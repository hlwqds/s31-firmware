//! 主机测试用的目标符号替身（与 `components/bt-blobs/src/host_stubs.zig` 同一做法）。
//!
//! `osi_impl.zig` 的壳无条件引用 ROM、PHY、共存库的入口，而主机目标既不链归档也不链 ROM；
//! 没有这份替身，`wifi-blobs` 的主机测试在链接期就缺这些符号（2026-11-24 补上测试目标时实测）。
//! 五组：ROM / 共存库 / PHY 的 5 个入口（`osi_impl` 的初始化路径）；blob 的 SAE 配置（`wpa_cb.zig` 的 RSNX
//! 解析）；`libphy.a` 的 6 个 PHY 使能 / 关闭入口（`osi_impl` 的 PHY 壳）；以及一个**假驱动**——请求方连接时
//! 要问驱动要东西、往驱动里交东西的那些 blob 入口（`wpa_cb.zig` 的连接路径）。
//! **只被 `host_tests.zig` 与 `wpa_cb.zig` 的用例引用**，不进任何镜像；板上用真符号。

const std = @import("std");

/// ROM：`coex_init()`。核里是 `li a0,0; ret`（`coex_core_init` 的反汇编）。主机上数着调用次数：
/// 不开 `-Dcoex` 时 `_coex_init` 的计数桩不该来调它（`host_tests.zig`）。
pub var coex_calls: u32 = 0;

pub export fn coex_init() callconv(.c) void {
    coex_calls += 1;
}

/// ROM / `libcoexist.a`：`coex_enable()`。同上。
pub export fn coex_enable() callconv(.c) void {
    coex_calls += 1;
}

/// ROM：外设中断到 CPU 输入的路由表。
pub export fn intr_matrix_set(_: u32, _: u32, _: u32) callconv(.c) void {}

/// `libphy.a`：PHY 的 Wi-Fi 使能位。
pub export fn phy_wifi_enable_set(_: u8) callconv(.c) void {}

/// `libphy.a`：基带看门狗。
pub export fn set_bb_wdg(_: bool, _: bool, _: u16, _: u16, _: bool, _: bool, _: bool) callconv(.c) void {}

/// `libphy.a`：标定过之后的再次使能（`shellPhyEnable` 调）。
pub export fn phy_wakeup_init() callconv(.c) void {}

/// IDF `esp_phy` 的 `phy_common.c`（不在 `libphy.a` 里）：建 PLL 跟踪用的定时器（第一个 modem 打开时）。
pub export fn phy_track_pll_init() callconv(.c) void {}

/// IDF `esp_phy` 的 `phy_common.c`（不在 `libphy.a` 里）：置 `s_phy_modem_flag` 的 modem 位（参数是 `PHY_MODEM_*`）。
pub export fn phy_set_modem_flag(_: u32) callconv(.c) void {}

/// IDF `esp_phy` 的 `phy_common.c`（不在 `libphy.a` 里）：立刻跟一次 PLL。
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

// ---------------------------------------------------------------------------
// 假驱动：`wpa_cb.zig` 连接路径的用例
// ---------------------------------------------------------------------------
//
// 请求方在连接时要问驱动要东西（地址、SSID、口令、AP 的 RSNE、PMF 配置），也要往驱动里交东西
// （本 STA 的 RSNE、EAPOL 帧、钥匙）。板上这些是 blob 的函数；主机上落到这里：要什么给什么，
// 交来的都记进 `fake`，用例照着记录断言。行为上有一处与真驱动对齐：`esp_wifi_set_appie_internal`
// 的 flag 非 0 时，真驱动把长度当 u16 写进调用方缓冲的前两个字节（`ieee80211_set_appie` 的反汇编）。

/// blob `ieee80211_supplicant.o`：`struct wifi_ssid`。
const Ssid = extern struct { len: c_int, ssid: [32]u8 };

/// `wifi_config_t` 的大小（ilp32，C 侧验过）。
const config_size = 184;

/// 驱动的返回值、驱动里可配的状态，以及它收到的每一样东西。
pub const fake = struct {
    pub var mac: [6]u8 = .{ 0x02, 0x00, 0x00, 0x00, 0x20, 0x01 };
    pub var ssid: []const u8 = "";
    pub var password: []const u8 = "";
    /// `esp_wifi_sta_prof_is_rsn_internal()`。
    pub var profile_rsn: bool = true;
    /// 驱动的扫描缓存里这个 BSS 的 RSN IE（含 Element ID 与 Length）。
    pub var ap_rsne: ?[]const u8 = null;
    pub var notify_completed_rsne: bool = false;
    pub var pmf_capable: bool = false;
    pub var pmf_required: bool = false;
    pub var get_config_rc: c_int = 0;
    pub var appie_rc: c_int = 0;
    pub var sta_connect_rc: c_int = 0;
    pub var key_rc: c_int = 0;
    pub var tx_rc: c_int = 0;

    pub const KeyInstall = struct {
        alg: c_int,
        addr: [6]u8,
        key_idx: c_int,
        set_tx: c_int,
        rsc: [8]u8,
        rsc_len: usize,
        key: [32]u8,
        key_len: usize,
        flags: c_int,
    };

    pub const AppIe = struct { typ: u8, flag: u8, len: u16, rc: c_int, buf: [130]u8 };

    /// `esp_wifi_set_sta_key_internal` 收到的每一把钥匙。
    pub var keys: [8]KeyInstall = undefined;
    pub var n_keys: usize = 0;
    /// `esp_wifi_set_igtk_internal` 收到的每一个 `wifi_wpa_igtk_t`（40 字节）。
    pub var igtks: [4][40]u8 = undefined;
    pub var n_igtks: usize = 0;
    pub var app_ies: [4]AppIe = undefined;
    pub var n_app_ies: usize = 0;
    /// `esp_wifi_internal_tx` 收到的每一帧（EAPOL 或 IP 数据帧，都含 Ethernet 头）。
    pub var tx_frames: [16][1600]u8 = undefined;
    pub var tx_lens: [16]usize = undefined;
    pub var n_tx: usize = 0;
    pub var txdone_cb: ?*const fn ([*]u8, usize, bool) callconv(.c) void = null;
    pub var sta_connect_calls: u32 = 0;
    pub var sta_connect_bssid: [6]u8 = @splat(0);
    pub var connect_calls: u32 = 0;
    pub var disconnect_calls: u32 = 0;
    /// `esp_wifi_auth_done_internal()` 被调了几次：请求方每报一次「钥匙协商完成」加一。
    pub var auth_done_calls: u32 = 0;
    /// `esp_wifi_internal_reg_rxcb()` 登记的收帧回调（注销后是空）。
    pub var rxcb: ?*const fn (?*anyopaque, u16, ?*anyopaque) callconv(.c) c_int = null;
    /// 驱动缓冲交还了几次（`esp_wifi_internal_free_rx_buffer`）。
    pub var freed_rx_buffers: u32 = 0;
    /// `esp_wifi_internal_set_sta_ip()` 被调了几次。
    pub var sta_ip_calls: u32 = 0;
    pub var set_config_calls: u32 = 0;
    /// `esp_wifi_set_config` 收到的配置。
    pub var config: [config_size]u8 = @splat(0);

    /// 把 SSID 与口令抄进交给请求方的那个静态缓冲（`esp_wifi_set_config` 之后驱动里存的就是这两样）。
    pub fn refreshProfile() void {
        ssid_buf.len = @intCast(ssid.len);
        ssid_buf.ssid = @splat(0);
        @memcpy(ssid_buf.ssid[0..@min(ssid.len, 32)], ssid[0..@min(ssid.len, 32)]);
        password_buf = @splat(0);
        @memcpy(password_buf[0..@min(password.len, 64)], password[0..@min(password.len, 64)]);
        ap_rsne_buf = @splat(0);
        if (ap_rsne) |ie| @memcpy(ap_rsne_buf[0..@min(ie.len, ap_rsne_buf.len)], ie[0..@min(ie.len, ap_rsne_buf.len)]);
    }

    /// 驱动报告第 `i` 帧发送完成（或失败）。
    pub fn deliverTxDone(i: usize, failure: bool) void {
        const cb = txdone_cb orelse return;
        cb(@ptrCast(&tx_frames[i][14]), tx_lens[i] - 14, failure);
    }

    pub fn reset() void {
        mac = .{ 0x02, 0x00, 0x00, 0x00, 0x20, 0x01 };
        ssid = "";
        password = "";
        profile_rsn = true;
        ap_rsne = null;
        notify_completed_rsne = false;
        pmf_capable = false;
        pmf_required = false;
        get_config_rc = 0;
        appie_rc = 0;
        sta_connect_rc = 0;
        key_rc = 0;
        tx_rc = 0;
        n_keys = 0;
        n_igtks = 0;
        n_app_ies = 0;
        n_tx = 0;
        txdone_cb = null;
        sta_connect_calls = 0;
        sta_connect_bssid = @splat(0);
        connect_calls = 0;
        disconnect_calls = 0;
        auth_done_calls = 0;
        rxcb = null;
        freed_rx_buffers = 0;
        sta_ip_calls = 0;
        set_config_calls = 0;
        config = @splat(0);
    }
};

var ssid_buf: Ssid = .{ .len = 0, .ssid = @splat(0) };
var password_buf: [65]u8 = @splat(0);
var ap_rsne_buf: [256]u8 = @splat(0);

/// blob `ieee80211_supplicant.o`：STA 的 profile 是不是 RSN / WPA / WAPI。
pub export fn esp_wifi_sta_prof_is_rsn_internal() callconv(.c) bool {
    return fake.profile_rsn;
}

pub export fn esp_wifi_sta_prof_is_wpa_internal() callconv(.c) bool {
    return false;
}

pub export fn esp_wifi_sta_prof_is_wapi_internal() callconv(.c) bool {
    return false;
}

/// blob `ieee80211_supplicant.o`：STA 的 SSID、口令。
pub export fn esp_wifi_sta_get_prof_ssid_internal() callconv(.c) *const Ssid {
    return &ssid_buf;
}

pub export fn esp_wifi_sta_get_prof_password_internal() callconv(.c) [*:0]const u8 {
    return @ptrCast(&password_buf);
}

/// blob `ieee80211_api.o`：读、写 STA 的配置（`wifi_config_t`，184 字节）。
pub export fn esp_wifi_get_config(_: c_int, cfg: [*]u8) callconv(.c) c_int {
    @memset(cfg[0..config_size], 0);
    cfg[128] = @intFromBool(fake.pmf_capable);
    cfg[129] = @intFromBool(fake.pmf_required);
    return fake.get_config_rc;
}

pub export fn esp_wifi_set_config(_: c_int, cfg: [*]const u8) callconv(.c) c_int {
    @memcpy(fake.config[0..config_size], cfg[0..config_size]);
    fake.set_config_calls += 1;
    return 0;
}

/// blob `ieee80211_supplicant.o`：本 STA 的地址、扫描缓存里的 IE、AP 的「RSNE 完成位」。
pub export fn esp_wifi_get_macaddr_internal(_: u8, mac: [*]u8) callconv(.c) c_int {
    @memcpy(mac[0..6], &fake.mac);
    return 0;
}

pub export fn esp_wifi_sta_get_ie(_: [*]const u8, elem_id: u8) callconv(.c) ?[*]const u8 {
    const ie = fake.ap_rsne orelse return null;
    if (elem_id != ie[0]) return null;
    return &ap_rsne_buf;
}

pub export fn esp_wifi_sta_is_ap_notify_completed_rsne_internal() callconv(.c) bool {
    return fake.notify_completed_rsne;
}

pub export fn esp_wifi_set_appie_internal(typ: u8, ie: [*]const u8, len: u16, flag: u8) callconv(.c) c_int {
    if (flag != 0) std.mem.writeInt(u16, @constCast(ie)[0..2], len, .little);
    // 只记 RSN 这一种（本镜像也只交这一种）；记的是驱动写完长度之后的缓冲。
    if (typ == 4) {
        if (fake.n_app_ies >= fake.app_ies.len) return -1;
        const rec = &fake.app_ies[fake.n_app_ies];
        rec.* = .{ .typ = typ, .flag = flag, .len = len, .rc = fake.appie_rc, .buf = @splat(0) };
        const n = @min(@as(usize, len), rec.buf.len);
        @memcpy(rec.buf[0..n], ie[0..n]);
        fake.n_app_ies += 1;
    }
    return fake.appie_rc;
}

/// blob `ieee80211_supplicant.o`：关联、装钥匙。
pub export fn esp_wifi_sta_connect_internal(bssid: [*]const u8) callconv(.c) c_int {
    fake.sta_connect_calls += 1;
    fake.sta_connect_bssid = bssid[0..6].*;
    return fake.sta_connect_rc;
}

pub export fn esp_wifi_set_sta_key_internal(alg: c_int, addr: [*]const u8, key_idx: c_int, set_tx: c_int, seq: ?[*]const u8, seq_len: usize, key: [*]const u8, key_len: usize, flags: c_int) callconv(.c) c_int {
    if (fake.n_keys >= fake.keys.len) return -1;
    var k: fake.KeyInstall = .{
        .alg = alg,
        .addr = addr[0..6].*,
        .key_idx = key_idx,
        .set_tx = set_tx,
        .rsc = @splat(0),
        .rsc_len = seq_len,
        .key = @splat(0),
        .key_len = key_len,
        .flags = flags,
    };
    if (seq) |s| @memcpy(k.rsc[0..@min(seq_len, k.rsc.len)], s[0..@min(seq_len, k.rsc.len)]);
    @memcpy(k.key[0..@min(key_len, k.key.len)], key[0..@min(key_len, k.key.len)]);
    fake.keys[fake.n_keys] = k;
    fake.n_keys += 1;
    return fake.key_rc;
}

pub export fn esp_wifi_set_igtk_internal(_: u8, igtk: [*]const u8) callconv(.c) c_int {
    if (fake.n_igtks >= fake.igtks.len) return -1;
    @memcpy(fake.igtks[fake.n_igtks][0..40], igtk[0..40]);
    fake.n_igtks += 1;
    return fake.key_rc;
}

/// blob `ieee80211_output.o`：发一帧（EAPOL 或 IP 数据帧：都带 Ethernet 头）。
pub export fn esp_wifi_internal_tx(_: c_int, buf: [*]const u8, len: u16) callconv(.c) c_int {
    if (fake.n_tx >= fake.tx_frames.len) return -1;
    const n = @min(@as(usize, len), fake.tx_frames[0].len);
    @memcpy(fake.tx_frames[fake.n_tx][0..n], buf[0..n]);
    fake.tx_lens[fake.n_tx] = n;
    fake.n_tx += 1;
    return fake.tx_rc;
}

pub export fn esp_wifi_register_eapol_txdonecb_internal(cb: ?*const fn ([*]u8, usize, bool) callconv(.c) void) callconv(.c) c_int {
    fake.txdone_cb = cb;
    return 0;
}

/// blob `ieee80211_api.o`：发起、断开连接。
pub export fn esp_wifi_connect_internal() callconv(.c) c_int {
    fake.connect_calls += 1;
    return 0;
}

/// blob `ieee80211_supplicant.o`：钥匙协商完成（IDF `wpa_neg_complete()` 调它，里面是 `cnx_auth_done`）。
pub export fn esp_wifi_auth_done_internal() callconv(.c) bool {
    fake.auth_done_calls += 1;
    return true;
}

/// blob `ieee80211_output.o`：登记 / 注销收帧回调（IDF 的 netif 口在 STA 连上之后登记）。
pub export fn esp_wifi_internal_reg_rxcb(_: c_int, cb: ?*const fn (?*anyopaque, u16, ?*anyopaque) callconv(.c) c_int) callconv(.c) c_int {
    fake.rxcb = cb;
    return 0;
}

/// blob `esf_buf.o`：一帧用完，把驱动缓冲交还。
pub export fn esp_wifi_internal_free_rx_buffer(_: ?*anyopaque) callconv(.c) void {
    fake.freed_rx_buffers += 1;
}

/// blob `ieee80211_supplicant.o`：STA 拿到了地址（IDF got-ip 的默认处理调它）。
pub export fn esp_wifi_internal_set_sta_ip() callconv(.c) c_int {
    fake.sta_ip_calls += 1;
    return 0;
}

pub export fn esp_wifi_disconnect_internal() callconv(.c) c_int {
    fake.disconnect_calls += 1;
    return 0;
}
