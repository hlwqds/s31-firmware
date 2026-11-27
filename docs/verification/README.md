# 验证报告索引

这里只写实际跑过的命令和输出里出现过的结果。验证分级见 `docs/REPO-STANDARDS.md` §4：L1 主机、L2 镜像、L3 板侧自检、L4 真链路（抓空口）。

| 报告 | 规范依据 | 覆盖的组件 |
| --- | --- | --- |
| [`coex-verification.md`](coex-verification.md) | ESP-IDF 源码、ROM 与 `libcoexist.a`（共存不是 IEEE 或 Bluetooth 标准）；2026-11-27 起另含 IDF 的时钟单元表（`modem_clock_impl.c`）、IEEE Std 802.11-2016 §9.3 的管理帧格式（AP 侧空口证据）与 Bluetooth Core 5.4 [Vol 4] Part E §7.8.5 / §7.8.7 / §7.8.9（合并镜像里起广播的实验） | `radio-coex`；两个适配层的时钟写（`bt-blobs`、`wifi-blobs`）；合并镜像 `firmware/src/coex_merged.zig` |
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

2026-11-26 的后续：合并镜像里两个控制器同镜——带着 BLE 的 init 与 enable，Wi-Fi 走通真实链路（扫描 35 个 AP、连上 2059 ms、
DHCP 51 ms、ping 网关 10/10，`coex-verification.md` §15、`logs/coex-merged-wifi-link-boot.log`）。查出的规则是 PHY 的一次性
初始化与标定只认第一次使能：BLE 的 init 有两段会重做 PHY 的打开与标定（`probe_ptr.initPhy`、第 15 步的
`esp_phy_load_cal_and_init`），单变量对照里只跳过一段，Wi-Fi 的扫描就从三十多个 AP 掉到 1–2 个；合并镜像里让 Wi-Fi 先
start，BLE 的 init 两段都跳过（`phy_owned_by_wifi`），再把时钟 / 电源寄存器写回（不写回则连接失败）。这是"一个射频在收发、
另一个 enabled"——BLE 的射频没有起，L4b 仍然没有证据。
  【2026-11-27 晚：L4b 有了第一条证据，见下一段。】

2026-11-26 晚的后续：从 AP（OpenWrt）那一侧取了证据（`coex-verification.md` §15.8）。AP 的系统日志里，修之前每一轮都是
「板子没有确认认证响应」；最终形态是完整序列，AP 看板子 -24 dBm、双向 86 Mbit/s、15 秒里重传 0–1 次；只跳过第 15 步时
AP 发给板子的帧放弃 51 / 51、速率压到 6–8.6 Mbit/s，而信号一样强——退化在板子的接收侧。板子的 ARP 应答能跨过 AP 的桥
到达同网段的另一台主机；板子不回应别人的回显请求（数据通路的缺口）。日志 `logs/coex-merged-wifi-link-ap-syslog.log`、
`logs/coex-merged-wifi-link-ap-side.log`。空口上的帧见下一段。

2026-11-27 的后续：AP 侧抓到了空口上的帧（`coex-verification.md` §15.9、`logs/coex-merged-wifi-link-ap-frames.log`；
工具在 `tools/ap-side/`）：五个轮次 373 帧，板子发来的帧 -21 到 -28 dBm，连上的几轮关联过程同序同间隔；按条款的
对照见 `wifi-ieee80211-verification.md` §12。时钟域改成按单元取并集（`coex-verification.md` §16、
`logs/coex-merged-wifi-link-union-boot.log`）：不再有事后写回，两边的位在四个时点都在，20/20；单独的 BLE 探针回归
与基线逐行等价（`logs/bt-probe-clock-union-boot.log`）。合并镜像里试了经 HCI 起广播：第一版三次都停在发完第一条命令之后；
改成从发送任务里发之后三条命令都回了 Command Complete，但广播使能被接受之后 controller 任务不再让出，主上下文回不来，
synth 锁定位没有读到过（`coex-verification.md` §17、`logs/coex-merged-wifi-link-ble-adv-boot.log`、
`logs/coex-merged-wifi-link-ble-adv4-boot.log`、`logs/coex-merged-wifi-link-ble-adv8-boot.log`、
`logs/coex-merged-wifi-link-ble-adv8-ap-frames.log`、`ble-core-verification.md` §9）。合并镜像的构建入口固化为
`scripts/build-coex-link-image.sh`：只编 `coex_merged` 这一段，从 IDF 的归档重新生成对象集合，打印体积与归属。

2026-11-27 晚的后续：上一段里「广播使能被接受之后 controller 任务不再让出」的读法是错的——根因是**中断风暴**：`bt-blobs` 的
`intrArm` 把中断桥登记在 CLIC 输入号 24 上，而 trap 分发器按外部中断号（输入号减 16）查表，永远查不到；广播使能一处理，
BT MAC 的电平中断无限重入（每秒约 95 万次）。修掉（登记下标改成输入号减 16）之后合并镜像里 BLE 的广播上了空口：合成器
锁定位在广播使能后 35 ms 置位、15 秒后仍是它；中断桥 15 秒里入环 957 次、代跑 956 次；BLE 广播着的时候 Wi-Fi 照常连接、
DHCP、ping 10/10（往返平均从 3.5 ms 涨到 45 ms）；AP 侧记到第二次关联与四次握手；工作站 `bluetoothctl scan on` 看到 `s31`。
单变量对照：只把下标改回去，`handler 0x00000000 ok=0`、风暴照旧（`logs/coex-merged-wifi-link-ble-adv-storm-boot.log`）；
修掉之后 27/27（`logs/coex-merged-wifi-link-ble-adv{11,12,13}-boot.log`、`…-adv11-ap-syslog.log`、`…-adv11-ap-frames.log`、
`…-adv11-bt-scan.log`）。L4b 有了第一条证据；按广播间隔的时延与丢包等其余判据还没有做，「核真的在仲裁」的两条判据读了、
都不过（硬件定时器在每个时点都是 `en=0`，三组状态位的读数对不上名字）；单独的 BLE 探针回归一轮，与基线逐段相同——那边的
synth 墙不是这个风暴（`coex-verification.md` §17.5、`ble-core-verification.md` §9）。

2026-11-27 上午的后续（`coex-verification.md` §18）：按广播间隔 20 / 100 / 1000 ms 各量了一轮，每遍 ping 30 帧（`-Dcoex-adv-pings`），
三个间隔都不丢；广播时 rtt 三个间隔几乎一样（最小 27.2 ms、中位 30.5 ms、平均 45–55 ms），「间隔越短 rtt 越大」不成立。
空口上回显请求到应答中位 0.71 ms、没有重传；核不启动的对照轮里广播时 rtt 不涨（平均 3.5 ms）——涨在共存路径上。
「核真的在仲裁」两条判据过了一条：BLE 的状态字广播时是 `0x0001`（此前「对不上名字」是把 `coex_status_get` 当成了读字）；
硬件定时器在链路的每一泵步采一次使能位，约 3 万次里 0 次，这条没有过。PTI 行为、两侧的 start 回调还没有做。

2026-11-27 下午的后续（`coex-verification.md` §19）：持续的 Wi-Fi 流量（每遍 300 帧、间隔 50 ms，载荷 32 与 1400 字节各一轮）下
两遍都是 300/300；ADR-003 第 5 节剩下的三条判据都有了读数——两侧的 start 回调在 BLE enable 时各触发一次；PTI 是每个事件的定值；
核每接受一次事件 1 的申请就把定时器 0 装成申请的时长并置状态位（定时器的地址与使能位此前读错，§19.4 改正后「数值在两次读数
之间变了」按字面过了）。路线图 C8：LE Set Host Channel Classification 对真实 controller 发了，合规的图回 `0x00`、带保留位的图
回 `0x12`。顺带抓到并修掉：读数函数按值拷贝统计结构、栈帧 42 KB，把 16 KiB 主栈溢出 26 KB 进 BLE 堆，一版镜像因此崩在发送任务
的保存上下文上（§19.5）；合并 section 现在带主栈高水位的判据。没有做：时延的因果、可连接广播、这一轮的 AP 侧与空口采集。

## 不抓空口的另外三次板级运行（2026-11-24）

| 运行 | 命令 | 结果 | 日志 |
| --- | --- | --- | --- |
| 对真实 controller 的 HCI 一致性自检（BLE 探针 + 共存核） | `sh /tmp/probe-board.sh ble hci-conformance-boot.log 45` | 26 条只读命令：`checks passed=20 failed=6 total=26 supported=16 not_supported=4`。**结果不通过**：6 条不一致，分三类，命令名、opcode 与它在位图里的八位组.位见 `ble-core-verification.md` §8 | `logs/hci-conformance-boot.log`（此前两次：`hci-conformance-run1-hang.log`、`hci-conformance-run2.log`） |
| 共存合并镜像（两个 blob 同镜） | `sh /tmp/merged-board.sh` | `coex_merged` 6/6；8/8 段、`main: verdict=pass`；两个控制器的 init 都返回 0 | `logs/coex-merged-boot.log`（第一次：`coex-merged-run1-boot.log`） |
| 默认 profile | `python3 tests/e2e/run_e2e.py --board --profile net` | `PASS board:net`，8/8 段 | `logs/e2e-net-boot.log` |
| 时钟域按单元取并集（最小合并镜像） | `BLE=1 AP_CRED=<凭据文件> sh scripts/build-coex-link-image.sh`，烧录后抓 100 秒 | `coex_merged` 20/20；`main: verdict=pass`；共享时钟字在四个时点都是两边的并集 | `logs/coex-merged-wifi-link-union-boot.log` |
| BLE 起广播实验（2026-11-27 白天，广播没有起来——当晚查明是中断风暴，见下面「单变量对照」一行） | 同上，加 `ADV=1`，抓 150 秒，同时在 AP 上起 `MON` 采集（`tools/ap-side/collect.sh`）；之后 `esptool read_flash 0x18E000 0x1000` 读落盘记录，`tools/ap-side/decode-adv-marker.py` 解码 | 前面的判据全过；三条命令都回了 Command Complete（Status 0x00）；广播使能被接受之后板子失声（当时读成 controller 任务不再让出）：串口停在回包行的一半，落盘记录停在 Enable 的"正要发"，AP 只记到一次关联、monitor 上板子的帧到第一次断开为止，没有汇总行 | `logs/coex-merged-wifi-link-ble-adv8-boot.log`、`logs/coex-merged-wifi-link-ble-adv8-ap-syslog.log`、`logs/coex-merged-wifi-link-ble-adv8-ap-frames.log`、`logs/coex-merged-wifi-link-ble-adv4-boot.log`、`logs/coex-merged-wifi-link-ble-adv4-marker.txt`、`logs/coex-merged-wifi-link-ble-adv5-marker.txt`（第一版，主上下文里发：`logs/coex-merged-wifi-link-ble-adv-boot.log`） |
| 单独 BLE 探针回归（时钟函数改成只置位之后） | `sh /tmp/probe-board.sh ble bt-probe-clock-union-boot.log 50` | 与基线逐行等价：`INITED`，随后是 `ble_hw.c:506` 断言墙 | `logs/bt-probe-clock-union-boot.log` |
| 单独 Wi-Fi 真实链路回归（时钟钩子改成只置位之后） | `/tmp/r5c/connect-run.sh 75 <名字>`（`-Dwifi-link-probe` + 共存核，带 AP 凭据；结果经 `tools/ap-side/redact.py` 脱敏） | 扫描 37 个 AP、`STA_CONNECTED`、DHCP 102 ms、ping 网关 10/10（平均 18.8 ms），本地断开；基线 `logs/wifi-link-connect-boot.log`（40 个 AP、105 ms、平均 23.1 ms） | `logs/wifi-link-clock-union-boot.log` |
| 合并镜像里 BLE 起广播（2026-11-27 晚，中断桥的登记下标修掉之后） | 同上，加 `ADV=1`，烧录后抓 150 秒；工作站的 `bluetoothctl --timeout 230 scan on` 开在板子这一轮之前；AP 上起 `MON` 采集 | `coex_merged` 27/27；`main: verdict=pass`；合成器锁定位在广播使能后 35 ms 置位、15 秒后仍是它；中断桥 15 秒里入环 951 次、代跑 950 次（纯计数桩 0 次）；BLE 广播着的时候 Wi-Fi 连上、DHCP、ping 10/10（往返平均 3.7 → 39.4 ms）；工作站扫描看到 `[NEW] Device 02:00:00:00:BB:01 s31` | `logs/coex-merged-wifi-link-ble-adv13-boot.log`（最终代码）、`logs/coex-merged-wifi-link-ble-adv12-boot.log`；AP 侧与扫描的记录取自同代码的前一轮：`logs/coex-merged-wifi-link-ble-adv11-ap-syslog.log`、`logs/coex-merged-wifi-link-ble-adv11-ap-frames.log`、`logs/coex-merged-wifi-link-ble-adv11-bt-scan.log` |
| 单变量对照（最终代码只差登记下标那一行） | 同上，构建前把 `components/bt-blobs/src/bringup.zig` 的 `setHandler(routed_input - 16, …)` 改回 `setHandler(routed_input, …)`，抓 100 秒 | `check: ble interrupt bridge wired: MODEM_BT_MAC -> input 24 (want 24), handler 0x00000000 ok=0`；紧跟在 `0x200A` 的回包行后面累计 2001 万次中断（全部是输入 24），没有汇总行 | `logs/coex-merged-wifi-link-ble-adv-storm-boot.log` |
| 单独 BLE 探针回归（中断桥的登记下标修掉之后） | `sh /tmp/probe-board.sh ble bt-probe-bridge-index-boot.log 50` | 与基线逐段相同（只有计数值与串口交错不同）：`INITED`，HCI 一致性自检 20/26，照旧走到 synth 墙（`PRE200A 98BC=00000000`、`POLL0n 98BC=00000000`），主上下文一直在跑 | `logs/bt-probe-bridge-index-boot.log` |
| 按广播间隔量 ping（L4b 第一组，2026-11-27 上午） | `ADV=1 BLE=1 AP_CRED=<凭据文件> sh scripts/build-coex-link-image.sh -Dcoex-adv-interval-ms=<20、100、1000> -Dcoex-adv-pings=30`，烧录后抓 180 秒；同时在 AP 上起 MON 采集（`tools/ap-side/collect.sh`）、在工作站上 `tcpdump -i bluetooth-monitor`。对照轮多一个 `-Dcoex-sw-off=true` | 20 ms、100 ms 两轮 31/31；1000 ms 那轮 30/31（扫描灵敏度判据 8 对 19）；对照轮 28/31（核不在的那三条）。每遍 30 帧都不丢；广播时 rtt 三个间隔几乎一样（最小 27.2 ms、中位 30.5 ms，对照遍平均 4 ms）；对照轮广播时 rtt 平均 3.5 ms | `logs/coex-merged-wifi-link-ble-intvl{20,100,1000}-{boot.log,ap-frames.log,ap-side.txt,hci.txt}`、`…-intvl100-swoff-{boot.log,ap-side.txt}` |
| 持续的 Wi-Fi 流量、启动回调、PTI、信道分类（L4b 第二组与路线图 C8，2026-11-27 下午） | `ADV=1 BLE=1 AP_CRED=<凭据文件> sh scripts/build-coex-link-image.sh -Dcoex-adv-pings=300 -Dcoex-adv-ping-interval-ms=50 [-Dcoex-adv-ping-bytes=1400] -Dcoex-ble-chan-class=true`，烧录后抓 200 秒（只取板侧串口） | 最终镜像 35/35、`verdict=pass`：每遍 300 帧都是 300/300，广播那一遍 rtt 1.3 / 26.9 / 141.3 ms（对照遍 1.1 / 2.4 / 12.2 ms）；信道分类 `00 f8 ff ff 1f` 回 Status 0x00、保留位置上的图回 0x12；主栈高水位 13 520 字节里用到 1 688。读法迭代中的一版镜像一次抓取里连崩四次（`CPU_LOCKUP_RESET`；读数函数栈帧 42 KB，§19.5） | `logs/coex-merged-wifi-link-ble-intvl100-ping50ms300-boot.log`（不带信道分类的对照）、`…-intvl100-ping50ms300-1400b-chanclass-boot.log`（载荷 1400 字节）、`…-intvl100-ping50ms300-final-boot.log`（最终代码）、`…-intvl100-ping50ms300-lockup-boot.log`（崩溃那轮） |

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

2026-11-27（L4b 第二组与路线图 C8 那一轮，`516ee8b`）又对了一次：在它的父提交 `ad76f7d` 上建临时检出，与当前树各按默认构建
（不带任何 `-D` 开关，即 `net`）编一次，`app.bin` 都是 243 408 B、SHA-256
`4de8ad203cf95fdf02ef268029ae56ecbe1dd391c1cbdd1d484858abeb4c8dcb`，`app.elf` 都是
`b7ef0050e34a74c4def6ada516339f801c9a81bba2dc1ef032db2eb5fd631913`，逐字节相同——那一轮只动了 `wifi-blobs`、`radio-coex`、
`ble-802154` 与合并镜像，都不在默认镜像里。收尾时把板子刷回的就是这一份（读回校验通过）；自检 7/8，没过的是 `net_ethernet`
的 `rx loopback frame`，原因是板子的网线没接（`link: no partner after 5s`、`phy-link: up=0`）——同一条在
`logs/e2e-net-boot.log` 里（网线接着）是 `ok=1`。

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
