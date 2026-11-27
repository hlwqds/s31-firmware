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
/// 合并镜像的真实链路步骤（`firmware/src/coex_merged.zig`，`-Dcoex-wifi-link`）用的入口：`link_probe.zig` 的
/// `linkStart()` / `linkRest()` / `linkScan()`。只有那一种镜像引用它；别的镜像里这一项不被分析，`link_probe.zig`
/// 要的 `probe_opts` / `net_ipv4` / `net_udp` 模块也就不必挂进来。
pub const link = @import("link_probe.zig");
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
const wpa_cb = @import("wpa_cb.zig");

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
// ---------------------------------------------------------------------------
// 全量寄存器对照（2026-11-25）：与官方 IDF oracle（`tools/wifi-idf-oracle/`）在 `esp_wifi_init`
// 之后对照 523 个有定义的寄存器（`regDumpAll`，地址表在它上方）。差集分析与单变量实验的结论：
//
//   - 两边 95 个不同，集中在 PMU 与 MODEM_LPCON；
//   - 其中 77 个可以在 init 之前安全地按 IDF 值写入，**全部写进去之后 `MAC_ST` 仍是 0xE000**
//     ⇒ 它们都不是 init / start 的必要条件；
//   - 充要的是 IDF `pmu_init()` 里的一步：给三个 HP 电源模式写 modem 的 ICG 码（2/1/0）并触发
//     两次立即更新。由 `initOnly` 开头的 `board.pmu.initModemIcg()` 完成（出处与实测表见该文件）。
//
// 单变量实验用的一次性开关与移植表已随实验结束删除。
// ---------------------------------------------------------------------------
/// 打印 523 个寄存器（与 oracle 对照用）。约 1.4 秒串口时间，默认关。
const probe_regdump = false;
/// blob 的日志级别，取值是 `wifi_log_level_t`（`esp_private/wifi.h:390-397`）：0 none、1 error、2 warning、
/// 3 info、4 debug、5 verbose。默认 3，与 IDF 默认配置（`CONFIG_LOG_DEFAULT_LEVEL=INFO`）一致。
pub var blob_log_level: c_int = 3;

/// `_phy_enable(modem)` 的首次部分：首次调用做 `register_chipv7_phy`（IDF 的
/// `esp_phy_enable` → `esp_phy_load_cal_and_init` 就是这个时机）。返回 1 表示"已经标定过，这次没做事"，
/// 调用方据此走 IDF 的另一条路（`phy_wakeup_init`）。
var phy_registered = false;
fn phyEnableHook(modem: u32) usize {
    if (phy_registered) return 1;
    const register_phy = @extern(*const fn (*const [128]u8, *[1894]u8, u32) callconv(.c) c_int, .{
        .name = "register_chipv7_phy",
    });
    // IDF 存过标定数据之后的启动读 NVS 里的数据、配 `PHY_RF_CAL_PARTIAL`（`esp_phy_load_cal_and_init`）。
    // 本镜像不持久化标定数据，所以每次启动都做全量标定（IDF 首次启动的做法 `PHY_RF_CAL_FULL`）。
    // 2026-11-26 板侧对照过：与用对照镜像存在本板的标定数据相比，只多约 30 ms（首条 blob 日志 1621 →
    // 1650 ms），扫描结果一致（31 个共同 AP 的 authmode / 信道全部相同，RSSI 平均差 0.3 dB）。
    // 持久化标定数据（之后走 PARTIAL）是后续项。
    // 标定前把 station MAC 写进 `cal_data->mac`（偏移 4，6 字节）——IDF 在标定前就是这么做的；
    // 标定数据是 MAC 绑定的（`phy_rfcal_data_check_new`/`_sub_new` 会校验）。
    const mode: u32 = 2; // PHY_RF_CAL_FULL
    @memcpy(cal_data[4..10], &macHook());
    const rc = register_phy(&phy_init_data.params, @ptrCast(&cal_data), mode);
    phy_registered = true;
    // 标定到底做没做：`cal_data` 在调用前是全 0，FULL 标定会往里写结果。数一下非零字节数。
    var nz: usize = 0;
    for (cal_data) |b| {
        if (b != 0) nz += 1;
    }
    log.line("wifi-init-probe: _phy_enable(modem={d}) -> register_chipv7_phy rc={d}; cal_data: version={d} mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} nonzero={d}/1904 head={x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        modem,        rc,           cal_data[0],  cal_data[4],  cal_data[5],  cal_data[6],
        cal_data[7],  cal_data[8],  cal_data[9],  nz,           cal_data[10], cal_data[11],
        cal_data[12], cal_data[13], cal_data[14], cal_data[15], cal_data[16], cal_data[17],
    });
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
var pump_logs: u32 = 0;
var ready_swaps: u32 = 0;
/// 当前控制权是否在任务上下文里。
var in_task: bool = false;
/// 合并镜像（`-Dcoex-merged`）里，控制权此刻是否在**别人的任务栈**上（BLE controller 的任务）。
/// 那种时候绝不能泵 Wi-Fi 任务：`pumpRealTask` 会把 Wi-Fi 这边存的主栈指针改写成 BLE 任务的栈指针，
/// 两边的调度状态一起报废（ADR-003 第 2 节"一个调度器"要解决的正是这件事）。为真时让出点
/// 只计数、立即返回，调用它的信号量 / 队列等待按"没拿到"处理。
pub var foreign_context: bool = false;
/// 因 `foreign_context` 而拒绝让出的次数。
pub var foreign_refusals: u32 = 0;
/// 任务上下文是否已经建立（建立前 idle 只计数）。
var task_ctx_ready: bool = false;

/// 合作式调度的核心：主上下文与任务上下文互相让出。
///
/// - 在**主**上下文里被调用（blob API 阻塞等任务应答）→ 切到任务；
/// - 在**任务**上下文里被调用（任务阻塞收消息）→ 切回主上下文。
fn semArgs() u64 {
    // 每个参数是 `(max<<16)|init`；只带前 2 个（32 位足够），避免打包丢失信息。
    return @as(u64, impl.sem_create_args[0]) | (@as(u64, impl.sem_create_args[1]) << 32);
}

fn giveStats() u64 {
    return (@as(u64, impl.null_give) << 32) | @as(u64, impl.give_total);
}

fn queueStats() u96 {
    return (@as(u96, impl.last_recv_count) << 64) |
        (@as(u96, impl.recv_ok) << 32) | @as(u96, impl.send_ok);
}

fn nvsStats() u96 {
    return (@as(u96, @intCast(impl.nvs_last_rc)) << 64) |
        (@as(u96, impl.nvs_last_want) << 32) | @as(u96, impl.nvs_get_blob_calls);
}

/// round-robin 泵**真实任务上下文**（init 的 `take` 阻塞期间，PP 任务必须能跑）。
var pump_idx: usize = 0;
/// **实际切到任务的次数**——`idle_calls` 是"进了钩子几次"，不等于"切了几次任务"。
var task_switches: u64 = 0;
var cur_task: ?*impl.Task = null;
fn pumpRealTask() bool {
    if (impl.task_count == 0) return false;
    var tried: usize = 0;
    while (tried < impl.task_count) : (tried += 1) {
        const i = (pump_idx + tried) % impl.task_count;
        const t = &impl.tasks[i];
        if (t.ctx.sp == 0) continue;
        pump_idx = (i + 1) % impl.task_count;
        cur_task = t;
        in_task = true;
        impl.current_is_task = true;
        sched.enterAs(&t.ctx);
        task_switches +%= 1;
        sched.swapContext(&main_ctx, &t.ctx);
        // 从任务切回：任务在自己的阻塞点调了 on_idle。
        cur_task = null;
        in_task = false;
        impl.current_is_task = false;
        return true;
    }
    return false;
}

// **自旋让出补丁已回滚（不安全）**：从桩里调 `pumpRealTask()` 直接 `instruction access fault`
// （`!! 3d306120 3d306120 80007881`，跳到垃圾地址）。原因：`main_ctx` 只由 `sched.start()` 登记，
// 从 main 的**任意点**（这里是 blob 代码里的自旋桩）让出时没有对应帧，切回来就错位；
// 而走 `idleHook()` 又因为 `in_task` 是残留 true 而走"从任务切回主"分支，用错基址 swap。
// ⇒ 要做这件事，必须先让"让出点"能登记自己的 main 帧（每处让出点一个 `Context`），
// 不是改几个字节就能解决的。

/// **时钟域六寄存器快照**（IDF 对照用）：写前 / 写后 / init 后 三个时刻各打一次。
/// "钩子被调 ≠ 位真的生效" 是当前唯一未验证的环节，这张表就是判据。
/// MAC 块全窗口的**校验和**（4 KB，`0x20104000..0x20105000`）——逐字 dump 太占串口，
/// 用异或+求和两个数就能与 IDF 侧对照"整块是否相同"。
fn macWindowHash() struct { x: u32, s: u32 } {
    const w: [*]const volatile u32 = @ptrFromInt(0x2010_4000);
    var x: u32 = 0;
    var s: u32 = 0;
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        const v = w[i];
        x ^= v *% @as(u32, @intCast(i + 1));
        s +%= v;
    }
    return .{ .x = x, .s = s };
}

fn dumpClockRegs(tag: []const u8) void {
    const R = struct { name: []const u8, addr: usize };
    const regs = [_]R{
        .{ .name = "test_conf(+00)", .addr = 0x2010_9C00 },
        .{ .name = "clk_conf(+04)", .addr = 0x2010_9C04 },
        .{ .name = "force_on(+08)", .addr = 0x2010_9C08 },
        .{ .name = "icg(+0C)", .addr = 0x2010_9C0C },
        .{ .name = "rst_conf(+10)", .addr = 0x2010_9C10 },
        .{ .name = "clk_conf1(+14)", .addr = 0x2010_9C14 },
        .{ .name = "lpcon+18", .addr = 0x2010_F018 },
        // LPCON 侧还有两个我们**从没写过**的：force_on(+0x1C) 与 ICG 位图(+0x20)。
        // IDF 的 `modem_clock_hal_set_clock_domain_icg_bitmap()` 对 SYSCON 侧和 LPCON 侧**都写**，
        // 我们只写了 SYSCON 侧那张 ⇒ 这两格很可能是"域没真上电"的另一半。
        .{ .name = "lpcon+1C_fo", .addr = 0x2010_F01C },
        .{ .name = "lpcon+20_icg", .addr = 0x2010_F020 },
        .{ .name = "hp1e0_socpll", .addr = 0x2058_71E0 },
        // MAC 块窗口（IDF `before_init` 里 `m10 = 0xf7c40000`，其余为 0——与我们对照）
        .{ .name = "mac_c00", .addr = 0x2010_4C00 },
        .{ .name = "mac_c10", .addr = 0x2010_4C10 },
    };
    log.line("wifi-init-probe: CLKDMP[{s}]", .{tag});
    for (regs) |r| {
        const v: *volatile u32 = @ptrFromInt(r.addr);
        log.line("wifi-init-probe:   {s}=0x{x:0>8}", .{ r.name, v.* });
    }
}

// ---------------------------------------------------------------------------
// 全量寄存器 dump（2026-11-25）：与官方 IDF 的 oracle（`tools/wifi-idf-oracle/`，打开
// `CONFIG_ORACLE_REGDUMP`）在**同一个时点**各读一遍、程序化做差。地址表由 SoC 头文件里
// 定义过的寄存器生成（只读，不盲读未映射地址），与 oracle 的 `regdump_addrs.h` 是同一份。
// 之前只对照过 11 个时钟寄存器 + MAC 块校验和 + hp1e0，全部相同；这张表把 PMU、LP 系统、
// HP 系统时钟、低功耗模拟等一并纳入。
// ---------------------------------------------------------------------------
const regdump_addrs = [_]u32{
    0x20109400, 0x20109404, 0x20109408, 0x2010940C, 0x20109C00, 0x20109C04, 0x20109C08, 0x20109C0C,
    0x20109C10, 0x20109C14, 0x20109C18, 0x20109C1C, 0x20109C20, 0x20109C24, 0x20109C28, 0x20109C2C,
    0x20109C30, 0x2010F000, 0x2010F004, 0x2010F008, 0x2010F00C, 0x2010F010, 0x2010F014, 0x2010F018,
    0x2010F01C, 0x2010F020, 0x2010F024, 0x2010F028, 0x2010F02C, 0x2010F030, 0x2010F034, 0x2010F038,
    0x2010F03C, 0x2010F040, 0x2010F044, 0x2010F048, 0x2010F04C, 0x2010F050, 0x2010F054, 0x2010F058,
    0x2010F800, 0x2010F804, 0x2010F808, 0x2010F80C, 0x2010F810, 0x2010F814, 0x2010F818, 0x2010F81C,
    0x2010F820, 0x2010F824, 0x2010F828, 0x2010F82C, 0x2010F830, 0x2010F834, 0x2010F838, 0x2010F83C,
    0x20587000, 0x20587004, 0x20587008, 0x2058700C, 0x20587010, 0x20587014, 0x20587018, 0x2058701C,
    0x20587020, 0x20587024, 0x20587028, 0x2058702C, 0x20587030, 0x20587034, 0x20587038, 0x2058703C,
    0x20587040, 0x20587044, 0x20587048, 0x2058704C, 0x20587050, 0x20587054, 0x20587058, 0x2058705C,
    0x20587060, 0x20587064, 0x20587068, 0x2058706C, 0x20587070, 0x20587074, 0x20587078, 0x2058707C,
    0x20587080, 0x20587084, 0x20587088, 0x2058708C, 0x20587090, 0x20587094, 0x20587098, 0x2058709C,
    0x205870A0, 0x205870A4, 0x205870A8, 0x205870AC, 0x205870B0, 0x205870B4, 0x205870B8, 0x205870BC,
    0x205870C0, 0x205870C4, 0x205870C8, 0x205870CC, 0x205870D0, 0x205870D4, 0x205870D8, 0x205870DC,
    0x205870E0, 0x205870E4, 0x205870E8, 0x205870EC, 0x205870F0, 0x205870F4, 0x205870F8, 0x205870FC,
    0x20587100, 0x20587104, 0x20587108, 0x2058710C, 0x20587110, 0x20587114, 0x20587118, 0x2058711C,
    0x20587120, 0x20587124, 0x20587128, 0x2058712C, 0x20587130, 0x20587134, 0x20587138, 0x20587144,
    0x20587148, 0x2058714C, 0x20587150, 0x20587154, 0x20587158, 0x2058715C, 0x20587160, 0x20587164,
    0x20587168, 0x2058716C, 0x20587170, 0x20587174, 0x20587178, 0x2058717C, 0x20587180, 0x20587184,
    0x20587188, 0x2058718C, 0x20587190, 0x20587194, 0x20587198, 0x2058719C, 0x205871A0, 0x205871A4,
    0x205871A8, 0x205871AC, 0x205871B0, 0x205871B4, 0x205871B8, 0x205871BC, 0x205871C8, 0x205871CC,
    0x205871D0, 0x205871D4, 0x205871D8, 0x205871DC, 0x205871E0, 0x205871F8, 0x205871FC, 0x20589000,
    0x20589004, 0x20589008, 0x2058900C, 0x20589010, 0x20589014, 0x20589018, 0x2058901C, 0x20589020,
    0x20589024, 0x20589028, 0x2058902C, 0x20589030, 0x20589034, 0x20589038, 0x20589040, 0x20589044,
    0x20589048, 0x2058907C, 0x20589080, 0x20589084, 0x20589088, 0x2058908C, 0x20589090, 0x20589094,
    0x20589098, 0x2058909C, 0x205890A0, 0x205890A4, 0x205890A8, 0x205890AC, 0x205890B0, 0x205893FC,
    0x20700000, 0x20700004, 0x20700008, 0x2070000C, 0x20700018, 0x2070001C, 0x20700020, 0x20700024,
    0x20700028, 0x2070002C, 0x20700030, 0x20700034, 0x20700038, 0x2070003C, 0x20700040, 0x20700044,
    0x20700048, 0x2070004C, 0x20700050, 0x20700054, 0x20700058, 0x2070005C, 0x20700060, 0x20700064,
    0x20700068, 0x2070006C, 0x20700070, 0x20700074, 0x2070009C, 0x20700100, 0x2070010C, 0x20700110,
    0x20700114, 0x20700118, 0x2070011C, 0x20700120, 0x20700124, 0x20700130, 0x20700138, 0x2070013C,
    0x20700154, 0x20700158, 0x2070015C, 0x20700164, 0x20700170, 0x20700174, 0x20700178, 0x2070017C,
    0x20700180, 0x20700190, 0x20700194, 0x207001A0, 0x207001A4, 0x207001B4, 0x207001B8, 0x207001BC,
    0x207001C0, 0x207001C4, 0x207001E8, 0x207001EC, 0x207001F0, 0x207001F8, 0x207001FC, 0x20700200,
    0x20700204, 0x20700208, 0x20700218, 0x2070021C, 0x20700220, 0x20700224, 0x20700228, 0x2070022C,
    0x20700230, 0x20700234, 0x20700238, 0x2070023C, 0x20700270, 0x20700274, 0x20701000, 0x20701004,
    0x20701008, 0x2070100C, 0x20701010, 0x20701014, 0x20701018, 0x2070101C, 0x20701020, 0x20701024,
    0x20701028, 0x2070102C, 0x20701030, 0x20701034, 0x20701038, 0x2070103C, 0x20701040, 0x20701044,
    0x20701048, 0x2070104C, 0x20701050, 0x20701054, 0x20701058, 0x2070105C, 0x20701060, 0x20701064,
    0x20701068, 0x207013FC, 0x20702000, 0x20702004, 0x20702008, 0x20702018, 0x2070201C, 0x20702020,
    0x20702024, 0x20702028, 0x2070202C, 0x20702030, 0x20702034, 0x20702038, 0x2070203C, 0x207023FC,
    0x20704000, 0x20704004, 0x20704008, 0x2070400C, 0x20704010, 0x20704014, 0x20704018, 0x2070401C,
    0x20704020, 0x20704024, 0x20704028, 0x2070402C, 0x20704030, 0x20704034, 0x20704038, 0x2070403C,
    0x20704040, 0x20704044, 0x20704048, 0x2070404C, 0x20704050, 0x20704054, 0x20704058, 0x2070405C,
    0x20704060, 0x20704064, 0x20704068, 0x2070406C, 0x20704070, 0x20704074, 0x20704078, 0x2070407C,
    0x20704080, 0x20704084, 0x20704088, 0x2070408C, 0x20704090, 0x20704094, 0x20704098, 0x2070409C,
    0x207040A0, 0x207040A4, 0x207040A8, 0x207040AC, 0x207040B0, 0x207040B4, 0x207040B8, 0x207040BC,
    0x207040C0, 0x207040C4, 0x207040CC, 0x207040D0, 0x207040D8, 0x207040DC, 0x207040E0, 0x207040E4,
    0x207040E8, 0x207040EC, 0x207040F0, 0x207040F4, 0x207040F8, 0x207040FC, 0x20704100, 0x20704104,
    0x20704108, 0x2070410C, 0x20704110, 0x20704114, 0x20704118, 0x2070411C, 0x20704120, 0x20704124,
    0x20704128, 0x2070412C, 0x20704130, 0x20704134, 0x20704138, 0x2070413C, 0x20704140, 0x20704144,
    0x20704148, 0x2070414C, 0x20704150, 0x20704154, 0x20704158, 0x2070415C, 0x20704160, 0x20704164,
    0x20704168, 0x2070416C, 0x20704170, 0x20704174, 0x20704178, 0x2070417C, 0x20704180, 0x20704184,
    0x20704188, 0x2070418C, 0x20704190, 0x20704194, 0x20704198, 0x2070419C, 0x207041A0, 0x207041A4,
    0x207041A8, 0x207041AC, 0x207041B0, 0x207041B4, 0x207041B8, 0x207041BC, 0x207041C0, 0x207041C4,
    0x207041C8, 0x207041CC, 0x207041D0, 0x207041D4, 0x207041D8, 0x207041DC, 0x207041E0, 0x207041E4,
    0x207041E8, 0x207041EC, 0x207041F0, 0x207041F4, 0x207041F8, 0x207041FC, 0x20704200, 0x20704204,
    0x20704208, 0x2070420C, 0x20704210, 0x20704214, 0x20704218, 0x2070421C, 0x20704220, 0x20704224,
    0x207043FC, 0x20706000, 0x20706004, 0x20706008, 0x2070600C, 0x20706010, 0x20706014, 0x20706018,
    0x2070601C, 0x20706020, 0x20706024, 0x20706028, 0x2070602C, 0x20706030, 0x20706034, 0x20706038,
    0x2070603C, 0x20706040, 0x20706044, 0x20706048, 0x2070604C, 0x20706050, 0x20706054, 0x20706058,
    0x2070605C, 0x20706060, 0x20706064, 0x20706068, 0x2070606C, 0x20706070, 0x20706200, 0x20706204,
    0x20706208, 0x2070620C, 0x20706300, 0x207067F0, 0x207067F8, 0x207067FC, 0x20710004, 0x20710008,
    0x2071000C, 0x20710010, 0x20710014, 0x20710018, 0x2071001C, 0x20710020, 0x20710024, 0x20710028,
    0x2071002C, 0x20710030, 0x20710034, 0x20710038, 0x2071003C, 0x20710040, 0x20710044, 0x20710048,
    0x2071004C, 0x20710050, 0x207103FC,
};

/// 全量寄存器 dump（523 个有定义的寄存器）。真实链路探针用它做与 oracle 的同点对照。
pub fn regDumpAll(tag: []const u8) void {
    const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
    log.line("REGDUMP {s} begin n={d} mac_st={x:0>8}", .{ tag, regdump_addrs.len, mac_st.* });
    for (regdump_addrs, 0..) |a, i| {
        const p: *volatile u32 = @ptrFromInt(a);
        log.line("REG {d} {x:0>8} {x:0>8}", .{ i, a, p.* });
    }
    log.line("REGDUMP {s} end", .{tag});
}

/// MAC 块整段（0x20104000 起 4 KB，blob 私有，不在头文件里），与 oracle 的 `macdump` 同点对照。
/// 扫描是驱动直接往这里写出来的；只读，个别读清位会被读掉，只用于诊断。
pub fn macDumpAll(tag: []const u8) void {
    log.line("MACDUMP {s} begin n={d} base={x:0>8}", .{ tag, 1024, @as(u32, 0x2010_4000) });
    for (0..1024) |i| {
        const a: usize = 0x2010_4000 + 4 * i;
        const p: *volatile u32 = @ptrFromInt(a);
        log.line("MACW {d} {x:0>8} {x:0>8}", .{ i, a, p.* });
    }
    log.line("MACDUMP {s} end", .{tag});
}

/// 不在头文件里的几块，与 oracle 的 `rangdump_all` 同点对照。只读头文件里给了基址的那几块，各按 1 KB
/// （WIDGETS 2 KB）算。**FE 只到 0x20101FFF**：0x20102000 起读不到——本镜像在那里读一次就挂死
/// （2026-11-26 两次 dump 都停在第 2048 个字）；0x20103000 是 IEEE 802.15.4 的块，中间是空的。
/// 每行 8 个字（`RG <地址> <8 个值>`），全打不做过滤。只读，只用于诊断。
pub fn rangeDumpAll() void {
    rangeDump("fe", 0x2010_0000, 2048, false);
    rangeDump("bb", 0x2010_7000, 1024, false);
    rangeDump("brx", 0x2010_8000, 256, false);
    rangeDump("timer", 0x2010_8400, 256, false);
    rangeDump("etm", 0x2010_8800, 256, false);
    rangeDump("dump", 0x2010_9000, 256, false);
    rangeDump("wgt", 0x2010_9400, 512, false);
    // 0x2010D000 起这一块头文件里没有名字，范围是猜的：读每一行之前先把地址打出去，挂死也能知道挂在哪。
    rangeDump("pwr0", 0x2010_D000, 512, true);
    rangeDump("pwr8", 0x2010_D800, 64, true);
}

fn rangeDump(name: []const u8, base: usize, n: usize, guarded: bool) void {
    log.line("RANGEDUMP {s} begin base={x:0>8} n={d}", .{ name, @as(u32, @intCast(base)), n });
    var i: usize = 0;
    while (i < n) : (i += 8) {
        const first: u32 = @intCast(base + 4 * i);
        if (guarded) log.line("RANGEAT {x:0>8}", .{first});
        var buf: [88]u8 = undefined;
        var w = (std.fmt.bufPrint(&buf, "RG {x:0>8}", .{first}) catch unreachable).len;
        var j: usize = 0;
        while (j < 8 and i + j < n) : (j += 1) {
            w += (std.fmt.bufPrint(buf[w..], " {x:0>8}", .{hw.readReg(base + 4 * (i + j))}) catch unreachable).len;
        }
        log.line("{s}", .{buf[0..w]});
    }
    log.line("RANGEDUMP {s} end", .{name});
}

/// 定点采样：全量对照里出现过差异的那几十个地址，一个一行（`FOCUS <地址> <值>`），与 oracle 的
/// `focusdump` 同一张地址表。放在扫描开始后 100 ms、所有慢 dump **之前**打：全量 dump 要十几秒，
/// 对照镜像那边不打断扫描，等 dump 走到 BB 块时扫描已经结束、驱动已把 FE/BB 时钟收起来——
/// 那是空闲态，不是收发态（2026-11-26 的 scan8 就是这么比错的）。
const focus_addrs = [_]usize{
    0x2010_7000, 0x2010_7030, 0x2010_704C, 0x2010_7050, 0x2010_706C, 0x2010_7078, 0x2010_708C, 0x2010_7128,
    0x2010_7138, 0x2010_71D4, 0x2010_740C, 0x2010_7438, 0x2010_7848, 0x2010_785C, 0x2010_7888, 0x2010_78A8,
    0x2010_78AC, 0x2010_78B8, 0x2010_78BC, 0x2010_78C0, 0x2010_78C4, 0x2010_78D0, 0x2010_7C08, 0x2010_7C60,
    0x2010_7C64, 0x2010_7C80, 0x2010_7C90, 0x2010_7CB0, 0x2010_7FFC, 0x2010_8038, 0x2010_803C, 0x2010_8044,
    0x2010_8048, 0x2010_8094, 0x2010_D800, 0x2010_D878, 0x2010_001C, 0x2010_0050, 0x2010_0400, 0x2010_0438,
    0x2010_0450, 0x2010_0800, 0x2010_081C, 0x2010_0820, 0x2010_0830, 0x2010_0848, 0x2010_084C, 0x2010_0850,
    0x2010_0890, 0x2010_0894, 0x2010_0898, 0x2010_089C, 0x2010_08A0, 0x2010_08A4, 0x2010_1FFC,
};

pub fn focusDump(tag: []const u8) void {
    log.line("FOCUSDUMP {s} begin n={d}", .{ tag, focus_addrs.len });
    for (focus_addrs) |a| {
        log.line("FOCUS {x:0>8} {x:0>8}", .{ @as(u32, @intCast(a)), hw.readReg(a) });
    }
    log.line("FOCUSDUMP {s} end", .{tag});
}

/// 真实链路探针（`link_probe.zig`）把它接成长期运行的泵：不打每 1000 次那行日志，
/// 也不在 400 万次让出后停机。
pub var idle_quiet: bool = false;
/// 阻塞等待的让出点。从主上下文调用 = 把 Wi-Fi 任务推进一步，任务让出后返回。
pub fn idleHook() void {
    idle_calls += 1;
    if (foreign_context) {
        foreign_refusals += 1;
        return;
    }
    // **"真阻塞 + 泵 PP worker"实验已做**：init 直接挂住（PP 任务始终没 give）。
    // ⇒ PP worker 在我们的环境里跑不到它的 `give`。已回滚。
    if (idle_calls == 1) log.raw("wifi-init-probe: task blocked -> yielded to idle hook\n");
    // 每 1000 次让出打一行：区分"在乒乓（任务没答话）"与"blob 忙等（根本不进钩子）"。
    if (!idle_quiet and idle_calls % 1000 == 0) {
        var e0: usize = 0;
        var e1: usize = 0;
        if (impl.task_count > 0) if (impl.tasks[0].entry) |e| {
            e0 = @intFromPtr(e);
        };
        if (impl.task_count > 1) if (impl.tasks[1].entry) |e| {
            e1 = @intFromPtr(e);
        };
        log.line("wifi-init-probe: idle_calls={d} in_task={} hooks={d} tasks={d} e0=0x{x} e1=0x{x}", .{
            idle_calls,
            in_task,
            impl.event_count,
            impl.task_count,
            e0,
            e1,
        });
    }
    if (!idle_quiet and idle_calls > 4_000_000) {
        log.line("wifi-init-probe: idle budget exhausted ({d}), halting", .{idle_calls});
        hw.halt();
    }
    // **任务侧让出**：被泵的任务在自己的阻塞点进到这里 ⇒ 切回主上下文（RTOS 式 block）。
    if (in_task) {
        if (cur_task) |t| {
            in_task = false;
            impl.current_is_task = false;
            sched.swapContext(&t.ctx, &main_ctx);
            in_task = true;
            impl.current_is_task = true;
        } else {
            // 回退：走的是旧的 `task_ctx`（`pump round` 那条路径，没经过 `pumpRealTask`），
            // 必须照旧切回主上下文——否则任务在 `on_idle` 里空转、主上下文永远回不去。
            in_task = false;
            impl.current_is_task = false;
            sched.swapContext(&task_ctx, &main_ctx);
            in_task = true;
            impl.current_is_task = true;
        }
        return;
    }
    // **泵真实任务**：init 期间 `task_ctx_ready` 还是 false，但 `_task_create` 已经登记了任务
    // （含 PP 任务）。`take`/`recv` 的阻塞循环会进这里 ⇒ 切到任务跑一轮，它 give 之后 take 就能返回。
    if (!in_task) {
        const pumped = pumpRealTask();
        if (pumped and pump_logs < 8) {
            pump_logs += 1;
            // 标签用 `semmax`：那个数是 `_semphr_create` 的 **max 参数**（`0x00010000`），不是调用计数。
            log.line("wifi-init-probe: pump#{d} hooks={d} give={d} null_give={d} semmax=0x{x}", .{
                pump_logs, impl.event_count, impl.give_total, impl.null_give, impl.sem_create_args[0],
            });
        }
        if (pumped) return;
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
/// 已打印的 trace 行数（上限 200）。真实链路探针在扫描之前把它清零，让那一段也能被追踪。
pub var trace_lines: u32 = 0;

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
/// 基址：eFuse 的工厂 MAC（IDF `esp_efuse_mac_get_default`）。48 位字段 = `EFUSE_RD_MAC_SYS1`（`0x20715054`）
/// 的低 16 位拼上 `EFUSE_RD_MAC_SYS0`（`0x20715050`），按大端逐字节（`esp_efuse_read_field_blob` 的口径：
/// `mac[0]` 是最高字节；实测按小端读出来是 `28:99:d1:04:29:1c`，反着才对）。
/// 此前这里写死占位地址 `02:00:00:00:00:01`，探针日志里 station 用的一直是它。
fn macHook() [6]u8 {
    const lo = hw.readReg(0x2071_5050);
    const hi = hw.readReg(0x2071_5054);
    return .{
        @truncate(hi >> 8),  @truncate(hi),
        @truncate(lo >> 24), @truncate(lo >> 16),
        @truncate(lo >> 8),  @truncate(lo),
    };
}

/// C shim 的回调：把 blob 自己的日志整行打到串口（变参已在 `printf_shim.c` 里展开）。
pub export fn s31_printf_hook(msg: ?[*:0]const u8) void {
    const m = msg orelse return;
    log.line("wifi-blob: {s}", .{std.mem.span(m)});
}

// ---------------------------------------------------------------------------
// `-Dcoex`：共存核在 Wi-Fi 探针里的接线。关着时 `coexBoot`/`coexReport` 没有调用点，整段不生成代码。
// ---------------------------------------------------------------------------
const coex_gate = @import("coex_gate");
const coex_hooks = @import("coex_hooks.zig");
const radio_coex = if (coex_gate.enabled) @import("radio_coex") else struct {};
const on_target = @import("builtin").os.tag == .freestanding;

/// ROM 槽位（`boards/esp32s31-coreboard/linker/rom_syms.ld`）：核把参数块的指针存在
/// `g_coex_param_ptr`，把它收下的适配表指针存在 `g_coa_funcs_p`。
extern var g_coex_param_ptr: usize;
extern var g_coa_funcs_p: usize;

/// `components/radio-coex/link/coex_printf_shim.c` 的出口（共存库的日志整行）。只在 `-Dcoex` 时发射。
const CoexExports = struct {
    export fn s31_coex_log_hook(msg: [*:0]const u8) callconv(.c) void {
        log.line("coex> {s}", .{std.mem.span(msg)});
    }
};
comptime {
    if (coex_gate.enabled) _ = CoexExports;
}

/// "当前是否在中断上下文"：`mstatus.MIE == 0`。trap 入口由硬件清 MIE，临界区也清 MIE——
/// 那种情况按"在中断里"作答是安全的一侧（核走不睡眠的 ISR 分支）。
fn coexInIsr() bool {
    if (!on_target) return false;
    const mstatus: usize = asm volatile ("csrr %[v], mstatus"
        : [v] "=r" (-> usize),
    );
    return (mstatus & 0x8) == 0;
}

/// 启动共存核（IDF 的 `init_coexist`：系统初始化 SECONDARY 级，早于 `app_main`）。
///
/// 真正做初始化的是它调的 `coex_pre_init`（`coex_core_pre_init`：方案表、ROM 版本打印、把参数块的
/// 指针写进 `g_coex_param_ptr`、硬件定时器分频）；`coex_init`（`coex_core_init`）在核里是 `li a0,0; ret`。
/// 所以板上判据（参数指针非零、版本行）看的是这一步。必须在 arena 与时基钩子就位之后
/// （核会建信号量、读时间），在 `esp_wifi_init_internal` 之前。
fn coexBoot() void {
    if (!on_target) return;
    coex_hooks.in_isr_hook = coexInIsr;
    // `-Dcoex-sw-off`：胶水照常链着，但按 IDF 关闭分支的桩值作答，`boot()` 被拒、核不启动。关掉 `-Dcoex` 会同时把钩子
    // 换成计数桩（它们回的值与 IDF 关闭分支不一样），这个开关把"核不启动"单独拿出来做对照。
    const cfg: radio_coex.Config = if (coex_gate.sw_off) .{ .sw_coexist = false } else .{};
    radio_coex.bind.boot(coex_hooks.hooks(), cfg) catch |e| {
        const g = radio_coex.instance();
        const rc: u32 = @bitCast(g.last_core_rc);
        const rej = g.rejected[@backingInt(radio_coex.Hook.boot)];
        log.line("coex[boot]: FAILED {s} rc=0x{x} rejected={d}", .{ @errorName(e), rc, rej });
        return;
    };
    coexReport("boot");
    radio_coex.instance().on_enter = &coexTrace;
    radio_coex.instance().on_leave = &coexTraceLeave;
}

/// `-Dcoex`：共存核的钩子被 blob 调到时的**即时**痕迹。`esp_wifi_start` 卡在 MAC 忙位时不返回，
/// 事后的诊断行打不出来；`_coex_enable` 这条路径到底有没有被 blob 执行，只能靠入口处的这一行作证。
pub var coex_trace_all: bool = false;

fn coexTrace(h: radio_coex.Hook) void {
    if (coex_trace_all) {
        log.raw("coex> ");
        log.line("{s} called by blob", .{radio_coex.hookName(h)});
        return;
    }
    switch (h) {
        .coex_enable_wrapper => log.raw("coex> _coex_enable called by blob\n"),
        .coex_disable_wrapper => log.raw("coex> _coex_disable called by blob\n"),
        .coex_wifi_request_wrapper => log.raw("coex> _coex_wifi_request called by blob\n"),
        .coex_wifi_release_wrapper => log.raw("coex> _coex_wifi_release called by blob\n"),
        else => {},
    }
}

/// `_coex_enable` / `_coex_disable` 返回时的那一行：返回码，加上返回**之后**两侧的状态。
/// 入口行只证明"blob 调了"，这一行才证明"核心收下了"（rc=0 且 Wi-Fi 侧变成 enabled）。
fn coexTraceLeave(h: radio_coex.Hook, rc: c_int) void {
    switch (h) {
        .coex_enable_wrapper, .coex_disable_wrapper => log.line("coex> {s} returned rc={d} wifi={s} ble={s} rej={d}", .{
            radio_coex.hookName(h), rc, @tagName(coexSide(.wifi)), @tagName(coexSide(.ble)), coexRejected(),
        }),
        else => {},
    }
}

/// 诊断行（两行）。`coa` 应等于 `table`：那就是"核心收下了我们的适配表"。
pub fn coexReport(stage: []const u8) void {
    if (!on_target) return;
    const g = radio_coex.instance();
    const fw: [*:0]const u8 = if (g.core.version_get) |f| (f() orelse "?") else "?";
    var rej: u32 = 0;
    for (g.rejected) |r| rej += r;
    log.line("coex[{s}]: booted={} wifi={s} ble={s} param=0x{x:0>8} coa=0x{x:0>8} table=0x{x:0>8} rej={d}", .{ stage, g.state.booted, @tagName(g.state.wifi), @tagName(g.state.ble), g_coex_param_ptr, g_coa_funcs_p, @intFromPtr(radio_coex.adapterTable()), rej });
    log.line("coex[{s}]: fw={s} en={d} req={d} rel={d} sta={d} startcb={d} intset={d}", .{ stage, std.mem.span(fw), radio_coex.calls(.coex_enable_wrapper), radio_coex.calls(.coex_wifi_request_wrapper), radio_coex.calls(.coex_wifi_release_wrapper), radio_coex.calls(.coex_status_get_wrapper), radio_coex.calls(.coex_register_start_cb_wrapper), radio_coex.calls(.coex_schm_interval_set_wrapper) });
}

/// `-Dcoex`：探针表里的五个表项再包一层，只为把 blob 交给共存核的东西记下来——照旧转给胶水的
/// 包装函数，行为不变。胶水自己只计"blob 调了几次"；这里记的是**核怎么答的**：申请的返回码、
/// 给每个事件的优先级（PTI）、置 / 清的是哪些 Wi-Fi 状态位。真实链路各阶段的读数见 `coexReadings`。
const CoexTraceStats = struct {
    /// 一个事件号（`coex_event_t`）上 blob 交给核的三样：申请、释放、查 PTI，各带"核回错"的次数。
    /// 核只给少数事件配了硬件定时器（`coex_core_request` / `coex_core_release` 里 `coex_core_timer_idx_get`
    /// 回 255 的），其余事件的申请与释放核一律回 0x102（`ESP_ERR_INVALID_ARG`）——那是核里的静态表，
    /// 不是胶水出错，所以"回错"要按事件分开看。
    const Ev = struct {
        req: u32 = 0,
        req_bad: u32 = 0,
        rel: u32 = 0,
        rel_bad: u32 = 0,
        /// 查 PTI：次数、核回错的次数、见过的 PTI 值按位或。
        pti_n: u32 = 0,
        pti_bad: u32 = 0,
        pti_mask: u8 = 0,
        /// 每个 PTI 值（0..15，核回 0 的那些）各查到几次。只记按位或的话，BLE 广播前后分布变了也看不出来。
        pti_hist: [16]u32 = @splat(0),
        /// 核接受申请（回 0）之后读到的定时器使能位（`hwTimerEnableMask`）：接受了几次、其中几次有定时器使能着、见过哪几个。
        armed_n: u32 = 0,
        armed_on: u32 = 0,
        armed_mask: u8 = 0,
        armed_at_us: ?u64 = null,
        /// 核接受申请之后定时器的状态位（`0x2010F40C + 16*idx` 的 bit0）按位或，与核装进这个事件的定时器的 tick 数
        /// （配置字 w0 的低 24 位）的最近一次读数。
        armed_status: u8 = 0,
        armed_ticks: u32 = 0,
        /// 已经为这个事件打过几行定时器的原始字（至多 3 行）。
        logged: u32 = 0,
        /// 核接受释放（回 0）的次数，与其中释放之前使能位还置着的次数。
        rel_ok: u32 = 0,
        rel_on: u32 = 0,
        /// 核接受释放之前定时器的状态位按位或，与其中有状态位置着的次数。
        rel_status: u8 = 0,
        rel_status_n: u32 = 0,
        /// 从接受申请到释放：几段、最短、最长、累计（微秒）。
        held_n: u32 = 0,
        held_min_us: u32 = std.math.maxInt(u32),
        held_max_us: u32 = 0,
        held_sum_us: u64 = 0,
    };
    ev: [64]Ev = @splat(.{}),
    /// 64 及以上的事件号出现的总次数。
    ev_big: u32 = 0,
    /// `_coex_schm_status_bit_set` / `_clear`：blob 经这两项告诉核"Wi-Fi 现在在干什么"。
    set_n: u32 = 0,
    set_type: u32 = 0,
    set_mask: u32 = 0,
    set_last: u32 = 0,
    clr_n: u32 = 0,
    clr_mask: u32 = 0,

    fn of(self: *CoexTraceStats, event: u32) ?*Ev {
        if (event >= self.ev.len) {
            self.ev_big += 1;
            return null;
        }
        return &self.ev[@intCast(event)];
    }
};
var coex_trace_stats: CoexTraceStats = .{};
fn coexWifiRequestTraced(event: u32, latency: u32, duration: u32) callconv(.c) c_int {
    const rc = radio_coex.wifi.coex_wifi_request_wrapper(event, latency, duration);
    if (coex_trace_stats.of(event)) |e| {
        e.req += 1;
        if (rc != 0) e.req_bad += 1 else {
            // 核接受了：按它的代码（`coex_core_request`），配了定时器的事件这时已经 `coex_hw_timer_set` 加 `coex_hw_timer_enable`。
            const timers = hwTimerEnableMask();
            e.armed_n += 1;
            e.armed_status |= hwTimerStatusMask();
            e.armed_at_us = hw.nowUs();
            if (timers != 0) {
                e.armed_on += 1;
                e.armed_mask |= timers;
            }
            if (timerOf(event)) |idx| {
                e.armed_ticks = hw.readReg(0x2010_F400 + 16 * idx) & 0xFFFFFF;
                // 头三次各打一行定时器的 4 个字：核装进去的是什么，使能字与状态字读回来是什么。
                if (e.logged < 3) {
                    e.logged += 1;
                    logTimerBlock(event, idx);
                }
            }
        }
    }
    // 一轮十来次，逐次打：时延、时长是 blob 向核申请的量，后面是核的答复。
    log.line("coex> _coex_wifi_request event={d} latency={d} duration={d} -> rc={d}", .{ event, latency, duration, rc });
    return rc;
}
fn coexWifiReleaseTraced(event: u32) callconv(.c) c_int {
    // 释放之前先读定时器的使能字与状态字：核在 `coex_core_release` → `coex_hw_timer_disable` 里才关定时器、清状态字的 bit0。
    const before = hwTimerEnableMask();
    const status_before = hwTimerStatusMask();
    const t_rel = hw.nowUs();
    const rc = radio_coex.wifi.coex_wifi_release_wrapper(event);
    if (coex_trace_stats.of(event)) |e| {
        e.rel += 1;
        if (rc != 0) e.rel_bad += 1 else {
            e.rel_ok += 1;
            if (before != 0) e.rel_on += 1;
            e.rel_status |= status_before;
            if (status_before != 0) e.rel_status_n += 1;
            if (e.armed_at_us) |t0| {
                const us: u32 = @intCast(@min(t_rel -% t0, std.math.maxInt(u32)));
                e.held_n += 1;
                if (us < e.held_min_us) e.held_min_us = us;
                if (us > e.held_max_us) e.held_max_us = us;
                e.held_sum_us += us;
                e.armed_at_us = null;
            }
        }
    }
    return rc;
}

fn coexPtiGetTraced(event: u32, pti: ?*u8) callconv(.c) c_int {
    const rc = radio_coex.wifi.coex_pti_get_wrapper(event, pti);
    if (coex_trace_stats.of(event)) |e| {
        e.pti_n += 1;
        if (rc != 0) e.pti_bad += 1;
        if (pti) |p| e.pti_mask |= p.*;
        if (rc == 0) if (pti) |p| {
            if (p.* < 16) e.pti_hist[p.*] += 1;
        };
    }
    return rc;
}

/// 核的 5 个硬件定时器的使能位拼成一个位图：bit idx = 第 idx 个使能着。`coexist_hw.o` 的反汇编：每个定时器 16 个字节，
/// 在 `0x2010F400 + 16*idx`——`+0`、`+4` 是 `coex_hw_timer_set` 写的两个配置字，`+8` 是使能字（`coex_hw_timer_enable`
/// 置它的 **bit0**，`coex_hw_timer_disable` 清它），`+0xC` 是状态字（disable 往它的 bit0 写 1）。
fn hwTimerEnableMask() u8 {
    var m: u8 = 0;
    for (0..5) |idx| {
        const en: u32 = hw.readReg(0x2010_F408 + 16 * idx);
        if (en & 1 != 0) m |= @as(u8, 1) << @intCast(idx);
    }
    return m;
}

/// 核的 5 个硬件定时器的状态位（`0x2010F40C + 16*idx` 的 bit0）拼成一个位图。板上读到的是：核接受申请之后这个位清着、
/// bit1 置着（`coex_hw_timer_enable` 清 bit0 再置使能字的 bit0，而使能字的 bit0 读回来就是 0）——这些位各是什么含义没有弄清
/// （`coex-verification.md` §19）。
fn hwTimerStatusMask() u8 {
    var m: u8 = 0;
    for (0..5) |idx| {
        const st: u32 = hw.readReg(0x2010F40C + 16 * idx);
        if (st & 1 != 0) m |= @as(u8, 1) << @intCast(idx);
    }
    return m;
}

/// 核的事件表（`coexist_core.o` 的 `.rodata.CSWTCH.28`，下标是事件号减一）里配了硬件定时器的事件：事件号 → 定时器号；其余没有。
fn timerOf(event: u32) ?u32 {
    return switch (event) {
        1 => 0,
        2 => 1,
        36 => 4,
        38 => 2,
        45, 46 => 3,
        else => null,
    };
}

/// 第 idx 个定时器的 4 个字。
fn logTimerBlock(event: u32, idx: u32) void {
    const base = 0x2010_F400 + 16 * idx;
    log.line("coex> timer after the accepted request: e{d} -> timer {d}: w0=0x{x:0>8} w1=0x{x:0>8} en=0x{x:0>8} st=0x{x:0>8}", .{ event, idx, hw.readReg(base), hw.readReg(base + 4), hw.readReg(base + 8), hw.readReg(base + 12) });
}

/// 当前的栈指针（读数用：这一段代码跑在哪根栈上）。
inline fn spNow() usize {
    var sp: usize = undefined;
    asm volatile ("mv %[out], sp"
        : [out] "=r" (sp),
    );
    return sp;
}

fn coexStatusBitSetTraced(st_type: u32, status: u32) callconv(.c) void {
    radio_coex.wifi.coex_schm_status_bit_set_wrapper(st_type, status);
    coex_trace_stats.set_n += 1;
    coex_trace_stats.set_type = st_type;
    coex_trace_stats.set_mask |= status;
    coex_trace_stats.set_last = status;
}

fn coexStatusBitClearTraced(st_type: u32, status: u32) callconv(.c) void {
    radio_coex.wifi.coex_schm_status_bit_clear_wrapper(st_type, status);
    coex_trace_stats.clr_n += 1;
    coex_trace_stats.clr_mask |= status;
}

/// 把上面五项装进探针的 osi 表（在 `radio_coex.wifi.fill` 之后）。
fn coexTraceTable(table: anytype) void {
    table._coex_wifi_request = @ptrCast(&coexWifiRequestTraced);
    table._coex_wifi_release = @ptrCast(&coexWifiReleaseTraced);
    table._coex_pti_get = @ptrCast(&coexPtiGetTraced);
    table._coex_schm_status_bit_set = @ptrCast(&coexStatusBitSetTraced);
    table._coex_schm_status_bit_clear = @ptrCast(&coexStatusBitClearTraced);
}

/// 一行装不下的列表分几行打。日志一行上限 200 字节，前面还有 `coex[阶段]: 标签:`，所以正文留 140 字节
/// （2026-11-26 第一次上板时按 200 算，阶段名一长，后几个阶段的三行都被整行截断）。
const text_budget: usize = 140;

fn flushLine(stage: []const u8, tag: []const u8, text: []const u8) void {
    if (text.len == 0) return;
    log.line("coex[{s}]: {s}:{s}", .{ stage, tag, text });
}

/// 往分页的一行里追加一项：正文超过 `text_budget` 就先把已有的打出去。
fn appendItem(stage: []const u8, tag: []const u8, line: []u8, used: *usize, text: []const u8) void {
    if (used.* + text.len > text_budget) {
        flushLine(stage, tag, line[0..used.*]);
        used.* = 0;
    }
    @memcpy(line[used.*..][0..text.len], text);
    used.* += text.len;
}

/// 真实链路各阶段的共存读数（L4，`-Dcoex`）。`coexReport` 的两行之外再看四样：
///
///   * blob 经胶水调核的次数，按钩子全列（`coexReport` 只挑了 6 个）——连接、收发这一路 blob 到底
///     用了共存核的哪些入口，各阶段的差值就是这一阶段用了多少；
///   * blob 交给核的东西与核的答复（`CoexTraceStats`）：申请的时延 / 时长与返回码、按事件的 PTI、
///     置 / 清的状态位；
///   * 核手里的当前值：Wi-Fi 状态位、调度间隔 / 周期 / 相位；
///   * 共存的低功耗时钟配置 `MODEM_LPCON_COEX_LP_CLK_CONF`（`0x2010F008`：位 [15:4] 是分频数，低 4 位是
///     时钟源选择）。`coex_hw_timer_tick_get` 读它做 tick 与时间的换算——它是配置，不是计数，读两次不会变；
///   * 核的硬件定时器（`coexist_hw.o` 的反汇编）：每个 16 个字节，在 `0x2010F400 + 16*idx`——`+0`、`+4` 是
///     `coex_hw_timer_set` 写的两个配置字，`+8` 是使能字（`coex_hw_timer_enable` 置它的 bit0），`+0xC` 是状态字。
///     核的事件表里定时器号最多用到 4，所以读 0..4；每个隔 1 ms 读两次。2026-11-27 之前读的是 `0x2010F040 + 16*idx`
///     （那是 `MODEM_LPCON` 的寄存器）与使能字的 bit1，都读错了地方，见 `coex-verification.md` §19.4。
///
/// 读核用的是 `g.core` 上的函数本身，不经包装函数，所以不给胶水的调用计数添数。
pub fn coexReadings(stage: []const u8) void {
    if (!on_target) return;
    coexReport(stage);
    const g = radio_coex.instance();
    if (!g.state.booted) return;
    // 栈指针读数。这个函数曾经把统计结构按值拷贝四份（`const t = coex_trace_stats` 与三个 `for (t.ev)`，每份 10 KB），栈帧 42 KB，
    // 把 16 KiB 的主栈溢出到 BLE 堆里——2026-11-27 有一版镜像因此崩在发送任务的保存上下文上（`coex-verification.md` §19.5）。
    // 现在都按指针走；每个阶段留一个栈指针读数，它应当在主栈里（不低于 `_heap_end`）。
    log.line("coex[{s}]: sp=0x{x:0>8}", .{ stage, spNow() });
    var line: [200]u8 = undefined;
    var item: [160]u8 = undefined;
    var used: usize = 0;
    for (std.enums.values(radio_coex.Hook)) |h| {
        const n = radio_coex.calls(h);
        if (n == 0) continue;
        const name = radio_coex.hookName(h);
        const short = if (std.mem.startsWith(u8, name, "coex_") and std.mem.endsWith(u8, name, "_wrapper"))
            name[5 .. name.len - 8]
        else
            name;
        const text = std.fmt.bufPrint(&item, " {s}={d}", .{ short, n }) catch break;
        appendItem(stage, "hooks", &line, &used, text);
    }
    flushLine(stage, "hooks", line[0..used]);

    const c = g.core;
    log.line("coex[{s}]: core: wifi_status=0x{x:0>8} ble_status=0x{x:0>8} bt_status=0x{x:0>8} interval={d} period={d} phase={s} flexible={d} last_rc={d} last_error={s}", .{
        stage,                                                    c.status_get.?(radio_coex.core.status_get_wifi_bitmap), c.status_get.?(radio_coex.core.status_get_ble_bitmap),
        c.status_get.?(radio_coex.core.status_get_bt_bitmap),     c.schm_interval_get.?(),                                c.schm_curr_period_get.?(),
        if (c.schm_curr_phase_get.?() == null) "none" else "set", c.schm_flexible_period_get.?(),                         g.last_core_rc,
        if (radio_coex.lastError()) |e| @errorName(e) else "-",
    });
    const t = &coex_trace_stats;
    log.line("coex[{s}]: blob->core: status_bit_set n={d} type={d} mask=0x{x:0>8} last=0x{x:0>8} | status_bit_clear n={d} mask=0x{x:0>8} | events>=64 n={d}", .{
        stage, t.set_n, t.set_type, t.set_mask, t.set_last, t.clr_n, t.clr_mask, t.ev_big,
    });
    used = 0;
    for (t.ev[0..], 0..) |*e, i| {
        if (e.req + e.rel + e.pti_n == 0) continue;
        var n = (std.fmt.bufPrint(&item, " e{d}:", .{i}) catch unreachable).len;
        if (e.req != 0) n += (std.fmt.bufPrint(item[n..], " req={d} bad={d}", .{ e.req, e.req_bad }) catch unreachable).len;
        if (e.rel != 0) n += (std.fmt.bufPrint(item[n..], " rel={d} bad={d}", .{ e.rel, e.rel_bad }) catch unreachable).len;
        if (e.pti_n != 0) n += (std.fmt.bufPrint(item[n..], " pti n={d} mask=0x{x:0>2} bad={d}", .{ e.pti_n, e.pti_mask, e.pti_bad }) catch unreachable).len;
        appendItem(stage, "by event", &line, &used, item[0..n]);
    }
    flushLine(stage, "by event", line[0..used]);
    // PTI 按值计数（路线图 C7 的「PTI 行为」）：各阶段的差值就是那一段里核给每个事件的优先级各是几次。
    used = 0;
    var hist: [160]u8 = undefined;
    for (t.ev[0..], 0..) |*e, i| {
        var hn: usize = 0;
        for (e.pti_hist[0..], 0..) |cnt, v| {
            if (cnt == 0) continue;
            hn += (std.fmt.bufPrint(hist[hn..], " {d}:{d}", .{ v, cnt }) catch break).len;
        }
        if (hn == 0) continue;
        const n = (std.fmt.bufPrint(&item, " e{d}:", .{i}) catch unreachable).len;
        hn = @min(hn, item.len - n);
        @memcpy(item[n..][0..hn], hist[0..hn]);
        appendItem(stage, "pti by value", &line, &used, item[0 .. n + hn]);
    }
    flushLine(stage, "pti by value", line[0..used]);
    // 核的硬件定时器在核处理申请 / 释放的那一会儿是什么样（ADR-003 第 5 节 L4b 的「核的硬件定时器在走」）：泵步之间采
    // （`coex_merged.zig` 的 `sampleHwTimers`）看不到申请与释放落在同一个泵步里的那种武装，所以直接在两个包装函数里读。
    used = 0;
    for (t.ev[0..], 0..) |*e, i| {
        if (e.armed_n + e.rel_ok == 0) continue;
        const text = std.fmt.bufPrint(&item, " e{d}: acc={d} on_after={d} (timers 0x{x:0>2}) last_ticks={d}; rel={d} on_before={d} st_before={d}x (0x{x:0>2}); held {d}x min/avg/max={d}/{d}/{d} us", .{
            i,                                       e.armed_n,                         e.armed_on,     e.armed_mask, e.armed_ticks,
            e.rel_ok,                                e.rel_on,                          e.rel_status_n, e.rel_status, e.held_n,
            if (e.held_n == 0) 0 else e.held_min_us, e.held_sum_us / @max(e.held_n, 1), e.held_max_us,
        }) catch break;
        appendItem(stage, "timers in calls", &line, &used, text);
    }
    flushLine(stage, "timers in calls", line[0..used]);
    // 核里的三个状态字读不到（`coex_status_get` 不是读字，见 `radio-coex/src/fake.zig`）：Wi-Fi 的那份是 blob 最后一次置的值
    // （它每次先清 0xffff 再置），BLE / BT 的那份是 controller 经胶水置 / 清出来的镜像。
    log.line("coex[{s}]: status words: wifi=0x{x:0>4} (wifi blob's last set) ble=0x{x:0>4} bt=0x{x:0>4} (bt controller's set/clear, mirrored)", .{
        stage, @as(u16, @truncate(t.set_last)), radio_coex.bt_status_words[1], radio_coex.bt_status_words[2],
    });
    // 两个启动回调（胶水的 `wifiStartTrampoline` / `bleStartTrampoline`）各被核触发了多少次：两边都开着共存时核调它们，
    // 跳板再转给 blob 登记的回调。累计值，各阶段的差值就是这一阶段触发了几次。
    log.line("coex[{s}]: start callbacks: wifi n={d} ble n={d} (the core triggers the trampolines, they forward to the blobs' handlers)", .{ stage, radio_coex.wifi_start_calls, radio_coex.ble_start_calls });

    const clk = hw.readReg(0x2010_F008);
    log.line("coex[{s}]: coex lp clk conf 0x2010F008: 0x{x:0>8} (div_num {d}, src_sel 0x{x})", .{ stage, clk, (clk >> 4) & 0xFFF, clk & 15 });
    const t0 = hw.nowUs();
    readHwTimers(stage, "");
    while (hw.elapsedUs(t0) < 1000) {}
    readHwTimers(stage, " +1ms");
}

/// 核的 5 个硬件定时器的寄存器原值：配置两个字、使能字（bit0 = 使能）、状态字。
fn readHwTimers(stage: []const u8, tag: []const u8) void {
    for (0..5) |idx| {
        const base = 0x2010_F400 + 16 * idx;
        log.line("coex[{s}]: hw timer {d}{s}: w0 0x{x:0>8} w1 0x{x:0>8} en 0x{x:0>8} st 0x{x:0>8}", .{
            stage, idx, tag, hw.readReg(base), hw.readReg(base + 4), hw.readReg(base + 8), hw.readReg(base + 12),
        });
    }
}

/// `-Dcoex-merged` 的 section（`firmware/src/coex_merged.zig`）读共存核状态用的三个口子。
pub fn coexSide(s: radio_coex.Side) radio_coex.SideState {
    return radio_coex.instance().state.side(s);
}
pub fn coexSideInited(s: radio_coex.Side) bool {
    return coexSide(s) == .inited;
}
pub fn coexRejected() u32 {
    var rej: u32 = 0;
    for (radio_coex.instance().rejected) |r| rej += r;
    return rej;
}

/// `_log_write` / `_log_writev` 的 C 实现，取地址填进表：前者是变参函数（Zig 定义不了），
/// 后者带现成的 `va_list`——blob 先用前者打 "W (ms) tag: " 这一截表头，正文走后者。
const s31_log_write = @extern(*const anyopaque, .{ .name = "s31_log_write" });
const s31_log_writev = @extern(*const anyopaque, .{ .name = "s31_log_writev" });

/// 「只做到 init 返回」那一段的选项。探针的 `run()` 与合并镜像（`-Dcoex-merged`，ADR-003 第 2 节）
/// 共用这一段。
pub const InitOptions = struct {
    /// 探针的实验性写操作与大段转储：对内存布局写死的 blob 上下文块（`0x2f013d30`）、对 MAC 窗的
    /// 逐段哈希、init 期间的 osi 调用序列。合并镜像的内存布局不同，写死的地址必须关掉。
    experiments: bool = true,
    /// 交给 Wi-Fi arena 的堆长度；`null` = 整块堆（探针镜像）。合并镜像按子系统配额切分堆
    /// （ADR-003 第 2 节：一个堆，按子系统设配额）。
    heap_len: ?usize = null,
};

/// init 用的配置。`run()` 的失败诊断（`wifi_menuconfig_init`）还要用它，所以放在文件作用域。
var probe_cfg: initcfg.InitConfig = undefined;
/// `wifi_init_config_t.feature_caps` 的覆盖值（`WIFI_FEATURE_CAPS`）。IDF 的值随 sdkconfig 变：对照镜像
/// （`tools/wifi-idf-oracle`）是 0x5A1，`init_config.zig` 里的 0x1a1 出自另一套参照构建、只少 OWE soft-AP 那一位。
pub var feature_caps: ?u64 = null;

/// 装表 → `coex_init` → `esp_wifi_init_internal`，到 `INIT OK` 为止，返回 `esp_wifi_init_internal`
/// 的返回码。不建任务上下文、不开中断、不调 `esp_wifi_start`。
pub fn initOnly(opts: InitOptions) c_int {
    // 两个桩文件里的导出（`WIFI_EVENT`、`regdomain_table`、`est_PHY_*`、`hexstr2bin` 等）只在文件被分析时
    // 才发射。探针的 `run()` 末尾会遍历它们的计数，所以一直被带着；合并镜像只走到这里，要显式引用。
    comptime {
        _ = link_stubs;
        _ = osi_stubs;
    }

    // TIMG0 T0 是本仓的时间基（1 MHz）；探针构建不会自动初始化它，
    // 不初始化则 nowUs() 恒 0（实测），超时/采样中断都无从谈起。
    hw.initTimer();
    // 板级前置：关掉 APM 的三条访问路径控制过滤器（IDF 应用启动期 `bootloader_init_mem()` 做的，
    // 二级 bootloader 跳过；出处与实测见 `board.apm`）。默认只放行 TEE master，Wi-Fi MAC 的 DMA
    // 属 REE——不关，射频收到的帧进不了内存。
    {
        const before = board.apm.ctrlFilterValues();
        board.apm.disableCtrlFilters() catch |e|
            log.line("wifi-init-probe: apm disableCtrlFilters failed: {s}", .{@errorName(e)});
        const after = board.apm.ctrlFilterValues();
        log.line("wifi-init-probe: apm ctrl filters LP/HP/HP_MEM: {d}/{d}/{d} -> {d}/{d}/{d} (0 = off)", .{
            before[0], before[1], before[2], after[0], after[1], after[2],
        });
    }
    // 板级前置（与上面 `hw.initTimer()` 同类）：IDF 启动期 `pmu_init()` 给三个 HP 电源模式写 modem
    // 的 ICG 码并锁存；我们的镜像不做 IDF 的启动初始化，必须在这里补。不做则 modem 时钟域在
    // active 电源态下被门控：`MAC_ST` 的忙位永不自清、`esp_wifi_start` 不返回。
    {
        const before = board.pmu.modemIcgCode();
        board.pmu.initModemIcg() catch |e|
            log.line("wifi-init-probe: pmu initModemIcg failed: {s}", .{@errorName(e)});
        log.line("wifi-init-probe: pmu modem ICG code {d}->{d} (2 = active)", .{ before, board.pmu.modemIcgCode() });
    }

    // 启动期的另一条板级前置：给 Wi-Fi 模块选 LP 时钟源（IDF `esp_perip_clk_init()` 在 `app_main` 之前做，
    // 出处与对照读数见 `board.pmu.initModemLpClock`）。
    board.pmu.initModemLpClock() catch |e|
        log.line("wifi-init-probe: pmu initModemLpClock failed: {s}", .{@errorName(e)});

    // 1) 分配器缓冲：链接脚本给的堆区间（_heap_start.._heap_end，绝对符号取地址）。
    const heap_start: [*]u8 = @ptrFromInt(@intFromPtr(heapStart()));
    const heap_end: [*]u8 = @ptrFromInt(@intFromPtr(heapEnd()));
    const heap_full = @intFromPtr(heap_end) - @intFromPtr(heap_start);
    const heap_len = if (opts.heap_len) |n| @min(n, heap_full) else heap_full;
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
    @import("board").trap.timer_stats_hook = &impl.timerStats;
    @import("board").trap.timer_service_hook = &impl.serviceTimers;
    @import("board").trap.nvs_stats_hook = &nvsStats;
    @import("board").trap.queue_stats_hook = &queueStats;
    @import("board").trap.give_stats_hook = &giveStats;
    @import("board").trap.sem_args_hook = &semArgs;
    // `-Dcoex`：启动共存核（IDF 的 `init_coexist`）。放在 arena 与时基钩子就位之后、建表与 init 之前。
    if (coex_gate.enabled) coexBoot();
    // 自旋期 tick 泵实验已测（无推进），已回滚。
    // tick 泵实验已回滚。

    // 3) 建表；**不预装**，让 wifi_osi_funcs_register 自己校验并注册（IDF 的流程）
    // 表必须是**静态**的：ROM 在 `g_osi_funcs_p` 槽位里长期持有这个指针，
    // 栈上的表在返回后就失效——生产路径同理，所以放文件作用域。
    osi_table = impl.makeTable();
    osi_table._log_write = s31_log_write; // C 变参 shim
    osi_table._log_writev = s31_log_writev;
    // `-Dcoex`：把 24 个共存表项换成胶水的包装函数。必须在 `makeTable()`（它末尾是 `stubs.fill`）之后：
    // 否则 IDF 留空的 `_coex_condition_set` 会被通用桩填上。
    if (coex_gate.enabled) radio_coex.wifi.fill(&osi_table);
    if (coex_gate.enabled) coexTraceTable(&osi_table);
    const table = &osi_table;
    probe_cfg = initcfg.defaults(table);
    if (feature_caps) |f| probe_cfg.feature_caps = f;
    const cfg: *const initcfg.InitConfig = &probe_cfg;
    log.line("wifi-init-probe: table=0x{x:0>8} cfg magic=0x{x:0>8} crypto size={d}", .{
        @intFromPtr(table),
        @as(u32, @bitCast(cfg.magic)),
        cfg.wpa_crypto_funcs.size,
    });

    // 4) 完整 init（干净路径）。**只能调一次**：重复初始化会在第二次进入时解引用无效指针
    //    （实测 exception code=5）。
    // IDF 的 `esp_wifi_init` wrapper 在 `esp_wifi_init_internal` **之前**调 `coex_init()`
    //    （wifi_init.c），我们一直没做；`g_coex_param_ptr` 为 0 也与此吻合。
    if (coex_gate.enabled) {
        // 同一个位置，经胶水：`glue.wifiInit` 把 Wi-Fi 侧记成 inited，之后 blob 的 `wifi_hw_start`
        // 调 `_coex_enable` 才不会被拒（0x103）。两个分支只编一个。
        const rc = radio_coex.wifiInit(null) catch |e| wc: {
            log.line("wifi-init-probe: coex wifiInit FAILED {s} rejected={d}", .{ @errorName(e), radio_coex.rejected(.wifi_init) });
            break :wc @as(c_int, -1);
        };
        log.line("wifi-init-probe: coex wifiInit rc={d}", .{rc});
    } else {
        const coex_init = @extern(*const fn () callconv(.c) void, .{ .name = "coex_init" });
        log.raw("wifi-init-probe: calling coex_init() (IDF wrapper 顺序)\n");
        coex_init();
        log.raw("wifi-init-probe: coex_init returned\n");
    }
    if (opts.experiments) {
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
    }
    // **LPCON ICG 实验已做**：`MODEM_LPCON_CLK_CONF_POWER_ST_REG` 是 **LPCON_BASE + 0x20**
    // （`modem_lpcon_reg.h:198`），字段 wifipwr=[19:16] coex=[23:20] i2c_mst=[27:24] lp_apb=[31:28]。
    // 写 0x66660000（四域各 6）读回一致（wifipwr=6），但 init 后 `MAC_ST` 仍是 0xE000、自旋不变。
    // ⇒ LPCON ICG 也不是缺失的那一步。已回滚。
    // 注：`+0x18` 是 `MODEM_LPCON_CLK_CONF_REG`（我们一直写的是它，那是时钟配置，不是 ICG 图）。
    // **逐域 ICG map 实验已做**：写 `+0x0C` = 0x64646400（与 IDF 完全一致，读回也是 0x64646400），
    // 但 `esp_wifi_init_internal` 返回后 `MAC_ST` 仍是 0xE000、自旋不变。
    // ⇒ ICG 位图不是缺失的那一步（至少单独不是）。已回滚，保持基线干净。
    // 实验已做：`impl.task_create_fail = true`（_task_create 返回 pdFAIL）会让
    // `esp_wifi_init_internal` 直接返回 257(ESP_ERR_NO_MEM) ⇒ blob **要求建任务成功**，没有同步回退。
    // **init 窗口标记**：与 IDF 的 HOOKTRACE begin/end 同口径，只统计 init 期间的钩子。
    const w_qsend = impl.calls.queue_send;
    const w_qrecv = impl.calls.queue_recv;
    const w_rst = impl.cnt_reset_mac;
    const w_clk = impl.cnt_clk_en;
    const w_semc = impl.cnt_sem_create;
    const w_semcn = impl.cnt_sem_create_null;
    // **PP worker 泵实验已做**：给它栈、在 tick 里泵，配合"真阻塞"仍活锁
    // （`idle_calls` 涨到 20000 而 `hooks` 冻结在 17）⇒ 它不是 ack 的生产者。已回滚。
    // **`s_pp_task_create_sem` 实验已做**：我们把它写成 0x2f020ad0，但自旋时读回 **0x0**
    // ⇒ **blob 会把它清零**（`pp_create_task` 先清、再期望某个钩子填）⇒ 单纯"app 侧创建"无效。
    // **清零 `pp_task_hdl` 实验已做**：清零无效——init 里 `_task_create` 又把它写成 `task_dummy`
    // （实测 `ppq` 仍是 0x2f0203b0）⇒ 单纯清零不改变分支结果。已回滚。
    // **PP 上下文进入实验已做**：切进 `ppTask` 直接崩溃（182 次 panic，包装入口都没打印）
    // ⇒ PP worker 不能在我们的合成栈上运行。已回滚。
    // **tp 实验**：给 ppTask 设一个清零 TLS 区后仍是 182 次 panic、入口未打印 ⇒ tp 不是原因。
    // **故障根因已查明**：`g_osi_funcs_p`（0x2f07ff44）在 init 之前是 NULL ⇒ `lw a5,64(a5)` 从 0x40 读。
    // 装槽位后不崩，但 `queue_recv(0, forever)` 阻塞——队列还没被建。⇒ `ppTask` 不能在 init 之前泵。
    dumpClockRegs("before-init");
    // **重测 ROM `ic_mac_init(0)`**：ADR 那次是**旧状态**（握手未修好、任务不调度），且 ABI 可能不对
    // （入参应为"接口号"，即 `ic_mac_init(0)`）。现在握手成立，值得按正确 ABI 重跑一次。
    // **实测结论：rc=0 但 MAC_ST 仍 0xE000**（见 ADR）。因此默认关闭；
    // 需要复跑时把 `probe_manual_ic_mac_init` 置 true 即可（走同一开关，不再有第二个调用点）。
    if (probe_manual_ic_mac_init) {
        const ic_mac_init = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "ic_mac_init" });
        const rc = ic_mac_init(0);
        const ms: *volatile u32 = @ptrFromInt(0x2010_4CAC);
        log.line("wifi-init-probe: ic_mac_init(0) rc={d} MAC_ST=0x{x:0>8}", .{ rc, ms.* });
    }
    // **全 4 KB MAC 块 diff 的唯一差异**：`0x201044EC`，IDF `0x000102C0` vs 我们 `0x00010080`
    // ⇒ 差 **bit 6 与 bit 9**（`0x240`）。**实测：写不粘**（读回仍 0x10080）⇒ 它也是只读状态位，
    // 反映 MAC 状态而非配置它 ⇒ 是症状不是病因。保留这一行作为"已试过"的证据。
    if (opts.experiments) {
        const w44ec: *volatile u32 = @ptrFromInt(0x2010_44EC);
        const b = w44ec.*;
        w44ec.* = b | 0x240;
        log.line("wifi-init-probe: 0x201044EC fixed 0x{x} -> 0x{x} (IDF=0x102C0)", .{ b, w44ec.* });
    }
    impl.resetEvents(); // 从干净的环开始记录 init 期间的完整 osi 序列
    // **全表 diff 找到的唯一差异**：`LPCON+0x18`（clk_conf）在 IDF 侧是 `0x1`（bit0 = `clk_wifipwr_fo`，
    // WiFi 电源域 force-on，由 bootloader 打开），我们侧是 `0x4`（bit2 = `clk_i2c_mst_fo`）。
    // ⇒ 在 init **之前**把它对正：置 bit0、清 bit2。
    {
        const lp: *volatile u32 = @ptrFromInt(0x2010_F018);
        const b = lp.*;
        lp.* = (b & ~@as(u32, 1 << 2)) | (1 << 0);
        log.line("wifi-init-probe: LPCON+18 fixed pre-init 0x{x} -> 0x{x} (IDF=0x1)", .{ b, lp.* });
    }
    // IDF `esp_wifi_init()` 在 `esp_wifi_init_internal` **之前**先设三个省电参数（`wifi_init.c`，无条件调用）：
    // 最短活跃时间、keep-alive 间隔、等广播数据的时间。值取自对照镜像的 sdkconfig
    // （`CONFIG_ESP_WIFI_SLP_DEFAULT_MIN_ACTIVE_TIME=50` ms、`..._MAX_ACTIVE_TIME=10` s、
    // `..._WAIT_BROADCAST_DATA_TIME=15` ms），IDF 传的是微秒。
    {
        const set_min_active = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_wifi_set_sleep_min_active_time" });
        const set_keep_alive = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_wifi_set_keep_alive_time" });
        const set_wait_broadcast = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_wifi_set_sleep_wait_broadcast_data_time" });
        log.line("wifi-init-probe: pm params rc: min_active={d} keep_alive={d} wait_broadcast={d}", .{
            set_min_active(50 * 1000), set_keep_alive(10 * 1000 * 1000), set_wait_broadcast(15 * 1000),
        });
    }
    // **b14 / b21 门在新前提下的重测已做（均无效）**：b14=1 或 b14=1+b21=1 之后
    // `b288` 仍是 0、`MAC_ST` 仍是 `0x0000e000`、INITWIN 不变。已回滚。
    const init_rc = esp_wifi_init_internal(cfg);
    // IDF `esp_wifi_init()` 的收尾（`wifi_init.c:539-543`）：`esp_wifi_init_internal` 成功之后置
    // `MODEM_STATUS_WIFI_INITED`——此后 `_wifi_clock_disable` 不再关 Wi-Fi 自己的时钟。
    if (init_rc == 0) impl.wifi_clock_inited = true;
    // 同一段收尾里还有设 blob 的日志级别（`wifi_init.c:125-144`，在 `esp_wifi_init()` 的 `:460` 调用）：
    // 不设的话 blob 的日志是关的，只剩设级别之前打的那两行版本信息。
    if (init_rc == 0) {
        const set_level = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "esp_wifi_internal_set_log_level" });
        const rc = set_level(blob_log_level);
        log.line("wifi-init-probe: esp_wifi_internal_set_log_level({d}) rc=0x{x:0>8}", .{ blob_log_level, @as(u32, @bitCast(rc)) });
    }
    // IDF `esp_wifi_init()` 的最后一项（`wifi_init.c:512`）：`esp_supplicant_init()`——把 supplicant 的
    // 回调表登记给 blob（`g_ic->[444]`）。我们没有 IDF 的 `wpa_supplicant` 组件，登记自己的
    // （`wpa_cb.zig`）。不登记则那张表是空指针，而扫描路径 `scan_add_ssid_do` 对它有一处不判空就解引用，
    // 第一帧 beacon / probe response 就 `load access fault @0x54`（2026-11-26 板侧实测）。
    if (init_rc == 0) {
        const rc = wpa_cb.register();
        // 读回校验：blob 的 `esp_wifi_register_wpa_cb_internal` 就是 `g_ic->[444] = cb`。`g_ic` 是结构体
        // 本身（blob 的代码是 `lw a4,444(a5)`、a5 = `g_ic` 的地址），不是指针变量。
        const g_ic = @extern(*const anyopaque, .{ .name = "g_ic" });
        const stored: usize = @as([*]align(1) const usize, @ptrCast(g_ic))[444 / @sizeOf(usize)];
        log.line("wifi-init-probe: wpa cb register rc={d} g_ic[444]=0x{x:0>8} table=0x{x:0>8}", .{
            rc, stored, @intFromPtr(&wpa_cb.funcs),
        });
    }
    dumpClockRegs("after-init");
    if (probe_regdump) regDumpAll("after-init");
    {
        // init 返回之后 `MAC_ST` 的忙位（bit 13–15）：IDF 在 init 里就清零。读到 0xE000 说明 modem
        // 时钟域没跑起来（见 `initOnly` 开头的 `board.pmu.initModemIcg()`）。
        const ms: *volatile u32 = @ptrFromInt(0x2010_4CAC);
        log.line("wifi-init-probe: after-init MAC_ST=0x{x:0>8} (init_rc={d})", .{ ms.*, init_rc });
    }
    if (coex_gate.enabled) coexReport("init");
    if (opts.experiments) {
        const h = macWindowHash();
        log.line("wifi-init-probe: MACWIN xor=0x{x:0>8} sum=0x{x:0>8}", .{ h.x, h.s });
        // 分段 hash：4 段 × 256 字，定位差异落在哪一段
        const base: [*]const volatile u32 = @ptrFromInt(0x2010_4000);
        var q: usize = 0;
        while (q < 4) : (q += 1) {
            var x: u32 = 0;
            var sm: u32 = 0;
            var k: usize = 0;
            while (k < 256) : (k += 1) {
                const v = base[q * 256 + k];
                x ^= v *% @as(u32, @intCast(k + 1));
                sm +%= v;
            }
            log.line("wifi-init-probe: MACWINQ {d} xor=0x{x:0>8} sum=0x{x:0>8}", .{ q, x, sm });
            // Quarter 1 再细分成 16 段 × 16 字（差异已定位到该区）
            if (q == 1) {
                var b: usize = 0;
                while (b < 16) : (b += 1) {
                    var bx: u32 = 0;
                    var bs: u32 = 0;
                    var kk: usize = 0;
                    while (kk < 16) : (kk += 1) {
                        const v = base[256 + b * 16 + kk];
                        bx ^= v *% @as(u32, @intCast(kk + 1));
                        bs +%= v;
                    }
                    log.line("wifi-init-probe: Q1B {d} addr=0x{x} xor=0x{x:0>8} sum=0x{x:0>8}", .{
                        b, 0x2010_4400 + b * 64, bx, bs,
                    });
                    if (b == 3) {
                        var w: usize = 0;
                        while (w < 16) : (w += 1) {
                            const v = base[256 + 3 * 16 + w];
                            log.line("wifi-init-probe: W4C0 {d} addr=0x{x} v=0x{x:0>8}", .{
                                w, 0x2010_44C0 + w * 4, v,
                            });
                        }
                    }
                }
            }
        }
    }
    // **完整 osi 调用序列**（init 窗口内，最多 64 条）——与 IDF 侧逐条 diff，分叉点就是缺的那一步。
    if (opts.experiments) {
        const n = @min(impl.event_count, impl.events.len);
        // **环里存的是"最后 n 条"**，所以起点是 `event_count - n`，不是 0。
        const base = impl.event_count - n;
        log.line("wifi-init-probe: OSISEQ n={d} ring={d} base={d}", .{ impl.event_count, impl.events.len, base });
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const e = impl.events[(base + i) % impl.events.len];
            if (e.id < impl.hook_ids.len) {
                log.line("wifi-init-probe: OSI {d} {s} a0=0x{x} a1=0x{x}", .{
                    i, impl.hook_ids[e.id], e.a0, e.a1,
                });
            } else {
                log.line("wifi-init-probe: OSI {d} id={d} a0=0x{x}", .{ i, e.id, e.a0 });
            }
        }
    }
    log.line("wifi-init-probe: INITWIN qsend={d} qrecv={d} rstmac={d} clken={d} semcreate={d} semnull={d}", .{
        impl.calls.queue_send - w_qsend,
        impl.calls.queue_recv - w_qrecv,
        impl.cnt_reset_mac - w_rst,
        impl.cnt_clk_en - w_clk,
        impl.cnt_sem_create - w_semc,
        impl.cnt_sem_create_null - w_semcn,
    });
    log.line("wifi-init-probe: ROMGLOB swq=0x{x} ppq=0x{x} ppsem=0x{x}", .{
        @as(*volatile usize, @ptrFromInt(0x2f07ff0c)).*,
        @as(*volatile usize, @ptrFromInt(0x2f07ff18)).*,
        @as(*volatile usize, @ptrFromInt(0x2f07ff14)).*,
    });
    if (opts.experiments) {
        const bg_pre = @as([*]volatile u8, @ptrFromInt(0x2f013d30));
        log.line("wifi-init-probe: post-init ctx b14={d} b15={d} b16={d} b27={d} b288={d} b289={d} mac=0x{x:0>8}", .{
            bg_pre[14],                                    bg_pre[15], bg_pre[16], bg_pre[27], bg_pre[288], bg_pre[289],
            @as(*volatile u32, @ptrFromInt(0x20104CAC)).*,
        });
    }
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
    }
    return init_rc;
}

pub fn run() noreturn {
    log.raw("wifi-init-probe: begin\n");
    // 复位态基线：在任何 blob 代码跑之前读一次 MAC 状态寄存器，
    // 用来区分"busy{13..15} 是复位默认"还是"init 里被谁置起来的"。
    {
        const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
        log.line("wifi-init-probe: MAC_ST at begin = 0x{x:0>8}", .{mac_st.*});
    }
    const init_rc = initOnly(.{});
    if (init_rc == 0) {
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
                        // 这两个共享字只**置位**、不整字覆盖（2026-11-27，时钟域按单元取并集）：单独跑时读数与
                        // 整字写相同；BLE 先起的镜像里，它的位不会被 Wi-Fi 的 init 清掉。
                        t0.* |= 0x0000_0100;
                        t4.* |= 0x0020_1002;
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
                // **不再手动 `sched.start`**：`idleHook.pumpRealTask()` 已经 round-robin 泵真实任务
                // 上下文（`tasks[i].ctx`）。同一个 entry 建两份上下文（`task_ctx` + `tasks[i].ctx`）
                // 会让 `cur_task` 记账错位——任务在 `task_ctx` 上阻塞时切不回来（实测 hooks 冻结）。
                _ = &task_ctx;
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
                    // 这里曾有一个实验：把 `0x2f005b0c` 当成 blob 的"清状态位"函数来调，想在 start 之前
                    // 清掉 busy{13..15}。2026-11-24 用带符号的镜像核对：在关着共存的对照镜像里，那个地址
                    // 落在 `ppEnqueueTxDone`（0x2f005ac4，长 0x62）的函数**中间**，不是函数入口——
                    // 所以对照镜像在同一处也 panic（code 7，mepc=0x4004c70a）。它从来没成功过，已删除。
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
                        sched.enterAs(&task_ctx);
                        sched.swapContext(&main_ctx, &task_ctx);
                        in_task = false;
                        impl.current_is_task = false;
                        log.line("wifi-init-probe: pump round {d} after:  b14={d} b15={d} b16={d} b27={d} b288={d} mac=0x{x:0>8} recv={d} send={d} delay={d}", .{
                            round,                                         bgp[14],               bgp[15],               bgp[16],               bgp[27], bgp[288],
                            @as(*volatile u32, @ptrFromInt(0x20104CAC)).*, impl.calls.queue_recv, impl.calls.queue_send, impl.calls.task_delay,
                        });
                    }
                }
                // **强制上膛 + fire 实验已做**：`forceArmAll armed=14` → `trace timer_fire` 出现 14 次
                // （走真实路径）→ `timers fires=14 armed=0`，而自旋**不变**。
                // ⇒ 定时器路径**已被验证**：14 个回调全部 fire 过，状态机不推进。
                // **ppTask 泵实验已做**：给它自己的栈 + `sched.initContext`/`swapContext` 后它**能正常让出**
                // （不会像直接 call 那样挂死），但 **16 轮泵下来 b288 仍为 0、MAC_ST 不变**。
                // ⇒ ROM 的 PP worker 单独跑也不推进状态机（它多半在等别的消息/事件）。
                // **start 的自旋环已定位**（反汇编 0x2f0091fe..0x2f009206）：
                //     lw a5, 0(0x20104CAC)      # MAC_ST
                //     and a5, a5, 0xE000        # bits 13..15
                //     bnez a5, 0x2f0091fe       # 只要这三位非 0 就一直转
                // 我们板子上 MAC_ST=0x0000E000 ⇒ 这三位**全 1** ⇒ 死循环。
                // IDF 侧 MAC_ST 是 0（bootloader_init_mem 清过），所以它能过。
                {
                    dumpClockRegs("before-start");
                    log.line("wifi-init-probe: MAC_ST before start = 0x{x:0>8} (spin mask 0xE000)", .{mac_st.*});
                    // **全程 `_wifi_clock_enable` 调用次数**（IDF 侧是 9 次）——与 INITWIN 的窗口计数区分开。
                    log.line("wifi-init-probe: CLKEN total={d} caller=0x{x} (IDF caller pm_attach=0x4005700c)", .{
                        impl.cnt_clk_en,
                        impl.clk_caller_ra,
                    });
                    // **W1C 判别**：若 bits 13-15 是"写 1 清零"，写 0 当然没反应（之前试过），写 1 才会清。
                    // IDF start 后是 `0x00FF1000`（bits 13-15 = 0），我们是 `0x00FFF000`——差的就是这三位。
                    mac_st.* = 0xE000;
                    log.line("wifi-init-probe: after W1C write 0xE000 -> 0x{x:0>8}", .{mac_st.*});
                    mac_st.* = 0x00FF_1000;
                    log.line("wifi-init-probe: after write 0x00FF1000 -> 0x{x:0>8}", .{mac_st.*});
                    // **判别实验**：手动脉冲 `rst_wifimac`（`_wifi_reset_mac` 钩子，bit9，脉冲已加宽到 20 µs），
                    // 看 MAC_ST 的 bits 13-15 是否因此清零——若清不掉，说明那三位不属于这个复位域。
                    {
                        const before = mac_st.*;
                        _ = impl.callResetMac();
                        log.line("wifi-init-probe: after rst_wifimac pulse MAC_ST=0x{x:0>8} (was 0x{x:0>8})", .{
                            mac_st.*, before,
                        });
                    }
                    // **闸门**：`0x2f00254e` 返回 `b[0x2F0174A2]`（非 0 时）否则 `b[0x2F0175C4]`；
                    // 返回 0 时 `esp_wifi_start` **跳过** MAC_ST 等待（`beqz a0, 0x2f0091dc`）。
                    {
                        const g1: *volatile u8 = @ptrFromInt(0x2F0174A2);
                        const g2: *volatile u8 = @ptrFromInt(0x2F0175C4);
                        log.line("wifi-init-probe: gate b[2F0174A2]={d} b[2F0175C4]={d}", .{ g1.*, g2.* });
                    }
                    mac_st.* = 0;
                    log.line("wifi-init-probe: MAC_ST cleared -> 0x{x:0>8}", .{mac_st.*});
                }
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
        log.line("wifi-init-probe: wifi_menuconfig_init rc={d}", .{menu(&probe_cfg)});
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
