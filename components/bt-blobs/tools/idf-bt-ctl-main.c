// [host-side annotation] instrumented copy of the official idf-bt-ctl main.c:
// FE cluster 9-reg sampler (fe_sampler_task/fe_ring_dump) for official-vs-probe
// register reconciliation. Reference only, not built here.
// 对照实验：Espressif 官方 IDF 在这块板上 init/enable BLE 会不会卡？
// 每秒打一行心跳，卡住时最后一行就是卡点。
#include <stdio.h>
#include <stddef.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_bt.h"
#include "btdm_osal.h"
#include "btdm_log.h"
#include "btdm_external.h"
#include "btdm_coex.h"
#include "btdm_lp.h"
#include "esp_system.h"
#include "soc/hp_sys_clkrst_reg.h"

// 把"成功路径"上的关键寄存器读出来，作为对照基准
static void dump_regs(const char *when)
{
    uint32_t modem_ctrl0 = REG_READ(HP_SYS_CLKRST_MODEM_CTRL0_REG);
    uint32_t modem_conf  = REG_READ(HP_SYS_CLKRST_MODEM_CONF_REG);
    uint32_t clk_en0     = REG_READ(HP_SYS_CLKRST_CLK_EN0_REG);
    ESP_LOGW("idfbt", "[%s] MODEM_CTRL0=0x%08x MODEM_CONF=0x%08x CLK_EN0=0x%08x",
             when, (unsigned)modem_ctrl0, (unsigned)modem_conf, (unsigned)clk_en0);
    // modem syscon 窗口全量（0x20109C00 起 16 个字）
    for (int i = 0; i < 16; i++) {
        volatile uint32_t *r = (volatile uint32_t *)(0x20109C00u + i * 4);
        ESP_LOGW("idfbt", "[%s] syscon+0x%02x = 0x%08x", when, i * 4, (unsigned)*r);
    }
    // hp_sys_clkrst 窗口（0x20587000 起 0x200 字节）
    for (int i = 0; i < 128; i++) {
        volatile uint32_t *r = (volatile uint32_t *)(0x20587000u + i * 4);
        uint32_t v = *r;
        if (v) ESP_LOGW("oracle", "clkrst+0x%03x = 0x%08x", i * 4, (unsigned)v);
    }
    // 直接探一下那个块：若 IDF 状态下读得到，就说明我们缺的是某条使能
    volatile uint32_t *probe = (volatile uint32_t *)0x2010B000u;
    uint32_t v = *probe;
    ESP_LOGW("idfbt", "[%s] *(0x2010B000)=0x%08x  -> READABLE", when, (unsigned)v);
}

static const char *TAG = "idfbt";

// 10 个 per-object 锚点（与板侧实测同一批）
extern uint32_t r_sym_bt_pSy5Wex1v0iXw5RdWtwL;
extern uint32_t r_sym_bt_WDq2rzn4KRWP5mort5eS;
extern uint32_t r_sym_bt_YnZmsxu068uuC3PC4iu8;
extern uint32_t r_sym_bt_kfu8vf8dQgqwEzvqhb3d;
extern uint32_t r_sym_bt_d3D3sk5KewclELfrD5xa;
extern uint32_t r_sym_bt_sitBB3SrXn0IePgsPrBY;
extern uint32_t r_sym_bt_r4auAKWSAFwgQarMHZCc;
extern uint32_t r_sym_bt_lRdavKxt45o0gicEyznn;
extern uint32_t r_sym_bt_6Q68KSwuQQP4VjQGqiWa;
extern uint32_t r_sym_bt_y5Dip5N8bwiiGRcrWzBO;

static void dump_anchor_table(const char *when)
{
    ESP_LOGW("ANCHOR_TABLE", "== %s ==", when);
    ESP_LOGW("ANCHOR_TABLE", "  [0] pSy5Wex1v0iXw5RdWtwL = 0x%08x", (unsigned)r_sym_bt_pSy5Wex1v0iXw5RdWtwL);
    ESP_LOGW("ANCHOR_TABLE", "  [1] WDq2rzn4KRWP5mort5eS = 0x%08x", (unsigned)r_sym_bt_WDq2rzn4KRWP5mort5eS);
    ESP_LOGW("ANCHOR_TABLE", "  [2] YnZmsxu068uuC3PC4iu8 = 0x%08x", (unsigned)r_sym_bt_YnZmsxu068uuC3PC4iu8);
    ESP_LOGW("ANCHOR_TABLE", "  [3] kfu8vf8dQgqwEzvqhb3d = 0x%08x", (unsigned)r_sym_bt_kfu8vf8dQgqwEzvqhb3d);
    ESP_LOGW("ANCHOR_TABLE", "  [4] d3D3sk5KewclELfrD5xa = 0x%08x", (unsigned)r_sym_bt_d3D3sk5KewclELfrD5xa);
    ESP_LOGW("ANCHOR_TABLE", "  [5] sitBB3SrXn0IePgsPrBY = 0x%08x", (unsigned)r_sym_bt_sitBB3SrXn0IePgsPrBY);
    ESP_LOGW("ANCHOR_TABLE", "  [6] r4auAKWSAFwgQarMHZCc = 0x%08x", (unsigned)r_sym_bt_r4auAKWSAFwgQarMHZCc);
    ESP_LOGW("ANCHOR_TABLE", "  [7] lRdavKxt45o0gicEyznn = 0x%08x", (unsigned)r_sym_bt_lRdavKxt45o0gicEyznn);
    ESP_LOGW("ANCHOR_TABLE", "  [8] 6Q68KSwuQQP4VjQGqiWa = 0x%08x", (unsigned)r_sym_bt_6Q68KSwuQQP4VjQGqiWa);
    ESP_LOGW("ANCHOR_TABLE", "  [9] y5Dip5N8bwiiGRcrWzBO = 0x%08x", (unsigned)r_sym_bt_y5Dip5N8bwiiGRcrWzBO);
}

// 归档里的两个锚点全局（libbtdm_common）。oracle 链的是同一个归档 ⇒ 符号必然存在。
extern uint32_t r_sym_bt_r4auAKWSAFwgQarMHZCc;   // OkE7 的守卫锚点
extern uint32_t r_sym_bt_d3D3sk5KewclELfrD5xa;   // Xpuq 用的 P

extern uint32_t r_sym_bt_r4auAKWSAFwgQarMHZCc;
extern uint32_t r_sym_bt_d3D3sk5KewclELfrD5xa;
extern uint32_t r_sym_bt_6Q68KSwuQQP4VjQGqiWa;   // 7.o：BOhff 的守卫
extern int ble_osal_elem_calc(void *cfg, btdm_osal_elem_num_t *elem);
extern int btdm_osal_elem_mempool_init(btdm_osal_elem_num_t *elem);

// 逐步复刻 bt.c 的 init 序列，每步后打三个锚点 —— 确定性定位"谁发布谁"
// **全 modem 区扫描**：按 64 字节块做 FNV 哈希，只报变化的块，
// 覆盖 `0x20100000..0x2010FFFF`（modem）与 `0x20587000..0x20587FFF`（HP_SYS_CLKRST）。
#define SCAN_N 1024
static uint32_t scan_base[2] = {0x20100000u, 0x20587000u};
static uint32_t scan_hash[2][SCAN_N];

static uint32_t fnv_block(uint32_t base, int i)
{
    uint32_t h = 2166136261u;
    for (int k = 0; k < 16; k++) {
        uint32_t v = *(volatile uint32_t *)(base + i * 64u + k * 4u);
        h = (h ^ v) * 16777619u;
    }
    return h;
}

static bool scan_skip(int slot, int i)
{
    // `0x2010B000..0x2010BFFF` 在 init 前**不可访问**，扫到它就挂死 ⇒ 必须跳过
    uint32_t a = scan_base[slot] + i * 64u;
    return (slot == 0) && (a >= 0x2010B000u) && (a < 0x2010C000u);
}

static void scan_snap(int slot)
{
    for (int i = 0; i < SCAN_N; i++)
        scan_hash[slot][i] = scan_skip(slot, i) ? 0 : fnv_block(scan_base[slot], i);
}

static void scan_diff(int slot, const char *tag)
{
    for (int i = 0; i < SCAN_N; i++) {
        if (scan_skip(slot, i)) continue;
        uint32_t h = fnv_block(scan_base[slot], i);
        if (h != scan_hash[slot][i]) {
            ESP_LOGW("SCAN", "%s changed at 0x%08x:", tag, scan_base[slot] + i * 64u);
            for (int k = 0; k < 16; k++)
                ESP_LOGW("SCAN", "   +0x%02x = 0x%08x", k * 4,
                         (unsigned)*(volatile uint32_t *)(scan_base[slot] + i * 64u + k * 4u));
        }
    }
}

// IDF 默认 cfg.btdm 逐字段（我们要照它对齐）
static void cfg_dump(void)
{
    esp_bt_controller_config_t c = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_LOGW("cfg_dump", "SIZEOF esp_btdm_controller_config_t=%u  version@%u stack@%u prio@%u cpu@%u hci_cmd@%u hci_conn@%u sleep@%u vnum@%u mode@%u magic@%u",
             (unsigned)sizeof(esp_btdm_controller_config_t),
             (unsigned)offsetof(esp_btdm_controller_config_t, version),
             (unsigned)offsetof(esp_btdm_controller_config_t, task_stack_size),
             (unsigned)offsetof(esp_btdm_controller_config_t, task_prio),
             (unsigned)offsetof(esp_btdm_controller_config_t, task_run_cpu),
             (unsigned)offsetof(esp_btdm_controller_config_t, hci_cmd_num),
             (unsigned)offsetof(esp_btdm_controller_config_t, hci_conn_num),
             (unsigned)offsetof(esp_btdm_controller_config_t, sleep_en),
             (unsigned)offsetof(esp_btdm_controller_config_t, version_num),
             (unsigned)offsetof(esp_btdm_controller_config_t, bluetooth_mode),
             (unsigned)offsetof(esp_btdm_controller_config_t, magic));
    {
        const uint8_t *b = (const uint8_t *)&c;
        for (size_t i = 0; i < sizeof(esp_bt_controller_config_t); i += 32) {
            char line[200]; int n = 0;
            n += snprintf(line + n, sizeof(line) - n, "HEXDUMP +%03u:", (unsigned)i);
            for (size_t j = i; j < i + 32 && j < sizeof(esp_bt_controller_config_t); j++)
                n += snprintf(line + n, sizeof(line) - n, " %02x", b[j]);
            ESP_LOGW("cfg_dump", "%s", line);
        }
    }
    ESP_LOGW("cfg_dump", "version=0x%08x stack=%u prio=%u cpu=%u hci_cmd=%u hci_conn=%u sleep=%u vnum=%u mode=%u magic=0x%08x",
             (unsigned)c.btdm.version, (unsigned)c.btdm.task_stack_size, (unsigned)c.btdm.task_prio,
             (unsigned)c.btdm.task_run_cpu, (unsigned)c.btdm.hci_cmd_num, (unsigned)c.btdm.hci_conn_num,
             (unsigned)c.btdm.sleep_en, (unsigned)c.btdm.version_num, (unsigned)c.btdm.bluetooth_mode,
             (unsigned)c.btdm.magic);
}

static void step_by_step(void)
{
    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    btdm_osal_elem_num_t elem = { 3 + 100, 1 + 2, 0 + 10, 0, 1 };
    ble_osal_elem_calc(&cfg, &elem);
#define DUMP(tag) ESP_LOGW("stepbystep", tag " a21=0x%08x a2=0x%08x a7=0x%08x", \
        (unsigned)r_sym_bt_r4auAKWSAFwgQarMHZCc, (unsigned)r_sym_bt_d3D3sk5KewclELfrD5xa, \
        (unsigned)r_sym_bt_6Q68KSwuQQP4VjQGqiWa)
    cfg_dump();
    DUMP("boot        ");
    int rc = btdm_osal_elem_mempool_init(&elem); DUMP("elem_mempool"); ESP_LOGW("stepbystep", "  rc=%d", rc);

    rc = btdm_log_init();                        DUMP("log_init    "); ESP_LOGW("stepbystep", "  rc=%d", rc);
    rc = btdm_external_init();                   DUMP("external    "); ESP_LOGW("stepbystep", "  rc=%d", rc);
    rc = btdm_coex_init();                       DUMP("coex_init   "); ESP_LOGW("stepbystep", "  rc=%d", rc);
    scan_snap(0); scan_snap(1);
    // **step 5 之前的快照**：与 step 5 之后的同名 dump 相减 = IDF 这一步的全部写
    {
        static const struct { const char *n; unsigned base; int cnt; } w2[] = {
            {"syscon", 0x20109C00u, 16}, {"lpcon", 0x2010F000u, 16},
            {"pwr", 0x2010D000u, 16}, {"clkrst", 0x20587000u, 32},
        };
        for (unsigned k = 0; k < sizeof(w2)/sizeof(w2[0]); k++)
            for (int i = 0; i < w2[k].cnt; i++)
                ESP_LOGW("WIN_BEFORE", "%s +0x%03x = 0x%08x", w2[k].n, i*4, (unsigned)*(volatile uint32_t *)(w2[k].base + i*4));
    }
    ESP_LOGW("lpcon", "== after step4 ==");
    for (int i = 0; i < 16; i++)
        ESP_LOGW("lpcon", "  +0x%02x = 0x%08x", i * 4, (unsigned)*(volatile uint32_t *)(0x2010F000u + i * 4));
    btdm_lp_enable_clock(&cfg.btdm);              DUMP("lp_clock    ");
    scan_diff(0, "step5/modem"); scan_diff(1, "step5/clkrst");
    ESP_LOGW("lpcon", "== after step5 ==");
    for (int i = 0; i < 16; i++)
        ESP_LOGW("lpcon", "  +0x%02x = 0x%08x", i * 4, (unsigned)*(volatile uint32_t *)(0x2010F000u + i * 4));
    // **四窗口（step 5 之后）** —— 与我们板侧同点 dump 逐字对拍
    {
        static const struct { const char *n; unsigned base; int cnt; } wins[] = {
            {"syscon", 0x20109C00u, 16}, {"lpcon", 0x2010F000u, 16},
            {"pwr", 0x2010D000u, 16}, {"clkrst", 0x20587000u, 32},
        };
        for (unsigned k = 0; k < sizeof(wins)/sizeof(wins[0]); k++)
            for (int i = 0; i < wins[k].cnt; i++) {
                uint32_t v = *(volatile uint32_t *)(wins[k].base + i * 4);
                if (v) ESP_LOGW("WIN_AFTER", "%s +0x%03x = 0x%08x", wins[k].n, i * 4, (unsigned)v);
            }
    }
    ESP_LOGW("block_probe", "probe after step5 ...");
    { volatile uint32_t *bp2 = (volatile uint32_t *)0x2010B000u;
      ESP_LOGW("block_probe", "after step5: 0x2010B000 = 0x%08x", (unsigned)*bp2); }
#undef DUMP
}

static void dump_anchors(const char *when)
{
    uint32_t a = r_sym_bt_r4auAKWSAFwgQarMHZCc;
    uint32_t a7 = r_sym_bt_6Q68KSwuQQP4VjQGqiWa;
    uint32_t p = r_sym_bt_d3D3sk5KewclELfrD5xa;
    uint32_t plus8 = 0;
    if (a) plus8 = *(volatile uint32_t *)(uintptr_t)(a + 8);
    ESP_LOGW("idfbt", "[%s] a21=0x%08x (*(+8)=0x%08x)  a2=0x%08x  **a7=0x%08x**",
             when, (unsigned)a, (unsigned)plus8, (unsigned)p, (unsigned)a7);
    if (a) {
        for (int i = 0; i < 8; i++)
            ESP_LOGW("oracle", "X[%d]=0x%08x", i, (unsigned)*(volatile uint32_t *)(uintptr_t)(a + i * 4));
    }
    if (plus8) {
        for (int i = 0; i < 8; i++)
            ESP_LOGW("oracle", "Y[%d]=0x%08x", i, (unsigned)*(volatile uint32_t *)(uintptr_t)(plus8 + i * 4));
    }
}

static void dump_boot_state(void)
{
    static const struct { const char *n; unsigned base; int cnt; } w3[] = {
        {"syscon", 0x20109C00u, 16}, {"lpcon", 0x2010F000u, 16},
        {"pwr", 0x2010D000u, 16}, {"clkrst", 0x20587000u, 32},
    };
    for (unsigned k = 0; k < sizeof(w3)/sizeof(w3[0]); k++)
        for (int i = 0; i < w3[k].cnt; i++) {
            uint32_t v = *(volatile uint32_t *)(w3[k].base + i*4);
            if (v) ESP_LOGW("BOOTSTATE", "%s +0x%03x = 0x%08x", w3[k].n, i*4, (unsigned)v);
        }
}


// ---- FE 环同簇九寄存器采样（官方侧对账；450=轮询计数器，cap 0x10000） ----
#define FE_RING_N 512
static struct { uint32_t v[9]; unsigned tag; } fe_ring[FE_RING_N];
static volatile unsigned fe_ring_wr;
static volatile int fe_ring_on;

static uint32_t fe_r(unsigned off) { return *(volatile uint32_t *)(0x20100000u + off); }

static void fe_sampler_task(void *arg)
{
    (void)arg;
    uint32_t last[7] = {0xFFFFFFFFu,0xFFFFFFFFu,0xFFFFFFFFu,0xFFFFFFFFu,0xFFFFFFFFu,0xFFFFFFFFu,0xFFFFFFFFu};
    unsigned beat = 0;
    for (;;) {
        if (fe_ring_on && fe_ring_wr < FE_RING_N) {
            uint32_t cur[7] = { fe_r(0x408), fe_r(0x40C), fe_r(0x41C), fe_r(0x420), fe_r(0x444), fe_r(0x450), fe_r(0x47C) };
            int changed = 0;
            for (int k = 0; k < 7; k++) if (cur[k] != last[k]) changed = 1;
            int beat_line = (++beat % 500 == 0); // ~100ms 心跳
            if (changed || beat_line) {
                unsigned w = fe_ring_wr++;
                for (int k = 0; k < 7; k++) fe_ring[w].v[k] = cur[k];
                fe_ring[w].v[7] = fe_r(0x8D0);
                fe_ring[w].v[8] = fe_r(0x11AC);
                fe_ring[w].tag = changed ? 1 : 2; // 1=参数/锁存变化 2=心跳
                for (int k = 0; k < 7; k++) last[k] = cur[k];
            }
        }
        esp_rom_delay_us(200);
        taskYIELD(); // 防饿死：采样任务与 app_main 同级轮转，controller_init 必须能跑
    }
}

static void fe_ring_dump(void)
{
    ESP_LOGI(TAG, "== FE cluster ring: %u entries ==", fe_ring_wr);
    for (unsigned i = 0; i < fe_ring_wr && i < FE_RING_N; i++) {
        ESP_LOGI(TAG, "%s[%03u] 408=%08x 40C=%08x 41C=%08x 420=%08x 444=%08x 450=%08x 47C=%08x 08D0=%08x 11AC=%08x",
                 fe_ring[i].tag == 1 ? "FC" : "HB", i,
                 (unsigned)fe_ring[i].v[0], (unsigned)fe_ring[i].v[1], (unsigned)fe_ring[i].v[2],
                 (unsigned)fe_ring[i].v[3], (unsigned)fe_ring[i].v[4], (unsigned)fe_ring[i].v[5],
                 (unsigned)fe_ring[i].v[6], (unsigned)fe_ring[i].v[7], (unsigned)fe_ring[i].v[8]);
    }
}

void app_main(void)
{
    dump_boot_state();
    ESP_LOGI(TAG, "boot, idf=%s", esp_get_idf_version());
    int beat = 0;
    for (;;) {
        ESP_LOGI(TAG, "beat %d", beat++);
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (beat == 2) {
            ESP_LOGI(TAG, "== init first, then probe the block ==");
            xTaskCreate(fe_sampler_task, "fe3", 3072, NULL, 1, NULL); // prio=1 与 app_main 同级
            fe_ring_on = 1;
            // dump_anchors("before_init");
            // step_by_step() 已移除：legacy 前置流程在本板 crash→reboot 循环，
            // 挡住 controller_init。官方 init 自己做完整 bringup。
            ESP_LOGI(TAG, "controller_init ...");
            esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
            esp_err_t r = esp_bt_controller_init(&cfg);
            ESP_LOGI(TAG, "controller_init -> %s (0x%x)", esp_err_to_name(r), r);
            if (r == ESP_OK) {
                ESP_LOGI(TAG, "controller_enable(BLE) ...");
                dump_regs("after_init");
                dump_anchors("after_init");
            dump_anchor_table("after_init");
                r = esp_bt_controller_enable(ESP_BT_MODE_BLE);
                ESP_LOGI(TAG, "controller_enable -> %s (0x%x)", esp_err_to_name(r), r);
                vTaskDelay(pdMS_TO_TICKS(2000));
                fe_ring_on = 0;
                fe_ring_dump();
                dump_regs("after_enable");
                dump_anchors("after_enable");
            }
        }
    }
}
