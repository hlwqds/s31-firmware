const std = @import("std");

const Mod = struct { name: []const u8, path: []const u8, group: Group };
const Group = enum { boot, net, tls, apps, wifi, wire };

const all_modules = [_]Mod{
    .{ .name = "net_ipv4", .path = "../components/net-ipv4/src/selftest.zig", .group = .net },
    .{ .name = "net_udp_dhcp_dns", .path = "../components/net-udp-dhcp-dns/src/selftest.zig", .group = .net },
    .{ .name = "net_tcp", .path = "../components/net-tcp/src/selftest.zig", .group = .net },
    .{ .name = "net_congestion", .path = "../components/net-congestion/src/selftest.zig", .group = .net },
    .{ .name = "net_sockets", .path = "../components/net-sockets/src/selftest.zig", .group = .net },
    .{ .name = "net_ethernet", .path = "../components/net-ethernet/src/selftest.zig", .group = .net },
    .{ .name = "net_wire", .path = "../components/net-wire/src/selftest.zig", .group = .wire },
    .{ .name = "net_tls_http", .path = "../components/net-tls-http/src/selftest.zig", .group = .tls },
    .{ .name = "app_mqtt_ota", .path = "../components/app-mqtt-ota/src/selftest.zig", .group = .apps },
    .{ .name = "wifi_boundary", .path = "../components/wifi-boundary/src/selftest.zig", .group = .wifi },
    .{ .name = "wifi_connect", .path = "../components/wifi-connect/src/selftest.zig", .group = .wifi },
    .{ .name = "ble_802154", .path = "../components/ble-802154/src/selftest.zig", .group = .wifi },
    .{ .name = "wifi_mlme", .path = "../components/wifi-mlme/src/selftest.zig", .group = .wifi },
    .{ .name = "ble_security", .path = "../components/ble-security/src/selftest.zig", .group = .wifi },
    .{ .name = "radio_coex", .path = "../components/radio-coex/src/selftest.zig", .group = .wifi },
    .{ .name = "boot_power_perf", .path = "../components/boot-power-perf/src/selftest.zig", .group = .boot },
    .{ .name = "posix", .path = "../components/posix-compat/src/selftest.zig", .group = .net },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // P0.3 的板级证明工具：往 .rodata 里塞 N 字节静态数组，把 DROM 段撑过旧的 0x7F000。
    // 只有窗口真是 0xB0000 时才能链接成功；烧上去能起来才说明 loader 也接受这个段长。
    const fat_rodata = b.option(usize, "fat-rodata", "pad .rodata with N bytes to prove the DROM window (0 = off)") orelse 0;

    const g_boot = b.option(bool, "boot", "boot/power/perf 子系统") orelse true;
    const g_net = b.option(bool, "net", "IPv4/UDP/TCP/Socket/TLS 子系统") orelse true;
    const g_tls = b.option(bool, "tls", "TLS/HTTP 子系统") orelse false;
    const g_apps = b.option(bool, "apps", "MQTT/OTA 应用协议") orelse false;
    const g_wifi = b.option(bool, "wifi", "Wi-Fi/BLE/802.15.4 边界") orelse false;
    const g_wire = b.option(bool, "wire", "真实链路探针（DHCP+TCP，需主机配合）") orelse false;
    // R3 链接实验：把 IDF 的 Wi-Fi blob（net80211/pp/core）加进链接，看能不能吃下。
    // 只在给了目录时生效；产物**不上板**（适配层全是桩）。
    const wifi_blob_dir = b.option([]const u8, "wifi-blob-dir", "directory with unpacked blob objects (link experiment)") orelse "";
    // 逗号分隔的对象文件名（相对 wifi-blob-dir）。用 `ls *.o | paste -sd,` 生成，
    // 这样链接命令行上一眼能看见到底进了哪些成员，也不用在 build.zig 里做目录扫描。
    const wifi_blob_objs = b.option([]const u8, "wifi-blob-objs", "comma-separated object names inside wifi-blob-dir") orelse "";
    // R3 探针：编进"装表 → 调 esp_wifi_init_internal → 打日志停机"的入口。
    const wifi_init_probe = b.option(bool, "wifi-init-probe", "run the wifi init probe instead of the normal self-test") orelse false;
    // 真实链路探针：init → set_mode → start → 开中断泵任务 → 扫描 → …（干净入口，不带旧探针的实验写）。
    const wifi_link_probe = b.option(bool, "wifi-link-probe", "run the real-link probe (init, start, scan) instead of the normal self-test") orelse false;
    // 真实链路探针的连接阶段：AP 的 SSID 与密码从命令行来。**不入库**——密码会进镜像的 .rodata，
    // 而镜像本身不提交；脚本从对照镜像的本地 sdkconfig（`tools/wifi-idf-oracle/sdkconfig`，已 gitignore）里取。
    const wifi_ap_ssid = b.option([]const u8, "wifi-ap-ssid", "Wi-Fi AP SSID for the link probe's connect phase (do not commit)") orelse "";
    const wifi_ap_password = b.option([]const u8, "wifi-ap-password", "Wi-Fi AP password for the link probe's connect phase (do not commit)") orelse "";
    // R3.3 链接实验：把 BLE controller 归档（libble_app/libbtdm_common/libbtbb/libphy）
    // 加进链接。与 wifi-blob-* 同构：给目录 + 对象清单，产物用于量容量与解符号，
    // 适配面由 components/bt-blobs/link/bt_stubs.c + s31.ld 的 btdm 边界补上。
    const bt_blob_dir = b.option([]const u8, "bt-blob-dir", "directory with unpacked BLE controller objects") orelse "";
    const bt_blob_objs = b.option([]const u8, "bt-blob-objs", "comma-separated object names inside bt-blob-dir") orelse "";
    // **PHY 层**：`libphy.a` 解包后的目录（21 个对象，可装载仅 18 KB）。
    // 链接它 + 调 `phy_get_romfunc_addr()` 才能填充 `g_phyFuns`（PHY 函数表）。
    const phy_lib_dir = b.option([]const u8, "phy-lib-dir", "directory with unpacked libphy.a objects") orelse "";
    const phy_objs = b.option([]const u8, "phy-objs", "comma-separated object names inside phy-lib-dir") orelse "";
    // **IDF 源码编好的 PHY 对象**（从 IDF 的 build 目录直接取，省掉重建头文件树）：
    //   phy_init.c.obj / phy_common.c.obj / btbb_init.c.obj
    //   modem_clock.c.obj / periph_ctrl.c.obj
    // 它们提供 `esp_phy_common_clock_enable` / `phy_module_enable` /
    // `modem_clock_module_enable` —— 这些是 IRAM 代码，我们板上没有。
    const phy_src_objs = b.option([]const u8, "phy-src-objs", "comma-separated absolute paths of IDF PHY objects") orelse "";
    const bt_probe = b.option(bool, "bt-probe", "run the BLE controller probe instead of the normal self-test") orelse false;
    // R5/C3：两个射频的适配层同链（ADR-003 第 2、3 节）。要求 `-Dcoex` 与两个 blob 目录。
    // 入口不变（照常跑各段自检），只在 `enabled` 末尾多一个 `coex_merged` section：
    // 两个控制器的 init 都做到返回为止（`firmware/src/coex_merged.zig`）。
    const coex_merged = b.option(bool, "coex-merged", "link both radio adapter trees in one image and run both controllers' init as a self-test section") orelse false;
    // 合并镜像的实验步骤（要求 `-Dcoex-merged`）：两个控制器 init 之后接着 enable BLE（`bringup.enable`），
    // 把 controller 任务泵一小段，读回 synth 区与时钟寄存器。不发 HCI 命令，只回答"BLE enable 在 APM
    // 过滤器已关、ICG 码已设、共存核已启动的镜像里走到哪"。
    const coex_ble_enable = b.option(bool, "coex-ble-enable", "merged image only: after both inits, enable the BLE controller and pump its task") orelse false;
    // 合并镜像的 Wi-Fi 真实链路步骤（要求 `-Dcoex-merged`）：**Wi-Fi 先 `esp_wifi_start`**，再做 BLE 的 init（和可选的
    // enable），最后走全信道扫描、连接构建时给的 AP、DHCP、ping 网关、断开；泵里让 BLE 的 controller 任务也走。
    // 顺序不能反：PHY 库的一次性初始化与标定只认第一次使能，BLE 先 init 会把它用掉、还会在 init 里重新标定，
    // 两种情况下 Wi-Fi 都收不到帧（`docs/verification/coex-verification.md` §15）。连接阶段要构建时给 AP：
    // `-Dwifi-ap-ssid` / `-Dwifi-ap-password`。只编这一段时把别的 section 都关掉，镜像最小。
    const coex_wifi_link = b.option(bool, "coex-wifi-link", "merged image only: Wi-Fi starts first, then the BLE init (and optional enable), then the Wi-Fi real link (scan, connect, DHCP, ping) with the BLE controller task pumped alongside") orelse false;
    // 合并镜像在真实链路之前打一份寄存器转储（标签 `after-ble-init`，标签之后接扫描），只读不写（要求 `-Dcoex-wifi-link`）。
    const coex_dump = b.option(bool, "coex-dump", "merged image only: dump registers just before the Wi-Fi link") orelse false;
    // 合并镜像的 BLE 广播实验（要求 `-Dcoex-ble-enable`）：所有判据跑完之后，经 HCI 让 BLE controller 发不可连接
    // 广播（LE Set Advertising Parameters / Data / Enable），边泵 controller 任务边读 synth 锁定位，再让 Wi-Fi 在 BLE
    // 广播着的时候走一遍真实链路（ADR-003 第 5 节的 L4b），最后 15 秒只泵 BLE（Wi-Fi 已断开）。排在最后：这一步出问题时
    // 前面的判据已经打完。
    const coex_ble_adv = b.option(bool, "coex-ble-adv", "merged image only: after every check, start BLE advertising over HCI and read the synthesizer lock bit") orelse false;
    // 合并镜像广播实验的中断探针（要求 `-Dcoex-ble-adv`）：发广播使能之前给 trap 处理器挂一个每个中断调一次的钩子，
    // 每 4096 个中断打一行各 CLIC 输入的计数与最近几个被中断的 PC——哪个输入在风暴、主上下文是被谁饿死的，看它。
    const coex_adv_irq = b.option(bool, "coex-adv-irq", "merged image with -Dcoex-ble-adv: hook every interrupt in the trap handler and print the per-input counts plus recent interrupted PCs every 4096 interrupts") orelse false;
    // 合并镜像广播实验的广播间隔（毫秒，5 的倍数：0.625 ms 一档要能整除，规范的范围是 20 ms 到 10.24 s）与每遍 Wi-Fi 链路
    // ping 网关的帧数。默认值就是此前写死的 100 ms 与 10 帧。按广播间隔各量一轮 ping 的时延与丢包，是路线图 C7 的第一组
    // 判据（ADR-003 第 5 节的 L4b）。
    const coex_adv_interval_ms = b.option(u32, "coex-adv-interval-ms", "merged image with -Dcoex-ble-adv: BLE advertising interval in ms, a multiple of 5 in 20..10240 (default 100)") orelse 100;
    const coex_adv_pings = b.option(u16, "coex-adv-pings", "merged image with -Dcoex-ble-adv: echo requests to the gateway per Wi-Fi link pass, in both passes (default 10)") orelse 10;
    // 广播实验里 ping 的间隔（毫秒）。默认 1000 就是探针镜像里的固定值；调小并把帧数给够，就是 BLE 广播着的时候一段持续的
    // Wi-Fi 流量（同一时间只有一帧在飞）。路线图 C7 的第二组判据（有流量的时候核的硬件定时器在不在走、丢不丢）要它。
    const coex_adv_ping_interval_ms = b.option(u32, "coex-adv-ping-interval-ms", "merged image with -Dcoex-ble-adv: milliseconds between echo requests (default 1000); shorter than the 1000 ms reply timeout, the next request goes out as soon as the previous one is answered") orelse 1000;
    // 广播实验里回显请求的载荷字节数（0 到 1472：IP 包 1500 减去 IPv4 与 ICMP 的首部）。默认 32 就是探针镜像里的固定值；
    // 调大，一帧占空口的时间更长。
    const coex_adv_ping_bytes = b.option(u16, "coex-adv-ping-bytes", "merged image with -Dcoex-ble-adv: echo request payload bytes, 0..1472 (default 32)") orelse 32;
    // 广播实验的信道分类（要求 `-Dcoex-ble-adv` 与 `-Dcoex-wifi-link`）：BLE 广播起来之后、第二遍 Wi-Fi 链路之前，把 AP 所在的
    // 2.4 GHz 信道盖住的 BLE 数据信道标成 bad（LE Set Host Channel Classification，Vol 4 Part E §7.8.19），第二遍链路之后
    // 再用一张带保留位的图确认 controller 会拒。路线图 C8。AP 的主信道取自第一遍链路的扫描记录，所以还要 `-Dwifi-ap-ssid`。
    const coex_ble_chan_class = b.option(bool, "coex-ble-chan-class", "merged image with -Dcoex-ble-adv and -Dcoex-wifi-link: after advertising starts, send LE Set Host Channel Classification for the AP's channel and check the controller's status") orelse false;
    // 对照开关（要求 `-Dcoex`，只对 Wi-Fi 探针的 `coexBoot` 生效）：胶水照常链着，但把配置改成 `sw_coexist = false`——
    // 钩子按 IDF 关闭分支的桩值作答，`boot()` 被拒、核不启动。用来把"核不启动"与"钩子换成计数桩"分开
    // （`docs/verification/coex-verification.md` §13.3）。
    const coex_sw_off = b.option(bool, "coex-sw-off", "with -Dcoex: keep the glue linked but answer with IDF's coex-disabled stub values; the core is not booted") orelse false;
    // R5/C2：共存。把 `components/radio-coex` 的胶水链进镜像并绑到真实核心（`libcoexist.a` 与 ROM）。
    // 默认关；关闭时默认镜像与 BT/Wi-Fi 探针镜像逐字节不变（`docs/verification/coex-verification.md`）。
    const coex = b.option(bool, "coex", "link the BLE/Wi-Fi coexistence glue and bind it to the real coex core") orelse false;
    // 逗号分隔的 `libcoexist.a` 成员（解包后的 .o 绝对路径），写法同 phy-src-objs。
    const coex_objs = b.option([]const u8, "coex-objs", "comma-separated absolute paths of the unpacked libcoexist.a members (required by -Dcoex)") orelse "";
    if (coex and coex_objs.len == 0) @panic("-Dcoex 需要 -Dcoex-objs：给出 libcoexist.a 解包出的 11 个 .o");
    if (coex and g_wifi) @panic("-Dcoex 不能与 -Dwifi（自检 section）同开：radio_coex 的 section 模块与胶水模块不能同时含 glue.zig");
    if (coex and wifi_blob_dir.len > 0 and bt_blob_dir.len > 0 and !coex_merged) @panic("-Dcoex 一次只接一个射频的适配层；两个 blob 同链请加 -Dcoex-merged");
    if (coex_sw_off and !coex) @panic("-Dcoex-sw-off 需要 -Dcoex");
    if (coex_merged) {
        if (!coex) @panic("-Dcoex-merged 需要 -Dcoex：共存核是合并镜像的一部分");
        if (wifi_blob_dir.len == 0 or bt_blob_dir.len == 0) @panic("-Dcoex-merged 需要同时给出 -Dwifi-blob-dir 与 -Dbt-blob-dir");
        if (wifi_init_probe or wifi_link_probe or bt_probe) @panic("-Dcoex-merged 不能与 -Dwifi-init-probe / -Dwifi-link-probe / -Dbt-probe 同开：探针镜像的入口不跑各段自检");
    }
    if (coex_ble_enable and !coex_merged) @panic("-Dcoex-ble-enable 需要 -Dcoex-merged");
    if (coex_wifi_link and !coex_merged) @panic("-Dcoex-wifi-link 需要 -Dcoex-merged");
    if (coex_dump and !coex_wifi_link) @panic("-Dcoex-dump 需要 -Dcoex-wifi-link");
    if (coex_adv_irq and !coex_ble_adv) @panic("-Dcoex-adv-irq 需要 -Dcoex-ble-adv");
    if (coex_adv_interval_ms < 20 or coex_adv_interval_ms > 10_240 or coex_adv_interval_ms % 5 != 0) @panic("-Dcoex-adv-interval-ms 要是 20 到 10240 之间 5 的倍数");
    if (coex_adv_pings == 0) @panic("-Dcoex-adv-pings 至少 1");
    if (coex_adv_ping_interval_ms == 0) @panic("-Dcoex-adv-ping-interval-ms 至少 1");
    if (coex_adv_ping_bytes > 1472) @panic("-Dcoex-adv-ping-bytes 至多 1472（IP 包 1500 减去 IPv4 与 ICMP 的首部）");
    if (coex_ble_chan_class and !coex_ble_adv) @panic("-Dcoex-ble-chan-class 需要 -Dcoex-ble-adv：信道分类在广播之后发");
    if (coex_ble_chan_class and !coex_wifi_link) @panic("-Dcoex-ble-chan-class 需要 -Dcoex-wifi-link：AP 的主信道取自第一遍链路的扫描");
    // 共存开关的唯一样子：各适配层（osal、bt-blobs、wifi-blobs）与 app 入口 import 的都是这一个模块。
    const coex_gate_src = if (coex)
        (if (coex_sw_off) "pub const enabled = true;\npub const sw_off = true;\n" else "pub const enabled = true;\npub const sw_off = false;\n")
    else
        "pub const enabled = false;\n";
    const coex_gate = b.createModule(.{ .root_source_file = b.addWriteFiles().add("coex_gate.zig", coex_gate_src) });
    const coex_mod = b.createModule(.{ .root_source_file = b.path("../components/radio-coex/src/glue.zig") });
    // C5 回滚链路：注入一条必然失败的自检，用来制造"连续 3 次失败"。
    const ab_fail = b.option(bool, "ab-fail", "inject a failing self-test entry (C5 rollback trigger)") orelse false;
    // C5 切槽：启动时把下次引导切到 ota_0/ota_1（写 otadata 后复位）。
    const ab_stage = b.option([]const u8, "ab-stage", "stage boot slot: \"a\" or \"b\" (writes otadata, then resets)") orelse "";
    // C7：固定工作量跑周期实测（p50/p95、周期/字节）。默认关闭，避免影响启动时间与日志。
    const perf_run = b.option(bool, "perf-run", "run the cycle benchmark at boot (C7)") orelse false;
    // C7 三档：切 CPU 到 80/160/320 各测一遍（改频，失败会挂；默认关闭）。
    const perf_tiers = b.option(bool, "perf-tiers", "also sweep CPU clock tiers 80/160/320 (C7, changes clocks)") orelse false;
    // C8：按需切回旧版本 —— 把当前槽标 INVALID 后复位，bootloader 改走另一槽/ factory。
    const ab_revert = b.option(bool, "ab-revert", "mark the running slot INVALID and reset (C8 revert-to-old)") orelse false;
    // 细粒度收窄（2026-11-25 起，验证镜像只编涉及的模块）：`-Donly=<section 名,section 名>`。
    // 在各组开关允许的范围内再只留列出的 section；默认（空串）不收窄，六个 profile 逐字节不变。
    // 例：验证 R5 无线离线特性只动了 wifi_mlme 与 ble_802154 两个组件时，
    //   `-Dboot=false -Dnet=false -Dwifi=true -Donly=ble_802154,wifi_mlme`
    // 镜像里就只有这两个自检 section，不带网络组与 wifi_connect 的密码学。
    // 名字必须是 all_modules 里的、且所在组已打开：写错在构建期就报错，免得「以为编进去了、其实没有」。
    const only_list = b.option([]const u8, "only", "comma-separated section names to keep (narrows the group switches; empty = all enabled)") orelse "";
    if (only_list.len > 0) {
        var it = std.mem.splitScalar(u8, only_list, ',');
        while (it.next()) |want| {
            if (want.len == 0) @panic("-Donly 里有空的 section 名（多了一个逗号）");
            var found = false;
            for (all_modules) |m| {
                if (std.mem.eql(u8, m.name, want)) {
                    found = true;
                    if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi, g_wire))
                        @panic(b.fmt("-Donly 里的 {s} 所在的组没有打开：先给对应的组开关（-Dboot / -Dnet / -Dtls / -Dapps / -Dwifi / -Dwire）", .{want}));
                }
            }
            if (!found) @panic(b.fmt("-Donly 里有不存在的 section：{s}", .{want}));
        }
    }

    const board = b.createModule(.{ .root_source_file = b.path("../boards/esp32s31-coreboard/src/board.zig") });
    // **trap↔BT 耦合门控**：trap.zig 引用 bt_print_osal_stats/dbg_tim_*（BT 轮次加的
    // extern），非 BT profile（net-wire 等）不链 bt 对象 ⇒ undefined symbol。此 shim
    // 以 comptime bool 交给 trap，false 时调用点被死代码消除，extern 不再被引用。
    {
        const bt_linked_src = if (bt_blob_dir.len > 0)
            "pub const present = true;\n"
        else
            "pub const present = false;\n";
        const bt_linked = b.createModule(.{ .root_source_file = b.addWriteFiles().add(
            "bt_linked.zig",
            bt_linked_src,
        ) });
        board.addImport("bt_linked", bt_linked);
    }

    var src: []const u8 = "pub const entries = .{\n";
    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi, g_wire)) continue;
        if (!onlyWants(m.name, only_list)) continue;
        // probe 镜像里不能带 posix section：它会把 `osal_kit`（sched/osal）编进 app，
        // 而 `bt_core` 对象里已有一份 ⇒ `bt_swap_context`、`s31_now_us` 等 export 重复。
        // probe 是诊断镜像，本来也不需要那一段。
        // **带 BLE 闭包的镜像里不挂 posix section**：闭包本身已占 `.flash.text` 699 856 /
        // 窗口 720 896，posix 再 +8.75 KB 就溢出（`scripts/check-bt-link.sh` 实测 2032 B）。
        // posix 是自检段，与 BLE 链接无关；真要三者共存必须先扩两段窗口。
        if ((bt_probe or bt_blob_dir.len > 0) and std.mem.eql(u8, m.name, "posix")) continue;
        src = b.fmt("{s}    .{{ .name = \"{s}\", .run = @import(\"{s}\").run }},\n", .{ src, m.name, m.name });
    }
    if (coex_merged) src = b.fmt("{s}    .{{ .name = \"coex_merged\", .run = @import(\"coex_merged\").run }},\n", .{src});
    if (ab_fail) {
        src = b.fmt("{s}    .{{ .name = \"ab-fail\", .run = @import(\"ab_fail\").run }},\n", .{src});
    }
    src = b.fmt("{s}}};\n", .{src});

    const eth_mod = b.createModule(.{ .root_source_file = b.path("../components/net-ethernet/src/api.zig") });
    eth_mod.addImport("board", board);
    const ipv4_mod = b.createModule(.{ .root_source_file = b.path("../components/net-ipv4/src/api.zig") });
    const udp_mod = b.createModule(.{ .root_source_file = b.path("../components/net-udp-dhcp-dns/src/api.zig") });
    const tcp_mod = b.createModule(.{ .root_source_file = b.path("../components/net-tcp/src/api.zig") });
    // socket 层（R2.2d）：net-wire 也要能驱动它，不只是 net 组的自检。
    const socks_mod = b.createModule(.{ .root_source_file = b.path("../components/net-sockets/src/api.zig") });
    socks_mod.addImport("net_tcp", tcp_mod);
    // wifi-connect 的纯逻辑面按模块名给别的组件用（第一个使用者：wifi-blobs 的 supplicant 回调）。
    const wifi_connect_mod = b.createModule(.{ .root_source_file = b.path("../components/wifi-connect/src/api.zig") });

    // OSAL（任务/调度器 + 同步原语）：从 bt-blobs 抽出来的独立组件。
    // 依赖面只有 std + builtin（时间/临界区/随机数是注入钩子），所以没有 board 依赖。
    const osal_mod = b.createModule(.{ .root_source_file = b.path("../components/osal/src/api.zig") });
    // POSIX 兼容层（api 根，**不导入 board**：主机测试目标也要用它）
    const posix_mod = b.createModule(.{ .root_source_file = b.path("../components/posix-compat/src/api.zig") });
    posix_mod.addImport("osal_kit", osal_mod);
    posix_mod.addImport("net_sockets", socks_mod);
    // 共存：开关常驻；胶水模块只在 -Dcoex 时给（关着时 osal.zig 里引用它的分支不会被分析）。
    osal_mod.addImport("coex_gate", coex_gate);
    if (coex) osal_mod.addImport("radio_coex", coex_mod);

    const wf = b.addWriteFiles();
    const enabled_file = wf.add("enabled.zig", src);
    // `boot_power_perf` 模块**无条件**创建：main 需要它（perf 实测），
    // 而 `enabled` 只在 boot 组打开时才引用它 ⇒ 关闭时不会带进任何代码。
    const bpp_mod = b.createModule(.{ .root_source_file = b.path("../components/boot-power-perf/src/selftest.zig") });
    bpp_mod.addImport("board", board);

    const enabled_mod = b.createModule(.{ .root_source_file = enabled_file });
    // `-Dab-fail` 注入的那条自检：永远返回 false，用来制造回滚条件。
    enabled_mod.addImport("ab_fail", b.createModule(.{ .root_source_file = b.addWriteFiles().add(
        "ab_fail.zig",
        "pub fn run() bool {\n    return false;\n}\n",
    ) }));

    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi, g_wire)) continue;
        if (!onlyWants(m.name, only_list)) continue;
        if (std.mem.eql(u8, m.name, "boot_power_perf")) {
            // 复用 bpp_mod：同一份 selftest.zig 不能同时属于两个模块。
            enabled_mod.addImport(m.name, bpp_mod);
            continue;
        }
        const mod = b.createModule(.{ .root_source_file = b.path(m.path) });
        mod.addImport("board", board);
        if (std.mem.eql(u8, m.name, "net_tcp")) {
            mod.addImport("net_tcp", tcp_mod);
        }
        if (std.mem.eql(u8, m.name, "net_sockets")) {
            // section 根（selftest.zig）与组件根（api.zig）是两个模块；
            // selftest 经模块取实现，于是 socket.zig 只属于 api 模块。
            mod.addImport("net_sockets", socks_mod);
        }
        if (std.mem.eql(u8, m.name, "posix")) {
            mod.addImport("posix", posix_mod);
            mod.addImport("osal_kit", osal_mod);
            mod.addImport("net_sockets", socks_mod); // 阻塞 accept 的演示要建一张 socket 表
        }
        if (std.mem.eql(u8, m.name, "net_wire")) {
            mod.addImport("net_ethernet", eth_mod);
            mod.addImport("net_ipv4", ipv4_mod);
            mod.addImport("net_udp", udp_mod);
            mod.addImport("net_tcp", tcp_mod);
            mod.addImport("net_sockets", socks_mod);
        }
        enabled_mod.addImport(m.name, mod);
    }

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/start.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // （注：compiler_rt 在本镜像占 193KB/492 符号的 f128/long-double 软浮点死重
    // （nm 实测：tanq 6932B 等，gc-sections 剥不动、岛内自洽无活根）——0.17.1 的
    // Build API 没有开关字段，正式裁剪留作后续（需扩 s31.ld 窗口以外的研究）。
    // irom 窗口已按 s31-two-segment-window-expansion 技能扩到 0xC0000。
    // 用 `@splat` 而不是 `[_]u8{0x5a} ** N`：后者在 Zig 0.17 里会报 `**` 的空格错误。
    // 必须经由一个 export 函数引用：`@export(&const 数组)` 在 0.17 不会 emit 数据。
    const fat_src = b.fmt(
        \\const blob: [{d}]u8 align(16) linksection(".rodata.fat") = @splat(0x5a);
        \\pub export fn keep() [*]const u8 {{
        \\    return &blob;
        \\}}
        \\
    , .{fat_rodata});
    const fat_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("fat_rodata.zig", fat_src) });
    app.root_module.addImport("fat_rodata", fat_mod);
    var wifi_probe_mod: ?*std.Build.Module = null;
    var bt_core_mod: ?*std.Build.Module = null;

    if (wifi_blob_dir.len > 0) {
        // 目录里是 .a 就按归档加（成员按需取用）；是解包后的 .o 就全部加（等价 --whole-archive）。
        // 后者才是"这个 blob 到底能不能塞进两段窗口"的真实测量。
        var obj_it = std.mem.splitScalar(u8, wifi_blob_objs, ',');
        var added: usize = 0;
        while (obj_it.next()) |name| {
            if (name.len == 0) continue;
            app.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/{s}", .{ wifi_blob_dir, name }) });
            added += 1;
        }
        if (added == 0) @panic("-Dwifi-blob-objs 为空：给它逗号分隔的对象名");
        // 关掉 --gc-sections **只在"量体积"模式**：那时没有真实引用，不关就什么都不会进来。
        // 探针模式有真实入口（esp_wifi_init_internal），必须保持 gc 打开，否则整个 blob 闭包
        // 全被链进来、irom 直接溢出（实测溢出 67 KB）。
        if (!(wifi_init_probe or coex_merged or wifi_link_probe)) app.link_gc_sections = false;
        const blobs_mod = b.createModule(.{ .root_source_file = b.path("../components/wifi-blobs/src/adapter.zig") });
        blobs_mod.addImport("board", board);

        // 归档成员只在被引用时才会取用：用一个独立的 Zig 对象引用 probe()，
        // 否则链接"成功"只是什么都没拉进来。
        const probe_src = "const a = @import(\"wifi_blobs\");\npub export fn wifi_blob_probe() usize {\n    return a.probe();\n}\n";
        const probe_mod = b.createModule(.{
            .root_source_file = b.addWriteFiles().add("wifi_probe.zig", probe_src),
            .target = target,
            .optimize = optimize,
        });
        probe_mod.addImport("wifi_blobs", blobs_mod);
        const probe_obj = b.addObject(.{ .name = "wifi_probe", .root_module = probe_mod });
        app.root_module.addObject(probe_obj);
    }
    // C5：otadata 的真实读写层（分区表 + flash + IDF 32 字节条目）
    const ota_ab_mod = b.createModule(.{ .root_source_file = b.path("../components/boot-power-perf/src/slot.zig") });
    app.root_module.addImport("ota_ab", ota_ab_mod);
    app.root_module.addImport("boot_power_perf", bpp_mod);
    app.root_module.addImport("perf_flag", b.createModule(.{ .root_source_file = b.addWriteFiles().add(
        "perf_flag.zig",
        b.fmt("pub const run = {};\npub const tiers = {};\n", .{ perf_run, perf_tiers }),
    ) }));
    app.root_module.addImport("ab_fail_flag", b.createModule(.{ .root_source_file = b.addWriteFiles().add(
        "ab_flags.zig",
        b.fmt("pub const enabled = {};\npub const stage = \"{s}\";\npub const revert = {};\n", .{ ab_fail, ab_stage, ab_revert }),
    ) }));
    app.root_module.addImport("board", board);
    app.root_module.addImport("enabled", enabled_mod);
    // 探针模块总是存在（start.zig 无条件 import），用 comptime 常量决定是否真的跑：
    // 关闭时是空实现，避免把 blob 的 @extern 引用带进常规构建。
    if ((wifi_init_probe or coex_merged or wifi_link_probe) and wifi_blob_dir.len > 0) {
        const probe_mod = b.createModule(.{
            .root_source_file = b.path(if (wifi_link_probe)
                "../components/wifi-blobs/src/link_probe.zig"
            else
                "../components/wifi-blobs/src/init_probe.zig"),
        });
        probe_mod.addImport("board", board);
        probe_mod.addImport("coex_gate", coex_gate);
        if (coex) probe_mod.addImport("radio_coex", coex_mod);
        probe_mod.addImport("wifi_connect", wifi_connect_mod);
        // 真实链路探针与合并镜像的真实链路步骤在连上之后把驱动的以太网帧接到 IP 栈
        // （`wifi-blobs/src/data_path.zig`：ARP / ICMP / DHCP）。
        if (wifi_link_probe or coex_wifi_link) {
            probe_mod.addImport("net_ipv4", ipv4_mod);
            probe_mod.addImport("net_udp", udp_mod);
        }
        const probe_opts = b.addOptions();
        probe_opts.addOption([]const u8, "ap_ssid", wifi_ap_ssid);
        probe_opts.addOption([]const u8, "ap_password", wifi_ap_password);
        probe_mod.addOptions("probe_opts", probe_opts);
        // C 变参 shim：Zig 定义不了变参函数，驱动的报错偏偏走它们。
        // 给了 Wi-Fi 对象目录就在这里加一次（下面 BT 那段不再重复加：同一文件加两次会重复定义）。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/wifi-blobs/src/printf_shim.c"), .flags = &.{} });
        wifi_probe_mod = probe_mod;
    }
    if ((wifi_init_probe or wifi_link_probe) and wifi_blob_dir.len > 0) {
        app.root_module.addImport("wifi_init_probe", wifi_probe_mod.?);
    } else {
        const off_src = "pub const enabled = false;\npub fn run() noreturn {\n    unreachable;\n}\n";
        const off_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("wifi_init_probe_off.zig", off_src) });
        app.root_module.addImport("wifi_init_probe", off_mod);
    }
    // PHY 使能有两条路径，行为**不同**（2026-11-18 实测）：
    //   - 不给 `-Dphy-src-objs`：`PROVIDE(esp_phy_enable)` 指到 ROM（`rom_syms.ld`）⇒
    //     bringup 能跑到 step 6 并打印锚点，崩在 deinit 路径 —— **可诊断**；
    //   - 给了 `-Dphy-src-objs`（IDF 编好的 7 个对象）：真实定义覆盖 PROVIDE ⇒ 但镜像
    //     起来就在 PHY 里打 PMU 转储、**没进 bringup** —— 这条路本身待查。
    // 所以不强制任何一条，也不为此 panic。
    if (phy_src_objs.len > 0) {
        var it2 = std.mem.splitScalar(u8, phy_src_objs, ',');
        while (it2.next()) |path| {
            if (path.len == 0) continue;
            app.root_module.addObjectFile(.{ .cwd_relative = path });
        }
    }

    // 共存核的对象、C 侧 shim 与胶水模块。只在 -Dcoex 时进链接。
    // 入口（`firmware/src/main.zig`）在 comptime 里引用 `radio_coex.bind`，
    // 于是 bind.zig 的 37 个 extern 与 43 个钩子函数体都被分析、进镜像。
    app.root_module.addImport("coex_gate", coex_gate);
    if (coex) {
        var coex_it = std.mem.splitScalar(u8, coex_objs, ',');
        while (coex_it.next()) |path| {
            if (path.len == 0) continue;
            app.root_module.addObjectFile(.{ .cwd_relative = path });
        }
        // `coexist_printf` 与 `puts`（C 变参 / 弱桩）。两者的提供者取舍见 shim 文件头：
        // `coexist_printf` 以 shim 为准（真格式化）；`puts` 在有 BLE 对象时由 BLE 侧提供。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/radio-coex/link/coex_printf_shim.c"), .flags = if (bt_blob_dir.len > 0) &.{"-DS31_COEX_NO_PUTS"} else &.{} });
        app.root_module.addImport("radio_coex", coex_mod);
    }

    if (phy_lib_dir.len > 0 and phy_objs.len > 0) {
        var it = std.mem.splitScalar(u8, phy_objs, ',');
        while (it.next()) |name| {
            if (name.len == 0) continue;
            app.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/{s}", .{ phy_lib_dir, name }) });
        }
    }

    if (bt_blob_dir.len > 0) {
        // 与 wifi-blob 同构：逗号分隔的对象清单，逐个加进链接（等价 --whole-archive）。
        // 关掉 gc-sections——这里没有真实引用，不关就一个成员都不会进来，量到的就是空镜像。
        var bt_it = std.mem.splitScalar(u8, bt_blob_objs, ',');
        var bt_added: usize = 0;
        while (bt_it.next()) |name| {
            if (name.len == 0) continue;
            app.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/{s}", .{ bt_blob_dir, name }) });
            bt_added += 1;
        }
        if (bt_added == 0) @panic("-Dbt-blob-objs 为空：给它逗号分隔的对象名");
        // 合并镜像必须开着 gc：两边的入口都只引到各自 init 路径，关掉会把整个 blob 闭包链进来。
        if (!coex_merged) app.link_gc_sections = false;
        // 适配面：10 个符号里的 5 个非链接脚本符号（另 5 个在 s31.ld 里 PROVIDE）。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/bt_stubs.c"), .flags = if (bt_probe or coex_merged) &.{"-DBT_ASSERT_RETURNS=1"} else &.{} });
        // 接管 `ets_printf`：ROM 的 UART 轮询在本板会卡死（PC 采样实测），
        // 归档的日志必须走我们的丢弃实现，否则"打印"就是"挂死"。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/bt_printf_shim.c"), .flags = &.{"-DS31_BT_FMT_LINES=40000"} });
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/wifi_probe_stubs.c"), .flags = &.{} });
        // **轮 118b**：esp_eco3_light.c.obj（已消失的 IDF 生成物）的裸机替身——
        // 8 个 modem/phy/pmu 轻量符号，替代会崩 ROM 的真 obj 闭包。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/modem_clock_light.c"), .flags = &.{} });
        // WiFi osi 栈的 `_log_write`（C 变参）——同签名导出（wifi-blobs 的 shim）。
        // 给了 Wi-Fi 对象目录时它已经在上面加过，不重复加。
        if (wifi_blob_dir.len == 0) app.root_module.addCSourceFile(.{ .file = b.path("../components/wifi-blobs/src/printf_shim.c"), .flags = &.{} });
        // IDF `esp_phy`/`modem_clock` 源码对象的桩（NVS 故意返回 NOT_FOUND ⇒ 全量校准）
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/phy_stubs.c"), .flags = &.{} });
        // OSAL 的 36 个 `wr_btdm_osal_*` 导出（强定义覆盖归档里的弱断言桩）。
        // 单独成对象：它只被归档引用，不需要进 root 模块。
        // **单一模块**：所有 bt-blobs 的文件都属于它（分两个模块会报"文件属于多个模块"）。
        const bt_core = b.createModule(.{
            .root_source_file = b.path("../components/bt-blobs/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        bt_core.addImport("board", board);
        bt_core.addImport("osal_kit", osal_mod);
        bt_core.addImport("coex_gate", coex_gate);
        if (coex) bt_core.addImport("radio_coex", coex_mod);
        // **只在 probe 镜像里编 bt_core**（探针要跑 bringup/transport）。非 probe 的闭包
        // 构建只需要 osal 的 5 个 `s31_*` 导出给归档解析 —— 用下面那个 comptime 根引用触发。
        // 把 bt_core 整个编进来会多 ~2 KB：blob 构建关了 gc-sections，`.flash.text` 会溢出
        // 窗口（`scripts/check-bt-link.sh` 实测 2032 B）。
        if (bt_probe or coex_merged) app.root_module.addImport("bt_core", bt_core);
        bt_core_mod = bt_core;
        // probe 用同一个模块（它 import 的是 `bt_core`，不是相对路径）
        // 直接 import 模块：bt_core 现在是 app 的模块（只编一次），因此既能强制分析
        // （`export fn` 才会发射），也不会像 addObject 那样把 board/osal 再编一遍。
        const probe_shim = "const c = @import(\"bt_core\");\npub const enabled = true;\npub const run = c.probe.run;\n";
        // probe 模块**总是存在**（与 wifi_init_probe 同构）：开则真探针，关则空实现。
        // 只 addImport 不调用是不会被编译的（import 惰性）⇒ 必须由 main.zig 显式引用。
        if (bt_probe) {
            const shim_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("bt_probe_on.zig", probe_shim) });
            shim_mod.addImport("bt_core", bt_core);
            app.root_module.addImport("bt_probe", shim_mod);
        } else if (coex_merged) {
            // 合并镜像里 bt_core 已由 `coex_merged` section 引用（探针的诊断导出都在它里面），
            // 不能再挂 closure_stubs（会与 bt_core 的导出撞名）；这里只要一个"不跑"的垫片。
            const off_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add(
                "bt_probe_off.zig",
                "pub const enabled = false;\npub fn run() noreturn {\n    unreachable;\n}\n",
            ) });
            app.root_module.addImport("bt_probe", off_mod);
        } else {
            // 归档要的 5 个 `s31_*` 在 osal.zig 里；没人引用就不会发射（惰性分析）。
            // 根引用必须挂在**会被引用的模块**上：main 引用 `bt_probe.enabled` ⇒ 本模块被分析
            // ⇒ 下面这行 comptime 生效。单独 import 一个锚点模块不会分析它（试过，5 个仍未定义）。
            // 非探针闭包构建里，trap.zig（bt_linked.present 为真时）与 link/*.c 引用的探针
            // 诊断符号只存在于 bt_core（仅 -Dbt-probe 编译）⇒ 11 个未定义符号
            // （2026-11-24 check-bt-link.sh 实测）。空实现在 closure_stubs.zig，同样挂在这里：
            // 不能 addObject，单独成对象会把 board 的导出再编一份，链接期撞名。
            const closure_stubs = b.createModule(.{
                .root_source_file = b.path("../components/bt-blobs/link/closure_stubs.zig"),
            });
            closure_stubs.addImport("board", board);
            const off_src = "const k = @import(\"osal_kit\");\n" ++
                "const cs = @import(\"bt_closure_stubs\");\n" ++
                "comptime {\n    k.forceExports();\n    cs.forceExports();\n}\n" ++
                "pub const enabled = false;\npub fn run() noreturn {\n    unreachable;\n}\n";
            const off_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("bt_probe_off.zig", off_src) });
            off_mod.addImport("osal_kit", osal_mod);
            off_mod.addImport("bt_closure_stubs", closure_stubs);
            app.root_module.addImport("bt_probe", off_mod);
        }
    }
    if (coex_merged) {
        const merged_mod = b.createModule(.{ .root_source_file = b.path("src/coex_merged.zig") });
        merged_mod.addImport("board", board);
        merged_mod.addImport("wifi_blobs_probe", wifi_probe_mod.?);
        merged_mod.addImport("bt_core", bt_core_mod.?);
        // 时钟域按单元取并集的板上判据要用 IDF 的单元表（`radio_coex.owner.clocks`）；合并镜像要求 `-Dcoex`。
        merged_mod.addImport("radio_coex", coex_mod);
        // 信道分类的信道图（路线图 C8）是 `ble-802154` 里的纯算术；只把那一个文件接进来。
        const chan_class = b.createModule(.{ .root_source_file = b.path("../components/ble-802154/src/channel_class.zig") });
        merged_mod.addImport("ble_channel_class", chan_class);
        if (coex_ble_adv and !coex_ble_enable) @panic("-Dcoex-ble-adv 需要 -Dcoex-ble-enable：广播之前 controller 要先 enable");
        const merged_opts_src = b.fmt("pub const ble_enable = {};\npub const wifi_link = {};\npub const dump = {};\npub const ble_adv = {};\npub const adv_irq: bool = {};\npub const adv_interval_ms: u32 = {};\npub const adv_pings: u16 = {};\npub const adv_ping_interval_ms: u32 = {};\npub const adv_ping_bytes: u16 = {};\npub const ble_chan_class: bool = {};\n", .{ coex_ble_enable, coex_wifi_link, coex_dump, coex_ble_adv, coex_adv_irq, coex_adv_interval_ms, coex_adv_pings, coex_adv_ping_interval_ms, coex_adv_ping_bytes, coex_ble_chan_class });
        merged_mod.addImport("coex_merged_opts", b.createModule(.{ .root_source_file = b.addWriteFiles().add("coex_merged_opts.zig", merged_opts_src) }));
        enabled_mod.addImport("coex_merged", merged_mod);
    }

    if (bt_blob_dir.len == 0) {
        const off_src = "pub const enabled = false;\npub fn run() noreturn {\n    unreachable;\n}\n";
        const off_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("bt_probe_off2.zig", off_src) });
        app.root_module.addImport("bt_probe", off_mod);
    }

    // 主机侧测试：每个 component 的 host_tests.zig 独立成测试目标，
    // 与章节时代一致——测试入口只 import 纯逻辑模块。
    const test_step = b.step("test", "host-side unit tests (all components)");
    for (all_modules) |m| {
        if (std.mem.eql(u8, m.name, "net_wire")) continue;
        const host_path = b.fmt("{s}", .{std.mem.replaceOwned(u8, b.allocator, m.path, "selftest.zig", "host_tests.zig") catch @panic("oom")});
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(host_path),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        t.root_module.addImport("board", board);
        // net-sockets 的 wire.zig 需要 net_tcp（真实段 ⇄ 组件内段的适配）
        if (m.group == .net) t.root_module.addImport("net_tcp", tcp_mod);
        if (std.mem.eql(u8, m.name, "posix")) {
            // 本层的宿主测试就是 `host_tests.zig`（循环已把 selftest.zig 换成它）
            t.root_module.addImport("osal_kit", osal_mod);
            t.root_module.addImport("net_sockets", socks_mod);
        }
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // OSAL 组件自己的主机测试（20 项：osal 17 + sched 2 + 聚合 1）
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("../components/osal/src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }) });
        // `coex_hooks.zig` 的适配表类型来自 radio_coex；开关在主机测试里恒为关。
        t.root_module.addImport("coex_gate", coex_gate);
        t.root_module.addImport("radio_coex", coex_mod);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // wifi-blobs 的主机测试（`-Dcoex` 的 Wi-Fi 侧钩子在里面）。它没有自检 section，上面的循环
    // 遍历不到——此前这 26+4 个用例没有任何门禁跑过（覆盖率门禁只按文本计数）。
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("../components/wifi-blobs/src/host_tests.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        t.root_module.addImport("radio_coex", coex_mod);
        // `osi_impl` 的 `_slowclk_cal_get` 壳按模块名取板级时钟标定值（常量），主机测试编表时也要它。
        t.root_module.addImport("board", board);
        t.root_module.addImport("wifi_connect", wifi_connect_mod);
        t.root_module.addImport("net_ipv4", ipv4_mod);
        t.root_module.addImport("net_udp", udp_mod);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // bt-blobs 的 OSAL 是纯逻辑，单独成主机测试目标；不起 app 的依赖
    // （归档链接是 opt-in 的 -Dbt-blob-*，常规构建里这个组件不参与）。
    {
        const bt_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("../components/bt-blobs/src/host_tests.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        bt_tests.root_module.addImport("coex_gate", coex_gate);
        bt_tests.root_module.addImport("osal_kit", osal_mod);
        test_step.dependOn(&b.addRunArtifact(bt_tests).step);
    }

    // 探针构建保留符号：panic 的 PC 才能 addr2line 回函数名（生产镜像保持 strip）。
    // 辅助开关 `-Dkeep-symbols`：给其它构建也保留符号表，用来核对"某个符号到底进没进镜像"
    // （strip 过的 ELF 连必然存在的符号都列不出来）。默认关。**它的镜像不等同于 strip 的镜像**：
    // `trapDispatch` 按"有没有符号信息"选诊断路径，实测 `.flash.text` 里有 4 个字节随之变化
    // （大小不变）。所以只拿它核对符号，不拿它做逐字节对比，也不拿它上板取证。
    const keep_symbols = b.option(bool, "keep-symbols", "keep app.elf's symbol table (verification aid; loaded image is unchanged)") orelse false;
    if (bt_probe or keep_symbols) app.root_module.strip = false;
    app.setLinkerScript(b.path("../boards/esp32s31-coreboard/linker/s31.ld"));
    // WiFi/BT 预编译归档引用的外设基址符号（121 个 PROVIDE）

    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}

fn enabled(m: Mod, boot: bool, net: bool, tls: bool, apps: bool, wifi: bool, wire: bool) bool {
    return switch (m.group) {
        .boot => boot,
        .net => net,
        .tls => tls,
        .apps => apps,
        .wifi => wifi,
        .wire => wire,
    };
}

/// `-Donly` 的过滤：空串不过滤；否则只留名单里的 section。
fn onlyWants(name: []const u8, only_list: []const u8) bool {
    if (only_list.len == 0) return true;
    var it = std.mem.splitScalar(u8, only_list, ',');
    while (it.next()) |want| {
        if (std.mem.eql(u8, want, name)) return true;
    }
    return false;
}
