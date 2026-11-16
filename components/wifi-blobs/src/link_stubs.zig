//! 链接期桩：让 blob 的链接闭合，同时**记录谁被调用**（R3 的探针）。
//!
//! 这些是 lld 报的 45 个非 ROM 符号里、还没有真实现的部分（`net80211_printf`/`pp_printf`/
//! `mesh_printf` 已由 `printf_shim.c` 提供，故不在此列）。函数桩累加计数并返回 0；
//! 数据桩是零值全局——**链接能过不代表能跑**：`est_PHY_*` 是 eFuse 标定表，零值等于没标定。

pub var hits: [15]u32 = @splat(0);

pub const names = [_][]const u8{
    "esp_event_handler_register",
    "esp_event_handler_unregister",
    "esp_mesh_send_event_internal",
    "esp_test_tx_duration",
    "esp_wifi_connect",
    "esp_wifi_disconnect",
    "free",
    "hexstr2bin",
    "phy_printf",
    "putchar",
    "puts",
    "rtc_clk_xtal_freq_get",
    "snprintf",
    "sprintf",
    "strtok",
};

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
pub export fn phy_printf() callconv(.c) usize {
    hits[8] += 1;
    return 0;
}
pub export fn putchar() callconv(.c) usize {
    hits[9] += 1;
    return 0;
}
pub export fn puts() callconv(.c) usize {
    hits[10] += 1;
    return 0;
}
pub export fn rtc_clk_xtal_freq_get() callconv(.c) usize {
    hits[11] += 1;
    return 0;
}
pub export fn snprintf() callconv(.c) usize {
    hits[12] += 1;
    return 0;
}
pub export fn sprintf() callconv(.c) usize {
    hits[13] += 1;
    return 0;
}
pub export fn strtok() callconv(.c) usize {
    hits[14] += 1;
    return 0;
}

// 数据符号：按已知声明给**真实形态**，而不是一律 4 字节零。
// 板级教训：`WIFI_EVENT` 是 `const char* const`（`ESP_EVENT_DECLARE_BASE`），零填充 = 空指针，
// blob 一解引用就是 misaligned load（实测 mepc=0x40015820、mtval=0xc2）。
pub export const WIFI_EVENT: [*:0]const u8 = "WIFI_EVENT";

/// IDF 里是 `const wifi_regdomain_t regdomain_table[]`（`esp_wifi_regulatory.c:93`）。
/// 尺寸未知，给足 4 KiB 零值，按下标读不会越界；内容为 0 = "没有国家配置"。
pub export var regdomain_table: [4096]u8 = @splat(0);

/// 同上：`const wifi_regulatory_t regulatory_data[]`（`esp_wifi_regulatory.c:280`）。
pub export var regulatory_data: [4096]u8 = @splat(0);

// `g_mt` 与 `g_espnow_user_oui` 由 libmesh.a / libespnow.a 自己定义，这里不能再导出（会重复符号）。

// `est_PHY_*` 是 `uint16_t` 标量（FTM 标定表），4 字节零足够；真值要 eFuse 标定路径。
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
