//! blob 的 supplicant 回调表（IDF `struct wpa_funcs`，`esp_wifi_driver.h:138`）。
//!
//! IDF 的 `esp_wifi_init()` 在 `esp_wifi_init_internal()` 之后调 `esp_supplicant_init()`
//! （`wpa_supplicant/esp_supplicant/src/esp_wpa_main.c:509`）：填一张 `struct wpa_funcs`，再调 blob 的
//! `esp_wifi_register_wpa_cb_internal(&cb)`——反汇编就是 `g_ic->[444] = cb`。我们的镜像没有 IDF 的
//! `wpa_supplicant` 组件，这一步没人做，`g_ic->[444]` 是空指针；而扫描路径 `scan_add_ssid_do` 对
//! **每个收到的 AP** 在一处不做判空就解引用它（`lw t1, 84(a4)` 取 `wpa_sta_rx_mgmt`），于是第一帧
//! beacon / probe response 就 `load access fault`、`mtval=0x54`（2026-11-26 板侧实测）。
//!
//! 本文件：
//! - `Funcs`：27 个函数指针，字段顺序与 blob 编译时的头文件一致，布局用 comptime 断言钉死；
//! - `WpaIe`：`wifi_wpa_ie_t`（`esp_wifi_driver.h:113`），`wpa_parse_wpa_ie` 的输出；
//! - `parseWpaIe`：`wpa_parse_wpa_ie_wrapper`（`esp_wpa_main.c:280`）的移植——分派
//!   （`rsn_supp/wpa_ie.c:33`）、RSN（`common/wpa_common.c` 的 `wpa_parse_wpa_ie_rsn`）、
//!   WPA（`wpa_parse_wpa_ie_wpa`）、RSNX（`wpa_parse_wpa_ie_rsnxe`），以及套件选择器 → 内部位、
//!   内部位 → 公共 `wifi_cipher_type_t`。blob 的扫描代码拿这些值判 AP 的 authmode，所以
//!   **位值不能自己定**：全部抄 `wpa_supplicant/src/common/defs.h`。
//!
//! 布局的证据直接取自 blob（`objdump -dr` 各目标文件，找 `lw x,444(y)` 之后读的字段）：
//! 16 = `wpa_sta_disconnected_cb`（`ieee80211_sta_new_state`）、44 = `wpa_ap_get_wpa_ie`
//! （beacon / probe response 构造）、60 = `wpa_parse_wpa_ie`（`scan_add_ssid_do`，调用后读
//! 结果的 0 / 4 / 8 / 12 四个字）、72 / 76 = SAE 消息的构造 / 解析（`ieee80211_auth_construct`、
//! `sta_auth_sae`）、84 = `wpa_sta_rx_mgmt`（`scan_add_ssid_do`、`sta_recv_mgmt`）、
//! 92 / 96 = OWE（`ieee80211_add_dh_param`、`sta_recv_assoc`）、104 = `wpa_config_reload`。
//!
//! 编译开关取对照镜像（`tools/wifi-idf-oracle`）的 `compile_commands.json`：
//! `IEEE80211W`、`WPA3_SAE`、`GMAC`、`OWE_STA`、`WPA3_COMPAT` 开；`IEEE80211R`、`SUITEB`、
//! `SUITEB192`、`GCMP`、`DPP` 关。关着的那几个分支返回 0（不计位），与对照镜像逐位一致。
//!
//! 表里填了四个：`wpa_sta_init` / `wpa_sta_deinit`（`wifi_station_start` / `wifi_station_stop` 在表指针
//! 非空时**不判字段是否为空**就调）、`wpa_sta_disconnected_cb`（`ieee80211_sta_new_state` 进 INIT 态时
//! **连表指针都不判空**就调，扫描结束的 SCAN → INIT 也会走到）、`wpa_parse_wpa_ie`（扫描路径判 AP 的
//! authmode）。前三个驱动 `wifi-connect` 自己的请求方（模块 `wifi_connect` 的 `supplicant`）。
//! 其余入口（`wpa_sta_rx_eapol`、`wpa_config_parse_string`、SAE / OWE 的消息构造与解析 …）是连接
//! 路径的，连接那一步再填；其中好几个调用点同样不判空，所以**连接之前必须先填齐**。

const std = @import("std");

/// wifi-connect 的公共入口（按模块名 import，见 `firmware/build.zig` 的 `wifi_connect` 模块）：
/// 请求方 `supplicant`、关联前的策略选择 `rsne`、口令 → PMK 的 `wpa2`、套件换算 `akm` / `ccmp` / `bip`。
const wc = @import("wifi_connect");

// ---------------------------------------------------------------------------
// 套件选择器（`wpa_common.h:63` 的 `RSN_SELECTOR(a,b,c,d)` = 大端 u32）
// ---------------------------------------------------------------------------

const oui_rsn: u32 = 0x000F_AC00; // 00-0F-AC
const oui_wpa: u32 = 0x0050_F200; // 00-50-F2

/// `RSNE_OVERRIDE_IE_VENDOR_TYPE`：厂商形式 RSNE（`CONFIG_WPA3_COMPAT`）。
const vendor_type_rsne_override: u32 = 0x506F_9A29;
/// `RSNXE_OVERRIDE_IE_VENDOR_TYPE`：厂商形式 RSNXE。
const vendor_type_rsnxe_override: u32 = 0x506F_9A2B;

/// `WLAN_EID_*`（`ieee802_11_defs.h`）。
const eid_vendor_specific: u8 = 221;
const eid_rsn: u8 = 48;
const eid_wapi: u8 = 68;
const eid_rsnx: u8 = 244;

const version: u16 = 1; // `RSN_VERSION` == `WPA_VERSION`
const selector_len: usize = 4;
const sel_len_i: c_int = 4;
const pmkid_len: usize = 16;

/// `WLAN_RSNX_CAPAB_SAE_H2E`（`ieee802_11_defs.h:280`）。
const rsnx_capab_sae_h2e: u3 = 5;

// ---------------------------------------------------------------------------
// supplicant 内部位（`wpa_supplicant/src/common/defs.h`）。只列解析路径会产出的那些。
// ---------------------------------------------------------------------------

const proto_wpa: u32 = 1 << 0;
const proto_rsn: u32 = 1 << 1;

/// `WPA_CIPHER_*`。注意与上游 hostap 的位值不同（IDF 版 TKIP 是 BIT(1)、CCMP 是 BIT(3)）。
const cipher = struct {
    const none: u32 = 1 << 0;
    const tkip: u32 = 1 << 1;
    const ccmp: u32 = 1 << 3;
    const cmac128: u32 = 1 << 5;
    const wep40: u32 = 1 << 7;
    const wep104: u32 = 1 << 8;
    const sms4: u32 = 1 << 10;
    const gcmp: u32 = 1 << 11;
    const gcmp256: u32 = 1 << 12;
    const gmac128: u32 = 1 << 13;
    const gmac256: u32 = 1 << 14;
    const gtk_not_used: u32 = 1 << 15;
};

/// `WPA_KEY_MGMT_*`。
const key_mgmt = struct {
    const ieee8021x: u32 = 1 << 0;
    const psk: u32 = 1 << 1;
    const wpa_none: u32 = 1 << 4;
    const ieee8021x_sha256: u32 = 1 << 7;
    const psk_sha256: u32 = 1 << 8;
    const sae: u32 = 1 << 10;
    const ft_sae: u32 = 1 << 11;
    const owe: u32 = 1 << 22;
    const sae_ext_key: u32 = 1 << 26;
};

// ---------------------------------------------------------------------------
// ABI 结构
// ---------------------------------------------------------------------------

/// `wifi_cipher_type_t`（`esp_wifi_types_generic.h`）。
pub const public_cipher = struct {
    pub const none: c_int = 0;
    pub const wep40: c_int = 1;
    pub const wep104: c_int = 2;
    pub const tkip: c_int = 3;
    pub const ccmp: c_int = 4;
    pub const tkip_ccmp: c_int = 5;
    pub const aes_cmac128: c_int = 6;
    pub const sms4: c_int = 7;
    pub const gcmp: c_int = 8;
    pub const gcmp256: c_int = 9;
    pub const aes_gmac128: c_int = 10;
    pub const aes_gmac256: c_int = 11;
    pub const unknown: c_int = 12;
};

/// `wifi_wpa_ie_t`（`esp_wifi_driver.h:113`）：`wpa_parse_wpa_ie` 交给 blob 的解析结果。
/// 密码套件已经是公共的 `wifi_cipher_type_t`；`key_mgmt` 仍是 supplicant 内部位。
pub const WpaIe = extern struct {
    proto: c_int = 0,
    pairwise_cipher: c_int = 0,
    group_cipher: c_int = 0,
    key_mgmt: c_int = 0,
    capabilities: c_int = 0,
    num_pmkid: usize = 0,
    /// 指向被解析元素里的 PMKID 列表（`num_pmkid == 0` 时也指向列表该在的位置）。
    pmkid: ?[*]const u8 = null,
    mgmt_group_cipher: c_int = 0,
    rsnxe_capa: u8 = 0,
};

/// `struct wpa_ie_data`（`wpa_common.h`）里 wrapper 会读的字段（它不读 `has_group`、`has_pairwise`）。
const IeData = struct {
    proto: u32 = 0,
    pairwise_cipher: u32 = 0,
    group_cipher: u32 = 0,
    key_mgmt: u32 = 0,
    capabilities: u32 = 0,
    num_pmkid: usize = 0,
    pmkid: ?[*]const u8 = null,
    mgmt_group_cipher: u32 = 0,
    rsnxe_capa: u8 = 0,
};

/// `struct wpa_funcs`（`esp_wifi_driver.h:138`，27 个字段无条件编译，顺序即结构体顺序）。
/// AP（softap）那 7 个与 SAE / OWE 的 6 个本 STA 不填，保留位置是为了后面字段的偏移。
pub const Funcs = extern struct {
    wpa_sta_init: ?*const fn () callconv(.c) bool = null,
    wpa_sta_deinit: ?*const fn () callconv(.c) bool = null,
    wpa_sta_connect: ?*const fn ([*]u8) callconv(.c) c_int = null,
    wpa_sta_connected_cb: ?*const fn ([*]u8) callconv(.c) void = null,
    wpa_sta_disconnected_cb: ?*const fn (u8) callconv(.c) void = null,
    wpa_sta_rx_eapol: ?*const fn ([*]u8, [*]u8, u32) callconv(.c) c_int = null,
    wpa_sta_in_4way_handshake: ?*const fn () callconv(.c) bool = null,
    wpa_ap_init: ?*const fn () callconv(.c) ?*anyopaque = null,
    wpa_ap_deinit: ?*const fn (?*anyopaque) callconv(.c) bool = null,
    wpa_ap_join: ?*const fn (?*anyopaque) callconv(.c) bool = null,
    wpa_ap_remove: ?*const fn ([*]u8) callconv(.c) bool = null,
    wpa_ap_get_wpa_ie: ?*const fn (*usize) callconv(.c) ?[*]u8 = null,
    wpa_ap_rx_eapol: ?*const fn (?*anyopaque, ?*anyopaque, [*]u8, usize) callconv(.c) bool = null,
    wpa_ap_get_peer_spp_msg: ?*const fn (?*anyopaque, *bool, *bool) callconv(.c) void = null,
    wpa_config_parse_string: ?*const fn ([*:0]const u8, *usize) callconv(.c) ?[*:0]u8 = null,
    wpa_parse_wpa_ie: ?*const fn ([*]const u8, usize, *WpaIe) callconv(.c) c_int = null,
    wpa_config_bss: ?*const fn ([*]u8) callconv(.c) c_int = null,
    wpa_michael_mic_failure: ?*const fn (u16) callconv(.c) c_int = null,
    wpa3_build_sae_msg: ?*const fn ([*]u8, u32, *usize) callconv(.c) ?[*]u8 = null,
    wpa3_parse_sae_msg: ?*const fn ([*]u8, usize, u32, u16) callconv(.c) c_int = null,
    wpa3_hostap_handle_auth: ?*const fn ([*]u8, usize, u32, u16, [*]u8) callconv(.c) c_int = null,
    wpa_sta_rx_mgmt: ?*const fn (u8, [*]u8, usize, [*]u8, i8, u8, u64) callconv(.c) c_int = null,
    wpa_config_done: ?*const fn () callconv(.c) void = null,
    owe_build_dhie: ?*const fn (u16) callconv(.c) ?[*]u8 = null,
    owe_process_assoc_resp: ?*const fn ([*]const u8, usize, [*]const u8, usize) callconv(.c) c_int = null,
    wpa_sta_clear_curr_pmksa: ?*const fn () callconv(.c) void = null,
    wpa_config_reload: ?*const fn () callconv(.c) void = null,
};

comptime {
    // ilp32（板子）。偏移即上文的 blob 证据：84 是崩溃点读的字段（`mtval=0x54`），60 是扫描路径调的回调。
    if (@sizeOf(usize) == 4) {
        if (@offsetOf(Funcs, "wpa_sta_rx_mgmt") != 84) @compileError("wpa_sta_rx_mgmt 偏移应为 84");
        if (@offsetOf(Funcs, "wpa_parse_wpa_ie") != 60) @compileError("wpa_parse_wpa_ie 偏移应为 60");
        if (@offsetOf(Funcs, "wpa_config_parse_string") != 56) @compileError("wpa_config_parse_string 偏移应为 56");
        if (@sizeOf(WpaIe) != 36) @compileError("wifi_wpa_ie_t 应为 36 字节");
        if (@offsetOf(WpaIe, "mgmt_group_cipher") != 28) @compileError("mgmt_group_cipher 偏移应为 28");
        if (@offsetOf(WpaIe, "rsnxe_capa") != 32) @compileError("rsnxe_capa 偏移应为 32");
    }
    // 两种字长都成立：27 个函数指针，不多不少。
    if (@sizeOf(Funcs) != 27 * @sizeOf(usize)) @compileError("struct wpa_funcs 应为 27 个函数指针");
}

/// 登记给 blob 的那张表。字段顺序即 `struct wpa_funcs` 的顺序（`esp_wifi_driver.h:138`）。
pub var funcs: Funcs = .{
    .wpa_sta_init = &staInit,
    .wpa_sta_deinit = &staDeinit,
    .wpa_sta_connect = &staConnect,
    .wpa_sta_connected_cb = &staConnected,
    .wpa_sta_disconnected_cb = &staDisconnected,
    .wpa_sta_rx_eapol = &staRxEapol,
    .wpa_sta_in_4way_handshake = &in4wayHandshake,
    .wpa_config_parse_string = &parseConfigString,
    .wpa_parse_wpa_ie = &parseWpaIe,
    .wpa_config_done = &configDone,
    .wpa_sta_clear_curr_pmksa = &clearCurrPmksa,
    .wpa_config_reload = &configReload,
};

/// blob 的请求方实例：`wpa_sta_init` 建出来，`wpa_sta_deinit` 收回去（`attached` 为假时内容没有定义）。
var supplicant: wc.supplicant.Supplicant = undefined;
var attached: bool = false;

/// `wpa_attach()`（`esp_wpa_main.c:136`）= `wpa_sm_init()`（`rsn_supp/wpa.c:2407`）：状态机整块清零、
/// 停在初始态（IDF 的 `WPA_INACTIVE`；这里是图 12-49 的 INITIALIZE），没有任何密钥。认证方地址、
/// AKM、RSNE 都还没有（`aa` 为零、`pmk_set` 为假），到连接那一步再给。`wifi_station_start` 每次
/// start 都调它，所以每次都是一个全新实例（同 IDF 的 `memset(sm, 0, ...)`）。
///
/// `wpa_attach` 另有一件事这里一并做：登记 EAPOL 发送完成回调（`eapol_txcb`）——密钥是在消息 4
/// 「发送完成」时才装进驱动的（见 `eapolTxDone`）。`esp_set_scan_ie()` 是空函数（对照镜像的
/// `WNM` / `MBO` 关），不做。
fn staInit() callconv(.c) bool {
    supplicant = .{ .cfg = .{
        .spa = @splat(0),
        .aa = @splat(0),
        .akm = 0,
        .pairwise = .ccmp128,
        .group = .ccmp128,
        .mfp = false,
        .ap_rsne = &[_]u8{},
        .sta_rsne = &[_]u8{},
    } };
    attached = true;
    resetConnectState();
    return drv.register_eapol_txdone(&eapolTxDone) == 0;
}

/// `wpa_deattach()` = `wpa_sm_deinit()` + 注销 EAPOL 发送完成回调：收回请求方。
fn staDeinit() callconv(.c) bool {
    attached = false;
    _ = drv.register_eapol_txdone(null);
    return true;
}

/// 下面这一组原因码（`wifi_err_reason_t`）下 IDF 的 `wpa_sta_disconnected_cb`（`esp_wpa_main.c:303`）清掉
/// 当前 PMKSA 并 `wpa_sm_notify_disassoc()`——取消 PTK 重键定时、丢掉 PMK / PTK / GTK / IGTK、清 BSSID。
/// 其余原因码 IDF 只按需清 PMKSA 缓存；本项目不做 PMKSA 缓存（`supplicant.zig` 文件头），所以不动。
fn dropsSa(reason: u8) bool {
    return switch (reason) {
        2, // AUTH_EXPIRE
        6, // CLASS2_FRAME_FROM_NONAUTH_STA
        7, // CLASS3_FRAME_FROM_NONASSOC_STA
        15, // 4WAY_HANDSHAKE_TIMEOUT
        49, // INVALID_PMKID
        50, // INVALID_MDE
        51, // INVALID_FTE
        202, // AUTH_FAIL
        203, // ASSOC_FAIL
        204, // HANDSHAKE_TIMEOUT
        205, // CONNECTION_FAIL
        => true,
        else => false,
    };
}

fn staDisconnected(reason: u8) callconv(.c) void {
    // IDF 在这一段之后无条件清的几样（重放计数等）里，本镜像有对应的只有连接进度：下一次关联从头来。
    msg4_in_flight = false;
    negotiation_done = false;
    // 表一直登记着：`wifi_station_stop` 之后进 INIT 态仍会走到这里，那时请求方已经收回。
    if (!attached or !dropsSa(reason)) return;
    supplicant.disconnect(); // 12.6.18：删除 PTKSA、GTKSA、IGTKSA，端口关掉
    supplicant.cfg.aa = @splat(0);
}

/// IDF `esp_supplicant_init()` 的最小形态：把表登记给 blob（`g_ic->[444]`）。返回 blob 的返回码（0 = 成功）。
pub fn register() c_int {
    return register_wpa_cb(&funcs);
}

const register_wpa_cb = @extern(*const fn (*Funcs) callconv(.c) c_int, .{ .name = "esp_wifi_register_wpa_cb_internal" });
const get_config_sae_pwe_h2e = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "esp_wifi_get_config_sae_pwe_h2e_internal" });

// ---------------------------------------------------------------------------
// 套件选择器 → supplicant 内部位
// ---------------------------------------------------------------------------

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn le16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}

/// `rsn_selector_to_bitfield`（`wpa_common.c:295`）。对照镜像 `GCMP` 关 → 8、9 不计位。
fn rsnCipherBit(suite: u32) u32 {
    return switch (suite) {
        oui_rsn | 0 => cipher.none,
        oui_rsn | 1 => cipher.wep40,
        oui_rsn | 2 => cipher.tkip,
        oui_rsn | 4 => cipher.ccmp,
        oui_rsn | 5 => cipher.wep104,
        oui_rsn | 6 => cipher.cmac128,
        oui_rsn | 7 => cipher.gtk_not_used,
        oui_rsn | 11 => cipher.gmac128,
        oui_rsn | 12 => cipher.gmac256,
        // GCMP-128 / GCMP-256（开关关）、CCMP-256、BIP-CMAC-256（没有位）
        else => 0,
    };
}

/// `wpa_cipher_valid_mgmt_group`（`wpa_common.c:402`）。
fn validMgmtGroup(c: u32) bool {
    return c == cipher.gtk_not_used or c == cipher.cmac128 or c == cipher.gmac128 or c == cipher.gmac256;
}

/// `rsn_key_mgmt_to_bitfield`（`wpa_common.c:326`）。对照镜像 `IEEE80211R`、`SUITEB`、`SUITEB192`、
/// `DPP` 关 → FT（3、4）、Suite-B（11、12）、DPP 不计位。
fn rsnKeyMgmtBit(suite: u32) u32 {
    return switch (suite) {
        oui_rsn | 1 => key_mgmt.ieee8021x,
        oui_rsn | 2 => key_mgmt.psk,
        oui_rsn | 5 => key_mgmt.ieee8021x_sha256,
        oui_rsn | 6 => key_mgmt.psk_sha256,
        oui_rsn | 8 => key_mgmt.sae,
        oui_rsn | 9 => key_mgmt.ft_sae,
        oui_rsn | 18 => key_mgmt.owe,
        oui_rsn | 24 => key_mgmt.sae_ext_key,
        else => 0,
    };
}

/// `wpa_selector_to_bitfield`（`wpa_common.c:376`），WPA v1 的 OUI 00-50-F2。
fn wpaCipherBit(suite: u32) u32 {
    return switch (suite) {
        oui_wpa | 0 => cipher.none,
        oui_wpa | 1 => cipher.wep40,
        oui_wpa | 2 => cipher.tkip,
        oui_wpa | 4 => cipher.ccmp,
        oui_wpa | 5 => cipher.wep104,
        else => 0,
    };
}

/// `wpa_key_mgmt_to_bitfield`（`wpa_common.c:391`），WPA v1。
fn wpaKeyMgmtBit(suite: u32) u32 {
    return switch (suite) {
        oui_wpa | 0 => key_mgmt.wpa_none,
        oui_wpa | 1 => key_mgmt.ieee8021x,
        oui_wpa | 2 => key_mgmt.psk,
        else => 0,
    };
}

/// `cipher_type_map_supp_to_public`（`rsn_supp/wpa.c:89`）：按**整个位掩码**做 switch，
/// 所以成对套件列表是「CCMP + TKIP」以外的组合（如 WEP40 + WEP104）都落到 `UNKNOWN`。
pub fn toPublicCipher(c: u32) c_int {
    return switch (c) {
        cipher.none => public_cipher.none,
        cipher.wep40 => public_cipher.wep40,
        cipher.wep104 => public_cipher.wep104,
        cipher.tkip => public_cipher.tkip,
        cipher.ccmp => public_cipher.ccmp,
        cipher.ccmp | cipher.tkip => public_cipher.tkip_ccmp,
        cipher.cmac128 => public_cipher.aes_cmac128,
        cipher.gmac128 => public_cipher.aes_gmac128,
        cipher.gmac256 => public_cipher.aes_gmac256,
        cipher.sms4 => public_cipher.sms4,
        cipher.gcmp => public_cipher.gcmp,
        cipher.gcmp256 => public_cipher.gcmp256,
        else => public_cipher.unknown,
    };
}

// ---------------------------------------------------------------------------
// 解析：RSN / WPA / RSNX
// ---------------------------------------------------------------------------

const SuiteList = struct {
    bits: *u32,
    /// `left == 1`（字段残缺）时的返回码。
    short: c_int,
    /// 计数为 0 或装不下时的返回码。
    count: c_int,
};

/// 「Count(2) + n × 选择器(4)」字段。`left >= 2` 才读：先把目标清零（C 版在校验计数之前清，
/// 所以校验失败时留下的也是 0 而不是默认值），再校验计数。`left == 1` 返回 `short`。
/// 没有内容可读（`left == 0`）时什么都不做，目标保持默认值。
fn readSuiteList(ie: []const u8, pos: *usize, left: *c_int, f: SuiteList, comptime toBit: fn (u32) u32) ?c_int {
    if (left.* >= 2) {
        f.bits.* = 0;
        var count: usize = le16(ie[pos.*..]);
        pos.* += 2;
        left.* -= 2;
        if (count == 0 or left.* < @as(c_int, @intCast(count)) * sel_len_i) return f.count;
        while (count > 0) : (count -= 1) {
            f.bits.* |= toBit(be32(ie[pos.*..]));
            pos.* += selector_len;
            left.* -= sel_len_i;
        }
    } else if (left.* == 1) {
        return f.short;
    }
    return null;
}

/// `wpa_parse_wpa_ie_rsn`。`ie` 含 Element ID 与 Length。返回码与 C 版逐一对应（-1 太短、-2 头不对、
/// -3/-5/-7 字段残缺、-4/-6 计数越界、-9 PMKID 越界、-10 管理帧密码套件不支持）。出错时已填的
/// 字段保留——C 版就是中途返回，wrapper 照样把它们拷给 blob。
fn parseRsn(ie: []const u8, d: *IeData) c_int {
    d.* = .{
        .proto = proto_rsn,
        .pairwise_cipher = cipher.ccmp,
        .group_cipher = cipher.ccmp,
        .key_mgmt = key_mgmt.ieee8021x,
        .mgmt_group_cipher = cipher.cmac128,
    };
    if (ie.len < 4) return -1; // 长度 0 也在这里：没有 RSN IE，静默失败

    var pos: usize = undefined;
    if (ie.len >= 8 and ie[1] >= 6 and ie[1] == ie.len - 2 and
        be32(ie[2..]) == vendor_type_rsne_override and le16(ie[6..]) == version)
    {
        // 厂商形式：Element ID | Length | Vendor Type(4) | Version(2) | 正文的其余部分
        pos = 8;
    } else {
        if (ie[0] != eid_rsn or ie[1] != ie.len - 2 or le16(ie[2..]) != version) return -2;
        pos = 4;
    }
    var left: c_int = @intCast(ie.len - pos);

    if (left >= sel_len_i) {
        d.group_cipher = rsnCipherBit(be32(ie[pos..]));
        pos += selector_len;
        left -= sel_len_i;
    } else if (left > 0) {
        return -3;
    }

    if (readSuiteList(ie, &pos, &left, .{ .bits = &d.pairwise_cipher, .short = -5, .count = -4 }, rsnCipherBit)) |e| return e;
    if (readSuiteList(ie, &pos, &left, .{ .bits = &d.key_mgmt, .short = -7, .count = -6 }, rsnKeyMgmtBit)) |e| return e;

    if (left >= 2) {
        d.capabilities = le16(ie[pos..]);
        pos += 2;
        left -= 2;
    }

    if (left >= 2) {
        const n: usize = le16(ie[pos..]);
        pos += 2;
        left -= 2;
        // C：`num_pmkid > (unsigned int) left / PMKID_LEN`
        const room: usize = @intCast(@max(left, 0));
        if (n > room / pmkid_len) {
            d.num_pmkid = 0;
            return -9;
        }
        d.num_pmkid = n;
        d.pmkid = ie.ptr + pos;
        pos += n * pmkid_len;
        left -= @intCast(n * pmkid_len);
    }

    if (left >= sel_len_i) {
        d.mgmt_group_cipher = rsnCipherBit(be32(ie[pos..]));
        if (!validMgmtGroup(d.mgmt_group_cipher)) return -10;
    }
    // 末尾多出的字节：C 版忽略
    return 0;
}

/// `wpa_parse_wpa_ie_wpa`：厂商元素 00-50-F2:01（Element ID | Length | OUI+Type(4) | Version(2)）。
fn parseWpa(ie: []const u8, d: *IeData) c_int {
    d.* = .{
        .proto = proto_wpa,
        .pairwise_cipher = cipher.tkip,
        .group_cipher = cipher.tkip,
        .key_mgmt = key_mgmt.ieee8021x,
        .mgmt_group_cipher = 0,
    };
    if (ie.len < 8) return -1;

    if (ie[0] != eid_vendor_specific or ie[1] != ie.len - 2 or be32(ie[2..]) != oui_wpa | 1 or
        le16(ie[6..]) != version) return -2;
    var pos: usize = 8;
    var left: c_int = @intCast(ie.len - 8);

    if (left >= sel_len_i) {
        d.group_cipher = wpaCipherBit(be32(ie[pos..]));
        pos += selector_len;
        left -= sel_len_i;
    } else if (left > 0) {
        return -3;
    }

    if (readSuiteList(ie, &pos, &left, .{ .bits = &d.pairwise_cipher, .short = -5, .count = -4 }, wpaCipherBit)) |e| return e;
    if (readSuiteList(ie, &pos, &left, .{ .bits = &d.key_mgmt, .short = -7, .count = -6 }, wpaKeyMgmtBit)) |e| return e;

    if (left >= 2) {
        d.capabilities = le16(ie[pos..]);
        pos += 2;
        left -= 2;
    }
    return 0;
}

/// `wpa_parse_wpa_ie_rsnxe`：只取 capabilities 一个字节。STA 配了「必须 H2E」而 AP 不支持时返回 -1。
fn parseRsnx(ie: []const u8, d: *IeData) c_int {
    const sae_pwe = get_config_sae_pwe_h2e(0); // `WIFI_IF_STA`
    d.* = .{};
    if (ie.len < 3) return -1;
    // 厂商形式：Element ID | Length | Vendor Type(4) | capabilities
    const capa: u8 = if (ie[0] == eid_vendor_specific and ie[1] >= 1 + 4) ie[6] else ie[2];
    if (sae_pwe == 1 and (capa & (@as(u8, 1) << rsnx_capab_sae_h2e)) == 0) return -1;
    d.rsnxe_capa = capa;
    return 0;
}

/// `wpa_parse_wpa_ie`（`rsn_supp/wpa_ie.c:33`）的分派。WAPI 元素直接返回 0；C 版此时不清 `data`
/// （wrapper 读到的是栈上的旧值），这里给确定的零。
fn dispatch(ie: []const u8, d: *IeData) c_int {
    if (ie.len >= 1) {
        if (ie[0] == eid_rsn) return parseRsn(ie, d);
        if (ie[0] == eid_rsnx) return parseRsnx(ie, d);
        if (ie[0] == eid_wapi) {
            d.* = .{};
            return 0;
        }
    }
    if (ie.len >= 6 and ie[0] == eid_vendor_specific and ie[1] >= 4) {
        const vtype = be32(ie[2..]);
        if (vtype == vendor_type_rsne_override) return parseRsn(ie, d);
        if (vtype == vendor_type_rsnxe_override) return parseRsnx(ie, d);
    }
    return parseWpa(ie, d);
}

/// 回调本体：`wpa_parse_wpa_ie_wrapper`（`esp_wpa_main.c:280`）。返回码原样透传，结果无论成败都填。
fn parseWpaIe(ie: [*]const u8, ie_len: usize, data: *WpaIe) callconv(.c) c_int {
    var d: IeData = .{};
    const ret = dispatch(ie[0..ie_len], &d);
    data.* = .{
        .proto = @bitCast(d.proto),
        .pairwise_cipher = toPublicCipher(d.pairwise_cipher),
        .group_cipher = toPublicCipher(d.group_cipher),
        .key_mgmt = @bitCast(d.key_mgmt),
        .capabilities = @bitCast(d.capabilities),
        .num_pmkid = d.num_pmkid,
        .pmkid = d.pmkid,
        .mgmt_group_cipher = toPublicCipher(d.mgmt_group_cipher),
        .rsnxe_capa = d.rsnxe_capa,
    };
    return ret;
}

// ---------------------------------------------------------------------------
// 连接路径（WPA2-PSK）：blob 的 MAC / MLME 做认证、关联与收发，这里只做请求方的逻辑
// ---------------------------------------------------------------------------
//
// 分工照 IDF：
// - `esp_wifi_connect_internal()`：驱动从扫描缓存里选 BSS，调 `wpa_sta_connect(bssid)`。请求方按 AP 的
//   RSNE 选 AKM 与密码套件、算 PMK，把本 STA 的 RSNE 交给驱动（放进关联请求），驱动才发关联请求。
// - 关联成功 → `wpa_sta_connected_cb(bssid)`。
// - AP 发来的每一帧 EAPOL-Key → `wpa_sta_rx_eapol(src, buf, len)`。要回应的帧经 `esp_wifi_internal_tx()`
//   发出去：Ethernet II 头 + EAPOL，帧类型 0x888E（驱动收帧时给的也是这个形状，EAPOL 在 +14）。
// - 消息 4「发送完成」→ `eapol_txcb`。这时才把 PTK、GTK、IGTK 装进驱动（`esp_wifi_set_sta_key_internal` /
//   `esp_wifi_set_igtk_internal`），驱动随后进 RUN 态、发 `WIFI_EVENT_STA_CONNECTED`。
//
// 范围：RSN + PSK。WPA v1、企业、SAE、OWE、FT、DPP 都不做——选出来的 AKM 不是 PSK 就拒绝。

/// 板上打到串口；主机用例里不打印（`board.log` 直接写 UART 寄存器）。
fn logLine(comptime fmt: []const u8, args: anytype) void {
    if (comptime @import("builtin").os.tag == .freestanding)
        @import("board").log.line("wpa: " ++ fmt, args);
}

fn randomFromBoard(dst: *[32]u8) void {
    @import("board").rng.fill(dst);
}

fn randomForHost(dst: *[32]u8) void {
    @memset(dst, 0x5a);
}

/// SNonce 的随机源。板上用 TRNG；主机上填一个定值（只有用例会跑到，用例自己换成向量里的 SNonce）。
pub var fill_random: *const fn (*[32]u8) void =
    if (@import("builtin").os.tag == .freestanding) &randomFromBoard else &randomForHost;

// ---- 驱动的入口（都是 blob 导出的函数；签名抄 IDF） ---------------------------------

const wifi_if_sta: c_int = 0;
const eid_ie_rsn: u8 = 48;
const eapol_ethertype: u16 = 0x888e;

/// IDF 给驱动的 app IE 类型（`wifi_appie_t`）里用到的两个；取值在 C 侧 `_Static_assert` 验过。
const appie_rsn: u8 = 4;

/// IDF `enum key_flag`（`esp_wifi_driver.h:227`）：装 PTK / GTK 时告诉驱动这把钥匙的用途。
const key_flag_rx: c_int = 1 << 2;
const key_flag_tx: c_int = 1 << 3;
const key_flag_group: c_int = 1 << 4;
const key_flag_pairwise: c_int = 1 << 5;

/// IDF `enum wpa_alg` 里本镜像会装进驱动的两个。
const alg_ccmp: c_int = 3;
const alg_gcmp: c_int = 9;

/// IDF 的 `ASSOC_IE_LEN`：本 STA 的 RSNE 放在这个大小的静态缓冲里，IDF 把**整个缓冲的长度**交给驱动。
const assoc_ie_len: usize = 128;

/// `struct wifi_ssid`（`esp_wifi_driver.h:96`）。
const Ssid = extern struct { len: c_int, ssid: [32]u8 };

/// `wifi_pmf_config_t`：管理帧保护的通告。
pub const PmfConfig = extern struct { capable: bool = false, required: bool = false };

/// `wifi_config_t` 的 `sta` 成员（`wifi_sta_config_t`，`esp_wifi_types_generic.h`）。枚举 4 字节，全是定宽字段，
/// 所以前 130 字节在两种字长下布局相同。偏移由对照镜像的编译参数在 C 侧验过（2026-11-26，把 `offsetof`
/// 编成数组大小再用 `nm` 读）：ssid@0、password@32、scan_method@96、bssid_set@100、channel@107、
/// sort_method@112、threshold@116（rssi@116、authmode@120）、pmf_cfg@128（capable@128、required@129），
/// 总长 184，`wifi_config_t` 也是 184。
/// 本镜像只填 `ssid`、`password`、`pmf_cfg`，其余保持 0（`threshold.authmode = 0`：IDF 见到口令长度 ≥ 8
/// 时自动按 WPA2 及以上处理）。
pub const StaConfig = extern struct {
    ssid: [32]u8 = @splat(0),
    password: [64]u8 = @splat(0),
    scan_method: c_int = 0, // WIFI_FAST_SCAN
    bssid_set: bool = false,
    bssid: [6]u8 = @splat(0),
    channel: u8 = 0,
    listen_interval: u16 = 0,
    sort_method: c_int = 0, // WIFI_CONNECT_AP_BY_SIGNAL
    threshold: extern struct { rssi: i8 = 0, authmode: c_int = 0, rssi_5g_adjustment: u8 = 0 } = .{},
    pmf_cfg: PmfConfig = .{},
    /// 其后的字段（两个位域字、SAE 配置、HE / VHT 能力、H2E identifier）本镜像不设，保持 0。
    /// 不逐个建模：第二个位域字紧跟在 `failure_retry_cnt` 后面，C 的位域分配规则与 Zig 不同。
    rest: [184 - 130]u8 = @splat(0),
};

/// `wifi_wpa_igtk_t`（`esp_wifi_driver.h:210`）：Key ID（小端 u16）、IPN（6）、IGTK 补到 32。
pub const Igtk = extern struct { keyid: [2]u8 = .{ 0, 0 }, pn: [6]u8 = @splat(0), igtk: [32]u8 = @splat(0) };

comptime {
    if (@sizeOf(StaConfig) != 184) @compileError("wifi_sta_config_t 应为 184 字节");
    if (@offsetOf(StaConfig, "password") != 32 or @offsetOf(StaConfig, "pmf_cfg") != 128 or
        @offsetOf(StaConfig, "rest") != 130) @compileError("wifi_sta_config_t 的偏移不对");
    if (@sizeOf(Igtk) != 40) @compileError("wifi_wpa_igtk_t 应为 40 字节");
}

const drv = struct {
    const sta_prof_is_rsn = @extern(*const fn () callconv(.c) bool, .{ .name = "esp_wifi_sta_prof_is_rsn_internal" });
    const sta_prof_ssid = @extern(*const fn () callconv(.c) *const Ssid, .{ .name = "esp_wifi_sta_get_prof_ssid_internal" });
    const sta_prof_password = @extern(*const fn () callconv(.c) [*:0]const u8, .{ .name = "esp_wifi_sta_get_prof_password_internal" });
    const get_config = @extern(*const fn (c_int, *StaConfig) callconv(.c) c_int, .{ .name = "esp_wifi_get_config" });
    const set_config = @extern(*const fn (c_int, *const StaConfig) callconv(.c) c_int, .{ .name = "esp_wifi_set_config" });
    const get_macaddr = @extern(*const fn (u8, *[6]u8) callconv(.c) c_int, .{ .name = "esp_wifi_get_macaddr_internal" });
    const sta_get_ie = @extern(*const fn ([*]const u8, u8) callconv(.c) ?[*]const u8, .{ .name = "esp_wifi_sta_get_ie" });
    const ap_notify_completed_rsne = @extern(*const fn () callconv(.c) bool, .{ .name = "esp_wifi_sta_is_ap_notify_completed_rsne_internal" });
    const set_appie = @extern(*const fn (u8, [*]const u8, u16, u8) callconv(.c) c_int, .{ .name = "esp_wifi_set_appie_internal" });
    const sta_connect = @extern(*const fn ([*]const u8) callconv(.c) c_int, .{ .name = "esp_wifi_sta_connect_internal" });
    const set_sta_key = @extern(*const fn (c_int, [*]const u8, c_int, c_int, ?[*]const u8, usize, [*]const u8, usize, c_int) callconv(.c) c_int, .{ .name = "esp_wifi_set_sta_key_internal" });
    const set_igtk = @extern(*const fn (u8, *const Igtk) callconv(.c) c_int, .{ .name = "esp_wifi_set_igtk_internal" });
    const internal_tx = @extern(*const fn (c_int, [*]const u8, u16) callconv(.c) c_int, .{ .name = "esp_wifi_internal_tx" });
    const register_eapol_txdone = @extern(*const fn (?*const fn ([*]u8, usize, bool) callconv(.c) void) callconv(.c) c_int, .{ .name = "esp_wifi_register_eapol_txdonecb_internal" });
    const connect = @extern(*const fn () callconv(.c) c_int, .{ .name = "esp_wifi_connect_internal" });
    /// IDF `wpa_neg_complete()` 调的就是它：告诉驱动钥匙协商完成。
    const auth_done = @extern(*const fn () callconv(.c) bool, .{ .name = "esp_wifi_auth_done_internal" });
    const disconnect = @extern(*const fn () callconv(.c) c_int, .{ .name = "esp_wifi_disconnect_internal" });
};

// ---- 状态 ------------------------------------------------------------------------------

/// IDF 的 `assoc_ie_buf`（`rsn_supp/wpa.c:63`）：本 STA 的 RSNE，从下标 2 起。前两个字节是驱动的——
/// `esp_wifi_set_appie_internal(type, buf, len, flag = 1)` 只记下指针，并把 len 当 u16 写进 `buf[0..2]`
/// （`ieee80211_set_appie` 的反汇编）。IDF 给驱动的是整个缓冲的长度（RSN：126），不是元素的真实长度，照抄。
var assoc_ie_buf: [assoc_ie_len + 2]u8 = @splat(0);

/// AP 在 Beacon / Probe Response 里的 RSNE（整段元素）。请求方校验消息 3 时逐字节比对它，所以要留一份。
var ap_rsne_buf: [256]u8 = @splat(0);

/// 发给 AP 的 EAPOL 帧：前 14 字节是 Ethernet 头，EAPOL 从下标 14 起（请求方直接把回应写到这里）。
/// 静态缓冲——驱动发完之前不能动它。
var eapol_tx_buf: [14 + 256]u8 = @splat(0);

/// 消息 4 已交给驱动、还没收到「发送完成」。密钥要等那一刻才装（IDF `eapol_txcb`）。
var msg4_in_flight: bool = false;
/// 四次握手完成：PTK（以及消息 3 带来的 GTK、IGTK）已经装进驱动。
var negotiation_done: bool = false;

/// 已经装进驱动的 GTK / IGTK 是哪一把（Key ID 与起始 PN）。IDF 不把「已经在用的同一把」再装一遍
/// （`wpa_supplicant_install_gtk` / `wpa_supplicant_install_igtk` 开头的检测），这里据此认「同一把」。
var gtk_installed: struct { valid: bool = false, key_id: u8 = 0, rsc: u64 = 0 } = .{};
var igtk_installed: struct { valid: bool = false, key_id: u16 = 0, ipn: u64 = 0 } = .{};

fn resetConnectState() void {
    msg4_in_flight = false;
    negotiation_done = false;
    gtk_installed = .{};
    igtk_installed = .{};
}

/// 给探针读的进度。
pub const Status = struct {
    attached: bool,
    state: wc.supplicant.KmState,
    phase: wc.supplicant.Phase,
    msg4_in_flight: bool,
    negotiation_done: bool,
    pmk_set: bool,
    ptk_valid: bool,
    gtk_valid: bool,
    rejects: u32,
    last_error: ?anyerror,
    /// 选中的 AP 的 RSNE；还没走到 `wpa_sta_connect` 时是空的。
    ap_rsne: []const u8,
    /// 本 STA 交给驱动的 RSNE（不含驱动占的前两个字节）。
    sta_rsne: []const u8,
};

pub fn status() Status {
    const empty: []const u8 = &[_]u8{};
    if (!attached) return .{
        .attached = false,
        .state = .initialization,
        .phase = .idle,
        .msg4_in_flight = false,
        .negotiation_done = false,
        .pmk_set = false,
        .ptk_valid = false,
        .gtk_valid = false,
        .rejects = 0,
        .last_error = null,
        .ap_rsne = empty,
        .sta_rsne = empty,
    };
    return .{
        .attached = true,
        .state = supplicant.state,
        .phase = supplicant.phase,
        .msg4_in_flight = msg4_in_flight,
        .negotiation_done = negotiation_done,
        .pmk_set = supplicant.pmk_set,
        .ptk_valid = supplicant.ptksa.valid,
        .gtk_valid = supplicant.gtksa.valid,
        .rejects = supplicant.rejects,
        .last_error = supplicant.last_error,
        .ap_rsne = supplicant.cfg.ap_rsne,
        .sta_rsne = supplicant.cfg.sta_rsne,
    };
}

/// 诊断：请求方手里的钥匙与 `other` 的前 16 字节逐字节比较的位图，**不暴露钥匙本身**：
/// `equal` 的 bit i = 第 i 字节相等，`mine_nonzero` / `other_nonzero` 的 bit i = 各自第 i 字节非 0。
pub const KeyCompare = struct { equal: u16, mine_nonzero: u16, other_nonzero: u16 };

fn compareKey(mine: *const [16]u8, other: []const u8) KeyCompare {
    var r: KeyCompare = .{ .equal = 0, .mine_nonzero = 0, .other_nonzero = 0 };
    for (mine, 0..) |b, i| {
        if (i >= other.len) break;
        const bit = @as(u16, 1) << @intCast(i);
        if (b == other[i]) r.equal |= bit;
        if (b != 0) r.mine_nonzero |= bit;
        if (other[i] != 0) r.other_nonzero |= bit;
    }
    return r;
}

/// 成对钥匙的低 128 位：CCMP-128 的 TK 就是它，交给驱动装进 MAC 的也是这 16 字节。
pub fn tkCompare(other: []const u8) KeyCompare {
    return compareKey(&supplicant.ptksa.tk, other);
}

/// 组钥匙的低 128 位（GTK）。
pub fn gtkCompare(other: []const u8) KeyCompare {
    return compareKey(&supplicant.gtksa.gtk, other);
}

// ---- 关联之前：`wpa_sta_connect` ------------------------------------------------------

/// 本 STA 放进关联请求的 RSNE，照 IDF 的 `wpa_gen_wpa_ie_rsn`（`rsn_supp/wpa_ie.c:123`）。
///
/// AP 没有通告「RSNE 完成位」（`esp_wifi_sta_is_ap_notify_completed_rsne_internal()` 为假）而 AKM 又不是
/// 802.1X 时，IDF 只放版本号与组密码套件（8 字节），其余字段省略。否则放全：组密码套件、1 个成对套件、
/// 1 个 AKM、RSN 能力（只有管理帧保护的两位）、PMKSA 缓存里的 PMKID（本项目不做缓存，省略）、
/// 管理帧保护启用时的「0 个 PMKID」与 group management cipher suite。
fn buildStaRsne(chosen: wc.rsne.Selection, own: wc.rsne.OwnPolicy, ap_notify_completed: bool, out: []u8) wc.rsne.Error!usize {
    var ie = wc.rsne.Rsne{ .group = chosen.group };
    if (!ap_notify_completed) return wc.rsne.encode(ie, out);
    ie.pairwise[0] = chosen.pairwise;
    ie.pairwise_len = 1;
    ie.akm[0] = chosen.akm;
    ie.akm_len = 1;
    ie.caps = (if (own.mfpc) wc.rsne.caps_mfpc else 0) | (if (own.mfpr) wc.rsne.caps_mfpr else 0);
    ie.caps_present = true;
    if (own.mfpc or own.mfpr) {
        ie.pmkid_present = true;
        ie.gmcs_present = true;
    }
    return wc.rsne.encode(ie, out);
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// 口令 → PMK（IDF `wpa_set_passphrase`，`rsn_supp/wpa.c`）：64 个十六进制字符的 PSK 直接解码成 32 字节；
/// 8–63 个可打印字符的口令走 PBKDF2-HMAC-SHA1（SSID 作盐，4096 轮）。其余长度返回空。
fn derivePmk(password: []const u8, ssid: []const u8) ?[wc.wpa2.pmk_len]u8 {
    if (password.len == wc.wpa2.pmk_len * 2) {
        var pmk: [wc.wpa2.pmk_len]u8 = undefined;
        for (&pmk, 0..) |*b, i| {
            const hi = hexNibble(password[2 * i]) orelse return null;
            const lo = hexNibble(password[2 * i + 1]) orelse return null;
            b.* = hi << 4 | lo;
        }
        return pmk;
    }
    return wc.wpa2.derivePmk(password, ssid) catch null;
}

fn readPmfConfig() PmfConfig {
    var cfg: StaConfig = std.mem.zeroes(StaConfig);
    if (drv.get_config(wifi_if_sta, &cfg) != 0) return .{};
    return cfg.pmf_cfg;
}

/// 表的字段 8（IDF `wpa_sta_connect`，`esp_wpa_main.c:243`）。驱动选好 BSS、发关联请求之前调它。
/// 返回 0 驱动才继续关联。
///
/// 顺序照 IDF：`wpa_config_profile()` 定协议；`wpa_config_bss()` 取本 STA 的地址、SSID、口令与 AP 的 RSNE
/// （来自驱动的扫描缓存），选 AKM 与密码套件、算 PMK、生成 RSNE 并交给驱动；最后
/// `esp_wifi_sta_connect_internal(bssid)` 告诉驱动可以往下走。
///
/// IDF 另有两件事这里不做：把 PMK 存进驱动的 AP 信息（给 NVS 里的 PMK 缓存用，重启后免算）与
/// `esp_set_assoc_ie()`（RSNXE、MDE 这些，对照镜像的 RRM / 11R 关；纯 PSK 下 RSNXE 是空的）。
fn staConnect(bssid: [*]u8) callconv(.c) c_int {
    if (!attached) return -1;
    resetConnectState();
    const aa: [6]u8 = bssid[0..6].*;
    if (!drv.sta_prof_is_rsn()) {
        logLine("connect refused: profile is not RSN (WPA2 / WPA3)", .{});
        return -1;
    }

    const s = drv.sta_prof_ssid();
    const ssid_len: usize = @min(@as(usize, @intCast(@max(s.len, 0))), s.ssid.len);
    const ssid = s.ssid[0..ssid_len];
    const password = std.mem.span(drv.sta_prof_password());
    const pmk = derivePmk(password, ssid) orelse {
        logLine("connect refused: password length {d} / ssid length {d} is not a PSK", .{ password.len, ssid.len });
        return -1;
    };

    var own_mac: [6]u8 = @splat(0);
    _ = drv.get_macaddr(0, &own_mac);
    const ap_ie = drv.sta_get_ie(bssid, eid_ie_rsn) orelse {
        logLine("connect refused: no RSN IE in the scan cache for this BSS", .{});
        return -1;
    };
    const ap_ie_len: usize = 2 + @as(usize, ap_ie[1]);
    if (ap_ie[0] != eid_ie_rsn or ap_ie_len > ap_rsne_buf.len) {
        logLine("connect refused: malformed RSN IE (id {d}, len {d})", .{ ap_ie[0], ap_ie_len });
        return -1;
    }
    const ap_rsne = ap_rsne_buf[0..ap_ie_len];
    @memcpy(ap_rsne, ap_ie[0..ap_ie_len]);

    const pmf = readPmfConfig();
    const ap = wc.rsne.parse(ap_rsne) catch |e| {
        logLine("connect refused: AP RSNE: {s}", .{@errorName(e)});
        return -1;
    };
    const own = wc.rsne.OwnPolicy{ .mfpc = pmf.capable, .mfpr = pmf.required };
    const chosen = wc.rsne.select(ap, own) catch |e| {
        logLine("connect refused: {s}", .{@errorName(e)});
        return -1;
    };
    if (chosen.akm != wc.rsne.Akm.psk) {
        logLine("connect refused: selected AKM {d} is not PSK", .{chosen.akm});
        return -1;
    }
    const pairwise = wc.akm.cipherOf(chosen.pairwise) orelse {
        logLine("connect refused: pairwise cipher suite {d}", .{chosen.pairwise});
        return -1;
    };
    const group = wc.akm.cipherOf(chosen.group) orelse {
        logLine("connect refused: group cipher suite {d}", .{chosen.group});
        return -1;
    };

    @memset(&assoc_ie_buf, 0);
    const n = buildStaRsne(chosen, own, drv.ap_notify_completed_rsne(), assoc_ie_buf[2..]) catch |e| {
        logLine("connect refused: cannot build the STA RSNE: {s}", .{@errorName(e)});
        return -1;
    };

    supplicant = .{ .cfg = .{
        .spa = own_mac,
        .aa = aa,
        .akm = chosen.akm,
        .pairwise = pairwise,
        .group = group,
        .mfp = chosen.mfp_negotiated,
        .ap_rsne = ap_rsne,
        .sta_rsne = assoc_ie_buf[2..][0..n],
    } };
    supplicant.startPmk(&pmk, null) catch |e| {
        logLine("connect refused: supplicant rejected the PMK: {s}", .{@errorName(e)});
        return -1;
    };
    supplicant.step(); // INITIALIZE → AUTHENTICATION：等关联完成

    // 本 STA 的 RSNE 交给驱动。IDF `set_assoc_ie`：flag = 1，长度是整个缓冲的（126）。
    const appie_rc = drv.set_appie(appie_rsn, &assoc_ie_buf, @intCast(assoc_ie_len - 2), 1);
    logLine("connect: pairwise={d} group={d} akm={d} mfp={} sta_rsne={d} B appie rc={d}", .{
        chosen.pairwise, chosen.group, chosen.akm, chosen.mfp_negotiated, n, appie_rc,
    });
    if (appie_rc != 0) return -1;
    return drv.sta_connect(bssid);
}

/// 表的字段 12：`wpa_sta_connected_cb`，关联成功时驱动调它（`cnx_auth_done`）。IDF 的
/// `supplicant_sta_conn_handler` 在对照镜像的配置下是空的（11k/v、11R 关）。这里做的是 802.11 的
/// AuthenticationRequest（12.7.10.2）：AUTHENTICATION → STAKEYSTART，端口使能，等 AP 的消息 1。
fn staConnected(bssid: [*]u8) callconv(.c) void {
    if (!attached) return;
    if (std.mem.eql(u8, &supplicant.cfg.aa, bssid[0..6])) {
        if (!supplicant.associate()) logLine("assoc notified but the supplicant is in {s}", .{supplicant.state.name()});
    } else {
        logLine("assoc notified for a BSS we did not prepare", .{});
    }
}

// ---- 四次握手：`wpa_sta_rx_eapol` 与「发送完成」 ---------------------------------------

/// 表的字段 20（IDF 的 `wpa_sm_rx_eapol`，`rsn_supp/wpa.c:2105`）。`buf` 是一帧完整的 EAPOL-Key（含 EAPOL 头），
/// `len` 是它的长度。返回值照 IDF 的约定，**不是发送结果**：处理了返回 1；帧不成形（解不开）返回 0；
/// 其余丢弃（校验不过、重放、钥匙装不进驱动）返回 -1。回应发没发出去不改变返回值——IDF 的
/// `wpa_send_eapol` 不回传发送结果，发送失败由驱动的握手超时管。
///
/// 驱动在这个调用点只拿返回码选一条日志（`.wifiextrairam.49` 的反汇编：调完表里偏移 20 的这一项，
/// `bnez a0` 打 `wpa_psk handle succeed`，否则打 `wpa_psk handle fail`，之后一律按「帧已处理」返回）。
/// 2026-11-26 之前这里返回的是发送结果（成功为 0），板上每一帧处理成功的握手日志都是 `handle fail`。
fn staRxEapol(src: [*]u8, buf: [*]u8, len: u32) callconv(.c) c_int {
    if (!attached) return -1;
    if (len == 0 or len > eapol_tx_buf.len - 14) {
        logLine("eapol rx dropped: length {d}", .{len});
        return 0;
    }
    if (supplicant.state == .authentication) {
        // 驱动没经 `wpa_sta_connected_cb` 就把 EAPOL 递过来了。AP 只给已关联的 STA 发消息 1，照样算关联成功。
        logLine("eapol rx before the assoc notify; associating", .{});
        _ = supplicant.associate();
    }
    var snonce: [32]u8 = undefined;
    fill_random(&snonce);
    const n = supplicant.recvEapol(buf[0..len], snonce, eapol_tx_buf[14..]) catch |e| {
        logLine("eapol rx rejected ({d} B): {s}", .{ len, @errorName(e) });
        // 解不开的帧（短、长度对不上）IDF 也当「不是给本机的 Key 帧」静默丢弃：0。校验不过才是 -1。
        return if (e == error.BadFrame) 0 else -1;
    };
    if (n == 0) {
        logLine("eapol rx ok ({d} B), nothing to send", .{len});
        return 1;
    }
    // 收到的那一帧：Key Info 的 key type 位（成对）与 install 位同时置位的是消息 3；STAKEYSTART 里
    // 其余要回应的就是组密钥握手的消息 1（消息 3 处理完之后 phase 也已是 ptk_done，所以先认消息 3）。
    const msg3 = len >= 7 and std.mem.readInt(u16, buf[5..7], .big) & 0x0048 == 0x0048;
    const group = !msg3 and supplicant.phase == .ptk_done;
    // 组密钥握手（消息 1 → 消息 2）：先装 GTK、IGTK 再回消息 2（IDF `wpa_supplicant_process_1_of_2`：
    // "install gtk before send 2 of 2"）。装不进去就不回——回了等于确认一把自己手里没有的钥匙。
    const already_done = negotiation_done;
    var group_rc: c_int = 0;
    if (group) {
        group_rc = installGroupKeys();
        negotiation_done = supplicant.gtksa.valid;
        if (group_rc != 0) {
            logLine("eapol rx group msg 1 ({d} B): GTK install rc={d}, msg 2 not sent", .{ len, group_rc });
            return -1;
        }
    }
    @memcpy(eapol_tx_buf[0..6], src[0..6]);
    @memcpy(eapol_tx_buf[6..12], &supplicant.cfg.spa);
    std.mem.writeInt(u16, eapol_tx_buf[12..14], eapol_ethertype, .big);
    const rc = drv.internal_tx(wifi_if_sta, &eapol_tx_buf, @intCast(14 + n));
    if (msg3) {
        // 回的是消息 4：钥匙等「发送完成」再装（见 `eapolTxDone`）。
        msg4_in_flight = true;
        logLine("eapol rx msg 3 ({d} B) -> tx msg 4 ({d} B) rc={d}", .{ len, n, rc });
    } else if (group) {
        logLine("eapol rx group msg 1 ({d} B) -> tx group msg 2 ({d} B) rc={d}", .{ len, n, rc });
        // 首次组密钥握手（消息 3 没带 GTK）：回完消息 2 就是协商完成。之后再来的是换钥匙，不重复报。
        if (rc == 0 and !already_done) keyNegComplete();
    } else {
        logLine("eapol rx msg 1 ({d} B) -> tx msg 2 ({d} B) rc={d}", .{ len, n, rc });
    }
    return 1; // 处理了。`rc` 只进上面的日志
}
/// `eapol_txcb`（`rsn_supp/wpa.c:3027`）。IDF 在这里只认「消息 4 发送完成」这一件事：把 PTK、GTK 装进驱动，
/// 状态进 COMPLETED。本镜像用 `msg4_in_flight` 认消息 4（IDF 看的是 Key Data 长度为 0 或 secure 位，
/// 再由 `txcb_flags` 兜底）。发送失败时 IDF 什么都不做——等驱动的握手超时。
fn eapolTxDone(payload: [*]u8, len: usize, tx_failure: bool) callconv(.c) void {
    _ = payload;
    _ = len;
    if (!attached or !msg4_in_flight) return;
    if (tx_failure) {
        logLine("msg 4 tx failed", .{});
        return;
    }
    msg4_in_flight = false;
    finishHandshake();
}

fn algOf(c: wc.ccmp.Cipher) c_int {
    return switch (c) {
        .ccmp128, .ccmp256 => alg_ccmp,
        .gcmp128, .gcmp256 => alg_gcmp,
    };
}

/// 把 PTKSA / GTKSA 里「低 128 位 ‖ 多出来的那一段」拼成驱动的 key 参数（16 或 32 字节）。
fn joinedKey(lo: *const [16]u8, hi: []const u8, key_len: usize, out: *[32]u8) []const u8 {
    @memcpy(out[0..lo.len], lo);
    @memcpy(out[lo.len..key_len], hi[0 .. key_len - lo.len]);
    return out[0..key_len];
}

/// IDF `wpa_supplicant_install_ptk(sm, KEY_FLAG_TX | KEY_FLAG_RX)`：成对钥匙，Key ID 0，发收都开。
/// RSN 的序列号字段是 8 个 0（`wpa_supplicant_get_rsc`：PTK 不用 Key RSC）。
fn installPtk() c_int {
    const sa = &supplicant.ptksa;
    const rsc: [8]u8 = @splat(0);
    var key: [32]u8 = undefined;
    const k = joinedKey(&sa.tk, &sa.tk_hi, sa.cipher.keyLen(), &key);
    return drv.set_sta_key(
        algOf(sa.cipher),
        &supplicant.cfg.aa,
        0,
        1,
        &rsc,
        rsc.len,
        k.ptr,
        sa.cipher.keyLen(),
        key_flag_pairwise | key_flag_tx | key_flag_rx,
    );
}

/// IDF `wpa_supplicant_install_gtk`：组钥匙，只收不发。序列号字段是这一帧的 Key RSC（6 字节，PN0 在前）。
fn installGtk() c_int {
    const sa = &supplicant.gtksa;
    var key: [32]u8 = undefined;
    var rsc: [8]u8 = @splat(0);
    std.mem.writeInt(u64, &rsc, sa.rsc, .little);
    const k = joinedKey(&sa.gtk, &sa.gtk_hi, sa.cipher.keyLen(), &key);
    return drv.set_sta_key(
        algOf(sa.cipher),
        &supplicant.cfg.aa,
        @intCast(sa.key_id),
        @intFromBool(sa.tx),
        &rsc,
        6,
        k.ptr,
        sa.cipher.keyLen(),
        key_flag_group | key_flag_rx,
    );
}

/// IDF `wpa_supplicant_install_igtk`（管理帧保护协商成功时才有）：Key ID、IPN 与 IGTK 交给驱动。
fn installIgtk() c_int {
    const sa = &supplicant.igktsa;
    var ig: Igtk = .{};
    std.mem.writeInt(u16, &ig.keyid, sa.key_id, .little);
    ig.pn = wc.bip.ipnToBytes(sa.replay.replay);
    const len = sa.cipher.keyLen();
    var key: [32]u8 = undefined;
    @memcpy(ig.igtk[0..len], joinedKey(&sa.igtk, &sa.igtk_hi, len, &key));
    return drv.set_igtk(0, &ig);
}

/// 组钥匙：GTK、IGTK。四次握手随消息 3 收下的、组密钥握手换下来的，都从这里装进驱动。已经在驱动的
/// 那一把不重装。返回驱动的返回码里第一个非 0 的。
fn installGroupKeys() c_int {
    var rc: c_int = 0;
    const g = &supplicant.gtksa;
    if (g.valid and !(gtk_installed.valid and gtk_installed.key_id == g.key_id and gtk_installed.rsc == g.rsc)) {
        rc = installGtk();
        gtk_installed = .{ .valid = true, .key_id = g.key_id, .rsc = g.rsc };
    }
    const i = &supplicant.igktsa;
    if (i.valid and !(igtk_installed.valid and igtk_installed.key_id == i.key_id and igtk_installed.ipn == i.replay.replay)) {
        const r = installIgtk();
        if (rc == 0) rc = r;
        igtk_installed = .{ .valid = true, .key_id = i.key_id, .ipn = i.replay.replay };
    }
    return rc;
}

/// 消息 4 发送完成（IDF `wpa_supplicant_send_4_of_4_txcallback` 的顺序）：装 PTK；消息 3 里带了 GTK
/// （WPA2 的常态）就一并装上，握手到此完成。哪一步装不进去就停在那一步（IDF 的 `goto failed`）。
fn finishHandshake() void {
    const ptk_rc = installPtk();
    if (ptk_rc != 0) {
        logLine("ptk install after msg 4 rc={d}: GTK not installed, negotiation not reported", .{ptk_rc});
        return;
    }
    if (!supplicant.gtksa.valid) {
        // 消息 3 没带 GTK：协商要等组密钥握手完成（`staRxEapol`）再报。
        logLine("ptk installed after msg 4; msg 3 carried no GTK, waiting for the group handshake (port {}valid)", .{supplicant.port_valid});
        return;
    }
    const group_rc = installGroupKeys();
    negotiation_done = group_rc == 0;
    logLine("keys installed after msg 4: ptk rc={d}, group keys rc={d}, port {}valid", .{
        ptk_rc, group_rc, supplicant.port_valid,
    });
    if (negotiation_done) keyNegComplete();
}
/// IDF `wpa_supplicant_key_neg_complete` → `wpa_neg_complete()`：钥匙协商完成。
/// 把 PTK、GTK 装进驱动都不等于告诉驱动「握手完成」——那一件事只在这里做
/// （`esp_wifi_auth_done_internal` → blob 的 `cnx_auth_done`）。2026-11-26 上板实测少了它的下场：
/// 请求方 `negotiation_done=true ptk=true gtk=true`，驱动照样在 10 s 后 `handshake timeout`，
/// 以 204（4WAY_HANDSHAKE_TIMEOUT）去关联。IDF 那个函数里其余三件事在它的移植里都是空的
/// （`wpa_sm_cancel_auth_timeout`、`wpa_sm_mlme_setprotection`、`eapol_sm_notify_eap_success`）。
fn keyNegComplete() void {
    const ok = drv.auth_done();
    logLine("key negotiation complete: esp_wifi_auth_done_internal -> {}", .{ok});
}
/// 表的字段 24（IDF `wpa_sta_in_4way_handshake`）：收到消息 1 之后、握手完成之前为真。
fn in4wayHandshake() callconv(.c) bool {
    if (!attached) return false;
    return supplicant.phase == .ptk_started or (supplicant.phase == .ptk_done and !negotiation_done);
}

// ---- 配置：`wpa_config_parse_string` 与三个空的收尾 ---------------------------------------

/// 结果放在静态缓冲里轮换。IDF 是 `os_malloc`、调用方随即 `free`；本运行时的 `free` 是不做事的计数桩
/// （`link_stubs.zig`），所以静态缓冲与 IDF 的堆缓冲在这里等价。驱动一次只用一个结果。
var parse_string_pool: [4][64]u8 = undefined;
var parse_string_next: usize = 0;

/// hostap 的 `printf_decode`（`utils/common.c:194`）：解 `\` 转义（`\\` `\"` `\n` `\r` `\t` `\e` `\xHH`、
/// 最多三位八进制）。返回解出来的字节数。
fn printfDecode(buf: []u8, str: []const u8) usize {
    var i: usize = 0;
    var len: usize = 0;
    while (i < str.len) {
        if (len + 1 >= buf.len) break;
        const c = str[i];
        if (c != '\\') {
            buf[len] = c;
            len += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= str.len) break;
        const simple: ?u8 = switch (str[i]) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'e' => 0x1b,
            else => null,
        };
        if (simple) |v| {
            buf[len] = v;
            len += 1;
            i += 1;
        } else if (str[i] == 'x') {
            i += 1;
            // 两个十六进制字符取一个字节；只有一个也收；一个都不是就跳过 `\x`（C 的 `break`）。
            const hi: ?u8 = if (i < str.len) hexNibble(str[i]) else null;
            const lo: ?u8 = if (i + 1 < str.len) hexNibble(str[i + 1]) else null;
            if (hi != null and lo != null) {
                buf[len] = hi.? << 4 | lo.?;
                len += 1;
                i += 2;
            } else if (hi) |v| {
                buf[len] = v;
                len += 1;
                i += 1;
            }
        } else if (str[i] >= '0' and str[i] <= '7') {
            var val: u8 = str[i] - '0';
            i += 1;
            for (0..2) |_| {
                if (i < str.len and str[i] >= '0' and str[i] <= '7') {
                    val = val *% 8 +% (str[i] - '0');
                    i += 1;
                }
            }
            buf[len] = val;
            len += 1;
        }
    }
    return len;
}

/// 表的字段 56（`utils/common.c:310`，ESP 这一支）：带引号的字符串去掉引号；`P"…"` 再解转义；
/// 不带引号的 5 或 13 个字符（WEP 钥匙）原样返回；其余按十六进制解（64 个字符的 PSK 解成 32 字节 PMK，
/// 奇数个字符时最后一个不要）。解不出来的返回空。普通口令（8–63 个字符）在这里**返回空**——IDF 也一样，
/// 驱动在非 SAE-PK 的路径上只拿它判空，PMK 另算（见 `derivePmk`）。
fn parseConfigString(value: [*:0]const u8, len: *usize) callconv(.c) ?[*:0]u8 {
    const s = std.mem.span(value);
    const dst = &parse_string_pool[parse_string_next];
    parse_string_next = (parse_string_next + 1) % parse_string_pool.len;
    var n: usize = 0;
    if (s.len >= 1 and s[0] == '"') {
        const body = s[1..];
        if (body.len == 0 or body[body.len - 1] != '"' or body.len - 1 >= dst.len) return null;
        n = body.len - 1;
        @memcpy(dst[0..n], body[0..n]);
    } else if (s.len >= 2 and s[0] == 'P' and s[1] == '"') {
        const body = s[2..];
        if (body.len == 0 or body[body.len - 1] != '"' or body.len >= dst.len) return null;
        n = printfDecode(dst, body[0 .. body.len - 1]);
    } else if (s.len == 5 or s.len == 13) {
        n = s.len;
        @memcpy(dst[0..n], s);
    } else {
        n = s.len / 2;
        if (n + 1 > dst.len) return null;
        for (0..n) |i| {
            const hi = hexNibble(s[2 * i]) orelse return null;
            const lo = hexNibble(s[2 * i + 1]) orelse return null;
            dst[i] = hi << 4 | lo;
        }
    }
    dst[n] = 0;
    len.* = n;
    return @ptrCast(&dst[0]);
}

/// 表的字段 88（IDF `wpa_config_done`）：只有一句 `esp_set_scan_ie()`，对照镜像的 `WNM` / `MBO` 关，是空函数。
fn configDone() callconv(.c) void {}

/// 表的字段 100（IDF `wpa_sta_clear_curr_pmksa`）：清 PMKSA 缓存里的「当前」项。本项目不做 PMKSA 缓存。
fn clearCurrPmksa() callconv(.c) void {}

/// 表的字段 104（IDF `wpa_config_reload`）：`wpa_sm_pmksa_cache_flush()`。本项目不做 PMKSA 缓存。
fn configReload() callconv(.c) void {}

// ---- 给应用（探针）用的三个入口 --------------------------------------------------------

/// `esp_wifi_set_config(WIFI_IF_STA, cfg)`。返回驱动的返回码（0 = 成功）。
pub fn setStaConfig(cfg: *const StaConfig) c_int {
    return drv.set_config(wifi_if_sta, cfg);
}

/// IDF 的 `esp_wifi_connect()`：只是 `esp_wifi_connect_internal()` 加一个（关着的）漫游钩子。
pub fn connect() c_int {
    return drv.connect();
}

/// IDF 的 `esp_wifi_disconnect()`。
pub fn disconnect() c_int {
    return drv.disconnect();
}

// ---------------------------------------------------------------------------
// 主机侧用例：按 blob 的调法（元素指针、`Length + 2`、输出结构）走回调
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sel(comptime oui: u32, comptime t: u8) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, oui | @as(u32, t), .big);
    return b;
}

/// 小端的 2 字节计数 / 版本 / 能力字段。
fn num(comptime n: u16) [2]u8 {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, n, .little);
    return b;
}

/// 大端的 4 字节厂商类型。
fn vendor(comptime t: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, t, .big);
    return b;
}

/// 加上 Element ID 与 Length。
fn elem(comptime id: u8, comptime body: []const u8) [2 + body.len]u8 {
    var out: [2 + body.len]u8 = undefined;
    out[0] = id;
    out[1] = body.len;
    @memcpy(out[2..], body);
    return out;
}

const Parsed = struct { rc: c_int, d: WpaIe };

/// 调回调。输出结构先填满哨兵值：回调必须在任何返回码下把每个字段都写一遍。
fn parse(ie: []const u8) Parsed {
    var d: WpaIe = .{
        .proto = -559038737,
        .pairwise_cipher = -559038737,
        .group_cipher = -559038737,
        .key_mgmt = -559038737,
        .capabilities = -559038737,
        .num_pmkid = 0xDEADBEEF,
        .pmkid = null,
        .mgmt_group_cipher = -559038737,
        .rsnxe_capa = 0xAA,
    };
    // blob 调的时候传的是 `Length + 2`。长度 0 的元素没有 Length 字节，传 0。
    const len = if (ie.len >= 2) @as(usize, ie[1]) + 2 else 0;
    const rc = parseWpaIe(ie.ptr, len, &d);
    return .{ .rc = rc, .d = d };
}

test "wpa_cb: 回调表的字段顺序与 blob 读的偏移一致" {
    // 上文「布局的证据」里 blob 实际读到的偏移是 ilp32 的字节数；换一种指针宽度就按比例换算。
    const read_by_blob = [_]struct { field: []const u8, at: usize }{
        .{ .field = "wpa_sta_disconnected_cb", .at = 16 },
        .{ .field = "wpa_ap_get_wpa_ie", .at = 44 },
        .{ .field = "wpa_config_parse_string", .at = 56 },
        .{ .field = "wpa_parse_wpa_ie", .at = 60 },
        .{ .field = "wpa3_build_sae_msg", .at = 72 },
        .{ .field = "wpa3_parse_sae_msg", .at = 76 },
        .{ .field = "wpa_sta_rx_mgmt", .at = 84 },
        .{ .field = "owe_build_dhie", .at = 92 },
        .{ .field = "owe_process_assoc_resp", .at = 96 },
        .{ .field = "wpa_sta_clear_curr_pmksa", .at = 100 },
        .{ .field = "wpa_config_reload", .at = 104 },
    };
    const scale = @sizeOf(usize) / 4;
    inline for (read_by_blob) |f| try testing.expectEqual(f.at * scale, @offsetOf(Funcs, f.field));

    // blob 调完 `wpa_parse_wpa_ie` 读的是 0 / 4 / 8 / 12 四个字（与指针宽度无关）。后面几个字段
    // 的偏移依赖字长，ilp32（板子）上的值由文件里的 comptime 断言把关。
    try testing.expectEqual(@as(usize, 0), @offsetOf(WpaIe, "proto"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(WpaIe, "pairwise_cipher"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WpaIe, "group_cipher"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(WpaIe, "key_mgmt"));
}

test "wpa_cb: RSN PSK + CCMP → 公共 CCMP，key_mgmt 只有 PSK，管理帧密码套件取默认值" {
    // Version | group CCMP | 1 × CCMP | 1 × PSK | RSN Capabilities
    const ie = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++ num(1) ++ sel(oui_rsn, 4) ++
        num(1) ++ sel(oui_rsn, 2) ++ num(0x000C)));
    const r = parse(&ie);
    try testing.expectEqual(@as(c_int, 0), r.rc);
    try testing.expectEqual(@as(c_int, @bitCast(proto_rsn)), r.d.proto);
    try testing.expectEqual(public_cipher.ccmp, r.d.pairwise_cipher);
    try testing.expectEqual(public_cipher.ccmp, r.d.group_cipher);
    try testing.expectEqual(@as(c_int, @bitCast(key_mgmt.psk)), r.d.key_mgmt);
    try testing.expectEqual(@as(c_int, 0x000C), r.d.capabilities);
    try testing.expectEqual(@as(usize, 0), r.d.num_pmkid);
    // 字段缺席 → C 版的默认值 BIP-CMAC-128
    try testing.expectEqual(public_cipher.aes_cmac128, r.d.mgmt_group_cipher);
    try testing.expectEqual(@as(u8, 0), r.d.rsnxe_capa);
}

test "wpa_cb: WPA2/WPA3 混合 AP（PSK + SAE、CCMP + TKIP、GMAC-128、一个 PMKID、末尾多出字节）" {
    const pmkid = [16]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01 };
    const ie = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++
        num(2) ++ sel(oui_rsn, 4) ++ sel(oui_rsn, 2) ++ // 成对：CCMP、TKIP
        num(2) ++ sel(oui_rsn, 2) ++ sel(oui_rsn, 8) ++ // AKM：PSK、SAE
        num(0x0080) ++ num(1) ++ pmkid ++ sel(oui_rsn, 11) ++ // MFPC、PMKID、BIP-GMAC-128
        [_]u8{ 0xde, 0xad, 0xbe, 0xef })); // 末尾多出 4 字节：忽略
    const r = parse(&ie);
    try testing.expectEqual(@as(c_int, 0), r.rc);
    try testing.expectEqual(public_cipher.tkip_ccmp, r.d.pairwise_cipher);
    try testing.expectEqual(@as(c_int, @bitCast(key_mgmt.psk | key_mgmt.sae)), r.d.key_mgmt);
    try testing.expectEqual(@as(c_int, 0x0080), r.d.capabilities);
    try testing.expectEqual(@as(usize, 1), r.d.num_pmkid);
    try testing.expectEqualSlices(u8, r.d.pmkid.?[0..pmkid_len], &pmkid);
    try testing.expectEqual(public_cipher.aes_gmac128, r.d.mgmt_group_cipher);
}

test "wpa_cb: 纯 WPA3 AP（只有 SAE）——GCMP 按对照镜像的开关不计位，成对只剩 CCMP" {
    const ie = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++
        num(2) ++ sel(oui_rsn, 4) ++ sel(oui_rsn, 8) ++ // 成对：CCMP、GCMP-128
        num(1) ++ sel(oui_rsn, 8) ++ num(0x00C0))); // MFPC + MFPR
    const r = parse(&ie);
    try testing.expectEqual(@as(c_int, 0), r.rc);
    try testing.expectEqual(@as(c_int, @bitCast(key_mgmt.sae)), r.d.key_mgmt);
    try testing.expectEqual(public_cipher.ccmp, r.d.pairwise_cipher);
    try testing.expectEqual(@as(c_int, 0x00C0), r.d.capabilities);
}

test "wpa_cb: 内部位到公共密码套件按整个位掩码映射，组合对不上就是 UNKNOWN" {
    try testing.expectEqual(public_cipher.tkip_ccmp, toPublicCipher(cipher.ccmp | cipher.tkip));
    try testing.expectEqual(public_cipher.unknown, toPublicCipher(cipher.wep40 | cipher.wep104));
    try testing.expectEqual(public_cipher.unknown, toPublicCipher(0));
    try testing.expectEqual(public_cipher.gcmp, toPublicCipher(cipher.gcmp));
}

test "wpa_cb: WPA v1 TKIP + PSK → proto=WPA，没有管理帧密码套件（UNKNOWN）" {
    // Element ID 221 | OUI 00-50-F2:01 | Version | group TKIP | 1 × TKIP | 1 × PSK | Capabilities
    const ie = elem(eid_vendor_specific, &(vendor(oui_wpa | 1) ++ num(1) ++ sel(oui_wpa, 2) ++
        num(1) ++ sel(oui_wpa, 2) ++ num(1) ++ sel(oui_wpa, 2) ++ num(0x0001)));
    const r = parse(&ie);
    try testing.expectEqual(@as(c_int, 0), r.rc);
    try testing.expectEqual(@as(c_int, @bitCast(proto_wpa)), r.d.proto);
    try testing.expectEqual(public_cipher.tkip, r.d.pairwise_cipher);
    try testing.expectEqual(public_cipher.tkip, r.d.group_cipher);
    try testing.expectEqual(@as(c_int, @bitCast(key_mgmt.psk)), r.d.key_mgmt);
    try testing.expectEqual(@as(c_int, 1), r.d.capabilities);
    try testing.expectEqual(public_cipher.unknown, r.d.mgmt_group_cipher);
}

test "wpa_cb: 残缺的元素按 C 版的返回码报错，已填的字段照样交给 blob" {
    // 版本号不是 1：-2，其余字段保持 C 版的默认值（成对 / 组 CCMP、AKM 802.1X）。
    const bad_version = elem(eid_rsn, &(num(2) ++ sel(oui_rsn, 4)));
    var r = parse(&bad_version);
    try testing.expectEqual(@as(c_int, -2), r.rc);
    try testing.expectEqual(public_cipher.ccmp, r.d.pairwise_cipher);
    try testing.expectEqual(@as(c_int, @bitCast(key_mgmt.ieee8021x)), r.d.key_mgmt);

    // 成对套件计数是 3，后面只有 2 个选择器：-4；组套件已读出 TKIP，成对被清成 0（→ UNKNOWN）。
    const count_botch = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 2) ++ num(3) ++ sel(oui_rsn, 4) ++ sel(oui_rsn, 4)));
    r = parse(&count_botch);
    try testing.expectEqual(@as(c_int, -4), r.rc);
    try testing.expectEqual(public_cipher.tkip, r.d.group_cipher);
    try testing.expectEqual(public_cipher.unknown, r.d.pairwise_cipher);

    // 版本号后面只剩 1 个字节（组套件装不下）：-3。
    const straggle = elem(eid_rsn, &(num(1) ++ [_]u8{0x01}));
    r = parse(&straggle);
    try testing.expectEqual(@as(c_int, -3), r.rc);

    // 组套件读完后只剩 1 个字节（成对套件计数装不下）：-5。
    const straggle2 = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++ [_]u8{0x01}));
    r = parse(&straggle2);
    try testing.expectEqual(@as(c_int, -5), r.rc);

    // PMKID 计数是 2，后面只有 1 个 PMKID：-9。
    const pmk_botch = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++ num(1) ++ sel(oui_rsn, 4) ++
        num(1) ++ sel(oui_rsn, 2) ++ num(0) ++ num(2) ++ @as([pmkid_len]u8, @splat(0))));
    r = parse(&pmk_botch);
    try testing.expectEqual(@as(c_int, -9), r.rc);
    try testing.expectEqual(@as(usize, 0), r.d.num_pmkid);

    // 管理帧密码套件是 BIP-CMAC-256（没有位 → 0，不在有效集合里）：-10。
    const bad_mgmt = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++ num(1) ++ sel(oui_rsn, 4) ++
        num(1) ++ sel(oui_rsn, 2) ++ num(0) ++ num(0) ++ sel(oui_rsn, 13)));
    r = parse(&bad_mgmt);
    try testing.expectEqual(@as(c_int, -10), r.rc);

    // 长度 0：分派落到 WPA v1 解析 → proto=WPA、-1，默认值照样填好。
    const empty = [_]u8{};
    r = parse(&empty);
    try testing.expectEqual(@as(c_int, -1), r.rc);
    try testing.expectEqual(@as(c_int, @bitCast(proto_wpa)), r.d.proto);
    try testing.expectEqual(public_cipher.tkip, r.d.pairwise_cipher);
}

test "wpa_cb: WAPI 元素返回 0，结果清零（内部位 0 → 公共 UNKNOWN）" {
    const ie = elem(eid_wapi, &[_]u8{ 0x01, 0x00, 0x7f });
    const r = parse(&ie);
    try testing.expectEqual(@as(c_int, 0), r.rc);
    try testing.expectEqual(@as(c_int, 0), r.d.proto);
    try testing.expectEqual(public_cipher.unknown, r.d.pairwise_cipher);
    try testing.expectEqual(@as(usize, 0), r.d.num_pmkid);
    try testing.expectEqual(@as(u8, 0), r.d.rsnxe_capa);
}

test "wpa_cb: 厂商形式的 RSNE（WPA3 兼容模式）按 RSN 解析" {
    // Element ID 221 | Vendor Type | Version | group CCMP | 1 × CCMP | 1 × SAE | Capabilities
    const ie = elem(eid_vendor_specific, &(vendor(vendor_type_rsne_override) ++ num(1) ++ sel(oui_rsn, 4) ++
        num(1) ++ sel(oui_rsn, 4) ++ num(1) ++ sel(oui_rsn, 8) ++ num(0)));
    const r = parse(&ie);
    try testing.expectEqual(@as(c_int, 0), r.rc);
    try testing.expectEqual(@as(c_int, @bitCast(proto_rsn)), r.d.proto);
    try testing.expectEqual(@as(c_int, @bitCast(key_mgmt.sae)), r.d.key_mgmt);
}

test "wpa_cb: RSNXE 只取能力字节；STA 要求 H2E 而 AP 不支持时返回 -1" {
    const stubs = @import("host_stubs.zig");
    stubs.sae_pwe_h2e = 0;
    defer stubs.sae_pwe_h2e = 0;

    // 两种形式的能力字节都是 0x20（SAE H2E，B5）。标准：Element ID | Length | capabilities
    // （没有版本字节）；厂商：Element ID | Length | Vendor Type(4) | capabilities。
    const plain = elem(eid_rsnx, &[_]u8{1 << rsnx_capab_sae_h2e});
    const wrapped = elem(eid_vendor_specific, &(vendor(vendor_type_rsnxe_override) ++ [_]u8{1 << rsnx_capab_sae_h2e}));
    for ([_][]const u8{ &plain, &wrapped }) |ie| {
        const r = parse(ie);
        try testing.expectEqual(@as(c_int, 0), r.rc);
        try testing.expectEqual(@as(u8, 1 << rsnx_capab_sae_h2e), r.d.rsnxe_capa);
        try testing.expectEqual(@as(c_int, 0), r.d.proto);
    }

    // 要求 H2E：AP 的 RSNXE 没有这一位 → -1，能力字节不上报。
    stubs.sae_pwe_h2e = 1;
    const no_h2e = elem(eid_rsnx, &[_]u8{0x01});
    const r = parse(&no_h2e);
    try testing.expectEqual(@as(c_int, -1), r.rc);
    try testing.expectEqual(@as(u8, 0), r.d.rsnxe_capa);
    const with_h2e = parse(&plain);
    try testing.expectEqual(@as(c_int, 0), with_h2e.rc);
}

test "wpa_cb: attach 给出一个没有密钥的请求方，每次 attach 都是全新实例" {
    try testing.expect(funcs.wpa_sta_deinit.?()); // 别的用例可能 attach 过
    try testing.expect(!attached);
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expect(attached);
    try testing.expectEqual(wc.supplicant.KmState.initialization, supplicant.state);
    try testing.expect(!supplicant.pmk_set);
    try testing.expect(!supplicant.port_enabled);
    try testing.expect(!supplicant.ptksa.valid);
    try testing.expect(!supplicant.gtksa.valid);

    supplicant.step(); // INITIALIZE → AUTHENTICATION
    try testing.expect(supplicant.associate()); // → STAKEYSTART，端口使能
    try testing.expect(supplicant.port_enabled);
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expectEqual(wc.supplicant.KmState.initialization, supplicant.state);
    try testing.expect(!supplicant.port_enabled);
}

test "wpa_cb: 四次握手超时的断开通知丢掉安全关联并清掉认证方地址；不在那一组原因码里的通知不动它" {
    try testing.expect(funcs.wpa_sta_init.?());
    supplicant.cfg.aa = .{ 0x02, 0x00, 0x00, 0x00, 0x20, 0x01 };
    supplicant.step();
    try testing.expect(supplicant.associate());

    funcs.wpa_sta_disconnected_cb.?(1); // UNSPECIFIED：IDF 这时只清 PMKSA 缓存，本项目没有缓存
    try testing.expectEqual(wc.supplicant.KmState.stakey_start, supplicant.state);
    try testing.expect(supplicant.port_enabled);

    funcs.wpa_sta_disconnected_cb.?(15); // 4WAY_HANDSHAKE_TIMEOUT
    try testing.expectEqual(wc.supplicant.KmState.initialization, supplicant.state);
    try testing.expect(!supplicant.port_enabled);
    try testing.expectEqual([6]u8{ 0, 0, 0, 0, 0, 0 }, supplicant.cfg.aa);
}

test "wpa_cb: detach 之后的断开通知不碰已收回的请求方" {
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expect(funcs.wpa_sta_deinit.?());
    try testing.expect(!attached);
    supplicant.state = .authentication; // 已收回实例的内容本没有定义，这里拿它当哨兵
    funcs.wpa_sta_disconnected_cb.?(15);
    try testing.expectEqual(wc.supplicant.KmState.authentication, supplicant.state);
}

// ---------------------------------------------------------------------------
// 连接路径的用例：假驱动 + 已知答案的整条握手
// ---------------------------------------------------------------------------

const driver_stubs = @import("host_stubs.zig");
const fake = driver_stubs.fake;
const vec = wc.vectors;

fn snonceFromVector(dst: *[32]u8) void {
    dst.* = vec.snonce;
}

/// 假驱动的 profile 照 Annex J.4.2 用例 1（SSID "IEEE"、口令 "password"，PMK 就是向量里的 `pmk_ieee`），
/// AP 是端到端向量里的那一个：成对 CCMP + GCMP-128、AKM PSK + SAE、通告 MFPC。`pmf` 是本 STA 通告不通告
/// 管理帧保护。
fn prepareFake(pmf: bool) void {
    fake.reset();
    fake.mac = vec.sta_mac;
    fake.ssid = "IEEE";
    fake.password = "password";
    fake.ap_rsne = &vec.e2e_ap_rsne;
    fake.pmf_capable = pmf;
    fake.notify_completed_rsne = true;
    fake.refreshProfile();
    fill_random = &snonceFromVector;
}

fn rx(ap_mac: *[6]u8, frame: []const u8) c_int {
    return funcs.wpa_sta_rx_eapol.?(ap_mac, @constCast(frame.ptr), @intCast(frame.len));
}

test "wpa_cb: WPA2-PSK 连接——关联前备好 PMK 与 RSNE，三帧回应逐字节对上已知答案，钥匙在消息 4 发送完成后才装" {
    prepareFake(true);
    var ap_mac = vec.ap_mac;
    try testing.expect(funcs.wpa_sta_init.?());
    // attach 登记了「发送完成」回调：钥匙是那时才装的。
    try testing.expect(fake.txdone_cb != null);

    // 驱动选好 BSS 后调 wpa_sta_connect：返回 0 才继续关联。
    try testing.expectEqual(@as(c_int, 0), funcs.wpa_sta_connect.?(&ap_mac));
    try testing.expectEqual(@as(u32, 1), fake.sta_connect_calls);
    try testing.expectEqual(vec.ap_mac, fake.sta_connect_bssid);
    // PMK = PBKDF2(口令, SSID)。`pmk` 是 48 字节的缓冲（AKM 12、13 用得到 48），PSK 只占前 32。
    try testing.expectEqualSlices(u8, &vec.pmk_ieee, supplicant.pmk[0..32]);
    try testing.expect(supplicant.pmk_set);
    try testing.expectEqual(wc.supplicant.KmState.authentication, supplicant.state);
    // 本 STA 的 RSNE 交给驱动：类型 RSN、flag = 1、长度是整个缓冲的 126，驱动把长度写进了缓冲的前两个字节，
    // 元素从下标 2 起，内容就是向量里的 STA RSNE（管理帧保护通告了，所以有 PMKID 计数与 group management suite）。
    try testing.expectEqual(@as(usize, 1), fake.n_app_ies);
    try testing.expectEqual(appie_rsn, fake.app_ies[0].typ);
    try testing.expectEqual(@as(u8, 1), fake.app_ies[0].flag);
    try testing.expectEqual(@as(u16, 126), fake.app_ies[0].len);
    try testing.expectEqual(@as(u16, 126), std.mem.readInt(u16, assoc_ie_buf[0..2], .little)); // 写进了请求方的缓冲
    try testing.expectEqual(@as(u16, 126), std.mem.readInt(u16, fake.app_ies[0].buf[0..2], .little));
    try testing.expectEqualSlices(u8, &vec.e2e_sta_rsne, fake.app_ies[0].buf[2..][0..vec.e2e_sta_rsne.len]);
    try testing.expectEqualSlices(u8, &vec.e2e_sta_rsne, status().sta_rsne);
    try testing.expectEqualSlices(u8, &vec.e2e_ap_rsne, status().ap_rsne);
    try testing.expect(!funcs.wpa_sta_in_4way_handshake.?());

    // 关联成功。
    funcs.wpa_sta_connected_cb.?(&ap_mac);
    try testing.expectEqual(wc.supplicant.KmState.stakey_start, supplicant.state);

    // 消息 1 → 消息 2：回应装进 Ethernet 头（dst = AP、src = 本 STA、0x888E）交给驱动发。
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_msg1)); // 1 = 处理了（IDF 的约定）
    try testing.expectEqual(@as(usize, 1), fake.n_tx);
    try testing.expectEqualSlices(u8, &vec.ap_mac, fake.tx_frames[0][0..6]);
    try testing.expectEqualSlices(u8, &vec.sta_mac, fake.tx_frames[0][6..12]);
    try testing.expectEqual(@as(u16, eapol_ethertype), std.mem.readInt(u16, fake.tx_frames[0][12..14], .big));
    try testing.expectEqualSlices(u8, &vec.e2e_msg2, fake.tx_frames[0][14..][0..vec.e2e_msg2.len]);
    try testing.expectEqual(@as(usize, 14 + vec.e2e_msg2.len), fake.tx_lens[0]);
    try testing.expectEqual(@as(usize, 0), fake.n_keys);
    try testing.expect(funcs.wpa_sta_in_4way_handshake.?());

    // 消息 3 → 消息 4：请求方已经算出 PTK、收下 GTK 与 IGTK，但驱动里一把钥匙都还没装。
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_msg3));
    try testing.expectEqualSlices(u8, &vec.e2e_msg4, fake.tx_frames[1][14..][0..vec.e2e_msg4.len]);
    try testing.expectEqual(@as(usize, 0), fake.n_keys);
    try testing.expectEqual(@as(usize, 0), fake.n_igtks);
    try testing.expect(status().msg4_in_flight);
    try testing.expect(!status().negotiation_done);
    try testing.expect(funcs.wpa_sta_in_4way_handshake.?());
    // 协商还没完成：驱动还没被告知。
    try testing.expectEqual(@as(u32, 0), fake.auth_done_calls);

    // 消息 4 发送完成：PTK（成对，发收都开，Key ID 0，RSC 全 0）。
    // 向量里 GTK 的 Key RSC 是 0，看不出字节序；装进驱动之前给请求方记的值换成一个能看出来的。
    supplicant.gtksa.rsc = 0x0102_0304_0506;
    fake.deliverTxDone(1, false);
    try testing.expectEqual(@as(usize, 2), fake.n_keys);
    const ptk = fake.keys[0];
    try testing.expectEqual(alg_ccmp, ptk.alg);
    try testing.expectEqual(vec.ap_mac, ptk.addr);
    try testing.expectEqual(@as(c_int, 0), ptk.key_idx);
    try testing.expectEqual(@as(c_int, 1), ptk.set_tx);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), &ptk.rsc);
    try testing.expectEqual(@as(usize, 8), ptk.rsc_len);
    try testing.expectEqualSlices(u8, vec.ptk48[32..48], ptk.key[0..16]);
    try testing.expectEqual(@as(usize, 16), ptk.key_len);
    try testing.expectEqual(key_flag_pairwise | key_flag_tx | key_flag_rx, ptk.flags);
    // GTK（组，只收，Key ID 1，RSC = 消息 3 的 Key RSC，6 字节）。
    const gtk = fake.keys[1];
    try testing.expectEqual(alg_ccmp, gtk.alg);
    try testing.expectEqual(@as(c_int, 1), gtk.key_idx);
    try testing.expectEqual(@as(c_int, 0), gtk.set_tx);
    // GTK 的 RSC = Key RSC 的低 6 字节，PN0 在前。
    try testing.expectEqualSlices(u8, &[_]u8{ 6, 5, 4, 3, 2, 1 }, gtk.rsc[0..6]);
    try testing.expectEqual(@as(usize, 6), gtk.rsc_len);
    try testing.expectEqualSlices(u8, &vec.e2e_gtk, gtk.key[0..16]);
    try testing.expectEqual(@as(usize, 16), gtk.key_len);
    try testing.expectEqual(key_flag_group | key_flag_rx, gtk.flags);
    // IGTK（Key ID 4）：Key ID、IPN、钥匙各就各位。
    try testing.expectEqual(@as(usize, 1), fake.n_igtks);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 0 }, fake.igtks[0][0..2]);
    try testing.expectEqualSlices(u8, &vec.e2e_igtk, fake.igtks[0][8..24]);
    try testing.expect(status().negotiation_done);
    try testing.expect(!funcs.wpa_sta_in_4way_handshake.?());
    // 装钥匙不等于告诉驱动「握手完成」——那件事单独报给驱动一次（板上少了它，驱动 10 s 后以 204 去关联）。
    try testing.expectEqual(@as(u32, 1), fake.auth_done_calls);
    try testing.expectEqual(@as(u32, 0), supplicant.rejects);

    // 组密钥握手（换钥匙）：新 GTK（Key ID 2）与新 IGTK（Key ID 5）在回应发出时立刻装，不等「发送完成」。
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_gmsg1));
    try testing.expectEqualSlices(u8, &vec.e2e_gmsg2, fake.tx_frames[2][14..][0..vec.e2e_gmsg2.len]);
    try testing.expectEqual(@as(usize, 3), fake.n_keys);
    try testing.expectEqual(@as(c_int, 2), fake.keys[2].key_idx);
    try testing.expectEqual(key_flag_group | key_flag_rx, fake.keys[2].flags);
    try testing.expectEqual(@as(usize, 2), fake.n_igtks);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 0 }, fake.igtks[1][0..2]);
    fake.deliverTxDone(2, false);
    try testing.expectEqual(@as(usize, 3), fake.n_keys); // 这一次的「发送完成」不再装钥匙
    // 换钥匙不是"协商完成"：不重复报。
    try testing.expectEqual(@as(u32, 1), fake.auth_done_calls);

    // 断开通知：钥匙与连接进度一起清掉。
    funcs.wpa_sta_disconnected_cb.?(15);
    try testing.expect(!status().negotiation_done);
    try testing.expect(!supplicant.ptksa.valid);
    try testing.expect(!funcs.wpa_sta_in_4way_handshake.?());
}

test "wpa_cb: 组密钥握手换下来的 GTK 装不进驱动——不回消息 2，也不报协商完成" {
    prepareFake(true);
    var ap_mac = vec.ap_mac;
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expectEqual(@as(c_int, 0), funcs.wpa_sta_connect.?(&ap_mac));
    funcs.wpa_sta_connected_cb.?(&ap_mac);
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_msg1));
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_msg3));
    fake.deliverTxDone(1, false);
    try testing.expectEqual(@as(u32, 1), fake.auth_done_calls);

    // 驱动拒绝装钥匙：请求方不替一把自己手里送不进去的钥匙回确认。
    fake.key_rc = -1;
    try testing.expectEqual(@as(c_int, -1), rx(&ap_mac, &vec.e2e_gmsg1));
    try testing.expectEqual(@as(usize, 2), fake.n_tx);
    try testing.expectEqual(@as(u32, 1), fake.auth_done_calls);
}

test "wpa_cb: `wpa_sta_rx_eapol` 的返回值照 IDF——处理了返回 1（回应发没发出去都一样），解不开的帧 0，校验不过、重放 -1" {
    prepareFake(true);
    var ap_mac = vec.ap_mac;
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expectEqual(@as(c_int, 0), funcs.wpa_sta_connect.?(&ap_mac));
    funcs.wpa_sta_connected_cb.?(&ap_mac);

    // 解不开的帧（短于固定首部）：不是给本机的 Key 帧，静默丢弃。
    try testing.expectEqual(@as(c_int, 0), rx(&ap_mac, vec.e2e_msg1[0..10]));
    try testing.expectEqual(@as(usize, 0), fake.n_tx);

    // 校验不过（消息 1 不该带 Request 位，12.7.2 h)）：丢弃，不回应。
    var request = vec.e2e_msg1;
    request[5] = 0x08; // Key Info 的 bit 11（Request）在高字节的 bit 3
    try testing.expectEqual(@as(c_int, -1), rx(&ap_mac, &request));
    try testing.expectEqual(@as(usize, 0), fake.n_tx);

    // 处理了：1。驱动没把回应发出去也是 1——返回值说的是「这一帧处理了」，不是「回应到了」。
    fake.tx_rc = 0x101;
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_msg1));
    fake.tx_rc = 0;
    try testing.expectEqual(@as(usize, 1), fake.n_tx);
    try testing.expectEqual(@as(c_int, 1), rx(&ap_mac, &vec.e2e_msg3));
    // 消息 3 的 MIC 证实过的重放计数：同一帧再来是重放，丢弃。
    try testing.expectEqual(@as(c_int, -1), rx(&ap_mac, &vec.e2e_msg3));
    try testing.expectEqual(@as(usize, 2), fake.n_tx);
}

test "wpa_cb: AP 没通告 RSNE 完成位时本 STA 的 RSNE 只放版本号与组密码套件；没开管理帧保护的 STA 也收下只通告 MFPC 的 AP" {
    prepareFake(false);
    fake.notify_completed_rsne = false;
    var ap_mac = vec.ap_mac;
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expectEqual(@as(c_int, 0), funcs.wpa_sta_connect.?(&ap_mac));
    try testing.expectEqualSlices(u8, &[_]u8{ 48, 6, 1, 0, 0x00, 0x0f, 0xac, 0x04 }, status().sta_rsne);
    try testing.expect(fake.app_ies[0].buf[10] == 0); // 元素之后全是 0
    try testing.expect(!supplicant.cfg.mfp);
    try testing.expectEqualSlices(u8, &vec.pmk_ieee, supplicant.pmk[0..32]);
}

test "wpa_cb: 不支持的 AP 或配置在关联之前就拒绝——SAE-only、TKIP、AP 强制管理帧保护、口令长度不对" {
    var ap_mac = vec.ap_mac;
    const sae_only = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 4) ++ num(1) ++ sel(oui_rsn, 4) ++ num(1) ++ sel(oui_rsn, 8) ++ num(0x0080)));
    const tkip_only = elem(eid_rsn, &(num(1) ++ sel(oui_rsn, 2) ++ num(1) ++ sel(oui_rsn, 2) ++ num(1) ++ sel(oui_rsn, 2) ++ num(0)));
    var strict = vec.e2e_ap_rsne;
    strict[24] |= 0x40; // RSN Capabilities 的 MFPR

    prepareFake(false);
    try testing.expect(funcs.wpa_sta_init.?());
    const cases = [_][]const u8{ &sae_only, &tkip_only, &strict };
    for (cases) |ap| {
        fake.ap_rsne = ap;
        fake.refreshProfile();
        try testing.expectEqual(@as(c_int, -1), funcs.wpa_sta_connect.?(&ap_mac));
    }
    fake.ap_rsne = null; // 扫描缓存里没有 RSN IE
    fake.refreshProfile();
    try testing.expectEqual(@as(c_int, -1), funcs.wpa_sta_connect.?(&ap_mac));

    prepareFake(true); // 本 STA 通告 MFPC 时，强制管理帧保护的 AP 是可以连的
    fake.ap_rsne = &strict;
    fake.refreshProfile();
    try testing.expectEqual(@as(c_int, 0), funcs.wpa_sta_connect.?(&ap_mac));
    try testing.expect(supplicant.cfg.mfp);

    // 口令长度不对（< 8 个字符，也不是 64 个十六进制字符）。
    prepareFake(false);
    fake.password = "short";
    fake.refreshProfile();
    try testing.expectEqual(@as(c_int, -1), funcs.wpa_sta_connect.?(&ap_mac));
    // 64 个十六进制字符的 PSK 直接当 PMK。
    fake.password = &std.fmt.bytesToHex(vec.pmk_ieee, .lower);
    fake.refreshProfile();
    try testing.expectEqual(@as(c_int, 0), funcs.wpa_sta_connect.?(&ap_mac));
    try testing.expectEqualSlices(u8, &vec.pmk_ieee, supplicant.pmk[0..32]);
    // 这一段里驱动只被叫去关联了一次：上一次 `prepareFake` 之后只有十六进制 PSK 那一回没被拒绝。
    try testing.expectEqual(@as(u32, 1), fake.sta_connect_calls);
}

test "wpa_cb: 口令字符串的四种写法（带引号、P\"…\" 转义、WEP 长度、十六进制 PSK）；普通口令返回空" {
    var len: usize = 99;
    const parse_string = funcs.wpa_config_parse_string.?;
    try testing.expectEqualSlices(u8, "hello", parse_string("\"hello\"", &len).?[0..5]);
    try testing.expectEqual(@as(usize, 5), len);
    // \x41 = 'A'、\n、\101（八进制）= 'A'、\" = '"'
    try testing.expectEqualSlices(u8, "aA\nA\"", parse_string("P\"a\\x41\\n\\101\\\"\"", &len).?[0..5]);
    try testing.expectEqual(@as(usize, 5), len);
    try testing.expectEqualSlices(u8, "12345", parse_string("12345", &len).?[0..5]);
    const hex = parse_string("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", &len).?;
    try testing.expectEqual(@as(usize, 32), len);
    try testing.expectEqualSlices(u8, &vec.anonce, hex[0..32]);
    // 普通口令（8–63 个字符、不是十六进制）：解不出来，返回空。
    try testing.expect(parse_string("secret123", &len) == null);
    try testing.expect(parse_string("abcdefgh", &len) == null);
    try testing.expect(parse_string("zz", &len) == null);
    try testing.expect(parse_string("\"unterminated", &len) == null);
    try testing.expect(parse_string("\"abc\"x", &len) == null);
}

test "wpa_cb: 给驱动的配置与收发入口原样转交" {
    fake.reset();
    var cfg: StaConfig = .{ .pmf_cfg = .{ .capable = true } };
    @memcpy(cfg.ssid[0..4], "hl-w");
    @memcpy(cfg.password[0..6], "secret"[0..6]);
    try testing.expectEqual(@as(c_int, 0), setStaConfig(&cfg));
    try testing.expectEqualSlices(u8, "hl-w", fake.config[0..4]);
    try testing.expectEqualSlices(u8, "secret"[0..6], fake.config[32..38]);
    try testing.expectEqual(@as(u8, 1), fake.config[128]);
    try testing.expectEqual(@as(c_int, 0), connect());
    try testing.expectEqual(@as(u32, 1), fake.connect_calls);
    try testing.expectEqual(@as(c_int, 0), disconnect());
    try testing.expectEqual(@as(u32, 1), fake.disconnect_calls);
}
