//! 证书吊销列表（CRL）的最小实现：解析、用签发者验签、按序列号查表。
//!
//! 只支持本仓生成的 CRL（ECDSA P-256 + SHA-256），复用 `cert.zig` 的 DER 原语。
//!
//! 结构（RFC 5280 §5.1）：
//!   CertificateList ::= SEQUENCE { tbsCertList, sigAlg, signature BIT STRING }
//!   tbsCertList ::= SEQUENCE { version [0]?, sigAlg, issuer, thisUpdate,
//!                              nextUpdate?, revokedCertificates?, crlExtensions? }
//!   revokedCertificates ::= SEQUENCE OF SEQUENCE { userCertificate INTEGER, revocationDate, ... }
//!
//! 不做 OCSP、不做增量 CRL、不解析扩展。序列号按**原始字节**比较（去掉前导 0），
//! 因为序列号允许超过 64 位，数值化会截断。

const std = @import("std");
const cert = @import("cert.zig");

pub const Error = error{
    BadDer,
    BadSignature,
    TooManyEntries,
};

pub const max_entries = 16;

pub const Crl = struct {
    /// tbsCertList 的原始 DER（验签输入）。
    tbs: []const u8,
    /// BIT STRING 去掉 unused-bits 字节后的 ECDSA-Sig-Value DER。
    sig: []const u8,
    serials: [max_entries][]const u8 = @splat(&.{}),
    len: usize = 0,

    pub fn isRevoked(self: *const Crl, serial: []const u8) bool {
        const want = stripZeros(serial);
        for (self.serials[0..self.len]) |s| {
            if (std.mem.eql(u8, stripZeros(s), want)) return true;
        }
        return false;
    }
};

fn stripZeros(b: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < b.len and b[i] == 0) : (i += 1) {}
    return b[i..];
}

/// 解析并用 `issuer` 验签。`issuer` 必须是签发这张 CRL 的证书（不是根）。
pub fn parse(der: []const u8, issuer: *const cert.Cert) Error!Crl {
    var p: usize = 0;
    const root = cert.nextTlv(der, &p) catch return Error.BadDer;
    if (root.tag != 0x30) return Error.BadDer;

    var q: usize = 0;
    const tbs = cert.nextTlv(root.body, &q) catch return Error.BadDer;
    const sig_alg = cert.nextTlv(root.body, &q) catch return Error.BadDer;
    const sig_bits = cert.nextTlv(root.body, &q) catch return Error.BadDer;
    if (tbs.tag != 0x30 or sig_alg.tag != 0x30 or sig_bits.tag != 0x03) return Error.BadDer;
    if (sig_bits.body.len < 2 or sig_bits.body[0] != 0) return Error.BadDer;

    var out: Crl = .{ .tbs = tbs.raw, .sig = sig_bits.body[1..] };

    var t: usize = 0;
    var field = cert.nextTlv(tbs.body, &t) catch return Error.BadDer;
    if (field.tag == 0xA0) field = cert.nextTlv(tbs.body, &t) catch return Error.BadDer; // version
    if (field.tag != 0x30) return Error.BadDer; // sigAlg
    _ = cert.nextTlv(tbs.body, &t) catch return Error.BadDer; // issuer
    _ = cert.nextTlv(tbs.body, &t) catch return Error.BadDer; // thisUpdate

    while (t < tbs.body.len) {
        const item = cert.nextTlv(tbs.body, &t) catch return Error.BadDer;
        if (item.tag == 0xA0) break; // crlExtensions
        if (item.tag != 0x30) continue; // nextUpdate (UTCTime / GeneralizedTime)
        var r: usize = 0;
        while (r < item.body.len) {
            const entry = cert.nextTlv(item.body, &r) catch return Error.BadDer;
            if (entry.tag != 0x30) return Error.BadDer;
            var e: usize = 0;
            const serial = cert.nextTlv(entry.body, &e) catch return Error.BadDer;
            if (serial.tag != 0x02) return Error.BadDer;
            if (out.len == max_entries) return Error.TooManyEntries;
            out.serials[out.len] = serial.body;
            out.len += 1;
        }
    }

    cert.verifyMessage(issuer, out.tbs, out.sig) catch return Error.BadSignature;
    return out;
}

// ---------------------------------------------------------------------------
// 测试：自己造一张 CRL（std 的 ECDSA 能生成密钥并签名），不依赖外部 fixture
// ---------------------------------------------------------------------------

const testing = std.testing;

fn derLen(n: usize, out: []u8) usize {
    if (n < 0x80) {
        out[0] = @intCast(n);
        return 1;
    }
    if (n < 0x100) {
        out[0] = 0x81;
        out[1] = @intCast(n);
        return 2;
    }
    out[0] = 0x82;
    out[1] = @intCast(n >> 8);
    out[2] = @intCast(n & 0xFF);
    return 3;
}

fn tlv(buf: []u8, tag: u8, body: []const u8) []const u8 {
    var len: [3]u8 = undefined;
    const n = derLen(body.len, &len);
    buf[0] = tag;
    @memcpy(buf[1..][0..n], len[0..n]);
    @memcpy(buf[1 + n ..][0..body.len], body);
    return buf[0 .. 1 + n + body.len];
}

/// 把一段 TLV 追加进 dst（不返回切片，避免测试里自别名）。
fn put(dst: []u8, pos: *usize, tag: u8, body: []const u8) void {
    var lenbuf: [3]u8 = undefined;
    const n = derLen(body.len, &lenbuf);
    dst[pos.*] = tag;
    pos.* += 1;
    @memcpy(dst[pos.*..][0..n], lenbuf[0..n]);
    pos.* += n;
    @memcpy(dst[pos.*..][0..body.len], body);
    pos.* += body.len;
}

const alg_der = [_]u8{ 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };

/// 造一张只含给定序列号的 CRL，并用 `kp` 签名。
fn makeCrl(buf: []u8, serials: []const []const u8, kp: anytype) ![]const u8 {
    // 每条吊销项：SEQUENCE { INTEGER serial, UTCTime }
    var rev_body: [256]u8 = undefined;
    var rpos: usize = 0;
    for (serials) |s| {
        var entry_body: [48]u8 = undefined;
        var epos: usize = 0;
        put(&entry_body, &epos, 0x02, s);
        put(&entry_body, &epos, 0x17, "260101000000Z");
        put(&rev_body, &rpos, 0x30, entry_body[0..epos]);
    }
    var rev_seq: [260]u8 = undefined;
    var rs: usize = 0;
    put(&rev_seq, &rs, 0x30, rev_body[0..rpos]);

    // tbsCertList：sigAlg / issuer(空 Name) / thisUpdate / revoked
    var tbs_body: [400]u8 = undefined;
    var bpos: usize = 0;
    put(&tbs_body, &bpos, 0x30, &alg_der);
    put(&tbs_body, &bpos, 0x30, "");
    put(&tbs_body, &bpos, 0x17, "260101000000Z");
    @memcpy(tbs_body[bpos..][0..rs], rev_seq[0..rs]);
    bpos += rs;

    var tbs_buf: [420]u8 = undefined;
    var tp: usize = 0;
    put(&tbs_buf, &tp, 0x30, tbs_body[0..bpos]);
    const tbs = tbs_buf[0..tp];

    const sig = try kp.sign(tbs, null);
    var der_buf: [std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&der_buf);

    var bits: [96]u8 = undefined;
    bits[0] = 0; // unused bits
    @memcpy(bits[1..][0..sig_der.len], sig_der);

    var outer_body: [560]u8 = undefined;
    var opos: usize = 0;
    @memcpy(outer_body[opos..][0..tbs.len], tbs);
    opos += tbs.len;
    put(&outer_body, &opos, 0x30, &alg_der);
    put(&outer_body, &opos, 0x03, bits[0 .. 1 + sig_der.len]);

    var op: usize = 0;
    put(buf, &op, 0x30, outer_body[0..opos]);
    return buf[0..op];
}

fn fakeIssuer(kp: anytype) cert.Cert {
    var c: cert.Cert = undefined;
    c.spki_point = &kp.public_key.toUncompressedSec1();
    return c;
}

test "crl: 吊销的序列号被命中，未吊销的不命中" {
    const kp = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generateDeterministic(@splat(7));
    var buf: [1024]u8 = undefined;
    const der = try makeCrl(&buf, &[_][]const u8{ &[_]u8{0x01}, &[_]u8{0x7F} }, kp);
    var issuer = fakeIssuer(kp);
    const c = try parse(der, &issuer);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expect(c.isRevoked(&[_]u8{0x01}));
    try testing.expect(c.isRevoked(&[_]u8{ 0x00, 0x7F })); // 前导 0 不影响
    try testing.expect(!c.isRevoked(&[_]u8{0x02}));
}

test "crl: 换一张证书验签必须失败（CRL 是签发者签的）" {
    const kp = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generateDeterministic(@splat(7));
    const other = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generateDeterministic(@splat(9));
    var buf: [1024]u8 = undefined;
    const der = try makeCrl(&buf, &[_][]const u8{&[_]u8{0x01}}, kp);
    var wrong = fakeIssuer(other);
    try testing.expectError(error.BadSignature, parse(der, &wrong));
}
