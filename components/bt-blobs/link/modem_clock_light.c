/* **轮 118b**：esp_eco3_light.c 的裸机替身。
 *
 * 历史：bt-ctl-oracle 构建树曾生成 esp_eco3_light.c.obj（ECO3 + light-sleep
 * 变体），以 8 个轻量符号满足 probe 链接；该生成物随构建树重配消失。
 * 本文件按裸机语义重建同样签名：
 * - modem_clock_module_enable / mac_reset / wifi_bt_common_module_enable：
 *   no-op——裸机无其他外设竞争，modem 电源域由 blob 自己的 RF-ON burst 管；
 * - phy_module_enable / disable / has_clock_bits：PHY 时钟位管理，no-op，
 *   has_clock_bits 恒 0（无 bits 可关）；
 * - pmu_init：no-op——PMU 已由 ROM/boot 初始化，重配反而打坏状态
 *   （bg_3049 时代实证：真 pmu_init/modem_clock 在裸机 bringup 中段崩 ROM）。
 */
#include <stdint.h>
#include <stdbool.h>

/* **轮 123**：modem_clock_module_enable 从 no-op 升级为**寄存器直写真实现**。
 *
 * 崩溃史：bg_3049 时代链真 IDF modem_clock 实现崩 ROM——那是上下文实现
 * （modem_clock_context_t + refcount + hal dev 指针）裸机无初始化所致。
 * 本实现只做 **MMIO 写**，无任何上下文依赖。
 *
 * **为什么不能再 no-op（轮 123 根因实锤）**：blob controller task 主循环
 * （0x2f00fc00 IRAM，反汇编实证）每次事件处理前调
 * `e_btdm_lp_modem_clock_set(1)` → `modem_clock_module_enable(6)`。
 * no-op ⇒ BTMAC/BTBB/BT_APB/ETM/SEC/BLE_TIMER 数字时钟门**从未打开** ⇒
 * BB 引擎永久停摆 ⇒ 无 TX ⇒ synth 不锁 ⇒ 98BC 恒 0。模拟域（RF-ON
 * I2C burst）与数字域是两回事——"RF-ON burst 管 modem 电源域"只对模拟成立。
 *
 * 门位号（IDF reg 头交叉验证，porting.zig 90-125 同源）：
 *   clk_conf   (+0x04): etm=22, sec_ecb=25, sec_apb=28, sec=29, ble_timer=30
 *   clk_conf1  (+0x14): wifibb_44m=2, wifibb_80x1=7, wifi_apb=10,
 *                       bt_apb=16, btbb=17, btmac=18
 *   LPCON clk  (0x2010F000+0x18): coex=1
 *   SOC_PLL_SOURCE_CG: HP_SYS_CLKRST.modem_conf(0x205871E0)=0x3d（bringup 已写）
 * deps 定义：esp_hw_support/modem/port/esp32s31/modem_clock_impl.c:15-25。
 */
#include <stdint.h>
#include <stdbool.h>

#define MODEM_SYSCON_BASE 0x20109C00u
#define MODEM_LPCON_BASE  0x2010F000u
#define REG_CLK_CONF      (MODEM_SYSCON_BASE + 0x04)
#define REG_CLK_CONF1     (MODEM_SYSCON_BASE + 0x14)
#define REG_LPCON_CLK     (MODEM_LPCON_BASE + 0x18)
#define REG_HP_MODEM_CONF 0x205871E0u

static inline void mmio_or(uint32_t addr, uint32_t bits)
{
    *(volatile uint32_t *)addr |= bits;
}

/* domain 枚举值与 esp_private/esp_modem_clock.h 对齐（blob 调用点 0x400662da
 * 实证 BT 传 6；bringup mce(13) = PHY 校准）。签名两参是 light 变体口径，
 * blob 单参调用兼容（a1 为寄存器残留值，忽略）。 */
int modem_clock_module_enable(int domain, void *clk)
{
    (void)clk;
    switch (domain) {
    case 6: /* PERIPH_BT_MODULE —— BLE_CLOCK_DEPS 全开（宁可多开不少开） */
        mmio_or(REG_CLK_CONF1, (1u << 18) /* btmac(BLE_MAC) */
                | (1u << 17) /* btbb(BT_I154_COMMON_BB) */
                | (1u << 7) /* wifibb_80x1 */
                | (1u << 16) /* bt_apb(BT_APB) */);
        mmio_or(REG_CLK_CONF, (1u << 22) /* etm */
                | (1u << 28) /* sec_apb(BT_APB 第二门) */
                | (1u << 25) | (1u << 29) /* sec+ecb(BT_PERIPHERAL) */
                | (1u << 30) /* ble_timer(BT_PERIPHERAL) */);
        mmio_or(REG_LPCON_CLK, 1u << 1); /* coex */
        *(volatile uint32_t *)REG_HP_MODEM_CONF = 0x3d; /* SOC_PLL_SOURCE_CG */
        break;
    case 13: /* PERIPH_PHY_CALIBRATION —— WIFI_APB|BB_44M|BT_BB|BT_APB|SOC_PLL */
        mmio_or(REG_CLK_CONF1, (1u << 10) /* wifi_apb（bringup 事后清） */
                | (1u << 2) /* wifibb_44m */
                | (1u << 17) /* btbb */
                | (1u << 16) /* bt_apb */);
        mmio_or(REG_CLK_CONF, 1u << 28);
        *(volatile uint32_t *)REG_HP_MODEM_CONF = 0x3d;
        break;
    case 7: /* PERIPH_BT_APB_MODULE —— BT_APB|ETM|SOC_PLL|BLE_MAC */
        mmio_or(REG_CLK_CONF1, (1u << 16) | (1u << 18));
        mmio_or(REG_CLK_CONF, 1u << 22);
        *(volatile uint32_t *)REG_HP_MODEM_CONF = 0x3d;
        break;
    default:
        break;
    }
    return 0;
}
int modem_clock_module_disable(int domain, void *clk) { (void)domain; (void)clk; return 0; }

/* **轮 123f**：mac_reset 从 no-op 升级为寄存器直写（modem_syscon_ll_reset_bt
 * 同款：rst_btmac_apb=bit15、rst_btmac=bit16 各写 1 再写 0 脉冲复位）。
 * 官方 esp32c6/bt.c:1120-1121 顺序 = module_enable(PERIPH_BT_MODULE) 之后、
 * r_btdm_task_init 之前 ⇒ task_init 期 SCHED 页写入（1254/1258/11AC/100C）
 * 时门已开（advisor 数据链：oracle 9C14 与我们一字不差、唯一 BB 差 = 11AC）。 */
void modem_clock_module_mac_reset(int domain)
{
    (void)domain;
    volatile uint32_t *rst = (volatile uint32_t *)(MODEM_SYSCON_BASE + 0x10);
    *rst |= (1u << 15);
    *rst &= ~(1u << 15);
    *rst |= (1u << 16);
    *rst &= ~(1u << 16);
}
int wifi_bt_common_module_enable(int module) { (void)module; return 0; }
int wifi_bt_common_module_disable(int module) { (void)module; return 0; }
int phy_module_enable(int module, bool enable) { (void)module; (void)enable; return 0; }
int phy_module_disable(int module) { (void)module; return 0; }
bool phy_module_has_clock_bits(int module) { (void)module; return false; }
/* **轮 135**：pmu_init 恢复空桩（默认构建态）。真 pmu_init（pmu_init.c.obj +
 * pmu_param.c.obj 随 -Dphy-src-objs 追加）已实证：**裸机可执行至 F1 前块 GATE
 * 行**（较 bg_3049 崩 ROM 时代大幅前进 = PMU 移植可行性实证，r134b.log），但
 * 随后在 0x200A 发送路径内挂死（GATE 后 60s+ 全静默）——与 README 25238
 * item#2「pmu 后 flash 写静默失败 + FE 轮询挂」同族 = 独立课题。重新链入方法 =
 * 删本空桩 + -Dphy-src-objs 追加 esp_hw_support 的 pmu_init.c.obj,pmu_param.c.obj。 */
// 轮 148b：真 pmu 实验态（捕获窗 flash 环首次实跑：楔死 PC 经 0x1870_0100
// 通道落盘，esptool read_flash 读出 = 新等待面地址。空桩恢复 = 改回上一行）。
/* **轮 141 终判**：三因子（真 pmu_init 域上电 + mc0|=0x15 MODEM CLK/PLL +
 * UART 恢复）同测 = CTRL0 bit2/4 **写后仍读 0**（电源钳制假说也否，硬件级顽固）
 * + 流程照旧死于 0x200A。恢复空桩默认态。
 * r138a 先例：真 pmu + UART CTRL0 恢复 = 挂死根修 ✓（流程存活至 POSTPOLL）。 */
/* 轮 138 终判：真 pmu_init + UART CTRL0 恢复（r138a）= 挂死根修 ✓（流程全程
 * 存活至 POSTPOLL）但 **0x200A 无 CC**（evt 恒 6，0x1405=rc-3 LE 分发死）⇒
 * 控制器楔得更死（空桩态 = 全命令有 CC）。真 pmu 净效应 = 负 ×2 确认。
 * OTA 终验：5min 自跑无发射（扫描器对照 6 设备 ✓）。默认态 = 空桩。 */
