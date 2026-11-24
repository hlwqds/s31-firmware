//! wifi-connect：EAP（RFC 3748）与 EAP-TLS（RFC 5216）的主机侧单测（`zig test src/eap_tests.zig`）。
//!
//! 被测的是 `eap.zig` 与 `eap_tls.zig`。这个文件能独立作为测试根；`host_tests.zig` 末尾也 import 了它。
//!
//! 期望值的来源：
//!   * **按规范的图排出来的字节**：EAP 包头（RFC 3748 §4、§4.1 的图）、Success / Failure（§4.2）、
//!     Legacy Nak（§5.3.1）、Expanded Nak（§5.3.2 的图，Length=20）、EAP-TLS 的 Request / Response
//!     （RFC 5216 3.1、3.2 的图）与分片会话图（2.1.5，15–16 页）。注释里写出每个 Length 怎么加出来的。
//!   * **独立 oracle**：`pmkFromMsk` 的已知答案来自 `/tmp/s31-oracle/eap_oracle.py`（Python `hashlib`：
//!     MSK = SHA-512(seed)，PMK = MSK 的前 32 八位组），常量见 `kat_pmk_*`。
//!   * **独立实现（只读对照）**：wpa_supplicant `src/eap_peer/eap_tls_common.c`、`src/eap_peer/eap_common.c`。
//!
//! TLS 引擎是按脚本吐记录 / 吞记录的假引擎（`Script`）。性质测试用测试自己写的参考重组（`RefRx`）和
//! 参考认证器（`converse`），写法与被测代码不同：所有切点、分片长度在上下限两侧的边界都过一遍。

const std = @import("std");

const eap = @import("eap.zig");
const eap_tls = @import("eap_tls.zig");
const vectors = @import("vectors.zig");

const selftest_host = @import("selftest_host.zig");
const eap_selftest = @import("eap_selftest.zig");

const Sha512 = std.crypto.hash.sha2.Sha512;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

/// 编译期解码十六进制字面量。一张表里一次要解码十几个字面量，超过默认的 1000 步分支额度。
fn h(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(20_000);
    return vectors.hex(s);
}

// ---------------------------------------------------------------------------
// 假引擎
// ---------------------------------------------------------------------------

/// 按脚本工作的 TLS 引擎：`pull` 依次吐出 `flights`，`push` 把整段记录抄进 `inbox`。
const Script = struct {
    flights: []const []const u8 = &.{},
    pulled: usize = 0,
    inbox: [8][2048]u8 = undefined,
    inbox_len: [8]usize = @splat(0),
    pushes: usize = 0,
    /// 设了就让下一次 `pull` 吐这段（引擎报错后留下的 TLS alert），只吐一次。
    alert: ?[]const u8 = null,
    /// 设了就让下一次 `push` 失败，只失败一次。
    fail_push: ?anyerror = null,
    /// 收够这么多次 `push`、并且 `flights` 都吐完了，握手才算完成。
    done_after: usize = 1,
    key: [eap_tls.msk_len]u8 = @splat(0),
    resets: usize = 0,

    fn engine(s: *Script) eap_tls.Engine {
        return .{
            .ctx = s,
            .pullFn = pullFn,
            .pushFn = pushFn,
            .doneFn = doneFn,
            .mskFn = mskFn,
            .resetFn = resetFn,
        };
    }

    fn pullFn(ctx: ?*anyopaque, buf: []u8) usize {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        var flight: []const u8 = undefined;
        if (s.alert) |a| {
            s.alert = null;
            flight = a;
        } else {
            if (s.pulled >= s.flights.len) return 0;
            flight = s.flights[s.pulled];
            s.pulled += 1;
        }
        if (flight.len > buf.len) return flight.len; // 放不下：只报长度（引擎契约）
        @memcpy(buf[0..flight.len], flight);
        return flight.len;
    }

    fn pushFn(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        if (s.fail_push) |e| {
            s.fail_push = null;
            return e;
        }
        @memcpy(s.inbox[s.pushes][0..bytes.len], bytes);
        s.inbox_len[s.pushes] = bytes.len;
        s.pushes += 1;
    }

    fn doneFn(ctx: ?*anyopaque) bool {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        return s.pushes >= s.done_after and s.pulled >= s.flights.len;
    }

    fn mskFn(ctx: ?*anyopaque) [eap_tls.msk_len]u8 {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        return s.key;
    }

    fn resetFn(ctx: ?*anyopaque) void {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        s.resets += 1;
    }

    fn pushed(self: *const Script, i: usize) []const u8 {
        return self.inbox[i][0..self.inbox_len[i]];
    }
};

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

fn PeerOf(comptime rx: usize, comptime tx: usize, comptime frag: usize) type {
    return eap.PeerSized(.{ .tls = .{ .rx_max = rx, .tx_max = tx, .fragment = frag } });
}

/// 已知答案用的 peer：重组 / 发送缓冲 256，每片 TLS 数据 16 八位组。
const Kat = PeerOf(256, 256, 16);

/// 把 EAP 包封进 EAPOL-EAP 帧（版本 2）。
fn fr(comptime eap_hex: []const u8) [eap_hex.len / 2 + 4]u8 {
    const pkt = h(eap_hex);
    var out: [pkt.len + 4]u8 = undefined;
    out[0] = 2;
    out[1] = 0;
    out[2] = @truncate(pkt.len >> 8);
    out[3] = @truncate(pkt.len);
    @memcpy(out[4..], &pkt);
    return out;
}

fn expectFrame(got: []const u8, comptime want_hex: []const u8) !void {
    try expectEqualSlices(u8, &h(want_hex), got);
}

/// 取出 peer 响应里的 EAP-TLS Type-Data（Flags 起），顺带核对 Code / Identifier / Type。
fn tlsData(resp: []const u8, want_id: u8) ![]const u8 {
    const p = try eap.parse(resp);
    try expectEqual(eap.Code.response, p.code);
    try expectEqual(want_id, p.id);
    try expect(p.data.len >= 2);
    try expectEqual(@as(u8, 13), p.data[0]);
    return p.data[1..];
}

/// 把一个 EAP 包封成帧交给 peer，返回它的响应（EAP 包）。没有响应时返回空切片。
fn sendTo(peer: anytype, out: []u8, pkt: []const u8) ![]const u8 {
    var frame: [4096]u8 = undefined;
    const n = try eap.eapolWrap(&frame, pkt);
    const m = try peer.onFrame(frame[0..n], out);
    if (m == 0) return out[0..0];
    return try eap.eapolBody(out[0..m]);
}

/// 测试自己写的参考重组：只认 Flags 的 L / M 位，不 import 被测的 `Rx`。
const RefRx = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    total: usize = 0,
    /// 每一片的 Flags 八位组。
    flags: [2048]u8 = @splat(0),
    count: usize = 0,

    fn feed(self: *RefRx, td: []const u8) !bool {
        const flags = td[0];
        var d = td[1..];
        if (flags & 0x80 != 0) {
            self.total = std.mem.readInt(u32, d[0..4], .big);
            d = d[4..];
        }
        try expect(flags & 0x20 == 0); // peer 永远不发 Start
        try expect(flags & 0x1f == 0); // 保留位必须置 0
        self.flags[self.count] = flags;
        self.count += 1;
        @memcpy(self.buf[self.len..][0..d.len], d);
        self.len += d.len;
        if (flags & 0x40 != 0) return false;
        try expectEqual(if (self.total == 0) self.len else self.total, self.len);
        return true;
    }
};

/// 收齐 peer 的一段记录：带 M 就回一个空 Request 要下一片（RFC 5216 2.1.5 的认证器一侧）。
fn collectFlight(peer: anytype, out: []u8, first: []const u8, id: *u8, sink: *RefRx) !void {
    var resp = first;
    while (true) {
        if (try sink.feed(try tlsData(resp, id.*))) return;
        id.* +%= 1;
        resp = try sendTo(peer, out, &[_]u8{ 1, id.*, 0, 6, 13, 0 });
    }
}

/// 运行期拼一个 Request/EAP-TLS：`typedata` 是从 Flags 起的八位组。
fn tlsRequest(out: []u8, id: u8, typedata: []const u8) []const u8 {
    out[0] = 1;
    out[1] = id;
    out[4] = 13;
    @memcpy(out[5..][0..typedata.len], typedata);
    const eap_len = 5 + typedata.len;
    std.mem.writeInt(u16, out[2..4], @intCast(eap_len), .big);
    return out[0..eap_len];
}

/// 参考实现的分片编码：`Code Id Length Type Flags [Total] Data`。
fn serverFragment(out: []u8, id: u8, data: []const u8, total: ?usize, more: bool) []const u8 {
    out[0] = 1;
    out[1] = id;
    out[4] = 13;
    out[5] = (if (total != null) @as(u8, 0x80) else 0) | (if (more) @as(u8, 0x40) else 0);
    var n: usize = 6;
    if (total) |t| {
        std.mem.writeInt(u32, out[6..10], @intCast(t), .big);
        n = 10;
    }
    @memcpy(out[n..][0..data.len], data);
    n += data.len;
    std.mem.writeInt(u16, out[2..4], @intCast(n), .big);
    return out[0..n];
}

/// 随机选 0–14 个互不相同的切点，升序返回。
fn randomCuts(rand: std.Random, len: usize, cuts: *[15]usize) []const usize {
    const k = rand.intRangeAtMost(usize, 1, @min(len, cuts.len + 1));
    var n: usize = 0;
    while (n < k - 1) {
        const c = rand.intRangeLessThan(usize, 1, len);
        var dup = false;
        for (cuts[0..n]) |x| {
            if (x == c) dup = true;
        }
        if (!dup) {
            cuts[n] = c;
            n += 1;
        }
    }
    // 切点最多 14 个：插入排序够用。
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and cuts[j - 1] > cuts[j]) : (j -= 1) std.mem.swap(usize, &cuts[j - 1], &cuts[j]);
    }
    return cuts[0..n];
}

// ---------------------------------------------------------------------------
// 已知答案用的记录流：客户端两段（0x00–0x27、0x30–0x57），服务端一段（0xa0–0xc7），每段 40 八位组
// ---------------------------------------------------------------------------

const s0_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222324252627";
const s1_hex = "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f5051525354555657";
const r0_hex = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf";
const r1_hex = "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf";
const r2_hex = "c0c1c2c3c4c5c6c7";
const r_hex = r0_hex ++ r1_hex ++ r2_hex;

// ---------------------------------------------------------------------------
// PMK 已知答案：/tmp/s31-oracle/eap_oracle.py（hashlib），seed = "s31-eap-pmk-<n>"
// MSK = SHA-512(seed)，PMK = MSK 的前 32 八位组
// ---------------------------------------------------------------------------

const kat_pmk_0: [32]u8 = h("46816feb0ecbe9be2732e489a68ff5015086a3ec7370a1b61750b3f6688b1151");
const kat_pmk_1: [32]u8 = h("5463564b61d228f212afaa146bea460417983db09ef586cb0a4fca09a4d0241f");
const kat_pmk_2: [32]u8 = h("1fab0bbe3b2f6ea2e9156eb46f8d4afc555bc06f95e7e93e9ad82b339f1e69f9");
const kat_pmk_3: [32]u8 = h("8692d293a460e778aa7858934eb4f5c76e3bdf7840e5a524a1687f0add33c41a");
const kat_pmk_4: [32]u8 = h("022e427fc0b16a1969625709af13e4eb99ca140ac479b1ce49922e5f7a817ea0");
const kat_pmk_5: [32]u8 = h("cb62999236fcd33f8a808a7e8d56b0cc4b648591c37a50d4837636e2ef7f7562");
const kat_pmk_6: [32]u8 = h("f80d857234eade0973ebf0eb4ba07efcf379fad9296e92d301cb71c084395d0e");
const kat_pmk_7: [32]u8 = h("67cee6fb4be53318ffc00074f4cd7bcf2338b12cce006c1ccd8bb92dd93bd52d");

// ---------------------------------------------------------------------------
// EAP 包头（RFC 3748 §4、§4.1）
// ---------------------------------------------------------------------------

test "eap parse: Code / Identifier / Length, padding ignored, bad Code / Length rejected (RFC 3748 4)" {
    // Request/Identity，带可显示的消息 "Test\0"：Length = 4 + 1 + 5 = 10。后面的 de ad be ef 是链路层填充。
    const pkt = h("0101000a015465737400" ++ "deadbeef");
    const p = try eap.parse(&pkt);
    try expectEqual(eap.Code.request, p.code);
    try expectEqual(@as(u8, 1), p.id);
    try expectEqual(@as(u16, 10), p.length);
    try expectEqualSlices(u8, &h("015465737400"), p.data);

    // Length 之外是填充：改成什么都不影响。
    var padded = pkt;
    @memset(padded[10..], 0xff);
    try expectEqualSlices(u8, p.data, (try eap.parse(&padded)).data);

    try expectError(error.EapLength, eap.parse(pkt[0..9])); // Length 10 > 收到的 9：MUST be silently discarded
    try expectError(error.EapTooShort, eap.parse(pkt[0..3]));
    try expectError(error.EapLength, eap.parse(&h("01000301"))); // Length 3 连头都装不下
    for ([_]u8{ 0, 5, 255 }) |code| try expectError(error.EapCode, eap.parse(&[_]u8{ code, 1, 0, 4 }));

    // Success：只有 4 八位组的头（§4.2：Length 4）。
    const s = try eap.parse(&h("030c0004"));
    try expectEqual(eap.Code.success, s.code);
    try expectEqual(@as(u8, 0x0c), s.id);
    try expectEqual(@as(u16, 4), s.length);
    try expectEqual(@as(usize, 0), s.data.len);
    try expectEqual(eap.Code.failure, (try eap.parse(&h("04010004"))).code);
    try expectEqual(eap.Code.response, (try eap.parse(&h("0201000501"))).code);
}

// ---------------------------------------------------------------------------
// EAPOL-EAP 帧
// ---------------------------------------------------------------------------

test "eapol wrap known answer: Version=2, Type=EAP-Packet, Body Length = EAP packet length" {
    // EAP-Response/Identity "user@example.com"：Length = 4 + 1 + 16 = 21。
    const resp = h("0201001501" ++ "75736572406578616d706c652e636f6d");
    var out: [64]u8 = undefined;
    const n = try eap.eapolWrap(&out, &resp);
    // 包体长度 0x0015 不含 EAPOL 头的 4 个八位组。
    try expectFrame(out[0..n], "0200" ++ "0015" ++ "0201001501" ++ "75736572406578616d706c652e636f6d");
    try expectEqual(@as(usize, 25), n);
    try expectError(error.NoBufferSpace, eap.eapolWrap(out[0..24], &resp));
}

test "eapol parse: body length cuts the body, trailing octets ignored, versions 1 and 2 accepted" {
    // Version=1 的帧，包体是 EAP-Success（4 八位组），后面 2 个填充。
    const frame = h("01" ++ "00" ++ "0004" ++ "03070004" ++ "ffff");
    try expectEqualSlices(u8, &h("03070004"), try eap.eapolBody(&frame));
    try expectEqualSlices(u8, &h("03070004"), try eap.eapolBody(frame[0..8]));
    try expectEqualSlices(u8, &h("03070004"), try eap.eapolBody(&fr("03070004")));
    try expectEqual(@as(usize, 0), (try eap.eapolBody(&h("02000000"))).len); // 包体长度 0

    try expectError(error.EapolVersion, eap.eapolBody(&h("0000000403070004")));
    try expectError(error.EapolVersion, eap.eapolBody(&h("0300000403070004")));
    try expectError(error.EapolType, eap.eapolBody(&h("02010000"))); // EAPOL-Start
    try expectError(error.EapolType, eap.eapolBody(&h("0203005c"))); // EAPOL-Key
    try expectError(error.EapolLength, eap.eapolBody(frame[0..7])); // 声明 4，只有 3
    try expectError(error.EapolTooShort, eap.eapolBody(frame[0..3]));

    // Version 1、2 的帧 peer 都收；Version 3 拒绝。
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    var v1 = fr("0101000501");
    v1[0] = 1;
    try expectFrame(out[0..try peer.onFrame(&v1, &out)], "02000006020100060175");
    try expectFrame(out[0..try peer.onFrame(&fr("0102000501"), &out)], "02000006020200060175");
    var v3 = fr("0103000501");
    v3[0] = 3;
    try expectError(error.EapolVersion, peer.onFrame(&v3, &out));
    const key_frame = h("0203000403080004"); // Packet Type 3（EAPOL-Key）不归 peer
    try expectError(error.EapolType, peer.onFrame(&key_frame, &out));
}

// ---------------------------------------------------------------------------
// Identity / Notification / Nak（RFC 3748 §5.1、§5.2、§5.3）
// ---------------------------------------------------------------------------

test "identity round trip: Request with message -> Response carries the configured identity, no NUL (RFC 3748 5.1)" {
    var script = Script{};
    var peer = Kat.init("user@example.com", script.engine());
    var out: [64]u8 = undefined;
    // Request/Identity（id 1），消息 "Test\0"：Length = 4 + 1 + 5 = 10。
    const n = try peer.onFrame(&fr("0101000a015465737400"), &out);
    // Response/Identity：Length = 4 + 1 + 16 = 21，Type-Data 是 "user@example.com"，不以 NUL 结尾。
    try expectFrame(out[0..n], "02000015" ++ "0201001501" ++ "75736572406578616d706c652e636f6d");
    try expectEqual(eap.State.idle, peer.state());
    try expectEqual(eap.Status.idle, peer.status());
    try expectEqual(@as(usize, 0), script.pulled); // Identity 不碰引擎

    // 空 Identity（Identity 未知）：Type-Data 0 八位组，Length = 5。
    var empty = Kat.init("", script.engine());
    try expectFrame(out[0..try empty.onFrame(&fr("01ff000501"), &out)], "0200000502ff000501");
}

test "identity: too long or NUL-terminated identity rejected, 1020-octet Response accepted (RFC 3748 5.1)" {
    var script = Script{};
    var out: [2048]u8 = undefined;
    var ok: [eap.identity_max]u8 = @splat('a');
    var peer = Kat.init(&ok, script.engine());
    // Length = 1020：RFC 说的上限。
    const n = try peer.onFrame(&fr("0101000501"), &out);
    try expectEqual(@as(usize, 4 + eap.identity_response_max), n);
    try expectEqual(@as(u16, 1020), std.mem.readInt(u16, out[6..8], .big));
    try expectEqual(@as(u8, 2), out[0]); // 仍封在 EAPOL 里

    var long: [eap.identity_max + 1]u8 = @splat('a');
    var bad = Kat.init(&long, script.engine());
    try expectError(error.IdentityInvalid, bad.onFrame(&fr("0101000501"), &out));
    try expectEqual(@as(usize, 0), bad.prev_resp_len);

    var nul = Kat.init("user\x00", script.engine());
    try expectError(error.IdentityInvalid, nul.onFrame(&fr("0101000501"), &out));
    // NUL 在中间不算结尾。
    var mid = Kat.init("user\x00name", script.engine());
    try expectEqual(@as(usize, 4 + 4 + 1 + 9), try mid.onFrame(&fr("0101000501"), &out));
}

test "notification: Request 'Password expires' -> Notification Response with zero Type-Data (RFC 3748 5.2)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    // Request/Notification（id 6）：Length = 4 + 1 + 16 = 21。
    const n = try peer.onFrame(&fr("01060015" ++ "02" ++ "50617373776f72642065787069726573"), &out);
    // Response/Notification：Length = 4 + 1 = 5。
    try expectFrame(out[0..n], "020000050206000502");
    try expectEqual(eap.State.idle, peer.state()); // 不改 peer 的状态

    // 0 八位组的消息不符合 5.2 的「greater than zero octets in length」。
    try expectError(error.NotificationEmpty, peer.onFrame(&fr("0107000502"), &out));
    try expectEqual(@as(usize, 0), peer.prev_resp_len); // 被丢弃的 Request 顶掉了上一个 Response
}

test "legacy nak: unsupported MD5-Challenge -> Nak listing EAP-TLS (RFC 3748 5.3.1)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    // Request/MD5-Challenge（Type 4，id 2）：Length = 4 + 1 + 16 = 21。
    var n = try peer.onFrame(&fr("01020015" ++ "04" ++ "0102030405060708090a0b0c0d0e0f1011121314"), &out);
    // Nak：Type 3，Type-Data 是一个期望的 Type（13），Length = 4 + 1 + 1 = 6。
    try expectFrame(out[0..n], "0200000602020006030d");
    try expectEqual(eap.State.idle, peer.state());

    // 5.3.1 列的不可接受范围是 4-253、255；下界、253、255 各试一个（Length = 4 + 1 = 5）。
    n = try peer.onFrame(&fr("0103000504"), &out);
    try expectFrame(out[0..n], "0200000602030006030d");
    n = try peer.onFrame(&fr("01040005fd"), &out); // 253
    try expectFrame(out[0..n], "0200000602040006030d");
    n = try peer.onFrame(&fr("01050005ff"), &out); // 255
    try expectFrame(out[0..n], "0200000602050006030d");
}

test "expanded types: EAP-TLS requested in expanded form is accepted and answered in expanded form (RFC 3748 5.7)" {
    const s0 = h(s0_hex);
    const flights = [_][]const u8{&s0};
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    // 254 | Vendor-Id 0 (IETF) | Vendor-Type 13 | Flags=S：Length = 4 + 8 + 1 = 13。
    const n = try peer.onFrame(&fr("0104000d" ++ "fe" ++ "000000" ++ "0000000d" ++ "20"), &out);
    // Response 照 Expanded 形式：Length = 4 + 8 + (1 + 4 + 16) = 33。
    try expectFrame(out[0..n], "02000021" ++ "02040021" ++ "fe" ++ "000000" ++ "0000000d" ++ "c000000028" ++
        "000102030405060708090a0b0c0d0e0f");
    try expectEqual(eap.State.method, peer.state());
    // 截断的 Expanded 头（不足 Vendor-Id 3 + Vendor-Type 4）被拒。
    try expectError(error.BadExpanded, peer.onFrame(&fr("0105000a" ++ "fe0000000000"), &out));
    // Vendor-Id 不是 0：不是 IETF 的 EAP-TLS。
    try expectError(error.UnexpectedRequest, peer.onFrame(&fr("0106000c" ++ "fe" ++ "000009" ++ "0000000d"), &out));
}

test "expanded nak: unacceptable Expanded Type -> Expanded Nak in IETF form, Length=20 (RFC 3748 5.3.2)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    // 254 | Vendor-Id 9 | Vendor-Type 1：Length = 4 + 8 = 12。
    var n = try peer.onFrame(&fr("0103000c" ++ "fe" ++ "000009" ++ "00000001"), &out);
    // 5.3.2 的图：Code 2 | Identifier | Length=20 | Type=254 | 0 (IETF) | 3 (Nak)，
    // 后面跟期望的 Type（每个 8 八位组，全是 Expanded 形式）：254 | 0 (IETF) | 13。
    try expectFrame(out[0..n], "02000014" ++ "02030014" ++ "fe000000" ++ "00000003" ++ "fe000000" ++ "0000000d");
    try expectEqual(eap.State.idle, peer.state());
    // Vendor-Id 是 0、但 Vendor-Type 不是 13（这里 300）：同样回 Expanded Nak。
    n = try peer.onFrame(&fr("0104000c" ++ "fe" ++ "000000" ++ "0000012c"), &out);
    try expectFrame(out[0..n], "02000014" ++ "02040014" ++ "fe000000" ++ "00000003" ++ "fe000000" ++ "0000000d");
}

test "nak never appears in a Request; Type 0 is not a method (RFC 3748 5, 5.7)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    try expectError(error.NakInRequest, peer.onFrame(&fr("0101000603" ++ "00"), &out));
    try expectError(error.NakInRequest, peer.onFrame(&fr("0101000c" ++ "fe000000" ++ "00000003"), &out));
    try expectError(error.NoType, peer.onFrame(&fr("0101000500"), &out));
    try expectError(error.NoType, peer.onFrame(&fr("01010004"), &out)); // Length 4：没有 Type
    try expectError(error.EapResponse, peer.onFrame(&fr("0201000501"), &out)); // peer 不处理 Response
    try expectEqual(@as(usize, 0), peer.prev_resp_len);
}

// ---------------------------------------------------------------------------
// EAP-TLS 已知答案（RFC 5216 2.1.1、2.1.5、3.1、3.2）
// ---------------------------------------------------------------------------

test "eap-tls known answer: Start -> ClientHello in 3 fragments, first with L (RFC 5216 2.1.5, 3.2)" {
    const s0 = h(s0_hex);
    const flights = [_][]const u8{&s0};
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u@example.com", script.engine());
    var out: [128]u8 = undefined;

    // EAP-TLS Start（id 5）：Code 1、Type 13、Flags=S=0x20、无数据。Length = 4 + 1 + 1 = 6。
    var n = try peer.onFrame(&fr("010500060d20"), &out);
    // 分片 1：Flags = L|M = 0xc0，TLS Message Length = 40 = 0x28，数据 16 八位组。
    // Length = 4 (EAP 头) + 1 (Type) + 1 (Flags) + 4 (Message Length) + 16 = 26 = 0x001a。
    try expectFrame(out[0..n], "0200001a" ++ "0205001a" ++ "0dc000000028" ++ "000102030405060708090a0b0c0d0e0f");
    try expectEqual(eap.State.method, peer.state());
    try expectEqual(eap.Status.in_progress, peer.status());

    // 对端对我方分片的确认：Flags=0、无数据。Identifier 逐片递增，响应带同一个 Identifier（2.1.5）。
    n = try peer.onFrame(&fr("010600060d00"), &out);
    // 分片 2：Flags = M = 0x40。Length = 4 + 1 + 1 + 16 = 22 = 0x0016。
    try expectFrame(out[0..n], "02000016" ++ "02060016" ++ "0d40" ++ "101112131415161718191a1b1c1d1e1f");

    n = try peer.onFrame(&fr("010700060d00"), &out);
    // 最后一片：Flags = 0，不带 L。Length = 4 + 1 + 1 + 8 = 14 = 0x000e。
    try expectFrame(out[0..n], "0200000e" ++ "0207000e" ++ "0d00" ++ "2021222324252627");
    try expect(!peer.tls.txPending());
    try expect(!peer.tls.handshakeDone()); // 引擎还没收到服务端那一段

    // 发完之后对端再发一个空包：我方没有待发的分片，回空包（Flags=0）。
    n = try peer.onFrame(&fr("010800060d00"), &out);
    try expectFrame(out[0..n], "02000006020800060d00");
}

test "eap-tls known answer: server flight in 3 fragments, empty ACK per M fragment, then EAP-Success (RFC 5216 2.1.5)" {
    const s0 = h(s0_hex);
    const s1 = h(s1_hex);
    const flights = [_][]const u8{ &s0, &s1 };
    var script = Script{ .flights = &flights };
    for (&script.key, 0..) |*b, i| b.* = @truncate(i);
    var peer = Kat.init("u@example.com", script.engine());
    var out: [128]u8 = undefined;
    for ([_][]const u8{ &fr("010500060d20"), &fr("010600060d00"), &fr("010700060d00") }) |req| {
        _ = try peer.onFrame(req, &out);
    }

    // 服务端分片 1（id 8）：Flags L|M，总长 40。Length = 4 + 1 + 1 + 4 + 16 = 26。
    var n = try peer.onFrame(&fr("0108001a" ++ "0dc000000028" ++ r0_hex), &out);
    // 「an EAP-Response with EAP-Type=EAP-TLS and no data」：Length = 6。
    try expectFrame(out[0..n], "02000006020800060d00");
    // 分片 2（id 9）：Flags M。Length = 4 + 1 + 1 + 16 = 22。
    n = try peer.onFrame(&fr("01090016" ++ "0d40" ++ r1_hex), &out);
    try expectFrame(out[0..n], "02000006020900060d00");
    try expectEqual(@as(usize, 0), script.pushes); // 没收齐不交给引擎
    try expect(peer.tls.rx.busy());

    // 最后一片（id 10）：Flags 0。Length = 4 + 1 + 1 + 8 = 14。
    n = try peer.onFrame(&fr("010a000e" ++ "0d00" ++ r2_hex), &out);
    try expectEqual(@as(usize, 1), script.pushes);
    try expectEqualSlices(u8, &h(r_hex), script.pushed(0));
    try expect(!peer.tls.rx.busy());
    // 引擎的第二段记录（0x30–0x57）切成 3 片发回，首片带 L。
    try expectFrame(out[0..n], "0200001a" ++ "020a001a" ++ "0dc000000028" ++
        "303132333435363738393a3b3c3d3e3f");
    n = try peer.onFrame(&fr("010b00060d00"), &out);
    try expectFrame(out[0..n], "02000016" ++ "020b0016" ++ "0d40" ++ "404142434445464748494a4b4c4d4e4f");
    n = try peer.onFrame(&fr("010c00060d00"), &out);
    try expectFrame(out[0..n], "0200000e" ++ "020c000e" ++ "0d00" ++ "5051525354555657");
    try expect(peer.tls.handshakeDone());

    // EAP-Success：Code 3、Length 4，Identifier 是它所应答的那个 Response 的（§4.2）。
    n = try peer.onFrame(&fr("030c0004"), &out);
    try expectEqual(@as(usize, 0), n);
    try expectEqual(eap.State.success, peer.state());
    try expectEqual(eap.Status.succeeded, peer.status());
    try expectEqualSlices(u8, &script.key, &peer.msk());
    try expectEqualSlices(u8, script.key[0..32], &peer.pmk());
}

// ---------------------------------------------------------------------------
// Flags 与长度检查（RFC 5216 2.1.5、3.1、3.2）
// ---------------------------------------------------------------------------

test "flags: L=0x80 M=0x40 S=0x20; reserved bits ignored on receive, zero on send (RFC 5216 3.1, 3.2)" {
    const all = eap_tls.Flags.parse(0xe0);
    try expect(all.length_included and all.more and all.start);
    try expectEqual(@as(u8, 0xe0), all.encode());
    const none = eap_tls.Flags.parse(0x1f);
    try expect(!none.length_included and !none.more and !none.start);
    try expectEqual(@as(u8, 0), none.encode()); // 保留位写 0
    try expectEqual(@as(u8, 0xc0), (eap_tls.Flags{ .length_included = true, .more = true }).encode());

    // Type-Data 的两种排法（3.2 的图：Flags | TLS Message Length | TLS Data）。
    var buf: [16]u8 = undefined;
    try expectEqual(@as(usize, 1), try eap_tls.encodeTypeData(&buf, .{ .data = "" }));
    try expectFrame(buf[0..1], "00");
    try expectEqual(@as(usize, 8), try eap_tls.encodeTypeData(&buf, .{
        .data = &h("aabbcc"),
        .total = 0x01020304,
        .length_included = true,
        .more = true,
    }));
    try expectFrame(buf[0..8], "c0" ++ "01020304" ++ "aabbcc");
    try expectError(error.NoBufferSpace, eap_tls.encodeTypeData(buf[0..7], .{
        .data = &h("aabbcc"),
        .total = 1,
        .length_included = true,
    }));

    // 保留位置了也照常处理：Start（S|R）、确认（R）、带 L 的整段（L|R）。
    const s0 = h(s0_hex);
    const flights = [_][]const u8{&s0};
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    var n = try peer.onFrame(&fr("01050006" ++ "0d3f"), &out); // S + 保留位全 1
    try expectFrame(out[0..n], "0200001a" ++ "0205001a" ++ "0dc000000028" ++
        "000102030405060708090a0b0c0d0e0f");
    n = try peer.onFrame(&fr("01060006" ++ "0d1f"), &out); // 确认 + 保留位
    try expectFrame(out[0..n], "02000016" ++ "02060016" ++ "0d40" ++ "101112131415161718191a1b1c1d1e1f");
    n = try peer.onFrame(&fr("01070006" ++ "0d1f"), &out);
    try expectFrame(out[0..n], "0200000e" ++ "0207000e" ++ "0d00" ++ "2021222324252627");
    // 不带 L 的单条消息，保留位置了：原样交给引擎。Length = 4 + 1 + 1 + 8 = 14。
    n = try peer.onFrame(&fr("0108000e" ++ "0d1f" ++ "2021222324252627"), &out);
    try expectFrame(out[0..n], "02000006020800060d00"); // 引擎没有下一段，回空包
    try expectEqualSlices(u8, s0[32..40], script.pushed(0));
    // 服务端整段带 L、保留位也置了：Length = 4 + 1 + 1 + 4 + 40 = 50。
    n = try peer.onFrame(&fr("01090032" ++ "0d9f" ++ "00000028" ++ r_hex), &out);
    try expectEqual(@as(usize, 2), script.pushes);
    try expectEqualSlices(u8, &h(r_hex), script.pushed(1));
}

test "bad flags rejected: Start with L / M / data, M without L, missing Flags octet (RFC 5216 2.1.1, 2.1.5)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    // Start 必须是 S 位置位、无数据。
    try expectError(error.BadFlags, peer.onFrame(&fr("01010006" ++ "0d60"), &out)); // S|M
    try expectError(error.BadFlags, peer.onFrame(&fr("01010006" ++ "0da0"), &out)); // S|L
    try expectError(error.BadFlags, peer.onFrame(&fr("01010006" ++ "0de0"), &out)); // S|L|M
    try expectError(error.BadFlags, peer.onFrame(&fr("01010007" ++ "0d20" ++ "01"), &out)); // S + 1 八位组数据
    try expectError(error.BadFlags, peer.onFrame(&fr("0101000a" ++ "0da0" ++ "00000001"), &out)); // S|L + 长度字段
    // 首片带 M 却没有 L：不知道总长，没法重组。Length = 4 + 1 + 1 + 32 = 38。
    try expectError(error.BadFlags, peer.onFrame(&fr("01020026" ++ "0d40" ++ r0_hex ++ r1_hex), &out));
    // 没有 Flags 八位组。
    try expectError(error.BadFlags, peer.onFrame(&fr("010300050d"), &out));
    try expectEqual(eap.State.idle, peer.state());
    try expectEqual(@as(usize, 0), script.pulled);
    try expectEqual(@as(usize, 0), peer.prev_resp_len);
}

test "bad length rejected: TLS Message Length must match the fragments (RFC 5216 2.1.5, 3.1)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    // L 字段不足 4 八位组。
    try expectError(error.BadLength, peer.onFrame(&fr("01010008" ++ "0d80" ++ "0000"), &out));
    // 声明总长为 0 却带着数据。
    try expectError(error.BadLength, peer.onFrame(&fr("0101000e" ++ "0d80" ++ "00000000" ++ "a0a1a2a3"), &out));
    // 声明 40，首片就送了 40 以上却还带 M。
    try expectError(error.BadLength, peer.onFrame(&fr("010100320dc000000028" ++ r_hex), &out));
    // 声明 32，一片刚好送满，却还带 M。
    try expectError(error.BadLength, peer.onFrame(&fr("0102002a0dc000000020" ++ r0_hex ++ r1_hex), &out));
    // 声明 40，一片只送 32，却没带 M。
    try expectError(error.BadLength, peer.onFrame(&fr("0103002a0d8000000028" ++ r0_hex ++ r1_hex), &out));
    // 带 L 却没有数据。
    try expectError(error.BadLength, peer.onFrame(&fr("0104000a" ++ "0d80" ++ "00000028"), &out));

    // 续片：超出剩余、提前结束、空片。每条之后重组状态都清掉。
    const first = fr("0101001a" ++ "0dc000000028" ++ r0_hex);
    _ = try peer.onFrame(&first, &out);
    // 24 + 1 = 25 八位组：Length = 4 + 1 + 1 + 25 = 31。
    try expectError(error.BadLength, peer.onFrame(&fr("0102001f" ++ "0d00" ++ r1_hex ++ r2_hex ++ "00"), &out));
    try expect(!peer.tls.rx.busy());
    _ = try peer.onFrame(&first, &out);
    try expectError(error.BadLength, peer.onFrame(&fr("01030016" ++ "0d00" ++ r1_hex), &out));
    try expect(!peer.tls.rx.busy());
    _ = try peer.onFrame(&first, &out);
    // 重组到一半时收到空包：既不是续片，也不是有意义的确认。
    try expectError(error.BadLength, peer.onFrame(&fr("010400060d00"), &out));
    try expect(!peer.tls.rx.busy());
    try expectEqual(@as(usize, 0), script.pushes);
}

test "continuation fragment may repeat L only with the same total (RFC 5216 2.1.5)" {
    var script = Script{};
    var out: [64]u8 = undefined;
    var peer = Kat.init("u", script.engine());
    _ = try peer.onFrame(&fr("0101001a" ++ "0dc000000028" ++ r0_hex), &out);
    // 续片带 L、总长一致：收下。Length = 4 + 1 + 1 + 4 + 16 = 26。
    const n = try peer.onFrame(&fr("0102001a" ++ "0dc0" ++ "00000028" ++ r1_hex), &out);
    try expectFrame(out[0..n], "02000006020200060d00");
    try expect(peer.tls.rx.busy());

    var other = Kat.init("u", script.engine());
    _ = try other.onFrame(&fr("0101001a" ++ "0dc000000028" ++ r0_hex), &out);
    // 续片带 L、总长对不上：拒绝。
    try expectError(error.BadLength, other.onFrame(&fr("0102001a" ++ "0dc0" ++ "00000030" ++ r1_hex), &out));
    try expect(!other.tls.rx.busy());
}

// ---------------------------------------------------------------------------
// 缓冲边界
// ---------------------------------------------------------------------------

test "rx buffer: declared total above the buffer is rejected before copying; exactly the buffer size is fine" {
    var out: [512]u8 = undefined;
    var req: [600]u8 = undefined;
    var td: [32]u8 = undefined;
    var script = Script{};
    var peer = PeerOf(256, 256, 16).init("u", script.engine());
    _ = try sendTo(&peer, &out, tlsRequest(&req, 5, &[_]u8{0x20})); // Start，引擎没给记录

    // 重组缓冲 256：声明 257 → RxTooLong，这一片的数据一个都不收。
    td[0] = 0xc0;
    std.mem.writeInt(u32, td[1..5], 257, .big);
    @memset(td[5..21], 0x5a);
    try expectError(error.RxTooLong, sendTo(&peer, &out, tlsRequest(&req, 6, td[0..21])));
    try expect(!peer.tls.rx.busy());
    try expectEqual(@as(usize, 0), peer.prev_resp_len);

    // 正好 256：首片 16（M）+ 续片 240，整段交给引擎。
    var flight: [256]u8 = undefined;
    for (&flight, 0..) |*b, i| b.* = @truncate(i * 7);
    var resp = try sendTo(&peer, &out, serverFragment(&req, 7, flight[0..16], 256, true));
    try expectEqualSlices(u8, &h("020700060d00"), resp);
    try expect(peer.tls.rx.busy());
    resp = try sendTo(&peer, &out, serverFragment(&req, 8, flight[16..], null, false));
    try expectEqualSlices(u8, &h("020800060d00"), resp);
    try expectEqual(@as(usize, 1), script.pushes);
    try expectEqualSlices(u8, &flight, script.pushed(0));
    try expectEqual(@as(usize, 256), eap_tls.RxSized(256).capacity);
}

test "output buffer too small: NoBufferSpace; the built Response is resent when the Request is retransmitted" {
    const s0 = h(s0_hex);
    const flights = [_][]const u8{&s0};
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u", script.engine());
    var small: [10]u8 = undefined;
    // 整帧 30 八位组（EAPOL 头 4 + EAP 26）。
    try expectError(error.NoBufferSpace, peer.onFrame(&fr("010500060d20"), &small));
    try expectEqual(@as(usize, 26), peer.prev_resp_len); // Response 已经拼好
    try expectEqual(@as(usize, 1), script.pulled);
    // 同一个 Start 重传（Identifier 不变）：原样重发，引擎不再被碰。
    var out: [128]u8 = undefined;
    const n = try peer.onFrame(&fr("010500060d20"), &out);
    try expectFrame(out[0..n], "0200001a" ++ "0205001a" ++ "0dc000000028" ++
        "000102030405060708090a0b0c0d0e0f");
    try expectEqual(@as(usize, 1), script.pulled);
    try expectEqual(@as(usize, 0), script.resets);
}

test "engine flight larger than the send buffer: TxTooLong" {
    var flight: [300]u8 = @splat(0x33);
    const flights = [_][]const u8{&flight};
    var script = Script{ .flights = &flights };
    var peer = PeerOf(256, 256, 16).init("u", script.engine());
    var out: [128]u8 = undefined;
    try expectError(error.TxTooLong, peer.onFrame(&fr("010500060d20"), &out));
    try expectEqual(@as(usize, 0), peer.prev_resp_len);
    try expect(!peer.tls.txPending());
}

// ---------------------------------------------------------------------------
// 本端判失败之后（RFC 5216 2.1.3）
// ---------------------------------------------------------------------------

test "data while our fragments are pending: local failure, empty response, Failure accepted afterwards (RFC 5216 2.1.3, 2.1.5)" {
    const s0 = h(s0_hex);
    const flights = [_][]const u8{&s0};
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    var req: [128]u8 = undefined;
    const r = h(r_hex);
    _ = try peer.onFrame(&fr("010500060d20"), &out); // 我方分片 1 已发，还欠 2 片

    // 对端不等确认就送来数据。
    var resp = try sendTo(&peer, &out, serverFragment(&req, 6, &r, 40, false));
    try expectEqualSlices(u8, &h("020600060d00"), resp);
    try expectEqual(eap.Status.failed, peer.status());
    try expectEqual(@as(?eap_tls.Failure, .data_while_sending), peer.tls.failure);
    try expectEqual(@as(usize, 0), script.pushes); // 没交给引擎
    try expect(!peer.tls.txPending()); // 欠着的分片作废

    // 判失败之后对端再送数据：不交给引擎，回空响应。
    resp = try sendTo(&peer, &out, serverFragment(&req, 7, &r, 40, false));
    try expectEqualSlices(u8, &h("020700060d00"), resp);
    try expectEqual(@as(usize, 0), script.pushes);

    // 此时 EAP-Success 不该信；EAP-Failure 收下。
    try expectError(error.SuccessNotAllowed, peer.onFrame(&fr("03070004"), &out));
    try expectEqual(@as(usize, 0), try peer.onFrame(&fr("04070004"), &out));
    try expectEqual(eap.State.failure, peer.state());
    try expectEqual(eap.Status.failed, peer.status());
}

test "engine failure: empty response, or the engine's alert (fragmented); later Success discarded (RFC 5216 2.1.3)" {
    var out: [128]u8 = undefined;
    var req: [128]u8 = undefined;
    const r = h(r_hex);

    // (a) 引擎拒收、没有留下记录：回空的 EAP-TLS 响应。
    var script = Script{ .fail_push = error.BadFinished };
    var peer = Kat.init("u", script.engine());
    _ = try sendTo(&peer, &out, tlsRequest(&req, 5, &[_]u8{0x20}));
    _ = try sendTo(&peer, &out, serverFragment(&req, 6, r[0..16], 40, true));
    _ = try sendTo(&peer, &out, serverFragment(&req, 7, r[16..32], null, true));
    var resp = try sendTo(&peer, &out, serverFragment(&req, 8, r[32..], null, false));
    try expectEqualSlices(u8, &h("020800060d00"), resp);
    try expectEqual(@as(?eap_tls.Failure, .engine), peer.tls.failure);
    try expectEqual(@as(?anyerror, error.BadFinished), peer.tls.last_engine_error);
    try expectEqual(eap.Status.failed, peer.status());
    try expectError(error.SuccessNotAllowed, peer.onFrame(&fr("03080004"), &out));
    try expectEqual(@as(usize, 0), try peer.onFrame(&fr("04080004"), &out));
    try expectEqual(eap.State.failure, peer.state());

    // (b) 引擎拒收、留了一条 40 八位组的 TLS alert：切 3 片照发，判失败之后也继续发完。
    const s0 = h(s0_hex);
    const flights = [_][]const u8{&s0};
    const alert: [40]u8 = @splat(0xa1);
    var script2 = Script{ .flights = &flights, .fail_push = error.BadCertificate };
    var peer2 = Kat.init("u", script2.engine());
    _ = try sendTo(&peer2, &out, tlsRequest(&req, 5, &[_]u8{0x20}));
    _ = try sendTo(&peer2, &out, tlsRequest(&req, 6, &[_]u8{0})); // 先把我方 ClientHello 的 3 片发完
    _ = try sendTo(&peer2, &out, tlsRequest(&req, 7, &[_]u8{0}));
    _ = try sendTo(&peer2, &out, serverFragment(&req, 8, r[0..16], 40, true));
    _ = try sendTo(&peer2, &out, serverFragment(&req, 9, r[16..32], null, true));
    script2.alert = &alert;
    resp = try sendTo(&peer2, &out, serverFragment(&req, 10, r[32..], null, false));
    // Length = 4 + 1 + 1 + 4 + 16 = 26。
    try expectFrame(resp, "020a001a" ++ "0dc000000028" ++ "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1");
    resp = try sendTo(&peer2, &out, tlsRequest(&req, 11, &[_]u8{0}));
    try expectFrame(resp, "020b0016" ++ "0d40" ++ "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1");
    resp = try sendTo(&peer2, &out, tlsRequest(&req, 12, &[_]u8{0}));
    try expectFrame(resp, "020c000e" ++ "0d00" ++ "a1a1a1a1a1a1a1a1"); // 最后 8 八位组：Length = 14
    try expectEqual(@as(?anyerror, error.BadCertificate), peer2.tls.last_engine_error);
    try expectEqual(@as(usize, 0), script2.pushes);
    try expectError(error.SuccessNotAllowed, peer2.onFrame(&fr("030c0004"), &out));
    _ = try peer2.onFrame(&fr("040c0004"), &out);
    try expectEqual(eap.State.failure, peer2.state());
}

test "a new Start restarts the handshake: engine reset, half-sent flight and half-received message dropped" {
    const s0 = h(s0_hex);
    const flights = [_][]const u8{ &s0, &s0, &s0 };
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    var req: [128]u8 = undefined;
    const r = h(r_hex);
    const first = "0dc000000028" ++ "000102030405060708090a0b0c0d0e0f";

    // 我方分片没发完就来了新的 Start（Identifier 变了）：欠着的分片作废，从新握手的第一片开始。
    var resp = try sendTo(&peer, &out, tlsRequest(&req, 5, &[_]u8{0x20}));
    try expectFrame(resp, "0205001a" ++ first);
    _ = try sendTo(&peer, &out, tlsRequest(&req, 6, &[_]u8{0})); // 发出分片 2
    resp = try sendTo(&peer, &out, tlsRequest(&req, 7, &[_]u8{0x20}));
    try expectEqual(@as(usize, 1), script.resets);
    try expectEqual(@as(usize, 2), script.pulled);
    try expectFrame(resp, "0207001a" ++ first);

    // 把这次的 3 片发完（确认 id 8、9），然后对端的记录只收到一半（id 10）。
    _ = try sendTo(&peer, &out, tlsRequest(&req, 8, &[_]u8{0}));
    _ = try sendTo(&peer, &out, tlsRequest(&req, 9, &[_]u8{0}));
    _ = try sendTo(&peer, &out, serverFragment(&req, 10, r[0..16], 40, true));
    try expect(peer.tls.rx.busy());
    // 新的 Start：重组清掉，握手重来。
    resp = try sendTo(&peer, &out, tlsRequest(&req, 11, &[_]u8{0x20}));
    try expect(!peer.tls.rx.busy());
    try expectEqual(@as(usize, 2), script.resets);
    try expectEqual(@as(usize, 3), script.pulled);
    try expectFrame(resp, "020b001a" ++ first);
    try expectEqual(eap.Status.in_progress, peer.status());
}

test "without resetFn the engine can be started once; a second Start is refused" {
    var script = Script{};
    var engine = script.engine();
    engine.resetFn = null;
    var out: [64]u8 = undefined;
    var req: [64]u8 = undefined;
    var peer = Kat.init("u", engine);
    _ = try sendTo(&peer, &out, tlsRequest(&req, 1, &[_]u8{0x20}));
    try expect(peer.tls.started);
    try expectError(error.EngineNotResettable, sendTo(&peer, &out, tlsRequest(&req, 2, &[_]u8{0x20})));
}

// ---------------------------------------------------------------------------
// EAP-Success / EAP-Failure 何时可信（RFC 3748 §4.2）
// ---------------------------------------------------------------------------

test "EAP-Success is discarded until the TLS handshake is done (RFC 3748 4.2, RFC 5216 2.1.3)" {
    const s0 = h(s0_hex);
    const s1 = h(s1_hex);
    const flights = [_][]const u8{ &s0, &s1 };
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u", script.engine());
    var out: [128]u8 = undefined;
    var req: [128]u8 = undefined;
    const r = h(r_hex);
    _ = try sendTo(&peer, &out, tlsRequest(&req, 5, &[_]u8{0x20}));
    try expectError(error.SuccessNotAllowed, peer.onFrame(&fr("03050004"), &out)); // 刚发出 ClientHello 的第一片
    _ = try sendTo(&peer, &out, tlsRequest(&req, 6, &[_]u8{0}));
    _ = try sendTo(&peer, &out, tlsRequest(&req, 7, &[_]u8{0}));
    try expectError(error.SuccessNotAllowed, peer.onFrame(&fr("03070004"), &out)); // ClientHello 发完，握手还没完成

    // 服务端那一段收齐，我方第二段记录只发出去第一片：握手还不算完成。
    _ = try sendTo(&peer, &out, serverFragment(&req, 8, r[0..16], 40, true));
    _ = try sendTo(&peer, &out, serverFragment(&req, 9, r[16..32], null, true));
    _ = try sendTo(&peer, &out, serverFragment(&req, 10, r[32..], null, false));
    try expect(peer.tls.txPending());
    try expectError(error.SuccessNotAllowed, peer.onFrame(&fr("030a0004"), &out));
    _ = try sendTo(&peer, &out, tlsRequest(&req, 11, &[_]u8{0}));
    _ = try sendTo(&peer, &out, tlsRequest(&req, 12, &[_]u8{0}));
    try expect(peer.tls.handshakeDone());
    try expectEqual(eap.State.method, peer.state());

    // Identifier 对不上我方最后一个 Response（id 12）的不理。
    try expectError(error.ResultIdentifier, peer.onFrame(&fr("030b0004"), &out));
    try expectError(error.ResultIdentifier, peer.onFrame(&fr("030d0004"), &out));
    try expectEqual(eap.State.method, peer.state());

    // 对上了：成功。之后再来的 Success / Failure / Request 一律不理。
    try expectEqual(@as(usize, 0), try peer.onFrame(&fr("030c0004"), &out));
    try expectEqual(eap.State.success, peer.state());
    try expectEqual(eap.Status.succeeded, peer.status());
    try expectError(error.ResultNotAllowed, peer.onFrame(&fr("040c0004"), &out));
    try expectError(error.Finished, peer.onFrame(&fr("010d000501"), &out));
    try expectEqual(eap.State.success, peer.state());
}

test "Success / Failure carry no data: Length must be 4 (RFC 3748 4.2)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    var req: [64]u8 = undefined;
    _ = try sendTo(&peer, &out, tlsRequest(&req, 5, &[_]u8{0x20}));
    try expectError(error.ResultLength, peer.onFrame(&fr("0305000500"), &out));
    try expectError(error.ResultLength, peer.onFrame(&fr("04050005" ++ "01"), &out));
    try expectError(error.EapTooShort, peer.onFrame(&fr("030500"), &out));
    try expectEqual(eap.State.method, peer.state());
}

test "canned Success / Failure (before any authentication method) is discarded (RFC 3748 4.2)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    try expectError(error.ResultNotAllowed, peer.onFrame(&fr("03010004"), &out));
    try expectError(error.ResultNotAllowed, peer.onFrame(&fr("04010004"), &out));
    // Identity、Nak 都回了，仍然没有跑过认证方法。
    _ = try peer.onFrame(&fr("0101000501"), &out);
    try expectError(error.ResultNotAllowed, peer.onFrame(&fr("03010004"), &out));
    _ = try peer.onFrame(&fr("01020005" ++ "04"), &out);
    try expectError(error.ResultNotAllowed, peer.onFrame(&fr("04020004"), &out));
    try expectEqual(eap.State.idle, peer.state());
    try expectEqual(eap.Status.idle, peer.status());
}

test "once EAP-TLS started, other methods and Identity requery are discarded and no Nak is sent (RFC 3748 2.1, 4.1)" {
    var script = Script{};
    var peer = Kat.init("u", script.engine());
    var out: [64]u8 = undefined;
    var req: [64]u8 = undefined;
    _ = try sendTo(&peer, &out, tlsRequest(&req, 5, &[_]u8{0x20}));
    try expectError(error.UnexpectedRequest, peer.onFrame(&fr("01060005" ++ "04"), &out)); // MD5-Challenge
    try expectError(error.UnexpectedRequest, peer.onFrame(&fr("0107000501"), &out)); // Identity Requery
    try expectError(error.UnexpectedRequest, peer.onFrame(&fr("0108000c" ++ "fe000000" ++ "00000005"), &out));
    try expectEqual(@as(usize, 0), peer.prev_resp_len);
    // Notification 是 2.1 明文的例外：照回，不改状态。
    const resp = try sendTo(&peer, &out, &[_]u8{ 1, 9, 0, 6, 2, '!' });
    try expectFrame(resp, "0209000502");
    try expectEqual(eap.State.method, peer.state());
}

test "duplicate Request: the original Response is resent without reprocessing (RFC 3748 4.1)" {
    const s0 = h(s0_hex);
    const s1 = h(s1_hex);
    const flights = [_][]const u8{ &s0, &s1 };
    var script = Script{ .flights = &flights };
    var peer = Kat.init("u@example.com", script.engine());
    var out: [128]u8 = undefined;
    var again: [128]u8 = undefined;

    var a = try peer.onFrame(&fr("0101000501"), &out);
    var b = try peer.onFrame(&fr("0101000501"), &again);
    try expectEqualSlices(u8, out[0..a], again[0..b]);
    try expectEqual(@as(usize, 0), script.pulled);

    a = try peer.onFrame(&fr("01020006" ++ "0d20"), &out);
    b = try peer.onFrame(&fr("01020006" ++ "0d20"), &again); // Start 重传
    try expectEqualSlices(u8, out[0..a], again[0..b]);
    try expectEqual(@as(usize, 1), script.pulled); // 引擎只被取了一次
    try expectEqual(@as(usize, 0), script.resets);

    a = try peer.onFrame(&fr("010300060d00"), &out); // 确认 → 分片 2
    b = try peer.onFrame(&fr("010300060d00"), &again); // 确认重传 → 还是分片 2
    try expectEqualSlices(u8, out[0..a], again[0..b]);
    try expectFrame(out[0..a], "02000016" ++ "02030016" ++ "0d40" ++ "101112131415161718191a1b1c1d1e1f");
    _ = try peer.onFrame(&fr("010400060d00"), &out); // 分片 3

    _ = try peer.onFrame(&fr("0105001a" ++ "0dc000000028" ++ r0_hex), &out); // 对端分片 1 → 确认
    a = try peer.onFrame(&fr("0105001a" ++ "0dc000000028" ++ r0_hex), &out);
    try expectFrame(out[0..a], "02000006020500060d00");
    // 最后一片重传：引擎不会被再喂一次，回的还是同一段记录的第一片。Length = 4 + 1 + 1 + 24 = 30。
    const last = fr("0106001e" ++ "0d00" ++ r1_hex ++ r2_hex);
    a = try peer.onFrame(&last, &out);
    b = try peer.onFrame(&last, &again);
    try expectEqualSlices(u8, out[0..a], again[0..b]);
    try expectEqual(@as(usize, 1), script.pushes);
    try expectEqual(@as(usize, 2), script.pulled);
    // 新 Identifier 的请求照常处理。
    a = try peer.onFrame(&fr("010700060d00"), &out);
    try expectFrame(out[0..a], "02000016" ++ "02070016" ++ "0d40" ++ "404142434445464748494a4b4c4d4e4f");
}

// ---------------------------------------------------------------------------
// 密钥（RFC 5216 §2.3、802.11-2016 §12.7.1.3）
// ---------------------------------------------------------------------------

test "pmkFromMsk known answers: PMK = first 32 octets of MSK (802.11-2016 12.7.1.3, RFC 5216 2.3)" {
    const wants = .{ &kat_pmk_0, &kat_pmk_1, &kat_pmk_2, &kat_pmk_3, &kat_pmk_4, &kat_pmk_5, &kat_pmk_6, &kat_pmk_7 };
    inline for (wants, 0..) |want, i| {
        var seed_buf: [32]u8 = undefined;
        const seed = try std.fmt.bufPrint(&seed_buf, "s31-eap-pmk-{d}", .{i});
        var msk: [eap_tls.msk_len]u8 = undefined;
        Sha512.hash(seed, &msk, .{});
        try expectEqualSlices(u8, want, &eap_tls.pmkFromMsk(msk));
        // 后 32 八位组不进 PMK：改它们结果不变；改前 32 个才变。
        var tail: [eap_tls.msk_len]u8 = msk;
        @memset(tail[32..], 0xff);
        try expectEqualSlices(u8, want, &eap_tls.pmkFromMsk(tail));
        tail[0] ^= 1;
        try expect(!std.mem.eql(u8, want, &eap_tls.pmkFromMsk(tail)));
    }
    try expectEqual(@as(usize, 64), eap_tls.msk_len);
    try expectEqual(@as(usize, 32), eap_tls.pmk_len);
}

test "splitKeyMaterial: MSK = Key_Material(0,63), EMSK = Key_Material(64,127) (RFC 5216 2.3)" {
    var km: [eap_tls.key_material_len]u8 = undefined;
    for (&km, 0..) |*b, i| b.* = @truncate(i);
    const k = eap_tls.splitKeyMaterial(km);
    try expectEqual(@as(usize, 128), eap_tls.key_material_len);
    try expectEqualSlices(u8, km[0..64], &k.msk);
    try expectEqualSlices(u8, km[64..128], &k.emsk);
    try expectEqualSlices(u8, km[0..32], &eap_tls.pmkFromMsk(k.msk));
}

// ---------------------------------------------------------------------------
// 性质：任意记录流、任意切点
// ---------------------------------------------------------------------------

test "rx reassembly: every split of every stream length up to 12 gives back the same bytes (RFC 5216 2.1.5)" {
    var prng = std.Random.DefaultPrng.init(0x5216);
    const rand = prng.random();
    var stream: [12]u8 = undefined;
    var frag: [32]u8 = undefined;
    var n: usize = 1;
    while (n <= stream.len) : (n += 1) {
        rand.bytes(stream[0..n]);
        const splits: usize = @as(usize, 1) << @intCast(n - 1);
        var mask: usize = 0;
        while (mask < splits) : (mask += 1) {
            var rx = eap_tls.RxSized(64){};
            var pos: usize = 0;
            while (pos < n) {
                // 第 pos 个八位组之后是不是切点，看 mask 的第 pos 位。
                var end: usize = pos + 1;
                while (end < n and ((mask >> @intCast(end - 1)) & 1) == 0) : (end += 1) {}
                var k: usize = 1; // 先跳过 Flags 八位组
                frag[0] = 0;
                // 不分片的单条消息不带 L；分成多片时首片带 L 和总长。
                if (pos == 0 and n > 1) {
                    frag[0] |= 0x80;
                    std.mem.writeInt(u32, frag[1..5], @intCast(n), .big);
                    k = 5;
                }
                if (end < n) frag[0] |= 0x40;
                @memcpy(frag[k..][0 .. end - pos], stream[pos..end]);
                k += end - pos;
                const got = rx.accept(frag[0..k]) catch |e| {
                    std.debug.print("rx split n={d} mask={d} pos={d} end={d} typedata={x}\n", .{ n, mask, pos, end, frag[0..k] });
                    return e;
                };
                if (end < n) {
                    try expect(got == .ack);
                    try expect(rx.busy());
                } else {
                    try expect(got == .complete);
                    try expectEqualSlices(u8, stream[0..n], got.complete);
                    try expect(!rx.busy());
                }
                pos = end;
            }
        }
    }
}

test "tx fragmentation: boundaries at the fragment size; L only when fragmented, M on all but the last (RFC 5216 2.1.5)" {
    const P = PeerOf(128, 512, 16);
    // 长度在 16 的两侧、整倍数、整倍数加一。
    const lens = [_]usize{ 1, 15, 16, 17, 31, 32, 33, 48, 64 };
    for (lens) |len| {
        var flight: [64]u8 = undefined;
        for (&flight, 0..) |*b, i| b.* = @truncate(0x30 + i);
        const flights = [_][]const u8{flight[0..len]};
        var script = Script{ .flights = &flights };
        var peer = P.init("u", script.engine());
        var out: [256]u8 = undefined;
        var id: u8 = 5;
        const resp = try sendTo(&peer, &out, &[_]u8{ 1, 5, 0, 6, 13, 0x20 });
        var sink = RefRx{};
        try collectFlight(&peer, &out, resp, &id, &sink);
        const count = (len + 15) / 16;
        try expectEqual(count, sink.count);
        try expectEqualSlices(u8, flight[0..len], sink.buf[0..sink.len]);
        try expectEqual(len > 16, sink.flags[0] & 0x80 != 0); // L 只在真的分片时出现
        for (sink.flags[0 .. count - 1]) |f| try expect(f & 0x40 != 0); // 前面的都带 M
        try expect(sink.flags[count - 1] & 0xc0 == 0); // 最后一片不带 M，也不带 L
        try expect(!peer.tls.txPending());
    }
    // 引擎没有记录可发：回空的 EAP-TLS 包。
    var none = Script{};
    var peer = P.init("u", none.engine());
    var out: [64]u8 = undefined;
    const resp = try sendTo(&peer, &out, &[_]u8{ 1, 1, 0, 6, 13, 0x20 });
    try expectEqualSlices(u8, &h("020100060d00"), resp);
}

/// 一场完整的会话：Identity、EAP-TLS Start、双方各几段随机记录、EAP-Success。
/// 服务端的每一段按随机切点分片；peer 自己的分片由参考重组收齐。两边都逐字节比对。
fn converse(comptime P: type, rand: std.Random) !void {
    const rx_max = P.config.tls.rx_max;
    const tx_max = P.config.tls.tx_max;
    var out: [4096]u8 = undefined;
    var sbuf: [2048]u8 = undefined;
    var cbuf: [5][tx_max]u8 = undefined;
    var sfl: [4][rx_max]u8 = undefined;

    // 随机的记录流：客户端 n+1 段（第一段是 ClientHello），服务端 n 段（每段至少 1 八位组）。
    const n_server = rand.intRangeLessThan(usize, 0, sfl.len + 1);
    var cf: [cbuf.len][]const u8 = undefined;
    var sf: [sfl.len][]const u8 = undefined;
    for (0..n_server + 1) |i| {
        const len = rand.intRangeAtMost(usize, 0, tx_max);
        rand.bytes(cbuf[i][0..len]);
        cf[i] = cbuf[i][0..len];
    }
    for (0..n_server) |i| {
        const len = rand.intRangeAtMost(usize, 1, rx_max);
        rand.bytes(sfl[i][0..len]);
        sf[i] = sfl[i][0..len];
    }
    var key: [eap_tls.msk_len]u8 = undefined;
    rand.bytes(&key);
    var script = Script{ .flights = cf[0 .. n_server + 1], .done_after = n_server, .key = key };
    var peer = P.init("user@example.com", script.engine());
    try expectEqual(eap.Status.idle, peer.status());

    var id: u8 = 0;
    var sink = RefRx{};
    var cut_buf: [15]usize = undefined;
    var starts: [17]usize = undefined;

    // Request/Identity → Response/Identity（Length = 4 + 1 + 16 = 21）。
    id +%= 1;
    var resp = try sendTo(&peer, &out, &[_]u8{ 1, id, 0, 5, 1 });
    try expectFrame(resp, "02010015" ++ "01" ++ "75736572406578616d706c652e636f6d");

    // EAP-TLS Start → ClientHello。
    id +%= 1;
    resp = try sendTo(&peer, &out, &[_]u8{ 1, id, 0, 6, 13, 0x20 });
    sink = .{};
    try collectFlight(&peer, &out, resp, &id, &sink);
    try expectEqualSlices(u8, cf[0], sink.buf[0..sink.len]);

    for (0..n_server) |i| {
        const flight = sf[i];
        const cuts = randomCuts(rand, flight.len, &cut_buf);
        starts[0] = 0;
        for (cuts, 0..) |c, j| starts[j + 1] = c;
        starts[cuts.len + 1] = flight.len;
        const k = cuts.len + 1;
        for (0..k) |j| {
            id +%= 1;
            resp = try sendTo(&peer, &out, serverFragment(&sbuf, id, flight[starts[j]..starts[j + 1]], if (j == 0) flight.len else null, j != k - 1));
            if (j != k - 1) try expectEqualSlices(u8, &h("00"), try tlsData(resp, id)); // 带 M 的分片：空确认
        }
        // 最后一片交齐，peer 回它下一段记录的第一片。
        sink = .{};
        try collectFlight(&peer, &out, resp, &id, &sink);
        try expectEqualSlices(u8, cf[i + 1], sink.buf[0..sink.len]);
        try expectEqual(eap.Status.in_progress, peer.status());
    }
    try expectEqual(n_server, script.pushes);
    for (0..n_server) |i| try expectEqualSlices(u8, sf[i], script.pushed(i));
    try expect(peer.tls.handshakeDone());

    // EAP-Success 的 Identifier 是我方最后一个 Response 的。
    try expectEqual(@as(usize, 0), (try sendTo(&peer, &out, &[_]u8{ 3, id, 0, 4 })).len);
    try expectEqual(eap.State.success, peer.state());
    try expectEqualSlices(u8, &key, &peer.msk());
    try expectEqualSlices(u8, key[0..32], &peer.pmk());
}

test "random conversations: arbitrary record streams and cut points, both sides reassemble byte-for-byte (RFC 5216 2.1.5)" {
    var prng = std.Random.DefaultPrng.init(0x5216_2026);
    const rand = prng.random();
    inline for (.{ PeerOf(1024, 1024, 1), PeerOf(1024, 1024, 7), PeerOf(1024, 1024, 100), PeerOf(1024, 1024, 1398) }) |P| {
        for (0..8) |_| try converse(P, rand);
    }
}

// ---------------------------------------------------------------------------
// 板侧子自检在主机上执行
// ---------------------------------------------------------------------------

test "board selftest on host: eap (eap_selftest.run) passes every check" {
    try selftest_host.expectAllPass(eap_selftest.run);
}
