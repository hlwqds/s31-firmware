//! 128 字节 `esp_phy_init_data_t`，供 C 桩 `phy_stubs.c` 的 `nvs_get_blob` 返回给
//! IDF 的 `esp_phy_get_init_data()`（它走 `nvs_open`/`nvs_get_blob` 取这张表，
//! 取不到就 `ESP_ERROR_CHECK` → "failed to obtain PHY init data" → abort）。
//!
//! 数据与 `wifi-blobs/src/phy_init_data.zig` 的 `params` **同源同值**（本文件由脚本复制，
//! 不是运行时依赖 —— BLE 组件不引入对 wifi-blobs 的依赖）。

pub const params: [128]u8 = .{
    1,  0,  80, 80, 80, 80, 76, 72, 80, 80, 76, 72, 64, 60, 60, 60,
    76, 76, 72, 68, 0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  81,
};

// C 侧符号名（`phy_stubs.c` 里 `extern const unsigned char g_phy_init_data_128[128];`）。
comptime {
    @export(&params, .{ .name = "g_phy_init_data_128" });
}
