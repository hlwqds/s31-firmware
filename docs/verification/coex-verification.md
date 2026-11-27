# 共存验证报告

- 规范依据：共存不是 IEEE 或 Bluetooth 的标准，而是 Espressif 的实现。对照物是 ESP-IDF 源码（`~/esp/esp-idf`）、ROM 里的仲裁核（`esp32s31.rom.coexist.ld`）和 `libcoexist.a`。设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`。
- 验证分级见 `docs/REPO-STANDARDS.md` §4：L1 主机、L2 镜像、L3 板侧自检、L4 真链路。
- 本报告只写实际跑过的命令和输出里出现过的结果。没有证据的项写"未验证"。

## 1. 结论摘要

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| C0 非探针 BLE 闭包链接 | L2 | 修复后通过 | §2.1 |
| C0 合并链接实验 | L2 | C 对象层只有 4 个同名符号；Zig 层未触及 | §2.2 |
| C0 容量 | L2 | 纯 BLE 闭包镜像 text 745 KB，已占 irom 窗口的 95% | §2.3 |
| C1 共存 glue | L1 | 45/45；23 个 Wi-Fi 包装函数与 20 个 BLE 函数对照 IDF 源码逐条一致 | §3.1、§3.2 |
| C1 自检 | L3 | 第一次上板 10/10（对着假核心） | §3.4 |
| C2 接线：开 `-Dcoex` 的镜像 | L2 | BLE 闭包、BLE 探针、Wi-Fi 探针三种镜像链接通过，恰好两段，无孤儿段 | §4.3 |
| C2 接线：关 `-Dcoex` 的镜像 | L2 | 默认、BLE 闭包、BLE 探针、Wi-Fi 探针四种镜像与改动前逐字节相同 | §4.2 |
| C2 真核心上板（BLE 探针） | L3 | 参数指针非零、两行版本、适配表被收下、两个 BLE 回调都登记；与非 coex 对照走到同一处 | §4.4 |
| C2 真核心上板（Wi-Fi 探针） | L3 | 共存库自己打出两行版本、`wifiInit rc=0`、`INIT OK`；随后的 panic 来自探针写死的地址，对照在同一处也 panic | §4.5；更正见 §9.2 |
| C3 冲突面 | L2 | 两棵树同链一共 12 个符号撞名（Zig 层 6、链接器层 6），未定义 0 | §6.1 |
| C3 提供者统一 | L2 | 按规则定出每个符号留谁（落选方改弱符号）之后，合并镜像链接通过：恰好两段，重复 0，未定义 0 | §6.2 |
| C4 合并镜像上板 | L3 | 8/8 段通过、`main: verdict=pass`；`esp_wifi_init_internal rc=0`、`bringup.init rc=0`；`wifi=inited ble=inited rej=0` | §7.1 |
| C4 窗口扩大 | L2 / L3 | 默认镜像只有重定位差异；新 drom 基址下 8/8；irom、drom 的新上限各有一次实板证明 | §7.2–§7.4 |
| C4 分区表 | — | 没有改：init 级的合并镜像 1 117 376 B，装得下现有 factory 分区 | §7.5 |
| Wi-Fi 侧 `_coex_enable` | L3 | blob 调了它，核心回 `rc=0`，Wi-Fi 侧变成 `enabled` | §9.1 |
| C5 PHY 与时钟域的归属模型 | L1 / L4 | 归属模型 11 项主机用例（`owner.zig`：Owner、ClockBits、时钟单元表 `clocks`）。**时钟域已接并上板（2026-11-27，§16）**：两边只置自己的单元位，共享字在四个时点与并集逐位一致，20/20。PHY 的归属规则见下面「合并镜像里的 Wi-Fi 真实链路」一行 | §8、§16 |
| 探针镜像回归 | L3 / L4 | BLE 探针开共存仍走到原来的墙，SRAM 布局读数不变；Wi-Fi 探针开共存仍 `INIT OK`，并走到 `esp_wifi_start`（2026-11-25 起返回 0，见下一行）。2026-11-27 时钟写改成只置位之后两个单射频镜像各回归一轮：BLE 探针与基线逐行等价（`logs/bt-probe-clock-union-boot.log`）；单独的 Wi-Fi 真实链路镜像扫描 37 个 AP、连上、DHCP、ping 10/10（`logs/wifi-link-clock-union-boot.log`）。同晚中断桥的登记下标修掉之后（§17.5），BLE 探针又回归一轮：`logs/bt-probe-bridge-index-boot.log` 与基线逐段相同（只有计数值与串口交错不同），照旧走到 synth 墙 | §6.5、§16、§17.5 |
| modem 的 ICG 码（Wi-Fi 侧 R3.1 的墙） | L3 | Wi-Fi 探针 `esp_wifi_start rc=0`、init 之后 `MAC_ST=0x00000000`；合并镜像重跑 0 个失败。BLE 侧不能接（探针锁死）——**2026-11-26 更正**：锁死的两份日志来自已经不在树里的旧探针；合并镜像里 BLE enable 在 ICG 已生效时返回 0、没有锁死 | §11、§14 |
| 共存的真实效果（L4b，两个射频都开） | L4 | 有了第一条证据（2026-11-27 晚，§17.5）：合并镜像里 BLE 经 HCI 起广播——合成器锁定位在广播使能后 35 ms 置位，BLE 广播着的时候 Wi-Fi 连上真实 AP、DHCP、ping 10/10（往返平均从 3.5 ms 涨到 45 ms），工作站的蓝牙扫描看到板子的广播 `s31`。此前卡住的根因是中断风暴（中断桥登记错了一个下标），单变量对照在最终代码上做过。**没有做的**：按广播间隔的时延与丢包、PTI 行为；「核真的在仲裁」的两条判据都还没有过——五个硬件定时器在每个时点都是 `en=0`、相隔 1 ms 的两次读数相同，三组状态位有了读数但对不上名字（§17.5）。**一个射频在收发、另一个 enabled**：两个控制器同镜，Wi-Fi 连上真实 AP（见下面「合并镜像里的 Wi-Fi 真实链路」一行）。修之前的样子见 §17.2–§17.4 | `logs/coex-merged-wifi-link-ble-adv12-boot.log`、`logs/coex-merged-wifi-link-ble-adv13-boot.log`、`logs/coex-merged-wifi-link-ble-adv-storm-boot.log`、`logs/coex-merged-wifi-link-ble-adv11-ap-syslog.log`、`logs/coex-merged-wifi-link-ble-adv11-ap-frames.log`、`logs/coex-merged-wifi-link-ble-adv11-bt-scan.log`；§17.5 |
| 只开 Wi-Fi 的共存读数（L4a） | L4 | 共存核开着时真实链路能通（连上、DHCP、ping 网关 10/10）；胶水没有拒绝过一次调用；blob 的 13 次申请核都回 `0x102`，原因在核的静态表里（这些事件没有配硬件定时器）；BLE 没开，核的状态位是 0。不开共存的对照已补，判据成立（§13）。**更正**：初稿写的"硬件定时器都是 0"不成立——当时读的 `0x2010F008` 是共存低功耗时钟的配置，不是计数器（§12） | `logs/wifi-link-connect-boot.log`；§12、§13 |
| 不开共存的对照（ADR-003 L4a 的判据「ping 与不开共存时一样」） | L4 | **成立**：胶水按 IDF 关闭分支作答、核不启动（`-Dcoex` + `-Dcoex-sw-off`）时扫描 38 个 AP、连上 2566 ms、DHCP 46 ms、ping 10/10。只去掉 `-Dcoex` 的两轮收不到帧（扫描 0 个 AP、连接 `reason=201`），根因是 `_coex_pti_get` 的计数桩把出参写成 0——只把这一处改成不写，计数桩的镜像也照常（扫描 37 个 AP、ping 10/10）。**共存核不是 Wi-Fi 收发的前置**：本表初稿写反了，已更正 | `logs/wifi-link-nocoex-boot.log`、`logs/wifi-link-coex-off-boot.log`、`logs/wifi-link-stubs-pti-boot.log`；§13 |
| 合并镜像里的 BLE enable（`-Dcoex-ble-enable`） | L3 | `bringup.enable rc=0`、`ENABLED`，共存核 BLE 侧 `enabled`；没有锁死、没有复位。synth 锁定位（`0x201098BC` 的 bit2）在 enable 前后都是 0——这是预期值：合成器是广播使能命令处理之后才上电的，这一轮没有发 HCI 命令，**对 R3.3 不构成结论** | `logs/coex-merged-ble-enable-boot.log`；§14 |
| 合并镜像里的 Wi-Fi 真实链路（`-Dcoex-wifi-link`） | L3 / L4 | 两个控制器同镜：BLE `INITED`、`ENABLED`，Wi-Fi 扫描 35 个 AP、连上 2059 ms、DHCP 51 ms、ping 网关 10/10，16/16 项通过，`verdict=pass`（2026-11-26）。前提是 Wi-Fi 先 `esp_wifi_start`，并且 BLE 的 init 不再做两段会重做 PHY 的打开与标定的事（`probe_ptr.initPhy`、第 15 步的 `esp_phy_load_cal_and_init`）：五个单变量对照里，只跳过其中一段，扫描就从三十多个 AP 掉到 1–2 个，而连接、DHCP、ping 的判据照样全过（所以加了一条「扫描 AP 数不低于基线一半」）；当时不写回时钟 / 电源寄存器就 `reason=7` 断开——2026-11-27 查清是 BLE 整字覆盖了 Wi-Fi 的时钟位，改成只置位之后不再写回（§16） | `logs/coex-merged-wifi-link-*.log`（通的一份与五份对照）、`logs/coex-merged-wifi-link-deaf-boot.log`（BLE 先 init，不通）；§15、§16 |
| AP 侧的证据（OpenWrt AP，2026-11-26 晚） | L3 | AP 的系统日志里，修之前的每一轮都是「板子没有确认认证响应」——发得出、收不到；最终形态是完整序列，AP 看板子 -24 dBm、双向 86 Mbit/s、15 秒里重传 0–1 次。只跳过第 15 步时，AP 发给板子的帧放弃 51 次（共 51 帧）、速率压到 6–8.6 Mbit/s，而信号一样强：退化在板子的接收侧。板子的 ARP 应答能跨过 AP 的桥到达同网段的另一台主机；板子不回应别人的回显请求（数据通路的缺口，与共存无关）。空口上的帧见下一行 | `logs/coex-merged-wifi-link-ap-syslog.log`、`logs/coex-merged-wifi-link-ap-side.log`；§15.8 |
| 空口上的帧（AP 上临时 monitor 接口，2026-11-27 凌晨） | L4 | 最终形态、E 的第三次、C 的第二次、B 的第三次、D 的第三次，共 373 帧。板子发来的帧在五个轮次里都是 -21 到 -28 dBm（扫描掉到 2–3 个 AP 的三轮也一样）：板子的发射没有坏。连上的四轮，空口上的关联过程同序同间隔（消息 1 之后 260–262 ms 才有消息 2，最终形态也是这样）。C 那一轮板子的认证请求、关联请求都到了 AP，AP 也都答了（关联应答是「成功、AID 1」），但 hostapd 没留下这个站点，消息 1 从来没有发出 | `logs/coex-merged-wifi-link-ap-frames.log`；§15.9 |
| 时钟域按单元取并集（2026-11-27） | L4 | BLE init / enable / 整轮 Wi-Fi 链路之后共享字都是两边的并集（`CLK_CONF1=0x003FFFFF`、`CLK_CONF=0x7E601002`、LPCON=0x0F、时钟源 0x3D），不再有事后写回；基线 38 个 AP、之后 34 个，连上、DHCP、ping 10/10，20/20。判据在第一次上板时抓到了 Wi-Fi 自己的 enable / disable 钩子里的两处整字写 | `logs/coex-merged-wifi-link-union-boot.log`；§16 |
| 路线图 C9：板子回别人的 ping（2026-11-27 晚） | L4 | 工作站 ping 板子，两遍 Wi-Fi 链路里板子答了 97 + 118 帧，工作站收到 215 个应答，逐遍对得上；37/37 | `logs/coex-merged-c9-pingin-boot.log`；§20.2 |
| 路线图 C9：「BLE 先起」的顺序（2026-11-27 晚） | L4 | 三个单变量对照：PHY 由 BLE 的 init 打开时 Wi-Fi 只扫到 4 个 AP（时钟位都在，是标定的问题）；PHY 没开就做 controller 的 init，第 7 步停机；**先按 Wi-Fi 的路径打开 PHY、再做 BLE 的 init、最后 Wi-Fi start**，扫描 32 个 AP、两遍链路都通，36/36。不能反的是「谁打开 PHY」，不是 controller 的先后 | 三份 `logs/coex-merged-c9-blefirst-*-boot.log`；§20.3 |
| 路线图 C9：BLE 的下电路径（2026-11-27 晚） | L4 | 照 IDF `bt_controller_disable` 的顺序关 BLE：只属于 BLE 的时钟位关了、时钟源回到 BLE 来之前、Wi-Fi 与 PHY 的位一个不少（三轮相同）。controller 的八步之间要留时间：连着做之后 Wi-Fi 36 秒里扫不到 AP（25/28）；每步之后空转 2.5 秒或扫一次都正常（28/28）。隔多久、隔在哪几步之间，没有定 | 三份 `logs/coex-merged-c9-bledown-*-boot.log`；§20.4 |
| 路线图 C9：计数桩对齐 IDF 的关闭分支（2026-11-27 晚） | L1 / L4 | 23 个钩子逐项对过，三处改齐（`_coex_init` / `_coex_enable` 不再调核、`_coex_schm_flexible_period_get` 回 1、探针的 init 关着共存时不再调核）；不开 `-Dcoex` 的镜像不再链 `libcoexist.a`，单独的链路探针回归照常（32 个 AP、ping 10/10） | `logs/wifi-link-stubs-aligned-boot.log`；§20.5 |
| 路线图 C9：分区表与 compiler_rt（2026-11-27 晚） | L2 | 都不用动：最大的合并镜像 1 261 424 B，是 factory 的 82.1%；compiler_rt 在合并镜像里 36 个符号 6 604 B、默认镜像里 782 B，没有 f128 的例程 | §20.6 |

## 2. C0 调研与设计（2026-11-24）

### 2.1 非探针 BLE 闭包链接：修复前后

命令（仓库根目录）：

```bash
env -u LD_LIBRARY_PATH bash scripts/check-bt-link.sh
```

修复前：第 2 步 `链接失败（rc=1）`，11 个未定义符号。它们全是只在 `-Dbt-probe` 构建里编译的诊断导出（定义在 `components/bt-blobs/src/{probe,bringup,osi_impl}.zig`），而 `boards/esp32s31-coreboard/src/trap.zig` 在 `bt_linked.present` 为真时、`components/bt-blobs/link/*.c` 无条件引用它们：

```text
bt_print_osal_stats  dbg_tim_armed  dbg_tim_fires  dbg_tim_fn
probe_dump_now       s31AssertYield
s31_bt_log_dropped_inc  s31_bt_log_mute_get  s31_bt_raw_line
s31_bt_raw_put          s31_bt_ring_put
```

修复：新增 `components/bt-blobs/link/closure_stubs.zig`（与探针默认行为一致的空实现：日志静默、断言行直写 UART、其余空操作），由 `firmware/build.zig` 的非探针分支经 `bt_probe` 关闭垫片挂进 app 的模块树（提交 `3194bf6`）。只影响"给了 blob 目录且没开探针"这一种配置；探针镜像和不带 blob 的镜像都不编译它。

修复后，同一条命令的输出：

```text
== 3/3 断言镜像里有 blob 代码 ==
   镜像 950756 字节（普通构建约 162 KB）
bt 链接门禁：OK（116 个对象，镜像 950756 字节）
```

`riscv32-esp-elf-readelf -S -W firmware/zig-out/bin/app.elf` 的三个装载段：

```text
.flash.text     0x0b5ce0 = 745056 B
.flash.rodata   0x01db60 = 121696 B
.iram_blobs     0x00f1b0 = 61872 B
```

### 2.2 合并链接实验

目的：把两个 blob 的整闭包放进同一次链接，看链接器报出多少冲突。不带探针、gc 关（量体积形态），`libcoexist.a` 的 11 个成员经 `-Dphy-src-objs` 加入。命令在 `firmware/` 下：

```bash
env -u LD_LIBRARY_PATH zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
  -Dwifi-blob-dir=/tmp/blobobjs -Dwifi-blob-objs=<该目录下全部 .o，逗号分隔> \
  -Dbt-blob-dir=/tmp/bt-link-gate/flat -Dbt-blob-objs="$(cat /tmp/bt-link-gate/flat/objs.csv)" \
  -Dphy-src-objs=<libcoexist.a 解包出的 11 个 .o>
```

| 输入 | 同名符号 | 未定义符号 |
| --- | --- | --- |
| Wi-Fi 对象含量体积桩 `zz_stubs.o` | 4：`sprintf`、`free`、`net80211_printf`、`pp_printf` | 0 |
| 去掉 `zz_stubs.o` | 0 | 61 |

4 个同名符号全是 `zz_stubs.o` 与 BT 侧 C 桩的撞名：`sprintf` 对 `bt_stubs.c`，`free` 对 `phy_stubs.c`，两个 `printf` 对 `printf_shim.c`。

61 个未定义是 Wi-Fi 侧必须自己提供的符号：24 张 `est_PHY_*` 表（PHY 初始数据，仓库里只有全零占位）、mesh 与 espnow 的厂商接口约 30 个、`WIFI_EVENT` 等数据符号、3 个日志函数。

判读：C 对象层的统一工作量很小，一份桩即可。这个实验没有编译两边的 Zig 探针，所以 `esp_event_handler_*`、`s31_printf_hook`、两个上下文切换器这些 Zig 层的冲突没有体现，那部分才是 ADR-003 第 2 节的主体。

实验中的一次错误记录：第一次运行时误把 `/tmp/blobobjs` 里的 `libcoexist.a`、`libphy.a` 等归档与解包对象重复链入，得到 322 个同名符号的错误数字；只传 `.o` 重跑后才是上表。

### 2.3 容量数字

| 量 | 值 | 来源 |
| --- | --- | --- |
| irom 窗口 | 786 432 B | `boards/esp32s31-coreboard/linker/s31.ld` |
| drom 窗口 | 720 896 B | 同上 |
| factory 分区 | 1 536 000 B | `firmware/idf-bootstrap/partitions.csv` |
| 纯 BLE 闭包镜像（本仓，gc 关） | text 745 056 B，镜像 950 756 B | §2.1 |
| 纯 BLE controller 镜像（IDF 自带构建，仓库外） | `.flash.text` 528 424 B | `~/esp/bt-ctl-oracle/build/bt-ctl-oracle.map` |
| 链接前的段和（上界） | BLE 闭包 116 个对象 text 439 974 B、iram 65 294 B；Wi-Fi `libnet80211` 加 `libpp` text 410 522 B、iram 2 766 B、rodata 104 937 B | `riscv32-esp-elf-readelf -S -W` 对各对象求和 |

两个 blob 加起来超过现在的 irom 窗口，合并镜像也超过 factory 分区，所以 ADR-003 第 3 节要求先扩窗口和分区。

## 3. C1 共存 glue（`components/radio-coex`）

对照物是 ESP-IDF 源码：`esp_wifi/esp32s31/esp_adapter.c:435-632`（Wi-Fi 侧 23 个包装函数加 1 个留空表项）与 `bt/porting_btdm/controller/btdm_common/src/btdm_coex.c:40-235`（BLE 侧 16 个钩子加 4 个生命周期函数）。

### 3.1 主机测试

```sh
cd components/radio-coex && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 45 tests passed.
```

`zig fmt --check src/` 干净。测试用一个记录型假核心：每个钩子转发的参数与返回值、IDF 留空或返回定值的条目、两个 BLE 回调按 type 保存、乱序调用被拒、适配表布局（20 个表项、80 字节）。

### 3.2 与 IDF 源码的一致性

- 实现代理用一次性脚本从两份 C 源推出每个函数的 `#if` 条件、关闭分支返回值和转发目标，与本组件逐个比较：Wi-Fi 23 个、BLE 20 个，0 处不一致。
- 主代理把 `wifi.zig` 与 `ble.zig` 和两份 C 源并排通读：参数、返回类型、条件（哪些只看 `CONFIG_SW_COEXIST_ENABLE`、哪些还看外部共存、哪两个走电源管理开关且 get 在关闭时返回 1），以及关闭分支的返回值（`curr_period_get` 回 1、两个登记与取信道函数回 -1、`version_get` 在开了共存时回 0 且不写出参）全部一致。

### 3.3 目标编译

```sh
cd components/radio-coex && env -u LD_LIBRARY_PATH zig build-obj -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -OReleaseSmall -fno-emit-bin src/bind.zig   # 通过
```

`bind.zig` 是目标专用的：37 个 `@extern` 指向 `libcoexist.a` 与 ROM 的真实符号，主机构建不编译它。`selftest.zig` 以固件参数编译通过。

### 3.4 板侧自检（第一次上板，2026-11-24）

随 `wifi` profile 上板，对着假核心：`checks: passed=10 failed=0 total=10`。日志 `logs/wifi-selftest-prefix-boot.log`。

### 3.5 一个与 glue 无关、但被这次自检暴露的编译器行为

主代理用桩 `board` 模块在主机上执行同一份自检时，生命周期那条判据为假，而真板上为真。把合取里的每一项单独打印后定位到 `glue.lastError() == @as(?glue.Error, error.AlreadyBooted)`。用与仓库无关的最小程序在主机上复现：

```zig
const E = error{ A, B };
fn opt() ?E { return error.A; }
// 比较 opt() == @as(?E, error.A)
```

| Zig 0.17.1 | `opt() == @as(?E, error.A)` | `e == error.A`（非可选） | `(opt() orelse error.B) == error.A` |
| --- | --- | --- | --- |
| Debug | **false** | true | true |
| ReleaseSafe、ReleaseSmall、ReleaseFast | true | true | true |

Debug 构建下可选的错误集合值用 `==` 比较恒为假。仓库的主机测试正是 Debug；板上固件是 ReleaseSmall，所以那条判据在板上本来就对。自检已改为先解包再比较（`lastErrorIs`）。仓库里其它命中都是可选指针的比较，不受影响。

### 3.6 实现偏离

- 顺序守卫是加上的：IDF 没有共存层的顺序检查。被拒的调用不进核心，回 `ESP_ERR_INVALID_STATE` 或空操作，并计一次拒绝。
- 还没 `boot()` 时钩子按"共存关闭"的桩值作答并计拒绝；IDF 里这种时序不可能发生（`init_coexist` 在启动期）。
- `boot()` 报出核心失败；IDF 的 `init_coexist` 不看返回值。
- 编译期的 `CONFIG_*` 换成运行期的 `glue.Config`，默认取 esp32s31 的 IDF 默认配置。
- glue 自己不提供 `coexist_printf`（C 变参函数）；接线时由 `link/coex_printf_shim.c` 补上（§4.1）。仍未提供：`esp_coex_preference_set`、外部共存的 GPIO 配置。

## 4. C2 接线：把 glue 接进两套适配层（2026-11-24）

开关是 `-Dcoex`（`firmware/build.zig`），默认关。`build.zig` 用 `b.addWriteFiles()` 生成一个只含 `pub const enabled` 的模块 `coex_gate`，各适配层用它做 comptime 分支；胶水模块 `radio_coex`（根是 `radio-coex/src/glue.zig`）只在开关打开时才挂给需要的模块。

### 4.1 接了什么

| 侧 | 位置 | 内容 |
| --- | --- | --- |
| 入口 | `firmware/src/main.zig` | `comptime` 里引用 `radio_coex.bind.boot`，使 `bind.zig` 的 37 个 extern 与 43 个钩子函数体进镜像 |
| 链接输入 | `firmware/build.zig` | `-Dcoex-objs` 给出 `libcoexist.a` 的成员；另编 `components/radio-coex/link/coex_printf_shim.c` |
| BLE 导出 | `components/osal/src/osal.zig` | 11 个 `wr_btdm_coex_*` 开关打开时转发给 `radio_coex.ble.*`；补 5 个原本缺失的强定义（`schm_interval_get`、`schm_curr_period_get`、`schm_curr_phase_get`、`version_get`、`iso_start_int_handle`） |
| BLE OS 钩子 | `components/osal/src/coex_hooks.zig`（新） | 适配表的 18 个函数，用 osal 已有的信号量池、`btdmMalloc`、毫秒时基实现 |
| BLE 生命周期 | `components/bt-blobs/src/porting.zig` | `btdmCoexInit()`、`btdmCoexEnable()` 开关打开时转发；调用点原本就在 IDF 对应的位置（init 第 4 步、enable 第 16 步） |
| BLE 启动与诊断 | `components/bt-blobs/src/coex_wiring.zig`（新）、`probe.zig` | `bringup.init` 之前 `boot()`；泵循环里顺带推进共存定时器；三个阶段各打三行诊断 |
| BLE 的三个桩 | `components/bt-blobs/src/wifi_glue.zig` | `esp_coex_rom_version_get`、`coex_core_ble_conn_dyn_prio_get` 开关打开时经别名转给 ROM 真函数 |
| Wi-Fi 表项 | `components/wifi-blobs/src/init_probe.zig` | `makeTable()` 之后 `radio_coex.wifi.fill(&osi_table)`，24 个表项换成胶水的包装函数 |
| Wi-Fi 生命周期 | 同上 | 原来直接调 ROM `coex_init()` 的位置改为 `radio_coex.wifiInit(null)` |
| Wi-Fi 启动与诊断 | 同上 | arena 与时基钩子就位之后 `bind.boot(...)`；init 之后打两行诊断 |
| Wi-Fi OS 钩子 | `components/wifi-blobs/src/coex_hooks.zig`（新） | 18 个函数，全部转给 osi 表已在用的壳 |
| 链接脚本 | `boards/esp32s31-coreboard/linker/s31.ld` | `.iram_blobs` 增收 `.coexiram*`、`.coexsleepiram*`；两个 ROM 别名符号 |

### 4.2 关着时镜像不变

基线是改动前的提交 `3f4e575`（`git worktree` 检出）。两棵树各构建一次，先删掉旧的 `app.elf`，对每个可加载段做 `objcopy -O binary --only-section=<段>` 后比 SHA-256。先做了空对照：同一提交在两个不同路径的 worktree 里构建，闭包镜像与探针镜像都没有差异，所以路径不是因素。

| 配置 | 段数 | 布局（地址与大小） | 内容 |
| --- | --- | --- | --- |
| 默认镜像 | 9 | 相同 | 全部相同 |
| BLE 闭包（非探针） | 9 | 相同 | 全部相同 |
| BLE 探针 | 10 | 相同 | 全部相同 |
| Wi-Fi 探针 | 9 | 相同 | 全部相同 |

另有一次旁证：收尾时刷回板子的默认固件，`app.bin` 的 SHA-256 是 `7ff95014…`，与基线的默认镜像相同。

途中的一次反例，记下来免得重犯：第一版把 `wifi_glue.zig` 的三个共存桩挪进嵌套结构体（想用 comptime 决定是否发射）。结果 BLE 探针镜像的 `.flash.text` 有 38 个字节、`.flash.rodata` 有 28 个字节不同——4171 个函数都在、大小都一样，但那三个桩和两个邻居在段内换了位。改成"导出留在文件顶层原位、只在函数体里加 comptime 分支"之后恢复逐字节相同。

### 4.3 开着时的镜像（L2）

| 镜像 | app.bin | 段数 | `DROM, IROM` 行 | irom（窗口 786 432） | 孤儿段 |
| --- | --- | --- | --- | --- | --- |
| BLE 闭包 + 共存核 | 955 872 B | 5 | 2 | 753 712 B（余 32 720） | 无 |
| BLE 探针 + 共存核 | 949 328 B | 6 | 2 | 777 712 B（余 8 720） | 无 |
| Wi-Fi 探针 + 共存核 | 572 240 B | 5 | 2 | 379 824 B（余 406 608） | 无 |

Wi-Fi 探针不开共存时是 556 416 B、irom 369 376 B；开了多 10 448 B，是共存核与胶水的体量。

链接层查清的四件事：

1. **只缺两个符号。** 把 `libcoexist.a` 的 11 个成员并进 BLE 闭包构建，链接器只报 `coexist_printf` 与 `puts`。ROM 侧的 `coex_core_*`、`coex_env` 等已被现有链接脚本覆盖。
2. **孤儿段。** 第一次链接成功后 `readelf` 里多出 `.coexiram.1` 到 `.coexiram.12`，地址落在 `0x2e00fdb0` 一带——那是 `lpdata`（LP RAM，ULP keeper 的地盘），不是可执行的 IRAM。IDF 用 `esp_coex/linker.lf` 把 `.coexiram+` 收进 `iram0_text`；我们的 `.iram_blobs` 漏了这一族。补上之后 `.iram_blobs` 从 61 872 B 变成 62 736 B。
3. **适配表没有 MD5 校验这回事。** `libcoexist.a` 里有 `Invalid coexist adapter function md5, internal: %s, idf: %s`。查证：指纹串 `g_coex_adapter_funcs_md5` 定义在库自己内部（`coexist_api.o`），校验函数是 `esp_coex_adapter_funcs_md5_check(const char *md5)`，调用者是两个射频 blob，比的是**头文件** `esp_coexist_adapter.h` 的 MD5（`test_md5/test_md5.sh`），用来发现库与适配头不是同一版。我们的代码不调它，Zig 写的钩子也不受它约束。
4. **探针镜像里的两个桩遮住了 ROM。** `wifi_glue.zig` 强定义了 `esp_coex_rom_version_get`（恒回 `"0"`）和 `coex_core_ble_conn_dyn_prio_get`（恒回 0），官方固件启动时的 "coex: ROM version" 一行在我们这里一直是 0。链接脚本给同地址加了别名 `rom_*`，桩在开关打开时经别名转给真函数，名字不用变。

### 4.4 板级：BLE 探针 + 共存核

烧录用 `firmware/tools/flash.sh /dev/ttyUSB0 <app.bin>`（带读回校验），`tools/capture.py` 抓 45 秒。日志 `logs/coex-ble-probe-boot.log`。

```text
bt coex> coexist rom version %s
coex[boot]: booted=true wifi=idle ble=idle param=0x2f00ffe4 rej=0
coex[boot]: fw=2.0.0 rom=cdcf52b coa=0x2f010480 table=0x2f010480
coex[init]: booted=true wifi=idle ble=inited param=0x2f00ffe4 rej=0
coex[init]: cb0=0x4004dac0 cb1=0x4004daee st+=0 st-=0 regb=0 rgbl=2 chg=0 ini=1 en=0
coex[enable]: booted=true wifi=idle ble=enabled param=0x2f00ffe4 rej=0
```

ADR-003 给 L3 定的判据：

| 判据 | 读数 |
| --- | --- |
| `g_coex_param_ptr` 非零 | `param=0x2f00ffe4`（此前板上恒为 0） |
| 固件与 ROM 版本 | `fw=2.0.0 rom=cdcf52b` |
| 适配表被核心接受 | `coa=0x2f010480`，等于 `table=0x2f010480` |
| BLE 两个回调都登记 | `cb0=0x4004dac0 cb1=0x4004daee`，`rgbl=2` |
| BLE 侧状态机 | boot 之后 idle → init 之后 `inited`（`ini=1`）→ enable 之后 `enabled` |
| 乱序 | 三个阶段 `rej=0` |

第一行 `bt coex> coexist rom version %s` 是共存库自己经 `coexist_printf` 打的：探针镜像里这个符号是 `wifi_glue.zig` 的 Zig 导出，读不到变参，只能把格式串原样转给日志。版本串由诊断行给出。

**对照。** 同一棵树、开关关着的探针镜像（与 `3f4e575` 逐字节相同）烧一次，日志 `logs/coex-ble-probe-control.log`：

| 里程碑 | 开共存 | 对照 |
| --- | --- | --- |
| `bt bringup: INITED` | 有 | 有 |
| `A(rx) sendReadVersion rc=0 stats cmds=3 evt=4` | 相同 | 相同 |
| `A2(rx) sendReset rc=0 btdm_tx=2`、`A4(rx) readBdAddr rc=0 btdm_tx=3` | 相同 | 相同 |
| `sched patchset written (22 regs) pre-200A` | 有 | 有 |
| `ble_hw.c:506` 断言（已知的 synth-ready 墙，R3.3） | 停在这里 | 停在这里 |
| panic | 0 | 0 |
| FE 计数器（三个采样点） | 160，160，160（冻结） | 175，175，175（冻结） |

### 4.5 板级：Wi-Fi 探针 + 共存核

日志 `logs/coex-wifi-probe-boot.log`。

```text
coex> coex firmware version: a830d28
coex> coexist rom version cdcf52b
coex[boot]: booted=true wifi=idle ble=idle param=0x2f01173c coa=0x2f0159f0 table=0x2f0159f0 rej=0
wifi-init-probe: coex wifiInit rc=0
coex[init]: booted=true wifi=inited ble=idle param=0x2f01173c coa=0x2f0159f0 table=0x2f0159f0 rej=0
coex[init]: fw=2.0.0 en=0 req=0 rel=0 sta=0 startcb=1 intset=0
wifi-init-probe: esp_wifi_init_internal rc=0
wifi-init-probe: INIT OK, arena free=261568/299872 B, bad_handle=0, blocking_refused=4
wifi-init-probe: ptr g_coex_param_ptr=0x2f01173c
```

前两行是共存库自己打的，经 C shim 真格式化（`%s` 已展开）。`startcb=1` 是 blob 在 init 期间经胶水登记了 start 回调。最后一行是探针自己的转储：不开共存时这一行是 `0x00000000`。

**随后的 panic 不是共存带来的。** 探针在 `INIT OK` 之后继续做它的 pre-start 实验（`init_probe.zig:1125`）：

```zig
const clearStatus = @as(*const fn (u32) callconv(.c) usize, @ptrFromInt(0x2f005b0c));
```

它把 blob 的一个 RAM 函数写死成 `0x2f005b0c`。开了共存后 arena 前面多了共存核的分配，那个地址不再是函数，跳进去落在数据里：

| | 开共存 | 对照（`logs/coex-wifi-probe-control.log`） |
| --- | --- | --- |
| `INIT OK` 之后到 panic 之前的行数（去掉逐条 OSI 转储） | 123 | 123，逐行对应 |
| 异常 | code 6（store address misaligned），`mepc=0x2f005b12` | code 7（store access fault），`mepc=0x4004c70a`，`mtval=0xe030` |
| `esp_wifi_init_internal rc` | 0 | 0 |
| `g_coex_param_ptr` | `0x2f01173c` | `0x00000000` |

对照在同一处也进 trap。**【2026-11-24 更正】**上面"开了共存后 arena 前面多了共存核的分配，那个地址不再是函数"
这句推断是错的：用带符号表的镜像核对，`0x2f005b0c` 在**关着共存的对照镜像里**同样落在 `ppEnqueueTxDone`
（`0x2f005ac4`，长 `0x62`）的函数中间，不是任何函数的入口。那是一个从来没成功过的实验调用，与共存无关；
已删除，探针现在能走到 `esp_wifi_start`（§9）。

因为那次 panic，探针在 start 之前就停住，`_coex_enable` 这条路径在**当时**的板上没有被 blob 执行
（诊断行 `en=0`），Wi-Fi 侧停在 `inited`。现在的结果见 §9.1：已执行、已收下。

### 4.6 复现命令

都在 `firmware/` 下，`zig` 用 `/tmp/bin/zig`，先 `env -u LD_LIBRARY_PATH`。

共存核的对象（11 个）：

```bash
mkdir -p /tmp/coex-objs
riscv32-esp-elf-ar x --output /tmp/coex-objs \
  ~/esp/esp-idf/components/esp_coex/lib/esp32s31/libcoexist.a
COEX="$(ls /tmp/coex-objs/*.o | paste -sd,)"
```

BLE 闭包、BLE 探针：

```bash
zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall -Dbt-blob-dir=/tmp/bt-link-gate/flat \
  -Dbt-blob-objs="$(cat /tmp/bt-link-gate/flat/objs.csv)" -Dcoex=true -Dcoex-objs="$COEX"
# 探针再加：-Dbt-probe=true -Dphy-src-objs=<IDF 构建里的 phy_init.c.obj,phy_common.c.obj,btbb_init.c.obj>
```

Wi-Fi 探针的完整配方此前没有记录在仓库里（只留下了量体积的那一条），这次从 `/tmp` 下的对象清单拼出来、在基线上试通：

- 一个目录里放全部对象、名字逗号分隔：`libcore.a`、`libpp.a`、`libnet80211.a` 的 105 个成员，`esp_phy/lib/esp32s31/libphy.a` 的 21 个，`libmesh.a` 的 15 个，`libespnow.a` 的 2 个；
- `-Dphy-src-objs` 给 IDF 参照构建（`~/esp/bt-ctl-oracle/build/esp-idf`）里的 6 个对象：`phy_init.c.obj`、`phy_common.c.obj`、`btbb_init.c.obj`、`modem_clock.c.obj`、`periph_ctrl.c.obj`、`modem_clock_hal.c.obj`；
- `-Dwifi-init-probe=true -Dwifi-blob-dir=<该目录> -Dwifi-blob-objs=<名字>`；
- 不开共存时，`libcoexist.a` 的 11 个成员要混在 `wifi-blob-objs` 里（探针直接调 `coex_init`）；开共存时改走 `-Dcoex=true -Dcoex-objs=`。

辅助开关 `-Dkeep-symbols=true` 保留符号表，用来核对"某个符号进没进镜像"（strip 过的 ELF 连必然存在的符号都列不出来）。它的镜像**不等同于** strip 的镜像：`trapDispatch` 按有没有符号信息选诊断路径，`.flash.text` 里有 4 个字节随之变化。只拿它核对符号。

### 4.7 顺带修掉的一个验证漏洞

`wifi-blobs` 的 26 个主机用例此前**没有任何门禁跑过**，而且测试文件本身编不过：

- 它没有自检 section，`build.zig` 里遍历 `all_modules` 的循环建不出它的测试目标；覆盖率门禁 `check-coverage.py` 只数 `test` 的文本个数，照样判 OK。
- 补上目标之后连报四类错误：`host_tests.zig` 里 `testNowUs` 定义了两次；一个用例访问了私有的 `impl.hooks`；`osi.zig` 的 `indexOf`/`nameOf` 用了 0.17 已改名的 `.fields`；`osi_impl.zig` 的 `shellSetIntr`、`shellSetIsr`、`shellIntsOn/Off` 直接写 MMIO、执行 RISC-V 汇编、引用 `board`，在 x86 主机上编不过。链接期还缺 5 个板级符号。

修法：`build.zig` 加显式测试目标；`host_stubs.zig` 给 5 个板级符号空实现（与 `bt-blobs/src/host_stubs.zig` 同一做法）；那四个壳在非 freestanding 目标上提前返回（计数器照常累加）；`.fields` 改 `.field_names`。修完 31/31 通过（26 个旧用例 + 4 个共存钩子用例 + 1 个替身用例）。

另有一个用例发现的细节：`test` 块里只认直接的 `@import("x.zig")`。写成文件顶层的 `const x = @import("x.zig")` 再在 `test` 块里 `_ = x`，那个文件里的用例不会被跑。

### 4.8 实现偏离（C2）

- 启动位置：IDF 在系统初始化的 SECONDARY 级（早于 `app_main`）；裸机镜像放在"第一个碰射频的 init 之前"——BLE 探针在 `bringup.init` 的紧前面，Wi-Fi 探针在 arena 与时基钩子就位之后、建表之前。
- `boot()` 失败不拦住后续：胶水按 IDF 关闭分支的桩值作答并计拒绝，诊断行打出原因。
- BLE 侧 OS 钩子（`osal/src/coex_hooks.zig`）：拿不到锁时不真睡，只在短窗口内自旋重试后回报失败并计数；`ets_timer` 是软件定时器（核手里的定时器指针当键，函数与到期时刻记在侧表里，由泵循环推进）；"是否在中断里"看 `mstatus.MIE`，临界区也算中断（安全的一侧）。
- Wi-Fi 侧 OS 钩子（`wifi-blobs/src/coex_hooks.zig`）：`*_from_isr` 即不等待的 take/give，出参 `hptw` 写 false；`_xtal_freq_get` 回常量 40，`_debug_matrix_init` 回 0。
- `_coex_condition_set` 留空（IDF 也留空）。
- BLE 侧没有 disable/deinit 的调用点（`bringup` 没有 disable 路径），enable 之后停在 `enabled`；同一次启动里再 init 会被胶水拒绝。
- `-Dcoex` 一次只接一个射频的适配层，两个 blob 目录同给时 `build.zig` 直接报错。（C3 起另开了
  `-Dcoex-merged`，见 §6.4；不带它的那条报错还在。）
- `-Dcoex` 不能与 `-Dwifi`（自检 section）同开：`radio_coex` 的 section 模块与胶水模块不能同时含 `glue.zig`。

### 4.9 未验证

- 【2026-11-24 更新】两个射频同时在一个镜像里：已在 C3、C4 做到 init 都返回（§6、§7）；共存的任何实际效果
  （L4）仍然没有证据。
- 【2026-11-24 更新】Wi-Fi 侧的 `_coex_enable`：已执行、已收下（§9.1）。
- 18 个 OS 钩子在有争用时的行为：只做了主机测试，板上核只走了"立即拿到锁"的路径。
- 共存核的硬件定时器：只开 Wi-Fi 的那一轮里 blob 只申请过事件 7 和 9，核里这两个事件没有配定时器，所以没有定时器被武装，无从观察它走不走。【2026-11-26 更正】初稿写的"寄存器恒为 `0x00000314`，没在走"读错了对象：那个寄存器是共存低功耗时钟的配置（§12）。BLE 开起来之后走不走仍未验证。
- 回调被核心调用的时刻（使能计数升到 2 / 降回 1）：需要两个射频都开，目前只验证了登记。

## 5. 总览：C3–C5 做到了哪（2026-11-24）

| 项 | 结果 | 还差什么 |
| --- | --- | --- |
| C3 运行时统一 | 两棵树能链进同一个镜像并上板；冲突面 12 个符号，按规则各留一个提供者 | 设计里的"一个调度器 / 一份 osi / trap 钩子多槽"没有做——量过之后不需要（§6.3） |
| C4 合并镜像 | 上板 8/8 段通过，两个控制器的 init 都返回 0 | 只做到 init（合并镜像不调 `esp_wifi_start`）；Wi-Fi 侧 R3.1 的墙已拆（§11），BLE enable 仍待 R3.3 |
| C4 窗口 | irom、drom 各扩到 `0x1C0000`，drom 基址后移；两侧新上限各有一次实板证明 | 分区表没有改（§7.5） |
| C5 归属模型 | 纯逻辑模型 + 10 项主机用例 | 寄存器序列没有接（§8） |
| C6 共存性能 | 只开 Wi-Fi 时的核读数已有（L4a，§12） | 阻塞：等 R3.3（synth）；R3.1、R3.2 已拆（§11、`wifi-ieee80211-verification.md` §11） |

## 6. C3 运行时统一：两棵树同链

### 6.1 冲突面实测

把 Wi-Fi 侧（`components/wifi-blobs`）与 BLE 侧（`components/bt-blobs`、`components/osal`）的适配层、
两个 blob 的整闭包、`libcoexist.a` 的 11 个成员放进同一次链接（开 gc，两边各有真实入口）：

| 层 | 结果 |
| --- | --- |
| Zig 编译期 | 6 个导出撞名：`s31_coex_log_hook`、`esp_event_handler_register`、`esp_event_handler_unregister`、`putchar`、`puts`、`strtok` |
| 链接器 | 压掉上面 6 个之后另有 6 个重复符号：`sprintf`、`rtc_clk_xtal_freq_get`、`phy_printf`、`free`、`s31_printf_hook`、`get_phy_version_str`；未定义 0 |

一次走弯的记录：第一次实验报了 334 个重复符号，数字是假的——输入不干净。`/tmp/blobobjs` 里混着量体积桩
`zz_stubs.o`，而且 `libphy.a` 被链了两遍（Wi-Fi 那边一份归档，BLE 扁平闭包里又有一份 `libphy_*.o`）。
把输入理成三份互不重叠的集合之后才是上表（§6.6）。

### 6.2 每个符号留谁

规则是「真归档 > 能用的实现 > 计数桩」，落选的一方改成弱符号导出：Zig 用
`@export(…, .{ .linkage = .weak })`，C 用 `__attribute__((weak))`。两条依据都实测过：两个 `export fn` 同名
Zig 在编译期就报撞名；一侧弱符号加一侧强符号可以编译，链接时强符号胜出。单独构建任一射频时没有别的
定义，行为不变。

| 符号 | Wi-Fi 侧原来是什么 | BLE 侧原来是什么 | 留谁（落选方改弱符号） |
| --- | --- | --- | --- |
| `esp_event_handler_register` / `_unregister` | `wifi-blobs/src/event_bus.zig`：能用的注册表，Wi-Fi blob 靠它同步派发事件 | `bt-blobs/src/event_bus.zig`：同构的一份，仓库里没有调用者 | Wi-Fi 侧（BLE 侧改弱） |
| `s31_printf_hook` | `wifi-blobs/src/init_probe.zig`：把驱动的报错打到串口 | `bt-blobs/link/wifi_probe_stubs.c`：丢弃 | Wi-Fi 侧（BLE 桩改弱） |
| `s31_coex_log_hook` | `init_probe.zig`：`coex> …` | `osal/src/osal.zig`：`bt coex> …` | 只能留一份：Wi-Fi 侧（osal 改弱） |
| `putchar` / `puts` / `strtok` | `wifi-blobs/src/link_stubs.zig`：只计数 | `bt-blobs/src/libc_glue.zig`：能用的实现 | BLE 侧（Wi-Fi 桩改弱） |
| `free` | `link_stubs.zig`：只计数，不释放 | `bt-blobs/link/phy_stubs.c`：归还到 BLE arena；不是本 arena 的指针按块头魔数忽略 | BLE 侧（Wi-Fi 桩改弱） |
| `sprintf` | `link_stubs.zig`：回 0，**不写缓冲区** | `bt-blobs/link/bt_stubs.c`：最小实现 | BLE 侧（Wi-Fi 桩改弱） |
| `phy_printf` | `link_stubs.zig`：回 0 | `wifi_probe_stubs.c`：格式串转 raw-line | BLE 侧（Wi-Fi 桩改弱） |
| `rtc_clk_xtal_freq_get` | `link_stubs.zig`：回 0 | `wifi_probe_stubs.c`：回 40 | BLE 侧（Wi-Fi 桩改弱） |
| `get_phy_version_str` | — | `wifi_probe_stubs.c`：`"s31-probe"` | `libphy.a` 的 `phy_debug.o`（真归档；BLE 桩改弱） |
| `coexist_printf` | — | `bt-blobs/src/wifi_glue.zig`：只转格式串，变参丢失 | `radio-coex/link/coex_printf_shim.c`：真格式化（改成强定义，BLE 侧改弱） |
| `puts`（`coex_printf_shim.c` 那份） | 弱定义 | 强定义（`libc_glue.zig`） | 有 BLE 对象时 shim 不再定义它（`-DS31_COEX_NO_PUTS`），避免两个强定义撞名 |

最后一行的效果在 BLE 探针上看得到：共存库自己打的那行版本以前是 `coexist rom version %s`（`%s` 没展开），
现在是 `coexist rom version cdcf52b`（§6.5）。

改完之后同一个实验：重复 0、未定义 0。

### 6.3 运行时约定

ADR-003 第 2 节列了六项（调度器、osi、导出、堆、tick、trap 钩子）。逐项量过之后：

- **调度器**：两个切换原语（`wifi-blobs/src/sched.zig` 的 `s31_swap_context` 与 `osal/src/sched.zig` 的
  `bt_swap_context`）机器码完全相同，链接器把它们折到同一个地址；冲突只可能来自**嵌套**——在一方的任务栈上
  去泵另一方的任务，才会改写对方存的主栈指针。合并镜像把 init 排成「主 → Wi-Fi 任务 → 主 → BLE 任务 → 主」，
  不嵌套。另加一道保险：BLE 的 init 期间置 `wifi-blobs` 的 `foreign_context`，Wi-Fi 侧的让出点只计数、
  不切换。板上读数 `wifi idle hook refused on ble stack n=0`：没有触发。**没有合并两个切换器。**
- **osi**：合并镜像里只有 Wi-Fi 侧的表被注册；`bt-blobs/src` 里那份分叉副本的 `makeTable()` 仍然没有调用点。
  **没有删它**——探针还在用它的 `setHooks` / `serviceTimers`。
- **堆**：一个堆按配额切两段（Wi-Fi 前 3/5，其余给 BLE），两边各拿一段去初始化自己的 arena。
- **tick 与中断**：两边都不开（与各自探针镜像同条件），ISR 入口共用板级的 `trapEntry`。
- **trap 钩子**：两边占的槽不重叠（Wi-Fi 6 个统计钩子，BLE 5 个诊断钩子）。**没有改成多槽。**
- **共存核的 OS 钩子**只有一套（Wi-Fi 侧 boot 时登记的）。板上能看到 BLE 的 init 期间核经这套钩子取放信号量
  （`trace semphr_take a0=0x2f04e170 a1=0xffffffff` 与随后的 `semphr_give`），无争用、立即成功。

两处顺带修掉的东西：

1. **对内存布局写死的地址**。两边的探针实验都带着这种地址，而合并镜像的布局和任何一边的探针镜像都不同。
   Wi-Fi 侧：`initOnly(.{ .experiments = false })` 关掉探针的实验写（`0x2f013d30` 的 blob 上下文块等）。
   BLE 侧：`bringup.zig` 加 `layout_probes` 开关，为假时本文件的 MMIO 助手拦截对 `0x2f01_0f00..0x2f01_1200`
   的访问（写丢弃、读回 0）。核对时发现一件事：`bringup.init` 里注释成「blob 的 lazy-init 槽」的
   `0x2f011130/1134/1138` 和「`s_is_phy_calibrated`」的 `0x2F01_0F80`，在**现在的 BLE 探针镜像里**就已经落在
   我们自己的静态数组 `g_phy_cal_buf` 里（`nm`：`g_phy_cal_buf` 在 `0x2f010c00`，真正的 `s_is_phy_calibrated`
   在 `_bss_start = 0x2f010a00`）。也就是说这些读写今天都是空操作，探针照样走到 INITED；而合并镜像里同样的
   数值会落进 `.iram_blobs` 的代码中间。
2. **日志钩子的代码地址门**。`osal.logLine` 只放行落在可执行区的钩子，而"可执行区"写死成
   `0x4000_0020 .. 0x400A_0300`（某一次构建的实测值）。合并镜像的 text 到 `0x400c99b0`，排到上界之外的
   日志钩子会被整段丢弃且不报错。改成用链接脚本的 `_text_start` / `_text_end`。

### 6.4 构建开关与入口

- `firmware/build.zig` 新增 `-Dcoex-merged`：要求 `-Dcoex` 与两个 blob 目录，不能与 `-Dwifi-init-probe` /
  `-Dbt-probe` 同开。入口不变（照常跑各段自检），只在末尾多一个 `coex_merged` section
  （`firmware/src/coex_merged.zig`）。
- Wi-Fi 侧：init 那一段从探针的 `run()` 里抽出成 `init_probe.initOnly(opts)`，到 `INIT OK` 返回；探针的 `run()`
  调完它再接自己的实验。BLE 侧：新增 `probe.initOnly(region)`，只做 `bringup.init` 需要的前置（钩子、时基、堆），
  不带探针的实验装置；共存核不在这里 boot。
- 修了一个重复：`wifi-blobs/src/printf_shim.c` 在"两个目录都给"时会被加进链接两次（两个分支各加一次）。

### 6.5 探针镜像回归

两个探针是"已知正常态"的参照，改完必须还走得通：

| 探针 | 改动前 | 改动后 | 日志 |
| --- | --- | --- | --- |
| BLE + 共存核 | `INITED` → `ble=enabled` → `sendReadVersion rc=0`、`sendReset rc=0`、`readBdAddr rc=0` → 停在 `ble_hw.c:506` | 同一条路径，同样的里程碑 | `logs/coex-ble-probe-c3-boot.log` |
| Wi-Fi + 共存核 | `INIT OK` 之后 panic | `INIT OK` 之后继续走到 `esp_wifi_start`（§9） | `logs/coex-wifi-probe-start-boot.log` |

BLE 探针的 SRAM 布局读数与改动前相同（`param=0x2f00ffe4`、`arena free=274464 B`），说明 SRAM 侧没有挪动。

### 6.6 复现命令

三份互不重叠的对象集合（2026-11-24 配好）：

| 目录 | 个数 | 内容 |
| --- | --- | --- |
| `/tmp/merged-wifi-objs` | 143 | `libcore` / `libpp` / `libnet80211` 的 105 个 + `libphy` 21 个 + `libmesh` 15 个 + `libespnow` 2 个；**不含** `zz_stubs.o` |
| `/tmp/merged-bt-objs` | 102 | BLE 闭包扁平对象去掉 14 个 `libphy_*`（`libphy` 只从 Wi-Fi 那份链一遍；两边成员逐字节相同） |
| `/tmp/coex-objs` | 11 | `libcoexist.a` |

```bash
cd firmware
IDF=~/esp/bt-ctl-oracle/build/esp-idf
PHY3="$IDF/esp_phy/CMakeFiles/__idf_esp_phy.dir/src/phy_init.c.obj,$IDF/esp_phy/CMakeFiles/__idf_esp_phy.dir/src/phy_common.c.obj,$IDF/esp_phy/CMakeFiles/__idf_esp_phy.dir/src/btbb_init.c.obj"
REG="$IDF/esp_wifi/CMakeFiles/__idf_esp_wifi.dir/regulatory/esp_wifi_regulatory.c.obj"
env -u LD_LIBRARY_PATH /tmp/bin/zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
  -Dcoex-merged=true -Dcoex=true -Dcoex-objs="$(ls /tmp/coex-objs/*.o | paste -sd,)" -Dkeep-symbols=true \
  -Dwifi-blob-dir=/tmp/merged-wifi-objs -Dwifi-blob-objs="$(ls /tmp/merged-wifi-objs | paste -sd,)" \
  -Dbt-blob-dir=/tmp/merged-bt-objs -Dbt-blob-objs="$(cat /tmp/merged-bt-objs/objs.csv | paste -sd,)" \
  -Dphy-src-objs="$PHY3,$REG"
```

PHY 源对象取 BLE 探针配方的 3 个；`modem_clock` 一类由 `bt-blobs/link/modem_clock_light.c` 的轻量替身提供。
`esp_wifi_regulatory.c.obj` 是 2026-11-26 补的：`link_stubs.zig` 不再给 `regdomain_table` / `regulatory_data` 留零值桩
（那是扫描不到 AP 的原因之一），缺了这个对象链接期就报未定义符号。
烧录用 `firmware/tools/flash.sh`（带读回校验），抓 45 秒。

在命令末尾加 `-Dcoex-ble-enable=true`，section 在两个 init 之后多跑一步：enable BLE、把 controller 任务泵 1 秒，
前后读 synth 区与时钟 / 射频状态寄存器（§14）。它要求 `-Dcoex-merged`。

## 7. C4 合并镜像与窗口

### 7.1 合并镜像上板

在最终代码树上重跑（2026-11-24 第二次，`logs/coex-merged-boot.log`，483 行）。第一次（07:33）的日志抓在「读两行 `LPCON+0x18`」的代码加进源码之前，留作 `logs/coex-merged-run1-boot.log`；两次的里程碑相同。

```text
coex-merged: heap total=167456 B wifi=100473 B ble=66983 B
coex[boot]: booted=true wifi=idle ble=idle param=0x2f01a5d4 coa=0x2f0218f4 table=0x2f0218f4 rej=0
coex> coex firmware version: a830d28
coex> coexist rom version cdcf52b
coex[init]: booted=true wifi=inited ble=idle param=0x2f01a5d4 coa=0x2f0218f4 table=0x2f0218f4 rej=0
wifi-init-probe: esp_wifi_init_internal rc=0
wifi-init-probe: INIT OK, arena free=62152/100456 B, bad_handle=0, blocking_refused=4
read: LPCON+18 after wifi init=0x00000003
check: wifi esp_wifi_init_internal rc=0 ok=1
bt bringup: INITED
bt init-only: bringup.init rc=0 arena free=28552 B
read: LPCON+18 after ble init=0x0000000f (bit0 wifipwr / bit1 coex / bit2 i2c_mst)
check: ble bringup.init rc=0 ok=1
coex[merged]: booted=true wifi=inited ble=inited param=0x2f01a5d4 coa=0x2f0218f4 table=0x2f0218f4 rej=0
check: coex sides wifi=inited ble=inited (both inited) ok=1
check: coex rejected calls=0 ok=1
check: wifi idle hook refused on ble stack n=0 ok=1
checks: passed=6 failed=0 total=6
firmware: sections: passed=8 failed=0 total=8
main: verdict=pass
```

| 判据 | 读数 |
| --- | --- |
| 两个控制器的 init 都返回 | `esp_wifi_init_internal rc=0`、`bringup.init rc=0` |
| 共存核两侧 | `wifi=inited ble=inited`，`rej=0` |
| 合并 section | 6/6；整镜像 8/8 段、`main: verdict=pass`（聚合行不计 `coex_merged`） |
| 异常 | 整份日志里没有 panic、trap 行 |

**`LPCON+0x18`（`MODEM_LPCON_CLK_CONF_REG`）的两行读数**，给 ADR-003 第 4 节的归属模型留的对照。位定义取自 IDF 的 `soc/esp32s31/include/modem/modem_lpcon_reg.h`：bit0 `WIFIPWR_EN`、bit1 `COEX_EN`、bit2 `I2C_MST_EN`、bit3 `LP_TIMER_EN`。

| 时点 | 读数 | 置位的位 |
| --- | --- | --- |
| Wi-Fi init 之前（探针按 IDF 对正） | `0x4 → 0x1` | 只留 wifipwr |
| Wi-Fi init 之后 | `0x3` | wifipwr、coex（共存核在 Wi-Fi init 期间置上） |
| BLE init 之后 | `0xF` | 再加 i2c_mst（BLE 的 PHY）与 lp_timer（BLE 的 LP 定时器时钟） |

这与第 8 节里按 IDF 实测写进用例的 `0x1 → 0x7 → 0x1` 不是同一条序列：本镜像里共存时钟在 Wi-Fi init 时置上之后一直留着，BLE 侧多置了 lp_timer。它只是读数——归属模型没有接到任何启动路径上（第 8 节）。

### 7.2 占用

取自同一次构建（`readelf -S -W app.elf`、`esptool image-info`）：

| 量 | 值 |
| --- | --- |
| `.flash.text` | 826 960 B（旧 irom 窗口 786 432 B 装不下） |
| `.flash.rodata` | 156 656 B（旧 drom 窗口 720 896 B 装得下） |
| `.iram_blobs` | 100 208 B |
| `.data` / `.bss` | 35 984 B / 168 832 B |
| 堆（`_heap_start.._heap_end`） | 167 456 B：Wi-Fi 100 473 B，BLE 66 983 B |
| init 之后各侧余量 | Wi-Fi 62 152 B（arena 100 456 B），BLE 28 552 B |
| `app.bin` | 1 120 464 B（factory 分区 1 536 000 B，余 415 536 B） |
| `image-info` | 恰好两行 `DROM, IROM`：IROM `0xc9e50` @ `0x40000020`，DROM `0x263f0` @ `0x401d0020` |

第一次上板时的占用（07:33 的构建，`bt-blobs` 的 HCI 一致性自检并入之前）：`.flash.text` 825 744 B、`.flash.rodata` 154 800 B、`app.bin` 1 117 376 B。第 7.4 节 irom 新上限的证明引用的是这一次的 825 744 B，现在的 826 960 B 同样超过旧上限。

### 7.3 默认镜像：只有重定位

drom 基址后移之后 `app.bin` 不可能逐字节相同。能证明、也该证明的是「除了重定位什么都没变」。
基线是改动前的提交 `4f47fdf`（`git worktree` 检出），两边用同样的参数构建默认镜像（boot + net）：

| 段 | 结果 |
| --- | --- |
| `.flash.text` | 地址与大小相同（145 968 B）。反汇编逐条比较（`objdump -d`）：两边都是 48 062 条指令，地址、长度、助记符零差异；1 903 处 `lui` + `addi` 合成的 32 位常量全部等于「旧 rodata 地址 + `0xD0000`」，另 2 处单独的 `lui` 立即数也恰好差 `0xD0000` |
| `.flash.rodata` | 基址 `0x40100020` → `0x401d0020`，大小相同（46 800 B）。971 个不同的字节分两类：111 个字是指向旧 rodata 的指针（各 +`0xD0000`），860 个字是 text 与 rodata 之间的相对偏移（各 −`0xD0000`）；没有未解释的差异 |
| `.trap_ram`、`.data` | 逐字节相同，地址不变 |
| `.bss`、`.btdm_bss`、`.phy_cal_buf`、`.btdm_data` | 大小与地址不变 |
| 板级 | `run_e2e.py --board --profile net` → `PASS board:net`，8/8 段、`main: verdict=pass`；DROM 段落在 `0x401d0020`（`logs/e2e-net-boot.log`） |

### 7.4 新上限的板级证明

| 段 | 镜像 | 段长 | 旧上限 | 结果 |
| --- | --- | --- | --- | --- |
| irom | 合并镜像（§7.1） | 825 744 B | 786 432 B | 8/8 段通过 |
| drom | 默认镜像 + `-Dfat-rodata=1000000` | 1 046 816 B | 720 896 B | 8/8 段通过、`main: verdict=pass`（`logs/fat-rodata-1000000-boot.log`；`app.bin` 1 243 504 B） |

### 7.5 分区表没有改

ADR-003 第 3 节原计划把 factory 与两个 ota 槽扩到 4 MB 级，理由是"合并镜像也超过 factory 分区（1.5 MB）"。
实测不成立：init 级的合并镜像 1 117 376 B，离 factory 上限还差约 41 万字节。而挪动 `ota_0` / `ota_1` /
`otadata` 的偏移会让已提交的 A/B 证据失效，并牵动 `scripts/demo-board.sh` 等脚本。所以这次只扩了链接窗口，
分区表原样不动。等真有一个装不下的镜像（两个 blob + TLS + 应用同链）时再扩，届时连同 A/B 切槽与回滚的断言一起重跑。

## 8. C5 归属模型（只有主机验证）

`components/radio-coex/src/owner.zig`，依据是 IDF 的 `esp_phy_enable` / `esp_phy_disable`
（`esp_phy/src/phy_init.c:324`、`:408`）：第一个使用者才开 PHY 的公共部分，最后一个离开才关；共存时钟
`PERIPH_COEX_MODULE` 是 BT / Wi-Fi 模块时钟的依赖项，随模块一起计数。

- `Owner.acquire / release(side)` 返回一串要串行执行的动作；公共部分只随首个与末个使用者各动一次。
- `ClockBits`：多个使用者共享一组时钟使能位，一侧放弃只撤自己的位。

```sh
cd components/radio-coex && env -u LD_LIBRARY_PATH /tmp/bin/zig test src/host_tests.zig   # All 55 tests passed.
```

55 = 胶水原有 45 项 + 归属模型 10 项。10 项覆盖：两个使用者的进出顺序（两种次序）、中间使用者离开不动公共部分、
全部离开后再请求公共部分重走一遍、重复请求与无请求的放弃被拒且不改状态、200 步随机序列里公共部分的开 / 关次数
等于使用者数跨越 0 的次数、位图的并与撤、`LPCON+0x18` 按 IDF 实测的 `0x1 → 0x7 → 0x1` 走。

**没有做的**：寄存器序列。模型不碰硬件，也没有接到任何镜像的启动路径上。按 ADR-003 §4 原定的口径，
具体序列要等两个射频各自打通后才能上板验证。

## 9. Wi-Fi 侧的 `_coex_enable`

### 9.1 证据

Wi-Fi 探针开 `-Dcoex`（`logs/coex-wifi-probe-start-boot.log`）：

```text
wifi-init-probe: INIT OK, arena free=261360/299664 B, bad_handle=0, blocking_refused=4
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
wifi-init-probe: _phy_enable(modem=0) -> register_chipv7_phy rc=0
coex> _coex_enable called by blob
coex> coex_enable_wrapper returned rc=0 wifi=enabled ble=idle rej=0
wifi-init-probe: trace wifi_reset_mac a0=0x00000000 a1=0x00000000
…
NMI n=5000 mepc=0x2f009cbe … a4=0000e000 a5=0000e000
```

| 判据 | 读数 |
| --- | --- |
| blob 调了 `_coex_enable` | `coex> _coex_enable called by blob` |
| 核心收下 | `returned rc=0 wifi=enabled ble=idle rej=0` |
| 之后 | 探针停在已知的 R3.1 墙：PC 采样钉在 `0x2f009cb6 / 0x2f009cbe`，掩码 `0xE000` 的 MAC 忙位 |

那两行 `coex>` 是胶水的 `on_enter` / `on_leave` 回调打的（`init_probe.zig` 的 `coexBoot()` 登记）。
`esp_wifi_start` 不返回，事后的诊断行打不出来，所以只能靠入口与返回处的即时痕迹。（2026-11-25 起返回 0，见 §11。）

### 9.2 对 §4.5 的更正

§4.5 把 `INIT OK` 之后的 panic 归因于「开共存后 arena 前面多了共存核的分配，`0x2f005b0c` 不再是函数」。
这个归因是错的。用带符号表的关共存探针镜像核对（`nm -S -n`）：

```text
2f005ac4 00000062 T ppEnqueueTxDone
```

`0x2f005b0c` 落在 `ppEnqueueTxDone` 的函数中间（起址 + `0x48`），不是任何函数的入口——所以对照镜像在同一处
同样 panic（§4.5 表里的 code 7）。那是一个从来没成功过的实验调用，与共存无关。已删除。

## 10. 实现偏离与未验证

偏离（相对 ADR-003 的设计）：

- 没有合并两个上下文切换器，没有删除 `bt-blobs/src` 的 osi 副本，没有把 trap 钩子改成多槽；同名导出用弱符号
  定提供者而不是合并实现。依据见 §6.3。
- 分区表没有改（§7.5）。
- 归属模型只有主机验证，寄存器序列未接（§8）。
- `coexist_printf` 的提供者从「BLE 侧的 Zig 导出」换成了 C shim（真格式化）；BLE 探针里共存库的日志因此变了样。
- `osal.logLine` 的可执行区判定从写死的地址范围换成链接符号。

未验证：

- 合并镜像里 `esp_wifi_start` 没有跑；BLE enable 跑过一次（`-Dcoex-ble-enable`，§14）：返回 0，synth 锁定位仍是 0。
  两个控制器**同时工作**（至少一个在收发）仍然没有任何证据；BLE enable 之后的 HCI 与射频路径仍待 R3.3。
- 18 个 OS 钩子在有争用时的行为：主机测试之外，板上核只走了"立即拿到锁"的路径；外来上下文保护在板上没有触发过
  （`n=0`），所以它管不管用只有主机侧的推理。
- 共存核的硬件定时器：只开 Wi-Fi 的那一轮没有定时器被武装（blob 只申请了没有配定时器的事件，§12）；BLE 开起来之后未验证。
- BLE 的两个回调被核心调用的时刻：需要两个射频都开，目前只验证了登记。
- 【2026-11-26 更新】Wi-Fi enable 之后 blob 调了哪些共存钩子、核怎么答：已有读数（§12）。
- 共存的真实效果（L4b，两个射频都开）：没有任何证据；只开 Wi-Fi 的读数（L4a）见 §12。【2026-11-26 更新】两个控制器同镜、
  一个射频在收发的读数见 §15；两个射频都在收发仍然没有证据。
- 不开 `-Dcoex` 的镜像里 blob 调到的是计数桩，不是本组件的胶水。它们的返回值与 IDF 关闭分支的逐项对照只核了 `_coex_pti_get` 一项（§13：它的桩把出参写成 0，收不到帧，已修）；其余钩子的计数桩没有逐项核过。

## 11. modem 的 ICG 码：`esp_wifi_start` 首次返回（2026-11-25）

根因、逐个单变量实验与 IDF 源码出处记在 `docs/adr/ADR-001-wifi-blobs-cooperative-yield.md` 文末。
这里只列与本报告有关的板侧读数和复现方法。

### 11.1 做了什么

- 板级包新增 `boards/esp32s31-coreboard/src/pmu.zig`（`board.pmu.initModemIcg()`）：给三个 HP 电源模式写 modem 的
  ICG 码（active=2 / modem=1 / sleep=0）并触发两次立即更新——IDF 启动期 `pmu_init()` 里的一步，裸机镜像此前没有做。
- `init_probe.zig` 的 `initOnly()` 开头调用它；`_wifi_clock_disable` 按 IDF 补齐（清 `clk_coex_en`、不在 disable 时复位 BB）。

### 11.2 板侧读数

| 镜像 | 读数 | 日志 |
| --- | --- | --- |
| Wi-Fi 探针 | `wifi-init-probe: pmu modem ICG code 0->2 (2 = active)`；`after-init MAC_ST=0x00000000 (init_rc=0)`；`esp_wifi_start rc=0x0 (idle_calls=22)` | `logs/wifi-probe-start-rc0-boot.log` |
| 修复前的同一个探针（全量 dump） | `REGDUMP after-init begin n=523 mac_st=0000e000` | `logs/wifi-probe-regdump-before-boot.log` |
| IDF oracle（全量 dump） | `REGDUMP after-init begin n=523 mac_st=00000000` | `logs/wifi-idf-oracle-regdump-boot.log` |
| 合并镜像（§7.1 的重跑） | `read: LPCON+18 after wifi init=0x00000001`（此前是 `0x00000003`）；`check: wifi esp_wifi_init_internal rc=0 ok=1`；`bt bringup: INITED`；`main: verdict=pass` | `logs/coex-merged-pmu-icg-boot.log` |
| BLE 探针，BLE 侧也加这一调用 | 两次 `rst:0x1a (CPU_LOCKUP_RESET)`，第一次启动没到 `INITED` | `logs/bt-probe-pmu-icg-lockup-boot.log` |
| BLE 探针，对照（不加） | `bt bringup: INITED`、8 条 `bt-blob-strong-assert`，与 §6.5 相同 | `logs/bt-probe-pmu-icg-control-boot.log` |

### 11.3 边界

- 这一步只到 `esp_wifi_start` 返回。扫描、连接、收发已于 2026-11-26 上板（`wifi-ieee80211-verification.md` §10、§11）；
  共存方面只开 Wi-Fi 的读数见 §12；两个控制器同镜、一个射频在收发的读数见 §15，真实效果（L4b）仍然没有证据。
- BLE 侧**没有**接这一步：接了会让 BLE 探针锁死（上表）。合并镜像里 BLE 的 `bringup.init` 是在 ICG 已生效的状态下跑的，
  照样 `INITED`；问题出在探针 `INITED` 之后的实验流程，没有分析，属于 R3.3。
  - 【2026-11-26 更正】"探针锁死"的两份日志来自已经不在树里的旧探针（§14.1）。合并镜像里 BLE 的 enable 在 ICG 已生效时返回 0，
    没有锁死（§14）；HEAD 的独立探针有没有同样的问题没有重跑。
- `pmu_init()` 的其余部分（稳压器电压档、睡眠配置等）没有做。修复后的全量对照（`logs/wifi-probe-fix-regdump-boot.log`）
  与 oracle 还差 90 个寄存器，时钟相关寄存器全部相同。

### 11.4 全量寄存器对照的复现

oracle 打开 `CONFIG_ORACLE_REGDUMP`（`idf.py menuconfig` → `Oracle Wi-Fi credentials`）；探针把 `init_probe.zig` 的
`probe_regdump` 置 `true`。两边各抓 22 秒，按地址配对 `REG <序号> <地址> <值>` 行做差。地址表用
`python3 tools/wifi-idf-oracle/gen_regdump_addrs.py --check` 核对（与 IDF 头文件、与探针侧的表逐项相同）。

## 12. Wi-Fi 已连接状态下的共存核读数（L4a，2026-11-26）

Wi-Fi 的真实链路通了之后（`wifi-ieee80211-verification.md` §11），同一份真实链路探针开着 `-Dcoex` 跑，在六个时点
各取一组读数：`esp_wifi_start` 之后、扫描结束、连上、ping 结束、断开之前、断开之后。读数的出处是
`wifi-blobs/src/init_probe.zig` 的 `coexReadings`，判据写在 ADR-003 第 5 节的 L4a 一行。日志就是那一次运行的
`logs/wifi-link-connect-boot.log`（与 Wi-Fi 验证报告 §11 是同一份）。

探针在 osi 表里给五项再包了一层，只观测、照旧转给胶水的包装函数：`_coex_wifi_request` 逐次打（事件、时延、时长）与
核的返回码；申请、释放、查 PTI 按事件号记次数、核回错的次数、见过的 PTI 值；`_coex_schm_status_bit_set` /
`_clear` 记置过、清过的状态位。读核手里的当前值走 `g.core` 上的函数本身，不给胶水的调用计数添数。

各项都是自启动起的累计：

| 时点 | Wi-Fi 侧 | 胶水拒绝 | `_coex_wifi_request` | `_coex_wifi_release` | `_coex_status_get` | 核的调度间隔 | 核的 Wi-Fi 状态位 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| start 之后 | enabled | 0 | 0 | 2 | 2 | 1000 | 0 |
| 扫描结束 | enabled | 0 | 0 | 4 | 66 | 1000 | 0 |
| 连上 | enabled | 0 | 2 | 19 | 115 | 1024 | 0 |
| ping 结束 | enabled | 0 | 11 | 307 | 529 | 1024 | 0 |
| 断开之前 | enabled | 0 | 12 | 438 | 732 | 1024 | 0 |
| 断开之后 | enabled | 0 | 13 | 444 | 745 | 1000 | 0 |

**blob 向核申请的 13 次全部被拒**（返回 `0x102`，`ESP_ERR_INVALID_ARG`）：

```text
coex> _coex_wifi_request event=7 latency=0 duration=20000 -> rc=258
coex> _coex_wifi_request event=9 latency=0 duration=5000 -> rc=258
```

事件 7 出现在发起连接与断开的时候，各一次；事件 9 共 11 次：连上时一次、十帧回显各一次、之后泵的 5 秒里又一次。
这不是胶水出错：`coex_wifi_request` 就是 `coex_core_request`，它先查 `coex_core_timer_idx_get(event)`，回 255 就直接回
`0x102`。核里的事件表
（`coexist_core.o` 的 `.rodata.CSWTCH.28`，下标是事件号减一）只给 6 个事件配了硬件定时器：

| 事件号 | 1 | 2 | 36 | 38 | 45 | 46 | 其余（3–35、37、39–44） |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 硬件定时器 | 0 | 1 | 4 | 2 | 3 | 3 | 无 |

释放走同一张表，读数对得上：事件 1、2、38、46 的释放共 88 + 83 + 87 + 4 次，返回码全是 0；事件 0、7、9 的释放共
169 + 2 + 11 次，全是 `0x102`。

查 PTI 的 104 次核都答了（没有回错）：

| 事件号 | 0 | 1 | 3 | 5 | 6 | 7 | 9 | 10 | 12 | 15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 次数 | 1 | 52 | 6 | 12 | 2 | 2 | 11 | 7 | 10 | 1 |
| PTI | 0x0a | 0x05 | 0x07 | 0x01 | 0x01 | 0x01 | 0x07 | 0x03 | 0x01 | 0x01 |

blob 置过的 Wi-Fi 状态位（类型 0）是 `0x1`、`0x2`、`0x4`：连上之后最后一次置的是 `0x4`，断开之后最后一次置的是 `0x0`；
清的时候一律写 `0xffff`。核手里的 Wi-Fi 状态位（`coex_status_get(1)`）在六个时点都是 0——这个函数只在别的模块
（BLE）置了状态位时才回非零，BLE 没开。

**定时器。**【2026-11-26 更正】这一节初稿写的是「核的硬件定时器寄存器 `0x2010F008` 在六个时点、每个时点隔 1 ms 读两次，都是
`0x00000314`：没在走」。那读错了对象。`0x2010F008` 是 `MODEM_LPCON_COEX_LP_CLK_CONF`，共存低功耗时钟的**配置**：位 [15:4] 是分频数
（49），低 4 位是时钟源选择（`0x4` = XTAL）。`coex_hw_timer_tick_get` 读它是为了在 tick 与时间之间换算（`coexist_hw.o` 的反汇编），
它不是计数，读多少次都不会变，说明不了定时器走没走。定时器本身在 `0x2010F040 + 16*idx`（配置与比较值）与 `0x2010F408 + 16*idx`
（使能位是 bit1），由 `coex_hw_timer_set` / `coex_hw_timer_enable` 写；入库的那份日志没有读它们。这一轮能说的是：blob 只申请过
事件 7 和 9，核里这两个事件没有配定时器，所以没有定时器被武装，无从观察它走没走。探针的读数已改成读定时器寄存器
（`coexReadings` 末尾的 `readHwTimers`），下次上板才有数。

【2026-11-27 更正，见 §19.4】上一段里定时器的地址与位都写错了。重看 `coexist_hw.o`：`coex_hw_timer_set` 的基址是 `lui 0x2011`、
`addi -192` 得到 `0x02010F40`，加上定时器号再左移 4 位——所以每个定时器 16 个字节，在 `0x2010F400 + 16*idx`（`+0`、`+4` 是它写的
两个配置字，`+8` 是使能字，`+0xC` 是状态字）；`coex_hw_timer_enable` 置的是 `0x2010F408 + 16*idx` 的 **bit0**（`ori …,1`），
`coex_hw_timer_disable` 清同一个位并往 `0x2010F40C + 16*idx` 的 bit0 写 1。此前 `readHwTimers` 读的 `0x2010F040 + 16*idx` 是
`MODEM_LPCON` 的寄存器（上面 §13.2 表里 `0x2010F044` 就是 `DCMEM_VALID_2`），§17–§18 里「使能位恒为 0」的读数看的是 bit1。
读法已改，改后的读数在 §19。

同一轮里链路是通的（连上 3031 ms、DHCP 105 ms 拿到地址、ping 网关 10/10）。入库的是带读数的第三轮：前两轮分页的行被日志的
200 字节上限截断，已修；三轮的链路读数与"每轮 13 次申请全部 `0x102`"一致。

**不开共存的对照。** ADR-003 第 5 节 L4a 一行留的判据「ping 与不开共存时一样」**成立**：胶水按 IDF 关闭分支作答、核不启动的
镜像扫描 38 个 AP、连上、DHCP、ping 10/10。中间走了一段弯路——只去掉 `-Dcoex` 的两轮收不到帧，查下去是计数桩的缺陷，
不是缺了共存核。细目见 §13。

结论与边界：

- 胶水在真实链路上没有拒绝过一次调用（`rej=0`、`last_error=-`）。blob 经 osi 表调到了 23 个 Wi-Fi 包装函数里的 16 个；
  没调的 7 个是 `coex_init_wrapper`、`coex_deinit_wrapper`、`coex_disable_wrapper`、`coex_schm_interval_get_wrapper`、
  `coex_schm_curr_phase_get_wrapper`、`coex_schm_process_restart_wrapper`、`coex_schm_get_phase_by_idx_wrapper`。
- 核对每一次申请都回了 `0x102`，原因在核的静态表里。官方栈用的是同一份 `libcoexist.a` 与同一个 blob，在这条链路上
  得到的应是同一批答复 [INFERENCE：没有在 oracle 上读到这些返回码]。
- 这只是"只开 Wi-Fi"的读数：BLE 没开，核没有可仲裁的另一方，状态位是 0。两个控制器同镜、BLE enabled 但射频没起的读数
  见 §15；两个射频都在收发的真实共存（L4b）仍然没有任何证据，做法与判据写在 ADR-003 第 5 节。

## 13. 不开共存的对照：收不到帧的是计数桩，不是共存核（2026-11-26）

§12 的读数都取自开着 `-Dcoex` 的镜像，ADR-003 第 5 节 L4a 一行留了一条判据「ping 与不开共存时一样」。这一节是补的对照。
结论是判据成立，但中间走了一段弯路：头两轮对照收不到帧，一度被记成"共存核是 Wi-Fi 收发的前提"；查下去，那是计数桩的缺陷。

### 13.1 四种构建

流程与 `wifi-ieee80211-verification.md` §11 的连接轮相同（全信道扫描，然后连接同一个 AP、DHCP、ping 网关），同一份真实链路
探针、同一个源码树，只变共存钩子由谁来答：

| 轮次 | 构建 | blob 的共存钩子 | 共存核 | 扫描 | 连接 | 日志 |
| --- | --- | --- | --- | --- | --- | --- |
| `connect-cc` | `-Dcoex` | 胶水 → 核 | 启动 | 40 个 AP | 3031 ms；DHCP 105 ms；ping 10/10 | 未入库 |
| `connect-ad`、`connect-ae` | 不开 `-Dcoex` | 计数桩（`osi_impl.zig` 的 `shellCoex*`） | 不启动 | `apnum=0` | `reason=201`，3446 / 3447 ms | `logs/wifi-link-nocoex-boot.log`（`ad` 的脱敏副本） |
| `connect-af` | `-Dcoex` + `-Dcoex-sw-off` | 胶水，按 IDF 关闭分支作答 | 不启动 | 38 个 AP | 2566 ms；DHCP 46 ms；ping 10/10 | `logs/wifi-link-coex-off-boot.log` |
| `connect-ag` | 不开 `-Dcoex`，只改 `_coex_pti_get` 的桩 | 计数桩 | 不启动 | 37 个 AP | 2625 ms；DHCP 50 ms；ping 10/10 | `logs/wifi-link-stubs-pti-boot.log` |

"不开 `-Dcoex`"的写法见 §4.6：去掉 `-Dcoex` 与 `-Dcoex-objs`，`libcoexist.a` 的 11 个成员混在 `-Dwifi-blob-objs` 里，
所以 `libcoexist.a` 照样链着，只是没人调 `coex_pre_init`、blob 的钩子指向计数桩。`-Dcoex-sw-off` 是为这一轮加的开关：
胶水照常链着，`coexBoot` 把配置里的 `sw_coexist` 置假，`bind.boot()` 回 `CoexDisabled`（日志
`coex[boot]: FAILED CoexDisabled rc=0x0 rejected=1`，之后各阶段 `booted=false`），每个钩子按 `Glue.off()` 走关闭分支——
那一套桩值在 L1 逐钩子对照过 `esp_adapter.c` 的 `#else`（`host_tests.zig` 的 `expectWifiStubValues`）。

头两轮的日志：

```text
wifi-blob: Send scan done event: status=0, apnum=0
wifi-link-probe: esp_wifi_scan_get_ap_num rc=0x0 n=0
wifi-blob: connect status 1 -> 3
wifi-blob: Send disconnect event, reason=201
wifi-link-probe: DISCONNECTED in 3446 ms: reason=201
```

扫描照样逐信道走完，只是一条帧都收不到。这就是 `wifi-ieee80211-verification.md` §10 之前那道"扫描走完、0 个 AP"的墙，
所以当时很容易把它读成"又缺了一个 IDF 替我们做的前置"。

### 13.2 寄存器跟着谁走

每轮在同样的时点都留了寄存器转储（`REGDUMP` 523 个有文档的寄存器、`MACDUMP` MAC 块 1024 个字）。把"核启动"与"钩子是谁"
分开之后，原先以为跟着共存核走的那一组地址分成了两簇：

| 地址（时点） | 身份 | 核启动（`cc`） | 计数桩，PTI 写 0（`ad`） | 胶水关闭分支（`af`） | 计数桩，PTI 不写（`ag`） |
| --- | --- | --- | --- | --- | --- |
| `0x2010F008`（start 之后） | `MODEM_LPCON_COEX_LP_CLK_CONF` | `0x314` | `0` | `0` | `0` |
| `0x2010F03C`（start 之后） | `MODEM_LPCON_DCMEM_VALID_0` | `0x00800001` | `0x1` | `0x00800001` | `0x00800001` |
| `0x2010F044`（start 之后） | `MODEM_LPCON_DCMEM_VALID_2` | `0x80` | `0` | `0x80` | `0x80` |
| `0x2010F050`（start 之后） | `MODEM_LPCON_MODEM_INTR_STATUS` | `0x2` | `0` | `0x2` | `0x2` |
| `0x2058909C`（start 之后） | `HP_SYS_CLKRST + 0x9C` | `0x02000000` | `0` | `0x02000000` | `0x02000000` |
| `0x20104DD4` / `0x20104DD8`（扫描后） | MAC 的 PTI 表字 | `0x55777555` / `0x00003377` | `0` / `0` | `0xff00083f` / `0x0000500d` | `0xf4000080` / `0x00005007` |
| `0x2010408C`–`0x20104094`、`0x20104300`（扫描后） | MAC 的 RX 缓冲字与掩码 | 非零 | 全 0 | 非零 | 非零 |

- 只有 `COEX_LP_CLK_CONF` 跟着核走：核启动之后是 `0x314`（分频数 49，时钟源 XTAL），不启动就是 0。`af`、`ag` 两轮它都是 0
  而链路正常，所以它不是收发的前提。
- 其余几个跟着钩子的答复走：PTI 写 0 的两轮是 0，另外三种构建非零。MAC 的 PTI 表字最直接：blob 拿到 PTI 0 就把它编进表里，
  表全 0 的两轮 RX 缓冲字也全 0。关掉共存时 blob 用的是它自己的默认 PTI（`af`、`ag` 的表字与官方开着共存时的不同，但非零）。
- `ad` 对 `cc` 的逐地址差分：start 之后有文档的 523 个里差 7 个，扫描中共同 1602 个地址差 110 个，扫描后 6727 个里差 146 个
  （`REG` 8、`MACW` 68、`RG` 70）。全量差分文件落在 `/tmp`，没有入库；上面的表是入库日志里逐个地址读出来的。

### 13.3 根因、修复与边界

- **根因：`_coex_pti_get` 的计数桩把出参写成 0。** `osi_impl.zig` 的 `shellCoexPtiGet` 原先是 `if (pti) |q| q.* = 0; return 0;`。
  IDF 的关闭分支（`esp_adapter.c` 里 `#if CONFIG_SW_COEXIST_ENABLE || CONFIG_EXTERNAL_COEX_ENABLE` 的 `#else`）是返回 0、
  **不写出参**。单变量验证就是 `connect-ag`：计数桩的镜像只把那一行写去掉，链路恢复。
- **修复**：`shellCoexPtiGet` 不再写出参，与 IDF 的关闭分支一致。
- **共存核不是 Wi-Fi 收发的前提。** `af`、`ag` 两轮核都没有启动（参数指针是 0、`COEX_LP_CLK_CONF` 是 0），链路照常。
  当初排查扫描时加上 `-Dcoex` 之后 RX 那组寄存器"对上了"，应是因为真核心回了真的 PTI，不是因为它启动了什么硬件前提
  [INFERENCE：当时没有把 PTI 单独拿出来测，这一条是由 `ag` 反推的]。
- **`wifi-ieee80211-verification.md` §10 的"原因有两处"不用改**：APM 访问控制过滤器、supplicant 回调表。那一节的读数都开着
  `-Dcoex`，事后看那只是当时探针的样子。
- **ADR-003 第 5 节 L4a 一行的判据成立**：不开共存时真实链路照常。`-Dcoex` 对 Wi-Fi 仍然是可选项，"默认关"不变。
- 没有做的：其余钩子的计数桩与 IDF 关闭分支的逐项对照。已知的两处出入没有核到底——`coex_schm_flexible_period_get`
  关闭分支回 1，计数桩回多少没有看；`shellCoexEnable` 会去调 `libcoexist.a` 的 `coex_enable()`，IDF 的关闭分支不调。
  链路在 `ag` 里正常，说明它们不影响这条路径，但"等价"没有证。
- 官方 Wi-Fi 镜像是开着共存的：仓里的 oracle 转储（纯 Wi-Fi 镜像）在 init 之后 `2010F008` 就是 `0x00000314`
  （`logs/wifi-idf-oracle-regdump-boot.log` 第 105 行）；仓库外的参照构建 `s31-wifi-oracle` 的 sdkconfig 里
  `CONFIG_SW_COEXIST_ENABLE=y`，映射文件里链了 `libcoexist.a` 和 `__esp_sys_init_fn_init_coexist`。要和官方栈逐项对齐
  （比如 PTI 表字）就开 `-Dcoex`；不开时链路正常，PTI 表是 blob 自己的默认值。

## 14. 合并镜像里的 BLE enable（2026-11-26）

§10 初稿写的是"合并镜像里 BLE enable 没有跑"。这一轮用 `-Dcoex-ble-enable` 把它跑了（§6.6 的命令末尾加这个开关），回答的问题是：
APM 过滤器已关、ICG 码已写、共存核已启动的镜像里，生产路径的 BLE enable 走到哪。

### 14.1 做法

- `firmware/src/coex_merged.zig` 在两个 init 之后多一步：读一次寄存器，调 `bringup.enable()`，把 controller 任务泵 1 秒
  （`probe.zig` 的 `enableOnly` / `pumpFor`：让出点、ISR 桥、`ets_timer`、OSAL 周期回调、两级看门狗、时钟门控回写，
  与探针主循环里让任务推进的那几项相同），再读一次。
- 不发 HCI 命令，也不做探针的实验：`run()` 里探针的那一套要么依赖探针镜像的内存布局，要么就是通向 synth 墙的实验本身。
- `bringup.enable()` 里 anchor[8] 原先按探针镜像的布局写死在 `0x2f01_8720`；合并镜像里那个符号在 `0x2f024098`，
  写死的地址读到的是不相干的内存。改成按符号取（`probe_ptr.bohffAnchor()`）。其余写死的地址都落在 `layout_probes = false`
  时被拦截的那一段，合并镜像里是空操作。
- 这一份镜像里 Wi-Fi 侧的 `initOnly` 先做了关 APM 过滤器与设 modem 的 ICG 码，所以 BLE 的 init 与 enable 都是在这两样
  已生效的状态下跑的。日志里自己的读数：`wifi-init-probe: apm ctrl filters LP/HP/HP_MEM: 0/0/0 -> 0/0/0 (0 = off)`（进
  `initOnly` 之前就已经是 0——合并镜像照常先跑各段自检，是哪一段先关的这份日志里没有行可引）、
  `wifi-init-probe: pmu modem ICG code 0->2 (2 = active)`、`coex[boot]: booted=true … rej=0`。§11.2 记的"BLE 探针加了这一
  调用之后两次 `rst:0x1a`"来自已经不在树里的旧探针，这一轮没有复现。

### 14.2 板侧读数（`logs/coex-merged-ble-enable-boot.log`）

```text
wifi-init-probe: apm ctrl filters LP/HP/HP_MEM: 0/0/0 -> 0/0/0 (0 = off)
wifi-init-probe: pmu modem ICG code 0->2 (2 = active)
bt init-only: bringup.init rc=0 arena free=30728 B
read[ble before enable]: synth 98bc=00000000 98c0=00000000 98b8=00000000 9880..988c=00000000 7fff8404 00000000 00000000
read[ble before enable]: fe 0438=ff410000 0450=00110000 047c=00000000 lpcon+18=0000000f clkrst 7040=00000001 71f8=00000001
read[ble before enable]: ana f800=002f0669 f818=2900e444 f81c=00ffffef
bt enable-only: status=2 rounds=41544 evq=0/0/0 pend_ok=2 busy=0
read[ble after enable]: synth 98bc=00000000 98c0=00000000 98b8=00000000 9880..988c=00000000 7fff8404 00000000 00000000
read[ble after enable]: fe 0438=ff410000 0450=00102000 047c=00000000 lpcon+18=0000000f clkrst 7040=00000001 71f8=00000001
read[ble after enable]: ana f800=002f0669 f818=2900e444 f81c=00ffffef
coex[ble-enable]: booted=true wifi=inited ble=enabled param=0x2f01b374 coa=0x2f01f064 table=0x2f01f064 rej=0
coex[ble-enable]: hooks: boot=1 wifi_init=1 schm_register_cb=1 register_start_cb=1 configure_preemption_end_cb=1 btdm_coex_init=1 btdm_coex_enable=1
coex[ble-enable]: coex lp clk conf 0x2010F008: 0x00000314 (div_num 49, src_sel 0x4)
coex[ble-enable]: hw timer 4: 0x00000001 0x000018f4 0x00000314 0x00000001 en 0x00000000 st 0x00000000
check: ble bringup.enable rc=0 ok=1
checks: passed=7 failed=0 total=7
```

| 项 | 读数 |
| --- | --- |
| `bringup.enable` | `rc=0`，状态 `ENABLED`；日志里只有上电复位（`rst:0x1`），没有锁死、没有 panic |
| controller 任务 | 泵 1 秒共 41 544 轮；OSAL 事件队列的入 / 出 / 空都是 0，互斥锁拿到 2 次 |
| 共存核 | BLE 侧 `enabled`，胶水零拒绝；blob 经 BLE 适配层调了 `btdm_coex_init`、`btdm_coex_enable` 与三个登记钩子；核手里没有请求、没有释放 |
| 合成器锁定位 | `0x201098BC` 的 bit2 在 enable 前后都是 0 |
| synth 区与 ANA | `0x20109880` 起四个字、`0x2010F800` / `F818` / `F81C` 在 enable 前后逐字相同 |
| 核的硬件定时器 | 5 个的使能位都是 0，隔 1 ms 两次读数相同（§12 更正里说的那组寄存器，这是第一次读到） |
| 整体 | `coex_merged` 7/7，`firmware: sections: passed=8 failed=0`，`main: verdict=pass` |

enable 前后只有一处不同：`0x2010_0450` 从 `0x00110000` 变成 `0x00102000`，那是 `bringup.enable()` 自己写的。

### 14.3 结论与边界

- **生产路径的 BLE enable 在合并镜像里走通了**：五步归档调用都返回 0，共存核的 BLE 侧进了 `enabled`，没有锁死。
  §11.3 里"接了会让 BLE 探针锁死"只对那份旧探针成立。
- **这一轮对 synth 那道墙（R3.3）没有结论。**【2026-11-26 更正】初稿写的是"enable 之后 `98BC` 仍是 0，所以 APM 过滤器、ICG 码、
  共存核启动都不是 R3.3 的解"，并把 `bringup.zig` 注释里的"enable rc=0 → 98BC=4"当依据。那个推论不成立：合成器上电是
  广播使能命令处理的**结果**，不是前置条件。`components/bt-blobs/README.md` 的"oracle90b 参照时序"是逐时点的：enable
  完成时官方固件的 `98BC` 就是 `0x00000000`，发完 `0x2006` / `0x2008` / `0x200A` 才变成 `0x00000004`（三条命令的响应
  都是 Hardware Error 事件）。这一轮没有发 HCI 命令，读到 0 与官方同一时点的读数相同。要知道这三样够不够，得在合并
  镜像里把广播序列发下去——那正是独立探针卡住的地方。
- 这一轮不发 HCI 命令，所以它只回答"enable 走到哪"。泵的 1 秒里 controller 没有可做的事（事件队列为空），
  synth 区与 ANA 寄存器不动只说明它没动。
- `bringup.enable()` 不是纯生产路径：它开头无条件写 `0x2010_0450 = 0x00102000`（探针期为对齐官方值加的，改的是 FE 寄存器），
  日志里 `0450` 的变化就是它。这一轮 Wi-Fi 没有 start，没有后果；把这条路径并进合并镜像做 L4b 之前，要把它拿掉或挂到开关后面。
- 一条没有验证的线索：这一轮 ANA 的 `0x2010F818` 是 `0x2900e444`，而 `probe_ptr.zig` 的注释写着 ana I2C burst
  （`phy_ana_i2c_master_burst_rf_onoff(1)` 加 `phy_ana_i2c_master_burst_bbpll_config()`）做完之后 CONF0 应是 `0x2900e448`。
  差在哪一位、是不是合成器没就绪的原因，没有查。
- 【2026-11-26 更新】合并镜像里 `esp_wifi_start` 已经跑了，两个控制器同镜、Wi-Fi 走通真实链路的读数见 §15
  （"一个射频在收发、另一个 enabled"；BLE 的射频没有起，L4b 仍然没有证据）。过程中撞上的那道墙——BLE 的 init 会让
  Wi-Fi 收不到帧——根因就在这一轮 enable 之后才看得见：PHY 的一次性初始化只认第一次使能，见 §15.3。

## 15. 合并镜像里的 Wi-Fi 真实链路：PHY 归先使能它的那一方（2026-11-26）

§14 末尾留下的那一项——"两个控制器同时工作没有任何证据"——这一节补上第一块：同一个镜像里 BLE `inited`、`enabled`，
Wi-Fi 连上真实 AP、DHCP、ping 网关 10/10。BLE 的射频没有起（R3.3），所以这是"一个射频在收发、另一个 enabled"，
不是 L4b。通到这一步之前先撞上了一道新的墙：Wi-Fi 先 start 之后，BLE 的 init 会让 Wi-Fi 的接收退化到收不到帧。

### 15.1 做法

- `firmware/build.zig` 新增 `-Dcoex-wifi-link`（要求 `-Dcoex-merged`）。`coex_merged` section 的顺序：切堆 → Wi-Fi
  `initOnly` → **Wi-Fi 先 `esp_wifi_start`**（`link_probe.zig` 的 `linkStart()`）→ 存一份寄存器快照、扫一次全信道作
  基线 → BLE `initOnly`（→ 可选的 enable）→ BLE 的 init 改过的时钟 / 电源寄存器按快照写回 → Wi-Fi 走扫描、连接、
  DHCP、ping、断开（`linkRest()`）。这两个入口是从真实链路探针的 `run()` 里抽出来的主干，不带探针的诊断；
  探针的 `run()` 没动。顺序为什么不能反，见 15.3。
- **2026-11-27 更新**：快照与写回已经删除。查清被覆盖的是 BLE 移植层整字写 `CLK_CONF1` 的那一句之后，两边改成只置
  自己的时钟单元位，不再需要事后写回，见 16。
- 泵的每一步 Wi-Fi 之后调一次 `bt.probe.pumpStep()`：BLE 的 controller 任务走一轮，期间关掉 Wi-Fi 侧的让出点。
- 只编这一段：`-Dboot=false -Dnet=false -Dwire=false -Dwifi=false -Dtls=false -Dapps=false`，不带符号表。
  镜像 1 226 480 B（带全部自检段和符号表的合并镜像是 1 262 208 B）。堆 210 240 B：Wi-Fi 114 688 B、BLE 95 552 B；
  Wi-Fi start 之后它的 arena 还剩 64 424 B。
- `-Dcoex-dump`：链路之前打一份转储（`REGDUMP` / `FOCUSDUMP` / `MACDUMP`，标签 `after-ble-init`），只读。
- AP 的凭据经 `-Dwifi-ap-ssid` / `-Dwifi-ap-password` 给，不入库。

构建与上板（在 §6.6 的命令末尾加 `-Dcoex-wifi-link=true`、可选的 `-Dcoex-ble-enable=true`，其余 section 关掉）：

```bash
env -u LD_LIBRARY_PATH /tmp/bin/zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
  -Dcoex-merged=true -Dcoex=true -Dcoex-objs="$(ls /tmp/coex-objs/*.o | paste -sd,)" \
  -Dcoex-wifi-link=true -Dcoex-ble-enable=true \
  -Dboot=false -Dnet=false -Dwire=false -Dwifi=false -Dtls=false -Dapps=false \
  -Dwifi-blob-dir=/tmp/merged-wifi-objs -Dwifi-blob-objs="$(ls /tmp/merged-wifi-objs | paste -sd,)" \
  -Dbt-blob-dir=/tmp/merged-bt-objs -Dbt-blob-objs="$(cat /tmp/merged-bt-objs/objs.csv | paste -sd,)" \
  -Dphy-src-objs="$PHY3,$REG" -Dwifi-ap-ssid=… -Dwifi-ap-password=…
```

### 15.2 实验阶梯

排查阶段的十四轮。每一轮只跑一次；原始日志只留了轮 1（`logs/coex-merged-wifi-link-deaf-boot.log`），其余各轮的数字是当时的
读数。这一节不靠它下结论，结论性的证据是下面的五个单变量对照。

| 轮 | 条件 | BLE init 之前 | 之后 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | BLE 先 init 并 enable，Wi-Fi 后 start | — | Wi-Fi 钩子打出的标定数据非零 6/1904 字节；扫描 3 个 AP，连接 `reason=201` | 两个控制器在一个镜像里没有崩、没有锁死，链路不通（`logs/coex-merged-wifi-link-deaf-boot.log`） |
| 2 | 同上，BLE 只 init、泵里不轮转 | — | 3 个 AP，`reason=204` | 排除"泵里的 BLE 轮转"。堆配额不是原因的依据是另一条：同一个配额下 BLE init 之前扫描正常（轮 11） |
| 3 | 轮 2 + IDF 真的 modem clock 对象 | — | 3 个 AP | 仍然聋；这一轮是 BLE 先 init 的顺序，标定已经被 BLE 用掉，两个因素混在一起，不能单独归因 |
| 4 | Wi-Fi 先 start，再 BLE init | — | 1 个 AP | PHY 的一次性初始化归了 Wi-Fi（标定数据 262 个非零字节），之后仍然聋 |
| 5 | 轮 4 + 时基校准 | — | 1 个 AP | Wi-Fi init 后、start 后、BLE init 后都是 80 MHz CPU 对 1 MHz 定时器，排除时基 |
| 6 | 轮 4 + 寄存器对拍 | — | 1 个 AP | 当时在聋的镜像上的读数没有入库；修好之后同一时点的对拍见 15.3 |
| 7 | 轮 4 + `CLK_CONF1` 或回 Wi-Fi 的时钟位 | — | 2 个 AP | 时钟位单独不是原因 |
| 8 | 轮 4 + 跳过 BLE 自己的 PHY 打开序列 | — | 2 个 AP | 只跳过 `initPhy` 不够（对照 E 复现了这一点） |
| 9 | 轮 4 + 把快照里变化过的寄存器全部写回 | — | 1 个 AP | 42 个写回去，不够；`DCMEM_VALID_*`、`ANA_CONF0` 等几位写不上 |
| 10 | 轮 4 + Wi-Fi 停掉再 start | — | 0 个 AP | 驱动重写 MAC 不够 |
| 11 | 轮 4 + BLE init 之前先扫一次 | **34 个 AP** | — | 合并镜像里 Wi-Fi 自己是好的：是 BLE 的 init |
| 12 | 轮 4 + 快照全写回 + Wi-Fi 停掉再 start | 37 个 AP | 连上、DHCP、ping 8/10（平均 79 ms） | 事后补救能通，质量差 |
| 13 | 两段都跳过（`initPhy`、第 15 步的重新标定）+ 时钟位写回；BLE 只 init | — | 37 个 AP，连上，ping 10/10（平均 3.2 ms） | 恢复 |
| 14 | 同 13 + BLE enable，泵里轮转 | 38 个 AP | 40 个 AP，连上，DHCP 51 ms，ping 10/10，`verdict=pass` | 目标配置 |

**最终形态上的五个单变量对照。** 修完之后在最终形态的代码上，把三样东西逐个关掉再上板——跳过 `initPhy`、跳过第 15 步的
重新标定、时钟 / 电源寄存器写回——每次只改一处，跑完即恢复。都是 `-Dcoex-wifi-link -Dcoex-ble-enable`；除 A 的两次之外都带
`-Dcoex-dump`，转储在 BLE enable 之后、写回之前。日志都入库了（前缀 `logs/coex-merged-wifi-link-`）。B、C、D 跑在加新判据
之前（15 项），E 跑在之后（16 项，见 15.4）。

| 对照 | 跳过 `initPhy` | 跳过第 15 步 | 写回 | BLE init 之前 | 之后 | 判据 | 日志后缀 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A 最终形态 | 是 | 是 | 是 | 34 / 33 个 AP | 35 / 35 个 AP；连上 2059 / 2052 ms，DHCP 51 / 51 ms，ping 10/10 | 16/16、15/15 | `boot.log`、`dump-boot.log` |
| B | 否 | 否 | 是 | 39 个 AP | 4 个 AP；连上 1951 ms，DHCP 3887 ms，ping 9/10 | 15/15，`verdict=pass` | `noguard-boot.log` |
| C | 是 | 是 | 否 | 36 个 AP | 35 个 AP；认证、关联成功，随即 `reason=7` 断开 | 11/15，`verdict=fail` | `norestore-boot.log` |
| D | 否 | 是 | 是 | 31 个 AP | 1 个 AP；连上 1956 ms，DHCP 24 ms，ping 9/10（平均 70 ms，最大 304 ms） | 15/15，`verdict=pass` | `onlyloadcal-boot.log` |
| E | 是 | 否 | 是 | 36 个 AP | 2 个 AP；连接 `reason=2` | 11/16，`verdict=fail` | `onlyinitphy-boot.log` |

读法：

- **两段各自都足以让 Wi-Fi 的接收退化。** 只跳过第 15 步（D，`initPhy` 照常跑）：31 → 1 个 AP。只跳过 `initPhy`（E，第 15 步
  照常跑）：36 → 2 个 AP。两段都跳过（A）：33–34 → 35 个 AP。
- **写回是连接阶段必要的。** 两段都跳过但不写回（C）：扫描照常（35 个 AP），认证、关联都成功，随即被 AP 以 `reason=7`
  断开，没有走到四次握手。写回的 13 个里哪几个是必要的，没有再分。
- **原来的判据抓不住这种退化。** B 和 D 里接收已经退到 1–4 个 AP，连接、DHCP、ping、稳定 5 秒照样全过，`verdict=pass`
  （B 的两次里一次连上、一次关联没完成，见 15.8）。所以加了一条：BLE init 之后的扫描 AP 数不得低于基线的一半（15.4）。
  它在 E 上失败（`2 vs 36`），在最终形态上通过（15.5），在晚上两次退化镜像上也如实失败（15.8）。
- **"接收通路的字读回 0"复现不出来。** 排查阶段记过"聋的那几轮里 MAC 块接收通路的那组字读回 0"。B、D、E 三份转储里
  这组字都不是 0（PTI 表字与单独探针相同，`0x20104300 = ffffffff`）；排查阶段那几轮的原始日志没有入库，那个说法作废。

### 15.3 根因

IDF 的 `esp_phy_enable` 只在 modem 标志为 0 时才初始化 PHY（`phy_init.c:324-342`）：第一个使能的模块开时钟、做一次性的
标定；第二个模块使能时只把自己或进标志，不重做。本仓的 BLE 适配层是按"单独跑"写的，`bringup.init` 里有两段会重做 PHY 的
打开与标定，哪一段在 Wi-Fi 之后做，都会把 Wi-Fi 建立好的 PHY 配置冲掉（对照 D、E）：

1. `probe_ptr.initPhy()`——自己那套"从零打开"的序列：ICG、`phy_wifi_enable_set`、`set_bb_wdg`、`CLK_CONF1` 与 FE 位，再走
   一次自己的标定（日志 `bt phy: enable modem=2 icg+phy_wifi_enable_set+bb_wdg+conf1 done`、`bt phy: calib rc=0`）。
2. 第 15 步的 `mce(13)` + IDF 的 `esp_phy_load_cal_and_init()`。它看 IDF 自己的静态变量 `s_is_phy_calibrated`；Wi-Fi 这边走的
   是探针的钩子（`init_probe.zig` 的 `phyEnableHook`），不去置这个变量，所以它在镜像里恒为 0，一调就是一次**全量重新
   标定**。`osi_impl.zig` 里记过 PHY 停在"刚标定完"的状态时的症状：扫描只出 TX 完成中断，一帧都收不到。

两段各自伤在哪一步（`initPhy` 之后的哪一步、标定之后的哪一处状态）没有再往下拆。能定的只有：两段各做一次就各退化一次，
两段都跳过就恢复。

另一种顺序（BLE 先 init）是另一种坏法，有入库日志（轮 1）：PHY 的一次性初始化被 BLE 用掉，库的实现只认第一次，Wi-Fi
start 时它什么都不做——Wi-Fi 钩子打出的标定数据 `version=0`、非零 6/1904 字节，只有探针预写的 MAC（单独探针里是
`version=100`、259–262 个非零字节）；扫描 3 个 AP。返回码是 0。

顺带澄清一个数字：全信道扫描 2.4 秒是正常的——blob 扫信道 1–11（主动，各 120 ms）和 12–14（被动，各 360 ms）。
单独探针日志里的"约 9 秒"含停下来打转储的时间。

**BLE 的 init 还改了哪些寄存器。** `btdm_lp_enable_clock` 把 `MODEM_SYSCON_CLK_CONF1` 整字写成自己的值：两段都跳过时是
`0x003FF880`（单独探针同一时点是 `0x0038E7FF`），Wi-Fi 基带的时钟位被关掉 10 个——`wifibb_22m` / `40m` / `44m` / `80m` /
`40x` / `80x` / `40x1` / `160x1`、`wifimac`、`wifi_apb`——只剩 `wifibb_80x1`；`initPhy` 照常跑的 B、D 里这个字是
`0x003FFA8C`，第 15 步照常跑的 E 里是 `0x003FF884`。

与单独的真实链路探针对拍（修好之后的镜像 A，带转储的那一次；`logs/wifi-link-connect-boot.log` 的 `REGDUMP after-scan` 对
`logs/coex-merged-wifi-link-dump-boot.log` 的 `REGDUMP after-ble-init`，都是扫描结束时、连接之前）：523 个有文档的寄存器里
19 个不同，其中 2 个是活值（`0x207001A4` 是 PMU 的计数，`0x2010F804` 是模拟 I2C 主控的状态字，都在 `radioSkip` 的清单里），
真正的变化是 17 个。按块：`MODEM_LPCON` 8 个（含 `DCMEM_VALID_*` 那几个字）、`MODEM_SYSCON` 4 个、`I2C_ANA_MST` 2 个、
`MODEM_WIDGETS` 1 个（`0x20109400`）、SoC PLL 的配置字 `0x205871E0`（`0x25 → 0x3D`）与 `0x20589090` 各 1 个。B、D、E 的
同一对拍是 23–24 个不同（`initPhy` 或第 15 步多改了几个字）。

这些是伴随现象：不写回时（C）扫描照常、连接失败，写回之后连接正常。写回里有 1–3 个字写不上（`0x2010F03C` / `0x2010F044`
的 `DCMEM_VALID_*`、`0x20589090`，日志行 `radio restore: … wanted …, reads …`），链路照常。MAC 块在修好之后、写回之前，
接收通路的那组字与单独探针的同一时点一致：PTI 表字 `55777555` / `00003377`、`0x20104300 = ffffffff`、
`0x20104548 = 00c00000`；整块 1024 个字里 59 个不同，没有逐个归类。

### 15.4 修复

- `components/bt-blobs/src/probe_ptr.zig`：`pub var phy_owned_by_wifi`，为真时 `initPhy()` 整段跳过。
- `components/bt-blobs/src/bringup.zig`：同一个变量为真时，第 15 步的 `mce(13)` + `esp_phy_load_cal_and_init()` 跳过。
- `components/bt-blobs/src/probe.zig`：`setPhyOwnedByWifi()`；合并镜像里 Wi-Fi start 返回 0 之后、BLE 的 init 之前调。
- `components/wifi-blobs/src/init_probe.zig`：`radioSnapshot()` / `radioRestore(mask)`——存有文档的 523 个与定点的 55 个
  寄存器，把变化过的按区域写回。合并镜像只写回时钟 / 电源那一组（实测 13–15 个，其中 1–3 个写不上，见 15.3）。
- `firmware/src/coex_merged.zig`：新判据——BLE init 之后的扫描 AP 数不得低于基线的一半。
- 单独的 BLE 探针不受影响：变量默认是假，两条分支照旧。

### 15.5 板侧读数（`logs/coex-merged-wifi-link-boot.log`）

最终形态的镜像（`-Dcoex-wifi-link -Dcoex-ble-enable`，只编 `coex_merged` 一段，带新判据）：

```text
wifi-link: scan[before ble init]: GOT in 2421 ms, esp_wifi_scan_get_ap_num rc=0x0 n=34
bt phy: initPhy skipped (PHY already on, Wi-Fi owns it)
check: ble bringup.init rc=0 ok=1
check: ble bringup.enable rc=0 ok=1
wifi-init-probe: radio restore (mask 0x1): clock/power=13 ana_i2c=0 bb_fe=0 lp_pmu=0
wifi-link: wait scan-done 10s -> GOT in 2437 ms
wifi-link: esp_wifi_scan_get_ap_num rc=0x0 n=35
wpa: eapol rx msg 1 (99 B) -> tx msg 2 (127 B) rc=0
wpa: eapol rx msg 3 (155 B) -> tx msg 4 (99 B) rc=0
wifi-link-probe: STA_CONNECTED bssid=… ch=1 authmode=3 aid=1
wifi-link-probe: CONNECTED in 2059 ms (1 progress reports)
wifi-link-probe: data path: DHCP bound in 51 ms ip=… router=…
wifi-link-probe: net: ping done: sent=10 received=10 timed_out=0 rtt min/avg/max=1772/3830/8882 us
wifi-link-probe: stayed connected for 5 s
wifi-link-probe: esp_wifi_disconnect_internal -> DISCONNECTED reason=8
check: wifi scan after ble keeps >= half the baseline ap (35 vs 34) ok=1
checks: passed=16 failed=0 total=16
main: verdict=pass
```

| 项 | 读数 |
| --- | --- |
| 镜像 | 1 226 480 B；`rst:0x1` 上电复位一次，没有别的复位、没有 panic |
| BLE | `bringup.init rc=0`（`INITED`），`bringup.enable rc=0`（`ENABLED`），共存核 BLE 侧 `enabled` |
| Wi-Fi 基线（BLE init 之前） | 34 个 AP |
| Wi-Fi 链路（BLE enabled 之后） | 35 个 AP；连上 2059 ms；钥匙落进 MAC 密钥表（位图 `ffff`）；DHCP 51 ms；答了网关的 ARP；ping 10/10，rtt 最小 / 平均 / 最大 1.8 / 3.8 / 8.9 ms；连着 5 秒没有掉；本地断开 `reason=8` |
| 新判据 | BLE init 之后 35 个 AP，不低于基线（34 个）的一半 |
| 调度 | Wi-Fi 的让出点被 BLE 任务栈上的调用碰到 0 次（整轮） |
| Wi-Fi arena（三个采样点） | start 之后剩 64 424 / 114 672 B；扫描后 58 932 B；连接阶段结束 61 136 B |

同一形态带 `-Dcoex-dump` 的那一次（`logs/coex-merged-wifi-link-dump-boot.log`，镜像 1 228 464 B，跑在新判据之前，15/15）：
BLE init 之前 33 个 AP，之后 35 个 AP，连上 2052 ms，DHCP 51 ms，ping 10/10（rtt 1.9 / 3.8 / 8.9 ms）。它的用途是 15.3 的
寄存器对拍（转储在 BLE enable 之后、写回之前）。

### 15.6 共存核读数（BLE enabled）

与 §12（BLE 没开）比，这一轮 Wi-Fi blob 对核的用法多出三样——正是 §12 里"没调到的 7 个钩子"里的三个：

| 钩子 | §12（BLE 没开） | 本轮（BLE enabled） |
| --- | --- | --- |
| `coex_schm_interval_get` | 0 | 2 |
| `coex_schm_curr_phase_get` | 0 | 1 |
| `coex_schm_process_restart` | 0 | 1 |
| `coex_schm_curr_period_get` | 2 | 5 |
| `coex_schm_flexible_period_set` / `_get` | 2 / 2 | 3 / 4 |

其余与 §12 一致：胶水零拒绝；blob 的申请里事件 7、9 共 15 次，核都回 `0x102`（全部申请是 16 次，另 1 次是事件 1，回的不是
`0x102`）；核手里 `wifi_status=0`、`interval=1000`、`period=1`；置 / 清 Wi-Fi 状态位各 67 次，三个状态位都置过（掩码 `0x7`，
与 §12 的 after-ping 相同），最后一次置的是 `0`（§12 的 after-ping 是 `0x4`）。多调到的那三个钩子在五份对照日志里次数都
一样；申请与释放的次数跟着链路的流量走（连不上的 C、E 少得多）。

核的硬件定时器：读数时 5 个的使能字和状态字都是 0；定时器 0 的头两个字非零（这次是 `0x600383DE` / `0x000000C3`，之前一次
是 `0xC0028164` / `0x000000DF`，像是计数值）。BLE 先 init 的那一轮（15.2 的轮 1，`logs/coex-merged-wifi-link-deaf-boot.log`）
同一时点 5 个的使能字和状态字读回 1。这些字是哪一步写的、差别来自顺序还是来自 PHY 的修复，没有分开验证。

### 15.7 边界

- BLE 的射频没有起（R3.3），所以这是"一个射频在收发、另一个 enabled"。两个射频真的抢天线会怎样（L4b），仍然没有
  证据。
- 写回是整字写，而且在 BLE 的 enable 之后执行：`CLK_CONF1` 回到 Wi-Fi 的快照值，BLE 那一侧的时钟位也一并被拿掉。这一轮
  BLE 的 controller 是在这种状态下被泵的，没有任何一项检查在看它。正解是时钟配置按两个射频的需求取并集（ADR-003 第 4 节），
  没有做。
- 两段各自伤在哪一步没有再拆（`initPhy` 之后的哪一步、标定之后的哪一处状态）；写回的 13–15 个寄存器里哪几个是必要的，
  也没有再分。
- 排查阶段（15.2 的十四轮）的原始日志只留了轮 1，那些数字是当时的读数。带结论的五份对照都有入库日志，每个对照跑了一次；
  B 和 D 在晚上又各跑了一次，带 AP 侧采集，见 15.8。
- 合并镜像里真实链路的顺序只有 Wi-Fi 先 start 这一种；BLE 先 init 那种顺序（轮 1）不走。
- `bringup.enable()` 开头无条件写 `0x2010_0450 = 0x00102000`（§14.3）。这一轮它是在 Wi-Fi 已经 start 之后执行的，
  链路照常通过；它对 Wi-Fi 有没有影响没有单独量。
- 一台 AP（WPA2-PSK + CCMP-128，信道 1）。AP 自己记的事件、站点统计、有线侧的帧见 15.8；空口上的帧（2026-11-27 凌晨，
  临时 monitor 接口）见 15.9。
- 合并镜像里 `esp_wifi_start` 之后到 BLE init 之间、BLE 的 init 期间，Wi-Fi 的任务没有被泵（只开了中断），
  事件队列里积压的帧被丢掉；链路是从扫描重新开始的。
- `esp_wifi_start` 没返回 0 的那条分支（不置旗子、不做基线与链路）没有上过板；它只会在 `wifi first` 那一项判据上报失败。

### 15.8 AP 侧的证据（2026-11-26 晚）

用户用网线把工作站接进了 AP 的 LAN，并给了路由器的登录。AP 是一台刷了 OpenWrt 25.12.6 的小米 AX3000T（2.4 GHz 信道 1，
接口 `phy0-ap0`，网关 192.168.31.1）。路由器没有外网，装不了 tcpdump（工作站也够不到 downloads.openwrt.org），所以这一节
拿到的是三样别的东西，都不是空口上的帧（空口上的帧是后来在工作站上交叉编译 tcpdump 抓的，见 15.9）；都只读，没有改路由器：

- **AP 的系统日志。** hostapd 在默认级别就记关联过程的每一步，dnsmasq 记 DHCP 四步。路由器的日志是个约 1300 行的环形
  缓冲，22:52 取了一份与板子有关的行入库：`logs/coex-merged-wifi-link-ap-syslog.log`（528 行，时间换算成本机时间，带轮次
  注释）。
- **站点统计。** 板子连上期间每秒一份 `iw dev phy0-ap0 station dump` 与 hostapd 的 `get_clients`。
- **AP 有线侧的帧。** 工作站在网线上抓与板子有关的 ARP / ICMP 帧的摘要（不含载荷）。

后两样覆盖晚上的四轮上板，入库为 `logs/coex-merged-wifi-link-ap-side.log`。

**AP 日志里今天各轮的样子。** 成功的连接在 AP 侧都是同一个序列：`authenticated` → `associated (aid 1)` →
`AP-STA-CONNECTED` → `WPA: pairwise key handshake completed (RSN)` → `EAPOL-4WAY-HS-COMPLETED` → DHCP 四步（连上后 1 秒内
ACK）→ 约 15 秒后板子主动断开。失败与退化的几轮，AP 侧各有一句对得上的话：

| 轮 | 板子那边 | AP 日志 |
| --- | --- | --- |
| 修之前的 11 轮（13:03–13:51） | 扫描只剩个位数、连不上 | 每轮都是 `did not acknowledge authentication response`，65 秒后 `deauthenticated due to local deauth request`：AP 收到了板子的认证请求，发了响应，没等到板子的确认。板子发得出、收不到，在 AP 侧看得最直接 |
| C（不写回） | 认证、关联成功后被 `reason=7` 断开 | 同上：`did not acknowledge authentication response`，没有 `associated` 这一行 |
| E（只跳过 `initPhy`） | 连接 `reason=2` | 同上 |
| B（两段都不跳过，第一次） | 连上，DHCP 3887 ms | 四次握手完成；DHCP 第一次 DISCOVER / OFFER 之后板子没有接着发 REQUEST，4 秒后重新 DISCOVER 才 ACK |

**晚上带站点统计的四轮。** 都是 `-Dcoex-wifi-link -Dcoex-ble-enable`，从提交的源码构建；对照轮只做临时改动，跑完即恢复。

| 轮 | 板子：BLE init 之前 → 之后 | 板子的链路 | AP 日志 | AP 看这一条链路 |
| --- | --- | --- | --- | --- |
| 最终形态（两次） | 27 → 34、24 → 32 个 AP | 连上约 2.06 s，DHCP 27–51 ms，ping 网关 10/10，16/16 | 完整序列，连上后 1 秒内 DHCPACK | 信号 -24 dBm；AP → 板子 86 Mbit/s（HE），板子 → AP 86 Mbit/s（HE）；15 秒里重传 0–1 次、放弃 0–1 次 |
| D 的第二次（只跳过第 15 步） | 30 → 4 个 AP | 连上 2866 ms，DHCP 55 ms，ping 9/10（平均 68 ms）；新判据失败，15/16 | 完整序列 | 信号 -23 dBm；AP → 板子先降到 6 Mbit/s、再 8.6 Mbit/s；15 秒里重传 47 次、放弃 51 次（共发 51 帧）；板子 → AP 的速率在 1 / 6 / 86 / 73 Mbit/s 之间跳 |
| B 的第二次（两段都不跳过） | 28 → 2 个 AP | 关联没完成，`reason=4`；新判据失败，11/16 | 只有 `authenticated`，没有 `associated` | 板子没关联上，没有站点统计 |

读法：

- **退化在板子的接收侧。** 对照 D 里 AP 收到的信号与健康时一样强（-23 / -24 dBm），但 AP 发给板子的帧一半左右放弃、
  速率被压到传统 OFDM 的 6–8.6 Mbit/s。板子自己扫描时只看到 4 个 AP、ping 网关丢 1 个，是同一件事。
- **"两段都不跳过"的结果每轮不一样。** B 的第一次能连上（只是 DHCP 慢），第二次关联都没完成。退化状态下失败在哪一步
  是随机的：AP 日志里 C、E 是认证响应没被确认，B 的第二次是关联没完成。
- **判据。** 这两轮退化镜像上，新加的那条判据都如实失败（`4 vs 30`、`2 vs 28`）。

**同网段的另一台主机。** 工作站在 AP 的有线侧（192.168.31.156）。等 AP 报告板子连上之后再发起，网线上抓到：

```text
22:49:27  eth dst ff:ff:ff:ff:ff:ff src c8:53:09:d0:6d:85  ARP request  who-has 192.168.31.151 tell 192.168.31.156
22:49:27  eth dst c8:53:09:d0:6d:85 src 1c:29:04:d1:99:28  ARP reply    who-has 192.168.31.156 tell 192.168.31.151
22:49:27  eth dst 1c:29:04:d1:99:28 src c8:53:09:d0:6d:85  ICMP type=8 code=0 seq=1  192.168.31.156 -> 192.168.31.151
```

工作站的邻居表项随即变成 `192.168.31.151 lladdr 1c:29:04:d1:99:28 REACHABLE`：板子的 ARP 应答跨过 AP 的桥到了另一台
主机，这是板子发出的帧第一次在板子之外被抓到。10 个回显请求一个都没有应答：
`components/wifi-blobs/src/data_path.zig` 的 ICMP 分支只处理回显应答（`handleEchoReply`），没有"收到回显请求、回一个应答"
这一半。板子只发 ping，不回 ping。这是数据通路的一个缺口，不是链路问题，与共存无关；记入待办。

探测方式踩到的一个坑：如果从一轮开跑就 ping 板子，板子 40 秒后才连上，这期间 Linux 已经把邻居表项判成 FAILED，之后不再
重发 ARP（七分钟后仍是 FAILED）。所以"工作站 ping 板子 0 个回应"要先分清是这个，还是板子真没回。

**边界。**

- 这一节的证据里没有空口上的帧（802.11 的认证、关联、EAPOL 帧本身）：当时路由器装不了 tcpdump。后来补上了，见 15.9。
- 路由器的日志是约 1300 行的环形缓冲，新的挤掉旧的；入库的是 22:52 那一份，更早的读数（昨晚的第一次关联）已经被挤掉。
- 每个轮次只跑一次。对照 B 的两次结果不同（15.2 的第一次连上，这次关联没完成），样本是 2。
- 站点统计里的速率是 AP 速率控制的瞬时值；`iw` 的字段随驱动而异，mt76 给的就是上面这些。


### 15.9 空口上的帧（2026-11-27 凌晨）

15.8 的三样证据里没有 802.11 帧本身：路由器装不了 tcpdump。装不了包不等于跑不了程序——在工作站上交叉编译了一个静态的
tcpdump（libpcap 1.10.5 与 tcpdump 4.99.6，`zig cc -target aarch64-linux-musl`，1 371 592 B），放进路由器的内存盘
`/tmp`：不是装的包，重启即消失。脚本在 `tools/ap-side/`（构建、采集、整理三件），用法见同目录的 README。从仓库里的脚本
从头构建，产物的 SHA-256 与路由器上正在用的是同一个。
【2026-11-27 凌晨更正】「放进内存盘、重启即消失」是最初的做法；只放内存盘的那份在路由器上敲 `tcpdump` 是 not found。
后来同一个二进制装到了路由器的 `/usr/bin/tcpdump`（flash 上的 overlay，重启不丢，`rm` 即卸载），现在在路由器上直接
`tcpdump` 就能用；工作站上的 `~/.local/bin/tcpdump` 也是同一个脚本编的。构建与上传的命令见 `tools/ap-side/README.md`。

抓包点试了三处，前两处都不够：

| 抓哪里 | 看得到 | 看不到 |
| --- | --- | --- |
| AP 接口 `phy0-ap0` | 数据面的帧（驱动转成以太网格式）、微秒级时间戳 | 管理帧（认证、关联、去认证走 nl80211，不经过网卡的抓包点）；EAPOL（这个内核 6.12.112 + mt76 上抓不到） |
| `any` | 每一帧经过哪些接口 | 同上 |
| 临时 monitor 接口 | 空口上的 802.11 帧：探测、认证、关联、EAPOL 四条、加密数据帧的首部、解关联、去认证；带微秒时间戳、速率、信号 | 载荷（本来就是密文；EAPOL 只有首部摘要） |

monitor 接口与 AP 在同一个射频、同一个信道上：`iw dev phy0-ap0 interface add <名> type monitor`，建得起来也删得干净。
采集脚本只抓地址里有板子 MAC 的帧，每帧 256 字节，只输出 tcpdump 的文字摘要（不带 `-v` / `-x`）；退出、出错、被中断时
都删掉接口，不写任何持久配置。五个轮次之后在路由器上核对：monitor 类型的接口 0 个。

五个轮次：最终形态（提交的源码，没有临时改动）、E 的第三次（只跳过 `initPhy`）、C 的第二次（不写回）、B 的第三次
（两段都不跳过）、D 的第三次（只跳过第 15 步）。入库 `logs/coex-merged-wifi-link-ap-frames.log`（492 行：每轮板侧读数
一行、AP 日志里这一轮的行、一行一帧的清单；邻居的 SSID / BSSID 换成标签，与板侧日志同一套编号），站点统计补在
`logs/coex-merged-wifi-link-ap-side.log` 末尾。时间：路由器的时钟是 GMT、没有 NTP，比标准时间慢 38 天 14 小时 4 分 22 秒；
帧的时间戳是路由器的 epoch 秒，加这个差再按本机时区显示就是本机时间（路由器显示的墙钟加 38 天 22 小时 4 分 22 秒，其中
8 小时是时区）。三份证据的头部原先写成「慢 38 天 22 小时」，只写了墙钟那一个数，已改成两个数都写；换算本身一直是对的。

**读数。**

| 轮 | 帧数 | 板子发来的帧的信号（强 → 弱） | 认证请求 → 关联应答 | 消息 1 → 消息 2 | 消息 3 → 消息 4 | AP 15 秒里的重传 / 放弃 | 结局 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 最终形态 | 82 | -28..-21 dBm | 19 ms | 262 ms | 23 ms | 0 / 0 | 连上 15 秒后板子发解关联，1.2 秒后 AP 发去认证 |
| E 的第三次 | 88 | -28..-23 dBm | 22 ms | 260 ms | 17 ms | 16 / 16 | 同最终形态；板子发往网关的加密帧有 11 个（ping 是 10 个，多出的一个在 281 ms 之后） |
| C 的第二次 | 18 | -26..-24 dBm | 25 ms | 没有消息 1 | — | 板子没关联上 | 板子发了一个数据帧，AP 回「来自未关联站点的 3 类帧」的解关联（`reason=7`） |
| B 的第三次 | 97 | -27..-23 dBm | 21 ms | 260 ms | 19 ms | 15 / 18 | 同最终形态；解关联帧板子发了两遍 |
| D 的第三次 | 88 | -26..-23 dBm | 22 ms | 262 ms | 16 ms | 28 / 29 | 同 B |

E、B、D 三次的板侧链路：连上 2055 / 1954 / 1958 ms，DHCP 55 / 24 / 49 ms，ping 网关 10/10、9/10、9/10；新判据「扫描 AP 数
不低于基线一半」都失败（32 → 3、32 → 2、30 → 3），整体 15/16。最终形态这一轮是 29 → 18 个 AP、16/16。

清单共 373 行，其中 5 行是 monitor 接口把同一帧重复交付的（时间戳与内容完全相同：B 的第三次里 4 行，一行 ADDBA 请求、
三行 QoS 帧；E 的第三次里 1 行 QoS 帧），不是板子重发；各轮的「帧数」含这些重复。

读法：

- **板子的发射在每一轮都是好的。** 五个轮次里板子发来的帧在 AP 这边都是 -21 到 -28 dBm，扫描掉到 2–3 个 AP 的三轮
  也一样。
- **连上的四轮，空口上的关联过程同序、间隔相同。** 关联应答之后 2 ms AP 发消息 1；板子隔 260–262 ms 才回消息 2（最终
  形态也是这样，不是退化引起的）；AP 1 ms 后发消息 3；板子 16–23 ms 后发消息 4。
- **退化的三轮里，AP 发给板子的帧要重传。** 站点统计 15 秒里重传 15–29 次、放弃 16–29 次，AP → 板子的速率压到
  6.0 / 8.6 Mbit/s；最终形态是 0 / 0、86 Mbit/s。信号一样强而 AP 的帧送不到，与 15.8 的结论一致：退化在板子的接收侧。
- **C 那一轮：板子的帧到了，AP 也答了，但 hostapd 没留下这个站点。** 空口上板子发的去认证帧、认证请求、关联请求
  都在；AP 发出了认证应答和关联应答（成功、AID 1）。hostapd 只记了一句「没有确认到认证响应」，没有 `associated` 这一行，
  消息 1 从来没有发出。板子没有重发认证请求或关联请求，550 ms 后发了一个数据帧，AP 回了 `reason=7` 的解关联。也就是说
  这一轮板子收到了 AP 的两个应答；丢的是 AP 对它自己那一帧的确认（这一条是从 hostapd 的日志读出来的，清单里没有 ACK）。
- **扫描与关联之前。** 板子的探测请求是通配的（SSID 为空），信道 1、2 上的 AP（含用户自己的）都有应答；定向探测
  （SSID = `hl-wifi`）之后 1–3 ms AP 应答，板子再过约 1.5 s 发一个去认证帧（`reason=3`，1–10 ms 之后才是认证请求）。
  五轮都如此。
- **数据阶段（最终形态）。** 握手后板子发了三次块确认请求（ADDBA）；之后每秒一个回显请求发往网关（AP 自己），1–3 ms 后
  AP 的应答在空口上出现，十个都有应答。帧的内容是密文，摘要里只有首部。

边界：

- AP 发出的帧在 monitor 接口上的时间戳不保证是第一次发出的时刻。E 的第三次里一个回显应答在清单里比请求晚 384 ms，
  而板子自己量到的往返最大值是 18.7 ms——所以 AP → 板子这一侧的重传节奏以站点统计为准，不用帧清单的时间去算。
- 控制帧（ACK、块确认、RTS / CTS）不在清单里，原因没有查。每帧只抓 256 字节，长帧的尾部不在。
- 入库前把邻居的 SSID / BSSID 换成标签，标签表因此多了一个只出现在这些抓包里的 AP（`ap-41`）；口令与路由器的登录记录
  不入库。
- 每个轮次一次；这些帧说明「板子发得出、AP 答了、hostapd 没确认到」，不说明 AP 那一帧板子为什么没确认。

## 16. 时钟域按单元取并集（2026-11-27）

§15 用事后写回补救的那一处，正解做掉了。设计见 ADR-003 第 4 节的实现记录（2026-11-27）。

### 16.1 做法

两边共享的时钟 / 电源字上，每个射频**只置位、不清位**，置的位是它依赖的时钟单元（IDF 的依赖表，
`components/radio-coex/src/owner.zig` 的 `clocks`）。改掉的写：

| 文件 | 原来 | 现在 |
| --- | --- | --- |
| `bt-blobs/src/porting.zig`，`btdmLpEnableClock` | `CLK_CONF1 ← 0x003FF880` 整字（清掉 Wi-Fi 的基带、MAC、APB 共 10 个时钟位） | `\|=` BT 的三位 + 共用的 `wifibb_80x1` + PHY 前端 |
| 同上 | 强开位 `FORCE_ON ← 0xFF` 整字 | `\|= 0xF8`（PHY 前端与 BT 的五个；Wi-Fi 的基带 / MAC / APB 不替它决定） |
| 同上 | `LPCON CLK_CONF ← 0x0B` 整字（清掉 PHY 的 I2C 主控位） | `\|= wifipwr + coex + lp_timer` |
| `bt-blobs/src/bringup.zig`，`init` 开头 | `CLK_CONF ← 0x00201002`、`TEST_CONF ← 0x100` 整字 | 置位 |
| `wifi-blobs/src/osi_impl.zig`，`_wifi_clock_enable` | `LPCON ← 0x3` 整字 | `\|= 0x3` |
| 同上，`_wifi_clock_disable` | 无条件清共存时钟、`MODEM_CONF ← 0x25` | BLE 还占着共享单元时不动（BT 自己的三个单元还置着就是还占着） |
| `wifi-blobs/src/init_probe.zig`，`initOnly` | `TEST_CONF ← 0x100`、`CLK_CONF ← 0x00201002` 整字 | 置位 |
| `firmware/src/coex_merged.zig` | BLE init 之前存快照、之后整字写回 | 删除；四个时点按并集核对（`checkClocks`） |

整字写只留 IDF 自己也整字写的两处：时钟源 `MODEM_CONF`（`0x3D` / `0x25`）与初始化的 ICG 位图。
单独的 Wi-Fi 探针、单独的 BLE 探针读数不变：它们的寄存器从复位值起步，置位与整字写的结果相同。

### 16.2 板侧读数（`logs/coex-merged-wifi-link-union-boot.log`）

最小合并镜像（`scripts/build-coex-link-image.sh`，`BLE=1`，1 224 304 B）：

| 时点 | `CLK_CONF` | `FORCE_ON` | `CLK_CONF1` | `LPCON CLK_CONF` | `MODEM_CONF` |
| --- | --- | --- | --- | --- | --- |
| Wi-Fi start 之后 | `0x00201002` | `0x00000000` | `0x0038E7FF` | `0x00000005` | `0x00000025` |
| BLE init 之后 | `0x7E601002` | `0x000000FC` | `0x003FFFFF` | `0x0000000F` | `0x0000003D` |
| BLE enable 之后 | `0x7E601002` | `0x000000FC` | `0x003FFFFF` | `0x0000000F` | `0x0000003D` |
| 整轮 Wi-Fi 链路之后 | `0x7E601002` | `0x000000FC` | `0x003FFFFF` | `0x0000000F` | `0x0000003D` |

`CLK_CONF1 = 0x003FFFFF` 是三组的并集：Wi-Fi 的 bit0-10、PHY 前端的 bit11-15 与 19-21、BT 的 bit16-18。
链路：基线扫描 38 个 AP，BLE init 之后 34 个；连上、DHCP、ping 网关 10/10（最小 1.9 / 平均 4.9 / 最大 12.6 ms）、
稳定 5 秒。`checks: passed=20 failed=0`，`verdict=pass`。不再需要任何事后的写回。

`FORCE_ON = 0xFC`：bit3-7 是 BLE 的 init 置的（PHY 前端与 BT 的五个强开位），bit2（`wifi_apb_fo`）来自 BLE 的 PHY 域序列
（`phyDomainEnable`，它在 PHY 归 Wi-Fi 时仍然会跑）——也就是 BLE 仍在替 Wi-Fi 决定一个强开位，对应下面边界里的那一条。

**单独的射频各回归一轮**（两个适配层的时钟写都改过）。单独的 Wi-Fi 真实链路镜像（`-Dwifi-link-probe` + 共存核，
`logs/wifi-link-clock-union-boot.log`，基线 `logs/wifi-link-connect-boot.log`）：扫描 37 个 AP（基线 40）、连上、DHCP 102 ms
（基线 105 ms）、ping 网关 10/10（最小 / 平均 / 最大 11.9 / 18.8 / 23.9 ms，基线 13.1 / 23.1 / 30.2 ms）、本地断开。
单独的 BLE 探针（`logs/bt-probe-clock-union-boot.log`）与基线 `bt-probe-pmu-icg-control-boot.log` 逐行等价：`INITED`，
随后是同一个 `ble_hw.c:506` 断言墙；差别只有逐调用日志交错处的噪声。

### 16.3 判据在第一次上板时抓到了一处遗漏

只改 BLE 侧时的第一轮：BLE init / enable 之后并集是对的，但 Wi-Fi 走完链路那一段之后 `LPCON` 回到 `0x05`、
`MODEM_CONF` 回到 `0x25`，判据报 `missing lpcon=0x0000000a modem_conf=0x0000003d`，15/16。追下去是 Wi-Fi 自己的
`_wifi_clock_enable` / `_wifi_clock_disable`（表里第 5、6 行）。改掉之后是上面的 20/20。那一轮的日志没有单独留档
（同名文件被后一轮覆盖），数字取自当时的串口读数。

### 16.4 读法

- 之前「不写回时钟 / 电源寄存器就 `reason=7` 断开」（§15.2 的对照 C）的原因就是 BLE 整字覆盖 `CLK_CONF1`：
  Wi-Fi 的 MAC 与 APB 时钟位被清掉。现在不写回也通过。
- 之前的整字写回把 BLE 的时钟全拿掉了：`CLK_CONF1` 的 BT 三位、`CLK_CONF` 的 BLE 定时器与 modem 安全模块、LPCON 的
  共存与 LP 定时器时钟、时钟源。合并镜像里的 BLE 一直是被这样掐着的；§14 与 §15 的读数都是在这个状态下取的。

### 16.5 边界

- BLE 的射频仍然没有起（R3.3），所以「BLE 的位都在」只说明时钟配置对了，不说明 BLE 在这份配置下能工作。
  【2026-11-27 晚：合并镜像里 BLE 的广播已上空口，时钟并集就是它跑着的那份配置，见 §17.5。】
- 核对是「有位」比较：多出来的位不算错（BLE 移植层额外开的 `fe_20m` / `fe_40m` 就不在单元表里）；强开位没有判据。
- 没有做：BLE 的 disable 路径（释放自己的单元）；「BLE 先起」的顺序下 Wi-Fi init 之前把 `LPCON+0x18` 对正成 `0x1`
  的那一句仍然会清 I2C 主控位；BLE 的 PHY 域序列（含写 flash 的探针标记）与 XTAL trim 在 PHY 归 Wi-Fi 时仍然会跑。
- 时钟源：IDF 的 station 镜像在扫描之后读回 `0x25`（`logs/wifi-idf-oracle-regdump-boot.log`），本仓的 Wi-Fi 路径相同；
  BLE init 之后是 `0x3D`，Wi-Fi 的链路就是在这个时钟源下跑的，与 IDF 里「Wi-Fi 先、BLE 后」的组合一致。

## 17. 合并镜像里让 BLE 起广播（2026-11-27）

> 【2026-11-27 更正】本章 §17.2–§17.4 记的是修掉之前的样子，结论已被 §17.5 推翻：广播使能之后板子失声，不是 controller
> 任务不让出，也不是时钟被门控，是 BT MAC 的中断在无限重入（中断桥登记错了一个下标）。修掉之后合并镜像里 BLE 的广播
> 上了空口，L4b 有了证据；读数在 §17.5。

### 17.1 做法

- `-Dcoex-ble-adv`（要求 `-Dcoex-ble-enable`）：所有判据之后，`bt-blobs/src/probe.zig` 的 `advertiseOnly` 经 HCI 发三条
  命令——LE Set Advertising Parameters（[Vol 4] Part E §7.8.5：间隔 0x00A0 = 100 ms——这些字段是 0.625 ms 一档、ADV_NONCONN_IND、信道图 0x07）、
  LE Set Advertising Data（§7.8.7：Flags + 名字 `s31`）、LE Set Advertising Enable（§7.8.9）——然后泵 3 秒、每轮读
  synth 锁定位（`0x201098BC` 的 bit2）。判据：三条命令的回包 Status 为 0、锁定位至少置位过一次；之后让 Wi-Fi 在
  BLE 广播着的时候再走一遍链路（ADR-003 第 5 节的 L4b）。
- 命令从一个独立栈上的发送任务里发（`sendFromTask`，栈 8 KB，从 BLE 的 arena 里分）。【2026-11-27 第一版是在
  主上下文里同步发，三次上板都停在第一条命令上，见 §17.3】任务阻塞时切回主上下文，主上下文每轮泵 controller
  任务、再把发送任务恢复回来；等发送、等回包都按时间与轮数双重封顶（blob 会把定时器门控掉，只按时间判会永远等）。
- 回包匹配按 §7.7.14：Command Complete 的 opcode 在八位组 3..4、Status 在 5（第一版把位置写错了，已改）。
- 过程另写一份到 flash：`0x18E000` 一个扇区（factory 与 `ota_0` 之间，不属于任何分区），发命令之前擦，每一步一条
  32 字节记录；主机侧 `esptool read_flash 0x18E000 0x1000` 读回，`tools/ap-side/decode-adv-marker.py` 解码。
  加它是因为广播使能之后串口会停（§17.2），「命令发到哪、回没回」不能只靠串口判断。它只写到 `0x200A` 的"正要发"
  为止：回包之后那次写不会返回（§17.3），所以发完这条记录就冻结，之后的采样只留在 RAM 里。
- 等待有三重上限：时间、轮数（100 万轮）、CPU 周期数（400 M 个，1.5–2.5 秒）——广播使能之后定时器会被门控，
  按时间判等不到头。
- 排在所有判据之后：广播使能之后板子不再出声，后面的 Wi-Fi 链路也走不到，前面的判据已经打完。默认关：不开
  `-Dcoex-ble-adv` 时调用点在编译期被去掉，这段代码不进镜像。
  【2026-11-27 晚更正】上面「回包之后那次写不会返回」「广播使能之后定时器会被门控」「广播使能之后板子不再出声」三处
  说的是修掉中断风暴之前的样子（§17.5）：回包之后主上下文是被中断风暴挡住的，定时器没有被门控；现在这一步跑完之后
  照常打 `checks:` 汇总。第二遍 Wi-Fi 链路之后 BLE 再广播 15 秒（只泵 BLE），收尾时打一行中断桥的计数与核的读数。

### 17.2 板侧读数

上板十次，分七组：第一版三次，之后 `ble-adv2` 到 `ble-adv8` 各一次。`ble-adv3` 的串口与落盘记录和 `ble-adv4` 相同，
`ble-adv5` 的串口、`ble-adv7` 的串口和 `ble-adv8` 相同，这几次的重复文件没有入库。

| 组 | 镜像 | 日志 | 三条命令的回包 | 之后 |
| --- | --- | --- | --- | --- |
| A（第一版，主上下文里发） | 三次同一个结局，最后一次的日志入库 | `logs/coex-merged-wifi-link-ble-adv-boot.log` | 第一条命令（0x2006）发出后没有任何回包行 | 日志停在半行 `bt call: eventq…`，之后 80 多秒没有输出 |
| B（发送任务，`ble-adv2`） | — | `logs/coex-merged-wifi-link-ble-adv2-boot.log` | 0x2006：Command Complete，Status 0x00，10 ms；0x2008：同，8 ms | 0x200A 之后只剩一行 `bt call: eventq_get`，之后到抓取结束（100 秒）没有输出 |
| C（发送任务 + 落盘记录，`ble-adv3` / `ble-adv4`） | 两次结果相同，后一次入库 | `logs/coex-merged-wifi-link-ble-adv4-boot.log`、`logs/coex-merged-wifi-link-ble-adv4-marker.txt` | 0x2006、0x2008、0x200A：都是 Command Complete，Status 0x00 | 0x200A 的回包行打到 `…status=0x00 after 0` 停住，是日志的最后一行；落盘记录的最后一条是 `0x200a about to send` |
| D（C + 每次落盘之前回写单独探针第 112 轮的整套时钟字，`ble-adv5`） | — | `logs/coex-merged-wifi-link-ble-adv5-marker.txt` | 同 C | 落盘记录仍然停在 `0x200a about to send` |
| E（发完 `0x200A` 的"正要发"记录就冻结，回包之后不碰 ROM，`ble-adv6`） | — | `logs/coex-merged-wifi-link-ble-adv6-ap-syslog.log` | — | AP 只记到第一次那一次关联 |
| F（E + 等待按 CPU 周期封顶，`ble-adv7`） | — | `logs/coex-merged-wifi-link-ble-adv7-ap-syslog.log`、`logs/coex-merged-wifi-link-ble-adv7-ap-frames.log` | — | AP 只记到一次关联；monitor 接口上板子的帧到第一次断开为止，之后约 100 秒一帧都没有 |
| G（拿掉 D 的回写之后的最终代码，`ble-adv8`） | — | `logs/coex-merged-wifi-link-ble-adv8-boot.log`、`logs/coex-merged-wifi-link-ble-adv8-ap-syslog.log`、`logs/coex-merged-wifi-link-ble-adv8-ap-frames.log` | 0x2006、0x2008、0x200A：都是 Command Complete，Status 0x00 | 同 F；串口停在那一行的第 58 个字节上 |

每一组前面的判据都全部通过（时钟并集、基线扫描与链路扫描、连接、DHCP、ping），所以各组之间的差别只在广播这一步。
没有 `checks:` 汇总行，也没有复位记录。

C、D 组的落盘记录：C 是 7 条，D 是 8 条，照顺序是启动、（D 多一条发命令之前读到的时钟字）、`0x2006` 正要发、一条采样
（`0x201098BC` = 0、`0x2010F800` = `0x01700266`）、`0x2006` Status 0x00、`0x2008` 正要发、`0x2008` Status 0x00、
`0x200A` 正要发。按 C 的代码顺序，下一条应当是 `0x200A` 的回包（那条回包行串口上已经打出来了），之后每 20000 轮一条
采样、收尾三条——都没有。D 读到并回写的时钟字是 `MODEM_CONF=0x3D`、`CLK_CONF=0x7E601002`、`CLK_CONF1=0x003FFFFF`、
`LP_CLK_CONF=0x0F`，`SYSTIMER_CTRL0` 本来就是 `0x11`。

G 组的三份证据对得上：串口最后一行是 `bt adv: cmd 0x200a got Command Complete status=0x00 after 0`；AP 的系统日志里
板子只关联了一次（路由器时钟 06:15:17 连上、06:15:33 断开，采集窗口 06:14:47–06:17:17）；monitor 接口上板子发的帧到
去关联为止（本机时间 04:20:01），最后一帧是 04:20:02 AP 发的去认证，采集窗口到 04:22:02。F 组相同（路由器时钟
06:09:35 连上、06:09:50 断开）。

工作站蓝牙扫描（`bluetoothctl scan on`，hci0）八次：110 秒一次，150–220 秒七次（各看到 12–16 台别的设备），都没有
名字 `s31` 的设备，也没有板子的 MAC 地址开头的设备。

### 17.3 来龙去脉

> 【2026-11-27 更正】下面「C 到 G 组卡在哪」的四条观测是原样，「读法」是错的：主上下文不是停在第一次恢复 controller 任务
> 的时候，而是被中断风暴挡在 `mret` 之后——见 §17.5。

- **A 组卡在哪**：这类命令的接收路径带着 FOREVER 去等 controller 任务，而任务要等泵——「rx 阻塞等任务 = 任务等
  泵」（`probe.zig` 里轮 14、轮 95d 的注释）；`components/osal/src/sched.zig` 的 `block()` 是「把当前上下文切回主
  上下文」，从主上下文自己调用它，等于切回上一次 `resumeTask` 保存的旧现场。当时试过两种改法（主上下文里的
  FOREVER 等待改成让任务跑一轮；改成有界忙等后超时），结局都一样，两处改动都已撤回。B 组把发送挪到任务里，
  OSAL 的等待原语一个字没改，命令就通了。
- **C 到 G 组卡在哪**：广播使能被接受（Command Complete、Status 0x00）之后。这与单独探针记的「时钟收缩」和
  「紧等待环」是同一处（`components/bt-blobs/README.md` 轮 96–117）。四条观测：
  1. 串口是在回包行打到第 58 个字节时停的——门控不是瞬间发生的。
  2. 回包之后紧跟的那次 flash 写没有落盘。写之前回写泵的三个门控字与 SYS_TIMER 的时钟使能（`ble-adv4` 的镜像），再把
     单独探针第 112 轮的整套回写补上（`ble-adv5`），记录都停在 `0x200A` 的"正要发"。
  3. 去掉这次 flash 写之后（`ble-adv6`），板子在广播这一步之后没有任何动静，但那一轮的等待只按轮数封顶，不说明问题；
     再按 CPU 周期封顶之后（`ble-adv7`、`ble-adv8`）一样：串口没有一行、AP 没有第二次关联、monitor 上板子没有一帧。
  4. 回包行是在等回包那个循环的第一次 `pumpStep()` 之后打出来的——controller 任务交出回包之后让出过一次。
- **读法**：主上下文停在回包之后第一次恢复 controller 任务的时候，与单独探针轮 117 记的「0x200A 之后 blob 进入无断言
  紧等待环、CPU 饿死全静默」一致。**分不清的只剩一种**：主上下文活着，但 Wi-Fi 在收缩之后不再发帧（那样第二次链路
  的扫描是空的，AP 一侧看起来一样）。

### 17.4 结论与下一步

> 【2026-11-27 更正】下面第 2、3 条结论是错的（广播使能之后不是 controller 任务不让出，是中断风暴；合成器 35 ms 内就锁了，
> 广播上了空口）；「下一步」里的两条当晚都做了，结果在 §17.5。

- **命令层不再是卡点**：合并镜像里经 HCI 发 LE Set Advertising Parameters / Data / Enable，三条都回了 Command
  Complete、Status 0x00（[Vol 4] Part E §7.7.14 的回包格式、§7.8.5 / §7.8.7 / §7.8.9 的命令）。在合并镜像里发需要
  controller 任务处理的 HCI 命令，要走 `probe.zig` 的 `sendFromTask`，不要在主上下文里发。
- **广播使能被接受之后 controller 不再让出**：Command Complete 回到 host 之后，controller 任务进入不让出的等待，HP 侧的
  串口、定时器、ROM flash 跟着停；共存核已启动、PHY 归 Wi-Fi 都没有改变它。单独探针第 112 轮的时钟回写在这份镜像里
  不改变结局，那两样回写已从代码里拿掉。
- **对 R3.3 仍然没有结论**：合成器锁定位在广播使能之后一次也没有读到。空口上没有看到板子的广播，所以 L4b（两个射频
  同时收发）仍然没有证据。
- 下一步（没有做）：凡是靠主循环往外写的通道（落盘、LP RAM 槽）在回包之后都到不了，只剩两条——找一个收缩之后还在
  走的中断源、在 ISR 里采样 PC；或在收缩生效之前用数据观察点抓到 blob 写时钟门控的那条指令。单独探针那一侧的
  「时钟收缩」与合成器不锁，见 `components/bt-blobs/README.md` 轮 96–162。

### 17.5 根因：中断风暴；修掉之后两个射频同时上了空口（2026-11-27）

**根因。** blob 在 enable 里调 `intr_alloc(124)`，OSAL 的钩子 `bt-blobs/src/bringup.zig` 的 `intrArm` 把 MODEM_BT_MAC
（源 124）路由到 CLIC 输入 24，并把中断桥登记进 trap 分发表；登记用的下标是 **24**，而 `trapDispatch` 查表用的是
**外部中断号**（CLIC 输入号减 16，这里是 8；`boards/esp32s31-coreboard/src/trap.zig` 的 `setHandler` 注释写明了这个约定）。
于是分发器永远查不到中断桥。泵的每一轮经 `bridgeReenable()` 开着输入 24 的 IE；广播使能一处理，BT MAC 拉起这个电平
中断，trap 进来查不到 handler 就返回，`mret` 之后立刻再进——**中断风暴**，主上下文一个指令也执行不到。串口那一行停在
半行，是主上下文再也没回来写剩下的字符；落盘记录停在「正要发」同理。单独探针（`-Dbt-probe`）里没有这个风暴：它开着
全局中断、也登记了这座桥，但那边的 controller 没有走到拉起这个中断的一步，主上下文一直在跑（见下面「边界」）。

修法一行：`setHandler(routed_input - 16, …)`。合并镜像在发广播使能之前多一条判据，核对源 124 的路由与分发器查到的
handler（`check: ble interrupt bridge wired: MODEM_BT_MAC -> input 24 (want 24), handler 0x…`）；`-Dcoex-adv-irq` 的
中断探针留着（看哪个输入在风暴），发广播使能之前打的两个诊断读数也留着。为找根因临时加的 STORE 观察点
（`-Dcoex-adv-watch`，RISC-V debug trigger 0）与「时钟门控回写的开关」在根因定了之后已从代码里删掉。

**怎么找到的**（都在合并镜像 `-Dcoex-wifi-link -Dcoex-ble-enable -Dcoex-ble-adv` 上）：

| 步 | 做法 | 看到了什么 |
| --- | --- | --- |
| 1 | 泵里武装 T0 采样（中断里记被中断的 PC） | 一武装，中断计数每秒多出几十万——风暴第一次露头，当时记在采样器头上 |
| 2 | 发广播使能之前在 `UART0_CTRL0`（`0x20587088`）上武装 STORE 观察点，带自检（先武装在自己的静态字上写一次：命中、打一行 `BP!`、恢复执行） | 广播使能之后这个地址上一次 store 也没有，板子照样失声 |
| 3 | 观察点换到 `SYSTIMER_CTRL0`（`0x20587120`） | 同上，零命中 |
| 4 | `-Dcoex-adv-irq`：trap 处理器里挂一个每个中断调一次的钩子，每 4096 个中断打一行各输入的计数与最近 4 个被中断的 PC | 风暴：只有输入 24 在涨，被中断的 PC 每次都是同一个地址 |
| 5 | **单变量对照**：最终代码，只把登记下标改回 24 | `check: ble interrupt bridge wired: MODEM_BT_MAC -> input 24 (want 24), handler 0x00000000 ok=0`；`handler(8)=0x0 handler(24)=0x400bf7b2`；紧跟在 `0x200A` 的回包行后面风暴，累计 2001 万次中断，没有 `checks:` 汇总行 |
| 6 | 登记下标改成 `routed_input - 16`（与第 5 步是同一份源码，只差这一行） | `check: ble interrupt bridge wired: … handler 0x400bf7b2 ok=1`；没有风暴；合成器锁定；AP 记到第二次关联；工作站扫描看到 `s31` |

第 1–4 步的日志没有入库（第 4 步之后先加了诊断行与这一行修法，两者一起上板，所以第 5 步是事后在最终代码上补的
对照）。第 5 步是 `logs/coex-merged-wifi-link-ble-adv-storm-boot.log`，第 6 步是 `logs/coex-merged-wifi-link-ble-adv12-boot.log`
（27/27）。之后给中断桥多加一个计数（代跑的里面跑的是纯计数桩的次数）、给核的读数多加两组状态位，又上板一次：
`logs/coex-merged-wifi-link-ble-adv13-boot.log`（27/27，最终代码）。

**风暴的样子**（第 5 步，只差那一行）：

```text
check: ble interrupt bridge wired: MODEM_BT_MAC -> input 24 (want 24), handler 0x00000000 ok=0
bt adv: handler(8)=0x0 handler(24)=0x400bf7b2 clic24=0x7fc00100 clic25=0x1fc00100 mie24=0 mie25=0
bt call: bt adv: cmd 0x200a got Commabt adv: irq n=4096 inputs 24:4096 pc 400a8402 400a8402 400a8402 400a8402
bt adv: irq n=724992 inputs 24:724992 pc 400a8402 400a8402 400a8402 400a8402
bt adv: irq n=20013056 inputs 24:20013056 pc 400a8402 400a8402 400a8402 400a8402
```

第三行是 `0x200A` 的 Command Complete 回包行：只写到一半，中断探针的第一行就插了进来，回包行的后半截再也没有出来。
探针按 CPU 周期限速（两行之间至少 0.75 秒），每行的计数多约 71 万 ⇒ 每秒约 95 万次（上限），全部是输入 24。
`clic24=0x7fc00100`：输入 24 的 IE 开着（泵的 `bridgeReenable()` 每一轮都写），而分发器在下标 8 上什么也没查到。

**修之后的读数**（`ble-adv12`，27/27，`main: verdict=pass`；标了 `ble-adv13` 的取自最终代码那一轮，也是 27/27）：

| 判据 | 读数 |
| --- | --- |
| 中断桥 | 分发器在下标 8 上查到 `0x400bf7b2`、下标 24 上是 0；全程没有一行风暴（探针每 4096 个中断才打一行，一行都没有）；15 秒收尾时的计数 `queued=957 drained=956 dropped=0`。`ble-adv13` 多一个计数：`queued=951 drained=950 dropped=0 count_only=0`——代跑的 950 次跑的都是 blob 经 `intr_alloc(124, …)` 登记的 ISR，不是纯计数桩 |
| 三条广播命令 | Command Complete，Status 都是 0x00（间隔 0x00A0 = 100 ms：这些字段是 0.625 ms 一档，NimBLE 的 `BLE_HCI_ADV_ITVL` 是 625 µs） |
| 合成器锁定位（`0x201098BC` bit2） | 106361 次读数里 106361 次置位，第一次在广播使能后 34863 µs；读数 `0x00000004`；15 秒之后仍是它 |
| BLE 广播着的时候 Wi-Fi 再走一遍链路 | 扫描 18 个 AP（基线 24 个）、连接、四次握手、DHCP、ping 10/10；往返 min/avg/max = 30.4 / 45.1 / 92.4 ms（BLE 只 enable 不广播时 1.9 / 3.5 / 10.8 ms） |
| AP 侧（取自 `ble-adv11`，同一份代码只少计数与状态位） | `logs/coex-merged-wifi-link-ble-adv11-ap-syslog.log`：路由器时钟 07:36:06 认证、关联，07:36:07 四次握手完成，07:36:08 `DHCPACK`，07:36:23 断开（第一次是 07:35:40–07:35:55，BLE 只 enable）；`…-adv11-ap-frames.log`：05:40:28.9 认证与关联响应，四次握手 05:40:29 |
| 空口（取自 `ble-adv11`） | 工作站 `bluetoothctl --timeout 230 scan on`（开在板子这一轮之前）：`[NEW] Device 02:00:00:00:BB:01 s31`，之后 `[DEL]`（扫描不再收到它）（`logs/coex-merged-wifi-link-ble-adv11-bt-scan.log`） |
| 空口上的广播 PDU 与间隔（取自 `ble-adv14`、`ble-adv15`，镜像是最终代码；工作站 `btmon` 记 HCI 事件） | PDU：两条 LE Extended Advertising Report——`ADV_NONCONN_IND`（legacy），地址类型 Public `02:00:00:00:BB:01`，主 PHY LE 1M，广播数据 8 字节——Flags 0x06（LE General Discoverable、BR/EDR Not Supported）加完整名字 `s31`；RSSI 一条 -51 dBm、一条 -25 dBm（`logs/coex-merged-wifi-link-ble-adv14-btmon.txt`）。间隔：16.9 秒里 20 次上报，相邻 19 段每一段都是「100 ms 加 0–10 ms 的 advDelay」的整数倍（最短的一段 103.9 ms，k=1；折一步在 100.8–106.4 ms），按 200 ms 只有 5 段有解——**空口上的广播间隔是 100 ms**（`logs/coex-merged-wifi-link-ble-adv15-advinterval.txt`）；RSSI 20 次 min / median / max = -54 / -49 / -47 dBm |
| 核的硬件定时器（`ble-adv13`；ADR-003 第 5 节 L4b 的判据之一） | 五个定时器在每个时点都是 `en=0`，相隔 1 ms 的两次读数相同——含 BLE 广播着、Wi-Fi 已连上的 `connected` / `after-ping` / `before-disconnect` 三个时点。「数值在两次读数之间变了」在这些读数上不成立；读数取在各阶段的边界上，之间有没有定时器在跑，这些读数看不见 |
| 核的状态位（`ble-adv13`；`coex_status_get` 的三组位图，判据之二） | 有了读数，但对不上名字。按 wifi / ble / bt 的顺序：`after-start` 起各时点 `0/0/0`，第一遍连上 `0/1/1`，广播一起 `1/0/1`，第二遍连上 `1/1/1`，收尾 `1/0/1`。也就是 BLE 一开始广播，`wifi_status` 与 `bt_status` 就恒为 1；`ble_status` 只在 Wi-Fi 连着的那三个时点为 1（第一遍链路里 BLE 还没广播时也是）。这几位的含义没有弄清，「BLE 的状态位非 0」这条判据先不能判 |

`ble-adv11` 是 27/27：合成器 106218 / 106218、34835 µs，ping 往返 26.9 / 38.9 / 97.4 ms（基线 1.9 / 4.2 / 10.5 ms），
扫描 13 个 AP（基线 24 个）。修之后一共上板六次（`ble-advw6`、`ble-adv9`、`ble-adv10`、`ble-adv11`、`ble-adv12`、
`ble-adv13`；`ble-advw6`、`ble-adv9` 的日志没有入库）：合成器都是 35 ms 内锁定，Wi-Fi 都是连上、DHCP、ping 10/10。
工作站扫描看到 `s31` 的记录有五次（`ble-advw6`、`ble-adv10`、`ble-adv11`、`ble-adv12`、`ble-adv13`；入库的只有
`ble-adv11` 那一份）；`ble-adv9` 的扫描在板子起广播之前就结束了，没有读数。`ble-adv10` 是 25/26：挂掉的是「BLE init
之后的扫描不低于基线的一半」那条（12 对 32）——同一天里健康的读数在 13–37 个 AP 之间跳，退化时是 1–4 个（§15.2），
那一次是环境。

**边界。**

- 空口上的证据是「工作站的扫描看到 `s31`」、两条 HCI 广播上报和 19 段间隔（上面表格）。间隔只在同一块板上量了这一个配置
  （0x00A0）：要让每一次广播事件都上报，得在 `bluetoothctl` 的 `scan` 子菜单里 `duplicate-data on`，默认扫描开着控制器的
  重复过滤（56 秒只上报两次）；上报很稀（约 1.2 次/秒），原因没有查。广播是不可连接的（ADV_NONCONN_IND），连接与
  GATT 没有做。BLE 从广播使能起一直广播到 section 结束（约 45 秒：3 秒泵 + 一遍 Wi-Fi 链路 + 最后 15 秒只泵 BLE），
  没有发广播关闭命令；更长时间的稳定性没有测。配方在 `tools/ap-side/README.md` 的「蓝牙一侧」。
- 广播时用的地址是 `02:00:00:00:BB:01`——`osal.readEfuseMac` 的回退值，合并镜像没有接读 eFuse MAC 的钩子。
- 「核真的在仲裁」的两条判据（ADR-003 第 5 节 L4b）都还没有过：硬件定时器在每个时点都是 `en=0`，状态位的读数对不上
  名字（上面表格）。所以现在只算「两个射频同时开着」。BLE 广播着的时候 Wi-Fi 的 ping 往返平均从 3.5 ms 涨到 45 ms
  （10 帧不丢；`ble-adv12`，`ble-adv11` 是 4.2 → 38.9 ms），涨在哪里没有查（共存核分时、还是泵的轮转，没有分开）。
- 单独探针（`-Dbt-probe`）的 synth 墙（`components/bt-blobs/README.md` 轮 96–162）不是这个风暴。那边全局中断开着，桥也
  登记了（`bt osal: arm src=124 -> CLIC input 24 (routed, bridged=true)`），但主上下文一直在跑（广播使能之后 `POLL0n` 行
  每几秒照常打印），`0x201098BC` 恒为 0——BT MAC 的中断没有拉起来，同一个错下标在那边不表现为风暴。修前修后在单独
  探针上各跑一轮（`logs/bt-probe-clock-union-boot.log`、`logs/bt-probe-bridge-index-boot.log`），日志逐段相同（只有计数值
  与串口交错不同）。那边的墙是另一处，根因未知。
- 同类的一处还开着：`bt-blobs` 与 `wifi-blobs` 的 `osi_impl.zig` 里 `_set_isr(n, f, arg)` 的实现把 blob 给的 `n` 原样交给
  `trap.setHandler`。那两处的注释原来写「`setHandler` 内部归一化」，并不属实，已改。blob 经这条路传的 `n` 是外部中断号
  还是 CLIC 输入号，没有核对过；合并镜像不依赖它（BT MAC 走 `intrArm` 的桥）。
- 工作站 ping 板子仍然没有应答（板子只发 ping 不回 ping，§15.8 的已知缺口），与共存无关。

## 18. L4b 第一组：按广播间隔量 ping 的时延与丢包，外加「核不启动」的对照（2026-11-27）

### 18.1 做法

合并镜像 `-Dcoex-merged -Dcoex-wifi-link -Dcoex-ble-enable -Dcoex-ble-adv`，只编合并这一段（`scripts/build-coex-link-image.sh`，
`ADV=1 BLE=1`，app.bin 1 238 960 字节）。这一轮给镜像加了两个构建参数：`-Dcoex-adv-interval-ms`（广播间隔，默认 100）与
`-Dcoex-adv-pings`（每遍 Wi-Fi 链路 ping 网关的帧数，默认 10；这三轮用 30）。每轮两遍 Wi-Fi 链路：第一遍 BLE 只 enable（对照），
第二遍 BLE 广播着。广播间隔 20 / 100 / 1000 ms 各一轮；另跑一轮对照，镜像与参数同 100 ms 那一轮，只多 `-Dcoex-sw-off=true`——
胶水按 IDF 关闭分支的桩值作答、核不启动（`coex[boot]: FAILED CoexDisabled rc=0x0 rejected=1`）。

每一轮三路取证：板子串口；AP 上临时 monitor 接口抓地址里有板子 MAC 的帧（路由器上自编的静态 tcpdump，
`tools/ap-side/collect.sh` 的 MON 模式），外加每秒一份站点统计；工作站上自编的 tcpdump 直接打印 HCI 监视流。

入库：`logs/coex-merged-wifi-link-ble-intvl{20,100,1000}-boot.log`（板侧，脱敏）、`…-ap-frames.log`（空口上的帧，脱敏）、
`…-ap-side.txt`（AP 一侧：站点统计、帧型计数、hostapd 的行）、`…-hci.txt`（板子地址的 HCI 上报与由它们重算的读数）；
对照轮是 `…-intvl100-swoff-boot.log` 与 `…-intvl100-swoff-ap-side.txt`。

### 18.2 读数

rtt 单位 ms，min / avg / max，取自板子的 `ping done` 行；p50、p90 是逐帧回显往返的分位数。每一遍都是 30 发 30 收、0 超时。

| 广播间隔 | 板子检查 | BLE 只 enable（对照） | BLE 广播着 | 空口上的广播间隔（工作站 HCI 流） | AP → 板子的帧：重传 / 失败 | 板子发的 QoS Null 帧每遍个数（相邻间隔的中位数） |
| --- | --- | --- | --- | --- | --- | --- |
| 20 ms | 31/31，`verdict=pass` | 1.6 / 4.8 / 18.9；p50 3.3，p90 9.0 | 27.2 / 54.9 / 103.5；p50 30.5，p90 96.7 | 62.2 秒 192 条上报，相邻 191 段里 188 段是 k×（20–30 ms）；同一次广播事件内的上报间隔 19.0–25.2 ms | 1 / 1；广播时 1 / 1 | 33（999.5 ms）→ 115（63.0 ms） |
| 100 ms | 31/31，`verdict=pass` | 1.7 / 4.1 / 11.0；p50 3.0，p90 9.0 | 27.3 / 45.3 / 107.7；p50 30.4，p90 92.4 | 61.7 秒 57 条，56 段里 55 段是 k×（100–110 ms） | 0 / 0；广播时 2 / 2 | 35（999.5 ms）→ 111（61.5 ms） |
| 1000 ms | 30 过 1 没过（下面「边界」） | 1.9 / 3.9 / 12.2；p50 2.4，p90 8.9 | 27.2 / 47.9 / 107.9；p50 30.4，p90 96.7 | 49.2 秒 6 条，5 段全部是 k×（1000–1010 ms） | 1 / 1；广播时 0 / 0 | 31（999.8 ms）→ 110（61.6 ms） |
| 100 ms，核不启动（对照） | 28 过 3 没过（都是「核在不在」那三条：两侧状态、`rej`、BLE 状态字） | 1.9 / 4.0 / 13.4 | 2.0 / 3.5 / 11.5 | 56.6 秒 35 条，最短间隔 100.0 ms | 2 / 2；广播时 3 / 3 | 31（998.5 ms）→ 31（1000.0 ms） |

空口上每一遍都是同一个样子（monitor 接口看到的）：板子 → AP 的数据帧 31 个（30 个回显请求加 1 个别的），AP → 板子 30 个，
没有一帧带重传标志；回显请求到应答在空口上相隔中位 0.71 ms、最大 12 ms 以内（四轮各 60 次，9–11 次超过 1 ms，核不启动的
那一轮也一样）。AP 一侧数到板子发来的帧：核在、BLE 只 enable 时 66–70 个，
核在、BLE 广播时 145–156 个；核不启动时两遍都是 66–74 个——多出来的就是那些 QoS Null 帧。

核的读数（这一轮新加的两处，见 18.4）：

| 判据 | 三个间隔的读数 |
| --- | --- |
| BLE 的状态位非 0（ADR-003 第 5 节 L4b 之二） | controller 经胶水告诉核的 BLE 状态字，广播起来之后是 `0x0001`，三个间隔都一样，一直保持到 15 秒收尾结束；Wi-Fi blob 的状态字连着的时候是 `0x0004`（扫描过程中置过 `0x0001`，扫完置回 0）。对照轮里核不受理这些调用，镜像里是 0 |
| 核的硬件定时器在走（之一） | 链路的每一泵步读 5 个定时器的使能字（每 2 ms 最多一次）：BLE 只 enable 那一遍 16 725–16 813 次，BLE 广播那一遍 12 779–13 118 次，三个间隔都是一次使能也没看到；对照轮两遍各约 18 000 次，同样 0 |

### 18.3 结论

- **三个间隔下 ping 都不丢**：每遍 30 发 30 收、0 超时，每遍都是探针自己断开的（`reason=8`）。ADR-003 为这一组定的判据
  「每轮都没有 `STA_DISCONNECTED`、ping 不丢」过了。
- **「广播间隔越短，ping rtt 的最大值越大」不成立**：三个间隔下广播那一遍的分布几乎一样——最小 27.2 ms、中位 30.4–30.5 ms、
  平均 45–55 ms、最大 104–108 ms。空口上的广播间隔确实分别是 20、100、1000 ms（HCI 流），所以不是间隔没改。
- **时延不来自空口**：回显请求到应答在空口上中位 0.71 ms、最大 12 ms 以内，板子发的帧没有一个带重传标志，AP → 板子的重传
  每遍 0–2 次，都与核不启动的那一轮相同。涨的 30–100 ms 在板子内部。
- **涨在共存路径上，不在「BLE 在广播」本身**：核不启动那一轮，BLE 照样在空口广播（35 条上报），广播那一遍的 rtt 与对照遍
  一样（平均 3.5 ms 对 4.0 ms）。核在的时候才有 27 ms 的下限。
- **核在、BLE 广播时，Wi-Fi 这一侧的空口行为变了**：板子发的 QoS Null 帧从每秒 1 个变成中位每 62 ms 一个（每遍 31–35 个
  → 110–115 个），AP 一侧数到板子发来的帧 150 个上下，平时 66–74 个。它与广播间隔无关——核看到的只是「BLE 在广播」这个状态字。
  回显往返的中位数 30 ms 约是 QoS Null 间隔的一半。[INFERENCE] 机制没有核对：像是 Wi-Fi 被共存核反复切进省电、靠 QoS Null
  轮询才拿到回显。
- **「核真的在仲裁」的两条判据过了一条**：BLE 的状态位非 0 有了直接读数；硬件定时器在走没有过的（约 3 万次采样里 0 次）。
  对照轮说明核在不在会改变 Wi-Fi 的行为，所以核确实参与了调度；但按 ADR-003 的写法两条都要，现在仍然只算「两个射频同时开着」
  加一条「核在改变 Wi-Fi 的行为」。

### 18.4 两处读法的更正

- **`coex_status_get(bitmap)` 不是读状态字。** 反汇编（`components/radio-coex/src/fake.zig` 里照着写的模型）：bitmap 之外还有
  别的状态字非零时才回核的状态（`coex_core_status_get()`），否则回 0。§17.5 表里「三组状态位」的读数 0/1/1、1/0/1、1/1/1
  （按 wifi / ble / bt 的查询顺序）正好对得上：Wi-Fi 连着时查 ble、bt 各看到对方非零；BLE 广播时查 wifi、bt 看到 BLE 非零；
  两个都在时三个查询都是 1。「对不上名字」是因为把它当成了读字。现在读数行里多一行 `status words:`，直接给出三个字
  （见 `components/radio-coex/src/glue.zig` 的 `bt_status_words` 与 `wifi-blobs/src/init_probe.zig` 的 `CoexTraceStats.set_last`）。
- **硬件定时器在阶段边界上读不到「在走」。** 核只在处理申请 / 释放的那一会儿使能定时器，§17.5 里每个时点隔 1 ms 读两次的
  是不是它活动的时刻。现在在链路的每一泵步采一次（`firmware/src/coex_merged.zig` 的 `sampleHwTimers`），看的是使能位。读了两遍
  链路、约 3 万次，都是 0——这个读数下这条判据不过，原因见「边界」。

### 18.5 边界

- 时延涨在哪一段没有分开（发出去之前在等，还是收到之后处理晚）；QoS Null 帧变多与 rtt 的关系是时间上的对应，不是核对过的因果。
- 「硬件定时器在走」没过的可能原因：核只给事件表里配了定时器的事件用定时器（`init_probe.zig` 的 `CoexTraceStats` 注释），
  ping 这种每秒一帧的流量不触发；Wi-Fi 有吞吐的时候没量。
- 1000 ms 那一轮 `verdict=fail`：没过的是「BLE init 之后的扫描不低于基线的一半」（8 对 19），与 §17.5 的 `ble-adv10` 同一种
  环境波动（同一天里健康读数在 13–37 个 AP 之间跳），与广播间隔无关；那一轮其余 30 条都过，两遍链路都连上、DHCP、30/30。
- 每个间隔只跑了一轮，每遍 30 帧。PTI 行为、两侧的 start 回调没有做；广播仍是不可连接的。
- 合并镜像带 `-Dcoex-ble-adv` 时判据从 27 条变成 31 条（多了两条定时器采样、两条 BLE 状态字）；不带它的镜像条数不变。
- `tools/ap-side/collect.sh` 的 MON 模式在仓库这一版里一直建不起 monitor 接口（把 wiphy 名字拼成了 `phy0-ap0`），这一轮修了；
  之前的 MON 轮次跑的是 `/tmp` 里另一份写死 `phy0` 的脚本。

## 19. L4b 第二组与路线图 C8：持续的 Wi-Fi 流量、启动回调、PTI、硬件定时器的读法更正、LE Set Host Channel Classification（2026-11-27）

### 19.1 做法

镜像同 §18（`ADV=1 BLE=1`，广播间隔 100 ms），这一轮多了三样：

- **持续的 Wi-Fi 流量**：`-Dcoex-adv-ping-interval-ms=50 -Dcoex-adv-pings=300`——每遍 Wi-Fi 链路 ping 300 帧、间隔 50 ms
  （§18 是 10 帧、1 秒）。同一时间只有一帧在飞：间隔比 1 秒的应答超时短，就是上一帧一回来就发下一帧，实测每遍 15.0–15.9 秒。
  载荷由 `-Dcoex-adv-ping-bytes` 给（默认 32，至多 1472）。每遍链路打一行 `coex-ping[…]`：发了几帧、收到几帧、超时几帧、
  往返时延的最小 / 平均 / 最大。
- **`coexReadings` 多三行**（`wifi-blobs/src/init_probe.zig`）：`start callbacks:`——核触发两个「都开了共存」入口各多少次
  （胶水的两个跳板，`radio-coex/src/glue.zig`）；`pti by value:`——每个事件的 PTI 按值计数（此前只记按位或）；
  `timers in calls:`——在 `_coex_wifi_request` 被核接受之后、在 `_coex_wifi_release` 交给核之前直接读定时器的寄存器。
- **信道分类**（`-Dcoex-ble-chan-class`，路线图 C8）：BLE 广播起来之后、第二遍 Wi-Fi 链路之前，经发送任务发 LE Set Host Channel
  Classification（`0x2014`），参数是 `ble-802154/src/channel_class.zig` 按 AP 的主信道算的图（主信道取自第一遍链路的
  `WIFI_EVENT_STA_CONNECTED`，`wifi-blobs/src/link_probe.zig` 的 `LinkResult.ap_channel`）；第二遍链路之后再把同一张图的保留位置上发一次。

每轮两遍 Wi-Fi 链路：第一遍 BLE 只 enable（对照），第二遍 BLE 广播着。只取了板侧串口（没有 AP 侧与 HCI 流的采集），经
`tools/ap-side/redact.py` 脱敏。这一轮上板十次，镜像之间只差读法：

| 轮 | 与上一行的差别 | app.bin | 板子检查 | 日志 |
| --- | --- | --- | --- | --- |
| A | 300 帧 × 50 ms、载荷 32 字节；有 `start callbacks:` 与 `pti by value:`，没有 `timers in calls:` | 1 244 864 B | 31/31，`verdict=pass` | `logs/coex-merged-wifi-link-ble-intvl100-ping50ms300-boot.log` |
| B | 加信道分类与 `timers in calls:`（使能位还读的是 bit1，§19.4） | 1 258 320 B | 33/33，`verdict=pass` | 不入库 |
| C | 同 B，载荷 1400 字节 | 1 258 384 B | 33/33，`verdict=pass` | `…-intvl100-ping50ms300-1400b-chanclass-boot.log` |
| D | 定时器的地址与使能位改正（§19.4） | 1 259 088 B | 33/33，`verdict=pass` | 不入库 |
| E | 再加「接受申请到释放」的时长与核装进定时器的 tick 数 | 1 260 352 B | 33/33，`verdict=pass` | 不入库 |
| F | 再把状态字的两个位分开计数、泵步里也读状态字、多两条判据 | 1 262 240 B | **崩溃**：一次抓取里连崩四次，每次 lockup 复位后再跑一遍都停在第一条 `0x2014` 之后（§19.5） | `…-intvl100-ping50ms300-lockup-boot.log` |
| G | 回到 E 的读法，每个阶段多打一行栈指针 | 1 261 152 B | 33/33，`verdict=pass` | 不入库 |
| H | 读数函数的栈帧从 42 KB 降到 864 B（§19.5），多一条主栈高水位的读数与两条判据；AP 的主信道改取 `WIFI_EVENT_STA_CONNECTED`，信道分类那一步去掉了 `catch unreachable`、带保留位的图按「不回 0x00」判 | 1 259 232 B | 35/35，`verdict=pass` | `…-intvl100-ping50ms300-final-boot.log` |

入库 A、C、H 与 F 的崩溃日志；B、D、E、G 是读法迭代中的四轮，读数与 H 相同。**A–G 的每一轮里读数函数都在溢出主栈**
（§19.5）：这些轮次的读数本身是量出来的，但板子读数的那一阵子处在被踩坏内存的状态下，所以结论以 H 为准，与 H 一致的才写进下文。

判据条数：带 `-Dcoex-ble-adv` 的镜像是 33 条（§18 的 31 条加两条「主栈没碰到栈底」），再加 `-Dcoex-ble-chan-class` 是 35 条。

### 19.2 读数

**ping**（rtt 单位 ms，最小 / 平均 / 最大；每一遍都是 300 发 300 收、0 超时，断开都是探针自己做的）：

| 轮 | 载荷 | BLE 只 enable（对照） | BLE 广播着 | ping 段的时长（对照遍 / 广播遍） |
| --- | --- | --- | --- | --- |
| A | 32 B | 1.2 / 3.3 / 37.7 | 2.2 / 28.9 / 134.0 | 15.0 s / 15.9 s |
| B | 32 B | 1.0 / 2.9 / 22.2 | 2.8 / 27.1 / 102.1 | 15.0 s / 15.6 s |
| C | 1400 B | 1.7 / 3.2 / 16.2 | 3.0 / 28.0 / 137.2 | 15.0 s / 15.6 s |
| H | 32 B | 1.1 / 2.4 / 12.2 | 1.3 / 26.9 / 141.3 | 15.0 s / 15.5 s |

H 的两遍都带着信道分类（广播起来之后图 `00 f8 ff ff 1f` 就一直有效）。与不带它的 A 比，广播那一遍的 rtt 在同一个范围里：
**分类对 ping 没有看得出的影响**（各只跑了一轮）。载荷从 32 字节加到 1400 字节（C）：同样不丢，时延同一个范围。

**核的读数**（H；A、C、E 相同）：

| 判据 / 读数 | 结果 |
| --- | --- |
| 两侧的 start 回调被触发（ADR-003 第 5 节 L4b） | `after-start` 时 `wifi n=0 ble n=0`；BLE enable 把核的使能计数升到 2，从这一刻起 `wifi n=1 ble n=1`，到收尾不再变。与反汇编一致：`coex_core_enable` 在计数升到 2 时先调 `_coex_register_start_cb` 登记的函数、再调 `coex_register_ble_cb` 登记在 type 0 下的函数（`components/radio-coex/README.md` 的「假核心依据」） |
| PTI 行为 | 每个事件一个定值，整轮不变、BLE 广播前后也一样：e0 = 10、e1 = 5、e3 = 7、e9 = 7、e10 = 3，e5 / e6 / e7 / e12 / e15 = 1。PTI 是事件的优先级（`esp_coexist_internal.h` 的 `coex_pti_get`）；此前按位或记下的 `0x05`、`0x07`、`0x0a` 就是这些值本身。变的是 blob 问的次数（下一行） |
| blob 向核要什么 | 对照遍（BLE 只 enable）300 帧 ping 期间一次申请都没有：e12 的 PTI 查询 +300、e1 的 +320 上下，仅此而已。广播那一遍每一帧都带出一串：e1 申请 259–266 次，核都收下（时长 51 180 µs 上下 209 次、119 990 µs 上下 45 次、100 ms 与 33 000–40 000 µs 各 5 次）；e9 申请 310–319 次、e0 申请 205–210 次——这两个事件核里没有配定时器，回 `0x102`；PTI 查询 e0 +209、e1 +643、e9 +313、e12 +300（H）。载荷从 32 字节加到 1400 字节这些数不变（C：265 / 319 / 210；H：262 / 313 / 206） |

**硬件定时器**（H；D、E、G 相同）：

| 在哪儿读 | 读到什么 |
| --- | --- |
| 泵步之间采使能字（`firmware/src/coex_merged.zig` 的 `sampleHwTimers`） | 每遍一万次上下（10 719 与 7 285 次），一次使能位也没看到 |
| 核接受申请之后（`timers in calls:` 与头三行原始字） | 事件 1 的申请核收下 263 次（广播那一遍 262 次），每次都把定时器 0 重新装过：w0 = `0x150066ae`（时长 32 858 µs → 低 24 位 26 286）、`0x150176f4`（119 985 µs → 95 988）、`0x150176ee`（119 978 µs → 95 982）——低 24 位 = 时长 × 0.8，即 1.25 µs 一个 tick；w1 = 0。状态字读回 `0x00000002`（bit1 置着、bit0 清着）；使能字的 bit0（`coex_hw_timer_enable` 置的就是它）读回 0 |
| 释放之前 | 使能字的 bit0 与状态字的 bit0 都是 0；从接受申请到释放 207 段：最短 5.0 ms、平均 59 ms、最长 2.4 秒（对照遍连接时的那一次） |
| 阶段边界（`readHwTimers`） | 定时器 0 的 w0 每个阶段都不一样（`0x150066ae` → `0x150176ef` → `0x15009ff1` → `0x15007ce9`），是最近一次申请的时长；定时器 1–4 没被用过（全 0）；`en`、`st` 在边界上都是 0 |

### 19.3 信道分类

| 命令 | 参数 | controller 的回答 |
| --- | --- | --- |
| LE Set Host Channel Classification | AP 在 2.4 GHz 信道 1（2412 MHz）：盖住数据信道 0–10，图 `00 f8 ff ff 1f`，37 个里 26 个 unknown | Command Complete，Status `0x00` |
| 同一条，保留位置上 | `00 f8 ff ff 9f`（第 5 个字节的 bit7） | Command Complete，Status `0x12`（Invalid HCI Command Parameters） |

B、C、E、G、H 五轮都是这两行；回包都是「0 ms、0 轮泵」到的；两条之间隔了第二遍 Wi-Fi 链路（远超 §7.8.19 的 1 秒）。发完之后
BLE 一直在广播：合成器锁定位与 controller 置给核的 BLE 状态字 `0x0001` 保持到 15 秒收尾。

判据写的是「带保留位的图不回 `0x00`」：§7.8.19 只说最高几位保留，没有规定拒绝时的错误码；`0x12` 是 NimBLE 的取法
（`ble_ll_hci.c:859-862`），也是这次实测到的值。AP 不在 2.4 GHz 的 1..14 信道上、或者第一遍没连上时算不出图，这一步跳过、不打判据。

### 19.4 定时器读法的更正

§13 里「定时器在 `0x2010F040 + 16*idx`（配置与比较值）与 `0x2010F408 + 16*idx`（使能位是 bit1）」两处都错了：§17–§18 的 `hw timer`
行与 §18.4 的「约 3 万次采样里 0 次」都读错了地方。重看 `coexist_hw.o`：

| 函数 | 做了什么 |
| --- | --- |
| `coex_hw_timer_set(idx, …)` | 基址 `lui 0x2011`、`addi -192` = `0x02010F40`，加 idx 再左移 4 位 → `0x2010F400 + 16*idx`：`+0` 写入两个 4 位参数与低 24 位的 tick 数，`+4` 写低 24 位 |
| `coex_hw_timer_enable(idx)` | 清 `0x2010F40C + 16*idx` 的 bit0，置 `0x2010F408 + 16*idx` 的 **bit0**（`ori …,1`） |
| `coex_hw_timer_disable(idx)` | 清使能字的 bit0，往 `0x2010F40C + 16*idx` 的 bit0 写 1 |
| `coex_core_request` | 按事件号查 `coex_core_timer_idx_get`，回 255 就回 `0x102`；否则取事件表里这个事件的参数字节，`coex_hw_timer_set(idx, …)` 再 `coex_hw_timer_enable(idx)`，回 0（反汇编里事件号是它的第二个参数，第一个是原样转给 `coex_hw_timer_set` 的一个字节） |
| `coex_core_release(event)` | 同一张表；有定时器就 `coex_hw_timer_disable(idx)`，回 0 |

所以每个定时器 16 个字节，在 `0x2010F400 + 16*idx`；此前读的 `0x2010F040 + 16*idx` 是 `MODEM_LPCON` 的寄存器（§13.2 表里
`0x2010F044` 是 `DCMEM_VALID_2`），使能位看的是 bit1。核每接受一次事件 1 的申请都走 `set` + `enable`：定时器 0 被装成申请的
时长（1.25 µs 一个 tick），状态字的 bit1 置着。使能字的 bit0 为什么读回来是 0、状态字两个位各是什么含义、定时器有没有真的在数
（没有可读的计数器），都没有弄清。

ADR-003 第 5 节写的判据是「硬件定时器的数值在两次读数之间变了（读 `coex_hw_timer_set` 写的那组寄存器）」：按改正后的地址，
定时器 0 的 w0 在各阶段之间都变了，这条**按字面过了**；「在走」本身仍然只有「核按申请把它装好并置了状态位」这一步的证据。

### 19.5 崩溃与主栈溢出

**现象（F）。** 一次抓取里连崩四次（上电一次，之后四次 `CPU_LOCKUP_RESET`，每次复位后再跑一遍），每次都在同一步：三条广播命令都回了 `0x00`、`coexReadings("ble-adv")` 打完、
`bt adv: send 0x2014` 之后。故障转储：`PCAddr: 0x30303030`（ASCII「0000」）、`Cause: 1`（取指访问错误）、`f_sp=0x2f06f920`；
故障栈上那段是 `…0000\n\0 st0_after=0x00; rel=4 en_before=0 …`——读数行的尾巴压在一帧保存的上下文上。`0x2f06f920` 落在 BLE
发送任务的栈里（同一份日志：`bt sched: 任务体开始 sp=0x2f06f9f0 ctx.sp=0x2f06fa60`），发 `0x2014` 时调度器从那里恢复发送任务，
`ra` 读出来是「0000」。

**根因。** 不是读数本身，是读数函数的栈帧。`coexReadings` 里 `const t = coex_trace_stats;` 与三个 `for (t.ev, 0..) |e, i|` 都按值
拷贝整个统计结构：每个事件加进 `pti_hist`（16 个 `u32`）之后这个结构是 10 KB，四份就是 42 KB。带符号表构建的反汇编里它的序言是
`addi sp,sp,-256` 之后紧跟 `lui a2,0xa; addi a2,a2,688; sub sp,sp,a2`——栈帧 41 904 字节，G 的栈指针读数对得上（`run()` 里是
`0x2f07a4a0`，进 `coexReadings` 就是 `0x2f0701e0`）。主栈只有 16 KiB（`s31.ld` 的 `_stack_size`，底 = `_heap_end` = `0x2f076fc0`），
每次读数都把它溢出 26 KB 进 BLE 堆；F 的栈帧再多 768 字节、释放包装里又多一层日志，正好压到发送任务保存的那一帧。A–G 每一轮
都在溢出，只是没压到致命的字节。

**修法。** 统计结构改成按指针读（`const t = &coex_trace_stats;`、`for (t.ev[0..], 0..) |*e, i|`），栈帧 864 字节；合并 section 开头
把主栈的空闲部分涂上图案，两处判「栈没碰到栈底」（`checkMainStack`），每个阶段与关键步各打一行栈指针与高水位
（`coex[…]​: sp=`、`coex-merged: sp[…]`）。H 的读数：读数函数在主栈里（`run()` 是 `0x2f07a490`，`coexReadings` 是 `0x2f07a230` /
`0x2f079fc0`）；主栈的空闲部分 13 520 字节，整段里最深用到 1 688 字节，离栈底还有 11 832 字节——16 KiB 够用，不需要加。
涂色的第一版用 `@memset`，被 ReleaseSmall 当成死存储整个消掉（反汇编里只剩长度的计算），那一轮读数恒为「0 B left」、两条判据
误报；改成 volatile 逐字节写之后才是上面的数。带符号表的构建里扫过一遍：其余函数没有 ≥ 2 KB 的栈帧。

**边界。** 主栈溢出为什么在 A–E 里没有表现出别的异常，没有查（被踩的是 BLE 堆里一段 26 KB 的区间）；在修掉之前入库的
`coex[…]` 读数行本身仍然有效（它们是从寄存器与计数器里读出来的，不依赖那段栈）。

### 19.6 结论

- 持续的 Wi-Fi 流量（每秒 20 帧、每遍 15 秒）下 ping 不丢：对照遍与广播遍都是 300/300，载荷 32 与 1400 字节都是。广播时 rtt
  的形状与 §18 一样（下限 1–3 ms、平均 26–29 ms、最大 76–142 ms）。
- ADR-003 第 5 节 L4b 剩下的三条判据都有了读数：两侧的 start 回调各触发一次（BLE enable 时）；PTI 是每个事件的定值，与 BLE
  是否在广播无关；核每接受一次事件 1 的申请就把定时器 0 装成申请的时长并置状态位——「数值在两次读数之间变了」按字面过了。
- 路线图 C8：主机侧 5 条用例；板上 controller 收下合规的图（`0x00`）、拒掉带保留位的图（`0x12`）。图有没有被用上看不出来
  （只有不可连接广播）。
- 读数函数曾把主栈溢出 26 KB：已修，加了高水位的判据。§17–§18 里定时器的读数作废（读错了地址与位），其余读数不受影响。
- 没有做的：AP 侧与空口采集这一轮没做；时延涨在哪一段；可连接广播（定时器是否在数、信道分类有没有被用，都要连接才有数据
  信道）；每个配置只跑了一轮。

## 20. 路线图 C9：收尾的六项（2026-11-27 晚）

路线图 C9 列的六件事：其余钩子的计数桩与 IDF 关闭分支的逐项对照、BLE 的 disable 路径、「BLE 先起」的顺序、板子回别人的 ping、
分区表扩大、compiler_rt 死重。镜像仍然只编 `coex_merged`（`scripts/build-coex-link-image.sh`），每一轮只改一个开关。日志经
`tools/ap-side/redact.py` 脱敏；停机现场的原始转储（栈与通用寄存器）换成 `[REDACTED]`，`mepc` / `mtval` / `cause` 行保留。

### 20.1 做法

三个新开关（都要求 `-Dcoex-wifi-link`；不给就是原来的行为，默认镜像与其余日志不变）：

| 开关 | 作用 | 落点 |
| --- | --- | --- |
| `-Dcoex-ping-in-ms=<n>` | 每一遍 Wi-Fi 链路 ping 网关之后留 n 毫秒，等外面的主机来 ping 板子 | `wifi-blobs/src/link_probe.zig`（`inboundPingWindow`）、`data_path.zig`（`handleEchoRequest`） |
| `-Dcoex-ble-first=phy_ble` / `phy_deferred` / `phy_wifi_first` | 起手顺序反过来：BLE 先 `bringup.init`，Wi-Fi 再 `esp_wifi_start`；三种差在 PHY 的一次性初始化与标定由谁、在什么时候做 | `firmware/src/coex_merged.zig`、`wifi-blobs/src/init_probe.zig`（`phyEnableWifiOwned`） |
| `-Dcoex-ble-disable` | 所有判据之后按 IDF `bt_controller_disable` 的顺序关 BLE，每一步之后扫一次全信道，最后让 Wi-Fi 再走一遍链路（要求 `-Dcoex-ble-enable`） | `bt-blobs/src/probe.zig`（`downBegin` / `downStep` / `downEnd`）、`porting.zig`（`btdmLpDisableClock`、`btdmCoexDisable`）、`coex_merged.zig`（`bleDownStep`） |

另有两处不挂开关的改动：不开 `-Dcoex` 时计数桩按 IDF 的关闭分支作答（§20.5）；`radio-coex/src/owner.zig` 的 `clocks` 多了
`only()`（只属于一个模块的位）与逐字的取与 / 取反 / 判空，供下电路径判「BLE 自己的单元关了、别人的还开着」。

### 20.2 板子回别人的 ping

**实现**（`wifi-blobs/src/data_path.zig`）。此前数据通路只认本机发出去的回显的应答，别人发来的回显请求一律丢掉——工作站
ping 板子没有应答。现在 `handleFrame` 把 ICMP 按 type 分开：type 8 交给 `handleEchoRequest`。

- 只答发给本机当前地址的请求（这一条原来就卡着），所以广播的请求不答——RFC 1122 §3.2.2.6 允许不答，本工程的取舍写在
  `icmp.mayReply`；没拿到租约时不答。
- `code` 不是 0、校验和不对的请求丢掉（RFC 1122 §3.2.2）。
- 应答用 `icmp.echoReplyFrom`：id、序号、载荷一字不改，只把 type 改成 0、重算校验和（RFC 792 的 Echo Reply）。以太网目的地址取
  请求帧的源地址——跨网段来的请求，回给它的下一跳。IP 包正好 1500 字节（载荷 1472）的请求答得出来。
- 每答一帧一个事件（日志 `ping answered id=… seq=… from …`），统计里多两项：`echo_requests`、`echo_replies`。

主机用例（`data_path.zig`）：应答帧逐层对得上（以太网、IP、ICMP 的 type / code / id / 序号 / 载荷 / 校验和），载荷取到上限；
坏校验和、code 不是 0、发给别的地址、租约到期之后都不答，也不计进统计。

**板上。** 在 §19 的最终配置上再加 `-Dcoex-ping-in-ms=8000`（1 261 024 B）。板侧判据两条，每遍链路一条：这一遍里至少答过一帧。
工作站那边在烧录之后起 `ping -n -c 1000 -i 0.2 -W 1 192.168.31.151`（板子从 AP 的 DHCP 拿到的还是这个地址）。

| 遍 | BLE 的状态 | 扫到的 AP | ping 网关 | 板子答了几帧 | 其中窗口开始前 | 工作站收到的应答 |
| --- | --- | --- | --- | --- | --- | --- |
| 第一遍 | enable，不广播 | 30 | 300/300，rtt 最小 / 平均 / 最大 1.7 / 3.5 / 23.2 ms | 97 | 71 | 97（`icmp_seq` 31–127） |
| 第二遍 | 广播中 | 35 | 300/300，1.9 / 40.9 / 93.6 ms | 118 | 91 | 118（`icmp_seq` 193–310） |

板侧 37/37（§19 的 35 条加两条），`verdict=pass`，一次复位。工作站共 215 个应答，与板侧 97 + 118 逐遍对得上；应答时间最小
1.29 ms、中位 38.1 ms、九成在 146 ms 以内、最大 450 ms。

两点说明。其一，板子只要拿到了地址就答，不是只在窗口里答：窗口开在 ping 网关那一段之后，开的时候 71 帧已经答过了，
所以「答够 4 帧」立刻成立、窗口 0 ms 就结束（`inbound ping window: answered 71 of 4 wanted in 0 ms`）。窗口开关留着，是为了给
「外面来 ping」保一段确定的时间，不让链路在 ping 网关之后马上断。其二，工作站的 `ping` 没有打出汇总行：板子第二遍断开之后
邻居表项失效，`sendmsg` 回 `No route to host`，进程就退了；数取自逐行的 `bytes from`。

日志 `logs/coex-merged-c9-pingin-boot.log`。

### 20.3 「BLE 先起」的顺序：三个单变量对照

§15 的结论是「Wi-Fi 先 start，BLE 的 init 跳过 PHY 那两段」，并记着两种反例都让 Wi-Fi 收不到帧。那时时钟域还是整字覆盖
（§16 之前），BLE 先 init 也会把 Wi-Fi 的时钟位清掉，「收不到帧」的两个可能原因没有分开。这一轮在最终的镜像上把顺序当成
唯一的变量，三种各一轮（镜像只差 `-Dcoex-ble-first` 的取值）：

| 取值 | PHY 的一次性初始化与标定 | 结果 | app.bin | 日志 |
| --- | --- | --- | --- | --- |
| `phy_ble` | BLE 的 init 做（不调 `setPhyOwnedByWifi`，与 §15 的反例相同） | 时钟位都在（Wi-Fi start 之后 `CLK_CONF1=0x003FFFFF`），但 Wi-Fi **收不到**：BLE init 之后的扫描只有 4 个 AP，两次连接都以 `reason=201` / `reason=4` 失败，6 条判据不过（26/32） | 1 260 848 B | `logs/coex-merged-c9-blefirst-phyble-boot.log` |
| `phy_deferred` | BLE 的 init 跳过，等 Wi-Fi start 时做 | BLE 的 init **停机**：第 7 步 `btdm_lp_init` 里 load access fault（`exception code=5`，`mepc=0x2f824c72`、`mtval=0x193`），这一轮没有走到 Wi-Fi start | 1 261 152 B | `logs/coex-merged-c9-blefirst-phydeferred-boot.log` |
| `phy_wifi_first` | BLE 的 init 之前先按 Wi-Fi 的路径打开（`phyEnableWifiOwned`），BLE 的 init 跳过 | **都正常**：标定数据 264 个非零字节；BLE init 返回 0；之后的扫描 32 个 AP；两遍链路都连上、DHCP、ping 300/300；36/36，`verdict=pass` | 1 261 424 B | `logs/coex-merged-c9-blefirst-phywififirst-boot.log` |

结论分三层：

- **不能反的是「谁打开 PHY」，不是 controller 的先后。** PHY 由 BLE 的 init 打开时，Wi-Fi 之后的扫描从三十多个 AP 掉到 4 个
  ——时钟位全在（三个时点的并集核对都过），所以这不是时钟的问题，是标定：Wi-Fi start 时 `register_chipv7_phy` 什么都不做
  （§15.2）。§15 把「收不到帧」归到时钟覆盖上的可能性排除。
- **controller 的 init 要在 PHY 开着的时候做。** `phy_deferred` 里 BLE 的 init 在 PHY 没开时走到第 7 步就停机。IDF 自己是把
  `esp_phy_enable(PHY_MODEM_BT)` 放在 enable 里的（`btdm_lp.c:255`、`:446`），init 不碰 PHY；我们这一版的 init 在 PHY 没开时
  为什么在第 7 步取空指针，没有往下查 [INFERENCE：`porting.btdmLpInit` 里那几个 `r_btdm_hal_*` 用到了 PHY 初始化才置的指针]。
- **所以支持的第二种顺序是**：先按 Wi-Fi 的路径把 PHY 打开并标定，再做 BLE 的 init（和 enable），最后 Wi-Fi `esp_wifi_start`。
  `phyEnableWifiOwned` 照 blob 在 `esp_wifi_start` 里的前两步做——先 `_wifi_clock_enable`，再 `_phy_enable`。第一版只调了
  `_phy_enable`，`register_chipv7_phy` 直接停住（抓了 200 秒，停在 `trace icg_write` 之后）：校准期间要 Wi-Fi 的基带时钟。
  start 之后再调这两个钩子是幂等的（时钟位重申；`shellPhyEnable` 见 modem 已经开着回 0）。这一种顺序下的读数与默认顺序
  同一个量级：两遍 ping 的 rtt 平均 3.5 ms / 29.1 ms（§19 与本轮默认顺序的两遍分别是 2.4–3.5 ms 与 26–41 ms），合成器约
  16 ms 锁定，信道分类照常收下、照常拒掉带保留位的图。

合并镜像的默认顺序不变（Wi-Fi 先起）。`phy_wifi_first` 留作开关：应用要先起 BLE 时，PHY 这一步必须由 Wi-Fi 的路径先做。

### 20.4 BLE 的下电路径

**做法。** 照 IDF `bt_controller_disable`（`components/bt/controller/esp32s31/bt.c:124-145`）把 enable 的每一步倒回去，拆成八步
（`bt-blobs/src/probe.zig` 的 `DownStep`）：`r_btdm_task_disable`、`r_btdm_hci_fc_disable`、`r_conn_stack_disable`、
`r_base_stack_disable`（本仓用这两个替 IDF 的 `ble_stack_disable`）、`btdm_coex_disable`（共存核的使能计数里属于 BLE 的那一次减一）、
`esp_btbb_disable`、`esp_phy_disable`（modem 2；本仓的 `btdmLpReset` 是空的，enable 时显式做了反过来的两件）、`btdm_lp_disable_clock`
（IDF 放在 deinit 里，bt.c:112；本仓是 `porting.btdmLpDisableClock`：只清**只属于 BLE** 的门控位——`CLK_CONF1` bit16-18、`CLK_CONF`
的 ETM 与 modem 安全模块、BLE 定时器、`LPCON` 的 LP 定时器时钟——与 Wi-Fi、PHY 共用的位不动，时钟源写回 BLE 来之前的读数）。
第 1 到 4 步是 controller 库里的函数：主上下文等的时候由 `osiOnIdle` 把 controller 任务泵起来（只在这条路径上开），每一步最多等
3 秒。镜像 `BLE=1` 加 `-Dcoex-ble-disable`：第一遍 Wi-Fi 链路之后下电，核对时钟字，再让 Wi-Fi 走一遍链路（泵里不再有 BLE）。
IDF 的 deinit 里剩下的几件（传输层、任务、内存池、日志）不做。

判据七条：每一步都在 3 秒内返回；下电后 Wi-Fi 与 PHY 依赖的时钟位一个不少；只属于 BLE 的位都关了（例外：`LPCON` bit1 共存时钟
归共存核，核还在替 Wi-Fi 做仲裁，`coex[ble-down]` 里 `en=1`）；时钟源回到 BLE 来之前的读数；下电后的扫描不低于基线的一半；
连接与 DHCP；ping 跑完。

**三轮，差别只在八步之间隔了什么**（开关：`-Dcoex-ble-down-scan` 默认每一步之后扫一次；`false` 是连着做，再加
`-Dcoex-ble-down-gap=<ms>` 就是每一步之后让 Wi-Fi 空转）。

| 轮 | 八步之间 | 每一步用时（µs） | 之后的扫描 | 板子检查 | 日志 |
| --- | --- | --- | --- | --- | --- |
| A | 每一步之后扫一次全信道（约 2.5 秒） | 1006 / 23 / 16 / 61 / 285 / 20 / 28 / 147 | 每一步之后 31–37 个 AP（基线 40）；最后一遍链路 32 个 AP、连上、DHCP 59 ms、ping 10/10 | **28/28**，`verdict=pass` | `logs/coex-merged-c9-bledown-stepwise-boot.log` |
| B | 什么都不隔，约 1.4 ms 里连着做完 | 1049 / 13 / 7 / 43 / 187 / 11 / 17 / 87 | 之后 36 秒里连着扫 15 次，**每次 0 个 AP**（基线 31）；连接 `reason=201` | 25/28，`verdict=fail`（不过的三条：扫描、连接、ping） | `logs/coex-merged-c9-bledown-backtoback-boot.log` |
| C | 每一步之后让 Wi-Fi 空转 2.5 秒（不扫描） | 988 / 21 / 7 / 50 / 249 / 11 / 17 / 108 | 之后 12 秒里 4 次：35、33、35、39 个 AP（基线 35）；最后一遍链路 34 个 AP、连上、DHCP 51 ms、ping 10/10 | **28/28**，`verdict=pass` | `logs/coex-merged-c9-bledown-paced-boot.log` |

**时钟这一半（路线图 C9 写的就是这一半）成立**，三轮读数相同：下电后 `CLK_CONF=0x00201002`、`CLK_CONF1=0x0038FFFF`、时钟源
`0x25`，与 BLE 来之前（Wi-Fi start 之后）的读数只差强开位与 `CLK_CONF1` 多出来的两位（bit8、bit15，多开无害）；只属于 BLE 的位
下电前是 `CLK_CONF1=0x00070000`、`CLK_CONF=0x7E400000`、`LPCON=0x8`，下电后都是 0；Wi-Fi 与 PHY 依赖的位一个不少。
第一次上板（步骤还没有拆开，每一步之后没有扫描）也是 25/28，时钟三条都过、扫描 0 个 AP，与 B 一致。

**controller 那一半有条前提：八步之间要留时间。** 连着做之后 Wi-Fi 就收不到帧，36 秒里不恢复，两次上板一样；每一步之后空转
2.5 秒（C）或扫一次（A）都正常——所以起作用的不是「Wi-Fi 在收发」，是时间。IDF 里这几个函数在任务上下文里调，前后自然有时间；
本仓的调用几十微秒到 1 毫秒就返回了 [INFERENCE：controller 的关闭有异步的部分，后面的步骤或 Wi-Fi 抢在它前面]。最少要隔多久、
隔在哪几步之间、等的是什么（controller 任务、定时器，还是射频的切换），这一轮没有定；两个开关留着，下一步按步二分。

判据里「只属于 BLE 的位」一开始把 `LPCON` bit1 也算了进去，A 里它还开着（`0x7`）、判成不过：共存时钟归共存核，核还在替 Wi-Fi
做仲裁，这一位不该关，判据已改；B、C 里它自己回到了关（`0x5`）。

回归里顺手抓到一处：连接失败的那一遍把上一遍的 `dhcp=true ping=true stayed=true` 报了出去（`link_probe.zig` 的 `connectPhase()`
没有清结果的标志），已修。A、B 的日志是修之前抓的：B 的 `result` 行与判据行里 `dhcp=1` 是上一遍的旧值（判据用的是 `connected`，
结论不受影响）。

### 20.5 计数桩与 IDF 关闭分支的逐项对照

§13 挂账的「其余钩子没有逐项核」。不开 `-Dcoex` 的镜像里 blob 调到的是 `wifi-blobs/src/osi_impl.zig` 的计数桩；对照的依据是
IDF `esp_wifi/esp32s31/esp_adapter.c` 里 23 个包装函数在 `#if` 不成立时的 `#else`（表在 796-822 行）。

| osi 表项 | IDF 的包装（`esp_adapter.c`） | 关闭分支 | 此前 | 现在 |
| --- | --- | --- | --- | --- |
| `_coex_init` | `coex_init_wrapper`，435-442 | 回 0，不调核 | 调 `libcoexist.a` 的 `coex_init()`，回 0 | 回 0，不调核 |
| `_coex_enable` | `coex_enable_wrapper`，451-458 | 回 0，不调核 | 调核的 `coex_enable()`，回 0 | 回 0，不调核 |
| `_coex_schm_flexible_period_get` | `coex_schm_flexible_period_get_wrapper`，607-614（只看功耗管理） | 回 **1** | 落在具名桩上，回 0 | 单独的壳，回 1 |
| `_coex_pti_get` | `coex_pti_get_wrapper`，512-519 | 回 0，不写出参 | 2026-11-26 已改成不写（§13） | 不变 |
| `_coex_status_get`、`_coex_wifi_request`、`_coex_wifi_release`、`_coex_schm_interval_set` | 467-492、535-542 | 回 0 | 回 0 | 不变 |
| `_coex_register_start_cb` | 571-578（只看软件共存） | 回 0 | 回 0 | 不变 |
| `_coex_deinit`、`_coex_disable`、`_coex_schm_status_bit_clear`、`_coex_schm_status_bit_set` | 444-465、521-533 | 无返回值 | 具名桩（计数、回 0，没人看返回值） | 不变 |
| `_coex_wifi_channel_set`、`_coex_event_duration_get`、`_coex_schm_interval_get`、`_coex_schm_curr_period_get`、`_coex_schm_curr_phase_get`、`_coex_schm_process_restart`、`_coex_schm_register_cb`、`_coex_schm_flexible_period_set`、`_coex_schm_get_phase_by_idx`、`_coex_configure_preemption_end_cb` | 494-510、544-569、580-605、616-632 | 回 0（`event_duration_get` 不写出参；两个取相位的回 `NULL`） | 具名桩（回 0，不写出参） | 不变 |

23 个里对齐了三处：`_coex_init`、`_coex_enable` 不再调核，`_coex_schm_flexible_period_get` 回 1。还有一处在探针的 init 里：
`wifi-blobs/src/init_probe.zig` 在关着 `-Dcoex` 时直接调过核的 `coex_init()`（注的是「IDF wrapper 顺序」）——那是 IDF **开着**
共存时的顺序（`wifi_init.c:458` → 包装函数调核）；关着时包装函数回 0、不碰核（`esp_adapter.c:439-440`）。现在关着时什么都不调，
不开 `-Dcoex` 的镜像也就不再需要 `libcoexist.a` 的 11 个成员。`bt-blobs/src/osi_impl.zig` 里那份 Wi-Fi osi 表是没有调用者的副本
（从 `wifi-blobs` 分叉来的），三处照同样的口径改了，免得两份悄悄分叉。

**主机**（`wifi-blobs/src/host_tests.zig`）：从表里取出每个钩子按 C 调用约定调一遍——返回值逐个等于上表的关闭分支，
`pti_get` / `event_duration_get` 不写出参，两个取相位的回空指针；`_coex_init` / `_coex_enable` 调过之后，替身里核的计数没有动。

**板上**（单独的 Wi-Fi 真实链路探针 `-Dwifi-link-probe`，不开 `-Dcoex`，对象集合不带 `libcoexist.a`）：`INIT OK`，扫描 32 个 AP
（8.6 秒），2 564 ms 连上，DHCP 50 ms，ping 10/10（rtt 最小 / 平均 / 最大 1.8 / 4.4 / 10.5 ms），稳 5 秒，本地断开 `reason=8`；
一次复位。与 §13 的 `connect-ag`（对齐之前，链着 `libcoexist.a`）同一个量级：37 个 AP、2 625 ms、DHCP 50 ms、10/10。blob 调这些桩的
次数与那一轮相同（`_coex_schm_status_bit_set` / `_clear` 各 37 次、`_coex_event_duration_get` 13 次、`_coex_schm_flexible_period_set`
3 次）。镜像 705 008 B；把那 11 个成员给回去也是 705 008 B——没人引用的归档成员本来就被链接器丢掉，所以这一项省的是依赖，不是体积。

日志 `logs/wifi-link-stubs-aligned-boot.log`。

### 20.6 分区表与 compiler_rt：量过了，不用动

- **分区表**：这一轮最大的合并镜像是 `phy_wifi_first` 那一份，1 261 424 B，是 factory 分区（1 536 000 B）的 82.1%，还余约 275 KB
  （迄今最大的是 §19 的 1 262 240 B）。ADR-003 第 3 节「等真有一个装不下的镜像时再扩」不变。
- **compiler_rt**：带符号表构建（`BREAKDOWN=1`）后 `nm -S` 数 `compiler_rt.*` 的符号——合并镜像 36 个、6 604 B（最大的是
  `add_f64` 884 B、`__divdf3` 838 B），占 `.flash.text`（965 664 B）的 0.7%；默认镜像 6 个、782 B（`__udivmoddi4` 等）。两份镜像里
  都没有 f128 / long-double 的软浮点例程。背景里「约 193 KB / 492 符号的死重」是旧工具链的读数，没有可裁的东西；
  `firmware/build.zig` 里那条注已更正。
- **合并镜像的体积归属**（同一次带符号表的构建，1 260 224 B）：Wi-Fi blob text 304 350 B、BLE blob 358 272 B、共存核 5 166 B、
  本仓的适配层与主机栈 249 434 B；`.flash.rodata` 169 648 B，其中没有符号的（字符串池、表）131 610 B。

### 20.7 判据条数、日志与没有做的

| 镜像 | 板侧判据 | 日志 |
| --- | --- | --- |
| §19 的最终配置 + `-Dcoex-ping-in-ms=8000` | 37/37（§19 的 35 条加两条「板子答过别人的 ping」） | `logs/coex-merged-c9-pingin-boot.log` |
| 同上 + `-Dcoex-ble-first=phy_ble` | 26/32（不过的 6 条都是连接、DHCP、ping、稳 5 秒） | `logs/coex-merged-c9-blefirst-phyble-boot.log` |
| 同上 + `-Dcoex-ble-first=phy_deferred` | 停在 BLE 的 init，没有判据 | `logs/coex-merged-c9-blefirst-phydeferred-boot.log` |
| 同上 + `-Dcoex-ble-first=phy_wifi_first` | 36/36（多一条「PHY 由 Wi-Fi 的路径先打开」） | `logs/coex-merged-c9-blefirst-phywififirst-boot.log` |
| `BLE=1` + `-Dcoex-ble-disable`（每一步之后扫描，默认） | 28/28 | `logs/coex-merged-c9-bledown-stepwise-boot.log` |
| 同上 + `-Dcoex-ble-down-scan=false`（连着做） | 25/28 | `logs/coex-merged-c9-bledown-backtoback-boot.log` |
| 同上 + `-Dcoex-ble-down-scan=false -Dcoex-ble-down-gap=2500` | 28/28 | `logs/coex-merged-c9-bledown-paced-boot.log` |
| 单独的 Wi-Fi 链路探针，不开 `-Dcoex` | 不打判据，看读数（§20.5） | `logs/wifi-link-stubs-aligned-boot.log` |

主机用例多了四条：wifi-blobs 两条（回显请求、计数桩）、bt-blobs 一条（BLE 关时钟只清自己的位）、`radio-coex` 一条（只属于一个模块的位）；
各组件与三处文档里的总数跟着改（`tests/baselines.json`，`scripts/check-invariants.py` 核对）。

没有做的：

- 下电路径里八步之间最少要隔多久、隔在哪几步之间、等的是什么（§20.4）；`phy_deferred` 停在第 7 步的原因（§20.3）。
- `phy_wifi_first` 只上板一次；下电路径的三种各一到两次（连着做那一种两次，结果相同）；都没有从 AP 一侧抓帧。
- 「BLE 先起」的第二种顺序没有做成默认：应用层要先起 BLE 时得自己按这个顺序调（PHY 那一步由 Wi-Fi 的路径先做）。
- §19.6 留下的三条（可连接广播、时延涨在哪一段、信道分类有没有被 controller 用上）这一轮没有碰。
