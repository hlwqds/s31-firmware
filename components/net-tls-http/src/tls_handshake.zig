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
const tls_keyschedule = @import("tls_keyschedule.zig");

pub const Error = error{
    BufferTooSmall,
    Truncated,
    NotServerHello,
    BadVersion,
    BadCompression,
    BadExtension,
    /// 服务端选了我们没实现的套件（只支持 TLS_AES_128_GCM_SHA256）。
    BadCipher,
    /// TLS 1.3 的 ServerHello 没有 key_share：意味着 HRR/PSK 等本实现不走的路径。
    MissingKeyShare,
    NotCertificate,
    TooManyCerts,
    NotCertificateVerify,
    NotFinished,
    BadFinishedLength,
    /// server_name 超过 255 字节（TLS 的 SNI 长度是 u16，但本实现只支持常见域名）。
    NameTooLong,
};

pub const handshake_type_client_hello: u8 = 0x01;
pub const handshake_type_server_hello: u8 = 0x02;

pub const cipher_tls_aes_128_gcm_sha256: u16 = 0x1301;
pub const group_x25519: u16 = 0x001d;
pub const sig_ecdsa_secp256r1_sha256: u16 = 0x0403;

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
    const sig_ext = 4 + 2 + 2; // 只通告 ECDSA P-256：cert.zig 只验得了这个
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
    put16(out[i + 2 ..], 4);
    i += 4;
    put16(out[i..], 2);
    i += 2;
    put16(out[i..], sig_ecdsa_secp256r1_sha256);
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
    try std.testing.expectEqual(@as(u16, 2), read16(sigs[0..2])); // 只通告 ECDSA P-256
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

// ---------------------------------------------------------------------------
// 转录（transcript）：握手消息的滚动 SHA-256
// ---------------------------------------------------------------------------

/// TLS 1.3 的密钥调度要的是“到目前为止所有握手消息”的哈希。这里用流式
/// `Sha256`，并允许 `snapshot()` 在任意点取当前值（ClientHello…ServerHello
/// 与 ClientHello…server Finished 是两个快照）。
pub const Transcript = struct {
    h: tls_keyschedule.Hash,

    pub fn init() Transcript {
        return .{ .h = tls_keyschedule.Hash.init(.{}) };
    }

    /// 只喂**握手消息本体**（含 4 字节 type+length），不含记录头。
    pub fn add(self: *Transcript, handshake_msg: []const u8) void {
        self.h.update(handshake_msg);
    }

    /// 当前转录哈希。`Sha256` 的流式状态可以复制，所以取快照不破坏后续累积。
    pub fn snapshot(self: Transcript) [tls_keyschedule.hash_length]u8 {
        var copy = self.h;
        var out: [tls_keyschedule.hash_length]u8 = undefined;
        copy.final(&out);
        return out;
    }
};

// ---------------------------------------------------------------------------
// ServerHello 解析（握手驱动只需这几项：random、套件、key_share）
// ---------------------------------------------------------------------------

pub const ServerHello = struct {
    random: [32]u8,
    cipher_suite: u16,
    /// 服务端 key_share（x25519）。**解析时强制存在**：TLS 1.3 的 ServerHello 若
    /// 没有 key_share，说明服务端走的是 HRR/PSK 等本实现不支持的路径——这种情况下
    /// 继续握手只会用空密钥派生出错东西，所以就地报错。
    key_share: [x25519.key_length]u8,
    /// TLS 1.3 必须在 supported_versions 里回 0x0304；缺省或别的值都说明对方不是 1.3。
    supported_version: u16,
};

/// 解析一条完整的 ServerHello 握手消息（含 type=2 + 3 字节长度）。
pub fn parseServerHello(msg: []const u8) Error!ServerHello {
    if (msg.len < 4 + 2 + 32 + 1) return Error.Truncated;
    if (msg[0] != handshake_type_server_hello) return Error.NotServerHello;
    const body_len = read24(msg[1..]);
    if (4 + body_len > msg.len) return Error.Truncated;
    var i: usize = 4;
    const end = 4 + body_len;

    const version = read16(msg[i..]);
    if (version != 0x0303) return Error.BadVersion;
    i += 2;

    // 带默认值初始化（`= undefined` 会把 `key_share`/`supported_version` 的 null 默认一起抹掉）
    var sh: ServerHello = .{ .random = undefined, .cipher_suite = 0, .key_share = undefined, .supported_version = 0 };
    @memcpy(&sh.random, msg[i..][0..32]);
    i += 32;

    const sid_len = msg[i];
    i += 1;
    if (i + sid_len + 2 + 1 > end) return Error.Truncated;
    i += sid_len;

    sh.cipher_suite = read16(msg[i..]);
    i += 2;

    const comp_len = msg[i];
    i += 1;
    if (comp_len != 1) return Error.BadCompression;
    i += 1; // 必须是 0（null）

    if (i + 2 > end) return Error.Truncated;
    const exts_len = read16(msg[i..]);
    i += 2;
    if (i + exts_len != end) return Error.Truncated;

    var have_version = false;
    var have_key_share = false;
    while (i < end) {
        if (i + 4 > end) return Error.Truncated;
        const id = read16(msg[i..]);
        const len = read16(msg[i + 2 ..]);
        i += 4;
        if (i + len > end) return Error.Truncated;
        const body = msg[i..][0..len];
        switch (id) {
            ext_supported_versions => {
                if (len != 2) return Error.BadExtension;
                sh.supported_version = read16(body);
                have_version = true;
            },
            ext_key_share => {
                if (len != 2 + 2 + x25519.key_length) return Error.BadExtension;
                if (read16(body[0..2]) != group_x25519) return Error.BadExtension;
                if (read16(body[2..4]) != x25519.key_length) return Error.BadExtension;
                @memcpy(&sh.key_share, body[4..][0..x25519.key_length]);
                have_key_share = true;
            },
            else => {},
        }
        i += len;
    }

    // 三处强制校验：都是"能解析但继续下去会用错密钥"的情形，必须在解析处就死。
    if (sh.cipher_suite != cipher_tls_aes_128_gcm_sha256) return Error.BadCipher;
    if (!have_version or sh.supported_version != 0x0304) return Error.BadVersion;
    if (!have_key_share) return Error.MissingKeyShare;
    return sh;
}

/// 测试用的 ServerHello 构造器：按线上格式手工拼，供解析器对拍。
fn buildServerHelloForTest(buf: []u8, random32: [32]u8, suite: u16, ks: [x25519.key_length]u8, with_version: bool) []u8 {
    var i: usize = 4;
    put16(buf[i..], 0x0303);
    i += 2;
    @memcpy(buf[i..][0..32], &random32);
    i += 32;
    buf[i] = 0; // session_id echo 长度
    i += 1;
    put16(buf[i..], suite);
    i += 2;
    buf[i] = 1; // 压缩方法数量
    i += 1;
    buf[i] = 0; // null
    i += 1;

    const exts_len_off = i;
    i += 2;
    const exts_start = i;

    // key_share
    put16(buf[i..], ext_key_share);
    put16(buf[i + 2 ..], 2 + 2 + x25519.key_length);
    i += 4;
    put16(buf[i..], group_x25519);
    put16(buf[i + 2 ..], x25519.key_length);
    i += 4;
    @memcpy(buf[i..][0..x25519.key_length], &ks);
    i += x25519.key_length;

    if (with_version) {
        put16(buf[i..], ext_supported_versions);
        put16(buf[i + 2 ..], 2);
        i += 4;
        put16(buf[i..], 0x0304);
        i += 2;
    }

    put16(buf[exts_len_off..], @intCast(i - exts_start));
    buf[0] = handshake_type_server_hello;
    put24(buf[1..], @intCast(i - 4));
    return buf[0..i];
}

test "handshake: ServerHello 解析出 random/套件/key_share/版本" {
    var buf: [256]u8 = undefined;
    var rand: [32]u8 = undefined;
    for (&rand, 0..) |*b, i| b.* = @intCast(i);
    const ks: [x25519.key_length]u8 = @splat(0x42);
    const msg = buildServerHelloForTest(&buf, rand, cipher_tls_aes_128_gcm_sha256, ks, true);

    const sh = try parseServerHello(msg);
    try std.testing.expectEqualSlices(u8, &rand, &sh.random);
    try std.testing.expectEqual(cipher_tls_aes_128_gcm_sha256, sh.cipher_suite);
    try std.testing.expectEqual(@as(u16, 0x0304), sh.supported_version);
    try std.testing.expectEqualSlices(u8, &ks, &sh.key_share);
}

test "handshake: 服务端选别的套件/版本缺失/key_share 缺失都是硬错" {
    var buf: [256]u8 = undefined;
    const rand: [32]u8 = @splat(7);
    const ks: [x25519.key_length]u8 = @splat(9);

    // 只支持 TLS_AES_128_GCM_SHA256：服务端选 AES-256-GCM-SHA384 必须当场报错，
    // 否则会用错误的密钥长度继续派生（下游表现为静默算错）。
    const wrong_suite = buildServerHelloForTest(&buf, rand, 0x1302, ks, true);
    try std.testing.expectError(Error.BadCipher, parseServerHello(wrong_suite));

    // 没有 supported_versions ⇒ 对方不是 TLS 1.3
    const wrong_version = buildServerHelloForTest(&buf, rand, cipher_tls_aes_128_gcm_sha256, ks, false);
    try std.testing.expectError(Error.BadVersion, parseServerHello(wrong_version));
}

test "handshake: 去掉 key_share 扩展时返回 MissingKeyShare" {
    // 手工构造一条合法 SH，再去掉 key_share 扩展（只留 supported_versions）。
    var buf: [256]u8 = undefined;
    const rand: [32]u8 = @splat(3);
    var i: usize = 4;
    put16(buf[i..], 0x0303);
    i += 2;
    @memcpy(buf[i..][0..32], &rand);
    i += 32;
    buf[i] = 0;
    i += 1;
    put16(buf[i..], cipher_tls_aes_128_gcm_sha256);
    i += 2;
    buf[i] = 1;
    i += 1;
    buf[i] = 0;
    i += 1;
    const exts_len_off = i;
    i += 2;
    const exts_start = i;
    put16(buf[i..], ext_supported_versions);
    put16(buf[i + 2 ..], 2);
    i += 4;
    put16(buf[i..], 0x0304);
    i += 2;
    put16(buf[exts_len_off..], @intCast(i - exts_start));
    buf[0] = handshake_type_server_hello;
    put24(buf[1..], @intCast(i - 4));

    try std.testing.expectError(Error.MissingKeyShare, parseServerHello(buf[0..i]));
}

test "handshake: 错类型与截断各自报错（截断先报 Truncated 再谈内容）" {
    var buf: [256]u8 = undefined;
    const rand: [32]u8 = @splat(5);
    const ks: [x25519.key_length]u8 = @splat(6);
    const msg = buildServerHelloForTest(&buf, rand, cipher_tls_aes_128_gcm_sha256, ks, true);

    var wrong_buf: [256]u8 = undefined;
    @memcpy(wrong_buf[0..msg.len], msg);
    wrong_buf[0] = handshake_type_client_hello;
    try std.testing.expectError(Error.NotServerHello, parseServerHello(wrong_buf[0..msg.len]));

    var trunc_buf: [256]u8 = undefined;
    @memcpy(trunc_buf[0..msg.len], msg);
    put24(trunc_buf[1..], @intCast(msg.len));
    try std.testing.expectError(Error.Truncated, parseServerHello(trunc_buf[0 .. msg.len - 1]));

    // 空/过短缓冲：长度检查在读取 msg[0] 之前
    try std.testing.expectError(Error.Truncated, parseServerHello(&[_]u8{}));
    try std.testing.expectError(Error.Truncated, parseServerHello(&[_]u8{ 1, 2, 3 }));
}

test "handshake: 转录快照等于一次性 SHA-256（流式与整体一致）" {
    var tr = Transcript.init();
    const a = "first-handshake-message";
    const b = "second-handshake-message";
    tr.add(a);
    const mid = tr.snapshot();
    tr.add(b);
    const done = tr.snapshot();

    try std.testing.expectEqualSlices(u8, &tls_keyschedule.hash(a), &mid);
    const concat = a ++ b;
    try std.testing.expectEqualSlices(u8, &tls_keyschedule.hash(concat), &done);
    try std.testing.expect(!std.mem.eql(u8, &mid, &done));
}

test "handshake: 从解析出的 key_share 走 ECDHE + buildSchedule 的形状" {
    // 双方各取一个标量，交叉算出同一个共享秘密；再用转录快照喂 buildSchedule。
    const client_secret: [32]u8 = @splat(0x11);
    const server_secret: [32]u8 = @splat(0x22);
    const server_pub = x25519.publicKey(server_secret);
    const client_pub = x25519.publicKey(client_secret);
    const s1 = try x25519.scalarmult(client_secret, server_pub);
    const s2 = try x25519.scalarmult(server_secret, client_pub);
    try std.testing.expectEqualSlices(u8, &s1, &s2);

    var tr = Transcript.init();
    tr.add("CH->SH");
    const hs_hash = tr.snapshot();
    const sched = try tls_keyschedule.buildSchedule(&s1, &hs_hash, &hs_hash);
    // 只验形状：两条 traffic secret 不同、且非零
    try std.testing.expect(!std.mem.eql(u8, &sched.client_hs_traffic, &sched.server_hs_traffic));
    try std.testing.expect(!std.mem.allEqual(u8, &sched.client_hs_traffic, 0));
}

// ---------------------------------------------------------------------------
// ServerHello 之后的三条消息 + Finished
// ---------------------------------------------------------------------------

pub const handshake_type_encrypted_extensions: u8 = 0x08;
pub const handshake_type_certificate: u8 = 0x0b;
pub const handshake_type_certificate_verify: u8 = 0x0f;
pub const handshake_type_finished: u8 = 0x14;

const cv_context_server = "TLS 1.3, server CertificateVerify";

/// Certificate 消息里的一张证书（DER 切片，指向原缓冲）。
pub const CertEntry = struct { der: []const u8 };

/// Certificate（type 11）：`certificate_request_context` + 证书列表。
/// 返回的切片都指向 `msg`，不复制。
pub fn parseCertificate(msg: []const u8, out: *[max_certs]CertEntry) Error![]CertEntry {
    if (msg.len < 4) return Error.Truncated;
    if (msg[0] != handshake_type_certificate) return Error.NotCertificate;
    const body_len = read24(msg[1..]);
    if (4 + body_len > msg.len) return Error.Truncated;
    var i: usize = 4;
    const end = 4 + body_len;

    if (i + 1 > end) return Error.Truncated;
    const ctx_len = msg[i];
    i += 1;
    if (i + ctx_len > end) return Error.Truncated;
    i += ctx_len;

    if (i + 3 > end) return Error.Truncated;
    const list_len = read24(msg[i..]);
    i += 3;
    if (i + list_len != end) return Error.Truncated;

    var n: usize = 0;
    while (i < end) {
        if (i + 3 > end) return Error.Truncated;
        const clen = read24(msg[i..]);
        i += 3;
        if (i + clen > end) return Error.Truncated;
        if (n == out.len) return Error.TooManyCerts;
        out[n] = .{ .der = msg[i..][0..clen] };
        n += 1;
        i += clen;
    }
    return out[0..n];
}

pub const max_certs = 4;

/// CertificateVerify（type 15）：签名算法 + 签名。
pub const CertificateVerify = struct {
    scheme: u16,
    signature: []const u8,
};

pub fn parseCertificateVerify(msg: []const u8) Error!CertificateVerify {
    if (msg.len < 4 + 2 + 2) return Error.Truncated;
    if (msg[0] != handshake_type_certificate_verify) return Error.NotCertificateVerify;
    const body_len = read24(msg[1..]);
    if (4 + body_len > msg.len) return Error.Truncated;
    const scheme = read16(msg[4..]);
    const sig_len = read16(msg[6..]);
    if (8 + sig_len != 4 + body_len) return Error.Truncated;
    return .{ .scheme = scheme, .signature = msg[8..][0..sig_len] };
}

/// CertificateVerify 的签名内容（RFC 8446 §4.4.3）：
/// 64 个空格 ‖ 上下文串 ‖ 0x00 ‖ 转录哈希。
pub fn certificateVerifyContent(buf: []u8, transcript_hash: [tls_keyschedule.hash_length]u8) ![]const u8 {
    const need = 64 + cv_context_server.len + 1 + transcript_hash.len;
    if (buf.len < need) return Error.BufferTooSmall;
    @memset(buf[0..64], 0x20);
    var i: usize = 64;
    @memcpy(buf[i..][0..cv_context_server.len], cv_context_server);
    i += cv_context_server.len;
    buf[i] = 0;
    i += 1;
    @memcpy(buf[i..][0..transcript_hash.len], &transcript_hash);
    i += transcript_hash.len;
    return buf[0..i];
}

/// Finished（type 20）：32 字节 verify_data。
pub fn parseFinished(msg: []const u8) Error![tls_keyschedule.hash_length]u8 {
    if (msg.len < 4 + tls_keyschedule.hash_length) return Error.Truncated;
    if (msg[0] != handshake_type_finished) return Error.NotFinished;
    const body_len = read24(msg[1..]);
    if (body_len != tls_keyschedule.hash_length) return Error.BadFinishedLength;
    var out: [tls_keyschedule.hash_length]u8 = undefined;
    @memcpy(&out, msg[4..][0..tls_keyschedule.hash_length]);
    return out;
}

/// 验服务端 Finished：用 `server_hs_traffic` 与**收到 Finished 之前**的转录哈希算期望值。
pub fn verifyFinished(
    server_hs_traffic: [tls_keyschedule.hash_length]u8,
    transcript_hash: [tls_keyschedule.hash_length]u8,
    received: [tls_keyschedule.hash_length]u8,
) bool {
    const expect = tls_keyschedule.finishedVerifyData(server_hs_traffic, &transcript_hash);
    // 常数时间比较：verify_data 是可被逐字节试探的认证值。
    var diff: u8 = 0;
    for (expect, received) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// 服务端飞行（ServerHello 之后的消息）的顺序状态机。
///
/// TLS 1.3 的顺序是**强制**的：EE → Certificate → CertificateVerify → Finished
/// （PSK 模式可能跳过 Cert/CV，但本实现不支持，所以按严格顺序推进）。
/// 顺序错就直接失败——这条消息流是认证链的一部分，顺序被改写等同于攻击。
pub const Flight = struct {
    state: State = .expect_encrypted_extensions,
    transcript: Transcript,

    pub const State = enum {
        expect_encrypted_extensions,
        expect_certificate,
        expect_certificate_verify,
        expect_finished,
        done,
    };

    pub const Error = error{ UnexpectedMessage, BadFinished, NotEncryptedExtensions };

    pub fn init() Flight {
        return .{ .transcript = Transcript.init() };
    }

    pub fn expect(self: *Flight, st: State) bool {
        return self.state == st;
    }
};

/// 推进一步飞行状态；`msg` 是完整的握手消息（含 4 字节头）。
/// 成功时把消息计入转录并前进状态；Finished 由调用方用 `verifyFinished` 校验，
/// 因为密钥取决于 schedule（本函数不持有密钥）。
pub fn advanceFlight(f: *Flight, msg: []const u8, server_hs_traffic: [tls_keyschedule.hash_length]u8) Flight.Error!void {
    const t = msg[0];
    switch (f.state) {
        .expect_encrypted_extensions => {
            if (t != handshake_type_encrypted_extensions) return Flight.Error.UnexpectedMessage;
            f.transcript.add(msg);
            f.state = .expect_certificate;
        },
        .expect_certificate => {
            if (t != handshake_type_certificate) return Flight.Error.UnexpectedMessage;
            f.transcript.add(msg);
            f.state = .expect_certificate_verify;
        },
        .expect_certificate_verify => {
            if (t != handshake_type_certificate_verify) return Flight.Error.UnexpectedMessage;
            f.transcript.add(msg);
            f.state = .expect_finished;
        },
        .expect_finished => {
            if (t != handshake_type_finished) return Flight.Error.UnexpectedMessage;
            // RFC 8446 §4.4.4：服务端 verify_data 覆盖的是**收到 Finished 之前**的转录
            // （CH…CertificateVerify）。所以先取快照并验，再把 Finished 计入转录——
            // 顺序反了就是那句经典的"密钥调度对不上"。
            const before = f.transcript.snapshot();
            const received = parseFinished(msg) catch return Flight.Error.UnexpectedMessage;
            if (!verifyFinished(server_hs_traffic, before, received)) return Flight.Error.BadFinished;
            f.transcript.add(msg); // 客户端 Finished 的转录从这里往后算
            f.state = .done;
        },
        .done => return Flight.Error.UnexpectedMessage,
    }
}

// ---------------------------------------------------------------------------
// 飞行状态机的用例（用合成消息，不依赖真实服务器）
// ---------------------------------------------------------------------------

fn hsMsg(buf: []u8, typ: u8, body: []const u8) []const u8 {
    buf[0] = typ;
    put24(buf[1..], @intCast(body.len));
    @memcpy(buf[4..][0..body.len], body);
    return buf[0 .. 4 + body.len];
}

test "flight: 顺序 EE → Certificate → CertificateVerify → Finished，错序即失败" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    var c: [512]u8 = undefined;
    var d: [256]u8 = undefined;

    const ee = hsMsg(&a, handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    var cert_body: [16]u8 = undefined;
    cert_body[0] = 0; // request context 长度
    put24(cert_body[1..], 3 + 2);
    put24(cert_body[4..], 2);
    @memcpy(cert_body[7..][0..2], "DE");
    const cert = hsMsg(&b, handshake_type_certificate, &cert_body);
    const cv = hsMsg(&c, handshake_type_certificate_verify, &[_]u8{ 0x04, 0x03, 0x00, 0x01, 0xEE });
    var fin_body: [32]u8 = @splat(0x5A);
    const fin = hsMsg(&d, handshake_type_finished, &fin_body);

    const traffic: [tls_keyschedule.hash_length]u8 = @splat(0x33);

    var f = Flight.init();
    // 正确顺序：Finished 必须通过验证才算完成，所以要按真实边界算 verify_data
    try advanceFlight(&f, ee, traffic);
    try std.testing.expect(f.expect(.expect_certificate));
    try advanceFlight(&f, cert, traffic);
    try std.testing.expect(f.expect(.expect_certificate_verify));
    try advanceFlight(&f, cv, traffic);
    try std.testing.expect(f.expect(.expect_finished));

    // 服务端 Finished 覆盖的是**收到它之前**的转录（CH…CV），这里正是 Flight 自己算出来的
    const before_fin = f.transcript.snapshot();
    const good = tls_keyschedule.finishedVerifyData(traffic, &before_fin);
    var good_msg_buf: [40]u8 = undefined;
    const good_fin = hsMsg(&good_msg_buf, handshake_type_finished, &good);
    try advanceFlight(&f, good_fin, traffic);
    try std.testing.expect(f.expect(.done));

    // 伪造的 verify_data 必须被拒（曾经这里只计入转录、不校验）
    var g = Flight.init();
    try advanceFlight(&g, ee, traffic);
    try advanceFlight(&g, cert, traffic);
    try advanceFlight(&g, cv, traffic);
    try std.testing.expectError(Flight.Error.BadFinished, advanceFlight(&g, fin, traffic));

    // 错序：Finished 先到
    var h = Flight.init();
    try std.testing.expectError(Flight.Error.UnexpectedMessage, advanceFlight(&h, fin, traffic));
    // 错序：CV 在 Certificate 之前
    var k = Flight.init();
    try advanceFlight(&k, ee, traffic);
    try std.testing.expectError(Flight.Error.UnexpectedMessage, advanceFlight(&k, cv, traffic));
}

test "flight: Certificate 列表逐张切出 DER，bin/长度不符即报错" {
    var buf: [512]u8 = undefined;
    var body: [32]u8 = undefined;
    body[0] = 0;
    put24(body[1..], 11); // 两条目：3+2 + 3+3
    put24(body[4..], 2);
    @memcpy(body[7..][0..2], "AA");
    put24(body[9..], 3);
    @memcpy(body[12..][0..3], "BBB");
    const msg = hsMsg(&buf, handshake_type_certificate, body[0..15]);

    var entries: [max_certs]CertEntry = undefined;
    const list = try parseCertificate(msg, &entries);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("AA", list[0].der);
    try std.testing.expectEqualStrings("BBB", list[1].der);

    // 列表长度与内容不符
    var bad: [512]u8 = undefined;
    @memcpy(bad[0..msg.len], msg);
    put24(bad[5..], 999);
    try std.testing.expectError(Error.Truncated, parseCertificate(bad[0..msg.len], &entries));
}

test "flight: CertificateVerify 的签名内容 = 64 空格 + 上下文 + 0x00 + 转录哈希" {
    var buf: [256]u8 = undefined;
    const th: [32]u8 = @splat(0xAB);
    const content = try certificateVerifyContent(&buf, th);
    try std.testing.expectEqual(@as(usize, 64 + cv_context_server.len + 1 + 32), content.len);
    try std.testing.expect(std.mem.allEqual(u8, content[0..64], 0x20));
    try std.testing.expectEqualStrings(cv_context_server, content[64..][0..cv_context_server.len]);
    try std.testing.expectEqual(@as(u8, 0), content[64 + cv_context_server.len]);
    try std.testing.expectEqualSlices(u8, &th, content[65 + cv_context_server.len ..]);
}

test "flight: Finished 长度错误与 verify_data 不匹配" {
    var buf: [64]u8 = undefined;
    // 长度字段写 33（≠ 32）：缓冲够长，所以必须报 BadFinishedLength 而不是 Truncated
    var body: [33]u8 = @splat(1);
    const wrong_len = hsMsg(&buf, handshake_type_finished, &body);
    try std.testing.expectError(Error.BadFinishedLength, parseFinished(wrong_len));

    const secret: [32]u8 = @splat(0x11);
    const th: [32]u8 = @splat(0x22);
    const good = tls_keyschedule.finishedVerifyData(secret, &th);
    try std.testing.expect(verifyFinished(secret, th, good));

    var tampered = good;
    tampered[0] ^= 0x01;
    try std.testing.expect(!verifyFinished(secret, th, tampered));
    // 转录变了，旧 verify_data 立刻失效
    var th2 = th;
    th2[31] ^= 0x80;
    try std.testing.expect(!verifyFinished(secret, th2, good));
}
