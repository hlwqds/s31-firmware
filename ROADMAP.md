# Roadmap

本仓库是 **Zig × ESP32-S31 系统实现**的唯一开发地。路线图按「可验收的出口条件」组织：
每个阶段结束必须有一条**能在日志或 CI 里指认的证据**，否则不算完成。

- 当前基线：`v0.2.0`（生产结构：单一固件 + 组件；由 `hl-ljj-quartz@32f10c56` 迁出的实现重构而来）
- 状态明细：`SUITE-README.md`、`BRINGUP-2026-11-12.md`
- 工程约定：`AGENTS.md`、`docs/REPO-STANDARDS.md`

## 现状（v0.1.0）

| 能力 | 状态 | 证据 |
| --- | --- | --- |
| 启动链 / 链接布局 / 时钟 / UART / 中断 / 定时器 / Flash / 调度 / 堆栈 / 双核 | 基本可用 | `logs/ch04-boot.log` … `logs/ch15-boot.log` |
| 以太网 MAC/PHY（ch17） | **阻塞**：SWR 超时、无 PHY 应答 | `logs/ch17d-boot.log` |
| IPv4/ARP/ICMP、UDP/DHCP/DNS、TCP、TLS/HTTP、MQTT/OTA、Socket 层 | 离线判定通过，真链路未验 | `logs/ch18-boot.log` … `logs/ch24-boot.log` |
| Wi-Fi / BLE / 802.15.4 边界 | 符号取证 + ABI/字节路径自检 | `logs/ch25-boot.log` … `logs/ch27-boot.log` |
| 选槽/回滚/功耗/性能模型（ch28A） | 板侧自检通过；计量与 28B 未做 | `logs/ch28-boot.log`、`logs/ch28a-boot.log` |
| 生产化原型的宿主测试（netmgr/ota/provisioning/recovery） | 通过 | 15/15、8/8、18/18、9/9 |
| CI / 发布 / 版本标签 | **未建立** | 本路线图 P0 |

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
- [x] 板侧联调：默认配置（boot+net）烧录通过，聚合 `firmware: checks: passed=6 failed=0 total=6`、`main: verdict=pass`（`logs/firmware-boot.log`）
- [x] 聚合测试：`firmware` 的 `test` step 覆盖 11 个组件（323 项）
- [x] 脚本：`scripts/check-host.sh`、`scripts/check-fmt.sh`、`scripts/build-image.sh`、`tools/capture.py`
- [x] CI 定义：host / image 两个 job；板级 job 为自托管手动触发
- [ ] 分支保护与远端：`main` 只接受 PR；发布用 tag
- [ ] **P0.2 多段镜像**：解除「恰好两段」限制，使 `-Dtls=true` 与 `-Dwifi=true` 可同时开启
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
- [ ] 生产化四切片接口冻结（v1 ABI），共享 KAT 向量，HIL 回归脚本可无人值守跑
- [ ] baseline 清单 + HIL 台架接入 CI（自托管 runner）
- **出口**：HIL 跑一轮全绿并归档日志；接口变更需 ADR

### P4：自举、计量与发布（W4/W5，v1.0.0）

- [ ] 28B：Zig 二级 bootloader 可选实现（镜像头/分区/选槽/校验/救援）
- [ ] 真实电流、唤醒时间、频率切换测量，替换 ch28 的模型值
- [ ] 发布包：`s31-system-vX.Y.Z`（含镜像、日志摘要、复现命令、SHA256）
- [ ] CHANGELOG 与升级说明；破坏性变更给出迁移指引
- **出口**：外部使用者按发布包能在同型号板卡复现「构建 → 烧录 → 自检通过」

## 里程碑与版本

| 版本 | 内容 | 阻塞项 |
| --- | --- | --- |
| v0.1.0 | 迁出快照（当前） | — |
| v0.2.0 | P0 工程化 | 无 |
| v0.3.0 | P1 以太网闭环 | ref clock / MDIO |
| v0.4.0 | P2 应用层真链路 | 依赖 v0.3.0 |
| v0.5.0 | P3 Wi-Fi + 生产化 | 依赖 v0.3.0 |
| v1.0.0 | P4 自举/计量/发布 | 依赖 v0.4.0、v0.5.0 |

## 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| ch17 时钟/PHY 问题长期无解 | P1 之后全部阻塞 | 独立时间盒实验；每轮只改一个变量并留日志；必要时换板/换 PHY 验证 |
| 硬件只有一块板 | 并发开发互相踩串口 | `flock` 串行 + 自托管 HIL runner 排队 |
| 生产化原型与章节工程重复实现 | 双份逻辑漂移 | 以 `tools/s31-production` 为实现源，章节工程只保留教学版本；共享 KAT |
| 计量设备缺失 | 功耗/性能无法验收 | v1.0 前只声明模型值；计量到位后再改结论 |
| 无远端备份 | 单机丢失 | P0 完成前先加远端并开分支保护 |

## 不在本仓库范围

教程正文、站点构建、博客链接策略属于 `hl-ljj-quartz`；本仓库只在发布说明里引用对应章节。
