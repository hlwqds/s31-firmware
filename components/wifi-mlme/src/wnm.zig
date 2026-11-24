//! wifi-mlme：Wireless network management（IEEE Std 802.11-2016：11.24.7 的 BSS transition
//! management、11.2.3.18 的 WNM sleep mode，以及 9.4.2.79 / 9.4.2.82 / 9.4.2.37 / 9.6.14 的元素与
//! 帧格式）。
//!
//! 全部是「字节 ↔ 结构」和「输入 → 判决 / 状态」的纯逻辑：不碰射频、不分配堆内存。
//!
//!   1. BSS Transition Management（下称 BTM）Query / Request / Response 三种帧的解析与构造，
//!      Request Mode 各位与候选表的约束；
//!   2. STA 侧：收到 BTM Request 后按候选表与本端 BSS 表（`scan.zig`，只读）决定 BTM Status
//!      Code 与 Target BSSID；
//!   3. AP 侧：由扫描表生成带 Preference 的候选表、Disassociation Timer 的逐 Beacon 递减、
//!      组地址 Request 的条件；
//!   4. WNM Sleep Mode：元素与两种帧的解析 / 构造，STA 侧的进出与 DTIM 期醒来规则，AP 侧的
//!      接受 / 拒绝、停发单播、TIM 位与密钥处理。
//!
//! 对应原文（页码为印刷页码）：
//!
//!   * 11.24.7.1–11.24.7.4（p.1799–1802）：BTM 能力、Query、Request、Response；
//!   * 9.6.14.1 / Table 9-354（p.1225）：WNM Action 字段；9.6.14.8–9.6.14.10（p.1230–1232）、
//!     Figure 9-700–9-705、Table 9-357（p.1233）；
//!   * 9.4.2.37（p.916–921）：Neighbor Report 元素；Figure 9-299 / 9-300、Table 9-152（p.920–921）；
//!   * 11.2.3.18.1–.3（p.1623–1624）：WNM sleep mode 的能力、STA 侧、AP 侧规程；
//!   * 9.4.2.82 / Figure 9-424 / Table 9-203 / Table 9-204（p.1005–1006）：WNM Sleep Mode 元素；
//!   * 9.4.2.79 / Figure 9-416（p.1001）：BSS Max Idle Period 元素；
//!   * 9.6.14.19–9.6.14.20 / Figure 9-715–9-716（p.1237–1238）：WNM Sleep Mode Request / Response；
//!   * 11.2.3.1（p.1600）：PS 模式且不在 WNM sleep mode 的 STA 按 ListenInterval / ReceiveDTIMs
//!     听 Beacon；
//!   * MIB 属性 dot11BssMaxIdlePeriod：Max Idle Period 以 1000 TU 为单位（「number of 1000
//!     TUs that pass before an AP disassociates an inactive non-AP STA」）。
//!
//! 「2016 无明文、依据盘上 hostap」的规则（与上面分开列）：
//!
//!   * 候选表条目没有 Preference 子元素时不算 excluded：2016 只说「Preference 为 0 即
//!     excluded」；hostap `common/wnm_sta.c:337` 是 `preference_present && preference == 0` 才
//!     排除，排序时缺 Preference 的排后面（`wnm_sta.c:743–751`）。本实现同它。
//!   * Accept 时 Target BSSID 总是 6 字节；不知道目标时写 6 个 0（`wnm_sta.c:610–617` 引
//!     P802.11-REVmc 的澄清）。
//!
//! 取舍与偏离：
//!
//!   * 候选表里有候选、但本端 BSS 表里一个都没见过时回 2（Insufficient Beacon or Probe
//!     Response frames received from all candidates）——Table 9-357 的字面含义，且 11.24.7.4
//!     规定 AP 收到 2 后应留出扫描时间再发。hostap 同一情形回 7（`wnm_sta.c:710–713`）。
//!   * BTM Status 3（Insufficient available capacity）需要 BSS Available Admission Capacity /
//!     BSS Load，本端 BSS 表不存，所以判决模型不会产出 3，只把它当作合法码。
//!   * TFS（Traffic Filtering Service，11.24.12）不实现：WNM Sleep Mode 帧里的 TFS 元素原样
//!     透传，AP 侧模型只保留「有排队帧就置 TIM 位」这一条。
//!   * Key Data（GTK / IGTK 的封装）不实现：只保留长度字段与「该走 Key Data 还是组密钥握手」
//!     的判定。
//!
//! 比特编号沿用 9.2.2（p.636）：字段第 N 位落在第 N/8 字节的第 N mod 8 位。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const robust = @import("robust.zig");
const rrm = @import("rrm.zig");
const scan = @import("scan.zig");

pub const Error = rrm.Error || error{
    /// 保留字段不是 0（Disassociation Imminent = 0 时的 Disassociation Timer 等）。
    ReservedField,
    /// Request Mode 的 BSS Termination Included = 1 却没有 BSS Termination Duration 字段。
    MissingTermination,
};

pub const BuildError = rrm.BuildError || error{
    ReservedField,
    MissingTermination,
    /// ESS Disassociation Imminent = 1 却没有 Session Information URL 字段。
    MissingUrl,
    /// 构造 Query / Response 时给出的候选表元素串被截断。
    Truncated,
    /// 构造 Query / Response 时给出的候选表里有非 Neighbor Report 元素。
    UnexpectedElement,
};

fn le16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

fn w16(out: []u8, v: u16) void {
    std.mem.writeInt(u16, out[0..2], v, .little);
}

// ---------------------------------------------------------------------------
// 0) 常量
// ---------------------------------------------------------------------------

/// WNM 的 Category（Table 9-47，p.736：Robust = Yes）。
pub const category: u8 = @backingInt(robust.Category.wnm);

/// Table 9-354（p.1225）：本组件用到的 WNM Action 字段。
pub const Action = enum(u8) {
    btm_query = 6,
    btm_request = 7,
    btm_response = 8,
    sleep_request = 16,
    sleep_response = 17,
    _,
};

/// Table 9-357（p.1233）：BTM status code；9–255 保留。
pub const BtmStatus = struct {
    pub const accept: u8 = 0;
    pub const reject_unspecified: u8 = 1;
    /// Reject—Insufficient Beacon or Probe Response frames received from all candidates。
    pub const reject_insufficient_frames: u8 = 2;
    /// Reject—Insufficient available capacity from all candidates。
    pub const reject_insufficient_capacity: u8 = 3;
    /// Reject—BSS termination undesired。
    pub const reject_termination_undesired: u8 = 4;
    /// Reject—BSS termination delay requested。
    pub const reject_termination_delay: u8 = 5;
    /// Reject—STA BSS Transition Candidate List provided。
    pub const reject_candidate_list_provided: u8 = 6;
    /// Reject—No suitable BSS transition candidates。
    pub const reject_no_suitable_candidates: u8 = 7;
    /// Reject—Leaving ESS。
    pub const reject_leaving_ess: u8 = 8;

    /// Table 9-357 的名字；保留值返回 null。
    pub fn name(code: u8) ?[]const u8 {
        return switch (code) {
            0 => "Accept",
            1 => "Reject-Unspecified reject reason",
            2 => "Reject-Insufficient Beacon or Probe Response frames received from all candidates",
            3 => "Reject-Insufficient available capacity from all candidates",
            4 => "Reject-BSS termination undesired",
            5 => "Reject-BSS termination delay requested",
            6 => "Reject-STA BSS Transition Candidate List provided",
            7 => "Reject-No suitable BSS transition candidates",
            8 => "Reject-Leaving ESS",
            else => null,
        };
    }
};

/// 11.24.7.2（p.1800）：只为提供偏好而发 Query 时，BSS Transition Query Reason 取 19。
pub const query_reason_preferred_candidate_list: u8 = 19;

fn checkHeader(body: []const u8, action: Action) Error!void {
    if (body.len < 2) return error.Truncated;
    if (body[0] != category) return error.BadCategory;
    if (body[1] != @backingInt(action)) return error.BadAction;
}

// ---------------------------------------------------------------------------
// 1) Request Mode 与 BTM Request（9.6.14.9；Figure 9-701 / 9-702 / 9-703 / 9-704）
// ---------------------------------------------------------------------------

/// Figure 9-702（p.1231）：B0 Preferred Candidate List Included、B1 Abridged、B2
/// Disassociation Imminent、B3 BSS Termination Included、B4 ESS Disassociation Imminent、
/// B5–B7 保留。
pub const RequestMode = packed struct(u8) {
    preferred_candidate_list_included: bool = false,
    abridged: bool = false,
    disassociation_imminent: bool = false,
    bss_termination_included: bool = false,
    ess_disassociation_imminent: bool = false,
    reserved: u3 = 0,

    pub fn word(self: RequestMode) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) RequestMode {
        return .{
            .preferred_candidate_list_included = w & 0x01 != 0,
            .abridged = w & 0x02 != 0,
            .disassociation_imminent = w & 0x04 != 0,
            .bss_termination_included = w & 0x08 != 0,
            .ess_disassociation_imminent = w & 0x10 != 0,
        };
    }
};

/// 一帧 BTM Request / Query / Response 里最多放几个候选。
pub const max_candidates = 8;

/// Figure 9-701（p.1230）：Category、WNM Action、Dialog Token(1)、Request mode(1)、
/// Disassociation Timer(2)、Validity Interval(1)、BSS Termination Duration(12，可选)、Session
/// Information URL(可选)、BSS Transition Candidate List Entries(可选)。
pub const BtmRequest = struct {
    dialog_token: u8 = 0,
    mode: RequestMode = .{},
    disassociation_timer: u16 = 0,
    validity_interval: u8 = 0,
    termination: ?rrm.TerminationDuration = null,
    url: ?[]const u8 = null,
    candidates: [max_candidates]rrm.NeighborReport = undefined,
    candidate_count: u8 = 0,

    pub fn candidateSlice(self: *const BtmRequest) []const rrm.NeighborReport {
        return self.candidates[0..self.candidate_count];
    }

    pub fn findCandidate(self: *const BtmRequest, bssid: frame.Mac) ?*const rrm.NeighborReport {
        for (self.candidates[0..self.candidate_count]) |*c| {
            if (std.mem.eql(u8, &c.bssid, &bssid)) return c;
        }
        return null;
    }
};

pub fn parseBtmRequest(body: []const u8) Error!BtmRequest {
    if (body.len < 7) return error.Truncated;
    try checkHeader(body, .btm_request);
    var r = BtmRequest{
        .dialog_token = body[2],
        .mode = RequestMode.fromWord(body[3]),
        .disassociation_timer = le16(body[4..6]),
        .validity_interval = body[6],
    };
    // 「The Dialog Token field is the nonzero value …」（9.6.14.9）。
    if (r.dialog_token == 0) return error.ZeroDialogToken;
    // 「The Validity Interval field is the number of beacon transmission times (TBTTs) until the
    // BSS transition candidate list is no longer valid. A value of 0 is reserved.」
    if (r.validity_interval == 0) return error.ReservedValue;
    // 「If the Disassociation Imminent field is 0, the Disassociation Timer field is reserved.」
    if (!r.mode.disassociation_imminent and r.disassociation_timer != 0) return error.ReservedField;
    var pos: usize = 7;
    if (r.mode.bss_termination_included) {
        // 「present only when the BSS Termination Included field is 1」：子元素 ID 4、Length 10。
        if (body.len - pos < 12) return error.MissingTermination;
        if (body[pos] != rrm.NeighborReportSubelement.bss_termination_duration or body[pos + 1] != 10) return error.BadLength;
        r.termination = .{
            .tsf = std.mem.readInt(u64, body[pos + 2 ..][0..8], .little),
            .duration_minutes = le16(body[pos + 10 ..][0..2]),
        };
        pos += 12;
    }
    if (r.mode.ess_disassociation_imminent) {
        // Figure 9-704：URL Length(1) + URL；「This field is present when the ESS Disassociation
        // Imminent field is 1」。
        if (pos >= body.len) return error.Truncated;
        const n: usize = body[pos];
        pos += 1;
        if (body.len - pos < n) return error.Truncated;
        r.url = body[pos .. pos + n];
        pos += n;
    }
    // 候选表「contains zero or more Neighbor Report elements」。
    var w = ie.Walker.init(body[pos..]);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        if (r.candidate_count == max_candidates) return error.TooMany;
        r.candidates[r.candidate_count] = try rrm.parseNeighborReport(el.body);
        r.candidate_count += 1;
    }
    return r;
}

pub fn buildBtmRequest(out: []u8, r: BtmRequest) BuildError!usize {
    if (r.dialog_token == 0) return error.ZeroDialogToken;
    if (r.validity_interval == 0) return error.ReservedValue;
    if (!r.mode.disassociation_imminent and r.disassociation_timer != 0) return error.ReservedField;
    if (r.mode.bss_termination_included and r.termination == null) return error.MissingTermination;
    const url_len = if (r.url) |u| u.len else 0;
    if (r.mode.ess_disassociation_imminent and r.url == null) return error.MissingUrl;
    const fixed: usize = 7 +
        (if (r.mode.bss_termination_included) @as(usize, 12) else 0) +
        (if (r.mode.ess_disassociation_imminent) @as(usize, 1 + url_len) else 0);
    if (fixed > 255 or out.len < fixed) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.btm_request);
    out[2] = r.dialog_token;
    out[3] = r.mode.word();
    w16(out[4..6], r.disassociation_timer);
    out[6] = r.validity_interval;
    var pos: usize = 7;
    if (r.termination) |t| {
        out[pos] = rrm.NeighborReportSubelement.bss_termination_duration;
        out[pos + 1] = 10;
        std.mem.writeInt(u64, out[pos + 2 ..][0..8], t.tsf, .little);
        w16(out[pos + 10 ..], t.duration_minutes);
        pos += 12;
    }
    if (r.url) |u| {
        out[pos] = @intCast(u.len);
        @memcpy(out[pos + 1 ..][0..u.len], u);
        pos += 1 + u.len;
    }
    for (r.candidateSlice()) |c| pos += try rrm.buildNeighborReport(out[pos..], c);
    return pos;
}

// ---------------------------------------------------------------------------
// 2) 候选表的 Preference 约束（11.24.7.2 / 11.24.7.4；Table 9-152）
// ---------------------------------------------------------------------------

/// Query 与 Response 里的候选表：「The Preference field value … shall be between 1 and 255.
/// The value of 0 is reserved」——所以每条都要带 Preference 子元素，且不是 0。
fn checkPreferenceList(comptime E: type, elements: []const u8) E!void {
    var w = ie.Walker.init(elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        const c = rrm.parseNeighborReport(el.body) catch |e| return switch (e) {
            error.Truncated => error.Truncated,
            else => error.BadLength,
        };
        if ((c.preference orelse 0) == 0) return error.ReservedValue;
    }
}

// ---------------------------------------------------------------------------
// 3) BTM Query（9.6.14.8；Figure 9-700）
// ---------------------------------------------------------------------------

/// Figure 9-700（p.1230）：Category、WNM Action、Dialog Token(1)、BSS Transition Query
/// Reason(1)、BSS Transition Candidate List Entries(可选)。
pub const BtmQuery = struct {
    dialog_token: u8,
    /// Table 9-176（p.969）：Transition and Transition Query reasons。
    reason: u8,
    /// Neighbor Report 元素串，每条都带 1–255 的 Preference。
    candidates: []const u8,
};

pub fn parseBtmQuery(body: []const u8) Error!BtmQuery {
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .btm_query);
    if (body[2] == 0) return error.ZeroDialogToken;
    try checkPreferenceList(Error, body[4..]);
    return .{ .dialog_token = body[2], .reason = body[3], .candidates = body[4..] };
}

pub const BtmQueryParams = struct {
    dialog_token: u8,
    reason: u8,
    /// 已拼好的 Neighbor Report 元素串；只提供偏好时也用 19。
    candidate_elements: []const u8 = &.{},
};

pub fn buildBtmQuery(out: []u8, p: BtmQueryParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    try checkPreferenceList(BuildError, p.candidate_elements);
    const total = 4 + p.candidate_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.btm_query);
    out[2] = p.dialog_token;
    out[3] = p.reason;
    @memcpy(out[4..][0..p.candidate_elements.len], p.candidate_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 4) BTM Response（9.6.14.10；Figure 9-705；Table 9-357）
// ---------------------------------------------------------------------------

/// Figure 9-705（p.1232）：Category、WNM Action、Dialog Token(1)、BTM Status Code(1)、BSS
/// Termination Delay(1)、Target BSSID(6，状态码为 0 时才有)、候选表(可选)。
pub const BtmResponse = struct {
    dialog_token: u8,
    status: u8,
    /// 状态码为 5（Reject—BSS termination delay requested）时是请求延迟的分钟数，否则保留。
    termination_delay: u8,
    /// 状态码为 0 时才有（6 字节；不知道目标时是 6 个 0）。
    target_bssid: ?frame.Mac = null,
    candidates: [max_candidates]rrm.NeighborReport = undefined,
    candidate_count: u8 = 0,

    pub fn candidateSlice(self: *const BtmResponse) []const rrm.NeighborReport {
        return self.candidates[0..self.candidate_count];
    }
};

pub fn parseBtmResponse(body: []const u8) Error!BtmResponse {
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .btm_response);
    var r = BtmResponse{ .dialog_token = body[2], .status = body[3], .termination_delay = body[4] };
    // 「9–255 Reserved」（Table 9-357）。
    if (r.status > BtmStatus.reject_leaving_ess) return error.ReservedValue;
    // 「This field is reserved if the Status code field value is not set to 5.」
    if (r.status != BtmStatus.reject_termination_delay and r.termination_delay != 0) return error.ReservedField;
    var pos: usize = 5;
    if (r.status == BtmStatus.accept) {
        // 「This field is present if the Status code subfield contains 0, and not present otherwise.」
        if (body.len - pos < 6) return error.Truncated;
        r.target_bssid = body[pos..][0..6].*;
        pos += 6;
    }
    var w = ie.Walker.init(body[pos..]);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        if (r.candidate_count == max_candidates) return error.TooMany;
        r.candidates[r.candidate_count] = try rrm.parseNeighborReport(el.body);
        r.candidate_count += 1;
    }
    // 「If the BTM Status Code field is a value of 6 …, the non-AP STA shall include a nonempty
    // BSS Transition Candidate List Entries field」（11.24.7.4）。
    if (r.status == BtmStatus.reject_candidate_list_provided and r.candidate_count == 0) return error.BadValue;
    for (r.candidateSlice()) |c| {
        if ((c.preference orelse 0) == 0) return error.ReservedValue;
    }
    return r;
}

pub const BtmResponseParams = struct {
    dialog_token: u8,
    status: u8,
    termination_delay: u8 = 0,
    /// 状态码为 0 时写进 Target BSSID；null 时写 6 个 0。状态码非 0 时必须为 null。
    target_bssid: ?frame.Mac = null,
    /// 已拼好的 Neighbor Report 元素串；状态码为 6 时不能为空。
    candidate_elements: []const u8 = &.{},
};

pub fn buildBtmResponse(out: []u8, p: BtmResponseParams) BuildError!usize {
    if (p.status > BtmStatus.reject_leaving_ess) return error.ReservedValue;
    if (p.status != BtmStatus.reject_termination_delay and p.termination_delay != 0) return error.ReservedField;
    if (p.status != BtmStatus.accept and p.target_bssid != null) return error.ReservedField;
    if (p.status == BtmStatus.reject_candidate_list_provided and p.candidate_elements.len == 0) return error.BadValue;
    try checkPreferenceList(BuildError, p.candidate_elements);
    const total = 5 + (if (p.status == BtmStatus.accept) @as(usize, 6) else 0) + p.candidate_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.btm_response);
    out[2] = p.dialog_token;
    out[3] = p.status;
    out[4] = p.termination_delay;
    var pos: usize = 5;
    if (p.status == BtmStatus.accept) {
        out[pos..][0..6].* = p.target_bssid orelse @splat(0);
        pos += 6;
    }
    @memcpy(out[pos..][0..p.candidate_elements.len], p.candidate_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 5) STA 侧：怎么回 BTM Request（11.24.7.3 / 11.24.7.4）
// ---------------------------------------------------------------------------

pub const StaConfig = struct {
    /// SME 打算离开 ESS → Reject—Leaving ESS（11.24.7.4）。
    leaving_ess: bool = false,
    /// BSS Termination Included = 1 时的对策：0 接受终止；非 0 是请求延迟的分钟数
    /// （Reject—BSS termination delay，BSS Termination Delay 填这个值）。
    termination_delay_minutes: u8 = 0,
    /// 策略（非标准）：BSSID Information 的 Security 位为 0 的候选不选。9.4.2.37：Security
    /// 位为 0 表示「不支持同样的安全配置，或者信息未知」。
    require_security_match: bool = false,
    /// SME 自己排好的候选表（Neighbor Report 元素串，Preference 1–255）；非空时回 6。
    own_candidate_elements: ?[]const u8 = null,
};

pub const StaContext = struct {
    /// 当前关联的 BSSID：它不是迁移目标。
    current_bssid: frame.Mac = @splat(0),
    received_tu: u64 = 0,
    now_tu: u64 = 0,
    beacon_interval_tu: u16 = 100,
};

pub const Decision = struct {
    status: u8,
    target_bssid: ?frame.Mac = null,
    termination_delay: u8 = 0,
};

/// 候选表还在有效期内：Validity Interval 个 TBTT 之内才可以用（11.24.7.3：「The STA shall
/// not use the corresponding BSS Transition Candidate List Entries field information after the
/// indicated validity interval」）。
pub fn candidatesValid(req: *const BtmRequest, ctx: StaContext) bool {
    const valid_tu: u64 = @as(u64, req.validity_interval) * ctx.beacon_interval_tu;
    return ctx.now_tu <= ctx.received_tu + valid_tu;
}

const Rank = struct {
    /// 候选表的 Preference；没排优先级的（不在表里、或表里没带 Preference）是 0。
    pref: u8,
    rssi: i8,
    bssid: frame.Mac,
};

/// Table 9-152：255 最偏好；偏好相同按 RSSI 强者，再按 BSSID 字典序，保证结果确定。
fn better(a: Rank, b: Rank) bool {
    if (a.pref != b.pref) return a.pref > b.pref;
    if (a.rssi != b.rssi) return a.rssi > b.rssi;
    return std.mem.order(u8, &a.bssid, &b.bssid) == .lt;
}

const ScanResult = struct {
    best: ?Rank,
    /// 还需要扫描（有没见过的候选，或候选范围是开放的）→ 2；否则 → 7。
    needs_scan: bool,
};

fn scanCandidates(req: *const BtmRequest, cfg: StaConfig, table: *const scan.BssTable, ctx: StaContext) ScanResult {
    // 过了有效期就不能再用候选表：当作没有候选表、也没有 Abridged。
    const usable = candidatesValid(req, ctx);
    var res = ScanResult{ .best = null, .needs_scan = !usable or !req.mode.abridged };
    var unseen: usize = 0;
    if (usable) {
        for (req.candidateSlice()) |*c| {
            // 没有 Preference 子元素的候选不算 excluded（hostap common/wnm_sta.c:337）。
            if (c.preference == null or c.preference.? != 0) unseen += 1;
        }
    }
    for (table.entries[0..table.len]) |*b| {
        // 当前关联的 BSS 不是迁移目标。
        if (std.mem.eql(u8, &b.bssid, &ctx.current_bssid)) continue;
        var pref: u8 = 0;
        if (usable) {
            if (req.findCandidate(b.bssid)) |c| {
                // 「A Preference field value of 0 indicates that the BSS listed is an excluded
                // BSS.」（11.24.7.3）：带了 Preference 子元素且值为 0 才排除；没有该子元素的
                // 不算 excluded（hostap common/wnm_sta.c:337），排序时排在所有带 Preference 的之后。
                if (c.preference) |p| {
                    if (p == 0) continue;
                    pref = p;
                }
                // 见过了这个候选：下面即使因为不合适而跳过，也不再算「需要扫描」。
                unseen -= 1;
                if (cfg.require_security_match and !c.bssid_info.security) continue;
            } else if (req.mode.abridged) {
                // 「shall treat any BSSID in the current ESS that does not appear in the BSS
                // Transition Candidate List as if it were present … with a Preference value of 0」
                continue;
            }
        }
        // BTM 的规定不适用于 IBSS（11.24.7.1）。
        if (b.capability.ibss) continue;
        const rank = Rank{ .pref = pref, .rssi = b.rssi, .bssid = b.bssid };
        if (res.best == null or better(rank, res.best.?)) res.best = rank;
    }
    // 候选范围封闭（Abridged = 1 且候选表可用）时：非 excluded 的候选都见过却没选中 → 再扫也没
    // 用；还有没见过的候选 → 需要扫描。
    if (usable and req.mode.abridged) res.needs_scan = unseen != 0;
    return res;
}

/// 收到 BTM Request 后的 Response 内容。
///
///   * BSS Termination Included = 1：0（接受终止）或 5（请求延迟）；
///   * 打算离开 ESS：8；SME 给了自己的候选表：6（Response 必须带非空候选表）；
///   * 扫描表里有非 excluded 的候选：0，Target BSSID 取偏好最高的；
///   * 候选范围封闭（Abridged）且候选全都见过或全被排除：7；
///   * 其余：2（候选还在，但本端没收到它们的 Beacon / Probe Response，需要扫描）。
pub fn decideBtm(req: *const BtmRequest, cfg: StaConfig, table: *const scan.BssTable, ctx: StaContext) Decision {
    if (req.mode.bss_termination_included) {
        if (cfg.termination_delay_minutes != 0) {
            return .{ .status = BtmStatus.reject_termination_delay, .termination_delay = cfg.termination_delay_minutes };
        }
        const best = scanCandidates(req, cfg, table, ctx).best;
        return .{ .status = BtmStatus.accept, .target_bssid = if (best) |b| b.bssid else null };
    }
    if (cfg.leaving_ess) return .{ .status = BtmStatus.reject_leaving_ess };
    if (cfg.own_candidate_elements) |own| {
        if (own.len != 0) return .{ .status = BtmStatus.reject_candidate_list_provided };
    }
    const res = scanCandidates(req, cfg, table, ctx);
    if (res.best) |b| return .{ .status = BtmStatus.accept, .target_bssid = b.bssid };
    if (!res.needs_scan) return .{ .status = BtmStatus.reject_no_suitable_candidates };
    return .{ .status = BtmStatus.reject_insufficient_frames };
}

/// `scan.BssTable.find` 要可变指针；这里只读。
fn findBss(table: *const scan.BssTable, bssid: frame.Mac) ?*const scan.Bss {
    for (table.entries[0..table.len]) |*b| {
        if (std.mem.eql(u8, &b.bssid, &bssid)) return b;
    }
    return null;
}

// ---------------------------------------------------------------------------
// 6) AP 侧：发 BTM Request（11.24.7.3）
// ---------------------------------------------------------------------------

pub const max_btm_stas = 8;

pub const BtmApSta = struct {
    address: frame.Mac = @splat(0),
    /// 关联 STA 的 Extended Capabilities 里 BSS Transition 位（B19，11.24.7.1）。
    supports_btm: bool = false,
    /// 最近一帧 Request 的 Disassociation Imminent = 1。
    disassoc_imminent: bool = false,
    /// 到 AP 发 Disassociation 帧之前还有几个 TBTT。
    disassoc_timer: u16 = 0,
};

/// 进程内的 AP 模型：Disassociation Timer 的记账与组地址 Request 的条件。
pub const BtmAp = struct {
    stas: [max_btm_stas]BtmApSta = @splat(.{}),
    len: u8 = 0,

    pub fn init() BtmAp {
        return .{};
    }

    pub fn count(self: *const BtmAp) usize {
        return self.len;
    }

    pub fn associate(self: *BtmAp, address: frame.Mac, supports_btm: bool) ?*BtmApSta {
        if (self.len == max_btm_stas) return null;
        self.stas[self.len] = .{ .address = address, .supports_btm = supports_btm };
        self.len += 1;
        return &self.stas[self.len - 1];
    }

    pub fn find(self: *BtmAp, address: frame.Mac) ?*BtmApSta {
        for (self.stas[0..self.len]) |*s| {
            if (std.mem.eql(u8, &s.address, &address)) return s;
        }
        return null;
    }

    pub fn dissociate(self: *BtmAp, address: frame.Mac) void {
        for (self.stas[0..self.len], 0..) |*s, i| {
            if (std.mem.eql(u8, &s.address, &address)) {
                self.len -= 1;
                self.stas[i] = self.stas[self.len];
                return;
            }
        }
    }

    /// 「The AP may transmit a group addressed BSS Transition Management Request frame to
    /// associated non-AP STAs if all associated non-AP STAs support the BSS transition
    /// management; otherwise the AP shall not transmit a group addressed BSS Transition
    /// Management Request frame」（11.24.7.3）。
    pub fn groupRequestAllowed(self: *const BtmAp) bool {
        if (self.len == 0) return false;
        for (self.stas[0..self.len]) |s| {
            if (!s.supports_btm) return false;
        }
        return true;
    }

    /// 发出一帧 Disassociation Imminent = 1 的 Request 之后记账：计时器是「0 or the number
    /// of TBTTs that will occur prior to the AP disassociating the non-AP STA」（11.24.7.3）。
    pub fn noteImminentRequest(self: *BtmAp, address: frame.Mac, tbtts: u16) ?*BtmApSta {
        const s = self.find(address) orelse return null;
        s.disassoc_imminent = true;
        s.disassoc_timer = tbtts;
        return s;
    }

    /// 「The AP shall decrement the timer by one after transmitting each Beacon frame until the
    /// timer has value of 0」（11.24.7.3）。后续 Request 带计时器的当前值。
    pub fn onBeaconSent(self: *BtmAp) void {
        for (self.stas[0..self.len]) |*s| {
            if (s.disassoc_timer != 0) s.disassoc_timer -= 1;
        }
    }

    /// 下一帧 Request 里该填的 Disassociation Timer。
    pub fn disassocTimer(self: *BtmAp, address: frame.Mac) u16 {
        const s = self.find(address) orelse return 0;
        return s.disassoc_timer;
    }

    /// 「the AP shall not transmit a Disassociation frame to the non-AP STA unless the timer for
    /// the non-AP STA has value of 0」（11.24.7.3）。
    pub fn mayDisassociate(self: *BtmAp, address: frame.Mac) bool {
        const s = self.find(address) orelse return false;
        return s.disassoc_imminent and s.disassoc_timer == 0;
    }
};

/// 「When the BSS Transition Management Request frame is transmitted as a group addressed frame,
/// a receiving non-AP STA shall not respond with a BSS Transition Management Response frame.」
/// 单播的 Request：「shall respond … with a BSS Transition Management Response frame」（11.24.7.3）。
pub fn responseExpected(group_addressed: bool) bool {
    return !group_addressed;
}

/// AP 给一个候选 BSS 的排位信息。
pub const ApCandidate = struct {
    bssid: frame.Mac,
    /// Table 9-152（p.921）：0 = Excluded BSS，1–255 排序。
    preference: u8 = 0,
    /// BSSID Information 的 Security 位（9.4.2.37）。
    security: bool = false,
    operating_class: u8 = 255,
    /// dot11PHYType；255 表示未知。
    phy_type: u8 = 255,
    /// 只在能保证 TSF Offset 累计误差 ≤ 1.5 TU 时给出（11.11.10.3）。
    tsf: ?rrm.TsfInfo = null,
    termination: ?rrm.TerminationDuration = null,
};

pub const ApRequestParams = struct {
    dialog_token: u8,
    disassoc_imminent: bool = false,
    disassoc_timer: u16 = 0,
    validity_interval: u8,
    candidates: []const ApCandidate,
    /// 发请求的 AP 的国家串；邻居国家不同才带 Condensed Country String 子元素（9.4.2.37）。
    serving_country: [3]u8 = @splat(0),
};

/// 由 AP 的扫描表排 BTM Request：每个在扫描表里见过的候选一个 Neighbor Report 元素（信道号
/// 取自扫描表，Capabilities 位取自 Capability Information，其余取自 `ApCandidate`）。一个
/// 都排不进时 Preferred Candidate List Included = 0（9.6.14.9）。
pub fn buildApRequest(out: []u8, table: *const scan.BssTable, p: ApRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    if (p.validity_interval == 0) return error.ReservedValue;
    if (!p.disassoc_imminent and p.disassoc_timer != 0) return error.ReservedField;
    if (out.len < 7) return error.NoRoom;
    var pos: usize = 7;
    var listed: usize = 0;
    for (p.candidates) |c| {
        const b = findBss(table, c.bssid) orelse continue;
        var n = rrm.NeighborReport{
            .bssid = b.bssid,
            .bssid_info = .{
                .ap_reachability = .unknown,
                .security = c.security,
                .capabilities = rrm.BssidCapabilities.fromCapability(b.capability),
            },
            .operating_class = c.operating_class,
            .channel = b.channel,
            .phy_type = c.phy_type,
            .tsf = c.tsf,
            .preference = c.preference,
            .termination = c.termination,
        };
        // 「present only if the country of the neighbor AP … differs from the country of the AP
        // that sent this neighbor report」（9.4.2.37）。
        if (b.country_present and !std.mem.eql(u8, b.country[0..2], p.serving_country[0..2])) n.condensed_country = b.country[0..2].*;
        pos += try rrm.buildNeighborReport(out[pos..], n);
        listed += 1;
    }
    out[0] = category;
    out[1] = @backingInt(Action.btm_request);
    out[2] = p.dialog_token;
    out[3] = (RequestMode{
        .preferred_candidate_list_included = listed != 0,
        .disassociation_imminent = p.disassoc_imminent,
    }).word();
    w16(out[4..6], p.disassoc_timer);
    out[6] = p.validity_interval;
    return pos;
}

// ---------------------------------------------------------------------------
// 7) WNM Sleep Mode 元素与帧（9.4.2.82；9.6.14.19 / 9.6.14.20）
// ---------------------------------------------------------------------------

/// Table 9-203（p.1006）：Enter 0、Exit 1，其余保留。
pub const SleepActionType = enum(u8) {
    enter = 0,
    exit = 1,
    _,
};

/// Table 9-204（p.1006）：WNM Sleep Mode Response Status；6–255 保留。
pub const SleepStatus = struct {
    /// Enter/Exit WNM sleep mode Accept。
    pub const accept: u8 = 0;
    /// Exit WNM sleep mode Accept, GTK/IGTK update required。
    pub const accept_exit_update_keys: u8 = 1;
    /// Denied. The AP is unable to perform the requested action。
    pub const denied: u8 = 2;
    /// Denied temporarily. The request can be submitted again at a later time。
    pub const denied_temporarily: u8 = 3;
    /// Denied. Due to the pending key expiration。
    pub const denied_key_expiration: u8 = 4;
    /// Denied. Due to other WNM services in use by the requesting STA。
    pub const denied_other_wnm: u8 = 5;

    pub fn name(code: u8) ?[]const u8 {
        return switch (code) {
            0 => "Enter/Exit WNM sleep mode Accept",
            1 => "Exit WNM sleep mode Accept, GTK/IGTK update required",
            2 => "Denied. The AP is unable to perform the requested action",
            3 => "Denied temporarily",
            4 => "Denied. Due to the pending key expiration",
            5 => "Denied. Due to other WNM services in use by the requesting STA",
            else => null,
        };
    }
};

/// Figure 9-424（p.1005）：Action Type(1)、WNM Sleep Mode Response Status(1)、WNM Sleep
/// Interval(2)，Length = 4。
pub const sleep_element_len = 4;

pub const SleepElement = struct {
    action_type: SleepActionType,
    /// 「valid only in the WNM Sleep Mode element in a WNM Sleep Mode Response frame and is
    /// reserved otherwise」（9.4.2.82）。
    response_status: u8 = 0,
    /// 每 DTIM 间隔数醒来一次；0 = 不按固定间隔醒。Action Type = Exit 时保留。
    interval: u16 = 0,
};

pub fn parseSleepElement(body: []const u8) Error!SleepElement {
    if (body.len != sleep_element_len) return error.BadLength;
    if (body[0] > @backingInt(SleepActionType.exit)) return error.ReservedValue;
    if (body[1] > SleepStatus.denied_other_wnm) return error.ReservedValue;
    return .{ .action_type = @fromBackingInt(@intCast(body[0])), .response_status = body[1], .interval = le16(body[2..4]) };
}

pub fn buildSleepElement(out: []u8, e: SleepElement) BuildError!usize {
    if (@backingInt(e.action_type) > @backingInt(SleepActionType.exit)) return error.ReservedValue;
    if (e.response_status > SleepStatus.denied_other_wnm) return error.ReservedValue;
    if (out.len < 6) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.wnm_sleep_mode);
    out[1] = sleep_element_len;
    out[2] = @backingInt(e.action_type);
    out[3] = e.response_status;
    w16(out[4..6], e.interval);
    return 6;
}

/// Figure 9-715（p.1238）：Category、WNM Action、Dialog Token(1)、WNM Sleep Mode Element(6)、
/// TFS Request Elements。
pub const SleepRequest = struct {
    dialog_token: u8,
    element: SleepElement,
    tfs_request: []const u8,
};

pub fn parseSleepRequest(body: []const u8) Error!SleepRequest {
    if (body.len < 9) return error.Truncated;
    try checkHeader(body, .sleep_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    if (body[3] != @backingInt(ie.ElementId.wnm_sleep_mode) or body[4] != sleep_element_len) return error.MissingElement;
    const e = try parseSleepElement(body[5..9]);
    if (e.response_status != 0) return error.ReservedField;
    // 「The WNM Sleep Interval field is reserved if the Action Type field is 1」（9.4.2.82）。
    if (e.action_type == .exit and e.interval != 0) return error.ReservedField;
    return .{ .dialog_token = body[2], .element = e, .tfs_request = body[9..] };
}

pub const SleepRequestParams = struct {
    dialog_token: u8,
    action_type: SleepActionType,
    interval: u16 = 0,
    tfs_request_elements: []const u8 = &.{},
};

pub fn buildSleepRequest(out: []u8, p: SleepRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    if (p.action_type == .exit and p.interval != 0) return error.ReservedField;
    const total = 9 + p.tfs_request_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.sleep_request);
    out[2] = p.dialog_token;
    _ = try buildSleepElement(out[3..], .{ .action_type = p.action_type, .interval = p.interval });
    @memcpy(out[9..][0..p.tfs_request_elements.len], p.tfs_request_elements);
    return total;
}

/// Figure 9-716（p.1238）：Category、WNM Action、Dialog Token(1)、Key Data Length(2)、Key
/// Data、WNM Sleep Mode Element(6)、TFS Response Elements。没有管理帧保护时 Key Data Length = 0。
pub const SleepResponse = struct {
    dialog_token: u8,
    key_data: []const u8,
    element: SleepElement,
    tfs_response: []const u8,
};

pub fn parseSleepResponse(body: []const u8) Error!SleepResponse {
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .sleep_response);
    const n: usize = le16(body[3..5]);
    if (body.len - 5 < n) return error.Truncated;
    var pos: usize = 5 + n;
    if (body.len - pos < 6) return error.MissingElement;
    if (body[pos] != @backingInt(ie.ElementId.wnm_sleep_mode) or body[pos + 1] != sleep_element_len) return error.MissingElement;
    // 只取元素自己的 4 个八位组：后面是 TFS Response Elements（图 9-716），不是元素的一部分。
    const e = try parseSleepElement(body[pos + 2 ..][0..sleep_element_len]);
    if (e.action_type == .exit and e.interval != 0) return error.ReservedField;
    pos += 6;
    return .{ .dialog_token = body[2], .key_data = body[5 .. 5 + n], .element = e, .tfs_response = body[pos..] };
}

pub const SleepResponseParams = struct {
    dialog_token: u8,
    element: SleepElement,
    key_data: []const u8 = &.{},
    tfs_response_elements: []const u8 = &.{},
};

pub fn buildSleepResponse(out: []u8, p: SleepResponseParams) BuildError!usize {
    if (p.element.action_type == .exit and p.element.interval != 0) return error.ReservedField;
    const total = 3 + 2 + p.key_data.len + 6 + p.tfs_response_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.sleep_response);
    out[2] = p.dialog_token;
    w16(out[3..5], @intCast(p.key_data.len));
    @memcpy(out[5..][0..p.key_data.len], p.key_data);
    _ = try buildSleepElement(out[5 + p.key_data.len ..], p.element);
    @memcpy(out[11 + p.key_data.len ..][0..p.tfs_response_elements.len], p.tfs_response_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 8) STA 侧：WNM sleep mode 的进出与 DTIM 期的行为（11.2.3.18.2）
// ---------------------------------------------------------------------------

pub const SleepState = enum { awake, entering, sleeping, exiting };

pub const StateError = error{ Busy, NotSleeping, IntervalTooLong, BadToken };

/// 「The WNM Sleep Interval field shall be less than the BSS max idle period」（11.2.3.18.2）。
/// Max Idle Period 以 1000 TU 为单位（dot11BssMaxIdlePeriod），一个 DTIM 间隔是 dtim_period ×
/// beacon_interval 个 TU。返回满足 interval × dtim_period × beacon_interval < max_idle × 1000
/// 的最大 interval；`max_idle_period` 为 0（没有上限可算）或 DTIM 周期为 0 时返回 0。
pub fn maxSleepInterval(max_idle_period: u16, dtim_period: u8, beacon_interval_tu: u16) u32 {
    if (max_idle_period == 0 or dtim_period == 0 or beacon_interval_tu == 0) return 0;
    const limit_tu: u64 = @as(u64, max_idle_period) * 1000 - 1;
    const per_dtim_tu: u64 = @as(u64, dtim_period) * beacon_interval_tu;
    return @intCast(limit_tu / per_dtim_tu);
}

pub const DtimEvent = union(enum) {
    /// 这个 DTIM 不必醒：WNM sleep mode 下不必每个 DTIM 都醒（11.2.3.18.2）。
    doze,
    /// 醒：`tim_bit` = TIM 里本 STA 的位置了，`group_pending` = AP 缓存了组播。
    wake: struct { tim_bit: bool, group_pending: bool },
};

pub const SleepSta = struct {
    state: SleepState = .awake,
    interval_dtim: u16 = 0,
    pending_token: u8 = 0,
    /// AP 的 Response 指示成功进入：GTKSA（用了 MFP 时连 IGTKSA）要删除（11.2.3.18.2）。
    keys_invalidated: bool = false,
    /// AP 说需要 GTK/IGTK 更新（status 1；新密钥在 Key Data 里）。
    key_update_required: bool = false,
    last_status: u8 = 0,

    pub fn sleeping(self: *const SleepSta) bool {
        return self.state == .sleeping;
    }

    /// 「The non-AP STA does not participate in GTK/IGTK updates」（11.2.3.18.2）。
    pub fn gtkUpdateApplies(self: *const SleepSta) bool {
        return self.state != .sleeping;
    }

    /// 发进入请求。`max_idle_period` 是 AP 在（Re)Association Response 里给的 BSS Max Idle
    /// Period；null 表示 AP 没给，不做比较。
    pub fn requestEnter(self: *SleepSta, token: u8, interval_dtim: u16, max_idle_period: ?u16, dtim_period: u8, beacon_interval_tu: u16) StateError!SleepElement {
        if (self.state != .awake) return error.Busy;
        if (token == 0) return error.BadToken;
        if (max_idle_period) |m| {
            const sleep_tu: u64 = @as(u64, interval_dtim) * dtim_period * beacon_interval_tu;
            if (sleep_tu >= @as(u64, m) * 1000) return error.IntervalTooLong;
        }
        self.state = .entering;
        self.interval_dtim = interval_dtim;
        self.pending_token = token;
        self.keys_invalidated = false;
        self.key_update_required = false;
        return .{ .action_type = .enter, .interval = interval_dtim };
    }

    /// 发退出请求：Action Type = Exit，Interval 保留（11.2.3.18.2）。
    pub fn requestExit(self: *SleepSta, token: u8) StateError!SleepElement {
        if (self.state != .sleeping) return error.NotSleeping;
        if (token == 0) return error.BadToken;
        self.state = .exiting;
        self.pending_token = token;
        return .{ .action_type = .exit };
    }

    /// 请求没有得到 Response（超时）：回到请求之前的状态。
    pub fn onRequestTimeout(self: *SleepSta) void {
        self.state = if (self.state == .entering) .awake else .sleeping;
    }

    /// 收到 AP 的 Response；返回 false 表示忽略（Dialog Token 对不上、Action Type 没回显、
    /// 状态码与请求对不上）。
    ///
    /// 主动发的 Response（Dialog Token = 0）：status 1 让 STA 退出 WNM sleep mode，其余忽略
    /// （11.2.3.18.2）。应答进入请求：status 0 进 sleeping 并删 GTKSA / IGTKSA，2–5 回 awake。
    /// 应答退出请求：status 0 / 1 回 awake（1 表示要更新密钥），2–5 留在 sleeping。
    pub fn onResponse(self: *SleepSta, resp: SleepResponse) bool {
        const status = resp.element.response_status;
        if (resp.dialog_token == 0) {
            const accepted = self.sleeping() and status == SleepStatus.accept_exit_update_keys;
            if (accepted) {
                self.state = .awake;
                self.key_update_required = true;
                self.last_status = status;
            }
            return accepted;
        }
        const want_enter = self.state == .entering;
        if (!want_enter and self.state != .exiting) return false;
        if (resp.dialog_token != self.pending_token) return false;
        const want: SleepActionType = if (want_enter) .enter else .exit;
        if (resp.element.action_type != want) return false;
        self.last_status = status;
        if (want_enter) {
            // status 1（Exit … Accept）只对退出有意义。
            if (status == SleepStatus.accept_exit_update_keys) return false;
            self.state = if (status == SleepStatus.accept) .sleeping else .awake;
            self.keys_invalidated = status == SleepStatus.accept;
            return true;
        }
        const ok = status <= SleepStatus.accept_exit_update_keys;
        self.state = if (ok) .awake else .sleeping;
        self.key_update_required = status == SleepStatus.accept_exit_update_keys;
        return true;
    }

    /// 「The STA wakes up at intervals not longer than the value indicated by the WNM Sleep
    /// Interval field to check whether the corresponding TIM bit is set or group addressed
    /// traffic is pending」（11.2.3.18.2）。Interval = 0：「does not wake up at any specific
    /// interval」（9.4.2.82）。
    pub fn mustWakeAt(self: *const SleepSta, dtim_index: u64) bool {
        if (self.state != .sleeping or self.interval_dtim == 0) return false;
        return dtim_index % self.interval_dtim == 0;
    }

    /// DTIM Beacon 到了：不在醒来点就继续 doze；在醒来点就醒，并读出 TIM 里的两位。
    pub fn onDtim(self: *const SleepSta, tim: ?ie.Tim, dtim_index: u64, aid: u16) DtimEvent {
        if (!self.mustWakeAt(dtim_index)) return .doze;
        const t = tim orelse return .{ .wake = .{ .tim_bit = false, .group_pending = false } };
        return .{ .wake = .{ .tim_bit = t.bitSet(aid), .group_pending = t.multicast_buffered } };
    }
};

// ---------------------------------------------------------------------------
// 9) AP 侧：WNM sleep mode 服务（11.2.3.18.3）
// ---------------------------------------------------------------------------

/// Exit 之后怎么把当前 GTK（有 MFP 时连 IGTK）交给 STA（11.2.3.18.3）。
pub const KeyHandling = enum {
    /// 没有 RSN，或没有配好有效 PTK：不需要。
    none,
    /// RSN + 管理帧保护 + 有效 PTK：当前（更新中则是 pending 的）GTK / IGTK 放进 Response 的 Key Data。
    key_data,
    /// RSN、无管理帧保护、有效 PTK：Response 之后紧接着做组密钥握手（12.7.7）。
    group_key_handshake,
};

pub fn keyHandling(rsn: bool, mfp: bool, ptk: bool) KeyHandling {
    if (!rsn or !ptk) return .none;
    return if (mfp) .key_data else .group_key_handshake;
}

pub const max_sleep_stas = 8;

pub const SleepApSta = struct {
    aid: u16 = 0,
    sleeping: bool = false,
    interval_dtim: u16 = 0,
    rsn: bool = false,
    mfp: bool = false,
    ptk: bool = false,
    /// 有排队的 TFS Notify / 匹配帧：AP 置这个 STA 的 TIM 位。
    tim_bit: bool = false,
    /// 这个 STA 还在用别的 WNM 服务：进入请求回 5。
    other_wnm_in_use: bool = false,
};

/// 进程内的 AP 模型：接受 / 拒绝、停发单播、TIM 位、密钥处理。
pub const SleepAp = struct {
    stas: [max_sleep_stas]SleepApSta = @splat(.{}),
    len: u8 = 0,
    /// AP 正在做 GTK/IGTK 更新：进入请求回 4；此间的 Exit 要带 pending 的密钥。
    key_update_in_progress: bool = false,

    pub fn init() SleepAp {
        return .{};
    }

    pub fn associate(self: *SleepAp, aid: u16, rsn: bool, mfp: bool, ptk: bool) ?*SleepApSta {
        if (aid == 0 or self.len == max_sleep_stas) return null;
        self.stas[self.len] = .{ .aid = aid, .rsn = rsn, .mfp = mfp, .ptk = ptk };
        self.len += 1;
        return &self.stas[self.len - 1];
    }

    pub fn find(self: *SleepAp, aid: u16) ?*SleepApSta {
        for (self.stas[0..self.len]) |*s| {
            if (s.aid == aid) return s;
        }
        return null;
    }

    pub fn dissociate(self: *SleepAp, aid: u16) void {
        for (self.stas[0..self.len], 0..) |*s, i| {
            if (s.aid == aid) {
                self.len -= 1;
                self.stas[i] = self.stas[self.len];
                return;
            }
        }
    }

    /// 处理一帧 Request：改状态，把 Response 写进 `out`（Dialog Token 与 Action Type 回显；
    /// 进入时 Action Type「shall be set to Enter WNM sleep mode」）。
    pub fn onRequest(self: *SleepAp, sta: *SleepApSta, req: SleepRequest, out: []u8) BuildError!usize {
        var element = req.element;
        var status: u8 = SleepStatus.accept;
        switch (element.action_type) {
            .enter => {
                if (self.key_update_in_progress) {
                    status = SleepStatus.denied_key_expiration;
                } else if (sta.other_wnm_in_use) {
                    status = SleepStatus.denied_other_wnm;
                } else {
                    sta.sleeping = true;
                    sta.interval_dtim = element.interval;
                }
            },
            // 「the AP shall disable WNM sleep mode service for the requesting STA」
            .exit => {
                sta.sleeping = false;
                element.interval = 0;
            },
            else => return error.ReservedValue,
        }
        element.response_status = status;
        return buildSleepResponse(out, .{ .dialog_token = req.dialog_token, .element = element });
    }

    /// 「When WNM sleep mode is enabled for an associated STA, the AP shall stop sending all
    /// individually addressed MPDUs to the non-AP STA」（11.2.3.18.3）。
    pub fn unicastAllowed(sta: *const SleepApSta) bool {
        return !sta.sleeping;
    }

    /// 「An AP shall not perform GTK/IGTK updates for the STAs in WNM sleep mode」。
    pub fn gtkUpdateApplies(sta: *const SleepApSta) bool {
        return !sta.sleeping;
    }

    /// 「The AP shall set the TIM bit corresponding to the AID of the associated STA for which
    /// the AP has queued either a TFS Notify frame or matching frame」。
    pub fn queueTfsMatch(self: *SleepAp, aid: u16) bool {
        const s = self.find(aid) orelse return false;
        s.tim_bit = true;
        return true;
    }

    pub fn timBit(self: *SleepAp, aid: u16) bool {
        const s = self.find(aid) orelse return false;
        return s.tim_bit;
    }

    /// 「When all traffic filter sets established for a STA are deleted upon frame matches, the
    /// AP shall also disable the WNM sleep mode service and transmit to the STA an unsolicited
    /// WNM Sleep Mode Response frame with the WNM Sleep Mode Response status value … set to 1」
    /// （11.2.3.18.3）。主动发的帧 Dialog Token 为 0（9.6.14.20）。
    pub fn onFiltersDeleted(sta: *SleepApSta, out: []u8) BuildError!usize {
        sta.sleeping = false;
        return buildSleepResponse(out, .{
            .dialog_token = 0,
            .element = .{ .action_type = .exit, .response_status = SleepStatus.accept_exit_update_keys },
        });
    }
};
