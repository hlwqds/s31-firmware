//! tools/qemu-instr 用的 `board` 模块，**时钟会走**：`nowUs()` 返回「已执行指令数 ÷ 80」。
//! 板子 80 MHz、每条约 1 周期（`cal.zig` 的校准），于是自检里按时间等待的循环在仿真里按板子的
//! 速度推进，等待本身消耗的指令被如实数进去——自检最后打印的「指令数 ÷ 80」就是它的虚拟耗时（微秒）。
//! 日志不打印。用于带超时、重传之类真实等待的自检（网络组、POSIX）。
pub const log = struct {
    pub fn line(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn raw(bytes: []const u8) void {
        _ = bytes;
    }
};

fn minstret() u64 {
    var hi: u32 = 0;
    var lo: u32 = 0;
    var hi2: u32 = 0;
    while (true) {
        hi = asm volatile ("csrrs %[v], 0xb82, x0"
            : [v] "=r" (-> u32),
        );
        lo = asm volatile ("csrrs %[v], 0xb02, x0"
            : [v] "=r" (-> u32),
        );
        hi2 = asm volatile ("csrrs %[v], 0xb82, x0"
            : [v] "=r" (-> u32),
        );
        if (hi == hi2) break;
    }
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

pub const hw = struct {
    pub fn nowUs() u64 {
        return minstret() / 80;
    }
};

/// 自检里用 `board.trap.panic(…)` 断言；走到这里就是自检自己发现错了，停住（不会打印，也不会走到结果行）。
pub const trap = struct {
    pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
        _ = fmt;
        _ = args;
        @trap();
    }
};
