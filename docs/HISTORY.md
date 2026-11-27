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

## 真实链路连上 AP 与数据通路（2026-11-26）

- **做了什么**：真实链路探针在扫描之后继续走连接 → 核对 MAC 密钥表 → 数据通路（DHCP + ping 网关）→ 再泵 5 秒 → 断开，
  全程开着共存核并取读数。连接一侧把 supplicant 回调表从 4 项填到 12 项，`wifi-connect` 的 `Supplicant` 第一次在真实 AP 上走完
  WPA2-PSK 的四次握手（RSN + PSK，CCMP-128）；数据通路一侧新增 `data_path.zig`，把驱动的以太网帧接到 `net-ipv4` 与
  `net-udp-dhcp-dns`。共存一侧给探针加了各阶段的核读数（`coexReadings`），ADR-003 第 5 节把 L4 拆成 L4a / L4b 并写下 L4b 的做法。
- **怎么找到的**：这一步修的四处都在运行时，每处都先有一个板上的现场。① 握手完成后 `store access fault`、停在断点上时返回地址与栈帧里
  是 `0xff00ffff`、`0xff000000` 这类值：Wi-Fi 任务栈按 blob 请求的 6656 字节给，四次握手用 9252 字节；探针加打各任务栈的高水位之后数字才看得见。
  ② `esp_wifi_set_config` 回 `0x1105`：NVS 的键在第 9 个、第 19 个就用完（日志里 `wifi_nvs_set fail`）。③ 连上之后 DHCP 12 秒没有
  应答、一帧都没收到，而握手照常完成：探针加了一项核对——MAC 密钥表里成对钥匙与组钥匙那两格对请求方手里的钥匙逐字节比——
  位图是 `ffff, 8fff, 88ff, …` 的阶梯，才想到是逐字节的 `memcpy` 写整字寄存器堆；对照镜像里这三个名字取的是 ROM 的实现。
  ④ ping 网关 0/10 而 DHCP 正常：给数据通路加"最近收到的帧"的记录，看到网关在每帧回显之后都来问本机的 MAC，本机没有答。
  细目在 `docs/verification/wifi-ieee80211-verification.md` §11 与 `docs/verification/coex-verification.md` §12。
- **验证**：主机门禁（fmt、单元测试 2064 项、覆盖率、不变量、容量、e2e host）通过；板侧连上约 3.0 s、DHCP 约 0.1 s、ping 网关
  连续 4 轮 10/10、连上后稳定 5 秒、断开 reason=8（`logs/wifi-link-connect-boot.log`，邻居的 SSID 与 BSSID 已脱敏）；修复前的现场
  各留了一段（`wifi-link-connect-crash-boot.log`、`wifi-link-connect-watchpoint-boot.log`、`wifi-link-connect-badkeys-boot.log`、
  `wifi-link-connect-noarp-boot.log`）。默认镜像（`net` profile）上板 `firmware: sections: passed=8 failed=0 total=8`、`main: verdict=pass`
  （`logs/e2e-net-boot.log`）。
- **没有做的**：其余 AKM 与套件（SAE、OWE、FT、企业）、多台 AP、重连与长时间稳定性；把 TCP / TLS 接到这条链路上；抓包；
  两个射频同时开着的共存效果（L4b，等 R3.3）。

## 合并镜像里的 Wi-Fi 真实链路（2026-11-26）

- **做了什么**：新增 `-Dcoex-wifi-link`（要求 `-Dcoex-merged`）——合并自检 section 让 Wi-Fi 先 `esp_wifi_start`，扫一次全信道作
  基线，再做 BLE 的 init（可选 `-Dcoex-ble-enable`），把时钟 / 电源寄存器按快照写回，然后 Wi-Fi 走真实链路（扫描、连接、
  DHCP、ping、断开）；判据多一条「BLE init 之后的扫描 AP 数不低于基线的一半」。真实链路的主干从探针的 `run()` 抽成
  `link_probe.zig` 的 `linkStart()` / `linkRest()`，探针照旧用它们。结果是两个控制器同镜、BLE `INITED` 且 `ENABLED` 的状态下，
  Wi-Fi 扫描 35 个 AP、连上、DHCP、ping 网关 10/10。
- **怎么找到的**：第一次上板不通（3 个 AP、`reason=201`），而每一块零件单独都验证过。在 BLE init 之前插一次同样的扫描
  （三十多个 AP）之后，「谁干的」就没有悬念——是 BLE 的 init 这一段。读代码：`bringup.init` 有两段会重做 PHY 的打开与标定
  （`probe_ptr.initPhy()`，与第 15 步的 `esp_phy_load_cal_and_init()`——它在这个镜像里恒为「没标定过」，等于每次都做一次
  全量重新标定）。初稿只把责任归给后者；修完之后在最终形态上做五个单变量对照（每次只关一样）才定案：只跳过其中一段，
  扫描就掉到 1–2 个 AP，两段都跳过才恢复；不写回时钟 / 电源寄存器，扫描照常、连接失败（`reason=7`）。对照还暴露出原来
  的判据抓不住接收退化（退化的镜像 `verdict` 照样是 pass），于是加了那条扫描 AP 数的判据。修法是把「PHY 归先使能它的
  那一方」落到代码里（`probe_ptr.phy_owned_by_wifi`）。细目在 `docs/verification/coex-verification.md` §15。
- **验证**：主机门禁（`scripts/check-all.sh`：fmt、单元测试 2064 项、覆盖率、不变量、容量、六个 profile 构建）退出 0；板侧
  最终形态：BLE init 之前 34 个 AP，之后 35 个 AP，连上 2059 ms、DHCP 51 ms、ping 网关 10/10，16/16，`verdict=pass`
  （`logs/coex-merged-wifi-link-boot.log`）。五份对照日志同一个前缀（`-dump-`、`-noguard-`、`-norestore-`、`-onlyloadcal-`、
  `-onlyinitphy-boot.log`）；BLE 先 init 的顺序不通，留作对照（`logs/coex-merged-wifi-link-deaf-boot.log`）。
- **AP 侧的证据（当晚）**：用户用网线把工作站接进 AP 的 LAN 并给了登录，AP 是刷了 OpenWrt 的小米 AX3000T。只读采集三样：
  AP 的系统日志、板子连上期间每秒一份的站点统计、AP 有线侧网线上的帧。AP 日志里修之前每一轮都是「板子没有确认认证
  响应」；最终形态双向 86 Mbit/s、15 秒里重传 0–1 次；只跳过第 15 步时 AP 发给板子的帧放弃 51 / 51、速率压到
  6–8.6 Mbit/s，而信号一样强——退化在板子的接收侧。板子的 ARP 应答能跨过 AP 的桥到达同网段的另一台主机；板子不回应
  别人的回显请求（数据通路只处理回显应答，是缺口）。细目在 `docs/verification/coex-verification.md` §15.8。
- **2026-11-27 更新**：下面「没有做的」里的时钟域与空口上的帧已经做了，见下一节。
- **没有做的**：两个射频都在收发的共存效果（L4b，BLE 的射频没有起）；时钟域的正解（现在是事后整字写回，在 BLE 的 enable
  之后执行，BLE 那一侧的时钟位也被拿掉）；两段各自伤在哪一步；写回的寄存器里哪几个必要；排查阶段各轮的原始日志没有入库；
  空口上的帧（路由器没有外网，装不了 tcpdump）；板子回别人的 ping。

## 空口上的帧、时钟域按单元取并集（2026-11-27）

- **做了什么**：(1) AP 侧抓到了空口上的帧——在工作站上交叉编译静态的 tcpdump 放进路由器的内存盘，每轮临时建 monitor
  接口；工具入库 `tools/ap-side/`（当晚同一个二进制改装到路由器的 `/usr/bin/tcpdump`，重启不丢；工作站也装了
  `~/.local/bin/tcpdump`）。(2) 时钟域改成按单元取并集：两边只置自己的时钟单元位，共享单元另一边还占着就不关，
  事后写回删除；IDF 的单元表写在 `components/radio-coex/src/owner.zig` 的 `clocks`，合并镜像在四个时点按并集核对。
  (3) 合并镜像的构建入口固化为 `scripts/build-coex-link-image.sh`，只编合并这一段。(4) 试了在合并镜像里经 HCI 起广播
  （`-Dcoex-ble-adv`），没有结论。
- **验证**：主机测试全过；板上 20/20（`logs/coex-merged-wifi-link-union-boot.log`）；单独的 BLE 探针与基线逐行等价
  （`logs/bt-probe-clock-union-boot.log`）；单独的 Wi-Fi 真实链路镜像回归通过（`logs/wifi-link-clock-union-boot.log`：
  扫描 37 个 AP、连上、DHCP、ping 10/10）；空口帧 `logs/coex-merged-wifi-link-ap-frames.log`；广播实验
  `logs/coex-merged-wifi-link-ble-adv-boot.log`（停在发完第一条命令之后）。细目在 `docs/verification/coex-verification.md`
  §15.9–§17、`wifi-ieee80211-verification.md` §12、`ble-core-verification.md` §9。
- **没有做的**：两个射频都在收发（广播没有起来；HCI 命令要从独立栈上的发送任务里发，没有做）；BLE 的 disable 路径；
  「BLE 先起」的顺序；板子回别人的 ping。
- **2026-11-27 更新**：发送任务当晚做了，见下一节。

## 合并镜像里 HCI 命令从发送任务里发（2026-11-27）

- **做了什么**：上一节「没有做的」里的发送任务做了——`components/bt-blobs/src/probe.zig` 的 `sendFromTask` 把 HCI 命令
  交给一个独立栈上的任务（8 KB，从 BLE 的 arena 里分），阻塞走「任务 → 主上下文」的正常切换，主上下文每轮泵 controller
  任务、再恢复发送任务；等发送与等回包按时间与轮数双重封顶。广播实验另写一份落盘记录（flash `0x18E000`，`markerWrite`；
  主机侧 `tools/ap-side/decode-adv-marker.py` 解码）。`components/osal/src/osal.zig` 多两个记录变量（任务最近一次停在哪个
  等待原语上），等待的语义没有动。
- **验证**：主机测试 41/41 步通过；`check-host` 5/5（firmware 2068）。板上七次（`-Dcoex-ble-adv`，发送任务）：`0x2006` /
  `0x2008` 都回了 Command Complete、Status 0x00，`0x200A` 的回包在带落盘记录的几次里也回了（上一版停在第一条命令上）。
  广播使能被接受之后主上下文回不来：串口停在回包行的一半，回包之后那次 flash 写不返回（落盘前回写泵的门控字与
  SYS_TIMER 时钟使能、再补上单独探针第 112 轮的整套时钟字，记录都停在"正要发"）；把这次 flash 写去掉、等待再按 CPU
  周期封顶之后，AP 一侧仍然没有第二次关联，monitor 上板子的帧到第一次断开为止。工作站蓝牙扫描七次（150–220 秒，各看到
  12–16 台别的设备）没有看到板子。日志 `logs/coex-merged-wifi-link-ble-adv2-boot.log`、
  `logs/coex-merged-wifi-link-ble-adv4-boot.log`、`logs/coex-merged-wifi-link-ble-adv4-marker.txt`、
  `logs/coex-merged-wifi-link-ble-adv5-marker.txt`、`logs/coex-merged-wifi-link-ble-adv{6,7,8}-ap-syslog.log`、
  `logs/coex-merged-wifi-link-ble-adv{7,8}-ap-frames.log`、`logs/coex-merged-wifi-link-ble-adv8-boot.log`。细目在
  `docs/verification/coex-verification.md` §17。
- **没有做的**：两个射频都在收发（广播没有起来；广播使能被接受之后 controller 任务不再让出，合成器锁没锁没有读到）；
  BLE 的 disable 路径；「BLE 先起」的顺序；板子回别人的 ping。
- **2026-11-27 更新**：「没有做的」里的第一条当晚查到了根因，见下一节。

## 合并镜像里 BLE 的广播上了空口：根因是中断风暴（2026-11-27）

- **做了什么**：广播使能之后板子失声，不是 controller 任务不让出，也不是 blob 把时钟门控掉：blob 在 enable 里调 `intr_alloc(124)`
  时，`bringup.zig` 的 `intrArm` 把中断桥登记进 trap 分发表用的下标是 CLIC 输入号 24，而分发器按外部中断号（输入号减 16）
  查表，查的是 8——永远查不到。泵每一轮都开着输入 24 的 IE，广播使能一处理，BT MAC 的电平中断进来，查不到 handler 就返回，
  `mret` 之后立刻再进：中断风暴，主上下文一个指令也执行不到。修法一行（`setHandler(routed_input - 16, …)`）；合并镜像多一条
  判据核对中断桥登记在分发器查的那个下标上，收尾多打一行中断桥的计数。为找根因临时加的 STORE 观察点（`-Dcoex-adv-watch`）
  及其配套已删；`-Dcoex-adv-irq` 的中断探针留着。
- **怎么找到的**：先按上一节留的两条路各做一遍——在 UART0 与 SYSTIMER 的时钟控制字上武装数据观察点（带自检），广播使能之后
  零命中，「时钟门控」在合并镜像里排除；给 trap 处理器挂每个中断调一次的钩子，看到只有输入 24 在涨、累计上千万次。最后在
  最终代码上补单变量对照：只把登记下标改回 24，`handler 0x00000000 ok=0`、风暴照旧；改回去，27/27。两次镜像的源码只差这一行。
- **验证**：主机门禁（`scripts/check-all.sh`：fmt、yaml、不变量、单元测试、覆盖率、容量、e2e host）退出 0。板上
  （`-Dcoex-ble-adv`）：合成器锁定位在广播使能后 35 ms 置位、15 秒后仍是它；中断桥 15 秒里入环 951 次、代跑 950 次，代跑的
  都是 blob 经 `intr_alloc(124, …)` 登记的 ISR（纯计数桩 0 次）；Wi-Fi 在 BLE 广播着的时候连上真实 AP、DHCP、ping 10/10
  （往返平均从 3.5 ms 涨到 45 ms）；AP 侧记到第二次关联与四次握手；工作站 `bluetoothctl scan on` 看到 `s31`。日志
  `logs/coex-merged-wifi-link-ble-adv-storm-boot.log`（对照）、`…-ble-adv11-boot.log`、`…-ble-adv12-boot.log`、
  `…-ble-adv13-boot.log`（最终代码）、`…-ble-adv11-ap-syslog.log`、`…-ble-adv11-ap-frames.log`、`…-ble-adv11-bt-scan.log`。
  空口上的广播本身（工作站 `btmon` 记 HCI 事件）：两条广播上报——`ADV_NONCONN_IND`、Public `02:00:00:00:BB:01`、Flags 0x06 加名字
  `s31`，RSSI -51 / -25 dBm（`logs/coex-merged-wifi-link-ble-adv14-btmon.txt`）；间隔——19 段相邻上报每一段都是 100 ms 加
  advDelay 的整数倍，空口上是 100 ms（`logs/coex-merged-wifi-link-ble-adv15-advinterval.txt`）；配方在
  `tools/ap-side/README.md` 的「蓝牙一侧」。
  另一条记录路也走通了：工作站的静态 tcpdump 换成带 `BLUEZ_INCLUDE` 的构建后认得 `bluetooth-monitor` 接口，ble-adv16 轮
  把 HCI 监视流记成 pcap（145 秒 2841 包），`tools/ap-side/pcap-bt-adv.py` 读出来：板子地址 47 条上报、40.7 秒，46 段相邻
  间隔里 45 段是 100 ms 加 advDelay 的整数倍，与 btmon 的读数一致（`logs/coex-merged-wifi-link-ble-adv16-tcpdump-pcap.txt`）。
  同一份构建还给 tcpdump 打了打印机补丁（`tools/ap-side/tcpdump-4.99.6-bt-monitor.patch`），ble-adv17 轮它自己把板子地址的
  42 条上报打成一行一条（41.5 秒，41 段相邻间隔全部是 100 ms 加 advDelay 的整数倍）；装着的最终版又量了一轮（ble-adv18：
  1817 包里 45 行、41.1 秒，44 段全部是），入库的就是这些行（`logs/coex-merged-wifi-link-ble-adv17-tcpdump-print.txt`、
  `logs/coex-merged-wifi-link-ble-adv18-tcpdump-print.txt`）。
  单独的 BLE 探针修前修后各跑一轮（`logs/bt-probe-clock-union-boot.log`、`logs/bt-probe-bridge-index-boot.log`），逐段相同。
  细目在 `docs/verification/coex-verification.md` §17.5 与 `components/bt-blobs/README.md` 轮 167。
- **没有过的**：ADR-003「核真的在仲裁」的两条判据——五个硬件定时器在每个时点都是 `en=0`、相隔 1 ms 的两次读数相同；
  三组状态位（`coex_status_get` 的 wifi / ble / bt 位图，读数行里现在一并打印）对不上名字，含义没有弄清。这一轮只算
  「两个射频同时开着」。【2026-11-27 上午更正】状态位那一条是读法错了（`coex_status_get` 不是读字），现在直接读出来是过的；
  硬件定时器改成链路的每一泵步采一次，仍然没看到——见下一节。
- **没有做的**：按广播间隔（20 / 100 / 1000 ms）各一轮的时延与丢包【2026-11-27 上午做了，见下一节】、PTI 行为、两侧的 start 回调（路线图 C7 的其余
  判据）；单独的 BLE 探针那边的 synth 墙（不是这个风暴，根因未知）；`osi_impl.zig` 的 `shellSetIsr` 里 blob 传的编号是
  哪一种（同类的一处，还开着）；可连接广播与 GATT；更长时间的稳定性（广播从使能起到 section 结束约 45 秒，没有发广播
  关闭命令）；广播地址还是回退的 `02:00:00:00:BB:01`（空口上量到的间隔只是 0x00A0 这一个配置）；BLE 的 disable 路径；「BLE 先起」的
  顺序；板子回别人的 ping。

## L4b 第一组：按广播间隔量 ping，外加核不启动的对照（2026-11-27 上午）

- **做了什么**：合并镜像加两个构建参数——`-Dcoex-adv-interval-ms`（BLE 广播间隔，默认 100）与 `-Dcoex-adv-pings`（每遍 Wi-Fi 链路
  ping 网关的帧数，默认 10；链路探针的 ping 帧数由 `link_probe.ping_count` 给，探针镜像里仍是 10）；合并 section 多两组读数：
  链路的每一泵步采共存核 5 个硬件定时器的使能位（`firmware/src/coex_merged.zig` 的 `sampleHwTimers`），以及 controller 经胶水
  置 / 清的状态字的镜像（`radio-coex/src/glue.zig` 的 `bt_status_words`，`coexReadings` 里多一行 `status words:`）。
  `tools/ap-side/collect.sh` 的 MON 模式修了 wiphy 名字的拼法（此前仓库这一版建不起 monitor 接口）。
  `tools/ap-side/pcap-bt-adv.py` 加 `--report-slot-ms`（相邻上报的间隔逐段核对，比 30 ms 分组阈值短的间隔要用它）。
  上板四轮：20 / 100 / 1000 ms 各一轮，外加 100 ms 的「核不启动」对照（`-Dcoex-sw-off`）。
- **验证**：主机门禁 `scripts/check-all.sh` 退出 0（单元测试 2068 项，覆盖率 100%）。板上四轮都只编合并这一段
  （app.bin 1 238 960 字节）：20 ms 与 100 ms 两轮 31/31、`verdict=pass`；1000 ms 那轮 30 过 1 没过（扫描灵敏度那条：8 对 19，
  与 `ble-adv10` 同一种环境波动）；对照轮 28 过 3 没过（核不在的那三条，是对照本身）。三路取证：板侧串口、AP 一侧
  （`collect.sh` 的 MON 模式加站点统计）、工作站上自编 tcpdump 打印的 HCI 流。读数与结论：三个间隔下每遍 30 帧都不丢；
  广播时 rtt 三个间隔几乎一样（最小 27.2 ms、中位 30.5 ms、平均 45–55 ms，对照遍平均 4 ms），「间隔越短 rtt 越大」不成立；
  空口上回显请求到应答中位 0.71 ms、没有重传；核不启动的对照里广播时 rtt 不涨（平均 3.5 ms）——涨在共存路径上，
  核在、BLE 广播时板子的 Wi-Fi 每秒发十几个 QoS Null 帧（平时 1 个），机制没有核对。「核真的在仲裁」两条判据过了一条：
  BLE 的状态字广播时是 `0x0001`；硬件定时器约 3 万次采样里没看到使能。日志
  `logs/coex-merged-wifi-link-ble-intvl{20,100,1000}-{boot.log,ap-frames.log,ap-side.txt,hci.txt}`、
  `…-intvl100-swoff-{boot.log,ap-side.txt}`；细目在 `docs/verification/coex-verification.md` §18。
- **没有过的**：硬件定时器在走（ping 这种流量下核不用定时器；Wi-Fi 有吞吐时没量）。
- **没有做的**：时延涨在哪一段（发之前等、收之后处理晚）与 QoS Null 帧变多的因果；PTI 行为、两侧的 start 回调；可连接广播；
  每个间隔只跑了一轮。

## L4b 第二组与路线图 C8：持续的 Wi-Fi 流量、启动回调、PTI、硬件定时器读法的更正、信道分类（2026-11-27 下午）

- **做了什么**：合并镜像再加三个构建参数——`-Dcoex-adv-ping-interval-ms`（每遍 ping 的间隔）、`-Dcoex-adv-ping-bytes`（载荷字节数）与
  `-Dcoex-ble-chan-class`（广播起来之后发 LE Set Host Channel Classification，第二遍链路之后再用带保留位的图确认 controller 会拒）。
  `coexReadings` 多三行：`start callbacks:`（胶水两个跳板的计数，`radio-coex/src/glue.zig`）、`pti by value:`（每个事件的 PTI 按值计数）、
  `timers in calls:`（核接受申请之后、释放交给核之前直接读定时器寄存器），另有一行栈指针。新模块 `ble-802154/src/channel_class.zig`
  （37 位信道图、按 Wi-Fi 的 2.4 GHz 信道算分类图；期望值来自规范原文、NimBLE 与 802.11-2016，重叠窗口手算，没有差分）与 5 条用例；
  `wifi-blobs/src/data_path.zig` 的回显载荷长度改成参数，多 1 条用例。主机用例 2068 → 2075。
- **验证**：主机门禁全过——`scripts/check-fmt.sh` 313 个文件干净；`check-host.sh` 5/5（`firmware` 2075 项）；`check-invariants.py`、
  `check-coverage.py`（逻辑模块 100% 可达，用例数不低于基线）、`update_matrix.py --check`、分区表、`check-capacity.py`（六个 profile 都在
  基线的容忍之内）、`run_e2e.py --host` 六个 profile 的构建全部 PASS。板上十次，都只编合并这一段：最终镜像（app.bin 1 259 232 字节）
  35/35、`verdict=pass`——每遍 300 帧、间隔 50 ms，对照遍与广播遍都是 300/300，
  广播那一遍 rtt 1.3 / 26.9 / 141.3 ms；载荷 1400 字节同样不丢；两侧的 start 回调在 BLE enable 时各触发一次；PTI 是每个事件的定值
  （e0 = 10、e1 = 5、e3 与 e9 = 7、e10 = 3，其余 1），广播那一遍每一帧带出 e1 / e9 / e0 约 0.9 / 1.0 / 0.7 次向核的申请；核每接受一次
  事件 1 的申请就把定时器 0 装成申请的时长（低 24 位 = 时长 × 0.8）并置状态字的 bit1；信道分类 `00 f8 ff ff 1f` 回 `0x00`、
  保留位置上的图回 `0x12`；主栈高水位 13 520 字节里用到 1 688。日志 `logs/coex-merged-wifi-link-ble-intvl100-ping50ms300-boot.log`、
  `…-intvl100-ping50ms300-1400b-chanclass-boot.log`、`…-intvl100-ping50ms300-final-boot.log`；细目在 `docs/verification/coex-verification.md` §19。
- **收尾**：板子刷回生产镜像。它与父提交 `ad76f7d` 的默认镜像逐字节相同（`app.bin` SHA-256 `4de8ad20…`，
  `docs/verification/README.md`「默认镜像不变」），读回校验通过；自检 7/8，没过的 `net_ethernet` 的 `rx loopback frame` 是板子
  没接网线（`phy-link: up=0`），网线接回后同一条是 `ok=1`。
- **验收里抓到并修掉的两处**：① 硬件定时器的读法读错了地址与位——`coexist_hw.o` 的反汇编里每个定时器 16 个字节在
  `0x2010F400 + 16*idx`，使能位是 `0x2010F408 + 16*idx` 的 bit0；此前读的 `0x2010F040 + 16*idx` 是 `MODEM_LPCON` 的寄存器，
  §17–§18 里「使能位恒为 0」的读数作废。② `coexReadings` 按值拷贝统计结构四份、栈帧 42 KB，把 16 KiB 的主栈溢出 26 KB 进 BLE 堆；
  一版镜像（`…-intvl100-ping50ms300-lockup-boot.log`）因此一次抓取里连崩四次、每次 `CPU_LOCKUP_RESET`（发 `0x2014` 恢复发送任务时 `ra` 是读数行
  的尾巴「0000」），当天的其余几轮也在溢出、只是没踩到致命的字节。改成按指针读之后栈帧 864 B；合并 section 开头把主栈空闲部分涂上
  图案、两处判「栈没碰到栈底」——涂色的第一版用 `@memset`，被 ReleaseSmall 当成死存储整个消掉（带符号表的反汇编里只剩长度的
  计算），一轮读数恒为「0 B left」、两条判据误报，改成 volatile 逐字节写才是真读数。定位靠两样：带符号表构建的反汇编（`addi sp,sp,-256`
  之后紧跟 `sub sp,sp,0xa2b0`）与每个阶段的栈指针读数。
- **没有过的 / 没有做的**：定时器有没有真的在数（没有可读的计数器）；信道分类有没有被 controller 用上（只有不可连接广播）；
  时延涨在哪一段；这一轮没有 AP 侧与空口采集；每个配置只跑了一轮。

## 日志

`logs/` 中是章节时代的板侧原始输出（文件名不改，便于与 `docs/history/BRINGUP-chapter-era.md`
逐条对照）。重构后的新证据使用同样命名规则追加。
