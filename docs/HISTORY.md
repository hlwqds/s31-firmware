# 历史与溯源

本仓库 v0.1.0 由 `hl-ljj-quartz@32f10c56` 的 `practice/zig-esp32-s31/` 与
`tools/s31-production/` 迁出，随后重构为生产结构（单一固件 + 组件）。原始章节工程
保留在 v0.1.0 提交历史与博客仓库中，可作为逐章参考。

## 章节 → 组件映射

| 组件 | 来源章节 | 主机测试数 |
| --- | --- | --- |
| `components/boot-power-perf` | 自举/功耗/性能（原 28A） | 14 |
| `components/net-ipv4` | IPv4/ICMP/ARP/路由 | 70 |
| `components/net-udp-dhcp-dns` | UDP/DHCP/DNS | 50 |
| `components/net-tcp` | TCP 状态机与可靠传输 | 33 |
| `components/net-congestion` | TCP 拥塞控制 | 21 |
| `components/net-sockets` | Socket API 与事件循环 | 38 |
| `components/net-tls-http` | TLS 记录层与 HTTP/1.1 | 58 |
| `components/app-mqtt-ota` | MQTT 与 OTA | 27 |
| `components/wifi-boundary` | Wi-Fi blob 边界 | 15 |
| `components/wifi-connect` | Wi-Fi 连接管理 | 20 |
| `components/ble-802154` | BLE / 802.15.4 边界 | 20 |
| `tools/s31-production/{netmgr,ota,provisioning,recovery}` | 生产化原型 | 15 / 8 / 18 / 9 |

## 日志

`logs/` 中是章节时代的板侧原始输出（文件名不改，便于与 `docs/history/BRINGUP-chapter-era.md`
逐条对照）。重构后的新证据使用同样命名规则追加。
