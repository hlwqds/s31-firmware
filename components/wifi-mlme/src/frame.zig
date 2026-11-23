//! wifi-mlme：MAC 帧头与帧封装（IEEE Std 802.11-2016 Clause 9）。
//!
//! 本文件只做三件事，全部是「字节 ↔ 结构」的纯逻辑：
//!
//!   1. Frame Control 的编/解码（9.2.4.1，p.638–644），含 Type/Subtype 表
//!      （Table 9-1，p.639–640）与 Control Frame Extension 的另一种布局
//!      （Figure 9-3，p.638）；
//!   2. 帧头各字段的定长布局（9.2.3 Figure 9-1，p.638；管理帧 Figure 9-58，
//!      p.692；控制帧 9.3.1.2–9.3.1.7，p.670–672）：解析出地址、Sequence
//!      Control、QoS Control、HT Control 与 Frame Body 的切片；
//!   3. FCS（9.2.4.8，p.665）：按原文实现的 CRC-32，并附一份逐位移位的
//!      参考除法，用来互相对拍。
//!
//! 页码均为 IEEE Std 802.11-2016 的印刷页码。本文件不 import 任何硬件
//! 相关代码，只 import `std`。

const std = @import("std");

pub const mac_len = 6;
pub const fcs_len = 4;
/// 最小帧格式：Frame Control(2) + Duration/ID(2) + Address 1(6) + FCS(4)
/// （9.2.3，p.637：「The first three fields ... and the last field (FCS)
/// ... constitute the minimal frame format and are present in all frames」）。
pub const min_frame_len = 2 + 2 + mac_len + fcs_len;

pub const Mac = [mac_len]u8;
pub const broadcast: Mac = @splat(0xff);

/// Individual/Group 位是首字节的 B0（9.2.2，p.636）；为 1 即组地址。
pub fn isGroupAddress(mac: Mac) bool {
    return (mac[0] & 0x01) != 0;
}

pub fn isBroadcast(mac: Mac) bool {
    return std.mem.eql(u8, &mac, &broadcast);
}

// ---------------------------------------------------------------------------
// Type / Subtype（Table 9-1，p.639–640；数值按表里的二进制写法）
// ---------------------------------------------------------------------------

pub const FrameType = enum(u2) {
    mgmt = 0b00,
    control = 0b01,
    data = 0b10,
    extension = 0b11,

    pub fn name(self: FrameType) []const u8 {
        return switch (self) {
            .mgmt => "mgmt",
            .control => "control",
            .data => "data",
            .extension => "extension",
        };
    }
};

pub const MgmtSubtype = enum(u4) {
    assoc_req = 0b0000,
    assoc_resp = 0b0001,
    reassoc_req = 0b0010,
    reassoc_resp = 0b0011,
    probe_req = 0b0100,
    probe_resp = 0b0101,
    timing_advertisement = 0b0110,
    reserved_7 = 0b0111,
    beacon = 0b1000,
    atim = 0b1001,
    disassoc = 0b1010,
    auth = 0b1011,
    deauth = 0b1100,
    action = 0b1101,
    action_no_ack = 0b1110,
    reserved_15 = 0b1111,

    pub fn name(self: MgmtSubtype) []const u8 {
        return switch (self) {
            .assoc_req => "assoc_req",
            .assoc_resp => "assoc_resp",
            .reassoc_req => "reassoc_req",
            .reassoc_resp => "reassoc_resp",
            .probe_req => "probe_req",
            .probe_resp => "probe_resp",
            .timing_advertisement => "timing_advertisement",
            .reserved_7 => "reserved",
            .beacon => "beacon",
            .atim => "atim",
            .disassoc => "disassoc",
            .auth => "auth",
            .deauth => "deauth",
            .action => "action",
            .action_no_ack => "action_no_ack",
            .reserved_15 => "reserved",
        };
    }
};

pub const DataSubtype = enum(u4) {
    data = 0b0000,
    data_cf_ack = 0b0001,
    data_cf_poll = 0b0010,
    data_cf_ack_cf_poll = 0b0011,
    null = 0b0100,
    cf_ack = 0b0101,
    cf_poll = 0b0110,
    cf_ack_cf_poll = 0b0111,
    qos_data = 0b1000,
    qos_data_cf_ack = 0b1001,
    qos_data_cf_poll = 0b1010,
    qos_data_cf_ack_cf_poll = 0b1011,
    qos_null = 0b1100,
    reserved_13 = 0b1101,
    qos_cf_poll = 0b1110,
    qos_cf_ack_cf_poll = 0b1111,
};

pub const ControlSubtype = enum(u4) {
    reserved_0 = 0b0000,
    reserved_1 = 0b0001,
    reserved_2 = 0b0010,
    reserved_3 = 0b0011,
    beamforming_report_poll = 0b0100,
    vht_ndp_announcement = 0b0101,
    control_frame_extension = 0b0110,
    control_wrapper = 0b0111,
    block_ack_req = 0b1000,
    block_ack = 0b1001,
    ps_poll = 0b1010,
    rts = 0b1011,
    cts = 0b1100,
    ack = 0b1101,
    cf_end = 0b1110,
    cf_end_cf_ack = 0b1111,
};

/// Control Frame Extension 的取值（Table 9-2，p.640–641），占 FC 的 B8–B11。
pub const ControlFrameExtension = enum(u4) {
    reserved_0 = 0b0000,
    reserved_1 = 0b0001,
    poll = 0b0010,
    spr = 0b0011,
    grant = 0b0100,
    dmg_cts = 0b0101,
    dmg_dts = 0b0110,
    grant_ack = 0b0111,
    ssw = 0b1000,
    ssw_feedback = 0b1001,
    ssw_ack = 0b1010,
    _,
};

// ---------------------------------------------------------------------------
// Frame Control（9.2.4.1）
// ---------------------------------------------------------------------------

pub const FrameControl = struct {
    /// B0–B1。本标准取 0，其余保留（9.2.4.1.2，p.638）。
    protocol_version: u2 = 0,
    /// B2–B3。
    type: FrameType = .mgmt,
    /// B4–B7。Data 帧的 B7 同时是 QoS 子字段（9.2.4.1.3，p.639）。
    subtype: u4 = 0,
    /// B8。
    to_ds: bool = false,
    /// B9。
    from_ds: bool = false,
    /// B10。
    more_fragments: bool = false,
    /// B11。
    retry: bool = false,
    /// B12。
    power_management: bool = false,
    /// B13。
    more_data: bool = false,
    /// B14（9.2.4.1.9，p.644）。
    protected_frame: bool = false,
    /// B15：非 QoS Data 帧里表示 StrictlyOrdered，QoS Data / 管理帧里表示
    /// 带 HT Control 字段（9.2.4.1.10，p.644）。
    order_htc: bool = false,
    /// 仅当 Type=Control 且 Subtype=6 时有意义：此时 B8–B11 不再是
    /// To DS / From DS / More Fragments / Retry，而是 4 位扩展值
    /// （9.2.4.1.1 与 Figure 9-3，p.638）。
    control_frame_extension: u4 = 0,

    /// Type=Control 且 Subtype=6 时用 Figure 9-3 的布局（9.2.4.1.1，p.638）。
    pub fn usesControlExtensionLayout(self: FrameControl) bool {
        return self.type == .control and self.subtype == @backingInt(ControlSubtype.control_frame_extension);
    }

    pub fn isQoSData(self: FrameControl) bool {
        return self.type == .data and self.subtype >= @backingInt(DataSubtype.qos_data);
    }

    pub fn isMgmt(self: FrameControl, subtype: MgmtSubtype) bool {
        return self.type == .mgmt and self.subtype == @backingInt(subtype);
    }

    /// Data 帧的 B6=1 表示该子类型不含 Frame Body（9.2.4.1.3，p.640：
    /// 「bit 6 is set to 1 in data subtypes that contain no Frame Body field」）。
    pub fn hasFrameBody(self: FrameControl) bool {
        return !(self.type == .data and (self.subtype & 0b0100) != 0);
    }

    /// 是否带 HT Control 字段：管理帧与 QoS Data 帧由 B15 决定
    /// （9.2.4.6.1，p.654）；非 QoS Data 帧的 B15 是 StrictlyOrdered，不是 HT Control。
    pub fn hasHtControl(self: FrameControl) bool {
        return self.order_htc and (self.type == .mgmt or self.isQoSData());
    }

    pub fn encode(self: FrameControl) u16 {
        var w: u16 = @as(u16, self.protocol_version) |
            (@as(u16, @backingInt(self.type)) << 2) |
            (@as(u16, self.subtype) << 4);
        if (self.usesControlExtensionLayout()) {
            w |= @as(u16, self.control_frame_extension) << 8;
        } else {
            w |= @as(u16, @intFromBool(self.to_ds)) << 8;
            w |= @as(u16, @intFromBool(self.from_ds)) << 9;
            w |= @as(u16, @intFromBool(self.more_fragments)) << 10;
            w |= @as(u16, @intFromBool(self.retry)) << 11;
        }
        w |= @as(u16, @intFromBool(self.power_management)) << 12;
        w |= @as(u16, @intFromBool(self.more_data)) << 13;
        w |= @as(u16, @intFromBool(self.protected_frame)) << 14;
        w |= @as(u16, @intFromBool(self.order_htc)) << 15;
        return w;
    }

    pub fn decode(word: u16) FrameControl {
        const fc = FrameControl{
            .protocol_version = @truncate(word),
            .type = @fromBackingInt(@intCast(@as(u2, @truncate(word >> 2)))),
            .subtype = @truncate(word >> 4),
            .control_frame_extension = @truncate(word >> 8),
        };
        if (fc.usesControlExtensionLayout()) {
            // Figure 9-3：B8–B11 是扩展值，B12–B15 仍是 Power Management 等四个标志。
            return .{
                .protocol_version = fc.protocol_version,
                .type = fc.type,
                .subtype = fc.subtype,
                .control_frame_extension = fc.control_frame_extension,
                .power_management = (word >> 12) & 1 != 0,
                .more_data = (word >> 13) & 1 != 0,
                .protected_frame = (word >> 14) & 1 != 0,
                .order_htc = (word >> 15) & 1 != 0,
            };
        }
        return .{
            .protocol_version = fc.protocol_version,
            .type = fc.type,
            .subtype = fc.subtype,
            .to_ds = (word >> 8) & 1 != 0,
            .from_ds = (word >> 9) & 1 != 0,
            .more_fragments = (word >> 10) & 1 != 0,
            .retry = (word >> 11) & 1 != 0,
            .power_management = (word >> 12) & 1 != 0,
            .more_data = (word >> 13) & 1 != 0,
            .protected_frame = (word >> 14) & 1 != 0,
            .order_htc = (word >> 15) & 1 != 0,
        };
    }

    /// 人读的 `<type>/<subtype>`，保留子类型原样给数字。
    pub fn describe(self: FrameControl, buf: []u8) []const u8 {
        const sub: ?[]const u8 = switch (self.type) {
            .mgmt => @as(?[]const u8, std.enums.tagName(MgmtSubtype, @fromBackingInt(@intCast(self.subtype)))),
            .control => std.enums.tagName(ControlSubtype, @fromBackingInt(@intCast(self.subtype))),
            .data => std.enums.tagName(DataSubtype, @fromBackingInt(@intCast(self.subtype))),
            .extension => null,
        };
        if (sub) |s| return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.type.name(), s }) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{s}/{d}", .{ self.type.name(), self.subtype }) catch buf[0..0];
    }
};

// ---------------------------------------------------------------------------
// Duration/ID（9.2.4.2，p.644；Table 9-5，p.645）
// ---------------------------------------------------------------------------

pub const DurationId = union(enum) {
    /// B15=0：Duration 值（微秒），0–32767。
    duration: u16,
    /// B15=1、B14=0、B0–B13=0：CFP 期间 PCF 下的固定值（32 768）。
    pcf,
    /// B15=1、B14=1、B0–B13=1..2007：PS-Poll 帧里的 AID。
    aid: u16,
    /// Table 9-5 里标为 Reserved 的编码，原样保留 16 位取值。
    reserved: u16,

    pub fn word(self: DurationId) u16 {
        return switch (self) {
            .duration => |v| blk: {
                std.debug.assert(v <= 0x7fff);
                break :blk v;
            },
            .pcf => 0x8000,
            .aid => |a| 0xc000 | a,
            .reserved => |w| w,
        };
    }
};

pub fn decodeDurationId(word: u16) DurationId {
    if (word & 0x8000 == 0) return .{ .duration = word & 0x7fff };
    if (word & 0x4000 == 0) {
        if (word & 0x3fff == 0) return .pcf;
        return .{ .reserved = word };
    }
    const low: u16 = word & 0x3fff;
    if (low >= 1 and low <= 2007) return .{ .aid = low };
    return .{ .reserved = word };
}

// ---------------------------------------------------------------------------
// QoS Control（9.2.4.5，p.647–653；Table 9-6，p.648）
// ---------------------------------------------------------------------------

pub const AckPolicy = enum(u2) {
    /// B5=0,B6=0：Normal Ack 或 Implicit Block Ack Request（Table 9-9，p.650）。
    normal_ack = 0b00,
    /// B5=1,B6=0：No Ack。
    no_ack = 0b01,
    /// B5=0,B6=1：No explicit acknowledgment 或 PSMP Ack。
    no_explicit_ack = 0b10,
    /// B5=1,B6=1：Block Ack。
    block_ack = 0b11,
};

pub const QosControl = struct {
    /// B0–B3（9.2.4.5.2，p.649）。
    tid: u4 = 0,
    /// B4：HC 发的帧里是 EOSP，非 AP STA 的 QoS Data 里按 bit 4 取 0/1 选择
    /// 「TXOP Duration Requested」或「Queue Size」布局（Table 9-6，p.648）。
    /// 含义随发送方与帧类型变化，这里只保留原值。
    bit4: bool = false,
    /// B5–B6（9.2.4.5.4，p.650）。
    ack_policy: AckPolicy = .normal_ack,
    /// B7：A-MSDU Present（9.2.4.5.9，p.652）。
    a_msdU_present: bool = false,
    /// B8–B15：TXOP Limit / AP PS Buffer State / TXOP Duration Requested /
    /// Queue Size 等，布局取决于 Table 9-6 的行；原样保留。
    high: u8 = 0,

    pub fn word(self: QosControl) u16 {
        return @as(u16, self.tid) |
            (@as(u16, @intFromBool(self.bit4)) << 4) |
            (@as(u16, @backingInt(self.ack_policy)) << 5) |
            (@as(u16, @intFromBool(self.a_msdU_present)) << 7) |
            (@as(u16, self.high) << 8);
    }

    pub fn fromWord(w: u16) QosControl {
        return .{
            .tid = @truncate(w),
            .bit4 = (w >> 4) & 1 != 0,
            .ack_policy = @fromBackingInt(@intCast(@as(u2, @truncate(w >> 5)))),
            .a_msdU_present = (w >> 7) & 1 != 0,
            .high = @truncate(w >> 8),
        };
    }
};

// ---------------------------------------------------------------------------
// 帧头布局（Figure 9-1，p.638；Figure 9-58，p.692；9.3.1.2–9.3.1.7，p.670–672）
// ---------------------------------------------------------------------------

pub const LayoutError = error{
    /// Control 子类型 4–9（Beamforming Report Poll、VHT NDP Announcement、
    /// Control Frame Extension、Control Wrapper、BlockAckReq、BlockAck）的
    /// 帧头布局本组件没有逐条核对原文，不做解析与编码。
    UnsupportedSubtype,
    /// Extension 帧只解析「最小帧格式」，不支持编码。
    UnsupportedType,
    MissingAddress,
    UnexpectedAddress,
    MissingSequenceControl,
    UnexpectedSequenceControl,
    MissingQosControl,
    UnexpectedQosControl,
    MissingHtControl,
    UnexpectedHtControl,
    /// Null 类子类型（无 Frame Body）却带了帧体。
    UnexpectedBody,
    NoRoom,
};

pub fn headerLen(fc: FrameControl) LayoutError!u8 {
    return switch (fc.type) {
        // Figure 9-58（p.692）：2+2+6+6+6+2，+HTC 时再加 4。
        .mgmt => 24 + @as(u8, if (fc.hasHtControl()) 4 else 0),
        // Figure 9-1（p.638）：地址 4 仅 To DS=From DS=1 时存在（Table 9-3，p.641）；
        // QoS Control 仅 QoS 子类型的 Data 帧存在（9.2.4.5.1，p.648）。
        .data => blk: {
            var n: u8 = 24;
            if (fc.to_ds and fc.from_ds) n += 6;
            if (fc.isQoSData()) n += 2;
            if (fc.hasHtControl()) n += 4;
            break :blk n;
        },
        .control => switch (fc.subtype) {
            // PS-Poll（Figure 9-23）、CF-End（9-24）、CF-End+CF-Ack（9-25）、
            // RTS（9-20）：两个地址，16 字节。
            10, 11, 14, 15 => 16,
            // CTS（Figure 9-21）、Ack（9-22）：一个地址，10 字节。
            12, 13 => 10,
            else => return error.UnsupportedSubtype,
        },
        // Extension 帧：只解析 FC + Duration/ID + Address 1（9.3.4.1，p.716）。
        .extension => 10,
    };
}

/// 帧头字段。`addr2`/`addr3`/`addr4`/`seq_ctrl`/`qos`/`ht_control` 是否
/// 必须存在由 `fc` 决定，`validate` 负责核对（规则见 `headerLen` 的出处）。
pub const Header = struct {
    fc: FrameControl = .{},
    duration_id: DurationId = .{ .duration = 0 },
    addr1: Mac = @splat(0),
    addr2: ?Mac = null,
    addr3: ?Mac = null,
    /// B0–B3 Fragment Number，B4–B15 Sequence Number（Figure 9-4，p.647）。
    seq_ctrl: ?u16 = null,
    addr4: ?Mac = null,
    qos: ?QosControl = null,
    ht_control: ?[4]u8 = null,

    pub fn len(self: Header) LayoutError!u8 {
        return headerLen(self.fc);
    }

    pub fn sequenceNumber(self: Header) u16 {
        return (self.seq_ctrl orelse 0) >> 4;
    }

    pub fn fragmentNumber(self: Header) u4 {
        return @truncate(self.seq_ctrl orelse 0);
    }

    pub fn validate(self: Header) LayoutError!void {
        const has_ht = self.ht_control != null;
        switch (self.fc.type) {
            .extension => return error.UnsupportedType,
            .control => {
                if (headerLen(self.fc)) |_| {} else |_| return error.UnsupportedSubtype;
                const wants_addr2 = switch (self.fc.subtype) {
                    12, 13 => false,
                    else => true,
                };
                if (wants_addr2 and self.addr2 == null) return error.MissingAddress;
                if (!wants_addr2 and self.addr2 != null) return error.UnexpectedAddress;
                if (self.addr3 != null or self.addr4 != null) return error.UnexpectedAddress;
                if (self.seq_ctrl != null) return error.UnexpectedSequenceControl;
                if (self.qos != null) return error.UnexpectedQosControl;
                if (has_ht) return error.UnexpectedHtControl;
            },
            .mgmt => {
                if (self.addr2 == null or self.addr3 == null) return error.MissingAddress;
                if (self.addr4 != null) return error.UnexpectedAddress;
                if (self.seq_ctrl == null) return error.MissingSequenceControl;
                if (self.qos != null) return error.UnexpectedQosControl;
                if (has_ht != self.fc.hasHtControl()) {
                    return if (has_ht) error.UnexpectedHtControl else error.MissingHtControl;
                }
            },
            .data => {
                if (self.addr2 == null or self.addr3 == null) return error.MissingAddress;
                if (self.seq_ctrl == null) return error.MissingSequenceControl;
                const wants_addr4 = self.fc.to_ds and self.fc.from_ds;
                if (wants_addr4 and self.addr4 == null) return error.MissingAddress;
                if (!wants_addr4 and self.addr4 != null) return error.UnexpectedAddress;
                const wants_qos = self.fc.isQoSData();
                if (wants_qos and self.qos == null) return error.MissingQosControl;
                if (!wants_qos and self.qos != null) return error.UnexpectedQosControl;
                if (has_ht != self.fc.hasHtControl()) {
                    return if (has_ht) error.UnexpectedHtControl else error.MissingHtControl;
                }
            },
        }
    }

    /// 只写帧头，返回写入的字节数。调用前先 `validate`。
    pub fn encodeInto(self: Header, out: []u8) LayoutError!void {
        try self.validate();
        const n: usize = try headerLen(self.fc);
        if (out.len < n) return error.NoRoom;
        std.mem.writeInt(u16, out[0..2], self.fc.encode(), .little);
        std.mem.writeInt(u16, out[2..4], self.duration_id.word(), .little);
        out[4..10].* = self.addr1;
        var pos: usize = 10;
        if (self.addr2) |a| {
            out[pos..][0..mac_len].* = a;
            pos += mac_len;
        }
        if (self.addr3) |a| {
            out[pos..][0..mac_len].* = a;
            pos += mac_len;
        }
        if (self.seq_ctrl) |sc| {
            std.mem.writeInt(u16, out[pos..][0..2], sc, .little);
            pos += 2;
        }
        if (self.addr4) |a| {
            out[pos..][0..mac_len].* = a;
            pos += mac_len;
        }
        if (self.qos) |q| {
            std.mem.writeInt(u16, out[pos..][0..2], q.word(), .little);
            pos += 2;
        }
        if (self.ht_control) |ht| {
            out[pos..][0..4].* = ht;
            pos += 4;
        }
        std.debug.assert(pos == n);
    }
};

// ---------------------------------------------------------------------------
// 整帧：解析与封装
// ---------------------------------------------------------------------------

pub const FcsMode = enum {
    /// 缓冲区不含 FCS（网卡已校验并剥离的常见形态）。
    none,
    /// 末尾 4 字节是 FCS，只取出不校验。
    present,
    /// 末尾 4 字节是 FCS，并校验；不符返回 `error.BadFcs`。
    checked,
};

pub const ParseError = error{
    /// 不足最小帧格式（含/不含 FCS 分别是 14/10 字节），或帧头被截断。
    TooShort,
    /// Protocol Version 不是 0（9.2.4.1.2，p.638：其余取值保留）。
    BadProtocolVersion,
    BadFcs,
    UnsupportedSubtype,
    /// Null 类子类型不该有 Frame Body（9.2.4.1.3，p.640）。
    UnexpectedBody,
};

pub const Frame = struct {
    hdr: Header,
    /// 原样切出的 MAC 帧头字节。
    header: []const u8,
    /// Frame Body，不含 FCS。
    body: []const u8,
    /// FCS 的 4 个字节（线上顺序：多项式最高次项所在字节在前）。
    fcs: ?[4]u8,

    pub fn isGroupAddressed(self: Frame) bool {
        return isGroupAddress(self.hdr.addr1);
    }

    /// TA = Address 2（9.3.3.2 b)，p.693；9.2.4.3.8，p.646）。
    pub fn ta(self: Frame) ?Mac {
        return self.hdr.addr2;
    }
};

pub const ActionHeader = struct {
    /// Table 9-47（p.736–737）的 Category。
    category: u8,
    /// Category 之后那一字节：各分类自己的 Action 字段（如 9.6.10.1 的
    /// SA Query Action、9.6.11 的 Public Action）。
    action: u8,
    /// Action Details 的其余部分。
    details: []const u8,
};

/// Action / Action No Ack 帧体 = Action 字段（Category 1 字节 + Action Details
/// 变长，Figure 9-76，p.736；Table 9-38，p.715）。
pub fn parseAction(body: []const u8) error{Truncated}!ActionHeader {
    if (body.len < 2) return error.Truncated;
    return .{ .category = body[0], .action = body[1], .details = body[2..] };
}

pub fn parse(buf: []const u8, mode: FcsMode) ParseError!Frame {
    const has_fcs = mode != .none;
    const min_len: usize = if (has_fcs) min_frame_len else min_frame_len - fcs_len;
    if (buf.len < min_len) return error.TooShort;
    const end: usize = if (has_fcs) buf.len - fcs_len else buf.len;

    const fc = FrameControl.decode(std.mem.readInt(u16, buf[0..2], .little));
    if (fc.protocol_version != 0) return error.BadProtocolVersion;
    const hlen: usize = headerLen(fc) catch return error.UnsupportedSubtype;
    if (end < hlen) return error.TooShort;

    var fcs: ?[4]u8 = null;
    if (has_fcs) {
        const bytes: [4]u8 = buf[end..][0..fcs_len].*;
        if (mode == .checked and std.mem.readInt(u32, &bytes, .little) != crc32(buf[0..end])) {
            return error.BadFcs;
        }
        fcs = bytes;
    }

    var hdr = Header{
        .fc = fc,
        .duration_id = decodeDurationId(std.mem.readInt(u16, buf[2..4], .little)),
        .addr1 = buf[4..10].*,
    };
    var pos: usize = 10;
    switch (fc.type) {
        .extension => {},
        .control => if (fc.subtype != 12 and fc.subtype != 13) {
            hdr.addr2 = buf[pos..][0..mac_len].*;
            pos += mac_len;
        },
        .mgmt, .data => {
            hdr.addr2 = buf[pos..][0..mac_len].*;
            pos += mac_len;
            hdr.addr3 = buf[pos..][0..mac_len].*;
            pos += mac_len;
            hdr.seq_ctrl = std.mem.readInt(u16, buf[pos..][0..2], .little);
            pos += 2;
            if (fc.type == .data and fc.to_ds and fc.from_ds) {
                hdr.addr4 = buf[pos..][0..mac_len].*;
                pos += mac_len;
            }
            if (fc.isQoSData()) {
                hdr.qos = QosControl.fromWord(std.mem.readInt(u16, buf[pos..][0..2], .little));
                pos += 2;
            }
            if (fc.hasHtControl()) {
                hdr.ht_control = buf[pos..][0..4].*;
                pos += 4;
            }
        },
    }
    std.debug.assert(pos == hlen);

    const body = buf[pos..end];
    if (body.len != 0 and !fc.hasFrameBody()) return error.UnexpectedBody;
    return .{ .hdr = hdr, .header = buf[0..pos], .body = body, .fcs = fcs };
}

/// 封装整帧：帧头 + 帧体（+ FCS）。返回写入的字节数。
pub fn seal(hdr: Header, body: []const u8, with_fcs: bool, out: []u8) LayoutError!usize {
    try hdr.validate();
    const hlen: usize = try headerLen(hdr.fc);
    const total = hlen + body.len + (if (with_fcs) @as(usize, fcs_len) else 0);
    if (out.len < total) return error.NoRoom;
    if (body.len != 0 and !hdr.fc.hasFrameBody()) return error.UnexpectedBody;
    try hdr.encodeInto(out);
    @memcpy(out[hlen..][0..body.len], body);
    if (with_fcs) {
        std.mem.writeInt(u32, out[total - fcs_len ..][0..fcs_len], crc32(out[0 .. total - fcs_len]), .little);
    }
    return total;
}

// ---------------------------------------------------------------------------
// FCS（9.2.4.8，p.665）
//
// 从原文（印刷页码）取下的性质：
//   p.636（9.2.1 c)）：FCS 是「a 32-bit CRC based on ITU-T V.42」。
//   p.665：对 MAC 帧头的所有字段与 Frame Body（合称 calculation fields）计算。
//   p.665：生成多项式 G(x) = x32+x26+x23+x22+x16+x12+x11+x10+x8+x7+x5+x4+x2+x+1。
//   p.665：FCS = 「1s complement of the sum (modulo 2)」的两项余数，
//          等价于下面的典型实现：寄存器预置全 1，除以 G(x)，余数取反。
//   p.665：初始余数预置为全 1（发射机与接收机都是）。
//   p.665：FCS「transmitted commencing with the coefficient of the
//          highest-order term」，即最高次项先发。
//   p.665：接收端把 calculation fields 与 FCS 一起送入除法，余数是唯一非零值
//          x31+x30+x26+x25+x24+x18+x15+x14+x12+x11+x10+x8+x6+x5+x4+x3+x+1
//          = 0xC704DD7B。
//   p.636（9.2.2）：「Any field containing a CRC is an exception to this
//          convention and is transmitted commencing with the coefficient of the
//          highest-order term」——普通字段是低位比特先发。
//   p.2292（17.3.5.5）：「The octets of the PSDU are placed in the transmit
//          serial bit stream, bit 0 first and bit 7 last.」
//
// 由 p.636 / p.2292 / p.665 三条合起来：每个字节的 B0 先上线；FCS 字段却
// 要最高次项先上线，所以 FCS 的 4 个字节是「多项式按位反射后的小端序」，
// 也就是常见的反射式 CRC-32（多项式 0x04C11DB7，反射 0xEDB88320，初值
// 0xFFFFFFFF，结果取反），按小端写出。接收端寄存器（同样反射后、取反后）
// 的唯一余数是 bit_reverse(0xC704DD7B) = 0xDEBB20E3。
// ---------------------------------------------------------------------------

const crc_poly = 0x04c1_1db7;
const crc_poly_reflected = 0xedb8_8320;
const crc_init: u32 = 0xffff_ffff;

/// 9.2.4.8（p.665）给出的接收端唯一余数（多项式域）。
pub const fcs_residue_polynomial: u32 = 0xc704_dd7b;
/// 同一个余数在反射域（逐位移位实现里直接读到的值）。
pub const fcs_residue_reflected: u32 = 0xdebb_20e3;

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if (c & 1 != 0) crc_poly_reflected ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk table;
};

/// 对 `data`（MAC 帧头 + Frame Body，不含 FCS）算 FCS，返回按小端写出前的数值。
pub fn crc32(data: []const u8) u32 {
    var c: u32 = crc_init;
    for (data) |b| {
        c = crc_table[@as(u8, @truncate(c ^ @as(u32, b)))] ^ (c >> 8);
    }
    return ~c;
}

/// 整帧校验：末 4 字节是否等于前文的 FCS。
pub fn fcsOk(frame_with_fcs: []const u8) bool {
    if (frame_with_fcs.len < fcs_len) return false;
    const body = frame_with_fcs[0 .. frame_with_fcs.len - fcs_len];
    const got = std.mem.readInt(u32, frame_with_fcs[body.len..][0..fcs_len], .little);
    return got == crc32(body);
}

/// 接收端寄存器终值：对「帧 + FCS」继续做同样的除法（不取反）。帧正确时
/// 等于 `fcs_residue_reflected`。
pub fn crc32Register(frame_with_fcs: []const u8) u32 {
    var c: u32 = crc_init;
    for (frame_with_fcs) |b| {
        c = crc_table[@as(u8, @truncate(c ^ @as(u32, b)))] ^ (c >> 8);
    }
    return c;
}

/// 逐位移位的参考实现，直接照 9.2.4.8（p.665）的文字写，用来与 `crc32` 对拍：
/// 寄存器预置全 1，比特按线上顺序（每字节 B0 先，见 17.3.5.5）移入，
/// 余数取反即 FCS 多项式。返回值在「多项式域」，未做位反射——
/// 与 `crc32(data)` 相差一次 32 位反射。
pub fn fcsSerialPolynomial(data: []const u8) u32 {
    var reg: u32 = crc_init;
    shiftIn(&reg, data);
    return ~reg;
}

/// 逐位实现的接收端余数：`data` 连同其 FCS 字节一起送入除法。
/// 帧正确时等于 `fcs_residue_polynomial`（0xC704DD7B，p.665）。
pub fn residueSerialPolynomial(frame_with_fcs: []const u8) u32 {
    var reg: u32 = crc_init;
    shiftIn(&reg, frame_with_fcs);
    return reg;
}

fn shiftIn(reg: *u32, data: []const u8) void {
    for (data) |b| {
        var bit: u3 = 0;
        while (true) : (bit +%= 1) {
            const feedback: u32 = (reg.* >> 31) ^ ((@as(u32, b) >> bit) & 1);
            reg.* <<= 1;
            if (feedback != 0) reg.* ^= crc_poly;
            if (bit == 7) break;
        }
    }
}
