//! 未实现钩子的**具名桩**（由 osi.zig 的字段表生成，与字段一一对应）。
//!
//! 调用 null 等于跳到 0x0；桩累加 `hits[i]` 并返回 0，日志按顺序告诉你 blob 先要哪个钩子。
//!
//! `fill` **只填空字段**：已实现（makeTable 里赋过值）的钩子不会被桩覆盖——否则新增实现会被
//! 静默吃掉，表现为"改了代码但 hits 还在涨"。

const osi = @import("osi.zig");

pub var hits: [field_count]u32 = @splat(0);
pub const field_count: usize = 55;
pub const names = [_][]const u8{
    "_env_is_chip",
    "_queue_send_from_isr",
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

pub fn fill(t: *osi.Osi) void {
    if (t._env_is_chip == null) t._env_is_chip = @ptrCast(&stub0);
    if (t._queue_send_from_isr == null) t._queue_send_from_isr = @ptrCast(&stub1);
    if (t._event_post == null) t._event_post = @ptrCast(&stub2);
    if (t._dport_access_stall_other_cpu_start_wrap == null) t._dport_access_stall_other_cpu_start_wrap = @ptrCast(&stub3);
    if (t._dport_access_stall_other_cpu_end_wrap == null) t._dport_access_stall_other_cpu_end_wrap = @ptrCast(&stub4);
    if (t._wifi_pm_sleep_lock_acquire == null) t._wifi_pm_sleep_lock_acquire = @ptrCast(&stub5);
    if (t._wifi_pm_sleep_lock_release == null) t._wifi_pm_sleep_lock_release = @ptrCast(&stub6);
    if (t._phy_disable == null) t._phy_disable = @ptrCast(&stub7);
    if (t._phy_enable == null) t._phy_enable = @ptrCast(&stub8);
    if (t._phy_update_country_info == null) t._phy_update_country_info = @ptrCast(&stub9);
    if (t._timer_arm == null) t._timer_arm = @ptrCast(&stub10);
    if (t._timer_disarm == null) t._timer_disarm = @ptrCast(&stub11);
    if (t._timer_done == null) t._timer_done = @ptrCast(&stub12);
    if (t._timer_setfn == null) t._timer_setfn = @ptrCast(&stub13);
    if (t._timer_arm_us == null) t._timer_arm_us = @ptrCast(&stub14);
    if (t._wifi_reset_mac == null) t._wifi_reset_mac = @ptrCast(&stub15);
    if (t._wifi_clock_enable == null) t._wifi_clock_enable = @ptrCast(&stub16);
    if (t._wifi_clock_disable == null) t._wifi_clock_disable = @ptrCast(&stub17);
    if (t._wifi_rtc_enable_iso == null) t._wifi_rtc_enable_iso = @ptrCast(&stub18);
    if (t._wifi_rtc_disable_iso == null) t._wifi_rtc_disable_iso = @ptrCast(&stub19);
    if (t._get_time == null) t._get_time = @ptrCast(&stub20);
    if (t._slowclk_cal_get == null) t._slowclk_cal_get = @ptrCast(&stub21);
    if (t._log_write == null) t._log_write = @ptrCast(&stub22);
    if (t._log_writev == null) t._log_writev = @ptrCast(&stub23);
    if (t._coex_init == null) t._coex_init = @ptrCast(&stub24);
    if (t._coex_deinit == null) t._coex_deinit = @ptrCast(&stub25);
    if (t._coex_enable == null) t._coex_enable = @ptrCast(&stub26);
    if (t._coex_disable == null) t._coex_disable = @ptrCast(&stub27);
    if (t._coex_status_get == null) t._coex_status_get = @ptrCast(&stub28);
    if (t._coex_condition_set == null) t._coex_condition_set = @ptrCast(&stub29);
    if (t._coex_wifi_request == null) t._coex_wifi_request = @ptrCast(&stub30);
    if (t._coex_wifi_release == null) t._coex_wifi_release = @ptrCast(&stub31);
    if (t._coex_wifi_channel_set == null) t._coex_wifi_channel_set = @ptrCast(&stub32);
    if (t._coex_event_duration_get == null) t._coex_event_duration_get = @ptrCast(&stub33);
    if (t._coex_pti_get == null) t._coex_pti_get = @ptrCast(&stub34);
    if (t._coex_schm_status_bit_clear == null) t._coex_schm_status_bit_clear = @ptrCast(&stub35);
    if (t._coex_schm_status_bit_set == null) t._coex_schm_status_bit_set = @ptrCast(&stub36);
    if (t._coex_schm_interval_set == null) t._coex_schm_interval_set = @ptrCast(&stub37);
    if (t._coex_schm_interval_get == null) t._coex_schm_interval_get = @ptrCast(&stub38);
    if (t._coex_schm_curr_period_get == null) t._coex_schm_curr_period_get = @ptrCast(&stub39);
    if (t._coex_schm_curr_phase_get == null) t._coex_schm_curr_phase_get = @ptrCast(&stub40);
    if (t._coex_schm_process_restart == null) t._coex_schm_process_restart = @ptrCast(&stub41);
    if (t._coex_schm_register_cb == null) t._coex_schm_register_cb = @ptrCast(&stub42);
    if (t._coex_register_start_cb == null) t._coex_register_start_cb = @ptrCast(&stub43);
    if (t._regdma_link_set_write_wait_content == null) t._regdma_link_set_write_wait_content = @ptrCast(&stub44);
    if (t._sleep_retention_find_link_by_id == null) t._sleep_retention_find_link_by_id = @ptrCast(&stub45);
    if (t._coex_schm_flexible_period_set == null) t._coex_schm_flexible_period_set = @ptrCast(&stub46);
    if (t._coex_schm_flexible_period_get == null) t._coex_schm_flexible_period_get = @ptrCast(&stub47);
    if (t._coex_schm_get_phase_by_idx == null) t._coex_schm_get_phase_by_idx = @ptrCast(&stub48);
    if (t._coex_configure_preemption_end_cb == null) t._coex_configure_preemption_end_cb = @ptrCast(&stub49);
    if (t._wifi_disable_ac_ax == null) t._wifi_disable_ac_ax = @ptrCast(&stub50);
    if (t._wifi_bb_sleep_retention_attach == null) t._wifi_bb_sleep_retention_attach = @ptrCast(&stub51);
    if (t._wifi_bb_sleep_retention_detach == null) t._wifi_bb_sleep_retention_detach = @ptrCast(&stub52);
    if (t._wifi_mac_sleep_retention_attach == null) t._wifi_mac_sleep_retention_attach = @ptrCast(&stub53);
    if (t._wifi_mac_sleep_retention_detach == null) t._wifi_mac_sleep_retention_detach = @ptrCast(&stub54);
}
