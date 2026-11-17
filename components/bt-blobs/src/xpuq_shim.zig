//! 接管归档的 `r_sym_bt_2aNN`（`libbtdm_common/2.o`）。
//!
//! 原实现只有四条指令：
//!
//! ```asm
//! lui  a5, .LANCHOR0       ; 2.o 的锚点 = r_sym_bt_d3D3sk5KewclELfrD5xa（即 P）
//! lw   a5, 0(a5)           ; a5 = P
//! sw   zero, 0(a5)         ; *(u32*)P = 0      ← P 为 NULL 时向地址 0 写
//! sw   a5, 4(a5)           ; *(u32*)(P+4) = P
//! ret
//! ```
//!
//! `P` 为 NULL 时那条 store 落在地址 0，事务永不退休：无异常、无采样、
//! 后续的建任务与任务体都不会发生 —— 与板侧观测完全一致。
//!
//! 这里给一个强定义：**先把 P 打出来（诊断），P 为 NULL 就跳过那两条 store（解阻）**，
//! 其余行为与原实现一致。

const builtin = @import("builtin");
const on_target = builtin.target.os.tag == .freestanding;

extern var r_sym_bt_d3D3sk5KewclELfrD5xa: u32;

pub fn run() void {
    if (!on_target) return;
    const p = r_sym_bt_d3D3sk5KewclELfrD5xa;
    @import("osal.zig").logLine("bt shim: 2aNN 进入 P=0x{x:0>8}", .{p});
    if (p == 0) {
        @import("osal.zig").logLine("bt shim: P==NULL ⇒ 跳过向地址 0 的零填充", .{});
        return;
    }
    const q: [*]u32 = @ptrFromInt(p);
    q[0] = 0;
    q[1] = p;
}

export fn r_sym_bt_2aNNQgpuVlZoKiS5xEYJ() callconv(.c) void {
    run();
}
