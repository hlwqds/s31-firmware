//! wifi-mlme：管理帧的固定字段、Status Code / Reason Code 表，以及 STA 侧帧体的
//! 构造（IEEE Std 802.11-2016 Clause 9.3.3、9.4.1）。
//!
//! 帧体 = 固定字段 + 元素串。这里只解固定字段，元素串原样交出去，由 `ie.zig`
//! 按需解码。构造器按各帧 Table（9-29、9-31、9-33）的顺序写固定字段与元素。
//!
//! 页码均为印刷页码。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");

fn le16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

fn le64(b: *const [8]u8) u64 {
    return std.mem.readInt(u64, b, .little);
}

// ---------------------------------------------------------------------------
// Capability Information（9.4.1.4，p.724；Figure 9-68）
// ---------------------------------------------------------------------------

pub const Capability = packed struct(u16) {
    ess: bool = false,
    ibss: bool = false,
    cf_pollable: bool = false,
    cf_poll_request: bool = false,
    privacy: bool = false,
    short_preamble: bool = false,
    reserved_6_7: u2 = 0,
    spectrum_management: bool = false,
    qos: bool = false,
    short_slot_time: bool = false,
    apsd: bool = false,
    radio_measurement: bool = false,
    reserved_13: u1 = 0,
    delayed_block_ack: bool = false,
    immediate_block_ack: bool = false,

    pub fn word(self: Capability) u16 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u16) Capability {
        return @bitCast(w);
    }
};

// ---------------------------------------------------------------------------
// Authentication Algorithm Number（9.4.1.1，p.723）
// ---------------------------------------------------------------------------

pub const AuthAlgorithm = enum(u16) {
    open_system = 0,
    shared_key = 1,
    fast_bss_transition = 2,
    sae = 3,
    vendor_specific = 65535,
    _,
};

// ---------------------------------------------------------------------------
// Status Code（9.4.1.9；Table 9-46，p.732–736）与 Reason Code（9.4.1.7；Table 9-45，p.728–731）
// ---------------------------------------------------------------------------

const Named = struct { code: u16, name: []const u8 };

/// MLME 流程里会据以分支的 Status Code。
pub const StatusCode = struct {
    pub const success: u16 = 0;
    pub const refused_reason_unspecified: u16 = 1;
    pub const unsupported_auth_algorithm: u16 = 13;
    pub const transaction_sequence_error: u16 = 14;
    pub const refused_capabilities_mismatch: u16 = 10;
    pub const denied_no_more_stas: u16 = 17;
    pub const refused_basic_rates_mismatch: u16 = 18;
    pub const refused_temporarily: u16 = 30;
    /// 9.4.1.9（p.731）：这个取值同样表示操作成功。
    pub const success_power_save_mode: u16 = 85;
    pub const anti_clogging_token_required: u16 = 76;
    pub const unsupported_finite_cyclic_group: u16 = 77;
    pub const rejected_with_suggested_bss_transition: u16 = 82;
};

/// STA 会放进 Deauthentication / Disassociation 帧或据以判断的 Reason Code。
pub const ReasonCode = struct {
    pub const unspecified_reason: u16 = 1;
    pub const invalid_authentication: u16 = 2;
    pub const leaving_network_deauth: u16 = 3;
    pub const invalid_class2_frame: u16 = 6;
    pub const invalid_class3_frame: u16 = 7;
    pub const leaving_network_disassoc: u16 = 8;
};

/// Table 9-46。名字按原文；状态 1 原文写的是「REFUSED, REFUSED_REASON_UNSPECIFIED」
/// 两个别名，这里取第二个。保留值不在表里，`statusCodeName` 返回 null。
const status_names = [_]Named{
    .{ .code = 0, .name = "SUCCESS" },
    .{ .code = 1, .name = "REFUSED_REASON_UNSPECIFIED" },
    .{ .code = 2, .name = "TDLS_REJECTED_ALTERNATIVE_PROVIDED" },
    .{ .code = 3, .name = "TDLS_REJECTED" },
    .{ .code = 5, .name = "SECURITY_DISABLED" },
    .{ .code = 6, .name = "UNACCEPTABLE_LIFETIME" },
    .{ .code = 7, .name = "NOT_IN_SAME_BSS" },
    .{ .code = 10, .name = "REFUSED_CAPABILITIES_MISMATCH" },
    .{ .code = 11, .name = "DENIED_NO_ASSOCIATION_EXISTS" },
    .{ .code = 12, .name = "DENIED_OTHER_REASON" },
    .{ .code = 13, .name = "UNSUPPORTED_AUTH_ALGORITHM" },
    .{ .code = 14, .name = "TRANSACTION_SEQUENCE_ERROR" },
    .{ .code = 15, .name = "CHALLENGE_FAILURE" },
    .{ .code = 16, .name = "REJECTED_SEQUENCE_TIMEOUT" },
    .{ .code = 17, .name = "DENIED_NO_MORE_STAS" },
    .{ .code = 18, .name = "REFUSED_BASIC_RATES_MISMATCH" },
    .{ .code = 19, .name = "DENIED_NO_SHORT_PREAMBLE_SUPPORT" },
    .{ .code = 22, .name = "REJECTED_SPECTRUM_MANAGEMENT_REQUIRED" },
    .{ .code = 23, .name = "REJECTED_BAD_POWER_CAPABILITY" },
    .{ .code = 24, .name = "REJECTED_BAD_SUPPORTED_CHANNELS" },
    .{ .code = 25, .name = "DENIED_NO_SHORT_SLOT_TIME_SUPPORT" },
    .{ .code = 27, .name = "DENIED_NO_HT_SUPPORT" },
    .{ .code = 28, .name = "R0KH_UNREACHABLE" },
    .{ .code = 29, .name = "DENIED_PCO_TIME_NOT_SUPPORTED" },
    .{ .code = 30, .name = "REFUSED_TEMPORARILY" },
    .{ .code = 31, .name = "ROBUST_MANAGEMENT_POLICY_VIOLATION" },
    .{ .code = 32, .name = "UNSPECIFIED_QOS_FAILURE" },
    .{ .code = 33, .name = "DENIED_INSUFFICIENT_BANDWIDTH" },
    .{ .code = 34, .name = "DENIED_POOR_CHANNEL_CONDITIONS" },
    .{ .code = 35, .name = "DENIED_QOS_NOT_SUPPORTED" },
    .{ .code = 37, .name = "REQUEST_DECLINED" },
    .{ .code = 38, .name = "INVALID_PARAMETERS" },
    .{ .code = 39, .name = "REJECTED_WITH_SUGGESTED_CHANGES" },
    .{ .code = 40, .name = "STATUS_INVALID_ELEMENT" },
    .{ .code = 41, .name = "STATUS_INVALID_GROUP_CIPHER" },
    .{ .code = 42, .name = "STATUS_INVALID_PAIRWISE_CIPHER" },
    .{ .code = 43, .name = "STATUS_INVALID_AKMP" },
    .{ .code = 44, .name = "UNSUPPORTED_RSNE_VERSION" },
    .{ .code = 45, .name = "INVALID_RSNE_CAPABILITIES" },
    .{ .code = 46, .name = "STATUS_CIPHER_OUT_OF_POLICY" },
    .{ .code = 47, .name = "REJECTED_FOR_DELAY_PERIOD" },
    .{ .code = 48, .name = "DLS_NOT_ALLOWED" },
    .{ .code = 49, .name = "NOT_PRESENT" },
    .{ .code = 50, .name = "NOT_QOS_STA" },
    .{ .code = 51, .name = "DENIED_LISTEN_INTERVAL_TOO_LARGE" },
    .{ .code = 52, .name = "STATUS_INVALID_FT_ACTION_FRAME_COUNT" },
    .{ .code = 53, .name = "STATUS_INVALID_PMKID" },
    .{ .code = 54, .name = "STATUS_INVALID_MDE" },
    .{ .code = 55, .name = "STATUS_INVALID_FTE" },
    .{ .code = 56, .name = "REQUESTED_TCLAS_NOT_SUPPORTED" },
    .{ .code = 57, .name = "INSUFFICIENT_TCLAS_PROCESSING_RESOURCES" },
    .{ .code = 58, .name = "TRY_ANOTHER_BSS" },
    .{ .code = 59, .name = "GAS_ADVERTISEMENT_PROTOCOL_NOT_SUPPORTED" },
    .{ .code = 60, .name = "NO_OUTSTANDING_GAS_REQUEST" },
    .{ .code = 61, .name = "GAS_RESPONSE_NOT_RECEIVED_FROM_SERVER" },
    .{ .code = 62, .name = "GAS_QUERY_TIMEOUT" },
    .{ .code = 63, .name = "GAS_QUERY_RESPONSE_TOO_LARGE" },
    .{ .code = 64, .name = "REJECTED_HOME_WITH_SUGGESTED_CHANGES" },
    .{ .code = 65, .name = "SERVER_UNREACHABLE" },
    .{ .code = 67, .name = "REJECTED_FOR_SSP_PERMISSIONS" },
    .{ .code = 68, .name = "REFUSED_UNAUTHENTICATED_ACCESS_NOT_SUPPORTED" },
    .{ .code = 72, .name = "INVALID_RSNE" },
    .{ .code = 73, .name = "U_APSD_COEXISTANCE_NOT_SUPPORTED" },
    .{ .code = 74, .name = "U_APSD_COEX_MODE_NOT_SUPPORTED" },
    .{ .code = 75, .name = "BAD_INTERVAL_WITH_U_APSD_COEX" },
    .{ .code = 76, .name = "ANTI_CLOGGING_TOKEN_REQUIRED" },
    .{ .code = 77, .name = "UNSUPPORTED_FINITE_CYCLIC_GROUP" },
    .{ .code = 78, .name = "CANNOT_FIND_ALTERNATIVE_TBTT" },
    .{ .code = 79, .name = "TRANSMISSION_FAILURE" },
    .{ .code = 80, .name = "REQUESTED_TCLAS_NOT_SUPPORTED" },
    .{ .code = 81, .name = "TCLAS_RESOURCES_EXHAUSTED" },
    .{ .code = 82, .name = "REJECTED_WITH_SUGGESTED_BSS_TRANSITION" },
    .{ .code = 83, .name = "REJECT_WITH_SCHEDULE" },
    .{ .code = 84, .name = "REJECT_NO_WAKEUP_SPECIFIED" },
    .{ .code = 85, .name = "SUCCESS_POWER_SAVE_MODE" },
    .{ .code = 86, .name = "PENDING_ADMITTING_FST_SESSION" },
    .{ .code = 87, .name = "PERFORMING_FST_NOW" },
    .{ .code = 88, .name = "PENDING_GAP_IN_BA_WINDOW" },
    .{ .code = 89, .name = "REJECT_U-PID_SETTING" },
    .{ .code = 92, .name = "REFUSED_EXTERNAL_REASON" },
    .{ .code = 93, .name = "REFUSED_AP_OUT_OF_MEMORY" },
    .{ .code = 94, .name = "REJECTED_EMERGENCY_SERVICES_NOT_SUPPORTED" },
    .{ .code = 95, .name = "QUERY_RESPONSE_OUTSTANDING" },
    .{ .code = 96, .name = "REJECT_DSE_BAND" },
    .{ .code = 97, .name = "TCLAS_PROCESSING_TERMINATED" },
    .{ .code = 98, .name = "TS_SCHEDULE_CONFLICT" },
    .{ .code = 99, .name = "DENIED_WITH_SUGGESTED_BAND_AND_CHANNEL" },
    .{ .code = 100, .name = "MCCAOP_RESERVATION_CONFLICT" },
    .{ .code = 101, .name = "MAF_LIMIT_EXCEEDED" },
    .{ .code = 102, .name = "MCCA_TRACK_LIMIT_EXCEEDED" },
    .{ .code = 103, .name = "DENIED_DUE_TO_SPECTRUM_MANAGEMENT" },
    .{ .code = 104, .name = "DENIED_VHT_NOT_SUPPORTED" },
    .{ .code = 105, .name = "ENABLEMENT_DENIED" },
    .{ .code = 106, .name = "RESTRICTION_FROM_AUTHORIZED_GDB" },
    .{ .code = 107, .name = "AUTHORIZATION_DEENABLED" },
};

/// Table 9-45。37 与 38 在原文里各有两三个名字（END_TS / END_BA / END_DLS、
/// UNKNOWN_TS / UNKNOWN_BA），这里取第一个。
const reason_names = [_]Named{
    .{ .code = 1, .name = "UNSPECIFIED_REASON" },
    .{ .code = 2, .name = "INVALID_AUTHENTICATION" },
    .{ .code = 3, .name = "LEAVING_NETWORK_DEAUTH" },
    .{ .code = 4, .name = "REASON_INACTIVITY" },
    .{ .code = 5, .name = "NO_MORE_STAS" },
    .{ .code = 6, .name = "INVALID_CLASS2_FRAME" },
    .{ .code = 7, .name = "INVALID_CLASS3_FRAME" },
    .{ .code = 8, .name = "LEAVING_NETWORK_DISASSOC" },
    .{ .code = 9, .name = "NOT_AUTHENTICATED" },
    .{ .code = 10, .name = "UNACCEPTABLE_POWER_CAPABILITY" },
    .{ .code = 11, .name = "UNACCEPTABLE_SUPPORTED_CHANNELS" },
    .{ .code = 12, .name = "BSS_TRANSITION_DISASSOC" },
    .{ .code = 13, .name = "REASON_INVALID_ELEMENT" },
    .{ .code = 14, .name = "MIC_FAILURE" },
    .{ .code = 15, .name = "4WAY_HANDSHAKE_TIMEOUT" },
    .{ .code = 16, .name = "GK_HANDSHAKE_TIMEOUT" },
    .{ .code = 17, .name = "HANDSHAKE_ELEMENT_MISMATCH" },
    .{ .code = 18, .name = "REASON_INVALID_GROUP_CIPHER" },
    .{ .code = 19, .name = "REASON_INVALID_PAIRWISE_CIPHER" },
    .{ .code = 20, .name = "REASON_INVALID_AKMP" },
    .{ .code = 21, .name = "UNSUPPORTED_RSNE_VERSION" },
    .{ .code = 22, .name = "INVALID_RSNE_CAPABILITIES" },
    .{ .code = 23, .name = "802_1X_AUTH_FAILED" },
    .{ .code = 24, .name = "REASON_CIPHER_OUT_OF_POLICY" },
    .{ .code = 25, .name = "TDLS_PEER_UNREACHABLE" },
    .{ .code = 26, .name = "TDLS_UNSPECIFIED_REASON" },
    .{ .code = 27, .name = "SSP_REQUESTED_DISASSOC" },
    .{ .code = 28, .name = "NO_SSP_ROAMING_AGREEMENT" },
    .{ .code = 29, .name = "BAD_CIPHER_OR_AKM" },
    .{ .code = 30, .name = "NOT_AUTHORIZED_THIS_LOCATION" },
    .{ .code = 31, .name = "SERVICE_CHANGE_PRECLUDES_TS" },
    .{ .code = 32, .name = "UNSPECIFIED_QOS_REASON" },
    .{ .code = 33, .name = "NOT_ENOUGH_BANDWIDTH" },
    .{ .code = 34, .name = "MISSING_ACKS" },
    .{ .code = 35, .name = "EXCEEDED_TXOP" },
    .{ .code = 36, .name = "STA_LEAVING" },
    .{ .code = 37, .name = "END_TS" },
    .{ .code = 38, .name = "UNKNOWN_TS" },
    .{ .code = 39, .name = "TIMEOUT" },
    .{ .code = 45, .name = "PEERKEY_MISMATCH" },
    .{ .code = 46, .name = "PEER_INITIATED" },
    .{ .code = 47, .name = "AP_INITIATED" },
    .{ .code = 48, .name = "REASON_INVALID_FT_ACTION_FRAME_COUNT" },
    .{ .code = 49, .name = "REASON_INVALID_PMKID" },
    .{ .code = 50, .name = "REASON_INVALID_MDE" },
    .{ .code = 51, .name = "REASON_INVALID_FTE" },
    .{ .code = 52, .name = "MESH-PEERING-CANCELED" },
    .{ .code = 53, .name = "MESH-MAX-PEERS" },
    .{ .code = 54, .name = "MESH-CONFIGURATION-POLICY-VIOLATION" },
    .{ .code = 55, .name = "MESH-CLOSE-RCVD" },
    .{ .code = 56, .name = "MESH-MAX-RETRIES" },
    .{ .code = 57, .name = "MESH-CONFIRM-TIMEOUT" },
    .{ .code = 58, .name = "MESH-INVALID-GTK" },
    .{ .code = 59, .name = "MESH-INCONSISTENT-PARAMETERS" },
    .{ .code = 60, .name = "MESH-INVALID-SECURITY-CAPABILITY" },
    .{ .code = 61, .name = "MESH-PATH-ERROR-NO-PROXY-INFORMATION" },
    .{ .code = 62, .name = "MESH-PATH-ERROR-NO-FORWARDING-INFORMATION" },
    .{ .code = 63, .name = "MESH-PATH-ERROR-DESTINATION-UNREACHABLE" },
    .{ .code = 64, .name = "MAC-ADDRESS-ALREADY-EXISTS-IN-MBSS" },
    .{ .code = 65, .name = "MESH-CHANNEL-SWITCH-REGULATORY-REQUIREMENTS" },
    .{ .code = 66, .name = "MESH-CHANNEL-SWITCH-UNSPECIFIED" },
};

fn lookup(table: []const Named, code: u16) ?[]const u8 {
    for (table) |e| {
        if (e.code == code) return e.name;
    }
    return null;
}

pub fn statusCodeName(code: u16) ?[]const u8 {
    return lookup(&status_names, code);
}

pub fn reasonCodeName(code: u16) ?[]const u8 {
    return lookup(&reason_names, code);
}

// ---------------------------------------------------------------------------
// 固定字段解码
// ---------------------------------------------------------------------------

/// Beacon（Table 9-27，p.694）与 Probe Response（Table 9-34，p.708）的前三个
/// 字段相同：Timestamp(8)、Beacon interval(2)、Capability Information(2)。
pub const BssAnnouncement = struct {
    /// TSF timer 值（9.4.1.10，p.736），小端。
    timestamp: u64,
    /// 相邻 TBTT 之间的 TU 数（9.4.1.3，p.724）。
    beacon_interval: u16,
    capability: Capability,
    elements: []const u8,
};

pub const FixedError = error{Truncated};

pub fn parseBeacon(body: []const u8) FixedError!BssAnnouncement {
    return parseBssAnnouncement(body);
}

pub fn parseProbeResponse(body: []const u8) FixedError!BssAnnouncement {
    return parseBssAnnouncement(body);
}

fn parseBssAnnouncement(body: []const u8) FixedError!BssAnnouncement {
    if (body.len < 12) return error.Truncated;
    return .{
        .timestamp = le64(body[0..8]),
        .beacon_interval = le16(body[8..10]),
        .capability = Capability.fromWord(le16(body[10..12])),
        .elements = body[12..],
    };
}

/// Probe Request 没有固定字段，整个帧体是元素串（Table 9-33，p.706–707）。
pub const ProbeRequest = struct {
    elements: []const u8,
};

pub fn parseProbeRequest(body: []const u8) ProbeRequest {
    return .{ .elements = body };
}

/// Authentication（Table 9-35，p.712–713）：Algorithm(2)、Transaction Sequence(2)、
/// Status Code(2)，其后是按算法与事务号决定有无的字段和元素。SAE / FT / Shared Key
/// 的后续内容不在本组件范围内，原样放在 `elements` 里。
pub const Authentication = struct {
    algorithm: u16,
    transaction: u16,
    status: u16,
    elements: []const u8,

    pub fn isOpenSystem(self: Authentication) bool {
        return self.algorithm == @backingInt(AuthAlgorithm.open_system);
    }
};

pub const AuthError = error{
    Truncated,
    /// Table 9-36 规定这一帧「fields 4 onwards: Not present」，却出现了非厂商特定的元素。
    UnexpectedElements,
    /// Open System 第 1 帧的 Status Code 是 Reserved，必须为 0。
    UnexpectedStatus,
    /// Status = REJECTED_WITH_SUGGESTED_BSS_TRANSITION 的 Open System 第 2 帧必须带
    /// Neighbor Report 元素。
    MissingNeighborReport,
};

fn hasOnlyVendorSpecific(elements: []const u8) AuthError!bool {
    var w = ie.Walker.init(elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.vendor_specific)) return false;
    }
    return true;
}

fn hasElement(elements: []const u8, id: ie.ElementId) AuthError!bool {
    var w = ie.Walker.init(elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id == @backingInt(id)) return true;
    }
    return false;
}

pub fn parseAuthentication(body: []const u8) AuthError!Authentication {
    if (body.len < 6) return error.Truncated;
    const a = Authentication{
        .algorithm = le16(body[0..2]),
        .transaction = le16(body[2..4]),
        .status = le16(body[4..6]),
        .elements = body[6..],
    };
    // Table 9-36（p.713）的 Open System 两行：seq 1 无后续字段；seq 2 在
    // REJECTED_WITH_SUGGESTED_BSS_TRANSITION 时带 Neighbor Report，否则无后续字段。
    if (a.isOpenSystem()) {
        switch (a.transaction) {
            1 => {
                if (a.status != 0) return error.UnexpectedStatus;
                if (!(try hasOnlyVendorSpecific(a.elements))) return error.UnexpectedElements;
            },
            2 => {
                if (a.status == StatusCode.rejected_with_suggested_bss_transition) {
                    if (!(try hasElement(a.elements, .neighbor_report))) return error.MissingNeighborReport;
                } else if (!(try hasOnlyVendorSpecific(a.elements))) {
                    return error.UnexpectedElements;
                }
            },
            else => {},
        }
    }
    return a;
}

/// Deauthentication（Table 9-37，p.715）与 Disassociation（Table 9-28，p.699）：
/// Reason Code(2)，其后可选厂商特定元素与（组地址帧的）MME。
pub const Reasoned = struct {
    reason_code: u16,
    elements: []const u8,
};

pub fn parseDeauthentication(body: []const u8) FixedError!Reasoned {
    return parseReasoned(body);
}

pub fn parseDisassociation(body: []const u8) FixedError!Reasoned {
    return parseReasoned(body);
}

fn parseReasoned(body: []const u8) FixedError!Reasoned {
    if (body.len < 2) return error.Truncated;
    return .{ .reason_code = le16(body[0..2]), .elements = body[2..] };
}

/// Association Request（Table 9-29，p.699）：Capability(2)、Listen Interval(2)。
pub const AssociationRequest = struct {
    capability: Capability,
    listen_interval: u16,
    elements: []const u8,
};

pub fn parseAssociationRequest(body: []const u8) FixedError!AssociationRequest {
    if (body.len < 4) return error.Truncated;
    return .{
        .capability = Capability.fromWord(le16(body[0..2])),
        .listen_interval = le16(body[2..4]),
        .elements = body[4..],
    };
}

/// Reassociation Request（Table 9-31，p.702）：多一个 Current AP Address(6)。
pub const ReassociationRequest = struct {
    capability: Capability,
    listen_interval: u16,
    current_ap: frame.Mac,
    elements: []const u8,
};

pub fn parseReassociationRequest(body: []const u8) FixedError!ReassociationRequest {
    if (body.len < 10) return error.Truncated;
    return .{
        .capability = Capability.fromWord(le16(body[0..2])),
        .listen_interval = le16(body[2..4]),
        .current_ap = body[4..10].*,
        .elements = body[10..],
    };
}

/// Association Response（Table 9-30，p.700）与 Reassociation Response（Table 9-32，
/// p.704）：Capability(2)、Status code(2)、AID(2)。
pub const AssociationResponse = struct {
    capability: Capability,
    status: u16,
    /// AID 字段原值（含保留的高 5 位）。
    aid_raw: u16,
    elements: []const u8,

    /// 9.4.1.8（p.731）：非 DMG STA 的 AID 取 1–2007，高 5 位保留（接收端忽略）。
    pub fn aid(self: AssociationResponse) u16 {
        return self.aid_raw & 0x07ff;
    }

    pub fn success(self: AssociationResponse) bool {
        return self.status == StatusCode.success or self.status == StatusCode.success_power_save_mode;
    }
};

pub const AssocRespError = error{ Truncated, BadAid };

pub fn parseAssociationResponse(body: []const u8) AssocRespError!AssociationResponse {
    return parseAssocResp(body);
}

pub fn parseReassociationResponse(body: []const u8) AssocRespError!AssociationResponse {
    return parseAssocResp(body);
}

fn parseAssocResp(body: []const u8) AssocRespError!AssociationResponse {
    if (body.len < 6) return error.Truncated;
    const r = AssociationResponse{
        .capability = Capability.fromWord(le16(body[0..2])),
        .status = le16(body[2..4]),
        .aid_raw = le16(body[4..6]),
        .elements = body[6..],
    };
    // 成功的响应必须给一个合法 AID（1–2007，9.4.1.8，p.731）。
    if (r.success() and (r.aid() == 0 or r.aid() > 2007)) return error.BadAid;
    return r;
}

// ---------------------------------------------------------------------------
// 帧体构造（STA 侧）
// ---------------------------------------------------------------------------

pub const BuildError = error{
    NoRoom,
    SsidTooLong,
    NoRates,
    TooManyRates,
    NoSuites,
    TooManySuites,
    TooManyPmkids,
    /// Open System 的事务号只能是 1 或 2，且第 1 帧的 Status Code 必须为 0。
    BadTransaction,
};

/// Beacon / Probe Response 帧体（AP 侧才会发；给进程内对端用）。
pub fn buildBssAnnouncement(a: BssAnnouncement, elements: []const u8, out: []u8) error{NoRoom}!usize {
    if (out.len < 12 + elements.len) return error.NoRoom;
    std.mem.writeInt(u64, out[0..8], a.timestamp, .little);
    std.mem.writeInt(u16, out[8..10], a.beacon_interval, .little);
    std.mem.writeInt(u16, out[10..12], a.capability.word(), .little);
    @memcpy(out[12..][0..elements.len], elements);
    return 12 + elements.len;
}

pub const ProbeRequestParams = struct {
    /// 0–32 字节；长度 0 是通配 SSID（9.4.2.2，p.790）。
    ssid: []const u8,
    rates: []const ie.Rate,
    ext_rates: []const ie.Rate = &.{},
};

/// Probe Request（Table 9-33 的顺序）：SSID、Supported Rates、[Extended Supported Rates]。
pub fn buildProbeRequest(p: ProbeRequestParams, out: []u8) BuildError!usize {
    var pos: usize = 0;
    pos += try ie.buildSsid(p.ssid, out[pos..]);
    pos += try ie.buildSupportedRates(p.rates, out[pos..]);
    if (p.ext_rates.len != 0) pos += try ie.buildExtSupportedRates(p.ext_rates, out[pos..]);
    return pos;
}

/// Open System 的两帧之一（12.3.3.2，p.1931；Table 9-36）：`transaction` = 1 是
/// 请求（Status 填 0），= 2 是响应。
pub fn buildOpenSystemAuth(transaction: u16, status: u16, out: []u8) error{ NoRoom, BadTransaction }!usize {
    if (transaction != 1 and transaction != 2) return error.BadTransaction;
    if (transaction == 1 and status != 0) return error.BadTransaction;
    if (out.len < 6) return error.NoRoom;
    std.mem.writeInt(u16, out[0..2], @backingInt(AuthAlgorithm.open_system), .little);
    std.mem.writeInt(u16, out[2..4], transaction, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
    return 6;
}

pub const AssocParams = struct {
    capability: Capability = .{},
    listen_interval: u16 = 0,
    ssid: []const u8,
    rates: []const ie.Rate,
    ext_rates: []const ie.Rate = &.{},
    rsne: ?ie.RsneParams = null,
};

/// Association Request（Table 9-29，p.699）：Capability、Listen Interval、SSID、
/// Supported Rates、[Extended Supported Rates]、…、[RSN]。元素按 ID 升序（p.694）。
pub fn buildAssociationRequest(p: AssocParams, out: []u8) BuildError!usize {
    if (out.len < 4) return error.NoRoom;
    std.mem.writeInt(u16, out[0..2], p.capability.word(), .little);
    std.mem.writeInt(u16, out[2..4], p.listen_interval, .little);
    return 4 + try buildAssocElements(p, out[4..]);
}

pub const ReassocParams = struct {
    assoc: AssocParams,
    /// Current AP Address（9.4.1.5，p.727）：当前关联的 AP 的 MAC 地址。
    current_ap: frame.Mac = @splat(0),
};

/// Reassociation Request（Table 9-31，p.702）：比 Association Request 多一个
/// Current AP Address。
pub fn buildReassociationRequest(p: ReassocParams, out: []u8) BuildError!usize {
    if (out.len < 10) return error.NoRoom;
    std.mem.writeInt(u16, out[0..2], p.assoc.capability.word(), .little);
    std.mem.writeInt(u16, out[2..4], p.assoc.listen_interval, .little);
    out[4..10].* = p.current_ap;
    return 10 + try buildAssocElements(p.assoc, out[10..]);
}

fn buildAssocElements(p: AssocParams, out: []u8) BuildError!usize {
    var pos: usize = 0;
    pos += try ie.buildSsid(p.ssid, out[pos..]);
    pos += try ie.buildSupportedRates(p.rates, out[pos..]);
    if (p.ext_rates.len != 0) pos += try ie.buildExtSupportedRates(p.ext_rates, out[pos..]);
    if (p.rsne) |rsne| pos += try ie.buildRsne(rsne, out[pos..]);
    return pos;
}

pub fn buildDeauthentication(reason_code: u16, out: []u8) error{NoRoom}!usize {
    if (out.len < 2) return error.NoRoom;
    std.mem.writeInt(u16, out[0..2], reason_code, .little);
    return 2;
}

pub fn buildDisassociation(reason_code: u16, out: []u8) error{NoRoom}!usize {
    return buildDeauthentication(reason_code, out);
}

pub const AssocRespParams = struct {
    capability: Capability,
    status: u16,
    /// 1–2007；高 5 位写 0（保留位发送时置 0，9.2.2，p.637）。
    aid: u16,
    /// 跟在固定字段后面的元素串（Supported Rates 等），由调用方拼好。
    elements: []const u8 = &.{},
};

/// Association Response / Reassociation Response 帧体：Capability、Status code、
/// AID，其后是元素。AP 侧才会发；进程内对端用它拼响应。
pub fn buildAssociationResponse(p: AssocRespParams, out: []u8) error{ NoRoom, BadAid }!usize {
    if (p.aid > 2007) return error.BadAid;
    if (out.len < 6 + p.elements.len) return error.NoRoom;
    std.mem.writeInt(u16, out[0..2], p.capability.word(), .little);
    std.mem.writeInt(u16, out[2..4], p.status, .little);
    std.mem.writeInt(u16, out[4..6], p.aid, .little);
    @memcpy(out[6..][0..p.elements.len], p.elements);
    return 6 + p.elements.len;
}
