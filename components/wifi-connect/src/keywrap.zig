//! wifi-connect：AES Key Wrap / Unwrap，128 位或 256 位 KEK（RFC 3394 §2.2.1、§2.2.2）。
//!
//! 802.11-2016 12.7.2 b) 1) ii)、iii)：Key Descriptor Version 2/3 的 EAPOL-Key 帧用
//! 「NIST AES key wrap」保护 Key Data 字段。KEK 的长度由 12.7.3 表 12-8（印刷页 2027）
//! 给出：AKM 00-0F-AC:1 到 9 与 11 是 128 位，AKM 00-0F-AC:12、13 是 256 位。
//! RFC 3394 §2：KEK 可以是 AES 支持的任意密钥长度，算法本身不随密钥长度改变；
//! §4.3、§4.5、§4.6 是 256 位 KEK 的向量（128、192、256 位的 Key Data）。
//! 本文件只做这一件事：把一段不小于 16 字节、长度为 8 的倍数的明文包成
//! 明文长度 + 8 字节的密文，以及反过来。
//!
//! 实现按 RFC 3394 §2.2.1 的「索引法」原地计算：把缓冲看成 n+1 个 64 位块，
//! 第 0 块是 64 位完整性寄存器 A，第 1..n 块是 R[i]。块内按大端读写
//! （RFC 3394 §2.1 的 MSB/LSB 指的是位串的先后次序，与主机字节序无关）。
//!
//! 不用分配器：调用方给输出缓冲，块数组放在栈上（最多 `max_plain / 8 + 1` 块）。
//! 本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");
const aes = std.crypto.core.aes;

pub const kek_len = 16;
/// AKM 00-0F-AC:12、13 的 KEK 长度（表 12-8，印刷页 2027）。
pub const kek_len_256 = 32;
/// 一次最多包裹的明文字节数。消息 3 的 Key Data = RSNE + GTK KDE + IGTK KDE，填充到 8 的
/// 倍数后包裹。128 位套件下两个 KDE 是 24 与 30 字节；256 位套件下 GTK KDE 是 40 字节
/// （图 12-35：头 6 + Key ID/Tx 1 + Reserved 1 + GTK 32），IGTK KDE 是 46 字节
/// （图 12-42：头 6 + Key ID 2 + IPN 6 + IGTK 32），RSNE 不超过 38 字节时合计仍在这个
/// 上限内；更长的 RSNE 报 `TooLong`，上限没有为本轮放宽。
pub const max_plain = 128;
/// 密文比明文多 8 字节（多出一个完整性寄存器块）。
pub const wrap_overhead = 8;
pub const max_wrapped = max_plain + wrap_overhead;
/// RFC 3394 §2.2.3.1 的默认初始值 A6A6A6A6A6A6A6A6。
pub const iv: u64 = 0xa6a6_a6a6_a6a6_a6a6;

pub const Error = error{
    /// 输入少于两个 64 位块：RFC 3394 §2 规定 n 至少为 2。
    TooShort,
    /// 长度不是 8 的倍数（调用方应先按 12.7.2 j) 填充）。
    NotMultipleOf8,
    /// 明文超过 `max_plain`。
    TooLong,
    /// 输出缓冲不够。
    BufferTooSmall,
    /// 解包后 A ≠ IV：密文或 KEK 不对（RFC 3394 §2.2.2 第 3 步）。
    Integrity,
};

const block_count = max_plain / 8 + 1;

/// 明文 `plain_len` 对应的密文长度；长度非法时返回对应错误。
pub fn wrappedLen(plain_len: usize) Error!usize {
    if (plain_len < 2 * 8) return error.TooShort;
    if (plain_len % 8 != 0) return error.NotMultipleOf8;
    if (plain_len > max_plain) return error.TooLong;
    return plain_len + wrap_overhead;
}

fn loadBlock(buf: []const u8, index: usize) u64 {
    return std.mem.readInt(u64, buf[index * 8 ..][0..8], .big);
}

fn storeBlock(buf: []u8, index: usize, value: u64) void {
    std.mem.writeInt(u64, buf[index * 8 ..][0..8], value, .big);
}

fn beBytes(value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, value, .big);
    return out;
}

/// 常量时间比较两个 64 位整数是否相等。
fn ctEql(a: u64, b: u64) bool {
    return std.crypto.timing_safe.eql([8]u8, beBytes(a), beBytes(b));
}

/// RFC 3394 §2.2.1 索引法：j = 0..5，i = 1..n，t = n·j + i。`Aes` 是 128 位或 256 位的 AES。
fn wrapWith(comptime Aes: type, kek: [Aes.key_bits / 8]u8, plain: []const u8, out: []u8) Error!usize {
    const total = try wrappedLen(plain.len);
    if (out.len < total) return error.BufferTooSmall;
    const n = plain.len / 8;

    var blocks: [block_count]u64 = undefined;
    blocks[0] = iv;
    for (0..n) |i| blocks[i + 1] = loadBlock(plain, i);

    const ctx = Aes.initEnc(kek);
    for (0..6) |j| {
        for (1..n + 1) |i| {
            const t: u64 = n * j + i;
            var buf: [16]u8 = undefined;
            @memcpy(buf[0..8], &beBytes(blocks[0]));
            @memcpy(buf[8..16], &beBytes(blocks[i]));
            var b: [16]u8 = undefined;
            ctx.encrypt(&b, &buf);
            blocks[0] = std.mem.readInt(u64, b[0..8], .big) ^ t;
            blocks[i] = std.mem.readInt(u64, b[8..16], .big);
        }
    }

    for (0..n + 1) |i| storeBlock(out, i, blocks[i]);
    return total;
}

/// 用 128 位 KEK 包裹明文，输出写入 `out`，返回写入长度（`plain.len + 8`）。
pub fn wrap(kek: [kek_len]u8, plain: []const u8, out: []u8) Error!usize {
    return wrapWith(aes.Aes128, kek, plain, out);
}

/// 同 `wrap`，KEK 是 256 位（AKM 00-0F-AC:12、13，表 12-8）。
pub fn wrap256(kek: [kek_len_256]u8, plain: []const u8, out: []u8) Error!usize {
    return wrapWith(aes.Aes256, kek, plain, out);
}

/// RFC 3394 §2.2.2 索引法：j = 5..0，i = n..1，t 从 6n 递减。
fn unwrapWith(comptime Aes: type, kek: [Aes.key_bits / 8]u8, wrapped: []const u8, out: []u8) Error!usize {
    if (wrapped.len < 2 * 8 + wrap_overhead) return error.TooShort;
    if (wrapped.len % 8 != 0) return error.NotMultipleOf8;
    if (wrapped.len > max_wrapped) return error.TooLong;
    const total = wrapped.len - wrap_overhead;
    if (out.len < total) return error.BufferTooSmall;
    const n = total / 8;

    var blocks: [block_count]u64 = undefined;
    for (0..n + 1) |i| blocks[i] = loadBlock(wrapped, i);

    const ctx = Aes.initDec(kek);
    var t: u64 = 6 * n;
    var j: usize = 6;
    while (j > 0) {
        j -= 1;
        var i: usize = n + 1;
        while (i > 1) {
            i -= 1;
            var buf: [16]u8 = undefined;
            @memcpy(buf[0..8], &beBytes(blocks[0] ^ t));
            @memcpy(buf[8..16], &beBytes(blocks[i]));
            var b: [16]u8 = undefined;
            ctx.decrypt(&b, &buf);
            blocks[0] = std.mem.readInt(u64, b[0..8], .big);
            blocks[i] = std.mem.readInt(u64, b[8..16], .big);
            t -= 1;
        }
    }

    // RFC 3394 §2.2.2 第 3 步：A 不是初始值就报错，不输出明文。
    if (!ctEql(blocks[0], iv)) return error.Integrity;

    for (0..n) |i| storeBlock(out, i, blocks[i + 1]);
    return total;
}

/// 用 128 位 KEK 解包密文，明文写入 `out`，返回明文长度。
/// A 的比较是常量时间的；失败时 `out` 不被写入。
pub fn unwrap(kek: [kek_len]u8, wrapped: []const u8, out: []u8) Error!usize {
    return unwrapWith(aes.Aes128, kek, wrapped, out);
}

/// 同 `unwrap`，KEK 是 256 位（AKM 00-0F-AC:12、13，表 12-8）。
pub fn unwrap256(kek: [kek_len_256]u8, wrapped: []const u8, out: []u8) Error!usize {
    return unwrapWith(aes.Aes256, kek, wrapped, out);
}
