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


    const board = b.createModule(.{ .root_source_file = b.path("../boards/esp32s31-coreboard/src/board.zig") });

    var src: []const u8 = "pub const entries = .{\n";
    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi, g_wire)) continue;
        src = b.fmt("{s}    .{{ .name = \"{s}\", .run = @import(\"{s}\").run }},\n", .{ src, m.name, m.name });
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

    const wf = b.addWriteFiles();
    const enabled_file = wf.add("enabled.zig", src);
    const enabled_mod = b.createModule(.{ .root_source_file = enabled_file });

    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi, g_wire)) continue;
        const mod = b.createModule(.{ .root_source_file = b.path(m.path) });
        mod.addImport("board", board);
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
        app.root_module.addCSourceFile(.{ .file = b.path("../components/bt-blobs/link/bt_stubs.c"), .flags = &.{} });
        // OSAL 的 36 个 `wr_btdm_osal_*` 导出（强定义覆盖归档里的弱断言桩）。
        // 单独成对象：它只被归档引用，不需要进 root 模块。
        const osal_mod = b.createModule(.{
            .root_source_file = b.path("../components/bt-blobs/src/osal.zig"),
            .target = target,
            .optimize = optimize,
        });
        const osal_obj = b.addObject(.{ .name = "bt_osal", .root_module = osal_mod });
        app.root_module.addObject(osal_obj);
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
        test_step.dependOn(&b.addRunArtifact(bt_tests).step);
    }

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
