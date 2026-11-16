//! 第一次真正执行 blob 代码的探针（R3 的 milestone）。
//!
//! 做四件事：装 osi 表进 ROM 槽位 → 构造 `wifi_init_config_t` → 调
//! `esp_wifi_init_internal` → 打印返回码与"哪些桩被调用过"，然后停机。
//!
//! 判读方式：
//!   - 返回码非 0 且 `osi_stubs.hits` 有非零项 → 那个钩子就是 blob 要的第一样东西；
//!   - 返回码非 0 但 hits 全 0 → 失败发生在真正执行 blob 之前（config 校验/magic）；
//!   - 直接 trap → 落在哪个地址由 trap 处理打印，配 `link_stubs`/`osi_stubs` 的计数区分阶段。
//!
//! **只在 `-Dwifi-init-probe=true` 时参与构建**：常规镜像不受影响。

const std = @import("std");

/// 供 start.zig 做 comptime 选择：探针构建为 true。
pub const enabled = true;
const board = @import("board");
const trap = board.trap;
const log = board.log;
const hw = board.hw;
const rng = board.rng;

const osi = @import("osi.zig");
const impl = @import("osi_impl.zig");
const initcfg = @import("init_config.zig");
const osi_stubs = @import("osi_stubs.zig");
const sched = @import("sched.zig");
const phy_init_data = @import("phy_init_data.zig");
const event_bus = @import("event_bus.zig");
const link_stubs = @import("link_stubs.zig");

/// blob 里的入口（`esp_wifi.h:437` / `esp_private/wifi.h`）。
const esp_wifi_init_internal = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{
    .name = "esp_wifi_init_internal",
});

/// 收发接缝（`esp_private/wifi.h:485/578/819`）：
/// - `esp_wifi_internal_reg_rxcb(ifx, fn)`：注册**我们的**回调，blob 收到帧后调它；
/// - `esp_wifi_internal_tx(ifx, buf, len)`：把帧交给 blob 发；
/// - `esp_wifi_internal_get_config_channel(ifx, &primary, &second)`：查当前信道。
const reg_rxcb = @extern(*const fn (u32, *const fn (?*anyopaque, u16, ?*anyopaque) callconv(.c) c_int) callconv(.c) c_int, .{ .name = "esp_wifi_internal_reg_rxcb" });
/// 探针是否在 init 阶段真的发一帧（实验开关：false = 不弄脏 TX 引擎）。
const probe_send_init_frame = false;
/// 探针是否注册 RX 回调（实验开关：false = 不让 RX 引擎认为有人持有缓冲）。
const probe_register_rxcb = false;
const wifi_tx = @extern(*const fn (u32, ?*anyopaque, u16) callconv(.c) c_int, .{ .name = "esp_wifi_internal_tx" });
const get_config_channel = @extern(*const fn (u32, *u8, *u8) callconv(.c) c_int, .{ .name = "esp_wifi_internal_get_config_channel" });

var rx_frames: u32 = 0;

// ---- 上下文切换自检（两根栈）----
var static_stack: [16 * 1024]u8 align(16) = undefined;
/// ROM 的 PP worker（`ppTask = 0x2f800fc0`）自己的栈与上下文：它是任务体（死循环），
/// 只能像 blob 任务那样"给栈 + 切进去"，不能直接调用（实测直接 call 后采样停止）。
var pp_stack: [16 * 1024]u8 align(16) = undefined;
var pp_ctx: sched.Context = .{};
/// PHY 标定数据（`esp_phy_calibration_data_t.opaque[1894]`），由 `register_chipv7_phy` 填充。
/// `esp_phy_calibration_data_t` = version[4] + mac[6] + opaque[1894] = **1904** 字节。
/// 之前只声明 1894 字节并把 `&cal_data` 当结构体起点传给 `register_chipv7_phy`：
/// 库会把前 10 字节当 version/mac，并读写数组末尾之后 10 字节（越界）。
/// IDF 的真实路径（phy_init.c:895-960）：calloc(1904) → 从 NVS 读标定（空分区 ⇒ 失败 ⇒ FULL）
/// → 把 station MAC 写进 `cal_data->mac` → `register_chipv7_phy(init_data, cal_data, FULL)`。
var cal_data: [1904]u8 align(8) = @splat(0);

/// 实验开关：是否在 init 阶段就注册 PHY。false = 交给 `_phy_enable`（IDF 的真实顺序）。
const probe_register_phy_at_init = false;
/// 实验开关：是否在**探针 init** 阶段就写 CLK_CONF1 / FORCE_ON。
/// IDF 实测：`after-esp_wifi_init` 时 `CLK_CONF1 = 0`（Wi-Fi 时钟是在 **start** 期间由
/// `_wifi_clock_enable` 打开的，值才变成 0x38e7ff）。我们此前在 init 就把 MAC 时钟打开，
/// 比 IDF 早了一个阶段。false = 交给钩子（与 IDF 一致）。
const probe_clock_at_init = true; // 实测必须 true：关掉会让 FE/BB 时钟写序列 stall
/// 实验开关：探针是否在 start 前手动调 ROM 的 PHY/MAC 入口。IDF 的 wrapper **不会**这么做，
/// 打开会把状态机推到半初始化态，干扰"到底缺哪一步"的判断。默认全关，走干净路径。
const probe_manual_phy_calls = false;
const probe_manual_ic_mac_init = false;

/// `_phy_enable(modem)` 的真实实现：首次调用做 `register_chipv7_phy`（IDF 的
/// `esp_phy_enable` → `esp_phy_load_cal_and_init` 就是这个时机）。
var phy_registered = false;
fn phyEnableHook(modem: u32) usize {
    if (phy_registered) return 0;
    const register_phy = @extern(*const fn (*const [128]u8, *[1894]u8, u32) callconv(.c) c_int, .{
        .name = "register_chipv7_phy",
    });
    // 把 station MAC 写进 `cal_data->mac`（偏移 4，6 字节）——IDF 在标定前就是这么做的；
    // 标定数据是 MAC 绑定的（`phy_rfcal_data_check_new`/`_sub_new` 会校验）。
    @memcpy(cal_data[4..10], &[_]u8{ 0x1c, 0x29, 0x04, 0xd1, 0x99, 0x28 });
    const rc = register_phy(&phy_init_data.params, @ptrCast(&cal_data), 2); // PHY_RF_CAL_FULL
    phy_registered = true;
    log.line("wifi-init-probe: _phy_enable(modem={d}) -> register_chipv7_phy rc={d}", .{ modem, rc });
    return 0;
}
/// `phy_init_magic_pre`：必须紧贴在 `phy_init_data.params` 之前（IDF 的布局约定）。
var magic_pre: [8]u8 = @splat(0);
/// `phy_init_magic_post`：紧贴之后。
var magic_post: [8]u8 = @splat(0);
var main_ctx: sched.Context = .{};
var task_ctx: sched.Context = .{};

fn schedTestEntry(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        log.line("sched-test: task iteration {d} (yielding)", .{i});
        sched.swapContext(&task_ctx, &main_ctx); // 让出：切回主上下文
        log.line("sched-test: task iteration {d} resumed", .{i});
    }
    log.raw("sched-test: task done, returning to main\n");
}

/// 自检：任务在自己的栈上跑 3 轮，每轮让出一次；主上下文依次恢复。
fn runSchedSelfTest() void {
    // 先用**静态**栈：把 arena 的分配/对齐变量排除掉，只测切换原语。
    sched.initContext(&task_ctx, &static_stack, &schedTestEntry, null);
    log.line("sched-test: begin, task sp=0x{x:0>8} stack=0x{x:0>8}", .{
        task_ctx.sp,
        @intFromPtr(&static_stack),
    });
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        if (i == 0) {
            sched.start(&task_ctx, &main_ctx); // 第一次进入任务
        } else {
            sched.swapContext(&main_ctx, &task_ctx); // 恢复任务
        }
        log.line("sched-test: main resumed after round {d} (main_sp=0x{x:0>8} task_sp=0x{x:0>8})", .{
            i,
            main_ctx.sp,
            task_ctx.sp,
        });
    }
    log.raw("sched-test: PASS\n");
}

/// `wifi_rxcb_t`（`wifi.h:564`）：`esp_err_t (*)(void *buffer, uint16_t len, void *eb)`。
fn rxCb(buffer: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c_int {
    rx_frames += 1;
    if (rx_frames <= 2) log.line("wifi-init-probe: rx frame len={d} buf=0x{x:0>8} eb=0x{x:0>8}", .{
        len,
        @intFromPtr(buffer),
        @intFromPtr(eb),
    });
    return 0;
}

/// 静态 osi 表（见 run() 里的说明）。
var osi_table: osi.Osi = undefined;

/// 合作式让出点：任务体阻塞时被调用。计数并在有限次后停机——证明"任务存活且会让出"，
/// 而不是把 CPU 卡在忙等里。生产路径里这里就是主循环（收包/发送）。
var idle_calls: u32 = 0;
var ready_swaps: u32 = 0;
/// 当前控制权是否在任务上下文里。
var in_task: bool = false;
/// 任务上下文是否已经建立（建立前 idle 只计数）。
var task_ctx_ready: bool = false;

/// 合作式调度的核心：主上下文与任务上下文互相让出。
///
/// - 在**主**上下文里被调用（blob API 阻塞等任务应答）→ 切到任务；
/// - 在**任务**上下文里被调用（任务阻塞收消息）→ 切回主上下文。
fn idleHook() void {
    idle_calls += 1;
    if (idle_calls == 1) log.raw("wifi-init-probe: task blocked -> yielded to idle hook\n");
    // 每 1000 次让出打一行：区分"在乒乓（任务没答话）"与"blob 忙等（根本不进钩子）"。
    if (idle_calls % 1000 == 0) log.line("wifi-init-probe: idle_calls={d} in_task={} hooks={d}", .{
        idle_calls,
        in_task,
        impl.event_count,
    });
    if (idle_calls > 20_000) {
        log.line("wifi-init-probe: idle budget exhausted ({d}), halting", .{idle_calls});
        hw.halt();
    }
    if (!task_ctx_ready) return;
    // 诊断：任务就绪后前 6 次让出（不依赖 idle_calls 的累计值）。
    ready_swaps += 1;
    if (ready_swaps <= 24) log.line("wifi-init-probe: swap#{d} in_task={} hooks={d}", .{
        ready_swaps,
        in_task,
        impl.event_count,
    });
    if (in_task) {
        in_task = false;
        impl.current_is_task = false;
        sched.swapContext(&task_ctx, &main_ctx); // 任务让出
        in_task = true; // 被恢复：回到任务上下文
        impl.current_is_task = true;
    } else {
        in_task = true;
        impl.current_is_task = true;
        sched.swapContext(&main_ctx, &task_ctx); // 主上下文让出给任务
        in_task = false;
        impl.current_is_task = false;
    }
}

/// 钩子预算耗尽：说明"任务体卡在哪个等待原语上"，然后停机。
fn budgetExhaustedHook(total: u32) void {
    log.line("wifi-init-probe: hook budget exhausted after {d} calls", .{total});
    const n = @min(total, impl.events.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const idx = (total - n + i) % impl.events.len;
        const e = impl.events[idx];
        // 先打 id 数字，再在**边界内**才打名字：越界索引会把 .rodata 里的字符串头
        // 当 `{s}` 解引用（实测 mtval=0x69666977，正是 "wifi" 的 ASCII）。
        if (e.id < impl.hook_ids.len) {
            log.line("wifi-init-probe:   hook[{d}] {s} a0=0x{x:0>8} a1=0x{x:0>8}", .{
                i,
                impl.hook_ids[e.id],
                e.a0,
                e.a1,
            });
        } else {
            log.line("wifi-init-probe:   hook[{d}] id={d}(OOB) a0=0x{x:0>8} a1=0x{x:0>8}", .{
                i,
                e.id,
                e.a0,
                e.a1,
            });
        }
    }
    hw.halt();
}

/// 逐行追踪钩子调用（上限 40 行，避免刷屏）。
var trace_lines: u32 = 0;

fn traceNote(id: u8, a0: usize, a1: usize) void {
    // 追踪 take(0)/give(1)/queue_recv(4)/queue_send(5)/alloc(13)：
    // 关键问题是"任务到底有没有收到我们发的消息"（send 句柄 0x2f01d940 vs recv 句柄）。
    // 定时器相关的 id（16..19）也放行：要回答"blob 在自旋前到底有没有 setfn/arm 过定时器"。
    // 放行全部已登记 id（新增 id 只要进了 hook_ids 就能打，不必再改这里）。
    if (id >= impl.hook_ids.len) return;
    if (trace_lines >= 200) return;
    trace_lines += 1;
    const name = if (id < impl.hook_ids.len) impl.hook_ids[id] else "?";
    if (id == 12) { // event_post：顺带打"有多少处理器、有多少落空"
        log.line("wifi-init-probe: trace event_post id={d} bits=0x{x} handlers={d} undispatched={d}", .{
            a0, a1, event_bus.count, event_bus.undispatched,
        });
        trace_lines += 1;
        return;
    }
    log.line("wifi-init-probe: trace {s} a0=0x{x:0>8} a1=0x{x:0>8}", .{ name, a0, a1 });
}

fn nowUsHook() u64 {
    return hw.nowUs();
}
fn fillRandomHook(dst: []u8) void {
    rng.fill(dst);
}
fn macHook() [6]u8 {
    return .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
}

/// C shim 的回调：把驱动自己的报错原样打到串口（只有格式串，变参不展开）。
pub export fn s31_printf_hook(msg: ?[*:0]const u8) void {
    const m = msg orelse return;
    log.line("wifi-blob: {s}", .{std.mem.span(m)});
}

/// `_log_write` 的 C 实现（变参），取地址填进表。
const s31_log_write = @extern(*const anyopaque, .{ .name = "s31_log_write" });

pub fn run() noreturn {
    log.raw("wifi-init-probe: begin\n");
    // 复位态基线：在任何 blob 代码跑之前读一次 MAC 状态寄存器，
    // 用来区分"busy{13..15} 是复位默认"还是"init 里被谁置起来的"。
    {
        const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
        log.line("wifi-init-probe: MAC_ST at begin = 0x{x:0>8}", .{mac_st.*});
    }
    // TIMG0 T0 是本仓的时间基（1 MHz）；探针构建不会自动初始化它，
    // 不初始化则 nowUs() 恒 0（实测），超时/采样中断都无从谈起。
    hw.initTimer();

    // 1) 分配器缓冲：链接脚本给的堆区间（_heap_start.._heap_end，绝对符号取地址）。
    const heap_start: [*]u8 = @ptrFromInt(@intFromPtr(heapStart()));
    const heap_end: [*]u8 = @ptrFromInt(@intFromPtr(heapEnd()));
    const heap_len = @intFromPtr(heap_end) - @intFromPtr(heap_start);
    impl.initArena(heap_start[0..heap_len]);
    log.line("wifi-init-probe: arena={d} B", .{heap_len});

    // 2) 注入硬件钩子（组件不 import board）
    impl.setHooks(.{
        .now_us = &nowUsHook,
        .fill_random = &fillRandomHook,
        .mac = &macHook,
        .on_budget_exhausted = &budgetExhaustedHook,
        .on_idle = &idleHook,
        .on_note = &traceNote,
        .on_phy_enable = &phyEnableHook,
    });

    // 3) 建表；**不预装**，让 wifi_osi_funcs_register 自己校验并注册（IDF 的流程）
    // 表必须是**静态**的：ROM 在 `g_osi_funcs_p` 槽位里长期持有这个指针，
    // 栈上（`run()` 的局部变量）的表在返回后就失效——生产路径同理，所以放文件作用域。
    osi_table = impl.makeTable();
    osi_table._log_write = s31_log_write; // C 变参 shim
    const table = &osi_table;
    const cfg = initcfg.defaults(table);
    log.line("wifi-init-probe: table=0x{x:0>8} cfg magic=0x{x:0>8} crypto size={d}", .{
        @intFromPtr(table),
        @as(u32, @bitCast(cfg.magic)),
        cfg.wpa_crypto_funcs.size,
    });

    // 4) 完整 init（干净路径）。**只能调一次**：重复初始化会在第二次进入时解引用无效指针
    //    （实测 exception code=5）。
    // IDF 的 `esp_wifi_init` wrapper 在 `esp_wifi_init_internal` **之前**调 `coex_init()`
    // （wifi_init.c），我们一直没做；`g_coex_param_ptr` 为 0 也与此吻合。
    {
        const coex_init = @extern(*const fn () callconv(.c) void, .{ .name = "coex_init" });
        log.raw("wifi-init-probe: calling coex_init() (IDF wrapper 顺序)\n");
        coex_init();
        log.raw("wifi-init-probe: coex_init returned\n");
    }
    // **b14 前置实验（B 判定）**：把强制置位提前到 init **之前**。若 init 里真的会调使能函数
    // （0x40034d1a），它应当走到结尾并写下 b288/b16=1；否则说明那条调用路径压根没执行。
    const bg_pre = @as([*]volatile u8, @ptrFromInt(0x2f013d30));
    log.line("wifi-init-probe: pre-init ctx b14={d} b15={d} b288={d} cb_slot=0x{x}", .{
        bg_pre[14],                                    bg_pre[15], bg_pre[288],
        @as(*volatile u32, @ptrFromInt(0x2f011aa8)).*,
    });
    // **ctx[15] 前置实验**：wrapper 0x40035ea8 的第一道门就是 ctx[15]；实测它在 init 跑到 ~#512 才变 1，
    // 也就是说 init 走到那次 enable 调用时它还是 0 -> 被跳过 -> 之后无人重试。这里提前置 1。
    // 判据：post-init 的 b16/b27/b288 是否变 1（成功路径标志），而不是 mac（deinit 命令字会污染 en 位）。
    bg_pre[15] = 1;
    const init_rc = esp_wifi_init_internal(&cfg);
    log.line("wifi-init-probe: post-init ctx b14={d} b15={d} b16={d} b27={d} b288={d} b289={d} mac=0x{x:0>8}", .{
        bg_pre[14],                                    bg_pre[15], bg_pre[16], bg_pre[27], bg_pre[288], bg_pre[289],
        @as(*volatile u32, @ptrFromInt(0x20104CAC)).*,
    });
    log.line("wifi-init-probe: esp_wifi_init_internal rc={d}", .{init_rc});
    {
        const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
        log.line("wifi-init-probe: MAC_ST after init = 0x{x:0>8}", .{mac_st.*});
    }
    if (init_rc == 0) {
        log.line("wifi-init-probe: INIT OK, arena free={d}/{d} B, bad_handle={d}, blocking_refused={d}", .{
            impl.arena_state.bytes_free,
            impl.arena_state.bytes_total,
            impl.bad_handle,
            impl.blocking_refused,
        });
        log.line("wifi-init-probe: tasks recorded={d}", .{impl.task_count});

        // 先验证上下文切换本身（两根栈），再谈 API 与任务的交错。
        runSchedSelfTest();

        // 协作式跑一次登记的任务：没有调度器，`entry(arg)` 一旦进入自己的等待循环就永不返回，
        // 所以给钩子调用一个预算（300 次），耗尽即打印现场并停机。
        if (impl.task_count > 0) {
            const task = impl.tasks[0];
            if (task.entry) |entry| {
                // PHY bring-up：`register_chipv7_phy` 在 libphy.a 里
                // （签名见 `esp_private/phy.h:45`），真实 IDF 在 `esp_phy_init` 里调它。
                // 之前没做这一步，`wifi_start_process` 的 `adc2_wifi_acquire` 与任务侧上下文都停在
                // 未初始化状态。cal_data 是 1894 字节不透明缓冲（`esp_phy_calibration_data_t`）。
                {
                    // `register_chipv7_phy` 一开头就访问这两个绝对地址（反汇编 0x68/0xf2 处）：
                    //   0x20109c18：lw → 清 bit1 → sw
                    //   0x20100800：lw → sw
                    // 如果调制解调器域还没上电，这些访问会**挂起而不报异常**——正好解释"不返回也不 fault"。
                    // 先单独读一次：读得通就说明不是域的问题，读不通就是它。
                    const reg_rtc: *volatile u32 = @ptrFromInt(0x2010_9c18);
                    const reg_modem: *volatile u32 = @ptrFromInt(0x2010_0800);
                    log.line("wifi-init-probe: pre-PHY regs: 0x20109c18=0x{x:0>8} 0x20100800=0x{x:0>8}", .{
                        reg_rtc.*,
                        reg_modem.*,
                    });
                    // 逐个调用它的前序函数，定位挂起点（register_chipv7_phy 只调这 5 个）：
                    //   phy_get_romfunc_addr / phy_force_txrx_off / phy_freq_module_resetn /
                    //   phy_dis_hw_set_freq / phy_i2c_master_reset
                    // 调制解调器时钟：`MODEM_LPCON_TEST_CONF_REG`（0x2010F000）的 bit0
                    // （`MODEM_LPCON_CLK_EN`，默认 0）。IDF 用 `modem_clock_module_enable(PERIPH_PHY_MODULE)`
                    // 打开它；不打开时 PHY 的 I2C 握手永远等不到完成（`phy_rf_init` 就是挂在那里）。
                    {
                        const clk_reg: *volatile u32 = @ptrFromInt(0x2010_F000);
                        const before = clk_reg.*;
                        clk_reg.* = before | 1;
                        const after = clk_reg.*;
                        log.line("wifi-init-probe: MODEM_LPCON_CLK_EN 0x{x} -> 0x{x}", .{ before, after });
                    }
                    // `MODEM_LPCON_CLK_CONF_REG`（0x2010F018）：bit0 WIFIPWR / bit1 COEX /
                    // bit2 I2C_MST / bit3 LP_TIMER。`phy_rf_init` 的握手走 I2C 模拟主控，
                    // 所以至少要 bit2；一并把 WiFi 电源与 coex 打开。
                    {
                        const conf: *volatile u32 = @ptrFromInt(0x2010_F018);
                        const before = conf.*;
                        // IDF 实测（station 例程）：start 期间 LPCON+18 = **0x7**（bit0 wifipwr /
                        // bit1 coex / bit2 i2c_mst），之后回到 0x1；**bit3(lp_timer) 不开**。
                        // 之前我们写 0b1111 会多开 bit3——按 IDF 的值对齐。
                        conf.* = before | 0b0111;
                        log.line("wifi-init-probe: MODEM_LPCON_CLK_CONF 0x{x} -> 0x{x}", .{ before, conf.* });
                    }
                    // 照 IDF `modem_clock_module_enable(PERIPH_PHY_MODULE)` 移植（S31 分支）：
                    //   deps = MODEM_ADC_COMMON_FE | MODEM_PRIVATE_FE | SOC_PLL_SOURCE_CG | I2C_MASTER
                    // 1) SOC_PLL_SOURCE_CG：`HP_SYS_CLKRST_MODEM_CONF_REG` = 0x3d
                    //    （`modem_clock_hal_enable_soc_pll_source_cg`，`hal/esp32s31/modem_clock_hal.c:122`）
                    // 2) MODEM_ADC_COMMON_FE：`CLK_CONF1` 的 FE_APB(15) / FE_80M(13)
                    // 3) MODEM_PRIVATE_FE：FE_160M(14) / FE_DAC(21) / FE_PWDET_ADC(19) / FE_ADC(20)
                    {
                        const pll: *volatile u32 = @ptrFromInt(0x2058_71E0);
                        const before = pll.*;
                        pll.* = 0x3d;
                        log.line("wifi-init-probe: HP_SYS_CLKRST_MODEM_CONF 0x{x} -> 0x{x}", .{ before, pll.* });
                    }
                    {
                        const conf1: *volatile u32 = @ptrFromInt(0x2010_9C14);
                        const before = conf1.*;
                        // PHY 组（FE）+ `PERIPH_PHY_CALIBRATION_MODULE` 组：
                        // WIFI_BB_44M(2) / WIFI_BB(3) / WIFI_BB_80X1(7) / WIFI_APB(9)。
                        // WIFI_CLOCK_DEPS 对应的完整位集（见 osi_impl.zig 的 wifi_clk_conf1_bits 注释）：
                        // BB 主时钟组 0..8 + WIFI_MAC(9) + WIFI_APB(10) + FE 组 13,14,15,19,20,21。
                        const bits: u32 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) |
                            (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) |
                            (1 << 13) | (1 << 14) | (1 << 15) | (1 << 19) | (1 << 20) | (1 << 21);
                        if (probe_clock_at_init) {
                            conf1.* = before | bits;
                            log.line("wifi-init-probe: MODEM_SYSCON_CLK_CONF1 0x{x} -> 0x{x}", .{ before, conf1.* });
                        } else {
                            log.raw("wifi-init-probe: CLK_CONF1 SKIPPED at init (交给 _wifi_clock_enable)\n");
                        }
                    }
                    // 先打开 force-on 位（使能位不等于上电）：
                    //   SYSCON_FORCE_ON(0x20109C08)：WIFI_APB_FO(2) | FE_FO(3) | FE_APB_FO(4)
                    //   LPCON_FORCE_ON(0x2010F01C)：WIFIPWR_FO(0) | I2C_MST_FO(2)
                    {
                        const fo_sys: *volatile u32 = @ptrFromInt(0x2010_9C08);
                        const before = fo_sys.*;
                        if (probe_clock_at_init) {
                            fo_sys.* = before | (1 << 2) | (1 << 3) | (1 << 4);
                            log.line("wifi-init-probe: SYSCON_FORCE_ON 0x{x} -> 0x{x}", .{ before, fo_sys.* });
                        } else {
                            log.raw("wifi-init-probe: SYSCON_FORCE_ON SKIPPED at init\n");
                        }
                        const fo_lp: *volatile u32 = @ptrFromInt(0x2010_F01C);
                        const b2 = fo_lp.*;
                        fo_lp.* = b2 | (1 << 0) | (1 << 2);
                        log.line("wifi-init-probe: LPCON_FORCE_ON 0x{x} -> 0x{x}", .{ b2, fo_lp.* });
                    }
                    // ★★ 按 IDF 实测值对齐 `MODEM_SYSCON` 的三处（IDF `after-esp_wifi_init`）：
                    //   +00 test_conf = 0x00000100
                    //   +04 clk_conf  = 0x00201002   ← 模拟前端时钟（pwdet/adc/dac），我们**从未写过**
                    //   +08 force_on  = 0x00000000   ← IDF 这里是 0；我们写了 0x1c
                    //   +0c ICG       = 0x64646400
                    {
                        const t0: *volatile u32 = @ptrFromInt(0x2010_9C00);
                        const t4: *volatile u32 = @ptrFromInt(0x2010_9C04);
                        const t8: *volatile u32 = @ptrFromInt(0x2010_9C08);
                        log.line("wifi-init-probe: IDF-align before: +00=0x{x} +04=0x{x} +08=0x{x}", .{ t0.*, t4.*, t8.* });
                        // 注意：**不能**把 force_on(+08) 清 0——IDF 的 +08 是 0，但它有别的上电路径；
                        // 我们靠 FORCE_ON 让 `phy_open_fe_bb_clk` 的写序列不 stall（实测清 0 会卡死）。
                        t0.* = 0x0000_0100;
                        t4.* = 0x0020_1002;
                        log.line("wifi-init-probe: IDF-align after:  +00=0x{x} +04=0x{x} +08=0x{x}", .{ t0.*, t4.*, t8.* });
                    }
                    // ★ `CLK_CONF_POWER_ST`(0x20109C0C) **不是只读状态寄存器，而是各域的 ICG（时钟门控）
                    // 位图**：`modem_syscon_ll_set_{modem_apb,modem_periph,wifi,bt,fe,ieee802154}_icg_bitmap`
                    // 写的都是它（bits 31:28 / 27:24 / 23:20 / 19:16 / 15:12 / 11:8）。
                    // IDF 实测（station 例程 init 之后）= **0x64646400**（apb=6/peri=6/wifi=4/bt=4/fe=4）。
                    // 我们此前从没写过它 → 所有域都被门控 → MAC 永远不跑 → 自旋永不结束。
                    {
                        const st: *volatile u32 = @ptrFromInt(0x2010_9C0C);
                        const before = st.*;
                        st.* = 0x6464_6400;
                        log.line("wifi-init-probe: ICG_POWER_ST 0x{x} -> 0x{x} (IDF=0x64646400)", .{ before, st.* });
                    }
                    // `MODEM_SYSCON_CLK_CONF_POWER_ST_REG`(0x20109C0C)：各域时钟的**实际**状态。
                    // 字段：MODEM_APB[31:28] / MODEM_PERI[27:24] / WIFI[23:20]。
                    {
                        const st: *volatile u32 = @ptrFromInt(0x2010_9C0C);
                        const v = st.*;
                        log.line("wifi-init-probe: CLK_CONF_POWER_ST=0x{x:0>8} apb={d} peri={d} wifi={d}", .{
                            v,
                            (v >> 28) & 0xf,
                            (v >> 24) & 0xf,
                            (v >> 20) & 0xf,
                        });
                    }
                    // 逐条复现 `phy_open_fe_bb_clk` 的写序列（日志在写之前，最后一行即挂点）。
                    {
                        const r0: *volatile u32 = @ptrFromInt(0x2010_0400);
                        log.raw("wifi-init-probe: write 0x20100400\n");
                        r0.* = 0x1E7;
                        const r1: *volatile u32 = @ptrFromInt(0x2010_0800);
                        log.raw("wifi-init-probe: rmw 0x20100800\n");
                        r1.* = r1.* | 3;
                        const r2: *volatile u32 = @ptrFromInt(0x2010_7C80);
                        log.raw("wifi-init-probe: write 0x20107C80\n");
                        r2.* = 0xFFFF_FFFF;
                        const r3: *volatile u32 = @ptrFromInt(0x2070_401C);
                        log.raw("wifi-init-probe: rmw 0x2070401C\n");
                        r3.* = r3.* | 0x0040_000F;
                        log.raw("wifi-init-probe: fe_bb writes done\n");
                    }
                    // 关掉手工二分：只在"真实路径"上跑 `register_chipv7_phy`，否则 ROM 自己的
                    // 初始化顺序被跳过，得到的故障可能是探针人为造成的（0x2f07FC40 为空的教训）。
                    const manual_bisect = false;
                    if (manual_bisect) {
                        inline for (.{
                            "phy_get_xtal_freq",
                            "phy_get_rf_cal_version",
                            // `phy_rf_init` 的 23 个被调函数里，这些**不接收参数**（反汇编确认），
                            // 可以安全地逐个单独调用；`phy_rc_cal_init` 是首要嫌疑
                            // （它内部构造 I2C 命令结构再调 `phy_rc_cal`，走模拟 I2C 主控）。
                            // `phy_open_fe_bb_clk` 反汇编出来是**直筒**（无循环、无 jalr），
                            // 只做四次寄存器写：
                            //   0x20100400 = 0x1E7；0x20100800 |= 3；
                            //   0x20107C80 = 0xFFFFFFFF；0x2070401C |= 0x40000F
                            // 所以"挂起"只可能是其中某个**写**在总线上 stall。逐条写、逐条打日志定位。
                            "phy_open_fe_bb_clk",
                            "phy_rc_cal_init",
                            "phy_rfpll_chgp_cal",
                            "phy_tsens_read_init",
                            "phy_get_temp_init",
                            "phy_bbpll_cal",
                            "phy_rf_init",
                            "phy_bb_init",
                            "phy_get_temp_init",
                            "phy_get_romfunc_addr",
                            "phy_force_txrx_off",
                            "phy_freq_module_resetn",
                            "phy_dis_hw_set_freq",
                            "phy_i2c_master_reset",
                        }) |name| {
                            const f = @extern(*const fn () callconv(.c) void, .{ .name = name });
                            log.line("wifi-init-probe: calling {s}", .{name});
                            f();
                            log.line("wifi-init-probe: {s} returned", .{name});
                        }
                    }
                    const register_phy = @extern(*const fn (*const [128]u8, *[1894]u8, u32) callconv(.c) c_int, .{ .name = "register_chipv7_phy" });
                    if (impl.arena_state.describe(0x2f01c9e4)) |info| {
                        log.line("wifi-init-probe: 0x2f01c9e4 落在块 size=0x{x} free={} offset=0x{x}", .{
                            info.size, info.free, info.offset,
                        });
                    } else {
                        log.raw("wifi-init-probe: 0x2f01c9e4 不在 arena 里\n");
                    }
                    // 被调地址稳定等于 `cal_data - 12`：把附近的静态对象都打出来对账。
                    log.line("wifi-init-probe: magic_pre=0x{x} magic_post=0x{x} cal_data=0x{x} cal_data-12=0x{x}", .{
                        @intFromPtr(&magic_pre),
                        @intFromPtr(&magic_post),
                        @intFromPtr(&cal_data),
                        @intFromPtr(&cal_data) - 12,
                    });
                    log.line("wifi-init-probe: cal_data=0x{x:0>8} init_params=0x{x:0>8} wrapper=0x{x:0>8} inner=0x{x:0>8}", .{
                        @intFromPtr(&cal_data),
                        @intFromPtr(&phy_init_data.params),
                        impl.last_wrapper,
                        impl.last_inner,
                    });
                    // IDF 的布局：`phy_init_magic_pre`（"PHYINIT\0"，8 B）紧贴结构体之前、
                    // `phy_init_magic_post` 紧贴之后。PHY 代码可能检查这两个魔数，所以照抄布局。
                    magic_pre = "PHYINIT\x00".*;
                    magic_post = "PHYINIT\x00".*;
                    // 先跳过 RF 标定（PHY_RF_CAL_NONE = 1）：标定路径是本固件最可疑的地方
                    // （它等 PHY 应答，而 MIE=0 时中断永远不来）。若 NONE 能返回，就锁定标定。
                    // 实验：改成 PHY_RF_CAL_FULL=2（不是 1=NONE）。当初跳过标定是因为中断关着、
                    // 怕标定路径要等 PHY 应答；现在中断已开，且 blob 很可能正是靠标定完成才清
                    // MAC+0xAC 的 [15:13] 握手位。
                    if (probe_register_phy_at_init) {
                        const rc_phy = register_phy(&phy_init_data.params, @ptrCast(&cal_data), 2); // 2 = PHY_RF_CAL_FULL
                        log.line("wifi-init-probe: register_chipv7_phy(mode=FULL) rc={d} (cal_data {d} B)", .{
                            rc_phy,
                            @as(usize, 1894),
                        });
                    } else {
                        log.raw("wifi-init-probe: register_chipv7_phy SKIPPED at init (交给 _phy_enable)\n");
                    }
                }

                log.line("wifi-init-probe: starting task[0] entry=0x{x:0>8} arg=0x{x:0>8} on its own stack", .{
                    @intFromPtr(entry), @intFromPtr(task.arg),
                });
                // 只**建立**任务上下文，不主动跑它：blob 的任务体在 `esp_wifi_start` 之前
                // 进入会在内部回调派发处解引用未初始化的上下文（实测 mtval=0x102）。
                // 正确顺序是：先调 start，它 post 消息并阻塞等待 → idleHook 把控制权交给任务
                // → 任务处理完应答 → 主上下文从阻塞处继续。
                sched.initContext(&task_ctx, &static_stack, entry, task.arg);
                task_ctx_ready = true;
                log.raw("wifi-init-probe: task context ready, running it until it blocks\n");
                // 先让任务跑一轮（它阻塞收消息 → 通过 idleHook 让回主上下文），
                // 这样 wifi 状态机有机会推进到 start 期待的状态。
                // 共存实验：保留我们的 `mtvec` 做采样，但把**别人的中断链式转发**给 ROM 的入口。
                // blob 把 TIMG0_T0 当自己的 tick；只采样不转发，ROM 的 tick ISR 永不运行。
                const rom_mtvec_ptr = @extern(*const usize, .{ .name = "rom_mtvec" });
                log.line("wifi-init-probe: chain-to-ROM mode, rom_mtvec=0x{x:0>8}", .{rom_mtvec_ptr.*});
                trap.chain_other_irqs = true;
                // 采样器回到 **T0 / 输入 25** 并自 ack：改用 T1/26、把 25 转发给 ROM dispatcher 会让
                // "尚未安装 handler 的 25"变成电平中断风暴（实测 init 直接卡在 0x4004a764）。
                hw.routeT0Interrupt(25);
                hw.armT0Interrupt(2000);
                hw.enableInterrupts();
                in_task = true;
                impl.current_is_task = true;
                sched.start(&task_ctx, &main_ctx);
                in_task = false;
                impl.current_is_task = false;
                log.line("wifi-init-probe: task blocked, main resumed (idle_calls={d})", .{idle_calls});

                // 收发接缝探针：在不启动射频的前提下，问清楚哪些内部 API 现在就可达。
                {
                    // 实验：不注册 RX 回调（RX 引擎"有人持有缓冲"可能让 deinit 永远等 RX 静止）。
                    if (probe_register_rxcb) {
                        const rrc = reg_rxcb(0, &rxCb); // 0 = WIFI_IF_STA
                        log.line("wifi-init-probe: reg_rxcb rc={d}", .{rrc});
                    } else {
                        log.raw("wifi-init-probe: reg_rxcb SKIPPED (probe_register_rxcb=false)\n");
                    }
                    var primary: u8 = 0;
                    var second: u8 = 0;
                    const crc = get_config_channel(0, &primary, &second);
                    log.line("wifi-init-probe: get_config_channel rc={d} primary={d} second={d}", .{ crc, primary, second });
                    // 实验：**不**在 init 阶段真发帧。上一次 `internal_tx` 返回 0x3002（失败），
                    // 很可能把 MAC 的 TX 引擎留在半提交态，导致 start 里的 deinit 等 TX 静止死等。
                    if (probe_send_init_frame) {
                        var frame: [64]u8 = @splat(0xaa);
                        const trc = wifi_tx(0, &frame, @intCast(frame.len));
                        log.line("wifi-init-probe: internal_tx rc=0x{x} (64 B)", .{@as(u32, @bitCast(trc))});
                    } else {
                        log.raw("wifi-init-probe: internal_tx SKIPPED (probe_send_init_frame=false)\n");
                    }
                }

                const esp_wifi_start = @extern(*const fn () callconv(.c) c_int, .{ .name = "esp_wifi_start" });
                // 预算实验：`note()` 在 semphr_take/give、mutex_lock、queue_recv/send 上都会递减
                // `impl.budget`，归零即打印事件环。用它在"start 不返回"的情况下判断 blob 到底
                // 有没有调我们的钩子（例如非阻塞 take 轮询：idle_calls 不涨，但钩子在涨）。
                // 先清空事件环与 trace 计数，这样两者都只剩 `esp_wifi_start` 自己的调用。
                impl.resetEvents();
                trace_lines = 0;
                impl.budget = 0; // 不设预算，用 traceNote 逐行追踪
                // `esp_wifi_start` 的第一件事是 `wifi_init_completed()`（返回非 0 才继续）：
                // 它读 blob 内部状态字并和 3 比较。直接问它，省得猜。
                const init_completed = @extern(*const fn () callconv(.c) c_int, .{ .name = "wifi_init_completed" });
                log.line("wifi-init-probe: wifi_init_completed={d} (非 0 才继续)", .{init_completed()});
                // ★ ROM 里有 `ic_mac_init`(0x2f800d9c) / `ic_mac_deinit`(0x2f800d98) /
                // `is_lmac_idle`(0x2f800da4)。自旋函数属于 blob 的 MAC deinit 路径，
                // 所以先问 ROM 自己"LMAC 是否空闲"，再试一次 ROM 的 MAC 初始化。
                {
                    const is_lmac_idle = @extern(*const fn () callconv(.c) c_int, .{ .name = "is_lmac_idle" });
                    const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
                    const ic_interface_enabled = @extern(*const fn () callconv(.c) c_int, .{ .name = "ic_interface_enabled" });
                    log.line("wifi-init-probe: is_lmac_idle={d} ic_interface_enabled={d} mac=0x{x:0>8}", .{
                        is_lmac_idle(), ic_interface_enabled(), mac_st.*,
                    });
                    // `is_lmac_idle` 的反汇编显示 IC 层走 `*(0x2f07ff48)` 的 vtable，所以 IC 函数
                    // 很可能要这个上下文指针作参数；之前无参调用没生效可能就是 ABI 不对。
                    // `is_lmac_idle` 的真体是 `ic->fns[55](i)`、i=0..4 ⇒ IC 层函数的入参是**接口号**，
                    // 不是上下文指针（传 g_ic 会把 0x2f01d3c8 当指针用，属乱序调用的错误用法）。
                    const ic_mac_init_ifx = @extern(*const fn (u32) callconv(.c) void, .{ .name = "ic_mac_init" });
                    if (probe_manual_ic_mac_init) ic_mac_init_ifx(0);
                    log.line("wifi-init-probe: after ic_mac_init(0): is_lmac_idle={d} iface={d} mac=0x{x:0>8}", .{
                        is_lmac_idle(), ic_interface_enabled(), mac_st.*,
                    });
                    // 只调无参的 `hal_mac_is_dma_enable`：`hal_mac_get_txq_state/complete` 带参数，
                    // 用垃圾 a0 调会 store fault（实测 mtval=0xa6b000a）。
                    const is_dma_enable = @extern(*const fn () callconv(.c) c_int, .{ .name = "hal_mac_is_dma_enable" });
                    log.line("wifi-init-probe: dma_enable={d}", .{is_dma_enable()});
                }
                // ★ 按 IDF 标准顺序补齐配置：init → set_mode → set_country → set_storage → start。
                // 探针此前从 init **直接跳到** start，中间三步一步都没做；而触发 MAC deinit 的函数
                // 读 `g_chm`(0x2f07ff88) = channel manager，说明 start 会按"新信道"重配 MAC。
                {
                    const WifiCountry = extern struct {
                        cc: [3]u8,
                        schan: u8,
                        nchan: u8,
                        max_tx_power: i8,
                        policy: u32,
                    };
                    const set_mode = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_wifi_set_mode" });
                    const set_country = @extern(*const fn (*const WifiCountry) callconv(.c) c_int, .{ .name = "esp_wifi_set_country" });
                    const set_storage = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_wifi_set_storage" });

                    const rc_mode = set_mode(1); // WIFI_MODE_STA
                    log.line("wifi-init-probe: set_mode(STA) rc={d}", .{rc_mode});
                    // "01" 被拒（rc=258 = ESP_ERR_INVALID_ARG），改真实国家码 CN（1..13）。
                    const country: WifiCountry = .{
                        .cc = .{ 'C', 'N', 0 },
                        .schan = 1,
                        .nchan = 13,
                        .max_tx_power = 20,
                        .policy = 0, // WIFI_COUNTRY_POLICY_AUTO
                    };
                    const rc_cc = set_country(&country);
                    log.line("wifi-init-probe: set_country(CN,1..13) rc={d}", .{rc_cc});
                    const rc_st = set_storage(1); // WIFI_STORAGE_RAM
                    log.line("wifi-init-probe: set_storage(RAM) rc={d}", .{rc_st});
                    // 关键：`set_country` 被拒（258），`get_config_channel` 一直是 0/0 —— 信道从未设定。
                    // 而自旋的调用者属于信道管理路径（wl_chm.o 的 chm_*），"切到信道 0" 正好会触发 MAC 重配。
                    const set_channel = @extern(*const fn (u8, u8) callconv(.c) c_int, .{ .name = "esp_wifi_set_channel" });
                    const rc_ch = set_channel(6, 0); // primary=6, secondary=0（2.4G 20MHz）
                    log.line("wifi-init-probe: set_channel(6,0) rc={d}", .{rc_ch});
                    const wdev = @as(*const usize, @ptrFromInt(0x2f07_FF40)).*;
                    const ppw = @as(*const usize, @ptrFromInt(0x2f07_FF48)).*;
                    const chm = @as(*const usize, @ptrFromInt(0x2f07_FF88)).*;
                    log.line("wifi-init-probe: wDevCtrl=0x{x:0>8} pp_wdev_funcs=0x{x:0>8} g_chm=0x{x:0>8}", .{ wdev, ppw, chm });
                    // 给"自旋的 a1 = 0x2f01cab0"找归属：把一批 ROM 数据指针一起打出来比对。
                    const names = [_]struct { n: []const u8, a: usize }{
                        .{ .n = "g_hmac_cnt_ptr", .a = 0x2f07ff80 },
                        .{ .n = "g_ic_ptr", .a = 0x2f07ff84 },
                        .{ .n = "g_eb_list_desc_ptr", .a = 0x2f07ff30 },
                        .{ .n = "g_lmac_cnt_ptr", .a = 0x2f07ff38 },
                        .{ .n = "pp_sig_cnt_ptr", .a = 0x2f07ff34 },
                        .{ .n = "s_wifi_queue", .a = 0x2f07ff1c },
                        .{ .n = "trc_ctl_ptr", .a = 0x2f07fef4 },
                        .{ .n = "xphyQueue", .a = 0x2f07ff0c },
                        .{ .n = "g_coex_param_ptr", .a = 0x2f07ff94 },
                    };
                    for (names) |e| {
                        const v = @as(*const usize, @ptrFromInt(e.a)).*;
                        log.line("wifi-init-probe: ptr {s}=0x{x:0>8}", .{ e.n, v });
                    }
                }
                // 实验：blob 在 start 期间走 MAC deinit 等 TX/RX 静止（`g_mac_deinit_*`）。
                // IDF 的 `esp_phy_enable()` 会调 ROM 的 `wifi_rf_phy_enable`(0x2f800cf4)，
                // 而我们的手工 bring-up 从没调过它——先补上这一次，看 [15:13] 是否自清。
                {
                    // 先复位 FE 的 TX/RX 状态机（ROM `phy_fe_txrx_reset` = 0x2f8013d8，
                    // esp32s31.rom.phy.ld:143）：MAC deinit 等的 busy{13..15} 正是 TX/RX 引擎的忙位。
                    // `WIFI_CLOCK_DEPS` 的 COEXIST 一项在 LPCON（0x2010F000）的 clk_conf(+0x18)：
                    // bit0 wifipwr / **bit1 coex** / bit2 i2c_mst（modem_lpcon_ll_enable_coex_clock）。
                    {
                        const lpcon: *volatile u32 = @ptrFromInt(0x2010_F018);
                        const before = lpcon.*;
                        lpcon.* = before | (1 << 0) | (1 << 1) | (1 << 2);
                        log.line("wifi-init-probe: LPCON_CLK_CONF 0x{x} -> 0x{x}", .{ before, lpcon.* });
                    }
                    // IDF 开 BB 时钟时的序列是"**先脉冲 RST_WIFIBB 再开 0x17b 时钟**"
                    // （modem_clock_wifi_bb_configure → modem_syscon_ll_reset_wifibb）。
                    // 我们从没动过 BB 的复位——而 TX/RX 状态机正住在 BB 里。
                    {
                        const rst: *volatile u32 = @ptrFromInt(0x2010_9C10);
                        const before = rst.*;
                        rst.* = before | (1 << 8); // rst_wifibb
                        rst.* = rst.* & ~@as(u32, 1 << 8);
                        log.line("wifi-init-probe: rst_wifibb pulse 0x{x} -> 0x{x}", .{ before, rst.* });
                    }
                    // 变体：**时钟关断状态下**脉冲复位（部分 SoC 要求 clock-gated reset 才生效）。
                    // 序列：清 clk_wifimac_en(bit9) → 脉冲 rst_wifimac(bit9 of 0x20109C10) → 重新使能。
                    {
                        const conf1: *volatile u32 = @ptrFromInt(0x2010_9C14);
                        const rst: *volatile u32 = @ptrFromInt(0x2010_9C10);
                        const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
                        const c0 = conf1.*;
                        conf1.* = c0 & ~@as(u32, 1 << 9);
                        rst.* = rst.* | (1 << 9);
                        rst.* = rst.* & ~@as(u32, 1 << 9);
                        conf1.* = c0;
                        log.line("wifi-init-probe: gated reset (clk off -> rst -> on): mac=0x{x:0>8}", .{mac_st.*});
                    }
                    // blob 自己的"清状态位"函数（`0x2f005b0c`，取 a0 作掩码，清 `(a0 & 0xFF000) | bit12`）。
                    // 实验：start 之前先把 stale 的 busy{13..15} 清掉，看 deinit 的轮询是否直接通过。
                    const clearStatus = @as(*const fn (u32) callconv(.c) usize, @ptrFromInt(0x2f005b0c));
                    const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
                    log.line("wifi-init-probe: pre-start mac=0x{x:0>8}, clearing 0xE000", .{mac_st.*});
                    _ = clearStatus(0xE000);
                    log.line("wifi-init-probe: post-clear mac=0x{x:0>8}", .{mac_st.*});
                    const fe_txrx_reset = @extern(*const fn () callconv(.c) void, .{ .name = "phy_fe_txrx_reset" });
                    if (probe_manual_phy_calls) {
                        log.raw("wifi-init-probe: calling phy_fe_txrx_reset()\n");
                        fe_txrx_reset();
                        log.raw("wifi-init-probe: phy_fe_txrx_reset returned\n");
                    }
                    const rf_enable = @extern(*const fn () callconv(.c) void, .{ .name = "wifi_rf_phy_enable" });
                    if (probe_manual_phy_calls) {
                        log.raw("wifi-init-probe: calling wifi_rf_phy_enable()\n");
                        rf_enable();
                        log.raw("wifi-init-probe: wifi_rf_phy_enable returned\n");
                    }
                }
                log.line("wifi-init-probe: event_bus handlers={d} posts={d} undispatched={d}", .{
                    event_bus.count, event_bus.posts, event_bus.undispatched,
                });
                // **rst_wifimac 脉冲实验**：`modem_rst_conf`(0x20109C10) bit9 = rst_wifimac。
                // bits 15:13（busy/ack）在 blob 里**没有软件清除路径**，所以 IDF init 后
                // MAC_ST 0xE000 -> 0 只能是硬件副作用；复位脉冲是唯一候选。
                const rst_reg = @as(*volatile u32, @ptrFromInt(0x20109C10));
                const mac_st = @as(*volatile u32, @ptrFromInt(0x20104CAC));
                log.line("wifi-init-probe: pre-pulse MAC_ST=0x{x:0>8} rst=0x{x:0>8}", .{ mac_st.*, rst_reg.* });
                rst_reg.* |= (1 << 9);
                var d: u32 = 0;
                while (d < 2000) : (d += 1) asm volatile ("nop");
                rst_reg.* &= ~@as(u32, 1 << 9);
                d = 0;
                while (d < 20000) : (d += 1) asm volatile ("nop");
                log.line("wifi-init-probe: post-pulse MAC_ST=0x{x:0>8} rst=0x{x:0>8} en_bits={d}", .{
                    mac_st.*, rst_reg.*, (mac_st.* >> 17) & 7,
                });
                // **b14 实验已做**（置 1 后 start）：无效——`b16`/`b288` 仍为 0，说明 MAC 使能函数
                // （0x40034d1a）在 **init 期间**就被 b14=0 挡掉返回了，start 里不会再跑一次。
                // **泵任务实验（start 之前）**：8 轮全无变化 ⇒ 在那个时刻任务无事可做。
                // 注意：这**不覆盖自旋期间**（那时主上下文被钉在 deinit 循环里），
                // "自旋期间没有并发"这条仍未验证。
                {
                    const bgp = @as([*]volatile u8, @ptrFromInt(0x2f013d30));
                    var round: usize = 0;
                    while (round < 8) : (round += 1) {
                        log.line("wifi-init-probe: pump round {d} before: b14={d} b15={d} b16={d} b27={d} b288={d} mac=0x{x:0>8} recv={d} send={d} delay={d}", .{
                            round,                                         bgp[14],               bgp[15],               bgp[16],               bgp[27], bgp[288],
                            @as(*volatile u32, @ptrFromInt(0x20104CAC)).*, impl.calls.queue_recv, impl.calls.queue_send, impl.calls.task_delay,
                        });
                        in_task = true;
                        impl.current_is_task = true;
                        sched.swapContext(&main_ctx, &task_ctx);
                        in_task = false;
                        impl.current_is_task = false;
                        log.line("wifi-init-probe: pump round {d} after:  b14={d} b15={d} b16={d} b27={d} b288={d} mac=0x{x:0>8} recv={d} send={d} delay={d}", .{
                            round,                                         bgp[14],               bgp[15],               bgp[16],               bgp[27], bgp[288],
                            @as(*volatile u32, @ptrFromInt(0x20104CAC)).*, impl.calls.queue_recv, impl.calls.queue_send, impl.calls.task_delay,
                        });
                    }
                }
                // **ppTask 泵实验已做**：给它自己的栈 + `sched.initContext`/`swapContext` 后它**能正常让出**
                // （不会像直接 call 那样挂死），但 **16 轮泵下来 b288 仍为 0、MAC_ST 不变**。
                // ⇒ ROM 的 PP worker 单独跑也不推进状态机（它多半在等别的消息/事件）。
                log.line("wifi-init-probe: calling esp_wifi_start (idle_calls={d}, tracing hooks)", .{idle_calls});
                const src = esp_wifi_start();
                log.line("wifi-init-probe: hook budget left={d}, hook calls={d}", .{ impl.budget, impl.event_count });
                log.line("wifi-init-probe: esp_wifi_start rc=0x{x} (idle_calls={d})", .{
                    @as(u32, @bitCast(src)),
                    idle_calls,
                });
            }
        }
        hw.halt();
    }

    // 5) 失败时做分阶段诊断（这些调用会改状态，只能放在失败之后）
    inline for (.{ "pm_funcs_init", "wdev_funcs_init", "net80211_funcs_init" }) |name| {
        const f = @extern(*const fn () callconv(.c) c_int, .{ .name = name });
        const rc = f();
        log.line("wifi-init-probe: {s} rc={d}", .{ name, rc });
    }
    {
        const menu = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{ .name = "wifi_menuconfig_init" });
        log.line("wifi-init-probe: wifi_menuconfig_init rc={d}", .{menu(&cfg)});
    }
    inline for (.{ "misc_nvs_init", "ic_create_wifi_task", "ieee80211_ioctl_init" }) |name| {
        const f = @extern(*const fn () callconv(.c) c_int, .{ .name = name });
        const rc = f();
        log.line("wifi-init-probe: {s} rc={d}", .{ name, rc });
    }

    // 6) 谁被调用过
    var reported: usize = 0;
    for (osi_stubs.hits, 0..) |n, i| {
        if (n == 0) continue;
        log.line("wifi-init-probe: osi stub {s} hits={d}", .{ osi_stubs.names[i], n });
        reported += 1;
        if (reported >= 12) break;
    }
    var lreported: usize = 0;
    for (link_stubs.hits, 0..) |n, i| {
        if (n == 0) continue;
        log.line("wifi-init-probe: link stub {s} hits={d}", .{ link_stubs.names[i], n });
        lreported += 1;
        if (lreported >= 12) break;
    }
    if (reported == 0 and lreported == 0) log.raw("wifi-init-probe: no stub was called\n");
    log.raw("wifi-init-probe: done\n");
    hw.halt();
}

// 链接脚本里的堆边界（`s31.ld:172-173` 定义 `_heap_start` / `_heap_end`）。它们是**绝对符号**：
// 取地址得到边界值；声明成 usize 会变成"去那个地址读一个 usize"。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}
