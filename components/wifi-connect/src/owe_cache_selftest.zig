//! wifi-connect：OWE 的 PMK caching（RFC 8110 4.5）的板侧自检（第四批）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 数值出处：PMK / PMKID / 公钥 / 元素都取 `owe_selftest.zig` 的 KAT（RFC 5903 §8.1 的
//! 密钥对经 RFC 8110 §4.4，由独立 oracle `/tmp/s31-oracle/owe_oracle.py kat` 给出）。
//! 缓存判决本身不做密钥运算，KAT 的值只当「缓存里存的那串字节」用；过期与替换策略已对
//! Python 模型做差分（`/tmp/s31-oracle/owe_cache/cache_oracle.py`，两个种子共 800 条操作、
//! 0 不一致）。
//!
//! 判据（条款号是 RFC 8110 的；hostap 行号来自
//! `~/esp/esp-idf/components/wpa_supplicant/src`）：
//!   ① 4.5（518–519 行）AP：请求 RSNE 带缓存的 PMKID → 命中，回缓存里的 PMK
//!   ② 4.5（hostap ieee802_11.c:846-850）AP：命中不要求请求里有 DH Parameter element
//!   ③ 4.5（529–531 行）AP：PMKID 未命中 → 忽略它，走正常 OWE 关联
//!   ④ 4.5（533–535 行）client：响应 PMKID 一致 → 忽略响应里的 DH Parameter element
//!     （塞一个曲线上不存在的公钥 x=1，若被解析必然失败）
//!   ⑤ 4.5（536–539 行）client：响应没有 PMKID → 正常 OWE 关联
//!   ⑥ 4.5（540–542 行）client：请求没带 PMKID → 忽略响应里的 PMKID
//!   ⑦ hostap pmksa_cache.c：now == expires_at 有效、now > expires_at 过期；purge 清掉
//!   ⑧ hostap pmksa_cache.c:217-238：缓存满时挤掉 added_at 最老的条目
//!   ⑨ hostap pmksa_cache.c:181-215：同一 PMKID 再入是原位替换（PMK 与有效期一并换）
//!   ⑩ 4.5（516–518 行）：offerPmkid 给有效条目里 added_at 最大的；过期后不再提供
//!   ⑪ 4.3（394–400 行）：status 77 后 SHOULD 换一个支持的群；只有 19 时无群可换
//!   ⑫ 4.5（523–526 行）：请求 MUST 同时带 PMKID 与 DH Parameter element；MFPC 假时
//!     PMKID 写不进 RSNE，拒绝（PmkidNeedsMfpc），不许静默丢
//!
//! 指令预算：全部判据只做字节数组比较与 ≤4 条目的线性扫描——没有哈希、没有 P-256 点乘
//! （0 条，预算上限 1 条），估算 < 5 万条 rv32 指令。缓存与元素缓冲都在文件作用域
//! （Cache 4 条 × 64 B，ies/req 缓冲 128/64 B），板侧 16 KiB 栈装得下。

const std = @import("std");

const owe = @import("owe.zig");
const rsne = @import("rsne.zig");
const st = @import("owe_selftest.zig");

var text_buf: [160]u8 = undefined;
var ies_buf: [128]u8 = undefined;
var req_buf: [128]u8 = undefined;
var rsne_buf: [rsne.max_len]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&text_buf, fmt, args) catch "owe cache: text too long";
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

/// 带 PMKID 的请求侧策略：PMKID Count 排在 RSN Capabilities 之后，本组件只在 MFPC 时写
/// 那两个字段。MFPR 保持假：默认策略（MFPC=MFPR=0）对 MFPR=1 的对端按表 12-2 不可关联。
const policy_mfpc: rsne.OwnPolicy = blk: {
    var p = owe.policy;
    p.mfpc = true;
    break :blk p;
};

/// KAT 密钥对直接由 RFC 5903 §8.1 的私钥与公钥拼成（公钥就是私钥的基点倍数），不跑点乘。
const kat_kp_client = owe.KeyPair{ .private = st.kat_priv_client, .public = st.kat_x_client };

/// AP 的 RSNE（无 PMKID）按 12.6.3 选出的策略。写在文件作用域的 `rsne_buf` 里。
fn apSelection() rsne.Selection {
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise[1] = rsne.Cipher.gcmp128;
    r.pairwise_len = 2;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    const n = rsne.encode(r, &rsne_buf) catch unreachable;
    const ap = rsne.parse(rsne_buf[0..n]) catch unreachable;
    return rsne.select(ap, owe.policy) catch unreachable;
}

/// STA 的 Association Request 的信息元素（`ies_buf`）：RSNE（可带一个 PMKID）
/// ‖（可选）DH Parameter element。返回切片，下一次调用前有效。
fn staIes(pmkid: ?[owe.pmkid_len]u8, element: ?[]const u8) []const u8 {
    var total = rsne.buildStaRsne(apSelection(), policy_mfpc, pmkid, &ies_buf) catch unreachable;
    if (element) |e| {
        @memcpy(ies_buf[total..][0..e.len], e);
        total += e.len;
    }
    return ies_buf[0..total];
}

/// AP 的 Association Response 的信息元素（`ies_buf`）：RSNE（可带一个 PMKID）
/// ‖（可选）DH Parameter element。
fn apIes(pmkid: ?[owe.pmkid_len]u8, element: ?[]const u8) []const u8 {
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    if (pmkid != null) {
        r.caps = rsne.caps_mfpc;
        r.caps_present = true;
        r.pmkid_present = true;
        r.pmkid_len = 1;
    }
    if (pmkid) |p| r.pmkid[0] = p;
    const n = rsne.encode(r, &ies_buf) catch unreachable;
    var total = n;
    if (element) |e| {
        @memcpy(ies_buf[total..][0..e.len], e);
        total += e.len;
    }
    return ies_buf[0..total];
}

fn hitOf(d: owe.CacheDecision) ?@FieldType(owe.CacheDecision, "hit") {
    return switch (d) {
        .hit => |h| h,
        .fresh => null,
    };
}

/// KAT 缓存条目：added_at 1000、有效期 100_000（判据里的 now 都远在有效期内）。
fn katCache() owe.Cache {
    var cache: owe.Cache = .{};
    cache.add(st.kat_pmk, st.kat_pmkid, 1000, 100_000);
    return cache;
}

/// 一个曲线上不存在的公钥（x = 1，`owe_selftest` ⑥ 的负例）装进 DH Parameter element。
/// 文件作用域，返回切片。
fn badElement() []const u8 {
    const full: [37]u8 = st.kat_element_ap;
    @memcpy(&bad_element_storage, &full);
    @memset(bad_element_storage[5..], 0);
    bad_element_storage[36] = 1; // public key 的最后一字节：x = 1
    return &bad_element_storage;
}
var bad_element_storage: [37]u8 = undefined;

// ①②③ AP 侧 ----------------------------------------------------------------

noinline fn checkApHit(check: fn (bool, []const u8) void) void {
    var cache = katCache();
    const hit = hitOf(owe.apCacheDecision(staIes(st.kat_pmkid, &st.kat_element_client), &cache, 2000) catch {
        check(false, "owe 4.5 AP: apCacheDecision(hit) errored");
        return;
    });
    const ok = hit != null and eq(&hit.?.pmk, &st.kat_pmk) and eq(&hit.?.pmkid, &st.kat_pmkid);
    check(ok, say("owe 4.5 AP: request PMKID in cache -> hit with the cached PMK {x} {x}", .{ st.kat_pmk[0], st.kat_pmk[31] }));

    // 命中不要求请求里有 DH Parameter element（hostap 在 DH 检查之前就返回）。
    const hit2 = hitOf(owe.apCacheDecision(staIes(st.kat_pmkid, null), &cache, 2000) catch {
        check(false, "owe 4.5 AP: apCacheDecision(hit, no DH) errored");
        return;
    });
    check(hit2 != null and eq(&hit2.?.pmk, &st.kat_pmk), "owe 4.5 AP: cache hit does not require a DH element in the request (hostap 846-850)");
}

noinline fn checkApMiss(check: fn (bool, []const u8) void) void {
    var cache: owe.Cache = .{};
    const other: [16]u8 = @splat(0x33);
    cache.add(st.kat_pmk, other, 1000, 100_000);
    const d = owe.apCacheDecision(staIes(st.kat_pmkid, &st.kat_element_client), &cache, 2000) catch {
        check(false, "owe 4.5 AP: apCacheDecision(miss) errored");
        return;
    };
    // 未命中 → fresh（忽略 PMKID，照常 OWE 关联）；点乘派生由 owe_selftest ⑧ 覆盖。
    check(hitOf(d) == null, "owe 4.5 AP: an unknown PMKID is ignored, decision is fresh (RFC 8110 4.5 lines 529-531)");
}

// ④⑤⑥ client 侧 ------------------------------------------------------------

noinline fn checkClientHit(check: fn (bool, []const u8) void) void {
    var cache = katCache();
    // 响应里的 DH Parameter element 装着曲线上不存在的公钥：命中时整个 SHALL-ignore。
    const hit = hitOf(owe.clientCacheDecision(apIes(st.kat_pmkid, badElement()), st.kat_pmkid, &cache, 2000) catch {
        check(false, "owe 4.5 client: clientCacheDecision(hit) errored");
        return;
    });
    const ok = hit != null and eq(&hit.?.pmk, &st.kat_pmk) and eq(&hit.?.pmkid, &st.kat_pmkid);
    check(ok, "owe 4.5 client: matching response PMKID -> hit, the DH element is ignored even when present (lines 533-535)");

    // 响应没有 PMKID → SHALL 照常走 OWE 关联（派生本身由 owe_selftest ⑧ 覆盖）。
    const d5 = owe.clientCacheDecision(apIes(null, &st.kat_element_ap), st.kat_pmkid, &cache, 2000) catch {
        check(false, "owe 4.5 client: decision without response PMKID errored");
        return;
    };
    check(hitOf(d5) == null, "owe 4.5 client: a response without a PMKID falls back to normal OWE (lines 536-539)");

    // 请求里没带 PMKID → SHALL 忽略响应里的 PMKID（哪怕它和缓存条目一样）。
    const d6 = owe.clientCacheDecision(apIes(st.kat_pmkid, &st.kat_element_ap), null, &cache, 2000) catch {
        check(false, "owe 4.5 client: decision without an offered PMKID errored");
        return;
    };
    check(hitOf(d6) == null, "owe 4.5 client: no PMKID in the request -> the response PMKID is ignored (lines 540-542)");
}

// ⑦⑧⑨⑩ 缓存状态 ------------------------------------------------------------

noinline fn checkExpiry(check: fn (bool, []const u8) void) void {
    var cache: owe.Cache = .{};
    cache.add(st.kat_pmk, st.kat_pmkid, 1000, 100);
    const at_edge = cache.lookup(st.kat_pmkid, 1100) != null;
    const expired = cache.lookup(st.kat_pmkid, 1101) == null;
    const purged = cache.purge(1101) == 1 and cache.len() == 0;
    check(at_edge and expired and purged, say("owe 4.5 cache: valid at expires_at={d}, expired one tick later, purge removes it", .{@intFromBool(at_edge and expired)}));
}

const five_ids = [5][16]u8{ @splat(0x01), @splat(0x02), @splat(0x03), @splat(0x04), @splat(0x05) };
const five_pmks = [5][32]u8{ @splat(0x11), @splat(0x12), @splat(0x13), @splat(0x14), @splat(0x15) };

noinline fn checkEviction(check: fn (bool, []const u8) void) void {
    var cache: owe.Cache = .{};
    for (five_ids, five_pmks, 0..) |id, pmk, i| {
        cache.add(pmk, id, @intCast(i + 1), 100_000);
    }
    var others = cache.lookup(five_ids[1], 10) != null;
    others = others and cache.lookup(five_ids[2], 10) != null;
    others = others and cache.lookup(five_ids[3], 10) != null;
    const newest = if (cache.lookup(five_ids[4], 10)) |e| eq(&e.pmk, &five_pmks[4]) else false;
    check(cache.lookup(five_ids[0], 10) == null and others and newest and cache.len() == owe.Cache.max_entries, "owe 4.5 cache: full cache evicts the earliest-expiring entry (hostap 217-238), keeps the rest");
}

noinline fn checkReplace(check: fn (bool, []const u8) void) void {
    const pmk_old: [32]u8 = @splat(0xaa);
    const pmk_new: [32]u8 = @splat(0xbb);
    var cache: owe.Cache = .{};
    cache.add(pmk_old, st.kat_pmkid, 1, 10);
    cache.add(pmk_new, st.kat_pmkid, 100, 50);
    const got = cache.lookup(st.kat_pmkid, 120);
    const ok = cache.len() == 1 and got != null and eq(&got.?.pmk, &pmk_new) and
        cache.lookup(st.kat_pmkid, 151) == null;
    check(ok, "owe 4.5 cache: adding the same PMKID again replaces pmk and lifetime in place (hostap 181-215)");
}

noinline fn checkOffer(check: fn (bool, []const u8) void) void {
    var cache: owe.Cache = .{};
    const empty = cache.offerPmkid(10) == null;
    cache.add(five_pmks[0], five_ids[0], 1, 200); // 到 201
    cache.add(five_pmks[1], five_ids[1], 2, 100); // 到 102
    const newest = if (cache.offerPmkid(10)) |p| eq(&p, &five_ids[1]) else false;
    const after_expiry = if (cache.offerPmkid(103)) |p| eq(&p, &five_ids[0]) else false;
    check(empty and newest and after_expiry and cache.offerPmkid(202) == null, "owe 4.5: offerPmkid picks the newest valid entry and nothing after expiry (lines 516-518)");
}

// ⑪⑫ status code 77 与请求构造 ----------------------------------------------

noinline fn checkStatus77(check: fn (bool, []const u8) void) void {
    const only_19 = owe.nextGroupToTry(19, &.{19}) == null;
    const other = owe.nextGroupToTry(19, &.{ 19, 21 }) != null and owe.nextGroupToTry(19, &.{ 19, 21 }).? == 21;
    check(only_19 and other, "owe 4.3: after status 77 retry a different supported group; with only 19 there is none -> abandon (lines 394-400)");
}

noinline fn checkRequest(check: fn (bool, []const u8) void) void {
    const n = owe.buildAssocRequestWith(apSelection(), kat_kp_client, policy_mfpc, st.kat_pmkid, &req_buf) catch {
        check(false, "owe 4.5: request build errored");
        return;
    };
    const parsed = rsne.parse(req_buf[0..n]) catch {
        check(false, "owe 4.5: request RSNE parse errored");
        return;
    };
    const pmkid_ok = parsed.pmkid_present and parsed.pmkid_len == 1 and eq(&parsed.pmkid[0], &st.kat_pmkid);
    const element = owe.findElement(req_buf[0..n], owe.element_id, owe.element_ext);
    const element_ok = element != null and element.?.len == 37 and eq(element.?[0..37], &st.kat_element_client);
    const refused = isErr(owe.buildAssocRequestWith(apSelection(), kat_kp_client, owe.policy, st.kat_pmkid, &req_buf), error.PmkidNeedsMfpc);
    check(pmkid_ok and element_ok and refused, "owe 4.5: request carries the PMKID in the RSNE and the DH element (MUST, lines 523-526); without MFPC it is refused, not dropped");
}

// ---------------------------------------------------------------------------

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkApHit(check);
    checkApMiss(check);
    checkClientHit(check);
    checkExpiry(check);
    checkEviction(check);
    checkReplace(check);
    checkOffer(check);
    checkStatus77(check);
    checkRequest(check);
}
