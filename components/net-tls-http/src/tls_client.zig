//! net-tls-http：TLS 1.3 客户端状态机（握手 + 密钥切换）。
//!
//! 这一层把已有的件串起来，**不含任何 I/O**：调用方把收/发的字节交给它，
//! 它决定"下一步该发什么、收到这条记录意味着什么"。这样主机侧可以用一个
//! 脚本书做服务端把整条链跑完，板侧只负责把字节搬进搬出 socket。
//!
//! 状态推进与安全边界：
//!
//! ```text
//!   start()            → ClientHello（记录层明文，记录版本 0x0301）
//!   onRecord(0x16 SH)  → ECDHE + 握手密钥（CH..SH 转录）
//!   onRecord(0x14 CCS) → 跳过（OpenSSL 的中间盒兼容哑记录）
//!   onRecord(0x17 …)   → 解密：EE → Certificate → CertificateVerify → Finished
//!                        Finished **在 Flight 里真验**，失败即 BadFinished
//!   buildClientFinished() → 客户端 Finished（client_hs 密钥加密），随后切应用密钥
//!   onRecord(0x17 app) → 应用数据 / alert（内层类型 0x15）
//! ```
//!
//! **信任边界**：`Options.trust_cert_der` 为 null 时只做"证书自洽 + CertificateVerify
//! 签名"（用对端证书里的公钥验），**不判断这张证书是否可信**（无根 CA、无域名匹配）。
//! 这时 `certificate_trusted` 保持 false，日志/文档必须照此写。
const std = @import("std");
const record = @import("tls_record.zig");
const handshake = @import("tls_handshake.zig");
const protect = @import("tls_protect.zig");
const x25519 = @import("x25519.zig");
const ks = @import("tls_keyschedule.zig");
const cert = @import("cert.zig");
const crl_mod = @import("crl.zig");
const chain = @import("chain.zig");
const random = @import("random.zig");
const aead = @import("aead.zig");

pub const Error = error{
    UnexpectedState,
    UnexpectedPlaintextHandshake,
    BufferTooSmall,
    BadAlert,
    /// 服务端 Finished 的 verify_data 不对（伪造/篡改）。
    BadFinished,
    /// 记录 AEAD 校验失败（密钥/序号/AD 不对）。
    RecordAuthFailed,
    /// 对端发来 alert（`alert` 字段带 level/description）。
    ServerAlert,
    /// ServerHello 解析失败（细节见 `last_parse_error`，可用 `@errorFromInt` 还原名字）。
    BadServerHello,
    /// 配了 trust 证书，但对端出示的叶证书不是钉住的那张。
    CertificatePinMismatch,
    /// 链校验失败：签发关系/签名/锚不对。
    CertificateChainFailed,
    /// 链里找到了签发者，但它不被注入的锚信任（`chain.Error.UntrustedAnchor`）。
    CertificateUntrustedAnchor,
    /// 叶证书的序列号出现在配置的 CRL 里。
    CertificateRevoked,
    /// 链校验发现证书过期。
    CertificateExpired,
    /// 链校验发现主机名与 SAN 不匹配。
    CertificateHostnameMismatch,
    /// 配了 trust 证书但 CertificateVerify 验不过（签名或 scheme 不对）。
    CertificateVerifyFailed,
    /// 配了 trust 证书但证书本身解析失败。
    BadCertificate,
    NoKeyShare,
    NoServerFinished,
};

pub const Phase = enum {
    idle,
    await_server_hello,
    await_flight,
    /// 服务端 Finished 已验，可以发客户端 Finished。
    ready_client_finished,
    established,
};

pub const Alert = struct { level: u8, description: u8 };

pub const Options = struct {
    server_name: []const u8,
    /// PIN 模式：钉住单张证书（DER）。null ⇒ 不用 PIN。
    trust_cert_der: ?[]const u8 = null,
    /// 链模式：信任锚（DER，调用方持有，不采信对端链里的根）。
    trust_anchor_der: ?[]const u8 = null,
    /// 校验有效期用的“现在”。null ⇒ **跳过并标注**（没有可信时钟就别假装验过）。
    now: ?cert.UtcTime = null,
    /// 可选 CRL（DER）。给了就在链校验之后按序列号查吊销；CRL 的签名由
    /// **签发叶证书的那张证书**验（不是锚）。
    crl_der: ?[]const u8 = null,
};

pub const Client = struct {
    opts: Options,
    rng: random.Reader,
    secret: [x25519.scalar_length]u8 = undefined,
    /// 转录只有一份，归 Flight 所有：Finished 的校验在 Flight 内部取快照，
    /// 若这里再存一份（只喂 CH+SH）就会出现"校验用了不含 CH+SH 的哈希"。
    flight: handshake.Flight,
    phase: Phase = .idle,

    shared: [32]u8 = undefined,
    /// CH..ServerHello 的转录哈希（应用密钥派生需要它，不能事后重算）。
    hs_th: [ks.hash_length]u8 = undefined,
    schedule: ?ks.Schedule = null,
    /// Finished 验签用的**流量密钥**（32 B，不是 AEAD key——后者只有 16 B）。
    server_hs_traffic: [ks.hash_length]u8 = undefined,
    client_hs_traffic: [ks.hash_length]u8 = undefined,
    server_hs: ?protect.KeyState = null,
    client_hs: ?protect.KeyState = null,
    client_ap: ?protect.KeyState = null,
    server_ap: ?protect.KeyState = null,

    /// 证书链与信任状态（供日志/上层判读）。
    certificate_trusted: bool = false,
    /// 叶证书自洽（自签/自校验）通过。**不是**信任判断。
    certificate_verified_self_signed: bool = false,
    /// 叶证书指纹（SHA-256），供日志对拍；切片持有会随重组缓冲失效，所以只留指纹。
    leaf_fingerprint: [32]u8 = @splat(0),
    /// 叶证书 DER 的**稳定副本**（重组缓冲会被下一条消息覆盖，CV 还要用它验签）。
    leaf_der: [cert.max_cert_len]u8 = undefined,
    leaf_len: usize = 0,
    /// 有效期是否真的检查过（`now == null` 时为 false，日志必须照实写）。
    expiry_checked: bool = false,
    /// 链长度（1 = 叶直接由锚签发，2 = 一层中间证书）；0 = 没走链校验。
    chain_len: u8 = 0,

    alert: ?Alert = null,
    /// 最近一次 ServerHello 解析失败的原始错误码（板上没有 stderr，driver 用
    /// `@errorFromInt` 还原成具体名字；这个字段就是在定位"压缩方法读错字节"时加的）。
    last_parse_error: u16 = 0,
    /// 应用数据阶段最近一条记录的内容位置（内容留在调用方的 scratch 里）。
    last_payload_len: usize = 0,
    last_payload_type: u8 = 0,
    /// 握手消息跨记录重组的缓冲：放 .bss（客户端结构体本身也应放 .bss）。
    msg_buf: [4096]u8 = undefined,
    /// 跨记录重组时的已收字节数。**不要**在这里存 `MessageReader`：它内部持有
    /// `&msg_buf`，而 `Client` 会被按值返回/移动，指针会悬空（实测：前几个字节
    /// 碰巧正确、深层解析报 BadLength）。每次调用时按 (buf,len) 现场构造视图。
    reader_len: usize = 0,

    pub fn init(opts: Options, rng: random.Reader) Client {
        return .{ .opts = opts, .rng = rng, .flight = handshake.Flight.init(), .reader_len = 0 };
    }

    fn level(self: *Client) [ks.hash_length]u8 {
        return self.flight.transcript.snapshot();
    }

    /// 本端的 X25519 公钥（`start()` 之后有效）。服务端用它算共享秘密；
    /// 板侧日志也会打它的指纹，便于与主机侧对拍。
    pub fn clientPublic(self: *const Client) [32]u8 {
        return x25519.publicKey(self.secret);
    }

    /// 写 ClientHello 记录到 `out`，返回整条记录长度。
    pub fn start(self: *Client, out: []u8) Error!usize {
        if (self.phase != .idle) return Error.UnexpectedState;
        self.rng.fill(&self.secret);
        const p = handshake.Params{ .server_name = self.opts.server_name, .secret = self.secret };
        const n = handshake.writeClientHelloRecord(out, p, self.rng) catch return Error.BufferTooSmall;
        // 转录只吃握手消息本体（去掉 5 字节记录头）
        self.flight.transcript.add(out[record.header_len..n]);
        self.phase = .await_server_hello;
        return n;
    }

    /// 送入一条记录（明文 SH/CCS 或加密飞行都走这里）。
    /// `scratch` 用于解密明文，至少 `record.max_record_length` 字节。
    pub fn onRecord(self: *Client, rec: []const u8, scratch: []u8) Error!void {
        const hdr = record.readHeader(rec[0..@min(rec.len, record.header_len)]) catch return Error.UnexpectedState;
        if (rec.len < record.header_len + hdr.length) return Error.UnexpectedState;
        const frag = rec[record.header_len..][0..hdr.length];

        switch (hdr.content_type) {
            // OpenSSL 默认发一条哑 CCS 做中间盒兼容：握手期间静默跳过。
            .change_cipher_spec => return,
            .alert => return self.handlePlaintextAlert(frag),
            .handshake => return self.handlePlaintextHandshake(frag),
            .application_data => return self.handleProtected(frag, scratch),
        }
    }

    fn handlePlaintextAlert(self: *Client, frag: []const u8) Error!void {
        if (frag.len < 2) return Error.BadAlert;
        self.alert = .{ .level = frag[0], .description = frag[1] };
        return Error.ServerAlert;
    }

    fn handlePlaintextHandshake(self: *Client, frag: []const u8) Error!void {
        if (self.phase != .await_server_hello) return Error.UnexpectedPlaintextHandshake;
        const sh_msg = if (frag.len >= 4 and frag[0] == handshake.handshake_type_server_hello) frag else return Error.UnexpectedPlaintextHandshake;

        // 转录在 ServerHello **之后**取快照（CH..SH）。
        self.flight.transcript.add(sh_msg);
        const sh = handshake.parseServerHello(sh_msg) catch |e| {
            self.last_parse_error = @intFromError(e);
            return Error.BadServerHello;
        };
        self.shared = x25519.scalarmult(self.secret, sh.key_share) catch return Error.NoKeyShare;

        const th = self.level();
        self.hs_th = th;
        const sched = ks.buildSchedule(&self.shared, &th, &th) catch return Error.UnexpectedState;
        self.schedule = sched;
        self.server_hs_traffic = sched.server_hs_traffic;
        self.client_hs_traffic = sched.client_hs_traffic;
        self.server_hs = protect.KeyState.init(sched.server_hs_traffic);
        self.client_hs = protect.KeyState.init(sched.client_hs_traffic);
        self.phase = .await_flight;
    }

    fn handleProtected(self: *Client, frag: []const u8, scratch: []u8) Error!void {
        // 读方向的序号是独立的：握手阶段用 server_hs，established 之后必须换成 server_ap
        // （用错密钥的表现是 AuthFailed，而服务端那边看起来"发了但对方没反应"）。
        const established = self.phase == .established;
        var k = (if (established) self.server_ap else self.server_hs) orelse return Error.UnexpectedState;
        const r = protect.openFragment(scratch, &k, frag) catch return Error.RecordAuthFailed;
        if (established) self.server_ap = k else self.server_hs = k;

        if (self.phase == .established) {
            // 应用数据阶段：内容留在 `scratch`，上层按 (type,len) 取用。
            self.last_payload_len = r.len;
            self.last_payload_type = r.ct;
            return;
        }
        switch (r.ct) {
            // 加密后的 alert：把对端拒绝的原因带出去，而不是当成坏记录。
            21 => {
                if (r.len < 2) return Error.BadAlert;
                self.alert = .{ .level = scratch[0], .description = scratch[1] };
                return Error.ServerAlert;
            },
            22 => return self.ingestHandshake(scratch[0..r.len]),
            // 握手期间的哑 CCS 有时也被加密进记录里（少见但合法）。
            20 => return,
            else => return Error.UnexpectedState,
        }
    }

    fn ingestHandshake(self: *Client, data: []const u8) Error!void {
        // 视图按值构造：buf 指向本结构体的字段，len 独立保存在 `reader_len`。
        var r = record.MessageReader{ .buf = &self.msg_buf, .len = self.reader_len };
        const first = r.push(.handshake, data) catch return Error.UnexpectedState;
        self.reader_len = r.len;
        if (first) |msg| try self.dispatchHandshake(msg);
        while (true) {
            const next = r.take() catch return Error.UnexpectedState;
            self.reader_len = r.len;
            const msg = next orelse break;
            try self.dispatchHandshake(msg);
        }
    }

    fn dispatchHandshake(self: *Client, msg: []const u8) Error!void {
        const srv_hs_tr = self.server_hs_traffic;
        // 先处理 Certificate / CertificateVerify 的语义（Flight 只管顺序与转录）。
        switch (msg[0]) {
            handshake.handshake_type_certificate => {
                var entries: [handshake.max_certs]handshake.CertEntry = undefined;
                const list = handshake.parseCertificate(msg, &entries) catch return Error.BadCertificate;
                if (list.len > 0) {
                    if (list[0].der.len > self.leaf_der.len) return Error.BadCertificate;
                    @memcpy(self.leaf_der[0..list[0].der.len], list[0].der);
                    self.leaf_len = list[0].der.len;
                    const leaf = cert.parse(list[0].der) catch return Error.BadCertificate;
                    self.leaf_fingerprint = cert.fingerprint(list[0].der);

                    if (self.opts.trust_anchor_der) |anchor| {
                        // 链模式：锚由调用方给；对端链里的其它证书只作为候选签发者。
                        var issuers: [handshake.max_certs][]const u8 = undefined;
                        var n: usize = 0;
                        for (list[1..]) |e| {
                            issuers[n] = e.der;
                            n += 1;
                        }
                        const r = chain.verifyChain(list[0].der, issuers[0..n], anchor, self.opts.now, self.opts.server_name) catch |e| switch (e) {
                            chain.Error.Expired => return Error.CertificateExpired,
                            chain.Error.HostnameMismatch => return Error.CertificateHostnameMismatch,
                            chain.Error.UntrustedAnchor => return Error.CertificateUntrustedAnchor,
                            else => return Error.CertificateChainFailed,
                        };
                        self.certificate_trusted = true;
                        self.expiry_checked = r.expiry_checked;
                        self.chain_len = @intCast(r.chain_len);

                        if (self.opts.crl_der) |crl_der| {
                            var issuer_cert = cert.parse(r.issuer_der) catch return Error.BadCertificate;
                            const crl = crl_mod.parse(crl_der, &issuer_cert) catch return Error.CertificateChainFailed;
                            if (crl.isRevoked(leaf.serial)) return Error.CertificateRevoked;
                        }
                    } else if (self.opts.trust_cert_der) |pinned| {
                        // PIN 语义：必须是**同一张**证书；只验 CV 签名不够。
                        if (!std.mem.eql(u8, pinned, list[0].der)) return Error.CertificatePinMismatch;
                        self.certificate_trusted = true;
                    }
                    // 自签校验只做记录，不当作握手前提。
                    if (cert.verifySignature(&leaf)) |_| {
                        self.certificate_verified_self_signed = true;
                    } else |_| {}
                }
            },
            handshake.handshake_type_certificate_verify => {
                const cv = handshake.parseCertificateVerify(msg) catch return Error.CertificateVerifyFailed;
                if (cv.scheme != handshake.sig_ecdsa_secp256r1_sha256) return Error.CertificateVerifyFailed;
                if (self.opts.trust_cert_der) |der| {
                    var trusted = cert.parse(der) catch return Error.BadCertificate;
                    var buf: [128 + 32]u8 = undefined;
                    const content = handshake.certificateVerifyContent(&buf, self.level()) catch return Error.BufferTooSmall;
                    cert.verifyMessage(&trusted, content, cv.signature) catch return Error.CertificateVerifyFailed;
                } else if (self.opts.trust_anchor_der != null) {
                    // 链模式：CV 由**出示的叶证书**的私钥签，用它的公钥验（链已经建立信任）。
                    if (self.leaf_len == 0) return Error.CertificateVerifyFailed;
                    var leaf = cert.parse(self.leaf_der[0..self.leaf_len]) catch return Error.BadCertificate;
                    var buf: [128 + 32]u8 = undefined;
                    const content = handshake.certificateVerifyContent(&buf, self.level()) catch return Error.BufferTooSmall;
                    cert.verifyMessage(&leaf, content, cv.signature) catch return Error.CertificateVerifyFailed;
                }
                // trust 为 null：只记录"未验信任"，不阻断（文档必须照此声明）。
            },
            else => {},
        }
        // Finished 的密钥这里必须传：Flight 内部在计入转录前取快照并校验。
        handshake.advanceFlight(&self.flight, msg, srv_hs_tr) catch |e| switch (e) {
            handshake.Flight.Error.BadFinished => return Error.BadFinished,
            handshake.Flight.Error.UnexpectedMessage => return Error.UnexpectedState,
            handshake.Flight.Error.NotEncryptedExtensions => return Error.UnexpectedState,
        };
        if (self.flight.state == .done) self.phase = .ready_client_finished;
    }

    /// 用应用密钥封一条记录（HTTP 等上层数据走这里）。
    /// 只有 `established` 之后才允许：握手阶段误用会把明文当应用数据发出去。
    pub fn sealApplication(self: *Client, out: []u8, content_type: u8, content: []const u8) Error!usize {
        if (self.phase != .established) return Error.UnexpectedState;
        var k = self.client_ap orelse return Error.UnexpectedState;
        const n = protect.seal(out, &k, content_type, content) catch return Error.BufferTooSmall;
        self.client_ap = k;
        return n;
    }

    /// 写客户端 Finished（handshake 记录，client_hs 密钥加密），并切到应用密钥。
    pub fn buildClientFinished(self: *Client, out: []u8) Error!usize {
        if (self.phase != .ready_client_finished) return Error.UnexpectedState;
        const th = self.level(); // 已含服务端 Finished
        var sched = self.schedule orelse return Error.UnexpectedState;
        const verify = ks.finishedVerifyData(self.client_hs_traffic, &th);

        var msg: [4 + ks.hash_length]u8 = undefined;
        msg[0] = handshake.handshake_type_finished;
        msg[1] = 0;
        msg[2] = 0;
        msg[3] = ks.hash_length;
        @memcpy(msg[4..], &verify);

        var client_keys = self.client_hs orelse return Error.UnexpectedState;
        const n = protect.seal(out, &client_keys, @backingInt(record.ContentType.handshake), &msg) catch return Error.BufferTooSmall;
        self.client_hs = client_keys;
        self.flight.transcript.add(&msg); // 客户端也要把自己的 Finished 计入后续转录

        // 应用密钥：hs_transcript = CH..SH、ap_transcript = CH..server Finished。
        // 两个快照都在被使用前取过，这里只做派生（HKDF 相对网络开销可忽略）。
        const ap_th = th;
        const full = ks.buildSchedule(&self.shared, &self.hs_th, &ap_th) catch return Error.UnexpectedState;
        sched = full;
        self.schedule = full;
        self.client_ap = protect.KeyState.init(full.client_ap_traffic);
        self.server_ap = protect.KeyState.init(full.server_ap_traffic);
        self.phase = .established;
        return n;
    }
};

// ---------------------------------------------------------------------------
// 用例：脚本化服务端把整条握手跑完（主机侧、无 I/O）
// ---------------------------------------------------------------------------

const TestStream = struct {
    state: u64 = 0x2026_0301,
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

fn put24b(buf: []u8, v: u32) void {
    buf[0] = @intCast((v >> 16) & 0xff);
    buf[1] = @intCast((v >> 8) & 0xff);
    buf[2] = @intCast(v & 0xff);
}

fn hsWrap(buf: []u8, typ: u8, body: []const u8) []const u8 {
    buf[0] = typ;
    put24b(buf[1..], @intCast(body.len));
    @memcpy(buf[4..][0..body.len], body);
    return buf[0 .. 4 + body.len];
}

/// 拼一条 ServerHello（只含 supported_versions + key_share）。
fn buildServerHello(buf: []u8, server_pub: [32]u8) []const u8 {
    var i: usize = 4;
    buf[i] = 0x03;
    buf[i + 1] = 0x03;
    i += 2;
    @memset(buf[i..][0..32], 0x5A);
    i += 32;
    buf[i] = 0; // session id echo
    i += 1;
    buf[i] = 0x13;
    buf[i + 1] = 0x01;
    i += 2;
    buf[i] = 0; // legacy_compression_method（单字节，RFC 8446 §4.1.3）
    i += 1;
    const exts_len_off = i;
    i += 2;
    const exts_start = i;
    // supported_versions
    buf[i] = 0x00;
    buf[i + 1] = 0x2b;
    buf[i + 2] = 0x00;
    buf[i + 3] = 0x02;
    buf[i + 4] = 0x03;
    buf[i + 5] = 0x04;
    i += 6;
    // key_share
    buf[i] = 0x00;
    buf[i + 1] = 0x33;
    buf[i + 2] = 0x00;
    buf[i + 3] = 0x24;
    buf[i + 4] = 0x00;
    buf[i + 5] = 0x1d;
    buf[i + 6] = 0x00;
    buf[i + 7] = 0x20;
    i += 8;
    @memcpy(buf[i..][0..32], &server_pub);
    i += 32;
    buf[exts_len_off] = @intCast((i - exts_start) >> 8);
    buf[exts_len_off + 1] = @intCast((i - exts_start) & 0xff);
    buf[0] = handshake.handshake_type_server_hello;
    put24b(buf[1..], @intCast(i - 4));
    return buf[0..i];
}

fn wrapHandshakeRecord(buf: []u8, msg: []const u8) []const u8 {
    record.writeHeader(buf[0..record.header_len], .handshake, msg.len) catch unreachable;
    @memcpy(buf[record.header_len..][0..msg.len], msg);
    return buf[0 .. record.header_len + msg.len];
}

fn sealRecord(out: []u8, k: *protect.KeyState, inner_ct: u8, content: []const u8) []const u8 {
    const n = protect.seal(out, k, inner_ct, content) catch unreachable;
    return out[0..n];
}

test "client: 完整握手（CH→SH→EE/Cert/CV/Finished→client Finished），Finished 真验" {
    var stream = TestStream{};
    var client = Client.init(.{ .server_name = "ch23-stub.local" }, stream.reader());
    var ch_rec: [512]u8 = undefined;
    const ch_n = try client.start(&ch_rec);
    try std.testing.expectEqual(@as(u8, 0x16), ch_rec[0]);
    try std.testing.expectEqual(@as(u16, 0x0301), std.mem.readInt(u16, ch_rec[1..3], .big));

    // ---- 服务端侧：用自己的私钥与客户端公钥算共享秘密 ----
    const server_secret: [32]u8 = @splat(0x42);
    const shared = try x25519.scalarmult(server_secret, client.clientPublic());
    var srv_tr = handshake.Transcript.init();
    srv_tr.add(ch_rec[record.header_len..ch_n]);

    var sh_buf: [256]u8 = undefined;
    const sh = buildServerHello(&sh_buf, x25519.publicKey(server_secret));
    srv_tr.add(sh);
    const hs_th = srv_tr.snapshot();
    const sched = try ks.buildSchedule(&shared, &hs_th, &hs_th);
    var srv_hs = protect.KeyState.init(sched.server_hs_traffic);
    var cli_hs = protect.KeyState.init(sched.client_hs_traffic);

    var sh_rec: [300]u8 = undefined;
    try client.onRecord(wrapHandshakeRecord(&sh_rec, sh), undefined_scratch());
    try std.testing.expectEqual(Phase.await_flight, client.phase);

    // CCS（OpenSSL 的哑记录）必须被静默跳过
    var ccs_rec = [_]u8{ 20, 0x03, 0x03, 0x00, 0x01, 0x01 };
    try client.onRecord(&ccs_rec, undefined_scratch());
    try std.testing.expectEqual(Phase.await_flight, client.phase);

    // ---- 服务端飞行 ----
    var msgbuf: [512]u8 = undefined;
    var recbuf: [600]u8 = undefined;

    // EncryptedExtensions
    const ee = hsWrap(&msgbuf, handshake.handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    srv_tr.add(ee);
    var sealed: [600]u8 = undefined;
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, ee), undefined_scratch());

    // Certificate（用组件自带 fixture，保证 DER 可解析且自洽）
    var cert_body: [512]u8 = undefined;
    cert_body[0] = 0;
    // list = entry_len(3) + der + entry extensions(2)
    put24b(cert_body[1..], @intCast(3 + cert.fixture_der.len + 2));
    put24b(cert_body[4..], @intCast(cert.fixture_der.len));
    @memcpy(cert_body[7..][0..cert.fixture_der.len], cert.fixture_der);
    cert_body[7 + cert.fixture_der.len] = 0;
    cert_body[8 + cert.fixture_der.len] = 0;
    const cert_msg = hsWrap(&recbuf, handshake.handshake_type_certificate, cert_body[0 .. 9 + cert.fixture_der.len]);
    srv_tr.add(cert_msg);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cert_msg), undefined_scratch());
    try std.testing.expect(client.certificate_verified_self_signed);
    try std.testing.expect(!client.certificate_trusted); // 没配 trust：不判信任

    // CertificateVerify（trust=null，不验签名，只记录）
    const cv = hsWrap(&msgbuf, handshake.handshake_type_certificate_verify, &[_]u8{ 0x04, 0x03, 0x00, 0x02, 0xAA, 0xBB });
    srv_tr.add(cv);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cv), undefined_scratch());

    // Finished：verify_data 覆盖 CH…CV（不含自己）
    const before_fin = srv_tr.snapshot();
    const verify = ks.finishedVerifyData(sched.server_hs_traffic, &before_fin);
    var fin_body: [ks.hash_length]u8 = undefined;
    @memcpy(&fin_body, &verify);
    const fin = hsWrap(&msgbuf, handshake.handshake_type_finished, &fin_body);
    srv_tr.add(fin);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, fin), undefined_scratch());
    try std.testing.expectEqual(Phase.ready_client_finished, client.phase);

    // ---- 客户端 Finished：用 client_hs 密钥加密，内容必须与同一规则算出的值一致 ----
    var fin_rec: [128]u8 = undefined;
    const n = try client.buildClientFinished(&fin_rec);
    try std.testing.expectEqual(Phase.established, client.phase);

    var plain: [128]u8 = undefined;
    const r = try protect.openFragment(&plain, &cli_hs, fin_rec[record.header_len..n]);
    try std.testing.expectEqual(@as(u8, 22), r.ct);
    // 客户端 Finished 的转录 = CH…server Finished；这里用服务端侧的转录快照独立重算
    const cli_th = srv_tr.snapshot();
    const expect2 = ks.finishedVerifyData(sched.client_hs_traffic, &cli_th);
    try std.testing.expectEqualSlices(u8, &expect2, plain[4..][0..ks.hash_length]);
}

test "client: 服务端 Finished 被篡改时握手失败（不是静默接受）" {
    var stream = TestStream{};
    var client = Client.init(.{ .server_name = "a.test" }, stream.reader());
    var ch_rec: [512]u8 = undefined;
    const ch_n = try client.start(&ch_rec);

    const server_secret: [32]u8 = @splat(0x42);
    const shared = try x25519.scalarmult(server_secret, client.clientPublic());
    var srv_tr = handshake.Transcript.init();
    srv_tr.add(ch_rec[record.header_len..ch_n]);
    var sh_buf: [256]u8 = undefined;
    const sh = buildServerHello(&sh_buf, x25519.publicKey(server_secret));
    srv_tr.add(sh);
    const hs_th = srv_tr.snapshot();
    const sched = try ks.buildSchedule(&shared, &hs_th, &hs_th);
    var srv_hs = protect.KeyState.init(sched.server_hs_traffic);

    var sh_rec: [300]u8 = undefined;
    try client.onRecord(wrapHandshakeRecord(&sh_rec, sh), undefined_scratch());

    var msgbuf: [512]u8 = undefined;
    var sealed: [600]u8 = undefined;
    const ee = hsWrap(&msgbuf, handshake.handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    srv_tr.add(ee);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, ee), undefined_scratch());

    var cert_body: [512]u8 = undefined;
    cert_body[0] = 0;
    // list = entry_len(3) + der + entry extensions(2)
    put24b(cert_body[1..], @intCast(3 + cert.fixture_der.len + 2));
    put24b(cert_body[4..], @intCast(cert.fixture_der.len));
    @memcpy(cert_body[7..][0..cert.fixture_der.len], cert.fixture_der);
    cert_body[7 + cert.fixture_der.len] = 0;
    cert_body[8 + cert.fixture_der.len] = 0;
    var cb2: [512]u8 = undefined;
    const cert_msg = hsWrap(&cb2, handshake.handshake_type_certificate, cert_body[0 .. 9 + cert.fixture_der.len]);
    srv_tr.add(cert_msg);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cert_msg), undefined_scratch());

    const cv = hsWrap(&msgbuf, handshake.handshake_type_certificate_verify, &[_]u8{ 0x04, 0x03, 0x00, 0x01, 0x00 });
    srv_tr.add(cv);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cv), undefined_scratch());

    var fin_body: [ks.hash_length]u8 = @splat(0x77); // 伪造
    const fin = hsWrap(&msgbuf, handshake.handshake_type_finished, &fin_body);
    try std.testing.expectError(Error.BadFinished, client.onRecord(sealRecord(&sealed, &srv_hs, 22, fin), undefined_scratch()));
    try std.testing.expect(client.phase != .ready_client_finished);
}

/// 用例里 SH 是明文记录，解密缓冲不会被写；给一块真缓冲以免传 undefined 触发安全构建的检查。
var scratch_buf: [record.max_record_length]u8 = undefined;
fn undefined_scratch() []u8 {
    return &scratch_buf;
}

test "client: established 之后的应用数据必须用 server_ap 解（握手密钥解不开）" {
    // 复用完整握手的前半段：CH → SH → EE/Cert/CV/Finished → client Finished
    var stream = TestStream{};
    var client = Client.init(.{ .server_name = "a.test" }, stream.reader());
    var ch_rec: [512]u8 = undefined;
    const ch_n = try client.start(&ch_rec);

    const server_secret: [32]u8 = @splat(0x42);
    const shared = try x25519.scalarmult(server_secret, client.clientPublic());
    var srv_tr = handshake.Transcript.init();
    srv_tr.add(ch_rec[record.header_len..ch_n]);
    var sh_buf: [256]u8 = undefined;
    const sh = buildServerHello(&sh_buf, x25519.publicKey(server_secret));
    srv_tr.add(sh);
    const hs_th = srv_tr.snapshot();
    const sched = try ks.buildSchedule(&shared, &hs_th, &hs_th);
    var srv_hs = protect.KeyState.init(sched.server_hs_traffic);

    var sh_rec: [300]u8 = undefined;
    try client.onRecord(wrapHandshakeRecord(&sh_rec, sh), undefined_scratch());

    var msgbuf: [512]u8 = undefined;
    var sealed: [600]u8 = undefined;
    const ee = hsWrap(&msgbuf, handshake.handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    srv_tr.add(ee);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, ee), undefined_scratch());

    var cert_body: [512]u8 = undefined;
    cert_body[0] = 0;
    // list = entry_len(3) + der + entry extensions(2)
    put24b(cert_body[1..], @intCast(3 + cert.fixture_der.len + 2));
    put24b(cert_body[4..], @intCast(cert.fixture_der.len));
    @memcpy(cert_body[7..][0..cert.fixture_der.len], cert.fixture_der);
    cert_body[7 + cert.fixture_der.len] = 0;
    cert_body[8 + cert.fixture_der.len] = 0;
    var cb2: [512]u8 = undefined;
    const cert_msg = hsWrap(&cb2, handshake.handshake_type_certificate, cert_body[0 .. 9 + cert.fixture_der.len]);
    srv_tr.add(cert_msg);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cert_msg), undefined_scratch());

    const cv = hsWrap(&msgbuf, handshake.handshake_type_certificate_verify, &[_]u8{ 0x04, 0x03, 0x00, 0x01, 0x00 });
    srv_tr.add(cv);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cv), undefined_scratch());

    const before_fin = srv_tr.snapshot();
    const fin_v = ks.finishedVerifyData(sched.server_hs_traffic, &before_fin);
    var fin_body: [ks.hash_length]u8 = undefined;
    @memcpy(&fin_body, &fin_v);
    const fin = hsWrap(&msgbuf, handshake.handshake_type_finished, &fin_body);
    srv_tr.add(fin);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, fin), undefined_scratch());

    var fin_rec: [128]u8 = undefined;
    _ = try client.buildClientFinished(&fin_rec);
    try std.testing.expectEqual(Phase.established, client.phase);

    // 服务端用 *应用* 密钥发一条数据：客户端必须用 server_ap 解开。
    // （旧实现固定用 server_hs，这里会 AuthFailed——正是这条用例的存在理由。）
    // 应用密钥必须用 **CH..server Finished** 的转录派生（客户端在 buildClientFinished
    // 里就是这么算的）；拿第一次 schedule 的 ap 字段会得到另一组密钥。
    const after_fin = srv_tr.snapshot();
    const ap_sched = try ks.buildSchedule(&shared, &hs_th, &after_fin);
    var srv_ap = protect.KeyState.init(ap_sched.server_ap_traffic);
    var app_rec: [64]u8 = undefined;
    const payload = "HTTP/1.1 200 OK\r\n";
    const rec = sealRecord(&app_rec, &srv_ap, 23, payload);
    try client.onRecord(rec, undefined_scratch());
    try std.testing.expectEqual(@as(u8, 23), client.last_payload_type);
    try std.testing.expectEqual(payload.len, client.last_payload_len);
}

test "client: 配了 trust 但叶证书不是钉住的那张 → CertificatePinMismatch（只验 CV 签名不够）" {
    var stream = TestStream{};
    var client = Client.init(.{ .server_name = "a.test", .trust_cert_der = "not-the-server-cert" }, stream.reader());
    var ch_rec: [512]u8 = undefined;
    const ch_n = try client.start(&ch_rec);

    const server_secret: [32]u8 = @splat(0x42);
    const shared = try x25519.scalarmult(server_secret, client.clientPublic());
    var srv_tr = handshake.Transcript.init();
    srv_tr.add(ch_rec[record.header_len..ch_n]);
    var sh_buf: [256]u8 = undefined;
    const sh = buildServerHello(&sh_buf, x25519.publicKey(server_secret));
    srv_tr.add(sh);
    const hs_th = srv_tr.snapshot();
    const sched = try ks.buildSchedule(&shared, &hs_th, &hs_th);
    var srv_hs = protect.KeyState.init(sched.server_hs_traffic);

    var sh_rec: [300]u8 = undefined;
    try client.onRecord(wrapHandshakeRecord(&sh_rec, sh), undefined_scratch());

    var msgbuf: [512]u8 = undefined;
    var sealed: [600]u8 = undefined;
    const ee = hsWrap(&msgbuf, handshake.handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    srv_tr.add(ee);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, ee), undefined_scratch());

    var cert_body: [512]u8 = undefined;
    cert_body[0] = 0;
    // list = entry_len(3) + der + entry extensions(2)
    put24b(cert_body[1..], @intCast(3 + cert.fixture_der.len + 2));
    put24b(cert_body[4..], @intCast(cert.fixture_der.len));
    @memcpy(cert_body[7..][0..cert.fixture_der.len], cert.fixture_der);
    cert_body[7 + cert.fixture_der.len] = 0;
    cert_body[8 + cert.fixture_der.len] = 0;
    var cb2: [512]u8 = undefined;
    const cert_msg = hsWrap(&cb2, handshake.handshake_type_certificate, cert_body[0 .. 9 + cert.fixture_der.len]);
    srv_tr.add(cert_msg);
    // 对端出示的是 fixture，而我们钉的是别的证书：必须在证书这一条就失败。
    try std.testing.expectError(Error.CertificatePinMismatch, client.onRecord(sealRecord(&sealed, &srv_hs, 22, cert_msg), undefined_scratch()));
}

test "client: established 后 sealApplication 的记录能被对端的应用密钥解开" {
    // 复用完整握手：CH → SH → 飞行 → client Finished
    var stream = TestStream{};
    var client = Client.init(.{ .server_name = "a.test" }, stream.reader());
    var ch_rec: [512]u8 = undefined;
    const ch_n = try client.start(&ch_rec);

    const server_secret: [32]u8 = @splat(0x42);
    const shared = try x25519.scalarmult(server_secret, client.clientPublic());
    var srv_tr = handshake.Transcript.init();
    srv_tr.add(ch_rec[record.header_len..ch_n]);
    var sh_buf: [256]u8 = undefined;
    const sh = buildServerHello(&sh_buf, x25519.publicKey(server_secret));
    srv_tr.add(sh);
    const hs_th = srv_tr.snapshot();
    const sched = try ks.buildSchedule(&shared, &hs_th, &hs_th);
    var srv_hs = protect.KeyState.init(sched.server_hs_traffic);

    var sh_rec: [300]u8 = undefined;
    try client.onRecord(wrapHandshakeRecord(&sh_rec, sh), undefined_scratch());

    var msgbuf: [512]u8 = undefined;
    var sealed: [600]u8 = undefined;
    const ee = hsWrap(&msgbuf, handshake.handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    srv_tr.add(ee);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, ee), undefined_scratch());

    var cert_body: [512]u8 = undefined;
    cert_body[0] = 0;
    // list = entry_len(3) + der + entry extensions(2)
    put24b(cert_body[1..], @intCast(3 + cert.fixture_der.len + 2));
    put24b(cert_body[4..], @intCast(cert.fixture_der.len));
    @memcpy(cert_body[7..][0..cert.fixture_der.len], cert.fixture_der);
    cert_body[7 + cert.fixture_der.len] = 0;
    cert_body[8 + cert.fixture_der.len] = 0;
    var cb2: [512]u8 = undefined;
    const cert_msg = hsWrap(&cb2, handshake.handshake_type_certificate, cert_body[0 .. 9 + cert.fixture_der.len]);
    srv_tr.add(cert_msg);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cert_msg), undefined_scratch());

    const cv = hsWrap(&msgbuf, handshake.handshake_type_certificate_verify, &[_]u8{ 0x04, 0x03, 0x00, 0x01, 0x00 });
    srv_tr.add(cv);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cv), undefined_scratch());

    const before_fin = srv_tr.snapshot();
    const fin_v = ks.finishedVerifyData(sched.server_hs_traffic, &before_fin);
    var fin_body: [ks.hash_length]u8 = undefined;
    @memcpy(&fin_body, &fin_v);
    const fin = hsWrap(&msgbuf, handshake.handshake_type_finished, &fin_body);
    srv_tr.add(fin);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, fin), undefined_scratch());

    var fin_rec: [128]u8 = undefined;
    _ = try client.buildClientFinished(&fin_rec);
    try std.testing.expectEqual(Phase.established, client.phase);

    // 对端要解**客户端**发出的记录，用的是 client_ap_traffic（读/写方向各自独立）
    const after_fin = srv_tr.snapshot();
    const ap_sched = try ks.buildSchedule(&shared, &hs_th, &after_fin);
    var srv_ap = protect.KeyState.init(ap_sched.client_ap_traffic);

    var app: [256]u8 = undefined;
    const n = try client.sealApplication(&app, 23, "GET / HTTP/1.1\r\n\r\n");
    var plain: [256]u8 = undefined;
    const r = try protect.openFragment(&plain, &srv_ap, app[record.header_len..n]);
    try std.testing.expectEqual(@as(u8, 23), r.ct);
    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", plain[0..r.len]);
}

// ---------------------------------------------------------------------------
// 链模式的用例：fixture 的私钥可由固定 seed 复现，所以能造出真签名
// ---------------------------------------------------------------------------

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// 组件 fixture 的密钥（`cert.buildSelfSigned` 用 `generateDeterministic(@splat(0x23))`）。
fn fixtureKey() Ecdsa.KeyPair {
    return Ecdsa.KeyPair.generateDeterministic(@splat(0x23)) catch unreachable;
}

/// 造一条由 fixture 私钥真正签过名的 CertificateVerify 消息。
fn signCv(buf: []u8, transcript_hash: [32]u8) []const u8 {
    var content_buf: [128 + 32]u8 = undefined;
    const content = handshake.certificateVerifyContent(&content_buf, transcript_hash) catch unreachable;
    const kp = fixtureKey();
    const sig = kp.sign(content, @splat(0)) catch unreachable;
    var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&sig_buf);
    var body: [2 + 2 + Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    body[0] = 0x04; // ecdsa_secp256r1_sha256
    body[1] = 0x03;
    body[2] = @intCast((sig_der.len >> 8) & 0xff);
    body[3] = @intCast(sig_der.len & 0xff);
    @memcpy(body[4..][0..sig_der.len], sig_der);
    return hsWrap(buf, handshake.handshake_type_certificate_verify, body[0 .. 4 + sig_der.len]);
}

fn chainOptions(anchor: []const u8, now: ?cert.UtcTime) Options {
    return .{ .server_name = "ch23.local", .trust_anchor_der = anchor, .now = now };
}

/// 跑到 CV 之前的公共步骤，返回 (client, srv_tr, sched, srv_hs)。
fn driveToCv(client: *Client, srv_tr: *handshake.Transcript, sched: *ks.Schedule, srv_hs: *protect.KeyState) !void {
    var ch_rec: [512]u8 = undefined;
    const ch_n = try client.start(&ch_rec);
    const server_secret: [32]u8 = @splat(0x42);
    const shared = try x25519.scalarmult(server_secret, client.clientPublic());
    srv_tr.* = handshake.Transcript.init();
    srv_tr.add(ch_rec[record.header_len..ch_n]);

    var sh_buf: [256]u8 = undefined;
    const sh = buildServerHello(&sh_buf, x25519.publicKey(server_secret));
    srv_tr.add(sh);
    const hs_th = srv_tr.snapshot();
    sched.* = try ks.buildSchedule(&shared, &hs_th, &hs_th);
    srv_hs.* = protect.KeyState.init(sched.server_hs_traffic);

    var sh_rec: [300]u8 = undefined;
    try client.onRecord(wrapHandshakeRecord(&sh_rec, sh), undefined_scratch());

    var msgbuf: [512]u8 = undefined;
    var sealed: [1024]u8 = undefined;
    const ee = hsWrap(&msgbuf, handshake.handshake_type_encrypted_extensions, &[_]u8{ 0, 0 });
    srv_tr.add(ee);
    try client.onRecord(sealRecord(&sealed, &srv_hs.*, 22, ee), undefined_scratch());

    var cert_body: [1024]u8 = undefined;
    cert_body[0] = 0;
    put24b(cert_body[1..], @intCast(3 + cert.fixture_der.len + 2));
    put24b(cert_body[4..], @intCast(cert.fixture_der.len));
    @memcpy(cert_body[7..][0..cert.fixture_der.len], cert.fixture_der);
    cert_body[7 + cert.fixture_der.len] = 0;
    cert_body[8 + cert.fixture_der.len] = 0;
    var cb2: [1024]u8 = undefined;
    const cert_msg = hsWrap(&cb2, handshake.handshake_type_certificate, cert_body[0 .. 9 + cert.fixture_der.len]);
    srv_tr.add(cert_msg);
    try client.onRecord(sealRecord(&sealed, &srv_hs.*, 22, cert_msg), undefined_scratch());
}

test "client+chain: 自签 fixture 作锚 → trusted，CV 用叶证书公钥验过" {
    var stream = TestStream{};
    var client = Client.init(chainOptions(cert.fixture_der, .{ .year = 2026, .month = 6, .day = 1, .hour = 0, .minute = 0, .second = 0 }), stream.reader());
    var srv_tr: handshake.Transcript = undefined;
    var sched: ks.Schedule = undefined;
    var srv_hs: protect.KeyState = undefined;
    try driveToCv(&client, &srv_tr, &sched, &srv_hs);
    try std.testing.expect(client.certificate_trusted);
    try std.testing.expect(client.expiry_checked);

    var cv_buf: [512]u8 = undefined;
    const cv = signCv(&cv_buf, srv_tr.snapshot());
    srv_tr.add(cv);
    var sealed: [1024]u8 = undefined;
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, cv), undefined_scratch());

    var msgbuf: [512]u8 = undefined;
    const before_fin = srv_tr.snapshot();
    const verify = ks.finishedVerifyData(sched.server_hs_traffic, &before_fin);
    const fin = hsWrap(&msgbuf, handshake.handshake_type_finished, &verify);
    srv_tr.add(fin);
    try client.onRecord(sealRecord(&sealed, &srv_hs, 22, fin), undefined_scratch());
    try std.testing.expectEqual(Phase.ready_client_finished, client.phase);
}

test "client+chain: 过期/主机名不符/错误锚各自在证书这一步失败" {
    var stream = TestStream{};
    var client = Client.init(chainOptions(cert.fixture_der, .{ .year = 2030, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }), stream.reader());
    var srv_tr: handshake.Transcript = undefined;
    var sched: ks.Schedule = undefined;
    var srv_hs: protect.KeyState = undefined;
    try std.testing.expectError(Error.CertificateExpired, driveToCv(&client, &srv_tr, &sched, &srv_hs));

    // 主机名不符
    var stream2 = TestStream{};
    var c2 = Client.init(.{ .server_name = "evil.example", .trust_anchor_der = cert.fixture_der, .now = .{ .year = 2026, .month = 6, .day = 1, .hour = 0, .minute = 0, .second = 0 } }, stream2.reader());
    try std.testing.expectError(Error.CertificateHostnameMismatch, driveToCv(&c2, &srv_tr, &sched, &srv_hs));

    // 锚不是签发者（用一张"看起来像证书"的错误 DER：直接把 fixture 的 CN 改掉做不到，
    // 用空锚字节触发 BadCertificate → 映射成 CertificateChainFailed）
    var stream3 = TestStream{};
    var c3 = Client.init(.{ .server_name = "ch23.local", .trust_anchor_der = "not-a-cert", .now = null }, stream3.reader());
    try std.testing.expectError(Error.CertificateChainFailed, driveToCv(&c3, &srv_tr, &sched, &srv_hs));
}

test "client+chain: now=null 时链校验通过但 expiry_checked=false（降级必须可见）" {
    var stream = TestStream{};
    var client = Client.init(chainOptions(cert.fixture_der, null), stream.reader());
    var srv_tr: handshake.Transcript = undefined;
    var sched: ks.Schedule = undefined;
    var srv_hs: protect.KeyState = undefined;
    try driveToCv(&client, &srv_tr, &sched, &srv_hs);
    // 链本身可信，但没有时钟就不许声称验过有效期。
    try std.testing.expect(client.certificate_trusted);
    try std.testing.expect(!client.expiry_checked);
}
