//! WiFi/BT 闭包最小桩——budding blob 引用的 esp-idf 系统符号最小供给。
//! 每个桩仅返回成功/零值，保证链接通过；行为语义待逐项验证。
long long esp_timer_get_time(void) {
    // 2026-11-20 晚二转：饱和实验（钳 999_999）已完成判别使命——旧"PLL-track
    // regi2c 卡死"实为 deep_sleep_register_phy_hook 桩签名自循环的误读。现还原
    // 递增时钟（每调用 +1ms）：phy_track_pll_internal 会真正跑 regi2c PLL 跟踪，
    // 这正是合成器锁定（0x201098BC.bit2）与空中辐射可能缺的最后一步。
    // 若 phy_track_pll 再成卡点 ⇒ regi2c 停滞为真，交给 FE 仪器链。
    static unsigned long long t;
    return (long long)(t += 1000); // 每次调用 +1ms，避免"永不超时"或天文数字
}
int esp_timer_create(const void *a, void **o) { (void)a; (void)o; return 0; }
int esp_timer_start_periodic(void *t, unsigned long long p) { (void)t; (void)p; return 0; }
int esp_timer_stop(void *t) { (void)t; return 0; }
int esp_timer_delete(void *t) { (void)t; return 0; }
unsigned xPortInIsrContext(void) { return 0; }
int xPortEnterCriticalTimeout(void *m, unsigned int t) { (void)m; (void)t; return 0; }
void vPortExitCriticalMultiCore(void *m) { (void)m; }
void __assert_func(const char *f, int l, const char *fn, const char *e) { (void)f;(void)l;(void)fn;(void)e; }
void esp_rom_gpio_connect_in_signal(int a, int b, int c, int d) { (void)a;(void)b;(void)c;(void)d; }
void esp_rom_output_tx_wait_idle(int u) { (void)u; }
void esp_rom_route_intr_matrix(int a, int b, int c) { (void)a;(void)b;(void)c; }
void esp_rom_software_reset_system(void) { }
int esp_set_time_from_rtc(void) { return 0; }
void esp_sync_timekeeping_timers(void) { }
void esprv_int_disable(int x) { (void)x; }
void esprv_int_enable(int x) { (void)x; }
void esprv_int_set_priority(int a, int b) { (void)a;(void)b; }
void esprv_int_set_threshold(int a) { (void)a; }
int esprv_int_set_type(int a, int b) { (void)a;(void)b; return 0; }
void _esp_error_check_failed(int rc, const char *file, int line, const char *func, const char *expr) {
    // ⚠ 本桩曾被写成"直接返回"——ESP_ERROR_CHECK 失败后执行从失败块的 jal
    // 落到链接器排在其后的下一个函数入口（本轮恰好是 esp_phy_enable），
    // 制造出整场五轮判读都在解的幽灵自循环。现镜像 abort 桩：记录 rc+ra、
    // 落盘、原地自旋——失败必须可见，不得静默跌落。
    volatile extern unsigned g_esperr_rc;
    volatile extern unsigned g_esperr_ra;
    extern unsigned g_flag_a;
    g_esperr_rc = (unsigned)rc;
    __asm__ volatile ("mv %0, ra" : "=r"(g_esperr_ra));
    g_flag_a = 2;
    { extern void probe_dump_now(void); probe_dump_now(); }
    for (;;) {}
}
volatile unsigned g_esperr_rc = 0;
volatile unsigned g_esperr_ra = 0;
// ⚠ IDF 原型 = esp_err_t esp_deep_sleep_register_phy_hook(handler)——**1 参、返回
// esp_err_t**。曾写成 (fn,arg) 返回 void ⇒ a0 残留垃圾 ⇒ phy_init.c:985/989 的
// ESP_ERROR_CHECK 判失败 ⇒ 失败块 jal 的返回地址恰好落在 esp_phy_enable 入口
// ⇒ 跌落进 esp_phy_enable 后 ret 又回到同一入口 = 无限自循环（load_cal 永不返回）。
int esp_deep_sleep_register_phy_hook(void *fn) { (void)fn; return 0; }
int esp_efuse_mac_get_default(unsigned char *mac) { mac[0]=0x02;mac[1]=0x00;mac[2]=0x00;mac[3]=0x00;mac[4]=0xBB;mac[5]=0x01; return 0; }
int esp_gpio_is_reserved(int gpio) { (void)gpio; return 0; }
void esp_log(const char *tag, const char *fmt, ...) { (void)tag;(void)fmt; }
unsigned int esp_log_timestamp(void) { return 0; }
int esp_sleep_pd_config(int pd, int opt) { (void)pd;(void)opt; return 0; }
const char *get_phy_version_str(void) { return "s31-probe"; }
int gpio_config(const void *cfg) { (void)cfg; return 0; }
const unsigned char phy_init_data[144] = { 0x02, 0x00, 0x00, 0x00, 0xB4, 0x00, 0x00, 0x00, 0x9C, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
void phy_printf(unsigned int level, const char *tag, const char *format, ...) { (void)level;(void)tag;(void)format; }
int rtc_clk_xtal_freq_get(void) { return 40; }
void s31_printf_hook(unsigned int level, const char *tag, const char *format, ...) { (void)level;(void)tag;(void)format; }
