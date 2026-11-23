//! ble-security：SMP 命令的编解码。
//!
//! 出处：Bluetooth Core Specification 5.4 [Vol 3] Part H：
//!   * 3.3          命令格式与命令码表（Table 3.3）；保留码收到后应忽略
//!   * 3.5.1/3.5.2  Pairing Request / Response：IO Capability(1)、OOB data flag(1)、
//!                  AuthReq(1)、Maximum Encryption Key Size(1)、两个 Key Distribution(1)
//!   * 3.5.3–3.5.8  Confirm(16)、Random(16)、Failed(1)、Public Key(64)、DHKey Check(16)、
//!                  Keypress Notification(1)
//!   * 3.6.2–3.6.7  Encryption Information(16)、Central Identification(2+8)、
//!                  Identity Information(16)、Identity Address Information(1+6)、
//!                  Signing Information(16)、Security Request(1)
//!   * 1.2.1        多八位组字段最低位八位组先传
//!
//! 所以线上的 16/32/64 位字段都是小端；本组件内部一律用大端（与规范的十六进制
//! 写法一致），换序只在本文件发生。图 3.11 / 3.3 的位序已对照官方页面的插图核对：
//! AuthReq 低到高是 Bonding_Flags(2)、MITM、SC、Keypress、CT2、RFU(2)；
//! Key Distribution 低到高是 EncKey、IdKey、SignKey、LinkKey、RFU(4)。
//!
//! 每种命令的长度是固定的：短了 `Short`，长了 `Trailing`，都不静默容忍。

const std = @import("std");

const ecc = @import("ecc.zig");
const toolbox = @import("toolbox.zig");

/// Pairing Public Key：1 + 64 字节，是最长的 SMP 命令（3.2 的 MTU 65）。
pub const max_len = 65;

pub const Code = enum(u8) {
    pairing_request = 0x01,
    pairing_response = 0x02,
    pairing_confirm = 0x03,
    pairing_random = 0x04,
    pairing_failed = 0x05,
    encryption_information = 0x06,
    central_identification = 0x07,
    identity_information = 0x08,
    identity_address_information = 0x09,
    signing_information = 0x0A,
    security_request = 0x0B,
    pairing_public_key = 0x0C,
    pairing_dhkey_check = 0x0D,
    pairing_keypress_notification = 0x0E,
};

pub const Error = error{
    /// 短于该命令的固定长度。
    Short,
    /// 长于固定长度。
    Trailing,
    /// 命令码是保留值（3.3：应忽略）。
    UnknownCode,
    /// 输出缓冲放不下。
    NoSpace,
};

/// 3.6.5 Identity Address Information 的 AddrType。
pub const addr_type_public: u8 = 0x00;
pub const addr_type_random: u8 = 0x01;

/// Pairing Request / Response 的 6 个字段，原始字节；取值合法性由 `pairing.zig` 判断。
pub const Features = struct {
    io_cap: u8,
    oob: u8,
    auth_req: u8,
    max_key_size: u8,
    initiator_keys: u8,
    responder_keys: u8,
};

pub const Pdu = union(enum) {
    pairing_request: Features,
    pairing_response: Features,
    pairing_confirm: toolbox.Key,
    pairing_random: toolbox.Key,
    /// Pairing Failed 的 Reason（Table 3.7）。
    pairing_failed: u8,
    encryption_information: toolbox.Key,
    central_identification: struct { ediv: u16, rand: u64 },
    identity_information: toolbox.Key,
    /// `addr_type` 只应是 0x00（public）或 0x01（static random）。
    identity_address_information: struct { addr_type: u8, addr: toolbox.Addr },
    signing_information: toolbox.Key,
    /// Security Request 的 AuthReq 字节。
    security_request: u8,
    pairing_public_key: ecc.Pub,
    pairing_dhkey_check: toolbox.Key,
    keypress_notification: u8,

    pub fn code(self: Pdu) Code {
        return switch (self) {
            .pairing_request => .pairing_request,
            .pairing_response => .pairing_response,
            .pairing_confirm => .pairing_confirm,
            .pairing_random => .pairing_random,
            .pairing_failed => .pairing_failed,
            .encryption_information => .encryption_information,
            .central_identification => .central_identification,
            .identity_information => .identity_information,
            .identity_address_information => .identity_address_information,
            .signing_information => .signing_information,
            .security_request => .security_request,
            .pairing_public_key => .pairing_public_key,
            .pairing_dhkey_check => .pairing_dhkey_check,
            .keypress_notification => .pairing_keypress_notification,
        };
    }
};

fn keyAt(body: []const u8) toolbox.Key {
    return toolbox.reverse(16, body[0..16].*);
}

pub fn decode(bytes: []const u8) Error!Pdu {
    if (bytes.len == 0) return error.Short;
    const c: Code = std.enums.fromInt(Code, bytes[0]) orelse return error.UnknownCode;
    const body = bytes[1..];
    switch (c) {
        .pairing_request, .pairing_response => {
            if (body.len < 6) return error.Short;
            if (body.len > 6) return error.Trailing;
            const f = Features{
                .io_cap = body[0],
                .oob = body[1],
                .auth_req = body[2],
                .max_key_size = body[3],
                .initiator_keys = body[4],
                .responder_keys = body[5],
            };
            return if (c == .pairing_request) .{ .pairing_request = f } else .{ .pairing_response = f };
        },
        .pairing_confirm, .pairing_random, .encryption_information, .identity_information, .signing_information, .pairing_dhkey_check => {
            if (body.len < 16) return error.Short;
            if (body.len > 16) return error.Trailing;
            return switch (c) {
                .pairing_confirm => .{ .pairing_confirm = keyAt(body) },
                .pairing_random => .{ .pairing_random = keyAt(body) },
                .encryption_information => .{ .encryption_information = keyAt(body) },
                .identity_information => .{ .identity_information = keyAt(body) },
                .signing_information => .{ .signing_information = keyAt(body) },
                else => .{ .pairing_dhkey_check = keyAt(body) },
            };
        },
        .pairing_failed, .security_request, .pairing_keypress_notification => {
            if (body.len < 1) return error.Short;
            if (body.len > 1) return error.Trailing;
            return switch (c) {
                .pairing_failed => .{ .pairing_failed = body[0] },
                .security_request => .{ .security_request = body[0] },
                else => .{ .keypress_notification = body[0] },
            };
        },
        .central_identification => {
            if (body.len < 10) return error.Short;
            if (body.len > 10) return error.Trailing;
            return .{ .central_identification = .{
                .ediv = std.mem.readInt(u16, body[0..2], .little),
                .rand = std.mem.readInt(u64, body[2..10], .little),
            } };
        },
        .identity_address_information => {
            if (body.len < 7) return error.Short;
            if (body.len > 7) return error.Trailing;
            return .{ .identity_address_information = .{ .addr_type = body[0], .addr = body[1..7].* } };
        },
        .pairing_public_key => {
            if (body.len < 64) return error.Short;
            if (body.len > 64) return error.Trailing;
            return .{ .pairing_public_key = .{
                .x = toolbox.reverse(32, body[0..32].*),
                .y = toolbox.reverse(32, body[32..64].*),
            } };
        },
    }
}

fn putKey(out: []u8, key: toolbox.Key) void {
    out[0..16].* = toolbox.reverse(16, key);
}

/// 编码一条命令，返回写入的字节数。`out` 至少 `max_len` 字节时一定放得下。
pub fn encode(p: Pdu, out: []u8) Error!usize {
    const c = p.code();
    switch (p) {
        .pairing_request, .pairing_response => |f| {
            if (out.len < 7) return error.NoSpace;
            out[0] = @backingInt(c);
            out[1] = f.io_cap;
            out[2] = f.oob;
            out[3] = f.auth_req;
            out[4] = f.max_key_size;
            out[5] = f.initiator_keys;
            out[6] = f.responder_keys;
            return 7;
        },
        .pairing_confirm, .pairing_random, .encryption_information, .identity_information, .signing_information, .pairing_dhkey_check => {
            if (out.len < 17) return error.NoSpace;
            out[0] = @backingInt(c);
            putKey(out[1..17], switch (p) {
                .pairing_confirm => |v| v,
                .pairing_random => |v| v,
                .encryption_information => |v| v,
                .identity_information => |v| v,
                .signing_information => |v| v,
                .pairing_dhkey_check => |v| v,
                else => unreachable,
            });
            return 17;
        },
        .pairing_failed, .security_request, .keypress_notification => |v| {
            if (out.len < 2) return error.NoSpace;
            out[0] = @backingInt(c);
            out[1] = v;
            return 2;
        },
        .central_identification => |v| {
            if (out.len < 11) return error.NoSpace;
            out[0] = @backingInt(c);
            std.mem.writeInt(u16, out[1..3], v.ediv, .little);
            std.mem.writeInt(u64, out[3..11], v.rand, .little);
            return 11;
        },
        .identity_address_information => |v| {
            if (out.len < 8) return error.NoSpace;
            out[0] = @backingInt(c);
            out[1] = v.addr_type;
            @memcpy(out[2..8], &v.addr);
            return 8;
        },
        .pairing_public_key => |pk| {
            if (out.len < 65) return error.NoSpace;
            out[0] = @backingInt(c);
            out[1..33].* = toolbox.reverse(32, pk.x);
            out[33..65].* = toolbox.reverse(32, pk.y);
            return 65;
        },
    }
}
