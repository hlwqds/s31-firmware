//! 主机测试用的目标符号替身（与 `components/bt-blobs/src/host_stubs.zig` 同一做法）。
//!
//! `osi_impl.zig` 的几个壳无条件引用 ROM、PHY、共存库的入口，而主机目标既不链归档也不链 ROM；
//! 没有这份替身，`wifi-blobs` 的主机测试在链接期就缺这 5 个符号（2026-11-24 补上测试目标时实测）。
//! **只被 `host_tests.zig` 引用**，不进任何镜像；板上用真符号。

const std = @import("std");

/// ROM：`coex_init()`。核里是 `li a0,0; ret`（`coex_core_init` 的反汇编）。
pub export fn coex_init() callconv(.c) void {}

/// ROM / `libcoexist.a`：`coex_enable()`。
pub export fn coex_enable() callconv(.c) void {}

/// ROM：外设中断到 CPU 输入的路由表。
pub export fn intr_matrix_set(_: u32, _: u32, _: u32) callconv(.c) void {}

/// `libphy.a`：PHY 的 Wi-Fi 使能位。
pub export fn phy_wifi_enable_set(_: u8) callconv(.c) void {}

/// `libphy.a`：基带看门狗。
pub export fn set_bb_wdg(_: bool, _: bool, _: u16, _: u16, _: bool, _: bool, _: bool) callconv(.c) void {}

test "host_stubs(wifi): 五个目标符号替身都在，调用不产生副作用" {
    coex_init();
    coex_enable();
    intr_matrix_set(0, 0, 0);
    phy_wifi_enable_set(0);
    set_bb_wdg(false, false, 0, 0, false, false, false);
    // 让链接器看到每个符号都被引用（删掉任何一个导出，这里就是未定义）。
    const refs = [_]*const anyopaque{ &coex_init, &coex_enable, &intr_matrix_set, &phy_wifi_enable_set, &set_bb_wdg };
    for (refs) |r| try std.testing.expect(@intFromPtr(r) != 0);
}
