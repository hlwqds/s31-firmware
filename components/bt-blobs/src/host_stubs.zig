//! bt-blobs 主机测试的目标侧 extern 桩（x86_64 链接需要定义）。
//!
//! 板上这些符号由 ROM（spiflash）、libphy（load_cal、modem_clock）、归档
//! （`r_sym_bt_*` 数据槽）和板级代码（`flash_op_window`）提供；主机测试目标不链
//! 任何归档，`refAllDecls` 又会分析 bringup/porting/gate 的全部 pub 函数，所以
//! 这里给同签名的空实现。**只被 `host_tests.zig` 导入**，目标板镜像不含本文件。
//!
//! 覆盖门禁若报本文件"纯数据/零逻辑"，属预期：桩没有可测行为。

/// 归档数据槽（hci ctx 槽，板上位于 0x2f011020）。
export var r_sym_bt_pSy5Wex1v0iXw5RdWtwL: u32 = 0;

/// 板级 flash 操作窗口标志（`board.hw` 同款）。
export var flash_op_window: u32 = 0;

export fn modem_clock_module_enable(modem: c_int) callconv(.c) void {
    _ = modem;
}

/// BT MAC 复位族（板上由 `link/modem_clock_light.c` 提供）。
export fn modem_clock_module_mac_reset(domain: c_int) callconv(.c) void {
    _ = domain;
}

/// PHY 使能（板上默认由 ROM 提供，见 `rom_syms.ld`）。
export fn esp_phy_enable(modem: c_int) callconv(.c) void {
    _ = modem;
}

/// RF 寄存器 I2C 读写原语（ROM）；`bringup.init` 的晶振 trim 读回用到。
export fn phy_i2c_writeReg(reg: u8, hostid: u8, blk: u8, data: u8) callconv(.c) void {
    _ = reg;
    _ = hostid;
    _ = blk;
    _ = data;
}

export fn phy_i2c_readReg(reg: u8, hostid: u8, blk: u8) callconv(.c) u8 {
    _ = reg;
    _ = hostid;
    _ = blk;
    return 0;
}

export fn esp_phy_load_cal_and_init() callconv(.c) void {}

export fn esp_btbb_enable() callconv(.c) void {}

export fn esp_rom_spiflash_erase_sector(sector_number: u32) callconv(.c) c_int {
    _ = sector_number;
    return 0;
}

export fn esp_rom_spiflash_write(target_address: u32, src_data: [*]const u32, len_bytes: u32) callconv(.c) c_int {
    _ = target_address;
    _ = src_data;
    _ = len_bytes;
    return 0;
}

/// bt_printf_shim 的行环（轮 8 flash 标记判据）：主机测试目标不链 shim C，给空定义。
export var s31_bt_log_mute: c_int = 1; // **轮 94-final**：0x200A 后 UART0 被门控，默认静默
export var s31_bt_ring: [16][48]u8 = @splat(@splat(0));
export var s31_bt_ring_head: c_uint = 0;
export var s31_bt_log_dropped: c_uint = 0;
