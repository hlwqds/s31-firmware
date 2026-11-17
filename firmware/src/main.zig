//! 生产固件入口：按构建开关组合子系统自检，跑完后停机。
const board = @import("board");
const enabled = @import("enabled");

pub export fn main() noreturn {
    // `-Dwifi-init-probe` 打开时，入口换成 R3 探针（正常自检不跑）。
    // `enabled` 是 comptime 常量，关闭时整个分支被剪掉。
    const probe = @import("wifi_init_probe");
    if (probe.enabled) probe.run();
    // `-Dbt-probe` 打开时换成 BLE controller 探针（与 wifi 探针同构，二者互斥）
    const bt_probe = @import("bt_probe");
    if (bt_probe.enabled) bt_probe.run();
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
