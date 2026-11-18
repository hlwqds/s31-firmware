//! posix-compat：`clock_gettime` / `nanosleep` / `usleep` / `sleep`。
//!
//! 时钟与睡眠都由**注入**决定（`bind`）：板上接 tick/`hw.nowUs`，主机测试接假时钟。
//! 这样本模块没有全局硬件依赖，`zig build test` 能完整覆盖换算与边界。
//!
//! 只支持 `CLOCK_MONOTONIC` 与 `CLOCK_REALTIME`（后者同样单调，因为我们没有墙上时钟源）：
//! 板子上没有校准过的 RTC，返回一个假的实时时间比返回错误更危险，所以 `CLOCK_REALTIME`
//! 明确返回 `EINVAL`，让调用方立刻发现「这里没有墙钟」。

const std = @import("std");
const errno = @import("errno.zig");

pub const CLOCK_REALTIME: c_int = 0;
pub const CLOCK_MONOTONIC: c_int = 1;

/// POSIX 的 `struct timespec`（LP64 布局：两个 i64）。
pub const timespec = extern struct {
    tv_sec: i64 = 0,
    tv_nsec: i64 = 0,
};

pub const ns_per_sec: u64 = 1_000_000_000;

/// 注入点。
pub const Env = struct {
    /// 单调时钟，返回**纳秒**。
    now_ns: *const fn () u64,
    /// 睡至少 `ns` 纳秒。
    sleep_ns: *const fn (u64) void,
    /// 时钟分辨率（纳秒），`clock_getres` 用。
    res_ns: u64,
};

var env: ?Env = null;

pub fn bind(e: Env) void {
    env = e;
}

pub fn unbind() void {
    env = null;
}

fn need() ?Env {
    return env orelse {
        errno.set(errno.ENOSYS);
        return null;
    };
}

/// 纳秒 ⇄ `timespec`。负数或超过 u64 的输入在调用侧已被拒绝。
pub fn toTimespec(ns: u64) timespec {
    return .{
        .tv_sec = @intCast(ns / ns_per_sec),
        .tv_nsec = @intCast(ns % ns_per_sec),
    };
}

/// `timespec` → 纳秒。`tv_nsec` 越界（<0 或 ≥1e9）返回 null —— POSIX 要求调用方保证合法。
pub fn fromTimespec(ts: timespec) ?u64 {
    if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= @as(i64, @intCast(ns_per_sec))) return null;
    const sec: u64 = @intCast(ts.tv_sec);
    const nsec: u64 = @intCast(ts.tv_nsec);
    return sec * ns_per_sec + nsec;
}

pub fn clock_gettime(clock_id: c_int, ts: *timespec) c_int {
    if (clock_id != CLOCK_MONOTONIC) {
        // CLOCK_REALTIME 见文件头：没有墙钟，明确拒绝而不是返回单调时间冒充
        errno.set(errno.EINVAL);
        return -1;
    }
    const e = need() orelse return -1;
    ts.* = toTimespec(e.now_ns());
    return 0;
}

pub fn clock_getres(clock_id: c_int, ts: *timespec) c_int {
    if (clock_id != CLOCK_MONOTONIC) {
        errno.set(errno.EINVAL);
        return -1;
    }
    const e = need() orelse return -1;
    ts.* = toTimespec(e.res_ns);
    return 0;
}

/// 睡 `req`。`rem` 只在被信号打断时才有意义（我们没有信号，所以永远写 0）。
pub fn nanosleep(req: *const timespec, rem: ?*timespec) c_int {
    const want = fromTimespec(req.*) orelse {
        errno.set(errno.EINVAL);
        return -1;
    };
    const e = need() orelse return -1;
    if (rem) |r| r.* = .{};
    if (want == 0) return 0;
    e.sleep_ns(want);
    return 0;
}

pub fn usleep(usec: u32) c_int {
    const e = need() orelse return -1;
    if (usec == 0) return 0;
    e.sleep_ns(@as(u64, usec) * 1_000);
    return 0;
}

pub fn sleep(seconds: u32) c_int {
    const e = need() orelse return -1;
    if (seconds == 0) return 0;
    e.sleep_ns(@as(u64, seconds) * ns_per_sec);
    return 0;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// 假环境：时钟可推进，睡眠只记账不真睡。
const Fake = struct {
    var now: u64 = 0;
    var slept: u64 = 0;
    fn nowNs() u64 {
        return now;
    }
    fn sleepNs(ns: u64) void {
        slept += ns;
        now += ns; // 与真实环境一致：睡完时钟前进
    }
};

fn bindFake() void {
    Fake.now = 1_234_567_890;
    Fake.slept = 0;
    bind(.{ .now_ns = Fake.nowNs, .sleep_ns = Fake.sleepNs, .res_ns = 1_000_000 });
}

test "time: timespec 往返（含边界）" {
    const t = toTimespec(1_234_567_890);
    try testing.expectEqual(@as(i64, 1), t.tv_sec);
    try testing.expectEqual(@as(i64, 234_567_890), t.tv_nsec);
    try testing.expectEqual(@as(u64, 1_234_567_890), fromTimespec(t).?);

    try testing.expectEqual(@as(u64, 0), fromTimespec(.{}).?);
    // tv_nsec 越界的两种
    try testing.expect(fromTimespec(.{ .tv_nsec = -1 }) == null);
    try testing.expect(fromTimespec(.{ .tv_nsec = 1_000_000_000 }) == null);
    // tv_sec 为负
    try testing.expect(fromTimespec(.{ .tv_sec = -1 }) == null);
}

test "time: clock_gettime 只认 MONOTONIC，REALTIME 明确拒绝" {
    bindFake();
    defer unbind();
    var ts: timespec = .{};
    try testing.expectEqual(@as(c_int, 0), clock_gettime(CLOCK_MONOTONIC, &ts));
    try testing.expectEqual(Fake.now, fromTimespec(ts).?);

    try testing.expectEqual(@as(c_int, -1), clock_gettime(CLOCK_REALTIME, &ts));
    try testing.expectEqual(errno.EINVAL, errno.get());

    var res: timespec = .{};
    try testing.expectEqual(@as(c_int, 0), clock_getres(CLOCK_MONOTONIC, &res));
    try testing.expectEqual(@as(u64, 1_000_000), fromTimespec(res).?);
}

test "time: nanosleep 按请求睡，rem 清零，零时长不调睡眠" {
    bindFake();
    defer unbind();

    const one_ms: timespec = .{ .tv_sec = 0, .tv_nsec = 1_000_000 };
    var rem: timespec = .{ .tv_sec = 9, .tv_nsec = 9 };
    try testing.expectEqual(@as(c_int, 0), nanosleep(&one_ms, &rem));
    try testing.expectEqual(@as(u64, 1_000_000), Fake.slept);
    try testing.expectEqual(@as(i64, 0), rem.tv_sec);
    try testing.expectEqual(@as(i64, 0), rem.tv_nsec);

    // 零时长：不碰 sleeper
    const before = Fake.slept;
    const zero: timespec = .{};
    try testing.expectEqual(@as(c_int, 0), nanosleep(&zero, null));
    try testing.expectEqual(before, Fake.slept);

    // 非法输入
    const bad: timespec = .{ .tv_nsec = 2_000_000_000 };
    try testing.expectEqual(@as(c_int, -1), nanosleep(&bad, null));
    try testing.expectEqual(errno.EINVAL, errno.get());
}

test "time: usleep/sleep 换算与未绑定时的 ENOSYS" {
    bindFake();
    try testing.expectEqual(@as(c_int, 0), usleep(2_500));
    try testing.expectEqual(@as(u64, 2_500_000), Fake.slept);
    Fake.slept = 0;
    try testing.expectEqual(@as(c_int, 0), sleep(1));
    try testing.expectEqual(@as(u64, ns_per_sec), Fake.slept);

    unbind();
    var ts: timespec = .{};
    try testing.expectEqual(@as(c_int, -1), clock_gettime(CLOCK_MONOTONIC, &ts));
    try testing.expectEqual(errno.ENOSYS, errno.get());
    try testing.expectEqual(@as(c_int, -1), usleep(1));
    try testing.expectEqual(errno.ENOSYS, errno.get());
}
