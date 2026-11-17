//! 分区表解析（IDF 二进制格式，位于 flash 0x8000）。
//!
//! 格式出处：IDF v6.1 `components/bootloader_support/include/esp_flash_partitions.h`
//! 与 `esp_partition.h`。条目 32 字节，小端：
//!
//! ```text
//!   0..2   magic = 0xAA50（字节序 aa 50）
//!   2..3   type    0=app 1=data
//!   3..4   subtype
//!   4..8   offset
//!   8..12  size
//!  12..28  label（16 字节，NUL 填充）
//!  28..32  flags
//! ```
//!
//! 表在 0x8000，最多 0xC00 字节；条目以 magic 不是 0xAA50 结束（烧过的表是 0xFFFF，
//! 也就是无数据的 0xFF 填充）。末尾可能跟一个 32 字节的 MD5 记录（magic 0xEBEB），
//! 本模块**不校验**它：bootloader 才是权威，这里只读引导用的几个字段。
//!
//! 为什么需要它：C5 的 A/B 要先知道 `ota_0`/`ota_1`/`otadata` 到底在哪，
//! 而这些偏移由分区表决定，不能写死在代码里（改表就会静默错位）。

const std = @import("std");
const flash = @import("flash.zig");

pub const entry_len: usize = 32;
pub const table_offset: u32 = 0x8000;
pub const table_max_len: usize = 0xC00;
pub const magic: u16 = 0x50AA;
pub const md5_magic: u16 = 0xEBEB;

/// `type` 字段。
pub const Kind = struct {
    pub const app: u8 = 0x00;
    pub const data: u8 = 0x01;
};

/// `subtype` 字段（只列本仓用到的）。
pub const Subtype = struct {
    pub const factory: u8 = 0x00;
    pub const ota_0: u8 = 0x10;
    pub const ota_1: u8 = 0x11;
    pub const nvs: u8 = 0x02;
    pub const phy: u8 = 0x01;
    /// `data/ota`：otadata 的 subtype 就是 0x00，与 app/factory 的 0x00 靠 type 区分。
    pub const otadata: u8 = 0x00;
};

pub const Error = error{
    BadMagic,
    TooManyEntries,
    ReadFailed,
};

pub const Entry = struct {
    kind: u8,
    subtype: u8,
    offset: u32,
    size: u32,
    label: [16]u8,

    /// 取标签字符串。**必须借指针**：按值传参时 `self.label` 是栈上的副本，
    /// 从它切出来的 slice 在函数返回后悬空（host 测试会直接读到垃圾）。
    pub fn name(self: *const Entry) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.label, 0) orelse self.label.len;
        return self.label[0..n];
    }

    pub fn isApp(self: Entry) bool {
        return self.kind == Kind.app;
    }
};

/// 表里条目数上限：0xC00 / 32 = 96，但真正有用的远少于此。
pub const max_entries: usize = 32;

pub const Table = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,

    pub fn slice(self: *const Table) []const Entry {
        return self.entries[0..self.count];
    }

    /// 按标签查找（区分大小写，与 IDF 一致）。
    pub fn find(self: *const Table, label: []const u8) ?Entry {
        for (self.entries[0..self.count]) |*e| {
            if (std.mem.eql(u8, e.name(), label)) return e.*;
        }
        return null;
    }

    /// 按 (type, subtype) 查找。otadata 只能这样找。
    pub fn findKind(self: *const Table, kind: u8, subtype: u8) ?Entry {
        for (self.slice()) |e| {
            if (e.kind == kind and e.subtype == subtype) return e;
        }
        return null;
    }

    pub fn findApp(self: *const Table, subtype: u8) ?Entry {
        return self.findKind(Kind.app, subtype);
    }

    pub fn otadata(self: *const Table) ?Entry {
        return self.findKind(Kind.data, Subtype.otadata);
    }
};

/// 解析一段分区表字节。遇到 magic 不是 0xAA50 的条目即停止。
pub fn parse(bytes: []const u8) Error!Table {
    var t: Table = .{};
    var off: usize = 0;
    while (off + entry_len <= bytes.len) : (off += entry_len) {
        const m = std.mem.readInt(u16, bytes[off..][0..2], .little);
        if (m != magic) break;
        if (t.count == max_entries) return Error.TooManyEntries;
        var e: Entry = .{
            .kind = bytes[off + 2],
            .subtype = bytes[off + 3],
            .offset = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little),
            .size = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little),
            .label = undefined,
        };
        @memcpy(&e.label, bytes[off + 12 ..][0..16]);
        t.entries[t.count] = e;
        t.count += 1;
    }
    if (t.count == 0) return Error.BadMagic;
    return t;
}

/// 从 flash 读出真实分区表。缓冲区是模块级静态量，不占启动栈。
var table_buf: [table_max_len]u8 align(4) = undefined;

pub fn readFlashTable() (Error || flash.Error)!Table {
    const words: [*]u32 = @ptrCast(@alignCast(&table_buf));
    flash.read(table_offset, words[0 .. table_max_len / 4]) catch |e| switch (e) {
        else => return Error.ReadFailed,
    };
    return parse(&table_buf);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// 真实产物前 3 条（`firmware/idf-bootstrap/build/partition_table/partition-table.bin`
/// 的前 0x60 字节）：nvs / phy_init / factory。用来把解析器钉在真实字节上。
const fixture_prefix = [_]u8{
    0xaa, 0x50, 0x01, 0x02, 0x00, 0x90, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x6e, 0x76, 0x73, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xaa, 0x50, 0x01, 0x01, 0x00, 0xf0, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x70, 0x68, 0x79, 0x5f,
    0x69, 0x6e, 0x69, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xaa, 0x50, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x70, 0x17, 0x00, 0x66, 0x61, 0x63, 0x74,
    0x6f, 0x72, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

test "partition: 解析真实分区表前缀（nvs/phy_init/factory）" {
    var bytes: [table_max_len]u8 = @splat(0xFF);
    @memcpy(bytes[0..fixture_prefix.len], &fixture_prefix);
    const t = try parse(&bytes);
    try testing.expectEqual(@as(usize, 3), t.count);

    const nvs = t.find("nvs").?;
    try testing.expectEqual(@as(u8, 0x01), nvs.kind);
    try testing.expectEqual(@as(u8, 0x02), nvs.subtype);
    try testing.expectEqual(@as(u32, 0x9000), nvs.offset);
    try testing.expectEqual(@as(u32, 0x6000), nvs.size);

    const f = t.find("factory").?;
    try testing.expectEqual(@as(u32, 0x10000), f.offset);
    try testing.expectEqual(@as(u32, 0x177000), f.size);
    try testing.expect(f.isApp());

    // 没有 OTA 槽的表现在必须如实报告
    try testing.expect(t.findApp(Subtype.ota_0) == null);
    try testing.expect(t.otadata() == null);
}

test "partition: 带 ota_0/ota_1/otadata 的表" {
    var bytes: [table_max_len]u8 = @splat(0xFF);
    @memcpy(bytes[0..fixture_prefix.len], &fixture_prefix);

    const extras = [_]struct { kind: u8, sub: u8, off: u32, size: u32, label: []const u8 }{
        .{ .kind = 0x00, .sub = 0x10, .off = 0x190000, .size = 0x180000, .label = "ota_0" },
        .{ .kind = 0x00, .sub = 0x11, .off = 0x310000, .size = 0x180000, .label = "ota_1" },
        .{ .kind = 0x01, .sub = 0x00, .off = 0x490000, .size = 0x2000, .label = "otadata" },
    };
    var off: usize = fixture_prefix.len;
    for (extras) |x| {
        std.mem.writeInt(u16, bytes[off..][0..2], magic, .little);
        bytes[off + 2] = x.kind;
        bytes[off + 3] = x.sub;
        std.mem.writeInt(u32, bytes[off + 4 ..][0..4], x.off, .little);
        std.mem.writeInt(u32, bytes[off + 8 ..][0..4], x.size, .little);
        @memset(bytes[off + 12 .. off + 28], 0);
        @memcpy(bytes[off + 12 ..][0..x.label.len], x.label);
        off += entry_len;
    }

    const t = try parse(&bytes);
    try testing.expectEqual(@as(usize, 6), t.count);
    try testing.expectEqual(@as(u32, 0x190000), t.findApp(Subtype.ota_0).?.offset);
    try testing.expectEqual(@as(u32, 0x310000), t.findApp(Subtype.ota_1).?.offset);
    const od = t.otadata().?;
    try testing.expectEqual(@as(u32, 0x490000), od.offset);
    try testing.expectEqual(@as(u32, 0x2000), od.size);
    try testing.expectEqualStrings("otadata", od.name());
}

test "partition: 空 flash（全 0xFF）报 BadMagic 而不是假装成功" {
    const blank: [table_max_len]u8 = @splat(0xFF);
    try testing.expectError(Error.BadMagic, parse(&blank));
}

test "partition: 条目上限被守住" {
    var bytes: [max_entries * entry_len]u8 = @splat(0xFF);
    var off: usize = 0;
    while (off < bytes.len) : (off += entry_len) {
        std.mem.writeInt(u16, bytes[off..][0..2], magic, .little);
    }
    var t = try parse(&bytes);
    try testing.expectEqual(max_entries, t.count);
    _ = &t;
}
