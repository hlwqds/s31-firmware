//! iso_selftest：第五批特性 iso（LE Isochronous HCI 接口面）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 经 `isoCheck` 调用。不 import board，
//! 不分配堆内存；说明文字不超过 180 字节（`board.log` 一行超过 200 字节会被截断）。
//! 每个判据函数 `noinline`（ReleaseSmall 会把内联函数的大数组叠进同一个栈帧，
//! 板侧主栈标称只有 16 KiB）；大缓冲放在文件作用域。
//!
//! 判据（主机测试 `iso_tests.zig` 覆盖得更细；括号里是条款号，HCI 在 [Vol 4] Part E，
//! 链路层在 [Vol 6] Part B）：
//!   ① LE Set CIG Parameters：24+9n 八位组已知答案（§7.8.97）
//!   ② LE Set CIG Parameters 返回参数：Status + CIG_ID + CIS_Count + 句柄数组（§7.8.97）
//!   ③ LE Create CIS：句柄对交错排列（§7.8.99）；重复 CIS 句柄被拒
//!   ④ LE Accept / Reject CIS Request：帧与返回参数（§7.8.101 / §7.8.102）
//!   ⑤ LE Create BIG：31 八位组含 Broadcast_Code（§7.8.103）
//!   ⑥ 未加密却给非零 Broadcast_Code 被拒（§7.8.103 的 Host shall）
//!   ⑦ LE BIG Create Sync：BIS 索引严格递增（§7.8.106）
//!   ⑧ BIS 索引乱序被拒（§7.8.106 的 shall）
//!   ⑨ LE Setup ISO Data Path：Codec_ID 5 八位组 + 配置（§7.8.109）
//!   ⑩ transparent air mode 带配置被拒（§7.8.109）
//!   ⑪ LE Remove ISO Data Path：方向位图 0x00–0x03 都可编码（§7.8.110 的位表
//!     没有「shall set at least one bit」）
//!   ⑫ 方向位图带保留位被拒（§7.8.110）
//!   ⑬ LE Read ISO TX Sync 返回参数（§7.8.96）
//!   ⑭ LE Read ISO Link Quality 返回参数：7 个计数器按表 7.3（§7.8.116）
//!   ⑮ LE CIS Established：28 八位组逐字段（§7.7.65.25）
//!   ⑯ LE CIS Request：6 八位组（§7.7.65.26）
//!   ⑰ LE Create BIG Complete：句柄数组（§7.7.65.27）
//!   ⑱ LE BIG Sync Lost：句柄 + 原因（§7.7.65.30）
//!   ⑲ BIGInfo 33 八位组手排逐字段（§4.4.6.11；位置按 NimBLE（盘上）与上游 Zephyr
//!     ble_ll_sync.c 交叉核对）；57 八位组 = 加密（§4.4.6.10）
//!   ⑳ HCI ISO Data 包：complete SDU + TS 手排（§5.4.5 图 5.5）
//!   ㉑ lost data 无载荷；带载荷被拒（§5.4.5 最后一段 shall）
//!   ㉒ 公式：BIG_Sync_Delay、GC、组偏移、控制子事件偏移、payload 计数器
//!     （§4.4.6.3–§4.4.6.7）

const std = @import("std");

const iso = @import("iso.zig");

fn nib(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("不是十六进制字符"),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    inline for (0..s.len / 2) |i| {
        out[i] = (nib(s[2 * i]) << 4) | nib(s[2 * i + 1]);
    }
    return out;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// 命令输出缓冲（最大 255+4）与句柄数组，放文件作用域避免占栈。
var out_buf: [300]u8 = undefined;
var handles_buf: [31]u16 = undefined;

/// ① Set CIG Parameters（§7.8.97）：单 CIS 的 28 字节帧（与主机测试同一字节串）。
const k_set_cig = hex("01622018" ++ "00" ++ "ff0000" ++ "ff0000" ++ "00" ++ "00" ++ "00" ++
    "0500" ++ "0500" ++ "01" ++ "00" ++ "2000" ++ "2000" ++ "01" ++ "01" ++ "00" ++ "00");

noinline fn ckSetCig(check: fn (bool, []const u8) void) void {
    const cis = [_]iso.CigCisParams{.{
        .cis_id = 0,
        .max_sdu_c_to_p = 0x020,
        .max_sdu_p_to_c = 0x020,
        .phy_c_to_p = 0x01,
        .phy_p_to_c = 0x01,
        .rtn_c_to_p = 0,
        .rtn_p_to_c = 0,
    }};
    const n = iso.leSetCigParameters(&out_buf, 0, 0x0000FF, 0x0000FF, 0, 0, 0, 5, 5, &cis) catch unreachable;
    check(n == k_set_cig.len and eq(out_buf[0..n], &k_set_cig), "iso 1: set CIG params frame matches hand-packed bytes (§7.8.97)");
}

/// ② Set CIG 返回参数（§7.8.97）：Status=00, CIG_ID=0, count=1, handle=0x42。
const k_set_cig_ret = hex("000001" ++ "4200");

noinline fn ckSetCigRet(check: fn (bool, []const u8) void) void {
    const r = iso.parseSetCigReturn(&k_set_cig_ret, &handles_buf) catch unreachable;
    check(r.status == 0 and r.cig_id == 0 and r.handles.len == 1 and r.handles[0] == 0x42, "iso 2: set CIG return parses status+cig_id+handle (§7.8.97)");
}

/// ③ Create CIS（§7.8.99）。
const k_create_cis = hex("016420" ++ "09" ++ "02" ++ "4200" ++ "8000" ++ "4300" ++ "8100");

noinline fn ckCreateCis(check: fn (bool, []const u8) void) void {
    const pairs = [_]iso.CreateCisPair{
        .{ .cis_handle = 0x0042, .acl_handle = 0x0080 },
        .{ .cis_handle = 0x0043, .acl_handle = 0x0081 },
    };
    const n = iso.leCreateCis(&out_buf, &pairs) catch unreachable;
    const ok_frame = n == k_create_cis.len and eq(out_buf[0..n], &k_create_cis);
    const dup = [_]iso.CreateCisPair{
        .{ .cis_handle = 0x0042, .acl_handle = 0x0080 },
        .{ .cis_handle = 0x0042, .acl_handle = 0x0081 },
    };
    const dup_rejected = std.meta.isError(iso.leCreateCis(&out_buf, &dup));
    check(ok_frame and dup_rejected, "iso 3: create CIS packs pairs, duplicate CIS handle rejected (§7.8.99)");
}

noinline fn ckAcceptReject(check: fn (bool, []const u8) void) void {
    const na = iso.leAcceptCisRequest(&out_buf, 0x0042) catch unreachable;
    const ok_a = eq(out_buf[0..na], &hex("016620" ++ "02" ++ "4200"));
    const nr = iso.leRejectCisRequest(&out_buf, 0x0042, 0x13) catch unreachable;
    const ok_r = eq(out_buf[0..nr], &hex("016720" ++ "03" ++ "4200" ++ "13"));
    const ret = iso.parseRejectReturn(&hex("00" ++ "4200")) catch unreachable;
    check(ok_a and ok_r and ret.conn_handle == 0x0042, "iso 4: accept/reject CIS request frames and return (§7.8.101/102)");
}

/// ⑤⑥ Create BIG（§7.8.103）。
const k_create_big = hex("0168201f" ++ "01" ++ "05" ++ "02" ++ "ff0000" ++ "ff00" ++ "0a00" ++
    "02" ++ "03" ++ "01" ++ "00" ++ "01" ++ "00112233445566778899aabbccddeeff");

noinline fn ckCreateBig(check: fn (bool, []const u8) void) void {
    var params: iso.CreateBigParams = .{
        .big_handle = 1,
        .advertising_handle = 5,
        .num_bis = 2,
        .sdu_interval = 0x0000FF,
        .max_sdu = 0x00FF,
        .max_transport_latency = 0x000A,
        .rtn = 2,
        .phy = 0x03,
        .packing = 1,
        .framing = 0,
        .encryption = 1,
        .broadcast_code = hex("00112233445566778899aabbccddeeff"),
    };
    const n = iso.leCreateBig(&out_buf, params) catch unreachable;
    const ok_frame = n == k_create_big.len and eq(out_buf[0..n], &k_create_big);
    params.encryption = 0;
    const plain_rejected = std.meta.isError(iso.leCreateBig(&out_buf, params));
    check(ok_frame and plain_rejected, "iso 5: create BIG frame matches; unencrypted non-zero code rejected (§7.8.103)");
}

/// ⑦⑧ BIG Create Sync（§7.8.106）。
noinline fn ckBigCreateSync(check: fn (bool, []const u8) void) void {
    const ok_params: iso.BigCreateSyncParams = .{
        .big_handle = 2,
        .sync_handle = 0x0040,
        .encryption = 0,
        .mse = 0,
        .big_sync_timeout = 0x00C8,
        .bis = &.{ 1, 3 },
    };
    const n = iso.leBigCreateSync(&out_buf, ok_params) catch unreachable;
    const ok_frame = n == 4 + 24 + 2 and out_buf[3] == 26 and out_buf[4] == 2 and out_buf[28] == 1 and out_buf[29] == 3;
    const bad: iso.BigCreateSyncParams = .{
        .big_handle = 2,
        .sync_handle = 0x0040,
        .encryption = 0,
        .mse = 0,
        .big_sync_timeout = 0x00C8,
        .bis = &.{ 3, 1 },
    };
    const disorder_rejected = std.meta.isError(iso.leBigCreateSync(&out_buf, bad));
    check(ok_frame and disorder_rejected, "iso 6: BIG create sync packs; non-ascending BIS list rejected (§7.8.106)");
}

/// ⑨⑩ Setup ISO Data Path（§7.8.109）。
const k_setup_path = hex("016e20" ++ "0f" ++ "4200" ++ "00" ++ "00" ++ "06" ++ "6b00" ++
    "0100" ++ "f40100" ++ "02" ++ "0102");

noinline fn ckSetupPath(check: fn (bool, []const u8) void) void {
    var params: iso.SetupIsoDataPathParams = .{
        .conn_handle = 0x0042,
        .data_path_direction = 0,
        .data_path_id = 0,
        .coding_format = 0x06,
        .company_id = 0x006B,
        .vs_codec_id = 1,
        .controller_delay = 500,
        .codec_config = &.{ 0x01, 0x02 },
    };
    const n = iso.leSetupIsoDataPath(&out_buf, params) catch unreachable;
    const ok_frame = n == k_setup_path.len and eq(out_buf[0..n], &k_setup_path);
    params.coding_format = iso.coding_fmt_transparent_air;
    const transparent_rejected = std.meta.isError(iso.leSetupIsoDataPath(&out_buf, params));
    check(ok_frame and transparent_rejected, "iso 7: setup ISO path packs codec id+config; transparent air with config rejected (§7.8.109)");
}

/// ⑪⑫ Remove ISO Data Path（§7.8.110）。位表没有「shall set at least one bit」
/// （那两句在 §7.8.97 / §7.8.103 的 PHY 参数），0x00 可编码；保留位被拒。
noinline fn ckRemovePath(check: fn (bool, []const u8) void) void {
    const n = iso.leRemoveIsoDataPath(&out_buf, 0x0042, 0x03) catch unreachable;
    const ok_both = eq(out_buf[0..n], &hex("016f20" ++ "03" ++ "4200" ++ "03"));
    const n0 = iso.leRemoveIsoDataPath(&out_buf, 0x0042, 0x00) catch unreachable;
    const ok_none = eq(out_buf[0..n0], &hex("016f20" ++ "03" ++ "4200" ++ "00"));
    const reserved_rejected = std.meta.isError(iso.leRemoveIsoDataPath(&out_buf, 0x0042, 0x10));
    check(ok_both and ok_none and reserved_rejected, "iso 8: remove ISO path dir 0 and 1/2/3 encode, reserved bits rejected (§7.8.110)");
}

noinline fn ckTxSync(check: fn (bool, []const u8) void) void {
    const n = iso.leReadIsoTxSync(&out_buf, 0x0042) catch unreachable;
    const ok_frame = eq(out_buf[0..n], &hex("016120" ++ "02" ++ "4200"));
    const r = iso.parseTxSyncReturn(&hex("00" ++ "4200" ++ "3412" ++ "efcdab89" ++ "2c1b0a")) catch unreachable;
    const ok_ret = r.packet_sequence_number == 0x1234 and r.tx_time_stamp == 0x89ABCDEF and r.time_offset == 0x0A1B2C;
    check(ok_frame and ok_ret, "iso 9: read ISO TX sync frame and return parse (§7.8.96)");
}

noinline fn ckLinkQuality(check: fn (bool, []const u8) void) void {
    const n = iso.leReadIsoLinkQuality(&out_buf, 0x0042) catch unreachable;
    const ok_frame = eq(out_buf[0..n], &hex("017520" ++ "02" ++ "4200"));
    var buf: [iso.LinkQualityReturn.packed_len]u8 = undefined;
    buf[0] = 0;
    std.mem.writeInt(u16, buf[1..3], 0x0042, .little);
    inline for (0..7) |i| std.mem.writeInt(u32, buf[3 + 4 * i ..][0..4], @intCast(i + 1), .little);
    const r = iso.parseLinkQualityReturn(&buf) catch unreachable;
    const ok_ret = r.tx_unacked_packets == 1 and r.duplicate_packets == 7 and r.crc_error_packets == 5;
    check(ok_frame and ok_ret, "iso 10: read ISO link quality frame and 7 counters in table order (§7.8.116 table 7.3)");
}

/// ⑮ CIS Established（§7.7.65.25）。
const k_cis_est = hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++
    "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "0800");

noinline fn ckCisEstablished(check: fn (bool, []const u8) void) void {
    const r = iso.parseCisEstablished(&k_cis_est) catch unreachable;
    const ok = r.conn_handle == 0x0042 and r.cig_sync_delay == 0xEA and r.iso_interval == 8 and
        r.phy_p_to_c == 3 and r.max_pdu_c_to_p == 0xFB and r.isoIntervalUs() == 10_000;
    check(ok, "iso 11: CIS established parses 28 octets incl 10ms iso interval (§7.7.65.25)");
}

noinline fn ckCisRequest(check: fn (bool, []const u8) void) void {
    const r = iso.parseCisRequest(&hex("4000" ++ "4100" ++ "05" ++ "06")) catch unreachable;
    check(r.acl_conn_handle == 0x40 and r.cis_conn_handle == 0x41 and r.cig_id == 5 and r.cis_id == 6, "iso 12: CIS request parses ACL/CIS handles and CIG/CIS ids (§7.7.65.26)");
}

/// ⑰ Create BIG Complete（§7.7.65.27）。
const k_big_comp = hex("00" ++ "03" ++ "001000" ++ "002000" ++ "02" ++ "04" ++ "03" ++ "05" ++
    "02" ++ "fb00" ++ "1000" ++ "02" ++ "4000" ++ "4100");

noinline fn ckBigComplete(check: fn (bool, []const u8) void) void {
    const r = iso.parseCreateBigComplete(&k_big_comp, &handles_buf) catch unreachable;
    const ok = r.big_handle == 3 and r.bn == 3 and r.irc == 2 and r.num_bis == 2 and
        r.handles.len == 2 and r.handles[0] == 0x40 and r.handles[1] == 0x41;
    check(ok, "iso 13: create BIG complete parses params and 2 BIS handles (§7.7.65.27)");
}

noinline fn ckBigSyncLost(check: fn (bool, []const u8) void) void {
    const r = iso.parseBigSyncLost(&hex("03" ++ "08")) catch unreachable;
    check(r.big_handle == 3 and r.reason == 0x08, "iso 14: BIG sync lost parses handle and timeout reason (§7.7.65.30)");
}

/// ⑲ BIGInfo 33 八位组手排（§4.4.6.11，图 4.38 的位位置按 NimBLE ble_ll_sync.c
/// :670-702（盘上）与上游 Zephyr pdu.h:1107-1146（不在本机 esp-idf 树，见 iso.zig
/// 文件头）交叉核对）。
const k_biginfo = hex("19000310" ++ "46" ++ "983a30" ++ "7c9220" ++ "1b" ++ "00" ++
    "efbeadde" ++ "10278007" ++ "efbe" ++ "ffffffff" ++ "3f" ++ "05000000" ++ "80");

noinline fn ckBigInfo(check: fn (bool, []const u8) void) void {
    const bi = iso.parseBigInfo(&k_biginfo) catch unreachable;
    const ok = bi.offsetUs() == 750 and bi.iso_interval == 6 and bi.num_bis == 2 and bi.nse == 6 and
        bi.bn == 2 and bi.sub_interval_us == 15000 and bi.bis_spacing_us == 37500 and
        bi.irc == 2 and bi.max_pdu == 27 and bi.seed_access_address == 0xDEADBEEF and
        bi.sdu_interval_us == 10000 and bi.max_sdu == 120 and bi.base_crc_init == 0xBEEF and
        eq(&bi.chm, &hex("ffffffff1f")) and bi.phy_ll == .le_2m and bi.phyHci() == 2 and
        bi.payload_count == 5 and bi.framing and !bi.encrypted and bi.offsetValid();
    check(ok, "iso 15: BIGInfo 33-octet hand-pack parses every field incl phy and offset (§4.4.6.11)");
}

noinline fn ckBigInfoEncrypted(check: fn (bool, []const u8) void) void {
    var buf: [57]u8 = undefined;
    @memcpy(buf[0..33], &k_biginfo);
    @memcpy(buf[33..41], &hex("0011223344556677"));
    @memcpy(buf[41..57], &hex("8899aabbccddeeff0011223344556677"));
    const bi = iso.parseBigInfo(&buf) catch unreachable;
    const ok_enc = bi.encrypted and eq(&bi.giv, &hex("0011223344556677"));
    const bad_len = std.meta.isError(iso.parseBigInfo(buf[0..34]));
    check(ok_enc and bad_len, "iso 16: 57-octet BIGInfo is encrypted with GIV/GSKD; wrong length rejected (§4.4.6.10/11)");
}

/// ⑳ ISO Data 包：complete SDU + TS（§5.4.5 图 5.5；位置与 NimBLE ble_hs_iso.c、
/// Zephyr hci_types.h 交叉核对）。
const k_iso_comp_ts = hex("0260" ++ "0b00" ++ "44332211" ++ "0700" ++ "0300" ++ "aabbcc");

noinline fn ckIsoPacket(check: fn (bool, []const u8) void) void {
    const n = iso.encodeIsoData(&out_buf, 2, .complete_sdu, 0x11223344, 7, 3, .valid, &hex("aabbcc")) catch unreachable;
    const ok_enc = eq(out_buf[0..n], &k_iso_comp_ts);
    const d = iso.decodeIsoData(&k_iso_comp_ts) catch unreachable;
    const ok_dec = d.conn_handle == 2 and d.ts.? == 0x11223344 and d.packet_sequence_number.? == 7 and
        d.sdu_len.? == 3 and d.status.? == .valid and eq(d.fragment, &hex("aabbcc"));
    check(ok_enc and ok_dec, "iso 17: ISO data packet complete SDU+TS encodes/decodes (§5.4.5)");
}

noinline fn ckIsoLost(check: fn (bool, []const u8) void) void {
    const d = iso.decodeIsoData(&hex("0220" ++ "0400" ++ "0000" ++ "0080")) catch unreachable;
    const ok_lost = d.status.? == .lost and d.fragment.len == 0 and d.sdu_len.? == 0;
    const with_data = std.meta.isError(iso.decodeIsoData(&hex("0220050007000080" ++ "aa")));
    check(ok_lost and with_data, "iso 18: lost data packet has no payload; lost with fragment rejected (§5.4.5)");
}

/// ㉒ 公式（§4.4.6.3–§4.4.6.7）。
noinline fn ckFormulas(check: fn (bool, []const u8) void) void {
    const ok_delay = iso.bigSyncDelayUs(2, 37500, 6, 15000, 500) == 113_000;
    const ok_gc = (iso.groupCount(6, 2) catch unreachable) == 3 and
        (std.meta.isError(iso.groupCount(5, 2)));
    const ok_group = iso.groupEventOffset(2, 3, 3) == 6;
    const ok_ctrl = iso.bigControlOffsetUs(.sequential, 2, 37500, 6, 15000) == 75_000 and
        iso.bigControlOffsetUs(.interleaved, 2, 37500, 6, 15000) == 90_000;
    const ok_payload = iso.payloadRange(10, 2).lo == 20 and iso.payloadRange(10, 2).hi == 21;
    const ok_interval = iso.intervalUs(8) == 10_000;
    check(ok_delay and ok_gc and ok_group and ok_ctrl and ok_payload and ok_interval, "iso 19: BIG formulas big_sync_delay/gc/group/ctrl_offset/payload/interval (§4.4.6.3-4.4.6.7)");
}

noinline fn ckExpects(check: fn (bool, []const u8) void) void {
    const status_cmds = iso.expects(iso.op_le_create_cis).? == .command_status and
        iso.expects(iso.op_le_create_big).? == .command_status and
        iso.expects(iso.op_le_big_create_sync).? == .command_status and
        iso.expects(iso.op_le_accept_cis_request).? == .command_status;
    const complete_cmds = iso.expects(iso.op_le_set_cig_params).? == .command_complete and
        iso.expects(iso.op_le_read_iso_link_quality).? == .command_complete;
    check(status_cmds and complete_cmds, "iso 20: command status vs complete mapping per spec Event(s) text (§7.8.97-116)");
}

/// 入口：`selftest.zig` 经 `isoCheck` 调用；`iso_tests.zig` 在主机上跑同一份。
pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    ckSetCig(check);
    ckSetCigRet(check);
    ckCreateCis(check);
    ckAcceptReject(check);
    ckCreateBig(check);
    ckBigCreateSync(check);
    ckSetupPath(check);
    ckRemovePath(check);
    ckTxSync(check);
    ckLinkQuality(check);
    ckCisEstablished(check);
    ckCisRequest(check);
    ckBigComplete(check);
    ckBigSyncLost(check);
    ckBigInfo(check);
    ckBigInfoEncrypted(check);
    ckIsoPacket(check);
    ckIsoLost(check);
    ckFormulas(check);
    ckExpects(check);
}
