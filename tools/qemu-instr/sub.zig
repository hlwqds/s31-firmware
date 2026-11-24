//! tools/qemu-instr 的测量模块之一：量**一份板侧子自检**（模块 `s`，入口 `run(check)`）。
//! `check` 回调什么都不做，只计数：量的是纯计算，不含串口打印。
const std = @import("std");
const root = @import("root");
const s = @import("s");

var n: usize = 0;
var bad: usize = 0;

fn check(ok: bool, text: []const u8) void {
    _ = text;
    n += 1;
    if (!ok) bad += 1;
}

pub fn run() u32 {
    const t0 = root.minstret();
    s.run(check);
    const t1 = root.minstret();
    root.report("instr={d} checks={d} bad={d}\r\n", .{ t1 - t0, n, bad });
    return if (bad == 0) 0 else 1;
}
