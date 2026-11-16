//! 极简 RAM 版 NVS：只为让 Wi-Fi 的 init 路径能往下走，不是持久化实现。
//!
//! Wi-Fi 初始化几乎必然经 NVS 读配置/国家码/校准，所以 `_nvs_*` 这 12 个钩子留 null 会让
//! init 一进去就撞空指针，崩溃点停在我们最不想看的地方。这里用一张固定槽位的键值表把它打通：
//!
//!   - 命名空间最多 `max_namespaces` 个，句柄 = 序号 + 1（0 留给"无效"）；
//!   - 键名最长 `max_key`，值支持 i8/u8/u16 与 ≤ `max_blob` 的 blob；
//!   - `commit` 什么都不做（返回 0）：RAM 版没有"落盘"语义，真持久化留给以后接 flash。
//!
//! 返回值按 IDF 的 `esp_err_t`：0 = ESP_OK，非 0 见下面常量。

const std = @import("std");

pub const ok: c_int = 0;
pub const err_not_found: c_int = 0x1102; // ESP_ERR_NVS_NOT_FOUND
pub const err_no_free: c_int = 0x1105; // ESP_ERR_NVS_NO_FREE_PAGES
pub const err_invalid_len: c_int = 0x110C; // ESP_ERR_NVS_INVALID_LENGTH
pub const err_invalid_arg: c_int = 0x102; // ESP_ERR_INVALID_ARG

pub const max_namespaces = 4;
/// 槽数 × `max_blob` 是静态 `.bss` 占用：8 × 2048 = 16 KiB（原 32 × 64 = 2 KiB）。
/// blob 实际用到的键很少，8 个够用；若日志出现"槽满"再调。
pub const max_slots = 8;
pub const max_key = 16;
/// **必须装得下 PHY 校准数据**：`esp_phy_calibration_data_t` = 1904 字节。此前是 64，
/// 于是 blob 在 init 里读 `cal_data` 会拿到 `ESP_ERR_NVS_INVALID_LENGTH`（实测 rc=0x1102），
/// PHY 走"无校准"分支。这里给到 2048。
pub const max_blob = 2048;

const Kind = enum { i8v, u8v, u16v, blob };

const Slot = struct {
    used: bool = false,
    ns: u8 = 0,
    key: [max_key]u8 = undefined,
    key_len: usize = 0,
    kind: Kind = .u8v,
    num: u16 = 0,
    blob: [max_blob]u8 = undefined,
    blob_len: usize = 0,
};

var namespaces: [max_namespaces][max_key]u8 = undefined;
var namespace_len: [max_namespaces]usize = @splat(0);
var namespace_used: [max_namespaces]bool = @splat(false);
var slots: [max_slots]Slot = @splat(.{});

pub fn reset() void {
    namespace_used = @splat(false);
    namespace_len = @splat(0);
    slots = @splat(.{});
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

fn ensure(ns: u8, key: [*:0]const u8) ?*Slot {
    if (find(ns, key)) |s| return s;
    const k = std.mem.span(key);
    if (k.len == 0 or k.len > max_key) return null;
    for (&slots) |*s| {
        if (!s.used) {
            s.* = .{ .used = true, .ns = ns };
            @memcpy(s.key[0..k.len], k);
            s.key_len = k.len;
            return s;
        }
    }
    return null;
}

fn nsOf(handle: u32) ?u8 {
    if (handle == 0 or handle > max_namespaces) return null;
    return @intCast(handle - 1);
}

pub fn setNum(handle: u32, key: [*:0]const u8, value: u16, kind: Kind) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    const s = ensure(ns, key) orelse return err_no_free;
    s.kind = kind;
    s.num = value;
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
    const s = ensure(ns, key) orelse return err_no_free;
    s.kind = .blob;
    @memcpy(s.blob[0..data.len], data);
    s.blob_len = data.len;
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
    @memcpy(out[0..s.blob_len], s.blob[0..s.blob_len]);
    len.* = s.blob_len;
    return ok;
}

pub fn eraseKey(handle: u32, key: [*:0]const u8) c_int {
    const ns = nsOf(handle) orelse return err_invalid_arg;
    const s = find(ns, key) orelse return err_not_found;
    s.used = false;
    return ok;
}
