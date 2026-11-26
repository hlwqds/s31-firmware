//! 极简 RAM 版 NVS：只为让 Wi-Fi 的 init / 配置路径能往下走，不是持久化实现。
//!
//! Wi-Fi 初始化几乎必然经 NVS 读配置/国家码/校准，所以 `_nvs_*` 这 12 个钩子留 null 会让
//! init 一进去就撞空指针，崩溃点停在我们最不想看的地方。这里用一张固定槽位的键值表把它打通：
//!
//!   - 命名空间最多 `max_namespaces` 个，句柄 = 序号 + 1（0 留给"无效"）；
//!   - 键名最长 `max_key`，值支持 i8/u8/u16 与 blob；
//!   - `commit` 什么都不做（返回 0）：RAM 版没有"落盘"语义，真持久化留给以后接 flash。
//!
//! 返回值按 IDF 的 `esp_err_t`：0 = ESP_OK，非 0 见下面常量。
//!
//! ## 存储分三块
//!
//! **键表**（`max_slots` 项）只记键和标量值，不占 blob 空间。驱动不是把 STA 配置存成一个大 blob，
//! 而是把 `wifi_sta_config_t` **逐字段**存成四十多个键（`sta.ssid`、`sta.pswd`、`sta.chan`、
//! `sta.scan_method`、`sta.minrssi` …；对照镜像留在板子 NVS 里的键名就是这样），其中绝大多数是
//! 1–2 字节的标量。此前每个槽自带 2048 字节 blob（为 PHY 校准数据定的尺寸）：8 个槽在
//! `esp_wifi_set_config` 的第 9 个键就用完，改成 18 个槽后又在第 19 个键用完
//! （板侧实测 `wifi_nvs_set fail, index=15` / `index=41 ret=0x1105`，`esp_wifi_set_config` 返回 `0x1105`）。
//!
//! **blob 池**分两档，只在键第一次存 blob 时才占：大池装 PHY 校准数据（1904 字节），小池装字符串
//! （`sta.pswd` 65 字节、`sta.ssid` 36 字节）。小池满了小 blob 可以借大池的空位。
//! 存不下的写入按 IDF 的语义不改动旧值。

const std = @import("std");

pub const ok: c_int = 0;
pub const err_not_found: c_int = 0x1102; // ESP_ERR_NVS_NOT_FOUND
pub const err_no_free: c_int = 0x1105; // ESP_ERR_NVS_NO_FREE_PAGES
pub const err_invalid_len: c_int = 0x110C; // ESP_ERR_NVS_INVALID_LENGTH
pub const err_invalid_arg: c_int = 0x102; // ESP_ERR_INVALID_ARG

pub const max_namespaces = 4;
pub const max_key = 16;
/// 键表大小：驱动的 `esp_wifi_set_config` 一次写四十多个键，再加 init 路径读写的那些。
pub const max_slots = 64;
/// **必须装得下 PHY 校准数据**：1904 字节。给不到时 blob 在 init 里读 `cal_data` 会拿到
/// `ESP_ERR_NVS_INVALID_LENGTH`，PHY 走"无校准"分支（实测 rc=0x1102）。
pub const big_blob = 2048;
pub const max_blob = big_blob;
pub const max_big_blobs = 2;
pub const small_blob = 256;
pub const max_small_blobs = 16;

const Kind = enum { i8v, u8v, u16v, blob };

const Slot = struct {
    used: bool = false,
    /// 写成功过一次。新占的键表项在写入失败时要还回去。
    written: bool = false,
    ns: u8 = 0,
    key: [max_key]u8 = undefined,
    key_len: usize = 0,
    kind: Kind = .u8v,
    num: u16 = 0,
    /// 这个键占用的 blob（池子里的一整格），没存过 blob 就是空。
    blob: ?[]u8 = null,
    blob_len: usize = 0,
};

var namespaces: [max_namespaces][max_key]u8 = undefined;
var namespace_len: [max_namespaces]usize = @splat(0);
var namespace_used: [max_namespaces]bool = @splat(false);
var big_pool: [max_big_blobs][big_blob]u8 = undefined;
var big_used: [max_big_blobs]bool = @splat(false);
var small_pool: [max_small_blobs][small_blob]u8 = undefined;
var small_used: [max_small_blobs]bool = @splat(false);
var slots: [max_slots]Slot = @splat(.{});

pub fn reset() void {
    namespace_used = @splat(false);
    namespace_len = @splat(0);
    big_used = @splat(false);
    small_used = @splat(false);
    slots = @splat(.{});
}

/// 已占用的键表项数（诊断用）。
pub fn usedSlots() usize {
    var n: usize = 0;
    for (&slots) |*s| {
        if (s.used) n += 1;
    }
    return n;
}

fn nameEq(stored: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, stored, name);
}

pub fn open(name: [*:0]const u8, out_handle: ?*u32) c_int {
    const h = out_handle orelse return err_invalid_arg;
    const n = std.mem.span(name);
    if (n.len == 0 or n.len > max_key) return err_invalid_arg;
    for (0..max_namespaces) |i| {
        if (namespace_used[i] and nameEq(namespaces[i][0..namespace_len[i]], n)) {
            h.* = @intCast(i + 1);
            return ok;
        }
    }
    for (0..max_namespaces) |i| {
        if (!namespace_used[i]) {
            @memcpy(namespaces[i][0..n.len], n);
            namespace_len[i] = n.len;
            namespace_used[i] = true;
            h.* = @intCast(i + 1);
            return ok;
        }
    }
    return err_no_free;
}

pub fn close(handle: u32) void {
    _ = handle;
}

pub fn commit(handle: u32) c_int {
    _ = handle;
    return ok; // RAM 版没有落盘语义
}

fn find(ns: u8, key: [*:0]const u8) ?*Slot {
    const k = std.mem.span(key);
    if (k.len == 0 or k.len > max_key) return null;
    for (&slots) |*s| {
        if (s.used and s.ns == ns and nameEq(s.key[0..s.key_len], k)) return s;
    }
    return null;
}

/// 这个键的键表项：已有就沿用，没有就新占一项（键表满了返回空）。
fn ensureSlot(ns: u8, key: [*:0]const u8) ?*Slot {
    if (find(ns, key)) |s| return s;
    const k = std.mem.span(key);
    if (k.len == 0 or k.len > max_key) return null;
    for (&slots) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .ns = ns };
            @memcpy(e.key[0..k.len], k);
            e.key_len = k.len;
            return e;
        }
    }
    return null;
}

fn allocBlob(n: usize) ?[]u8 {
    if (n > small_blob) {
        for (&big_pool, &big_used) |*cell, *u| {
            if (!u.*) {
                u.* = true;
                return cell[0..];
            }
        }
        return null;
    }
    for (&small_pool, &small_used) |*cell, *u| {
        if (!u.*) {
            u.* = true;
            return cell[0..];
        }
    }
    // 小池满了：借大池的空位（大池不会给小值留着不用——宁可占地方也不让驱动报错）。
    for (&big_pool, &big_used) |*cell, *u| {
        if (!u.*) {
            u.* = true;
            return cell[0..];
        }
    }
    return null;
}

/// 把这个键占的 blob 格还回池子。
fn releaseBlob(s: *Slot) void {
    const b = s.blob orelse return;
    for (&big_pool, &big_used) |*cell, *u| {
        if (@intFromPtr(b.ptr) == @intFromPtr(&cell[0])) u.* = false;
    }
    for (&small_pool, &small_used) |*cell, *u| {
        if (@intFromPtr(b.ptr) == @intFromPtr(&cell[0])) u.* = false;
    }
    s.blob = null;
    s.blob_len = 0;
}

fn nsOf(handle: u32) ?u8 {
    if (handle == 0 or handle > max_namespaces) return null;
    return @intCast(handle - 1);
}

pub fn setNum(handle: u32, key: [*:0]const u8, value: u16, kind: Kind) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    const s = ensureSlot(ns, key) orelse return err_no_free;
    s.kind = kind;
    s.num = value;
    s.written = true;
    return ok;
}

pub fn getNum(handle: u32, key: [*:0]const u8, kind: Kind, out: *u16) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    const s = find(ns, key) orelse return err_not_found;
    if (s.kind != kind) return err_not_found;
    out.* = s.num;
    return ok;
}

pub fn setBlob(handle: u32, key: [*:0]const u8, data: []const u8) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    if (data.len > max_blob) return err_invalid_len;
    const s = ensureSlot(ns, key) orelse return err_no_free;
    // 旧的那格够大就接着用；不够就先切新格、再还旧格——切不到新格时旧值原样留着。
    const keeps = if (s.blob) |b| b.len >= data.len else false;
    if (!keeps) {
        const cell = allocBlob(data.len) orelse {
            if (!s.written) s.used = false;
            return err_no_free;
        };
        releaseBlob(s);
        s.blob = cell;
    }
    s.kind = .blob;
    @memcpy(s.blob.?[0..data.len], data);
    s.blob_len = data.len;
    s.written = true;
    return ok;
}

/// `len` 是**输入输出**：输入缓冲大小，输出实际长度（IDF 语义）。
pub fn getBlob(handle: u32, key: [*:0]const u8, out: []u8, len: *usize) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    const s = find(ns, key) orelse return err_not_found;
    if (s.kind != .blob) return err_not_found;
    if (out.len < s.blob_len) {
        len.* = s.blob_len;
        return err_invalid_len;
    }
    @memcpy(out[0..s.blob_len], s.blob.?[0..s.blob_len]);
    len.* = s.blob_len;
    return ok;
}

pub fn eraseKey(handle: u32, key: [*:0]const u8) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    const s = find(ns, key) orelse return err_not_found;
    releaseBlob(s);
    s.used = false;
    return ok;
}

// ---------------------------------------------------------------------------
// 主机侧用例
// ---------------------------------------------------------------------------

const testing = std.testing;

test "nvs_ram: 标量与 blob 的往返，句柄、键长、越界都按 IDF 的错误码报" {
    reset();
    var h: u32 = 0;
    try testing.expectEqual(ok, open("nvs.net80211", &h));
    try testing.expectEqual(ok, open("nvs.net80211", &h)); // 同名命名空间复用
    try testing.expectEqual(@as(u32, 1), h);
    try testing.expectEqual(err_invalid_arg, open("", &h));
    try testing.expectEqual(err_invalid_arg, open("a.name.that.is.far.too.long.for.nvs", &h));

    try testing.expectEqual(ok, setNum(h, "sta.chan", 6, .u8v));
    var v: u16 = 0;
    try testing.expectEqual(ok, getNum(h, "sta.chan", .u8v, &v));
    try testing.expectEqual(@as(u16, 6), v);
    try testing.expectEqual(ok, setNum(h, "sta.chan", 11, .u8v)); // 同一个键再写一次是覆盖
    try testing.expectEqual(ok, getNum(h, "sta.chan", .u8v, &v));
    try testing.expectEqual(@as(u16, 11), v);
    // 类型不对按「没找到」报。
    try testing.expectEqual(err_not_found, getNum(h, "sta.chan", .u16v, &v));
    try testing.expectEqual(err_not_found, getNum(h, "sta.nope", .u8v, &v));
    try testing.expectEqual(@as(usize, 1), usedSlots());

    const blob: [184]u8 = @splat(0xAB);
    try testing.expectEqual(ok, setBlob(h, "sta.conf", &blob));
    var buf: [256]u8 = undefined;
    var n: usize = buf.len;
    try testing.expectEqual(ok, getBlob(h, "sta.conf", &buf, &n));
    try testing.expectEqualSlices(u8, &blob, buf[0..n]);
    // 缓冲太小：报 INVALID_LENGTH，并告诉调用方实际长度。
    n = 32;
    try testing.expectEqual(err_invalid_len, getBlob(h, "sta.conf", buf[0..32], &n));
    try testing.expectEqual(@as(usize, blob.len), n);
    // 另一个命名空间看不到这个键。
    var h2: u32 = 0;
    try testing.expectEqual(ok, open("nvs.phy", &h2));
    n = buf.len;
    try testing.expectEqual(err_not_found, getBlob(h2, "sta.conf", &buf, &n));
}

test "nvs_ram: PHY 校准数据（1904 字节）放得下，超长与键长越界被拒，拒掉的值不改旧值" {
    reset();
    var h: u32 = 0;
    try testing.expectEqual(ok, open("phy", &h));
    const cal: [1904]u8 = @splat(0x5A);
    try testing.expectEqual(ok, setBlob(h, "cal_data", &cal));
    var buf: [2048]u8 = undefined;
    var n: usize = buf.len;
    try testing.expectEqual(ok, getBlob(h, "cal_data", &buf, &n));
    try testing.expectEqual(@as(usize, 1904), n);
    const too_long: [2049]u8 = @splat(0);
    try testing.expectEqual(err_invalid_len, setBlob(h, "cal_data", &too_long));
    try testing.expectEqual(err_no_free, setBlob(h, "a.key.name.that.is.far.too.long.for.nvs", &cal));
    n = buf.len;
    try testing.expectEqual(ok, getBlob(h, "cal_data", &buf, &n));
    try testing.expectEqual(@as(usize, 1904), n);
}

test "nvs_ram: esp_wifi_set_config 那一步——逐字段存的 STA 配置（两个字符串加四十多个标量键）都存得进去" {
    reset();
    var h: u32 = 0;
    try testing.expectEqual(ok, open("nvs.net80211", &h));
    try testing.expectEqual(ok, setBlob(h, "cal_data", &@as([1904]u8, @splat(0x11))));
    // 照驱动留在板子 NVS 里的存法：`sta.ssid` 是 [长度 4 字节][32 字节缓冲]，`sta.pswd` 是 64 字节缓冲
    // 加 1 个字节，其余都是 1–2 字节的标量。
    var ssid: [36]u8 = @splat(0);
    ssid[0] = 7;
    @memcpy(ssid[4..11], "hl-wifi");
    try testing.expectEqual(ok, setBlob(h, "sta.ssid", &ssid));
    const pswd: [65]u8 = @splat(0x38);
    try testing.expectEqual(ok, setBlob(h, "sta.pswd", &pswd));
    const scalar_keys = [_][*:0]const u8{
        "bssid.set",     "sta.lis_intval", "sta.chan",      "sta.scan_method", "sta.sort_method",
        "sta.minrssi",   "sta.minauth",    "sta.apsw",      "sta.pmf_e",       "sta.pmf_r",
        "sta.rrm_e",     "sta.btm_e",      "sta.mbo_e",     "sta.ft",          "sta.owe",
        "sta.bss_retry", "sta.trans_d",    "sta.wpa3_c_d",  "sta.sae_h2e",     "sta.sae_pk_m",
        "sta.he_dcm",    "sta.he_dcm_c_t", "sta.he_dcm_c",  "sta.he_mcs9_d",   "sta.he_su_b_d",
        "sta.he_su_b_f", "sta.he_mu_b_f",  "sta.vht_s_b_d", "sta.vht_m_b_d",   "sta.vht_mcs8_e",
        "sta.sae_h2e_i", "sta.he_cqi_f_d",
    };
    for (scalar_keys, 0..) |k, i| {
        try testing.expectEqual(ok, setNum(h, k, @intCast(i + 1), .u8v));
    }
    try testing.expectEqual(@as(usize, 3 + scalar_keys.len), usedSlots());
    var v: u16 = 0;
    try testing.expectEqual(ok, getNum(h, "sta.vht_mcs8_e", .u8v, &v));
    try testing.expectEqual(@as(u16, 30), v);
    // 字符串原样读回。
    var buf: [256]u8 = undefined;
    var n: usize = buf.len;
    try testing.expectEqual(ok, getBlob(h, "sta.pswd", &buf, &n));
    try testing.expectEqualSlices(u8, &pswd, buf[0..n]);
    n = buf.len;
    try testing.expectEqual(ok, getBlob(h, "sta.ssid", &buf, &n));
    try testing.expectEqualSlices(u8, &ssid, buf[0..n]);
}

test "nvs_ram: 池子满了按 IDF 的错误码报且不改旧值；擦掉键腾出的地方可以再用；小 blob 可以借大池" {
    reset();
    var h: u32 = 0;
    try testing.expectEqual(ok, open("nvs.net80211", &h));
    // 填满小池（16 格）；第 17 个小 blob 借大池。
    var i: usize = 0;
    while (i < max_small_blobs) : (i += 1) {
        var key: [max_key]u8 = @splat(0);
        key[0] = 'A' + @as(u8, @intCast(i));
        const val: [200]u8 = @splat(@intCast(i));
        try testing.expectEqual(ok, setBlob(h, @ptrCast(&key), &val));
    }
    const borrowed: [200]u8 = @splat(0xEE);
    try testing.expectEqual(ok, setBlob(h, "borrowed", &borrowed));
    // 大池只剩一格：校准数据放得下，再来一个大的就没地方。
    const cal: [1904]u8 = @splat(0x11);
    try testing.expectEqual(ok, setBlob(h, "cal_data", &cal));
    const third: [1904]u8 = @splat(0x22);
    try testing.expectEqual(err_no_free, setBlob(h, "third", &third));
    // 超过小池、又借不到大池的 300 字节 blob 也没有地方。
    const mid: [300]u8 = @splat(7);
    try testing.expectEqual(err_no_free, setBlob(h, "mid", &mid));
    // 存不下不改旧值："borrowed" 还是原来那 200 个 0xEE。
    var buf: [2048]u8 = undefined;
    var n: usize = buf.len;
    try testing.expectEqual(ok, getBlob(h, "borrowed", &buf, &n));
    try testing.expectEqualSlices(u8, &borrowed, buf[0..n]);
    // 标量不占 blob 池：键表还有地方，照样存得进去。
    try testing.expectEqual(ok, setNum(h, "sta.chan", 6, .u8v));
    var v: u16 = 0;
    try testing.expectEqual(ok, getNum(h, "sta.chan", .u8v, &v));
    try testing.expectEqual(@as(u16, 6), v);
    // 擦掉 "borrowed"，300 字节的 blob 就借到它腾出来的大池那一格。
    try testing.expectEqual(ok, eraseKey(h, "borrowed"));
    try testing.expectEqual(ok, setBlob(h, "mid", &mid));
    n = buf.len;
    try testing.expectEqual(ok, getBlob(h, "mid", &buf, &n));
    try testing.expectEqual(@as(usize, 300), n);
    try testing.expectEqual(err_not_found, eraseKey(h, "never.written"));
    try testing.expectEqual(err_not_found, getBlob(h, "borrowed", &buf, &n));
}

test "nvs_ram: 同一个键从小值长成大值时挪得进大池，值还是对的；键表满了报 NO_FREE_PAGES" {
    reset();
    var h: u32 = 0;
    try testing.expectEqual(ok, open("nvs.net80211", &h));
    const small: [100]u8 = @splat(1);
    try testing.expectEqual(ok, setBlob(h, "grows", &small));
    const big: [1904]u8 = @splat(2);
    try testing.expectEqual(ok, setBlob(h, "grows", &big));
    var buf: [2048]u8 = undefined;
    var n: usize = buf.len;
    try testing.expectEqual(ok, getBlob(h, "grows", &buf, &n));
    try testing.expectEqual(@as(usize, 1904), n);
    try testing.expectEqual(@as(usize, 1), usedSlots());
    // 小池那一格已经还回去了：16 个小 blob 还都放得下。
    var i: usize = 0;
    while (i < max_small_blobs) : (i += 1) {
        var key: [max_key]u8 = @splat(0);
        key[0] = 'A' + @as(u8, @intCast(i));
        try testing.expectEqual(ok, setBlob(h, @ptrCast(&key), &small));
    }
    try testing.expectEqual(@as(usize, 17), usedSlots());
    // 写到键表满（64 项）：键名用两个字母，互不相同，也不与上面的单字母键、"grows" 相同。
    while (usedSlots() < max_slots) {
        var key: [max_key]u8 = @splat(0);
        const ordinal = max_slots - usedSlots();
        key[0] = 'a' + @as(u8, @intCast(ordinal / 26));
        key[1] = 'a' + @as(u8, @intCast(ordinal % 26));
        try testing.expectEqual(ok, setNum(h, @ptrCast(&key), 1, .u8v));
    }
    try testing.expectEqual(max_slots, usedSlots());
    try testing.expectEqual(err_no_free, setNum(h, "overflow", 1, .u8v));
    // 失败的那次没有在键表里留下痕迹：擦掉一项之后还能再写进去。
    try testing.expectEqual(ok, eraseKey(h, "grows"));
    try testing.expectEqual(ok, setNum(h, "overflow", 1, .u8v));
    var v: u16 = 0;
    try testing.expectEqual(ok, getNum(h, "overflow", .u8v, &v));
    try testing.expectEqual(@as(u16, 1), v);
}
