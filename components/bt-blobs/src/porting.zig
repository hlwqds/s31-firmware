//! IDF porting 层的 C 函数（**不在归档里**）在裸机侧的 Zig 实现。
//!
//! 这 9 个函数原本住在 `components/bt/porting_btdm/...` 的 C 里。照 IDF 原文逐条读过之后，
//! 除了 `btdm_lp_enable_clock`（要动 CNNT/modem 域的时钟门控与 BT MAC 复位）之外，
//! 其余**都不是硬活**：4 个是 `return 0`，`ble_controller_scan_duplicate_config` 是
//! NimBLE **host** 侧的扫描去重（controller-only 构建没有 host，归档里也从不引用它），
//! `ble_msys_init` 只是转调归档里的 `r_esp_ble_msys_init`。
const std = @import("std");
const osal = @import("osal.zig");
const mempool_abi = @import("mempool_abi.zig");
const builtin = @import("builtin");
const on_target = builtin.target.os.tag == .freestanding;
const config = @import("config.zig");

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

/// `btdm_coex.c`：`CONFIG_SW_COEXIST_ENABLE` 关时 `return ESP_OK;`（我们不开软件共存）
pub fn btdmCoexInit() c_int {
    return 0;
}

/// `btdm_lp.c`：`UC_BT_CTRL_SLEEP_ENABLE=0` 且无 `CONFIG_PM_ENABLE` ⇒ 两个分支都不进，`return ESP_OK;`
pub fn btdmLpInit() c_int {
    return 0;
}

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
const b_conf1_wifibb_80x1: u32 = @as(u32, 1) << 7;
const b_conf1_bt_apb: u32 = @as(u32, 1) << 16;
const b_conf1_btbb: u32 = @as(u32, 1) << 17;
const b_conf1_btmac: u32 = @as(u32, 1) << 18;
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
/// 后者我们一个字都没写过 ⇒ 与首次对拍发现的 `clk_coex_en` 属同一类遗漏。
/// `0x66660000` 与 wifi-blobs 在本板上早已验证过的写法一致（各域 st_map=6）。
const reg_lpcon_power_st: usize = lpcon_base + 0x20;
const lpcon_power_st_value: u32 = 0x6666_0000;
const b_lpcon_clk_coex_en: u32 = @as(u32, 1) << 1;

const mmio = @import("builtin");
extern fn bt_mmio_read(addr: usize) u32;
extern fn bt_mmio_write(addr: usize, val: u32) void;

fn rd(addr: usize) u32 {
    if (mmio.os.tag != .freestanding) return 0;
    return bt_mmio_read(addr);
}
fn wr(addr: usize, val: u32) void {
    if (mmio.os.tag != .freestanding) return;
    bt_mmio_write(addr, val);
}

var lp_clock_enabled: bool = false;

/// 强制重开时钟门控（复位脉冲之后用：复位可能清掉时钟配置）。
pub fn forceReenableClocks(cfg: *const config.BtdmCfg) void {
    lp_clock_enabled = false;
    btdmLpEnableClock(cfg);
}

/// 是否写 `SOC_PLL_SOURCE_CG`。默认 **false**：板侧证据显示写了之后 ROM 会卡在
/// `UART0` 的 TX FIFO 排空上（`txfifo_cnt` 恒 128）——先排除"这一写扰动时钟"的可能。
pub var pll_write_enabled: bool = false;

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

    // 1) 开时钟（读-改-写，别把别人的位清掉）
    wr(reg_clk_conf1, rd(reg_clk_conf1) | b_conf1_btmac | b_conf1_btbb |
        b_conf1_bt_apb | b_conf1_wifibb_80x1);
    wr(reg_clk_conf, rd(reg_clk_conf) | b_conf_etm | b_conf_sec_ecb |
        b_conf_sec_apb | b_conf_sec | b_conf_ble_timer);
    wr(reg_lpcon_clk_conf, rd(reg_lpcon_clk_conf) | b_lpcon_coex);

    // 2) **读回自证**：这一行直接证明"门到底开没开"，比再烧一轮盲试快
    const c0 = rd(reg_clk_conf);
    const c1 = rd(reg_clk_conf1);
    const lc = rd(reg_lpcon_clk_conf);
    osal.logPublic("bt lp: clk_conf=0x{x:0>8} clk_conf1=0x{x:0>8} lpcon=0x{x:0>8}", .{ c0, c1, lc });
    const need0 = b_conf_etm | b_conf_sec_ecb | b_conf_sec_apb | b_conf_sec | b_conf_ble_timer;
    const need1 = b_conf1_btmac | b_conf1_btbb | b_conf1_bt_apb | b_conf1_wifibb_80x1;
    osal.logPublic("bt lp: gates conf_ok={} conf1_ok={} coex_ok={}", .{
        (c0 & need0) == need0,
        (c1 & need1) == need1,
        (lc & b_lpcon_coex) != 0,
    });

    // 2.5) **SOC PLL 时钟源**：BT 与 PHY 的 deps 里都有它，但它不是门控位而是源选择
    //      ⇒ 只开门控而源没接上，MAC 读回恒 0/全 1，轮询它的状态位永远等不到。
    // **对照实验**：这一写疑似扰动了 UART/APB 时钟（板侧证据：ROM 在 `UART0_STATUS+0x1C`
    // 上等 TX FIFO 排空，txfifo_cnt 恒 128 ⇒ FIFO 满且不动）。默认先不写，用 -Dbt-pll-write 打开。
    if (pll_write_enabled) wr(reg_hp_clkrst_modem_conf, modem_conf_on);
    const mc = rd(reg_hp_clkrst_modem_conf);
    osal.logPublic("bt lp: modem_conf=0x{x:0>8} (want 0x3d) pll_ok={}", .{ mc, (mc & 0x3F) == modem_conf_on });

    // 2.6) **PHY 前端时钟**：不开这路，PHY 起不来 ⇒ MAC 等不到 PHY 就绪。
    wr(reg_clk_conf1, rd(reg_clk_conf1) | b_conf1_fe_20m | b_conf1_fe_40m | b_conf1_fe_80m |
        b_conf1_fe_160m | b_conf1_fe_apb | b_conf1_fe_pwdet_adc | b_conf1_fe_adc | b_conf1_fe_dac);
    const c1b = rd(reg_clk_conf1);
    const fe_need = b_conf1_fe_20m | b_conf1_fe_40m | b_conf1_fe_80m | b_conf1_fe_160m |
        b_conf1_fe_apb | b_conf1_fe_pwdet_adc | b_conf1_fe_adc | b_conf1_fe_dac;
    osal.logPublic("bt lp: clk_conf1=0x{x:0>8} fe_ok={}", .{ c1b, (c1b & fe_need) == fe_need });

    // 2.7) **LP timer 时钟**（IDF 放在 mac_reset 之后；我们紧随其后，顺序同样满足"门控先于复位"）
    wr(reg_lpcon_lp_timer_conf, rd(reg_lpcon_lp_timer_conf) & ~@as(u32, 0xF) | @as(u32, 1)); // 选 32k 源 + div=0
    wr(reg_lpcon_32k_conf, (rd(reg_lpcon_32k_conf) & ~@as(u32, 0x3)) | @as(u32, 1)); // 32k 选内部 RC32K
    // bit0(wifipwr) + bit1(coex) + bit3(lp_timer)：与 IDF step 5 之后的 `0x0b` 一致
    wr(reg_lpcon_clk_conf, rd(reg_lpcon_clk_conf) | b_lpcon_clk_wifipwr_en |
        b_lpcon_clk_coex_en | b_lpcon_clk_lp_timer_en);
    // LP 域的 ICG 状态映射（此前从未写）：IDF 的 icg_map_init_all 覆盖两个域
    wr(reg_lpcon_power_st, rd(reg_lpcon_power_st) | lpcon_power_st_value);
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
        wr(a, rd(a) | @as(u32, 0x18)); // modem_clk_source_sel | modem_pll_clk_en
        osal.logPublic("bt lp: MODEM_CONF=0x{x:0>8} (bit3+bit4 set)", .{rd(a)});
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
    //   只写 `clk_conf_power_st` 位图是**惰性**的：必须再打 apply 位，PMU 才会把
    //   新的 clock-gating 图应用下去。位定义（`soc/esp32s31/register/soc/pmu_reg.h`）：
    //     PMU_IMM_HP_FUNC_ICG   (+0xfc)  bit31 UPDATE_DIG_ICG_FUNC_EN
    //     PMU_IMM_HP_APB_ICG    (+0x100) bit31 UPDATE_DIG_ICG_APB_EN
    //     PMU_IMM_MODEM_ICG     (+0x104) bit31 UPDATE_DIG_ICG_MODEM_EN
    //     PMU_IMM_SLEEP_SYSCLK  (+0xf8)  bit28 UPDATE_DIG_ICG_SWITCH
    {
        const pmu: usize = 0x2070_4000;
        wr(pmu + 0xfc, rd(pmu + 0xfc) | (@as(u32, 1) << 31));
        wr(pmu + 0x100, rd(pmu + 0x100) | (@as(u32, 1) << 31));
        wr(pmu + 0x104, rd(pmu + 0x104) | (@as(u32, 1) << 31));
        wr(pmu + 0xf8, rd(pmu + 0xf8) | (@as(u32, 1) << 28));
        osal.logPublic("bt lp: PMU ICG apply done func=0x{x:0>8} apb=0x{x:0>8} modem=0x{x:0>8} slp=0x{x:0>8}", .{
            rd(pmu + 0xfc), rd(pmu + 0x100), rd(pmu + 0x104), rd(pmu + 0xf8),
        });
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
    osal.logPublic("bt lp: mac reset族 done (btmac/btmac_apb/ble_timer/mod_sec), rst_conf=0x{x:0>8}", .{rd(reg_rst_conf)});
    if (on_target) {
        osal.logPublic("bt lp: uart0 status after = 0x{x:0>8}", .{(@as(*volatile u32, @ptrFromInt(0x2038_A01C))).*});
    }
}

/// `btdm_lp_reset(true)`：低功耗子系统复位。当前无状态可复位。
pub fn btdmLpReset(enable: bool) void {
    _ = enable;
}

/// `btdm_coex_enable()`：软件共存未开 ⇒ 直接成功。
pub fn btdmCoexEnable() c_int {
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
