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
//!     （开了 `-Dcoex-ble-enable` 时）。BLE 的射频没有起（R3.3），所以这一步是"一个射频在收发、另一个 enabled"。
//!     顺序为什么不能反，见下面「PHY 的归属」。
//!
//! **PHY 的归属（ADR-003 第 4 节的第一条板级证据，2026-11-26）。** IDF 的 `esp_phy_enable` 只在 modem 标志为 0
//! 时才初始化 PHY（`phy_init.c:324-342`）；BT 在 Wi-Fi 之后使能时只把自己或进标志。本仓的 BLE 适配层是按
//! "单独跑"写的，`bringup.init` 里自己调了 `esp_phy_load_cal_and_init`（全量重新标定）和一整套"从零打开"的
//! PHY 序列。两个射频同镜时：
//!
//!   - BLE 先 init：这一次性的初始化被 BLE 用掉，Wi-Fi start 时 `register_chipv7_phy` 什么都不做（标定数据
//!     是空的），Wi-Fi 收不到帧；
//!   - Wi-Fi 先 start：Wi-Fi 标定成功（标定数据约 260 个非零字节），但 BLE init 里的重新标定把 Wi-Fi 建立好
//!     的 PHY 配置冲掉——同一个 2.4 秒的全信道扫描，BLE init 之前 34–37 个 AP，之后 1–4 个。
//!
//! 所以 `-Dcoex-wifi-link` 的顺序是 Wi-Fi 先 start；`bt.probe.setPhyOwnedByWifi()` 让 BLE 的 init 跳过那两段。
//! BLE 的 init 还会整字改写 `MODEM_SYSCON_CLK_CONF1` 这类时钟寄存器，做完之后把"Wi-Fi start 之后、BLE init
//! 之前"存下的快照里变化过的时钟 / 电源寄存器写回去（`init_probe.radioSnapshot` / `radioRestore`）。后一条是
//! 补救：正解是时钟配置按两个射频的需求取并集（ADR-003 第 4 节的归属模型），还没有做。
//!
//! 只编这一段时把别的 section 都关掉（`-Dboot=false -Dnet=false -Dwire=false -Dwifi=false`），镜像约 1.2 MB。
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
//!   - **中断**：只开 Wi-Fi blob 自己的那一个输入（`link_probe.linkStart`）；BLE 的中断不武装。
//!   - **对内存布局写死的地址**：两边的探针实验都关掉（`experiments = false`、
//!     `bringup.layout_probes = false`）——合并镜像的布局和任何一边的探针镜像都不同。
//!
//! 本文件只在 `-Dcoex-merged` 时被 `enabled` 引用；主机测试不编译它。

const std = @import("std");
const opts = @import("coex_merged_opts");

const board = @import("board");
const wifi = @import("wifi_blobs_probe");
const bt = @import("bt_core");

const log = board.log;

/// Wi-Fi 拿堆的前多少字节，其余给 BLE。init 实测用量：Wi-Fi 约 38 KB、BLE 约 38 KB
/// （`docs/verification/coex-verification.md`）。合并镜像里堆只有约 210 KB（两边的静态池、
/// trap 栈、blob 的常驻代码都占 SRAM），给 Wi-Fi 多一些是因为它运行期的收发缓冲更多：
/// start 之后实测还剩 64 KB。
pub const wifi_heap_bytes: usize = 112 * 1024;

extern const _heap_start: u8;
extern const _heap_end: u8;

/// `MODEM_LPCON_CLK_CONF_REG`（bit0 Wi-Fi 电源域 / bit1 共存 / bit2 PHY 的 I2C 主控）。
/// 两边的适配层各自写过它：Wi-Fi 侧 init 前按 IDF 对正成 `0x1`（清掉 bit2），BLE 的 PHY 再把 bit2 置回来。
/// 这里只读不写，给 ADR-003 §4 的归属模型（`radio-coex/src/owner.zig`）留一份板上的对照读数。
const lpcon_clk_conf: *volatile u32 = @ptrFromInt(0x2010_F018);

/// `-Dcoex-ble-enable` 的步骤里泵 controller 任务多久。
const ble_pump_us: u64 = 1_000_000;

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

/// 泵里的一步：让 BLE 的 controller 任务走一轮。这一轮跑在 BLE 任务的栈上，所以期间关掉 Wi-Fi 侧的让出点——
/// 万一有谁在那里碰到 Wi-Fi 的等待原语，只会按没拿到处理（同 BLE 的 init）。只在开了 `-Dcoex-ble-enable`
/// 之后才装这个钩子：controller 没有被 enable 时泵它没有意义。
fn bleStep() void {
    if (!opts.ble_enable) return;
    wifi.foreign_context = true;
    bt.probe.pumpStep();
    wifi.foreign_context = false;
}

/// 作为 section 跑：全过返回 true。
pub fn run() bool {
    g_passed = 0;
    g_failed = 0;

    // 1) 堆配额：链接脚本的 `_heap_start .. _heap_end`（绝对符号，取地址得到边界值）。
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
    log.line("read: LPCON+18 after wifi init=0x{x:0>8}", .{lpcon_clk_conf.*});
    check(wrc == 0, "wifi esp_wifi_init_internal rc={d}", .{wrc});

    // 3) `-Dcoex-wifi-link`：Wi-Fi 先 start（PHY 的一次性初始化与标定从此归 Wi-Fi），存一份寄存器快照，
    //    再扫一次全信道——证明合并镜像里 Wi-Fi 自己是好的，后面的变化才都算在 BLE 的 init 头上。
    var wifi_started = false;
    if (opts.wifi_link) {
        const src = wifi.link.linkStart();
        log.line("coex-merged: wifi first: esp_wifi_start rc={d}", .{src});
        check(src == 0, "wifi first: esp_wifi_start rc={d}", .{src});
        wifi_started = src == 0;
        if (wifi_started) {
            bt.probe.setPhyOwnedByWifi();
            wifi.radioSnapshot();
            const base_ap = wifi.link.linkScan("before ble init");
            check(base_ap > 0, "wifi baseline scan before ble init ap={d}", .{base_ap});
        }
    }

    // 4) BLE：bringup.init。期间关掉 Wi-Fi 侧的让出点（见文件头「调度」）。开了 `-Dcoex-wifi-link` 时它不再做
    //    自己的 PHY 打开序列，也不再重新标定。
    wifi.foreign_context = true;
    const brc = bt.probe.initOnly(@as([*]u8, @ptrFromInt(heap_start + wifi_bytes))[0..bt_bytes]);
    wifi.foreign_context = false;
    log.line("read: LPCON+18 after ble init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst)", .{lpcon_clk_conf.*});
    check(brc == 0, "ble bringup.init rc={d}", .{brc});

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
    }

    // 7) `-Dcoex-wifi-link`：Wi-Fi 走真实链路的后半段（`link_probe.zig` 的 `linkRest`）：全信道扫描、连接构建时
    //    给的 AP、DHCP、ping 网关、断开。BLE 的 init 改过的时钟 / 电源寄存器先按快照写回。
    if (opts.wifi_link) {
        if (opts.dump) {
            wifi.regDumpAll("after-ble-init");
            wifi.focusDump("after-ble-init");
            wifi.macDumpAll("after-ble-init");
        }
        if (wifi_started) {
            _ = wifi.radioRestore(1);
            const refusals0 = wifi.foreign_refusals;
            wifi.link.co_pump = if (opts.ble_enable) &bleStep else null;
            const r = wifi.link.linkRest();
            wifi.link.co_pump = null;
            wifi.coexReadings("wifi-link");
            readRadios("after wifi link");
            check(r.scan_done and r.ap_num > 0, "wifi scan done={} ap={d}", .{ @intFromBool(r.scan_done), r.ap_num });
            if (r.connect_attempted) {
                check(r.connected, "wifi STA_CONNECTED ({d})", .{@intFromBool(r.connected)});
                check(r.dhcp, "wifi dhcp bound ({d})", .{@intFromBool(r.dhcp)});
                check(r.ping_done, "wifi ping done ({d})", .{@intFromBool(r.ping_done)});
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

    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
