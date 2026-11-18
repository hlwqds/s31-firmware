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

    const board = b.createModule(.{ .root_source_file = b.path("../boards/esp32s31-coreboard/src/board.zig") });

    var src: []const u8 = "pub const entries = .{\n";
    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi, g_wire)) continue;
        // probe 镜像里不能带 posix section：它会把 `osal_kit`（sched/osal）编进 app，
        // 而 `bt_core` 对象里已有一份 ⇒ `bt_swap_context`、`s31_now_us` 等 export 重复。
        // probe 是诊断镜像，本来也不需要那一段。
        if (bt_probe and std.mem.eql(u8, m.name, "posix")) continue;
        src = b.fmt("{s}    .{{ .name = \"{s}\", .run = @import(\"{s}\").run }},\n", .{ src, m.name, m.name });
    }
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

    // OSAL（任务/调度器 + 同步原语）：从 bt-blobs 抽出来的独立组件。
    // 依赖面只有 std + builtin（时间/临界区/随机数是注入钩子），所以没有 board 依赖。
    const osal_mod = b.createModule(.{ .root_source_file = b.path("../components/osal/src/api.zig") });
    // POSIX 兼容层（api 根，**不导入 board**：主机测试目标也要用它）
    const posix_mod = b.createModule(.{ .root_source_file = b.path("../components/posix-compat/src/api.zig") });
    posix_mod.addImport("osal_kit", osal_mod);
    posix_mod.addImport("net_sockets", socks_mod);

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
        if (!wifi_init_probe) app.link_gc_sections = false;
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
    if (wifi_init_probe and wifi_blob_dir.len > 0) {
        const probe_mod = b.createModule(.{ .root_source_file = b.path("../components/wifi-blobs/src/init_probe.zig") });
        probe_mod.addImport("board", board);
        // C 变参 shim：Zig 定义不了变参函数，驱动的报错偏偏走它们。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/wifi-blobs/src/printf_shim.c"), .flags = &.{} });
        app.root_module.addImport("wifi_init_probe", probe_mod);
    } else {
        const off_src = "pub const enabled = false;\npub fn run() noreturn {\n    unreachable;\n}\n";
        const off_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("wifi_init_probe_off.zig", off_src) });
        app.root_module.addImport("wifi_init_probe", off_mod);
    }
    if (phy_src_objs.len > 0) {
        var it2 = std.mem.splitScalar(u8, phy_src_objs, ',');
        while (it2.next()) |path| {
            if (path.len == 0) continue;
            app.root_module.addObjectFile(.{ .cwd_relative = path });
        }
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
        app.link_gc_sections = false;
        // 适配面：10 个符号里的 5 个非链接脚本符号（另 5 个在 s31.ld 里 PROVIDE）。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/bt_stubs.c"), .flags = if (bt_probe) &.{"-DBT_ASSERT_RETURNS=1"} else &.{} });
        // 接管 `ets_printf`：ROM 的 UART 轮询在本板会卡死（PC 采样实测），
        // 归档的日志必须走我们的丢弃实现，否则"打印"就是"挂死"。
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/bt_printf_shim.c"), .flags = &.{} });
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
        // **不作为独立对象**：`addObject` 会把 `board`/`osal_kit` 再编一份，而 app 自己也编
        // 同一批模块 ⇒ `bt_swap_context`、`s31_now_us`、`bt_mmio_read` 等 `export fn` 全部重复。
        // 作为 app 的一个模块引入则只编一次；blob 构建已关 gc-sections，`export` 不会被裁掉。
        app.root_module.addImport("bt_core", bt_core);
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
        } else {
            const off_src = "pub const enabled = false;\npub fn run() noreturn {\n    unreachable;\n}\n";
            const off_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("bt_probe_off.zig", off_src) });
            app.root_module.addImport("bt_probe", off_mod);
        }
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
        bt_tests.root_module.addImport("osal_kit", osal_mod);
        test_step.dependOn(&b.addRunArtifact(bt_tests).step);
    }

    // 探针构建保留符号：panic 的 PC 才能 addr2line 回函数名（生产镜像保持 strip）。
    if (bt_probe) app.root_module.strip = false;
    app.setLinkerScript(b.path("../boards/esp32s31-coreboard/linker/s31.ld"));
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
