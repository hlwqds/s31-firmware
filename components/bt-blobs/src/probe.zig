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
const config = @import("config.zig");
const bringup = @import("bringup.zig");
const transport = @import("transport.zig");
const sched = @import("osal_kit").sched;
const porting = @import("porting.zig");
const board = @import("board");

/// 归档里的 BT 基带初始化（`libbtbb.a` 提供；IDF 的 `esp_btbb_enable` 就是调它）。
extern fn bt_bb_v2_init_cmplx(version_print: c_int) c_int;

/// 链接脚本 `s31.ld` 的堆边界是**绝对符号**：取地址得到边界值，
/// 声明成 `usize` 会变成"去那个地址读一个 usize"。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}

/// 是否在探针里开中断。默认 **false**：先排除"ISR 打印打断 ROM UART 写"这个变量。
pub var probe_irqs: bool = true; // 判别实验：只让 ISR 写串口

var cfg: config.Config = .{};
var ctrl_task: ?*sched.Task = null;

// ---- 钩子：**必须在 init 链之前装**，否则最关键的观测手段就没了 ----

/// ⚠ 单位是**毫秒**：注入 `nowUs()/1000`。直接注入 `nowUs()` 会让所有超时窗口大 1000 倍，
/// 症状是"起来了但永远不超时/不动作"，极难归因。
fn nowMs() u32 {
    return @intCast(board.hw.nowUs() / 1000);
}
/// **实验脚手架开关**（全部默认关）：这些是排查"卡在 0x2010B000"时用的一次性装置，
/// 保留是为了可复现，但默认不干扰正常 bring-up。
/// - `dump_rom`：启动时 dump ROM 区与 UART0 寄存器（离线反汇编用）
/// - `ble_block_experiment`：复位脉冲 + 时钟重开 + `bt_bb_v2_init_cmplx` + 读 `0x2010B000`
pub var dump_rom: bool = false;
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
fn dumpAtPend() void {
    if (dump_done or osal.caller_n < 22) return; // 推迟到 event_init 一族之后
    // **按字节预算**：1 行计数（~20 B）+ 3 条截断到 24 B 的消息，合计 < 110 B。
    board.log.line("D{d}.{d}", .{ log_hook_calls, osal.caller_n });
    var mi: u32 = 0;
    while (mi < 3) : (mi += 1) {
        const m = ringAt(mi);
        if (m.len > 0) board.log.line("M{s}", .{m[0..@min(m.len, 24)]});
    }
    dump_done = true;
}


pub fn ringCount() u32 { return log_ring_n; }
pub fn logcCount() u32 { return log_hook_calls; }

pub fn ringAt(idx: u32) []const u8 {
    if (idx >= log_ring_n) return "";
    const slot = (log_ring_n -% 1 -% idx) % ring_slots;
    return log_ring[slot][0..log_ring_lens[slot]];
}
pub var log_hook_ours: u32 = 0;
pub var log_hook_other: u32 = 0;
/// 对照实验：为 true 时 logHook 只计数，把 UART 让出来（否则采样全落在它里面）。
pub var log_hook_silent: bool = true; // 窗口内整体静音：让 FIFO 空着给 DUMP 用 // 实验表明会同时静音我们自己的进度日志，故默认关闭

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
        osal.logPublic("bt probe: arena {d} B", .{he - hs});
    } else {
        osal.logPublic("bt probe: FATAL no heap region", .{});
        halt();
    }

    // 2) init 链（15 步）
    cfg = config.defaults();
    osal.logPublic("bt probe: init start", .{});
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
    var rc = bringup.init(&cfg);
    if (rc != 0) {
        osal.logPublic("bt probe: init FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    osal.logPublic("bt probe: init ok, arena free={d} B", .{osal.arenaFree()});

    // 3) enable 链（6 步）
    rc = bringup.enable();
    if (rc != 0) {
        osal.logPublic("bt probe: enable FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
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
    rc = transport.sendResetViaHs();
    osal.logPublic("bt probe: sendReset rc={d}", .{rc});

    var round: u32 = 0;
    while (round < 200) : (round += 1) {
        osal.logPublic("bt task round {d}", .{round});
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        _ = osal.serviceCallouts(osal.timeGet());
        if (transport.stats().evt_count > 0) {
            osal.logPublic("bt probe: GOT {d} EVT, last code=0x{x:0>2}", .{ transport.stats().evt_count, transport.stats().last_evt_code });
            halt();
        }
    }
    osal.logPublic("bt probe: no EVT after {d} rounds (evt_count=0)", .{round});
    halt();
}

/// 把 **osal 记录的归档调用点**打出来（panic 时由 board 调）。
/// 这些返回地址是归档自己的 PC —— 采样被我们的钩子占据时，这是唯一的归档侧落点。
fn dumpOsalCallers() void {
    // 先报"我跑了 + 计数是多少"：分开「钩子没被调用」与「环真的空」。
    board.log.line("panic: lc ours={d} other={d} total={d}", .{ log_hook_ours, log_hook_other, log_hook_calls });
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

fn halt() noreturn {
    while (true) {
        asm volatile ("" ::: .{ .memory = true });
    }
}
