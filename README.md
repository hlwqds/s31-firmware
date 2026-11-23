# s31-firmware

ESP32-S31（RISC-V 双核）的**生产固件与板级组件**，用 Zig 0.17.1 编写，
形态为「纯 Zig ELF + IDF 二级 bootloader」。不包含教程与博客内容。

- 固件入口：`firmware/`（单一固件，构建时按特性开关裁剪）
- 板级层：`boards/esp32s31-coreboard/`（链接脚本、启动/异常/日志/寄存器）
- 子系统：`components/`（net / apps / wifi / boot-power-perf）
- 生产化工具：`tools/s31-production/`
- 历史与证据：`docs/history/`、`logs/`

## 能力现状

| 领域 | 状态 |
| --- | --- |
| 启动链、链接布局、看门狗、时钟 | 真机验证（历史 bring-up 记录） |
| IPv4 / ARP / ICMP / UDP / DHCP / DNS / TCP / Socket | 主机测试 + 板侧自检；真实链路受以太网驱动阻塞 |
| TLS/HTTP、MQTT/OTA | known-answer / 注入路径自检 |
| Wi-Fi / BLE / 802.15.4 | 符号取证 + ABI/字节路径自检；**BLE controller 归档已闭包链接**（116 对象 / 913728 B，`scripts/check-bt-link.sh`），Wi-Fi 侧仍为桩 |
| 选槽 / 回滚 / 功耗 / 性能模型 | 板侧自检通过；计量与 Zig bootloader 未做 |

完整判据与未闭环项见 `ROADMAP.md` 与 `docs/history/`。

**范围**：本仓只承载产品固件（`firmware/`）、板级层（`boards/`）、网络/应用/Wi-Fi 组件与生产化工具。
中断/CLIC、定时器/DMA、Flash/NVS、堆栈 caps、双核 SMP/IPI、可观测性等实验性实现**不在本仓**
（代码随章节树移除，结论与日志见 `docs/history/` 与 `logs/`）。
**例外（2026-11-18 起）**：协作式调度与同步原语已进仓 —— `components/osal/`（`sched.zig` +
`osal.zig`，服务 BLE 归档）与 `components/posix-compat/`（POSIX 形状：sem/mutex/cond/rwlock/
thread/timer，section `posix` 有板级证据）。它们进仓的理由是**生产侧本来就需要**（归档的 OSAL
是产品固件的一部分），不是教学实现。

## 构建

```bash
# 主机测试（全部组件 + 工具切片）
env -u LD_LIBRARY_PATH zig build test --summary all      # 在 firmware/ 下
scripts/check-host.sh                                    # 仓库级发现式运行

# 固件（默认：boot + net，不含 TLS/Wi-Fi；两段镜像窗口的限制见 ROADMAP P0.2）
cd firmware
env -u LD_LIBRARY_PATH zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
  -Dboot=true -Dnet=true -Dtls=false -Dapps=false -Dwifi=false

# 镜像与烧录
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin   # 恰好两行 DROM, IROM
sh tools/flash.sh /dev/ttyUSB1                                      # 需 idf-bootstrap/build
```

特性开关：`-Dboot`/`-Dnet`/`-Dtls`/`-Dapps`/`-Dwifi`。TLS 与全部特性同时开启会超出
当前两段镜像布局（`irom` 窗口跨入 `drom` 虚拟基址），见 `ROADMAP.md` P0.2。

## 规范

- 仓库规范：`docs/REPO-STANDARDS.md`
- 路线图：`ROADMAP.md`
- 贡献流程：`CONTRIBUTING.md`
- 工程硬约束速查：`AGENTS.md`
- 变更记录：`CHANGELOG.md`
- 测试框架与门禁：`docs/TESTING.md`（单元 816 项 + 覆盖率门禁 + profile/板级 E2E）
