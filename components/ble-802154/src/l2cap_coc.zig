//! ble-802154：LE 上基于额度的 L2CAP 连接（LE Credit Based Flow Control 与 Enhanced Credit
//! Based Flow Control 两种）——信令编解码、每条链路的信道表、K-frame 的分段与重组、
//! 额度记账。EATT bearer 建在它上面（`eatt.zig`）。
//!
//! 规范出处（Bluetooth Core Specification v5.4，[Vol 3] Part A，行号指
//! `/tmp/btcore-txt/v3a-l2cap.txt`）：
//!   * CID 名字空间 —— §2.1 表 2.3（2310–2317）：LE-U 上动态分配的 CID 是 0x0040–0x007F；
//!     同一条逻辑链路上两个同时活动的信道不得共用一个 CID（2219）。本文件让槽位 `i`
//!     固定用 CID `0x0040 + i`，所以「已分配的 CID 不得再用」由构造保证；
//!   * K-frame —— §3.4.1（2547–2550：PDU Length 多算 2 字节 SDU Length）、§3.4.2（2552：
//!     SDU 的第一帧带 SDU Length，值不大于对端 MTU）、§3.4.3（2556：SDU Length 超过
//!     MTU、任一帧载荷超过 MPS、载荷之和超过 SDU Length —— 三种都 shall disconnect）；
//!   * 信令 C-frame —— §4（2558–2566）：LE-U 信令信道 CID 0x0005，一个 C-frame 只放一条
//!     命令，Data Length 不对的包是 invalid behavior；§4.1（2691–2732，图 4.3、表 4.3）：
//!     Code 不认识时回 L2CAP_COMMAND_REJECT_RSP，Identifier 与被拒的命令相同，Reason
//!     0x0000（Command not understood，不带 Reason Data）；Identifier 0x00 无效（`l2cap.zig`）；
//!   * L2CAP_LE_CREDIT_BASED_CONNECTION_REQ / RSP —— §4.22 / §4.23（3165–3256，图 4.18、
//!     图 4.19，表 4.15 的 SPSM 范围、表 4.16 的结果码）：MTU / MPS 至少 23，MPS 最大
//!     65533，Initial Credits 0–65535；被拒时忽略 DCID / MTU / MPS / Initial Credits；
//!   * L2CAP_FLOW_CONTROL_CREDIT_IND —— §4.24（3257–3264，图 4.20）：CID 是**发送方**的
//!     端点，Credits 在 1–65535；
//!   * L2CAP_CREDIT_BASED_CONNECTION_REQ / RSP —— §4.25 / §4.26（3265–3347，图 4.21、
//!     图 4.22，表 4.17 的结果码）：一次最多 5 个 CID，MTU / MPS 至少 64，Initial Credits
//!     1–65535；DCID 的顺序与 SCID 一一对应；DCID 为 0x0000 表示那条信道没建立；收到
//!     已分配的 DCID 时新旧两条信道都不能用；全部被拒或全部挂起时忽略后四个字段；
//!   * L2CAP_CREDIT_BASED_RECONFIGURE_REQ / RSP —— §4.27 / §4.28（3348–3389，图 4.23、
//!     图 4.24，表 4.18 的结果码）与 §7.11（4472–4477）：MTU 不得缩小；一次配置多条时
//!     MPS 不得缩小；参数无效时回非零结果且不改任何值；发完手头需要旧 MPS 的 PDU 之后
//!     才回响应。REQ 里的 Destination CID 是**发请求一方**的端点（3360），所以在收它的
//!     一端按对端 CID（`remote_cid`）找信道；
//!   * 额度规则 —— §10.1 / §10.2（5839、5845）：额度为 0 不得发 K-frame；额度已是 0 时
//!     还收到 K-frame 就断开信道；额度之和超过 65535 断开信道；Credits 为 0 的指示忽略，
//!     自己也不得发 0；
//!   * 安全拒绝 —— §10.1 末段（5840）/ §10.2 第二段（5846）：认证不足、授权不足、加密
//!     密钥太短各自对应的结果码（表 4.16 / 表 4.17 里数值相同）；
//!   * EATT 的 SPSM 0x0027 —— Assigned Numbers（2026-11-16 版）SPSM 表：0x0027 = EATT，
//!     PSM or SPSM。
//!
//! 与本机 NimBLE（`~/esp/esp-idf/components/bt/host/nimble/nimble/nimble/`）交叉核对过：
//!   * 字段顺序 —— `host/src/ble_l2cap_sig_priv.h` 61–67（le_con_req）、69–75（le_con_rsp）、
//!     77–83（credit_base_connect_req）、85–91（rsp）、93–97（reconfig_req）、99–101
//!     （reconfig_rsp）、113–116（le_credits）；
//!   * 响应端的结果码 —— `host/src/ble_l2cap_sig.c` 812–916（重配置）、988–1177（增强
//!     连接）、1285–1393（旧式连接）；发起端的校验 —— 1180–1282、1395–1457；
//!   * 数据面 —— `host/src/ble_l2cap_coc.c` 234–365（接收）、520–644（发送）、646–678
//!     （额度溢出）；`host/src/ble_l2cap_coc_priv.h` 33–34（CID 范围）；
//!   * EATT 的 PSM —— `host/src/ble_eatt_priv.h` 29。
//!
//! 原文没有规定、这里定下来的几处（都写在各自的函数上）：多个拒绝理由同时成立时回
//! 哪一个；成功响应里 MTU / MPS 低于规定的最小值怎么处理；重配置时哪个方向出错。
//! 与 NimBLE 不同的只有一处：重配置请求里的 DCID 按原文找对端 CID（见 `onReconfigReq`）。
//!
//! 没有分配、没有全局状态。接收缓冲的大小在编译期定（`sdu_max`）。

const std = @import("std");
const l2cap = @import("l2cap.zig");
const svr = @import("att_server.zig");

pub const Error = error{
    /// 输入比一个基本头还短。
    Short,
    /// PDU Length 之后还有字节。
    Trailing,
    /// 输出缓冲不够。
    NoSpace,
    /// Data Length 与这条命令规定的长度不符，或 CID 数组的长度不是 2 的倍数。
    BadLength,
    /// 字段取值不合法、CID 不在本端范围、对端 CID 对不上。
    BadParam,
    /// 信令 Identifier 是 0x00。
    InvalidIdentifier,
    /// 不认识或不允许在 LE 信令信道上使用的 Code。
    UnknownCode,
    /// 已有一个连接或重配置过程在等响应，或重配置要求的「先发完手头的 PDU」做不到。
    Busy,
    /// 没有空闲槽位。
    NoChannel,
    /// 本端没有可发的 K-frame 额度（§10.1）。
    NoCredits,
    /// 收到帧时对端的额度已经是 0（§10.1）：断开信道。
    CreditExceeded,
    /// 额度之和超过 65535（§10.1）：断开信道。
    CreditOverflow,
    /// Credits 为 0 的指示：按 §10.1 忽略，状态不变。
    CreditIgnored,
    /// SDU 长度超过对端 MTU（§3.4.2）。
    SduTooLong,
    /// K-frame 载荷超过本端 MPS（§3.4.3）：断开信道。
    MpsExceeded,
    /// 各帧载荷之和超过 SDU Length（§3.4.3）：断开信道。
    SduOverrun,
    /// 重配置请求缩小了 MTU（§7.11）。
    MtuReduction,
    /// 重配置请求一次配置多条时缩小了 MPS（§7.11）。
    MpsReduction,
};

// ---------------------------------------------------------------------------
// 常量与结果码
// ---------------------------------------------------------------------------

/// EATT 的 SPSM（Assigned Numbers：EATT，PSM or SPSM 0x0027）。
pub const spsm_eatt: u16 = 0x0027;
/// SPSM 的固定区间与动态区间。表 4.15。
pub const spsm_fixed_lo: u16 = 0x0001;
pub const spsm_fixed_hi: u16 = 0x007F;
pub const spsm_dynamic_lo: u16 = 0x0080;
pub const spsm_dynamic_hi: u16 = 0x00FF;

/// LE-U 上动态分配的 CID。表 2.3。
pub const cid_lo: u16 = l2cap.cid_dynamic_lo;
pub const cid_hi: u16 = l2cap.cid_dynamic_hi;

/// CID 是否在 LE-U 动态分配区间里。表 2.3。与本地有几个槽位无关：对端可以用区间里的
/// 任何一个值当端点。
pub fn cidInRange(cid: u16) bool {
    return cid >= cid_lo and cid <= cid_hi;
}

/// 一条连接请求里的 CID 数上限。§4.25、§4.27。
pub const max_cids: usize = 5;
/// 旧式（LE Credit Based Flow Control）必须支持的最小 MTU 与 MPS。§4.22、§4.23。
pub const le_min_mtu: u16 = 23;
pub const le_min_mps: u16 = 23;
/// 增强式（Enhanced Credit Based Flow Control）必须支持的最小 MTU 与 MPS。§4.25、§4.26。
pub const ecoc_min_mtu: u16 = 64;
pub const ecoc_min_mps: u16 = 64;
/// MPS 的上限。§4.22、§4.23、§4.25、§4.26。
pub const max_mps: u16 = 65533;

/// L2CAP_LE_CREDIT_BASED_CONNECTION_RSP 的 Result。表 4.16。
pub const le_result = struct {
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

    /// 表 4.16 里列出的值；其余是 Reserved for future use。
    pub fn isKnown(r: u16) bool {
        return switch (r) {
            success,
            spsm_not_supported,
            no_resources,
            insufficient_authentication,
            insufficient_authorization,
            encryption_key_size_too_short,
            insufficient_encryption,
            invalid_source_cid,
            source_cid_already_allocated,
            unacceptable_parameters,
            => true,
            else => false,
        };
    }
};

/// L2CAP_CREDIT_BASED_CONNECTION_RSP 的 Result 的三种含义。
pub const ResultKind = enum {
    /// 0x0000：全部建立。
    success,
    /// 0x0004 / 0x0009 / 0x000A：部分被拒，逐个看 DCID 是否为 0。
    partial,
    /// 其余：全部被拒（不认识的值按 Reserved 处理，也当成全部被拒）。
    refused,
    /// 0x000D–0x000F：全部挂起，对端稍后还会再发一条响应。
    pending,
};

/// L2CAP_CREDIT_BASED_CONNECTION_RSP 的 Result。表 4.17。
pub const result = struct {
    pub const success: u16 = 0x0000;
    pub const all_refused_spsm: u16 = 0x0002;
    pub const some_refused_no_resources: u16 = 0x0004;
    pub const all_refused_insufficient_authentication: u16 = 0x0005;
    pub const all_refused_insufficient_authorization: u16 = 0x0006;
    pub const all_refused_key_size_too_short: u16 = 0x0007;
    pub const all_refused_insufficient_encryption: u16 = 0x0008;
    pub const some_refused_invalid_source_cid: u16 = 0x0009;
    pub const some_refused_source_cid_already_allocated: u16 = 0x000A;
    pub const all_refused_unacceptable_parameters: u16 = 0x000B;
    pub const all_refused_invalid_parameters: u16 = 0x000C;
    pub const all_pending: u16 = 0x000D;
    pub const all_pending_authentication: u16 = 0x000E;
    pub const all_pending_authorization: u16 = 0x000F;

    pub fn kind(r: u16) ResultKind {
        return switch (r) {
            success => .success,
            some_refused_no_resources, some_refused_invalid_source_cid, some_refused_source_cid_already_allocated => .partial,
            all_pending, all_pending_authentication, all_pending_authorization => .pending,
            else => .refused,
        };
    }
};

/// L2CAP_CREDIT_BASED_RECONFIGURE_RSP 的 Result。表 4.18。
pub const reconfig_result = struct {
    pub const success: u16 = 0x0000;
    pub const mtu_reduction: u16 = 0x0001;
    pub const mps_reduction: u16 = 0x0002;
    pub const invalid_dcid: u16 = 0x0003;
    pub const unacceptable_parameters: u16 = 0x0004;
};

/// L2CAP_COMMAND_REJECT_RSP 的 Reason。表 4.3（本文件只产生 0x0000，不带 Reason Data）。
pub const reject_command_not_understood: u16 = l2cap.reject.command_not_understood;

// ---------------------------------------------------------------------------
// 信令命令
// ---------------------------------------------------------------------------

/// 信令 Code。表 4.2 里 LE-U 信令信道（CID 0x0005）上与额度有关的几条。
pub const Code = enum(u8) {
    command_reject = 0x01,
    le_credit_conn_req = 0x14,
    le_credit_conn_rsp = 0x15,
    credit_ind = 0x16,
    credit_conn_req = 0x17,
    credit_conn_rsp = 0x18,
    reconfig_req = 0x19,
    reconfig_rsp = 0x1A,
    pub fn fromByte(b: u8) ?Code {
        return std.enums.fromInt(Code, b);
    }
};

/// 最多 5 个 CID 的数组。§4.25–§4.27。
pub const Cids = struct {
    n: u8 = 0,
    v: [max_cids]u16 = @splat(0),

    pub fn slice(self: *const Cids) []const u16 {
        return self.v[0..self.n];
    }
};

/// 图 4.18：SPSM、SCID、MTU、MPS、Initial Credits，各 2 字节。
pub const LeConnReq = struct { spsm: u16, scid: u16, mtu: u16, mps: u16, credits: u16 };
/// 图 4.19：DCID、MTU、MPS、Initial Credits、Result，各 2 字节。
pub const LeConnRsp = struct { dcid: u16, mtu: u16, mps: u16, credits: u16, result: u16 };
/// 图 4.20：CID、Credits，各 2 字节。
pub const CreditInd = struct { cid: u16, credits: u16 };
/// 图 4.21：SPSM、MTU、MPS、Initial Credits，Source CID 数组（2–10 字节）。
pub const ConnReq = struct { spsm: u16, mtu: u16, mps: u16, credits: u16, scids: Cids = .{} };
/// 图 4.22：MTU、MPS、Initial Credits、Result，Destination CID 数组（2–10 字节）。
pub const ConnRsp = struct { mtu: u16, mps: u16, credits: u16, result: u16, dcids: Cids = .{} };
/// 图 4.23：MTU、MPS，Destination CID 数组（2–10 字节）。
pub const ReconfigReq = struct { mtu: u16, mps: u16, dcids: Cids = .{} };
/// 图 4.24：Result。
pub const ReconfigRsp = struct { result: u16 };
/// 图 4.3：Reason（只有不带 Reason Data 的 0x0000）。
pub const CommandReject = struct { reason: u16 };

pub const Msg = union(enum) {
    command_reject: CommandReject,
    le_credit_conn_req: LeConnReq,
    le_credit_conn_rsp: LeConnRsp,
    credit_ind: CreditInd,
    credit_conn_req: ConnReq,
    credit_conn_rsp: ConnRsp,
    reconfig_req: ReconfigReq,
    reconfig_rsp: ReconfigRsp,

    pub fn code(self: Msg) Code {
        return switch (self) {
            .command_reject => .command_reject,
            .le_credit_conn_req => .le_credit_conn_req,
            .le_credit_conn_rsp => .le_credit_conn_rsp,
            .credit_ind => .credit_ind,
            .credit_conn_req => .credit_conn_req,
            .credit_conn_rsp => .credit_conn_rsp,
            .reconfig_req => .reconfig_req,
            .reconfig_rsp => .reconfig_rsp,
        };
    }
};

/// 一条信令命令与它的 Identifier。
pub const SigMsg = struct { identifier: u8, msg: Msg };

fn put16(out: []u8, i: usize, v: u16) void {
    std.mem.writeInt(u16, out[2 * i ..][0..2], v, .little);
}

fn get16(d: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, d[2 * i ..][0..2], .little);
}

fn cidsLen(dlen: usize, head: usize) Error!u8 {
    if (dlen < head + 2 or dlen > head + 2 * max_cids or (dlen - head) % 2 != 0) return error.BadLength;
    return @intCast((dlen - head) / 2);
}

/// 把一条命令的数据段写进 `d`，返回长度。
fn putData(msg: Msg, d: []u8) Error!usize {
    switch (msg) {
        .command_reject => |r| {
            put16(d, 0, r.reason);
            return 2;
        },
        .le_credit_conn_req => |r| {
            for ([_]u16{ r.spsm, r.scid, r.mtu, r.mps, r.credits }, 0..) |v, i| put16(d, i, v);
            return 10;
        },
        .le_credit_conn_rsp => |r| {
            for ([_]u16{ r.dcid, r.mtu, r.mps, r.credits, r.result }, 0..) |v, i| put16(d, i, v);
            return 10;
        },
        .credit_ind => |c| {
            put16(d, 0, c.cid);
            put16(d, 1, c.credits);
            return 4;
        },
        .credit_conn_req => |r| {
            for ([_]u16{ r.spsm, r.mtu, r.mps, r.credits }, 0..) |v, i| put16(d, i, v);
            for (r.scids.slice(), 0..) |v, i| put16(d, 4 + i, v);
            return 8 + 2 * r.scids.n;
        },
        .credit_conn_rsp => |r| {
            for ([_]u16{ r.mtu, r.mps, r.credits, r.result }, 0..) |v, i| put16(d, i, v);
            for (r.dcids.slice(), 0..) |v, i| put16(d, 4 + i, v);
            return 8 + 2 * r.dcids.n;
        },
        .reconfig_req => |r| {
            put16(d, 0, r.mtu);
            put16(d, 1, r.mps);
            for (r.dcids.slice(), 0..) |v, i| put16(d, 2 + i, v);
            return 4 + 2 * r.dcids.n;
        },
        .reconfig_rsp => |r| {
            put16(d, 0, r.result);
            return 2;
        },
    }
}

/// 封一条完整的信令 C-frame（基本头 + Code + Identifier + Data Length + Data），CID 0x0005。
/// CID 数组里必须有 1–5 个（§4.25–§4.27）；Identifier 为 0 → `InvalidIdentifier`。
pub fn encode(out: []u8, identifier: u8, msg: Msg) Error!usize {
    if (identifier == 0x00) return error.InvalidIdentifier;
    switch (msg) {
        .credit_conn_req => |r| if (r.scids.n == 0 or r.scids.n > max_cids) return error.BadParam,
        .credit_conn_rsp => |r| if (r.dcids.n == 0 or r.dcids.n > max_cids) return error.BadParam,
        .reconfig_req => |r| if (r.dcids.n == 0 or r.dcids.n > max_cids) return error.BadParam,
        else => {},
    }
    var data: [8 + 2 * max_cids]u8 = undefined;
    const n = try putData(msg, &data);
    if (out.len < l2cap.header_len + l2cap.sig_header_len + n) return error.NoSpace;
    (l2cap.Header{ .length = @intCast(l2cap.sig_header_len + n), .cid = l2cap.cid_le_signaling }).encode(out[0..l2cap.header_len]);
    const s = out[l2cap.header_len..];
    s[0] = @backingInt(msg.code());
    s[1] = identifier;
    std.mem.writeInt(u16, s[2..4], @intCast(n), .little);
    @memcpy(s[l2cap.sig_header_len..][0..n], data[0..n]);
    return l2cap.header_len + l2cap.sig_header_len + n;
}

/// 解一条信令 C-frame。CID 必须是 0x0005，长度必须与 Code 对得上；Code 不认识 →
/// `UnknownCode`（调用方回 Command Reject）。
pub fn decode(pdu: []const u8) Error!SigMsg {
    const f = try l2cap.decodeBFrame(pdu);
    if (f.cid != l2cap.cid_le_signaling) return error.BadParam;
    if (f.payload.len < l2cap.sig_header_len) return error.Short;
    const identifier = f.payload[1];
    if (identifier == 0x00) return error.InvalidIdentifier;
    const dlen: usize = std.mem.readInt(u16, f.payload[2..4], .little);
    if (f.payload.len != l2cap.sig_header_len + dlen) return error.BadLength;
    const d = f.payload[l2cap.sig_header_len..];
    const code = Code.fromByte(f.payload[0]) orelse return error.UnknownCode;
    const msg: Msg = switch (code) {
        .command_reject => blk: {
            if (dlen != 2) return error.BadLength;
            break :blk .{ .command_reject = .{ .reason = get16(d, 0) } };
        },
        .le_credit_conn_req => blk: {
            if (dlen != 10) return error.BadLength;
            break :blk .{ .le_credit_conn_req = .{
                .spsm = get16(d, 0),
                .scid = get16(d, 1),
                .mtu = get16(d, 2),
                .mps = get16(d, 3),
                .credits = get16(d, 4),
            } };
        },
        .le_credit_conn_rsp => blk: {
            if (dlen != 10) return error.BadLength;
            break :blk .{ .le_credit_conn_rsp = .{
                .dcid = get16(d, 0),
                .mtu = get16(d, 1),
                .mps = get16(d, 2),
                .credits = get16(d, 3),
                .result = get16(d, 4),
            } };
        },
        .credit_ind => blk: {
            if (dlen != 4) return error.BadLength;
            break :blk .{ .credit_ind = .{ .cid = get16(d, 0), .credits = get16(d, 1) } };
        },
        .credit_conn_req => blk: {
            const n = try cidsLen(dlen, 8);
            var r = ConnReq{ .spsm = get16(d, 0), .mtu = get16(d, 1), .mps = get16(d, 2), .credits = get16(d, 3) };
            r.scids = .{ .n = n, .v = readCids(d, 4, n) };
            break :blk .{ .credit_conn_req = r };
        },
        .credit_conn_rsp => blk: {
            const n = try cidsLen(dlen, 8);
            var r = ConnRsp{ .mtu = get16(d, 0), .mps = get16(d, 1), .credits = get16(d, 2), .result = get16(d, 3) };
            r.dcids = .{ .n = n, .v = readCids(d, 4, n) };
            break :blk .{ .credit_conn_rsp = r };
        },
        .reconfig_req => blk: {
            const n = try cidsLen(dlen, 4);
            var r = ReconfigReq{ .mtu = get16(d, 0), .mps = get16(d, 1) };
            r.dcids = .{ .n = n, .v = readCids(d, 2, n) };
            break :blk .{ .reconfig_req = r };
        },
        .reconfig_rsp => blk: {
            if (dlen != 2) return error.BadLength;
            break :blk .{ .reconfig_rsp = .{ .result = get16(d, 0) } };
        },
    };
    return .{ .identifier = identifier, .msg = msg };
}

fn readCids(d: []const u8, at: usize, n: u8) [max_cids]u16 {
    var v: [max_cids]u16 = @splat(0);
    for (0..n) |i| v[i] = get16(d, at + i);
    return v;
}

fn anyZero(cids: Cids) bool {
    for (cids.slice()) |v| {
        if (v == 0) return true;
    }
    return false;
}

/// SPSM 是否在表 4.15 的两个区间里。
pub fn spsmValid(spsm: u16) bool {
    return (spsm >= spsm_fixed_lo and spsm <= spsm_fixed_hi) or
        (spsm >= spsm_dynamic_lo and spsm <= spsm_dynamic_hi);
}

// ---------------------------------------------------------------------------
// 数据面：一条信道
// ---------------------------------------------------------------------------

pub const Rx = union(enum) {
    /// SDU 的一段，还没收全。
    partial,
    /// 一个完整的 SDU。切片指向调用方的接收缓冲，下一次 `receive` 之前有效。
    complete: []const u8,
};

/// 一次基于额度的信道交换的两个方向。`rx_*` 是本端能收的上限（连接与重配置时告诉
/// 对端的），`tx_*` 是对端能收的上限。MTU 是 SDU 上限，MPS 是单个 K-frame 的载荷上限
/// （§3.4.3）。额度：`tx_credits` 是对端给本端的、本端还能发几个 K-frame；`rx_credits`
/// 是本端给对端的、对端还能发几个（§10.1）。
///
/// `local_cid` 为 0 表示槽位空闲。
pub const Chan = struct {
    local_cid: u16 = 0,
    /// 对端的端点；`local_cid != 0` 而 `remote_cid == 0` 表示连接还在进行。
    remote_cid: u16 = 0,
    rx_mtu: u16 = 0,
    rx_mps: u16 = 0,
    tx_mtu: u16 = 0,
    tx_mps: u16 = 0,
    tx_credits: u16 = 0,
    rx_credits: u16 = 0,
    /// 本端收下、但还没用 L2CAP_FLOW_CONTROL_CREDIT_IND 还给对端的额度。
    rx_owed: u16 = 0,

    tx_sdu: []const u8 = &.{},
    tx_pos: usize = 0,
    tx_first: bool = true,
    tx_active: bool = false,

    rxing: bool = false,
    rx_total: usize = 0,
    rx_len: usize = 0,
    /// 新的接收 MPS：等手头这个 SDU 收完再生效（对端是按旧的、更大的 MPS 分段的）。
    rx_mps_pending: u16 = 0,

    pub fn used(self: *const Chan) bool {
        return self.local_cid != 0;
    }

    /// 两端的端点都有了：信道已建立，可以收发。
    pub fn established(self: *const Chan) bool {
        return self.local_cid != 0 and self.remote_cid != 0;
    }

    /// 有一个 SDU 正在发（可能卡在额度上）。
    pub fn sending(self: *const Chan) bool {
        return self.tx_active;
    }

    /// SDU 没发完，而且没有额度了。
    pub fn stalled(self: *const Chan) bool {
        return self.tx_active and self.tx_credits == 0;
    }

    /// 开始发一个 SDU。超过对端 MTU → `SduTooLong`（§3.4.2）；上一个还没发完 → `Busy`。
    /// `sdu` 必须在发完之前一直有效。
    pub fn startSend(self: *Chan, sdu: []const u8) Error!void {
        if (sdu.len > self.tx_mtu) return error.SduTooLong;
        if (self.tx_active) return error.Busy;
        self.tx_sdu = sdu;
        self.tx_pos = 0;
        self.tx_first = true;
        self.tx_active = true;
    }

    /// 还需要几个 K-frame（第一帧的载荷里要放 2 字节 SDU Length，§3.4.2）。空 SDU 也占一帧。
    pub fn framesLeft(self: *const Chan) usize {
        if (!self.tx_active) return 0;
        var rest = self.tx_sdu.len - self.tx_pos;
        var first = self.tx_first;
        var frames: usize = 0;
        while (true) {
            frames += 1;
            const cap: usize = if (first) @as(usize, self.tx_mps) - 2 else self.tx_mps;
            const n = @min(rest, cap);
            rest -= n;
            if (rest == 0) break;
            first = false;
        }
        return frames;
    }

    /// 写下一个 K-frame（CID 是 `remote_cid`），返回字节数；当前 SDU 已发完返回 null。
    /// 没有额度 → `NoCredits`，状态不变（§10.1）。
    pub fn sendNext(self: *Chan, out: []u8) Error!?usize {
        if (!self.tx_active) return null;
        if (self.tx_credits == 0) return error.NoCredits;
        const cap: usize = if (self.tx_first) @as(usize, self.tx_mps) - 2 else self.tx_mps;
        const left = self.tx_sdu.len - self.tx_pos;
        const n: usize = if (left > cap) cap else left;
        const head: usize = if (self.tx_first) 2 else 0;
        if (out.len < l2cap.header_len + head + n) return error.NoSpace;
        (l2cap.Header{ .length = @intCast(head + n), .cid = self.remote_cid }).encode(out[0..l2cap.header_len]);
        var body = out[l2cap.header_len .. l2cap.header_len + head + n];
        if (self.tx_first) {
            // PDU Length = 载荷 + 2（§3.4.1）；SDU Length 是整个 SDU 的字节数（§3.4.2）。
            std.mem.writeInt(u16, body[0..2], @intCast(self.tx_sdu.len), .little);
            body = body[2..];
        }
        @memcpy(body[0..n], self.tx_sdu[self.tx_pos .. self.tx_pos + n]);
        self.tx_pos += n;
        self.tx_first = false;
        self.tx_credits -= 1;
        if (self.tx_pos == self.tx_sdu.len) self.tx_active = false;
        return l2cap.header_len + head + n;
    }

    /// 收一个 K-frame。`rbuf` 是这条信道的接收缓冲，长度必须不小于 `rx_mtu`。
    /// 三种 shall disconnect 的情况与额度违规各是一个错误，调用方据此断开信道：
    /// `SduTooLong`、`MpsExceeded`、`SduOverrun`（§3.4.3）、`CreditExceeded`（§10.1）。
    pub fn receive(self: *Chan, rbuf: []u8, kframe: []const u8) Error!Rx {
        const f = try l2cap.decodeBFrame(kframe);
        if (f.cid != self.local_cid) return error.BadParam;
        errdefer self.rxing = false;
        // §10.1：对端的额度已经是 0 还发过来，就是违规。
        if (self.rx_credits == 0) return error.CreditExceeded;
        self.rx_credits -= 1;
        if (f.payload.len > self.rx_mps) return error.MpsExceeded;

        var data = f.payload;
        if (!self.rxing) {
            // SDU 的第一帧：载荷以 SDU Length 开头（§3.4.2）。
            if (data.len < 2) return error.Short;
            const total: usize = std.mem.readInt(u16, data[0..2], .little);
            if (data.len - 2 > total) return error.SduOverrun;
            if (total > self.rx_mtu) return error.SduTooLong;
            self.rxing = true;
            self.rx_total = total;
            self.rx_len = 0;
            data = data[2..];
        }
        if (data.len > self.rx_total - self.rx_len) return error.SduOverrun;
        @memcpy(rbuf[self.rx_len .. self.rx_len + data.len], data);
        self.rx_len += data.len;
        self.rx_owed +|= 1;
        if (self.rx_len == self.rx_total) {
            self.rxing = false;
            if (self.rx_mps_pending != 0) {
                self.rx_mps = self.rx_mps_pending;
                self.rx_mps_pending = 0;
            }
            return .{ .complete = rbuf[0..self.rx_len] };
        }
        return .partial;
    }

    /// 收到 L2CAP_FLOW_CONTROL_CREDIT_IND：发送额度加上去（§10.1）。CID 是**发送方**的
    /// 端点，也就是本端发帧用的 `remote_cid`（§4.24）。Credits 为 0 → `CreditIgnored`
    /// （§10.1：忽略）；之和超过 65535 → `CreditOverflow`（§10.1：断开信道）。
    pub fn addCredits(self: *Chan, ind: CreditInd) Error!void {
        if (ind.cid != self.remote_cid) return error.BadParam;
        if (ind.credits == 0) return error.CreditIgnored;
        const sum: u32 = @as(u32, self.tx_credits) + ind.credits;
        if (sum > 65535) return error.CreditOverflow;
        self.tx_credits = @intCast(sum);
    }

    /// 对端能收的 MTU 与 MPS 变了（§7.11：对端发来重配置，或本端是重配置的发起方
    /// 收到成功响应之后由对端执行）。只能在手头没有按旧 MPS 分段的 SDU 在发时调用。
    pub fn setPeerLimits(self: *Chan, mtu: u16, mps: u16) void {
        self.tx_mtu = mtu;
        self.tx_mps = mps;
    }

    /// 本端能收的 MTU 与 MPS 变了。MPS 变小的时候，正在收的 SDU 仍按旧 MPS 收完。
    pub fn setOwnLimits(self: *Chan, mtu: u16, mps: u16) void {
        self.rx_mtu = mtu;
        if (self.rxing) self.rx_mps_pending = mps else self.rx_mps = mps;
    }
};

// ---------------------------------------------------------------------------
// 一条逻辑链路：信道表与信令过程
// ---------------------------------------------------------------------------

/// 本端的接收参数。连接请求、连接响应、重配置请求里的 MTU / MPS / Initial Credits
/// 都是这一组（§4.22、§4.23、§4.25、§4.26、§4.27）。
pub const Params = struct { mtu: u16, mps: u16, credits: u16 };

/// 建信道之前对链路的安全要求。EATT 要求加密（[Vol 3] Part G §5.3.2）。
pub const Need = struct {
    authenticated: bool = false,
    authorized: bool = false,
    encrypted: bool = false,
    /// 要求加密时密钥至少要有这么多字节；0 表示不限。
    min_key_size: u8 = 0,
};

/// 按 §10.1 末段 / §10.2 第二段给出拒绝的结果码：认证 → 授权 → 加密 → 密钥长度。
/// 两种连接的结果码数值相同（表 4.16、表 4.17）。
pub fn securityResult(sec: svr.Security, need: Need) ?u16 {
    if (need.authenticated and !sec.authenticated) return le_result.insufficient_authentication;
    if (need.authorized and !sec.authorized) return le_result.insufficient_authorization;
    if ((need.encrypted or need.authenticated) and !sec.encrypted) return le_result.insufficient_encryption;
    if ((need.encrypted or need.authenticated) and need.min_key_size > 0 and sec.key_size < need.min_key_size) {
        return le_result.encryption_key_size_too_short;
    }
    return null;
}

/// 发起端一次连接过程的结果。
pub const ConnectDone = struct { established: u8 = 0, refused: u8 = 0, result: u16 = 0 };

/// `onSignal()` 除了可能产生一条应答之外，还报告发生了什么。
pub const Event = union(enum) {
    none,
    /// 响应端：刚建立了这么多条信道。
    connected: u8,
    /// 发起端：连接过程结束。
    connect_done: ConnectDone,
    /// 响应端：对端重配置了这么多条信道。
    peer_reconfigured: u8,
    /// 发起端：重配置过程结束，这是响应里的 Result。
    reconfigured: u16,
    /// 收到额度指示：加了这么多。
    credits_added: u16,
    /// 有信道因为对端的违规被断开：额度溢出（§10.1），或连接响应里的 DCID 已经分配
    /// （§4.26，这时新旧两条都断）。`closed` 里是断开前的对端 CID，本端 CID 为 0 的
    /// 那条还没建立。
    closed: Cids,
};

pub const Outcome = struct { out_len: usize = 0, event: Event = .none };

const PendingKind = enum { connect, connect_le, reconfig };

/// 在途的信令过程：一个 Identifier、涉及的槽位与 CID。
const Pending = struct {
    kind: PendingKind,
    id: u8,
    n: u8,
    slots: [max_cids]u8 = @splat(0),
    /// connect：本端 CID；reconfig：要重配置的本端 CID。
    cids: [max_cids]u16 = @splat(0),
    mtu: u16 = 0,
    mps: u16 = 0,
};

/// 一条逻辑链路上的全部基于额度的信道与信令过程。`capacity` 是信道槽位数（CID
/// `0x0040 + i`），`sdu_max` 是每条信道的接收缓冲大小，也是本端 MTU 的上限。
///
/// 两个角色都支持：发起端用 `connect()` / `connectLe()` / `reconfigure()`，响应端只用
/// `onSignal()`；同一条链路上两个方向的信令互不干扰。收发数据用 `receive()` /
/// `startSend()` / `sendNext()`；收下的额度用 `flushCredits()` 还给对端。
pub fn Link(comptime capacity: usize, comptime sdu_max: usize) type {
    if (capacity == 0 or capacity > @as(usize, cid_hi - cid_lo) + 1) @compileError("capacity 必须在 1..64");
    if (sdu_max < ecoc_min_mtu or sdu_max > max_mps) @compileError("sdu_max 必须在 64..65533");
    return struct {
        const Self = @This();

        pub const buffer_max: usize = sdu_max;

        chans: [capacity]Chan = @splat(.{}),
        bufs: [capacity][sdu_max]u8 = undefined,
        /// 本端的接收参数。默认 MTU 取满缓冲、MPS 取 64、额度 8。
        params: Params = .{ .mtu = sdu_max, .mps = @min(sdu_max, 64), .credits = 8 },
        /// 本端提供（响应端）或要连（发起端）的 SPSM。
        spsm: u16 = spsm_eatt,
        /// 旧式的 LE Credit Based Connection Request（0x14）也让建信道。EATT 不允许
        /// （[Vol 3] Part G §5.3：EATT 用 L2CAP_CREDIT_BASED_CONNECTION_REQ）。
        legacy_ok: bool = true,
        /// 链路的安全状态与建信道的要求。响应端据此回 0x0005–0x0008（§10.1、§10.2）。
        sec: svr.Security = .{},
        need: Need = .{},
        /// 下一个信令 Identifier。0x00 无效，所以到 0xFF 之后回到 0x01。
        next_id: u8 = 1,
        pending: ?Pending = null,

        pub fn allocId(self: *Self) u8 {
            const id = self.next_id;
            self.next_id = if (id == 0xFF) 1 else id + 1;
            return id;
        }

        /// 改本端的接收参数。MTU 装不进缓冲 → `NoSpace`；小于规定的最小值或额度
        /// 不在 1–65535 → `BadParam`（额度是 Initial Credits，增强式要求至少 1）。
        pub fn setParams(self: *Self, p: Params) Error!void {
            if (p.mtu > sdu_max) return error.NoSpace;
            if (p.mtu < ecoc_min_mtu or p.mps < ecoc_min_mps or p.mps > max_mps or p.credits == 0) return error.BadParam;
            self.params = p;
        }

        /// 槽位 `i` 的 CID。
        pub fn cidOf(i: usize) u16 {
            return @intCast(cid_lo + i);
        }

        /// CID 是不是本端某条信道的端点；是就返回槽位。
        pub fn slotOf(cid: u16) ?usize {
            if (cid < cid_lo or cid > cid_hi) return null;
            const i: usize = cid - cid_lo;
            return if (i < capacity) i else null;
        }

        /// 以 `cid` 为对端端点（本端发帧用的 CID）的已建立信道。
        pub fn byRemoteCid(self: *const Self, cid: u16) ?usize {
            for (&self.chans, 0..) |*c, i| {
                if (c.established() and c.remote_cid == cid) return i;
            }
            return null;
        }

        pub fn establishedCount(self: *const Self) u8 {
            var n: u8 = 0;
            for (&self.chans) |*c| {
                if (c.established()) n += 1;
            }
            return n;
        }

        /// 本地断开一条信道（§3.4.3、§10.1 的 disconnect，或 §4.26 的 shall not be used）。
        pub fn close(self: *Self, i: usize) void {
            self.chans[i] = .{};
        }

        /// 断开这条链路上的全部信道。
        pub fn disconnect(self: *Self) void {
            self.chans = @splat(.{});
            self.pending = null;
        }

        fn freeSlot(self: *const Self) ?usize {
            for (&self.chans, 0..) |*c, i| {
                if (!c.used()) return i;
            }
            return null;
        }

        /// 接收参数写进一条刚建的信道。
        fn armRx(self: *Self, c: *Chan) void {
            c.rx_mtu = self.params.mtu;
            c.rx_mps = self.params.mps;
            c.rx_credits = self.params.credits;
        }

        // -----------------------------------------------------------------
        // 数据面
        // -----------------------------------------------------------------

        /// 收一个 K-frame（K-frame 的 CID 决定是哪条信道）。信道必须是已建立的。
        pub fn receive(self: *Self, i: usize, kframe: []const u8) Error!Rx {
            if (!self.chans[i].established()) return error.NoChannel;
            return self.chans[i].receive(&self.bufs[i], kframe);
        }

        pub fn startSend(self: *Self, i: usize, sdu: []const u8) Error!void {
            if (!self.chans[i].established()) return error.NoChannel;
            return self.chans[i].startSend(sdu);
        }

        pub fn sendNext(self: *Self, i: usize, out: []u8) Error!?usize {
            if (!self.chans[i].established()) return error.NoChannel;
            return self.chans[i].sendNext(out);
        }

        /// 还额度。每收下一个 K-frame 就欠对端一个额度；这个函数把欠得最多的那条信道
        /// 的额度用一条 L2CAP_FLOW_CONTROL_CREDIT_IND 还回去（§4.24：CID 是本端 CID）。
        /// 没有欠的返回 null。还给对端的额度不会让对端的额度超过 65535（§10.1）。
        pub fn flushCredits(self: *Self, out: []u8) Error!?usize {
            var best: ?usize = null;
            var best_owed: u16 = 0;
            for (&self.chans, 0..) |*c, i| {
                if (c.established() and c.rx_owed > best_owed) {
                    best = i;
                    best_owed = c.rx_owed;
                }
            }
            const i = best orelse return null;
            return try self.grantCredits(out, i, 0);
        }

        /// 给信道 `i` 的对端补 `credits` 个额度；传 0 表示「把欠的都还了」。一条指示
        /// 发不下的额度留在 `rx_owed` 里下次再还。
        pub fn grantCredits(self: *Self, out: []u8, i: usize, credits: u16) Error!?usize {
            const c = &self.chans[i];
            if (!c.established()) return error.NoChannel;
            const room: u16 = @intCast(65535 - @as(u32, c.rx_credits));
            const n = if (credits == 0) @min(c.rx_owed, room) else @min(credits, room);
            if (n == 0) return null;
            const len = try encode(out, self.allocId(), .{ .credit_ind = .{ .cid = c.local_cid, .credits = n } });
            c.rx_credits += n;
            if (credits == 0) c.rx_owed -= n;
            return len;
        }

        // -----------------------------------------------------------------
        // 发起端
        // -----------------------------------------------------------------

        fn begin(self: *Self, kind: PendingKind, n: u8) Error!*Pending {
            if (self.pending != null) return error.Busy;
            self.pending = .{ .kind = kind, .id = self.allocId(), .n = n };
            return &self.pending.?;
        }

        /// 发 L2CAP_CREDIT_BASED_CONNECTION_REQ（图 4.21）：用 `n` 个空闲槽位各建一条
        /// 信道，SPSM 取 `self.spsm`，MTU / MPS / Initial Credits 取 `self.params`（§4.25）。
        /// 响应到来之前槽位已占住；过程结束（或失败）时才放开。
        pub fn connect(self: *Self, out: []u8, n: u8) Error!usize {
            if (n == 0 or n > max_cids) return error.BadParam;
            const p = try self.begin(.connect, n);
            errdefer self.abandon(p);
            var req = ConnReq{ .spsm = self.spsm, .mtu = self.params.mtu, .mps = self.params.mps, .credits = self.params.credits };
            var k: u8 = 0;
            for (&self.chans, 0..) |*c, i| {
                if (k == n) break;
                if (c.used()) continue;
                c.* = .{ .local_cid = cidOf(i) };
                self.armRx(c);
                p.slots[k] = @intCast(i);
                p.cids[k] = c.local_cid;
                req.scids.v[k] = c.local_cid;
                k += 1;
            }
            if (k < n) return error.NoChannel;
            req.scids.n = n;
            return encode(out, p.id, .{ .credit_conn_req = req });
        }

        /// 发 L2CAP_LE_CREDIT_BASED_CONNECTION_REQ（图 4.18）：只用一条信道，MTU / MPS /
        /// Initial Credits 同样取 `self.params`。对端回的 MTU / MPS 允许小到 23（§4.23）。
        pub fn connectLe(self: *Self, out: []u8) Error!usize {
            if (!self.legacy_ok) return error.BadParam;
            const slot = self.freeSlot() orelse return error.NoChannel;
            const p = try self.begin(.connect_le, 1);
            errdefer self.abandon(p);
            const c = &self.chans[slot];
            c.* = .{ .local_cid = cidOf(slot) };
            self.armRx(c);
            p.slots[0] = @intCast(slot);
            p.cids[0] = c.local_cid;
            return encode(out, p.id, .{ .le_credit_conn_req = .{
                .spsm = self.spsm,
                .scid = c.local_cid,
                .mtu = self.params.mtu,
                .mps = self.params.mps,
                .credits = self.params.credits,
            } });
        }

        /// 发 L2CAP_CREDIT_BASED_RECONFIGURE_REQ（图 4.23）：本端以后能收 MTU / MPS。
        /// `cids` 是本端 CID（§4.27：数组是发请求一方的端点），1–5 条。§7.11 的两条
        /// 义务在这里先查：MTU 不得缩小 → `MtuReduction`；一次配置多条时 MPS 不得缩小
        /// → `MpsReduction`。新 MTU 装不进接收缓冲 → `NoSpace`。
        pub fn reconfigure(self: *Self, out: []u8, cids: []const u16, mtu: u16, mps: u16) Error!usize {
            if (cids.len == 0 or cids.len > max_cids) return error.BadParam;
            if (mtu > sdu_max) return error.NoSpace;
            if (mtu < ecoc_min_mtu or mps < ecoc_min_mps or mps > max_mps) return error.BadParam;
            if (self.pending != null) return error.Busy;
            var slots: [max_cids]u8 = @splat(0);
            for (cids, 0..) |cid, k| {
                const i = slotOf(cid) orelse return error.BadParam;
                if (!self.chans[i].established()) return error.NoChannel;
                if (self.chans[i].rx_mtu > mtu) return error.MtuReduction;
                if (cids.len > 1 and self.chans[i].rx_mps > mps) return error.MpsReduction;
                slots[k] = @intCast(i);
            }
            const p = try self.begin(.reconfig, @intCast(cids.len));
            errdefer self.abandon(p);
            p.slots = slots;
            for (cids, 0..) |cid, k| p.cids[k] = cid;
            p.mtu = mtu;
            p.mps = mps;
            return encode(out, p.id, .{ .reconfig_req = .{
                .mtu = mtu,
                .mps = mps,
                .dcids = .{ .n = @intCast(cids.len), .v = p.cids },
            } });
        }

        /// 过程失败：放开它占的槽位（已建立的信道留着）。
        fn abandon(self: *Self, p: *Pending) void {
            if (p.kind == .reconfig) {
                self.pending = null;
                return;
            }
            for (p.slots[0..p.n]) |i| {
                if (!self.chans[i].established()) self.close(i);
            }
            self.pending = null;
        }

        fn takePending(self: *Self, id: u8, kind: PendingKind) ?*Pending {
            const p = &(self.pending orelse return null);
            if (p.id != id or p.kind != kind) return null;
            return p;
        }

        /// 收到连接响应：按 DCID 逐条落定。`ConnRsp.dcids.n` 必须等于请求里的 SCID 数
        /// （§4.26：顺序一一对应）。
        fn onConnRsp(self: *Self, id: u8, rsp: ConnRsp) Error!Event {
            const p = self.takePending(id, .connect) orelse return .none;
            if (rsp.dcids.n != p.n) {
                self.abandon(p);
                return error.BadLength;
            }
            switch (result.kind(rsp.result)) {
                .refused => {
                    // §4.26：全部被拒时忽略 DCID / MTU / MPS / Initial Credits。
                    const r = rsp.result;
                    const n = p.n;
                    self.abandon(p);
                    return .{ .connect_done = .{ .established = 0, .refused = n, .result = r } };
                },
                .pending => return .none,
                .success, .partial => {},
            }
            // §4.26：MTU / MPS 至少 64、MPS 最大 65533、Initial Credits 在 1–65535；DCID 要么是 0
            // （那条没建立），要么在动态分配区间里（表 2.3）。结果码是成功时 DCID 也不得为 0。
            // 响应带着不合法的字段就整条不可信：槽位全部放开，过程作废。
            var bad = rsp.mtu < ecoc_min_mtu or rsp.mps < ecoc_min_mps or rsp.mps > max_mps or rsp.credits == 0;
            for (rsp.dcids.slice()) |d| {
                if (d != 0 and !cidInRange(d)) bad = true;
            }
            if (bad or (rsp.result == result.success and anyZero(rsp.dcids))) {
                self.abandon(p);
                return error.BadParam;
            }
            var done = ConnectDone{ .result = rsp.result };
            var closed = Cids{};
            for (p.slots[0..p.n], rsp.dcids.slice()) |i, dcid| {
                const c = &self.chans[i];
                if (dcid == 0) {
                    // 部分被拒：DCID 为 0 的那一条没建立。
                    self.close(i);
                    done.refused += 1;
                    continue;
                }
                if (self.byRemoteCid(dcid)) |old| {
                    // §4.26：已分配的 DCID —— 原来那条和新的这条都不能用。
                    self.close(old);
                    self.close(i);
                    done.refused += 1;
                    closed.v[closed.n] = dcid;
                    closed.n += 1;
                    continue;
                }
                c.remote_cid = dcid;
                c.tx_mtu = rsp.mtu;
                c.tx_mps = rsp.mps;
                c.tx_credits = rsp.credits;
                done.established += 1;
            }
            self.pending = null;
            return if (closed.n != 0) .{ .closed = closed } else .{ .connect_done = done };
        }

        fn onLeConnRsp(self: *Self, id: u8, rsp: LeConnRsp) Error!Event {
            const p = self.takePending(id, .connect_le) orelse return .none;
            const i = p.slots[0];
            if (rsp.result != le_result.success) {
                // §4.23：被拒时忽略 DCID / MTU / MPS / Initial Credits。
                const r = rsp.result;
                self.abandon(p);
                return .{ .connect_done = .{ .refused = 1, .result = r } };
            }
            if (rsp.mtu < le_min_mtu or rsp.mps < le_min_mps or rsp.mps > max_mps or slotOf(rsp.dcid) == null) {
                self.abandon(p);
                return error.BadParam;
            }
            if (self.byRemoteCid(rsp.dcid)) |old| {
                // §4.23：DCID shall not be already allocated。
                self.close(old);
                self.abandon(p);
                var closed = Cids{};
                closed.v[0] = rsp.dcid;
                closed.n = 1;
                return .{ .closed = closed };
            }
            const c = &self.chans[i];
            c.remote_cid = rsp.dcid;
            c.tx_mtu = rsp.mtu;
            c.tx_mps = rsp.mps;
            c.tx_credits = rsp.credits;
            self.pending = null;
            return .{ .connect_done = .{ .established = 1 } };
        }

        fn onReconfigRsp(self: *Self, id: u8, r: u16) Event {
            const p = self.takePending(id, .reconfig) orelse return .none;
            if (r == reconfig_result.success) {
                // §7.11：响应之后这些信道的 MTU 与 MPS 改成请求里的值。
                for (p.slots[0..p.n]) |i| self.chans[i].setOwnLimits(p.mtu, p.mps);
            }
            self.pending = null;
            return .{ .reconfigured = r };
        }

        fn onCreditInd(self: *Self, ind: CreditInd) Event {
            const i = self.byRemoteCid(ind.cid) orelse return .none;
            self.chans[i].addCredits(ind) catch |e| switch (e) {
                error.CreditIgnored => return .none,
                error.CreditOverflow => {
                    // §10.1：额度之和超过 65535，断开信道。
                    var closed = Cids{ .n = 1 };
                    closed.v[0] = ind.cid;
                    self.close(i);
                    return .{ .closed = closed };
                },
                else => return .none,
            };
            return .{ .credits_added = ind.credits };
        }

        // -----------------------------------------------------------------
        // 响应端
        // -----------------------------------------------------------------

        /// 结构检查之后、逐条信道之前的拒绝理由。原文没有规定多个理由同时成立时回
        /// 哪一个，这里的顺序是：结构 → SPSM → 安全 → Source CID。
        fn refuseConnReq(self: *const Self, req: ConnReq) ?u16 {
            // §4.25：MTU / MPS 至少 64，MPS 最大 65533，Initial Credits 在 1–65535。
            if (req.mtu < ecoc_min_mtu or req.mps < ecoc_min_mps or req.mps > max_mps or req.credits == 0) {
                return result.all_refused_invalid_parameters;
            }
            if (!self.servesSpsm(req.spsm)) return result.all_refused_spsm;
            if (securityResult(self.sec, self.need)) |r| return r;
            for (req.scids.slice(), 0..) |scid, k| {
                // 动态分配区间（表 2.3）；请求里的 SCID 不得重复。
                if (!cidInRange(scid)) return result.some_refused_invalid_source_cid;
                for (req.scids.slice()[0..k]) |prev| {
                    if (prev == scid) return result.some_refused_invalid_source_cid;
                }
            }
            return null;
        }

        fn servesSpsm(self: *const Self, spsm: u16) bool {
            return spsm == self.spsm and spsmValid(spsm);
        }

        /// 响应端处理一条请求后的应答与事件。
        const Replied = struct { len: usize, event: Event };

        /// 收到 L2CAP_CREDIT_BASED_CONNECTION_REQ（§4.25）。应答里 Destination CID 数组
        /// 的第 `i` 项对应 Source CID 数组的第 `i` 项；为 0 表示那条没建立。
        fn onConnReq(self: *Self, id: u8, req: ConnReq, out: []u8) Error!Replied {
            var rsp = ConnRsp{ .mtu = self.params.mtu, .mps = self.params.mps, .credits = self.params.credits, .result = 0 };
            rsp.dcids.n = req.scids.n;
            var made: u8 = 0;
            if (self.refuseConnReq(req)) |r| {
                rsp.result = r;
            } else {
                for (req.scids.slice(), 0..) |scid, k| {
                    if (self.byRemoteCid(scid)) |old| {
                        // SCID 已经是一条信道的对端端点。回那条信道的 DCID：发起端看到已
                        // 分配的 DCID 会把新旧两条都弃掉（§4.26）。
                        rsp.result = result.some_refused_source_cid_already_allocated;
                        rsp.dcids.v[k] = self.chans[old].local_cid;
                        continue;
                    }
                    const slot = self.freeSlot() orelse {
                        rsp.result = result.some_refused_no_resources;
                        continue;
                    };
                    const c = &self.chans[slot];
                    c.* = .{ .local_cid = cidOf(slot), .remote_cid = scid };
                    self.armRx(c);
                    c.tx_mtu = req.mtu;
                    c.tx_mps = req.mps;
                    c.tx_credits = req.credits;
                    rsp.dcids.v[k] = c.local_cid;
                    made += 1;
                }
            }
            const len = try encode(out, id, .{ .credit_conn_rsp = rsp });
            return .{ .len = len, .event = .{ .connected = made } };
        }

        /// 旧式 L2CAP_LE_CREDIT_BASED_CONNECTION_REQ 的拒绝理由（全部拒绝）：SPSM → 安全
        /// → Source CID 越界 → MTU / MPS 小于 23（§4.22；旧式没有「invalid parameters」
        /// 这个码，用 0x000B unacceptable parameters）。
        fn refuseLeConnReq(self: *const Self, req: LeConnReq) ?u16 {
            if (!self.legacy_ok or !self.servesSpsm(req.spsm)) return le_result.spsm_not_supported;
            if (securityResult(self.sec, self.need)) |r| return r;
            if (!cidInRange(req.scid)) return le_result.invalid_source_cid;
            if (req.mtu < le_min_mtu or req.mps < le_min_mps or req.mps > max_mps) return le_result.unacceptable_parameters;
            return null;
        }

        /// 收到 L2CAP_LE_CREDIT_BASED_CONNECTION_REQ（§4.22）：只建一条信道。之后按顺序是
        /// SCID 已占用（0x000A）与没有空闲槽位（0x0004）。
        fn onLeConnReq(self: *Self, id: u8, req: LeConnReq, out: []u8) Error!Replied {
            var r: u16 = 0;
            if (self.refuseLeConnReq(req)) |code| r = code;
            if (r == 0 and self.byRemoteCid(req.scid) != null) r = le_result.source_cid_already_allocated;
            const slot: ?usize = if (r == 0) (self.freeSlot() orelse blk: {
                r = le_result.no_resources;
                break :blk null;
            }) else null;
            var rsp = LeConnRsp{ .dcid = 0, .mtu = self.params.mtu, .mps = self.params.mps, .credits = self.params.credits, .result = r };
            var made: u8 = 0;
            if (slot) |i| {
                const c = &self.chans[i];
                c.* = .{ .local_cid = cidOf(i), .remote_cid = req.scid };
                self.armRx(c);
                c.tx_mtu = req.mtu;
                c.tx_mps = req.mps;
                c.tx_credits = req.credits;
                rsp.dcid = c.local_cid;
                made = 1;
            }
            const len = try encode(out, id, .{ .le_credit_conn_rsp = rsp });
            return .{ .len = len, .event = .{ .connected = made } };
        }

        /// 收到 L2CAP_CREDIT_BASED_RECONFIGURE_REQ（§4.27、§7.11）。请求里的 MTU / MPS 是
        /// **对端**以后能收的上限，所以改的是本端的发送上限。参数无效时回非零结果、
        /// 不改任何值。多个理由同时成立时原文没规定回哪个，这里的顺序是：结构（0x0004）
        /// → DCID 无效（0x0003）→ MTU 缩小（0x0001）→ MPS 缩小（0x0002）。
        ///
        /// DCID 按原文（3360）是发请求一方的端点，所以在本端找 `remote_cid` 相同的
        /// 信道。NimBLE 在这里按自己的 SCID 找（`ble_l2cap_sig.c` 880），方向相反；两端
        /// 都从 0x0040 起分配时看不出区别，本文件以原文为准。
        fn onReconfigReq(self: *Self, id: u8, req: ReconfigReq, out: []u8) Error!Replied {
            var r: u16 = 0;
            var chans: [max_cids]usize = @splat(0);
            var n: usize = 0;
            // §4.27：MPS 最大 65533，每个 DCID 非零；最小值 64 取自 §4.25（发请求的一方的接收上限）。
            if (req.mtu < ecoc_min_mtu or req.mps < ecoc_min_mps or req.mps > max_mps or anyZero(req.dcids)) {
                r = reconfig_result.unacceptable_parameters;
            } else {
                for (req.dcids.slice()) |dcid| {
                    const i = self.byRemoteCid(dcid) orelse {
                        r = reconfig_result.invalid_dcid;
                        break;
                    };
                    chans[n] = i;
                    n += 1;
                }
            }
            if (r == 0) {
                for (chans[0..n]) |i| {
                    if (self.chans[i].tx_mtu > req.mtu) {
                        r = reconfig_result.mtu_reduction;
                        break;
                    }
                }
            }
            if (r == 0 and n > 1) {
                for (chans[0..n]) |i| {
                    if (self.chans[i].tx_mps > req.mps) {
                        r = reconfig_result.mps_reduction;
                        break;
                    }
                }
            }
            if (r != 0) {
                const len = try encode(out, id, .{ .reconfig_rsp = .{ .result = r } });
                return .{ .len = len, .event = .none };
            }
            for (chans[0..n]) |i| {
                // §7.11：先发完手头需要旧 MPS 的 PDU 再回响应。发不完就回 `Busy`，不改
                // 状态，调用方稍后把同一条 PDU 再交进来。
                if (self.chans[i].sending()) return error.Busy;
            }
            for (chans[0..n]) |i| self.chans[i].setPeerLimits(req.mtu, req.mps);
            const len = try encode(out, id, .{ .reconfig_rsp = .{ .result = 0 } });
            return .{ .len = len, .event = .{ .peer_reconfigured = @intCast(n) } };
        }

        // -----------------------------------------------------------------
        // 入口
        // -----------------------------------------------------------------

        /// 处理对端发来的一条信令 C-frame。应答（如果有）写进 `out`，长度在
        /// `out_len`；发生的事在 `event`。不认识的 Code 回 Command Reject；与在途过程
        /// 无关的响应忽略。
        pub fn onSignal(self: *Self, pdu: []const u8, out: []u8) Error!Outcome {
            var o = Outcome{};
            const f = try l2cap.decodeBFrame(pdu);
            if (f.cid != l2cap.cid_le_signaling) return error.BadParam;
            const id: u8 = if (f.payload.len >= 2) f.payload[1] else 0;
            const m = decode(pdu) catch |e| switch (e) {
                // §4.1：Code 不认识就回 Command not understood，Identifier 相同。
                error.UnknownCode => {
                    o.out_len = try encode(out, id, .{ .command_reject = .{ .reason = reject_command_not_understood } });
                    return o;
                },
                else => return e,
            };
            switch (m.msg) {
                .command_reject => {
                    // 对端不认我们的命令：在途的过程作废。
                    if (self.pending) |*p| {
                        if (p.id == m.identifier) self.abandon(p);
                    }
                },
                .le_credit_conn_req => |req| {
                    const r = try self.onLeConnReq(m.identifier, req, out);
                    o.out_len = r.len;
                    o.event = r.event;
                },
                .le_credit_conn_rsp => |rsp| o.event = try self.onLeConnRsp(m.identifier, rsp),
                .credit_ind => |ind| o.event = self.onCreditInd(ind),
                .credit_conn_req => |req| {
                    const r = try self.onConnReq(m.identifier, req, out);
                    o.out_len = r.len;
                    o.event = r.event;
                },
                .credit_conn_rsp => |rsp| o.event = try self.onConnRsp(m.identifier, rsp),
                .reconfig_req => |req| {
                    const r = try self.onReconfigReq(m.identifier, req, out);
                    o.out_len = r.len;
                    o.event = r.event;
                },
                .reconfig_rsp => |r| o.event = self.onReconfigRsp(m.identifier, r.result),
            }
            return o;
        }
    };
}
