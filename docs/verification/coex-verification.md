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
| C5 PHY 与时钟域的归属模型 | L1 | `radio-coex/src/owner.zig` 10 项主机用例全过；**寄存器序列没有接** | §8 |
| 探针镜像回归 | L3 | BLE 探针开共存仍走到原来的墙，SRAM 布局读数不变；Wi-Fi 探针开共存仍 `INIT OK`，并走到 `esp_wifi_start`（2026-11-25 起返回 0，见下一行） | §6.5 |
| modem 的 ICG 码（Wi-Fi 侧 R3.1 的墙） | L3 | Wi-Fi 探针 `esp_wifi_start rc=0`、init 之后 `MAC_ST=0x00000000`；合并镜像重跑 0 个失败。BLE 侧不能接（探针锁死）——**2026-11-26 更正**：锁死的两份日志来自已经不在树里的旧探针；合并镜像里 BLE enable 在 ICG 已生效时返回 0、没有锁死 | §11、§14 |
| 共存的真实效果（L4b，两个射频都开） | L4 | 两个射频都在收发：没有任何证据，BLE 的射频 synth 不锁。合并镜像里 BLE enable 返回 0 之后锁定位仍是 0（2026-11-26，§14）。**一个射频在收发、另一个 enabled** 已经跑通：两个控制器同镜，Wi-Fi 连上真实 AP（见下面「合并镜像里的 Wi-Fi 真实链路」一行） | — |
| 只开 Wi-Fi 的共存读数（L4a） | L4 | 共存核开着时真实链路能通（连上、DHCP、ping 网关 10/10）；胶水没有拒绝过一次调用；blob 的 13 次申请核都回 `0x102`，原因在核的静态表里（这些事件没有配硬件定时器）；BLE 没开，核的状态位是 0。不开共存的对照已补，判据成立（§13）。**更正**：初稿写的"硬件定时器都是 0"不成立——当时读的 `0x2010F008` 是共存低功耗时钟的配置，不是计数器（§12） | `logs/wifi-link-connect-boot.log`；§12、§13 |
| 不开共存的对照（ADR-003 L4a 的判据「ping 与不开共存时一样」） | L4 | **成立**：胶水按 IDF 关闭分支作答、核不启动（`-Dcoex` + `-Dcoex-sw-off`）时扫描 38 个 AP、连上 2566 ms、DHCP 46 ms、ping 10/10。只去掉 `-Dcoex` 的两轮收不到帧（扫描 0 个 AP、连接 `reason=201`），根因是 `_coex_pti_get` 的计数桩把出参写成 0——只把这一处改成不写，计数桩的镜像也照常（扫描 37 个 AP、ping 10/10）。**共存核不是 Wi-Fi 收发的前置**：本表初稿写反了，已更正 | `logs/wifi-link-nocoex-boot.log`、`logs/wifi-link-coex-off-boot.log`、`logs/wifi-link-stubs-pti-boot.log`；§13 |
| 合并镜像里的 BLE enable（`-Dcoex-ble-enable`） | L3 | `bringup.enable rc=0`、`ENABLED`，共存核 BLE 侧 `enabled`；没有锁死、没有复位。synth 锁定位（`0x201098BC` 的 bit2）在 enable 前后都是 0——这是预期值：合成器是广播使能命令处理之后才上电的，这一轮没有发 HCI 命令，**对 R3.3 不构成结论** | `logs/coex-merged-ble-enable-boot.log`；§14 |
| 合并镜像里的 Wi-Fi 真实链路（`-Dcoex-wifi-link`） | L3 | 两个控制器同镜：BLE `INITED`、`ENABLED`，Wi-Fi 扫描 35 个 AP、连上 2059 ms、DHCP 51 ms、ping 网关 10/10，16/16 项通过，`verdict=pass`（2026-11-26）。前提是 Wi-Fi 先 `esp_wifi_start`，并且 BLE 的 init 不再做两段会重做 PHY 的打开与标定的事（`probe_ptr.initPhy`、第 15 步的 `esp_phy_load_cal_and_init`）：五个单变量对照里，只跳过其中一段，扫描就从三十多个 AP 掉到 1–2 个，而连接、DHCP、ping 的判据照样全过（所以加了一条「扫描 AP 数不低于基线一半」）；不写回时钟 / 电源寄存器，则认证、关联成功后被 `reason=7` 断开 | `logs/coex-merged-wifi-link-*.log`（通的一份与五份对照）、`logs/coex-merged-wifi-link-deaf-boot.log`（BLE 先 init，不通）；§15 |

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
- **原来的判据抓不住这种退化。** B 和 D 里接收已经退到 1–4 个 AP，连接、DHCP、ping、稳定 5 秒照样全过，`verdict=pass`。
  所以加了一条：BLE init 之后的扫描 AP 数不得低于基线的一半（15.4）。它在 E 上失败（`2 vs 36`），在最终形态上通过（15.5）。
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
- 排查阶段（15.2 的十四轮）的原始日志只留了轮 1，那些数字是当时的读数。带结论的五份对照都有入库日志，每个对照只跑了一次。
- 合并镜像里真实链路的顺序只有 Wi-Fi 先 start 这一种；BLE 先 init 那种顺序（轮 1）不走。
- `bringup.enable()` 开头无条件写 `0x2010_0450 = 0x00102000`（§14.3）。这一轮它是在 Wi-Fi 已经 start 之后执行的，
  链路照常通过；它对 Wi-Fi 有没有影响没有单独量。
- 一台 AP（WPA2-PSK + CCMP-128，信道 1）；没有抓包。
- 合并镜像里 `esp_wifi_start` 之后到 BLE init 之间、BLE 的 init 期间，Wi-Fi 的任务没有被泵（只开了中断），
  事件队列里积压的帧被丢掉；链路是从扫描重新开始的。

