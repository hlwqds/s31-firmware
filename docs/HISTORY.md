# 历史与溯源

本仓库 v0.1.0 由 `hl-ljj-quartz@32f10c56` 的 `practice/zig-esp32-s31/` 与
`tools/s31-production/` 迁出，随后重构为生产结构（单一固件 + 组件）。原始章节工程
保留在 v0.1.0 提交历史与博客仓库中，可作为逐章参考。

## 章节 → 组件映射

| 组件 | 来源章节 | 主机测试数 |
| --- | --- | --- |
| `components/boot-power-perf` | 自举/功耗/性能（原 28A） | 28 |
| `components/net-ipv4` | IPv4/ICMP/ARP/路由 | 73 |
| `components/net-udp-dhcp-dns` | UDP/DHCP/DNS | 50 |
| `components/net-tcp` | TCP 状态机与可靠传输 | 36 |
| `components/net-congestion` | TCP 拥塞控制 | 21 |
| `components/net-sockets` | Socket API 与事件循环 | 38 |
| `components/net-tls-http` | TLS 记录层与 HTTP/1.1 | 70 |
| `components/app-mqtt-ota` | MQTT 与 OTA | 27 |
| `components/wifi-boundary` | Wi-Fi blob 边界 | 15 |
| `components/wifi-connect` | Wi-Fi 连接管理；R5.3 扩展为完整的 RSNA 请求方与帧级密码（CCMP、GCMP、BIP） | 57 |
| `components/wifi-blobs` | 真实 Wi-Fi blob 链接与 osi 适配（ch25 的实测延伸；R5/C2 加共存钩子） | 31 |
| `components/ble-802154` | BLE / 802.15.4 边界；R5.4 扩展为 HCI 控制、L2CAP、广播数据与地址、RFC 7668 | 68 |
| `components/wifi-mlme` | Wi-Fi 帧格式、管理帧、信息元素、MLME 与扫描（IEEE Std 802.11-2016 的非 AP STA 侧；R5.2 新增） | 61 |
| `components/ble-security` | SMP 配对与链路层加密（Bluetooth Core 5.4 Vol 3 Part H、Vol 6 Part B；R5.5 新增） | 51 |
| `components/radio-coex` | BLE 与 Wi-Fi 共存的 glue（对照 ESP-IDF 的 coex 接口；ADR-003） | 45 |
| `components/bt-blobs` | ch27 §27.11（BLE/802.15.4 边界）+ R3.3；R5/C2 加共存接线 | 19 |
| `tools/s31-production/{netmgr,ota,provisioning,recovery}` | 生产化原型 | 15 / 8 / 18 / 9 |

## 日志

`logs/` 中是章节时代的板侧原始输出（文件名不改，便于与 `docs/history/BRINGUP-chapter-era.md`
逐条对照）。重构后的新证据使用同样命名规则追加。
