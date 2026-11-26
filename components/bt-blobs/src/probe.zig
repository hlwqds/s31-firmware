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
/// 泵循环里的 ets_timer 推进。开 `-Dcoex` 时顺带推进共存核的软件定时器——同一个让出点，
/// 不另加调用；关着时仍是原来的函数，非 coex 探针镜像不变。
const osi_impl_serviceTimers = if (coex_gate.enabled) serviceTimersWithCoex else @import("osi_impl.zig").serviceTimers;
const transport = @import("transport.zig");
const sched = @import("osal_kit").sched;
const porting = @import("porting.zig");
const board = @import("board");
const coex_gate = @import("coex_gate");
/// 共存接线（`-Dcoex`）：`bringup.init` 之前启动共存核，之后各阶段打诊断行。关着时都是空函数。
const coex_wiring = @import("coex_wiring.zig");

fn serviceTimersWithCoex() void {
    @import("osi_impl.zig").serviceTimers();
    @import("osal_kit").coex_hooks.service();
}

/// **轮 32 撤回**：@extern 引用 s_is_phy_calibrated 会激活 phy_init.c.obj 的
/// .sbss → 级联拉出 pmu_init/modem_clock/closed-libphy burst 调用链（全部
/// 未定义死路）。回到 nm 硬编码地址 0x2f010f80（本构建布局稳定，见 nm）。
/// 归档里的 BT 基带初始化（`libbtbb.a` 提供；IDF 的 `esp_btbb_enable` 就是调它）。
/// **blob 台词行环（Zig 侧，安全 .bss）**：bt_printf_shim 经 export 回调写入。
pub var bt_ring: [16][48]u8 align(4) linksection(".bt_lp_data") = @splat(@splat(0));
pub var bt_ring_head: u32 linksection(".bt_lp_data") = 0;
var bt_log_mute: c_int = 0;
var bt_log_dropped: u32 = 0;

export fn s31_bt_log_mute_get() c_int {
    return bt_log_mute;
}

export fn s31_bt_log_dropped_inc() void {
    bt_log_dropped += 1;
}

/// **裸三元组环**（wr_btdm_log_internal_hex 的 (type,len,ptr)——轮 9）。
pub var bt_raw: [16][3]u32 align(4) linksection(".bt_lp_data") = @splat(@splat(0));
pub var bt_raw_head: u32 linksection(".bt_lp_data") = 0;

export fn s31_bt_raw_put(p0: u32, p1: u32, p2: u32) void {
    const slot = &bt_raw[bt_raw_head % bt_raw.len];
    slot[0] = p0;
    slot[1] = p1;
    slot[2] = p2;
    bt_raw_head +%= 1;
}

export fn s31_bt_ring_put(line: [*:0]const u8) void {
    const slot = &bt_ring[bt_ring_head % bt_ring.len];
    var i: usize = 0;
    while (line[i] != 0 and i < slot.len - 1) : (i += 1) slot[i] = line[i];
    slot[i] = 0;
    bt_ring_head +%= 1;
}

extern fn bt_bb_v2_init_cmplx(version_print: c_int) c_int;
/// **轮 49**：官方 mode 分发器（oracle 实证 = enable 语义边界）——
/// a0=0x80000002(BLE) → j yTwwy5 → `r_ble_hci_trans_cfg_ll` 注册 env[32]/[48]。
/// step 17 链只注册不调用 ⇒ 此处按官方语义亲自分发。
extern fn r_sym_ble_FzTWy2M5WtXtifB7Pwt4(mode: u32) callconv(.c) u32;
/// **轮 50**：LL 命令处理入口（cfg_ll 注册对——cmd 入口 / arg=0）；取址镜像写
/// 进 btdm ctx[32]（A 路径门）。ACL 入口 = r_sym_ble_roXDjbaluQmUuwn9uMP8。
extern fn r_sym_ble_FJxPPDsfsgFzTvO2VwlU() callconv(.c) void;
/// **轮 51**：regi2c 读原语（ROM 绝对地址 0x2f8012ec，两镜像同址）。
/// 板上实测调用形如 (reg_add, block_hostid, block)——RF PLL cap = (99,1,6)。
extern fn phy_i2c_readReg(reg: u8, hostid: u8, block: u8) callconv(.c) u8;
/// **轮 57**：ana 写原语（ROM 绝对地址，与 readReg 同族）。
/// **轮 87b 签名修正**：reg-first（与 readReg 同序）——RMW 对实证
/// （phy_bt_tx_pwctrl_init：readReg_Mask(reg=103) 后 writeReg(a0=103,a1=1,a2=28,a3=2)，
/// 读改写必须同寄存器 ⇒ (reg, hostid, block, val)，不是 (block, hostid, reg, val)）。
extern fn phy_i2c_writeReg(reg: u8, hostid: u8, block: u8, val: u8) callconv(.c) void;
/// **轮 51**：RF 电源域开关（ana burst 原语，probe F83C 块尾部已有同款调用）。
extern fn phy_ana_i2c_master_burst_rf_onoff(on: u32) callconv(.c) void;
/// **轮 58**：读 LL 命令静态事件的排队态（wr_ 包装 = 我们镜像内具名符号）。
const wr_btdm_osal_event_is_queued = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wr_btdm_osal_event_is_queued" });
/// **轮 59**：osal 侧 event_init 快照访问（symbol 化，地址无关）。
const osal_last_event_init = @extern(*[48][3]usize, .{ .name = "osal_last_event_init" });
const osal_last_event_init_n = @extern(*usize, .{ .name = "osal_last_event_init_n" });
/// **轮 63b**：event_init 钩子回调——目标槽（*(0x2f01101c)+12）init 的瞬间
/// 武装 Slot.p STORE 观察点（后续 deinit/rebind 写者 → LP 槽三元组）。
/// bringup 钩子注册名（probe_mod 经此引用）。
var evinit_seq: u32 = 0;
/// **轮 67b**：钩子诊断（BSS 计数器，泵期 diag 读出——flash 写路径隔离）
var hook_fired: u32 = 0;
var hook_last_slot: u32 = 0;
var hook_last_fn: u32 = 0;

pub fn bt_hook_event_init3(slot: usize, fn_addr: usize, arg_addr: usize) void {
    onEventInit3(slot, fn_addr, arg_addr);
    // **轮 67：event_init 流水 flash 直写**（16 条轮转，esptool 离线读
    // 0x18C140 起 4 字/条 {magic, slot, fn, arg}）——env+16/20 注册节点真源。
    evinit_seq +%= 1;
    hook_fired +%= 1;
    hook_last_slot = @truncate(slot);
    hook_last_fn = @truncate(fn_addr);
}
pub fn onEventInit3(slot: usize, fn_addr: usize, arg_addr: usize) void {
    _ = fn_addr;
    _ = arg_addr;
    // **轮 63 判决：宽签名武装 = 观察点风暴**（匹配到无关槽 → 反复 trap →
    // halt，mmio trace 实录）。禁用 in-hook 武装；正确姿势 = 先打印 eo 真值
    // （CMD-EVENT 行），再按精确值武装（下一轮）。
    _ = slot;
}

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
var uart_stuck_rounds: u32 = 0;
var uart_mute_done: bool = false;
/// 实验：fwd06 前做一次 MWDT1 阳性对照（短超时不喂 ⇒ 必须复位）。
/// MWDT1 阳性对照开关。**默认关**：对照早已通过，而它的 LP 旗标槽(0x2E000310)
/// 会被下载阶段刮花——垃圾值让 `ctrl_flag != 0x1234` 恒真 ⇒ 对照每个 boot 重跑,
/// 0.1 s WDT + 1.5 s delay ⇒ 每 boot 必咬(实测 rst:0x8 × 46/110s 的真身)。
pub var mwdt_ctrl: bool = false;
var diag_blk_ok: bool = false;
/// **轮 48**：modem_rst_conf(0x2010_9C10) 复断言 OR 锁存——两次诊断行之间
/// 泵每轮读一次并清零释放，锁存 OR 值供诊断行判读"谁在复断言、清了活不活"。
var rst_or: u32 = 0;
/// 轮 51：ana 四件套快照泵首轮打印旗。
var ana_dumped: bool = false;
/// 轮 59：event_init 快照打印旗。
var evinit_dumped: bool = false;
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

/// **UART 失声快照**（0x2E000400，LP RAM）：泵检测到 TXFIFO 卡满时写入并软复位，
/// 下次开机 UART 恢复后读出真实寄存器态（0x2E000400，40 字）。
const uart_mute_magic: u32 = 0xD1A6_4000;
const uart_mute_addr: usize = 0x2E00_0400;
fn uartMuteSnapshot(round: u32) void {
    var b: [40]u32 = @splat(0);
    b[0] = uart_mute_magic;
    b[1] = round;
    for (0..12) |k| b[2 + k] = @as(*volatile u32, @ptrFromInt(0x2038_A000 + 4 * k)).*;
    for (0..7) |k| b[14 + k] = @as(*volatile u32, @ptrFromInt(0x2058_7000 + 4 * k)).*;
    for (0..16) |k| b[21 + k] = @as(*volatile u32, @ptrFromInt(0x2010_9C00 + 4 * k)).*;
    b[37] = @import("board").hw.rw_drops;
    const lp: [*]volatile u32 = @ptrFromInt(uart_mute_addr);
    var k: usize = 1;
    while (k < 40) : (k += 1) lp[k] = b[k];
    lp[0] = uart_mute_magic;
}

/// 开机打印 UART 失声快照（软复位后 UART 已恢复）。
pub fn uartMuteReport() void {
    const lp: [*]volatile u32 = @ptrFromInt(uart_mute_addr);
    if (lp[0] != uart_mute_magic) return;
    board.log.line("BBU round={d}", .{lp[1]});
    for (1..10) |r| {
        board.log.line("BBU {d}: {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ r, lp[4 * r], lp[4 * r + 1], lp[4 * r + 2], lp[4 * r + 3] });
    }
    lp[0] = 0;
}

/// 开机首段：若黑匣子 magic 在，则逐字打印（每行 4 字）并清 magic。
pub fn lpBlackBoxReport() void {
    // LP 追踪槽（0x2E000300）：最后 OSAL 调用者 ra / log-sink 的 blob ra / 探针阶段标记。
    const t: [*]volatile u32 = @ptrFromInt(0x2E00_0300);
    board.log.line("BBT seq={d} osal_ra=0x{x:0>8} sink_ra=0x{x:0>8} phase=0x{x:0>8}", .{ t[0], t[1], t[2], t[3] });
    // **轮 62**：fn_ 字段 STORE 观察点命中槽（0x2E0004D0=PC/4D4=ra/4D8=count）
    {
        const w: [*]volatile u32 = @ptrFromInt(0x2E00_04D0);
        board.log.line("BBT wp2 pc=0x{x:0>8} ra=0x{x:0>8} count={d}", .{ w[0], w[1], w[2] });
        const e16: [*]volatile u32 = @ptrFromInt(0x2E00_04E0);
        board.log.line("BBT env16=0x{x:0>8} env20=0x{x:0>8}", .{ e16[0], e16[1] });
        // **轮 67b**：钩子诊断读出
        board.log.line("BBT hook fired={d} slot=0x{x:0>8} fn=0x{x:0>8} n={d}", .{ hook_fired, hook_last_slot, hook_last_fn, osal_last_event_init_n.* });
    }
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
        // **EVH 行**:活锁计数表(per-boot,开机清零)。
        const et: [*]volatile u32 = @ptrFromInt(0x2E00_0500);
        var evi: usize = 0;
        while (evi < 16) : (evi += 2) {
            if (et[evi] != 0) {
                board.log.line("EVH {x:0>8}/{d}", .{ et[evi], et[evi + 1] });
                board.hw.delayUs(5000); // FIFO 只有 128B,报告行间不排空 ⇒ 后续行被丢
            }
        }
        const al: *volatile u32 = @ptrFromInt(0x2E00_2388);
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
/// **时钟门控基线**(mwdt1Arm 后拍):泵每轮回写,直接检验"哑火=时钟门控"假设。
var clk_snap: [3]u32 = .{ 0, 0, 0 };
var uart_soc_snap: u32 = 0;
fn uartSnapshot() void {
    var i: usize = 0;
    while (i < uart_cmp_words) : (i += 1) uart_snap[i] = @as(*volatile u32, @ptrFromInt(UART0 + 4 * i)).*;
    uart_ctrl0_snap = @as(*volatile u32, @ptrFromInt(CLKRST_UART0_CTRL0)).*;
    uart_soc_snap = @as(*volatile u32, @ptrFromInt(CLKRST_SOC_CLK_SEL)).*;
    uart_snap_ok = true;
}
/// 恢复并返回恢复的字数；首个差分 (offset, was, now) 写入 out。
fn uartRestore(out: *[3]u32, dry: bool) usize {
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
            // **dry=true 只比较**:实测泵内回写会把总线打挂(连 MWDT1/RTC WDT
            // 复位都不再来)——写 UART0 在哑火期是危险动作,证据先行。
            if (!dry) r.* = uart_snap[off / 4];
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
        if (!dry) c0.* = uart_ctrl0_snap;
        n += 1;
    }
    uart_restored += @intCast(n);
    return n;
}

/// **轮 20：SCHED 区补写集**（原 armed 后 → 0x200A 前调用）。
fn schedPatchset() void {
    const wr = struct {
        fn w(addr: usize, val: u32) void {
            @as(*volatile u32, @ptrFromInt(addr)).* = val;
        }
    }.w;
    wr(0x2010_1054, 0x1820_8000);
    wr(0x2010_107c, 0x8000_0000);
    wr(0x2010_10f0, 0x0030_87d0);
    wr(0x2010_10f4, 0x0060_7643);
    wr(0x2010_10f8, 0x0030_74ba);
    wr(0x2010_10fc, 0x0000_087e);
    wr(0x2010_1100, 0x0010_0000);
    wr(0x2010_1104, 0x0000_0011);
    wr(0x2010_1108, 0xffdf_7fff);
    wr(0x2010_1110, 0x0006_b409);
    wr(0x2010_1174, 0x0000_771e);
    wr(0x2010_1178, 0x0000_771e);
    wr(0x2010_117c, 0x0000_8857);
    wr(0x2010_1180, 0x0000_88aa);
    wr(0x2010_1184, 0x0070_0000);
    wr(0x2010_1188, 0x0c00_0041);
    wr(0x2010_11a8, 0x0020_0000);
    wr(0x2010_11ac, 0xa900_0000);
    wr(0x2010_11b8, 0x004e_0000);
    wr(0x2010_11d4, 0x0101_0101);
    wr(0x2010_11e4, 0x0101_0101);
    wr(0x2010_11ec, 0x0101_0101);
    osal.logPublic("bt probe: sched patchset written (22 regs) pre-200A", .{});
}

/// **轮 21b：modem_rst_conf 在 0x200A 前后的值**（冻结点转存进 rec[506..508]）。
pub var rst_conf_pre_200A: u32 = 0;
pub var rst_conf_post_200A: u32 = 0;

/// **轮 43**：sleep env 占位结构（blob sleep 子系统 env 指针的合法 NULL 等价物）
var sleep_env_stub: [256]u8 = undefined;

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

fn preForwardMark() void {
    writeLightMarker(1);
}

/// 轮 13/14：轻量标记（0x18F000，7 字）——phase=0 pre-0x200A / phase=1 pre-forward。
fn writeLightMarker(phase: u32) void {
    const eswL = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
    const eseL = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
    const stL = transport.stats();
    const oL = @import("osal_kit").osal.stats();
    @as(*volatile u32, @ptrFromInt(0x2080_0010)).* = 1 << 27;
    const cntL: u32 = @as(*volatile u32, @ptrFromInt(0x2080_001C)).*;
    // **轮 118**：[8]/[9] = FF（NOR 只能 1→0；post-send 用 esp_rom_spiflash_write
    // 把实际 98BC/F800 写入这两个槽——FF 槽接受任意值）
    var recL: [10]u32 = .{
        0xADC0_BBF4,
        cntL,
        stL.evt_count,
        stL.cmds_sent,
        oL.eventq_put,
        oL.eventq_get_ok,
        @intFromPtr(&cfg.btdm),
        phase,
        0xFFFF_FFFF,
        0xFFFF_FFFF,
    };
    const clicL: usize = 0x1080_1000 + 25 * 4;
    const gL: u32 = @as(*volatile u32, @ptrFromInt(clicL)).*;
    @as(*volatile u32, @ptrFromInt(clicL)).* = gL & ~@as(u32, 0x108);
    _ = eseL(0x18F000 / 0x1000);
    if (@import("builtin").target.os.tag == .freestanding) board.hw.flashOpBegin();
    _ = eswL(0x18F000, &recL, @sizeOf(@TypeOf(recL)));
    if (@import("builtin").target.os.tag == .freestanding) board.hw.flashOpEnd();
    @as(*volatile u32, @ptrFromInt(clicL)).* = gL;
}

/// **轮 119d**：ULP keeper 武装（幂等，可在 bringup.init 前后各调一次）。
/// init 内部的 LP 域动作会把 boot addr 清 0（BOOTADDR 回读实证）⇒ init 后必须重装。
var ulp_prog_snapshot: [60]u8 = @splat(0);
var feed_seq: u32 = 0;

fn ulpKeeperArm(comptime tag: u8) void {
    const ulp_prog = [_]u8{
        // **轮 120w2（v14 60B，格子 LP 0x2E000F00 → DMEM 映射 HP 0x2E0036F8）**：
        // DMEM store = HP 地址 +0x27F8（实证）⇒ HP 读 0x36F8 = 活计数。
        // 程序文本在 IMEM 窗（前 4KB）内 = 取指 ✓。waiti 模式（触发唤醒跑一圈）。
        0x37, 0x1e, 0x00, 0x2e, 0x13, 0x0e, 0x0e, 0xf0,
        0x93, 0x0e, 0x0e, 0x02, 0x37, 0x08, 0xde, 0xc0,
        0xb7, 0x08, 0xde, 0xfa, 0x83, 0x25, 0x0e, 0x00,
        0x85, 0x05, 0xc2, 0x05, 0xc1, 0x81, 0xb3, 0xe5,
        0x05, 0x01, 0x23, 0x20, 0xbe, 0x00, 0x83, 0xa7,
        0x0e, 0x00, 0x85, 0x07, 0xbd, 0x8b, 0xb3, 0xe7,
        0x17, 0x01, 0x23, 0xa0, 0xfe, 0x00, 0x73, 0x00,
        0x50, 0x10, 0xe9, 0xbf,
    };
    // **轮 120b**：向量表！oracle 加载完整 ULP 镜像（0x2E000000-0x7F 向量表
    // +0x80 程序）。裸核 mtvec=0，LP 域任何中断（我们自己 arm 的 RTC timer
    // INT_ENA bit27 就是活源）→ 跳 0x0 → 全零非法 → 崩溃环 = 死。
    // 填 128B mret（0x30200073）：任何 trap 立即返回，程序无感继续。
    var v: usize = 0;
    while (v < 0x80) : (v += 4) {
        @as(*volatile u32, @ptrFromInt(0x2E00_0000 + v)).* = 0x3020_0073;
    }
    // **轮 119p 根因定案**：S31 LP RAM = 4KB（oracle example RESERVE_MEM=4096；
    // oracle 终态 boot_addr=0x2E000080=LP RAM 起+0x80 向量表后）。此前程序放
    // 0x2E001000 = 偏移 4KB = LP RAM 之外 ⇒ 取指必死——118+ 轮「核从未执行」
    // 的真根因。blob 盒最低 0x2E000200，0x80-0xB8 无冲突。
    for (ulp_prog, 0..) |b, i| @as(*volatile u8, @ptrFromInt(0x2E000080 + i)).* = b;
    ulp_prog_snapshot = ulp_prog; // 快照供 POLL 环重写（轮 120p）
    @as(*volatile u32, @ptrFromInt(0x2070_0018)).* = 0x2E000080; // LP_SYS lp_core_boot_addr
    // **轮 119j 全表勘误**（lp_peri_clkrst_reg.h 权威，base=0x20710000）：
    //   CPU_CTRL=+0x4(bit30 clk_force_on/bit31 rst_en)、RAM_CTRL=+0xc(bit30
    //   ram_clk_en 默认1/bit31 ram_rst_en)、INTR_CTRL=+0x28(bit30 intr_clk_en/
    //   bit31 intr_rst_en)。旧代码 intr 写落 CPU_CTRL=无害重复、+0x0 写=保留洞。
    const lpc: usize = 0x2071_0000; // LP_PERI_CLKRST
    const ccp: usize = lpc + 0x4; // CPU_CTRL
    const rcp: usize = lpc + 0xc; // RAM_CTRL
    const icp: usize = lpc + 0x28; // INTR_CTRL
    @as(*volatile u32, @ptrFromInt(rcp)).* |= (1 << 30); // lp_ram_clk_en
    @as(*volatile u32, @ptrFromInt(ccp)).* |= (1 << 30); // lp_core_clk_force_on
    @as(*volatile u32, @ptrFromInt(icp)).* |= (1 << 30); // lp_intr_clk_en
    @as(*volatile u32, @ptrFromInt(ccp)).* = (1 << 31) | (1 << 30); // cpu 复位脉冲(WT)
    @as(*volatile u32, @ptrFromInt(icp)).* |= (1 << 31); // intr 复位脉冲(与 cpu 同步)
    @as(*volatile u32, @ptrFromInt(ccp)).* = (1 << 30); // 释放 cpu 复位
    @as(*volatile u32, @ptrFromInt(icp)).* &= ~@as(u32, 1 << 31); // 释放 intr 复位
    // 清 LP 核复位原因旗（下次 LPCORST 读数只反映本 boot 之后的事件）
    @as(*volatile u32, @ptrFromInt(0x2070_1038)).* = 0;
    // **轮 119i**：LP 根时钟源 force-on（LP_AONCLKRST root_clk_conf @0x20701000：
    // bit28 pll80m / bit29 xtal / bit30 fosc）。裸机跳过 IDF rtc_clk_init，
    // 源全默认 force-on=0 ⇒ 睡眠门控可能把 LP 核唯一时钟源关死。
    @as(*volatile u32, @ptrFromInt(0x2070_1000)).* |= (1 << 28) | (1 << 29) | (1 << 30);
    // **轮 120c oracle 配对流程**：ulp_lp_core_stop() 以 SLEEP_REQ(PWR1 bit31 WT)
    // 把 LP CPU 置入睡态 → load → WAKEUP_EN(PWR2 bit1) → 复位脉冲 →
    // HP_TRIGGER_LP(PWR0..comm +0x1B8 bit31) 唤醒。缺 sleep→wake 配对 = 触发无效。
    @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B0)).* = (1 << 31); // LP CPU SLEEP_REQ
    @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B4)).* |= (1 << 1); // PWR2.WAKEUP_EN bit1
    @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B8)).* = (1 << 31); // HP_TRIGGER_LP(WT) 唤醒
    // **轮 119k**：写后即时回读——分离「写没落地」vs「后被 blob 清」
    const c: u32 = @as(*volatile u32, @ptrFromInt(ccp)).*;
    const r: u32 = @as(*volatile u32, @ptrFromInt(rcp)).*;
    const i: u32 = @as(*volatile u32, @ptrFromInt(icp)).*;
    const ba: u32 = @as(*volatile u32, @ptrFromInt(0x2070_0018)).*;
    board.log.line("ARM{d} cpu={x:0>8} ram={x:0>8} intr={x:0>8} ba={x:0>8}", .{ tag, c, r, i, ba });
}

/// 合并镜像（`-Dcoex-merged`，ADR-003 第 2 节）：BLE controller **只做到 `bringup.init` 返回**。
///
/// 与 `run()` 的区别：
///   - 堆只拿 `region` 这一段（合并镜像按子系统配额切分堆）；
///   - 不做探针的实验与诊断装置：trap 钩子、ROM 取样、调试触发器、flash 标记、LP 核 keeper、
///     RTC 看门狗探针，以及一切对内存布局写死的 RAM 槽（`bringup.layout_probes = false`）；
///   - 共存核不在这里 boot：合并镜像里它由 Wi-Fi 侧启动一次（`init_probe.coexBoot`）。
///
/// 返回 `bringup.init` 的返回码（0 = INITED）。之后 controller 任务阻塞在自己的等待原语上，
/// 要让它继续跑得由调用方去泵（探针的泵在 `run()` 的主循环里）。
pub fn initOnly(region: []u8) c_int {
    bringup.layout_probes = false;
    porting.clock_writes_enabled = clock_writes;
    bringup.skip_task_init = skip_task_init;
    osal.setHooks(.{
        .now_ms = nowMs,
        .log = logHook,
        .irq_save = irqSave,
        .irq_restore = irqRestore,
        // 门控测量（`gate.probeAnchors`）是探针的诊断：每次拿到互斥锁都打几行，这里不装。
    });
    osal.setMacHook(macHook);
    // 时基：不调 `hw.initTimer()` 则 `nowUs()` 恒 0，OSAL 的 `now_ms` 也就恒 0（见 `run()` 里的说明）。
    board.hw.initTimer();
    if (region.len == 0) {
        osal.logPublic("bt init-only: FATAL no heap region", .{});
        return -1;
    }
    osal.initArena(region);
    board.log.line("A{d}K", .{region.len / 1024});
    // osi_impl 的钩子（与 `run()` 相同）：时基与任务让出原语。
    @import("osi_impl.zig").setHooks(.{
        .now_us = @import("board").hw.nowUs,
        .fill_random = null,
        .mac = null,
        .on_idle = osiOnIdle,
        .on_phy_enable = null,
        .on_note = null,
        .on_budget_exhausted = null,
    });
    cfg = config.defaults();
    osal.logPublic("bt init-only: init start", .{});
    const rc = bringup.init(&cfg);
    board.log.line("bt init-only: bringup.init rc={d} arena free={d} B", .{ rc, osal.arenaFree() });
    return rc;
}

/// 合并镜像里 Wi-Fi 先 `esp_wifi_start`（`-Dcoex-wifi-link`）时调用：PHY 已经由 Wi-Fi 打开并标定，BLE 的 init
/// 不再做自己那套"从零打开"的 PHY 序列（`probe_ptr.initPhy`）。必须在 `initOnly` 之前调。
pub fn setPhyOwnedByWifi() void {
    @import("probe_ptr.zig").phy_owned_by_wifi = true;
}

/// 把 blob 改掉的三个时钟门控字写回 `enableOnly()` 拍的基线：blob 在 enable 之后会动 UART0 与定时器组的门控，
/// 不写回去串口与定时器就停了，所以泵的每一轮都做。广播使能之后它不够用（见下面落盘记录一节的注释）。
fn restoreClockGates() void {
    const c2: [*]volatile u32 = @ptrFromInt(0x2058_7000);
    c2[0x88 / 4] = clk_snap[0];
    c2[0x114 / 4] = clk_snap[1];
    c2[0x11C / 4] = clk_snap[2];
}

var pump_rounds: u32 = 0;

/// 合并镜像的实验步骤（`-Dcoex-ble-enable`）：`initOnly` 之后跑 `bringup.enable`，再把 controller 任务泵
/// `max_pump_us` 微秒——它是协作式任务，不泵就不跑。
///
/// 只走生产路径：不发 HCI 命令，也不做 `run()` 里探针的实验（那些要么依赖探针镜像的内存布局，要么就是
/// 通向 synth 那道墙的实验本身）。返回 `bringup.enable` 的返回码（0 = ENABLED）。
pub fn enableOnly(max_pump_us: u64) c_int {
    // 泵之前拍基线：blob 可能把 UART0 / 定时器组的时钟门控改掉，泵每轮照 `run()` 的做法回写。
    const c2: [*]volatile u32 = @ptrFromInt(0x2058_7000);
    clk_snap[0] = c2[0x88 / 4];
    clk_snap[1] = c2[0x114 / 4];
    clk_snap[2] = c2[0x11C / 4];
    const rc = bringup.enable();
    if (rc != 0) {
        board.log.line("bt enable-only: bringup.enable rc={d} at step {d}", .{ rc, bringup.stats().failed_step });
        return rc;
    }
    pumpFor(max_pump_us);
    const st = osal.stats();
    board.log.line("bt enable-only: status={d} rounds={d} evq={d}/{d}/{d} pend_ok={d} busy={d}", .{
        bringup.getStatus(), pump_rounds, st.eventq_put, st.eventq_get_ok, st.eventq_get_empty, st.mutex_pend_ok, st.mutex_pend_busy,
    });
    return rc;
}

/// 协作式泵：让 controller 任务跑 `max_us` 微秒。每轮是 `run()` 主循环里让任务推进的必要项——让出点、
/// ISR 桥的两个半泵、ets_timer、OSAL 的周期回调、两级看门狗、时钟门控回写，每轮一步（`pumpStep`）。
pub fn pumpFor(max_us: u64) void {
    const t0 = board.hw.nowUs();
    pump_rounds = 0;
    while (board.hw.elapsedUs(t0) < max_us) : (pump_rounds += 1) pumpStep();
}

/// 泵的一步。合并镜像（`-Dcoex-wifi-link`）在 Wi-Fi 真实链路的泵里每一步也调它一次，两个控制器在同一个
/// 主循环里轮转。这一步跑在 BLE 任务的栈上，调用方负责在调用期间关掉 Wi-Fi 侧的让出点
/// （`init_probe.foreign_context`）。`clk_snap` 由 `enableOnly()` 在 enable 之前拍好。
pub fn pumpStep() void {
    restoreClockGates();
    board.hw.mwdt1Feed();
    board.hw.feedRtcWdt();
    sched.drainPending();
    if (sched.firstTask()) |t| sched.resumeTask(&t.ctx);
    bringup.bridgeDrain();
    bringup.bridgeReenable();
    osi_impl_serviceTimers();
    // RTC 计数器的读数要靠 update 位触发才刷新；不触发，controller 读到的睡眠时间恒为旧值。
    @as(*volatile u32, @ptrFromInt(0x2080_0010)).* = 1 << 27;
    _ = osal.serviceCallouts(osal.timeGet());
}

// ---------------------------------------------------------------------------
// 合并镜像的 BLE 广播实验（`-Dcoex-ble-adv`）：经 HCI 让 controller 发不可连接广播
// ---------------------------------------------------------------------------

/// synth 区的锁定位：`0x201098BC` 的 bit2。合成器是广播使能命令处理之后才上电的（`coex-verification.md` §14）。
fn synthLock() bool {
    return (@as(*volatile u32, @ptrFromInt(0x2010_98BC)).* & (1 << 2)) != 0;
}

// ---------------------------------------------------------------------------
// HCI 命令的发送任务
// ---------------------------------------------------------------------------
//
// 命令不能从主上下文直接发（2026-11-27）。`r_btdm_hci_trans_rx` 的接收路径带着 FOREVER 去等 controller 任务
// （「rx 阻塞等任务 = 任务等泵」，README 轮 14），而 OSAL 的等待原语只在任务上下文里阻塞：主上下文里的
// `sched.block()` 是把主上下文切回它自己的旧现场，从此没人泵任务、没人喂狗
// （`logs/coex-merged-wifi-link-ble-adv-boot.log`，三次上板都停在这里）。
//
// 所以命令从一个独立栈上的发送任务里发。它阻塞时切回主上下文；主上下文照常泵 controller 任务（`pumpStep`），
// 再把发送任务恢复回来接着跑。两个任务在主循环里轮转，直到 `sendCmd` 返回。等待都是 FOREVER，主循环每一轮把
// 两个任务各恢复一次、让它们重新检查条件——所以不依赖单个等待者槽位的记账（两个任务同时等同一把锁时，
// `mutexPend` 只记得后一个）。
//
// 栈从 BLE 的 arena 里分（`osal.btdmMalloc`）：合并镜像的 SRAM 没有余量再放静态数组。

/// 发送任务的栈：blob 的接收路径自己会用栈，日志格式化另带 128 字节与 202 字节两级缓冲。
const sender_stack_bytes: u32 = 8192;
var sender: ?*sched.Task = null;
/// 命令序号：主循环每交来一条命令加一；发送任务只在序号变了之后才发，被别的事件顺带唤醒时不重发上一条。
var sender_seq: u32 = 0;
var sender_done_seq: u32 = 0;
var sender_opcode: u16 = 0;
var sender_params: []const u8 = &.{};
var sender_rc: c_int = 0;
const SenderPhase = enum { sending, done };
var sender_phase: SenderPhase = .done;
/// 上一条命令卡住了：发送任务还停在 blob 的接收路径里，之后的命令都不再发。
var sender_stalled = false;

fn senderEntry(_: ?*anyopaque) callconv(.c) void {
    sched.block(); // 第一次进来只是登记：等主循环交来第一条命令
    while (true) {
        if (sender_done_seq != sender_seq) {
            sender_done_seq = sender_seq;
            sender_rc = transport.sendCmd(sender_opcode, sender_params);
            sender_phase = .done;
        }
        sched.block();
    }
}

/// 等串口发送 FIFO 排空：只按 FIFO 水位自旋，有界，不依赖定时器。`hw.rawWrite` 等 FIFO 腾位置只等有限几拍，
/// 连着打一串行时后面的半行会被丢；判据行之前先排空，它就不会被前一条回包的 18 行挤掉。
fn uartDrain() void {
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    var spins: u32 = 0;
    while (((status.* >> 16) & 0xFF) != 0 and spins < 60_000_000) : (spins += 1) {}
}

/// 发送任务：第一次用到时建，之后复用。只在广播实验里建（BLE 的 init 之后），所以任务表里排在 controller 任务后面——
/// `pumpStep` 取的是表里第一个任务（`sched.firstTask`），建早了泵到的就是发送任务。
fn senderStart() ?*sched.Task {
    if (sender) |t| return t;
    const mem = osal.btdmMalloc(sender_stack_bytes, 0) orelse {
        board.log.line("bt adv: sender stack alloc({d}) failed", .{sender_stack_bytes});
        return null;
    };
    const task = sched.taskCreate(@as([*]u8, @ptrCast(mem))[0..sender_stack_bytes], senderEntry, null) orelse {
        const ss = sched.stats();
        board.log.line("bt adv: sender task_create failed (table full: created={d} failed={d})", .{ ss.created, ss.created_failed });
        return null;
    };
    sender = task;
    return task;
}

/// 在发送任务里发一条命令，等 `sendCmd` 返回（至多 `timeout_us`，并且至多 `max_rounds` 轮）。
/// 返回 `sendCmd` 的返回码；-8 = 建不了发送任务，-9 = 卡住（判读行紧跟在调用处）。
fn sendFromTask(opcode: u16, params: []const u8, timeout_us: u64, max_rounds: u32) c_int {
    const t = senderStart() orelse return -8;
    if (sender_stalled) return -9;
    sender_opcode = opcode;
    sender_params = params;
    sender_seq +%= 1;
    sender_phase = .sending;
    // 第一次进任务体要经 trampoline 认出入口（`sched.startScheduler` 的约定），之后的恢复只走 `resumeTask`。
    sched.enterAs(&t.ctx);
    sched.resumeTask(&t.ctx);
    const t0 = board.hw.nowUs();
    var rounds: u32 = 0;
    while (sender_phase != .done) : (rounds += 1) {
        if (board.hw.elapsedUs(t0) >= timeout_us or rounds >= max_rounds) {
            sender_stalled = true;
            _ = markerWrite(.stall, opcode, rounds, osal.last_park_kind, @truncate(osal.last_park_ctx), transport.evtSeq());
            uartDrain();
            const ss = sched.stats();
            const os = osal.stats();
            board.log.line("bt adv: cmd 0x{x:0>4} sender stalled after {d} ms, {d} rounds: last park kind={d} ctx=0x{x}", .{
                opcode, board.hw.elapsedUs(t0) / 1000, rounds, osal.last_park_kind, osal.last_park_ctx,
            });
            board.log.line("bt adv: sched created={d} blocks={d} resumes={d} deferred={d} self-drop={d}; osal blocked={d} sem-to={d} evq put/get/empty={d}/{d}/{d} mutex ok/busy={d}/{d}", .{
                ss.created,       ss.blocks,           ss.resumes,    sched.deferred_resumes, sched.self_resume_dropped,
                os.blocked_calls, os.sem_pend_timeout, os.eventq_put, os.eventq_get_ok,       os.eventq_get_empty,
                os.mutex_pend_ok, os.mutex_pend_busy,
            });
            return -9;
        }
        const st_now = rd32(0x2058_7120);
        const gate = rd32(0x2058_7114);
        pumpStep();
        if (sender_phase != .done) sched.resumeTask(&t.ctx);
        if (rounds % 20_000 == 0) {
            _ = markerWrite(.sample, rd32(0x2010_98BC), rd32(0x2010_F800), st_now, transport.evtSeq(), gate);
        }
    }
    return sender_rc;
}

/// 等回包至多泵这么多轮。blob 处理广播命令时会把定时器门控掉，按时间判超时会永远等下去，所以轮数也要封顶
/// （一次 `pumpStep` 是一轮；泵 1 秒实测约 4 万轮）。
const hci_max_rounds: u32 = 1_000_000;

/// 发一条 HCI 命令（在发送任务里，见 `sendFromTask`）并等它的回包（Command Complete 或 Command Status，
/// Vol 4 Part E §7.7.14、§7.7.15）。等待期间照常泵 controller 任务、喂狗。回包是 `transport.lastEvent()` 的
/// 原始帧（下一条事件会覆盖它）；没发出去、或没等到回包，返回 null。
fn hciCommand(opcode: u16, params: []const u8, timeout_us: u64) ?[]const u8 {
    const seq = transport.evtSeq();
    uartDrain();
    board.log.line("bt adv: send 0x{x:0>4} plen={d} (from the sender task)", .{ opcode, params.len });
    _ = markerWrite(.command, opcode, 0x100, rd32(0x2010_98BC), rd32(0x2010_F800), transport.evtSeq());
    if (opcode == 0x200A) marker_frozen = true;
    const rc = sendFromTask(opcode, params, timeout_us, hci_max_rounds);
    if (rc != 0) {
        board.log.line("bt adv: cmd 0x{x:0>4} not sent, rc={d}", .{ opcode, rc });
        _ = markerWrite(.command, opcode, 0x1000 | @as(u32, @intCast(-rc)), rd32(0x2010_98BC), rd32(0x2010_F800), transport.evtSeq());
        return null;
    }
    const t0 = board.hw.nowUs();
    var rounds: u32 = 0;
    while (rounds < hci_max_rounds) : (rounds += 1) {
        board.hw.mwdt1Feed();
        board.hw.feedRtcWdt();
        pumpStep();
        if (transport.evtSeq() != seq) {
            const evt = transport.lastEvent();
            // Command Complete（§7.7.14）：code 0x0E，[2] 是包数，opcode 在 [3..4]，Status 在 [5]；
            // Command Status（§7.7.15）：code 0x0F，Status 在 [2]，opcode 在 [4..5]。
            const lo: u8 = @truncate(opcode);
            const hi: u8 = @truncate(opcode >> 8);
            const complete = evt.len >= 6 and evt[0] == 0x0E and evt[3] == lo and evt[4] == hi;
            const status_evt = evt.len >= 7 and evt[0] == 0x0F and evt[4] == lo and evt[5] == hi;
            if (complete or status_evt) {
                const st = hciStatus(evt, opcode) orelse 0xFF;
                board.log.line("bt adv: cmd 0x{x:0>4} got {s} status=0x{x:0>2} after {d} ms ({d} rounds)", .{
                    opcode,
                    if (complete) "Command Complete" else "Command Status",
                    st,
                    board.hw.elapsedUs(t0) / 1000,
                    rounds,
                });
                _ = markerWrite(.command, opcode, st, rd32(0x2010_98BC), rd32(0x2010_F800), transport.evtSeq());
                return evt;
            }
            // 别的事件：打一行原始字节（至多 8 个八位组），继续等。
            uartDrain();
            var hx: [16]u8 = undefined;
            board.log.line("bt adv: other event while waiting 0x{x:0>4}: n={d} raw={s}", .{
                opcode, evt.len, hciConfHex(&hx, evt[0..@min(evt.len, 8)]),
            });
        }
        if (board.hw.elapsedUs(t0) >= timeout_us) break;
    }
    board.log.line("bt adv: cmd 0x{x:0>4} no reply within {d} ms ({d} rounds)", .{ opcode, timeout_us / 1000, rounds });
    _ = markerWrite(.command, opcode, 0x200, rd32(0x2010_98BC), rd32(0x2010_F800), transport.evtSeq());
    return null;
}

/// 回包里的 Status：Command Complete 在八位组 5，Command Status 在八位组 2。
fn hciStatus(evt: []const u8, opcode: u16) ?u8 {
    const i: usize = if (evt[0] == 0x0E) 5 else 2;
    _ = opcode;
    return if (evt.len > i) evt[i] else null;
}

// ---------------------------------------------------------------------------
// 广播实验的落盘记录（flash `0x18E000`，一个扇区）
// ---------------------------------------------------------------------------
//
// 广播使能命令的处理会把 UART0 与定时器组的时钟门控掉（README 轮 96–117："时钟收缩"），之后串口上一个字也
// 出不来：主循环还在不在跑、合成器有没有起，从串口都看不出（`logs/coex-merged-wifi-link-ble-adv2-boot.log`
// 停在 `0x200A` 之后）。所以每一步往这个扇区写一条 32 字节的记录。
//
// - 扇区位置：factory 分区结束于 `0x187000`、`ota_0` 从 `0x190000` 起，`0x187000–0x18FFFF` 不属于任何分区
//   （`firmware/idf-bootstrap/partitions.csv`）。独立探针的标记用的是 `0x187000`–`0x18F000` 里别的扇区。
// - 发命令之前先擦：NOR 写只把 1 变 0，擦过的扇区每一格只能写一次，所以记录按槽位顺排，不回头改。
// - 主机侧用 `esptool read_flash 0x18E000 0x1000` 读（会让板子复位），`tools/ap-side/decode-adv-marker.py` 解码。
// - **广播使能的"正要发"之后再不写**（`ble-adv3` 到 `ble-adv7` 几轮定下来的）：回包之后主上下文就停在 ROM 的
//   `esp_rom_spiflash_write` 里面。写之前先把泵的三个门控字和 SYS_TIMER 的时钟使能写回（`ble-adv4` 那一轮的镜像），
//   再把单独探针第 112 轮的整套回写补上——MODEM_CONF、CLK_CONF、CLK_CONF1、LP_CLK_CONF 写回发命令之前读到的值
//   （`ble-adv5` 那一轮，记录 `logs/coex-merged-wifi-link-ble-adv5-marker.txt`）——记录都停在"正要发"。所以 `0x200A`
//   的"正要发"之后落盘记录冻结（`marker_frozen`），之后的采样只留在 RAM 里、经串口打出来。这份记录的边界因此是：
//   它回答"命令发到哪、回没回"，回答不了广播使能之后的状态。
// - 写的时候关全局中断：镜像里武装着 Wi-Fi blob 的输入，trap 入口在 flash 窗口里只记录不分发
//   （`hw.flashOpBegin`），电平挂起的输入会原地打转。

const marker_base: u32 = 0x18E_000;
const marker_words: usize = 8;
const marker_slots: usize = 0x1000 / (marker_words * 4);
var marker_next: usize = 0;
/// 广播使能的"正要发"之后再不碰 ROM 的 flash 例程（见上面的文件头注释）：置位后 `markerWrite` 只计数。
var marker_frozen = false;
var marker_skipped: u32 = 0;

/// 冻结之后的采样留在 RAM 里（广播使能之后每 250 ms 或每 20000 轮一条，留最早的 24 条），收尾时经串口打出来。
const Sample = struct { polls: u32, synth: u32, f800: u32, systimer: u32, gate: u32, evt_seq: u32 };
const sample_ring = 24;
var samples: [sample_ring]Sample = @splat(.{ .polls = 0, .synth = 0, .f800 = 0, .systimer = 0, .gate = 0, .evt_seq = 0 });
var sample_n: usize = 0;

const MarkerKind = enum(u32) {
    /// `a` = 启动时读到 `0x201098BC`、`b` = `0x2010F800`、`c` = OSAL 的 `eventq_put`、`d` = 事件序号、`e` = 0。
    boot = 1,
    /// `a` = opcode、`b` = 0x100（正要发）/ 0x1000 + 错误码（没发出去）/ 0x200（没等到回包）/ 回包里的 Status，
    /// `c` = `0x201098BC`、`d` = `0x2010F800`、`e` = 事件序号。
    command = 2,
    /// 等一条命令（发送或回包）每 20000 轮一条：`a` = `0x201098BC`、`b` = `0x2010F800`、
    /// `c` = `0x20587120`（SYSTIMER_CTRL0）、`d` = 事件序号、`e` = `0x20587114`。广播使能之后不再落盘，采样只在 RAM 里。
    sample = 3,
    /// `a` = `0x201098BC`、`b` = `0x2010F800`、`c` = 轮数、`d` = 锁定位为 1 的轮数、`e` = 事件序号。
    final = 4,
    /// synth 区与 ANA：`a` = `0x201098C0`、`b` = `0x201098B8`、`c` = `0x2010F818`、`d` = `0x2010F81C`、`e` = `0x20109C04`。
    radios = 5,
    /// synth 区前半：`a`–`d` = `0x20109880`、`0x20109884`、`0x20109888`、`0x2010988C`、`e` = `0x201098A8`。
    synth = 6,
    /// 发送任务卡住：`a` = opcode、`b` = 轮数、`c` = 最近一次停下的等待原语（1 sem / 2 mutex / 3 eventq）、
    /// `d` = 那个上下文的地址、`e` = 事件序号。
    stall = 7,
};

fn markerErase() void {
    const ese = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
    board.hw.disableInterrupts();
    board.hw.flashOpBegin();
    const rc = ese(marker_base / 0x1000);
    board.hw.flashOpEnd();
    board.hw.enableInterrupts();
    marker_next = 0;
    board.log.line("bt adv: marker sector 0x{x:0>6} erased, rc={d}", .{ marker_base, rc });
}

/// 写一条记录（只写没写过的槽）。扇区写满就不写，返回 null。
fn markerWrite(kind: MarkerKind, a: u32, b: u32, c: u32, d: u32, e: u32) ?usize {
    if (marker_frozen) {
        marker_skipped += 1;
        return null;
    }
    if (marker_next >= marker_slots) return null;
    const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
    const idx: u32 = @intCast(marker_next);
    const rec = [marker_words]u32{ 0x4144_5621 ^ idx, @backingInt(kind), idx, a, b, c, d, e };
    board.hw.disableInterrupts();
    board.hw.flashOpBegin();
    _ = esw(marker_base + idx * (marker_words * 4), &rec, marker_words * 4);
    board.hw.flashOpEnd();
    board.hw.enableInterrupts();
    marker_next += 1;
    return marker_next - 1;
}

pub const AdvResult = struct {
    params_status: ?u8 = null,
    data_status: ?u8 = null,
    enable_status: ?u8 = null,
    /// 广播使能之后泵了多少轮、其中 synth 锁定位为 1 的轮数、第一次为 1 距离使能命令多久。
    polls: u32 = 0,
    locked_polls: u32 = 0,
    first_lock_us: ?u64 = null,
    synth_98bc_last: u32 = 0,
};

/// 合并镜像的实验步骤（`-Dcoex-ble-adv`）：`enableOnly` 之后发三条 HCI 命令——LE Set Advertising
/// Parameters（间隔 `interval_units`，0x20-0x4000，1.25 ms 一档，Vol 4 Part E §7.8.5）、LE Set Advertising
/// Data（§7.8.7，Flags + 名字 `s31`）、LE Set Advertising Enable（§7.8.9）——然后把 controller 任务泵 `wait_us`
/// 微秒，每轮读一次 synth 锁定位。调用方负责在调用期间关掉 Wi-Fi 侧的让出点。
pub fn advertiseOnly(interval_units: u16, wait_us: u64) AdvResult {
    var r: AdvResult = .{};
    markerErase();
    _ = markerWrite(.boot, rd32(0x2010_98BC), rd32(0x2010_F800), osal.stats().eventq_put, transport.evtSeq(), 0);

    var p: [15]u8 = @splat(0);
    p[0] = @truncate(interval_units);
    p[1] = @truncate(interval_units >> 8);
    p[2] = p[0];
    p[3] = p[1];
    p[4] = 0x03; // ADV_NONCONN_IND（§7.8.5：Advertising_Type）
    // 其余：自身地址类型 public（5）、对端地址类型 public（6）、对端地址全 0（7-12）、
    // 信道图 0x07（13：37 / 38 / 39 三个广播信道都开）、过滤策略 0（14）。
    p[13] = 0x07;
    if (hciCommand(0x2006, &p, 2_000_000)) |e| r.params_status = hciStatus(e, 0x2006);

    var d: [32]u8 = @splat(0);
    d[0] = 8; // Advertising_Data_Length
    d[1] = 0x02; // Flags 的长度
    d[2] = 0x01; // AD type: Flags
    d[3] = 0x06; // LE General Discoverable + BR/EDR Not Supported
    d[4] = 0x04; // Complete Local Name 的长度：类型 1 + 名字 3（长度只数它后面跟着的字节）
    d[5] = 0x09; // AD type: Complete Local Name
    @memcpy(d[6..9], "s31");
    if (hciCommand(0x2008, &d, 2_000_000)) |e| r.data_status = hciStatus(e, 0x2008);

    const t_en = board.hw.nowUs();
    if (hciCommand(0x200A, &.{0x01}, 2_000_000)) |e| r.enable_status = hciStatus(e, 0x200A);

    const t0 = board.hw.nowUs();
    var t_s = t0;
    // 时长上限另按 CPU 的周期数计一次：广播使能之后定时器可能被门控，按时间判就等不到头；轮数上限是 100 万轮，
    // 在那之后要跑多久没有数。400 M 个周期在 160–262 MHz 上是 1.5–2.5 秒。实测这个上限并没有派上用场
    // （`ble-adv7`、`ble-adv8` 两轮）：回包之后主上下文没有走出这个循环的第一轮——AP 的 monitor 接口上板子的帧到
    // 第一次断开为止，没有第二次关联，串口停在那条回包行的一半。
    const adv_cycle_budget: u64 = 400_000_000;
    const sample_cycles: u64 = 25_000_000;
    const c_start = board.hw.cycleCount();
    var c_s = c_start;
    while (board.hw.elapsedUs(t0) < wait_us and r.polls < hci_max_rounds and board.hw.cycleCount() -% c_start < adv_cycle_budget) {
        const st_now = rd32(0x2058_7120);
        const gate = rd32(0x2058_7114);
        board.hw.mwdt1Feed();
        board.hw.feedRtcWdt();
        pumpStep();
        r.polls += 1;
        r.synth_98bc_last = rd32(0x2010_98BC);
        if (synthLock()) {
            r.locked_polls += 1;
            if (r.first_lock_us == null) r.first_lock_us = board.hw.elapsedUs(t_en);
        }
        if (board.hw.cycleCount() -% c_s >= sample_cycles or board.hw.elapsedUs(t_s) >= 250_000 or r.polls % 20_000 == 0) {
            c_s = board.hw.cycleCount();
            t_s = board.hw.nowUs();
            _ = markerWrite(.sample, r.synth_98bc_last, rd32(0x2010_F800), st_now, transport.evtSeq(), gate);
            if (sample_n < sample_ring) {
                samples[sample_n] = .{ .polls = r.polls, .synth = r.synth_98bc_last, .f800 = rd32(0x2010_F800), .systimer = st_now, .gate = gate, .evt_seq = transport.evtSeq() };
                sample_n += 1;
            }
        }
    }
    _ = markerWrite(.final, r.synth_98bc_last, rd32(0x2010_F800), r.polls, r.locked_polls, transport.evtSeq());
    _ = markerWrite(.radios, rd32(0x2010_98C0), rd32(0x2010_98B8), rd32(0x2010_F818), rd32(0x2010_F81C), rd32(0x2010_9C04));
    _ = markerWrite(.synth, rd32(0x2010_9880), rd32(0x2010_9884), rd32(0x2010_9888), rd32(0x2010_988C), rd32(0x2010_98A8));
    uartDrain();
    board.log.line("bt adv-only: interval={d} params={} data={} enable={} polls={d} locked={d} first_lock_us={} 98bc=0x{x:0>8} records={d}", .{
        interval_units,
        if (r.params_status) |s| s else 0xFF,
        if (r.data_status) |s| s else 0xFF,
        if (r.enable_status) |s| s else 0xFF,
        r.polls,
        r.locked_polls,
        if (r.first_lock_us) |t| t else 0xFFFFFFFFFFFFFFFF,
        r.synth_98bc_last,
        marker_next,
    });
    for (samples[0..sample_n]) |s| {
        board.log.line("bt adv: sample polls={d} 98bc=0x{x:0>8} f800=0x{x:0>8} systimer_ctrl0=0x{x:0>8} gate7114=0x{x:0>8} evt_seq={d}", .{ s.polls, s.synth, s.f800, s.systimer, s.gate, s.evt_seq });
    }
    board.log.line("bt adv: record writes skipped after the advertise-enable was sent: {d}", .{marker_skipped});
    return r;
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

    // **轮 45：sleep env stub 预填（blob arena 分配）**——0x2f011134 = blob sleep
    // 子系统 env 指针槽。sleep_en 钳制使 blob 跳过 sleep init ⇒ 槽值 0 ⇒ sleep_cb
    // 读 NULL+0xC fault。修法 = 从 blob arena 分配 256B（OkE7 锚点历史路径），
    // 写自引用（offset 12 指回 stub），发布到槽 ⇒ blob 读到受保护内存 ✓。
    // **时机 = arena 初始化后、task_init(步 6) 前** ⇒ 赶在 blob 首次读槽之前。
    // **轮 71 撤销全部容器预填（0x2f011134/0x2f011138/0x2f011130）**——
    // 官方语义（OB0cbi2 反汇编实证）：*(0x2f011134)==0 = sleep OFF（beqz
    // 直接返回 0），非零 = 谎报 ON ⇒ post-INITED 链走进 set_sleep_cb ⇒
    // sleep ctx NULL store 崩（cfg sleep_en=0 本就不该跑 sleep init）。
    // 0x2f011138 = OkE7 自管理 env 槽（lazy malloc），非零 = 入口 bail -1。
    // 0x2f011130 哨兵 = OkE7 内部 fqmZkUKg 自管（外部预发 = 干扰链）。
    // 槽全让给 blob 自管，轮 71 判据：无 sleep crash ⇒ INITED ⇒ evt/CC 链。
    // （轮 67 终判撤销记录：0x2f011138 = OkE7 自管理 env 槽 lazy-init；0x2f011130
    //  哨兵 = OkE7 内部 fqmZkUKg 自管；0x2f011134 = sleep OFF 判定槽，非零谎报 ON。）

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
    // hp_sys_clkrst 全窗口（与 IDF 成功镜像的程序化对拍）
    {
        var k: usize = 0;
        while (k < 128) : (k += 1) {
            const a: usize = 0x2058_7000 + k * 4;
            const v = (@as(*volatile u32, @ptrFromInt(a))).*;
            if (v != 0) board.log.line("clkrst+0x{x:0>3} = 0x{x:0>8}", .{ k * 4, v });
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
        // **轮 138（r134b 挂死根修）**：pmu_init 杀 UART0 时钟 ⇒ 后续阻塞写
        // （log/sendCmdViaHs 路径）永挂 = r134b「GATE 后静默」真因。立即从
        // uartSnapshot 恢复 CTRL0（bit7 UART0_CLK_EN/bit1 APB_CLK_EN）。
        @as(*volatile u32, @ptrFromInt(CLKRST_UART0_CTRL0)).* = uart_ctrl0_snap;
        @as(*volatile u32, @ptrFromInt(CLKRST_SOC_CLK_SEL)).* = uart_soc_snap;
        // **轮 93**：lp_pc_en 武装前读 LP 槽——里面是**上一轮 boot 挂死时**的冻结
        // mepc（NMI 每 2ms 写，挂死后不再更新，LP 跨复位保留）。确定性 hang ⇒
        // 每轮打印的都是同一挂死 PC。上轮 boot 在 0x200A 后全静默 ⇒ 此值即死点。
        {
            const pc0: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0380)).*;
            const pc1: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0384)).*;
            const nmic: u32 = board.trap.nmi_count;
            const h600: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0600)).*;
            const h604: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0604)).*;
            const h608: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0608)).*;
            const h60c: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_060C)).*;
            board.log.line("PREVHANG pc0=0x{x:0>8} pc1=0x{x:0>8} nmi_this={d} h600={x:0>8}", .{ pc0, pc1, nmic, h600 });
            board.log.line("ADVRES magic={x:0>8} first={x:0>8} last={x:0>8}", .{ h604, h608, h60c });
            // **轮 115**：读 WDT FEED reg（0x20801008）= ULP loop 计数器
            // ⇒ 上一轮挂死时长 = 值 × 0.25s（若 LP 数字复位保留成立）
            const feedv: u32 = @as(*volatile u32, @ptrFromInt(0x2080_1008)).*;
            board.log.line("HANGDUR feed={d} (×0.25s = 挂死秒数)", .{feedv});
            // **轮 104**：ULP->HP 写通路验证——CONFIG1（0x20801004）= ULP 每循环
            // 写的递增计数器。跨 MWDT1 数字复位 LP/该块保留 ⇒ 值>0x29CC40（初值）
            // = 通路活；=初值/0 = 写不通。
            const cfg1v: u32 = @as(*volatile u32, @ptrFromInt(0x2080_1004)).*;
            board.log.line("ULPPATH cfg1=0x{x:0>8} (初值 0x29cc40, 递增=通路活)", .{cfg1v});
            // **轮 119**：LP 核心跳（v12 纯 LP-RAM 自增）。boot2 读的是 boot1
            // 整个挂死窗口的累计值；计数>0 = LP 核活，恒 0 = LP 核没在执行。
            const hbcnt: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_36F8)).* & 0xFFFF; // 低半字=活计数（视图 +2 字节错位）
            const hbph: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_3718)).* & 0xFFFF;
            board.log.line("LPCNT hb={x:0>8} phase={x:0>8} (>0 = LP 核活)", .{ hbcnt, hbph });
            // **轮 119c 判据**：① boot addr 回读（应 0x2E001000；0x2E000000 =
            // IDF 默认 = 我们的写没落地或被 blob init 覆盖）；② LP RAM 扫魔数
            // （0xC0DE/0xFADE 前缀落点 = LP 核真在写 + HP/LP 视图偏移量）。
            const ba: u32 = @as(*volatile u32, @ptrFromInt(0x2070_0018)).*;
            board.log.line("BOOTADDR=0x{x:0>8} (期望 0x2E001000)", .{ba});
            // **轮 119h**：LP 核复位原因（LP_AONCLKRST+0x38）。flag=1 = 核曾运行
            // 并自我复位（崩溃环）；flag=0 cause=0 = 核从未离开过复位态。
            const lprc: u32 = @as(*volatile u32, @ptrFromInt(0x2070_1038)).*;
            board.log.line("LPCORST raw=0x{x:0>8} (bit0=flag, [6:1]=cause, bit29=pmu_mask)", .{lprc});
            // **轮 119j**：LP_PERI_CLKRST 三寄存器回读（清旗后 re-arm 已跑）
            const clkr: u32 = @as(*volatile u32, @ptrFromInt(0x2071_0004)).*;
            const ramr: u32 = @as(*volatile u32, @ptrFromInt(0x2071_000c)).*;
            const intrr: u32 = @as(*volatile u32, @ptrFromInt(0x2071_0028)).*;
            board.log.line("LPCLK cpu={x:0>8} ram={x:0>8} intr={x:0>8} (cpu[30]=1 ram[30]=1 intr[30]=1 期望)", .{ clkr, ramr, intrr });
            {
                // boot 序号：LP RAM 跨数字复位保留 ⇒ 每次本读出块执行 = 一个 boot
                const bseq: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0F40)).* + 1;
                @as(*volatile u32, @ptrFromInt(0x2E00_0F40)).* = bseq;
                board.log.line("BOOTSEQ={d}", .{bseq});
            }
            {
                var hits: usize = 0;
                var addr: usize = 0x2E00_0000;
                while (addr < 0x2E00_4000 and hits < 6) : (addr += 4) {
                    const v = @as(*volatile u32, @ptrFromInt(addr)).*;
                    if ((v & 0xFFFF_0000) == 0xC0DE_0000 or (v & 0xFFFF_0000) == 0xFADE_0000) {
                        board.log.line("MAGIC 0x{x:0>8} @0x{x:0>8} (HP/LP 视图偏移 = 0x{x})", .{ v, addr, addr -% 0x2E00_0F00 });
                        hits += 1;
                    }
                }
                if (hits == 0) board.log.line("MAGIC none in 0x0000-0x3FFF (LP 核未写或视图在别处)", .{});
            }
            {
                // **轮 120m**：垃圾指针宿主扫描——logHook 链崩在调 0x10801000/
                // 0x2f000000（r119m/120l 两族）⇒ 扫 blob 数据区找这两个值的宿主槽。
                var ghits: usize = 0;
                var ga: usize = 0x2F00_0000;
                while (ga < 0x2F08_0000 and ghits < 8) : (ga += 4) {
                    const v = @as(*volatile u32, @ptrFromInt(ga)).*;
                    if (v == 0x1080_1000 or v == 0x2F00_0000) {
                        const wprev = @as(*volatile u32, @ptrFromInt(ga - 8)).*;
                        const wprev2 = @as(*volatile u32, @ptrFromInt(ga - 4)).*;
                        board.log.line("GPTR 0x{x:0>8} @0x{x:0>8} (prev=0x{x:0>8},0x{x:0>8})", .{ v, ga, wprev2, wprev });
                        ghits += 1;
                    }
                }
                if (ghits == 0) board.log.line("GPTR none in 0x2f000000-0x2f080000", .{});
            }
            const h610: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0610)).*;
            const h614: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0614)).*;
            const h618: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_0618)).*;
            board.log.line("ADVRES2 9C10={x:0>8} 98B8={x:0>8} 98C0={x:0>8}", .{ h610, h614, h618 });
            // **轮 110 读回**：CLK_CONF1（canary 0xC0 高位在?）、LP_CLK_CONF bit1
            const cc1: u32 = @as(*volatile u32, @ptrFromInt(0x2010_9C14)).*;
            const lpc18: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F018)).*;
            board.log.line("CANARY CLK_CONF1={x:0>8} LP_CLK18={x:0>8} (bit1=1 ⇒ ULP 可达)", .{ cc1, lpc18 });
            // **轮 95**：LP PC 环 dump（0x2E0003A0，32 项——上一轮挂死 boot 的
            // NMI 每 2ms 采样序列）⇒ 挂死自旋 PC 直接可见
            {
                const ring: [*]volatile u32 = @ptrFromInt(0x2E00_03A0);
                const cnt: u32 = @as(*volatile u32, @ptrFromInt(0x2E00_039C)).*;
                board.log.line("RING n={d}", .{cnt});
                var k: u32 = 0;
                while (k < 32) : (k += 1) {
                    const idx = (cnt +% 32 - 1 - k) % 32; // 从最新往回
                    const v = ring[idx];
                    if (k % 4 == 0) {
                        // 每行首打印序号（行内 4 个 PC 同行续）
                        board.log.line("RING[{d:0>2}]", .{k});
                    }
                    board.log.line(" PC{d:0>2}=0x{x:0>8}", .{ k, v });
                }
            }
        }
        board.trap.lp_pc_en = true; // pmu_init 后 LP RAM 才可访问：开 NMI PC 环/采样
        osal.lp_trace_en = true;
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
            uartMuteReport(); // 上一轮 UART 失声时的寄存器快照（复位后 UART 已恢复）
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
        const burst_rf_onoff = @extern(*const fn (on: c_int) callconv(.c) u32, .{ .name = "phy_ana_i2c_master_burst_rf_onoff" });
        const burst_bbpll = @extern(*const fn () callconv(.c) u32, .{ .name = "phy_ana_i2c_master_burst_bbpll_config" });
        // **轮 121z8 根修**：burst 返回值写入 I2C_BURST_CONF_REG（0x2010F810）——
        // burst 函数只返回配置值不写硬件！调用者必须写到 I2C_ANA_MST_I2C_BURST_CONF_REG
        // 才触发 I2C 事务（→ 合成器编程 → synth 锁定 → 98BC.bit2 置位）。
        // 此前 probe 丢弃返回值 ⇒ 合成器从未收到编程 ⇒ 118 轮挂死真根因！
        @as(*volatile u32, @ptrFromInt(0x2010_F810)).* = burst_rf_onoff(1);
        @as(*volatile u32, @ptrFromInt(0x2010_F810)).* = burst_bbpll();
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
    // **轮 27：解除 slot1 的诊断触发器**——它带着历史 tdata2（STORE|U 无 M）
    // 一直活着，会抢在正式观察点之前命中并污染 wp_hit_pc（单命中设计下
    // 第一个 cause=3 是谁的命中无法区分）。诊断完成即解除。
    asm volatile ("csrw 0x7a0, t0");
    asm volatile ("li t0, 1");
    asm volatile ("csrw 0x7a0, t0");
    asm volatile ("csrw 0x7a1, zero");
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
        board.trap.pmu_wake_on = true; // 轮 120o：PMU SW_WAKEUP_HP（src141→input7）
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
    // **EVH 计数表清零**(0x2E000500):per-boot 活锁归因。
    @memset(@as([*]u32, @ptrFromInt(0x2E00_0500))[0..17], 0);
    @memset(@as([*]u32, @ptrFromInt(0x2E00_0548))[0..6], 0); // UAR 差分槽
    // **收集旗**(0x2E00055C,跨 MWDT1 数字复位保留):0xC0DEC0DE=本上电周期已
    // 自陷上交过 ⇒ 泵自由长跑;否则 round 4000 时 MWDT1 自陷交出差分。
    const collect_flag: *volatile u32 = @ptrFromInt(0x2E00_055C);
    // **RTC WDT 死人开关提前**（bringup 前）：冻结点漂移实测可早至 step 6
    // （看门狗原武装点 fwd06 前覆盖不到）。cpu_reset 保 LP ⇒ 任何冻结 ≤25 min
    // 内数字复位 ⇒ 下 boot 打印黑匣子。fwd06 前的再武装只是续期。
    // **死亡现场取证扇区读回**(0x187000):上一个冻结周期由 NMI 写入的
    // 解除证据(MWDT1 CONFIG0/HOLD/UART 门控),此 boot 打印后擦除重置。
    {
        const esp_rom_spiflash_read: *const fn (u32, [*]u32, u32) callconv(.c) c_int =
            @extern(*const fn (u32, [*]u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_read" });
        const ulp_flash_erase: *const fn (u32) callconv(.c) c_int =
            @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
        const slot = @as(*volatile u32, @ptrFromInt(0x2E00_0574)).*;
        if (slot > 0 and slot <= 200) {
            var k: u32 = 0;
            while (k < slot) : (k += 1) {
                var rec: [4]u32 = .{ 0, 0, 0, 0 };
                _ = esp_rom_spiflash_read(0x187000 + k * 16, &rec, 16);
                board.log.line("DEATH[{d}] {x} {x} {x} {x}", .{ k, rec[0], rec[1], rec[2], rec[3] });
                board.hw.delayUs(5000);
            }
        }
        _ = ulp_flash_erase(0x187000 / 4096);
        @as(*volatile u32, @ptrFromInt(0x2E00_0574)).* = 0; // 计数重置,本轮重新收集
    }
    // **时钟 force-on**(LP_CLK_PO_EN bits: LP_BUS/AON_SLOW/SLOW/FAST/FOSC/RC32K):
    // 默认 0 = 时钟在 PMU sleep 请求时自动门控。blob 触发 sleep ⇒ 芯片睡死
    // (CPU waiti/时钟门控/WDT 停摆/UART 停——全部观测自洽)。置位 ⇒ 时钟永不
    // 门控 ⇒ 睡眠中 MWDT1 照走 ⇒ 10s 必咬 ⇒ 冻结变复位。
    // **轮 119o**：补 bit3 clk_aon_fast_oen（LP 核时钟源域！此前 1,2,4-7 全开
    // 独漏 3）与 bit0 clk_core_efuse_oen——位图不齐 = 源被门控，CPU_CTRL
    // force-on 只防睡眠门控不创造源。
    @as(*volatile u32, @ptrFromInt(0x2070_1004)).* |= (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7);
    board.hw.armRtcWdt(true, 49_300_000);

    // **RTC 慢时钟源钉死 RC_SLOW**(ROOT_CLK_CONF bits[25:23]=0)：默认源含
    // 外部 32.768k 晶振——本板未焊 ⇒ blob 时钟代码切到该源时 RTC 域整体停摆
    // (ULP/RTC WDT 全死,25min 窗 0 触发的根因理论)。RC_SLOW 为片内振荡器。
    {
        const ra: usize = 0x2070_1000;
        const v = @as(*volatile u32, @ptrFromInt(ra)).*;
        @as(*volatile u32, @ptrFromInt(ra)).* = v & ~(@as(u32, 7) << 23);
    }

    // **轮 119d**：keeper 预武装（幂等；init 内 LP 域动作会清 boot addr ⇒ init 后重装）
    // `-Dcoex`：启动共存核（IDF 的 `init_coexist`）。必须在 bringup.init 之前——
    // BLE 的 init 第 4 步 `btdm_coex_init` 与 controller 登记 BLE 回调都在其后。
    coex_wiring.boot();
    ulpKeeperArm(0);
    var rc = bringup.init(&cfg);
    // **轮 119d**：init 后重武装（init 的 LP 域动作清了 boot addr——回读实证）
    ulpKeeperArm(1);
    // **轮 120a**：PMU 触发重加（仅 post-init）——r119m 的 crash 当时程序在
    // LP RAM 外（0x2E001000 取指出界→总线错），现程序在 0x2E000080 合法位。
    // WAKEUP_EN.BIT1(SW_WAKEUP_HP) + HP_TRIGGER_LP（oracle 同款且安全）。
    @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B4)).* |= (1 << 1);
    @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B8)).* = (1 << 31);
    {
        const ba: u32 = @as(*volatile u32, @ptrFromInt(0x2070_0018)).*;
        board.log.line("REARM BOOTADDR=0x{x:0>8} (期望 0x2E000080)", .{ba});
    }
    coex_wiring.report(.init);

    // **轮 103b**：sleep 字段清零前移——task_init 已消费配置并填 sleep 对象
    // （0x2f011044 系），此刻清零 ⇒ ADV-enable 路径读到的就是禁用值。
    // oracle 对拍：word5(0x6c64 vs 0)、word6(0x46c60 vs 0)、word8(1 vs 0)。
    {
        const sp: [*]volatile u32 = @ptrFromInt(0x2f01_1044);
        sp[5] = 0;
        sp[6] = 0;
        sp[8] = 0;
        // **轮 111**：cfg.btdm.sleep_en 也清零——task_init 把它回写非 0（轮 13），
        // blob ADV-enable 读它决定是否进 modem 深睡时钟收缩（本轮 LP_CLK18
        // bit1=0 实证收缩发生）。F3 时点清零太晚（决策在 task_init 已定）。
        cfg.btdm.sleep_en = 0;
        board.log.line("SLPFIX-early w5=0 w6=0 w8=0 sleep_en=0 (all disabled)", .{});
    }

    // **轮 75：env 头 dump**（OkE7 返回后——env+0/4/8/12/16/20 全景）
    {
        const evp2: usize = @as(*volatile usize, @ptrFromInt(0x2f01_101c)).*;
        if (evp2 >= 0x2f00_0000 and evp2 < 0x2f90_0000 and evp2 % 4 == 0) {
            const w0: u32 = @as(*volatile u32, @ptrFromInt(evp2)).*;
            const w4: u32 = @as(*volatile u32, @ptrFromInt(evp2 + 4)).*;
            const w8: u32 = @as(*volatile u32, @ptrFromInt(evp2 + 8)).*;
            const w12: u32 = @as(*volatile u32, @ptrFromInt(evp2 + 12)).*;
            const w16: u32 = @as(*volatile u32, @ptrFromInt(evp2 + 16)).*;
            const w20: u32 = @as(*volatile u32, @ptrFromInt(evp2 + 20)).*;
            board.log.line(
                "bt probe: env hdr 0x{x:0>8}: +0={x:0>8} +4={x:0>8} +8={x:0>8} +12={x:0>8} +16={x:0>8} +20={x:0>8}",
                .{ evp2, w0, w4, w8, w12, w16, w20 },
            );
            // **轮 82**：state+4 读数（hiASs 状态机检查的字段）——env+4 子对象的 +4 偏移
            const mptr: usize = @as(*volatile usize, @ptrFromInt(evp2 + 4)).*;
            if (mptr >= 0x2f00_0000 and mptr < 0x2f90_0000 and mptr % 4 == 0) {
                const state4: u32 = @as(*volatile u32, @ptrFromInt(mptr + 4)).*;
                board.log.line("bt probe: state_obj={x:0>8} state+4={x:0>8}", .{ mptr, state4 });
            }
        } else {
            osal.logPublic("bt probe: env hdr ptr oob=0x{x:0>8}", .{evp2});
        }
    }
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
    // ⇒ 此刻写 100000（RC_SLOW 136k÷5，官方 btdm_lp_init 覆写口径）/0 即修复除零。
    // （注：本补丁在 init 返回后执行，不可能影响 step 17 的 rc——此前
    // "step17 rc=-3 归咎补丁"系误读，step17 失败另有原因。）
    {
        // **双候选判别（2026-11-21）**：真 sleep 对象指针 = [0x2f011044]
        // （y5Dip...，blob 于 40062ba2 写 obj+24/28）；[0x2f011034] 为旧假设。
        // 两处都查：仅当 obj[24]==0 且 obj[28]==0（零除活体）才补 100000。
        const cands = [_]usize{ 0x2f01_1044, 0x2f01_1034 };
        for (cands) |cp| {
            const obj: u32 = @as(*volatile u32, @ptrFromInt(cp)).*;
            const tag: []const u8 = if (cp == 0x2f01_1044) "1044" else "1034";
            if (obj >= 0x2f00_0000 and obj < 0x2f10_0000 and obj % 4 == 0) {
                const plo: *volatile u32 = @ptrFromInt(@as(usize, obj) + 24);
                const phi: *volatile u32 = @ptrFromInt(@as(usize, obj) + 28);
                if (plo.* == 0 and phi.* == 0) {
                    plo.* = 100000;
                    phi.* = 0;
                    osal.logPublic("bt probe: rtc_freq patch @{s} obj=0x{x:0>8} +24=100000", .{ tag, obj });
                } else {
                    _ = phi.*; // （else 分支日志已删：与 if 分支同串重复，镜像容量紧张。）
                }
            } else {
                osal.logPublic("bt probe: rtc_freq oob @{s} ptr=0x{x:0>8}", .{ tag, obj });
            }
        }
        // **RTC 比较武装（软件半环闭合）**：target0 = counter + 2s ⇒
        // SOC_WAKEUP（INT_ENA+MAP input6 已路由）⇒ trap 置旗 ⇒ 泵调
        // btSleepCb ⇒ sleep 唤醒软件半环闭环。（无条件：不依赖补丁命中）
        const rtb: usize = 0x2080_0000;
        // **隔离 RTC clk_en（2026-11-22，单变量轮）**：date(+0x3FC).bit31=clk_en，
        // 不置位 counter 一个 tick 都不走（skill s31-rtc-timer-probe 结论 3）——
        // BT 调度时基冻结 ⇒ LL 调度器永等 ⇒ 泵头冻结，且任何 rtc_freq 值都无效
        //（完整解释 btfix1/2 两轮零变化）。RMW 保留 bits[30:0]（写 date 丢 bit31=关钟）。
        @as(*volatile u32, @ptrFromInt(rtb + 0x3FC)).* |= 1 << 31;
        @as(*volatile u32, @ptrFromInt(rtb + 0x10)).* = 1 << 27;
        const cnt: u32 = @as(*volatile u32, @ptrFromInt(rtb + 0x1C)).*;
        @as(*volatile u32, @ptrFromInt(rtb + 0x04)).* = 0x8000_0000; // HIGH0=0 | TAR_EN0=1
        @as(*volatile u32, @ptrFromInt(rtb + 0x00)).* = cnt +% (137_271 * 2); // +2s
        @as(*volatile u32, @ptrFromInt(rtb + 0x34)).* = 1 << 31; // INT_CLR
        @as(*volatile u32, @ptrFromInt(rtb + 0x30)).* = 1 << 31; // INT_ENA
        // （armed2 行已删：FIFO 死区 4/4 全丢，cnt 判据已进 flash 标记。）
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
    bt_log_mute = 1;
    flashStageExtra(10, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0); // host 可读：init 之后、enable 之前
    osal.dump_hook = null;
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
    // **轮 26：STORE 观察点武装**——盯 s_is_phy_calibrated(0x2f010f80) 的写者：
    // 轮 25 实证该字节被持续踩（enable 后 230 → 冻结 136，源码只写 1）⇒ 有无符号
    // 指针写者污染胶水 bss。单命中：第一个写它的指令被 trap 抓 PC（trap 侧推进
    // mepc 后系统继续）。武装窗口 = bringup.enable 之前（踩踏从标定期就开始）。
    {
        // **轮 43 修复：sleep env 槽预填**——0x2f011134（r_sym_bt_sitBB3...）
        // = blob sleep 子系统的 env 指针槽。sleep_en 钳制（轮 13）使 blob 跳过
        // sleep init ⇒ 槽值 0 ⇒ sleep_cb 读 NULL+0xC fault（bpboot5 实测）。
        // 修法 = 预填一个静态零结构指针（blob 读到非零 = 安全访问零字段）。

    }
    {
        // **轮 30：STORE 观察点重武装（trapEntry 快路径版）**——cause-3 命中走
        // trapEntry 的 SRAM 快路径（零 flash 取指），XIP panic 类已根除。
        // 目标地址用链接符号取（跨构建稳健）：s_is_phy_calibrated（IDF 胶水静态，
        // 轮 24-29 链条：它被某指针持续写非零 ⇒ enable 入口恒 skip load_cal）。
        // **轮 34：目标 = tasks[0].ctx.sp（saved-sp 槽 0x2f010cec）**——合法写者
        // 只有 bt_swap_context 的 0x40078380；非该 PC 的命中 = 把坏 sp 写进任务
        // 上下文的原始踩踏者（比 flag 写者更上游）。
        // **轮 40 判决实验**：完全撤装观察点（轮 37-39 的 watch 命中 = 仪器吞 flag 写）
        if (false) {
            const watch_addr: u32 = 0x2F01_0F80;
            @import("board").trap.wp_watch_on = 1;
            asm volatile ("csrw 0x7a5, zero");
            asm volatile ("csrw 0x7a0, zero");
            asm volatile ("csrw 0x7a2, %[a]"
                :
                : [a] "r" (watch_addr),
            );
            asm volatile ("li t0, 0x4a"); // STORE|U|M（mcontrol 语义；芯片实现 mcontrol6）
            asm volatile ("csrw 0x7a1, t0");
            asm volatile ("li t0, 0x88"); // MTE
            asm volatile ("csrw 0x7a5, t0");
            osal.logPublic("bt probe: STORE watch armed @0x{x:0>8} (fastpath)", .{watch_addr});
            // **轮 38：c.ebreak 自证已删**——它是 panic 源（mepc=ra=ebreak 地址，resume 无推进 → 双重异常）。
        } // if (false) end
    }
    // **轮 63b：Slot.p 观察点改钩子就地武装**——轮 62 证明重绑定发生在
    // bringup.init 内部（enable 前武装太晚、零命中）。event_init(idx26) 命中
    // 目标槽的瞬间就盯住 Slot.p：后续 deinit/rebind 写者 → LP 槽三元组。
    rc = bringup.enable();
    if (rc != 0) {
        osal.logPublic("bt probe: enable FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    coex_wiring.report(.enable);
    // **从此零 flash 写**：post-enable 的 ROM flash 写 = 与 blob 并发 flash 操作
    // 相撞的楔子源头。标记深度只进 LP 槽（跨复位经 FEFE hist 带出）。
    bt_window_no_flash = true;
    board.trap.pc_dump_at = 0xFFFF_FFFF; // 采样器 ISR 不再触发 0x187000 dump
    mark.put(0x30, 0xADC0B103, @bitCast(rc)); // 此刻起 LP-only
    osal.logPublic("bt probe: enabled (status={d})", .{bringup.getStatus()});
    // **轮 49 根修 2**：ble_hci_trans_env[32]=0 ⇒ host 命令进 transport 后 LL
    // 处理入口缺失，全部静默丢弃（hs_cmd_tx 尾部 `jr env[32]` 实锤；板测 c32=0）。
    // env[32] 由 cfg_ll 注册，cfg_ll 的唯一官方调用者 = mode 分发器
    // `r_sym_ble_FzTWy2M5WtXtifB7Pwt4(mode)`（oracle 实证：a0=0x80000002 →
    // j yTwwy5 → cfg_ll(LL cmd=0x400183a6, ACL=0x40018418)）。step 17 官方链
    // 只**注册**分发器到槽[4]、从未**调用** ⇒ cfg_ll 永不执行。此处按官方
    // enable 语义亲自分发 BLE mode（0x80000002）。
    _ = r_sym_ble_FzTWy2M5WtXtifB7Pwt4(0x8000_0002);
    osal.logPublic("bt probe: mode dispatch 2 (BLE) done", .{});
    // **轮 50：A 路径门镜像开**——btdm ctx[32]（A 路径 r_btdm_hci_trans_rx 的
    // 分发槽）仍 0；cfg_ll 已证明 LL cmd 处理器对（e32=0x400183a6）。把同一对
    // 入口镜像写进 btdm ctx（ctxp 运行时读 *0x2f011020，arena 分配地址漂移）。
    // 一次 boot 双判据：B 路径切换（fwd06/0x2008）+ A 路径门开 ⇒ evt 演化定位
    // 剩余闸门。若 evt 仍不涨 ⇒ ctx[32] 语义不同，上 STORE 观察点抓官方写者。
    {
        const cp: usize = @as(*volatile usize, @ptrFromInt(0x2f01_1020)).*;
        if (cp >= 0x2f00_0000 and cp < 0x2f90_0000 and cp % 4 == 0) {
            @as(*volatile u32, @ptrFromInt(cp + 32)).* = @intFromPtr(&r_sym_ble_FJxPPDsfsgFzTvO2VwlU);
            @as(*volatile u32, @ptrFromInt(cp + 36)).* = 0;
            osal.logPublic("bt probe: ctx32 mirror -> 0x{x:0>8}", .{@intFromPtr(&r_sym_ble_FJxPPDsfsgFzTvO2VwlU)});
        } else {
            osal.logPublic("bt probe: ctx32 mirror skip cp=0x{x:0>8}", .{cp});
        }
    }
    // **轮 18：0x20100438 补齐缺失 7 位**（BB 窗口 diff 唯一差异：官方 0xffc00000
    // vs 我们 0xe0000000——缺 bits[28:22]）。判据链任一出现即破墙：FE450 振荡/
    // 47C 脉冲/98BC.bit2 置位/rcA+POST/evt 增量。
    @as(*volatile u32, @ptrFromInt(0x2010_0438)).* |= 0x1FC0_0000;
    // **轮 13：广播序列前钳 modem sleep**——blob 在 task_init 强制 sleep_en 非 0
    // （cfg 写 0 被回写实证）；Enable=1 启动广播后 LL 首次空闲进 sleep ⇒ 裸机
    // 无 light-sleep+LP 唤醒源 ⇒ 睡死（轮 12 机制终版）。序列发出前清零。
    cfg.btdm.sleep_en = 0;
    // **轮 14 pre-forward 钩子**：最后一条 sendCmd 的 forward 之前重写轻量标记
    //（phase=1）——到达而冻结 ⇒ rx 内部死锁；未到 ⇒ 挂在日志/更早。
    transport.pre_forward_hook = &preForwardMark;

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
    // **轮 21：modem_rst_conf(9C10) 释放**——oracle 端点 0x00000000 vs probe 残留
    // 0x001870c0（2026-11-22 ANA 硬 diff）。解码：bit12 rst_fe_adc / bit13
    // rst_fe_ahb / bit14 rst_fe = **RF 前端整块按在复位里** ⇒ synth 物理上锁不上
    // ⇒ 98BC.bit2 恒 0。IDF 链路 esp_phy_enable 断言、modem_clock_device_control
    // per-device 释放；我们的移植缺释放半边。现在在 phy/btbb 都完成后统一清零。
    {
        const before = (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).*;
        (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).* = 0;
        osal.logPublic("bt probe: modem_rst_conf 0x{x:0>8} -> 0 (FE/btmac/zbmac released)", .{before});
    }
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
    // **HCI 一致性自检**（Bluetooth Core 5.4，Vol 4 Part E）：A 阶段已证明 A 路径的回包可达，在这里、
    // 任何射频实验（0x2006 / 0x2008 / 0x200A）之前同步跑完。不能挂在主泵循环上——脚本在进主循环
    // 之前就停在 0x200A 的 synth 墙上，永远轮不到（2026-11-24 定位，见 `hciConformanceRun`）。
    _ = hciConformanceRun();

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
            board.hw.armT0Interrupt(10_000); // 2ms 的 handler 开销会饿慢主循环(MWDT1 因此提前咬)
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
        while (wait_dumps < 1_000_000) : (wait_dumps += 1) { // 100M 在 CPU 慢 100x 时要分钟级;降到 1M 让主循环过循环点
            asm volatile ("nop");
        }
        // **oracle 实验：IDF 本体的 `esp_phy_enable(PHY_MODEM_BT=2)`**
        // WITH_PHY=1 已把 IDF 的 phy_init.c 链进来（`esp_phy_enable` T 符号已确认）。
        // 它内部含我们手写版没有的完整射频使能段（含 analog/regi2c/PMU 路径）。
        // 若这一步之后轮询位能置 ⇒ 缺的就是它；若仍挂 ⇒ 连 IDF 都点不亮这块，
        // 问题在更上游（电源岛/晶振时钟路径）。
        // （WiFi osi 栈块已移除——该路径需要 esp_wifi 归档 = esp-idf 全系统栈）
        // **轮 20d 移除**：esp_phy_enable 已按官方时序移入 bringup.init step7
        // （btdm_lp_init 位）。此处原调用晚于 enable 阶段的 esp_btbb_enable，
        // 顺序错误（BB init 先于 RF enable）；实证 cmds=8 每轮都穿过且返回但
        // bit2 不置——时序错位正是疑点，现由 bringup 内的调用判别。
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
        // **轮 123k（oracle 命令序列逐字节复刻——此前 0x200A 从未发出）**：
        // oracle（bt-ctl-oracle/main.c 轮 15）时序实证：0x2006(MAC) → 0x2008(15B
        // params 字节) → 0x200A([01]) 后引擎才自臂 107C=80000000、11AC 跳动、
        // 98BC=4。我们的旧序列 = 0x2006 发了 15B params（OCF/payload 错位）、
        // F2 = 0x1405（Read RSSI）——0x200A 全程缺失 = 引擎永不武装的油门。
        // 字节 = oracle_send_cmd 的 buf 逐字节同款（H4 0x01 前缀在 transport 层）。
        const mac6: [6]u8 = .{ 0x02, 0x00, 0x00, 0x00, 0x20, 0x01 }; // 与 oracle p_addr 同
        const advp15: [15]u8 = .{ 0x00, 0x20, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00 }; // 与 oracle p_advp 同
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
            // **轮 49 根修**：intrArm 从未被执行——blob 走 ROM intr_handler_set
            // 直注册（捕获里无 intr_alloc 日志），osal on_intr_arm 钩子死代码 ⇒
            // MAP[124] 从未写入 ⇒ BT MAC 中断源从未路由 ⇒ brg=0、BB/MAC 事件链
            // 死、RF ready 永不置位。此处直接补路由（MAP=0x18 + 桥 handler +
            // mie 位），随后 ie24 才开 IE——顺序：路由/handler 先于 IE。
            bringup.intrArm(124);
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
        {
            const c: [*]volatile u32 = @ptrFromInt(0x2058_7000);
            clk_snap[0] = c[0x88 / 4];
            clk_snap[1] = c[0x114 / 4];
            clk_snap[2] = c[0x11C / 4];
            // NMI 看门狗重武装使能旗(0x570:与 clk_snap 0x560-0x56C 不冲突)
            @as(*volatile u32, @ptrFromInt(0x2E00_0570)).* = 0xBEEF_0001;
            // 传给 NMI(NMI 每 tick 据此回写——主核冻结后仍保时钟活)
            const cs: [*]volatile u32 = @ptrFromInt(0x2E00_0560);
            cs[0] = clk_snap[0];
            cs[1] = clk_snap[1];
            cs[2] = clk_snap[2];
            cs[3] = 0xCAFE_0001; // 有效旗
        }
        // **RTC WDT 兜底**（RTC 时钟域,独立于 HP TIMERGRP 时钟——哑火时 T0+MWDT1
        // 同时停 ⇒ 怀疑计时器域被门控,MWDT1 可能随之失效）：cpu_reset=true 只复位
        // CPU 核,LP 保留 ⇒ 差分证据可回读。137kHz × 360s ≈ 49.3M cycles。
        board.hw.armRtcWdt(true, 49_300_000);
        // （ICG 全 1 A/B 已做：无效果，代码撤除。）
        uartSnapshot(); // **快照**:泵每轮 compare/restore 的基线(UART0 32 字+CLKRST)
        // **轮 50：A→B 路径切换**——env[32]=FJxPPD 已注册（e32=0x400183a6 实证），
        // B 路径（hs_cmd_tx→jr env[32]）命令下行打通；A 路径（r_btdm_hci_trans_rx
        // → btdm ctx[32]=0）仍是死门。ADV 命令改走 B 路径直测 LL 处理能力。
        const r6 = transport.sendCmdViaHs(0x2006, &mac6);
        // **轮 15 协作让出**：任务消费积压命令/腾队列——裸忙等连发会在队列临界态
        // 死锁（轮 14 实锤：0x200A 的 rx 阻塞等任务=任务等泵）。
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        osi_impl_serviceTimers();
        osal.logPublic("bt probe: fwd06 ret={d}", .{r6});
        board.log.line("FWD06 rc={d} evt={d}", .{ r6, transport.stats().evt_count });
        osal.lpTrace(3, 0xF001);
        mark.put(0x80, 0xADC0B10d, transport.stats().btdm_tx);
        flashStageExtra(21, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0);
        var ad: [32]u8 = @splat(0);
        @memcpy(ad[0..advp15.len], &advp15);
        osal.lpTrace(3, 0xF002);
        const r8 = transport.sendCmdViaHs(0x2008, &advp15);
        osal.lpTrace(3, 0xF003);
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        osi_impl_serviceTimers();
        board.log.line("FWD8 rc={d} evt={d}", .{ r8, transport.stats().evt_count });
        // **轮 84**：ADV 类命令发送**之后** dump LE env（hiASs 状态机宿主）——
        // 判据：+4 仍 0 ⇒ 命令没到 .L673（分发上游断）；变 1 ⇒ hiASs 跑过、
        // 状态迁移了（CC 丢在 handler 后段）；变 2 ⇒ 状态机已迁移（轮 82c 三件套①）。
        {
            const le_env: usize = @as(*volatile usize, @ptrFromInt(0x2f011_01C)).*;
            if (le_env >= 0x2f00_0000 and le_env < 0x2f90_0000 and le_env % 4 == 0) {
                const f4: u32 = @as(*volatile u32, @ptrFromInt(le_env + 4)).*;
                const pa8: u32 = @as(*volatile u32, @ptrFromInt(le_env + 8)).*;
                const pb52: u32 = @as(*volatile u32, @ptrFromInt(le_env + 52)).*;
                board.log.line("LEENV {x:0>8} +4={x:0>8} +8={x:0>8} +52={x:0>8}", .{ le_env, f4, pa8, pb52 });
            } else {
                board.log.line("LEENV slot invalid {x:0>8}", .{le_env});
            }
        }
        // **轮 13/14 轻量标记（0x18F000，相位字）**：phase=0=pre-0x200A；phase=1=
        // pre-forward（最后一条 sendCmd 的 forward 之前——经 transport.pre_forward_hook）。
        writeLightMarker(0);
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
        // **轮 20b：SCHED 补写推迟到 0x200A 前**——armed 后写被 blob 在命令
        // 处理期清除（SC 054 存活、0f0+ 全灭实证）；官方值由 RF init/调度器在
        // 清除之后写入。现在在清除动作之后再补写一次。
        schedPatchset();
        // **轮 21b：modem_rst_conf 释放推迟到 0x200A 前**——armed 后清零被
        // 命令处理期复断言（0x188000 终值回到 0x001870c0 实证）：blob/phy 路径
        // 在命令期重按 FE 复位。官方同代 phy 的 phy_module_enable 负责释放，
        // 我们链接的 IDF v6.1 版本不释放（modem_flag 机制=期望别的 owner）。
        // 现在所有复断言之后、ADV 选通之前清零，rec[506..508] 记前后值。
        rst_conf_pre_200A = (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).*;
        (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).* = 0;
        rst_conf_post_200A = (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).*;
        // **轮 22b：F83C 对齐官方值**——ana 域硬 diff 恰一位：probe=0x12411290
        // （bit28=1）vs 官方=0x02411290（bit28=0）。bit28 误开的时钟源若挂在
        // regi2c 路径上，模拟写会静默失效。一行成本的对齐实验。
        const f83c_before = (@as(*volatile u32, @ptrFromInt(0x2010_F83C))).*;
        (@as(*volatile u32, @ptrFromInt(0x2010_F83C))).* = 0x0241_1290;
        // **轮 76：F83C 写前后二分**（board.log 直写 UART 可靠——FIFO 免疫）
        board.log.line("F0 {x:0>8}", .{f83c_before});
        // **轮 131（oracle 指针镜像实验）**：引擎疑似校验指针落点区域（oracle
        // 0x2f07ea18 接受，我们 0x2f02cd58 拒清）。0x2f07ea18 在我们布局 = 栈顶
        // 之后空隙区（_stack_top=0x2f07afc0 与 rom_phyFuns=0x2f07fc3c 之间）= 可
        // 安全占用。镜像 ctx 64B + 覆写全局指针 → 0x200A → 98BC 判决。
        {
            const dst: [*]volatile u32 = @ptrFromInt(0x2f07_ea18);
            const srcp: [*]const volatile u32 = @ptrFromInt(0x2f02_cd58);
            for (0..16) |i| dst[i] = srcp[i];
            const g: *volatile u32 = @ptrFromInt(0x2f010_15c);
            g.* = 0x2f07_ea18;
            board.log.line("CTXMIRROR g={x:0>8} w9888={x:0>8}", .{ g.*, @as(*volatile u32, @ptrFromInt(0x2010_9888)).* });
        }
        // **轮 132（README 候选门 1+2 + 写-回读自证）**：modem_ctrl0(0x20587040)
        // bit0 reg_modem_clk_en + clk_en0(0x205871F8) 读数；判据 = 写 0x12345678
        // 到 0x20109880 读回相等 ⇒ 门找到。
        {
            const mc0: *volatile u32 = @ptrFromInt(0x2058_7040);
            // **轮 140（MODEM PLL 钟解锁）**：reg.h 权威——CTRL0 bit2 = MODEM_CLK_EN、
            // bit4 = MODEM_PLL_CLK_EN（MODEM 域 PLL 核钟！）。轮 132 只置 bit0 ⇒
            // BB 域核心钟关 = 988x 全惰/9884 冻结的完整解释。
            mc0.* |= 1 | (1 << 2) | (1 << 4);
            const ce0v: u32 = @as(*volatile u32, @ptrFromInt(0x2058_71F8)).*;
            const tgt: *volatile u32 = @ptrFromInt(0x2010_9880);
            tgt.* = 0x1234_5678;
            const rb: u32 = tgt.*;
            const verdict: []const u8 = if (rb == 0x1234_5678) "GATE-FOUND" else "still-gated";
            board.log.line("GATE mc0={x:0>8} ce0={x:0>8} w9880={x:0>8} {s}", .{ mc0.*, ce0v, rb, verdict });
            // **轮 139（别名假说终验）**：0x20109888 = SRAM 固定地址 0x2f0185e4
            // 的硬件别名窗（oracle OGLOB 值 = 窗口值 ✓、我们全局地址不同 = 不镜像 ✓
            // 两条观测的唯一自洽解释）。写魔数到裸地址 0x2f0185e4 → 读窗口：
            // 镜像 ⇒ 写我们 ctx ptr 进去 = 引擎读到有效指针 = 接受态解锁。
            {
                const slot: *volatile u32 = @ptrFromInt(0x2f018_5e4);
                const saved = slot.*;
                slot.* = 0xC0DE_4242;
                const win = @as(*volatile u32, @ptrFromInt(0x2010_9888)).*;
                const av: []const u8 = if (win == 0xC0DE_4242) "MIRROR" else "none";
                board.log.line("ALIAS slot={x:0>8} win9888={x:0>8} {s}", .{ slot.*, win, av });
                slot.* = saved;
            }
            // **轮 138**：DIAG_BUS_EXCHANGE 视图交换扫描——4-bit×4 mux 全组合
            // （0x20109408：SEL0-3 各 4bit），每次写后读 9888：非零/变化 = 交换
            // 改变了 BB 私区视图 = 机制发现。FIX_SEL(0x20109404) 同法 5bit×2。
            {
                const exc: *volatile u32 = @ptrFromInt(0x2010_9408);
                const fix: *volatile u32 = @ptrFromInt(0x2010_9404);
                const fix0 = fix.*;
                exc.* = 0;
                fix.* = 0;
                var hit: u32 = 0;
                var sel: u32 = 0;
                while (sel < 16 and hit < 6) : (sel += 1) {
                    exc.* = sel | (sel << 4) | (sel << 8) | (sel << 12);
                    const v = @as(*volatile u32, @ptrFromInt(0x2010_9888)).*;
                    if (v != 0) {
                        board.log.line("EXC sel={d} w9888={x:0>8}", .{ sel, v });
                        hit += 1;
                    }
                }
                exc.* = 0;
                var fs: u32 = 1;
                while (fs < 32 and hit < 8) : (fs += 1) {
                    fix.* = (fs << 5) | fs | (1 << 10);
                    const v = @as(*volatile u32, @ptrFromInt(0x2010_9888)).*;
                    if (v != 0) {
                        board.log.line("FIX sel={d} w9888={x:0>8}", .{ fs, v });
                        hit += 1;
                    }
                }
                exc.* = 0;
                fix.* = fix0;
                board.log.line("DIAG sweep done hit={d}", .{hit});
            }
            // **轮 144（AON modem 钟源实验）**：HP_ALIVE_SYS_MODEM_CLK_AON_REG
            // （0x20589020，bit31 SEL: 0=foscl 1=xtal, default 1）。读当前值 →
            // 翻 SEL → 读 9884/9888（BB 域苏醒判）→ 恢复。三判据一次烧录。
            {
                const aon: *volatile u32 = @ptrFromInt(0x2058_9020);
                const orig = aon.*;
                board.log.line("AON orig={x:0>8} w9888={x:0>8}", .{ orig, @as(*volatile u32, @ptrFromInt(0x2010_9888)).* });
                aon.* = orig ^ (1 << 31);
                const w84 = @as(*volatile u32, @ptrFromInt(0x2010_9884)).*;
                const w88 = @as(*volatile u32, @ptrFromInt(0x2010_9888)).*;
                aon.* = orig;
                const w84b = @as(*volatile u32, @ptrFromInt(0x2010_9884)).*;
                board.log.line("AON flip sel={} w84={x:0>8}→{x:0>8} w88={x:0>8}", .{ (orig >> 31) & 1, w84, w84b, w88 });
            }
            // **轮 136**：0x20109800-98FF 保留性地图（逐 16B 写魔数读回）
            // R=retain / L=live（硬件值滚动）/ D=drop（写丢）
            {
                var wbase: u32 = 0x2010_9800;
                while (wbase < 0x2010_9900) : (wbase += 16) {
                    var mi: u32 = 0;
                    var marks: [4]u8 = .{ 'D', 'D', 'D', 'D' };
                    while (mi < 4) : (mi += 1) {
                        const a: *volatile u32 = @ptrFromInt(wbase + mi * 4);
                        const before: u32 = a.*;
                        a.* = 0xDEAD_0000 +% mi +% wbase;
                        const after: u32 = a.*;
                        marks[mi] = if (after == 0xDEAD_0000 +% mi +% wbase) 'R' else if (after != before) 'L' else 'D';
                    }
                    board.log.line("WMAP {x:0>8} {c}{c}{c}{c}", .{ wbase, marks[0], marks[1], marks[2], marks[3] });
                }
            }
        }
        // **轮 123k**：F1 改发 0x200A（此前 = 第二次 0x2006+params，enable 全程缺失）
        @as(*volatile u32, @ptrFromInt(0x2E00_057C)).* = 0xC0DE_9F2C; // 轮 148：trap 捕获窗旗开
        const adv_en: [1]u8 = .{0x01};
        const r6b = transport.sendCmdViaHs(0x200A, &adv_en);
        board.log.line("F1 rc={d} evt={d}", .{ r6b, transport.stats().evt_count });
        {
            // **轮 89b**：0x2006 的 CC status（last_evt 静态副本，[5]=status）
            const le = transport.stats();
            board.log.line("CC2006 {x:0>2} {x:0>2} op={x:0>2}{x:0>2} status={x:0>2}", .{ le.last_evt[0], le.last_evt[1], le.last_evt[4], le.last_evt[3], le.last_evt[5] });
        }
        // **轮 78：LE 活性探测**——发 Read RSSI (0x1405，无副作用)
        // CC 回来（evt→5）= LE 分支活，hang 是 ADV enable 特有（RF 依赖）
        // CC 不来 = 整个 LE 分发死
        const rrssi = transport.sendCmdViaHs(0x1405, &.{});
        board.log.line("F2 rc={d} evt={d}", .{ rrssi, transport.stats().evt_count });
        board.log.line("F2S btdm_tx={d} evt={d}", .{ transport.stats().btdm_tx, transport.stats().evt_count });
        @as(*volatile u32, @ptrFromInt(0x2E00_057C)).* = 0; // 轮 148：捕获窗旗关
        // **轮 86**：HCI 传输 env 对账——LE CC 的分发器内构造已完成（.L672），
        // 事件应在 kAQT9Bbw→ll_evt_tx 后抵达 env+24（cfg_hs 注册的 leEvtTx）。
        // 判据：+24 必须 = nm 里 leEvtTx 的符号地址；credits(env+64) 供 kAQT9Bbw
        // 的 avail 判定（<len+2 会走 assert(113) 路径——我们的 assert 若不 halt
        // 仍会尾跳 ll_evt_tx，不会吞事件）。
        {
            const hep: usize = @as(*volatile usize, @ptrFromInt(0x2f011_0FC)).*;
            if (hep >= 0x2f00_0000 and hep < 0x2f90_0000 and hep % 4 == 0) {
                const cb24: u32 = @as(*volatile u32, @ptrFromInt(hep + 24)).*;
                const ar28: u32 = @as(*volatile u32, @ptrFromInt(hep + 28)).*;
                const credits: u16 = @as(*volatile u16, @ptrFromInt(hep + 64)).*;
                board.log.line("HCIEVN env={x:0>8} +24={x:0>8} +28={x:0>8} credits={d}", .{ hep, cb24, ar28, credits });
                // **轮 86b**：last_evt[8] = 最后一条 CC 的原始字节（leEvtTx 存的静态副本）。
                // CC 布局：[0]=0x0E [1]=len [2]=ncmd [3..4]=opcode [5]=status。
                // status=0 ⇒ ADV 参数被接受；18/12 ⇒ handler 拒绝（参数/状态机）。
                const le = transport.stats();
                board.log.line("LASTCC {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
                    le.last_evt[0], le.last_evt[1], le.last_evt[2], le.last_evt[3],
                    le.last_evt[4], le.last_evt[5], le.last_evt[6], le.last_evt[7],
                });
            } else {
                board.log.line("HCIEVN env invalid {x:0>8}", .{hep});
            }
        }
        // **轮 90 守卫反转**：oracle90b 时序实证——esp_bt_controller_enable 完成时
        // 98BC 仍=0，发完 0x2006/0x2008/0x200A 后才变 4 ⇒ synth 上电是 ADV-enable
        // 命令处理的结果而非前置条件。rfready 守卫逻辑恰好反了，移除。
        const rf_ok = true;
        var ra2: c_int = -100;
        // **轮 91**：pre-send 快照（hang 时 UART 仍留有发送前状态）
        {
            const pre98: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
            const pref8: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*;
            const prem1: u32 = @as(*volatile u32, @ptrFromInt(0x2058_71E0)).*;
            board.log.line("PRE200A 98BC={x:0>8} f800={x:0>8} m1e0={x:0>8}", .{ pre98, pref8, prem1 });
            // **轮 94b**：ROM 自旋环指令字节（0x2f8036c0..e0，8 字）——解码轮询条件
            {
                const rp: [*]volatile u32 = @ptrFromInt(0x2f80_36C0);
                board.log.line("ROMC0 {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ rp[0], rp[1], rp[2], rp[3] });
                board.log.line("ROMD0 {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ rp[4], rp[5], rp[6], rp[7] });
                // 轮询目标寄存器也一并打：ROM 环通常 lw 自 UART0 块（0x20587000 系）
                const u0st: u32 = @as(*volatile u32, @ptrFromInt(0x2058_7088)).*;
                const u0fifo: u32 = @as(*volatile u32, @ptrFromInt(0x2058_7058)).*;
                board.log.line("UARTST 088={x:0>8} 058={x:0>8}", .{ u0st, u0fifo });
            }
            // **轮 103b**：SLPFIX 清零已前移至 bringup.init 之后（task_init 消费
            // 配置后立即执行——F3 时点清零被证明太晚或非该时点的决策输入）。
            // **轮 101**：RTC/SYS_TIMER 活性三步验证（UART 活性期，无挂死干扰）
            // ① latch → 读计数 → 忙等 ~1s → latch → 读 ⇒ 差分=每秒计数
            // ② 与 ULP 相同的 RC_SLOW 压回序列 ⇒ 读回核实 bits[25:23] 清零
            {
                const latched: *volatile u32 = @ptrFromInt(0x2080_0010);
                const cnt: *volatile u32 = @ptrFromInt(0x2080_001C);
                latched.* = 1 << 27;
                const c0: u32 = cnt.*;
                var spin: u32 = 0;
                while (spin < 150) : (spin += 1) {
                    var inner: u32 = 0;
                    while (inner < 1_000_000) : (inner += 1) {
                        asm volatile ("nop");
                    }
                }
                latched.* = 1 << 27;
                const c1: u32 = cnt.*;
                board.log.line("CLKCHK c0={x:0>8} c1={x:0>8} delta={d} (≈21700/0.15s 为活)", .{ c0, c1, c1 -% c0 });
                const rcv: *volatile u32 = @ptrFromInt(0x2070_1000);
                const v0: u32 = rcv.*;
                rcv.* = v0 & ~@as(u32, 0x0380_0000);
                const v1: u32 = rcv.*;
                board.log.line("PRESCHK v0={x:0>8} v1={x:0>8} (v1 无 03800000=压回写生效)", .{ v0, v1 });
                rcv.* = v0; // 还原
            }
            // **轮 92b 决定性实验**：手动置 F800 bit24（oracle=0x012f0669 我们=0x002f0669
            // 的唯一差异），轮询 98BC 10×500ms——若 bit2 跟随，synth 墙缩成一个 bit。
            const f800p: *volatile u32 = @ptrFromInt(0x2010_F800);
            f800p.* = pref8 | 0x0100_0000;
            // **轮 118-final**：ULP keeper 在 LP_CLK_CONF（0x2010f018）bit10 每
            // ~0.25s 翻转。主上下文在 RF-ON 门控下活（mcycle 忙等）⇒ 10 次 POLL
            // 读 bit10 序列：交替 0/1 = ULP 活；恒定 = ULP 死/时钟被门控。
            const f018p: *volatile u32 = @ptrFromInt(0x2010_F018);
            // **轮 120w**：HP/LP 视图偏移每 boot 变（+0x27F8 或 -0xE74 已实证）
            // ⇒ 读双候选；魔数扫描定位真实落点。
            const hbp: *volatile u32 = @ptrFromInt(0x2E00_36F8);
            const hpp: *volatile u32 = @ptrFromInt(0x2E00_3718);
            var f818v: u32 = 0;
            _ = &f818v;
            const hbp2: *volatile u32 = @ptrFromInt(0x2E00_0F8C); // -0xE74: 0xE80→0x8C
            const hpp2: *volatile u32 = @ptrFromInt(0x2E00_0FAC); // 0xEA0→0xAC
            const bbp: *volatile u32 = @ptrFromInt(0x2010_11AC);
            var poll: u32 = 0;
            while (poll < 10) : (poll += 1) {
                const s: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
                // **轮 119k 根修**：blob 在处理中清 LP_PERI_CLKRST CPU_CTRL.bit30/
                // INTR_CTRL.bit30（LP 核时钟坍缩真身，上一 boot 遗留读数实证）。
                // 主上下文 mcycle 环活着 ⇒ 每次迭代 oracle 全配对（轮 120d）：
                // **轮 120p**：先重写程序+向量表（blob init memset LP RAM ⇒ 只配对
                // 唤醒的核从全零取指即死 = 此前 POLL 配对无效的最简解释），
                // 然后 SLEEP_REQ → boot addr → 时钟位 → 复位脉冲 → WAKEUP_EN → TRIGGER。
                var vw2: usize = 0;
                while (vw2 < 0x80) : (vw2 += 4) {
                    @as(*volatile u32, @ptrFromInt(0x2E00_0000 + vw2)).* = 0x3020_0073;
                }
                for (0..ulp_prog_snapshot.len) |pi| {
                    @as(*volatile u8, @ptrFromInt(0x2E00_0080 + pi)).* = ulp_prog_snapshot[pi];
                }
                // **轮 120q**：全量时钟重断言——blob init 可能清 PO_EN 位图/根时钟
                // force-on/RAM clk（ARM0 后从未重写过）。corst=0x29 证复位线通，
                // 缺的是时钟链全量。
                @as(*volatile u32, @ptrFromInt(0x2070_1004)).* |= 0xFF; // lp_clk_po_en 全位
                @as(*volatile u32, @ptrFromInt(0x2070_1000)).* |= (1 << 28) | (1 << 29) | (1 << 30); // root force
                @as(*volatile u32, @ptrFromInt(0x2071_000c)).* |= (1 << 30); // ram clk
                // **轮 121d**：BB 引擎启动写重断言——r_btdm_task_enable 写的
                // [0x2010100C]=1 被 ADV-enable 坍缩抹除（BB dump 实证 100C=0）
                @as(*volatile u32, @ptrFromInt(0x2010_100C)).* = 1;
                // **轮 121z9 仪器**：BURST_STATUS(+0x14) 读回——bit0 = MST_BURST_DONE
                //（burst 执行完成标志）。写 BURST_CONF 后 DONE=1 = I2C 事务完成。
                const bst: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F814)).*;
                @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B0)).* = (1 << 31); // SLEEP_REQ(WT)
                @as(*volatile u32, @ptrFromInt(0x2071_0004)).* |= (1 << 30);
                @as(*volatile u32, @ptrFromInt(0x2071_0028)).* |= (1 << 30);
                @as(*volatile u32, @ptrFromInt(0x2070_0018)).* = 0x2E000080;
                const ccp2: usize = 0x2071_0004;
                @as(*volatile u32, @ptrFromInt(ccp2)).* = (1 << 31) | (1 << 30);
                @as(*volatile u32, @ptrFromInt(ccp2)).* = (1 << 30);
                @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B4)).* |= (1 << 1); // WAKEUP_EN bit1
                @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x1B8)).* = (1 << 31); // TRIGGER(WT)
                // **轮 121e**：全注册队列投递——osal.q_addr_map（已 pub）逐项
                // eventqPut 假事件（Slot{p=0x2E000B40}，载荷 LP 0x2E000B40 全零+
                // magic）。某一队列 = ADV-enable 的等待队列 ⇒ 任务推进。
                @as(*volatile u32, @ptrFromInt(0x2E00_2B00)).* = 0x2E00_2B40;
                @as(*volatile u32, @ptrFromInt(0x2E00_2B40)).* = 0xC0DE_0000 +% feed_seq;
                feed_seq +%= 1;
                {
                    for (&osal.q_addr_map) |*m| {
                        if (m.addr != 0 and m.q != null) {
                            var es2: osal.Slot = .{ .p = @ptrFromInt(0x2E00_2B40) };
                            osal.eventqPut(@ptrCast(@constCast(&m.addr)), &es2);
                        }
                    }
                }
                // 旧 Queue 结构路径已证无效（池基址=指针表非队列，121d）
                // **轮 120u**：FORCE_STALL 检查+解除——PWR0(+0x1AC) bit18 = 强制停滞
                //（oracle 终态 bit18=0、bit1=0）。若 blob 置位 = 核停而不死（ Stall！）。
                const pwr0p: *volatile u32 = @ptrFromInt(0x2070_4000 + 0x1AC);
                const p0v: u32 = pwr0p.*;
                if ((p0v & (1 << 18)) != 0) pwr0p.* = p0v & ~@as(u32, 1 << 18);
                const lprcp: u32 = @as(*volatile u32, @ptrFromInt(0x2070_1038)).*;
                const cc_rb: u32 = @as(*volatile u32, @ptrFromInt(0x2071_0004)).*; // 重断言后回读
                // **轮 120w**：POLL00 全 4KB 魔数扫描——blob init 后 HP/LP 视图偏移
                // 可能变化（魔数落点漂移）⇒ 本次 boot 内实时扫描。
                if (poll == 0) {
                    // **轮 120z4**：11AC（BB 引擎使能）补写——oracle=0xa9000000
                    if (bbp.* == 0) bbp.* = 0xA900_0000;
                    // **轮 121f**：q_addr_map 全 dump——任务 qslot=0x2f015ea0 是否
                    // 在注册表内（内=我们的投递应达；外=注册表满/未走 eventqInit）。
                    for (&osal.q_addr_map, 0..) |*m, mi| {
                        if (m.addr != 0) {
                            board.log.line("QMAP[{d:0>2}] addr=0x{x:0>8} q=0x{x:0>8}", .{ mi, m.addr, @intFromPtr(m.q.?) });
                        }
                    }
                    // **轮 121a**：ana 域对拍——F83C bit28（我们=1/oracle=0）翻转；
                    // F818 读入（oracle=2900e444）
                    const f83c: *volatile u32 = @ptrFromInt(0x2010_F83C);
                    f83c.* &= ~@as(u32, 1 << 28);
                    f818v = @as(*volatile u32, @ptrFromInt(0x2010_F818)).*;
                    // **轮 121b**：BB dump（oracle bb_dump_task 同寄存器同格式）
                    // oracle 基准（/tmp/oracle_bb.log）：450=00102000 47C=0 408=a0000000
                    // 40C=7 41C=34020 420=0 444=0 11AC=a9000000 08D0=0 9C10=0
                    // 9C14=3fe080 9888=2f07ea18 988C=f07d854 98B8=0 98BC=4
                    const bbr: [*]volatile u32 = @ptrFromInt(0x2010_0450);
                    const bb2: [*]volatile u32 = @ptrFromInt(0x2010_11AC);
                    board.log.line("BB 450={x:0>8} 47C={x:0>8} 408={x:0>8} 40C={x:0>8} 41C={x:0>8} 420={x:0>8} 444={x:0>8}", .{ bbr[0], @as(*volatile u32, @ptrFromInt(0x2010_047C)).*, @as(*volatile u32, @ptrFromInt(0x2010_0408)).*, @as(*volatile u32, @ptrFromInt(0x2010_040C)).*, @as(*volatile u32, @ptrFromInt(0x2010_041C)).*, @as(*volatile u32, @ptrFromInt(0x2010_0420)).*, @as(*volatile u32, @ptrFromInt(0x2010_0444)).* });
                    // **轮 134**：9884 计数器速率样本（POLL 间隔 0.75s，差值 = BB 核
                    // 时钟速率；oracle 同款对拍判「满速/跛脚」）
                    board.log.line("W9884={x:0>8}", .{@as(*volatile u32, @ptrFromInt(0x2010_9884)).*});
                    board.log.line("BB 100C={x:0>8} 11AC={x:0>8} 08D0={x:0>8} 9C10={x:0>8} 9C14={x:0>8} 9888={x:0>8} 988C={x:0>8} 98B8={x:0>8}", .{ @as(*volatile u32, @ptrFromInt(0x2010_100C)).*, bb2[0], @as(*volatile u32, @ptrFromInt(0x2010_08D0)).*, @as(*volatile u32, @ptrFromInt(0x2010_9C10)).*, @as(*volatile u32, @ptrFromInt(0x2010_9C14)).*, @as(*volatile u32, @ptrFromInt(0x2010_9888)).*, @as(*volatile u32, @ptrFromInt(0x2010_988C)).*, @as(*volatile u32, @ptrFromInt(0x2010_98B8)).* });
                    board.log.line("SC 1254={x:0>8} 1258={x:0>8} 107C={x:0>8} 1000={x:0>8}", .{ @as(*volatile u32, @ptrFromInt(0x2010_1254)).*, @as(*volatile u32, @ptrFromInt(0x2010_1258)).*, @as(*volatile u32, @ptrFromInt(0x2010_107C)).*, @as(*volatile u32, @ptrFromInt(0x2010_1000)).* });
                    // **轮 129**：等锁环现场寄存器（trap 一次捕获）。
                    {
                        const pa3 = @extern(*volatile u32, .{ .name = "pollcap_a3" });
                        const pa4 = @extern(*volatile u32, .{ .name = "pollcap_a4" });
                        const ps1 = @extern(*volatile u32, .{ .name = "pollcap_s1" });
                        const pn = @extern(*volatile u32, .{ .name = "pollcap_n" });
                        const pc_mepc = @extern(*volatile u32, .{ .name = "pollcap_mepc" });
                        board.log.line("POLLCAP n={d} mepc=0x{x:0>8} a3={x:0>8} a4={x:0>8} s1={x:0>8}", .{ pn.*, pc_mepc.*, pa3.*, pa4.*, ps1.* });
                    }
                    // **轮 129b**：栈区调度槽扫描——a4 = Deeq 的 sp+15（确定性），
                    // [a4-1912] = s3 = ctx ptr 落栈槽。parked sp 向下扫 1000 词找
                    // 0x2f02cd58，命中打印邻域 16 词（调度字段非零 = 武装已写栈）。
                    if (ctrl_task) |t| {
                        const sp0: usize = t.ctx.sp;
                        var hits3: u32 = 0;
                        var qq: usize = sp0 - 4000;
                        while (qq < sp0 + 4000 and hits3 < 3) : (qq += 4) {
                            const svv = @as(*volatile u32, @ptrFromInt(qq)).*;
                            if (svv == 0x2f02_cd58) {
                                hits3 += 1;
                                board.log.line("CTXSLOT @0x{x:0>8} (sp-{})", .{ qq, sp0 - qq });
                                var wi: u32 = 0;
                                while (wi < 12) : (wi += 1) {
                                    const wa = qq - 64 + wi * 4;
                                    board.log.line("S{d:0>2} {x:0>8} = {x:0>8}", .{ wi, wa, @as(*volatile u32, @ptrFromInt(wa)).* });
                                }
                            }
                        }
                        if (hits3 == 0) board.log.line("CTXSLOT none in [sp-4000,sp+4000)", .{});
                    }
                    // **轮 124d**：ana 芯片内部对拍——reg99 横扫 blocks 1-6 + B6 regs
                    // 92-106（oracle 基线：R99 b1=ab b3=32 b4=11 b5=11；B6=ff*5 80 3f 00 ff ff 63 0a ff 2f 00）
                    {
                        const rd = @extern(*const fn (reg: u8, hostid: u8, blk: u8) callconv(.c) u8, .{ .name = "phy_i2c_readReg" });
                        board.log.line("R99 b1={x:0>2} b2={x:0>2} b3={x:0>2} b4={x:0>2} b5={x:0>2} b6={x:0>2} b7={x:0>2}", .{ rd(99, 1, 1), rd(99, 1, 2), rd(99, 1, 3), rd(99, 1, 4), rd(99, 1, 5), rd(99, 1, 6), rd(99, 1, 7) });
                        board.log.line("B6 {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{ rd(92, 1, 6), rd(93, 1, 6), rd(94, 1, 6), rd(95, 1, 6), rd(96, 1, 6), rd(97, 1, 6), rd(98, 1, 6), rd(99, 1, 6), rd(100, 1, 6), rd(101, 1, 6), rd(102, 1, 6), rd(103, 1, 6), rd(104, 1, 6), rd(105, 1, 6), rd(106, 1, 6) });
                    }
                    var m2: usize = 0;
                    var ma: usize = 0x2E00_0000;
                    while (ma < 0x2E00_1000 and m2 < 4) : (ma += 4) {
                        const mv = @as(*volatile u32, @ptrFromInt(ma)).*;
                        if ((mv & 0xFFFF_0000) == 0xC0DE_0000) {
                            board.log.line("POLLSCAN magic=0x{x:0>8} @0x{x:0>8}", .{ mv, ma });
                            m2 += 1;
                        }
                    }
                    if (m2 == 0) board.log.line("POLLSCAN none (核死或视图超 4KB 窗)", .{});
                }
                board.log.line("POLL{d:0>2} 98BC={x:0>8} f800={x:0>8} f018={x:0>8} hb={x:0>4} ph={x:0>4} hb2={x:0>8} ph2={x:0>8} pwr0={x:0>8} ccrb={x:0>8} i11ac={x:0>8} f818={x:0>8} bst={x:0>8} corst={x:0>8}", .{ poll, s, f800p.*, f018p.*, hbp.* & 0xFFFF, hpp.* & 0xFFFF, hbp2.*, hpp2.*, p0v, cc_rb, bbp.*, f818v, bst, lprcp });
                // **轮 123d**：时钟门全指纹 + 桥活动——clk_conf(9C04) 22/25/28/29/30、
                // LPCON clk(0x2010F018) bit1(coex)、bridge_w/r/d（input24 源活动）。
                board.log.line("CLKG 9C04={x:0>8} 9C08={x:0>8} 9C14={x:0>8} LP018={x:0>8} bw={d}/{d}/{d} rtcwk={d}", .{
                    @as(*volatile u32, @ptrFromInt(0x2010_9C04)).*,
                    @as(*volatile u32, @ptrFromInt(0x2010_9C08)).*,
                    @as(*volatile u32, @ptrFromInt(0x2010_9C14)).*,
                    @as(*volatile u32, @ptrFromInt(0x2010_F018)).*,
                    bringup.bridge_w,
                    bringup.bridge_ran,
                    bringup.bridge_dropped,
                    board.trap.rtc_wake_flag,
                });
                // **轮 121z9 关键修复**：POLL 环让出 CPU——mcycle 忙等 7.5s 饿死
                // blob 任务 ⇒ ADV-enable 内部超时过期 ⇒ 永不完成（evt 恒 8 的
                // 最简解释）。每次迭代让出一次 ⇒ blob 任务获得 90%+ CPU 时间。
                if (ctrl_task) |t| sched.resumeTask(&t.ctx);
                // **轮 134b**：9884 每轮采样（速率差分）
                board.log.line("W9884b={x:0>8}", .{@as(*volatile u32, @ptrFromInt(0x2010_9884)).*});
                // **轮 105**：延迟改 mcycle 忙等——bit24(RF-ON arm) 写入后硬件立即
                // 门控 SYS_TIMER（RF 上电序列的电源收缩）⇒ esp_rom_delay_us 永转。
                // mcycle 忙等不受门控影响 ⇒ 主上下文活 ⇒ 98BC 演化实时可见。
                var mw: u32 = 0;
                while (mw < 150) : (mw += 1) {
                    var mi: u32 = 0;
                    while (mi < 1_000_000) : (mi += 1) {
                        asm volatile ("nop");
                    }
                }
            }
        }
        // **轮 120z2**：blob 任务挂起帧 dump——POLL 结束后泵已代跑若干轮，
        // 帧内 = 处理器当前挂起点（第二等待面的真实 PC）。
        if (ctrl_task) |t| {
            board.log.line("TCTX sp=0x{x:0>8}", .{t.ctx.sp});
            var fi: usize = 0;
            while (fi < 14) : (fi += 1) {
                board.log.line("TCTX[{d:0>2}] = 0x{x:0>8}", .{ fi, sched.frameWord(&t.ctx, fi) });
            }
            // **轮 121e**：eventq_pool 扫描——找 waiter == &t.ctx 的 Queue
            //（= 任务挂起等待的真队列）⇒ 直接 send 解锁。
            const myctx: u32 = @intFromPtr(&t.ctx);
            var qp2: usize = 0x2f01_5ea0;
            const qend: usize = 0x2f01_5ea0 + 0x6604; // 池真实大小（nm -S）
            var found: usize = 0;
            while (qp2 < qend) : (qp2 += 4) {
                const w0 = @as(*volatile u32, @ptrFromInt(qp2)).*;
                if (w0 >= 4 and w0 <= 64) {
                    const w1 = @as(*volatile u32, @ptrFromInt(qp2 + 4)).*;
                    const w2 = @as(*volatile u32, @ptrFromInt(qp2 + 8)).*;
                    const w5 = @as(*volatile u32, @ptrFromInt(qp2 + 20)).*;
                    if (w1 >= 4 and w1 <= 64 and w2 <= w1 and w5 == myctx) {
                        board.log.line("QFOUND @0x{x:0>8} item={d} cap={d} count={d}", .{ qp2, w0, w1, w2 });
                        found += 1;
                    }
                }
            }
            if (found == 0) board.log.line("QFOUND none in pool (waiter 指针不匹配)", .{});
            // **轮 121z9b**：ctrl_task 入口地址——找到 blob controller task 的
            // 入口函数 ⇒ 反汇编找 BB schedule arm 写集。
            if (t.ctx.entry) |e| board.log.line("TASKENTRY=0x{x:0>8}", .{@intFromPtr(e)});
        }
        // **轮 121z6**：post-POLL evt/btdm_tx 判读——0x200A 处理器若完成则
        // CC 事件入队（evt≥9）且命令已发（btdm_tx≥4）。
        board.log.line("POSTPOLL evt={d} btdm_tx={d}", .{ transport.stats().evt_count, transport.stats().btdm_tx });
        if (rf_ok) {
            // **轮 94b**：0x200A 后 blob 门控 UART0 ⇒ 任何打印都会卡死主上下文
            // （ROM FIFO 等待环 0x2f8036cc，NMI 实测 ra=probe.run 打印路径）。
            // 静默一切 UART 输出，ADV-enable 结果直写 0x18F000 marker 离线判读。
            board.log.muted = true;
            // **轮 120o 根修**：SW_WAKEUP_HP INT 路由三件套——HP_TRIGGER_LP 唤醒
            // LP CPU 后 LP 经 SW_WAKEUP_HP（PWR2 bit1 使能的源）向 HP 举手；source
            // 141（ETS_PMT/PMU_INTR）未路由 = CLIC 硬件向量跳 base 0x10801000 = 崩
            //（r119m/120l 两族 crash 同机制）。MAP→input7 + intctl IE+prio +
            // PMU INT_ENA/CLR bit29（PMU_HP_INT_ENA/CLR = PMU base+0x194/0x198）。
            @as(*volatile u32, @ptrFromInt(0x2058_5000 + 141 * 4)).* = 7; // MAP: src141→input7
            {
                const clic7: *volatile u32 = @ptrFromInt(0x1080_1000 + 7 * 4);
                clic7.* = (1 << 8) | (1 << 30); // IE + prio=1（写有效读恒 0）
            }
            @as(*volatile u32, @ptrFromInt(0x2070_4000 + 0x194)).* |= (1 << 29); // PMU INT_ENA sw
            // **轮 120y**：synth-waiter 补丁——r_sym_ble_NZbbpXEXzbgRpDNnAbBu
            //（0x40001b22）入口写 c.ret（0x8082）：synth 永不上电 ⇒ 等待器超时
            // ⇒ 断言 ⇒ 调用者无限重试（BT_ASSERT_RETURNS 语义差）。补丁 = 立即
            // 返回 ⇒ blob 跳过等待继续推进（官方 rc=3 容忍路径）。
            // **轮 121c 修正**：补丁从 c.ret@入口 改为 伪成功@轮询环——保留等待器
            // 的 RF 配置写（9888/988C = synth 启动触发，BB dump 实证缺它！），仅
            // 跳过 16.7M 轮询（0x40001b72 处 lw → li a5,4 = 伪 bit2 置位 →
            // .L145 成功路径）。oracle 流程复刻：ADV 完成 → synth 后续上电。
            @as(*volatile u16, @ptrFromInt(0x4000_1B72)).* = 0x0545; // c.li a5,4
            @as(*volatile u16, @ptrFromInt(0x4000_1B74)).* = 0x0001; // c.nop（原 lw 尾 2B）
            asm volatile ("fence.i");
            // **轮 120k**：STORE 观察点盯 SYSTIMER_CTRL0（0x20587120）——坍缩期间
            // 谁写它（blob 门控 SYS_TIMER 的写点）→ trap cause=3 → wp 槽给出 mepc。
            // tdata1=0x4A（STORE|M|U）；tselect=1（0 号留给历史武装）。
            // **轮 120k→l**：目标改 TIMERGRP 时钟门 0x2058_711C（SYSTIMER_CTRL0
            // = 我们 POLL 环每 0.75s 自写 = 观察点风暴，轮 63 已知模式）。
            // 0x711C 只有 hw init 写一次 ⇒ 命中必是 blob 的 TIMERGRP 门控写。
            asm volatile ("csrw 0x7a0, zero");
            asm volatile ("csrw 0x7a1, zero"); // 先解除 trig0 历史
            asm volatile ("li t0, 1");
            asm volatile ("csrw 0x7a0, t0");
            asm volatile ("li t0, 0x2058711C");
            asm volatile ("csrw 0x7a5, t0"); // tdata2 = 目标地址
            asm volatile ("li t0, 0x4A");
            asm volatile ("csrw 0x7a1, t0"); // tdata1 = STORE|M|U
            asm volatile ("csrw 0x7a0, zero"); // 回 tselect=0
            // **轮 95d**：0x200A 改走 A 路径（异步队列）——B 路径同步分发下
            // ADV-enable handler 内部等待的事件需要泵投递而泵正阻塞在本调用里
            // = 同步死锁。A 路径入队 ⇒ controller task 在自己上下文处理 ⇒
            // 内部等待可满足（基础命令 A 路径已证通：A(rx) sendReadVersion）。
            ra2 = transport.sendCmd(0x200A, &ae);
            // **轮 100**：post-send 不再用 writeLightMarker（ROM 擦除内部
            // esp_rom_delay_us = 楔点，会挡住后面的 mcycle 观测块）。观测全走 LP。
            // **轮 116 活遥测**：0x200A 入队后（A 路径异步，task 并发处理），
            // esp_rom_spiflash_write（页编程等待=寄存器轮询非 delay_us；NOR 写仅
            // 清位）把 98BC 实时值写 marker[8]——synth 上电则变 0x4。
            const esw116 = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
            const m116: *volatile u32 = @ptrFromInt(0x18F000 + 32); // marker[8] 活遥测槽
            {
                const v: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
                _ = esw116(0x18F000 + 32, @ptrCast(&v), 4);
            }
            // **轮 96**：post-send 观测全走非 ROM 通道——0x200A 后 blob 楔死
            // ROM 的 flash-erase 等待与 esp_rom_delay_us（SYS_TIMER 时钟被门控）。
            // mcycle 忙等轮询 98BC 15s，首/末值 + F800 写远处 LP 槽
            // （0x2E000600 系，RTC WDT 20s 数字复位后下 boot PREVHANG 读出）。
            {
                board.hw.armRtcWdt(true, 120_000_000); // ≈60s @2MHz——挂死后数字复位（LP 保留）⇒ 下 boot 读 ADVRES
                const lp600: *volatile u32 = @ptrFromInt(0x2E00_0600);
                const lp604: *volatile u32 = @ptrFromInt(0x2E00_0604);
                const lp608: *volatile u32 = @ptrFromInt(0x2E00_0608);
                const lp60c: *volatile u32 = @ptrFromInt(0x2E00_060C);
                lp604.* = 0x5A5A_0001; // "96 轮询数据" magic
                const s_first: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
                var t: u32 = 0;
                var s_last: u32 = s_first;
                var f_last: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*;
                // **轮 112**：轮询环内先回写时钟门四件套 + SYSTIMER 使能 ⇒
                // 对抗 blob ADV-enable 的时钟收缩 ⇒ 98BC 读瞬时完成（不再 1s 停顿）
                // ⇒ SYS_TIMER 活 ⇒ blob task 的时间源活 ⇒ RF-wait 能超时 ⇒ 返回。
                const mc: [*]volatile u32 = @ptrFromInt(0x2010_9C00);
                const lpc18: [*]volatile u32 = @ptrFromInt(0x2010_F018);
                const mcconf: [*]volatile u32 = @ptrFromInt(0x2058_71E0);
                const stc: [*]volatile u32 = @ptrFromInt(0x2058_7120);
                // mcycle 忙等 15s，分片轮询
                // **轮 121w 修正**：mc[0]=TEST_CONF(+0x00) 非 CLK_CONF(+0x04)！
                // mc[1]=CLK_CONF(+0x04)、mc[3]=POWER_ST(+0x0C)、mc[2]=FORCE_ON(+0x08)
                while (t < 150) : (t += 1) {
                    mc[5] = 0x003f_f880; // CLK_CONF1（MODEM SYSCON +0x14）
                    mc[1] = 0x7e60_1002; // CLK_CONF（+0x04，原 mc[0]=TEST_CONF 写错位！）
                    mc[2] = 0x0000_00FF; // FORCE_ON（+0x08）全 FO
                    mc[3] |= 0xFFFF_F000; // POWER_ST(+0x0C) 六域 ST_MAP 全 0xF=常开（bits[31:12]，bits[11:0] reserved 勿触）
                    lpc18[0] |= 2; // LP_CLK_CONF |= coex/i2c_mst
                    mcconf[0] = 0x3d; // MODEM_CONF
                    stc[0] |= 0x11; // SYSTIMER_CTRL0 apb+clk en
                    var spin: u32 = 0;
                    while (spin < 1_000_000) : (spin += 1) {
                        asm volatile ("nop");
                    }
                    s_last = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
                    f_last = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*;
                    if (t == 0) lp600.* = s_last;
                    m116.* = s_last; // **轮 116**：每次轮询刷新 marker[8]（活遥测）
                }
                lp604.* = 0x5A5A_0002;
                lp608.* = s_first;
                lp60c.* = s_last;
                lp600.* = f_last;
                // **轮 118**：post-send 结果落 [8]/[9]——NOR 编码：每字写
                // ~(值)（全 1 中清位）⇒ 读回取反即原值。esp_rom_spiflash_write
                // 页编程等待=寄存器轮询（SYS_TIMER 门控不影响该轮询路径）。
                const esw118 = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
                const r98n: u32 = ~s_last;
                const rf8n: u32 = ~f_last;
                _ = esw118(0x18F000 + 32, @ptrCast(&r98n), 4);
                _ = esw118(0x18F000 + 36, @ptrCast(&rf8n), 4);
                // **轮 113**：ADVRES 环（含每轮时钟回写）之后，SYS_TIMER 已被 ULP+
                // 回写救活 ⇒ ROM flash API 的内部延迟能走完 ⇒ writeLightMarker(3)
                // 不再楔死 ⇒ ADV-enable 结果（phase=3 + 98BC/F800）落 flash。
                writeLightMarker(3);
                // **轮 101**：MODEM_SYSCON 复位/时钟寄存器挂死快照——9C10
                // （modem_rst_conf：blob ADV-enable 可能重断言 FE 复位位）
                const r9c10: u32 = @as(*volatile u32, @ptrFromInt(0x2010_9C10)).*;
                const r98b8: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98B8)).*;
                const r98c0: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98C0)).*;
                @as(*volatile u32, @ptrFromInt(0x2E00_0610)).* = r9c10;
                @as(*volatile u32, @ptrFromInt(0x2E00_0614)).* = r98b8;
                @as(*volatile u32, @ptrFromInt(0x2E00_0618)).* = r98c0;
            }
        } else {
            board.log.line("F3 SKIP rfready=0", .{});
            // **轮 87**：osal 修复后的 RF 墙基线重测（轮 51-56 分析先于 osal 重写）。
            // 全部被动读/自环，不发 0x200A：
            //  R1: synth ready 全字（bit2 是 RF/BB ready 硬件位）
            //  R2: ana master clock（0x208133fc bit28）+ DEVICE_EN 位图（0x20813014）
            //  R3: ana 自环 write 0x5A→readback（轮 57 已证活——post-fix 再证一次）
            //  R4: FE/PLL 关键寄存器 0x201008D0（FE 环判据）与 0x2010F800/F818
            const r98bc: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
            const mstclk: u32 = @as(*volatile u32, @ptrFromInt(0x2081_33fc)).*;
            const deven: u32 = @as(*volatile u32, @ptrFromInt(0x2081_3014)).*;
            const fe8d0: u32 = @as(*volatile u32, @ptrFromInt(0x2010_08D0)).*;
            const f800: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*;
            // **轮 87c**：BB init HW 验证——bt_bb_v2_init_cmplx 写 0x20100870
            // （bits[15:8] |= 0x96）与 0x20102c00（|= 0x19f_000）；非默认值 = BB init 跑过。
            const bb870: u32 = @as(*volatile u32, @ptrFromInt(0x2010_0870)).*;
            const bbc00: u32 = @as(*volatile u32, @ptrFromInt(0x2010_2C00)).*;
            // **轮 88**：oracle CLK-post 对拍三件——m1e0 应=0x3d、st 应=0x60448000、98BC 应=4
            const m1e0: u32 = @as(*volatile u32, @ptrFromInt(0x2058_71E0)).*;
            const st1c: u32 = @as(*volatile u32, @ptrFromInt(0x2038_A01C)).*;
            board.log.line("R1 98BC={x:0>8} R2 mst={x:0>8} den={x:0>8} R4 fe={x:0>8} f800={x:0>8}", .{ r98bc, mstclk, deven, fe8d0, f800 });
            board.log.line("R5 bb870={x:0>8} bbc00={x:0>8}", .{ bb870, bbc00 });
            board.log.line("R6 m1e0={x:0>8} st1c={x:0>8} (oracle: 3d / 60448000)", .{ m1e0, st1c });
            // **轮 89d**：modem clock 链四层判定——latch=1? dev_list/icg 懒初始化过?
            // hal[1] 被写 0x2010f000? （全非零 = device_control 跑到底，写被丢；
            // latch=0 = pump 没调 enable 分支）
            const latch: u8 = @as(*volatile u8, @ptrFromInt(0x2f011_14C)).*;
            const ctx12: u32 = @as(*volatile u32, @ptrFromInt(0x2f010_E70)).*;
            const ctx16: u32 = @as(*volatile u32, @ptrFromInt(0x2f010_E74)).*;
            const hal0: u32 = @as(*volatile u32, @ptrFromInt(0x2f010_E88)).*;
            const hal4: u32 = @as(*volatile u32, @ptrFromInt(0x2f010_E8C)).*;
            board.log.line("R7 latch={d} ctx12={x:0>8} ctx16={x:0>8} hal0={x:0>8} hal4={x:0>8}", .{ latch, ctx12, ctx16, hal0, hal4 });
            // **轮 89f**：hal 表指向的两块实际时钟寄存器 + 漏读的 F818
            const hp9c00: u32 = @as(*volatile u32, @ptrFromInt(0x2010_9C00)).*;
            const hp9c04: u32 = @as(*volatile u32, @ptrFromInt(0x2010_9C04)).*;
            const f818: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F818)).*;
            board.log.line("R9 hp9c00={x:0>8} hp9c04={x:0>8} f800={x:0>8} f818={x:0>8}", .{ hp9c00, hp9c04, f800, f818 });
            // **轮 89e**：0x20813014 写-回读活性测试（写保护判据）
            const den_addr: usize = 0x2081_3014;
            const d0: u32 = @as(*volatile u32, @ptrFromInt(den_addr)).*;
            @as(*volatile u32, @ptrFromInt(den_addr)).* = d0 | 0x20;
            const d1: u32 = @as(*volatile u32, @ptrFromInt(den_addr)).*;
            @as(*volatile u32, @ptrFromInt(den_addr)).* = d0;
            const d2: u32 = @as(*volatile u32, @ptrFromInt(den_addr)).*;
            board.log.line("R8 den wr-rb: pre={x:0>8} set={x:0>8} restore={x:0>8} latch={s}", .{ d0, d1, d2, if (d1 & 0x20 != 0) "YES" else "NO" });
            // **轮 90**：RF-ON burst 直驱（oracle 在 lp_reset 相由 esp_phy_enable 内部
            // 执行；我们的 F800 bit24=0 说明 burst 没跑/没生效）。此刻 PHY/BB/时钟
            // 全就绪，从 probe 直接驱动一次并读 98BC/F800。
            phy_ana_i2c_master_burst_rf_onoff(1);
            const s98_after: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
            const f800_after: u32 = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*;
            board.log.line("R10 rf_onoff done 98BC={x:0>8} f800={x:0>8}", .{ s98_after, f800_after });
            // **轮 87b**：签名修正后重跑——(reg=99, hostid=1, block=6) = PLL cap 自环
            phy_i2c_writeReg(99, 1, 6, 0x5A);
            const loopback: u8 = phy_i2c_readReg(99, 1, 6);
            board.log.line("R3 ana loopback={x:0>2} (0x5A=alive)", .{loopback});
        }
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        osi_impl_serviceTimers();
        flashStage(23);
        osal.logPublic("bt probe: LE rc6={d} rc8={d} rcA={d} tx={d}", .{ r6, r8, ra2, transport.stats().btdm_tx });

        // **轮 5 判据（2026-11-22，flash 标记通道——UART 在本区 4/4 全丢，盲区免疫）**：
        // 冻结时刻把唤醒链计数器 {事件环计数, evt 回调数, btdm_tx, events_dropped,
        // undispatched} + cnt 双采样（走动 ⇒ Δ>0，同时判定 RTC clk_en 是否生效）+
        // FE450/47C 值 + osi 事件环尾 8 条写 0x18E000 扇区；宿主机
        // `esptool read-flash 0x18E000` 离线判读，指认断点 ∈ {入队未处理,
        // 事件无订阅者, 队列 send/recv 断}（5F70/5F7D 门控模式照抄）。
        {
            const esw5 = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
            const ese5 = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
            const st5 = transport.stats();
            @as(*volatile u32, @ptrFromInt(0x2080_0010)).* = 1 << 27;
            const cnt1: u32 = @as(*volatile u32, @ptrFromInt(0x2080_001C)).*;
            const o1 = @import("osal_kit").osal.stats(); // 相位 1（fwd06 后即时）
            var spins: u32 = 0;
            while (spins < 4_000_000) : (spins += 1) {
                @as(*volatile u32, @ptrFromInt(0x2080_0010)).* = 1 << 27;
                if (@as(*volatile u32, @ptrFromInt(0x2080_001C)).* != cnt1) break;
            }
            const cnt2: u32 = @as(*volatile u32, @ptrFromInt(0x2080_001C)).*;
            // **第二采样相位（~200ms 后）**：完成流是否仍在走（evt/cmds 增量）
            // + last_evt 字节。区分「完成流断在第二条命令」vs「只卡 0x200A」。
            var spins3: u32 = 0;
            while (spins3 < 40_000_000) : (spins3 += 1) {
                @as(*volatile u32, @ptrFromInt(0x2080_0010)).* = 1 << 27;
                const now: u32 = @as(*volatile u32, @ptrFromInt(0x2080_001C)).*;
                if (now -% cnt2 >= 27_000) break; // ≈200ms @137 kHz
            }
            const cnt3: u32 = @as(*volatile u32, @ptrFromInt(0x2080_001C)).*;
            const st6 = transport.stats(); // 相位 2 新读（stats 按值返回）
            const o2 = @import("osal_kit").osal.stats(); // 相位 2 新读（o1 在 cnt1 处）
            var rec: [528]u32 = undefined;
            const ready_raw: u32 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*; // 读挂 ⇒ 本记录不出现
            rec[0] = 0xADC0_BBF4;
            rec[1] = osi_impl.event_count;
            rec[2] = st5.evt_count;
            rec[3] = st5.btdm_tx;
            rec[4] = osi_impl.events_dropped;
            rec[5] = @import("event_bus.zig").undispatched;
            rec[6] = cnt1;
            rec[7] = cnt2;
            rec[8] = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
            rec[9] = @as(*volatile u32, @ptrFromInt(0x2010_047C)).*;
            rec[10] = @bitCast(r6);
            rec[11] = @bitCast(r8);
            rec[12] = cnt3;
            rec[13] = st6.evt_count; // 相位 2（相位 1 在 rec[2]）
            rec[14] = st6.cmds_sent;
            rec[15] = @as(u32, st6.last_evt_code);
            rec[16] = @as(u32, st6.last_evt[0]) | @as(u32, st6.last_evt[1]) << 8 |
                @as(u32, st6.last_evt[2]) << 16 | @as(u32, st6.last_evt[3]) << 24;
            rec[17] = @as(u32, st6.last_evt[4]) | @as(u32, st6.last_evt[5]) << 8 |
                @as(u32, st6.last_evt[6]) << 16 | @as(u32, st6.last_evt[7]) << 24;
            rec[18] = o1.eventq_put;
            // **osal 唤醒链双相快照**（200ms 窗口内 put/get 增量直接指认断点）：
            // P1 = [18..28]，P2 = [29..39]。
            // **轮 12 决定性一测**：0x201098BC（0x200A 轮询的 ready 位）在冻结时刻
            // 是否可读。若本记录仍完整出现 ⇒ 读可完成（CPU 活着）；若记录消失
            // ⇒ CPU 卡在 blob 轮询的那条 lw 上（MODEM 总线停摆 = 死因实锤）。
            rec[19] = o1.eventq_get_ok;
            rec[20] = o1.eventq_get_empty;
            rec[21] = o1.event_run_count;
            rec[22] = o1.event_run_no_slot;
            rec[23] = o1.raw_q_dropped;
            rec[24] = o1.pool_exhausted;
            rec[25] = o1.eventq_requeued;
            rec[26] = o1.blocked_calls;
            rec[27] = o1.sem_pend_ok;
            rec[28] = o1.sem_pend_timeout;
            rec[29] = o2.eventq_put;
            rec[30] = o2.eventq_get_ok;
            rec[31] = o2.eventq_get_empty;
            rec[32] = o2.event_run_count;
            rec[33] = o2.event_run_no_slot;
            rec[34] = o2.raw_q_dropped;
            rec[35] = o2.pool_exhausted;
            rec[36] = o2.eventq_requeued;
            rec[37] = o2.blocked_calls;
            rec[38] = o2.sem_pend_ok;
            rec[39] = o2.sem_pend_timeout;
            // **blob 台词行环**（bt_printf_shim 的 s31_bt_ring，mute 期也在记）：
            // HCI 分发器对每条命令的内部判词，16×48B = 192 字，rec[44..236]。
            rec[40] = bt_ring_head;
            rec[41] = bt_log_dropped;
            rec[42] = bt_raw_head;
            rec[43] = @intFromPtr(&cfg.btdm); // 冻结读：blob 是否回写 sleep_en
            rec[296] = ready_raw; // 0x201098BC 冻结值（bit2=RF/BB ready）
            rec[297] = st6.tx_type; // 出站首包类型
            // **轮 18：BB 窗口（0x20100400-5FF，64 字）**——与官方 BW dump 对照找缺失写集。
            var bw: usize = 0;
            while (bw < 64) : (bw += 1) {
                rec[298 + bw] = @as(*volatile u32, @ptrFromInt(0x2010_0400 + bw * 4)).*;
            }
            // **轮 19：分区哈希（XOR+非零计数）**——rec[362..368]＝BBHEAD/SCHED/WIDGET。
            const segs = [_]struct { base: usize, words: usize }{
                .{ .base = 0x2010_0000, .words = 256 },
                .{ .base = 0x2010_1000, .words = 128 },
                .{ .base = 0x2010_9400, .words = 80 },
            };
            for (segs, 0..) |sg, si| {
                var x: u32 = 0;
                var nz: u32 = 0;
                var i: usize = 0;
                while (i < sg.words) : (i += 1) {
                    const v = @as(*volatile u32, @ptrFromInt(sg.base + i * 4)).*;
                    x ^= v;
                    if (v != 0) nz += 1;
                }
                rec[362 + si * 2] = x;
                rec[363 + si * 2] = nz;
            }
            // **轮 20：SCHED 区逐字 dump（0x20101000-1200，128 字）**——rec[368..496]。
            // 注意 rec[362..368] 是哈希，勿混淆；本段才是逐字值。
            var scw: usize = 0;
            while (scw < 128) : (scw += 1) {
                rec[368 + scw] = @as(*volatile u32, @ptrFromInt(0x2010_1000 + scw * 4)).*;
            }
            // **轮 20e：LP hist 槽并入大 rec**（advisor 2026-11-22）——mark.put 写
            // LP RAM(0x2E00_0004+4k)，FEFE 记录只走 LP boot 路径落盘；主路径冻结式
            // boot 从不过那个点 ⇒ hist 离线恒 0。现在随大 rec 每轮落盘，可判读。
            var hk: usize = 0;
            while (hk < 10) : (hk += 1) {
                rec[496 + hk] = @as(*volatile u32, @ptrFromInt(0x2E00_0004 + 4 * hk)).*;
            }
            rec[506] = rst_conf_pre_200A;
            rec[507] = rst_conf_post_200A;
            // **轮 24：校准运行判据**——oracle 版 esp_phy_enable 先调
            // phy_module_has_clock_bits(modem)，为假则整段 load_cal 被跳过
            // （rc 仍 0）⇒ 校准从未运行 ⇒ synth 永不锁。两个字节钉死：
            //   rec[508] = s_is_phy_calibrated（esp_phy_enable 内部读的全局，
            //              反汇编 0x4000077e: lui 0x2f011; lbu -384 = 0x2f010f80）
            //   rec[509] = phy_module_has_clock_bits(2)（PHY_MODEM_BT）直调结果
            // **轮 30**：rec[508..511] = 观察点四元组 {写者 PC, 写者 ra, 命中数, calflag}
            // **轮 31**：观察点四元组改读 **LP 槽副本**（0x2E0004A0..4AC，快路径
            // 直写）——bss 全局可能被同一写者踩（count 恒 20 亿跨构建恒定的
            // 解释），LP 域在踩踏域之外。
            rec[508] = @as(*volatile u32, @ptrFromInt(0x2E00_04A0)).*;
            rec[509] = @as(*volatile u32, @ptrFromInt(0x2E00_04A4)).*;
            rec[510] = @as(*volatile u32, @ptrFromInt(0x2E00_04A8)).*;
            // **rec[511] = 冻结时刻 flag 字节**（nm 地址直读；本构建布局见 nm）
            rec[511] = @as(*volatile u8, @ptrFromInt(0x2F01_0F40)).*; // flag@0x2f010f80（s_is_phy_calibrated 本构建地址）
            // **轮 33：ra 链**（快路径 LP 0x2E0004B0..4CC，命中时刻 sp 向上的
            // 8 个文本段候选返回地址）——定位别名跳转的上游调用者。
            rec[512] = @as(*volatile u32, @ptrFromInt(0x2E00_04B0)).*;
            rec[513] = @as(*volatile u32, @ptrFromInt(0x2E00_04B4)).*;
            rec[514] = @as(*volatile u32, @ptrFromInt(0x2E00_04B8)).*;
            rec[515] = @as(*volatile u32, @ptrFromInt(0x2E00_04BC)).*;
            rec[516] = @as(*volatile u32, @ptrFromInt(0x2E00_04C0)).*;
            rec[517] = @as(*volatile u32, @ptrFromInt(0x2E00_04C4)).*;
            rec[518] = @as(*volatile u32, @ptrFromInt(0x2E00_04C8)).*;
            rec[519] = @as(*volatile u32, @ptrFromInt(0x2E00_04CC)).*;
            // **轮 34**：saved-sp 槽的非 swap 写者三元组（0 = 无污染写者）
            // **轮 36**：wp2 读 LP 权威副本（bss 全局在窗口内会被踩）
            rec[520] = @as(*volatile u32, @ptrFromInt(0x2E00_04D0)).*;
            rec[521] = @as(*volatile u32, @ptrFromInt(0x2E00_04D4)).*;
            rec[522] = @as(*volatile u32, @ptrFromInt(0x2E00_04D8)).*;
            // 裸三元组环 16×3 = 48 字（rec[44..92]）。
            var r9: usize = 0;
            while (r9 < 48) : (r9 += 1) rec[44 + r9] = bt_raw[r9 / 3][r9 % 3];
            // **最后一条日志的载荷**（p2 指针 ≤32B，rec[92..100]）——HCI 级真内容。
            {
                const last = bt_raw[(bt_raw_head +% 15) % 16];
                const plen: usize = @min(last[1], 32);
                const dst9: [*]u8 = @ptrCast(&rec[92]);
                const src9: [*]volatile u8 = @ptrFromInt(last[2]);
                var b9: usize = 0;
                while (b9 < plen) : (b9 += 1) dst9[b9] = src9[b9];
            }
            // **出站首包头 16B**（btdmTx 的 tx_first，5 次 btdm_tx ≈ 5 条 Complete 的第一条）。
            rec[100] = @as(u32, st6.tx_first[0]) | @as(u32, st6.tx_first[1]) << 8 |
                @as(u32, st6.tx_first[2]) << 16 | @as(u32, st6.tx_first[3]) << 24;
            rec[101] = @as(u32, st6.tx_first[4]) | @as(u32, st6.tx_first[5]) << 8 |
                @as(u32, st6.tx_first[6]) << 16 | @as(u32, st6.tx_first[7]) << 24;
            rec[102] = @as(u32, st6.tx_first[8]) | @as(u32, st6.tx_first[9]) << 8 |
                @as(u32, st6.tx_first[10]) << 16 | @as(u32, st6.tx_first[11]) << 24;
            rec[103] = @as(u32, st6.tx_first[12]) | @as(u32, st6.tx_first[13]) << 8 |
                @as(u32, st6.tx_first[14]) << 16 | @as(u32, st6.tx_first[15]) << 24;
            // **文本行环整环**（768B ⇒ rec[104..296]；裸三元组/载荷已先行落位，勿覆盖）。
            const dst: [*]u8 = @ptrCast(&rec[104]);
            const src2: [*]const u8 = @ptrCast(&bt_ring);
            var bi: usize = 0;
            while (bi < 768) : (bi += 1) dst[bi] = src2[bi];
            const clic25b: usize = 0x1080_1000 + 25 * 4;
            const g5: u32 = @as(*volatile u32, @ptrFromInt(clic25b)).*;
            @as(*volatile u32, @ptrFromInt(clic25b)).* = g5 & ~@as(u32, 0x108);
            _ = ese5(0x18E000 / 0x1000);
            if (builtin.target.os.tag == .freestanding) board.hw.flashOpBegin();
            _ = esw5(0x18E000, &rec, @sizeOf(@TypeOf(rec)));
            if (builtin.target.os.tag == .freestanding) board.hw.flashOpEnd();
            @as(*volatile u32, @ptrFromInt(clic25b)).* = g5;
        }

        // **轮 11：0x200A 后第二份标记（0x18F000）**——若本记录存在 ⇒ 0x200A 返回了；
        // FE450/47C 判「广播真在跑（450 进官方振荡集/47C 脉冲）」vs「RF 未发车（仍静止）」。
        {
            const esw6 = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
            const ese6 = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
            const stA = transport.stats();
            var recA: [8]u32 = .{
                0xADC0_BBA2,
                @as(*volatile u32, @ptrFromInt(0x2010_0450)).*,
                @as(*volatile u32, @ptrFromInt(0x2010_047C)).*,
                stA.evt_count,
                stA.btdm_tx,
                @bitCast(ra2),
                @as(*volatile u32, @ptrFromInt(0x2080_001C)).*, // LP counter 现值
                stA.tx_type,
            };
            const clic25c: usize = 0x1080_1000 + 25 * 4;
            const g6: u32 = @as(*volatile u32, @ptrFromInt(clic25c)).*;
            @as(*volatile u32, @ptrFromInt(clic25c)).* = g6 & ~@as(u32, 0x108);
            _ = ese6(0x18F000 / 0x1000);
            if (builtin.target.os.tag == .freestanding) board.hw.flashOpBegin();
            _ = esw6(0x18F000, &recA, @sizeOf(@TypeOf(recA)));
            if (builtin.target.os.tag == .freestanding) board.hw.flashOpEnd();
            @as(*volatile u32, @ptrFromInt(clic25c)).* = g6;
        }
    }
    var round: u32 = 0;
    var evt_at: ?u32 = null;
    var diag_at: u32 = 0;
    var rom_scanned: bool = false;
    var hscan_done: bool = false;
    var bb0_done: bool = false;
    var diag_round: u32 = 0;
    while (true) : (round += 1) {
        // **时钟回写**(泵顶):CLKRST UART0/TIMERGRP 门控恢复 boot 基线——
        // 若哑火=时钟门控,此回写让输出复活 ⇒ 因果链闭合。回写目标是 HP 域
        // 系统控制器(永有时钟),读它安全;UART0 本体仍禁碰。
        {
            const c2: [*]volatile u32 = @ptrFromInt(0x2058_7000);
            c2[0x88 / 4] = clk_snap[0];
            c2[0x114 / 4] = clk_snap[1];
            c2[0x11C / 4] = clk_snap[2];
            const cc: [*]volatile u32 = @ptrFromInt(0x2E00_0548);
            cc[5] +%= 1; // 回写轮数(LP 可观测)
        }
        // **泵内禁止触碰 UART0**:哑火(时钟被门控)后读其寄存器即挂总线
        // ——52 boot 全冻在泵头几轮的实测根因。差分只能走 NMI 的 CLKRST
        // +0x88 采样(HP 域,读它安全)。round 50 自陷交出黑匣子。
        if (round >= 50) {
            if (collect_flag.* != 0xC0DE_C0DE) {
                collect_flag.* = 0xC0DE_C0DE;
                osal.lpTrace(3, 0xD3C1);
                board.hw.mwdt1Suicide(); // 数字复位:LP 保留 ⇒ 下 boot 打印黑匣子
            }
        }
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
        if (!wdt_suicide) {
            board.hw.mwdt1Feed();
            board.hw.feedRtcWdt();
        }
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
        // **轮 48 实验**：modem_rst_conf 每轮读+清（释放 FE 复位）。先证：
        // 清零被命令处理期复断言（终值回 0x001870c0），官方由 phy_module_enable
        // 释放、我们路径不释放 ⇒ FE 憋复位 ⇒ RF 永不 ready。清了活不活看 evt。
        {
            const rsten: *volatile u32 = @ptrFromInt(0x2010_9C10);
            const rv: u32 = rsten.*;
            if (rv != 0) {
                rst_or |= rv;
                rsten.* = 0;
            }
        }
        _ = osal.serviceCallouts(osal.timeGet());
        const now = osal.timeGet();
        // **合成器/事务活值采样**（每 ~1s）：98BC.bit2 = RF/BB ready（旧 stage-22
        // 墙的位）；F818.CONF0 bit27 = ana 事务相位（官方在事务完成后清）。
        // 泵窗内的活读数，不经 LP/flash，无下载刮花问题。
        if (round % 200 == 0) {
            diag_at = now;
            if (!ana_dumped) {
                ana_dumped = true;
                bringup.anaSnap(); // 轮 51 槽 3：泵首轮
                for (0..bringup.ana_snap_n) |k| {
                    const s4 = bringup.ana_snap[k];
                    board.log.line("bt probe: ana[{d}] F818={x:0>8} F800={x:0>8} 11AC={x:0>8} 0450={x:0>8}", .{ k, s4[0], s4[1], s4[2], s4[3] });
                }
                // **regi2c 读判别**（读 cal 期写过的 PLL cap 寄存器，同三元组）：
                // 真值 ⇒ ana 总线活（缺口 = 没人发 RF init 事务）；0/0xFF ⇒ 总线死
                // （追 i2c_mst 时钟门）。lpTrace 相位包夹：0xA001 打 0xA002 不打 =
                // 挂死在总线等待内部。
                // **轮 51 追加**：首轮读回 0x00 + calflag=1 ⇒ RF 电源域校准后被关。
                // 此处重调 rf_onoff(1) 再读：非零 ⇒ 有人在校准后关 RF（抓关者）；
                // 仍 0 ⇒ rf_onoff 自身未生效（前置缺失）。
                osal.lpTrace(3, 0xA001);
                phy_ana_i2c_master_burst_rf_onoff(1);
                osal.lpTrace(3, 0xA003);
                const capv: u8 = phy_i2c_readReg(99, 1, 6);
                osal.lpTrace(3, 0xA002);
                board.log.line("bt probe: regi2c(99,1,6)=0x{x:0>2}", .{capv});
                // **轮 52：ana master clock 判别**——bootloader 用 force_enable
                // 常开 ⇒ app 期引用计数可掉零 ⇒ master clock 停 ⇒ ROM readReg
                // 带超时快速返回 0（与读 0x00 未挂死吻合）。BIT28@0x208133fc
                // （HP 可安全读写域）置位后再读：非零 ⇒ 墙 = master clock 门控。
                {
                    const dreg: *volatile u32 = @ptrFromInt(0x2081_33fc);
                    const before: u32 = dreg.*;
                    dreg.* = before | (1 << 28);
                    osal.lpTrace(3, 0xA004);
                    const capv2: u8 = phy_i2c_readReg(99, 1, 6);
                    osal.lpTrace(3, 0xA005);
                    board.log.line("bt probe: mstclk before={x:0>8} regi2c=0x{x:0>2}", .{ before, capv2 });
                    // **轮 53**：DEVICE_EN 位图（bits[11:0] 每模拟设备一位）
                    const deven: u32 = @as(*volatile u32, @ptrFromInt(0x2081_3014)).*;
                    const ctrl0: u32 = @as(*volatile u32, @ptrFromInt(0x2081_3000)).*;
                    board.log.line("bt probe: deven={x:0>8} lpctrl0={x:0>8}", .{ deven, ctrl0 });
                    // **轮 53 判别**：deven=0 = 全设备掉电。全置 0xFFF 再读：
                    // 非零 ⇒ 设备电源 = 真墙（之后二分定位 RF 位）；仍 0 ⇒ 设备位
                    // 不是电源门，回到 PMU 域审计。
                    @as(*volatile u32, @ptrFromInt(0x2081_3014)).* = 0xFFF;
                    osal.lpTrace(3, 0xA006);
                    const capv3: u8 = phy_i2c_readReg(99, 1, 6);
                    osal.lpTrace(3, 0xA007);
                    board.log.line("bt probe: deven->FFF regi2c=0x{x:0>2} deven_now={x:0>8}", .{ capv3, @as(*volatile u32, @ptrFromInt(0x2081_3014)).* });
                    // **轮 59**：blob 的 event_init 快照（是否给 LL 命令事件注册过回调）
                    if (!evinit_dumped) {
                        evinit_dumped = true;
                        const n = osal_last_event_init_n.*;
                        board.log.line("bt probe: evinit total={d}", .{n});
                        // 按槽匹配：命令事件槽（*(0x2f01101c)+12）的 init 记录
                        const eo_scan: usize = @as(*volatile usize, @ptrFromInt(0x2f01_101c)).* + 12;
                        var k2: usize = 0;
                        while (k2 < @min(n, 48)) : (k2 += 1) {
                            const idx = if (n < 48) k2 else (n - 48 + k2) % 48;
                            const trio = osal_last_event_init.*[idx];
                            if (eo_scan >= 0x2f00_0000 and trio[0] == eo_scan) {
                                board.log.line("bt probe: CMD-EVENT eo=0x{x:0>8} idx={d} fn=0x{x:0>8} arg=0x{x:0>8}", .{ eo_scan, idx, trio[1], trio[2] });
                            }
                        }
                    }
                }
            }
            // **BB 测量活性判据**（skill：98BC 非判据）：0x47C 0↔0x10000 脉冲
            // + 0x450 振荡 = BB 测量在跑；两者静止 = BB 未启动。
            const m47c: u32 = @as(*volatile u32, @ptrFromInt(0x2010_047C)).*;
            const m450: u32 = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
            const r98 = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
            _ = @as(*volatile u32, @ptrFromInt(0x2010_F818)).*; // ANA_CONF0（活值：txphase 已稳定=1 多轮）
            _ = @as(*volatile u32, @ptrFromInt(0x2010_F800)).*; // I2C0_CTRL（活值：本轮诊断行不加，见 burst 快照）
            const fe_cnt = @as(*volatile u32, @ptrFromInt(0x2010_11AC)).*;
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
            // **轮 57**：e32 = ble_hci_trans_env[32]（cfg_ll 注册的 LL cmd 入口）
            // 与 c32（btdm ctx[32]）不同层——A 路径走后者，B 路径走前者。
            // **轮 58**：LL 命令事件排队态——FJxPPD 把命令包进 *(0x2f01101c)+12
            // 的单一静态事件，is_queued≠0 时一切后续命令返回 7 丢弃。读它！
            var evq: u32 = 0;
            var evcb: u32 = 0;
            var evarg: u32 = 0;
            {
                const ep2: usize = @as(*volatile usize, @ptrFromInt(0x2f01_101c)).*;
                if (ep2 >= 0x2f00_0000 and ep2 < 0x2f90_0000 and ep2 % 4 == 0) {
                    const eo: usize = ep2 + 12;
                    evq = @bitCast(wr_btdm_osal_event_is_queued(@ptrFromInt(eo)));
                    // **轮 58b**：eo = Slot 桩（+0 = 池 Event 指针）；fn_/arg 在池对象里
                    const evp: usize = @as(*volatile usize, @ptrFromInt(eo)).*;
                    if (evp >= 0x2f00_0000 and evp < 0x2f90_0000 and evp % 4 == 0) {
                        evcb = @as(*volatile u32, @ptrFromInt(evp + 4)).*; // Event.fn_
                        evarg = @as(*volatile u32, @ptrFromInt(evp + 8)).*; // Event.arg
                    }
                }
            }
            var e32: u32 = 0;
            {
                const ep: usize = @as(*volatile usize, @ptrFromInt(0x2f01_10fc)).*;
                if (ep >= 0x2f00_0000 and ep < 0x2f90_0000 and ep % 4 == 0) {
                    e32 = @as(*volatile u32, @ptrFromInt(ep + 32)).*;
                }
            }
            board.log.line("bt probe: icg {x}->{x} rfready={d} fe={d} rst={x:0>8} qput={d} getok={d} evrun={d}/{d} evt={d} e32=0x{x:0>8} evq={d} evcb=0x{x:0>8} evarg=0x{x:0>8} brg={d}/{d}/{d}", .{
                icg_bt,
                icg_after,
                (r98 >> 2) & 1,
                fe_cnt,
                rst_or,
                st.eventq_put,
                st.eventq_get_ok,
                st.event_run_count,
                st.event_run_no_slot,
                transport.stats().evt_count,
                e32,
                evq,
                evcb,
                evarg,
                bringup.bridge_w,
                bringup.bridge_ran,
                bringup.bridge_dropped,
            });
            rst_or = 0;
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
    while (off < len) : (off += 32) {}
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
pub fn flashStageExtra(n: u32, a: u32, b: u32) void {
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

// ---------------------------------------------------------------------------
// HCI 一致性自检（Bluetooth Core 5.4，Vol 4 Part E）：对真实 controller 发只读的本地信息命令，
// 逐条按规范校验回包。在脚本里**同步**跑完：位置在 A 阶段（三条基础命令都拿到回包）之后、任何射频
// 实验之前——脚本在进主循环之前就停在 0x200A 的 synth 墙上，挂在主泵循环上永远轮不到。
// A 路径的回包在 `sendCmd` 返回之前就经 `btdmTx` 到达（日志里 `btdm_tx` 逐条 +1），所以
// `hciConformanceRun()` 把 `hciConformanceTick()` 的状态机连着推进到收尾即可；推进一步的逻辑仍在
// `hciConformanceTick()` 里，需要非阻塞的调用方可以直接用它。
// 规则与解码在 `hci_conformance.zig`（纯逻辑，主机可测）；这里只管时序与打印。
// ---------------------------------------------------------------------------

const hci_conformance = @import("hci_conformance.zig");

/// 开跑前先等这么久：让 A 阶段最后一条命令之后还可能到达的事件先到，
/// 免得被当成本自检第一条命令的回包。
const hci_conf_start_delay_us: u64 = 200_000;
/// 一条命令等回包的上限。规范 §4.4 建议主机用 1 s 的回包超时；这里留到 2 s。
const hci_conf_timeout_us: u64 = 2_000_000;
var hci_conf_entered_us: ?u64 = null;
/// 发到第几条；等于 `commands.len` 时下一步是收尾，超过则已收尾。
var hci_conf_idx: usize = 0;
var hci_conf_sent: bool = false;
var hci_conf_sent_us: u64 = 0;
var hci_conf_seq_at_send: u32 = 0;
var hci_conf_passed: u32 = 0;
var hci_conf_failed: u32 = 0;
var hci_conf_supported: u32 = 0;
var hci_conf_not_supported: u32 = 0;
/// HCI_Read_Local_Supported_Commands 的回包。读到之前 `hci_conf_have_mask` 为假，判决时跳过位检查。
var hci_conf_mask: [64]u8 = @splat(0);
var hci_conf_have_mask: bool = false;
/// 当前这条命令已经为它打过几行原始字节（只有没通过的回包才打，每条至多两行）。
var hci_conf_raw_lines: u32 = 0;

fn hciConfHex(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (bytes) |b| {
        if (n + 2 > out.len) break;
        out[n] = digits[b >> 4];
        out[n + 1] = digits[b & 0x0f];
        n += 2;
    }
    return out[0..n];
}

/// 打一行回包的原始字节（至多 13 个八位组）与来处：回包到底长什么样，由板上数据说话。
fn hciConfDumpRaw(cmd: hci_conformance.Command, evt: []const u8) void {
    if (hci_conf_raw_lines >= 2) return;
    hci_conf_raw_lines += 1;
    const st = transport.stats();
    var hx: [26]u8 = undefined;
    board.log.line("read: hci {s} reply via {s} pkt_type={d} n={d} raw={s}", .{
        cmd.name,
        if (st.last_evt_from_btdm) "btdm" else "hs",
        st.last_evt_pkt_type,
        evt.len,
        hciConfHex(&hx, evt[0..@min(evt.len, 13)]),
    });
}

/// 推进一步（见本节文件头注释）。
pub fn hciConformanceTick() void {
    if (hci_conf_idx > hci_conformance.commands.len) return;
    const now = board.hw.nowUs();
    if (hci_conf_entered_us == null) hci_conf_entered_us = now;
    const t0 = hci_conf_entered_us.?;
    if (hci_conf_idx == hci_conformance.commands.len) {
        board.log.line("hci-conformance: checks passed={d} failed={d} total={d} supported={d} not_supported={d}", .{
            hci_conf_passed,    hci_conf_failed,        hci_conf_passed + hci_conf_failed,
            hci_conf_supported, hci_conf_not_supported,
        });
        hci_conf_idx += 1;
        return;
    }
    const cmd = hci_conformance.commands[hci_conf_idx];
    if (!hci_conf_sent) {
        if (now - t0 < hci_conf_start_delay_us) return;
        hci_conf_seq_at_send = transport.evtSeq();
        hci_conf_sent_us = now;
        hci_conf_raw_lines = 0;
        const rc = transport.sendCmd(cmd.opcode, cmd.params);
        hci_conf_sent = true;
        if (rc != 0) {
            hci_conf_failed += 1;
            board.log.line("check: hci {s} (0x{x:0>4}) send rc={d} ok=0", .{ cmd.name, cmd.opcode, rc });
            hci_conf_idx += 1;
            hci_conf_sent = false;
        }
        return;
    }
    // 已发，等回包。**超时先判**：回包不是本命令的 Command Complete 时下面会一直落到 `other_event`，
    // 超时判断若排在它后面就永远走不到（2026-11-24 板上实测：Read Buffer Size 的回包不是
    // Command Complete，主上下文在这一步无限空转）。
    if (now - hci_conf_sent_us > hci_conf_timeout_us) {
        hci_conf_failed += 1;
        board.log.line("check: hci {s} no matching reply within {d} ms ok=0", .{ cmd.name, hci_conf_timeout_us / 1000 });
        hci_conf_idx += 1;
        hci_conf_sent = false;
        return;
    }
    // 以事件序号有没有变为准。
    if (transport.evtSeq() == hci_conf_seq_at_send) return;
    const evt = transport.lastEvent();
    const verdict = hci_conformance.verifyDeclared(cmd, evt, if (hci_conf_have_mask) &hci_conf_mask else null);
    switch (verdict) {
        // 别的事件，或不是这条命令的回包：继续等（超时已在上面保证）。
        .other_event => hciConfDumpRaw(cmd, evt),
        .ok => |r| {
            var text: [96]u8 = undefined;
            hci_conf_passed += 1;
            hci_conf_supported += 1;
            board.log.line("check: hci {s} {s} ok=1", .{ cmd.name, hci_conformance.describe(cmd, r, &text) });
            if (cmd.kind == .supported_commands) {
                @memcpy(&hci_conf_mask, &r.supported_commands);
                hci_conf_have_mask = true;
                // 整张位图打出来（4 行 × 16 八位组）：之后每条命令的位检查、以及读日志的人，都靠它。
                var line: [96]u8 = undefined;
                var off: usize = 0;
                while (off < 64) : (off += 16) {
                    board.log.line("read: hci supported_commands[{d}..{d}]={s}", .{
                        off, off + 15, hciConfHex(&line, r.supported_commands[off..][0..16]),
                    });
                }
            }
            hci_conf_idx += 1;
            hci_conf_sent = false;
        },
        .not_supported => {
            hci_conf_passed += 1;
            hci_conf_not_supported += 1;
            board.log.line("check: hci {s} not supported (status=0x01) class={s} ok=1", .{ cmd.name, @tagName(cmd.support) });
            hci_conf_idx += 1;
            hci_conf_sent = false;
        },
        .fail => |v| {
            hci_conf_failed += 1;
            hciConfDumpRaw(cmd, evt);
            board.log.line("check: hci {s} {s} detail={d} ok=0", .{ cmd.name, @tagName(v.rule), v.detail });
            hci_conf_idx += 1;
            hci_conf_sent = false;
        },
    }
}

/// 同步跑完整个自检（见本节文件头注释），返回「全过」。等待期间照常喂狗：正常情况下每条命令的
/// 回包都在 `sendCmd` 返回前到达，整个自检只占几十毫秒；没有匹配回包的命令各空转至多
/// `hci_conf_timeout_us`。
pub fn hciConformanceRun() bool {
    while (hci_conf_idx <= hci_conformance.commands.len) {
        hciConformanceTick();
        if (!wdt_suicide) {
            board.hw.mwdt1Feed();
            board.hw.feedRtcWdt();
        }
    }
    return hci_conf_failed == 0;
}
