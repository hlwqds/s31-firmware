//! net-tls-http：握手后的**记录保护**（TLS 1.3 的 TLSCiphertext）。
//!
//! 握手消息解析（`tls_handshake.zig`）与 AEAD（`aead.zig`）各自都有用例，但中间
//! 还差一层：把明文记录变成 `0x17 0x0303 length | ciphertext | tag`，以及反过来。
//! 这一层是"能解析消息"与"能在线上安全收发"之间的全部差距，且它的错误全部是
//! **静默**的：nonce 写错一位、AD 用错长度、序号没递增，解出来的都是垃圾而不报错
//! （对方会当成 `bad_record_mac` 直接断开，本地只看到"握手卡住"）。
//!
//! 规则（RFC 8446 §5.2-5.3）：
//!
//! ```text
//! nonce   = iv XOR seq            （seq 从 0 起，每发/收一条记录 +1，握手与
//!                                  应用数据的序号**各自独立**，切换密钥时归零）
//! AD      = 0x17 0x03 0x03 len    （外层 content type 永远是 application_data(23)，
//!                                  真正的类型藏在明文末尾）
//! plaintext = content || inner_type || 0..15 个零
//! ```
//!
//! 这层**不做**密钥调度、不决定何时切换，只接收一对 `(key, iv, seq)`。
const std = @import("std");
const aead = @import("aead.zig");
const record = @import("tls_record.zig");

pub const Opened = struct { len: usize, ct: u8 };

pub const Error = error{
    BufferTooSmall,
    /// 密文长度不是 tag 的整数倍关系（< tag 或短于 tag）。
    TooShort,
    /// 解出来的内容类型不是已知值（或全是填充）。
    BadInnerType,
    /// AEAD 校验失败：密钥/序号/AD 任一不对都会落到这里。
    AuthFailed,
    LengthOverflow,
};

/// 一条记录的头：外层永远是 `application_data` + 0x0303。
pub const header = [5]u8{ 22 + 1, 0x03, 0x03, 0, 0 };

pub const KeyState = struct {
    key: [aead.key_length]u8,
    iv: [aead.nonce_length]u8,
    seq: u64 = 0,

    pub fn init(secret: [32]u8) KeyState {
        var ks: KeyState = undefined;
        aead.deriveKeyIv(secret, &ks.key, &ks.iv);
        ks.seq = 0;
        return ks;
    }

    fn nonce(self: *const KeyState) [aead.nonce_length]u8 {
        var n = self.iv;
        var s = self.seq;
        var i: usize = aead.nonce_length;
        while (i > 0) {
            i -= 1;
            n[i] ^= @truncate(s & 0xff);
            s >>= 8;
        }
        return n;
    }
};

/// 明文 `content` 打成一条 TLSCiphertext，返回整条记录的长度（含 5 字节头）。
/// 调用方负责在成功后 `ks.seq += 1`——封装在这里做，是为了让调用点无法忘记
/// （忘记递增 ⇒ 同一 nonce 复用 ⇒ 密钥流泄露）。
pub fn seal(out: []u8, ks: *KeyState, content_type: u8, content: []const u8) Error!usize {
    const ct_len = content.len + 1; // + inner type
    const total = record.header_len + ct_len + aead.tag_length;
    if (out.len < total) return Error.BufferTooSmall;
    if (ct_len + aead.tag_length > record.max_record_length) return Error.LengthOverflow;

    record.writeHeader(out[0..record.header_len], .application_data, ct_len + aead.tag_length) catch return Error.LengthOverflow;

    const ct = out[record.header_len..][0..ct_len];
    const tag: *[aead.tag_length]u8 = @ptrCast(out[record.header_len + ct_len ..][0..aead.tag_length]);
    @memcpy(ct[0..content.len], content);
    ct[content.len] = content_type;

    const ad = aead.additionalData(@backingInt(record.ContentType.application_data), ct_len + aead.tag_length);
    aead.sealWithNonce(ct, tag, ct, &ad, ks.nonce(), ks.key) catch return Error.BufferTooSmall;
    ks.seq += 1;
    return total;
}

/// 解开一条 TLSCiphertext（**整条记录**，含 5 字节头）。
pub fn open(out: []u8, ks: *KeyState, record_bytes: []const u8) Error!Opened {
    if (record_bytes.len < record.header_len + aead.tag_length) return Error.TooShort;
    const hdr = record.readHeader(record_bytes[0..record.header_len]) catch return Error.TooShort;
    if (hdr.content_type != .application_data) return Error.BadInnerType;
    return openFragment(out, ks, record_bytes[record.header_len..][0..hdr.length]);
}

/// 解一段密文（**不含**记录头）：AD 的长度字段必须用 `ciphertext.len`（含 tag）。
/// 分开这一层是为了让驱动在"记录已被拆开"时不必为了 5 字节头再复制一整条记录
/// （在 16 KiB 栈的板子上，那份拷贝正好是放不下的）。
pub fn openFragment(out: []u8, ks: *KeyState, ciphertext: []const u8) Error!Opened {
    if (ciphertext.len < aead.tag_length + 1) return Error.TooShort;
    const payload_len = ciphertext.len - aead.tag_length;
    if (payload_len > out.len) return Error.BufferTooSmall;

    const tag = ciphertext[payload_len..][0..aead.tag_length];
    const ad = aead.additionalData(@backingInt(record.ContentType.application_data), ciphertext.len);
    aead.openWithNonce(out[0..payload_len], ciphertext[0..payload_len], tag.*, &ad, ks.nonce(), ks.key) catch return Error.AuthFailed;
    ks.seq += 1;

    var type_index: ?usize = null;
    var i: usize = payload_len;
    while (i > 0) {
        i -= 1;
        if (out[i] != 0) {
            type_index = i;
            break;
        }
    }
    const ti = type_index orelse return Error.BadInnerType;
    const inner = out[ti];
    if (inner == 0) return Error.BadInnerType;
    return .{ .len = ti, .ct = inner };
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

const test_secret: [32]u8 = @splat(0x5C);

test "protect: 同一密钥下 seal → open 还原内容与类型" {
    var tx = KeyState.init(test_secret);
    var rx = KeyState.init(test_secret);
    var buf: [512]u8 = undefined;
    const msg = "handshake-finished-bytes";
    const n = try seal(&buf, &tx, 22, msg); // 22 = handshake
    try std.testing.expectEqual(@as(u8, 23), buf[0]); // 外层永远是 application_data
    try std.testing.expectEqual(@as(u16, 0x0303), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(usize, n), @as(usize, 5) + msg.len + 1 + 16);

    var out: [512]u8 = undefined;
    const r = try open(&out, &rx, buf[0..n]);
    try std.testing.expectEqual(@as(u8, 22), r.ct);
    try std.testing.expectEqualStrings(msg, out[0..r.len]);
    try std.testing.expectEqual(@as(u64, 1), tx.seq);
    try std.testing.expectEqual(@as(u64, 1), rx.seq);
}

test "protect: 序号参与 nonce——同样的明文两条记录密文不同" {
    var tx = KeyState.init(test_secret);
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const n1 = try seal(&buf1, &tx, 23, "same");
    const n2 = try seal(&buf2, &tx, 23, "same");
    try std.testing.expectEqual(n1, n2);
    try std.testing.expect(!std.mem.eql(u8, buf1[5..n1], buf2[5..n2]));
}

test "protect: 篡改一个字节 ⇒ AuthFailed（不是静默错误数据）" {
    var tx = KeyState.init(test_secret);
    var rx = KeyState.init(test_secret);
    var buf: [256]u8 = undefined;
    const n = try seal(&buf, &tx, 23, "payload");
    buf[7] ^= 0x01;
    var out: [256]u8 = undefined;
    try std.testing.expectError(Error.AuthFailed, open(&out, &rx, buf[0..n]));
    // 失败的记录不推进序号（RFC 要求的 "bad_record_mac 后连接终止"，这里只保证计数不乱跳）
    try std.testing.expectEqual(@as(u64, 0), rx.seq);
}

test "protect: 序号错位/密钥不同都解不开" {
    var tx = KeyState.init(test_secret);
    var buf: [256]u8 = undefined;
    const n = try seal(&buf, &tx, 22, "x");

    var wrong_seq = KeyState.init(test_secret);
    wrong_seq.seq = 5;
    var out: [256]u8 = undefined;
    try std.testing.expectError(Error.AuthFailed, open(&out, &wrong_seq, buf[0..n]));

    const other: [32]u8 = @splat(0x5D);
    var wrong_key = KeyState.init(other);
    try std.testing.expectError(Error.AuthFailed, open(&out, &wrong_key, buf[0..n]));
}

test "protect: 内层类型为 0 的退化为 BadInnerType，过短记录报 TooShort" {
    var tx = KeyState.init(test_secret);
    var rx = KeyState.init(test_secret);
    var buf: [256]u8 = undefined;
    const n = try seal(&buf, &tx, 0, "");
    var out: [256]u8 = undefined;
    try std.testing.expectError(Error.BadInnerType, open(&out, &rx, buf[0..n]));

    try std.testing.expectError(Error.TooShort, open(&out, &rx, buf[0..5]));
}
