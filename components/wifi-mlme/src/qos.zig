//! wifi-mlme：QoS（IEEE Std 802.11-2016 的 QoS Control 字段、QoS 数据帧、UP / TID / AC、
//! EDCA 参数、QoS Capability 与 EDCA Parameter Set 元素）。
//!
//! 对应原文（页码为印刷页码）：
//!
//!   * 9.2.4.1.3（p.639）：Data 帧子类型的 B7 是 QoS 子字段。带 QoS Control 字段的只有
//!     QoS 子类型的 Data 帧（9.2.4.5.1，p.648）；管理帧、控制帧一律没有。
//!   * 9.2.4.5.1–.16（p.647–653）：QoS Control 字段。布局见 Table 9-6（p.648），TID 的
//!     归属见 Table 9-8（p.649），Ack Policy 见 Table 9-9（p.650–651），AP PS Buffer
//!     State 见 Figure 9-6（p.652）。
//!   * Table 10-1（p.1298）：UP → AC；10.2.4.2（p.1299）：管理帧与 PS-Poll 用的 AC。
//!   * 9.4.2.29（p.897–898）：EDCA Parameter Set 元素（Figure 9-261–9-264）；默认值见
//!     Table 9-137（p.899），ACI 见 Table 9-136（p.898）。
//!   * 9.4.2.35（p.916）、9.4.1.17（p.739–740）：QoS Capability 元素与 QoS Info 字段，
//!     Max SP Length 见 Table 9-48（p.740）。
//!   * 10.22.2.2 / 10.22.2.4（p.1379–1380）：CW 与 AIFS；10.22.2.8（p.1387）：TXOP 上限
//!     为 0 的含义；10.12（p.1365）：A-MSDU 只能放在 QoS Data 帧里。
//!
//! Table 9-6 只实现 infrastructure BSS 的六行（HC 与非 AP STA）和 mesh BSS 的那一行。
//! DMG 的 Table 9-7、TPU buffer / sleep STA 的四行不在范围。本文件不 import 硬件相关代码。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");

// ---------------------------------------------------------------------------
// 1) AC、UP 与 TID
// ---------------------------------------------------------------------------

/// 四个访问类别（access category）。取值就是 ACI（Table 9-136，p.898）。
pub const Ac = enum(u2) {
    be = 0,
    bk = 1,
    vi = 2,
    vo = 3,

    pub fn name(self: Ac) []const u8 {
        return switch (self) {
            .be => "AC_BE",
            .bk => "AC_BK",
            .vi => "AC_VI",
            .vo => "AC_VO",
        };
    }

    pub fn index(self: Ac) u2 {
        return @backingInt(self);
    }

    /// Table 9-136（p.898）：ACI → AC。
    pub fn fromIndex(aci: u2) Ac {
        return @fromBackingInt(@intCast(aci));
    }

    /// 4 位 AC 掩码里对应的那一位（bit i = ACI i）。
    pub fn mask(self: Ac) u4 {
        return @as(u4, 1) << self.index();
    }

    /// 掩码 `acs` 里优先级最高的那个 AC；掩码为空返回 null。
    pub fn highest(acs: u4) ?Ac {
        var i: u2 = 3;
        while (true) {
            const ac: Ac = @fromBackingInt(@intCast(i));
            if (acs & ac.mask() != 0) return ac;
            if (i == 0) return null;
            i -= 1;
        }
    }
};

/// Table 9-8（p.649）：TID 子字段的取值归属。EDCA 的 TID 就是 UP（0–7）；
/// 8–15 是 TSID（HCCA、SPCA，以及 HEMM / SEMM 的流量流，Table 9-8）。
pub const TidKind = enum { up, tsid };

pub fn tidKind(tid: u4) TidKind {
    return if (tid < 8) .up else .tsid;
}

/// Table 10-1（p.1298）：UP → AC。UP 1、2 是 Background，0、3 是 Best Effort，
/// 4、5 是 Video，6、7 是 Voice。
pub fn acForUp(up: u3) Ac {
    return switch (up) {
        1, 2 => .bk,
        0, 3 => .be,
        4, 5 => .vi,
        6, 7 => .vo,
    };
}

/// TID → AC：TID 0–7 就是 UP；TID 8–15 是 TSID（Table 9-8），不属于任何 AC。
pub fn acForTid(tid: u4) ?Ac {
    return if (tid < 8) acForUp(@intCast(tid)) else null;
}

pub const TidError = error{
    /// 超过 4 位。
    BadTid,
    /// TID 8–15 是 TSID：本组件只做 EDCA，发帧时不接受。
    TidIsTsid,
};

/// 发 QoS 帧前核对 TID：必须是 EDCA 的 0–7。
pub fn edcaTid(tid: u8) TidError!u4 {
    if (tid > 15) return error.BadTid;
    if (tid >= 8) return error.TidIsTsid;
    return @intCast(tid);
}

/// 10.2.4.2（p.1299）：管理帧用 AC_VO；单独寻址发给非 QoS STA 的管理帧用 AC_BE。
pub fn acForMgmtFrame(individual_to_non_qos_sta: bool) Ac {
    return if (individual_to_non_qos_sta) .be else .vo;
}

/// 10.2.4.2（p.1299）：「PS-Poll frames shall be sent using the access category
/// AC_BE for medium access」。
pub const ps_poll_ac: Ac = .be;

// ---------------------------------------------------------------------------
// 2) EDCA 参数
// ---------------------------------------------------------------------------

/// TXOP Limit / TXOP Duration Requested 的单位（9.2.4.5.5，p.651）。
pub const txop_unit_us: u32 = 32;

/// 一个 AC 的 EDCA 参数（dot11EDCATable 的一行）。
pub const AcParams = struct {
    /// 空闲槽数的系数；非 AP STA 的最小值是 2（10.22.2.4，p.1381）。
    aifsn: u8 = 0,
    cwmin: u16 = 0,
    cwmax: u16 = 0,
    /// TXOP 上限，单位 32 µs。0 表示这个 TXOP 里只发一个 MPDU（10.22.2.8，p.1387）。
    txop_limit: u16 = 0,

    /// 10.22.2.4（p.1380）：AIFS[AC] = AIFSN[AC] × aSlotTime + aSIFSTime。
    pub fn aifsUs(self: AcParams, slot_time_us: u32, sifs_us: u32) u32 {
        return @as(u32, self.aifsn) * slot_time_us + sifs_us;
    }

    /// TXOP 上限（µs）。
    pub fn txopLimitUs(self: AcParams) u32 {
        return @as(u32, self.txop_limit) * txop_unit_us;
    }
};

/// PHY 的 aCWmin / aCWmax（PLME-CHARACTERISTICS 给出的静态特性）。
pub const Cw = struct { min: u16, max: u16 };

/// Table 15-5（p.2238），DSSS。
pub const dsss_cw = Cw{ .min = 31, .max = 1023 };
/// Table 16-4（p.2263），HR/DSSS。
pub const hr_dsss_cw = Cw{ .min = 31, .max = 1023 };
/// Table 17-21（p.2321），OFDM。20 MHz 信道的 aSlotTime = 9 µs、aSIFSTime = 16 µs。
pub const ofdm_cw = Cw{ .min = 15, .max = 1023 };
pub const ofdm_slot_time_us: u32 = 9;
pub const ofdm_sifs_us: u32 = 16;
/// Table 19-25（p.2426），HT。
pub const ht_cw = Cw{ .min = 15, .max = 1023 };

/// 10.3.9（p.1334）与 Table 18-5（p.2332）：ERP 的 aCWmin 取两个值之一——基本速率集
/// 只含 1、2、5.5、11 Mb/s 时是 aCWmin(0) = 31，否则是 aCWmin(1) = 15。
pub fn erpCw(only_dsss_rates: bool) Cw {
    return .{ .min = if (only_dsss_rates) 31 else 15, .max = 1023 };
}

/// Table 9-137（p.899）按 PHY 分的三列。Clause 22（TVHT）那一列随 BCU 变、且不是
/// 32 µs 的整数倍，本实现没有取。
pub const PhyFamily = enum {
    /// Clause 15（DSSS）、Clause 16（HR/DSSS）。
    clause_15_16,
    /// Clause 17（OFDM）、18（ERP）、19（HT）、21（VHT）。
    clause_17_18_19_21,
    /// 其它 PHY：TXOP 上限为 0。
    other,
};

/// Table 9-137（p.899）：非 AP STA 的默认 EDCA 参数。返回的数组下标是 ACI
/// （0 = AC_BE，1 = AC_BK，2 = AC_VI，3 = AC_VO）。`cw` 是 PHY 的 aCWmin / aCWmax。
pub fn defaultAcParams(family: PhyFamily, cw: Cw) [4]AcParams {
    const m: u32 = @as(u32, cw.min) + 1;
    const vi_cwmin: u16 = @intCast(m / 2 - 1);
    const vo_cwmin: u16 = @intCast(m / 4 - 1);
    // TXOP 上限（µs，下面换成 32 µs 为单位）：AC_BE、AC_BK、AC_VI、AC_VO。
    const txop_us = switch (family) {
        .clause_15_16 => [4]u32{ 3264, 3264, 6016, 3264 },
        .clause_17_18_19_21 => [4]u32{ 2528, 2528, 4096, 2080 },
        .other => [4]u32{ 0, 0, 0, 0 },
    };
    var out: [4]AcParams = undefined;
    for (&out, txop_us) |*p, us| p.txop_limit = @intCast(us / txop_unit_us);
    out[0].aifsn = 3;
    out[0].cwmin = cw.min;
    out[0].cwmax = cw.max;
    out[1].aifsn = 7;
    out[1].cwmin = cw.min;
    out[1].cwmax = cw.max;
    out[2].aifsn = 2;
    out[2].cwmin = vi_cwmin;
    out[2].cwmax = cw.min;
    out[3].aifsn = 2;
    out[3].cwmin = vo_cwmin;
    out[3].cwmax = vi_cwmin;
    return out;
}

// ---------------------------------------------------------------------------
// 3) QoS Control 字段（9.2.4.5，p.647–653；Table 9-6，p.648）
// ---------------------------------------------------------------------------

/// 发送方。Table 9-6 的行按发送方与帧子类型来选。
pub const Sender = enum {
    /// 混合协调者（HC），也就是 AP。
    hc,
    non_ap_sta,
    mesh,
};

pub const LayoutError = error{
    /// 不是 Data 帧，或者 Data 子类型的 QoS 子字段是 0：没有 QoS Control 字段。
    NotQosFrame,
    /// Data 子类型 13（Table 9-1 标为 Reserved）。
    ReservedSubtype,
    /// Table 9-6 里本实现没有取的行：非 AP STA 发的 QoS (+)CF-Poll 帧、3 地址且单独寻址的 mesh 帧。
    UnsupportedLayout,
    /// Table 9-6 标为 Reserved 的位被置 1（或交叉字段的保留条件不成立）。
    ReservedBitsSet,
    /// 给 `encode` 的子字段与这一行布局对不上。
    LayoutMismatch,
    /// A-MSDU Present = 1 但帧体为空（10.12，p.1365：A-MSDU 放在 QoS Data 帧的帧体里）。
    AmsduWithoutBody,
};

/// Table 9-6 的一行。
pub const Layout = enum {
    /// HC 发的 QoS CF-Poll、QoS CF-Ack +CF-Poll：B4 EOSP，B7 Reserved，B8–B15 TXOP Limit。
    hc_cf_poll,
    /// HC 发的 QoS Data +CF-Poll、QoS Data +CF-Ack +CF-Poll：B7 A-MSDU Present，B8–B15 TXOP Limit。
    hc_data_cf_poll,
    /// HC 发的 QoS Data、QoS Data +CF-Ack：B7 A-MSDU Present，B8–B15 AP PS Buffer State。
    hc_data,
    /// HC 发的 QoS Null：B4 EOSP，B7 Reserved，B8–B15 AP PS Buffer State。
    hc_null,
    /// 非 AP STA 发的 QoS Data、QoS Data +CF-Ack：B4 = 0 时 B8–B15 是 TXOP Duration
    /// Requested，B4 = 1 时是 Queue Size。
    sta_data,
    /// 非 AP STA 发的 QoS Null：B7 Reserved，其余同 `sta_data`。
    sta_null,
    /// mesh BSS 里 mesh STA 发的全部帧：B4 EOSP，B7 A-MSDU Present，B8 Mesh Control
    /// Present，B9 Mesh Power Save Level，B10 RSPI，B11–B15 Reserved。
    mesh,

    /// 这一行的 B4 是 EOSP（非 AP STA 的两行里 B4 是布局选择位）。
    pub fn hasEosp(self: Layout) bool {
        return switch (self) {
            .hc_cf_poll, .hc_data_cf_poll, .hc_data, .hc_null, .mesh => true,
            .sta_data, .sta_null => false,
        };
    }

    /// 这一行的 B7 是 A-MSDU Present（其余行的 B7 是 Reserved）。
    pub fn hasAMsdU(self: Layout) bool {
        return switch (self) {
            .hc_data_cf_poll, .hc_data, .sta_data, .mesh => true,
            .hc_cf_poll, .hc_null, .sta_null => false,
        };
    }

    pub fn name(self: Layout) []const u8 {
        return switch (self) {
            .hc_cf_poll => "hc_cf_poll",
            .hc_data_cf_poll => "hc_data_cf_poll",
            .hc_data => "hc_data",
            .hc_null => "hc_null",
            .sta_data => "sta_data",
            .sta_null => "sta_null",
            .mesh => "mesh",
        };
    }
};

/// 由 To DS / From DS 推断发送方（Table 9-3，p.641）。To DS=0 From DS=1 只用于 AP 发的
/// 帧；To DS=1 From DS=0 是 STA 发给 AP；两个都是 1 的四地址格式只用于 mesh BSS。
pub fn senderOf(fc: frame.FrameControl) LayoutError!Sender {
    if (fc.type != .data) return error.NotQosFrame;
    const key: u2 = (@as(u2, @intFromBool(fc.to_ds)) << 1) | @intFromBool(fc.from_ds);
    return switch (key) {
        0b01 => .hc,
        0b00, 0b10 => .non_ap_sta,
        0b11 => .mesh,
    };
}

/// Table 9-6：这一帧的 QoS Control 字段用哪一行布局。
pub fn layoutFor(fc: frame.FrameControl, sender: Sender) LayoutError!Layout {
    if (fc.type != .data or !fc.isQoSData()) return error.NotQosFrame;
    return switch (sender) {
        .mesh => .mesh,
        .hc => switch (fc.subtype) {
            8, 9 => .hc_data,
            10, 11 => .hc_data_cf_poll,
            12 => .hc_null,
            14, 15 => .hc_cf_poll,
            else => error.ReservedSubtype,
        },
        .non_ap_sta => switch (fc.subtype) {
            8, 9 => .sta_data,
            12 => .sta_null,
            else => error.UnsupportedLayout,
        },
    };
}

/// AP PS Buffer State（9.2.4.5.8，p.652；Figure 9-6）：AP 为这个 STA 缓存了多少。
pub const ApPsBufferState = struct {
    /// B9：1 表示给出了缓冲状态；为 0 时下面两项是 Reserved。
    indicated: bool = false,
    /// B10–B11：除本帧之外还有缓冲的 AC 里优先级最高的那个（ACI）。
    highest_priority_ac: u2 = 0,
    /// B12–B15：缓冲总量，4096 字节为单位；15 表示超过 57 344 字节。
    buffered_load: u4 = 0,

    /// B8–B15 这一个字节。
    pub fn octet(self: ApPsBufferState) LayoutError!u8 {
        if (!self.indicated and (self.highest_priority_ac != 0 or self.buffered_load != 0)) {
            return error.ReservedBitsSet;
        }
        return (@as(u8, @intFromBool(self.indicated)) << 1) |
            (@as(u8, self.highest_priority_ac) << 2) | (@as(u8, self.buffered_load) << 4);
    }

    /// 缓冲总量的下界（字节）；`buffered_load` 为 0（没有缓冲）时是 null。
    pub fn octetsAtLeast(self: ApPsBufferState) ?u32 {
        if (self.buffered_load == 0) return null;
        return @as(u32, self.buffered_load) * ap_buffered_load_unit;
    }
};

pub const ap_buffered_load_unit: u32 = 4096;
/// AP Buffered Load = 15 的含义：超过 57 344 字节（p.652）。
pub const ap_buffered_load_more_than: u32 = 14 * ap_buffered_load_unit;

/// 把缓冲字节数折成 AP Buffered Load：向上取整到 4096 的整数倍，超过 57 344 记 15。
pub fn encodeApBufferedLoad(octets: u32) u4 {
    if (octets > ap_buffered_load_more_than) return 15;
    return @intCast((octets + ap_buffered_load_unit - 1) / ap_buffered_load_unit);
}

/// B8–B15 随布局变化的那一段。
pub const Tail = union(enum) {
    /// HC 发的含 CF-Poll 的帧：TXOP Limit，单位 32 µs；0 表示紧跟着只发一个 MPDU 或
    /// 一个 QoS Null 帧（9.2.4.5.5，p.651）。
    txop_limit: u8,
    /// HC 发的 QoS Data / QoS Null：AP PS Buffer State。
    ap_ps_buffer_state: ApPsBufferState,
    /// 非 AP STA 的帧：希望下一个 TXOP 有多长，单位 32 µs；0 表示本服务期不请求
    /// （9.2.4.5.7，p.652）。
    txop_duration_requested: u8,
    /// 非 AP STA 的帧：同一 TID 的发送队列里还缓存了多少，256 字节为单位
    /// （9.2.4.5.6，p.651）。
    queue_size: u8,
    /// mesh STA 的帧：B8–B10 三个子字段（9.2.4.5.10–.12，p.652–653）。
    mesh: MeshBits,
};

pub const MeshBits = struct {
    /// B8：帧体里带 Mesh Control 字段。
    control_present: bool = false,
    /// B9：这次帧交换成功后对端的 mesh power management 模式是 deep sleep。
    /// Power Management 子字段为 0 时是 Reserved。
    power_save_level: bool = false,
    /// B10：以接收方为 owner 的 mesh peer service period 已发起。组地址帧里是 Reserved。
    rspi: bool = false,
};

/// 按 Table 9-6 的一行拆开的 QoS Control 字段。
pub const Fields = struct {
    /// B0–B3。0–7 是 EDCA 的 UP，8–15 是 TSID（Table 9-8，p.649）。
    tid: u4 = 0,
    /// B4 EOSP（9.2.4.5.3，p.649）：HC 置 1 表示服务期的最后一帧。非 AP STA 的两行里
    /// B4 不是 EOSP，这里是 null。
    eosp: ?bool = null,
    /// B5–B6（Table 9-9，p.650–651）。
    ack_policy: frame.AckPolicy = .normal_ack,
    /// B7 A-MSDU Present（9.2.4.5.9，p.652）：1 表示帧体是一个完整的 A-MSDU，0 表示是
    /// 一个 MSDU 或其分片。B7 为 Reserved 的行里是 null。
    a_msdU_present: ?bool = null,
    tail: Tail = .{ .txop_duration_requested = 0 },
};

/// Queue Size = 255：大小未知或未指定（p.651）。
pub const queue_size_unknown: u8 = 255;
/// Queue Size = 254 的门槛：超过 64 768 字节（p.651）。
pub const queue_size_more_than: u32 = 253 * 256;

/// 把缓冲字节数折成 Queue Size（9.2.4.5.6，p.651）：向上取整到 256 的整数倍；
/// 超过 64 768 字节记 254；0 只表示队列里没有东西。
pub fn encodeQueueSize(octets: u32) u8 {
    if (octets > queue_size_more_than) return 254;
    return @intCast((octets + 255) / 256);
}

/// TXOP Limit / TXOP Duration Requested 换成 µs（单位 32 µs，p.651–652）。
pub fn txopDurationUs(value: u8) u32 {
    return @as(u32, value) * txop_unit_us;
}

/// 拆开 16 位的 QoS Control 字段。Table 9-6 标 Reserved 的位不为 0 时返回
/// `ReservedBitsSet`。
pub fn decode(layout: Layout, w: u16) LayoutError!Fields {
    const bit4 = (w >> 4) & 1 != 0;
    const bit7 = (w >> 7) & 1 != 0;
    const high: u8 = @truncate(w >> 8);
    var f = Fields{
        .tid = @truncate(w),
        .ack_policy = @fromBackingInt(@intCast(@as(u2, @truncate(w >> 5)))),
        .tail = undefined,
    };
    switch (layout) {
        .hc_cf_poll => {
            if (bit7) return error.ReservedBitsSet;
            f.eosp = bit4;
            f.tail = .{ .txop_limit = high };
        },
        .hc_data_cf_poll => {
            f.eosp = bit4;
            f.a_msdU_present = bit7;
            f.tail = .{ .txop_limit = high };
        },
        .hc_data => {
            f.eosp = bit4;
            f.a_msdU_present = bit7;
            f.tail = .{ .ap_ps_buffer_state = try decodeApPsBufferState(high) };
        },
        .hc_null => {
            if (bit7) return error.ReservedBitsSet;
            f.eosp = bit4;
            f.tail = .{ .ap_ps_buffer_state = try decodeApPsBufferState(high) };
        },
        .sta_data => {
            f.a_msdU_present = bit7;
            f.tail = staTail(bit4, high);
        },
        .sta_null => {
            if (bit7) return error.ReservedBitsSet;
            f.tail = staTail(bit4, high);
        },
        .mesh => {
            if (w & 0xf800 != 0) return error.ReservedBitsSet;
            f.eosp = bit4;
            f.a_msdU_present = bit7;
            f.tail = .{ .mesh = .{
                .control_present = high & 1 != 0,
                .power_save_level = high & 2 != 0,
                .rspi = high & 4 != 0,
            } };
        },
    }
    return f;
}

fn staTail(bit4: bool, high: u8) Tail {
    return if (bit4) .{ .queue_size = high } else .{ .txop_duration_requested = high };
}

fn decodeApPsBufferState(high: u8) LayoutError!ApPsBufferState {
    if (high & 1 != 0) return error.ReservedBitsSet; // B8 Reserved
    const s = ApPsBufferState{
        .indicated = high & 2 != 0,
        .highest_priority_ac = @truncate(high >> 2),
        .buffered_load = @truncate(high >> 4),
    };
    _ = try s.octet();
    return s;
}

/// 拼出 16 位的 QoS Control 字段。子字段与这一行布局对不上（例如给非 AP STA 的行
/// 填了 EOSP）时返回 `LayoutMismatch`。
pub fn encode(layout: Layout, f: Fields) LayoutError!u16 {
    var w: u16 = @as(u16, f.tid) | (@as(u16, @backingInt(f.ack_policy)) << 5);
    if (layout.hasEosp()) {
        w |= @as(u16, @intFromBool(f.eosp orelse return error.LayoutMismatch)) << 4;
    } else if (f.eosp != null) {
        return error.LayoutMismatch;
    }
    if (layout.hasAMsdU()) {
        w |= @as(u16, @intFromBool(f.a_msdU_present orelse return error.LayoutMismatch)) << 7;
    } else if (f.a_msdU_present != null) {
        return error.LayoutMismatch;
    }
    const high: u8 = switch (layout) {
        .hc_cf_poll, .hc_data_cf_poll => switch (f.tail) {
            .txop_limit => |v| v,
            else => return error.LayoutMismatch,
        },
        .hc_data, .hc_null => switch (f.tail) {
            .ap_ps_buffer_state => |s| try s.octet(),
            else => return error.LayoutMismatch,
        },
        .sta_data, .sta_null => switch (f.tail) {
            .txop_duration_requested => |v| v,
            .queue_size => |v| blk: {
                w |= 1 << 4;
                break :blk v;
            },
            else => return error.LayoutMismatch,
        },
        .mesh => switch (f.tail) {
            .mesh => |m| @as(u8, @intFromBool(m.control_present)) |
                (@as(u8, @intFromBool(m.power_save_level)) << 1) |
                (@as(u8, @intFromBool(m.rspi)) << 2),
            else => return error.LayoutMismatch,
        },
    };
    return w | (@as(u16, high) << 8);
}

/// 先按 `layout` 拆开，再核对与 Frame Control 有关的两个保留条件：
/// 9.2.4.5.11（p.653）：Power Management 子字段为 0 时 Mesh Power Save Level 是 Reserved；
/// 9.2.4.5.12（p.653）：RSPI 在组地址帧里是 Reserved。
pub fn decodeFor(fc: frame.FrameControl, group_addressed: bool, layout: Layout, w: u16) LayoutError!Fields {
    const f = try decode(layout, w);
    if (layout == .mesh) {
        const m = f.tail.mesh;
        if (m.power_save_level and !fc.power_management) return error.ReservedBitsSet;
        if (m.rspi and group_addressed) return error.ReservedBitsSet;
    }
    return f;
}

pub const AckPolicyError = error{
    GroupMustBeNoAck,
    QosNullMustBeNormalAck,
    CfPollMustBeNoExplicitAck,
};

/// 9.2.4.5.4（Table 9-9，p.650–651）里对 Ack Policy 取值的三条约束：
///   * 组地址的 QoS 帧一律 No Ack（除非这个 TID 有 block ack 协议，组地址 QoS Null 也要 No Ack）；
///   * 非 DMG STA 把单独寻址的 QoS Null 的 Ack Policy 设成 Normal Ack；
///   * QoS CF-Poll、QoS CF-Ack +CF-Poll 的 Ack Policy 是 No explicit acknowledgment or PSMP Ack。
pub fn checkAckPolicy(fc: frame.FrameControl, group_addressed: bool, policy: frame.AckPolicy, tid_has_block_ack: bool) AckPolicyError!void {
    if (fc.type != .data or !fc.isQoSData()) return;
    if (group_addressed) {
        if (policy != .no_ack and (fc.subtype == 12 or !tid_has_block_ack)) return error.GroupMustBeNoAck;
        return;
    }
    switch (fc.subtype) {
        12 => if (policy != .normal_ack) return error.QosNullMustBeNormalAck,
        14, 15 => if (policy != .no_explicit_ack) return error.CfPollMustBeNoExplicitAck,
        else => {},
    }
}

// ---------------------------------------------------------------------------
// 4) QoS Capability 与 EDCA Parameter Set 元素
// ---------------------------------------------------------------------------

/// Max SP Length（Table 9-48，p.740）：取值是 QoS Info 的 B5、B6。
pub const MaxSpLength = enum(u2) {
    /// B5=0 B6=0：服务期里把缓冲的 BU 全部收下。
    all = 0b00,
    /// B5=1 B6=0：每个服务期最多两个 BU。
    two = 0b01,
    /// B5=0 B6=1：每个服务期最多四个 BU。
    four = 0b10,
    /// B5=1 B6=1：每个服务期最多六个 BU。
    six = 0b11,

    /// 每个服务期的上限；`all` 是 null。
    pub fn limit(self: MaxSpLength) ?u8 {
        return switch (self) {
            .all => null,
            .two => 2,
            .four => 4,
            .six => 6,
        };
    }
};

/// 非 AP STA 发的 QoS Info（Figure 9-83，p.740）。放在 (Re)Association Request 的
/// QoS Capability 元素里。
pub const QosInfoSta = packed struct(u8) {
    /// B0–B3：各 AC 的 U-APSD Flag。1 表示这个 AC 既是 trigger-enabled 又是 delivery-enabled。
    uapsd_vo: bool = false,
    uapsd_vi: bool = false,
    uapsd_bk: bool = false,
    uapsd_be: bool = false,
    /// B4
    q_ack: bool = false,
    /// B5–B6
    max_sp_length: MaxSpLength = .all,
    /// B7：能处理 More Data=1 的 Ack 帧并保持清醒。
    more_data_ack: bool = false,

    pub fn octet(self: QosInfoSta) u8 {
        return @bitCast(self);
    }

    pub fn fromOctet(o: u8) QosInfoSta {
        return @bitCast(o);
    }

    /// B0–B3 原样取出：Figure 9-83 的位次（B0 AC_VO、B1 AC_VI、B2 AC_BK、B3 AC_BE）。
    pub fn uapsdMask(self: QosInfoSta) u4 {
        return @truncate(self.octet());
    }

    /// 同一组 U-APSD Flag 换成 ACI 次序的掩码（bit i = ACI i：B0 AC_BE、B1 AC_BK、
    /// B2 AC_VI、B3 AC_VO），给按 AC 索引的表用。
    pub fn acMask(self: QosInfoSta) u4 {
        var m: u4 = 0;
        if (self.uapsd_be) m |= Ac.be.mask();
        if (self.uapsd_bk) m |= Ac.bk.mask();
        if (self.uapsd_vi) m |= Ac.vi.mask();
        if (self.uapsd_vo) m |= Ac.vo.mask();
        return m;
    }

    /// 这个 AC 是否 trigger- 且 delivery-enabled。
    pub fn uapsdEnabled(self: QosInfoSta, ac: Ac) bool {
        return self.acMask() & ac.mask() != 0;
    }

    /// 四个 AC 都 delivery-enabled（11.2.3.8 b：此时 TIM 位置 1 后发 trigger 帧）。
    pub fn allDeliveryEnabled(self: QosInfoSta) bool {
        return self.uapsdMask() == 0xf;
    }
};

/// AP 发的 QoS Info（Figure 9-82，p.739）。放在 Beacon 的 QoS Capability 元素或 EDCA
/// Parameter Set 元素里。
pub const QosInfoAp = packed struct(u8) {
    /// B0–B3：EDCA Parameter Set Update Count（10.2.4.2，p.1299）。
    edca_update_count: u4 = 0,
    /// B4
    q_ack: bool = false,
    /// B5：能处理 Queue Size。
    queue_request: bool = false,
    /// B6：能处理 TXOP Duration Requested。
    txop_request: bool = false,
    /// B7
    reserved: u1 = 0,

    pub fn octet(self: QosInfoAp) u8 {
        return @bitCast(self);
    }

    pub fn fromOctet(o: u8) QosInfoAp {
        return @bitCast(o);
    }
};

pub const BuildError = error{ NoRoom, ApsdNotSupported };

/// QoS Capability 元素（9.4.2.35，p.916；Figure 9-293）：Element ID 46、Length 1、QoS Info。
/// `ap_apsd` 是 AP 的 Capability Information 里 APSD 子字段的值。AP 不支持 APSD 时，
/// U-APSD Flag 要全 0、Max SP Length 是 Reserved（p.740）；STA 这时还要求 U-APSD 就返回
/// `ApsdNotSupported`。
pub fn buildQosCapability(sta: QosInfoSta, ap_apsd: bool, out: []u8) BuildError!usize {
    if (!ap_apsd and (sta.uapsdMask() != 0 or sta.max_sp_length != .all)) return error.ApsdNotSupported;
    if (out.len < 3) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.qos_capability);
    out[1] = 1;
    out[2] = sta.octet();
    return 3;
}

/// 元素体（不含 Element ID 与 Length）里的那一字节 QoS Info。调用方按发送方决定用
/// `QosInfoSta.fromOctet` 还是 `QosInfoAp.fromOctet` 解释。
pub fn parseQosCapability(body: []const u8) error{ Truncated, TooLong }!u8 {
    if (body.len < 1) return error.Truncated;
    if (body.len > 1) return error.TooLong;
    return body[0];
}

/// Length (18)（Figure 9-261，p.897）：QoS Info 1 + Reserved 1 + 4 × Parameter Record 4。
pub const edca_param_set_len = 18;

/// 一个 AC 的 Parameter Record（Figure 9-262–9-264，p.897–898）。
pub const EdcaRecord = struct {
    aifsn: u4,
    /// Admission Control Mandatory（B4）。
    acm: bool,
    /// ACI（B5–B6，Table 9-136）。
    aci: u2,
    ecwmin: u4,
    ecwmax: u4,
    txop_limit: u16,

    /// CW = 2^ECW − 1（p.898）；ECW 最大 15，CW 最大 32 767。
    pub fn cwOf(ecw: u4) u16 {
        return (@as(u16, 1) << ecw) - 1;
    }

    pub fn cwmin(self: EdcaRecord) u16 {
        return cwOf(self.ecwmin);
    }

    pub fn cwmax(self: EdcaRecord) u16 {
        return cwOf(self.ecwmax);
    }

    pub fn params(self: EdcaRecord) AcParams {
        return .{ .aifsn = self.aifsn, .cwmin = self.cwmin(), .cwmax = self.cwmax(), .txop_limit = self.txop_limit };
    }

    pub fn fromOctets(b: *const [4]u8) error{BadAifsn}!EdcaRecord {
        if (b[0] & 0x0f < 2) return error.BadAifsn; // 「The minimum value of the AIFSN subfield is 2」（p.898）
        return .{
            .aifsn = @truncate(b[0]),
            .acm = b[0] & 0x10 != 0,
            .aci = @truncate(b[0] >> 5),
            .ecwmin = @truncate(b[1]),
            .ecwmax = @truncate(b[1] >> 4),
            .txop_limit = std.mem.readInt(u16, b[2..4], .little),
        };
    }
};

/// EDCA Parameter Set 元素体。`records` 按元素里的顺序（AC_BE、AC_BK、AC_VI、AC_VO），
/// 取某个 AC 的参数用 `record()`，按 ACI 字段找，不依赖顺序。
pub const EdcaParameterSet = struct {
    qos_info: QosInfoAp,
    records: [4]EdcaRecord,

    pub fn record(self: EdcaParameterSet, ac: Ac) ?EdcaRecord {
        for (self.records) |r| {
            if (r.aci == ac.index()) return r;
        }
        return null;
    }
};

pub const EdcaError = error{ Truncated, TooLong, BadAifsn };

/// 解析 EDCA Parameter Set 的元素体（9.4.2.29，p.897–898）。保留位（Reserved 字节、
/// ACI/AIFSN 的 B7、QoS Info 的 B7）接收时忽略。
pub fn parseEdcaParameterSet(body: []const u8) EdcaError!EdcaParameterSet {
    if (body.len < edca_param_set_len) return error.Truncated;
    if (body.len > edca_param_set_len) return error.TooLong;
    var set = EdcaParameterSet{ .qos_info = QosInfoAp.fromOctet(body[0]), .records = undefined };
    for (&set.records, 0..) |*r, i| {
        r.* = try EdcaRecord.fromOctets(body[2 + 4 * i ..][0..4]);
    }
    return set;
}

// ---------------------------------------------------------------------------
// 5) QoS 数据帧
// ---------------------------------------------------------------------------

/// 一帧解析完的 QoS 数据帧。
pub const QosFrame = struct {
    frame: frame.Frame,
    layout: Layout,
    qos: Fields,
    /// TID 0–7 对应的 AC；TID 8–15 是 TSID 时为 null。
    ac: ?Ac,
};

pub const ParseError = frame.ParseError || LayoutError;

/// 解析一帧带 QoS Control 的 Data 帧（3 地址或 4 地址，带不带 FCS 都可以）。发送方由
/// To DS / From DS 推断。不是 QoS 数据帧时返回 `NotQosFrame`。
pub fn parse(mpdu: []const u8, mode: frame.FcsMode) ParseError!QosFrame {
    const f = try frame.parse(mpdu, mode);
    const sender = try senderOf(f.hdr.fc);
    const layout = try layoutFor(f.hdr.fc, sender);
    const fields = try decodeFor(f.hdr.fc, f.isGroupAddressed(), layout, f.hdr.qos.?.word());
    return .{ .frame = f, .layout = layout, .qos = fields, .ac = acForTid(fields.tid) };
}

pub const TxParams = struct {
    sender: Sender,
    /// Data 子类型（8–15 里的一个 QoS 子类型）。
    subtype: u4,
    addr1: frame.Mac,
    addr2: frame.Mac,
    addr3: frame.Mac,
    addr4: ?frame.Mac = null,
    duration_id: frame.DurationId = .{ .duration = 0 },
    seq_ctrl: u16 = 0,
    qos: Fields,
    power_management: bool = false,
    more_data: bool = false,
    retry: bool = false,
    protected_frame: bool = false,
    ht_control: ?[4]u8 = null,
    body: []const u8 = &.{},
};

pub const SealError = frame.LayoutError || LayoutError || error{NotGroupAddressed};

/// 拼一帧带 QoS Control 的 Data 帧（3 地址或 4 地址），返回写入的字节数（含帧尾 FCS
/// 时含 FCS）。To DS / From DS 按 Table 9-3（p.641）由 `sender` 决定：HC 发的帧
/// From DS=1，非 AP STA 发的帧 To DS=1；mesh STA 给出 `addr4` 时是四地址（两个都是
/// 1），不给时必须是组地址的三地址 mesh 帧（From DS=1）。
/// A-MSDU Present=1 时帧体不能为空（10.12，p.1365）。
pub fn seal(p: TxParams, with_fcs: bool, out: []u8) SealError!usize {
    var to_ds = false;
    var from_ds = false;
    switch (p.sender) {
        .hc => from_ds = true,
        .non_ap_sta => to_ds = true,
        .mesh => {
            if (p.addr4 != null) {
                to_ds = true;
                from_ds = true;
            } else {
                if (!frame.isGroupAddress(p.addr1)) return error.NotGroupAddressed;
                from_ds = true;
            }
        },
    }
    const fc = frame.FrameControl{
        .type = .data,
        .subtype = p.subtype,
        .to_ds = to_ds,
        .from_ds = from_ds,
        .power_management = p.power_management,
        .more_data = p.more_data,
        .retry = p.retry,
        .protected_frame = p.protected_frame,
        .order_htc = p.ht_control != null,
    };
    const layout = try layoutFor(fc, p.sender);
    if ((p.qos.a_msdU_present orelse false) and p.body.len == 0) return error.AmsduWithoutBody;
    const word = try encode(layout, p.qos);
    // 与 Frame Control 有关的保留条件（mesh 的两项）在发送侧也要成立。
    _ = try decodeFor(fc, frame.isGroupAddress(p.addr1), layout, word);
    const hdr = frame.Header{
        .fc = fc,
        .duration_id = p.duration_id,
        .addr1 = p.addr1,
        .addr2 = p.addr2,
        .addr3 = p.addr3,
        .seq_ctrl = p.seq_ctrl,
        .addr4 = p.addr4,
        .qos = frame.QosControl.fromWord(word),
        .ht_control = p.ht_control,
    };
    return frame.seal(hdr, p.body, with_fcs, out);
}

/// 非 AP STA 发给 AP 的 QoS Data / QoS Null 的子字段：TID 用 EDCA 的 0–7（Table 9-8）。
/// 这两行布局里没有 EOSP。QoS Null 的 B7 是 Reserved，`a_msdU_present` 要给 null。
pub fn staFields(tid: u8, ack_policy: frame.AckPolicy, a_msdU_present: ?bool, tail: Tail) TidError!Fields {
    const t = try edcaTid(tid);
    return .{ .tid = @intCast(t), .ack_policy = ack_policy, .a_msdU_present = a_msdU_present, .tail = tail };
}
