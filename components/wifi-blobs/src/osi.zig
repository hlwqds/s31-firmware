//! `wifi_osi_funcs_t` 的 Zig 镜像（R3 的 OS 抽象表）。
//!
//! 这张表是 IDF Wi-Fi blob 与宿主之间的**唯一** OS 契约：blob 不直接引用 FreeRTOS /
//! esp_event / esp_timer / heap（实测这三个归档里 `xTaskCreate`/`xQueue*`/`xSemaphore*`/
//! `esp_event_*`/`esp_timer_*`/`heap_caps_*` 的未定义引用全是 0），它通过 `g_osi_funcs_p`
//! 指向这张表回调。
//!
//! **字段顺序与类型必须与 IDF 头逐字段一致**：错一位后面所有指针都会错位调用，
//! 链接能过、运行期直接跑飞，没有任何编译期提示。所以这里：
//!
//!   - 字段由 `components/esp_wifi/include/esp_private/wifi_os_adapter.h` 经 IDF 的
//!     `sdkconfig.h` 预处理后**自动生成**（顺序即结构体顺序），不是手写；
//!   - ilp32 下所有函数指针 4 字节，`_version`/`_magic` 是 `int32_t`，所以
//!     `@sizeOf == 4 * {n}`，下面用 comptime 断言钉死。
//!
//! 重新生成：见文件末尾的命令。改了 IDF 版本或 sdkconfig 后必须重跑，字段数会变。

pub const field_count: usize = 128;

/// IDF 头里的两个常量（`wifi_os_adapter.h:20-21`）：驱动会校验，填错直接拒绝。
pub const version: u32 = 0x0000_0009;
/// `0xDEADBEAF` 在 C 里是 `int`（负值），这里按位存成 u32 再 bitCast。
pub const magic: i32 = @bitCast(@as(u32, 0xDEAD_BEAF));

pub const Osi = extern struct {
    _version: i32 = @bitCast(version),
    _env_is_chip: ?*const anyopaque = null,
    _set_intr: ?*const anyopaque = null,
    _clear_intr: ?*const anyopaque = null,
    _set_isr: ?*const anyopaque = null,
    _ints_on: ?*const anyopaque = null,
    _ints_off: ?*const anyopaque = null,
    _is_from_isr: ?*const anyopaque = null,
    _spin_lock_create: ?*const anyopaque = null,
    _spin_lock_delete: ?*const anyopaque = null,
    _wifi_int_disable: ?*const anyopaque = null,
    _wifi_int_restore: ?*const anyopaque = null,
    _task_yield_from_isr: ?*const anyopaque = null,
    _semphr_create: ?*const anyopaque = null,
    _semphr_delete: ?*const anyopaque = null,
    _semphr_take: ?*const anyopaque = null,
    _semphr_give: ?*const anyopaque = null,
    _wifi_thread_semphr_get: ?*const anyopaque = null,
    _mutex_create: ?*const anyopaque = null,
    _recursive_mutex_create: ?*const anyopaque = null,
    _mutex_delete: ?*const anyopaque = null,
    _mutex_lock: ?*const anyopaque = null,
    _mutex_unlock: ?*const anyopaque = null,
    _queue_create: ?*const anyopaque = null,
    _queue_delete: ?*const anyopaque = null,
    _queue_send: ?*const anyopaque = null,
    _queue_send_from_isr: ?*const anyopaque = null,
    _queue_send_to_back: ?*const anyopaque = null,
    _queue_send_to_front: ?*const anyopaque = null,
    _queue_recv: ?*const anyopaque = null,
    _queue_msg_waiting: ?*const anyopaque = null,
    _event_group_create: ?*const anyopaque = null,
    _event_group_delete: ?*const anyopaque = null,
    _event_group_set_bits: ?*const anyopaque = null,
    _event_group_clear_bits: ?*const anyopaque = null,
    _event_group_wait_bits: ?*const anyopaque = null,
    _task_create_pinned_to_core: ?*const anyopaque = null,
    _task_create: ?*const anyopaque = null,
    _task_delete: ?*const anyopaque = null,
    _task_delay: ?*const anyopaque = null,
    _task_ms_to_tick: ?*const anyopaque = null,
    _task_get_current_task: ?*const anyopaque = null,
    _task_get_max_priority: ?*const anyopaque = null,
    _malloc: ?*const anyopaque = null,
    _free: ?*const anyopaque = null,
    _event_post: ?*const anyopaque = null,
    _get_free_heap_size: ?*const anyopaque = null,
    _rand: ?*const anyopaque = null,
    _dport_access_stall_other_cpu_start_wrap: ?*const anyopaque = null,
    _dport_access_stall_other_cpu_end_wrap: ?*const anyopaque = null,
    _wifi_pm_sleep_lock_acquire: ?*const anyopaque = null,
    _wifi_pm_sleep_lock_release: ?*const anyopaque = null,
    _phy_disable: ?*const anyopaque = null,
    _phy_enable: ?*const anyopaque = null,
    _phy_update_country_info: ?*const anyopaque = null,
    _read_mac: ?*const anyopaque = null,
    _timer_arm: ?*const anyopaque = null,
    _timer_disarm: ?*const anyopaque = null,
    _timer_done: ?*const anyopaque = null,
    _timer_setfn: ?*const anyopaque = null,
    _timer_arm_us: ?*const anyopaque = null,
    _wifi_reset_mac: ?*const anyopaque = null,
    _wifi_clock_enable: ?*const anyopaque = null,
    _wifi_clock_disable: ?*const anyopaque = null,
    _wifi_rtc_enable_iso: ?*const anyopaque = null,
    _wifi_rtc_disable_iso: ?*const anyopaque = null,
    _esp_timer_get_time: ?*const anyopaque = null,
    _nvs_set_i8: ?*const anyopaque = null,
    _nvs_get_i8: ?*const anyopaque = null,
    _nvs_set_u8: ?*const anyopaque = null,
    _nvs_get_u8: ?*const anyopaque = null,
    _nvs_set_u16: ?*const anyopaque = null,
    _nvs_get_u16: ?*const anyopaque = null,
    _nvs_open: ?*const anyopaque = null,
    _nvs_close: ?*const anyopaque = null,
    _nvs_commit: ?*const anyopaque = null,
    _nvs_set_blob: ?*const anyopaque = null,
    _nvs_get_blob: ?*const anyopaque = null,
    _nvs_erase_key: ?*const anyopaque = null,
    _get_random: ?*const anyopaque = null,
    _get_time: ?*const anyopaque = null,
    _random: ?*const anyopaque = null,
    _slowclk_cal_get: ?*const anyopaque = null,
    _log_write: ?*const anyopaque = null,
    _log_writev: ?*const anyopaque = null,
    _log_timestamp: ?*const anyopaque = null,
    _malloc_internal: ?*const anyopaque = null,
    _realloc_internal: ?*const anyopaque = null,
    _calloc_internal: ?*const anyopaque = null,
    _zalloc_internal: ?*const anyopaque = null,
    _wifi_malloc: ?*const anyopaque = null,
    _wifi_realloc: ?*const anyopaque = null,
    _wifi_calloc: ?*const anyopaque = null,
    _wifi_zalloc: ?*const anyopaque = null,
    _wifi_create_queue: ?*const anyopaque = null,
    _wifi_delete_queue: ?*const anyopaque = null,
    _coex_init: ?*const anyopaque = null,
    _coex_deinit: ?*const anyopaque = null,
    _coex_enable: ?*const anyopaque = null,
    _coex_disable: ?*const anyopaque = null,
    _coex_status_get: ?*const anyopaque = null,
    _coex_condition_set: ?*const anyopaque = null,
    _coex_wifi_request: ?*const anyopaque = null,
    _coex_wifi_release: ?*const anyopaque = null,
    _coex_wifi_channel_set: ?*const anyopaque = null,
    _coex_event_duration_get: ?*const anyopaque = null,
    _coex_pti_get: ?*const anyopaque = null,
    _coex_schm_status_bit_clear: ?*const anyopaque = null,
    _coex_schm_status_bit_set: ?*const anyopaque = null,
    _coex_schm_interval_set: ?*const anyopaque = null,
    _coex_schm_interval_get: ?*const anyopaque = null,
    _coex_schm_curr_period_get: ?*const anyopaque = null,
    _coex_schm_curr_phase_get: ?*const anyopaque = null,
    _coex_schm_process_restart: ?*const anyopaque = null,
    _coex_schm_register_cb: ?*const anyopaque = null,
    _coex_register_start_cb: ?*const anyopaque = null,
    _regdma_link_set_write_wait_content: ?*const anyopaque = null,
    _sleep_retention_find_link_by_id: ?*const anyopaque = null,
    _coex_schm_flexible_period_set: ?*const anyopaque = null,
    _coex_schm_flexible_period_get: ?*const anyopaque = null,
    _coex_schm_get_phase_by_idx: ?*const anyopaque = null,
    _coex_configure_preemption_end_cb: ?*const anyopaque = null,
    _wifi_disable_ac_ax: ?*const anyopaque = null,
    _wifi_bb_sleep_retention_attach: ?*const anyopaque = null,
    _wifi_bb_sleep_retention_detach: ?*const anyopaque = null,
    _wifi_mac_sleep_retention_attach: ?*const anyopaque = null,
    _wifi_mac_sleep_retention_detach: ?*const anyopaque = null,
    _magic: i32 = magic,
};

comptime {
    // ilp32：每个字段 4 字节。若这条断言挂了，说明字段表与 IDF 头不再一致。
    if (@sizeOf(usize) == 4) {
        if (@sizeOf(Osi) != 4 * field_count) @compileError("Osi 尺寸与字段数不符");
        if (@offsetOf(Osi, "_version") != 0) @compileError("_version 必须是第一个字段");
        if (@offsetOf(Osi, "_magic") != 4 * (field_count - 1)) @compileError("_magic 必须是最后一个字段");
    }
}

/// 空表：钩子全 null，但 `_version`/`_magic` 已是驱动认可的值。
/// 真适配层要逐项填（malloc/free/信号量/队列/定时器/日志/random）。
pub const empty: Osi = .{};

/// **ROM 里的表指针槽位**：`esp32s31.rom.pp.ld:340` 把 `g_osi_funcs_p` 定义成
/// `0x2f07ff44`——那是 ROM 保留 RAM 里的一个 4 字节槽位，blob 读的是**它**，
/// 不是我们定义的符号。所以光填好表不够，必须把表地址写进这个槽位。
///
/// 注意这个地址在我们的 SRAM 上界（`0x2F07AFC0`）**之上**：属于 ROM 留作 RAM 的区域，
/// 与我们的堆/栈不冲突，但写入前应先读回原值确认是合理指针（`install` 会返回它）。
pub const slot_addr: usize = 0x2F07_FF44;

/// 把表装进 ROM 槽位，返回装之前槽位里的值（便于确认没有覆盖别的东西）。
/// 非 riscv32（主机测试）时是 no-op：那个地址在主机上不可访问。
pub fn install(table: *const Osi) ?*const Osi {
    if (@import("builtin").cpu.arch != .riscv32) return null;
    const slot: *volatile ?*const Osi = @ptrFromInt(slot_addr);
    const previous = slot.*;
    slot.* = table;
    return previous;
}

// 重新生成字段表（**不要**用文本解析：这个头有 5 处按目标裁剪字段的 #if，
// 文本解析出的字段数/偏移必错，而链接照样过、运行期调用全错位）：
//   IDF=~/esp/esp-idf
//   GCC=~/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin/riscv32-esp-elf-gcc
//   $GCC -E -P -I$IDF/esp_wifi/include -I$IDF/esp_wifi/include/esp_private \
//     -I$IDF/soc/esp32s31/include -I$IDF/hal/esp32s31/include \
//     -include firmware/idf-bootstrap/build/config/sdkconfig.h - <<<'#include "esp_private/wifi_os_adapter.h"' \
//     | sed -n '/typedef struct wifi_osi_funcs_t {/,/} wifi_osi_funcs_t;/p'
