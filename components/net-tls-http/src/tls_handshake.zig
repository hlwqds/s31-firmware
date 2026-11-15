//! net-tls-http：TLS 1.3 ClientHello 的编码（本章只做到"把首包写对"）。
//!
//! 为什么单独一层：ClientHello 是唯一一个**还没拿到任何密钥**就必须逐字节正确的
//! 报文——长度前缀套三层（记录 → 握手 → 扩展），任何一处算错，服务端只会回
//! `decode_error` 或直接断开，而板侧日志看起来"发出去了"。
//!
//! 编码的所有输入都是显式的（随机数、私钥、SNI），本模块**不读时钟、不取熵、
//! 不发包**：
//!
//! ```text
//! writeClientHello(out, params)  → 握手消息（type=1 + 3 字节长度）
//! writeClientHelloRecord(out, p) → 记录（type=0x16 + 版本 + 长度）+ 握手消息
//! ```
//!
//! 随机数来自 `random.Reader`（接缝在 `random.zig`）；私钥来自调用方。
//! 生产路径必须用 `Reader.cryptographicallySecure() == true` 的来源，否则
//! 握手在密码学上不成立。
const std = @import("std");
const record = @import("tls_record.zig");
const x25519 = @import("x25519.zig");
const random = @import("random.zig");

pub const Error = error{
    BufferTooSmall,
    /// server_name 超过 255 字节（TLS 的 SNI 长度是 u16，但本实现只支持常见域名）。
    NameTooLong,
};

pub const handshake_type_client_hello: u8 = 0x01;

pub const cipher_tls_aes_128_gcm_sha256: u16 = 0x1301;
pub const group_x25519: u16 = 0x001d;
pub const sig_ecdsa_secp256r1_sha256: u16 = 0x0403;
pub const sig_rsa_pss_rsae_sha256: u16 = 0x0804;

const ext_server_name: u16 = 0x0000;
const ext_supported_groups: u16 = 0x000a;
const ext_signature_algorithms: u16 = 0x000d;
const ext_supported_versions: u16 = 0x002b;
const ext_key_share: u16 = 0x0033;

pub const Params = struct {
    /// SNI（必须是非空域名；IP 地址不能进 SNI）。
    server_name: []const u8,
    /// X25519 私钥（32 字节，调用方从 `random.Reader` 取）。
    secret: [x25519.scalar_length]u8,
};

fn put16(out: []u8, v: u16) void {
    std.mem.writeInt(u16, out[0..2], v, .big);
}

fn put24(out: []u8, v: u32) void {
    out[0] = @intCast((v >> 16) & 0xff);
    out[1] = @intCast((v >> 8) & 0xff);
    out[2] = @intCast(v & 0xff);
}

/// 写握手消息，返回字节数。`rng` 只用来取 32 字节 `random`。
pub fn writeClientHello(out: []u8, p: Params, rng: random.Reader) Error!usize {
    if (p.server_name.len > 255) return Error.NameTooLong;

    // 先按最坏长度检查，避免写到一半才发现不够（调用方可能直接发缓冲）。
    const name_entry = 1 + 2 + p.server_name.len;
    const sni_ext = 4 + 2 + name_entry;
    const ver_ext = 4 + 1 + 2;
    const groups_ext = 4 + 2 + 2;
    const sig_ext = 4 + 2 + 4;
    const ks_ext = 4 + 2 + 2 + 2 + x25519.key_length;
    const exts_len = sni_ext + ver_ext + groups_ext + sig_ext + ks_ext;
    const body_len = 2 + 32 + 1 + 2 + 2 + 1 + 1 + 2 + exts_len;
    const total = 4 + body_len;
    if (out.len < total) return Error.BufferTooSmall;

    var i: usize = 0;
    out[i] = handshake_type_client_hello;
    put24(out[i + 1 ..], @intCast(body_len));
    i += 4;

    put16(out[i..], 0x0303); // legacy_version：TLS 1.3 在记录层伪装成 1.2
    i += 2;

    rng.fill(out[i..][0..32]);
    i += 32;

    out[i] = 0; // legacy_session_id：TLS 1.3 兼容模式不需要
    i += 1;

    put16(out[i..], 2);
    i += 2;
    put16(out[i..], cipher_tls_aes_128_gcm_sha256);
    i += 2;

    out[i] = 1; // legacy_compression_methods
    i += 1;
    out[i] = 0; // null
    i += 1;

    put16(out[i..], @intCast(exts_len));
    i += 2;

    // 0x0000 server_name
    put16(out[i..], ext_server_name);
    put16(out[i + 2 ..], @intCast(2 + name_entry));
    i += 4;
    put16(out[i..], @intCast(name_entry));
    i += 2;
    out[i] = 0; // host_name
    i += 1;
    put16(out[i..], @intCast(p.server_name.len));
    i += 2;
    @memcpy(out[i..][0..p.server_name.len], p.server_name);
    i += p.server_name.len;

    // 0x002b supported_versions
    put16(out[i..], ext_supported_versions);
    put16(out[i + 2 ..], 3);
    i += 4;
    out[i] = 2; // 列表长度
    i += 1;
    put16(out[i..], 0x0304); // TLS 1.3
    i += 2;

    // 0x000a supported_groups
    put16(out[i..], ext_supported_groups);
    put16(out[i + 2 ..], 4);
    i += 4;
    put16(out[i..], 2);
    i += 2;
    put16(out[i..], group_x25519);
    i += 2;

    // 0x000d signature_algorithms
    put16(out[i..], ext_signature_algorithms);
    put16(out[i + 2 ..], 6);
    i += 4;
    put16(out[i..], 4);
    i += 2;
    put16(out[i..], sig_ecdsa_secp256r1_sha256);
    i += 2;
    put16(out[i..], sig_rsa_pss_rsae_sha256);
    i += 2;

    // 0x0033 key_share（一个 x25519 share）
    const pubkey = x25519.publicKey(p.secret);
    put16(out[i..], ext_key_share);
    put16(out[i + 2 ..], @intCast(2 + 2 + 2 + x25519.key_length));
    i += 4;
    put16(out[i..], @intCast(2 + 2 + x25519.key_length));
    i += 2;
    put16(out[i..], group_x25519);
    i += 2;
    put16(out[i..], x25519.key_length);
    i += 2;
    @memcpy(out[i..][0..x25519.key_length], &pubkey);
    i += x25519.key_length;

    std.debug.assert(i == total);
    return i;
}

/// 把握手消息包进 TLS 记录（`content_type = handshake(22)`）。
pub fn writeClientHelloRecord(out: []u8, p: Params, rng: random.Reader) Error!usize {
    const hs_len = try writeClientHello(out[record.header_len..], p, rng);
    record.writeHeader(out[0..record.header_len], .handshake, hs_len) catch return Error.BufferTooSmall;
    // RFC 8446 §5.1：ClientHello 的**记录层** legacy_version 用 0x0301（TLS 1.0），
    // 握手体内的 legacy_version 才是 0x0303。`writeHeader` 是通用件，写的是 0x0303，
    // 这里按 RFC 覆盖这两个字节——顺序反了服务端会直接断开，而板侧日志看着"发出去了"。
    put16(out[1..], 0x0301);
    return record.header_len + hs_len;
}

// ---------------------------------------------------------------------------
// 用例：结构逐字段对拍 + 可复现性 + 边界
// ---------------------------------------------------------------------------

const test_secret: [x25519.scalar_length]u8 = @splat(0x77);

/// 测试用确定性流（与 `random.zig` 的用例同构；生产模块不导出它）。
const TestStream = struct {
    state: u64 = 0,
    fn fillFn(ctx: ?*anyopaque, out: []u8) void {
        const self: *TestStream = @ptrCast(@alignCast(ctx.?));
        var i: usize = 0;
        while (i < out.len) {
            self.state +%= 0x9E37_79B9_7F4A_7C15;
            var z = self.state;
            z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
            z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
            z ^= z >> 31;
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, z, .little);
            const n = @min(8, out.len - i);
            @memcpy(out[i..][0..n], buf[0..n]);
            i += n;
        }
    }
    fn reader(self: *TestStream) random.Reader {
        return .{ .ctx = self, .fillFn = fillFn, .secure = false };
    }
};

fn read16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}

fn read24(b: []const u8) u32 {
    return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
}

/// 按 TLS 的三层长度把扩展走一遍，返回下一个扩展的偏移（找不到就断言失败）。
fn findExt(buf: []const u8, exts_off: usize, exts_len: usize, want: u16) []const u8 {
    var i = exts_off;
    while (i < exts_off + exts_len) {
        const id = read16(buf[i..]);
        const len = read16(buf[i + 2 ..]);
        if (id == want) return buf[i + 4 ..][0..len];
        i += 4 + len;
    }
    std.debug.panic("extension 0x{x:0>4} not found", .{want});
}

test "handshake: ClientHello 的三层长度与扩展逐字段自洽" {
    var rng = TestStream{ .state = 0x2026_0301 };
    var buf: [512]u8 = undefined;
    const p = Params{ .server_name = "example.test", .secret = test_secret };
    const n = try writeClientHelloRecord(&buf, p, rng.reader());

    // 记录层
    try std.testing.expectEqual(@as(u8, 22), buf[0]); // handshake
    try std.testing.expectEqual(@as(u16, 0x0301), read16(buf[1..]));
    try std.testing.expectEqual(@as(usize, n), @as(usize, record.header_len) + read16(buf[3..]));

    // 握手层
    const hs = buf[record.header_len..n];
    try std.testing.expectEqual(handshake_type_client_hello, hs[0]);
    try std.testing.expectEqual(@as(u32, @intCast(hs.len - 4)), read24(hs[1..]));
    try std.testing.expectEqual(@as(u16, 0x0303), read16(hs[4..])); // legacy_version
    try std.testing.expectEqual(@as(u8, 0), hs[6 + 32]); // session_id 长度
    try std.testing.expectEqual(@as(u16, 2), read16(hs[7 + 32 ..]));
    try std.testing.expectEqual(cipher_tls_aes_128_gcm_sha256, read16(hs[9 + 32 ..]));

    // 扩展
    // 4(type+len) + 2(legacy_version) + 32(random) + 1(session_id) + 2+2(套件)
    // + 1+1(压缩) = 45 → 扩展总长的 2 字节在 45，扩展从 47 开始
    const exts_len_off = 4 + 2 + 32 + 1 + 2 + 2 + 1 + 1;
    const exts_off = exts_len_off + 2;
    const exts_len = read16(hs[exts_len_off..]);
    try std.testing.expectEqual(@as(usize, hs.len - exts_off), @as(usize, exts_len));

    const ver = findExt(hs, exts_off, exts_len, ext_supported_versions);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 0x03, 0x04 }, ver);

    const groups = findExt(hs, exts_off, exts_len, ext_supported_groups);
    try std.testing.expectEqual(@as(u16, group_x25519), read16(groups[2..]));

    const sigs = findExt(hs, exts_off, exts_len, ext_signature_algorithms);
    try std.testing.expectEqual(@as(u16, 4), read16(sigs[0..2]));
    try std.testing.expectEqual(sig_ecdsa_secp256r1_sha256, read16(sigs[2..]));

    const ks = findExt(hs, exts_off, exts_len, ext_key_share);
    try std.testing.expectEqual(group_x25519, read16(ks[2..]));
    try std.testing.expectEqual(@as(u16, x25519.key_length), read16(ks[4..]));
    const expected_pub = x25519.publicKey(test_secret);
    try std.testing.expectEqualSlices(u8, &expected_pub, ks[6..][0..x25519.key_length]);

    const sni = findExt(hs, exts_off, exts_len, ext_server_name);
    try std.testing.expectEqual(@as(u8, 0), sni[2]); // host_name
    try std.testing.expectEqualStrings("example.test", sni[5..]);
}

test "handshake: 同一个随机流生成的首包逐字节相同（板侧日志可复现）" {
    var a = TestStream{ .state = 42 };
    var b = TestStream{ .state = 42 };
    var x: [512]u8 = undefined;
    var y: [512]u8 = undefined;
    const p = Params{ .server_name = "a.test", .secret = test_secret };
    const nx = try writeClientHelloRecord(&x, p, a.reader());
    const ny = try writeClientHelloRecord(&y, p, b.reader());
    try std.testing.expectEqual(nx, ny);
    try std.testing.expectEqualSlices(u8, x[0..nx], y[0..ny]);
}

test "handshake: 随机数确实进了 random 字段（换 seed 变、同 seed 同）" {
    const p = Params{ .server_name = "a.test", .secret = test_secret };
    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;
    var r1 = TestStream{ .state = 1 };
    var r2 = TestStream{ .state = 1 };
    var r3 = TestStream{ .state = 2 };
    const a = try writeClientHelloRecord(&buf_a, p, r1.reader());
    _ = try writeClientHelloRecord(&buf_b, p, r2.reader());
    try std.testing.expectEqualSlices(u8, buf_a[6..38], buf_b[6..38]); // random 相同
    _ = try writeClientHelloRecord(&buf_b, p, r3.reader());
    try std.testing.expect(!std.mem.eql(u8, buf_a[6..38], buf_b[6..38]));
    try std.testing.expect(a > 0);
}

test "handshake: 缓冲不足与过长的 SNI 都显式报错" {
    var rng = TestStream{ .state = 3 };
    var small: [64]u8 = undefined;
    const p = Params{ .server_name = "a.test", .secret = test_secret };
    try std.testing.expectError(Error.BufferTooSmall, writeClientHello(&small, p, rng.reader()));

    var big: [1024]u8 = undefined;
    var long_name: [256]u8 = undefined;
    @memset(&long_name, 'x');
    try std.testing.expectError(Error.NameTooLong, writeClientHello(&big, .{ .server_name = &long_name, .secret = test_secret }, rng.reader()));
}
