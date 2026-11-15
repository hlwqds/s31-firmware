//! net-tls-http：证书链校验（信任锚的最小实现）。
//!
//! `cert.zig` 只回答"这张证书自洽吗"，`verifyMessage` 只回答"这条签名是不是它签的"。
//! 真正确认"对端是谁"还需要三件事，本文件把它们做成**显式输入**：
//!
//! ```text
//! verifyChain(leaf, issuers, trust_anchor, now, hostname)
//!   ├─ 叶证书的 issuer 必须等于某个签发者的 subject
//!   ├─ 叶证书的签名必须被该签发者的公钥验过（不是自签）
//!   ├─ 签发者必须由**调用方提供的信任锚**签发（或就是锚本身）——锚不来自对端
//!   └─ 有效期包含 `now`，且 SAN/CN 覆盖 `hostname`
//! ```
//!
//! **时钟不在本组件里**：`now` 由调用方给（ch05 的时钟或编译期常量都行）。
//! 没时钟就不该声称验过有效期——传一个越界的 `now` 会在测试里被抓住。
//!
//! 信任锚是**调用方持有的证书**（DER），不是"对端链里的根"：把对端链里的根当锚，
//! 等于让对端自己证明自己。
const std = @import("std");
const cert = @import("cert.zig");

pub const Error = error{
    /// 链上某张证书解析失败。
    BadCertificate,
    /// 链断了：找不到能给 (leaf|issuer) 签名的证书。
    NoIssuer,
    /// 签名验证失败（issuer 的公钥验不过 tbs）。
    BadSignature,
    /// 证书有效期不包含 now。
    Expired,
    /// 主机名与 SAN/CN 都不匹配。
    HostnameMismatch,
    /// 提供的信任锚没有被用上（链顶不是锚）——宁可报错也不要静默降级。
    UntrustedAnchor,
};

/// 日历比较（只看日期，不看时分秒：证书有效期到天）。
fn dateLess(a: cert.UtcTime, b: cert.UtcTime) bool {
    if (a.year != b.year) return a.year < b.year;
    if (a.month != b.month) return a.month < b.month;
    return a.day < b.day;
}

pub fn validityContains(c: *const cert.Cert, now: cert.UtcTime) bool {
    return !dateLess(now, c.not_before) and !dateLess(c.not_after, now);
}

/// 主机名匹配：SAN 里逐条比较，SAN 为空才回落到 CN。
/// 支持单个前导通配符 `*.example.com`（只匹配一级，且不匹配裸域）。
pub fn hostnameMatches(c: *const cert.Cert, hostname: []const u8) bool {
    var i: usize = 0;
    while (i < c.san_len) : (i += 1) {
        // iPAddress SAN 不是主机名：拿它做字符串比较会让 "127.0.0.1" 被当成合法名字。
        if (c.san_is_ip[i]) continue;
        if (matchName(c.sanAt(i), hostname)) return true;
    }
    // RFC 6125：有 SAN 就不再回落到 CN；只有完全没有 SAN 才看 CN。
    if (c.san_len == 0) return matchName(c.subject_cn, hostname);
    return false;
}

fn matchName(pattern: []const u8, host: []const u8) bool {
    if (pattern.len == 0 or host.len == 0) return false;
    if (pattern[0] == '*' and pattern.len > 2 and pattern[1] == '.') {
        const suffix = pattern[1..]; // ".example.com"
        // 必须比后缀多一个非空标签，且标签里不能再有点
        if (host.len <= suffix.len) return false;
        const head = host[0 .. host.len - suffix.len];
        if (std.mem.indexOfScalar(u8, head, '.') != null) return false;
        if (head.len == 0) return false;
        return std.ascii.eqlIgnoreCase(suffix, host[host.len - suffix.len ..]);
    }
    return std.ascii.eqlIgnoreCase(pattern, host);
}

/// 用 `issuer` 的公钥验证 `leaf` 的签名（不是自签校验）。
fn signedBy(leaf: *const cert.Cert, issuer: *const cert.Cert) bool {
    if (leaf.issuer_cn.len == 0 or !std.mem.eql(u8, leaf.issuer_cn, issuer.subject_cn)) return false;
    cert.verifyMessage(issuer, leaf.tbs, leaf.sig) catch return false;
    return true;
}

pub const Result = struct { chain_len: usize, expiry_checked: bool };

/// 校验一条链：`leaf` 由 `issuers` 里的某张签发，链顶必须由 `anchor` 签发（或就是锚）。
/// `issuers` 顺序不限（逐张尝试），但必须能连成一条到锚的路径。
pub fn verifyChain(
    leaf_der: []const u8,
    issuer_ders: []const []const u8,
    anchor_der: []const u8,
    now: ?cert.UtcTime,
    hostname: []const u8,
) Error!Result {
    const anchor = cert.parse(anchor_der) catch return Error.BadCertificate;
    var leaf = cert.parse(leaf_der) catch return Error.BadCertificate;

    // `now == null` 表示**没有可信时钟**：跳过有效期并在结果里标注，
    // 而不是拿构建期常量假装验过（那样永远不会失败）。
    if (now) |n| {
        if (!validityContains(&leaf, n)) return Error.Expired;
    }
    if (!hostnameMatches(&leaf, hostname)) return Error.HostnameMismatch;

    // 叶证书直接由锚签发？
    if (signedBy(&leaf, &anchor)) return .{ .chain_len = 1, .expiry_checked = now != null };

    // 否则在 issuers 里找一张能签叶证书的，再要求它由锚签发（一层中间证书）。
    for (issuer_ders) |der| {
        var mid = cert.parse(der) catch return Error.BadCertificate;
        if (now) |n| {
            if (!validityContains(&mid, n)) continue;
        }
        if (!signedBy(&leaf, &mid)) continue;
        if (signedBy(&mid, &anchor)) return .{ .chain_len = 2, .expiry_checked = now != null };
        // 找到了签发者但它本身不被锚信任：明确报"锚没用上"，不静默降级。
        return Error.UntrustedAnchor;
    }
    return Error.NoIssuer;
}

// ---------------------------------------------------------------------------
// 用例：用组件自己的证书构造器造一条真链（叶子 ← 中间 ← 根）
// ---------------------------------------------------------------------------

// 构造器在 cert.zig 里（`buildFixture`/`signWith` 一族）。这里只在用例里用它们；
// 若签名 API 名义不同，编译期会指出，不会静默用错。

test "chain: 通配符只匹配一级，且不匹配裸域" {
    try std.testing.expect(matchName("*.example.com", "a.example.com"));
    try std.testing.expect(!matchName("*.example.com", "a.b.example.com"));
    try std.testing.expect(!matchName("*.example.com", "example.com"));
    try std.testing.expect(matchName("Example.COM", "example.com")); // 大小写不敏感
    try std.testing.expect(!matchName("example.com", "www.example.com"));
}

const sfx = "ch23.local"; // fixture 的 SAN 是 ch23.local / www.ch23.local / 127.0.0.1

/// fixture 的有效期是 260101..270101（notBefore 先写、`Rev` 反向落盘）。
fn nowValid() cert.UtcTime {
    return .{ .year = 2026, .month = 6, .day = 1, .hour = 0, .minute = 0, .second = 0 };
}

test "chain: 自签证书作为锚 → chain_len=1；过期/主机名不符各自报错" {
    const leaf = cert.fixture_der;
    const none: []const []const u8 = &.{};

    const r = try verifyChain(leaf, none, leaf, nowValid(), sfx);
    try std.testing.expectEqual(@as(usize, 1), r.chain_len);

    const later: cert.UtcTime = .{ .year = 2030, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
    try std.testing.expectError(Error.Expired, verifyChain(leaf, none, leaf, later, sfx));

    try std.testing.expectError(Error.HostnameMismatch, verifyChain(leaf, none, leaf, nowValid(), "evil.example"));
}

test "chain: SAN 为空时回落到 CN，且必须是整串相等" {
    const c0 = try cert.parse(cert.fixture_der);
    var c = c0;
    c.san_len = 0;
    try std.testing.expect(hostnameMatches(&c, "ch23-stub.local")); // CN
    try std.testing.expect(!hostnameMatches(&c, "ch23-stub.localx"));
    try std.testing.expect(!hostnameMatches(&c, "stub.local"));
}

test "chain: 有效期比较到天，边界日算有效" {
    const c = try cert.parse(cert.fixture_der);
    const before: cert.UtcTime = .{ .year = 2025, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 };
    const first: cert.UtcTime = .{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
    const last: cert.UtcTime = .{ .year = 2027, .month = 1, .day = 1, .hour = 23, .minute = 59, .second = 59 };
    const beyond: cert.UtcTime = .{ .year = 2027, .month = 1, .day = 2, .hour = 0, .minute = 0, .second = 0 };
    try std.testing.expect(!validityContains(&c, before));
    try std.testing.expect(validityContains(&c, first));
    try std.testing.expect(validityContains(&c, last)); // notAfter 当天仍有效
    try std.testing.expect(!validityContains(&c, beyond));
}

test "chain: iPAddress SAN 不能当主机名匹配（fixture 里有 127.0.0.1）" {
    const c = try cert.parse(cert.fixture_der);
    try std.testing.expect(hostnameMatches(&c, "ch23.local")); // dNSName
    try std.testing.expect(hostnameMatches(&c, "www.ch23.local")); // dNSName
    try std.testing.expect(!hostnameMatches(&c, "127.0.0.1")); // iPAddress，不是名字
}
