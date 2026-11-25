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

表里的主机测试数是迁入当时的数，不随后来的批次改动。2026-11-24 的第一批、第二批与 2026-11-25 的第三批、第四批、第五批
往 `wifi-mlme`、`wifi-connect`、`ble-802154`、`ble-security` 里加了不抓空口能验证的特性（清单与证据在 `docs/verification/`），
当前的用例数以各组件的 README 与 `tests/baselines.json` 为准。

## 无线离线特性第五批（2026-11-25）

- **做了什么**：六个不抓空口的特性片——WNM 的其余子域（BSS Max Idle、TIM Broadcast、FMS、DMS、Collocated Interference、
  Channel Usage、WNM Notification、Event / Diagnostic 容器、QoS Traffic Capability，`wnm.zig` 第 15–24 节）、GAS / ANQP（`gas.zig`）、
  Block Ack 与 A-MSDU 子帧头（`blockack.zig`）进 `wifi-mlme`；PAwR 的三条数据命令与两个事件（`pawr.zig`）、
  Connection Subrating（`subrate.zig`）、LE Isochronous 的 HCI 接口面（`iso.zig`）进 `ble-802154`。
  主机用例 1818 → 2032，板侧判据 `wifi_mlme` 58 → 121、`ble_802154` 152 → 207（`wifi_connect` 199 不变）。
  规范依据：IEEE Std 802.11-2016 与 Bluetooth Core Specification 5.4；本批不涉新 RFC。
- **验收里抓到并修掉的问题**：Block Ack 的窗口边界错误（`SN = WinStart + 2^11` 一格的归属与原文相反，三处 `<=` → `<`；
  txt 转储里不等式是图片、为空，切片与 Python 模型同错，靠渲染 PDF 原文抓到）；WnmRest 带红测试交付（首交 34/39、
  板侧 5 条不过）且 QoS Traffic Capability 元素长度严格判等比 9.4.2.78 严；`keepaliveVerdict` 的周期参数 u16 → u32；
  GasAnqp 的「Status Code 宽度规范沉默」更正为 9.4.1.9（2 八位组）；IsoHci 的 `transparent air mode = 0x03` 补出处
  （Assigned Numbers §2.11）；WnmRest 的占空比公式推断经渲染 PDF 证实。差分驱动 `driver_pawr.zig` 的暂存区越界是驱动缺陷，
  改驱动（不入库）后重跑，`pawr.zig` 本身没有问题。
- **独立评审与返修（同日）**：只读评审员给出 Wi-Fi 15 条、BLE 7 条，BlockAck 一片无发现，其余五片返修并复验——
  最大的一条（P1，也是主代理验收时的漏项）是 CI Report 元素宽度：实现把中心频率做成 2 八位组、元素体 19 字节，
  原图 Figure 9-427 的八位组行是 4 4 4 4 2、元素体 21 字节，合规对端的每条 CI Report 都会被拒收；已按原图重做。
  另有 DMS Add 的反方向检查、GAS 失败路径与空列表、Advertisement Protocol 方向、FMS / DMS 长度封顶、CI 电平 +127、
  Diagnostic 子元素、CI Request 保留字段按 9.2.4.1 忽略、PAwR 的「已答位图」应答、`leRemoveIsoDataPath` 放宽与
  Emergency Call Number（9.4.5.5）补齐；`iso.zig` 文件头的 Zephyr 引用更正（BIGInfo 只有 NimBLE 一份可对）。
  存疑三条照实保留（见 `docs/verification/wifi-ieee80211-verification.md` §5.6）。
- **独立评审第二轮与一次误判（同日，如实记录）**：Wi-Fi 残留 6 条处理完（Destination URI ≤ 253 两侧强制并补边界用例、
  构造侧 URI 元素最小长度对齐、注释与页码改正）。其中 DMS 描述符构造侧的上限 `payload > 252` 比原文严一个八位组
  （9.4.2.88：DMS Length 最大 253），主代理核对时只读了 6 行、误判评审「不成立」并让切片别改；读完整函数后确认评审是对的，
  自己改成 253 并补 n = 252 可构造、n = 253 被拒的用例。BLE 第二轮七条全部解决、无新发现。
- **没有做的**：三片 Wi-Fi 与三片 BLE 都没有独立实现对拍（模型与实现同错时差分抓不出来）；与真实 AP 的互通没有本仓库自己的证据。
  板级：2026-11-25 随第五批镜像上板（串口权限由用户授权 `setfacl` 恢复），**整份 `wifi` profile 14/14 个 section 全过、
  `main: verdict=pass`**——三个无线 section 的判据全部在真板上通过（`wifi_mlme` 121/121、`wifi_connect` 199/199、
  `ble_802154` 207/207，第三、四、五批之后第一次），`net_ethernet` 11/11；`--only` 最小验证镜像（只编两个无线 section，
  512704 B = 整份的 42%）同样通过。期间一次 `net_ethernet` 不过查明是主机网口配置把链路拉低（板侧只等 5 秒），与板子无关。
  真实 AP 的厂商栈对照（属 R3）：官方 IDF 最小 station 已在同板连上用户提供的 AP（关联、WPA2-PSK、DHCP、ping 网关 5/5）；
  本仓库自己的 Wi-Fi 当时仍停在 `esp_wifi_start` 等 MAC 忙位（同日稍后解决，见下一节）。
  范围边界见 `docs/verification/` 两份报告的 §6。提交号见 `git log` 里标题含「R5 第五批」的那一条（站点仓的路线图引用了它）。

## Wi-Fi blob 的 `esp_wifi_start` 首次返回（2026-11-25）

- **做了什么**：找出并修掉了 Wi-Fi blob 移植自 R3.1 起的卡点。板级包新增 `boards/esp32s31-coreboard/src/pmu.zig`
  （`board.pmu.initModemIcg()`）：给三个 HP 电源模式写 modem 的 ICG 码（active=2 / modem=1 / sleep=0）并触发两次
  立即更新——IDF 启动期 `pmu_init()` 里的一步，裸机镜像此前没有做。`components/wifi-blobs` 的 `initOnly()` 开头调用它；
  `_wifi_clock_disable` 按 IDF 补齐（清 `clk_coex_en`、不在 disable 时复位 BB）；探针加了与 oracle 同一张地址表的全量寄存器
  dump（`probe_regdump`，默认关）。`tools/wifi-idf-oracle` 加 `CONFIG_ORACLE_REGDUMP` 与地址表生成器 `gen_regdump_addrs.py`。
- **怎么找到的**：与官方 IDF 在 `esp_wifi_init` 之后对照 SoC 头文件里定义过的 523 个寄存器，差集 95 个；其中 77 个可以
  安全照抄的全部按 IDF 值写入也不解决；单变量实验收窄到「写码 + 触发更新」必要且充分。完整记录在
  `docs/adr/ADR-001-wifi-blobs-cooperative-yield.md` 文末。
- **验证**：主机门禁 `scripts/check-all.sh` 各步通过；板侧——Wi-Fi 探针 `esp_wifi_start rc=0`（此前不返回）、init 之后
  `MAC_ST=0x00000000`（`logs/wifi-probe-start-rc0-boot.log`）；合并镜像重跑 `main: verdict=pass`
  （`logs/coex-merged-pmu-icg-boot.log`）；量产镜像 `PASS board:net`（8/8 段）。主机用例数不变。
- **没有做的**：扫描、连接、收发（`esp_wifi_start` 返回之后的路径）；BLE 侧不接这一步（接了 BLE 探针锁死，
  `logs/bt-probe-pmu-icg-lockup-boot.log`，属 R3.3）；`pmu_init()` 的其余部分（稳压器电压档、睡眠配置等）。

## 真实链路首次扫描（2026-11-26）

- **做了什么**：Wi-Fi 探针（`-Dwifi-link-probe`）在 `esp_wifi_start` 之后发起主动扫描，约 9.1 s 走完全部信道，
  `esp_wifi_scan_get_ap_records` 取到 38 条真实记录。为此修了两处。① 板级包新增 `boards/esp32s31-coreboard/src/apm.zig`
  （`board.apm.disableCtrlFilters()`）：裸机镜像没做 IDF 应用启动期 `bootloader_init_mem()` 关 APM 访问控制过滤器的三行，
  `FUNC_CTRL` 停在复位值（`0x7F` / `0x3F` / `0x0F`），只放行 TEE master——Wi-Fi MAC 的 DMA 属 REE，射频收到的帧写不进内存。
  ② `components/wifi-blobs/src/wpa_cb.zig`：登记 blob 的 supplicant 回调表（`struct wpa_funcs`）。镜像里没有 IDF 的
  `wpa_supplicant` 组件，这张表的指针一直是空的；现在 attach / detach / 断开通知驱动 `wifi-connect` 的 `Supplicant`
  （为此 `wifi-connect` 加了公共入口 `api.zig`），`wpa_parse_wpa_ie` 是 IDF 同名函数的移植。探针的 PHY 标定改回每次
  全量标定，不再用从对照镜像 NVS 里读出来的标定数据（那份文件本来就不该入库）。
- **怎么找到的**：① 线索是 ch17 以太网的同一条根因——APM 控制过滤器挡住 REE master 的 DMA；用对照镜像 ELF 的反汇编
  确认 IDF 应用的 `bootloader_init_mem` 正好是三条写 0。关掉之后中断状态字立刻出现收帧位，驱动开始构造 AP 记录。
  ② 第一帧之后驱动崩在 `scan_add_ssid_do`（`load access fault`，`mtval=0x54`）：`objdump -dr` 看 blob 各目标文件里
  `lw x,444(y)` 之后读的是哪个字段，对上 IDF 头文件 `struct wpa_funcs` 的偏移（84 = `wpa_sta_rx_mgmt`），再从 oracle 的
  链接 map 确认这些入口在 IDF 里来自 `wpa_supplicant` 组件。完整记录在 `docs/verification/wifi-ieee80211-verification.md` §10。
- **验证**：主机门禁（fmt、单元测试 2045 项、覆盖率、不变量）通过；板侧连续 5 次扫描全部完成（32–41 个 AP）；
  与同板 oracle 同一时段的结果逐 AP 对照，8 个里 7 个一致、第 8 个那一轮没扫到
  （`logs/wifi-link-scan-boot.log`，邻居的 SSID 与 BSSID 已脱敏）。
- **没有做的**：连接、收发；PHY 标定数据的持久化；回调表里连接路径的入口（`wpa_sta_rx_eapol`、`wpa_config_parse_string`、
  SAE / OWE 的消息构造与解析等）；与 AP 的互通仍只有厂商栈的证据；没有抓包。

## 日志

`logs/` 中是章节时代的板侧原始输出（文件名不改，便于与 `docs/history/BRINGUP-chapter-era.md`
逐条对照）。重构后的新证据使用同样命名规则追加。
