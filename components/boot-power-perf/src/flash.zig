//! SPI flash 的最小封装（只依赖掩膜 ROM），C5 的 OTA 落盘用它。
//!
//! 移植自 `practice/zig-esp32-s31/ch23-tls-emac-lab/src/flash.zig`（该版本已在
//! 同一块板上实测：擦 4 扇区 + 写入 + 回读 SHA-256 与主机载荷一致，
//! 见 ch23 的 `logs/ch23-ota-flash.log`）。本文件只做工程化调整，行为不变。
//!
//! 三个函数来自 ROM，地址由 `boards/esp32s31-coreboard/linker/s31.ld` 的 PROVIDE 提供：
//!   esp_rom_spiflash_read         = 0x2f80016c
//!   esp_rom_spiflash_write        = 0x2f800168
//!   esp_rom_spiflash_erase_sector = 0x2f800160
//! 出处：IDF v6.1 `components/esp_rom/esp32s31/ld/esp32s31.rom.ld`；
//! 签名出处：同版本的 `esp_rom_spiflash.h`。
//!
//! 本模块只做四件事：
//!   1) 把"偏移"而不是"XIP 地址"作为唯一参数；
//!   2) 在调用前检查 4 字节对齐、长度、边界；
//!   3) 把返回码 0 翻译成 `void`，非 0 翻译成错误；
//!   4) 用一个很短的临界窗口（清 mstatus.MIE）包住写/擦。
//!
//! 关于 cache：生产的 `s31.ld` 把代码放在 IROM、只读数据放在 DROM，也就是 **XIP**。
//! 从 flash 常驻代码擦写 flash 这件事在 ch09/ch23 都已实测可行，但**换布局、
//! 换 ROM 版本或换 flash 型号必须重测**。写/擦期间仍屏蔽 MIE。
//!
//! 关于对齐：ROM 的原型是 `uint32_t *`，长度按**字节**计。缓冲必须是 4 字节对齐的
//! `[]u32`，长度天然是 4 的倍数；用 `[]u8` 调过去在 C 侧就是未对齐访问。

const std = @import("std");
const builtin = @import("builtin");

/// 主机侧（x86_64）没有掩膜 ROM。所有入口在主机上一律返回 `NotOnTarget`，
/// 而 `on_target` 是 **comptime 常量**，所以主机构建里 ROM 调用整段被消除，
/// `zig test` 不会去找那三个 extern 符号。
pub const on_target = builtin.target.os.tag == .freestanding;

/// 擦除单位：4 KiB。
pub const sector_size: u32 = 0x1000;

/// 模组 ESP32-S31-WROOM-3（N16R16V）的容量，仅用于边界检查。
pub const flash_size: u32 = 16 * 1024 * 1024;

extern fn esp_rom_spiflash_read(src_address: u32, dst_data: [*]u32, len_bytes: u32) c_int;
extern fn esp_rom_spiflash_write(target_address: u32, src_data: [*]const u32, len_bytes: u32) c_int;
extern fn esp_rom_spiflash_erase_sector(sector_number: u32) c_int;

pub const Error = error{
    NotOnTarget,
    UnalignedOffset,
    UnalignedLength,
    OutOfRange,
    ReadFailed,
    WriteFailed,
    EraseFailed,
    VerifyFailed,
};

/// 短临界窗口：写/擦期间不允许中断插进来。
///
/// 只动 `mstatus.MIE`，恢复时也只把它还原成进入前的值，因此不会"顺手"打开
/// 某个中断源。用 `csrrci/csrsi` 的立即数形式，不依赖寄存器分配。
const Critical = struct {
    saved: u32,

    fn begin() Critical {
        var old: u32 = undefined;
        asm volatile ("csrrci %[old], mstatus, 8"
            : [old] "=r" (old),
        );
        return .{ .saved = old };
    }

    fn end(self: Critical) void {
        if ((self.saved & 0x8) != 0) {
            asm volatile ("csrsi mstatus, 8");
        }
    }
};

fn check(offset: u32, len: u32) Error!void {
    if (offset % 4 != 0) return Error.UnalignedOffset;
    if (len % 4 != 0) return Error.UnalignedLength;
    const end = @as(u64, offset) + @as(u64, len);
    if (end > flash_size) return Error.OutOfRange;
}

/// 读 `dst.len * 4` 字节到 `dst`。`dst` 必须 4 字节对齐。
pub fn read(offset: u32, dst: []u32) Error!void {
    if (!on_target) return Error.NotOnTarget;
    try check(offset, @intCast(dst.len * 4));
    if (esp_rom_spiflash_read(offset, dst.ptr, @intCast(dst.len * 4)) != 0) {
        return Error.ReadFailed;
    }
}

/// 读任意字节长度的便捷包装：偏移与长度都必须 4 字节对齐。
///
/// 只接受对齐的 `[]u8`，用 `@alignCast` 在编译期之外显式断言对齐。
pub fn readBytes(offset: u32, dst: []align(4) u8) Error!void {
    if (dst.len % 4 != 0) return Error.UnalignedLength;
    const words: [*]u32 = @ptrCast(@alignCast(dst.ptr));
    try read(offset, words[0 .. dst.len / 4]);
}

/// 写 `src.len * 4` 字节。目标区域必须已经擦过（全 0xFF）。
pub fn write(offset: u32, src: []const u32) Error!void {
    if (!on_target) return Error.NotOnTarget;
    try check(offset, @intCast(src.len * 4));
    const guard = Critical.begin();
    defer guard.end();
    if (esp_rom_spiflash_write(offset, src.ptr, @intCast(src.len * 4)) != 0) {
        return Error.WriteFailed;
    }
}

/// 写任意字节长度（4 字节对齐）。不足一个字的部分由调用方自行补齐。
pub fn writeBytes(offset: u32, src: []align(4) const u8) Error!void {
    if (src.len % 4 != 0) return Error.UnalignedLength;
    const words: [*]const u32 = @ptrCast(@alignCast(src.ptr));
    try write(offset, words[0 .. src.len / 4]);
}

/// 擦除包含 `offset` 的整个 4 KiB 扇区。
///
/// ROM 的参数是**扇区号**（`offset / 0x1000`），不是地址；传地址会擦到
/// 一个完全无关的位置，而且控制器不会报错。
pub fn eraseSector(offset: u32) Error!void {
    if (!on_target) return Error.NotOnTarget;
    if (offset % sector_size != 0) return Error.UnalignedOffset;
    if (offset >= flash_size) return Error.OutOfRange;
    const guard = Critical.begin();
    defer guard.end();
    if (esp_rom_spiflash_erase_sector(offset / sector_size) != 0) {
        return Error.EraseFailed;
    }
}

/// 写后立刻读回比对：ROM 的返回码只代表控制器报告完成，
/// 不代表阵列里真的落下了这些字节。
pub fn writeVerified(offset: u32, words: []const u32) Error!void {
    try write(offset, words);

    // 分块读回，避免为任意长度在栈上开大数组。
    var back: [16]u32 align(4) = undefined;
    var i: usize = 0;
    while (i < words.len) {
        const n = @min(words.len - i, back.len);
        try read(offset + @as(u32, @intCast(i * 4)), back[0..n]);
        if (!std.mem.eql(u32, words[i..][0..n], back[0..n])) {
            return Error.VerifyFailed;
        }
        i += n;
    }
}
