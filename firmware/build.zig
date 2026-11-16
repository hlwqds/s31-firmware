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
    const wifi_blob_dir = b.option([]const u8, "wifi-blob-dir", "directory with libnet80211.a/libpp.a/libcore.a (link experiment)") orelse "";

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
        // 现实会拉进来的那批对象（api/ioctl/sta/output/scan + pp 的 pm/wdev/pp），
        // 由 `ar x` 解包到一个目录后整批链接——等价 --whole-archive，才能真正量出体积。
        const objs = [_][]const u8{
            "ieee80211_api.o",   "ieee80211_ioctl.o", "ieee80211_sta.o",
            "ieee80211_output.o", "ieee80211_scan.o", "pp.o",
            "wdev.o",            "pm.o",
        };
        for (objs) |name| {
            app.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/{s}", .{ wifi_blob_dir, name }) });
        }
        const blobs_mod = b.createModule(.{ .root_source_file = b.path("../components/wifi-blobs/src/adapter.zig") });
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
