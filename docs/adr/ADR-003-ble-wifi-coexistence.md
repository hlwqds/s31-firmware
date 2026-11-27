# ADR-003：BLE 与 Wi-Fi 共存的设计

- 状态：accepted
- 日期：2026-11-23
- 决策者：huanglin（委托 coding agent 调研、起草并实现）

## 背景

2026-11-23 的调研结论（每条都有出处；`R/` 指 `/home/huanglin/code/s31-firmware`，`IDF/` 指 `~/esp/esp-idf`）：

| 事实 | 出处 |
| --- | --- |
| 单独的 Wi-Fi 与 BLE 都还没有端到端跑通：Wi-Fi blob 卡在 `esp_wifi_start` 的 MAC 忙位，BLE controller 的射频 synth 不锁（2026-11-25 更正：Wi-Fi 侧已能从 `esp_wifi_start` 返回，见 ADR-001 文末；本行其余内容是决策当时的事实。2026-11-27 更正：合并镜像里 BLE 的广播已上空口、合成器 35 ms 内锁定，见 `docs/verification/coex-verification.md` §17.5；单独的 BLE 探针里 synth 不锁这一条没有变化） | `R/logs/ch25-start-boot.log:401`（start 无返回行）；`R/logs/r162b-unlock-sweep-negative.log`（`98BC.bit2=0`）；路线图 R3.1/R3.3 |
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
| compiler_rt：默认镜像里 6 个符号 782 B，合并镜像里 36 个符号 6 604 B，没有 f128 / long-double 的软浮点例程（2026-11-27 带符号表构建后 `nm` 实测；此前记的「约 193 KB 死重」是旧工具链的读数） | `R/firmware/build.zig` `app` 后面的注；`docs/verification/coex-verification.md` §20.6 |
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

**【2026-11-26 补记】「默认关」对 Wi-Fi 也成立。** L4a 的对照轮闭合了：胶水链着、按 IDF 关闭分支作答、共存核不启动
（`-Dcoex` + `-Dcoex-sw-off`）的镜像，真实链路照常——扫描 38 个 AP、连上、DHCP、ping 10/10。中间有一段弯路：只去掉
`-Dcoex` 的镜像（钩子是计数桩）收不到帧，一度被记成"共存核是前提"；查清是 `_coex_pti_get` 的计数桩把出参写成 0，
不是缺了共存核（`docs/verification/coex-verification.md` §13）。落在设计上的一条：**blob 的共存钩子要么走本组件的胶水
（关闭分支在 L1 逐钩子对照过 IDF），要么把计数桩逐项对齐**——两边的桩值不是一回事。

**【2026-11-26 补记 2】「PHY 归先使能它的那一方」拿到了板级证据。** 合并镜像里两个控制器带着 BLE enable 走通了 Wi-Fi
的真实链路（扫描 35–37 个 AP、连上、DHCP、ping 10/10，`-Dcoex-wifi-link`）。过程里撞上的墙正是这条归属规则的另一面：
BLE 的 init 是按"单独跑"写的，`bringup.init` 里有两段会重做 PHY 的打开与标定——`probe_ptr.initPhy()`，与第 15 步的
`esp_phy_load_cal_and_init`（在本镜像里恒为"没标定过"，等于一次全量重新标定）。单变量对照：只跳过第 15 步，扫描从
31 个 AP 掉到 1 个；只跳过 `initPhy`，36 个掉到 2 个；两段都跳过才恢复。反过来让 BLE 先 init，PHY 的一次性初始化被它
用掉，Wi-Fi 那边的标定数据是空的。修法是把规则落到代码里：Wi-Fi start 成功后置 `phy_owned_by_wifi`，BLE 的 init 不再做
这两段。时钟域那一条还没有正解——BLE 的 init 仍整字改写 `MODEM_SYSCON_CLK_CONF1`，合并镜像不写回的话扫描照常、连接
失败（`reason=7`），所以现在是事后按快照把时钟 / 电源寄存器整字写回（BLE 那一侧的时钟位也被拿掉）；按两个射频的需求
取并集留给下面第 5 项。细目见 `docs/verification/coex-verification.md` §15。

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

**实现记录（2026-11-24，C3）——量过之后，上面六项里真正要做的是这些：**

- 先做了一次合并链接实验：两棵树 + 两个 blob 的整闭包 + `libcoexist` 链进同一次链接。Zig 层报 6 个
  导出撞名，压掉之后链接器再报 6 个重复符号，未定义 0。冲突面一共 12 个符号，比预想小得多。
- **同名导出**：没有合并实现，而是定了一条规则——「真归档 > 能用的实现 > 计数桩」，落选的一方改成
  **弱符号**导出（Zig 用 `@export(…, .{ .linkage = .weak })`，C 用 `__attribute__((weak))`）。单独构建
  任一射频时没有别的定义，行为不变。取舍逐个写在 `components/radio-coex/link/coex_printf_shim.c` 文件头。
  顺带纠正了两处：Wi-Fi 侧 7 个只是计数的桩（`sprintf` 连缓冲区都不写）原本会在合并镜像里压过 BLE 侧
  能用的实现；`coexist_printf` 的真格式化（C shim）原本被 BLE 侧「只转格式串」的强导出压住。
- **调度器**：两个切换原语机器码完全相同（链接器把它们折到同一地址），冲突只在「嵌套」——在一方的
  任务栈上去泵另一方的任务。合并镜像把 init 排成「主 → Wi-Fi 任务 → 主 → BLE 任务 → 主」，不嵌套；
  另加一道保险：BLE init 期间置 `wifi-blobs` 的 `foreign_context`，Wi-Fi 侧的让出点只计数、不切换
  （板上读数 `n=0`，说明没有触发）。**没有把两个切换器合成一个**。
- **osi 表**：合并镜像里只有 Wi-Fi 侧的表被注册；`bt-blobs/src` 里那份分叉副本的 `makeTable()` 仍然
  没有调用点，是惰性的。**没有删除它**——探针还在用它的 `setHooks` / `serviceTimers`，而探针是钉在
  已知正常态上的 4000 行实验代码；删除留到探针退役时。
- **堆**：一个堆按配额切两段，Wi-Fi 拿前 3/5（实测 100 512 B），其余给 BLE（67 008 B）。
  合并镜像里堆只有约 164 KB（两边的静态池、trap 栈、blob 的常驻代码都占 SRAM）。
- **tick**：合并镜像里两边都不开中断（与各自探针镜像同条件），没有冲突可解。
- **trap 钩子**：两边占的槽不重叠（Wi-Fi 6 个统计钩子，BLE 5 个诊断钩子），**没有改成多槽**。
- **对内存布局写死的地址**：两边的探针实验都带着这种地址，合并镜像的布局和任何一边的探针镜像都不同。
  Wi-Fi 侧用 `initOnly(.{ .experiments = false })` 关掉；BLE 侧在 `bringup.zig` 加 `layout_probes` 开关，
  让本文件的 MMIO 助手拦截对那一小段"槽"地址的访问。核对时发现：`bringup.init` 里被注释成"blob 的
  lazy-init 槽 / `s_is_phy_calibrated`"的那几个地址，在**现在的 BLE 探针镜像里**就已经落进我们自己的
  静态数组 `g_phy_cal_buf`（起始 `0x2f010c00`），不是 blob 的数据——它们今天是空操作，探针照样走到 INITED。
- **写死的代码地址门**：`osal.logLine` 原本只放行落在 `0x4000_0020..0x400A_0300` 的日志钩子；镜像一大，
  BLE 的里程碑行会被静默丢弃。改成用链接脚本的 `_text_start` / `_text_end`。
- **入口**：Wi-Fi 侧的 init 原来全写在探针的 `run()` 里，抽出 `init_probe.initOnly()`（到 `INIT OK` 返回）；
  BLE 侧新增 `probe.initOnly(region)`（`bringup.init` 加它必需的钩子、时基与堆，不带探针的实验装置）。
  构建开关 `-Dcoex-merged` 把两边挂进同一个 app，并在各段自检之后多跑一个 `coex_merged` section。

### 3. 容量与分区

- IDF 自己的构建里，纯 BLE controller 镜像的 text 是 528 KB；两个 blob 加起来超过现在的 irom 窗口（786 KB），合并镜像也超过 factory 分区（1.5 MB）。
- 不带探针的纯 BLE 闭包镜像在我们自己的构建里 text 实测 745 KB（gc 关，见背景表），单它就已占去 irom 窗口的 95%。
- 链接脚本：irom 扩到能装下"两个 blob + 应用"，drom 基址后移。上限以芯片为准（`docs/ARCHITECTURE.md`：`SOC_IROM_HIGH=0x44000000`，DROM 段须结束在 `0x43FF0000` 以下），并用 `-Dfat-rodata` 一类的填料镜像在板上证明新窗口能被 loader 加载。
- 分区表：factory 与两个 ota 槽从 1.5 MB 扩到 4 MB 级（flash 共 16 MB），A/B 切槽与回滚的断言重跑。
- compiler_rt 死重单独立项，先量后删。
- 合并链接（开 gc、带真实入口）实测后写入 `tools/s31-production/baseline/capacity.json`。

**实现记录（2026-11-24，C4）：**

- 实测占用（带默认的 boot + net 各段，开 gc）：合并镜像 `.flash.text` **825 744 B**、`.flash.rodata`
  154 800 B、`.iram_blobs` 100 208 B、`.data` 35 968 B、`.bss` 168 768 B；`app.bin` 1 117 376 B。
  上文"两个 blob 加起来超过 irom 窗口（786 KB）"成立；"合并镜像也超过 factory 分区（1.5 MB）"**不成立**：
  init 级的合并镜像离 factory 上限（1 536 000 B）还差约 41 万字节。
- 链接脚本：irom `0x40000020` 长度 `0xC0000` → `0x1C0000`；drom 基址 `0x40100020` → `0x401D0020`
  （irom 窗口之后的下一页），长度 `0xB0000` → `0x1C0000`。合计远大于 factory 分区，所以
  **窗口不再是有效的容量约束**，实际占用由 `scripts/check-capacity.py` 的 factory 判据把关。
- **分区表没有改**（偏离上文"factory 与两个 ota 槽扩到 4 MB 级"）：init 级的合并镜像装得下现有分区；
  而挪动 `ota_0` / `ota_1` / `otadata` 的偏移会让已提交的 A/B 证据失效，并牵动 `demo-board.sh` 等脚本。
  等真有一个装不下的镜像（两个 blob + TLS + 应用同链）时再扩，届时连同 A/B 切槽与回滚的断言一起重跑。
- 板级证据见 `docs/verification/coex-verification.md` §7：新 drom 基址下默认镜像 8/8 通过；irom 新上限
  由合并镜像自己证明（825 744 B > 旧上限）；drom 新上限由 `-Dfat-rodata=1000000` 的镜像证明
  （DROM 段 1 046 816 B > 旧上限）。默认镜像在扩容前后的差异只有重定位（指令流形状不变）。
- **2026-11-27 晚补记（路线图 C9，`coex-verification.md` §20.6）**：带 BLE 广播、信道分类与「板子回别人的 ping」的合并镜像最大
  1 261 424 B，是 factory 分区（1 536 000 B）的 82.1%，还余约 275 KB——分区表仍然不用扩。compiler_rt 量过了：带符号表构建后
  `nm` 数出来，默认镜像 6 个符号 782 B、合并镜像 36 个符号 6 604 B，没有 f128 / long-double 的软浮点例程；上文「死重单独立项，
  先量后删」与背景表里那句「约 193 KB」是旧工具链的读数，这一项撤销。

出口条件：合并镜像能启动、两个控制器的 init 都返回、各段自检通过。这一步不需要射频。

### 4. PHY 与时钟域的归属

Wi-Fi 与 BLE 都依赖 PHY 使能和 modem 时钟，`COEXIST_CLOCK_DEPS` 本身就含 `SOC_PLL_SOURCE_CG`（`IDF/components/esp_hw_support/modem/port/esp32s31/modem_clock_impl.c:14-18,35`）。设计上 PHY 只有一个归属者：由 glue 记录两个子系统的使能请求，串行地做 PHY enable/disable 与 `coex_module_enable(PERIPH_COEX_MODULE)`。具体寄存器序列要等两个射频各自打通后才能上板验证，这里只定归属模型。

**实现记录（2026-11-24，C5）：** 归属模型落在 `components/radio-coex/src/owner.zig`（纯逻辑）：
`Owner.acquire / release(side)` 返回一串要**串行**执行的动作（共存时钟 → PHY 公共部分 → 该侧 modem 位；
最后一个使用者离开时反过来），公共部分只随首个与末个使用者各动一次，对应 IDF
`esp_phy_enable` / `esp_phy_disable`（`esp_phy/src/phy_init.c:324`、`:408`）的引用计数加一把锁；
`ClockBits` 让多个使用者共享一组时钟使能位，一侧放弃只撤自己的位。只有主机测试（10 项）。
寄存器序列仍未接：按本节原定，要等两个射频各自打通后才能上板验证。合并镜像的 section 只打印
`LPCON+0x18` 的读数作对照（§8）。

**实现记录（2026-11-27，C5 的时钟域一条）：按单元取并集，两边各管各的位。**

- **根因**（板上读数加 IDF 源码）：两边的适配层都整字写过共享的时钟字。BLE 侧 `bt-blobs/src/porting.zig` 的
  `btdmLpEnableClock` 把 `MODEM_SYSCON_CLK_CONF1` 整字写成 `0x003FF880`（清掉 Wi-Fi 的基带、MAC、APB 共 10 个
  时钟位）、强开位整字写 `0xFF`、`MODEM_LPCON_CLK_CONF` 整字写 `0x0B`（清掉 PHY 的 I2C 主控位）；
  `bringup.init` 开头整字写 `CLK_CONF` 与 `TEST_CONF`。Wi-Fi 侧 `wifi-blobs/src/osi_impl.zig` 的 `_wifi_clock_enable`
  整字写 `LPCON+0x18 = 0x3`，`_wifi_clock_disable` 无条件清共存时钟、把时钟源整字写回 `0x25`。此前的补救是事后
  按快照整字写回：Wi-Fi 的位回来了，BLE 的位（BT_APB / BTBB / BTMAC、BLE 定时器、modem 安全模块、共存与 LP 定时器
  时钟、PLL 时钟源）全被拿掉——合并镜像里的 BLE 一直是被这样掐着的。
- **IDF 的做法**（`esp_hw_support/modem/port/esp32s31/modem_clock_impl.c:14-21` 与同目录的 LL / HAL）：时钟按
  **单元**管理（WIFI_BB、WIFI_MAC、COEXIST、SOC_PLL_SOURCE_CG、BLE_MAC……），带引用计数，每个单元只写自己那一位，
  从不整字覆盖；一个模块依赖哪些单元是一张表。
- **规则**（落在代码里）：
  1. 共享的时钟 / 电源字上，任一射频**只置位、不清位**，置的位是它依赖的单元（单元表在
     `components/radio-coex/src/owner.zig` 的 `clocks`）。整字写只留 IDF 自己也整字写的两处：时钟源 `MODEM_CONF`
     （`0x3D` / `0x25`，`modem_clock_hal.c:124`）与初始化时的 ICG 位图。
  2. 共享单元（COEXIST、SOC_PLL_SOURCE_CG、WIFI_BB_80X1、PHY 前端、I2C 主控）一边释放时，另一边还占着就不关。
     本仓没有跨两个适配层的引用计数，用寄存器当计数器：BT 自己的三个单元（`CLK_CONF1` bit16-18）还置着，就是
     BLE 还占着（`osi_impl.zig` 的 `bleClockOn`）。
  3. 单一归属的配置（BLE 的 LP 定时器、32 kHz 时钟源）由归属者整字写。
  4. 事后写回（`radioSnapshot` / `radioRestore`）删除。
  5. 板上判据：合并镜像在 Wi-Fi start 之后、BLE init / enable 之后、整轮 Wi-Fi 链路之后各读一次共享字，
     与单元表的并集逐位比（`firmware/src/coex_merged.zig` 的 `checkClocks`）。
- **证据**：L1——`owner.zig` 两条（三组的位互不覆盖、并集能判出整字覆盖与整字写回各缺了什么位），
  `porting.zig` 两条（预置 Wi-Fi 的位再让 BLE 开时钟，两边的位都在；寄存器从复位值起步时读数与原来的整字写
  相同，单独的 BLE 探针不受影响）。L4——`logs/coex-merged-wifi-link-union-boot.log`：三个时点都是
  `CLK_CONF1=0x003FFFFF`、`CLK_CONF=0x7E601002`、`LPCON=0x0F`、`MODEM_CONF=0x3D`；Wi-Fi 基线 38 个 AP、BLE init
  之后 34 个，连上、DHCP、ping 10/10，20/20 项通过，`verdict=pass`。
- **影响面**：默认镜像（boot + net）与各 profile 不含这两个适配层，不受影响。单射频的镜像只在共享时钟字的写法上变了
  （置位代替整字写），各回归一轮：单独的 Wi-Fi 真实链路镜像扫描 37 个 AP、连上、DHCP、ping 10/10
  （`logs/wifi-link-clock-union-boot.log`，基线 `logs/wifi-link-connect-boot.log`）；单独的 BLE 探针与基线逐行等价。
  入库前一律经 `tools/ap-side/redact.py` 脱敏（扫描结果里有邻居的 SSID 与 BSSID）。
- **没有做的**：Wi-Fi init 之前把 `LPCON+0x18` 对正成 `0x1` 的那一句会清 I2C 主控位，只在 Wi-Fi 先起的顺序下安全；BLE 的 PHY 域序列
  （`phyDomainEnable`，含写 flash 的探针标记）与 XTAL trim 在 PHY 归 Wi-Fi 时仍然会跑一遍（以幂等置位为主）。

**实现记录（2026-11-27 晚，路线图 C9，`coex-verification.md` §20）。**

- **「BLE 先起」的顺序，三个单变量对照**（`-Dcoex-ble-first`）：PHY 由 BLE 的 init 打开时，时钟位都在、Wi-Fi 仍只扫到 4 个 AP——
  是标定的问题，不是时钟的（上面补记 2 的结论在时钟并集之上成立）；PHY 没开就做 controller 的 init，`bringup.init` 第 7 步停机（补记 4 更正）；
  **先按 Wi-Fi 的路径打开 PHY（`init_probe.phyEnableWifiOwned`，照 blob 在 `esp_wifi_start` 里的前两步 `_wifi_clock_enable`、
  `_phy_enable`）、再做 BLE 的 init、最后 Wi-Fi start**，Wi-Fi 照常（扫描 32 个 AP，两遍链路都通，36/36）。规则精确成一句：
  **PHY 的一次性初始化与标定必须由 Wi-Fi 的路径先做；做完之后两个 controller 的先后可以换。** 默认顺序不变（Wi-Fi 先起）。
- **BLE 的下电路径**（`-Dcoex-ble-disable`）：照 IDF `bt_controller_disable`（`esp32s31/bt.c:124-145`）拆成八步
  （`bt-blobs/src/probe.zig` 的 `DownStep`）；时钟这一半按上面的规则 2 落实——`porting.btdmLpDisableClock` 只清只属于 BLE 的位
  （`CLK_CONF1` bit16-18、`CLK_CONF` 的 ETM 与 modem 安全模块、BLE 定时器、`LPCON` 的 LP 定时器时钟），与 Wi-Fi、PHY 共用的位
  不动，时钟源写回 BLE 来之前的读数；板上三轮读数相同，Wi-Fi 与 PHY 的位一个不少。`LPCON` bit1（共存时钟）归共存核，不算
  BLE 的。**controller 的八步之间要留时间**（补记 4 作废）：连着做（1.4 ms）之后 Wi-Fi 36 秒里扫不到 AP；每一步之后空转 2.5 秒或扫一次都正常
  （28/28）。隔多久、隔在哪几步之间，没有定。
- **不开 `-Dcoex` 时的计数桩**也按 IDF 的关闭分支逐项对齐了（§20.5）：桩与胶水的 `Glue.off()` 现在是同一套值，不开 `-Dcoex`
  的镜像不再需要 `libcoexist.a`。

**补记 4（2026-11-28，路线图 C9 的续，`coex-verification.md` §20.3、§20.4.1–20.4.3）。**

- **BLE 的下电路径：上面「controller 的八步之间要留时间」作废。** 那是把两件事（八步之间 Wi-Fi 的任务有没有跑过、隔了多久）同时
  改了读出来的。单变量对照：八步连着做没有问题；失聪要的是 BLE 的下电步骤（一步不做、紧跟着扫描，Wi-Fi 正常）；同样 20 毫秒，
  让 Wi-Fi 的任务跑过就好，纯等待就聋或停在下一次扫描里。规则精确成一句：**一个射频的下电不能抢在另一个射频驱动任务的收尾之前。**
  Wi-Fi 的 blob 断开之后还要在自己的任务里放掉共存申请、放省电锁；本仓的主上下文自己就是推驱动任务的那一个，不推就撞上。真 OS 上
  驱动的任务优先级比应用高，应用拿到断开事件时收尾已经做完了。落实：`link_probe.settleAfterDisconnect()`——断开事件之后推 Wi-Fi 的
  任务，直到连续 5 毫秒里钩子与事件都没有动静（最长 200 毫秒）。默认的下电路径（八步连着做、不放间隔）28/28。链路还连着的时候
  下电（`-Dcoex-ble-down-linked`）32/32：断开之后才有那件收尾，连着时下电不需要等。撞的到底是八步里的哪一步、核或 blob 里卡住的
  是什么状态，没有查。
- **时钟源那一段是共用单元，判据分两种情形。** `HP_SYS_CLKRST_MODEM_CONF`（`0x3d` 开 / `0x25` 关）在 IDF 的依赖表里是 Wi-Fi、
  共存核、PHY、标定都依赖的单元，`modem_clock_module_disable` 按引用计数、最后一个用户放手才关（`modem_clock.c` 的
  `config_wrapper`）。本仓的下电把它写回 BLE 来之前的读数：Wi-Fi 空闲时与它自己的读数相同（IDF 自己的 station 镜像空闲时也是
  `0x25`）；Wi-Fi 还连着时下电，这个字是 Wi-Fi 正在用的 `0x3d`，写回的 `0x25` 随后被 Wi-Fi 自己改回去（一次实测链路没掉、
  ping 10/10）。所以连着时下电的判据取下电之前的读数。这与 IDF「按引用计数、不替别人写」的做法有差别，留作对照项。
- **「BLE 先起」的 `phy_deferred`：停的不是 controller 的 init，是 init 里那一句 `esp_phy_enable(2)`。** PHY 没开时 libphy 的
  `esp_phy_enable` 走「首次使能」那条路，时钟与对象都没就位。给这一句加了保护（入口用 `bt.probe.setPhyDeferred()` 明说，不看
  modem 标志——默认顺序里它也是 0）之后，BLE 的 init 与 enable 都能在 PHY 没开时做；Wi-Fi start 把 PHY 打开并标定之后，BLE 照常
  广播（35/35）。所以第二种顺序有两种：先按 Wi-Fi 的路径打开 PHY 再做 BLE（`phy_wifi_first`，BLE 立刻可用），或 BLE 先起、
  等 Wi-Fi start 之后才上空口（`phy_deferred`）。不能反的仍然只是「PHY 的一次性初始化与标定由 Wi-Fi 的路径做」。

### 5. 验证（按仓库的 L1–L4 分级；不抓空口能到 L3）

| 级 | 内容 | 判据 |
| --- | --- | --- |
| L1 主机 | glue 对照 IDF：每个钩子的转发、返回值、留空条目；回调按 type 保存并触发；乱序拒绝；适配表布局 | `components/radio-coex` 的主机测试；README 里"钩子 → IDF 源码行 → 测试"三列表 |
| L2 镜像 | `-Dcoex` 打开后链接通过且恰好两段；关闭时默认镜像逐段不变 | `image-info` 两行；逐段 SHA-256 相同 |
| L3 板侧（不抓空口） | 单射频探针镜像开 coex：`g_coex_param_ptr` 非零、打印 coex 固件与 ROM 版本（官方固件启动时就有这两行，见 `R/components/bt-blobs/logs/bt-ana-i2c-official-trace.log:59-60`）、BLE 两个回调都注册成功、`coex_wifi_request` 之后 BLE 回调被触发；随后合并镜像启动 | 串口日志 |
| L4a 真链路（只开 Wi-Fi） | 共存核开着时真实 AP 链路照常；读出 blob 在各阶段怎么用共存核、核怎么答 | `-Dcoex` 的真实链路探针（`-Dwifi-link-probe`）在 start 后、扫描后、连上、ping 结束、断开前后各打一组读数（`wifi-blobs/src/init_probe.zig` 的 `coexReadings`）：胶水两侧的状态与各钩子被调的次数、每次申请的（事件、时延、时长）与返回码、按事件的释放与 PTI、置 / 清的 Wi-Fi 状态位、核手里的状态位与调度参数。判据：`rej=0`、`last_error=-`；不开共存时链路照常（2026-11-26 的对照：胶水按 IDF 关闭分支作答、核不启动，扫描 38 个 AP、连上、ping 10/10；计数桩的镜像修掉 PTI 桩之后同样照常，`coex-verification.md` §13）；申请 / 释放的返回码按事件对得上核的静态表（只有配了硬件定时器的事件回 0）。**已有读数（2026-11-26）**，见 `docs/verification/coex-verification.md` §12 |
| L4b 真实共存（两个射频都开） | 共存的效果：BLE 不同广播间隔下 Wi-Fi 的时延与丢包、PTI 行为、`coex_status_get` 里出现 BLE 的状态位、核的硬件定时器在走、两侧的 start 回调被触发；空口上 AP 的 monitor 接口看 Wi-Fi 这边（`tools/ap-side/`），工作站的蓝牙控制器看 BLE 的广播 | 仍被 R3.3（BLE 的 synth）挡着，做法先定下来：合并镜像里先连 Wi-Fi，再起 BLE 广播，间隔 20 / 100 / 1000 ms 各一轮；每轮打 ping 10 帧的 rtt min/avg/max 与 L4a 那一组读数，和不起 BLE 的对照比。判据：每轮都没有 `STA_DISCONNECTED`、ping 不丢；BLE 的状态位非 0、硬件定时器的数值在两次读数之间变了（读 `coex_hw_timer_set` 写的那组寄存器：`0x2010F040 + 16*idx` 与 `0x2010F408 + 16*idx`，`coexReadings` 现在读的就是它们）——这两条是"核真的在仲裁"的证据，缺一条只算"两个射频同时开着"；广播间隔越短，ping rtt 的最大值越大。空口上有没有让，2026-11-27 起有设备可看（此前"没有设备"一句作废）。**2026-11-27 试了第一步（`-Dcoex-ble-adv`）**：步骤已接好。第一版在主上下文里发命令，三次上板都停在第一条命令之后——这类命令要 controller 任务在自己的上下文里处理；改成从独立栈上的发送任务里发之后，三条命令都回了 Command Complete、Status 0x00，但广播使能被接受之后板子失声（串口、落盘、AP 一侧的第二次关联都停在回包之后），当时读成"controller 任务不再让出"。**2026-11-27 晚查到了根因并修掉**：是中断风暴（`bt-blobs` 的 `intrArm` 把中断桥登记在 CLIC 输入号 24 上，trap 分发器按外部中断号 8 查），与共存核无关；修掉之后 27/27——合成器锁定位在广播使能后 35 ms 置位、15 秒后仍是它，BLE 广播着的时候 Wi-Fi 连上、DHCP、ping 10/10（100 ms 间隔，往返平均从 3.5 ms 涨到 45 ms），AP 侧记到第二次关联与四次握手，工作站的蓝牙控制器看到 `s31`。上面做法里的两条「核真的在仲裁」判据读了、都不过：五个硬件定时器在每个时点都是 `en=0`、相隔 1 ms 的两次读数相同；三组状态位（`coex_status_get` 的 wifi / ble / bt 位图，读数行里现在一并打印）对不上名字——BLE 一开始广播，`wifi_status` 与 `bt_status` 就恒为 1，`ble_status` 只在 Wi-Fi 连着时为 1，含义没有弄清。所以这一轮只算「两个射频同时开着」。还没有做的：按广播间隔（20 / 100 / 1000 ms）各一轮、PTI 行为、两侧的 start 回调（`coex-verification.md` §17.5）。**2026-11-27 上午：按广播间隔三轮加「核不启动」的对照（`coex-verification.md` §18）**。第一组判据过：20 / 100 / 1000 ms 各一轮，每遍 ping 30 帧（`-Dcoex-adv-pings`）都不丢，断开都是探针自己做的。「广播间隔越短，ping rtt 的最大值越大」不成立：三个间隔下广播那一遍的分布几乎一样（最小 27.2 ms、中位 30.5 ms、平均 45–55 ms；对照遍平均 4 ms）。空口上回显请求到应答中位 0.71 ms、没有重传，涨的在板子内部；只把核关掉（`-Dcoex-sw-off`）再跑一轮，广播时 rtt 不涨（平均 3.5 ms）——涨在共存路径上，核在、BLE 广播时板子的 Wi-Fi 每秒发十几个 QoS Null 帧（平时 1 个）。两条「核真的在仲裁」判据过了一条：上一段说对不上名字的三组状态位是读法错了（`coex_status_get` 不是读字，见 §18.4），现在直接读出来，BLE 的状态字广播时是 `0x0001`；硬件定时器改成链路的每一泵步采一次使能位，约 3 万次里 0 次——ping 这种流量下核不用定时器，这条判据在现在的流量下观察不到，要不要换成「核在不在会改变 Wi-Fi 的行为」（对照轮看得到），留待以后定。还没有做的：PTI 行为、两侧的 start 回调、Wi-Fi 有吞吐时的定时器。**2026-11-27 下午：第二组，持续的 Wi-Fi 流量与其余三条判据（`coex-verification.md` §19）**。每遍 300 帧、间隔 50 ms（`-Dcoex-adv-ping-interval-ms`），载荷 32 与 1400 字节（`-Dcoex-adv-ping-bytes`）各一轮：对照遍与广播遍都是 300/300。剩下三条判据的读数：两侧的 start 回调在 BLE enable 时各触发一次（胶水的两个跳板计数）；PTI 是每个事件的定值（e1 = 5、e9 = 7、e0 = 10……），与 BLE 是否在广播无关，变的是 blob 向核申请的次数；定时器——上面判据里的地址与位都写错了（`coex_hw_timer_set` 的基址左移 4 位后是 `0x2010F400 + 16*idx`，使能位是 `0x2010F408 + 16*idx` 的 bit0，§19.4），改正后核每接受一次事件 1 的申请就把定时器 0 装成申请的时长（1.25 µs 一个 tick）并置状态字的 bit1，「数值在两次读数之间变了」按字面过了；定时器有没有真的在数没有可读的计数器，判不了，这条留到有连接（数据信道上有流量）的时候再看。顺带抓到并修掉一处：读数函数按值拷贝统计结构、栈帧 42 KB，把 16 KiB 主栈溢出 26 KB 进 BLE 堆，一版镜像因此崩在发送任务的保存上下文上（§19.5）；合并 section 现在带主栈高水位的判据。还没有做的：时延涨在哪一段、可连接广播 |

## 验证镜像的最小组成（2026-11-27 增补）

验证某一项功能时，镜像里只编与它有关的 section。这不是省空间的小事：合并镜像自己就占 factory 分区的八成，
多带一段无关的自检就少一分余量；而且出问题时，镜像里每多一段代码就多一个嫌疑。

- **共存真链路**（两个射频 + 共存核）：只编 `coex_merged`，`-Dboot=false -Dnet=false -Dwire=false -Dwifi=false
  -Dtls=false -Dapps=false`。入口是 `scripts/build-coex-link-image.sh`：从 IDF 的归档重新生成三份对象集合、构建、
  断言恰好两段、打印体积与归属。实测 1 224 304 B（factory 分区的 79.7%）：flash 文本 945 680 B、只读数据
  164 112 B、IRAM 103 712 B。按归属（带符号表的那一份，只用来核对符号）：Wi-Fi blob 文本约 296 KB、IRAM 62 KB，
  BLE blob 文本约 358 KB、IRAM 40 KB，共存核约 6 KB，本仓的 Zig 代码文本约 210 KB、只读数据 30 KB，其余约
  125 KB 是没有符号的 blob 日志串与表。`-Dcoex-dump` 的寄存器转储另占 26 KB 文本与 9 KB 只读数据，取证时才开。
- **无线纯逻辑自检**：`tests/e2e/run_e2e.py --board --profile wifi --only <section,…>`（经 `-Donly` 只编涉及的
  section），整份 profile 留给发布前门禁。
- 默认镜像（boot + net）与各探针镜像的开关不变。

## 后果

- 正面：
  - glue 层语义有唯一依据（IDF 源码），可以逐钩子验证，不依赖射频。
  - 默认构建字节不变，现有工作态镜像不受影响。（C2 时成立：四种非 coex 镜像逐字节不变。C4 为扩窗口
    后移了 drom 基址，此后默认镜像只有重定位差异，见第 3 节的实现记录。）
  - 运行时统一解决的是"两个 blob 能否同镜像"的硬约束，与射频是否打通无关，可以先行。
- 负面：
  - 运行时统一要改动 `wifi-blobs`、`bt-blobs`、`osal` 里钉在已知正常态的代码，回归风险集中在 BT 探针镜像上，靠"默认镜像不变证明"和板级自检兜底。
  - 窗口与分区扩大后，factory `0x10000`、ota_0 `0x190000` 这些偏移要跟着改，已有日志里的偏移成为历史值。
    （2026-11-24 实际没有改分区表，这些偏移都还在；变的只有 drom 的基址。）
  - 共存的真实效果（L4b）在 BLE 打通前无法验证；只开 Wi-Fi 时能读到的是 blob 怎么用共存核、核怎么答（L4a，2026-11-26 已有读数）。本设计能保证的是胶水正确、两个控制器能同镜像启动。
  - 不开 `-Dcoex` 的镜像里 blob 调到的是计数桩，不是本组件的胶水；`_coex_pti_get` 的桩把出参写成 0 就足以让 Wi-Fi 收不到帧
    （2026-11-26，已修）。关闭分支的语义只在胶水里逐钩子对照过 IDF（L1），计数桩那边没有这层保证；同日的对照轮一度因此
    把共存核误记成 Wi-Fi 的前提。**2026-11-27 晚已对齐**（路线图 C9，`coex-verification.md` §20.5）：`_coex_init` / `_coex_enable`
    的桩不再调核，`_coex_schm_flexible_period_get` 回 1，关着 `-Dcoex` 的探针 init 不再直接调核；不开 `-Dcoex` 的镜像也就不再
    需要 `libcoexist.a`。
- 需要跟进：
  1. `radio-coex` 接进 `wifi-blobs`、`osal`、`bt-blobs`（在 `-Dcoex` 开关后面）。**已完成 2026-11-24**（路线图 C2）：三种 coex 镜像链接通过，四种非 coex 镜像逐字节不变，BLE 探针与 Wi-Fi 探针各自带着真核心上板。证据与偏离见 `docs/verification/coex-verification.md` §4。第 5 节验证表里的 L3 判据已满足前四行；"随后合并镜像启动"属于第 4 项。
  2. 运行时统一：调度器、osi、导出、堆、tick、trap 钩子六项。**已做到两棵树可同链并上板（2026-11-24，
     路线图 C3）**，实际做法与第 2 节的设计有出入，见那里的实现记录：同名导出用弱符号定提供者、堆按配额
     切分、init 不嵌套；两个切换器没有合并，`bt-blobs` 的 osi 副本没有删，trap 钩子没有改多槽。
  3. 窗口与分区扩大及板级证明；compiler_rt 死重。**窗口已扩并有板级证明；分区表未改**（理由见第 3 节的实现记录；2026-11-27 晚
     量过，最大的合并镜像是 factory 的 82.1%，仍然不用扩）；**compiler_rt 已量，没有可裁的**（第 3 节的补记）。
  4. 合并镜像启动（L3）。**已完成 2026-11-24**：合并镜像 8/8 段通过、`verdict=pass`，
     `esp_wifi_init_internal rc=0`、`bringup.init rc=0`（`logs/coex-merged-boot.log`）。
  5. PHY 与时钟域的归属：PHY 这一条已有板级证据并落进代码（2026-11-26，第 4 节补记 2）。时钟域于 2026-11-27 改成
     按单元取并集并上板（第 4 节的实现记录），事后写回已删除；BLE 的 disable 路径于 2026-11-27 晚做了并上板（同上）：时钟这一半
     成立；「controller 的八步之间要留时间」2026-11-28 更正：连着做 Wi-Fi 会聋是因为下电抢在 Wi-Fi 任务收尾之前，已修
     （断开之后先让 Wi-Fi 的任务跑到安静），默认下电路径 28/28，连着链路时下电 32/32（补记 4）。
  6. R3.1（`MAC_ST`）已拆（2026-11-25），Wi-Fi 真实链路已通（2026-11-26：连接、DHCP、ping 网关；2026-11-27 起有空口上的帧），
     L4a 已有读数（第 5 节）。L4b 有了第一条证据（2026-11-27 晚）：合并镜像里 BLE 的广播上了空口——起广播
     （`-Dcoex-ble-adv`）时"广播使能之后整机失声"的根因是中断风暴（`bt-blobs` 的 `intrArm` 把中断桥登记在 CLIC 输入号 24
     上，而分发器按外部中断号 8 查表），修掉之后合成器 35 ms 内锁定，BLE 广播着的时候 Wi-Fi 照常连接、DHCP、ping 10/10
     （往返平均 4 → 45 ms），工作站的蓝牙扫描看到 `s31`（`coex-verification.md` §17.5）。第 5 节 L4b「核真的在仲裁」的两条
     判据读了、都不过：五个硬件定时器在每个时点都是 `en=0`、相隔 1 ms 的两次读数相同；三组状态位有了读数，但位图的名字
     与读到的活动对不上，含义没有弄清。按广播间隔各一轮、PTI 行为、两侧的 start 回调还没有做。单独的 BLE 探针回归一轮，
     与基线逐段相同——那边的 synth 墙不是这个风暴。
