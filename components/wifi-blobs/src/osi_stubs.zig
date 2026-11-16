//! 未实现钩子的**具名桩**（由 osi.zig 的字段表生成，与字段一一对应）。
//!
//! 为什么不留 null：调用 null 等于跳到 0x0，板子只会给一个 trap 地址，看不出是哪个钩子被要。
//! 这些桩在被调用时累加 `hits[i]` 并返回 0，日志会按顺序告诉我们它先要哪个钩子。

const osi = @import("osi.zig");

pub var hits: [field_count]u32 = @splat(0);
pub const field_count: usize = 66;
pub const names = [_][]const u8{
    "_env_is_chip",
    "_wifi_thread_semphr_get",
    "_queue_send_from_isr",
    "_event_group_create",
    "_event_group_delete",
    "_event_group_set_bits",
    "_event_group_clear_bits",
    "_event_group_wait_bits",
    "_task_create_pinned_to_core",
    "_task_create",
    "_task_delete",
    "_event_post",
    "_dport_access_stall_other_cpu_start_wrap",
    "_dport_access_stall_other_cpu_end_wrap",
    "_wifi_pm_sleep_lock_acquire",
    "_wifi_pm_sleep_lock_release",
    "_phy_disable",
    "_phy_enable",
    "_phy_update_country_info",
    "_timer_arm",
    "_timer_disarm",
    "_timer_done",
    "_timer_setfn",
    "_timer_arm_us",
    "_wifi_reset_mac",
    "_wifi_clock_enable",
    "_wifi_clock_disable",
    "_wifi_rtc_enable_iso",
    "_wifi_rtc_disable_iso",
    "_get_time",
    "_slowclk_cal_get",
    "_log_write",
    "_log_writev",
    "_wifi_create_queue",
    "_wifi_delete_queue",
    "_coex_init",
    "_coex_deinit",
    "_coex_enable",
    "_coex_disable",
    "_coex_status_get",
    "_coex_condition_set",
    "_coex_wifi_request",
    "_coex_wifi_release",
    "_coex_wifi_channel_set",
    "_coex_event_duration_get",
    "_coex_pti_get",
    "_coex_schm_status_bit_clear",
    "_coex_schm_status_bit_set",
    "_coex_schm_interval_set",
    "_coex_schm_interval_get",
    "_coex_schm_curr_period_get",
    "_coex_schm_curr_phase_get",
    "_coex_schm_process_restart",
    "_coex_schm_register_cb",
    "_coex_register_start_cb",
    "_regdma_link_set_write_wait_content",
    "_sleep_retention_find_link_by_id",
    "_coex_schm_flexible_period_set",
    "_coex_schm_flexible_period_get",
    "_coex_schm_get_phase_by_idx",
    "_coex_configure_preemption_end_cb",
    "_wifi_disable_ac_ax",
    "_wifi_bb_sleep_retention_attach",
    "_wifi_bb_sleep_retention_detach",
    "_wifi_mac_sleep_retention_attach",
    "_wifi_mac_sleep_retention_detach",
};

fn stub0() callconv(.c) usize {
    hits[0] += 1;
    return 0;
}
fn stub1() callconv(.c) usize {
    hits[1] += 1;
    return 0;
}
fn stub2() callconv(.c) usize {
    hits[2] += 1;
    return 0;
}
fn stub3() callconv(.c) usize {
    hits[3] += 1;
    return 0;
}
fn stub4() callconv(.c) usize {
    hits[4] += 1;
    return 0;
}
fn stub5() callconv(.c) usize {
    hits[5] += 1;
    return 0;
}
fn stub6() callconv(.c) usize {
    hits[6] += 1;
    return 0;
}
fn stub7() callconv(.c) usize {
    hits[7] += 1;
    return 0;
}
fn stub8() callconv(.c) usize {
    hits[8] += 1;
    return 0;
}
fn stub9() callconv(.c) usize {
    hits[9] += 1;
    return 0;
}
fn stub10() callconv(.c) usize {
    hits[10] += 1;
    return 0;
}
fn stub11() callconv(.c) usize {
    hits[11] += 1;
    return 0;
}
fn stub12() callconv(.c) usize {
    hits[12] += 1;
    return 0;
}
fn stub13() callconv(.c) usize {
    hits[13] += 1;
    return 0;
}
fn stub14() callconv(.c) usize {
    hits[14] += 1;
    return 0;
}
fn stub15() callconv(.c) usize {
    hits[15] += 1;
    return 0;
}
fn stub16() callconv(.c) usize {
    hits[16] += 1;
    return 0;
}
fn stub17() callconv(.c) usize {
    hits[17] += 1;
    return 0;
}
fn stub18() callconv(.c) usize {
    hits[18] += 1;
    return 0;
}
fn stub19() callconv(.c) usize {
    hits[19] += 1;
    return 0;
}
fn stub20() callconv(.c) usize {
    hits[20] += 1;
    return 0;
}
fn stub21() callconv(.c) usize {
    hits[21] += 1;
    return 0;
}
fn stub22() callconv(.c) usize {
    hits[22] += 1;
    return 0;
}
fn stub23() callconv(.c) usize {
    hits[23] += 1;
    return 0;
}
fn stub24() callconv(.c) usize {
    hits[24] += 1;
    return 0;
}
fn stub25() callconv(.c) usize {
    hits[25] += 1;
    return 0;
}
fn stub26() callconv(.c) usize {
    hits[26] += 1;
    return 0;
}
fn stub27() callconv(.c) usize {
    hits[27] += 1;
    return 0;
}
fn stub28() callconv(.c) usize {
    hits[28] += 1;
    return 0;
}
fn stub29() callconv(.c) usize {
    hits[29] += 1;
    return 0;
}
fn stub30() callconv(.c) usize {
    hits[30] += 1;
    return 0;
}
fn stub31() callconv(.c) usize {
    hits[31] += 1;
    return 0;
}
fn stub32() callconv(.c) usize {
    hits[32] += 1;
    return 0;
}
fn stub33() callconv(.c) usize {
    hits[33] += 1;
    return 0;
}
fn stub34() callconv(.c) usize {
    hits[34] += 1;
    return 0;
}
fn stub35() callconv(.c) usize {
    hits[35] += 1;
    return 0;
}
fn stub36() callconv(.c) usize {
    hits[36] += 1;
    return 0;
}
fn stub37() callconv(.c) usize {
    hits[37] += 1;
    return 0;
}
fn stub38() callconv(.c) usize {
    hits[38] += 1;
    return 0;
}
fn stub39() callconv(.c) usize {
    hits[39] += 1;
    return 0;
}
fn stub40() callconv(.c) usize {
    hits[40] += 1;
    return 0;
}
fn stub41() callconv(.c) usize {
    hits[41] += 1;
    return 0;
}
fn stub42() callconv(.c) usize {
    hits[42] += 1;
    return 0;
}
fn stub43() callconv(.c) usize {
    hits[43] += 1;
    return 0;
}
fn stub44() callconv(.c) usize {
    hits[44] += 1;
    return 0;
}
fn stub45() callconv(.c) usize {
    hits[45] += 1;
    return 0;
}
fn stub46() callconv(.c) usize {
    hits[46] += 1;
    return 0;
}
fn stub47() callconv(.c) usize {
    hits[47] += 1;
    return 0;
}
fn stub48() callconv(.c) usize {
    hits[48] += 1;
    return 0;
}
fn stub49() callconv(.c) usize {
    hits[49] += 1;
    return 0;
}
fn stub50() callconv(.c) usize {
    hits[50] += 1;
    return 0;
}
fn stub51() callconv(.c) usize {
    hits[51] += 1;
    return 0;
}
fn stub52() callconv(.c) usize {
    hits[52] += 1;
    return 0;
}
fn stub53() callconv(.c) usize {
    hits[53] += 1;
    return 0;
}
fn stub54() callconv(.c) usize {
    hits[54] += 1;
    return 0;
}
fn stub55() callconv(.c) usize {
    hits[55] += 1;
    return 0;
}
fn stub56() callconv(.c) usize {
    hits[56] += 1;
    return 0;
}
fn stub57() callconv(.c) usize {
    hits[57] += 1;
    return 0;
}
fn stub58() callconv(.c) usize {
    hits[58] += 1;
    return 0;
}
fn stub59() callconv(.c) usize {
    hits[59] += 1;
    return 0;
}
fn stub60() callconv(.c) usize {
    hits[60] += 1;
    return 0;
}
fn stub61() callconv(.c) usize {
    hits[61] += 1;
    return 0;
}
fn stub62() callconv(.c) usize {
    hits[62] += 1;
    return 0;
}
fn stub63() callconv(.c) usize {
    hits[63] += 1;
    return 0;
}
fn stub64() callconv(.c) usize {
    hits[64] += 1;
    return 0;
}
fn stub65() callconv(.c) usize {
    hits[65] += 1;
    return 0;
}

pub fn fill(t: *osi.Osi) void {
    t._env_is_chip = @ptrCast(&stub0);
    t._wifi_thread_semphr_get = @ptrCast(&stub1);
    t._queue_send_from_isr = @ptrCast(&stub2);
    t._event_group_create = @ptrCast(&stub3);
    t._event_group_delete = @ptrCast(&stub4);
    t._event_group_set_bits = @ptrCast(&stub5);
    t._event_group_clear_bits = @ptrCast(&stub6);
    t._event_group_wait_bits = @ptrCast(&stub7);
    t._task_create_pinned_to_core = @ptrCast(&stub8);
    t._task_create = @ptrCast(&stub9);
    t._task_delete = @ptrCast(&stub10);
    t._event_post = @ptrCast(&stub11);
    t._dport_access_stall_other_cpu_start_wrap = @ptrCast(&stub12);
    t._dport_access_stall_other_cpu_end_wrap = @ptrCast(&stub13);
    t._wifi_pm_sleep_lock_acquire = @ptrCast(&stub14);
    t._wifi_pm_sleep_lock_release = @ptrCast(&stub15);
    t._phy_disable = @ptrCast(&stub16);
    t._phy_enable = @ptrCast(&stub17);
    t._phy_update_country_info = @ptrCast(&stub18);
    t._timer_arm = @ptrCast(&stub19);
    t._timer_disarm = @ptrCast(&stub20);
    t._timer_done = @ptrCast(&stub21);
    t._timer_setfn = @ptrCast(&stub22);
    t._timer_arm_us = @ptrCast(&stub23);
    t._wifi_reset_mac = @ptrCast(&stub24);
    t._wifi_clock_enable = @ptrCast(&stub25);
    t._wifi_clock_disable = @ptrCast(&stub26);
    t._wifi_rtc_enable_iso = @ptrCast(&stub27);
    t._wifi_rtc_disable_iso = @ptrCast(&stub28);
    t._get_time = @ptrCast(&stub29);
    t._slowclk_cal_get = @ptrCast(&stub30);
    t._log_write = @ptrCast(&stub31);
    t._log_writev = @ptrCast(&stub32);
    t._wifi_create_queue = @ptrCast(&stub33);
    t._wifi_delete_queue = @ptrCast(&stub34);
    t._coex_init = @ptrCast(&stub35);
    t._coex_deinit = @ptrCast(&stub36);
    t._coex_enable = @ptrCast(&stub37);
    t._coex_disable = @ptrCast(&stub38);
    t._coex_status_get = @ptrCast(&stub39);
    t._coex_condition_set = @ptrCast(&stub40);
    t._coex_wifi_request = @ptrCast(&stub41);
    t._coex_wifi_release = @ptrCast(&stub42);
    t._coex_wifi_channel_set = @ptrCast(&stub43);
    t._coex_event_duration_get = @ptrCast(&stub44);
    t._coex_pti_get = @ptrCast(&stub45);
    t._coex_schm_status_bit_clear = @ptrCast(&stub46);
    t._coex_schm_status_bit_set = @ptrCast(&stub47);
    t._coex_schm_interval_set = @ptrCast(&stub48);
    t._coex_schm_interval_get = @ptrCast(&stub49);
    t._coex_schm_curr_period_get = @ptrCast(&stub50);
    t._coex_schm_curr_phase_get = @ptrCast(&stub51);
    t._coex_schm_process_restart = @ptrCast(&stub52);
    t._coex_schm_register_cb = @ptrCast(&stub53);
    t._coex_register_start_cb = @ptrCast(&stub54);
    t._regdma_link_set_write_wait_content = @ptrCast(&stub55);
    t._sleep_retention_find_link_by_id = @ptrCast(&stub56);
    t._coex_schm_flexible_period_set = @ptrCast(&stub57);
    t._coex_schm_flexible_period_get = @ptrCast(&stub58);
    t._coex_schm_get_phase_by_idx = @ptrCast(&stub59);
    t._coex_configure_preemption_end_cb = @ptrCast(&stub60);
    t._wifi_disable_ac_ax = @ptrCast(&stub61);
    t._wifi_bb_sleep_retention_attach = @ptrCast(&stub62);
    t._wifi_bb_sleep_retention_detach = @ptrCast(&stub63);
    t._wifi_mac_sleep_retention_attach = @ptrCast(&stub64);
    t._wifi_mac_sleep_retention_detach = @ptrCast(&stub65);
}
