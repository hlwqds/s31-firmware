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
const osal = @import("osal_kit").osal;

/// abort 桩里记录的**直接调用者地址**（C 侧全局）。
extern var g_abort_ra: u32;
extern var g_c_count: u32;

/// 供 C 侧 abort 桩调用：在崩溃瞬间把状态导出（不 halt）。
/// **周期性**打印 OSAL 计数器（不依赖任何触发点）。
/// 停滞期间由 trap 的心跳反复调用 ⇒ 最后一行就是停滞时的计数。
/// 第 2 次 `event_init` 时触发总 dump（**确定性**触发点，不依赖中断）。
/// 第 1 次 `eventq_init` 时 dump —— 此时已越过 init 链早期，
/// 计数器首次反映真实事件操作。
pub fn bt_hook_eventq_init(n: u32) void {
    if (n != 1) return;
    probe_dump_now();
}

pub fn bt_hook_event_init(n: u32) void {
    if (n != 2) return;
    probe_dump_now();
}

export fn bt_print_osal_stats() void {
    const st = osal.stats();
    board.log.line("Q1 {d} {d} {d}", .{ st.eventq_put, st.eventq_get_ok, st.eventq_get_empty });
    board.log.line("Q2 {d} {d} {d}", .{ st.mutex_pend_ok, st.mutex_pend_busy, st.blocked_calls });
    board.log.line("Q3 {d} {d}", .{ st.pool_exhausted, st.eventq_requeued });
}

export fn probe_dump_now() void {
    dump_done = false; // abort 时刻必须能再次导出（否则被 once-only 门挡住）
    // **OSAL 计数器**：判断"投递了但消费不到"还是"根本没投递"的关键
    {
        const st = osal.stats();
        board.log.line("Q1 {d} {d} {d}", .{ st.eventq_put, st.eventq_get_ok, st.eventq_get_empty });
        board.log.line("Q2 {d} {d} {d}", .{ st.mutex_pend_ok, st.mutex_pend_busy, st.blocked_calls });
        board.log.line("Q3 {d} {d}", .{ st.pool_exhausted, st.eventq_requeued });
        board.log.line("Q4 {d} {d}", .{ log_hook_calls, log_hook_ours });
        board.log.line("Q5 {d} {d} {d} {d}", .{ board.hw.rw_calls, board.hw.rw_bytes, board.hw.rw_drops, board.hw.rw_max_fifo });
    }
    dumpAtPend();
}
const config = @import("config.zig");
const bringup = @import("bringup.zig");
const transport = @import("transport.zig");
const sched = @import("osal_kit").sched;
const porting = @import("porting.zig");
const board = @import("board");

/// 归档里的 BT 基带初始化（`libbtbb.a` 提供；IDF 的 `esp_btbb_enable` 就是调它）。
extern fn bt_bb_v2_init_cmplx(version_print: c_int) c_int;

// **WiFi osi 栈**（wifi-blobs 移植件，本次综合的主线）
const osi_impl = @import("osi_impl.zig");
const init_config = @import("init_config.zig");
const osi = @import("osi.zig");
const s31_log_write = @extern(*const anyopaque, .{ .name = "s31_log_write" });
const libc_glue = @import("libc_glue.zig");
var osi_table: osi.Osi = undefined;

/// **本轮最深步骤号**（mark.put 单调递增；LP-RAM 跨 boot 累积用）。
/// LP-RAM 累积的 RAM 侧副本（FEFE 记录用，写 flash 在 FEFC 证据之后）。
pub var lp_boot_n: u32 = 0;
pub var lp_hist: [9]u32 = @splat(0);

/// 链接脚本 `s31.ld` 的堆边界是**绝对符号**：取地址得到边界值，
/// 声明成 `usize` 会变成"去那个地址读一个 usize"。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}

/// 是否在探针里开中断。默认 **false**：先排除"ISR 打印打断 ROM UART 写"这个变量。
// **必须是 false**：`true` 会 `routeT0Interrupt(25)` + 每 2 ms 打印，而
// CLIC input 25 **也是 BT 归档的 tick 源**（ADR-001:1185 候选 A、
// README:9991-9994）⇒ ① 控制器时序步进不推进（0x200A 永远等不到完成条件）
// ② ISR 每 2 ms 灌 UART ⇒ TX FIFO 打满（恒 128）⇒ 应用日志一行都出不来。
// 这同时解释了"串口零字节"与"0x200A 挂住"两个症状。
pub var probe_irqs: bool = false;

var cfg: config.Config = .{};
var ctrl_task: ?*sched.Task = null;

// ---- 钩子：**必须在 init 链之前装**，否则最关键的观测手段就没了 ----

/// ⚠ 单位是**毫秒**：注入 `nowUs()/1000`。直接注入 `nowUs()` 会让所有超时窗口大 1000 倍，
/// 症状是"起来了但永远不超时/不动作"，极难归因。
fn nowMs() u32 {
    return @intCast(board.hw.nowUs() / 1000);
}
/// **实验脚手架开关**（全部默认关）：这些是排查"卡在 0x2010B000"时用的一次性装置，
/// 保留是为了可复现，但默认不干扰正常 bring-up。
/// - `dump_rom`：启动时 dump ROM 区与 UART0 寄存器（离线反汇编用）
/// - `ble_block_experiment`：复位脉冲 + 时钟重开 + `bt_bb_v2_init_cmplx` + 读 `0x2010B000`
pub var dump_rom: bool = false;
/// **只做一次直读**（control read `0x20109C04` + `0x2010B000`），
/// 不触发 `ble_block_experiment` 那条「重置脉冲 + bt_bb_v2_init_cmplx」的重路径。
pub var bt_block_read_only: bool = false; // 复现用；默认关（开启后每次开机读一次 0x2010B000）

pub var ble_block_experiment: bool = false;
/// 跳过 `r_btdm_task_init`（它会访问不可达块）⇒ 用于验证 step 7–15 / enable / HCI。
pub var skip_task_init: bool = false;

/// 补调 `fqmZk`（把 `Xpuq` 的锚点 `P` 填上）。
/// **默认关**：oracle 实测 IDF 里该锚点在 init **之前也是 0**，由 init 自己填；
/// 我们此前的"P=NULL 是 bug"是**误判**（在 step 6 之前读了它）。
pub var populate_workaround: bool = false; // 真实路径（21.o 锚点由 OkE7 自己发布）
/// **只发布 7.o 的锚点**（`r_sym_bt_BOhff` 的守卫）。依据：21.o 的锚点由 `OkE7`
/// 自己 malloc(76) 并发布（见 README），而 7.o 的锚点**没有任何惰性发布者**
/// ⇒ `BOhff`（建任务）永远早退 ⇒ `task_create` 永不发生。
pub var publish_bohff_anchor: bool = false; // 实验：不预发布 anchor[8]，让 JwHs 自己分配

/// `Xpuq` 用的锚点全局（`libbtdm_common/2.o` 的 `.bss.r_sym_bt_d3D3sk5KewclELfrD5xa`）。
/// 唯一的写者是 `r_sym_bt_fqmZkUKgd5GE6m7i2YFG`：`P = wr_btdm_osal_malloc(...)`。
/// `Xpuq` 之后用 `a1 = P` 做 `sw zero, 0(a1) …` 的零填充 —— **若 P 为 NULL，
/// 它会从地址 0 开始写，看起来就是"卡死"**（无 fault、无 OSAL 调用）。
extern var r_sym_bt_d3D3sk5KewclELfrD5xa: u32;

/// 是否把 `osal.logPublic` 的每一行都打到 UART。
/// 默认 **true**（可观测性优先）；设 false 可做"UART 静默"对照——但注意那样连进度行也看不到，
/// 需要额外把里程碑用 `board.log.line` 直写，否则实验没有信息量（踩过）。
pub var verbose: bool = false; // 主实验：日志几乎全关，只留里程碑行

/// 对照实验用：false ⇒ 完全不写任何时钟门控（验证"我们改时钟把 UART 弄停"）。
pub var clock_writes: bool = true; // 默认写；false 仅用于对照实验

/// 直接写 UART0 的 FIFO，**永不阻塞**。
///
/// 为什么不用 `board.log.line`（ROM 的 `esp_rom_printf`）：ROM 的路径会
/// `while (txfifo_cnt > 127) {}` 死等——一旦 FIFO 不排空，**日志自己也挂住**，
/// 于是"卡住之后什么都看不到"，无法区分"程序停在那"与"只是打印停了"。
/// 这里对每个字节做**有界**等待，等不到就丢弃，保证日志通道本身不会堵死。
pub var log_hook_calls: u32 = 0;

// ---- RAM 环形日志：不碰 UART，由 ISR 逐条吐出（短行才挤得进 FIFO）----
const ring_slots = 32;
const ring_len = 60;
pub var log_ring: [ring_slots][ring_len]u8 = @splat(@splat(0));
pub var log_ring_lens: [ring_slots]u8 = @splat(0);
pub var log_ring_n: u32 = 0;

pub fn ringPush(msg: []const u8) void {
    const slot = log_ring_n % ring_slots;
    const n = @min(msg.len, ring_len);
    @memcpy(log_ring[slot][0..n], msg[0..n]);
    log_ring_lens[slot] = @intCast(n);
    log_ring_n +%= 1;
}

/// ISR 侧调用：吐出第 `idx` 条（0 = 最新），返回切片。
/// 事件触发导出：打 PC 采样 + 计数器，然后停机。
var dump_done: bool = false;

/// dump 专用：格式化后走**阻塞写**（肯等到 FIFO 有空位），避免长行被丢。
fn dumpLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [200:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..198], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    board.hw.rawLineBlocking(buf[0 .. text.len + 1 :0]);
}

fn dumpAtPend() void {
    if (dump_done) return;

    // **UART 排空自测（修正版）**：自旋到计数 < 5（有界 ~20 ms），并**双读**对照。
    // 旧版只等 ~10 ms，而 125 B @115200 需 10.85 ms ⇒ 结论无效。
    {
        const st: *volatile u32 = @ptrFromInt(0x2038_A01C);
        const f: *volatile u32 = @ptrFromInt(0x2038_A000);
        const before = (st.* >> 16) & 0xFF;
        f.* = 'Z';
        var k: u32 = 0;
        while (k < 2_000_000) : (k += 1) {
            if (((st.* >> 16) & 0xFF) < 5) break;
        }
        const r1 = (st.* >> 16) & 0xFF;
        const r2 = (st.* >> 16) & 0xFF;
        const cc = (@as(*volatile u32, @ptrFromInt(0x2038_A088))).*;
        board.log.line("U {d}->{d},{d} spins={d} cc={x}", .{ before, r1, r2, k, cc });
    }
    dumpLine("A{x}/{d}", .{ g_abort_ra, osal.arenaFree() }); // 极短：调用者/空闲
    osal.canaryScan();

    osal.arenaWalk();
    {
        var mi: u32 = 0;
        while (mi < @min(osal.malloc_calls, 8)) : (mi += 1) dumpLine("M{d} {d} 0x{x}", .{ mi, osal.mc_sizes[mi], osal.mc_rets[mi] });
    }
    dumpLine("MC {d} sz={d} ret=0x{x}", .{ osal.malloc_calls, osal.last_req_size, osal.last_ret });
    dumpLine("CN 0x{x} 0x{x} {d}", .{ osal.canary_base + osal.canary_first_off, osal.canary_first_val, osal.canary_bad_words });
    // **按字节预算**：1 行计数（~20 B）+ 3 条截断到 24 B 的消息，合计 < 110 B。
    dumpLine("D{d}.{d}", .{ log_hook_calls, osal.caller_n });
    var mi: u32 = 0;
    while (mi < 3) : (mi += 1) {
        const m = ringAt(mi);
        if (m.len > 0) dumpLine("M{s}", .{m[0..@min(m.len, 24)]});
    }
    dump_done = true;
}

var flag_buf: [16]u8 = @splat(0);
fn flagBuf() []const u8 {
    const n = std.fmt.bufPrint(&flag_buf, "<C{d}>", .{g_c_count}) catch return "<C>";
    return n;
}

pub fn ringCount() u32 {
    return log_ring_n;
}
pub fn logcCount() u32 {
    return log_hook_calls;
}

pub fn ringAt(idx: u32) []const u8 {
    if (idx >= log_ring_n) return "";
    const slot = (log_ring_n -% 1 -% idx) % ring_slots;
    return log_ring[slot][0..log_ring_lens[slot]];
}
pub var log_hook_ours: u32 = 0;
pub var log_hook_calls_only: u32 = 0;
/// 仅 step 6 窗口内为真：只有此刻才发数字码（序列纯净，且不被里程碑挤掉）。
pub var call_stream_on: bool = false;

/// 调用码存进 RAM（不占 UART），由一次性导出统一打出来 —— 里程碑进度照常可见。
pub var code_ring: [48]u8 = @splat(0);
pub var code_n: u32 = 0;

fn codePush(c: u8) void {
    if (code_n < code_ring.len) {
        code_ring[code_n] = c;
        code_n += 1;
    }
    // **按码数触发导出**：不依赖 `irq_count`（其基准未核实），也不 halt。
    // 16 个码≈接近序列尾部，此时打一行 ~30 字节，FIFO 放得下。
    if (code_n == 8 or code_n == 16) {
        if (board.trap.extra_dump) |f| f();
    }
}

/// 直接写一个字节（绕过行缓冲；用于"每次调用一字母"的低带宽编码）。
fn uartPut(ch: u8) void {
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    var spins: u32 = 0;
    while ((((status.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
    if (spins < 40) fifo.* = ch;
}

/// 调用名 → 单数字码（数字不会与日志散文里的字母混淆，grep `[0-9]` 即得序列）。
/// malloc=0 mutex_init=1 eventq_init=2 event_init=3 mutex_pend=4
/// mutex_release=5 free=6 eventq_get=7 eventq_put=8 sem_*=9 其余=#
fn codeOf(name: []const u8) u8 {
    if (std.mem.startsWith(u8, name, "malloc")) return '0';
    if (std.mem.startsWith(u8, name, "mutex_init")) return '1';
    if (std.mem.startsWith(u8, name, "eventq_init")) return '2';
    if (std.mem.startsWith(u8, name, "event_init")) return '3';
    if (std.mem.startsWith(u8, name, "mutex_pend")) return '4';
    if (std.mem.startsWith(u8, name, "mutex_release")) return '5';
    if (std.mem.startsWith(u8, name, "free")) return '6';
    if (std.mem.startsWith(u8, name, "eventq_get")) return '7';
    if (std.mem.startsWith(u8, name, "eventq_put")) return '8';
    if (std.mem.startsWith(u8, name, "sem")) return '9';
    return '#';
}
pub var log_hook_other: u32 = 0;
/// 对照实验：为 true 时 logHook 只计数，把 UART 让出来（否则采样全落在它里面）。
pub var log_hook_silent: bool = false; // 默认放行；true 会连我们自己的进度日志一起静音（实测过）

fn logHook(msg: []const u8) void {
    // **三层语义各归各位**（这条以前写错过两次，每次代价是一轮无效板测）：
    //   里程碑 `bt bringup:`  → 无条件放行（唯一能判断进度的输出）
    //   归档日志 `osal>`       → 受 `verbose` 控制
    //   逐调用 `bt hook:`      → 受 `osal.trace_hooks` 控制（在 `logLine` 里）
    //
    // probe 镜像默认**打开**逐调用日志：它就是为了看"崩之前最后一个归档调用是什么"。
    // 输出量大，正式镜像不要开（`logLine` 里按前缀过滤，这里只是把门打开）。
    // ⚠️ 曾经这里无条件 `osal.trace_hooks = true` —— 每次打印都会把调用方设的静音**重新打开**，
    // 诊断窗口因此失效。trace 的开关应在入口显式设，不该藏在日志钩子里。
    board.trap.recordLogCaller(@returnAddress());
    log_hook_calls +%= 1;
    // **按来源分流**：只放行我们自己以 `"bt "` 开头的短行（`logPublic` 走这里），
    // 归档的消息只计数不写 UART ⇒ 串口不再被灌满，采样可用。
    if (std.mem.startsWith(u8, msg, "bt ")) {
        log_hook_ours +%= 1;
        // **只对逐调用行限量**（`bt ret:`/`bt call:`），里程碑（`bt bringup:`/`bt lp:`）不受限：
        // 早先把上限套在全部自身日志上，结果里程碑被吃掉、`malloc` 行变成 0（本会话踩过）。
        // **逐调用只写 1 个字节**：把 `bt ret: <name>…` / `bt call: <name>…` 压成该名字的首字母。
        // 21 次调用只占 21 字节，永不灌满 128 B FIFO，也不会与 ISR 心跳逐字节交错到无法 grep。
        if (call_stream_on) {
            if (std.mem.indexOf(u8, msg, "bt ret: ")) |k| {
                const rest = msg[k + 8 ..];
                if (rest.len > 0) {
                    codePush(codeOf(rest));
                    return;
                }
            }
            if (std.mem.indexOf(u8, msg, "bt call: ")) |k| {
                const rest = msg[k + 9 ..];
                if (rest.len > 0) {
                    codePush(codeOf(rest));
                    return;
                }
            }
            return; // 窗口内其它自身日志一律不发：把 21 字节留给码流
        }
    } else {
        log_hook_other +%= 1; // 归档自己的消息：进 RAM 环，不打 UART
        ringPush(msg);
        return;
    }
    if (!verbose and std.mem.startsWith(u8, msg, "osal> ")) return;
    const uart_fifo: *volatile u32 = @ptrFromInt(0x2038_A000); // UART_FIFO
    const uart_status: *volatile u32 = @ptrFromInt(0x2038_A01C); // UART_STATUS
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((uart_status.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
        if (spins >= 40) return; // FIFO 卡死：**立即丢字节，绝不把 CPU 停在 UART**
        uart_fifo.* = ch;
    }
    var spins: u32 = 0;
    while ((((uart_status.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
    if (spins < 40) uart_fifo.* = '\n';
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

/// 因果实验：把 anchor[0] 毒成一个**有效可写 RAM 指针**（+28=0），
/// 若崩溃因此消失或换点，就证明"anchor[0]==0 → 零值兜底 → store 到 0"这条链。
var poison_buf: [64]u8 align(4) = @splat(0);
pub var poison_anchor0: bool = false; // 基线
pub var pmu_dump: bool = false; // 纯诊断；WITH_PHY 版会在此停住，默认关
pub var reprobe_ble_block: bool = false; // 验证须放在 PHY 使能/校准**之后**，见 README // 复核实验：读 0x2010B000 会挂死整个系统
/// 自测：故意往地址 0 写一次。用它的标签地址与 panic 报出的 mepc 比对，
/// 判定这颗 CPU 的 store 异常是精确的还是会延迟上报。
pub var selftest_store0: bool = false; // 标定完成：见 README

var selftest_scratch: u32 = 0;

export fn probeSelftestStore0() void {
    // 标定延迟：坏写 -> fence -> 一次正常写（带标签）。
    // 若 mepc 落在 fence 处，说明错误在 fence（写队列排空点）上报。
    asm volatile ("sb zero, 0(zero)");
    asm volatile ("fence iorw, iorw");
}

export fn probeSelftestAfterFence() void {
    const q: *volatile u32 = &selftest_scratch;
    q.* = 0x1234;
}

pub fn run() noreturn {
    board.trap.extra_dump = dumpOsalCallers;
    board.trap.on_pc_ready = dumpPcRing;
    board.trap.ring_at = ringAt;
    board.trap.ring_n_at = ringCount;
    osal.dump_hook = dumpAtPend;
    board.trap.probe_logc = logcCount;
    if (reprobe_ble_block) {
        // 复核 README 记录的总根因：读 BLE/MAC 寄存器块是否会挂死（会挂，默认关）。
        board.log.line("{s}", .{"bt probe: re-probing 0x2010B000 ..."});
        const bleblk: *volatile u32 = @ptrFromInt(0x2010_B000);
        const ble0 = bleblk.*;
        board.log.line("bt probe: 0x2010B000 = 0x{x} (survived)", .{ble0});
    }
    if (selftest_store0) {
        probeSelftestStore0();
        probeSelftestAfterFence();
    }
    if (poison_anchor0) {
        // +28 填有效指针：若 `lw a0,28(a5)` 的值被下游当指针用，崩点应随之后移。
        const p28: *u32 = @ptrCast(&poison_buf[28]);
        p28.* = @intFromPtr(&poison_buf);
        const slot: *volatile u32 = @ptrFromInt(0x2f00fff4);
        slot.* = @intFromPtr(&poison_buf);
        board.log.line("poison: anchor[0] -> 0x{x}", .{@intFromPtr(&poison_buf)});
    }
    // **最先**做 ROM 取样：此时还没开中断，输出不会被 ISR 的行冲散。
    if (dump_rom) {
        dumpRom("A", 0x2f83efb0, 96);
        dumpRom("B", 0x2f812180, 160);
        dumpRom("U", 0x2038A000, 64);
    }

    porting.clock_writes_enabled = clock_writes;
    bringup.skip_task_init = skip_task_init;
    osal.setHooks(.{
        .now_ms = nowMs,
        .log = logHook,
        .irq_save = irqSave,
        .irq_restore = irqRestore,
        // 门控测量（`r_btdm_task_init` 的 env/P/锚点表）原先硬编码在 `osal.mutexPend` 里，
        // 现在由本组件注册 —— 内核不该知道 `0x2f00ffd0` 和 `probe_ptr`。
        .on_mutex_acquired = @import("gate.zig").probeAnchors,
    });
    osal.setMacHook(macHook);
    board.log.line("{s}", .{"bt probe: hooks installed (now_ms=us/1000)"});

    // **最先初始化时基**：不调 `hw.initTimer()`，TIMG0 的时钟没开 ⇒ `nowUs()` 恒 0（实测，
    // 见 ADR-001:729-730）⇒ ① T0 的 alarm 永不到点 ⇒ 一个中断都不来（采样器永远静默）；
    // ② OSAL 的 `now_ms = nowUs()/1000` 恒 0 ⇒ 归档里任何"等到某个时刻"的条件永远不成立 ⇒ 死等。
    // 这一行缺席的代价是整条链卡在 step 6，而且现象与"中断不工作"完全一样。
    board.hw.initTimer();
    const t0 = board.hw.nowUs();
    board.hw.initTimer();
    const t1 = board.hw.nowUs();
    board.log.line("bt probe: timer {d} -> {d} (must increase)", .{ t0, t1 });

    // **在 init 之前**武装 T0 + 开中断：init 一旦卡住，只有 ISR 还能说话。
    // 采样点在 trap 的输入 25 分支；中断还在来 ⇒ 是 spin 而非死机。
    // ⚠ 只有探针构建这么做，生产固件保持 MIE=0。
    // **对照实验开关**：ISR 里打印可能打断 ROM 的 UART 写（板侧证据：ROM 卡在
    // `UART0+0x1C` 的 TX 状态、值恒 128）。默认**不开中断**，只保留时基。
    if (probe_irqs) {
        board.hw.routeT0Interrupt(25);
        board.hw.armT0Interrupt(2000);
        board.hw.enableInterrupts();
        // **把 T0 的 CLIC 输入变成 NMI 源**：NMI 不受 `mstatus.MIE` 屏蔽，
        // 所以即使归档进了临界区（关中断）也照样能打断它、拿到 PC。
        // `CLIC_INT_CTRL_REG(i) = 0x10801000 + i*4`；bit3 = nmies、bits[7:4] = nmithres。
        // 保留优先级低 3 位、置 nmies、把 nmithres 清零。
        {
            const reg: *volatile u32 = @ptrFromInt(0x1080_1000 + 25 * 4);
            const old = reg.*;
            // **必须保留 bit8（IE）**：只保留低 3 位会把使能位一起清掉，中断就不来了。
            reg.* = (old & 0x107) | (1 << 3);
            board.log.line("bt probe: clic[25] 0x{x} -> 0x{x} (nmies)", .{ old, reg.* });
        }
        board.log.line("{s}", .{"bt probe: irq enabled (probe only), t0=2ms"});
    } else {
        board.log.line("{s}", .{"bt probe: irqs OFF (control run)"});
    }

    if (ble_block_experiment) {
        // **可访问性实验**：归档在 `r_sym_bt_XPuq` 里读 `0x2010B000..0x2010B100`
        // （MODEM_BASE+0xB000，BLE/MAC 私有块，soc 头里无定义）。
        // 已验证：**在什么都没做时读它一次就挂死**（总线挂起）。
        // 现在按 IDF 的顺序先做前置，再读一次，看是否变可读：
        //   ① 开我们那套时钟门控  ② 调归档里的 `bt_bb_v2_init_cmplx(1)`（= esp_btbb_enable 的核心）
        board.log.line("{s}", .{"bt probe: clock gates first ..."});
        var early_cfg = config.defaults();
        porting.clock_writes_enabled = true;
        porting.btdmLpEnableClock(&early_cfg.btdm);

        // `HP_SYS_CLKRST.MODEM_CTRL0`(0x20587040) 的 bit0 = `MODEM_CLK_EN`（默认 1）。
        // 若它为 0，modem 块就没有时钟 ⇒ 访问会挂死。
        const modem_ctrl0: *volatile u32 = @ptrFromInt(0x2058_7040);
        const mc0 = modem_ctrl0.*;
        board.log.line("bt probe: MODEM_CTRL0=0x{x:0>8} clk_en={}", .{ mc0, (mc0 & 1) != 0 });
        if ((mc0 & 1) == 0) {
            modem_ctrl0.* = mc0 | 1;
            board.log.line("bt probe: MODEM_CLK_EN was 0 -> set, now 0x{x:0>8}", .{modem_ctrl0.*});
        }
        // 复位位：我们打印过 `rst_conf=0x00000000` ⇒ 所有 modem 复位位都是 0（未处于复位）✓

        // **完整复位脉冲**（IDF 的 `MODEM_RESET_FIELD_WHEN_PU` 等价物）：此前我们只脉冲过
        // bit16(`rst_btmac`)，而 bit15/17/23/29 这些子模块复位位可能**从未被置过**。
        // 先写全 1（按住所有复位）再写全 0（释放），然后重开时钟（复位可能清掉时钟配置）。
        const rst: *volatile u32 = @ptrFromInt(0x2010_9C10);
        const rst_before = rst.*;
        rst.* = 0xFFFF_FFFF;
        var d: u32 = 0;
        while (d < 2000) : (d += 1) std.atomic.spinLoopHint();
        rst.* = 0;
        board.log.line("bt probe: rst pulse {x} -> all1 -> {x}", .{ rst_before, rst.* });
        porting.forceReenableClocks(&early_cfg.btdm);
        board.log.line("{s}", .{"bt probe: clocks re-enabled after reset pulse"});

        board.log.line("{s}", .{"bt probe: calling bt_bb_v2_init_cmplx(1) ..."});
        _ = bt_bb_v2_init_cmplx(1);

        board.log.line("{s}", .{"bt probe: probing 0x2010B000 (after bb init) ..."});
        const bleblk: *volatile u32 = @ptrFromInt(0x2010_B000);
        const ble0 = bleblk.*;
        board.log.line("bt probe: 0x2010B000 = 0x{x:0>8} (READABLE!)", .{ble0});
    }

    // 1) arena 最先
    const hs = @intFromPtr(heapStart());
    const he = @intFromPtr(heapEnd());
    if (he > hs) {
        const region = @as([*]u8, @ptrFromInt(hs))[0 .. he - hs];
        osal.initArena(region);
        // **极短**：长行会被 FIFO 丢；这里只要一个数字（KB）就够判读。
        board.log.line("A{d}K", .{(he - hs) / 1024});
    } else {
        osal.logPublic("bt probe: FATAL no heap region", .{});
        halt();
    }

    // 2) init 链（15 步）
    cfg = config.defaults();
    osal.logPublic("bt probe: init start", .{});
    // **syscon 窗口对拍**：与 IDF 成功镜像的 `[after_init]` 逐字比较
    {
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a: usize = 0x2010_9C00 + k * 4;
            board.log.line("bt probe: syscon+0x{x:0>2} = 0x{x:0>8}", .{ k * 4, (@as(*volatile u32, @ptrFromInt(a))).* });
        }
    }
    // hp_sys_clkrst 全窗口（与 IDF 成功镜像的程序化对拍）
    {
        var k: usize = 0;
        while (k < 128) : (k += 1) {
            const a: usize = 0x2058_7000 + k * 4;
            const v = (@as(*volatile u32, @ptrFromInt(a))).*;
            if (v != 0) board.log.line("clkrst+0x{x:0>3} = 0x{x:0>8}", .{ k * 4, v });
        }
    }
    // **UART0 排水能力判定**：同一地址连采 4 次，间隔约 100 ms。
    // 递减 ⇒ 只是排得慢（查波特率/时钟）；恒定 ⇒ 真的停住。
    {
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            board.log.line("uart0 采样[{d}] 0x{x:0>8}", .{ k, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* });
            board.hw.delayUs(100_000);
        }
    }
    // PMU 窗口（0x20704000..+0x200）非零项 —— 与 IDF oracle 的同类 dump 逐字对拍
    // ⚠️ 纯诊断；`WITH_PHY=1` 版在最后几项停住（0x207041E4 之后），故默认关闭。
    if (pmu_dump) {
        var k: usize = 0;
        while (k < 128) : (k += 1) {
            const a: usize = 0x2070_4000 + k * 4;
            const v = (@as(*volatile u32, @ptrFromInt(a))).*;
            if (v != 0) board.log.line("pmu+0x{x:0>3} = 0x{x:0>8}", .{ k * 4, v });
        }
    }
    {
        const w: *volatile u32 = @ptrFromInt(0x20100800);
        board.log.line("FE800={x}", .{w.*});
    }
    // **IDF 次序：pmu_init → 时钟/使能 → BT init**。
    // 前/后各拍 {PMU_RF_PWC, ana-mst-clk, ICG_MODEM×2} 到 0x18B/18C；
    // pmu_init 的默认值会清掉 RF 电源/时钟 ⇒ 之后重放整套使能。
    {
        const rd_ = struct {
            fn r(addr: usize) u32 {
                return @as(*volatile u32, @ptrFromInt(addr)).*;
            }
            fn wr(addr: usize, val: u32) void {
                @as(*volatile u32, @ptrFromInt(addr)).* = val;
            }
        };
        var pb: [5]u32 = @splat(0);
        pb[0] = 0xADC0_FEE5;
        pb[1] = rd_.r(0x2070_4184);
        pb[2] = rd_.r(0x2010_F83C);
        pb[3] = rd_.r(0x2070_4014);
        pb[4] = rd_.r(0x2070_4054);
        _ = esp_rom_spiflash_erase_sector(0x18B000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18B000, &pb, @intCast(@sizeOf(@TypeOf(pb))));
        flashStage(72);
        // **逐位探测 CSR 0x7a0**（解码 Espressif tdata1 的真实布局）：
        // 每位：写 (读|bit) → 读回 → 记录是否保留。结果 8 字（位图）+ 32 字（原始回读）
        // 落 0x18F000（pre-pmu 窗口）。若 CSR 写有副作用，数据已先行落盘。
        {
            var rb_bits: [32]u32 = @splat(0);
            var keep: u32 = 0; // 位图：bit b = 1 ⇒ 写该位后回读含该位（可写）
            var bp: u32 = 0;
            while (bp < 32) : (bp += 1) {
                const bit: u32 = @as(u32, 1) << @intCast(bp);
                var cur: u32 = undefined;
                asm volatile ("csrr %[v], 0x7a0"
                    : [v] "=r" (cur),
                );
                const wv: u32 = cur | bit;
                asm volatile ("csrw 0x7a0, %[v]"
                    :
                    : [v] "r" (wv),
                );
                asm volatile ("csrr %[v], 0x7a0"
                    : [v] "=r" (cur),
                );
                rb_bits[bp] = cur;
                if ((cur & bit) != 0) keep |= bit;
            }
            // 恢复：写回探测前的值（或已知安全值 0x0）
            var pv: [10]u32 = @splat(0);
            pv[0] = 0xADC0_FEEC;
            pv[1] = keep; // 可写位图
            for (0..32) |k| pv[2 + k] = rb_bits[k]; // 每位探测的回读（截断到 30 位）
            _ = esp_rom_spiflash_erase_sector(0x18F000 / 0x1000);
            _ = esp_rom_spiflash_write(0x18F000, &pv, 32);
        }
        // **干净触发器验证**（只碰已证可读的 CSR；pre-pmu 窗口 flash 可靠）：
        // tinfo 回读；写 tdata1=0x4C → 回读；写 tdata2=0x2f828a78 → 回读；
        // tcontrol(0x7a3)=0x88 写 → 回读（此前读 0 无陷阱）；tselect 回读。
        // 结果 6 字落 0x18F000（此窗口 flash 可靠——stage 72 落地证实）。
        // **改进位探测**（兼容粘滞位语义）：每位先写 0 清场 → 写该位 → 读回 →
        // (rb & bit) 判保留。write-1-to-set 与普通覆盖两种语义都能正确判定。
        {
            var keep: u32 = 0;
            var bp: u32 = 0;
            while (bp < 32) : (bp += 1) {
                const bit: u32 = @as(u32, 1) << @intCast(bp);
                asm volatile ("csrw 0x7a0, zero"); // 清场
                const wv: u32 = bit;
                asm volatile ("csrw 0x7a0, %[v]"
                    :
                    : [v] "r" (wv),
                );
                var rb: u32 = undefined;
                asm volatile ("csrr %[v], 0x7a0"
                    : [v] "=r" (rb),
                );
                if ((rb & bit) != 0) keep |= bit;
            }
            flashStage(92); // 位探测完成 ⇒ 未挂死
            // **keep 位图落盘**（独立扇区 0x189000）：{FEEC, keep}
            var kp: [2]u32 = .{ 0xADC0_FEEC, keep };
            _ = esp_rom_spiflash_erase_sector(0x189000 / 0x1000);
            _ = esp_rom_spiflash_write(0x189000, &kp, 8);
        }
        // **0x7a4/0x7a5 写-回读验证**（RISC-V Debug 规范 0.13 的 tdata1/tdata2 地址）：
        // tdata1(0x7a4) ← 0x4C（Espressif 布局：USER|MACHINE|EXECUTE）
        // tdata2(0x7a5) ← 0x2f828a78（目标地址）
        // 回读相等 ⇒ 找到真触发器 CSR！
        var r4: u32 = undefined;
        var r5: u32 = undefined;
        asm volatile ("li t0, 0x4c");
        asm volatile ("csrw 0x7a4, t0"); // tdata1 = 0x4C
        asm volatile ("csrr %[v], 0x7a4"
            : [v] "=r" (r4),
        );
        asm volatile ("li t0, 0x2f828a78");
        asm volatile ("csrw 0x7a5, t0"); // tdata2 = 地址
        asm volatile ("csrr %[v], 0x7a5"
            : [v] "=r" (r5),
        );
        var v_t1: u32 = undefined;
        var v_t2: u32 = undefined;
        var v_t3: u32 = undefined;
        var v_t4: u32 = undefined;
        var v_t5: u32 = undefined;
        asm volatile ("csrr %[v], 0x7a4"
            : [v] "=r" (v_t1),
        ); // tinfo
        asm volatile ("li t0, 0x4c");
        asm volatile ("csrw 0x7a0, t0"); // tdata1 = 0x4C
        asm volatile ("csrr %[v], 0x7a0"
            : [v] "=r" (v_t2),
        ); // 回读
        asm volatile ("li t0, 0x2f828a78");
        asm volatile ("csrw 0x7a1, t0"); // tdata2 = 地址
        asm volatile ("csrr %[v], 0x7a1"
            : [v] "=r" (v_t3),
        ); // 回读
        asm volatile ("li t0, 0x88");
        asm volatile ("csrw 0x7a3, t0"); // tcontrol
        asm volatile ("csrr %[v], 0x7a3"
            : [v] "=r" (v_t4),
        ); // 回读
        asm volatile ("csrr %[v], 0x7a5"
            : [v] "=r" (v_t5),
        ); // tselect
        var cv: [8]u32 = @splat(0);
        cv[0] = 0xADC0_FEEB;
        cv[1] = v_t1; // tinfo
        cv[2] = v_t2; // tdata1 回读
        cv[3] = v_t3; // tdata2 回读
        cv[4] = v_t4; // tcontrol 回读
        cv[5] = v_t5; // tselect 回读
        cv[6] = r4; // 0x7a4 回读（写 0x4C 后）
        cv[7] = r5; // 0x7a5 回读（写地址后）
        _ = esp_rom_spiflash_erase_sector(0x18F000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18F000, &cv, @intCast(@sizeOf(@TypeOf(cv))));
        // **正确武装序列**（Debug Spec v1.0 地址映射）：
        // tselect(0x7a0) = 触发器 0 → tdata1(0x7a1) = EXECUTE|USER|MACHINE →
        // tdata2(0x7a2) = 0x2f828a78（vendor FE 轮询地址）→ tcontrol(0x7a5) = MTE|MPTE
        // （0xffff0000 dump 已删：load access fault = 未映射 ⇒ 不可执行，问题已答）
        const pmu_init_f = @extern(*const fn () callconv(.c) void, .{ .name = "pmu_init" });
        pmu_init_f();
        flashStage(73);
        // **LP-RAM 跨 boot 累积**（0x2E000000，CPU_LOCKUP 复位不清；pmu_init 后才可读）：
        // LP[0]=boot 计数；LP[1..10]=最近 10 轮各自的最深步骤号。
        // 每轮在此转写 flash 0x188000 ⇒ host 一次读到逐轮历史（循环下不再盲）。
        {
            // **LP 魔数守卫**：上电非零垃圾 ⇒ 魔数不符即清零（跨 lockup 存活则保留计数）
            const magic_slot: *volatile u32 = @ptrFromInt(0x2E00_003C);
            if (magic_slot.* != 0x2E00_B007) {
                for (0..11) |k| {
                    @as(*volatile u32, @ptrFromInt(0x2E00_0000 + 4 * k)).* = 0;
                }
                magic_slot.* = 0x2E00_B007;
            }
            lp_boot_n = @as(*volatile u32, @ptrFromInt(0x2E00_0000)).* +% 1;
            @as(*volatile u32, @ptrFromInt(0x2E00_0000)).* = lp_boot_n;
            for (0..9) |k| {
                lp_hist[k] = @as(*volatile u32, @ptrFromInt(0x2E00_0004 + 4 * k)).*;
            }
            // flash 转写挪到 FEFC 证据块之后（紧跟 flashStage 的写会静默失败）
        }
        var ab: [5]u32 = @splat(0);
        ab[0] = 0xADC0_FEE6;
        ab[1] = rd_.r(0x2070_4184);
        ab[2] = rd_.r(0x2010_F83C);
        ab[3] = rd_.r(0x2070_4014);
        ab[4] = rd_.r(0x2070_4054);
        _ = esp_rom_spiflash_erase_sector(0x18C000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18C000, &ab, @intCast(@sizeOf(@TypeOf(ab))));
        // **单臂实验**：只写 PMU_RF_PWC（0x20704184 = 0xFFFF0000）一个使能。
        // 若仅此写就导致控制流跳飞（触发器 match≥0x2f828a78 会如实报告），
        // ⇒ 该写的副作用就是根因候选；判据：marker/ring 的位置。
        rd_.wr(0x2070_4184, 0xFFFF_0000);
        var rc_: [3]u32 = .{ 0xADC0_FEE7, rd_.r(0x2070_4184), rd_.r(0x2010_F83C) };
        _ = esp_rom_spiflash_erase_sector(0x18D000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18D000, &rc_, 12);
    }
    // **RISC-V debug trigger（Debug Spec v1.0 映射，写-回读已验证）**——提前到 BT 探测之前：
    // BT 段（bringup.enable/HCI）是已知挂死点，放它后面永远跑不到。
    // LOAD 观察点盯 0x20501000（**bb_init 自旋条件实测**：helper 0x2f80e450
    // `lw a5,0(a4); andi a5,15; bnez` —— 等 (0x20501000 & 0xF)==0；
    // 另一 helper 0x2f80e440 等全零。0x2f80e4d0/e4de 采样 PC 是路过点）。
    // 命中 = 自旋环内，auth_pc 应为 0x2f80e450/e440；trap 快照读它的活值
    // ⇒ 阻塞位到底是什么。
    // **STORE 观察点**：目标 0x2f07f99c（bb_init 真等待点，实测基线 0、自旋时仍 0）。
    // 命中 ⇒ auth_pc = 注册者 PC；不命中 ⇒ 本流程无人写它。
    // （FEFA 轮 LOAD@0x20501000 已证 0x20501000 pre-BT=0、自旋时=0x6992f。）
    const vfe4: u32 = @as(*volatile u32, @ptrFromInt(0x2f07_ffe4)).*;
    const target_addr: u32 = vfe4 +% 36;
    const cur_val: u32 = if (vfe4 != 0) @as(*volatile u32, @ptrFromInt(target_addr)).* else 0xDEAD_0000;
    var base: [4]u32 = .{ 0xADC0_FEFC, vfe4, target_addr, cur_val };
    _ = esp_rom_spiflash_erase_sector(0x189000 / 0x1000);
    _ = esp_rom_spiflash_write(0x189000, &base, 16);
    // **LP 逐轮历史转写**（落点在 FEFC 之后 —— 该窗口写可靠）：
    // {FEFE, boot_n, hist[0..9]} @0x18A000（空闲扇区；0x188000 已被自旋期回读 buf2 占用）。
    var lrec: [11]u32 = @splat(0);
    lrec[0] = 0xADC0_FEFE;
    lrec[1] = lp_boot_n;
    for (0..9) |k| lrec[2 + k] = lp_hist[k];
    _ = esp_rom_spiflash_erase_sector(0x18A000 / 0x1000);
    _ = esp_rom_spiflash_write(0x18A000, &lrec, 44);
    // **安全次序：先关后配最后开** —— 中间态绝不带着陈旧 tdata2 武装活观察点：
    asm volatile ("csrw 0x7a5, zero"); // tcontrol = 0（先全关）
    asm volatile ("csrw 0x7a1, zero"); // tdata1 = 0（解除）
    asm volatile ("csrw 0x7a0, zero"); // tselect = 0
    asm volatile ("mv t0, %[addr]"
        :
        : [addr] "r" (target_addr),
    );
    asm volatile ("csrw 0x7a2, t0"); // tdata2 = target_addr（此刻无观察点在活）
    asm volatile ("li t0, 0x4a");
    asm volatile ("csrw 0x7a1, t0"); // tdata1 = STORE|USER|MACHINE
    asm volatile ("li t0, 0x88");
    asm volatile ("csrw 0x7a5, t0"); // tcontrol = MTE(bit3)|MPTE(bit7)（最后开）
    // **武装证据**（直写，不屏蔽 MIE —— pmu 后 flashStage 类写不落地，直写才落地）：
    // {FEF5, tdata1_rb, tdata2_rb, tcontrol_rb} @0x189000。在 ⇒ 观察点已活（本轮独有 magic）。
    var t1v: u32 = undefined;
    var t2v: u32 = undefined;
    var tcv: u32 = undefined;
    asm volatile ("csrr %[v], 0x7a1"
        : [v] "=r" (t1v),
    );
    asm volatile ("csrr %[v], 0x7a2"
        : [v] "=r" (t2v),
    );
    asm volatile ("csrr %[v], 0x7a5"
        : [v] "=r" (tcv),
    );
    // **PC 邻域反汇编 dump**（0x2f 区可直读，dumpRom 先例）：
    // fe_poll: 命中 PC 0x2f828a5c 所在轮询环；rf_pwr: 命中 PC 0x2f00c3e2 所在例程。
    dumpRom("fe_poll", 0x2f828a40, 0x60);
    dumpRom("rf_pwr", 0x2f00c3b0, 0x60);
    // bb_init 尾调用目标与两个 helper（本轮自旋真挂点候选）
    dumpRom("tc_tgt", 0x2f8210c0, 0x60);
    dumpRom("helper", 0x2f80e420, 0x40);
    // （bb_init 邻域 dump 已撤：pre-BT 读 0x2f80e4a0 疑似间歇 fault ⇒ 2s 重启循环；
    //  窗口字节已捕获并解码，见 README 附记 1af128e。）

    // **直写进度标记**（post-pmu 可靠通道：FEE6 已擦 0x18C000 扇区，0x18C020 起空闲；
    // 各 8 字 {magic, 值}，不再擦除，host 按 magic 定位最后到达的步）
    const mark = struct {
        var seq: u32 = 0;
        fn put(off: u32, magic: u32, v: u32) void {
            seq +%= 1;
            // **直写 LP 槽**：本轮最深步骤号进 LP（RAM 直写，无 flash 失败问题）
            const slot: *volatile u32 = @ptrFromInt(0x2E00_0004 + 4 * ((lp_boot_n - 1) % 10));
            slot.* = seq;
            const pair: [2]u32 = .{ magic, v };
            _ = esp_rom_spiflash_write(0x18C000 + off, &pair, 8);
        }
    };
    // （CSR 扫描已挪到 bringup 之前 —— flash 可用窗口）
    var rc = bringup.init(&cfg);
    mark.put(0x20, 0xADC0B101, @bitCast(rc));
    // **不写日志的标记**：init 返回后立刻置位。崩溃时若该值仍为 0 ⇒ 崩在 return 路径；
    // 已置位 ⇒ 崩在更晚处。（日志行在本故障下会丢，故用纯 RAM。）
    @import("board").trap.diag_b = 0xB0B0;
    if (rc != 0) {
        osal.logPublic("bt probe: init FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    osal.logPublic("bt probe: init ok {d}", .{0}); // 先打，不碰 arena
    // （FEFD 回调表 dump 已删：一次性实验已完成并提交 0328594；
    //  0x188000 现由 LP 逐轮历史 FEFE 使用，勿再写此扇区。）
    // **解除 dump 钩子**：`dumpAtPend` 挂在 `dump_hook` 上，而它在**每次** `mutex_pend`
    // 里被调用（`osal.zig:1059`）；它的 `dump_done` 守卫在函数**末尾**才置位 ⇒
    // 一旦内部不返回就会**每次 pend 重入** ⇒ 把 controller 饿死。
    // bringup 已过观测窗口，这里解除，让运行时路径零开销。
    flashStageExtra(10, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0); // host 可读：init 之后、enable 之前
    osal.dump_hook = null;
    osal.logPublic("bt probe: dump_hook disarmed", .{});
    const af = osal.arenaFree();
    osal.logPublic("bt probe: arena free={d} B", .{af});

    // 3) enable 链（6 步）
    flashStageExtra(11, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0); // 即将调用 enable()
    mark.put(0x28, 0xADC0B102, @bitCast(rc));
    rc = bringup.enable();
    mark.put(0x30, 0xADC0B103, @bitCast(rc));
    flashStageExtra(12, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0); // enable() 已返回
    if (rc != 0) {
        osal.logPublic("bt probe: enable FAILED at step {d} rc={d}", .{ bringup.stats().failed_step, rc });
        halt();
    }
    osal.logPublic("bt probe: enabled (status={d})", .{bringup.getStatus()});

    // 4) 真正进任务（只有第一次用 startScheduler）
    ctrl_task = findFirstTask();
    if (ctrl_task) |t| {
        // 调度器已在 `task_create` 时启动过（FreeRTOS 语义）⇒ 这里不能再调
        // `startScheduler`（它会重置 `main_ctx`）。
        osal.logPublic("bt probe: controller task present (stack={d} B, scheduler started={})", .{ t.stack_size, sched.isStarted() });
    } else {
        osal.logPublic("bt probe: WARN no task was created by r_btdm_task_init", .{});
    }

    // 5) 发第一条命令并泵任务
    osal.logPublic("bt probe: sending HCI Reset", .{});
    mark.put(0x38, 0xADC0B104, 0);
    rc = transport.sendResetViaHs();
    mark.put(0x40, 0xADC0B105, @bitCast(rc));
    osal.logPublic("bt probe: sendReset rc={d}", .{rc});

    // **判别实验**：发第二条**可区分**的命令（Read Local Version，opcode 0x1001）。
    // `evt=2` 且回包 opcode 为 `01 10` ⇒ 命令被逐条处理（`0000` 是 init 遗留事件）；
    // 仍 `evt=1` ⇒ 我们抓到的那条是 blob 自己的 init 事件，命令未被消费。
    rc = transport.sendCmdViaHs(0x1001, &.{});
    osal.logPublic("bt probe: B(hs) sendReadVersion rc={d} stats cmds={d} evt={d}", .{ rc, transport.stats().cmds_sent, transport.stats().evt_count });
    // **A 路径对照**：`sendCmd` 走 `r_btdm_hci_trans_rx`，前置要求 status == ENABLED。
    mark.put(0x48, 0xADC0B106, 0);
    const a_rc = transport.sendCmd(0x1001, &.{});
    mark.put(0x50, 0xADC0B107, transport.stats().btdm_tx);
    osal.logPublic("bt probe: A(rx) sendReadVersion rc={d} stats cmds={d} evt={d}", .{ a_rc, transport.stats().cmds_sent, transport.stats().evt_count });
    // **第二条 A 路径命令**（唯一 opcode 0x0C03）：看 `btdm_tx` 是否 1 → 2。
    mark.put(0x58, 0xADC0B108, 0);
    const a2_rc = transport.sendCmd(0x0C03, &.{});
    mark.put(0x60, 0xADC0B109, transport.stats().btdm_tx);
    osal.logPublic("bt probe: A2(rx) sendReset rc={d} btdm_tx={d}", .{ a2_rc, transport.stats().btdm_tx });
    // **第三条**：再发一次 Read Local Version，**让它成为最后一条** ⇒
    // `tx_head` 捕获的就是它的 12 字节应答（hci_version / manufacturer 等），
    // 用来确认 HCI 通道承载的是**真实数据**而不是桩。
    // **读 BD_ADDR**（`0x1009`）：controller 的公开地址。
    // 一条命令、确定回包（6 字节地址），且是后续 LE 广播的前提。
    mark.put(0x68, 0xADC0B10a, 0);
    const a4_rc = transport.sendCmd(0x1009, &.{});
    mark.put(0x70, 0xADC0B10b, transport.stats().btdm_tx);
    osal.logPublic("bt probe: A4(rx) readBdAddr rc={d} btdm_tx={d}", .{ a4_rc, transport.stats().btdm_tx });

    // **LE 广播 + flash 阶段标记**：每条命令前把阶段写进 `0x186000`，
    // 卡住后从 **host** 读回 —— 不依赖任何日志。
    {
        // **实验：现在重试 `bt_bb_v2_init_cmplx(1)`**。
        // ADR-001 旧记录：它 stall 在 `write 0x20107C80`（WIFI_BB 区）——但那是旧时钟状态
        // （clk_conf1 缺 wifibb 位组）。本轮自旋期快照证实 clk_conf1 已被归档自己开到
        // `0x003FFA8C`（含 wifibb_44m/80m/160x1/wifimac）⇒ 前置条件已变。
        // 用 PC 采样器判读：若再 stall，直接拿挂点地址；端到端判据 marker stage 23 / tx 6。
        // （pmu_init 已提前到 bringup 之前 —— IDF 次序；前/后 PMU 状态在 0x18B/18C 扇区）
        flashStage(73);
        // **采样窗口搬到此处**：esp_phy_enable 若挂，ISR 采 72 个样本后自动落盘 0x187000
        board.trap.resetPcs();
        board.trap.sample_quiet = true;
        board.trap.pc_dump_at = 72;
        if (!probe_irqs) {
            probe_irqs = true;
            board.hw.routeT0Interrupt(25);
            board.hw.armT0Interrupt(2000);
            board.hw.enableInterrupts();
            // **NMI 转换**（与 boot 期 :438-444 相同）：esp_phy_enable 会关中断，
            // 只有 NMI 能看见它关中断后的自旋 —— 这是本窗口的目的所在。
            const nmi_reg: *volatile u32 = @ptrFromInt(0x1080_1000 + 25 * 4);
            const old_c = nmi_reg.*;
            nmi_reg.* = (old_c & 0x107) | (1 << 3); // 保留 bit8(IE)+低3位，置 nmies(bit3)
        }
        flashStage(90); // wait 之后：样本 ≥90 ⇒ 采样活着
        // **等采样器的 ISR dump 完成**（72 次采样触发一次性落盘 0x187000）。
        // 否则 flashStage(64) 的擦写会与 ISR dump **撞车**（ROM spiflash 不可重入）
        // ⇒ marker 写静默失败（这正是 73 之后 64 不落地的机制）。
        // **定长等待**（~1.6s）：给采样器/触发器时间进入 esp_phy_enable 的挂段。
        // 不依赖 pcSampleCount —— 采样器在 72 样本 dump 后已停（活寄存器即可判读）。
        var wait_dumps: u32 = 0;
        while (wait_dumps < 100_000_000) : (wait_dumps += 1) {
            asm volatile ("nop");
        }
        // **oracle 实验：IDF 本体的 `esp_phy_enable(PHY_MODEM_BT=2)`**
        // WITH_PHY=1 已把 IDF 的 phy_init.c 链进来（`esp_phy_enable` T 符号已确认）。
        // 它内部含我们手写版没有的完整射频使能段（含 analog/regi2c/PMU 路径）。
        // 若这一步之后轮询位能置 ⇒ 缺的就是它；若仍挂 ⇒ 连 IDF 都点不亮这块，
        // 问题在更上游（电源岛/晶振时钟路径）。
        // **WiFi osi 栈前置**（wifi-blobs 配方：表 → initcfg → coex_init →
        // esp_wifi_init_internal——esp_wifi_init_internal ∈ libnet80211.a 本轮已链）
        {
            osi_table = osi_impl.makeTable();
            osi_table._log_write = s31_log_write;
            const wcfg = init_config.defaults(&osi_table);
            const coex_init = @extern(*const fn () callconv(.c) void, .{ .name = "coex_init" });
            coex_init();
            const esp_wifi_init_internal = @extern(*const fn (*const anyopaque) callconv(.c) c_int, .{ .name = "esp_wifi_init_internal" });
            const wrc = esp_wifi_init_internal(&wcfg);
            mark.put(0xa0, 0xADC0B111, @bitCast(wrc)); // M11: init_internal 返回码
        }
        // **WiFi osi 栈前置**（wifi-blobs 配方：表 → initcfg → coex_init →
        // esp_wifi_init_internal（∈ libnet80211.a，本轮已链）；bb_v2_init 跳过中）
        {
            const coex_init = @extern(*const fn () callconv(.c) void, .{ .name = "coex_init" });
            coex_init();
            osi_table = osi_impl.makeTable();
            osi_table._log_write = s31_log_write;
            const wcfg = init_config.defaults(&osi_table);
            const esp_wifi_init_internal = @extern(*const fn (*const anyopaque) callconv(.c) c_int, .{ .name = "esp_wifi_init_internal" });
            const wrc = esp_wifi_init_internal(&wcfg);
            mark.put(0xa8, 0xADC0B120, @bitCast(wrc)); // M20: init_internal 返回码
        }
        const esp_phy_enable = @extern(*const fn (modem: c_int) callconv(.c) void, .{ .name = "esp_phy_enable" });
        mark.put(0xa0, 0xADC0B112, 0); // **调用前标记** ⇒ seq 12：hist=12 ⇒ 死在 esp_phy_enable 内；hist=11 ⇒ 死在本调用之前（LE 块前半段）
        esp_phy_enable(2); // PHY_MODEM_BT（判别轮的 modem=1 已回退——上轮判别因缺调用前标记而无效）
        mark.put(0x88, 0xADC0B10e, 0); // esp_phy_enable 返回 ⇒ M00e
        flashStageExtra(71, @bitCast(@as(c_int, 0)), 0);
        mark.put(0x90, 0xADC0B10f, 0); // bb_v2_init 调用前 ⇒ M00f
        // **本轮跳过手动 bb_v2_init**（0328594 定案：顺序错误——
        // 回调表项 [a4+36] 需注册步骤填充，手动提前调用 = 永等 + CPU_LOCKUP 循环。
        // 官方链应经由 enable/esp_btbb_enable 在注册之后调用。）
        const bbrc: c_int = -1; // -1 = skipped
        mark.put(0x98, 0xADC0B110, @bitCast(bbrc)); // 跳过 ⇒ 记 -1 ⇒ M10
        flashStageExtra(65, @bitCast(bbrc), 0);
        // ✅ **已实验判定：信道 37 不是原因**（2026-11-19，`0x07` → `0x03` 后 marker 仍 22/5）。
        // 曾怀疑信道 37 = 2402 MHz 走 26 MHz 路径、本板没使能 ⇒ 调谐就挂。
        // 结果：去掉 37 无变化 ⇒ 恢复标准的"三个信道全开"。
        var ap: [15]u8 = .{ 0xA0, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00 };
        // ✅ **已实验判定：地址类型不是原因**（2026-11-19）
        // 试过「0x2005 写随机地址 + own_addr_type=0x01」⇒ marker 仍 `stage=22`
        // （`tx` 从 5 变 6 **只是因为多了一条 0x2005**，不是成功）。
        // ⚠ **判据必须是 `stage == 23`**；只看 `tx` 会把"多发一条命令"误判成"返回了"。
        // ✅ **已实验判定：自置 bit2 无效**（2026-11-19：`0x201098BC |= 4` 后仍 22/5）。
        //    我们的写被丢弃或在归档轮询前被清；而同一区域 0x20109400(CLK_EN) 写 1
        //    能保留 ⇒ "块无时钟"不成立，0x201098BC.bit2 是**硬件状态位**（RF/BB ready）。
        //    ⇒ 机制最终版：0x200A 写配置+启动选通 → 等 RF/BB ready → 位永不置位
        //      （射频使能链不完整）→ 超时错误码 3。见 README「最终机制」。
        mark.put(0x78, 0xADC0B10c, 0);
        const r6 = transport.sendCmd(0x2006, &ap);
        mark.put(0x80, 0xADC0B10d, transport.stats().btdm_tx);
        flashStageExtra(21, (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).* >> 16 & 0xFF, 0);
        var ad: [32]u8 = @splat(0);
        ad[0] = 3;
        ad[1] = 2;
        ad[2] = 0x06;
        const r8 = transport.sendCmd(0x2008, &ad);
        // **射频状态快照**：`0x200A` 之前把 FE 块的值也存进 flash，
        // 让 host 一次读出"射频是否就绪"，而不只是"停在哪"。
        // **实验：去掉 FE 快照读**。README 与 `tools/jtag-watch-modem-block.sh` 记的
        // 根因症状是"访问 `0x2010B000` 后总线不再应答 —— 无异常、**中断停止、静默**"，
        // 而这个 stage 22 恰好就在 `0x200A` 之前读那两个地址
        // ⇒ 一次改动可同时解释"0x200A 无应答"与"UART 哑"（后者至今未解释）。
        // 另外 word2/3 的 FE 快照**本是噪声**（同构建两次运行就不同），本来也不该当判据。
        // 判据：marker stage/tx（23/6 = 返回了）+ 串口是否恢复。
        // **实验：把 `UART0_STATUS.TXFIFO_CNT` 写进标记**（word2），
        // 以区分"FIFO 满且不排空（发送通道死）"与"FIFO 空（压根没写进去）"。
        // UART0 = 0x2038_A000，STATUS = +0x1C，TXFIFO_CNT = bit[23:16]。
        const uart_st: u32 = (@as(*volatile u32, @ptrFromInt(0x2038_A01C))).*;
        _ = uart_st;
        // **最后两个判据**：
        //   `GPIO_FUNC58_OUT_SEL_CFG`(0x20583BDC)：GPIO matrix 是否把 pad58 改接到别的信号
        //   `UART0.clkdiv_sync`(0x2038A014)：波特率分频（默认 694 = 80 MHz / 115200）
        const osel: u32 = (@as(*volatile u32, @ptrFromInt(0x2058_3BDC))).*;
        const cdiv: u32 = (@as(*volatile u32, @ptrFromInt(0x2038_A014))).*;
        // **判据**：`MODEM_SYSCON.modem_rst_conf`(0x20109C10)
        //   bit9 `rst_wifimac` = 1 ⇒ MAC 一直在复位里 ⇒ 命令永不应答（trap.zig:331-333）
        //   bit8 `rst_wifibb`  = 1 ⇒ BB 在复位里
        const rst_conf: u32 = (@as(*volatile u32, @ptrFromInt(0x2010_9C10))).*;
        _ = rst_conf;
        _ = osel;
        _ = cdiv;
        // **快照自旋环写/轮询的三个寄存器**（MODEM_WIDGETS=0x20109400 私有块）：
        //   W+0x480 = 0x20109880（环里写 0x0FFFFFFF 的那个）
        //   W+0x4A8 = 0x201098A8（写 0）
        //   W+0x4B8 = 0x201098B8（写 a3）
        const w480: u32 = (@as(*volatile u32, @ptrFromInt(0x2010_9880))).*;
        const w4a8: u32 = (@as(*volatile u32, @ptrFromInt(0x2010_98A8))).*;
        flashStageExtra(22, w480, w4a8);
        // ⚠ **当前是 Enable=1（真正开始广播）**，会挂住 —— 这是**已定位的缺陷**，不是回归。
        // 控制实验（Enable=0）能正常返回（`btdm_tx` 6），那次改动**绝不能留在树里**：
        // 否则烧这个构建会看到"rcA=0、tx=6"，误以为广播通了。
        // （采样窗口已提前到 esp_phy_enable 之前 —— 见 stage 64 处注释）
        // **诊断仪器，出厂/生产构建绝不能开**：
        // 1. 它把 T0 武装到 CLIC input 25（BT 归档的 tick 源）；
        // 2. ISR 会在挂住时**擦写 flash 扇区 0x187000**；
        // 3. 这两者都会改变出厂行为 —— 本文件是 bt-blobs 探针，不含在生产固件里。
        // `sample_quiet = true`：ISR 只记环不打印（UART 不可用，打印会自旋）。
        // ⚠ 武装必须在**这里**做：`probe_irqs` 在 `:432` 的武装点读的是**当时**的值，
        // 那时还是 false ⇒ 只置 true 不会让定时器起来（第一次实测环里是垃圾数据）。
        board.trap.resetPcs();
        board.trap.sample_quiet = true;
        board.trap.pc_dump_at = 72;
        if (!probe_irqs) {
            probe_irqs = true;
            board.hw.routeT0Interrupt(25);
            board.hw.armT0Interrupt(2000);
            board.hw.enableInterrupts();
        }
        // ⛔ **门控扫描已回退**（2026-11-19）：对 clk_en0/modem_ctrl0/widgets-conf 写全 1
        //    会把 modem 搞死（marker 停在 61，0x2006 都挂）—— 这些寄存器的位语义
        //    不是"全开"。且 0x20109880 读回恒 0 但总线正常 ⇒ **疑似只写寄存器**
        //    （同 `modem_rst_conf`："读回恒 0, 只可写"）⇒ **写-回读探针对这块无效**，
        //    判据只能用端到端（stage 23 / btdm_tx 6）。
        // ✅ **MODEM_PWR 分组探测结论**（2026-11-19）：组 1（+0x00..+0x1C，读全 0）能完成，
        //    **组 2（+0x20..+0x3C）把总线读挂**（marker 精确停在 67）⇒ 该电源控制区
        //    在 +0x20 处有锋利的可访问性边界；且总线中毒后连 flash 写都不可靠
        //    （组 1 数据扇区 0x18A000 回读全 ff ⇒ 写未落地）。探测已回退，
        //    基线回到 22/5。下次若要继续，从组 2 的第一个字 +0x20 单字探测。
        var ae: [1]u8 = .{1};
        const ra2 = transport.sendCmd(0x200A, &ae);
        flashStage(23);
        osal.logPublic("bt probe: LE rc6={d} rc8={d} rcA={d} tx={d}", .{ r6, r8, ra2, transport.stats().btdm_tx });
    }
    var round: u32 = 0;
    while (round < 2000) : (round += 1) {
        if (ctrl_task) |t| sched.resumeTask(&t.ctx);
        _ = osal.serviceCallouts(osal.timeGet());
        if (transport.stats().evt_count > 0) {
            osal.logPublic("bt probe: GOT {d} EVT, last code=0x{x:0>2}", .{ transport.stats().evt_count, transport.stats().last_evt_code });
            halt();
        }
    }
    osal.logPublic("bt probe: no EVT after {d} rounds (evt={d} cmds={d} btdm_tx={d} alloc_null={d} rw_drops={d})", .{
        round, transport.stats().evt_count, transport.stats().cmds_sent, transport.stats().btdm_tx, transport.stats().cmd_alloc_null, @import("board").hw.rw_drops,
    });
    halt();
}

/// 把 **osal 记录的归档调用点**打出来（panic 时由 board 调）。
/// 这些返回地址是归档自己的 PC —— 采样被我们的钩子占据时，这是唯一的归档侧落点。
fn dumpOsalCallers() void {
    // 先报"我跑了 + 计数是多少"：分开「钩子没被调用」与「环真的空」。
    // **无条件**输出（不随 code_n 阈值）：这是本轮唯一必须拿到的读数。
    osal.canaryScan();
    osal.arenaWalk();
    board.log.line("A{x}/{d}", .{ g_abort_ra, osal.arenaFree() }); // 极短：调用者/空闲
    {
        var mi: u32 = 0;
        while (mi < @min(osal.malloc_calls, 8)) : (mi += 1) board.log.line("M{d} {d} 0x{x}", .{ mi, osal.mc_sizes[mi], osal.mc_rets[mi] });
    }
    board.log.line("MC {d} sz={d} ret=0x{x}", .{ osal.malloc_calls, osal.last_req_size, osal.last_ret });
    board.log.line("CN 0x{x} 0x{x} {d}", .{ osal.canary_base + osal.canary_first_off, osal.canary_first_val, osal.canary_bad_words });
    // 分配结束（0x2f0206a0）之后 56 个字：区分"连续溢出"与"孤立结构化写入"。
    {
        var k: usize = 0;
        var buf: [224]u8 = undefined;
        var w: usize = 0;
        while (k < 56) : (k += 1) {
            const q: *volatile u32 = @ptrFromInt(0x2f0206a0 + k * 4);
            const n = std.fmt.bufPrint(buf[w..], "{x},", .{q.*}) catch break;
            w += n.len;
        }
        board.log.line("W {s}", .{buf[0..w]});
    }
    if (osal.arena_init_magic != 0) board.log.line("AM {x}", .{osal.arena_init_magic});
    if (code_n > 0) board.log.line("CODES n={d} {s}", .{ code_n, code_ring[0..code_n] });
    board.log.line("panic: lc ours={d} other={d} total={d}", .{ log_hook_ours, log_hook_other, log_hook_calls });
    // **进度落点**（纯 RAM，不受串口丢行影响）
    // **用阻塞写**：panic 现场最不能丢的就是这一行（本会话已多次因丢行误判）
    dumpLine("panic: LASTSTEP {d} {s}", .{ bringup.last_step, bringup.last_step_name });
    board.log.line("panic: osaldump reached n={d}", .{osal.caller_n});
    // s0=0x2f00ffe8 = anchor[6]；把 11 个锚点 + 每个非零锚点的 +8 字段打出来，
    // 直接回答「哪个字段未发布」。0x2f00ffd0 是 anchor[0]。
    var ai: usize = 0;
    while (ai < 11) : (ai += 1) {
        // **不要用硬编码 0x2f00ffd0**：锚点符号地址随镜像布局移动
        // （WITH_PHY=1 版里 anchor[0] 在 0x2f010ee0），必须取符号地址。
        const base: usize = @intFromPtr(&@extern(*volatile u32, .{ .name = "r_sym_bt_pSy5Wex1v0iXw5RdWtwL" }));
        const slot: *const volatile u32 = @ptrFromInt(base + 4 * ai);
        const v = slot.*;
        if (v != 0 and v > 0x2f000000 and v < 0x30000000) {
            const f8: *const volatile u32 = @ptrFromInt(@as(usize, v) + 8);
            board.log.line("panic: anchor[{d}]=0x{x:0>8} +8=0x{x:0>8}", .{ ai, v, f8.* });
        } else {
            board.log.line("panic: anchor[{d}]=0x{x:0>8}", .{ ai, v });
        }
    }
    const n = @min(osal.caller_n, 12);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (osal.caller_n +% osal.caller_ring.len - n + i) % osal.caller_ring.len;
        board.log.line("panic: osalcaller[{d}]=0x{x:0>8}", .{ i, osal.caller_ring[idx] });
    }
}

/// 打印 PC 采样：卡住时这是"它在哪转"的唯一线索。
fn dumpPcs() void {
    var pcs: [48]u32 = @splat(0);
    const n = board.trap.samplePcs(&pcs);
    osal.logPublic("bt probe: pc samples n={d} total={d}", .{ n, board.trap.pcSampleCount() });
    var i: usize = 0;
    while (i < n) : (i += 1) osal.logPublic("bt probe:   pc[{d}]=0x{x:0>8}", .{ i, pcs[i] });
}

/// 按 8 字一行打印一段 ROM（`0x2f8xxxxx` 可直接读）。
fn dumpRom(tag: []const u8, base: usize, len: usize) void {
    board.log.line("rom {s} @0x{x}", .{ tag, base });
    var off: usize = 0;
    while (off < len) : (off += 32) {
        board.log.line("rom {s} +{d:0>2}: {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
            tag,                                    off,
            board.hw.bt_mmio_read(base + off),      board.hw.bt_mmio_read(base + off + 4),
            board.hw.bt_mmio_read(base + off + 8),  board.hw.bt_mmio_read(base + off + 12),
            board.hw.bt_mmio_read(base + off + 16), board.hw.bt_mmio_read(base + off + 20),
            board.hw.bt_mmio_read(base + off + 24), board.hw.bt_mmio_read(base + off + 28),
        });
    }
}

fn findFirstTask() ?*sched.Task {
    // sched 内部有任务表；这里通过一个公开访问器拿第一个已登记任务。
    return sched.firstTask();
}

/// 停机。**周期性重打判决**：单次打印很容易被 128 B 的 UART FIFO 丢弃，
/// 而停机后没有别的输出可以对照 ⇒ 每 ~2 s 重复一次，保证一定能抓到。
fn halt() noreturn {
    const tr = transport.stats();
    var n: u32 = 0;
    while (true) : (n +%= 1) {
        if (n % 2_000_000 == 1) {
            const bs = bringup.stats();
            const le = tr.last_evt;
            // ⚠ **`board.log.line` 只有 200 字节缓冲，超长会 `catch return` 静默丢弃**
            // （`log.zig:19`）⇒ 判决拆成两行，每行都远低于上限。
            @import("board").log.line(
                "bt HALT: evt={d} cmds={d} btdm_tx={d} alloc={d} drops={d} code=0x{x:0>2} fs={d} rc={d}",
                .{ tr.evt_count, tr.cmds_sent, tr.btdm_tx, tr.cmd_alloc_null, @import("board").hw.rw_drops, tr.last_evt_code, bs.failed_step, bs.last_rc },
            );
            @import("board").log.line(
                "bt HALT evt: {x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2}",
                .{ le[0], le[1], le[2], le[3], le[4], le[5] },
            );
            @import("board").log.line(
                "bt HALT tx: t={x} n={d} {x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2}",
                .{ tr.tx_type, tr.tx_len, tr.tx_head[0], tr.tx_head[1], tr.tx_head[2], tr.tx_head[3], tr.tx_head[4], tr.tx_head[5] },
            );
            @import("board").log.line(
                "bt HALT tx2: {x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2},{x:0>2}",
                .{ tr.tx_head[6], tr.tx_head[7], tr.tx_head[8], tr.tx_head[9], tr.tx_head[10], tr.tx_head[11] },
            );
        }
        asm volatile ("" ::: .{ .memory = true });
    }
}

// ---------------------------------------------------------------------------
// **host 可读的 flash 标记**（`0x186000` = factory 分区尾部，app.bin 只到 ~0xDB000）
//
// 目的：日志通道不可靠时，仍能让 **host** 知道"流程走到哪一步"——
// `esptool read-flash 0x186000 0x10` 即可，**完全不经过 UART**。
//
// ⚠ **绝不能从 NMI 调用**：ROM 的擦写会在临界区里阻塞取指，
// 而 CPU 正从同一片 flash 执行 XIP ⇒ 会硬挂。只在**主上下文**里调用。
// ---------------------------------------------------------------------------
extern fn esp_rom_spiflash_erase_sector(sector_number: u32) c_int;
/// 把 `pc_ring` 一次性写到 **0x187000**（独立扇区，不碰标记的 0x186000）。
/// `esp_rom_spiflash_write` **不自动擦**（`esp_rom_spiflash.h:257-271`）⇒ 先擦。
/// 只写一次：flash 同址只能 1→0，重复写不会更新。
fn dumpPcRing() void {
    // **两扇区分步**：第一步只落 PC 环 + 现场（不碰可疑块，绝对安全）；
    // 第二步才去读 0x20109xxx —— 若那一步把总线读挂，第一步的数据已安全落盘。
    {
        var buf: [7 + 48]u32 = @splat(0);
        // buf[0] = magic（判布局用）
        buf[0] = 0xADC0_FEE0;
        buf[1] = board.trap.pcSampleCount();
        buf[2] = board.trap.dump_s0;
        buf[3] = board.trap.dump_a0;
        buf[4] = board.trap.dump_a1;
        buf[5] = board.trap.dump_ra;
        _ = board.trap.samplePcs(@ptrCast(buf[6..].ptr));
        _ = esp_rom_spiflash_erase_sector(0x187000 / 0x1000);
        _ = esp_rom_spiflash_write(0x187000, &buf, @intCast(@sizeOf(@TypeOf(buf))));
    }
    // 第二步：**此刻环已在自旋、已写过** ⇒ 读回才是"写了是否生效"的真判据。
    {
        var buf2: [14]u32 = @splat(0);
        buf2[0] = 0xADC0_FEE1;
        buf2[1] = (@as(*volatile u32, @ptrFromInt(0x2010_9880))).*;
        buf2[2] = (@as(*volatile u32, @ptrFromInt(0x2010_98A8))).*;
        buf2[3] = (@as(*volatile u32, @ptrFromInt(0x2010_98B8))).*;
        buf2[4] = 0x0FFF_FFFF; // 环里写出去的期望值，放一起方便比对
        buf2[5] = (@as(*volatile u32, @ptrFromInt(0x2010_9400))).*; // widgets CLK_EN 回读（我们写过 bit0）
        buf2[6] = (@as(*volatile u32, @ptrFromInt(0x2010_98BC))).*; // **被轮询的寄存器本身**（应含 bit2）
        buf2[7] = (@as(*volatile u32, @ptrFromInt(0x2010_9C00))).*; // SYSCON CLK_EN（本轮新开）
        buf2[8] = (@as(*volatile u32, @ptrFromInt(0x2010_9C14))).*; // clk_conf1（对照写入值 0x003ff880）
        buf2[9] = (@as(*volatile u32, @ptrFromInt(0x2010_F000))).*; // LPCON CLK_EN（本轮新开）
        buf2[10] = (@as(*volatile u32, @ptrFromInt(0x2010_D800))).*; // **vendor 等 busy 的寄存器**
        buf2[11] = (@as(*volatile u32, @ptrFromInt(0x2010_F83C))).*; // ana mst 块时钟（应含 bit28）
        buf2[12] = (@as(*volatile u32, @ptrFromInt(0x2070_4184))).*; // PMU_RF_PWC（RF 电路电源）
        buf2[13] = (@as(*volatile u32, @ptrFromInt(0x1080_1064))).*; // **CLIC[25] 读回**：bit3 nmies、bit8 IE —— 定责 NMI 未投递还是被清
        _ = esp_rom_spiflash_erase_sector(0x188000 / 0x1000);
        _ = esp_rom_spiflash_write(0x188000, &buf2, @intCast(@sizeOf(@TypeOf(buf2))));
    }
}

extern fn esp_rom_spiflash_write(target_address: u32, src_data: [*]const u32, len_bytes: u32) c_int;

// ⚠ **标记扇区从 0x186000 迁到 0x185000**（2026-11-19 晚）：
// pmu_init 之后 0x186000 的擦写返回成功但数据不落地（同 boot 内其它扇区写均正常，
// 屏蔽/不屏蔽中断都一样）⇒ 该扇区在 pmu 后不可信。host 判读改用 0x185000。
const flash_mark_off: u32 = 0x18_5000;
const flash_mark_magic: u32 = 0x5A17_0000; // 高 16 位是 magic，低 16 位是阶段

/// 把阶段号写入 flash 标记槽。**只能在主上下文调用**。
fn flashStage(n: u32) void {
    if (@import("builtin").target.os.tag != .freestanding) return;
    // ⚠ **必须屏蔽中断**：ROM 的擦/写**不替我们屏蔽** MIE，
    // 而擦写期间 flash 控制器忙 ⇒ 此时进中断可能硬 fault 或写坏扇区，
    // 且症状与"LE 卡住"完全一样。`boot-power-perf/src/flash.zig` 的封装
    // 正是用 `Critical`（清 mstatus.MIE）做这件事。
    // ⚠ `erase_sector` 的参数是**扇区号**，不是地址：
    // 传地址会静默擦到无关位置且返回成功。
    // **实验（2026-11-19 晚）：去掉中断屏蔽**。
    // 现象：pmu_init 之后，走本函数（屏蔽 MIE）的 marker 写静默失败，
    // 而不屏蔽的直接写（0x18A000 快照、ISR dump 0x187000）都成功。
    // ⇒ 区别就是 MIE 屏蔽。若不屏蔽后 marker 恢复更新 ⇒ 屏蔽是元凶
    // （pmu_init 改电源/时钟后，屏蔽 MIE 的擦写路径在此时序下会静默失败）。
    // 风险：擦写期间进中断可能硬 fault —— 本窗口内唯一中断源是刚武装的
    // 2ms 采样器，其 ISR 只读寄存器不写 flash，重叠窗口 ≤ 一次擦除。
    const rc_e = esp_rom_spiflash_erase_sector(flash_mark_off / 0x1000);
    var w: [1]u32 = .{flash_mark_magic | (n & 0xFFFF)};
    const rc_w = esp_rom_spiflash_write(flash_mark_off, &w, 4);
    // 失败日志（独立扇区 0x18E000）：{magic2, stage, 失败} ⇒ “没写成”不再静默
    // 第二个字：**计数器快照**，让 host 一次读出"命令有没有被消费"。
    // 高 16 = btdm_tx（应答数），低 16 = evt_count（leEvtTx 事件数）
    {
        const st = @import("transport.zig").stats();
        var c: [1]u32 = .{(@as(u32, st.btdm_tx) << 16) | (st.evt_count & 0xFFFF)};
        _ = esp_rom_spiflash_write(flash_mark_off + 4, &c, 4);
    }
    if (rc_e != 0 or rc_w != 0) {
        var jb: [3]u32 = .{ 0xADC0_FEE4, n, @as(u32, 1) };
        _ = esp_rom_spiflash_erase_sector(0x18E000 / 0x1000);
        _ = esp_rom_spiflash_write(0x18E000, &jb, 12);
    }
}

/// 同 `flashStage`，但额外把两个观察值写进标记扇区的第 3/4 个字。
fn flashStageExtra(n: u32, a: u32, b: u32) void {
    flashStage(n);
    if (@import("builtin").target.os.tag != .freestanding) return;
    const prev = asm volatile ("csrrci %[v], mstatus, 8"
        : [v] "=r" (-> usize),
    );
    defer _ = asm volatile ("csrw mstatus, %[v]"
        :
        : [v] "r" (prev),
        : .{ .memory = true });
    var w1: [1]u32 = .{a};
    var w2: [1]u32 = .{b};
    _ = esp_rom_spiflash_write(flash_mark_off + 8, &w1, 4);
    _ = esp_rom_spiflash_write(flash_mark_off + 12, &w2, 4);
}
