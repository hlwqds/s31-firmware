//! wifi-connect：OWE 的 PMK caching（RFC 8110 4.5）与 status code 77 的客户端动作（4.3）的
//! 主机用例（第四批）。
//!
//! 本文件可以单独作为测试根：`zig test src/owe_cache_tests.zig`；`host_tests.zig` 也 import 它。
//!
//! 期望值出处：
//!   * PMK / PMKID 用 `owe_selftest.zig` 里的 KAT（RFC 5903 §8.1 的密钥对走 RFC 8110 §4.4，
//!     数值由独立 oracle `/tmp/s31-oracle/owe_oracle.py kat` 给出）。缓存逻辑本身不参与
//!     密钥运算，所以判据都拿 KAT 的 PMK / PMKID 当「缓存里存的值」。
//!   * 过期与替换策略对拍过 Python 模型：`/tmp/s31-oracle/owe_cache/cache_oracle.py`
//!     （两个种子共 800 条操作、0 不一致），策略注释里的 hostap 行号来自
//!     `~/esp/esp-idf/components/wpa_supplicant/src`。
//!   * 每条用例标注条款号或 hostap 行号；「多 PMKID 的响应不算命中」是 RFC 8110 没写的
//!     互操作决定，出处是 hostap wpa.c:3386-3389，标注 [INFERENCE:hostap]。

const std = @import("std");

const owe = @import("owe.zig");
const rsne = @import("rsne.zig");
const st = @import("owe_selftest.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;

const selftest_host = @import("selftest_host.zig");
const owe_cache_selftest = @import("owe_cache_selftest.zig");

// 大缓冲放在文件作用域。
var buf_a: [512]u8 = undefined;
var buf_b: [512]u8 = undefined;
var ies_buf: [512]u8 = undefined;

/// 带 PMKID 的请求侧策略：PMKID Count 字段排在 RSN Capabilities 之后，本组件只在 MFPC 时写
/// 那两个字段（`rsne.buildStaRsne`），所以要带 PMKID 就得开 MFPC。MFPR 保持假：默认策略
/// （MFPC=MFPR=0）对 MFPR=1 的对端按表 12-2 是不可关联，select 会报 MfpPolicyViolation。
const policy_mfpc: rsne.OwnPolicy = blk: {
    var p = owe.policy;
    p.mfpc = true;
    break :blk p;
};

const Hit = @FieldType(owe.CacheDecision, "hit");
const Fresh = @FieldType(owe.CacheDecision, "fresh");

fn expectHit(d: owe.CacheDecision) Hit {
    return switch (d) {
        .hit => |h| h,
        .fresh => unreachable,
    };
}

fn expectFresh(d: owe.CacheDecision) Fresh {
    return switch (d) {
        .fresh => |f| f,
        .hit => unreachable,
    };
}

/// AP 的 RSNE：CCMP-128 与 GCMP-128、AKM 只通告 OWE（RFC 8110 表 1）；`pmkid` 非空时带上
/// RSN Capabilities 与恰好一个 PMKID（802.11-2016 9.4.2.25 的字段次序）。返回长度。
fn apRsneInto(out: []u8, pmkid: ?[owe.pmkid_len]u8) usize {
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise[1] = rsne.Cipher.gcmp128;
    r.pairwise_len = 2;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    if (pmkid) |p| {
        r.caps = rsne.caps_mfpc;
        r.caps_present = true;
        r.pmkid_present = true;
        r.pmkid_len = 1;
        r.pmkid[0] = p;
    }
    return rsne.encode(r, out) catch unreachable;
}

/// AP 的 Association Response 的信息元素：AP 的 RSNE ‖（可选）DH Parameter element，
/// 写进 `out`，返回切片（在 `out` 里）。
fn apIesInto(out: []u8, pmkid: ?[owe.pmkid_len]u8, element: ?[]const u8) []const u8 {
    var total = apRsneInto(out, pmkid);
    if (element) |e| {
        @memcpy(out[total..][0..e.len], e);
        total += e.len;
    }
    return out[0..total];
}

/// STA 的 Association Request 的信息元素：RSNE（按 `own_policy` 写，可带一个 PMKID）
/// ‖（可选）DH Parameter element。PMKID 列表要超过一个时直接用 `rsne.Rsne`。
fn staIesInto(out: []u8, own_policy: rsne.OwnPolicy, pmkid: ?[owe.pmkid_len]u8, element: ?[]const u8) []const u8 {
    const sel = apSelection();
    var total = rsne.buildStaRsne(sel, own_policy, pmkid, out) catch unreachable;
    if (element) |e| {
        @memcpy(out[total..][0..e.len], e);
        total += e.len;
    }
    return out[0..total];
}

/// 按 AP 的 RSNE（上面那份，无 PMKID）做出的策略选择（12.6.3）。
fn apSelection() rsne.Selection {
    var r: [rsne.max_len]u8 = undefined;
    const n = apRsneInto(&r, null);
    const ap = rsne.parse(r[0..n]) catch unreachable;
    return rsne.select(ap, owe.policy) catch unreachable;
}

fn keypairClient() owe.KeyPair {
    return owe.fromPrivate(st.kat_priv_client) catch unreachable;
}

fn keypairAp() owe.KeyPair {
    return owe.fromPrivate(st.kat_priv_ap) catch unreachable;
}

/// KAT 的缓存条目：PMK / PMKID 来自独立 oracle（owe_selftest.zig 文件头），缓存逻辑只当
/// 字节串存取。
fn cacheWithKat(lifetime: u64) owe.Cache {
    var cache = owe.Cache{};
    cache.add(st.kat_pmk, st.kat_pmkid, 1000, lifetime);
    return cache;
}

// ---------------------------------------------------------------------------
// client 侧（4.5，533–542 行）
// ---------------------------------------------------------------------------

test "owe_cache: client cache hit uses the cached PMK and ignores the DH element (RFC 8110 4.5, lines 533-535)" {
    var cache = cacheWithKat(100_000);
    // 响应里的 DH Parameter element 塞了曲线上不存在的公钥（x = 1，owe_selftest ⑥ 的负例）：
    // 命中时它整个被 SHALL-ignore，解析都不该发生。
    var bad_element: [37]u8 = st.kat_element_ap;
    @memset(bad_element[5..], 0);
    bad_element[36] = 1; // public key 的最后一字节：x = 1
    const ies = apIesInto(&ies_buf, st.kat_pmkid, &bad_element);
    const h = expectHit(try owe.clientCacheDecision(ies, st.kat_pmkid, &cache, 2000));
    try expect(eql(u8, &h.pmk, &st.kat_pmk)); // KAT：oracle owe_oracle.py kat
    try expect(eql(u8, &h.pmkid, &st.kat_pmkid));
}

test "owe_cache: client cache hit without a DH element in the response (RFC 8110 4.5, lines 527-529)" {
    var cache = cacheWithKat(100_000);
    // AP 命中时的响应：RSNE 回同一个 PMKID，没有 DH Parameter element。
    const ies = apIesInto(&ies_buf, st.kat_pmkid, null);
    const h = expectHit(try owe.clientCacheDecision(ies, st.kat_pmkid, &cache, 2000));
    try expect(eql(u8, &h.pmk, &st.kat_pmk));
}

test "owe_cache: client falls back to normal OWE when the response PMKID mismatches (RFC 8110 4.5, lines 536-539)" {
    var cache = cacheWithKat(100_000);
    const other: [16]u8 = @splat(0xab);
    const ies = apIesInto(&ies_buf, other, &st.kat_element_ap);
    const f = expectFresh(try owe.clientCacheDecision(ies, st.kat_pmkid, &cache, 2000));
    // 未命中 → 照常走 OWE 关联：同一段 IEs 交给 processAssoc，得到 KAT 的 PMK。
    const assoc = try owe.processAssoc(.client, ies, keypairClient());
    try expect(eql(u8, &assoc.keys.pmk, &st.kat_pmk));
    try expectEqual(assoc.sel.akm, f.sel.akm);
    try expectEqual(assoc.sel.pairwise, f.sel.pairwise);
}

test "owe_cache: client falls back when the response has no PMKID; OWE AKM without DH element is still discarded (RFC 8110 4.3 lines 389-393, 4.5 lines 536-539)" {
    var cache = cacheWithKat(100_000);
    // 没有 PMKID、有 DH Parameter element → 正常关联，KAT PMK。
    const with_dh = apIesInto(&ies_buf, null, &st.kat_element_ap);
    _ = expectFresh(try owe.clientCacheDecision(with_dh, st.kat_pmkid, &cache, 2000));
    try expect(eql(u8, &(try owe.processAssoc(.client, with_dh, keypairClient())).keys.pmk, &st.kat_pmk));
    // 没有 PMKID、也没有 DH Parameter element：缓存未在进行 → MUST discard（4.3）。
    var ies2: [64]u8 = undefined;
    const no_dh = apIesInto(&ies2, null, null);
    _ = expectFresh(try owe.clientCacheDecision(no_dh, st.kat_pmkid, &cache, 2000));
    try expectError(error.NoDhParameter, owe.processAssoc(.client, no_dh, keypairClient()));
}

test "owe_cache: client that offered no PMKID ignores the PMKID in the response (RFC 8110 4.5, lines 540-542)" {
    var cache = cacheWithKat(100_000);
    // 响应带着一个与本端缓存条目相同的 PMKID——但请求里没带 PMKID，SHALL 忽略 → 不是命中。
    const ies = apIesInto(&ies_buf, st.kat_pmkid, &st.kat_element_ap);
    _ = expectFresh(try owe.clientCacheDecision(ies, null, &cache, 2000));
    try expect(cache.lookup(st.kat_pmkid, 2000) != null); // 缓存还在，只是没用它
}

test "owe_cache: a matched response PMKID without a live cache entry is PmkNotCached (RFC 8110 4.5)" {
    const empty = owe.Cache{};
    const ies = apIesInto(&ies_buf, st.kat_pmkid, null);
    // AP 缓存过这条 PMKID（所以回了它），本端的缓存里却没有：命中路径没有 PMK 可用。
    try expectError(error.PmkNotCached, owe.clientCacheDecision(ies, st.kat_pmkid, &empty, 2000));
    // 同一响应在过期之后也一样：条目 expires_at = 1000 + 100_000。
    var cache = cacheWithKat(100_000);
    try expectError(error.PmkNotCached, owe.clientCacheDecision(ies, st.kat_pmkid, &cache, 101_001));
}

test "owe_cache: a response with two PMKIDs is not a cache hit [INFERENCE:hostap rsn_supp/wpa.c:3386-3389]" {
    var cache = cacheWithKat(100_000);
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    r.caps = rsne.caps_mfpc;
    r.caps_present = true;
    r.pmkid_present = true;
    r.pmkid_len = 2;
    r.pmkid[0] = @splat(0x11);
    r.pmkid[1] = st.kat_pmkid; // 列表里有一个与请求相同——hostap 的请求方只认 num_pmkid == 1
    const rn = rsne.encode(r, &ies_buf) catch unreachable;
    @memcpy(ies_buf[rn..][0..37], &st.kat_element_ap);
    const f = expectFresh(try owe.clientCacheDecision(ies_buf[0 .. rn + 37], st.kat_pmkid, &cache, 2000));
    try expectEqual(owe.akm_owe, f.sel.akm);
}

// ---------------------------------------------------------------------------
// AP 侧（4.5，516–531 行）
// ---------------------------------------------------------------------------

test "owe_cache: AP cache hit returns the cached PMK (RFC 8110 4.5, lines 518-519)" {
    var cache = cacheWithKat(100_000);
    const ies = staIesInto(&ies_buf, policy_mfpc, st.kat_pmkid, &st.kat_element_client);
    const h = expectHit(try owe.apCacheDecision(ies, &cache, 2000));
    try expect(eql(u8, &h.pmk, &st.kat_pmk));
    try expect(eql(u8, &h.pmkid, &st.kat_pmkid));
}

test "owe_cache: AP cache hit does not require a DH element in the request (hostap ap/ieee802_11.c:846-850)" {
    var cache = cacheWithKat(100_000);
    // hostap 在 DH 检查之前就返回成功；这里连元素都不带，照样命中。
    const ies = staIesInto(&ies_buf, policy_mfpc, st.kat_pmkid, null);
    const h = expectHit(try owe.apCacheDecision(ies, &cache, 2000));
    try expect(eql(u8, &h.pmk, &st.kat_pmk));
}

test "owe_cache: AP cache miss proceeds with normal OWE and the derived PMK becomes a hit (RFC 8110 4.5, lines 529-531)" {
    var cache = owe.Cache{};
    const ies = staIesInto(&ies_buf, policy_mfpc, st.kat_pmkid, &st.kat_element_client);
    // 缓存里没有 kat_pmkid → 忽略 PMKID，照常 OWE：派生出 KAT 的 PMK（C = g^i、A = g^r）。
    const f = expectFresh(try owe.apCacheDecision(ies, &cache, 1000));
    const assoc = try owe.processAssoc(.ap, ies, keypairAp());
    try expect(eql(u8, &assoc.keys.pmk, &st.kat_pmk));
    try expectEqual(assoc.sel.akm, f.sel.akm);
    // AP 派生成功后入缓存（hostap wpa_auth_pmksa_add2，ieee802_11.c:966-973）：
    cache.add(assoc.keys.pmk, assoc.keys.pmkid, 1000, owe.pmk_lifetime_80211);
    const h = expectHit(try owe.apCacheDecision(ies, &cache, 2000));
    try expect(eql(u8, &h.pmk, &st.kat_pmk));
}

test "owe_cache: AP searches every PMKID in the request list (hostap ap/wpa_auth_ie.c:813-821)" {
    var cache = cacheWithKat(100_000);
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    r.caps = rsne.caps_mfpc;
    r.caps_present = true;
    r.pmkid_present = true;
    r.pmkid_len = 2;
    r.pmkid[0] = @splat(0x22);
    r.pmkid[1] = st.kat_pmkid; // 第二个命中
    const rn = rsne.encode(r, &ies_buf) catch unreachable;
    @memcpy(ies_buf[rn..][0..37], &st.kat_element_client);
    const h = expectHit(try owe.apCacheDecision(ies_buf[0 .. rn + 37], &cache, 2000));
    try expect(eql(u8, &h.pmkid, &st.kat_pmkid));
}

test "owe_cache: AP cache miss with a PMKID but no DH element is an unspecified failure (hostap ap/ieee802_11.c:852-855)" {
    var cache = owe.Cache{};
    const ies = staIesInto(&ies_buf, policy_mfpc, st.kat_pmkid, null);
    _ = expectFresh(try owe.apCacheDecision(ies, &cache, 2000));
    // 未命中 → 照常 OWE，但请求里没有 DH Parameter element：拒绝，status 1
    // （hostap 对 owe_dh 为空回 WLAN_STATUS_UNSPECIFIED_FAILURE；表 9-46 印刷页 732）。
    try expectError(error.NoDhParameter, owe.processAssoc(.ap, ies, keypairAp()));
    try expectEqual(owe.Status.unspecified_failure, owe.statusCode(error.NoDhParameter));
}

test "owe_cache: requests that are not OWE fail before any cache work (RFC 8110 4.2, 4.3 ordering)" {
    var cache = cacheWithKat(100_000);
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    r.akm[0] = rsne.Akm.psk; // 对端不是 OWE
    r.akm_len = 1;
    var req: [64]u8 = undefined;
    const rn = rsne.encode(r, &req) catch unreachable;
    try expectError(error.NoAkmOverlap, owe.apCacheDecision(req[0..rn], &cache, 2000));
    // 没有 RSNE：不是 RSNA。
    try expectError(error.NoRsne, owe.apCacheDecision(&st.kat_element_client, &cache, 2000));
    try expectError(error.NoRsne, owe.clientCacheDecision(&st.kat_element_ap, st.kat_pmkid, &cache, 2000));
}

// ---------------------------------------------------------------------------
// 缓存状态：过期与替换（策略对拍 /tmp/s31-oracle/owe_cache/cache_oracle.py）
// ---------------------------------------------------------------------------

test "owe_cache: entries expire at the hostap boundary (pmksa_cache.c: expiration < now)" {
    var cache = owe.Cache{};
    cache.add(st.kat_pmk, st.kat_pmkid, 1000, 100);
    try expectEqual(@as(usize, 1), cache.len());
    try expect(cache.lookup(st.kat_pmkid, 1100) != null); // now == expires_at：仍有效
    try expect(cache.lookup(st.kat_pmkid, 1101) == null); // now > expires_at：过期
    try expect(cache.offerPmkid(1101) == null);
    try expectEqual(@as(usize, 1), cache.purge(1101));
    try expectEqual(@as(usize, 0), cache.len());
    try expectEqual(@as(usize, 0), cache.purge(1101)); // 再清一遍：0
}

test "owe_cache: a full cache evicts the oldest entry (hostap pmksa_cache.c:217-238)" {
    var cache = owe.Cache{};
    const pmks = [5][16]u8{
        @splat(0x01), @splat(0x02), @splat(0x03), @splat(0x04), @splat(0x05),
    };
    const pmks5 = [5][32]u8{
        @splat(0x11), @splat(0x12), @splat(0x13), @splat(0x14), @splat(0x15),
    };
    for (pmks, pmks5, 0..) |id, pmk, i| {
        cache.add(pmk, id, @intCast(i + 1), 100_000);
    }
    try expectEqual(owe.Cache.max_entries, cache.len());
    // 各条 lifetime 相同：最早过期的就是最早加入的（第 0 条，added_at = 1）。
    try expect(cache.lookup(pmks[0], 10) == null);
    for (1..4) |i| try expect(cache.lookup(pmks[i], 10) != null);
    try expect(eql(u8, &(cache.lookup(pmks[4], 10) orelse return error.TestUnexpectedResult).pmk, &pmks5[4]));
}

test "owe_cache: adding the same PMKID again replaces the entry in place (hostap pmksa_cache.c:181-215)" {
    var cache = owe.Cache{};
    const pmk_old: [32]u8 = @splat(0xaa);
    const pmk_new: [32]u8 = @splat(0xbb);
    cache.add(pmk_old, st.kat_pmkid, 1, 10);
    // 同一 PMKID 但 PMK 不同：替换，不占新位。
    cache.add(pmk_new, st.kat_pmkid, 100, 50);
    try expectEqual(@as(usize, 1), cache.len());
    try expect(eql(u8, &(cache.lookup(st.kat_pmkid, 120) orelse return error.TestUnexpectedResult).pmk, &pmk_new));
    // 旧的有效期也一并被替换：added_at 1 + 10 = 11 早已过期，新条目到 150。
    try expect(cache.lookup(st.kat_pmkid, 149) != null);
    try expect(cache.lookup(st.kat_pmkid, 151) == null);
}

test "owe_cache: adding the same PMK and PMKID again reuses the entry without refreshing (hostap pmksa_cache.c:186-194)" {
    var cache = owe.Cache{};
    const pmk: [32]u8 = @splat(0xcc);
    cache.add(pmk, st.kat_pmkid, 1, 10);
    cache.add(pmk, st.kat_pmkid, 100, 50); // 同一交换：旧条目原样保留，时间不刷新
    try expectEqual(@as(usize, 1), cache.len());
    const e = cache.lookup(st.kat_pmkid, 11) orelse return error.TestUnexpectedResult;
    try expectEqual(@as(u64, 1), e.added_at);
    try expectEqual(@as(u64, 11), e.expires_at);
    try expect(eql(u8, &e.pmk, &pmk));
    try expect(cache.lookup(st.kat_pmkid, 12) == null); // 旧有效期仍然生效
}

test "owe_cache: a full cache evicts the earliest-expiring entry, not the oldest added (hostap pmksa_cache.c:254-262, 217-238)" {
    var cache = owe.Cache{};
    const id_a: [16]u8 = @splat(0x0a);
    const id_b: [16]u8 = @splat(0x0b);
    const id_c: [16]u8 = @splat(0x0c);
    const id_d: [16]u8 = @splat(0x0d);
    const id_e: [16]u8 = @splat(0x0e);
    const pmk: [32]u8 = @splat(0x21);
    // a 最早加入但活到 10001；c 加得晚却只活到 60：第 5 条挤掉的是 c（expires_at 最早）。
    cache.add(pmk, id_a, 1, 10_000);
    cache.add(pmk, id_b, 2, 10_000);
    cache.add(pmk, id_c, 3, 57);
    cache.add(pmk, id_d, 4, 10_000);
    try expectEqual(owe.Cache.max_entries, cache.len());
    cache.add(pmk, id_e, 50, 10_000);
    try expect(cache.lookup(id_c, 60) == null);
    try expect(cache.lookup(id_a, 60) != null);
    try expect(cache.lookup(id_b, 60) != null);
    try expect(cache.lookup(id_d, 60) != null);
    try expect(cache.lookup(id_e, 60) != null);
}

test "owe_cache: offerPmkid picks the newest valid entry (RFC 8110 4.5, lines 516-518)" {
    var cache = owe.Cache{};
    try expect(cache.offerPmkid(10) == null); // 空缓存：不带 PMKID，走正常关联
    const pmk_a: [32]u8 = @splat(0x01);
    const pmk_b: [32]u8 = @splat(0x02);
    const id_a: [16]u8 = @splat(0x0a);
    const id_b: [16]u8 = @splat(0x0b);
    // a 到 201，b 到 102。
    cache.add(pmk_a, id_a, 1, 200);
    cache.add(pmk_b, id_b, 2, 100);
    try expect(eql(u8, &(cache.offerPmkid(10) orelse return error.TestUnexpectedResult), &id_b));
    // b 过期（102 < 103）之后：只能提供还没有过期的那条（a 到 201）。
    try expect(eql(u8, &(cache.offerPmkid(103) orelse return error.TestUnexpectedResult), &id_a));
    try expect(cache.offerPmkid(202) == null);
}

// ---------------------------------------------------------------------------
// 请求的构造与 status code 77 的客户端动作
// ---------------------------------------------------------------------------

test "owe_cache: association request carries the PMKID in the RSNE and the DH element (RFC 8110 4.5, lines 523-526)" {
    var req: [128]u8 = undefined;
    const n = try owe.buildAssocRequestWith(apSelection(), keypairClient(), policy_mfpc, st.kat_pmkid, &req);
    // RSNE 里恰好一个 PMKID，与本端提供的一致（802.11-2016 9.4.2.25）。
    const parsed = try rsne.parse(req[0..n]);
    try expect(parsed.pmkid_present);
    try expectEqual(@as(u8, 1), parsed.pmkid_len);
    try expect(eql(u8, &parsed.pmkid[0], &st.kat_pmkid));
    // 后面跟着 DH Parameter element：MUST include both（4.5）。
    const el = owe.findElement(req[0..n], owe.element_id, owe.element_ext) orelse return error.TestUnexpectedResult;
    try expect(eql(u8, el[0..37], &st.kat_element_client));
    // MFPC 是假的时候不许静默丢 PMKID。
    var req2: [128]u8 = undefined;
    try expectError(error.PmkidNeedsMfpc, owe.buildAssocRequestWith(apSelection(), keypairClient(), owe.policy, st.kat_pmkid, &req2));
}

test "owe_cache: without caching the request is byte-identical to the old API (backward compatibility)" {
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const sel = apSelection();
    const na = try owe.buildAssocRequest(sel, keypairClient(), &a);
    const nb = try owe.buildAssocRequestWith(sel, keypairClient(), owe.policy, null, &b);
    try expectEqual(na, nb);
    try expect(eql(u8, a[0..na], b[0..nb]));
}

test "owe_cache: after status 77 the client retries a different supported group or abandons (RFC 8110 4.3, lines 394-400)" {
    // 本组件只有 group 19（4.3 的 MUST）：没有「不同的群」可换 → null（放弃，SHOULD 记日志）。
    try expectEqual(@as(?u16, null), owe.nextGroupToTry(19, &.{19}));
    // 有别的群时换过去（列表顺序里的第一个不同的）。
    try expectEqual(@as(?u16, 21), owe.nextGroupToTry(19, &.{ 19, 21 }));
    try expectEqual(@as(?u16, 21), owe.nextGroupToTry(19, &.{ 21, 19 }));
    try expectEqual(@as(?u16, 19), owe.nextGroupToTry(20, &.{ 19, 21 }));
    try expectEqual(@as(?u16, null), owe.nextGroupToTry(19, &.{}));
}

test "owe_cache: a cache hit keeps the OWE selection from the response RSNE (RFC 8110 4.3)" {
    var cache = cacheWithKat(100_000);
    // 4.3 要求命中时的响应也带 OWE AKM 的 RSNE；响应里还塞了一个合法的 DH Parameter
    // element——命中时它被 SHALL-ignore，同一份字节走正常关联也不该报错。
    const ies = apIesInto(&ies_buf, st.kat_pmkid, &st.kat_element_ap);
    const h = expectHit(try owe.clientCacheDecision(ies, st.kat_pmkid, &cache, 2000));
    const assoc = try owe.processAssoc(.client, ies, keypairClient());
    try expect(eql(u8, &assoc.keys.pmk, &st.kat_pmk));
    try expectEqual(assoc.sel.akm, h.sel.akm);
    try expectEqual(assoc.sel.pairwise, h.sel.pairwise);
    try expectEqual(assoc.sel.group, h.sel.group);
    try expectEqual(assoc.sel.mfp_negotiated, h.sel.mfp_negotiated);
}

test "owe_cache: full round trip — fresh association populates both caches, reassociation hits on both sides (RFC 8110 4.5)" {
    // t=1000：第一次关联，双方各自派生（KAT），各自入缓存。
    var client_cache = owe.Cache{};
    var ap_cache = owe.Cache{};
    const req_ies = staIesInto(&ies_buf, policy_mfpc, null, &st.kat_element_client);
    const client_assoc = try owe.processAssoc(.client, apIesInto(&buf_a, null, &st.kat_element_ap), keypairClient());
    const ap_assoc = try owe.processAssoc(.ap, req_ies, keypairAp());
    try expect(eql(u8, &client_assoc.keys.pmk, &ap_assoc.keys.pmk));
    client_cache.add(client_assoc.keys.pmk, client_assoc.keys.pmkid, 1000, owe.pmk_lifetime_80211);
    ap_cache.add(ap_assoc.keys.pmk, ap_assoc.keys.pmkid, 1000, owe.pmk_lifetime_80211);

    // t=2000：重关联。client 提供 PMKID 并放进请求（4.5，523–526 行）；AP 命中，回 PMKID、
    // 不带 DH Parameter element（527–529 行）；client 命中，用缓存的 PMK（533–535 行）。
    const offered = client_cache.offerPmkid(2000) orelse return error.TestUnexpectedResult;
    try expect(eql(u8, &offered, &st.kat_pmkid));
    const req2 = staIesInto(&ies_buf, policy_mfpc, offered, &st.kat_element_client);
    const ap_hit = expectHit(try owe.apCacheDecision(req2, &ap_cache, 2000));
    try expect(eql(u8, &ap_hit.pmk, &st.kat_pmk));
    const resp_ies = apIesInto(&buf_b, ap_hit.pmkid, null); // 没有 DH Parameter element
    const client_hit = expectHit(try owe.clientCacheDecision(resp_ies, offered, &client_cache, 2000));
    try expect(eql(u8, &client_hit.pmk, &ap_hit.pmk));
    try expect(eql(u8, &client_hit.pmkid, &ap_hit.pmkid));
}

// ---------------------------------------------------------------------------
// 板侧子自检在主机上的读数
// ---------------------------------------------------------------------------

test "board selftest on host: OWE PMK caching (owe_cache_selftest.run) passes every check" {
    try selftest_host.expectAllPass(owe_cache_selftest.run);
}
