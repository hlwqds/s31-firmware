//! wifi-mlme：非 AP STA 侧的 MLME 状态机与流程（IEEE Std 802.11-2016 Clause 11.3）。
//!
//! 对应原文（页码为印刷页码）：
//!
//!   * 11.3.1（p.1642）状态变量：对每个远端 STA 保存 State 1–4；
//!   * 11.3.2（p.1643）状态迁移图 Figure 11-13；
//!   * 11.3.3（p.1643–1646）按状态过滤帧的 Class 1/2/3；
//!   * 11.3.4.2 / 11.3.4.4 / 11.3.4.5（p.1646–1648）认证与解除认证的发起方 / 目的方流程；
//!   * 11.3.5.2 / 11.3.5.4 / 11.3.5.6 / 11.3.5.7（p.1649–1657）(Re)Association 与
//!     Disassociation 的 STA 侧流程；
//!   * 12.3.3.2（p.1931）Open System 两帧事务；Table 9-36（p.713）；
//!   * 10.3.4.4（p.1328）重传与 SRC/LRC、dot11ShortRetryLimit / dot11LongRetryLimit；
//!   * 10.3.2.11.2（p.1319）序号：模 4096、从 0 起、每个 MMPDU 加 1；
//!   * 9.2.4.4.2（p.647）序号在重传中保持不变。
//!
//! 接口形状：
//!
//!   * 输入事件：`receive`（收到帧）、`tick`（时间，单位 TU）、上层请求
//!     （`authenticate` / `associate` / `reassociate` / `deauthenticate` /
//!     `disassociate` / `setProtection`）；
//!   * 输出：`takeTx` 取走待发帧，`txResult` 回报有无 ACK；
//!   * 上行指示：`poll` 取 MLME-*.confirm / *.indication。
//!
//! 没有堆、没有分配：待发帧与指示都在定长槽里，时间全部由调用方注入。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const mgmt = @import("mgmt.zig");
const robust = @import("robust.zig");

// ---------------------------------------------------------------------------
// 计时器与重传限制
// ---------------------------------------------------------------------------

/// AuthenticateFailureTimeout（6.3.5.2.2，p.280；11.3.4.2 c，p.1647）：认证流程
/// 的时间上限，单位 TU。原文只给了参数名与单位，没有给默认值；本实现的工程常数
/// 取 1024 TU（约 1 s）。
pub const default_authenticate_failure_timeout_tu: u32 = 1024;
/// dot11AssociationResponseTimeout（MIB，p.2785–2786；11.3.5.2 f，p.1650）：请求方
/// 等 (Re)Association 响应的时间，单位 TU。原文的 MIB 定义没有 DEFVAL；本实现的
/// 工程常数取 1024 TU。
pub const default_association_response_timeout_tu: u32 = 1024;
/// dot11ShortRetryLimit 的 DEFVAL { 7 }（MIB，p.3087）。
pub const default_dot11_short_retry_limit: u8 = 7;
/// dot11LongRetryLimit 的 DEFVAL { 4 }（MIB，p.3087）。
pub const default_dot11_long_retry_limit: u8 = 4;
/// dot11RTSThreshold 的 DEFVAL { 65536 }（MIB，p.3086–3087）：比最大 PSDU 还大，
/// 等于关掉 RTS/CTS，于是管理帧全部计入 SRC。
pub const default_dot11_rts_threshold: u32 = 65536;

pub const Config = struct {
    /// dot11RSNAActivated（11.3.1、11.3.5.2 d，p.1642、p.1650）：为 true 时关联成功
    /// 进 State 3，否则直接进 State 4。
    rsna_activated: bool = false,
    authenticate_failure_timeout_tu: u32 = default_authenticate_failure_timeout_tu,
    association_response_timeout_tu: u32 = default_association_response_timeout_tu,
    short_retry_limit: u8 = default_dot11_short_retry_limit,
    long_retry_limit: u8 = default_dot11_long_retry_limit,
    rts_threshold: u32 = default_dot11_rts_threshold,
    /// 发给 AP 的单播管理帧里 Duration/ID 字段的取值。9.3.3.2（p.693）规定
    /// More Fragments=0 时为「发一帧 Ack 的时间加一个 SIFS」，随速率而变，由
    /// 上层按当前速率算好传进来；组地址帧固定为 0。
    unicast_duration: u16 = 0,
};

// ---------------------------------------------------------------------------
// 状态与帧分类
// ---------------------------------------------------------------------------

/// 11.3.1（p.1642）：
///   State 1：未认证、未关联；
///   State 2：已认证、未关联；
///   State 3：已认证、已关联，RSNA 认证未完成，802.1X Controlled Port 阻塞；
///   State 4：已认证、已关联，RSNA 已建立或不需要，端口放行。
pub const State = enum(u3) {
    state1 = 1,
    state2 = 2,
    state3 = 3,
    state4 = 4,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .state1 => "state1",
            .state2 => "state2",
            .state3 => "state3",
            .state4 => "state4",
        };
    }

    pub fn authenticated(self: State) bool {
        return self != .state1;
    }

    pub fn associated(self: State) bool {
        return self == .state3 or self == .state4;
    }
};

pub const FrameClass = enum {
    class1,
    class2,
    class3,
    /// 11.3.3 的三张清单都没列到的帧（Timing Advertisement、Beamforming Report Poll
    /// 等），以及本组件没核对过布局的控制帧子类型。
    unclassified,
};

/// 11.3.3（p.1644–1646）的帧分类，按「infrastructure BSS 里的非 AP STA」取清单：
///
///   Class 1：RTS / CTS / Ack / CF-End / CF-End+CF-Ack；Probe Request/Response、
///            Beacon、ATIM、Authentication、Deauthentication、Public Action、
///            Self-protected Action；DMG Beacon。
///   Class 2：Association / Reassociation Request / Response、Disassociation。
///   Class 3：infrastructure BSS 里 STA 之间的 Data 帧；未被列为 Class 1/2 的
///            Action / Action No Ack；PS-Poll、BlockAck、BlockAckReq、Poll、SPR。
///
/// IBSS、PBSS、DMG 专属的条目不在这里判断。
pub fn classifyFrame(fc: frame.FrameControl, body: []const u8) FrameClass {
    return switch (fc.type) {
        .data => .class3,
        .control => switch (fc.subtype) {
            @backingInt(frame.ControlSubtype.rts),
            @backingInt(frame.ControlSubtype.cts),
            @backingInt(frame.ControlSubtype.ack),
            @backingInt(frame.ControlSubtype.cf_end),
            @backingInt(frame.ControlSubtype.cf_end_cf_ack),
            => .class1,
            @backingInt(frame.ControlSubtype.ps_poll),
            @backingInt(frame.ControlSubtype.block_ack),
            @backingInt(frame.ControlSubtype.block_ack_req),
            => .class3,
            @backingInt(frame.ControlSubtype.control_frame_extension) => switch (fc.control_frame_extension) {
                @backingInt(frame.ControlFrameExtension.poll),
                @backingInt(frame.ControlFrameExtension.spr),
                @backingInt(frame.ControlFrameExtension.dmg_dts),
                => .class3,
                @backingInt(frame.ControlFrameExtension.grant),
                @backingInt(frame.ControlFrameExtension.dmg_cts),
                @backingInt(frame.ControlFrameExtension.grant_ack),
                @backingInt(frame.ControlFrameExtension.ssw),
                @backingInt(frame.ControlFrameExtension.ssw_feedback),
                @backingInt(frame.ControlFrameExtension.ssw_ack),
                => .class1,
                else => .unclassified,
            },
            else => .unclassified,
        },
        .extension => if (fc.subtype == 0) .class1 else .unclassified,
        .mgmt => switch (fc.subtype) {
            @backingInt(frame.MgmtSubtype.probe_req),
            @backingInt(frame.MgmtSubtype.probe_resp),
            @backingInt(frame.MgmtSubtype.beacon),
            @backingInt(frame.MgmtSubtype.atim),
            @backingInt(frame.MgmtSubtype.auth),
            @backingInt(frame.MgmtSubtype.deauth),
            => .class1,
            @backingInt(frame.MgmtSubtype.assoc_req),
            @backingInt(frame.MgmtSubtype.assoc_resp),
            @backingInt(frame.MgmtSubtype.reassoc_req),
            @backingInt(frame.MgmtSubtype.reassoc_resp),
            @backingInt(frame.MgmtSubtype.disassoc),
            => .class2,
            @backingInt(frame.MgmtSubtype.action),
            @backingInt(frame.MgmtSubtype.action_no_ack),
            => blk: {
                if (body.len == 0) break :blk .class3;
                break :blk switch (body[0]) {
                    @backingInt(robust.Category.public),
                    @backingInt(robust.Category.self_protected),
                    => .class1,
                    else => .class3,
                };
            },
            else => .unclassified,
        },
    };
}

pub const FilterAction = enum {
    accept,
    discard,
    /// 11.3.4.1（p.1646）：收到未认证 STA 的 Class 2/3 帧时丢弃；Address 1 是单播
    /// 就回一帧 Deauthentication。
    discard_and_deauthenticate,
    /// 11.3.5.1（p.1648）：收到已认证未关联 STA 的 Class 3 帧时丢弃；Address 1 是
    /// 单播就回一帧 Disassociation。
    discard_and_disassociate,
};

/// 11.3.3（p.1643–1644）：「In State 1, only Class 1 frames are allowed. In State 2,
/// either Class 1 or Class 2 frames are allowed. In State 3 and State 4, all frames
/// are allowed.」
pub fn filterByState(state: State, class: FrameClass, individually_addressed: bool) FilterAction {
    const allowed = switch (state) {
        .state1 => class == .class1,
        .state2 => class == .class1 or class == .class2,
        .state3, .state4 => true,
    };
    if (allowed) return .accept;
    if (!individually_addressed) return .discard;
    return switch (class) {
        .class2 => .discard_and_deauthenticate,
        .class3 => if (state == .state1) .discard_and_deauthenticate else .discard_and_disassociate,
        .class1, .unclassified => .discard,
    };
}

/// 类违规响应帧里的 Reason Code（Table 9-45，p.728）：
/// 6 INVALID_CLASS2_FRAME「Class 2 frame received from nonauthenticated STA」；
/// 7 INVALID_CLASS3_FRAME「Class 3 frame received from nonassociated STA」。
pub fn classViolationReason(class: FrameClass) u16 {
    return if (class == .class2) mgmt.ReasonCode.invalid_class2_frame else mgmt.ReasonCode.invalid_class3_frame;
}

// ---------------------------------------------------------------------------
// 上行指示
// ---------------------------------------------------------------------------

/// MLME-AUTHENTICATE.confirm 的 ResultCode（6.3.5.3.2，p.281）。Open System 只会
/// 产生前两个与超时；ANTI-CLOGGING TOKEN REQUIRED、FINITE CYCLIC GROUP NOT
/// SUPPORTED、AUTHENTICATION REJECTED 属于 SAE / Shared Key，不在本组件范围。
pub const AuthResult = enum {
    success,
    refused,
    auth_failure_timeout,

    pub fn name(self: AuthResult) []const u8 {
        return switch (self) {
            .success => "SUCCESS",
            .refused => "REFUSED",
            .auth_failure_timeout => "AUTH_FAILURE_TIMEOUT",
        };
    }
};

/// MLME-(RE)ASSOCIATE.confirm 的 ResultCode（6.3.7.3.2，p.289；6.3.8.3.2，p.299）
/// 加两个本实现补充的取值（见各项注释）。
pub const AssocResult = enum {
    success,
    refused_reason_unspecified,
    refused_not_authenticated,
    refused_capabilities_mismatch,
    refused_external_reason,
    refused_ap_out_of_memory,
    refused_basic_rates_mismatch,
    rejected_emergency_services_not_supported,
    refused_temporarily,
    /// Association Response 的 Status Code 在上面枚举里没有对应项（例如 17
    /// DENIED_NO_MORE_STAS）；原值放在 `status` 里。
    refused_other,
    /// 11.3.5.4 a)（p.1653）的「STA 未关联到同一 ESS」；原文没有给这一项的 ResultCode。
    refused_not_associated,
    /// dot11AssociationResponseTimeout 到期没收到响应（11.3.5.2 f、11.3.5.4 f）；
    /// 原文只说发 confirm 通知失败，没给 ResultCode。
    association_response_timeout,

    pub fn name(self: AssocResult) []const u8 {
        return switch (self) {
            .success => "SUCCESS",
            .refused_reason_unspecified => "REFUSED_REASON_UNSPECIFIED",
            .refused_not_authenticated => "REFUSED_NOT_AUTHENTICATED",
            .refused_capabilities_mismatch => "REFUSED_CAPABILITIES_MISMATCH",
            .refused_external_reason => "REFUSED_EXTERNAL_REASON",
            .refused_ap_out_of_memory => "REFUSED_AP_OUT_OF_MEMORY",
            .refused_basic_rates_mismatch => "REFUSED_BASIC_RATES_MISMATCH",
            .rejected_emergency_services_not_supported => "REJECTED_EMERGENCY_SERVICES_NOT_SUPPORTED",
            .refused_temporarily => "REFUSED_TEMPORARILY",
            .refused_other => "REFUSED_OTHER",
            .refused_not_associated => "REFUSED_NOT_ASSOCIATED",
            .association_response_timeout => "ASSOCIATION_RESPONSE_TIMEOUT",
        };
    }

    /// 把 Association Response 的 Status Code 折成 ResultCode：名字对得上的按名字，
    /// 其余归 `refused_other`。
    pub fn fromStatus(status: u16) AssocResult {
        return switch (status) {
            mgmt.StatusCode.success, mgmt.StatusCode.success_power_save_mode => .success,
            mgmt.StatusCode.refused_reason_unspecified => .refused_reason_unspecified,
            mgmt.StatusCode.refused_capabilities_mismatch => .refused_capabilities_mismatch,
            92 => .refused_external_reason,
            93 => .refused_ap_out_of_memory,
            mgmt.StatusCode.refused_basic_rates_mismatch => .refused_basic_rates_mismatch,
            94 => .rejected_emergency_services_not_supported,
            mgmt.StatusCode.refused_temporarily => .refused_temporarily,
            else => .refused_other,
        };
    }
};

pub const AssocConfirm = struct {
    peer: frame.Mac,
    result: AssocResult,
    /// Association Response 里的 Status Code 原值；超时或流程没发出时为 0。
    status: u16,
    /// 成功时 AP 分配的 AID（1–2007）。
    aid: u16,
    /// 成功时 AP 的 Capability Information。
    capability: u16,
};

pub const Indication = union(enum) {
    authenticate_confirm: struct { peer: frame.Mac, result: AuthResult, status: u16 },
    deauthenticate_confirm: struct { peer: frame.Mac },
    deauthenticate_indication: struct { peer: frame.Mac, reason_code: u16 },
    associate_confirm: AssocConfirm,
    reassociate_confirm: AssocConfirm,
    disassociate_confirm: struct { peer: frame.Mac },
    disassociate_indication: struct { peer: frame.Mac, reason_code: u16 },

    pub fn name(self: Indication) []const u8 {
        return switch (self) {
            .authenticate_confirm => "authenticate_confirm",
            .deauthenticate_confirm => "deauthenticate_confirm",
            .deauthenticate_indication => "deauthenticate_indication",
            .associate_confirm => "associate_confirm",
            .reassociate_confirm => "reassociate_confirm",
            .disassociate_confirm => "disassociate_confirm",
            .disassociate_indication => "disassociate_indication",
        };
    }
};

// ---------------------------------------------------------------------------
// 发送槽
// ---------------------------------------------------------------------------

pub const TxKind = enum {
    authentication,
    association_request,
    reassociation_request,
    deauthentication,
    disassociation,
    /// 对类违规帧的 Deauthentication 响应（11.3.4.1）。
    deauth_response,
    /// 对类违规帧的 Disassociation 响应（11.3.5.1）。
    disassoc_response,
};

const Procedure = enum { auth, assoc };

fn procedureOf(kind: TxKind) ?Procedure {
    return switch (kind) {
        .authentication => .auth,
        .association_request, .reassociation_request => .assoc,
        else => null,
    };
}

const Pending = struct {
    kind: TxKind,
    peer: frame.Mac,
    hdr: frame.Header,
    buf: [tx_buf_len]u8 = undefined,
    len: u16 = 0,
    /// 10.3.4.4（p.1328）：每个待发 MSDU/MMPDU 各有一份 SRC 与 LRC。
    src: u8 = 0,
    lrc: u8 = 0,
    /// 所属流程已结束（超时或被解除认证）：不再重传。
    cancelled: bool = false,
};

/// 发送缓冲：24 字节帧头 + Association Request 最大帧体（10 + 34 + 10 + 257 + 257）
/// + 4 字节 FCS = 598。
pub const tx_buf_len = 640;
/// Association / Reassociation Request 帧体在缓冲里能占的上限（留出帧头与 FCS）。
pub const assoc_body_max = tx_buf_len - 24 - frame.fcs_len;

pub const TxFrame = struct {
    kind: TxKind,
    /// 整帧，含帧尾 FCS。
    mpdu: []const u8,
    group_addressed: bool,
    /// 这是第几次发送尝试（从 1 起）。
    attempts: u8,
};

pub const TxOutcome = enum { none, delivered, retry, abandoned };

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

pub const max_peers = 4;
pub const indication_capacity = 8;

pub const RequestError = error{
    /// 已有认证/关联流程在进行，或发送槽被占用。
    Busy,
    /// 同时要记住的远端 STA 超过 `max_peers`。
    PeerTableFull,
    /// 超时参数为 0（AuthenticateFailureTimeout 与 dot11AssociationResponseTimeout 的取值范围都从 1 起）。
    InvalidTimeout,
    /// 单播流程的对端地址是组地址，或组地址流程的对端地址是单播。
    InvalidPeer,
    /// 请求里的元素参数不合法：SSID 超过 32 字节、速率或 suite 列表为空。
    InvalidArgument,
    /// 拼出来的帧超过 `tx_buf_len`（帧体超出 `assoc_body_max`，或内部元素表上限）。
    FrameTooLong,
};

pub const Stats = struct {
    tx_attempts: u32 = 0,
    tx_retries: u32 = 0,
    tx_abandoned: u32 = 0,
    discarded_by_state: u32 = 0,
    discarded_unprotected_robust: u32 = 0,
    /// 发送槽被占用、没发出去的类违规响应。
    responses_dropped: u32 = 0,
    indication_dropped: u32 = 0,
};

const Peer = struct {
    used: bool = false,
    mac: frame.Mac = @splat(0),
    state: State = .state1,
    aid: u16 = 0,
    capability: u16 = 0,
};

const AuthPending = struct {
    peer: frame.Mac,
    deadline_tu: u64,
};

const AssocPending = struct {
    peer: frame.Mac,
    reassoc: bool,
    /// Reassociation 时的 Current AP（11.3.5.4，p.1653），成功后它降到 State 2。
    old_ap: frame.Mac,
    deadline_tu: u64,
};

const IndicationQueue = struct {
    buf: [indication_capacity]Indication = undefined,
    head: u4 = 0,
    len: u4 = 0,
    dropped: u32 = 0,

    fn push(self: *IndicationQueue, ev: Indication) void {
        if (self.len < indication_capacity) {
            self.buf[(self.head + self.len) % indication_capacity] = ev;
            self.len += 1;
            return;
        }
        // 满了丢最旧的一条并计数，与 wifi-connect 的事件队列同一约定。
        self.buf[self.head] = ev;
        self.head = (self.head + 1) % indication_capacity;
        self.dropped += 1;
    }
};

pub const Machine = struct {
    own_address: frame.Mac,
    config: Config = .{},
    peers: [max_peers]Peer = .{ .{}, .{}, .{}, .{} },
    /// 10.3.2.11.2（p.1319）：模 4096 的序号计数器，从 0 起。
    seq_counter: u12 = 0,
    tx_pending: ?Pending = null,
    tx_inflight: ?Pending = null,
    auth: ?AuthPending = null,
    assoc: ?AssocPending = null,
    indications: IndicationQueue = .{},
    /// 由 SME 按 12.6.19（p.2002–2003）在 PTK 与 IGTK 装好后置位：之后未保护的
    /// robust 管理帧一律丢弃。
    discard_unprotected_robust: bool = false,
    stats: Stats = .{},

    pub fn init(own_address: frame.Mac, config: Config) Machine {
        return .{ .own_address = own_address, .config = config };
    }

    pub fn reset(self: *Machine) void {
        self.* = init(self.own_address, self.config);
    }

    // ---- 对端状态表 -------------------------------------------------------

    fn findPeer(self: *Machine, peer: frame.Mac) ?*Peer {
        for (&self.peers) |*p| {
            if (p.used and std.mem.eql(u8, &p.mac, &peer)) return p;
        }
        return null;
    }

    fn ensurePeer(self: *Machine, peer: frame.Mac) RequestError!*Peer {
        if (self.findPeer(peer)) |p| return p;
        for (&self.peers) |*p| {
            if (!p.used) {
                p.* = .{ .used = true, .mac = peer, .state = .state1 };
                return p;
            }
        }
        return error.PeerTableFull;
    }

    fn dropPeer(self: *Machine, peer: frame.Mac) void {
        if (self.findPeer(peer)) |p| p.* = .{};
    }

    /// 该远端 STA 的状态变量（11.3.1）；没打过交道的 STA 视为 State 1。
    pub fn stateOf(self: *const Machine, peer: frame.Mac) State {
        for (&self.peers) |*p| {
            if (p.used and std.mem.eql(u8, &p.mac, &peer)) return p.state;
        }
        return .state1;
    }

    /// 当前关联着的 AP（状态 3 或 4 的那一个）；没有返回 null。
    pub fn associatedPeer(self: *const Machine) ?frame.Mac {
        for (&self.peers) |*p| {
            if (p.used and p.state.associated()) return p.mac;
        }
        return null;
    }

    /// 关联成功时 AP 分配的 AID。
    pub fn aidOf(self: *const Machine, peer: frame.Mac) u16 {
        for (&self.peers) |*p| {
            if (p.used and std.mem.eql(u8, &p.mac, &peer)) return p.aid;
        }
        return 0;
    }

    /// 本 STA 所属 BSS 的 BSSID：infrastructure BSS 里就是 AP 的 MAC 地址
    /// （9.2.4.3.4，p.646）。取状态 ≥ 2 的那个 AP。
    fn memberBssid(self: *const Machine) ?frame.Mac {
        for (&self.peers) |*p| {
            if (p.used and p.state.authenticated()) return p.mac;
        }
        return null;
    }

    fn push(self: *Machine, ev: Indication) void {
        self.indications.push(ev);
        self.stats.indication_dropped = self.indications.dropped;
    }

    // ---- 发送槽 -----------------------------------------------------------

    fn nextSeqCtrl(self: *Machine) u16 {
        const sc = @as(u16, self.seq_counter) << 4;
        self.seq_counter +%= 1;
        return sc;
    }

    fn txBusy(self: *const Machine) bool {
        return self.tx_pending != null or self.tx_inflight != null;
    }

    /// 拼一帧单播管理帧（帧尾带 FCS）放进发送槽。Address 1 = 对端，Address 2 =
    /// 本 STA，Address 3 = BSSID（9.3.3.2，p.693）。
    fn queueTx(
        self: *Machine,
        kind: TxKind,
        subtype: frame.MgmtSubtype,
        dst: frame.Mac,
        bssid: frame.Mac,
        body: []const u8,
    ) void {
        const group = frame.isGroupAddress(dst);
        const hdr = frame.Header{
            .fc = .{ .type = .mgmt, .subtype = @backingInt(subtype) },
            .duration_id = .{ .duration = if (group) 0 else self.config.unicast_duration },
            .addr1 = dst,
            .addr2 = self.own_address,
            .addr3 = bssid,
            .seq_ctrl = self.nextSeqCtrl(),
        };
        var p = Pending{ .kind = kind, .peer = dst, .hdr = hdr };
        // 帧体在进这里之前已由 mgmt 构造器校验过长度（≤ assoc_body_max），
        // 布局字段也由本函数填齐，所以 seal 只可能成功。
        p.len = @intCast(frame.seal(hdr, body, true, &p.buf) catch unreachable);
        self.tx_pending = p;
    }

    /// 取走待发帧。返回的切片在下一次 `takeTx` 之前有效。上一帧还没 `txResult`
    /// 时返回 null。
    pub fn takeTx(self: *Machine) ?TxFrame {
        if (self.tx_inflight != null) return null;
        const p = self.tx_pending orelse return null;
        self.tx_pending = null;
        self.stats.tx_attempts += 1;
        self.tx_inflight = p;
        const live = &self.tx_inflight.?;
        return .{
            .kind = live.kind,
            .mpdu = live.buf[0..live.len],
            .group_addressed = frame.isGroupAddress(live.hdr.addr1),
            .attempts = 1 + live.src + live.lrc,
        };
    }

    /// 驱动回报发送结果。组地址帧没有 ACK，发完按 `acked = true` 回报。
    pub fn txResult(self: *Machine, acked: bool) TxOutcome {
        const p = &(self.tx_inflight orelse return .none);
        const kind = p.kind;
        const peer = p.peer;
        if (acked or p.cancelled) {
            self.tx_inflight = null;
            if (!acked) self.stats.tx_abandoned += 1;
            self.completeTx(kind, peer);
            return if (acked) .delivered else .abandoned;
        }
        // 10.3.4.4（p.1328）：PSDU 长度 ≤ dot11RTSThreshold 计 SRC，否则计 LRC。
        if (@as(u32, p.len) <= self.config.rts_threshold) p.src += 1 else p.lrc += 1;
        if (p.src >= self.config.short_retry_limit or p.lrc >= self.config.long_retry_limit) {
            self.tx_inflight = null;
            self.stats.tx_abandoned += 1;
            self.completeTx(kind, peer);
            return .abandoned;
        }
        self.stats.tx_retries += 1;
        // 「All retransmission attempts for an MPDU … that has failed the
        // acknowledgment procedure one or more times shall be made with the Retry
        // subfield set to 1.」序号不变（9.2.4.4.2，p.647）。
        p.hdr.fc.retry = true;
        const hlen = frame.headerLen(p.hdr.fc) catch unreachable;
        p.hdr.encodeInto(p.buf[0..hlen]) catch unreachable;
        // 帧头变了，帧尾 FCS 跟着重算（9.2.4.8：FCS 覆盖帧头与帧体）。
        const body_len: usize = p.len - frame.fcs_len;
        std.mem.writeInt(u32, p.buf[body_len..][0..frame.fcs_len], frame.crc32(p.buf[0..body_len]), .little);
        self.tx_pending = p.*;
        self.tx_inflight = null;
        return .retry;
    }

    /// 11.3.4.4 d)（p.1648）：「Once the Deauthentication frame is acknowledged or
    /// attempts to transmit the frame are abandoned, the MLME shall issue an
    /// MLME-DEAUTHENTICATE.confirm」。
    fn completeTx(self: *Machine, kind: TxKind, peer: frame.Mac) void {
        if (kind == .deauthentication) self.push(.{ .deauthenticate_confirm = .{ .peer = peer } });
    }

    fn cancelProcedureTx(self: *Machine, proc: Procedure, peer: frame.Mac) void {
        if (self.tx_pending) |p| {
            if (procedureOf(p.kind) == proc and std.mem.eql(u8, &p.peer, &peer)) self.tx_pending = null;
        }
        if (self.tx_inflight) |*p| {
            if (procedureOf(p.kind) == proc and std.mem.eql(u8, &p.peer, &peer)) p.cancelled = true;
        }
    }

    // ---- 时间 -------------------------------------------------------------

    /// 时间推进（TU）。到点的流程按 11.3.4.2 c) 与 11.3.5.2 f) / 11.3.5.4 f) 收尾。
    pub fn tick(self: *Machine, now_tu: u64) void {
        if (self.auth) |a| {
            if (now_tu >= a.deadline_tu) {
                self.auth = null;
                self.cancelProcedureTx(.auth, a.peer);
                // 认证失败：状态不变。
                self.push(.{ .authenticate_confirm = .{ .peer = a.peer, .result = .auth_failure_timeout, .status = 0 } });
            }
        }
        if (self.assoc) |a| {
            if (now_tu >= a.deadline_tu) {
                self.assoc = null;
                self.cancelProcedureTx(.assoc, a.peer);
                if (self.findPeer(a.peer)) |p| p.state = .state2;
                const confirm: AssocConfirm = .{ .peer = a.peer, .result = .association_response_timeout, .status = 0, .aid = 0, .capability = 0 };
                self.push(if (a.reassoc) .{ .reassociate_confirm = confirm } else .{ .associate_confirm = confirm });
            }
        }
    }

    // ---- 上层请求（MLME-SAP） --------------------------------------------

    /// MLME-AUTHENTICATE.request（11.3.4.2，p.1646–1647）：发 Open System 的第 1 帧
    /// （12.3.3.2.2，p.1931），然后等第 2 帧，最多等 `authenticate_failure_timeout_tu`。
    pub fn authenticate(self: *Machine, peer: frame.Mac, authenticate_failure_timeout_tu: u32, now_tu: u64) RequestError!void {
        if (frame.isGroupAddress(peer)) return error.InvalidPeer;
        if (self.auth != null or self.assoc != null or self.txBusy()) return error.Busy;
        if (authenticate_failure_timeout_tu == 0) return error.InvalidTimeout;
        _ = try self.ensurePeer(peer);
        var body: [6]u8 = undefined;
        const n = mgmt.buildOpenSystemAuth(1, 0, &body) catch unreachable;
        self.queueTx(.authentication, .auth, peer, peer, body[0..n]);
        self.auth = .{ .peer = peer, .deadline_tu = now_tu +| @as(u64, authenticate_failure_timeout_tu) };
    }

    pub const AssocRequest = struct {
        peer: frame.Mac,
        listen_interval: u16,
        capability: mgmt.Capability = .{},
        ssid: []const u8,
        rates: []const ie.Rate,
        ext_rates: []const ie.Rate = &.{},
        rsne: ?ie.RsneParams = null,
    };

    /// MLME-ASSOCIATE.request（11.3.5.2，p.1649–1650）。State 1 时不发帧，直接回
    /// REFUSED_NOT_AUTHENTICATED 的 confirm（步骤 a）。
    pub fn associate(self: *Machine, r: AssocRequest, now_tu: u64) RequestError!void {
        if (frame.isGroupAddress(r.peer)) return error.InvalidPeer;
        if (self.auth != null or self.assoc != null) return error.Busy;
        if (self.stateOf(r.peer) == .state1) {
            self.push(.{ .associate_confirm = .{ .peer = r.peer, .result = .refused_not_authenticated, .status = 0, .aid = 0, .capability = 0 } });
            return;
        }
        if (self.txBusy()) return error.Busy;
        if (self.config.association_response_timeout_tu == 0) return error.InvalidTimeout;
        var body: [assoc_body_max]u8 = undefined;
        const n = assocBody(.{ .assoc = assocParams(r) }, false, r.peer, &body) catch |e| return mapBuildError(e);
        self.queueTx(.association_request, .assoc_req, r.peer, r.peer, body[0..n]);
        self.assoc = .{ .peer = r.peer, .reassoc = false, .old_ap = r.peer, .deadline_tu = now_tu +| @as(u64, self.config.association_response_timeout_tu) };
    }

    pub const ReassocRequest = struct {
        /// 目标（新）AP。
        peer: frame.Mac,
        /// Current AP Address（9.4.1.5，p.727）。
        current_ap: frame.Mac,
        listen_interval: u16,
        capability: mgmt.Capability = .{},
        ssid: []const u8,
        rates: []const ie.Rate,
        ext_rates: []const ie.Rate = &.{},
        rsne: ?ie.RsneParams = null,
    };

    /// MLME-REASSOCIATE.request（11.3.5.4，p.1652–1654）。步骤 a)：STA 没有关联、
    /// 或目标 AP 的状态是 State 1，直接回 confirm 结束。
    pub fn reassociate(self: *Machine, r: ReassocRequest, now_tu: u64) RequestError!void {
        if (frame.isGroupAddress(r.peer)) return error.InvalidPeer;
        if (self.auth != null or self.assoc != null) return error.Busy;
        var fail: ?AssocResult = null;
        const old = self.findPeer(r.current_ap);
        if (old == null or !old.?.state.associated()) {
            fail = .refused_not_associated;
        } else if (self.stateOf(r.peer) == .state1) {
            fail = .refused_not_authenticated;
        }
        if (fail) |result| {
            self.push(.{ .reassociate_confirm = .{ .peer = r.peer, .result = result, .status = 0, .aid = 0, .capability = 0 } });
            return;
        }
        if (self.txBusy()) return error.Busy;
        if (self.config.association_response_timeout_tu == 0) return error.InvalidTimeout;
        var body: [assoc_body_max]u8 = undefined;
        const n = assocBody(.{ .assoc = assocParams(.{
            .peer = r.peer,
            .listen_interval = r.listen_interval,
            .capability = r.capability,
            .ssid = r.ssid,
            .rates = r.rates,
            .ext_rates = r.ext_rates,
            .rsne = r.rsne,
        }) }, true, r.current_ap, &body) catch |e| return mapBuildError(e);
        self.queueTx(.reassociation_request, .reassoc_req, r.peer, r.peer, body[0..n]);
        self.assoc = .{ .peer = r.peer, .reassoc = true, .old_ap = r.current_ap, .deadline_tu = now_tu +| @as(u64, self.config.association_response_timeout_tu) };
    }

    fn assocParams(r: AssocRequest) mgmt.AssocParams {
        return .{
            .capability = r.capability,
            .listen_interval = r.listen_interval,
            .ssid = r.ssid,
            .rates = r.rates,
            .ext_rates = r.ext_rates,
            .rsne = r.rsne,
        };
    }

    fn assocBody(p: mgmt.ReassocParams, reassoc: bool, current_ap: frame.Mac, out: []u8) mgmt.BuildError!usize {
        return if (reassoc)
            mgmt.buildReassociationRequest(.{ .assoc = p.assoc, .current_ap = current_ap }, out)
        else
            mgmt.buildAssociationRequest(p.assoc, out);
    }

    fn mapBuildError(e: mgmt.BuildError) RequestError {
        return switch (e) {
            // SSID 超过 32 字节、速率或 suite 列表为空：调用方给的参数不合法。
            error.SsidTooLong, error.NoRates, error.NoSuites => error.InvalidArgument,
            // 元素表上限或帧体缓冲装不下。
            error.NoRoom, error.TooManyRates, error.TooManySuites, error.TooManyPmkids => error.FrameTooLong,
            error.BadTransaction => error.InvalidArgument,
        };
    }

    /// MLME-DEAUTHENTICATE.request（11.3.4.4，p.1647–1648）：状态 ≥ 2 时发
    /// Deauthentication 帧，状态置 State 1，帧被确认或放弃后发 confirm。
    pub fn deauthenticate(self: *Machine, peer: frame.Mac, reason_code: u16) RequestError!void {
        if (frame.isGroupAddress(peer)) return error.InvalidPeer;
        const state = self.stateOf(peer);
        if (state == .state1) {
            // 步骤 b)：State 1 不生成帧；原语既然到了，直接 confirm。
            self.push(.{ .deauthenticate_confirm = .{ .peer = peer } });
            return;
        }
        if (self.txBusy()) return error.Busy;
        self.abortProcedures(peer);
        self.dropPeer(peer);
        var body: [2]u8 = undefined;
        const n = mgmt.buildDeauthentication(reason_code, &body) catch unreachable;
        self.queueTx(.deauthentication, .deauth, peer, peer, body[0..n]);
    }

    /// 组地址的 Deauthentication（12.3.3.1，p.1931：「Deauthentication frames are
    /// advisory and may be sent as group addressed frames」）：发给 BSSID 里的所有
    /// STA，不动任何对端的状态。
    pub fn deauthenticateGroup(self: *Machine, bssid: frame.Mac, reason_code: u16) RequestError!void {
        if (frame.isGroupAddress(bssid)) return error.InvalidPeer;
        if (self.txBusy()) return error.Busy;
        var body: [2]u8 = undefined;
        const n = mgmt.buildDeauthentication(reason_code, &body) catch unreachable;
        self.queueTx(.deauthentication, .deauth, frame.broadcast, bssid, body[0..n]);
    }

    /// MLME-DISASSOCIATE.request（11.3.5.6，p.1657）：State 3/4 时发 Disassociation
    /// 帧；状态置 State 2（步骤 b）；随即发 confirm（步骤 c）。
    pub fn disassociate(self: *Machine, peer: frame.Mac, reason_code: u16) RequestError!void {
        if (frame.isGroupAddress(peer)) return error.InvalidPeer;
        const p = self.findPeer(peer);
        if (p == null or !p.?.state.associated()) {
            self.push(.{ .disassociate_confirm = .{ .peer = peer } });
            return;
        }
        if (self.txBusy()) return error.Busy;
        p.?.state = .state2;
        p.?.aid = 0;
        var body: [2]u8 = undefined;
        const n = mgmt.buildDisassociation(reason_code, &body) catch unreachable;
        self.queueTx(.disassociation, .disassoc, peer, peer, body[0..n]);
        self.push(.{ .disassociate_confirm = .{ .peer = peer } });
    }

    /// MLME-SETPROTECTION.request(Rx_Tx)（11.3.5.2 h，p.1650）：把该 STA 置为 State 4。
    /// 只在它当前是 State 3 时生效。
    pub fn setProtection(self: *Machine, peer: frame.Mac) bool {
        const p = self.findPeer(peer) orelse return false;
        if (p.state != .state3) return false;
        p.state = .state4;
        return true;
    }

    /// 该 STA 是否已关联且端口放行（State 4，11.3.1）：Class 3 业务帧可以收发。
    pub fn canSendClass3(self: *const Machine, peer: frame.Mac) bool {
        return self.stateOf(peer).associated();
    }

    fn abortProcedures(self: *Machine, peer: frame.Mac) void {
        var auth_expired = false;
        if (self.auth) |a| {
            if (std.mem.eql(u8, &a.peer, &peer)) {
                self.auth = null;
                auth_expired = true;
            }
        }
        if (auth_expired) self.cancelProcedureTx(.auth, peer);
        var assoc_expired = false;
        if (self.assoc) |a| {
            if (std.mem.eql(u8, &a.peer, &peer)) {
                self.assoc = null;
                assoc_expired = true;
            }
        }
        if (assoc_expired) self.cancelProcedureTx(.assoc, peer);
    }

    // ---- 上行指示 ---------------------------------------------------------

    pub fn poll(self: *Machine) ?Indication {
        var q = &self.indications;
        if (q.len == 0) return null;
        const ev = q.buf[q.head];
        q.head = (q.head + 1) % indication_capacity;
        q.len -= 1;
        return ev;
    }

    // ---- 收帧 -------------------------------------------------------------

    pub const RxOutcome = enum {
        /// 帧改变了状态或产生了一条指示。
        consumed,
        /// Address 1 是别人的单播地址。
        ignored_not_for_us,
        /// Address 2 是本 STA 自己（例如回环的广播）。
        ignored_own_frame,
        /// 组地址帧（Beacon 除外）的 Address 3 不是本 STA 所属 BSS 的 BSSID
        /// （9.3.3.2，p.692）。
        ignored_foreign_bss,
        /// 被 11.3.3 的状态过滤丢弃（可能已排了一帧类违规响应）。
        discarded_by_state,
        /// 12.6.19：装好 PTK/IGTK 后未保护的 robust 管理帧。
        discarded_unprotected_robust,
        /// 不归本状态机处理的帧（Beacon、Probe、Action、Data、控制帧……）。
        ignored_unhandled,
        /// 是本状态机管的子类型，但当前没有等它的流程，或事务号/算法对不上。
        ignored_unexpected,

        pub fn name(self: RxOutcome) []const u8 {
            return switch (self) {
                .consumed => "consumed",
                .ignored_not_for_us => "ignored_not_for_us",
                .ignored_own_frame => "ignored_own_frame",
                .ignored_foreign_bss => "ignored_foreign_bss",
                .discarded_by_state => "discarded_by_state",
                .discarded_unprotected_robust => "discarded_unprotected_robust",
                .ignored_unhandled => "ignored_unhandled",
                .ignored_unexpected => "ignored_unexpected",
            };
        }
    };

    pub const ReceiveError = error{
        MalformedAuthentication,
        MalformedAssociationResponse,
        MalformedDeauthentication,
        MalformedDisassociation,
    };

    pub const RxMeta = struct {
        /// 解封装之前这帧的 Protected Frame 位是否为 1（即下层把它解密出来了）。
        protected: bool = false,
    };

    /// 把一帧交给状态机。`rx` 已由 `frame.parse` 解析（帧尾的 FCS 由驱动校验或已剥离）。
    pub fn receive(self: *Machine, rx: frame.Frame, meta: RxMeta) ReceiveError!RxOutcome {
        const hdr = rx.hdr;
        const group = frame.isGroupAddress(hdr.addr1);
        if (!group and !std.mem.eql(u8, &hdr.addr1, &self.own_address)) return .ignored_not_for_us;
        const ta = hdr.addr2 orelse return .ignored_unhandled;
        if (std.mem.eql(u8, &ta, &self.own_address)) return .ignored_own_frame;
        const is_beacon = hdr.fc.isMgmt(.beacon);
        if (group and !is_beacon) {
            const member = self.memberBssid() orelse return .ignored_foreign_bss;
            const bssid = hdr.addr3 orelse return .ignored_foreign_bss;
            if (!std.mem.eql(u8, &bssid, &member)) return .ignored_foreign_bss;
        }

        // 11.3.3（p.1646）：「“receive” … refers to a frame that meets all the
        // filtering criteria specified in Clause 12 and Clause 10.」所以保护过滤在前。
        if (self.discard_unprotected_robust and !meta.protected) {
            const verdict = robust.classify(hdr.fc, rx.body, false) catch .not_robust;
            if (verdict == .robust) {
                self.stats.discarded_unprotected_robust += 1;
                return .discarded_unprotected_robust;
            }
        }

        const state = self.stateOf(ta);
        const class = classifyFrame(hdr.fc, rx.body);
        // 11.3.3 的过滤适用于所有帧类型（Data 帧是 Class 3），先于子类型分派。
        switch (filterByState(state, class, !group)) {
            .accept => {},
            .discard => {
                self.stats.discarded_by_state += 1;
                return .discarded_by_state;
            },
            .discard_and_deauthenticate, .discard_and_disassociate => {
                self.stats.discarded_by_state += 1;
                self.sendClassViolation(ta, state, class);
                return .discarded_by_state;
            },
        }
        if (hdr.fc.type != .mgmt) return .ignored_unhandled;
        return self.handleMgmt(rx, ta);
    }

    fn sendClassViolation(self: *Machine, ta: frame.Mac, state: State, class: FrameClass) void {
        if (self.txBusy()) {
            self.stats.responses_dropped += 1;
            return;
        }
        var body: [2]u8 = undefined;
        const reason = classViolationReason(class);
        if (class == .class2 or state == .state1) {
            const n = mgmt.buildDeauthentication(reason, &body) catch unreachable;
            self.queueTx(.deauth_response, .deauth, ta, ta, body[0..n]);
        } else {
            const n = mgmt.buildDisassociation(reason, &body) catch unreachable;
            self.queueTx(.disassoc_response, .disassoc, ta, ta, body[0..n]);
        }
    }

    fn handleMgmt(self: *Machine, rx: frame.Frame, ta: frame.Mac) ReceiveError!RxOutcome {
        return switch (rx.hdr.fc.subtype) {
            @backingInt(frame.MgmtSubtype.auth) => self.onAuthentication(rx, ta),
            @backingInt(frame.MgmtSubtype.deauth) => self.onDeauthentication(rx, ta),
            @backingInt(frame.MgmtSubtype.assoc_resp), @backingInt(frame.MgmtSubtype.reassoc_resp) => self.onAssociationResponse(rx, ta),
            @backingInt(frame.MgmtSubtype.disassoc) => self.onDisassociation(rx, ta),
            else => .ignored_unhandled,
        };
    }

    fn onAuthentication(self: *Machine, rx: frame.Frame, ta: frame.Mac) ReceiveError!RxOutcome {
        const a = mgmt.parseAuthentication(rx.body) catch return error.MalformedAuthentication;
        // 对端发来的第 1 帧（认证请求）需要 SME 的 MLME-AUTHENTICATE.response，
        // 属于 11.3.4.3 的目的方流程；非 AP STA 在 infrastructure BSS 里不处理。
        const pending = self.auth orelse return .ignored_unexpected;
        if (!std.mem.eql(u8, &pending.peer, &ta)) return .ignored_unexpected;
        if (!a.isOpenSystem() or a.transaction != 2) return .ignored_unexpected;
        self.auth = null;
        self.cancelProcedureTx(.auth, ta);
        const peer = self.findPeer(ta) orelse return .ignored_unexpected;
        if (a.status == mgmt.StatusCode.success) {
            // 11.3.4.2 c)（p.1647）：State 1 → State 2；其它状态不变。
            if (peer.state == .state1) peer.state = .state2;
            self.push(.{ .authenticate_confirm = .{ .peer = ta, .result = .success, .status = a.status } });
        } else {
            // 「Unsuccessful authentication leaves the STA’s state unchanged」（11.3.4.1）。
            self.push(.{ .authenticate_confirm = .{ .peer = ta, .result = .refused, .status = a.status } });
        }
        return .consumed;
    }

    fn onAssociationResponse(self: *Machine, rx: frame.Frame, ta: frame.Mac) ReceiveError!RxOutcome {
        const r = mgmt.parseAssociationResponse(rx.body) catch return error.MalformedAssociationResponse;
        const pending = self.assoc orelse return .ignored_unexpected;
        if (!std.mem.eql(u8, &pending.peer, &ta)) return .ignored_unexpected;
        const got_reassoc = rx.hdr.fc.subtype == @backingInt(frame.MgmtSubtype.reassoc_resp);
        if (got_reassoc != pending.reassoc) return .ignored_unexpected;
        const peer = self.findPeer(ta) orelse return .ignored_unexpected;
        self.assoc = null;
        self.cancelProcedureTx(.assoc, ta);

        var confirm = AssocConfirm{ .peer = ta, .result = .success, .status = r.status, .aid = 0, .capability = r.capability.word() };
        if (r.success()) {
            // 11.3.5.2 d)（p.1650）/ 11.3.5.4 c)（p.1653）。
            peer.state = if (self.config.rsna_activated) .state3 else .state4;
            peer.aid = r.aid();
            peer.capability = r.capability.word();
            confirm.aid = r.aid();
            for (&self.peers) |*other| {
                if (!other.used or std.mem.eql(u8, &other.mac, &ta)) continue;
                if (!other.state.associated()) continue;
                // Reassociation：新旧 AP 相同时旧 AP 的状态不动。
                if (pending.reassoc and std.mem.eql(u8, &other.mac, &pending.old_ap) and
                    std.mem.eql(u8, &pending.old_ap, &ta)) continue;
                other.state = .state2;
                other.aid = 0;
            }
        } else {
            // 11.3.5.2 f)（p.1650）/ 11.3.5.4 f) 1)（p.1654）：状态置 State 2。
            peer.state = .state2;
            peer.aid = 0;
            confirm.result = AssocResult.fromStatus(r.status);
        }
        self.push(if (pending.reassoc) .{ .reassociate_confirm = confirm } else .{ .associate_confirm = confirm });
        return .consumed;
    }

    /// 11.3.4.5（p.1648）：对端状态是 State 2/3/4 时，发 indication 并把状态置 State 1。
    fn onDeauthentication(self: *Machine, rx: frame.Frame, ta: frame.Mac) ReceiveError!RxOutcome {
        const d = mgmt.parseDeauthentication(rx.body) catch return error.MalformedDeauthentication;
        const peer = self.findPeer(ta) orelse return .ignored_unexpected;
        if (peer.state == .state1) return .ignored_unexpected;
        self.abortProcedures(ta);
        self.dropPeer(ta);
        self.push(.{ .deauthenticate_indication = .{ .peer = ta, .reason_code = d.reason_code } });
        return .consumed;
    }

    /// 11.3.5.7（p.1657）：对端状态是 State 3/4 时，发 indication 并把状态置 State 2。
    fn onDisassociation(self: *Machine, rx: frame.Frame, ta: frame.Mac) ReceiveError!RxOutcome {
        const d = mgmt.parseDisassociation(rx.body) catch return error.MalformedDisassociation;
        const peer = self.findPeer(ta) orelse return .ignored_unexpected;
        if (!peer.state.associated()) return .ignored_unexpected;
        peer.state = .state2;
        peer.aid = 0;
        self.push(.{ .disassociate_indication = .{ .peer = ta, .reason_code = d.reason_code } });
        return .consumed;
    }
};
