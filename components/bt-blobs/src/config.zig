//! `esp_bt_controller_config_t` 的逐字段镜像（BLE_ONLY 相关部分）。
//!
//! 布局**不是手算的**：`tools/btcfg-probe.sh` 用 rv32 gcc 把 `sizeof`/`offsetof`
//! 发射成常量表再读回来（交叉产物跑不了，所以用常量表）。实测：
//!
//! ```text
//! sizeof(esp_bt_controller_config_t) = 192
//!   ble   @ 0     (112 字节)
//!   bredr @ 112   (56 字节，含 8 个 C 位域 ⇒ 用 [56]u8 表示)
//!   btdm  @ 168   (20 字节)
//! ble 内: config_version@0、rtc_freq@24、main_xtal_freq@84、config_magic@108
//! btdm 内: version@0、magic@16
//! ```
//!
//! 三个不能用 Zig `bool` 的地方：C 的 `bool` 若字节非 0/1，Zig `bool` 是 UB ⇒ 全用 `u8`。
//! `bredr` 在 BLE_ONLY 下不用，但**仍然占 56 字节**，`btdm` 的偏移由它决定。
const std = @import("std");

/// `esp_btdm_controller_config_t`（20 字节）
pub const BtdmCfg = extern struct {
    version: u32 = 0, // BTDM_CONFIG_VERSION = 0x20260127
    task_stack_size: u16 = 0, // 单位**字节**
    task_prio: u8 = 0,
    task_run_cpu: u8 = 0,
    hci_cmd_num: u8 = 0,
    hci_conn_num: u8 = 0,
    sleep_en: u8 = 0,
    version_num: u8 = 0,
    bluetooth_mode: u8 = 0, // 不能是 IDLE（bt.c 直接拒绝）
    magic: u32 = 0, // BTDM_CONFIG_MAGIC_VALUE = 0x5a5aa5a5
};

/// 匿名 `struct { ... } ble`（112 字节）。字段顺序与 `esp_bt.h` 一致。
pub const BleCfg = extern struct {
    config_version: u32 = 0,
    ble_ll_resolv_list_size: u16 = 0,
    ble_hci_evt_hi_buf_count: u16 = 0,
    ble_hci_evt_lo_buf_count: u16 = 0,
    ble_ll_sync_list_cnt: u8 = 0,
    ble_ll_sync_cnt: u8 = 0,
    ble_ll_rsp_dup_list_count: u16 = 0,
    ble_ll_adv_dup_list_count: u16 = 0,
    ble_ll_tx_pwr_dbm: u8 = 0,
    rtc_freq: u64 = 0,
    ble_ll_sca: u16 = 0,
    ble_ll_scan_phy_number: u8 = 0,
    ble_ll_conn_def_auth_pyld_tmo: u16 = 0,
    ble_ll_jitter_usecs: u8 = 0,
    ble_ll_sched_max_adv_pdu_usecs: u16 = 0,
    ble_ll_sched_direct_adv_max_usecs: u16 = 0,
    ble_ll_sched_adv_max_usecs: u16 = 0,
    ble_scan_rsp_data_max_len: u16 = 0,
    ble_ll_cfg_num_hci_cmd_pkts: u8 = 0,
    ble_ll_ctrl_proc_timeout_ms: u32 = 0,
    nimble_max_connections: u16 = 0,
    ble_whitelist_size: u8 = 0,
    ble_acl_buf_size: u16 = 0,
    ble_acl_buf_count: u16 = 0,
    ble_hci_evt_buf_size: u16 = 0,
    ble_multi_adv_instances: u16 = 0,
    ble_ext_adv_max_size: u16 = 0,
    controller_task_stack_size: u16 = 0,
    controller_task_prio: u8 = 0,
    controller_run_cpu: u8 = 0,
    enable_qa_test: u8 = 0,
    enable_bqb_test: u8 = 0,
    enable_tx_cca: u8 = 0,
    cca_rssi_thresh: u8 = 0,
    sleep_en: u8 = 0,
    coex_phy_coded_tx_rx_time_limit: u8 = 0,
    dis_scan_backoff: u8 = 0,
    ble_scan_classify_filter_enable: u8 = 0,
    cca_drop_mode: u8 = 0,
    cca_low_tx_pwr: i8 = 0,
    main_xtal_freq: u8 = 0,
    ignore_wl_for_direct_adv: u8 = 0,
    enable_pcl: u8 = 0,
    csa2_select: u8 = 0,
    enable_csr: u8 = 0,
    backoff_rssi: i8 = 0,
    iso_enabled: u8 = 0, // C bool ⇒ u8
    iso_bqb_test: u8 = 0, // C bool ⇒ u8
    iso_fra_unseg: u8 = 0, // C bool ⇒ u8
    iso_nsfc_en: u8 = 0, // C bool ⇒ u8
    iso_nsfc_num: u8 = 0,
    iso_buf_count: u8 = 0,
    iso_buf_size: u16 = 0,
    iso_big_count: u8 = 0,
    iso_bis_count: u16 = 0,
    iso_bis_per_big: u8 = 0,
    iso_cig_count: u8 = 0,
    iso_cis_count: u16 = 0,
    iso_cis_per_cig: u8 = 0,
    config_magic: u32 = 0,
};

/// `esp_bredr_controller_config_t` 有 8 个 C 位域，Zig 无法逐字段镜像 ⇒ 只保留尺寸。
/// BLE_ONLY 下不填内容，但**必须占位**（`btdm` 跟在它后面）。
pub const BredrCfg = extern struct {
    raw: [56]u8 = @splat(0),
};

pub const Config = extern struct {
    ble: BleCfg = .{},
    bredr: BredrCfg = .{},
    btdm: BtdmCfg = .{},
};

// 常量（`esp_bt.h`）
pub const BLE_CONFIG_VERSION: u32 = 0x20241029;
pub const BLE_CONFIG_MAGIC: u32 = 0x5A5AA5A5;
pub const BTDM_CONFIG_VERSION: u32 = 0x20260127;
pub const BTDM_CONFIG_MAGIC_VALUE: u32 = 0x5a5aa5a5;

comptime {
    // 这些数字来自 tools/btcfg-probe.sh 的实测输出，不是推算。
    std.debug.assert(@sizeOf(BleCfg) == 112);
    std.debug.assert(@sizeOf(BtdmCfg) == 20);
    std.debug.assert(@sizeOf(BredrCfg) == 56);
    std.debug.assert(@sizeOf(Config) == 192);
    std.debug.assert(@offsetOf(Config, "ble") == 0);
    std.debug.assert(@offsetOf(Config, "bredr") == 112);
    std.debug.assert(@offsetOf(Config, "btdm") == 168);
    std.debug.assert(@offsetOf(BleCfg, "config_version") == 0);
    std.debug.assert(@offsetOf(BleCfg, "rtc_freq") == 24);
    std.debug.assert(@offsetOf(BleCfg, "main_xtal_freq") == 84);
    std.debug.assert(@offsetOf(BleCfg, "config_magic") == 108);
    std.debug.assert(@offsetOf(BtdmCfg, "version") == 0);
    std.debug.assert(@offsetOf(BtdmCfg, "magic") == 16);
}

test "config: 默认值可填、魔数落位" {
    var c: Config = .{};
    c.ble.config_version = BLE_CONFIG_VERSION;
    c.ble.config_magic = BLE_CONFIG_MAGIC;
    c.ble.rtc_freq = 40_000_000; // u64，单位 Hz
    c.ble.main_xtal_freq = 40; // u8，单位 MHz
    c.btdm.version = BTDM_CONFIG_VERSION;
    c.btdm.magic = BTDM_CONFIG_MAGIC_VALUE;
    c.btdm.bluetooth_mode = 1; // BLE
    std.testing.expectEqual(@as(u32, 0x5A5AA5A5), c.ble.config_magic) catch unreachable;
    std.testing.expectEqual(@as(u64, 40_000_000), c.ble.rtc_freq) catch unreachable;
}
