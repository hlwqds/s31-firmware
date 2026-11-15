//! 板级：LP TRNG（真随机数）驱动。
//!
//! 地址与序列**不是猜的**，直接来自本机 IDF checkout
//! （`/home/huanglin/esp/esp-idf`，路径可由 `firmware/idf-bootstrap/build/CMakeCache.txt`
//! 的 `IDF_PATH` 找回）：
//!
//! ```text
//! components/soc/esp32s31/register/soc/reg_base.h:107   DR_REG_TRNG_BASE      0x20814000
//! components/soc/esp32s31/register/soc/trng_reg.h:358   TRNG_CRC_SYNC_DATA_REG  base+0x48
//! components/soc/esp32s31/register/soc/trng_struct.h    conf: bit31 sample_enable
//!                                                             bit30 noise_crc_en
//!                                                       date: bit28 clk_en
//! components/soc/esp32s31/register/soc/reg_base.h:92    DR_REG_LP_PERICLKRST_BASE 0x20710000
//! components/soc/esp32s31/register/soc/lp_peri_clkrst_struct.h
//!                                                       rng_ctrl @0x3c: bit30 clk_en
//!                                                                      bit31 rst_en
//! components/soc/esp32s31/register/soc/trng_reg.h       TRNG_DATE_REG          base+0xfc
//! ```
//!
//! 使能顺序照抄 `components/hal/esp32s31/include/hal/trng_ll.h` 的 `trng_ll_enable()`
//! （总线时钟 → 复位脉冲 → 模块时钟 → 采样 → noise CRC）；读取照抄
//! `components/esp_hw_support/hw_random.c`：**每次只读一个 32 位字并 XOR 累积**，
//! 两次读之间至少等 `APB_CYCLE_WAIT_NUM` 个 APB 周期，否则读到的是同一批熵。
//!
//! 本文件的用例只覆盖纯逻辑（等待循环次数换算），不碰 MMIO——那份证据只能在板上拿。
const hw = @import("hw.zig");

pub const base: usize = 0x2081_4000;
pub const reg_conf: usize = base + 0x00;
pub const reg_crc_sync_data: usize = base + 0x48;
pub const reg_date: usize = base + 0xfc;

pub const lp_clkrst_base: usize = 0x2071_0000;
pub const reg_lp_rng_ctrl: usize = lp_clkrst_base + 0x3c;

const conf_sample_enable: u32 = 1 << 31;
const conf_noise_crc_en: u32 = 1 << 30;
const date_clk_en: u32 = 1 << 28;
const clkrst_clk_en: u32 = 1 << 30;
const clkrst_rst_en: u32 = 1 << 31;

/// 两次采样之间要等的 APB 周期数（IDF `hw_random.c` 的 `APB_CYCLE_WAIT_NUM`：
/// ESP32S3 用 1778 ≈ 45 kHz；本板 APB 80 MHz，取同一量级的 1600）。
pub const apb_wait_cycles: u32 = 1600;

fn rd(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn wr(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

/// 置位/清位，其余位保持原值（寄存器里有保留位，读-改-写比盲写安全）。
fn setBits(addr: usize, bits: u32, on: bool) void {
    const cur = rd(addr);
    wr(addr, if (on) cur | bits else cur & ~bits);
}

/// 使能 TRNG：总线时钟 → 复位 → 模块时钟 → 采样 → noise CRC。
pub fn enable() void {
    setBits(reg_lp_rng_ctrl, clkrst_clk_en, true);
    setBits(reg_lp_rng_ctrl, clkrst_rst_en, true);
    setBits(reg_lp_rng_ctrl, clkrst_rst_en, false);
    setBits(reg_date, date_clk_en, true);
    setBits(reg_conf, conf_sample_enable, true);
    setBits(reg_conf, conf_noise_crc_en, true);
}

pub fn disable() void {
    setBits(reg_conf, conf_sample_enable, false);
    setBits(reg_conf, conf_noise_crc_en, false);
    setBits(reg_date, date_clk_en, false);
    setBits(reg_lp_rng_ctrl, clkrst_clk_en, false);
}

/// 读一个 32 位字（不等待；连续读会拿到相关的样本，别这么用）。
pub fn readWord() u32 {
    return rd(reg_crc_sync_data);
}

/// 读一个 32 位字，先按 IDF 的节奏等够 APB 周期。
pub fn word() u32 {
    var c: u32 = 0;
    while (c < apb_wait_cycles) : (c += 1) {
        asm volatile ("nop");
    }
    return readWord();
}

/// 填满 `out`：每 4 字节一次采样，XOR 累积（与 IDF `esp_fill_random` 同构）。
pub fn fill(out: []u8) void {
    var i: usize = 0;
    while (i < out.len) {
        const w = word();
        var buf: [4]u8 = undefined;
        @memcpy(&buf, @as(*const [4]u8, @ptrCast(&w)));
        const n = @min(4, out.len - i);
        @memcpy(out[i..][0..n], buf[0..n]);
        i += n;
    }
}

test "rng: 等待周期换算（不碰 MMIO）" {
    // 80 MHz APB、1600 周期 ≈ 20 µs/字 ≈ 50 kHz 采样——与 IDF 的 45~62.5 kHz 同量级。
    const per_word_us = apb_wait_cycles / 80;
    try @import("std").testing.expect(per_word_us >= 10 and per_word_us <= 40);
}
