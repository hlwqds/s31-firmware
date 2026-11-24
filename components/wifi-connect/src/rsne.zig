//! wifi-connect：RSNE 与 RSNA 策略选择（IEEE Std 802.11-2016 9.4.2.25、12.6.2、12.6.3）。
//!
//! RSNE（图 9-255，印刷页 882）：
//!   Element ID(48) | Length | Version | Group Data Cipher Suite | Pairwise Cipher
//!   Suite Count + List | AKM Suite Count + List | RSN Capabilities | PMKID Count +
//!   List | Group Management Cipher Suite
//! Version 之后全是可选字段；某个非零长度字段缺席时，它后面的字段也都不出现。
//! Version 1 之后的所有数值字段按 9.2.2 小端；套件选择器 = OUI(3) + Suite Type(1)。
//!
//! 策略选择（12.6.3，印刷页 1991–1992）：发起关联的 STA 在 (Re)Association
//! Request 里放一个 RSNE，其中「一个认证与成对密码套件取自 AP 通告的集合」，
//! 「组密码套件用 AP 通告的那个」；只要有一项没有交集就不跟这个 AP 关联。
//! 管理帧保护用表 12-2（印刷页 1992）按双方 RSNE 里的 MFPC / MFPR 决定，
//! 协商结果是「双方的 MFPC 都为 1」，并在 4 次握手里用双方 RSNE 再确认一次。
//!
//! RSNE 的完整编解码与信息元素扫描属于 `wifi-mlme`；这里只解析策略选择与
//! 握手校验（消息 3 的 RSNE 必须与 Beacon / Probe Response 里的一致）要用的字段。
//! 不认识的套件选择器按 12.6.2「STA 应忽略」处理：保留在列表里、不参与匹配。
//! 不用分配器；不 import hw/log。

const std = @import("std");

const akm = @import("akm.zig");

pub const element_id: u8 = 48;
pub const oui = [3]u8{ 0x00, 0x0f, 0xac };
pub const version: u16 = 1;
/// 非 00-0F-AC 的套件选择器：本组件不认识。
pub const unknown: u8 = 0xff;

pub const max_pairwise = 8;
pub const max_akm = 8;
pub const max_pmkid = 4;
pub const pmkid_len = 16;
/// 所有字段都出现、列表都满时的 RSNE 长度。
pub const max_len = 2 + 2 + 4 + (2 + 4 * max_pairwise) + (2 + 4 * max_akm) + 2 + (2 + pmkid_len * max_pmkid) + 4;

/// 表 9-131（印刷页 884–885）的 cipher suite type。
///
/// 用途见表 9-132（印刷页 886）：CCMP 与 GCMP 的四个选择器既作 GTK 也作 PTK；BIP 的
/// 四个只能作 IGTK，即 RSNE 的 Group Management Cipher Suite。Key length 见表 12-4
/// （印刷页 2021）：CCMP-128、GCMP-128、BIP-CMAC-128、BIP-GMAC-128 是 16 字节，
/// GCMP-256、CCMP-256、BIP-GMAC-256、BIP-CMAC-256 是 32 字节。
/// AKM 00-0F-AC:11 只与 GCMP-128、BIP-GMAC-128 搭配；00-0F-AC:12、13 只与 GCMP-256、
/// CCMP-256、BIP-CMAC-256、BIP-GMAC-256 搭配（9.4.2.25.3，印刷页 888）。
pub const Cipher = struct {
    pub const use_group: u8 = 0;
    pub const wep40: u8 = 1;
    pub const tkip: u8 = 2;
    pub const ccmp128: u8 = 4;
    pub const wep104: u8 = 5;
    /// Group Management Cipher Suite 字段缺席时的默认值（印刷页 885）。
    pub const bip_cmac128: u8 = 6;
    pub const no_group: u8 = 7;
    pub const gcmp128: u8 = 8;
    pub const gcmp256: u8 = 9;
    pub const ccmp256: u8 = 10;
    pub const bip_gmac128: u8 = 11;
    pub const bip_gmac256: u8 = 12;
    pub const bip_cmac256: u8 = 13;
};

/// 表 9-133（印刷页 886–888）的 AKM suite type 里，既有调用方按名字引用的三个。数值只在
/// `akm.zig` 的 `Type` 里定义一次：每个 AKM 的握手算法、能不能与某个密码套件合用，都在那张表里。
pub const Akm = struct {
    pub const ieee8021x: u8 = @backingInt(akm.Type.ieee8021x);
    pub const psk: u8 = @backingInt(akm.Type.psk);
    pub const sae: u8 = @backingInt(akm.Type.sae);
};

/// 图 9-257（印刷页 888）：RSN Capabilities 的两个管理帧保护位。
pub const caps_mfpr: u16 = 0x0040; // B6
pub const caps_mfpc: u16 = 0x0080; // B7

pub const Error = error{
    /// 元素 ID 不是 48。
    NotRsne,
    /// 元素体比字段需要的短，或末尾多出字节。
    Truncated,
    BadVersion,
    /// Pairwise / AKM Suite Count 为 0（9.4.2.25.2、9.4.2.25.3：0 保留）。
    BadCount,
    BufferTooSmall,
    /// 编码结果超过单个元素的 255 字节上限。
    TooLong,
};

pub const Rsne = struct {
    /// Group Data Cipher Suite。字段缺席时默认 CCMP-128（9.4.2.25.2，印刷页 885）。
    group: u8 = Cipher.ccmp128,
    /// Pairwise Cipher Suite List；`pairwise_len == 0` 表示字段缺席（默认 CCMP-128）。
    pairwise: [max_pairwise]u8 = @splat(unknown),
    pairwise_len: u8 = 0,
    akm: [max_akm]u8 = @splat(unknown),
    akm_len: u8 = 0,
    caps: u16 = 0,
    caps_present: bool = false,
    /// PMKID Count 字段是否出现（出现了也可以是 0 个 PMKID）。
    pmkid_present: bool = false,
    pmkid: [max_pmkid][pmkid_len]u8 = @splat(@splat(0)),
    pmkid_len: u8 = 0,
    /// Group Management Cipher Suite。缺席时默认 BIP-CMAC-128（印刷页 885）。
    gmcs: u8 = Cipher.bip_cmac128,
    gmcs_present: bool = false,

    /// Management Frame Protection Capable（RSN Capabilities B7）。
    pub fn mfpc(self: Rsne) bool {
        return (self.caps & caps_mfpc) != 0;
    }

    /// Management Frame Protection Required（RSN Capabilities B6）。
    pub fn mfpr(self: Rsne) bool {
        return (self.caps & caps_mfpr) != 0;
    }
};

fn selectorType(sel: *const [4]u8) u8 {
    return if (std.mem.eql(u8, sel[0..3], &oui)) sel[3] else unknown;
}

fn putSelector(out: []u8, suite_type: u8) void {
    @memcpy(out[0..3], &oui);
    out[3] = suite_type;
}

/// 解析一个完整的 RSNE（含 Element ID 与 Length）。`buf` 可以比元素长。
pub fn parse(buf: []const u8) Error!Rsne {
    if (buf.len < 2) return error.Truncated;
    if (buf[0] != element_id) return error.NotRsne;
    const len: usize = buf[1];
    if (buf.len < 2 + len or len < 2) return error.Truncated;
    const body = buf[2..][0..len];
    if (std.mem.readInt(u16, body[0..2], .little) != version) return error.BadVersion;

    var r = Rsne{};
    var pos: usize = 2;

    // 每个字段：剩余长度不够一个完整字段就当它缺席；但差 1–3 字节说明帧被截断。
    if (pos == body.len) return r;
    if (body.len - pos < 4) return error.Truncated;
    r.group = selectorType(body[pos..][0..4]);
    pos += 4;
    if (pos == body.len) return r;

    if (body.len - pos < 2) return error.Truncated;
    const pc: usize = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;
    if (pc == 0 or pc > 63) return error.BadCount;
    if (body.len - pos < 4 * pc) return error.Truncated;
    r.pairwise_len = @intCast(@min(pc, max_pairwise));
    for (0..pc) |i| {
        if (i < max_pairwise) r.pairwise[i] = selectorType(body[pos..][0..4]);
        pos += 4;
    }
    if (pos == body.len) return r;

    if (body.len - pos < 2) return error.Truncated;
    const ac: usize = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;
    if (ac == 0 or ac > 63) return error.BadCount;
    if (body.len - pos < 4 * ac) return error.Truncated;
    r.akm_len = @intCast(@min(ac, max_akm));
    for (0..ac) |i| {
        if (i < max_akm) r.akm[i] = selectorType(body[pos..][0..4]);
        pos += 4;
    }
    if (pos == body.len) return r;

    if (body.len - pos < 2) return error.Truncated;
    r.caps = std.mem.readInt(u16, body[pos..][0..2], .little);
    r.caps_present = true;
    pos += 2;
    if (pos == body.len) return r;

    if (body.len - pos < 2) return error.Truncated;
    const kc: usize = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;
    r.pmkid_present = true;
    if (body.len - pos < pmkid_len * kc) return error.Truncated;
    r.pmkid_len = @intCast(@min(kc, max_pmkid));
    for (0..kc) |i| {
        if (i < max_pmkid) r.pmkid[i] = body[pos..][0..pmkid_len].*;
        pos += pmkid_len;
    }
    if (pos == body.len) return r;

    if (body.len - pos < 4) return error.Truncated;
    r.gmcs = selectorType(body[pos..][0..4]);
    r.gmcs_present = true;
    pos += 4;
    if (pos != body.len) return error.Truncated;
    return r;
}

/// 编码整个元素。只写 `*_len > 0` 的列表与 `*_present` 的字段。
pub fn encode(self: Rsne, out: []u8) Error!usize {
    // Element ID + Length + Version + Group Data Cipher Suite。
    var need: usize = 8;
    if (self.pairwise_len > 0) need += 2 + 4 * @as(usize, self.pairwise_len);
    if (self.akm_len > 0) need += 2 + 4 * @as(usize, self.akm_len);
    if (self.caps_present) need += 2;
    if (self.pmkid_present) need += 2 + pmkid_len * @as(usize, self.pmkid_len);
    if (self.gmcs_present) need += 4;
    if (need - 2 > 255) return error.TooLong;
    if (out.len < need) return error.BufferTooSmall;

    out[0] = element_id;
    out[1] = @intCast(need - 2);
    var pos: usize = 2;
    std.mem.writeInt(u16, out[pos..][0..2], version, .little);
    pos += 2;
    putSelector(out[pos..][0..4], self.group);
    pos += 4;
    if (self.pairwise_len > 0) {
        std.mem.writeInt(u16, out[pos..][0..2], self.pairwise_len, .little);
        pos += 2;
        for (self.pairwise[0..self.pairwise_len]) |c| {
            putSelector(out[pos..][0..4], c);
            pos += 4;
        }
    }
    if (self.akm_len > 0) {
        std.mem.writeInt(u16, out[pos..][0..2], self.akm_len, .little);
        pos += 2;
        for (self.akm[0..self.akm_len]) |a| {
            putSelector(out[pos..][0..4], a);
            pos += 4;
        }
    }
    if (self.caps_present) {
        std.mem.writeInt(u16, out[pos..][0..2], self.caps, .little);
        pos += 2;
    }
    if (self.pmkid_present) {
        std.mem.writeInt(u16, out[pos..][0..2], self.pmkid_len, .little);
        pos += 2;
        for (self.pmkid[0..self.pmkid_len]) |*p| {
            @memcpy(out[pos..][0..pmkid_len], p);
            pos += pmkid_len;
        }
    }
    if (self.gmcs_present) {
        putSelector(out[pos..][0..4], self.gmcs);
        pos += 4;
    }
    return pos;
}

// ---------------------------------------------------------------------------
// 策略选择（12.6.2、12.6.3）
// ---------------------------------------------------------------------------

const default_ciphers = [max_pairwise]u8{ Cipher.ccmp128, Cipher.gcmp128, unknown, unknown, unknown, unknown, unknown, unknown };
const default_akms = [max_akm]u8{ Akm.psk, Akm.sae, unknown, unknown, unknown, unknown, unknown, unknown };

/// 本 STA 的能力与策略。列表按本 STA 的偏好排列。
pub const OwnPolicy = struct {
    pairwise: [max_pairwise]u8 = default_ciphers,
    pairwise_len: u8 = 2,
    group: [max_pairwise]u8 = default_ciphers,
    group_len: u8 = 2,
    akm: [max_akm]u8 = default_akms,
    akm_len: u8 = 2,
    /// 管理帧保护启用时能提供的 group management cipher suite。
    gmcs: u8 = Cipher.bip_cmac128,
    /// dot11RSNAProtectedManagementFramesActivated
    mfpc: bool = false,
    /// activated 为真且 dot11RSNAUnprotectedManagementFramesAllowed 为假
    mfpr: bool = false,
};

pub const SelError = error{
    GroupNotSupported,
    NoPairwiseOverlap,
    NoAkmOverlap,
    /// 成对、组密码套件或 group management cipher suite 不能与任何一个双方都支持的 AKM 合用
    /// （9.4.2.25.3，印刷页 888：AKM 11 只配 GCMP-128、BIP-GMAC-128，AKM 12、13 只配 256 位的那四个）。
    AkmCipherMismatch,
    /// 表 12-2 的 STA action 是「shall not (try to) associate」。
    MfpPolicyViolation,
    /// 管理帧保护已协商，但 AP 的 group management cipher suite 本 STA 不支持。
    GroupMgmtNotSupported,
};

pub const Selection = struct {
    pairwise: u8,
    group: u8,
    akm: u8,
    /// 双方 MFPC 都为 1：管理帧保护已协商（12.6.3，印刷页 1992）。
    mfp_negotiated: bool,
};

pub const StaMfpAction = enum { may_associate, do_not_associate };

/// 表 12-2（印刷页 1992）Robust management frame selection 的 STA action 列。
/// 八行依次是（AP MFPC, AP MFPR, STA MFPC, STA MFPR）：
///   (0,0,0,0) (1,0,0,0) (1,0 或 1,1,0 或 1) (0,0,1,0)            → 可关联
///   (1,1,0,0)                                              → 不得关联
///   (0,0,1,1) (1,0 或 1,0,1)                               → 不得尝试关联
///   (0,1,1,0 或 1)                                         → AP 的设置无效，不得尝试关联
/// 归纳：任何一方「不支持却要求」（MFPC = 0 且 MFPR = 1）即无效；一方要求而另一方
/// 不支持也不行；其余可关联。
pub fn staMfpAction(ap_mfpc: bool, ap_mfpr: bool, sta_mfpc: bool, sta_mfpr: bool) StaMfpAction {
    if (ap_mfpr and !ap_mfpc) return .do_not_associate;
    if (sta_mfpr and !sta_mfpc) return .do_not_associate;
    if (ap_mfpr and !sta_mfpc) return .do_not_associate;
    if (sta_mfpr and !ap_mfpc) return .do_not_associate;
    return .may_associate;
}

fn contains(list: []const u8, want: u8) bool {
    return std.mem.indexOfScalar(u8, list, want) != null;
}

/// 拿 AP 的 RSNE 对本 STA 的策略做匹配（12.6.3，印刷页 1991）：
///   组密码套件必须是 AP 通告的那一个，且本 STA 支持；
///   成对密码套件按 AP 列表的顺序取双方都支持的（AP 的列表缺席则按默认 CCMP-128），
///   AKM 同理（AP 的列表缺席则按默认 00-0F-AC:1，即 IEEE 802.1X）；
///   选中的 AKM 必须能与成对、组密码套件合用，AP 通告的 group management cipher suite 也
///   必须能与它合用（9.4.2.25.3，`akm.cipherAllowed`）。成对套件按 AP 的顺序、AKM 也按 AP 的顺序，
///   取第一对能合用的组合：AKM 11 会越过排在前面的 CCMP-128，选 GCMP-128；
///   再过表 12-2；管理帧保护协商成立时，AP 的 group management cipher suite 本 STA 还得支持。
pub fn select(ap: Rsne, own: OwnPolicy) SelError!Selection {
    if (!contains(own.group[0..own.group_len], ap.group)) return error.GroupNotSupported;

    // AP 的列表缺席时：成对默认 CCMP-128，AKM 默认 00-0F-AC:1（9.4.2.25.2、9.4.2.25.3）。
    const default_pairwise = [_]u8{Cipher.ccmp128};
    const default_akm = [_]u8{Akm.ieee8021x};
    const pws: []const u8 = if (ap.pairwise_len == 0) &default_pairwise else ap.pairwise[0..ap.pairwise_len];
    const akms: []const u8 = if (ap.akm_len == 0) &default_akm else ap.akm[0..ap.akm_len];
    var saw_pairwise = false;
    var saw_akm = false;
    var pairwise: ?u8 = null;
    var chosen_akm: ?u8 = null;
    for (pws) |c| {
        if (!contains(own.pairwise[0..own.pairwise_len], c)) continue;
        saw_pairwise = true;
        for (akms) |a| {
            if (!contains(own.akm[0..own.akm_len], a)) continue;
            saw_akm = true;
            if (!akm.cipherAllowed(a, c) or !akm.cipherAllowed(a, ap.group)) continue;
            pairwise = c;
            chosen_akm = a;
            break;
        }
        if (chosen_akm != null) break;
    }
    if (!saw_pairwise) return error.NoPairwiseOverlap;
    const ak = chosen_akm orelse return if (saw_akm) error.AkmCipherMismatch else error.NoAkmOverlap;
    const pw = pairwise.?;
    if (!akm.cipherAllowed(ak, ap.gmcs)) return error.AkmCipherMismatch;

    if (staMfpAction(ap.mfpc(), ap.mfpr(), own.mfpc, own.mfpr) == .do_not_associate) {
        return error.MfpPolicyViolation;
    }
    const negotiated = ap.mfpc() and own.mfpc;
    if (negotiated and ap.gmcs != own.gmcs) return error.GroupMgmtNotSupported;

    return .{ .pairwise = pw, .group = ap.group, .akm = ak, .mfp_negotiated = negotiated };
}

/// 本 STA 放进 (Re)Association Request 与消息 2 的 RSNE：版本、AP 的组密码套件、
/// 选中的一个成对密码套件、选中的一个 AKM。管理帧保护可用时再带上 RSN
/// Capabilities（MFPC / MFPR）、PMKID Count（可带一个 PMKID）与 group management
/// cipher suite——字段顺序与样例见 9.4.2.25.1 的 NOTE（印刷页 883–884）。
pub fn buildStaRsne(sel: Selection, own: OwnPolicy, pmkid: ?[pmkid_len]u8, out: []u8) Error!usize {
    var r = Rsne{
        .group = sel.group,
        .pairwise = .{ sel.pairwise, unknown, unknown, unknown, unknown, unknown, unknown, unknown },
        .pairwise_len = 1,
        .akm = .{ sel.akm, unknown, unknown, unknown, unknown, unknown, unknown, unknown },
        .akm_len = 1,
    };
    if (own.mfpc) {
        r.caps = caps_mfpc | (if (own.mfpr) caps_mfpr else 0);
        r.caps_present = true;
        r.pmkid_present = true;
        if (pmkid) |p| {
            r.pmkid[0] = p;
            r.pmkid_len = 1;
        }
        r.gmcs = own.gmcs;
        r.gmcs_present = true;
    }
    return encode(r, out);
}

/// 4 次握手确认管理帧保护：双方 RSNE 的 MFPC 都是 1 才算协商成立（12.6.3，印刷页 1992）。
pub fn mfpConfirmed(ap_rsne: []const u8, sta_rsne: []const u8) Error!bool {
    const ap = try parse(ap_rsne);
    const sta = try parse(sta_rsne);
    return ap.mfpc() and sta.mfpc();
}
