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
#endif

#define WIFI_SSID CONFIG_ORACLE_WIFI_SSID
#define WIFI_PASS CONFIG_ORACLE_WIFI_PASSWORD

#define GOT_IP_BIT BIT0
#define PING_END_BIT BIT1

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
        ESP_LOGI(TAG, "event: STA_START -> esp_wifi_connect()");
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
#endif
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL));
    s_evt = xEventGroupCreate();

    ESP_LOGI(TAG, "esp_wifi_set_mode(STA) -> %s", esp_err_to_name(esp_wifi_set_mode(WIFI_MODE_STA)));
    wifi_config_t wc = {0};
    strlcpy((char *)wc.sta.ssid, WIFI_SSID, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, WIFI_PASS, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    ESP_LOGI(TAG, "esp_wifi_set_config -> %s", esp_err_to_name(esp_wifi_set_config(WIFI_IF_STA, &wc)));

    esp_err_t e = esp_wifi_start();
    ESP_LOGI(TAG, "esp_wifi_start -> %s", esp_err_to_name(e));
#ifdef CONFIG_ORACLE_REGDUMP
    regdump("after-start");
#endif

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
