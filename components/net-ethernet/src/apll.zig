//! APLL（音频 PLL）备用 125 MHz 源：MPLL 校准在本板裸机下不完成时的绕行方案。
//!
//! 依据 ESP-IDF v6.1：
//!   - `esp_hal_clock/esp32s31/include/hal/clk_tree_ll.h:51-57`
//!     multiplier = xtal * (4 + sdm2 + sdm1/256 + sdm0/65536)，范围 350–500 MHz；
//!     输出 = multiplier / ((o_div + 2) * 2)，范围 5.3–125 MHz。
//!   - 同文件 `:131-139` `clk_ll_apll_enable()`：PMU_IMM_HP_CK_POWER_1 bit21/25/29
//!     + HP_ALIVE_SYS_HP_CLK_CTRL bit23。
//!   - `esp_hw_support/port/esp32s31/rtc_clk.c:598-611`
//!     `rtc_clk_apll_coeff_set()` 的顺序：set_config → 模拟时钟 → 校准。
//!
//! 本模块只做“上电 + 配置 + 使能 ref 源”，校准结果用 PLLA_CAL_END 打印，
//! 不阻塞：125 MHz 是否真的出来，以 GPIO13 的翻转计数为判据。

const board = @import("board");
const hw = board.hw;

const pmu_imm_hp_ck_power_1: usize = 0x2070_4000 + 0x0f4;
const hp_alive_hp_clk_ctrl: usize = 0x2058_9000;
const lp_aonclkrst_apll_div: usize = 0x2070_1000 + 0x50;
const lp_aonclkrst_apll_sdm: usize = 0x2070_1000 + 0x64;
const hp_sys_clkrst_ana_pll_ctrl0: usize = 0x2058_7000 + 0x174;

const tie_high_global_apll_icg: u32 = 1 << 21;
const tie_high_xpd_apll_i2c: u32 = 1 << 25;
const tie_high_xpd_apll: u32 = 1 << 29;
const hp_audio_pll_clk_en: u32 = 1 << 23;

const plla_cal_end: u32 = 1 << 0;

pub const State = struct {
    cal_end: bool,
    out_div: u32,
    sdm: u32,
    div_raw: u32,
    pll_raw: u32,
    clk_en: bool,
};

/// 500 MHz 倍频 + o_div=0 → 125 MHz 输出（xtal 40 MHz）。
/// sdm2=8、sdm1=128、sdm0=0：40 * (4 + 8 + 0.5) = 500 MHz。
pub const sdm2: u32 = 8;
pub const sdm1: u32 = 128;
pub const sdm0: u32 = 0;
pub const out_div: u32 = 0;

pub fn read() State {
    const div = hw.readReg(lp_aonclkrst_apll_div);
    const sdm = hw.readReg(lp_aonclkrst_apll_sdm);
    const pll = hw.readReg(hp_sys_clkrst_ana_pll_ctrl0);
    return .{
        .cal_end = (pll & plla_cal_end) != 0,
        .out_div = (div >> 3) & 0x1f,
        .sdm = sdm & 0x3f_ffff,
        .div_raw = div,
        .pll_raw = pll,
        .clk_en = (hw.readReg(hp_alive_hp_clk_ctrl) & hp_audio_pll_clk_en) != 0,
    };
}

/// 上电 + 配置 + 等待 PLLA_CAL_END（有界）。
pub fn ensure125(timeout_us: u32) State {
    hw.setBits(pmu_imm_hp_ck_power_1, tie_high_global_apll_icg);
    hw.setBits(pmu_imm_hp_ck_power_1, tie_high_xpd_apll | tie_high_xpd_apll_i2c);
    hw.setBits(hp_alive_hp_clk_ctrl, hp_audio_pll_clk_en);
    hw.fence();
    hw.delayUs(200);

    // out_div 在 bit7:3；ref_div 保持默认 5。
    hw.writeMasked(lp_aonclkrst_apll_div, 0x1f << 3, out_div << 3);
    hw.writeReg(lp_aonclkrst_apll_sdm, (sdm2 << 16) | (sdm1 << 8) | sdm0);
    hw.fence();

    const start = hw.nowUs();
    while (!read().cal_end) {
        if (hw.elapsedUs(start) > timeout_us) break;
    }
    return read();
}

/// APLL 输出频率（Hz）：xtal × (4 + sdm2 + sdm1/256 + sdm0/65536) / ((o_div + 2) × 2)。
/// 公式来自 `clk_tree_ll.h:51-57`；主机侧单测用它验证 125 MHz 的参数选择。
pub fn outputHz(xtal_mhz: u32, sdm2_v: u32, sdm1_v: u32, sdm0_v: u32, o_div_v: u32) u64 {
    const num = @as(u64, 4 * 65536 + sdm2_v * 65536 + sdm1_v * 256 + sdm0_v);
    const den = @as(u64, 65536) * 2 * (o_div_v + 2);
    return @as(u64, xtal_mhz) * 1_000_000 * num / den;
}

test "APLL 500MHz multiplier with o_div=0 gives exactly 125MHz" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 125_000_000), outputHz(40, sdm2, sdm1, sdm0, out_div));
}
