//! BLE controller 的板上探针：`init` → `enable` → 进任务 → 发 HCI Reset → 打回程字节。
//!
//! 只在 `-Dbt-probe` 的构建里跑（照 `wifi-init-probe` 的模式）。**绝不与 wifi blob 同镜像**：
//! 两套 arena/队列都是按"协作式、无抢占"写的，共存会偶发损坏。
//!
//! ## 顺序（三个点错一个就白跑一趟）
//!
//! 1. **arena 最先初始化**：`r_btdm_task_init` 内部会调我们的 `task_create`，它要从 arena
//!    分 8 KiB 栈；arena 没初始化 ⇒ `alloc` 返回 null ⇒ `task_create` 返 ENOMEM ⇒
//!    init 链**第 4 步**失败，报错会指向"task_init 失败"而不是"arena 没初始化"。
//! 2. `init` 链（15 步，含 `transport.init`）→ `enable` 链（6 步，末尾 `r_btdm_task_enable`）。
//! 3. **必须 `sched.startScheduler()` 才会真正进任务**——只 `task_create` 是"登记"，
//!    任务永远不跑。之后主循环周期 `resumeTask`：正常情况下 controller 走
//!    "归档 → 我们的 `semRelease`/`eventqPut` → resume" 这条路，但若它阻塞在我们没覆盖的
//!    内部队列上，没有周期重入就会永远停在那里。
//!
//! ## 日志怎么读
//!
//! | 现象 | 结论 |
//! | --- | --- |
//! | 没有 `bt task round` | 任务从没跑过（`start` 没生效 / 任务没建出来） |
//! | 有 round、命令已发、但没有 `EVT` | 任务跑了但没回包（→ 查切片 E / 时钟门控） |
//! | 有 `EVT` 但 status≠0 | 回包了但命令失败 |
const std = @import("std");
const builtin = @import("builtin");
const osal = @import("osal_kit").osal;

/// abort 桩里记录的**直接调用者地址**（C 侧全局）。
extern var g_abort_ra: u32;
extern var g_c_count: u32;

/// 供 C 侧 abort 桩调用：在崩溃瞬间把状态导出（不 halt）。
/// **周期性**打印 OSAL 计数器（不依赖任何触发点）。
/// 停滞期间由 trap 的心跳反复调用 ⇒ 最后一行就是停滞时的计数。
/// 第 2 次 `event_init` 时触发总 dump（**确定性**触发点，不依赖中断）。
/// 第 1 次 `eventq_init` 时 dump —— 此时已越过 init 链早期，
/// 计数器首次反映真实事件操作。
pub fn bt_hook_eventq_init(n: u32) void {
    if (n != 1) return;
    probe_dump_now();
}

pub fn bt_hook_event_init(n: u32) void {
    if (n != 2) return;
    probe_dump_now();
}

export fn bt_print_osal_stats() void {
    const st = osal.stats();
    board.log.line("Q1 {d} {d} {d}", .{ st.eventq_put, st.eventq_get_ok, st.eventq_get_empty });
    board.log.line("Q2 {d} {d} {d}", .{ st.mutex_pend_ok, st.mutex_pend_busy, st.blocked_calls });
    board.log.line("Q3 {d} {d}", .{ st.pool_exhausted, st.eventq_requeued });
}

export fn probe_dump_now() void {
    dump_done = false; // abort 时刻必须能再次导出（否则被 once-only 门挡住）
    // **OSAL 计数器**：判断"投递了但消费不到"还是"根本没投递"的关键
    {
        const st = osal.stats();
        board.log.line("Q1 {d} {d} {d}", .{ st.eventq_put, st.eventq_get_ok, st.eventq_get_empty });
        board.log.line("Q2 {d} {d} {d}", .{ st.mutex_pend_ok, st.mutex_pend_busy, st.blocked_calls });
        board.log.line("Q3 {d} {d}", .{ st.pool_exhausted, st.eventq_requeued });
        board.log.line("Q4 {d} {d}", .{ log_hook_calls, log_hook_ours });
        board.log.line("Q5 {d} {d} {d} {d}", .{ board.hw.rw_calls, board.hw.rw_bytes, board.hw.rw_drops, board.hw.rw_max_fifo });
    }
    dumpAtPend();
}
const config = @import("config.zig");
const bringup = @import("bringup.zig");
const osi_impl_timerStats = @import("osi_impl.zig").timerStats;
const osi_impl_serviceTimers = @import("osi_impl.zig").serviceTimers;
const transport = @import("transport.zig");
const sched = @import("osal_kit").sched;
const porting = @import("porting.zig");
const board = @import("board");

/// 归档里的 BT 基带初始化（`libbtbb.a` 提供；IDF 的 `esp_btbb_enable` 就是调它）。
extern var s31_bt_log_mute: c_int;

extern fn bt_bb_v2_init_cmplx(version_print: c_int) c_int;

// **WiFi osi 栈**（wifi-blobs 移植件，本次综合的主线）
const osi_impl = @import("osi_impl.zig");
const init_config = @import("init_config.zig");
const osi = @import("osi.zig");
const s31_log_write = @extern(*const anyopaque, .{ .name = "s31_log_write" });
const libc_glue = @import("libc_glue.zig");
const wifi_glue = @import("wifi_glue.zig");
// **强制编译/发射**：Zig 惰性分析——未引用模块的 export fn 不会发射符号
comptime {
    _ = libc_glue;
    _ = wifi_glue;
}
var osi_table: osi.Osi = undefined;

/// **本轮最深步骤号**（mark.put 单调递增；LP-RAM 跨 boot 累积用）。
/// LP-RAM 累积的 RAM 侧副本（FEFE 记录用，写 flash 在 FEFC 证据之后）。
pub var lp_boot_n: u32 = 0;
pub var lp_hist: [9]u32 = @splat(0);

/// 链接脚本 `s31.ld` 的堆边界是**绝对符号**：取地址得到边界值，
/// 声明成 `usize` 会变成"去那个地址读一个 usize"。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}

/// 是否在探针里开中断。默认 **false**：先排除"ISR 打印打断 ROM UART 写"这个变量。
// **必须是 false**：`true` 会 `routeT0Interrupt(25)` + 每 2 ms 打印，而
// CLIC input 25 **也是 BT 归档的 tick 源**（ADR-001:1185 候选 A、
// README:9991-9994）⇒ ① 控制器时序步进不推进（0x200A 永远等不到完成条件）
// ② ISR 每 2 ms 灌 UART ⇒ TX FIFO 打满（恒 128）⇒ 应用日志一行都出不来。
// 这同时解释了"串口零字节"与"0x200A 挂住"两个症状。
pub var probe_irqs: bool = false;
/// **BT 窗口（enable 之后）禁止一切 flash 写**：post-enable 的 ROM flash 写与
/// blob 自己的 flash 操作相撞会把 SPI1 主 FSM 楔死（MST_ST 卡 0xF、SLV_ST 卡 9、
/// FLASH_PE/USR 自清位卡 1；此后 HP 对 SPI1 寄存器块的读写全部挂死）。
/// 置位后：mark.put 只写 LP 槽、flashStage/Extra 空转、dumpPcRing 直接返回、
/// 采样器 ISR 不再触发 0x187000 dump（pc_dump_at 改大）。深度经 LP hist 跨复位读出。
pub var bt_window_no_flash: bool = false;
/// 实验：fwd06 前把 clk_conf1/0x20109C08 回写成官方 BLE-only 值。
pub var align_clk_conf1: bool = true;

/// **盲区诊断块**（2026-11-21）：UART/T0 失声后唯一的读出通道。泵（主上下文）
/// 每轮把现场写进 LP RAM 黑匣子（跨复位保留），下次开机首段 `lpBlackBoxReport`
/// 读出。flash 路径已弃用（BT enable 后 ROM flash 写不可靠，实测扇区始终 0xFF）。
const diag_blk_magic: u32 = 0xD1A6_B007;
/// LP RAM 黑匣子地址（0x2E000200 起 64 字；现有 LP 槽只用到 0x0000-0x002C 与 0x0440-0x04A0）。
const lp_blk_addr: usize = 0x2E00_0200;
var diag_blk_tries: u32 = 0;
var wdt_suicide: bool = false;
/// 实验：fwd06 前做一次 MWDT1 阳性对照（短超时不喂 ⇒ 必须复位）。
pub var mwdt_ctrl: bool = true;
var diag_blk_ok: bool = false;
fn rd32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
/// 返回是否已成功落盘并校验。
fn diagFlashBlock(round: u32) bool {
    var b: [64]u32 = @splat(0);
    var i: usize = 0;
    b[i] = diag_blk_magic;
    i += 1;
    b[i] = round;
    i += 1;
    // UART0：STATUS/CLKDIV/CONF0
    b[i] = rd32(0x2038_A01C);
    i += 1;
    b[i] = rd32(0x2038_A014);
    i += 1;
    b[i] = rd32(0x2038_A038);
    i += 1;
    // HP_SYS_CLKRST
    for ([_]usize{ 0x00, 0x04, 0x08, 0x0C, 0x40, 0x88, 0x1E0 }) |o| {
        b[i] = rd32(0x2058_7000 + o);
        i += 1;
    }
    // TIMG0 原始 13 字
    for (0..13) |k| {
        b[i] = rd32(0x2058_0000 + 4 * k);
        i += 1;
    }
    // MODEM_SYSCON 16 字
    for (0..16) |k| {
        b[i] = rd32(0x2010_9C00 + 4 * k);
        i += 1;
    }
    // FE / 计数
    b[i] = rd32(0x2010_0450);
    i += 1;
    const st = osal.stats();
    b[i] = st.eventq_put;
    i += 1;
    b[i] = st.eventq_get_ok;
    i += 1;
    b[i] = st.event_run_count;
    i += 1;
    b[i] = bringup.bridge_w;
    i += 1;
    b[i] = bringup.bridge_ran;
    i += 1;
    b[i] = bringup.stub_blocks;
    i += 1;
    const tr = @import("board").trap;
    b[i] = tr.irq_count;
    i += 1;
    b[i] = tr.nmi_count;
    i += 1;
    b[i] = 0; // （uart_stuck_n 已随 NMI UART 诊断移除）
    i += 1;
    b[i] = @import("board").hw.rw_drops;
    i += 1;
    b[i] = sched.deferred_resumes;
    i += 1;
    b[i] = sched.self_resume_dropped;
    i += 1;
    // CSRs（主上下文）
    b[i] = asm volatile ("csrr %[v], 0x300"
        : [v] "=r" (-> u32),
    );
    i += 1;
    b[i] = asm volatile ("csrr %[v], 0x304"
        : [v] "=r" (-> u32),
    );
    i += 1;
    b[i] = asm volatile ("csrr %[v], 0x305"
        : [v] "=r" (-> u32),
    );
    i += 1;
    b[i] = asm volatile ("csrr %[v], 0x307"
        : [v] "=r" (-> u32),
    );
    i += 1;
    // **写 LP RAM 黑匣子**（跨复位保留；下次开机首段读出打印）。magic 最后写，
    // 半截数据不会被误认。BT enable 后 ROM flash 写不可靠（档案）⇒ 不走 flash。
    const lp: [*]volatile u32 = @ptrFromInt(lp_blk_addr);
    var k: usize = 1;
    while (k < i) : (k += 1) lp[k] = b[k];
    lp[0] = diag_blk_magic;
    return true;
}

/// 开机首段：若黑匣子 magic 在，则逐字打印（每行 4 字）并清 magic。
pub fn lpBlackBoxReport() void {
    // LP 追踪槽（0x2E000300）：最后 OSAL 调用者 ra / log-sink 的 blob ra / 探针阶段标记。
    const t: [*]volatile u32 = @ptrFromInt(0x2E00_0300);
    board.log.line("BBT seq={d} osal_ra=0x{x:0>8} sink_ra=0x{x:0>8} phase=0x{x:0>8}", .{ t[0], t[1], t[2], t[3] });
    // 事件环回放：最近的 24 条（tag<<28|value），按发生顺序。
    {
        const ring: [*]volatile u32 = @ptrFromInt(0x2E00_0320);
        const n: u32 = if (t[0] < 24) t[0] else 24;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const e = ring[(t[0] + 1 - n + k) % 24]; // 最新事件在 (seq % 24)
            board.log.line("BBR {d} t{d} 0x{x:0>7}", .{ k, e >> 28, e & 0x0FFF_FFFF });
        }
    }
    // （BBT phase==0xD2C7 且上一条复位原因是 WDT ⇒ 对照通过。）
    {
        // 冻结点 PC 采样（NMI 每 tick 写）：last/prev 相同 ⇒ 自旋在同一条指令附近。
        const pc0: *volatile u32 = @ptrFromInt(0x2E00_0380);
        const pc1: *volatile u32 = @ptrFromInt(0x2E00_0384);
        const al: *volatile u32 = @ptrFromInt(0x2E00_0388);
        board.log.line("BBP last=0x{x:0>8} prev=0x{x:0>8} nmi={d} assert_line={d}", .{ pc0.*, pc1.*, @import("board").trap.nmi_count, al.* });
        {
            const cnt: *volatile u32 = @ptrFromInt(0x2E00_039C);
            const ring: [*]volatile u32 = @ptrFromInt(0x2E00_03A0);
            var k: u32 = 0;
            while (k < 16) : (k += 1) {
                const e = ring[(cnt.* + 32 - 16 + k) % 32];
                board.log.line("BBQ {d} 0x{x:0>8}", .{ k, e });
            }
        }
    }
    const lp: [*]volatile u32 = @ptrFromInt(lp_blk_addr);
    if (lp[0] != diag_blk_magic) return;
    var r: usize = 0;
    while (r < 16) : (r += 1) {
        board.log.line("BBX {d}: {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ r, lp[4 * r], lp[4 * r + 1], lp[4 * r + 2], lp[4 * r + 3] });
    }
    lp[0] = 0;
}

/// **UART0 快照/恢复**（2026-11-21）：首条 HCI 命令处理期间 UART0 TX 死亡
/// （FIFO 卡满、所有输出被丢弃——"UART 哑"）。fwd06 前拍快照，泵每轮比对+恢复
/// 可安全回写的配置寄存器；恢复成功则输出复现，且差分字直接指认改写者。
const UART0: usize = 0x2038_A000;
const uart_cmp_words = 32; // 0x00..0x7C
var uart_snap: [uart_cmp_words]u32 = undefined;
var uart_snap_ok: bool = false;
var uart_restored: u32 = 0;
/// 可安全回写的配置偏移（不含 0x00 FIFO/CONF0 同址、0x10 INT_CLR、0x1C STATUS）。
const uart_restore_offs = [_]usize{ 0x14, 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34, 0x3C, 0x40, 0x44, 0x48, 0x4C, 0x50, 0x54, 0x58, 0x5C, 0x60, 0x64, 0x68, 0x6C, 0x70, 0x74, 0x78, 0x7C };
/// HP_SYS_CLKRST_UART0_CTRL0（0x2058_7088）：bit7 UART0_CLK_EN、bit1 APB_CLK_EN、
/// bit0 SYS_CLK_EN、bit3/2 APB/CORE_RST_EN、bits[6:5] 时钟源；SOC_CLK_SEL（+0x00）。
const CLKRST_UART0_CTRL0: usize = 0x2058_7000 + 0x88;
const CLKRST_SOC_CLK_SEL: usize = 0x2058_7000 + 0x00;
var uart_ctrl0_snap: u32 = 0;
var uart_soc_snap: u32 = 0;
fn uartSnapshot() void {
    var i: usize = 0;
    while (i < uart_cmp_words) : (i += 1) uart_snap[i] = @as(*volatile u32, @ptrFromInt(UART0 + 4 * i)).*;
    uart_ctrl0_snap = @as(*volatile u32, @ptrFromInt(CLKRST_UART0_CTRL0)).*;
    uart_soc_snap = @as(*volatile u32, @ptrFromInt(CLKRST_SOC_CLK_SEL)).*;
    uart_snap_ok = true;
}
/// 恢复并返回恢复的字数；首个差分 (offset, was, now) 写入 out。
fn uartRestore(out: *[3]u32) usize {
    if (!uart_snap_ok) return 0;
    var n: usize = 0;
    for (uart_restore_offs) |off| {
        const r: *volatile u32 = @ptrFromInt(UART0 + off);
        const cur = r.*;
        if (cur != uart_snap[off / 4]) {
            if (n == 0) {
                out[0] = @intCast(off);
                out[1] = uart_snap[off / 4];
                out[2] = cur;
            }
            r.* = uart_snap[off / 4];
            n += 1;
        }
    }
    // 时钟控制寄存器：被改写则整字恢复（覆盖门控/复位/源切换三类假说）。
    const c0: *volatile u32 = @ptrFromInt(CLKRST_UART0_CTRL0);
    if (c0.* != uart_ctrl0_snap) {
        if (n == 0) {
            out[0] = 0x100; // 标记：差分在 CLKRST+0x88
            out[1] = uart_ctrl0_snap;
            out[2] = c0.*;
        }
        c0.* = uart_ctrl0_snap;
        n += 1;
    }
    uart_restored += @intCast(n);
    return n;
}

var cfg: config.Config = .{};
var ctrl_task: ?*sched.Task = null;

// **寄存器稀疏快照/差分**（0x200A 前后对比）：
// ⚠ 只读**已知可读白名单**——盲读区域会挂总线（0x20109800+128B 实测 boot 循环，
// 同 MODEM_PWR 组 2 的"读挂"型）。白名单 = 全部有先前成功读据的地址。
const snap_addrs = [7]usize{
    0x2010_98BC, // 合成器 ready（bit2）
    0x2010_11AC, // FE 计数器（fe）
    0x2010_08D0, // FE 等待位
    0x2010_F818, // ANA_CONF0（事务相位）
    0x2010_F800, // I2C0_CTRL
    0x2010_9C04, // modem clk conf
    0x2010_9C14, // modem clk conf1
};
var snap_regs: [7]u32 = @splat(0);
var snap_valid: bool = false;
var snap_diff_done: bool = false;

fn snapshotRegs() void {
    for (&snap_regs, &snap_addrs) |*w, *a| {
        w.* = @as(*volatile u32, @ptrFromInt(a.*)).*;
    }
}

/// 差分打印：白名单寄存器 0x200A 前后对比，列出变化项（最多 7 项）。
fn printRegDiff() void {
    var buf: [180]u8 = undefined;
    var out: usize = 0;
    const head = "bt diff:";
    @memcpy(buf[out..][0..head.len], head);
    out += head.len;
    for (&snap_regs, &snap_addrs, 0..) |*old, *a, i| {
        const now = @as(*volatile u32, @ptrFromInt(a.*)).*;
        if (now != old.*) {
            const w = std.fmt.bufPrint(buf[out..], " +{x}=0x{x:0>8}", .{ a.* & 0xFFFF, now }) catch break;
            out += w.len;
            old.* = now;
        }
        _ = i;
    }
    osal.logPublic("{s}", .{buf[0..out]});
}

// ---- 钩子：**必须在 init 链之前装**，否则最关键的观测手段就没了 ----

/// ⚠ 单位是**毫秒**：注入 `nowUs()/1000`。直接注入 `nowUs()` 会让所有超时窗口大 1000 倍，
/// 症状是"起来了但永远不超时/不动作"，极难归因。
fn osiOnIdle() void {
    // 任务上下文调用：驻停任务、切回主上下文（主泵下一轮 resumeTask 再切入）。
    sched.block();
}

// **零除法 ms 时基**（2026-11-21）：`nowUs()/1000` 的 u64 软件除法链被 blob
// 调度器每 tick 轮询 ⇒ CPU 钉死在 __udivmoddi4（NMI 实证）。改累加器：
// Δµs 分块进 ms 桶，轮询高频时每调用仅 0-1 次减法，无除法。
var nowms_last_us: u64 = 0;
var nowms_rem: u64 = 0;
var nowms_acc: u32 = 0;
fn nowMs() u32 {
    const now = board.hw.nowUs();
    const delta = now -% nowms_last_us;
    nowms_last_us = now;
    nowms_rem +%= delta;
    while (nowms_rem >= 1000) {
        nowms_acc +%= 1;
        nowms_rem -= 1000;
    }
    return nowms_acc;
}
/// **实验脚手架开关**（全部默认关）：这些是排查"卡在 0x2010B000"时用的一次性装置，
/// 保留是为了可复现，但默认不干扰正常 bring-up。
/// - `dump_rom`：启动时 dump ROM 区与 UART0 寄存器（离线反汇编用）
/// - `ble_block_experiment`：复位脉冲 + 时钟重开 + `bt_bb_v2_init_cmplx` + 读 `0x2010B000`
pub var dump_rom: bool = false;
/// **只做一次直读**（control read `0x20109C04` + `0x2010B000`），
/// 不触发 `ble_block_experiment` 那条「重置脉冲 + bt_bb_v2_init_cmplx」的重路径。
pub var bt_block_read_only: bool = false; // 复现用；默认关（开启后每次开机读一次 0x2010B000）

pub var ble_block_experiment: bool = false;
/// 跳过 `r_btdm_task_init`（它会访问不可达块）⇒ 用于验证 step 7–15 / enable / HCI。
pub var skip_task_init: bool = false;

/// 补调 `fqmZk`（把 `Xpuq` 的锚点 `P` 填上）。
/// **默认关**：oracle 实测 IDF 里该锚点在 init **之前也是 0**，由 init 自己填；
/// 我们此前的"P=NULL 是 bug"是**误判**（在 step 6 之前读了它）。
pub var populate_workaround: bool = false; // 真实路径（21.o 锚点由 OkE7 自己发布）
/// **只发布 7.o 的锚点**（`r_sym_bt_BOhff` 的守卫）。依据：21.o 的锚点由 `OkE7`
/// 自己 malloc(76) 并发布（见 README），而 7.o 的锚点**没有任何惰性发布者**
/// ⇒ `BOhff`（建任务）永远早退 ⇒ `task_create` 永不发生。
pub var publish_bohff_anchor: bool = false; // 实验：不预发布 anchor[8]，让 JwHs 自己分配

/// `Xpuq` 用的锚点全局（`libbtdm_common/2.o` 的 `.bss.r_sym_bt_d3D3sk5KewclELfrD5xa`）。
/// 唯一的写者是 `r_sym_bt_fqmZkUKgd5GE6m7i2YFG`：`P = wr_btdm_osal_malloc(...)`。
/// `Xpuq` 之后用 `a1 = P` 做 `sw zero, 0(a1) …` 的零填充 —— **若 P 为 NULL，
/// 它会从地址 0 开始写，看起来就是"卡死"**（无 fault、无 OSAL 调用）。
extern var r_sym_bt_d3D3sk5KewclELfrD5xa: u32;

/// 是否把 `osal.logPublic` 的每一行都打到 UART。
/// 默认 **true**（可观测性优先）；设 false 可做"UART 静默"对照——但注意那样连进度行也看不到，
/// 需要额外把里程碑用 `board.log.line` 直写，否则实验没有信息量（踩过）。
pub var verbose: bool = false; // 主实验：日志几乎全关，只留里程碑行

/// 对照实验用：false ⇒ 完全不写任何时钟门控（验证"我们改时钟把 UART 弄停"）。
pub var clock_writes: bool = true; // 默认写；false 仅用于对照实验

/// 直接写 UART0 的 FIFO，**永不阻塞**。
///
/// 为什么不用 `board.log.line`（ROM 的 `esp_rom_printf`）：ROM 的路径会
/// `while (txfifo_cnt > 127) {}` 死等——一旦 FIFO 不排空，**日志自己也挂住**，
/// 于是"卡住之后什么都看不到"，无法区分"程序停在那"与"只是打印停了"。
/// 这里对每个字节做**有界**等待，等不到就丢弃，保证日志通道本身不会堵死。
pub var log_hook_calls: u32 = 0;

// ---- RAM 环形日志：不碰 UART，由 ISR 逐条吐出（短行才挤得进 FIFO）----
const ring_slots = 32;
const ring_len = 60;
pub var log_ring: [ring_slots][ring_len]u8 = @splat(@splat(0));
pub var log_ring_lens: [ring_slots]u8 = @splat(0);
pub var log_ring_n: u32 = 0;

pub fn ringPush(msg: []const u8) void {
    const slot = log_ring_n % ring_slots;
    const n = @min(msg.len, ring_len);
    @memcpy(log_ring[slot][0..n], msg[0..n]);
    log_ring_lens[slot] = @intCast(n);
    log_ring_n +%= 1;
}

/// ISR 侧调用：吐出第 `idx` 条（0 = 最新），返回切片。
/// 事件触发导出：打 PC 采样 + 计数器，然后停机。
var dump_done: bool = false;

/// dump 专用：格式化后走**阻塞写**（肯等到 FIFO 有空位），避免长行被丢。
fn dumpLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [200:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..198], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    board.hw.rawLineBlocking(buf[0 .. text.len + 1 :0]);
}

fn dumpAtPend() void {
    if (dump_done) return;

    // **UART 排空自测（修正版）**：自旋到计数 < 5（有界 ~20 ms），并**双读**对照。
    // 旧版只等 ~10 ms，而 125 B @115200 需 10.85 ms ⇒ 结论无效。
    {
        const st: *volatile u32 = @ptrFromInt(0x2038_A01C);
        const f: *volatile u32 = @ptrFromInt(0x2038_A000);
        const before = (st.* >> 16) & 0xFF;
        f.* = 'Z';
        var k: u32 = 0;
        while (k < 2_000_000) : (k += 1) {
            if (((st.* >> 16) & 0xFF) < 5) break;
        }
        const r1 = (st.* >> 16) & 0xFF;
        const r2 = (st.* >> 16) & 0xFF;
        const cc = (@as(*volatile u32, @ptrFromInt(0x2038_A088))).*;
        board.log.line("U {d}->{d},{d} spins={d} cc={x}", .{ before, r1, r2, k, cc });
    }
    dumpLine("A{x}/{d}", .{ g_abort_ra, osal.arenaFree() }); // 极短：调用者/空闲
    osal.canaryScan();

    osal.arenaWalk();
    {
        var mi: u32 = 0;
        while (mi < @min(osal.malloc_calls, 8)) : (mi += 1) dumpLine("M{d} {d} 0x{x}", .{ mi, osal.mc_sizes[mi], osal.mc_rets[mi] });
    }
    dumpLine("MC {d} sz={d} ret=0x{x}", .{ osal.malloc_calls, osal.last_req_size, osal.last_ret });
    dumpLine("CN 0x{x} 0x{x} {d}", .{ osal.canary_base + osal.canary_first_off, osal.canary_first_val, osal.canary_bad_words });
    // **按字节预算**：1 行计数（~20 B）+ 3 条截断到 24 B 的消息，合计 < 110 B。
    dumpLine("D{d}.{d}", .{ log_hook_calls, osal.caller_n });
    var mi: u32 = 0;
    while (mi < 3) : (mi += 1) {
        const m = ringAt(mi);
        if (m.len > 0) dumpLine("M{s}", .{m[0..@min(m.len, 24)]});
    }
    dump_done = true;
}

var flag_buf: [16]u8 = @splat(0);
fn flagBuf() []const u8 {
    const n = std.fmt.bufPrint(&flag_buf, "<C{d}>", .{g_c_count}) catch return "<C>";
    return n;
}

pub fn ringCount() u32 {
    return log_ring_n;
}
pub fn logcCount() u32 {
    return log_hook_calls;
}

pub fn ringAt(idx: u32) []const u8 {
    if (idx >= log_ring_n) return "";
    const slot = (log_ring_n -% 1 -% idx) % ring_slots;
    return log_ring[slot][0..log_ring_lens[slot]];
}
pub var log_hook_ours: u32 = 0;
pub var log_hook_calls_only: u32 = 0;
/// 仅 step 6 窗口内为真：只有此刻才发数字码（序列纯净，且不被里程碑挤掉）。
pub var call_stream_on: bool = false;

/// 调用码存进 RAM（不占 UART），由一次性导出统一打出来 —— 里程碑进度照常可见。
pub var code_ring: [48]u8 = @splat(0);
pub var code_n: u32 = 0;

fn codePush(c: u8) void {
    if (code_n < code_ring.len) {
        code_ring[code_n] = c;
        code_n += 1;
    }
    // **按码数触发导出**：不依赖 `irq_count`（其基准未核实），也不 halt。
    // 16 个码≈接近序列尾部，此时打一行 ~30 字节，FIFO 放得下。
    if (code_n == 8 or code_n == 16) {
        if (board.trap.extra_dump) |f| f();
    }
}

/// 直接写一个字节（绕过行缓冲；用于"每次调用一字母"的低带宽编码）。
fn uartPut(ch: u8) void {
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    var spins: u32 = 0;
    while ((((status.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
    if (spins < 40) fifo.* = ch;
}

/// 调用名 → 单数字码（数字不会与日志散文里的字母混淆，grep `[0-9]` 即得序列）。
/// malloc=0 mutex_init=1 eventq_init=2 event_init=3 mutex_pend=4
/// mutex_release=5 free=6 eventq_get=7 eventq_put=8 sem_*=9 其余=#
fn codeOf(name: []const u8) u8 {
    if (std.mem.startsWith(u8, name, "malloc")) return '0';
    if (std.mem.startsWith(u8, name, "mutex_init")) return '1';
    if (std.mem.startsWith(u8, name, "eventq_init")) return '2';
    if (std.mem.startsWith(u8, name, "event_init")) return '3';
    if (std.mem.startsWith(u8, name, "mutex_pend")) return '4';
    if (std.mem.startsWith(u8, name, "mutex_release")) return '5';
    if (std.mem.startsWith(u8, name, "free")) return '6';
    if (std.mem.startsWith(u8, name, "eventq_get")) return '7';
    if (std.mem.startsWith(u8, name, "eventq_put")) return '8';
    if (std.mem.startsWith(u8, name, "sem")) return '9';
    return '#';
}
pub var log_hook_other: u32 = 0;
/// 对照实验：为 true 时 logHook 只计数，把 UART 让出来（否则采样全落在它里面）。
pub var log_hook_silent: bool = false; // 默认放行；true 会连我们自己的进度日志一起静音（实测过）

fn logHook(msg: []const u8) void {
    // **三层语义各归各位**（这条以前写错过两次，每次代价是一轮无效板测）：
    //   里程碑 `bt bringup:`  → 无条件放行（唯一能判断进度的输出）
    //   归档日志 `osal>`       → 受 `verbose` 控制
    //   逐调用 `bt hook:`      → 受 `osal.trace_hooks` 控制（在 `logLine` 里）
    //
    // probe 镜像默认**打开**逐调用日志：它就是为了看"崩之前最后一个归档调用是什么"。
    // 输出量大，正式镜像不要开（`logLine` 里按前缀过滤，这里只是把门打开）。
    // ⚠️ 曾经这里无条件 `osal.trace_hooks = true` —— 每次打印都会把调用方设的静音**重新打开**，
    // 诊断窗口因此失效。trace 的开关应在入口显式设，不该藏在日志钩子里。
    board.trap.recordLogCaller(@returnAddress());
    log_hook_calls +%= 1;
    // **按来源分流**：只放行我们自己以 `"bt "` 开头的短行（`logPublic` 走这里），
    // 归档的消息只计数不写 UART ⇒ 串口不再被灌满，采样可用。
    if (std.mem.startsWith(u8, msg, "bt ")) {
        log_hook_ours +%= 1;
        // **只对逐调用行限量**（`bt ret:`/`bt call:`），里程碑（`bt bringup:`/`bt lp:`）不受限：
        // 早先把上限套在全部自身日志上，结果里程碑被吃掉、`malloc` 行变成 0（本会话踩过）。
        // **逐调用只写 1 个字节**：把 `bt ret: <name>…` / `bt call: <name>…` 压成该名字的首字母。
        // 21 次调用只占 21 字节，永不灌满 128 B FIFO，也不会与 ISR 心跳逐字节交错到无法 grep。
        if (call_stream_on) {
            if (std.mem.indexOf(u8, msg, "bt ret: ")) |k| {
                const rest = msg[k + 8 ..];
                if (rest.len > 0) {
                    codePush(codeOf(rest));
                    return;
                }
            }
            if (std.mem.indexOf(u8, msg, "bt call: ")) |k| {
                const rest = msg[k + 9 ..];
                if (rest.len > 0) {
                    codePush(codeOf(rest));
                    return;
                }
            }
            return; // 窗口内其它自身日志一律不发：把 21 字节留给码流
        }
    } else {
        log_hook_other +%= 1; // 归档自己的消息：进 RAM 环，不打 UART
        ringPush(msg);
        return;
    }
    if (!verbose and std.mem.startsWith(u8, msg, "osal> ")) return;
    const uart_fifo: *volatile u32 = @ptrFromInt(0x2038_A000); // UART_FIFO
    const uart_status: *volatile u32 = @ptrFromInt(0x2038_A01C); // UART_STATUS
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((uart_status.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
        if (spins >= 40) return; // FIFO 卡死：**立即丢字节，绝不把 CPU 停在 UART**
        uart_fifo.* = ch;
    }
    var spins: u32 = 0;
    while ((((uart_status.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
    if (spins < 40) uart_fifo.* = '\n';
}
/// 当前不开中断 ⇒ 空实现；切片 E 真开中断后换成真的关/开。
fn irqSave() u32 {
    return 0;
}
fn irqRestore(_: u32) void {}
fn macHook(out: *[6]u8) void {
    // 出厂 MAC 还没接 efuse 读；先给本地管理地址兜底（0x02 开头）。
    out.* = .{ 0x02, 0x00, 0x00, 0x00, 0xBB, 0x01 };
}

/// 因果实验：把 anchor[0] 毒成一个**有效可写 RAM 指针**（+28=0），
/// 若崩溃因此消失或换点，就证明"anchor[0]==0 → 零值兜底 → store 到 0"这条链。
var poison_buf: [64]u8 align(4) = @splat(0);
pub var poison_anchor0: bool = false; // 基线
pub var pmu_dump: bool = false; // 纯诊断；WITH_PHY 版会在此停住，默认关
pub var reprobe_ble_block: bool = false; // 验证须放在 PHY 使能/校准**之后**，见 README // 复核实验：读 0x2010B000 会挂死整个系统
/// 自测：故意往地址 0 写一次。用它的标签地址与 panic 报出的 mepc 比对，
/// 判定这颗 CPU 的 store 异常是精确的还是会延迟上报。
pub var selftest_store0: bool = false; // 标定完成：见 README

var selftest_scratch: u32 = 0;

export fn probeSelftestStore0() void {
    // 标定延迟：坏写 -> fence -> 一次正常写（带标签）。
    // 若 mepc 落在 fence 处，说明错误在 fence（写队列排空点）上报。
    asm volatile ("sb zero, 0(zero)");
    asm volatile ("fence iorw, iorw");
}

export fn probeSelftestAfterFence() void {
    const q: *volatile u32 = &selftest_scratch;
    q.* = 0x1234;
}

pub fn run() noreturn {
    board.trap.extra_dump = dumpOsalCallers;
    board.trap.on_pc_ready = dumpPcRing;
    board.trap.ring_at = ringAt;
    board.trap.ring_n_at = ringCount;
    osal.dump_hook = dumpAtPend;
    board.trap.probe_logc = logcCount;
    if (reprobe_ble_block) {
        // 复核 README 记录的总根因：读 BLE/MAC 寄存器块是否会挂死（会挂，默认关）。
        board.log.line("{s}", .{"bt probe: re-probing 0x2010B000 ..."});
        const bleblk: *volatile u32 = @ptrFromInt(0x2010_B000);
        const ble0 = bleblk.*;
        board.log.line("bt probe: 0x2010B000 = 0x{x} (survived)", .{ble0});
    }
    if (selftest_store0) {
        probeSelftestStore0();
        probeSelftestAfterFence();
    }
    if (poison_anchor0) {
        // +28 填有效指针：若 `lw a0,28(a5)` 的值被下游当指针用，崩点应随之后移。
        const p28: *u32 = @ptrCast(&poison_buf[28]);
        p28.* = @intFromPtr(&poison_buf);
        const slot: *volatile u32 = @ptrFromInt(0x2f00fff4);
        slot.* = @intFromPtr(&poison_buf);
        board.log.line("poison: anchor[0] -> 0x{x}", .{@intFromPtr(&poison_buf)});
    }
    // **最先**做 ROM 取样：此时还没开中断，输出不会被 ISR 的行冲散。
    if (dump_rom) {
        dumpRom("A", 0x2f83efb0, 96);
        dumpRom("B", 0x2f812180, 160);
        // **ROM BB 分发考古（2026-11-21）**：链头 handler 0x2f8127ec（ctx[4] 间接跳）
        // 与链表成员——找 ctx（0x2f07f1F4）的惰性初始化或真 ISR 线索。
        dumpRom("CH", 0x2f8127c0, 0x140);
        // ctx 表区：0x2f07f190-0x2f07f210（链表头 0x2f07f19c + ctx 槽 0x2f07f1F4）
        dumpRom("CT", 0x2f07f190, 0x80);
        dumpRom("U", 0x2038A000, 64);
    }

    porting.clock_writes_enabled = clock_writes;
    bringup.skip_task_init = skip_task_init;
    osal.setHooks(.{
        .now_ms = nowMs,
        .log = logHook,
        .irq_save = irqSave,
        .irq_restore = irqRestore,
        // 门控测量（`r_btdm_task_init` 的 env/P/锚点表）原先硬编码在 `osal.mutexPend` 里，
        // 现在由本组件注册 —— 内核不该知道 `0x2f00ffd0` 和 `probe_ptr`。
        .on_mutex_acquired = @import("gate.zig").probeAnchors,
    });
    osal.setMacHook(macHook);
    board.log.line("{s}", .{"bt probe: hooks installed (now_ms=us/1000)"});

    // **最先初始化时基**：不调 `hw.initTimer()`，TIMG0 的时钟没开 ⇒ `nowUs()` 恒 0（实测，
    // 见 ADR-001:729-730）⇒ ① T0 的 alarm 永不到点 ⇒ 一个中断都不来（采样器永远静默）；
    // ② OSAL 的 `now_ms = nowUs()/1000` 恒 0 ⇒ 归档里任何"等到某个时刻"的条件永远不成立 ⇒ 死等。
    // 这一行缺席的代价是整条链卡在 step 6，而且现象与"中断不工作"完全一样。
    board.hw.initTimer();
    const t0 = board.hw.nowUs();
    board.hw.initTimer();
    const t1 = board.hw.nowUs();
    board.log.line("bt probe: timer {d} -> {d} (must increase)", .{ t0, t1 });

    // **在 init 之前**武装 T0 + 开中断：init 一旦卡住，只有 ISR 还能说话。
    // 采样点在 trap 的输入 25 分支；中断还在来 ⇒ 是 spin 而非死机。
    // ⚠ 只有探针构建这么做，生产固件保持 MIE=0。
    // **对照实验开关**：ISR 里打印可能打断 ROM 的 UART 写（板侧证据：ROM 卡在
    // `UART0+0x1C` 的 TX 状态、值恒 128）。默认**不开中断**，只保留时基。
    if (probe_irqs) {
        board.hw.routeT0Interrupt(25);
        board.hw.armT0Interrupt(2000);
        board.hw.enableInterrupts();
        // ⚠ **ISR 的 0x187000 dump 必须在此关掉**：dump 在采样满 72 次（~144ms）
        // 时擦写 flash——与本轮 step 5 的 flash 标记写同窗相撞（ROM spiflash
        // 不可重入 ⇒ 双方挂死）。历史上所有"静默挂死"都可能是这个竞争。
        board.trap.pc_dump_at = 0xFFFF_FFFF;
        // **把 T0 的 CLIC 输入变成 NMI 源**：NMI 不受 `mstatus.MIE` 屏蔽，
        // 所以即使归档进了临界区（关中断）也照样能打断它、拿到 PC。
        // `CLIC_INT_CTRL_REG(i) = 0x10801000 + i*4`；bit3 = nmies、bits[7:4] = nmithres。
        // 保留优先级低 3 位、置 nmies、把 nmithres 清零。
        {
            const reg: *volatile u32 = @ptrFromInt(0x1080_1000 + 25 * 4);
            const old = reg.*;
            // **必须保留 bit8（IE）**：只保留低 3 位会把使能位一起清掉，中断就不来了。
            reg.* = (old & 0x107) | (1 << 3);
            board.log.line("bt probe: clic[25] 0x{x} -> 0x{x} (nmies)", .{ old, reg.* });
        }
        board.log.line("{s}", .{"bt probe: irq enabled (probe only), t0=2ms"});
    } else {
        board.log.line("{s}", .{"bt probe: irqs OFF (control run)"});
    }

    if (ble_block_experiment) {
        // **可访问性实验**：归档在 `r_sym_bt_XPuq` 里读 `0x2010B000..0x2010B100`
        // （MODEM_BASE+0xB000，BLE/MAC 私有块，soc 头里无定义）。
        // 已验证：**在什么都没做时读它一次就挂死**（总线挂起）。
        // 现在按 IDF 的顺序先做前置，再读一次，看是否变可读：
        //   ① 开我们那套时钟门控  ② 调归档里的 `bt_bb_v2_init_cmplx(1)`（= esp_btbb_enable 的核心）
        board.log.line("{s}", .{"bt probe: clock gates first ..."});
        var early_cfg = config.defaults();
        porting.clock_writes_enabled = true;
        porting.btdmLpEnableClock(&early_cfg.btdm);

        // `HP_SYS_CLKRST.MODEM_CTRL0`(0x20587040) 的 bit0 = `MODEM_CLK_EN`（默认 1）。
        // 若它为 0，modem 块就没有时钟 ⇒ 访问会挂死。
        const modem_ctrl0: *volatile u32 = @ptrFromInt(0x2058_7040);
        const mc0 = modem_ctrl0.*;
        board.log.line("bt probe: MODEM_CTRL0=0x{x:0>8} clk_en={}", .{ mc0, (mc0 & 1) != 0 });
        if ((mc0 & 1) == 0) {
            modem_ctrl0.* = mc0 | 1;
            board.log.line("bt probe: MODEM_CLK_EN was 0 -> set, now 0x{x:0>8}", .{modem_ctrl0.*});
        }
        // 复位位：我们打印过 `rst_conf=0x00000000` ⇒ 所有 modem 复位位都是 0（未处于复位）✓

        // **完整复位脉冲**（IDF 的 `MODEM_RESET_FIELD_WHEN_PU` 等价物）：此前我们只脉冲过
        // bit16(`rst_btmac`)，而 bit15/17/23/29 这些子模块复位位可能**从未被置过**。
        // 先写全 1（按住所有复位）再写全 0（释放），然后重开时钟（复位可能清掉时钟配置）。
        const rst: *volatile u32 = @ptrFromInt(0x2010_9C10);
        const rst_before = rst.*;
        rst.* = 0xFFFF_FFFF;
        var d: u32 = 0;
        while (d < 2000) : (d += 1) std.atomic.spinLoopHint();
        rst.* = 0;
        board.log.line("bt probe: rst pulse {x} -> all1 -> {x}", .{ rst_before, rst.* });
        porting.forceReenableClocks(&early_cfg.btdm);
        board.log.line("{s}", .{"bt probe: clocks re-enabled after reset pulse"});

        board.log.line("{s}", .{"bt probe: calling bt_bb_v2_init_cmplx(1) ..."});
        _ = bt_bb_v2_init_cmplx(1);

        board.log.line("{s}", .{"bt probe: probing 0x2010B000 (after bb init) ..."});
        const bleblk: *volatile u32 = @ptrFromInt(0x2010_B000);
        const ble0 = bleblk.*;
        board.log.line("bt probe: 0x2010B000 = 0x{x:0>8} (READABLE!)", .{ble0});
    }

    // 1) arena 最先
    const hs = @intFromPtr(heapStart());
    const he = @intFromPtr(heapEnd());
    if (he > hs) {
        const region = @as([*]u8, @ptrFromInt(hs))[0 .. he - hs];
        osal.initArena(region);
        // **极短**：长行会被 FIFO 丢；这里只要一个数字（KB）就够判读。
        board.log.line("A{d}K", .{(he - hs) / 1024});
    } else {
        osal.logPublic("bt probe: FATAL no heap region", .{});
        halt();
    }

    // 2) init 链（15 步）
    // **osi_impl hooks 接线（此前从未调用 setHooks ⇒ now_us 等全 null）**：
    // now_us = T0 µs 时基——esp_timer_get_time/deadline/serviceTimers 的唯一
    // 时间源（"时基缺口"的 osi 层最后一块）。
    @import("osi_impl.zig").setHooks(.{
        .now_us = @import("board").hw.nowUs,
        .fill_random = null,
        .mac = null,
        // **on_idle = 任务让出原语**：blob 阻塞路径（sem/queue 等待）的"合作式
        // 让出点"——不接线则任务自旋不让出 ⇒ 主循环永远泵不到 ⇒ step 20 挂死。
        // sched.block = 驻停当前（任务）切回主（osal eventqGet 同款原语）。
        .on_idle = osiOnIdle,
        .on_phy_enable = null,
        .on_note = null,
        .on_budget_exhausted = null,
    });
    cfg = config.defaults();
    osal.logPublic("bt probe: init start", .{});
    // **RTC 比较路径端到端硬件测试**（零 blob 依赖）：counter+5s → target0
    // → TAR_EN0 触发 → INT_ENA bit31/28 使能 → NMI 轮询 INT_RAW 是否到点
    // 置位。到点 ⇒ RTC 比较路径全通（blob 睡眠唤醒的硬件前提就位）。
    {
        const rtb: usize = 0x2080_0000;
        // ①clk_en 必须置位（ch23 实证：bit31 不置 counter 一个 tick 都不走）
        const date0: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x3FC)).*;
        if ((date0 >> 31) & 1 == 0) {
            @as(*volatile u32, @ptrFromInt(rtb + 0x3FC)).* = (date0 & 0x7FFF_FFFF) | 0x8000_0000;
        }
        // ②counter 锁存 #1 → 50ms nop 环 → 锁存 #2（走动判据：Δ≈137×50=6850）
        @as(*volatile u32, @ptrFromInt(rtb + 0x10)).* = 1 << 27;
        const cnt1: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x1C)).*;
        var nops: u32 = 0;
        while (nops < 4_000_000) : (nops += 1) asm volatile ("nop");
        @as(*volatile u32, @ptrFromInt(rtb + 0x10)).* = 1 << 27;
        const cnt2: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x1C)).*;
        // ③target0：⚠ **TAR_EN0 = +0x04 的 bit31**（IDF 头：TAR_HIGH0[15:0]
        // 在 +0x04[15:0]，TAR_EN0 在 +0x04[31]——此前写 +0x04=0 清掉了它、
        // +0x08 是 TAR_LOW1 ⇒ 武装从未生效）。写序：HIGH0(含 EN)先、LOW0 后。
        @as(*volatile u32, @ptrFromInt(rtb + 0x04)).* = 0x8000_0000; // HIGH0=0 | TAR_EN0=1
        @as(*volatile u32, @ptrFromInt(rtb + 0x00)).* = cnt2 +% (137_271 * 2);
        @as(*volatile u32, @ptrFromInt(rtb + 0x34)).* = (1 << 31) | (1 << 28); // INT_CLR
        @as(*volatile u32, @ptrFromInt(rtb + 0x30)).* = (1 << 31) | (1 << 28); // INT_ENA
        // 读回（写入保留判据）
        const t_lo: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x00)).*;
        const t_en: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x08)).*;
        const ena: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x30)).*;
        osal.logPublic("bt probe: rtc chk c1=0x{x:0>8} c2=0x{x:0>8} d={d} t_lo=0x{x:0>8} t_en={x:0>8} ena={x:0>8} date={x:0>8}", .{
            cnt1, cnt2, cnt2 -% cnt1, t_lo, t_en, ena, date0,
        });
        // **NMI 行带 INT_RAW 读数**：bit31=SOC_WAKEUP（到点置位？）、bit28=tick
        // （INT_RAW 经 NMI 行 ir= 字段观测，无需标志）
    }
    // **LP timer 时钟门扫描（安全协议）**：①LP_CON 基线 dump（8 字）；
    // ②clk_conf(+0x18) 置高位候选门（保低 4 位已确认）；③LP 槽记录 mask；
    // ④读 0x2070_0C00（挂 ⇒ rst ⇒ LP 槽存证 mask，rst 后可判）；⑤恢复。
    {
        // ①基线 dump
        var bb: [200]u8 = undefined;
        var bi: usize = 0;
        var rw: usize = 0;
        while (rw < 8) : (rw += 1) {
            const v: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F000 + rw * 4)).*;
            const pc = std.fmt.bufPrint(bb[bi..], "F{d:0>2}={x:0>8} ", .{ rw * 4, v }) catch break;
            bi += pc.len;
        }
        bb[bi] = 0;
        board.hw.rawLineBlocking(bb[0..bi :0]);
        // ②置高位候选门（0xFFF0：bit4-15 全试）
        const lpc: *volatile u32 = @ptrFromInt(0x2010_F018);
        const orig = lpc.*;
        const mask: u32 = 0x0000_FFF0;
        lpc.* = orig | mask;
        // ③LP 槽存证（slot9 = mask，slot10 占位）
        @as(*volatile u32, @ptrFromInt(0x2E00_0024)).* = mask;
        @as(*volatile u32, @ptrFromInt(0x2E00_0028)).* = 0xDEAD_BEEF;
        // ④读尝试
        const v: u32 = @as(*volatile u32, @ptrFromInt(0x2070_0C00)).*;
        @as(*volatile u32, @ptrFromInt(0x2E00_0028)).* = v;
        // ⑤恢复 + 打印（未挂才走到这）
        lpc.* = orig;
        osal.logPublic("bt probe: lptimer read ok 0x20700c00=0x{x:0>8} (mask=0x{x:0>4})", .{ v, mask });
    }
    // ⚠ **0x2070_0C00 读挂总线（2026-11-21 实证 rst ×5）**：首字读取即挂
    // （前 5 boot 全死在该读，rst:0x1a ×5；末 boot 越过但 dump 行被 FIFO 丢）
    // ⇒ 该区列入**读挂毒区**（与 0x2010D020 同型）。LP timer 探测改用
    // flash 标记法或 NMI 内单字读（下轮）。
    // **syscon 窗口对拍**：与 IDF 成功镜像的 `[after_init]` 逐字比较
    {
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a: usize = 0x2010_9C00 + k * 4;
            board.log.line("bt probe: syscon+0x{x:0>2} = 0x{x:0>8}", .{ k * 4, (@as(*volatile u32, @ptrFromInt(a))).* });
        }
    }
    // hp_sys_clkrst 全窗口（与 IDF 成功镜像的程序化对拍）
    {
        var k: usize = 0;
        while (k < 128) : (k += 1) {
            const a: usize = 0x2058_7000 + k * 4;
            const v = (@as(*volatile u32, @ptrFromInt(a))).*;
            if (v != 0) board.log.line("clkrst+0x{x:0>3} = 0x{x:0>8}", .{ k * 4, v });
        }
    }
    // **UART0 排水能力判定**：同一地址连采 4 次，间隔约 100 ms。
    // 递减 ⇒ 只是排得慢（查波特率/时钟）；恒定 ⇒ 真的停住。
    {
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            board.log.line("uart0 采样[{d}] 0x{x:0>8}", .{ k, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* });
            board.hw.delayUs(100_000);
        }
    }
    // PMU 窗口（0x20704000..+0x200）非零项 —— 与 IDF oracle 的同类 dump 逐字对拍
    // ⚠️ 纯诊断；`WITH_PHY=1` 版在最后几项停住（0x207041E4 之后），故默认关闭。
    if (pmu_dump) {
        var k: usize = 0;
        while (k < 128) : (k += 1) {
            const a: usize = 0x2070_4000 + k * 4;
            const v = (@as(*volatile u32, @ptrFromInt(a))).*;
            if (v != 0) board.log.line("pmu+0x{x:0>3} = 0x{x:0>8}", .{ k * 4, v });
        }
    }
    {
        const w: *volatile u32 = @ptrFromInt(0x20100800);
        board.log.line("FE800={x}", .{w.*});
    }
    // **IDF 次序：pmu_init → 时钟/使能 → BT init**。
    // 前/后各拍 {PMU_RF_PWC, ana-mst-clk, ICG_MODEM×2} 到 0x18B/18C；
    // pmu_init 的默认值会清掉 RF 电源/时钟 ⇒ 之后重放整套使能。
    {
        const rd_ = struct {
            fn r(addr: usize) u32 {
                return @as(*volatile u32, @ptrFromInt(addr)).*;
            }
            fn wr(addr: usize, val: u32) void {
                @as(*volatile u32, @ptrFromInt(addr)).* = val;
            }
        };
        var pb: [5]u32 = @splat(0);
        pb[0] = 0xADC0_FEE5;
        pb[1] = rd_.r(0x2070_4184);
        pb[2] = rd_.r(0x2010_F83C);
        pb[3] = rd_.r(0x2070_4014);
        pb[4] = rd_.r(0x2070_4054);
        _ = esp_rom_spiflash_erase_sector(0x18B000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18B000, &pb, @intCast(@sizeOf(@TypeOf(pb))));
        flashStage(72);
        // **逐位探测 CSR 0x7a0**（解码 Espressif tdata1 的真实布局）：
        // 每位：写 (读|bit) → 读回 → 记录是否保留。结果 8 字（位图）+ 32 字（原始回读）
        // 落 0x18F000（pre-pmu 窗口）。若 CSR 写有副作用，数据已先行落盘。
        {
            var rb_bits: [32]u32 = @splat(0);
            var keep: u32 = 0; // 位图：bit b = 1 ⇒ 写该位后回读含该位（可写）
            var bp: u32 = 0;
            while (bp < 32) : (bp += 1) {
                const bit: u32 = @as(u32, 1) << @intCast(bp);
                var cur: u32 = undefined;
                asm volatile ("csrr %[v], 0x7a0"
                    : [v] "=r" (cur),
                );
                const wv: u32 = cur | bit;
                asm volatile ("csrw 0x7a0, %[v]"
                    :
                    : [v] "r" (wv),
                );
                asm volatile ("csrr %[v], 0x7a0"
                    : [v] "=r" (cur),
                );
                rb_bits[bp] = cur;
                if ((cur & bit) != 0) keep |= bit;
            }
            // 恢复：写回探测前的值（或已知安全值 0x0）
            var pv: [10]u32 = @splat(0);
            pv[0] = 0xADC0_FEEC;
            pv[1] = keep; // 可写位图
            for (0..32) |k| pv[2 + k] = rb_bits[k]; // 每位探测的回读（截断到 30 位）
            _ = esp_rom_spiflash_erase_sector(0x18F000 / 0x1000);
            _ = esp_rom_spiflash_write(0x18F000, &pv, 32);
        }
        // **干净触发器验证**（只碰已证可读的 CSR；pre-pmu 窗口 flash 可靠）：
        // tinfo 回读；写 tdata1=0x4C → 回读；写 tdata2=0x2f828a78 → 回读；
        // tcontrol(0x7a3)=0x88 写 → 回读（此前读 0 无陷阱）；tselect 回读。
        // 结果 6 字落 0x18F000（此窗口 flash 可靠——stage 72 落地证实）。
        // **改进位探测**（兼容粘滞位语义）：每位先写 0 清场 → 写该位 → 读回 →
        // (rb & bit) 判保留。write-1-to-set 与普通覆盖两种语义都能正确判定。
        {
            var keep: u32 = 0;
            var bp: u32 = 0;
            while (bp < 32) : (bp += 1) {
                const bit: u32 = @as(u32, 1) << @intCast(bp);
                asm volatile ("csrw 0x7a0, zero"); // 清场
                const wv: u32 = bit;
                asm volatile ("csrw 0x7a0, %[v]"
                    :
                    : [v] "r" (wv),
                );
                var rb: u32 = undefined;
                asm volatile ("csrr %[v], 0x7a0"
                    : [v] "=r" (rb),
                );
                if ((rb & bit) != 0) keep |= bit;
            }
            flashStage(92); // 位探测完成 ⇒ 未挂死
            // **keep 位图落盘**（独立扇区 0x189000）：{FEEC, keep}
            var kp: [2]u32 = .{ 0xADC0_FEEC, keep };
            _ = esp_rom_spiflash_erase_sector(0x189000 / 0x1000);
            _ = esp_rom_spiflash_write(0x189000, &kp, 8);
        }
        // **0x7a4/0x7a5 写-回读验证**（RISC-V Debug 规范 0.13 的 tdata1/tdata2 地址）：
        // tdata1(0x7a4) ← 0x4C（Espressif 布局：USER|MACHINE|EXECUTE）
        // tdata2(0x7a5) ← 0x2f828a78（目标地址）
        // 回读相等 ⇒ 找到真触发器 CSR！
        var r4: u32 = undefined;
        var r5: u32 = undefined;
        asm volatile ("li t0, 0x4c");
        asm volatile ("csrw 0x7a4, t0"); // tdata1 = 0x4C
        asm volatile ("csrr %[v], 0x7a4"
            : [v] "=r" (r4),
        );
        asm volatile ("li t0, 0x2f828a78");
        asm volatile ("csrw 0x7a5, t0"); // tdata2 = 地址
        asm volatile ("csrr %[v], 0x7a5"
            : [v] "=r" (r5),
        );
        var v_t1: u32 = undefined;
        var v_t2: u32 = undefined;
        var v_t3: u32 = undefined;
        var v_t4: u32 = undefined;
        var v_t5: u32 = undefined;
        asm volatile ("csrr %[v], 0x7a4"
            : [v] "=r" (v_t1),
        ); // tinfo
        asm volatile ("li t0, 0x4c");
        asm volatile ("csrw 0x7a0, t0"); // tdata1 = 0x4C
        asm volatile ("csrr %[v], 0x7a0"
            : [v] "=r" (v_t2),
        ); // 回读
        asm volatile ("li t0, 0x2f828a78");
        asm volatile ("csrw 0x7a1, t0"); // tdata2 = 地址
        asm volatile ("csrr %[v], 0x7a1"
            : [v] "=r" (v_t3),
        ); // 回读
        asm volatile ("li t0, 0x88");
        asm volatile ("csrw 0x7a3, t0"); // tcontrol
        asm volatile ("csrr %[v], 0x7a3"
            : [v] "=r" (v_t4),
        ); // 回读
        asm volatile ("csrr %[v], 0x7a5"
            : [v] "=r" (v_t5),
        ); // tselect
        var cv: [8]u32 = @splat(0);
        cv[0] = 0xADC0_FEEB;
        cv[1] = v_t1; // tinfo
        cv[2] = v_t2; // tdata1 回读
        cv[3] = v_t3; // tdata2 回读
        cv[4] = v_t4; // tcontrol 回读
        cv[5] = v_t5; // tselect 回读
        cv[6] = r4; // 0x7a4 回读（写 0x4C 后）
        cv[7] = r5; // 0x7a5 回读（写地址后）
        _ = esp_rom_spiflash_erase_sector(0x18F000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18F000, &cv, @intCast(@sizeOf(@TypeOf(cv))));
        // **正确武装序列**（Debug Spec v1.0 地址映射）：
        // tselect(0x7a0) = 触发器 0 → tdata1(0x7a1) = EXECUTE|USER|MACHINE →
        // tdata2(0x7a2) = 0x2f828a78（vendor FE 轮询地址）→ tcontrol(0x7a5) = MTE|MPTE
        // （0xffff0000 dump 已删：load access fault = 未映射 ⇒ 不可执行，问题已答）
        const pmu_init_f = @extern(*const fn () callconv(.c) void, .{ .name = "pmu_init" });
        pmu_init_f();
        // **BT modem clock 使能**（btdm_lp_enable_clock 的核心——此前故意留空）
        // modem_clock_module_enable(6=PERIPH_BT_MODULE) → BLE_CLOCK_DEPS 8 个门
        // modem_clock_module_enable(14=PERIPH_BT_APB_MODULE) → BT_APB_CLOCK_DEPS 4 个门
        // modem_clock_module_mac_reset(6) → BT MAC 复位
        // ⇒ BT BB/RF 硬件获得时钟后 FE 环等待才可能解除
        {
            const mce = @extern(*const fn (u32) callconv(.c) void, .{ .name = "modem_clock_module_enable" });
            const mcmr = @extern(*const fn (u32) callconv(.c) void, .{ .name = "modem_clock_module_mac_reset" });
            mce(6); // PERIPH_BT_MODULE
            mce(14); // PERIPH_BT_APB_MODULE
            mcmr(6); // BT MAC reset
        }
        flashStage(73);
        // **LP-RAM 跨 boot 累积**（0x2E000000，CPU_LOCKUP 复位不清；pmu_init 后才可读）：
        // LP[0]=boot 计数；LP[1..10]=最近 10 轮各自的最深步骤号。
        // 每轮在此转写 flash 0x188000 ⇒ host 一次读到逐轮历史（循环下不再盲）。
        {
            // **LP 魔数守卫**：上电非零垃圾 ⇒ 魔数不符即清零（跨 lockup 存活则保留计数）
            const magic_slot: *volatile u32 = @ptrFromInt(0x2E00_003C);
            if (magic_slot.* != 0x2E00_B007) {
                for (0..11) |k| {
                    @as(*volatile u32, @ptrFromInt(0x2E00_0000 + 4 * k)).* = 0;
                }
                magic_slot.* = 0x2E00_B007;
            }
            lp_boot_n = @as(*volatile u32, @ptrFromInt(0x2E00_0000)).* +% 1;
            @as(*volatile u32, @ptrFromInt(0x2E00_0000)).* = lp_boot_n;
            lpBlackBoxReport(); // 上一轮失声前的最后现场
            for (0..9) |k| {
                lp_hist[k] = @as(*volatile u32, @ptrFromInt(0x2E00_0004 + 4 * k)).*;
            }
            // flash 转写挪到 FEFC 证据块之后（紧跟 flashStage 的写会静默失败）
        }
        var ab: [8]u32 = @splat(0);
        ab[0] = 0xADC0_FEE6;
        ab[1] = rd_.r(0x2070_4184);
        ab[2] = rd_.r(0x2010_F83C);
        ab[3] = rd_.r(0x2070_4014);
        ab[4] = rd_.r(0x2070_4054);
        ab[5] = (@as(*volatile u32, @ptrFromInt(0x2050_1000))).*; // SPI1_CMD pre-BT 基线
        ab[6] = (@as(*volatile u32, @ptrFromInt(0x2050_1010))).*; // CTRL2 对照
        ab[7] = 0; // 保留（b101 标记槽从 0x18C020 起，必须留空）
        _ = esp_rom_spiflash_erase_sector(0x18C000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18C000, &ab, @intCast(@sizeOf(@TypeOf(ab))));
        // **单臂实验**：只写 PMU_RF_PWC（0x20704184 = 0xFFFF0000）一个使能。
        // 若仅此写就导致控制流跳飞（触发器 match≥0x2f828a78 会如实报告），
        // ⇒ 该写的副作用就是根因候选；判据：marker/ring 的位置。
        rd_.wr(0x2070_4184, 0xFFFF_0000);
        // **ana mst 时钟 bit28 恢复**（2026-11-20 深夜新态）：马拉松时代官方链跑过
        // 留下的残留时钟 0x12411290（bit28=1）在彻底断电式复位后被清成 0x02411290，
        // 我们的最小链此前只读不写 ⇒ enable() 挂在模拟主时钟缺失（b103 不落）。
        // 显式置回 bit28——这同时是当年 FE 环"官方 692ms 过、我们过不去"的候选实体。
        {
            const amst = rd_.r(0x2010_F83C);
            if ((amst & (1 << 28)) == 0) rd_.wr(0x2010_F83C, amst | (1 << 28));
        }
        // **BBPLL burst 发车**（2026-11-20 终）：FE 环正点数据（三读全 0、SPI1 空闲、
        // 时钟全开）⇒ 合成器从未被配置。libphy 的
        // `phy_ana_i2c_master_burst_bbpll_config`（零参、自足：command_mem_cfg +
        // burst_config(2)）就是官方链给 RF PLL 发车的 burst 序列。提前显式调一次，
        // 判据：FE3 行 98BC 是否开始变化 / FE spin 是否放行。
        // **RF ON burst 先行**：burst_rf_onoff(a0) 带参（入口 mv s1,a0 实证），
        // 官方链是 rf_onoff(1) → bbpll_config 的次序（RF 供电 burst 先于 PLL 配置）。
        // 上一轮只调了 bbpll_config，缺 RF-ON 前置 ⇒ 合成器仍不锁。
        const burst_rf_onoff = @extern(*const fn (on: c_int) callconv(.c) void, .{ .name = "phy_ana_i2c_master_burst_rf_onoff" });
        const burst_bbpll = @extern(*const fn () callconv(.c) void, .{ .name = "phy_ana_i2c_master_burst_bbpll_config" });
        burst_rf_onoff(1);
        burst_bbpll();
        // **ana I2C master 块只读探测**（DR_REG_I2C_ANA_MST_BASE=0x2010F800）：
        // regi2c 写-回读的前哨——若三读全 FF/stall ⇒ 块不可访问（时钟/电源未到位），
        // burst 写自然 no-op；若可读 ⇒ 块活着，regi2c 死因在事务层。
        // **触发器武装读回**：tselect=0/1/2 的 tdata1——若 chip 只有 1-2 个触发器，
        // 高位 tselect 写会饱和/忽略，读回即知三触发武装是否真实成立。

        var td1: [3]u32 = @splat(0);
        for (0..3) |ti| {
            const t = @as(u32, @intCast(ti));
            asm volatile ("csrw 0x7a0, %[t]"
                :
                : [t] "r" (t),
            );
            var tmp: u32 = 0;
            asm volatile ("csrr %[v], 0x7a1"
                : [v] "=r" (tmp),
            );
            td1[ti] = tmp; // asm 输出操作数不允许下标表达式
        }
        var rc_: [10]u32 = .{
            0xADC0_FEE7,
            rd_.r(0x2070_4184),
            rd_.r(0x2010_F83C),
            0x5BB1_11C4, // burst bbpll 已调标记
            rd_.r(0x2010_F818), // ANA_CONF0
            rd_.r(0x2010_F81C), // ANA_CONF1（STATUS1 在其 bits31:24）
            rd_.r(0x2010_F800), // I2C0_CTRL
            td1[0],
            td1[1],
            td1[2],
        };
        // 恢复 tselect=2（武装的 register_chipv7_phy 触发）
        asm volatile ("li t0, 2");
        asm volatile ("csrw 0x7a0, t0");

        board.hw.flashOpBegin(); // 窗口旗：NMI 打进擦写期时 trap 入口只记录并重试（2026-11-21 实测此处间歇 lockup）
        _ = esp_rom_spiflash_erase_sector(0x18D000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18D000, &rc_, 28);
        board.hw.flashOpEnd();
    }
    // **RISC-V debug trigger（Debug Spec v1.0 映射，写-回读已验证）**——提前到 BT 探测之前：
    // BT 段（bringup.enable/HCI）是已知挂死点，放它后面永远跑不到。
    // LOAD 观察点盯 0x20501000（**bb_init 自旋条件实测**：helper 0x2f80e450
    // `lw a5,0(a4); andi a5,15; bnez` —— 等 (0x20501000 & 0xF)==0；
    // 另一 helper 0x2f80e440 等全零。0x2f80e4d0/e4de 采样 PC 是路过点）。
    // 命中 = 自旋环内，auth_pc 应为 0x2f80e450/e440；trap 快照读它的活值
    // ⇒ 阻塞位到底是什么。
    // **STORE 观察点**：目标 0x2f07f99c（bb_init 真等待点，实测基线 0、自旋时仍 0）。
    // 命中 ⇒ auth_pc = 注册者 PC；不命中 ⇒ 本流程无人写它。
    // （FEFA 轮 LOAD@0x20501000 已证 0x20501000 pre-BT=0、自旋时=0x6992f。）
    const vfe4: u32 = @as(*volatile u32, @ptrFromInt(0x2f07_ffe4)).*;
    const target_addr: u32 = vfe4 +% 36;
    const cur_val: u32 = if (vfe4 != 0) @as(*volatile u32, @ptrFromInt(target_addr)).* else 0xDEAD_0000;
    var base: [4]u32 = .{ 0xADC0_FEFC, vfe4, target_addr, cur_val };
    board.hw.flashOpBegin(); // 窗口旗：NMI 打进擦写期时 trap 入口只记录并重试（2026-11-21 实测此处间歇 lockup）
    _ = esp_rom_spiflash_erase_sector(0x189000 / 0x1000);
    _ = esp_rom_spiflash_write(0x189000, &base, 16);
    board.hw.flashOpEnd();
    // **LP 逐轮历史转写**（落点在 FEFC 之后 —— 该窗口写可靠）：
    // {FEFE, boot_n, hist[0..9], enable步号, 0x404, 0x30, FE三件套+mepc} @0x18A000。
    // [14..17] = NMI 450k 时拍的 0x201098BC/0x201008D0/0x201011AC/mepc（FE 环定位判据）。
    var lrec: [25]u32 = @splat(0);
    lrec[0] = 0xADC0_FEFE;
    lrec[1] = lp_boot_n;
    for (0..9) |k| lrec[2 + k] = lp_hist[k];
    lrec[11] = @as(*volatile u32, @ptrFromInt(0x2E00_002C)).*; // 最后 enter 步号（init+enable）
    lrec[12] = @as(*volatile u32, @ptrFromInt(0x2E00_0404)).*;
    lrec[13] = @as(*volatile u32, @ptrFromInt(0x2E00_0030)).*;
    lrec[14] = @as(*volatile u32, @ptrFromInt(0x2E00_0440)).*;
    lrec[15] = @as(*volatile u32, @ptrFromInt(0x2E00_0444)).*;
    lrec[16] = @as(*volatile u32, @ptrFromInt(0x2E00_0448)).*;
    lrec[17] = @as(*volatile u32, @ptrFromInt(0x2E00_044C)).*;
    lrec[18] = @as(*volatile u32, @ptrFromInt(0x2E00_04A0)).*; // 主上下文最后自旋 PC
    lrec[19] = @as(*volatile u32, @ptrFromInt(0x2E00_0490)).*; // ANA_CONF0 @load_cal
    lrec[20] = @as(*volatile u32, @ptrFromInt(0x2E00_0494)).*; // I2C0_CTRL @load_cal
    lrec[21] = @as(*volatile u32, @ptrFromInt(0x2E00_0498)).*; // ANA_CONF1 @load_cal
    lrec[22] = @as(*volatile u32, @ptrFromInt(0x2E00_049C)).*; // 98BC @load_cal
    lrec[23] = 0xADC0_5FE9; // 格式标记（本扩展版）
    lrec[24] = @as(*volatile u32, @ptrFromInt(0x2E00_0490)).*; // load_cal 返回标记
    board.hw.flashOpBegin(); // 窗口旗：NMI 打进擦写期时 trap 入口只记录并重试（2026-11-21 实测此处间歇 lockup）
    _ = esp_rom_spiflash_erase_sector(0x18A000 / 0x1000);
    _ = esp_rom_spiflash_write(0x18A000, &lrec, 96);
    board.hw.flashOpEnd();
    // **EXEC 断点武装**（2026-11-20 终）：0x2f828a64 = FE 环内指令。MIE 屏蔽下
    // NMI/T0 全哑（上一轮 IDL esp_phy_enable 挂死时零 NMI 行 = MIE 关），而
    // mcontrol6 EXEC match 不受 MIE 影响 ⇒ 若 CPU 在 MIE=0 下执行 FE 环，
    // 断点异常（cause 3）穿透屏蔽，trap 处理器的 "!!" dump 直接给出 mepc/现场。
    asm volatile ("csrw 0x7a5, zero"); // tcontrol = 0（先全关）
    asm volatile ("csrw 0x7a1, zero"); // tdata1 = 0（解除）
    asm volatile ("csrw 0x7a0, zero"); // tselect = 0
    // **单触发（消除数量未知互覆）+ 饱和探测**：只武装 common_clock 入口
    // （esp_phy_enable 内第一个 helper）。UART 直打探测结果（MIE 前置，可靠）。
    asm volatile ("csrw 0x7a0, zero");
    asm volatile ("csrw 0x7a1, t0");
    asm volatile ("li t0, 1");
    asm volatile ("csrw 0x7a0, t0");
    asm volatile ("csrw 0x7a1, t0");
    asm volatile ("csrw 0x7a0, zero"); // 回 trig0
    // tdata1 读回自证（写 0x58 后应读回含 0x58 的值；全 FF/0 ⇒ 触发器不存在）
    var tdl: u32 = 0;
    asm volatile ("csrr %[v], 0x7a1"
        : [v] "=r" (tdl),
    );
    // tselect 饱和探测：写 3 读回——读回 3 ⇒ ≥4 个触发器；读回 <3 ⇒ 更少
    var ts3: u32 = 0;
    asm volatile ("li t0, 3");
    asm volatile ("csrw 0x7a0, t0");
    asm volatile ("csrr %[v], 0x7a0"
        : [v] "=r" (ts3),
    );
    asm volatile ("csrw 0x7a0, zero"); // 回 tselect=0
    asm volatile ("li t0, 0x88");
    asm volatile ("csrw 0x7a5, t0"); // tcontrol（最后开）
    @import("board").hw.rawWrite("bt probe: trig armed tdl=0x");
    // 十六进制后缀（rawWrite 无格式化，分三段拼）
    const hexd = "0123456789abcdef";
    var hx: [8]u8 = undefined;
    var hi: usize = 8;
    var vv = tdl;
    while (hi > 0) : (hi -= 1) {
        hx[hi - 1] = hexd[vv & 0xF];
        vv >>= 4;
    }
    @import("board").hw.rawWrite(&hx);
    @import("board").hw.rawWrite(" tsat3=");
    var hx2: [2]u8 = .{ hexd[(ts3 >> 4) & 0xF], hexd[ts3 & 0xF] };
    @import("board").hw.rawWrite(&hx2);
    @import("board").hw.rawWrite("\n");
    // **武装证据**（直写，不屏蔽 MIE —— pmu 后 flashStage 类写不落地，直写才落地）：
    // {FEF5, tdata1_rb, tdata2_rb, tcontrol_rb} @0x189000。在 ⇒ 观察点已活（本轮独有 magic）。
    var t1v: u32 = undefined;
    var t2v: u32 = undefined;
    var tcv: u32 = undefined;
    asm volatile ("csrr %[v], 0x7a1"
        : [v] "=r" (t1v),
    );
    asm volatile ("csrr %[v], 0x7a2"
        : [v] "=r" (t2v),
    );
    asm volatile ("csrr %[v], 0x7a5"
        : [v] "=r" (tcv),
    );
    // **PC 邻域反汇编 dump**（0x2f 区可直读，dumpRom 先例）：
    // fe_poll: 命中 PC 0x2f828a5c 所在轮询环；rf_pwr: 命中 PC 0x2f00c3e2 所在例程。
    dumpRom("fe_poll", 0x2f828840, 0x2c0); // 扩窗到函数入口（setup 写序列）
    dumpRom("rf_pwr", 0x2f00c3b0, 0x60);
    // bb_init 尾调用目标与两个 helper（本轮自旋真挂点候选）
    dumpRom("tc_tgt", 0x2f8210c0, 0x60);
    dumpRom("helper", 0x2f80e420, 0x40);
    // **ROM 表 ext35/37 的真 fn 候选**（blob 的 BT MAC/BB ISR——顺藤摸 schedule
    // arm 写）：0x2f815258（偶对齐）/0x2f07f19c（wrapper 域）各 0x80。
    dumpRom("isr35", 0x2f815258, 0x80);
    // **任务入口 fn=0x2f000000 之谜**：blob 基址处是什么？可执行代码还是空 RAM？
    dumpRom("base0", 0x2f000000, 0x40);
    dumpRom("base800", 0x2f000800, 0x20); // 对照：trapEntry 在位（我们自己的代码）
    dumpRom("isr37h", 0x2f07f188, 0xB0);
    dumpRom("chead", 0x2f8127ec, 0x50); // 链头 handler 本体：解码 ctx 期望与真 ISR 线索 // 表头完整字 + ctx 槽 0x2f07f1F4（+0x6C）⇒ 覆盖到 0x2f07f238
    // **ROM BT init 区 dump**：找写 0x2f07f1F4（ctx 指针槽）的初始化函数——
    // 离线 grep `lui 0x2f07f` + `sw 500(` 定位 ctx 建立调用。
    dumpRom("btini", 0x2f814000, 0x1000);
    // **ctx 追踪（BB 调度真 ISR 定位）**：h_c 尾部 `jr [ctx+4]`（a1=-3）跳真正
    // 主 ISR——ctx 指针槽在 0x2f07f1F4（h_c 的 lw a0,0x1F4(a5)）。
    {
        const ctxp = @as(*volatile u32, @ptrFromInt(0x2f07f_1F4)).*;
        dumpRom("ctxp", 0x2f07f_1F4, 0x10);
        if (ctxp != 0 and (ctxp & 0x3) == 0) {
            dumpRom("ctx", ctxp, 0x40); // ctx[0..16]：ctx[4]=真主 ISR 地址
            const real_isr = @as(*volatile u32, @ptrFromInt(ctxp + 4)).*;
            osal.logPublic("bt ctx: ctxp=0x{x:0>8} real_isr=0x{x:0>8}", .{ ctxp, real_isr });
        }
    }

    // （bb_init 邻域 dump 已撤：pre-BT 读 0x2f80e4a0 疑似间歇 fault ⇒ 2s 重启循环；
    //  窗口字节已捕获并解码，见 README 附记 1af128e。）

    // **直写进度标记**（post-pmu 可靠通道：FEE6 已擦 0x18C000 扇区，0x18C020 起空闲；
    // 各 8 字 {magic, 值}，不再擦除，host 按 magic 定位最后到达的步）
    const mark = struct {
        var seq: u32 = 0;
        fn put(off: u32, magic: u32, v: u32) void {
            seq +%= 1;
            // **BT 窗口内纯 no-op**（2026-11-21）：enable 之后 LP 域状态已变
            // （modem-sleep/LP 时钟门控），对 LP RAM 槽 0x2E00_0004 的直写会把
            // 总线挂死——所有轮次 "fwd06 ret=0" 之后的第一条语句就是
            // `mark.put(0x80, …)`，而紧随其后的 "post21" 从未打印 ⇒ 楔点即此。
            // 深度标记在 BT 窗口内不再需要（UART + NMI 行足够）。
            if (bt_window_no_flash) return;
            // **直写 LP 槽**：本轮最深步骤号进 LP（RAM 直写，无 flash 失败问题）
            const slot: *volatile u32 = @ptrFromInt(0x2E00_0004 + 4 * ((lp_boot_n - 1) % 10));
            slot.* = seq;
            const pair: [2]u32 = .{ magic, v };
            _ = esp_rom_spiflash_write(0x18C000 + off, &pair, 8);
        }
    };
    // （CSR 扫描已挪到 bringup 之前 —— flash 可用窗口）
    // **init/enable 窗口采样器**：72 样本（~36ms）后 ISR 落盘 0x187000。
    // 此时 controller task 未启动（enable step 20 才建任务）⇒ 落盘无并发风险。
    // 新 regime 下 enable() 内挂死且无 lockup（boot_n 恒 1）⇒ bootloader 会 scribble
    // LP 槽（LP 书签全废），PC 环是唯一深度仪器。
    board.trap.resetPcs();
    board.trap.sample_quiet = true;
    board.trap.pc_dump_at = 0xFFFF_FFFF; // ISR 落盘永久关（撞车根因，2026-11-20）
    // **init 窗口 T0 + NMI**（tick 是 vendor 校准依赖，不能撤）：
    // ISR 的 0x187000 dump 已永久关（pc_dump_at=0xFFFF_FFFF）⇒ 无 flash 竞争。
    // NMI 转换让 register_chipv7_phy 关中断段仍可观测。
    if (!probe_irqs) {
        probe_irqs = true;
        board.hw.routeT0Interrupt(25);
        board.hw.armT0Interrupt(2000);
        board.hw.enableInterrupts();
        const nmi_reg: *volatile u32 = @ptrFromInt(0x1080_1000 + 25 * 4);
        const old_c = nmi_reg.*;
        nmi_reg.* = (old_c & 0x107) | (1 << 3); // nmies 置位（NMI 不受 MIE 屏蔽）
    }
    // **RTC WDT 重臂**（9s 超时，STG0=复位）：init/enable 挂死时 9s 后复位，
    // LP 槽（步号 0x2C + 自旋 PC 0x4A0）跨复位保留，下一轮 FEFE 转写给 host。
    // start.zig 在开机时已禁用 WDT（避免自检 9s 被咬）——这里在 init 前重新武装。
    {
        const cfg0: *volatile u32 = @ptrFromInt(0x2080_1000);
        const feed: *volatile u32 = @ptrFromInt(0x2080_1014);
        const wp: *volatile u32 = @ptrFromInt(0x2080_1018);
        asm volatile ("fence iorw, iorw");
        wp.* = 0x50D8_3AA1;
        feed.* = 0x8000_0000;
        asm volatile ("fence iorw, iorw");
        cfg0.* = (cfg0.* & 0x87FF_FFFF) | 0xA000_0000; // EN(bit31) + STG0=010b(bits30:28)=复位 CPU
        asm volatile ("fence iorw, iorw");
        wp.* = 0;
        asm volatile ("fence iorw, iorw");
        // 自证：读回 CONFIG0 确认 EN+STG0 已置
        const rb = cfg0.*;
        @import("osal_kit").osal.logPublic("bt wdt: config0=0x{x:0>8} en={d} stg0={d}", .{ rb, (rb >> 31) & 1, (rb >> 28) & 7 });
    }
    // **blob 三槽清零（脏 RAM 修复）**：rst:0x1a 不清 RAM ⇒ blob 全局槽跨
    // boot 残留。三槽（0x2f011028/34/38 = 调度 ready 掩码/sleep 对象指针/
    // btdm_cb 指针）清零后首 boot 直达 0x2008 park ✓。
    // ⚠ **全块清零（0x2f011020-047）已否决**（2026-11-21）：十字里 7 个非
    // 槽全局是 blob 跨 boot 依赖的合法状态 ⇒ 全清后无 boot 能过（rst ×12）。
    @as(*volatile u32, @ptrFromInt(0x2f01_1028)).* = 0;
    @as(*volatile u32, @ptrFromInt(0x2f01_1034)).* = 0;
    @as(*volatile u32, @ptrFromInt(0x2f01_1038)).* = 0;
    // ⚠ **btdm_bss/十字块清零均已否决**（2026-11-21 板载 A/B ×2）：清任何
    // blob 状态区（十字 0x2f011020-047 或 btdm_bss 6KB）都导致更差（无 boot
    // 能过 step 20）⇒ **blob 依赖 rst:0x1a 保留 RAM 的跨 boot 接力**（前几
    // boot 的 PHY 校准/调度状态是后续 boot 的前置）。step17 间歇性的来源
    // 另找（PHY/时序 boot 依赖嫌疑最大——前几 boot 校准未完成）。
    @as(*volatile u32, @ptrFromInt(0x2f01_1028)).* = 0;
    @as(*volatile u32, @ptrFromInt(0x2f01_1034)).* = 0;
    @as(*volatile u32, @ptrFromInt(0x2f01_1038)).* = 0;
    // **RTC SOC_WAKEUP 中断路由 + handler**（sleep 唤醒软件半环）：
    // MAP(+0x1fc) 把 MODEM_LP_TIMER 源路由到 CLIC input 6 ⇒ trap 置旗 ⇒
    // 泵循环调已注册的 sleep 回调（主上下文安全）⇒ sleep 完成 ⇒ 分发环退出。
    {
        const intcore: usize = 0x2058_5000;
        const map_reg: *volatile u32 = @ptrFromInt(intcore + 0x1fc);
        const map_def = map_reg.*;
        const wake_input: u32 = 6;
        map_reg.* = wake_input;
        board.trap.rtc_wake_on = true;
        // CLIC input 6 门控：IE(bit8) + prio(bit30:28)=1
        const clic6: *volatile u32 = @ptrFromInt(0x1080_1000 + wake_input * 4);
        clic6.* = (clic6.* & ~@as(u32, 0xFFFF_FFFF)) | (1 << 8) | (1 << 30);
        // RTC 比较武装：target0 = counter + 2s，TAR_EN0 触发，INT_ENA bit31
        const rtb: usize = 0x2080_0000;
        @as(*volatile u32, @ptrFromInt(rtb + 0x10)).* = 1 << 27;
        const cnt: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x1C)).*;
        @as(*volatile u32, @ptrFromInt(rtb + 0x00)).* = cnt +% (137_271 * 2);
        @as(*volatile u32, @ptrFromInt(rtb + 0x04)).* = 0;
        @as(*volatile u32, @ptrFromInt(rtb + 0x08)).* = 1 << 31;
        @as(*volatile u32, @ptrFromInt(rtb + 0x34)).* = 1 << 31;
        @as(*volatile u32, @ptrFromInt(rtb + 0x30)).* = 1 << 31;
        _ = map_def; // （"rtc wake routed" 行已回收：镜像容量紧张；wake_input 别处仍用）
    }
    var rc = bringup.init(&cfg);
    mark.put(0x20, 0xADC0B101, @bitCast(rc));
    // **不写日志的标记**：init 返回后立刻置位。崩溃时若该值仍为 0 ⇒ 崩在 return 路径；
    // 已置位 ⇒ 崩在更晚处。（日志行在本故障下会丢，故用纯 RAM。）
    @import("board").trap.diag_b = 0xB0B0;
    if (rc != 0) {
        osal.logPublic("bt probe: init FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    osal.logPublic("bt probe: init ok {d}", .{0}); // 先打，不碰 arena
    // **rtc_freq 补丁（重新启用，2026-11-21）**：sleep 配置对象（*/0x2f011044）
    // 的 obj[24/28] rtc_freq u64 = 0 ⇒ 调度器时间换算 (us×1e6)/0 除零
    // （mcontrol6 入口断点实测：入口 a2/a3=全零）。controller_init 已建对象
    // ⇒ 此刻写 32000（RTC 32k，同 cfg.ble.rtc_freq）/0 即修复除零。
    // （注：本补丁在 init 返回后执行，不可能影响 step 17 的 rc——此前
    // "step17 rc=-3 归咎补丁"系误读，step17 失败另有原因。）
    {
        // **双候选判别（2026-11-21）**：真 sleep 对象指针 = [0x2f011044]
        // （y5Dip...，blob 于 40062ba2 写 obj+24/28）；[0x2f011034] 为旧假设。
        // 两处都查：仅当 obj[24]==0 且 obj[28]==0（零除活体）才补 32000。
        const cands = [_]usize{ 0x2f01_1044, 0x2f01_1034 };
        for (cands) |cp| {
            const obj: u32 = @as(*volatile u32, @ptrFromInt(cp)).*;
            const tag: []const u8 = if (cp == 0x2f01_1044) "1044" else "1034";
            if (obj >= 0x2f00_0000 and obj < 0x2f10_0000 and obj % 4 == 0) {
                const plo: *volatile u32 = @ptrFromInt(@as(usize, obj) + 24);
                const phi: *volatile u32 = @ptrFromInt(@as(usize, obj) + 28);
                if (plo.* == 0 and phi.* == 0) {
                    plo.* = 32000;
                    phi.* = 0;
                    osal.logPublic("bt probe: rtc_freq patch @{s} obj=0x{x:0>8} +24=32000", .{ tag, obj });
                } else {
                    _ = phi.*;
                    osal.logPublic("bt probe: rtc_freq patch @{s} obj=0x{x:0>8} +24=32000", .{ tag, obj });
                }
            } else {
                osal.logPublic("bt probe: rtc_freq oob @{s} ptr=0x{x:0>8}", .{ tag, obj });
            }
        }
        // **RTC 比较武装（软件半环闭合）**：target0 = counter + 2s ⇒
        // SOC_WAKEUP（INT_ENA+MAP input6 已路由）⇒ trap 置旗 ⇒ 泵调
        // btSleepCb ⇒ sleep 唤醒软件半环闭环。（无条件：不依赖补丁命中）
        const rtb: usize = 0x2080_0000;
        @as(*volatile u32, @ptrFromInt(rtb + 0x10)).* = 1 << 27;
        const cnt: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x1C)).*;
        @as(*volatile u32, @ptrFromInt(rtb + 0x04)).* = 0x8000_0000; // HIGH0=0 | TAR_EN0=1
        @as(*volatile u32, @ptrFromInt(rtb + 0x00)).* = cnt +% (137_271 * 2); // +2s
        @as(*volatile u32, @ptrFromInt(rtb + 0x34)).* = 1 << 31; // INT_CLR
        @as(*volatile u32, @ptrFromInt(rtb + 0x30)).* = 1 << 31; // INT_ENA
        osal.logPublic("bt probe: rtc cmp armed2 cnt=0x{x:0>8}", .{cnt});
    }
    // **udiv 入口 EXEC 断点武装（相位正确版）**：此刻 init_phy 的
    // phy_xtal_duty_cal 除法已过（断点不撞它），LE 块分发等待的磨 CPU
    // 除法尚未开始 ⇒ 命中即磨 CPU 热点本体。one-shot：命中即全清触发器。
    // ⚠ 2026-11-21 关闭：cyclic 9/9 boot 在 step15 后确定性 panic——cblist
    // u64 打印走 __udivmoddi4(ROM 0x400ad7a6)，tdata2 只比对低 32 位入口
    // ⇒ 每轮 logPublic(u64) 即撞断点 ⇒ cause=3 死停。cblist 取证优先。
    // 🔁 2026-11-21 二次改造：init 期武装取消（0x40061c2a 零命中 ×16 ⇒
    // task_deinit 的 unlink 对未执行 ⇒ 摘链者走 blob-ROM）。武装点移至
    // bringup cb14 块（step14 后）：EXEC one-shot 盯 gvLJK4 入口 0x40061376
    // ——step14 后的第一次 unlink 必命中，trap ra = 调用者显形。
    if (false) {
        const addr: u32 = 0x4006_1c2a;
        board.trap.udiv_addr = addr;
        board.trap.udiv_watch_on = true;
        asm volatile ("csrw 0x7a0, zero"); // tselect=0
        asm volatile ("csrw 0x7a2, %[a]"
            :
            : [a] "r" (addr),
        ); // tdata2=入口
        asm volatile ("li t4, 0x4c"); // EXEC|U|M（skill 实测布局）
        asm volatile ("csrw 0x7a1, t4");
        asm volatile ("li t4, 0x88"); // MTE 使能
        asm volatile ("csrw 0x7a5, t4");
        osal.logPublic("bt probe: udiv watch armed @0x{x:0>8}", .{addr});
    }
    // （FEFD 回调表 dump 已删：一次性实验已完成并提交 0328594；
    //  0x188000 现由 LP 逐轮历史 FEFE 使用，勿再写此扇区。）
    // **解除 dump 钩子**：`dumpAtPend` 挂在 `dump_hook` 上，而它在**每次** `mutex_pend`
    // 里被调用（`osal.zig:1059`）；它的 `dump_done` 守卫在函数**末尾**才置位 ⇒
    // 一旦内部不返回就会**每次 pend 重入** ⇒ 把 controller 饿死。
    // bringup 已过观测窗口，这里解除，让运行时路径零开销。
    // **mute=1（层 2 判据轮）**：mute=0 时 0x2006 分发环巨预算 × 每迭代一次
    // log（~µs）⇒ 走不完；mute=1 迭代 µs 级可完成并推进到 0x2008，采样钉
    // blob 区 ⇒ 门控 st 行才有数据。日志内容观察让位给 state 轨迹判据。
    s31_bt_log_mute = 1;
    flashStageExtra(10, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0); // host 可读：init 之后、enable 之前
    osal.dump_hook = null;
    osal.logPublic("bt probe: dump_hook disarmed", .{});
    const af = osal.arenaFree();
    osal.logPublic("bt probe: arena free={d} B", .{af});

    // 3) enable 链（6 步）
    flashStageExtra(11, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0); // 即将调用 enable()
    mark.put(0x28, 0xADC0B102, @bitCast(rc));
    // **T0 武装（init 后）**：NMI 转换让 enable 期（关中断段）仍可观测
    if (!probe_irqs) {
        probe_irqs = true;
        board.hw.routeT0Interrupt(25);
        board.hw.armT0Interrupt(2000);
        board.hw.enableInterrupts();
        const nmi_reg: *volatile u32 = @ptrFromInt(0x1080_1000 + 25 * 4);
        const old_c = nmi_reg.*;
        nmi_reg.* = (old_c & 0x107) | (1 << 3); // nmies 置位（NMI 不受 MIE 屏蔽）
    }
    rc = bringup.enable();
    if (rc != 0) {
        osal.logPublic("bt probe: enable FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    // **从此零 flash 写**：post-enable 的 ROM flash 写 = 与 blob 并发 flash 操作
    // 相撞的楔子源头。标记深度只进 LP 槽（跨复位经 FEFE hist 带出）。
    bt_window_no_flash = true;
    board.trap.pc_dump_at = 0xFFFF_FFFF; // 采样器 ISR 不再触发 0x187000 dump
    mark.put(0x30, 0xADC0B103, @bitCast(rc)); // 此刻起 LP-only
    osal.logPublic("bt probe: enabled (status={d})", .{bringup.getStatus()});

    // 4) 真正进任务（只有第一次用 startScheduler）
    ctrl_task = findFirstTask();
    if (ctrl_task) |t| {
        // 调度器已在 `task_create` 时启动过（FreeRTOS 语义）⇒ 这里不能再调
        // `startScheduler`（它会重置 `main_ctx`）。
        osal.logPublic("bt probe: controller task present (stack={d} B, scheduler started={})", .{ t.stack_size, sched.isStarted() });
    } else {
        osal.logPublic("bt probe: WARN no task was created by r_btdm_task_init", .{});
    }

    // 5) 发第一条命令并泵任务
    osal.logPublic("bt probe: sending HCI Reset", .{});
    mark.put(0x38, 0xADC0B104, 0);
    rc = transport.sendResetViaHs();
    mark.put(0x40, 0xADC0B105, @bitCast(rc));
    osal.logPublic("bt probe: sendReset rc={d}", .{rc});

    // **判别实验**：发第二条**可区分**的命令（Read Local Version，opcode 0x1001）。
    // `evt=2` 且回包 opcode 为 `01 10` ⇒ 命令被逐条处理（`0000` 是 init 遗留事件）；
    // 仍 `evt=1` ⇒ 我们抓到的那条是 blob 自己的 init 事件，命令未被消费。
    rc = transport.sendCmdViaHs(0x1001, &.{});
    osal.logPublic("bt probe: B(hs) sendReadVersion rc={d} stats cmds={d} evt={d}", .{ rc, transport.stats().cmds_sent, transport.stats().evt_count });
    // **A 路径对照**：`sendCmd` 走 `r_btdm_hci_trans_rx`，前置要求 status == ENABLED。
    mark.put(0x48, 0xADC0B106, 0);
    const a_rc = transport.sendCmd(0x1001, &.{});
    mark.put(0x50, 0xADC0B107, transport.stats().btdm_tx);
    osal.logPublic("bt probe: A(rx) sendReadVersion rc={d} stats cmds={d} evt={d}", .{ a_rc, transport.stats().cmds_sent, transport.stats().evt_count });
    // **第二条 A 路径命令**（唯一 opcode 0x0C03）：看 `btdm_tx` 是否 1 → 2。
    mark.put(0x58, 0xADC0B108, 0);
    const a2_rc = transport.sendCmd(0x0C03, &.{});
    mark.put(0x60, 0xADC0B109, transport.stats().btdm_tx);
    osal.logPublic("bt probe: A2(rx) sendReset rc={d} btdm_tx={d}", .{ a2_rc, transport.stats().btdm_tx });
    // **第三条**：再发一次 Read Local Version，**让它成为最后一条** ⇒
    // `tx_head` 捕获的就是它的 12 字节应答（hci_version / manufacturer 等），
    // 用来确认 HCI 通道承载的是**真实数据**而不是桩。
    // **读 BD_ADDR**（`0x1009`）：controller 的公开地址。
    // 一条命令、确定回包（6 字节地址），且是后续 LE 广播的前提。
    mark.put(0x68, 0xADC0B10a, 0);
    const a4_rc = transport.sendCmd(0x1009, &.{});
    mark.put(0x70, 0xADC0B10b, transport.stats().btdm_tx);
    osal.logPublic("bt probe: A4(rx) readBdAddr rc={d} btdm_tx={d}", .{ a4_rc, transport.stats().btdm_tx });

    // **LE 广播 + flash 阶段标记**：每条命令前把阶段写进 `0x186000`，
    // 卡住后从 **host** 读回 —— 不依赖任何日志。
    {
        // **实验：现在重试 `bt_bb_v2_init_cmplx(1)`**。
        // ADR-001 旧记录：它 stall 在 `write 0x20107C80`（WIFI_BB 区）——但那是旧时钟状态
        // （clk_conf1 缺 wifibb 位组）。本轮自旋期快照证实 clk_conf1 已被归档自己开到
        // `0x003FFA8C`（含 wifibb_44m/80m/160x1/wifimac）⇒ 前置条件已变。
        // 用 PC 采样器判读：若再 stall，直接拿挂点地址；端到端判据 marker stage 23 / tx 6。
        // （pmu_init 已提前到 bringup 之前 —— IDF 次序；前/后 PMU 状态在 0x18B/18C 扇区）
        flashStage(73);
        // **采样窗口搬到此处**：esp_phy_enable 若挂，ISR 采 72 个样本后自动落盘 0x187000
        board.trap.resetPcs();
        board.trap.sample_quiet = true;
        board.trap.pc_dump_at = 0xFFFF_FFFF; // BT 窗口零 flash 写：环只留 RAM，不落盘
        if (!probe_irqs) {
            probe_irqs = true;
            board.hw.routeT0Interrupt(25);
            board.hw.armT0Interrupt(2000);
            board.hw.enableInterrupts();
            // **NMI 转换**（与 boot 期 :438-444 相同）：esp_phy_enable 会关中断，
            // 只有 NMI 能看见它关中断后的自旋 —— 这是本窗口的目的所在。
            const nmi_reg: *volatile u32 = @ptrFromInt(0x1080_1000 + 25 * 4);
            const old_c = nmi_reg.*;
            nmi_reg.* = (old_c & 0x107) | (1 << 3); // 保留 bit8(IE)+低3位，置 nmies(bit3)
        }
        flashStage(90); // wait 之后：样本 ≥90 ⇒ 采样活着
        // **等采样器的 ISR dump 完成**（72 次采样触发一次性落盘 0x187000）。
        // 否则 flashStage(64) 的擦写会与 ISR dump **撞车**（ROM spiflash 不可重入）
        // ⇒ marker 写静默失败（这正是 73 之后 64 不落地的机制）。
        // **定长等待**（~1.6s）：给采样器/触发器时间进入 esp_phy_enable 的挂段。
        // 不依赖 pcSampleCount —— 采样器在 72 样本 dump 后已停（活寄存器即可判读）。
        // ⚠ 盲 CTRL2.SYNC_RESET 已删（2026-11-20 末）：零 flash 写窗口下 SPI1 楔子
        // 预期不再形成（楔子 = 我们的 post-enable flash 写撞出来的），盲复位是
        // 唯一死点（panic illegal @0x40069dba，哨兵 s0=0xaddc0002 证明死在它旁边）。
        var wait_dumps: u32 = 0;
        while (wait_dumps < 100_000_000) : (wait_dumps += 1) {
            asm volatile ("nop");
        }
        // **oracle 实验：IDF 本体的 `esp_phy_enable(PHY_MODEM_BT=2)`**
        // WITH_PHY=1 已把 IDF 的 phy_init.c 链进来（`esp_phy_enable` T 符号已确认）。
        // 它内部含我们手写版没有的完整射频使能段（含 analog/regi2c/PMU 路径）。
        // 若这一步之后轮询位能置 ⇒ 缺的就是它；若仍挂 ⇒ 连 IDF 都点不亮这块，
        // 问题在更上游（电源岛/晶振时钟路径）。
        // （WiFi osi 栈块已移除——该路径需要 esp_wifi 归档 = esp-idf 全系统栈）
        const esp_phy_enable = @extern(*const fn (modem: c_int) callconv(.c) void, .{ .name = "esp_phy_enable" });
        mark.put(0xa4, 0xADC0B112, 0); // **调用前标记** ⇒ hist=12 ⇒ 死在 esp_phy_enable 内；hist=11 ⇒ 死在本调用之前（LE 块前半段）
        esp_phy_enable(2); // PHY_MODEM_BT（判别轮的 modem=1 已回退——上轮判别因缺调用前标记而无效）
        mark.put(0x88, 0xADC0B10e, 0); // esp_phy_enable 返回 ⇒ M00e
        flashStageExtra(71, @bitCast(@as(c_int, 0)), 0);
        mark.put(0x90, 0xADC0B10f, 0); // bb_v2_init 调用前 ⇒ M00f
        // **本轮跳过手动 bb_v2_init**（0328594 定案：顺序错误——
        // 回调表项 [a4+36] 需注册步骤填充，手动提前调用 = 永等 + CPU_LOCKUP 循环。
        // 官方链应经由 enable/esp_btbb_enable 在注册之后调用。）
        const bbrc: c_int = -1; // -1 = skipped
        mark.put(0x98, 0xADC0B110, @bitCast(bbrc)); // 跳过 ⇒ 记 -1 ⇒ M10
        flashStageExtra(65, @bitCast(bbrc), 0);
        // ✅ **已实验判定：信道 37 不是原因**（2026-11-19，`0x07` → `0x03` 后 marker 仍 22/5）。
        // 曾怀疑信道 37 = 2402 MHz 走 26 MHz 路径、本板没使能 ⇒ 调谐就挂。
        // 结果：去掉 37 无变化 ⇒ 恢复标准的"三个信道全开"。
        var ap: [15]u8 = .{ 0xA0, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00 };
        // ✅ **已实验判定：地址类型不是原因**（2026-11-19）
        // 试过「0x2005 写随机地址 + own_addr_type=0x01」⇒ marker 仍 `stage=22`
        // （`tx` 从 5 变 6 **只是因为多了一条 0x2005**，不是成功）。
        // ⚠ **判据必须是 `stage == 23`**；只看 `tx` 会把"多发一条命令"误判成"返回了"。
        // ✅ **已实验判定：自置 bit2 无效**（2026-11-19：`0x201098BC |= 4` 后仍 22/5）。
        //    我们的写被丢弃或在归档轮询前被清；而同一区域 0x20109400(CLK_EN) 写 1
        //    能保留 ⇒ "块无时钟"不成立，0x201098BC.bit2 是**硬件状态位**（RF/BB ready）。
        //    ⇒ 机制最终版：0x200A 写配置+启动选通 → 等 RF/BB ready → 位永不置位
        //      （射频使能链不完整）→ 超时错误码 3。见 README「最终机制」。
        var bt_ie_on: bool = false;
        // **ISR 桥 IE 使能（LE 块之前）**：MAC 应答靠 input21 中断投递——
        // IE 若留在泵循环（LE 块之后）⇒ 0x2006 发出后应答永远不来 ⇒ 死等。
        // enable 已返回（任务已启动、桥已挂），此刻开 IE 安全。
        if (!bt_ie_on) {
            bt_ie_on = true;
            // **官方值去掉 SHV 位**（2026-11-21 修正）：官方 `intctl[24]=0x7fc10100`
            // 的 bits14-15 = CLIC 选择性硬件向量化——硬件经 `mtvt[input]` 取入口，
            // IDF 启动代码把 mtvt 指向 SRAM 基址的 `_mtvt_table`（0x2f000040）。
            // 我们裸机链接在该处无表 ⇒ `mtvt[24]` 取到垃圾（实测跳 0x60，被中断
            // 上下文 ra=vibwBXog 调用点）⇒ LOCKUP。改走软件分发（mtvec →
            // trapDispatch → handler[24]），只保留官方优先级 0x7f + IE。
            const ie24: *volatile u32 = @ptrFromInt(0x1080_1000 + 24 * 4);
            ie24.* = 0x7f00_0100;
        }
        // **rx/buf_alloc 共用的 ENABLED 旗**（rx .L50 = li a0,-3 出口；buf_alloc
        // 同门前置）——ctx = [2f011020]，旗 = byte[ctx] bit0。官方由
        // esp_bt_controller_enable 置位；我们直调 r_* 从未置 ⇒ 注入/分配全被拒。
        {
            const hctx: usize = @as(*volatile usize, @ptrFromInt(0x2f01_1020)).*;
            if (hctx >= 0x2f00_0000 and hctx < 0x2f10_0000) {
                const fp: *volatile u8 = @ptrFromInt(hctx);
                const before: u8 = fp.*;
                fp.* |= 1;
                osal.logPublic("bt probe: rx flag {d}->1 ctx=0x{x:0>8}", .{ before, hctx });
            } else {
                osal.logPublic("bt probe: rx ctx oob=0x{x:0>8}", .{hctx});
            }
        }
        mark.put(0x78, 0xADC0B10c, 0);
        // （FE 簇 + SYSCON 窗口一次性快照已回收——对拍结论见 README：FE 8/9 同值、
        //  仅 0x450 异（0x00110000 vs 官方 0x00102000）；镜像容量紧张。）
        // **时钟集合对齐官方 BLE-only**（实验，2026-11-21）：官方 enable 后
        // `clk_conf1(0x20109C14)=0x003FE080`、`0x20109C08=0`；我们的 Wi-Fi 风格
        // PHY 使能多开了 bit2/3(WIFI_BB 44M/80M)、bit9(WIFI_MAC)、bit11(FE_20M)
        // 与 9C08 的 bit2/3/4。fwd06 前按官方值回写，观察 UART/T0 是否仍失声。
        if (align_clk_conf1) {
            const c14: *volatile u32 = @ptrFromInt(0x2010_9C14);
            const c08: *volatile u32 = @ptrFromInt(0x2010_9C08);
            c14.* = 0x003F_E080;
            c08.* = 0;
        }
        _ = diagFlashBlock(0xF00D); // 阳性对照：fwd06 前写一次黑匣子（下次开机必须可见）
        // **存活探针**：武装 RTC WDT（STG0=CPU 复位，约 8–33 s 视慢时钟）。泵每轮喂狗。
        // （RTC WDT 探针已撤：LP 慢时钟在失声态下是否在走未知，改由 HP 域 MWDT1 承担。）
        // **MWDT1 阳性对照**（2026-11-21）：短超时 + 故意 1.5 s 不喂 ⇒ 必须复位并打
        // `rst:0x.. (TG1WDT..)` 旗标；否则此看门狗不可信，"失声后无复位"不构成证据。
        // 复位前在 LP 留旗（跨数字复位保留则下次开机打印 MWDTCTRL OK）。
        // 对照只做一次：LP 旗标（跨数字复位保留）。0xC7C7=对照进行中（被 WDT1 复位后
        // 读到它即"通过"）；0x1234=已通过。EN 复位后 LP 是垃圾 ⇒ 重做对照（无害）。
        const ctrl_flag: *volatile u32 = @ptrFromInt(0x2E00_0310);
        if (ctrl_flag.* == 0xC7C7) ctrl_flag.* = 0x1234;
        if (mwdt_ctrl and ctrl_flag.* != 0x1234) {
            ctrl_flag.* = 0xC7C7;
            osal.lpTrace(3, 0xD2C7);
            const r0 = board.hw.mwdt1Regs();
            board.hw.mwdt1Arm(0x190_0000); // 0.1 s（tick=262.144 MHz，官方 5 s=0x4e200000 实测）
            const r1 = board.hw.mwdt1Regs();
            board.log.line("mwdt: tg1 0x{x:0>8}>0x{x:0>8} core0 0x{x:0>8}>0x{x:0>8} regclk=0x{x:0>8} cfg0=0x{x:0>8}", .{ r0.tg1, r1.tg1, r0.core0, r1.core0, r0.regclk, r1.cfg0 });
            board.hw.delayUs(1_500_000);
            // 没复位 ⇒ 本行之后流程继续（BBT 的 phase 仍为 0xD2C7 即"对照失败"）。
        }
        board.hw.mwdt1Arm(0x9C40_0000); // HP 域看门狗 10 s（tick=262.144 MHz）：主上下文冻结也能复位
        // （ICG 全 1 A/B 已做：无效果，代码撤除。）
        const r6 = transport.sendCmd(0x2006, &ap);
        osal.logPublic("bt probe: fwd06 ret={d}", .{r6});
        osal.lpTrace(3, 0xF001);
        mark.put(0x80, 0xADC0B10d, transport.stats().btdm_tx);
        flashStageExtra(21, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0);
        osal.logPublic("bt probe: post21", .{});
        var ad: [32]u8 = @splat(0);
        ad[0] = 3;
        ad[1] = 2;
        ad[2] = 0x06;
        osal.lpTrace(3, 0xF002);
        const r8 = transport.sendCmd(0x2008, &ad);
        osal.lpTrace(3, 0xF003);
        // **射频状态快照**：`0x200A` 之前把 FE 块的值也存进 flash，
        // 让 host 一次读出"射频是否就绪"，而不只是"停在哪"。
        // **实验：去掉 FE 快照读**。README 与 `tools/jtag-watch-modem-block.sh` 记的
        // 根因症状是"访问 `0x2010B000` 后总线不再应答 —— 无异常、**中断停止、静默**"，
        // 而这个 stage 22 恰好就在 `0x200A` 之前读那两个地址
        // ⇒ 一次改动可同时解释"0x200A 无应答"与"UART 哑"（后者至今未解释）。
        // 另外 word2/3 的 FE 快照**本是噪声**（同构建两次运行就不同），本来也不该当判据。
        // 判据：marker stage/tx（23/6 = 返回了）+ 串口是否恢复。
        // **实验：把 `UART0_STATUS.TXFIFO_CNT` 写进标记**（word2），
        // 以区分"FIFO 满且不排空（发送通道死）"与"FIFO 空（压根没写进去）"。
        // UART0 = 0x2038_A000，STATUS = +0x1C，TXFIFO_CNT = bit[23:16]。
        const uart_st: u32 = (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).*;
        _ = uart_st;
        // **最后两个判据**：
        //   `GPIO_FUNC58_OUT_SEL_CFG`(0x20583BDC)：GPIO matrix 是否把 pad58 改接到别的信号
        //   `UART0.clkdiv_sync`(0x2038A014)：波特率分频（默认 694 = 80 MHz / 115200）
        const osel: u32 = (@as(*volatile u32, @ptrFromInt(0x2058_3BDC))).*;
        const cdiv: u32 = (@as(*volatile u32, @ptrFromInt(0x2038_A014))).*;
        // **判据**：`MODEM_SYSCON.modem_rst_conf`(0x20109C10)
        //   bit9 `rst_wifimac` = 1 ⇒ MAC 一直在复位里 ⇒ 命令永不应答（trap.zig:331-333）
        //   bit8 `rst_wifibb`  = 1 ⇒ BB 在复位里
        const rst_conf: u32 = (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).*;
        _ = rst_conf;
        _ = osel;
        _ = cdiv;
        // **快照自旋环写/轮询的三个寄存器**（MODEM_WIDGETS=0x20109400 私有块）：
        //   W+0x480 = 0x20109880（环里写 0x0FFFFFFF 的那个）
        //   W+0x4A8 = 0x201098A8（写 0）
        //   W+0x4B8 = 0x201098B8（写 a3）
        osal.lpTrace(3, 0xF011); // 读 MODEM_WIDGETS W+0x480/0x4A8 之前
        const w480: u32 = (@as(*volatile u32, @ptrFromInt(0x2010_9880))).*;
        osal.lpTrace(3, 0xF012); // W+0x480 已读
        const w4a8: u32 = (@as(*volatile u32, @ptrFromInt(0x2010_98A8))).*;
        osal.lpTrace(3, 0xF013); // W+0x4A8 已读
        flashStageExtra(22, w480, w4a8);
        // ⚠ **当前是 Enable=1（真正开始广播）**，会挂住 —— 这是**已定位的缺陷**，不是回归。
        // 控制实验（Enable=0）能正常返回（`btdm_tx` 6），那次改动**绝不能留在树里**：
        // 否则烧这个构建会看到"rcA=0、tx=6"，误以为广播通了。
        // （采样窗口已提前到 esp_phy_enable 之前 —— 见 stage 64 处注释）
        // **诊断仪器，出厂/生产构建绝不能开**：
        // 1. 它把 T0 武装到 CLIC input 25（BT 归档的 tick 源）；
        // 2. ISR 会在挂住时**擦写 flash 扇区 0x187000**；
        // 3. 这两者都会改变出厂行为 —— 本文件是 bt-blobs 探针，不含在生产固件里。
        // `sample_quiet = true`：ISR 只记环不打印（UART 不可用，打印会自旋）。
        // ⚠ 武装必须在**这里**做：`probe_irqs` 在 `:432` 的武装点读的是**当时**的值，
        // 那时还是 false ⇒ 只置 true 不会让定时器起来（第一次实测环里是垃圾数据）。
        board.trap.resetPcs();
        board.trap.sample_quiet = true;
        board.trap.pc_dump_at = 0xFFFF_FFFF; // BT 窗口零 flash 写：环只留 RAM，不落盘
        if (!probe_irqs) {
            probe_irqs = true;
            board.hw.routeT0Interrupt(25);
            board.hw.armT0Interrupt(2000);
            board.hw.enableInterrupts();
        }
        // ⛔ **门控扫描已回退**（2026-11-19）：对 clk_en0/modem_ctrl0/widgets-conf 写全 1
        //    会把 modem 搞死（marker 停在 61，0x2006 都挂）—— 这些寄存器的位语义
        //    不是"全开"。且 0x20109880 读回恒 0 但总线正常 ⇒ **疑似只写寄存器**
        //    （同 `modem_rst_conf`："读回恒 0, 只可写"）⇒ **写-回读探针对这块无效**，
        //    判据只能用端到端（stage 23 / btdm_tx 6）。
        // ✅ **MODEM_PWR 分组探测结论**（2026-11-19）：组 1（+0x00..+0x1C，读全 0）能完成，
        //    **组 2（+0x20..+0x3C）把总线读挂**（marker 精确停在 67）⇒ 该电源控制区
        //    在 +0x20 处有锋利的可访问性边界；且总线中毒后连 flash 写都不可靠
        //    （组 1 数据扇区 0x18A000 回读全 ff ⇒ 写未落地）。探测已回退，
        //    基线回到 22/5。下次若要继续，从组 2 的第一个字 +0x20 单字探测。
        var ae: [1]u8 = .{1};
        // **寄存器快照（0x200A 发送前，白名单稀疏）**：evt 到达后差分 ⇒
        // "BB schedule arm 是否发生、动了哪些寄存器"直接可见。
        snapshotRegs();
        osal.lpTrace(3, 0xF014); // snapshotRegs 之后
        snap_valid = true;
        const ra2 = transport.sendCmd(0x200A, &ae);
        osal.lpTrace(3, 0xF015); // sendCmd(0x200A) 之后
        flashStage(23);
        osal.logPublic("bt probe: LE rc6={d} rc8={d} rcA={d} tx={d}", .{ r6, r8, ra2, transport.stats().btdm_tx });
    }
    var round: u32 = 0;
    var evt_at: ?u32 = null;
    var diag_at: u32 = 0;
    var rom_scanned: bool = false;
    var hscan_done: bool = false;
    var bb0_done: bool = false;
    var diag_round: u32 = 0;
    while (true) : (round += 1) {
        // **RTC SOC_WAKEUP 旗**：主上下文调已注册的 sleep 回调（trap 只置旗）
        // **park 相位寄存器读出**（每 300 轮）：MAP 路由 + CLIC in6/in25 门控
        // ——SOC_WAKEUP 旗未置时的三查（路由保留？in6 IE/prio vs in25 形态？）
        if (board.trap.rtc_wake_flag != 0) {
            board.trap.rtc_wake_flag = 0;
            osal.logPublic("bt probe: rtc wake cb fired n={d}", .{board.trap.rtc_wake_n});
            bringup.btSleepCb(0);
        }
        // 单次 kick/轮：配合桩的 256 次限速让出 ⇒ 每轮推进 256 个日志调用
        // （批量 200 kick 版实测 fwd06 后崩溃复位，已回退，见 bringup 桩注释）。
        // **sink 自愈重发布**：每轮重写 [2f010fb4]+[+12]，对冲任何覆写。
        {
            const sink: usize = @intFromPtr(&bringup.log_sink_storage);
            @as(*volatile usize, @ptrFromInt(0x2f01_0fb4)).* = sink;
            @as(*volatile usize, @ptrFromInt(sink + 12)).* = @intFromPtr(&bringup.btLogYieldStub);
            @as(*volatile usize, @ptrFromInt(sink + 28)).* = @intFromPtr(&bringup.btLogYieldStub);
        }
        if (!wdt_suicide) board.hw.mwdt1Feed();
        sched.drainPending(); // 任务/ISR 上下文里延迟的唤醒在这里补做
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        bringup.bridgeDrain(); // ISR 桥主泵半：主上下文代跑 blob handler
        bringup.bridgeReenable(); // 代跑后开回被屏蔽的桥接输入（电平中断的协作闭环）
        osi_impl_serviceTimers(); // ets_timer 协作泵：blob 的调度 tick 源（此前只挂在 osi 内部等待路径，泵循环不经过 ⇒ 定时器永不推进）
        // **RTC counter 锁存触发**：RTC_TIMER 的 counter 读数需要 update 位
        // （+0x10 bit27）触发才刷新——不触发则 controller 读到的 sleep time
        // 恒为陈旧值 ⇒ BB 调度永不到期（fe=0 冻结的候选根因）。每轮锁存一次。
        {
            const rtu: *volatile u32 = @ptrFromInt(0x2080_0010);
            rtu.* = 1 << 27;
        }
        _ = osal.serviceCallouts(osal.timeGet());
        const now = osal.timeGet();
        // **合成器/事务活值采样**（每 ~1s）：98BC.bit2 = RF/BB ready（旧 stage-22
        // 墙的位）；F818.CONF0 bit27 = ana 事务相位（官方在事务完成后清）。
        // 泵窗内的活读数，不经 LP/flash，无下载刮花问题。
        if (round % 200 == 0) {
            diag_at = now;
            // **BB 测量活性判据**（skill：98BC 非判据）：0x47C 0↔0x10000 脉冲
            // + 0x450 振荡 = BB 测量在跑；两者静止 = BB 未启动。
            const m47c: u32 = @as(*volatile u32, @ptrFromInt(0x2010_047C)).*;
            const m450: u32 = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
            const r98 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
            _ = @as(*volatile u32, @ptrFromInt(0x2010_F818)).*; // ANA_CONF0（活值：txphase 已稳定=1 多轮）
            _ = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*; // I2C0_CTRL（活值：本轮诊断行不加，见 burst 快照）
            const fe_cnt = @as(*volatile u32, @ptrFromInt(0x2010_11AC)).*;
            // 任务驻停 PC：swapContext 帧布局 words[12]=ra（sched.zig frame_bytes=64，
            // initContext 对称写 words[12]=trampoline）——任务每轮让出点直接可见。
            const tpc: u32 = if (ctrl_task) |t|
                @as(*volatile u32, @ptrFromInt(t.ctx.sp + 48)).*
            else
                0;
            // CLIC input 60（=BT src 124 的武装入口）原始 intctl 字：
            // bits[31:24]=IP（pending），bit8=IE——看 BB 中断到底有没有提出。
            const st = osal.stats();
            const rtcb: usize = 0x2080_0000;
            @as(*volatile u32, @ptrFromInt(rtcb + 0x10)).* = 1 << 27; // 锁存
            const rtc = @as(*volatile u32, @ptrFromInt(rtcb + 0x14)).*;
            _ = @as(*volatile u32, @ptrFromInt(0x2010_F818)).*; // ANA_CONF0（活值，txphase 已稳定=1 多轮）
            _ = @as(*volatile u32, @ptrFromInt(0x2070_1004)).*; // PO_EN（RC32K OEN 已置，活值不再进诊断行）
            const ts = osi_impl_timerStats();
            const trap = @import("board").trap;
            const h5 = trap.getHandler(5);
            const h5f: usize = if (h5.fn_) |f| @intFromPtr(f) else 0;
            _ = rtc; // 原走已删的 logPublic diag 行（死通道）
            _ = ts;
            _ = h5f;
            _ = m47c; // （泵内 bb 47C/450 行已回收：fwd06 前有 FE 簇完整快照）
            _ = m450;
            // **BB 私有块探读（once）**：0x2010B000。时钟全开后首读——挂死 =
            // BB 块仍被门控（本身就是答案）；可读 = 对照调度寄存器找 arm 差集。
            if (!bb0_done) {
                bb0_done = true;
                const b0: u32 = @as(*volatile u32, @ptrFromInt(0x2010_B000)).*;
                const b4: u32 = @as(*volatile u32, @ptrFromInt(0x2010_B004)).*;
                const b8: u32 = @as(*volatile u32, @ptrFromInt(0x2010_B008)).*;
                const bc: u32 = @as(*volatile u32, @ptrFromInt(0x2010_B00C)).*;
                board.log.line("bt probe: bb0 B000={x:0>8} B004={x:0>8} B008={x:0>8} B00C={x:0>8}", .{ b0, b4, b8, bc });
            }
            // **ana 对拍（官方轨迹：CONF0 2100e408→2900e448、I2C0_CTRL 012f0669
            // →01780369）**：静态=ana I2C 路径死；变化=事务在发。
            // （ana f818/f800/rfpwc 诊断行已回收：镜像容量紧张，读数历次恒定。）
            // ⚠ pmut 读（0x2010F020 LP 域 power_st）已移除——该读在 round200
            // 触发 LP 域总线挂死（盲读 LP 域 = 已知危险）。仅保留 syscon 域读。
            // **ICG 修复实验**：bt_st_map 0x4→0x6（补 MODEM 态不门控，官方
            // icg_config 默认）——写后 BB 时钟域在 MODEM 电源态也保持时钟。
            const icgreg: *volatile u32 = @ptrFromInt(0x2010_9C0C);
            const icg_bt: u32 = (icgreg.* >> 16) & 0xF;
            if (icg_bt == 0x4) icgreg.* = (icgreg.* & ~@as(u32, 0xF0000)) | (0x6 << 16);
            const icg_after: u32 = (icgreg.* >> 16) & 0xF;
            // **槽位/闸门判读行**（2026-11-21）：getok/evrun 判"任务是否消费+
            // handler 是否被调"；c0=ctx[0]（bit0=启用、bit1=BLE 标志）、
            // c32=ctx[32]（回包回调指针）判派发器 .L365 静默闸门。
            var c0: u32 = 0;
            var c32: u32 = 0;
            {
                const ctxp: usize = @as(*volatile usize, @ptrFromInt(0x2f01_1020)).*;
                if (ctxp >= 0x2f00_0000 and ctxp < 0x2f90_0000 and ctxp % 4 == 0) {
                    c0 = @as(*volatile u32, @ptrFromInt(ctxp)).*;
                    c32 = @as(*volatile u32, @ptrFromInt(ctxp + 32)).*;
                }
            }
            board.log.line("bt probe: icg {x}->{x} rfready={d} fe={d} qput={d} getok={d} evrun={d}/{d} pc=0x{x:0>8} sb={d} brg={d}/{d}/{d}", .{
                icg_bt,
                icg_after,
                (r98 >> 2) & 1,
                fe_cnt,
                st.eventq_put,
                st.eventq_get_ok,
                st.event_run_count,
                st.event_run_no_slot,
                tpc,
                bringup.stub_blocks,
                bringup.bridge_w,
                bringup.bridge_ran,
                bringup.bridge_dropped,
            });
            // **盲区诊断块**：UART 失声后仍每轮尝试，成功即止（最多 40 轮）。
            if (!diag_blk_ok and diag_blk_tries < 40) {
                diag_blk_tries += 1;
                diag_blk_ok = diagFlashBlock(@intCast(round));
            }
            osal.lpTrace(3, @as(u32, 0x1_0000) +% @as(u32, @truncate(round)));
            // （自陷复位仪器已结案：确认泵活着/主上下文冻结解除，正式轮不再复位。）
            // （已删）logPublic diag 行：泵期实测 0 输出（死通道），其读数已并入上方 icg 板载行。
            // **ROM 分发 ctx 槽读数**：0x2f07f1F4 → ctx；ctx[4]=真 ISR（全 0 =
            // ROM BT 分发上下文未初始化 = BB 事件链缺口的既有定案，当轮复核）。
            {
                const ctxp: usize = @as(*volatile usize, @ptrFromInt(0x2f07_f1F4)).*;
                osal.logPublic("bt diag: ctxp=0x{x:0>8}", .{ctxp});
                // **HP_SYS ctx 区四字**：0x768 = BB ISR fn（缺口本体）；
                // 0x76C = 状态、0x76A = 使能。写者=官方 init 的 ROM 绑定调用。
                if (ctxp >= 0x0200_0000 and ctxp < 0x0202_0000 and ctxp % 4 == 0) {
                    const w0: u32 = @as(*volatile u32, @ptrFromInt(ctxp + 0x60)).*;
                    const w8: u32 = @as(*volatile u32, @ptrFromInt(ctxp + 0x68)).*;
                    const wfn: usize = @as(*volatile usize, @ptrFromInt(ctxp + 0x68)).*;
                    const wst: u32 = @as(*volatile u32, @ptrFromInt(ctxp + 0x6C)).*;
                    _ = w0;
                    osal.logPublic("bt diag: hpsys+68=0x{x:0>8} fn=0x{x:0>8} st=0x{x:0>8}", .{ w8, wfn, wst });
                } else {
                    osal.logPublic("bt diag: ctxp oob", .{});
                }
            }
            // **自有 handlers 表全扫描（第 4 次 diag 起）**：blob 经
            // intr_handler_set(n,…) 直注的真 ISR 落在哪个外部号——路由正解钥匙。
            diag_round +%= 1;
            if (!hscan_done and diag_round >= 4) {
                hscan_done = true;
                var buf2: [180]u8 = undefined;
                var o2: usize = 0;
                const h2 = "bt hscan:";
                @memcpy(buf2[o2..][0..h2.len], h2);
                o2 += h2.len;
                var cnt2: u32 = 0;
                var ei: usize = 0;
                while (ei < 64 and cnt2 < 6) : (ei += 1) {
                    const hh = trap.getHandler(ei);
                    if (hh.fn_) |f| {
                        const w2 = std.fmt.bufPrint(buf2[o2..], " {d}=0x{x:0>8}", .{ ei, @intFromPtr(f) }) catch break;
                        o2 += w2.len;
                        cnt2 += 1;
                    }
                }
                if (cnt2 == 0) {
                    const none2 = " (all empty)";
                    @memcpy(buf2[o2..][0..none2.len], none2);
                    o2 += none2.len;
                }
                osal.logPublic("{s}", .{buf2[0..o2]});
            }
            // **ROM 表全扫描（第 3 次 diag 起，避 FIFO 早期流量）**：找 blob 直注
            // intr_handler_set 的真 ISR
            diag_round +%= 1;
            if (!hscan_done and diag_round >= 6) {
                hscan_done = true;
                var ei: usize = 0;
                while (ei < 64) : (ei += 1) {
                    const hh = trap.getHandler(ei);
                    if (hh.fn_) |f| {
                        osal.logPublic("bt hscan: ext{d}=0x{x:0>8}", .{ ei, @intFromPtr(f) });
                    }
                }
                osal.logPublic("bt hscan: done", .{});
            }
            if (!rom_scanned and diag_round >= 3) {
                rom_scanned = true;
                var buf: [160]u8 = undefined;
                var n: usize = 0;
                var out: usize = 0;
                const head = "bt romscan:";
                @memcpy(buf[out..][0..head.len], head);
                out += head.len;
                var e: usize = 0;
                while (e < 48) : (e += 1) {
                    const rh = @import("board").trap.romHandler(e);
                    if (rh.fn_) |f| {
                        const fp: usize = @intFromPtr(f);
                        const written = std.fmt.bufPrint(buf[out..], " {d}=0x{x:0>8}", .{ e, fp }) catch break;
                        out += written.len;
                        n += 1;
                        if (n >= 6) break;
                    }
                }
                if (n == 0) {
                    const none = " (all empty)";
                    @memcpy(buf[out..][0..none.len], none);
                    out += none.len;
                }
                osal.logPublic("{s}", .{buf[0..out]});
            }
        }
        if (evt_at == null and transport.stats().evt_count > 0) {
            evt_at = now;
            // **寄存器差分（白名单 vs 活值）**：schedule arm 是否发生直接可见。
            printRegDiff();
            // ⚠ 旧版在此直接 halt ⇒ 广告只开了几毫秒，空中扫描器永远来不及看
            // （Command Complete SUCCESS ≠ 空中有包）。首事件后**继续泵 600 s**
            // 让 BB 广播引擎保持调度，OTA 观测窗留给宿主机/手机 BLE scan。
            osal.logPublic("bt probe: GOT {d} EVT last=0x{x:0>2} — keep pumping 600 s (OTA window)", .{
                transport.stats().evt_count, transport.stats().last_evt_code,
            });
        }
        if (evt_at) |evt_t0| {
            if (now -% evt_t0 > 600_000) break; // timeGet 单位 = ms（tick 驱动）
        } else if (round >= 2000) {
            osal.logPublic("bt probe: no EVT after {d} rounds (evt={d} cmds={d} btdm_tx={d} alloc_null={d} rw_drops={d})", .{
                round, transport.stats().evt_count, transport.stats().cmds_sent, transport.stats().btdm_tx, transport.stats().cmd_alloc_null, @import("board").hw.rw_drops,
            });
            halt();
        }
    }
    osal.logPublic("bt probe: OTA window done (evt={d} cmds={d} btdm_tx={d} rw_drops={d})", .{
        transport.stats().evt_count, transport.stats().cmds_sent, transport.stats().btdm_tx, @import("board").hw.rw_drops,
    });
    halt();
}

/// 把 **osal 记录的归档调用点**打出来（panic 时由 board 调）。
/// 这些返回地址是归档自己的 PC —— 采样被我们的钩子占据时，这是唯一的归档侧落点。
fn dumpOsalCallers() void {
    // 先报"我跑了 + 计数是多少"：分开「钩子没被调用」与「环真的空」。
    // **无条件**输出（不随 code_n 阈值）：这是本轮唯一必须拿到的读数。
    osal.canaryScan();
    osal.arenaWalk();
    board.log.line("A{x}/{d}", .{ g_abort_ra, osal.arenaFree() }); // 极短：调用者/空闲
    {
        var mi: u32 = 0;
        while (mi < @min(osal.malloc_calls, 8)) : (mi += 1) board.log.line("M{d} {d} 0x{x}", .{ mi, osal.mc_sizes[mi], osal.mc_rets[mi] });
    }
    board.log.line("MC {d} sz={d} ret=0x{x}", .{ osal.malloc_calls, osal.last_req_size, osal.last_ret });
    board.log.line("CN 0x{x} 0x{x} {d}", .{ osal.canary_base + osal.canary_first_off, osal.canary_first_val, osal.canary_bad_words });
    // 分配结束（0x2f0206a0）之后 56 个字：区分"连续溢出"与"孤立结构化写入"。
    {
        var k: usize = 0;
        var buf: [224]u8 = undefined;
        var w: usize = 0;
        while (k < 56) : (k += 1) {
            const q: *volatile u32 = @ptrFromInt(0x2f0206a0 + k * 4);
            const n = std.fmt.bufPrint(buf[w..], "{x},", .{q.*}) catch break;
            w += n.len;
        }
        board.log.line("W {s}", .{buf[0..w]});
    }
    if (osal.arena_init_magic != 0) board.log.line("AM {x}", .{osal.arena_init_magic});
    if (code_n > 0) board.log.line("CODES n={d} {s}", .{ code_n, code_ring[0..code_n] });
    board.log.line("panic: lc ours={d} other={d} total={d}", .{ log_hook_ours, log_hook_other, log_hook_calls });
    // **进度落点**（纯 RAM，不受串口丢行影响）
    // **用阻塞写**：panic 现场最不能丢的就是这一行（本会话已多次因丢行误判）
    dumpLine("panic: LASTSTEP {d} {s}", .{ bringup.last_step, bringup.last_step_name });
    board.log.line("panic: osaldump reached n={d}", .{osal.caller_n});
    // s0=0x2f00ffe8 = anchor[6]；把 11 个锚点 + 每个非零锚点的 +8 字段打出来，
    // 直接回答「哪个字段未发布」。0x2f00ffd0 是 anchor[0]。
    var ai: usize = 0;
    while (ai < 11) : (ai += 1) {
        // **不要用硬编码 0x2f00ffd0**：锚点符号地址随镜像布局移动
        // （WITH_PHY=1 版里 anchor[0] 在 0x2f010ee0），必须取符号地址。
        const base: usize = @intFromPtr(&@extern(*volatile u32, .{ .name = "r_sym_bt_pSy5Wex1v0iXw5RdWtwL" }));
        const slot: *const volatile u32 = @ptrFromInt(base + 4 * ai);
        const v = slot.*;
        if (v != 0 and v > 0x2f000000 and v < 0x30000000) {
            const f8: *const volatile u32 = @ptrFromInt(@as(usize, v) + 8);
            board.log.line("panic: anchor[{d}]=0x{x:0>8} +8=0x{x:0>8}", .{ ai, v, f8.* });
        } else {
            board.log.line("panic: anchor[{d}]=0x{x:0>8}", .{ ai, v });
        }
    }
    const n = @min(osal.caller_n, 12);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (osal.caller_n +% osal.caller_ring.len - n + i) % osal.caller_ring.len;
        board.log.line("panic: osalcaller[{d}]=0x{x:0>8}", .{ i, osal.caller_ring[idx] });
    }
}

/// 打印 PC 采样：卡住时这是"它在哪转"的唯一线索。
fn dumpPcs() void {
    var pcs: [48]u32 = @splat(0);
    const n = board.trap.samplePcs(&pcs);
    osal.logPublic("bt probe: pc samples n={d} total={d}", .{ n, board.trap.pcSampleCount() });
    var i: usize = 0;
    while (i < n) : (i += 1) osal.logPublic("bt probe:   pc[{d}]=0x{x:0>8}", .{ i, pcs[i] });
}

/// 按 8 字一行打印一段 ROM（`0x2f8xxxxx` 可直接读）。
fn dumpRom(tag: []const u8, base: usize, len: usize) void {
    board.log.line("rom {s} @0x{x}", .{ tag, base });
    var off: usize = 0;
    while (off < len) : (off += 32) {
        board.log.line("rom {s} +{d:0>2}: {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
            tag,                                    off,
            board.hw.bt_mmio_read(base + off),      board.hw.bt_mmio_read(base + off + 4),
            board.hw.bt_mmio_read(base + off + 8),  board.hw.bt_mmio_read(base + off + 12),
            board.hw.bt_mmio_read(base + off + 16), board.hw.bt_mmio_read(base + off + 20),
            board.hw.bt_mmio_read(base + off + 24), board.hw.bt_mmio_read(base + off + 28),
        });
    }
}

fn findFirstTask() ?*sched.Task {
    // sched 内部有任务表；这里通过一个公开访问器拿第一个已登记任务。
    return sched.firstTask();
}

/// 停机。**周期性重打判决**：单次打印很容易被 128 B 的 UART FIFO 丢弃，
/// 而停机后没有别的输出可以对照 ⇒ 每 ~2 s 重复一次，保证一定能抓到。
fn halt() noreturn {
    const tr = transport.stats();
    var n: u32 = 0;
    while (true) : (n +%= 1) {
        if (n % 2_000_000 == 1) {
            const bs = bringup.stats();
            const le = tr.last_evt;
            // ⚠ **`board.log.line` 只有 200 字节缓冲，超长会 `catch return` 静默丢弃**
            // （`log.zig:19`）⇒ 判决拆成两行，每行都远低于上限。
            @import("board").log.line(
                "bt HALT: evt={d} cmds={d} btdm_tx={d} alloc={d} drops={d} code=0x{x:0>2} fs={d} rc={d}",
                .{ tr.evt_count, tr.cmds_sent, tr.btdm_tx, tr.cmd_alloc_null, @import("board").hw.rw_drops, tr.last_evt_code, bs.failed_step, bs.last_rc },
            );
            @import("board").log.line(
                "bt HALT evt: {x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2}",
                .{ le[0], le[1], le[2], le[3], le[4], le[5] },
            );
            @import("board").log.line(
                "bt HALT tx: t={x} n={d} {x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2}",
                .{ tr.tx_type, tr.tx_len, tr.tx_head[0], tr.tx_head[1], tr.tx_head[2], tr.tx_head[3], tr.tx_head[4], tr.tx_head[5] },
            );
            @import("board").log.line(
                "bt HALT tx2: {x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2}",
                .{ tr.tx_head[6], tr.tx_head[7], tr.tx_head[8], tr.tx_head[9], tr.tx_head[10], tr.tx_head[11] },
            );
        }
        asm volatile ("" ::: .{ .memory = true });
    }
}

// ---------------------------------------------------------------------------
// **host 可读的 flash 标记**（`0x186000` = factory 分区尾部，app.bin 只到 ~0xDB000）
//
// 目的：日志通道不可靠时，仍能让 **host** 知道"流程走到哪一步"——
// `esptool read-flash 0x186000 0x10` 即可，**完全不经过 UART**。
//
// ⚠ **绝不能从 NMI 调用**：ROM 的擦写会在临界区里阻塞取指，
// 而 CPU 正从同一片 flash 执行 XIP ⇒ 会硬挂。只在**主上下文**里调用。
// ---------------------------------------------------------------------------
extern fn esp_rom_spiflash_erase_sector(sector_number: u32) c_int;
/// 把 `pc_ring` 一次性写到 **0x187000**（独立扇区，不碰标记的 0x186000）。
/// `esp_rom_spiflash_write` **不自动擦**（`esp_rom_spiflash.h:257-271`）⇒ 先擦。
/// 只写一次：flash 同址只能 1→0，重复写不会更新。
fn dumpPcRing() void {
    // BT 窗口内零 flash 写（含采样器 ISR 回调路径）——直接返回。
    if (bt_window_no_flash) return;
    // **第零步（本轮新增）：SPI1 忙位采样——必须在任何 flash 擦写之前**。
    // 上一版把三次读放在 FEE0 的擦写之后（µs 级尾随 + ~200ms）仍全 FF；
    // 这里是 1.6s 等待后的第一个动作，窗口内零 flash 操作：若仍 FF ⇒ 忙不是
    // 我们的 marker 写造成的，而是 blob 自己在反复发不完成的 flash 读。
    {
        var srec: [6]u32 = @splat(0);
        srec[0] = 0xADC0_FEE8;
        srec[1] = (@as(*volatile u32, @ptrFromInt(0x2050_1000))).*;
        {
            var d1: u32 = 0;
            while (d1 < 6_250_000) : (d1 += 1) asm volatile ("nop"); // ~100ms 静默
            srec[2] = (@as(*volatile u32, @ptrFromInt(0x2050_1000))).*;
        }
        srec[3] = (@as(*volatile u32, @ptrFromInt(0x2050_1004))).*;
        srec[4] = (@as(*volatile u32, @ptrFromInt(0x2050_1008))).*;
        srec[5] = board.trap.pcSampleCount(); // 窗口归属：>0 ⇒ 任务已自旋
        _ = esp_rom_spiflash_erase_sector(0x18E000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18E000, &srec, @intCast(@sizeOf(@TypeOf(srec))));
    }
    // **两扇区分步**：第一步只落 PC 环 + 现场（不碰可疑块，绝对安全）；
    // 第二步才去读 0x20109xxx —— 若那一步把总线读挂，第一步的数据已安全落盘。
    {
        var buf: [7 + 48]u32 = @splat(0);
        // buf[0] = magic（判布局用）
        buf[0] = 0xADC0_FEE0;
        buf[1] = board.trap.pcSampleCount();
        buf[2] = board.trap.dump_s0;
        buf[3] = board.trap.dump_a0;
        buf[4] = board.trap.dump_a1;
        buf[5] = board.trap.dump_ra;
        _ = board.trap.samplePcs(@ptrCast(buf[6..].ptr));
        _ = esp_rom_spiflash_erase_sector(0x187000 / 0x1000);
        _ = esp_rom_spiflash_write(0x187000, &buf, @intCast(@sizeOf(@TypeOf(buf))));
    }
    // 第二步：**此刻环已在自旋、已写过** ⇒ 读回才是"写了是否生效"的真判据。
    {
        var buf2: [18]u32 = @splat(0);
        buf2[0] = 0xADC0_FEE1;
        buf2[1] = (@as(*volatile u32, @ptrFromInt(0x2010_9880))).*;
        buf2[2] = (@as(*volatile u32, @ptrFromInt(0x2010_98A8))).*;
        buf2[3] = (@as(*volatile u32, @ptrFromInt(0x2010_98B8))).*;
        buf2[4] = 0x0FFF_FFFF; // 环里写出去的期望值，放一起方便比对
        buf2[5] = (@as(*volatile u32, @ptrFromInt(0x2010_9400))).*; // widgets CLK_EN 回读（我们写过 bit0）
        buf2[6] = (@as(*volatile u32, @ptrFromInt(0x2010_98BC))).*; // **被轮询的寄存器本身**（应含 bit2）
        buf2[7] = (@as(*volatile u32, @ptrFromInt(0x2010_9C00))).*; // SYSCON CLK_EN（本轮新开）
        buf2[8] = (@as(*volatile u32, @ptrFromInt(0x2010_9C14))).*; // clk_conf1（对照写入值 0x003ff880）
        buf2[9] = (@as(*volatile u32, @ptrFromInt(0x2010_F000))).*; // LPCON CLK_EN（本轮新开）
        buf2[10] = (@as(*volatile u32, @ptrFromInt(0x2010_D800))).*; // **vendor 等 busy 的寄存器**
        buf2[11] = (@as(*volatile u32, @ptrFromInt(0x2010_F83C))).*; // ana mst 块时钟（应含 bit28）
        buf2[12] = (@as(*volatile u32, @ptrFromInt(0x2070_4184))).*; // PMU_RF_PWC（RF 电路电源）
        buf2[13] = (@as(*volatile u32, @ptrFromInt(0x1080_1064))).*; // **CLIC[25] 读回**：bit3 nmies、bit8 IE —— 定责 NMI 未投递还是被清
        // **SPI1 主 FSM 忙位采样**（0x20501000=SPI1_MEM_C_CMD_REG，MST_ST[3:0]/SLV_ST[7:4]）：
        // 0x2f80e4cc 停点真轮询条件 = (该字 & 0xF)==0（1af128e 解码）。自旋期单点
        // 实测 0x6992f（MST_ST=0xF、SLV_ST=2 send-cmd）。这里隔 ~100ms 连读三次，
        // 判别"我们自己的 marker 写导致的瞬时忙"（三读应回 0）vs"FSM 卡死/门控"（恒 F）。
        buf2[14] = (@as(*volatile u32, @ptrFromInt(0x2050_1000))).*;
        {
            var d1: u32 = 0;
            while (d1 < 6_250_000) : (d1 += 1) asm volatile ("nop"); // ~100ms
            buf2[15] = (@as(*volatile u32, @ptrFromInt(0x2050_1000))).*;
        }
        {
            var d2: u32 = 0;
            while (d2 < 6_250_000) : (d2 += 1) asm volatile ("nop"); // 再 ~100ms
            buf2[16] = (@as(*volatile u32, @ptrFromInt(0x2050_1000))).*;
        }
        buf2[17] = (@as(*volatile u32, @ptrFromInt(0x2050_1004))).*; // 相邻寄存器对照
        _ = esp_rom_spiflash_erase_sector(0x188000 / 0x1000);
        _ = esp_rom_spiflash_write(0x188000, &buf2, @intCast(@sizeOf(@TypeOf(buf2))));
    }
    // **ROM SPI-flash legacy 函数表快照**（0x189000，纯观测）。
    // esp32s31.rom.ld:198：rom_spiflash_legacy_funcs = 0x2f07ffe4。
    // 注意：0x2f80e4cc 停点的真轮询是 [0x20501000]&0xF（1af128e 已解码），
    // 此表与其无关，仅作 flash 驱动状态对照。
    {
        var buf3: [16]u32 = @splat(0);
        buf3[0] = 0xADC0_FEE7;
        const tbl: u32 = (@as(*volatile u32, @ptrFromInt(0x2f07_FFE4))).*;
        buf3[1] = tbl; // 期望 0x2f07f978
        if (tbl >= 0x2f00_0000 and tbl < 0x2f08_0000) {
            buf3[2] = (@as(*volatile u32, @ptrFromInt(tbl + 0x0C))).*; // unlock
            buf3[3] = (@as(*volatile u32, @ptrFromInt(tbl + 0x10))).*; // erase_sector
            buf3[4] = (@as(*volatile u32, @ptrFromInt(tbl + 0x14))).*; // erase_block
            buf3[5] = (@as(*volatile u32, @ptrFromInt(tbl + 0x18))).*; // read
            buf3[6] = (@as(*volatile u32, @ptrFromInt(tbl + 0x1C))).*; // write
            buf3[7] = (@as(*volatile u32, @ptrFromInt(tbl + 0x20))).*; // encrypt_write
            buf3[8] = (@as(*volatile u32, @ptrFromInt(tbl + 0x24))).*;
            buf3[9] = (@as(*volatile u32, @ptrFromInt(tbl + 0x28))).*; // wren
            buf3[10] = (@as(*volatile u32, @ptrFromInt(tbl + 0x2C))).*; // wait_idle
            buf3[11] = (@as(*volatile u32, @ptrFromInt(tbl + 0x30))).*; // erase_area
            buf3[12] = (@as(*volatile u32, @ptrFromInt(tbl + 0x04))).*; // read_sub_len
            buf3[13] = (@as(*volatile u32, @ptrFromInt(tbl + 0x08))).*; // write_sub_len
        }
        _ = esp_rom_spiflash_erase_sector(0x189000 / 0x1000);
        _ = esp_rom_spiflash_write(0x189000, &buf3, @intCast(@sizeOf(@TypeOf(buf3))));
    }
}

extern fn esp_rom_spiflash_write(target_address: u32, src_data: [*]const u32, len_bytes: u32) c_int;

// ⚠ **标记扇区从 0x186000 迁到 0x185000**（2026-11-19 晚）：
// pmu_init 之后 0x186000 的擦写返回成功但数据不落地（同 boot 内其它扇区写均正常，
// 屏蔽/不屏蔽中断都一样）⇒ 该扇区在 pmu 后不可信。host 判读改用 0x185000。
const flash_mark_off: u32 = 0x18_5000;
const flash_mark_magic: u32 = 0x5A17_0000; // 高 16 位是 magic，低 16 位是阶段

/// 把阶段号写入 flash 标记槽。**只能在主上下文调用**。
fn flashStage(n: u32) void {
    if (@import("builtin").target.os.tag != .freestanding) return;
    if (bt_window_no_flash) return; // BT 窗口零 flash 写（SPI1 楔子预防）
    board.hw.flashOpBegin(); // 窗口旗（见 flashStageExtra 的说明）；幂等，嵌套安全
    defer board.hw.flashOpEnd();
    // ⚠ **必须屏蔽中断**：ROM 的擦/写**不替我们屏蔽** MIE，
    // 而擦写期间 flash 控制器忙 ⇒ 此时进中断可能硬 fault 或写坏扇区，
    // 且症状与"LE 卡住"完全一样。`boot-power-perf/src/flash.zig` 的封装
    // 正是用 `Critical`（清 mstatus.MIE）做这件事。
    // ⚠ `erase_sector` 的参数是**扇区号**，不是地址：
    // 传地址会静默擦到无关位置且返回成功。
    // **实验（2026-11-19 晚）：去掉中断屏蔽**。
    // 现象：pmu_init 之后，走本函数（屏蔽 MIE）的 marker 写静默失败，
    // 而不屏蔽的直接写（0x18A000 快照、ISR dump 0x187000）都成功。
    // ⇒ 区别就是 MIE 屏蔽。若不屏蔽后 marker 恢复更新 ⇒ 屏蔽是元凶
    // （pmu_init 改电源/时钟后，屏蔽 MIE 的擦写路径在此时序下会静默失败）。
    // 风险：擦写期间进中断可能硬 fault —— 本窗口内唯一中断源是刚武装的
    // 2ms 采样器，其 ISR 只读寄存器不写 flash，重叠窗口 ≤ 一次擦除。
    const rc_e = esp_rom_spiflash_erase_sector(flash_mark_off / 0x1000);
    var w: [1]u32 = .{flash_mark_magic | (n & 0xFFFF)};
    const rc_w = esp_rom_spiflash_write(flash_mark_off, &w, 4);
    // 失败日志（独立扇区 0x18E000）：{magic2, stage, 失败} ⇒ “没写成”不再静默
    // 第二个字：**计数器快照**，让 host 一次读出"命令有没有被消费"。
    // 高 16 = btdm_tx（应答数），低 16 = evt_count（leEvtTx 事件数）
    {
        const st = @import("transport.zig").stats();
        var c: [1]u32 = .{(@as(u32, st.btdm_tx) << 16) | (st.evt_count & 0xFFFF)};
        _ = esp_rom_spiflash_write(flash_mark_off + 4, &c, 4);
    }
    if (rc_e != 0 or rc_w != 0) {
        var jb: [3]u32 = .{ 0xADC0_FEE4, n, @as(u32, 1) };
        _ = esp_rom_spiflash_erase_sector(0x18E000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18E000, &jb, 12);
    }
}

/// 同 `flashStage`，但额外把两个观察值写进标记扇区的第 3/4 个字。
fn flashStageExtra(n: u32, a: u32, b: u32) void {
    if (@import("builtin").target.os.tag != .freestanding) return;
    // **窗口守卫补全**（2026-11-21）：此前只挡了 flashStage（擦+首写），
    // 本函数自己的两次 esp_rom_spiflash_write 照写——BT 窗口（任务活了之后）
    // 实测楔死在第一条 write（标记扇区 0xFF + NMI 采样仍响应 = 楔在 masked
    // 写内）。零写窗口纪律覆盖到本函数。
    if (bt_window_no_flash) return;
    // **窗口旗包住整段擦写**（2026-11-21）：T0 已配成 NMI（mstatus.MIE 屏蔽不了它），
    // 擦写期打进 trapDispatch（flash XIP）= 取指 fault ⇒ CPU_LOCKUP。旗置位期间
    // trap 入口只记录并 mret 重试（入口在 .trap_ram）。是否命中取决于 NMI 重装节拍
    // 与写窗口的相对时序——同一 build 要么全中要么全不中（实测 43/45 vs 0）。
    board.hw.flashOpBegin();
    defer board.hw.flashOpEnd();
    flashStage(n);
    const prev = asm volatile ("csrrci %[v], mstatus, 8"
        : [v] "=r" (-> usize),
    );
    defer _ = asm volatile ("csrw mstatus, %[v]"
        :
        : [v] "r" (prev),
        : .{ .memory = true });
    var w1: [1]u32 = .{a};
    var w2: [1]u32 = .{b};
    _ = esp_rom_spiflash_write(flash_mark_off + 8, &w1, 4);
    _ = esp_rom_spiflash_write(flash_mark_off + 12, &w2, 4);
}
