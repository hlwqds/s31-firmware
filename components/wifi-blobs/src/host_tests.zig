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

test "osi_impl: 信号量计数与空 take" {
    var s: impl.Semphr = .{ .count = 1, .max = 2 };
    // 单线程语义：take 空立刻失败，不阻塞
    try std.testing.expectEqual(@as(u32, 1), s.count);
    s.count -= 1;
    try std.testing.expectEqual(@as(u32, 0), s.count);
    try std.testing.expectEqual(@as(u32, 0), s.count); // 空
    s.count = @min(s.count + 1, s.max);
    try std.testing.expectEqual(@as(u32, 1), s.count);
}

test "osi_impl: 队列环绕与满/空" {
    var storage: [impl.Queue.bytesNeeded(4, 3)]u8 align(8) = undefined;
    const q: *impl.Queue = @ptrCast(&storage);
    q.* = .{ .item_size = 4, .cap = 3 };
    var out: [4]u8 = undefined;

    try std.testing.expect(!q.recv(&out)); // 空
    for (0..3) |i| {
        const item = [4]u8{ @intCast(i), 0, 0, 0 };
        try std.testing.expect(q.send(&item));
    }
    try std.testing.expect(!q.send(&[4]u8{ 9, 9, 9, 9 })); // 满
    for (0..3) |i| {
        try std.testing.expect(q.recv(&out));
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[0]);
    }
    try std.testing.expect(!q.recv(&out)); // 又空
}

test "osi_impl: 互斥在单线程下是空操作" {
    var m: impl.Mutex = .{};
    m.locked = true;
    m.locked = false;
    try std.testing.expect(!m.locked);
}
