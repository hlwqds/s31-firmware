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
//!   - `-Dcoex-ble-adv`（要求 `-Dcoex-ble-enable`）：所有判据之后，经 HCI 让 BLE 发不可连接广播（三条命令，从一个
//!     独立栈上的发送任务里发），泵 3 秒、每轮读 synth 锁定位；然后让 Wi-Fi 在 BLE 广播着的时候再走一遍真实链路。
//!     实测（2026-11-27）三条命令都回了 Command Complete，但广播使能之后板子不再出声，后面的判据一次也没跑到；
//!     这一步走到哪，看 flash 里的落盘记录（`probe.zig` 的 `markerWrite`，`tools/ap-side/decode-adv-marker.py` 解码）。
//!
//! **PHY 的归属（ADR-003 第 4 节的第一条板级证据，2026-11-26）。** IDF 的 `esp_phy_enable` 只在 modem 标志为 0
//! 时才初始化 PHY（`phy_init.c:324-342`）；BT 在 Wi-Fi 之后使能时只把自己或进标志。本仓的 BLE 适配层是按
//! "单独跑"写的，`bringup.init` 里自己调了 `esp_phy_load_cal_and_init`（全量重新标定）和一整套"从零打开"的
//! PHY 序列。两个射频同镜时：
//!
//!   - BLE 先 init：这一次性的初始化被 BLE 用掉，Wi-Fi start 时 `register_chipv7_phy` 什么都不做（标定数据
//!     是空的），Wi-Fi 收不到帧；
//!   - Wi-Fi 先 start：Wi-Fi 标定成功（标定数据约 260 个非零字节），BLE init 的两段——`probe_ptr.initPhy()` 与
//!     第 15 步的 `esp_phy_load_cal_and_init`——各自都把 Wi-Fi 建立好的 PHY 配置冲掉：单变量对照里只跳过一段，
//!     全信道扫描就从三十多个 AP 掉到 1–2 个（`docs/verification/coex-verification.md` §15.2）。
//!
//! 所以 `-Dcoex-wifi-link` 的顺序是 Wi-Fi 先 start；`bt.probe.setPhyOwnedByWifi()` 让 BLE 的 init 跳过那两段。
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

const radio_coex = @import("radio_coex");
/// IDF 的时钟单元表与并集运算（`radio-coex/src/owner.zig`）。
const clocks = radio_coex.owner.clocks;

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
/// `-Dcoex-ble-adv` 的广播间隔（0.625 ms × 2 = 1.25 ms 一档，0x00A0 = 200 ms）与广播着的时候泵多久。
const ble_adv_interval_units: u16 = 0x00A0;
const ble_adv_pump_us: u64 = 3_000_000;

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
    log.line("read: LPCON+18 after wifi init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst / bit3 lp_timer)", .{rd(clocks.lpcon_clk_conf)});
    check(wrc == 0, "wifi esp_wifi_init_internal rc={d}", .{wrc});

    // 3) `-Dcoex-wifi-link`：Wi-Fi 先 start（PHY 的一次性初始化与标定从此归 Wi-Fi），核对共享时钟字里
    //    Wi-Fi 与 PHY 的位都在，再扫一次全信道——证明合并镜像里 Wi-Fi 自己是好的，后面的变化才都算在 BLE 的 init 头上。
    var wifi_started = false;
    var base_ap: u16 = 0;
    if (opts.wifi_link) {
        const src = wifi.link.linkStart();
        log.line("coex-merged: wifi first: esp_wifi_start rc={d}", .{src});
        check(src == 0, "wifi first: esp_wifi_start rc={d}", .{src});
        wifi_started = src == 0;
        if (wifi_started) {
            bt.probe.setPhyOwnedByWifi();
            checkClocks("after wifi start", &.{ .wifi, .phy });
            base_ap = wifi.link.linkScan("before ble init");
            check(base_ap > 0, "wifi baseline scan before ble init ap={d}", .{base_ap});
        }
    }

    // 4) BLE：bringup.init。期间关掉 Wi-Fi 侧的让出点（见文件头「调度」）。开了 `-Dcoex-wifi-link` 时它不再做
    //    自己的 PHY 打开序列，也不再重新标定。
    wifi.foreign_context = true;
    const brc = bt.probe.initOnly(@as([*]u8, @ptrFromInt(heap_start + wifi_bytes))[0..bt_bytes]);
    wifi.foreign_context = false;
    log.line("read: LPCON+18 after ble init=0x{x:0>8} (bit0 wifipwr / bit1 coex / bit2 i2c_mst / bit3 lp_timer)", .{rd(clocks.lpcon_clk_conf)});
    check(brc == 0, "ble bringup.init rc={d}", .{brc});
    checkClocks("after ble init", &.{ .wifi, .phy, .ble });

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
            const r = wifi.link.linkRest();
            wifi.link.co_pump = null;
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
    //    在 BLE 广播着的时候再走一遍真实链路（ADR-003 第 5 节的 L4b）。排在最后：广播使能之后 blob 会把串口与定时器
    //    的时钟门控掉，板子从此不再出声，这个分支里的判据一次也没跑到过（`coex-verification.md` §17）；前面的判据
    //    这时已经打完，这一步走到哪由 flash 里的落盘记录回答。
    if (opts.ble_adv) {
        readRadios("before ble adv");
        wifi.foreign_context = true;
        const a = bt.probe.advertiseOnly(ble_adv_interval_units, ble_adv_pump_us);
        wifi.foreign_context = false;
        readRadios("after ble adv");
        wifi.coexReport("ble-adv");
        wifi.coexReadings("ble-adv");
        const fmt_status = struct {
            fn s(v: ?u8) u8 {
                return v orelse 0xFF;
            }
        }.s;
        const adv_ok = a.params_status == 0 and a.data_status == 0 and a.enable_status == 0;
        check(adv_ok, "ble adv commands status params={d} data={d} enable={d}", .{ fmt_status(a.params_status), fmt_status(a.data_status), fmt_status(a.enable_status) });
        check(a.locked_polls > 0, "ble synth lock seen ({d}/{d} polls, first after {d} us)", .{ a.locked_polls, a.polls, a.first_lock_us orelse 0 });
        if (adv_ok and opts.wifi_link and wifi_started) {
            wifi.link.co_pump = &bleStep;
            const r2 = wifi.link.linkRest();
            wifi.link.co_pump = null;
            checkClocks("after wifi link with ble adv", &.{ .wifi, .phy, .ble });
            check(r2.connected and r2.dhcp, "wifi link while ble advertising: connected={} dhcp={}", .{ @intFromBool(r2.connected), @intFromBool(r2.dhcp) });
            check(r2.ping_done, "wifi ping while ble advertising done ({d})", .{@intFromBool(r2.ping_done)});
        }
    }

    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
