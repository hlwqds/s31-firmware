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

/* modem 时钟域枚举与 esp_private/esp_modem_clock.h 对齐；裸机只认 no-op，
 * 用 int 擦掉枚举依赖。 */
int modem_clock_module_enable(int domain, void *clk) { (void)domain; (void)clk; return 0; }
int modem_clock_module_disable(int domain, void *clk) { (void)domain; (void)clk; return 0; }
void modem_clock_module_mac_reset(int domain) { (void)domain; }
int wifi_bt_common_module_enable(int module) { (void)module; return 0; }
int wifi_bt_common_module_disable(int module) { (void)module; return 0; }
int phy_module_enable(int module, bool enable) { (void)module; (void)enable; return 0; }
int phy_module_disable(int module) { (void)module; return 0; }
bool phy_module_has_clock_bits(int module) { (void)module; return false; }
void pmu_init(void) {}
