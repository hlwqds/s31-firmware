# 验证报告索引

这里只写实际跑过的命令和输出里出现过的结果。验证分级见 `docs/REPO-STANDARDS.md` §4：L1 主机、L2 镜像、L3 板侧自检、L4 真链路（抓空口）。

| 报告 | 规范依据 | 覆盖的组件 |
| --- | --- | --- |
| [`coex-verification.md`](coex-verification.md) | ESP-IDF 源码、ROM 与 `libcoexist.a`（共存不是 IEEE 或 Bluetooth 标准） | `radio-coex` |
| [`wifi-ieee80211-verification.md`](wifi-ieee80211-verification.md) | IEEE Std 802.11-2016；RFC 3394、RFC 4493、RFC 6070 | `wifi-mlme`、`wifi-connect` |
| [`ble-core-verification.md`](ble-core-verification.md) | Bluetooth Core Specification 5.4；RFC 7668 | `ble-802154`、`ble-security` |

## 板级运行：2026-11-24 第一次

命令（仓库根目录，板子在 `/dev/ttyUSB0`，不需要主机侧网络，不抓空口）：

```bash
BOARD=/dev/ttyUSB0 python3 tests/e2e/run_e2e.py --board --profile wifi
```

harness 按 profile 构建、经 `tools/flash.sh` 烧录（读回校验）、抓 30 秒串口并断言。原始日志：`logs/wifi-selftest-prefix-boot.log`（"prefix" 指自检修复之前的那一次）。

| section（按固件输出顺序） | 判据 | 结果 |
| --- | --- | --- |
| `net_ipv4` | 13/13 | 通过 |
| `net_udp_dhcp_dns` | 14/14 | 通过 |
| `net_tcp` | 11/11 | 通过 |
| `net_congestion` | 10/10 | 通过 |
| `net_sockets` | 12/12 | 通过 |
| `net_ethernet` | 11/11 | 通过 |
| `wifi_boundary` | 13/13 | 通过 |
| `wifi_connect` | 28/28 | 通过 |
| `ble_802154` | 18/19 | **失败 1 条**：`check: gap adv kat=1 nospace=1 name=1 hci=0 malformed=1 ok=0` |
| `wifi_mlme` | 16/16 | 通过 |
| `ble_security` | 25/25 | 通过 |
| `radio_coex` | 10/10 | 通过（对着假核心） |
| `boot_power_perf` | 12/12 | 通过 |
| `posix` | 36/36 | 通过 |

聚合行：`firmware: sections: passed=13 failed=1 total=14`、`main: verdict=fail`。harness 结果 `FAIL board:wifi`。

失败那一条的原因：`ble-802154` 的自检把 32 字节的 HCI 参数与向量的 31 字节切片比较，差一，恒为假；与目标无关，是自检代码的错。已改为整段比较（`components/ble-802154/src/selftest.zig`）。修复后用桩 `board` 模块在主机上执行五个组件的 `selftest.run()`，结果 28/16/19/25/10 全过。

**修复后的板级复验还没有做**，所以目前没有一份整体判决为 `pass` 的板级日志。上面的表是唯一一次板级运行的原始结果。

## 默认镜像不变（L2）

新 section 只挂在 `wifi` 组，`firmware/build.zig` 的默认选项不含 `wifi`。在集成前的提交 `3194bf6` 上建 worktree，与集成后的工作树用同一组构建参数（`tests/e2e/run_e2e.py` 里各 profile 的 `-D` 开关）各构建一次，整文件比 SHA-256，两边在不同目录：

| profile | `app.bin` | SHA-256（`app.bin`） | SHA-256（`app.elf`） |
| --- | --- | --- | --- |
| `min` | 76 240 B | `c6a2d1cc8d17d845c86a847c04c607ae1ed6e6238677da5a6983c74b8c9a3b99` | `0ede552acb9a44200dfec097c8b01122a01714704d56a2e0491561ecafe84444` |
| `net-wire` | 145 200 B | `0dfcd421ce035abd27b10e2d660bb29e39189be0e65872b2a0ccfafdc590ab9b` | `fd1988231a0ce0bed1e3f5e90ed58ad05a6ef9a6a5d6d9426e91af953bc79077` |
| `net`（即默认镜像） | 243 488 B | `7ff950143c0cb646898e63fc139c6b0d51959e6ee7837ad4de0d7904043dfa2e` | `ac5b407e7f28302ff716774970fa1bbdfb9994d078d47f52b17d5fa7f2653243` |
| `tls` | 333 600 B | `785daaefd87ec140b2204433410d770f8c8bdfabf84af88acc6e8689e687ed20` | `6a1b02376bf706c3f76a88dc0b7bfd1aedff9485ed944cf1d8e0f9f483416134` |

四个 profile 的 `app.bin` 与 `app.elf` 两边逐字节相同。默认镜像另用 `scripts/build-image.sh firmware`（不带任何 `-D` 开关）单独构建对比过一次，结果与表中 `net` 一行一致。

## 容量（L2）

`3194bf6` 与本轮改动后各跑一次 `scripts/check-capacity.py`，取其表格相减：

| profile | `app.bin` 增长 | irom 增长 | drom 增长 | 说明 |
| --- | --- | --- | --- | --- |
| `wifi` | +193 232 B | +176 848 B | +50 784 B | 三个新 section 加两个扩展的 section |
| `full` | +192 032 B | +142 832 B | +46 160 B | 同上 |
| `min`、`net`、`tls`、`net-wire` | 0 | 0 | 0 | 不含 `wifi` 组，见上一节 |

本轮之后：`wifi` 的 irom 余量 411 056 B，`full` 的 irom 余量 276 528 B，factory 分区余量分别为 1 024 128 B 与 869 904 B。

基线文件 `tools/s31-production/baseline/capacity.json` 上次刷新是 2026-11-18（`a59e5d7`）。到 `3194bf6` 为止已有一批与本轮无关的漂移，所以 **`3194bf6` 上 `check-capacity.py` 本来就是失败的**（退出码 1）：六个 profile 的 irom 增长 21 504 到 31 504 B（`min` 21 504、`net-wire` 22 848，其余四个 31 072 到 31 504）。本轮用 `check-capacity.py --update` 把这些一并写进基线，复核通过。

`app.bin` 的大小不代表真实占用：esptool 在 IROM 段之后插一个填充段，把 DROM 段对齐到 64 KiB。同一批漂移，`min` 的 `app.bin` 只大了 1 152 B，`net` 的却大了 59 936 B。看占用要用 irom 与 drom 两列。

这批漂移的来源（`a59e5d7` 与 `3194bf6` 各构建一次 `min`、`net`、`net-wire`，在临时检出里关掉 strip 后按符号比较函数字节）：

- `boards/esp32s31-coreboard/src/trap.zig` 的 `trapDispatch` 在三个 profile 里都从约 5 350 B 长到 25 454 到 25 694 B（+20 104 到 +20 344 B），并带进 5 160 B 的浮点格式化代码。该文件同期从 517 行长到 1620 行，中间 159 个提交动过，单次最多加 55 行，是 BLE 调试期间累积的诊断代码。它没有构建开关，所有 profile 都编进去。`wifi`、`tls`、`full` 没有单独量。
- `net` 另外多出一个约 9.7 KB 的自检入口（`selftest.run.8`）、日志 2 922 B、osal 1 848 B。

是否给这些诊断代码加开关由仓库所有者决定，本轮没有动 `trap.zig`。中间大多数提交在默认 `min` 配置下构建失败（`071a8fc` 的提交说明提到当时非 BT profile 的链接回归），所以 `git bisect` 无法逐个提交定位；上面的数字是两端各构建一次量出来的。
