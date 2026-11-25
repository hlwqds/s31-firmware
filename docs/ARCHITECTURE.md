# 架构

```
firmware/                    单一固件（start.zig → main.zig → components）
  ├── src/{start,main}.zig
  ├── idf-bootstrap/         IDF 二级 bootloader + 分区表（生成物不入库）
  └── tools/flash.sh
boards/esp32s31-coreboard/   板级层：linker/s31.ld、hw/clock/pmu/rng/log/trap、板卡说明
components/
  ├── net-ipv4               首部/校验和/分片/重组/路由/ARP/ICMP
  ├── net-udp-dhcp-dns       UDP、DHCP 状态机、DNS 解析与缓存
  ├── net-tcp                TCP 状态机、RTO、乱序重组、TIME_WAIT
  ├── net-congestion         慢启动/AIMD/Reno + 确定性仿真
  ├── net-sockets            FD 表、poll 事件循环、连接池
  ├── net-tls-http           TLS 记录层/密钥日程/AEAD/DER、HTTP/1.1
  ├── app-mqtt-ota           MQTT 3.1.1、OTA 清单校验/回滚
  ├── wifi-boundary          OSI 函数表 ABI、blob 边界
  ├── wifi-blobs             真实 blob 链接 + osi 适配层（init/任务/合作式让出）
  ├── wifi-connect               扫描/连接状态机；RSNA（WPA2/WPA3 密钥派生、按 AKM 的 4 次握手、CCMP/GCMP/BIP 含 256 位套件）；SAE（P-256 与其余 14 个群）；FT 密钥层次与 FT 协议；OWE；EAP-TLS
  ├── ble-802154             HCI、ATT 服务端、GATT 服务端与客户端、AES-CMAC 签名、扩展广播与周期广播的 host 侧、EATT 与 Robust Caching、LL Privacy 与 LE Power Control 的 host 侧、802.15.4 帧头与 6LoWPAN 适配层
  ├── wifi-mlme              IEEE 802.11 帧格式、管理帧、信息元素、MLME、扫描、QoS Control、省电、无线测量、WNM（BSS Transition Management、WNM Sleep Mode）（纯逻辑）
  ├── ble-security           SMP 配对、密钥分发、链路层 AES-CCM（纯逻辑）
  ├── radio-coex             BLE + Wi-Fi 共存 glue 与 PHY/时钟归属模型（对照 IDF 的 coex 钩子，纯逻辑；设计见 ADR-003）
  ├── bt-blobs               真实 BLE controller 归档的链接、OSAL 与 HCI 传输；板级探针，含对 controller 的 HCI 一致性自检
  └── boot-power-perf        otadata 选槽、A/B、功耗/性能模型
tools/s31-production/        生产化组件（netmgr/ota/provisioning/recovery/基线/HIL）
```

## 依赖方向

`firmware → components → boards`；`components` 之间**不互相依赖**（共享类型通过各自模块内定义，
需要时在 firmware 层胶合）。`tools/s31-production` 独立构建，通过 C ABI 与固件对接。

## 构建变体

`firmware/build.zig` 生成 `enabled.zig`（仅包含已启用子系统的 `run` 入口），
未启用的组件**不参与编译**。默认 `boot + net`；TLS/应用/Wi-Fi 按需开启。

两段窗口（唯一真相是 `boards/esp32s31-coreboard/linker/s31.ld`）：`irom` 从 `0x40000020`、
`drom` 从 `0x401D0020`，各 `0x1C0000`（1 835 008 B）。2026-11-24 的 R5 扩容（原为 irom `0xC0000`、
drom `0xB0000`、drom 基址 `0x40100020`）是为了把两个射频 blob 链进同一镜像，见
`docs/adr/ADR-003-ble-wifi-coexistence.md` 第 3 节。窗口只是链接上限，**实际占用仍受 factory 分区
（1 536 000 B）约束**，由 `scripts/check-capacity.py` 把关（窗口从链接脚本解析，相对基线增长超过
8 KiB 即失败）。芯片侧上限远大于此（`SOC_IROM_HIGH=0x44000000`、MMU 1024×64 KiB），但 DROM 段
必须结束在 `0x43FF0000` 以下——loader 把 DROM 区间最后一页当分区发现的临时页。

窗口上限的板级证据（`docs/verification/coex-verification.md` §7）：

- irom：合并镜像的 IROM 段 **825 744 B**，超过旧上限 786 432 B，烧录后 8/8 通过（`logs/coex-merged-boot.log`）；
- drom：`-Dfat-rodata=1000000` 造出 **1 046 816 B** 的 DROM 段，超过旧上限 720 896 B，烧录后 8/8 通过
  （`logs/fat-rodata-1000000-boot.log`）；
- 新基址 `0x401D0020`：以上两个镜像与默认镜像（`logs/e2e-net-boot.log`）的 DROM 段都落在那里。

默认镜像在扩容前后的差异只有重定位：`.flash.text` 的 48 062 条指令形状不变，1 905 处指向 rodata 的
常量各加 `0xD0000`；`.flash.rodata` 里 971 个不同的字节全是「指向 rodata 的指针」或「text 与 rodata 的
相对偏移」；SRAM 各段逐字节相同。

## 证据链

- 主机测试：`firmware/zig build test`（聚合全部组件）+ `tools/s31-production/*/build.zig`。
- 板侧自检：每个组件 `selftest.zig` 在固件里被顺序调用，日志落到 `logs/`。
- 历史：`docs/history/` 保留章节时代的 SPEC、总览与十轮 bring-up 记录；`logs/` 文件名不改。
