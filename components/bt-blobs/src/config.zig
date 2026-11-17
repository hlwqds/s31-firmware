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
    /// **RTC 慢时钟频率（Hz）**，不是主晶振！IDF 在 `ble.c:673` 紧挨 `r_ble_controller_init`
    /// 之前硬写 `cfg->ble.rtc_freq = 32000`（内部 RC32K / 外部 32k）。填成 40 MHz 会
    /// 让睡眠时钟、连接间隔、SCA 推算全错（**差 1250 倍且不报错**）。
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
/// RTC 慢时钟：内部 RC32K / 外部 32k ⇒ 32000；32.768 kHz 晶振 ⇒ 32768。
pub const RTC_FREQ_32K: u64 = 32000;
/// 主晶振（u8，单位 **MHz**）——与 `rtc_freq` 是两个不同的字段，单位也不同。
pub const MAIN_XTAL_FREQ_MHZ: u8 = 40;
/// `esp_bt_mode_t`：IDLE=0 / BREDR=1? 见下——BLE_ONLY 构建下 controller 只接受 BLE。
pub const BTDM_CONTROLLER_MODE_BLE: u8 = 0x01;

comptime {
    // **每一个字段**的偏移都钉住（不只是 4 个锚点）⇒ 字段类型/顺序写错当场编译失败。
    std.debug.assert(@offsetOf(BleCfg, "config_version") == 0);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_resolv_list_size") == 4);
    std.debug.assert(@offsetOf(BleCfg, "ble_hci_evt_hi_buf_count") == 6);
    std.debug.assert(@offsetOf(BleCfg, "ble_hci_evt_lo_buf_count") == 8);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_sync_list_cnt") == 10);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_sync_cnt") == 11);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_rsp_dup_list_count") == 12);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_adv_dup_list_count") == 14);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_tx_pwr_dbm") == 16);
    std.debug.assert(@offsetOf(BleCfg, "rtc_freq") == 24);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_sca") == 32);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_scan_phy_number") == 34);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_conn_def_auth_pyld_tmo") == 36);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_jitter_usecs") == 38);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_sched_max_adv_pdu_usecs") == 40);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_sched_direct_adv_max_usecs") == 42);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_sched_adv_max_usecs") == 44);
    std.debug.assert(@offsetOf(BleCfg, "ble_scan_rsp_data_max_len") == 46);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_cfg_num_hci_cmd_pkts") == 48);
    std.debug.assert(@offsetOf(BleCfg, "ble_ll_ctrl_proc_timeout_ms") == 52);
    std.debug.assert(@offsetOf(BleCfg, "nimble_max_connections") == 56);
    std.debug.assert(@offsetOf(BleCfg, "ble_whitelist_size") == 58);
    std.debug.assert(@offsetOf(BleCfg, "ble_acl_buf_size") == 60);
    std.debug.assert(@offsetOf(BleCfg, "ble_acl_buf_count") == 62);
    std.debug.assert(@offsetOf(BleCfg, "ble_hci_evt_buf_size") == 64);
    std.debug.assert(@offsetOf(BleCfg, "ble_multi_adv_instances") == 66);
    std.debug.assert(@offsetOf(BleCfg, "ble_ext_adv_max_size") == 68);
    std.debug.assert(@offsetOf(BleCfg, "controller_task_stack_size") == 70);
    std.debug.assert(@offsetOf(BleCfg, "controller_task_prio") == 72);
    std.debug.assert(@offsetOf(BleCfg, "controller_run_cpu") == 73);
    std.debug.assert(@offsetOf(BleCfg, "enable_qa_test") == 74);
    std.debug.assert(@offsetOf(BleCfg, "enable_bqb_test") == 75);
    std.debug.assert(@offsetOf(BleCfg, "enable_tx_cca") == 76);
    std.debug.assert(@offsetOf(BleCfg, "cca_rssi_thresh") == 77);
    std.debug.assert(@offsetOf(BleCfg, "sleep_en") == 78);
    std.debug.assert(@offsetOf(BleCfg, "coex_phy_coded_tx_rx_time_limit") == 79);
    std.debug.assert(@offsetOf(BleCfg, "dis_scan_backoff") == 80);
    std.debug.assert(@offsetOf(BleCfg, "ble_scan_classify_filter_enable") == 81);
    std.debug.assert(@offsetOf(BleCfg, "cca_drop_mode") == 82);
    std.debug.assert(@offsetOf(BleCfg, "cca_low_tx_pwr") == 83);
    std.debug.assert(@offsetOf(BleCfg, "main_xtal_freq") == 84);
    std.debug.assert(@offsetOf(BleCfg, "ignore_wl_for_direct_adv") == 85);
    std.debug.assert(@offsetOf(BleCfg, "enable_pcl") == 86);
    std.debug.assert(@offsetOf(BleCfg, "csa2_select") == 87);
    std.debug.assert(@offsetOf(BleCfg, "enable_csr") == 88);
    std.debug.assert(@offsetOf(BleCfg, "backoff_rssi") == 89);
    std.debug.assert(@offsetOf(BleCfg, "iso_enabled") == 90);
    std.debug.assert(@offsetOf(BleCfg, "iso_bqb_test") == 91);
    std.debug.assert(@offsetOf(BleCfg, "iso_fra_unseg") == 92);
    std.debug.assert(@offsetOf(BleCfg, "iso_nsfc_en") == 93);
    std.debug.assert(@offsetOf(BleCfg, "iso_nsfc_num") == 94);
    std.debug.assert(@offsetOf(BleCfg, "iso_buf_count") == 95);
    std.debug.assert(@offsetOf(BleCfg, "iso_buf_size") == 96);
    std.debug.assert(@offsetOf(BleCfg, "iso_big_count") == 98);
    std.debug.assert(@offsetOf(BleCfg, "iso_bis_count") == 100);
    std.debug.assert(@offsetOf(BleCfg, "iso_bis_per_big") == 102);
    std.debug.assert(@offsetOf(BleCfg, "iso_cig_count") == 103);
    std.debug.assert(@offsetOf(BleCfg, "iso_cis_count") == 104);
    std.debug.assert(@offsetOf(BleCfg, "iso_cis_per_cig") == 106);
    std.debug.assert(@offsetOf(BleCfg, "config_magic") == 108);
    std.debug.assert(@offsetOf(BtdmCfg, "version") == 0);
    std.debug.assert(@offsetOf(BtdmCfg, "task_stack_size") == 4);
    std.debug.assert(@offsetOf(BtdmCfg, "task_prio") == 6);
    std.debug.assert(@offsetOf(BtdmCfg, "task_run_cpu") == 7);
    std.debug.assert(@offsetOf(BtdmCfg, "hci_cmd_num") == 8);
    std.debug.assert(@offsetOf(BtdmCfg, "hci_conn_num") == 9);
    std.debug.assert(@offsetOf(BtdmCfg, "sleep_en") == 10);
    std.debug.assert(@offsetOf(BtdmCfg, "version_num") == 11);
    std.debug.assert(@offsetOf(BtdmCfg, "bluetooth_mode") == 12);
    std.debug.assert(@offsetOf(BtdmCfg, "magic") == 16);

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
    c.ble.rtc_freq = RTC_FREQ_32K; // u64，RTC 慢时钟 Hz（不是主晶振）
    c.ble.main_xtal_freq = 40; // u8，单位 MHz
    c.btdm.version = BTDM_CONFIG_VERSION;
    c.btdm.magic = BTDM_CONFIG_MAGIC_VALUE;
    c.btdm.bluetooth_mode = BTDM_CONTROLLER_MODE_BLE; // 不能是 IDLE/双模
    std.testing.expectEqual(@as(u32, 0x5A5AA5A5), c.ble.config_magic) catch unreachable;
    std.testing.expectEqual(@as(u64, 32_000), c.ble.rtc_freq) catch unreachable;
}

/// `BT_CONTROLLER_INIT_CONFIG_DEFAULT()` 的 BLE_ONLY 分支（`esp_bt.h:487-561`），
/// 取值来自 `ble_user_cfg.h` 的**非 NimBLE** fallback 分支（逐条核过行号）。
///
/// ⚠ 若哪天打开 `CONFIG_BT_NIMBLE_EXT_ADV`，`ble_hci_evt_buf_size` 与
/// `ble_ext_adv_max_size` 会变成 **257 / 1650**（`ble_user_cfg.h:34-35` 走 MYNEWT_VAL），
/// 不是这里的 70 / 31。
pub fn defaults() Config {
    var c: Config = .{};
    c.ble = .{
        .config_version = BLE_CONFIG_VERSION,
        .ble_ll_resolv_list_size = 0,
        .ble_hci_evt_hi_buf_count = 30, // ble_user_cfg.h:106
        .ble_hci_evt_lo_buf_count = 8, // 同区段 fallback
        .ble_ll_sync_list_cnt = 5,
        .ble_ll_sync_cnt = 1,
        .ble_ll_rsp_dup_list_count = 0,
        .ble_ll_adv_dup_list_count = 0,
        .ble_ll_tx_pwr_dbm = 0,
        .rtc_freq = RTC_FREQ_32K,
        .ble_ll_sca = 0, // CONFIG_BT_LE_LL_SCA 的 Kconfig 默认
        .ble_ll_scan_phy_number = 1, // BLE_LL_SCAN_PHY_NUMBER_N（非 2M-PHY 分支）
        .ble_ll_conn_def_auth_pyld_tmo = 3000, // ble_user_cfg.h:159
        .ble_ll_jitter_usecs = 16, // ble_user_cfg.h:155
        .ble_ll_sched_max_adv_pdu_usecs = 376, // :151
        .ble_ll_sched_direct_adv_max_usecs = 502, // :149
        .ble_ll_sched_adv_max_usecs = 852, // :147
        .ble_scan_rsp_data_max_len = 31, // = DEFAULT_BT_LE_EXT_ADV_MAX_SIZE
        .ble_ll_cfg_num_hci_cmd_pkts = 1, // :145
        .ble_ll_ctrl_proc_timeout_ms = 40000, // :143
        .nimble_max_connections = 2,
        .ble_whitelist_size = 12, // ble_user_cfg.h:100
        .ble_acl_buf_size = 255, // :70
        .ble_acl_buf_count = 24, // :76
        .ble_hci_evt_buf_size = 70, // :82
        .ble_multi_adv_instances = 1,
        .ble_ext_adv_max_size = 31, // :88
        .controller_task_stack_size = 4096, // UC_BT_CTRL_TASK_STACK_SIZE（字节）
        .controller_task_prio = 23, // ESP_TASK_BT_CONTROLLER_PRIO
        .controller_run_cpu = 0,
        .enable_qa_test = 0,
        .enable_bqb_test = 0,
        .enable_tx_cca = 0,
        .cca_rssi_thresh = 206, // 256 - DEFAULT_BT_LE_CCA_RSSI_THRESH(50)
        .sleep_en = 0,
        .coex_phy_coded_tx_rx_time_limit = 0,
        .dis_scan_backoff = 0,
        .ble_scan_classify_filter_enable = 1,
        .main_xtal_freq = MAIN_XTAL_FREQ_MHZ,
        .ignore_wl_for_direct_adv = 0,
        .enable_pcl = 0,
        .csa2_select = 1,
        .enable_csr = 0,
        .backoff_rssi = @bitCast(@as(u8, @intCast(-100 + 256))),
        .iso_enabled = 0,
        .iso_bqb_test = 0,
        .iso_fra_unseg = 0,
        .iso_nsfc_en = 0,
        .iso_nsfc_num = 0,
        .iso_buf_count = 0,
        .iso_buf_size = 0,
        .iso_big_count = 0,
        .iso_bis_count = 0,
        .iso_bis_per_big = 0,
        .iso_cig_count = 0,
        .iso_cis_count = 0,
        .iso_cis_per_cig = 0,
        .config_magic = BLE_CONFIG_MAGIC,
    };
    c.btdm = .{
        .version = BTDM_CONFIG_VERSION,
        .task_stack_size = 4096,
        .task_prio = 23,
        .task_run_cpu = 0,
        .hci_cmd_num = 2, // CONFIG_BT_CTRL_HCI_CMD_NUM 默认
        .hci_conn_num = 2, // max_connections + iso_cis + iso_bis
        .sleep_en = 0,
        .version_num = 0,
        .bluetooth_mode = BTDM_CONTROLLER_MODE_BLE,
        .magic = BTDM_CONFIG_MAGIC_VALUE,
    };
    return c;
}

test "defaults: 关键字段与 IDF 默认宏一致" {
    const c = defaults();
    try std.testing.expectEqual(BLE_CONFIG_MAGIC, c.ble.config_magic);
    try std.testing.expectEqual(BTDM_CONFIG_MAGIC_VALUE, c.btdm.magic);
    try std.testing.expectEqual(BTDM_CONFIG_VERSION, c.btdm.version);
    try std.testing.expectEqual(@as(u64, 32_000), c.ble.rtc_freq);
    try std.testing.expectEqual(@as(u8, 40), c.ble.main_xtal_freq);
    try std.testing.expectEqual(@as(u8, 1), c.btdm.bluetooth_mode);
    try std.testing.expectEqual(@as(u16, 4096), c.ble.controller_task_stack_size);
    try std.testing.expectEqual(@as(u16, 4096), c.btdm.task_stack_size);
    try std.testing.expectEqual(@as(u8, 206), c.ble.cca_rssi_thresh);
    // backoff_rssi 是 int8_t ⇒ -100
    try std.testing.expectEqual(@as(i8, -100), @as(i8, @bitCast(c.ble.backoff_rssi)));
}

// ---------------------------------------------------------------------------
// 元素计数：`ble_osal_elem_calc` + `btdm_osal_elem_mempool_init` 的输入
//
// 权威实现：`porting_btdm/controller/ble/src/ble.c:1586-1607`。
// ⚠ 注意 IDF 里五个累加宏是**交叉**用的（`evt` 用的是 `BLE_HOST_CO_COUNT`、
// `evtq` 用 `BLE_HOST_EV_COUNT`、`co` 用 `BLE_HOST_EVQ_COUNT`），看着像笔误，
// 但它就是归档依赖语义 ⇒ 照抄，别"修正"。
// ---------------------------------------------------------------------------

/// `btdm_osal_elem_num_t`：**5 个 u16 = 10 字节**（`btdm_osal.h:36-42`）。
pub const ElemNum = extern struct {
    evt_count: u16 = 0,
    evtq_count: u16 = 0,
    co_count: u16 = 0,
    sem_count: u16 = 0,
    mutex_count: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ElemNum) == 10);
}

/// NimBLE 开启时的 host 侧常量（`ble.c:1573-1581`）。
pub const host_counts = struct {
    pub const co: u16 = 8;
    pub const ev: u16 = 11 + co; // 19
    pub const evq: u16 = 3;
    pub const sem: u16 = 10;
    pub const mutex: u16 = 4;
};

/// 归档里的 `r_ble_ll_get_npl_element_info(cfg, &elem)`。
/// 传的是**整个 `esp_bt_controller_config_t*`**（不是 `&cfg->ble`）——归档可能读 `btdm` 字段。
extern fn r_ble_ll_get_npl_element_info(cfg: ?*anyopaque, elem: *ElemNum) c_int;

/// 只在目标构建里真正引用归档符号；主机上没有归档，走死代码路径（测试必须注入 hook）。
fn callArchive(cfg: *const Config, ll: *ElemNum) void {
    if (@import("builtin").os.tag == .freestanding) {
        _ = r_ble_ll_get_npl_element_info(@constCast(cfg), ll);
    } else {
        ll.* = .{};
    }
}

/// 注入点：主机测试没法调归档，换成替身。未注入时调归档。
pub var npl_info_hook: ?*const fn (cfg: *const Config, elem: *ElemNum) void = null;

/// `bt.c:172-178` 的 **seed**：controller 在算之前就把这几个数预置好了，
/// 不是从零开始（evt 起步就是 3+100）。少这一步会少算 103 个事件。
pub fn seed() ElemNum {
    return .{ .evt_count = 3 + 100, .evtq_count = 1 + 2, .co_count = 0 + 10, .sem_count = 0, .mutex_count = 1 };
}

/// 复刻 `ble_osal_elem_calc`：先问归档要 LL 侧的数目，再按交叉的那组宏累加。
pub fn elemCalc(cfg: *const Config, elem: *ElemNum) void {
    var ll: ElemNum = .{};
    if (npl_info_hook) |f| {
        f(cfg, &ll);
    } else {
        callArchive(cfg, &ll);
    }
    elem.evt_count +%= ll.evt_count +% host_counts.co +% 10;
    elem.evtq_count +%= ll.evtq_count +% host_counts.ev +% 10;
    elem.co_count +%= ll.co_count +% host_counts.evq +% 10;
    elem.sem_count +%= ll.sem_count +% host_counts.sem +% 10;
    elem.mutex_count +%= ll.mutex_count +% host_counts.mutex +% 10;
}

/// 一步到位：seed + elemCalc。`btdm_osal_elem_mempool_init(&elem)` 收的就是它的指针。
pub fn mempoolElemNum(cfg: *const Config) ElemNum {
    var e = seed();
    elemCalc(cfg, &e);
    return e;
}

test "elem: seed 来自 bt.c 的预置值，不是零" {
    const s = seed();
    try std.testing.expectEqual(@as(u16, 103), s.evt_count);
    try std.testing.expectEqual(@as(u16, 3), s.evtq_count);
    try std.testing.expectEqual(@as(u16, 10), s.co_count);
    try std.testing.expectEqual(@as(u16, 0), s.sem_count);
    try std.testing.expectEqual(@as(u16, 1), s.mutex_count);
}

test "elem: 累加用交叉的那组宏（IDF 原样）" {
    npl_info_hook = struct {
        fn f(_: *const Config, e: *ElemNum) void {
            e.* = .{ .evt_count = 1, .evtq_count = 2, .co_count = 3, .sem_count = 4, .mutex_count = 5 };
        }
    }.f;
    defer npl_info_hook = null;
    const c = defaults();
    const e = mempoolElemNum(&c);
    // evt += 1 + co(8) + 10 = 19 ⇒ 103+19 = 122
    try std.testing.expectEqual(@as(u16, 122), e.evt_count);
    // evtq += 2 + ev(19) + 10 = 31 ⇒ 3+31 = 34
    try std.testing.expectEqual(@as(u16, 34), e.evtq_count);
    // co += 3 + evq(3) + 10 = 16 ⇒ 10+16 = 26
    try std.testing.expectEqual(@as(u16, 26), e.co_count);
    // sem += 4 + sem(10) + 10 = 24 ⇒ 0+24 = 24
    try std.testing.expectEqual(@as(u16, 24), e.sem_count);
    // mutex += 5 + mutex(4) + 10 = 19 ⇒ 1+19 = 20
    try std.testing.expectEqual(@as(u16, 20), e.mutex_count);
}

test "elem: 池容量必须覆盖 element 数的上限" {
    npl_info_hook = struct {
        fn f(_: *const Config, e: *ElemNum) void {
            e.* = .{ .evt_count = 60, .evtq_count = 5, .co_count = 5, .sem_count = 5, .mutex_count = 5 };
        }
    }.f;
    defer npl_info_hook = null;
    const e = mempoolElemNum(&defaults());
    // 事件 103+60+8+10 = 181 ⇒ 池 192 够用
    try std.testing.expect(e.evt_count <= 192);
    try std.testing.expect(e.evtq_count <= 48);
    try std.testing.expect(e.co_count <= 32);
    try std.testing.expect(e.sem_count <= 32);
    try std.testing.expect(e.mutex_count <= 32);
}
