//! wifi-mlme：robust 管理帧的判定（IEEE Std 802.11-2016 12.2.7、12.2.8、12.6.19、12.6.20，
//! 以及它们引用的 Table 9-47）。
//!
//! 只回答「这一帧算不算 robust 管理帧」「该不该为它协商 / 使用保护」两个纯逻辑
//! 问题；真正的加解密与 MIC 不在本组件（归 wifi-connect）。
//!
//! 页码均为印刷页码。

const std = @import("std");

const frame = @import("frame.zig");

/// Action 帧的 Category（Table 9-47，p.736–737）。
pub const Category = enum(u8) {
    spectrum_management = 0,
    qos = 1,
    dls = 2,
    block_ack = 3,
    public = 4,
    radio_measurement = 5,
    fast_bss_transition = 6,
    ht = 7,
    sa_query = 8,
    protected_dual_of_public = 9,
    wnm = 10,
    unprotected_wnm = 11,
    tdls = 12,
    mesh = 13,
    multihop = 14,
    self_protected = 15,
    dmg = 16,
    fast_session_transfer = 18,
    robust_av_streaming = 19,
    unprotected_dmg = 20,
    vht = 21,
    vendor_specific_protected = 126,
    vendor_specific = 127,
    _,
};

/// Radio Measurement 的 Action 字段（Table 9-306，p.1173）。
pub const RadioMeasurementAction = enum(u8) {
    request = 0,
    report = 1,
    link_measurement_request = 2,
    link_measurement_report = 3,
    neighbor_report_request = 4,
    _,
};

/// SA Query 的 Action 字段（Table 9-331，p.1210）。
pub const SaQueryAction = enum(u8) {
    request = 0,
    response = 1,
    _,
};

pub const Verdict = enum {
    robust,
    not_robust,
    /// TDLS Action：总是装在 Data 帧里传，「whether these frames are robust is not
    /// applicable」（Table 9-47 NOTE 2，p.737）。
    not_applicable,
};

pub const ClassifyError = error{
    /// Action / Action No Ack 帧体连 Category 字节都没有。
    MissingCategory,
};

/// Action 类别是否 robust。`action` 是 Category 之后的那一字节，帧体只有 1 字节时
/// 传 null。
///
/// Table 9-47（p.736–737）的 Robust 列逐行如下：
///
///   Code  Meaning                       Robust
///   0     Spectrum Management           Yes
///   1     QoS                           Yes
///   2     DLS                           Yes
///   3     Block Ack                     Yes
///   4     Public                        No
///   5     Radio Measurement             See NOTE 1
///   6     Fast BSS Transition           Yes
///   7     HT                            No
///   8     SA Query                      Yes
///   9     Protected Dual of Public Action Yes
///   10    WNM                           Yes
///   11    Unprotected WNM               No
///   12    TDLS                          —（See NOTE 2）
///   13    Mesh                          Yes
///   14    Multihop                      Yes
///   15    Self-protected                No
///   16    DMG                           Yes
///   17    Reserved (used by the Wi-Fi Alliance) —
///   18    Fast Session Transfer         Yes
///   19    Robust AV Streaming           Yes
///   20    Unprotected DMG               No
///   21    VHT                           No
///   21–125 Reserved                    —
///   126   Vendor-specific Protected    Yes
///   127   Vendor-specific               No
///   128–255 Error                      —
///
/// NOTE 1：Radio Measurement 帧是 robust，只有 DMG BSS 里的 Link Measurement
/// Request / Report 例外。NOTE 2：TDLS Action 总是装在 Data 帧里，这个问题不适用。
pub fn categoryVerdict(category: u8, action: ?u8, dmg_bss: bool) Verdict {
    return switch (category) {
        0, 1, 2, 3, 6, 8, 9, 10, 13, 14, 16, 18, 19, 126 => .robust,
        4, 7, 11, 15, 20, 21, 127 => .not_robust,
        12 => .not_applicable,
        5 => blk: {
            if (!dmg_bss) break :blk .robust;
            const a = action orelse break :blk .robust;
            break :blk switch (a) {
                2, 3 => .not_robust,
                else => .robust,
            };
        },
        // 17、22–125（Reserved）与 128–255（Error）的 Robust 列是「—」；12.2.8 只把
        // 标 Yes 的 Action 帧算作 robust，所以按 not_robust 处理。
        else => .not_robust,
    };
}

/// 一帧是否 robust 管理帧。
///
/// 12.2.8（p.1927）：「The robust Management frames are Disassociation,
/// Deauthentication, and robust Action frames. Action frames specified with “No”
/// in the “Robust” column of Table 9-47 are not robust Management frames and
/// shall not be protected.」
pub fn classify(fc: frame.FrameControl, body: []const u8, dmg_bss: bool) ClassifyError!Verdict {
    if (fc.type != .mgmt) return .not_robust;
    return switch (fc.subtype) {
        @backingInt(frame.MgmtSubtype.disassoc),
        @backingInt(frame.MgmtSubtype.deauth),
        => .robust,
        @backingInt(frame.MgmtSubtype.action),
        @backingInt(frame.MgmtSubtype.action_no_ack),
        => blk: {
            if (body.len == 0) return error.MissingCategory;
            const action: ?u8 = if (body.len >= 2) body[1] else null;
            break :blk categoryVerdict(body[0], action, dmg_bss);
        },
        else => .not_robust,
    };
}

/// 12.2.7（p.1927）：Protected Frame 子字段**必须**置 1 的三类帧之一——
/// 「Individually addressed robust Management frames」与「Authentication frames with
/// Authentication Algorithm Number field equal to 1 (Shared Key) and Authentication
/// Transaction Sequence Number field equal to 3」。Data 帧取决于是否做了加密封装，
/// 不在这里判断。
pub fn protectedFrameShallBeSet(fc: frame.FrameControl, body: []const u8, individually_addressed: bool) bool {
    if (fc.type != .mgmt) return false;
    if (fc.subtype == @backingInt(frame.MgmtSubtype.auth)) {
        if (body.len >= 4) {
            const algorithm = std.mem.readInt(u16, body[0..2], .little);
            const transaction = std.mem.readInt(u16, body[2..4], .little);
            return algorithm == 1 and transaction == 3;
        }
        return false;
    }
    if (!individually_addressed) return false;
    return (classify(fc, body, false) catch .not_robust) == .robust;
}

/// 12.6.20（p.2003）第一句：「A STA with dot11RSNAProtectedManagementFramesActivated
/// equal to true shall negotiate robust management frame protection with a STA that
/// advertised MFPC = 1.」
pub fn negotiateMfp(dot11_rsna_protected_mgmt_frames_activated: bool, peer_mfpc: bool) bool {
    return dot11_rsna_protected_mgmt_frames_activated and peer_mfpc;
}

/// 12.6.20（p.2003）：Public Action 帧若有对应的 Protected Dual of Public Action
/// 帧（9.6.11），用哪种「取决于对应 MLME 原语的 “Protected” 参数；没有这个参数时，
/// 协商了管理帧保护就用保护版本」。
pub fn useProtectedDual(protected_param: ?bool, mfp_negotiated: bool) bool {
    return protected_param orelse mfp_negotiated;
}
