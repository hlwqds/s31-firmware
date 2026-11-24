//! wifi-connect：EAP 包格式与 peer 侧规则（RFC 3748）。
//!
//! 边界：
//!   * EAP 包头 Code / Identifier / Length / Type（RFC 3748 §4、§4.1），Success / Failure（§4.2）。
//!   * EAPOL-EAP 帧的封装与解析：EAPOL 帧头四个八位组，见下面「EAPOL 帧头」。
//!   * peer 的规则：Request → Response 与重复的 Request（§4.1），Success / Failure 何时可信（§4.2），
//!     Identity（§5.1）、Notification（§5.2）、Legacy Nak（§5.3.1）、Expanded Types 与 Expanded Nak
//!     （§5.7、§5.3.2），以及「一场会话只许一种认证方法」（§2.1）。
//!   * 认证方法只接了 EAP-TLS（RFC 5216，`eap_tls.zig`）；TLS 引擎经 `eap_tls.Engine` 注入，
//!     本组件不实现 TLS。EAPOL-Key 在 `wpa2.zig`，这里不碰。
//!   * 不 import board / log，不分配堆内存。
//!
//! 拒绝与「silently discard」：RFC 对无效包的要求多半是不理（§4 的 Code / Length、§4.2 的 Success、
//! §2.1 的换方法）。这里把每一种都报成一个具体的错误，方便调用方记日志；共同点是**不回任何东西**，
//! 线上行为与 RFC 一致。两种情况例外，回的是空响应而不是沉默：本端 TLS 判失败之后、我方分片没发完
//! 又收到对端数据（都见 `eap_tls.zig`），因为 RFC 5216 2.1.3 要对方收到响应才发 EAP-Failure。
//!
//! EAPOL 帧头：802.11-2016 自己不定义它。4.10.2 说「IEEE 802.1X EAPOL PDUs are transmitted in one
//! or more IEEE 802.11 Data frames and passed via the IEEE 802.1X Uncontrolled Port」；12.7.2 的图 12-32
//! 画出帧头的三个字段（Protocol Version 1 八位组、Packet Type 1 八位组、Packet Body Length
//! 2 八位组），比特与八位组约定指向 IEEE Std 802.1X-2010 的 11.2——那份原文不在盘上。字段含义按
//! 盘上的两处：
//!   * RFC 3580 §4（16 页）：Version「The Version field is one octet. For IEEE 802.1X, it contains
//!     the value 0x01.」；Packet Body Length「contains the length of the EAPOL-Key descriptor in
//!     octets, not including the Version, Packet Type and Packet Body Length fields.」
//!   * wpa_supplicant `src/common/eapol_common.h`：`#define EAPOL_VERSION 2`（IEEE Std 802.1X-2004）、
//!     `IEEE802_1X_TYPE_EAP_PACKET = 0`。本组件的 EAPOL-Key 帧也用版本 2（`wpa2.zig`）。
//! 所以本文件发版本 2，收版本 1 或 2。

const std = @import("std");

const eap_tls = @import("eap_tls.zig");

// ---------------------------------------------------------------------------
// 常数与错误
// ---------------------------------------------------------------------------

pub const eap_header_len = 4;
pub const eapol_header_len = 4;
pub const eapol_protocol_version: u8 = 2;
/// EAPOL Packet Type：EAP-Packet。
pub const eapol_type_eap_packet: u8 = 0;

/// EAP Type（RFC 3748 §5 的表）。
pub const type_identity: u8 = 1;
pub const type_notification: u8 = 2;
pub const type_nak: u8 = 3;
pub const type_expanded: u8 = 254;

/// Identity Response 最多 1020 八位组（RFC 3748 5.1：「SHOULD NOT assume that an Identity Request
/// or Response can be larger than 1020 octets」），去掉 EAP 头与 Type 就是 1015。
pub const identity_max = 1015;
pub const identity_response_max = 1020;

/// Expanded 形式的 EAP-TLS：254 | Vendor-Id 0 (IETF) | Vendor-Type 13（RFC 3748 5.7 的图）。
const expanded_eap_tls: [8]u8 = .{ 254, 0, 0, 0, 0, 0, 0, eap_tls.eap_type };
/// Expanded Nak 的头：254 | Vendor-Id 0 (IETF) | Vendor-Type 3 (Nak)（RFC 3748 5.3.2）。
const expanded_nak_head: [8]u8 = .{ 254, 0, 0, 0, 0, 0, 0, type_nak };

pub const Error = eap_tls.Error || error{
    EapolTooShort,
    /// EAPOL Protocol Version 不是 1 也不是 2。
    EapolVersion,
    /// EAPOL Packet Type 不是 EAP-Packet。
    EapolType,
    /// EAPOL Packet Body Length 超过帧里实际有的八位组。
    EapolLength,
    EapTooShort,
    /// EAP Length 小于 4，或大于收到的八位组数（§4：MUST be silently discarded）。
    EapLength,
    /// EAP Code 不在 1–4（§4：MUST be silently discarded）。
    EapCode,
    /// Request 里没有 Type 字段，或 Type 是 0。
    NoType,
    /// peer 收到 Response：peer 不处理它。
    EapResponse,
    /// Nak（Legacy 或 Expanded）出现在 Request 里（§5：MUST NOT be sent in a Request）。
    NakInRequest,
    /// Expanded Type 不足 8 八位组的 Vendor-Id + Vendor-Type。
    BadExpanded,
    /// 会话已经以 Success / Failure 结束，之后的帧一律不理。
    Finished,
    /// Success / Failure 的 Length 不是 4（§4.2：MUST NOT contain additional data）。
    ResultLength,
    /// Success / Failure 的 Identifier 不是我方上一个 Response 的（§4.2）。
    ResultIdentifier,
    /// 我方没有 outstanding 的 Response，这个 Success / Failure 无从对应（§4.2）。
    ResultNotAllowed,
    /// 发 Success 的时机不被允许：握手没完成或本端已判失败（§4.2、RFC 5216 2.1.3）。
    SuccessNotAllowed,
    /// 方法开始之后又来一个别的 Type 的 Request（§2.1：MUST treat them as invalid, and silently discard）。
    UnexpectedRequest,
    /// Notification Request 的消息是 0 八位组（§5.2：「greater than zero octets in length」）。
    NotificationEmpty,
    /// 配置的 Identity 太长，或以 NUL 结尾（§5.1：「The Identity Response field MUST NOT be null terminated」）。
    IdentityInvalid,
};

// ---------------------------------------------------------------------------
// EAP 包头
// ---------------------------------------------------------------------------

pub const Code = enum(u8) {
    request = 1,
    response = 2,
    success = 3,
    failure = 4,
};

pub const Header = struct {
    code: Code,
    id: u8,
    /// Length 字段：整个 EAP 包的长度，含 4 八位组的头。
    length: u16,
    /// Length 范围内的八位组（Code / Identifier / Length 之后）。
    data: []const u8,
};

/// 解 EAP 包头（RFC 3748 §4 的图）。Length 之外的八位组是链路层填充，忽略；
/// Length 大于收到的八位组数则丢弃。
pub fn parse(pkt: []const u8) Error!Header {
    if (pkt.len < eap_header_len) return error.EapTooShort;
    const code = std.enums.fromInt(Code, pkt[0]) orelse return error.EapCode;
    const length: u16 = std.mem.readInt(u16, pkt[2..4], .big);
    if (length < eap_header_len) return error.EapLength;
    if (length > pkt.len) return error.EapLength;
    return .{ .code = code, .id = pkt[1], .length = length, .data = pkt[eap_header_len..length] };
}

// ---------------------------------------------------------------------------
// EAPOL-EAP 帧
// ---------------------------------------------------------------------------

/// 拆 EAPOL 头，返回包体（Packet Body），也就是里面的 EAP 包。
/// 包体长度之外的八位组忽略。
pub fn eapolBody(frame: []const u8) Error![]const u8 {
    if (frame.len < eapol_header_len) return error.EapolTooShort;
    if (frame[0] != 1 and frame[0] != eapol_protocol_version) return error.EapolVersion;
    if (frame[1] != eapol_type_eap_packet) return error.EapolType;
    const body_len: usize = std.mem.readInt(u16, frame[2..4], .big);
    if (body_len > frame.len - eapol_header_len) return error.EapolLength;
    return frame[eapol_header_len..][0..body_len];
}

/// 把一个 EAP 包封进 EAPOL-EAP 帧：Version=2、Packet Type=EAP-Packet、Packet Body Length=包长。
pub fn eapolWrap(out: []u8, pkt: []const u8) Error!usize {
    if (pkt.len > std.math.maxInt(u16)) return error.EapolLength;
    const total = eapol_header_len + pkt.len;
    if (out.len < total) return error.NoBufferSpace;
    out[0] = eapol_protocol_version;
    out[1] = eapol_type_eap_packet;
    std.mem.writeInt(u16, out[2..4], @intCast(pkt.len), .big);
    @memcpy(out[eapol_header_len..total], pkt);
    return total;
}

// ---------------------------------------------------------------------------
// Request 的 Type
// ---------------------------------------------------------------------------

const Kind = enum {
    bad,
    identity,
    notification,
    nak,
    tls,
    /// Type 4–253 或 255：本端不支持的认证方法，回 Legacy Nak。
    legacy_other,
    /// Expanded Type，但不是 IETF 的 EAP-TLS：回 Expanded Nak。
    expanded_other,
};

const Request = struct {
    kind: Kind,
    /// Type 之后的八位组（Type-Data）。
    data: []const u8,
    /// 请求用的是 Expanded Type（254）形式。
    expanded: bool,

    /// Response 的 Type 字段沿用请求的形式：Legacy 请求回单八位组 Type，Expanded 请求回 Expanded
    /// （§4.1：「The Type field of a Response MUST ... match that of the Request」；5.7 说 Vendor-Id
    /// 为 0 时两种形式语义相同，照抄请求的形式两种读法都满足）。
    fn writeType(self: Request, buf: *[8]u8) []const u8 {
        if (!self.expanded) {
            buf[0] = eap_tls.eap_type;
            return buf[0..1];
        }
        buf.* = expanded_eap_tls;
        return buf[0..8];
    }
};

fn parseRequest(data: []const u8) Error!Request {
    var rest: []const u8 = data[1..];
    var vendor: u32 = 0;
    var method: u32 = data[0];
    const expanded = data[0] == type_expanded;
    if (expanded) {
        // Vendor-Data 可以是 0 八位组（Expanded Nak 之外没有数据时），所以下限是这 8 个。
        if (data.len < 8) return error.BadExpanded;
        vendor = std.mem.readInt(u24, data[1..4], .big);
        method = std.mem.readInt(u32, data[4..8], .big);
        rest = data[8..];
    }
    const kind: Kind = if (vendor != 0) .expanded_other else switch (method) {
        0 => .bad, // 0 只用在 Nak Response 里表示没有可接受的替代（5.7）
        type_identity => .identity,
        type_notification => .notification,
        type_nak => .nak,
        eap_tls.eap_type => .tls,
        else => if (expanded) .expanded_other else .legacy_other,
    };
    return .{ .kind = kind, .data = rest, .expanded = expanded };
}

// ---------------------------------------------------------------------------
// Peer
// ---------------------------------------------------------------------------

pub const State = enum {
    /// 还没有对任何认证方法回过 Response。
    idle,
    /// 已经对 EAP-TLS 的 Request 回过 EAP-TLS 的 Response：从这一刻起不能再换方法（§2.1、§4.1）。
    method,
    success,
    failure,
};

/// 给调用方看的总状态：`state` 加上 TLS 层自己判的失败。
pub const Status = enum { idle, in_progress, succeeded, failed };

pub const Config = struct {
    tls: eap_tls.Config = .{},
};

pub fn PeerSized(comptime cfg: Config) type {
    // EAPOL 头 4 + EAP 头 4 + Type 1 + Flags 1 + TLS Message Length 4 + 数据；Expanded Type 多 7 八位组。
    const tls_response_max = eapol_header_len + 14 + 7 + cfg.tls.fragment;
    const resp_max = @max(tls_response_max, eapol_header_len + identity_response_max);
    return struct {
        const Self = @This();
        pub const config: Config = cfg;
        /// 一帧响应的最大长度（含 EAPOL 头）。
        pub const response_max: usize = resp_max;

        identity: []const u8,
        tls: eap_tls.MethodSized(cfg.tls),
        st: State = .idle,
        /// 最近一个 Request 的 Identifier。
        have_prev_req: bool = false,
        prev_req_id: u8 = 0,
        /// 我方对最近一个 Request 的 Response（EAP 包，不含 EAPOL 头）；`prev_resp_len == 0` 表示没回。
        prev_resp: [resp_max]u8 = undefined,
        prev_resp_len: usize = 0,

        pub fn init(identity: []const u8, engine: eap_tls.Engine) Self {
            return .{ .identity = identity, .tls = eap_tls.MethodSized(cfg.tls).init(engine) };
        }

        pub fn state(self: *const Self) State {
            return self.st;
        }

        pub fn status(self: *const Self) Status {
            return switch (self.st) {
                .success => .succeeded,
                .failure => .failed,
                .idle => .idle,
                .method => if (self.tls.failure != null) .failed else .in_progress,
            };
        }

        /// MSK（RFC 5216 2.3：MSK = Key_Material(0,63)），取自引擎。
        pub fn msk(self: *const Self) [eap_tls.msk_len]u8 {
            return self.tls.msk();
        }

        /// PMK：MSK 的前 32 八位组（`eap_tls.pmkFromMsk`）。成功之后才有意义。
        pub fn pmk(self: *const Self) [eap_tls.pmk_len]u8 {
            return eap_tls.pmkFromMsk(self.tls.msk());
        }

        /// 输入一帧 EAPOL-EAP，把要回的 EAPOL-EAP 帧写进 `out`，返回帧长；0 = 不回。
        pub fn onFrame(self: *Self, frame: []const u8, out: []u8) Error!usize {
            return self.onPacket(try eapolBody(frame), out);
        }

        /// 同上，输入的是 EAPOL 包体里的 EAP 包。
        pub fn onPacket(self: *Self, pkt: []const u8, out: []u8) Error!usize {
            const p = try parse(pkt);
            switch (p.code) {
                .response => return error.EapResponse,
                .success => {
                    try self.acceptResult(p, true);
                    return 0;
                },
                .failure => {
                    try self.acceptResult(p, false);
                    return 0;
                },
                .request => {},
            }
            if (self.st == .success or self.st == .failure) return error.Finished;

            // 重复的 Request（重传时 Identifier 不变，§4.1）：原样重发上次的 Response，不重新处理——
            // 否则同一串 TLS 记录会再喂给引擎一次。没回过的（被丢弃，或 `out` 当时放不下）照常处理：
            // 丢弃的规则是确定的，结果一样；放不下的这次也许就放得下了。
            if (self.have_prev_req and p.id == self.prev_req_id and self.prev_resp_len != 0) {
                return eapolWrap(out, self.prev_resp[0..self.prev_resp_len]);
            }
            self.have_prev_req = true;
            self.prev_req_id = p.id;
            self.prev_resp_len = 0;
            return self.onRequest(p.id, p.data, out);
        }

        /// Success / Failure 只在发得出的时候才理（§4.2）。
        fn acceptResult(self: *Self, p: Header, success: bool) Error!void {
            if (p.length != eap_header_len) return error.ResultLength;
            // 一上来就发的（canned）或会话已结束的：§4.2「MUST silently discard it」。
            if (self.st != .method) return error.ResultNotAllowed;
            // Identifier 必须是它所应答的那个 Response 的（§4.2）。
            if (!(self.have_prev_req and p.id == self.prev_req_id and self.prev_resp_len != 0)) {
                return error.ResultIdentifier;
            }
            if (success) {
                // 对端想用一个提前的 Success 绕过互相认证（§4.2）；EAP-TLS 只在握手完成之后
                // 允许 Success（RFC 5216 2.1.3）。本端已判失败时同样不理。
                if (!self.tls.handshakeDone()) return error.SuccessNotAllowed;
                self.st = .success;
            } else {
                self.st = .failure;
            }
        }

        fn onRequest(self: *Self, id: u8, data: []const u8, out: []u8) Error!usize {
            if (data.len == 0) return error.NoType;
            const req = try parseRequest(data);
            const b = &self.prev_resp;
            var type_buf: [8]u8 = undefined;

            switch (req.kind) {
                .tls => {
                    b[0] = @backingInt(Code.response);
                    b[1] = id;
                    const type_len = req.writeType(&type_buf).len;
                    @memcpy(b[4..][0..type_len], type_buf[0..type_len]);
                    // Type-Data 直接写进响应缓冲：Flags、TLS Message Length 和数据都归 `eap_tls`。
                    const td = try self.tls.onRequest(req.data, b[4 + type_len ..]);
                    const eap_len = eap_header_len + type_len + td;
                    if (eap_len > std.math.maxInt(u16)) return error.NoBufferSpace;
                    std.mem.writeInt(u16, b[2..4], @intCast(eap_len), .big);
                    // 回出 EAP-TLS 的 Response 之后，这场会话的方法就定了（§2.1）。
                    self.st = .method;
                    return self.finish(out, eap_len);
                },
                .identity => {
                    if (self.st == .method) return error.UnexpectedRequest; // Identity Requery（§2.1）
                    if (self.identity.len > identity_max or
                        (self.identity.len > 0 and self.identity[self.identity.len - 1] == 0))
                    {
                        return error.IdentityInvalid;
                    }
                    return self.respond(out, id, &[_]u8{type_identity}, self.identity);
                },
                .notification => {
                    if (req.data.len == 0) return error.NotificationEmpty;
                    // Response 的 Type-Data 是 0 八位组（§5.2）；不改 peer 的状态。
                    return self.respond(out, id, &[_]u8{type_notification}, "");
                },
                .legacy_other => {
                    if (self.st == .method) return error.UnexpectedRequest; // 不能再发 Nak（§4.1）
                    // Legacy Nak：Type-Data 是期望的认证 Type，一个八位组一个（§5.3.1）。
                    return self.respond(out, id, &[_]u8{type_nak}, &[_]u8{eap_tls.eap_type});
                },
                .expanded_other => {
                    if (self.st == .method) return error.UnexpectedRequest;
                    // Expanded Nak 只回给 Expanded Type 的请求，期望的类型也都写成 Expanded（§5.3.2）。
                    return self.respond(out, id, &expanded_nak_head, &expanded_eap_tls);
                },
                .bad => return error.NoType,
                .nak => return error.NakInRequest,
            }
        }

        /// 拼一个 Response：Code=2、Identifier=`id`、Length、Type、Type-Data，再封进 EAPOL。
        fn respond(self: *Self, out: []u8, id: u8, type_bytes: []const u8, type_data: []const u8) Error!usize {
            const b = &self.prev_resp;
            const eap_len = eap_header_len + type_bytes.len + type_data.len;
            if (eap_len > std.math.maxInt(u16) or eap_len > b.len) return error.NoBufferSpace;
            b[0] = @backingInt(Code.response);
            b[1] = id;
            std.mem.writeInt(u16, b[2..4], @intCast(eap_len), .big);
            @memcpy(b[eap_header_len..][0..type_bytes.len], type_bytes);
            @memcpy(b[eap_header_len + type_bytes.len ..][0..type_data.len], type_data);
            return self.finish(out, eap_len);
        }

        /// Response 已经在 `prev_resp` 里拼好：先记下来，再往 `out` 里封。`out` 放不下时报错，
        /// 但对端重传同一个 Request 时这一帧照样能重发。
        fn finish(self: *Self, out: []u8, eap_len: usize) Error!usize {
            self.prev_resp_len = eap_len;
            return eapolWrap(out, self.prev_resp[0..eap_len]);
        }
    };
}

pub const Peer = PeerSized(.{});
