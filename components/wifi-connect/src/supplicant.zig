//! wifi-connect：RSNA 请求方（supplicant）——4 次握手、组密钥握手、安全关联，
//! 以及 IEEE Std 802.11-2016 12.7.10 的请求方密钥管理状态机。
//!
//! 覆盖的条款：
//!   12.7.10（印刷页 2062–2064，图 12-49）：四个状态 INITIALIZE、AUTHENTICATION、
//!     DISCONNECTED、STAKEYSTART，以及 portValid / portEnable 等变量。
//!   12.7.6（印刷页 2029–2037）：4 次握手。消息 1 没有 MIC，只用来带 ANonce 和
//!     PMKID；请求方每收到一个不陈旧的消息 1 就换一个新的 SNonce、重算 PTK、回消息 2。
//!     消息 3 要过重放计数、ANonce、MIC、RSNE 几道检查，然后才装 PTK / GTK / IGTK
//!     并回消息 4。消息 1 的内容在消息 3 证实之前不得用来更新已装的密钥。
//!   12.7.7（印刷页 2040–2042）：组密钥握手。消息 1 的重放计数必须严格大于本会话
//!     里见过的任何 EAPOL-Key 帧，MIC 用当前 PTK 的 KCK 验，通过后装 GTK（和 IGTK）。
//!   12.7.2 d)（印刷页 2022）：本地 Key Replay Counter 只在 MIC 验证通过之后才更新，
//!     所以消息 1 从不更新它——这样消息 1 重传（计数更大）之后消息 3 仍然能过。
//!   12.6.1.1.1（印刷页 1985–1986）：PTKSA 在消息 3 被请求方证实时建立；GTKSA、
//!     IGTKSA 在消息 3 或组密钥握手消息 1 到达时建立。
//!
//! 随 AKM 变的一切都从 `akm.zig` 的表里取：PTK 的派生、PMKID、EAPOL-Key 的 MIC 算法与
//! 长度、Key Data 的封装（KEK 128 或 256 位）、能接受的 Key Descriptor Version、消息 1 里
//! PMKID KDE 的处理、AKM 与密码套件能不能合用。本文件只有握手的流程与字段检查，
//! 不按 AKM 分支。Key Descriptor Version 的处理是：认证方发来的那一帧是哪一个被接受的
//! 版本（AKM 8、9 可以是 0 或 3），回应里就用那一个。
//!
//! 密钥长度的上限：PMK 48（AKM 12、13）、KCK 24、KEK 32、TK / GTK / IGTK 32（256 位套件）。
//! 安全关联里的 `kck`、`kek`、`tk`、`gtk`、`igtk` 是各自的前 128 位，长出来的那一段在
//! 同名的 `_hi` 字段里，用时拼起来。
//!
//! 明确不做：802.1X / EAP、SAE、OWE 的 DH（PMK 与它们的 PMKID 由调用方给）、FT 的帧交换
//! （PMK-R1 由调用方用 `ft.zig` 派生后给，PMKR1Name 在 RSNE 里的核对、MDE / FTE 都不在
//! 这里）、PMKSA 缓存、SMK/PeerKey、扩展 Key ID（PTK 的 Key ID 恒为 0）、超时与重传
//! （12.7.10：「本状态机不用超时与重试」，由上层负责）。
//!
//! 没有随机数源：每次接受消息 1 时需要的 SNonce 由调用方传入。没有分配器。
//! 不 import hw/log。

const std = @import("std");
const akm = @import("akm.zig");
const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const hdr = @import("hdr.zig");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const mfp = @import("mfp.zig");
const rsne = @import("rsne.zig");
const suite256 = @import("suite256.zig");
const wpa2 = @import("wpa2.zig");

pub const HandshakeError = kde.WrapError || rsne.Error || akm.Error || error{
    /// EAPOL-Key 帧太短或长度字段不符（12.7.2：字段值无效的帧应静默丢弃）。
    BadFrame,
    /// Descriptor Type 不是 RSN。
    BadDescriptor,
    /// Key Information 与消息号/方向不符，Key Length、Descriptor Version 不对；
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
    /// AKM 与成对 / 组密码套件或 group management cipher suite 不能合用（9.4.2.25.3）。
    AkmCipherMismatch,
    /// 还没有可用的 PMK：没调用 `start` / `startPmk`，或那一次被拒绝了。
    NoPmk,
    /// PMKID 要由调用方给的 AKM（SAE、FT、OWE）没有给。
    MissingPmkid,
    /// 密码套件不在本组件的范围内（TKIP、WEP、Use group cipher suite 等）。
    UnsupportedCipher,
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

/// 把密钥「前 128 位 ‖ 多出来的那一段」拼成连续的 `len` 个八位组，写进 `buf`。
fn joinKey(lo: []const u8, hi: []const u8, len: usize, buf: []u8) []const u8 {
    @memcpy(buf[0..lo.len], lo);
    @memcpy(buf[lo.len..len], hi[0 .. len - lo.len]);
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// 安全关联（12.6.1.1）
// ---------------------------------------------------------------------------

/// PTKSA（12.6.1.1.6，印刷页 1985）：PTK、成对密码套件、两端 MAC、Key ID，
/// 外加每帧保护要用的收发 PN。
///
/// KCK 可以是 128 或 192 位（表 12-8），KEK 128 或 256 位，TK 128 或 256 位（表 12-4）。
/// `kck`、`kek`、`tk` 是各自的低 128 位，`kck_hi`、`kek_hi`、`tk_hi` 是多出来的那一段；
/// KCK、KEK 的有效长度记在 `kck_len`、`kek_len`，TK 的看 `cipher`。
pub const Ptksa = struct {
    valid: bool = false,
    kck: [wpa2.kck_len]u8 = @splat(0),
    kek: [wpa2.kek_len]u8 = @splat(0),
    tk: [ccmp.tk_len]u8 = @splat(0),
    kck_hi: [akm.kck_hi_len]u8 = @splat(0),
    kek_hi: [akm.kek_hi_len]u8 = @splat(0),
    tk_hi: [akm.tk_hi_len]u8 = @splat(0),
    kck_len: u8 = wpa2.kck_len,
    kek_len: u8 = wpa2.kek_len,
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

    /// 完整的 KCK。128 位时直接指向本结构，192 位时拼进 `buf`。
    pub fn kckSlice(self: *const Ptksa, buf: *[akm.kck_max_len]u8) []const u8 {
        if (self.kck_len == wpa2.kck_len) return &self.kck;
        return joinKey(&self.kck, &self.kck_hi, self.kck_len, buf);
    }

    /// 完整的 KEK（128 或 256 位）。
    pub fn kekSlice(self: *const Ptksa, buf: *[akm.kek_max_len]u8) []const u8 {
        if (self.kek_len == wpa2.kek_len) return &self.kek;
        return joinKey(&self.kek, &self.kek_hi, self.kek_len, buf);
    }

    fn tk256(self: *const Ptksa) [ccmp.tk_len_256]u8 {
        var key: [ccmp.tk_len_256]u8 = undefined;
        @memcpy(key[0..ccmp.tk_len], &self.tk);
        @memcpy(key[ccmp.tk_len..], &self.tk_hi);
        return key;
    }

    /// 用 PTK 保护一帧（数据帧或单独寻址的稳健管理帧用同一把 TK，12.5.3.3.6）。
    /// PN 先加再用，所以第一帧是 1。
    pub fn protect(self: *Ptksa, mpdu: []const u8, out: []u8) Error!usize {
        if (!self.valid) return error.NoKey;
        if (self.tx_pn >= ccmp.pn_max) return error.BadPn;
        self.tx_pn += 1;
        const p = ccmp.Params{ .cipher = self.cipher, .pn = self.tx_pn, .key_id = self.key_id };
        if (self.cipher.keyLen() == ccmp.tk_len) return ccmp.encapsulate(p, self.tk, mpdu, out);
        return ccmp.encapsulate256(p, self.tk256(), mpdu, out);
    }

    /// 解封装一帧并做重放检测：TA 必须是这个 SA 的认证方，PN 要大于对应计数器，
    /// MIC 通过之后才推进计数器（12.5.3.4.4 a)）。
    pub fn unprotect(self: *Ptksa, mpdu: []const u8, out: []u8) Error!ccmp.Decapped {
        if (!self.valid) return error.NoKey;
        const h = try hdr.parse(mpdu);
        if (!std.mem.eql(u8, &h.a2, &self.aa)) return error.WrongPeer;
        const d = if (self.cipher.keyLen() == ccmp.tk_len)
            try ccmp.decapsulate(self.cipher, self.tk, mpdu, out, false)
        else
            try ccmp.decapsulate256(self.cipher, self.tk256(), mpdu, out, false);
        const is_mgmt = d.hdr.kind == .mgmt;
        if (!self.rx.isFresh(d.pn, is_mgmt, d.hdr.tid)) return error.Replay;
        self.rx.update(d.pn, is_mgmt, d.hdr.tid);
        return d;
    }
};

/// GTKSA（12.6.1.1.8，印刷页 1985–1986）：非 AP STA 的 GTKSA 只用于接收。
/// GTK 是 128 或 256 位（表 12-4），`gtk_hi` 是多出来的那一段。
pub const Gtksa = struct {
    valid: bool = false,
    gtk: [ccmp.tk_len]u8 = @splat(0),
    gtk_hi: [akm.tk_hi_len]u8 = @splat(0),
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

    fn gtk256(self: *const Gtksa) [ccmp.tk_len_256]u8 {
        var key: [ccmp.tk_len_256]u8 = undefined;
        @memcpy(key[0..ccmp.tk_len], &self.gtk);
        @memcpy(key[ccmp.tk_len..], &self.gtk_hi);
        return key;
    }

    pub fn unprotect(self: *Gtksa, mpdu: []const u8, out: []u8) Error!ccmp.Decapped {
        if (!self.valid) return error.NoKey;
        const d = if (self.cipher.keyLen() == ccmp.tk_len)
            try ccmp.decapsulate(self.cipher, self.gtk, mpdu, out, false)
        else
            try ccmp.decapsulate256(self.cipher, self.gtk256(), mpdu, out, false);
        // 8 字节头里的 Key ID 指明用的是哪把 GTK。
        if (d.key_id != @as(u2, @truncate(self.key_id))) return error.WrongPeer;
        if (!self.rx.isFresh(d.pn, false, d.hdr.tid)) return error.Replay;
        self.rx.update(d.pn, false, d.hdr.tid);
        return d;
    }
};

/// IGTKSA（12.6.1.1.9，印刷页 1986）：Key ID、IGTK、认证方 MAC、收发方向。
/// IGTK 的长度与算法跟 group management cipher suite 走（BIP 的四个变体，表 12-4），
/// `igtk_hi` 是 256 位变体多出来的那一段。
pub const IgtkSa = struct {
    valid: bool = false,
    igtk: [bip.igtk_len]u8 = @splat(0),
    igtk_hi: [bip.igtk_len_256 - bip.igtk_len]u8 = @splat(0),
    cipher: bip.Cipher = .bip_cmac128,
    key_id: u16 = 0,
    aa: [6]u8 = @splat(0),
    replay: bip.IgtkReplay = .{},

    pub fn reset(self: *IgtkSa) void {
        zeroise(&self.igtk);
        self.* = .{};
    }

    fn igtkSlice(self: *const IgtkSa, buf: *[bip.igtk_len_256]u8) []const u8 {
        return joinKey(&self.igtk, &self.igtk_hi, self.cipher.keyLen(), buf);
    }

    /// 校验一个组寻址稳健管理帧（12.5.4.6）：按 Key ID 找 IGTK、查 IPN 重放、验 MIC、
    /// 通过后推进重放计数。返回去掉 MME 的帧长。
    pub fn unprotect(self: *IgtkSa, frame: []const u8) Error!bip.Verified {
        if (!self.valid) return error.NoKey;
        const mmie = try bip.parseMmieOf(self.cipher, frame);
        if (mmie.key_id != self.key_id) return error.WrongPeer;
        if (!self.replay.isFresh(mmie.ipn)) return error.Replay;
        var buf: [bip.igtk_len_256]u8 = undefined;
        const v = try bip.verifyCipher(self.cipher, self.igtkSlice(&buf), frame);
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
    /// AKM suite type（表 9-133，`akm.Type` 的值）。握手里随 AKM 变的一切由 `akm.zig` 的表给出。
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
    /// 本 AKM 在表里的那一行；`pmk_set` 为假时没有意义。
    spec: akm.Spec = undefined,
    pmk: [akm.pmk_max_len]u8 = @splat(0),
    /// `start` / `startPmk` 被接受之后为真；被拒绝时为假，收到的 EAPOL-Key 一律回 `NoPmk`。
    pmk_set: bool = false,
    /// PMK 的标识符（`akm.Pmkid`）：有的 AKM 一开始就有，AKM 11、12 在消息 3 被接受时才有。
    pmkid: [akm.pmkid_len]u8 = @splat(0),
    anonce: [wpa2.nonce_len]u8 = @splat(0),
    snonce: [wpa2.nonce_len]u8 = @splat(0),
    /// 消息 1 之后算出的候选 PTK（12.7.10.3 的 TPTK），前 `tptk_len` 个八位组有效；
    /// 消息 3 证实后装进 `ptksa`。
    tptk: [akm.ptk_max_len]u8 = @splat(0),
    tptk_len: u8 = 0,
    /// 认证方最近一帧用的 Key Descriptor Version（`spec.versions` 里的一个）；回应照抄。
    peer_version: u8 = 0,
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

    /// 候选 PTK 的前 48 个八位组（KCK ‖ KEK ‖ TK，128 位套件下就是整把 PTK）。
    /// 更长的 PTK（AKM 12、13，或 256 位套件）用 `candidatePtkSlice()`。
    pub fn candidatePtk(self: *const Supplicant) [wpa2.ptk_ccmp_len]u8 {
        return self.tptk[0..wpa2.ptk_ccmp_len].*;
    }

    /// 候选 PTK 全文，长度是 KCK_bits + KEK_bits + TK_bits / 8。
    pub fn candidatePtkSlice(self: *const Supplicant) []const u8 {
        return self.tptk[0..self.tptk_len];
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
        self.tptk_len = 0;
        zeroise(&self.snonce);
        self.port_enabled = false;
        self.port_valid = false;
        self.phase = .idle;
        self.state = .initialization;
    }

    /// 上电初始化或收到 Deauthentication / Disassociation：进 INITIALIZE，记下 32 八位组的
    /// PMK。PMKID 按 AKM 自己算得出的 AKM（1、2、5、6）走这里；别的 AKM 用 `startPmk`。
    /// 被拒绝时什么都不装，之后收到的 EAPOL-Key 回 `NoPmk`（原因记在 `last_error`）。
    pub fn start(self: *Supplicant, pmk: [wpa2.pmk_len]u8) void {
        self.startPmk(&pmk, null) catch {};
    }

    /// 上电初始化或收到 Deauthentication / Disassociation：进 INITIALIZE，记下 PMK 与它的标识符，
    /// 然后进 INITIALIZE。`pmk` 的长度必须是本 AKM 的那一个（`akm.Spec.pmk_len`）。
    ///
    /// `pmkid` 是标识符不由握手自己算的 AKM 要的：SAE（AKM 8，12.4.5.4）、FT（AKM 3、4、9、13，
    /// PMKR1Name）、OWE（AKM 18）；别的 AKM 忽略它。AKM 11、12 的 PMKID 以 KCK 为密钥，消息 3
    /// 被接受时才填进 `pmkid`。
    ///
    /// 拒绝的四种情况：AKM 不在表里（`UnsupportedAkm`）、PMK 长度不符（`BadPmkLength`）、
    /// AKM 与成对 / 组密码套件（协商了管理帧保护时还有 group management cipher suite）不能合用
    /// （`AkmCipherMismatch`，9.4.2.25.3）、该给的标识符没给（`MissingPmkid`）。
    pub fn startPmk(self: *Supplicant, pmk: []const u8, pmkid: ?[akm.pmkid_len]u8) HandshakeError!void {
        self.installPmk(pmk, pmkid) catch |e| {
            // 既有的入口 `start` 报不了错：原因留在 `last_error` 里给日志用。
            self.last_error = e;
            return e;
        };
    }

    fn installPmk(self: *Supplicant, pmk: []const u8, pmkid: ?[akm.pmkid_len]u8) HandshakeError!void {
        self.enterInitialize();
        self.pmk_set = false;
        zeroise(&self.pmk);
        zeroise(&self.pmkid);
        self.key_replay_counter = 0;
        const s = try akm.spec(self.cfg.akm);
        if (pmk.len != s.pmk_len) return error.BadPmkLength;
        if (!akm.cipherAllowed(self.cfg.akm, akm.cipherType(self.cfg.pairwise)) or
            !akm.cipherAllowed(self.cfg.akm, akm.cipherType(self.cfg.group))) return error.AkmCipherMismatch;
        if (self.cfg.mfp and !akm.cipherAllowed(self.cfg.akm, (try self.gmcs()).suiteType())) return error.AkmCipherMismatch;
        switch (s.pmkid) {
            .hmac_pmk => self.pmkid = try akm.pmkid(self.cfg.akm, pmk, self.cfg.aa, self.cfg.spa),
            .hmac_kck => {}, // 消息 3 被接受时才填
            .given => self.pmkid = pmkid orelse return error.MissingPmkid,
        }
        @memcpy(self.pmk[0..pmk.len], pmk);
        self.spec = s;
        self.pmk_set = true;
    }

    /// 协商的 group management cipher suite：AP 在 Beacon / Probe Response 的 RSNE 里通告的
    /// 那一个（字段缺席时按默认 BIP-CMAC-128）。不是 BIP 的四个变体之一时回 `UnsupportedCipher`。
    fn gmcs(self: *const Supplicant) HandshakeError!bip.Cipher {
        const r = rsne.parse(self.cfg.ap_rsne) catch return error.RsneMismatch;
        return bip.Cipher.fromSuiteType(r.gmcs) orelse error.UnsupportedCipher;
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

    // -- 候选 PTK 的三段（12.7.1.3：KCK = L(PTK, 0, KCK_bits)，KEK、TK 依次往后） --

    fn kck(self: *const Supplicant) []const u8 {
        return self.tptk[0..self.spec.kckLen()];
    }

    fn kek(self: *const Supplicant) []const u8 {
        return self.tptk[self.spec.kckLen()..][0..self.spec.kek_len];
    }

    fn installPtk(self: *Supplicant) void {
        const k = self.kck();
        const e = self.kek();
        self.ptksa.reset();
        self.ptksa = .{
            .valid = true,
            .kck_len = @intCast(k.len),
            .kek_len = @intCast(e.len),
            .cipher = self.cfg.pairwise,
            .key_id = 0,
            .spa = self.cfg.spa,
            .aa = self.cfg.aa,
        };
        @memcpy(self.ptksa.kck[0..wpa2.kck_len], k[0..wpa2.kck_len]);
        @memcpy(self.ptksa.kck_hi[0 .. k.len - wpa2.kck_len], k[wpa2.kck_len..]);
        @memcpy(self.ptksa.kek[0..wpa2.kek_len], e[0..wpa2.kek_len]);
        @memcpy(self.ptksa.kek_hi[0 .. e.len - wpa2.kek_len], e[wpa2.kek_len..]);
        const tk = self.tptk[k.len + e.len .. self.tptk_len];
        const tk_len = self.cfg.pairwise.keyLen();
        @memcpy(self.ptksa.tk[0..ccmp.tk_len], tk[0..ccmp.tk_len]);
        @memcpy(self.ptksa.tk_hi[0 .. tk_len - ccmp.tk_len], tk[ccmp.tk_len..tk_len]);
        self.port_valid = true;
    }

    /// GTK 的长度必须等于组密码套件的（表 12-4）。调用点在动任何状态之前先核对它。
    fn checkGtk(self: *const Supplicant, gtk: []const u8) Error!void {
        if (gtk.len != self.cfg.group.keyLen()) return error.BadKeyLength;
    }

    /// IGTK 的长度必须等于 group management cipher suite 的（表 12-4）；返回那个套件。
    fn igtkCipher(self: *const Supplicant, igtk: []const u8) Error!bip.Cipher {
        const cipher = try self.gmcs();
        if (igtk.len != cipher.keyLen()) return error.BadKeyLength;
        return cipher;
    }

    /// 装 GTK。长度已由 `checkGtk` 核对，所以这里不会再失败。
    fn installGtk(self: *Supplicant, key_id: u8, tx: bool, gtk: []const u8, rsc: u64) void {
        const len = self.cfg.group.keyLen();
        self.gtksa.reset();
        self.gtksa = .{
            .valid = true,
            .key_id = key_id & 0x03,
            .cipher = self.cfg.group,
            .tx = tx,
            .rsc = rsc,
        };
        @memcpy(self.gtksa.gtk[0..ccmp.tk_len], gtk[0..ccmp.tk_len]);
        @memcpy(self.gtksa.gtk_hi[0 .. len - ccmp.tk_len], gtk[ccmp.tk_len..len]);
        // Key RSC 是认证方给 GTK 用的起始 PN（12.7.6.4），接收重放计数以它同步。
        self.gtksa.rx.reset(rsc);
    }

    /// 装 IGTK：套件由 `igtkCipher` 定，长度由它核对，所以这里不会再失败。
    fn installIgtk(self: *Supplicant, key_id: u16, igtk: []const u8, ipn: u64, cipher: bip.Cipher) void {
        const len = cipher.keyLen();
        self.igktsa.reset();
        self.igktsa = .{ .valid = true, .cipher = cipher, .key_id = key_id, .aa = self.cfg.aa };
        @memcpy(self.igktsa.igtk[0..bip.igtk_len], igtk[0..bip.igtk_len]);
        @memcpy(self.igktsa.igtk_hi[0 .. len - bip.igtk_len], igtk[bip.igtk_len..len]);
        // 12.5.4.4：接收重放计数置成 IGTK KDE 里的 IPN。
        self.igktsa.replay.reset(ipn);
    }

    // -- EAPOL-Key 收发 ----------------------------------------------------

    /// 编一帧回应：Key Descriptor Version 用认证方那一帧的（AKM 8、9 可能是 0 或 3），
    /// MIC 字段按本 AKM 的长度、算法来填（表 12-8）。
    fn send(self: *Supplicant, confirm_key: []const u8, kf: wpa2.KeyFrame, key_data: []const u8, out: []u8) Error!usize {
        var f = kf;
        f.version = wpa2.eapol_protocol_version;
        f.mic_len = @intCast(self.spec.mic.micLen());
        f.key_info = (f.key_info & ~wpa2.KeyInfo.version_mask) | self.peer_version;
        @memset(&f.mic, 0);
        const n = wpa2.encode(f, key_data, out) catch return self.reject(error.BadFrame);
        const mic = suite256.computeMic(self.spec.mic, confirm_key, out[0..n]) catch return self.reject(error.BadFrame);
        @memcpy(out[wpa2.mic_offset..][0..mic.len], mic.bytes[0..mic.len]);
        return n;
    }

    /// 处理一帧来自认证方的 EAPOL-Key（整帧，含 EAPOL 头）。`snonce` 是为这次
    /// 握手新画的 SNonce，只在帧是消息 1 时用到。需要回应时把回应帧写进 `out`
    /// （至少 `wpa2.keyBodyFixedLen(mic_len) + key_data.len` 字节）并返回长度。
    ///
    /// 标准里的「静默丢弃」在这里是返回一个具体的错误值，调用方记日志后丢掉即可。
    pub fn recvEapol(self: *Supplicant, eapol: []const u8, snonce: [wpa2.nonce_len]u8, out: []u8) Error!usize {
        if (self.state != .stakey_start) return self.reject(error.NotStarted);
        if (!self.pmk_set) return self.reject(error.NoPmk);
        // Key MIC 字段的长度随 AKM（12.7.2 h)），帧里不带，按表给。
        const dec = wpa2.decodeMic(eapol, self.spec.mic.micLen()) catch |e| return self.reject(if (e == error.BadDescriptor) error.BadDescriptor else error.BadFrame);
        const f = dec.frame;
        const info = f.key_info;

        // 认证方不会置 Request 位（12.7.2 b) 9)）；SMK 握手不在本组件范围；
        // Error 位由请求方置（b) 8)）；Key Descriptor Version 必须是本 AKM 接受的那几个之一（b) 1)）。
        const version: u8 = @truncate(info & wpa2.KeyInfo.version_mask);
        if ((info & wpa2.KeyInfo.request) != 0 or
            (info & wpa2.KeyInfo.smk_message) != 0 or
            (info & wpa2.KeyInfo.err) != 0 or
            !self.spec.acceptsVersion(version))
        {
            return self.reject(error.BadKeyInfo);
        }
        // 回应里用同一个版本。
        self.peer_version = version;
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
            if (secure or encr or (info & wpa2.KeyInfo.install) != 0 or
                f.key_len != self.cfg.pairwise.keyLen()) return self.reject(error.BadKeyInfo);
            return self.recvMsg1(f, dec.key_data, snonce, out);
        }

        // 12.7.6.4：Install = 0/1，Key Ack = 1，Key MIC = 1，Secure = 1，Encrypted Key Data = 1。
        // Key Length 要等消息里的 RSNE 看完再核：第二个 RSNE 可能改写成对密码套件，TK 长度随之变。
        if (!secure or !encr) return self.reject(error.BadKeyInfo);
        return self.recvMsg3(eapol, f, dec.key_data, out);
    }

    /// 4 次握手消息 1（12.7.6.2，印刷页 2030）。计数「以前用过」（不大于已被 MIC 证实
    /// 的值）就丢；否则换新的 SNonce、重算 PTK、回消息 2。消息 1 重传也走这里。
    fn recvMsg1(self: *Supplicant, f: wpa2.KeyFrame, key_data: []const u8, snonce: [wpa2.nonce_len]u8, out: []u8) Error!usize {
        if (!wpa2.replayAccept(self.key_replay_counter, f.replay)) return self.reject(error.BadReplay);
        if (std.mem.allEqual(u8, &f.nonce, 0)) return self.reject(error.BadNonce);

        // Key Data 里可以有 PMKID（不加密）。握手一开始就有标识符的 AKM 带了必须相等，对不上说明认证方
        // 用的是另一个 PMKSA；标识符要等 PTK（AKM 11、12）或另有来处（FT）的 AKM 不看它（`akm.Msg1Pmkid`）。
        if (self.spec.msg1_pmkid == .checked and key_data.len > 0) {
            var parser = kde.Parser.init(key_data);
            while (parser.next() catch |e| return self.reject(e)) |item| {
                switch (item) {
                    .pmkid => |p| if (!std.mem.eql(u8, &p, &self.pmkid)) return self.reject(error.PmkidMismatch),
                    else => {},
                }
            }
        }

        self.anonce = f.nonce;
        self.snonce = snonce;
        const n = akm.derivePtk(self.cfg.akm, self.pmk[0..self.spec.pmk_len], self.cfg.aa, self.cfg.spa, self.anonce, self.snonce, self.cfg.pairwise.keyLen(), &self.tptk) catch |e| return self.reject(e);
        self.tptk_len = @intCast(n);
        self.pending_replay = f.replay;
        self.phase = .ptk_started;

        // 12.7.6.3：Key Type = Pairwise，Install = 0，Key Ack = 0，Key MIC = 1，Secure = 0，
        // Key Length = 0，Key Replay Counter = n，Key Nonce = SNonce，Key Data = 本 STA 的 RSNE。
        const kf = wpa2.KeyFrame{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.mic,
            .replay = f.replay,
            .nonce = self.snonce,
        };
        return self.send(self.kck(), kf, self.cfg.sta_rsne, out);
    }

    /// 消息 3 的 RSNE 校验（12.7.6.4 a)、12.7.2，印刷页 2025–2026）：第一个 RSNE
    /// 必须与 Beacon / Probe Response 里的逐字节相同；第二个 RSNE 可选，用来改写
    /// 成对密码套件——它只写一个套件、必须是认证方通告过的、其余字段与第一个相同，
    /// 而且本组件得支持它、能与本 AKM 合用、本 AKM 下改得动（见 `applyPairwiseOverride`）。
    /// 返回改写后的成对密码套件；没有第二个 RSNE 时返回 null（沿用已选的）。
    fn verifyRsnes(self: *Supplicant, first: []const u8, second: ?[]const u8) Error!?ccmp.Cipher {
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
        // 12.6.3：消息 3 带了第二个 RSNE 时，安全关联用的就是它写的成对套件——用不了就去认证。
        const cipher = akm.cipherOf(override) orelse return error.UnsupportedCipher;
        if (!akm.cipherAllowed(self.cfg.akm, override)) return error.AkmCipherMismatch;
        // TK 长度变了的改写要把 PTK 按新长度重新派生，而 12.7.1.7.2 的 KDF 把 Length 算进每一块：
        // 换一个长度得到的是另一把 PTK，与已验过 MIC 的那一把对不上。只有 12.7.1.2 的 PRF 做得到。
        if (cipher.keyLen() != self.cfg.pairwise.keyLen() and
            !std.meta.eql(self.spec.ptk, .{ .pairwise = .sha1 })) return error.UnsupportedCipher;
        return cipher;
    }

    /// 4 次握手消息 3（12.7.6.4，印刷页 2034–2035）。
    fn recvMsg3(self: *Supplicant, eapol: []const u8, f: wpa2.KeyFrame, key_data: []const u8, out: []u8) Error!usize {
        // 计数用过：丢弃。先判它，重放的消息 3 无论握手走到哪一步都报重放。
        if (!wpa2.replayAccept(self.key_replay_counter, f.replay)) return self.reject(error.BadReplay);
        if (self.phase != .ptk_started) return self.reject(error.BadOrder);
        // ANonce 与消息 1 不同：丢弃。
        if (!std.mem.eql(u8, &f.nonce, &self.anonce)) return self.reject(error.NonceMismatch);
        const mic_ok = suite256.verifyMic(self.spec.mic, self.kck(), eapol) catch return self.reject(error.BadFrame);
        if (!mic_ok) return self.reject(error.BadMic);

        // Key Data 是加密的：RSNE(1 或 2 个) ‖ GTK KDE ‖ (IGTK KDE)，用候选 PTK 的 KEK 解开。
        var plain_buf: [keywrap.max_plain]u8 = undefined;
        const unwrapped = kde.unwrapKeyDataKek(self.kek(), key_data, &plain_buf) catch |e| return self.reject(e);
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
        // Key Length = 成对密码套件的 TK 长度（表 12-4）；套件以消息 3 的第二个 RSNE 为准。
        const pairwise = override orelse self.cfg.pairwise;
        if (f.key_len != pairwise.keyLen()) return self.reject(error.BadKeyInfo);
        const g = gtk orelse return self.reject(error.NoGtk);
        if (self.cfg.mfp and igtk == null) return self.reject(error.NoIgtk);
        // 长度先全部核对，再动任何状态：装到一半才失败，会留下「PTK 装了、GTK 没装、重放计数
        // 已前进」的残局，重传的消息 3 又因为计数不新鲜被丢。GTK、IGTK 的长度随各自的套件（表 12-4）。
        self.checkGtk(g.gtk) catch |e| return self.reject(e);
        const igtk_cipher: ?bip.Cipher = if (igtk) |i|
            (self.igtkCipher(i.igtk) catch |e| return self.reject(e))
        else
            null;

        // 到这里消息 3 才算数：换成第二个 RSNE 的成对套件，更新重放计数，装 PTK / GTK / IGTK，回消息 4。
        if (override) |o| self.applyPairwiseOverride(o);
        self.key_replay_counter = f.replay;
        self.installPtk();
        // AKM 11、12 的 PMKID 以 KCK 为密钥：现在 PTK 定下来了，才算得出。
        switch (self.spec.pmkid) {
            .hmac_kck => {
                var kbuf: [akm.kck_max_len]u8 = undefined;
                self.pmkid = akm.pmkid(self.cfg.akm, self.ptksa.kckSlice(&kbuf), self.cfg.aa, self.cfg.spa) catch |e| return self.reject(e);
            },
            else => {},
        }
        self.installGtk(g.key_id, g.tx, g.gtk, f.rsc);
        if (igtk) |i| self.installIgtk(i.key_id, i.igtk, std.mem.readInt(u48, &i.ipn, .little), igtk_cipher.?);
        self.phase = .ptk_done;

        // 12.7.6.5：Key Ack = 0，Key MIC = 1，Secure = 1，Key Replay Counter = n+1，
        // Key Nonce = 0，Key Data 为空。
        const kf = wpa2.KeyFrame{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.mic | wpa2.KeyInfo.secure,
            .replay = f.replay,
        };
        var kbuf: [akm.kck_max_len]u8 = undefined;
        return self.send(self.ptksa.kckSlice(&kbuf), kf, &.{}, out);
    }

    /// 消息 3 的第二个 RSNE 改写了成对密码套件（12.6.3）。能不能改写由 `verifyRsnes` 判定；
    /// TK 长度随之变了的时候，PTK 按新的 TK 长度重新派生。只有 12.7.1.2 的 PRF 的输出是
    /// 前缀稳定的（每块只由循环计数决定）：KCK、KEK 与已经验过 MIC 的那一把完全相同，只是 TK
    /// 多出后面那一段。12.7.1.7.2 的 KDF 把 Length 算进每一块（i ‖ Label ‖ Context ‖ Length），
    /// 换一个长度就是另一把毫不相干的 PTK，所以那几种 AKM 下改不了 TK 长度。
    fn applyPairwiseOverride(self: *Supplicant, cipher: ccmp.Cipher) void {
        const same_len = cipher.keyLen() == self.cfg.pairwise.keyLen();
        self.cfg.pairwise = cipher;
        if (same_len) return;
        // PMK 的长度在 `startPmk` 时核过，这里不会再失败。
        self.tptk_len = @intCast(akm.derivePtk(self.cfg.akm, self.pmk[0..self.spec.pmk_len], self.cfg.aa, self.cfg.spa, self.anonce, self.snonce, cipher.keyLen(), &self.tptk) catch unreachable);
    }

    /// 组密钥握手消息 1（12.7.7.2，印刷页 2041）。
    fn recvGroupMsg1(self: *Supplicant, eapol: []const u8, f: wpa2.KeyFrame, key_data: []const u8, out: []u8) Error!usize {
        // a) 计数必须严格大于本会话里见过的任何 EAPOL-Key 帧。先判它。
        if (!wpa2.replayAccept(self.key_replay_counter, f.replay)) return self.reject(error.BadReplay);
        if (self.phase != .ptk_done or !self.ptksa.valid) return self.reject(error.BadOrder);
        var kbuf: [akm.kck_max_len]u8 = undefined;
        var ebuf: [akm.kek_max_len]u8 = undefined;
        // b) MIC 用当前 PTK 的 KCK。
        const mic_ok = suite256.verifyMic(self.spec.mic, self.ptksa.kckSlice(&kbuf), eapol) catch return self.reject(error.BadFrame);
        if (!mic_ok) return self.reject(error.BadMic);

        var plain_buf: [keywrap.max_plain]u8 = undefined;
        const unwrapped = kde.unwrapKeyDataKek(self.ptksa.kekSlice(&ebuf), key_data, &plain_buf) catch |e| return self.reject(e);
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
        // 长度先核对（表 12-4），再动状态，理由同消息 3。
        self.checkGtk(g.gtk) catch |e| return self.reject(e);
        const igtk_cipher: ?bip.Cipher = if (igtk) |i|
            (self.igtkCipher(i.igtk) catch |e| return self.reject(e))
        else
            null;

        // c) 装 GTK 与 IGTK；d) 回消息 2 并推进重放计数。
        self.key_replay_counter = f.replay;
        self.installGtk(g.key_id, g.tx, g.gtk, f.rsc);
        if (igtk) |i| self.installIgtk(i.key_id, i.igtk, std.mem.readInt(u48, &i.ipn, .little), igtk_cipher.?);

        // 12.7.7.3：Key Type = Group/SMK，Install = 0，Key Ack = 0，Key MIC = 1，
        // Secure = 1，Key Replay Counter 与消息 1 相同，Key Nonce = 0，Key Data 为空。
        const kf = wpa2.KeyFrame{
            .key_info = wpa2.KeyInfo.mic | wpa2.KeyInfo.secure,
            .replay = f.replay,
        };
        return self.send(self.ptksa.kckSlice(&kbuf), kf, &.{}, out);
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
