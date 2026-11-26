# 验证报告索引

这里只写实际跑过的命令和输出里出现过的结果。验证分级见 `docs/REPO-STANDARDS.md` §4：L1 主机、L2 镜像、L3 板侧自检、L4 真链路（抓空口）。

| 报告 | 规范依据 | 覆盖的组件 |
| --- | --- | --- |
| [`coex-verification.md`](coex-verification.md) | ESP-IDF 源码、ROM 与 `libcoexist.a`（共存不是 IEEE 或 Bluetooth 标准） | `radio-coex` |
| [`wifi-ieee80211-verification.md`](wifi-ieee80211-verification.md) | IEEE Std 802.11-2016；其上的 RFC 3394、RFC 4493、RFC 6070、RFC 4231、RFC 2104，第三批另涉 RFC 8110、RFC 5869、RFC 5903、RFC 6090、RFC 5216、RFC 3748、RFC 2409、RFC 3526，第四批只涉 RFC 8110 §4.5；第五批不涉新 RFC | `wifi-mlme`、`wifi-connect` |
| [`ble-core-verification.md`](ble-core-verification.md) | Bluetooth Core Specification 5.4；其上的 RFC 7668、RFC 4493、RFC 3610，第三批另涉 RFC 4944、RFC 6282、RFC 6775、RFC 8025，第四批另涉 RFC 4861、RFC 4862、RFC 8930、RFC 8931；第五批不涉新 RFC（只引 Bluetooth SIG 的 Assigned Numbers §2.11） | `ble-802154`、`ble-security`；`bt-blobs` 的 HCI 一致性自检（§8） |

Wi-Fi 与 BLE 都不是 RFC 所定义的：前者的规范是 IEEE Std 802.11，后者是 Bluetooth SIG 的 Core Specification；RFC 只覆盖其上的少数协议。

第五批（2026-11-25，六片：WNM 其余子域、GAS / ANQP、Block Ack、PAwR、Connection Subrating、LE Isochronous 的 HCI 接口面）的
用例数、差分与偏离：Wi-Fi 三片在 `wifi-ieee80211-verification.md` §2、§4.6、§5.6、§6；BLE 三片在 `ble-core-verification.md`
§4.3、§5.4、§6、§7；变更记录见 `CHANGELOG.md` 的「无线离线特性第五批」条目。

## 板级运行：2026-11-24 第一次

命令（仓库根目录，板子在 `/dev/ttyUSB0`，不需要主机侧网络，不抓空口）：

```bash
BOARD=/dev/ttyUSB0 python3 tests/e2e/run_e2e.py --board --profile wifi
```

harness 按 profile 构建、经 `tools/flash.sh` 烧录（读回校验）、抓一段串口并断言（2026-11-25 起抓取时长按 profile 配置：默认 30 秒，`wifi` 60 秒、`full` 90 秒，见 `docs/TESTING.md`）。原始日志：`logs/wifi-selftest-prefix-boot.log`（"prefix" 指自检修复之前的那一次）。

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
（这是 2026-11-24 第一次运行的实录；失败的那条当天已修复，其后与 2026-11-25 第五批终态的板级运行都是 14/14 全过、`verdict=pass`，见上面第五批一节。）

失败那一条的原因：`ble-802154` 的自检把 32 字节的 HCI 参数与向量的 31 字节切片比较，差一，恒为假；与目标无关，是自检代码的错。已改为整段比较（`components/ble-802154/src/selftest.zig`）。修复后用桩 `board` 模块在主机上执行五个组件的 `selftest.run()`，结果 28/16/19/25/10 全过。

## 板级运行：2026-11-24 复验

同一条命令再跑一次（`PASS board:wifi`）。14 个 section 全部通过，`ble_802154` 19/19，聚合行
`firmware: sections: passed=14 failed=0 total=14`、`main: verdict=pass`。原始日志 `logs/e2e-wifi-boot.log`
（已覆盖上一次的文件；上一次的原始日志只留在 `logs/wifi-selftest-prefix-boot.log`）。

| section | `net_ipv4` | `net_udp_dhcp_dns` | `net_tcp` | `net_congestion` | `net_sockets` | `net_ethernet` | `wifi_boundary` | `wifi_connect` | `ble_802154` | `wifi_mlme` | `ble_security` | `radio_coex` | `boot_power_perf` | `posix` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 判据 | 13/13 | 14/14 | 11/11 | 10/10 | 12/12 | 11/11 | 13/13 | 28/28 | 19/19 | 16/16 | 25/25 | 10/10 | 12/12 | 36/36 |

## 板级运行：2026-11-24 第二批之后

同一条命令（第二批——SAE 完整协议、FT、256 位套件、QoS 与省电、ATT / GATT 扩展——并入之后）。`PASS board:wifi`，14 个 section
全部通过，聚合行 `firmware: sections: passed=14 failed=0 total=14`、`main: verdict=pass`。原始日志 `logs/e2e-wifi-boot.log`
（又覆盖了复验那一次的同名文件；上一节的数字取自那一次运行）。

| section | `net_ipv4` | `net_udp_dhcp_dns` | `net_tcp` | `net_congestion` | `net_sockets` | `net_ethernet` | `wifi_boundary` | `wifi_connect` | `ble_802154` | `wifi_mlme` | `ble_security` | `radio_coex` | `boot_power_perf` | `posix` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 判据 | 13/13 | 14/14 | 11/11 | 10/10 | 12/12 | 11/11 | 13/13 | **87/87** | **50/50** | **24/24** | 25/25 | 10/10 | 12/12 | 36/36 |

三个变了的 section：`wifi_connect` 28 → 87（SAE 24 条、suite-256 22 条、FT 13 条）；`ble_802154` 19 → 50（AES-CMAC 与签名 4 条、
ATT 服务端 11 条、GATT 服务端 8 条、GATT 客户端 8 条）；`wifi_mlme` 16 → 24（QoS 与省电）。

第三批（2026-11-25）之后，三个 section 的判据是 `wifi_connect` 177（+90）、`wifi_mlme` 37（+13）、`ble_802154` 106（+56），
在主机上用桩 `board` 执行都是零失败。**这一批当时没有上板**；2026-11-25 随第五批的镜像上板、全部通过（见下一节）。

第四批（2026-11-25）之后，三个 section 的判据是 `wifi_connect` 199（+22）、`wifi_mlme` 58（+21）、`ble_802154` 152（+46），
在主机上用桩 `board` 执行都是零失败（最长一行分别是 140、154、114 字节）。**这一批当时也没有上板**（串口无权限）；
2026-11-25 随第五批的镜像上板、全部通过（见下一节）。

第五批（2026-11-25）之后，三个 section 的判据是 `wifi_connect` 199（不变）、`wifi_mlme` 121（+63）、`ble_802154` 207（+55），
在主机上用桩 `board` 执行都是零失败。串口权限由用户授权 `setfacl` 恢复后，同日随 `wifi` profile 上板
（`BOARD=/dev/ttyUSB0 python3 tests/e2e/run_e2e.py --board --profile wifi`）：**`PASS board:wifi`，14/14 个 section 全部通过**，
聚合 `firmware: sections: passed=14 failed=0 total=14`、`main: verdict=pass`——三个无线 section 的判据全部在真板上通过：
`wifi_connect` 199/199、`ble_802154` 207/207、`wifi_mlme` 121/121（第三、四、五批之后第一次上板），`net_ethernet` 11/11 也过
（此前一次不过是因为主机网口 `enp0s31f6` 在 NetworkManager 里反复尝试激活已消失的配置、把链路拉低，板侧只等 5 秒；
链路稳定后同一条判据通过）。整份日志 `logs/e2e-wifi-boot.log`（覆盖了第二、三、四批时期的同名文件）。

最小验证镜像（新增的 `--only` 机制，`--profile wifi --only ble_802154,wifi_mlme`）同样通过：`PASS board:wifi[ble_802154,wifi_mlme]`、
207/207 与 121/121，日志 `logs/e2e-wifi-only-ble_802154+wifi_mlme-boot.log`；该镜像 512704 B，是整份 `wifi` 镜像（1218736 B）的 42%。

真实 AP 的厂商栈对照（属路线图 R3，不属于第五批）：官方 IDF 的最小 station（`tools/wifi-idf-oracle/`）在同一块板上连用户提供的 AP
（SSID `hl-wifi`；密码不进任何仓库或文档）：关联、WPA2-PSK、DHCP、ping 网关 5/5，日志 `logs/wifi-idf-oracle-sta.log`，
见 `wifi-ieee80211-verification.md` §8。

2026-11-25 的后续：与 oracle 的全量寄存器对照找到了本仓库 `esp_wifi_start` 不返回的根因并修复，
`esp_wifi_start rc=0`（`logs/wifi-probe-start-rc0-boot.log`；`wifi-ieee80211-verification.md` §9、`coex-verification.md` §11）。

2026-11-26 的后续：本仓库自己的移植第一次扫描到真实 AP——`esp_wifi_start` 之后主动扫描约 9.1 s 走完全部信道，
取到 38 条真实记录；根因两处（APM 访问控制过滤器、supplicant 回调表是空指针），证据与逐 AP 对照见
`wifi-ieee80211-verification.md` §10、`logs/wifi-link-scan-boot.log`（邻居的 SSID 与 BSSID 已脱敏）。

2026-11-26 的后续：本仓库自己的移植第一次连上真实 AP 并在 IP 层收发（WPA2-PSK + CCMP-128）——`STA_CONNECTED` 约 3.0 s，
MAC 密钥表里的钥匙核对一致，DHCP 拿到地址，ping 网关 10/10；修了四处运行时问题（任务栈过界、NVS 键表、`memcpy` 写密钥表、
数据通路不答 ARP 请求），证据见 `wifi-ieee80211-verification.md` §11、`logs/wifi-link-connect-boot.log`（脱敏）。
同一次运行开着共存核，各阶段的共存读数见 `coex-verification.md` §12。

2026-11-26 的后续：补了不开共存的对照——胶水按 IDF 关闭分支作答、核不启动时扫描 38 个 AP、ping 10/10，L4a 的判据成立
（`coex-verification.md` §13、`logs/wifi-link-coex-off-boot.log`）。只去掉 `-Dcoex` 的镜像收不到帧，查清是 `_coex_pti_get`
的计数桩把出参写成 0，已修（`logs/wifi-link-nocoex-boot.log` 是修之前，`logs/wifi-link-stubs-pti-boot.log` 是修之后）。
合并镜像里的 BLE enable 返回 0、没有锁死，但 synth 锁定位仍是 0（`coex-verification.md` §14、
`logs/coex-merged-ble-enable-boot.log`）。L4a 里"硬件定时器没在走"的读数已更正：当时读的是共存低功耗时钟的配置寄存器
（`coex-verification.md` §12）。

## 不抓空口的另外三次板级运行（2026-11-24）

| 运行 | 命令 | 结果 | 日志 |
| --- | --- | --- | --- |
| 对真实 controller 的 HCI 一致性自检（BLE 探针 + 共存核） | `sh /tmp/probe-board.sh ble hci-conformance-boot.log 45` | 26 条只读命令：`checks passed=20 failed=6 total=26 supported=16 not_supported=4`。**结果不通过**：6 条不一致，分三类，命令名、opcode 与它在位图里的八位组.位见 `ble-core-verification.md` §8 | `logs/hci-conformance-boot.log`（此前两次：`hci-conformance-run1-hang.log`、`hci-conformance-run2.log`） |
| 共存合并镜像（两个 blob 同镜） | `sh /tmp/merged-board.sh` | `coex_merged` 6/6；8/8 段、`main: verdict=pass`；两个控制器的 init 都返回 0 | `logs/coex-merged-boot.log`（第一次：`coex-merged-run1-boot.log`） |
| 默认 profile | `python3 tests/e2e/run_e2e.py --board --profile net` | `PASS board:net`，8/8 段 | `logs/e2e-net-boot.log` |

## 默认镜像（L2）

下面「默认镜像不变」一节是第一批集成时的逐字节对比。之后为共存扩大了链接窗口（drom 基址后移），默认镜像不再可能逐字节相同；
能证明、也证明过的是「除了重定位什么都没变」，见 `coex-verification.md` §7.3。第二批的代码只挂在 `wifi` 组，不进默认镜像。

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

**第二批之后（2026-11-24）**：`check-capacity.py` 再跑一次，`wifi` 与 `full` 超过基线 8 KiB 的阈值，这是第二批特性本身的体量
（SAE 的 P-256 运算、suite-256、ATT / GATT 服务端与客户端）；同样用 `--update` 重写基线后复核通过。其余四个 profile 没有变化。

| profile | `app.bin` 增长 | irom 增长 | drom 增长 | 之后 irom 余量（窗口 1 835 008 B） | factory 分区余量 |
| --- | --- | --- | --- | --- | --- |
| `wifi` | +226 976 B | +164 560 B | +41 712 B | 1 295 072 B | 797 152 B |
| `full` | +187 472 B | +136 512 B | +41 360 B | 1 188 592 B | 682 368 B |
| `min`、`net`、`tls`、`net-wire` | 0 | 0 | 0 | — | — |

同日 `tests/e2e/run_e2e.py --host`：六个 profile（`min`、`net`、`wifi`、`tls`、`net-wire`、`full`）构建全部通过，镜像都恰好两段。

共用同一个射频的合并镜像（Wi-Fi + BLE 两个 blob 同镜，`-Dcoex-merged`）不在这六个 profile 里，它的占用见 `coex-verification.md` §7.2。

**第三批之后（2026-11-25）**：`wifi` 1063200 B、`full` 1182480 B，factory 分区余量分别是 472800 与 353520 B。
**第四批之后（2026-11-25）**：`check-capacity.py` 对 `wifi` 与 `full` 报增长超过 8 KiB 的阈值，是六个新模块与它们的子自检的体量；
同样用 `--update` 重写基线后门禁通过。其余四个 profile 没有变化。

| profile | `app.bin` 增长 | irom 增长 | drom 增长 | 之后 factory 分区余量 |
| --- | --- | --- | --- | --- |
| `wifi` | +94 368 B | +63 888 B | +29 440 B | 378 432 B |
| `full` | +72 688 B | +64 544 B | +29 472 B | 280 832 B |
| `min`、`net`、`tls`、`net-wire` | 0 | 0 | 0 | — |

`wifi` 镜像里函数代码的增量是 63960 字节：第四批 Wi-Fi 四片 32128（`wnm` +7772、`wnm_tfs_selftest` +8952、`rrm_caps_selftest` +5284、
`owe_cache_selftest` +4156、`owe` +2332、`ft_ric_selftest` +1320、`rrm` +1304、`ft_proto` +1008），BLE 两片 31274（`nd6` +9812、`sfr` +8980、
`sfr_selftest` +6370、`nd6_selftest` +4360、它们引用到的 `fifteen4` +1750），其余零星几百字节；没有标准库的异常膨胀。
`full` 的 factory 分区余量只剩 280 KB，再有两批这样的增量就会顶满。

**第五批之后（2026-11-25，评审两轮返修之后的终态）**：`scripts/check-all.sh` 在终态代码上 rc=0 全绿
（`PASS firmware (2032)`、`capacity gate: OK`、六个 profile 全部 PASS）。在此之前跑过两遍：返修前第一遍停在容量门禁（按规则 FAIL），
`check-capacity.py --update` 后第二遍全绿；评审第二轮之后基线再 `--update` 一次。其余四个 profile 没有变化。

| profile | `app.bin` 增长 | irom 增长 | drom 增长 | 之后 factory 分区余量 |
| --- | --- | --- | --- | --- |
| `wifi` | +61168 B（1157568 → 1218736） | +39312 B | +21680 B | 317264 B |
| `full` | +61104 B（1255168 → 1316272） | +39200 B | +21728 B | 219728 B |
| `min`、`net`、`tls`、`net-wire` | 0 | 0 | 0 | — |

`full` 的 factory 分区余量从 280832 B 降到 219728 B；镜像增量约等于六片子自检的 text（46709 B）再加约 14 KB。
按第五批约 60 KB 的增量，余量还够 3 批左右，下一批之前要定「扩分区还是把自检移出 full」。

基线文件 `tools/s31-production/baseline/capacity.json` 上次刷新是 2026-11-18（`a59e5d7`）。到 `3194bf6` 为止已有一批与本轮无关的漂移，所以 **`3194bf6` 上 `check-capacity.py` 本来就是失败的**（退出码 1）：六个 profile 的 irom 增长 21 504 到 31 504 B（`min` 21 504、`net-wire` 22 848，其余四个 31 072 到 31 504）。本轮用 `check-capacity.py --update` 把这些一并写进基线，复核通过。

`app.bin` 的大小不代表真实占用：esptool 在 IROM 段之后插一个填充段，把 DROM 段对齐到 64 KiB。同一批漂移，`min` 的 `app.bin` 只大了 1 152 B，`net` 的却大了 59 936 B。看占用要用 irom 与 drom 两列。

这批漂移的来源（`a59e5d7` 与 `3194bf6` 各构建一次 `min`、`net`、`net-wire`，在临时检出里关掉 strip 后按符号比较函数字节）：

- `boards/esp32s31-coreboard/src/trap.zig` 的 `trapDispatch` 在三个 profile 里都从约 5 350 B 长到 25 454 到 25 694 B（+20 104 到 +20 344 B），并带进 5 160 B 的浮点格式化代码。该文件同期从 517 行长到 1620 行，中间 159 个提交动过，单次最多加 55 行，是 BLE 调试期间累积的诊断代码。它没有构建开关，所有 profile 都编进去。`wifi`、`tls`、`full` 没有单独量。
- `net` 另外多出一个约 9.7 KB 的自检入口（`selftest.run.8`）、日志 2 922 B、osal 1 848 B。

是否给这些诊断代码加开关由仓库所有者决定，本轮没有动 `trap.zig`。中间大多数提交在默认 `min` 配置下构建失败（`071a8fc` 的提交说明提到当时非 BT profile 的链接回归），所以 `git bisect` 无法逐个提交定位；上面的数字是两端各构建一次量出来的。
