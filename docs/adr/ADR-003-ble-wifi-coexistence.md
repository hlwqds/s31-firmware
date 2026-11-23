# ADR-003：BLE 与 Wi-Fi 共存的设计

- 状态：accepted
- 日期：2026-11-23
- 决策者：huanglin（委托 coding agent 调研、起草并实现）

## 背景

2026-11-23 的调研结论（每条都有出处；`R/` 指 `/home/huanglin/code/s31-firmware`，`IDF/` 指 `~/esp/esp-idf`）：

| 事实 | 出处 |
| --- | --- |
| 单独的 Wi-Fi 与 BLE 都还没有端到端跑通：Wi-Fi blob 卡在 `esp_wifi_start` 的 MAC 忙位，BLE controller 的射频 synth 不锁 | `R/logs/ch25-start-boot.log:401`（start 无返回行）；`R/logs/r162b-unlock-sweep-negative.log`（`98BC.bit2=0`）；路线图 R3.1/R3.3 |
| 两套 blob 适配层按构造互斥。没有任何构建把两棵树链进同一镜像 | `R/firmware/src/main.zig:22-26`；`R/firmware/build.zig:90-96,236,308` |
| 同名导出：`esp_event_handler_register`/`unregister`、`s31_printf_hook`（两边签名不同）、`free`/`sprintf`/`putchar`/`puts`/`strtok`/`rtc_clk_xtal_freq_get` | `R/components/wifi-blobs/src/event_bus.zig:30,43` 与 `R/components/bt-blobs/src/event_bus.zig:30,43`；`R/components/wifi-blobs/src/init_probe.zig:404` 与 `R/components/bt-blobs/link/wifi_probe_stubs.c:90`；`R/components/wifi-blobs/src/link_stubs.zig:42-79`；`R/components/bt-blobs/link/bt_stubs.c:15` 自述两套不要同时链进同一个镜像 |
| 两套协作式切换器各持一份主上下文栈指针，互不 import | `R/components/wifi-blobs/src/sched.zig:64-153`（`s31_swap_context`）；`R/components/osal/src/sched.zig:80-185`（`bt_swap_context`） |
| 两边各吃下整块堆 | `R/components/wifi-blobs/src/init_probe.zig:424-428`；`R/components/bt-blobs/src/probe.zig:1086-1089` |
| 两边都把 TIMG0 T0 当 tick 并路由到 CLIC 输入 25 | `R/components/wifi-blobs/src/init_probe.zig:882-887`；`R/components/bt-blobs/src/probe.zig:193-199,2189-2192` |
| trap 钩子是单槽，两边各占一组 | `R/boards/esp32s31-coreboard/src/trap.zig:1453-1458,1567-1580` |
| 共存 glue 现状：Wi-Fi 侧 24 个 osi coex 钩子里 8 个有实现，其余是返回 0 的静默桩；BLE 侧 16 个 `wr_btdm_coex_*` 里 11 个只计数，5 个没有强定义，落到归档的断言桩 | `R/components/wifi-blobs/src/osi_impl.zig:1132-1171`、`osi_stubs.zig:316-341`；`R/components/osal/src/osal.zig:1981-2082`；`R/components/bt-blobs/logs/r136b-full-disasm-lp-authoritative.txt:167612-167738` |
| BLE 回调注册只有一个槽，controller 会注册两个 type，第二个覆盖第一个；存下的回调没有任何调用点 | `R/components/osal/src/osal.zig:2005-2007,2077-2082`；`R/components/bt-blobs/logs/btfix1.log:240-248` |
| 共存核从未被初始化：板上 `g_coex_param_ptr=0`；启动期的 `coex_pre_init()` 与适配表注册在仓内零命中 | `R/logs/ch25-clock-readback-boot.log:386`；对 `R/components`、`R/boards` 检索 `coex_pre_init\|esp_coex_adapter_register\|g_coex_adapter_funcs` |
| BT 闭包里没有 `libcoexist.a` | `R/components/bt-blobs/tools/gen-bt-closure.sh:18-23` |
| 容量：irom 窗口 786 432 B、drom 窗口 720 896 B；factory 分区 1 536 000 B | `R/boards/esp32s31-coreboard/linker/s31.ld:49-50`；`R/firmware/idf-bootstrap/partitions.csv:23` |
| IDF 自己的纯 BLE controller 镜像：`.flash.text` 528 424 B、`.flash.rodata` 64 168 B（已链 `libcoexist` 7 个成员） | `~/esp/bt-ctl-oracle/build/bt-ctl-oracle.map:22905,31933,382-577`（仓库外的参照构建） |
| 我们的镜像另有约 193 KB 剥不掉的 compiler_rt 死重 | `R/firmware/build.zig:175-177` |
| 不带探针的纯 BLE 闭包镜像（2026-11-24 实测，gc 关）：`.flash.text` 745 056 B、`.flash.rodata` 121 696 B、`.iram_blobs` 61 872 B，镜像 950 756 B | `scripts/check-bt-link.sh` 的输出；命令见 `docs/verification/coex-verification.md` |
| 合并链接实验（2026-11-24，两个 blob 整闭包加 `libcoexist` 11 个成员，不带探针）：带着 Wi-Fi 量体积桩 `zz_stubs.o` 时只有 4 个同名符号（`sprintf`、`free`、`net80211_printf`、`pp_printf`，全是它与 BT 侧 C 桩撞名），未定义 0；去掉它后同名 0、未定义 61（Wi-Fi 侧专属：24 张 `est_PHY_*` 表、mesh 与 espnow 的厂商接口、`WIFI_EVENT` 等） | 同上 |
| 非探针的 BLE 闭包链接原本是断的：`scripts/check-bt-link.sh` 报 11 个未定义符号，都是只在探针构建里编译的诊断导出 | 已修：`R/components/bt-blobs/link/closure_stubs.zig`，经 `R/firmware/build.zig` 的非探针分支挂进模块树 |

用户要求把共存写进路线图、给出设计并实现，凡是不靠抓空口就能验证的部分都要落地。

不做的后果：即使两个射频各自打通，同一镜像里也只能二选一；而 IDF 的两个 blob 本来就是按 Espressif 的共存接口写的，缺了这层 glue，同时开启时谁也不知道对方在用射频。

## 选项

1. 方案 A：自研仲裁器（自己写时分或优先级调度，直接切射频）。
2. 方案 B：沿用 Espressif 的共存架构（ROM 里的仲裁核加 `libcoexist.a`），用 Zig 补齐 IDF 的 C 胶水层，并解决两个适配层的运行时冲突。
3. 方案 C：只做外部共存（GPIO 信号交给片外芯片），片内不共存。

## 决定

选 B。

- 两个 blob 的时间敏感逻辑在闭源代码里，它们按 `wifi_osi_funcs_t` 的 coex 钩子和 `wr_btdm_coex_*` 接口对接仲裁核。方案 A 要在闭源 blob 内部埋点，做不到；方案 C 不满足"同时运行"。
- 方案 B 的工作量是确定的：胶水层是薄转发，语义以 IDF 源码为准，可以在主机上逐钩子对照测试，不依赖射频。

### 1. 共存 glue（新组件 `radio-coex`）

把 IDF 的三层 C 代码逐项写成可主机测试的 Zig：

- **适配表**：`coex_adapter_funcs_t`（esp32s31：版本 2、魔数 0xDEADBEAF、20 个表项），经 `esp_coex_adapter_register` 注册。依据 `IDF/components/esp_coex/include/private/esp_coexist_adapter.h:15-16`、`IDF/components/esp_coex/esp32s31/esp_coex_adapter.c:160-181`。
- **Wi-Fi 侧**：`IDF/components/esp_wifi/esp32s31/esp_adapter.c:435-632` 的 24 个 coex 钩子。名字、参数、返回值，以及 esp32s31 配置下留空或返回定值的条目，都照搬。
- **BLE 侧**：`IDF/components/bt/porting_btdm/controller/btdm_common/src/btdm_coex.c` 的 16 个 `wr_btdm_coex_*` 与 `btdm_coex_init`/`btdm_coex_enable`/`btdm_coex_disable`。回调按 type 分别保存，并提供触发点。
- **核接口**：把需要的 `libcoexist.a` 与 ROM 入口（`IDF/components/esp_rom/esp32s31/ld/esp32s31.rom.coexist.ld`）收成一个函数指针结构。主机测试注入记录桩；目标上由 `bind.zig` 用 `@extern` 绑定真实符号，主机构建不编译它。
- **生命周期**：启动期 `coex_pre_init()` 与适配表注册，然后是 Wi-Fi 初始化之前的 `coex_init()`（`IDF/components/esp_wifi/src/wifi_init.c:457-471`），再是 BLE 侧 init 第 4 步与 enable 第 16 步。乱序调用由状态机拒绝。

构建开关 `-Dcoex`，默认关。默认镜像的字节必须不变，用"worktree 基线 + 同配方构建 + 逐段 SHA-256"证明。

### 2. 运行时统一（让两棵树能链进同一镜像）

```text
                 ┌──────────────────────────────────────────────┐
 应用 / 自检 ───▶│ 主上下文（协作式调度：一个切换器、一个主栈）   │
                 │   ┌──────────────┐      ┌────────────────┐    │
                 │   │ Wi-Fi blob   │      │ BLE controller │    │
                 │   │ task(s)      │      │ task           │    │
                 │   └──────┬───────┘      └───────┬────────┘    │
                 │  osi 表（唯一一份）       OSAL（osal_kit）      │
                 │   ┌──────────────────────────────────────┐    │
                 │   │ radio-coex glue ──▶ libcoexist + ROM │    │
                 │   └──────────────────────────────────────┘    │
                 │ tick：TIMG0 T0 → CLIC 25，同时驱动两边的定时器 │
                 └──────────────────────────────────────────────┘
```

- 一个调度器：`osal_kit.sched` 是唯一的上下文切换器，`wifi-blobs` 的 `s31_swap_context` 退化为别名或删除，主栈只有一个。
- 一份 osi 实现：`wifi-blobs/src/osi_impl.zig` 是唯一的 osi 表提供者。`bt-blobs/src` 里那份分叉副本（`osi.zig`、`osi_impl.zig`、`osi_stubs.zig`、`event_bus.zig`、`nvs_ram.zig`、`init_config.zig`）删除；它的 coex 部分今天不可达（`makeTable()` 没有调用点），用到的 `setHooks`/`serviceTimers` 改由 wifi-blobs 的那份提供。
- 同名导出：`esp_event_handler_*`、`s31_printf_hook`、libc 桩各留一份。`s31_printf_hook` 取 Wi-Fi 侧的签名，BT 调用点跟着改。
- 符号提供者唯一：真实归档（`libphy`、`libcoexist`、`libbtbb`）优先于 ROM，ROM 优先于一份桩。量体积用的 `zz_stubs.o` 不进合并镜像。上面那次合并链接实验说明 C 对象层的冲突只有 4 个符号；Zig 层（两套探针与 osi 副本）的同名导出和调度冲突才是主体，该实验没有触及。
- 堆：一个堆，按子系统设配额（Wi-Fi、BLE、应用各一个上限）。
- tick：TIMG0 T0 只路由一次，Wi-Fi 的软件定时器与 BLE 的 callout 挂在同一个 tick 上。
- trap 钩子：单槽改多槽列表。

### 3. 容量与分区

- IDF 自己的构建里，纯 BLE controller 镜像的 text 是 528 KB；两个 blob 加起来超过现在的 irom 窗口（786 KB），合并镜像也超过 factory 分区（1.5 MB）。
- 不带探针的纯 BLE 闭包镜像在我们自己的构建里 text 实测 745 KB（gc 关，见背景表），单它就已占去 irom 窗口的 95%。
- 链接脚本：irom 扩到能装下"两个 blob + 应用"，drom 基址后移。上限以芯片为准（`docs/ARCHITECTURE.md`：`SOC_IROM_HIGH=0x44000000`，DROM 段须结束在 `0x43FF0000` 以下），并用 `-Dfat-rodata` 一类的填料镜像在板上证明新窗口能被 loader 加载。
- 分区表：factory 与两个 ota 槽从 1.5 MB 扩到 4 MB 级（flash 共 16 MB），A/B 切槽与回滚的断言重跑。
- compiler_rt 死重单独立项，先量后删。
- 合并链接（开 gc、带真实入口）实测后写入 `tools/s31-production/baseline/capacity.json`。

出口条件：合并镜像能启动、两个控制器的 init 都返回、各段自检通过。这一步不需要射频。

### 4. PHY 与时钟域的归属

Wi-Fi 与 BLE 都依赖 PHY 使能和 modem 时钟，`COEXIST_CLOCK_DEPS` 本身就含 `SOC_PLL_SOURCE_CG`（`IDF/components/esp_hw_support/modem/port/esp32s31/modem_clock_impl.c:14-18,35`）。设计上 PHY 只有一个归属者：由 glue 记录两个子系统的使能请求，串行地做 PHY enable/disable 与 `coex_module_enable(PERIPH_COEX_MODULE)`。具体寄存器序列要等两个射频各自打通后才能上板验证，这里只定归属模型。

### 5. 验证（按仓库的 L1–L4 分级；不抓空口能到 L3）

| 级 | 内容 | 判据 |
| --- | --- | --- |
| L1 主机 | glue 对照 IDF：每个钩子的转发、返回值、留空条目；回调按 type 保存并触发；乱序拒绝；适配表布局 | `components/radio-coex` 的主机测试；README 里"钩子 → IDF 源码行 → 测试"三列表 |
| L2 镜像 | `-Dcoex` 打开后链接通过且恰好两段；关闭时默认镜像逐段不变 | `image-info` 两行；逐段 SHA-256 相同 |
| L3 板侧（不抓空口） | 单射频探针镜像开 coex：`g_coex_param_ptr` 非零、打印 coex 固件与 ROM 版本（官方固件启动时就有这两行，见 `R/components/bt-blobs/logs/bt-ana-i2c-official-trace.log:59-60`）、BLE 两个回调都注册成功、`coex_wifi_request` 之后 BLE 回调被触发；随后合并镜像启动 | 串口日志 |
| L4 真链路 | 共存下的性能：BLE 不同广播间隔对 Wi-Fi 吞吐的影响、PTI 行为 | 需要两个射频都通并抓空口；当前被 R3.1 与 R3.3 的墙挡住 |

## 后果

- 正面：
  - glue 层语义有唯一依据（IDF 源码），可以逐钩子验证，不依赖射频。
  - 默认构建字节不变，现有工作态镜像不受影响。
  - 运行时统一解决的是"两个 blob 能否同镜像"的硬约束，与射频是否打通无关，可以先行。
- 负面：
  - 运行时统一要改动 `wifi-blobs`、`bt-blobs`、`osal` 里钉在已知正常态的代码，回归风险集中在 BT 探针镜像上，靠"默认镜像不变证明"和板级自检兜底。
  - 窗口与分区扩大后，factory `0x10000`、ota_0 `0x190000` 这些偏移要跟着改，已有日志里的偏移成为历史值。
  - 共存的真实效果（L4）在两个射频打通前无法验证。本设计能保证的是胶水正确、两个控制器能同镜像启动。
- 需要跟进：
  1. `radio-coex` 接进 `wifi-blobs`、`osal`、`bt-blobs`（在 `-Dcoex` 开关后面）。
  2. 运行时统一：调度器、osi、导出、堆、tick、trap 钩子六项。
  3. 窗口与分区扩大及板级证明；compiler_rt 死重。
  4. 合并镜像启动（L3）。
  5. R3.1（`MAC_ST`）与 R3.3（synth）打通后做 L4。
