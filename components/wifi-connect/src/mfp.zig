//! wifi-connect：管理帧保护规则与 SA Query。
//!
//! 哪些帧必须保护，由三处合起来定：
//!   12.2.8（印刷页 1927）：稳健管理帧 = Disassociation、Deauthentication、
//!     表 9-47（印刷页 736–737）Robust 列为 Yes 的 Action 帧；
//!     Robust 列为 No 的 Action 帧不是稳健管理帧，不得保护。
//!   12.6.19（印刷页 2002–2003）：按 dot11RSNAProtectedManagementFramesActivated、
//!     dot11RSNAUnprotectedManagementFramesAllowed、对端 MFPC、PTK/IGTK 是否已安装，
//!     决定收到的帧收还是丢。
//!   12.6.20（印刷页 2003）：与通告 MFPC = 1 的 STA 协商管理帧保护；协商结果在
//!     4 次握手里用双方 RSNE 的 MFPC 位确认（12.6.3，印刷页 1992）。
//!
//! SA Query（11.14，印刷页 1745–1746；帧格式 9.6.10，印刷页 1210–1211）：
//!   Category = 8（表 9-47），SA Query Action 0 = Request、1 = Response（表 9-331），
//!   后跟 16 位 Transaction Identifier；响应必须带回请求里的同一个标识。
//!   支持 MFP 的 STA 都要支持 SA Query；收到 Request 应回复 Response，除非没关联到
//!   发送方、或刚发出 (Re)Association Request 还在等响应。
//!   非 AP STA 在与 AP 的关联协商了 MFP 的前提下，收到 AP 发来的、原因码为
//!   INVALID_CLASS2_FRAME / INVALID_CLASS3_FRAME 的未保护 Deauthentication /
//!   Disassociation 时，可以发起 SA Query 来确认关联是否仍然有效。
//!
//! 802.11 帧的完整编解码属于 `wifi-mlme`，组件之间不互相 import，所以这里只有
//! 一个最小的帧分类器：读帧头与帧体前两个字节，够判断「是不是稳健帧、是什么帧」。
//! 加解密与 MIC 在 `ccmp.zig`、`bip.zig`。
//! 不用分配器；不 import hw/log。

const std = @import("std");
const bip = @import("bip.zig");
const hdr = @import("hdr.zig");

pub const Error = error{Truncated};

/// 表 9-47（印刷页 736–737）的 Category 值。
pub const Category = struct {
    pub const spectrum_mgmt: u8 = 0;
    pub const qos: u8 = 1;
    pub const dls: u8 = 2;
    pub const block_ack: u8 = 3;
    pub const public: u8 = 4;
    pub const radio_measurement: u8 = 5;
    pub const fast_bss_transition: u8 = 6;
    pub const ht: u8 = 7;
    pub const sa_query: u8 = 8;
    pub const protected_dual_of_public: u8 = 9;
    pub const wnm: u8 = 10;
    pub const unprotected_wnm: u8 = 11;
    pub const tdls: u8 = 12;
    pub const mesh: u8 = 13;
    pub const multihop: u8 = 14;
    pub const self_protected: u8 = 15;
    pub const dmg: u8 = 16;
    pub const fast_session_transfer: u8 = 18;
    pub const robust_av_streaming: u8 = 19;
    pub const unprotected_dmg: u8 = 20;
    pub const vht: u8 = 21;
    pub const vendor_specific_protected: u8 = 126;
    pub const vendor_specific: u8 = 127;
};

/// 表 9-331（印刷页 1210）的 SA Query Action 字段。
pub const SaQueryAction = struct {
    pub const request: u8 = 0;
    pub const response: u8 = 1;
};

pub const sa_query_body_len = 4;
pub const transaction_id_len = 2;

/// 表 9-46（印刷页 735）里触发 SA Query 的两个原因码。
pub const reason_invalid_class2_frame: u16 = 6;
pub const reason_invalid_class3_frame: u16 = 7;

pub const Kind = enum {
    disassoc,
    deauth,
    /// Action 或 Action No Ack 帧；`category` 是 Action Details 的第一个字节。
    action,
    other,
};

pub const FrameClass = struct {
    kind: Kind,
    category: u8,
    group: bool,
    protected: bool,

    /// 12.2.8：是不是稳健管理帧。`action` 帧看表 9-47 的 Robust 列。
    pub fn robust(self: FrameClass) bool {
        return switch (self.kind) {
            .disassoc, .deauth => true,
            .action => categoryRobust(self.category) == .yes,
            .other => false,
        };
    }
};

pub const Robust = enum { yes, no, not_applicable };

/// 表 9-47 的 Robust 列。Radio Measurement 的注 1（Link Measurement Request/Report
/// 在 DMG BSS 里不稳健）不适用于非 DMG，所以按 Yes。
pub fn categoryRobust(category: u8) Robust {
    return switch (category) {
        Category.spectrum_mgmt,
        Category.qos,
        Category.dls,
        Category.block_ack,
        Category.radio_measurement,
        Category.fast_bss_transition,
        Category.sa_query,
        Category.protected_dual_of_public,
        Category.wnm,
        Category.mesh,
        Category.multihop,
        Category.dmg,
        Category.fast_session_transfer,
        Category.robust_av_streaming,
        Category.vendor_specific_protected,
        => .yes,
        Category.tdls => .not_applicable,
        else => .no,
    };
}

/// 最小分类器：帧头 + 帧体（已解封装、不含 FCS）。
pub fn classify(frame: []const u8) Error!FrameClass {
    const h = try hdr.parse(frame);
    var kind: Kind = .other;
    var category: u8 = 0;
    if (h.kind == .mgmt) {
        kind = switch (h.subtype) {
            hdr.Subtype.disassoc => .disassoc,
            hdr.Subtype.deauth => .deauth,
            hdr.Subtype.action, hdr.Subtype.action_no_ack => blk: {
                // Action 字段 = Category(1) + Action Details（9.4.1.11，印刷页 736）。
                if (frame.len < h.hdr_len + 1) break :blk .other;
                category = frame[h.hdr_len];
                break :blk .action;
            },
            else => .other,
        };
    }
    return .{
        .kind = kind,
        .category = category,
        .group = h.groupAddressed(),
        .protected = h.protected,
    };
}

/// 读 Deauthentication / Disassociation 帧体里的 Reason code（帧体头 2 个字节，
/// 表 9-28、9-37；按 9.2.2 小端）。不是这两种帧时返回 null。
pub fn reasonCode(frame: []const u8) Error!?u16 {
    const c = try classify(frame);
    if (c.kind != .disassoc and c.kind != .deauth) return null;
    const h = try hdr.parse(frame);
    if (frame.len < h.hdr_len + 2) return error.Truncated;
    return std.mem.readInt(u16, frame[h.hdr_len..][0..2], .little);
}

/// 11.14：这一帧是否可以当作「关联状态可能不一致」的线索——未保护的
/// Deauthentication / Disassociation，原因码是 INVALID_CLASS2_FRAME 或
/// INVALID_CLASS3_FRAME。调用方还要自己确认发送方是自己的 AP 且关联协商了 MFP。
pub fn isSaQueryTrigger(frame: []const u8) Error!bool {
    const c = try classify(frame);
    if (c.protected) return false;
    const reason = (try reasonCode(frame)) orelse return false;
    return reason == reason_invalid_class2_frame or reason == reason_invalid_class3_frame;
}

/// 管理帧保护的本地状态。
pub const Policy = struct {
    /// dot11RSNAProtectedManagementFramesActivated
    activated: bool,
    /// dot11RSNAUnprotectedManagementFramesAllowed
    unprotected_allowed: bool = false,
    /// 对端在它的 RSNE 里通告的 Management Frame Protection Capable（RSN Capabilities B7）。
    peer_mfpc: bool = false,
    /// 与对端的 PTK 和 IGTK 是否都已安装。
    keys_installed: bool = false,
    /// 按收到的 MME 的 Key ID 能不能找到对应的 IGTK。
    igtk_available: bool = false,
};

pub const RxAction = enum { accept, discard };

/// 帧尾是不是 BIP 的 MME。BIP 不置 Protected Frame 位，只能这样认。
fn hasMmie(frame: []const u8) bool {
    return frame.len >= hdr.base_hdr_len + bip.mmie_total and
        frame[frame.len - bip.mmie_total] == bip.mmie_element_id and
        frame[frame.len - bip.mmie_total + 1] == bip.mmie_len_field;
}

/// 12.6.19 的接收规则。`frame` 是去掉 FCS 的原始帧（受保护的还没解封装）。
///
/// 单独寻址：
///   未启用 MFP：未保护的收，受保护的丢。
///   启用、允许未保护、对端 MFPC = 0：同上。
///   启用、其余情形：未保护的稳健 Action 帧丢（密钥装好之前也是丢，12.6.19 末段）；
///   未保护的 Disassociation / Deauthentication 只在 PTK 与 IGTK 安装之前处理；
///   受保护的交上去解封装。
/// 组寻址：
///   未启用 MFP：未保护的收，受保护的「忽略其保护」也收。
///   启用：对端 MFPC = 1 或不允许未保护时，未保护的丢；带 MME 的要有可用的 IGTK。
///
/// 这里只说「收还是丢」。受保护的帧接下来还得过 CCMP/GCMP 或 BIP 的 MIC 与重放。
pub fn rxAction(p: Policy, frame: []const u8) Error!RxAction {
    const c = try classify(frame);
    if (!c.robust()) return .accept;

    if (c.group) {
        if (!p.activated) return .accept;
        if (!hasMmie(frame)) {
            if (!p.unprotected_allowed or p.peer_mfpc) return .discard;
            return .accept;
        }
        return if (p.igtk_available) .accept else .discard;
    }

    if (!p.activated) return if (c.protected) .discard else .accept;
    // 对端通告 MFPC = 0 且允许未保护帧：与它之间明文收发，它发来的受保护帧丢弃。
    if (p.unprotected_allowed and !p.peer_mfpc) return if (c.protected) .discard else .accept;
    if (c.protected) return .accept;

    switch (c.kind) {
        .action => return .discard,
        .disassoc, .deauth => return if (p.keys_installed) .discard else .accept,
        .other => return .accept,
    }
}

/// 发送方向（12.6.19）：这一帧现在明文发、保护发，还是还不能发。
///   plaintext：未保护地发。
///   protected：用 PTK（单独寻址）或 IGTK（组寻址）保护后发。
///   not_yet：稳健 Action 帧，但 PTK / IGTK 还没装好——先不发。
pub const TxAction = enum { plaintext, protected, not_yet };

pub fn txAction(p: Policy, frame: []const u8) Error!TxAction {
    const c = try classify(frame);
    if (!c.robust() or !p.activated) return .plaintext;

    if (c.group) return if (p.keys_installed) .protected else .not_yet;

    // 12.6.20：与通告 MFPC = 1 的 STA 协商；不允许未保护帧时对任何 STA 都保护。
    if (!p.peer_mfpc and p.unprotected_allowed) return .plaintext;
    if (c.kind == .action) return if (p.keys_installed) .protected else .not_yet;
    // Disassociation / Deauthentication：密钥装好之前只能明文发（对端也只在
    // 那之前处理明文的这两种帧），装好之后保护。
    return if (p.keys_installed) .protected else .plaintext;
}

// ---------------------------------------------------------------------------
// SA Query
// ---------------------------------------------------------------------------

pub const SaQuery = struct {
    is_response: bool,
    transaction_id: u16,
};

/// 解析 SA Query Request / Response 的帧体（Category | Action | Transaction Identifier）。
/// 不是 SA Query 帧返回 null；帧体太短报 `Truncated`。
pub fn parseSaQuery(body: []const u8) Error!?SaQuery {
    if (body.len < 1) return error.Truncated;
    if (body[0] != Category.sa_query) return null;
    if (body.len < sa_query_body_len) return error.Truncated;
    const action = body[1];
    if (action != SaQueryAction.request and action != SaQueryAction.response) return null;
    return .{
        .is_response = action == SaQueryAction.response,
        .transaction_id = std.mem.readInt(u16, body[2..4], .little),
    };
}

/// 拼一个 SA Query 帧体。
pub fn buildSaQuery(response: bool, transaction_id: u16, out: *[sa_query_body_len]u8) void {
    out[0] = Category.sa_query;
    out[1] = if (response) SaQueryAction.response else SaQueryAction.request;
    std.mem.writeInt(u16, out[2..4], transaction_id, .little);
}

/// 响应方（11.14）：任何支持 SA Query 的 STA。
pub const Responder = struct {
    /// 当前是否关联到发来 Request 的那个 STA。
    associated: bool = false,
    /// 是否刚发出 (Re)Association Request、还在 dot11AssociationResponseTimeOut 内等响应。
    awaiting_assoc_response: bool = false,

    /// 收到一个 Action 帧体。应当回复时返回要带回的 Transaction Identifier。
    pub fn onRequest(self: Responder, body: []const u8) Error!?u16 {
        if (!self.associated or self.awaiting_assoc_response) return null;
        const q = (try parseSaQuery(body)) orelse return null;
        if (q.is_response) return null;
        return q.transaction_id;
    }
};

/// 发起方（11.14）：与 AP 的关联协商了 MFP 的非 AP STA。
///
/// `start` 记下开始时刻并发出第一个 Request；之后每 `retry_tu` 个 TU 重发一次，
/// 直到收到标识相符的 Response，或者自开始起过了 `max_tu` 个 TU。
pub const Initiator = struct {
    active: bool = false,
    /// 未完成事务的 Transaction Identifier；未发起时无意义。
    transaction_id: u16 = 0,
    /// 当前这次事务是否已收到有效响应。
    peer_responded: bool = false,
    start_tu: u32 = 0,
    last_sent_tu: u32 = 0,
    retry_tu: u32 = 1,
    max_tu: u32 = 1,
    /// 已经发出的 Request 个数（含第一次）。
    sent: u8 = 0,

    /// 发起一次 SA Query 过程。`first_id` 是这次事务的标识（12.7.6.3 c)：实现选一个
    /// 对当前 PTKSA 有效的非负整数）。返回要放进第一个 Request 的标识。
    pub fn start(self: *Initiator, now_tu: u32, retry_tu: u32, max_tu: u32, id: u16) u16 {
        self.active = true;
        self.peer_responded = false;
        self.transaction_id = id;
        self.start_tu = now_tu;
        self.last_sent_tu = now_tu;
        self.retry_tu = @max(retry_tu, 1);
        self.max_tu = @max(max_tu, 1);
        self.sent = 1;
        return self.transaction_id;
    }

    /// 到没到重发时刻：距上次发送过了 retry_tu，且总时长还没到 max_tu。
    pub fn due(self: *const Initiator, now_tu: u32) bool {
        if (!self.active or self.peer_responded) return false;
        return now_tu - self.start_tu < self.max_tu and now_tu - self.last_sent_tu >= self.retry_tu;
    }

    /// 重发一次，沿用同一个标识。返回要放进 Request 的标识。
    pub fn resend(self: *Initiator, now_tu: u32) u16 {
        self.last_sent_tu = now_tu;
        self.sent +%= 1;
        return self.transaction_id;
    }

    /// 自开始起是否已过 max_tu。
    pub fn expired(self: *const Initiator, now_tu: u32) bool {
        return self.active and now_tu - self.start_tu >= self.max_tu;
    }

    /// 关联是否已确认有效：这次事务收到过标识相符的 Response。
    pub fn saConfirmed(self: *const Initiator) bool {
        return self.active and self.peer_responded;
    }

    /// 收到一个 Action 帧体。只有 SA Query Response 且标识与未完成事务相同才算数
    /// （9.6.10.3：Transaction Identifier 设成对应 Request 里的值）。
    pub fn onResponse(self: *Initiator, body: []const u8) bool {
        if (!self.active) return false;
        const q = (parseSaQuery(body) catch return false) orelse return false;
        if (!q.is_response or q.transaction_id != self.transaction_id) return false;
        self.peer_responded = true;
        return true;
    }

    /// 超时后放弃：之后 `saConfirmed` 为 false，SME 可以删除 SA 与临时密钥（11.14）。
    pub fn giveUp(self: *Initiator) void {
        self.active = false;
        self.peer_responded = false;
    }
};
