# Roadmap

本仓库是 **Zig × ESP32-S31 系统实现**的唯一开发地。路线图按「可验收的出口条件」组织：
每个阶段结束必须有一条**能在日志或 CI 里指认的证据**，否则不算完成。

- 当前基线：`v0.2.0`（生产结构：单一固件 + 组件；由 `hl-ljj-quartz@32f10c56` 迁出的实现重构而来）
- 状态明细：`SUITE-README.md`、`BRINGUP-2026-11-12.md`
- 工程约定：`AGENTS.md`、`docs/REPO-STANDARDS.md`

## 现状（2026-11-24）

| 能力 | 状态 | 证据 |
| --- | --- | --- |
| 启动链 / 链接布局 / 时钟 / UART / 中断 / 定时器 / Flash / 调度 / 堆栈 / 双核 | 基本可用 | `logs/ch04-boot.log` … `logs/ch15-boot.log` |
| 以太网 MAC/PHY 驱动 | 真链路可用：DHCP → ARP → TCP 握手 → socket 收发，板上 7/7 | `logs/e2e-net-wire-boot.log` |
| IPv4/ARP/ICMP、UDP/DHCP/DNS、TCP、Socket 层 | 真链路已上板（DHCP + TCP + socket） | `logs/e2e-net-wire-boot.log` |
| TLS/HTTP、MQTT/OTA | 离线判定通过；真实链路证据在 ch23 lab（TLS 握手 + HTTPS GET、MQTT、OTA 回滚） | `logs/e2e-tls-boot.log`；`hl-ljj-quartz` 的 `practice/zig-esp32-s31/logs/ch23-*.log` |
| Wi-Fi / BLE / 802.15.4 边界 | 符号取证 + ABI/字节路径自检 | `logs/ch25-boot.log` … `logs/ch27-boot.log` |
| BLE + Wi-Fi 共存（glue，设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`） | glue 已接进两套适配层（`-Dcoex`，默认关）：BLE 探针与 Wi-Fi 探针各自带着真核心上板，参数指针非零、版本行打出、适配表被核心收下；关着时四种镜像与改动前逐字节相同。两个 blob 同镜（C3、C4）与空口未做 | `docs/verification/coex-verification.md` |
| Wi-Fi 与 BLE 的离线可验证特性（按规范条款） | 本轮落地 5 个组件：主机测试 282 项，与独立参照实现差分一致；板级自检 14/14 个 section 通过（`logs/e2e-wifi-boot.log`，整体判决 pass）；默认镜像逐字节不变 | `docs/verification/` |
| 真实 Wi-Fi blob（`components/wifi-blobs`） | **init 返回 0**；任务体可跑并合作式让出；扫描/连接未做 | `logs/wifi-init-ok-boot.log`、`logs/wifi-task-boot.log` |
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
- [x] 聚合测试：`firmware` 的 `test` step 覆盖 **19 个测试项目（830 项）**（含 `posix`）
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
- [ ] 共存 glue：`components/radio-coex` 对照 IDF 逐钩子验证（L1），在 `-Dcoex` 开关后接入两套 blob 适配层，默认镜像逐段不变（L2）；设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`
- [ ] 共存的运行时统一、窗口与分区扩大、合并镜像启动（L3，不抓空口）
- [ ] Wi-Fi 与 BLE 的离线可验证特性按条款落地，每项有按条款组织的验证报告（`docs/verification/`）；清单见下文「无线特性路线图」
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

规范口径：Wi-Fi 取 **IEEE Std 802.11-2016**（条款号取自该版目录）；BLE 取 **Bluetooth Core Specification 5.4**（按卷、部分、节引用）；其上的 RFC 单列：RFC 7668（IPv6 over BLE）、RFC 3394（AES Key Wrap，WPA2 的密钥封装）、RFC 4493（AES-CMAC）、RFC 3610（AES-CCM）。

验证分级沿用 `docs/REPO-STANDARDS.md` §4：L1 主机、L2 镜像、L3 板侧自检、L4 真链路（抓空口）。**两个射频目前都没有端到端跑通**（Wi-Fi 卡在 `esp_wifi_start` 的 MAC 忙位，BLE 的射频 synth 不锁），所以这张路线图按"不抓空口能验到哪一级"排序：L1 到 L3 的项现在就能做完，L4 的项等射频打通。

证据落在 `docs/verification/`：`coex-verification.md`、`wifi-ieee80211-verification.md`、`ble-core-verification.md`。表里的"状态"只认这些报告里有的证据。

### 共存

设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`。

| 项 | 内容 | 不抓空口能验到 | 状态 |
| --- | --- | --- | --- |
| C0 | 调研与设计：共存接口面、容量实测、合并链接实验、非探针闭包链接修复 | L2 | 已完成 2026-11-24 |
| C1 | 共存 glue（`components/radio-coex`）：适配表、24 个 Wi-Fi 钩子、16 个 BLE 钩子、核接口、生命周期 | L1 | 离线验证通过（45/45）；板侧自检 10/10（对假核心）；真核心经 C2 上板 |
| C2 | 接进 `wifi-blobs`、`osal`、`bt-blobs`，放在 `-Dcoex` 开关后；默认镜像逐段不变 | L2 | 已完成 2026-11-24：三种 coex 镜像链接通过，四种非 coex 镜像逐字节不变，两块板级实验各带对照（L3） |
| C3 | 运行时统一：一个调度器、一份 osi，导出、堆、tick、trap 钩子各一份 | L2 | 计划 |
| C4 | 窗口与分区扩大；合并镜像启动、两个控制器的 init 都返回 | L3 | 计划 |
| C5 | PHY 与时钟域归属（启动序列） | L3 | 计划 |
| C6 | 共存性能：BLE 广播间隔对 Wi-Fi 吞吐的影响、PTI 行为 | L4 | 阻塞：等 R3.1、R3.3 |

### Wi-Fi（IEEE Std 802.11-2016）

| 特性 | 条款 | 验证方式 | 不抓空口的上限 | 状态 |
| --- | --- | --- | --- | --- |
| MAC 帧格式与字段 | 9.2.3、9.2.4.1–9.2.4.8 | 字节级已知答案；Annex J.9 的帧 | L3 | 离线验证通过（L1；板侧自检 16/16） |
| 管理帧（Beacon、Probe、Authentication、Deauthentication、Association、Reassociation、Disassociation、Action） | 9.3.3.3–9.3.3.14 | 编解码已知答案 | L3 | 离线验证通过（L1） |
| 信息元素（SSID、速率、DSSS、TIM、Country、RSNE、Extended Capabilities、MMIE 等） | 9.4.2.2–9.4.2.158 的子集 | 解析合成的 Beacon | L3 | 离线验证通过（L1） |
| MLME：认证、关联、去认证、状态机与定时器 | 11.3 | 进程内假 AP 对打，时间注入 | L3 | 离线验证通过（L1） |
| 扫描（被动、主动、信道驻留） | 11.1.4 | 扫描计划的确定性测试 | L3 | 离线验证通过（L1） |
| PSK、PMKID、PTK、GTK 派生 | 12.7.1.2–12.7.1.4；Annex J.3、J.4、J.7 | Annex J 官方向量 | L3 | 离线验证通过（L1；板侧自检 28/28） |
| 4 次握手与组密钥握手（请求方） | 12.7.6、12.7.7、12.7.10 | 进程内认证方对打 | L3 | 离线验证通过（L1） |
| 密钥数据封装与 AES Key Wrap | 12.7.2；RFC 3394 | RFC 3394 §4.1 | L3 | 离线验证通过（L1） |
| 安全关联与策略选择 | 12.6.1、12.6.2、12.6.3 | 状态机测试 | L3 | 离线验证通过（L1） |
| CCMP-128、GCMP-128 | 12.5.3、12.5.5 | Annex J.6.4、J.7、J.9.2 | L3 | 离线验证通过（L1） |
| BIP-CMAC-128 与 MMIE | 12.5.4、9.4.2.55 | Annex J.8、J.9.1 | L3 | 离线验证通过（L1） |
| 管理帧保护与 SA Query | 12.2.8、12.6.19、12.6.20、11.14、9.6.10 | 分类表与 SA Query 过程 | L3 | 离线验证通过（L1） |
| SAE 完整实现（P-256、PWE、Commit 与 Confirm、状态机） | 12.4；Annex J.10 | J.10 向量与双端对打 | L3 | 计划（现有：字节层子集，缺椭圆曲线运算） |
| FT 密钥层次 | 12.7.1.7、13.4 | 推导向量 | L3 | 计划 |
| CCMP-256、GCMP-256、BIP-256 | 12.5 | 与 128 位版同构 | L3 | 计划 |
| QoS 与省电 | 9.2.4.5、10.3、11.2 | 编解码 | L3 | 计划（TIM 解析随信息元素一起做） |
| TKIP、WEP | 12.5.2、12.3.2 | 不做 | — | 不做：pre-RSNA，已弃用 |
| 真实 MAC：`esp_wifi_start`、扫描、连接 | 不适用 | 抓空口 | L4 | 阻塞：`MAC_ST[15:13]` |

### BLE（Bluetooth Core 5.4 与 RFC 7668）

| 特性 | 条款 | 验证方式 | 不抓空口的上限 | 状态 |
| --- | --- | --- | --- | --- |
| HCI 控制命令与事件（Command Complete、Command Status、LE Meta、流控计数） | Vol 4 Part E §5.4、§7.7、§7.8 | 字节级已知答案；假控制器 | L1，L3 见下一行 | 离线验证通过（L1）；板侧自检 19/19（第一次 18/19，失败的一条是自检自身的错，修复后复验通过） |
| 对真实 controller 的 HCI 一致性自检 | Vol 4 Part E | 板上发只读命令并按规范校验返回值 | L3 | 计划；已证明能回复的命令：0x0C03、0x1001、0x1009、0x2006、0x2008、0x1405 |
| ACL 分段与重组 | Vol 4 Part E §5.4 | 大 SDU 分段后重组 | L1 | 离线验证通过（L1） |
| L2CAP（基本信道、LE 信令、基于信用的流控） | Vol 3 Part A §3、§4、§10 | 双端对打 | L1 | 离线验证通过（L1） |
| 广播与扫描响应数据、地址类型、可解析私有地址 | Vol 3 Part C §11、§10.8；Vol 3 Part H §2.2 | 往返、解析、私有地址生成与解析 | L1 | 离线验证通过（L1） |
| IPv6 over BLE | RFC 7668 §3.2.4、§3.2.5 | RFC 7668 §3.2.4.1 的示例 | L1 | 离线验证通过（L1） |
| SMP 密码学工具箱 | Vol 3 Part H §2.2 | Appendix D 样例；与独立参照实现做差分 | L1 | 离线验证通过（L1；板侧自检 25/25） |
| 配对：legacy 与 LE Secure Connections，全部方法，双角色 | Vol 3 Part H §2.3、§3 | 双端进程内配对 | L1 | 离线验证通过（L1） |
| 密钥分发与绑定存储 | Vol 3 Part H §3 | 双端密钥一致 | L1 | 离线验证通过（L1） |
| 链路层加密（AES-CCM）与 CRC-24 | Vol 6 Part B §4.6.1、§5.1.3、§3.1 | 保护与解保护往返，篡改被拒 | L1 | 离线验证通过（L1） |
| ATT 与 GATT 扩展（指示、发现、prepared write） | Vol 3 Part F、Part G | 双端对打 | L1 | 计划（现有：8 个 ATT 操作码、服务端定长表） |
| 广播、连接、真实收发 | 不适用 | 抓空口 | L4 | 阻塞：射频 synth PLL 不锁 |
