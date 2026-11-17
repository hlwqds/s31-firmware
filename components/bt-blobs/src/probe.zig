//! BLE controller 的板上探针：`init` → `enable` → 进任务 → 发 HCI Reset → 打回程字节。
//!
//! 只在 `-Dbt-probe` 的构建里跑（照 `wifi-init-probe` 的模式）。**绝不与 wifi blob 同镜像**：
//! 两套 arena/队列都是按"协作式、无抢占"写的，共存会偶发损坏。
//!
//! ## 顺序（三个点错一个就白跑一趟）
//!
//! 1. **arena 最先初始化**：`r_btdm_task_init` 内部会调我们的 `task_create`，它要从 arena
//!    分 8 KiB 栈；arena 没初始化 ⇒ `alloc` 返回 null ⇒ `task_create` 返 ENOMEM ⇒
//!    init 链**第 4 步**失败，报错会指向"task_init 失败"而不是"arena 没初始化"。
//! 2. `init` 链（15 步，含 `transport.init`）→ `enable` 链（6 步，末尾 `r_btdm_task_enable`）。
//! 3. **必须 `sched.startScheduler()` 才会真正进任务**——只 `task_create` 是"登记"，
//!    任务永远不跑。之后主循环周期 `resumeTask`：正常情况下 controller 走
//!    "归档 → 我们的 `semRelease`/`eventqPut` → resume" 这条路，但若它阻塞在我们没覆盖的
//!    内部队列上，没有周期重入就会永远停在那里。
//!
//! ## 日志怎么读
//!
//! | 现象 | 结论 |
//! | --- | --- |
//! | 没有 `bt task round` | 任务从没跑过（`start` 没生效 / 任务没建出来） |
//! | 有 round、命令已发、但没有 `EVT` | 任务跑了但没回包（→ 查切片 E / 时钟门控） |
//! | 有 `EVT` 但 status≠0 | 回包了但命令失败 |
const std = @import("std");
const builtin = @import("builtin");
const osal = @import("osal.zig");
const config = @import("config.zig");
const bringup = @import("bringup.zig");
const transport = @import("transport.zig");
const sched = @import("sched.zig");
const board = @import("board");

/// 链接脚本 `s31.ld` 的堆边界是**绝对符号**：取地址得到边界值，
/// 声明成 `usize` 会变成"去那个地址读一个 usize"。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}

var cfg: config.Config = .{};
var ctrl_task: ?*sched.Task = null;

// ---- 钩子：**必须在 init 链之前装**，否则最关键的观测手段就没了 ----

/// ⚠ 单位是**毫秒**：注入 `nowUs()/1000`。直接注入 `nowUs()` 会让所有超时窗口大 1000 倍，
/// 症状是"起来了但永远不超时/不动作"，极难归因。
fn nowMs() u32 {
    return @intCast(board.hw.nowUs() / 1000);
}
/// 同步刷到 UART（不缓冲）——切上下文后日志顺序才可信。
fn logHook(msg: []const u8) void {
    board.log.line("{s}", .{msg});
}
/// 当前不开中断 ⇒ 空实现；切片 E 真开中断后换成真的关/开。
fn irqSave() u32 {
    return 0;
}
fn irqRestore(_: u32) void {}
fn macHook(out: *[6]u8) void {
    // 出厂 MAC 还没接 efuse 读；先给本地管理地址兜底（0x02 开头）。
    out.* = .{ 0x02, 0x00, 0x00, 0x00, 0xBB, 0x01 };
}

pub fn run() noreturn {
    osal.setHooks(.{ .now_ms = nowMs, .log = logHook, .irq_save = irqSave, .irq_restore = irqRestore });
    osal.setMacHook(macHook);
    board.log.line("{s}", .{"bt probe: hooks installed (now_ms=us/1000)"});

    // 1) arena 最先
    const hs = @intFromPtr(heapStart());
    const he = @intFromPtr(heapEnd());
    if (he > hs) {
        const region = @as([*]u8, @ptrFromInt(hs))[0 .. he - hs];
        osal.initArena(region);
        osal.logPublic("bt probe: arena {d} B", .{he - hs});
    } else {
        osal.logPublic("bt probe: FATAL no heap region", .{});
        halt();
    }

    // 2) init 链（15 步）
    cfg = config.defaults();
    osal.logPublic("bt probe: init start", .{});
    var rc = bringup.init(&cfg);
    if (rc != 0) {
        osal.logPublic("bt probe: init FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    osal.logPublic("bt probe: init ok, arena free={d} B", .{osal.arenaFree()});

    // 3) enable 链（6 步）
    rc = bringup.enable();
    if (rc != 0) {
        osal.logPublic("bt probe: enable FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    osal.logPublic("bt probe: enabled (status={d})", .{bringup.getStatus()});

    // 4) 真正进任务（只有第一次用 startScheduler）
    ctrl_task = findFirstTask();
    if (ctrl_task) |t| {
        osal.logPublic("bt probe: entering controller task (stack={d} B)", .{t.stack_size});
        sched.startScheduler(t);
        osal.logPublic("bt probe: back in main (task blocked or returned)", .{});
    } else {
        osal.logPublic("bt probe: WARN no task was created by r_btdm_task_init", .{});
    }

    // 5) 发第一条命令并泵任务
    osal.logPublic("bt probe: sending HCI Reset", .{});
    rc = transport.sendResetViaHs();
    osal.logPublic("bt probe: sendReset rc={d}", .{rc});

    var round: u32 = 0;
    while (round < 200) : (round += 1) {
        osal.logPublic("bt task round {d}", .{round});
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        _ = osal.serviceCallouts(osal.timeGet());
        if (transport.stats().evt_count > 0) {
            osal.logPublic("bt probe: GOT {d} EVT, last code=0x{x:0>2}", .{ transport.stats().evt_count, transport.stats().last_evt_code });
            halt();
        }
    }
    osal.logPublic("bt probe: no EVT after {d} rounds (evt_count=0)", .{round});
    halt();
}

fn findFirstTask() ?*sched.Task {
    // sched 内部有任务表；这里通过一个公开访问器拿第一个已登记任务。
    return sched.firstTask();
}

fn halt() noreturn {
    while (true) {
        asm volatile ("" ::: .{ .memory = true });
    }
}
