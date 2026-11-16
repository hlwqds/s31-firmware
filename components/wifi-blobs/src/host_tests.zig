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

test {
    _ = adapter;
    _ = osi;
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
