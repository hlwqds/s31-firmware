//! tools/qemu-instr 的测量模块之一：量一个组件的**整份板侧自检**（模块 `selftest`，入口 `run() bool`；
//! 板级接口由模块 `board` 提供，见 `board_stub_bare.zig` / `board_stub_time.zig`）。
//! 打印自检本体的指令数与 `ok`。
const root = @import("root");
const selftest = @import("selftest");

pub fn run() u32 {
    const t0 = root.minstret();
    const ok = selftest.run();
    const t1 = root.minstret();
    root.report("instr={d} ok={d}\r\n", .{ t1 - t0, @intFromBool(ok) });
    return if (ok) 0 else 1;
}
