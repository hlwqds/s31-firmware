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
| C2 及以后（接入两套适配层、运行时统一、容量、合并镜像） | — | 未开始 | — |
| 共存的真实效果（L4） | L4 | 没有任何证据：两个射频都没有端到端跑通 | — |

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
- 未提供：`coexist_printf`（C 变参函数）、`esp_coex_preference_set`、外部共存的 GPIO 配置。

### 3.7 未验证

- 真核心下的全部行为：适配表被核心接受、`g_coex_param_ptr` 非零、两行版本日志、18 个适配钩子的真实现。
- ADR-003 里 L3 判据"`coex_wifi_request` 之后 BLE 回调被触发"指的是方案回调；那条路径没有被反汇编过，本组件只验证了登记。按反汇编确定的调用点是：BLE 回调 type 0 在使能计数升到 2 时被调，type 1 在降回 1 时被调。
- 接入 `wifi-blobs`、`osal`、`bt-blobs`（C2）尚未开始。接线时已知的坑：`osal.zig` 只导出了 16 个 `wr_btdm_coex_*` 里的 11 个；`wifi-blobs/src/osi_impl.zig` 的 `shellCoexWifiRequest` 参数顺序与 IDF 不符；`wifi.fill()` 要在通用桩之后调，否则 IDF 留空的 `_coex_condition_set` 会被填上。
