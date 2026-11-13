//! 生产固件入口：按构建开关组合子系统自检，跑完后停机。
const board = @import("board");
const enabled = @import("enabled");

pub export fn main() noreturn {
    board.log.raw("s31-firmware boot\n");
    var n: u32 = 0;
    var failed: u32 = 0;
    inline for (enabled.entries) |e| {
        board.log.line("section: {s}", .{e.name});
        if (!e.run()) failed += 1;
        n += 1;
    }
    board.log.line("firmware: sections: passed={d} failed={d} total={d}", .{ n - failed, failed, n });
    board.log.line("main: verdict={s}", .{if (failed == 0) "pass" else "fail"});
    board.hw.halt();
}
