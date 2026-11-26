//! IDF porting 层的 C 函数（**不在归档里**）在裸机侧的 Zig 实现。
//!
//! 这 9 个函数原本住在 `components/bt/porting_btdm/...` 的 C 里。照 IDF 原文逐条读过之后，
//! 除了 `btdm_lp_enable_clock`（要动 CNNT/modem 域的时钟门控与 BT MAC 复位）之外，
//! 其余**都不是硬活**：4 个是 `return 0`，`ble_controller_scan_duplicate_config` 是
//! NimBLE **host** 侧的扫描去重（controller-only 构建没有 host，归档里也从不引用它），
//! `ble_msys_init` 只是转调归档里的 `r_esp_ble_msys_init`。
const std = @import("std");
extern var flash_op_window: u32; // board.hw 同款
fn flashOpSet(v: u32) void {
    flash_op_window = v;
}
const osal = @import("osal_kit").osal;
const mempool_abi = @import("mempool_abi.zig");
const builtin = @import("builtin");
const on_target = builtin.target.os.tag == .freestanding;
const config = @import("config.zig");
/// 共存开关（`firmware/build.zig` 用 `-Dcoex` 生成）。关着时下面两个生命周期函数仍是 `return 0`。
const coex_gate = @import("coex_gate");
const radio_coex = if (coex_gate.enabled) @import("radio_coex") else struct {};

// ---------------------------------------------------------------------------
// 4 个 `return 0`（IDF 原文：日志/外部/共存/低功耗的"初始化"在没有对应子系统时是空实现）
// ---------------------------------------------------------------------------

/// `btdm_log.c`：`return 0;`
pub fn btdmLogInit() c_int {
    return 0;
}

/// `btdm_external.c`：`return 0;`
pub fn btdmExternalInit() c_int {
    return 0;
}

/// `btdm_coex.c:203-211`：开了软件共存是 `coex_init()`（经共存胶水交给核），否则 `return ESP_OK;`。
/// `-Dcoex` 打开时转发 `radio-coex`。核必须已由 `coex_wiring.boot()` 启动，否则胶水回 `ESP_OK` 并计一次拒绝。
pub fn btdmCoexInit() c_int {
    if (coex_gate.enabled) return radio_coex.ble.btdm_coex_init();
    return 0;
}

/// `btdm_lp.c:374`：sleep_cb/pm_lock 两分支确实不进（`UC_BT_CTRL_SLEEP_ENABLE=0`、无
/// `CONFIG_PM_ENABLE`），但函数**尾行 `r_btdm_hal_rtc_freq_set` 是无条件的**——此前漏做。
pub fn btdmLpInit() c_int {
    if (@import("builtin").os.tag != .freestanding) return 0;
    // 官方 `btdm_lp_init`（btdm_lp.c:374）的最后一步：`r_btdm_hal_rtc_freq_set(s_bt_lpclk_freq)`。
    // **轮 17 起：MAIN_XTAL 口径 100000**（sel_xtal + div399 ⇒ 40M/400=100kHz）。
    // 旧 RC_SLOW 口径 27200（oracle sdkconfig 路径）实证 synth-ready 双双失败，弃用。
    // **disasm 实证全镜像 0 调用者**——blob 从不自己设，官方由本胶水负责；此前 sleep
    // 对象 rtc_freq u64 一直靠 step10 补丁的 32000（RC32K 口径，与实际 tick 差 17.6%）。
    // 写点（0x40062b98，**双参 u64 对**）：a0=obj[24]、a1=obj[28]；槽空返回 1。
    // （obj[+4]=freq<<24 是隔壁 9yM12TlY@0x40062bb8 的另一个 export，别混。）
    return r_btdm_hal_rtc_freq_set(rtc_freq_lp, 0);
}

/// LP timer 实际 tick（lp_timer_conf=0x18F4：sel_xtal + div_num=399 ⇒ 40MHz/400=100kHz）。
pub const rtc_freq_lp: u32 = 100000;
extern fn r_btdm_hal_rtc_freq_set(freq_lo: u32, freq_hi: u32) c_int;

/// `ble.c` 的扫描去重：调的是 `ble_vhci_disc_duplicate_mode_disable/enable` 与
/// `ble_vhci_disc_duplicate_set_max_cache_size` —— 那是 **NimBLE host 侧**的过滤器，
/// 既不在归档里、归档也从不引用（`grep ble_vhci` 在全归档零命中）。
/// controller-only 构建没有 host ⇒ 空实现是对的，**别去找它们的定义**。
pub fn bleControllerScanDuplicateConfig() void {}

// ---------------------------------------------------------------------------
// msys：`ble_msys.c:67-72` 转调归档的 `r_esp_ble_msys_init`
// ---------------------------------------------------------------------------

/// 取值来自 **controller 侧** Kconfig `porting_btdm/controller/ble/Kconfig.in:225-254`
/// （`#if CONFIG_BT_NIMBLE_ENABLED` 的 `#else` 分支，controller-only 构建走这条）。
/// ⚠ `from_heap=1` ⇒ 归档会经 `wr_btdm_osal_malloc` 向我们的 arena 要约
/// `12×(256+8) + 24×(320+8) ≈ 11 KB` ⇒ **`initArena()` 必须先于本函数完成**。
pub const msys = struct {
    pub const block1_count: u16 = 12; // BT_LE_MSYS_1_BLOCK_COUNT（Kconfig.in:227）
    pub const block1_size: u16 = 256; // BT_LE_MSYS_1_BLOCK_SIZE（:236）
    pub const block2_count: u16 = 24;
    pub const block2_size: u16 = 320;
    pub const from_heap: c_int = 1; // BT_LE_MSYS_BUF_FROM_HEAP default y
};

extern fn r_esp_ble_msys_init(
    s1_size: u32,
    s2_size: u32,
    s1_count: u16,
    s2_count: u16,
    from_heap: c_int,
) c_int;

// ---------------------------------------------------------------------------
// 时钟 / 复位 / 共存使能
//
// `btdm_lp_enable_clock` 是这 9 个函数里唯一的真硬件活。**当前故意留空实现 + 大声日志**：
// HCI Reset / Read Local Version 是**软件层**的命令，未必需要射频时钟；只有当 controller
// 一碰 MAC 寄存器就 fault 时，才回来补下面这 8+4 个门。
//
// 补的时候照 IDF `esp_hw_support/modem/port/esp32s31/modem_clock_impl.c`：
//   `modem_clock_module_enable(PERIPH_BT_MODULE)`      = BLE_CLOCK_DEPS（**8 个门**）：
//       BLE_MAC·clk_conf1.clk_btmac_en、BT_I154_COMMON_BB·enable_bt_bb_clock、
//       ETM·enable_etm_clock、COEXIST（在 **lpcon** 块：modem_lpcon_ll_enable_coex_clock）、
//       WIFI_BB_80X1·enable_wifibb_80x1_clock、SOC_PLL_SOURCE_CG·modem_clock_hal_enable_soc_pll_source_cg、
//       BT_APB·enable_bt_apb_clock + enable_modem_sec_apb_clock、
//       BT_PERIPHERAL·enable_modem_sec_clock + enable_ble_timer_clock
//   `modem_clock_module_enable(PERIPH_BT_APB_MODULE)`   = BT_APB_CLOCK_DEPS（**4 个门**）：
//       BT_APB、ETM、SOC_PLL_SOURCE_CG、BLE_MAC
//   `modem_clock_module_mac_reset(PERIPH_BT_MODULE)`    = 复位 BT MAC（按 module 分派）
//
// 两条纪律：① **宁可多开不要少开** —— 少开一个门，controller 访问该外设就是总线挂死
// （比缺时钟更糟）；多开只浪费一点功耗 ⇒ 直接照 BLE_CLOCK_DEPS 全开。
// ② 裸机没有 `esp_os_enter_critical_safe` 的锁 ⇒ 单核下用"关中断写寄存器再开"代替。
// ---------------------------------------------------------------------------

// ---- 寄存器与位号（全部来自 IDF reg 头里的 `bitpos:[n]` 注释，交叉验证过）----
//
//   DR_REG_MODEM_SYSCON_BASE = MODEM_BASE(0x20100000) + 0x9C00 = 0x20109C00
//   DR_REG_MODEM_LPCON_BASE  = MODEM_PWR_BASE(0x2010D000) + 0x2000 = 0x2010F000
//   clk_conf        = SYSCON + 0x4     modem_rst_conf = SYSCON + 0x10
//   clk_conf1       = SYSCON + 0x14    LPCON clk_conf = LPCON + 0x18
//
// `clk_conf` 位号（从 `pwdet_sar_clock_ena`=bit0 数起，用 `CLK_DATA_DUMP_EN=BIT(31)` 反查）：
//   clk_etm_en=22、clk_modem_sec_ecb_en=25、clk_modem_sec_apb_en=28、
//   clk_modem_sec_en=29、clk_ble_timer_en=30
// `clk_conf1` 位号（从 `clk_wifibb_22m_en`=bit0 数起，用 `CLK_FE_DAC_EN=BIT(21)` 反查）：
//   clk_wifibb_80x1_en=7、clk_bt_apb_en=16、clk_btbb_en=17、clk_btmac_en=18
// LPCON：clk_coex_en=bit1。复位：modem_rst_conf.rst_btmac=bit16。
//
// 范围收缩：**不碰 ICG 位图**（`icg_config[domain]` / `clk_conf_power_st` 是电源管理那条路，
// `modem_clock_module_enable` 完全不碰它们）。
const syscon_base: usize = 0x2010_9C00;

var mp_ev: mempool_abi.Pool align(4) = @splat(0);
var mp_evq: mempool_abi.Pool align(4) = @splat(0);
var mp_co: mempool_abi.Pool align(4) = @splat(0);
var mp_sem: mempool_abi.Pool align(4) = @splat(0);
var mp_mux: mempool_abi.Pool align(4) = @splat(0);
const lpcon_base: usize = 0x2010_F000;
const reg_clk_conf: usize = syscon_base + 0x04;
const reg_clk_conf_power_st: usize = syscon_base + 0x0c;
const reg_rst_conf: usize = syscon_base + 0x10;
// `modem_rst_conf` 的位（esp32s31 `modem_syscon_struct.h`）。读回恒 0,只可写。
const b_rst_btmac_apb: u32 = 1 << 15;
const b_rst_modem_ecb: u32 = 1 << 25;
const b_rst_modem_ccm: u32 = 1 << 26;
const b_rst_modem_bah: u32 = 1 << 27;
const b_rst_modem_sec: u32 = 1 << 29;
const b_rst_ble_timer: u32 = 1 << 30;
const reg_clk_conf1: usize = syscon_base + 0x14;
const reg_lpcon_clk_conf: usize = lpcon_base + 0x18;

const b_conf_etm: u32 = @as(u32, 1) << 22;
const b_conf_sec_ecb: u32 = @as(u32, 1) << 25;
const b_conf_sec_apb: u32 = @as(u32, 1) << 28;
const b_conf_sec: u32 = @as(u32, 1) << 29;
const b_conf_ble_timer: u32 = @as(u32, 1) << 30;
// **IDF `clk_conf` = 0x7e601002** 的位图（nibble6 = E = 1110）：
//   bit25 sec_ecb / bit26 sec_ccm / **bit27 sec_bah** 置位，**bit24 zbmac 清零**。
// ⇒ 我们此前漏的是 **bit26 与 bit27**（而 bit24 不应置位）。
// 目标 = 0x00201002 | bit23 | {22,25,26,27,28,29,30} = **0x7e601002**。
const b_conf_sec_ccm: u32 = @as(u32, 1) << 26;
const b_conf_sec_bah: u32 = @as(u32, 1) << 27;
const b_conf1_wifibb_80x1: u32 = @as(u32, 1) << 7;
const b_conf1_bt_apb: u32 = @as(u32, 1) << 16;
const b_conf1_btbb: u32 = @as(u32, 1) << 17;
const b_conf1_btmac: u32 = @as(u32, 1) << 18;
/// `MODEM_SYSCON_CLK_CONF_FORCE_ON`（`+0x08`）里归 PHY 前端与 BT 的强开位：fe、fe_apb、btbb、btmac、bt_apb。
/// bit0-2（wifibb、wifimac、wifi_apb）是 Wi-Fi 的单元，BLE 不碰。
const b_fo_bt_fe: u32 = 0x0000_00F8;
const b_lpcon_coex: u32 = @as(u32, 1) << 1;
const b_rst_btmac: u32 = @as(u32, 1) << 16;

// ---- 第二轮补的缺口（2026-11-17）----
//
// 板侧证据：`r_btdm_task_init` 在 ROM 里等 `MAC_ST[15:13]`（28/28 采样 mac=0xE000）。
// 只开 ICG 门控位不够 —— 还缺三样：
//   ① `SOC_PLL_SOURCE_CG`：**不是门控位**，是时钟源选择字段，写整个 6 bit 魔数
//      `0x3d`（开）/ `0x25`（关）到 `HP_SYS_CLKRST.modem_conf` = **0x205871E0**。
//   ② PHY 的前端时钟（同在 `clk_conf1`）：`clk_fe_20m/40m/80m/160m/apb_en`=11..15、
//      `clk_fe_pwdet_adc_en`=19、`clk_fe_adc_en`=20、`clk_fe_dac_en`=21。
//      不开这一路，PHY 起不来 ⇒ MAC 等不到 PHY 就绪 ⇒ 忙位永不清。
//   ③ LP timer 时钟（LPCON）：`LP_TIMER_CONF`=+0x4（选 32k 源 + 分频 0）、
//      `MODEM_32K_CLK_CONF`=+0x14（RC32K 码 = 1）、`CLK_CONF`=+0x18 的 bit3 `clk_lp_timer_en`。
const reg_hp_clkrst_modem_conf: usize = 0x2058_71E0;
const modem_conf_on: u32 = 0x3d;
const modem_conf_off: u32 = 0x25;

const b_conf1_fe_20m: u32 = @as(u32, 1) << 11;
const b_conf1_fe_40m: u32 = @as(u32, 1) << 12;
const b_conf1_fe_80m: u32 = @as(u32, 1) << 13;
const b_conf1_fe_160m: u32 = @as(u32, 1) << 14;
const b_conf1_fe_apb: u32 = @as(u32, 1) << 15;
const b_conf1_fe_pwdet_adc: u32 = @as(u32, 1) << 19;
const b_conf1_fe_adc: u32 = @as(u32, 1) << 20;
const b_conf1_fe_dac: u32 = @as(u32, 1) << 21;

const reg_lpcon_lp_timer_conf: usize = lpcon_base + 0x04;
const reg_lpcon_32k_conf: usize = lpcon_base + 0x14;
const b_lpcon_clk_lp_timer_en: u32 = @as(u32, 1) << 3;
// **`MODEM_LPCON + 0x18` 的 bit0/bit1 此前从未写**，而 IDF 的 `BLE_CLOCK_DEPS` 里有
// `COEXIST` → `modem_lpcon_ll_enable_coex_clock()` → `clk_conf.clk_coex_en`(bit1)、
// 以及 `WIFIPWR`(bit0)。板侧对拍实证：IDF 在 step 5 之后该字 = `0x0000000b`
// （bit0+bit1+bit3），我们只写了 bit3 ⇒ **bit1 缺失**是 `0x2010B000` 不可访问的直接原因。
const b_lpcon_clk_wifipwr_en: u32 = @as(u32, 1) << 0;

/// `MODEM_LPCON + 0x20` = `clk_conf_power_st`：LP 域的 ICG 状态映射
/// （bit16-19 wifipwr / 20-23 coex / 24-27 i2c_mst / 28-31 lp_apb）。
/// IDF 的 `modem_clock_module_icg_map_init_all()` 会把它覆盖到的**两个域**都填上：
/// `MODEM_SYSCON.clk_conf_power_st`（我们写了 `0x64646400`）**和这一个**。
/// 后者的写入见 `btdmLpEnableClock` 内的 `wr(reg_lpcon_power_st, …)`（此前这一段注释说"从未写过"，已过时）。
/// `0x66660000` 与 wifi-blobs 在本板上早已验证过的写法一致（各域 st_map=6）。
const reg_lpcon_power_st: usize = lpcon_base + 0x20;
const lpcon_power_st_value: u32 = 0x6666_0000;
const b_lpcon_clk_coex_en: u32 = @as(u32, 1) << 1;

const mmio = @import("builtin");
extern fn bt_mmio_read(addr: usize) u32;
extern fn bt_mmio_write(addr: usize, val: u32) void;

/// 主机测试用的假寄存器文件：非 freestanding 目标上 `rd` / `wr` 走这里。板上不存在（`builtin` 是编译期判断）。
const HostReg = struct { addr: usize = std.math.maxInt(usize), val: u32 = 0 };
var host_regs: [48]HostReg = @splat(.{});

pub fn rd(addr: usize) u32 {
    if (mmio.os.tag != .freestanding) {
        for (&host_regs) |*s| if (s.addr == addr) return s.val;
        return 0;
    }
    return bt_mmio_read(addr);
}
pub fn wr(addr: usize, val: u32) void {
    if (mmio.os.tag != .freestanding) {
        for (&host_regs) |*s| {
            if (s.addr == addr or s.addr == std.math.maxInt(usize)) {
                s.* = .{ .addr = addr, .val = val };
                return;
            }
        }
        return;
    }
    bt_mmio_write(addr, val);
}

var lp_clock_enabled: bool = false;

/// **PHY 频域使能**（移植自 wifi 侧已验证序列，默认关闭）。
/// 与 wifi 的关键差异：**保留 `LPCON_FORCE_ON` 的 `I2C_MST_FO`(bit2)** —— BLE 的 PHY 寄存器
/// 走模拟 I2C 主控，wifi 侧那条 `LPCON+0x18←0x1` 会把 bit2 清掉，**不能照抄**。
pub var phy_domain_enable: bool = true; // **必需**：关掉会停在 step 6（实测），保持 true

pub fn phyDomainEnable() void {
    if (!phy_domain_enable) return;
    // 1) SOC_PLL_SOURCE_CG —— **不写**。
    // 本文件 238-240 行已记录：写了之后 ROM 会卡在 UART0 TX-FIFO 排空上（txfifo_cnt 恒 128）。
    // 实测（2026-11-19）：TXFIFO_CNT 停在 120/128、CPU 85–96% 在 hw.rawWrite、
    // **注意**：此前曾据 TXFIFO_CNT=120 / tick 170 Hz 关掉这一写 —— 那两条观测后来都被撤回
    // （120 是 dump 自己刚写的 14 行；FIFO 实际 125→4 能排空；170 Hz 是归档自己的 tick）。
    // 本文件 331-333 行明确：**不开 bit4，modem 寄存器总线不应答，访问 0x2010B000 直接挂死（不是 fault）**。
    // ⇒ 该写必须执行。`pll_write_enabled` 保留为实验开关，默认 true。
    if (pll_write_enabled) wr(0x2058_71E0, 0x3d);
    // 2) MODEM_SYSCON CLK_CONF1：PHY 依赖组（FE_APB/FE_80M/FE_160M/FE_DAC/FE_PWDET_ADC/FE_ADC）
    const conf1: usize = 0x2010_9C14;
    const bits: u32 = (1 << 13) | (1 << 14) | (1 << 15) | (1 << 19) | (1 << 20) | (1 << 21);
    wr(conf1, rd(conf1) | bits);
    // 2b) MODEM_SYSCON 三处按 IDF 实测值**直接写**（不是 OR —— Wi-Fi 侧就是这么写的，
    //     且它能让 register_chipv7_phy 返回 rc=1）。
    //   +00 test_conf = 0x00000100
    //   +04 clk_conf  = 0x00201002  ← 模拟前端时钟（pwdet/adc/dac）
    //   +0c ICG(门控位图) = 0x64646400  ← apb/peri/wifi/bt/fe
    // **注意**：这三行是本会话加的，且跑在 step 51 —— **晚于** step 5 的
    // `btdmLpEnableClock()`（它已把 `+0x04` 置成 IDF 的 step-5 后值 `0x7e601002`）。
    // 若在此写成 boot 值 `0x00201002`，会把 `0x7e400000`（modem/模拟域时钟位）**抹掉**
    // ⇒ `0x2010B000` 立即不应答。这里只保留 `+0x04` 的**已有值**，不清位。
    // 2b 的两条整字写已**移到 boot 期**（`bringup.zig` 的 `init()` 开头）：
    // 放在这里（step 51）会覆盖 step 5 的 RMW 结果。
    // 3) SYSCON_FORCE_ON：WIFI_APB_FO(2) | FE_FO(3) | FE_APB_FO(4)
    // **5F7D 入口标记**（UART 无关）：phyDomainEnable 已进入
    {
        const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
        const ese = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
        var rec: [4]u32 = .{ 0xADC0_5F7D, 0x2010_9C08, 0x2010_9C14, 0x2010_F018 };
        rec[1] = rd(0x2010_9C08);
        _ = ese(0x18E000 / 0x1000);
        flashOpSet(1);
        flashOpSet(1);
        // **CLIC[25] 门控**（防 flash 写期中断打进 XIP trap ⇒ 缓存关 ⇒ 挂死）：
        // 清 nmies(bit3)+IE(bit8)，写完恢复。T0 采样器已武装、125µs 一发，
        // 不门控则与 ms 级 flash 擦写必然相撞。
        const clic25: usize = 0x1080_1000 + 25 * 4;
        const gsaved: u32 = rd(clic25);
        wr(clic25, gsaved & ~@as(u32, 0x108));

        _ = esw(0x18E000, &rec, 16);
        flashOpSet(0);
        flashOpSet(0);
        wr(clic25, gsaved);
    }
    const fo: usize = 0x2010_9C08;
    // **补 bit6 `clk_btmac_fo` 与 bit7 `clk_bt_apb_fo`**（IDF `clk_conf_force_on` 位序）：
    // `0x2010B000` 是私有 BLE/MAC 块，缺这两个 force-on ⇒ 无时钟 ⇒ 不应答。
    wr(fo, rd(fo) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 7));
    // 4) LPCON_FORCE_ON：WIFIPWR_FO(0) | **I2C_MST_FO(2)**（BLE 必需）
    const fo_lp: usize = 0x2010_F01C;
    wr(fo_lp, rd(fo_lp) | (1 << 0) | (1 << 2));
    // 5) 确认 LPCON+0x18 的 bit2 保持（不要照抄 wifi 的 ←0x1）
    const lp18: usize = 0x2010_F018;
    wr(lp18, rd(lp18) | (1 << 2));

    // ⛔ **不要调 `phy_open_fe_bb_clk`**（ROM `0x2f80131c`，符号在
    //    `boards/esp32s31-coreboard/linker/rom_syms.ld:137`）：
    //    ADR-001:2129-2131 实测它会 **stall**（日志停在 `write 0x20107C80`），
    //    :2253-2255 结论是"相位对齐 IDF 这条路在裸机 bring-up 上不成立"，
    //    且 wifi 路径的自旋点就在它内部（ADR:231-237）。
    //    ⇒ BT 路径去跑它只会把 PHY 使能处 stall 掉，does not answer 0x200A.
    // 10) **PMU 模拟外设电源域上电**（`regi2c_ctrl_ll_i2c_sar_periph_enable` 等价，
    //     esp_hal_regi2c/esp32s31/include/hal/regi2c_ctrl_ll.h:76-83）：
    //     `PMU_ANA_PERI_PWR_CTRL_REG` = `DR_REG_PMU_BASE(0x20704000) + 0x208 = 0x20704208`
    //     bit31 `PMU_RSTB_PERIF_I2C`（复位）、bit30 `PMU_XPD_PERIF_I2C`（上电）。
    //     **此域没电 ⇒ 模拟前端（regi2c 之后的 RF/FE）不存在 ⇒ vendor PHY 在 FE 寄存器
    //     上轮询永不满足（实测 0x2f828a78 自旋、基址 s0=0x20100000）**。
    //     序列：清 bit31 → ~1µs → 置 bit30+bit31（IDF 注释：1µs 延时由数字设计推荐）。
    {
        const pa: usize = 0x2070_4208;
        var v = rd(pa);
        v &= ~(@as(u32, 1) << 31);
        wr(pa, v);
        var dly: u32 = 0;
        while (dly < 2_000) : (dly += 1) asm volatile ("nop");
        v = rd(pa);
        v |= (1 << 30) | (1 << 31);
        wr(pa, v);
        osal.logPublic("bt phy: ana peri pwr on, reg=0x{x:0>8}", .{rd(pa)});
    }
    osal.logPublic("bt phy: domain clocks on (pll=0x3d conf1|=FE lp18|=i2c_mst widgets syscon/lpcon-en ana-pwr)", .{});

    // 7) **`MODEM_WIDGETS_CLK_EN`（0x20109400 bit0，默认 0 = 关）**：
    //    WIDGETS 私有块（MODEM_BASE+0x9400）**自己有一张时钟使能寄存器**，
    //    我们此前从没写过 ⇒ 归档写 `W+0x480/4A8/4B8`(0x20109880/8A8/8B8) 全被丢弃
    //    ⇒ `0x200A` 里它写完就轮询 ⇒ 死循环（2026-11-19 实测：写 0x0FFFFFFF 读回 0）。
    //    IDF 侧出处：`soc/esp32s31/include/modem/modem_widgets_reg.h:14-18`。
    //    **写-回读自证**：写特征值 → 读回相等才算成功。
    {
        const wclk: usize = 0x2010_9400;
        // 只置**已定义**的 bit0（`MODEM_WIDGETS_CLK_EN`），别写全 1 ——
        // 该寄存器其余位保留，写 1 的后果未知（破坏性扫描的教训）。
        wr(wclk, rd(wclk) | (1 << 0));
        // 8) **两个块级 CLK_EN（+0x00）此前从未写过**：
        //    `MODEM_SYSCON_CLK_EN` = 0x20109C00 bit0、
        //    `MODEM_LPCON_CLK_EN` = 0x2010F000 bit0（**默认 0**）。
        //    porting 写过 SYSCON +0x04..+0x14、LPCON +0x08..+0x20，唯独漏了 +0x00。
        //    （注意 0x20109880/A8/B8/BC 就在 widgets 块空间 0x20109400..0x20109BFF 里。）
        wr(0x2010_9C00, rd(0x2010_9C00) | (1 << 0));
        wr(0x2010_F000, rd(0x2010_F000) | (1 << 0));
        // 8b) **I2C_ANA_MST 块时钟**（`I2C_ANA_MST_CLK_EN` = DATE_REG(+0x3C) bit28，
        //     **默认 0**；块基址 = MODEM_PWR_BASE + 0x2800 = **0x2010F800**，
        //     reg_base.h:24 ⇒ 使能地址 = **0x2010F83C**）。此前从未写过：
        //     模拟事务全成空操作 ⇒ 模拟前端配置不进去 ⇒ FE 轮询永不满足。
        wr(0x2010_F83C, rd(0x2010_F83C) | (1 << 28));
        // 9) **modem 域主时钟**（`reg_modem_clk_en`，0x20587040 bit0）—— 单独干净测
        //    （此前只在污染性扫描里测过，读数不可信）
        wr(0x2058_7040, rd(0x2058_7040) | (1 << 0));
        osal.logPublic("bt phy: syscon/lpcon CLK_EN set (0x{x}/0x{x})", .{
            rd(0x2010_9C00), rd(0x2010_F000),
        });
        // 自证：写一个特征值到 W+0x480，读回比较
        const probe_addr: usize = 0x2010_9880;
        wr(probe_addr, 0x1234_5678);
        const rb: u32 = rd(probe_addr);
        osal.logPublic("bt phy: widgets clk on, W+0x480 write/readback 0x12345678=0x{x:0>8} ok={}", .{ rb, rb == 0x1234_5678 });
    }
    osal.logPublic("bt phy: domain clocks on (pll=0x3d conf1|=FE lp18|=i2c_mst widgets)", .{});
    // **5F7C 出口标记**：phyDomainEnable 全序列完成（widgets 自证也已过）
    {
        const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
        const ese = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
        var rec: [4]u32 = .{ 0xADC0_5F7C, rd(0x2010_9C00), rd(0x2010_F000), rd(0x2010_F83C) };
        _ = ese(0x18E000 / 0x1000);
        flashOpSet(1);
        flashOpSet(1);
        // **CLIC[25] 门控**（防 flash 写期中断打进 XIP trap ⇒ 缓存关 ⇒ 挂死）：
        // 清 nmies(bit3)+IE(bit8)，写完恢复。T0 采样器已武装、125µs 一发，
        // 不门控则与 ms 级 flash 擦写必然相撞。
        const clic25: usize = 0x1080_1000 + 25 * 4;
        const gsaved: u32 = rd(clic25);
        wr(clic25, gsaved & ~@as(u32, 0x108));

        _ = esw(0x18E000, &rec, 16);
        flashOpSet(0);
        flashOpSet(0);
        wr(clic25, gsaved);
    }
}

/// 强制重开时钟门控（复位脉冲之后用：复位可能清掉时钟配置）。
pub fn forceReenableClocks(cfg: *const config.BtdmCfg) void {
    lp_clock_enabled = false;
    btdmLpEnableClock(cfg);
}

/// 是否写 `SOC_PLL_SOURCE_CG`。默认 **false**：板侧证据显示写了之后 ROM 会卡在
/// `UART0` 的 TX FIFO 排空上（`txfifo_cnt` 恒 128）——先排除"这一写扰动时钟"的可能。
pub var pll_write_enabled: bool = true;

/// `btdm_lp_enable_clock` 的真实现：`BLE_CLOCK_DEPS`(8) + `BT_APB_CLOCK_DEPS`(4) + MAC 复位。
///
/// **顺序**：先开时钟（三个寄存器 12 位），**再**做 MAC 复位——IDF 也是
/// "开 BT 模块 → 开 BT APB 模块 → mac_reset → LP timer 时钟"。复位必须在时钟之后，
/// 否则 MAC 刚被复位又被 controller 初始化。
///
/// 纪律：**宁可多开不要少开**——少一个门，访问该外设就是总线挂死（比缺时钟更糟）；
/// 多开只浪费一点功耗。
/// 是否真的写时钟门控。设 false 用于**对照实验**：排除"我们改时钟把 UART 弄停"。
/// 板侧证据链：`UART0_STATUS.TXFIFO_CNT` 恒 128（FIFO 满且不排空），而 UART0 就在
/// `0x2038A000` —— 和我们改的 modem/外设时钟是同一片。
pub var clock_writes_enabled: bool = true;

pub fn btdmLpEnableClock(cfg: *const config.BtdmCfg) void {
    _ = cfg;
    if (lp_clock_enabled) return;
    lp_clock_enabled = true;
    if (!clock_writes_enabled) {
        osal.logPublic("bt lp: clock writes SKIPPED (control run)", .{});
        return;
    }

    // 1) 开时钟。**只置位、不清位**（2026-11-27，ADR-003 第 4 节的时钟域规则）：这些字是两个射频共享的，
    // 每一位归一个时钟单元（IDF `modem_clock_impl.c` 的单元表，`radio-coex/src/clocks.zig`）。
    // 两个射频同镜、Wi-Fi 先 start 时，整字写会把 Wi-Fi 的位清掉——板上实测扫描照常、认证关联之后被 AP 以
    // `reason=7` 断开（`docs/verification/coex-verification.md` §15 的对照 C）。
    // `MODEM_SYSCON_CLK_CONF1`（`+0x14`）按单元分成三组，这里置的是后两组：
    //   bit0-10    wifibb_22m/40m/44m/80m/40x/80x/40x1、**wifibb_80x1(7，Wi-Fi 与 BLE 共用)**、160x1、wifimac、wifi_apb
    //   bit11-15、19-21  PHY 前端：fe_20m/40m/80m/160m/apb、fe_pwdet_adc/adc/dac（公共）
    //   bit16-18   bt_apb、btbb（BT_I154_COMMON_BB）、btmac（BLE_MAC）
    // 合并镜像里 Wi-Fi 已置好前两组，这里是给它们补上 fe_20m/40m，再置 BT 的三位。
    wr(reg_clk_conf1, rd(reg_clk_conf1) | b_conf1_bt_apb | b_conf1_btbb | b_conf1_btmac |
        b_conf1_wifibb_80x1 | b_conf1_fe_20m | b_conf1_fe_40m | b_conf1_fe_80m | b_conf1_fe_160m |
        b_conf1_fe_apb | b_conf1_fe_pwdet_adc | b_conf1_fe_adc | b_conf1_fe_dac);
    // 强开位（`+0x08`）：使能位会被 ICG 门控，强开位不会。单独的 BLE 探针没有 ICG 码，BT_APB 的写不落地
    // 就是它没开（轮 121v）。只强开 PHY 前端与 BT 自己的单元，不替 Wi-Fi 决定它的基带、MAC、APB 要不要常开。
    wr(syscon_base + 0x08, rd(syscon_base + 0x08) | b_fo_bt_fe);
    wr(reg_clk_conf, rd(reg_clk_conf) | b_conf_etm | b_conf_sec_ecb |
        b_conf_sec_apb | b_conf_sec | b_conf_ble_timer |
        b_conf_sec_ccm | b_conf_sec_bah);
    wr(reg_lpcon_clk_conf, rd(reg_lpcon_clk_conf) | b_lpcon_coex);

    // 2) **读回自证**：这一行直接证明"门到底开没开"，比再烧一轮盲试快
    const c0 = rd(reg_clk_conf);
    const c1 = rd(reg_clk_conf1);
    const lc = rd(reg_lpcon_clk_conf);
    osal.logPublic("bt lp: clk_conf=0x{x:0>8} clk_conf1=0x{x:0>8} lpcon=0x{x:0>8}", .{ c0, c1, lc });
    const need0 = b_conf_etm | b_conf_sec_ecb | b_conf_sec_apb | b_conf_sec | b_conf_ble_timer | b_conf_sec_ccm | b_conf_sec_bah;
    const need1 = b_conf1_btmac | b_conf1_btbb | b_conf1_bt_apb | b_conf1_wifibb_80x1;
    osal.logPublic("bt lp: gates conf_ok={} conf1_ok={} coex_ok={}", .{
        (c0 & need0) == need0,
        (c1 & need1) == need1,
        (lc & b_lpcon_coex) != 0,
    });

    // 2.5) **SOC PLL 时钟源**：BT 与 PHY 的 deps 里都有它，但它不是门控位而是源选择
    //      ⇒ 只开门控而源没接上，MAC 读回恒 0/全 1，轮询它的状态位永远等不到。
    // **对照实验**：这一写疑似扰动了 UART/APB 时钟（板侧证据：ROM 在 `UART0_STATUS+0x1C`
    // 上等 TX FIFO 排空，txfifo_cnt 恒 128 ⇒ FIFO 满且不动）。默认写；用 `-Dbt-pll-write=false` 关闭做对照。
    if (pll_write_enabled) wr(reg_hp_clkrst_modem_conf, modem_conf_on);
    const mc = rd(reg_hp_clkrst_modem_conf);
    osal.logPublic("bt lp: modem_conf=0x{x:0>8} (want 0x3d) pll_ok={}", .{ mc, (mc & 0x3F) == modem_conf_on });

    // 2.6) **PHY 前端时钟**：不开这路，PHY 起不来 ⇒ MAC 等不到 PHY 就绪。位已在上面第 1 步一起置了，这里只读回自证。
    const c1b = rd(reg_clk_conf1);
    const fe_need = b_conf1_fe_20m | b_conf1_fe_40m | b_conf1_fe_80m | b_conf1_fe_160m |
        b_conf1_fe_apb | b_conf1_fe_pwdet_adc | b_conf1_fe_adc | b_conf1_fe_dac;
    osal.logPublic("bt lp: clk_conf1=0x{x:0>8} fe_ok={}", .{ c1b, (c1b & fe_need) == fe_need });

    // 2.7) **LP timer 时钟**（IDF 放在 mac_reset 之后；我们紧随其后，顺序同样满足"门控先于复位"）
    // **轮 17（2026-11-22）：RC_SLOW → MAIN_XTAL**。RC_SLOW 口径下官方与我们的
    // synth-ready（0x201098BC.bit2）双双永不置位、FE450 静止、0x200A error 3——
    // RF 合成器校准需要 40MHz 晶振参考，136k RC 无法驱动。btdm_lp.c 的
    // MAIN_XTAL 分支：sel_xtal(bit2=1) + div=40M/100k-1=399 ⇒ lp_timer_conf=0x18F4
    //（100kHz tick），rtc_freq=100000。
    wr(reg_lpcon_lp_timer_conf, 0x18F4); // sel_xtal(bit2) + div_num=399 ⇒ 40M/400=100kHz
    wr(reg_lpcon_32k_conf, (rd(reg_lpcon_32k_conf) & ~@as(u32, 0x3)) | @as(u32, 1)); // 32k 选内部 RC32K
    // `MODEM_LPCON_CLK_CONF`（`+0x18`）：bit0 wifipwr + bit1 coex + bit3 lp_timer，与 IDF step 5 之后的读数一致。
    // bit2（i2c_mst）是 PHY 的模拟 I2C 主控，不在这里管：单独跑时它由强开位顶着（读回是 1），
    // 合并镜像里是 Wi-Fi 的 PHY 开的，**不能清**——所以这一句同样是只置位。
    wr(reg_lpcon_clk_conf, rd(reg_lpcon_clk_conf) |
        b_lpcon_clk_wifipwr_en | b_lpcon_clk_coex_en | b_lpcon_clk_lp_timer_en);
    // **lpcon+0x04 = 0x41 / +0x08 = 0x314 / +0x0c = 0x01**（IDF step 5 后的实测值，我们此前未写）
    wr(lpcon_base + 0x04, rd(lpcon_base + 0x04) | @as(u32, 0x40));
    wr(lpcon_base + 0x08, @as(u32, 0x314)); // 定值写（IDF step5 后实测）
    wr(lpcon_base + 0x0c, rd(lpcon_base + 0x0c) | @as(u32, 0x01));
    // **`MODEM_LPCON + 0x20` = 0x66660000**：step-5 边界四点对拍实测 IDF 写这个值
    // （此前我按 **step4** 快照误判为 0 并撤销过一次 —— 那是错的时间点）。
    wr(reg_lpcon_power_st, lpcon_power_st_value);
    osal.logPublic("bt lp: lp_timer_conf=0x{x:0>8} 32k_conf=0x{x:0>8} lpcon_clk=0x{x:0>8}", .{
        rd(reg_lpcon_lp_timer_conf), rd(reg_lpcon_32k_conf), rd(reg_lpcon_clk_conf),
    });

    // 2.75) **modem PLL 时钟**（`HP_SYS_CLKRST_MODEM_CONF` = 0x205871e0）。
    //   位定义（hp_sys_clkrst_struct.h）：
    //     bit0 modem_apb_clk_en(默认1)  bit1 modem_rst_en  bit2 modem_clk_en(默认1)
    //     bit3 modem_clk_source_sel     bit4 **modem_pll_clk_en(默认 0)**
    //     bit5 modem_xtal_clk_en(默认1)
    //   IDF 的对照镜像实测：init 前 0x25，init 后 0x3d ⇒ 它把 bit3 与 bit4 打开。
    //   **bit4 是 modem PLL 时钟，默认关闭**；不开它，modem 的寄存器总线不应答，
    //   表现为访问 `0x2010B000` 直接挂死（不是 fault）。
    {
        const a: usize = 0x2058_71E0;
        // **受 `pll_write_enabled` 控制**：本文件 238-240 记录写此寄存器会让 ROM 卡在
        // UART0 TX-FIFO 排空上（txfifo_cnt 恒 128）。实测 2026-11-19 复现：
        // TXFIFO_CNT=120/128、tick 170 Hz（设定 10 kHz）。默认关，便于二分 bit3/bit4。
        if (pll_write_enabled) {
            wr(a, rd(a) | @as(u32, 0x18)); // modem_clk_source_sel | modem_pll_clk_en
            osal.logPublic("bt lp: MODEM_CONF=0x{x:0>8} (bit3+bit4 set)", .{rd(a)});
        }
    }

    // 2.8) **IDF `clk_conf` 里被我们漏掉的时钟**（与 IDF 成功镜像逐字对拍得出）：
    //      IDF clk_conf=0x7e601002，我们 0x00201002 ⇒ 差 0x7E400000：
    //        bit22 clk_etm_en
    //        bit25 clk_modem_sec_ecb_en   bit26 _ccm_en   bit27 _bah_en
    //        bit28 clk_modem_sec_apb_en   bit29 clk_modem_sec_en
    //        bit30 **clk_ble_timer_en**
    //      复位与时钟必须成对：此前我们复位了这些块却从未给它们开门控。
    {
        const b_etm: u32 = 1 << 22;
        const b_sec = (@as(u32, 1) << 25) | (@as(u32, 1) << 26) | (@as(u32, 1) << 27) |
            (@as(u32, 1) << 28) | (@as(u32, 1) << 29);
        const b_ble_timer: u32 = 1 << 30;
        wr(reg_clk_conf, rd(reg_clk_conf) | b_etm | b_sec | b_ble_timer);
        // clk_conf1 / clk_conf_power_st：IDF 分别为 0x00070080 / 0x64646400，我们全 0。
        wr(reg_clk_conf1, rd(reg_clk_conf1) | @as(u32, 0x0007_0080));
        wr(reg_clk_conf_power_st, rd(reg_clk_conf_power_st) | @as(u32, 0x6464_6400));
        osal.logPublic("bt lp: clk_conf=0x{x:0>8} clk_conf1=0x{x:0>8} power_st=0x{x:0>8}", .{
            rd(reg_clk_conf), rd(reg_clk_conf1), rd(reg_clk_conf_power_st),
        });
    }

    // 2.9) **PMU 的 ICG 应用触发**（IDF 在 `rtc_clk_init` 里做，我们此前从未做）。
    // **轮 120s 拔除**：apply 位 = PMU 状态机动作（应用 ICG 位图下硬件），疑似
    // 瞬时门控/状态迁移 = LP 核 1ms 死亡时刻候选。单变量验证：
    // 若核活过 1ms/0x200A 推进 ⇒ 我们的 ICG apply = 坍缩触发件（IDF rtc_clk_init
    // 在时钟树未起时调用安全，我们在 task 上下文调用语义不同）。
    {
        _ = rd;
        _ = wr;
        // const pmu: usize = 0x2070_4000;
        // wr(pmu + 0xfc, rd(pmu + 0xfc) | (@as(u32, 1) << 31));
        // wr(pmu + 0x100, rd(pmu + 0x100) | (@as(u32, 1) << 31));
        // wr(pmu + 0x104, rd(pmu + 0x104) | (@as(u32, 1) << 31));
        // wr(pmu + 0xf8, rd(pmu + 0xf8) | (@as(u32, 1) << 28));
    }

    if (!on_target) return; // 主机侧无 MMIO：窗口 dump 与后续写入都跳过
    // **四个 modem 窗口全量 dump**（step 5 末尾）：与 oracle 的同名 dump 逐字对拍。
    // 直读 `0x2010B000` 会挂板，所以"我们的块是否可读"只能靠寄存器状态等价来推断。
    {
        const wins = [_]struct { name: []const u8, base: usize, n: usize }{
            // 只读 syscon 的前 4 个字（`+0x004` = clk_conf，是本轮根因的判据）。
            // 其余窗口在 init 路径上会多打 ~1 KB 阻塞写，已移除。
            .{ .name = "syscon", .base = 0x2010_9C00, .n = 4 },
            // clkrst 只打我们真正比对过的那几项（原 128 项会把 FIFO 灌满，导致后续行被丢）
            .{ .name = "clkrst", .base = 0x2058_7000, .n = 16 },
        };
        for (wins) |w| {
            var i: usize = 0;
            while (i < w.n) : (i += 1) {
                const v = (@as(*volatile u32, @ptrFromInt(w.base + i * 4))).*;
                osal.logLine("bt bringup: win: {s} +0x{x:0>3} = 0x{x:0>8}", .{ w.name, i * 4, v });
            }
        }
    }

    // 3) **MAC 复位族**（时钟之后）。IDF `modem_clock_module_mac_reset(PERIPH_BT_MODULE)`
    //    依次复位四个域,顺序与位号如下（`modem_syscon_struct.h` 的 `modem_rst_conf`）:
    //      rst_btmac      bit16
    //      rst_btmac_apb  bit15   ← 此前**漏做**
    //      rst_ble_timer  bit30   ← 此前**漏做**
    //      modem_sec      bit29 (+ ecb 25 / ccm 26 / bah 27) ← 此前**漏做**
    //    只做 bit16 时,`0x2010B000`(BLE/MAC 私有块)读一次即总线挂起;
    //    IDF 的对照镜像里同一地址在 init 后读得到 `0x5ac00000`。
    //    该寄存器读回恒为 0（写 1 不可回读）,所以每步都**直接写值**而非 RMW。
    const pulse = struct {
        fn f(v: u32) void {
            wr(reg_rst_conf, v);
            wr(reg_rst_conf, 0);
        }
    };
    pulse.f(b_rst_btmac); // 1. BT MAC
    pulse.f(b_rst_btmac_apb); // 2. BT MAC APB
    pulse.f(b_rst_ble_timer); // 3. BLE timer
    pulse.f(b_rst_modem_ecb | b_rst_modem_ccm | b_rst_modem_bah | b_rst_modem_sec); // 4. modem sec
    // ✅ **实验（2026-11-19）：脉冲 rst_btbb_apb(17)/rst_btbb(18)** —— 此前从未碰过。
    //    位图（`modem_syscon_struct.h`，锚点 reserved3=bit3）：
    //    btmac_apb=15 ✓ / btmac=16 ✓（现有常量正确）/ **btbb_apb=17 / btbb=18**。
    //    我们的 MAC 复位族脉冲了 15/16/30/25/26/27/29，唯独没脉冲 17/18
    //    ⇒ 若 BB 上电即在复位里，它从未被释放 ⇒ 写丢弃、轮询读 0、0x200A 错误码 3。
    //    判据用端到端（marker stage 23 / btdm_tx 6）；rst_conf 读回恒 0 无信息。
    pulse.f((1 << 17));
    pulse.f((1 << 18));
    // （"mac reset族 done" 日志已删：rst_conf 读回恒 0 无信息，镜像容量紧张。）

    // ⛔ **"BLE RTC timer 时钟链"块已删除（2026-11-22 反汇编根因定案）**。该块
    //    （2026-11-21）按**错误偏移**写了三个 MODEM_LPCON 寄存器。`modem_lpcon_struct.h`
    //    的真实布局：lp_timer_conf=+0x04、coex_lp_clk_conf=+0x08、wifi_lp_clk_conf=+0x0C、
    //    modem_32k_clk_conf=**+0x14**、clk_conf=**+0x18**、clk_conf_force_on=+0x1C——
    //    该块却按 "+0x18=32k、+0x08=lp_timer、+0x1C=clk_conf" 写。净效果（oracle 对拍
    //    值 → 块后实际值）：+0x08 coex LP 时钟 **0x314 → 0x01C**（xtal+xtal32k 双源同时
    //    选通 + div=1 的未定义混选）、+0x18 clk_conf **0x0b → 0x09**（**clk_coex_en 被清**）、
    //    +0x1C **0x04 → 0x404**。板上无 XTAL32K ⇒ 这是已回滚的 xtal32k 回归事故的变体复发
    //    （2026-11-21 的"寄存器级展开"把它重新引入）。coex LP 时钟链被打断 ⇒ blob 的
    //    coex/LL 调度等不到 tick ⇒ 泵头冻结、BB 永不启动（47C/450 静止）——与 §29.23/29.24
    //    终版定性吻合。32k conf 的正主写入在上方 `reg_lpcon_32k_conf`（+0x14），从未缺失。
    // ✅ 修复 = 整块删除：+0x08/+0x18/+0x1C 回到 oracle 对拍值 0x314/0x0b/0x04。
    //    （"lpcon 回读"日志已删：落在 FIFO 丢失区打不出来，判据已由离线反汇编取得；
    //    第一轮上板已证 oracle 对齐后泵头仍冻结，LPCON 划出嫌疑清单。）
}

/// `btdm_lp_reset(true)`：低功耗子系统复位。当前无状态可复位。
pub fn btdmLpReset(enable: bool) void {
    _ = enable;
}

/// `btdm_coex_enable()`：软件共存未开 ⇒ 直接成功；开了 ⇒ `coex_enable()`（使能计数里属于 BLE 的那一次加一）。
pub fn btdmCoexEnable() c_int {
    if (coex_gate.enabled) return radio_coex.ble.btdm_coex_enable();
    return 0;
}

/// 只在目标构建里引用归档符号；主机侧返回 0（主机没有 msys 子系统）。
pub fn bleMsysInit() c_int {
    if (@import("builtin").os.tag != .freestanding) return 0;
    // `SYSINIT_MSYS_n_MEMBLOCK_SIZE = BLE_MSYS_ALIGN(size, 4)`；128/320 本来就是 4 的倍数。
    return r_esp_ble_msys_init(msys.block1_size, msys.block2_size, msys.block1_count, msys.block2_count, msys.from_heap);
}

// ---------------------------------------------------------------------------
// mempool：IDF 在池空时会回退动态 malloc，我们的静态池**没有回退**
// ⇒ 必须做容量校验，并把 5 个数字打出来，否则"池不够"会表现成 controller 不动
// ---------------------------------------------------------------------------

/// IDF 的 `btdm_memblock_get` 失败码是 -1..-10；这里用 -1 表示"容量不够"，
/// 并把每个超标项单独编号，便于一眼看出是哪一类池。
pub const MempoolErr = struct {
    pub const evt: c_int = -1;
    pub const evtq: c_int = -2;
    pub const co: c_int = -3;
    pub const sem: c_int = -4;
    pub const mutex: c_int = -5;
};

/// 静态池容量（与 `osal.zig` 的池一致；那里也有一条用例断言"默认 config 的 element 数 ≤ 容量"）。
pub const pool_caps = struct {
    pub const evt: u16 = osal.pool_caps.event;
    pub const evtq: u16 = osal.pool_caps.eventq;
    pub const co: u16 = osal.pool_caps.callout;
    pub const sem: u16 = osal.pool_caps.sem;
    pub const mutex: u16 = osal.pool_caps.mutex;
};

/// 复刻 `btdm_osal_elem_mempool_init(&elem)` 的**校验**部分：
/// IDF 会按 `elem` 的 5 个计数建池；我们只能从静态池取，所以超了就直接报错。
pub fn elemMempoolInit(elem: config.ElemNum) c_int {
    // **先无条件报全五项**：只报第一项会让"到底要多少"分多次启动才能凑齐。
    osal.logPublic("bt mempool: need evt={d} evtq={d} co={d} sem={d} mutex={d} / cap {d}/{d}/{d}/{d}/{d}", .{
        elem.evt_count, elem.evtq_count, elem.co_count, elem.sem_count, elem.mutex_count,
        pool_caps.evt,  pool_caps.evtq,  pool_caps.co,  pool_caps.sem,  pool_caps.mutex,
    });
    if (elem.evt_count > pool_caps.evt) {
        osal.logPublic("bt mempool: evt {d} > cap {d}", .{ elem.evt_count, pool_caps.evt });
        return MempoolErr.evt;
    }
    if (elem.evtq_count > pool_caps.evtq) {
        osal.logPublic("bt mempool: evtq {d} > cap {d}", .{ elem.evtq_count, pool_caps.evtq });
        return MempoolErr.evtq;
    }
    if (elem.co_count > pool_caps.co) {
        osal.logPublic("bt mempool: co {d} > cap {d}", .{ elem.co_count, pool_caps.co });
        return MempoolErr.co;
    }
    if (elem.sem_count > pool_caps.sem) {
        osal.logPublic("bt mempool: sem {d} > cap {d}", .{ elem.sem_count, pool_caps.sem });
        return MempoolErr.sem;
    }
    if (elem.mutex_count > pool_caps.mutex) {
        osal.logPublic("bt mempool: mutex {d} > cap {d}", .{ elem.mutex_count, pool_caps.mutex });
        return MempoolErr.mutex;
    }
    osal.logPublic("bt mempool: ok evt={d} evtq={d} co={d} sem={d} mutex={d}", .{
        elem.evt_count, elem.evtq_count, elem.co_count, elem.sem_count, elem.mutex_count,
    });

    // **真正建池**：这一步此前完全缺失，是本轮所有怪现象的源头。
    //
    // IDF 的 `btdm_osal_elem_mempool_init` 对每个池做两件事：
    //   1. 用 `BTDM_MEMPOOL_SIZE(n, blksize) = ceil(blksize/4) * n` 个 u32 分配缓冲；
    //   2. `btdm_mempool_init(&pool, count, blksize, buf, "name")` —— 它是 inline 包装，
    //      真正干活的是**归档**的 `r_btdm_os_mempool_init`。
    //
    // 我们只做容量校验、从不调它 ⇒ 归档的池从未初始化 ⇒
    // `r_sym_bt_OkE7` 的守卫 `*(*s0 + 8) != 0` 为假 ⇒ 跳过 `fqmZk`
    // ⇒ 锚点 `P` 停在 NULL ⇒ `Xpuq` 从**地址 0** 零填充到 `0x2010B100`
    // ⇒ modem 寄存器窗口（含我们配好的时钟）被清零 ⇒ 表现为"无声卡死"。
    if (!on_target) return 0; // 主机侧无归档、无 arena：只验证容量逻辑
    const rc_evt = initPool("evt", elem.evt_count, 12, &mp_ev);
    if (rc_evt != 0) return rc_evt;
    const rc_evq = initPool("evtq", elem.evtq_count, 4, &mp_evq);
    if (rc_evq != 0) return rc_evq;
    const rc_co = initPool("co", elem.co_count, 20, &mp_co);
    if (rc_co != 0) return rc_co;
    const rc_sem = initPool("sem", elem.sem_count, 4, &mp_sem);
    if (rc_sem != 0) return rc_sem;
    const rc_mux = initPool("mutex", elem.mutex_count, 4, &mp_mux);
    if (rc_mux != 0) return rc_mux;
    return 0;
}

/// 建一个池：缓冲取自我们的 arena，池结构由归档的 `r_btdm_os_mempool_init` 填。
/// 块尺寸按 IDF 的 `*_freertos` 结构（evt 12 / evtq 4 / co 20 / sem 4 / mutex 4）。
fn initPool(name: [*:0]const u8, count: u16, blk: u32, mp: *anyopaque) c_int {
    if (count == 0) return 0;
    const bytes: u32 = ((blk + 3) / 4) * @as(u32, count) * 4;
    const buf = osal.btdmMalloc(bytes, 0) orelse {
        osal.logPublic("bt mempool: {s} 缓冲分配失败 ({d} B)", .{ name, bytes });
        return MempoolErr.evt;
    };
    const rc = mempool_abi.init(mp, count, blk, buf, name);
    osal.logPublic("bt mempool: init {s} blocks={d} blk={d} buf={x} rc={d}", .{
        name, count, blk, @intFromPtr(buf), rc,
    });
    return rc;
}

/// 一步到位：`seed + elemCalc → 容量校验`，就是 `bt.c:172-186` 那三步。
pub fn prepareMempool(cfg: *const config.Config) c_int {
    const elem = config.mempoolElemNum(cfg);
    return elemMempoolInit(elem);
}

test "porting: 4 个空实现都返回 0，扫描去重是空操作" {
    try std.testing.expectEqual(@as(c_int, 0), btdmLogInit());
    try std.testing.expectEqual(@as(c_int, 0), btdmExternalInit());
    try std.testing.expectEqual(@as(c_int, 0), btdmCoexInit());
    try std.testing.expectEqual(@as(c_int, 0), btdmLpInit());
    bleControllerScanDuplicateConfig();
    try std.testing.expectEqual(@as(c_int, 0), bleMsysInit()); // 主机侧早退
    // 常量取 controller 侧 Kconfig（不是 NimBLE 的 24/128 分支）
    try std.testing.expectEqual(@as(u16, 12), msys.block1_count);
    try std.testing.expectEqual(@as(u16, 256), msys.block1_size);
    try std.testing.expectEqual(@as(u16, 24), msys.block2_count);
    try std.testing.expectEqual(@as(u16, 320), msys.block2_size);
    try std.testing.expectEqual(@as(c_int, 1), msys.from_heap);
}

test "porting: mempool 容量校验按类报错，默认 config 通过" {
    // 默认 config 算出来 181 个事件 ⇒ 192 够
    try std.testing.expectEqual(@as(c_int, 0), prepareMempool(&config.defaults()));
    // 人为超限：每类各报自己的错误码
    var over = config.ElemNum{ .evt_count = 999, .evtq_count = 0, .co_count = 0, .sem_count = 0, .mutex_count = 0 };
    try std.testing.expectEqual(MempoolErr.evt, elemMempoolInit(over));
    over = .{ .evt_count = 0, .evtq_count = 999 };
    try std.testing.expectEqual(MempoolErr.evtq, elemMempoolInit(over));
    over = .{ .co_count = 999 };
    try std.testing.expectEqual(MempoolErr.co, elemMempoolInit(over));
    over = .{ .sem_count = 999 };
    try std.testing.expectEqual(MempoolErr.sem, elemMempoolInit(over));
    over = .{ .mutex_count = 999 };
    try std.testing.expectEqual(MempoolErr.mutex, elemMempoolInit(over));
}

test "porting: 时钟门控是空实现（可重复调用不崩），共存使能返回 0" {
    const c = config.defaults();
    btdmLpEnableClock(&c.btdm);
    btdmLpEnableClock(&c.btdm); // 幂等
    btdmLpReset(true);
    btdmLpReset(false);
    try std.testing.expectEqual(@as(c_int, 0), btdmCoexEnable());
}

test "porting: BLE 开时钟只置自己的位，Wi-Fi 已有的时钟位一个不掉" {
    // 起点是合并镜像里 Wi-Fi start 之后的读数（`logs/wifi-link-connect-boot.log` 的 `REGDUMP after-scan`，
    // 2026-11-26）：Wi-Fi 的基带 / MAC / APB、PHY 前端、模拟 I2C 主控都已置位，BT 的位还没有。
    host_regs = @splat(.{});
    lp_clock_enabled = false;
    wr(reg_clk_conf1, 0x0038_E7FF);
    wr(reg_clk_conf, 0x0020_1002);
    wr(syscon_base + 0x08, 0x0000_0000);
    wr(reg_lpcon_clk_conf, 0x0000_0005);
    wr(reg_hp_clkrst_modem_conf, 0x0000_0025);
    const c = config.defaults();

    btdmLpEnableClock(&c.btdm);

    // CLK_CONF1：Wi-Fi 的 0-10 位原样在，PHY 前端补齐，BT 的三位出现（两边都开 = 0x003F_FFFF）。
    try std.testing.expectEqual(@as(u32, 0x003F_FFFF), rd(reg_clk_conf1));
    // CLK_CONF：Wi-Fi / PHY 的位不动，BLE 的 etm、modem_sec、ble_timer 出现。
    try std.testing.expectEqual(@as(u32, 0x7E60_1002), rd(reg_clk_conf));
    // 强开位：只强开 PHY 前端与 BT 的（bit3-7），Wi-Fi 的 wifibb / wifimac / wifi_apb 不被替它决定。
    try std.testing.expectEqual(@as(u32, 0x0000_00F8), rd(syscon_base + 0x08));
    // LPCON：i2c_mst（bit2，PHY 的模拟 I2C 主控）还在，共存与 BLE 的 LP 定时器时钟出现。
    try std.testing.expectEqual(@as(u32, 0x0000_000F), rd(reg_lpcon_clk_conf));
    // modem 时钟源：IDF 的做法是整字写 0x3D（Wi-Fi 与 BLE 的依赖里都有它）。
    try std.testing.expectEqual(@as(u32, 0x0000_003D), rd(reg_hp_clkrst_modem_conf));
    // 再开一次不累加、不清位。
    lp_clock_enabled = false;
    btdmLpEnableClock(&c.btdm);
    try std.testing.expectEqual(@as(u32, 0x003F_FFFF), rd(reg_clk_conf1));
    try std.testing.expectEqual(@as(u32, 0x0000_000F), rd(reg_lpcon_clk_conf));
}

test "porting: 单独跑（寄存器是复位值）时开时钟后的读数与原来的整字写相同" {
    // BLE 单独的镜像里这些字从 0 起步（PHY 的模拟前端配置 `0x00201002` 是 `bringup.init` 开头先置的）：只置位
    // 写出来的值必须与 2026-11-26 之前整字写的值一样，否则单独的 BLE 探针会被这次改动带着变。
    host_regs = @splat(.{});
    lp_clock_enabled = false;
    wr(reg_hp_clkrst_modem_conf, 0x0000_0025);
    wr(reg_clk_conf, 0x0020_1002);
    const c = config.defaults();
    btdmLpEnableClock(&c.btdm);
    try std.testing.expectEqual(@as(u32, 0x003F_F880 | b_conf1_fe_20m | b_conf1_fe_40m), rd(reg_clk_conf1));
    try std.testing.expectEqual(@as(u32, 0x7E60_1002), rd(reg_clk_conf));
    try std.testing.expectEqual(@as(u32, 0x0000_00F8), rd(syscon_base + 0x08));
}
