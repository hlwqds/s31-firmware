//! ch17-ethernet-mac-phy-driver：RGMII 与 MDIO 的引脚配置。
//!
//! ## 两种完全不同的接法
//!
//! S31 的 GMAC 引脚分两类（`soc_caps.h`：
//! `SOC_EMAC_USE_MULTI_IO_MUX` 与 `SOC_EMAC_MII_USE_GPIO_MATRIX` 同时为 1）：
//!
//!   - **数据/时钟脚有 IO_MUX 功能**：RGMII 的 12 根线全部是 `MCU_SEL = 2`，
//!     直接选功能即可，不经过 GPIO 矩阵（延时可预测，适合 125 MHz DDR）；
//!   - **MDC/MDIO 没有 IO_MUX 功能**：只能走 GPIO 矩阵（信号号 108/109/107）。
//!
//! 引脚号来自 IDF 的板级描述
//! `components/esp_hal_emac/esp32s31/emac_periph.c`：
//!
//!   | 信号        | GPIO（第一组） | IO_MUX 功能 |
//!   | ----------- | -------------- | ----------- |
//!   | TXD0        | 8              | 2           |
//!   | TXD1        | 9              | 2           |
//!   | TXD2        | 10             | 2           |
//!   | TXD3        | 11             | 2           |
//!   | TX_CTL      | 12             | 2（PHY_TXEN_PAD） |
//!   | TXC（125M） | 13             | 2（RMII_CLK_PAD）  |
//!   | RXC         | 14             | 2（RX_CLK_PAD）    |
//!   | RX_CTL      | 15             | 2（PHY_RXDV_PAD）  |
//!   | RXD3        | 16             | 2           |
//!   | RXD2        | 17             | 2           |
//!   | RXD1        | 18             | 2           |
//!   | RXD0        | 19             | 2           |
//!
//! 第二组是 GPIO36–47（同表 `emac_periph.c` 里每个信号的第二个候选）。
//! 本板用第一组：**待真机验证**——原理图上 RJ45 走哪一组必须以实物为准，
//! 这里只是选了 IDF 表里排在前面的那一组。
//!
//! ## MDC/MDIO 的引脚号必须查原理图
//!
//! IDF 不提供 MDC/MDIO 的板级默认值（它们在 `emac_periph.c` 里只有矩阵
//! 信号号，没有 GPIO 号），所以本工程把两个脚做成 `pins.zig` 顶部的常量，
//! 默认 GPIO20/GPIO21 —— **待真机验证**。接错只会让 MDIO 读回 0xFFFF。

const board = @import("board");
const hw = board.hw;
const regs = @import("regs.zig");

/// 板级接线：改这里，不要改下面的实现。
// 原理图（ESP32-S31-Function-CoreBoard-1 V1.0, sheet 03_Ethernet）：
//   PHY_MDC=GPIO5、PHY_MDIO=GPIO6、ETH_PHY_RST=GPIO7、ETH_INTN=GPIO4
//   RGMII: TXD0..3=GPIO8..11、TX_CTL=12、TX_CLK=13、RX_CLK=14、RX_CTL=15、RXD3..0=16..19
// PHY 为 Motorcomm YT8531DC-CA。
/// CNNT_IO_MUX（CNNT_PAD_CTRL）：GPIO13–19 的 PAD 电气控制。
/// 基址 reg_base.h:80 `DR_REG_CNNT_PAD_CTRL_BASE` = 0x2058_8000。
/// 结构（cnnt_io_mux_struct.h:1152-1170）：7 个 gmac_* 寄存器各 4 字节，
/// 其后 ctrl 在 +0x3F4，bit1 = gmac_pad_pin_ctrl_ded_sel。
const cnnt_pad_ctrl: usize = 0x2058_8000;
const cnnt_pad_ctrl_ded_sel: u32 = 1 << 1;
const gmac_rx_clk_reg = cnnt_pad_ctrl + 0x04;
const gmac_rxdv_reg = cnnt_pad_ctrl + 0x08;
const gmac_rxd3_reg = cnnt_pad_ctrl + 0x0c;
const gmac_rxd2_reg = cnnt_pad_ctrl + 0x10;
const gmac_rxd1_reg = cnnt_pad_ctrl + 0x14;
const gmac_rxd0_reg = cnnt_pad_ctrl + 0x18;
const pad_fun_ie: u32 = 1 << 8;

pub const default_mdc: u5 = 5;
pub const default_mdio: u5 = 6;
pub const phy_reset_gpio: u5 = 7;

pub const PinCfg = struct {
    gpio: u5,
    func: u32,
    input: bool,
    /// 0 = 关闭上下拉（RGMII 差分/单端信号不需要内部拉）。
    pull: Pull = .none,
};

pub const Pull = enum { none, up, down };

/// 第一组 RGMII 引脚（顺序：TXD0..TXD3、TX_CTL、TXC、RXC、RX_CTL、RXD3..RXD0）。
pub const rgmii_pins = [_]PinCfg{
    .{ .gpio = 8, .func = regs.func_gmac, .input = false },
    .{ .gpio = 9, .func = regs.func_gmac, .input = false },
    .{ .gpio = 10, .func = regs.func_gmac, .input = false },
    .{ .gpio = 11, .func = regs.func_gmac, .input = false },
    .{ .gpio = 12, .func = regs.func_gmac, .input = false },
    .{ .gpio = 13, .func = regs.func_gmac, .input = false },
    .{ .gpio = 14, .func = regs.func_gmac, .input = true },
    .{ .gpio = 15, .func = regs.func_gmac, .input = true },
    .{ .gpio = 16, .func = regs.func_gmac, .input = true },
    .{ .gpio = 17, .func = regs.func_gmac, .input = true },
    .{ .gpio = 18, .func = regs.func_gmac, .input = true },
    .{ .gpio = 19, .func = regs.func_gmac, .input = true },
};

/// 配置一个 IO_MUX 引脚：选功能 + 输入使能 + 上下拉 + 驱动强度。
///
/// `FUN_DRV` 取 2（约 20 mA 档），RGMII 的 125 MHz 边沿需要足够驱动；
/// 具体档位与走线阻抗相关，**待真机验证**（示波器看 TXC 过冲）。
pub fn initIomuxPin(cfg: PinCfg) void {
    const addr = regs.iomuxAddr(cfg.gpio);
    var v = hw.readReg(addr);
    v &= ~(regs.iomux.mcu_sel_mask | regs.iomux.fun_ie | regs.iomux.fun_pu | regs.iomux.fun_pd);
    v &= ~(@as(u32, 0x3) << regs.iomux.drv_shift);
    v |= (@as(u32, 2) << regs.iomux.drv_shift); // FUN_DRV = 2
    v |= @as(u32, cfg.func) << regs.iomux.mcu_sel_shift;
    if (cfg.input) v |= regs.iomux.fun_ie;
    switch (cfg.pull) {
        .none => {},
        .up => v |= regs.iomux.fun_pu,
        .down => v |= regs.iomux.fun_pd,
    }
    hw.writeReg(addr, v);
}

/// 把所有 RGMII 数据/时钟脚切到 GMAC 的 IO_MUX 功能。
pub fn initRgmii() void {
    for (rgmii_pins) |p| initIomuxPin(p);
    // GPIO13–19 属于 CNNT 域：必须切到专用 GMAC pad 控制，输入 pads 打开 IE，
    // 否则 RX_CLK/RXDV/RXD 的信号进不了 MAC（症状：SWR 永远等不到 RX 时钟域）。
    hw.setBits(cnnt_pad_ctrl + 0x3f4, cnnt_pad_ctrl_ded_sel);
    const inputs = [_]usize{ gmac_rx_clk_reg, gmac_rxdv_reg, gmac_rxd3_reg, gmac_rxd2_reg, gmac_rxd1_reg, gmac_rxd0_reg };
    for (inputs) |addr| hw.setBits(addr, pad_fun_ie);
}

/// 把一个脚切成“由 GPIO 矩阵驱动”的通用模式（MCU_SEL = 1）。
fn toMatrixMode(gpio_num: u5) void {
    const addr = regs.iomuxAddr(gpio_num);
    var v = hw.readReg(addr);
    v &= ~(regs.iomux.mcu_sel_mask | regs.iomux.fun_pu | regs.iomux.fun_pd);
    v |= regs.iomux.mcu_sel_gpio;
    hw.writeReg(addr, v);
}

/// 把信号接到某个脚上做**输出**。
///
/// `force_enable` 决定输出使能来源（`OEN_SEL`，见 gpio_struct.h:1010-1013）：
///
///   - `true`  → `OEN_SEL = 1`：由 `GPIO_ENABLE_REG` 控制，**永远驱动**。
///                单向信号（MDC）用这个，不依赖外设是否提供了 OE。
///   - `false` → `OEN_SEL = 0`：由外设的 OE 控制。双向的 MDIO 必须用这个，
///                否则读 PHY 时 MAC 会把线一直拉着，PHY 无法回话。
pub fn routeOutput(gpio_num: u5, signal_idx: u8, force_enable: bool) void {
    toMatrixMode(gpio_num);
    const addr = regs.gpioOutSelAddr(gpio_num);
    var v: u32 = 0;
    v |= @as(u32, signal_idx) & regs.gpio_matrix.out_sel_mask;
    // OUT_INV_SEL = 0、OEN_INV_SEL = 0
    if (force_enable) v |= regs.gpio_matrix.oen_sel;
    hw.writeReg(addr, v);
    // oen_sel = 1 时这一位就是真正的输出使能；oen_sel = 0 时它不生效。
    hw.writeReg(regs.gpio + regs.gpio_matrix.enable_w1ts, @as(u32, 1) << gpio_num);
}

/// 把某个**输入信号**接到指定脚（S31 是“信号索引”结构：
/// 寄存器按信号号索引，里面写 GPIO 号）。
pub fn routeInput(gpio_num: u5, signal_idx: u8) void {
    toMatrixMode(gpio_num);
    hw.setBits(regs.iomuxAddr(gpio_num), regs.iomux.fun_ie);
    const addr = regs.gpioInSelAddr(signal_idx);
    var v: u32 = 0;
    v |= @as(u32, gpio_num) & regs.gpio_matrix.in_sel_mask;
    v |= regs.gpio_matrix.sig_in_sel; // 1 = 走矩阵（0 = 旁路直连 IO_MUX）
    hw.writeReg(addr, v);
}

/// 释放 PHY 复位：ETH_PHY_RST 为低有效，先拉低 10 ms 再拉高。
pub fn initPhyReset() void {
    toMatrixMode(phy_reset_gpio);
    hw.writeReg(regs.gpio + regs.gpio_matrix.enable_w1ts, @as(u32, 1) << phy_reset_gpio);
    // 低有效：先清零，再置位
    hw.writeReg(regs.gpio + 0x0c, @as(u32, 1) << phy_reset_gpio); // OUT_W1TC
    hw.delayUs(20_000);
    hw.writeReg(regs.gpio + 0x08, @as(u32, 1) << phy_reset_gpio); // OUT_W1TS
    hw.delayUs(200_000);
}

/// MDC（输出，信号 108，永远驱动）+ MDIO（双向：输出 109 / 输入 107，
/// 输出使能交给外设）。
pub fn initMdio(mdc_gpio: u5, mdio_gpio: u5) void {
    routeOutput(mdc_gpio, regs.sig_gmii_mdc_out, true);
    routeOutput(mdio_gpio, regs.sig_gmii_mdo_out, false);
    routeInput(mdio_gpio, regs.sig_gmii_mdi_in);
}

/// 读回某脚的 IO_MUX 配置（打印用）。
pub fn iomuxSnapshot(gpio_num: u5) u32 {
    return hw.readReg(regs.iomuxAddr(gpio_num));
}

/// MCU_SEL 字段（0 = 外设功能，1 = GPIO/矩阵，2 = 第二功能 …）。
pub fn mcuSel(snapshot: u32) u32 {
    return (snapshot & regs.iomux.mcu_sel_mask) >> regs.iomux.mcu_sel_shift;
}

pub fn inputEnabled(snapshot: u32) bool {
    return (snapshot & regs.iomux.fun_ie) != 0;
}

test "rgmii pin table covers 8..19 exactly once" {
    var seen: [20]bool = @splat(false);
    for (rgmii_pins) |p| {
        if (p.gpio < 8 or p.gpio > 19) return error.OutOfRange;
        if (seen[p.gpio]) return error.Duplicate;
        seen[p.gpio] = true;
    }
}

test "four outputs and eight inputs" {
    var outs: usize = 0;
    var ins: usize = 0;
    for (rgmii_pins) |p| {
        if (p.input) ins += 1 else outs += 1;
    }
    // TXD0..3 + TX_CTL + TXC = 6 路输出；RXC + RX_CTL + RXD0..3 = 6 路输入。
    try @import("std").testing.expectEqual(@as(usize, 6), outs);
    try @import("std").testing.expectEqual(@as(usize, 6), ins);
}
