//! ble-802154：板侧自检（19 条判据）。
//!
//! 本组件板侧**不碰射频**：没有扫描、没有连接、没有读特征值、没有 Thread 入网。
//! controller 归档（libble_app.a 等）一个字节都没链接（见 `tools/symbols.sh`
//! 的产物与`docs/history/` 的历史说明/27.11）。被测对象全是纯逻辑：
//!
//!   `hci.zig`      —— HCI 分帧（ACL / Command / Event / LE Meta）
//!   `att.zig`      —— ATT 8 个操作码的字节布局与 MTU 截断
//!   `gatt.zig`     —— 定长特征表、句柄分配、权限、CCCD 订阅
//!   `fifteen4.zig` —— 802.15.4 FCF/地址 + 6LoWPAN IPHC 解压
//!   `hci_cmd.zig` / `hci_evt.zig` —— HCI 控制命令、事件分发、命令与 ACL 额度
//!   `acl.zig` / `l2cap.zig` —— ACL 分片重组、L2CAP 信令与 credit based 通道
//!   `gap_adv.zig` / `ipsp.zig` —— 广播数据与设备地址、IPv6 over BLE
//!
//! 19 条判据（每条一行 `check: ... ok=1/0`，数字全部来自实际比较）：
//!
//!   ① ACL 头编码 = 42 30 05 00，且 decode 往返一致
//!   ② ACL 251 字节上限：252 字节被拒（rejected=1），251 字节通过
//!   ③ ATT_MTU 交换：请求 247 → 协商 247 → 响应 03 F7 00；22 被拒
//!   ④ Read Request/Response 字节级 KAT（0A 25 00 / 0B 63 68 32 37）+ MTU 截断
//!   ⑤ 写权限拒绝：只读句柄 → ATT 0x03，Error Response 01 12 02 00 03
//!   ⑥ Notification + CCCD：未订阅不产生字节；订阅后 1B 02 00 't=21'
//!   ⑦ 句柄越界 → Error Response 01 0A 99 00 01
//!   ⑧ GATT 表容量：8 个特征注册成功，第 9 个 table_full，表不变
//!   ⑨ FCF 编码/解码：0x8861（双短）与 0xC861（源长）
//!   ⑩ 短/长地址模式：头长 9 / 15 字节，地址类型可判别
//!   ⑪ 6LoWPAN 解压：两个无状态案例（SAM/DAM=10 与 =11）
//!   ⑫ 不支持的压缩（SAC=1、P≠00、非 IPHC）被拒，rejected 计数准确
//!   ⑬ HCI 控制命令：3 条编码器 KAT + 返回参数；未知 OpCode / 截断被拒
//!   ⑭ 事件分发 + host 状态：命令额度 Busy、ACL 包额度取尽与还回、未知子事件
//!   ⑮ ACL：61 字节 PDU 切成 27/27/7 再重组；续片先到被拒
//!   ⑯ L2CAP：连接参数更新两个角色；credit based 通道收发与额度耗尽
//!   ⑰ 广播数据：AD 构造 = 旧 KAT、31 字节上限、解析、坏结构被拒
//!   ⑱ 地址：AES-128 FIPS-197 KAT、RPA 生成与解析（对的/错的 IRK）
//!   ⑲ IPv6 over BLE：IID 与 RFC 7668 §3.2.4.1 的压缩字节、组播监听表
//!
//! 所有状态都在 `.bss` 的静态变量里：板侧没有堆，自检也不依赖分配失败。

const std = @import("std");

const att = @import("att.zig");
const fifteen4 = @import("fifteen4.zig");
const gatt = @import("gatt.zig");
const hci = @import("hci.zig");
const acl = @import("acl.zig");
const cmd = @import("hci_cmd.zig");
const evt = @import("hci_evt.zig");
const gap = @import("gap_adv.zig");
const ipsp = @import("ipsp.zig");
const l2cap = @import("l2cap.zig");
const vectors = @import("vectors.zig");
const board = @import("board");
const log = board.log;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

var hci_stats: hci.Stats = .{};
var att_stats: att.Stats = .{};
var g4_stats: fifteen4.Stats = .{};
var table: gatt.Table = .{};

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [180]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `?Error` 与错误字面量的比较：Zig 不允许 `opt == error.Foo`，这里按名字比。
fn isErr(x: anytype, want: anyerror) bool {
    const e = x orelse return false;
    return std.mem.eql(u8, @errorName(e), @errorName(want));
}

fn addChar(uuid: u16, perm: gatt.Perm, initial: []const u8) u16 {
    return switch (table.add(uuid, perm, initial)) {
        .handle => |h| h,
        .err => 0,
    };
}

// ---------------------------------------------------------------------------
// ① ACL 头编码
// ---------------------------------------------------------------------------

fn checkAclHeader() void {
    hci_stats.reset();
    const hdr = hci.AclHeader{
        .handle = 0x042,
        .pb = .previously_used,
        .bc = .point_to_point,
        .data_len = 5,
    };
    var bytes: [4]u8 = undefined;
    hdr.encode(&bytes);
    const back = hci.AclHeader.decode(&bytes) catch hci.AclHeader{
        .handle = 0,
        .pb = .previously_used,
        .bc = .point_to_point,
        .data_len = 0,
    };
    const ok = eql(&bytes, &hci.kat_acl_header) and
        back.handle == 0x042 and
        back.data_len == 5 and
        back.pb == .previously_used;

    var hex_buf: [12]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch "?";
    check(ok, "hci acl header {s} handle=0x{x:0>3} pb={d}", .{
        hex, back.handle, @backingInt(back.pb),
    });
}

// ---------------------------------------------------------------------------
// ② ACL 最大长度（必须能区分“拒绝”与“静默截断”）
// ---------------------------------------------------------------------------

fn checkAclMax() void {
    hci_stats.reset();
    var buf: [hci.acl_buf_size]u8 = undefined;

    const big: [hci.acl_max_payload + 1]u8 = @splat(0xaa);
    var over_err: ?hci.Error = null;
    if (hci.encodeAcl(&buf, 0x042, .previously_used, &big, &hci_stats)) |_| {} else |e| over_err = e;
    const rejected = hci_stats.rejected;
    const encoded_after_over = hci_stats.acl_encoded;

    const ok_payload: [hci.acl_max_payload]u8 = @splat(0x55);
    const total = hci.encodeAcl(&buf, 0x042, .previously_used, &ok_payload, &hci_stats) catch 0;
    const back = hci.decodeAcl(buf[0..total], &hci_stats) catch null;

    // 再解一次被砍掉尾巴的包：必须计入 truncated，而不是静默通过。
    var trunc_err: ?hci.Error = null;
    if (hci.decodeAcl(buf[0 .. total - 1], &hci_stats)) |_| {} else |e| trunc_err = e;
    const truncated = hci_stats.truncated;

    const ok = isErr(over_err, error.Oversize) and
        rejected == 1 and
        encoded_after_over == 0 and
        total == hci.acl_header_len + hci.acl_max_payload and
        back != null and back.?.payload.len == hci.acl_max_payload and
        isErr(trunc_err, error.Short) and
        truncated == 1;
    check(ok, "hci acl max={d} oversize_rejected={d} encoded={d} truncated={d}", .{
        hci.acl_max_payload, rejected, hci_stats.acl_encoded, truncated,
    });
}

// ---------------------------------------------------------------------------
// ③ ATT_MTU 交换
// ---------------------------------------------------------------------------

fn checkMtuExchange() void {
    att_stats.reset();
    var buf: [8]u8 = undefined;

    const client = att.decodeMtuReq(&att.kat_mtu_req, &att_stats) catch 0;
    const negotiated = att.negotiate(client, att.max_mtu);
    const rsp_len = att.encodeMtuRsp(&buf, negotiated, &att_stats) catch 0;

    // 22 < 23：**本组件更严的自定策略**（规范只规定 23 是默认/最小值，没要求
    // 拒绝；本机 NimBLE 是夹到 23，见 ble_att.c:494-496）。这里选择显式拒绝，
    // 因为这章的判据要一个可判别的失败，而不是静默钳位。
    const small: [3]u8 = .{ 0x02, 0x16, 0x00 };
    var small_err: ?att.Error = null;
    if (att.decodeMtuReq(&small, &att_stats)) |_| {} else |e| small_err = e;
    const exchanges_after_reject = att_stats.mtu_exchanges;

    const ok = client == 247 and
        negotiated == 247 and
        rsp_len == 3 and
        eql(buf[0..3], &att.kat_mtu_rsp) and
        isErr(small_err, error.MtuTooSmall) and
        exchanges_after_reject == 1 and
        att_stats.rejected == 1;
    check(ok, "att mtu req={d} negotiated={d} rsp=03f700 rejected={d} exchanges={d}", .{
        client, negotiated, att_stats.rejected, att_stats.mtu_exchanges,
    });
}

// ---------------------------------------------------------------------------
// ④ Read Request / Response + MTU 截断
// ---------------------------------------------------------------------------

fn checkReadKats() void {
    att_stats.reset();
    var buf: [64]u8 = undefined;

    const req_len = att.encodeReadReq(&buf, 0x0025, &att_stats) catch 0;
    const req_ok = req_len == 3 and eql(buf[0..3], &att.kat_read_req);

    const rsp_len = att.encodeReadRsp(&buf, "ch27", 23, &att_stats) catch 0;
    const rsp_ok = rsp_len == 5 and eql(buf[0..5], &att.kat_read_rsp);

    // 30 字节值、MTU=23 → 只能放 22 字节，截断计数 +1。
    const long: [30]u8 = @splat('x');
    const cut = att.encodeReadRsp(&buf, &long, 23, &att_stats) catch 0;
    const ok = req_ok and rsp_ok and cut == 23 and
        att_stats.truncated == 1 and
        att_stats.reads == 2;
    check(ok, "att read req=0a2500 rsp=0b-ch27 cut={d} truncated={d}", .{
        cut, att_stats.truncated,
    });
}

// ---------------------------------------------------------------------------
// ⑤ 写权限拒绝（断言具体错误码）
// ---------------------------------------------------------------------------

fn checkWritePermission() void {
    att_stats.reset();
    table.reset();
    var buf: [32]u8 = undefined;

    // 特征 #1：只读，句柄 0x0001(声明) / 0x0002(值)。
    const h_ro = addChar(0x2a00, gatt.Perm.ro(), "ro");
    // 特征 #2：读写，句柄 0x0003 / 0x0004。
    const h_rw = addChar(0x2a01, gatt.Perm.rw(), "rw");

    const denied = table.handleWrite(h_ro, "nope", &buf, &att_stats);
    var err_pdu: [5]u8 = undefined;
    const denied_ok = switch (denied) {
        .err => |e| blk: {
            if (e != .write_not_permitted) break :blk false;
            const code = e.code() orelse break :blk false;
            if (code != .write_not_permitted) break :blk false;
            _ = att.encodeError(&err_pdu, .write_req, h_ro, code, &att_stats) catch
                break :blk false;
            const expect = [5]u8{ 0x01, 0x12, 0x02, 0x00, 0x03 };
            break :blk eql(&err_pdu, &expect);
        },
        .pdu => false,
    };

    const allowed = table.handleWrite(h_rw, "ok", &buf, &att_stats);
    const allowed_ok = switch (allowed) {
        .pdu => |n| n == 1 and buf[0] == 0x13,
        .err => false,
    };

    const ok = h_ro == 0x0002 and h_rw == 0x0004 and
        denied_ok and allowed_ok and
        att_stats.errors_emitted == 1 and
        table.stats.writes == 1;
    check(ok, "gatt write ro_handle=0x{x:0>4} code=0x{x:0>2} err_pdu=0112020003 ok_writes={d}", .{
        h_ro, @backingInt(att.Code.write_not_permitted), table.stats.writes,
    });
}

// ---------------------------------------------------------------------------
// ⑥ Notification + CCCD 订阅
// ---------------------------------------------------------------------------

fn checkNotify() void {
    att_stats.reset();
    table.reset();
    var buf: [32]u8 = @splat(0xa5);

    // 特征 #1：读 + 通知，值 "t=21"。声明=1 值=2 CCCD=3。
    const h_val = addChar(0x2a06, gatt.Perm.rn(), "t=21");
    const h_cccd = h_val + 1;

    // 未订阅：本地错误，且不得写入任何字节（buf[0] 仍是 0xa5）。
    const unsub = table.notify(h_val, &buf, 23, &att_stats);
    const untouched = buf[0] == 0xa5;
    const unsub_ok = switch (unsub) {
        .err => |e| e == .not_subscribed and e.code() == null,
        .pdu => false,
    };

    // 订阅：写 CCCD {01 00}。
    const sub = table.handleWrite(h_cccd, &[_]u8{ 0x01, 0x00 }, &buf, &att_stats);
    const sub_ok = switch (sub) {
        .pdu => |n| n == 1 and buf[0] == 0x13,
        .err => false,
    };

    buf[0] = 0xa5;
    const sent = table.notify(h_val, &buf, 23, &att_stats);
    const expect = [7]u8{ 0x1b, 0x02, 0x00, 't', '=', '2', '1' };
    const sent_ok = switch (sent) {
        .pdu => |n| n == 7 and eql(buf[0..7], &expect),
        .err => false,
    };

    // 退订：CCCD {00 00}，之后 notify 再次被拒（且不占订阅槽）。
    const unsub_pdu = table.handleWrite(h_cccd, &[_]u8{ 0x00, 0x00 }, &buf, &att_stats);
    const unsub_write_ok = switch (unsub_pdu) {
        .pdu => |n| n == 1,
        .err => false,
    };
    const after = table.notify(h_val, &buf, 23, &att_stats);
    const after_ok = switch (after) {
        .err => |e| e == .not_subscribed,
        .pdu => false,
    };

    const ok = h_val == 0x0002 and h_cccd == 0x0003 and
        untouched and unsub_ok and sub_ok and sent_ok and
        unsub_write_ok and after_ok and
        table.subCount() == 0 and table.stats.subs == 1 and table.stats.unsubs == 1;
    check(ok, "notify unsub_untouched={d} cccd=0x{x:0>4} pdu=1b0200-t21 subs={d}/{d}", .{
        @intFromBool(untouched), h_cccd, table.stats.subs, table.stats.unsubs,
    });
}

// ---------------------------------------------------------------------------
// ⑦ 句柄越界 → Error Response
// ---------------------------------------------------------------------------

fn checkHandleRange() void {
    att_stats.reset();
    table.reset();
    var buf: [32]u8 = undefined;
    _ = addChar(0x2a00, gatt.Perm.ro(), "v");

    // 0x0099 从未分配；0x0000 是保留的无效句柄；0x0001 是声明句柄（不可读）。
    const r1 = table.handleRead(0x0099, &buf, 23, &att_stats);
    const r2 = table.handleRead(0x0000, &buf, 23, &att_stats);
    const r3 = table.handleRead(0x0001, &buf, 23, &att_stats);

    var pdu: [5]u8 = undefined;
    const code_ok = switch (r1) {
        .err => |e| blk: {
            const c = e.code() orelse break :blk false;
            if (c != .invalid_handle) break :blk false;
            _ = att.encodeError(&pdu, .read_req, 0x0099, c, &att_stats) catch
                break :blk false;
            break :blk eql(&pdu, &att.kat_error_rsp);
        },
        .pdu => false,
    };
    const both_err = (switch (r2) {
        .err => |e| e == .invalid_handle,
        .pdu => false,
    }) and (switch (r3) {
        .err => |e| e == .invalid_handle,
        .pdu => false,
    });

    check(code_ok and both_err and att_stats.errors_emitted == 1, "gatt handle range 0x0099=01-0a990001 reserved_rejected={d} errors={d}", .{
        @intFromBool(both_err), att_stats.errors_emitted,
    });
}

// ---------------------------------------------------------------------------
// ⑧ GATT 表容量上限
// ---------------------------------------------------------------------------

fn checkTableCapacity() void {
    table.reset();
    var added: u8 = 0;
    var i: u8 = 0;
    while (i < gatt.max_chars) : (i += 1) {
        const h = addChar(0x2a00 + @as(u16, i), gatt.Perm.ro(), "x");
        if (h != 0) added += 1;
    }
    const next_before = table.next_handle;
    const ninth = table.add(0x2a10, gatt.Perm.ro(), "x");
    const full_ok = switch (ninth) {
        .err => |e| blk: {
            if (e != .table_full) break :blk false;
            const c = e.code() orelse break :blk false;
            break :blk c == .insufficient_resources;
        },
        .handle => false,
    };
    const ok = added == gatt.max_chars and
        table.countOf() == gatt.max_chars and
        full_ok and
        table.stats.rejected == 1 and
        // 8 个只读特征 → 16 个句柄，next_handle 停在 0x0011。
        next_before == 0x0011;
    check(ok, "gatt capacity chars={d}/{d} ninth=table_full rejected={d} next=0x{x:0>4}", .{
        table.countOf(), gatt.max_chars, table.stats.rejected, table.next_handle,
    });
}

// ---------------------------------------------------------------------------
// ⑨ 802.15.4 FCF 编码/解码
// ---------------------------------------------------------------------------

fn checkFcf() void {
    const a = fifteen4.Fcf{
        .frame_type = .data,
        .ack_request = true,
        .pan_compress = true,
        .dest_mode = .short,
        .src_mode = .short,
    };
    const wa = a.encode();
    const back_a = fifteen4.Fcf.decode(wa);

    const b = fifteen4.Fcf{
        .frame_type = .data,
        .ack_request = true,
        .pan_compress = true,
        .dest_mode = .short,
        .src_mode = .long,
    };
    const wb = b.encode();

    const le_a = [2]u8{ @truncate(wa), @truncate(wa >> 8) };
    const le_b = [2]u8{ @truncate(wb), @truncate(wb >> 8) };
    const ok = wa == 0x8861 and
        eql(&le_a, &fifteen4.kat_fcf_short) and
        wb == 0xc861 and
        eql(&le_b, &fifteen4.kat_fcf_long_src) and
        back_a.frame_type == .data and
        back_a.ack_request and
        back_a.pan_compress and
        back_a.dest_mode == .short and
        back_a.src_mode == .short and
        back_a.version == 0;
    check(ok, "ieee802154 fcf short=0x{x:0>4} long_src=0x{x:0>4} acks=1 pancomp=1", .{
        wa, wb,
    });
}

// ---------------------------------------------------------------------------
// ⑩ 短地址 / 长地址模式
// ---------------------------------------------------------------------------

fn checkAddressModes() void {
    g4_stats.reset();
    var buf: [32]u8 = undefined;

    const short_hdr = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .short,
        },
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    const n_short = fifteen4.encodeHeader(&buf, short_hdr, &g4_stats) catch 0;
    const short_ok = n_short == 9 and eql(buf[0..9], &fifteen4.kat_mac_short);

    const long_hdr = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .long,
        },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    const n_long = fifteen4.encodeHeader(&buf, long_hdr, &g4_stats) catch 0;
    const long_ok = n_long == 15 and eql(buf[0..15], &fifteen4.kat_mac_long_src);

    // 解码回来：地址类型必须一致（短/长可判别，不是“都是 8 字节”）。
    const decoded = fifteen4.decodeHeader(&fifteen4.kat_frame_short, &g4_stats) catch null;
    const type_ok = if (decoded) |d|
        (d.header.src == .short) and (d.header.dest == .short) and
            d.payload.len == fifteen4.kat_lowpan_short.len and
            d.header.seq == 0x2a and d.header.dest_pan == 0x1234
    else
        false;

    const ok = short_ok and long_ok and type_ok and
        g4_stats.frames_encoded == 2 and
        g4_stats.frames_decoded == 1;
    check(ok, "ieee802154 hdr short={d}B long={d}B decoded={d} src=short", .{
        n_short, n_long, g4_stats.frames_decoded,
    });
}

// ---------------------------------------------------------------------------
// ⑪ 6LoWPAN 解压（两个无状态案例）
// ---------------------------------------------------------------------------

fn checkLowpan() void {
    g4_stats.reset();

    const hdr_a = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .short,
        },
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    var a_ok = false;
    var a_len: u16 = 0;
    if (fifteen4.decompress(&fifteen4.kat_lowpan_short, &hdr_a, &g4_stats)) |v| {
        const want_src = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x9a, 0x3c,
        };
        const want_dst = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x00, 0x02,
        };
        const src = v.src();
        const dst = v.dst();
        a_len = v.payloadLen();
        a_ok = v.version() == 6 and
            v.payloadLen() == 10 and
            v.nextHeader() == 17 and
            v.hopLimit() == 255 and
            eql(&src, &want_src) and
            eql(&dst, &want_dst) and
            v.udp.src_port == 0x1234 and
            v.udp.dst_port == 0x5678 and
            v.udp.checksum == 0xabcd and
            v.udp.checksum_present and
            eql(v.payload, "ok");
    } else |_| {}

    // 第二个案例：地址全省略（SAM=11 DAM=11），源是长地址 → IID 的 U/L 位翻转。
    const hdr_b = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .long,
        },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    var b_ok = false;
    if (fifteen4.decompress(&fifteen4.kat_lowpan_elided, &hdr_b, &g4_stats)) |v| {
        const want_src = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        };
        const src = v.src();
        b_ok = v.version() == 6 and
            v.payloadLen() == 10 and
            eql(&src, &want_src) and
            v.udp.src_port == 0x0050 and
            v.udp.dst_port == 0x0035 and
            eql(v.payload, "hi");
    } else |_| {}

    check(a_ok and b_ok and g4_stats.decompressed == 2, "lowpan stateless={d} ports=0x1234/0x5678 plen={d} ul_flip_ok={d}", .{
        g4_stats.decompressed, a_len, @intFromBool(b_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑫ 不支持的压缩被拒（断言拒绝计数）
// ---------------------------------------------------------------------------

fn checkRejections() void {
    g4_stats.reset();
    const hdr = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    // 先成功解一个，确保 rejected 与 decompressed 是两个独立计数。
    if (fifteen4.decompress(&fifteen4.kat_lowpan_short, &hdr, &g4_stats)) |_| {} else |_| {}
    const ok_before = g4_stats.decompressed;

    // (a) SAC=1 / SAM=01：需要上下文表。
    var e1: ?fifteen4.Error = null;
    if (fifteen4.decompress(&fifteen4.kat_lowpan_stateful, &hdr, &g4_stats)) |_| {} else |e| e1 = e;
    // (b) NHC 端口压缩 P=01：本组件不解。
    const p_compressed = [8]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xf1, 0x35 };
    var e2: ?fifteen4.Error = null;
    if (fifteen4.decompress(&p_compressed, &hdr, &g4_stats)) |_| {} else |e| e2 = e;
    // (c) 非 IPHC dispatch（分片头 11000xxx）。
    const frag = [3]u8{ 0xc0, 0x2a, 0x00 };
    var e3: ?fifteen4.Error = null;
    if (fifteen4.decompress(&frag, &hdr, &g4_stats)) |_| {} else |e| e3 = e;

    const ok = isErr(e1, error.UnsupportedCompression) and
        isErr(e2, error.UnsupportedCompression) and
        isErr(e3, error.BadDispatch) and
        g4_stats.rejected == 3 and
        g4_stats.decompressed == ok_before and
        ok_before == 1;
    var names_buf: [96]u8 = undefined;
    const names = std.fmt.bufPrint(&names_buf, "{s}+{s}+{s}", .{
        @errorName(e1.?), @errorName(e2.?), @errorName(e3.?),
    }) catch "?";
    check(ok, "lowpan reject stateful+ports+frag rejected={d} decompressed={d} ({s})", .{
        g4_stats.rejected, g4_stats.decompressed, names,
    });
}

// ---------------------------------------------------------------------------
// ⑬ HCI 控制命令：编码器 KAT + 返回参数解析
// ---------------------------------------------------------------------------

var cmd_buf: [40]u8 = undefined;
var g_host: evt.Host = .{};
var acl_sdu: [61]u8 = undefined;
var acl_copy: [61]u8 = undefined;
var acl_pkt_buf: [hci.acl_buf_size]u8 = undefined;
var ipsp_pkt: [96]u8 = undefined;
var ipsp_out: [96]u8 = undefined;
var g_ctxs: ipsp.Contexts = .{};
var g_listeners: ipsp.ListenerTable = .{};

const prefix_2001_db8: [8]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0 };
const prefix_2001_db8_1: [8]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0 };

/// 某个调用是否以指定的错误失败（按错误名比较）。
fn failsWith(result: anytype, comptime name: []const u8) bool {
    if (result) |_| {
        return false;
    } else |e| {
        return std.mem.eql(u8, @errorName(e), name);
    }
}

fn checkHciCommandKat() void {
    const n1 = cmd.leSetAdvertisingParameters(&cmd_buf, .{}) catch 0;
    const kat1 = eql(cmd_buf[0..n1], &vectors.hci_le_set_adv_params);
    const n2 = cmd.leCreateConnection(&cmd_buf, .{
        .peer_addr_type = 0x01,
        .peer_addr = .{ .bytes = vectors.dev_addr },
    }) catch 0;
    const kat2 = eql(cmd_buf[0..n2], &vectors.hci_le_create_connection);
    const n3 = cmd.leEnableEncryption(&cmd_buf, 0x0042, vectors.enc_random, 0x1234, vectors.fips197_b_key) catch 0;
    const kat3 = eql(cmd_buf[0..n3], &vectors.hci_le_enable_encryption);
    var len: u16 = 0;
    var count: u8 = 0;
    if (cmd.parseReturn(cmd.op_le_read_buffer_size_v1, &vectors.ret_le_read_buffer_size_v1)) |r| {
        len = r.le_buffer_size_v1.le_acl_data_packet_length;
        count = r.le_buffer_size_v1.total_num_le_acl_packets;
    } else |_| {}
    // 负例：不认识的 OpCode、截断的返回参数。
    const bad_op = failsWith(cmd.parseReturn(0xFCFF, &[_]u8{0}), "UnknownOpcode");
    const bad_len = failsWith(cmd.parseReturn(cmd.op_read_bd_addr, vectors.ret_read_bd_addr[0..5]), "Short");
    const ok = kat1 and kat2 and kat3 and len == 27 and count == 8 and bad_op and bad_len;
    check(ok, "hci cmd adv={d} create={d} enc={d} ret={d}/{d} unknown={d} short={d}", .{
        @intFromBool(kat1),   @intFromBool(kat2),    @intFromBool(kat3), len, count,
        @intFromBool(bad_op), @intFromBool(bad_len),
    });
}

// ---------------------------------------------------------------------------
// ⑭ 事件分发 + host 状态：命令额度与 ACL 包额度
// ---------------------------------------------------------------------------

fn checkHciEventDemux() void {
    g_host = .{};
    var out: [16]u8 = undefined;
    const sent = g_host.send(&out, cmd.op_le_read_buffer_size_v1, &.{}) catch 0;
    const busy = failsWith(g_host.send(&out, cmd.op_reset, &.{}), "Busy");
    var cc_ok = false;
    if (g_host.onEvent(&vectors.evt_cc_le_read_buffer_size)) |ev| {
        cc_ok = ev == .command_complete;
    } else |_| {}
    const total = g_host.credits.total;
    var handle: u16 = 0;
    if (g_host.onEvent(&vectors.evt_le_conn_complete)) |ev| {
        if (ev == .le_connection_complete) handle = ev.le_connection_complete.handle;
    } else |_| {}
    var i: usize = 0;
    while (i < 8) : (i += 1) g_host.credits.take() catch {};
    const no_credit = failsWith(g_host.credits.take(), "NoCredits");
    _ = g_host.onEvent(&vectors.evt_number_of_completed_packets) catch {};
    const free = g_host.credits.free;
    const unknown = failsWith(g_host.onEvent(&vectors.evt_le_unknown_subevent), "UnknownSubevent");
    const ok = sent == 4 and busy and cc_ok and total == 8 and handle == 0x0042 and
        no_credit and free == 4 and unknown;
    check(ok, "hci host sent={d} busy={d} cc={d} total={d} handle=0x{x:0>4} nocredit={d} free={d} unknown={d}", .{
        sent,                    @intFromBool(busy), @intFromBool(cc_ok),   total, handle,
        @intFromBool(no_credit), free,               @intFromBool(unknown),
    });
}

// ---------------------------------------------------------------------------
// ⑮ ACL 分片 / 重组
// ---------------------------------------------------------------------------

fn checkAclFragmentation() void {
    std.mem.writeInt(u16, acl_sdu[0..2], 57, .little);
    std.mem.writeInt(u16, acl_sdu[2..4], l2cap.cid_att, .little);
    var x: u32 = 0x1234_5678;
    for (acl_sdu[4..]) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }
    var seg = acl.Segmenter.init(0x0002, &acl_sdu, 27) catch
        acl.Segmenter{ .handle = 0, .sdu = &.{}, .pkt_len = 1 };
    const AclR = acl.Reassembler(2, 96);
    var r: AclR = .{};
    var frags: usize = 0;
    var got: usize = 0;
    var first_ok = false;
    while (true) {
        const n = (seg.next(&acl_pkt_buf) catch null) orelse break;
        if (frags == 0) first_ok = eql(acl_pkt_buf[0..4], &vectors.acl_hdr_first);
        frags += 1;
        const pushed = r.push(acl_pkt_buf[0..n]) catch acl.Pushed.partial;
        switch (pushed) {
            .complete => |p| {
                got = p.len;
                if (p.len <= acl_copy.len) @memcpy(acl_copy[0..p.len], p);
            },
            .partial => {},
        }
    }
    // 负例：续片先到（句柄 7 上没有开始过的 PDU）。
    const no_start = failsWith(r.push(&[_]u8{ 0x07, 0x10, 0x02, 0x00, 1, 2 }), "NoStart");
    const same = got == 61 and eql(acl_copy[0..got], &acl_sdu);
    const ok = frags == 3 and first_ok and same and no_start;
    check(ok, "acl frags={d} first={d} reassembled={d} equal={d} nostart={d}", .{
        frags, @intFromBool(first_ok), got, @intFromBool(same), @intFromBool(no_start),
    });
}

// ---------------------------------------------------------------------------
// ⑯ L2CAP：信令两个角色 + LE credit based 通道
// ---------------------------------------------------------------------------

fn checkL2cap() void {
    var buf: [64]u8 = undefined;
    const n = l2cap.encodeSig(&buf, 0x01, .{ .conn_param_update_req = .{
        .interval_min = 0x0006,
        .interval_max = 0x000C,
        .latency = 0,
        .timeout = 0x00C8,
    } }) catch 0;
    const kat = eql(buf[0..n], &vectors.l2cap_cpu_req);
    var accepted: u16 = 0xFFFF;
    var rejected = false;
    if (l2cap.decodeSig(buf[0..n])) |req| {
        const ra = l2cap.connParamUpdateOnReq(&buf, .central, req.identifier, true) catch 0;
        if (l2cap.decodeSig(buf[0..ra])) |rsp| {
            accepted = l2cap.connParamUpdateOnRsp(.peripheral, rsp) catch 0xFFFF;
        } else |_| {}
        const rj = l2cap.connParamUpdateOnReq(&buf, .peripheral, req.identifier, true) catch 0;
        if (l2cap.decodeSig(buf[0..rj])) |rej| {
            rejected = rej.sig == .command_reject and
                rej.sig.command_reject == l2cap.reject.command_not_understood;
        } else |_| {}
    } else |_| {}

    const Chan = l2cap.Channel(32);
    var a = Chan.init(0x0040, 0x0041, 32, 23, 32, 23, 2, 2) catch
        return check(false, "l2cap chan init failed", .{});
    var b = Chan.init(0x0041, 0x0040, 32, 23, 32, 23, 2, 2) catch
        return check(false, "l2cap chan init failed", .{});
    var sdu: [30]u8 = undefined;
    var x: u32 = 7;
    for (&sdu) |*p| {
        x = x *% 1664525 +% 1013904223;
        p.* = @truncate(x >> 24);
    }
    a.startSend(&sdu) catch {};
    const k1 = (a.sendNext(&buf) catch null) orelse 0;
    const part = b.receive(buf[0..k1]) catch Chan.Rx.partial;
    const k2 = (a.sendNext(&buf) catch null) orelse 0;
    var got: usize = 0;
    const done = b.receive(buf[0..k2]) catch Chan.Rx.partial;
    switch (done) {
        .complete => |p| got = p.len,
        .partial => {},
    }
    a.startSend(&sdu) catch {};
    const no_credit = failsWith(a.sendNext(&buf), "NoCredits");
    const ok = kat and accepted == l2cap.param_update_accepted and rejected and
        part == .partial and got == 30 and no_credit;
    check(ok, "l2cap kat={d} accepted=0x{x:0>4} rejected={d} partial={d} sdu={d} nocredit={d}", .{
        @intFromBool(kat), accepted,                @intFromBool(rejected), @intFromBool(part == .partial),
        got,               @intFromBool(no_credit),
    });
}

// ---------------------------------------------------------------------------
// ⑰ 广播数据：构造 + 31 字节上限 + 解析
// ---------------------------------------------------------------------------

fn checkAdvData() void {
    var b: gap.Builder = .{};
    var ok = true;
    b.flags(0x06) catch {
        ok = false;
    };
    b.uuids16(&[_]u16{0x180A}, true) catch {
        ok = false;
    };
    b.name("ch27", true) catch {
        ok = false;
    };
    const kat = ok and eql(b.data(), &hci.kat_adv_data);
    const big: [20]u8 = @splat('x');
    const no_space = failsWith(b.append(0x99, &big), "NoSpace");
    const unchanged = b.len == 13;
    var name_ok = false;
    if (gap.localName(b.data()) catch null) |ln| {
        name_ok = ln.complete and eql(ln.name, "ch27");
    }
    var out: [1 + gap.adv_data_max]u8 = undefined;
    b.packHci(&out);
    // out 是 Length(1) + 31 字节定长，对应向量的 [4..]（共 32 字节），不是 [1..] 对 [4..]。
    const hci_ok = eql(&out, vectors.hci_le_set_adv_data[4..]);
    // 负例：Length 越过缓冲末尾。
    var bad = gap.iterate(&[_]u8{ 0x05, 0x01, 0x06 });
    const malformed = failsWith(bad.next(), "BadLength");
    check(kat and no_space and unchanged and name_ok and hci_ok and malformed, "gap adv kat={d} nospace={d} name={d} hci={d} malformed={d}", .{
        @intFromBool(kat),    @intFromBool(no_space),  @intFromBool(name_ok),
        @intFromBool(hci_ok), @intFromBool(malformed),
    });
}

// ---------------------------------------------------------------------------
// ⑱ 地址哈希与可解析私有地址
// ---------------------------------------------------------------------------

fn checkRandomAddress() void {
    const enc = gap.e(vectors.fips197_b_key, vectors.fips197_b_input);
    const aes_ok = eql(&enc, &vectors.fips197_b_output);
    const rpa = gap.generateRpa(vectors.rpa_irk, vectors.rpa_prand) catch gap.Addr{};
    const generated = eql(&rpa.bytes, &vectors.rpa_addr);
    const resolved = gap.resolve(rpa, vectors.rpa_irk);
    const wrong = gap.resolve(rpa, vectors.wrong_irk);
    const bad_prand = failsWith(gap.generateRpa(vectors.rpa_irk, .{ 0x21, 0x3C, 0x9A }), "BadParam");
    const static_ok = (gap.Addr{ .bytes = vectors.dev_addr }).randomKind() == .static;
    check(aes_ok and generated and resolved and !wrong and bad_prand and static_ok, "addr aes={d} rpa={d} resolved={d} wrong={d} bad_prand={d} static={d}", .{
        @intFromBool(aes_ok),    @intFromBool(generated), @intFromBool(resolved), @intFromBool(wrong),
        @intFromBool(bad_prand), @intFromBool(static_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑲ IPv6 over BLE：IID 与 RFC 7668 §3.2.4.1 的压缩结果
// ---------------------------------------------------------------------------

fn addr6(groups: [8]u16) [16]u8 {
    var a: [16]u8 = undefined;
    for (groups, 0..) |g, i| std.mem.writeInt(u16, a[2 * i ..][0..2], g, .big);
    return a;
}

/// 一个 UDP/IPv6 包（Hop Limit 64、端口 5683、校验和 0x1234）。
fn mkUdp6(src: [16]u8, dst: [16]u8, data: []const u8, out: []u8) usize {
    @memset(out[0..48], 0);
    out[0] = 0x60;
    out[6] = 17;
    out[7] = 64;
    std.mem.writeInt(u16, out[4..6], @intCast(8 + data.len), .big);
    @memcpy(out[8..24], &src);
    @memcpy(out[24..40], &dst);
    std.mem.writeInt(u16, out[40..42], 5683, .big);
    std.mem.writeInt(u16, out[42..44], 5683, .big);
    std.mem.writeInt(u16, out[44..46], @intCast(8 + data.len), .big);
    std.mem.writeInt(u16, out[46..48], 0x1234, .big);
    @memcpy(out[48 .. 48 + data.len], data);
    return 48 + data.len;
}

fn checkIpsp() void {
    const got_iid = ipsp.iid(vectors.ipsp_addr_6ln);
    const iid_ok = eql(&got_iid, &vectors.ipsp_iid_6ln);
    g_ctxs = .{};
    const zeros8: [8]u8 = @splat(0);
    g_ctxs.setWithIid(0, prefix_2001_db8 ++ zeros8, 64, vectors.ipsp_iid_6ln) catch {};
    g_ctxs.set(1, prefix_2001_db8_1 ++ zeros8, 64) catch {};
    const link = ipsp.Link{ .local = vectors.ipsp_addr_6ln, .peer = vectors.ipsp_addr_6lbr };
    const src = prefix_2001_db8 ++ vectors.ipsp_iid_6ln;
    const dst = prefix_2001_db8_1 ++ [8]u8{ 0, 0, 0, 0, 0, 0, 0, 5 };
    const n = mkUdp6(src, dst, "coap", &ipsp_pkt);
    const m = ipsp.compress(&ipsp_out, ipsp_pkt[0..n], link, &g_ctxs) catch 0;
    const kat = eql(ipsp_out[0..m], &vectors.iphc_7668_6ln_to_remote_dam01);
    // 组播监听表按链路记录；单播地址不能登记。
    g_listeners = .{};
    const all_nodes = addr6(.{ 0xFF02, 0, 0, 0, 0, 0, 0, 1 });
    g_listeners.add(1, all_nodes) catch {};
    g_listeners.add(2, all_nodes) catch {};
    var links: [4]u12 = undefined;
    const count = g_listeners.linksFor(all_nodes, &links) catch 0;
    const bad_group = failsWith(g_listeners.add(3, src), "BadParam");
    check(iid_ok and kat and count == 2 and bad_group, "ipsp iid={d} rfc7668={d} listeners={d} badgroup={d}", .{
        @intFromBool(iid_ok), @intFromBool(kat), count, @intFromBool(bad_group),
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

fn runChecks() bool {
    checkAclHeader();
    checkAclMax();
    checkMtuExchange();
    checkReadKats();
    checkWritePermission();
    checkNotify();
    checkHandleRange();
    checkTableCapacity();
    checkFcf();
    checkAddressModes();
    checkLowpan();
    checkRejections();
    checkHciCommandKat();
    checkHciEventDemux();
    checkAclFragmentation();
    checkL2cap();
    checkAdvData();
    checkRandomAddress();
    checkIpsp();
    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    log.line("read: hci acl_buf={d} max_payload={d} encoded={d} decoded={d} rejected={d}", .{
        hci.acl_buf_size,      hci.acl_max_payload, hci_stats.acl_encoded,
        hci_stats.acl_decoded, hci_stats.rejected,
    });
    log.line("read: att mtu={d}/{d} exchanges={d} reads={d} writes={d} notifies={d} errors={d} trunc={d}", .{
        att.default_mtu,          att.max_mtu,         att_stats.mtu_exchanges,
        att_stats.reads,          att_stats.writes,    att_stats.notifies,
        att_stats.errors_emitted, att_stats.truncated,
    });
    log.line("read: gatt chars={d} subs={d} mask=0x{x:0>2} lowpan_len={d}", .{
        table.countOf(),               table.subCount(), table.subMask(),
        fifteen4.kat_lowpan_short.len,
    });
    log.line("read: 154 frames={d}/{d} decompressed={d} rejected={d}", .{
        g4_stats.frames_encoded, g4_stats.frames_decoded,
        g4_stats.decompressed,   g4_stats.rejected,
    });

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
