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

也就是说 **blob 自己的 IRAM 任务代码**在 give 时传了 null。下一步是在 blob 对象里按这段字节模式
反查是哪个函数（`ieee80211_ioctl.o` / `pp.o` 一类），看它给 `a0` 赋值的那几行。

### 为什么还不能直接按字节反查（记录方法学）

试过在 blob 对象里按 `lui s1,0x40104` / `lui s2,0x2f012` 的字节模式定位那个 null-give 调用者，
**搜不到**：链接期把这些 `lui` 的立即数重定位成了最终地址，对象文件里的占位值与镜像里的不同。
所以对这类"绝对地址立即数"的代码，字节模式匹配只对**未重定位的相对指令**（如之前那次
`mv s1,a0; lw a0,4(s0); jalr a5`）有效。

要继续，只有两条路：

1. 用链接后的镜像地址反查 `.iram_blobs` 里的函数归属（需要 blob 的段内符号/`.symtab`，我们目前没有）；
2. 在 `_semphr_give` 里记录**调用链**（`@returnAddress()` + 再上一层的 `s0`/`ra`），用运行时数据定位。
