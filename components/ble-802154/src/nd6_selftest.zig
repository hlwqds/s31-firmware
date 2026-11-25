//! nd6：6LoWPAN 邻居发现（RFC 6775 第 5 章）的板侧自检（第四批）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字每行 ≤ 180 字节（板侧 `board.log` 超 200 截断）。
//! 判据与主机测试 `nd6_tests.zig` 用同一批期望值（RFC 6775/4861 手排 KAT，gen_kats.py
//! 排出）；板侧只算固定输入。大缓冲（Host、报文缓冲）放文件作用域：板侧栈只有 16 KiB。
//! 每个判据函数加 `noinline`（ReleaseSmall 会把内联函数的大数组叠进同一个栈帧）。
//!
//! 判据（全部是字节操作与 u64 比较，无椭圆曲线 / 大表，指令预算见文件尾注释）：
//!   ① ARO 编码 KAT 与解码往返（RFC 6775 §4.1 行 874-881）
//!   ② ARO 负例：Length≠2 → error（§4.1 行 860-862；§5.5.2 行 1393-1395）
//!   ③ 6CO 编码 KAT 与解码往返（§4.2 图 1 行 937-949）+ 负例（行 968-969）
//!   ④ ABRO 编码 KAT、Version Low/High 拆装（§4.3 行 1032-1041）
//!   ⑤ RS 编码 KAT（RFC 4861 §4.1 + RFC 6775 §5.3；校验和在帧内）
//!   ⑥ 注册 NS KAT（RFC 6775 图 5 行 2495-2499）+ parseNs 回读
//!   ⑦ RA KAT → processRa 落表（路由器 / 上下文 / ABRO），坏校验和拒收
//!   ⑧ 上下文生命周期：valid → receive-only → free（时间注入，§5.4.3 行 1329-1332）
//!   ⑨ syncContexts 写进 fifteen4.iphc.Contexts（公开 API，state/match 验证）
//!   ⑩ 注册流程：register → tick 出 NS 动作；NA Status=0 → registered；Status=2 摘路由器
//!   ⑪ 下一跳分类（§5.6 行 1440-1459）+ 短地址 / EUI-64 的 IID 反推（§5.7）
//!   ⑫ 注册寿命选取（§5.8.1 行 1496-1500）与醒来刷新（§5.8.2 行 1528-1530）

const std = @import("std");
const nd6 = @import("nd6.zig");
const f15 = @import("fifteen4.zig");

fn hx(comptime n: usize, s: []const u8) [n]u8 {
    @setEvalBranchQuota(100_000);
    var out: [n]u8 = @splat(0);
    for (out[0 .. s.len / 2], 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }
    return out;
}

// ---- 夹具与 KAT（与 nd6_tests.zig 同源：gen_kats.py 手排） ----

const host_eui = hx(8, "0200000000000001");
const host_gp16 = hx(16, "20010db8000000000000fffe0000aaaa");
const router_ll = hx(16, "fe800000000000000000000000000002");
const host_ll = hx(16, "fe800000000000000000000000000001");
const prefix64 = hx(16, "20010db8000000000000000000000000");
const lbr_addr = hx(16, "20010db8000000000000000000000001");
const all_routers = hx(16, "ff020000000000000000000000000002");

const kat_aro_ok = hx(16, "21020000000000640200000000000001");
const kat_co64 = hx(16, "220240110000006420010DB800000000");
const kat_abro = hx(24, "2303000500010000" ++ "20010DB8000000000000000000000001");
const kat_rs_frame = hx(24, "85007A230000000001020200000000000001000000000000");
const kat_reg_ns = hx(48, "8700D41900000000" ++ "FE800000000000000000000000000002" ++
    "21020000000000640200000000000001" ++ "0101AAAA00000000");
const kat_ra_frame = hx(104, "8600DD814000070800007530000003E8" ++
    "01020200000000000001000000000000" ++
    "03044040000151800000384000000000" ++ "20010DB8000000000000000000000000" ++
    "220240110000006420010DB800000000" ++
    "230300050001000020010DB8000000000000000000000001");
const kat_na_ok = hx(40, "88001ECD60000000FE800000000000000000000000000002" ++
    "21020000000000640200000000000001");

const meta_ok = nd6.PacketMeta{ .src = router_ll, .dst = host_ll, .hop_limit = 255 };

// 文件作用域大缓冲（板侧栈 16 KiB）。
var h: nd6.Host = undefined;
var out_opt: [32]u8 = undefined;
var msg_buf: [128]u8 = undefined;
var acts: [8]nd6.Action = undefined;
var iphc_ctxs: f15.iphc.Contexts = .{};

// ---------------------------------------------------------------------------
// 判据
// ---------------------------------------------------------------------------

fn check1_aro(comptime check: fn (bool, []const u8) void) void {
    const n = nd6.encodeAro(&out_opt, nd6.aro_status_success, 100, host_eui) catch unreachable;
    var ok = n == 16;
    for (out_opt[0..16], kat_aro_ok) |b, k| {
        if (b != k) ok = false;
    }
    check(ok, "① ARO 编码=RFC6775 §4.1 图（Type33 Len2 Status lifetime60s EUI64）KAT 16B");
    if (nd6.decodeAro(&out_opt)) |a| {
        check(a.status == 0 and a.lifetime_units == 100, "① ARO 解码往返：Status/Lifetime/EUI-64 原样");
    } else |_| {
        check(false, "① ARO 解码往返：Status/Lifetime/EUI-64 原样");
    }
}

fn check2_aro_negative(comptime check: fn (bool, []const u8) void) void {
    var opt = kat_aro_ok;
    opt[1] = 3;
    var ok = true;
    if (nd6.decodeAro(&opt)) |_| ok = false else |_| {}
    check(ok, "② ARO Length=3 → BadOptionLength（6775 §4.1 行 860-862 “Always 2”）");
    if (nd6.decodeAro(kat_aro_ok[0..8])) |_| ok = false else |e| {
        ok = e == error.Short;
    }
    check(ok, "② ARO 截断（仅 8B）→ Short");
}

fn check3_6co(comptime check: fn (bool, []const u8) void) void {
    const n = nd6.encode6co(&out_opt, 1, prefix64, 64, true, 100) catch unreachable;
    var ok = n == 16;
    for (out_opt[0..16], kat_co64) |b, k| {
        if (b != k) ok = false;
    }
    check(ok, "③ 6CO 编码=RFC6775 §4.2 图1（Res|C|CID、VL60s 大端）KAT 16B");
    if (nd6.decode6co(&out_opt)) |c| {
        check(c.cid == 1 and c.compression and c.prefix_len == 64, "③ 6CO 解码往返 CID/C/前缀长");
    } else |_| {
        check(false, "③ 6CO 解码往返 CID/C/前缀长");
    }
    var bad = kat_co64;
    bad[1] = 2;
    bad[2] = 96; // Context Length >64 却 Length=2
    if (nd6.decode6co(&bad)) |_| ok = false else |e| {
        ok = e == error.BadOptionLength;
    }
    check(ok, "③ 6CO 负例：Context Length>64 且 Length=2 → 拒（行 968-969）");
}

fn check4_abro(comptime check: fn (bool, []const u8) void) void {
    const n = nd6.encodeAbro(&out_opt, 0x0001_0005, 0, lbr_addr) catch unreachable;
    var ok = n == 24;
    for (out_opt[0..24], kat_abro) |b, k| {
        if (b != k) ok = false;
    }
    check(ok, "④ ABRO 编码=RFC6775 §4.3（VersionLow 先发、VL=0）KAT 24B");
    if (nd6.decodeAbro(&out_opt)) |a| {
        check(a.version == 0x0001_0005 and a.lifetime_units == 0, "④ ABRO 解码：Version Low/High 拼回 32 位");
    } else |_| {
        check(false, "④ ABRO 解码：Version Low/High 拼回 32 位");
    }
}

fn check5_rs(comptime check: fn (bool, []const u8) void) void {
    const n = nd6.encodeRs(&msg_buf, host_ll, all_routers, .{ .eui64 = host_eui }) catch unreachable;
    var ok = n == kat_rs_frame.len;
    for (msg_buf[0..n], kat_rs_frame) |b, k| {
        if (b != k) ok = false;
    }
    check(ok, "⑤ RS 编码 KAT：SLLAO 必带（§5.3 行 1242）+ ICMPv6 校验和 24B");
}

fn check6_reg_ns(comptime check: fn (bool, []const u8) void) void {
    const n = nd6.encodeRegistrationNs(&msg_buf, host_gp16, router_ll, 100, host_eui, .{ .short16 = 0xAAAA }) catch unreachable;
    var ok = n == kat_reg_ns.len;
    for (msg_buf[0..n], kat_reg_ns) |b, k| {
        if (b != k) ok = false;
    }
    check(ok, "⑥ 注册 NS KAT：Src=GP16 Dst=6LR ARO+SLLAO（图 5 行 2495-2499）48B");
    const meta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 255 };
    if (nd6.parseNs(meta, msg_buf[0..n], .ieee802154)) |r| {
        var eq = std.mem.eql(u8, &r.target, &router_ll);
        if (r.sllao) |lla| {
            eq = eq and lla.short16 == 0xAAAA;
        } else eq = false;
        check(eq and r.ignored == 1, "⑥ parseNs 回读：Target=路由器、SLLAO=0xAAAA、ARO 计 ignored");
    } else |_| {
        check(false, "⑥ parseNs 回读：Target=路由器、SLLAO=0xAAAA、ARO 计 ignored");
    }
}

fn check7_ra(comptime check: fn (bool, []const u8) void) void {
    h = nd6.Host.init(host_eui, .ieee802154);
    const now: u64 = 100_000;
    if (h.processRa(meta_ok, &kat_ra_frame, now, 0)) |_| {
        check(h.routers[0].live and h.routers[0].valid_until == now + 1800 * 1000, "⑦ RA 落表：路由器 lifetime 1800s（§5.4 行 1266）");
        check(h.contextState(1, now) == .valid and h.abrs[0].version == 0x0001_0005, "⑦ RA 落表：6CO CID1 valid、ABRO 版本 0x00010005");
    } else |_| {
        check(false, "⑦ RA 落表：路由器 lifetime 1800s（§5.4 行 1266）");
        check(false, "⑦ RA 落表：6CO CID1 valid、ABRO 版本 0x00010005");
    }
    var bad = kat_ra_frame;
    bad[2] ^= 0x40;
    if (h.processRa(meta_ok, &bad, now, 0)) |_| {
        check(false, "⑦ 坏校验和 → BadChecksum（RFC 4443 §2.3 伪头）");
    } else |e| {
        check(e == error.BadChecksum, "⑦ 坏校验和 → BadChecksum（RFC 4443 §2.3 伪头）");
    }
}

fn check8_context_lifetime(comptime check: fn (bool, []const u8) void) void {
    h = nd6.Host.init(host_eui, .ieee802154);
    h.now = 0;
    h.applyContext(.{ .cid = 2, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 1 });
    var ok = h.contextState(2, 59_999) == .valid;
    check(ok, "⑧ 上下文 60s 内 valid（§5.4.2 行 1310-1315）");
    check(h.contextState(2, 60_001) == .receive_only, "⑧ 过期 → receive-only（§5.4.3 行 1329-1332）");
    check(h.contextState(2, 60_000 + 3600_000) == .free, "⑧ 2×默认 Router Lifetime 后删除（行 1330-1332）");
    ok = true;
    h.applyContext(.{ .cid = 2, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 0 });
    if (h.contextState(2, 0) != .free) ok = false;
    check(ok, "⑧ Valid Lifetime=0 → 立即删除（§5.4.2 行 1317-1319）");
}

fn check9_sync(comptime check: fn (bool, []const u8) void) void {
    h = nd6.Host.init(host_eui, .ieee802154);
    h.now = 50_000;
    h.applyContext(.{ .cid = 1, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 2 });
    iphc_ctxs = .{};
    h.syncContexts(&iphc_ctxs);
    var ok = iphc_ctxs.state(1) == .valid;
    if (iphc_ctxs.match(hx(16, "20010db8000000000000000000000042"))) |hit| {
        ok = ok and hit.id == 1;
    } else ok = false;
    check(ok, "⑨ syncContexts → fifteen4 表：state=valid、前缀匹配 CID1");
    h.now = 50_000 + 120_000 + 1;
    h.syncContexts(&iphc_ctxs);
    check(iphc_ctxs.state(1) == .receive_only, "⑨ 过期后同步成 C=0 条目（receive-only）");
    h.now = 50_000 + 120_000 + 3600_000;
    h.syncContexts(&iphc_ctxs);
    check(iphc_ctxs.state(1) == .free, "⑨ 保持期满同步删除（remove）");
}

fn check10_registration(comptime check: fn (bool, []const u8) void) void {
    h = nd6.Host.init(host_eui, .ieee802154);
    _ = h.processRa(meta_ok, &kat_ra_frame, 0, 0) catch unreachable;
    h.register(host_gp16, router_ll, 1000) catch unreachable;
    const n = h.tick(1000, &acts);
    var saw = false;
    for (acts[0..n]) |a| switch (a) {
        .send_register => |r| saw = std.mem.eql(u8, &r.registered, &host_gp16) and !r.dereg,
        else => {},
    };
    check(saw, "⑩ register → tick 产出注册 NS 动作（§5.5.1）");
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    if (h.processNa(meta, &kat_na_ok, 2000)) |hit| {
        check(hit != null and h.regs[0].state == .registered and
            h.regs[0].expires_at == 2000 + 100 * 60 * 1000, "⑩ NA Status=0 → registered、寿命 100 单位（行 1407-1408）");
    } else |_| {
        check(false, "⑩ NA Status=0 → registered、寿命 100 单位（行 1407-1408）");
    }
    var na2 = kat_na_ok;
    na2[26] = 2; // ARO Status=2（偏移 24+2）
    nd6.finalizeChecksum(&na2, meta.src, meta.dst);
    _ = h.processNa(meta, &na2, 3000) catch unreachable;
    const n2 = h.tick(3100, &acts);
    check(!h.routers[0].live and n2 > 0, "⑩ Status=2 → 摘默认路由器（行 1431-1434）→ 重新 RS");
}

fn check11_nexthop(comptime check: fn (bool, []const u8) void) void {
    h = nd6.Host.init(host_eui, .ieee802154);
    var ok = true;
    switch (h.nextHop(host_gp16)) {
        .no_route => {},
        else => ok = false,
    }
    _ = h.processRa(meta_ok, &kat_ra_frame, 0, 0) catch unreachable;
    switch (h.nextHop(router_ll)) {
        .neighbor => |d| ok = ok and std.mem.eql(u8, &d, &router_ll),
        else => ok = false,
    }
    switch (h.nextHop(host_gp16)) {
        .router => |r| ok = ok and std.mem.eql(u8, &r, &router_ll),
        else => ok = false,
    }
    check(ok and h.nextHop(all_routers) == .multicast, "⑪ 下一跳：link-local/组播/global→路由器（§5.6 行 1440-1459）");
    const short_host = hx(16, "fe80000000000000000000fffe001234");
    const lla = nd6.linkFromIid(.ieee802154, short_host[8..16].*) orelse nd6.LinkAddr{ .short16 = 0 };
    check(lla == .short16 and lla.short16 == 0x1234, "⑪ IID 反推：0000:00ff:fe00:XXXX → 短地址（RFC 6282 行 640-648）");
    check(h.resolveLinkAddr(host_ll).?.eui64[0] == 0x02, "⑪ resolveLinkAddr：IID 反推 U/L 翻转兜底");
}

fn check12_sleep(comptime check: fn (bool, []const u8) void) void {
    const picked = nd6.Host.pickRegistrationLifetime(30 * 60 * 1000) catch 0;
    check(picked == 31, "⑫ 30min 睡眠 → 31 单位（> 睡眠时长，§5.8.1 行 1496-1500）");
    h = nd6.Host.init(host_eui, .ieee802154);
    _ = h.processRa(meta_ok, &kat_ra_frame, 0, 0) catch unreachable;
    h.register(host_gp16, router_ll, 0) catch unreachable;
    _ = h.tick(0, &acts);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    _ = h.processNa(meta, &kat_na_ok, 1000) catch unreachable;
    const expires = h.regs[0].expires_at;
    const n = h.onWakeup(expires - 200_000, 300_000, &acts);
    check(n == 1 and h.regs[0].state == .probing, "⑫ 醒来：将在下次睡前过期的注册被刷新（行 1528-1530）");
}

/// 板侧耗时预算：12 个判据全是字节拷贝/比较与少量 u64 乘除（每判据 < 2 千条 rv32
/// 指令量级），总计远低于 2400 万条上限；无椭圆曲线、无大表。
pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    check1_aro(check);
    check2_aro_negative(check);
    check3_6co(check);
    check4_abro(check);
    check5_rs(check);
    check6_reg_ns(check);
    check7_ra(check);
    check8_context_lifetime(check);
    check9_sync(check);
    check10_registration(check);
    check11_nexthop(check);
    check12_sleep(check);
}
