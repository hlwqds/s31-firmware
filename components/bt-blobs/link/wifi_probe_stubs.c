//! WiFi/BT 闭包最小桩——budding blob 引用的 esp-idf 系统符号最小供给。
//! 每个桩仅返回成功/零值，保证链接通过；行为语义待逐项验证。
long long esp_timer_get_time(void) {
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
void _esp_error_check_failed(int rc, const char *file, int line, const char *func, const char *expr) { (void)rc;(void)file;(void)line;(void)func;(void)expr; }
void esp_deep_sleep_register_phy_hook(void *fn, void *arg) { (void)fn;(void)arg; }
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
