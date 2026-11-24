//! `-Dcoex-merged`：两个射频的适配层同链时的自检 section（ADR-003 第 2、3 节）。
//!
//! 一个镜像里同时带着 Wi-Fi blob、BLE controller blob、共存核和两套适配层，顺序是：
//!
//!   1. 把链接脚本给的堆按子系统配额切成两段（ADR-003 第 2 节：一个堆，按子系统设配额）；
//!   2. Wi-Fi 侧 `initOnly`：装 osi 表、**启动共存核**（只在这里 boot 一次）、
//!      `coex_init`、`esp_wifi_init_internal`，到 `INIT OK` 为止；
//!   3. BLE 侧 `initOnly`：装 OSAL 钩子、`bringup.init`，到 `INITED` 为止；
//!   4. 读回共存核两侧的状态，逐条打 `check:` 行。
//!
//! 两个控制器都只做到 init 返回：不 `esp_wifi_start`、不 enable BLE、不发包。这一步不需要射频，
//! 也不抓空口。真正的共存效果（L4）要等两个射频各自打通。
//!
//! 两套适配层在同一个镜像里怎么不打架，见 ADR-003 第 2 节与本文件的调用约定：
//!
//!   - **符号**：12 个同名导出各留一份，规则是「真归档 > 能用的实现 > 计数桩」，落选的一方以弱符号
//!     导出（`wifi-blobs/src/link_stubs.zig`、`bt-blobs/src/event_bus.zig`、`osal/src/osal.zig`、
//!     `bt-blobs/link/wifi_probe_stubs.c`、`radio-coex/link/coex_printf_shim.c`）。
//!   - **调度**：两个切换器各自保存自己的主栈指针，只要不嵌套就互不干扰。init 的顺序是
//!     「主 → Wi-Fi 任务 → 主 → BLE 任务 → 主」，不会嵌套；BLE 的 init 期间把 Wi-Fi 侧的让出点
//!     关掉（`wifi.foreign_context`），万一有谁在 BLE 任务栈上碰到 Wi-Fi 的信号量，也只会
//!     按没拿到处理，不会去改写 Wi-Fi 的主栈指针。
//!   - **共存核的 OS 钩子**只有一套：Wi-Fi 侧 boot 时登记的那套。
//!   - **中断**：两边都不开（与各自的探针镜像同条件）。
//!   - **对内存布局写死的地址**：两边的探针实验都关掉（`experiments = false`、
//!     `bringup.layout_probes = false`）——合并镜像的布局和任何一边的探针镜像都不同。
//!
//! 本文件只在 `-Dcoex-merged` 时被 `enabled` 引用；主机测试不编译它。

const std = @import("std");

const board = @import("board");
const wifi = @import("wifi_blobs_probe");
const bt = @import("bt_core");

const log = board.log;

/// Wi-Fi 拿堆的前多少字节，其余给 BLE。init 实测用量：Wi-Fi 约 38 KB、BLE 约 31 KB
/// （`docs/verification/coex-verification.md`）。合并镜像里堆只有约 160 KB（两边的静态池、
/// trap 栈、blob 的常驻代码都占 SRAM），给 Wi-Fi 多一些是因为它运行期的收发缓冲更多。
pub const wifi_heap_bytes: usize = 112 * 1024;

extern const _heap_start: u8;
extern const _heap_end: u8;

/// `MODEM_LPCON_CLK_CONF_REG`（bit0 Wi-Fi 电源域 / bit1 共存 / bit2 PHY 的 I2C 主控）。
/// 两边的适配层各自写过它：Wi-Fi 侧 init 前按 IDF 对正成 `0x1`（清掉 bit2），BLE 的 PHY 再把 bit2 置回来。
/// 这里只读不写，给 ADR-003 §4 的归属模型（`radio-coex/src/owner.zig`）留一份板上的对照读数。
const lpcon_clk_conf: *volatile u32 = @ptrFromInt(0x2010_F018);

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) g_passed += 1 else g_failed += 1;
    var text_buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
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

    // 2) Wi-Fi：装表、启动共存核、coex_init、esp_wifi_init_internal。
    const wrc = wifi.initOnly(.{ .experiments = false, .heap_len = wifi_bytes });
    log.line("read: LPCON+18 after wifi init=0x{x:0>8}", .{lpcon_clk_conf.*});
    check(wrc == 0, "wifi esp_wifi_init_internal rc={d}", .{wrc});

    // 3) BLE：bringup.init。期间关掉 Wi-Fi 侧的让出点（见文件头「调度」）。
    wifi.foreign_context = true;
    const brc = bt.probe.initOnly(@as([*]u8, @ptrFromInt(heap_start + wifi_bytes))[0..bt_bytes]);
    wifi.foreign_context = false;
    log.line("read: LPCON+18 after ble init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst)", .{lpcon_clk_conf.*});
    check(brc == 0, "ble bringup.init rc={d}", .{brc});

    // 4) 共存核：两侧都应当停在 `inited`（都没 enable）。
    wifi.coexReport("merged");
    check(wifi.coexSideInited(.wifi) and wifi.coexSideInited(.ble), "coex sides wifi={s} ble={s} (both inited)", .{
        @tagName(wifi.coexSide(.wifi)),
        @tagName(wifi.coexSide(.ble)),
    });
    check(wifi.coexRejected() == 0, "coex rejected calls={d}", .{wifi.coexRejected()});
    // 让出点被 BLE 任务栈上的调用碰到的次数：0 说明两边在 init 期间没有经过对方的等待原语。
    check(wifi.foreign_refusals == 0, "wifi idle hook refused on ble stack n={d}", .{wifi.foreign_refusals});

    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
