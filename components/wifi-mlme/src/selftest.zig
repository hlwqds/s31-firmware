//! wifi-mlme：板侧自检（24 条判据）。
//!
//! 每条判据打印一行 `check: ... ok=1/0`，最后一行 `checks: passed=N failed=M
//! total=N+M`。判据与主机侧 `src/host_tests.zig` 是同一批向量、同一批断言，
//! 只是板侧没有堆、日志走 `board.log.line`。本组件板侧**不碰射频**：被测对象是
//! 八段纯逻辑（`frame.zig` / `ie.zig` / `mgmt.zig` / `robust.zig` / `mlme.zig` /
//! `scan.zig` / `qos.zig` / `powersave.zig`）。
//!
//! 24 条判据：
//!
//!   ① FCS：wpa-Induction.pcap 八帧的帧尾 FCS 逐字节命中，改一字节即失败；Annex J.9.1
//!   ② FCS 逐位参考实现与查表实现互为反射，接收余数 = 0xC704DD7B（9.2.4.8，p.665）
//!   ③ 四种 To DS / From DS 组合的帧头逐字段解析并原样封回（Table 9-3）
//!   ④ Duration/ID（Table 9-5）与 PS-Poll 的 AID
//!   ⑤ Annex J.9.1 / J.9.2 帧：类型、地址、Reason Code、MME
//!   ⑥ 元素：Country（mesh.pcap）、Beacon 固定字段、Supported Rates、TIM 的 AID 位
//!   ⑦ RSNE：原文五个样例解析后由构造器逐字节复原；MFPC / PMKID；负例
//!   ⑧ Extended Capabilities（Table 9-135）
//!   ⑨ 帧体：Authentication / Association Response / Disassociation 固定字段与负例
//!   ⑩ robust 判定：Deauthentication / SA Query 为 robust，Public / Beacon 不是；Table 9-47
//!   ⑪ Open System 认证：发出的帧 = 抓包第 78 帧，收到第 80 帧进 State 2
//!   ⑫ 关联：请求 = Table 9-29 顺序的帧，无 RSNA 进 State 4
//!   ⑬ 有 RSNA 停在 State 3，MLME-SETPROTECTION.request(Rx_Tx) 后进 State 4
//!   ⑭ Disassociation / Deauthentication / 认证超时 / 类违规响应
//!   ⑮ 扫描计划（主动 12 步、被动 3 步）
//!   ⑯ Probe Request = 抓包第 58 帧；BSS 表把 Beacon 与 Probe Response 合并为一条
//!   ⑰ QoS Control（Table 9-6）：七行布局拆开再拼回去；保留位与管理帧的负例
//!   ⑱ QoS 数据帧：抓包的 TID 0 / TID 7 帧与重传；3 地址、4 地址帧构造后解析；负例
//!   ⑲ UP ↔ TID ↔ AC、Table 9-137 默认 EDCA 参数、QoS Info 与 QoS Capability 元素
//!   ⑳ TIM / DTIM：AID → 位、Bitmap Offset、组播位、DTIM Count、偏移越界
//!   ㉑ PS-Poll 帧：格式、长度与 AID 的负例；抓包里 STA 用 Null 帧进出 PS 模式
//!   ㉒ U-APSD 两侧：trigger 帧与服务期（STA）、Max SP Length（AP）
//!   ㉓ STA 模型与 AP 模型对接：进 PS → PS-Poll 取 BU → DTIM 组播 → 回到 active 补发
//!   ㉔ More Data 的含义与提示、监听间隔

const std = @import("std");

const board = @import("board");
const log = board.log;

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const mgmt = @import("mgmt.zig");
const robust = @import("robust.zig");
const mlme = @import("mlme.zig");
const scan = @import("scan.zig");
const vectors = @import("vectors.zig");

const qos = @import("qos.zig");
const powersave = @import("powersave.zig");
const rrm_wnm_selftest = @import("rrm_wnm_selftest.zig");
const wnm_tfs_selftest = @import("wnm_tfs_selftest.zig");
const rrm_caps_selftest = @import("rrm_caps_selftest.zig");

/// 新判据共用的一块缓冲，放在文件作用域，不占栈。
var g_scratch: [320]u8 = undefined;

/// 结果是不是错误（任何 error union）。
fn isErr(res: anytype) bool {
    _ = res catch return true;
    return false;
}

/// Beacon 里的 TIM 元素体；帧坏或没带 TIM 返回 null。
fn beaconTim(beacon: []const u8) ?[]const u8 {
    const f = frame.parse(beacon, .none) catch return null;
    const el = findEl(f.body[12..], .tim) orelse return null;
    return el.body;
}

fn decodeFails(layout: qos.Layout, w: u16) bool {
    _ = qos.decode(layout, w) catch return true;
    return false;
}

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [186]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn eql(a: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, a, y);
}

fn b(ok: bool) u32 {
    return @intFromBool(ok);
}

/// 带帧尾 FCS 的帧按「校验 FCS」解析；失败返回 null。
fn parseOk(mpdu: []const u8) ?frame.Frame {
    return frame.parse(mpdu, .checked) catch null;
}

/// 找到指定 ID 的第一个元素；元素串坏掉或没找到都返回 null。
fn findEl(elements: []const u8, id: ie.ElementId) ?ie.Element {
    const el = ie.find(elements, id) catch return null;
    return el;
}

const basic_rates = [_]ie.Rate{
    .{ .value = 2, .basic = true },   .{ .value = 4, .basic = true },
    .{ .value = 11, .basic = true },  .{ .value = 22, .basic = true },
    .{ .value = 36, .basic = false }, .{ .value = 48, .basic = false },
    .{ .value = 72, .basic = false }, .{ .value = 108, .basic = false },
};
const ext_rates = [_]ie.Rate{
    .{ .value = 12, .basic = false }, .{ .value = 18, .basic = false },
    .{ .value = 24, .basic = false }, .{ .value = 96, .basic = false },
};
const suite_ccmp = [1]ie.Suite{ie.Suite.ieee(4)};
const suite_psk = [1]ie.Suite{ie.Suite.ieee(2)};
const ap_capability = mgmt.Capability.fromWord(0x0411);

const capture_frames = [_][]const u8{
    &vectors.cap_beacon,     &vectors.cap_probe_req, &vectors.cap_probe_resp,
    &vectors.cap_auth_1,     &vectors.cap_auth_2,    &vectors.cap_assoc_req,
    &vectors.cap_assoc_resp, &vectors.cap_disassoc,
};
const capture_fcs = [_][]const u8{
    &vectors.cap_beacon_fcs,     &vectors.cap_probe_req_fcs, &vectors.cap_probe_resp_fcs,
    &vectors.cap_auth_1_fcs,     &vectors.cap_auth_2_fcs,    &vectors.cap_assoc_req_fcs,
    &vectors.cap_assoc_resp_fcs, &vectors.cap_disassoc_fcs,
};

/// 进程内对端 AP：按 STA 的请求拼响应帧（帧尾带 FCS）。
const PeerAp = struct {
    address: frame.Mac,
    seq: u12 = 4000,
    buf: [128]u8 = undefined,

    fn mpdu(self: *PeerAp, subtype: frame.MgmtSubtype, dst: frame.Mac, body: []const u8) []const u8 {
        const hdr = frame.Header{
            .fc = .{ .type = .mgmt, .subtype = @backingInt(subtype) },
            .addr1 = dst,
            .addr2 = self.address,
            .addr3 = self.address,
            .seq_ctrl = @as(u16, self.seq) << 4,
        };
        self.seq +%= 1;
        const n = frame.seal(hdr, body, true, &self.buf) catch return self.buf[0..0];
        return self.buf[0..n];
    }

    fn authResp(self: *PeerAp, sta: frame.Mac, status: u16) []const u8 {
        var body: [6]u8 = undefined;
        const n = mgmt.buildOpenSystemAuth(2, status, &body) catch return self.buf[0..0];
        return self.mpdu(.auth, sta, body[0..n]);
    }

    fn assocResp(self: *PeerAp, sta: frame.Mac, status: u16, aid: u16) []const u8 {
        var body: [16]u8 = undefined;
        const n = mgmt.buildAssociationResponse(.{ .capability = ap_capability, .status = status, .aid = aid, .elements = &[_]u8{ 1, 2, 2, 4 } }, &body) catch
            return self.buf[0..0];
        return self.mpdu(.assoc_resp, sta, body[0..n]);
    }
};

fn assocRequest(peer: frame.Mac) mlme.Machine.AssocRequest {
    return .{
        .peer = peer,
        .listen_interval = 10,
        .capability = mgmt.Capability.fromWord(0x0431),
        .ssid = "Coherer",
        .rates = &basic_rates,
        .ext_rates = &ext_rates,
        .rsne = .{ .group_data_cipher = ie.Suite.ieee(2), .pairwise = &suite_ccmp, .akms = &suite_psk, .caps = ie.RsnCaps{} },
    };
}

fn deliver(m: *mlme.Machine, mpdu: []const u8) mlme.Machine.RxOutcome {
    const f = frame.parse(mpdu, .checked) catch return .ignored_unexpected;
    return m.receive(f, .{}) catch .ignored_unexpected;
}

/// 取走待发帧、回报已确认，返回取到的整帧字节数（0 表示没有待发帧）。
fn ackPending(m: *mlme.Machine) usize {
    const tx = m.takeTx() orelse return 0;
    const n = tx.mpdu.len;
    _ = m.txResult(true);
    return n;
}

/// 发认证请求并收下 AP 的成功响应。
fn authRound(m: *mlme.Machine, ap: *PeerAp) bool {
    m.authenticate(ap.address, 1024, 0) catch return false;
    if (ackPending(m) == 0) return false;
    const consumed = deliver(m, ap.authResp(vectors.cap_sta, 0)) == .consumed;
    const confirmed = if (m.poll()) |ev| ev.authenticate_confirm.result == .success else false;
    return consumed and confirmed and m.stateOf(ap.address) == .state2;
}

/// 把 STA 带到 State 4（dot11RSNAActivated = false）。
fn associated(m: *mlme.Machine, ap: *PeerAp) bool {
    if (!authRound(m, ap)) return false;
    m.associate(assocRequest(ap.address), 0) catch return false;
    if (ackPending(m) == 0) return false;
    if (deliver(m, ap.assocResp(vectors.cap_sta, 0, 1)) != .consumed) return false;
    _ = m.poll(); // 取走 associate_confirm
    return m.stateOf(ap.address) == .state4;
}

// ---------------------------------------------------------------------------
// ① ② FCS
// ---------------------------------------------------------------------------

fn checkFcs() void {
    var hit = true;
    var tamper_rejected = true;
    for (capture_frames, capture_fcs) |mpdu, want| {
        const f = parseOk(mpdu) orelse {
            hit = false;
            continue;
        };
        hit = hit and eql(&f.fcs.?, want);
        var bad: [160]u8 = undefined;
        @memcpy(bad[0..mpdu.len], mpdu);
        bad[mpdu.len - 1] ^= 0x01;
        tamper_rejected = tamper_rejected and !frame.fcsOk(bad[0..mpdu.len]);
    }
    // Annex J.9.1 明文帧 + 本实现算出的 FCS = zlib.crc32 的跨实现值。
    var j91: [30]u8 = undefined;
    @memcpy(j91[0..26], &vectors.j91_deauth_plain);
    std.mem.writeInt(u32, j91[26..30], frame.crc32(&vectors.j91_deauth_plain), .little);
    const j91_ok = eql(j91[26..30], &vectors.j91_deauth_plain_fcs) and frame.fcsOk(&j91);
    check(hit and tamper_rejected and j91_ok, "fcs capture=8/8 tamper_rej={d} j91={d}", .{ b(tamper_rejected), b(j91_ok) });
}

fn checkFcsReference() void {
    var data: [40]u8 = undefined;
    var seed: u32 = 0x2026_1124;
    for (&data) |*x| {
        seed = seed *% 1664525 +% 1013904223;
        x.* = @truncate(seed >> 13);
    }
    const fast = frame.crc32(&data);
    const serial = frame.fcsSerialPolynomial(&data);
    var whole: [44]u8 = undefined;
    @memcpy(whole[0..40], &data);
    std.mem.writeInt(u32, whole[40..44], fast, .little);
    // 逐位实现与查表实现互为 32 位反射；整帧的接收余数是 p.665 的多项式。
    const reflect_ok = @bitReverse(serial) == fast;
    const residue_ok = frame.residueSerialPolynomial(&whole) == frame.fcs_residue_polynomial and
        frame.crc32Register(&whole) == frame.fcs_residue_reflected;
    check(reflect_ok and residue_ok, "fcs serial_reflect={d} residue_c704dd7b={d}", .{ b(reflect_ok), b(residue_ok) });
}

// ---------------------------------------------------------------------------
// ③ ④ 帧头字段
// ---------------------------------------------------------------------------

fn checkHeader() void {
    const x1 = frame.Mac{ 2, 0, 0, 0, 0, 1 };
    const x2 = frame.Mac{ 2, 0, 0, 0, 0, 2 };
    const x3 = frame.Mac{ 2, 0, 0, 0, 0, 3 };
    const x4 = frame.Mac{ 2, 0, 0, 0, 0, 4 };
    // (FC 两个字节, To DS, From DS, 地址数)。第四个是 QoS Data + Retry + Order（带 HT Control）。
    const Combo = struct { fc: [2]u8, to_ds: bool, from_ds: bool, n: u8 };
    const combos = [_]Combo{
        .{ .fc = .{ 0x08, 0x0c }, .to_ds = false, .from_ds = false, .n = 3 },
        .{ .fc = .{ 0x08, 0x51 }, .to_ds = true, .from_ds = false, .n = 3 },
        .{ .fc = .{ 0x08, 0xa2 }, .to_ds = false, .from_ds = true, .n = 3 },
        .{ .fc = .{ 0x88, 0x8b }, .to_ds = true, .from_ds = true, .n = 4 },
    };
    var ok = true;
    var again: [64]u8 = undefined;
    for (combos) |c| {
        var mpdu: [64]u8 = undefined;
        var p: usize = 0;
        mpdu[p..][0..2].* = c.fc;
        p += 2;
        std.mem.writeInt(u16, mpdu[p..][0..2], 0x2c3a, .little);
        p += 2;
        mpdu[p..][0..6].* = x1;
        p += 6;
        mpdu[p..][0..6].* = x2;
        p += 6;
        mpdu[p..][0..6].* = x3;
        p += 6;
        std.mem.writeInt(u16, mpdu[p..][0..2], 0xabc7, .little);
        p += 2;
        if (c.n == 4) {
            mpdu[p..][0..6].* = x4;
            p += 6;
        }
        const has_qos = (c.fc[0] & 0x80) != 0;
        if (has_qos) {
            std.mem.writeInt(u16, mpdu[p..][0..2], 0x07a2, .little);
            p += 2;
        }
        if (has_qos and (c.fc[1] & 0x80) != 0) {
            mpdu[p..][0..4].* = .{ 0x11, 0x22, 0x33, 0x44 };
            p += 4;
        }
        mpdu[p..][0..3].* = .{ 6, 5, 4 };
        p += 3;
        std.mem.writeInt(u32, mpdu[p..][0..4], frame.crc32(mpdu[0..p]), .little);
        p += 4;

        const f = parseOk(mpdu[0..p]) orelse {
            ok = false;
            continue;
        };
        const h = f.hdr;
        ok = ok and h.fc.to_ds == c.to_ds and h.fc.from_ds == c.from_ds;
        ok = ok and h.fc.more_fragments == ((c.fc[1] & 0x04) != 0);
        ok = ok and h.fc.retry == ((c.fc[1] & 0x08) != 0);
        ok = ok and h.fc.power_management == ((c.fc[1] & 0x10) != 0);
        ok = ok and h.fc.more_data == ((c.fc[1] & 0x20) != 0);
        ok = ok and h.fc.protected_frame == ((c.fc[1] & 0x40) != 0);
        ok = ok and h.duration_id.word() == 0x2c3a and h.sequenceNumber() == 0xabc and h.fragmentNumber() == 7;
        ok = ok and std.mem.eql(u8, &h.addr1, &x1) and std.mem.eql(u8, &h.addr2.?, &x2);
        ok = ok and std.mem.eql(u8, &h.addr3.?, &x3) and ((h.addr4 == null) == (c.n == 3));
        ok = ok and eql(f.body, &[_]u8{ 6, 5, 4 });
        if (has_qos) {
            const q = h.qos.?;
            ok = ok and q.tid == 2 and q.a_msdU_present and q.ack_policy == .no_ack and q.high == 7;
        } else {
            ok = ok and h.qos == null;
        }
        const n = frame.seal(h, f.body, true, &again) catch 0;
        ok = ok and n == p and eql(again[0..n], mpdu[0..p]);
    }
    check(ok, "header 4 ds combos fields+roundtrip={d}", .{b(ok)});

    // Duration/ID（Table 9-5）。
    const d0 = frame.decodeDurationId(0x8000);
    const d1 = frame.decodeDurationId(0xc7d7);
    const d2 = frame.decodeDurationId(0xc7d8);
    const d3 = frame.decodeDurationId(0x013a);
    const dur_ok = d0 == .pcf and d1 == .aid and d1.aid == 2007 and d2 == .reserved and
        d3 == .duration and d3.duration == 314 and d1.word() == 0xc7d7;
    // PS-Poll：Duration/ID 字段带着 B14=B15=1 的 AID；两个地址。
    var pp: [20]u8 = undefined;
    pp[0..2].* = .{ 0xa4, 0x00 };
    std.mem.writeInt(u16, pp[2..4], 0xc7d7, .little);
    pp[4..10].* = x1;
    pp[10..16].* = x2;
    std.mem.writeInt(u32, pp[16..20], frame.crc32(pp[0..16]), .little);
    var ps_ok = false;
    if (parseOk(&pp)) |f| {
        ps_ok = f.hdr.duration_id == .aid and f.hdr.duration_id.aid == 2007 and f.header.len == 16;
    }
    check(dur_ok and ps_ok, "duration_id table9-5={d} ps_poll_aid={d}", .{ b(dur_ok), b(ps_ok) });
}

// ---------------------------------------------------------------------------
// ⑤ Annex J.9
// ---------------------------------------------------------------------------

fn checkAnnexJ() void {
    // 三帧各自一个标志：哪一帧解析失败都保持 false，不会被别的帧带过。
    var plain_ok = false;
    if (frame.parse(&vectors.j91_deauth_plain, .none) catch null) |f| {
        plain_ok = f.hdr.fc.isMgmt(.deauth) and f.isGroupAddressed() and !f.hdr.fc.protected_frame;
        plain_ok = plain_ok and f.hdr.sequenceNumber() == 0 and f.hdr.fragmentNumber() == 9;
        if (mgmt.parseDeauthentication(f.body)) |d| {
            plain_ok = plain_ok and d.reason_code == mgmt.ReasonCode.invalid_authentication;
        } else |_| {
            plain_ok = false;
        }
    }
    var mmie_ok = false;
    if (frame.parse(&vectors.j91_deauth_bip, .none) catch null) |f| {
        // Protected 标志不置位；帧体 = Reason Code + MME。
        mmie_ok = !f.hdr.fc.protected_frame and eql(f.body[2..], &vectors.j91_mme_element);
        if (ie.parseMmie(&vectors.j91_mmie_body)) |m| {
            mmie_ok = mmie_ok and m.key_id == 4 and m.ipn == 4 and eql(m.mic, &vectors.j91_mme_mic);
        } else |_| {
            mmie_ok = false;
        }
    }
    var unicast_ok = false;
    if (frame.parse(&vectors.j92_deauth_plain, .none) catch null) |f| {
        unicast_ok = !f.isGroupAddressed() and std.mem.eql(u8, &f.hdr.addr1, &[_]u8{ 2, 0, 0, 0, 1, 0 });
        if (mgmt.parseDeauthentication(f.body)) |d| {
            unicast_ok = unicast_ok and d.reason_code == 2 and f.hdr.sequenceNumber() == 6;
        } else |_| {
            unicast_ok = false;
        }
    }
    // J.9.2 的单播 Deauthentication 置 Protected 后，FC = 原文 AAD 里的 c0 40。
    const fc = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.deauth), .protected_frame = true };
    var fc_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &fc_bytes, fc.encode(), .little);
    check(plain_ok and mmie_ok and unicast_ok and eql(&fc_bytes, &vectors.j92_aad_frame_control), "annex_j91_j92 plain={d} mmie_key4_ipn4={d} unicast={d}", .{
        b(plain_ok), b(mmie_ok), b(unicast_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑥ ⑦ ⑧ 信息元素
// ---------------------------------------------------------------------------

fn checkElements() void {
    // Country（mesh.pcap）：13 个 Subband Triplet。
    var country_ok = false;
    var w = ie.Walker.init(&vectors.mesh_country_element);
    if (w.next()) |el_opt| {
        if (el_opt) |el| {
            if (ie.parseCountry(el.body)) |c| {
                const first = c.tripletsSlice()[0].subband;
                country_ok = c.triplet_count == 13 and eql(&c.string, "US ") and first.first_channel == 36 and
                    first.max_tx_power_dbm == 17;
            } else |_| {}
        }
    } else |_| {}
    // Operating Triplet（首字节 ≥ 201）+ Padding；负的最大发送功率。
    if (ie.parseCountry(&vectors.country_us_operating)) |op| {
        country_ok = country_ok and op.triplet_count == 2 and op.tripletsSlice()[1].operating.operating_class == 81;
    } else |_| {
        country_ok = false;
    }
    if (ie.parseCountry(&vectors.country_fi_negative)) |fi| {
        country_ok = country_ok and fi.tripletsSlice()[1].subband.max_tx_power_dbm == -23;
    } else |_| {
        country_ok = false;
    }

    // 抓包 Beacon：固定字段、SSID、Supported Rates、TIM、RSNE。
    var fixed_ok = false;
    var rates_ok = false;
    var tim_ok = false;
    var rsne_ok = false;
    if (parseOk(&vectors.cap_beacon)) |f| {
        if (mgmt.parseBeacon(f.body)) |bb| {
            fixed_ok = bb.timestamp == 0x011bd4f189 and bb.beacon_interval == 100 and bb.capability.word() == 0x0411;
            if (findEl(bb.elements, .ssid)) |el| {
                if (ie.parseSsid(el.body)) |s| {
                    fixed_ok = fixed_ok and eql(s, "Coherer");
                } else |_| {}
            }
            if (findEl(bb.elements, .supported_rates)) |el| {
                if (ie.parseSupportedRates(el.body)) |itv| {
                    var it = itv;
                    var count: usize = 0;
                    var last = ie.Rate{ .value = 0, .basic = true };
                    while (it.next()) |r| {
                        count += 1;
                        last = r;
                    }
                    rates_ok = count == 8 and last.value == 108 and !last.basic;
                } else |_| {}
            }
            if (findEl(bb.elements, .tim)) |el| {
                if (ie.parseTim(el.body)) |t| {
                    tim_ok = t.isDtim() and t.dtim_period == 1 and !t.multicast_buffered and !t.bitSet(5);
                } else |_| {}
            }
            if (findEl(bb.elements, .rsn)) |el| {
                if (ie.parseRsne(el.body)) |r| {
                    rsne_ok = r.group_data_cipher.?.kind == 2 and r.pairwise_len == 2 and
                        r.akmSlice()[0].kind == 2 and !r.caps.mfpc;
                } else |_| {}
            }
        } else |_| {}
    }
    // 手工 TIM：Offset 5、位图 20 04 → AID 85 与 AID 90。
    if (ie.parseTim(vectors.tim_aid85_90[2..])) |t| {
        tim_ok = tim_ok and t.bitSet(85) and t.bitSet(90) and !t.bitSet(84) and !t.bitSet(0) and !t.bitSet(2008);
    } else |_| {
        tim_ok = false;
    }
    // DSSS Parameter Set（抓包 Probe Response）：Current Channel = 1。
    var dsss_ok = false;
    if (parseOk(&vectors.cap_probe_resp)) |pr| {
        if (findEl(pr.body[12..], .dsss_param_set)) |el| {
            if (ie.parseDsssChannel(el.body)) |ch| {
                dsss_ok = ch == 1;
            } else |_| {}
        }
    }
    check(country_ok and fixed_ok and rates_ok and tim_ok and rsne_ok and dsss_ok, "ie country={d} beacon_fixed={d} rates8={d} tim_aid85_90={d} rsn_tkip_ccmp_psk={d} dsss_ch1={d}", .{
        b(country_ok), b(fixed_ok), b(rates_ok), b(tim_ok), b(rsne_ok), b(dsss_ok),
    });
}

fn checkRsne() void {
    var out: [64]u8 = undefined;
    var ok = true;
    // 原文五个样例：解析之后由构造器逐字节复原。
    const samples = [_][]const u8{
        &vectors.rsne_8021x_ccmp,  &vectors.rsne_8021x_ccmp_preauth, &vectors.rsne_wep40_no_caps,
        &vectors.rsne_8021x_pmkid, &vectors.rsne_8021x_mfpc_bip,
    };
    for (samples) |s| {
        const r = ie.parseRsne(s[2..]) catch {
            ok = false;
            continue;
        };
        const n = ie.buildRsne(.{
            .group_data_cipher = r.group_data_cipher.?,
            .pairwise = r.pairwiseSlice(),
            .akms = r.akmSlice(),
            .caps = if (r.caps_present) r.caps else null,
            .pmkids = r.pmkidSlice(),
            .group_mgmt_cipher = r.group_mgmt_cipher,
        }, &out) catch {
            ok = false;
            continue;
        };
        ok = ok and n == s.len and eql(out[0..n], s);
    }
    const mfp = ie.parseRsne(vectors.rsne_8021x_mfpc_bip[2..]) catch null;
    const caps_ok = mfp != null and mfp.?.caps.mfpc and !mfp.?.caps.mfpr and mfp.?.group_mgmt_cipher.?.kind == 6;
    const pm = ie.parseRsne(vectors.rsne_8021x_pmkid[2..]) catch null;
    const pmkid_ok = pm != null and pm.?.pmkid_count == 1 and eql(&pm.?.pmkidSlice()[0], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    // 负例：Version 2；Pairwise Cipher Suite Count = 0；只有 Version 的最短形态合法。
    const neg_ok = (ie.parseRsne(&[_]u8{ 2, 0 }) catch null) == null and
        (ie.parseRsne(&[_]u8{ 1, 0, 0, 0x0f, 0xac, 4, 0, 0 }) catch null) == null and
        (ie.parseRsne(&[_]u8{ 1, 0 }) catch null) != null;
    check(ok and caps_ok and pmkid_ok and neg_ok, "rsne 5 samples rebuilt={d} mfpc_bip={d} pmkid={d} negative={d}", .{
        b(ok), b(caps_ok), b(pmkid_ok), b(neg_ok),
    });

    // Extended Capabilities（Table 9-135）。
    var ext_ok = false;
    if (findEl(&vectors.ext_cap_element, .ext_capabilities)) |el| {
        if (ie.parseExtCap(el.body)) |c| {
            ext_ok = c.bssTransition() and c.multipleBssid() and c.interworking() and c.utf8Ssid() and
                c.operatingModeNotification() and c.ftmResponder() and !c.ftmInitiator();
        } else |_| {}
    }
    const eleven: [11]u8 = @splat(0);
    const ext_neg = (ie.parseExtCap("") catch null) == null and (ie.parseExtCap(&eleven) catch null) == null;
    check(ext_ok and ext_neg, "ext_cap bits={d} negative={d}", .{ b(ext_ok), b(ext_neg) });
}

// ---------------------------------------------------------------------------
// ⑨ ⑩ 帧体与 robust 判定
// ---------------------------------------------------------------------------

fn checkBodies() void {
    var auth_ok = false;
    var assoc_ok = false;
    var dis_ok = false;
    if (parseOk(&vectors.cap_auth_1)) |f| {
        if (mgmt.parseAuthentication(f.body)) |a| {
            auth_ok = a.isOpenSystem() and a.transaction == 1 and a.status == 0;
        } else |_| {}
    }
    if (parseOk(&vectors.cap_auth_2)) |f| {
        if (mgmt.parseAuthentication(f.body)) |a| {
            auth_ok = auth_ok and a.transaction == 2 and a.status == 0 and std.mem.eql(u8, &f.hdr.addr1, &vectors.cap_sta);
        } else |_| {}
    }
    if (parseOk(&vectors.cap_assoc_resp)) |f| {
        if (mgmt.parseAssociationResponse(f.body)) |p| {
            assoc_ok = p.aid() == 1 and p.aid_raw == 0xc001 and p.success() and p.capability.word() == 0x0411;
        } else |_| {}
    }
    if (parseOk(&vectors.cap_disassoc)) |f| {
        if (mgmt.parseDisassociation(f.body)) |d| {
            dis_ok = eql(mgmt.reasonCodeName(d.reason_code) orelse "", "LEAVING_NETWORK_DISASSOC");
        } else |_| {}
    }
    // 负例：截断；成功却给了越界的 AID。
    const neg_ok = (mgmt.parseAuthentication(&[_]u8{ 0, 0, 1, 0 }) catch null) == null and
        (mgmt.parseAssociationResponse(&[_]u8{ 0x11, 0x04, 0, 0, 0xd8, 0x07 }) catch null) == null;
    check(auth_ok and assoc_ok and dis_ok and neg_ok, "bodies auth12={d} assoc_aid1={d} disassoc_r8={d} negative={d}", .{
        b(auth_ok), b(assoc_ok), b(dis_ok), b(neg_ok),
    });

    // robust：Deauthentication / Disassociation / SA Query 是；Public / Beacon 不是。
    const fc_action = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) };
    const sa_query = [_]u8{ 8, 0, 0x34, 0x12 };
    const public = [_]u8{ 4, 9 };
    var robust_ok = false;
    if (parseOk(&vectors.cap_disassoc)) |dis| {
        robust_ok = (robust.classify(dis.hdr.fc, dis.body, false) catch .not_robust) == .robust;
    }
    if (parseOk(&vectors.cap_beacon)) |bc| {
        robust_ok = robust_ok and (robust.classify(bc.hdr.fc, bc.body, false) catch .robust) == .not_robust;
    }
    robust_ok = robust_ok and (robust.classify(fc_action, &sa_query, false) catch .not_robust) == .robust;
    robust_ok = robust_ok and (robust.classify(fc_action, &public, false) catch .robust) == .not_robust;
    // Table 9-47：19 Robust AV Streaming 为 Yes；12 TDLS 不适用；NOTE 1 的 DMG 例外。
    const table_ok = robust.categoryVerdict(19, 0, false) == .robust and
        robust.categoryVerdict(12, 0, false) == .not_applicable and
        robust.categoryVerdict(5, 2, true) == .not_robust and robust.categoryVerdict(5, 2, false) == .robust;
    check(robust_ok and table_ok, "robust deauth_saquery={d} table9-47={d}", .{ b(robust_ok), b(table_ok) });
}

// ---------------------------------------------------------------------------
// ⑪ ⑫ ⑬ ⑭ MLME
// ---------------------------------------------------------------------------

fn checkMlmeAuthAssoc() void {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    m.seq_counter = 23; // 抓包第 78 帧的 Sequence Control = 70 01
    m.authenticate(vectors.cap_ap, 1024, 0) catch {};
    var copy: [128]u8 = undefined;
    var auth_frame_ok = false;
    if (m.takeTx()) |tx| {
        @memcpy(copy[0..tx.mpdu.len], tx.mpdu);
        auth_frame_ok = eql(copy[0..tx.mpdu.len], &vectors.cap_auth_1);
        _ = m.txResult(true);
    }
    const auth_ok = auth_frame_ok and deliver(&m, &vectors.cap_auth_2) == .consumed and
        m.stateOf(vectors.cap_ap) == .state2;
    _ = m.poll(); // 取走 authenticate_confirm

    // 关联请求 = 抓包第 82 帧的帧头 + Table 9-29 顺序的帧体；AP 的响应 = 抓包第 84 帧。
    m.associate(assocRequest(vectors.cap_ap), 0) catch {};
    var assoc_frame_ok = false;
    if (m.takeTx()) |tx| {
        @memcpy(copy[0..tx.mpdu.len], tx.mpdu);
        assoc_frame_ok = eql(copy[0..tx.mpdu.len], &vectors.assoc_req_table_9_29);
        _ = m.txResult(true);
    }
    const consumed = deliver(&m, &vectors.cap_assoc_resp) == .consumed;
    const state4 = m.stateOf(vectors.cap_ap) == .state4 and m.aidOf(vectors.cap_ap) == 1;
    const confirmed = if (m.poll()) |ev| ev.associate_confirm.result == .success and ev.associate_confirm.aid == 1 else false;
    check(auth_ok, "mlme auth frame78={d} state2_after_frame80={d}", .{ b(auth_frame_ok), b(auth_ok) });
    check(assoc_frame_ok and consumed and state4 and confirmed, "mlme assoc frame_table_9_29={d} state4_aid1={d} confirm={d}", .{
        b(assoc_frame_ok), b(state4 and consumed), b(confirmed),
    });

    // 有 RSNA：关联成功停在 State 3；MLME-SETPROTECTION.request(Rx_Tx) 之后才进 State 4。
    var r = mlme.Machine.init(vectors.cap_sta, .{ .rsna_activated = true });
    var ap2 = PeerAp{ .address = vectors.cap_ap };
    var state3 = false;
    var protected_now = false;
    if (authRound(&r, &ap2)) {
        r.associate(assocRequest(vectors.cap_ap), 0) catch {};
        _ = ackPending(&r);
        if (deliver(&r, ap2.assocResp(vectors.cap_sta, 0, 7)) == .consumed) {
            state3 = r.stateOf(vectors.cap_ap) == .state3 and r.aidOf(vectors.cap_ap) == 7;
            protected_now = r.setProtection(vectors.cap_ap) and r.stateOf(vectors.cap_ap) == .state4;
        }
    }
    check(state3 and protected_now, "mlme rsna state3_aid7={d} set_protection_state4={d}", .{ b(state3), b(protected_now) });
}

fn checkMlmeRelease() void {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    var ap = PeerAp{ .address = vectors.cap_ap };
    const reached = associated(&m, &ap);

    // AP 的 Disassociation：State 2 + indication（Reason 8）。
    var db: [2]u8 = undefined;
    const dn = mgmt.buildDisassociation(8, &db) catch 0;
    const dis = deliver(&m, ap.mpdu(.disassoc, vectors.cap_sta, db[0..dn])) == .consumed and
        m.stateOf(vectors.cap_ap) == .state2;
    const dis_ind = if (m.poll()) |ev| ev.disassociate_indication.reason_code == 8 else false;

    // AP 的 Deauthentication：State 1 + indication（Reason 2）。
    const reauthed = authRound(&m, &ap);
    var xb: [2]u8 = undefined;
    const xn = mgmt.buildDeauthentication(2, &xb) catch 0;
    const dea = deliver(&m, ap.mpdu(.deauth, vectors.cap_sta, xb[0..xn])) == .consumed and
        m.stateOf(vectors.cap_ap) == .state1;
    const dea_ind = if (m.poll()) |ev| ev.deauthenticate_indication.reason_code == 2 else false;

    // 认证超时：状态不变，AUTH_FAILURE_TIMEOUT；到点前没有指示。
    m.authenticate(vectors.cap_ap, 1024, 100) catch {};
    _ = ackPending(&m);
    m.tick(1123);
    const before = m.poll() == null;
    m.tick(1124);
    const timed_out = if (m.poll()) |ev| ev.authenticate_confirm.result == .auth_failure_timeout else false;
    const state1 = m.stateOf(vectors.cap_ap) == .state1;

    // 类违规：State 1 收到 Association Request → 丢弃并回 Deauthentication（Reason 6）。
    var vb: [64]u8 = undefined;
    const vn = mgmt.buildAssociationRequest(.{ .listen_interval = 1, .ssid = "x", .rates = &basic_rates }, &vb) catch 0;
    const violation = deliver(&m, ap.mpdu(.assoc_req, vectors.cap_sta, vb[0..vn])) == .discarded_by_state;
    var reason_ok = false;
    var copy: [128]u8 = undefined;
    if (m.takeTx()) |tx| {
        const len = tx.mpdu.len;
        @memcpy(copy[0..len], tx.mpdu);
        _ = m.txResult(true);
        if (parseOk(copy[0..len])) |f| {
            if (mgmt.parseDeauthentication(f.body)) |d| {
                reason_ok = f.hdr.fc.isMgmt(.deauth) and d.reason_code == 6 and
                    std.mem.eql(u8, &f.hdr.addr1, &vectors.cap_ap);
            } else |_| {}
        }
    }
    check(reached and reauthed and dis and dis_ind and dea and dea_ind and before and timed_out and state1 and violation and reason_ok, "mlme assoc4={d} disassoc_r8={d} deauth_r2={d} timeout={d} violation_deauth_r6={d}", .{
        b(reached), b(dis and dis_ind), b(dea and dea_ind), b(before and timed_out and state1), b(violation and reason_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑮ ⑯ 扫描
// ---------------------------------------------------------------------------

fn checkScan() void {
    const channels = [_]u8{ 1, 6, 11 };
    var steps: [scan.max_steps]scan.Step = undefined;
    const n = scan.plan(.{ .channel_list = &channels, .probe_delay_us = 250, .min_channel_time_tu = 20, .max_channel_time_tu = 38 }, &steps) catch 0;
    var plan_ok = n == 12;
    for (channels, 0..) |ch, i| {
        const base = i * 4;
        plan_ok = plan_ok and steps[base].kind == .probe_delay and steps[base].duration == 250 and steps[base].channel == ch;
        plan_ok = plan_ok and steps[base + 1].kind == .probe_request and steps[base + 2].kind == .dwell_min and
            steps[base + 2].duration == 20;
        plan_ok = plan_ok and steps[base + 3].kind == .dwell_to_max and steps[base + 3].duration == 18 and
            steps[base + 3].conditional;
    }
    const passive_n = scan.plan(.{ .scan_type = .passive, .channel_list = &channels, .max_channel_time_tu = 100 }, &steps) catch 0;
    plan_ok = plan_ok and passive_n == 3 and steps[0].kind == .listen and steps[0].duration == 100;
    var rejected = false;
    if (scan.plan(.{ .channel_list = &.{} }, &steps)) |_| {} else |e| rejected = e == error.EmptyChannelList;
    if (scan.plan(.{ .channel_list = &channels, .max_channel_time_tu = 0 }, &steps)) |_| {
        rejected = false;
    } else |e| rejected = rejected and e == error.BadChannelTime;
    check(plan_ok and rejected, "scan active_steps={d} passive={d} rejected={d}", .{
        b(plan_ok), b(passive_n == 3), b(rejected),
    });

    const pr_rates = [_]ie.Rate{
        .{ .value = 2, .basic = false },  .{ .value = 4, .basic = false },
        .{ .value = 11, .basic = false }, .{ .value = 22, .basic = false },
        .{ .value = 36, .basic = false }, .{ .value = 48, .basic = false },
        .{ .value = 72, .basic = false }, .{ .value = 108, .basic = false },
    };
    const one = [_]u8{1};
    var out: [128]u8 = undefined;
    const pn = scan.buildProbeRequestMpdu(.{ .ssid = "Coherer", .channel_list = &one }, vectors.cap_sta, 0x0010, &pr_rates, &ext_rates, &out) catch 0;
    const probe_ok = pn == vectors.cap_probe_req.len and eql(out[0..pn], &vectors.cap_probe_req);

    var table = scan.BssTable.init();
    var added = false;
    var merged = false;
    var fields_ok = false;
    if (parseOk(&vectors.cap_beacon)) |bc| {
        added = table.update(bc, .{ .rssi = -48, .channel = 1, .now_tu = 5 }) catch false;
        // Beacon 自带的字段：TSF、DTIM Period、12 个速率、RSNE 摘要。
        if (table.find(vectors.cap_ap)) |e| {
            fields_ok = e.tsf == 0x011bd4f189 and e.rssi == -48 and e.dtim_period == 1 and e.rates_len == 12 and
                eql(e.ssidSlice(), "Coherer") and e.rsn != null and e.rsn.?.pairwise_len == 2 and
                e.rsn.?.akmSlice()[0].kind == 2;
        }
    }
    // Probe Response 没有 TIM：刷新后以它为准（TSF、RSSI、看到次数）。
    if (parseOk(&vectors.cap_probe_resp)) |pr| merged = !(table.update(pr, .{ .rssi = -52, .channel = 1, .now_tu = 9 }) catch true);
    if (table.find(vectors.cap_ap)) |e| {
        fields_ok = fields_ok and table.count() == 1 and e.seen_count == 2 and e.tsf == 0x011c23ff61 and
            e.channel == 1 and e.rssi == -52 and e.rates_len == 12;
    }
    check(probe_ok and added and merged and fields_ok, "scan probe_frame58={d} bss_added={d} merged={d} fields={d}", .{
        b(probe_ok), b(added), b(merged), b(fields_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑰ QoS Control（9.2.4.5，p.647–653；Table 9-6，p.648）
// ---------------------------------------------------------------------------

fn checkQosControl() void {
    // 七行布局各取一个字：拆开再拼回去。
    const Case = struct { layout: qos.Layout, word: u16 };
    const cases = [_]Case{
        .{ .layout = .hc_cf_poll, .word = 0x0a47 },
        .{ .layout = .hc_data_cf_poll, .word = 0xffd3 },
        .{ .layout = .hc_data, .word = 0xeef5 },
        .{ .layout = .hc_null, .word = 0x0216 },
        .{ .layout = .sta_data, .word = 0x0011 },
        .{ .layout = .sta_null, .word = 0x0000 },
        .{ .layout = .mesh, .word = 0x067f },
    };
    var ok = true;
    for (cases) |c| {
        const f = qos.decode(c.layout, c.word) catch {
            ok = false;
            continue;
        };
        ok = ok and (qos.encode(c.layout, f) catch 0) == c.word;
    }
    if (qos.decode(.hc_data, 0xeef5)) |hc| {
        ok = ok and hc.tid == 5 and (hc.eosp orelse false) and hc.ack_policy == .block_ack and (hc.a_msdU_present orelse false);
        ok = ok and hc.tail.ap_ps_buffer_state.highest_priority_ac == 3 and hc.tail.ap_ps_buffer_state.buffered_load == 14;
    } else |_| {
        ok = false;
    }
    // Table 9-6 标 Reserved 的位不为 0。
    const neg_ok = decodeFails(.hc_cf_poll, 0x0080) and decodeFails(.sta_null, 0x0080) and
        decodeFails(.hc_data, 0x0100) and decodeFails(.hc_null, 0x0400) and decodeFails(.mesh, 0x0800);
    // 发送方由 To DS / From DS 推断，布局由发送方与子类型决定；管理帧不是 QoS 帧。
    const fc: frame.FrameControl = .{ .type = .data, .subtype = 8, .from_ds = true };
    const layout_ok = (qos.layoutFor(fc, .hc) catch .mesh) == .hc_data and
        (qos.layoutFor(.{ .type = .data, .subtype = 12 }, .non_ap_sta) catch .mesh) == .sta_null and
        (qos.senderOf(fc) catch .mesh) == .hc and
        (qos.senderOf(.{ .type = .data, .to_ds = true }) catch .mesh) == .non_ap_sta and
        isErr(qos.layoutFor(.{ .type = .mgmt, .subtype = 8 }, .hc)) and
        isErr(qos.layoutFor(.{ .type = .data, .subtype = 13 }, .hc));
    check(ok and neg_ok and layout_ok, "qos_ctrl 7rows={d} reserved_rej={d} layout={d}", .{ b(ok), b(neg_ok), b(layout_ok) });
}

// ---------------------------------------------------------------------------
// ⑱ QoS 数据帧
// ---------------------------------------------------------------------------

fn checkQosFrames() void {
    // 抓包：http_PPI.cap 第 1、3 帧（TID 0，帧尾带 FCS）；wpa-eap-tls.pcap 第 1、2 帧（TID 7，重传）。
    var cap_ok = false;
    var retry_ok = false;
    if (qos.parse(&vectors.ppi_qos_data_to_ap, .checked)) |up| {
        if (qos.parse(&vectors.ppi_qos_data_from_ap, .checked)) |down| {
            cap_ok = up.layout == .sta_data and down.layout == .hc_data and up.qos.tid == 0 and down.qos.tid == 0;
            cap_ok = cap_ok and (up.ac orelse .vo) == .be and up.frame.header.len == 26;
            cap_ok = cap_ok and std.mem.eql(u8, up.frame.body[0..8], &[_]u8{ 0xaa, 0xaa, 0x03, 0, 0, 0, 0x08, 0x00 });
        } else |_| {}
    } else |_| {}
    if (qos.parse(&vectors.eaptls_qos_from_ap, .none)) |eap| {
        if (qos.parse(&vectors.eaptls_qos_from_ap_retry, .none)) |r| {
            retry_ok = eap.qos.tid == 7 and (eap.ac orelse .be) == .vo and r.frame.hdr.fc.retry and
                eql(eap.frame.body, r.frame.body);
        } else |_| {}
    } else |_| {}
    // 构造：3 地址（STA→AP，TID 5、Queue Size=1）与 4 地址 mesh 帧，解析回来一致。
    const body = [_]u8{ 6, 5, 4, 3 };
    var three = false;
    if (qos.seal(.{ .sender = .non_ap_sta, .subtype = 8, .addr1 = vectors.cap_ap, .addr2 = vectors.cap_sta, .addr3 = vectors.cap_ap, .qos = (qos.staFields(5, .normal_ack, false, .{ .queue_size = 1 }) catch qos.Fields{}), .body = &body }, true, &g_scratch)) |n| {
        if (qos.parse(g_scratch[0..n], .checked)) |back| {
            three = n == 34 and back.qos.tid == 5 and back.qos.tail.queue_size == 1 and eql(back.frame.body, &body);
        } else |_| {}
    } else |_| {}
    var four = false;
    if (qos.seal(.{ .sender = .mesh, .subtype = 8, .addr1 = vectors.cap_sta, .addr2 = vectors.cap_ap, .addr3 = vectors.cap_sta, .addr4 = vectors.cap_ap, .qos = .{ .tid = 0, .eosp = false, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .mesh = .{ .control_present = true } } }, .body = &body }, true, &g_scratch)) |n| {
        if (qos.parse(g_scratch[0..n], .checked)) |back| {
            four = n == 40 and back.frame.header.len == 32 and back.qos.tail.mesh.control_present;
        } else |_| {}
    } else |_| {}
    // 负例：管理帧带 QoS Control、管理帧交给 qos.parse、QoS Control 被截断、非法 TID。
    const bad = frame.Header{ .fc = .{ .type = .mgmt, .subtype = 8 }, .addr1 = vectors.cap_ap, .addr2 = vectors.cap_sta, .addr3 = vectors.cap_ap, .seq_ctrl = 0, .qos = .{} };
    const neg_ok = isErr(bad.validate()) and isErr(qos.parse(&vectors.cap_beacon, .checked)) and
        isErr(qos.parse(vectors.eaptls_qos_from_ap[0..25], .none)) and
        isErr(qos.staFields(16, .normal_ack, false, .{ .txop_duration_requested = 0 }));
    check(cap_ok and retry_ok and three and four and neg_ok, "qos_frame capture={d} retry={d} 3addr={d} 4addr={d} neg={d}", .{ b(cap_ok), b(retry_ok), b(three), b(four), b(neg_ok) });
}

// ---------------------------------------------------------------------------
// ⑲ UP / TID / AC、默认 EDCA 参数、QoS Info
// ---------------------------------------------------------------------------

fn checkQosEdca() void {
    // Table 10-1（p.1298）；TID 8–15 是 TSID，不属于任何 AC。
    const want = [8]qos.Ac{ .be, .bk, .bk, .be, .vi, .vi, .vo, .vo };
    var map_ok = true;
    for (want, 0..) |ac, up| {
        map_ok = map_ok and qos.acForUp(@intCast(up)) == ac and (qos.acForTid(@intCast(up)) orelse .vo) == ac;
    }
    map_ok = map_ok and (qos.acForTid(8) == null) and (qos.acForTid(15) == null) and
        isErr(qos.edcaTid(8)) and isErr(qos.edcaTid(16));
    // Table 9-137（p.899）：aCWmin = 15 的那一族（OFDM / HT）与 aCWmin = 31 的那一族（DSSS）。
    const p = qos.defaultAcParams(.clause_17_18_19_21, qos.ofdm_cw);
    const d = qos.defaultAcParams(.clause_15_16, qos.dsss_cw);
    const edca_ok = p[0].aifsn == 3 and p[1].aifsn == 7 and p[2].aifsn == 2 and p[3].aifsn == 2 and
        p[0].cwmin == 15 and p[2].cwmin == 7 and p[3].cwmin == 3 and p[2].cwmax == 15 and p[3].cwmax == 7 and
        p[0].txop_limit == 79 and p[2].txop_limit == 128 and p[3].txop_limit == 65 and
        d[0].cwmin == 31 and d[2].cwmin == 15 and d[2].txop_limit == 188 and
        p[0].aifsUs(9, 16) == 43 and p[1].aifsUs(9, 16) == 79;
    // Figure 9-83、Table 9-48（p.740）：U-APSD Flag、Q-Ack、Max SP Length；元素 `2e 01 <QoS Info>`。
    var info = qos.QosInfoSta{ .uapsd_be = true, .max_sp_length = .four };
    info.q_ack = true;
    var info_ok = info.octet() == 0x58 and info.uapsdEnabled(.be) and !info.uapsdEnabled(.vo);
    info.uapsd_bk = true;
    info.uapsd_vi = true;
    info.uapsd_vo = true;
    info_ok = info_ok and info.allDeliveryEnabled() and info.acMask() == 0xf and
        (qos.MaxSpLength.two.limit() orelse 0) == 2;
    if (qos.buildQosCapability(.{ .uapsd_be = true, .max_sp_length = .four }, true, g_scratch[0..8])) |n| {
        info_ok = info_ok and n == 3 and g_scratch[0] == 46 and g_scratch[1] == 1 and g_scratch[2] == 0x48;
    } else |_| {
        info_ok = false;
    }
    info_ok = info_ok and isErr(qos.buildQosCapability(.{ .uapsd_be = true }, false, g_scratch[0..8]));
    check(map_ok and edca_ok and info_ok, "qos_edca up_ac={d} table9-137={d} qos_info={d}", .{ b(map_ok), b(edca_ok), b(info_ok) });
}

// ---------------------------------------------------------------------------
// ⑳ TIM / DTIM
// ---------------------------------------------------------------------------

fn checkTim() void {
    var bm = powersave.VirtualBitmap{};
    // AID 4 的 TIM 与抓包（Network_Join_Nokia_Mobile.pcap 第 1062 帧）逐字节相同；
    // AID 85、90 与原有手工向量相同。
    bm.set(4) catch {};
    var n = powersave.encodeTim(&bm, 0, 1, false, &g_scratch) catch 0;
    var ok = false;
    if (std.mem.indexOf(u8, &vectors.nokia_beacon_aid4, g_scratch[0..n]) != null) ok = true;
    bm.clearAll();
    bm.set(85) catch {};
    bm.set(90) catch {};
    n = powersave.encodeTim(&bm, 3, 4, false, &g_scratch) catch 0;
    ok = ok and n == 7 and eql(g_scratch[0..n], &vectors.tim_aid85_90);
    // Bitmap Offset：AID 20 → N1 = 2、Offset 1、位图 10。
    bm.clearAll();
    bm.set(20) catch {};
    n = powersave.encodeTim(&bm, 0, 1, false, &g_scratch) catch 0;
    ok = ok and n == 6 and g_scratch[4] == 0x02 and g_scratch[5] == 0x10;
    // 位序：AID 8、15 在第 1 字节，AID 2007 在第 250 字节 bit 7。
    bm.clearAll();
    bm.set(8) catch {};
    bm.set(15) catch {};
    bm.set(2007) catch {};
    const bits_ok = bm.octets[1] == 0x81 and bm.octets[250] == 0x80 and bm.isSet(2007) and !bm.isSet(2008);
    n = powersave.encodeTim(&bm, 0, 1, false, &g_scratch) catch 0;
    ok = ok and n == 256 and g_scratch[4] == 0x00 and g_scratch[255] == 0x80;
    // 组播位：只有组播缓存时是 `05 04 00 01 01 00`，与抓包的 DTIM 相同；Bitmap Offset 越界被拒。
    bm.clearAll();
    n = powersave.encodeTim(&bm, 0, 1, true, &g_scratch) catch 0;
    var mc_ok = n == 6 and eql(g_scratch[0..n], &vectors.tim_multicast);
    if (std.mem.indexOf(u8, &vectors.cap_dtim_multicast, g_scratch[0..n]) == null) mc_ok = false;
    const over = [_]u8{ 0, 1, 0xfc, 0 };
    mc_ok = mc_ok and isErr(ie.parseTim(&over)) and powersave.dtimCount(1, 3) == 2 and
        powersave.dtimCount(2, 3) == 1 and powersave.dtimCount(3, 3) == 0;
    // 解码：抓包 Beacon 的 TIM 里 AID 4 有缓冲、AID 5 没有。
    var dec_ok = false;
    if (beaconTim(&vectors.nokia_beacon_aid4)) |t| {
        if (ie.parseTim(t)) |tim| dec_ok = tim.isDtim() and tim.bitSet(4) and !tim.bitSet(5) else |_| {}
    }
    check(ok and bits_ok and mc_ok and dec_ok, "tim aid4_85_90={d} bits={d} mcast_offset={d} decode={d}", .{ b(ok), b(bits_ok), b(mc_ok), b(dec_ok) });
}

// ---------------------------------------------------------------------------
// ㉑ PS-Poll
// ---------------------------------------------------------------------------

fn checkPsPoll() void {
    // 9.3.1.5（p.671）：FC = a4 00，ID = c0 04（AID 4 加上高 2 位），BSSID(RA)，TA，FCS。
    const n = powersave.buildPsPollFrame(4, vectors.cap_ap, vectors.cap_sta, g_scratch[0..20]) catch 0;
    var ok = n == 20 and g_scratch[0] == 0xa4 and g_scratch[1] == 0x00 and g_scratch[2] == 0x04 and g_scratch[3] == 0xc0;
    ok = ok and eql(g_scratch[4..10], &vectors.cap_ap) and eql(g_scratch[10..16], &vectors.cap_sta);
    if (powersave.parsePsPoll(g_scratch[0..20], .checked)) |p| ok = ok and p.aid == 4 else |_| ok = false;
    // 负例：长度不对、AID 非法、不是 PS-Poll。
    const neg_ok = isErr(powersave.parsePsPoll(g_scratch[0..15], .none)) and
        isErr(powersave.parsePsPoll(g_scratch[0..17], .none)) and isErr(powersave.parsePsPoll(g_scratch[0..19], .present)) and
        isErr(powersave.buildPsPollFrame(0, vectors.cap_ap, vectors.cap_sta, g_scratch[0..20])) and
        isErr(powersave.buildPsPollFrame(2008, vectors.cap_ap, vectors.cap_sta, g_scratch[0..20])) and
        isErr(powersave.parsePsPoll(&vectors.rts_header, .none));
    // 抓包：STA 发给 AP 的 Null 帧 PM=1（#1040）、PM=0（#1063）。
    var pm_ok = false;
    if (frame.parse(&vectors.nokia_null_pm1, .none)) |f| {
        if (frame.parse(&vectors.nokia_null_pm0, .none)) |g| {
            pm_ok = f.hdr.fc.power_management and !g.hdr.fc.power_management;
        } else |_| {}
    } else |_| {}
    check(ok and neg_ok and pm_ok, "ps_poll frame={d} neg={d} null_pm_capture={d}", .{ b(ok), b(neg_ok), b(pm_ok) });
}

// ---------------------------------------------------------------------------
// ㉒ U-APSD
// ---------------------------------------------------------------------------

fn checkUapsd() void {
    // STA 侧：四个 AC 都 delivery-enabled，TIM 位置 1 → trigger 帧；服务期到 EOSP=1。
    var s = powersave.Sta.init(vectors.cap_sta, vectors.cap_ap, .{ .qos_info = .{ .uapsd_be = true, .uapsd_bk = true, .uapsd_vi = true, .uapsd_vo = true } });
    var ok = false;
    if (s.associated(4, 1)) |_| {
        if (s.request(.power_save, true)) |_| {
            _ = s.exchangeResult(.frame_to_ap, true, true);
            const ev = s.onBeacon(beaconTim(&vectors.nokia_beacon_aid4), 0);
            s.triggerSent() catch {};
            _ = s.onUnicastFromAp(.{ .more_data = true, .ac = .be, .eosp = false });
            const mid = s.in_service_period;
            const a = s.onUnicastFromAp(.{ .more_data = false, .ac = .vo, .eosp = true });
            ok = ev.trigger and !ev.poll and mid and a.sp_ended and !s.in_service_period;
        } else |_| {}
    } else |_| {}
    // AP 侧：Max SP Length = 2、缓存 3 个：两帧后 EOSP=1，第三个留给下一个服务期。
    var m = powersave.Ap.init();
    var ap_ok = false;
    if (m.associate(4, .{ .uapsd_be = true, .uapsd_vo = true, .max_sp_length = .two })) |_| {
        m.setPowerManagement(4, true) catch {};
        for ([_]qos.Ac{ .be, .be, .vo }) |ac| _ = m.enqueueUnicast(4, ac) catch false;
        if (m.onTrigger(4, .vo) == .started) {
            var d = m.nextDelivery();
            const first = d == .unicast and d.unicast.ac == .vo and !d.unicast.eosp;
            m.txResult(.sent);
            d = m.nextDelivery();
            const second = d == .unicast and d.unicast.eosp;
            m.txResult(.sent);
            ap_ok = first and second and m.nextDelivery() == .none and m.onTrigger(4, .be) == .started;
        }
    } else |_| {}
    check(ok and ap_ok, "uapsd sta_trigger_sp={d} ap_sp_len2={d}", .{ b(ok), b(ap_ok) });
}

// ---------------------------------------------------------------------------
// ㉓ STA 模型与 AP 模型对接
// ---------------------------------------------------------------------------

fn checkPsInterop() void {
    var a = powersave.Ap.init();
    var s = powersave.Sta.init(vectors.cap_sta, vectors.cap_ap, .{});
    var ok = false;
    if (a.associate(4, null)) |_| {
        if (s.associated(4, 1)) |_| {
            _ = s.request(.power_save, true) catch {};
            ok = s.exchangeResult(.frame_to_ap, true, true) == .confirmed;
            a.setPowerManagement(4, true) catch {};
            ok = ok and (a.enqueueUnicast(4, .be) catch false) and (a.enqueueUnicast(4, .vo) catch false);
            const n = a.buildTim(0, 1, &g_scratch) catch 0;
            ok = ok and s.onBeacon(g_scratch[2..n], 0).poll;
            const m = s.buildPsPoll(g_scratch[200..220]) catch 0;
            if (powersave.parsePsPoll(g_scratch[200..220], .checked)) |p| {
                ok = ok and m == 20 and p.aid == 4 and a.onPsPoll(p.aid) == .deliver;
            } else |_| {
                ok = false;
            }
            var d = a.nextDelivery();
            ok = ok and d == .unicast and d.unicast.more_data;
            ok = ok and s.onUnicastFromAp(.{ .more_data = true }).poll;
            a.txResult(.sent);
            ok = ok and a.onPsPoll(4) == .deliver;
            d = a.nextDelivery();
            ok = ok and d == .unicast and !d.unicast.more_data;
            a.txResult(.sent);
            _ = s.onUnicastFromAp(.{ .more_data = false });
            ok = ok and s.powerStateAt(1) == .doze;
            // DTIM 的组播位让 STA 保持清醒；组播 More Data=1、0 发完才释放。
            ok = ok and a.enqueueMulticast() and a.enqueueMulticast();
            const t = a.buildTim(0, 1, &g_scratch) catch 0;
            ok = ok and s.onBeacon(g_scratch[2..t], 100).multicast and s.powerStateAt(101) == .awake;
            d = a.nextDelivery();
            const m1 = d == .multicast and d.multicast.more_data;
            a.txResult(.sent);
            d = a.nextDelivery();
            const m2 = d == .multicast and !d.multicast.more_data;
            a.txResult(.sent);
            ok = ok and m1 and m2;
            // 回到 active 模式（抓包 #1063 的 PM=0）：AP 不等 PS-Poll 直接补发缓冲的 BU。
            ok = ok and (a.enqueueUnicast(4, .be) catch false);
            _ = s.request(.active, true) catch {};
            ok = ok and s.exchangeResult(.frame_to_ap, false, true) == .confirmed;
            a.setPowerManagement(4, false) catch {};
            d = a.nextDelivery();
            ok = ok and d == .unicast and d.unicast.aid == 4;
        } else |_| {}
    } else |_| {}
    check(ok, "ps_interop poll_bu={d}", .{b(ok)});
}

// ---------------------------------------------------------------------------
// ㉔ More Data 与监听间隔
// ---------------------------------------------------------------------------

fn checkMoreData() void {
    // 9.2.4.1.8（p.643）：More Data 的含义随发送方与寻址变化；抓包里 DTIM 之后的组播帧 More Data=1 / 0。
    const more = parseOk(&vectors.cap_multicast_more_data);
    const last = parseOk(&vectors.cap_multicast_after_dtim);
    var ok = powersave.moreDataMeaning(.ap, true) == .ap_group and
        powersave.moreDataMeaning(.ap, false) == .ap_unicast and
        powersave.moreDataMeaning(.non_ap_sta, true) == .must_be_zero and
        !powersave.moreDataValid(.non_ap_sta, false, true);
    if (more) |m| {
        if (last) |l| ok = ok and m.hdr.fc.more_data and !l.hdr.fc.more_data;
    }
    // 11.2.3.8（p.1612）：More Data 提示等同 TIM 位置 1；没声明 More Data Ack 时 Ack 的 More Data 不算。
    var s = powersave.Sta.init(vectors.cap_sta, vectors.cap_ap, .{});
    var hint_ok = false;
    if (s.associated(4, 10)) |_| {
        if (s.request(.power_save, true)) |_| {
            _ = s.exchangeResult(.frame_to_ap, true, true);
            s.onAckFromAp(true);
            const ignored = !s.holds.unicast;
            s.onMoreDataHint();
            hint_ok = ignored and s.holds.unicast and s.retrieval() == .ps_poll;
        } else |_| {}
    } else |_| {}
    // 11.2.3.8 a)（p.1611）：Listen Interval 10、不收 DTIM → 下一个必须收的 Beacon 在 10 个间隔之后。
    var t = powersave.Sta.init(vectors.cap_sta, vectors.cap_ap, .{});
    var wake_ok = false;
    if (t.associated(1, 10)) |_| {
        if (t.request(.power_save, false)) |_| {
            _ = t.exchangeResult(.frame_to_ap, true, true);
            if (beaconTim(&vectors.cap_beacon)) |tim| {
                _ = t.onBeacon(tim, 0);
                const w = t.nextWake(0);
                if (w == .future) wake_ok = w.future.index == 10 and w.future.at_tu == 1000 else wake_ok = false;
                wake_ok = wake_ok and t.powerStateAt(999) == .doze and t.powerStateAt(1000) == .awake;
            }
        } else |_| {}
    } else |_| {}
    check(ok and hint_ok and wake_ok, "ps_moredatu meaning={d} hint={d} listen_int={d}", .{ b(ok), b(hint_ok), b(wake_ok) });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 无线测量与 WNM 的判据在自己的文件里，经这个回调记到同一本账上。
fn extCheck(ok: bool, text: []const u8) void {
    check(ok, "{s}", .{text});
}

fn runChecks() bool {
    checkFcs();
    checkFcsReference();
    checkHeader();
    checkAnnexJ();
    checkElements();
    checkRsne();
    checkBodies();
    checkMlmeAuthAssoc();
    checkMlmeRelease();
    checkScan();
    checkQosControl();
    checkQosFrames();
    checkQosEdca();
    checkTim();
    checkPsPoll();
    checkUapsd();
    checkPsInterop();
    checkMoreData();
    rrm_wnm_selftest.run(extCheck);
    wnm_tfs_selftest.run(extCheck);
    rrm_caps_selftest.run(extCheck);
    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    // 非判据读数：结构大小与计时 / 重传参数的默认值。
    log.line("read: sizes header={d} frame={d} bss={d} tx_buf={d} peers={d}", .{
        @sizeOf(frame.Header), @sizeOf(frame.Frame), @sizeOf(scan.Bss), mlme.tx_buf_len, mlme.max_peers,
    });
    log.line("read: timers auth_timeout_tu={d} assoc_timeout_tu={d} short_retry={d} long_retry={d}", .{
        mlme.default_authenticate_failure_timeout_tu, mlme.default_association_response_timeout_tu,
        mlme.default_dot11_short_retry_limit,         mlme.default_dot11_long_retry_limit,
    });
    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
