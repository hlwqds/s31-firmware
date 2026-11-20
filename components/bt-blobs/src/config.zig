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
    // **以下四项此前全是 0，是 step 6 走错误清理路径的直接原因。**
    // 取值照 `BT_CONTROLLER_INIT_CONFIG_DEFAULT()` 的实测（oracle 打印）：
    //   stack=4096 prio=23 hci_cmd=5 hci_conn=3
    // `task_stack_size = 0` 尤其致命：归档建任务时栈为 0，我们 `taskCreate`
    // 的 `stack_size >= 512` 门直接降级成"只登记不建上下文" ⇒ 任务体永不执行。
    c.btdm.task_stack_size = 4096; // **照 IDF**：实测 env+28 与 oracle 的唯一差异就在这里（8192 vs 4096）
    c.ble.controller_task_stack_size = 8192; // 两处保持一致
    c.btdm.task_prio = 23;
    c.btdm.hci_cmd_num = 5;
    c.btdm.hci_conn_num = 3;
    std.testing.expectEqual(@as(u32, 0x5A5AA5A5), c.ble.config_magic) catch unreachable;
    std.testing.expectEqual(@as(u64, 32_000), c.ble.rtc_freq) catch unreachable;
}

/// `BT_CONTROLLER_INIT_CONFIG_DEFAULT()` 的 BLE_ONLY 分支（`esp_bt.h:487-561`），
/// 取值来自 **controller 侧** 的权威 Kconfig `porting_btdm/controller/ble/Kconfig.in`
/// （归档就是用它编的）——**不是** `ble_user_cfg.h` 的 `#else` 兜底分支，那一组只在
/// `CONFIG_BT_LE_*` 未定义时生效，而 controller 构建里它们是有定义的（差异很大：
/// ACL buf size 517 vs 255、ACL count 10 vs 24、max_connections 3 vs 2、SCA 60 vs 0）。
///
/// ⚠ 若哪天打开 `CONFIG_BT_NIMBLE_EXT_ADV`，`ble_hci_evt_buf_size` 与
/// `ble_ext_adv_max_size` 会变成 **257 / 1650**（`ble_user_cfg.h:34-35` 走 MYNEWT_VAL），
/// 不是这里的 70 / 31。
/// **IDF `BT_CONTROLLER_INIT_CONFIG_DEFAULT()` 的 192 字节实测副本**（esp32s31，oracle 打印）。
///
/// 为什么整份照抄而不是逐字段填：`.ble`（偏移 0..167）里有十几个非 0 字段
/// （事件/连接缓冲数、扫描与同步列表长度、各超时与门限），我们的实现此前**全留 0**；
/// 其中任何一个是"计数"类字段，归档就会按 0 去算尺寸并写坏它自己的 env。
/// 逐字段猜了太多轮，直接把 192 字节搬过来最省事也最忠实。
/// `btdm` 在偏移 **168**（不是 112）：version=0x20260127、stack=4096、prio=23、
/// hci_cmd=5、hci_conn=3、mode=1、magic=0x5a5aa5a5 —— 与我们原先手填的值一致。
pub const idf_cfg192 = [192]u8{
    0x29, 0x10, 0x24, 0x20, 0x04, 0x00, 0x1e, 0x00, 0x08, 0x00, 0x05, 0x01, 0x14, 0x00, 0x14, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x3c, 0x00, 0x02, 0x00, 0xb8, 0x0b, 0x10, 0x00, 0x78, 0x01, 0xf6, 0x01, 0x54, 0x03, 0x72, 0x06,
    0x01, 0x00, 0x00, 0x00, 0x40, 0x9c, 0x00, 0x00, 0x03, 0x00, 0x0c, 0x00, 0x05, 0x02, 0x0a, 0x00,
    0x01, 0x01, 0x01, 0x00, 0x72, 0x06, 0x00, 0x10, 0x17, 0x00, 0x00, 0x00, 0x00, 0xce, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x28, 0x00, 0x00, 0x01, 0x00, 0x9c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xa5, 0xa5, 0x5a, 0x5a,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x27, 0x01, 0x26, 0x20, 0x00, 0x10, 0x17, 0x00,
    0x05, 0x03, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xa5, 0xa5, 0x5a, 0x5a, 0x00, 0x00, 0x00, 0x00,
};

pub fn defaults() Config {
    // **整份照抄 IDF 的 192 字节实测值**（见 `idf_cfg192`）：
    // `.ble` 里十几个计数/门限字段我们此前全留 0，归档据此算尺寸会写坏自己的 env。
    var c: Config = undefined;
    @memcpy(std.mem.asBytes(&c), &idf_cfg192);

    c.btdm = .{
        .version = BTDM_CONFIG_VERSION,
        .task_stack_size = 4096, // **照 IDF**（实测 env+28 的唯一差异就在此：8192 vs 4096）
        .task_prio = 23,
        .task_run_cpu = 0,
        .hci_cmd_num = 2, // CONFIG_BT_CTRL_HCI_CMD_NUM 默认
        .hci_conn_num = 3, // max_connections + iso_cis + iso_bis
        // **sleep_en=0 回退（2026-11-21 试验终判）**：=1 时对象建成 ✓ 但 blob
        // 时间换算（koby0AUV/H2OWtZ 系）每 ticks↔µs 一次 64 位软件除法
        // （__udivdi3，除 rtc_freq=32000 非 2 幂），调度器高频调用 ⇒ CPU 钉死
        // 在除法（NMI 202/202 钉 udivmod）⇒ 睡眠路径需要**睡眠时基基础设施**
        // （RTC timer 接入/换算优化），裸机暂缓。=0 时 early-out 保护性跳过
        // （官方 oracle idf_cfg192[178]=0 同值 ⇒ 非差异点）。
        .sleep_en = 0,
        .version_num = 0,
        .bluetooth_mode = BTDM_CONTROLLER_MODE_BLE,
        .magic = BTDM_CONFIG_MAGIC_VALUE,
    };
    c.ble.controller_task_stack_size = 4096; // 同上，与 btdm 保持一致
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
    // 这几个值直接改 LL 的缓冲/记账，取错来源不会报错、只会让 ACL 包莫名其妙
    // （controller 侧 Kconfig vs ble_user_cfg.h 的兜底分支差得很大）。
    try std.testing.expectEqual(@as(u16, 517), c.ble.ble_acl_buf_size);
    try std.testing.expectEqual(@as(u16, 10), c.ble.ble_acl_buf_count);
    try std.testing.expectEqual(@as(u16, 3), c.ble.nimble_max_connections);
    try std.testing.expectEqual(@as(u16, 4), c.ble.ble_ll_resolv_list_size);
    try std.testing.expectEqual(@as(u16, 60), c.ble.ble_ll_sca);
    try std.testing.expectEqual(@as(u8, 3), c.btdm.hci_conn_num);
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
