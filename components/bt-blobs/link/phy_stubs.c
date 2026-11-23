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
/* **修正（2026-11-19）**：vendor `phy_init.c` 按完整布局解读 `phy_init_data` 符号：
 *   phy_init_magic_pre("PHYINIT\0"，8B) + params[128] + phy_init_magic_post("PHYINIT\0"，8B)
 * 此前我们只给了 128B 裸参数 ⇒ vendor 读到的参数全错位 ⇒ RF 参数损坏 ⇒ 合成器不锁。
 * 布局依据：esp_phy/esp32s31/phy_init_data.c:14/150 与官方 map 里
 * `libesp_phy.a(phy_init.c.obj) (phy_init_data)` 的直接符号引用。 */
/* phy_init_data 表已由 libesp_phy.a(phy_init_data.c.obj) 提供 ⇒ 移除本表副本（重复符号）*/

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
/* ------------------------------------------------------------------ */
/* FreeRTOS 临界区 / 锁：转我们的 osal（这里用最简单的中断开关语义）       */
/* ------------------------------------------------------------------ */
void _lock_acquire(void **lock) { (void)lock; }
void _lock_release(void **lock) { (void)lock; }
/* **轮 118**：WithPHY=1 链入 sar_periph/rts objs 后新增引用；IDF locks.c.obj 的
 * 真身会与本文件上面两条空桩强冲突，这里补齐同语义空桩（裸机无竞争 ⇒ 恒成功）。 */
int _lock_try_acquire(void **lock) { (void)lock; return 1; }

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
unsigned g_flag_a = 0;
unsigned g_posctl = 0;
volatile unsigned g_abort_ra = 0;
unsigned g_c_count = 0;
extern unsigned char _phy_cal_buf_start[];   /* 精确计数（RAM，不受 FIFO 丢字节影响） */
static unsigned char g_phy_cal_buf[4][2048] __attribute__((aligned(16)));
static unsigned g_phy_cal_next = 0;

void *calloc(size_t n, size_t sz)
{
    /* 阳性对照已完成：见 README；此处保持空实现，避免干扰正常运行。 */
    size_t total = n * sz;
    /* **校准缓冲走独立段**（`.phy_cal_buf`，不在 arena 内）：
     * 归档 init 会吃光 arena（实测只剩 712 B），校准则需要 1904 B —— 两者不能共存。 */
    if (total == 1904) {
        unsigned char *const base = (unsigned char *)_phy_cal_buf_start;
        g_c_count++;
        for (size_t i = 0; i < total; i++) base[i] = 0;
        return base;
    }
    void *p = s31_btdm_malloc((uint32_t)total);
    if (p) {
        uint8_t *b = (uint8_t *)p;
        for (size_t i = 0; i < total; i++) b[i] = 0;
    }
    return p;
}
void free(void *p) {
    if (p == (void *)_phy_cal_buf_start) return;   /* 专用段不归还 */
    /* 专用缓冲不归还（4 槽范围内都算专用） */
    for (unsigned i = 0; i < 4; i++) if (p == (void *)g_phy_cal_buf[i]) return;
    s31_btdm_free(p);
}

/* ------------------------------------------------------------------ */
/* 日志（esp_log_timestamp/esp_log 由 liblog.a 提供 ⇒ 移除本桩）        */
/* ------------------------------------------------------------------ */
/* ------------------------------------------------------------------ */
/* 其余桩                                                              */
/* ------------------------------------------------------------------ */
/* abort：把**直接调用者地址**写进一个 RAM 全局（不走 UART，不会被丢），
 * 然后自旋。导出处会把它打出来。 */
void abort(void) {
    {
        unsigned ra;
        /* 函数入口处 ra 仍是调用者的返回地址；`__builtin_return_address` 在
         * 无帧指针时返回 0，故直接用汇编。 */
        __asm__ volatile ("mv %0, ra" : "=r"(ra));
        g_abort_ra = ra;
    }
    g_flag_a = 1;
    { extern void probe_dump_now(void); probe_dump_now(); }   /* 崩溃瞬间导出 */
    for (;;) {}
}

int esp_rom_gpio_connect_out_signal(int gpio, int sig, int inv, int oen) { (void)gpio; (void)sig; (void)inv; (void)oen; return ESP_OK; }
int esp_rom_get_reset_reason(int core) { (void)core; return 0; }

/* ------------------------------------------------------------------ */
/* **轮 118**：WithPHY=1 obj 闭包（sar_periph/rtc_module/tsens_hal）引用的
 * log 后端钩子。裸机路径 phy_printf 已由 wifi_probe_stubs 转发 raw-line，
 * 这些 cache/level 钩子空实现即可（IDF 语义：cache 未启用时直接落地）。 */
/* ------------------------------------------------------------------ */
int esp_log_default_level = 3;
uint32_t esp_log_level_get_timeout(const char *tag) { (void)tag; return 3; }
void esp_log_cache_add(unsigned int level, const char *tag) { (void)level; (void)tag; }
void esp_log_cache_clean(void) {}
uint32_t esp_log_cache_get_level(void) { return 3; }
void esp_log_cache_set_level(uint32_t level) { (void)level; }
void esp_log_impl_lock(void) {}
void esp_log_impl_unlock(void) {}
int esp_log_impl_lock_timeout(void) { return 1; }
