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

/// 每步**进入时**先打一行：否则"停在某步内部"与"没走到那步"分不开
/// （实测：step 6 `r_btdm_task_init` 内部挂住时，日志停在 step 5 之后，看不出是哪步）。
fn step(n: u32, comptime what: []const u8, archive_rc: ?c_int) c_int {
    osal.logPublic("bt bringup: step {d} " ++ what ++ " ...", .{n});
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
    var rc = step(1, "mempool", porting.prepareMempool(cfg));
    if (rc != 0) return rc;

    // 2. 三个空实现
    rc = step(2, "btdm_log_init", porting.btdmLogInit());
    if (rc != 0) return rc;
    rc = step(3, "btdm_external_init", porting.btdmExternalInit());
    if (rc != 0) return rc;
    rc = step(4, "btdm_coex_init", porting.btdmCoexInit());
    if (rc != 0) return rc;

    // 3. 时钟（空实现 + 日志）
    _ = step(5, "btdm_lp_enable_clock", null); // 空实现 + 日志，不算失败
    porting.btdmLpEnableClock(&cfg.btdm);

    // 4. 归档：任务层
    rc = step(6, "r_btdm_task_init", if (freestanding) r_btdm_task_init(&cfg.btdm) else 0);
    if (rc != 0) return rc;

    // 5. lp init（空实现）
    rc = step(7, "btdm_lp_init", porting.btdmLpInit());
    if (rc != 0) return rc;

    // 6. 归档：HCI 流控环境
    rc = step(8, "r_btdm_hci_fc_env_init", if (freestanding) r_btdm_hci_fc_env_init() else 0);
    if (rc != 0) return rc;

    // 7. BLE 控制器：**先注册 ext_funcs**（controller 的 malloc/free/rand/assert 都在这张表里，
    //    跳过它就等于 controller 没有分配器 ⇒ r_ble_controller_init 必然失败）
    rc = step(9, "esp_register_ext_funcs", if (freestanding) r_ext_funcs.register() else 0);
    if (rc != 0) return rc;
    // 再注册 BB 回调 → r_ble_controller_init → msys
    rc = step(9, "esp_ble_register_bb_funcs", if (freestanding) esp_ble_register_bb_funcs() else 0);
    if (rc != 0) return rc;
    rc = step(10, "r_ble_controller_init", if (freestanding) r_ble_controller_init(&cfg.ble) else 0);
    if (rc != 0) return rc;
    stats_state.ext_funcs_registered += 1;
    // `ble_controller_scan_duplicate_config` 是 host 侧 ⇒ 空操作
    porting.bleControllerScanDuplicateConfig();
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
    rc = step(14, "r_esp_ble_ll_set_public_addr", if (freestanding) r_esp_ble_ll_set_public_addr(&mac) else 0);
    if (rc != 0) return rc;

    // 15. **HCI 传输层**（IDF 里是 `esp_bt_controller_init` 的最后一步、enable 之前）。
    //     不做这一步：命令照样发得出去（我们直接调 forward），但 controller **没有回程回调**
    //     ⇒ Command Complete 永远到不了 `leEvtTx` ⇒ 症状是"init 全绿、命令发了、就是没回包"，
    //     极易被误判成时钟/中断/任务没做。
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
    var rc = step(16, "btdm_coex_enable", porting.btdmCoexEnable());
    if (rc != 0) return rc;

    rc = step(17, "r_base_stack_enable", if (freestanding) r_base_stack_enable() else 0);
    if (rc != 0) return rc;
    rc = step(18, "r_conn_stack_enable", if (freestanding) r_conn_stack_enable() else 0);
    if (rc != 0) return rc;

    rc = step(19, "r_btdm_hci_fc_enable", if (freestanding) r_btdm_hci_fc_enable() else 0);
    if (rc != 0) return rc;

    // **最后一步**：controller 任务在这里才真正启动
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
