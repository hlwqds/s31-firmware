//! `wifi_init_config_t` 与内嵌 `wpa_crypto_funcs_t` 的 Zig 镜像。
//!
//! 调 `esp_wifi_init_internal(config)` 之前必须给出这两个结构，且**布局必须与 C 一致**：
//! 首字段 `osi_funcs` 指向我们的表，末字段 `magic` 必须是 `WIFI_INIT_CONFIG_MAGIC`
//! （`esp_wifi.h:191`：`0x1F2F3F4F`，9 位十六进制，blob 会校验）。结构体里混着 C `bool`（1 字节）、`uint64_t`（ilp32 下 8 字节
//! 对齐）与 4 字节 int，padding 很敏感——所以布局用 comptime 断言钉死，而不是靠肉眼。
//!
//! 校验方式（C 侧，riscv32-esp-elf-gcc）：
//!   - `wpa_crypto_funcs_t` = 2×u32 + 11 个函数指针 = **52 字节**，`aes_wrap`@44、`aes_unwrap`@48
//!     已用 `_Static_assert` 在真实头文件上验证通过；
//!   - `wifi_init_config_t` 28 个字段无 `#if`，按 ilp32 规则算得 `magic`@152、总长 **160**。

const osi = @import("osi.zig");

/// `ESP_WIFI_CRYPTO_VERSION`（`esp_wifi_crypto_types.h:24`）。
pub const crypto_version: u32 = 0x0000_0001;

/// `WIFI_INIT_CONFIG_MAGIC`：blob 校验这个值，抄错会**返回失败而不是崩**，很难联想到常量。
/// 原文：`esp_wifi.h:191` —— `#define WIFI_INIT_CONFIG_MAGIC    0x1F2F3F4F`
/// 注意是 9 位十六进制、末尾是 `F`（写成 `0x1F2F3F4` 就是另一个数）。
pub const init_magic: i32 = 0x1F2F3F4F;

/// `wpa_crypto_funcs_t`：两个 u32 + 11 个函数指针（顺序见 `esp_wifi_crypto_types.h:395-409`）。
pub const WpaCrypto = extern struct {
    size: u32 = 0,
    version: u32 = 0,
    hmac_sha256_vector: ?*const anyopaque = null,
    pbkdf2_sha1: ?*const anyopaque = null,
    aes_128_encrypt: ?*const anyopaque = null,
    aes_128_decrypt: ?*const anyopaque = null,
    omac1_aes_128: ?*const anyopaque = null,
    ccmp_decrypt: ?*const anyopaque = null,
    ccmp_encrypt: ?*const anyopaque = null,
    aes_gmac: ?*const anyopaque = null,
    sha256_vector: ?*const anyopaque = null,
    aes_wrap: ?*const anyopaque = null,
    aes_unwrap: ?*const anyopaque = null,
};

/// `wifi_init_config_t`（`esp_wifi.h:60-126`，字段顺序即结构体顺序，无条件编译）。
pub const InitConfig = extern struct {
    osi_funcs: ?*const osi.Osi = null,
    wpa_crypto_funcs: WpaCrypto = .{},
    static_rx_buf_num: i32 = 0,
    dynamic_rx_buf_num: i32 = 0,
    tx_buf_type: i32 = 0,
    static_tx_buf_num: i32 = 0,
    dynamic_tx_buf_num: i32 = 0,
    rx_mgmt_buf_type: i32 = 0,
    rx_mgmt_buf_num: i32 = 0,
    cache_tx_buf_num: i32 = 0,
    csi_enable: i32 = 0,
    ampdu_rx_enable: i32 = 0,
    ampdu_tx_enable: i32 = 0,
    amsdu_tx_enable: i32 = 0,
    nvs_enable: i32 = 0,
    nano_enable: i32 = 0,
    rx_ba_win: i32 = 0,
    wifi_task_core_id: i32 = 0,
    beacon_max_len: i32 = 0,
    mgmt_sbuf_num: i32 = 0,
    feature_caps: u64 = 0,
    sta_disconnected_pm: bool = false,
    espnow_max_encrypt_num: i32 = 0,
    tx_hetb_queue_num: i32 = 0,
    dump_hesigb_enable: bool = false,
    privacy_enhancements: bool = false,
    rmac_auto_reset_int: u8 = 0,
    magic: i32 = init_magic,
};

comptime {
    // ilp32：指针 4、int 4、bool 1、uint64 8（对齐 8）。
    if (@sizeOf(usize) == 4) {
        if (@sizeOf(WpaCrypto) != 52) @compileError("wpa_crypto_funcs_t 应为 52 字节");
        if (@offsetOf(WpaCrypto, "aes_wrap") != 44) @compileError("aes_wrap 偏移应为 44");
        if (@offsetOf(WpaCrypto, "aes_unwrap") != 48) @compileError("aes_unwrap 偏移应为 48");
        if (@sizeOf(InitConfig) != 160) @compileError("wifi_init_config_t 应为 160 字节");
        if (@offsetOf(InitConfig, "osi_funcs") != 0) @compileError("osi_funcs 必须是第一个字段");
        if (@offsetOf(InitConfig, "feature_caps") != 128) @compileError("feature_caps 偏移应为 128");
        if (@offsetOf(InitConfig, "magic") != 152) @compileError("magic 偏移应为 152");
    }
}

/// IDF `WIFI_INIT_CONFIG_DEFAULT()` 的取值（来自 `esp_wifi.h:340-366` 的宏与我们的 sdkconfig.h）。
/// 全 0 的 config 会让 blob 以 `ESP_ERR_INVALID_ARG`（0x102）拒绝——板级实测 rc=258。
pub fn defaults(table: *const osi.Osi) InitConfig {
    var c: InitConfig = .{};
    c.osi_funcs = table;
    // `wifi_menuconfig_init` 会校验这两个值（反汇编 `.L718`/`.L720`）：
    //   1) config->magic == 0x1F2F3F4F
    //   2) config->wpa_crypto_funcs.size == sizeof(wpa_crypto_funcs_t) == 52
    // 我们的表原先全零 → size=0 → 直接 258。`version` 用 ESP_WIFI_CRYPTO_VERSION（=1）。
    c.wpa_crypto_funcs = .{ .size = @sizeOf(WpaCrypto), .version = crypto_version };
    c.static_rx_buf_num = 10; // CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM
    c.dynamic_rx_buf_num = 32; // CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM
    c.tx_buf_type = 1; // CONFIG_ESP_WIFI_TX_BUFFER_TYPE（动态 TX）
    c.static_tx_buf_num = 0; // 动态 TX 模式下为 0
    c.dynamic_tx_buf_num = 32; // CONFIG_ESP_WIFI_DYNAMIC_TX_BUFFER_NUM
    c.rx_mgmt_buf_type = 0; // CONFIG_ESP_WIFI_DYNAMIC_RX_MGMT_BUF = 0（静态 mgmt 缓冲）
    c.rx_mgmt_buf_num = 5; // CONFIG_ESP_WIFI_RX_MGMT_BUF_NUM_DEF
    c.nvs_enable = 1; // WIFI_NVS_ENABLED
    c.beacon_max_len = 752; // WIFI_SOFTAP_BEACON_MAX_LEN
    c.mgmt_sbuf_num = 32; // WIFI_MGMT_SBUF_NUM
    c.espnow_max_encrypt_num = 7; // CONFIG_ESP_WIFI_ESPNOW_MAX_ENCRYPT_NUM
    // 按 IDF 的 sdkconfig 补齐（之前漏设，全是 0）：
    c.ampdu_rx_enable = 1; // CONFIG_ESP_WIFI_AMPDU_RX_ENABLED=1
    c.ampdu_tx_enable = 1; // CONFIG_ESP_WIFI_AMPDU_TX_ENABLED=1
    c.rx_ba_win = 6; // CONFIG_ESP_WIFI_RX_BA_WIN=6
    c.tx_hetb_queue_num = 3; // CONFIG_ESP_WIFI_TX_HETB_QUEUE_NUM=3
    c.sta_disconnected_pm = true; // CONFIG_ESP_WIFI_STA_DISCONNECTED_PM_ENABLE=1
    return c;
}
