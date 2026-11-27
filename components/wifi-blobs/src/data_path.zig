//! Wi-Fi 数据通路：驱动给的以太网帧 ⇄ 本工程自己的 IP 栈（ARP / ICMP / DHCP）。
//!
//! 驱动一侧是 IDF 的 netif 口（`components/esp_wifi/src/wifi_netif.c`、`wifi_default.c`）替换 lwip 的
//! 那几个 blob 入口（`components/esp_wifi/include/esp_private/wifi.h`）：
//!
//!   - `esp_wifi_internal_reg_rxcb(WIFI_IF_STA, rxcb)`：STA 连上之后注册（IDF 在 `WIFI_EVENT_STA_CONNECTED`
//!     的默认处理里做）；驱动每收一帧数据帧就调 `rxcb(buffer, len, eb)`，`buffer` 是完整的以太网帧，
//!     `eb` 是它所在的驱动缓冲；
//!   - `esp_wifi_internal_free_rx_buffer(eb)`：那一帧用完，把驱动缓冲交还。IDF 的 lwip 口是先拷走、再交还
//!     （`wlanif_input`，`CONFIG_LWIP_L2_TO_L3_COPY`），这里一样；
//!   - `esp_wifi_internal_tx(WIFI_IF_STA, frame, len)`：发一帧完整的以太网帧；
//!   - 拿到地址之后 `esp_wifi_internal_set_sta_ip()`（IDF 在 got-ip 的默认处理里做）。
//!
//! IP 一侧是 `net-ipv4`（`arp` / `icmp` / `ipv4` / `inet`）与 `net-udp-dhcp-dns`（`udp` / `dhcp`）。
//! 没有路由表、没有 socket：地址靠 DHCP 拿（含续租、重绑、到期）。收到的报文只处理三类：DHCP 应答、
//! ARP（问本机地址的要答，本机问出去的应答要学）、本机发出的回显的应答。ping 的对象是租约里的网关。
//!
//! 驱动在自己的 Wi-Fi 任务里调 `rxcb`，那个任务跑在我们给它的栈上（`osi_impl.ensureTaskContext`）。
//! 所以 `rxcb` 只做三件事：过滤、拷进本模块的环形缓冲、交还驱动缓冲。帧由主上下文的 `poll()` 处理，
//! 回帧（ARP 请求、DHCP 报文、ICMP 回显）也都从主上下文发——不在驱动的收帧路径里回头调它的发送入口。

const std = @import("std");
const ip4 = @import("net_ipv4");
const udpmod = @import("net_udp");

const inet = ip4.inet;
const ipv4 = ip4.ipv4;
const arp = ip4.arp;
const icmp = ip4.icmp;
const udp = udpmod.udp;
const dhcp = udpmod.dhcp;

/// `WIFI_IF_STA`（`esp_wifi_types_native.h`）。
pub const wifi_if_sta: c_int = 0;
/// `ESP_OK` / `ESP_ERR_INVALID_ARG` / `ESP_ERR_NO_MEM`。
pub const ok: c_int = 0;
pub const err_invalid_arg: c_int = 0x102;
pub const err_no_mem: c_int = 0x101;

const ethertype_ipv4: u16 = 0x0800;
const ethertype_arp: u16 = 0x0806;
const broadcast_mac: [6]u8 = @splat(0xFF);

/// 以太网帧上限（不含 FCS）。
pub const mtu_frame: usize = 1514;
/// 以太网帧最短 60 字节：不足的补 0。补在我们这一侧，不指望驱动。
const eth_min_frame: usize = 60;
/// 收帧环形缓冲的槽数。
const rx_slots: usize = 4;

const ping_id: u16 = 0x3150;
/// 回显请求载荷的上限：IP 包 1500 字节减去 IPv4 首部 20 与 ICMP 首部 8。内容是字节的序号（第 i 个字节是 i）。
const ping_payload_max = 1500 - 20 - 8;
const ping_payload_bytes = blk: {
    @setEvalBranchQuota(4 * ping_payload_max);
    var a: [ping_payload_max]u8 = undefined;
    for (&a, 0..) |*b, i| b.* = @truncate(i);
    break :blk a;
};
/// 回显请求的载荷长度，默认 32。合并镜像的广播实验按 `-Dcoex-adv-ping-bytes` 改它（经 `link_probe.zig` 的 `ping_bytes`）：
/// 一帧越长大占空口的时间越长，「有吞吐的时候」离得更近。
pub var ping_bytes: usize = 32;
var ping_buf: [icmp.header_len + ping_payload_max]u8 = undefined;
/// 两帧之间的间隔，默认 1 秒。同一时间只有一帧在飞（等应答最多 `ping_timeout_us`），所以间隔比它短时，
/// 就是上一帧回来（或超时）之后马上发下一帧。合并镜像的广播实验按 `-Dcoex-adv-ping-interval-ms` 改它
/// （经 `link_probe.zig` 的 `ping_interval_us`），好让「BLE 广播着的时候有持续的 Wi-Fi 流量」有足够长的窗口。
pub var ping_interval_us: u64 = 1_000_000;
const ping_timeout_us: u64 = 1_000_000;

fn pingPayload() []const u8 {
    return ping_payload_bytes[0..@min(ping_bytes, ping_payload_max)];
}

const drv = struct {
    const reg_rxcb = @extern(*const fn (c_int, ?*const fn (?*anyopaque, u16, ?*anyopaque) callconv(.c) c_int) callconv(.c) c_int, .{ .name = "esp_wifi_internal_reg_rxcb" });
    const free_rx_buffer = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "esp_wifi_internal_free_rx_buffer" });
    const internal_tx = @extern(*const fn (c_int, [*]const u8, u16) callconv(.c) c_int, .{ .name = "esp_wifi_internal_tx" });
    const get_macaddr = @extern(*const fn (u8, *[6]u8) callconv(.c) c_int, .{ .name = "esp_wifi_get_macaddr_internal" });
    const set_sta_ip = @extern(*const fn () callconv(.c) c_int, .{ .name = "esp_wifi_internal_set_sta_ip" });
};

/// `poll()` 里发生的一件事，给调用方打日志用（`report` 把它排成一行）。
pub const Event = union(enum) {
    /// DHCP：发出了 DISCOVER。`attempt` 是第几次重试（0 = 第一次）。
    dhcp_discover: struct { attempt: u8, tx_rc: c_int },
    /// DHCP：选址阶段的 REQUEST 重试（`attempt` ≥ 1）。
    dhcp_request: struct { attempt: u8, tx_rc: c_int },
    /// 收到 OFFER，并按它发出了 REQUEST。
    dhcp_offer: struct { ip: [4]u8, tx_rc: c_int },
    /// 续租（单播给服务器）或重绑（广播）：发出了 REQUEST。
    dhcp_renew: struct { rebind: bool, attempt: u8, tx_rc: c_int },
    /// 租约到期（或服务器回了 NAK）：地址作废，邻居表清空，进行中的 ping 作废。
    lease_expired,
    /// 拿到租约。此后模块已经调过 `esp_wifi_internal_set_sta_ip()`。
    bound: struct { ip: [4]u8, mask: [4]u8, router: [4]u8, dns: [4]u8, sta_ip_rc: c_int },
    /// 别人用 ARP 请求问本机当前的地址，答了。`ip` / `mac` 是问的人。
    arp_answered: struct { ip: [4]u8, mac: [6]u8, tx_rc: c_int },
    arp_request: struct { ip: [4]u8, tx_rc: c_int },
    arp_reply: struct { ip: [4]u8, mac: [6]u8 },
    echo_sent: struct { seq: u16, tx_rc: c_int },
    echo_reply: struct { seq: u16, rtt_us: u32 },
    echo_timeout: u16,
    ping_done: PingStats,
    /// 驱动交来的帧放不进缓冲（缓冲满或太长），丢了；数字是累计数。
    rx_dropped: u32,
};

pub const PingStats = struct {
    sent: u16 = 0,
    received: u16 = 0,
    timed_out: u16 = 0,
    rtt_min_us: u32 = 0,
    rtt_max_us: u32 = 0,
    rtt_sum_us: u32 = 0,

    pub fn rttAvgUs(self: PingStats) u32 {
        return if (self.received == 0) 0 else self.rtt_sum_us / self.received;
    }
};

pub const Stats = struct {
    rx_frames: u32 = 0,
    /// 交上来、但不是发给本机的帧。
    rx_ignored: u32 = 0,
    rx_dropped: u32 = 0,
    tx_frames: u32 = 0,
    tx_failed: u32 = 0,
};

var local_mac: [6]u8 = @splat(0);
var attached: bool = false;
var counters: Stats = .{};
var rx_dropped_reported: u32 = 0;

var rx_ring: [rx_slots][mtu_frame]u8 = undefined;
var rx_len: [rx_slots]u16 = @splat(0);
var rx_head: usize = 0;
var rx_tail: usize = 0;

var client: dhcp.Client = .{};
var bound: bool = false;
/// 上一次推进 DHCP 的整秒。初值是一个到不了的秒数：第一次 `poll()` 不管落在哪一秒都要推进。
var last_sec: u64 = std.math.maxInt(u64);
var ip_id: u16 = 0x3100;

/// 本机用得上的邻居：网关与 DHCP 服务器（家里通常是同一台）。
const neighbors_max: usize = 2;
var neighbor_ip: [neighbors_max][4]u8 = @splat(inet.any);
var neighbor_mac: [neighbors_max][6]u8 = @splat(@splat(0));

const Inflight = struct { seq: u16, sent_at: u64 };
var ping_active: bool = false;
var ping_left: u16 = 0;
var inflight: ?Inflight = null;
var next_ping_us: u64 = 0;
var ping_stats: PingStats = .{};

// 发送用的静态缓冲：只在主上下文的 `poll()` 里用，不重入。
var tx_frame: [mtu_frame]u8 = undefined;
var ip_buf: [mtu_frame]u8 = undefined;
var dgram_buf: [576]u8 = undefined;
var bootp_buf: [600]u8 = undefined;

// ---------------------------------------------------------------------------
// 对外
// ---------------------------------------------------------------------------

/// 清掉全部状态（主机测试也用它）。
pub fn reset() void {
    attached = false;
    counters = .{};
    rx_dropped_reported = 0;
    rx_len = @splat(0);
    rx_head = 0;
    rx_tail = 0;
    client = .{};
    bound = false;
    last_sec = std.math.maxInt(u64);
    ip_id = 0x3100;
    neighbor_ip = @splat(inet.any);
    ping_active = false;
    ping_left = 0;
    inflight = null;
    next_ping_us = 0;
    ping_stats = .{};
}

/// 连上之后调：取本机 MAC，向驱动注册收帧回调。返回驱动的返回码。
pub fn start() c_int {
    reset();
    const rc = drv.get_macaddr(@intCast(wifi_if_sta), &local_mac);
    if (rc != ok) return rc;
    const rrc = drv.reg_rxcb(wifi_if_sta, &rxCb);
    attached = rrc == ok;
    return rrc;
}

/// 断开之前调：向驱动注销收帧回调。
pub fn stop() void {
    if (!attached) return;
    attached = false;
    _ = drv.reg_rxcb(wifi_if_sta, null);
}

/// 主上下文每一步调一次，直到返回空。每一步按顺序看：有没有帧被丢、DHCP 的每秒推进、ping、收到的下一帧。
pub fn poll(now_us: u64) ?Event {
    if (counters.rx_dropped != rx_dropped_reported) {
        rx_dropped_reported = counters.rx_dropped;
        return .{ .rx_dropped = rx_dropped_reported };
    }
    if (dhcpTick(now_us)) |ev| return ev;
    if (pingTick(now_us)) |ev| return ev;
    const slot = rx_head % rx_slots;
    const n = rx_len[slot];
    if (n == 0) return null;
    const ev = handleFrame(rx_ring[slot][0..n], now_us);
    // 处理完才把这一格让出来：处理期间缓冲区里还是这一帧。
    rx_len[slot] = 0;
    rx_head +%= 1;
    return ev;
}

/// 开始 ping 租约里的网关：每隔 `ping_interval_us`（默认 1 秒）一帧，共 `count` 帧；等应答最多 1 秒。要先拿到租约。
pub fn startPing(count: u16, now_us: u64) void {
    if (!bound or count == 0) return;
    ping_active = true;
    ping_left = count;
    inflight = null;
    next_ping_us = now_us;
    ping_stats = .{};
}

/// 当前租约；没有租约时各项全 0。
pub fn lease() dhcp.Lease {
    return if (bound) client.lease else .{};
}

pub fn stats() Stats {
    return counters;
}

fn ip4Text(buf: []u8, ip: [4]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch buf[0..0];
}

fn macText(buf: []u8, mac: [6]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch buf[0..0];
}

/// 把一件事排成一行（`buf` 给 128 字节够用）。
pub fn report(ev: Event, buf: []u8) []const u8 {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    var m: [18]u8 = undefined;
    var c: [16]u8 = undefined;
    return switch (ev) {
        .dhcp_discover => |d| std.fmt.bufPrint(buf, "dhcp DISCOVER attempt={d} tx rc=0x{x}", .{ d.attempt, @as(u32, @bitCast(d.tx_rc)) }) catch buf[0..0],
        .dhcp_request => |d| std.fmt.bufPrint(buf, "dhcp REQUEST retry attempt={d} tx rc=0x{x}", .{ d.attempt, @as(u32, @bitCast(d.tx_rc)) }) catch buf[0..0],
        .dhcp_offer => |d| std.fmt.bufPrint(buf, "dhcp OFFER ip={s} -> REQUEST tx rc=0x{x}", .{ ip4Text(&a, d.ip), @as(u32, @bitCast(d.tx_rc)) }) catch buf[0..0],
        .dhcp_renew => |d| std.fmt.bufPrint(buf, "dhcp {s} REQUEST attempt={d} tx rc=0x{x}", .{ if (d.rebind) "rebind(broadcast)" else "renew(unicast)", d.attempt, @as(u32, @bitCast(d.tx_rc)) }) catch buf[0..0],
        .lease_expired => std.fmt.bufPrint(buf, "dhcp lease expired: address dropped", .{}) catch buf[0..0],
        .bound => |d| std.fmt.bufPrint(buf, "dhcp ACK: bound ip={s} mask={s} router={s} dns={s}, esp_wifi_internal_set_sta_ip rc=0x{x}", .{
            ip4Text(&a, d.ip),               ip4Text(&b, d.mask), ip4Text(&m, d.router), ip4Text(&c, d.dns),
            @as(u32, @bitCast(d.sta_ip_rc)),
        }) catch buf[0..0],
        .arp_answered => |d| std.fmt.bufPrint(buf, "arp answered {s} ({s}) tx rc=0x{x}", .{
            ip4Text(&a, d.ip), macText(&m, d.mac), @as(u32, @bitCast(d.tx_rc)),
        }) catch buf[0..0],
        .arp_request => |d| std.fmt.bufPrint(buf, "arp request for {s} tx rc=0x{x}", .{ ip4Text(&a, d.ip), @as(u32, @bitCast(d.tx_rc)) }) catch buf[0..0],
        .arp_reply => |d| std.fmt.bufPrint(buf, "arp reply: {s} is {s}", .{ ip4Text(&a, d.ip), macText(&m, d.mac) }) catch buf[0..0],
        .echo_sent => |d| std.fmt.bufPrint(buf, "ping seq={d} tx rc=0x{x}", .{ d.seq, @as(u32, @bitCast(d.tx_rc)) }) catch buf[0..0],
        .echo_reply => |d| std.fmt.bufPrint(buf, "ping reply seq={d} rtt={d} us", .{ d.seq, d.rtt_us }) catch buf[0..0],
        .echo_timeout => |seq| std.fmt.bufPrint(buf, "ping timeout seq={d}", .{seq}) catch buf[0..0],
        .ping_done => |p| std.fmt.bufPrint(buf, "ping done: sent={d} received={d} timed_out={d} rtt min/avg/max={d}/{d}/{d} us", .{
            p.sent, p.received, p.timed_out, p.rtt_min_us, p.rttAvgUs(), p.rtt_max_us,
        }) catch buf[0..0],
        .rx_dropped => |n| std.fmt.bufPrint(buf, "rx dropped (ring full or oversized), total={d}", .{n}) catch buf[0..0],
    };
}

// ---------------------------------------------------------------------------
// 驱动一侧
// ---------------------------------------------------------------------------

/// 驱动的收帧回调：跑在驱动的 Wi-Fi 任务里。过滤、拷走、交还，别的不做。
fn rxCb(buffer: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c_int {
    // 交还之后那块内存就不能再读，所以交还放在最后。
    defer if (eb) |e| drv.free_rx_buffer(e);
    const src: [*]const u8 = @ptrCast(buffer orelse return err_invalid_arg);
    const n: usize = len;
    if (n < 14 or n > mtu_frame) {
        counters.rx_dropped += 1;
        return err_invalid_arg;
    }
    // 只留发给本机或广播的帧。驱动的过滤之外难免漏进来，这里再筛一遍，省一次拷贝。
    const dst = src[0..6].*;
    if (!std.mem.eql(u8, &dst, &local_mac) and !arp.isBroadcastMac(dst)) {
        counters.rx_ignored += 1;
        return ok;
    }
    const slot = rx_tail % rx_slots;
    if (rx_len[slot] != 0) {
        counters.rx_dropped += 1;
        return err_no_mem;
    }
    @memcpy(rx_ring[slot][0..n], src[0..n]);
    rx_len[slot] = len;
    rx_tail +%= 1;
    counters.rx_frames += 1;
    return ok;
}

// ---------------------------------------------------------------------------
// 主上下文：每秒的 DHCP、ping
// ---------------------------------------------------------------------------

/// `a` 不早于 `b`（回绕安全的比较）。
fn reached(a: u64, b: u64) bool {
    return a -% b < (1 << 63);
}

fn dropLease() void {
    bound = false;
    neighbor_ip = @splat(inet.any);
    ping_active = false;
    inflight = null;
}

fn neighborMac(ip: [4]u8) ?[6]u8 {
    for (neighbor_ip, neighbor_mac) |nb_ip, nb_mac| {
        if (inet.eql(nb_ip, ip)) return nb_mac;
    }
    return null;
}

/// 记下一条邻居。只记本机用得上的那两个地址，所以表不会满。
fn learnNeighbor(ip: [4]u8, mac: [6]u8) void {
    for (neighbor_ip, 0..) |nb_ip, i| {
        if (inet.eql(nb_ip, ip)) {
            neighbor_mac[i] = mac;
            return;
        }
    }
    for (neighbor_ip, 0..) |nb_ip, i| {
        if (inet.eql(nb_ip, inet.any)) {
            neighbor_ip[i] = ip;
            neighbor_mac[i] = mac;
            return;
        }
    }
}

/// 本机用得上的地址：网关、DHCP 服务器。ARP 应答只认它们的。
fn isWanted(ip: [4]u8) bool {
    return inet.eql(ip, client.lease.router) or inet.eql(ip, client.server_id);
}

const DhcpKind = enum { discover, select, renew, rebind };

fn dhcpTick(now_us: u64) ?Event {
    const now_s = now_us / 1_000_000;
    if (now_s == last_sec) return null;
    last_sec = now_s;
    switch (client.poll(now_s)) {
        .idle => return null,
        .send_discover => {
            const rc = sendDhcp(.discover);
            return .{ .dhcp_discover = .{ .attempt = client.attempts, .tx_rc = rc } };
        },
        .send_request => {
            const rc = sendDhcp(.select);
            return .{ .dhcp_request = .{ .attempt = client.attempts, .tx_rc = rc } };
        },
        .send_renew, .send_rebind => |want| {
            // 续租要单播给服务器，得先有它的 MAC（拿到租约时从回帧里学）；没有就退成重绑的广播形式。
            const renewing = want == .send_renew and neighborMac(client.server_id) != null;
            const rc = sendDhcp(if (renewing) .renew else .rebind);
            return .{ .dhcp_renew = .{ .rebind = !renewing, .attempt = client.attempts, .tx_rc = rc } };
        },
        .lease_expired => {
            const was_bound = bound;
            dropLease();
            return if (was_bound) .lease_expired else null;
        },
    }
}

fn pingTick(now_us: u64) ?Event {
    if (!ping_active) return null;
    if (inflight) |f| {
        if (!reached(now_us, f.sent_at +% ping_timeout_us)) return null;
        inflight = null;
        ping_stats.timed_out += 1;
        return .{ .echo_timeout = f.seq };
    }
    if (ping_left == 0) {
        ping_active = false;
        return .{ .ping_done = ping_stats };
    }
    if (!reached(now_us, next_ping_us)) return null;
    next_ping_us = now_us +% ping_interval_us;
    const gateway = client.lease.router;
    const mac = neighborMac(gateway) orelse {
        const rc = sendArpRequest(gateway);
        return .{ .arp_request = .{ .ip = gateway, .tx_rc = rc } };
    };
    const seq = ping_stats.sent;
    const rc = sendEcho(seq, gateway, mac);
    ping_stats.sent += 1;
    ping_left -= 1;
    if (rc != ok) {
        // 没发出去就没有应答可等：按丢帧计，下一帧照常。
        ping_stats.timed_out += 1;
    } else {
        inflight = .{ .seq = seq, .sent_at = now_us };
    }
    return .{ .echo_sent = .{ .seq = seq, .tx_rc = rc } };
}

// ---------------------------------------------------------------------------
// 主上下文：收到的帧
// ---------------------------------------------------------------------------

/// 收到的以太网帧。返回这一帧引出的事件。
fn handleFrame(frame: []const u8, now_us: u64) ?Event {
    if (frame.len < 14) return null;
    const dst = frame[0..6].*;
    if (!std.mem.eql(u8, &dst, &local_mac) and !arp.isBroadcastMac(dst)) return null;
    const etype = std.mem.readInt(u16, frame[12..14], .big);
    if (etype == ethertype_arp) return handleArp(frame[14..]);
    if (etype != ethertype_ipv4) return null;
    const pkt = frame[14..];
    const h = ipv4.Header.parseChecked(pkt) catch return null;
    if (h.isFragmented()) return null;
    const l4 = h.payload(pkt) catch return null;
    switch (h.protocol) {
        ipv4.proto.udp => {
            if (inet.eql(h.src, inet.any)) return null; // 没有地址的发送方不可能是 DHCP 服务器
            const uh = udp.Header.parse(l4) catch return null;
            if (uh.dst_port != dhcp.client_port) return null;
            if (udp.check(h.src, h.dst, l4) == .bad) return null;
            const payload = uh.payload(l4) catch return null;
            return handleDhcp(frame[6..12].*, payload, now_us);
        },
        ipv4.proto.icmp => {
            // 只收发给本机地址的报文。`l4` 是按 IP 首部的 total_len 切出来的，不含以太网填充。
            if (!bound or !inet.eql(h.dst, client.lease.ip)) return null;
            return handleEchoReply(h.src, l4, now_us);
        },
        else => return null,
    }
}

fn handleArp(body: []const u8) ?Event {
    const p = arp.Packet.parse(body) catch return null;
    if (p.op == arp.Op.request) {
        // 别人问的是本机当前的地址：答（RFC 826）。不答的话对端手里没有本机的 MAC，发给本机的单播
        // 一律发不出去——2026-11-26 实测 ping 网关：AP 每次都先用 ARP 请求来问本机，等不到应答，
        // 回显应答就永远不出门（对端缓存里碰巧还有本机时才通，所以时通时不通）。
        if (!bound or !inet.eql(p.tpa, client.lease.ip)) return null;
        var buf: [arp.packet_len]u8 = undefined;
        const r = (arp.Packet{ .op = arp.Op.reply, .sha = local_mac, .spa = p.tpa, .tha = p.sha, .tpa = p.spa }).write(&buf) catch return null;
        const rc = sendFrame(p.sha, ethertype_arp, r);
        return .{ .arp_answered = .{ .ip = p.spa, .mac = p.sha, .tx_rc = rc } };
    }
    if (p.op != arp.Op.reply) return null;
    // 只认本机用得上的地址的应答，而且必须是答给本机当前地址的。
    if (!bound or !inet.eql(p.tpa, client.lease.ip) or !isWanted(p.spa)) return null;
    learnNeighbor(p.spa, p.sha);
    // 正等它发回显：下一帧马上发，不用再等一格。
    if (ping_active) next_ping_us = 0;
    return .{ .arp_reply = .{ .ip = p.spa, .mac = p.sha } };
}

/// `src_mac` 是回帧的以太网源地址：DHCP 服务器的 MAC 从这里学。
fn handleDhcp(src_mac: [6]u8, payload: []const u8, now_us: u64) ?Event {
    var msg = dhcp.parseFixed(payload) catch return null;
    var opts = dhcp.Options{};
    dhcp.parseOptions(payload, &opts) catch return null;
    const action = client.onReply(&msg, &opts, now_us / 1_000_000) catch return null;
    switch (action) {
        .send_request => {
            const rc = sendDhcp(.select);
            return .{ .dhcp_offer = .{ .ip = msg.yiaddr, .tx_rc = rc } };
        },
        .idle => {
            if (opts.message_type == .nak) {
                // 服务器说这个地址不能给你：地址作废，下一秒重新 DISCOVER。
                const was_bound = bound;
                dropLease();
                return if (was_bound) .lease_expired else null;
            }
            if (bound or client.state != .bound) return null;
            bound = true;
            learnNeighbor(client.server_id, src_mac);
            const rc = drv.set_sta_ip();
            return .{ .bound = .{ .ip = client.lease.ip, .router = client.lease.router, .mask = client.lease.mask, .dns = client.lease.dns, .sta_ip_rc = rc } };
        },
        else => return null,
    }
}

fn handleEchoReply(src: [4]u8, l4: []const u8, now_us: u64) ?Event {
    const f = inflight orelse return null;
    if (!inet.eql(src, client.lease.router)) return null;
    const h = icmp.Header.parse(l4) catch return null;
    if (h.type != icmp.typ.echo_reply or h.code != 0) return null;
    if (h.id != ping_id or h.seq_or_mtu != f.seq) return null;
    if (l4.len != icmp.header_len + pingPayload().len) return null;
    if (!icmp.checksumOk(l4)) return null;
    inflight = null;
    const rtt: u32 = @intCast(@min(now_us -% f.sent_at, std.math.maxInt(u32)));
    ping_stats.received += 1;
    if (ping_stats.received == 1 or rtt < ping_stats.rtt_min_us) ping_stats.rtt_min_us = rtt;
    if (rtt > ping_stats.rtt_max_us) ping_stats.rtt_max_us = rtt;
    ping_stats.rtt_sum_us += rtt;
    return .{ .echo_reply = .{ .seq = f.seq, .rtt_us = rtt } };
}

// ---------------------------------------------------------------------------
// 主上下文：发帧
// ---------------------------------------------------------------------------

fn sendFrame(dst: [6]u8, ethertype: u16, payload: []const u8) c_int {
    const n = 14 + payload.len;
    if (n > tx_frame.len) return err_no_mem;
    tx_frame[0..6].* = dst;
    tx_frame[6..12].* = local_mac;
    std.mem.writeInt(u16, tx_frame[12..14], ethertype, .big);
    @memcpy(tx_frame[14..n], payload);
    const total = @max(n, eth_min_frame);
    @memset(tx_frame[n..total], 0);
    const rc = drv.internal_tx(wifi_if_sta, &tx_frame, @intCast(total));
    if (rc == ok) {
        counters.tx_frames += 1;
    } else counters.tx_failed += 1;
    return rc;
}

fn sendIpv4(dst_mac: [6]u8, src: [4]u8, dst: [4]u8, protocol: u8, l4: []const u8) c_int {
    if (20 + l4.len > ip_buf.len) return err_no_mem;
    var ih = ipv4.Header{ .total_len = @intCast(20 + l4.len), .id = ip_id, .ttl = 64, .protocol = protocol, .src = src, .dst = dst };
    ip_id +%= 1;
    const hlen = ih.write(&ip_buf) catch return err_no_mem;
    @memcpy(ip_buf[hlen..][0..l4.len], l4);
    return sendFrame(dst_mac, ethertype_ipv4, ip_buf[0 .. hlen + l4.len]);
}

fn sendUdp(dst_mac: [6]u8, src: [4]u8, dst: [4]u8, sport: u16, dport: u16, payload: []const u8) c_int {
    const total = udp.Header.len + payload.len;
    if (total > dgram_buf.len) return err_no_mem;
    const uh = udp.Header{ .src_port = sport, .dst_port = dport, .length = @intCast(total) };
    _ = uh.write(dgram_buf[0..udp.Header.len]) catch return err_no_mem;
    @memcpy(dgram_buf[udp.Header.len..total], payload);
    udp.seal(src, dst, dgram_buf[0..total]) catch return err_no_mem;
    return sendIpv4(dst_mac, src, dst, ipv4.proto.udp, dgram_buf[0..total]);
}

fn sendDhcp(kind: DhcpKind) c_int {
    const selecting = kind == .discover or kind == .select;
    const ciaddr: [4]u8 = if (selecting) inet.any else client.lease.ip;
    var msg = dhcp.Msg{ .xid = client.xid, .flags = .{ .broadcast = selecting }, .ciaddr = ciaddr };
    @memcpy(msg.chaddr[0..6], &local_mac);
    var b = dhcp.Builder.init(&bootp_buf, msg) catch return err_no_mem;
    const mt: dhcp.MsgType = if (kind == .discover) .discover else .request;
    b.option(dhcp.Option.message_type, &.{@backingInt(mt)}) catch return err_no_mem;
    if (kind == .select) {
        // 选址阶段的 REQUEST 指名要 OFFER 给的地址、带服务器标识；续租 / 重绑的走 ciaddr（RFC 2131 §4.3.2）。
        b.ip(dhcp.Option.requested_ip, client.offered_ip) catch return err_no_mem;
        b.ip(dhcp.Option.server_id, client.server_id) catch return err_no_mem;
    }
    b.option(dhcp.Option.param_list, &dhcp.default_param_list) catch return err_no_mem;
    const pkt = b.finish() catch return err_no_mem;
    var src = inet.any;
    var dst = inet.broadcast;
    var dst_mac = broadcast_mac;
    if (kind == .renew) {
        // 续租：单播给服务器，源地址已经是本机。
        dst_mac = neighborMac(client.server_id) orelse return err_invalid_arg;
        src = client.lease.ip;
        dst = client.server_id;
    } else if (kind == .rebind) {
        src = client.lease.ip;
    }
    return sendUdp(dst_mac, src, dst, dhcp.client_port, dhcp.server_port, pkt);
}

fn sendArpRequest(target: [4]u8) c_int {
    var buf: [arp.packet_len]u8 = undefined;
    const src_ip = if (bound) client.lease.ip else inet.any;
    const p = (arp.Packet{ .op = arp.Op.request, .sha = local_mac, .spa = src_ip, .tpa = target }).write(&buf) catch return err_no_mem;
    return sendFrame(broadcast_mac, ethertype_arp, p);
}

fn sendEcho(seq: u16, dst: [4]u8, dst_mac: [6]u8) c_int {
    const n = icmp.writeEchoRequest(&ping_buf, ping_id, seq, pingPayload()) catch return err_no_mem;
    return sendIpv4(dst_mac, client.lease.ip, dst, ipv4.proto.icmp, ping_buf[0..n]);
}

// ---------------------------------------------------------------------------
// 主机侧用例：假驱动 + 手搭的帧
// ---------------------------------------------------------------------------

const testing = std.testing;
const fake = @import("host_stubs.zig").fake;

const sta_mac = [6]u8{ 0x24, 0x6f, 0x28, 0x11, 0x22, 0x33 };
const ap_mac = [6]u8{ 0x44, 0xf7, 0x70, 0x16, 0xfa, 0xba };
/// DHCP 服务器与网关是两台机器：这样才走得到"先问网关的 MAC"那一步。
const server_ip: [4]u8 = .{ 192, 168, 43, 250 };
const gateway_ip: [4]u8 = .{ 192, 168, 43, 1 };
const gateway_mac = [6]u8{ 0x44, 0xf7, 0x70, 0x16, 0xfa, 0xbb };
const our_ip: [4]u8 = .{ 192, 168, 43, 77 };
const our_mask: [4]u8 = .{ 255, 255, 255, 0 };

var eb_token: u8 = 0;
var deliver_buf: [1600]u8 = undefined;

/// 驱动交上来一帧（`eb` 是个假句柄）。返回回调的返回码。
fn deliver(frame: []const u8) c_int {
    @memcpy(deliver_buf[0..frame.len], frame);
    return fake.rxcb.?(&deliver_buf, @intCast(frame.len), &eb_token);
}

fn lastTx() []const u8 {
    const i = fake.n_tx - 1;
    return fake.tx_frames[i][0..fake.tx_lens[i]];
}

fn ipPacket(buf: []u8, src: [4]u8, dst: [4]u8, protocol: u8, l4: []const u8) []const u8 {
    var h = ipv4.Header{ .total_len = @intCast(20 + l4.len), .id = 0x1234, .ttl = 64, .protocol = protocol, .src = src, .dst = dst };
    const n = h.write(buf) catch unreachable;
    @memcpy(buf[n..][0..l4.len], l4);
    return buf[0 .. n + l4.len];
}

fn udpDgram(buf: []u8, src: [4]u8, dst: [4]u8, sport: u16, dport: u16, payload: []const u8) []const u8 {
    const total = udp.Header.len + payload.len;
    const uh = udp.Header{ .src_port = sport, .dst_port = dport, .length = @intCast(total) };
    _ = uh.write(buf[0..udp.Header.len]) catch unreachable;
    @memcpy(buf[udp.Header.len..total], payload);
    udp.seal(src, dst, buf[0..total]) catch unreachable;
    return buf[0..total];
}

fn dhcpPayload(buf: []u8, xid: u32, mt: dhcp.MsgType, yiaddr: [4]u8, lease_secs: u32) []const u8 {
    const msg = dhcp.Msg{ .op = .reply, .xid = xid, .yiaddr = yiaddr };
    var b = dhcp.Builder.init(buf, msg) catch unreachable;
    b.option(dhcp.Option.message_type, &.{@backingInt(mt)}) catch unreachable;
    b.ip(dhcp.Option.server_id, server_ip) catch unreachable;
    b.ip(dhcp.Option.subnet_mask, our_mask) catch unreachable;
    b.ip(dhcp.Option.router, gateway_ip) catch unreachable;
    b.u32Opt(dhcp.Option.lease_time, lease_secs) catch unreachable;
    return b.finish() catch unreachable;
}

fn eth(buf: []u8, dst: [6]u8, src: [6]u8, etype: u16, payload: []const u8) []const u8 {
    buf[0..6].* = dst;
    buf[6..12].* = src;
    std.mem.writeInt(u16, buf[12..14], etype, .big);
    @memcpy(buf[14..][0..payload.len], payload);
    return buf[0 .. 14 + payload.len];
}

var fb_eth: [1600]u8 = undefined;
var fb_ip: [1500]u8 = undefined;
var fb_l4: [700]u8 = undefined;
var fb_pay: [700]u8 = undefined;

/// 服务器发给本机的一帧：以太网 + IPv4 + UDP + 载荷。
fn udpFrame(dst_ip: [4]u8, sport: u16, dport: u16, payload: []const u8) []const u8 {
    const dgram = udpDgram(&fb_l4, server_ip, dst_ip, sport, dport, payload);
    const pkt = ipPacket(&fb_ip, server_ip, dst_ip, ipv4.proto.udp, dgram);
    return eth(&fb_eth, sta_mac, ap_mac, ethertype_ipv4, pkt);
}

fn dhcpFrame(xid: u32, mt: dhcp.MsgType, yiaddr: [4]u8, lease_secs: u32) []const u8 {
    return udpFrame(inet.broadcast, dhcp.server_port, dhcp.client_port, dhcpPayload(&fb_pay, xid, mt, yiaddr, lease_secs));
}

fn arpFrame(op: u16, spa: [4]u8, sha: [6]u8, tpa: [4]u8) []const u8 {
    const body = (arp.Packet{ .op = op, .sha = sha, .spa = spa, .tha = sta_mac, .tpa = tpa }).write(fb_pay[0..arp.packet_len]) catch unreachable;
    return eth(&fb_eth, sta_mac, sha, ethertype_arp, body);
}

fn echoReplyFrame(seq: u16, corrupt_checksum: bool) []const u8 {
    var n = icmp.writeEchoReply(fb_l4[0..], ping_id, seq, pingPayload()) catch unreachable;
    if (corrupt_checksum) {
        fb_l4[2] ^= 0xFF;
        n = icmp.header_len + pingPayload().len;
    }
    const pkt = ipPacket(&fb_ip, gateway_ip, our_ip, ipv4.proto.icmp, fb_l4[0..n]);
    return eth(&fb_eth, sta_mac, gateway_mac, ethertype_ipv4, pkt);
}

/// 走完 DHCP 四步（第 0 秒起），租期 `lease_secs`。返回时已经 bound。
fn runDhcp(lease_secs: u32) !void {
    fake.reset();
    fake.mac = sta_mac;
    try testing.expectEqual(ok, start());
    _ = poll(0).?;
    var xid: u32 = 0;
    {
        const h = try ipv4.Header.parseChecked(lastTx()[14..]);
        const l4 = try h.payload(lastTx()[14..]);
        const uh = try udp.Header.parse(l4);
        xid = (try dhcp.parseFixed(try uh.payload(l4))).xid;
    }
    _ = deliver(dhcpFrame(xid, .offer, our_ip, 0));
    _ = poll(100_000).?;
    _ = deliver(dhcpFrame(xid, .ack, our_ip, lease_secs));
    _ = poll(200_000).?;
}

test "data_path: DHCP 四步——DISCOVER、OFFER→REQUEST、ACK；帧逐层对得上，拿到租约后通知驱动" {
    fake.reset();
    fake.mac = sta_mac;
    try testing.expectEqual(ok, start());
    try testing.expect(fake.rxcb != null);

    // 第 0 秒：DISCOVER（广播，源地址 0.0.0.0，chaddr 是本机 MAC）。
    try testing.expectEqual(Event{ .dhcp_discover = .{ .attempt = 0, .tx_rc = 0 } }, poll(0).?);
    const disc = lastTx();
    try testing.expectEqualSlices(u8, &broadcast_mac, disc[0..6]);
    try testing.expectEqualSlices(u8, &sta_mac, disc[6..12]);
    try testing.expectEqual(@as(u16, ethertype_ipv4), std.mem.readInt(u16, disc[12..14], .big));
    const dh = try ipv4.Header.parseChecked(disc[14..]);
    try testing.expect(inet.eql(dh.src, inet.any) and inet.eql(dh.dst, inet.broadcast));
    const dl4 = try dh.payload(disc[14..]);
    const duh = try udp.Header.parse(dl4);
    try testing.expectEqual(@as(u16, dhcp.client_port), duh.src_port);
    try testing.expectEqual(@as(u16, dhcp.server_port), duh.dst_port);
    const dpayload = try duh.payload(dl4);
    const dmsg = try dhcp.parseFixed(dpayload);
    var dopts = dhcp.Options{};
    try dhcp.parseOptions(dpayload, &dopts);
    try testing.expectEqual(dhcp.MsgType.discover, dopts.message_type.?);
    try testing.expectEqualSlices(u8, &sta_mac, dmsg.chaddr[0..6]);
    try testing.expect(dmsg.flags.broadcast);
    const xid = dmsg.xid;
    try testing.expectEqual(@as(u32, 0), fake.sta_ip_calls);

    // OFFER：按它发 REQUEST（指名要 OFFER 的地址，带服务器标识）。
    try testing.expectEqual(ok, deliver(dhcpFrame(xid, .offer, our_ip, 0)));
    try testing.expectEqual(@as(u32, 1), fake.freed_rx_buffers);
    try testing.expectEqual(Event{ .dhcp_offer = .{ .ip = our_ip, .tx_rc = 0 } }, poll(100_000).?);
    const req = lastTx();
    const rh = try ipv4.Header.parseChecked(req[14..]);
    try testing.expect(inet.eql(rh.src, inet.any) and inet.eql(rh.dst, inet.broadcast));
    const rl4 = try rh.payload(req[14..]);
    const rpayload = try (try udp.Header.parse(rl4)).payload(rl4);
    var ropts = dhcp.Options{};
    try dhcp.parseOptions(rpayload, &ropts);
    try testing.expectEqual(dhcp.MsgType.request, ropts.message_type.?);
    try testing.expectEqual(our_ip, ropts.requested_ip.?);
    try testing.expectEqual(server_ip, ropts.server_id.?);
    try testing.expectEqual(@as(u32, 0), fake.sta_ip_calls);

    // ACK：拿到租约，通知驱动。
    try testing.expectEqual(ok, deliver(dhcpFrame(xid, .ack, our_ip, 3600)));
    try testing.expectEqual(
        Event{ .bound = .{ .ip = our_ip, .mask = our_mask, .router = gateway_ip, .dns = server_ip, .sta_ip_rc = 0 } },
        poll(200_000).?,
    );
    try testing.expectEqual(@as(u32, 1), fake.sta_ip_calls);
    const l = lease();
    try testing.expectEqual(our_ip, l.ip);
    try testing.expectEqual(gateway_ip, l.router);
    try testing.expectEqual(our_mask, l.mask);
    try testing.expect(poll(200_000) == null);
}

test "data_path: ping 网关——先问网关的 MAC，回显一帧一答；超时与对不上号的应答都不算收到" {
    try runDhcp(3600);

    startPing(3, 1_000_000);
    // 网关的 MAC 还不知道：先发 ARP 请求（ARP 应答不是本机问过的地址就不学）。
    try testing.expectEqual(Event{ .arp_request = .{ .ip = gateway_ip, .tx_rc = 0 } }, poll(1_000_000).?);
    const ar = arp.Packet.parse(lastTx()[14..]) catch unreachable;
    try testing.expectEqual(arp.Op.request, ar.op);
    try testing.expectEqualSlices(u8, &sta_mac, &ar.sha);
    try testing.expectEqual(our_ip, ar.spa);
    try testing.expectEqual(gateway_ip, ar.tpa);
    try testing.expectEqual(ok, deliver(arpFrame(arp.Op.reply, .{ 192, 168, 43, 9 }, .{ 1, 2, 3, 4, 5, 6 }, our_ip)));
    try testing.expect(poll(1_000_000) == null);

    try testing.expectEqual(ok, deliver(arpFrame(arp.Op.reply, gateway_ip, gateway_mac, our_ip)));
    try testing.expectEqual(Event{ .arp_reply = .{ .ip = gateway_ip, .mac = gateway_mac } }, poll(1_000_000).?);
    // 学到网关的 MAC 之后回显立刻发出去（第 0 帧）。
    try testing.expectEqual(Event{ .echo_sent = .{ .seq = 0, .tx_rc = 0 } }, poll(1_000_000).?);
    const er = lastTx();
    try testing.expectEqualSlices(u8, &gateway_mac, er[0..6]);
    const eh = try ipv4.Header.parseChecked(er[14..]);
    try testing.expectEqual(our_ip, eh.src);
    try testing.expectEqual(gateway_ip, eh.dst);
    try testing.expectEqual(ipv4.proto.icmp, eh.protocol);
    const el4 = try eh.payload(er[14..]);
    const eih = try icmp.Header.parse(el4);
    try testing.expectEqual(icmp.typ.echo_request, eih.type);
    try testing.expectEqual(ping_id, eih.id);
    try testing.expectEqual(@as(u16, 0), eih.seq_or_mtu);
    try testing.expect(icmp.checksumOk(el4));

    // 校验和坏的应答不算。
    try testing.expectEqual(ok, deliver(echoReplyFrame(0, true)));
    try testing.expect(poll(1_300_000) == null);
    // 对得上的应答：rtt = 300 µs。
    try testing.expectEqual(ok, deliver(echoReplyFrame(0, false)));
    try testing.expectEqual(Event{ .echo_reply = .{ .seq = 0, .rtt_us = 300_000 } }, poll(1_300_000).?);

    // 第 1 帧 1 秒后发，没人应：1 秒后超时。第 2 帧紧跟着发，等到了。
    try testing.expectEqual(Event{ .echo_sent = .{ .seq = 1, .tx_rc = 0 } }, poll(2_000_000).?);
    try testing.expectEqual(Event{ .echo_timeout = 1 }, poll(3_000_000).?);
    try testing.expectEqual(Event{ .echo_sent = .{ .seq = 2, .tx_rc = 0 } }, poll(3_000_000).?);
    try testing.expectEqual(ok, deliver(echoReplyFrame(2, false)));
    try testing.expectEqual(Event{ .echo_reply = .{ .seq = 2, .rtt_us = 100_000 } }, poll(3_100_000).?);
    try testing.expectEqual(
        Event{ .ping_done = .{ .sent = 3, .received = 2, .timed_out = 1, .rtt_min_us = 100_000, .rtt_max_us = 300_000, .rtt_sum_us = 400_000 } },
        poll(3_100_000).?,
    );
    try testing.expect(poll(4_000_000) == null);
}

test "data_path: 回显请求的载荷长度是参数（默认 32）；长度对不上的应答不是对这一帧的应答" {
    ping_bytes = 600;
    defer ping_bytes = 32;
    try runDhcp(3600);

    startPing(2, 1_000_000);
    try testing.expectEqual(Event{ .arp_request = .{ .ip = gateway_ip, .tx_rc = 0 } }, poll(1_000_000).?);
    try testing.expectEqual(ok, deliver(arpFrame(arp.Op.reply, gateway_ip, gateway_mac, our_ip)));
    try testing.expectEqual(Event{ .arp_reply = .{ .ip = gateway_ip, .mac = gateway_mac } }, poll(1_000_000).?);
    try testing.expectEqual(Event{ .echo_sent = .{ .seq = 0, .tx_rc = 0 } }, poll(1_000_000).?);
    // 发出去的请求：ICMP 首部 8 + 载荷 600，载荷第 i 个字节是 i。
    const er = lastTx();
    const el4 = try (try ipv4.Header.parseChecked(er[14..])).payload(er[14..]);
    try testing.expectEqual(@as(usize, icmp.header_len + 600), el4.len);
    try testing.expectEqualSlices(u8, ping_payload_bytes[0..600], el4[icmp.header_len..]);
    try testing.expect(icmp.checksumOk(el4));

    // 默认长度（32）的应答：序号对得上，长度对不上，不算收到；这一帧到 1 秒还是超时。
    ping_bytes = 32;
    const short = deliver(echoReplyFrame(0, false));
    ping_bytes = 600;
    try testing.expectEqual(ok, short);
    try testing.expect(poll(1_300_000) == null);
    try testing.expectEqual(Event{ .echo_timeout = 0 }, poll(2_000_000).?);
    // 第 1 帧也是 600 字节；同长度的应答才算，rtt = 100 ms。
    try testing.expectEqual(Event{ .echo_sent = .{ .seq = 1, .tx_rc = 0 } }, poll(2_000_000).?);
    try testing.expectEqual(ok, deliver(echoReplyFrame(1, false)));
    try testing.expectEqual(Event{ .echo_reply = .{ .seq = 1, .rtt_us = 100_000 } }, poll(2_100_000).?);
    try testing.expectEqual(
        Event{ .ping_done = .{ .sent = 2, .received = 1, .timed_out = 1, .rtt_min_us = 100_000, .rtt_max_us = 100_000, .rtt_sum_us = 100_000 } },
        poll(2_100_000).?,
    );
    // 给得比上限大：按上限发，不会越界。
    ping_bytes = ping_payload_max + 100;
    try testing.expectEqual(@as(usize, ping_payload_max), pingPayload().len);
}
test "data_path: ARP 请求问的是本机地址就答（单播给问的人），问别的地址、还没拿到地址时都不答" {
    try runDhcp(3600);
    const tx_before = fake.n_tx;
    const body = (arp.Packet{
        .op = arp.Op.request,
        .sha = gateway_mac,
        .spa = gateway_ip,
        .tha = @splat(0),
        .tpa = our_ip,
    }).write(fb_pay[0..arp.packet_len]) catch unreachable;
    var frame_buf: [64]u8 = undefined;
    const ask = eth(&frame_buf, broadcast_mac, gateway_mac, ethertype_arp, body);

    // 网关来问本机的地址（板上 2026-11-26 实测就是这样：AP 每次回 ping 应答之前都先来问本机）。
    try testing.expectEqual(ok, deliver(ask));
    try testing.expectEqual(Event{ .arp_answered = .{ .ip = gateway_ip, .mac = gateway_mac, .tx_rc = 0 } }, poll(1_000_000).?);
    const ans = lastTx();
    try testing.expectEqual(@as(usize, tx_before + 1), fake.n_tx);
    try testing.expectEqualSlices(u8, &gateway_mac, ans[0..6]); // 单播给问的人
    try testing.expectEqualSlices(u8, &sta_mac, ans[6..12]);
    try testing.expectEqual(@as(u16, ethertype_arp), std.mem.readInt(u16, ans[12..14], .big));
    const rep = try arp.Packet.parse(ans[14..]);
    try testing.expectEqual(arp.Op.reply, rep.op);
    try testing.expectEqualSlices(u8, &sta_mac, &rep.sha);
    try testing.expectEqual(our_ip, rep.spa);
    try testing.expectEqualSlices(u8, &gateway_mac, &rep.tha);
    try testing.expectEqual(gateway_ip, rep.tpa);

    // 问的是别的地址：不答。
    const other_body = (arp.Packet{
        .op = arp.Op.request,
        .sha = gateway_mac,
        .spa = gateway_ip,
        .tha = @splat(0),
        .tpa = server_ip,
    }).write(fb_pay[0..arp.packet_len]) catch unreachable;
    try testing.expectEqual(ok, deliver(eth(&frame_buf, broadcast_mac, gateway_mac, ethertype_arp, other_body)));
    try testing.expect(poll(1_000_000) == null);
    try testing.expectEqual(@as(usize, tx_before + 1), fake.n_tx);

    // 租约到期之后本机没有地址了：谁问都不答。
    try testing.expectEqual(Event.lease_expired, poll(3600_200_000).?);
    try testing.expectEqual(ok, deliver(ask));
    try testing.expect(poll(3600_200_000) == null);
    try testing.expectEqual(@as(usize, tx_before + 1), fake.n_tx);
}

test "data_path: rxcb 只留发给本机或广播的帧，每帧交还一次驱动缓冲；缓冲满了、帧太长都丢并计数" {
    fake.reset();
    fake.mac = sta_mac;
    try testing.expectEqual(ok, start());

    // 发给别的 MAC 的单播帧：不进缓冲，但驱动缓冲照样交还。
    const alien = eth(&fb_eth, .{ 1, 2, 3, 4, 5, 6 }, ap_mac, ethertype_arp, fb_pay[0..28]);
    try testing.expectEqual(ok, deliver(alien));
    try testing.expectEqual(@as(u32, 1), fake.freed_rx_buffers);
    // 第一次 `poll()` 落在新的一秒：DHCP 从这里起步，先发 DISCOVER。
    try testing.expectEqual(Event{ .dhcp_discover = .{ .attempt = 0, .tx_rc = 0 } }, poll(0).?);
    try testing.expect(poll(0) == null);
    try testing.expectEqual(@as(u32, 1), stats().rx_ignored);

    // 太短、太长的帧都丢。
    try testing.expectEqual(err_invalid_arg, deliver(fb_eth[0..10]));
    try testing.expectEqual(err_invalid_arg, deliver(fb_eth[0 .. mtu_frame + 1]));
    try testing.expectEqual(@as(u32, 3), fake.freed_rx_buffers);
    try testing.expectEqual(Event{ .rx_dropped = 2 }, poll(0).?);

    // 一个没人处理的广播帧（IPv4，协议号 253）：进缓冲，取走之后没有事件。
    const junk_pkt = ipPacket(&fb_ip, server_ip, inet.broadcast, 253, "junk");
    const junk = eth(&fb_eth, broadcast_mac, ap_mac, ethertype_ipv4, junk_pkt);
    for (0..rx_slots) |_| try testing.expectEqual(ok, deliver(junk));
    try testing.expectEqual(err_no_mem, deliver(junk)); // 缓冲满：第 5 帧丢
    try testing.expectEqual(@as(u32, rx_slots), stats().rx_frames);
    try testing.expectEqual(Event{ .rx_dropped = 3 }, poll(0).?);
    for (0..rx_slots) |_| try testing.expect(poll(0) == null);
    try testing.expect(poll(0) == null);
    // 丢掉的那一帧同样把驱动缓冲交还了。
    try testing.expectEqual(@as(u32, 8), fake.freed_rx_buffers);

    // 注销：驱动拿到的是空回调。
    stop();
    try testing.expect(fake.rxcb == null);
}

test "data_path: 租约的续租与到期——t1 起单播 REQUEST，t2 起广播；到期地址作废、ping 作废、重新 DISCOVER" {
    try runDhcp(16); // t1 = 8 秒，t2 = 14 秒
    try testing.expectEqual(@as(u32, 1), fake.sta_ip_calls);

    // t1：续租。服务器的 MAC 在拿到租约时从回帧的源地址学到了。单播、源地址是本机、不带服务器标识。
    try testing.expectEqual(Event{ .dhcp_renew = .{ .rebind = false, .attempt = 0, .tx_rc = 0 } }, poll(8_000_000).?);
    const rn = lastTx();
    try testing.expectEqualSlices(u8, &ap_mac, rn[0..6]);
    const rh = try ipv4.Header.parseChecked(rn[14..]);
    try testing.expectEqual(our_ip, rh.src);
    try testing.expectEqual(server_ip, rh.dst);
    const rl4 = try rh.payload(rn[14..]);
    var ropts = dhcp.Options{};
    const rpayload = try (try udp.Header.parse(rl4)).payload(rl4);
    const rmsg = try dhcp.parseFixed(rpayload);
    try dhcp.parseOptions(rpayload, &ropts);
    try testing.expectEqual(dhcp.MsgType.request, ropts.message_type.?);
    try testing.expectEqual(our_ip, rmsg.ciaddr);
    try testing.expect(!rmsg.flags.broadcast);
    try testing.expect(ropts.server_id == null and ropts.requested_ip == null);
    // 4 秒没应答重试一次。
    try testing.expectEqual(Event{ .dhcp_renew = .{ .rebind = false, .attempt = 1, .tx_rc = 0 } }, poll(12_000_000).?);

    // t2：改成广播重绑（源地址还是本机）。
    try testing.expectEqual(Event{ .dhcp_renew = .{ .rebind = true, .attempt = 0, .tx_rc = 0 } }, poll(14_000_000).?);
    const rb = lastTx();
    try testing.expectEqualSlices(u8, &broadcast_mac, rb[0..6]);
    const bh = try ipv4.Header.parseChecked(rb[14..]);
    try testing.expectEqual(our_ip, bh.src);
    try testing.expect(inet.eql(bh.dst, inet.broadcast));

    // 没人应：租约到期。此刻在进行的 ping 一起作废（不再有 ping 的事件），地址清掉，下一秒重新 DISCOVER。
    startPing(1, 15_000_000);
    try testing.expectEqual(Event{ .arp_request = .{ .ip = gateway_ip, .tx_rc = 0 } }, poll(15_000_000).?);
    try testing.expectEqual(Event.lease_expired, poll(16_000_000).?);
    try testing.expect(inet.eql(lease().ip, inet.any));
    try testing.expectEqual(Event{ .dhcp_discover = .{ .attempt = 0, .tx_rc = 0 } }, poll(17_000_000).?);
}

test "data_path: 续租的 ACK 把租期续上，不重复通知驱动" {
    try runDhcp(16);
    var xid: u32 = 0;
    {
        const h = try ipv4.Header.parseChecked(fake.tx_frames[0][14..]);
        const l4 = try h.payload(fake.tx_frames[0][14..]);
        xid = (try dhcp.parseFixed(try (try udp.Header.parse(l4)).payload(l4))).xid;
    }
    try testing.expectEqual(Event{ .dhcp_renew = .{ .rebind = false, .attempt = 0, .tx_rc = 0 } }, poll(8_000_000).?);
    // 服务器回 ACK，租期换成 3600 秒：之后 50 秒内不再有续租。
    try testing.expectEqual(ok, deliver(dhcpFrame(xid, .ack, our_ip, 3600)));
    try testing.expect(poll(8_500_000) == null);
    try testing.expect(poll(60_000_000) == null);
    try testing.expectEqual(our_ip, lease().ip);
    try testing.expectEqual(@as(u32, 1), fake.sta_ip_calls);
}
