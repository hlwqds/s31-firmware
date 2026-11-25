//! ble-802154：板侧自检（50 条判据）。
//!
//! 本组件板侧**不碰射频**：没有扫描、没有连接、没有 Thread 入网，也没有任何 PDU 上过
//! 链路。ATT / GATT 的服务端与客户端只在本进程里对打——请求直接交给服务端、应答直接
//! 交回客户端（见 `pump()`）。controller 归档（libble_app.a 等）一个字节都没链接
//! （见 `tools/symbols.sh` 的产物与 `docs/history/` 的历史说明/27.11）。被测对象全是纯逻辑：
//!
//!   `hci.zig`      —— HCI 分帧（ACL / Command / Event / LE Meta）
//!   `att.zig`         —— ATT 全部 31 个操作码（[Vol 3] Part F 表 3.43）的布局、MTU 截断、响应打包
//!   `att_server.zig`  —— ATT 服务端：属性表、请求分发、排队写、通知与指示
//!   `gatt.zig`        —— 定长特征表、句柄分配、权限、CCCD 订阅
//!   `gatt_server.zig` —— GATT 服务端：服务 / 特征 / 描述符声明、CCCD、指示、Service Changed
//!   `gatt_client.zig` —— GATT 客户端：发现、读、写、订阅
//!   `cmac.zig`        —— AES-CMAC（RFC 4493）与 ATT 数据签名
//!   `fifteen4.zig` —— 802.15.4 FCF/地址 + 6LoWPAN IPHC 解压
//!   `hci_cmd.zig` / `hci_evt.zig` —— HCI 控制命令、事件分发、命令与 ACL 额度
//!   `acl.zig` / `l2cap.zig` —— ACL 分片重组、L2CAP 信令与 credit based 通道
//!   `gap_adv.zig` / `ipsp.zig` —— 广播数据与设备地址、IPv6 over BLE
//!
//! 50 条判据（每条一行 `check: ... ok=1/0`，数字全部来自实际比较）：
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
//!   ⑳ AES-CMAC：RFC 4493 §4 的四个向量（[Vol 3] Part H 附录 D.1 引的就是它们）
//!   ㉑ AES-CMAC：[Vol 3] Part G 附录 B 的数据库哈希输入（全零密钥，111 字节）
//!   ㉒ 签名：[Vol 3] Part F §3.4.5.4 的样例逐字节命中；MAC / 消息 / 密钥动了就被拒
//!   ㉓ 签名写：ATT_SIGNED_WRITE_CMD 有效则写入且不应答；没有 CSRK、重放、篡改都忽略
//!   ㉔ ATT 服务端 MTU 交换（§3.4.2.2）：取两端之小、小于默认值不变、生效后的长度上限
//!   ㉕ ATT 服务端 Find Information（§3.4.3）：按 ATT_MTU 翻页且不拆对、UUID 尺寸变化处分页、出错句柄
//!   ㉖ ATT 服务端 Read By Type（§3.4.4.1–2）：Length = 句柄 + 值、整条打包、值截到 ATT_MTU−4、异长分包
//!   ㉗ ATT 服务端 Read By Group Type（§3.4.4.9–10）：Length = 句柄 + 组尾句柄 + 值、128 位 UUID、0x10
//!   ㉘ ATT 服务端 Read Blob（§3.4.4.5–6）：按 ATT_MTU−1 分段、偏移等于长度回空、越界回 Invalid Offset
//!   ㉙ ATT 服务端 Read Multiple（§3.4.4.7–8）：按请求顺序首尾相接、整体截到 ATT_MTU−1、出错句柄
//!   ㉚ ATT 服务端 Read Multiple Variable（§3.4.4.12）：超过 ATT_MTU−1 处截断，Value Length 仍是完整长度
//!   ㉛ ATT 服务端 Read Multiple Variable（§3.4.4.12）：截点落在 Value Length 字段里 → 整条元组不放
//!   ㉜ ATT 服务端排队写（§3.4.6）：Prepare 应答复述请求，Execute（0x01）按接收顺序写
//!   ㉝ ATT 服务端排队写（§3.4.6）：取消（0x00）、偏移越界、队列满、链路断开都不写
//!   ㉞ ATT 服务端权限错误码：Read Not Permitted（含 Read By Type 的两条规则）、Write Not Permitted
//!   ㉟ GATT 服务端声明：服务、特征声明与特征值的字节（[Vol 3] Part G 表 3.1、3.3–3.6）
//!   ㊱ GATT 服务端声明：描述符（表 3.9、3.14、3.15）
//!   ㊲ GATT 服务端声明：包含声明（表 3.2）与 secondary 服务
//!   ㊳ CCCD 按 client 分别保存并门控通知（§3.3.3.3）
//!   ㊴ CCCD 写入校验：特征没有的位 → Application Error，尺寸不对不写（§4.12.3、表 3.11）
//!   ㊵ 指示：一次只发一条、等到确认才能再发、30 秒没有确认事务超时（§3.3.2、§3.3.3、§3.4.7.2）
//!   ㊶ Service Changed：声明字节、值不可读写、未订阅时指示算丢、只能有一个（§7.1）
//!   ㊷ GATT 客户端 Discover All Primary Services（附录 A 的表，§4.4.1）
//!   ㊸ GATT 客户端 Exchange MTU：取两端之小、每连接一次、MTU 100 下发现少翻页（§4.3.1）
//!   ㊹ GATT 客户端 Discover All Characteristics（§4.6.1）
//!   ㊺ GATT 客户端 Read 与 Read Long 两段（§4.8.1、§4.8.3）
//!   ㊻ GATT 客户端 Read Multiple Variable（§4.8.5）
//!   ㊼ GATT 客户端对 addService 建的表做发现（§4.4.1、§4.6.1）
//!   ㊽ GATT 客户端 Write Long：按 ATT_MTU−5 分段再 Execute（§4.9.4）
//!   ㊾ GATT 客户端写长之后 Read Long 两段、Read Multiple Variable 截断（§4.8.3、§4.8.5）
//!   ㊿ GATT 客户端订阅通知并收到、退订后收不到（§4.10.1、§4.12.3）
//!
//! ⑳–㊿ 的期望值都是先按条款把字节排出来的十六进制字面量（`hx()`），再让实现去命中；
//! 与 `host_tests.zig` 同一脚本的几条，脚本逐字相同。GATT 客户端那几条核对的是线上
//! 字节：对打时记下每一个 PDU（`Trace`），与脚本逐条、逐字节比较。没写 Part 的 § 都在
//! [Vol 3] Part F（ATT）或 Part G（GATT）里。
//!
//! 所有状态都在 `.bss` 的静态变量里：板侧没有堆，自检也不依赖分配失败。

const std = @import("std");

const att = @import("att.zig");
const att_server = @import("att_server.zig");
const fifteen4 = @import("fifteen4.zig");
const gatt = @import("gatt.zig");
const gatt_client = @import("gatt_client.zig");
const gatt_server = @import("gatt_server.zig");
const cmac = @import("cmac.zig");
const hci = @import("hci.zig");
const acl = @import("acl.zig");
const cmd = @import("hci_cmd.zig");
const evt = @import("hci_evt.zig");
const gap = @import("gap_adv.zig");
const ipsp = @import("ipsp.zig");
const l2cap = @import("l2cap.zig");
const vectors = @import("vectors.zig");
const ext_adv_selftest = @import("ext_adv_selftest.zig");
const eatt_selftest = @import("eatt_selftest.zig");
const privacy_selftest = @import("privacy_selftest.zig");
const sixlowpan_selftest = @import("sixlowpan_selftest.zig");
const nd6_selftest = @import("nd6_selftest.zig");
const sfr_selftest = @import("sfr_selftest.zig");
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
        // RFC 6282 §3.2 行 590-591：内联字段与 IPv6 头同序 → `3c 9a` / `02 00` 高字节在前。
        const want_src = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x3c, 0x9a,
        };
        const want_dst = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x02, 0x00,
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
    // (b) NHC 端口压缩 P=01：合法编码（RFC 6282 §4.3.3 图 14），这帧截断 → Short。
    const p_compressed = [8]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xf1, 0x35 };
    var e2: ?fifteen4.Error = null;
    if (fifteen4.decompress(&p_compressed, &hdr, &g4_stats)) |_| {} else |e| e2 = e;
    // (c) 非 IPHC dispatch（分片头 11000xxx）。
    const frag = [3]u8{ 0xc0, 0x2a, 0x00 };
    var e3: ?fifteen4.Error = null;
    if (fifteen4.decompress(&frag, &hdr, &g4_stats)) |_| {} else |e| e3 = e;

    const ok = isErr(e1, error.UnsupportedCompression) and
        isErr(e2, error.Short) and
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
// ⑳–㊿：AES-CMAC、ATT 服务端、GATT 服务端与客户端
//
// 期望值是按条款排出来的字节（十六进制字面量 `hx()`），让实现去命中。ATT / GATT 的
// 服务端与客户端在本进程里对打，没有任何 PDU 上过链路。没写 Part 的 § 都在 [Vol 3]
// Part F（ATT）或 Part G（GATT）里。
// ---------------------------------------------------------------------------

fn hexNib(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("不是十六进制字符"),
    };
}

fn hexCount(comptime s: []const u8) usize {
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        var n: usize = 0;
        for (s) |c| {
            if (c != ' ') n += 1;
        }
        if (n % 2 != 0) @compileError("十六进制字面量必须是偶数个字符");
        break :blk n / 2;
    };
}

/// 十六进制串（每字节两位，可以夹空格）→ 数组。在编译期解码：打错或漏掉一个字符是编译错误。
fn hx(comptime s: []const u8) [hexCount(s)]u8 {
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        var out: [hexCount(s)]u8 = undefined;
        var i: usize = 0;
        var j: usize = 0;
        while (j < s.len) : (j += 1) {
            if (s[j] == ' ') continue;
            out[i] = (hexNib(s[j]) << 4) | hexNib(s[j + 1]);
            i += 1;
            j += 1;
        }
        break :blk out;
    };
}

/// 第 i 字节 = (i × 7 + 1) & 0xFF 的值，用来核对分段读写。
fn pattern(comptime n: usize) [n]u8 {
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        var out: [n]u8 = undefined;
        for (&out, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
        break :blk out;
    };
}

fn bit(ok: bool) u8 {
    return @intFromBool(ok);
}

// pattern(40) 按下标切开：0–17、18–35、36–39；读的那边按 19、22、8 字节切。
const pat18a_hex = "01 08 0f 16 1d 24 2b 32 39 40 47 4e 55 5c 63 6a 71 78";
const pat18b_hex = "7f 86 8d 94 9b a2 a9 b0 b7 be c5 cc d3 da e1 e8 ef f6";
const pat4_hex = "fd 04 0b 12";
const pat30_hex = pat18a_hex ++ " 7f 86 8d 94 9b a2 a9 b0 b7 be c5 cc";
const pat40_hex = pat18a_hex ++ " " ++ pat18b_hex ++ " " ++ pat4_hex;
const pat22_hex = pat18a_hex ++ " 7f 86 8d 94";
const pat8_hex = "9b a2 a9 b0 b7 be c5 cc";
const pat19_hex = pat18a_hex ++ " 7f";
const pat30: [30]u8 = pattern(30);
const pat40: [40]u8 = pattern(40);

comptime {
    // 十六进制与 pattern() 是两份独立写法，编译期对一遍。
    if (!std.mem.eql(u8, &hx(pat30_hex), &pattern(30))) @compileError("pat30_hex 与 pattern(30) 不一致");
    if (!std.mem.eql(u8, &hx(pat40_hex), &pattern(40))) @compileError("pat40_hex 与 pattern(40) 不一致");
}

// ---------------------------------------------------------------------------
// 进程内对打（ATT 服务端 / GATT 服务端 / GATT 客户端共用）
//
//   `g_srv`           —— GATT 服务端，里面是一张 ATT 属性表 `g_srv.db`
//   `g_peer` / `g_peer2` —— client A / client B 在各自 ATT bearer 上的状态
//   `g_cli`           —— GATT 客户端的状态机
//   `g_tx` / `g_rx`   —— 客户端发出的请求 / 服务端的应答
//
// 时间用 `g_now`（毫秒）手动拨，30 秒超时不用真等。
// ---------------------------------------------------------------------------

const Gs = gatt_server.Server(64, 64);
const Gp = Gs.Db.Peer(4);
const Gc = gatt_client.Client(.{
    .services = 8,
    .includes = 4,
    .chars = 16,
    .descs = 16,
    .value = 128,
    .write = 128,
    .handles = 8,
});

const perm_r = att_server.Perm{ .read = true };
const perm_rw = att_server.Perm{ .read = true, .write = true };

/// 附录 A 只给了名字（«Vendor Specific Service» / «Vendor Specific Type»），没给编号：这两个 128 位
/// UUID 的字节是自拟的（同 `host_tests.zig`），线上最低有效字节在前。
const vendor_svc: [16]u8 = hx("01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10");
const vendor_type_hex = "11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00";
const vendor_type: [16]u8 = hx(vendor_type_hex);

var g_srv: Gs = .{};
var g_peer: Gp = .{};
var g_peer2: Gp = .{};
var g_cli: Gc = .{};
var g_tx: [att.buf_max]u8 = undefined;
var g_rx: [att.buf_max]u8 = undefined;
var g_now: u32 = 1000;

/// 这一次对打里 server 报过本地故障（Zig 错误，不是 ATT_ERROR_RSP）。
var g_lab_err = false;
var g_lab_errs: u32 = 0;
var g_lab_svr_pdus: u32 = 0;
var g_lab_cli_pdus: u32 = 0;
var g_trace: Trace = .{};

/// 对打时记下的线上字节：请求、应答交替。一条脚本核对的就是这一个过程的全部 PDU。
const Trace = struct {
    buf: [512]u8 = undefined,
    lens: [24]u16 = @splat(0),
    n: usize = 0,
    overflow: bool = false,

    fn total(self: *const Trace) usize {
        var t: usize = 0;
        for (self.lens[0..self.n]) |l| t += l;
        return t;
    }

    fn push(self: *Trace, bytes: []const u8) void {
        const off = self.total();
        if (self.n >= self.lens.len or off + bytes.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[off..][0..bytes.len], bytes);
        self.lens[self.n] = @intCast(bytes.len);
        self.n += 1;
    }

    fn at(self: *const Trace, i: usize) []const u8 {
        var off: usize = 0;
        for (self.lens[0..i]) |l| off += l;
        return self.buf[off..][0..self.lens[i]];
    }

    /// 与脚本逐条比较，返回第一条不相符的下标；条数不同时取两边较短的那个。全部相符时
    /// 返回脚本的条数。装不下而被丢掉的 PDU 一律算不相符。
    fn firstMismatch(self: *const Trace, script: []const []const u8) usize {
        if (self.overflow or self.n != script.len) return @min(self.n, script.len);
        for (script, 0..) |want, i| {
            if (!eql(self.at(i), want)) return i;
        }
        return script.len;
    }
};

/// 一次 `runScript()` 的结果：`at` 是第一条不相符的 PDU 下标，等于 `len` 即全部相符。
const Run = struct { ok: bool, at: usize, len: usize };

/// 清空属性表与各端状态，每条判据从一张干净的表开始。
fn labReset() void {
    g_srv.reset();
    g_peer = .{};
    g_peer2 = .{};
    g_cli.reset();
    g_now = 1000;
    g_trace = .{};
    g_lab_err = false;
}

/// 把一个请求交给 client A 的 server，返回它的应答（指向 `g_rx`）；server 报本地故障时为 null。
fn ask(req: []const u8) ?[]const u8 {
    g_lab_svr_pdus += 1;
    const n = g_peer.onPdu(&g_srv.db, req, &g_rx) catch {
        g_lab_errs += 1;
        g_lab_err = true;
        return null;
    };
    return g_rx[0..n];
}

/// 同上，client B；应答落在 `g_tx`（只在不对打的时候用）。
fn ask2(req: []const u8) ?[]const u8 {
    g_lab_svr_pdus += 1;
    const n = g_peer2.onPdu(&g_srv.db, req, &g_tx) catch {
        g_lab_errs += 1;
        g_lab_err = true;
        return null;
    };
    return g_tx[0..n];
}

/// 请求的应答必须逐字节等于 `want`。
fn says(req: []const u8, want: []const u8) bool {
    const rsp = ask(req) orelse return false;
    return eql(rsp, want);
}

fn says2(req: []const u8, want: []const u8) bool {
    const rsp = ask2(req) orelse return false;
    return eql(rsp, want);
}

/// 命令（或被丢弃的 PDU）：不应答。
fn silent(req: []const u8) bool {
    const rsp = ask(req) orelse return false;
    return rsp.len == 0;
}

/// 请求的应答必须是一条 ATT_ERROR_RSP（表 3.3）：出错的请求操作码、属性句柄与请求相符，
/// 错误码落在 [lo, hi] 里。
fn errorIs(req: []const u8, req_op: u8, handle: u16, lo: u8, hi: u8) bool {
    const rsp = ask(req) orelse return false;
    if (rsp.len != att.min_len.error_rsp or rsp[0] != 0x01 or rsp[1] != req_op) return false;
    return att.getU16(rsp[2..4]) == handle and rsp[4] >= lo and rsp[4] <= hi;
}

/// 客户端过程的第一条请求在 `g_tx[0..n0]`：交给 server，应答交回客户端，直到过程不再
/// 产生新请求。返回客户端的最终结果；server 报本地故障时置 `g_lab_err`。
fn pump(n0: usize) gatt_client.Step {
    var len = n0;
    g_trace = .{};
    g_trace.push(g_tx[0..len]);
    var guard: usize = 0;
    while (guard < g_trace.lens.len) : (guard += 1) {
        g_lab_svr_pdus += 1;
        const m = g_peer.onPdu(&g_srv.db, g_tx[0..len], &g_rx) catch {
            g_lab_errs += 1;
            g_lab_err = true;
            return .{ .outcome = .failed };
        };
        g_trace.push(g_rx[0..m]);
        g_lab_cli_pdus += 1;
        const step = g_cli.onPdu(g_rx[0..m], &g_tx, g_now);
        g_now += 1;
        if (step.outcome != .pending) return step;
        len = step.out_len;
        g_trace.push(g_tx[0..len]);
    }
    g_lab_errs += 1;
    g_lab_err = true;
    return .{ .outcome = .failed };
}

/// 跑完一个客户端过程，并与脚本逐条、逐字节比较线上字节。
fn runScript(n0: usize, script: []const []const u8) Run {
    const step = pump(n0);
    const at = g_trace.firstMismatch(script);
    return .{
        .ok = step.outcome == .done and g_cli.status == .ok and !g_lab_err and at == script.len,
        .at = at,
        .len = script.len,
    };
}

fn addDb(n: Gs.Db.New) bool {
    _ = g_srv.db.add(n) catch return false;
    return true;
}

/// 属性当前的值（按它自己的长度）必须等于 `want`。
fn valueIs(handle: u16, want: []const u8) bool {
    const a = g_srv.db.find(handle) orelse return false;
    return eql(a.value[0..a.len], want);
}

fn addSvc(uuid: att.Uuid, primary: bool) u16 {
    return g_srv.addService(uuid, primary) catch 0;
}

fn addCharacteristic(spec: gatt_server.CharSpec) gatt_server.Char {
    return g_srv.addCharacteristic(spec) catch .{ .decl = 0, .value = 0, .cccd = 0 };
}

/// 只读的定长描述符。
fn addDesc(uuid: u16, value: []const u8) u16 {
    return g_srv.addDescriptor(.{ .u16 = uuid }, perm_r, value, 0, true) catch 0;
}

fn addInc(service_start: u16) u16 {
    return g_srv.addInclude(service_start) catch 0;
}

/// 向 `peer` 发通知，线上字节必须等于 `want`（一条完整的 ATT_HANDLE_VALUE_NTF）。
fn notifyIs(peer: anytype, value_handle: u16, want: []const u8) bool {
    const n = g_srv.notify(peer, value_handle, want[3..], &g_rx) catch return false;
    return n == want.len and eql(g_rx[0..n], want);
}

// ---------------------------------------------------------------------------
// ⑳ AES-CMAC：RFC 4493 §4 的四个向量（[Vol 3] Part H 附录 D.1 引的就是它们）
// ---------------------------------------------------------------------------

fn checkCmacRfc4493() void {
    const key = hx("2b7e151628aed2a6abf7158809cf4f3c");
    const m = hx(
        "6bc1bee22e409f96e93d7e117393172a" ++
            "ae2d8a571e03ac9c9eb76fac45af8e51" ++
            "30c81c46a35ce411" ++
            "e5fbc1191a0a52eff69f2445df4f9b17" ++
            "ad2b417be66c3710",
    );
    // 16、64 字节：末块是整块（K1）；空消息与 40 字节（两个整块加 8 字节）：末块要补位（K2）。
    var matched: u8 = 0;
    if (eql(&cmac.cmac(key, &.{}), &hx("bb1d6929e95937287fa37d129b756746"))) matched += 1;
    if (eql(&cmac.cmac(key, m[0..16]), &hx("070a16b46b4d4144f79bdd9dd04a287c"))) matched += 1;
    if (eql(&cmac.cmac(key, m[0..40]), &hx("dfa66747de9ae63030ca32611497c827"))) matched += 1;
    if (eql(&cmac.cmac(key, &m), &hx("51f0bebf7e3b9d92fc49741779363cfe"))) matched += 1;
    check(matched == 4, "cmac rfc4493 len=0/16/40/64 matched={d}/4", .{matched});
}

// ---------------------------------------------------------------------------
// ㉑ AES-CMAC：[Vol 3] Part G 附录 B
// ---------------------------------------------------------------------------

fn checkCmacDbHash() void {
    // 数据库哈希的输入 M0–M6 共 111 字节（六个整块加 15 字节），密钥全零（§7.3.1）。
    const m = hx(
        "010000280018020003280a0300002a04" ++
            "000328020500012a0600002801180700" ++
            "0328200800052a090002290a0003280a" ++
            "0b00292b0c000328020d002a2b0e0000" ++
            "2808180f000228140016000f18100003" ++
            "28a21100182a12000229130000290000" ++
            "140001280f1815000328021600192a",
    );
    const ok = eql(&cmac.cmac(@splat(0), &m), &hx("f1ca2d48ecf58bac8a8830bbb9fba990"));
    check(ok, "cmac gatt-appendix-b key=zero len={d} hash={s}", .{
        m.len, if (ok) "f1ca2d48ecf58bac8a8830bbb9fba990" else "mismatch",
    });
}

// ---------------------------------------------------------------------------
// ㉒ 签名：[Vol 3] Part F §3.4.5.4 的样例
// ---------------------------------------------------------------------------

fn checkSignKat() void {
    // m = D2 12 00 13 37，SignCounter = 1；原文的签名是 01 00 00 00 F1 87 1E 93 3C 90 0F F2。
    const csrk = hx("611b64ebfbcd1fd372ec9196df425e50");
    const m = hx("d212001337");
    const sig = cmac.sign(csrk, 1, &m);
    const kat = eql(&sig, &hx("01000000f1871e933c900ff2"));
    // 原文的完整签名写消息：D2 12 00 13 37 | 01 00 00 00 F1 87 1E 93 3C 90 0F F2。
    var pdu: [17]u8 = undefined;
    @memcpy(pdu[0..5], &m);
    @memcpy(pdu[5..17], &sig);
    const wire = eql(&pdu, &hx("d21200133701000000f1871e933c900ff2"));
    // 验签：原样通过；MAC 翻一位、消息翻一位、换一把密钥都得拒。
    const good = cmac.verify(csrk, &m, sig);
    const bad_mac = blk: {
        var s = sig;
        s[11] ^= 1;
        break :blk s;
    };
    const bad_msg = blk: {
        var v = m;
        v[4] ^= 1;
        break :blk v;
    };
    const rejected: u8 = bit(!cmac.verify(csrk, &m, bad_mac)) + bit(!cmac.verify(csrk, &bad_msg, sig)) +
        bit(!cmac.verify(@splat(0), &m, sig));
    const counter = cmac.counterOf(sig);
    check(kat and wire and good and rejected == 3 and counter == 1, "cmac sign counter={d} kat={d} verify={d} rejected={d}/3", .{
        counter, bit(kat), bit(good), rejected,
    });
}

// ---------------------------------------------------------------------------
// ㉓ ATT_SIGNED_WRITE_CMD：只有签名有效且 SignCounter 更新时才写入
// ---------------------------------------------------------------------------

fn checkSignedWrite() void {
    labReset();
    const built = addDb(.{ .handle = 0x0012, .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 8 });
    const pdu_hex = "d21200133701000000f1871e933c900ff2";
    const pdu = hx(pdu_hex);
    // 没有对端的 CSRK：不验签，命令一律忽略（§3.4.5.4：验签失败就忽略，不应答）。
    const no_key = silent(&pdu) and valueIs(0x0012, "v");
    g_peer.csrk = hx("611b64ebfbcd1fd372ec9196df425e50");
    // §3.4.5.4 的例子原样送进去：值被写入。
    const applied = silent(&pdu) and valueIs(0x0012, &hx("13 37")) and g_peer.sign_counter == 1;
    // 原样重放：SignCounter 没有变大（[Vol 3] Part H §2.4.5），忽略。
    const replay = silent(&pdu);
    // 篡改 MAC 的最后一位、篡改值：验签失败，忽略，值不变。
    const bad_mac = flip(pdu_hex, 16);
    const bad_value = flip(pdu_hex, 4);
    const tampered = silent(&bad_mac) and silent(&bad_value) and valueIs(0x0012, &hx("13 37"));
    check(built and no_key and applied and replay and tampered and g_peer.stats.signed_writes == 1 and
        g_peer.stats.rejected_signatures == 4, "att_svr signed_write applied={d} rejected={d} counter={d}", .{
        g_peer.stats.signed_writes, g_peer.stats.rejected_signatures, g_peer.sign_counter,
    });
}

/// 十六进制串解出来之后，把第 `i` 字节的最低位翻掉。
fn flip(comptime s: []const u8, comptime i: usize) [hexCount(s)]u8 {
    return comptime blk: {
        var out = hx(s);
        out[i] ^= 1;
        break :blk out;
    };
}

// ---------------------------------------------------------------------------
// ㉔ ATT 服务端 MTU 交换
// ---------------------------------------------------------------------------

fn checkSvrMtu() void {
    labReset();
    const built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &pat30, .perm = perm_rw, .max_len = 40 });
    const payload_hex = "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15";
    var req: [24]u8 = undefined;
    @memcpy(req[0..3], &hx("12 01 00"));
    @memcpy(req[3..], &hx(payload_hex));

    // ATT_MTU 还是 23：读响应只带前 ATT_MTU−1 = 22 字节（表 3.19）；24 字节的写请求放不下，
    // 不得写入，也不回 ATT_WRITE_RSP。
    const cut = says(&hx("0a 01 00"), &hx("0b " ++ pat22_hex));
    const over = ask(&req);
    const not_written = if (over) |rsp| !(rsp.len == 1 and rsp[0] == 0x13) else false;
    const untouched = valueIs(1, &pat30);
    // §3.4.2.2：应答回本端能收的最大值（527 = 0x020F）；ATT_MTU = 两端之小，在这条应答之后生效：
    // 30 字节的值一次读完，24 字节的写请求也放得下了。
    const exchanged = says(&hx("02 f7 00"), &hx("03 0f 02"));
    const mtu = g_peer.mtu;
    const whole = says(&hx("0a 01 00"), &hx("0b " ++ pat30_hex));
    const fits = says(&req, &hx("13")) and valueIs(1, &hx(payload_hex));

    // 任一端错误地小于默认值：照常应答，ATT_MTU 不变；对端报得比本端上限大：取本端上限。
    labReset();
    _ = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 40 });
    const low = says(&hx("02 10 00"), &hx("03 0f 02"));
    const low_mtu = g_peer.mtu;
    const high = says(&hx("02 ff ff"), &hx("03 0f 02"));
    const high_mtu = g_peer.mtu;
    const ok = built and cut and not_written and untouched and exchanged and whole and fits and low and high and
        mtu == 247 and low_mtu == att.default_mtu and high_mtu == att.max_mtu;
    check(ok, "att_svr mtu rsp=030f02 min={d} below_default={d} cap={d} cut22={d} overlong_kept={d} applied={d}", .{
        mtu, low_mtu, high_mtu, bit(cut), bit(untouched), bit(whole and fits),
    });
}

// ---------------------------------------------------------------------------
// ㉕ ATT 服务端 Find Information
// ---------------------------------------------------------------------------

fn checkSvrFindInfo() void {
    labReset();
    var built = true;
    for (0..6) |i| {
        // 不可读的属性也照列（§4：这个请求永远允许）。
        built = addDb(.{ .type = .{ .u16 = @intCast(0x2A00 + i) }, .value = "v", .fixed = true, .perm = .{ .write = true } }) and built;
    }
    built = addDb(.{ .type = .{ .u128 = vendor_type }, .value = "v", .fixed = true, .perm = perm_r }) and built;

    // 表 3.8、3.10：ATT_MTU 23 的 Information Data 最多 21 字节 → 5 对 (句柄, 16 位 UUID)，
    // 第 6 对留给下一页；对不拆（§3.4.3.2）。
    const page1 = says(&hx("04 01 00 ff ff"), &hx("05 01 01 00 00 2a 02 00 01 2a 03 00 02 2a 04 00 03 2a 05 00 04 2a"));
    // 接下来是 16 位 UUID，再下一条是 128 位：尺寸不同的不能进同一个包，应答到它之前为止。
    const page2 = says(&hx("04 06 00 ff ff"), &hx("05 01 06 00 05 2a"));
    // 表 3.11：128 位 UUID 的页 Format = 0x02，每对 18 字节。
    const page3 = says(&hx("04 07 00 ff ff"), &hx("05 02 07 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"));
    // §3.4.3.1：范围内没有属性 → Attribute Not Found；起始句柄为 0 或大于结束句柄 → Invalid Handle。
    // 出错句柄都是请求的起始句柄。
    const none = says(&hx("04 08 00 ff ff"), &hx("01 04 08 00 0a"));
    const zero = says(&hx("04 00 00 ff ff"), &hx("01 04 00 00 01"));
    const swapped = says(&hx("04 05 00 04 00"), &hx("01 04 05 00 01"));
    const ok = built and page1 and page2 and page3 and none and zero and swapped;
    check(ok, "att_svr find_info page1=5pairs:{d} page2={d} page128={d} not_found={d} bad_range={d}", .{
        bit(page1), bit(page2), bit(page3), bit(none), bit(zero and swapped),
    });
}

// ---------------------------------------------------------------------------
// ㉖ ATT 服务端 Read By Type：Length 字段与整条打包
// ---------------------------------------------------------------------------

fn checkSvrReadByType() void {
    labReset();
    // 等长的值：一个应答放得下几条就放几条（§3.4.4.1），不拆（§3.4.4.2）。Length 5 的条目
    // 在 ATT_MTU 23 下放 4 条（2 + 4 × 5 = 22），第 5 条留给下一次请求。
    var built = true;
    for (0..5) |_| {
        built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .fixed = true, .perm = perm_r }) and built;
    }
    const four = says(&hx("08 01 00 ff ff 00 2a"), &hx("09 05 01 00 61 62 63 02 00 61 62 63 03 00 61 62 63 04 00 61 62 63"));
    const rest = says(&hx("08 05 00 ff ff 00 2a"), &hx("09 05 05 00 61 62 63"));
    const none = says(&hx("08 06 00 ff ff 00 2a"), &hx("01 08 06 00 0a"));

    // 值长于 ATT_MTU−4：只带前 ATT_MTU−4 = 19 字节，Length = 2 + 19 = 21（表 3.16）。
    // 截断后长度相同的两条放不进同一个包（2 + 2 × 21 > 23），各回各的；
    // 长度不同的（2 与 4 字节）不进同一个包。
    labReset();
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &pat30, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = pat30[0..19], .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "ab", .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "abcd", .fixed = true, .perm = perm_r }) and built;
    const cut = says(&hx("08 01 00 ff ff 00 2a"), &hx("09 15 01 00 " ++ pat19_hex));
    const exact = says(&hx("08 02 00 ff ff 00 2a"), &hx("09 15 02 00 " ++ pat19_hex));
    const mixed = says(&hx("08 03 00 ff ff 00 2a"), &hx("09 04 03 00 61 62")) and
        says(&hx("08 04 00 ff ff 00 2a"), &hx("09 06 04 00 61 62 63 64"));
    const cuts = g_peer.att.truncated == 1;
    const ok = built and four and rest and none and cut and exact and mixed and cuts;
    check(ok, "att_svr read_by_type len5_packed4={d} len21_cut={d} len21_exact={d} len4/6_split={d} truncated={d}", .{
        bit(four and rest and none), bit(cut), bit(exact), bit(mixed), g_peer.att.truncated,
    });
}

// ---------------------------------------------------------------------------
// ㉗ ATT 服务端 Read By Group Type
// ---------------------------------------------------------------------------

fn checkSvrReadByGroup() void {
    labReset();
    // 四个只有声明的主服务（0x0001–0x0004），一个从服务带一个特征（0x0005–0x0006），
    // 一个 128 位 UUID 的主服务（0x0007），再一个 16 位的（0x0008）。
    var built = true;
    const uuids = [_][]const u8{ &hx("0a 18"), &hx("0b 18"), &hx("0c 18"), &hx("0d 18") };
    for (uuids, 0..) |u, i| {
        built = addDb(.{ .handle = @intCast(i + 1), .type = .{ .u16 = 0x2800 }, .value = u, .fixed = true, .perm = perm_r }) and built;
    }
    built = addDb(.{ .handle = 0x0005, .type = .{ .u16 = 0x2801 }, .value = &hx("f0 ff"), .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .handle = 0x0006, .type = .{ .u16 = 0x2A02 }, .value = "e", .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .handle = 0x0007, .type = .{ .u16 = 0x2800 }, .value = &vendor_svc, .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .handle = 0x0008, .type = .{ .u16 = 0x2800 }, .value = &hx("01 18"), .fixed = true, .perm = perm_r }) and built;

    // 表 3.25、3.26：条目 = 句柄 ‖ 组尾句柄 ‖ 服务 UUID，Length = 6。ATT_MTU 23 放 3 条，不拆
    // （§3.4.4.10）。只有声明的一个服务，组尾句柄就是它自己（[Vol 3] Part G §3.1）。
    const page1 = says(&hx("10 01 00 ff ff 00 28"), &hx("11 06 01 00 01 00 0a 18 02 00 02 00 0b 18 03 00 03 00 0c 18"));
    // 0x0007 是 128 位 UUID：Length 20，与 16 位的条目不进同一个包，自己占一页。
    const page2 = says(&hx("10 04 00 ff ff 00 28"), &hx("11 06 04 00 04 00 0d 18"));
    const wide = says(&hx("10 05 00 ff ff 00 28"), &hx("11 14 07 00 07 00 01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"));
    const page3 = says(&hx("10 08 00 ff ff 00 28"), &hx("11 06 08 00 08 00 01 18"));
    const none = says(&hx("10 09 00 ff ff 00 28"), &hx("01 10 09 00 0a"));
    // «Secondary Service» 也是受支持的分组类型（[Vol 3] Part G §2.5.3）；组尾是服务定义里最后一个属性。
    const secondary = says(&hx("10 01 00 ff ff 01 28"), &hx("11 06 05 00 06 00 f0 ff"));
    // «Characteristic» 不是：Unsupported Group Type，出错句柄是起始句柄（§3.4.4.9）。
    const not_group = errorIs(&hx("10 01 00 ff ff 03 28"), 0x10, 0x0001, 0x10, 0x10);
    // §3.4.4.9 注：类型一律按 128 位比较，用基底 UUID 的写法请求 0x2800 也命中。
    const alias = says(&hx("10 08 00 ff ff fb 34 9b 5f 80 00 00 80 00 10 00 00 00 28 00 00"), &hx("11 06 08 00 08 00 01 18"));
    const ok = built and page1 and page2 and wide and page3 and none and secondary and not_group and alias;
    check(ok, "att_svr read_by_group page1=3:{d} len20={d} last={d} secondary={d} not_group={d} alias={d}", .{
        bit(page1 and page2), bit(wide), bit(page3 and none), bit(secondary), bit(not_group), bit(alias),
    });
}

// ---------------------------------------------------------------------------
// ㉘ ATT 服务端 Read Blob：分段读长属性
// ---------------------------------------------------------------------------

fn checkSvrReadBlob() void {
    labReset();
    const built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &pat30, .perm = perm_r });
    // 表 3.19：ATT_READ_RSP 带前 ATT_MTU−1 字节；表 3.21：ATT_READ_BLOB_REQ 从偏移 22 接着读，
    // 带回剩下的 8 字节。两段拼回来必须就是原值。
    var joined: [30]u8 = undefined;
    var got: usize = 0;
    if (ask(&hx("0a 01 00"))) |rsp| {
        if (rsp.len == 23 and rsp[0] == 0x0b) {
            @memcpy(joined[0..22], rsp[1..]);
            got = 22;
        }
    }
    if (ask(&hx("0c 01 00 16 00"))) |rsp| {
        if (rsp.len == 9 and rsp[0] == 0x0d) {
            @memcpy(joined[got..][0..8], rsp[1..]);
            got += 8;
        }
    }
    const whole = got == 30 and eql(&joined, &pat30);
    // §3.4.4.5：偏移等于值的长度 → 部分值的长度为 0；大于长度 → Invalid Offset；句柄不存在 → Invalid Handle。
    const at_end = says(&hx("0c 01 00 1e 00"), &hx("0d"));
    const past = says(&hx("0c 01 00 1f 00"), &hx("01 0c 01 00 07"));
    const missing = says(&hx("0c 99 00 00 00"), &hx("01 0c 99 00 01"));
    check(built and whole and at_end and past and missing, "att_svr read_blob 22+8={d} at_end={d} past_end={d} bad_handle={d}", .{
        bit(whole), bit(at_end), bit(past), bit(missing),
    });
}

// ---------------------------------------------------------------------------
// ㉙ ATT 服务端 Read Multiple（定长）
// ---------------------------------------------------------------------------

fn checkSvrReadMultiple() void {
    labReset();
    var built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "de", .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "", .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "xyz", .fixed = true, .perm = .{ .write = true } }) and built;
    // 表 3.23：各值按请求的顺序首尾相接（§3.4.4.7 注：句柄不必按大小），空值不占字节。
    const joined = says(&hx("0e 01 00 02 00 03 00"), &hx("0f 61 62 63 64 65")) and
        says(&hx("0e 02 00 01 00"), &hx("0f 64 65 61 62 63"));
    // §3.4.4.7：有一个句柄读不了或不存在，整个请求回错误，出错句柄是第一个出错的属性。
    // Set Of Handles 至少两个（表 3.22）：只给一个是非法请求（§3.3）。
    const unreadable = says(&hx("0e 01 00 04 00"), &hx("01 0e 04 00 02"));
    const missing = says(&hx("0e 01 00 99 00"), &hx("01 0e 99 00 01"));
    const single = says(&hx("0e 01 00"), &hx("01 0e 00 00 04"));
    // 首尾相接之后整体截到 ATT_MTU−1 = 22 字节：20 个 'a' 之后只放得下 2 个 'b'。
    labReset();
    const a20: [20]u8 = @splat('a');
    const b20: [20]u8 = @splat('b');
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &a20, .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &b20, .fixed = true, .perm = perm_r }) and built;
    var want: [23]u8 = @splat('a');
    want[0] = 0x0f;
    want[21] = 'b';
    want[22] = 'b';
    const cut = says(&hx("0e 01 00 02 00"), &want) and g_peer.att.truncated == 1;
    const ok = built and joined and unreadable and missing and single and cut;
    check(ok, "att_svr read_multiple order={d} unreadable={d} bad_handle={d} single={d} cut22={d}", .{
        bit(joined), bit(unreadable), bit(missing), bit(single), bit(cut),
    });
}

// ---------------------------------------------------------------------------
// ㉚ ATT 服务端 Read Multiple Variable：超过 ATT_MTU−1 处截断
// ---------------------------------------------------------------------------

fn checkSvrReadVarCut() void {
    labReset();
    var built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "de", .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "", .fixed = true, .perm = perm_r }) and built;
    // 表 3.29：每个元组 = Value Length（2 字节）‖ 值；空值也有自己的元组。
    const plain = says(&hx("20 01 00 02 00 03 00"), &hx("21 03 00 61 62 63 02 00 64 65 00 00"));
    const bad_handle = errorIs(&hx("20 01 00 99 00"), 0x20, 0x0099, 0x01, 0x01);
    const single = errorIs(&hx("20 01 00"), 0x20, 0x0000, 0x04, 0x04);

    // §3.4.4.12：列表超过 ATT_MTU−1 = 22 字节，就在那里截断。10 字节的值占 12 字节，第二个值
    // 只剩 8 字节；Value Length 仍写完整长度 20（表 3.29 注：客户端不得拿它推断实际带来的字节数）。
    labReset();
    const a10: [10]u8 = @splat('a');
    const b20: [20]u8 = @splat('b');
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &a10, .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &b20, .fixed = true, .perm = perm_r }) and built;
    var want: [23]u8 = @splat('b');
    @memcpy(want[0..3], &hx("21 0a 00"));
    @memset(want[3..13], 'a');
    @memcpy(want[13..15], &hx("14 00"));
    const cut = says(&hx("20 01 00 02 00"), &want) and g_peer.att.truncated == 1;
    check(built and plain and bad_handle and single and cut, "att_svr read_var plain={d} bad_handle={d} single={d} cut_at_22={d}", .{
        bit(plain), bit(bad_handle), bit(single), bit(cut),
    });
}

// ---------------------------------------------------------------------------
// ㉛ ATT 服务端 Read Multiple Variable：截点落在 Value Length 字段里
// ---------------------------------------------------------------------------

fn checkSvrReadVarTupleCut() void {
    // §3.4.4.12：截点若落在某条元组的 Value Length 字段里，就改在那条元组的起点截断——整条不放。
    labReset();
    const a19: [19]u8 = @splat('a');
    const b1: [1]u8 = .{'b'};
    var built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &a19, .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &b1, .fixed = true, .perm = perm_r }) and built;
    // 2 + 19 = 21，只剩 1 字节，不够第二条的 Value Length：应答到第一条为止。
    var want: [22]u8 = @splat('a');
    @memcpy(want[0..3], &hx("21 13 00"));
    const inside_length = says(&hx("20 01 00 02 00"), &want);

    // 第一条正好填满 ATT_MTU−1：第二条一个字节都放不下。
    labReset();
    const a20: [20]u8 = @splat('a');
    const b20: [20]u8 = @splat('b');
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &a20, .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &b20, .fixed = true, .perm = perm_r }) and built;
    var full: [23]u8 = @splat('a');
    @memcpy(full[0..3], &hx("21 14 00"));
    const exactly_full = says(&hx("20 01 00 02 00"), &full);

    // 剩 2 字节：Value Length 字段放得下、值一个字节都放不下。截点在字段之后，不算落在字段里，
    // 所以长度字段照样写入，写的仍是完整长度 1。
    labReset();
    const a18: [18]u8 = @splat('a');
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &a18, .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = &b1, .fixed = true, .perm = perm_r }) and built;
    var tail: [23]u8 = @splat('a');
    @memcpy(tail[0..3], &hx("21 12 00"));
    @memcpy(tail[21..23], &hx("01 00"));
    const two_left = says(&hx("20 01 00 02 00"), &tail) and g_peer.att.truncated == 1;
    check(built and inside_length and exactly_full and two_left, "att_svr read_var in_length_field={d} exactly_full={d} two_left={d}", .{
        bit(inside_length), bit(exactly_full), bit(two_left),
    });
}

// ---------------------------------------------------------------------------
// ㉜ ATT 服务端排队写：Prepare 与 Execute 的写入路径
// ---------------------------------------------------------------------------

/// 两个可写的属性（一个变长、一个定长）和一个只读的，句柄 0x0001–0x0003。
fn buildQueued() bool {
    labReset();
    var built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "", .perm = perm_rw, .max_len = 10 });
    built = addDb(.{ .type = .{ .u16 = 0x2A01 }, .value = "wxyz", .fixed = true, .perm = perm_rw }) and built;
    return addDb(.{ .type = .{ .u16 = 0x2A02 }, .value = "ro", .fixed = true, .perm = perm_r }) and built;
}

fn checkSvrQueuedWrite() void {
    const built = buildQueued();
    // 表 3.35：应答复述请求里的句柄、偏移与部分值。§3.4.6.1：收到 Execute 之前值不变。
    const echo = says(&hx("16 01 00 00 00 61 62 63"), &hx("17 01 00 00 00 61 62 63")) and
        says(&hx("16 01 00 03 00 64 65 66"), &hx("17 01 00 03 00 64 65 66"));
    const before = says(&hx("0a 01 00"), &hx("0b"));
    // 表 3.36：Flags = 0x01，立即写入全部排队的值。§3.4.6.3：按接收顺序写，然后回 ATT_EXECUTE_WRITE_RSP。
    const exec = says(&hx("18 01"), &hx("19"));
    const written = says(&hx("0a 01 00"), &hx("0b 61 62 63 64 65 66"));
    // 定长属性：部分值只覆盖那一段，其余不变。
    const fixed = says(&hx("16 02 00 00 00 61 62"), &hx("17 02 00 00 00 61 62")) and
        says(&hx("18 01"), &hx("19")) and says(&hx("0a 02 00"), &hx("0b 61 62 79 7a"));
    // §3.4.6.1：同一个句柄可以排多次，按接收顺序执行，后面的盖住前面的那一段。
    const twice = says(&hx("16 01 00 00 00 78 79"), &hx("17 01 00 00 00 78 79")) and
        says(&hx("16 01 00 00 00 70 71"), &hx("17 01 00 00 00 70 71")) and
        says(&hx("18 01"), &hx("19")) and says(&hx("0a 01 00"), &hx("0b 70 71 63 64 65 66"));
    // §3.4.6.1 注：值的校验留到 Execute。先把值续到 8 字节（偏移 6 接着写），再排一条偏移 8、
    // 3 字节的：Prepare 阶段照收；Execute 时 8 + 3 超过最大长度 10 → 整个队列丢弃、回
    // Invalid Attribute Value Length（§3.4.6.3），值不变。
    const grown = says(&hx("16 01 00 06 00 44 45"), &hx("17 01 00 06 00 44 45")) and
        says(&hx("18 01"), &hx("19")) and says(&hx("0a 01 00"), &hx("0b 70 71 63 64 65 66 44 45"));
    const too_long = says(&hx("16 01 00 00 00 01 02"), &hx("17 01 00 00 00 01 02")) and
        says(&hx("16 01 00 08 00 01 02 03"), &hx("17 01 00 08 00 01 02 03")) and
        says(&hx("18 01"), &hx("01 18 01 00 0d")) and
        says(&hx("0a 01 00"), &hx("0b 70 71 63 64 65 66 44 45"));
    const ok = built and echo and before and exec and written and fixed and twice and grown and too_long;
    check(ok, "att_svr queued_write echo={d} before={d} exec={d} fixed={d} twice={d} too_long={d}", .{
        bit(echo), bit(before), bit(exec and written), bit(fixed), bit(twice), bit(grown and too_long),
    });
}

// ---------------------------------------------------------------------------
// ㉝ ATT 服务端排队写：取消与各种丢弃
// ---------------------------------------------------------------------------

fn checkSvrQueuedDiscard() void {
    const built = buildQueued();
    // 表 3.36：Flags = 0x00，丢弃全部排队的值。§3.4.6.3：队列清空，照常回 ATT_EXECUTE_WRITE_RSP。
    const cancel = says(&hx("16 01 00 00 00 7a 7a"), &hx("17 01 00 00 00 7a 7a")) and
        says(&hx("18 00"), &hx("19")) and says(&hx("0a 01 00"), &hx("0b"));
    // §3.4.6.3：排队的偏移大于当前值的长度 → 整个队列丢弃，什么都不写，回 Invalid Offset。
    const bad_offset = says(&hx("16 01 00 00 00 41 42"), &hx("17 01 00 00 00 41 42")) and
        says(&hx("16 01 00 14 00 43"), &hx("17 01 00 14 00 43")) and
        says(&hx("18 01"), &hx("01 18 01 00 07")) and says(&hx("0a 01 00"), &hx("0b"));
    // §3.4.6.1：server 可以限制排队的条数。本实现是 4 条：第 5 条回 Prepare Queue Full，
    // 已经排队的 4 条不受影响，Execute 照常写入。
    var queued = true;
    for (0..4) |i| {
        const letter: u8 = @intCast('a' + i);
        const req = [6]u8{ 0x16, 0x01, 0x00, @intCast(i), 0x00, letter };
        const rsp = [6]u8{ 0x17, 0x01, 0x00, @intCast(i), 0x00, letter };
        queued = says(&req, &rsp) and queued;
    }
    const full = errorIs(&hx("16 01 00 04 00 65"), 0x16, 0x0001, 0x09, 0x09);
    const written = says(&hx("18 01"), &hx("19")) and valueIs(1, "abcd");
    // §3.4.6.1：句柄不存在、属性不可写，在 Prepare 这一步就回错误，不入队。
    const missing = says(&hx("16 99 00 00 00 61"), &hx("01 16 99 00 01"));
    const read_only = says(&hx("16 03 00 00 00 61"), &hx("01 16 03 00 03"));
    // §3.4.6.1：链路断了，排队的值清空、不执行。
    const prepared = says(&hx("16 01 00 00 00 7a 7a 7a"), &hx("17 01 00 00 00 7a 7a 7a"));
    g_peer.reset();
    const link_lost = says(&hx("18 01"), &hx("19")) and valueIs(1, "abcd");
    const ok = built and cancel and bad_offset and queued and full and written and missing and read_only and
        prepared and link_lost;
    check(ok, "att_svr queued_discard cancel={d} bad_offset={d} queue_full={d} prepare_rejected={d} link_lost={d}", .{
        bit(cancel), bit(bad_offset), bit(queued and full and written), bit(missing and read_only), bit(prepared and link_lost),
    });
}

// ---------------------------------------------------------------------------
// ㉞ ATT 服务端权限错误码
// ---------------------------------------------------------------------------

fn checkSvrPermissions() void {
    labReset();
    var built = addDb(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r });
    built = addDb(.{ .type = .{ .u16 = 0x2803 }, .value = &hx("02 03 00 00 2a"), .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .fixed = true, .perm = perm_r }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2803 }, .value = &hx("02 05 00 01 2a"), .fixed = true, .perm = .{} }) and built;
    built = addDb(.{ .type = .{ .u16 = 0x2A01 }, .value = &hx("00 00"), .fixed = true, .perm = perm_r }) and built;
    // §3.4.4.1：按类型读时，读不了的属性不进应答，它之前的照常返回；第一条就读不了，则不再看后面的，
    // 回它的错误码，出错句柄是它（Read Not Permitted 0x02）。
    const before = says(&hx("08 01 00 ff ff 03 28"), &hx("09 07 02 00 02 03 00 00 2a"));
    const first = errorIs(&hx("08 04 00 ff ff 03 28"), 0x08, 0x0004, 0x02, 0x02);
    // §3.4.5.1：写只读属性 → Write Not Permitted（0x03），出错句柄是它，值不变；句柄不存在 → Invalid Handle。
    const denied = says(&hx("12 03 00 78"), &hx("01 12 03 00 03"));
    const kept = says(&hx("0a 03 00"), &hx("0b 61 62 63"));
    const missing = says(&hx("12 99 00 78"), &hx("01 12 99 00 01"));
    // §3.4.5.3：写命令不回应答，写不进去也只是忽略。
    const command = silent(&hx("52 03 00 78")) and valueIs(3, "abc");
    const ok = built and before and first and denied and kept and missing and command;
    check(ok, "att_svr permissions before_unreadable={d} first_unreadable={d} write_ro={d} bad_handle={d} write_cmd={d}", .{
        bit(before), bit(first), bit(denied and kept), bit(missing), bit(command),
    });
}

// ---------------------------------------------------------------------------
// ㊵ GATT 服务端声明
// ---------------------------------------------------------------------------

/// 用 addService / addCharacteristic / addDescriptor 建的一张表（句柄 0x0001–0x000D）：
///
///   0x0001 «Primary Service» 0x1800
///   0x0002 «Characteristic» «Device Name»        0x0003 值 "Example Device"（可读可写，变长）
///   0x0004 «Characteristic» «Appearance»         0x0005 值 00 00（只读，定长）
///   0x0006 «Characteristic User Description»     "Appearance"
///   0x0007 «Characteristic Presentation Format»  04 00 ad 27 01 01 00
///   0x0008 «Secondary Service»（128 位 UUID）
///   0x0009 «Characteristic»（128 位 UUID）       0x000A 值 "Vendor"（可读可写，定长）
///   0x000B «Primary Service» 0x1801
///   0x000C «Include» → 0x0001       0x000D «Include» → 0x0008
fn buildDecls() bool {
    labReset();
    var ok = addSvc(.{ .u16 = 0x1800 }, true) == 1;
    const name = addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true, .write = true }, .initial = "Example Device" });
    const appear = addCharacteristic(.{ .uuid = .{ .u16 = 0x2A01 }, .props = .{ .read = true }, .initial = &hx("00 00"), .fixed = true });
    ok = ok and name.decl == 2 and name.value == 3 and name.cccd == 0;
    ok = ok and appear.decl == 4 and appear.value == 5 and appear.cccd == 0;
    ok = addDesc(gatt_server.uuid_user_desc, "Appearance") == 6 and ok;
    ok = addDesc(gatt_server.uuid_present_fmt, &hx("04 00 ad 27 01 01 00")) == 7 and ok;
    ok = addSvc(.{ .u128 = vendor_svc }, false) == 8 and ok;
    const vendor = addCharacteristic(.{ .uuid = .{ .u128 = vendor_type }, .props = .{ .read = true, .write = true }, .initial = "Vendor", .fixed = true });
    ok = ok and vendor.decl == 9 and vendor.value == 10;
    ok = addSvc(.{ .u16 = 0x1801 }, true) == 11 and ok;
    // §3.1：包含声明紧跟服务声明，排在任何特征定义之前。
    ok = addInc(1) == 12 and ok;
    ok = addInc(8) == 13 and ok;
    return ok and g_srv.db.count == 13;
}

fn checkGattsDecls() void {
    const built = buildDecls();
    // 表 3.1：服务声明的类型是 0x2800 / 0x2801，值是服务 UUID（2 或 16 字节）。
    const svc = says(&hx("0a 01 00"), &hx("0b 00 18")) and
        says(&hx("0a 08 00"), &hx("0b 01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"));
    // 表 3.3、3.4：特征声明 = 属性位（表 3.5）‖ 值句柄 ‖ 特征 UUID（2 或 16 字节）。
    // 0x0A = Read + Write，0x02 = Read。
    const decl = says(&hx("0a 02 00"), &hx("0b 0a 03 00 00 2a")) and
        says(&hx("0a 04 00"), &hx("0b 02 05 00 01 2a")) and
        says(&hx("0a 09 00"), &hx("0b 0a 0a 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"));
    // 表 3.6：特征值声明的类型就是特征 UUID，值是初值。
    const value = says(&hx("0a 03 00"), &hx("0b 45 78 61 6d 70 6c 65 20 44 65 76 69 63 65")) and
        says(&hx("0a 05 00"), &hx("0b 00 00")) and says(&hx("0a 0a 00"), &hx("0b 56 65 6e 64 6f 72"));
    // 客户端看到的样子：Read By Group Type 给出服务的句柄范围（到下一条服务声明之前），
    // Read By Type 给出特征声明；128 位 UUID 的声明 Length 21，与 16 位的分开。
    const group = says(&hx("10 01 00 ff ff 00 28"), &hx("11 06 01 00 07 00 00 18 0b 00 0d 00 01 18"));
    const chars = says(&hx("08 01 00 ff ff 03 28"), &hx("09 07 02 00 0a 03 00 00 2a 04 00 02 05 00 01 2a")) and
        says(&hx("08 05 00 ff ff 03 28"), &hx("09 15 09 00 0a 0a 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00")) and
        says(&hx("08 0a 00 ff ff 03 28"), &hx("01 08 0a 00 0a"));
    // 表 3.1、3.3：声明只读 → Write Not Permitted。特征值按属性位：可写的写进去（变长，截到 2 字节），
    // 不可写的回 Write Not Permitted，值不变。
    const decl_ro = says(&hx("12 02 00 78"), &hx("01 12 02 00 03"));
    const value_rw = says(&hx("12 03 00 41 42"), &hx("13")) and says(&hx("0a 03 00"), &hx("0b 41 42"));
    const value_ro = says(&hx("12 05 00 40"), &hx("01 12 05 00 03")) and says(&hx("0a 05 00"), &hx("0b 00 00"));
    const ok = built and svc and decl and value and group and chars and decl_ro and value_rw and value_ro;
    check(ok, "gatts decl svc={d} chr={d} value={d} discovery={d} decl_ro={d} value={d}", .{
        bit(svc), bit(decl), bit(value), bit(group and chars), bit(decl_ro), bit(value_rw and value_ro),
    });
}

// ---------------------------------------------------------------------------
// ㊱ GATT 服务端声明：描述符
// ---------------------------------------------------------------------------

fn checkGattsDescriptors() void {
    const built = buildDecls();
    // 表 3.9：用户描述，类型 0x2901，值是 UTF-8 串。
    const user = says(&hx("0a 06 00"), &hx("0b 41 70 70 65 61 72 61 6e 63 65"));
    // 表 3.14、3.15：表示格式，类型 0x2904，值 = 格式(1) ‖ 指数(1) ‖ 单位(2) ‖ 命名空间(1) ‖ 描述(2)。
    // 这里是附录 A 的例子 {0x04, 0x00, «Percent» 0x27AD, «Bluetooth SIG» 0x01, «Outside» 0x0001}。
    const format = says(&hx("0a 07 00"), &hx("0b 04 00 ad 27 01 01 00"));
    // 类型也按声明登记：Find Information 与 Read By Type 看到的都是 0x2901 / 0x2904。
    // Read By Type 的 Length = 句柄(2) + 值：10 字节的用户描述 → 12，7 字节的表示格式 → 9。
    const types = says(&hx("04 06 00 07 00"), &hx("05 01 06 00 01 29 07 00 04 29"));
    const by_type = says(&hx("08 01 00 ff ff 01 29"), &hx("09 0c 06 00 41 70 70 65 61 72 61 6e 63 65")) and
        says(&hx("08 01 00 ff ff 04 29"), &hx("09 09 07 00 04 00 ad 27 01 01 00"));
    // §3.3.3.5：表示格式只读，不要认证与授权。
    const read_only = says(&hx("12 07 00 00"), &hx("01 12 07 00 03"));
    check(built and user and format and types and by_type and read_only, "gatts desc user={d} format={d} types={d} read_only={d}", .{
        bit(user), bit(format), bit(types and by_type), bit(read_only),
    });
}

// ---------------------------------------------------------------------------
// ㊲ GATT 服务端声明：包含声明与 secondary 服务
// ---------------------------------------------------------------------------

fn checkGattsInclude() void {
    const built = buildDecls();
    // 表 3.2：包含声明，类型 0x2802，值 = 被包含服务的句柄 ‖ 组尾句柄 ‖ 服务 UUID；
    // 服务 UUID 是 128 位时不带。
    const decl = says(&hx("0a 0c 00"), &hx("0b 01 00 07 00 00 18")) and
        says(&hx("0a 0d 00"), &hx("0b 08 00 0a 00"));
    // 客户端按类型找包含声明（§4.5.1）：条目 = 句柄(2) + 值，6 字节与 4 字节的值 → Length 8 与 6，
    // 长度不同的条目不进同一个包。
    const by_type = says(&hx("08 01 00 ff ff 02 28"), &hx("09 08 0c 00 01 00 07 00 00 18")) and
        says(&hx("08 0d 00 ff ff 02 28"), &hx("09 06 0d 00 08 00 0a 00")) and
        says(&hx("08 0e 00 ff ff 02 28"), &hx("01 08 0e 00 0a"));
    // §3.1：服务定义到下一条服务声明之前结束；不是服务声明的句柄没有组尾。
    var ends = g_srv.serviceEnd(3) == null;
    if (g_srv.serviceEnd(1)) |e| ends = ends and e == 7;
    if (g_srv.serviceEnd(8)) |e| ends = ends and e == 10;
    if (g_srv.serviceEnd(11)) |e| ends = ends and e == 13;
    // §2.6.2：发现 primary 服务时看不到 secondary 服务（vendor 那个是 0x0008–0x000A）。
    const primary = says(&hx("10 01 00 ff ff 00 28"), &hx("11 06 01 00 07 00 00 18 0b 00 0d 00 01 18"));
    const secondary = says(&hx("10 01 00 ff ff 01 28"), &hx("11 14 08 00 0a 00 01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"));
    // 指向非服务声明的包含定义加不进去，表不变。
    const not_service = failsWith(g_srv.addInclude(3), "NotAService") and g_srv.db.count == 13;
    const ok = built and decl and by_type and ends and primary and secondary and not_service;
    check(ok, "gatts include decl={d} by_type={d} ends={d} secondary={d} not_service={d}", .{
        bit(decl), bit(by_type), bit(ends), bit(primary and secondary), bit(not_service),
    });
}

// ---------------------------------------------------------------------------
// ㊳ CCCD 按 client 分别保存并门控通知
// ---------------------------------------------------------------------------

/// 0x180F 服务里一个可读、可通知的特征：声明 0x0002、值 0x0003、CCCD 0x0004。
fn buildNotifyChar() gatt_server.Char {
    labReset();
    _ = addSvc(.{ .u16 = 0x180F }, true);
    return addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A19 },
        .props = .{ .read = true, .notify = true },
        .initial = &hx("5a"),
        .fixed = true,
    });
}

fn checkGattsCccd() void {
    const level = buildNotifyChar();
    const built = level.value == 3 and level.cccd == 4;
    // 表 3.10：CCCD 的类型是 0x2902；§3.3.3.3：默认值 0x0000。
    const ty = says(&hx("04 04 00 04 00"), &hx("05 01 04 00 02 29"));
    const default_a = says(&hx("0a 04 00"), &hx("0b 00 00"));
    const default_b = says2(&hx("0a 04 00"), &hx("0b 00 00"));
    // 没有订阅：不发，也不产生字节。
    g_rx[0] = 0xEE;
    const unsubscribed = failsWith(g_srv.notify(&g_peer, level.value, &hx("64"), &g_rx), "NotSubscribed") and g_rx[0] == 0xEE;
    // client A 订阅：读、按类型读，都只看到 A 自己的配置（§3.3.3.3：每个 client 一份）；B 仍是 0x0000。
    const sub_a = says(&hx("12 04 00 01 00"), &hx("13"));
    const cfg_a = (g_srv.configOf(&g_peer, level.value) orelse 0xFFFF) == 1;
    const cfg_b = (g_srv.configOf(&g_peer2, level.value) orelse 0xFFFF) == 0;
    const read_a = says(&hx("0a 04 00"), &hx("0b 01 00"));
    const read_b = says2(&hx("0a 04 00"), &hx("0b 00 00"));
    const type_a = says(&hx("08 01 00 ff ff 02 29"), &hx("09 04 04 00 01 00"));
    const type_b = says2(&hx("08 01 00 ff ff 02 29"), &hx("09 04 04 00 00 00"));
    // 通知只发给打开了通知位的 client（表 3.38：1B ‖ 句柄 ‖ 值）。
    const to_a = notifyIs(&g_peer, level.value, &hx("1b 03 00 64"));
    const b_quiet = failsWith(g_srv.notify(&g_peer2, level.value, &hx("64"), &g_rx), "NotSubscribed");
    // B 订阅之后也收得到；A 退订只影响 A。
    const sub_b = says2(&hx("12 04 00 01 00"), &hx("13"));
    const to_b = notifyIs(&g_peer2, level.value, &hx("1b 03 00 64"));
    const unsub_a = says(&hx("12 04 00 00 00"), &hx("13"));
    const a_quiet = failsWith(g_srv.notify(&g_peer, level.value, &hx("64"), &g_rx), "NotSubscribed");
    const b_still = notifyIs(&g_peer2, level.value, &hx("1b 03 00 64"));
    // 非绑定设备的新连接：CCCD 回到默认值。
    g_peer2.reset();
    const fresh = failsWith(g_srv.notify(&g_peer2, level.value, &hx("64"), &g_rx), "NotSubscribed") and
        says2(&hx("0a 04 00"), &hx("0b 00 00"));
    check(built and ty and default_a and default_b and unsubscribed and sub_a and cfg_a and cfg_b and
        read_a and read_b and type_a and type_b and to_a and b_quiet and sub_b and to_b and unsub_a and
        a_quiet and b_still and fresh, "gatts cccd default={d} per_client={d} gated={d} unsub={d} fresh={d}", .{
        bit(ty and default_a and default_b),    bit(sub_a and cfg_a and cfg_b and read_a and read_b and type_a and type_b),
        bit(unsubscribed and to_a and b_quiet), bit(sub_b and to_b and unsub_a and a_quiet and b_still),
        bit(fresh),
    });
}

// ---------------------------------------------------------------------------
// ㊴ CCCD 写入校验
// ---------------------------------------------------------------------------

fn checkGattsCccdWrite() void {
    labReset();
    _ = addSvc(.{ .u16 = 0x180F }, true);
    const open = addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .notify = true }, .initial = &hx("5a"), .fixed = true });
    const guarded = addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A1B },
        .props = .{ .read = true, .notify = true },
        .initial = &hx("01"),
        .fixed = true,
        .sec = .{ .cccd_write_auth = true },
    });
    const built = open.cccd == 4 and guarded.value == 6 and guarded.cccd == 7;
    // 先订阅上。
    const sub = says(&hx("12 04 00 01 00"), &hx("13"));
    // 表 3.11：指示位「只能在特征属性有 indicate 时置」，其余位保留。置了 → §4.12.3 的
    // Application Error（0x80–0x9F），值不写。
    const no_indicate = errorIs(&hx("12 04 00 02 00"), 0x12, 0x0004, 0x80, 0x9F);
    const reserved = errorIs(&hx("12 04 00 04 00"), 0x12, 0x0004, 0x80, 0x9F);
    const kept = says(&hx("0a 04 00"), &hx("0b 01 00"));
    // 表 3.10：值是两个 8 位组。尺寸不对：不出 ATT_WRITE_RSP，配置不变（§4.12.3）。
    var bad_size = true;
    inline for (.{ "12 04 00 01", "12 04 00 01 00 00", "12 04 00" }) |req| {
        bad_size = errorIs(&hx(req), 0x12, 0x0004, 0x00, 0xFF) and bad_size;
    }
    const still = says(&hx("0a 04 00"), &hx("0b 01 00"));
    // 表 3.10：写 CCCD 是否要认证由上层定。要求认证的那一个，在明文链路上回 Insufficient Authentication，
    // 链路认证之后才写得上。
    const auth_required = says(&hx("12 07 00 01 00"), &hx("01 12 07 00 05"));
    g_peer.security = .{ .encrypted = true, .key_size = 16, .authenticated = true };
    const authed = says(&hx("12 07 00 01 00"), &hx("13"));
    g_peer.security = .{};
    const ok = built and sub and no_indicate and reserved and kept and bad_size and still and auth_required and authed;
    check(ok, "gatts cccd_write no_indicate_bit={d} reserved={d} bad_size={d} unchanged={d} auth={d}", .{
        bit(no_indicate), bit(reserved), bit(bad_size), bit(kept and still), bit(auth_required and authed),
    });
}

// ---------------------------------------------------------------------------
// ㊵ 指示：一次一条，等到确认，30 秒超时
// ---------------------------------------------------------------------------

/// 0x180F 服务里一个可读、可写、可通知、可指示的特征：声明 0x0002、值 0x0003、CCCD 0x0004。
fn buildProbeChar() gatt_server.Char {
    labReset();
    _ = addSvc(.{ .u16 = 0x180F }, true);
    return addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A19 },
        .props = .{ .read = true, .write = true, .notify = true, .indicate = true },
        .initial = "",
        .max_len = 60,
    });
}

fn checkGattsIndicate() void {
    const c = buildProbeChar();
    const built = c.value == 3 and c.cccd == 4;
    // 没有打开指示位：不发，也不产生字节（§3.3.3.3）。
    g_rx[0] = 0xEE;
    const unsubscribed = failsWith(g_srv.indicate(&g_peer, c.value, "hi", &g_rx, 100), "NotSubscribed") and g_rx[0] == 0xEE;
    // 通知位和指示位都打开：下面要看「等确认期间通知不受影响」。
    const sub = says(&hx("12 04 00 03 00"), &hx("13"));
    // 表 3.39：ATT_HANDLE_VALUE_IND = 1D ‖ 句柄 ‖ 值。
    var ind: [8]u8 = undefined;
    const n = @min(g_srv.indicate(&g_peer, c.value, "hi", &g_rx, 100) catch 0, ind.len);
    @memcpy(ind[0..n], g_rx[0..n]);
    const sent = n == 5 and eql(ind[0..n], &hx("1d 03 00 68 69"));
    // §3.3.2、§3.4.7.2：确认之前不能再发指示；通知不受影响。
    const pending = failsWith(g_srv.indicate(&g_peer, c.value, "hi", &g_rx, 101), "IndicationPending");
    const notify_ok = notifyIs(&g_peer, c.value, &hx("1b 03 00 68 69"));
    // §3.3.3：29 999 毫秒过去还没到 30 秒。
    const not_yet = !g_peer.tick(100 + att_server.transaction_timeout_ms - 1);
    // §3.4.7.2：客户端收到指示回 ATT_HANDLE_VALUE_CFM（1E）；确认到了，才能再发。
    g_lab_cli_pdus += 1;
    const step = g_cli.onPdu(ind[0..n], &g_tx, g_now);
    const confirms = step.outcome == .indicate and step.out_len == 1 and g_tx[0] == 0x1e;
    const cfm = silent(g_tx[0..step.out_len]) and !g_peer.indicating;
    const again = (g_srv.indicate(&g_peer, c.value, "hi", &g_rx, 102) catch 0) == 5 and silent(&hx("1e"));
    // §3.3.3：指示 30 秒没有得到确认 → 事务超时，这条 bearer 不再收发。
    _ = g_srv.indicate(&g_peer, c.value, "hi", &g_rx, 1000) catch {};
    const not_yet2 = !g_peer.tick(1000 + att_server.transaction_timeout_ms - 1) and !g_peer.dead;
    const timed_out = g_peer.tick(1000 + att_server.transaction_timeout_ms) and g_peer.dead;
    const closed = failsWith(g_srv.notify(&g_peer, c.value, "hi", &g_rx), "BearerClosed");
    const counts = g_peer.stats.indications == 3 and g_peer.stats.timeouts == 1;
    check(built and unsubscribed and sub and sent and pending and notify_ok and not_yet and confirms and cfm and
        again and not_yet2 and timed_out and closed and counts, "gatts indicate sent={d} pending={d} cfm={d} again={d} timeout={d} closed={d}", .{
        bit(unsubscribed and sub and sent),      bit(pending and notify_ok), bit(confirms and cfm), bit(again),
        bit(not_yet and not_yet2 and timed_out), bit(closed and counts),
    });
}

// ---------------------------------------------------------------------------
// ㊶ Service Changed
// ---------------------------------------------------------------------------

fn checkGattsServiceChanged() void {
    labReset();
    var ok = addSvc(.{ .u16 = 0x1800 }, true) == 1;
    _ = addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true }, .initial = "Example Device" });
    const sc = g_srv.addServiceChanged() catch gatt_server.Char{ .decl = 0, .value = 0, .cccd = 0 };
    ok = ok and sc.decl == 5 and sc.value == 6 and sc.cccd == 7;
    // 表 7.2：特征声明 = 属性位 0x20（只指示）‖ 值句柄 ‖ UUID 0x2A05；
    // 表 7.3：值不可读、不可写。
    const decl = says(&hx("0a 05 00"), &hx("0b 20 06 00 05 2a"));
    const value = says(&hx("0a 06 00"), &hx("01 0a 06 00 02")) and
        says(&hx("12 06 00 01 00"), &hx("01 12 06 00 03"));
    // §7：它住在 «GATT Service» 0x1801 里，是 0x0004–0x0007。
    const found = says(&hx("10 01 00 ff ff 00 28"), &hx("11 06 01 00 03 00 00 18 04 00 07 00 01 18"));
    // §7.1：client 没有打开指示位时，这条指示算丢了——不产生字节。它的 CCCD 只允许指示位。
    g_rx[0] = 0xEE;
    const lost = failsWith(g_srv.serviceChanged(&g_peer, 0x0001, 0xFFFF, &g_rx, 10), "NotSubscribed") and g_rx[0] == 0xEE;
    const notify_bit = errorIs(&hx("12 07 00 01 00"), 0x12, 0x0007, 0x80, 0x9F);
    const sub = says(&hx("12 07 00 02 00"), &hx("13"));
    // 表 7.3：值 = 起始句柄 ‖ 结束句柄；0x0001–0xFFFF 表示全部重新发现（§2.5.2）。
    const whole = (g_srv.serviceChanged(&g_peer, 0x0001, 0xFFFF, &g_rx, 20) catch 0) == 7 and
        eql(g_rx[0..7], &hx("1d 06 00 01 00 ff ff"));
    const pending = failsWith(g_srv.serviceChanged(&g_peer, 0x0001, 0xFFFF, &g_rx, 21), "IndicationPending");
    const cfm = silent(&hx("1e"));
    const range = (g_srv.serviceChanged(&g_peer, 0x0010, 0x0012, &g_rx, 22) catch 0) == 7 and
        eql(g_rx[0..7], &hx("1d 06 00 10 00 12 00"));
    // §7.1：只能有一个实例。新连接的 client 还没有订阅：同样算丢。
    const single = failsWith(g_srv.addServiceChanged(), "Duplicate");
    g_peer.reset();
    const fresh = failsWith(g_srv.serviceChanged(&g_peer, 0x0001, 0xFFFF, &g_rx, 30), "NotSubscribed");
    const all = ok and decl and value and found and lost and notify_bit and sub and whole and pending and cfm and
        range and single and fresh;
    check(all, "gatts service_changed decl={d} value_ro={d} found={d} lost={d} sent={d} single={d}", .{
        bit(decl), bit(value), bit(found), bit(lost and notify_bit), bit(sub and whole and range), bit(single and fresh),
    });
}

// ---------------------------------------------------------------------------
// ㊷–㊿ GATT 客户端：与本进程的 server 对打，核对线上字节
// ---------------------------------------------------------------------------

/// [Vol 3] Part G 附录 A 表 A.1 的示例 server：47 个属性，句柄、类型、值照表抄。原文只给了
/// 名字、没给编号的 UUID 是自拟的（同 `host_tests.zig`）：«Battery State Service» 0xFF10、
/// «Battery State» 0xFF11、«Thermometer Humidity Service» 0xFF20、«Weight Service» 0xFF30、
/// «Weight kg» 0xFF31、«Position Service» 0xFF40、«Latitude Longitude» 0xFF41、
/// «Latitude Longitude Elevation» 0xFF42、«Alert Service» 0xFF50、«Alert Enumeration» 0xFF51、
/// «Manufacturer Service» 0xFFF0、«Manufacturer Name» 0xFF61、«Serial Number» 0xFF62；
/// «Vendor Specific Service» 与 «Vendor Specific Type» 是 128 位。
const appendix_a = [_]Gs.Db.New{
    .{ .handle = 0x0001, .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0004, .type = .{ .u16 = 0x2803 }, .value = &hx("02 06 00 00 2a"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0006, .type = .{ .u16 = 0x2A00 }, .value = "Example Device", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0010, .type = .{ .u16 = 0x2800 }, .value = &hx("01 18"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0011, .type = .{ .u16 = 0x2803 }, .value = &hx("26 12 00 05 2a"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0012, .type = .{ .u16 = 0x2A05 }, .value = &hx("00 00 00 00"), .fixed = true, .perm = .{} },
    .{ .handle = 0x0100, .type = .{ .u16 = 0x2800 }, .value = &hx("10 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0106, .type = .{ .u16 = 0x2803 }, .value = &hx("02 10 01 11 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0110, .type = .{ .u16 = 0xFF11 }, .value = &hx("04"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0200, .type = .{ .u16 = 0x2800 }, .value = &hx("20 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0201, .type = .{ .u16 = 0x2802 }, .value = &hx("00 05 04 05 f0 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0202, .type = .{ .u16 = 0x2802 }, .value = &hx("50 05 68 05"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0203, .type = .{ .u16 = 0x2803 }, .value = &hx("02 04 02 6e 2a"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0204, .type = .{ .u16 = 0x2A6E }, .value = &hx("8a 02"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0205, .type = .{ .u16 = 0x2904 }, .value = &hx("0e fe 2f 27 01 01 00"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0206, .type = .{ .u16 = 0x2901 }, .value = "Outside Temperature", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0210, .type = .{ .u16 = 0x2803 }, .value = &hx("02 12 02 6f 2a"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0212, .type = .{ .u16 = 0x2A6F }, .value = &hx("27"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0213, .type = .{ .u16 = 0x2904 }, .value = &hx("04 00 ad 27 01 01 00"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0214, .type = .{ .u16 = 0x2901 }, .value = "Outside Relative Humidity", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0280, .type = .{ .u16 = 0x2800 }, .value = &hx("30 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0281, .type = .{ .u16 = 0x2802 }, .value = &hx("05 05 09 05 f0 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0282, .type = .{ .u16 = 0x2803 }, .value = &hx("02 83 02 31 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0283, .type = .{ .u16 = 0xFF31 }, .value = &hx("82 55 00 00"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0284, .type = .{ .u16 = 0x2904 }, .value = &hx("08 fd 24 27 01 01 00"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0285, .type = .{ .u16 = 0x2901 }, .value = "Rucksack Weight", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0300, .type = .{ .u16 = 0x2800 }, .value = &hx("40 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0301, .type = .{ .u16 = 0x2803 }, .value = &hx("02 02 03 41 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0302, .type = .{ .u16 = 0xFF41 }, .value = &hx("ce 0f 32 0b a4 af be 28"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0304, .type = .{ .u16 = 0x2803 }, .value = &hx("02 05 03 42 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0305, .type = .{ .u16 = 0xFF42 }, .value = &hx("76 01 ce 0f 32 0b a4 af be 28"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0400, .type = .{ .u16 = 0x2800 }, .value = &hx("50 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0401, .type = .{ .u16 = 0x2803 }, .value = &hx("0e 02 04 51 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0402, .type = .{ .u16 = 0xFF51 }, .value = &hx("00"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0500, .type = .{ .u16 = 0x2801 }, .value = &hx("f0 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0501, .type = .{ .u16 = 0x2803 }, .value = &hx("02 02 05 61 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0502, .type = .{ .u16 = 0xFF61 }, .value = "ACME Temperature Sensor", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0503, .type = .{ .u16 = 0x2803 }, .value = &hx("02 04 05 62 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0504, .type = .{ .u16 = 0xFF62 }, .value = "237495-3282-A", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0505, .type = .{ .u16 = 0x2801 }, .value = &hx("f0 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0506, .type = .{ .u16 = 0x2803 }, .value = &hx("02 07 05 61 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0507, .type = .{ .u16 = 0xFF61 }, .value = "ACME Weighing Scales", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0508, .type = .{ .u16 = 0x2803 }, .value = &hx("02 09 05 62 ff"), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0509, .type = .{ .u16 = 0xFF62 }, .value = "11267-2327A00239", .fixed = true, .perm = perm_r },
    .{ .handle = 0x0550, .type = .{ .u16 = 0x2801 }, .value = &vendor_svc, .fixed = true, .perm = perm_r },
    .{ .handle = 0x0560, .type = .{ .u16 = 0x2803 }, .value = &hx("02 68 05" ++ " " ++ vendor_type_hex), .fixed = true, .perm = perm_r },
    .{ .handle = 0x0568, .type = .{ .u128 = vendor_type }, .value = "Vendor", .fixed = true, .perm = perm_r },
};

comptime {
    // 表 A.1 共 47 行。
    std.debug.assert(appendix_a.len == 47);
}

/// 装上附录 A 的表。
fn appendixA() bool {
    var ok = true;
    for (appendix_a) |row| {
        if (g_srv.db.add(row)) |_| {} else |_| ok = false;
    }
    return ok and g_srv.db.count == 47;
}

// ---------------------------------------------------------------------------
// ㊷ GATT 客户端 Discover All Primary Services
// ---------------------------------------------------------------------------

fn checkGattcPrimary() void {
    labReset();
    const built = appendixA();
    // §4.4.1：«Primary Service»、0x0001–0xFFFF；下一条请求的起始句柄 = 上一个 End Group Handle + 1；
    // 以 Attribute Not Found 结束。ATT_MTU 23 每页 3 个服务。
    const got = runScript(g_cli.discoverPrimaryServices(&g_tx, g_now) catch 0, &.{
        &hx("10 01 00 ff ff 00 28"),
        &hx("11 06 01 00 06 00 00 18 10 00 12 00 01 18 00 01 10 01 10 ff"),
        &hx("10 11 01 ff ff 00 28"),
        &hx("11 06 00 02 14 02 20 ff 80 02 85 02 30 ff 00 03 05 03 40 ff"),
        &hx("10 06 03 ff ff 00 28"),
        &hx("11 06 00 04 02 04 50 ff"),
        &hx("10 03 04 ff ff 00 28"),
        &hx("01 10 03 04 0a"),
    });
    // 结果是 7 个 primary 服务；三个 secondary 服务（0x0500、0x0505、0x0550）不在其中。
    const S = struct { start: u16, end: u16, uuid: u16 };
    const rows = [_]S{
        .{ .start = 0x0001, .end = 0x0006, .uuid = 0x1800 }, .{ .start = 0x0010, .end = 0x0012, .uuid = 0x1801 },
        .{ .start = 0x0100, .end = 0x0110, .uuid = 0xFF10 }, .{ .start = 0x0200, .end = 0x0214, .uuid = 0xFF20 },
        .{ .start = 0x0280, .end = 0x0285, .uuid = 0xFF30 }, .{ .start = 0x0300, .end = 0x0305, .uuid = 0xFF40 },
        .{ .start = 0x0400, .end = 0x0402, .uuid = 0xFF50 },
    };
    var results = g_cli.service_count == rows.len;
    for (rows, 0..) |r, i| {
        if (i >= g_cli.service_count) break;
        const s = g_cli.services[i];
        results = results and s.start == r.start and s.end == r.end and (s.uuid.asU16() orelse 0) == r.uuid;
    }
    check(built and got.ok and results, "gattc primary script={d}/{d} at={d} services={d}/{d}", .{
        bit(got.ok), got.len, got.at, g_cli.service_count, rows.len,
    });
}

// ---------------------------------------------------------------------------
// ㊸ GATT 客户端 Exchange MTU
// ---------------------------------------------------------------------------

fn checkGattcExchangeMtu() void {
    labReset();
    var built = appendixA();
    g_cli.rx_mtu = 247;
    g_peer.server_rx_mtu = 100;
    // §4.3.1、§3.4.2.2：Client Rx MTU 247、Server Rx MTU 100 → ATT_MTU = 100。
    const first = runScript(g_cli.exchangeMtu(&g_tx, g_now) catch 0, &.{ &hx("02 f7 00"), &hx("03 64 00") });
    const mtu = g_cli.mtu == 100 and g_peer.mtu == 100;
    // §4.3.1：这个子过程每个连接只能做一次。
    const once = failsWith(g_cli.exchangeMtu(&g_tx, g_now), "AlreadyExchanged");
    // ATT_MTU 100 下一个应答装得下全部 7 个 primary 服务：同样的发现从 8 个 PDU 变成 4 个。
    const second = runScript(g_cli.discoverPrimaryServices(&g_tx, g_now) catch 0, &.{
        &hx("10 01 00 ff ff 00 28"),
        &hx("11 06 01 00 06 00 00 18 10 00 12 00 01 18 00 01 10 01 10 ff 00 02 14 02 20 ff 80 02 85 02 30 ff 00 03 05 03 40 ff 00 04 02 04 50 ff"),
        &hx("10 03 04 ff ff 00 28"),
        &hx("01 10 03 04 0a"),
    });
    const count = g_cli.service_count == 7;

    // 对端回得小于默认值：过程照样算完成，ATT_MTU 不变，仍是 23（§3.4.2.2）。
    labReset();
    built = appendixA() and built;
    g_cli.rx_mtu = 247;
    _ = g_cli.exchangeMtu(&g_tx, g_now) catch {};
    const step = g_cli.onPdu(&hx("03 10 00"), &g_tx, g_now);
    const low = step.outcome == .done and g_cli.mtu == att.default_mtu;
    // §3.4.2.1：本端能收的小于默认值，不发。
    labReset();
    g_cli.rx_mtu = 22;
    const small = failsWith(g_cli.exchangeMtu(&g_tx, g_now), "MtuTooSmall");
    const ok = built and first.ok and mtu and once and second.ok and count and low and small;
    check(ok, "gattc mtu script={d}/{d} at={d} mtu={d} once={d} fast={d}/{d} at={d} low={d} small={d}", .{
        bit(first.ok), first.len,  first.at, bit(mtu), bit(once), bit(second.ok), second.len, second.at,
        bit(low),      bit(small),
    });
}

// ---------------------------------------------------------------------------
// ㊹ GATT 客户端 Discover All Characteristics
// ---------------------------------------------------------------------------

fn checkGattcCharacteristics() void {
    labReset();
    const built = appendixA();
    // §4.6.1：在一个服务的句柄范围里找 «Characteristic»。两条 16 位 UUID 的声明装在一个应答里；
    // 最后一条声明不是范围的最后一个句柄，所以再问一次，以 Attribute Not Found 结束。
    const svc = runScript(g_cli.discoverCharacteristics(.{ .start = 0x0200, .end = 0x0214 }, null, &g_tx, g_now) catch 0, &.{
        &hx("08 00 02 14 02 03 28"),
        &hx("09 07 03 02 02 04 02 6e 2a 10 02 02 12 02 6f 2a"),
        &hx("08 11 02 14 02 03 28"),
        &hx("01 08 11 02 0a"),
    });
    var in_service = g_cli.char_count == 2;
    if (in_service) {
        const a = g_cli.chars[0];
        const b = g_cli.chars[1];
        in_service = a.decl == 0x0203 and a.value == 0x0204 and a.props == 0x02 and (a.uuid.asU16() orelse 0) == 0x2A6E and
            b.decl == 0x0210 and b.value == 0x0212 and b.props == 0x02 and (b.uuid.asU16() orelse 0) == 0x2A6F;
    }
    // 整个 server：ATT_MTU 23 每页 3 条 16 位 UUID 的声明；128 位 UUID 的声明 Length 21，
    // 与别的条目放不进同一个应答，自己占一页（§4.6.1 的注）。
    const all = runScript(g_cli.discoverCharacteristics(.{ .start = 0x0001, .end = 0xFFFF }, null, &g_tx, g_now) catch 0, &.{
        &hx("08 01 00 ff ff 03 28"),
        &hx("09 07 04 00 02 06 00 00 2a 11 00 26 12 00 05 2a 06 01 02 10 01 11 ff"),
        &hx("08 07 01 ff ff 03 28"),
        &hx("09 07 03 02 02 04 02 6e 2a 10 02 02 12 02 6f 2a 82 02 02 83 02 31 ff"),
        &hx("08 83 02 ff ff 03 28"),
        &hx("09 07 01 03 02 02 03 41 ff 04 03 02 05 03 42 ff 01 04 0e 02 04 51 ff"),
        &hx("08 02 04 ff ff 03 28"),
        &hx("09 07 01 05 02 02 05 61 ff 03 05 02 04 05 62 ff 06 05 02 07 05 61 ff"),
        &hx("08 07 05 ff ff 03 28"),
        &hx("09 07 08 05 02 09 05 62 ff"),
        &hx("08 09 05 ff ff 03 28"),
        &hx("09 15 60 05 02 68 05 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"),
        &hx("08 61 05 ff ff 03 28"),
        &hx("01 08 61 05 0a"),
    });
    // 表里共 14 条特征声明，最后一条的 UUID 是 128 位。
    var whole = g_cli.char_count == 14;
    if (whole) {
        const last = g_cli.chars[13];
        whole = last.decl == 0x0560 and last.value == 0x0568 and eql(&last.uuid.to128(), &vendor_type);
    }
    check(built and svc.ok and in_service and all.ok and whole, "gattc chars svc={d}/{d} results={d} all={d}/{d} at={d} results={d}", .{
        bit(svc.ok), svc.len, bit(in_service), bit(all.ok), all.len, all.at, bit(whole),
    });
}

// ---------------------------------------------------------------------------
// ㊺ GATT 客户端 Read 与 Read Long
// ---------------------------------------------------------------------------

fn checkGattcReadLong() void {
    labReset();
    const built = appendixA();
    // §4.8.1：ATT_READ_REQ / ATT_READ_RSP。
    const short = runScript(g_cli.read(0x0204, &g_tx, g_now) catch 0, &.{ &hx("0a 04 02"), &hx("0b 8a 02") });
    const short_value = g_cli.value_len == 2 and eql(g_cli.value[0..2], &hx("8a 02"));
    // §4.8.3：23 字节的值读成两段——ATT_READ_RSP 带前 ATT_MTU−1 = 22 字节，
    // ATT_READ_BLOB_REQ 从偏移 22 接着读；最后一段短于 ATT_MTU−1，过程结束。
    const acme = "ACME Temperature Sensor";
    var head: [23]u8 = undefined;
    head[0] = 0x0b;
    @memcpy(head[1..], acme[0..22]);
    const two = runScript(g_cli.readLong(0x0502, &g_tx, g_now) catch 0, &.{
        &hx("0a 02 05"), &head, &hx("0c 02 05 16 00"), &hx("0d 72"),
    });
    const whole = g_cli.value_len == acme.len and eql(g_cli.value[0..g_cli.value_len], acme);
    // 普通 Read 只拿得到前 ATT_MTU−1 字节。
    const partial = runScript(g_cli.read(0x0502, &g_tx, g_now) catch 0, &.{ &hx("0a 02 05"), &head });
    const partial_value = g_cli.value_len == 22;
    // 25 字节的值：22 + 3。
    var head25: [23]u8 = undefined;
    head25[0] = 0x0b;
    @memcpy(head25[1..], "Outside Relative Humidity"[0..22]);
    const tail = runScript(g_cli.readLong(0x0214, &g_tx, g_now) catch 0, &.{
        &hx("0a 14 02"), &head25, &hx("0c 14 02 16 00"), &hx("0d 69 74 79"),
    });
    const tail_value = g_cli.value_len == 25;
    const ok = built and short.ok and short_value and two.ok and whole and partial.ok and partial_value and
        tail.ok and tail_value;
    check(ok, "gattc read {d}/{d} long22+1={d} value={d} read_only22={d} long22+3={d}", .{
        bit(short.ok), short.len, bit(two.ok), bit(whole), bit(partial.ok and partial_value), bit(tail.ok and tail_value),
    });
}

// ---------------------------------------------------------------------------
// ㊻ GATT 客户端 Read Multiple Variable Length
// ---------------------------------------------------------------------------

fn checkGattcReadMultipleVar() void {
    labReset();
    const built = appendixA();
    // §4.8.5：ATT_READ_MULTIPLE_VARIABLE_REQ，每个值前带自己的长度；空值也有元组。
    const plain = runScript(g_cli.readMultiple(&.{ 0x0204, 0x0212, 0x0402 }, true, &g_tx, g_now) catch 0, &.{
        &hx("20 04 02 12 02 02 04"), &hx("21 02 00 8a 02 01 00 27 01 00 00"),
    });
    var plain_values = g_cli.hit_count == 3;
    if (plain_values) {
        const h0 = g_cli.hits[0];
        const h1 = g_cli.hits[1];
        const h2 = g_cli.hits[2];
        plain_values = h0.len == 2 and h0.present == 2 and eql(g_cli.value[h0.off..][0..2], &hx("8a 02")) and
            h1.len == 1 and h1.present == 1 and g_cli.value[h1.off] == 0x27 and
            h2.len == 1 and h2.present == 1 and g_cli.value[h2.off] == 0x00;
    }
    // §3.4.4.12 注：23 字节的值只带来 20 字节（列表在 ATT_MTU−1 = 22 处截断），Value Length 仍写 23。
    var cut_pdu: [23]u8 = undefined;
    @memcpy(cut_pdu[0..3], &hx("21 17 00"));
    @memcpy(cut_pdu[3..], "ACME Temperature Sen");
    const cut = runScript(g_cli.readMultiple(&.{ 0x0502, 0x0212 }, true, &g_tx, g_now) catch 0, &.{
        &hx("20 02 05 12 02"), &cut_pdu,
    });
    const cut_len: u16 = if (g_cli.hit_count == 1) g_cli.hits[0].len else 0;
    const cut_present: u16 = if (g_cli.hit_count == 1) g_cli.hits[0].present else 0;
    // 截点会落在第二条元组的 Value Length 字段里：在它起点截断，整条不放 → 只有一条元组。
    var tuple_pdu: [22]u8 = undefined;
    @memcpy(tuple_pdu[0..3], &hx("21 13 00"));
    @memcpy(tuple_pdu[3..], "Outside Temperature");
    const tuple_cut = runScript(g_cli.readMultiple(&.{ 0x0206, 0x0212 }, true, &g_tx, g_now) catch 0, &.{
        &hx("20 06 02 12 02"), &tuple_pdu,
    });
    const tuple_hits = g_cli.hit_count;
    check(built and plain.ok and plain_values and cut.ok and cut_len == 23 and cut_present == 20 and
        tuple_cut.ok and tuple_hits == 1, "gattc read_var {d}/{d} cut={d}/{d} len/present={d}/{d} tuple_cut={d}/{d} hits={d}", .{
        bit(plain.ok),     plain.len,     bit(cut.ok), cut.len, cut_len, cut_present,
        bit(tuple_cut.ok), tuple_cut.len, tuple_hits,
    });
}

// ---------------------------------------------------------------------------
// ㊼ GATT 客户端对 addService 建的表做发现
// ---------------------------------------------------------------------------

fn checkGattcProbeDiscovery() void {
    const c = buildProbeChar();
    const built = c.value == 3 and c.cccd == 4 and g_srv.db.count == 4;
    // §4.4.1：从 0x0001 找起；下一条请求的起始句柄 = End Group Handle + 1，以 Attribute Not Found 结束。
    const services = runScript(g_cli.discoverPrimaryServices(&g_tx, g_now) catch 0, &.{
        &hx("10 01 00 ff ff 00 28"), &hx("11 06 01 00 04 00 0f 18"),
        &hx("10 05 00 ff ff 00 28"), &hx("01 10 05 00 0a"),
    });
    const svc_ok = g_cli.service_count == 1 and g_cli.services[0].start == 1 and g_cli.services[0].end == 4 and
        (g_cli.services[0].uuid.asU16() orelse 0) == 0x180F;
    // §4.6.1：特征声明 = 属性位 0x3A（Read、Write、Notify、Indicate，表 3.5）‖ 值句柄 0x0003 ‖ UUID 0x2A19。
    const chars = runScript(g_cli.discoverCharacteristics(.{ .start = 1, .end = 4 }, null, &g_tx, g_now) catch 0, &.{
        &hx("08 01 00 04 00 03 28"), &hx("09 07 02 00 3a 03 00 19 2a"),
        &hx("08 03 00 04 00 03 28"), &hx("01 08 03 00 0a"),
    });
    const char_ok = g_cli.char_count == 1 and g_cli.chars[0].value == 3 and g_cli.chars[0].props == 0x3A and
        (g_cli.chars[0].uuid.asU16() orelse 0) == 0x2A19;
    check(built and services.ok and svc_ok and chars.ok and char_ok, "gattc probe discovery svc={d}/{d} at={d} results={d} chr={d}/{d} at={d} results={d}", .{
        bit(services.ok), services.len, services.at, bit(svc_ok), bit(chars.ok), chars.len, chars.at, bit(char_ok),
    });
}

// ---------------------------------------------------------------------------
// ㊽ GATT 客户端 Write Long
// ---------------------------------------------------------------------------

/// 用 Write Long 把 `data` 写进句柄 `handle`：线上必须是 18 + 18 + 4 三段排队写再 Execute，
/// 写完之后属性的值就是 `data`。
fn writeLong40(handle: u16, data: []const u8) Run {
    // §4.9.4：每段最多 ATT_MTU−5 = 18 字节；最后 ATT_EXECUTE_WRITE_REQ 的 Flags = 0x01。
    // 这个子过程不要求核对 ATT_PREPARE_WRITE_RSP（§4.9.4 注），这里核对 server 确实原样复述。
    const got = runScript(g_cli.writeLong(handle, data, &g_tx, g_now) catch 0, &.{
        &hx("16 03 00 00 00 " ++ pat18a_hex),
        &hx("17 03 00 00 00 " ++ pat18a_hex),
        &hx("16 03 00 12 00 " ++ pat18b_hex),
        &hx("17 03 00 12 00 " ++ pat18b_hex),
        &hx("16 03 00 24 00 " ++ pat4_hex),
        &hx("17 03 00 24 00 " ++ pat4_hex),
        &hx("18 01"),
        &hx("19"),
    });
    return .{ .ok = got.ok and valueIs(handle, data), .at = got.at, .len = got.len };
}

fn checkGattcWriteLong() void {
    const c = buildProbeChar();
    const built = c.value == 3 and valueIs(c.value, "");
    const got = writeLong40(c.value, &pat40);
    check(built and got.ok, "gattc write_long script={d}/{d} at={d} stored={d}", .{
        bit(got.ok), got.len, got.at, bit(valueIs(c.value, &pat40)),
    });
}

// ---------------------------------------------------------------------------
// ㊾ GATT 客户端写长之后：Read Long 两段、Read Multiple Variable 截断
// ---------------------------------------------------------------------------

fn checkGattcReadAfterWrite() void {
    const c = buildProbeChar();
    const written = writeLong40(c.value, &pat40);
    // §4.8.3：40 字节读成两段，22 + 18；最后一段短于 ATT_MTU−1，过程结束。
    const read = runScript(g_cli.readLong(c.value, &g_tx, g_now) catch 0, &.{
        &hx("0a 03 00"),
        &hx("0b " ++ pat22_hex),
        &hx("0c 03 00 16 00"),
        &hx("0d " ++ pat8_hex ++ " d3 da e1 e8 ef f6" ++ " " ++ pat4_hex),
    });
    const value = g_cli.value_len == 40 and eql(g_cli.value[0..40], &pat40);
    // §4.8.5、§3.4.4.12：第一个值就占满 ATT_MTU−1，只有第一个元组。Value Length 写完整长度 40，
    // 实际带来的值只有 20 字节。
    const multi = runScript(g_cli.readMultiple(&.{ c.value, 1 }, true, &g_tx, g_now) catch 0, &.{
        &hx("20 03 00 01 00"),
        &hx("21 28 00 " ++ pat18a_hex ++ " 7f 86"),
    });
    const tuple_ok = g_cli.hit_count == 1 and g_cli.hits[0].len == 40 and g_cli.hits[0].present == 20;
    check(written.ok and read.ok and value and multi.ok and tuple_ok, "gattc read_after_write long22+18={d} value={d} var_len40/present20={d}", .{
        bit(read.ok), bit(value), bit(multi.ok and tuple_ok),
    });
}

// ---------------------------------------------------------------------------
// ㊿ GATT 客户端订阅通知并收到
// ---------------------------------------------------------------------------

fn checkGattcSubscribe() void {
    const c = buildProbeChar();
    const built = c.cccd == 4;
    // 还没有订阅：server 发不出通知。
    const gated = failsWith(g_srv.notify(&g_peer, c.value, "hi", &g_rx), "NotSubscribed");
    // §4.12.3：写 CCCD 的通知位（表 3.11）就是一条 ATT_WRITE_REQ / ATT_WRITE_RSP。
    const sub = runScript(g_cli.write(c.cccd, &hx("01 00"), &g_tx, g_now) catch 0, &.{
        &hx("12 04 00 01 00"), &hx("13"),
    });
    // §4.10.1：server 发 Handle Value Notification；客户端拿到句柄与值，不回任何 PDU。
    const sent = notifyIs(&g_peer, c.value, &hx("1b 03 00 68 69"));
    g_lab_cli_pdus += 1;
    const step = g_cli.onPdu(g_rx[0..5], &g_tx, g_now);
    var received = step.outcome == .notify and step.out_len == 0;
    if (step.event) |ev| {
        received = received and ev.handle == c.value and eql(ev.value, "hi");
    } else {
        received = false;
    }
    // 退订（写 0x0000）：又发不出了。
    const unsub = runScript(g_cli.write(c.cccd, &hx("00 00"), &g_tx, g_now) catch 0, &.{
        &hx("12 04 00 00 00"), &hx("13"),
    });
    const quiet = failsWith(g_srv.notify(&g_peer, c.value, "hi", &g_rx), "NotSubscribed");
    check(built and gated and sub.ok and sent and received and unsub.ok and quiet, "gattc subscribe sub={d}/{d} sent={d} received={d} unsub={d} quiet={d}", .{
        bit(sub.ok), sub.len, bit(sent), bit(received), bit(unsub.ok), bit(quiet),
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 第三批特性的判据各在自己的文件里，经这个回调记到同一本账上。
fn extCheck(ok: bool, text: []const u8) void {
    check(ok, "{s}", .{text});
}

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
    checkCmacRfc4493();
    checkCmacDbHash();
    checkSignKat();
    checkSignedWrite();
    checkSvrMtu();
    checkSvrFindInfo();
    checkSvrReadByType();
    checkSvrReadByGroup();
    checkSvrReadBlob();
    checkSvrReadMultiple();
    checkSvrReadVarCut();
    checkSvrReadVarTupleCut();
    checkSvrQueuedWrite();
    checkSvrQueuedDiscard();
    checkSvrPermissions();
    checkGattsDecls();
    checkGattsDescriptors();
    checkGattsInclude();
    checkGattsCccd();
    checkGattsCccdWrite();
    checkGattsIndicate();
    checkGattsServiceChanged();
    checkGattcPrimary();
    checkGattcExchangeMtu();
    checkGattcCharacteristics();
    checkGattcReadLong();
    checkGattcReadMultipleVar();
    checkGattcProbeDiscovery();
    checkGattcWriteLong();
    checkGattcReadAfterWrite();
    checkGattcSubscribe();
    ext_adv_selftest.run(extCheck);
    eatt_selftest.run(extCheck);
    privacy_selftest.run(extCheck);
    sixlowpan_selftest.run(extCheck);
    nd6_selftest.run(extCheck);
    sfr_selftest.run(extCheck);
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

    log.line("read: att_gatt server_pdus={d} client_pdus={d} local_errors={d}", .{
        g_lab_svr_pdus, g_lab_cli_pdus, g_lab_errs,
    });

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
