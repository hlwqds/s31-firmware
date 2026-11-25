/* s31-wifi-oracle：官方 IDF 的最小 station，当「板子射频 + AP」的对照。
 *
 * 目的（见 s31-firmware 的 Wi-Fi 移植）：自写运行时跑同一个 Wi-Fi blob 时 esp_wifi_start 卡在 MAC 忙位；
 * 先用官方 SDK 在同一块板上真实连一次 AP，证明射频与 AP 这条路是通的，再拿它当逐步复刻的 oracle。
 *
 * 事件全打印：STA 启动、关联 / 断开（带 reason）、信道与 RSSI、拿到的 IP 与网关；
 * 拿到 IP 之后主动发包（两端证据）：ping 网关 5 次、ping 一个公网地址 5 次、
 * 经网关做一次 DNS 解析再 ping 解析结果 3 次。之后每 10 秒打一次链路状态。
 */
#include <string.h>
#include <netdb.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"

#include "esp_event.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "apps/ping/ping_sock.h"
#ifdef CONFIG_ORACLE_REGDUMP
#include "regdump_addrs.h"

/* 与 s31-firmware 的 Wi-Fi 探针对照用：按 SoC 头文件里定义过的寄存器地址全量读一遍（只读、不写）。
 * 两边在同一个时点各 dump 一次，再程序化做差。MAC_ST（0x20104CAC）是 blob 私有的状态寄存器，
 * 不在头文件里，单独读。 */
static void regdump(const char *tag) {
    volatile uint32_t *mac_st = (volatile uint32_t *)0x20104CAC;
    printf("REGDUMP %s begin n=%u mac_st=%08X\n", tag, (unsigned)DUMP_N, (unsigned)*mac_st);
    for (unsigned i = 0; i < DUMP_N; i++) {
        volatile uint32_t *p = (volatile uint32_t *)g_dump_addrs[i];
        printf("REG %u %08X %08X\n", i, (unsigned)g_dump_addrs[i], (unsigned)*p);
    }
    printf("REGDUMP %s end\n", tag);
}

/* MAC 块整段（0x20104000 起 4 KB，blob 私有，不在头文件里）：扫描是驱动直接往这里写出来的。有定义的
 * 寄存器都都对上了而扫描结果不同时，差别只能在里面。只读；个别读清位会被读掉，只用于诊断。 */
#define MAC_BLOCK_BASE 0x20104000u
#define MAC_BLOCK_N 1024u
static void macdump(const char *tag) {
    printf("MACDUMP %s begin n=%u base=%08X\n", tag, (unsigned)MAC_BLOCK_N, (unsigned)MAC_BLOCK_BASE);
    for (unsigned i = 0; i < MAC_BLOCK_N; i++) {
        volatile uint32_t *p = (volatile uint32_t *)(MAC_BLOCK_BASE + 4u * i);
        printf("MACW %u %08X %08X\n", i, (unsigned)(MAC_BLOCK_BASE + 4u * i), (unsigned)*p);
    }
    printf("MACDUMP %s end\n", tag);
}

/* CLIC 每个输入的控制字（0x10801000 + 4*i）。s31-firmware 的真实链路探针只放行"装了处理函数"的输入；
 * 这里把 IDF 在扫描中实际放行的输入打出来对照。只打非零的。 */
static void clicdump(void) {
    printf("CLICDUMP begin n=64 base=%08X\n", (unsigned)0x10801000u);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t ctl = *(volatile uint32_t *)(0x10801000u + 4u * i);
        if (ctl) printf("CLIC %u %08X\n", i, (unsigned)ctl);
    }
    printf("CLICDUMP end\n");
}

/* 不在头文件里的几块：FE（0x20100000 起 16 KB）、BB/BRX/MODEM_TIMER/ETM/DATADUMP/WIDGETS（0x20107000 起
 * 11 KB）、0x2010D000 起 8 KB。每行 8 个字（`RG <地址> <8 个值>`），全打不做过滤。只读，只用于诊断。 */
static void rangdump(const char *tag, uint32_t base, uint32_t n) {
    printf("RANGEDUMP %s begin base=%08X n=%u\n", tag, (unsigned)base, (unsigned)n);
    for (uint32_t i = 0; i < n; i += 8) {
        printf("RG %08X", (unsigned)(base + 4u * i));
        for (uint32_t j = 0; j < 8 && i + j < n; j++) {
            printf(" %08X", (unsigned)*(volatile uint32_t *)(base + 4u * (i + j)));
        }
        printf("\n");
    }
    printf("RANGEDUMP %s end\n", tag);
}
static void rangdump_all(void) {
    /* 只读头文件里给了基址的那几块，各按 1 KB（WIDGETS 2 KB）算。FE 只到 0x20101FFF：0x20102000 起读不到
     * （s31-firmware 的探针在那里读一次就挂死；0x20103000 是 IEEE 802.15.4 的块，中间是空的）。 */
    rangdump("fe", 0x20100000u, 2048u);
    rangdump("bb", 0x20107000u, 1024u);
    rangdump("brx", 0x20108000u, 256u);
    rangdump("timer", 0x20108400u, 256u);
    rangdump("etm", 0x20108800u, 256u);
    rangdump("dump", 0x20109000u, 256u);
    rangdump("wgt", 0x20109400u, 512u);
    rangdump("pwr0", 0x2010D000u, 512u);
    rangdump("pwr8", 0x2010D800u, 64u);
}

/* 定点采样：两块全量对照里出现过差异的那几十个地址，一个一行（`FOCUS <地址> <值>`）。放在扫描开始后
 * 100 ms、所有慢 dump **之前**打——全量 dump 要十几秒，等到它的时候扫描早就结束、驱动已经把 FE/BB
 * 时钟收起来，那是空闲态而不是收发态（2026-11-26 的 scan8 就是这么比错的）。 */
static const uint32_t focus_addrs[] = {
    0x20107000u, 0x20107030u, 0x2010704Cu, 0x20107050u, 0x2010706Cu, 0x20107078u, 0x2010708Cu, 0x20107128u,
    0x20107138u, 0x201071D4u, 0x2010740Cu, 0x20107438u, 0x20107848u, 0x2010785Cu, 0x20107888u, 0x201078A8u,
    0x201078ACu, 0x201078B8u, 0x201078BCu, 0x201078C0u, 0x201078C4u, 0x201078D0u, 0x20107C08u, 0x20107C60u,
    0x20107C64u, 0x20107C80u, 0x20107C90u, 0x20107CB0u, 0x20107FFCu,
    0x20108038u, 0x2010803Cu, 0x20108044u, 0x20108048u, 0x20108094u,
    0x2010D800u, 0x2010D878u,
    0x2010001Cu, 0x20100050u, 0x20100400u, 0x20100438u, 0x20100450u, 0x20100800u, 0x2010081Cu, 0x20100820u,
    0x20100830u, 0x20100848u, 0x2010084Cu, 0x20100850u, 0x20100890u, 0x20100894u, 0x20100898u, 0x2010089Cu,
    0x201008A0u, 0x201008A4u, 0x20101FFCu,
};
static void focusdump(const char *tag) {
    printf("FOCUSDUMP %s begin n=%u\n", tag, (unsigned)(sizeof focus_addrs / sizeof focus_addrs[0]));
    for (unsigned k = 0; k < sizeof focus_addrs / sizeof focus_addrs[0]; k++) {
        printf("FOCUS %08X %08X\n", (unsigned)focus_addrs[k], (unsigned)*(volatile uint32_t *)focus_addrs[k]);
    }
    printf("FOCUSDUMP %s end\n", tag);
}

/* 各块单次读的耗时（与 s31-firmware 探针的 `busReadTiming` 同点对照）：每个地址读 16 次取平均。
 * 探针那边读 FE 块每个字约 10 ms，看这里是不是也这样。 */
static void readtiming(void) {
    const uint32_t addrs[] = { 0x20100000u, 0x20100800u, 0x20101800u, 0x20104000u, 0x20107000u, 0x20108000u, 0x20108400u,
                               0x20109000u, 0x20109C00u, 0x2010D000u, 0x2010D800u, 0x2010F000u, 0x2010F800u };
    for (unsigned k = 0; k < sizeof addrs / sizeof addrs[0]; k++) {
        int64_t t0 = esp_timer_get_time();
        uint32_t v = 0;
        for (int i = 0; i < 16; i++) v = *(volatile uint32_t *)addrs[k];
        printf("READTIMING %08X %lld us avg (last %08X)\n", (unsigned)addrs[k],
               (long long)((esp_timer_get_time() - t0) / 16), (unsigned)v);
    }
}
#endif

/* 驱动的信道管理器（blob 的 `g_chm`，一个指针变量）：`[4]` 是目标信道、`[82]` 是驱动记的当前信道。
 * s31-firmware 的真实链路探针读同一组字段对照：blob 在"这是芯片"时靠两者是否相等决定扫描前要不要切信道。 */
extern uint8_t *g_chm;
static void chmdump(const char *tag) {
    uint8_t *chm = g_chm;
    if (!chm) {
        printf("CHMDUMP %s obj=00000000\n", tag);
        return;
    }
    printf("CHMDUMP %s obj=%08X ch=%02X cur=%02X f80=%02X f83=%02X\n", tag, (unsigned)(uintptr_t)chm, chm[4], chm[82],
           chm[80], chm[83]);
}

#define WIFI_SSID CONFIG_ORACLE_WIFI_SSID
#define WIFI_PASS CONFIG_ORACLE_WIFI_PASSWORD

#define GOT_IP_BIT BIT0
#define PING_END_BIT BIT1
#define SCAN_DONE_BIT BIT2

static const char *TAG = "oracle";
static EventGroupHandle_t s_evt;
static int s_retry;
static const char *s_ping_name;
static uint32_t s_ping_req, s_ping_rep;

static const char *auth_mode_name(wifi_auth_mode_t m) {
    switch (m) {
        case WIFI_AUTH_OPEN: return "OPEN";
        case WIFI_AUTH_WEP: return "WEP";
        case WIFI_AUTH_WPA_PSK: return "WPA_PSK";
        case WIFI_AUTH_WPA2_PSK: return "WPA2_PSK";
        case WIFI_AUTH_WPA_WPA2_PSK: return "WPA/WPA2_PSK";
        case WIFI_AUTH_WPA3_PSK: return "WPA3_PSK";
        case WIFI_AUTH_WPA2_WPA3_PSK: return "WPA2/WPA3_PSK";
        case WIFI_AUTH_WAPI_PSK: return "WAPI_PSK";
        default: return "other";
    }
}

static void dump_ap(const char *when) {
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK) {
        ESP_LOGI(TAG, "%s: not associated", when);
        return;
    }
    ESP_LOGI(TAG, "%s: ssid=%s bssid=%02x:%02x:%02x:%02x:%02x:%02x ch=%u rssi=%d auth=%s",
             when, ap.ssid, ap.bssid[0], ap.bssid[1], ap.bssid[2], ap.bssid[3], ap.bssid[4], ap.bssid[5],
             ap.primary, ap.rssi, auth_mode_name(ap.authmode));
}

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        ESP_LOGI(TAG, "event: STA_START");
        /* 只扫描模式（SSID 为空）不连接。 */
        if (WIFI_SSID[0] == '\0') return;
        ESP_LOGI(TAG, "STA_START -> esp_wifi_connect()");
        esp_err_t e = esp_wifi_connect();
        ESP_LOGI(TAG, "esp_wifi_connect -> %s", esp_err_to_name(e));
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = data;
        s_retry++;
        ESP_LOGW(TAG, "event: STA_DISCONNECTED #%d reason=%d rssi=%d", s_retry, (int)d->reason, d->rssi);
        if (s_retry < 30) {
            vTaskDelay(pdMS_TO_TICKS(2000));
            esp_wifi_connect();
        }
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_CONNECTED) {
        wifi_event_sta_connected_t *c = data;
        ESP_LOGI(TAG, "event: STA_CONNECTED ssid=%s bssid=%02x:%02x:%02x:%02x:%02x:%02x ch=%u auth=%d aid=%u",
                 c->ssid, c->bssid[0], c->bssid[1], c->bssid[2], c->bssid[3], c->bssid[4], c->bssid[5],
                 c->channel, c->authmode, c->aid);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        ESP_LOGI(TAG, "event: GOT_IP ip=" IPSTR " netmask=" IPSTR " gw=" IPSTR, IP2STR(&e->ip_info.ip),
                 IP2STR(&e->ip_info.netmask), IP2STR(&e->ip_info.gw));
        dump_ap("after got ip");
        xEventGroupSetBits(s_evt, GOT_IP_BIT);
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_SCAN_DONE) {
        wifi_event_sta_scan_done_t *d = data;
        ESP_LOGI(TAG, "SCAN_DONE status=%d number=%d scan_id=%d", d->status, d->number, d->scan_id);
        xEventGroupSetBits(s_evt, SCAN_DONE_BIT);
    }
}

static void ping_ok(esp_ping_handle_t h, void *a) {
    uint8_t seq = 0;
    uint16_t len = 0;
    uint32_t t = 0;
    (void)a;
    esp_ping_get_profile(h, ESP_PING_PROF_SEQNO, &seq, sizeof(seq));
    esp_ping_get_profile(h, ESP_PING_PROF_SIZE, &len, sizeof(len));
    esp_ping_get_profile(h, ESP_PING_PROF_TIMEGAP, &t, sizeof(t));
    ESP_LOGI(TAG, "ping %s: reply seq=%u bytes=%u time=%u us", s_ping_name, seq, len, (unsigned)t);
}

static void ping_to(esp_ping_handle_t h, void *a) {
    (void)h;
    (void)a;
    ESP_LOGW(TAG, "ping %s: timeout", s_ping_name);
}

static void ping_end(esp_ping_handle_t h, void *a) {
    (void)a;
    esp_ping_get_profile(h, ESP_PING_PROF_REQUEST, &s_ping_req, sizeof(s_ping_req));
    esp_ping_get_profile(h, ESP_PING_PROF_REPLY, &s_ping_rep, sizeof(s_ping_rep));
    xEventGroupSetBits(s_evt, PING_END_BIT);
}

static void ping_run(const char *name, const ip_addr_t *target, uint32_t count) {
    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.count = count;
    cfg.target_addr = *target;
    cfg.task_stack_size = 4096;
    esp_ping_callbacks_t cbs = {
        .cb_args = NULL, .on_ping_success = ping_ok, .on_ping_timeout = ping_to, .on_ping_end = ping_end,
    };
    esp_ping_handle_t h;
    esp_err_t e = esp_ping_new_session(&cfg, &cbs, &h);
    if (e != ESP_OK) {
        ESP_LOGW(TAG, "ping %s: new session -> %s", name, esp_err_to_name(e));
        return;
    }
    s_ping_name = name;
    s_ping_req = s_ping_rep = 0;
    xEventGroupClearBits(s_evt, PING_END_BIT);
    esp_ping_start(h);
    xEventGroupWaitBits(s_evt, PING_END_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(count * 2000 + 5000));
    ESP_LOGI(TAG, "ping %s: requests=%u replies=%u", name, (unsigned)s_ping_req, (unsigned)s_ping_rep);
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_ping_delete_session(h);
}

/* 只扫描、不连接（`CONFIG_ORACLE_WIFI_SSID` 为空时走这里）：与 s31-firmware 的真实链路探针在同一点
 * 对照。全信道扫描非阻塞启动，等 100 ms 让它真正开始（射频已开、驱动在跳信道）就 dump 一次，
 * 再等它结束 dump 一次，并打印扫到的前几个 AP。 */
static void scan_only_run(void) {
    esp_err_t e = esp_wifi_scan_start(NULL, false);
    ESP_LOGI(TAG, "esp_wifi_scan_start(NULL, nonblock) -> %s", esp_err_to_name(e));
    vTaskDelay(pdMS_TO_TICKS(100));
#ifdef CONFIG_ORACLE_REGDUMP
    focusdump("in-scan");
    rangdump_all();
    regdump("in-scan");
    macdump("in-scan");
    clicdump();
    chmdump("in-scan");
#endif
    EventBits_t bits = xEventGroupWaitBits(s_evt, SCAN_DONE_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(10000));
    ESP_LOGI(TAG, "wait scan-done 10s -> %s", (bits & SCAN_DONE_BIT) ? "GOT" : "timeout");
    uint16_t n = 0;
    esp_err_t ne = esp_wifi_scan_get_ap_num(&n);
    ESP_LOGI(TAG, "esp_wifi_scan_get_ap_num -> %s n=%u", esp_err_to_name(ne), (unsigned)n);
    wifi_ap_record_t recs[8];
    uint16_t got = (n < 8) ? n : 8;
    if (ne == ESP_OK && got > 0) {
        esp_err_t ge = esp_wifi_scan_get_ap_records(&got, recs);
        ESP_LOGI(TAG, "esp_wifi_scan_get_ap_records -> %s got=%u", esp_err_to_name(ge), (unsigned)got);
        for (uint16_t i = 0; i < got; i++) {
            ESP_LOGI(TAG, "ap[%u] ssid=%s bssid=%02x:%02x:%02x:%02x:%02x:%02x ch=%u rssi=%d auth=%s", (unsigned)i,
                     recs[i].ssid, recs[i].bssid[0], recs[i].bssid[1], recs[i].bssid[2], recs[i].bssid[3],
                     recs[i].bssid[4], recs[i].bssid[5], recs[i].primary, recs[i].rssi,
                     auth_mode_name(recs[i].authmode));
        }
    }
#ifdef CONFIG_ORACLE_REGDUMP
    regdump("after-scan");
    macdump("after-scan");
    focusdump("after-scan");
    rangdump_all();
#endif
}

static void traffic_test(esp_netif_ip_info_t *ip) {
    ip_addr_t target;
    ip_addr_copy_from_ip4(target, ip->gw);
    ping_run("gateway", &target, 5);
    IP_ADDR4(&target, 223, 5, 5, 5);
    ping_run("223.5.5.5", &target, 5);
    /* 经网关做一次 DNS 解析：用 lwIP 的 getaddrinfo（走 esp_netif 默认的 DNS）。 */
    const struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM};
    struct addrinfo *res = NULL;
    int rc = getaddrinfo("www.baidu.com", NULL, &hints, &res);
    if (rc != 0 || res == NULL) {
        ESP_LOGW(TAG, "dns: getaddrinfo(www.baidu.com) -> rc=%d", rc);
        return;
    }
    struct sockaddr_in *sa = (struct sockaddr_in *)res->ai_addr;
    uint32_t u = sa->sin_addr.s_addr;
    ip4_addr_t a4;
    IP4_ADDR(&a4, (u >> 0) & 0xff, (u >> 8) & 0xff, (u >> 16) & 0xff, (u >> 24) & 0xff);
    ESP_LOGI(TAG, "dns: www.baidu.com -> " IPSTR, IP2STR(&a4));
    ip_addr_copy_from_ip4(target, a4);
    freeaddrinfo(res);
    ping_run("dns-result", &target, 3);
}

void app_main(void) {
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    ESP_LOGI(TAG, "s31-wifi-oracle: STA MAC=%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3],
             mac[4], mac[5]);
    ESP_LOGI(TAG, "nvs_flash_init -> %s", esp_err_to_name(nvs_flash_init()));

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t *sta_netif = esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_LOGI(TAG, "esp_wifi_init -> %s", esp_err_to_name(esp_wifi_init(&cfg)));
#ifdef CONFIG_ORACLE_REGDUMP
    regdump("after-init");
    chmdump("after-init");
#endif
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL));
    s_evt = xEventGroupCreate();

    ESP_LOGI(TAG, "esp_wifi_set_mode(STA) -> %s", esp_err_to_name(esp_wifi_set_mode(WIFI_MODE_STA)));
    wifi_config_t wc = {0};
    strlcpy((char *)wc.sta.ssid, WIFI_SSID, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, WIFI_PASS, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    if (WIFI_SSID[0] != '\0') {
        ESP_LOGI(TAG, "esp_wifi_set_config -> %s", esp_err_to_name(esp_wifi_set_config(WIFI_IF_STA, &wc)));
    }

    esp_err_t e = esp_wifi_start();
    ESP_LOGI(TAG, "esp_wifi_start -> %s", esp_err_to_name(e));
#ifdef CONFIG_ORACLE_REGDUMP
    regdump("after-start");
    chmdump("after-start");
    readtiming();
#endif

    if (WIFI_SSID[0] == '\0') {
        scan_only_run();
        for (;;) vTaskDelay(pdMS_TO_TICKS(10000));
    }

    /* 等最多 30 秒拿 IP；拿到就跑一轮主动发包。 */
    EventBits_t bits = xEventGroupWaitBits(s_evt, GOT_IP_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));
    ESP_LOGI(TAG, "wait got-ip 30s -> %s", (bits & GOT_IP_BIT) ? "GOT" : "timeout");
    if (bits & GOT_IP_BIT) {
        esp_netif_ip_info_t ip;
        if (esp_netif_get_ip_info(sta_netif, &ip) == ESP_OK) traffic_test(&ip);
        ESP_LOGI(TAG, "traffic test done");
    }
    for (int i = 0;; i++) {
        dump_ap(i == 0 ? "link" : "link");
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}
