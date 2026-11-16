//! 第一次真正执行 blob 代码的探针（R3 的 milestone）。
//!
//! 做四件事：装 osi 表进 ROM 槽位 → 构造 `wifi_init_config_t` → 调
//! `esp_wifi_init_internal` → 打印返回码与"哪些桩被调用过"，然后停机。
//!
//! 判读方式：
//!   - 返回码非 0 且 `osi_stubs.hits` 有非零项 → 那个钩子就是 blob 要的第一样东西；
//!   - 返回码非 0 但 hits 全 0 → 失败发生在真正执行 blob 之前（config 校验/magic）；
//!   - 直接 trap → 落在哪个地址由 trap 处理打印，配 `link_stubs`/`osi_stubs` 的计数区分阶段。
//!
//! **只在 `-Dwifi-init-probe=true` 时参与构建**：常规镜像不受影响。

const std = @import("std");

/// 供 start.zig 做 comptime 选择：探针构建为 true。
pub const enabled = true;
const board = @import("board");
const log = board.log;
const hw = board.hw;
const rng = board.rng;

const osi = @import("osi.zig");
const impl = @import("osi_impl.zig");
const initcfg = @import("init_config.zig");
const osi_stubs = @import("osi_stubs.zig");
const link_stubs = @import("link_stubs.zig");

/// blob 里的入口（`esp_wifi.h:437` / `esp_private/wifi.h`）。
const esp_wifi_init_internal = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{
    .name = "esp_wifi_init_internal",
});

fn nowUsHook() u64 {
    return hw.nowUs();
}
fn fillRandomHook(dst: []u8) void {
    rng.fill(dst);
}
fn macHook() [6]u8 {
    return .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
}

/// C shim 的回调：把驱动自己的报错原样打到串口（只有格式串，变参不展开）。
pub export fn s31_printf_hook(msg: ?[*:0]const u8) void {
    const m = msg orelse return;
    log.line("wifi-blob: {s}", .{std.mem.span(m)});
}

/// `_log_write` 的 C 实现（变参），取地址填进表。
const s31_log_write = @extern(*const anyopaque, .{ .name = "s31_log_write" });

pub fn run() noreturn {
    log.raw("wifi-init-probe: begin\n");

    // 1) 分配器缓冲：用链接脚本给的堆区间（_heap_start.._heap_end）。
    const heap_start: [*]u8 = @ptrFromInt(@intFromPtr(heapStart()));
    const heap_end: [*]u8 = @ptrFromInt(@intFromPtr(heapEnd()));
    const heap_len = @intFromPtr(heap_end) - @intFromPtr(heap_start);
    impl.initArena(heap_start[0..heap_len]);
    log.line("wifi-init-probe: arena={d} B", .{heap_len});

    // 2) 注入硬件钩子
    impl.setHooks(.{ .now_us = &nowUsHook, .fill_random = &fillRandomHook, .mac = &macHook });

    // 3) 建表并装进 ROM 槽位（`g_osi_funcs_p` = 0x2f07ff44）
    var table = impl.makeTable();
    table._log_write = s31_log_write; // C 变参 shim：能看到驱动自己的报错
    // 不预装：`wifi_osi_funcs_register` 会在槽位为空时校验并**自己注册**（反汇编 0x2a-0x2e 的
    // `_version == 9` 检查就在那条路径上）。预装会让它走"已注册"捷径、跳过校验——上一版就是那样，
    // 结果是 258 但看不出原因。
    log.line("wifi-init-probe: osi NOT preinstalled, slot=0x{x:0>8}", .{osi.slot_addr});

    // 3b) 直接问 `wifi_osi_funcs_register` 要一个答案（它是 blob 的全局符号）：
    //     返回非 0 就说明表没通过它的校验（表空 / _version != 9 / _magic 不符）。
    const register = @extern(*const fn (*const osi.Osi) callconv(.c) c_int, .{ .name = "wifi_osi_funcs_register" });
    log.line("wifi-init-probe: table ptr=0x{x:0>8} version={d} magic=0x{x:0>8}", .{
        @intFromPtr(&table), @as(u32, @bitCast(table._version)), @as(u32, @bitCast(table._magic)),
    });
    const rrc = register(&table);
    log.line("wifi-init-probe: wifi_osi_funcs_register rc={d}", .{rrc});
    // 再问 `wifi_api_lock`：init 里第二个 callee，它若非 0 会被原样透传成 rc。
    const api_lock = @extern(*const fn () callconv(.c) c_int, .{ .name = "wifi_api_lock" });
    const lrc = api_lock();
    log.line("wifi-init-probe: wifi_api_lock rc={d}", .{lrc});

    // 4) 构造 config（先构造，后面的阶段调用要传它）
    const cfg = initcfg.defaults(&table);

    // 3c) 逐个调用 init 内部的顺序（反汇编给出的顺序）。注意 `wifi_init_in_caller_task`
    //     带一个 `const wifi_init_config_t*` 参数（对象里是 `mv a0,s1` 后调用）——不传参就会
    //     拿垃圾指针去读 config->magic（实测 trap: mepc=0x40015820, `lw a4,152(s0)`, mtval=0xc2）。
    inline for (.{ "pm_funcs_init", "wdev_funcs_init", "net80211_funcs_init" }) |name| {
        const f = @extern(*const fn () callconv(.c) c_int, .{ .name = name });
        const rc = f();
        log.line("wifi-init-probe: {s} rc={d}", .{ name, rc });
        if (rc != 0) break;
    }
    {
        const f = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{ .name = "wifi_init_in_caller_task" });
        const rc = f(&cfg);
        log.line("wifi-init-probe: wifi_init_in_caller_task rc={d}", .{rc});
    }
    log.line("wifi-init-probe: cfg size={d} magic=0x{x:0>8}", .{ @sizeOf(initcfg.InitConfig), @as(u32, @bitCast(cfg.magic)) });
    const rc = esp_wifi_init_internal(&cfg);
    log.line("wifi-init-probe: esp_wifi_init_internal rc={d}", .{rc});

    // 5) 谁被调用过（按索引报名字）
    var reported: usize = 0;
    for (osi_stubs.hits, 0..) |n, i| {
        if (n == 0) continue;
        log.line("wifi-init-probe: osi stub {s} hits={d}", .{ osi_stubs.names[i], n });
        reported += 1;
        if (reported >= 12) break;
    }
    var lreported: usize = 0;
    for (link_stubs.hits, 0..) |n, i| {
        if (n == 0) continue;
        log.line("wifi-init-probe: link stub {s} hits={d}", .{ link_stubs.names[i], n });
        lreported += 1;
        if (lreported >= 12) break;
    }
    if (reported == 0 and lreported == 0) log.raw("wifi-init-probe: no stub was called\n");
    log.raw("wifi-init-probe: done\n");
    hw.halt();
}

// 链接脚本里的堆边界（`s31.ld:172-173` 定义 `_heap_start` / `_heap_end`）。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}
