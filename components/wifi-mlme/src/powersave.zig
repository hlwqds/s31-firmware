//! wifi-mlme：省电（IEEE Std 802.11-2016 的 11.2，只取非 DMG infrastructure BSS、没有 PCF
//! 的那一部分）。
//!
//! 对应原文（页码为印刷页码）：
//!
//!   * 9.2.4.1.7 / 9.2.4.1.8（p.642–643）：Frame Control 里的 Power Management 与 More Data；
//!   * 9.3.1.5（p.671）、9.2.4.2 a)（p.644）：PS-Poll 帧与它的 Duration/ID 字段；
//!   * 11.2.1–11.2.2（p.1599–1600）：两种电源状态；可缓存的 MMPDU（Table 11-1）；
//!   * 11.2.3.1–11.2.3.2（p.1600–1602）：告知 AP 的规则、两种模式、模式转换的条件；
//!   * 11.2.3.4（p.1602）、9.4.2.6（p.792–794）：TIM / DTIM、traffic indication virtual
//!     bitmap、Bitmap Offset 与 Partial Virtual Bitmap 的编码；
//!   * 11.2.3.5.1（p.1603–1604）：U-APSD 的 trigger 帧、服务期、Max SP Length；
//!   * 11.2.3.6（p.1607–1610）：AP 在 CP 里的缓冲、TIM 的组装、DTIM 之后的组播、PS-Poll
//!     响应、More Data 与 EOSP 的置位、U-APSD 服务期；
//!   * 11.2.3.8 / 11.2.3.10 / 11.2.3.11（p.1611–1613）：PS 模式 STA 的接收流程；
//!   * 6.3.2.2–6.3.2.3（p.264–265）：MLME-POWERMGT.request / confirm；
//!   * 9.4.1.6（p.727）：Listen Interval；9.4.1.8（p.727）：AID。
//!
//! 两个确定性的模型，时间全部由调用方注入（TU），没有堆、没有分配：
//!
//!   * `Sta`：非 AP STA 一侧。模式转换要等 AP 的 Ack 才生效；TIM / DTIM 决定何时必须
//!     醒着、何时发 PS-Poll 或 trigger 帧；More Data 与 EOSP 决定还能不能睡。
//!   * `Ap`：进程内的 AP 模型，给 STA 侧对拍和自检用。按每个 STA 的缓冲状态生成 TIM，
//!     按 11.2.3.6 决定 PS-Poll 的响应、U-APSD 服务期、DTIM 之后的组播次序。
//!
//! 不做：CFP / PCF、IBSS / MBSS / DMG、S-APSD、FMS、TIM Broadcast、WNM sleep mode、VHT
//! TXOP power save、PSMP、TDLS peer PSM，以及 11.2.3.6 的 i)–k)（重传上限、aging）。
//! PS-Poll 之前的随机退避（11.2.3.8 b：0 到 aCWmin 个时隙）由驱动做，这里没有随机数。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const qos = @import("qos.zig");
const robust = @import("robust.zig");

/// AID 的最大值（9.4.1.8，p.727：「in the range of 1 to 2007」）；AID 0 留给组播
/// （11.2.3.3，p.1602）。
pub const aid_max: u16 = 2007;

// ---------------------------------------------------------------------------
// 1) Frame Control 里的两个子字段
// ---------------------------------------------------------------------------

/// 发送方在 BSS 里的角色。
pub const Role = enum { non_ap_sta, ap };

/// 9.2.4.1.7（p.642）：Power Management 子字段在 infrastructure BSS 里是否有效。
pub const PmValidity = enum {
    /// 有效：1 表示这次帧交换成功后 STA 进入 PS 模式，0 表示 active 模式。
    valid,
    /// 保留：发送时置 0，接收时忽略。
    reserved,

    pub fn name(self: PmValidity) []const u8 {
        return switch (self) {
            .valid => "valid",
            .reserved => "reserved",
        };
    }
};

/// Power Management 子字段只用来告知 AP「这次帧交换成功之后本 STA 处于哪种模式」
/// （9.2.4.1.7，p.642），单播帧与组播帧的含义相同：
///   * AP 发的所有帧里它是 Reserved；
///   * STA 发给「还没关联的 AP」的管理帧里它是 Reserved；
///   * 其余（infrastructure BSS 里 11.2.3 所说的那些帧交换）有效。
pub fn pmValidity(role: Role, fc: frame.FrameControl, associated: bool) PmValidity {
    return switch (role) {
        .ap => .reserved,
        .non_ap_sta => if (fc.type == .mgmt and !associated) .reserved else .valid,
    };
}

/// 9.2.4.1.8（p.643）：More Data 子字段的含义随发送方与地址类型变化。
pub const MoreDataMeaning = enum {
    /// AP 发给 PS 模式 STA 的单播 Data / Management 帧：1 = 给这个 STA 的缓冲 BU 至少还
    /// 有一个。
    ap_unicast,
    /// AP 发的（非 GCR-SP）组播帧：1 = 本 beacon 间隔内还有组播 BU 要发。
    ap_group,
    /// 非 AP STA 发的组播帧，以及上面两条以外的单播帧：必须为 0。
    must_be_zero,

    pub fn name(self: MoreDataMeaning) []const u8 {
        return switch (self) {
            .ap_unicast => "ap_unicast",
            .ap_group => "ap_group",
            .must_be_zero => "must_be_zero",
        };
    }
};

/// 取舍：这里只列 9.2.4.1.8 对 infrastructure BSS 的非 AP STA 与 AP 成立的三条；CF-Pollable
/// STA 回 CF-Poll、TDLS peer PSM、mesh、VHT TXOP power save 四个例外没有建模。
pub fn moreDataMeaning(role: Role, group_addressed: bool) MoreDataMeaning {
    return switch (role) {
        .ap => if (group_addressed) .ap_group else .ap_unicast,
        .non_ap_sta => .must_be_zero,
    };
}

/// More Data 子字段的取值是否合法（必须为 0 的地方不能是 1）。
pub fn moreDataValid(role: Role, group_addressed: bool, more_data: bool) bool {
    return !(more_data and moreDataMeaning(role, group_addressed) == .must_be_zero);
}

// ---------------------------------------------------------------------------
// 2) PS-Poll（9.3.1.5，p.671；9.2.4.2 a)，p.644）
// ---------------------------------------------------------------------------

/// Frame Control 2 + ID 2 + BSSID(RA) 6 + TA 6（Figure 9-23）。
pub const ps_poll_header_len = 16;
/// 连同 FCS。
pub const ps_poll_frame_len = ps_poll_header_len + frame.fcs_len;

pub const PsPollError = error{
    /// 不足 16 字节（含 FCS 时是 20 字节），或 FCS 被截断。
    TooShort,
    /// 超过 16 字节（含 FCS 时是 20 字节）：PS-Poll 没有帧体。
    TooLong,
    /// 不是 PS-Poll 子类型。
    NotPsPoll,
    BadProtocolVersion,
    BadFcs,
    /// Duration/ID 字段不是「高 2 位置 1 的 AID」，或 AID 不在 1–2007。
    BadAid,
};

pub const PsPoll = struct {
    /// Duration/ID 字段里的 AID（发这个帧的 STA 的 AID）。
    aid: u16,
    /// BSSID(RA)：AP 里那个 STA 的地址。
    bssid: frame.Mac,
    /// TA：发 PS-Poll 的 STA。
    ta: frame.Mac,
    fc: frame.FrameControl,
};

/// 拼一帧 PS-Poll（带 FCS，20 字节）。RA = BSSID，TA = 发帧的 STA，Duration/ID = AID。
pub fn buildPsPollFrame(aid: u16, bssid: frame.Mac, ta: frame.Mac, out: []u8) error{ BadAid, NoRoom }!usize {
    if (aid == 0 or aid > aid_max) return error.BadAid;
    if (out.len < ps_poll_frame_len) return error.NoRoom;
    const hdr = frame.Header{
        .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.ps_poll) },
        .duration_id = .{ .aid = aid },
        .addr1 = bssid,
        .addr2 = ta,
    };
    return frame.seal(hdr, &.{}, true, out) catch |e| switch (e) {
        error.NoRoom => error.NoRoom,
        else => unreachable, // 布局字段在这里填齐了，除缓冲区外不会失败
    };
}

/// 解析一帧 PS-Poll。长度必须恰好是 16 字节（`mode` 不是 `.none` 时再加上 4 字节 FCS）。
pub fn parsePsPoll(mpdu: []const u8, mode: frame.FcsMode) PsPollError!PsPoll {
    const end = mpdu.len -| (if (mode == .none) @as(usize, 0) else frame.fcs_len);
    if (end < ps_poll_header_len) return error.TooShort;
    if (end > ps_poll_header_len) return error.TooLong;
    const f = frame.parse(mpdu, mode) catch |e| return switch (e) {
        error.TooShort => error.TooShort,
        error.BadProtocolVersion => error.BadProtocolVersion,
        error.BadFcs => error.BadFcs,
        error.UnsupportedSubtype, error.UnexpectedBody => error.NotPsPoll,
    };
    const fc = f.hdr.fc;
    if (fc.type != .control or fc.subtype != @backingInt(frame.ControlSubtype.ps_poll)) return error.NotPsPoll;
    const aid = switch (f.hdr.duration_id) {
        .aid => |a| a,
        else => return error.BadAid,
    };
    if (aid == 0) return error.BadAid;
    return .{ .aid = aid, .bssid = f.hdr.addr1, .ta = f.hdr.addr2.?, .fc = fc };
}

// ---------------------------------------------------------------------------
// 3) 可缓存的 MMPDU（11.2.2，p.1600）
// ---------------------------------------------------------------------------

/// Table 11-1（p.1600）：Action（Fine Timing Measurement 帧与 Fine Timing Measurement
/// Request 帧除外）、Disassociation、Deauthentication 帧是 bufferable，AP 可以缓存后用省电
/// 机制投递；其余都是 nonbufferable，不看省电状态直接发。IBSS 里单独寻址的 Probe Response
/// 那一行不属于 infrastructure BSS，没有列。FTM 的两个帧是 Public Action 32、33
/// （9.6.8.1，p.1178）。`body` 是管理帧的帧体。
pub fn isBufferableMmpdu(fc: frame.FrameControl, body: []const u8) bool {
    if (fc.type != .mgmt) return false;
    return switch (fc.subtype) {
        @backingInt(frame.MgmtSubtype.disassoc),
        @backingInt(frame.MgmtSubtype.deauth),
        => true,
        @backingInt(frame.MgmtSubtype.action) => blk: {
            if (body.len < 2) break :blk true;
            const ftm = body[0] == @backingInt(robust.Category.public) and (body[1] == 32 or body[1] == 33);
            break :blk !ftm;
        },
        else => false,
    };
}

// ---------------------------------------------------------------------------
// 4) TIM（9.4.2.6，p.792–794；11.2.3.3–11.2.3.4，p.1602）
// ---------------------------------------------------------------------------

/// traffic indication virtual bitmap：2008 位、251 字节（p.793）。位 N（0 ≤ N ≤ 2007）在
/// 第 N/8 字节的第 N mod 8 位（低位在前）；位 N 是 AID 为 N 的 STA 有没有缓冲的单播 BU，
/// 位 0 是组播。
pub const virtual_bitmap_len = ie.tim_bitmap_max;

pub const VirtualBitmap = struct {
    octets: [virtual_bitmap_len]u8 = @splat(0),

    pub fn set(self: *VirtualBitmap, aid: u16) error{BadAid}!void {
        if (aid > aid_max) return error.BadAid;
        self.octets[aid / 8] |= bitOf(aid);
    }

    pub fn clear(self: *VirtualBitmap, aid: u16) void {
        if (aid > aid_max) return;
        self.octets[aid / 8] &= ~bitOf(aid);
    }

    pub fn isSet(self: *const VirtualBitmap, aid: u16) bool {
        if (aid > aid_max) return false;
        return self.octets[aid / 8] & bitOf(aid) != 0;
    }

    pub fn clearAll(self: *VirtualBitmap) void {
        @memset(&self.octets, 0);
    }

    /// AID 1–2007 里有没有置 1 的位（不含 AID 0）。
    pub fn anyUnicast(self: *const VirtualBitmap) bool {
        return self.lowestUnicast() != null;
    }

    /// 最低的置位位置（AID ≥ 1）；没有返回 null。
    fn lowestUnicast(self: *const VirtualBitmap) ?u16 {
        if (self.octets[0] & 0xfe != 0) {
            return @ctz(self.octets[0] & 0xfe);
        }
        for (self.octets[1..], 1..) |o, i| {
            if (o != 0) return @as(u16, @intCast(i * 8)) + @as(u16, @ctz(o));
        }
        return null;
    }

    /// 最高的置位位置（含 AID 0）；没有返回 null。
    fn highestAny(self: *const VirtualBitmap) ?u16 {
        var i: usize = self.octets.len;
        while (i > 0) {
            i -= 1;
            const o = self.octets[i];
            if (o != 0) return @as(u16, @intCast(i * 8)) + @as(u16, 7 - @clz(o));
        }
        return null;
    }
};

fn bitOf(aid: u16) u8 {
    return @as(u8, 1) << @as(u3, @truncate(aid));
}

/// 9.4.2.6（p.793，dot11MultiBSSIDActivated = false）：Partial Virtual Bitmap 取虚拟位图的
/// 第 N1 到第 N2 字节，Bitmap Offset = N1/2，Length = (N2 − N1) + 4。
pub const TimRange = struct {
    /// 最大的偶数 N1，使位 1 到 N1×8−1 全是 0。
    n1: u8,
    /// 最小的 N2，使位 (N2+1)×8 到 2007 全是 0。
    n2: u8,
    /// Bitmap Offset = N1/2。
    offset: u8,
    /// AID 1–2007 没有任何缓冲位：p.794 规定 Partial Virtual Bitmap 编成一个 0 字节、
    /// Bitmap Offset 为 0、Length 为 4。
    empty: bool,
};

pub fn timRange(b: *const VirtualBitmap) TimRange {
    const low = b.lowestUnicast() orelse return .{ .n1 = 0, .n2 = 0, .offset = 0, .empty = true };
    const high = b.highestAny().?;
    const n1: u8 = @intCast((low / 8) & 0xfe);
    const n2: u8 = @intCast(high / 8);
    return .{ .n1 = n1, .n2 = n2, .offset = n1 / 2, .empty = false };
}

pub const TimError = error{
    /// 「The DTIM Period value 0 is reserved」（p.793）。
    BadDtimPeriod,
    NoRoom,
};

/// 编码 TIM 元素（Element ID 5；Figure 9-127，p.793）。组播位只放在 Bitmap Control 的
/// B0，Partial Virtual Bitmap 里不重复。
pub fn encodeTim(b: *const VirtualBitmap, dtim_count: u8, dtim_period: u8, multicast_buffered: bool, out: []u8) TimError!usize {
    if (dtim_period == 0) return error.BadDtimPeriod;
    const r = timRange(b);
    const body_len: usize = if (r.empty) 4 else @as(usize, r.n2 - r.n1) + 4;
    if (out.len < 2 + body_len) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.tim);
    out[1] = @intCast(body_len);
    out[2] = dtim_count;
    out[3] = dtim_period;
    out[4] = (@as(u8, r.offset) << 1) | @intFromBool(multicast_buffered);
    if (r.empty) {
        out[5] = 0;
        return 6;
    }
    const n: usize = r.n2 - r.n1 + 1;
    @memcpy(out[5..][0..n], b.octets[r.n1 .. r.n2 + 1]);
    if (r.n1 == 0) out[5] &= 0xfe;
    return 5 + n;
}

/// 11.2.3.4（p.1602）与 9.4.2.6（p.793）：DTIM Count 是「本帧之后、下一个 DTIM 之前还有
/// 几个 Beacon」，本帧是 DTIM 时为 0。AP 决定相位，这里取序号 0 为 DTIM、之后每
/// `dtim_period` 个 Beacon 一个（Figure 11-7，p.1603）。
pub fn dtimCount(beacon_index: u64, dtim_period: u8) u8 {
    if (dtim_period <= 1) return 0;
    const r: u64 = beacon_index % dtim_period;
    return @intCast((dtim_period - r) % dtim_period); // r = 0 时正好是 period，模回去就是 0
}

// ---------------------------------------------------------------------------
// 5) 非 AP STA 一侧
// ---------------------------------------------------------------------------

/// 两种电源管理模式（11.2.3.2，p.1601）。
pub const Mode = enum {
    /// 随时可以收发，一直是 awake。
    active,
    /// 只在收发帧时醒来，其余时间 doze。
    power_save,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .active => "active",
            .power_save => "power_save",
        };
    }

    /// 发给 AP 的帧里 Power Management 子字段的取值：PS 模式是 1（9.2.4.1.7，p.642）。
    pub fn pmBit(self: Mode) bool {
        return self == .power_save;
    }
};

/// 两种电源状态（11.2.1，p.1599）。
pub const PowerState = enum { awake, doze };

/// 本 STA 发起的一次帧交换属于哪一类。只有「STA 发给已关联 AP、并且收到 Ack 或
/// BlockAck」的 Management / Extension / Data 帧交换才能改变模式（11.2.3.2，p.1601）。
pub const Exchange = enum {
    /// 发给已关联 AP 的 Management / Extension / Data 帧。
    frame_to_ap,
    /// PS-Poll：不保证有 Ack，不能用来改变模式（p.1601 NOTE 1）。
    ps_poll,
    /// 其它：组地址帧，或不是发给 AP 的帧。Power Management 子字段是 Reserved，置 0。
    other,
};

/// 一次帧交换结束后的结果。
pub const PowerMgtResult = enum {
    /// 这次交换不改变模式（不是发给 AP 的帧，或 PS-Poll）。
    ignored,
    /// 没收到 Ack / BlockAck：模式不变，待完成的请求继续挂着。
    not_acked,
    /// 模式转换完成：SME 该收到 MLME-POWERMGT.confirm(SUCCESS)（6.3.2.3.3，p.265）。
    confirmed,
    /// 交换成功，但没有待完成的转换，模式也没变。
    no_change,
};

pub const Config = struct {
    /// Beacon interval（TU）。
    beacon_interval_tu: u16 = 100,
    /// 第 0 个 TBTT 的时刻（TU）：第 n 个 TBTT = beacon_phase_tu + n × beacon_interval_tu。
    beacon_phase_tu: u64 = 0,
    /// 本 STA 的 QoS Info（(Re)Association Request 里 QoS Capability 元素的那一字节，
    /// 9.4.1.17，p.740）。B0–B3 是各 AC 的 U-APSD Flag，全 0 表示不用 U-APSD。
    qos_info: qos.QosInfoSta = .{},
};

pub const StateError = error{
    /// AID 不在 1–2007。
    BadAid,
    /// 还没有关联（AID = 0）。
    NotAssociated,
};

pub const RequestError = error{ NotAssociated, Busy };

/// `Sta.request` 的即时结果。
pub const RequestOutcome = enum {
    /// 需要告知 AP：转换挂起，等一次成功的帧交换后才 confirm。
    pending,
    /// 不需要告知 AP（请求的就是当前模式）：直接 confirm。
    confirmed,
};

/// AP 处还有缓冲的单播 BU，分两类（11.2.3.6 g，p.1608；9.4.2.6，p.793）。
pub const Buffered = packed struct(u2) {
    /// 不走 U-APSD 投递的 AC 上的缓冲 BU；非 U-APSD STA 的全部缓冲都在这一类。
    nondelivery: bool = false,
    /// delivery-enabled AC 上的缓冲 BU，只在 U-APSD 服务期里投递。
    delivery: bool = false,

    pub fn any(self: Buffered) bool {
        return self.nondelivery or self.delivery;
    }
};

/// 让 STA 不能睡的原因，任何一条成立就要保持清醒。
pub const Holds = struct {
    /// TIM 里本 STA 的位置 1、或 AP 用 More Data 表示还有缓冲的单播 BU（11.2.3.8 c、d）。
    unicast: bool = false,
    /// DTIM 的组播位置 1，组播帧还没收完（11.2.3.8 e）。
    multicast: bool = false,
    /// U-APSD 服务期进行中，还没收到 EOSP=1（11.2.3.10 c）。
    service_period: bool = false,

    pub fn any(self: Holds) bool {
        return self.unicast or self.multicast or self.service_period;
    }
};

/// 收到 Beacon 之后要做什么。
pub const BeaconEvent = struct {
    /// Beacon 没带 TIM，或 TIM 解析失败（截断、DTIM Period = 0、位图越界）。
    bad_tim: bool = false,
    /// 这是 DTIM 且 AID 0 位为 1：保持清醒收组播 BU。
    multicast: bool = false,
    /// TIM 里本 STA 的位置 1，要发 PS-Poll（11.2.3.8 b）。
    poll: bool = false,
    /// TIM 里本 STA 的位置 1，四个 AC 都 delivery-enabled，要发 trigger 帧（11.2.3.8 b）。
    trigger: bool = false,
};

/// 收到 AP 发来的单播帧之后要做什么。
pub const RxAction = struct {
    /// 还有不走 U-APSD 投递的缓冲 BU：再发 PS-Poll（11.2.3.8 d、11.2.3.10 d）。
    poll: bool = false,
    /// delivery-enabled AC 上还有缓冲 BU：可以再发 trigger 帧（11.2.3.10 d）。
    trigger: bool = false,
    /// U-APSD 服务期结束（收到 EOSP=1）。
    sp_ended: bool = false,
};

/// AP 发来的一帧单播帧里与省电有关的三样东西。
pub const Downlink = struct {
    more_data: bool,
    /// QoS 帧的 TID 所属 AC；非 QoS 帧为 null。
    ac: ?qos.Ac = null,
    /// QoS 帧的 EOSP（9.2.4.5.3，p.649）；非 QoS 帧为 null。
    eosp: ?bool = null,
};

/// 要从 AP 取回缓冲的 BU 时该发什么（11.2.3.8 b，p.1611）。
pub const Retrieval = enum {
    none,
    ps_poll,
    /// 「a trigger frame if the STA is using U-APSD and all ACs are delivery-enabled」。
    trigger_frame,
};

/// 下一个必须醒着收的 Beacon。
pub const Wake = union(enum) {
    /// 没有必须收的 Beacon。
    none,
    /// 该收的 Beacon 已经过了 TBTT 但还没收到：保持清醒，等下一个 Beacon。
    due_now,
    /// 下一个必须收的 Beacon：序号 `index`，TBTT 在 `at_tu`。
    future: struct { index: u64, at_tu: u64 },
};

/// 非 AP STA 一侧的省电状态机。时间由调用方以 TU 注入；`now_tu` 所在的 beacon 间隔
/// 是 `(now_tu − beacon_phase_tu) / beacon_interval_tu`，收到 Beacon 时调用方认为它就是
/// 这个间隔里那个 Beacon。
pub const Sta = struct {
    own_address: frame.Mac = @splat(0),
    bssid: frame.Mac = @splat(0),
    /// AP 分配的 AID；0 表示没有关联。
    aid: u16 = 0,
    /// (Re)Association Request 里发的 Listen Interval，单位 beacon interval。
    listen_interval: u16 = 1,
    /// 当前生效的模式（dot11PowerManagementMode）。
    mode: Mode = .active,
    /// 已请求、还没被 AP 确认的模式（11.2.3.1，p.1600）。
    pending: ?Mode = null,
    /// MLME-POWERMGT.request 的 ReceiveDTIMs。
    receive_dtims: bool = true,
    config: Config = .{},
    buffered: Buffered = .{},
    /// 最近一次 TIM 的 AID 0 位。
    multicast_buffered: bool = false,
    holds: Holds = .{},
    /// U-APSD 服务期进行中（发了 trigger 帧，还没收到 EOSP=1）。
    in_service_period: bool = false,
    /// 最近收到的 Beacon 的序号。
    last_beacon: ?u64 = null,
    /// 下一个 DTIM 的序号（由最近一次 TIM 的 DTIM Count 推出）。
    next_dtim: ?u64 = null,

    pub fn init(own_address: frame.Mac, bssid: frame.Mac, config: Config) Sta {
        return .{ .own_address = own_address, .bssid = bssid, .config = config };
    }

    /// 关联成功。11.2.3.2（p.1601）：「A non-AP STA shall be in active mode upon
    /// (re)association.」`listen_interval` 是 (Re)Association Request 里的 Listen Interval
    /// （9.4.1.6，p.727）。
    pub fn associated(self: *Sta, aid: u16, listen_interval: u16) error{BadAid}!void {
        if (aid == 0 or aid > aid_max) return error.BadAid;
        self.aid = aid;
        self.listen_interval = listen_interval;
        self.resetPsState();
    }

    /// 解除关联 / 解除认证：没有关联的 STA 谈不上 PS 模式，回到 active。
    pub fn disassociated(self: *Sta) void {
        self.aid = 0;
        self.pending = null;
        self.resetPsState();
    }

    fn resetPsState(self: *Sta) void {
        self.mode = .active;
        self.pending = null;
        self.buffered = .{};
        self.multicast_buffered = false;
        self.holds = .{};
        self.in_service_period = false;
        self.last_beacon = null;
        self.next_dtim = null;
    }

    fn usingUapsd(self: *const Sta) bool {
        return self.config.qos_info.uapsdMask() != 0;
    }

    fn allDeliveryEnabled(self: *const Sta) bool {
        return self.config.qos_info.allDeliveryEnabled();
    }

    /// 这一类 TIM 位覆盖哪些 AC：四个 AC 都 delivery-enabled 的 U-APSD STA 看 delivery-
    /// enabled AC；其余 STA（不用 U-APSD，或还有 nondelivery-enabled AC）看其余的 AC
    /// （9.4.2.6，p.793）。
    fn timCoversDelivery(self: *const Sta) bool {
        return self.usingUapsd() and self.allDeliveryEnabled();
    }

    fn noteTimBit(self: *Sta, set: bool) void {
        if (self.timCoversDelivery()) self.buffered.delivery = set else self.buffered.nondelivery = set;
    }

    // ---- 模式转换 ---------------------------------------------------------

    /// MLME-POWERMGT.request（6.3.2.2，p.264）。模式不会立刻变：要先让 AP 通过一次带 Ack
    /// 的帧交换知道（11.2.3.1，p.1600）。没有关联的 STA 只能在 active 模式。
    pub fn request(self: *Sta, mode: Mode, receive_dtims: bool) RequestError!RequestOutcome {
        if (self.aid == 0) return error.NotAssociated;
        if (self.pending != null) return error.Busy;
        self.receive_dtims = receive_dtims;
        if (mode == self.mode) return .confirmed;
        self.pending = mode;
        return .pending;
    }

    /// 本 STA 即将发出的帧里 Power Management 子字段该填什么（9.2.4.1.7，p.642）：
    /// 有挂起的转换时填要转去的模式，否则填当前模式。`other` 类的帧里这个子字段是
    /// Reserved，填 0。同一次帧交换序列里各帧的取值相同（p.1600：「Power management
    /// mode shall not change during any single frame exchange sequence」）：调用方在整个
    /// 序列结束后才调 `exchangeResult`。
    pub fn pmBitFor(self: *const Sta, exchange: Exchange) bool {
        return switch (exchange) {
            .frame_to_ap => if (self.pending) |m| m.pmBit() else self.mode.pmBit(),
            // PS-Poll 不能改变模式，只反映当前模式。
            .ps_poll => self.mode.pmBit(),
            .other => false,
        };
    }

    /// 一次 STA 发起的帧交换结束。`pm_bit` 是 STA 发的帧里 Power Management 子字段的
    /// 取值，`acked` 表示有没有收到 AP 的 Ack / BlockAck。11.2.3.2（p.1601）：「The
    /// Power Management subfield(s) ... indicates the power management mode that the STA
    /// shall adopt upon successful completion of the entire frame exchange」。
    pub fn exchangeResult(self: *Sta, exchange: Exchange, pm_bit: bool, acked: bool) PowerMgtResult {
        if (exchange != .frame_to_ap) return .ignored;
        if (!acked) return .not_acked;
        const adopted: Mode = if (pm_bit) .power_save else .active;
        const was_pending = self.pending != null;
        if (self.pending) |want| {
            // 这一帧没带上要转去的模式：AP 只是被重新告知了当前模式，请求继续挂着。
            if (want != adopted) {
                self.mode = adopted;
                return .no_change;
            }
            self.pending = null;
        }
        const changed = adopted != self.mode;
        self.mode = adopted;
        if (adopted == .active) {
            // 11.2.3.6 l)（p.1610）：AP 得知 STA 回到 active 模式后会直接把缓冲的 BU
            // 发下来，不用再轮询。
            self.buffered = .{};
            self.holds.unicast = false;
            self.in_service_period = false;
            self.holds.service_period = false;
        }
        return if (was_pending or changed) .confirmed else .no_change;
    }

    // ---- 收 Beacon -------------------------------------------------------

    fn beaconIndex(self: *const Sta, now_tu: u64) u64 {
        if (self.config.beacon_interval_tu == 0) return 0;
        return (now_tu -| self.config.beacon_phase_tu) / self.config.beacon_interval_tu;
    }

    /// 收到 Beacon（`tim_body` 是 TIM 元素的元素体，没带 TIM 时给 null）。记录 DTIM 的
    /// 组播位与自己的 AID 位，按 11.2.3.8 决定要不要保持清醒、要不要取回缓冲的 BU。
    pub fn onBeacon(self: *Sta, tim_body: ?[]const u8, now_tu: u64) BeaconEvent {
        var ev = BeaconEvent{};
        const index = self.beaconIndex(now_tu);
        // TIM 解析失败（截断、DTIM Period = 0、位图越界）：当作没收到这个 Beacon——
        // 缓冲状态不变，唤醒时间表也不动。
        const tim = ie.parseTim(tim_body orelse "") catch {
            ev.bad_tim = true;
            return ev;
        };
        self.last_beacon = index;
        // DTIM Count：本帧之后到下一个 DTIM 还有几个 Beacon；本帧是 DTIM 时下一个在
        // DTIM Period 之后。
        self.next_dtim = index + (if (tim.dtim_count == 0) tim.dtim_period else tim.dtim_count);
        self.multicast_buffered = tim.multicast_buffered;
        // 11.2.3.11（p.1613）：active 模式的 STA 不需要解释 TIM。
        if (self.mode != .power_save) return ev;

        if (tim.isDtim() and tim.multicast_buffered and self.receive_dtims) {
            // e)（p.1611）：DTIM 说有组播，保持清醒直到 More Data 为 0 或 TIM 清掉组播位。
            self.holds.multicast = true;
            ev.multicast = true;
        } else if (!tim.multicast_buffered) {
            self.holds.multicast = false;
        }

        // b)（p.1611）：自己的 AID 位置 1 就发 PS-Poll 或 trigger 帧；c)：之后的 TIM 说
        // 没有缓冲了，就可以不用等。
        const bit = self.aid != 0 and tim.bitSet(self.aid);
        self.noteTimBit(bit);
        self.holds.unicast = self.buffered.any();
        switch (self.retrieval()) {
            .ps_poll => ev.poll = true,
            .trigger_frame => ev.trigger = true,
            .none => {},
        }
        return ev;
    }

    /// AP 发来的 QoS +CF-Ack（More Data=1）或 Ack（More Data=1，且本 STA 声明了 More Data
    /// Ack）：「shall operate exactly as if it received a TIM with its AID bit equal to 1」
    /// （11.2.3.8，p.1612）。
    pub fn onMoreDataHint(self: *Sta) void {
        if (self.mode != .power_save or self.aid == 0) return;
        self.noteTimBit(true);
        self.holds.unicast = true;
    }

    /// AP 的 Ack 帧：只有本 STA 的 QoS Info 里 More Data Ack 为 1 时，More Data=1 才算数
    /// （9.2.4.1.8，p.643）。
    pub fn onAckFromAp(self: *Sta, more_data: bool) void {
        if (more_data and self.config.qos_info.more_data_ack) self.onMoreDataHint();
    }

    // ---- 收 AP 发来的帧 ---------------------------------------------------

    /// 收到 AP 发给本 STA 的单播帧（PS-Poll 的响应、服务期里的帧，或 AP 直接发来的）。
    /// More Data 表示还有没有缓冲的单播 BU；delivery-enabled AC 上的帧看 EOSP。
    pub fn onUnicastFromAp(self: *Sta, d: Downlink) RxAction {
        var a = RxAction{};
        const on_delivery_ac = if (d.ac) |ac| self.config.qos_info.uapsdEnabled(ac) else false;
        if (on_delivery_ac) self.buffered.delivery = d.more_data else self.buffered.nondelivery = d.more_data;
        if (d.eosp) |e| {
            // 11.2.3.10 c)（p.1613）：收到 EOSP=1 的 QoS Data / QoS Null，服务期结束。
            if (e and self.in_service_period) {
                self.in_service_period = false;
                self.holds.service_period = false;
                a.sp_ended = true;
            }
        }
        self.holds.unicast = self.buffered.any();
        if (d.more_data) {
            // 服务期还在进行时 trigger 帧不会开新服务期（11.2.3.6 d），只在服务期结束后才提示。
            if (on_delivery_ac) a.trigger = !self.in_service_period else a.poll = true;
        }
        return a;
    }

    /// 收到 AP 发的组播帧（DTIM 之后的组播 BU）。More Data=0 表示组播发完了
    /// （9.2.4.1.8，p.643；11.2.3.8 e，p.1611）。
    pub fn onGroupFromAp(self: *Sta, more_data: bool) void {
        self.multicast_buffered = more_data;
        if (!more_data) self.holds.multicast = false;
    }

    /// 要发 PS-Poll 还是 trigger 帧才能取回缓冲的 BU（11.2.3.8 b）。服务期进行中、模式
    /// 转换还没被确认、或不在 PS 模式时什么都不发。
    pub fn retrieval(self: *const Sta) Retrieval {
        if (self.mode != .power_save or self.pending != null or self.in_service_period) return .none;
        if (self.buffered.nondelivery) return .ps_poll;
        if (self.buffered.delivery) return .trigger_frame;
        return .none;
    }

    /// 发出了 trigger 帧（trigger-enabled AC 上的 QoS Data / QoS Null）。服务期到 EOSP=1
    /// 为止，期间保持清醒（11.2.3.5.1，p.1603；11.2.3.10 b、c，p.1612–1613）。只有 PS 模式
    /// 下 AP 才会把 BU 缓存到服务期里投递，active 模式下不需要 trigger 帧。
    pub fn triggerSent(self: *Sta) error{ NotUsingUapsd, NotInPowerSave }!void {
        if (!self.usingUapsd()) return error.NotUsingUapsd;
        if (self.mode != .power_save) return error.NotInPowerSave;
        self.in_service_period = true;
        self.holds.service_period = true;
    }

    /// 拼一帧 PS-Poll：RA = BSSID，TA = 本 STA，ID = 本 STA 的 AID。
    pub fn buildPsPoll(self: *const Sta, out: []u8) (error{ NotAssociated, BadAid, NoRoom })!usize {
        if (self.aid == 0) return error.NotAssociated;
        return buildPsPollFrame(self.aid, self.bssid, self.own_address, out);
    }

    // ---- 醒着还是睡着 -----------------------------------------------------

    /// 按 ListenInterval 与 ReceiveDTIMs 算出的下一个必须收的 Beacon（11.2.3.8 a、e，
    /// p.1611）。a)：「The STA shall wake up early enough to be able to receive the first
    /// Beacon frame scheduled for transmission at the time corresponding to the last TBTT
    /// for which the STA was awake plus the time interval indicated by the ListenInterval」。
    /// Listen Interval 为 0 表示不按间隔收（9.4.1.6 的 NOTE：从不进入省电的 STA 可以填 0）。
    pub fn nextWake(self: *const Sta, now_tu: u64) Wake {
        if (self.mode != .power_save) return .none;
        const interval: u64 = @max(1, self.config.beacon_interval_tu);
        const current = self.beaconIndex(now_tu);
        const index: u64 = if (self.last_beacon) |last| blk: {
            var target: ?u64 = if (self.listen_interval != 0) last +| self.listen_interval else null;
            if (self.receive_dtims) {
                if (self.next_dtim) |d| target = if (target) |t| @min(t, d) else d;
            }
            break :blk target orelse return .none;
        } else current + 1; // 还没收到过 Beacon：先按下一个 TBTT 算。
        const at = self.config.beacon_phase_tu +| index *| interval;
        if (now_tu >= at) return .due_now;
        return .{ .future = .{ .index = index, .at_tu = at } };
    }

    /// 这一刻允许处于哪种电源状态。只按省电的义务判断：active 模式总是 awake；PS 模式
    /// 下有挂起的模式转换、有还没办完的事（`Holds`）、或该收的 Beacon 已经到了，就
    /// 得醒着，否则可以 doze。本 STA 要发帧时自己会醒来（11.2.3.2：「The STA enters
    /// the awake state to receive or transmit frames」），这里不管。
    pub fn powerStateAt(self: *const Sta, now_tu: u64) PowerState {
        if (self.mode == .active or self.pending != null) return .awake;
        if (self.holds.any()) return .awake;
        return switch (self.nextWake(now_tu)) {
            .due_now => .awake,
            .none, .future => .doze,
        };
    }
};

// ---------------------------------------------------------------------------
// 6) 进程内的 AP 模型（11.2.3.6 的 CP 部分）
// ---------------------------------------------------------------------------

pub const max_stas = 8;

/// AP 该发的那一帧。
pub const Delivery = union(enum) {
    /// 没有待发的帧。
    none,
    /// DTIM 之后的组播 BU；`more_data`：后面还有。
    multicast: struct { more_data: bool },
    /// 发给某 STA 的一个缓冲 BU。`eosp` 只在 U-APSD 服务期的最后一帧上是 true。
    unicast: struct {
        aid: u16,
        ac: qos.Ac,
        more_data: bool,
        eosp: bool,
    },
    /// 没有缓冲 BU 可发时，用 EOSP=1 的 QoS Null 结束 U-APSD 服务期。
    qos_null_eosp: struct { aid: u16, ac: qos.Ac, more_data: bool },
};

/// 驱动对一帧发送结果的回报。
pub const TxResult = enum {
    /// 发出去了（单播帧收到了 Ack）。
    sent,
    /// 这次没收到 Ack，还要重传同一帧。
    retry,
    /// 放弃这一帧：BU 留在缓冲里，等下次 PS-Poll 或下一个服务期。
    failed,
};

pub const PollResult = enum {
    /// 没有这个 STA。
    unknown,
    /// 上一个 PS-Poll 的响应还没发完：只 Ack，不处理（11.2.3.6 g，p.1608）。
    ack_only,
    /// STA 不在 PS 模式：AP 没有为它缓存任何 BU。
    not_in_ps,
    /// 在 PS 模式，但能发给它的 AC 上没有缓冲 BU。
    nothing_buffered,
    /// 取出了一个缓冲 BU，由 `nextDelivery` 给出。
    deliver,
};

pub const TriggerResult = enum {
    unknown,
    /// 这个 AC 不是 trigger-enabled。
    ignored,
    /// 服务期已经在进行：不再开新的（11.2.3.6 d，p.1607）。
    sp_in_progress,
    /// 服务期开始。
    started,
};

pub const ApError = error{
    BadAid,
    /// 同时记住的 STA 超过 `max_stas`。
    TableFull,
    NotAssociated,
};

/// AP 侧的省电投递模型。每个已关联的 STA 一条记录，四个 AC 各记一个缓冲计数。
pub const Ap = struct {
    pub const PsSta = struct {
        used: bool = false,
        aid: u16 = 0,
        /// Power Management status（11.2.3.6，p.1607）：true = PS 模式。
        ps: bool = false,
        /// 在用 U-APSD（QoS Capability 里至少一个 U-APSD Flag 为 1）。
        uapsd: bool = false,
        /// delivery-enabled（同时 trigger-enabled）的 AC，bit i = ACI i。
        delivery_enabled: u4 = 0,
        max_sp_length: qos.MaxSpLength = .all,
        /// 每个 AC 缓冲的 BU 数（下标 = ACI）。
        buffered: [4]u16 = @splat(0),
        /// PS-Poll 的响应还没发完。
        poll_pending: bool = false,
        poll_ac: qos.Ac = .be,
        /// U-APSD 服务期进行中。
        sp_active: bool = false,
        sp_sent: u8 = 0,

        fn bufferedIn(self: *const PsSta, acs: u4) u32 {
            var n: u32 = 0;
            for (self.buffered, 0..) |c, i| {
                if (acs & (@as(u4, 1) << @as(u2, @intCast(i))) != 0) n += c;
            }
            return n;
        }

        fn totalBuffered(self: *const PsSta) u32 {
            return self.bufferedIn(0xf);
        }

        /// PS-Poll 能取到的 AC：有 nondelivery-enabled AC 的 U-APSD STA 只能从这些 AC 取；
        /// 其余 STA 四个 AC 都可以（11.2.3.6 g，p.1608）。
        fn pollAcs(self: *const PsSta) u4 {
            return if (self.uapsd and self.delivery_enabled != 0xf) ~self.delivery_enabled else 0xf;
        }

        /// 位 N（9.4.2.6，p.793）。不用 APSD 的 STA 看全部 AC；用 APSD 且还有
        /// nondelivery-enabled AC 的 STA 只看这些 AC；四个 AC 都 delivery-enabled 的看全部。
        pub fn timBit(self: *const PsSta) bool {
            if (!self.ps) return false;
            if (!self.uapsd) return self.totalBuffered() != 0;
            if (self.delivery_enabled != 0xf) return self.bufferedIn(~self.delivery_enabled) != 0;
            return self.totalBuffered() != 0;
        }
    };

    stas: [max_stas]PsSta = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    /// 为 PS 模式的 STA 缓存的组播 BU 数。
    multicast_buffered: u16 = 0,
    /// 这次 DTIM 之后要发的组播 BU 数。
    multicast_ready: u16 = 0,
    /// 正在发的那一帧（没发完之前 `nextDelivery` 一直返回它）。
    tx: ?Delivery = null,

    pub fn init() Ap {
        return .{};
    }

    pub fn find(self: *Ap, aid: u16) ?*PsSta {
        for (&self.stas) |*s| {
            if (s.used and s.aid == aid) return s;
        }
        return null;
    }

    fn anyPs(self: *const Ap) bool {
        for (&self.stas) |*s| {
            if (s.used and s.ps) return true;
        }
        return false;
    }

    /// STA 关联成功：一定是 active 模式（11.2.3.2）。`qos_info` 是 (Re)Association
    /// Request 里 QoS Capability 元素的 QoS Info；没有这个元素时给 null。
    pub fn associate(self: *Ap, aid: u16, qos_info: ?qos.QosInfoSta) ApError!void {
        if (aid == 0 or aid > aid_max) return error.BadAid;
        var slot: ?*PsSta = self.find(aid);
        if (slot == null) {
            for (&self.stas) |*s| {
                if (!s.used) {
                    slot = s;
                    break;
                }
            }
        }
        const s = slot orelse return error.TableFull;
        s.* = .{ .used = true, .aid = aid };
        if (qos_info) |q| {
            s.uapsd = q.uapsdMask() != 0;
            s.delivery_enabled = q.acMask();
            s.max_sp_length = q.max_sp_length;
        }
    }

    /// STA 离开（解除关联 / 老化掉）：丢掉为它缓存的东西。
    pub fn dissociate(self: *Ap, aid: u16) void {
        if (self.find(aid)) |s| s.* = .{};
    }

    /// AP 被告知 STA 的模式变了（带 Power Management 位的帧交换成功完成）。
    pub fn setPowerManagement(self: *Ap, aid: u16, ps: bool) ApError!void {
        const s = self.find(aid) orelse return error.NotAssociated;
        s.ps = ps;
        if (!ps) {
            // 11.2.3.6 l)：回到 active 模式后不等 PS-Poll，缓冲的 BU 直接发。
            s.poll_pending = false;
            s.sp_active = false;
        }
    }

    /// 一个 BU 到达 AP。返回 true 表示已为 PS 模式的 STA 缓存（11.2.3.6 a），false
    /// 表示该直接发（b：「No BUs addressed directly to STAs operating in the active mode
    /// shall be buffered for power management reasons」）。
    pub fn enqueueUnicast(self: *Ap, aid: u16, ac: qos.Ac) ApError!bool {
        const s = self.find(aid) orelse return error.NotAssociated;
        if (!s.ps) return false;
        s.buffered[ac.index()] +|= 1;
        return true;
    }

    /// 一个组播 BU 到达 AP。BSS 里有 STA 处于 PS 模式就缓存到下一个 DTIM 之后
    /// （11.2.3.1，p.1600；11.2.3.6 e），返回 true；否则直接发，返回 false。
    pub fn enqueueMulticast(self: *Ap) bool {
        if (!self.anyPs()) return false;
        self.multicast_buffered +|= 1;
        return true;
    }

    /// 一个 MMPDU 到达 AP。返回 true 表示要缓存（PS 模式的 STA + bufferable 的 MMPDU），
    /// false 表示不看省电状态直接发（11.2.3.6 b）。`bufferable` 用 `isBufferableMmpdu` 算。
    pub fn bufferMmpdu(self: *const Ap, aid: u16, bufferable: bool) ApError!bool {
        const s = self.find(aid) orelse return error.NotAssociated;
        return s.ps and bufferable;
    }

    /// 每个 beacon interval 调一次，生成 Beacon 里的 TIM 元素（11.2.3.6 c）。`dtim_count`
    /// 是 0 时这是 DTIM：接下来要发组播（11.2.3.6 f）。
    pub fn buildTim(self: *Ap, dtim_count: u8, dtim_period: u8, out: []u8) TimError!usize {
        var bitmap = VirtualBitmap{};
        for (&self.stas) |*s| {
            if (s.used and s.timBit()) bitmap.set(s.aid) catch unreachable;
        }
        if (dtim_count == 0) self.multicast_ready = self.multicast_buffered;
        return encodeTim(&bitmap, dtim_count, dtim_period, self.multicast_buffered != 0, out);
    }

    fn start(self: *Ap, d: Delivery) Delivery {
        self.tx = d;
        return d;
    }

    /// 接下来该发的那一帧。次序：DTIM 之后先发完组播（11.2.3.4：「before transmitting
    /// any individually addressed frames」），然后是进行中的 U-APSD 服务期，然后是不等
    /// PS-Poll 就要发的（回到 active 模式的 STA）与 PS-Poll 的响应。上一帧还没
    /// `txResult` 时一直返回那一帧。
    pub fn nextDelivery(self: *Ap) Delivery {
        if (self.tx) |d| return d;
        // f)：DTIM 之后先发完组播，才发单独寻址的帧（11.2.3.4，p.1602）。
        if (self.multicast_ready > 0) {
            return self.start(.{ .multicast = .{ .more_data = self.multicast_ready > 1 } });
        }
        for (&self.stas) |*s| {
            if (s.used and s.sp_active) {
                if (spFrame(s)) |d| return self.start(d);
            }
        }
        for (&self.stas) |*s| {
            if (!s.used) continue;
            // 11.2.3.6 l)：回到 active 模式的 STA，不等 PS-Poll。
            if (!s.ps) {
                if (qos.Ac.highest(presentAcs(s.buffered))) |ac| {
                    return self.start(.{ .unicast = .{
                        .aid = s.aid,
                        .ac = ac,
                        .more_data = s.totalBuffered() > 1,
                        .eosp = false,
                    } });
                }
            } else if (s.poll_pending) {
                return self.start(.{ .unicast = .{
                    .aid = s.aid,
                    .ac = s.poll_ac,
                    .more_data = s.bufferedIn(s.pollAcs()) > 1,
                    .eosp = false,
                } });
            }
        }
        return .none;
    }

    /// U-APSD 服务期里的下一帧（11.2.3.6 h，p.1608–1609）：delivery-enabled AC 里优先级
    /// 最高且有缓冲的那个 AC 取一个；至少尝试发一个 BU，不超过 Max SP Length；除最后一
    /// 帧外 EOSP 都是 0，最后一帧 EOSP=1。没有缓冲 BU 可发时用 EOSP=1 的 QoS Null 结束。
    fn spFrame(s: *PsSta) ?Delivery {
        const left = s.bufferedIn(s.delivery_enabled);
        if (left == 0) {
            if (s.sp_sent == 0) {
                const ac = qos.Ac.highest(s.delivery_enabled) orelse qos.Ac.vo;
                return .{ .qos_null_eosp = .{ .aid = s.aid, .ac = ac, .more_data = s.totalBuffered() != 0 } };
            }
            s.sp_active = false;
            return null;
        }
        // 11.2.3.6 h)：至少尝试发一个 BU，不超过 Max SP Length；`all` 是不限长。
        const cap: u32 = s.max_sp_length.limit() orelse 0xff;
        if (s.sp_sent >= cap) {
            s.sp_active = false;
            return null;
        }
        const ac = qos.Ac.highest(presentAcs(s.buffered) & s.delivery_enabled).?;
        return .{ .unicast = .{
            .aid = s.aid,
            .ac = ac,
            .more_data = left > 1,
            .eosp = @as(u32, s.sp_sent) + 1 == cap or left == 1,
        } };
    }

    /// 驱动回报 `nextDelivery` 给出的那一帧发得怎么样。
    pub fn txResult(self: *Ap, r: TxResult) void {
        const d = self.tx orelse return;
        switch (d) {
            .none => {},
            .multicast => {
                // 组播帧没有 MAC 层重传（10.3.6），发出去就算送到了。
                self.multicast_ready -|= 1;
                self.multicast_buffered -|= 1;
                self.tx = null;
            },
            .qos_null_eosp => {
                if (r == .retry) return;
                if (self.find(d.qos_null_eosp.aid)) |s| s.sp_active = false;
                self.tx = null;
            },
            .unicast => |u| {
                const s = self.find(u.aid);
                if (r == .sent) {
                    if (s) |st| {
                        st.buffered[u.ac.index()] -|= 1;
                        if (st.sp_active) {
                            if (u.eosp) st.sp_active = false else st.sp_sent +|= 1;
                        }
                        st.poll_pending = false;
                    }
                    self.tx = null;
                } else if (r == .retry) {
                    // 同一帧重传。
                } else {
                    // 11.2.3.6 j)：这个 BU 留到下一个服务期 / 下一次 PS-Poll。
                    if (s) |st| {
                        st.poll_pending = false;
                        st.sp_active = false;
                    }
                    self.tx = null;
                }
            },
        }
    }

    /// 收到 PS-Poll（11.2.3.6 g，p.1608）。
    pub fn onPsPoll(self: *Ap, aid: u16) PollResult {
        const s = self.find(aid) orelse return .unknown;
        if (s.poll_pending) return .ack_only;
        if (!s.ps) return .not_in_ps;
        const ac = qos.Ac.highest(presentAcs(s.buffered) & s.pollAcs()) orelse return .nothing_buffered;
        s.poll_pending = true;
        s.poll_ac = ac;
        return .deliver;
    }

    /// 收到 trigger 帧：trigger-enabled AC 上的 QoS Data / QoS Null（11.2.3.5.1，p.1603）。
    pub fn onTrigger(self: *Ap, aid: u16, ac: qos.Ac) TriggerResult {
        const s = self.find(aid) orelse return .unknown;
        if (!s.uapsd or s.delivery_enabled & ac.mask() == 0) return .ignored;
        if (s.sp_active) return .sp_in_progress;
        s.sp_active = true;
        s.sp_sent = 0;
        return .started;
    }
};

fn presentAcs(counts: [4]u16) u4 {
    var m: u4 = 0;
    for (counts, 0..) |c, i| {
        if (c != 0) m |= @as(u4, 1) << @as(u2, @intCast(i));
    }
    return m;
}
