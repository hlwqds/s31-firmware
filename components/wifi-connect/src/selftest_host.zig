//! 在主机上执行板侧子自检的公共助手。
//!
//! 各特性的板侧自检在自己的 `<特性>_selftest.zig` 里，入口固定为
//! `run(check)`（`check: fn (bool, []const u8) void`），不 import board、不分配堆内存，
//! 所以可以在主机上跑：`selftest.zig` 经 `extCheck` 在板侧调用它，各特性的 `<特性>_tests.zig`
//! 用这里的 `expectAllPass` 在主机上再跑一遍。
//!
//! 这有两个用处：烧录之前就拦住自检自身的回归（2026-11-24 第一次上板 `ble-802154` 18/19，
//! 失败的那条就是自检自己的差一错误）；主机测试的 import 闭包也因此覆盖到自检文件。

const std = @import("std");

var g_passed: usize = 0;
var g_failed: usize = 0;
var g_longest: usize = 0;

fn count(ok: bool, text: []const u8) void {
    if (ok) g_passed += 1 else {
        g_failed += 1;
        std.debug.print("board selftest FAIL: {s}\n", .{text});
    }
    if (text.len > g_longest) g_longest = text.len;
}

/// 跑一遍子自检，断言：至少有 1 条判据、没有失败、最长的一行不超过 200 字节。
pub fn expectAllPass(comptime run: anytype) !void {
    g_passed = 0;
    g_failed = 0;
    g_longest = 0;
    run(count);
    try std.testing.expect(g_passed > 0);
    try std.testing.expectEqual(@as(usize, 0), g_failed);
    // `board.log` 一行超过 200 字节会被截断，行尾的 `ok=` 就没了（`ft_selftest.zig` 文件头）。
    try std.testing.expect(g_longest <= 200);
    std.debug.print("board selftest on host: passed={d} failed=0 longest-line={d}\n", .{ g_passed, g_longest });
}

/// 最近一遍里通过的判据条数。
pub fn lastPassed() usize {
    return g_passed;
}
