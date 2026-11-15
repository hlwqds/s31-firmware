//! net-wire：生产固件的真实链路探针（可选 `-Dwire=true`）。
//!
//! 只做两件事，且都必须有外部对端：
//!   1. DHCP DISCOVER → OFFER → REQUEST → ACK，拿到租约；
//!   2. 向 `租约网关:9000` 主动打开，握手由 `net-tcp` 的 `tcp.Conn` 驱动
//!      （含 RTO 重传），进 ESTABLISHED 后立刻 RST，保持 profile 短。
//!
//! 依赖 host 侧 dnsmasq + TCP 监听器；默认 CI 不开这个 profile。

const std = @import("std");
const board = @import("board");
const eth = @import("net_ethernet");
const ip4 = @import("net_ipv4");
const udpmod = @import("net_udp");
const tcpmod = @import("net_tcp");

const emac = eth.emac;
const regs = eth.regs;
const pins = eth.pins;
const apll = eth.apll;
const inet = ip4.inet;
const ipv4 = ip4.ipv4;
const arp = ip4.arp;
const udp = udpmod.udp;
const dhcp = udpmod.dhcp;
const tcp = tcpmod.tcp;
const checksum = tcpmod.checksum;
const socks = @import("net_sockets");
const socket = socks.socket;
const wire = socks.wire;

const log = board.log;
const hw = board.hw;

const local_mac: [6]u8 = .{ 0x02, 0x00, 0x00, 0x00, 0x31, 0x01 };
const host_port: u16 = 9000;
const local_port: u16 = 40000;
const syn_iss: u32 = 0x2026_3111;

var passed: u32 = 0;
var failed: u32 = 0;
var board_ip: [4]u8 = .{ 0, 0, 0, 0 };
var host_ip: [4]u8 = .{ 0, 0, 0, 0 };
var host_mac: ?[6]u8 = null;
var dhcp_client: dhcp.Client = .{};
/// 一次 profile 一条连接：状态机、ISS、RTO 全在 `tcp.Conn` 里。
var conn: tcp.Conn = .{};

// R2.2d：socket 层与真实连接并行驱动。分工见 ch22 的接线说明——
// 线上真相（seq/flags/RTO/重传）归 `tcp.Conn`，API 表面（fd/tx/rx 缓冲）归 `socket.Table`。
var tbl: socket.Table = .{};
var cfd: ?u8 = null;
var bases: wire.Bases = .{ .local_iss = 0, .peer_iss = 0 };
/// 客户端的 peer_iss 只能从 SYN-ACK 自己的 seq 学到；学之前不镜像任何段。
var peer_iss_known = false;
/// 已镜像给 socket 的字节数（按 socket 偏移）：`.data` 分支不看 seq，重复投递会让字节进两遍。
var mirrored: u32 = 0;
/// 已被 ACK 确认、可以 `drainTx` 的字节数（socket 偏移）。
var drained: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) passed += 1 else failed += 1;
    log.line("check: " ++ fmt ++ " ok={d}", args ++ .{@intFromBool(ok)});
}

fn sendFrame(dst: [6]u8, ethertype: u16, payload: []const u8) void {
    const f = emac.buildTestFrame(dst, local_mac, ethertype, payload);
    _ = emac.txFrame(f.len, 10_000) catch |e| log.line("wire: tx {s}", .{@errorName(e)});
}

fn sendUdp(dst_mac: [6]u8, src: [4]u8, dst: [4]u8, sport: u16, dport: u16, payload: []const u8) void {
    var dgram: [700]u8 = undefined;
    const uh = udp.Header{ .src_port = sport, .dst_port = dport, .length = @intCast(udp.Header.len + payload.len) };
    _ = uh.write(dgram[0..udp.Header.len]) catch return;
    @memcpy(dgram[udp.Header.len .. udp.Header.len + payload.len], payload);
    const total = udp.Header.len + payload.len;
    udp.seal(src, dst, dgram[0..total]) catch return;
    var pkt: [720]u8 = undefined;
    var ih = ipv4.Header{ .total_len = @intCast(20 + total), .id = 0x3100, .ttl = 64, .protocol = ipv4.proto.udp, .src = src, .dst = dst };
    const hlen = ih.write(pkt[0..20]) catch return;
    @memcpy(pkt[hlen .. hlen + total], dgram[0..total]);
    sendFrame(dst_mac, 0x0800, pkt[0 .. hlen + total]);
}

fn sendDhcp(msg_type: dhcp.MsgType, requested: ?[4]u8, server: ?[4]u8) void {
    var bootp: [600]u8 = undefined;
    var msg = dhcp.Msg{ .xid = dhcp_client.xid, .flags = .{ .broadcast = true } };
    @memcpy(msg.chaddr[0..6], &local_mac);
    var b = dhcp.Builder.init(&bootp, msg) catch return;
    b.option(dhcp.Option.message_type, &.{@backingInt(msg_type)}) catch return;
    if (requested) |ip| b.ip(dhcp.Option.requested_ip, ip) catch return;
    if (server) |ip| b.ip(dhcp.Option.server_id, ip) catch return;
    b.option(dhcp.Option.param_list, &dhcp.default_param_list) catch return;
    const pkt = b.finish() catch return;
    sendUdp(.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .{ 0, 0, 0, 0 }, .{ 255, 255, 255, 255 }, dhcp.client_port, dhcp.server_port, pkt);
}

fn sendArpRequest(target: [4]u8) void {
    var buf: [arp.packet_len]u8 = undefined;
    const p = (arp.Packet{ .op = arp.Op.request, .sha = local_mac, .spa = board_ip, .tpa = target }).write(&buf) catch return;
    sendFrame(.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, 0x0806, p);
}

fn answerArp(p: arp.Packet) void {
    if (p.op != arp.Op.request or !inet.eql(p.tpa, board_ip)) return;
    var buf: [arp.packet_len]u8 = undefined;
    const r = (arp.Packet{ .op = arp.Op.reply, .sha = local_mac, .spa = board_ip, .tha = p.sha, .tpa = p.spa }).write(&buf) catch return;
    sendFrame(p.sha, 0x0806, r);
}

/// 把 `tcp.Conn` 给出的 `Action` 编成一个段发出去。
/// 选项只在握手时有：`Conn` 的 Action 不含选项，SYN 固定带 MSS=1460。
fn socketWindow() u16 {
    const fd = cfd orelse return 65535;
    const s = &tbl.socks[fd];
    // socket 层没有接收背压（装不下就丢并计数），通告窗口不能超过它的剩余空间。
    return @intCast(@min(socket.rx_cap - s.rx_len, 65535));
}

fn sendAction(a: tcp.Action) void {
    if (!a.send) return;
    if (host_mac == null) return;
    const opts: tcp.Options = if (a.flags.syn) .{ .mss = tcp.MSS_ETHERNET } else .{};
    const hdr = tcp.Header{ .src_port = local_port, .dst_port = host_port, .seq = a.seq, .ack = a.ack, .flags = a.flags, .window = socketWindow() };

    if (a.payload_len > 0) {
        const fd = cfd orelse return;
        const sk = &tbl.socks[fd];
        // 环形 tx_buf 折返时中间一段是旧数据：先线性化到栈上暂存区。
        var scratch: [tcp.MSS_ETHERNET * 2]u8 = undefined;
        const n = sk.txPeek(&scratch).n;
        const want: usize = @intCast(a.seq -% bases.local_iss);
        const base = sk.txSeqBase();
        if (want < base or want - base + a.payload_len > n) {
            log.line("wire: tx peek miss want={d} base={d} n={d} len={d}", .{ want, base, n, a.payload_len });
            return;
        }
        const at = want - base;
        var seg: [tcp.MAX_HEADER + tcp.MSS_ETHERNET]u8 = undefined;
        const total = tcp.encode(hdr, opts, scratch[at..][0..a.payload_len], &seg) catch return;
        _ = checksum.fillTcp(board_ip, host_ip, seg[0..total]);
        var pkt: [20 + tcp.MAX_HEADER + tcp.MSS_ETHERNET]u8 = undefined;
        var ih = ipv4.Header{ .total_len = @intCast(20 + total), .id = 0x3101, .ttl = 64, .protocol = 6, .src = board_ip, .dst = host_ip };
        const hlen = ih.write(pkt[0..20]) catch return;
        @memcpy(pkt[hlen .. hlen + total], seg[0..total]);
        sendFrame(host_mac.?, 0x0800, pkt[0 .. hlen + total]);
        return;
    }

    var seg: [64]u8 = undefined;
    const n = tcp.encode(hdr, opts, "", &seg) catch return;
    _ = checksum.fillTcp(board_ip, host_ip, seg[0..n]);
    var pkt: [128]u8 = undefined;
    var ih = ipv4.Header{ .total_len = @intCast(20 + n), .id = 0x3101, .ttl = 64, .protocol = 6, .src = board_ip, .dst = host_ip };
    const hlen = ih.write(pkt[0..20]) catch return;
    @memcpy(pkt[hlen .. hlen + n], seg[0..n]);
    sendFrame(host_mac.?, 0x0800, pkt[0 .. hlen + n]);
}

fn handleDhcp(payload: []const u8, now_s: u64) bool {
    var msg = dhcp.parseFixed(payload) catch return false;
    var opts = dhcp.Options{};
    dhcp.parseOptions(payload, &opts) catch return false;
    const action = dhcp_client.onReply(&msg, &opts, now_s) catch return false;
    if (action == .send_request) {
        log.line("wire: dhcp OFFER ip={d}.{d}.{d}.{d}", .{ msg.yiaddr[0], msg.yiaddr[1], msg.yiaddr[2], msg.yiaddr[3] });
        sendDhcp(.request, dhcp_client.offered_ip, dhcp_client.server_id);
        return false;
    }
    if (opts.message_type == .ack) {
        board_ip = dhcp_client.lease.ip;
        host_ip = dhcp_client.lease.router;
        log.line("wire: dhcp ACK ip={d}.{d}.{d}.{d} gw={d}.{d}.{d}.{d}", .{
            board_ip[0], board_ip[1], board_ip[2], board_ip[3], host_ip[0], host_ip[1], host_ip[2], host_ip[3],
        });
        return true;
    }
    return false;
}

fn handleTcp(l4: []const u8, now_us: u64) void {
    const seg = tcp.parse(l4) catch return;
    if (seg.hdr.dst_port != local_port or seg.hdr.src_port != host_port) return;

    // 客户端的对端基址只能从 SYN-ACK 学：`peer_iss` = 它的 seq + 1（SYN 不占数据偏移）。
    if (seg.hdr.flags.syn and seg.hdr.flags.ack and !peer_iss_known) {
        bases.peer_iss = seg.hdr.seq +% 1;
        bases.local_iss = syn_iss +% 1;
        peer_iss_known = true;
        log.line("wire: socket peer_iss=0x{x:0>8} local_iss=0x{x:0>8}", .{ bases.peer_iss, bases.local_iss });
    }

    const a = conn.onSegment(seg, now_us);
    if (a.retransmit) log.line("wire: tcp retransmit state={s} seq=0x{x:0>8}", .{ conn.state.name(), a.seq });
    sendAction(a);

    // 镜像进 socket 层：学不到基址之前不投，投之前按偏移去重（`.data` 分支不看 seq）。
    if (peer_iss_known) if (cfd) |fd| {
        const rs = wire.fromTcp(seg, bases);
        if (rs.payload.len > 0) {
            if (rs.seq == mirrored) {
                tbl.deliver(fd, rs);
                mirrored +%= @intCast(rs.payload.len);
            }
        } else {
            tbl.deliver(fd, rs);
        }
    };

    // ACK 覆盖了多少应用字节就 drainTx 多少（tx_buf 是唯一副本，重传还要用）。
    if (cfd) |fd| {
        const acked: u32 = conn.snd_una -% bases.local_iss;
        if (acked > drained) {
            const n: usize = @intCast(acked - drained);
            _ = tbl.socks[fd].drainTx(n);
            drained = acked;
        }
    }
}

/// 收帧总入口。时间单位用微秒：`Conn` 的 RTO/2MSL 都是微秒，
/// DHCP 只吃秒，所以在 UDP 分支里现算 `now_us / 1_000_000`。
fn handleFrame(frame: []const u8, now_us: u64) void {
    if (frame.len < 14) return;
    const dst = frame[0..6].*;
    if (!std.mem.eql(u8, dst[0..], local_mac[0..]) and !arp.isBroadcastMac(dst)) return;
    const etype = std.mem.readInt(u16, frame[12..14], .big);
    if (etype == 0x0806) {
        const p = arp.Packet.parse(frame[14..]) catch return;
        answerArp(p);
        if (p.op == arp.Op.reply and inet.eql(p.spa, host_ip)) {
            host_mac = p.sha;
            log.raw("wire: arp host mac learned\n");
        }
        return;
    }
    if (etype != 0x0800) return;
    const h = ipv4.Header.parseChecked(frame[14..]) catch return;
    const l4 = h.payload(frame[14..]) catch return;
    if (h.protocol == ipv4.proto.udp) {
        const uh = udp.Header.parse(l4) catch return;
        if (uh.dst_port == dhcp.client_port) _ = handleDhcp(uh.payload(l4) catch return, now_us / 1_000_000);
        return;
    }
    if (h.protocol == 6 and host_mac != null and conn.state != .closed) {
        if (!checksum.verifyTcp(h.src, h.dst, l4)) return;
        handleTcp(l4, now_us);
    }
}

fn bringup() void {
    hw.initTimer();
    _ = hw.disableRtcWdt();
    emac.enableBusClock();
    pins.initRgmii();
    pins.initPhyReset();
    pins.initMdio(pins.default_mdc, pins.default_mdio);
    emac.resetRegisters();
    _ = apll.ensure125(50_000);
    emac.enableRgmiiClocks();
    emac.resetDma(20_000) catch log.raw("wire: dma reset failed\n");
    emac.setCsrDiv(regs.csr_div_safest);
    const found = emac.scanPhy(2_000);
    _ = emac.yt8531RgmiiInit();
    if (found == null) {
        log.raw("wire: no PHY\n");
        return;
    }
    emac.restartAutoneg(0, 2_000) catch {};
    _ = emac.waitLink(0, 5_000_000);
    const ssr = emac.mdioRead(0, 0x11, 2_000) catch 0;
    const speed: emac.Speed = switch ((ssr >> 14) & 3) {
        1 => .m100,
        2 => .m1000,
        else => .m10,
    };
    _ = emac.initMacConfig(speed, true);
    emac.setMacAddress(local_mac);
    _ = emac.initDmaDefaults();
    emac.initTxRing();
    emac.initRxRing(true);
    emac.setRingAddresses();
    emac.startDma();
    hw.delayUs(1_000_000);
}

pub fn run() bool {
    passed = 0;
    failed = 0;
    log.raw("wire: bring-up\n");
    bringup();
    check(hw.readReg(regs.gmac + regs.mac.version) & 0xFF == 0x37, "emac version", .{});

    var frame: [1600]u8 = undefined;
    var dhcp_ok = false;
    var last_sec: u64 = 0;
    const t0 = hw.nowUs();
    while (!dhcp_ok and hw.elapsedUs(t0) < 12_000_000) {
        const now_s = hw.nowUs() / 1_000_000;
        if (now_s != last_sec) {
            last_sec = now_s;
            switch (dhcp_client.poll(now_s)) {
                .send_discover => {
                    log.raw("wire: dhcp DISCOVER\n");
                    sendDhcp(.discover, null, null);
                },
                .send_request => sendDhcp(.request, dhcp_client.offered_ip, dhcp_client.server_id),
                else => {},
            }
        }
        const r = emac.rxPollCopy(20_000, &frame) catch continue;
        if (r) |len| {
            if (len <= frame.len) handleFrame(frame[0..len], hw.nowUs());
            if (dhcp_client.state == .bound) dhcp_ok = true;
        }
    }
    if (!dhcp_ok) {
        log.raw("wire: skipped/no-dhcp-server\n");
        log.line("wire: checks passed={d} failed={d}", .{ passed, failed });
        log.line("checks: passed={d} failed={d} total={d}", .{ passed, failed, passed + failed });
        return true;
    }
    check(true, "dhcp bound ip={d}.{d}.{d}.{d}", .{ board_ip[0], board_ip[1], board_ip[2], board_ip[3] });

    if (dhcp_ok) {
        sendArpRequest(host_ip);
        const ta = hw.nowUs();
        while (host_mac == null and hw.elapsedUs(ta) < 2_000_000) {
            const r = emac.rxPollCopy(20_000, &frame) catch continue;
            if (r) |len| if (len <= frame.len) handleFrame(frame[0..len], hw.nowUs());
        }
        check(host_mac != null, "arp host mac", .{});
        if (host_mac != null) {
            // R2.2d：握手由 socket 层的 connect + 真实 Conn 并行驱动。
            cfd = @intCast(tbl.connect());
            sendAction(conn.activeOpen(syn_iss, hw.nowUs()));
            log.line("wire: tcp SYN sent iss=0x{x:0>8} fd={d}", .{ syn_iss, cfd.? });
            const tt = hw.nowUs();
            while (conn.state != .established and hw.elapsedUs(tt) < 3_000_000) {
                const now_us = hw.nowUs();
                sendAction(conn.tick(now_us));
                const r = emac.rxPollCopy(20_000, &frame) catch continue;
                if (r) |len| if (len <= frame.len) handleFrame(frame[0..len], now_us);
            }
            check(conn.state == .established, "tcp handshake", .{});
            if (conn.state == .established) {
                log.line("wire: tcp ESTABLISHED state={s} snd_una=0x{x:0>8} rcv_nxt=0x{x:0>8}", .{ conn.state.name(), conn.snd_una, conn.rcv_nxt });
                const fd = cfd.?;
                check(tbl.socks[fd].state == .established, "socket layer established", .{});
                // 走一次应用数据：socket API 写 64 B → Conn 分配序号 → 主机 ACK → drainTx。
                var payload: [64]u8 = undefined;
                for (&payload, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
                const io = tbl.socks[fd].send(&payload);
                check(io.n == payload.len, "socket send accepted", .{});
                const ts = hw.nowUs();
                while (drained < payload.len and hw.elapsedUs(ts) < 2_000_000) {
                    const now_us = hw.nowUs();
                    sendAction(conn.tick(now_us));
                    while (true) {
                        const sk = &tbl.socks[fd];
                        const pend = sk.txPending();
                        if (pend == 0) break;
                        const want: usize = @intCast(conn.snd_nxt -% bases.local_iss);
                        const skbase = sk.txSeqBase();
                        if (want < skbase) break;
                        const avail = pend - (want - skbase);
                        if (avail == 0) break;
                        const a = conn.sendData(@min(avail, conn.mss), conn.snd_wnd, now_us);
                        if (!a.send) break;
                        sendAction(a);
                    }
                    const r = emac.rxPollCopy(20_000, &frame) catch continue;
                    if (r) |len| if (len <= frame.len) handleFrame(frame[0..len], now_us);
                }
                check(drained == payload.len, "socket tx acked", .{});
                log.line("wire: socket tx drained={d} state={s}", .{ drained, tbl.socks[fd].state.name() });
                hw.delayUs(100_000);
                // RST 不是 `Conn` 的输出（它只做 FIN）：生产探针用它结束 profile，
                // 不走 FIN/TIME_WAIT 的 60 s。Action 的 `to` 在这里只是标签。
                sendAction(.{ .send = true, .seq = conn.snd_nxt, .ack = conn.rcv_nxt, .flags = .{ .rst = true, .ack = true }, .to = .established });
                log.raw("wire: tcp RST sent\n");
            }
        }
    }
    log.line("wire: checks passed={d} failed={d}", .{ passed, failed });
    log.line("checks: passed={d} failed={d} total={d}", .{ passed, failed, passed + failed });
    return failed == 0;
}
