//! ble-802154：6LoWPAN 适配层（RFC 4944 / RFC 6282 / RFC 6775）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字每行 ≤ 200 字节（板侧 `board.log` 会截断）。
//! 判据与主机测试 `sixlowpan_tests.zig` 用同一批期望值（RFC 手排 KAT / lwIP 输出）；
//! 板侧只算固定输入。大缓冲放文件作用域：板侧栈只有 16 KiB。
//!
//! 判据：
//!   ① dispatch 分类（RFC 4944 §5.1 图 2；RFC 6282 §5；RFC 8025 §3）
//!   ② IPHC 无状态解压 KAT：帧 A（SAM/DAM=10 + UDP P=00，RFC 6282 §3.1.1/§4.3.3）
//!   ③ IPHC 无状态解压 KAT：帧 B（SAM/DAM=11，IID 取自封装头，§3.2.2）
//!   ④ 有状态解压：/48 上下文 + SAM=11，缝位 [48,64) 按 RFC 6282 行 429-435 置零
//!   ⑤ UDP NHC 四种 P 取值（RFC 6282 §4.3.3 图 14）
//!   ⑥ UDP 校验和：伪头 + RFC 1071，0 → 0xffff（RFC 2460 §8.1）
//!   ⑦ 分片头 KAT 与分片器偏移（RFC 4944 §5.3 图 4/5）
//!   ⑧ 重组：顺序完成、FRAGN 先到、重复片（§5.3）
//!   ⑨ 重组：重叠丢弃与 60 s 超时（§5.3）
//!   ⑩ Mesh 头编码与 §11 转发规则

const std = @import("std");
const f15 = @import("fifteen4.zig");

fn hx(s: []const u8, out: []u8) []u8 {
    const n = s.len / 2;
    for (out[0..n], 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }
    return out[0..n];
}

const mac_short = f15.MacHeader{
    .fcf = f15.Fcf{},
    .seq = 0x2a,
    .dest_pan = 0x1234,
    .dest = .{ .short = 0x0002 },
    .src_pan = 0x1234,
    .src = .{ .short = 0x9a3c },
};

const mac_long_src = f15.MacHeader{
    .fcf = f15.Fcf{ .src_mode = .long },
    .seq = 0x2b,
    .dest_pan = 0x1234,
    .dest = .{ .short = 0x0002 },
    .src_pan = 0x1234,
    .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
};

const zero16 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
const src_ip = [16]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0x9a, 0x3c };
const dst_ip = [16]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 };

// 文件作用域大缓冲（板侧栈 16 KiB）。
var out1: [256]u8 = @splat(0);
var out2: [256]u8 = @splat(0);
var out3: [512]u8 = @splat(0);
var cbuf: [512]u8 = @splat(0);
var piece: [140]u8 = @splat(0);
var frags_buf: [8][140]u8 = @splat(@splat(0));
var frame_buf: [64]u8 = @splat(0);
var hdr_buf: [64]u8 = @splat(0);
var udp_buf: [24]u8 = @splat(0);

const R2 = f15.frag.Reassembler(2, 512);

fn udpBytes(sp: u16, dp: u16, payload: []const u8) []u8 {
    udp_buf[0] = @truncate(sp >> 8);
    udp_buf[1] = @truncate(sp);
    udp_buf[2] = @truncate(dp >> 8);
    udp_buf[3] = @truncate(dp);
    std.mem.writeInt(u16, udp_buf[4..6], @intCast(8 + payload.len), .big);
    udp_buf[6] = 0;
    udp_buf[7] = 0;
    @memcpy(udp_buf[8 .. 8 + payload.len], payload);
    const c = f15.iphc.udpChecksum(src_ip, dst_ip, udp_buf[0 .. 8 + payload.len]);
    std.mem.writeInt(u16, udp_buf[6..8], c, .big);
    return udp_buf[0 .. 8 + payload.len];
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    // ① dispatch 分类（RFC 4944 §5.1 图 2 / RFC 6282 §5 / RFC 8025 §3）。
    {
        const ok = f15.dispatchOf(0x00) == .nalp and f15.dispatchOf(0x41) == .ipv6 and
            f15.dispatchOf(0x48) == .bc0 and f15.dispatchOf(0x60) == .iphc and
            f15.dispatchOf(0x7f) == .iphc and f15.dispatchOf(0x80) == .mesh and
            f15.dispatchOf(0xc0) == .frag1 and f15.dispatchOf(0xe0) == .fragn and
            f15.dispatchOf(0xf0) == .paging and f15.dispatchOf(0x5f) == .reserved;
        check(ok, "sixlowpan: dispatch nalp/ipv6/bc0/iphc/mesh/frag1/fragn/paging/reserved");
    }
    // ② 帧 A：SAM/DAM=10、UDP P=00 → RFC 手排 KAT（内联字段高字节在前，§3.2 行 590-591）。
    {
        const d = f15.iphc.decompress(&out1, &f15.kat_lowpan_short, f15.iphc.Link.fromMac(&mac_short), &.{}, .{}) catch null;
        const want = hx("60000000000a11ff" ++
            "fe80000000000000000000fffe003c9a" ++
            "fe80000000000000000000fffe000200" ++
            "12345678000aabcd6f6b", out2[128..]);
        const ok = d != null and std.mem.eql(u8, d.?.packet, want) and
            d.?.next_header == 17 and !d.?.udp_checksum_elided;
        check(ok, "sixlowpan: iphc frame A KAT sam/dam=10 udp P=00");
    }
    // ③ 帧 B：SAM/DAM=11 → IID 从封装头取，U/L 位翻转（RFC 6282 §3.2.2）。
    {
        const d = f15.iphc.decompress(&out1, &f15.kat_lowpan_elided, f15.iphc.Link.fromMac(&mac_long_src), &.{}, .{}) catch null;
        var want: [40]u8 = @splat(0);
        const w1 = hx("60000000000a11ff" ++ "fe800000000000000011223344556677", &want);
        const w2 = hx("fe80000000000000000000fffe000002", want[w1.len..]);
        const ok = d != null and std.mem.eql(u8, d.?.packet[0..40], want[0 .. w1.len + w2.len]);
        check(ok, "sixlowpan: iphc frame B KAT sam/dam=11 ul-flip");
    }
    // ④ 有状态解压：/48 上下文 + SAM=11 → 缝位 [48,64) 置零（RFC 6282 行 429-435）。
    {
        var ctxs: f15.iphc.Contexts = .{};
        ctxs.tick(1000);
        ctxs.update(2, [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 48, true, 10) catch {};
        const f = hx("7ff3" ++ "20" ++ "f0" ++ "12340035abcd", &frame_buf);
        const d = f15.iphc.decompress(&out1, f, f15.iphc.Link.fromMac(&mac_short), &ctxs, .{}) catch null;
        const want = hx("20010db80001" ++ "0000" ++ "000000fffe009a3c", out2[128..]);
        const ok = d != null and std.mem.eql(u8, d.?.packet[8..24], want);
        check(ok, "sixlowpan: stateful /48 ctx sam=11 gap bits zero");
    }
    // ⑤ UDP NHC 四种 P（RFC 6282 §4.3.3 图 14）。
    {
        const d0 = f15.decodeUdpNhc(hx("f0" ++ "1234" ++ "5678" ++ "abcd", &out2)) catch null;
        const d1 = f15.decodeUdpNhc(hx("f1" ++ "0050" ++ "35" ++ "abcd", &out2)) catch null;
        const d2 = f15.decodeUdpNhc(hx("f2" ++ "01" ++ "0035" ++ "abcd", &out2)) catch null;
        const d3 = f15.decodeUdpNhc(hx("f3" ++ "23" ++ "abcd", &out2)) catch null;
        const ok = d0 != null and d0.?.src_port == 0x1234 and d0.?.dst_port == 0x5678 and
            d1 != null and d1.?.src_port == 0x0050 and d1.?.dst_port == 0xf035 and
            d2 != null and d2.?.src_port == 0xf001 and d2.?.dst_port == 0x0035 and
            d3 != null and d3.?.src_port == 0xf0b2 and d3.?.dst_port == 0xf0b3 and
            d3.?.checksum == 0xabcd;
        check(ok, "sixlowpan: udp nhc P=00/01/10/11 ports");
    }
    // ⑥ UDP 校验和：全零伪头 + 全零 UDP（len=8）→ 0xffe6；算出 0 → 0xffff（RFC 2460 §8.1）。
    {
        const z8a = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const c0 = f15.iphc.udpChecksum(zero16, zero16, &z8a);
        const ud = [10]u8{ 0, 0, 0, 0, 0, 0x0a, 0, 0, 0xff, 0xda };
        const c1 = f15.iphc.udpChecksum(zero16, zero16, &ud);
        check(c0 == 0xffe6 and c1 == 0xffff, "sixlowpan: udp csum ffe6/0->ffff");
    }
    // ⑦ 分片头 KAT（RFC 4944 §5.3 图 4/5；lwIP TX 同字节序）+ 偏移按未压缩字节计。
    {
        var h: [8]u8 = @splat(0);
        const n1 = f15.frag.encodeHeader(&h, .{ .first = true, .size = 348, .tag = 1, .offset = 0 }) catch 0;
        const kat1 = n1 == 4 and h[0] == 0xc1 and h[1] == 0x5c and h[2] == 0x00 and h[3] == 0x01;
        const n2 = f15.frag.encodeHeader(&h, .{ .first = false, .size = 348, .tag = 1, .offset = 17 }) catch 0;
        const kat2 = n2 == 5 and h[0] == 0xe1 and h[4] == 17;
        check(kat1 and kat2, "sixlowpan: frag hdr kat c1/5c/00/01 e1 +17");
    }
    // ⑧ 重组：顺序完成、长度回填（RFC 4944 §5.3 NOTE）。
    {
        var pkt: [512]u8 = @splat(0);
        // 真 UDP 包：头 8 字节（Length=300）+ 292 字节载荷，总长 340。
        pkt[0] = 0x60;
        std.mem.writeInt(u16, pkt[4..6], 300, .big);
        pkt[6] = 17;
        pkt[7] = 64;
        @memcpy(pkt[8..24], &src_ip);
        @memcpy(pkt[24..40], &dst_ip);
        udp_buf[0] = 0x12;
        udp_buf[1] = 0x34;
        udp_buf[2] = 0x00;
        udp_buf[3] = 0x35;
        std.mem.writeInt(u16, udp_buf[4..6], 300, .big);
        udp_buf[6] = 0;
        udp_buf[7] = 0;
        @memcpy(pkt[40..48], udp_buf[0..8]);
        @memset(pkt[48..340], 0x5a);
        var kit_ok = true;
        const zc = f15.iphc.compress(&cbuf, pkt[0..340], f15.iphc.Link.fromMac(&mac_short), &.{}, .{}) catch null;
        if (zc == null) kit_ok = false;
        if (kit_ok) {
            const header_len = zc.?.frame_len - (340 - zc.?.hidden_len);
            var cur = f15.frag.Cursor.init(cbuf[0..zc.?.frame_len], header_len, zc.?.hidden_len, 104, 5) catch null;
            if (cur == null) kit_ok = false;
            if (cur != null) {
                var re: R2 = .{};
                var done = false;
                while (cur.?.next(&piece) catch null) |n| {
                    const hh = f15.frag.decodeHeader(piece[0..n]) catch break;
                    const key = R2.Key{ .sender = mac_short.src, .dest = mac_short.dest, .size = hh.header.size, .tag = 5 };
                    const o = re.push(piece[0..n], key, f15.iphc.Link.fromMac(&mac_short), &.{}, .{}, &out3) catch break;
                    if (std.meta.activeTag(o) == .complete) {
                        done = std.mem.eql(u8, o.complete, pkt[0..340]) and
                            std.mem.readInt(u16, o.complete[4..6], .big) == 300 and
                            std.mem.readInt(u16, o.complete[44..46], .big) == 300;
                    }
                }
                kit_ok = done;
            }
        }
        check(kit_ok, "sixlowpan: reass in-order 340B lens backfilled");
    }
    // ⑨ 重组：FRAGN 先到不丢、缺片 waiting、超时 60 s（RFC 4944 §5.3）。
    {
        var re: R2 = .{};
        var buf2: [16]u8 = @splat(0);
        const n = f15.frag.encodeHeader(&buf2, .{ .first = false, .size = 300, .tag = 7, .offset = 17 }) catch 0;
        @memcpy(buf2[n..][0..8], "12345678");
        const key = R2.Key{ .sender = mac_short.src, .dest = mac_short.dest, .size = 300, .tag = 7 };
        const o = re.push(buf2[0 .. n + 8], key, f15.iphc.Link.fromMac(&mac_short), &.{}, .{}, &out3) catch null;
        const waiting = o != null and std.meta.activeTag(o.?) == .waiting and re.inProgress() == 1;
        re.tick(59_999);
        const alive = re.inProgress() == 1;
        re.tick(60_000);
        check(waiting and alive and re.inProgress() == 0 and re.stats.expired == 1, "sixlowpan: reass fragn-first timeout 60s");
    }
    // ⑩ Mesh 头 KAT 与转发规则（RFC 4944 §5.2、§11）。
    {
        var m: [16]u8 = @splat(0);
        const n = f15.mesh.encodeHeader(&m, .{
            .originator = .{ .short = 0x9a3c },
            .final = .{ .short = 0x0002 },
            .hops_left = 3,
        }) catch 0;
        const kat = n == 5 and m[0] == 0xb3 and m[1] == 0x9a and m[2] == 0x3c and m[3] == 0x00 and m[4] == 0x02;
        const h = f15.mesh.Header{ .originator = .{ .short = 0x9a3c }, .final = .{ .short = 0x0002 }, .hops_left = 3 };
        const fwd = f15.mesh.forward(h, .{ .short = 0x0003 });
        const exp = f15.mesh.forward(h, .{ .short = 0x0002 }) == .deliver and
            (std.meta.activeTag(fwd) == .forward and fwd.forward == 2);
        check(kat and exp, "sixlowpan: mesh hdr kat + forward/deliver");
    }
}
