//! firmware：串口输出。
//!
//! 全部走 `hw.rawWrite`/`hw.rawLine`（有界、FIFO 满时放弃）：**不用 ROM 的
//! `esp_rom_printf`——它在 TX FIFO 满时会无限自旋（PC 采样实测 66 条样本落在那）。
//!
//! 先 `std.fmt.bufPrint` 再 `%s` 输出，而不是把格式串交给 ROM：
//! ROM 的格式化器不认识 Zig 的 `{x}`/`{d}` 语法，而本工程自检要打印十六进制
//! 校验和与十进制统计。所有输出都在当前栈上格式化，一次 `%s` 写完；
//! panic 路径因此不会依赖堆，也不会被行缓冲卡住。

const std = @import("std");

const hw = @import("hw.zig");
// 不再用 ROM 的 esp_rom_printf：它在 TX FIFO 满时会无限自旋（PC 采样实测）。

/// 一行输出。格式串不需要自带换行；超过 200 字节的行会被截断，不越界。
pub fn line(comptime fmt: []const u8, args: anytype) void {
    var buf: [202:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..200], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    const out: [:0]const u8 = buf[0 .. text.len + 1 :0];
    hw.rawWrite(out);
}

/// 只输出一段编译期常量（零格式化开销）。
pub fn raw(comptime text: [:0]const u8) void {
    hw.rawWrite(text);
}
