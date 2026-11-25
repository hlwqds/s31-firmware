//! PMU：modem 的时钟门控码——IDF 启动期 `pmu_init()` 里的那一步，裸机镜像必须自己补。
//!
//! ## 出处
//!
//! 序列照抄 IDF v6.1：
//!
//!   - `esp_system/port/soc/esp32s31/clk.c:47-52`：启动期 `esp_rtc_init()` 调 `pmu_init()`；
//!   - `esp_hw_support/port/esp32s31/pmu_init.c`：`pmu_hp_system_init()` 对 ACTIVE / MODEM / SLEEP
//!     三个 HP 电源模式各写一次 `DIG_ICG_MODEM_CODE`，每写完一个模式就触发两次"立即更新"
//!     （`pmu_ll_imm_update_dig_icg_modem_code`、`pmu_ll_imm_update_dig_icg_switch`）；
//!   - `esp_hw_support/port/esp32s31/pmu_param.c:132/148/164`：三个模式的码分别是
//!     `PMU_HP_ICG_MODEM_CODE_ACTIVE` / `_MODEM` / `_SLEEP`；
//!   - `esp_hal_pmu/include/hal/pmu_types.h:34-36`：这三个码的数值是 2 / 1 / 0。
//!
//! ## 码是干什么的
//!
//! modem 的每个时钟域在 `MODEM_SYSCON` / `MODEM_LPCON` 的 `CLK_CONF_POWER_ST` 里有一个 4 位的
//! 门控位图；时钟适配层写的是 0x6（IDF `modem_clock_domain_icg_config()`：
//! `ICG_NOGATING_ACTIVE | ICG_NOGATING_MODEM`）。位图的每一位对应一个码：PMU 当前处于哪个
//! 电源模式，就拿那个模式的码去查位图；位图里没有这个码，该域的时钟就被门控。
//!
//! ## 不做会怎样（板上实测，2026-11-25）
//!
//! 我们的镜像由 IDF 二级 bootloader 加载后直接进应用，没人做 `pmu_init`，三个码停在复位值 0，
//! 位图 0x6 对不上：`CLK_CONF1.clk_wifimac_en` 是 1，Wi-Fi MAC 的核却没在跑。
//! `MAC_ST`（0x20104CAC）的 bit 13–15 停在复位值 1，`esp_wifi_start` 里等它们自清的自旋永不返回。
//!
//! | 条件（Wi-Fi init 探针） | init 之后 `MAC_ST` | `esp_wifi_start` |
//! | --- | --- | --- |
//! | 都不做 | `0x0000e000` | 不返回 |
//! | 只写码 | `0x0000e000` | 不返回 |
//! | 只触发更新 | `0x0000e000` | 不返回 |
//! | 写码 + 触发 | `0x00000000` | 返回 0 |
//! | 写码 + 触发两次（**模拟**热复位后再跑一次 `initModemIcg()`；Wi-Fi 探针本身没有做过热复位） | `0x00000000` | 返回 0 |
//!
//! 写码加触发之后 `PMU_CLK_STATE0.ICG_MODEM_CODE_STATE` 从 0 变成 2（active），与同一块板上 IDF 的读数相同。
//!
//! 模拟的依据：PMU 的状态跨热复位保留——BLE 探针锁死重启后的第二次启动，调用之前就读到已生效的码
//! （`logs/bt-probe-pmu-icg-lockup-boot.log`）。Wi-Fi 探针里用连续调用两次来重现这个起点。
//!
//! ## 范围
//!
//! 这里只移植"码 + 更新"。`pmu_init` 的其余部分（各模式的稳压器电压档、偏置、备份、睡眠配置、
//! 电源域强制位）同样没做；对照实验表明它们不是 init 与 start 的必要条件：与 IDF 不同的 77 个
//! 可安全写入的寄存器全部按 IDF 值写入后 `MAC_ST` 仍是 `0xE000`，加上这一步才清零。
//! 需要睡眠或调压时再按源码补。

const builtin = @import("builtin");

const on_target = builtin.target.os.tag == .freestanding;

pub const Error = error{ NotOnTarget, ReadbackMismatch };

/// `PMU` 基址（`DR_REG_PMU_BASE`）。
const base: usize = 0x2070_4000;

/// `DIG_ICG_MODEM_CODE`（bit 31:30）。三个 HP 电源模式各有一个寄存器，按
/// `PMU_MODE_HP_ACTIVE=0 / MODEM=1 / SLEEP=2` 排在 `PMU.hp_sys[]` 里。
const code_shift: u5 = 30;
const code_mask: u32 = 0b11 << 30;
const r_mode_code = [3]usize{ base + 0x14, base + 0x54, base + 0x94 };

/// 两个写触发位：`PMU_IMM_MODEM_ICG_REG.update_dig_icg_modem_en`、
/// `PMU_IMM_SLEEP_SYSCLK_REG.update_dig_icg_switch`。
const r_imm_modem_icg: usize = base + 0x104;
const imm_update_dig_icg_modem_en: u32 = 1 << 31;
const r_imm_sleep_sysclk: usize = base + 0x0F8;
const imm_update_dig_icg_switch: u32 = 1 << 28;

/// `PMU_CLK_STATE0_REG`：`PMU_PMU_ICG_MODEM_CODE_STATE`（bit 22:21），当前拿去查门控位图的码。
/// 同一寄存器的 bit 20 `ICG_MODEM_SWITCH_STATE` 每应用一次更新序列就翻转一次：冷启动第一次之后是 1
/// （与 IDF 的读数相同），热复位之后再跑一次就是 0。实测两种取值下 init 与 start 都通过，所以不读它。
const r_clk_state0: usize = base + 0x1C8;
const state_code_shift: u5 = 21;

/// `PMU_HP_ICG_MODEM_CODE_*`（`pmu_types.h:34-36`），同时也是 `CLK_CONF_POWER_ST` 位图里的位号。
pub const IcgModemCode = enum(u2) {
    sleep = 0,
    modem = 1,
    active = 2,
};

/// 三个 HP 电源模式各自的码，下标 = `PMU_MODE_HP_*`（`pmu_param.c:132/148/164`）。
pub const mode_codes = [3]IcgModemCode{ .active, .modem, .sleep };

fn readReg(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn writeReg(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

/// 给三个 HP 电源模式写 modem 的 ICG 码并锁存；写完读回校验。
pub fn initModemIcg() Error!void {
    if (!on_target) return Error.NotOnTarget;

    for (mode_codes, r_mode_code) |code, reg| {
        writeReg(reg, (readReg(reg) & ~code_mask) | (@as(u32, @backingInt(code)) << code_shift));
        // 与 IDF `pmu_hp_system_init()` 末尾同序：先更新 modem 码，再更新 ICG 切换。
        writeReg(r_imm_modem_icg, imm_update_dig_icg_modem_en);
        writeReg(r_imm_sleep_sysclk, imm_update_dig_icg_switch);
    }
    for (mode_codes, r_mode_code) |code, reg| {
        if ((readReg(reg) & code_mask) != (@as(u32, @backingInt(code)) << code_shift)) {
            return Error.ReadbackMismatch;
        }
    }
}

/// 读回当前生效的 modem ICG 码（`PMU_PMU_ICG_MODEM_CODE_STATE`）。IDF 与我们读到的一样是 2（active）。
pub fn modemIcgCode() u2 {
    if (!on_target) return 0;
    return @truncate(readReg(r_clk_state0) >> state_code_shift);
}

// ---------------------------------------------------------------------------
// 启动期给 Wi-Fi 模块选 LP 时钟源。出处：IDF `esp_perip_clk_init()`，
// `esp_system/port/soc/esp32s31/clk.c:190-198`——它在 `app_main` 之前读 RTC 慢时钟的来源（内部 RC 还是
// 32k 晶振），给 Wi-Fi 的 LP 域选同一个源，分频 0。我们的镜像跳过 IDF 的启动初始化，这一步得自己补。
// ---------------------------------------------------------------------------

/// `MODEM_LPCON_WIFI_LP_CLK_CONF_REG`：源选择 bit 0–3（osc_slow、osc_fast、xtal、xtal32k），分频 [15:4]。
const modem_lpcon: usize = 0x2010_F000;
const r_wifi_lp_clk_conf: usize = modem_lpcon + 0x0C;
const r_lpcon_clk_conf: usize = modem_lpcon + 0x18;
const lp_sel_all: u32 = 0xF;
const lp_sel_osc_slow: u32 = 1 << 0;
const lp_div_mask: u32 = 0xFFF << 4;
const clk_wifipwr_en: u32 = 1 << 0;

/// 给 Wi-Fi 模块选 LP 时钟源：内部 RC 慢时钟（`MODEM_CLOCK_LPCLK_SRC_RC_SLOW`），分频 0，并开 `clk_wifipwr_en`。
/// 序列同 `modem_clock_select_lp_clock_source(PERIPH_WIFI_MODULE, RC_SLOW, 0)`
/// （`esp_hw_support/modem/modem_clock.c:231-249`）：清四个源选择位、置 `clk_wifipwr_lp_sel_osc_slow`、分频 0。
///
/// 不做时 `WIFI_LP_CLK_CONF` 停在复位值 0，四个源一个都没选（2026-11-25 与同板 oracle 的同点全量对照：
/// IDF 是 `0x00000001`，我们是 0）。同板的 oracle 没配外接 32k 晶振，RTC 慢时钟用的是内部 RC。
pub fn initModemLpClock() Error!void {
    if (!on_target) return Error.NotOnTarget;
    writeReg(r_wifi_lp_clk_conf, readReg(r_wifi_lp_clk_conf) & ~(lp_sel_all | lp_div_mask));
    writeReg(r_wifi_lp_clk_conf, readReg(r_wifi_lp_clk_conf) | lp_sel_osc_slow);
    writeReg(r_lpcon_clk_conf, readReg(r_lpcon_clk_conf) | clk_wifipwr_en);
}
