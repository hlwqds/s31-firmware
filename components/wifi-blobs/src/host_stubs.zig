//! 主机测试用的目标符号替身（与 `components/bt-blobs/src/host_stubs.zig` 同一做法）。
//!
//! `osi_impl.zig` 的壳无条件引用 ROM、PHY、共存库的入口，而主机目标既不链归档也不链 ROM；
//! 没有这份替身，`wifi-blobs` 的主机测试在链接期就缺这些符号（2026-11-24 补上测试目标时实测）。
//! 三组：ROM / 共存库 / PHY 的 5 个入口（`osi_impl` 的初始化路径）；blob 的 SAE 配置
//! （`wpa_cb.zig` 的 RSNX 解析）；`libphy.a` 的 6 个 PHY 使能 / 关闭入口（`osi_impl` 的 PHY 壳）。
//! **只被 `host_tests.zig` 与 `wpa_cb.zig` 的用例引用**，不进任何镜像；板上用真符号。

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

/// `libphy.a`：标定过之后的再次使能（`shellPhyEnable` 调）。
pub export fn phy_wakeup_init() callconv(.c) void {}

/// `libphy.a`：建 PLL 跟踪用的定时器（第一个 modem 打开时）。
pub export fn phy_track_pll_init() callconv(.c) void {}

/// `libphy.a`：置 `s_phy_modem_flag` 的 modem 位（参数是 `PHY_MODEM_*`）。
pub export fn phy_set_modem_flag(_: u32) callconv(.c) void {}

/// `libphy.a`：立刻跟一次 PLL。
pub export fn phy_track_pll() callconv(.c) void {}

/// `libphy.a`：最后一个 modem 关掉时关射频。
pub export fn phy_close_rf() callconv(.c) void {}

/// `libphy.a`：等跳频硬件做完。
pub export fn phy_wait_freq_hw_hop_done() callconv(.c) void {}

/// blob `ieee80211_ioctl.o`：STA 的 SAE PWE 配置（`esp_wifi_get_config_sae_pwe_h2e_internal()`）。
/// `wpa_cb.zig` 的 RSNX 解析读它：1 = 强制 H2E。用例改这个值来走「强制」与「不强制」两条路。
pub var sae_pwe_h2e: c_int = 0;

pub export fn esp_wifi_get_config_sae_pwe_h2e_internal(ifx: c_int) callconv(.c) c_int {
    _ = ifx;
    return sae_pwe_h2e;
}

test "host_stubs(wifi): 目标符号替身都在，调用不产生副作用" {
    coex_init();
    coex_enable();
    intr_matrix_set(0, 0, 0);
    phy_wifi_enable_set(0);
    set_bb_wdg(false, false, 0, 0, false, false, false);
    phy_wakeup_init();
    phy_track_pll_init();
    phy_set_modem_flag(0);
    phy_track_pll();
    phy_close_rf();
    phy_wait_freq_hw_hop_done();
    // 让链接器看到每个符号都被引用（删掉任何一个导出，这里就是未定义）。
    const refs = [_]*const anyopaque{
        &coex_init,
        &coex_enable,
        &intr_matrix_set,
        &phy_wifi_enable_set,
        &set_bb_wdg,
        &esp_wifi_get_config_sae_pwe_h2e_internal,
        &phy_wakeup_init,
        &phy_track_pll_init,
        &phy_set_modem_flag,
        &phy_track_pll,
        &phy_close_rf,
        &phy_wait_freq_hw_hop_done,
    };
    for (refs) |r| try std.testing.expect(@intFromPtr(r) != 0);
}
