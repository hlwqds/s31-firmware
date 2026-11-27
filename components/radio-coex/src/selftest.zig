//! radio-coex：板侧自检（10 条判据）。
//!
//! 板上两个射频都还没通，所以自检跑的是"胶水 + 记录型假核心"：与主机测试同一批模块，
//! 验证胶水自己的转发、配置分支、回调登记与生命周期守卫。它**不证明** `libcoexist.a` /
//! ROM 在板上工作——那是 L3 的事（`g_coex_param_ptr` 非零、版本两行日志、两个 BLE 回调登记成功，
//! 见 README「待验证项」）。
//!
//! 每条判据打印一行 `check: ... ok=1/0`，最后一行 `checks: passed=N failed=M total=N+M`。
//!
//! 跑之前把胶水单例存一份、跑完还原：生产构建若已经用 `bind.boot()` 装了真核心，不被自检冲掉。
//!
//! 十条判据：
//!
//!   ① 适配表：20 个字段、版本 2、魔数 0xDEADBEAF、缺钩子拒绝、给齐后 18 项都有
//!   ② boot：先注册适配表再 pre_init，注册的是胶水的静态表，pre_init 经表建信号量 (1,1)
//!   ③ Wi-Fi 转发：参数原样到核心、返回核心的值、status_get 补的位图是 1
//!   ④ Wi-Fi 关闭分支：配置没开时全是桩值（flexible_period_get 是 1），核心零调用，留空项只有 1 个
//!   ⑤ BLE 转发：方案回调登记在 BT(1) 下、信道出参指针透传、version_get 回 0、ISO 默认是桩
//!   ⑥ BLE 回调：两个 type 分开保存；单独 enable 不触发，第二个射频 enable 触发 type 0，降回 1 触发 type 1
//!   ⑦ 生命周期守卫：enable 早于 init、重复 enable、disable 早于 enable、enable 期间 deinit、boot 两次
//!   ⑧ 未启动：钩子降级成桩值并记拒绝，核心零调用
//!   ⑨ IDF 全序（boot → Wi-Fi init → BLE init → BLE enable → Wi-Fi enable → 关闭）被接受，核心调用顺序一致
//!   ⑩ 核心失败透传：适配表注册失败 ⇒ boot 报错、停在未启动态

const std = @import("std");

const adapter = @import("adapter.zig");
const ble = @import("ble.zig");
const core = @import("core.zig");
const fake = @import("fake.zig");
const glue = @import("glue.zig");
const wifi = @import("wifi.zig");

const board = @import("board");
const log = board.log;

const INVALID_STATE = core.ESP_ERR_INVALID_STATE;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

// ---------------------------------------------------------------------------
// 适配表的 18 个钩子与几个回调（纯 Zig，自给自足；与 host_tests.zig 里的那份同构）
// ---------------------------------------------------------------------------

var next_sem: usize = 0x1000;
var cb0_hits: u32 = 0;
var cb1_hits: u32 = 0;

fn hVoid0() callconv(.c) void {}
fn hSemCreate(max: u32, init: u32) callconv(.c) ?*anyopaque {
    _ = max;
    _ = init;
    const p: *anyopaque = @ptrFromInt(next_sem);
    next_sem += 4;
    return p;
}
fn hSemDelete(s: ?*anyopaque) callconv(.c) void {
    _ = s;
}
fn hSemFromIsr(s: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    _ = s;
    const p: *i32 = @ptrCast(@alignCast(hptw.?));
    p.* = 0;
    return 1;
}
fn hSemTake(s: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    _ = s;
    _ = ticks;
    return 1;
}
fn hSemGive(s: ?*anyopaque) callconv(.c) i32 {
    _ = s;
    return 1;
}
fn hIsInIsr() callconv(.c) c_int {
    return 0;
}
fn hMalloc(size: usize) callconv(.c) ?*anyopaque {
    _ = size;
    return null;
}
fn hFree(p: ?*anyopaque) callconv(.c) void {
    _ = p;
}
fn hTime() callconv(.c) i64 {
    return 0;
}
fn hEnvIsChip() callconv(.c) bool {
    return true;
}
fn hTimer1(t: ?*anyopaque) callconv(.c) void {
    _ = t;
}
fn hTimer3(t: ?*anyopaque, f: ?*anyopaque, a: ?*anyopaque) callconv(.c) void {
    _ = t;
    _ = f;
    _ = a;
}
fn hTimerArmUs(t: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    _ = t;
    _ = us;
    _ = repeat;
}
fn hDebugMatrix(e: c_int, s: c_int, rev: bool) callconv(.c) c_int {
    _ = e;
    _ = s;
    _ = rev;
    return core.ESP_ERR_NOT_SUPPORTED;
}
fn hXtal() callconv(.c) c_int {
    return 40;
}

const hooks = adapter.Hooks{
    ._task_yield_from_isr = &hVoid0,
    ._semphr_create = &hSemCreate,
    ._semphr_delete = &hSemDelete,
    ._semphr_take_from_isr = &hSemFromIsr,
    ._semphr_give_from_isr = &hSemFromIsr,
    ._semphr_take = &hSemTake,
    ._semphr_give = &hSemGive,
    ._is_in_isr = &hIsInIsr,
    ._malloc_internal = &hMalloc,
    ._free = &hFree,
    ._esp_timer_get_time = &hTime,
    ._env_is_chip = &hEnvIsChip,
    ._timer_disarm = &hTimer1,
    ._timer_done = &hTimer1,
    ._timer_setfn = &hTimer3,
    ._timer_arm_us = &hTimerArmUs,
    ._debug_matrix_init = &hDebugMatrix,
    ._xtal_freq_get = &hXtal,
};

fn someCb() callconv(.c) c_int {
    return 0;
}
fn bleCb0() callconv(.c) void {
    cb0_hits += 1;
}
fn bleCb1() callconv(.c) void {
    cb1_hits += 1;
}

fn cb(comptime f: anytype) *const anyopaque {
    return @ptrCast(f);
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

var fk: fake.Fake = .{};

/// `lastError()` 与期望值比较。**必须先解包再比**：Zig 0.17.1 的 Debug 构建里
/// `?E == ?E` 恒为假（`opt() == @as(?E, error.A)` 在 Debug 下是 false，Release* 下才对；
/// 仓库的主机测试正是 Debug）。本机最小复现见 `docs/verification/coex-verification.md`。
fn lastErrorIs(e: glue.Error) bool {
    return if (glue.lastError()) |v| v == e else false;
}

fn reset(cfg: glue.Config) void {
    cb0_hits = 0;
    cb1_hits = 0;
    fake.select(&fk);
    glue.install(fake.core(), cfg) catch |e| log.line("coex selftest: install failed: {s}", .{@errorName(e)});
}

fn boot() bool {
    glue.boot(hooks) catch |e| {
        log.line("coex selftest: boot failed: {s}", .{@errorName(e)});
        return false;
    };
    return true;
}

fn record(c: fake.Call) fake.Record {
    return fk.last(c) orelse .{ .call = c };
}

// ---------------------------------------------------------------------------
// ① 适配表
// ---------------------------------------------------------------------------

fn checkAdapter() void {
    const t = adapter.AdapterTable{};
    var partial = hooks;
    partial._semphr_create = null;
    const rejected = if (adapter.build(partial)) |_| false else |e| e == error.MissingHooks;
    const full = adapter.build(hooks) catch adapter.AdapterTable{};
    var filled: u32 = 0;
    inline for (@typeInfo(adapter.Hooks).@"struct".field_names) |name| {
        if (@field(full, name) != null) filled += 1;
    }
    check(
        adapter.field_count == 20 and t._version == 2 and @as(u32, @bitCast(t._magic)) == 0xDEAD_BEAF and
            rejected and adapter.missingMask(partial) == (1 << 1) and filled == 18,
        "adapter fields={d} version={d} magic={x} missing_rejected={d} missing_bit={d} filled={d}",
        .{ adapter.field_count, t._version, @as(u32, @bitCast(t._magic)), @intFromBool(rejected), adapter.missingMask(partial), filled },
    );
}

// ---------------------------------------------------------------------------
// ② boot
// ---------------------------------------------------------------------------

fn checkBoot() bool {
    reset(.{});
    const ok_boot = boot();
    const created = fk.hook_first[adapter.indexOf("_semphr_create")];
    check(
        ok_boot and fk.total() == 2 and fk.at(0).call == .adapter_register and fk.at(1).call == .pre_init and
            fk.registered == glue.adapterTable() and created[0] == 1 and created[1] == 1 and
            fk.timer_freq[0] == 4 and fk.timer_freq[1] == 50 and glue.state().phase() == .pre_inited,
        "boot calls={d} first=adapter_register second=pre_init table={d} sem_create=({d},{d}) timer=({d},{d}) phase=pre_inited={d}",
        .{ fk.total(), @intFromBool(fk.registered == glue.adapterTable()), created[0], created[1], fk.timer_freq[0], fk.timer_freq[1], @intFromBool(glue.state().phase() == .pre_inited) },
    );
    return ok_boot;
}

// ---------------------------------------------------------------------------
// ③ Wi-Fi 转发
// ---------------------------------------------------------------------------

fn checkWifiForward() void {
    fk.rc[@backingInt(fake.Call.wifi_request)] = -7;
    fk.val.status_get = 0x89AB_CDEF;
    fk.status_words[1] = 0x10;
    fk.val.pti = 0x5A;
    const req = wifi.coex_wifi_request_wrapper(1, 2, 3);
    const status = wifi.coex_status_get_wrapper();
    var pti: u8 = 0;
    const prc = wifi.coex_pti_get_wrapper(9, &pti);
    const r_req = record(.wifi_request);
    const r_status = record(.status_get);
    const r_pti = record(.pti_get);
    check(
        req == -7 and status == 0x89AB_CDEF and prc == 0 and pti == 0x5A and
            r_req.a0 == 1 and r_req.a1 == 2 and r_req.a2 == 3 and r_status.a0 == 1 and
            r_pti.a0 == 9 and r_pti.a1 == @intFromPtr(&pti),
        "wifi forward req_rc={d} req_args=({d},{d},{d}) status={x} status_bitmap={d} pti={d} pti_ptr_ok={d}",
        .{ req, r_req.a0, r_req.a1, r_req.a2, status, r_status.a0, pti, @intFromBool(r_pti.a1 == @intFromPtr(&pti)) },
    );
}

// ---------------------------------------------------------------------------
// ④ Wi-Fi 关闭分支与留空项
// ---------------------------------------------------------------------------

fn checkWifiStub() void {
    reset(.{ .sw_coexist = false, .external_coexist = false });
    var nulls: u32 = 0;
    for (wifi.entries) |e| {
        if (e.func == null) nulls += 1;
    }
    var d: u32 = 0xEEEE_EEEE;
    const req = wifi.coex_wifi_request_wrapper(1, 2, 3);
    const status = wifi.coex_status_get_wrapper();
    const flex = wifi.coex_schm_flexible_period_get_wrapper();
    const dur = wifi.coex_event_duration_get_wrapper(9, &d);
    const phase_null = wifi.coex_schm_curr_phase_get_wrapper() == null;
    check(
        nulls == 1 and wifi.entries.len == 24 and req == 0 and status == 0 and flex == 1 and dur == 0 and
            d == 0xEEEE_EEEE and phase_null and fk.total() == 0,
        "wifi stub entries={d} null_entries={d} req={d} status={d} flexible_period_get={d} duration={d} untouched={d} phase_null={d} core_calls={d}",
        .{ wifi.entries.len, nulls, req, status, flex, dur, @intFromBool(d == 0xEEEE_EEEE), @intFromBool(phase_null), fk.total() },
    );
}

// ---------------------------------------------------------------------------
// ⑤ BLE 转发
// ---------------------------------------------------------------------------

fn checkBleForward() void {
    reset(.{});
    _ = boot();
    _ = ble.btdm_coex_init();
    _ = wifi.coex_wifi_channel_set_wrapper(6, 2);
    const reg = ble.wr_btdm_coex_schm_register_btdm_callback(cb(&someCb));
    const reg_type = record(.schm_register_callback).a0;
    var p: u8 = 0;
    var s: u8 = 0;
    const get = ble.wr_btdm_coex_wifi_channel_get(&p, &s);
    const ver = ble.wr_btdm_coex_version_get(null, null, null);
    const iso = ble.wr_btdm_coex_iso_start(null);
    check(
        reg == 0 and reg_type == 1 and get == 0 and p == 6 and s == 2 and ver == 0 and iso == 0 and
            fk.count(.iso_start) == 0 and fk.count(.version_get_value) == 0,
        "ble forward schm_cb_rc={d} schm_cb_type={d} channel_get_rc={d} channel=({d},{d}) version_get={d} iso_start={d} iso_forwarded={d}",
        .{ reg, reg_type, get, p, s, ver, iso, fk.count(.iso_start) },
    );
}

// ---------------------------------------------------------------------------
// ⑥ BLE 回调
// ---------------------------------------------------------------------------

fn checkBleCallbacks() void {
    const calls0 = glue.ble_start_calls;
    _ = ble.wr_btdm_coex_register_ble_cb(0, cb(&bleCb0));
    _ = ble.wr_btdm_coex_register_ble_cb(1, cb(&bleCb1));
    const stored0 = glue.bleCallback(0) == cb(&bleCb0);
    const stored1 = glue.bleCallback(1) == cb(&bleCb1);
    _ = ble.btdm_coex_enable();
    const after_alone = cb0_hits + cb1_hits;
    _ = wifi.coex_init_wrapper();
    _ = wifi.coex_enable_wrapper();
    const after_second = cb0_hits;
    wifi.coex_disable_wrapper();
    const after_drop = cb1_hits;
    check(
        stored0 and stored1 and after_alone == 0 and after_second == 1 and after_drop == 1 and
            fk.ble_cb[0] == @as(?*const anyopaque, @ptrCast(&glue.bleStartTrampoline)) and fk.ble_cb[1] == cb(&bleCb1) and
            glue.ble_start_calls - calls0 == after_second,
        "ble callbacks stored0={d} stored1={d} hits_after_ble_alone={d} cb0_after_2nd_enable={d} cb1_after_drop_to_1={d}",
        .{ @intFromBool(stored0), @intFromBool(stored1), after_alone, after_second, after_drop },
    );
}

// ---------------------------------------------------------------------------
// ⑦ 生命周期守卫
// ---------------------------------------------------------------------------

fn checkLifecycleGuards() void {
    reset(.{});
    _ = boot();
    const early_enable = wifi.coex_enable_wrapper(); // enable 早于 init
    wifi.coex_disable_wrapper(); // disable 早于 enable
    _ = wifi.coex_init_wrapper();
    _ = wifi.coex_enable_wrapper();
    const double_enable = wifi.coex_enable_wrapper(); // 重复 enable
    wifi.coex_deinit_wrapper(); // enable 期间 deinit
    const boot_again = if (glue.boot(hooks)) |_| false else |e| e == error.AlreadyBooted;
    check(
        early_enable == INVALID_STATE and double_enable == INVALID_STATE and boot_again and
            glue.rejected(.coex_enable_wrapper) == 2 and glue.rejected(.coex_disable_wrapper) == 1 and
            glue.rejected(.coex_deinit_wrapper) == 1 and glue.rejected(.boot) == 1 and
            lastErrorIs(error.AlreadyBooted) and
            fk.count(.init) == 1 and fk.count(.enable) == 1 and fk.count(.disable) == 0 and fk.count(.deinit) == 0 and
            glue.state().wifi == .enabled,
        "lifecycle early_enable={d} double_enable={d} boot_twice_rejected={d} rejected(enable/disable/deinit/boot)=({d}/{d}/{d}/{d}) core(init/enable/disable/deinit)=({d}/{d}/{d}/{d})",
        .{ early_enable, double_enable, @intFromBool(boot_again), glue.rejected(.coex_enable_wrapper), glue.rejected(.coex_disable_wrapper), glue.rejected(.coex_deinit_wrapper), glue.rejected(.boot), fk.count(.init), fk.count(.enable), fk.count(.disable), fk.count(.deinit) },
    );
}

// ---------------------------------------------------------------------------
// ⑧ 未启动
// ---------------------------------------------------------------------------

fn checkNotBooted() void {
    reset(.{});
    const chan = ble.wr_btdm_coex_wifi_channel_get(null, null);
    const req = wifi.coex_wifi_request_wrapper(1, 2, 3);
    const init = ble.btdm_coex_init();
    check(
        chan == -1 and req == 0 and init == 0 and fk.total() == 0 and
            lastErrorIs(error.NotBooted) and
            glue.rejected(.wr_btdm_coex_wifi_channel_get) == 1 and glue.rejected(.coex_wifi_request_wrapper) == 1 and
            glue.rejected(.btdm_coex_init) == 1,
        "not booted channel_get={d} request={d} init={d} core_calls={d} last_error=NotBooted rejected={d}/{d}/{d}",
        .{ chan, req, init, fk.total(), glue.rejected(.wr_btdm_coex_wifi_channel_get), glue.rejected(.coex_wifi_request_wrapper), glue.rejected(.btdm_coex_init) },
    );
}

// ---------------------------------------------------------------------------
// ⑨ IDF 全序
// ---------------------------------------------------------------------------

fn checkIdfOrder() void {
    reset(.{});
    const b = boot();
    const wi_ok = if (glue.wifiInit(null)) |_| true else |_| false;
    const blob_init = wifi.coex_init_wrapper();
    const bi = ble.btdm_coex_init();
    _ = ble.wr_btdm_coex_register_ble_cb(0, cb(&bleCb0));
    _ = ble.wr_btdm_coex_register_ble_cb(1, cb(&bleCb1));
    const be = ble.btdm_coex_enable();
    const cb0_after_ble = cb0_hits;
    const we = wifi.coex_enable_wrapper();
    const cb0_after_wifi = cb0_hits;
    ble.btdm_coex_disable();
    wifi.coex_disable_wrapper();
    wifi.coex_deinit_wrapper();
    ble.btdm_coex_deinit();
    const want = [_]fake.Call{
        .adapter_register, .pre_init,        .init,   .init,   .init,
        .register_ble_cb,  .register_ble_cb, .enable, .enable, .disable,
        .disable,          .deinit,
    };
    var order_ok = fk.total() == want.len;
    if (order_ok) {
        for (want, 0..) |c, i| {
            if (!(c == fk.at(i).call)) order_ok = false;
        }
    }
    check(
        b and wi_ok and blob_init == 0 and bi == 0 and be == 0 and we == 0 and order_ok and
            cb0_after_ble == 0 and cb0_after_wifi == 1 and cb1_hits == 1,
        "idf order boot={d} wifi_init_ok={d} rcs=(blob_init/ble_init/ble_enable/wifi_enable)=({d}/{d}/{d}/{d}) core_order_ok={d} calls={d} cb0(ble_enable/wifi_enable)=({d}/{d}) cb1={d}",
        .{ @intFromBool(b), @intFromBool(wi_ok), blob_init, bi, be, we, @intFromBool(order_ok), fk.total(), cb0_after_ble, cb0_after_wifi, cb1_hits },
    );
}

// ---------------------------------------------------------------------------
// ⑩ 核心失败透传
// ---------------------------------------------------------------------------

fn checkBootFailure() void {
    reset(.{});
    fk.rc[@backingInt(fake.Call.adapter_register)] = core.ESP_ERR_INVALID_ARG;
    const failed = if (glue.boot(hooks)) |_| false else |e| e == error.AdapterRegisterFailed;
    const req = wifi.coex_wifi_request_wrapper(1, 2, 3);
    check(
        failed and glue.state().phase() == .reset and glue.snapshot().last_core_rc == core.ESP_ERR_INVALID_ARG and
            fk.count(.pre_init) == 0 and req == 0 and glue.rejected(.coex_wifi_request_wrapper) == 1,
        "boot failure reported={d} core_rc={x} phase=reset={d} pre_init_calls={d} hook_degraded={d}",
        .{ @intFromBool(failed), @as(u32, @bitCast(glue.snapshot().last_core_rc)), @intFromBool(glue.state().phase() == .reset), fk.count(.pre_init), @intFromBool(req == 0) },
    );
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

fn runChecks() void {
    checkAdapter();
    if (checkBoot()) {
        checkWifiForward();
    } else {
        check(false, "wifi forward skipped: boot failed", .{});
    }
    checkWifiStub();
    checkBleForward();
    checkBleCallbacks();
    checkLifecycleGuards();
    checkNotBooted();
    checkIdfOrder();
    checkBootFailure();
}

pub fn run() bool {
    // 自检换掉胶水单例的核心；跑完还原，生产实例不受影响。
    const saved = glue.snapshot();
    defer glue.restore(saved);

    g_passed = 0;
    g_failed = 0;
    runChecks();

    log.line("read: core_slots={d} wifi_entries={d} ble_entries={d} adapter_bytes={d} hook_count={d}", .{
        core.slot_count, wifi.entries.len, ble.entries.len, @sizeOf(adapter.AdapterTable), glue.hook_count,
    });
    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
