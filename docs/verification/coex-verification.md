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
| C2 真核心上板（Wi-Fi 探针） | L3 | 共存库自己打出两行版本、`wifiInit rc=0`、`INIT OK`；随后的 panic 来自探针写死的地址，对照在同一处也 panic | §4.5 |
| C3 及以后（运行时统一、窗口与分区、合并镜像） | — | 未开始 | §5 |
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

对照在同一处也进 trap。这一段是探针的实验代码，对内存布局有硬编码依赖；没有改它。

因为探针在 start 之前就 panic，blob 的 `wifi_hw_start` 没有跑到，`_coex_enable` 这条路径在板上**没有被执行**（诊断行 `en=0`），Wi-Fi 侧停在 `inited`。

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
- `-Dcoex` 目前一次只接一个射频的适配层：两个 blob 同链要等运行时统一（C3），`build.zig` 对此直接报错。
- `-Dcoex` 不能与 `-Dwifi`（自检 section）同开：`radio_coex` 的 section 模块与胶水模块不能同时含 `glue.zig`。

### 4.9 未验证

- 两个射频同时在一个镜像里（C3、C4），以及共存的任何实际效果（L4）。
- Wi-Fi 侧的 `_coex_enable`：探针在 start 之前 panic，这条路径没有被 blob 执行。
- 18 个 OS 钩子在有争用时的行为：只做了主机测试，板上核只走了"立即拿到锁"的路径。
- 共存核的硬件定时器（`coex_hw_timer_*`，读 `0x2010F008`）是否在走，没有读回。
- 回调被核心调用的时刻（使能计数升到 2 / 降回 1）：需要两个射频都开，目前只验证了登记。

## 5. C3 及以后：还没做，以及为什么

| 项 | 要动什么 | 现状 |
| --- | --- | --- |
| C3 运行时统一 | 一个调度器、一份 osi、同名的导出各留一份、堆配额、tick 只路由一次、trap 钩子改多槽 | 未开始。两边各有一套探针（`bt-blobs/src/probe.zig` 3945 行、`wifi-blobs/src/init_probe.zig` 1286 行），都带着进行中的实验和对内存布局的硬编码；C0 的合并链接实验没有编译这两层 Zig 代码，冲突面还没有量过 |
| C4 窗口与分区 | irom 窗口 786 432 B 装不下两个 blob（BLE 探针 + 共存核已用到 777 712 B，Wi-Fi 探针 + 共存核 379 824 B）；factory 与两个 ota 槽要跟着扩 | 未开始。扩窗口本身可以离线验证（链接 + 填料镜像上板），但改分区表会挪动 ota 槽的偏移，A/B 切槽与回滚的九项断言要重跑 |
| C5 PHY 与时钟域归属 | 启动序列 | 未开始，要等两个射频各自打通 |
| C6 共存性能 | — | 阻塞：等 R3.1（`MAC_ST`）与 R3.3（synth） |
