//! ble-802154：LE 上的 L2CAP（Bluetooth Core 5.4 [Vol 3] Part A）。
//!
//! 规范出处（条款号与原文一致）：
//!   * CID 名字空间（LE-U）：表 2.3 —— 0x0004 ATT、0x0005 LE 信令、0x0006 SMP，
//!     0x0040–0x007F 动态分配（§2.2 表 2.4 之前的一段写了这个范围）；
//!   * B-frame = PDU Length(2) + Channel ID(2) + 载荷 —— §3.1；
//!   * K-frame = 基本头 + [SDU Length(2)，只在 SDU 的第一帧] + 载荷 —— §3.4、
//!     §3.4.1、§3.4.2、§3.4.3；
//!   * 信令命令 = Code(1) + Identifier(1) + Data Length(2) + Data —— §4；
//!     Identifier 0x00 无效（§4 “Signaling identifier 0x00 is an invalid
//!     identifier”）；LE-U 的信令信道上一个 C-frame 只放一条命令（§4 的无效
//!     行为清单）；
//!   * Connection Parameter Update Request / Response —— §4.20 / §4.21（字段取自
//!     图 4.16、表 4.14）；
//!   * LE Credit Based Connection Request / Response、Flow Control Credit Ind ——
//!     §4.22 / §4.23 / §4.24（字段取自图 4.18–4.20，Result 取值取自表 4.16）；
//!   * Command Reject —— §4.1（Reason 取值取自表 4.3）；
//!   * LE Credit Based Flow Control mode 的规则 —— §10.1：有额度才能发 K-frame，
//!     每发一个减一；收到 Flow Control Credit Ind 就加上去。
//!
//! 图里的字段布局是图片，本次是从官方 HTML 的图逐格读出来的（见 README）。
//!
//! 没有分配、没有全局状态：通道对象的接收缓冲大小在编译期定。

const std = @import("std");

pub const Error = error{
    Short,
    Trailing,
    NoSpace,
    /// 声明长度与实际不符、字段不是规定宽度。
    BadLength,
    BadParam,
    /// 信令 Identifier 是 0x00。
    InvalidIdentifier,
    /// 不认识或该信道上不允许的信令 Code。
    UnknownCode,
    Busy,
    /// 本端没有可发的 K-frame 额度（§10.1）。
    NoCredits,
    /// 收到帧时对端的额度已经是 0（§10.1：无额度不得发）。
    CreditExceeded,
    /// 16 位额度字段装不下。
    CreditOverflow,
    /// SDU 长度超过本端 MTU：规范要求断开信道（§3.4.3）。
    SduTooLong,
    /// K-frame 载荷超过本端 MPS：规范要求断开信道（§3.4.3）。
    MpsExceeded,
    /// 各帧载荷之和超过 SDU Length：规范要求断开信道（§3.4.3）。
    SduOverrun,
};

// ---------------------------------------------------------------------------
// 通道标识符（表 2.3）与基本头
// ---------------------------------------------------------------------------

pub const cid_null: u16 = 0x0000;
pub const cid_att: u16 = 0x0004;
pub const cid_le_signaling: u16 = 0x0005;
pub const cid_smp: u16 = 0x0006;
pub const cid_dynamic_lo: u16 = 0x0040;
pub const cid_dynamic_hi: u16 = 0x007F;

/// PDU Length + Channel ID。B-frame 与 K-frame 共用。§3.1、§3.4.1。
pub const header_len: usize = 4;

pub const Header = struct {
    length: u16,
    cid: u16,

    pub fn encode(self: Header, out: *[header_len]u8) void {
        std.mem.writeInt(u16, out[0..2], self.length, .little);
        std.mem.writeInt(u16, out[2..4], self.cid, .little);
    }

    pub fn decode(bytes: *const [header_len]u8) Header {
        return .{
            .length = std.mem.readInt(u16, bytes[0..2], .little),
            .cid = std.mem.readInt(u16, bytes[2..4], .little),
        };
    }
};

pub const Frame = struct { cid: u16, payload: []const u8 };

/// 封一个 B-frame。§3.1。输出缓冲不够 → `NoSpace`，不写半个字节。
pub fn encodeBFrame(out: []u8, cid: u16, payload: []const u8) Error!usize {
    if (payload.len > 65535 or out.len < header_len + payload.len) return error.NoSpace;
    (Header{ .length = @intCast(payload.len), .cid = cid }).encode(out[0..header_len]);
    @memcpy(out[header_len..][0..payload.len], payload);
    return header_len + payload.len;
}

/// 解一个基本头 + 载荷：`pdu.len` 必须正好等于 4 + PDU Length。
pub fn decodeBFrame(pdu: []const u8) Error!Frame {
    if (pdu.len < header_len) return error.Short;
    const h = Header.decode(pdu[0..header_len]);
    const total = header_len + @as(usize, h.length);
    if (pdu.len < total) return error.Short;
    if (pdu.len > total) return error.Trailing;
    return .{ .cid = h.cid, .payload = pdu[header_len..] };
}

// ---------------------------------------------------------------------------
// 信令（§4）
// ---------------------------------------------------------------------------

/// LE 信令信道上与本组件相关的 Code。表 4.2。
pub const SigCode = enum(u8) {
    command_reject = 0x01,
    conn_param_update_req = 0x12,
    conn_param_update_rsp = 0x13,
    le_credit_conn_req = 0x14,
    le_credit_conn_rsp = 0x15,
    le_credit_ind = 0x16,
    _,
};

pub const sig_header_len: usize = 4;

/// Connection Parameter Update Request 的 4 个字段（各 2 字节）。图 4.16。
pub const ConnParamUpdate = struct { interval_min: u16, interval_max: u16, latency: u16, timeout: u16 };

/// Connection Parameter Update Response 的 Result。表 4.14。
pub const param_update_accepted: u16 = 0x0000;
pub const param_update_rejected: u16 = 0x0001;

/// LE Credit Based Connection Request 的 5 个字段（各 2 字节）。图 4.18。
pub const CreditConnReq = struct {
    spsm: u16,
    scid: u16,
    mtu: u16,
    mps: u16,
    initial_credits: u16,
};

/// LE Credit Based Connection Response 的 5 个字段（各 2 字节）。图 4.19。
pub const CreditConnRsp = struct {
    dcid: u16,
    mtu: u16,
    mps: u16,
    initial_credits: u16,
    result: u16,
};

/// LE_CREDIT_BASED_CONNECTION_RSP 的 Result。表 4.16。
pub const credit_result = struct {
    pub const success: u16 = 0x0000;
    pub const spsm_not_supported: u16 = 0x0002;
    pub const no_resources: u16 = 0x0004;
    pub const insufficient_authentication: u16 = 0x0005;
    pub const insufficient_authorization: u16 = 0x0006;
    pub const encryption_key_size_too_short: u16 = 0x0007;
    pub const insufficient_encryption: u16 = 0x0008;
    pub const invalid_source_cid: u16 = 0x0009;
    pub const source_cid_already_allocated: u16 = 0x000A;
    pub const unacceptable_parameters: u16 = 0x000B;
};

/// Flow Control Credit Ind：CID + Credits。图 4.20。
pub const CreditInd = struct { cid: u16, credits: u16 };

/// Command Reject 的 Reason。表 4.3。
pub const reject = struct {
    pub const command_not_understood: u16 = 0x0000;
    pub const signaling_mtu_exceeded: u16 = 0x0001;
    pub const invalid_cid: u16 = 0x0002;
};

/// 一条信令命令。
pub const Sig = union(enum) {
    conn_param_update_req: ConnParamUpdate,
    /// Connection Parameter Update Response 的 Result。
    conn_param_update_rsp: u16,
    le_credit_conn_req: CreditConnReq,
    le_credit_conn_rsp: CreditConnRsp,
    le_credit_ind: CreditInd,
    /// Command Reject 的 Reason（只支持不带 Reason Data 的 0x0000）。
    command_reject: u16,

    pub fn code(self: Sig) SigCode {
        return switch (self) {
            .conn_param_update_req => .conn_param_update_req,
            .conn_param_update_rsp => .conn_param_update_rsp,
            .le_credit_conn_req => .le_credit_conn_req,
            .le_credit_conn_rsp => .le_credit_conn_rsp,
            .le_credit_ind => .le_credit_ind,
            .command_reject => .command_reject,
        };
    }
};

pub const SigMsg = struct { identifier: u8, sig: Sig };

fn putU16s(out: []u8, vals: []const u16) void {
    for (vals, 0..) |v, i| std.mem.writeInt(u16, out[2 * i ..][0..2], v, .little);
}

/// 封一条 LE 信令 C-frame（CID 0x0005）。Identifier 为 0 → `InvalidIdentifier`。
/// §4：Data Length 只算 Data，不算 Code/Identifier/Data Length。
pub fn encodeSig(out: []u8, identifier: u8, sig: Sig) Error!usize {
    if (identifier == 0x00) return error.InvalidIdentifier;
    var data: [10]u8 = undefined;
    const n: usize = switch (sig) {
        .conn_param_update_req => |r| blk: {
            putU16s(&data, &.{ r.interval_min, r.interval_max, r.latency, r.timeout });
            break :blk 8;
        },
        .conn_param_update_rsp => |r| blk: {
            putU16s(&data, &.{r});
            break :blk 2;
        },
        .le_credit_conn_req => |r| blk: {
            putU16s(&data, &.{ r.spsm, r.scid, r.mtu, r.mps, r.initial_credits });
            break :blk 10;
        },
        .le_credit_conn_rsp => |r| blk: {
            putU16s(&data, &.{ r.dcid, r.mtu, r.mps, r.initial_credits, r.result });
            break :blk 10;
        },
        .le_credit_ind => |c| blk: {
            putU16s(&data, &.{ c.cid, c.credits });
            break :blk 4;
        },
        .command_reject => |reason| blk: {
            putU16s(&data, &.{reason});
            break :blk 2;
        },
    };
    const body_len = sig_header_len + n;
    if (out.len < header_len + body_len) return error.NoSpace;
    (Header{ .length = @intCast(body_len), .cid = cid_le_signaling }).encode(out[0..header_len]);
    out[header_len] = @backingInt(sig.code());
    out[header_len + 1] = identifier;
    std.mem.writeInt(u16, out[header_len + 2 ..][0..2], @intCast(n), .little);
    @memcpy(out[header_len + sig_header_len ..][0..n], data[0..n]);
    return header_len + body_len;
}

/// 解一条 LE 信令 C-frame：CID 必须是 0x0005，且只含一条命令。
pub fn decodeSig(pdu: []const u8) Error!SigMsg {
    const f = try decodeBFrame(pdu);
    if (f.cid != cid_le_signaling) return error.BadParam;
    if (f.payload.len < sig_header_len) return error.Short;
    const id = f.payload[1];
    if (id == 0x00) return error.InvalidIdentifier;
    const dlen: usize = std.mem.readInt(u16, f.payload[2..4], .little);
    if (f.payload.len != sig_header_len + dlen) return error.BadLength;
    const d = f.payload[sig_header_len..];
    const u16at = struct {
        fn at(b: []const u8, i: usize) u16 {
            return std.mem.readInt(u16, b[2 * i ..][0..2], .little);
        }
    }.at;
    const sig: Sig = switch (f.payload[0]) {
        @backingInt(SigCode.conn_param_update_req) => blk: {
            if (dlen != 8) return error.BadLength;
            break :blk .{ .conn_param_update_req = .{
                .interval_min = u16at(d, 0),
                .interval_max = u16at(d, 1),
                .latency = u16at(d, 2),
                .timeout = u16at(d, 3),
            } };
        },
        @backingInt(SigCode.conn_param_update_rsp) => blk: {
            if (dlen != 2) return error.BadLength;
            break :blk .{ .conn_param_update_rsp = u16at(d, 0) };
        },
        @backingInt(SigCode.le_credit_conn_req) => blk: {
            if (dlen != 10) return error.BadLength;
            break :blk .{ .le_credit_conn_req = .{
                .spsm = u16at(d, 0),
                .scid = u16at(d, 1),
                .mtu = u16at(d, 2),
                .mps = u16at(d, 3),
                .initial_credits = u16at(d, 4),
            } };
        },
        @backingInt(SigCode.le_credit_conn_rsp) => blk: {
            if (dlen != 10) return error.BadLength;
            break :blk .{ .le_credit_conn_rsp = .{
                .dcid = u16at(d, 0),
                .mtu = u16at(d, 1),
                .mps = u16at(d, 2),
                .initial_credits = u16at(d, 3),
                .result = u16at(d, 4),
            } };
        },
        @backingInt(SigCode.le_credit_ind) => blk: {
            if (dlen != 4) return error.BadLength;
            break :blk .{ .le_credit_ind = .{ .cid = u16at(d, 0), .credits = u16at(d, 1) } };
        },
        @backingInt(SigCode.command_reject) => blk: {
            // 表 4.4：0x0000 → 0 字节 Reason Data；另两种本组件不用。
            if (dlen != 2) return error.BadLength;
            break :blk .{ .command_reject = u16at(d, 0) };
        },
        else => return error.UnknownCode,
    };
    return .{ .identifier = id, .sig = sig };
}

// ---------------------------------------------------------------------------
// 连接参数更新（§4.20、§4.21）：两个角色
// ---------------------------------------------------------------------------

pub const Role = enum { central, peripheral };

/// 收到 Connection Parameter Update Request 后的回复。
///
/// §4.20：“This command shall only be sent from the Peripheral to the Central”；
/// “If a Peripheral's Host receives an L2CAP_CONNECTION_PARAMETER_UPDATE_REQ
/// packet it shall respond with an L2CAP_COMMAND_REJECT_RSP packet with reason
/// 0x0000”。所以：
///   * Central：按 `accept` 回 Response（接受的参数交给 HCI_LE_Connection_Update，
///     那一步在调用方）；
///   * Peripheral：回 Command Reject（Command not understood），`accept` 被忽略。
pub fn connParamUpdateOnReq(out: []u8, role: Role, identifier: u8, accept: bool) Error!usize {
    return switch (role) {
        .central => encodeSig(out, identifier, .{
            .conn_param_update_rsp = if (accept) param_update_accepted else param_update_rejected,
        }),
        .peripheral => encodeSig(out, identifier, .{ .command_reject = reject.command_not_understood }),
    };
}

/// 收到 Connection Parameter Update Response：只有 Peripheral 会收到。返回
/// Result（0x0000 接受、0x0001 拒绝）。Central 收到它是违规（§4.21：Response
/// “shall only be sent from the Central to the Peripheral”）。
pub fn connParamUpdateOnRsp(role: Role, msg: SigMsg) Error!u16 {
    if (role != .peripheral) return error.BadParam;
    return switch (msg.sig) {
        .conn_param_update_rsp => |r| r,
        else => error.BadParam,
    };
}

// ---------------------------------------------------------------------------
// LE Credit Based Flow Control mode（§3.4、§10.1）
// ---------------------------------------------------------------------------

/// LE Credit Based Flow Control mode 的一个通道。
///
/// 两个方向的参数分开存：`rx_*` 是本端能收的上限（本端在 Request/Response 里
/// 告诉对端的），`tx_*` 是对端能收的上限。MTU 是 SDU 上限、MPS 是单个 K-frame
/// 载荷上限（§4.22）。`sdu_max` 是本端接收缓冲的大小，必须不小于 `rx_mtu`。
pub fn Channel(comptime sdu_max: usize) type {
    return struct {
        const Self = @This();

        /// 实现必须支持的最小 MTU 与 MPS。§4.22、§4.23。
        pub const minimum_mtu: u16 = 23;
        pub const minimum_mps: u16 = 23;

        /// 本端 CID（对端发给我们时用的）。
        local_cid: u16,
        /// 对端 CID（我们发给对端时用的）。
        remote_cid: u16,
        rx_mtu: u16,
        rx_mps: u16,
        tx_mtu: u16,
        tx_mps: u16,
        /// 对端给我们的、还能发几个 K-frame。§10.1。
        tx_credits: u16,
        /// 我们给对端的、对端还能发几个 K-frame。
        rx_credits: u16,
        tx_sdu: []const u8 = &.{},
        tx_pos: usize = 0,
        tx_first: bool = true,
        tx_active: bool = false,
        rx_buf: [sdu_max]u8 = undefined,
        rx_len: usize = 0,
        /// 正在接收的 SDU 总长；0 表示空闲。
        rx_total: usize = 0,

        pub fn init(
            local_cid: u16,
            remote_cid: u16,
            rx_mtu: u16,
            rx_mps: u16,
            tx_mtu: u16,
            tx_mps: u16,
            tx_credits: u16,
            rx_credits: u16,
        ) Error!Self {
            if (local_cid < cid_dynamic_lo or local_cid > cid_dynamic_hi) return error.BadParam;
            if (remote_cid < cid_dynamic_lo or remote_cid > cid_dynamic_hi) return error.BadParam;
            if (rx_mtu < minimum_mtu or rx_mps < minimum_mps) return error.BadParam;
            if (tx_mtu < minimum_mtu or tx_mps < minimum_mps) return error.BadParam;
            if (rx_mtu > sdu_max) return error.NoSpace;
            return .{
                .local_cid = local_cid,
                .remote_cid = remote_cid,
                .rx_mtu = rx_mtu,
                .rx_mps = rx_mps,
                .tx_mtu = tx_mtu,
                .tx_mps = tx_mps,
                .tx_credits = tx_credits,
                .rx_credits = rx_credits,
            };
        }

        /// 有一个 SDU 正在发。
        pub fn sending(self: *const Self) bool {
            return self.tx_active;
        }

        /// 开始发一个 SDU。超过对端 MTU → `SduTooLong`；上一个还没发完 → `Busy`。
        /// `sdu` 必须在发完之前一直有效。
        pub fn startSend(self: *Self, sdu: []const u8) Error!void {
            if (sdu.len > self.tx_mtu) return error.SduTooLong;
            if (self.sending()) return error.Busy;
            self.tx_sdu = sdu;
            self.tx_pos = 0;
            self.tx_first = true;
            self.tx_active = true;
        }

        /// 当前 SDU 的 K-frame 是否已全部写出。
        pub fn sendDone(self: *const Self) bool {
            return !self.tx_active;
        }

        /// 当前 SDU 还需要几个 K-frame（第一帧的载荷里要放 2 字节 SDU Length，
        /// §3.4.2）。空 SDU 也占一帧。
        pub fn framesLeft(self: *const Self) usize {
            if (!self.tx_active) return 0;
            var rest = self.tx_sdu.len - self.tx_pos;
            var first = self.tx_first;
            var used: usize = 0;
            while (true) {
                used += 1;
                const cap: usize = if (first) @as(usize, self.tx_mps) - 2 else @as(usize, self.tx_mps);
                const n: usize = @min(rest, cap);
                rest -= n;
                if (rest == 0) break;
                first = false;
            }
            return used;
        }

        /// 写下一个 K-frame（CID = `remote_cid`），返回字节数；发完返回 null。
        /// 没有额度 → `NoCredits`，状态不变（§10.1）。
        pub fn sendNext(self: *Self, out: []u8) Error!?usize {
            if (self.sendDone()) return null;
            if (self.tx_credits == 0) return error.NoCredits;
            const left = self.tx_sdu.len - self.tx_pos;
            const cap: usize = if (self.tx_first) @as(usize, self.tx_mps) - 2 else @as(usize, self.tx_mps);
            const n: usize = if (left > cap) cap else left;
            const pdu_len: usize = (if (self.tx_first) @as(usize, 2) else 0) + n;
            if (out.len < header_len + pdu_len) return error.NoSpace;
            (Header{ .length = @intCast(pdu_len), .cid = self.remote_cid }).encode(out[0..header_len]);
            var body = out[header_len .. header_len + pdu_len];
            if (self.tx_first) {
                // PDU Length = 载荷 + 2（§3.4.1）；SDU Length 是整个 SDU 的字节数。
                std.mem.writeInt(u16, body[0..2], @intCast(self.tx_sdu.len), .little);
                body = body[2..];
            }
            @memcpy(body[0..n], self.tx_sdu[self.tx_pos .. self.tx_pos + n]);
            self.tx_pos += n;
            self.tx_first = false;
            if (self.tx_pos == self.tx_sdu.len) self.tx_active = false;
            self.tx_credits -= 1;
            return header_len + pdu_len;
        }

        /// 放弃正在接收的 SDU（出现 §3.4.3 的三种断连条件之后调用）。
        pub fn abortRx(self: *Self) void {
            self.rx_total = 0;
            self.rx_len = 0;
        }

        pub const Rx = union(enum) {
            partial,
            /// 一个完整的 SDU。切片指向通道内部的缓冲，下一次 `receive` 之前有效。
            complete: []const u8,
        };

        /// 收一个 K-frame。三种“shall disconnect the channel”的情况各自是一个
        /// 错误（§3.4.3）：SDU 超过 MTU、载荷超过 MPS、累计超过 SDU Length。
        pub fn receive(self: *Self, kframe: []const u8) Error!Rx {
            const f = try decodeBFrame(kframe);
            if (f.cid != self.local_cid) return error.BadParam;
            // §10.1：额度为 0 时对端不得再发；这一帧是违规。
            if (self.rx_credits == 0) return error.CreditExceeded;
            self.rx_credits -= 1;
            if (f.payload.len > self.rx_mps) return error.MpsExceeded;

            var data = f.payload;
            if (self.rx_total == 0) {
                // SDU 的第一帧：载荷以 SDU Length 开头（§3.4.2）。
                if (data.len < 2) return error.Short;
                const sdu_len: usize = std.mem.readInt(u16, data[0..2], .little);
                if (sdu_len > self.rx_mtu) return error.SduTooLong;
                data = data[2..];
                self.rx_len = 0;
                self.rx_total = sdu_len;
            }
            if (data.len > self.rx_total - self.rx_len) return error.SduOverrun;
            @memcpy(self.rx_buf[self.rx_len .. self.rx_len + data.len], data);
            self.rx_len += data.len;
            if (self.rx_len == self.rx_total) {
                self.rx_total = 0;
                return .{ .complete = self.rx_buf[0..self.rx_len] };
            }
            return .partial;
        }

        /// 收到 Flow Control Credit Ind：发送额度加上去（§10.1）。
        pub fn addCredits(self: *Self, ind: CreditInd) Error!void {
            // §4.24：CID 是**发送方**的端点，也就是我们发帧时用的 remote_cid。
            if (ind.cid != self.remote_cid) return error.BadParam;
            if (ind.credits == 0) return error.BadParam;
            const sum: u32 = @as(u32, self.tx_credits) + @as(u32, ind.credits);
            if (sum > 65535) return error.CreditOverflow;
            self.tx_credits = @intCast(sum);
        }

        /// 给对端补额度：本端处理完若干 SDU 之后调用，返回一条可以直接发出去的
        /// Flow Control Credit Ind（CID 是本端 CID，§4.24）。
        pub fn creditInd(self: *const Self, out: []u8, identifier: u8, credits: u16) Error!usize {
            return encodeSig(out, identifier, .{ .le_credit_ind = .{ .cid = self.local_cid, .credits = credits } });
        }
    };
}
