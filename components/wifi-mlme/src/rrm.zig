//! wifi-mlme：Radio measurement（IEEE Std 802.11-2016 Clause 11.11，以及 9.4.2.17 / 9.4.2.21 /
//! 9.4.2.22 / 9.4.2.36 / 9.4.2.37 / 9.4.2.38 / 9.4.2.41 / 9.6.7 的元素与帧格式）。
//!
//! 全部是「字节 ↔ 结构」和「输入 → 判决」的纯逻辑：不碰射频、不分配堆内存。量测本身
//! （离信道、定时、随机退避）由调用方做，这里只回答三件事：
//!
//!   1. 帧 / 元素 / 子元素的解析与构造（Category = 5 的六种 Action 帧，Table 9-306）；
//!   2. 量测 STA 侧：收到 Beacon request 后接不接、以哪一位（Late / Incapable / Refused）回绝，
//!      以及由 BSS 表（`scan.zig`，只读）排出 Beacon report（Beacon Table 模式与量测窗口两种）；
//!   3. AP 侧：Neighbor Report Request 的三种 SSID 范围怎么筛邻居、怎么回 Neighbor Report Response。
//!
//! 对应原文（页码为印刷页码）：
//!
//!   * 11.11.4（p.1710–1711）、Table 11-8（p.1710）：Measurement Duration 与 Duration Mandatory；
//!   * 11.11.6（p.1711–1714）：Token 回显、组地址帧不回 Incapable / Refused、并行位；
//!   * 11.11.7（p.1714）：Number of Repetitions；
//!   * 11.11.9.1（p.1716–1719）、Table 9-87 / 9-88 / 9-89 / 9-90：Beacon request / report；
//!   * 11.11.10.3（p.1731–1734）：Neighbor Report 响应的三种 SSID 范围、TSF 子元素的条件；
//!   * 11.11.13（p.1734）：Max Transmit Power 不超过 Max Regulatory Power；
//!   * 9.4.2.21.1 / .7、Figure 9-147 / 9-148 / 9-156 / 9-157（p.804–813）；
//!   * 9.4.2.22.1 / .7、Figure 9-190 / 9-191 / 9-192 / 9-199 / 9-200（p.835–844）、Table 9-112；
//!   * 9.4.2.17 Figure 9-143；9.4.2.36 Figure 9-294；9.4.2.37 Figure 9-295–9-300、Table 9-150 / 9-151 / 9-152；
//!   * 9.4.2.38 Table 9-154（p.923）；9.4.2.41（p.925）；
//!   * 9.6.7.1–9.6.7.7、Figure 9-649–9-654、Table 9-306（p.1173–1176）；
//!   * 9.4.3（p.1121）：子元素 = Subelement ID(1) + Length(1) + Information，不认识的跳过。
//!
//! 取舍与偏离（都有条款依据或写明原因）：
//!
//!   * Reported Frame Body 里 TIM / RSNE 的截断：原文写「only the first 4 octets of the element
//!     are reported and the element Length field is modified to indicate the truncated length of
//!     4」，两句话不能同时按字面成立（元素只剩 4 字节时 Length 只能是 2）。本实现取
//!     「Information 截到前 4 字节、Length 写 4」，元素自洽。盘上的 wpa_supplicant 不截断
//!     （hostap `common/rrm.c:466–477` 整个元素照抄）。
//!   * Beacon request 是 Passive / Active 而 Measurement Duration = 0：11.11.4 只规定发送方
//!     「shall not be set to 0」，没规定接收端怎么办；本实现按 Refused 回绝。
//!   * 没有可报的 BSS 时发空 Beacon report（11.11.9.1 允许 refuse 或 empty，取 empty）。
//!   * Extended Request 子元素（ID 11）、Reporting Condition 5–10 的参考电平、RM Enabled
//!     Capabilities 元素、Operating Class ↔ 信道的 Annex E 映射都不做。
//!
//! 比特编号沿用 9.2.2（p.636）：字段第 N 位落在第 N/8 字节的第 N mod 8 位。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const mgmt = @import("mgmt.zig");
const robust = @import("robust.zig");
const scan = @import("scan.zig");

pub const Error = error{
    /// 字节不够（固定字段、元素头、子元素被截断）。
    Truncated,
    /// 超出本实现的有界表或单个元素的上限。
    TooLong,
    /// 元素 / 子元素的长度与其固定布局对不上。
    BadLength,
    /// 自相矛盾：Report Mode 置了多位、拒绝时仍带报告字段。
    BadValue,
    /// 取值是保留值（测量模式 3–255、Reporting Detail 3–255、Reporting Condition 11–255）。
    ReservedValue,
    /// 帧头 Dialog Token 为 0（请求帧要求非 0）。
    ZeroDialogToken,
    /// Measurement Token 为 0 或在同一帧里重复。
    ZeroToken,
    DuplicateToken,
    BadCategory,
    BadAction,
    /// Link Measurement Report 里没有 TPC Report 元素。
    MissingElement,
    /// 该字段里出现了不允许的元素。
    UnexpectedElement,
    TooMany,
};

pub const BuildError = error{
    NoRoom,
    TooLong,
    BadLength,
    BadValue,
    ReservedValue,
    ZeroDialogToken,
    ZeroToken,
    DuplicateToken,
    TooMany,
};

fn le16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

fn le32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .little);
}

fn le64(b: *const [8]u8) u64 {
    return std.mem.readInt(u64, b, .little);
}

fn w16(out: []u8, v: u16) void {
    std.mem.writeInt(u16, out[0..2], v, .little);
}

// ---------------------------------------------------------------------------
// 0) 常量与子元素
// ---------------------------------------------------------------------------

/// Radio Measurement 的 Category（Table 9-47，p.736）。
pub const category: u8 = @backingInt(robust.Category.radio_measurement);

/// Table 9-306（p.1173）：Radio Measurement Action 字段。
pub const Action = enum(u8) {
    radio_measurement_request = 0,
    radio_measurement_report = 1,
    link_measurement_request = 2,
    link_measurement_report = 3,
    neighbor_report_request = 4,
    neighbor_report_response = 5,
    _,
};

/// Table 9-82（p.805）：Measurement Type 字段。
pub const MeasurementType = struct {
    pub const basic: u8 = 0;
    pub const cca: u8 = 1;
    pub const rpi_histogram: u8 = 2;
    pub const channel_load: u8 = 3;
    pub const noise_histogram: u8 = 4;
    pub const beacon: u8 = 5;
    pub const frame: u8 = 6;
    pub const sta_statistics: u8 = 7;
    pub const pause: u8 = 255;
};

/// 9.4.3（p.1121）：Subelement ID(1) + Length(1) + Information。
pub const Subelement = struct {
    id: u8,
    body: []const u8,
};

pub const SubWalker = struct {
    rest: []const u8,

    pub fn init(s: []const u8) SubWalker {
        return .{ .rest = s };
    }

    /// 取下一个子元素；走完返回 null。出错后遍历器作废。
    pub fn next(self: *SubWalker) error{Truncated}!?Subelement {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 2) return error.Truncated;
        const len: usize = self.rest[1];
        if (self.rest.len - 2 < len) return error.Truncated;
        const s = Subelement{ .id = self.rest[0], .body = self.rest[2 .. 2 + len] };
        self.rest = self.rest[2 + len ..];
        return s;
    }
};

// ---------------------------------------------------------------------------
// 1) Measurement Request 元素（9.4.2.21；Figure 9-147 / 9-148）
// ---------------------------------------------------------------------------

/// Figure 9-148（p.805）：B0 Parallel、B1 Enable、B2 Request、B3 Report、B4 Duration
/// Mandatory、B5–B7 保留（接收端按 0 处理）。
pub const RequestMode = packed struct(u8) {
    parallel: bool = false,
    enable: bool = false,
    request: bool = false,
    report: bool = false,
    duration_mandatory: bool = false,
    reserved: u3 = 0,

    pub fn word(self: RequestMode) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) RequestMode {
        return .{
            .parallel = w & 0x01 != 0,
            .enable = w & 0x02 != 0,
            .request = w & 0x04 != 0,
            .report = w & 0x08 != 0,
            .duration_mandatory = w & 0x10 != 0,
        };
    }
};

/// Figure 9-147（p.804）：Element ID(38)、Length、Token(1)、Mode(1)、Type(1)、Request。
/// Length 的最小值是 3（9.4.2.21.1）。
pub const MeasurementRequest = struct {
    token: u8,
    mode: RequestMode,
    type: u8,
    request: []const u8,
};

pub fn parseMeasurementRequest(body: []const u8) Error!MeasurementRequest {
    if (body.len < 3) return error.Truncated;
    return .{ .token = body[0], .mode = RequestMode.fromWord(body[1]), .type = body[2], .request = body[3..] };
}

/// Measurement Token「is set to a nonzero number that is unique among the Measurement Request
/// elements in a particular Measurement Request frame」（9.4.2.21.1）。
pub fn buildMeasurementRequestElement(out: []u8, token: u8, mode: RequestMode, mtype: u8, request: []const u8) BuildError!usize {
    if (token == 0) return error.ZeroToken;
    if (request.len > 252) return error.TooLong;
    const total = 5 + request.len;
    if (out.len < total) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.measurement_request);
    out[1] = @intCast(total - 2);
    out[2] = token;
    out[3] = mode.word();
    out[4] = mtype;
    @memcpy(out[5..][0..request.len], request);
    return total;
}

// ---------------------------------------------------------------------------
// 2) Beacon request（9.4.2.21.7；Figure 9-156；Table 9-87 / 9-88 / 9-89 / 9-90）
// ---------------------------------------------------------------------------

/// Table 9-87（p.812）：Passive 0、Active 1、Beacon Table 2，其余保留。
pub const BeaconMode = enum(u8) {
    passive = 0,
    active = 1,
    table = 2,
    _,
};

/// Table 9-88（p.812）的子元素 ID。
pub const BeaconRequestSubelement = struct {
    pub const ssid: u8 = 0;
    pub const beacon_reporting: u8 = 1;
    pub const reporting_detail: u8 = 2;
    pub const request: u8 = 10;
    pub const extended_request: u8 = 11;
    pub const ap_channel_report: u8 = 51;
};

/// Figure 9-157（p.813）：Reporting Condition(1) + Threshold/Offset Reference(1)。
pub const BeaconReporting = struct {
    /// Table 9-89（p.813）：0 = 每次量测后都报（默认），1–10 是条件。
    condition: u8,
    threshold_offset: u8,
};

pub const max_ap_channel_reports = 4;
pub const ap_channel_report_max_channels = 8;
pub const max_requested_elements = 8;

/// AP Channel Report（Figure 9-294，p.920；ID 51 的子元素同格式）：Operating Class(1) +
/// Channel List(每个信道 1 字节，可为空)。
pub const ApChannelReport = struct {
    operating_class: u8 = 0,
    channels: [ap_channel_report_max_channels]u8 = @splat(0),
    channel_count: u8 = 0,

    pub fn channelSlice(self: *const ApChannelReport) []const u8 {
        return self.channels[0..self.channel_count];
    }
};

/// Operating Class(1) Channel Number(1) Randomization Interval(2) Measurement Duration(2)
/// Measurement Mode(1) BSSID(6)（Figure 9-156）。
pub const beacon_request_fixed_len = 13;

pub const BeaconRequest = struct {
    operating_class: u8 = 0,
    channel: u8 = 0,
    randomization_interval_tu: u16 = 0,
    duration_tu: u16 = 0,
    mode: BeaconMode = .passive,
    /// 通配 BSSID（广播）表示信道上的全部 BSS。
    bssid: frame.Mac = frame.broadcast,
    /// 子元素 0：缺席即通配 SSID；长度 0 也是通配。
    ssid: ?[]const u8 = null,
    /// 子元素 1：只在重复量测时出现。
    beacon_reporting: ?BeaconReporting = null,
    /// Table 9-90（p.814）：0 不带；1 固定字段 + 点名的元素；2 全部（子元素缺席时的默认）。
    reporting_detail: u8 = 2,
    reporting_detail_present: bool = false,
    ap_channel_reports: [max_ap_channel_reports]ApChannelReport = @splat(.{}),
    ap_channel_report_count: u8 = 0,
    /// 子元素 10（Request）：要点名的元素 ID。
    requested: [max_requested_elements]u8 = @splat(0),
    requested_count: u8 = 0,

    pub fn ssidIsWildcard(self: *const BeaconRequest) bool {
        const s = self.ssid orelse return true;
        return s.len == 0;
    }

    pub fn isWildcardBssid(self: *const BeaconRequest) bool {
        return std.mem.eql(u8, &self.bssid, &frame.broadcast);
    }
};

pub fn parseApChannelReport(body: []const u8) Error!ApChannelReport {
    if (body.len < 1) return error.Truncated;
    const n = body.len - 1;
    if (n > ap_channel_report_max_channels) return error.TooLong;
    var r = ApChannelReport{ .operating_class = body[0] };
    @memcpy(r.channels[0..n], body[1..]);
    r.channel_count = @intCast(n);
    return r;
}

/// AP Channel Report 元素（ID 51）：Element ID、Length、Operating Class、Channel List。
pub fn buildApChannelReport(out: []u8, r: *const ApChannelReport) BuildError!usize {
    const n: usize = r.channel_count;
    const total = 3 + n;
    if (out.len < total) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.ap_channel_report);
    out[1] = @intCast(1 + n);
    out[2] = r.operating_class;
    @memcpy(out[3..][0..n], r.channels[0..n]);
    return total;
}

/// 解析 Measurement Request 元素的 Request 字段（Measurement Type = Beacon）。
pub fn parseBeaconRequest(request: []const u8) Error!BeaconRequest {
    if (request.len < beacon_request_fixed_len) return error.Truncated;
    var r = BeaconRequest{
        .operating_class = request[0],
        .channel = request[1],
        .randomization_interval_tu = le16(request[2..4]),
        .duration_tu = le16(request[4..6]),
        .mode = @fromBackingInt(@intCast(request[6])),
        .bssid = request[7..13].*,
    };
    switch (r.mode) {
        .passive, .active, .table => {},
        // 「Reserved 3–255」（Table 9-87）。
        else => return error.ReservedValue,
    }
    var w = SubWalker.init(request[beacon_request_fixed_len..]);
    while (try w.next()) |s| {
        switch (s.id) {
            BeaconRequestSubelement.ssid => {
                if (s.body.len > ie.ssid_max) return error.TooLong;
                r.ssid = s.body;
            },
            BeaconRequestSubelement.beacon_reporting => {
                if (s.body.len != 2) return error.BadLength;
                if (s.body[0] > 10) return error.ReservedValue;
                r.beacon_reporting = .{ .condition = s.body[0], .threshold_offset = s.body[1] };
            },
            BeaconRequestSubelement.reporting_detail => {
                if (s.body.len != 1) return error.BadLength;
                // 「Reserved 3–255」（Table 9-90）。
                if (s.body[0] > 2) return error.ReservedValue;
                r.reporting_detail = s.body[0];
                r.reporting_detail_present = true;
            },
            BeaconRequestSubelement.request => {
                for (s.body) |eid| {
                    if (r.requested_count == max_requested_elements) return error.TooMany;
                    r.requested[r.requested_count] = eid;
                    r.requested_count += 1;
                }
            },
            BeaconRequestSubelement.ap_channel_report => {
                if (r.ap_channel_report_count == max_ap_channel_reports) return error.TooMany;
                r.ap_channel_reports[r.ap_channel_report_count] = try parseApChannelReport(s.body);
                r.ap_channel_report_count += 1;
            },
            // Extended Request（11）不解析；其余子元素跳过（9.4.3）。
            else => {},
        }
    }
    return r;
}

/// Beacon request 的 Request 字段（13 字节固定字段 + 子元素）。子元素按 ID 升序写。
pub fn buildBeaconRequest(out: []u8, r: BeaconRequest) BuildError!usize {
    const ssid_len = if (r.ssid) |s| s.len else 0;
    var tail: usize = 0;
    if (r.ssid != null) tail += 2 + ssid_len;
    if (r.beacon_reporting != null) tail += 4;
    if (r.reporting_detail_present) tail += 3;
    if (r.requested_count != 0) tail += 2 + r.requested_count;
    for (r.ap_channel_reports[0..r.ap_channel_report_count]) |a| tail += 3 + a.channel_count;
    const total = beacon_request_fixed_len + tail;
    if (total > 252) return error.TooLong;
    if (r.beacon_reporting) |b| {
        if (b.condition > 10) return error.ReservedValue;
    }
    if (r.reporting_detail_present and r.reporting_detail > 2) return error.ReservedValue;
    if (out.len < total) return error.NoRoom;

    out[0] = r.operating_class;
    out[1] = r.channel;
    w16(out[2..4], r.randomization_interval_tu);
    w16(out[4..6], r.duration_tu);
    out[6] = @backingInt(r.mode);
    out[7..13].* = r.bssid;
    var pos: usize = beacon_request_fixed_len;
    if (r.ssid) |s| {
        out[pos] = BeaconRequestSubelement.ssid;
        out[pos + 1] = @intCast(s.len);
        @memcpy(out[pos + 2 ..][0..s.len], s);
        pos += 2 + s.len;
    }
    if (r.beacon_reporting) |b| {
        out[pos] = BeaconRequestSubelement.beacon_reporting;
        out[pos + 1] = 2;
        out[pos + 2] = b.condition;
        out[pos + 3] = b.threshold_offset;
        pos += 4;
    }
    if (r.reporting_detail_present) {
        out[pos] = BeaconRequestSubelement.reporting_detail;
        out[pos + 1] = 1;
        out[pos + 2] = r.reporting_detail;
        pos += 3;
    }
    if (r.requested_count != 0) {
        out[pos] = BeaconRequestSubelement.request;
        out[pos + 1] = r.requested_count;
        @memcpy(out[pos + 2 ..][0..r.requested_count], r.requested[0..r.requested_count]);
        pos += 2 + r.requested_count;
    }
    for (r.ap_channel_reports[0..r.ap_channel_report_count]) |*a| {
        out[pos] = BeaconRequestSubelement.ap_channel_report;
        out[pos + 1] = @intCast(1 + a.channel_count);
        out[pos + 2] = a.operating_class;
        const n: usize = a.channel_count;
        @memcpy(out[pos + 3 ..][0..n], a.channels[0..n]);
        pos += 3 + n;
    }
    std.debug.assert(pos == total);
    return total;
}

// ---------------------------------------------------------------------------
// 3) Measurement Report 元素（9.4.2.22.1；Figure 9-191 / 9-192）
// ---------------------------------------------------------------------------

/// Figure 9-192（p.836）：B0 Late、B1 Incapable、B2 Refused、B3–B7 保留。
pub const ReportMode = packed struct(u8) {
    late: bool = false,
    incapable: bool = false,
    refused: bool = false,
    reserved: u5 = 0,

    pub fn word(self: ReportMode) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) ReportMode {
        return .{ .late = w & 0x01 != 0, .incapable = w & 0x02 != 0, .refused = w & 0x04 != 0 };
    }

    /// 「No more than one bit is set to 1 within a Measurement Report Mode field」（9.4.2.22.1）。
    pub fn valid(self: ReportMode) bool {
        const n = @as(u8, @intFromBool(self.late)) + @intFromBool(self.incapable) + @intFromBool(self.refused);
        return n <= 1;
    }

    pub fn rejected(self: ReportMode) bool {
        return self.late or self.incapable or self.refused;
    }
};

/// Figure 9-191（p.836）：Element ID(39)、Length、Token(1)、Mode(1)、Type(1)、Report。
pub const MeasurementReport = struct {
    token: u8,
    mode: ReportMode,
    type: u8,
    report: []const u8,
};

pub fn parseMeasurementReport(body: []const u8) Error!MeasurementReport {
    if (body.len < 3) return error.Truncated;
    const r = MeasurementReport{ .token = body[0], .mode = ReportMode.fromWord(body[1]), .type = body[2], .report = body[3..] };
    if (!r.mode.valid()) return error.BadValue;
    // 「The Measurement Report field is not present when the Late / Incapable / Refused bit is
    // equal to 1」（9.4.2.22.1）。
    if (r.mode.rejected() and r.report.len != 0) return error.BadValue;
    return r;
}

pub fn buildMeasurementReportElement(out: []u8, token: u8, mode: ReportMode, mtype: u8, report: []const u8) BuildError!usize {
    if (!mode.valid()) return error.BadValue;
    if (mode.rejected() and report.len != 0) return error.BadValue;
    if (report.len > 252) return error.TooLong;
    const total = 5 + report.len;
    if (out.len < total) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.measurement_report);
    out[1] = @intCast(total - 2);
    out[2] = token;
    out[3] = mode.word();
    out[4] = mtype;
    @memcpy(out[5..][0..report.len], report);
    return total;
}
// ---------------------------------------------------------------------------
// 4) Beacon report（9.4.2.22.7；Figure 9-199 / 9-200；Table 9-112）
// ---------------------------------------------------------------------------

/// Table 9-112（p.844）的子元素 ID。
pub const BeaconReportSubelement = struct {
    pub const reported_frame_body: u8 = 1;
};

/// RCPI（Table 9-154）与 RSNI（9.4.2.41）里「Measurement not available」的取值。
pub const not_available: u8 = 255;

/// Operating Class(1) Channel Number(1) Actual Measurement Start Time(8) Measurement
/// Duration(2) Reported Frame Information(1) RCPI(1) RSNI(1) BSSID(6) Antenna ID(1)
/// Parent TSF(4)（Figure 9-199，p.846）。
pub const beacon_report_fixed_len = 26;

pub const BeaconReport = struct {
    operating_class: u8 = 255,
    channel: u8 = 255,
    /// 量测 STA 的 TSF 在量测开始时的值。
    start_time: u64 = 0,
    duration_tu: u16 = 0,
    reported_frame_info: u8 = 255,
    rcpi: u8 = not_available,
    rsni: u8 = not_available,
    bssid: frame.Mac = @splat(0),
    antenna_id: u8 = 0,
    /// 收到被报告帧 Timestamp 字段第一个字节时，量测 STA 的 TSF 低 4 字节。
    parent_tsf: u32 = 0,
    subelements: []const u8 = &.{},

    /// Figure 9-200（p.844）：B0–B6 Condensed PHY Type。
    pub fn phyType(self: BeaconReport) u7 {
        return @truncate(self.reported_frame_info);
    }

    /// Figure 9-200：B7 Reported Frame Type，0 = Beacon / Probe Response，1 = Measurement Pilot。
    pub fn isMeasurementPilot(self: BeaconReport) bool {
        return self.reported_frame_info & 0x80 != 0;
    }
};

pub fn parseBeaconReport(body: []const u8) Error!BeaconReport {
    if (body.len < beacon_report_fixed_len) return error.Truncated;
    // 子元素被截断同样算坏帧。
    var w = SubWalker.init(body[beacon_report_fixed_len..]);
    while (try w.next()) |_| {}
    return .{
        .operating_class = body[0],
        .channel = body[1],
        .start_time = le64(body[2..10]),
        .duration_tu = le16(body[10..12]),
        .reported_frame_info = body[12],
        .rcpi = body[13],
        .rsni = body[14],
        .bssid = body[15..21].*,
        .antenna_id = body[21],
        .parent_tsf = le32(body[22..26]),
        .subelements = body[beacon_report_fixed_len..],
    };
}

/// Beacon report 的 Report 字段（26 字节固定字段 + 子元素）。
pub fn buildBeaconReport(out: []u8, r: BeaconReport) BuildError!usize {
    const total = beacon_report_fixed_len + r.subelements.len;
    if (total > 252) return error.TooLong;
    if (out.len < total) return error.NoRoom;
    out[0] = r.operating_class;
    out[1] = r.channel;
    std.mem.writeInt(u64, out[2..10], r.start_time, .little);
    w16(out[10..12], r.duration_tu);
    out[12] = r.reported_frame_info;
    out[13] = r.rcpi;
    out[14] = r.rsni;
    out[15..21].* = r.bssid;
    out[21] = r.antenna_id;
    std.mem.writeInt(u32, out[22..26], r.parent_tsf, .little);
    @memcpy(out[26..][0..r.subelements.len], r.subelements);
    return total;
}

/// Token 回显请求、Mode = 0、Type = Beacon 的 Measurement Report 元素，Report 是 Beacon report。
pub fn buildBeaconReportElement(out: []u8, token: u8, mode: ReportMode, r: BeaconReport) BuildError!usize {
    if (mode.late) return error.BadValue;
    var rep: [255]u8 = undefined;
    const n = try buildBeaconReport(&rep, r);
    return buildMeasurementReportElement(out, token, mode, MeasurementType.beacon, rep[0..n]);
}

/// 空 Beacon report（11.11.9.1：「may either refuse the request or send an empty Beacon report」）：
/// 没有 BSS 可报。没有 Supported Operating Classes 元素时 Operating Class / Channel Number /
/// Reported Frame Information 写 255，RCPI / RSNI 写 255（不可用），其余为 0。
pub fn buildEmptyBeaconReportElement(out: []u8, token: u8) BuildError!usize {
    return buildBeaconReportElement(out, token, .{}, .{});
}

/// 一整帧 Beacon 请求：Radio Measurement Request 帧（Figure 9-649）里放一个 Beacon request 的
/// Measurement Request 元素（Token = 1）。给进程内的 AP 模型用。
pub fn buildBeaconRequestFrame(out: []u8, dialog_token: u8, repetitions: u16, mode: RequestMode, beacon: BeaconRequest) BuildError!usize {
    var field: [255]u8 = undefined;
    var elem: [255]u8 = undefined;
    const f = try buildBeaconRequest(&field, beacon);
    const n = try buildMeasurementRequestElement(&elem, 1, mode, MeasurementType.beacon, field[0..f]);
    return buildRadioMeasurementRequest(out, .{ .dialog_token = dialog_token, .repetitions = repetitions, .request_elements = elem[0..n] });
}

// ---------------------------------------------------------------------------
// 5) RCPI / RSNI
// ---------------------------------------------------------------------------

/// Table 9-154（p.923）：0 表示 P < –109.5 dBm；1–219 表示 RCPI = 2 ×（P + 110）；220 表示
/// P ≥ 0 dBm；221–254 保留；255 表示不可用。输入是整数 dBm。
pub fn rcpiFromDbm(dbm: i16) u8 {
    if (dbm < -109) return 0;
    if (dbm >= 0) return 220;
    return @intCast(2 * (dbm + 110));
}

/// 9.4.2.41（p.925）：RSNI =（10 × log10((RCPIpower – ANPIpower) / ANPIpower) + 10）× 2，0.5 dB
/// 一步，覆盖 –10..+117 dB。功率比取对数就是信号与噪声的 dBm 之差，所以整数 dBm 输入时
/// 结果精确；超出范围的按边界取值（255 留给「不可用」）。
pub fn rsniFromDbm(signal_dbm: i16, noise_dbm: i16) u8 {
    const v: i32 = 2 * (@as(i32, signal_dbm) - noise_dbm + 10);
    if (v <= 0) return 0;
    if (v >= not_available) return not_available - 1;
    return @intCast(v);
}

// ---------------------------------------------------------------------------
// 6) Reported Frame Body 子元素（9.4.2.22.7；Table 9-90 / 9-112）
// ---------------------------------------------------------------------------

/// Reported Frame Body 子元素（含 Subelement ID 与 Length）的上限：Measurement Report 元素
/// 总长不超过 255（Length 是 1 字节），减去元素头 3 与 Beacon report 固定字段 26。
pub const reported_frame_body_max = 255 - beacon_report_fixed_len - 3;

/// Beacon / Probe Response 的固定字段：Timestamp(8) + Beacon interval(2) + Capability(2)
/// （Table 9-27，p.694；Table 9-34，p.708）。
pub const beacon_fixed_len = 12;

/// Reported Frame Body 子元素（ID 1）。`detail` 是 Table 9-90 的 Reporting Detail：
///   0 → 不带（返回 0）；1 → 固定字段 + `requested` 点名的元素；2 → 固定字段 + 全部元素。
/// 元素按原帧顺序；装不下时在最后一个完整元素处截断（9.4.2.22.7）。TIM 与 RSNE 的
/// 截断见文件头的取舍。
pub fn buildReportedFrameBody(out: []u8, detail: u8, body: []const u8, requested: []const u8) BuildError!usize {
    if (detail > 2) return error.ReservedValue;
    if (detail == 0) return 0;
    if (body.len < beacon_fixed_len) return error.BadLength;
    if (out.len < reported_frame_body_max) return error.NoRoom;
    @memcpy(out[2..14], body[0..12]);
    var pos: usize = 2 + beacon_fixed_len;
    var w = ie.Walker.init(body[beacon_fixed_len..]);
    while (w.next() catch return error.BadLength) |el| {
        const wanted = detail == 2 or std.mem.indexOfScalar(u8, requested, el.id) != null;
        if (!wanted) continue;
        var info: []const u8 = el.body;
        if (el.id == @backingInt(ie.ElementId.tim) or el.id == @backingInt(ie.ElementId.rsn)) {
            if (info.len > 4) info = info[0..4];
        }
        if (pos + 2 + info.len > reported_frame_body_max) break;
        out[pos] = el.id;
        out[pos + 1] = @intCast(info.len);
        @memcpy(out[pos + 2 ..][0..info.len], info);
        pos += 2 + info.len;
    }
    out[0] = BeaconReportSubelement.reported_frame_body;
    out[1] = @intCast(pos - 2);
    return pos;
}

// ---------------------------------------------------------------------------
// 7) TPC Report 元素（9.4.2.17；Figure 9-143）
// ---------------------------------------------------------------------------

/// Transmit Power(1)、Link Margin(1)：都是补码有符号整数，单位 dBm / dB。
pub const TpcReport = struct {
    transmit_power_dbm: i8,
    link_margin_db: i8,
};

pub fn parseTpcReport(body: []const u8) Error!TpcReport {
    if (body.len != 2) return error.BadLength;
    return .{ .transmit_power_dbm = @bitCast(body[0]), .link_margin_db = @bitCast(body[1]) };
}

pub fn buildTpcReport(out: []u8, t: TpcReport) BuildError!usize {
    if (out.len < 4) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.tpc_report);
    out[1] = 2;
    out[2] = @bitCast(t.transmit_power_dbm);
    out[3] = @bitCast(t.link_margin_db);
    return 4;
}

// ---------------------------------------------------------------------------
// 8) Neighbor Report 元素（9.4.2.37；Figure 9-295–9-300；Table 9-150 / 9-151 / 9-152）
// ---------------------------------------------------------------------------

/// Table 9-151（p.919）里本组件解析 / 构造的子元素 ID。
pub const NeighborReportSubelement = struct {
    pub const tsf_information: u8 = 1;
    pub const condensed_country_string: u8 = 2;
    pub const bss_transition_candidate_preference: u8 = 3;
    pub const bss_termination_duration: u8 = 4;
};

/// Table 9-150（p.917）：AP Reachability。
pub const Reachability = enum(u2) {
    reserved = 0,
    not_reachable = 1,
    unknown = 2,
    reachable = 3,
};

/// Figure 9-297（p.918）：Capabilities 子字段与 Capability Information（9.4.1.4）的同名位。
pub const BssidCapabilities = packed struct(u6) {
    spectrum_management: bool = false,
    qos: bool = false,
    apsd: bool = false,
    radio_measurement: bool = false,
    delayed_block_ack: bool = false,
    immediate_block_ack: bool = false,

    pub fn fromCapability(c: mgmt.Capability) BssidCapabilities {
        return .{
            .spectrum_management = c.spectrum_management,
            .qos = c.qos,
            .apsd = c.apsd,
            .radio_measurement = c.radio_measurement,
            .delayed_block_ack = c.delayed_block_ack,
            .immediate_block_ack = c.immediate_block_ack,
        };
    }
};

/// Figure 9-296（p.917）：B0–1 AP Reachability、B2 Security、B3 Key Scope、B4–9 Capabilities、
/// B10 Mobility Domain、B11 High Throughput、B12 Very High Throughput、B13 FTM、B14–31 保留。
pub const BssidInfo = packed struct(u32) {
    ap_reachability: Reachability = .reserved,
    security: bool = false,
    key_scope: bool = false,
    capabilities: BssidCapabilities = .{},
    mobility_domain: bool = false,
    high_throughput: bool = false,
    very_high_throughput: bool = false,
    ftm: bool = false,
    reserved: u18 = 0,

    pub fn word(self: BssidInfo) u32 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u32) BssidInfo {
        return @bitCast(w);
    }
};

/// Figure 9-298（p.919）：TSF Offset(2) + Beacon Interval(2)。
pub const TsfInfo = struct {
    tsf_offset_tu: u16,
    beacon_interval_tu: u16,
};

/// Figure 9-300（p.921）：BSS Termination TSF(8) + Duration(2，分钟)。
pub const TerminationDuration = struct {
    tsf: u64 = 0,
    duration_minutes: u16 = 0,
};

/// BSSID(6) BSSID Information(4) Operating Class(1) Channel Number(1) PHY Type(1) + 可选子元素
/// （Figure 9-295，p.921）；Length 的最小值是 13。
pub const neighbor_report_fixed_len = 13;

pub const NeighborReport = struct {
    bssid: frame.Mac = @splat(0),
    bssid_info: BssidInfo = .{},
    operating_class: u8 = 0,
    channel: u8 = 0,
    phy_type: u8 = 0,
    tsf: ?TsfInfo = null,
    condensed_country: ?[2]u8 = null,
    /// 子元素 3；Table 9-152（p.921）：0 = Excluded BSS，1–255 排序（255 最偏好）。
    preference: ?u8 = null,
    termination: ?TerminationDuration = null,
};

/// 解析 Neighbor Report 元素；只取 Table 9-151 的子元素 1–4，其余跳过（9.4.3）。
pub fn parseNeighborReport(body: []const u8) Error!NeighborReport {
    if (body.len < neighbor_report_fixed_len) return error.Truncated;
    var r = NeighborReport{
        .bssid = body[0..6].*,
        .bssid_info = BssidInfo.fromWord(le32(body[6..10])),
        .operating_class = body[10],
        .channel = body[11],
        .phy_type = body[12],
    };
    var w = SubWalker.init(body[neighbor_report_fixed_len..]);
    while (try w.next()) |s| {
        switch (s.id) {
            NeighborReportSubelement.tsf_information => {
                if (s.body.len != 4) return error.BadLength;
                r.tsf = .{ .tsf_offset_tu = le16(s.body[0..2]), .beacon_interval_tu = le16(s.body[2..4]) };
            },
            NeighborReportSubelement.condensed_country_string => {
                if (s.body.len != 2) return error.BadLength;
                r.condensed_country = s.body[0..2].*;
            },
            NeighborReportSubelement.bss_transition_candidate_preference => {
                if (s.body.len != 1) return error.BadLength;
                r.preference = s.body[0];
            },
            NeighborReportSubelement.bss_termination_duration => {
                if (s.body.len != 10) return error.BadLength;
                r.termination = .{ .tsf = le64(s.body[0..8]), .duration_minutes = le16(s.body[8..10]) };
            },
            else => {},
        }
    }
    return r;
}

/// Neighbor Report 元素。子元素按 ID 升序写；`termination.duration_minutes` 为 0 是保留值。
pub fn buildNeighborReport(out: []u8, r: NeighborReport) BuildError!usize {
    var total: usize = 2 + neighbor_report_fixed_len;
    if (r.tsf != null) total += 6;
    if (r.condensed_country != null) total += 4;
    if (r.preference != null) total += 3;
    if (r.termination != null) total += 12;
    if (total > 255) return error.TooLong;
    if (r.termination) |t| {
        if (t.duration_minutes == 0) return error.ReservedValue;
    }
    if (out.len < total) return error.NoRoom;

    out[0] = @backingInt(ie.ElementId.neighbor_report);
    out[1] = @intCast(total - 2);
    out[2..8].* = r.bssid;
    std.mem.writeInt(u32, out[8..12], r.bssid_info.word(), .little);
    out[12] = r.operating_class;
    out[13] = r.channel;
    out[14] = r.phy_type;
    var pos: usize = 2 + neighbor_report_fixed_len;
    if (r.tsf) |t| {
        out[pos] = NeighborReportSubelement.tsf_information;
        out[pos + 1] = 4;
        w16(out[pos + 2 ..], t.tsf_offset_tu);
        w16(out[pos + 4 ..], t.beacon_interval_tu);
        pos += 6;
    }
    if (r.condensed_country) |c| {
        out[pos] = NeighborReportSubelement.condensed_country_string;
        out[pos + 1] = 2;
        out[pos + 2 ..][0..2].* = c;
        pos += 4;
    }
    if (r.preference) |p| {
        out[pos] = NeighborReportSubelement.bss_transition_candidate_preference;
        out[pos + 1] = 1;
        out[pos + 2] = p;
        pos += 3;
    }
    if (r.termination) |t| {
        out[pos] = NeighborReportSubelement.bss_termination_duration;
        out[pos + 1] = 10;
        std.mem.writeInt(u64, out[pos + 2 ..][0..8], t.tsf, .little);
        w16(out[pos + 10 ..], t.duration_minutes);
        pos += 12;
    }
    std.debug.assert(pos == total);
    return total;
}

// ---------------------------------------------------------------------------
// 9) 帧（9.6.7；Figure 9-649–9-654）
// ---------------------------------------------------------------------------

fn checkHeader(body: []const u8, action: Action) Error!void {
    if (body.len < 2) return error.Truncated;
    if (body[0] != category) return error.BadCategory;
    if (body[1] != @backingInt(action)) return error.BadAction;
}

/// 一帧里最多解析几个 Measurement Request / Report 元素。
pub const max_measurements = 8;

/// Figure 9-649（p.1173）：Category、Radio Measurement Action、Dialog Token(1)、Number of
/// Repetitions(2)、Measurement Request Elements。
pub const RadioMeasurementRequest = struct {
    dialog_token: u8,
    repetitions: u16,
    elements: []const u8,
    requests: [max_measurements]MeasurementRequest = undefined,
    request_count: u8 = 0,

    pub fn requestSlice(self: *const RadioMeasurementRequest) []const MeasurementRequest {
        return self.requests[0..self.request_count];
    }
};

pub fn parseRadioMeasurementRequest(body: []const u8) Error!RadioMeasurementRequest {
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .radio_measurement_request);
    var r = RadioMeasurementRequest{ .dialog_token = body[2], .repetitions = le16(body[3..5]), .elements = body[5..] };
    // 「The Dialog Token field is set to a nonzero value chosen by the STA sending the radio
    // measurement request」（9.6.7.2）。
    if (r.dialog_token == 0) return error.ZeroDialogToken;
    var w = ie.Walker.init(r.elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.measurement_request)) continue;
        if (r.request_count == max_measurements) return error.TooMany;
        const m = try parseMeasurementRequest(el.body);
        if (m.token == 0) return error.ZeroToken;
        for (r.requests[0..r.request_count]) |prev| {
            if (prev.token == m.token) return error.DuplicateToken;
        }
        r.requests[r.request_count] = m;
        r.request_count += 1;
    }
    return r;
}

pub const RadioMeasurementRequestParams = struct {
    dialog_token: u8,
    repetitions: u16 = 0,
    /// 已拼好的 Measurement Request 元素串。
    request_elements: []const u8 = &.{},
};

pub fn buildRadioMeasurementRequest(out: []u8, p: RadioMeasurementRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    const total = 5 + p.request_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.radio_measurement_request);
    out[2] = p.dialog_token;
    w16(out[3..5], p.repetitions);
    @memcpy(out[5..][0..p.request_elements.len], p.request_elements);
    return total;
}

/// Figure 9-650（p.1174）：Category、Radio Measurement Action、Dialog Token(1)、Measurement
/// Report Elements。Dialog Token 回显请求帧；自主报告（不是回应请求）时为 0。
pub const RadioMeasurementReport = struct {
    dialog_token: u8,
    elements: []const u8,
    reports: [max_measurements]MeasurementReport = undefined,
    report_count: u8 = 0,

    pub fn reportSlice(self: *const RadioMeasurementReport) []const MeasurementReport {
        return self.reports[0..self.report_count];
    }
};

pub fn parseRadioMeasurementReport(body: []const u8) Error!RadioMeasurementReport {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .radio_measurement_report);
    var r = RadioMeasurementReport{ .dialog_token = body[2], .elements = body[3..] };
    var w = ie.Walker.init(r.elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.measurement_report)) continue;
        if (r.report_count == max_measurements) return error.TooMany;
        r.reports[r.report_count] = try parseMeasurementReport(el.body);
        r.report_count += 1;
    }
    return r;
}

pub const RadioMeasurementReportParams = struct {
    dialog_token: u8,
    /// 已拼好的 Measurement Report 元素串。
    report_elements: []const u8 = &.{},
};

pub fn buildRadioMeasurementReport(out: []u8, p: RadioMeasurementReportParams) BuildError!usize {
    const total = 3 + p.report_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.radio_measurement_report);
    out[2] = p.dialog_token;
    @memcpy(out[3..][0..p.report_elements.len], p.report_elements);
    return total;
}

/// Figure 9-651（p.1174）：Category、Action、Dialog Token(1)、Transmit Power Used(1)、Max
/// Transmit Power(1)。
pub const LinkMeasurementRequest = struct {
    dialog_token: u8,
    transmit_power_dbm: i8,
    max_transmit_power_dbm: i8,
};

pub fn parseLinkMeasurementRequest(body: []const u8) Error!LinkMeasurementRequest {
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .link_measurement_request);
    if (body.len != 5) return error.TooLong;
    if (body[2] == 0) return error.ZeroDialogToken;
    return .{ .dialog_token = body[2], .transmit_power_dbm = @bitCast(body[3]), .max_transmit_power_dbm = @bitCast(body[4]) };
}

pub fn buildLinkMeasurementRequest(out: []u8, p: LinkMeasurementRequest) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    if (out.len < 5) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.link_measurement_request);
    out[2] = p.dialog_token;
    out[3] = @bitCast(p.transmit_power_dbm);
    out[4] = @bitCast(p.max_transmit_power_dbm);
    return 5;
}

/// Figure 9-652（p.1175）：Category、Action、Dialog Token(1)、TPC Report 元素(4)、Receive
/// Antenna ID(1)、Transmit Antenna ID(1)、RCPI(1)、RSNI(1)。非 DMG BSS 没有后面的可选项。
pub const LinkMeasurementReport = struct {
    dialog_token: u8,
    tpc: TpcReport,
    receive_antenna_id: u8,
    transmit_antenna_id: u8,
    rcpi: u8,
    rsni: u8,
};

pub fn parseLinkMeasurementReport(body: []const u8) Error!LinkMeasurementReport {
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .link_measurement_report);
    // TPC Report 元素紧跟在 Dialog Token 之后：Element ID 35、Length 2。
    if (body.len < 7) return error.MissingElement;
    if (body[3] != @backingInt(ie.ElementId.tpc_report) or body[4] != 2) return error.MissingElement;
    // 非 DMG BSS 没有后面的可选项：帧体固定 11 字节。
    if (body.len != 11) return error.TooLong;
    return .{
        .dialog_token = body[2],
        .tpc = try parseTpcReport(body[5..7]),
        .receive_antenna_id = body[7],
        .transmit_antenna_id = body[8],
        .rcpi = body[9],
        .rsni = body[10],
    };
}

pub fn buildLinkMeasurementReport(out: []u8, p: LinkMeasurementReport) BuildError!usize {
    if (out.len < 11) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.link_measurement_report);
    out[2] = p.dialog_token;
    _ = try buildTpcReport(out[3..], p.tpc);
    out[7] = p.receive_antenna_id;
    out[8] = p.transmit_antenna_id;
    out[9] = p.rcpi;
    out[10] = p.rsni;
    return 11;
}

/// 11.11.13（p.1734）：「The value of the Max Transmit Power field shall be less than or equal
/// to the Max Regulatory Power value for the current channel.」
pub fn maxTransmitPowerValid(max_transmit_power_dbm: i8, max_regulatory_dbm: i8) bool {
    return max_transmit_power_dbm <= max_regulatory_dbm;
}

/// 9.6.7.4（p.1174）：Max Transmit Power 是设备能力、策略、法规三者上限里最小的那个。
pub fn effectiveMaxTransmitPower(device_dbm: i8, policy_dbm: i8, regulatory_dbm: i8) i8 {
    return @min(device_dbm, policy_dbm, regulatory_dbm);
}

/// Figure 9-653（p.1176）：Category、Action、Dialog Token(1)、SSID 元素(可选)、其余可选元素。
pub const NeighborReportRequest = struct {
    dialog_token: u8,
    /// SSID 元素缺席 = 当前 ESS；长度 0 = 通配 SSID（11.11.10.3）。
    ssid: ?[]const u8,
    /// 其余元素（LCI / Location Civic 的 Measurement Request 元素），原样保留。
    elements: []const u8,
};

pub fn parseNeighborReportRequest(body: []const u8) Error!NeighborReportRequest {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .neighbor_report_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    var r = NeighborReportRequest{ .dialog_token = body[2], .ssid = null, .elements = body[3..] };
    var w = ie.Walker.init(r.elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id == @backingInt(ie.ElementId.ssid)) {
            if (el.body.len > ie.ssid_max) return error.TooLong;
            r.ssid = el.body;
        }
    }
    return r;
}

pub const NeighborReportRequestParams = struct {
    dialog_token: u8,
    /// null = 不带 SSID 元素（当前 ESS）；长度 0 = 通配。
    ssid: ?[]const u8 = null,
    extra_elements: []const u8 = &.{},
};

pub fn buildNeighborReportRequest(out: []u8, p: NeighborReportRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    const ssid_len = if (p.ssid) |s| s.len else 0;
    const with_ssid = p.ssid != null;
    const total = 3 + p.extra_elements.len + (if (with_ssid) @as(usize, 2 + ssid_len) else 0);
    if (with_ssid and ssid_len > ie.ssid_max) return error.TooLong;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.neighbor_report_request);
    out[2] = p.dialog_token;
    var pos: usize = 3;
    if (p.ssid) |s| {
        out[pos] = @backingInt(ie.ElementId.ssid);
        out[pos + 1] = @intCast(s.len);
        @memcpy(out[pos + 2 ..][0..s.len], s);
        pos += 2 + s.len;
    }
    @memcpy(out[pos..][0..p.extra_elements.len], p.extra_elements);
    return total;
}

/// Figure 9-654（p.1176）：Category、Action、Dialog Token(1)、Neighbor Report Elements。
pub const NeighborReportResponse = struct {
    dialog_token: u8,
    neighbors: []const u8,
    reports: [max_neighbors]NeighborReport = undefined,
    report_count: u8 = 0,

    pub fn reportSlice(self: *const NeighborReportResponse) []const NeighborReport {
        return self.reports[0..self.report_count];
    }
};

pub const max_neighbors = 10;

pub fn parseNeighborReportResponse(body: []const u8) Error!NeighborReportResponse {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .neighbor_report_response);
    var r = NeighborReportResponse{ .dialog_token = body[2], .neighbors = body[3..] };
    var w = ie.Walker.init(r.neighbors);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        if (r.report_count == max_neighbors) return error.TooMany;
        r.reports[r.report_count] = try parseNeighborReport(el.body);
        r.report_count += 1;
    }
    return r;
}

pub const NeighborReportResponseParams = struct {
    dialog_token: u8,
    /// 已拼好的 Neighbor Report 元素串；没有邻居时为空。
    neighbor_report_elements: []const u8 = &.{},
};

pub fn buildNeighborReportResponse(out: []u8, p: NeighborReportResponseParams) BuildError!usize {
    const total = 3 + p.neighbor_report_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.neighbor_report_response);
    out[2] = p.dialog_token;
    @memcpy(out[3..][0..p.neighbor_report_elements.len], p.neighbor_report_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 10) 量测 STA 侧：接不接 Beacon request（11.11.4 / 11.11.6 / 11.11.7 / 11.11.9.1）
// ---------------------------------------------------------------------------

/// 接收端的 MIB 开关。
pub const Capability = struct {
    /// dot11RMBeaconPassiveMeasurementActivated。
    beacon_passive: bool = false,
    /// dot11RMBeaconActiveMeasurementActivated。
    beacon_active: bool = false,
    /// dot11RMBeaconTableMeasurementActivated。
    beacon_table: bool = false,
    /// dot11RMParallelMeasurementsActivated。
    parallel: bool = false,
    /// dot11RMRepeatedMeasurementsActivated。
    repeated: bool = false,
    /// dot11RMBeaconMeasurementReportingConditionsActivated。
    reporting_conditions: bool = false,
    /// 0 = 不限（Table 11-8 第 1、2 行）；否则是 `maxMeasurementDurationTu()` 的结果。
    max_measurement_duration_tu: u32 = 0,
    /// dot11RMNonOperatingChannelMaxMeasurementDuration：0 = 不支持离信道量测（11.11.4）。
    nonoperating_max_duration_tu: u32 = 0,
};

/// Maximum Measurement Duration in TUs = 2^(dot11RMMaxMeasurementDuration – 4) × BeaconInterval
/// （11.11.4，p.1710）；MIB 值为 0 表示不限。
pub fn maxMeasurementDurationTu(mib: u8, beacon_interval_tu: u16) u32 {
    if (mib == 0) return 0;
    const shift: u32 = @as(u32, mib) - 4;
    if (shift >= 32) return std.math.maxInt(u32);
    return (@as(u32, 1) << @as(u5, @intCast(shift))) *| beacon_interval_tu;
}

pub const RequestContext = struct {
    repetitions: u16 = 0,
    /// RA 是组地址。
    group_addressed: bool = false,
    /// 本 STA 的工作 Operating Class 与主信道。
    operating_class: u8 = 0,
    channel: u8 = 0,
};

pub const RejectReason = enum {
    late,
    incapable,
    refused,

    pub fn mode(self: RejectReason) ReportMode {
        return switch (self) {
            .late => .{ .late = true },
            .incapable => .{ .incapable = true },
            .refused => .{ .refused = true },
        };
    }
};

pub const Accept = union(enum) {
    /// Beacon Table：直接用 BSS 表出报告，不看请求里的信道与时长（11.11.9.1）。
    table,
    /// Passive / Active：调用方按这些参数量测。
    measure: struct {
        channel: u8,
        duration_tu: u16,
        randomization_interval_tu: u16,
    },
};

pub const Rejection = struct {
    reason: RejectReason,
    /// false：组地址帧里的 Incapable / Refused 不回帧（11.11.6）。
    respond: bool,
};

pub const Outcome = union(enum) {
    /// Enable = 1 的元素不是量测请求（Table 9-81），不出报告。
    control,
    accepted: Accept,
    rejected: Rejection,
};

fn reject(reason: RejectReason, ctx: RequestContext) Outcome {
    // 「A STA shall not respond to requests received in group addressed frames in this manner」
    // （11.11.6，p.1713）。
    return .{ .rejected = .{ .reason = reason, .respond = !ctx.group_addressed } };
}

/// Channel Number 为 0 或 255 是「在各信道上逐个量测」，不是单个信道（9.4.2.21.7）。
pub fn isIterativeChannel(channel: u8) bool {
    return channel == 0 or channel == 255;
}

/// 收到一个 Beacon request 后的判决。按顺序核对：Enable 位、类型、模式能力、并行位、重复
/// 量测、Reporting Condition、时长（Table 11-8）。Beacon Table 模式不看信道与时长。
pub fn decide(cap: Capability, m: MeasurementRequest, req: BeaconRequest, ctx: RequestContext) Outcome {
    if (m.mode.enable) return .control;
    // 「The requested measurement type is not supported」→ Incapable（11.11.6）。
    if (m.type != MeasurementType.beacon) return reject(.incapable, ctx);
    const capable = switch (req.mode) {
        .passive => cap.beacon_passive,
        .active => cap.beacon_active,
        .table => cap.beacon_table,
        else => false,
    };
    if (!capable) return reject(.incapable, ctx);
    if (m.mode.parallel and !cap.parallel) return reject(.incapable, ctx);
    if (ctx.repetitions != 0 and !cap.repeated) return reject(.incapable, ctx);
    if (req.beacon_reporting) |b| {
        if (b.condition != 0 and (ctx.repetitions == 0 or !cap.reporting_conditions)) return reject(.incapable, ctx);
    }
    if (req.mode == .table) return .{ .accepted = .table };

    if (req.duration_tu == 0) return reject(.refused, ctx);
    const on_operating = !isIterativeChannel(req.channel) and req.operating_class == ctx.operating_class and req.channel == ctx.channel;
    var limit = cap.max_measurement_duration_tu;
    if (!on_operating) {
        if (cap.nonoperating_max_duration_tu == 0) return reject(.incapable, ctx);
        // Table 11-8 的规则对离信道量测同样成立（11.11.4）。
        limit = if (limit == 0) cap.nonoperating_max_duration_tu else @min(limit, cap.nonoperating_max_duration_tu);
    }
    if (limit != 0 and req.duration_tu > limit and m.mode.duration_mandatory) return reject(.refused, ctx);
    return .{ .accepted = .{ .measure = .{
        .channel = req.channel,
        .duration_tu = req.duration_tu,
        .randomization_interval_tu = req.randomization_interval_tu,
    } } };
}

// ---------------------------------------------------------------------------
// 11) 由 BSS 表出 Beacon report（11.11.9.1）
// ---------------------------------------------------------------------------

pub const SelectWindow = union(enum) {
    /// Beacon Table：不按信道与时长过滤。
    stored,
    /// 量测窗口：只取这段时间内在请求信道上见到的 BSS。
    measured: struct { start_tu: u64, end_tu: u64 },
};

/// 与 Beacon request 匹配的 BSS（11.11.9.1）：BSSID 通配则全部，否则只取那一个；SSID
/// 子元素缺席或长度 0 则不看 SSID。返回写进 `out` 的条数。
pub fn selectBss(table: *const scan.BssTable, req: BeaconRequest, window: SelectWindow, out: []*const scan.Bss) usize {
    var n: usize = 0;
    for (table.entries[0..table.len]) |*b| {
        if (n == out.len) break;
        if (!req.isWildcardBssid() and !std.mem.eql(u8, &b.bssid, &req.bssid)) continue;
        if (!req.ssidIsWildcard() and !std.mem.eql(u8, req.ssid.?, b.ssidSlice())) continue;
        switch (window) {
            .stored => {},
            .measured => |mw| {
                if (b.channel != req.channel) continue;
                if (b.last_seen_tu < mw.start_tu or b.last_seen_tu > mw.end_tu) continue;
            },
        }
        out[n] = b;
        n += 1;
    }
    return n;
}

pub const ReporterOptions = struct {
    /// Beacon report 要带的 Supported Operating Classes 元素体；给出时才报信道号、
    /// Operating Class 与 Reported Frame Information，否则三者写 255（11.11.9.1）。
    supported_operating_classes: ?[]const u8 = null,
    operating_class: u8 = 255,
    /// dot11PHYType；255 表示本表不存 PHY 类型。
    phy_type: u8 = 255,
    /// 收到的 Beacon / Probe Response 帧体；给出且 Reporting Detail ≥ 1 时才带 Reported
    /// Frame Body 子元素。
    frame_body: ?[]const u8 = null,
    /// Beacon Table 模式下量测时间不可知时保持 0（11.11.9.1）。
    start_time: u64 = 0,
    duration_tu: u16 = 0,
    parent_tsf: u32 = 0,
    antenna_id: u8 = 0,
    /// ANPI（dBm）；给出时才算 RSNI，否则写 255（不可用）。
    noise_dbm: ?i16 = null,
};

/// 由 BSS 表的一条排出 Beacon report 的 Measurement Report 元素。RCPI 由 RSSI 换算
/// （Table 9-154）；Reporting Detail 决定 Reported Frame Body 子元素。
pub fn buildBeaconReportFromBss(out: []u8, token: u8, req: BeaconRequest, b: *const scan.Bss, o: ReporterOptions) BuildError!usize {
    var r = BeaconReport{
        .start_time = o.start_time,
        .duration_tu = o.duration_tu,
        .rcpi = rcpiFromDbm(b.rssi),
        .rsni = if (o.noise_dbm) |noise| rsniFromDbm(b.rssi, noise) else not_available,
        .bssid = b.bssid,
        .antenna_id = o.antenna_id,
        .parent_tsf = o.parent_tsf,
    };
    if (o.supported_operating_classes != null) {
        r.operating_class = o.operating_class;
        r.channel = b.channel;
        // Reported Frame Type = 0（Beacon / Probe Response）；PHY 类型未知时整字节写 255。
        r.reported_frame_info = if (o.phy_type > 127) 255 else o.phy_type;
    }
    var sub: [reported_frame_body_max]u8 = undefined;
    if (o.frame_body) |fb| {
        const n = try buildReportedFrameBody(&sub, req.reporting_detail, fb, req.requested[0..req.requested_count]);
        r.subelements = sub[0..n];
    }
    return buildBeaconReportElement(out, token, .{}, r);
}

// ---------------------------------------------------------------------------
// 12) AP 侧：Neighbor Report Response（11.11.10.3）
// ---------------------------------------------------------------------------

/// 请求的 SSID 元素决定邻居范围：缺席 = 本 ESS；通配 = 全部；点名 = 那个 ESS。
pub const NeighborScope = enum {
    own_ess,
    all,
    named,
};

pub fn neighborScope(req: NeighborReportRequest, own_ess: []const u8) NeighborScope {
    const s = req.ssid orelse return .own_ess;
    if (s.len == 0) return .all;
    if (std.mem.eql(u8, s, own_ess)) return .own_ess;
    return .named;
}

/// AP 的邻居表条目：Neighbor Report 元素的内容加上它所属的 ESS。
pub const NeighborInfo = struct {
    report: NeighborReport,
    ess: []const u8,
};

/// 按 SSID 范围筛邻居（11.11.10.3）。返回写进 `out` 的条数。
pub fn selectNeighbors(scope: NeighborScope, named_ess: []const u8, own_ess: []const u8, neighbors: []const NeighborInfo, out: []*const NeighborInfo) usize {
    var n: usize = 0;
    for (neighbors) |*e| {
        if (n == out.len) break;
        const ok = switch (scope) {
            .all => true,
            .own_ess => std.mem.eql(u8, e.ess, own_ess),
            .named => std.mem.eql(u8, e.ess, named_ess),
        };
        if (!ok) continue;
        out[n] = e;
        n += 1;
    }
    return n;
}

/// 进程内的 AP 模型：收到 Neighbor Report Request 后回不回、回哪些邻居。
pub const NeighborReportAp = struct {
    /// dot11RMNeighborReportActivated：false 时忽略请求。
    activated: bool = false,
    own_ess: []const u8 = &.{},
    neighbors: []const NeighborInfo = &.{},
    scratch: [max_neighbors * 256]u8 = undefined,

    /// 回应帧的帧体（Category、Action、Dialog Token、Neighbor Report Elements）；返回 null
    /// 表示 dot11RMNeighborReportActivated 为 false，按 11.11.10.3 忽略请求。
    /// 「If there are no neighbor APs available, the AP shall send a Neighbor Report Response
    /// frame with no Neighbor Report elements」（11.11.10.3）——所以没有邻居时仍回帧。
    pub fn respond(self: *NeighborReportAp, req: NeighborReportRequest, out: []u8) BuildError!?usize {
        if (!self.activated) return null;
        var picked: [max_neighbors]*const NeighborInfo = undefined;
        const scope = neighborScope(req, self.own_ess);
        const n = selectNeighbors(scope, req.ssid orelse "", self.own_ess, self.neighbors, &picked);
        var pos: usize = 0;
        for (picked[0..n]) |e| {
            pos += try buildNeighborReport(self.scratch[pos..], e.report);
        }
        // Dialog Token 回显请求帧（9.6.7.7）。
        return try buildNeighborReportResponse(out, .{ .dialog_token = req.dialog_token, .neighbor_report_elements = self.scratch[0..pos] });
    }
};
