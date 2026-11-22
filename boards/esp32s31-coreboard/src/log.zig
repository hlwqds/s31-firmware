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

/// 一行输出。格式串不需要自带换行。
/// **超过 200 字节不再静默丢弃** —— 打印截断标记并计数（`line_trunc`）。
/// 历史：曾用 `catch return` 整行吞掉，本会话两次因此误判"程序没走到"。
/// 被截断的行数（可观测）。
pub var line_trunc: u32 = 0;

/// **轮 94b**：UART 静默开关——0x200A 后 blob 门控 UART0 时钟 ⇒ 任何打印
/// 都会卡死在 ROM FIFO 等待环（0x2f8036cc，NMI 实测）。置位后 line() 直接
/// no-op，结果经 flash marker（0x18F000）离线判读。
pub var muted: bool = false;

pub fn line(comptime fmt: []const u8, args: anytype) void {
    if (muted) return;
    var buf: [202:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..200], fmt, args) catch {
        // **不再静默丢弃**：超长的行以前会被整行吞掉且不留痕迹（本会话两次
        // 因此误判"程序没走到"）。现在打印前缀 + 明确的截断标记。
        line_trunc += 1;
        const t = std.fmt.bufPrint(&buf, "[LOGLINE TRUNCATED >200B #{d}]\n", .{line_trunc}) catch return;
        hw.rawWrite(buf[0..t.len :0]);
        return;
    };
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    const out: [:0]const u8 = buf[0 .. text.len + 1 :0];
    hw.rawWrite(out);
}

/// 只输出一段编译期常量（零格式化开销）。
pub fn raw(comptime text: [:0]const u8) void {
    hw.rawWrite(text);
}
