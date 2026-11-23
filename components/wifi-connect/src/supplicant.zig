//! wifi-connect：RSNA 请求方（supplicant）——4 次握手、组密钥握手、安全关联，
//! 以及 IEEE Std 802.11-2016 12.7.10 的请求方密钥管理状态机。
//!
//! 覆盖的条款：
//!   12.7.10（印刷页 2062–2064，图 12-49）：四个状态 INITIALIZE、AUTHENTICATION、
//!     DISCONNECTED、STAKEYSTART，以及 portValid / portEnable 等变量。
//!   12.7.6（印刷页 2029–2037）：4 次握手。消息 1 没有 MIC，只用来带 ANonce 和
//!     PMKID；请求方每收到一个不陈旧的消息 1 就换一个新的 SNonce、重算 PTK、回消息 2。
//!     消息 3 要过重放计数、ANonce、RSNE、MIC 四道检查，然后才装 PTK / GTK / IGTK
//!     并回消息 4。消息 1 的内容在消息 3 证实之前不得用来更新已装的密钥。
//!   12.7.7（印刷页 2040–2042）：组密钥握手。消息 1 的重放计数必须严格大于本会话
//!     里见过的任何 EAPOL-Key 帧，MIC 用当前 PTK 的 KCK 验，通过后装 GTK（和 IGTK）。
//!   12.7.2 d)（印刷页 2022）：本地 Key Replay Counter 只在 MIC 验证通过之后才更新，
//!     所以消息 1 从不更新它——这样消息 1 重传（计数更大）之后消息 3 仍然能过。
//!   12.6.1.1（印刷页 1985–1986）：PTKSA 在消息 3 被请求方证实时建立；GTKSA、
//!     IGTKSA 在消息 3 或组密钥握手消息 1 到达时建立。
//!
//! 明确不做：802.1X / EAP（PMK 由调用方给：PSK 直接当 PMK，或 SAE 的结果）、
//! SMK/PeerKey、FT、扩展 Key ID（PTK 的 Key ID 恒为 0）、超时与重传（12.7.10：
//! 「本状态机不用超时与重试」，由上层负责）。
//!
//! 没有随机数源：每次接受消息 1 时需要的 SNonce 由调用方传入。没有分配器。
//! 不 import hw/log。

const std = @import("std");
const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const hdr = @import("hdr.zig");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const mfp = @import("mfp.zig");
const rsne = @import("rsne.zig");
const wpa2 = @import("wpa2.zig");

pub const HandshakeError = kde.WrapError || rsne.Error || error{
    /// EAPOL-Key 帧太短或长度字段不符（12.7.2：字段值无效的帧应静默丢弃）。
    BadFrame,
    /// Descriptor Type 不是 RSN。
    BadDescriptor,
    /// Key Information 与消息号/方向不符，或 Key Length、Descriptor Version 不对；
    /// 也包括消息 3 / 组密钥消息 1 的 Key Data 没有加密（12.7.2 j)：带 GTK KDE
    /// 却不加密的帧应忽略；12.7.6.4、12.7.7.2 的字段表都规定 Encrypted Key Data = 1）。
    BadKeyInfo,
    /// Key Replay Counter 不比已见过的值大。
    BadReplay,
    /// 消息顺序不对：消息 3 / 组密钥消息 1 来早了。
    BadOrder,
    /// MIC 不对（口令不同，或帧被改过）。
    BadMic,
    /// 消息 3 的 ANonce 与消息 1 的不同。
    NonceMismatch,
    /// 消息 1 带的 PMKID 不是本 PMK 的。
    PmkidMismatch,
    /// 消息 3 的 RSNE 与 Beacon / Probe Response 里的不一致（应解除关联）。
    RsneMismatch,
    /// 消息 3 或组密钥消息 1 没带 GTK。
    NoGtk,
    /// 协商了管理帧保护，消息 3 却没带 IGTK KDE。
    NoIgtk,
    /// GTK / IGTK 的长度与密码套件不符。
    BadKeyLength,
    /// 消息 1 的 ANonce 全 0。
    BadNonce,
    /// 状态机不在 STAKEYSTART：没有进行中的握手，帧被静默丢弃。
    NotStarted,
    /// 两个 RSNE 字段不一致（消息 3 的第二个 RSNE 不合规）。
    InconsistentRsne,
};

pub const Error = HandshakeError || ccmp.Error || bip.Error || mfp.Error || error{
    /// 对应的安全关联不存在（还没握手，或已删除）。
    NoKey,
    /// 收到的帧的 TA 不是这个 PTKSA 的认证方，或 Key ID 与安全关联不符。
    WrongPeer,
    /// PN / IPN 不大于重放计数。
    Replay,
};

fn zeroise(bytes: []u8) void {
    @memset(bytes, 0);
}

// ---------------------------------------------------------------------------
// 安全关联（12.6.1.1）
// ---------------------------------------------------------------------------

/// PTKSA（12.6.1.1.6，印刷页 1985）：PTK、成对密码套件、两端 MAC、Key ID，
/// 外加每帧保护要用的收发 PN。
pub const Ptksa = struct {
    valid: bool = false,
    kck: [wpa2.kck_len]u8 = @splat(0),
    kek: [wpa2.kek_len]u8 = @splat(0),
    tk: [ccmp.tk_len]u8 = @splat(0),
    cipher: ccmp.Cipher = .ccmp128,
    key_id: u2 = 0,
    spa: [6]u8 = @splat(0),
    aa: [6]u8 = @splat(0),
    /// 最近一次发送用的 PN，0 表示还没发过；每个 SA 一个计数器（12.5.3.3.6）。
    tx_pn: u64 = 0,
    rx: ccmp.Replay = .{},

    /// MLME-DELETEKEYS：清掉密钥 material，PN 归零。
    pub fn reset(self: *Ptksa) void {
        zeroise(&self.kck);
        zeroise(&self.kek);
        zeroise(&self.tk);
        self.* = .{};
    }

    /// 用 PTK 保护一帧（数据帧或单独寻址的稳健管理帧用同一把 TK，12.5.3.3.6）。
    /// PN 先加再用，所以第一帧是 1。
    pub fn protect(self: *Ptksa, mpdu: []const u8, out: []u8) Error!usize {
        if (!self.valid) return error.NoKey;
        if (self.tx_pn >= ccmp.pn_max) return error.BadPn;
        self.tx_pn += 1;
        return ccmp.encapsulate(.{ .cipher = self.cipher, .pn = self.tx_pn, .key_id = self.key_id }, self.tk, mpdu, out);
    }

    /// 解封装一帧并做重放检测：TA 必须是这个 SA 的认证方，PN 要大于对应计数器，
    /// MIC 通过之后才推进计数器（12.5.3.4.4 a)）。
    pub fn unprotect(self: *Ptksa, mpdu: []const u8, out: []u8) Error!ccmp.Decapped {
        if (!self.valid) return error.NoKey;
        const h = try hdr.parse(mpdu);
        if (!std.mem.eql(u8, &h.a2, &self.aa)) return error.WrongPeer;
        const d = try ccmp.decapsulate(self.cipher, self.tk, mpdu, out, false);
        const is_mgmt = d.hdr.kind == .mgmt;
        if (!self.rx.isFresh(d.pn, is_mgmt, d.hdr.tid)) return error.Replay;
        self.rx.update(d.pn, is_mgmt, d.hdr.tid);
        return d;
    }
};

/// GTKSA（12.6.1.1.8，印刷页 1985–1986）：非 AP STA 的 GTKSA 只用于接收。
pub const Gtksa = struct {
    valid: bool = false,
    gtk: [ccmp.tk_len]u8 = @splat(0),
    key_id: u8 = 0,
    cipher: ccmp.Cipher = .ccmp128,
    /// GTK KDE 的 Tx 位。
    tx: bool = false,
    /// 消息里 Key RSC 字段的值；接收重放计数以它为初值。
    rsc: u64 = 0,
    rx: ccmp.Replay = .{},

    pub fn reset(self: *Gtksa) void {
        zeroise(&self.gtk);
        self.* = .{};
    }

    pub fn unprotect(self: *Gtksa, mpdu: []const u8, out: []u8) Error!ccmp.Decapped {
        if (!self.valid) return error.NoKey;
        const d = try ccmp.decapsulate(self.cipher, self.gtk, mpdu, out, false);
        // 8 字节头里的 Key ID 指明用的是哪把 GTK。
        if (d.key_id != @as(u2, @truncate(self.key_id))) return error.WrongPeer;
        if (!self.rx.isFresh(d.pn, false, d.hdr.tid)) return error.Replay;
        self.rx.update(d.pn, false, d.hdr.tid);
        return d;
    }
};

/// IGTKSA（12.6.1.1.9，印刷页 1986）：Key ID、IGTK、认证方 MAC、收发方向。
pub const IgtkSa = struct {
    valid: bool = false,
    igtk: [bip.igtk_len]u8 = @splat(0),
    key_id: u16 = 0,
    aa: [6]u8 = @splat(0),
    replay: bip.IgtkReplay = .{},

    pub fn reset(self: *IgtkSa) void {
        zeroise(&self.igtk);
        self.* = .{};
    }

    /// 校验一个组寻址稳健管理帧（12.5.4.6）：按 Key ID 找 IGTK、查 IPN 重放、验 MIC、
    /// 通过后推进重放计数。返回去掉 MME 的帧长。
    pub fn unprotect(self: *IgtkSa, frame: []const u8) Error!bip.Verified {
        if (!self.valid) return error.NoKey;
        const mmie = try bip.parseMmie(frame);
        if (mmie.key_id != self.key_id) return error.WrongPeer;
        if (!self.replay.isFresh(mmie.ipn)) return error.Replay;
        const v = try bip.verify(self.igtk, frame);
        self.replay.update(mmie.ipn);
        return v;
    }
};

// ---------------------------------------------------------------------------
// 请求方密钥管理状态机（12.7.10）
// ---------------------------------------------------------------------------

/// 图 12-49 的四个状态。
pub const KmState = enum {
    initialization,
    authentication,
    disconnected,
    stakey_start,

    pub fn name(self: KmState) []const u8 {
        return switch (self) {
            .initialization => "INITIALIZE",
            .authentication => "AUTHENTICATION",
            .disconnected => "DISCONNECTED",
            .stakey_start => "STAKEYSTART",
        };
    }
};

/// STAKEYSTART 里握手走到哪一步。
pub const Phase = enum {
    /// 还没收到消息 1。
    idle,
    /// 已回消息 2，等消息 3。
    ptk_started,
    /// 消息 3 已证实、消息 4 已发出，PTKSA 已建立。
    ptk_done,

    pub fn name(self: Phase) []const u8 {
        return switch (self) {
            .idle => "idle",
            .ptk_started => "ptk_started",
            .ptk_done => "ptk_done",
        };
    }
};

pub const Config = struct {
    spa: [6]u8,
    aa: [6]u8,
    /// AKM suite type（`rsne.Akm`）。决定 EAPOL-Key 的 MIC 算法与 Key Descriptor Version。
    akm: u8,
    pairwise: ccmp.Cipher,
    group: ccmp.Cipher,
    /// 管理帧保护已协商：双方 RSNE 的 MFPC 都是 1。
    mfp: bool,
    /// AP 在 Beacon / Probe Response 里的 RSNE（整段元素，含 Element ID 与 Length）。
    ap_rsne: []const u8,
    /// 本 STA 放进 (Re)Association Request 的 RSNE；消息 2 原样带上（12.7.2，印刷页 2025）。
    sta_rsne: []const u8,
};

pub const Supplicant = struct {
    cfg: Config,
    state: KmState = .initialization,
    phase: Phase = .idle,
    pmk: [wpa2.pmk_len]u8 = @splat(0),
    pmkid: [16]u8 = @splat(0),
    anonce: [wpa2.nonce_len]u8 = @splat(0),
    snonce: [wpa2.nonce_len]u8 = @splat(0),
    /// 消息 1 之后算出的候选 PTK（12.7.10.3 的 TPTK），消息 3 证实后装进 `ptksa`。
    tptk: [wpa2.ptk_ccmp_len]u8 = @splat(0),
    ptksa: Ptksa = .{},
    gtksa: Gtksa = .{},
    igktsa: IgtkSa = .{},
    /// 已被有效 MIC 证实过的最大 Key Replay Counter（12.7.2 d)）。
    key_replay_counter: u64 = 0,
    /// 最近一次接受的消息 1 的计数；消息 2 照抄它。
    pending_replay: u64 = 0,
    /// 802.1X::portValid：密钥装好才为真。
    port_valid: bool = false,
    /// 802.1X::portEnable
    port_enabled: bool = false,
    /// 握手期间被拒绝的帧数与最近一次原因（日志用）。
    rejects: u32 = 0,
    last_error: ?Error = null,

    fn reject(self: *Supplicant, e: Error) Error {
        self.rejects += 1;
        self.last_error = e;
        return e;
    }

    pub fn micAlg(self: *const Supplicant) wpa2.MicAlg {
        return switch (self.cfg.akm) {
            rsne.Akm.sae => .aes128_cmac,
            else => .hmac_sha1_128,
        };
    }

    /// 候选 PTK（消息 1 之后有效）。
    pub fn candidatePtk(self: *const Supplicant) [wpa2.ptk_ccmp_len]u8 {
        return self.tptk;
    }

    // -- 状态迁移（图 12-49） ----------------------------------------------

    /// INITIALIZE 的动作：Keycount = 0，Init = false，DeauthenticationRequest = false，
    /// MSK = 0，portEnable = false，MLME-DELETEKEYS(PTK、GTK[0...N]、IGTK[0...M])，
    /// portValid = false。之后停在 INITIALIZE，等 `step()` 走无条件迁移。
    fn enterInitialize(self: *Supplicant) void {
        self.ptksa.reset();
        self.gtksa.reset();
        self.igktsa.reset();
        zeroise(&self.tptk);
        zeroise(&self.snonce);
        self.port_enabled = false;
        self.port_valid = false;
        self.phase = .idle;
        self.state = .initialization;
    }

    /// 上电初始化或收到 Deauthentication / Disassociation：进 INITIALIZE，并记下
    /// PMK、算出 PMKID。INITIALIZE → AUTHENTICATION 的无条件迁移由 `step()` 完成。
    /// `cfg` 由调用方在构造 `Supplicant{ .cfg = ... }` 时给好。
    pub fn start(self: *Supplicant, pmk: [wpa2.pmk_len]u8) void {
        self.pmk = pmk;
        self.pmkid = wpa2.pmkid(pmk, self.cfg.aa, self.cfg.spa);
        self.key_replay_counter = 0;
        self.enterInitialize();
    }

    /// Unconditional transfer：INITIALIZE → AUTHENTICATION（AuthenticationFailed =
    /// false，STADisconnect()），DISCONNECTED → INITIALIZE。
    /// 其余状态下调用没有效果。
    pub fn step(self: *Supplicant) void {
        switch (self.state) {
            .initialization => self.state = .authentication,
            .disconnected => self.enterInitialize(),
            else => {},
        }
    }

    /// AuthenticationRequest：AUTHENTICATION → STAKEYSTART。SNonce = Random（等消息 1
    /// 到了才生成），PTK = GTK = IGTK = 0，portValid = false，portControl = Auto，
    /// portEnable = true。重放计数在（重）关联时清零（12.7.2 d)）。
    pub fn associate(self: *Supplicant) bool {
        if (self.state != .authentication) return false;
        self.ptksa.reset();
        self.gtksa.reset();
        self.igktsa.reset();
        self.key_replay_counter = 0;
        self.port_valid = false;
        self.port_enabled = true;
        self.phase = .idle;
        self.state = .stakey_start;
        return true;
    }

    /// DeauthenticationRequest，或 dot11RSNAConfigSALifetime 超时：进 INITIALIZE。
    /// 12.6.18：非 AP STA 删除 PTKSA、GTKSA、IGTKSA。
    pub fn disconnect(self: *Supplicant) void {
        self.enterInitialize();
    }

    /// AuthenticationFailed：进 DISCONNECTED（执行 StaDisconnect），`step()` 再回
    /// INITIALIZE。消息 3 的 RSNE 校验失败也走这里（12.7.6.4 a)：应解除关联或去认证）。
    pub fn authFailed(self: *Supplicant) void {
        self.enterInitialize();
        self.state = .disconnected;
    }

    /// 12.6.19：稳健管理帧的保护能不能用了——PTK 与 IGTK 都已安装。
    pub fn keysInstalled(self: *const Supplicant) bool {
        return self.ptksa.valid and self.igktsa.valid;
    }

    fn installPtk(self: *Supplicant) void {
        self.ptksa.reset();
        self.ptksa = .{
            .valid = true,
            .kck = self.tptk[0..wpa2.kck_len].*,
            .kek = self.tptk[wpa2.kck_len..][0..wpa2.kek_len].*,
            .tk = self.tptk[wpa2.kck_len + wpa2.kek_len ..][0..ccmp.tk_len].*,
            .cipher = self.cfg.pairwise,
            .key_id = 0,
            .spa = self.cfg.spa,
            .aa = self.cfg.aa,
        };
        self.port_valid = true;
    }

    fn installGtk(self: *Supplicant, key_id: u8, tx: bool, gtk: []const u8, rsc: u64) Error!void {
        if (gtk.len != ccmp.tk_len) return error.BadKeyLength;
        self.gtksa.reset();
        self.gtksa = .{
            .valid = true,
            .key_id = key_id & 0x03,
            .cipher = self.cfg.group,
            .tx = tx,
            .rsc = rsc,
        };
        @memcpy(&self.gtksa.gtk, gtk);
        // Key RSC 是认证方给 GTK 用的起始 PN（12.7.6.4），接收重放计数以它同步。
        self.gtksa.rx.reset(rsc);
    }

    fn installIgtk(self: *Supplicant, key_id: u16, igtk: []const u8, ipn: u64) Error!void {
        if (igtk.len != bip.igtk_len) return error.BadKeyLength;
        self.igktsa.reset();
        self.igktsa = .{ .valid = true, .key_id = key_id, .aa = self.cfg.aa };
        @memcpy(&self.igktsa.igtk, igtk);
        // 12.5.4.4：接收重放计数置成 IGTK KDE 里的 IPN。
        self.igktsa.replay.reset(ipn);
    }

    // -- EAPOL-Key 收发 ----------------------------------------------------

    fn send(self: *Supplicant, kck: [wpa2.kck_len]u8, kf: wpa2.KeyFrame, key_data: []const u8, out: []u8) Error!usize {
        var f = kf;
        f.version = wpa2.eapol_protocol_version;
        // Key Descriptor Version 在 Key Information 的 B0–2，由 AKM 决定（表 12-8）。
        f.key_info = (f.key_info & ~wpa2.KeyInfo.version_mask) | @as(u16, self.micAlg().descriptorVersion());
        @memset(&f.mic, 0);
        const n = wpa2.encode(f, key_data, out) catch return self.reject(error.BadFrame);
        const mic = wpa2.computeMicAlg(self.micAlg(), kck, out[0..n]) catch return self.reject(error.BadFrame);
        wpa2.setFrameMic(out[0..n], mic);
        return n;
    }

    /// 处理一帧来自认证方的 EAPOL-Key（整帧，含 EAPOL 头）。`snonce` 是为这次
    /// 握手新画的 SNonce，只在帧是消息 1 时用到。需要回应时把回应帧写进 `out`
    /// （至少 `eapol_header_len + key_body_fixed_len + sta_rsne.len` 字节）并返回长度。
    ///
    /// 标准里的「静默丢弃」在这里是返回一个具体的错误值，调用方记日志后丢掉即可。
    pub fn recvEapol(self: *Supplicant, eapol: []const u8, snonce: [wpa2.nonce_len]u8, out: []u8) Error!usize {
        if (self.state != .stakey_start) return self.reject(error.NotStarted);
        const dec = wpa2.decode(eapol) catch |e| return self.reject(if (e == error.BadDescriptor) error.BadDescriptor else error.BadFrame);
        const f = dec.frame;
        const info = f.key_info;

        // 认证方不会置 Request 位（12.7.2 b) 9)）；SMK 握手不在本组件范围；
        // Error 位由请求方置（b) 8)）；Key Descriptor Version 必须是 AKM 对应的那个（b) 1)）。
        if ((info & wpa2.KeyInfo.request) != 0 or
            (info & wpa2.KeyInfo.smk_message) != 0 or
            (info & wpa2.KeyInfo.err) != 0 or
            (info & wpa2.KeyInfo.version_mask) != self.micAlg().descriptorVersion())
        {
            return self.reject(error.BadKeyInfo);
        }
        // 本状态机里认证方发来的两种握手消息都带 Key Ack（消息 1、3，组密钥消息 1）。
        if ((info & wpa2.KeyInfo.ack) == 0) return self.reject(error.BadKeyInfo);

        const pairwise = (info & wpa2.KeyInfo.pairwise) != 0;
        const with_mic = (info & wpa2.KeyInfo.mic) != 0;
        const secure = (info & wpa2.KeyInfo.secure) != 0;
        const encr = (info & wpa2.KeyInfo.encr_key_data) != 0;

        if (!pairwise) {
            // 12.7.7.2：Install = 0，Key MIC = 1，Secure = 1，Encrypted Key Data = 1，Key Length = 0。
            if (!with_mic or !secure or !encr or
                (info & wpa2.KeyInfo.install) != 0 or f.key_len != 0) return self.reject(error.BadKeyInfo);
            return self.recvGroupMsg1(eapol, f, dec.key_data, out);
        }

        if (!with_mic) {
            // 12.7.6.2：Install = 0，Key MIC = 0，Secure = 0，Encrypted Key Data = 0；
            // Key Length = 成对密码套件的 TK 长度（表 12-4）。
            if (secure or encr or (info & wpa2.KeyInfo.install) != 0 or f.key_len != ccmp.tk_len) {
                return self.reject(error.BadKeyInfo);
            }
            return self.recvMsg1(f, dec.key_data, snonce, out);
        }

        // 12.7.6.4：Install = 0/1，Key Ack = 1，Key MIC = 1，Secure = 1，Encrypted Key Data = 1。
        if (!secure or !encr or f.key_len != ccmp.tk_len) return self.reject(error.BadKeyInfo);
        return self.recvMsg3(eapol, f, dec.key_data, out);
    }

    /// 4 次握手消息 1（12.7.6.2，印刷页 2030）。计数「以前用过」（不大于已被 MIC 证实
    /// 的值）就丢；否则换新的 SNonce、重算 PTK、回消息 2。消息 1 重传也走这里。
    fn recvMsg1(self: *Supplicant, f: wpa2.KeyFrame, key_data: []const u8, snonce: [wpa2.nonce_len]u8, out: []u8) Error!usize {
        if (!wpa2.replayAccept(self.key_replay_counter, f.replay)) return self.reject(error.BadReplay);
        if (std.mem.allEqual(u8, &f.nonce, 0)) return self.reject(error.BadNonce);

        // Key Data = 这个 PMK 的 PMKID（不加密）。对不上说明认证方用的是另一个 PMKSA。
        if (key_data.len > 0) {
            var parser = kde.Parser.init(key_data);
            while (parser.next() catch |e| return self.reject(e)) |item| {
                switch (item) {
                    .pmkid => |p| {
                        if (!std.mem.eql(u8, &p, &self.pmkid)) return self.reject(error.PmkidMismatch);
                    },
                    else => {},
                }
            }
        }

        self.anonce = f.nonce;
        self.snonce = snonce;
        self.tptk = wpa2.derivePtk(wpa2.ptk_ccmp_len, self.pmk, self.cfg.aa, self.cfg.spa, self.anonce, self.snonce);
        self.pending_replay = f.replay;
        self.phase = .ptk_started;

        // 12.7.6.3：Key Type = Pairwise，Install = 0，Key Ack = 0，Key MIC = 1，Secure = 0，
        // Key Length = 0，Key Replay Counter = n，Key Nonce = SNonce，Key Data = 本 STA 的 RSNE。
        const kf = wpa2.KeyFrame{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.mic,
            .replay = f.replay,
            .nonce = self.snonce,
        };
        return self.send(self.tptk[0..wpa2.kck_len].*, kf, self.cfg.sta_rsne, out);
    }

    /// 消息 3 的 RSNE 校验（12.7.6.4 a)、12.7.2，印刷页 2025–2026）：第一个 RSNE
    /// 必须与 Beacon / Probe Response 里的逐字节相同；第二个 RSNE 可选，用来改写
    /// 成对密码套件——它只写一个套件、必须是认证方通告过的、其余字段与第一个相同。
    /// 返回改写后的成对密码套件；没有第二个 RSNE 时返回 null（沿用已选的）。
    fn verifyRsnes(self: *Supplicant, first: []const u8, second: ?[]const u8) Error!?u8 {
        if (!std.mem.eql(u8, first, self.cfg.ap_rsne)) return error.RsneMismatch;
        const a = rsne.parse(first) catch return error.RsneMismatch;
        const second_slice = second orelse return null;

        var s = rsne.parse(second_slice) catch return error.InconsistentRsne;
        if (s.pairwise_len != 1) return error.InconsistentRsne;
        const override = s.pairwise[0];
        const advertised = if (a.pairwise_len == 0)
            override == rsne.Cipher.ccmp128 // 列表缺席时的默认成对套件（9.4.2.25.2）
        else
            std.mem.indexOfScalar(u8, a.pairwise[0..a.pairwise_len], override) != null;
        if (!advertised) return error.InconsistentRsne;

        // 「其余字段 identical」（12.7.2，印刷页 2026）：逐项比。
        const same = s.group == a.group and
            s.akm_len == a.akm_len and std.mem.eql(u8, s.akm[0..s.akm_len], a.akm[0..a.akm_len]) and
            s.caps_present == a.caps_present and s.caps == a.caps and
            s.pmkid_present == a.pmkid_present and s.pmkid_len == a.pmkid_len and
            std.mem.eql(u8, std.mem.sliceAsBytes(s.pmkid[0..s.pmkid_len]), std.mem.sliceAsBytes(a.pmkid[0..a.pmkid_len])) and
            s.gmcs_present == a.gmcs_present and s.gmcs == a.gmcs;
        if (!same) return error.InconsistentRsne;
        return override;
    }

    /// 4 次握手消息 3（12.7.6.4，印刷页 2034–2035）。
    fn recvMsg3(self: *Supplicant, eapol: []const u8, f: wpa2.KeyFrame, key_data: []const u8, out: []u8) Error!usize {
        // 计数用过：丢弃。先判它，重放的消息 3 无论握手走到哪一步都报重放。
        if (!wpa2.replayAccept(self.key_replay_counter, f.replay)) return self.reject(error.BadReplay);
        if (self.phase != .ptk_started) return self.reject(error.BadOrder);
        // ANonce 与消息 1 不同：丢弃。
        if (!std.mem.eql(u8, &f.nonce, &self.anonce)) return self.reject(error.NonceMismatch);
        const kck = self.tptk[0..wpa2.kck_len].*;
        const kek = self.tptk[wpa2.kck_len..][0..wpa2.kek_len].*;
        const mic_ok = wpa2.verifyMicAlg(self.micAlg(), kck, eapol) catch return self.reject(error.BadFrame);
        if (!mic_ok) return self.reject(error.BadMic);

        // Key Data 是加密的：RSNE(1 或 2 个) ‖ GTK KDE ‖ (IGTK KDE)，用候选 PTK 的 KEK 解开。
        var plain_buf: [keywrap.max_plain]u8 = undefined;
        const unwrapped = kde.unwrapKeyData(kek, key_data, &plain_buf) catch |e| return self.reject(e);
        var first_rsne: ?[]const u8 = null;
        var second_rsne: ?[]const u8 = null;
        var gtk: ?kde.GtkKde = null;
        var igtk: ?kde.IgtkKde = null;
        var parser = kde.Parser.init(unwrapped.plain);
        while (parser.next() catch |e| return self.reject(e)) |item| {
            switch (item) {
                .element => |el| {
                    if (el.id == rsne.element_id) {
                        if (first_rsne == null) first_rsne = el.full else second_rsne = el.full;
                    }
                },
                .gtk => |g| gtk = g,
                .igtk => |i| igtk = i,
                else => {}, // 不认识的元素与 KDE：忽略（12.7.2 j)）
            }
        }
        const override = self.verifyRsnes(first_rsne orelse return self.reject(error.RsneMismatch), second_rsne) catch |e| {
            // 12.7.6.4 a)：校验不过应解除关联或去认证——按认证失败处理。
            self.rejects += 1;
            self.last_error = e;
            self.authFailed();
            return e;
        };
        const g = gtk orelse return self.reject(error.NoGtk);
        if (self.cfg.mfp and igtk == null) return self.reject(error.NoIgtk);

        // 到这里消息 3 才算数：更新重放计数，装 PTK / GTK / IGTK，回消息 4。
        self.key_replay_counter = f.replay;
        if (override) |o| self.cfg.pairwise = pairwiseCipher(o);
        self.installPtk();
        self.installGtk(g.key_id, g.tx, g.gtk, f.rsc) catch |e| return self.reject(e);
        if (igtk) |i| {
            self.installIgtk(i.key_id, i.igtk, std.mem.readInt(u48, &i.ipn, .little)) catch |e| return self.reject(e);
        }
        self.phase = .ptk_done;

        // 12.7.6.5：Key Ack = 0，Key MIC = 1，Secure = 1，Key Replay Counter = n+1，
        // Key Nonce = 0，Key Data 为空。
        const kf = wpa2.KeyFrame{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.mic | wpa2.KeyInfo.secure,
            .replay = f.replay,
        };
        return self.send(self.ptksa.kck, kf, &.{}, out);
    }

    /// 组密钥握手消息 1（12.7.7.2，印刷页 2041）。
    fn recvGroupMsg1(self: *Supplicant, eapol: []const u8, f: wpa2.KeyFrame, key_data: []const u8, out: []u8) Error!usize {
        // a) 计数必须严格大于本会话里见过的任何 EAPOL-Key 帧。先判它。
        if (!wpa2.replayAccept(self.key_replay_counter, f.replay)) return self.reject(error.BadReplay);
        if (self.phase != .ptk_done or !self.ptksa.valid) return self.reject(error.BadOrder);
        // b) MIC 用当前 PTK 的 KCK。
        const mic_ok = wpa2.verifyMicAlg(self.micAlg(), self.ptksa.kck, eapol) catch return self.reject(error.BadFrame);
        if (!mic_ok) return self.reject(error.BadMic);

        var plain_buf: [keywrap.max_plain]u8 = undefined;
        const unwrapped = kde.unwrapKeyData(self.ptksa.kek, key_data, &plain_buf) catch |e| return self.reject(e);
        var gtk: ?kde.GtkKde = null;
        var igtk: ?kde.IgtkKde = null;
        var parser = kde.Parser.init(unwrapped.plain);
        while (parser.next() catch |e| return self.reject(e)) |item| {
            switch (item) {
                .gtk => |g| gtk = g,
                .igtk => |i| igtk = i,
                else => {},
            }
        }
        const g = gtk orelse return self.reject(error.NoGtk);

        // c) 装 GTK 与 IGTK；d) 回消息 2 并推进重放计数。
        self.key_replay_counter = f.replay;
        self.installGtk(g.key_id, g.tx, g.gtk, f.rsc) catch |e| return self.reject(e);
        if (igtk) |i| {
            self.installIgtk(i.key_id, i.igtk, std.mem.readInt(u48, &i.ipn, .little)) catch |e| return self.reject(e);
        }

        // 12.7.7.3：Key Type = Group/SMK，Install = 0，Key Ack = 0，Key MIC = 1，
        // Secure = 1，Key Replay Counter 与消息 1 相同，Key Nonce = 0，Key Data 为空。
        const kf = wpa2.KeyFrame{
            .key_info = wpa2.KeyInfo.mic | wpa2.KeyInfo.secure,
            .replay = f.replay,
        };
        return self.send(self.ptksa.kck, kf, &.{}, out);
    }

    // -- 每帧保护 ----------------------------------------------------------

    /// 发送方向：用 PTK 保护一帧（非 AP STA 的 GTK 只用于接收，IBSS 的 GTKSA 不在本组件范围）。
    pub fn protect(self: *Supplicant, mpdu: []const u8, out: []u8) Error!usize {
        return self.ptksa.protect(mpdu, out);
    }

    /// 接收分发：组寻址的受保护帧走 GTK，单独寻址的走 PTK；两者都带重放检测。
    pub fn unprotect(self: *Supplicant, mpdu: []const u8, out: []u8) Error!usize {
        const h = try hdr.parse(mpdu);
        if (!h.protected) return error.NotProtected;
        const d = if (h.groupAddressed())
            try self.gtksa.unprotect(mpdu, out)
        else
            try self.ptksa.unprotect(mpdu, out);
        return d.len;
    }

    /// BIP 校验一个组寻址稳健管理帧。返回去掉 MME 的帧长。
    pub fn unprotectBip(self: *Supplicant, frame: []const u8) Error!usize {
        const v = try self.igktsa.unprotect(frame);
        return v.len;
    }

    /// 管理帧保护的本地策略（交给 `mfp.zig` 的规则用）。
    pub fn mfpPolicy(self: *const Supplicant) mfp.Policy {
        return .{
            .activated = self.cfg.mfp,
            .unprotected_allowed = false,
            .peer_mfpc = self.cfg.mfp,
            .keys_installed = self.keysInstalled(),
            .igtk_available = self.igktsa.valid,
        };
    }
};

fn pairwiseCipher(suite_type: u8) ccmp.Cipher {
    return if (suite_type == rsne.Cipher.gcmp128) .gcmp128 else .ccmp128;
}
