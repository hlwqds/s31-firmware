//! wifi-blobs：主机侧单测入口。
//!
//! 这个组件**没有逻辑**可测——它是 R3 链接实验的适配面桩。主机测试存在的意义是：
//!
//!   1. `adapter.zig` 被真正编译（导出/符号名写错会在这里炸，而不是等上板）；
//!   2. `probe()` 用 `@extern` 引用的 `esp_wifi_80211_tx` 在主机侧有定义，
//!      否则链接期就是 undefined——下面那个 `pub export` 就是替身。
//!
//! 真机上这个符号由 `libnet80211.a` 提供；主机侧只验证"引用路径成立"。

const std = @import("std");
const adapter = @import("adapter.zig");
const osi = @import("osi.zig");
const impl = @import("osi_impl.zig");

test {
    _ = adapter;
    _ = osi;
    _ = impl;
}

test "wifi-blobs: probe 解析到替身符号的地址" {
    try std.testing.expect(adapter.probe() != 0);
}

test "wifi-blobs: osi 表填好驱动会校验的 version/magic" {
    const tbl = osi.empty;
    try std.testing.expectEqual(@as(i32, 0x0000_0009), tbl._version);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEAD_BEAF))), tbl._magic);
}

test "wifi-blobs: ROM 槽位地址与 install 的 off-target 行为" {
    try std.testing.expectEqual(@as(usize, 0x2F07_FF44), osi.slot_addr);
    // 主机上没有那块 ROM RAM：install 必须是 no-op，不能真的去写 0x2f07ff44。
    try std.testing.expectEqual(@as(?*const osi.Osi, null), osi.install(&osi.empty));
}

test "wifi-blobs: osi 表字段数与首尾字段固定" {
    // 字段数是 IDF 头经 sdkconfig 预处理后的结果；改了 IDF 版本就要重新生成 osi.zig。
    try std.testing.expectEqual(@as(usize, 128), osi.field_count);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(osi.Osi, "_version"));
    try std.testing.expectEqual(@as(usize, osi.field_count - 1), @offsetOf(osi.Osi, "_magic") / @sizeOf(usize));
}

/// 主机侧替身：`adapter.probe()` 引用这个名字，链接必须能解析。
pub export fn esp_wifi_80211_tx() callconv(.c) void {}

test "osi_impl: 分配器对齐、释放合并、耗尽" {
    var buf: [4096]u8 align(16) = undefined;
    var arena: impl.Arena = .{};
    arena.init(&buf);
    try std.testing.expect(arena.bytes_total > 3000);

    const a = arena.alloc(64, @alignOf(usize)) orelse return error.OutOfMemory;
    const b = arena.alloc(128, @alignOf(usize)) orelse return error.OutOfMemory;
    try std.testing.expect(@intFromPtr(a) != @intFromPtr(b));
    // 写满确认不越界
    @memset(a[0..64], 0xaa);
    @memset(b[0..128], 0xbb);

    arena.free(a);
    arena.free(b);
    // 释放后应能再拿到同样大的块（合并生效）
    const c = arena.alloc(128, @alignOf(usize)) orelse return error.OutOfMemory;
    try std.testing.expect(@intFromPtr(c) != 0);
    arena.free(c);

    // 耗尽：要一块比总量还大的
    try std.testing.expectEqual(@as(?[*]u8, null), arena.alloc(arena.bytes_total + 16, @alignOf(usize)));
}

test "osi_impl: realloc 保留内容" {
    var buf: [2048]u8 align(16) = undefined;
    var arena: impl.Arena = .{};
    arena.init(&buf);
    const a = arena.alloc(32, @alignOf(usize)) orelse return error.OutOfMemory;
    for (0..32) |i| a[i] = @intCast(i);
    const b = arena.realloc(a, 200) orelse return error.OutOfMemory;
    for (0..32) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), b[i]);
    arena.free(b);
}

test "osi_impl: 信号量按 FreeRTOS 约定返回 1/0，无限阻塞被拒绝并计数" {
    var s: impl.Semphr = .{ .count = 1, .max = 2 };
    try std.testing.expectEqual(@as(i32, 1), s.take(0));
    try std.testing.expectEqual(@as(i32, 0), s.take(0)); // 空、非阻塞 → 0
    const before = impl.blocking_refused;
    try std.testing.expectEqual(@as(i32, 0), s.take(impl.time_blocking)); // 无限阻塞 → 有意拒绝
    try std.testing.expectEqual(before + 1, impl.blocking_refused);
    try std.testing.expectEqual(@as(i32, 1), s.give());
    try std.testing.expectEqual(@as(i32, 1), s.give());
    try std.testing.expectEqual(@as(i32, 0), s.give()); // 已满 → 0
}

test "osi_impl: 队列环绕与满/空" {
    var storage: [impl.Queue.bytesNeeded(4, 3)]u8 align(8) = undefined;
    const q: *impl.Queue = @ptrCast(&storage);
    q.* = .{ .item_size = 4, .cap = 3 };
    var out: [4]u8 = undefined;

    try std.testing.expectEqual(@as(i32, 0), q.recv(&out, 0)); // 空
    for (0..3) |i| {
        const item = [4]u8{ @intCast(i), 0, 0, 0 };
        try std.testing.expectEqual(@as(i32, 1), q.send(&item, 0));
    }
    try std.testing.expectEqual(@as(i32, 0), q.send(&[4]u8{ 9, 9, 9, 9 }, 0)); // 满
    try std.testing.expectEqual(@as(u32, 3), q.msgWaiting());
    for (0..3) |i| {
        try std.testing.expectEqual(@as(i32, 1), q.recv(&out, 0));
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[0]);
    }
    try std.testing.expectEqual(@as(i32, 0), q.recv(&out, 0)); // 又空

    // 队首插入
    try std.testing.expectEqual(@as(i32, 1), q.sendFront(&[4]u8{ 7, 0, 0, 0 }));
    try std.testing.expectEqual(@as(i32, 1), q.recv(&out, 0));
    try std.testing.expectEqual(@as(u8, 7), out[0]);
}

test "osi_impl: event_post 用 esp_event 约定（成功=0/失败=-1）" {
    const before = impl.events_dropped;
    try std.testing.expectEqual(@as(i32, -1), impl.eventPost());
    try std.testing.expectEqual(before + 1, impl.events_dropped);
}

test "osi_impl: 互斥在单线程下是空操作" {
    var m: impl.Mutex = .{};
    m.locked = true;
    m.locked = false;
    try std.testing.expect(!m.locked);
}

test "osi_impl: 表里已实现的钩子非空，未实现的是 null" {
    var buf: [8192]u8 align(16) = undefined;
    impl.initArena(&buf);
    const tbl = impl.makeTable();
    try std.testing.expectEqual(@as(i32, 0x0000_0009), tbl._version);
    inline for (.{ "_malloc", "_free", "_semphr_create", "_semphr_take", "_semphr_give", "_mutex_lock", "_mutex_unlock", "_queue_create", "_queue_send", "_queue_recv" }) |name| {
        try std.testing.expect(@field(tbl, name) != null);
    }
    // 没实现：PHY/NVS/日志这些还留着 null，调用即崩（好过静默错值）
    try std.testing.expectEqual(@as(?*const anyopaque, null), tbl._timer_arm);
    try std.testing.expectEqual(@as(?*const anyopaque, null), tbl._coex_init);
}

test "osi_impl: 通过表指针调用分配/信号量/队列（C 调用约定）" {
    var buf: [8192]u8 align(16) = undefined;
    impl.initArena(&buf);
    const tbl = impl.makeTable();

    const malloc_fn: *const fn (usize) callconv(.c) ?*anyopaque = @ptrCast(tbl._malloc.?);
    const free_fn: *const fn (?*anyopaque) callconv(.c) void = @ptrCast(tbl._free.?);
    const sem_create: *const fn (u32, u32) callconv(.c) ?*anyopaque = @ptrCast(tbl._semphr_create.?);
    const sem_take: *const fn (?*anyopaque, u32) callconv(.c) i32 = @ptrCast(tbl._semphr_take.?);
    const sem_give: *const fn (?*anyopaque) callconv(.c) i32 = @ptrCast(tbl._semphr_give.?);
    const q_create: *const fn (u32, u32) callconv(.c) ?*anyopaque = @ptrCast(tbl._queue_create.?);
    const q_send: *const fn (?*anyopaque, ?*const anyopaque, u32) callconv(.c) i32 = @ptrCast(tbl._queue_send.?);
    const q_recv: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) i32 = @ptrCast(tbl._queue_recv.?);

    const p = malloc_fn(64) orelse return error.OutOfMemory;
    @memset(@as([*]u8, @ptrCast(p))[0..64], 0x5a);
    free_fn(p);

    const s = sem_create(1, 1) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(i32, 1), sem_take(s, 0));
    try std.testing.expectEqual(@as(i32, 0), sem_take(s, 0));
    try std.testing.expectEqual(@as(i32, 1), sem_give(s));

    const q = q_create(4, 4) orelse return error.OutOfMemory;
    var item = [4]u8{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(i32, 1), q_send(q, &item, 0));
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 1), q_recv(q, &out, 0));
    try std.testing.expectEqualSlices(u8, &item, &out);
}

test "osi_impl: 中断/任务类是可观测的空操作，计数从 0 起" {
    var buf: [4096]u8 align(16) = undefined;
    impl.initArena(&buf);
    const tbl = impl.makeTable();
    try std.testing.expect(tbl._set_intr != null);
    try std.testing.expect(tbl._ints_on != null);
    try std.testing.expect(tbl._task_get_current_task != null);

    const before = impl.calls;
    const set_intr: *const fn (i32, u32, u32, i32) callconv(.c) void = @ptrCast(tbl._set_intr.?);
    const ints_on: *const fn (u32) callconv(.c) void = @ptrCast(tbl._ints_on.?);
    const is_from_isr: *const fn () callconv(.c) bool = @ptrCast(tbl._is_from_isr.?);
    set_intr(0, 1, 2, 3);
    ints_on(0xff);
    try std.testing.expectEqual(before.set_intr + 1, impl.calls.set_intr);
    try std.testing.expectEqual(before.ints_on + 1, impl.calls.ints_on);
    try std.testing.expect(!is_from_isr());
}

test "osi_impl: implemented + unimplemented 恰好覆盖 128 个字段" {
    try std.testing.expectEqual(@as(usize, 128), impl.implemented.len + impl.unimplemented.len);
    try std.testing.expectEqual(@as(usize, 52), impl.implemented.len); // 21 原语 + 13 中断/任务 + 6 时间/随机/MAC + 12 NVS
}

var test_now_us: u64 = 1_234_567;
var test_mac: [6]u8 = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 };
fn testNowUs() u64 {
    return test_now_us;
}
fn testFillRandom(dst: []u8) void {
    for (dst, 0..) |*b, i| b.* = @intCast(0xa0 + (i & 0x0f));
}
fn testMac() [6]u8 {
    return test_mac;
}

test "osi_impl: 时间/随机/MAC 走注入钩子" {
    var buf: [4096]u8 align(16) = undefined;
    impl.initArena(&buf);
    impl.setHooks(.{ .now_us = &testNowUs, .fill_random = &testFillRandom, .mac = &testMac });
    const tbl = impl.makeTable();

    const get_time: *const fn () callconv(.c) i64 = @ptrCast(tbl._esp_timer_get_time.?);
    const log_ts: *const fn () callconv(.c) u32 = @ptrCast(tbl._log_timestamp.?);
    const get_random: *const fn (?[*]u8, usize) callconv(.c) c_int = @ptrCast(tbl._get_random.?);
    const read_mac: *const fn (?[*]u8, c_uint) callconv(.c) c_int = @ptrCast(tbl._read_mac.?);

    try std.testing.expectEqual(@as(i64, 1_234_567), get_time());
    try std.testing.expectEqual(@as(u32, 1234), log_ts());

    var rnd: [8]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), get_random(&rnd, rnd.len));
    try std.testing.expectEqual(@as(u8, 0xa0), rnd[0]);
    try std.testing.expectEqual(@as(u8, 0xa7), rnd[7]);

    var mac: [6]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), read_mac(&mac, 0));
    try std.testing.expectEqualSlices(u8, &test_mac, &mac);

    impl.setHooks(.{}); // 还原，避免影响别的用例
}

test "osi_impl: NVS 经表指针可读写（RAM 版）" {
    const nvs = @import("nvs_ram.zig");
    nvs.reset();
    var buf: [4096]u8 align(16) = undefined;
    impl.initArena(&buf);
    const tbl = impl.makeTable();

    const nvs_open: *const fn (?[*:0]const u8, c_uint, ?*u32) callconv(.c) c_int = @ptrCast(tbl._nvs_open.?);
    const set_u8: *const fn (u32, ?[*:0]const u8, u8) callconv(.c) c_int = @ptrCast(tbl._nvs_set_u8.?);
    const get_u8: *const fn (u32, ?[*:0]const u8, ?*u8) callconv(.c) c_int = @ptrCast(tbl._nvs_get_u8.?);
    const set_blob: *const fn (u32, ?[*:0]const u8, ?*const anyopaque, usize) callconv(.c) c_int = @ptrCast(tbl._nvs_set_blob.?);
    const get_blob: *const fn (u32, ?[*:0]const u8, ?*anyopaque, ?*usize) callconv(.c) c_int = @ptrCast(tbl._nvs_get_blob.?);
    const erase: *const fn (u32, ?[*:0]const u8) callconv(.c) c_int = @ptrCast(tbl._nvs_erase_key.?);

    var handle: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), nvs_open("nvs.net80211", 1, &handle));
    try std.testing.expect(handle != 0);

    try std.testing.expectEqual(@as(c_int, 0), set_u8(handle, "country", 7));
    var v: u8 = 0;
    try std.testing.expectEqual(@as(c_int, 0), get_u8(handle, "country", &v));
    try std.testing.expectEqual(@as(u8, 7), v);

    // 缺失键 → NOT_FOUND
    try std.testing.expectEqual(nvs.err_not_found, get_u8(handle, "absent", &v));

    const payload = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(c_int, 0), set_blob(handle, "cal", &payload, payload.len));
    var out: [8]u8 = undefined;
    var len: usize = out.len;
    try std.testing.expectEqual(@as(c_int, 0), get_blob(handle, "cal", &out, &len));
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualSlices(u8, &payload, out[0..len]);

    // 缓冲太小 → INVALID_LENGTH 且回填所需长度
    var tiny: [2]u8 = undefined;
    var need: usize = tiny.len;
    try std.testing.expectEqual(nvs.err_invalid_len, get_blob(handle, "cal", &tiny, &need));
    try std.testing.expectEqual(@as(usize, 5), need);

    try std.testing.expectEqual(@as(c_int, 0), erase(handle, "cal"));
    try std.testing.expectEqual(nvs.err_not_found, get_blob(handle, "cal", &out, &len));
}
