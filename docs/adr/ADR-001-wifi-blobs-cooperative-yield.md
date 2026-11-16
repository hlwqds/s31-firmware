# ADR-001：`wifi-blobs` 用「阻塞 = 合作式让出」代替调度器

- 状态：accepted
- 日期：2026-11-16
- 决策者：hl

## 背景

真实 Wi-Fi blob（`libnet80211.a` / `libpp.a` / …）在 `esp_wifi_init_internal` 里创建任务，
任务体是「阻塞收一条消息 → 处理 → 循环」。我们的固件没有调度器（MIE=0，单栈，无上下文切换），
所以两类实现都不成立：

1. **立即失败**（`_queue_recv` 空即返回 0）：任务体变成忙等。实测 300 次钩子预算瞬间烧完，
   CPU 被占死，主循环（EMAC 收发）永远拿不到执行权。
2. **真阻塞**（自旋等队列）：没有任何其他执行体能填队列，同样卡死。

板侧证据（`logs/wifi-task-boot.log`）：

```text
wifi-init-probe: running task[0] entry=0x2f00d012 arg=0x00000000 budget=300
wifi-init-probe: hook budget exhausted after 306 calls
wifi-init-probe:   hook[0] queue_recv a0=0x2f018820 a1=0xffffffff   ← 连续 8 条同签名
```

## 选项

1. **写一个抢占式调度器**：给每个任务分配栈、实现上下文切换、tick 中断。
   代价是几十行汇编 + 中断路径，且与「MIE=0 的裸机 bring-up 阶段」冲突。
2. **合作式让出（选定）**：`TIME_BLOCKING` 的等待变成「调用注入的 `Hooks.on_idle` 让出，
   再重查」，上限 64 次后返回失败。`on_idle` 由调用方提供，就是主循环的接缝。
3. **不用 blob 的任务，自己轮询 blob 的收发 API**：需要绕过 init 建的任务，但 init 已经建了，
   且内部状态由它自己维护，绕开等于重写驱动。

## 决定

选方案 2。关键约束：

- **让出语义对 init 路径也必须正确**：init 自己会阻塞在信号量上（实测
  `task blocked -> yielded to idle hook` 出现在 `esp_wifi_init_internal` 之前），
  而 init 仍返回 `rc=0`，这是「没改坏语义」的判据。
- **上限必须有**：没有上限时一次等待就可能永不返回；64 次是经验值（每次让出跑一遍主循环）。
- **诊断要靠预算与事件环**：`impl.budget` 归零时回调打印现场，`impl.events` 保留最近 8 次
  `(钩子 id, a0, a1)`——「它在等什么」不靠猜。
- **组件不 import 板级代码**：`Hooks` 注入（`now_us`/`fill_random`/`mac`/`on_idle`/
  `on_note`/`on_budget_exhausted`），固件侧接线。

## 后果

- 正面：任务体能真正执行自己的循环，且主循环仍有执行权；无需调度器、无中断路径改动；
  同一套机制在 init 阶段就被验证过。
- 负面：不是真并发——`on_idle` 里做的事不能依赖「任务已让出」之外的时序假设；
  64 次上限意味着「等待超时」是假超时，不能当作 FreeRTOS 的 `pdFAIL` 语义用于逻辑判断。
- 需要后续跟进：
  1. `on_idle` 目前只计数（探针）；生产路径要接 EMAC 收发（`esp_wifi_internal_reg_rxcb` /
     `esp_wifi_internal_tx`）。
  2. ~~`_task_delay` 仍是桩~~ → 已按同一语义实现（让出 + 按 `now_us` 计时，上限 64 次）。
  3. ~~任务体跑在我们的栈上~~ → 已实现两根栈的上下文切换（见下）。

## 追加（2026-11-16）：为什么最终必须有上下文切换

只做「让出」还不够。blob 的对外 API（`esp_wifi_internal_reg_rxcb` /
`esp_wifi_internal_ioctl` …）会**阻塞等待任务应答**，而任务体**永不返回**——同一根栈上两者
无法共存：先调 API 就没人跑任务（实测 `reg_rxcb` 卡住，`on_idle` 被调到 200 次上限），
先跑任务就回不到调用点。

因此新增 `src/sched.zig`：两根栈 + 一次保存/恢复 `(sp, ra, s0..s11)`。

**实现上的硬约束（都踩过）**：

1. **切换函数必须是 naked**。普通函数有编译器前导（`sp -= N`），保存下来的帧基址与 `ret`
   弹出的位置错位 N 字节 → 第一次让出后就再无下文（实测：进了任务、打印一行、卡死）。
   Zig 不允许直接调用 `callconv(.naked)` 函数，所以 `@export` 成 `s31_swap_context` 再经
   `@extern` 间接调用；naked 函数也不能引用参数名，参数按 ABI 落在 `a0`/`a1`。
2. **初始 `sp` 用 `alignBackward`**（栈向下增长）。`alignForward` 会越过分配区间最多 15 字节，
   踩到相邻 arena 块头——这种破坏是静默的。
3. **arena 只接受自然对齐请求**（`alloc` 里 `pad != 0` 就跳过该块）：要 16 字节对齐的栈就申请
   8 字节对齐，栈顶自己在 `initContext` 里对齐。

板侧自检（`logs/wifi-sched-boot.log`）：任务在自己栈上跑 3 轮、每轮让出，主上下文依次恢复，
任务返回后自动切回主上下文并打印 `sched-test: PASS`。

## 追加（2026-11-16）：合作式的边界——`esp_wifi_start` 忙等

`esp_wifi_start`（blob 符号，`ieee80211_api.o`）调用后板侧**再无任何日志**，连 idle 钩子的
每 1000 次进度行都没有：

```text
wifi-init-probe: calling esp_wifi_start (idle_calls=320)
（之后无输出）
```

它**看起来**不经过我们的信号量/队列钩子（后来证明是预算判据不足，见本文件末尾"逐行追踪"一节：
start 实际会 `zalloc(24 B)`、取三次互斥锁、`event_post(id=43)`，之后才不再调用钩子）。
反汇编确认 `wifi_init_completed` 只读状态字（不等待）、`esp_wifi_start` 先 `_wifi_zalloc`
（表 index 93）再 `ieee80211_ioctl`，所以卡点在 ioctl/状态机内部。

**逐行追踪（2026-11-16，`Hooks.on_note`）**：上面的"不经过钩子"最初是从"1000 次预算未耗尽"
推出来的，那个推断**不成立**（只证明少于 1000 次）。把 `_event_post` 从具名桩换成实现后，
`esp_wifi_start` 的完整序列是：

```text
trace zalloc      a0=0x18                 # 24 B
trace mutex_lock  a0=0x2f01c90c   ×3      # API 互斥锁
trace event_post  a0=0x2b (43)  a1=0x10   # start 事件，16 B
（之后没有任何钩子调用，也没有返回）
```

也就是说：取锁、发事件都做了，**但从未把 start 命令投进 wifi 队列**；任务停在阻塞收消息上，
谁也推进不了它。

**结论**：合作式让出能覆盖「阻塞在 OS 原语上」的一切路径（init、`reg_rxcb`、
`get_config_channel` 都已实测通过），但覆盖不了「blob 自己 spin / 等自己状态机」的路径。

### 两条后续路线（未实现，按代价排序）

1. **定时器中断抢占**（真正的修复）
   - 现状：`MIE=0`，`trap.zig` 只处理异常；`hw.nowUs` 走 SYSTIMER 读数（不产生中断）。
   - 需要：配置 SYSTIMER/mtimecmp 周期中断 → `mtvec` 指向新的 ISR → ISR 里保存
     **全部 caller-saved + callee-saved**（中断版上下文比 `sched.zig` 的 13 个字多得多）→
     切换栈 → `mret`。
   - 判据：忙等期间 idle 计数器/任务轮次持续增长；`esp_wifi_start` 返回非 `0x3007`。
2. **post 型入口**（更省事，但依赖内部结构）
   - 找到 `ieee80211_ioctl` 的消息格式，把「start」作为消息直接投进 `s_wifi_queue`，
     由任务自己处理——这会经过我们的队列钩子，合作式切换即可介入。
   - 风险：消息结构未公开，随 blob 版本漂移；只在路线 1 代价过高时采用。

在路线 1 落地前，`on_idle` 的合作式切换仍然是**正确且必要**的：它已经让 init、
`reg_rxcb`、`get_config_channel` 从"永久阻塞"变成"正常返回"。

## 追加（2026-11-16）：任务身份必须只有一个

`_task_create` 写出的 handle 与 `_task_get_current_task()` 的返回值曾经是**两个不同的全局对象**，
于是 ROM 里任何"我是不是 wifi 任务"的身份判断都是假。统一成同一个清零对象（256 B）后，
`internal_tx` 的错误码从 `0x3007`（`ESP_ERR_WIFI_CONN`）变成 `0x3002`
（`ESP_ERR_WIFI_NOT_STARTED`）——状态判断变准了，而 init 仍返回 0、`sched-test` 仍 PASS。

主机用例钉住这条不变量（handle 与 current 必须同址），避免以后又分叉。

## 追加（2026-11-16）：任务侧故障指向 PHY/coex bring-up

把 `_task_get_current_task` 改成**上下文感知**（主上下文与 wifi 任务是两个不同对象）之后，
任务第一次真正处理消息：

```text
trace semphr_give a0=0x00000000
trace queue_recv a0=0x2f01ca80 a1=0xffffffff
trace semphr_give a0=0x2f01d120
trace queue_recv a0=0x2f01ca80 a1=0xffffffff
panic: mepc=0x40017846 mtval=0x102 (a0=0x2f01d0f8)
```

两轮之后撞到同一个"未初始化上下文"故障：`ctx+12` 是 `0x102`（`ESP_ERR_INVALID_ARG`），
随后被当指针解引用。反汇编显示 `wifi_start_process` 的第一个调用是 `adc2_wifi_acquire`
（blob 里的**弱符号**，真实构建由 IDF 的 `esp_phy` 覆盖），说明 start 状态机要先把 PHY/ADC/coex
bring-up 做完才会建好那个上下文。

因此下一步的优先级是：**先 PHY/coex bring-up**（`esp_phy_init` 等价物 + eFuse 标定表 —— 目前
24 个 `est_PHY_*` 仍是零值桩），再谈定时器抢占；否则任务即使拿到 CPU 也会在这个未初始化的
上下文上崩。

## 追加（2026-11-16）：PHY 初始化本身也卡住

按 IDF 顺序（PHY 先于 wifi 任务）调用库自己的入口：

```zig
register_chipv7_phy(&phy_init_data.params, &cal_data /*1894 B 清零*/, 0 /*PHY_RF_CAL_PARTIAL*/)
```

`params` 是从 `$IDF/components/esp_phy/esp32s31/phy_init_data.c` 导出的真实 128 字节
（`CONFIG_ESP_PHY_MAX_TX_POWER=20` 代入 `LIMIT(...)` 后逐字节导出，已落库为
`src/phy_init_data.zig`）。板侧结果：**调用既不返回也不 fault**，日志停在 `internal_tx` 之后。

因此 PHY 这条线的顺序是：**先补调制解调器电源域与 PHY enable**（IDF 的 `esp_phy_enable` 在 C 层，
不在 blob 里），以及目前仍是零值桩的 24 个 `est_PHY_*` 标定表，再回来调 `register_chipv7_phy`。
在那之前，任务侧那个 `mtval=0x102` 的上下文故障也无法消除。

### 下一步的具体序列（已从 IDF 源码取出，尚未移植）

最初把"不返回也不 fault"当成"总线访问打到未上电域"的典型形态。**两次测量削弱了这个假设**：

| 测量 | 结果 |
| --- | --- |
| 先单独读它开头访问的 `0x20109c18` / `0x20100800` | 读得通（`0` / `1`），没有总线挂起 |
| 逐个调用它的 5 个前序函数 | 全部返回 |

继续二分后已经落到**单个函数**：

| 测量 | 结果 |
| --- | --- |
| `cal_mode = PHY_RF_CAL_NONE`（跳过 RF 标定） | 仍挂起 → **不是标定路径** |
| 逐个调用主体里的函数 | `phy_get_xtal_freq` ✓、`phy_get_rf_cal_version` ✓、**`phy_rf_init` 挂起** |

`phy_rf_init` 的 23 个调用里，`phy_rc_cal_init` → `phy_rc_cal` 会驱动 PHY 的 I2C master 访问
`0x20162824` —— 硬件握手，需要调制解调器/I2C 时钟在位。所以电源域/时钟重新成为第一嫌疑，
位置精确到 `phy_rf_init`。IDF 的顺序仍然是：

| 步骤 | 来源 | 动作 |
| --- | --- | --- |
| 1 | `components/esp_wifi/src/wifi_init.c:462` | `esp_wifi_power_domain_on()`（= `esp_wifi_bt_power_domain_on` 的别名，`esp_phy/src/phy_init.c:1243`） |
| 2 | `esp_phy/src/phy_init.c:453-477` | 清 `RTC_CNTL_DIG_PWC_REG` 的 `RTC_CNTL_WIFI_FORCE_PD` → 延时 10 µs → `wifi_bt_common_module_enable()` → 切 `SYSCON_WIFI_RST_EN_REG` 的 MODEM_RESET → 清 `RTC_CNTL_DIG_ISO_REG` 的 `RTC_CNTL_WIFI_FORCE_ISO` |
| 3 | `esp_hw_support/periph_ctrl.c:98` | `wifi_bt_common_module_enable()`：S31 走 `modem_clock_module_enable(PERIPH_PHY_MODULE)`（`SOC_MODEM_CLOCK_IS_INDEPENDENT`） |
| 4 | 之后 | 再调 `register_chipv7_phy` |

**已实测的一刀（2026-11-16）**：`MODEM_LPCON_TEST_CONF_REG`（`0x2010F000`）bit0 =
`MODEM_LPCON_CLK_EN`（默认 0），IDF 的 `modem_clock_module_enable(PERIPH_PHY_MODULE)` 就是开这一位。
写下去生效（`0x0 -> 0x1`）。随后按 `modem_clock_impl.c:20` 的整组依赖继续打开：

| 寄存器 | 读回 |
| --- | --- |
| `MODEM_LPCON_CLK_CONF_REG`(0x2010F018) | 写前 `0x4`（I2C_MST 已开）→ `0xf` |
| `HP_SYS_CLKRST_MODEM_CONF_REG`(0x205871E0) | **`0x25 -> 0x3d`**（`0x25` 正是 IDF 关闭值） |
| `MODEM_SYSCON_CLK_CONF1_REG`(0x20109C14) | `0x0 -> 0x38E000`（FE_80M/FE_160M/FE_APB/FE_PWDET_ADC/FE_ADC/FE_DAC） |

再把 `PERIPH_PHY_CALIBRATION_MODULE` 的独立组加进同一处写（WIFI_BB_44M(2)/WIFI_BB(3)/
WIFI_BB_80X1(7)/WIFI_APB(9)），`CLK_CONF1` 读回 **`0x38E28C`**；`phy_rf_init` **仍然不返回**。

两条排除让范围很窄：

- 模拟 I2C 主控时钟（`MODEM_LPCON.clk_conf.clk_i2c_mst_en` = 0x2010F018 bit2）**本来就是 1**——
  IDF 二级 bootloader 打开它（`bootloader_support/src/esp32s31/bootloader_esp32s31.c:56-57`）。
- S31 定义 `SOC_MODEM_CLOCK_IS_INDEPENDENT`，且没有 `SOC_PM_SUPPORT_WIFI_PD` /
  `SOC_PM_MODEM_PD_BY_SW` → 这颗芯片的 `esp_wifi_power_domain_on` **就是**上面那组时钟写，
  没有 RTC_CNTL force-PD 步骤可试。

**结论**：时钟这条线到此为止（全部打开、读回确认）。

进一步把 `phy_rf_init` 里**无参**的被调函数逐个单跑（反汇编确认无参），挂起点又缩小一级：

```text
phy_get_xtal_freq       returned
phy_get_rf_cal_version  returned
phy_open_fe_bb_clk      <-- 挂在这里
```

`phy_open_fe_bb_clk` 不在我们链接的任何归档里、也不是我们的桩——它是 **ROM 函数**
（`boards/esp32s31-coreboard/linker/rom_syms.ld:115`：`phy_open_fe_bb_clk = 0x2f80131c`）。
所以自旋在 ROM 代码内部，等一个我们还没制造出来的硬件状态位。

**ROM dump 结果（2026-11-16）**：先核对了地址来源——IDF 自己的
`components/esp_rom/esp32s31/ld/esp32s31.rom.phy.ld:96` 就是
`phy_open_fe_bb_clk = 0x2f80131c`，与 `rom_syms.ld:115` 完全一致，所以之前的二分有效。

dump 出来的第一个字 `0x3a52206f` 看着像 ASCII（"o R:"），实际是因为**这一段是 `j` thunk 表**：
每 4 字节一条 `jal x0, <target>`（都以 `0x…206f` 结尾）。解码第一条得 `j 0x2f823ec0`，那里是真代码：

```asm
2f823ec0  lui  a5, 0x20100      # 0x20100000
2f823ec4  addi a4, zero, 0x1e7
2f823ec8  sw   a4, 0x400(a5)    # 0x20100400 = 0x1E7
2f823ecc  lui  a4, 0x20101
2f823ed0  lw   a5, -2048(a4)    # 0x20100800（我们之前读到 0x1）
2f823ed4  lui  a3, 0x20704
2f823ed8  ori  a5, a5, 3
2f823edc  sw   a5, -2048(a4)    # 置 bit0|bit1
2f823ee0  lui  a5, 0x20108
...
2f823ee8  jalr a7, ...          # 间接调用另一个 ROM 例程 —— 自旋在这里
```

**更正**：把 dump 出来的字按 RV32 完整解码后，`phy_open_fe_bb_clk` 其实是**直筒代码**——没有循环、
没有 `jalr`，就是四次寄存器写然后 `ret`：

```asm
sw   a4, 1024(a5)    # 0x20100400 = 0x1E7
lw   a5, -2048(a4)   # 0x20100800
ori  a5, a5, 3
sw   a5, -2048(a4)   # 0x20100800 |= 3
sw   a4, -896(a5)    # 0x20107C80 = 0xFFFFFFFF
lw   a5, 28(a3)      # 0x2070401C
or   a5, a5, 0x40000F
sw   a5, 28(a3)      # 0x2070401C |= 0x0040000F
ret
```

逐条复现（每条写前打日志）后，停点确定：

```text
write 0x20100400    ok
rmw   0x20100800    ok
write 0x20107C80    <-- stall
```

`0x20107C80` = `MODEM_BASE + 0x7C80`，即 **WiFi BB** 寄存器窗口。再读
`MODEM_SYSCON_CLK_CONF_POWER_ST_REG`（0x20109C0C，`MODEM_APB[31:28]` / `MODEM_PERI[27:24]` /
`WIFI[23:20]`）：

```text
CLK_CONF_POWER_ST=0x00000000  apb=0  peri=0  wifi=0
```

**三个域全部报 0** —— 使能位置上了，但域没真的上电，所以 BB 窗口的写 stall。
缺的是"上电"那一半：`MODEM_SYSCON_CLK_CONF_FORCE_ON_REG`(0x20109C08) /
`MODEM_LPCON_CLK_CONF_FORCE_ON_REG`(0x2010F01C) 的 force-on 位，以及/或 PMU 电源域；
设好后先轮询 POWER_ST 的 WIFI nibble 非 0，再碰 BB 窗口。

**更正（此前写错）**：S31 **有**调制解调器寄存器头，位置是
`components/soc/esp32s31/include/modem/`（不是 `register/soc/`）：
`MODEM_BASE=0x20100000`、`MODEM_PWR_BASE=0x2010D000`、`DR_REG_MODEM_LPCON_BASE=0x2010F000`、
`DR_REG_MODEM_SYSCON_BASE=0x20109C00`。另外 `0x20162824` 是给 PHY 的 I2C master 用的
**RF 寄存器地址**，不是 CPU 地址——从 CPU 读它会 load access fault（已实测 `mtval=0x20162824`）。

另一条独立可能：PHY 标定本身可能依赖中断（`MIE=0` 下永远等不到），这与 §"定时器中断抢占"
是同一件事的两面——先做电源域/时钟，若仍挂起，再开中断路径。

### 新故障的成因（已解码，2026-11-16）

force-on 之后 PHY 继续跑，撞到 `mepc=0x2f82625a`、`mtval=0xa4`。把 ROM 该处 dump 出来解码：

```asm
2f826250  sw  s0, 24(sp)
2f826252  lw  a5, 164(a5)     # 0xA4 == 164 → a5 是 0，读 0x0+0xA4 → load access fault
```

继续往前 dump 到函数入口，`a5` 的来源已经确定：

```asm
2f82623a  addi sp, sp, -32
2f82623c  sw   s2, 16(sp)
2f82623e  lui  s2, 0x2f080
2f826242  lw   a5, -960(s2)     # → 0x2f07FC40（SRAM 里的全局指针）
...
2f826252  lw   a5, 164(a5)      # a5 = 0 → 读 0xA4 → load access fault
```

当时记成"根因是 `0x2f07FC40` 为空"。**这个结论被后续实验推翻了**：那个空指针是**手工二分**造成的
——把 ROM 的 PHY 函数逐个单独调用会跳过 ROM 自己的初始化顺序，本该先填好的全局当然还是 0。

把手动二分关掉（`const manual_bisect = false`）、只跑真实路径后，**PHY 入口返回了**：

```text
fe_bb writes done
register_chipv7_phy(NONE) rc=1 (cal_data 1894 B)
```

所以这条线的最终结论是：**force-on 位 + 时钟使能之后，`register_chipv7_phy` 不再卡死**。
（诊断纪律：手工乱序调用 ROM 函数得到的故障不可直接当结论——先跑真实路径。）

之后是一个新的、与 PHY 无关的故障：`illegal instruction`，`mepc=0x2f01c9d4`（SRAM）、
`ra=0x40017876` —— 执行流跳进了 RAM，说明有一次调用走了坏函数指针。

### 新故障的调用点（已定位，2026-11-16）

`illegal instruction` 的 `ra=0x40017876` 落在本仓镜像里，反汇编该处：

```asm
40017870  mv   s1, a0
40017872  lw   a0, 4(s0)     # 参数来自 s0+4
40017874  jalr a5            # 通过 a5 调用
40017876  lbu  a4, 8(s1)     # ← ra 回到这里
```

即又是一次"从上下文结构里取函数指针再调用"（和之前 `ctx->fn(ctx)` 同型），而这次的指针值落在
**0x2f01c9d4 —— 我们 arena 的地址范围**，所以跳进数据区、报非法指令。

这个调用点与更早那次 `mtval=0x102` 的故障是**同一个派发函数**（入口 `0x40017836`）：

```asm
4001783a  lw  s0, 12(a0)     # ctx = *(a0+12)
40017846  lw  a5, 0(s0)      # fn = *(ctx)
40017848  bnez a5, 0x40017870
40017872  lw  a0, 4(s0)      # arg = *(ctx+4)
40017874  jalr a5            # fn(arg)
```

区别只在"拿到的是什么"：上次 `*(ctx+12)` 是 `0x102`（读到相邻 `.bss`），这次 `ctx` 有效但
`*(ctx)` 是一个落在 SRAM（约 0x2f01c9d4）的值——也就是说**这张"函数表"的第一项不是代码指针**。

**这个函数已经定位到符号**：把 6 字节指令序列按**小端**（`aa84 4840 8297`）在全部 105 个 blob
对象里搜，唯一命中 **`ieee80211_ioctl.o`**，包含它的符号是 **`wifi_ipc_process`**。

也就是说：这是 blob 的 **IPC 消息派发**——它从消息里取出一个"处理函数指针"再调用。坏指针落在
我们的 arena 范围，说明这条消息携带的指针来自我们的缓冲区（或消息在入队/出队时被弄坏了）。

两条线索都试过，结论是否定的：

```text
cal_data    = 0x2f011680
wrapper     = 0x2f01df04     # _wifi_create_queue 返回的包装体
inner queue = 0x2f01d8a0
called      = 0x2f01c9e4     ← 三个都不匹配
```

**更正（关键）**：把每次运行的地址对齐后，规律是确定的：

| 运行 | `cal_data` | `mepc`（被调地址） | 差值 |
| --- | --- | --- | --- |
| A | 0x2f011680 | 0x2f011674 | **-12** |
| B | 0x2f011690 | 0x2f011684 | **-12** |

也就是说 blob 调用的"函数指针"**稳定等于 `cal_data - 12`**——不是随机 SRAM，而是**从我们的标定缓冲区
派生出来的一个指针**被当成了代码地址。（`_queue_send` 载荷追踪显示消息里是小整数，不是指针；
`arena_state.describe()` 也确认该地址不在 arena 里——它就是我们自己的静态区。）

所以真正的结论是：**ROM 把 `esp_phy_calibration_data_t` 当成有明确布局的结构来用**，而我们传的是
零/0xA5 填充的裸缓冲；它从中取出（或据此算出）的"函数指针"自然不是代码。下一步是把 IDF 的标定
数据真正做出来：`ftm_load_calibration.c` 的 eFuse 读取 + 24 张 `est_PHY_*` 表，按 IDF 的偏移铺进
`cal_data`，而不是填空。

下一步的方向因此改成：跟踪 blob 的分配（`_wifi_malloc/_zalloc` 的返回地址与大小）并在故障后
扫描这些缓冲区的首字，找出哪一个等于 `0x2f01c9e4` 的持有者；或者直接反汇编
`wifi_ipc_process` 的调用者，看它把什么当作消息传进来。

### 对 ctx 四字的解读（下一步假设）

```text
ctx[0]=0x2f011684 (= cal_data-12)   ctx[1]=0x2f01c9e0
ctx[2]=0x2010a000                   ctx[3]=0x20101000
```

后两项是调制解调器寄存器地址，前两项一个指向我们的静态区、一个指向 SRAM——这不像回调表，更像一张
**寄存器访问描述符**。而描述符在**主栈**上（`s0=0x2f07ac60`），派发却发生在**任务栈**上
（`sp=0x2f01c950`）。

据此最自然的解释：主上下文（init/start 路径）在**栈上**构造了这张描述符，把它的**指针**塞进
8 字节的队列消息交给任务；任务取出来派发时，第一个字段（"操作函数"）已经不是代码地址了。

下一步验证方式：在 `_queue_send` 里记录"载荷是 SRAM 指针且落在主栈范围"的消息（我们已经把载荷首字
打进 trace），看是否正好有这一条；若有，就是"栈上描述符被异步消费"的经典错误，修法是在发送方把它
放到静态/堆上（或由我们在钩子里复制一份）。

### 该假设被否掉（2026-11-16）

把 trace 改成同时记录 `queue_send`（id 5，`a1` = 载荷首字）与分配（id 13）后：

```text
trace queue_send a0=0x2f01d940 a1=0x00000006   ×3
```

**没有任何一条消息携带主栈指针**（载荷都是小整数 6）。所以"栈上描述符通过我们的队列传给任务"
不成立——那条通道要么是 blob 内部的队列/全局，要么是别的机制。

下一步：反汇编 `wifi_ipc_process` 的**调用者**，看它的 `a0`（消息指针）来自哪个全局；那才是这条
描述符真正的传递路径。

### 调用者已定位到对象文件（2026-11-16）

`wifi_ipc_process` 定义在 `ieee80211_ioctl.o`，**引用它的是 `ieee80211_api.o`**（`nm` 查 `U`）——
也就是 `esp_wifi_init_internal` / `esp_wifi_start` 那一侧。结合 `s0` 落在主栈（`0x2f07ac60`），
可以确定：描述符是在**主上下文的栈上**构造的，随后由 blob 内部的路径交给任务去派发（我们钩子里
看到的队列消息载荷只有小整数 6，说明这条通道不经过我们的队列实现）。

下一步：在 `ieee80211_api.o` 里找调用 `wifi_ipc_process` 的那一处（`objdump -dr` 搜重定位），
看它把哪个栈对象/全局当作消息传进来——那就是"第一字段为什么是 `cal_data - 12`"的答案。

### IPC 消息布局（从 `ieee80211_api.o` 反汇编读出来的，2026-11-16）

`esp_wifi_start` 一侧在栈上构造一条 24 字节消息再提交（`.L1180`）：

```asm
li   a4, 49                     # 0x31 = 消息类型/命令
sb   a4, 0(a0)                  # msg[0]  = 0x31
lui  a4, wifi_ipc_process
sw   a4, 4(a0)                  # msg[4]  = &wifi_ipc_process   ← 处理函数
li   a4, 1
sh   a4, 8(a0)                  # msg[8]  = 1（u16）
sb   zero, 10(a0)               # msg[10] = 0
sw   s1, 12(a0)                 # msg[12] = s1（指针）
sw   zero, 20(a0)               # msg[20] = 0
auipc t1, ...; ieee80211_ioctl(...)
```

而派发函数的形状是 `ctx = *(msg+12); fn = *(ctx); fn(*(ctx+4))`。把两者对上：
`msg[12]` 指向的结构，其 `[0]` 是真正被调用的函数、`[4]` 是参数。

实测 `msg[12]`（= 故障时的 `s0`）落在主栈，而 `ctx[0]` 是 `cal_data - 12`——也就是说
**那张 24 字节消息里 `msg[12]` 指向的栈对象，其第一个字段被填成了 `cal_data - 12`**。
`msg[12] = s1` 的来源也读出来了：这条消息由 **`esp_wifi_ipc_internal(a0, a1)`**（`ieee80211_api.o`）
构造，其中 `s1 = a0`——就是**调用者传进来的第一个参数**。所以 `ctx` 不是它自己造的，而是**调用者给的**：

```asm
esp_wifi_ipc_internal:
  addi sp, sp, -32
  beqz a0, .L1187          # a0 为空就报错
  lw   a5, 0(a0)           # 检查 a0[0]
  mv   s1, a0              # s1 = a0（调用者的上下文）
  mv   s0, a1
  call wifi_init_completed
  lw   a5, 372(g_osi_funcs_p)   # _wifi_zalloc
  li   a0, 24
  jalr a5                  # 分配 24 字节消息
  ...填 msg...
  sw   s1, 12(a0)          # msg[12] = 调用者的 a0
  call ieee80211_ioctl
```

所以下一步变成：找**谁调用 `esp_wifi_ipc_internal`**，以及它传进来的 `a0` 是什么（其首字为
`cal_data - 12`）。那就是整条链的起点。

### "把阻塞等待做成真等"这个修法被实测否掉（2026-11-16）

按"API 返回后栈帧被复用"的解释，把 `TIME_BLOCKING` 的 take/recv 改成**真的等到被 give**
（每次让出后重查，5 s 时钟上限）。板侧结果不是修好，而是**活锁**：

```text
wifi-init-probe: idle_calls=10000 in_task=false hooks=16
...
wifi-init-probe: idle budget exhausted (20001), halting
```

`hooks` 一直是 16（没有任何新的钩子调用），说明**任务侧也在等**：主上下文等 ack，任务等消息，
两边互相让出、谁都不前进。所以"真等"在这里不是答案——ack/消息的**生产者**本身缺失。

已回退成有界让出（并在代码里写明这次实测结论，避免下次重复）。真正的下一步是查清
"谁应该 give 这个 ack / 谁应该往任务队列投消息"。

### 根因链已闭合：ack 的 `_semphr_give` 被用**空句柄**调用（2026-11-16）

把 trace 扩到 `semphr_take(0)`/`give(1)` 之后，IPC 路径的完整序列是：

```text
trace semphr_take a0=0x2f01dfe0 a1=0xffffffff   # API 等 ack（BLOCKING）
trace queue_send  a0=0x2f01d940 a1=0x00000006   # 投递消息（载荷 6）
trace semphr_take a0=0x2f01dfe0 a1=0xffffffff
trace queue_send  a0=0x2f01d940 a1=0x00000006
trace semphr_take a0=0x2f01dfe0 a1=0xffffffff
trace queue_send  a0=0x2f01d940 a1=0x00000006
trace semphr_give a0=0x00000000 a1=0x00000000   # ← give 的句柄是 NULL！
```

`_semphr_give(NULL)` 在我们的壳里直接 `return 0`（静默丢弃），所以那个 ack **永远不会被 give**：
API 的 take 超时返回 → 栈上的描述符被回收 → 任务派发到过期内容 → 非法指令。

所以真正的根因是：**blob 用一个空句柄去 give ack**（它读的那个全局/字段没有初始化）。
注意一个关键不对称：**take 侧的句柄是有效的**（`0x2f01dfe0`），而 **give 侧传的是 0**。说明这是
两个不同的变量——take 用一个（已初始化），give 用另一个（从未被赋值）。

**已加日志并抓到调用者**：在 `_semphr_give` 里对 null 句柄记录 `@returnAddress()`：

```text
trace semphr_give a0=0x00000000 a1=0x2f00d70c   # a1 = 调用者 ra
```

`0x2f00d70c` 落在 **`.iram_blobs`**（blob 的 IRAM 代码），反汇编该处：

```asm
2f00d6fe  sw   ra, 60(sp)
2f00d702  lui  s1, 0x40104
2f00d706  lui  s2, 0x2f012
2f00d70a  jalr a5            # ← 通过表指针调用 _semphr_give
2f00d70c  li   s4, 0          # 返回地址
```

也就是说 **blob 自己的 IRAM 任务代码**在 give 时传了 null。

**但这个 null 更可能是症状而不是根因**（修正此前"根因链闭合"的说法）：take 失败（我们的有界让出
返回 0）之后，blob 走**取消/错误路径**，用一个空句柄 give 掉；真正缺的仍然是"任务为什么没有 ack"。

把 `queue_recv`(id 4) 也纳入追踪后，同一份日志里的**顺序**给出了答案：

```text
take(dfb8) → send(6)      # API 发第一条
take(dfe0) → send(6)      # 第二条
take(dfe0) → send(6)      # 第三条
take(dfe0) → give(NULL)   # API 放弃（take 超时）
queue_recv(0x2f01d940, BLOCKING)   # ← 任务到这时才第一次进入 recv
```

两个关键事实：

1. **recv 的句柄与 send 的句柄相同**（`0x2f01d940`）——队列通道没错；
2. **任务直到 API 放弃之后才进入 recv**——也就是说 API 阻塞等待期间，`on_idle` 的上下文切换
   并**没有**把任务真正推进到"处理消息"那一步。

所以剩下的问题收敛成一句：**API 的阻塞等待期间，为什么任务没有被调度到能取走消息？**
下一步该看 `idleHook` 的 `in_task`/`task_ctx_ready` 状态与任务的 `spins` 计数（任务可能在自己的
有界 recv 里先把 64 次让出烧完了）。

### 为什么还不能直接按字节反查（记录方法学）

试过在 blob 对象里按 `lui s1,0x40104` / `lui s2,0x2f012` 的字节模式定位那个 null-give 调用者，
**搜不到**：链接期把这些 `lui` 的立即数重定位成了最终地址，对象文件里的占位值与镜像里的不同。
所以对这类"绝对地址立即数"的代码，字节模式匹配只对**未重定位的相对指令**（如之前那次
`mv s1,a0; lw a0,4(s0); jalr a5`）有效。

要继续，只有两条路：

1. 用链接后的镜像地址反查 `.iram_blobs` 里的函数归属（需要 blob 的段内符号/`.symtab`，我们目前没有）；
2. 在 `_semphr_give` 里记录**调用链**（`@returnAddress()` + 再上一层的 `s0`/`ra`），用运行时数据定位。

### 关于"任务没被调度"的进一步读法（2026-11-16）

trace 里 **`queue_recv` 只出现一次**。结合我们的实现（`recv` 的阻塞分支会在**内部**让出 64 次再返回 0），
最可能的解释是：

1. 任务第一次 `recv` 时队列**还是空的**（三条消息是在它之后才发出的），它在内部让出 64 次；
2. 那 64 次让出把控制权交回主上下文，主上下文的 `take` 也在这段时间里把自己的 64 次烧完；
3. 双方各自"有界让出"的次数用尽 → 主上下文先返回 0 → blob 走取消路径 give(NULL)；
4. 任务随后才重新 `recv`（日志最后一行），此时消息已在队列里——但 API 已经放弃了。

也就是说：**两边的有界计数互相消耗**，谁都没等到对方。修法方向不是"再调大上限"，而是让**任务在
让出时不要消耗自己的配额**（例如 recv 的阻塞分支不设 64 次上限，而由 `on_idle` 的调度器决定何时
回到主上下文），或者让 API 的等待与任务的等待**共享**同一个时间预算。

### 一个反直觉的观测（待解释，2026-11-16）

在 `idleHook` 里加了"任务就绪后的前 12 次让出"日志（`post_ready_idles`），**一行都没有出现**——
也就是说：`esp_wifi_start` 里那个 `TIME_BLOCKING` 的 take 期间，`on_idle` **根本没有被调用过**。

这与"take 的阻塞分支会调 `on_idle`"直接矛盾，可能的原因：

1. 那个 take 走的是**别的分支**（例如 `blocking` 不是 `time_blocking`，或 `count > 0` 直接成功）；
2. 或者 `on_idle` 在 take 之前就被别的路径清掉了（`setHooks` 之后再没被覆盖，理论上不会）。

下次直接用日志把 take 的三个入口条件（`count`、`blocking`、是否调了 `on_idle`）打出来即可定案；
在此之前，不要基于"take 会触发让出"这个假设继续推理。

### 改序之后的进展：IPC 往返已经通了（2026-11-16）

任务先启动、再调 API 之后，seam 探针那几次调用**完整跑通了**：

```text
trace queue_recv a0=0x2f01d940 a1=0xffffffff   # 任务取消息
trace semphr_take a0=0x2f01dfe0 a1=0xffffffff
trace semphr_give a0=0x2f01dfe0 a1=0x00000000  # ← ack 用**有效句柄** give 了
```

也就是说描述符 → 队列 → 任务处理 → ack 这条链**是通的**（句柄 `0x2f01dfe0` 非空，与之前的
`give(NULL)` 形成对照）。

现在停在下一处：`esp_wifi_start` 自己那次 take：

```text
calling esp_wifi_start (idle_calls=197)
trace alloc  a0=0x18 a1=0x2f01dfb8
trace queue_send a0=0x2f01d940 a1=0x00000006
trace semphr_take a0=0x2f01dfe0 a1=0xffffffff
（此后 45 s 无输出，trace 只用了 52/200 行，不是被截断）
```

消息已经入队（`queue_send` 在 take 之前），但任务在 start 的等待期间**没有再 recv**——与之前
"take 期间任务未被调度"的现象同型。下一步就是把 `idleHook` 在 start 期间的实际调用情况记下来
（`in_task`/`task_ctx_ready`/`on_idle` 是否被调用），这次要放在**任务就绪之后**计数。

### start 期间的让出诊断：确实发生了交换，然后进入乒乓（2026-11-16）

在 `idleHook` 里按"任务就绪后的次数"计数（不依赖 `idle_calls` 的累计值），日志终于出现了：

```text
swap#5 in_task=true
calling esp_wifi_start (idle_calls=197)
trace semphr_take a0=0x2f01dfe0 a1=0xffffffff
swap#6 in_task=false          # start 的 take 调了 on_idle，并切到了任务
（之后没有新的 recv/send 行）
```

所以**交换确实发生了**（不是"没调度"）。此后进入的是乒乓：任务在自己的 `recv` 里让出（`in_task=true`）
→ 回到主上下文 → take 再让出（`in_task=false`）→ …… 两边各自消耗 64 次配额，谁都不前进。

问题因此变成：**任务那次 `recv` 为什么没有把队列里已有的消息取走？**（`queue_send` 在 take 之前
已经成功投递过一条 cmd=6 的消息。）下一步该在 `recv` 入口把 `self.count`、`out.len`、`item_size`
三个值打出来——如果 `out.len != item_size`，我们的实现会**直接返回 0 而不消费**，正好造成这种乒乓。

### recv 本身是好的（2026-11-16）

在 `recv` 入口把 `count` 与 `item_size` 打出来后，假设被否定：

```text
trace queue_recv ...
trace recv_probe a0=0x00000001 a1=0x00000008   # count=1、item_size=8 → 第一次就取到了
trace queue_recv ...
trace recv_probe a0=0x00000000 a1=0x00000008   # 之后 count=0 → 消息确实被消费
```

所以**队列收发与 item_size 都没问题**，任务也确实把消息取走了。`calling esp_wifi_start` 之后
不再出现 `queue_recv` —— 说明任务此刻阻塞在**别处**（很可能是它自己的一次 `semphr_take`），
而不是在等消息。

下一步：把 `semphr_take` 的句柄也纳入同一份 trace（已经在内），确认 start 期间任务停在哪一个
`take` 上；那一个就是"谁该给它"的答案。

### 决定性观测：切到任务后它**再也不让出**（2026-11-16）

把 swap 日志的上限提到 24 条并带上钩子计数：

```text
swap#1 in_task=true  hooks=106
swap#2 in_task=false hooks=112
...
swap#5 in_task=true  hooks=124
calling esp_wifi_start (idle_calls=197)
swap#6 in_task=false hooks=7      # 事件环在 start 前被重置，所以计数回到 7
（之后再没有 swap#7）
```

`swap#6` 是 start 的 take 让出、把控制权交给任务的那一次。**此后没有任何 swap**，也没有新的钩子
调用——也就是说：**任务一旦拿到 CPU，就再也没让回来**，它在 blob 代码里自旋/长循环，且不经过任何
OSI 钩子。

这解释了为什么主上下文的 `take` 永远等不到 ack：不是 ack 没被给，而是**任务根本没回到能 give 的位置**。

下一步：需要知道任务卡在哪个 PC。可选手段：(a) 用定时器中断采样 PC（同时把 trap 的中断分支改成
返回，而不是停机）；(b) 若它在等某个硬件状态，会在 trap 里显形。这也把"中断路径"从"以后再说"
变成了**当前必需的下一步**。

### 中断采样的具体方案（下一步，未实现）

目标：在任务不让出的情况下抢回 CPU，采样它的 PC，定位那段"无钩子自旋"。

1. **时钟源**：SYSTIMER 周期目标中断（IDF 的 `esp_timer` 在 S31 上就是用它），或机器定时器。
2. **使能**：`mie` 对应位 + `mstatus.MIE`；CLIC 输入使能（S31 用 CLIC，`mcause` 高位=中断、低 6 位=输入号）。
3. **ISR**：读 `mepc` 存进环形缓冲（不打印、不切换），然后 `mret` 返回；采样 N 次后在主上下文打印。
4. **帧**：现有 trap 帧已保存 `sp`/`s0`；中断返回还需要恢复 `s0..s11`（这一项之前只在故障路径用到）。
5. **判据**：采样里若 PC 集中在一个小范围（blob 的某个函数），那就是自旋点；若分散，说明是长循环而非死等。

这一项同时是"定时器抢占"的前置——做完采样就能决定是否直接把抢占用于调度。

### 中断采样：trap 侧已就绪，但**没有中断源被武装**（2026-11-16）

改动（已落库）：

- `trapDispatch` 现在对**中断**只做采样（前 8 次直接打印 `mepc`），然后 `return`——asm 里原有的
  恢复路径（`mepc`/`mstatus` + 寄存器 + `mret`）直接可用；异常仍然停机。
- `hw.enableInterrupts()`/`disableInterrupts()`（`csrsi/csrci mstatus, 8`）。
- 探针在切到任务前打开全局中断。

板侧结果：**没有任何 `irq-sample` 行**——也就是说 `mstatus.MIE=1` 还不够，**没有任何中断源被武装**
（定时器未启动、CLIC 输入未使能）。

所以下一步很明确：自己武装一个周期定时器。本仓的时间基是 **TIMG0 T0**（`0x2058_0000`，
ch15/ch17 实测，1 MHz），所以最省事的路径是：

1. 用 T0 的 alarm 寄存器（`timg0 + 0x10/0x14`）设一个周期比较；
2. 使能 T0 中断位（`timg0 + 0x70` 一带的 int_ena）与 **CLIC 输入**（`DR_REG_CLIC_BASE = 0x1080_0000`）；
3. `mie` 对应位置位（配合已打开的 `mstatus.MIE`）；
4. ISR 里只采样 `mepc`（前 8 次打印已在 `trapDispatch` 里）。

**进展与新的阻塞点（2026-11-16）**：

- 探针原先**没有初始化 TIMG0 T0**，`nowUs()` 恒为 0（实测 `timer 0 -> 0`）——已补 `hw.initTimer()`，
  现在 `timer 278417 -> 278419` ✓（时间基正常）。
- 武装后读回：`ena=0x1`（T0 中断已使能）、`alarm=now+2000` ✓、`clic=0x1fc00100`（IE 位已置）、
  `mstatus=0x2009`（MIE=1 ✓）、`int_st=0x0`（此刻尚未到点，符合预期）。
- 补上 T0 config 的 **alarm 使能位（bit10）** 之后，`int_st=0x1`——**外设已经拉起了中断** ✓，
  但**仍然没有 `irq-sample`**（CPU 没有取这个中断）。

`mtvec` 是**直接模式**（低 2 位 = 0，见 `firmware/src/start.zig:170`），所以向量模式不是原因。
**根因找到了：缺中断矩阵路由。** `ETS_*_INTR_SOURCE` 是**源号**，不是 CPU 输入号；源必须先经中断
矩阵映射到某个 CPU 输入。S31 的寄存器是
`INTERRUPT_CORE0_TIMERGRP0_T0_INTR_MAP_REG = 0x2058_5000 + 0x64`（低 6 位 = CPU 输入号）。
补上 `hw.routeT0Interrupt(25)` 之后，**采样立刻工作**：

```text
irq-sample #0 input=25 mepc=0x400490ca
... （8 次，PC 完全一致）
```

反汇编 `0x400490ca` 附近很说明问题：

```asm
400490be  sw   a1, 100(s7)     # 0x10801064 = CLIC ctrl for input 25
400490c2  lui  a0, 0x2000
400490c6  csrs mie, a0         # mie bit 25
400490ca  auipc ra, 0x1
400490ce  jalr -280(ra)        # → 0x40049fb2
```

也就是说 **blob 自己就在配置 TIMG0_T0（CLIC 输入 25 + `mie` bit25）**——它把这颗定时器当自己的 tick
中断用。我们的采样器正好落在它的配置代码上。

另外确认了一件事：**T0 是电平中断，ISR 必须清 `int_clr`（`timg0+0x78` bit0）并重设 alarm**，
否则 `mret` 后会立刻重入（第一版没清，看到的是中断风暴）。

**输入号**（`components/soc/esp32s31/include/soc/interrupts.h` 的枚举顺序，从 0 起）：

| 源 | 编号 |
| --- | --- |
| `ETS_TIMERGRP0_T0_INTR_SOURCE` | **25** |
| `ETS_SYSTIMER_TARGET0_INTR_SOURCE` | **33** |

CLIC 基址 `DR_REG_CLIC_BASE = 0x1080_0000`、控制区 `0x1080_1000`。所以剩下的实现就是：
arm T0 alarm（`0x2058_0010/0x2058_0014`）→ 使能 `timg0 + 0x70` 的 T0 int_ena →
CLIC 输入 25 使能 + `mie` 置位 → ISR 采样（`trapDispatch` 已就绪）。

### 意外收获：blob 自己的 tick 设置与我们手写的一模一样（2026-11-16）

把采样 PC 所在的函数完整读出来（`0x40049048` 起），发现它就是 **blob 自己的 tick 初始化**：

```asm
4004907e  csrsi mstatus, 8      # 开全局中断
40049082  lui  a0, 0x20585       # TIMG0 基址
40049086  li   a1, 25
40049088  sw   a1, 100(a0)      # 0x20585064：中断矩阵把 TIMG0_T0 路由到 CPU 输入 25 ✓
4004908c  lw   a0, 0(s0)
4004908e  ori  a0, a0, 1024     # t0config 的 alarm 使能位 ✓
40049092  sw   a0, 0(s0)
40049094  jal  0x40049fb2       # 读计数器
4004909c  addi a2, a0, 2000     # +2000 µs
...
400490be  sw   a1, 100(s7)      # 0x10801064：CLIC 输入 25 的 ctrl 字
400490c2  lui  a0, 0x2000
400490c6  csrs mie, a0          # mie bit 25
400490ca  jal  0x40049fb2       # 再读计数器
```

**这四步与我手写的 `routeT0Interrupt` / alarm / CLIC IE / mie 完全一致**——等于 blob 亲自确认了这套
配置是正确的（也解释了为什么补上矩阵路由后采样立刻工作）。

采样 PC 一直落在这个函数里，说明**它在被反复调用**——即 blob 在循环里重建 tick（或该函数被某个循环
调用）。这给了下一步一个很具体的入口：看 `0x40049048` 的调用者，以及它为什么会被重复进入。

### `int_clr` 偏移写错导致中断风暴；修好后采样指向一个 ROM 辅助函数（2026-11-16）

S31 的 TIMG 偏移是 `int_ena=+0x70`、`int_st=+0x78`、**`int_clr=+0x7C`**
（`soc/esp32s31/register/soc/timer_group_reg.h:649/701/727`）。第一版把"清中断"写到了 `+0x78`
（那是**状态**寄存器），于是中断永远不清 → 中断风暴 → 8 次采样全部落在同一个 PC。

改成写 `+0x7C` 之后，采样立刻变得有意义：

```text
irq-sample #0 input=25 mepc=0x400490ca
irq-sample #1 input=25 mepc=0x2f83efda
irq-sample #2 input=25 mepc=0x2f83efd2
irq-sample #3 input=25 mepc=0x2f83efda
...
```

后 7 次集中在 **0x2f83efd2..0x2f83efde**（ROM）。dump 该处并反汇编：

```asm
2f83efca  lui  a5, 0x20
2f83efce  addi a5, a5, 906      # a5 = 0x2038A
2f83efd2  add  a0, a0, a5
2f83efd4  slli a0, a0, 0xc      # a0 = (idx + 0x2038A) << 12
2f83efd6  lw   a0, 28(a0)       # 读该外设的 +28
2f83efd8  srli a0, a0, 0x10
2f83efda  zext.b a0, a0         # 取 [23:16] 这个字节
2f83efde  ret
```

这是一个**"读某外设寄存器 +28 的 [23:16] 字段"的 ROM 辅助函数**。任务在反复调用它——也就是在
**轮询某个外设的状态位**。下一步：找它的调用者（谁在循环里调它），那就是自旋点。

### 重新框定：我们的 `mtvec` **吞掉了 ROM 自己的中断**（2026-11-16，关键假设）

把三件事放在一起看：

1. blob 在 init 里**自己**配置 TIMG0_T0 作为 tick（矩阵 `0x20585064=25`、CLIC 输入 25、`mie` bit25）；
2. 我们的 `start.zig` 用 `csrw mtvec, trapEntry` **覆盖**了 ROM/bootloader 装的中断向量；
3. 采样显示 blob 的 tick 配置函数被**反复进入**（PC 在 `0x400490ca` 一带重复出现）。

最自然的解释：**blob 在等它的 tick 中断，而那个中断被我们的 `mtvec` 截获**——我们的 ISR 只采样并
`mret`，ROM 的 tick 处理逻辑从不运行，于是"等 tick"的循环永远不结束（这也正是"任务不让出"的
真因，而不是调度器的问题）。

**下一步（具体）**：

1. `start.zig` 在 `csrw mtvec` **之前**把旧的 `mtvec` 读出来存成全局（ROM 的向量入口）；
2. `trapDispatch` 对**不属于我们**的中断输入（除采样用的那个）**链到旧 `mtvec`**：
   先按帧恢复被中断的 `sp` 与寄存器，再跳到旧入口，让它自己的 ISR 正常执行；
3. 这样 blob 的 tick 能跑，采样器只处理自己的输入，互不干扰。

在那之前，"任务不让出"的现象不应再归因于调度器或 ack——**它是被我们自己的向量表截断的**。

### 把 `mtvec` 还给 ROM 的实验（2026-11-16）：仍然停在 swap#6

按上面的假设实现：`start.zig` 在覆盖前把旧 `mtvec` 存进 `export var rom_mtvec`（实测
**0x2f801703**，ROM 地址 ✓），探针在切到任务前把它写回 `mtvec` 并打开中断（不再武装自己的采样器）。

结果：**现象不变**——`esp_wifi_start` 之后依然是

```text
trace alloc a0=0x18 -> 0x2f01dfc8
trace queue_send a0=0x2f01d950 a1=0x00000006
trace semphr_take a0=0x2f01dff0 a1=0xffffffff
swap#6 in_task=false hooks=7      ← 任务拿到 CPU 后再无输出
```

也就是说"ROM 的 tick 被我们截获"这条假设**单独不足以解释**：把向量还回去之后任务仍然不让出。
下一步需要在**恢复 ROM 向量**的前提下重新采一次样（此时得用别的手段，例如 ROM 自己的 tick 计数
或再叠一层包装），确认任务此刻的 PC 是否还是那个 ROM 轮询辅助函数。

### 链式转发的实现要点（下一步，未实现）

把采样器与 ROM 的 tick 处理**共存**，需要在我们的入口里对"不属于自己"的中断**链到 ROM 入口**：

1. 入口保存的帧里已有 `ra`、`t0..t6`、`a0..a7`、被中断的 `sp`（offset 72）、`s0`（offset 76）；
2. **`s1..s11` 不需要额外保存**——我们的入口只用了 `t0`/`sp`，没碰它们，所以被中断的 s 寄存器
   在链式跳转时仍然完好（这是能做到"透明转发"的关键前提）；
3. 链式路径：从帧恢复 `ra`/`t0..t6`/`a0..a7` → `sp = frame[72]` → `jr rom_mtvec`；
   唯一的技术难点是"用哪个寄存器装跳转目标而不破坏被中断的寄存器"——可把目标先压栈、
   用 `ret` 完成跳转，或在 `mret` 前把 `mepc` 指向 ROM 入口（更简单：**改 `mepc` = rom_mtvec 再 mret**，
   ROM 入口会以"刚发生中断"的状态开始执行，只是 `mepc` 已被我们改写——需要确认 ROM 入口是否依赖
   原始 `mepc`）。

方案 3 的"改 `mepc` 再 `mret`"最省事，且不需要动寄存器；先验证 ROM 入口对 `mepc` 的依赖。

### 链式转发已实现并上板（2026-11-16）：init 段明显前进，swap#6 后采样消失

实现：

- `trapDispatch` 返回 `bool`：`true` = 把这次中断**转发**给 ROM 的入口；
- 入口新增链式路径：恢复 `ra`/`t1..t5`/`a0..a7`/被中断的 `sp`，`jr rom_mtvec`（`t0`/`t6` 作临时寄存器）；
- 探针置 `trap.chain_other_irqs = true` 并保留自己的采样输入 25。

板侧结果（40 s 采集）——**init 段确实前进了**，出现了此前从未见过的调用：

```text
chain-to-ROM mode, rom_mtvec=0x2f801703
trace semphr_give a0=0x2f01e020 a1=0x00000000
trace queue_recv a0=0x2f01d980 a1=0xffffffff
trace recv_probe a0=0x00000000 a1=0x00000008
swap#5 in_task=true hooks=124
...
calling esp_wifi_start (idle_calls=197)
trace alloc -> queue_send -> semphr_take
swap#6 in_task=false hooks=7
```

但 **`swap#6` 之后一次采样都没有**（2 ms 周期，40 s 内本该有上万次）——采样中断**彻底停了**。
最可能的解释：任务拿到 CPU 后 blob **自己装了 `mtvec`**（或屏蔽了中断），我们的 handler 从此不再被调用。
这也解释了为什么"任务不让出"在换了向量之后依然存在。

下一步：确认 `mtvec` 是否被任务改写。手段：在 swap 到任务前后各读一次 `mtvec`（`sched` 侧可做），
或在 ROM tick 的 ISR 里打点。若确实被改写，采样必须换成**不依赖 `mtvec`** 的手段
（例如在 ROM 的 tick 处理路径上挂钩子，或用 SYSTIMER 的独立中断源在 CLIC 层抢占）。

### 打印上限伪影：先纠正三处错误判读（2026-11-16）

这一节存在的意义是**记住这个坑**：`irq_samples` 是 `[16]usize`，而打印语句被写在
`if (irq_count < irq_samples.len)` **里面**，所以从 pb111 起"有效打印上限"一直是 **16**——
不管里面写 `< 32` 还是 `< 64` 都到不了。

后果是三条结论全被污染，逐条纠正：

| 曾经的写法 | 真相 |
| --- | --- |
| "16 次同 PC 之后中断停了" | 只是打印预算耗尽；pb113/114（自 ack）同样 16 条静默后主流程照常走到 `swap#6` |
| "16 < 32 所以不是风暴" | 算术无效：上限就是 16，不能用来排除风暴 |
| "`swap#6` 之后采样器一次都没触发，中断路径死了" | 同样是打印上限伪影 |

修法（已落地）：**打印与数组分离**——数组只存前 16 个，打印 `irq_count < 64` 全打、
之后每 256 条打一条心跳。

### 心跳证据：采样活过 `swap#6`，任务自旋在一个**硬件状态轮询**里（2026-11-16）

修好打印后（pb116，30 s 采集）拿到的是干净证据：

```text
calling esp_wifi_start (idle_calls=197, tracing hooks)
trace alloc -> queue_send -> semphr_take
swap#6 in_task=false hooks=7
irq-sample #256  input=25 mepc=0x2f009206
irq-sample #512  input=25 mepc=0x2f009206
...
irq-sample #2304 input=25 mepc=0x2f009206
```

两点都是新的：**中断在 `swap#6` 之后仍然活着**（"观测手段失效/mtvec 被改写"的假设一并作废）；
任务拿到 CPU 后**恒定自旋在 `0x2f009206`**。

**这个地址是 blob 自己的代码**（先纠正一版错误判读：当时用 `esptool read-mem` dump 出"数据样式的字"
就说它"不是代码"——`read-mem` 会先复位芯片，读到的是复位后残留，没有判据价值）。正确来源是 ELF：
`0x2f009206` 落在 `.iram_blobs`（`0x2f0000b0 + 0xf5b0`，flags=EXEC），反汇编是**干净的循环**：

```asm
2f0091fe  lui  a5, 0x20105
2f009202  addi a5, a5, -852      # a5 = 0x20104CAC
2f009202  lw   a5, 0(a5)         # a5 = REG[0x20104CAC]
2f009204  and  a5, a5, a4        # a4 = 0xE000（lui 0xe）
2f009206  bnez a5, 0x2f0091fe    # while ((REG & 0xE000) != 0) 空转
```

**结论**：任务不是"等不到 tick"，也不是"跳进数据区"，而是在**轮询硬件寄存器 `0x20104CAC` 的
[15:13] 位，等它们清零**。同一个函数上面刚写过这个寄存器（`or` 上 `0x00FF1000` 再 `sw`），
所以这是"写下去 → 等硬件把状态位清掉"的握手。

因此真正的阻塞点是**硬件/PHY 状态没有按 blob 预期变化**，与调度器、tick、中断向量都无关。
`0x20104CAC` 的归属已确认：IDF 的 `soc/esp32s31/include/modem/reg_base.h` 里
**`MODEM_BASE = 0x20100000`**，所以它是 **modem/PHY 窗口的 `+0x4CAC`**（不在公开寄存器头文件里，
属于闭源 PHY 内部寄存器）。

下一步：弄清这几位在什么条件下自清——也就是 blob 期待的**哪一步 PHY/calibration 握手**没有发生。
这决定了我们的 init 序列还缺什么，而不是调度器/中断层面的问题。

### 自旋的完整语义：写 → `ets_delay_us(20)` → 等状态位自清（2026-11-16）

把自旋点上下 16 条指令连起来看，语义很清楚：

```asm
2f0091e0  addi a5, a5, -852      # a5 = 0x20104CAC
2f0091e4  lw   a4, 0(a5)
2f0091e6  lui  a3, 0xff1
2f0091ec  or   a4, a4, a3
2f0091ee  sw   a4, 0(a5)         # REG[0x20104CAC] |= 0x00FF1000
2f0091f0  auipc ra, 0x7f7
2f0091f4  jalr -436(ra)          # -> 0x2f80003c（a0 已置 20）
2f0091f8  lui  a3, 0x20105
2f0091fc  lui  a4, 0xe           # a4 = 0xE000
2f0091fe  addi a5, a3, -852      # a5 = 0x20104CAC
2f009202  lw   a5, 0(a5)
2f009204  and  a5, a5, a4
2f009206  bnez a5, 0x2f0091fe    # 等 [15:13] 清零
```

`a0 = 20` 再 `call 0x2f80003c` 的形态就是 **`ets_delay_us(20)`**（ROM 的延时函数）。所以 blob 的
动作是：**置 `0x00FF1000` → 等 20 µs → 轮询 [15:13] 是否自清**。

`lui a3, 0xff1` 的立即数是 `0x00FF1 << 12 = 0x00FF1000`，即 **bits 12..19 全置**——它**包含**
[15:13] 这三位。也就是说"写完自己等自己清"：这是典型的**硬件握手位**，写入触发动作，
硬件完成后自动清零。

它永远不清，最直接的解释是 **modem/PHY 那块硬件没有在跑**（时钟没开 / 电源域没上），
于是寄存器写入不生效、状态位也不动。可查的开关就在同一窗口：

| 寄存器 | 地址 | 作用 |
| --- | --- | --- |
| `MODEM_SYSCON` | `0x20109C00` | modem 系统控制（复位/时钟选择） |
| `MODEM_LPCON` | `0x2010F000` | modem 低功耗时钟门控（**PHY 时钟常在这里**） |
| `MODEM_PWR` | `0x2010D000` | modem 电源域 |

下一步的具体动作：在调 `esp_wifi_start` 之前，按 IDF 的 PHY 初始化顺序把 `MODEM_LPCON` 的
PHY 时钟门打开（对照 `phy_init`/`esp_phy_enable` 的寄存器序列），再看这三位是否会自清。

### 根因候选（强）：`_phy_enable` 在我们这边是**空桩**（2026-11-16）

`components/wifi-blobs/src/osi_stubs.zig:300` 把 osi 表的 `_phy_enable` 直接指向 `stub8`（空函数）。
也就是说 blob 通过 osi 表请求"打开 PHY"时，我们**什么都没做**——PHY 的时钟/电源自然不会起来，
`MODEM_BASE+0x4CAC` 那些握手位也就永远不会自清。这与自旋语义完全吻合。

要验证/修复，需要把 `_phy_enable` 换成真实实现：走 `register_chipv7_phy(...)`（我们已有可调用的
签名，`init_probe.zig:410`）与 IDF `esp_phy_enable` 的时钟门序列（`MODEM_LPCON`），
而不是空桩。

签名细节（下一步实现要用）：osi 表里 `_phy_enable: ?*const anyopaque`，当前指向
`fn stub8() callconv(.c) usize { hits[8] += 1; return 0; }`——**无参数、返回 0**，正好对应 IDF 的
`esp_phy_enable(void)`。真实实现要做的是：开 `MODEM_LPCON` 的 PHY 时钟门 → 调 libphy 的
`phy_enable()`（以及首启时的 `register_chipv7_phy`）→ 返回 0。

顺序建议：先把 `_phy_enable` 真实化 → 重跑探针 → 观察 `0x20104CAC` 的 [15:13] 是否自清、
`esp_wifi_start` 是否返回。这一条比继续追调度器/中断更值得先做。

### 静态证明：blob **确实**依赖那些空桩（2026-11-16，不需要上板）

blob 通过 ROM RAM 里的 `g_osi_funcs_p`（`0x2F07FF44`）取 osi 表，再按固定偏移取函数指针。
在 `/tmp/blobobjs/*.o` 上用 `objdump -dr` 找出所有 "先 `lw reg, %lo(g_osi_funcs_p)` 再
`lw fn, OFF(reg)`" 的模式，统计 `OFF` 的分布，再按 `osi.zig` 的字段顺序映射回钩子名：

| idx | off | 钩子 | 被引用次数 |
| --- | --- | --- | --- |
| 2 | 0x008 | `_set_intr` | 28 |
| 3 | 0x00c | `_clear_intr` | 17 |
| 4 | 0x010 | `_set_isr` | 29 |
| 53 | 0x0d4 | **`_phy_enable`** | 4 |
| 56 | 0x0e0 | **`_timer_arm`** | 164 |
| 57 | 0x0e4 | **`_timer_disarm`** | 336 |
| 58 | 0x0e8 | **`_timer_done`** | 537 |
| 59 | 0x0ec | **`_timer_setfn`** | 289 |
| 60 | 0x0f0 | **`_timer_arm_us`** | 88 |
| 62 | 0x0f8 | **`_wifi_clock_enable`** | 19 |

（映射自检：idx 44 = `_free` 264 次、idx 93 = `_wifi_zalloc` 231 次、idx 106 = `_coex_pti_get`
89 次，都与直觉一致。）

**结论**：这些钩子不是"可能有用的边缘 API"，而是 blob 的**主路径**——`_timer_*` 那一族被引用
上千次（ESP 的 ets_timer 语义），`_phy_enable` 4 次。而它们在 `osi_stubs.zig` 里全是空桩。
所以"PHY 没上电 → `0x20104CAC` 的 [15:13] 永不自清"这条链条，不再只是推断：
**blob 明确会调 `_phy_enable`，而我们返回 0 什么都没做**。

### 实现顺序（下一步）

1. **`_phy_enable`**：签名 `fn () callconv(.c) usize`（= IDF 的 `esp_phy_enable(void)`）。
   时钟那一半的 ROM 等价物是 `phy_open_fe_bb_clk`（`0x2f80131c`，`rom_syms.ld:115`），四步写已在
   ADR 早期解码（`0x20100400=0x1E7`、`0x20100800|=3`、`0x20107C80=0xFFFFFFFF`、
   `0x2070401C|=0x40000F`）。注意 **PHY 时钟位在 `MODEM_SYSCON`（0x20109C00）的 `clk_conf1`**
   （`modem_clock.c:167-168` 的 `modem_syscon_ll_clk_conf1_get/set`），`MODEM_LPCON`（0x2010F000）
   管的是低电域 power——别只写 LPCON。另一半要先确认 libphy 里有没有可调的 `phy_enable` 符号
   （`nm libphy.a | grep -i phy_enable`），没有就只剩 `register_chipv7_phy` 这条路。
2. **`_timer_*` 五件套**：S31 的 ROM **没有 `ets_timer_*`**，只能应用侧自己实现——选一条**没被占用**
   的定时器（T0 被 blob 的 tick 与采样器占着，用 T1 或别的组）+ 一个 CLIC 输入，到期在 ISR 里回调
   `_timer_setfn` 存下的 `fn(arg)`；`_timer_arm` 单位 ms、`_timer_arm_us` 单位 µs。
3. **`_set_isr`/`_set_intr`/`_clear_intr`**：对应 ROM 的 `intr_handler_set`（`0x2f800764`）、
   `intr_matrix_set`（`0x2f800768`）、`ets_intr_lock/unlock`（`0x2f800770/774`），
   `esp32s31.rom.ld:333-337`。
4. 实现后 `host_tests.zig:149` 里"这些属于桩集合"的断言要同步改。

### 另一个待验证的候选：`PHY_RF_CAL_NONE`

探针里 `register_chipv7_phy(..., PHY_RF_CAL_NONE)` 当初是为绕开"标定要等 PHY 应答、而当时中断关着"。
现在中断已经开着，这个理由不成立了；blob 的 PHY 流程很可能正是**靠标定完成**才清掉那三位。
去掉 `PHY_RF_CAL_NONE`（走 `PHY_RF_CAL_FULL`）是比实现时钟门更便宜的一次实验。

### `PHY_RF_CAL_FULL` 实测：**不能**解开自旋（2026-11-16）

把探针里的标定模式从 `PHY_RF_CAL_NONE(1)` 改成 `PHY_RF_CAL_FULL(2)` 上板（pb117，40 s）：

```text
calling esp_wifi_start (idle_calls=197, tracing hooks)
trace alloc -> queue_send -> semphr_take
swap#6 in_task=false hooks=7
irq-sample #256 .. #1792 input=25 mepc=0x2f009206
```

**自旋点不变、仍然卡在 `0x2f009206`**。所以"跳过标定导致握手位不清"这条候选被排除
（`register_chipv7_phy` 返回 rc=0，标定本身也没报错）。

剩下的主候选就是**空桩**：`_phy_enable`（静态证据 4 处引用）与 `_timer_*` 全族（上千处）都还是
no-op，blob 的 PHY 上电与定时器驱动因此都不存在。下一步按实现顺序那节做 `_phy_enable`。

### `_phy_enable` 的真实实现配方（读 IDF `phy_init.c` 得出）

`libphy.a` 里**没有** `phy_enable` 符号（`nm libphy.a | grep phy_enable` 为空；导出的是
`register_chipv7_phy`、`phy_close_fe_bb_clk`、`phy_close_rf`、`phy_open_i2c_xpd_new` 等 163 个）。
真正的"打开"逻辑在 IDF 的 `esp_phy/src/phy_init.c:324 esp_phy_enable(esp_phy_modem_t modem)` 里，
顺序是：

```c
if (phy_get_modem_flag() == 0) {
    phy_update_wifi_mac_time(false, now);      // 开共用时钟前先更新 MAC 时间
    esp_phy_common_clock_enable();             // 共用时钟（periph/modem clock）
    phy_module_enable();                       // MODEM_SYSCON 的 PHY 时钟位
    assert(phy_module_has_clock_bits(PHY_INIT_MODEM_CLOCK_REQUIRED_BITS));
    if (!s_is_phy_calibrated) {
        esp_phy_load_cal_and_init();           // 首次：读 NVS 标定 → register_chipv7_phy
        s_is_phy_calibrated = true;
    }
}
```

所以我们的 `_phy_enable` 钩子应当：**① 开共用时钟 → ② 置 MODEM_SYSCON 的 PHY 时钟位（并回读校验）
→ ③ 首次调用时跑 `register_chipv7_phy`（我们已经会调，rc=0）→ 返回 0**。`assert` 那一步很值得
照抄成"回读校验并打印"，因为 `0x20104CAC` 的 [15:13] 正是"时钟真的到位了没有"的硬件答案。

### `_phy_enable` 已实现，但**不在自旋之前**被调用（2026-11-16）

把 `_phy_enable` 从空桩改成真实实现（幂等重申 `MODEM_SYSCON.CLK_CONF1` 的 PHY 时钟位与两个
`FORCE_ON` 寄存器，并记一条 `note(15, …)` 追踪），上板（pb118，40 s）：

```text
calling esp_wifi_start (idle_calls=197, tracing hooks)
trace alloc -> queue_send -> semphr_take
swap#6 in_task=false hooks=7
irq-sample #256 .. #1792 mepc=0x2f009206
```

**日志里一条 `trace phy_enable` 都没有** → 任务在调用 `_phy_enable` **之前**就已经进自旋了。
所以这条钩子不是当前卡点的解药（它仍然是必须补的，但优先级排在自旋之后）。

### 自旋函数的完整结构与调用链

反汇编 `0x2f009190` 起（自旋函数本体，`ret` 在 `0x2f009220`）：

```asm
2f009194  lw   a5, -720(a4)        # 0x2f07fd30 += 1（调用计数）
2f0091ac  lw   a5, 0(a4)           # a4 = 0x20104CAC
2f0091b0  srli a5, a5, 0xe ; andi 1 ; sb -> 0x2f07fd2d   # 记录 bit14
2f0091b8  lw   a5, 0(a4)
2f0091be  srli a5, a5, 0xd ; andi 1 ; sb -> 0x2f07fd2c   # 记录 bit13
2f0091c6  jal  0x2f00254e          # 一个"是否需要等"的判定
2f0091ca  beqz a0, 0x2f0091dc      # 返回 0 → 跳过前置等待
2f0091d2  lw/and 0xe000 ; bnez -> 自旋（前置：等 [15:13] 清零）
2f0091dc  ... sw 0x00FF1000 ...
2f0091f4  jalr -> 0x2f80003c       # ets_delay_us(20)（a0=20）
2f009202  lw/and 0xe000 ; bnez 0x2f0091fe   # 后置自旋（采样落点 0x2f009206）
2f009220  ret
```

调用链（静态）：`0x4003eb6e`（`.flash.text`）→ `0x2f005cc4` → `0x2f009190`。
另外两个全局 `0x2f07fd2c` / `0x2f07fd2d` 缓存了 bit13/bit14 的最近值——它们是**可观测的判据**：
下次采样时可以顺带把这两个字节读出来，直接看到硬件那两位在写前/写后的真实值。

### 硬件读数定案：寄存器是活的，**模拟/校准域没响应**（2026-11-16）

把心跳行接上硬件现场（读 `0x20104CAC` 整字与自旋函数缓存的 bit13/bit14），板侧 25 s（pb119）：

```text
irq-sample #256  mepc=0x2f009202 mac=0x00fff000 b13=1 b14=1
irq-sample #512  mepc=0x2f009206 mac=0x00fff000 b13=1 b14=1
irq-sample #1024 mepc=0x2f009206 mac=0x00fff000 b13=1 b14=1
irq-sample #5120 mepc=0x2f009204 mac=0x00fff000 b13=1 b14=1
```

**这是决定性读数**：

**先算准位**（之前写成 "bits 12..19" 是错的）：

- 写 `lui a3, 0xff1` → `0x000ff1 << 12` = `0x00FF1000` = **bit 12 + bits 16..23**；
- 等 `lui a4, 0xe` → `0xE000` = **bits 13..15**；
- 读回 `0x00FFF000` = **bits 12..23** = 写位 ∪ `{13,14,15}`。

即：硬件自己置上的恰好是**被轮询的三位 busy 位**——"写触发动作 → 硬件置 busy → 完成后自清"。
这个读法不偏向任何一方，剩下**两个并列候选**：

| 候选 | 判据 |
| --- | --- |
| A. blob 的 T0 tick ISR 从未运行 → 时序步进不被推进 | 我们所有带采样的运行里 input 25 都被自己的 handler 吃掉并自 ack 自重装；转发给 ROM 的 handler 表后若 [15:13] 自清即成立 |
| B. 下游/模拟侧没完成初始化 | 转发实验后仍不清，才轮到 `I2C_ANA_MST` / `MODEM_PWR` 这条 |

候选 A 的判别器：从 ROM `intr_handler_set`（`0x2f800764`）反汇编找出它写的 handler 表地址，让
`trapDispatch` 对 input 25 改成"采样后 ack 并转发 `table[25].fn(arg)`"。**这一步还没做**，
所以"与 tick 无关"目前没有证据。

下一步（有明确判别器）：

1. 在调 `esp_wifi_start` 之前把模拟域拉起来：`MODEM_PWR`(0x2010D000) 与 `I2C_ANA_MST` 的
   power/xpd 位（参照 IDF `esp_phy_enable` → `phy_open_i2c_xpd_new`）；
2. 判别器就是本行心跳：`mac` 的 bits 12..19 变成 0 → 模拟域起来了，自旋会消失；仍为 `0x00fff000`
   → 换下一组位再试。

### 候选 A 的实现路径已查明：blob 的 tick 走的是**我们桩掉的 osi `_timer_*`**

想"把 input 25 转发给 ROM 的 handler 表"这条路走不通：ROM 的 `intr_handler_set`（`0x2f800764`）
写的是 **ROM 内部静态数组** `s_intr_handlers[core][int_no]`（`components/riscv/interrupt.c:36`），
而 `_global_interrupt_handler` **没有导出符号**（`esp32s31.rom.ld` 里只有 `intr_handler_set` /
`intr_matrix_set`）。所以我们既拿不到表地址，也调不到 ROM 的分发器。

但沿着这条线反而找到了更可信的候选 A 形态：blob 的软件定时器（coex/协议栈调度）走的是 **osi 表的
`_timer_setfn` / `_timer_arm` / `_timer_arm_us` / `_timer_disarm` / `_timer_done`**，而这五个在
`osi_stubs.zig` 里全是**空桩**（`stub10..14`）。静态扫描显示它们被引用上千次（`_timer_done` 537、
`_timer_disarm` 336、`_timer_setfn` 289、`_timer_arm` 164、`_timer_arm_us` 88）。

所以"时序步进不被推进"的真正机制很可能是：**blob 注册的软件定时器永远不会到期**，因此它等待的
状态机步骤永远不前进。实现这五个钩子（挑一条空闲硬件定时器 + 一个 CLIC 输入，到期回调
`setfn` 存的 `fn(arg)`；`_timer_arm` 单位 ms、`_timer_arm_us` 单位 µs）是下一个可执行步骤，
而且它比"转发 input 25"更直接、更可能有解。

### 软件定时器五件套已实现，但**自旋前一个都没被 arm**（2026-11-16）

按上一节的判断实现了 osi 的 `_timer_setfn/_timer_arm/_timer_arm_us/_timer_disarm/_timer_done`
（协作式软件定时器：16 槽，`serviceTimers()` 在每个让出点推进，`_timer_arm` 单位 ms、
`_timer_arm_us` 单位 µs），并接进 `on_idle` 之前。

**第一次板跑（pb120/pb121）不可判读**：那两次对定时器钩子没有任何观测（`hook_ids` 只有 16 项、
`note_id_max` 仍是 14、探针的 `traceNote` 只放行 id 0/1/4/5/13/14），"fires=0"既可能是"没 arm"，
也可能是"根本没观测到"。补上观测（`hook_ids` 20 项、`note_id_max=19`、放行 id 16..19、
`host_tests` 的 `implemented.len` 71→77）后重跑（pb122，40 s）才拿到数据：

```text
trace timer_setfn a0=0x2f01452c a1=0x400334ee     # ← blob 确实注册了回调
... 共 14 次 timer_setfn
trace timer_arm   : 0 次
trace timer_fire  : 0 次
irq-sample #10 input=25 mepc=0x2f83efde mac=0x0000e000 b13=0 b14=0
```

结论：**blob 在自旋前注册了 14 个软件定时器回调（`setfn`），但一次都没 arm**。所以"定时器被桩 →
调度不推进"不是当前自旋的原因（我们的实现本身工作正常，`setfn` 已被调用 14 次）。

三个候选至此都被实验排除：

| 候选 | 实验 | 结果 |
| --- | --- | --- |
| 跳过标定 | `PHY_RF_CAL_FULL` | 自旋不变 |
| `_phy_enable` 空桩 | 实现真实上电 | 自旋前未被调用 |
| `_timer_*` 空桩 | 实现协作式定时器 | 自旋前无定时器被 arm |

剩下的就是硬件本身：写 `0x00FF1000` → 硬件置 busy{13:15} → **它不自清**。下一步要么找出谁该清它
（ROM 里同款流程的前后步骤），要么承认"这条 PHY 启动路径需要真实 PHY 固件/校准序列，裸机探针
还不具备条件"。

### 自旋函数正名：**MAC deinit**（ROM 符号表给出名字，2026-11-16）

`esp32s31.rom.pp.ld:417-419`（与我们的 `rom_syms.ld:216-218` 一致）给出了三个全局的名字：

| 地址 | 符号 |
| --- | --- |
| `0x2f07fd30` | `g_mac_deinit_count` |
| `0x2f07fd2d` | `g_mac_deinit_rxing` |
| `0x2f07fd2c` | `g_mac_deinit_txing` |

对上 `0x2f009190` 的反汇编：先 `g_mac_deinit_count++`，再把 `0x20104CAC` 的 **bit14 → `rxing`、
bit13 → `txing`**，调 `0x2f00254e` 发起停止，然后**等 TX/RX 的"仍在活动"位（[15:13]）自清**。

所以这段**不是"等 PHY 上电"**，而是 blob 在 `esp_wifi_start` 期间走了一次 **MAC deinit/复位**，
在等 TX/RX 静止。之前所有"PHY 电源域"的表述都应以此为准。

**两条有符号支撑的下一步**：

1. `wifi_rf_phy_enable = 0x2f800cf4` / `wifi_rf_phy_disable = 0x2f800cf0`
   （`esp32s31.rom.net80211.ld:65-66`）——IDF 的 `esp_phy_enable()` 走这一对，而我们的手工 bring-up
   **从没调过它**。在 start 前调一次 `wifi_rf_phy_enable`，看 deinit 的 [15:13] 是否自清。
2. 给 `0x2f00254e` 命名：`/tmp/blobobjs/*.o` 有符号表，用 `.iram_blobs` 段内偏移
   （`0x2f0091fe − 0x2f0000b0 = 0x914E`）字节匹配定位 .o，再用 `nm` 拿函数名。
