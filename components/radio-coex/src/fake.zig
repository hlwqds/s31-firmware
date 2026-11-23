//! radio-coex：核心的记录型假实现（`libcoexist.a` + ROM 的行为模型）。
//!
//! 只给主机测试（`host_tests.zig`）与板侧自检（`selftest.zig`）用，生产构建不引用。
//! 两部分：
//!
//!   1. **记录**：每个入口的每次调用进一条定长日志（入口、三个原始参数、返回值），
//!      外加每入口的计数与核心调适配表钩子的计数；
//!   2. **行为模型**：生命周期与回调相关的入口照 `libcoexist.a` 的反汇编建模
//!      （`riscv32-esp-elf-objdump -dr libcoexist.a`；下面注释里的 `dis:` 指反汇编里的函数名），
//!      其余入口回可编排的定值（`rc` / `val`），这样"原样转发"能用互不相同的数逐项核对。
//!
//! 假核心与真核心的三处刻意不同（都为了不让测试跑飞）：
//!
//!   * 适配表没注册时，真核心的 `coex_pre_init` 解引用空的 `g_coa_funcs_p`；假核心回 ESP_FAIL；
//!   * `coex_register_ble_cb` 收到 0/1 以外的 type，真核心打印后死循环（`coex_core_register_ble_cb`
//!     末尾 `j .L92`）；假核心计一次 `bad_ble_cb_type` 并回 259；
//!   * ROM 的 `coex_schm_lock` 没有反汇编，假核心假设方案环境没初始化（`coex_pre_init` 没成功）时它失败。

const std = @import("std");

const adapter = @import("adapter.zig");
const coreif = @import("core.zig");

/// 与 `core.Core` 的槽位一一同名同序（下面的 comptime 断言钉死）。
pub const Call = enum(u8) {
    pre_init,
    init,
    deinit,
    enable,
    disable,
    adapter_register,
    version_get,
    version_get_value,
    status_get,
    wifi_request,
    wifi_release,
    wifi_channel_set,
    event_duration_get,
    pti_get,
    schm_status_bit_clear,
    schm_status_bit_set,
    schm_interval_set,
    schm_interval_get,
    schm_curr_period_get,
    schm_curr_phase_get,
    schm_process_restart,
    schm_register_callback,
    register_start_cb,
    wifi_register_update_lpclk_callback,
    schm_flexible_period_set,
    schm_flexible_period_get,
    schm_get_phase_by_idx,
    configure_iso_end_wifi_cb,
    wifi_channel_get,
    register_wifi_channel_change_callback,
    register_ble_cb,
    ble_idle_time_inform,
    iso_start,
    iso_stop,
    protect_frame_thres_get,
    iso_start_int_handle,
    iso_end_int_handle,
};

pub const call_count: usize = @typeInfo(Call).@"enum".field_names.len;

comptime {
    const cn = @typeInfo(Call).@"enum".field_names;
    const sn = @typeInfo(coreif.Core).@"struct".field_names;
    if (cn.len != sn.len) @compileError("fake.Call 与 core.Core 槽位数不一致");
    for (cn, sn) |a, b| {
        if (!std.mem.eql(u8, a, b)) @compileError("fake.Call 与 core.Core 的槽位名不一致: " ++ a ++ " vs " ++ b);
    }
}

/// 一次核心调用的记录：三个原始参数（指针按地址、无符号数零扩展、有符号数按位）与返回值。
pub const Record = struct {
    call: Call,
    a0: u64 = 0,
    a1: u64 = 0,
    a2: u64 = 0,
    ret: i64 = 0,
};

pub const log_len = 64;

/// 可编排的定值：非 `esp_err_t` 的返回值与出参。
pub const Val = struct {
    /// `coex_core_status_get`（ROM）的返回值，`coex_status_get` 在"位图外还有别人置了状态位"时回它
    status_get: u32 = 0,
    pti: u8 = 0,
    duration: u32 = 0,
    protect_frame_thres: u16 = 0,
    version: [:0]const u8 = "coex-fake",
};

pub const Fake = struct {
    // ---- 记录 ----
    log: [log_len]Record = undefined,
    n: usize = 0,
    dropped: u32 = 0,
    counts: [call_count]u32 = @splat(0),
    /// 每个入口的 esp_err_t / int 返回值；非 0 即故障注入。
    rc: [call_count]c_int = @splat(coreif.ESP_OK),
    val: Val = .{},
    /// 核心调适配表钩子的次数，下标 = 适配表字段下标（0 是 `_version`，不用）。
    hook_calls: [adapter.field_count]u32 = @splat(0),
    /// 每个适配表钩子第一次被调时的两个参数。
    hook_first: [adapter.field_count][2]u64 = @splat(.{ 0, 0 }),
    /// `coex_pre_init` 末尾调的 `coex_hw_timer_freq_set(分频, 周期)`。
    timer_freq: [2]u32 = .{ 0, 0 },

    // ---- libcoexist.a 的状态（反汇编实证，见 H 里各函数）----
    registered: ?*const adapter.AdapterTable = null,
    /// `coex_env.sem`
    sem: ?*anyopaque = null,
    /// `coex_schm_init()` 成功过
    schm_ready: bool = false,
    /// `coex_env` 的使能引用计数（u8，回绕）
    enable_count: u8 = 0,
    /// `coex_env+4`：1 = 已启动
    status: u32 = 0,
    /// `coex_env+12`
    start_cb: ?*const anyopaque = null,
    /// `coex_env+16/+20`
    ble_cb: [2]?*const anyopaque = .{ null, null },
    /// `coex_schm_env+52`（WIFI=0）/ `+20`（BT=1）
    schm_cb: [2]?*const anyopaque = .{ null, null },
    /// `coex_schm_env+28`
    wifi_channel_cb: ?*const anyopaque = null,
    /// `s_set_lpclk_source_cb`
    lpclk_cb: ?*const anyopaque = null,
    /// `coex_schm_env+24/+25`
    wifi_primary: u8 = 0,
    wifi_secondary: u8 = 0,
    /// `coex_schm_env+12`
    interval: u32 = 0,
    /// `coex_schm_env+58`
    flexible_period: u8 = 0,
    /// `coex_schm_env+6/+8/+10/+56/+60`：WIFI / BLE / BT / 外部 / 802.15.4 的状态字
    status_words: [5]u16 = @splat(0),
    /// 方案表：`n_phases` 个 4 字节相位，供 `curr_phase_get` / `get_phase_by_idx` 回"核心内部的指针"
    n_phases: u8 = 3,
    curr_phase: u8 = 0,
    phases: [8]u32 = .{ 0x1111_1111, 0x2222_2222, 0x3333_3333, 0, 0, 0, 0, 0 },

    // ---- 回调触发计数 ----
    start_cb_calls: u32 = 0,
    ble_cb_calls: [2]u32 = .{ 0, 0 },
    wifi_channel_cb_count: u32 = 0,
    wifi_channel_cb_args: [2]u8 = .{ 0, 0 },
    bad_ble_cb_type: u32 = 0,

    pub fn reset(self: *Fake) void {
        self.* = .{};
    }

    pub fn count(self: *const Fake, c: Call) u32 {
        return self.counts[@backingInt(c)];
    }

    /// 进日志的条数（不含被挤掉的）。
    pub fn total(self: *const Fake) usize {
        return self.n;
    }

    pub fn at(self: *const Fake, i: usize) Record {
        return self.log[i];
    }

    pub fn slice(self: *const Fake) []const Record {
        return self.log[0..self.n];
    }

    /// 该入口的第一次调用。
    pub fn first(self: *const Fake, c: Call) ?Record {
        for (self.slice()) |r| {
            if (r.call == c) return r;
        }
        return null;
    }

    /// 该入口的最近一次调用。
    pub fn last(self: *const Fake, c: Call) ?Record {
        var found: ?Record = null;
        for (self.slice()) |r| {
            if (r.call == c) found = r;
        }
        return found;
    }
};

var current: *Fake = undefined;

/// 选中一个 `Fake` 作为核心函数表的宿主，并把它清零。函数指针签名里没有上下文，只能这样。
pub fn select(f: *Fake) void {
    f.* = .{};
    current = f;
}

fn cur() *Fake {
    return current;
}

/// 把 `Fake` 包装成 `core.Core`。
pub fn core() coreif.Core {
    var c: coreif.Core = .{};
    inline for (@typeInfo(Call).@"enum".field_names) |name| {
        @field(c, name) = &@field(H, name);
    }
    return c;
}

// ---- 小工具 ----

fn addr(p: anytype) u64 {
    return switch (@typeInfo(@TypeOf(p))) {
        .optional => if (p) |q| @intFromPtr(q) else 0,
        .pointer => @intFromPtr(p),
        else => @compileError("addr: 不是指针"),
    };
}

fn bits(v: anytype) u64 {
    return if (@typeInfo(@TypeOf(v)).int.signedness == .signed)
        @bitCast(@as(i64, @intCast(v)))
    else
        @intCast(v);
}

fn iret(v: anytype) i64 {
    return if (@typeInfo(@TypeOf(v)).int.signedness == .signed)
        @intCast(v)
    else
        @intCast(bits(v));
}

fn rec(c: Call, a0: u64, a1: u64, a2: u64, ret: i64) void {
    const f = cur();
    f.counts[@backingInt(c)] += 1;
    if (f.n < log_len) {
        f.log[f.n] = .{ .call = c, .a0 = a0, .a1 = a1, .a2 = a2, .ret = ret };
        f.n += 1;
    } else {
        f.dropped += 1;
    }
}

/// 核心调了一次适配表钩子（`i` = 适配表字段下标）。
fn useHook(comptime name: []const u8, a0: u64, a1: u64) void {
    const i = adapter.indexOf(name);
    const f = cur();
    f.hook_calls[i] += 1;
    if (f.hook_calls[i] == 1) f.hook_first[i] = .{ a0, a1 };
}

fn voidFn(cb: *const anyopaque) *const fn () callconv(.c) void {
    return @ptrCast(@alignCast(cb));
}

fn intFn(cb: *const anyopaque) *const fn () callconv(.c) c_int {
    return @ptrCast(@alignCast(cb));
}

fn chanFn(cb: *const anyopaque) *const fn (u8, u8) callconv(.c) void {
    return @ptrCast(@alignCast(cb));
}

/// `coex_core_lock`（dis: coexist_core.o `coex_core_lock`）：信号量不存在 → 259；
/// 中断里 `_semphr_take_from_isr`（hptw 非零还要 `_task_yield_from_isr`），否则
/// `_semphr_take(sem, 0xffffffff)`；返回值不是 1 ⇒ -1，是 1 ⇒ 0。
fn lockCore() c_int {
    const f = cur();
    const sem = f.sem orelse return 259;
    const t = f.registered orelse return 259;
    useHook("_is_in_isr", 0, 0);
    const r: i32 = if (t._is_in_isr.?() != 0) blk: {
        var hptw: i32 = 0;
        const taken = t._semphr_take_from_isr.?(sem, &hptw);
        useHook("_semphr_take_from_isr", addr(sem), addr(&hptw));
        if (hptw != 0) {
            t._task_yield_from_isr.?();
            useHook("_task_yield_from_isr", 0, 0);
        }
        break :blk taken;
    } else blk: {
        const taken = t._semphr_take.?(sem, adapter.time_blocking);
        useHook("_semphr_take", addr(sem), adapter.time_blocking);
        break :blk taken;
    };
    return if (r == 1) 0 else -1;
}

fn unlockCore() void {
    const f = cur();
    const sem = f.sem orelse return;
    const t = f.registered orelse return;
    useHook("_is_in_isr", 0, 0);
    if (t._is_in_isr.?() != 0) {
        var hptw: i32 = 0;
        _ = t._semphr_give_from_isr.?(sem, &hptw);
        useHook("_semphr_give_from_isr", addr(sem), addr(&hptw));
        if (hptw != 0) t._task_yield_from_isr.?();
    } else {
        _ = t._semphr_give.?(sem);
        useHook("_semphr_give", addr(sem), 0);
    }
}

/// ROM 的 `coex_schm_lock`：未反汇编，假设方案环境没初始化时失败。
fn lockSchm() c_int {
    return if (cur().schm_ready) 0 else -1;
}

/// `coex_schm_status_bitmap_get`（dis: coexist_scheme.o）：第 i 位 = 第 i 个状态字非零。
fn statusBitmap(f: *const Fake) u32 {
    var bm: u32 = 0;
    for (f.status_words, 0..) |w, i| {
        if (w != 0) bm |= @as(u32, 1) << @intCast(i);
    }
    return bm;
}

// ---------------------------------------------------------------------------
// 37 个入口
// ---------------------------------------------------------------------------

const H = struct {
    fn pre_init() callconv(.c) c_int {
        const f = cur();
        const inj = f.rc[@backingInt(Call.pre_init)];
        if (inj != coreif.ESP_OK) {
            rec(.pre_init, 0, 0, 0, inj);
            return inj;
        }
        // dis: coexist_core.o `coex_core_pre_init`
        const t = f.registered orelse {
            rec(.pre_init, 0, 0, 0, coreif.ESP_FAIL);
            return coreif.ESP_FAIL;
        };
        if (f.sem == null) {
            useHook("_semphr_create", 1, 1);
            f.sem = t._semphr_create.?(1, 1);
            if (f.sem == null) {
                rec(.pre_init, 0, 0, 0, coreif.ESP_FAIL);
                return coreif.ESP_FAIL;
            }
        }
        f.schm_ready = true;
        if (lockCore() != 0) {
            rec(.pre_init, 0, 0, 0, -1);
            return -1;
        }
        useHook("_env_is_chip", 0, 0);
        const chip = t._env_is_chip.?();
        f.timer_freq = if (chip) .{ 4, 50 } else .{ 8, 1 };
        unlockCore();
        rec(.pre_init, 0, 0, 0, coreif.ESP_OK);
        return coreif.ESP_OK;
    }

    /// dis: `coex_core_init` 是 `li a0,0; ret`。
    fn init() callconv(.c) c_int {
        return simple(.init);
    }

    /// dis: `coex_core_deinit` 是 `li a0,0; ret`。
    fn deinit() callconv(.c) void {
        rec(.deinit, 0, 0, 0, 0);
    }

    /// dis: coexist_core.o `coex_core_enable`：锁失败 -1；计数 +1；`bltu 1,new` 成立（新计数 > 1，
    /// 即第二个射频也开了共存）才 status=1 → 解锁 → `start_cb()` → `ble_cb[0]()`；
    /// 新计数是 1 时只解锁返回，不调回调。
    fn enable() callconv(.c) c_int {
        const f = cur();
        const inj = f.rc[@backingInt(Call.enable)];
        if (inj != coreif.ESP_OK) {
            rec(.enable, 0, 0, 0, inj);
            return inj;
        }
        if (lockCore() != 0) {
            rec(.enable, 0, 0, 0, -1);
            return -1;
        }
        f.enable_count +%= 1;
        if (f.enable_count > 1) f.status = 1;
        unlockCore();
        rec(.enable, 0, 0, 0, coreif.ESP_OK);
        if (f.enable_count <= 1) return coreif.ESP_OK;
        if (f.start_cb) |cb| {
            f.start_cb_calls += 1;
            _ = intFn(cb)();
        }
        if (f.ble_cb[0]) |cb| {
            f.ble_cb_calls[0] += 1;
            voidFn(cb)();
        }
        return coreif.ESP_OK;
    }

    /// dis: coexist_core.o `coex_core_disable`：锁失败直接回；计数 -1，不等于 1 直接回；
    /// 降回 1：status=0 → 解锁 → `ble_cb[1]()`。
    fn disable() callconv(.c) void {
        const f = cur();
        if (lockCore() != 0) {
            rec(.disable, 0, 0, 0, -1);
            return;
        }
        f.enable_count -%= 1;
        if (f.enable_count != 1) {
            unlockCore();
            rec(.disable, 0, 0, 0, 0);
            return;
        }
        f.status = 0;
        unlockCore();
        rec(.disable, 0, 0, 0, 0);
        if (f.ble_cb[1]) |cb| {
            f.ble_cb_calls[1] += 1;
            voidFn(cb)();
        }
    }

    /// dis: coexist_api.o `esp_coex_adapter_register`：已注册 → 0（不再校验）；表空 → 258；
    /// `_version != 2` → 258；`_magic != 0xDEADBEAF` → 258；否则存指针，回 0。
    fn adapter_register(table: ?*const adapter.AdapterTable) callconv(.c) c_int {
        const f = cur();
        var rc = f.rc[@backingInt(Call.adapter_register)];
        if (rc == coreif.ESP_OK) {
            if (f.registered != null) {
                rc = coreif.ESP_OK;
            } else if (table == null) {
                rc = coreif.ESP_ERR_INVALID_ARG;
            } else if (table.?._version != adapter.version) {
                rc = coreif.ESP_ERR_INVALID_ARG;
            } else if (table.?._magic != adapter.magic) {
                rc = coreif.ESP_ERR_INVALID_ARG;
            } else {
                f.registered = table;
            }
        }
        rec(.adapter_register, addr(table), 0, 0, rc);
        return rc;
    }

    fn version_get() callconv(.c) ?[*:0]const u8 {
        const f = cur();
        rec(.version_get, 0, 0, 0, iret(addr(f.val.version.ptr)));
        return f.val.version.ptr;
    }

    /// dis: coexist_api.o `coex_version_get_value`：出参空 → 258；否则写 {2, 0, 0}，回 0。
    fn version_get_value(v: ?*coreif.Version) callconv(.c) c_int {
        const out = v orelse {
            rec(.version_get_value, 0, 0, 0, coreif.ESP_ERR_INVALID_ARG);
            return coreif.ESP_ERR_INVALID_ARG;
        };
        out.* = .{ .major = 2, .minor = 0, .patch = 0 };
        rec(.version_get_value, addr(out), 0, 0, coreif.ESP_OK);
        return coreif.ESP_OK;
    }

    /// dis: coexist_api.o `coex_status_get`：`(~bitmap & status_bitmap) != 0` 才回
    /// `coex_core_status_get()`，否则 0。
    fn status_get(bitmap: u8) callconv(.c) u32 {
        const f = cur();
        const r: u32 = if ((~@as(u32, bitmap) & statusBitmap(f)) != 0) f.val.status_get else 0;
        rec(.status_get, bitmap, 0, 0, r);
        return r;
    }

    fn wifi_request(event: u32, latency: u32, duration: u32) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.wifi_request)];
        rec(.wifi_request, event, latency, duration, rc);
        return rc;
    }

    fn wifi_release(event: u32) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.wifi_release)];
        rec(.wifi_release, event, 0, 0, rc);
        return rc;
    }

    /// dis: coexist_scheme.o `coex_wifi_channel_set`：锁失败 -1；存主/辅信道 → 解锁 →
    /// 有登记信道变化回调就调 `cb(primary, secondary)`；回 0。
    fn wifi_channel_set(primary: u8, secondary: u8) callconv(.c) c_int {
        const f = cur();
        rec(.wifi_channel_set, primary, secondary, 0, if (lockSchm() != 0) -1 else 0);
        if (lockSchm() != 0) return -1;
        f.wifi_primary = primary;
        f.wifi_secondary = secondary;
        if (f.wifi_channel_cb) |cb| {
            f.wifi_channel_cb_count += 1;
            f.wifi_channel_cb_args = .{ primary, secondary };
            chanFn(cb)(primary, secondary);
        }
        return 0;
    }

    /// dis: coexist_core.o `coex_core_event_duration_get`：出参空 → -1（不写）。
    fn event_duration_get(event: u32, duration: ?*u32) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.event_duration_get)];
        const out = duration orelse {
            rec(.event_duration_get, event, 0, 0, -1);
            return -1;
        };
        out.* = f.val.duration;
        rec(.event_duration_get, event, addr(out), 0, rc);
        return rc;
    }

    /// dis: coexist_core.o `coex_core_pti_get`：出参空 → 258（不写）。
    fn pti_get(event: u32, pti: ?*u8) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.pti_get)];
        const out = pti orelse {
            rec(.pti_get, event, 0, 0, coreif.ESP_ERR_INVALID_ARG);
            return coreif.ESP_ERR_INVALID_ARG;
        };
        out.* = f.val.pti;
        rec(.pti_get, event, addr(out), 0, rc);
        return rc;
    }

    /// dis: coexist_scheme.o `coex_schm_status_bit_set`：type > 4 不理；否则该状态字按位或上
    /// status 的低 16 位。
    fn schm_status_bit_set(st_type: u32, status: u32) callconv(.c) void {
        const f = cur();
        const locked = lockSchm() == 0;
        rec(.schm_status_bit_set, st_type, status, 0, if (locked) 0 else -1);
        if (!locked or st_type > 4) return;
        f.status_words[@intCast(st_type)] |= @truncate(status);
    }

    fn schm_status_bit_clear(st_type: u32, status: u32) callconv(.c) void {
        const f = cur();
        const locked = lockSchm() == 0;
        rec(.schm_status_bit_clear, st_type, status, 0, if (locked) 0 else -1);
        if (!locked or st_type > 4) return;
        f.status_words[@intCast(st_type)] &= ~@as(u16, @truncate(status));
    }

    /// dis: coexist_scheme.o `coex_schm_interval_set`：锁失败 -1；存 interval，回 0。
    fn schm_interval_set(interval: u32) callconv(.c) c_int {
        const f = cur();
        if (lockSchm() != 0) {
            rec(.schm_interval_set, interval, 0, 0, -1);
            return -1;
        }
        f.interval = interval;
        rec(.schm_interval_set, interval, 0, 0, 0);
        return 0;
    }

    /// dis: `coex_schm_interval_get`：锁失败回 0。
    fn schm_interval_get() callconv(.c) u32 {
        const f = cur();
        const r: u32 = if (lockSchm() == 0) f.interval else 0;
        rec(.schm_interval_get, 0, 0, 0, r);
        return r;
    }

    /// dis: `coex_schm_curr_period_get`：锁失败回 1；否则方案表的相位数。
    fn schm_curr_period_get() callconv(.c) u8 {
        const f = cur();
        const r: u8 = if (lockSchm() == 0) f.n_phases else 1;
        rec(.schm_curr_period_get, 0, 0, 0, r);
        return r;
    }

    /// dis: `coex_schm_curr_phase_get`：锁失败或当前相位号越界回 NULL；否则方案表里那一项的地址。
    fn schm_curr_phase_get() callconv(.c) ?*anyopaque {
        const f = cur();
        const r: ?*anyopaque = if (lockSchm() != 0 or f.curr_phase >= f.n_phases)
            null
        else
            @ptrCast(&f.phases[f.curr_phase]);
        rec(.schm_curr_phase_get, 0, 0, 0, iret(addr(r)));
        return r;
    }

    fn schm_process_restart() callconv(.c) c_int {
        return simple(.schm_process_restart);
    }

    /// dis: coexist_scheme.o `coex_schm_register_callback`：锁失败 -1；type 0 → WIFI 槽、
    /// 1 → BT 槽，回 0；其它 type 回 -1。
    fn schm_register_callback(cb_type: c_int, cb: ?*const anyopaque) callconv(.c) c_int {
        const f = cur();
        if (lockSchm() != 0) {
            rec(.schm_register_callback, bits(cb_type), addr(cb), 0, -1);
            return -1;
        }
        const rc: c_int = switch (cb_type) {
            0, 1 => blk: {
                f.schm_cb[@intCast(cb_type)] = cb;
                break :blk 0;
            },
            else => -1,
        };
        rec(.schm_register_callback, bits(cb_type), addr(cb), 0, rc);
        return rc;
    }

    /// dis: coexist_core.o `coex_core_register_start_cb`：锁失败 259；存 `coex_env+12`；回 0。
    fn register_start_cb(cb: ?*const anyopaque) callconv(.c) c_int {
        const f = cur();
        if (lockCore() != 0) {
            rec(.register_start_cb, addr(cb), 0, 0, 259);
            return 259;
        }
        f.start_cb = cb;
        unlockCore();
        rec(.register_start_cb, addr(cb), 0, 0, 0);
        return 0;
    }

    fn wifi_register_update_lpclk_callback(cb: ?*const anyopaque) callconv(.c) void {
        const f = cur();
        f.lpclk_cb = cb;
        rec(.wifi_register_update_lpclk_callback, addr(cb), 0, 0, 0);
    }

    /// dis: coexist_scheme.o `coex_schm_flexible_period_set`：锁失败 -1。
    fn schm_flexible_period_set(period: u8) callconv(.c) c_int {
        const f = cur();
        if (lockSchm() != 0) {
            rec(.schm_flexible_period_set, period, 0, 0, -1);
            return -1;
        }
        f.flexible_period = period;
        rec(.schm_flexible_period_set, period, 0, 0, 0);
        return 0;
    }

    fn schm_flexible_period_get() callconv(.c) u8 {
        const f = cur();
        rec(.schm_flexible_period_get, 0, 0, 0, f.flexible_period);
        return f.flexible_period;
    }

    /// dis: coexist_scheme.o `coex_schm_get_phase_by_idx`：锁失败或 idx ≥ 相位数回 NULL；
    /// 否则方案表第 idx 项的地址。负数 idx 真核心会算出表前的地址，假核心回 NULL。
    fn schm_get_phase_by_idx(idx: c_int) callconv(.c) ?*anyopaque {
        const f = cur();
        const r: ?*anyopaque = if (lockSchm() != 0 or idx < 0 or idx >= f.n_phases)
            null
        else
            @ptrCast(&f.phases[@intCast(idx)]);
        rec(.schm_get_phase_by_idx, bits(idx), 0, 0, iret(addr(r)));
        return r;
    }

    fn configure_iso_end_wifi_cb(is_register: bool, cb: ?*const anyopaque) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.configure_iso_end_wifi_cb)];
        rec(.configure_iso_end_wifi_cb, @intFromBool(is_register), addr(cb), 0, rc);
        return rc;
    }

    /// dis: coexist_scheme.o `coex_wifi_channel_get`：任一出参空 → 258（不写）；锁失败 -1；
    /// 否则写出主/辅信道，回 0。
    fn wifi_channel_get(primary: ?*u8, secondary: ?*u8) callconv(.c) c_int {
        const f = cur();
        const p = primary orelse {
            rec(.wifi_channel_get, 0, addr(secondary), 0, coreif.ESP_ERR_INVALID_ARG);
            return coreif.ESP_ERR_INVALID_ARG;
        };
        const s = secondary orelse {
            rec(.wifi_channel_get, addr(p), 0, 0, coreif.ESP_ERR_INVALID_ARG);
            return coreif.ESP_ERR_INVALID_ARG;
        };
        if (lockSchm() != 0) {
            rec(.wifi_channel_get, addr(p), addr(s), 0, -1);
            return -1;
        }
        p.* = f.wifi_primary;
        s.* = f.wifi_secondary;
        rec(.wifi_channel_get, addr(p), addr(s), 0, 0);
        return 0;
    }

    /// dis: coexist_scheme.o `coex_register_wifi_channel_change_callback`：锁失败 -1；存，回 0。
    fn register_wifi_channel_change_callback(cb: ?*const anyopaque) callconv(.c) c_int {
        const f = cur();
        if (lockSchm() != 0) {
            rec(.register_wifi_channel_change_callback, addr(cb), 0, 0, -1);
            return -1;
        }
        f.wifi_channel_cb = cb;
        rec(.register_wifi_channel_change_callback, addr(cb), 0, 0, 0);
        return 0;
    }

    /// dis: coexist_core.o `coex_core_register_ble_cb`：锁失败 259；type 0 → `coex_env+16`、
    /// 1 → `coex_env+20`，回 0；其它 type 见文件头的刻意差异。
    fn register_ble_cb(cb_type: u8, func: ?*const anyopaque) callconv(.c) c_int {
        const f = cur();
        if (lockCore() != 0) {
            rec(.register_ble_cb, cb_type, addr(func), 0, 259);
            return 259;
        }
        const rc: c_int = switch (cb_type) {
            0, 1 => blk: {
                f.ble_cb[cb_type] = func;
                break :blk 0;
            },
            else => blk: {
                f.bad_ble_cb_type += 1;
                break :blk 259;
            },
        };
        unlockCore();
        rec(.register_ble_cb, cb_type, addr(func), 0, rc);
        return rc;
    }

    fn ble_idle_time_inform(start_offset: u32, duration: u32) callconv(.c) void {
        rec(.ble_idle_time_inform, start_offset, duration, 0, 0);
    }

    fn iso_start(info: ?*anyopaque) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.iso_start)];
        rec(.iso_start, addr(info), 0, 0, rc);
        return rc;
    }

    fn iso_stop(handle: u16) callconv(.c) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(Call.iso_stop)];
        rec(.iso_stop, handle, 0, 0, rc);
        return rc;
    }

    fn protect_frame_thres_get() callconv(.c) u16 {
        const f = cur();
        rec(.protect_frame_thres_get, 0, 0, 0, f.val.protect_frame_thres);
        return f.val.protect_frame_thres;
    }

    fn iso_start_int_handle(handle: u16, duration: u32) callconv(.c) void {
        rec(.iso_start_int_handle, handle, duration, 0, 0);
    }

    fn iso_end_int_handle(handle: u16, duration: u32) callconv(.c) void {
        rec(.iso_end_int_handle, handle, duration, 0, 0);
    }

    /// 只记录并回 `rc` 里编排的值（真核心这里是空操作或直接转调）。
    fn simple(c: Call) c_int {
        const f = cur();
        const rc = f.rc[@backingInt(c)];
        rec(c, 0, 0, 0, rc);
        return rc;
    }
};
