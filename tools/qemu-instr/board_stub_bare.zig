//! tools/qemu-instr 用的 `board` 模块（量指令数时顶替 `boards/` 的真板级模块）。
//! 行为与主机桩一致：日志不打印（量的是自检本体，不含串口输出），`nowUs` 恒为 0。
//! 适用于不依赖真实时间流逝的自检（`wifi_connect`、`wifi_mlme`、`ble_802154`、`ble_security`、
//! `radio_coex`、`wifi_boundary` 等——它们在主机上也是这样跑的）。
//! 依赖时间推进的自检用 `board_stub_time.zig`。
pub const log = struct {
    pub fn line(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn raw(bytes: []const u8) void {
        _ = bytes;
    }
};
pub const hw = struct {
    pub fn nowUs() u64 {
        return 0;
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
