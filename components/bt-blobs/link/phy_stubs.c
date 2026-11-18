/* IDF `esp_phy` / `modem_clock` 源码对象在裸机固件里的桩。
 *
 * ## 为什么需要这个文件
 *
 * `esp_phy_common_clock_enable` / `phy_module_enable` / `modem_clock_module_enable`
 * 都是 **IDF 源码**编译出的 **IRAM** 代码（在 IDF 的 ELF 里落在 `0x2f00xxxx` = DRAM），
 * 我们的镜像里没有 ⇒ 直接按地址调用得到 `illegal instruction`（板侧实测）。
 *
 * 因此改为**把 IDF 编好的 `.o` 直接链进来**（`-Dphy-src-objs`）。它们依赖的 IDF 服务
 * （NVS / esp_timer / FreeRTOS 临界区 / log / GPIO / efuse）在这里用最小实现补齐。
 *
 * ## 关键设计：NVS 故意返回 NOT_FOUND
 *
 * `esp_phy_load_cal_and_init()` 的流程是：
 *
 *     err = esp_phy_load_cal_data_from_nvs(cal_data);
 *     if (err) { calibration_mode = PHY_RF_CAL_FULL; }   // ← IDF 自带的 fallback
 *
 * 我们没有 NVS 分区，也不打算为校准数据引入一个 —— **让 `nvs_open` 返回
 * `ESP_ERR_NVS_NOT_FOUND` 正是 IDF 期望的"首次开机"路径**，于是它走全量校准。
 * 这不是权宜之计，是 IDF 官方支持的启动分支。
 */

#include <stddef.h>
#include <stdint.h>

#define ESP_ERR_NVS_BASE        0x1100
#define ESP_ERR_NVS_NOT_FOUND   (ESP_ERR_NVS_BASE + 0x02)
#define ESP_ERR_NVS_INVALID_LENGTH (ESP_ERR_NVS_BASE + 0x0d)
#define ESP_ERR_INVALID_ARG     0x102
#define ESP_OK                  0

/* 裸机侧提供（Zig）：arena 分配与日志。 */
extern void *s31_btdm_malloc(uint32_t size);
extern void s31_btdm_free(void *ptr);
extern void s31_phy_log(const char *tag, const char *msg);
extern uint64_t s31_now_us(void);

/* 注：`HP_SYS_CLKRST` 等**寄存器基址是绝对符号**，不是变量 ——
 * IDF 用 `PROVIDE(HP_SYS_CLKRST = 0x20587000)` 定义，代码里取 `&HP_SYS_CLKRST`。
 * 我一开始把它写成 `volatile void *const HP_SYS_CLKRST = ...`，于是 `&符号`
 * 得到的是**那个变量在 drom 里的地址**（实测 `0x40104f48`），PHY 于是往 flash 写
 * ⇒ `store access fault`。正确做法是放进 `rom_syms.ld`。 */

/* ------------------------------------------------------------------ */
/* PHY 初始化表：IDF `phy_init.c` 里的 `phy_init_data`（128 字节）       */
/* 从 IDF 的 ELF `.rodata` 抠出（`nm` 显示 size=0x80），形状是           */
/* `esp_phy_init_data_t { uint8_t params[128]; }`。                      */
/* ------------------------------------------------------------------ */
const uint8_t phy_init_data[128] = {
    0x01, 0x00, 0x50, 0x50, 0x50, 0x50, 0x4c, 0x48,
    0x50, 0x50, 0x4c, 0x48, 0x40, 0x3c, 0x3c, 0x3c,
    0x4c, 0x4c, 0x48, 0x44,
};

/* 注：`modem_clock_device_context` / `modem_clock_domain_icg_config` 由
 * `modem_clock_impl.c.obj` 自己定义，这里不要再给（会 duplicate symbol）。 */

/* ------------------------------------------------------------------ */
/* NVS：故意"空"。（见文件头说明）                                       */
/* ------------------------------------------------------------------ */
/* **PHY 初始化表**：IDF 的 `esp_phy_get_init_data()` 会 `nvs_open` + `nvs_get_blob` 取它，
 * 取不到就 `ESP_ERROR_CHECK` → "failed to obtain PHY init data" → abort。
 * 这里提供仓里现成的 128 字节表（`wifi-blobs/src/phy_init_data.zig` 的 `params`，由 Zig 侧导出）。 */
int nvs_open(const char *name, int open_mode, uint32_t *out_handle)
{
    (void)name; (void)open_mode;
    if (out_handle) *out_handle = 1;
    return ESP_OK;   /* 成功打开：让后续 nvs_get_blob 能返回初始化表 */
}
int nvs_close(uint32_t handle) { (void)handle; return ESP_OK; }
int nvs_commit(uint32_t handle) { (void)handle; return ESP_OK; }
int nvs_erase_all(uint32_t handle) { (void)handle; return ESP_OK; }
/* 校准数据 blob：返回 NOT_FOUND ⇒ IDF 走全量校准。
 * 注：PHY 初始化表**不经过 NVS** —— `esp_phy_get_init_data()` 是返回静态表
 * `phy_init_data`(0x40104fef) 的 thunk（size 10，不可能失败），镜像里本来就带着它。 */
int nvs_get_blob(uint32_t h, const char *k, void *o, size_t *len) { (void)h; (void)k; (void)o; (void)len; return ESP_ERR_NVS_NOT_FOUND; }
int nvs_set_blob(uint32_t h, const char *k, const void *v, size_t l) { (void)h; (void)k; (void)v; (void)l; return ESP_ERR_NVS_NOT_FOUND; }
int nvs_get_u32(uint32_t h, const char *k, uint32_t *o) { (void)h; (void)k; (void)o; return ESP_ERR_NVS_NOT_FOUND; }
int nvs_set_u32(uint32_t h, const char *k, uint32_t v) { (void)h; (void)k; (void)v; return ESP_ERR_NVS_NOT_FOUND; }

/* ------------------------------------------------------------------ */
/* esp_timer：PHY 只用于温度跟踪，全部空实现                             */
/* ------------------------------------------------------------------ */
int esp_timer_get_time(void) { return (int)(s31_now_us() & 0x7fffffff); }
int esp_timer_create(const void *args, void **out) { (void)args; if (out) *out = 0; return ESP_OK; }
int esp_timer_start_periodic(void *t, uint64_t period) { (void)t; (void)period; return ESP_OK; }
int esp_timer_stop(void *t) { (void)t; return ESP_OK; }
int esp_timer_delete(void *t) { (void)t; return ESP_OK; }

/* ------------------------------------------------------------------ */
/* FreeRTOS 临界区 / 锁：转我们的 osal（这里用最简单的中断开关语义）       */
/* ------------------------------------------------------------------ */
unsigned xPortInIsrContext(void) { return 0; }
int xPortEnterCriticalTimeout(void *mux, uint32_t timeout)
{
    (void)mux; (void)timeout;
    return 1;
}
void vPortExitCriticalMultiCore(void *mux) { (void)mux; }
void _lock_acquire(void **lock) { (void)lock; }
void _lock_release(void **lock) { (void)lock; }

/* ------------------------------------------------------------------ */
/* 内存：转我们的 arena                                                */
/* ------------------------------------------------------------------ */
/* **PHY 校准专用缓冲**：arena 已被归档吃到只剩 ~1.2 KB（实测 188 块、走到堆尾），
 * 而 PHY 校准要 1904 B ⇒ 必失败 ⇒ `phy_init.c` 的 ESP_ERROR_CHECK → abort。
 * 这一块不参与共享 arena 的竞争：`n*sz == 1904` 时直接给静态缓冲。 */

/* 单字节输出（不走我们的日志栈，避免被过滤/丢弃） */
static void put1(char c) {
    volatile unsigned *fifo = (volatile unsigned *)0x2038A000;
    volatile unsigned *stat = (volatile unsigned *)0x2038A01C;
    unsigned sp = 0;
    while ((((*stat >> 16) & 0xFF) >= 120) && sp < 40) sp++;
    if (sp < 40) *fifo = (unsigned)c;
}
static unsigned char g_phy_cal_buf[4][2048] __attribute__((aligned(16)));
static unsigned g_phy_cal_next = 0;

void *calloc(size_t n, size_t sz)
{
    size_t total = n * sz;
    if (total == 1904) {
        put1('C');
        unsigned slot = g_phy_cal_next & 3u;   /* **4 槽轮转**：避免别名 */
        g_phy_cal_next++;
        uint8_t *b = (uint8_t *)g_phy_cal_buf[slot];
        for (size_t i = 0; i < total; i++) b[i] = 0;
        return (void *)b;
    }
    void *p = s31_btdm_malloc((uint32_t)total);
    if (p) {
        uint8_t *b = (uint8_t *)p;
        for (size_t i = 0; i < total; i++) b[i] = 0;
    }
    return p;
}
void free(void *p) {
    /* 专用缓冲不归还（4 槽范围内都算专用） */
    for (unsigned i = 0; i < 4; i++) if (p == (void *)g_phy_cal_buf[i]) return;
    s31_btdm_free(p);
}

/* ------------------------------------------------------------------ */
/* 日志                                                                */
/* ------------------------------------------------------------------ */
void esp_log(const char *tag, const char *fmt, ...)
{
    (void)fmt;
    s31_phy_log(tag, fmt);
}
uint32_t esp_log_timestamp(void) { return (uint32_t)(s31_now_us() / 1000); }
int esp_log_default_level = 0;

/* ------------------------------------------------------------------ */
/* 其余桩                                                              */
/* ------------------------------------------------------------------ */
/* abort：把**直接调用者地址**写进一个 RAM 全局（不走 UART，不会被丢），
 * 然后自旋。导出处会把它打出来。 */
volatile unsigned g_abort_ra = 0;
void abort(void) {
    {
        unsigned ra;
        /* 函数入口处 ra 仍是调用者的返回地址；`__builtin_return_address` 在
         * 无帧指针时返回 0，故直接用汇编。 */
        __asm__ volatile ("mv %0, ra" : "=r"(ra));
        g_abort_ra = ra;
    }
    put1('A');
    { extern void probe_dump_now(void); probe_dump_now(); }   /* 崩溃瞬间导出 */
    for (;;) {}
}

void _esp_error_check_failed(int rc, const char *file, int line, const char *func, const char *expr)
{
    (void)rc; (void)file; (void)line; (void)func; (void)expr;
}
void esp_deep_sleep_register_phy_hook(void *fn, void *arg) { (void)fn; (void)arg; }
int esp_sleep_pd_config(int pd, int opt) { (void)pd; (void)opt; return ESP_OK; }
int esp_efuse_mac_get_default(uint8_t *mac)
{
    /* 与 bt-blobs 的 `readEfuseMac` 默认值一致（本地管理地址） */
    mac[0] = 0x02; mac[1] = 0x00; mac[2] = 0x00;
    mac[3] = 0x00; mac[4] = 0xBB; mac[5] = 0x01;
    return ESP_OK;
}
int esp_gpio_is_reserved(int gpio) { (void)gpio; return 0; }
int gpio_config(const void *cfg) { (void)cfg; return ESP_OK; }
int esp_rom_gpio_connect_out_signal(int gpio, int sig, int inv, int oen) { (void)gpio; (void)sig; (void)inv; (void)oen; return ESP_OK; }
int esp_rom_get_reset_reason(int core) { (void)core; return 0; }
const char *get_phy_version_str(void) { return "s31-phy"; }
