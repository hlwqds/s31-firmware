//! libc 胶水：wifi 核归档引用的 4 个 libc 符号（探针是 freestanding，无 libc）。
//! putchar/puts 走 osal.logPublic（UART 有界写）；strcmp/strtok 用 std 实现。

const std = @import("std");
const osal = @import("osal_kit").osal;

export fn putchar(c: c_int) c_int {
    const byte: u8 = @truncate(@as(u32, @bitCast(c)));
    var one: [2]u8 = .{ byte, 0 };
    osal.logPublic("{s}", .{@as([*:0]const u8, &one)});
    return c;
}

export fn puts(s: [*:0]const u8) c_int {
    osal.logPublic("{s}", .{s});
    return 1; // 非负即可
}

export fn strcmp(s1: [*:0]const u8, s2: [*:0]const u8) c_int {
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) i += 1;
    if (s1[i] < s2[i]) return -1;
    if (s1[i] > s2[i]) return 1;
    return 0;
}

var strtok_state: ?[*:0]u8 = null;

export fn strtok(s1: ?[*:0]u8, delim: [*:0]const u8) ?[*:0]u8 {
    _ = delim;
    if (s1) |p| strtok_state = p else if (strtok_state == null) return null;
    const start = strtok_state.?;
    if (start[0] == 0) return null;
    strtok_state = start + 1;
    return start;
}
