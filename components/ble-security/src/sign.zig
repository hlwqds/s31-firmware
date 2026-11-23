//! ble-security：签名数据——ATT Signed Write Command 的签名与验签。
//!
//! 出处：Bluetooth Core Specification 5.4：
//!   * [Vol 3] Part H 2.4.5    签名算法：M = m || SignCounter（最低位八位组在前），
//!                             AES-CMAC 截 64 位；SignCounter 从 0 起、每签一条加一；
//!                             验证方保存最近一次通过的计数器防重放
//!   * [Vol 3] Part F 3.3.1    Authentication Signature 覆盖 Attribute Opcode 与
//!                             Attribute Parameters；只有 ATT_WRITE_CMD 可以带签名
//!   * [Vol 3] Part F 3.4.5.4  ATT_SIGNED_WRITE_CMD：0xD2、Handle(2)、Value、
//!                             Signature(12)，以及 m = D212001337 的样例
//!
//! 规范在 CMAC 输入的字节序上自相矛盾，本文件**按 Part F 3.4.5.4 的样例数值实现**
//! （见 `signatureMac` 的注释）；这是全组件唯一一处「样例与正文字面不一致」的地方，
//! README 的「实现偏离」里有说明。
//!
//! 签名与验签都不需要连接，所以这里没有状态机；`Signer` 只记着计数器。

const std = @import("std");

const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

const toolbox = @import("toolbox.zig");

pub const Key = toolbox.Key;

/// [Vol 3] Part F 3.4.5.4。
pub const opcode_signed_write: u8 = 0xD2;

/// SignCounter(4) + MAC 的前 8 字节。
pub const signature_len = 12;
pub const counter_len = 4;
pub const mac_len = 8;
/// opcode + handle + signature。
pub const min_pdu_len = 1 + 2 + signature_len;
/// Attribute Value 的长度上限是 ATT_MTU − 15（3.4.5.4）。
pub const value_overhead = 15;

pub const Error = error{
    /// PDU 短于 15 字节。
    Short,
    /// 第一个字节不是 0xD2。
    BadOpcode,
    /// 输出缓冲放不下。
    NoSpace,
};

/// 2.4.5：算 CMAC，取前 64 位。
///
/// 输入的字节序有一处规范内部矛盾，按 [Vol 3] Part F 3.4.5.4 的样例处理：
/// 2.4.5 的文字把 M = m || SignCounter 写成自然顺序，但 Part F 样例给的
/// padding(M) = 0x0000000137130012D2 80 00… 是把 M = D212001337 01 00 00 00
/// **逐字节反转**后的 16 字节，样例的 CMAC F20F903C… 也只有按这个反转输入才
/// 算得出来（自然顺序算出来是 53907596…）。所以这里先喂 SignCounter 的最高位
/// 八位组，再把 m 倒着喂，最后是 opcode。输出的 8 字节按样例是 CMAC 前 8 字节
/// 的倒序。
fn signatureMac(csrk: Key, counter: u32, msg: []const u8) [mac_len]u8 {
    var ctx = CmacAes128.init(&csrk);
    var ctr: [counter_len]u8 = undefined;
    std.mem.writeInt(u32, &ctr, counter, .big);
    ctx.update(&ctr);
    var i = msg.len;
    while (i > 0) {
        i -= 1;
        ctx.update(msg[i..][0..1]);
    }
    var mac: [16]u8 = undefined;
    ctx.final(&mac);
    return toolbox.reverse(mac_len, mac[0..mac_len].*);
}

/// 2.4.5 的发送方：持有 CSRK 与 SignCounter。
pub const Signer = struct {
    csrk: Key,
    /// CSRK 生成时清零，每签一条消息加一。
    counter: u32 = 0,

    pub fn init(csrk: Key) Signer {
        return .{ .csrk = csrk };
    }

    /// 给 `msg` 签名，输出 12 字节签名（SignCounter 最低位八位组在前，然后是
    /// 8 字节 MAC），然后把计数器加一。
    pub fn sign(self: *Signer, msg: []const u8, sig_out: *[signature_len]u8) void {
        std.mem.writeInt(u32, sig_out[0..counter_len], self.counter, .little);
        sig_out[counter_len..signature_len].* = signatureMac(self.csrk, self.counter, msg);
        self.counter +%= 1;
    }

    /// 直接得到完整的 ATT_SIGNED_WRITE_CMD：opcode || handle || value || signature。
    pub fn signWrite(self: *Signer, handle: u16, value: []const u8, out: []u8) Error!usize {
        const total = min_pdu_len + value.len;
        if (out.len < total) return error.NoSpace;
        out[0] = opcode_signed_write;
        std.mem.writeInt(u16, out[1..3], handle, .little);
        @memcpy(out[3..][0..value.len], value);
        var sig: [signature_len]u8 = undefined;
        self.sign(out[0 .. 3 + value.len], &sig);
        @memcpy(out[3 + value.len ..][0..signature_len], &sig);
        return total;
    }
};

pub const VerifyResult = enum {
    ok,
    /// MAC 对不上。
    bad_signature,
    /// SignCounter 不大于已记录的值，这条消息（或更新的）之前见过。
    replayed,
};

pub const Verdict = struct {
    result: VerifyResult,
    /// 签名里的 SignCounter；`ok` 时应写回验证方的安全数据库。
    counter: u32,
};

/// 2.4.5 的验证方：重算 MAC 并比较，再用保存的计数器防重放。
/// `last_counter` 是最近一次验证通过的 SignCounter；还没验证过就传 null。
pub fn verifySignature(
    csrk: Key,
    last_counter: ?u32,
    msg: []const u8,
    sig: *const [signature_len]u8,
) Verdict {
    const counter = std.mem.readInt(u32, sig[0..counter_len], .little);
    if (last_counter) |last| {
        if (counter <= last) return .{ .result = .replayed, .counter = counter };
    }
    const expected = signatureMac(csrk, counter, msg);
    if (!std.crypto.timing_safe.eql([mac_len]u8, expected, sig[counter_len..signature_len].*)) {
        return .{ .result = .bad_signature, .counter = counter };
    }
    return .{ .result = .ok, .counter = counter };
}

pub const SignedWrite = struct {
    handle: u16,
    /// 指向输入 PDU 内部的切片。
    value: []const u8,
    signature: [signature_len]u8,
};

/// 解析 ATT_SIGNED_WRITE_CMD。只做布局检查，不验签。
pub fn decodeSignedWrite(pdu_bytes: []const u8) Error!SignedWrite {
    if (pdu_bytes.len < min_pdu_len) return error.Short;
    if (pdu_bytes[0] != opcode_signed_write) return error.BadOpcode;
    const value_len = pdu_bytes.len - min_pdu_len;
    return .{
        .handle = std.mem.readInt(u16, pdu_bytes[1..3], .little),
        .value = pdu_bytes[3 .. 3 + value_len],
        .signature = pdu_bytes[3 + value_len ..][0..signature_len].*,
    };
}

/// 验一条 ATT_SIGNED_WRITE_CMD：m 是 opcode + handle + value（3.3.1）。
pub fn verifySignedWrite(
    csrk: Key,
    last_counter: ?u32,
    pdu_bytes: []const u8,
) Error!Verdict {
    if (pdu_bytes.len < min_pdu_len) return error.Short;
    if (pdu_bytes[0] != opcode_signed_write) return error.BadOpcode;
    const split = pdu_bytes.len - signature_len;
    const sig: *const [signature_len]u8 = pdu_bytes[split..][0..signature_len];
    return verifySignature(csrk, last_counter, pdu_bytes[0..split], sig);
}
