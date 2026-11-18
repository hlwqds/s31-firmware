//! BLE bring-up 的**门控测量**：`r_btdm_task_init` 偏移 0x66 处的三个数。
//!
//! 这段代码原本嵌在 `osal.zig` 的 `mutexPend()` 里（每次无争用取锁都跑一遍）。它的地址
//! （`0x2f00_ffd0` 的 10 个 per-object 锚点）和 `probe_ptr` 都是 **bt-blobs 专有**的，
//! 放在通用内核里既污染了内核、又让每次取锁都往 UART 灌 15 行。2026-11-18 迁到这里，
//! 由 `probe.zig` 通过 `Hooks.on_mutex_acquired` 注册。
//!
//! 日志格式与迁出前**逐字相同**（`bt gate: ` / `bt env: ` / `bt P:   ` / `bt anchor[`），
//! 所以板上抓到的日志与历史记录可以直接对比。
//!
//! 三个数（2026-11 的 BLE 定位结论）：
//! - `env`     = 21.o 锚点（`OkE7` 发布的 76 B 环境）
//! - `*(env+8)`= `OkE7` 里 `fqmZk` 的守卫所读字段（应为 eventq 槽位指针）
//! - `P`       = 2.o 锚点（由 `fqmZk` 设置；为 0 则 `2aNN` 会向地址 0 写）
const std = @import("std");
const osal = @import("osal_kit").osal;
const pp = @import("probe_ptr.zig");

const logLine = osal.logLine;

/// 打印锚点表（基址 `0x2f00ffd0`，10 个槽）的一行快照，供"某操作前后"对读。
pub fn dumpAnchors(tag: []const u8) void {
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    var w: usize = 0;
    while (i < 10) : (i += 1) {
        const v = (@as(*volatile u32, @ptrFromInt(0x2f00_ffd0 + i * 4))).*;
        const n = std.fmt.bufPrint(buf[w..], " {x}", .{v}) catch break;
        w += n.len;
    }
    logLine("bt anchors[{s}]:{s}", .{ tag, buf[0..w] });
}

pub fn probeAnchors() void {
    const env = pp.okE7Anchor();
    const env8: u32 = if (env != 0) (@as(*volatile u32, @ptrFromInt(env + 8))).* else 0;
    logLine("bt gate: env=0x{x} *(env+8)=0x{x} P=0x{x}", .{ env, env8, pp.get() });
    if (env == 0) return;
    // **env 内容**：与 oracle 的 X[0..7] 对拍，看 [16]/[20] 是否是 env+52/env+64
    const e: [*]volatile u32 = @ptrFromInt(env);
    logLine("bt env: [0]=0x{x} [1]=0x{x} [2]=0x{x} [3]=0x{x}", .{ e[0], e[1], e[2], e[3] });
    logLine("bt env: [4]=0x{x} [5]=0x{x} [6]=0x{x} [7]=0x{x}", .{ e[4], e[5], e[6], e[7] });
    // `P` 被 `deinit` 的 `gvLJK` 当作**链表头**：`a3 = P; a5 = *(P); ...`
    // 若 `*(P)` 是垃圾，遍历/摘链就会 store 到野地址 ⇒ 这正是 deinit 的 fault。
    const pv = pp.get();
    if (pv == 0) return;
    const pl: [*]volatile u32 = @ptrFromInt(pv);
    logLine("bt P:   [0]=0x{x} [1]=0x{x} [2]=0x{x} [3]=0x{x}", .{ pl[0], pl[1], pl[2], pl[3] });
    // **10 个 per-object 锚点全表**（最终镜像里 `B r_sym_bt_*` 的完整集合）。
    // 非 0 = 已被归档自己发布；0 = 无人发布 ⇒ 后续消费它就是一次向 0 的访问。
    const names = [_][:0]const u8{
        "pSy5Wex1v0iXw5RdWtwL", "WDq2rzn4KRWP5mort5eS", "YnZmsxu068uuC3PC4iu8",
        "kfu8vf8dQgqwEzvqhb3d", "d3D3sk5KewclELfrD5xa", "sitBB3SrXn0IePgsPrBY",
        "r4auAKWSAFwgQarMHZCc", "lRdavKxt45o0gicEyznn", "6Q68KSwuQQP4VjQGqiWa",
        "y5Dip5N8bwiiGRcrWzBO",
    };
    var k: usize = 0;
    while (k < names.len) : (k += 1) {
        const v = (@as(*volatile u32, @ptrFromInt(0x2f00_ffd0 + k * 4))).*;
        logLine("bt anchor[{d}] {s} = 0x{x}", .{ k, names[k], v });
    }
}
