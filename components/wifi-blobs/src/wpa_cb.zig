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

/// wifi-connect 自己的请求方（按模块名 import，见 `firmware/build.zig` 的 `wifi_connect` 模块）。
const wc = @import("wifi_connect").supplicant;

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
    wpa_config_parse_string: ?*const fn ([*]const u8, *usize) callconv(.c) ?[*]u8 = null,
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

/// 登记给 blob 的那张表。
pub var funcs: Funcs = .{
    .wpa_sta_init = &staInit,
    .wpa_sta_deinit = &staDeinit,
    .wpa_sta_disconnected_cb = &staDisconnected,
    .wpa_parse_wpa_ie = &parseWpaIe,
};

/// blob 的请求方实例：`wpa_sta_init` 建出来，`wpa_sta_deinit` 收回去（`attached` 为假时内容没有定义）。
var supplicant: wc.Supplicant = undefined;
var attached: bool = false;

/// `wpa_attach()`（`esp_wpa_main.c:136`）= `wpa_sm_init()`（`rsn_supp/wpa.c:2407`）：状态机整块清零、
/// 停在初始态（IDF 的 `WPA_INACTIVE`；这里是图 12-49 的 INITIALIZE），没有任何密钥。认证方地址、
/// AKM、RSNE 都还没有（`aa` 为零、`pmk_set` 为假），到连接那一步再给。`wifi_station_start` 每次
/// start 都调它，所以每次都是一个全新实例（同 IDF 的 `memset(sm, 0, ...)`）。
///
/// IDF 的 `wpa_attach` 另有两件事这里不做：登记 EAPOL 发送完成回调（`eapol_txcb`，四次握手重传用，
/// 属于连接那一步）、`esp_set_scan_ie()`（对照镜像的 `WNM` / `MBO` 关，是空函数）。
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
    return true;
}

/// `wpa_deattach()` = `wpa_sm_deinit()`：收回请求方。
fn staDeinit() callconv(.c) bool {
    attached = false;
    return true;
}

/// `wpa_sta_disconnected_cb`（`esp_wpa_main.c:303`）：下面这一组原因码（`wifi_err_reason_t`）下 IDF 清掉
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
    // 表一直登记着：`wifi_station_stop` 之后进 INIT 态仍会走到这里，那时请求方已经收回。
    if (!attached or !dropsSa(reason)) return;
    supplicant.disconnect(); // 12.6.18：删除 PTKSA、GTKSA、IGTKSA，端口关掉
    supplicant.cfg.aa = @splat(0);
}

const register_wpa_cb = @extern(*const fn (*Funcs) callconv(.c) c_int, .{ .name = "esp_wifi_register_wpa_cb_internal" });
const get_config_sae_pwe_h2e = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "esp_wifi_get_config_sae_pwe_h2e_internal" });

/// IDF `esp_supplicant_init()` 的最小形态：把表登记给 blob（`g_ic->[444]`）。返回 blob 的返回码（0 = 成功）。
pub fn register() c_int {
    return register_wpa_cb(&funcs);
}

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
    try testing.expectEqual(wc.KmState.initialization, supplicant.state);
    try testing.expect(!supplicant.pmk_set);
    try testing.expect(!supplicant.port_enabled);
    try testing.expect(!supplicant.ptksa.valid);
    try testing.expect(!supplicant.gtksa.valid);

    supplicant.step(); // INITIALIZE → AUTHENTICATION
    try testing.expect(supplicant.associate()); // → STAKEYSTART，端口使能
    try testing.expect(supplicant.port_enabled);
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expectEqual(wc.KmState.initialization, supplicant.state);
    try testing.expect(!supplicant.port_enabled);
}

test "wpa_cb: 四次握手超时的断开通知丢掉安全关联并清掉认证方地址；不在那一组原因码里的通知不动它" {
    try testing.expect(funcs.wpa_sta_init.?());
    supplicant.cfg.aa = .{ 0x02, 0x00, 0x00, 0x00, 0x20, 0x01 };
    supplicant.step();
    try testing.expect(supplicant.associate());

    funcs.wpa_sta_disconnected_cb.?(1); // UNSPECIFIED：IDF 这时只清 PMKSA 缓存，本项目没有缓存
    try testing.expectEqual(wc.KmState.stakey_start, supplicant.state);
    try testing.expect(supplicant.port_enabled);

    funcs.wpa_sta_disconnected_cb.?(15); // 4WAY_HANDSHAKE_TIMEOUT
    try testing.expectEqual(wc.KmState.initialization, supplicant.state);
    try testing.expect(!supplicant.port_enabled);
    try testing.expectEqual([6]u8{ 0, 0, 0, 0, 0, 0 }, supplicant.cfg.aa);
}

test "wpa_cb: detach 之后的断开通知不碰已收回的请求方" {
    try testing.expect(funcs.wpa_sta_init.?());
    try testing.expect(funcs.wpa_sta_deinit.?());
    try testing.expect(!attached);
    supplicant.state = .authentication; // 已收回实例的内容本没有定义，这里拿它当哨兵
    funcs.wpa_sta_disconnected_cb.?(15);
    try testing.expectEqual(wc.KmState.authentication, supplicant.state);
}
