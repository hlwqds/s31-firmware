//! BLE 探针里的共存接线（`-Dcoex`）：启动共存核、注入中断判定、打诊断行。
//!
//! IDF 把共存核的启动放在系统初始化的 SECONDARY 级（`esp_coex/src/coexist.c:306-311`：
//! `esp_coex_adapter_register(&g_coex_adapter_funcs)`，然后 `coex_pre_init()`），早于 `app_main`。
//! 裸机镜像没有那一级，等价的位置是"第一个碰射频的 init 之前"——这里选在探针 `run()` 里
//! `bringup.init` 的紧前面：BLE 的 init 第 4 步 `btdm_coex_init` 与 controller 登记 BLE 回调
//! 都在其后。
//!
//! 真正的初始化全在 `coex_pre_init` 里（`libcoexist.a` 反汇编：`coex_core_pre_init` 依次调
//! `coex_schm_init`、`coex_rom_osi_funcs_init`（打印两行版本）、`coex_rom_data_init`
//! （把参数块的指针写进 `g_coex_param_ptr`）、`coex_hw_timer_freq_set`）；`coex_init`
//! （`coex_core_init`）在核里是 `li a0,0; ret`。所以板级判据看的是 `boot()` 这一步，
//! 不是 `btdm_coex_init`。
//!
//! 模块形状：`radio_coex` 的根就是 `radio-coex/src/glue.zig`，所以胶水的声明直接挂在模块上
//! （`radio_coex.instance()`、`radio_coex.Hook`、`radio_coex.calls()` …），其余文件经转出口到达
//! （`radio_coex.bind`、`radio_coex.ble`）。
//!
//! 不开 `-Dcoex` 时每个入口都是空函数，调用点被整体消除；`bind.zig`（37 个 extern）也不会被分析。

const std = @import("std");
const builtin = @import("builtin");
const coex_gate = @import("coex_gate");
const osal_kit = @import("osal_kit");
const radio_coex = if (coex_gate.enabled) @import("radio_coex") else struct {};
const board = @import("board");

const on_target = builtin.target.os.tag == .freestanding;

/// ROM 槽位：`coex_rom_data_init` 把参数块的指针存在这里
/// （`boards/esp32s31-coreboard/linker/rom_syms.ld` 的 `PROVIDE(g_coex_param_ptr = 0x2f07ff94)`）。
extern var g_coex_param_ptr: usize;
/// ROM 槽位：核心经 `esp_coex_adapter_register` 收下的适配表指针
/// （同文件的 `PROVIDE(g_coa_funcs_p = 0x2f07ff98)`）。应等于胶水适配表的地址。
extern var g_coa_funcs_p: usize;
/// ROM：共存核的 ROM 版本串。官方固件启动时的 "coex: ROM version" 一行取自它
/// （此前探针镜像里被 `wifi_glue.zig` 的桩遮住，恒为 "0"）。
extern fn esp_coex_rom_version_get() ?[*:0]const u8;

/// "当前是否在中断上下文"：`mstatus.MIE == 0`。
///
/// trap 入口由硬件清 MIE；临界区也清 MIE——那种情况按"在中断里"作答是安全的一侧
/// （共存核会走不睡眠的 ISR 分支）。IDF 的 `xPortInIsrContext()` 看的是栈。
fn inIsr() bool {
    if (!on_target) return false;
    const mstatus: usize = asm volatile ("csrr %[v], mstatus"
        : [v] "=r" (-> usize),
    );
    return (mstatus & 0x8) == 0;
}

pub const Stage = enum { boot, init, enable };

/// 启动共存核（IDF 的 `init_coexist`）。必须在 `bringup.init` 之前调一次。
///
/// 失败不拦住后面的 BLE init：胶水在"未启动"状态下按 IDF 关闭分支的桩值作答
/// （`ESP_OK`），并计一次拒绝——与 IDF 不看 `init_coexist` 返回值的实际效果一致，
/// 只是这里把原因打出来。
pub fn boot() void {
    if (!coex_gate.enabled) return;
    if (!on_target) return;
    osal_kit.coex_hooks.in_isr_hook = inIsr;
    radio_coex.bind.boot(osal_kit.coex_hooks.hooks(), .{}) catch |e| {
        const g = radio_coex.instance();
        const rej = g.rejected[@backingInt(radio_coex.Hook.boot)];
        const rc: u32 = @bitCast(g.last_core_rc);
        board.log.line("coex[boot]: FAILED {s} rc=0x{x} rejected={d}", .{ @errorName(e), rc, rej });
        return;
    };
    report(.boot);
}

/// 诊断行（三行，都短于 UART FIFO 的 128 字节）。各阶段各打一次。
pub fn report(stage: Stage) void {
    if (!coex_gate.enabled) return;
    if (!on_target) return;
    const g = radio_coex.instance();
    const fw: [*:0]const u8 = if (g.core.version_get) |f| (f() orelse "?") else "?";
    const rom: [*:0]const u8 = esp_coex_rom_version_get() orelse "?";
    var rej: u32 = 0;
    for (g.rejected) |r| rej += r;
    const tag = @tagName(stage);
    board.log.line("coex[{s}]: booted={} wifi={s} ble={s} param=0x{x} rej={d}", .{ tag, g.state.booted, @tagName(g.state.wifi), @tagName(g.state.ble), g_coex_param_ptr, rej });
    board.log.line("coex[{s}]: fw={s} rom={s} coa=0x{x} table=0x{x}", .{ tag, std.mem.span(fw), std.mem.span(rom), g_coa_funcs_p, @intFromPtr(radio_coex.adapterTable()) });
    board.log.line(
        "coex[{s}]: cb0=0x{x} cb1=0x{x} st+={d} st-={d} regb={d} rgbl={d} chg={d} ini={d} en={d}",
        .{
            tag,
            @intFromPtr(radio_coex.bleCallback(0)),
            @intFromPtr(radio_coex.bleCallback(1)),
            radio_coex.calls(.wr_btdm_coex_schm_status_bit_set),
            radio_coex.calls(.wr_btdm_coex_schm_status_bit_clear),
            radio_coex.calls(.wr_btdm_coex_schm_register_btdm_callback),
            radio_coex.calls(.wr_btdm_coex_register_ble_cb),
            radio_coex.calls(.wr_btdm_coex_wifi_channel_get),
            radio_coex.calls(.btdm_coex_init),
            radio_coex.calls(.btdm_coex_enable),
        },
    );
}

test "coex wiring: 不开 -Dcoex 时 boot 与 report 都是空操作" {
    boot();
    report(.boot);
    report(.init);
    report(.enable);
}
