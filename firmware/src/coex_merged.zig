//! `-Dcoex-merged`：两个射频的适配层同链时的自检 section（ADR-003 第 2、3 节）。
//!
//! 一个镜像里同时带着 Wi-Fi blob、BLE controller blob、共存核和两套适配层。默认的顺序：
//!
//!   1. 把链接脚本给的堆按子系统配额切成两段（ADR-003 第 2 节：一个堆，按子系统设配额）；
//!   2. Wi-Fi 侧 `initOnly`：装 osi 表、**启动共存核**（只在这里 boot 一次）、`coex_init`、
//!      `esp_wifi_init_internal`，到 `INIT OK` 为止；
//!   3. BLE 侧 `initOnly`：装 OSAL 钩子、`bringup.init`，到 `INITED` 为止；
//!   4. 读回共存核两侧的状态，逐条打 `check:` 行。
//!
//! 默认两个控制器都只做到 init 返回。三个可选开关各在后面多一步：
//!
//!   - `-Dcoex-ble-enable`：enable BLE，把 controller 任务泵 1 秒，前后读 synth 区与时钟 / 射频状态寄存器。
//!     不发 HCI 命令，所以它回答的是"enable 走到哪"，不是 synth 锁没锁——合成器是广播使能命令处理之后
//!     才上电的。
//!   - `-Dcoex-wifi-link`：Wi-Fi 走真实链路。顺序是 Wi-Fi 先 `esp_wifi_start`，再做 BLE 的 init（和可选的 enable），
//!     最后全信道扫描、连接构建时给的 AP、DHCP、ping 网关、断开；泵的每一步都让 BLE 的 controller 任务也走一步
//!     （开了 `-Dcoex-ble-enable` 时）。这一步里 BLE 还没有广播，是"一个射频在收发、另一个 enabled"；两个射频同时
//!     在空口上的是第 8 步（`-Dcoex-ble-adv`）。顺序为什么不能反，见下面「PHY 的归属」。
//!   - `-Dcoex-ble-adv`（要求 `-Dcoex-ble-enable`）：所有判据之后，经 HCI 让 BLE 发不可连接广播（三条命令，从一个
//!     独立栈上的发送任务里发；间隔由 `-Dcoex-adv-interval-ms` 给，默认 100 ms = 0x00A0），泵 3 秒、每轮读 synth 锁定位；然后让 Wi-Fi 在 BLE
//!     再走一遍真实链路，最后 15 秒只泵 BLE（Wi-Fi 已断开、没有流量），给空口那边的蓝牙扫描留一段干净的窗口。BLE 从
//!     广播使能起一直广播到 section 结束，没有发广播关闭命令。实测（2026-11-27）：三条命令都回了 Command Complete，
//!     合成器约 35 ms 内锁定，Wi-Fi 在 BLE 广播着的时候照常连接、DHCP、ping（10 帧不丢，rtt 平均从约 3.5 ms 涨到约
//!     45 ms），工作站的蓝牙扫描看到名字 `s31` 的设备（`coex-verification.md` §17.5）。
//!   - `-Dcoex-adv-irq`（要求 `-Dcoex-ble-adv`）：发广播使能之前给 trap 处理器挂一个每个中断调一次的钩子，每 4096 个中断
//!     打一行各 CLIC 输入的计数与最近几个被中断的 PC——哪个输入在风暴、主上下文是被谁饿死的，看它
//!     （2026-11-27 靠它找到"广播使能之后整机失声"的根因，`coex-verification.md` §17.5）。
//!   - `-Dcoex-adv-ping-interval-ms`：两遍 Wi-Fi 链路里 ping 的间隔（默认 1000 ms）。调小并把 `-Dcoex-adv-pings` 给够，
//!     第二遍链路就是 BLE 广播着的时候一段持续的 Wi-Fi 流量；每遍链路打一行 ping 的统计（`coex-ping[...]`）。
//!   - `-Dcoex-adv-ping-bytes`：回显请求的载荷字节数（默认 32，至多 1472）。调大，一帧占空口的时间更长。
//!   - `-Dcoex-ble-chan-class`（要求 `-Dcoex-ble-adv` 与 `-Dcoex-wifi-link`）：BLE 广播起来之后、第二遍 Wi-Fi 链路之前，
//!     发 LE Set Host Channel Classification（Vol 4 Part E §7.8.19），把 AP 所在的 2.4 GHz 信道盖住的数据信道标成 bad
//!     （路线图 C8；信道图在 `ble-802154/src/channel_class.zig`）。AP 的主信道取自第一遍链路的 `WIFI_EVENT_STA_CONNECTED`，所以要先给
//!     `-Dwifi-ap-ssid`。判据两条：那张图 controller 回 Status 0x00；第二遍链路之后同一张图置上保留位，controller 拒掉它（实测 0x12）。
//!   - `-Dcoex-ping-in-ms`（要求 `-Dcoex-wifi-link`，路线图 C9）：每一遍 Wi-Fi 链路 ping 网关之后留一段窗口，等外面的主机
//!     来 ping 板子、由板子答（`data_path.zig` 的 `handleEchoRequest`）。判据：窗口里至少答了一帧。来 ping 的主机由测试脚本起。
//!   - `-Dcoex-ble-first`（要求 `-Dcoex-wifi-link`，路线图 C9 的对照）：起手顺序反过来，BLE 先 `bringup.init`，Wi-Fi 再
//!     `esp_wifi_start`。三种：`phy_ble`（PHY 的一次性初始化与标定由 BLE 的 init 做）、`phy_deferred`（BLE 的 init 跳过 PHY，
//!     等 Wi-Fi start 时做）、`phy_wifi_first`（BLE 的 init 之前先按 Wi-Fi 的路径把 PHY 打开，BLE 的 init 跳过 PHY）。
//!     见下面「PHY 的归属」。
//!   - `-Dcoex-ble-disable`（要求 `-Dcoex-ble-enable` 与 `-Dcoex-wifi-link`，路线图 C9）：第一遍 Wi-Fi 链路之后按 IDF
//!     `bt_controller_disable` 的顺序关 BLE（八步），默认每一步之后扫一次全信道；`-Dcoex-ble-down-scan=false` 是连着做，
//!     再加 `-Dcoex-ble-down-gap=<ms>` 是每一步之后让 Wi-Fi 空转。核对时钟字，再让 Wi-Fi 走第二遍链路。
//!
//! **PHY 的归属（ADR-003 第 4 节的第一条板级证据，2026-11-26）。** IDF 的 `esp_phy_enable` 只在 modem 标志为 0
//! 时才初始化 PHY（`phy_init.c:324-342`）；BT 在 Wi-Fi 之后使能时只把自己或进标志。本仓的 BLE 适配层是按
//! "单独跑"写的，`bringup.init` 里自己调了 `esp_phy_load_cal_and_init`（全量重新标定）和一整套"从零打开"的
//! PHY 序列。两个射频同镜时：
//!
//!   - BLE 先 init、PHY 也由它打开：这一次性的初始化被 BLE 用掉，Wi-Fi start 时 `register_chipv7_phy` 什么都不做（标定数据
//!     是空的），Wi-Fi 收不到帧——2026-11-27 晚在时钟并集之上重做（`-Dcoex-ble-first=phy_ble`），时钟位全在，扫描还是只有
//!     4 个 AP：是标定的问题，不是时钟的；
//!   - Wi-Fi 先 start：Wi-Fi 标定成功（标定数据约 260 个非零字节），BLE init 的两段——`probe_ptr.initPhy()` 与
//!     第 15 步的 `esp_phy_load_cal_and_init`——各自都把 Wi-Fi 建立好的 PHY 配置冲掉：单变量对照里只跳过一段，
//!     全信道扫描就从三十多个 AP 掉到 1–2 个（`docs/verification/coex-verification.md` §15.2）。
//!
//! 所以 `-Dcoex-wifi-link` 的顺序是 Wi-Fi 先 start；`bt.probe.setPhyOwnedByWifi()` 让 BLE 的 init 跳过那两段。
//! **不能反的是「谁打开 PHY」，不是 controller 的先后**（`coex-verification.md` §20.3）：controller 的 init 要在 PHY 开着的时候做
//! （`phy_deferred`：PHY 没开，BLE 的 init 第 7 步停机）；先按 Wi-Fi 的路径把 PHY 打开（`init_probe.phyEnableWifiOwned`，照
//! blob 在 `esp_wifi_start` 里的前两步：`_wifi_clock_enable`、`_phy_enable`）、再做 BLE 的 init、最后 Wi-Fi start，Wi-Fi 照常
//! （`phy_wifi_first`，36/36）。默认不变；应用要先起 BLE 时按这一种顺序。
//!
//! **时钟域按单元取并集（ADR-003 第 4 节，2026-11-27）。** 两边共享的时钟字（`MODEM_SYSCON_CLK_CONF`、
//! `CLK_CONF1`、`CLK_CONF_FORCE_ON`、`MODEM_LPCON_CLK_CONF`、`HP_SYS_CLKRST_MODEM_CONF`）每一位归一个时钟单元，
//! 归谁见 `radio-coex/src/owner.zig` 的 `clocks`（照 IDF 的依赖表）。两边的适配层在这些字上**只置位、不清位**。
//! 在此之前 BLE 的 init 整字覆盖 `CLK_CONF1`，事后又把"BLE init 之前"的快照整字写回去（`radioSnapshot` /
//! `radioRestore`）：前者清掉 Wi-Fi 的基带与 MAC 时钟（认证关联之后被 AP 以 `reason=7` 断开），后者把 BLE 的
//! 时钟（BT_APB / BTBB / BTMAC、BLE 定时器、modem 安全模块、共存与 LP 定时器时钟、PLL 时钟源）全拿掉——
//! 合并镜像里的 BLE 一直是被这样掐着的。两种写法都已删除；本文件在每一步之后读回这些字，按并集逐位核对。
//!
//! 只编这一段时把别的 section 都关掉（`-Dboot=false -Dnet=false -Dwire=false -Dwifi=false`），镜像约 1.2 MB，
//! 其中约 950 KB 是两个 blob 本身（`scripts/build-coex-link-image.sh` 会打印体积明细）。
//!
//! 两套适配层在同一个镜像里怎么不打架，见 ADR-003 第 2 节与本文件的调用约定：
//!
//!   - **符号**：12 个同名导出各留一份，规则是「真归档 > 能用的实现 > 计数桩」，落选的一方以弱符号
//!     导出（`wifi-blobs/src/link_stubs.zig`、`bt-blobs/src/event_bus.zig`、`osal/src/osal.zig`、
//!     `bt-blobs/link/wifi_probe_stubs.c`、`radio-coex/link/coex_printf_shim.c`）。
//!   - **调度**：两个切换器各自保存自己的主栈指针，只要不嵌套就互不干扰。BLE 的 init、enable 和链路泵里的
//!     每一步 BLE 轮转都跑在 BLE 任务的栈上，期间把 Wi-Fi 侧的让出点关掉（`wifi.foreign_context`），万一有谁
//!     在那里碰到 Wi-Fi 的等待原语，也只会按没拿到处理，不会去改写 Wi-Fi 的主栈指针。
//!   - **共存核的 OS 钩子**只有一套：Wi-Fi 侧 boot 时登记的那套。
//!   - **中断**：全局中断由 Wi-Fi 侧打开（`link_probe.linkStart`）。Wi-Fi blob 用自己的那一个输入；BLE 的中断
//!     （`MODEM_BT_MAC`，CLIC 输入 24）经 `bringup.intrArm` 挂到 ISR 桥上——trap 里只屏蔽、入环，由泵在主上下文代跑。
//!     第 8 步之前核对它登记在分发器查的那个下标上。
//!   - **对内存布局写死的地址**：两边的探针实验都关掉（`experiments = false`、
//!     `bringup.layout_probes = false`）——合并镜像的布局和任何一边的探针镜像都不同。
//!
//! 本文件只在 `-Dcoex-merged` 时被 `enabled` 引用；主机测试不编译它。

const std = @import("std");
const opts = @import("coex_merged_opts");

const board = @import("board");
const wifi = @import("wifi_blobs_probe");
const bt = @import("bt_core");

const radio_coex = @import("radio_coex");
/// IDF 的时钟单元表与并集运算（`radio-coex/src/owner.zig`）。
const clocks = radio_coex.owner.clocks;
/// 信道分类的信道图（路线图 C8）：从 AP 的 2.4 GHz 信道算 BLE 的数据信道图。
const chan_class = @import("ble_channel_class");

const log = board.log;

/// Wi-Fi 拿堆的前多少字节，其余给 BLE。init 实测用量：Wi-Fi 约 38 KB、BLE 约 38 KB
/// （`docs/verification/coex-verification.md`）。合并镜像里堆只有约 210 KB（两边的静态池、
/// trap 栈、blob 的常驻代码都占 SRAM），给 Wi-Fi 多一些是因为它运行期的收发缓冲更多：
/// start 之后实测还剩 64 KB。
pub const wifi_heap_bytes: usize = 112 * 1024;

extern const _heap_start: u8;
extern const _heap_end: u8;

/// `-Dcoex-ble-enable` 的步骤里泵 controller 任务多久。
const ble_pump_us: u64 = 1_000_000;
/// `-Dcoex-ble-adv` 的广播间隔：构建时给毫秒（`-Dcoex-adv-interval-ms`，默认 100），换成 HCI 里的档数——0.625 ms 一档
/// （NimBLE 的 `BLE_HCI_ADV_ITVL` 是 625 µs；100 ms = 0x00A0）。广播着的时候泵多久写死不变。
const ble_adv_interval_units: u16 = @intCast(opts.adv_interval_ms * 8 / 5);
const ble_adv_pump_us: u64 = 3_000_000;
/// 第二遍 Wi-Fi 链路之后，让 BLE 继续广播这么久（只泵；此时 Wi-Fi 已断开、没有流量）：给空口那边的蓝牙扫描留一段稳定的窗口。
const ble_adv_hold_us: u64 = 15_000_000;

inline fn rd(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

/// synth 区（`0x20109880` 起，锁定位是 `0x201098BC` 的 bit2）与时钟 / 射频状态寄存器的原值。
/// 只读不写，也不解读。
fn readRadios(stage: []const u8) void {
    log.line("read[ble {s}]: synth 98bc={x:0>8} 98c0={x:0>8} 98b8={x:0>8} 9880..988c={x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        stage, rd(0x2010_98BC), rd(0x2010_98C0), rd(0x2010_98B8), rd(0x2010_9880), rd(0x2010_9884), rd(0x2010_9888), rd(0x2010_988C),
    });
    log.line("read[ble {s}]: syscon 9c00..9c0c={x:0>8} {x:0>8} {x:0>8} {x:0>8} 9c10={x:0>8} 9c14..9c20={x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        stage, rd(0x2010_9C00), rd(0x2010_9C04), rd(0x2010_9C08), rd(0x2010_9C0C), rd(0x2010_9C10), rd(0x2010_9C14), rd(0x2010_9C18), rd(0x2010_9C1C), rd(0x2010_9C20),
    });
    log.line("read[ble {s}]: fe 0438={x:0>8} 0450={x:0>8} 047c={x:0>8} lpcon+18={x:0>8} clkrst 7040={x:0>8} 71f8={x:0>8}", .{
        stage, rd(0x2010_0438), rd(0x2010_0450), rd(0x2010_047C), rd(0x2010_F018), rd(0x2058_7040), rd(0x2058_71F8),
    });
    log.line("read[ble {s}]: ana f800={x:0>8} f818={x:0>8} f81c={x:0>8}", .{ stage, rd(0x2010_F800), rd(0x2010_F818), rd(0x2010_F81C) });
}

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) g_passed += 1 else g_failed += 1;
    var text_buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

/// 一遍链路里 ping 的统计（路线图 C7：有流量的时候丢不丢、时延多大）。ping 没跑完时没有统计，只打一行说明。
fn logPing(tag: []const u8, r: wifi.link.LinkResult) void {
    if (r.ping) |p| {
        log.line("coex-ping[{s}]: {d} frames of {d} payload bytes, {d} ms apart: sent={d} received={d} timed_out={d} rtt min/avg/max={d}/{d}/{d} us", .{
            tag, opts.adv_pings, opts.adv_ping_bytes, opts.adv_ping_interval_ms, p.sent, p.received, p.timed_out, p.rtt_min_us, p.rttAvgUs(), p.rtt_max_us,
        });
    } else {
        log.line("coex-ping[{s}]: no stats, the ping phase did not finish", .{tag});
    }
}

/// 读回两边共享的时钟字。
fn readClocks() clocks.State {
    return .{
        .clk_conf = rd(clocks.clk_conf),
        .clk_conf_force_on = rd(clocks.clk_conf_force_on),
        .clk_conf1 = rd(clocks.clk_conf1),
        .lpcon_clk_conf = rd(clocks.lpcon_clk_conf),
        .modem_conf = rd(clocks.modem_conf),
    };
}

/// 按并集核对：`mods` 都开着的时候，共享字里应当有的位一个都不能少。少一个就是有一边整字覆盖了另一边的位。
fn checkClocks(stage: []const u8, mods: []const clocks.Module) void {
    const need = clocks.unionOf(mods);
    const got = readClocks();
    const miss = need.missing(got);
    log.line("clocks[{s}]: conf=0x{x:0>8} force_on=0x{x:0>8} conf1=0x{x:0>8} lpcon=0x{x:0>8} modem_conf=0x{x:0>8}", .{
        stage, got.clk_conf, got.clk_conf_force_on, got.clk_conf1, got.lpcon_clk_conf, got.modem_conf,
    });
    check(need.coveredBy(got), "clocks {s}: cover {d} modules (missing conf1=0x{x:0>8} conf=0x{x:0>8} lpcon=0x{x:0>8} modem_conf=0x{x:0>8})", .{
        stage, mods.len, miss.clk_conf1, miss.clk_conf, miss.lpcon_clk_conf, miss.modem_conf,
    });
}

/// 只打一行时钟字，不判（用在还没有立过据的时点）。
fn logClocks(stage: []const u8) void {
    const got = readClocks();
    log.line("clocks[{s}]: conf=0x{x:0>8} force_on=0x{x:0>8} conf1=0x{x:0>8} lpcon=0x{x:0>8} modem_conf=0x{x:0>8}", .{
        stage, got.clk_conf, got.clk_conf_force_on, got.clk_conf1, got.lpcon_clk_conf, got.modem_conf,
    });
}

/// 泵里的一步：让 BLE 的 controller 任务走一轮。这一轮跑在 BLE 任务的栈上，所以期间关掉 Wi-Fi 侧的让出点——
/// 万一有谁在那里碰到 Wi-Fi 的等待原语，只会按没拿到处理（同 BLE 的 init）。只在开了 `-Dcoex-ble-enable`
/// 之后才装这个钩子：controller 没有被 enable 时泵它没有意义。
fn bleStep() void {
    if (!opts.ble_enable) return;
    wifi.foreign_context = true;
    bt.probe.pumpStep();
    wifi.foreign_context = false;
    sampleHwTimers();
}

/// 共存核的五个硬件定时器的使能字（`0x2010F408 + 16*idx` 的 bit0，`coexist_hw.o` 里 `coex_hw_timer_enable` 置的就是它；
/// `coexReadings` 里同一个读法）。ADR-003 第 5 节 L4b 的判据之一是「核的硬件定时器在走」：所以链路的每一泵步采一次
/// （隔 2 ms 最多一次），数的是采了多少次、其中多少次看到使能、见过哪几个定时器。申请与释放落在同一个泵步里的那种武装
/// 这里也看不到，那一种在 `coexReadings` 的 `timers in calls:` 里读。
var timer_samples: u32 = 0;
var timer_enabled_samples: u32 = 0;
var timer_enabled_mask: u8 = 0;
var timer_last_us: u64 = 0;

fn resetHwTimers() void {
    timer_samples = 0;
    timer_enabled_samples = 0;
    timer_enabled_mask = 0;
    timer_last_us = 0;
}

fn sampleHwTimers() void {
    const now = board.hw.nowUs();
    if (board.hw.elapsedUs(timer_last_us) < 2_000) return;
    timer_last_us = now;
    timer_samples += 1;
    var any = false;
    for (0..5) |idx| {
        if ((rd(0x2010_F408 + 16 * idx) & 1) != 0) {
            any = true;
            timer_enabled_mask |= @as(u8, 1) << @intCast(idx);
        }
    }
    if (any) timer_enabled_samples += 1;
}

fn reportHwTimers(tag: []const u8) void {
    log.line("coex-timers[{s}]: {d} samples (at most one per 2 ms), {d} with a timer enabled, timers seen enabled 0x{x:0>2}", .{
        tag, timer_samples, timer_enabled_samples, timer_enabled_mask,
    });
    check(timer_samples > 0, "coex hw timers sampled while {s} ({d} samples, {d} with one enabled)", .{ tag, timer_samples, timer_enabled_samples });
}

inline fn spNow() usize {
    var sp: usize = undefined;
    asm volatile ("mv %[out], sp"
        : [out] "=r" (sp),
    );
    return sp;
}

/// 主栈的高水位。`paintMainStack` 在 section 开始时把栈底以上、当前栈指针以下的空闲部分涂上图案；`mainStackLeft` 从栈底往上数
/// 还有几个字节是图案，就是栈到过的最深处离栈底还有多远。主栈是 SRAM 末尾的 16 KiB（`s31.ld` 的 `_stack_size`），底就是
/// `_heap_end`，再往下是 BLE 堆的顶部。2026-11-27 有一版镜像把主栈溢出了 26 KB（读数函数按值拷贝统计结构，`coexReadings`
/// 的注释），栈底下面没有任何东西会拦住它，所以要量。
const stack_paint: u8 = 0xA5;
var main_stack_free: usize = 0;

/// 读写都走 volatile：第一版用 `@memset`，ReleaseSmall 把它整个消掉了（反汇编里只剩长度的计算），读数恒为「0 B left」。
fn paintMainStack() void {
    const bottom: usize = @intFromPtr(&_heap_end);
    const len = spNow() - 256 - bottom;
    if (len == 0 or len > 64 * 1024) return;
    const free: [*]volatile u8 = @ptrFromInt(bottom);
    for (0..len) |i| free[i] = stack_paint;
    main_stack_free = len;
}

/// 栈到过的最深处离栈底还有多少字节；0 = 碰到了栈底（溢出进 BLE 堆）。
fn mainStackLeft() usize {
    const free: [*]volatile u8 = @ptrFromInt(@intFromPtr(&_heap_end));
    var i: usize = 0;
    while (i < main_stack_free and free[i] == stack_paint) i += 1;
    return i;
}

fn logSp(tag: []const u8) void {
    const left = mainStackLeft();
    log.line("coex-merged: sp[{s}]=0x{x:0>8}; main stack: {d} of {d} free B used at the deepest point ({d} B left above the bottom 0x{x:0>8})", .{
        tag, spNow(), main_stack_free - left, main_stack_free, left, @intFromPtr(&_heap_end),
    });
}

/// 广播实验里两次判「栈没碰到栈底」；别的镜像不打判据，条数不变。
fn checkMainStack(tag: []const u8) void {
    const left = mainStackLeft();
    check(left > 0, "main stack stayed above its bottom while {s} ({d} B left at the deepest point)", .{ tag, left });
}

/// BLE 下电路径的板上判据（路线图 C9，`-Dcoex-ble-disable`）：`bt.probe.downStep` 照 IDF `bt_controller_disable` 的顺序
/// （`esp32s31/bt.c:124-145`）关 BLE，**每一步之后扫一次全信道**——Wi-Fi 是在哪一步之后收不到的，看这里
/// （2026-11-27 晚的第一轮把八步连着做完，之后的扫描是 0 个 AP）。最后前后比时钟字，再让 Wi-Fi 走一遍真实链路。
///
/// 判据的依据是单元表（`radio-coex/src/owner.zig` 的 `clocks`）：BLE 下电只能动**只属于自己**的位——
///   - Wi-Fi 与 PHY 依赖的位一个不少（并集 `unionOf(&.{ .wifi, .phy })`）；
///   - 只属于 BLE 的位（`only(.ble, …)`）在下电之后是空的——下电前它们在，就是这次关掉的。例外是 `MODEM_LPCON_CLK_CONF`
///     的 bit1（共存时钟）：单元表把它列在 BLE 的依赖里，但它归共存核，核还在替 Wi-Fi 做仲裁，这一位不该关；
///   - 时钟源（`HP_SYS_CLKRST_MODEM_CONF`）回到 BLE 来之前的读数 `wifi_modem_conf`。
/// 然后泵里去掉 BLE 的那一步，Wi-Fi 再走一遍链路：BLE 下电不能带着 Wi-Fi 一起倒。
fn bleDownStep(base_ap: u16, wifi_modem_conf: u32) void {
    const before = readClocks();
    logClocks("before ble down");
    var timed_out = false;
    var tag_buf: [24]u8 = undefined;
    bt.probe.downBegin();
    const down_steps = @typeInfo(bt.probe.DownStep).@"enum";
    var down_done_us: u64 = 0;
    inline for (down_steps.field_values) |value| {
        // 泵跑在 BLE 任务的栈上：做这一步期间关掉 Wi-Fi 侧的让出点（同 BLE 的 init / enable）；扫描的时候它不跑。
        const step: bt.probe.DownStep = @fromBackingInt(value);
        wifi.foreign_context = true;
        const d = bt.probe.downStep(step, wifi_modem_conf);
        wifi.foreign_context = false;
        timed_out = timed_out or d.timed_out;
        down_done_us = board.hw.nowUs();
        if (opts.ble_down_scan) {
            const tag = std.fmt.bufPrint(&tag_buf, "ble down {d}/8", .{value}) catch "ble down";
            const n = wifi.link.linkScan(tag);
            log.line("coex-ble-down: {d}/8 {s} a0={d} took {d} us timed_out={d}; wifi scan after it: ap={d} (baseline {d})", .{
                value, step.name(), d.a0, d.took_us, @intFromBool(d.timed_out), n, base_ap,
            });
        } else {
            log.line("coex-ble-down: {d}/8 {s} a0={d} took {d} us timed_out={d}", .{ value, step.name(), d.a0, d.took_us, @intFromBool(d.timed_out) });
        }
        if (!opts.ble_down_scan and opts.ble_down_gap_ms > 0) {
            // 步骤之间只让 Wi-Fi 空转这么久、不扫描：分开「步骤之间要时间」与「步骤之间要 Wi-Fi 在收发」。
            const tag = std.fmt.bufPrint(&tag_buf, "gap {d}/8", .{value}) catch "gap";
            wifi.link.pumpFor(@as(u64, opts.ble_down_gap_ms) * 1000, tag);
        }
    }
    bt.probe.downEnd();
    if (!opts.ble_down_scan) {
        // 八步连着做完（应用里的下电就是这个样子），之后连着扫 35 秒：Wi-Fi 是立刻就聋、还是要过一阵才恢复，看每一行的时间。
        var i: u32 = 0;
        const timeline_us: u64 = if (opts.ble_down_gap_ms > 0) 12_000_000 else 35_000_000;
        while (board.hw.elapsedUs(down_done_us) < timeline_us) : (i += 1) {
            const tag = std.fmt.bufPrint(&tag_buf, "after ble down {d}", .{i}) catch "after ble down";
            const n = wifi.link.linkScan(tag);
            log.line("coex-ble-down: wifi scan {d} ms after the down path: ap={d} (baseline {d})", .{ board.hw.elapsedUs(down_done_us) / 1000, n, base_ap });
        }
    }
    check(!timed_out, "ble down: every step returned within {d} ms", .{bt.probe.down_step_budget_us / 1000});

    const after = readClocks();
    logClocks("after ble down");
    const need_wp = clocks.unionOf(&.{ .wifi, .phy });
    const miss = need_wp.missing(after);
    check(need_wp.coveredBy(after), "clocks after ble down: wifi and phy units all still on (missing conf1=0x{x:0>8} conf=0x{x:0>8} lpcon=0x{x:0>8})", .{
        miss.clk_conf1, miss.clk_conf, miss.lpcon_clk_conf,
    });
    var ble_only = clocks.only(.ble, &.{ .wifi, .phy });
    ble_only.lpcon_clk_conf &= ~@as(u32, 1 << 1); // 共存时钟归核，见上
    const were = ble_only.andWith(before);
    const still = ble_only.andWith(after);
    check(still.isClear(), "ble's own clock units off after the down path (left conf1=0x{x:0>8} conf=0x{x:0>8} lpcon=0x{x:0>8}; were 0x{x:0>8} 0x{x:0>8} 0x{x:0>8})", .{
        still.clk_conf1, still.clk_conf, still.lpcon_clk_conf, were.clk_conf1, were.clk_conf, were.lpcon_clk_conf,
    });
    check(after.modem_conf == wifi_modem_conf, "clock source back to its reading from before ble (0x{x:0>8}, want 0x{x:0>8})", .{ after.modem_conf, wifi_modem_conf });
    // 共存核两侧的状态与计数（BLE 那一次使能应当已经减掉）。
    wifi.coexReport("ble-down");

    // BLE 不再被泵。Wi-Fi 再走一遍真实链路。
    wifi.link.co_pump = null;
    const r3 = wifi.link.linkRest();
    checkClocks("after wifi link with ble down", &.{ .wifi, .phy });
    check(r3.scan_done and r3.ap_num * 2 >= base_ap, "wifi scan after ble down keeps >= half the baseline ap ({d} vs {d})", .{ r3.ap_num, base_ap });
    if (r3.connect_attempted) {
        check(r3.connected and r3.dhcp, "wifi link after ble down: connected={} dhcp={}", .{ @intFromBool(r3.connected), @intFromBool(r3.dhcp) });
        check(r3.ping_done, "wifi ping after ble down done ({d})", .{@intFromBool(r3.ping_done)});
    }
    if (r3.ping != null) logPing("after ble down", r3);
}

/// 作为 section 跑：全过返回 true。
pub fn run() bool {
    g_passed = 0;
    g_failed = 0;
    paintMainStack();
    logSp("start");
    // 广播实验里两遍 Wi-Fi 链路（BLE 只 enable 的那一遍是对照）各 ping 网关 `-Dcoex-adv-pings` 帧；别的镜像里 `link_probe`
    // 的默认值是 10，不经过这里。
    if (opts.ble_adv) {
        wifi.link.ping_count = opts.adv_pings;
        wifi.link.ping_interval_us = @as(u64, opts.adv_ping_interval_ms) * 1000;
        wifi.link.ping_bytes = opts.adv_ping_bytes;
    }
    // 「板子回别人的 ping」（路线图 C9，`-Dcoex-ping-in-ms`）：每一遍链路 ping 网关之后留一段窗口，等外面的主机来 ping 板子。
    if (opts.wifi_link) wifi.link.ping_in_us = @as(u64, opts.ping_in_ms) * 1000;
    const heap_start: usize = @intFromPtr(&_heap_start);
    const heap_end: usize = @intFromPtr(&_heap_end);
    const heap_total = heap_end - heap_start;
    const wifi_bytes = @min(wifi_heap_bytes, heap_total * 3 / 5);
    const bt_bytes = heap_total - wifi_bytes;
    log.line("coex-merged: heap total={d} B wifi={d} B ble={d} B", .{ heap_total, wifi_bytes, bt_bytes });
    check(wifi_bytes >= 64 * 1024 and bt_bytes >= 64 * 1024, "heap split wifi={d}K ble={d}K (both >= 64K)", .{ wifi_bytes / 1024, bt_bytes / 1024 });

    // 2) Wi-Fi：装表、启动共存核、coex_init、esp_wifi_init_internal。要走真实链路时 `feature_caps` 与真实链路
    //    探针、对照镜像取同一个值（见 `init_probe.feature_caps` 的注释）。
    if (opts.wifi_link) wifi.feature_caps = 0x5A1;
    const wrc = wifi.initOnly(.{ .experiments = false, .heap_len = wifi_bytes });
    log.line("read: LPCON+18 after wifi init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst / bit3 lp_timer)", .{rd(clocks.lpcon_clk_conf)});
    check(wrc == 0, "wifi esp_wifi_init_internal rc={d}", .{wrc});

    // 3) 起手。默认（`-Dcoex-wifi-link`）Wi-Fi 先 start（PHY 的一次性初始化与标定从此归 Wi-Fi），核对共享时钟字里
    //    Wi-Fi 与 PHY 的位都在，再扫一次全信道——证明合并镜像里 Wi-Fi 自己是好的，后面的变化才都算在 BLE 的 init 头上。
    //    `-Dcoex-ble-first`（路线图 C9 的对照）把顺序反过来：BLE 先 `bringup.init`，PHY 的一次性初始化与标定由它做
    //    （所以不调 `setPhyOwnedByWifi`）。此刻 Wi-Fi 还没 start，共享时钟字只打出来不判：BLE 的哪些单元要到 enable 才开，
    //    没有单独立过据。
    var wifi_started = false;
    var base_ap: u16 = 0;
    // 第一遍链路里目标 AP 的主信道（0 = 没取到），信道分类（路线图 C8）用它。
    var ap_channel: u8 = 0;
    var ble_inited = false;
    // BLE 来之前（Wi-Fi start 之后）的时钟源读数：BLE 下电路径把它写回去。
    var wifi_modem_conf: u32 = 0;
    if (opts.ble_first) |mode| {
        // 除 `phy_ble` 之外，BLE 的 init 都跳过 PHY 那两段（PHY 仍然归 Wi-Fi）。`phy_wifi_first` 还先按 Wi-Fi 的路径把 PHY
        // 打开并标定——就是 blob 在 `esp_wifi_start` 里调的那条 `_phy_enable`，所以 BLE 的 init 看到的 PHY 状态与默认顺序里
        // （Wi-Fi start 之后）相同，换的只有 controller 的先后；`phy_deferred` 那一轮实测 PHY 没开时 controller 的 init 走不通。
        if (mode != .phy_ble) bt.probe.setPhyOwnedByWifi();
        if (mode == .phy_wifi_first) {
            const prc = wifi.phyEnableWifiOwned();
            check(prc == 0, "phy opened by wifi's path before ble init rc={d}", .{prc});
            checkClocks("phy on, before ble init", &.{.phy});
        }
        wifi.foreign_context = true;
        const brc = bt.probe.initOnly(@as([*]u8, @ptrFromInt(heap_start + wifi_bytes))[0..bt_bytes]);
        wifi.foreign_context = false;
        log.line("read: LPCON+18 after ble init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst / bit3 lp_timer)", .{rd(clocks.lpcon_clk_conf)});
        logClocks("after ble init, before wifi start");
        check(brc == 0, "ble bringup.init (ble first) rc={d}", .{brc});
        ble_inited = brc == 0;
    }
    if (opts.wifi_link) {
        const src = wifi.link.linkStart();
        log.line("coex-merged: wifi {s}: esp_wifi_start rc={d}", .{ if (opts.ble_first != null) "second" else "first", src });
        check(src == 0, "wifi {s}: esp_wifi_start rc={d}", .{ if (opts.ble_first != null) "second" else "first", src });
        wifi_started = src == 0;
        if (wifi_started) {
            if (opts.ble_first != null) {
                // BLE 已经 init 过：三个模块的位都该在。
                checkClocks("after wifi start, ble first", &.{ .wifi, .phy, .ble });
            } else {
                bt.probe.setPhyOwnedByWifi();
                wifi_modem_conf = readClocks().modem_conf;
                checkClocks("after wifi start", &.{ .wifi, .phy });
            }
            base_ap = wifi.link.linkScan(if (opts.ble_first != null) "after ble init, wifi second" else "before ble init");
            check(base_ap > 0, "wifi baseline scan {s} ap={d}", .{ if (opts.ble_first != null) "after ble init (ble first)" else "before ble init", base_ap });
        }
    }

    // 4) BLE：bringup.init。期间关掉 Wi-Fi 侧的让出点（见文件头「调度」）。开了 `-Dcoex-wifi-link` 时它不再做
    //    自己的 PHY 打开序列，也不再重新标定。BLE 先起的镜像里这一步已经在第 3 步做过。
    if (!ble_inited) {
        wifi.foreign_context = true;
        const brc = bt.probe.initOnly(@as([*]u8, @ptrFromInt(heap_start + wifi_bytes))[0..bt_bytes]);
        wifi.foreign_context = false;
        log.line("read: LPCON+18 after ble init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst / bit3 lp_timer)", .{rd(clocks.lpcon_clk_conf)});
        check(brc == 0, "ble bringup.init rc={d}", .{brc});
        checkClocks("after ble init", &.{ .wifi, .phy, .ble });
    }

    // 5) 共存核：BLE 侧停在 `inited`；Wi-Fi 侧是 `inited`，开了 `-Dcoex-wifi-link` 时是 `enabled`（已经 start）。
    wifi.coexReport("merged");
    const wifi_side = wifi.coexSide(.wifi);
    const wifi_side_ok = wifi.coexSideInited(.wifi) or (wifi_started and wifi_side == .enabled);
    check(wifi_side_ok and wifi.coexSideInited(.ble), "coex sides wifi={s} ble={s} (wifi started={}; both at least inited)", .{
        @tagName(wifi_side), @tagName(wifi.coexSide(.ble)), wifi_started,
    });
    check(wifi.coexRejected() == 0, "coex rejected calls={d}", .{wifi.coexRejected()});
    // 让出点被 BLE 任务栈上的调用碰到的次数：0 说明两边没有经过对方的等待原语。
    check(wifi.foreign_refusals == 0, "wifi idle hook refused on ble stack n={d}", .{wifi.foreign_refusals});

    // 6) `-Dcoex-ble-enable`：enable BLE，把 controller 任务泵 `ble_pump_us`。前后各读一次 synth 区与时钟 / 射频
    //    状态寄存器。不发 HCI 命令。
    if (opts.ble_enable) {
        readRadios("before enable");
        wifi.foreign_context = true;
        const erc = bt.probe.enableOnly(ble_pump_us);
        wifi.foreign_context = false;
        readRadios("after enable");
        wifi.coexReport("ble-enable");
        wifi.coexReadings("ble-enable");
        check(erc == 0, "ble bringup.enable rc={d}", .{erc});
        checkClocks("after ble enable", &.{ .wifi, .phy, .ble });
    }

    // 7) `-Dcoex-wifi-link`：Wi-Fi 走真实链路的后半段（`link_probe.zig` 的 `linkRest`）：全信道扫描、连接构建时
    //    给的 AP、DHCP、ping 网关、断开。时钟字不动：两边的位在 BLE 的 init 之后已经都在（上面的核对），链路
    //    就是在"两边都开着"的时钟配置下跑的。
    if (opts.wifi_link) {
        if (opts.dump) {
            wifi.regDumpAll("after-ble-init");
            wifi.focusDump("after-ble-init");
            wifi.macDumpAll("after-ble-init");
        }
        if (wifi_started) {
            const refusals0 = wifi.foreign_refusals;
            wifi.link.co_pump = if (opts.ble_enable) &bleStep else null;
            resetHwTimers();
            const r = wifi.link.linkRest();
            wifi.link.co_pump = null;
            ap_channel = r.ap_channel;
            // 对照：BLE 只 enable、不广播时的 ping 统计。广播实验之外不打，那些镜像的日志不变。
            if (opts.ble_adv) logPing("ble enabled", r);
            // 对照：BLE 只 enable、不广播时定时器的读数。广播实验之外不读出来，那些镜像的判据条数不变。
            if (opts.ble_adv) reportHwTimers("wifi link, ble enabled");
            if (opts.ble_adv) checkMainStack("wifi link, ble enabled");
            wifi.coexReadings("wifi-link");
            readRadios("after wifi link");
            checkClocks("after wifi link", &.{ .wifi, .phy, .ble });
            check(r.scan_done and r.ap_num > 0, "wifi scan done={} ap={d}", .{ @intFromBool(r.scan_done), r.ap_num });
            // BLE 的 init / enable 之后接收灵敏度不该掉：全信道扫描的 AP 数掉到基线的一半以下就不算过。连接、DHCP、ping
            // 那几项抓不住这种退化——2026-11-26 板上实测，基线三十多个 AP、这里只剩 1–4 个时它们照样全过。
            check(r.scan_done and r.ap_num * 2 >= base_ap, "wifi scan after ble keeps >= half the baseline ap ({d} vs {d})", .{ r.ap_num, base_ap });
            if (r.connect_attempted) {
                check(r.connected, "wifi STA_CONNECTED ({d})", .{@intFromBool(r.connected)});
                check(r.dhcp, "wifi dhcp bound ({d})", .{@intFromBool(r.dhcp)});
                check(r.ping_done, "wifi ping done ({d})", .{@intFromBool(r.ping_done)});
                if (opts.ping_in_ms > 0) check(r.ping_in_answered > 0, "board answered inbound pings ({d} answered, {d} valid requests)", .{ r.ping_in_answered, r.ping_in_seen });
                check(r.stayed, "wifi stayed connected 5 s ({d})", .{@intFromBool(r.stayed)});
            }
            // 整轮链路下来，Wi-Fi 的让出点被 BLE 任务栈上的调用碰到的次数应当还是 0。
            check(wifi.foreign_refusals == refusals0, "wifi idle hook refused on ble stack during link n={d}", .{wifi.foreign_refusals - refusals0});
            if (opts.ble_enable) {
                wifi.foreign_context = true;
                bt.probe.pumpFor(200_000);
                wifi.foreign_context = false;
            }
        }
    }

    // 8) `-Dcoex-ble-adv`：所有判据之后，经 HCI 让 BLE 发不可连接广播，泵 3 秒、每轮读 synth 锁定位；然后让 Wi-Fi
    //    在 BLE 广播着的时候再走一遍真实链路（ADR-003 第 5 节的 L4b），最后 15 秒只泵 BLE（Wi-Fi 已断开）。排在最后：
    //    这一步出问题时前面的判据已经打完。
    if (opts.ble_adv) {
        readRadios("before ble adv");
        wifi.foreign_context = true;
        bt.probe.irq_probe = opts.adv_irq;
        // BLE 的中断桥必须登记在分发器查的那个下标上（外部中断号 = CLIC 输入号 − 16）。登记错位时这个电平中断没人
        // 屏蔽，广播使能一处理就无限重入、主上下文饿死——2026-11-27 之前"广播使能之后整机失声"的根因
        // （`coex-verification.md` §17.5）。
        const ble_irq_map = rd(0x2058_5000 + 124 * 4) & 0x3F;
        const ble_irq_handler = bt.probe.handlerForInput(24);
        check(ble_irq_map == 24 and ble_irq_handler != 0, "ble interrupt bridge wired: MODEM_BT_MAC -> input {d} (want 24), handler 0x{x:0>8}", .{ ble_irq_map, ble_irq_handler });
        log.line("coex-merged: ble adv interval {d} ms (0x{x:0>4} x 0.625 ms), pings per wifi pass {d}", .{ opts.adv_interval_ms, ble_adv_interval_units, opts.adv_pings });
        logSp("before ble adv");
        const a = bt.probe.advertiseOnly(ble_adv_interval_units, ble_adv_pump_us);
        wifi.foreign_context = false;
        logSp("after ble adv");
        readRadios("after ble adv");
        wifi.coexReport("ble-adv");
        wifi.coexReadings("ble-adv");
        logSp("after the ble-adv readings");
        const fmt_status = struct {
            fn s(v: ?u8) u8 {
                return v orelse 0xFF;
            }
        }.s;
        const adv_ok = a.params_status == 0 and a.data_status == 0 and a.enable_status == 0;
        check(adv_ok, "ble adv commands status params={d} data={d} enable={d}", .{ fmt_status(a.params_status), fmt_status(a.data_status), fmt_status(a.enable_status) });
        check(a.locked_polls > 0, "ble synth lock seen ({d}/{d} polls, first after {d} us)", .{ a.locked_polls, a.polls, a.first_lock_us orelse 0 });
        // ADR-003 第 5 节 L4b 的另一条判据「BLE 的状态位非 0」：controller 经胶水告诉核的 BLE 状态字（镜像，见
        // `radio-coex/src/glue.zig` 的 `bt_status_words`）在广播起来之后应当非 0。
        const ble_word_adv = radio_coex.bt_status_words[1];
        check(ble_word_adv != 0, "ble status word non-zero while advertising (0x{x:0>4}; the controller's set/clear to the core, mirrored)", .{ble_word_adv});
        // 路线图 C8：把 AP 所在的 2.4 GHz 信道盖住的数据信道标成 bad（LE Set Host Channel Classification，Vol 4 Part E §7.8.19）。
        // 发在广播起来之后、第二遍 Wi-Fi 链路之前，那一遍链路就是在分类已经生效的情况下跑的。AP 的主信道取自第一遍
        // 链路的 `WIFI_EVENT_STA_CONNECTED`。算不出图（第一遍没连上，或者 AP 不在 2.4 GHz 的 1..14 信道上）就跳过，不打判据。
        var chan_map: [5]u8 = @splat(0);
        var chan_span: [2]u8 = .{ 0, 0 };
        var chan_ok = false;
        if (chan_class.avoidingWifiChannel(ap_channel)) |m| {
            chan_map = m.bytes;
            chan_span = chan_class.wifiOverlap(ap_channel) catch .{ 0, 0 };
            chan_ok = true;
        } else |_| {}
        if (opts.ble_chan_class and adv_ok and chan_ok) {
            wifi.foreign_context = true;
            logSp("before the channel class command");
            const st = bt.probe.setChannelClass(chan_map);
            wifi.foreign_context = false;
            logSp("after the channel class command");
            log.line("coex-chan-class: wifi channel {d} ({d} MHz) covers ble data channels {d}..{d}; map {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}, {d} of {d} channels unknown; controller status={d}", .{
                ap_channel,
                chan_class.wifiCenterFreqMhz(ap_channel) catch 0,
                chan_span[0],
                chan_span[1],
                chan_map[0],
                chan_map[1],
                chan_map[2],
                chan_map[3],
                chan_map[4],
                chan_class.channel_count - (chan_span[1] - chan_span[0] + 1),
                chan_class.channel_count,
                fmt_status(st),
            });
            check(st != null and st.? == 0, "ble channel class accepted for wifi channel {d} (status={d})", .{ ap_channel, fmt_status(st) });
        } else {
            log.line("coex-chan-class: skipped (enabled={} advertising ok={} ap channel={d} usable={})", .{ opts.ble_chan_class, adv_ok, ap_channel, chan_ok });
        }
        if (adv_ok and opts.wifi_link and wifi_started) {
            wifi.link.co_pump = &bleStep;
            resetHwTimers();
            const r2 = wifi.link.linkRest();
            wifi.link.co_pump = null;
            reportHwTimers("wifi link, ble advertising");
            checkClocks("after wifi link with ble adv", &.{ .wifi, .phy, .ble });
            check(r2.connected and r2.dhcp, "wifi link while ble advertising: connected={} dhcp={}", .{ @intFromBool(r2.connected), @intFromBool(r2.dhcp) });
            check(r2.ping_done, "wifi ping while ble advertising done ({d})", .{@intFromBool(r2.ping_done)});
            if (opts.ping_in_ms > 0) check(r2.ping_in_answered > 0, "board answered inbound pings while ble advertising ({d} answered, {d} valid requests)", .{ r2.ping_in_answered, r2.ping_in_seen });
            logPing("ble advertising", r2);
            if (opts.ble_chan_class and chan_ok) {
                // 反过来确认 controller 真的在看参数：同一张图把保留位（第 37 位）置上。规范只说保留位应当是 0，没有规定
                // 拒绝时的错误码（NimBLE 回 0x12，Invalid HCI Command Parameters）——判据是「不回 0x00」，回的码打在日志里。
                // 离上一条命令已经过了第二遍链路的工夫（扫描加连接，远超 1 秒的间隔要求）。
                var bad_map = chan_map;
                bad_map[4] |= 0x80;
                wifi.foreign_context = true;
                const st = bt.probe.setChannelClass(bad_map);
                wifi.foreign_context = false;
                log.line("coex-chan-class: map with a reserved bit set {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}, controller status={d}", .{ bad_map[0], bad_map[1], bad_map[2], bad_map[3], bad_map[4], fmt_status(st) });
                check(st != null and st.? != 0, "ble channel class rejects a map with a reserved bit set (status={d})", .{fmt_status(st)});
            }
            // 最后只泵、不再有 Wi-Fi 流量：BLE 在这段时间里一直广播着，工作站的蓝牙扫描靠这段窗口看到它。
            // 前后各读一次合成器锁定位与共存核的读数（核的状态位里应当有 BLE、硬件定时器在走）。
            wifi.foreign_context = true;
            const hold_lock0 = (rd(0x2010_98BC) & 4) != 0;
            bt.probe.pumpFor(ble_adv_hold_us);
            wifi.foreign_context = false;
            const hold_lock1 = (rd(0x2010_98BC) & 4) != 0;
            readRadios("after ble adv hold");
            wifi.coexReport("ble-adv-hold");
            wifi.coexReadings("ble-adv-hold");
            check(hold_lock0 and hold_lock1, "ble synth lock held through the {d} s hold (before={} after={} 98bc=0x{x:0>8})", .{
                ble_adv_hold_us / 1_000_000, @intFromBool(hold_lock0), @intFromBool(hold_lock1), rd(0x2010_98BC),
            });
            check(radio_coex.bt_status_words[1] == ble_word_adv, "ble status word unchanged through the hold (0x{x:0>4})", .{radio_coex.bt_status_words[1]});
            // 中断桥的计数：广播使能之后 blob 的 ISR 经桥入环、被主上下文代跑各了多少次；`count_only` 是代跑的里面
            // 跑的是纯计数桩的次数（blob 没有经 `intr_alloc` 登记自己的 ISR 时才非零）。
            const bs = bt.probe.bridgeStats();
            log.line("bt adv: interrupt bridge counters after the hold: queued={d} drained={d} dropped={d} count_only={d}", .{ bs.queued, bs.drained, bs.dropped, bs.count_only });
        }
    }

    // 10) `-Dcoex-ble-disable`（路线图 C9 的 BLE 下电路径）：所有判据之后，照 IDF `esp_bt_controller_disable` 的顺序关 BLE
    //     （`bt.probe.disableOnly`），核对时钟字里 Wi-Fi 与 PHY 的位一个不少、只属于 BLE 的位都关了、时钟源回到 BLE 来之前
    //     的读数，再让 Wi-Fi 走一遍真实链路（泵里不再有 BLE 的那一步）。排在最后：这一步出问题时前面的判据已经打完。
    if (opts.ble_disable and opts.wifi_link and wifi_started) bleDownStep(base_ap, wifi_modem_conf);

    if (opts.ble_adv) checkMainStack("end");
    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
