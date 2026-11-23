//! wifi-mlme：信息元素（IE）的遍历、解码与构造（IEEE Std 802.11-2016 Clause 9.4.2）。
//!
//! 三部分：
//!
//!   1. `Walker`：按 9.4.2.1（p.784）的「Element ID(1) + Length(1) + 可选的
//!      Element ID Extension(1) + Information」逐个走出元素，不认识的 ID 原样给出
//!      （9.3.3.2，p.694：不认识的元素跳过继续解析）。Length 指「Length 字段之后
//!      的字节数」，所以 ID 255 的扩展元素把 ID Extension 算在 Length 里。
//!   2. 解码器：SSID、Supported Rates、DSSS Parameter Set、TIM、Country、Extended
//!      Supported Rates、RSNE、Extended Capabilities、Management MIC。每个都是
//!      「截断 / 超长 / 自相矛盾」三类错误分开报。
//!   3. 构造器：STA 会发的四个元素（SSID、Supported Rates、Extended Supported
//!      Rates、RSNE）。
//!
//! 页码均为印刷页码。比特编号沿用 9.2.2（p.636）：字段第 N 位落在第 N/8 字节的
//! 第 N mod 8 位，低位在前。

const std = @import("std");

pub const ssid_max = 32;
/// Supported Rates 1–8 字节（Figure 9-124，p.791）。
pub const rates_max = 8;
/// Extended Supported Rates 1–255 字节（Figure 9-139，p.800）。
pub const ext_rates_max = 255;
/// TIM 的 DTIM Count / DTIM Period / Bitmap Control 三字节 + 1–251 字节位图
/// （Figure 9-127，p.793）。Length = 4..254。
pub const tim_min_len = 4;
pub const tim_max_len = 254;
/// 虚拟位图 2008 位 = 251 字节（p.793）。
pub const tim_bitmap_max = 251;
pub const country_triplets_max = 16;
pub const rsne_pairwise_max = 8;
pub const rsne_akm_max = 8;
pub const rsne_pmkid_max = 8;
pub const pmkid_len = 16;
/// MME：Key ID 2 + IPN 6 + MIC 8 或 16（Figure 9-330，p.941）。
pub const mmie_min_len = 16;
pub const mmie_max_len = 24;
/// Table 9-135（p.891–895）定义到的最高位是 B73，取整到 10 字节。
pub const ext_cap_max_octets = 10;

/// Table 9-77（p.784–790）里本组件用到的 Element ID。
pub const ElementId = enum(u8) {
    ssid = 0,
    supported_rates = 1,
    dsss_param_set = 3,
    cf_param_set = 4,
    tim = 5,
    ibss_param_set = 6,
    country = 7,
    challenge_text = 16,
    power_constraint = 32,
    erp = 42,
    rsn = 48,
    ext_supported_rates = 50,
    neighbor_report = 52,
    mgmt_mic = 76,
    ext_capabilities = 127,
    vendor_specific = 221,
    /// 使用 Element ID Extension 字段的元素（p.790）。
    extension = 255,
    _,
};

pub const IeError = error{
    /// 元素体短于该元素的最小长度。
    Truncated,
    /// 元素体长于该元素的最大长度。
    TooLong,
    /// 长度与内容对不上（Triplet 字段缺字节、MME 既非 16 也非 24 字节、RSNE 尾部多字节）。
    BadLength,
    /// 取值是保留值或自相矛盾（DTIM Period = 0、位图越过 251 字节、suite 计数为 0）。
    BadValue,
    /// RSNE Version 不是 1。
    BadVersion,
    /// Country 元素的 Padding 字节不是 0。
    BadPadding,
    /// 超出本实现的有界表。
    TooManyTriplets,
    TooManySuites,
    TooManyPmkids,
    /// MME Key ID 的 B12–B15 不是 0。
    ReservedBitsSet,
    /// MME Key ID 不是 4 或 5。
    BadKeyId,
    /// Extended Capabilities 是空的（长度 0）。
    Empty,
};

// ---------------------------------------------------------------------------
// 1) 遍历
// ---------------------------------------------------------------------------

pub const WalkError = error{
    /// 剩余字节装不下 Element ID 声明的长度。
    Truncated,
    /// Element ID 255 的元素没有 Element ID Extension 字节（Length = 0）。
    MissingIdExtension,
};

pub const Element = struct {
    id: u8,
    /// 仅 `id == 255` 时有意义。
    id_ext: u8 = 0,
    /// Information 字段，不含 Element ID / Length / Element ID Extension。
    body: []const u8,

    /// 是不是「扩展元素 ID」（ID 255 + ID Extension，9.4.2.1，p.784）。
    pub fn isExt(self: Element, id_ext: u8) bool {
        return self.id == @backingInt(ElementId.extension) and self.id_ext == id_ext;
    }
};

pub const Walker = struct {
    rest: []const u8,

    pub fn init(elements: []const u8) Walker {
        return .{ .rest = elements };
    }

    /// 取下一个元素；走完返回 null。出错后遍历器作废（之后只返回 null）。
    pub fn next(self: *Walker) WalkError!?Element {
        if (self.rest.len == 0) return null;
        errdefer self.rest = self.rest[0..0];
        if (self.rest.len < 2) return error.Truncated;
        const id = self.rest[0];
        const len: usize = self.rest[1];
        if (self.rest.len - 2 < len) return error.Truncated;
        const info = self.rest[2 .. 2 + len];
        self.rest = self.rest[2 + len ..];
        if (id != @backingInt(ElementId.extension)) {
            return .{ .id = id, .body = info };
        }
        if (info.len == 0) return error.MissingIdExtension;
        return .{ .id = id, .id_ext = info[0], .body = info[1..] };
    }

    /// 从当前位置起找第一个指定 ID 的元素；找不到返回 null。调用后遍历器停在
    /// 该元素之后。
    pub fn find(self: *Walker, id: ElementId) WalkError!?Element {
        while (try self.next()) |el| {
            if (el.id == @backingInt(id)) return el;
        }
        return null;
    }
};

/// 在一段元素串里找第一个指定 ID 的元素（不改任何状态）。
pub fn find(elements: []const u8, id: ElementId) WalkError!?Element {
    var w = Walker.init(elements);
    return w.find(id);
}

// ---------------------------------------------------------------------------
// 2) 解码器
// ---------------------------------------------------------------------------

// SSID（9.4.2.2，p.790）：0–32 字节，长度 0 是通配 SSID。
// 没有更短的下限，所以只有「超长」一种错误。

pub fn parseSsid(body: []const u8) IeError![]const u8 {
    if (body.len > ssid_max) return error.TooLong;
    return body;
}

pub fn isWildcardSsid(body: []const u8) bool {
    return body.len == 0;
}

// Supported Rates / Extended Supported Rates（9.4.2.3，p.790–791；9.4.2.13，p.799–800）

/// 一个速率字节：B7 是「基本」标志（只在 Beacon / Probe Response /
// (Re)Association Response 里有意义，其它管理帧里接收端忽略，p.791），
/// B6–B0 是以 500 kb/s 为单位的数据速率，或 BSS Membership Selector
/// 127（HT PHY）/ 126（VHT PHY）（Table 9-78，p.791）。
pub const Rate = struct {
    value: u7,
    basic: bool,

    pub fn isSelector(self: Rate) bool {
        return self.value == 127 or self.value == 126;
    }

    /// 速率值 × 500 kb/s；对 Membership Selector 没有意义。
    pub fn kbps(self: Rate) u32 {
        return @as(u32, self.value) * 500;
    }

    pub fn octet(self: Rate) u8 {
        return (@as(u8, @intFromBool(self.basic)) << 7) | @as(u8, self.value);
    }

    pub fn fromOctet(b: u8) Rate {
        return .{ .value = @truncate(b), .basic = b & 0x80 != 0 };
    }
};

/// 逐字节遍历 Supported Rates / Extended Supported Rates，不占表。
pub const RateIter = struct {
    rest: []const u8,

    pub fn next(self: *RateIter) ?Rate {
        if (self.rest.len == 0) return null;
        const r = Rate.fromOctet(self.rest[0]);
        self.rest = self.rest[1..];
        return r;
    }
};

/// Supported Rates and BSS Membership Selectors：1–8 字节（Figure 9-124）。
pub fn parseSupportedRates(body: []const u8) IeError!RateIter {
    if (body.len == 0) return error.Truncated;
    if (body.len > rates_max) return error.TooLong;
    return .{ .rest = body };
}

/// Extended Supported Rates and BSS Membership Selectors：1–255 字节（Figure 9-139）。
pub fn parseExtSupportedRates(body: []const u8) IeError!RateIter {
    if (body.len == 0) return error.Truncated;
    return .{ .rest = body };
}

// DSSS Parameter Set（9.4.2.4，p.792）：Current Channel 一个字节。

pub fn parseDsssChannel(body: []const u8) IeError!u8 {
    if (body.len < 1) return error.Truncated;
    if (body.len > 1) return error.TooLong;
    return body[0];
}

// TIM（9.4.2.6，p.792–794）

pub const Tim = struct {
    /// 到下一个 DTIM 之前（含本帧）还有几个 Beacon；0 表示本帧就是 DTIM。
    dtim_count: u8,
    /// 相邻两个 DTIM 之间的 Beacon 间隔数；全是 DTIM 时为 1。
    dtim_period: u8,
    /// Bitmap Control 的 B0：AP 缓存了组播 MSDU/MMPDU（只在 DTIM 里置 1）。
    multicast_buffered: bool,
    /// Bitmap Control 的 B1–B7 = N1/2：Partial Virtual Bitmap 从虚拟位图第几字节起。
    bitmap_offset: u8,
    partial: []const u8,

    pub fn isDtim(self: Tim) bool {
        return self.dtim_count == 0;
    }

    /// AID 对应的位是否置 1。AID 0 是组播位（p.793：「Bit number N indicates the
    /// status of buffered, individually addressed MSDU/MMPDUs for the STA whose AID is N」；
    /// 位 N 在第 N/8 字节的第 N mod 8 位）。
    pub fn bitSet(self: Tim, aid: u16) bool {
        if (aid == 0) return self.multicast_buffered;
        if (aid > 2007) return false;
        const octet: u16 = aid / 8;
        const first: u16 = @as(u16, self.bitmap_offset) * 2;
        if (octet < first) return false;
        const idx: usize = octet - first;
        if (idx >= self.partial.len) return false;
        return (self.partial[idx] >> @as(u3, @intCast(aid % 8))) & 1 != 0;
    }
};

pub fn parseTim(body: []const u8) IeError!Tim {
    if (body.len < tim_min_len) return error.Truncated;
    if (body.len > tim_max_len) return error.TooLong;
    const ctrl = body[2];
    const offset: u8 = ctrl >> 1;
    const partial = body[3..];
    if (body[1] == 0) return error.BadValue; // 「The DTIM Period value 0 is reserved」（p.793）
    if (@as(u16, offset) * 2 + partial.len > tim_bitmap_max) return error.BadValue;
    return .{
        .dtim_count = body[0],
        .dtim_period = body[1],
        .multicast_buffered = ctrl & 1 != 0,
        .bitmap_offset = offset,
        .partial = partial,
    };
}

// Country（9.4.2.9，p.795–797）

pub const Triplet = union(enum) {
    /// 首字节 ≤ 200：Subband Triplet（Figure 9-132，p.796）。
    subband: struct {
        first_channel: u8,
        num_channels: u8,
        /// 有符号数，dBm（p.797）。
        max_tx_power_dbm: i8,
    },
    /// 首字节 ≥ 201：Operating Triplet（Figure 9-134，p.796）。
    operating: struct {
        operating_extension_id: u8,
        operating_class: u8,
        coverage_class: u8,
    },
};

pub const Country = struct {
    /// 三个字节，结构由 dot11CountryString（Annex C）定义，这里原样保留。
    string: [3]u8,
    triplets: [country_triplets_max]Triplet = undefined,
    triplet_count: u8 = 0,

    pub fn tripletsSlice(self: *const Country) []const Triplet {
        return self.triplets[0..self.triplet_count];
    }
};

pub fn parseCountry(body: []const u8) IeError!Country {
    // 「The minimum length of the element is 8 octets」（p.797）：ID + Length + 3 + 3。
    if (body.len < 6) return error.Truncated;
    const extra = body.len - 3;
    var used = extra;
    switch (extra % 3) {
        // Triplet 字段 = Q×3 字节，或后面再跟 1 字节取值为 0 的 Padding
        // （Figure 9-130，p.795；p.797）。
        1 => {
            if (body[body.len - 1] != 0) return error.BadPadding;
            used -= 1;
        },
        2 => return error.BadLength,
        else => {},
    }
    const q: usize = used / 3;
    if (q > country_triplets_max) return error.TooManyTriplets;
    var c = Country{ .string = body[0..3].* };
    for (0..q) |i| {
        const t = body[3 + 3 * i ..][0..3];
        c.triplets[i] = if (t[0] <= 200)
            .{ .subband = .{ .first_channel = t[0], .num_channels = t[1], .max_tx_power_dbm = @bitCast(t[2]) } }
        else
            .{ .operating = .{ .operating_extension_id = t[0], .operating_class = t[1], .coverage_class = t[2] } };
    }
    c.triplet_count = @intCast(q);
    return c;
}

// RSNE（9.4.2.25，p.882–890）

pub const Suite = struct {
    oui: [3]u8,
    kind: u8,

    /// IEEE 注册的 suite selector OUI（Table 9-131，p.884）。
    pub const ieee_oui: [3]u8 = .{ 0x00, 0x0f, 0xac };

    pub fn ieee(kind: u8) Suite {
        return .{ .oui = ieee_oui, .kind = kind };
    }

    pub fn isIeee(self: Suite) bool {
        return std.mem.eql(u8, &self.oui, &ieee_oui);
    }

    pub fn eql(a: Suite, b: Suite) bool {
        return a.kind == b.kind and std.mem.eql(u8, &a.oui, &b.oui);
    }

    pub fn isIeeeKind(self: Suite, kind: u8) bool {
        return self.isIeee() and self.kind == kind;
    }
};

/// Table 9-131（p.884–885）里 00-0F-AC 的 Cipher Suite Selector。
pub const Cipher = enum(u8) {
    use_group = 0,
    wep_40 = 1,
    tkip = 2,
    ccmp_128 = 4,
    wep_104 = 5,
    bip_cmac_128 = 6,
    group_addressed_traffic_not_allowed = 7,
    gcmp_128 = 8,
    gcmp_256 = 9,
    ccmp_256 = 10,
    bip_gmac_128 = 11,
    bip_gmac_256 = 12,
    bip_cmac_256 = 13,
    _,
};

/// Table 9-133（p.886–887）里 00-0F-AC 的 AKM Suite Selector。
pub const Akm = enum(u8) {
    ieee802_1x = 1,
    psk = 2,
    ft_802_1x = 3,
    ft_psk = 4,
    sha256_802_1x = 5,
    sha256_psk = 6,
    tdls_tpk = 7,
    sae = 8,
    ft_sae = 9,
    ap_peerkey = 10,
    suite_b_128 = 11,
    suite_b_192 = 12,
    ft_802_1x_sha384 = 13,
    _,
};

/// Cipher Suite Selector 的名字；保留值、厂商自定义返回 null。
pub fn cipherName(s: Suite) ?[]const u8 {
    if (!s.isIeee()) return null;
    return switch (s.kind) {
        0 => "Use group cipher suite",
        1 => "WEP-40",
        2 => "TKIP",
        4 => "CCMP-128",
        5 => "WEP-104",
        6 => "BIP-CMAC-128",
        7 => "Group addressed traffic not allowed",
        8 => "GCMP-128",
        9 => "GCMP-256",
        10 => "CCMP-256",
        11 => "BIP-GMAC-128",
        12 => "BIP-GMAC-256",
        13 => "BIP-CMAC-256",
        else => null,
    };
}

/// AKM Suite Selector 的名字；保留值、厂商自定义返回 null。
pub fn akmName(s: Suite) ?[]const u8 {
    if (!s.isIeee()) return null;
    return switch (s.kind) {
        1 => "802.1X",
        2 => "PSK",
        3 => "FT-802.1X",
        4 => "FT-PSK",
        5 => "802.1X-SHA256",
        6 => "PSK-SHA256",
        7 => "TDLS",
        8 => "SAE",
        9 => "FT-SAE",
        10 => "AP-PeerKey",
        11 => "802.1X-Suite-B-128",
        12 => "802.1X-Suite-B-192",
        13 => "FT-802.1X-SHA384",
        else => null,
    };
}

/// 字段缺省时的默认 suite（p.885、p.888）：CCMP-128 与 802.1X；
/// 启用管理帧保护时组管理 cipher 默认 BIP-CMAC-128（p.885）。
pub const default_group_cipher = Suite.ieee(@backingInt(Cipher.ccmp_128));
pub const default_pairwise_cipher = Suite.ieee(@backingInt(Cipher.ccmp_128));
pub const default_akm = Suite.ieee(@backingInt(Akm.ieee802_1x));
pub const default_group_mgmt_cipher = Suite.ieee(@backingInt(Cipher.bip_cmac_128));

/// RSN Capabilities（Figure 9-257，p.888；各位含义见 9.4.2.25.4，p.888–890）。
/// 字段缺席时各位取 0（p.888）。
pub const RsnCaps = packed struct(u16) {
    preauthentication: bool = false,
    no_pairwise: bool = false,
    ptksa_replay_counters: u2 = 0,
    gtksa_replay_counters: u2 = 0,
    /// Management Frame Protection Required。
    mfpr: bool = false,
    /// Management Frame Protection Capable。
    mfpc: bool = false,
    joint_multiband_rsna: bool = false,
    peerkey_enabled: bool = false,
    spp_a_msdu_capable: bool = false,
    spp_a_msdu_required: bool = false,
    pbac: bool = false,
    extended_key_id: bool = false,
    reserved: u2 = 0,

    pub fn word(self: RsnCaps) u16 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u16) RsnCaps {
        return @bitCast(w);
    }
};

pub const Rsne = struct {
    group_data_cipher: ?Suite = null,
    pairwise: [rsne_pairwise_max]Suite = undefined,
    pairwise_len: u8 = 0,
    akms: [rsne_akm_max]Suite = undefined,
    akm_len: u8 = 0,
    caps: RsnCaps = .{},
    caps_present: bool = false,
    pmkids: [rsne_pmkid_max][pmkid_len]u8 = undefined,
    pmkid_count: u16 = 0,
    pmkids_present: bool = false,
    group_mgmt_cipher: ?Suite = null,

    pub fn pairwiseSlice(self: *const Rsne) []const Suite {
        return self.pairwise[0..self.pairwise_len];
    }

    pub fn akmSlice(self: *const Rsne) []const Suite {
        return self.akms[0..self.akm_len];
    }

    pub fn pmkidSlice(self: *const Rsne) []const [pmkid_len]u8 {
        return self.pmkids[0..self.pmkid_count];
    }

    /// 生效的 RSN Capabilities：字段缺席时全 0（p.888）。
    pub fn effectiveCaps(self: Rsne) RsnCaps {
        return self.caps;
    }

    /// 生效的组数据 cipher：字段缺席时默认 CCMP-128（p.885）。
    pub fn effectiveGroupCipher(self: Rsne) Suite {
        return self.group_data_cipher orelse default_group_cipher;
    }
};

const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn remaining(self: Cursor) usize {
        return self.buf.len - self.pos;
    }

    fn take(self: *Cursor, comptime n: usize) IeError!*const [n]u8 {
        if (self.remaining() < n) return error.Truncated;
        const s: *const [n]u8 = self.buf[self.pos..][0..n];
        self.pos += n;
        return s;
    }
};

fn readSuite(p: *const [4]u8) Suite {
    return .{ .oui = p[0..3].*, .kind = p[3] };
}

/// Pairwise / AKM Suite Count：「The value 0 is reserved」（p.884、p.886）。
fn readCountNonZero(c: *Cursor) IeError!u16 {
    const n = std.mem.readInt(u16, try c.take(2), .little);
    if (n == 0) return error.BadValue;
    return n;
}

/// 解析 RSNE 的 Information 字段（不含 Element ID 与 Length）。Version 之后的字段
/// 都是可选的，但「If any nonzero-length field is absent, then none of the
/// subsequent fields is included」（p.883）——所以帧体必须是完整布局的前缀。
pub fn parseRsne(body: []const u8) IeError!Rsne {
    var r = Rsne{};
    var c = Cursor{ .buf = body };
    if (std.mem.readInt(u16, try c.take(2), .little) != 1) return error.BadVersion;
    if (c.remaining() == 0) return r;
    r.group_data_cipher = readSuite(try c.take(4));
    if (c.remaining() == 0) return r;

    const pc = try readCountNonZero(&c);
    if (pc > rsne_pairwise_max) return error.TooManySuites;
    for (0..pc) |i| r.pairwise[i] = readSuite(try c.take(4));
    r.pairwise_len = @intCast(pc);
    if (c.remaining() == 0) return r;

    const ac = try readCountNonZero(&c);
    if (ac > rsne_akm_max) return error.TooManySuites;
    for (0..ac) |i| r.akms[i] = readSuite(try c.take(4));
    r.akm_len = @intCast(ac);
    if (c.remaining() == 0) return r;

    r.caps = RsnCaps.fromWord(std.mem.readInt(u16, try c.take(2), .little));
    r.caps_present = true;
    if (c.remaining() == 0) return r;

    // PMKID Count 可以是 0（「a series (possibly empty) of PMKIDs」，p.890）。
    const s = std.mem.readInt(u16, try c.take(2), .little);
    r.pmkids_present = true;
    if (s > rsne_pmkid_max) return error.TooManyPmkids;
    for (0..s) |i| r.pmkids[i] = (try c.take(pmkid_len)).*;
    r.pmkid_count = s;
    if (c.remaining() == 0) return r;

    r.group_mgmt_cipher = readSuite(try c.take(4));
    if (c.remaining() != 0) return error.BadLength;
    return r;
}

// Extended Capabilities（9.4.2.27，p.890–896；位号见 Table 9-135）

pub const ExtCap = struct {
    octets: [ext_cap_max_octets]u8 = @splat(0),
    len: u8 = 0,

    /// 第 `index` 位；超出收到的长度按 0。
    pub fn bit(self: ExtCap, index: u8) bool {
        const byte: u8 = index / 8;
        if (byte >= self.len) return false;
        return (self.octets[byte] >> @as(u3, @intCast(index % 8))) & 1 != 0;
    }

    /// B19：BSS Transition。
    pub fn bssTransition(self: ExtCap) bool {
        return self.bit(19);
    }
    /// B22：Multiple BSSID。
    pub fn multipleBssid(self: ExtCap) bool {
        return self.bit(22);
    }
    /// B25：SSID List。
    pub fn ssidList(self: ExtCap) bool {
        return self.bit(25);
    }
    /// B31：Interworking。
    pub fn interworking(self: ExtCap) bool {
        return self.bit(31);
    }
    /// B37：TDLS Support。
    pub fn tdlsSupport(self: ExtCap) bool {
        return self.bit(37);
    }
    /// B38：TDLS Prohibited。
    pub fn tdlsProhibited(self: ExtCap) bool {
        return self.bit(38);
    }
    /// B48：UTF-8 SSID。
    pub fn utf8Ssid(self: ExtCap) bool {
        return self.bit(48);
    }
    /// B62：Operating Mode Notification。
    pub fn operatingModeNotification(self: ExtCap) bool {
        return self.bit(62);
    }
    /// B70：Fine Timing Measurement Responder。
    pub fn ftmResponder(self: ExtCap) bool {
        return self.bit(70);
    }
    /// B71：Fine Timing Measurement Initiator。
    pub fn ftmInitiator(self: ExtCap) bool {
        return self.bit(71);
    }
};

pub fn parseExtCap(body: []const u8) IeError!ExtCap {
    if (body.len == 0) return error.Empty;
    if (body.len > ext_cap_max_octets) return error.TooLong;
    var e = ExtCap{ .len = @intCast(body.len) };
    @memcpy(e.octets[0..body.len], body);
    return e;
}

// Management MIC element（9.4.2.55，p.941）

pub const Mmie = struct {
    /// Key ID 字段的 B0–B11；IGTK Key ID 只会是 4 或 5。
    key_id: u16,
    /// 48 位 IPN，小端，用来检测组地址 robust 管理帧的重放。
    ipn: u64,
    /// BIP-CMAC-128 是 8 字节；BIP-CMAC-256 / BIP-GMAC-128 / BIP-GMAC-256 是 16 字节。
    mic: []const u8,

    pub fn isBipCmac128(self: Mmie) bool {
        return self.mic.len == 8;
    }
};

pub fn parseMmie(body: []const u8) IeError!Mmie {
    if (body.len < mmie_min_len) return error.Truncated;
    if (body.len > mmie_max_len) return error.TooLong;
    if (body.len != mmie_min_len and body.len != mmie_max_len) return error.BadLength;
    const key = std.mem.readInt(u16, body[0..2], .little);
    if (key & 0xf000 != 0) return error.ReservedBitsSet;
    const kid = key & 0x0fff;
    if (kid != 4 and kid != 5) return error.BadKeyId;
    var ipn: u64 = 0;
    for (body[2..8], 0..) |b, i| ipn |= @as(u64, b) << @as(u6, @intCast(8 * i));
    return .{ .key_id = kid, .ipn = ipn, .mic = body[8..] };
}

// ---------------------------------------------------------------------------
// 3) 构造器（STA 发出的元素；都带 Element ID 与 Length）
// ---------------------------------------------------------------------------

pub const BuildError = error{
    NoRoom,
    SsidTooLong,
    NoRates,
    TooManyRates,
    NoSuites,
    TooManySuites,
    TooManyPmkids,
};

pub fn buildSsid(ssid: []const u8, out: []u8) BuildError!usize {
    if (ssid.len > ssid_max) return error.SsidTooLong;
    const total = 2 + ssid.len;
    if (out.len < total) return error.NoRoom;
    out[0] = @backingInt(ElementId.ssid);
    out[1] = @intCast(ssid.len);
    @memcpy(out[2..][0..ssid.len], ssid);
    return total;
}

fn buildRateList(id: ElementId, rates: []const Rate, limit: usize, out: []u8) BuildError!usize {
    if (rates.len == 0) return error.NoRates;
    if (rates.len > limit) return error.TooManyRates;
    const total = 2 + rates.len;
    if (out.len < total) return error.NoRoom;
    out[0] = @backingInt(id);
    out[1] = @intCast(rates.len);
    for (rates, 0..) |r, i| out[2 + i] = r.octet();
    return total;
}

/// Supported Rates and BSS Membership Selectors：至多 8 个。
pub fn buildSupportedRates(rates: []const Rate, out: []u8) BuildError!usize {
    return buildRateList(.supported_rates, rates, rates_max, out);
}

/// Extended Supported Rates and BSS Membership Selectors：1–255 个。
pub fn buildExtSupportedRates(rates: []const Rate, out: []u8) BuildError!usize {
    return buildRateList(.ext_supported_rates, rates, ext_rates_max, out);
}

pub const RsneParams = struct {
    group_data_cipher: Suite,
    pairwise: []const Suite,
    akms: []const Suite,
    caps: ?RsnCaps = null,
    pmkids: []const [pmkid_len]u8 = &.{},
    /// 给出时一定写 PMKID Count（哪怕 PMKID 列表为空），因为它排在 Group
    /// Management Cipher Suite 之前（Figure 9-255，p.882）。
    group_mgmt_cipher: ?Suite = null,
};

pub fn buildRsne(p: RsneParams, out: []u8) BuildError!usize {
    if (p.pairwise.len == 0 or p.akms.len == 0) return error.NoSuites;
    if (p.pairwise.len > rsne_pairwise_max or p.akms.len > rsne_akm_max) return error.TooManySuites;
    if (p.pmkids.len > rsne_pmkid_max) return error.TooManyPmkids;
    const with_pmkid = p.pmkids.len != 0 or p.group_mgmt_cipher != null;
    const total: usize = 2 + 2 + 4 + 2 + 4 * p.pairwise.len + 2 + 4 * p.akms.len +
        (if (p.caps != null) @as(usize, 2) else 0) +
        (if (with_pmkid) 2 + pmkid_len * p.pmkids.len else 0) +
        (if (p.group_mgmt_cipher != null) @as(usize, 4) else 0);
    if (total - 2 > 255) return error.TooManySuites;
    if (out.len < total) return error.NoRoom;

    out[0] = @backingInt(ElementId.rsn);
    out[1] = @intCast(total - 2);
    var pos: usize = 2;
    std.mem.writeInt(u16, out[pos..][0..2], 1, .little); // Version 1（p.883）
    pos += 2;
    writeSuite(out[pos..][0..4], p.group_data_cipher);
    pos += 4;
    std.mem.writeInt(u16, out[pos..][0..2], @intCast(p.pairwise.len), .little);
    pos += 2;
    for (p.pairwise) |s| {
        writeSuite(out[pos..][0..4], s);
        pos += 4;
    }
    std.mem.writeInt(u16, out[pos..][0..2], @intCast(p.akms.len), .little);
    pos += 2;
    for (p.akms) |s| {
        writeSuite(out[pos..][0..4], s);
        pos += 4;
    }
    if (p.caps) |caps| {
        std.mem.writeInt(u16, out[pos..][0..2], caps.word(), .little);
        pos += 2;
    }
    if (with_pmkid) {
        std.mem.writeInt(u16, out[pos..][0..2], @intCast(p.pmkids.len), .little);
        pos += 2;
        for (p.pmkids) |id| {
            out[pos..][0..pmkid_len].* = id;
            pos += pmkid_len;
        }
    }
    if (p.group_mgmt_cipher) |g| {
        writeSuite(out[pos..][0..4], g);
        pos += 4;
    }
    std.debug.assert(pos == total);
    return total;
}

fn writeSuite(out: *[4]u8, s: Suite) void {
    out[0..3].* = s.oui;
    out[3] = s.kind;
}
