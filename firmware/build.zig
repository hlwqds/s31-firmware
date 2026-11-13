const std = @import("std");

const Mod = struct { name: []const u8, path: []const u8, group: Group };
const Group = enum { boot, net, tls, apps, wifi };

const all_modules = [_]Mod{
    .{ .name = "net_ipv4", .path = "../components/net-ipv4/src/selftest.zig", .group = .net },
    .{ .name = "net_udp_dhcp_dns", .path = "../components/net-udp-dhcp-dns/src/selftest.zig", .group = .net },
    .{ .name = "net_tcp", .path = "../components/net-tcp/src/selftest.zig", .group = .net },
    .{ .name = "net_congestion", .path = "../components/net-congestion/src/selftest.zig", .group = .net },
    .{ .name = "net_sockets", .path = "../components/net-sockets/src/selftest.zig", .group = .net },
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

    const g_boot = b.option(bool, "boot", "boot/power/perf 子系统") orelse true;
    const g_net = b.option(bool, "net", "IPv4/UDP/TCP/Socket/TLS 子系统") orelse true;
    const g_tls = b.option(bool, "tls", "TLS/HTTP 子系统") orelse false;
    const g_apps = b.option(bool, "apps", "MQTT/OTA 应用协议") orelse false;
    const g_wifi = b.option(bool, "wifi", "Wi-Fi/BLE/802.15.4 边界") orelse false;

    const board = b.createModule(.{ .root_source_file = b.path("../boards/esp32s31-coreboard/src/board.zig") });

    var src: []const u8 = "pub const entries = .{\n";
    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi)) continue;
        src = b.fmt("{s}    .{{ .name = \"{s}\", .run = @import(\"{s}\").run }},\n", .{ src, m.name, m.name });
    }
    src = b.fmt("{s}}};\n", .{src});

    const wf = b.addWriteFiles();
    const enabled_file = wf.add("enabled.zig", src);
    const enabled_mod = b.createModule(.{ .root_source_file = enabled_file });

    for (all_modules) |m| {
        if (!enabled(m, g_boot, g_net, g_tls, g_apps, g_wifi)) continue;
        const mod = b.createModule(.{ .root_source_file = b.path(m.path) });
        mod.addImport("board", board);
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
    app.root_module.addImport("board", board);
    app.root_module.addImport("enabled", enabled_mod);
    // 主机侧测试：每个 component 的 host_tests.zig 独立成测试目标，
    // 与章节时代一致——测试入口只 import 纯逻辑模块。
    const test_step = b.step("test", "host-side unit tests (all components)");
    for (all_modules) |m| {
        const host_path = b.fmt("{s}", .{std.mem.replaceOwned(u8, b.allocator, m.path, "selftest.zig", "host_tests.zig") catch @panic("oom")});
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(host_path),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        t.root_module.addImport("board", board);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    app.setLinkerScript(b.path("../boards/esp32s31-coreboard/linker/s31.ld"));
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}

fn enabled(m: Mod, boot: bool, net: bool, tls: bool, apps: bool, wifi: bool) bool {
    return switch (m.group) {
        .boot => boot,
        .net => net,
        .tls => tls,
        .apps => apps,
        .wifi => wifi,
    };
}
