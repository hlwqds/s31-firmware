//! controller 的 init / enable 编排（IDF `bt.c:200-280` + `ble.c:1447-1530` 的 Zig 版）。
//!
//! 每一步都分得清"归档符号"与"我们自己写的"——这是前面所有工作的落点：
//!
//! | 步 | 调用 | 归属 |
//! | --- | --- | --- |
//! | init 1 | `btdm_osal_elem_mempool_init(&elem)` | 我们（`porting.elemMempoolInit`，容量校验） |
//! | init 2 | `btdm_log_init` / `btdm_external_init` / `btdm_coex_init` | 我们（都 `return 0`） |
//! | init 3 | `btdm_lp_enable_clock(&cfg.btdm)` | 我们（**空实现 + 日志**） |
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
const builtin = @import("builtin");
const osal = @import("osal.zig");
const config = @import("config.zig");
const porting = @import("porting.zig");
const r_ext_funcs = @import("extfuncs.zig");
const transport = @import("transport.zig");

pub const Status = enum(u8) { idle = 0, inited = 1, enabled = 2 };

/// **跳过 `r_btdm_task_init`**（实验用）。
/// 该调用会访问不可达的 `0x2010B000` ⇒ 总线挂起，于是它之后的 step 7–15、enable 链、
/// HCI 传输**从未在板上执行过**。跳过它即可验证那一大片。
pub var skip_task_init: bool = false;

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
extern fn esp_ble_register_bb_funcs() c_int;
extern fn r_base_stack_initEnv() c_int;
extern fn r_conn_stack_initEnv() c_int;
extern fn r_base_stack_enable() c_int;
extern fn r_conn_stack_enable() c_int;
extern fn r_esp_ble_ll_set_public_addr(addr: *const [6]u8) c_int;

const freestanding = builtin.os.tag == .freestanding;

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
fn enter(n: u32, comptime what: []const u8) void {
    osal.logPublic("bt bringup: enter step {d} " ++ what, .{n});
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

pub fn init(cfg: *config.Config) c_int {
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

    // 3. 时钟门控（真实现：12 个门 + MAC 复位，内部读回自证）
    enter(5, "btdm_lp_enable_clock");
    porting.btdmLpEnableClock(&cfg.btdm);

    // 4. 归档：任务层
    // **BT_BLOCK_PROBE**：直读 `0x2010B000`。寄存器已与 IDF 同点对齐，
    // 若这行之后没有打印值 ⇒ 我们的块仍不可读；有值 ⇒ 块已可读、fault 另有其因。
    // **对照读 + 目标读**（仅目标侧：主机上这些地址不存在）
    // ⚠ **必须受开关控制**：`0x2010B000` 不可访问时会挂住整个系统，
    // 若无条件执行，**每一次正常运行都会死在它上面**（本轮就是这样，白白丢了几轮板测）。
    if (@import("builtin").target.os.tag == .freestanding and @import("probe.zig").ble_block_experiment) {
        osal.logPublic("bt probe: control read 0x20109C04 = 0x{x:0>8}", .{(@as(*volatile u32, @ptrFromInt(0x2010_9C04))).*});
        osal.logPublic("bt probe: BT_BLOCK_PROBE reading 0x2010B000 ...", .{});
        osal.logPublic("bt probe: 0x2010B000 = 0x{x:0>8}", .{(@as(*volatile u32, @ptrFromInt(0x2010_B000))).*});
    }
    enter(6, "r_btdm_task_init");
    {
        const pp = @import("probe_ptr.zig");
        if (@import("probe.zig").populate_workaround and pp.get() == 0) {
            const pr = pp.populate();
            osal.logPublic("bt bringup: Xpuq 锚点为 NULL => 补调写者 rc={d}, 现在 P=0x{x:0>8}", .{ pr, pp.get() });
        } else {
            osal.logPublic("bt bringup: Xpuq 锚点 P=0x{x:0>8} (init 前为 0 是正常的，oracle 亦如此)", .{pp.get()});
        }
    }
    // **只发布 7.o 锚点**：给 `BOhff` 的守卫一块可读内存（入口只判非空）。
    if (@import("probe.zig").publish_bohff_anchor) {
        const pp7 = @import("probe_ptr.zig");
        if (pp7.bohffAnchor() == 0) {
            if (osal.btdmMalloc(16, 0)) |a7| {
                pp7.setBOhffAnchor(@intCast(@intFromPtr(a7)));
                osal.logPublic("bt bringup: 发布 7.o 锚点 a7=0x{x:0>8}（BOhff 守卫）", .{@intFromPtr(a7)});
            }
        }
    }
    if (@import("probe.zig").populate_workaround) {
        // **发布 OkE7 锚点**（受 `populate_workaround` 控制，默认关）。
        //
        // 形状取自 oracle 的实测（`X[0..7]`）：
        //   +0 状态字节(=1)、+4/+8/+16/+20 指针、+12 0、+24 = 0x20260127(版本魔数)、+28 = 0x171000
        // `r_btdm_task_deinit` 会 `lw a0,20(a5)` 并把该字段当指针调用
        // ⇒ 结构必须 **≥32 字节**，否则 +20 越界（16 字节时读到的正是 arena 块头 0xb7a10c0d）。
        const pp = @import("probe_ptr.zig");
        const osal2 = @import("osal.zig");
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
                    // **同时发布 7.o 的锚点**：`r_sym_bt_BOhff`（建任务）的守卫也判非空；
                    // 只发布 21.o 时它会早退 ⇒ `task_create` 永不发生 ⇒ 走清理路径。
                    if (pp.bohffAnchor() == 0) {
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
        rc = step(6, "r_btdm_task_init", if (freestanding) r_btdm_task_init(&cfg.btdm) else 0);
    }
    if (rc != 0) return rc;

    // 5. lp init（空实现）
    enter(7, "btdm_lp_init");
    rc = step(7, "btdm_lp_init", porting.btdmLpInit());
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
    if (rc != 0) return rc;

    // 15. **HCI 传输层**（IDF 里是 `esp_bt_controller_init` 的最后一步、enable 之前）。
    //     不做这一步：命令照样发得出去（我们直接调 forward），但 controller **没有回程回调**
    //     ⇒ Command Complete 永远到不了 `leEvtTx` ⇒ 症状是"init 全绿、命令发了、就是没回包"，
    //     极易被误判成时钟/中断/任务没做。
    enter(15, "hci_transport_init");
    rc = step(15, "hci_transport_init", transport.init());
    if (rc != 0) return rc;

    status_state = .inited;
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
    enter(16, "btdm_coex_enable");
    var rc = step(16, "btdm_coex_enable", porting.btdmCoexEnable());
    if (rc != 0) return rc;

    enter(17, "r_base_stack_enable");
    rc = step(17, "r_base_stack_enable", if (freestanding) r_base_stack_enable() else 0);
    if (rc != 0) return rc;
    enter(18, "r_conn_stack_enable");
    rc = step(18, "r_conn_stack_enable", if (freestanding) r_conn_stack_enable() else 0);
    if (rc != 0) return rc;

    enter(19, "r_btdm_hci_fc_enable");
    rc = step(19, "r_btdm_hci_fc_enable", if (freestanding) r_btdm_hci_fc_enable() else 0);
    if (rc != 0) return rc;

    // **最后一步**：controller 任务在这里才真正启动
    enter(20, "r_btdm_task_enable");
    rc = step(20, "r_btdm_task_enable", if (freestanding) r_btdm_task_enable() else 0);
    if (rc != 0) return rc;

    status_state = .enabled;
    osal.logPublic("bt bringup: ENABLED", .{});
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
