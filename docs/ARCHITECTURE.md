# 架构

```
firmware/                    单一固件（start.zig → main.zig → components）
  ├── src/{start,main}.zig
  ├── idf-bootstrap/         IDF 二级 bootloader + 分区表（生成物不入库）
  └── tools/flash.sh
boards/esp32s31-coreboard/   板级层：linker/s31.ld、hw/log/trap、板卡说明
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
  ├── wifi-connect           扫描/连接状态机、WPA2/WPA3 派生
  ├── ble-802154             HCI/ATT/GATT、802.15.4 FCF/6LoWPAN
  ├── wifi-mlme              IEEE 802.11 帧格式、管理帧、信息元素、MLME、扫描（纯逻辑）
  ├── ble-security           SMP 配对、密钥分发、链路层 AES-CCM（纯逻辑）
  ├── radio-coex             BLE + Wi-Fi 共存 glue（对照 IDF 的 coex 钩子，纯逻辑；设计见 ADR-003）
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
`drom` 从 `0x40100020`，各 `0xB0000`（720 896 B，P0.3 扩容；合计 1 441 792 B 仍在 factory 1 500 K 内）。
芯片侧上限远大于此（`SOC_IROM_HIGH=0x44000000`、MMU 1024×64 KiB），但 DROM 段必须结束在
`0x43FF0000` 以下——loader 把 DROM 区间最后一页当分区发现的临时页。P0.3 扩容后 TLS/Wi-Fi 都能装下：
`full`（TLS + Wi-Fi + apps）实测镜像 398 576 B、IROM 段 305 696 B、DROM 段 70 796 B，
窗口余量分别为 415 200 B / 650 100 B，factory 分区余量 1 137 424 B。余量由
`scripts/check-capacity.py` 持续把关（窗口从链接脚本解析，增长超过 8 KiB 即失败）。
窗口上限本身有板级证据：`-Dfat-rodata=600000` 造出 **636 372 B** 的 DROM 段（超过旧 0x7F000），
烧录后 `sections: passed=7 failed=0 total=7`、`verdict=pass`。

## 证据链

- 主机测试：`firmware/zig build test`（聚合全部组件）+ `tools/s31-production/*/build.zig`。
- 板侧自检：每个组件 `selftest.zig` 在固件里被顺序调用，日志落到 `logs/`。
- 历史：`docs/history/` 保留章节时代的 SPEC、总览与十轮 bring-up 记录；`logs/` 文件名不改。
