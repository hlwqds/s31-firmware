//! controller 的 init / enable 编排（IDF `bt.c:200-280` + `ble.c:1447-1530` 的 Zig 版）。
//!
//! 每一步都分得清"归档符号"与"我们自己写的"——这是前面所有工作的落点：
//!
//! | 步 | 调用 | 归属 |
//! | --- | --- | --- |
//! | init 1 | `btdm_osal_elem_mempool_init(&elem)` | 我们（`porting.elemMempoolInit`，容量校验） |
//! | init 2 | `btdm_log_init` / `btdm_external_init` / `btdm_coex_init` | 我们（都 `return 0`） |
//! | init 3 | `btdm_lp_enable_clock(&cfg.btdm)` | 我们（已完整实现：门控+FE+MAC 复位族+LP timer；2026-11-22 删除过曾错位覆盖 coex/clk_conf 的"RTC timer clock chain"块） |
//! | init 4 | `r_btdm_task_init(&cfg.btdm)` | 归档 |
//! | init 5 | `btdm_lp_init` | 我们（`return 0`） |
//! | init 6 | `r_btdm_hci_fc_env_init` | 归档（`CONN_FC_ENABLE` 硬编码 1 ⇒ 必调） |
//! | init 7 | `esp_ble_register_bb_funcs` → `r_ble_controller_init(&cfg.ble)` → `ble_msys_init` | 混合 |
//! | init 8 | `r_base_stack_initEnv` / `r_conn_stack_initEnv` | 归档 |
//! | enable | `btdm_lp_reset` → `btdm_coex_enable` → `r_base_stack_enable` → `r_conn_stack_enable` → `r_btdm_hci_fc_enable` → **`r_btdm_task_enable`** | 混合 |
//!
//! ⚠ **`r_btdm_task_enable` 在 enable 步、不在 init 步**——只做 init 的话 controller 任务
//! 永不启动，HCI 不会有回包。这是"起来了但不发射"最常见的原因。
//!
//! ⚠ `esp_register_ext_funcs` **必须注册**（见 `extfuncs.zig`）：那张 40 字节的表里带的是
//! controller 侧的 `_malloc`/`_free`/`_os_random`/`_osi_assert`，跳过就等于 controller 没有分配器，
//! `r_ble_controller_init` 必然失败。ECC 三项照 IDF 在 SM 未开时那样给返回 -1 的桩。
const std = @import("std");
/// 板级模块只在目标板上存在；主机测试图里没有 `board`，给一个同名空壳并
/// 把所有板级写入用 `freestanding` 门控（此前主机门禁因 `no module named
/// 'board'` 与 RISC-V 内联汇编在 x86 上编译失败而红）。
const board = if (@import("builtin").os.tag == .freestanding) @import("board") else struct {};
/// 主机安全的 32 位 MMIO 写/置位/清位：init/enable 在主机测试里用 Hooks 跑，
/// 路径上的裸寄存器访问必须变成空操作（此前直接段错误 ⇒ 3 个 bringup 用例 ABRT）。
inline fn mmioWr(addr: usize, v: u32) void {
    if (freestanding) @as(*volatile u32, @ptrFromInt(addr)).* = v;
}
inline fn mmioSet(addr: usize, bits: u32) void {
    if (freestanding) @as(*volatile u32, @ptrFromInt(addr)).* |= bits;
}
inline fn mmioClr(addr: usize, bits: u32) void {
    if (freestanding) @as(*volatile u32, @ptrFromInt(addr)).* &= ~bits;
}
/// 定宽 MMIO 读（主机 0）。
inline fn mmioRdN(comptime T: type, addr: usize) T {
    return if (freestanding) @as(*volatile T, @ptrFromInt(addr)).* else 0;
}
/// 非 4 字节对齐地址的 u32 读（align(1)）。
inline fn mmioRdA1(addr: usize) u32 {
    return if (freestanding) @as(*align(1) const u32, @ptrFromInt(addr)).* else 0;
}
var mmio_scratch: [16]u8 align(4) = @splat(0);
/// 目标板：该地址的易失指针；主机测试：指向 dummy（读写落到 RAM）。
/// 供"先取指针再多次读写"的寄存器块使用。
inline fn mmioPtr(comptime T: type, addr: usize) *volatile T {
    if (freestanding) return @ptrFromInt(addr);
    return @ptrCast(&mmio_scratch);
}
inline fn mmioRd(addr: usize) u32 {
    return if (freestanding) @as(*volatile u32, @ptrFromInt(addr)).* else 0;
}

/// **轮 51：ana 四件套时序快照**——定位 ana 域死亡的确切一步。
/// 槽位：0=esp_btbb_enable 前 / 1=后 / 2=INITED / 3=泵首轮。
/// 读数 {F818(ana CONF0), F800(I2C0_CTRL), 11AC(FE cnt), 0450(FE cfg)}。
pub var ana_snap: [8][4]u32 = @splat(@splat(0));
pub var ana_snap_n: usize = 0;
pub fn anaSnap() void {
    if (!freestanding) return;
    if (ana_snap_n >= ana_snap.len) return;
    ana_snap[ana_snap_n] = .{
        mmioRd(0x2010_F818),
        mmioRd(0x2010_F800),
        mmioRd(0x2010_11AC),
        mmioRd(0x2010_0450),
    };
    ana_snap_n += 1;
}
/// 32 位 MMIO 读并放宽为 usize（目标板指针 32 位；主机 64 位上 `*usize` 对 4 字节
/// 对齐地址会编译失败）。
inline fn rdUsz(addr: usize) usize {
    return mmioRd(addr);
}
/// `probe.zig` 是板级探针（66 处 RISC-V 汇编 + 裸 MMIO），只在目标板存在。
/// 主机测试图里给同签名的空壳：钩子不装、实验开关全关。
const probe_mod = if (@import("builtin").os.tag == .freestanding) @import("probe.zig") else struct {
    pub fn bt_hook_event_init(_: u32) void {}
    pub fn bt_hook_event_init3(_: usize, _: usize, _: usize) void {}
    pub fn bt_hook_eventq_init(_: u32) void {}
    pub const ble_block_experiment: bool = false;
    pub const bt_block_read_only: bool = false;
    pub const populate_workaround: bool = false;
    pub const publish_bohff_anchor: bool = false;
    pub var call_stream_on: bool = false;
};
const builtin = @import("builtin");
const osal = @import("osal_kit").osal;
const config = @import("config.zig");
const porting = @import("porting.zig");
const r_ext_funcs = @import("extfuncs.zig");
const transport = @import("transport.zig");
const gate = @import("gate.zig");

pub const Status = enum(u8) { idle = 0, inited = 1, enabled = 2 };

/// **跳过 `r_btdm_task_init`**（实验用）。
/// 该调用会访问不可达的 `0x2010B000` ⇒ 总线挂起，于是它之后的 step 7–15、enable 链、
/// HCI 传输**从未在板上执行过**。跳过它即可验证那一大片。
pub var skip_task_init: bool = false;

/// cb7 相位捕获的 id2/id5 节点缓冲（task_deinit 摘链后原内存仍在，供重挂）。
pub var relink_p16: usize = 0;
pub var relink_p20: usize = 0;
pub var watch_node6: usize = 0;
pub var wl_printed: bool = false;

/// blob log sink 的让出桩：task 上下文每次 log 调用让出到主上下文一次。
/// 由 [2f010fb4] sink 的 +12/+28 槽引用（log_internal `jalr`）。
/// 让出桩计数（判读"任务每轮是否真推进"：icg 行 sb= 每轮增量）。
pub var stub_blocks: u32 = 0;

/// 纯计数 ISR 桩（oracle 路由 v4：blob 未经 intr_alloc 传 fn 时的占位）。
pub var count_only: u32 = 0;
fn countOnlyIsr(_: ?*anyopaque) callconv(.c) void {
    count_only += 1;
}

/// blob log sink 对象存储（自有 .bss，堆不可达；槽布局见 yield 注入段）。
pub var log_sink_storage: [64]usize align(4) = undefined;

/// **返回 1 + 限速让出**（2026-11-21 终版修正）：
/// - **必须返非 0**：返 0 ⇒ log_internal 跳过 .L43（格式化+**FIFO 出队**）
///   ⇒ FIFO 永不出队 ⇒ blob log_internal 在 mrucwvp（FIFO 满自旋）卡死
///   ——实测主/任务双上下文同旋（NMI mepc=0x400056a8 恒定）。
///   .L43 的输出槽已全槽 ret 桩（零成本），格式化是唯一残留成本；
/// - 每 256 次调用 block 一次 ⇒ 单次泵 kick 推进 256 个日志调用。
pub export fn btLogYieldStub() callconv(.c) c_int {
    // **blob 执行位置追踪**：`r_ble_log_internal_x1` 的帧是 `addi sp,sp,-48; sw ra,44(sp)`，
    // 入口 sp（= 本函数的 @frameAddress）+44 即 blob 调用点的 ra。只记代码区内的值。
    {
        const cfa: usize = @frameAddress();
        const blob_ra = @as(*volatile u32, @ptrFromInt(cfa + 44)).*;
        if ((blob_ra >= 0x4000_0020 and blob_ra < 0x400B_0000) or (blob_ra >= 0x2f00_0000 and blob_ra < 0x2f01_0000)) {
            osal.lpTrace(2, blob_ra);
        }
    }
    stub_blocks +%= 1;
    if (stub_blocks % 256 == 0) @import("osal_kit").sched.block();
    return 1;
}

/// 是否沿用旧顺序（PHY 早于 step 5 的时钟使能）。默认 false = 按 IDF 顺序。
pub var phy_before_clocks: bool = false; // 实验：PHY 初始化放到 step 5 之后

/// 是否在 step 6 前预先发布 anchor[8]（`r_sym_bt_6Q68KSwuQQP4VjQGqiWa`）。
pub var prepublish_bohff: bool = false;

var status_state: Status = .idle;
pub fn status() Status {
    return status_state;
}
/// 复刻 `esp_bt_controller_get_status()`——HCI 传输层开头就拿它做门禁（非 ENABLED 直接 -1）。
pub fn getStatus() u8 {
    return @backingInt(status_state);
}

pub const Stats = struct {
    init_calls: u32 = 0,
    enable_calls: u32 = 0,
    failed_step: u32 = 0, // 0 = 没有失败
    last_rc: c_int = 0,
    ext_funcs_registered: u32 = 0,
};
var stats_state = Stats{};
pub fn stats() Stats {
    return stats_state;
}

// 归档符号（签名取自 `ble.c:1397-1405` 与 `bt.c` 的 extern 声明）
extern fn r_btdm_task_init(cfg: *config.BtdmCfg) c_int;
extern fn r_btdm_hci_fc_env_init() c_int;
extern fn r_btdm_hci_fc_enable() c_int;
extern fn r_btdm_task_enable() c_int;
extern fn r_ble_controller_init(cfg: *config.BleCfg) c_int;
// 5 参：(cb, arg, q[88], q[92], a4=额外 init token——传 0 跳过 .L79 的附加初始化
// （垃圾值会让它 jal 垃圾指针）。反汇编 0x4006162c 实证。
/// **断言直写通道**（C 侧 wr_btdm_assert 调用）：绕过 ets_printf shim
/// （mute 会吞、FIFO 会丢）与 UART 有界写——断言文本必须可见。
export fn s31_bt_raw_line(s: [*:0]const u8) void {
    if (freestanding) board.hw.rawLineBlocking(std.mem.span(s));
}

extern fn r_btdm_sleep_set_sleep_cb(cb: ?*const anyopaque, arg: ?*anyopaque, a2: u32, a3: u32, a4: u32) c_int;
var sleep_cb_n: u32 = 0;
pub fn btSleepCb(a0: u32) callconv(.c) void {
    // **桩 sleep 回调**（btdm_sleep.c 的真实实现会做 RTC timer 武装等）。
    // 回调纪律：未知上下文（可能 trap/ISR）被 jalr ⇒ 纯 RAM 计数自增，
    // 不打日志/不写外设/不碰 flash（本仓反复实证的 trap 上下文不安全类）。
    _ = a0;
    sleep_cb_n +%= 1;
}
extern fn esp_ble_register_bb_funcs() c_int;
extern fn r_base_stack_initEnv() c_int;
extern fn r_conn_stack_initEnv() c_int;
extern fn r_base_stack_enable() c_int;
extern fn r_sym_bt_kNIbP2qfZqaMNyimIzAy(buf: *anyopaque, id: c_int) void;
/// ⚠ **这是一个空桩**：`0x4005764e` 处只有两个字节 `82 80` = `c.ret`，
/// 它**原样返回调用者的 `a0`**。无参调用时 `a0` 是残留值 ⇒
/// 我们曾把它读成 `rc=181935`/`rc=181941`（每次不同），误判为 enable 失败。
/// 显式传 0 让它返回确定的 0。
extern fn r_conn_stack_enable(_: c_int) c_int;
extern fn r_esp_ble_ll_set_public_addr(addr: *const [6]u8) c_int;

const freestanding = builtin.os.tag == .freestanding;

/// **轮 25**：esp_phy_enable 前后的 s_is_phy_calibrated 快照（probe 冻结点转存 rec）。
pub var phy_cal_flag_before: u8 = 0;
pub var phy_cal_flag_post: u8 = 0;

/// 主机测试注入点：把归档调用替换成可观察的假动作。
pub const Hooks = struct {
    call: ?*const fn (step: u32) c_int = null,
};
var hooks: Hooks = .{};
pub fn setHooks(h: Hooks) void {
    hooks = h;
}

/// **调用前**显式打一行。
///
/// 为什么不能放在 `step()` 里：`step(n, name, expr)` 的 `expr` 在**调用之前求值** ⇒
/// 那样打出来的"进入"日志其实在归档调用**返回之后**才出现，会让人误以为卡在下一步。
/// 实测踩过：`r_btdm_task_init` 内部挂住时，日志停在 step 5 之后，看起来像"卡在 step 6 之前"。
/// **纯 RAM 进度记录**（不受串口丢行影响）：崩溃后由 panic 路径 dump。
pub var last_step: u32 = 0;
pub var last_step_name: []const u8 = "none";

fn enter(n: u32, comptime what: []const u8) void {
    last_step = n;
    last_step_name = what;
    // **LP 深度槽**（0x2E000420）：跨复位可读，FEFE lrec[11] 带出。
    // enable() 内部挂死时 host 靠它定位卡在哪一步（UART 不可用时的唯一深度证据）。
    mmioWr(0x2E00_002C, n);
    // 同步到 board 侧（panic 行会打印它）
    if (freestanding) board.trap.last_step = n;
    if (freestanding) board.trap.last_step_name = what;
    osal.logPublic("bt bringup: enter step {d} " ++ what, .{n});
    // 让 UART FIFO 排空：step 1..5 在同一瞬间连发，5×~30 B > 128 B FIFO
    // ⇒ 溢出时 hw.rawWrite **按设计丢弃** ⇒ 只剩第一行可见（误判为"没执行"）。
    // 这里等 ~2 ms，足以让一行（30 B / 115200 ≈ 2.6 ms... 取保守值）排空。
    // 等 UART0 TX FIFO 排空（**有界**），再返回 —— 否则 5 行 step 日志连发会溢出
    // 128 B FIFO，`hw.rawWrite` 按设计丢弃，只剩第一行可见（会误判为"没执行"）。
    // UART0 = 0x2038A000，STATUS = +0x1C，TXFIFO_CNT = bit[23:16]（见 phy_stubs.c 的 put1）。
    if (freestanding) {
        const st: *volatile u32 = mmioPtr(u32, 0x2038_A01C);
        var guard: u32 = 0;
        while (guard < 2_000) : (guard += 1) { // FIFO 卡满时 200k 次迭代吃掉 82% CPU(HIST 实测),上限砍到 2k
            if (((st.* >> 16) & 0xFF) <= 8) break;
        }
    }
}

fn step(n: u32, comptime what: []const u8, archive_rc: ?c_int) c_int {
    if (hooks.call) |f| {
        const rc = f(n);
        if (rc != 0) {
            stats_state.failed_step = n;
            stats_state.last_rc = rc;
            osal.logPublic("bt bringup: step {d} " ++ what ++ " rc={d}", .{ n, rc });
        }
        return rc;
    }
    const rc = archive_rc orelse 0;
    if (rc != 0) {
        stats_state.failed_step = n;
        stats_state.last_rc = rc;
        osal.logPublic("bt bringup: step {d} " ++ what ++ " rc={d}", .{ n, rc });
    }
    return rc;
}

// 归档调用一律写成 `if (freestanding) f(...) else 0`：条件是 comptime 已知 ⇒
// 主机分支不求值，归档符号不会进 debug info（否则主机测试链接失败）。

// ---------------------------------------------------------------------------
// init（8 步）
// ---------------------------------------------------------------------------

/// 我们侧"boot 完成态"：与 oracle 的 `app_main` 入口同点（任何 BT 步骤之前）。
fn dumpBootState() void {
    if (@import("builtin").target.os.tag != .freestanding) return;
    {
        // **PHY 初始化**：现在用的是 **IDF 的真实实现**（`-Dphy-src-objs` 链进来的
        // `esp_phy.c`/`modem_clock.c`/`periph_ctrl.c` 对象），不再按地址调 IRAM。
        // 顺序与 IDF 的 `esp_phy_enable` 一致：填表 → 使能（内部含时钟/模块/校准）。
        const pp = @import("probe_ptr.zig");
        // 前后对读锚点表：区分"表由 PHY/ROM 填"与"表由闭包外的软件填"。
        gate.dumpAnchors("before-phy");
        if (phy_before_clocks) {
            porting.phyDomainEnable(); // 开关默认关；打开后在 PHY 使能前先补频域时钟
            pp.initPhy();
        }
        gate.dumpAnchors("after-phy");
        // ⚠️ `0x2f00fff8` **不是** `g_phyFuns`：它在锚点块里（`0x2f00ffd0 + 0x28`，第 11 个槽）。
        // 之前的标签把它当成 `g_phyFuns`，由此推出的"rom_phyFuns(0x2f07fc3c) ≠ g_phyFuns"是**误读**。
        osal.logLine("bt bringup: BOOTSTATE esp_phy_enable(BT) done, anchor[+0x28]=0x{x}", .{
            (mmioRd(0x2f00_fff8)),
        });
    }

    // boot 期四窗口 dump 与 19 条补齐写已移除：
    // 已知良好的四窗口状态在 step 5 之后由 `porting.zig` 的 `win:` dump 给出
    // （见 pc48.log:263-291），那里 `0x20109C04` 是可读的。
}

pub var rtc_patch_rb: u32 = 0;
pub var rtc_patch_done: bool = false;

pub fn init(cfg: *config.Config) c_int {
    // **时钟实验（compile-time 门控，默认关）**：RTC clk_en + RC32K OEN 两项
    // 使能后 boot 行为改变（实证：流程卡死在 enable step 20 task_enable、
    // blob intr_alloc 未到达）——与基线（fe=0 但 ENABLED ✓）冲突。隔离重测
    // 前保持关闭；RTC counter 走动实验另行单独做（当前基线 counter 冻结）。
    // **RTC 计数器 clk_en（BT 调度时基）**：date.bit31 复位=0 ⇒ counter 冻结。
    // controller 读的正是这个 LP 计数器——冻结 ⇒ 时间永不推进 ⇒ task_enable
    // 永等（本轮 A/B 组合：RTC ON + esp_btbb_enable + IE 延迟）。
    // 写 date 必须保留 bit31（skill: s31-rtc-timer-probe，counter ≈137 kHz）。
    // RC32K OEN（+0x4 bit7）已实证非缺口（开/关 fe 均 0），不在此块。
    mmioSet(0x2080_03FC, 0x8000_0000);
    // **boot 期一次性写入**（在 step 5 的 RMW 之前）：
    // `0x20109C04` 的 `0x00201002`（bit1/12/21 = pwdet/adc/dac 模拟前端时钟）
    // 必须**先**存在，step 5 的 `rd(reg_clk_conf) | 0x7e400000` 才会得到 IDF 的 `0x7e601002`。
    // 若缺这一步，step 5 只会写出 `0x7e400000`，模拟前端时钟缺失 ⇒ modem 窗口不应答。
    // **顺序关键**：参考构建先写 modem PLL（`0x2058_71E0 = 0x3d`），
    // 之后 `0x20109C04/0x20109C14` 的写才生效（参考日志次序：
    // `MODEM_CONF=0x3d` → `clk_conf=0x7e601002`）。我们此前顺序反了 ⇒ 写被丢弃。
    mmioWr(0x2058_71E0, 0x3d);
    // **栈用量探针**：入口与 INITED 处各取一次近似 sp（局部变量地址）
    {
        var probe_local: u8 = 0;
        if (freestanding) board.trap.diag_a = @intCast(@intFromPtr(&probe_local) & 0xFFFF);
    }
    mmioWr(0x2010_9C04, 0x0020_1002);
    mmioWr(0x2010_9C00, 0x0000_0100);
    mmioWr(0x2010_9C0C, 0x6464_6400);
    dumpBootState();
    stats_state = .{};
    stats_state.init_calls += 1;
    status_state = .idle;

    // 1. mempool（seed + elemCalc + 容量校验）
    enter(1, "mempool");
    var rc = step(1, "mempool", porting.prepareMempool(cfg));
    if (rc != 0) return rc;

    // 2. 三个空实现
    enter(2, "btdm_log_init");
    rc = step(2, "btdm_log_init", porting.btdmLogInit());
    if (rc != 0) return rc;
    enter(3, "btdm_external_init");
    rc = step(3, "btdm_external_init", porting.btdmExternalInit());
    if (rc != 0) return rc;
    enter(4, "btdm_coex_init");
    rc = step(4, "btdm_coex_init", porting.btdmCoexInit());
    if (rc != 0) return rc;

    // **中断使能钩子**：`intr_alloc` 只记录 handler 不够 —— controller 等的信号量由
    // ISR 释放，中断没使能 ⇒ 回包永远到不了。这里把 CLIC 输入 IE + mie 位置起来。
    @import("osal_kit").osal.on_intr_arm = &intrArm;
    @import("osal_kit").osal.on_event_init = &probe_mod.bt_hook_event_init;
    @import("osal_kit").osal.on_eventq_init = &probe_mod.bt_hook_eventq_init;
    @import("osal_kit").osal.on_event_init3 = &probe_mod.bt_hook_event_init3;
    // 3. 时钟门控（真实现：12 个门 + MAC 复位，内部读回自证）
    // **5F70 step5 入口标记**（UART 无关）：区分"没进 step 5"vs"step 5 内挂"
    {
        const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
        const ese = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
        var rec: [4]u32 = .{ 0xADC0_5F70, 0x20109C14, 0x2010F018, 0x20587040 };
        rec[1] = mmioRd(0x2010_9C14);
        rec[2] = mmioRd(0x2010_F018);
        rec[3] = mmioRd(0x2058_7040);
        // **先屏蔽 T0（clic25 nmies+IE）再擦写**——擦除 ~40 ms，T0 NMI 2 ms 一发，
        // 顺序反了 ⇒ 擦除期 NMI 打进 XIP ⇒ 取指 fault ⇒ CPU_LOCKUP（实测）。
        const clic25: usize = 0x1080_1000 + 25 * 4;
        const gsaved: u32 = mmioRd(clic25);
        mmioWr(clic25, gsaved & ~@as(u32, 0x108));
        _ = ese(0x18E000 / 0x1000);
        if (freestanding) board.hw.flashOpBegin();

        _ = esw(0x18E000, &rec, 16);
        if (freestanding) board.hw.flashOpEnd();
    }
    enter(5, "btdm_lp_enable_clock");
    porting.btdmLpEnableClock(&cfg.btdm);
    // **正确顺序**（对齐 IDF）：BT/LP 模块时钟已使能之后，再做 PHY 使能/校准。
    if (!phy_before_clocks) {
        enter(51, "phy_domain_enable");
        porting.phyDomainEnable();
        enter(52, "init_phy");
        @import("probe_ptr.zig").initPhy();
        osal.logPublic("bt bringup: PHY enabled AFTER step 5 (idf order)", .{});
    }

    // 4. 归档：任务层
    // **BT_BLOCK_PROBE**：直读 `0x2010B000`。寄存器已与 IDF 同点对齐，
    // 若这行之后没有打印值 ⇒ 我们的块仍不可读；有值 ⇒ 块已可读、fault 另有其因。
    // **对照读 + 目标读**（仅目标侧：主机上这些地址不存在）
    // ⚠ **必须受开关控制**：`0x2010B000` 不可访问时会挂住整个系统，
    // 若无条件执行，**每一次正常运行都会死在它上面**（本轮就是这样，白白丢了几轮板测）。
    if (@import("builtin").target.os.tag == .freestanding and (probe_mod.ble_block_experiment or probe_mod.bt_block_read_only)) {
        osal.logPublic("bt probe: control read 0x20109C04 = 0x{x:0>8}", .{(mmioRd(0x2010_9C04))});
        osal.logPublic("bt probe: 0x2010B000 = 0x{x:0>8}", .{(mmioRd(0x2010_B000))});
    }
    // **静默高频采样窗口**：step 6 里归档不打印，而我们自己的打印会占满采样
    //（本板 TX FIFO 停在 128）⇒ 先静默、把 T0 提到 ~100 µs，只把 PC 记进环。
    // **轮 65b：任务注册链表头 init**（官方 fqmZkUKg：osal_malloc(8) 哨兵
    // {+0:0, +4:self} 发布到 0x2f011130）——gvLJK4 追加循环前置条件。必须在
    // mempool init 之后（probe 早期调用会被 mempool 初始化清零，tlinit 实录）。
    if (freestanding) {
        // **轮 65b**：fqmZkUKg 哨兵后立即跑 yGU6cF4（清回调标志）——防 task_init
        // 后段的 reset 路径读到 flag≠0 走 .L79 清理分支（该分支解引用 chain，
        // 在我们环境 NULL store 崩，ok67 实录 mepc=0x40061654）。
        const ygu = @extern(*const fn () callconv(.c) void, .{ .name = "r_sym_bt_yGU6cF4ldGd8WlytaSqf" });
        ygu();
        osal.logPublic("bt bringup: task list head init *(0x2f011130)=0x{x:0>8}", .{mmioRd(0x2f01_1130)});
        // **轮 67**：env_obj[16]/[20] 注册节点预读（task_init 遍历表 = 崩点源）
        const envp: usize = @as(*volatile usize, @ptrFromInt(0x2f01_101c)).*;
        if (envp >= 0x2f00_0000 and envp < 0x2f90_0000 and envp % 4 == 0) {
            const n16: usize = @as(*volatile usize, @ptrFromInt(envp + 16)).*;
            const n20: usize = @as(*volatile usize, @ptrFromInt(envp + 20)).*;
            // **flash 直写通道**（LP 槽被下载刮花；mark.put 是 probe 私有）：
            // 0x18C100/0x18C108 = 空闲偏移，{magic, value} 8B 对，host esptool 读。
            const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
            const pair16: [2]u32 = .{ 0xADC0D001, @truncate(n16) };
            const pair20: [2]u32 = .{ 0xADC0D002, @truncate(n20) };
            _ = esw(0x18C000 + 0x100, &pair16, 8);
            _ = esw(0x18C000 + 0x108, &pair20, 8);
        } else {
            osal.logPublic("bt bringup: env ptr oob=0x{x:0>8}", .{envp});
        }
    }
    enter(6, "r_btdm_task_init");
    {
        const pp = @import("probe_ptr.zig");
        if (probe_mod.populate_workaround and pp.get() == 0) {
            const pr = pp.populate();
            osal.logPublic("bt bringup: Xpuq 锚点为 NULL => 补调写者 rc={d}, 现在 P=0x{x:0>8}", .{ pr, pp.get() });
        } else {
            osal.logPublic("bt bringup: Xpuq 锚点 P=0x{x:0>8} (init 前为 0 是正常的，oracle 亦如此)", .{pp.get()});
        }
    }
    // **只发布 7.o 锚点**：给 `BOhff` 的守卫一块可读内存（入口只判非空）。
    if (probe_mod.publish_bohff_anchor) {
        const pp7 = @import("probe_ptr.zig");
        if (pp7.bohffAnchor() == 0) {
            if (osal.btdmMalloc(16, 0)) |a7| {
                pp7.setBOhffAnchor(@intCast(@intFromPtr(a7)));
                osal.logPublic("bt bringup: 发布 7.o 锚点 a7=0x{x:0>8}（BOhff 守卫）", .{@intFromPtr(a7)});
            }
        }
    }
    if (probe_mod.populate_workaround) {
        // **发布 OkE7 锚点**（受 `populate_workaround` 控制，默认关）。
        //
        // 形状取自 oracle 的实测（`X[0..7]`）：
        //   +0 状态字节(=1)、+4/+8/+16/+20 指针、+12 0、+24 = 0x20260127(版本魔数)、+28 = 0x171000
        // `r_btdm_task_deinit` 会 `lw a0,20(a5)` 并把该字段当指针调用
        // ⇒ 结构必须 **≥32 字节**，否则 +20 越界（16 字节时读到的正是 arena 块头 0xb7a10c0d）。
        const pp = @import("probe_ptr.zig");
        const osal2 = @import("osal_kit").osal;
        if (pp.okE7Anchor() == 0) {
            {
                const x = osal2.btdmMalloc(32, 0);
                const y = osal2.btdmMalloc(32, 0);
                const p4 = osal2.btdmMalloc(32, 0);
                const p16 = osal2.btdmMalloc(32, 0);
                const p20 = osal2.btdmMalloc(32, 0);
                if (x != null and y != null and p4 != null and p16 != null and p20 != null) {
                    const xi: [*]u32 = @ptrCast(@alignCast(x.?));
                    xi[0] = 1; // 状态：inited
                    xi[1] = @intCast(@intFromPtr(p4.?));
                    xi[2] = @intCast(@intFromPtr(y.?));
                    xi[3] = 0;
                    xi[4] = @intCast(@intFromPtr(p16.?));
                    xi[5] = @intCast(@intFromPtr(p20.?));
                    xi[6] = 0x20260127; // BTDM_CONFIG_VERSION
                    xi[7] = 0x00171000;
                    pp.setOkE7Anchor(@intCast(@intFromPtr(x.?)));
                    // ⚠️ 这段预发布**曾长期误导**：`JwHs`(0x40060704) 读 anchor[8]
                    // （`r_sym_bt_6Q68KSwuQQP4VjQGqiWa`），**非零就返回 2**（"已初始化"），
                    // 而 `OkE7` 把非零当失败 ⇒ 返回 -8 ⇒ `task_init` 回滚 ⇒ deinit ⇒ 写 0 崩溃。
                    // `publish_bohff_anchor=false` 后 `JwHs` 自己 malloc(36)，`task_init` 跑过 15 次
                    // 分配才撞上 `0x2010B000` 总线挂起（真正的墙）。
                    // 实验：**不**预发布 anchor[8]（`6Q68KSw`）。归档自己的 `JwHs` 看到它非零就
                    // 返回 2（"已初始化"），而调用方把非零当失败 ⇒ OkE7 返回 -8 ⇒ 回滚。
                    if (prepublish_bohff and pp.bohffAnchor() == 0) {
                        if (osal2.btdmMalloc(32, 0)) |a7| {
                            pp.setBOhffAnchor(@intCast(@intFromPtr(a7)));
                            osal.logPublic("bt bringup: 发布 BOhff 锚点 a7=0x{x:0>8}", .{@intFromPtr(a7)});
                        }
                    }
                    osal.logPublic("bt bringup: 发布 OkE7 锚点 X=0x{x:0>8} (32B, +20=0x{x:0>8})", .{ @intFromPtr(x.?), @intFromPtr(p20.?) });
                } else {
                    osal.logPublic("bt bringup: 发布 OkE7 锚点失败（arena 分配）", .{});
                }
            }
        } else {
            osal.logPublic("bt bringup: OkE7 锚点已就绪=0x{x:0>8}", .{pp.okE7Anchor()});
        }
    }

    if (skip_task_init) {
        osal.logPublic("bt bringup: step 6 r_btdm_task_init SKIPPED (experiment)", .{});
        rc = 0;
    } else {
        // 窗口必须在**所有我们自己的打印之后**：step 6 里那几条 Xpuq/BOhff/OkE7 里程碑
        // 走 `osal.logPublic`（不受 `trace_hooks` 过滤），会在开窗后再打，把采样槽占满。
        // 窗口内还要**撤掉 gate 钩子**：归档取到互斥锁时它会打 15 行锚点表，每行都走 UART 自旋，
        // 采样会全部落在 `probe.logHook` 上（实测 48 条全是它）。
        if (freestanding) board.hw.mmio_off = true; // 关掉寄存器记录（否则它是热路径）
        if (freestanding) board.trap.sample_period_us = 100; // ISR 重装也用 100 µs（否则窗口只活一个 tick）
        if (freestanding) board.trap.resetPcs(); // 只保留本窗口的采样
        if (freestanding) board.trap.sample_quiet = true;
        if (freestanding) board.trap.probe_stop_at_tick = 0; // 干净采集：关掉 DUMP 路径（它的输出会与 win: dump 交错） // 100us/tick ⇒ ~3 s，落在 step 6 停滞之后 // 关闭：它会从开机起算并 halt，吃掉整轮实验 // 约 2 s 后故意 panic，一次性导出计数器 // 存活探针：让 ISR 自己打印 PC，静默时用它判定"自旋 vs 总线挂死"
        osal.trace_hooks = false; // "bt hook: " 逐调用日志也会走 logHook
        osal.clearMutexHook(); // gate 钩子会打 15 行锚点表，每行都走 UART 自旋
        if (freestanding) board.hw.armT0Interrupt(100);
        // ⚠️ `armT0Interrupt` 会把 CLIC 控制字整字重写（`(1<<24)|(1<<8)`），**清掉** probe.zig
        // 给 T0 设的 `nmies`(bit3) ⇒ NMI 采样在 step 6 期间根本不触发（实测：48 条采样全落在
        // 我们自己的 `logHook`，没有一条在归档里）。这里把 nmies 补回去。
        {
            const reg: *volatile u32 = mmioPtr(u32, 0x1080_1000 + 25 * 4);
            reg.* = (reg.* & 0x107) | (1 << 3);
        }
        probe_mod.call_stream_on = false; // 保持 false：true 会把 bt ret:/bt call: 压成 1 字节
        rc = step(6, "r_btdm_task_init", if (freestanding) r_btdm_task_init(&cfg.btdm) else 0);
        // not-ready 协议判据：若第一次只"发布对象"并返回 not-ready，第二次应能继续。
        // 只在第一次非零时重试一次，且不吞掉原始 rc 的日志。
        if (rc != 0 and freestanding) {
            osal.logPublic("bt bringup: step 6 first rc={d}, retrying once", .{rc});
            rc = step(6, "r_btdm_task_init(retry)", r_btdm_task_init(&cfg.btdm));
        }
    }
    if (rc != 0) return rc;
    // **cblist 遍历（step6 后）**：id 节点在 task_init 内创建；早 panic 的 boot 也出数。
    {
        const p0: usize = rdUsz(0x2f01_1030);
        if (p0 >= 0x2f00_0000 and p0 < 0x2f10_0000) {
            var a0v: u64 = 0;
            var a1v: u64 = 0;
            var node: usize = rdUsz(p0);
            var k: usize = 0;
            while (node >= 0x2f00_0000 and node < 0x2f10_0000 and k < 8) : (k += 1) {
                const op: u64 = mmioRdN(u16, node);
                const sh: u6 = @intCast(16 * (3 - (k % 4))); // 48,32,16,0 —— 每组 4 id，零叠写
                if (k < 4) a0v |= op << sh else a1v |= op << sh;
                node = rdUsz(node + 8);
            }
            osal.logPublic("bt probe: cblist6 A=0x{x:0>16} B=0x{x:0>16} n={d}", .{ a0v, a1v, k });
        } else {
            osal.logPublic("bt probe: cblist6 head oob=0x{x:0>8}", .{p0});
        }
    }

    // 5. lp init（空实现）
    enter(7, "btdm_lp_init");
    rc = step(7, "btdm_lp_init", porting.btdmLpInit());
    // **轮 20d：esp_phy_enable(PHY_MODEM_BT=2)——官方 controller_init 的第 9 步
    // `btdm_lp_init` 内部调用 esp_phy_enable（oracle 0x400105cc 反汇编实锤），
    // 位于 task_init 之后、hci_fc_env_init 之前。此前 probe 的 phy_enable 在 LE
    // 块（0x2005 前才调，晚于 enable 阶段的 esp_btbb_enable）⇒ BB 调度器对着
    // 未校准 RF 构建 ⇒ synth-ready(98BC.bit2) 永不置位 ⇒ 0x200A 错误 3。
    // 现按官方时序：phy 先于 btbb。返回判据：98BC 快照进日志与 hist。
    {
        if (freestanding) {
            // **轮 25/41**：s_is_phy_calibrated 清零 + 合并判决读出。
            // s_is_phy_calibrated = local b 符号（@extern 不可用）⇒ nm 硬编码
            // **每次构建后必须 nm 比对**（布局每构建漂移——轮 35 铁律显式化）。
            const cal_flag: *volatile u8 = @ptrFromInt(0x2F01_0F80); // nm 0x2f010f80
            phy_cal_flag_before = cal_flag.*;
            cal_flag.* = 0;
            const esp_phy_enable = @extern(*const fn (modem: c_int) callconv(.c) void, .{ .name = "esp_phy_enable" });
            const get_modem_flag = @extern(*const fn () callconv(.c) u32, .{ .name = "phy_get_modem_flag" });
            // **轮 27：MIE off 包住整个校准**（防 assert 风暴——协作单核下语义
            // 等价于真临界区保护全部事务）。
            const mf_pre = get_modem_flag();
            board.hw.disableInterrupts();
            esp_phy_enable(2);
            board.hw.enableInterrupts();
            phy_cal_flag_post = cal_flag.*;
            const mf_post = get_modem_flag();
            const flag_addr: usize = @intFromPtr(cal_flag);
            osal.logPublic(
                "bt bringup: esp_phy_enable(2) done calflag {d}->{d}->{d} modem_flag {d}->{d} flag_addr=0x{x:0>8} ready=0x{x:0>8}",
                .{ phy_cal_flag_before, phy_cal_flag_post, cal_flag.*, mf_pre, mf_post, flag_addr, mmioRd(0x2010_98BC) },
            );
        }
    }
    // **链表细节（step7 后）**：远离 step17 HALT 洪流，FIFO 从容排空。
    // 链状态 step6 已定（task_init 内 OkE7 重建 + 尾插），step7 无关。
    {
        const p0: usize = rdUsz(0x2f01_1030);
        if (p0 >= 0x2f00_0000 and p0 < 0x2f10_0000) {
            var node: usize = rdUsz(p0);
            var k: usize = 0;
            var a0v: u64 = 0;
            var a1v: u64 = 0;
            while (node >= 0x2f00_0000 and node < 0x2f10_0000 and k < 8) : (k += 1) {
                const op: u64 = mmioRdN(u16, node);
                const sh: u6 = @intCast(16 * (3 - (k % 4)));
                if (k < 4) a0v |= op << sh else a1v |= op << sh;
                // 链上捕获 id2/id5 节点地址（此刻仍在链上；env 全局已被置 1 不可用）
                if (op == 2) relink_p16 = node;
                if (op == 5) relink_p20 = node;
                node = rdUsz(node + 8);
            }
            osal.logPublic("bt probe: cb7 A=0x{x:0>16} B=0x{x:0>16} n={d}", .{ a0v, a1v, k });

            const envp: usize = rdUsz(0x2f01_1038);
            if (envp >= 0x2f00_0000 and envp < 0x2f10_0000) {
                const e0: usize = rdUsz(envp);
                const e16: usize = if (e0 >= 0x2f00_0000 and e0 < 0x2f10_0000) rdUsz(e0 + 16) else 0;
                const e20: usize = if (e0 >= 0x2f00_0000 and e0 < 0x2f10_0000) rdUsz(e0 + 20) else 0;
                osal.logPublic("bt probe: env=0x{x:0>8} +16=0x{x:0>8} +20=0x{x:0>8}", .{ e0, e16, e20 });
            } else {
                osal.logPublic("bt probe: env oob=0x{x:0>8}", .{envp});
            }
        }
    }
    if (rc != 0) return rc;

    // 6. 归档：HCI 流控环境
    enter(8, "r_btdm_hci_fc_env_init");
    rc = step(8, "r_btdm_hci_fc_env_init", if (freestanding) r_btdm_hci_fc_env_init() else 0);
    if (rc != 0) return rc;

    // 7. BLE 控制器：**先注册 ext_funcs**（controller 的 malloc/free/rand/assert 都在这张表里，
    //    跳过它就等于 controller 没有分配器 ⇒ r_ble_controller_init 必然失败）
    enter(9, "esp_register_ext_funcs");
    rc = step(9, "esp_register_ext_funcs", if (freestanding) r_ext_funcs.register() else 0);
    if (rc != 0) return rc;
    // 再注册 BB 回调 → r_ble_controller_init → msys
    enter(9, "esp_ble_register_bb_funcs");
    rc = step(9, "esp_ble_register_bb_funcs", if (freestanding) esp_ble_register_bb_funcs() else 0);
    if (rc != 0) return rc;
    enter(10, "r_ble_controller_init");
    rc = step(10, "r_ble_controller_init", if (freestanding) r_ble_controller_init(&cfg.ble) else 0);

    {
        const p0: usize = rdUsz(0x2f01_1030);
        if (p0 >= 0x2f00_0000 and p0 < 0x2f10_0000) {
            var a0v: u64 = 0;
            var a1v: u64 = 0;
            var node: usize = rdUsz(p0);
            var k: usize = 0;
            while (node >= 0x2f00_0000 and node < 0x2f10_0000 and k < 8) : (k += 1) {
                const op: u64 = mmioRdN(u16, node);
                if (op == 6) watch_node6 = node;
                const sh: u6 = @intCast(16 * (3 - (k % 4)));
                if (k < 4) a0v |= op << sh else a1v |= op << sh;
                node = rdUsz(node + 8);
            }
            osal.logPublic("bt probe: cb10 A=0x{x:0>16} B=0x{x:0>16} n={d}", .{ a0v, a1v, k });

            // STORE 观察点已拆除（2026-11-21）：写者已抓到（=step10 后 rtc_freq
            // 补丁，已修复）；留置会在 post-enable 区误命中 ⇒ trap 风暴 ⇒
            // rst:0x1a lockup ⇒ 毒化后续 boot（80-boot 窗 69/80 死 step4）。
        } else {
            osal.logPublic("bt probe: cb10 head oob=0x{x:0>8}", .{p0});
        }
    }
    // **调度器槽值追踪**：sleep/scheduler 对象指针（0x2f011034）——NMI2 读 0
    // 但 rc=0 要求 Zth2 的 malloc(32) 成功 ⇒ 有谁在 init 后清零，按步定位。
    {
        const slotv: *volatile u32 = mmioPtr(u32, 0x2f01_1034);
        osal.logPublic("bt probe: sched slot after step10 = 0x{x:0>8}", .{slotv.*});
        // **rtc_freq 补丁（2026-11-21 重写）**：⚠ 旧版无条件写 [2f011034]obj+24/28
        // ——obj+20 起是注册链节点（obj+24=节点 cb 指针、obj+28=next）⇒ 该写
        // 把 node6.next 清零截断链 ⇒ id2/5 脱链 ⇒ step17 Hl337(2) 未命中 rc=-3
        // （STORE 观察点抓到写者=本补丁）。真 sleep 对象在 [2f011044]。
        // 现只写 [2f011044] 的对象，且仅 obj[24]==0&&obj[28]==0（零除活体）时。
        const slp44: *volatile u32 = mmioPtr(u32, 0x2f01_1044);
        const obj44: u32 = slp44.*;
        if (obj44 >= 0x2f00_0000 and obj44 < 0x2f10_0000 and obj44 % 4 == 0) {
            const lo44: *volatile u32 = mmioPtr(u32, @as(usize, obj44) + 24);
            const hi44: *volatile u32 = mmioPtr(u32, @as(usize, obj44) + 28);
            if (lo44.* == 0 and hi44.* == 0) {
                lo44.* = 32000;
                hi44.* = 0;
                if (freestanding) board.trap.rtc_freq_rb = lo44.*;
                rtc_patch_rb = lo44.*;
                rtc_patch_done = true;
                osal.logPublic("bt probe: rtc_freq patch @1044 obj=0x{x:0>8}", .{obj44});
            } else {
                osal.logPublic("bt probe: rtc_freq nz @1044 +24=0x{x:0>8} +28=0x{x:0>8}", .{ lo44.*, hi44.* });
            }
        } else {
            osal.logPublic("bt probe: rtc_freq oob @1044 ptr=0x{x:0>8}", .{obj44});
        }
        if (false) {
            if (slotv.* >= 0x2f00_0000 and slotv.* < 0x2f10_0000) {
                mmioWr(slotv.* + 24, 32000);
                mmioWr(slotv.* + 28, 0);
                // **回读验证**：写后立即读 obj+24——rb==32000 ⇒ 写成功（step17
                // 失败另有因）；否则写异常/不可写。短行（FIFO 丢行风险最低）。
                const rb: u32 = mmioRd(slotv.* + 24);
                if (freestanding) board.trap.rtc_freq_rb = rb;
                rtc_patch_rb = rb;
                rtc_patch_done = true;
                osal.logPublic("bt p: rf rb={x}", .{rb});
                // **96B 对象全量 dump**（4 行 × 8 字）：对照官方字段找剩余零字段。
                var q: usize = 0;
                while (q < 96) : (q += 24) {
                    var ob: [128]u8 = undefined;
                    var oi: usize = 0;
                    const pc0 = std.fmt.bufPrint(ob[oi..], "bt o{d:0>2} +{d:0>3}:", .{ q / 24, q }) catch break;
                    oi += pc0.len;
                    var b: usize = 0;
                    while (b < 24) : (b += 4) {
                        const w: u32 = mmioRd(slotv.* + q + b);
                        const pc1 = std.fmt.bufPrint(ob[oi..], " {x:0>8}", .{w}) catch break;
                        oi += pc1.len;
                    }
                    ob[oi] = 0;
                    osal.logPublic("{s}", .{@as([*:0]const u8, @ptrCast(&ob))});
                }
            }
        }
    }
    if (rc != 0) return rc;
    stats_state.ext_funcs_registered += 1;
    // `ble_controller_scan_duplicate_config` 是 host 侧 ⇒ 空操作
    porting.bleControllerScanDuplicateConfig();
    enter(11, "ble_msys_init");
    rc = step(11, "ble_msys_init", porting.bleMsysInit());
    if (rc != 0) return rc;

    // 8. 归档：两个 stack 的 initEnv
    rc = step(12, "r_base_stack_initEnv", if (freestanding) r_base_stack_initEnv() else 0);
    if (rc != 0) return rc;
    rc = step(13, "r_conn_stack_initEnv", if (freestanding) r_conn_stack_initEnv() else 0);
    if (rc != 0) return rc;

    // 14. 公有地址：**没有它 HCI Reset 能过，但扫描/广播命令全部无效**
    var mac: [6]u8 = undefined;
    osal.readEfuseMac(&mac);
    std.mem.reverse(u8, &mac); // IDF 也是 `swap_in_place(mac, 6)` 之后再设
    osal.logPublic("bt bringup: public addr {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });
    enter(14, "r_esp_ble_ll_set_public_addr");
    rc = step(14, "r_esp_ble_ll_set_public_addr", if (freestanding) r_esp_ble_ll_set_public_addr(&mac) else 0);

    {
        const p0: usize = rdUsz(0x2f01_1030);
        if (p0 >= 0x2f00_0000 and p0 < 0x2f10_0000) {
            var a0v: u64 = 0;
            var a1v: u64 = 0;
            var k4_addr: usize = 0;
            var node: usize = rdUsz(p0);
            var k: usize = 0;
            while (node >= 0x2f00_0000 and node < 0x2f10_0000 and k < 8) : (k += 1) {
                const op: u64 = mmioRdN(u16, node);
                if (k == 4) k4_addr = node;
                const sh: u6 = @intCast(16 * (3 - (k % 4)));
                if (k < 4) a0v |= op << sh else a1v |= op << sh;
                node = rdUsz(node + 8);
            }
            // （cb14/lpcon/cblist17 行已回收：镜像容量紧张，读数历次稳定。）
            // **LPCON 回读（clean zone）**：BLE RTC timer 时钟链三寄存器粘性
            // 判别——值保持 ⇒ 写入生效（缺的不是这段）；值漂 ⇒ LP 域写问题。
            {
                const lp: usize = 0x2010_F000;
                const lpt04: u32 = mmioRd(lp + 0x04);
                const m32k: u32 = mmioRd(lp + 0x14);
                const cc18: u32 = mmioRd(lp + 0x18);
                _ = lpt04;
                _ = m32k;
                _ = cc18;
                // （本行已回收：镜像容量紧张。）
            }
            // **yield 注入（2026-11-21）**：task 空转轮询环 125ms/迭代从不让出
            // ⇒ 主上下文饿死。发布我们自己的 log sink（[2f010fb4]=obj，fn@+12/+28
            // = 让出桩）——task 的 log_internal 每迭代必查此 sink ⇒ 每迭代一次
            // sched.block() 让出 ⇒ 泵环恢复（diag/bridgeDrain/eventRun 活）。
            {
                // **sink 移入自有 .bss**（2026-11-21 终）：0x2f026000"堆不会到达"
                // 假设为假——trap 线实证 [sink+12] 被覆写成 0 后 jalr→NULL
                // （cause=1 取指 fault，ra=0x2f0087a4=bnez）⇒ CPU_LOCKUP 复位环。
                const sink: usize = @intFromPtr(&log_sink_storage);
                const yield_fn: usize = @intFromPtr(&btLogYieldStub);
                const ret_stub: usize = 0x4006_1554; // IC9 ret 桩
                var k7: usize = 0;
                while (k7 < 64) : (k7 += 4) {
                    // **全槽 ret 桩**（修复 PC=0 lockup）：blob 会调用 sink 的
                    // 其它 fn 槽——半零结构 = 调 0。默认全部 ret，再叠让出桩。
                    mmioWr(sink + k7, @truncate(ret_stub)); // 32 位槽写（主机 64 位对齐）
                }
                mmioWr(sink + 12, @truncate(yield_fn)); // 32 位槽写（主机 64 位对齐）
                mmioWr(sink + 28, @truncate(yield_fn)); // 32 位槽写（主机 64 位对齐）
                mmioWr(0x2f01_0fb4, @truncate(sink)); // 32 位槽写（主机 64 位对齐）
                osal.logPublic("bt probe: yield sink published obj=0x{x:0>8} fn=0x{x:0>8}", .{ sink, yield_fn });
            }
            // **判别读数**：cb7 捕获的 id2/5 节点地址（=env+52/+64）此刻的 id 值
            // 与链上第 5 节点地址比对——同址且 id=6 ⇒ 原地篡改；异址或 id=2 ⇒ 纯摘链。
            if (relink_p16 != 0 and relink_p16 % 4 == 0 and relink_p16 >= 0x2f00_0000 and relink_p16 < 0x2f10_0000) {
                const idn2: u32 = mmioRdN(u16, relink_p16);
                const nx2: usize = rdUsz(relink_p16 + 8);
                const idn5: u32 = if (relink_p20 >= 0x2f00_0000 and relink_p20 < 0x2f10_0000) mmioRdN(u16, relink_p20) else 0xFF;
                // （n2/n5 relink 读数行已回收：镜像容量紧张。）
                _ = idn2;
                _ = nx2;
                _ = idn5;
            }
            // **判别打印**：env→p16（节点2缓冲）现状 + 链尾 next。若 [p16] 仍=2
            // 而 node6.next 不指 p16 ⇒ 摘链；若 [p16]=0 ⇒ 内存被清（memset 型）。
            const envp: usize = rdUsz(0x2f01_1038);
            if (envp >= 0x2f00_0000 and envp < 0x2f10_0000) {
                const e0: usize = rdUsz(envp);
                if (e0 >= 0x2f00_0000 and e0 < 0x2f10_0000) {
                    const p16: usize = rdUsz(e0 + 16);
                    const p20: usize = rdUsz(e0 + 20);
                    const id16: u32 = if (p16 >= 0x2f00_0000 and p16 < 0x2f10_0000) mmioRdN(u16, p16) else 0xFFFF;
                    const nx16: usize = if (p16 >= 0x2f00_0000 and p16 < 0x2f10_0000) rdUsz(p16 + 8) else 0;
                    const id20: u32 = if (p20 >= 0x2f00_0000 and p20 < 0x2f10_0000) mmioRdN(u16, p20) else 0xFFFF;
                    osal.logPublic("bt probe: env+16=0x{x:0>8} id={d} nx=0x{x:0>8} | env+20=0x{x:0>8} id={d}", .{ p16, id16, nx16, p20, id20 });
                }
            }
            // 链尾节点（第 n 个）的 next 值
            if (k > 0) {
                var last: usize = rdUsz(p0);
                var j: usize = 1;
                while (j < k) : (j += 1) last = rdUsz(last + 8);
                const nxt: usize = rdUsz(last + 8);
                const lid: u32 = mmioRdN(u16, last);
                _ = nxt; // （last=/btslp16 读数行已回收：镜像容量紧张。）
                _ = lid;
            }
            // **deinit 判据**：task_deinit 尾部把 env[0] 清 0（state=1 为在位）。
            const envp2: usize = rdUsz(0x2f01_1038);
            if (envp2 >= 0x2f00_0000 and envp2 < 0x2f10_0000) {
                const e0: usize = rdUsz(envp2);
                const st: u8 = if (e0 >= 0x2f00_0000 and e0 < 0x2f10_0000) mmioRdN(u8, e0) else 0xFF;
                osal.logPublic("bt probe: env state={d}", .{st});
            }
        } else {
            osal.logPublic("bt probe: cb14 head oob=0x{x:0>8}", .{p0});
        }
    }
    if (rc != 0) return rc;

    // 15. **HCI 传输层**（IDF 里是 `esp_bt_controller_init` 的最后一步、enable 之前）。
    //     不做这一步：命令照样发得出去（我们直接调 forward），但 controller **没有回程回调**
    //     ⇒ Command Complete 永远到不了 `leEvtTx` ⇒ 症状是"init 全绿、命令发了、就是没回包"，
    //     极易被误判成时钟/中断/任务没做。
    enter(15, "hci_transport_init");
    // **load_cal 前移**（UART 存活期完成 FULL 校准——mce(13) 会关 UART0 时钟）：
    // mce(13)=PERIPH_PHY_CALIBRATION（deps 0x6364：FE 测量时钟）→ load_cal
    // （register_chipv7_phy FULL——此刻 tick 在、UART 在、模拟 prep 在）。
    {
        const mce = @extern(*const fn (modem: c_int) callconv(.c) void, .{ .name = "modem_clock_module_enable" });
        mce(13);
        // ⚠ **清 bit10（wifi_apb）**：mce(13) 的 deps 置此位 ⇒ UART0 APB 时钟被门控
        // ⇒ 观测通道死亡。FE 测量在自写路径实测不需要 bit10（clk_conf1=0x003ff880
        // 时期校准完成 rc=0）⇒ 清回后 UART 恢复且不影响校准。
        const c1p: *volatile u32 = mmioPtr(u32, 0x2010_9C14);
        c1p.* &= ~@as(u32, 1 << 10);
        const load_cal = @extern(*const fn () callconv(.c) void, .{ .name = "esp_phy_load_cal_and_init" });
        load_cal();
        mmioWr(0x2E00_0490, 0xADC0_5FC0); // LP：load_cal 已返回
        osal.logPublic("bt bringup: load_cal done (pre-mce13-uart-window)", .{});
    }
    rc = step(15, "hci_transport_init", transport.init());
    if (rc != 0) return rc;

    status_state = .inited;
    // **时间界定**：在 enable 之前采样两个睡眠段基址。
    // 若此处已被改 ⇒ 写入发生在 init 之前（bootloader/加载）；否则在 enable 路径里。
    // （last=/btslp16 读数行已回收：镜像容量紧张。）
    {
        var probe_local2: u8 = 0;
        if (freestanding) board.trap.diag_b = @intCast(@intFromPtr(&probe_local2) & 0xFFFF);
    }
    anaSnap(); // 轮 51 槽 2：INITED
    osal.logPublic("bt bringup: INITED", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// enable（6 步）——`r_btdm_task_enable` 在这条链的**最后**
// ---------------------------------------------------------------------------

pub fn enable() c_int {
    stats_state.enable_calls += 1;
    if (status_state != .inited) {
        osal.logPublic("bt bringup: enable refused, status={s}", .{@tagName(status_state)});
        return -1;
    }

    porting.btdmLpReset(true);
    // **esp_btbb_enable（官方链：phy_enable → btbb_enable → ble_stack_enable）**：
    // 内部 `bt_bb_v2_init_cmplx(BTBB_ENABLE_VERSION_PRINT)`——BB 调度器构建，
    // 经 step 9 注册的 bb funcs 回调（[a4+36]）走正式入口。此前整段缺失 ⇒
    // bb_v2_init 从未运行 ⇒ BB 调度器不存在 ⇒ 中断不触发/FE 冻结/无广播。
    // （旧"手动 bb_v2_init = 永等"是顺序错误：在注册前的 init 阶段手动调；
    // 此刻注册已完成、phy 已使能，与官方时序一致。）
    // **FE450 bit13 实验（2026-11-22，ch29 §29.24 下一入口）**：0x20100450 静态值
    // 官方 0x00102000（bit13=1，疑似 BB/RF ready）vs 我们 0x00110000（bit16=1）。
    // enable 前对齐官方值；若 LL 调度器在等 bit13，泵应越过 fwd06 后的下一条锚点。
    // **轮 56 默认 false**：抢先 btbb init 毒化假说（见下方 if 块注释）。
    const btbb_early_enable = false;
    mmioPtr(u32, 0x2010_0450).* = 0x0010_2000;
    // **轮 56：抢先 btbb init 毒化假说**——oracle 侧 esp_btbb_enable 首次真跑
    // 发生在 enable 相（btdm_lp_reset 内），blob task 的 init 体在自己的时间线
    // 做 RF init ana 写；我们 bringup 抢先调 esp_btbb_enable ⇒ bt_bb_v2_init_cmplx
    // 置"bb 已初始化"静态 ⇒ task init 体跳过 RF init（F800 零写、fe=0）。
    // 本实验默认关掉抢先调用，让 task 自己跑完整 init。判据 = F800 写帧
    // （bit24=1）+ rfready/evt 链。
    if (btbb_early_enable) {
        const esp_btbb_enable = @extern(*const fn () callconv(.c) void, .{ .name = "esp_btbb_enable" });
        anaSnap(); // 轮 51 槽 0：btbb 前
        osal.logPublic("bt bringup: calling esp_btbb_enable", .{});
        esp_btbb_enable();
        anaSnap(); // 轮 51 槽 1：btbb 后
        osal.logPublic("bt bringup: esp_btbb_enable done", .{});
        // 回读：若被 enable 内部改回，说明写点要移到 enable 之后（别急着判死）。
        osal.logPublic("bt probe: fe450=0x{x:0>8}", .{mmioRd(0x2010_0450)});
    }
    enter(16, "btdm_coex_enable");
    var rc = step(16, "btdm_coex_enable", porting.btdmCoexEnable());
    if (rc != 0) return rc;

    // **rc=-3 根因探针**：base_stack_enable 第二段注册 Hl337(id=2) 在
    // [2f011030] 链表扫 u16 id==2，未命中返回 -1 ⇒ 传导 -3。遍历打印链节点。
    {
        const p0: usize = rdUsz(0x2f01_1030);
        if (p0 >= 0x2f00_0000 and p0 < 0x2f10_0000) {
            // 紧凑单行（双组 u64，各 8 个 16-bit id，零叠写；FIFO 撞行免疫）
            var a0v: u64 = 0;
            var a1v: u64 = 0;
            var node: usize = rdUsz(p0);
            var k: usize = 0;
            while (node >= 0x2f00_0000 and node < 0x2f10_0000 and k < 8) : (k += 1) {
                const op: u64 = mmioRdN(u16, node);
                const sh: u6 = @intCast(16 * (3 - (k % 4))); // 48,32,16,0 —— 每组 4 id，零叠写
                if (k < 4) a0v |= op << sh else a1v |= op << sh;
                node = rdUsz(node + 8);
            }
            const tailc: usize = rdUsz(p0 + 4);
            _ = tailc; // （cblist 行已回收：镜像容量紧张；读数历次稳定）
        } else {
            osal.logPublic("bt probe: cblist head oob=0x{x:0>8}", .{p0});
        }
    }
    // **重挂 id2/id5**（实证：step10-14 间 blob 侧 task_deinit 摘走 [env+16]/[env+20]
    // 两节点 ⇒ step17 的 Hl337(2) 扫描未命中 ⇒ rc=-3）。节点内存未被清，原样重链。
    if (freestanding and relink_p16 != 0 and relink_p20 != 0) {
        const id16: u32 = mmioRdN(u16, relink_p16);
        const id20: u32 = mmioRdN(u16, relink_p20);
        if (id16 == 2 and id20 == 5) {
            r_sym_bt_kNIbP2qfZqaMNyimIzAy(@ptrFromInt(relink_p16), 2);
            r_sym_bt_kNIbP2qfZqaMNyimIzAy(@ptrFromInt(relink_p20), 5);
            osal.logPublic("bt probe: relink 2/5 ok", .{});
        } else {
            osal.logPublic("bt probe: relink skip id16={d} id20={d}", .{ id16, id20 });
        }
    }
    enter(17, "r_base_stack_enable");
    rc = step(17, "r_base_stack_enable", if (freestanding) r_base_stack_enable() else 0);
    // **post-17 混叠探针**：slot 指针（s0 结构 +0/+4/+8）+ 链表复扫。若 slot1 与
    // id-2 节点同缓冲，handler 存入(0x4001511a)把节点 id 覆成 0x511a ⇒ 复扫缺 2。
    {
        const s0p: usize = mmioRd(0x2f01_0f14);
        // 32 位字读（主机 64 位上 `*usize` 对 +4 地址会对齐失败）。
        const sl0: usize = if (s0p >= 0x2f00_0000 and s0p < 0x2f10_0000) mmioRd(s0p) else 0;
        const sl1: usize = if (s0p >= 0x2f00_0000 and s0p < 0x2f10_0000) mmioRd(s0p + 4) else 0;
        const sl2: usize = if (s0p >= 0x2f00_0000 and s0p < 0x2f10_0000) mmioRd(s0p + 8) else 0;
        // （slots 行已回收：镜像容量紧张）
        _ = sl0;
        _ = sl1;
        _ = sl2;
        const p0: usize = rdUsz(0x2f01_1030);
        if (p0 >= 0x2f00_0000 and p0 < 0x2f10_0000) {
            var a0v: u64 = 0;
            var a1v: u64 = 0;
            var node: usize = rdUsz(p0);
            var k: usize = 0;
            while (node >= 0x2f00_0000 and node < 0x2f10_0000 and k < 8) : (k += 1) {
                const op: u64 = mmioRdN(u16, node);
                const sh: u6 = @intCast(16 * (3 - (k % 4)));
                if (k < 4) a0v |= op << sh else a1v |= op << sh;
                node = rdUsz(node + 8);
            }
            // （本行已回收：镜像容量紧张。）
        }
    }
    if (rc != 0) return rc;
    enter(18, "r_conn_stack_enable");
    rc = step(18, "r_conn_stack_enable", if (freestanding) r_conn_stack_enable(0) else 0);
    if (rc != 0) return rc;

    enter(19, "r_btdm_hci_fc_enable");
    rc = step(19, "r_btdm_hci_fc_enable", if (freestanding) r_btdm_hci_fc_enable() else 0);
    if (rc != 0) return rc;

    // **最后一步**：controller 任务在这里才真正启动
    // **注册桩 sleep 回调**（sleep_en=1 ⇒ 调度器会调 obj[4]；未注册 ⇒
    // btdm_sleep.c:684 assert 后 jalr 0 ⇒ lockup，板载实证）。槽在 step 10
    // 已建 ✓ 此刻注册安全。
    if (freestanding) {
        // ⚠ 条件**不能**用 cfg.btdm.sleep_en——归档在 task_init 会回写该字段
        // （sleep_en=0 轮实证：step20 前已非 0 ⇒ 注册器被调 ⇒ 槽 NULL ⇒
        // load fault @0xc panic）。以**槽本身**为准：非空才注册。
        // **轮 71 终修**：守卫槽 = 0x2f011134（sleep env 槽——set_sleep_cb
        // 内部读 *(此槽)+12 做 store 目标；NULL ⇒ store-to-NULL fault 0x58）。
        // 槽=NULL ⇒ sleep OFF（OB0cbi2 同判据）⇒ 跳过注册 = 官方正确行为。
        const slot_chk: *volatile u32 = mmioPtr(u32, 0x2f01_1134);
        if (slot_chk.* != 0) {
            board.log.line("S1 slot134={x:0>8}", .{slot_chk.*});
            // a1=null 会命中 beqz a1 → .L75 整体跳过（obj[4] 不写）⇒
            // arg 用非空占位（桩不读它）。a4=0 跳过 .L79 附加初始化。
            const sleep_arg: usize = @intFromPtr(&btSleepCb);
            const rc_slp = r_btdm_sleep_set_sleep_cb(&btSleepCb, @ptrFromInt(sleep_arg), 0, 0, 0);
            osal.logPublic("bt probe: sleep_cb reg => {d}", .{rc_slp});
        } else {
            osal.logPublic("bt probe: sleep_cb skip (slot null)", .{});
        }
    }
    // **anchor[8]+12 = SRAM 窗口基址**（2026-11-21 oracle 对拍）：官方描述符
    // `[anchor8+12]=0x2f000000`；`r_btdm_task_enable → vJfrsAScC → 4S888Ay →
    // aGdrujd2` 据此写 `[0x20101074] = base & 0xFFC00000`（blob 的紧凑句柄
    // 解码基址：`ptr = base | (idx<<2)`）。我们这边 +12=0 ⇒ 基址 0 ⇒ 解码出
    // 裸偏移（实测 mepc=0x60 = 0x18<<2）⇒ 取指 fault。task_enable 前置为官方值。
    {
        const a8: usize = rdUsz(0x2f01_8720);
        if (a8 >= 0x2f00_0000 and a8 < 0x2f10_0000 and a8 % 4 == 0) {
            const mb: *volatile u32 = mmioPtr(u32, a8 + 12);
            if (mb.* == 0) mb.* = 0x2f00_0000;
        }
    }
    enter(20, "r_btdm_task_enable");
    rc = step(20, "r_btdm_task_enable", if (freestanding) r_btdm_task_enable() else 0);
    if (rc != 0) return rc;
    {
        const slotv: *volatile u32 = mmioPtr(u32, 0x2f01_1034);
        osal.logPublic("bt probe: sched slot after step20 = 0x{x:0>8}", .{slotv.*});
    }

    status_state = .enabled;
    osal.logPublic("bt bringup: ENABLED", .{});

    // **HCI 往返不在 enable() 里做**：controller 是**协作式任务**，
    // 必须每轮 `sched.resumeTask` + `osal.serviceCallouts` 才能推进。
    // 裸忙等**不会让它运行** ⇒ 会得到假 "NO EVENT"。
    // 成熟写法见 `probe.zig` 的 "5) 发第一条命令并泵任务"。

    return 0;
}

// ---------------------------------------------------------------------------
// 主机用例
// ---------------------------------------------------------------------------

var fake_step: u32 = 0;
var fail_at: u32 = 0;

fn fakeCall(n: u32) c_int {
    fake_step = n;
    if (fail_at != 0 and n == fail_at) return -7;
    return 0;
}

test "bringup: init 走到 INITED，enable 走到 ENABLED" {
    fake_step = 0;
    fail_at = 0;
    setHooks(.{ .call = fakeCall });
    defer setHooks(.{});
    var cfg = config.defaults();
    try std.testing.expectEqual(@as(c_int, 0), init(&cfg));
    try std.testing.expectEqual(Status.inited, status());
    try std.testing.expectEqual(@as(u8, 1), getStatus());
    try std.testing.expectEqual(@as(c_int, 0), enable());
    try std.testing.expectEqual(Status.enabled, status());
    // 最后一步必须是 task_enable（否则 controller 任务没起来）
    try std.testing.expectEqual(@as(u32, 20), fake_step);
    // 跳过了 host-only 的 ext_funcs
    try std.testing.expectEqual(@as(u32, 1), stats().ext_funcs_registered);
}

test "bringup: 任一步失败就停下并记录是哪一步" {
    fake_step = 0;
    fail_at = 10; // r_ble_controller_init
    setHooks(.{ .call = fakeCall });
    defer setHooks(.{});
    var cfg = config.defaults();
    try std.testing.expectEqual(@as(c_int, -7), init(&cfg));
    try std.testing.expectEqual(@as(u32, 10), stats().failed_step);
    try std.testing.expectEqual(Status.idle, status());
    fail_at = 0;
}

test "bringup: 未 init 时 enable 被拒" {
    setHooks(.{ .call = fakeCall });
    defer setHooks(.{});
    var cfg = config.defaults();
    _ = init(&cfg); // 先回到 idle 之外
    // 手工把状态打回 idle，模拟"没 init 就 enable"
    status_state = .idle;
    try std.testing.expectEqual(@as(c_int, -1), enable());
}

/// 把外设源号对应的 CLIC 输入使能，并置 `mie` 位。
// ---------------------------------------------------------------------------
// **ISR 桥**（2026-11-20）：blob handler 在 trap 上下文不安全（其内
// eventqPut→resumeTask 破坏调度器，实证 boot 循环）。桥两半：
// - trap 半 `bridgeIsr`：只把 (f,arg) 压环、立即返回——trap 安全；
// - 主泵半 `bridgeDrain`（probe 泵循环每轮调用）：主上下文逐个代跑——
//   "唤醒只能在主上下文"的正解。
// ---------------------------------------------------------------------------
const BridgeEntry = struct {
    f: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
};
const BridgeSrc = struct {
    in_use: bool = false,
    input: usize = 0,
    f: *const fn (?*anyopaque) callconv(.c) void = undefined,
    arg: ?*anyopaque = null,
};
var bridge_srcs: [4]BridgeSrc = @splat(.{});
var bridge_ring: [16]BridgeEntry = undefined;
pub var bridge_w: u32 = 0;
var bridge_r: u32 = 0;
pub var bridge_ran: u32 = 0;
pub var bridge_dropped: u32 = 0;

fn bridgeIsr(raw_arg: ?*anyopaque) callconv(.c) void {
    const s: *BridgeSrc = @ptrCast(@alignCast(raw_arg orelse return));
    // **入环即屏蔽该输入**（2026-11-21，结构性修复）：BT_MAC 中断是**电平型**，
    // 真正 ack 源的是被延迟到主上下文代跑的 blob ISR。trap 半只入环不屏蔽 ⇒
    // `mret` 后立刻重入（中断风暴，主上下文饿死）；2 ms 后 T0 NMI 嵌套进风暴，
    // 而 trap 入口用的是**固定顶部的私有栈、不支持嵌套** ⇒ 嵌套 handler 覆盖外层
    // 栈 ⇒ 整机静默脱轨（"路由 v4 后失声"的机制）。`bridgeReenable()` 在代跑后开回。
    if (freestanding and s.input < 64) hw.writeReg(0x1080_1000 + @as(usize, @intCast(s.input)) * 4, 0x7f00_0000);
    bridge_masked +%= 1;
    if (bridge_w -% bridge_r < bridge_ring.len) {
        bridge_ring[bridge_w % bridge_ring.len] = .{ .f = s.f, .arg = s.arg };
        bridge_w +%= 1;
    } else {
        bridge_dropped +%= 1;
    }
}

/// 代跑结束后把桥接输入的 IE 开回（主上下文，每轮调用，幂等）。
pub fn bridgeReenable() void {
    if (!freestanding) return;
    for (&bridge_srcs) |*s| {
        if (s.in_use and s.input < 64) hw.writeReg(0x1080_1000 + @as(usize, @intCast(s.input)) * 4, 0x7f00_0100);
    }
}

// **BB 中断链（src125 → input53 → 链表头 0x2f07f19c 的三 handler）**：
// ROM 表 ext37 条目 = {0x2f07f19c（链表头）, 0x2f81280e}——链表节点即
// 三条 blob handler（全偶地址，args 0x85/0x03/0x84）。
// ⚠ **三条目代跑即崩（机制未定案）**：uart_hscan.log 实证——代跑首次
// invoke 即 CPU lockup，×7 周期死点一致（0x40077740=trapDispatch 内
// log.line 双重 fault）。'ctx 槽 0x2f07f1F4=0 ⇒ 空指针解引用'系 b9d6a19
// 已撤回的前提，勿复用；三条目被 5521df1 解码为 intr 管理 API 家族而非
// 硬件 ISR，拿 0x85/0x03/0x84 当 ISR 参数代跑本身可能是契约误用。
// ⇒ chainIsr 现为纯计数 no-op；chain_fns/chain_args 已删（地址留 README），
// **恢复代跑前必须先反汇编三条目定契约**。
/// 板级寄存器写（trap 半用；主机测试图里为空）。
const hw = if (@import("builtin").os.tag == .freestanding) @import("board").hw else struct {
    pub fn writeReg(_: usize, _: u32) void {}
};
pub var bridge_masked: u32 = 0;
var chain_fires: u32 = 0;
fn chainIsr(_: ?*anyopaque) callconv(.c) void {
    chain_fires +%= 1;
}

/// 主泵循环每轮调用：代跑桥里积压的 blob handler（主上下文，调度器安全）。
pub var bridge_logged: bool = false;
pub fn bridgeDrain() void {
    var guard: u32 = 0;
    while (bridge_r != bridge_w and guard < 64) : (guard += 1) {
        const e = bridge_ring[bridge_r % bridge_ring.len];
        bridge_r +%= 1;
        bridge_ran +%= 1;
        if (!bridge_logged) {
            bridge_logged = true;
            const fp: usize = @intFromPtr(e.f);
            const ap: usize = if (e.arg) |a| @intFromPtr(a) else 0;
            @import("osal_kit").osal.logPublic("bt bridge: first fn=0x{x:0>8} arg=0x{x:0>8}", .{ fp, ap });
        }
        e.f(e.arg);
    }
}

/// 把外设源号对应的 CLIC 输入使能，并置 `mie` 位。
/// ⚠ `src` 是**源号**，未必等于 CPU 输入号 ⇒ 同时尝试 `src & 63`，
/// 并在日志里给出可用 `findPendingClicInput()` 校正的入口。
pub fn intrArm(src: c_int) void {
    if (@import("builtin").target.os.tag != .freestanding) return;
    // （`hw` 用文件级的门控别名：主机测试图里是同签名空壳。）
    // **路由目标改判 v2（ROM 表布局解码）**：ext34 fn 槽=0x2f81281e **奇数**
    // （RISC-V 函数指针不合法 ⇒ 该槽是 arg/数据）；真 fn 在相邻槽：
    // ext35=0x2f815258（偶 ✓）、ext37=0x2f07f19c（wrapper ✓）。blob 期望的
    // CLIC 输入 = 对应 ext+16：**MAC(src124) → 51、BB(src125) → 53**。
    // （前轮路由 124→50：源触发→桥压环→drain 跳奇地址崩→复位循环 ×6 实证——
    // 路由本身通了，只是 fn 槽选错。）
    // **路由目标 v3（hscan 实证）**：blob 经 intr_handler_set(**21**, handler)
    // 注册——截断的 hscan 首命中 handlers[5]（=ext5，即 CLIC input 21）非空。
    // ⇒ blob 期望 MAC 中断到达 **input 21**（ext 5）。125（BB）→ 22 仅路由
    // （ext6 无 handler 时不置 IE，风暴安全）。
    // **路由 v4 = 官方 oracle 对拍（2026-11-21）**：IDF v6.1 官方固件
    // enable 后实测 `MAP[124]=0x00000018`（BT_MAC → CLIC 输入 **24**，bit8 清）、
    // `intctl[24]=0x7fc10100`（prio=0x7f + bits14-15 + IE）、`MAP[125]=0`
    // （BT_BB **不映射**）、输入 21 属 src27（非 BT）、输入 53 未配置。
    // 旧 v3 的 124→21/125→53 与官方三处偏离（输入号/intctl 值/MAP bit8）。
    if (src != 124) return; // 官方只映射 124（125 不映射）
    const routed_input: usize = 24; // MODEM_BT_MAC → 官方输入 24
    // **路由（此前整段缺失 = FE 冻结根因）**：S31 的中断源 ≠ CPU 输入号，每源一个
    // MAP 寄存器（表基 0x2058_5000，源 0=SYS_ICM 于 +0x0、源 124=MODEM_BT_MAC 于
    // +0x1F0、源 125=MODEM_BT_BB 于 +0x1F4）。不写 MAP，CLIC 里永远看不到 pending
    // （routeT0Interrupt 同款教训，见 hw.zig 注释）。bits[5:0]=input，bits[9:8]=
    // pass_level（非零才启用）。
    hw.writeReg(0x2058_5000 + @as(usize, @intCast(src)) * 4, routed_input & 0x3F); // 官方值 0x18（bit8 清）
    // CLIC intctl：prio [31:24] **必须非零**（prio=0 的电平输入永不触发）+ IE bit8。
    // ⚠ **IE 与 handler 必须同开同关**：IE 置位而不挂 handler（或不挂清理源的电平
    // ISR）⇒ CPU 取中断 → dispatch 忽略 → IP 永不清 → 风暴循环（CPU 饿死）。
    // ⚠ **挂 blob handler 原样已实证 boot 循环**（trap 上下文不安全）——本桥
    // （bridgeIsr）只把 (f,arg) 压环立即返回，blob handler 由主泵 bridgeDrain
    // 代跑（调度器安全）。目标输入上 dispatch 将命中：我们的桥 → 主泵代跑。
    const isr_bridge = true;
    var bridged = false;
    if (comptime isr_bridge) {
        // handler 优先级：intrAlloc 登记（罕见）→ **ROM 表**（blob 直注
        // intr_handler_set 的真 ISR——IDF 语义 osal intr_alloc 可传 fn_=null，
        // handler 另经 ROM 表注册；romHandler = dispatch 兜底的同一来源）。
        var hf: ?*const fn (?*anyopaque) callconv(.c) void = null;
        var harg: ?*anyopaque = null;
        if (@import("osal_kit").osal.intrHandlerOf(src)) |h| {
            hf = h.f;
            harg = h.arg;
        }
        // **oracle 路由下不回退到自有表/链表头**：v3 的 `getHandler(21-16)` 命中
        // 的很可能是我们自己登记的 bridgeIsr（自证污染）。fn 缺失 ⇒ 纯计数桩
        // 仍挂桥（bridgeDrain 代跑只计数不触碰 blob；bridge_w>0 即证"源在发"）。
        if (hf == null) hf = countOnlyIsr;
        if (hf) |f| {
            bridged = true;
            for (&bridge_srcs) |*s| {
                if (!s.in_use) {
                    s.* = .{ .in_use = true, .input = routed_input, .f = f, .arg = harg };
                    // ⚠ **IE 不在这里置**：enable 期间置 IE，源一触发 handler 就在
                    // trap 上下文跑（boot 循环实证）——IE 由 probe 泵循环在
                    // bridgeDrain 激活后才开（见 probe.zig "ISR 桥 IE 延迟使能"，
                    // 对 input 21 与 input 53 同时生效）。
                    hw.writeReg(0x1080_1000 + routed_input * 4, 1 << 24); // 仅 prio
                    if (freestanding) board.trap.setHandler(routed_input, bridgeIsr, s);
                    break;
                }
            }
        }
    }
    const bit: u32 = @as(u32, 1) << @intCast(routed_input & 31);
    if (comptime @import("builtin").cpu.arch.isRiscv()) asm volatile ("csrs mie, %[b]"
        :
        : [b] "r" (bit),
    );
    @import("osal_kit").osal.logPublic("bt osal: arm src={d} -> CLIC input {d} (routed, bridged={}) mie|=0x{x}", .{ src, routed_input, bridged, bit });
}
