#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* 只抄结构体本身（esp_bt.h:176-323），不含任何 IDF 头 */
typedef struct {
    /*
     * Following parameters can not be configured runtime when call esp_bt_controller_init()
     * They will be overwritten by constant values from menuconfig options or from macros.
     * So, do not modify the value when esp_bt_controller_init()
     */
    uint32_t bredr_version;                 /*!< version number of the defined structure */
    /*
     * Following parameters can be configured runtime, when call esp_bt_controller_init()
     */
    uint8_t sleep_mode;                     /*!< controller sleep mode */
    uint8_t bt_test_mode_en;                /*!< enable br/edr test mode */
    uint8_t acl_cca_en;                     /*!< Enable BR/EDR ACL Transmit Clear Channel Assessment (TX CCA) */
    int8_t  cca_rssi_thr;                   /*!< BR/EDR RSSI threshold for Transmit Clear Channel Assessment (CCA) */
    uint8_t max_acl_conn;                   /*!< Maximum number of BR/EDR ACL connections. Configurable in menuconfig */
    uint8_t max_sync_conn;                  /*!< Maximum number of BR/EDR synchronous connections. Configurable in menuconfig */
    uint8_t cpb_tx_link_num;                /*!< BR/EDR CPB TX link number */
    uint8_t cpb_rx_link_num;                /*!< BR/EDR CPB RX link number */
    uint8_t bt_sco_datapath;                /*!< SCO data path, i.e. HCI(0) or PCM(1) */
    uint8_t hci_tl_type;                    /*!< HCI transport layer, UART, VHCI, etc */
    void *hci_tl_funcs;                     /*!< hci transport functions used, must be set when hci_tl_type is UART */
    uint32_t cfg_mask;                      /*!< reserved */
    uint32_t hw_target_code;                /*!< hardware target */
    int8_t acl_min_tx_pwr;                  /*!< Default transmit power for ACL minimum */
    int8_t acl_max_tx_pwr;                  /*!< Default transmit power for ACL maximum */
    int8_t apb_tx_pwr;                      /*!< Default transmit power for APB */
    int8_t page_tx_pwr;                     /*!< Default transmit power for Page */
    int8_t pscan_tx_pwr;                    /*!< Default transmit power for Page Scan */
    int8_t iscan_tx_pwr;                    /*!< Default transmit power for Inquiry Scan */
    int8_t cpb_tx_pwr;                      /*!< Default transmit power for CPB TX */
    int8_t strain_tx_pwr;                   /*!< Default transmit power for Synchronization Train */
    uint8_t rf_hw_type;                     /*!< RF hardware type */
    uint8_t static_aclu_tx_buf_nb;          /*!< Static ACL-U TX buffer number */
    uint8_t dynamic_aclu_tx_buf_nb;         /*!< Dynamic ACL-U TX buffer number */
    uint8_t aclu_rx_buf_nb;                 /*!< ACL-U RX buffer number */
    uint8_t sync_tx_buf_nb;                 /*!< SCO TX buffer number */
    uint8_t sync_rx_buf_nb;                 /*!< SCO RX buffer number */
    uint8_t esco_ev4_supp     : 1;          /*!< eSCO support EV4 packet type */
    uint8_t esco_ev5_supp     : 1;          /*!< eSCO support EV5 packet type */
    uint8_t esco_ev3_2_supp   : 1;          /*!< eSCO support 2-EV3 packet type */
    uint8_t esco_ev3_3_supp   : 1;          /*!< eSCO support 3-EV3 packet type */
    uint8_t esco_3_slots_supp : 1;          /*!< eSCO support 2-EV5 and/or 3-EV5 packet type */
    uint8_t bt_legacy_auth_vs_evt :1;       /*!< 1 if BR/EDR Legacy Authentication Vendor Specific Event is enabled, which is required to protect from BIAS attack; 0 otherwise. Configurable in menuconfig */
    uint8_t inq_filter_en : 1;              /*!< Enable inquiry result filter */
    uint8_t dtm_en :1;                      /*!< BR/EDR direct test mode */
    uint32_t mempool_size;                  /*!< Required mempool size used in BR/EDR controller */
    struct orca_mempool_ops *mempool_ops;   /*!< mempool operations used in BR/EDR controller */
    uint32_t bredr_magic;                   /*!< Magic number */
} esp_bredr_controller_config_t;

/**
 * @brief BTDM controller common configuration options
 */
typedef struct {
    uint32_t version;                   /*!< Version number of the defined structure */
    uint16_t task_stack_size;           /*!< Size of Bluetooth controller task stack */
    uint8_t task_prio;                  /*!< Priority of the Bluetooth controller task */
    uint8_t task_run_cpu;               /*!< CPU number on which the Bluetooth controller task runs */
    uint8_t hci_cmd_num;                /*!< HCI command buffer number */
    uint8_t hci_conn_num;               /*!< HCI level connection number */
    uint8_t sleep_en;                   /*!< Enable sleep functionality */
    uint8_t version_num;                /*!< Hardware version number of this chip */
    uint8_t bluetooth_mode;             /*!< Controller mode: BR/EDR, BLE or Dual Mode */
    uint32_t magic;                     /*!< Magic number for configuration validation */
} esp_btdm_controller_config_t;
typedef struct {
    /**
     * @brief Bluetooth LE controller configuration options
     */
    struct {
        uint32_t config_version;                     /*!< Version number of the defined structure */
        uint16_t ble_ll_resolv_list_size;            /*!< Size of the resolvable private address list */
        uint16_t ble_hci_evt_hi_buf_count;           /*!< Count of high buffers for HCI events */
        uint16_t ble_hci_evt_lo_buf_count;           /*!< Count of low buffers for HCI events */
        uint8_t ble_ll_sync_list_cnt;                /*!< Number of synchronization lists */
        uint8_t ble_ll_sync_cnt;                     /*!< Number of synchronizations */
        uint16_t ble_ll_rsp_dup_list_count;          /*!< Count of duplicated lists for scan response packets */
        uint16_t ble_ll_adv_dup_list_count;          /*!< Count of duplicated lists for advertising packets */
        uint8_t ble_ll_tx_pwr_dbm;                   /*!< Tx power (transmit power) in dBm */
        uint64_t rtc_freq;                           /*!< Frequency of RTC (Real-Time Clock) */
        uint16_t ble_ll_sca;                         /*!< Sleep Clock Accuracy (SCA) parameter */
        uint8_t ble_ll_scan_phy_number;              /*!< Number of PHYs supported for scanning */
        uint16_t ble_ll_conn_def_auth_pyld_tmo;      /*!< Connection default authentication payload timeout */
        uint8_t ble_ll_jitter_usecs;                 /*!< Jitter time in microseconds */
        uint16_t ble_ll_sched_max_adv_pdu_usecs;     /*!< Maximum time in microseconds for advertising PDU scheduling */
        uint16_t ble_ll_sched_direct_adv_max_usecs;  /*!< Maximum time in microseconds for directed advertising scheduling */
        uint16_t ble_ll_sched_adv_max_usecs;         /*!< Maximum time in microseconds for advertising scheduling */
        uint16_t ble_scan_rsp_data_max_len;          /*!< Maximum length of scan response data */
        uint8_t ble_ll_cfg_num_hci_cmd_pkts;         /*!< Number of HCI command packets that can be queued */
        uint32_t ble_ll_ctrl_proc_timeout_ms;        /*!< Control processing timeout in milliseconds */
        uint16_t nimble_max_connections;             /*!< Maximum number of connections supported */
        uint8_t ble_whitelist_size;                  /*!< Size of the white list */
        uint16_t ble_acl_buf_size;                   /*!< Buffer size of ACL (Asynchronous Connection-Less) data */
        uint16_t ble_acl_buf_count;                  /*!< Buffer count of ACL data */
        uint16_t ble_hci_evt_buf_size;               /*!< Buffer size for HCI event data */
        uint16_t ble_multi_adv_instances;            /*!< Number of advertising instances */
        uint16_t ble_ext_adv_max_size;               /*!< Maximum size of extended advertising data */
        uint16_t controller_task_stack_size;         /*!< Size of Bluetooth controller task stack, to be removed */
        uint8_t controller_task_prio;                /*!< Priority of the Bluetooth task, to be removed  */
        uint8_t controller_run_cpu;                  /*!< CPU number on which the Bluetooth controller task runs, to be removed */
        uint8_t enable_qa_test;                      /*!< Enable for QA test */
        uint8_t enable_bqb_test;                     /*!< Enable for BQB test */
        uint8_t enable_tx_cca;                       /*!< Enable Clear Channel Assessment (CCA) when transmitting */
        uint8_t cca_rssi_thresh;                     /*!< RSSI threshold for CCA */
        uint8_t sleep_en;                            /*!< Enable sleep functionality */
        uint8_t coex_phy_coded_tx_rx_time_limit;     /*!< Coexistence PHY coded TX and RX time limit */
        uint8_t dis_scan_backoff;                    /*!< Disable scan backoff */
        uint8_t ble_scan_classify_filter_enable;     /*!< Enable classification filter for BLE scan */
        uint8_t cca_drop_mode;                       /*!< CCA drop mode */
        int8_t cca_low_tx_pwr;                       /*!< Low TX power setting for CCA */
        uint8_t main_xtal_freq;                      /*!< Main crystal frequency */
        uint8_t ignore_wl_for_direct_adv;            /*!< Ignore the white list for directed advertising */
        uint8_t enable_pcl;                          /*!< Enable power control */
        uint8_t csa2_select;                         /*!< Select CSA2 */
        uint8_t enable_csr;                          /*!< Enable connection subrate */
        int8_t backoff_rssi;                         /*!< Set the lowest rssi threshold for backoff */
        bool iso_enabled;                            /*!< Enable ISO */
        bool iso_bqb_test;                           /*!< Enable ISO BQB test */
        bool iso_fra_unseg;                          /*!< Enable ISO FRA unsegmented */
        bool iso_nsfc_en;                            /*!< Enable ISO NSCF */
        uint8_t iso_nsfc_num;                        /*!< Number of ISO NSCF */
        uint8_t iso_buf_count;                       /*!< Number of ISO buffer */
        uint16_t iso_buf_size;                       /*!< Size of ISO buffer */
        uint8_t iso_big_count;                       /*!< Number of ISO big */
        uint16_t iso_bis_count;                      /*!< Number of ISO bis */
        uint8_t iso_bis_per_big;                     /*!< Number of ISO bis per big */
        uint8_t iso_cig_count;                       /*!< Number of ISO cig */
        uint16_t iso_cis_count;                      /*!< Number of ISO cis */
        uint8_t iso_cis_per_cig;                     /*!< Number of ISO cis per cig */
        uint32_t config_magic;                       /*!< Configuration magic value */
    } ble;                                           /*!< Bluetooth LE controller configuration options */

    /**
     * @brief Bluetooth Classic controller configuration options
     */
    esp_bredr_controller_config_t bredr;             /*!< Bluetooth Classic controller configuration options */

    /**
     * @brief Bluetooth controller common configuration options
     */
    esp_btdm_controller_config_t btdm;               /*!< Bluetooth controller common configuration options */
} esp_bt_controller_config_t;

/* 顺序即含义（见 btcfg_dump.sh 的注释） */
const unsigned probe[] = {
    sizeof(esp_bt_controller_config_t),             /* 0 */
    sizeof(esp_btdm_controller_config_t),           /* 1 */
    sizeof(esp_bredr_controller_config_t),          /* 2 */
    offsetof(esp_bt_controller_config_t, ble),      /* 3 */
    offsetof(esp_bt_controller_config_t, bredr),    /* 4 */
    offsetof(esp_bt_controller_config_t, btdm),     /* 5 */
    offsetof(esp_btdm_controller_config_t, version),/* 6 */
    offsetof(esp_btdm_controller_config_t, magic),  /* 7 */
    sizeof(__typeof__(((esp_bt_controller_config_t*)0)->ble)), /* 8 */
    offsetof(esp_bt_controller_config_t, ble) + offsetof(__typeof__(((esp_bt_controller_config_t*)0)->ble), config_magic),   /* 9 */
    offsetof(esp_bt_controller_config_t, ble) + offsetof(__typeof__(((esp_bt_controller_config_t*)0)->ble), config_version), /* 10 */
    offsetof(esp_bt_controller_config_t, ble) + offsetof(__typeof__(((esp_bt_controller_config_t*)0)->ble), rtc_freq),       /* 11 */
    offsetof(esp_bt_controller_config_t, ble) + offsetof(__typeof__(((esp_bt_controller_config_t*)0)->ble), main_xtal_freq), /* 12 */
};
