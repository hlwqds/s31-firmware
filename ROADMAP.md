# Roadmap

本仓库是 **Zig × ESP32-S31 系统实现**的唯一开发地。路线图按「可验收的出口条件」组织：
每个阶段结束必须有一条**能在日志或 CI 里指认的证据**，否则不算完成。

- 当前基线：`v0.2.0`（生产结构：单一固件 + 组件；由 `hl-ljj-quartz@32f10c56` 迁出的实现重构而来）
- 状态明细：`SUITE-README.md`、`BRINGUP-2026-11-12.md`
- 工程约定：`AGENTS.md`、`docs/REPO-STANDARDS.md`

## 现状（2026-11-26）

| 能力 | 状态 | 证据 |
| --- | --- | --- |
| 启动链 / 链接布局 / 时钟 / UART / 中断 / 定时器 / Flash / 调度 / 堆栈 / 双核 | 基本可用 | `logs/ch04-boot.log` … `logs/ch15-boot.log` |
| 以太网 MAC/PHY 驱动 | 真链路可用：DHCP → ARP → TCP 握手 → socket 收发，板上 7/7 | `logs/e2e-net-wire-boot.log` |
| IPv4/ARP/ICMP、UDP/DHCP/DNS、TCP、Socket 层 | 真链路已上板（DHCP + TCP + socket） | `logs/e2e-net-wire-boot.log` |
| TLS/HTTP、MQTT/OTA | 离线判定通过；真实链路证据在 ch23 lab（TLS 握手 + HTTPS GET、MQTT、OTA 回滚） | `logs/e2e-tls-boot.log`；`hl-ljj-quartz` 的 `practice/zig-esp32-s31/logs/ch23-*.log` |
| Wi-Fi / BLE / 802.15.4 边界 | 符号取证 + ABI/字节路径自检 | `logs/ch25-boot.log` … `logs/ch27-boot.log` |
| BLE + Wi-Fi 共存（设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`） | 共存 glue 接进两套适配层（`-Dcoex`；对不做 Wi-Fi 收发的镜像默认关），BLE 探针与 Wi-Fi 探针各自带着真核心上板，各带一次不开共存的对照；两棵树同链成合并镜像（`-Dcoex-merged`）并上板：8/8 段通过、两个控制器的 init 都返回 0；irom、drom 窗口各扩到 `0x1C0000`，新上限各有一次实板证明。2026-11-26 补上只开 Wi-Fi 的读数（L4a）：共存核开着时真实链路照常，胶水零拒绝，blob 的 13 次申请核都回 `0x102`（这些事件在核的事件表里没有硬件定时器）。同日的不开共存对照把共存核从"可选项"变成前提：关着时扫描 0 个 AP、连接 `reason=201`。合并镜像里的 BLE enable（`-Dcoex-ble-enable`）返回 0，synth 锁定位仍是 0。未做：两个控制器同时工作（L4b）、把 `init_coexist` 从开关后面挪出来、PHY 与时钟归属的寄存器序列、分区表扩大、compiler_rt 死重 | `docs/verification/coex-verification.md` |
| Wi-Fi 与 BLE 的离线可验证特性（按规范条款） | 五批做完不抓空口能验到的全部项。四个纯逻辑组件主机用例 1382 项（`wifi-mlme` 316、`wifi-connect` 432、`ble-802154` 583、`ble-security` 51），与独立参照实现或按原文手排的 oracle 差分一致。`wifi` profile 板级自检 14/14 个 section、整体判决 pass，但那是**第二批的镜像**（`wifi_mlme` 24、`wifi_connect` 87、`ble_802154` 50、`ble_security` 25）；第三、四批的判据当时没有上板。第五批（经独立评审两轮返修后）于 2026-11-25 随 `wifi` profile 上板（第三、四、五批之后第一次）：**整份 14/14 个 section 全过、`main: verdict=pass`**——`wifi_mlme` 121/121、`wifi_connect` 199/199、`ble_802154` 207/207、`net_ethernet` 11/11；用 `--only` 只编两个无线 section 的最小验证镜像（512704 B，整份的 42%）同样通过。还没做的领域按规范列在下面两张盘点表里 | `docs/verification/wifi-ieee80211-verification.md`、`ble-core-verification.md`；`logs/e2e-wifi-boot.log` |
| 对真实 BLE controller 的 HCI 一致性自检（不抓空口） | 板上发 26 条只读命令：20 条合规，6 条与 Bluetooth Core 5.4 不一致（2 条声明不支持却回成功、3 条声明支持却回 `0x0C`、1 条声明不支持却回 `0x0C` 而不是 `0x01`）；与 controller 配置的关系未验证 | `logs/hci-conformance-boot.log`；`docs/verification/ble-core-verification.md` §8 |
| 真实 Wi-Fi blob（`components/wifi-blobs`） | **init 返回 0**；任务体可跑并合作式让出；**主动扫描上板**（2026-11-26）：约 9.1 s 走完全部信道，取到 38 条真实记录（BSSID、SSID、信道、RSSI、authmode），与同板官方 IDF 同一时段的结果逐 AP 对照一致；**连上真实 AP 并在 IP 层收发**（2026-11-26，WPA2-PSK + CCMP-128）：`STA_CONNECTED` 约 3.0 s，MAC 密钥表里的钥匙与请求方手里的逐字节相同，DHCP 拿到地址，ping 网关连续 4 轮 10/10。以上都开着共存核（`-Dcoex`）：关着时扫描 0 个 AP，它是收发的前提 | `logs/wifi-init-ok-boot.log`、`logs/wifi-task-boot.log`、`logs/wifi-link-scan-boot.log`、`logs/wifi-link-connect-boot.log`（邻居的 SSID 与 BSSID 已脱敏）、`logs/wifi-link-nocoex-boot.log`（不开共存的对照） |
| 选槽/回滚/功耗/性能模型（28A） | 板侧自检通过；计量与 28B 未做 | `logs/ch28-boot.log`、`logs/ch28a-boot.log` |
| 生产化原型的宿主测试（netmgr/ota/provisioning/recovery） | 通过 | 15/15、8/8、18/18、9/9 |
| CI / 发布 / 版本标签 | CI 已建立（host、image、e2e 三个 job），主干全绿；发布与标签未做 | GitHub Actions：`0c94442` 三个 job 均 success |

## 工作流（Workstreams）

| ID | 主题 | 目标 |
| --- | --- | --- |
| W1 | 链路闭环 | 打通 ch17 的 ref clock → TX/RX 复位时钟 → MDIO，随后补齐 ch18–ch24 的真链路验收 |
| W2 | 生产化组件 | netmgr / OTA / provisioning / recovery 从原型走到可集成（接口冻结、共享 KAT、HIL 回归） |
| W3 | 工具与 HIL | baseline 清单、HIL 台架、一键构建/烧录/取证流水线 |
| W4 | 自举与计量 | 28B Zig 二级 bootloader；真实电流/唤醒/频率测量 |
| W5 | 工程发布 | CI、版本与变更日志、发布包（源码 + 镜像 + 证据） |

## 阶段与出口条件

### P0：仓库工程化（v0.2.0）

- [x] 生产结构：`firmware/` + `boards/` + `components/`（章节目录移除，历史见 `docs/HISTORY.md`）
- [x] 编译期特性开关：`-Dboot/-Dnet/-Dtls/-Dapps/-Dwifi`，未启用组件不参与编译
- [x] 板侧联调：默认配置（boot+net）烧录通过，聚合 `firmware: sections: passed=8 failed=0 total=8`（`net` profile，含 `posix`）、`main: verdict=pass`（`logs/firmware-boot.log`）
- [x] 聚合测试：`firmware` 的 `test` step 覆盖 **19 个测试项目（2064 项）**（含 `posix`）
- [x] 脚本：`scripts/check-host.sh`、`scripts/check-fmt.sh`、`scripts/build-image.sh`、`tools/capture.py`
- [x] CI 定义：host / image 两个 job；板级 job 为自托管手动触发
- [x] 覆盖率门禁：`scripts/check-coverage.py`（逻辑模块 100% 可达 + 用例数基线）
- [x] E2E：`tests/e2e/run_e2e.py`（profile 构建/两段镜像 + 板级自检，JUnit 输出）
- [ ] 组件去重：11 份组件内 `hw.zig`/`log.zig` 副本收敛到 `boards/`（配合 `scripts/check-board-sync.sh` 漂移检查）
- [ ] 分支保护与远端：`main` 只接受 PR；发布用 tag
- [x] **P0.2 镜像窗口扩容**：irom/drom 各 0x7F000，drom 基址移至 `0x40080020`（页偏移仍 0x20），
  TLS/Wi-Fi 全特性单镜像可链接并在板上跑通 11 段；`image-info` 仍恰好两行
- **出口**：主分支一次绿色 CI 运行；从零克隆后按 README 能在 10 分钟内跑通主机测试与镜像构建

### P1：以太网闭环（W1，v0.3.0）

- [ ] 证明 ref clock 真实频率（MPLL 配置/计量 GPIO13）
- [ ] `rst_clk_tx_n` / `rst_clk_rx_n` 由 0 变 1，SWR 自清
- [ ] MDIO 扫到 PHY（ident ≠ 0x0000/0xFFFF），读出 OUI/model
- [ ] ARP/ICMP 跑通（ch18 真链路），DHCP/DNS 在 ch19 复验
- **出口**：`ch17` README 的「未闭环」段替换为实测记录；ch18/ch19 各有一份 `logs/chNN-wire-*.log`

### P2：应用层真链路（W1/P2，v0.4.0）

- [ ] TCP 三次握手 + echo（ch20），抓包对照状态机
- [ ] 吞吐/时延曲线（ch21），与模型/仿真同图对照并注明差距
- [ ] socket 事件循环接真实链路（ch22），长连接与背压
- [ ] TLS 1.3 握手 + HTTPS GET（ch23）；MQTT broker 连通与 QoS1/2（ch24）
- **出口**：每项一条可复跑命令 + 一份日志；未能达标项要有明确的阻塞说明

### P3：Wi-Fi 与生产化（W2/W3，v0.5.0）

- [ ] WPA2 4-way 与 SAE 在真机跑通（ch26）；BLE/802.15.4 至少一条真实收发（ch27）
- [x] 共存 glue：`components/radio-coex` 对照 IDF 逐钩子验证（L1），在 `-Dcoex` 开关后接入两套 blob 适配层，默认镜像逐段不变（L2）。已完成 2026-11-24（路线图 C1、C2）：主机用例逐钩子与 IDF 源码一致；开着时三种 coex 镜像链接通过，关着时四种镜像与改动前逐字节相同
- [x] 共存的运行时统一、窗口扩大、合并镜像启动（L3，不抓空口）。已完成 2026-11-24（路线图 C3、C4）：合并镜像上板 8/8 段通过、`esp_wifi_init_internal rc=0`、`bringup.init rc=0`。分区表经实测不需要扩（init 级合并镜像 1 117 376 B，装得下 factory 分区），偏离记在 ADR-003 第 3 节
- [x] Wi-Fi 与 BLE 的离线可验证特性按条款落地，每项有按条款组织的验证报告（`docs/verification/`）。已完成 2026-11-24，分两批；清单见下文「无线特性路线图」。对真实 controller 的 HCI 一致性自检给出的是不通过的结果（26 条里 6 条与 5.4 不一致），报告如实记录
- [ ] 生产化四切片接口冻结（v1 ABI），共享 KAT 向量，HIL 回归脚本可无人值守跑
- [ ] baseline 清单 + HIL 台架接入 CI（自托管 runner）
- **出口**：HIL 跑一轮全绿并归档日志；接口变更需 ADR；离线可验证特性的验证报告齐全，未做的项在报告里写明原因

### P4：自举、计量与发布（W4/W5，v1.0.0）

- [ ] 28B：Zig 二级 bootloader 可选实现（镜像头/分区/选槽/校验/救援）
- [ ] 真实电流、唤醒时间、频率切换测量，替换 ch28 的模型值
- [ ] 发布包：`s31-firmware-vX.Y.Z`（含镜像、日志摘要、复现命令、SHA256）
- [ ] CHANGELOG 与升级说明；破坏性变更给出迁移指引
- **出口**：外部使用者按发布包能在同型号板卡复现「构建 → 烧录 → 自检通过」

## 里程碑与版本

| 版本 | 内容 | 阻塞项 |
| --- | --- | --- |
| v0.1.0 | 迁出快照（历史） | — |
| v0.2.0 | P0 工程化 | 无 |
| v0.3.0 | P1 以太网闭环 | ref clock / MDIO |
| v0.4.0 | P2 应用层真链路 | 依赖 v0.3.0 |
| v0.5.0 | P3 Wi-Fi + 共存 glue + 离线可验证特性 + 生产化 | 依赖 v0.3.0；真实射频收发依赖 R3.1、R3.3 |
| v1.0.0 | P4 自举/计量/发布 | 依赖 v0.4.0、v0.5.0 |

## 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| ch17 时钟/PHY 问题长期无解 | P1 之后全部阻塞 | 独立时间盒实验；每轮只改一个变量并留日志；必要时换板/换 PHY 验证 |
| 硬件只有一块板 | 并发开发互相踩串口 | `flock` 串行 + 自托管 HIL runner 排队 |
| 生产化原型与章节工程重复实现 | 双份逻辑漂移 | 以 `tools/s31-production` 为实现源，章节工程只保留教学版本；共享 KAT |
| 计量设备缺失 | 功耗/性能无法验收 | v1.0 前只声明模型值；计量到位后再改结论 |
| 无远端备份 | 单机丢失 | P0 完成前先加远端并开分支保护 |
| 两套 blob 适配层按构造互斥（同名导出、各占整块堆、同抢 tick、两个上下文切换器） | 共存镜像无法链接或启动 | 按 ADR-003 第 2 节做运行时统一，放在 `-Dcoex` 开关后，并用逐段 SHA-256 证明默认镜像不变 |
| 把主机测试通过当成"无线功能可用" | 路线图状态失真 | 每项特性标注验证级别；L1、L3 通过的只能写"离线验证通过"，真实收发只在 L4 证据出现后记为完成 |

## 不在本仓库范围

教程正文、站点构建、博客链接策略属于 `hl-ljj-quartz`；本仓库只在发布说明里引用对应章节。

## 无线特性路线图（按规范组织）

规范口径：Wi-Fi 与 BLE 都**不是 RFC 所定义的**——Wi-Fi 取 **IEEE Std 802.11-2016**（条款号取自该版目录），BLE 取 **Bluetooth Core Specification 5.4**（按卷、部分、节引用）。RFC 只在其上单列：RFC 7668（IPv6 over BLE）、RFC 3394（AES Key Wrap，WPA2 的密钥封装）、RFC 4493（AES-CMAC）、RFC 3610（AES-CCM）、RFC 6070（PBKDF2）、RFC 4231（HMAC 的测试向量）；第三批另涉 RFC 8110（OWE）、RFC 5869（HKDF）、RFC 5903 与 RFC 6090（ECC 的 Diffie-Hellman）、RFC 5216 与 RFC 3748（EAP-TLS 与 EAP）、RFC 2409 与 RFC 3526（MODP 群参数）；第四批另涉 RFC 8930 与 RFC 8931（6LoWPAN 的分片转发与选择性分片恢复）、RFC 4861 与 RFC 4862（RFC 6775 所依托的邻居发现与地址自动配置）。第五批的 Wi-Fi 与 BLE 三片都不涉新 RFC；BLE 的 IsoHci 一片引了 Bluetooth SIG 的 Assigned Numbers §2.11。

验证分级沿用 `docs/REPO-STANDARDS.md` §4：L1 主机、L2 镜像、L3 板侧自检、L4 真链路（抓空口）。验证某一批改动时用 `tests/e2e/run_e2e.py --board --profile wifi --only <section,…>`（构建期经 `firmware/build.zig` 的 `-Donly` 只编涉及的 section，最小验证镜像约是整份的 42%）；整份 profile 的运行留给发布前门禁。**Wi-Fi 通到了 IP 层的 ping，BLE 还没有端到端跑通**（Wi-Fi 的 blob 移植 2026-11-25 起能从 `esp_wifi_start` 返回、2026-11-26 起能扫描到真实 AP，并连上一台真实 AP 做 DHCP 与 ping 网关——只有 WPA2-PSK 一种配置，见验证报告 §9–§11；BLE 的射频 synth 不锁），所以这张路线图按"不抓空口能验到哪一级"排序：第一、二批 L1 到 L3 的项已于 2026-11-24 做完；第三批与第四批于 2026-11-25 做完，当时只到 L2（对真实 controller 的 HCI 一致性自检结果是不通过；这两批的判据已于同日随第五批的镜像上板、全部通过）；第五批也于 2026-11-25 做完：先验收，再经独立评审两轮（第一轮 Wi-Fi 15 + BLE 7 条、第二轮残留各 6 / 0 条）返修并复验，最后随 `wifi` profile 上板——14/14 个 section 全过、`main: verdict=pass`；L4 抓空口的项等射频打通（厂商栈的最小 station 与本仓库的移植都已在同板连上 AP，见「真实 MAC」行与验证报告 §8、§11）。第四批六项：OWE 的 PMK caching、FT 的 RIC、RM Enabled Capabilities 与 Annex E、WNM 的 TFS 与 Key Data、6LoWPAN-ND 的主机侧行为、分片转发与选择性分片恢复。第五批六项：WNM 的其余子域（BSS Max Idle、TIM Broadcast、FMS、DMS、Collocated Interference、Channel Usage、WNM Notification、Event / Diagnostic 容器、QoS Traffic Capability）、GAS / ANQP、Block Ack 与 A-MSDU 子帧头、PAwR 的三条数据命令与两个事件、Connection Subrating、LE Isochronous 的 HCI 接口面。

证据落在 `docs/verification/`：`coex-verification.md`、`wifi-ieee80211-verification.md`、`ble-core-verification.md`。表里的"状态"只认这些报告里有的证据；第三批各片的用例数、差分与偏离在 `wifi-ieee80211-verification.md` 的 §2、§4.4、§5.4、§6 与 `ble-core-verification.md` 的对应小节，第四批在 §2、§4.5、§5.5、§6 与 `ble-core-verification.md` 的 §4.2、§5.3、§6，第五批在 §2、§4.6、§5.6、§6 与 `ble-core-verification.md` 的 §4.3、§5.4、§6、§7。

### 共存

设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`。

| 项 | 内容 | 不抓空口能验到 | 状态 |
| --- | --- | --- | --- |
| C0 | 调研与设计：共存接口面、容量实测、合并链接实验、非探针闭包链接修复 | L2 | 已完成 2026-11-24 |
| C1 | 共存 glue（`components/radio-coex`）：适配表、24 个 Wi-Fi 钩子、16 个 BLE 钩子、核接口、生命周期 | L1 | 离线验证通过：主机 55 项（glue 45 + 归属模型 10），23 个 Wi-Fi 包装函数与 20 个 BLE 函数对照 IDF 源码逐条一致；板侧自检 10/10（对假核心）；真核心经 C2 上板 |
| C2 | 接进 `wifi-blobs`、`osal`、`bt-blobs`，放在 `-Dcoex` 开关后；默认镜像逐段不变 | L2 | 已完成 2026-11-24：三种 coex 镜像链接通过，四种非 coex 镜像逐字节不变，两块板级实验各带对照（L3） |
| C3 | 运行时统一：一个调度器、一份 osi，导出、堆、tick、trap 钩子各一份 | L2 | 已做到两棵树同链并上板（2026-11-24）：冲突面实测 12 个符号，按「真归档 > 能用的实现 > 计数桩」各留一个提供者（落选方改弱符号）。设计里的「一个调度器 / 一份 osi / trap 钩子多槽」没有做——逐项量过之后不需要，依据见 ADR-003 第 2 节实现记录 |
| C4 | 窗口与分区扩大；合并镜像启动、两个控制器的 init 都返回 | L3 | 已完成 2026-11-24：合并镜像 8/8 段通过，两个 init 都返回 0；irom、drom 各扩到 `0x1C0000`，两侧新上限各有一次实板证明。分区表没有改：init 级合并镜像装得下现有 factory 分区。2026-11-26：合并镜像里 BLE enable 返回 0（`-Dcoex-ble-enable`），没有锁死，synth 锁定位仍是 0 |
| C5 | PHY 与时钟域的归属（启动序列） | L3 | 归属模型已写并主机验证（`radio-coex/src/owner.zig`，10 项）。寄存器序列没有接：要等两个射频各自打通后才能上板验证 |

### Wi-Fi（IEEE Std 802.11-2016）

| 特性 | 条款 | 验证方式 | 不抓空口的上限 | 状态 |
| --- | --- | --- | --- | --- |
| MAC 帧格式与字段 | 9.2.3、9.2.4.1–9.2.4.8 | 字节级已知答案；Annex J.9 的帧 | L3 | 离线验证通过（L1；板侧自检 16/16） |
| 管理帧（Beacon、Probe、Authentication、Deauthentication、Association、Reassociation、Disassociation、Action） | 9.3.3.3–9.3.3.14 | 编解码已知答案 | L3 | 离线验证通过（L1） |
| 信息元素（SSID、速率、DSSS、TIM、Country、RSNE、Extended Capabilities、MMIE 等） | 9.4.2.2–9.4.2.158 的子集 | 解析合成的 Beacon | L3 | 离线验证通过（L1） |
| MLME：认证、关联、去认证、状态机与定时器 | 11.3 | 进程内假 AP 对打，时间注入 | L3 | 离线验证通过（L1） |
| 扫描（被动、主动、信道驻留） | 11.1.4 | 扫描计划的确定性测试 | L3 | 离线验证通过（L1） |
| PSK、PMKID、PTK、GTK 派生 | 12.7.1.2–12.7.1.4；Annex J.3、J.4、J.7 | Annex J 官方向量 | L3 | 离线验证通过（L1；板侧自检 28/28） |
| 4 次握手与组密钥握手（请求方） | 12.7.6、12.7.7、12.7.10；12.7.1.2、12.7.1.3、12.7.2、表 12-8 | 进程内认证方对打；第三批起与 Python oracle 及盘上 hostapd 的代码三方对拍 | L3 | 离线验证通过（L1）。第三批起按 AKM 1–6、8、9、11–13、18 选 PMK 长度、PTK 的 KDF、MIC、Key Data 封装与 Key Descriptor Version（45 项）；AKM 7、10 不支持 |
| 密钥数据封装与 AES Key Wrap | 12.7.2；RFC 3394 | RFC 3394 §4.1 | L3 | 离线验证通过（L1） |
| 安全关联与策略选择 | 12.6.1、12.6.2、12.6.3 | 状态机测试 | L3 | 离线验证通过（L1） |
| CCMP-128、GCMP-128 | 12.5.3、12.5.5 | Annex J.6.4、J.7、J.9.2 | L3 | 离线验证通过（L1） |
| BIP-CMAC-128 与 MMIE | 12.5.4、9.4.2.55 | Annex J.8、J.9.1 | L3 | 离线验证通过（L1） |
| 管理帧保护与 SA Query | 12.2.8、12.6.19、12.6.20、11.14、9.6.10 | 分类表与 SA Query 过程 | L3 | 离线验证通过（L1） |
| SAE：P-256 点运算、PWE 派生、Commit / Confirm、帧体、状态机、群协商 | 12.4；Annex J.10 | J.10 向量与双端对打；15 个群的整链差分 | L3 | 离线验证通过（L1：group 19 的完整实现 31 项，第三批加 15 个群共 67 项，整链差分 1500 组 0 不一致）。2016 的 12.4.4 没有群表，只要求 group 19，群号取自 IANA 注册表。恒定时间与 H2E 未做；FFC 1、22–24、ECC 27、31–34 未做。Password Identifier 与 Rejected Groups 元素不在 2016 正文里，按 hostap 源码实现（后者只做接收的一半）。J.10 的 pwd-value 与 KCK/PMK 三行与 12.7.1.7.2 正文不符，实现按正文走 |
| FT：密钥层次、FT 协议与 RIC | 12.7.1.7、13.4；13.5、13.7、13.8；13.11.2、13.11.3；9.4.2.50、9.4.2.51 | 推导向量（IEEE 没有 FT 派生向量，期望值取自独立实现）；三方进程内对拍与整帧差分；带 RIC 的完整交换对独立 Python oracle | L3 | 离线验证通过（L1：密钥层次 24 项；第三批加 MDE / FTE 编解码、over-the-air 与 over-the-DS 的认证序列、reassociation，64 项，整帧差分四个种子各 12000 帧 0 不一致；第四批加 RIC：RDE 与 Block Ack 的 RIC Descriptor 编解码、一条 RIC 的结构规则、进重关联帧的条件，18 项，over-the-air 与 over-the-DS 各一条带 RIC 的完整交换对 oracle 逐字节一致）。未做：R0KH 与 R1KH 之间的协议（13.10）、13.9 的状态机、13.6 的资源请求协议、QoS 描述符与 AP 的准入决策 |
| CCMP-256、GCMP-256、BIP-256 | 12.5、12.7.2、12.7.3；表 12-4、12-8 | Annex J.6.4、J.11 #3、J.9.1；与独立参照实现全量差分 | L3 | 离线验证通过（L1 23 项；全量差分 3568 条向量 0 不一致）。BIP-CMAC-256 没有官方向量 |
| QoS 与省电 | 9.2.4.5、9.4.2.29、9.4.1.17、10.2.4.2、11.2 | 编解码；STA 与 AP 两个进程内模型对拍 | L3 | 离线验证通过（L1 19 项：QoS 10、省电 9；板侧判据含在 24 条里，第五批之后 `wifi_mlme` 共 121 条，2026-11-25 上板 121/121 全过）。不做 EDCA 竞争与队列调度 |
| OWE（RFC 8110）：群 19 的 ECDH、DH Parameter element、PMK / PMKID 派生、与 4 次握手的衔接、PMK caching | RFC 8110 §4.1–§4.5；RFC 5869、RFC 5903、RFC 6090；802.11-2016 12.6.3、9.4.2.25 | RFC 5869 与 RFC 5903 的测试向量；与 Python oracle 及盘上 hostap 的代码差分（800 组）；PMK caching 的线上行为按 RFC 原文逐条用例，缓存管理策略对 Python 模型 800 组 | L3 | 离线验证通过（L1 30 项 + 第四批 25 项）。第四批加 §4.5 的 PMK caching：请求里同时带 PMKID 与 DH Parameter element、AP 命中与未命中、client 命中 / 回退 / 忽略三种处理。§4.5 没有规定缓存的有效期与替换策略，实现取自盘上 hostap 的 `pmksa_cache.c`，期限常量取 802.11-2016 的 `dot11RSNAConfigPMKLifetime`。只做 group 19。OWE Transition Mode 不在 RFC 8110 里（它出自 Wi-Fi 联盟的 OWE 规范，盘上没有原文），未实现 |
| EAP-TLS（RFC 5216 / RFC 3748）：EAP 头、Identity / Notification / Nak、分片与重组、MSK → PMK | RFC 3748 §4、§5；RFC 5216 §2.1、§2.3、§3；802.11-2016 12.7.1.3 | 按条款手排的已知答案；独立分片器差分（1200 条记录流、4096 组 MSK） | L3 | 离线验证通过（L1 34 项）。TLS 引擎由调用方注入，仓库不含 TLS 本身 |
| 无线测量：Measurement Request / Report、Beacon report、Link Measurement、Neighbor Report 响应；RM Enabled Capabilities 元素；Annex E 的 Operating Class 映射 | 11.11.4、11.11.6、11.11.9.1、11.11.10.3、11.11.13；9.4.2.17 / .21 / .22 / .36–.38 / .41 / .45；9.6.7；17.3.8.4.2、20.3.1、Annex E | 图逐字节手排；与 hostap 头文件的布局差分（每个种子 12000 帧）；Annex E 的表对按表手排的 oracle（516 行向量） | L3 | 离线验证通过（L1 32 项 + 第四批 16 项）。第四批加 RM Enabled Capabilities 元素（9.4.2.45，元素 ID 70）与 Annex E 的 Operating Class 表和查询（106 行：全球 41、美国 21、欧洲 15、日本 17、中国 12；中心频率按 17.3.8.4.2 与 20.3.1 两个公式），Beacon request 的 Operating Class / Channel 校验接进判决。量测本身未做；ITS 5.9 GHz、美国 4.9 GHz 公共安全、日本已废弃行、DMG 地区类不收录 |
| WNM：BSS Transition Management、WNM Sleep Mode、TFS 与 Key Data | 11.24.7、11.24.12；11.2.3.18；9.6.14.8–.10、9.6.14.15–.20；9.4.2.31、9.4.2.33、9.4.2.80、9.4.2.81、9.4.2.82 | 图逐字节手排；按原图排帧的 oracle 差分（BTM 与 WNM Sleep 每个种子 9000 帧；TFS 与 Key Data 三个种子各 310 例、一组 930 例） | L3 | 离线验证通过（L1 30 项 + 第四批 36 项）。第四批加 TFS（11.24.12：TCLAS 八种分类器、TFS Request / Response / Notify 帧、AP 侧与 STA 侧模型、过滤匹配）与 WNM Sleep Mode Response 的 Key Data 布局。Key Data 的真实加密是注入点，本组件只用测试替身验证；IDF 里的 hostap 把这两块裁掉了，没有独立实现对拍。第五批加其余子域：BSS Max Idle（含保活判决，余量由调用方注入）、TIM Broadcast、FMS、DMS、Collocated Interference（含占空比）、Channel Usage、WNM Notification、Event / Diagnostic 容器与 QoS Traffic Capability 元素（`wnm.zig` 第 15–24 节），39 项主机用例、31 条板侧判据（2026-11-25 上板 121/121 全过）；独立评审发现 CI Report 元素宽度与原图 Figure 9-427 不符（元素体 21 八位组，P1）等 12 条，已返修并复验；没做的边界见 `wnm.zig` 文件头（FMS Descriptor 元素 ID 86、WNM Notification 的 AP Descriptor / Firmware Version 子元素内容、FTM / Timing Measurement、Location track、Proxy ARP、AC Station Count 等非目标）；取舍与偏离清单见文件头与验证报告 §6 |
| TKIP、WEP | 12.5.2、12.3.2 | 不做 | — | 不做：pre-RSNA，已弃用 |
| Block Ack：ADDBA / DELBA 帧编解码、记分板位图语义、接收重排缓冲（第五批） | 9.3.1.8–.9、9.4.1.14–.16、9.4.2.139、9.6.5.2–.4、10.24.1–.2 / .4 / .7.3 / .7.5–.6、11.5.2–.4 | 按条款手排的已知答案；照同一份规范写的 Python 模型对拍（4 × 240 随机 + 256 条确定性边界 = 1216 例，0 不一致）；窗口边界对渲染 PDF 的原文逐格核对 | L3 | 离线验证通过（L1 38 项；板侧 19 条，2026-11-25 上板，`wifi_mlme` 121/121 全过）。只做 Basic 与 Compressed 变体（Extended Compressed / Multi-TID / VHT 1024 位 / Multi-STA / GCR 不做）；`SN = WinStart + 2^11` 的归属经渲染 PDF 更正（10.24.7.3 / .6 的严格小于）。A-MPDU、每帧的确认时序与聚合传输未做。独立评审（2026-11-25）对本片逐条核对、无发现 |
| A-MSDU 子帧头（第五批，随 Block Ack 一片） | 9.3.2.2 | 逐字段已知答案 | L3 | 部分做了：子帧头编解码已实现（Length 的大端序只有规范依据，内核只有头文件，没有第二实现对拍）；A-MPDU 分隔符、链路上的聚合传输与填充（10.5–10.6、10.13）未做 |
| GAS / ANQP 与 Interworking（第五批） | 9.6.8.12–.15、9.6.8.1（Table 9-307）、9.4.2.93、9.4.5（ANQP 元素）、11.25.3.2.2–.4、11.25.3.3、9.4.1.9、9.4.1.12、9.4.1.34 | 按条款手排的已知答案；照同一份规范写的 Python 模型对拍（696 例：接受 563 / 拒绝 133，0 不一致） | L3 | 离线验证通过（L1 36 项；板侧 13 条，2026-11-25 上板 121/121 全过）。请求方（STA 侧）Initial 与 Comeback 的分帧、Comeback 状态机与 `dot11GASResponseTimer`；ANQP 元素子集（NAI Realm 等按图 9-606 顺序）与 Emergency Call Number（9.4.5.5，独立评审指出静默缺口后补）。不做：Annex R、RLQP、多 BSSID、响应方 / 服务器侧、Protected Dual of Public Action、ANQP 厂商元素内容、3GPP Cellular Network（原样透传）。Status Code 字段 2 八位组按 9.4.1.9；独立评审的失败路径 / 空列表 / 分方向三处已返修 |
| 真实 MAC：`esp_wifi_start`、扫描、连接 | 不适用 | 抓空口 | L4 | 官方 IDF 的最小 station 已在同一块板上连上用户提供的 AP（L4，厂商栈）：关联、WPA2-PSK、DHCP、ping 网关 5/5（`logs/wifi-idf-oracle-sta.log`、`tools/wifi-idf-oracle/`、验证报告 §8）；`s31-firmware` 自己的 Zig 移植 2026-11-25 起能从 `esp_wifi_start` 返回（L3，`logs/wifi-probe-start-rc0-boot.log`、验证报告 §9），2026-11-26 起能扫描到真实 AP（真射频收发已通；证据是与同板 oracle 逐 AP 对照，没有抓包：oracle 同一时段看到的 8 个 AP 里 7 个出现在本镜像的结果里、信道 / authmode / SSID 一致，第 8 个那一轮没扫到；`logs/wifi-link-scan-boot.log`、验证报告 §10），同日起能连上真实 AP 并在 IP 层收发（WPA2-PSK + CCMP-128：`STA_CONNECTED` 约 3.0 s、MAC 密钥表核对一致、DHCP、ping 网关 10/10；`logs/wifi-link-connect-boot.log`、验证报告 §11），只有这一种配置 |

#### 尚未实现的领域（按 IEEE Std 802.11-2016 的目录盘点，2026-11-25）

上表每行末尾的「未做」之外，下面是 802.11-2016 里还没进上表的 host 侧领域。锚点是 `/tmp/spec/802.11-2016.txt` 的正文行号，
条款号取自该版目录；离线可验证的范围都能按原文手排期望值。整体不是 host 侧、不列的章：第 15–22 章（各 PHY）、第 8 章（PHY 服务）、
第 5–7 章（服务与管理原语）、第 4 章（概念描述）、第 14 章（mesh，与 S31 的 STA 形态不符）。都未排期。

| 领域 | 原文锚点 | 离线可验证的范围 | 必须真射频 / 真 MAC 的部分 | 现状与依赖 |
| --- | --- | --- | --- | --- |
| Block Ack：ADDBA / DELBA、记分板、接收重排缓冲 | 9.3.1.8–.9；9.4.1.14–.16；9.4.2.139（58039）；9.6.5（62513）；10.24（74012）；11.5（87835） | 帧编解码、记分板位图语义、重排缓冲（时间注入） | 每帧的确认时序与聚合传输 | **第五批已做**（`blockack.zig` 及其测试与子自检）：编解码、记分板、重排缓冲；只做 Basic 与 Compressed 变体，A-MPDU 与确认时序未做（见上面特性表） |
| A-MSDU / A-MPDU 聚合与分片重组 | 9.3.2.2；10.5（70311）；10.6（70348）；10.12（71468）；10.13；Annex O.2 | 子帧头、分隔符、分片与重组 | 链路上的聚合传输与填充（10.13.6 依赖 PHY） | **部分做了**：A-MSDU 子帧头（9.3.2.2）第五批随 Block Ack 一片实现；分隔符、分片与重组、聚合传输未做 |
| GAS / ANQP 与 Interworking（通用广播服务） | 9.4.5（60649 起）；9.6.8.12–.15；11.25.3（95017）；Annex R（188537） | ANQP TLV 编解码、GAS Initial / Comeback 分帧与 comeback 状态机 | 无 | **第五批已做**（`gas.zig` 及其测试与子自检）：请求方 Initial / Comeback、ANQP 元素子集；不做 Annex R、RLQP、多 BSSID、响应方 / 服务器侧等（见上面特性表） |
| WNM 的其余子域：TIM Broadcast、FMS、DMS、BSS Max Idle、Collocated Interference、Channel Usage、Event / Diagnostic | 11.24.2、11.24.3、11.24.9、11.24.13（94196）、11.24.15、11.24.16；9.6.14.11–.12、9.6.14.21–.25；9.4.2.75–.77、9.4.2.83–.84 | 帧 / 元素编解码与请求—响应状态机 | 无（量测数据来源除外） | **第五批已做**（`wnm.zig` 第 15–24 节及两个新测试 / 子自检文件）：上列子域加 WNM Notification 与 QoS Traffic Capability；取舍与偏离见 `wnm.zig` 文件头清单 |
| FT 的安全架构状态机与 RRB（Remote Request / Response） | 13.9（109359）；13.10（110029） | 四个 KH 的状态机、RRB 帧编解码（over-the-DS 路径） | 无（STA 只涉及 S0KH / S1KH 与 RRB 透传） | 未做。依赖已做的 FT 密钥层次与 over-the-DS 序列 |
| RSNA 的 PMKSA 缓存与预认证（PSK / SAE 路径） | 12.6.10（103625）、12.6.10.2、12.6.10.3 | PMKSA 生命周期、命中走 4 次握手的判决 | 无 | 未做。PMKID 的派生与 OWE 的 PMK caching 已做；hostap 的 `pmksa_cache.c` 可对拍 |
| 信道切换的 STA 侧：CSA / ECSA / Wide Bandwidth CSA | 9.4.2.19、9.4.2.53、9.4.2.161；9.6.2.6、9.6.8.7；11.9.9（89081）；11.10 | 元素编解码、切换计数与禁发判决、Supported Operating Classes（9.4.2.54，51319）的通告 | 实际调频、DFS 雷达检测（11.9.4–.6） | 未做。Annex E 的映射第四批已做，与之互补 |
| TS / TSPEC：ADDTS / DELTS、TS 生命周期 | 9.4.2.30–.34；9.6.3；11.4（86849）；Annex K（186487） | TSPEC / TCLAS / Schedule 编解码、TS 状态机 | HCCA 的准入与调度 | 未做。与「不做 EDCA 竞争与队列调度」的现有决策冲突，立项前先重估 |
| Multi-BSSID | 9.4.2.46（50951）、9.4.2.72、9.4.2.74；11.1.3.8；11.11.14 | Nontransmitted profile 的展开（对合成 Beacon 手排） | 无 | 未做。与扫描（`scan.zig`）衔接 |
| 跨监管域操作与 Operating Class 通告 | 10.21（71925）；9.4.2.54（51319）；Annex E（178239） | Supported Operating Classes 元素、入域规则（表驱动） | 频段的实际可用性 | 部分做了：Annex E 的表第四批已做，9.4.2.54 元素未做 |
| TPC 的 STA 侧 | 9.4.2.14–.17；9.6.2.4–.5；11.8 | 元素编解码、TPC Report 数值 | 发射功率选择与功率控制 | 未做。Link Measurement 已用到 TPC Report 字段，增量小 |
| Timing Advertisement / UTC TSF Offset | 9.3.3.16；11.22（92049） | 帧体编解码 | TSF 精度 | 未做。很小，可以捎带 |
| SAE 剩余的群（FFC 1、22–24；ECC 27、31–34）与恒定时间实现 | 12.4.4.1、12.4.4.3、12.4.8 | 群参数与 PWE 派生的数学 | 无 | 部分做了：`sae_groups.zig` 有 15 个群，`sae_full.zig` 有 Anti-Clogging Token。H2E、Password Identifier、Rejected Groups 元素不在 2016 正文里 |
| IBSS 省电与 ATIM | 11.2.4（85031）；11.2.8 | ATIM 窗口状态机、TIM / ATIM 编解码 | 无（IBSS 实际建网除外） | 未做。只在要支持 IBSS 时有用 |
| SM Power Save、HT、20/40 共存、VHT 操作 | 11.15（91120）；11.16（91128）；11.40（98596）；9.4.2.56–.60；9.6.12 | 元素与 Action 编解码 | CCA / NAV 的实际行为 | 未做。S31 上 HT / VHT 由 blob 处理，host 侧价值低 |
| TDLS（含 TPK 安全协议）、DLS、PeerKey / STK | 11.23（92089）；9.6.4、9.6.13；12.7.8（105951）；12.7.9（106400）；11.7 | TDLS 的载荷、TPK / SMK 握手、DLS 状态机 | 直接链路的信道切换与收发 | 未做。体量最大，依赖 QoS；按产品形态决定是否做 |
| 认证方（Authenticator）的密钥管理状态机 | 12.7.11（107048） | 状态机对打 | 无 | 未做。请求方（12.7.10）已做；只在做 AP 或测试认证方时有意义 |

离线可验证缺口里最大的三个：TDLS（含 TPK 安全协议，体量最大、依赖 QoS）、TS / TSPEC 的 ADDTS / DELTS 与 TS 生命周期
（与「不做 EDCA 竞争与队列调度」的现有决策冲突，立项前要先重估）、FT 的安全架构状态机与 RRB（依赖已做的 FT 密钥层次与 over-the-DS 序列）。
上述三项在盘点表里都仍是「未做」；第五批之后表里已无「对真实链路吞吐价值最大而完全未做」的 host 侧行。

容量：`full` 的 factory 分区余量随第五批从 280832 B 降到 219728 B（`wifi` profile 317264 B；镜像 `wifi` 1218736、
`full` 1316272 B）。按第五批约 60 KB 的增量，余量还够 3 批左右；下一批之前要定「扩分区还是把自检移出 full」。

### BLE（Bluetooth Core 5.4 与 RFC 7668）

| 特性 | 条款 | 验证方式 | 不抓空口的上限 | 状态 |
| --- | --- | --- | --- | --- |
| HCI 控制命令与事件（Command Complete、Command Status、LE Meta、流控计数） | Vol 4 Part E §5.4、§7.7、§7.8 | 字节级已知答案；假控制器 | L1，L3 见下一行 | 离线验证通过（L1）；板侧自检含在 50/50 里（第一次上板 18/19，失败的一条是自检自身的错，修复后复验通过） |
| 对真实 controller 的 HCI 一致性自检 | Vol 4 Part E §3.1（表 3.1）、§4.5、§6.27、§7.4、§7.6、§7.8 | 板上发 26 条只读命令，按规范与 controller 自己声明的 Supported_Commands 位图校验回包 | L3 | 已完成 2026-11-24，结果不通过：20 条合规（16 受支持、4 声明不支持），6 条不一致。细目见 `docs/verification/ble-core-verification.md` §8 |
| ACL 分段与重组 | Vol 4 Part E §5.4 | 大 SDU 分段后重组 | L1 | 离线验证通过（L1） |
| L2CAP（基本信道、LE 信令、基于信用的流控） | Vol 3 Part A §3、§4、§10 | 双端对打 | L1 | 离线验证通过（L1） |
| 广播与扫描响应数据、地址类型、可解析私有地址 | Vol 3 Part C §11、§10.8；Vol 3 Part H §2.2 | 往返、解析、私有地址生成与解析 | L1 | 离线验证通过（L1） |
| IPv6 over BLE | RFC 7668 §3.2.4、§3.2.5 | RFC 7668 §3.2.4.1 的示例 | L1 | 离线验证通过（L1） |
| 6LoWPAN 适配层补全：IPHC 压缩与无状态 / 有状态解压、上下文表的有效期、NHC（扩展头与 UDP）、dispatch、Mesh 头、分片与重组 | RFC 4944 §5.1–§5.3、§11；RFC 6282 §3、§4；RFC 6775 §4.2、§5.4.2–§5.4.3；RFC 8025 §3 | RFC 手排的已知答案；与盘上 lwIP 源码的差分（三个种子各 1000 个报文） | L1 | 离线验证通过（L1 50 项；板侧自检 10 条，2026-11-25 随第五批镜像上板、`ble_802154` 207/207 全过）。6LoWPAN-ND 的协议本体与 RFC 8930 / 8931 见下面两行；Mesh 路由、HC1 / HC2 未做。已知的互通缺口：lwIP 的压缩器用有状态压缩编码 `::` 源地址并指向没人配置过的上下文槽，本实现因上下文不存在而拒解（见验证报告 §4.1、§6） |
| 6LoWPAN-ND 的主机侧行为：ARO / 6CO / ABRO / SLLAO 编解码、RS / RA / NS / NA 的校验、上下文表、地址注册与续期、睡眠、下一跳判定 | RFC 6775 §3.1、§4.1–§4.3、§5；RFC 4861 §4.1–§4.6、§6.1.2、§7.1；RFC 4862；RFC 4944 §8 | 按原文手排的已知答案；与独立手写的 Python 解析器差分（主代理重跑 9000 例，被接受例的 94.7% 带选项） | L1 | 离线验证通过（L1 42 项；板侧自检 30 条，2026-11-25 随第五批镜像上板、`ble_802154` 207/207 全过）。保留字段按原文「接收方必须忽略」、不拒收。未做：6LR / 6LBR 与 DAR / DAC、mesh、DHCPv6、发送 NA、重定向、RFC 4861 完整的邻居缓存状态机 |
| 分片转发（VRB）与选择性分片恢复：RFRAG / RFRAG-ACK 头，发送方 / 接收方 / 转发方三个状态机 | RFC 8930 §5、§6；RFC 8931 §4.4、§5、§6、§7.1、附录 C | 按原文手排的已知答案；头部编解码对 Python oracle（两个方向 1216 组） | L1 | 离线验证通过（L1 27 项；板侧自检 16 条，2026-11-25 随第五批镜像上板、`ble_802154` 207/207 全过）。盘上没有这两份 RFC 的独立实现，三个状态机只有按原文手排的场景用例；真实路由查找是注入点 |
| SMP 密码学工具箱 | Vol 3 Part H §2.2 | Appendix D 样例；与独立参照实现做差分 | L1 | 离线验证通过（L1；板侧自检 25/25） |
| 配对：legacy 与 LE Secure Connections，全部方法，双角色 | Vol 3 Part H §2.3、§3 | 双端进程内配对 | L1 | 离线验证通过（L1） |
| 密钥分发与绑定存储 | Vol 3 Part H §3 | 双端密钥一致 | L1 | 离线验证通过（L1） |
| 链路层加密（AES-CCM）与 CRC-24 | Vol 6 Part B §4.6.1、§5.1.3、§3.1 | 保护与解保护往返，篡改被拒 | L1 | 离线验证通过（L1） |
| ATT 服务端、GATT 服务端与客户端、AES-CMAC 签名（指示、发现、排队写、CCCD、Service Changed、全部 GATT 过程） | Vol 3 Part F §3.4、§5.3；Vol 3 Part G §3、§4、§7.1、附录 A、B；RFC 4493 | 双端进程内对打，线上字节逐条比对；NimBLE 的 PDU 尺寸交叉核对 | L1 | 离线验证通过（L1：att 19、att_svr 13、gatts 5、gattc 18、cmac 3；板侧新增 31 条，含在 50/50 里） |
| 扩展广播与周期广播的 host 侧：17 条 HCI 命令、两个事件、广播集台账、链路层扩展头解析、广播数据分片器 | Vol 4 Part E §7.7.65.13、§7.7.65.18、§7.8.52–§7.8.69；Vol 6 Part B §1.2、§2.3、§2.3.4、§2.5.2 | 按参数表逐字节排的已知答案；与 NimBLE 的命令结构体、报告遍历代码交叉核对（没有独立 oracle） | L1 | 离线验证通过（L1 115 项；板侧自检 27 条，2026-11-25 随第五批镜像上板、`ble_802154` 207/207 全过）。取决于 controller 能力或时序调度的判据没有建模 |
| Enhanced ATT bearer 池、LE 上基于额度的 L2CAP 连接、Robust Caching（Client Supported Features、Database Hash） | Vol 3 Part G §2.5.2、§2.5.2.1、§5.3、§7.2–§7.4、附录 B；Vol 3 Part A §4.22–§4.28、§10.1–§10.2 | 附录 B 的样例；Database Hash 对独立 oracle（24 张随机属性表）；与 NimBLE 交叉核对 | L1 | 离线验证通过（L1 57 项；板侧自检 10 条，2026-11-25 随第五批镜像上板、`ble_802154` 207/207 全过） |
| LL Privacy 的解析列表与地址解析、LE Power Control 的 host 侧 | Vol 4 Part E §7.8.38–§7.8.45、§7.8.74–§7.8.77、§7.8.117–§7.8.121；Vol 6 Part B §1.3.2.2–.3、§4.5.16、§4.7、§5.1.17、§6.1–§6.5 | 参数表逐字节；RPA 对独立 oracle（仓外 2000 组）；与 NimBLE 交叉核对 | L1 | 离线验证通过（L1 66 项；板侧自检 9 条，2026-11-25 随第五批镜像上板、`ble_802154` 207/207 全过）。`Responder` 是 controller 行为的纯逻辑模型 |
| PAwR（Periodic Advertising with Responses）的 host 侧：LE Set Periodic Advertising Subevent Data / Response Data / Sync Subevent 三条命令（7.8.125–.127）、Subevent Data Request 与 Response Report 两个事件（7.7.65.36–.37）、AUX_SYNC_SUBEVENT_IND / RSP 的字段许可（表 2.8 / 2.9）与数据「只发一次然后立即丢弃」 | Core 5.4 [Vol 4] Part E §7.8.1、§7.8.125–.127、§7.7.65.36–.37；[Vol 6] Part B §2.3.1.9–.10（表 2.8、2.9）、§2.3.4、§4.4.2.2.4、§4.4.2.12.2 | 按参数表逐字节排的已知答案；照同一份规范独立写的 Python 模型对拍（1000 例，接受 301 / 拒绝 699，其中广播方应答场景 100 例通过 66，0 不一致）；表 2.8 / 2.9 的格子从 SIG HTML 逐格数出（NimBLE 没有 PAwR，没有独立实现对拍） | L1 | 离线验证通过（L1 31 项；板侧 18 条，2026-11-25 上板 207/207 全过）。`Advertiser.respond` 按独立评审改成「已答位图」（一条请求的多个子事件可分多条命令答完，同一子事件第二次应答回 `AlreadyAnswered`）。Packet Too Long / Too Early / Too Late、时序调度、§3.12 的连接建立、ADI 上位关系整链不做 |
| Connection Subrating 的 host 侧：LE Set Default Subrate / LE Subrate Request 两条命令与参数校验、LE Subrate Change 事件、LL 侧的接受 / 拒绝规则与 40 s 过程超时 | Core 5.4 [Vol 4] Part E §7.8.1、§7.8.123–.124、§7.7.65.35；[Vol 6] Part B §2.4.2.36–.37、§4.5.1–.2、§5.1.19–.20、§5.2 | 按参数表逐字节；规范向量 + 照同一份策略写的模型对拍（714 例：通过 407 / 拒绝 307，0 不一致）；命令结构体与 LL PDU 长度对 NimBLE | L1 | 离线验证通过（L1 27 项；板侧 17 条，2026-11-25 上板 207/207 全过）。独立评审只发现注释引用错位，已改。三条 0x12 错误码之间的先后按 NimBLE 的顺序；Central 取 factor 用 `min(acc_max, req_max)` |
| LE Isochronous 的 HCI 接口面：ISO 数据包格式（PB / TS / Packet_Status_Flag）、CIS / BIS / BIG 相关命令与事件的编解码、BIGInfo 布局 | Core 5.4 [Vol 4] Part E §5.4.5、§7.8.96–.97 / .99 / .101–.103 / .106 / .109–.110 / .116、§7.7.65.25–.27 / .29–.30 / .34；[Vol 6] Part B §4.4.6.3–.4、§4.4.6.11；Assigned Numbers §2.11 | 按原文位宽逐字段排的已知答案；策略模型对拍（5 × 375 = 1875 例，拒绝 348，0 不一致）；HCI ISO 数据包头的位布局对 NimBLE 与盘上 Zephyr 的一份拷贝（`esp_ble_iso/include/zephyr/bluetooth/hci_types.h`，只有 ISO 包头的结构体）；BIGInfo 的位布局只有 NimBLE 一份可对（`ble_ll_sync.c:670–702`），外加 4.4.6.11 的 33 / 57 八位组总长；BIGInfo 里 BaseCRCInit 的 16 位宽度标 [INFERENCE] | L1 | 离线验证通过（L1 37 项；板侧 20 条，2026-11-25 上板 207/207 全过）。`transparent air mode = 0x03` 有出处（Assigned Numbers §2.11）。独立评审后 `leRemoveIsoDataPath` 接受 direction = 0x00（原文没有 shall）、RTN 越界的错误名改 `BadRtn`。CIG / BIG 的时序调度与音频流、ISOAL、H4 的 ISO 指示字节不编；7.8.97 的 RTN 推荐不等式没有实现（txt 转储失真，无法唯一还原） |
| 广播、连接、真实收发 | 不适用 | 抓空口 | L4 | 阻塞：射频 synth PLL 不锁 |

#### 尚未实现的领域（按 Bluetooth Core Specification 5.4 盘点，2026-11-25）

上表之外，下面是 Core 5.4 里还没进上表的 host 侧领域。锚点是盘上原文的行号：`/tmp/spec/Core-54-hci.txt`（[Vol 4] Part E）、
`/tmp/spec/Core-54-ll.txt`（[Vol 6] Part B）、`/tmp/spec/Core-54-sm.txt`（[Vol 3] Part H）、`/tmp/spec/Core-54-generic-attribute-profile--gatt-.txt`、
`/tmp/btcore-txt/v3a-l2cap.txt`（[Vol 3] Part A）。Core 5.4 的其它卷（LE Audio 的 GAF / BAP / 各 profile、Mesh profile、
Vol 3 Part C 的正文、Vol 3 Part E 与 Vol 5）盘上**没有原文**，这些行只能从 HCI 与 L2CAP 的接口面列。都未排期。

| 领域 | 盘上原文锚点 | 离线可验证的范围 | 必须真射频 / controller 的部分 | 现状与版本归属 |
| --- | --- | --- | --- | --- |
| PAwR（周期广播带响应）的 host 侧剩余部分 | hci.txt 7.8.125–127（1726–1728；正文 38249 起）、7.7.65 的 Subevent Data Request / Response Report；ll.txt 3.9–3.12、4.4.2.2.4（4390 起） | 三条数据命令与两个事件的编解码；subevent / response slot 的关系校验；同步窗口的推算 | subevent 的实际调度与收发 | **第五批已做**（`pawr.zig` 及其测试与子自检）：LE Set Periodic Advertising Subevent Data / Response Data / Sync Subevent 三条命令、两个事件、AUX_SYNC_SUBEVENT_IND / RSP 的字段许可（表 2.8 / 2.9）、数据只发一次的语义；`ext_adv.zig` 原有的 7.8.61 v2 参数校验不变。subevent 的实际调度、Packet Too Long / Too Early / Too Late、连接建立与 ADI 上位整链不做 |
| Encrypted Advertising Data | hci.txt 7.8.53 v2（31085 起）、7.8.122（38045）；Vol 1 5.4.6；Vol 3 Part C 10.10 | 加密标志的参数校验与逐字节打包、密钥相关地址变化的参数编码 | 实际加密后的空口发送与解密接收 | 未做。5.4 新特性 |
| Connection Subrating | hci.txt 7.8.123–124（1724–1725；正文 38046 起）、LE Subrate Change 事件；ll.txt 4.6.33.2、4.5.1、5.1.19–20（6196–6212） | 两条命令与一个事件的编解码；5.1.19–20 的参数接受 / 拒绝规则表 | 子额定后连接事件的实际调度 | **第五批已做**（`subrate.zig` 及其测试与子自检）：命令 / 事件编解码与 LL 接受 / 拒绝规则、40 s 过程超时。子额定后连接事件的实际调度不做；9.3.16 的正文不在盘上，实现不引用它 |
| Periodic Advertising Sync Transfer | hci.txt 7.8.91–92（1692–1693）、LE Periodic Advertising Sync Transfer Received 事件；ll.txt 2.4.2.27、2.4.2.40、5.1.13 | 命令 / 事件编解码；5.1.13 的三个时钟漂移公式（固定输入手排） | PDU 的实际收发与同步建立 | 未做。5.1 引入 |
| LE Isochronous 通道的 host 侧（CIS / BIS / ISOAL） | hci.txt 7.8.96–114（1697–1715）、ISO 数据包 5.4.5（1282）、LE Create BIG Complete（25233）、BIGInfo Adv Report（27229）；ll.txt 2.6、4.4.6 | 命令与事件逐字节；BIGInfo 的布局；BIG_Sync_Delay 与 bigEventCounter × BN 的公式 | CIG / BIG 的时序调度与音频流 | **部分做了**（`iso.zig` 及其测试与子自检，第五批）：HCI 接口面——ISO 数据包格式、CIS / BIS / BIG 命令与事件、BIGInfo 布局（HCI ISO 包头的位布局对 NimBLE 与盘上 Zephyr 的 `esp_ble_iso/.../hci_types.h` 拷贝；BIGInfo 只有 NimBLE 一份可对，加 4.4.6.11 的 33 / 57 八位组总长）。时序调度与音频流、ISOAL、BIG_Sync_Delay 公式、LE Audio 协议层不做；`l2cap_coc.zig` 的增强额度通道仍未接 ISO |
| LE 信道分类 | hci.txt 7.8.19（1620；正文 28590）；ll.txt 4.6.36 | 37 位信道图的打包与校验 | 报告信道的实际测量与调度 | 未做。命令自 4.0 即有，feature 是 5.3 新增 |
| LE PHY 命令与 PHY Update | hci.txt 7.8.47–49（1648–1650；正文 30826 起）、LE PHY Update Complete 事件 | 三条命令与一个事件的编解码、参数有效性表 | PHY 的实际协商与切换 | 未做。5.0 引入 |
| 测向（AoA / AoD，CTE）的 host 侧 | hci.txt 7.8.80–87（1681–1688；正文 33628 起）；ll.txt 3.7；Vol 1 8 | 天线切换模式表、IQ 采样报告的布局与参数校验 | CTE 的实际发送 / 采样与角度解算 | 未做。5.1 引入，需要多天线 |
| HCI 测试命令与 Direct Test Mode | hci.txt 7.8.28–30、7.6.3–4；Vol 6 Part F | 命令 / 事件编解码、DTM 测试包格式 | 射频收发的实测计数 | 部分做了：`ecc.zig` 有调试密钥对，测试命令未做 |
| LE GATT Security Levels Characteristic | gatt.txt 12.7（963）；v5.4 变更列表（hci.txt 70） | 特征的声明与值、权限语义 | 无 | 未做。5.4 新特性 |
| SMP：CTKD 的配对流程与 Keypress Notification | sm.txt 2.3.5.7（2713 起）、3.3、3.5.8（3223 起）、3.4（2997 起） | 派生函数已做；Transport Specific Key Distribution 的流程、Keypress PDU、计时器对 Keypress 的重启规则 | CTKD 的端到端需要 BR/EDR 侧的配对实体 | 部分做了：`toolbox.zig` 有 `ltkToLinkKey` / `linkKeyToLtk`，流程未接进 `pairing.zig`；Keypress 未做 |
| BR/EDR 的 HCI 命令与事件族 | hci.txt 7.1–7.3（1350–1493）、7.5、7.7 | 编解码与部分状态逻辑（角色切换、QoS 参数校验） | 页 / 查询 / SCO，需要 BR/EDR controller（S31 没有） | 未做 |
| BR/EDR 的 L2CAP 模式与配置 | v3a-l2cap.txt 2.4、3.3、5.3–5.7、7.2–7.3、8（ERTM 状态机 752 起） | ERTM 状态机、FCS（有样例数据） | 需要 BR/EDR ACL 链路 | 未做 |
| AMP（Alternate MAC / PHY） | 原文不在盘上（Vol 3 Part E、Vol 5）；只有 hci.txt 7.3.101 | HCI 层的编解码 | 全部协议层行为 | 不投入：5.3 起移除（v5.3 变更列表，hci.txt 66） |
| GAP 模式与复合操作 | 原文不在盘上（Vol 3 Part C 正文，只有目录锚 gatt.txt 956–970） | — | — | 广播数据格式已做；模式矩阵未做，且无原文可核 |
| LE Audio / Mesh 的 host 接口面 | 原文不在盘上（GAF / BAP / CAP、Mesh profile） | 同 ISO 那一行 | 协议层 / profile 行为与音频编解码 | 未做，依赖 ISO 行先行 |

不列入：LE Channel Sounding 是 Core 6.0 的特性，hci.txt 全文没有 "Channel Sounding"。离线可验证缺口里最大的三个：
Encrypted Advertising Data（5.4 新特性，编解码与参数校验）、Periodic Advertising Sync Transfer（命令 / 事件编解码加
5.1.13 的时钟漂移公式）、LE 信道分类（37 位信道图的打包与校验）。PAwR 的三条命令与两个事件、Connection Subrating、
LE Isochronous 的 HCI 接口面已在第五批做完（见上面特性表）。

### RFC 索引（按编号，2026-11-25）

上面两张特性表以 IEEE Std 802.11-2016 与 Bluetooth Core Specification 5.4 为主索引——Wi-Fi 与 BLE 本身不是 RFC 定义的。
这里把无线组件源码里实际引用的 35 份 RFC 按编号再列一遍，便于按 RFC 查。状态只写上表与验证报告里有证据的；
「引用」表示只在注释里引用该 RFC 的一条规则，没有独立的实现或用例。

| RFC | 内容 | 在本仓用在哪 | 状态 |
| --- | --- | --- | --- |
| RFC 791 | IPv4 | WNM 帧里 IP 版本字段的取值（`wifi-mlme/src/wnm.zig`） | 引用 |
| RFC 1071 | IP 校验和算法 | ICMPv6 校验和（`ble-802154/src/nd6.zig`） | 随 `nd6` 离线验证通过 |
| RFC 2104 | HMAC | FT 密钥派生的向量出处（`wifi-connect/src/ft_vectors.zig`） | 随 FT 离线验证通过 |
| RFC 2409、RFC 3526 | IKE 的 MODP 群参数 | SAE 的 FFC 群（`wifi-connect/src/sae_groups.zig`） | 离线验证通过 |
| RFC 2460 | IPv6 | WNM 帧里 IP 版本字段的取值（`wifi-mlme/src/wnm.zig`） | 引用 |
| RFC 2464、RFC 4291 | IPv6 over Ethernet、IPv6 编址架构 | BLE 侧的 IID 与地址（`ble-802154/src/ipsp.zig`、`nd6.zig`、`fifteen4.zig`） | 随 6LoWPAN 离线验证通过 |
| RFC 2548 | MS 的 RADIUS 属性（MPPE 密钥的封装） | EAP-TLS 的 MSK → PMK（`wifi-connect/src/eap_tls.zig`） | 随 EAP-TLS 离线验证通过 |
| RFC 3394 | AES Key Wrap | 4 次握手 Key Data 的封装与解封（`wifi-connect/src/keywrap.zig`、`kde.zig`、`suite256.zig`） | 离线验证通过（RFC 3394 §4.1） |
| RFC 3580 | 802.1X 与 RADIUS 的使用指南（§4 的 Version 字段） | EAP 头校验（`wifi-connect/src/eap.zig`） | 随 EAP 离线验证通过 |
| RFC 3610 | AES-CCM | 链路层加密（`ble-security/src/linklayer.zig`） | 离线验证通过 |
| RFC 3748 | EAP | EAP 头、Identity、Nak、分片（`wifi-connect/src/eap.zig`、`eap_tls.zig`） | 离线验证通过 |
| RFC 4231 | HMAC 的测试向量 | 256 位套件 KDF 的向量出处（`wifi-connect/src/suite256_vectors.zig`） | 随 256 位套件离线验证通过 |
| RFC 4282 | 网络接入标识（NAI） | ANQP 的 NAI Realm 编码类型（`wifi-mlme/src/gas.zig`） | 随 GAS 离线验证通过 |
| RFC 4443 | ICMPv6 | 校验和与 RS / RA / NS / NA（`ble-802154/src/nd6.zig`） | 离线验证通过 |
| RFC 4493 | AES-CMAC | BIP 的向量（`wifi-connect/src/vectors.zig`）；GATT 签名与 Robust Caching（`ble-802154/src/cmac.zig`、`robust_cache.zig`）；SMP 工具箱（`ble-security/src/toolbox.zig`） | 离线验证通过 |
| RFC 4861、RFC 4862 | 邻居发现、SLAAC | 6LoWPAN-ND 的主机侧行为（`ble-802154/src/nd6.zig`） | 离线验证通过 |
| RFC 4944 | 6LoWPAN 适配层（dispatch、Mesh 头、分片） | `ble-802154/src/ipsp.zig`、`fifteen4.zig`、`sfr.zig` | 离线验证通过 |
| RFC 5216 | EAP-TLS | `wifi-connect/src/eap_tls.zig` | 离线验证通过（L1 34 项） |
| RFC 5869 | HKDF | OWE 与 SAE 的密钥派生（`wifi-connect/src/owe.zig`、`sae.zig`）；BLE 随机源的展开（`ble-security/src/rand.zig`） | 随所在模块 |
| RFC 5903、RFC 6090 | 椭圆曲线 Diffie-Hellman | OWE 的群 19（`wifi-connect/src/owe.zig`） | 离线验证通过（RFC 的测试向量） |
| RFC 6070 | PBKDF2 | PSK → PMK 的向量出处（`wifi-connect/src/vectors.zig`） | 离线验证通过（Annex J.3） |
| RFC 6282 | 6LoWPAN IPHC | `ble-802154/src/ipsp.zig`、`fifteen4.zig`、`nd6.zig` | 离线验证通过 |
| RFC 6775 | 6LoWPAN-ND | `ble-802154/src/nd6.zig` | 离线验证通过 |
| RFC 7668 | IPv6 over BLE | `ble-802154/src/ipsp.zig` | 离线验证通过（§3.2.4.1 的示例） |
| RFC 8025 | IPv6 over IEEE 802.15.4 的更正 | `ble-802154/src/fifteen4.zig` | 随所在模块 |
| RFC 8110 | OWE | `wifi-connect/src/owe.zig`、`akm.zig` | 离线验证通过；Transition Mode 不在 RFC 8110 里，未做 |
| RFC 8138 | 6LoWPAN 扩展头的 dispatch（分页） | `ble-802154/src/sfr.zig` | 部分做了：只留 size_delta 注入口 |
| RFC 8247 | 802.1X / EAP 的 IANA 注册表更新 | SAE 群的 DEPRECATED 标记（`wifi-connect/src/sae_groups.zig`） | 引用 |
| RFC 8930 | 6LoWPAN 转发分片恢复（VRB） | `ble-802154/src/sfr.zig` | 离线验证通过 |
| RFC 8931 | 6LoWPAN 选择性分片恢复（RFRAG） | `ble-802154/src/sfr.zig` | 离线验证通过 |
| RFC 9190 | EAP-TLS 1.3 | 只在注释里提到（`wifi-connect/src/eap_tls.zig`） | 未做 |

不在无线组件里、但上表的实现依赖的 RFC：RFC 8446（TLS 1.3，`net-tls-http`；EAP-TLS 的 TLS 引擎由调用方注入）、
RFC 2131（DHCP，`net-udp-dhcp-dns`；拿 IP 那一步）。
