//! 链接期桩：让 blob 的链接闭合，同时**记录谁被调用**（R3 的探针）。
//!
//! 这些是 lld 报的 45 个非 ROM 符号（ROM 的 269 个已在 `linker/rom_syms.ld` 里）。
//! 函数桩累加计数并返回 0；数据桩是零值全局——**链接能过不代表能跑**：真实适配层要按
//! 符号类型给真变量/真实现（`est_PHY_*` 是 eFuse 标定表，零值等于"没有标定"）。

/// 与 `names` 同序的调用计数（只有函数桩会累加）。
pub var hits: [18]u32 = @splat(0);

pub const names = [_][]const u8{
    "esp_event_handler_register",
    "esp_event_handler_unregister",
    "esp_mesh_send_event_internal",
    "esp_test_tx_duration",
    "esp_wifi_connect",
    "esp_wifi_disconnect",
    "free",
    "hexstr2bin",
    "mesh_printf",
    "net80211_printf",
    "phy_printf",
    "pp_printf",
    "putchar",
    "puts",
    "rtc_clk_xtal_freq_get",
    "snprintf",
    "sprintf",
    "strtok",
};

pub export fn esp_event_handler_register() callconv(.c) usize {
    hits[0] += 1;
    return 0;
}
pub export fn esp_event_handler_unregister() callconv(.c) usize {
    hits[1] += 1;
    return 0;
}
pub export fn esp_mesh_send_event_internal() callconv(.c) usize {
    hits[2] += 1;
    return 0;
}
pub export fn esp_test_tx_duration() callconv(.c) usize {
    hits[3] += 1;
    return 0;
}
pub export fn esp_wifi_connect() callconv(.c) usize {
    hits[4] += 1;
    return 0;
}
pub export fn esp_wifi_disconnect() callconv(.c) usize {
    hits[5] += 1;
    return 0;
}
pub export fn free() callconv(.c) usize {
    hits[6] += 1;
    return 0;
}
pub export fn hexstr2bin() callconv(.c) usize {
    hits[7] += 1;
    return 0;
}
pub export fn mesh_printf() callconv(.c) usize {
    hits[8] += 1;
    return 0;
}
pub export fn net80211_printf() callconv(.c) usize {
    hits[9] += 1;
    return 0;
}
pub export fn phy_printf() callconv(.c) usize {
    hits[10] += 1;
    return 0;
}
pub export fn pp_printf() callconv(.c) usize {
    hits[11] += 1;
    return 0;
}
pub export fn putchar() callconv(.c) usize {
    hits[12] += 1;
    return 0;
}
pub export fn puts() callconv(.c) usize {
    hits[13] += 1;
    return 0;
}
pub export fn rtc_clk_xtal_freq_get() callconv(.c) usize {
    hits[14] += 1;
    return 0;
}
pub export fn snprintf() callconv(.c) usize {
    hits[15] += 1;
    return 0;
}
pub export fn sprintf() callconv(.c) usize {
    hits[16] += 1;
    return 0;
}
pub export fn strtok() callconv(.c) usize {
    hits[17] += 1;
    return 0;
}

// 数据符号：零值占位（真值来自 eFuse / IDF 的 C 层）。
pub export var WIFI_EVENT: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var regdomain_table: [4]u8 = @splat(0);
pub export var regulatory_data: [4]u8 = @splat(0);
