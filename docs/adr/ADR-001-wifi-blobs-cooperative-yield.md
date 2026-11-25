# ADR-001：`wifi-blobs` 用「阻塞 = 合作式让出」代替调度器

- 状态：accepted
- 日期：2026-11-16
- 决策者：hl
- **2026-11-25 更新**：本 ADR 追查的卡点（`esp_wifi_start` 等 `MAC_ST[15:13]` 自清）已定位并修复，结论在文末
  「根因与修复（2026-11-25）」。此前各节按实验顺序记录，当时的中间结论保留不动。

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

### `wifi_rf_phy_enable` 提前调用：**也不能**解开自旋（2026-11-16）

在 `esp_wifi_start` 之前显式调用 ROM 的 `wifi_rf_phy_enable`（`0x2f800cf4`，IDF `esp_phy_enable`
走的就是它），调用与返回都有日志（pb123）：

```text
calling wifi_rf_phy_enable()
wifi_rf_phy_enable returned
calling esp_wifi_start (idle_calls=197, tracing hooks)
swap#6 in_task=false hooks=8
irq-sample #256 .. mepc=0x2f00920x mac=0x00fff000 b13=1 b14=1
```

**自旋不变**。至此四个候选全部被实验排除：标定模式、`_phy_enable` 空桩、`_timer_*` 空桩、
`wifi_rf_phy_enable` 未调用。剩下唯一没做的一步就是**给 `0x2f00254e` 命名**（deinit 发起者）并
查清"谁在 start 期间触发 MAC deinit"——`g_mac_deinit_count` 的调用者。

### 给 `0x2f00254e` 命名的可行方法（字节匹配**不可行**，已实测）

试过两种字节匹配，都失败，原因值得记住：

1. 直接在各 `.o` 的 `.iram_blobs` 里搜 `0x2f00254e` 处的字节 → 无命中；
2. 把 `libphy/libcoexist/libmesh/libespnow` 全部 `ar x` 解开（49 个成员）再搜 → 仍无命中。

原因是 **重定位**：链接后 ELF 里的 `lui a5, 0x2f001` 是重定位结果，而 `.o` 里的立即数是 0
（skill §7 记过这条）。所以字节模式匹配天然失效。

替代做法（更省事）：**直接反汇编它**。`0x2f00254e` 只有 6 条指令，是个**取字节的判定函数**：

```asm
2f00254e  lui  a5, 0x2f014
2f002552  addi a5, a5, 1144      # a5 = 0x2f014478
2f002556  lbu  a0, 450(a5)       # a0 = *(u8*)0x2f01463e
2f00255a  bnez a0, 0x2f002560
2f00255c  lbu  a0, 740(a5)       # 否则 a0 = *(u8*)0x2f01475c
2f002560  ret
```

所以它不是"发起停止"，而是 **`wait_needed()` 谓词**：返回 blob 的两个状态字节之一。
自旋函数的真实控制流因此是：

```
if (wait_needed() != 0) { 等 [15:13] 清零 }      // 前置轮询
写 0x00FF1000 → ets_delay_us(20) → 等 [15:13] 清零   // 后置轮询（采样落点）
```

我们采到的都是**后置**轮询，说明写入已经发生、busy 位就是不清。

### `0x20104CAC` 的字段地图（静态：所有 9 处访问）

在链接后的镜像里搜 `0x20104cac`，共 9 处。除自旋函数自己（`0x2f0091xx`）外：

| 站点 | 动作 | 含义 |
| --- | --- | --- |
| `0x400333d2` | `lw` → `and 0xfff1ffff` → 写 | **清 bits 17..19** |
| `0x40033bcc` / `0x400344a0` / `0x4003456c` | `lw` → `or 0xE0000` → 写 | **置 bits 17..19** |
| `0x2f005b20` | `lui 0xff0` 掩码后拼写 | 写 bits 12..19 的一部分 |

所以这张寄存器至少有三个字段：

- **bits 13..15**：自旋等待的 busy 位（对上 `g_mac_deinit_txing`(bit13) / `g_mac_deinit_rxing`(bit14)）；
- **bits 17..19**（`0xE0000`）：由 blob 的 flash 代码显式**置/清**——这是一组"某模块使能/占用"标志，
  不是自旋直接等的对象；
- **bit 12 与 bits 16、20..23**：由 blob 的 `0x00FF1000` 写入或硬件置起。

这解释了读回 `0x00FFF000` 为什么会比写入多：bits 13..15 是 deinit 自己置的 busy，bits 17..19 是
另外三条路径置的使能位。**下一步要查的是"谁该把 13..15 清掉"**——按 `g_mac_deinit_txing/rxing` 的
语义，那是 MAC 真正停止 TX/RX 时由硬件清的，所以问题回到"TX/RX 为什么停不下来"。

### 找到真正的缺失钩子：`_wifi_reset_mac` 就在自旋**之前**被调用（2026-11-16）

给 `_wifi_clock_enable/disable` 与 `_wifi_reset_mac` 三个空桩加上 `note()` 观测后上板（pb124）：

```text
swap#6 in_task=false hooks=9
trace timer_disarm
trace wifi_clk_en          ← blob 调它
trace wifi_reset_mac       ← ★ 紧接着就是它
trace timer_disarm
irq-sample #256 .. mepc=0x2f00920x mac=0x00fff000 b13=1 b14=1
```

**这是决定性观测**：blob 在进入 MAC deinit 自旋**之前**先调 `_wifi_reset_mac`——而这个钩子一直是
空桩，等于**MAC 从来没被复位过**，TX/RX 的 busy 位自然停不下来。

实现（照 IDF 的真实路径）：S31 的 `_wifi_reset_mac` = `modem_clock_module_mac_reset(PERIPH_WIFI_MODULE)`
（`esp_wifi/esp32s31/esp_adapter.c:376`），其内核是 `modem_syscon_ll_reset_wifimac()`：

- `MODEM_SYSCON.modem_rst_conf` = **0x20109C10**（字段序：`test_conf` 0x00 / `clk_conf` 0x04 /
  `clk_conf_force_on` 0x08 / `clk_conf_power_st` 0x0C / **`modem_rst_conf` 0x10** / `clk_conf1` 0x14，
  与探针里 FORCE_ON=0x08、POWER_ST=0x0C、CLK_CONF1=0x14 三个锚点完全吻合）；
- `rst_wifimac` = **bit 9**；
- 动作是 **1 → 0 脉冲**。

**上板结果（pb125）：自旋仍然不变**（`mac=0x00fff000`）。所以"复位脉冲缺失"是必要条件但不是充分条件：
复位之后还需要 blob 走完 MAC 初始化（时钟/配置），busy 位才会在硬件侧清掉。第五个候选部分排除。

### 时钟侧已确认无误；剩下的怀疑转向 TX/RX 排空

`_wifi_clock_enable` 该做的事也对上了：IDF 的 `wifi_module_enable()` →
`modem_clock_module_enable(PERIPH_WIFI_MODULE)`，其 MAC 一项是
`modem_syscon_ll_enable_wifi_mac_clock()` = `clk_conf1.clk_wifimac_en`（**bit 9**，见
`modem_syscon_struct.h` 里 `clk_conf1` 的字段序），而我们的实现**本来就置了 bit 9**。

所以复位与时钟两条都到位了，busy 位却仍不清。剩下的解释指向**活动本身**：init 阶段 blob 真的发过一帧
（`internal_tx rc=0x3002 (64 B)`），而 TX/RX 的"仍在活动"位是等 DMA 排空才清的——而我们的宿主层
没有真实收发（rxcb 是桩、TX 出口是桩），DMA 环可能永远处于"有一帧在飞"的状态。

下一步（可测）：在探针里给 `esp_wifi_internal_tx` 一个**真的**出口（把帧丢掉但**归还 TX 缓冲/推进
描述符**），并在 rxcb 侧按 blob 期望的方式归还 RX 缓冲，看 deinit 的 busy 位是否自清。

### 候选清单与实验结论（截至 2026-11-16 的完整账）

| # | 候选 | 实验 | 结果 |
| --- | --- | --- | --- |
| 1 | 跳过 RF 标定 | `PHY_RF_CAL_FULL(2)` | 自旋不变 |
| 2 | `_phy_enable` 空桩 | 实现真实上电 | 自旋前**未调用** |
| 3 | `_timer_*` 空桩 | 实现协作式软件定时器 | 自旋前注册 14 次、**arm 0 次** |
| 4 | `wifi_rf_phy_enable` 未调用 | start 前显式调用 | 自旋不变 |
| 5 | `_wifi_reset_mac` 空桩 | 实现 `rst_wifimac`(0x20109C10 bit9) 1→0 脉冲 | **被调用**，自旋不变 |
| 6 | `_wifi_clock_enable` 位不全 | 补齐 `WIFI_CLOCK_DEPS` 全部位（CLK_CONF1=0x38E7FF） | 自旋不变 |
| 7 | init 的 `internal_tx` 弄脏 TX 引擎 | 跳过该帧（`probe_send_init_frame=false`） | 自旋不变 |
| 8 | FE 的 TX/RX 状态机未复位 | start 前调 ROM `phy_fe_txrx_reset`(0x2f8013d8) | 自旋不变 |

**结论（诚实版）**：`esp_wifi_start` 期间 blob 走的是 MAC deinit 路径（`g_mac_deinit_count++`、
`g_mac_deinit_txing/rxing` ← `0x20104CAC` 的 bit13/bit14），随后**等 busy{13..15} 自清**；这三位在
镜像里**没有任何一处软件写清**（9 处访问里唯一的 AND 清的是 bits 17..19），只能由硬件在 TX/RX 真正
静止时清。八条宿主侧解释全部被实验排除，剩下的是**闭源寄存器语义**：那三位由谁、在什么条件下清。

继续推进需要的不是更多猜测，而是硬件手册或另一台已知正常的 S31 上做同址对比（例如 IDF 官方
`esp_wifi_start` 成功后 `0x20104CAC` 的读回值）。

### 决定性读数：busy{13..15} 从**第一条样本**起就是 1，而且写不掉

两条新证据合起来把这条线闭合了：

1. **最早期的样本就是 `mac=0x0000e000`**（pb126/pb129 的 #0/#1/#2/#3/#10/#50）——那时 blob 的 start
   代码还一条都没跑。所以 bits 13..15 不是"init 弄脏的"，而是**复位默认态**（TX/RX 引擎未上电/未初始化
   时报告 busy）。
2. **blob 自己的清状态函数也清不掉它们**。`0x2f005b0c` 是一个"按掩码清状态"的小函数：

   ```asm
   2f005b20  lui a5, 0xff0        # 0xFF000 = bits 12..19
   2f005b26  and a5, a5, a0       # a5 = a0 & 0xFF000
   2f005b28  lui a2, 0x1 ; or     # a5 |= bit12
   2f005b2e  not a5, a5 ; and a5, a5, a3 ; sw a5, 0(a4)   # 写回 (current & ~a5)
   ```

   我们在 start 前用 `a0 = 0xE000` 调它：`pre-start mac=0x0000e000` → `post-clear mac=0x0000e000`，
   **一位都没变**。说明 bits 13..15 是**硬件只读状态位**，软件写不进去。

**最终结论**：`esp_wifi_start` 的 MAC deinit 在等 TX/RX 引擎的硬件忙位清零；这些位复位即为 1、软件不可写，
只有**真正完成 MAC/PHY 上电与初始化**（DMA 环 + RF 前端）才会清。我们的裸机探针没有真实 PHY 收发链路，
所以它们永远不清——这已不是宿主钩子能修的问题。

要让 `esp_wifi_start` 返回，下一步只有两条路：① 提供真实的 MAC/PHY 初始化（IDF 的 `esp_phy_enable`
完整等价物 + MAC 的 DMA 环建立），或 ② 在另一台**已知正常**的 S31 上读同址做对比，确认那三位的清零条件。

### 补充两个"复位变体"，同样无效（2026-11-16，候选 9/10）

按 IDF 开 BB 时钟的序列（`modem_clock_wifi_bb_configure`：**先脉冲 `rst_wifibb` 再开 0x17b 时钟**）
以及"clock-gated reset"惯例各试一次，都在 start 之前：

| # | 实验 | 结果 |
| --- | --- | --- |
| 9 | 脉冲 `rst_wifibb`（`0x20109C10` bit8） | `0x0 -> 0x0`，`mac` 仍 `0x0000e000` |
| 10 | 时钟门控复位：清 `clk_wifimac_en`(CLK_CONF1 bit9) → 脉冲 `rst_wifimac` → 重新使能 | `mac=0x0000e000` 不变 |

**十条宿主侧路径全部无效**。加上"blob 自己的清状态函数也写不掉"，可以确定：
`0x20104CAC` 的 bits 13..15 由硬件独占，软件（包括复位与时钟门控）都无法改变。

**这条线到此为止**。要再推进只能靠：① 忠实实现 IDF 的 `esp_phy_enable` + MAC DMA 环建立（工作量最大的
那条路）；② 在一台已知正常的 S31 上读 `0x20104CAC` 做对照，确定这三位的清零条件。

### `WIFI_CLOCK_DEPS` 七项逐条核对：全部已开（2026-11-16，补上最后的审计）

之前只核了 CLK_CONF1，没把七项与寄存器一一对上。现在逐条落实（每一项都有 IDF 的 LL 函数作依据）：

| dep | 寄存器 / 位 | 我们的状态 |
| --- | --- | --- |
| `WIFI_MAC` | `CLK_CONF1(0x20109C14)` bit9 `clk_wifimac_en` | ✅ |
| `WIFI_APB` | 同上 bit10 `clk_wifi_apb_en` | ✅ |
| `WIFI_BB` | 同上 `0x17b`（bit0,1,3,4,5,6,8） | ✅ |
| `WIFI_BB_44M` | 同上 bit2 | ✅ |
| `WIFI_BB_80X1` | 同上 bit7 | ✅ |
| **`COEXIST`** | **`MODEM_LPCON(0x2010F000).clk_conf(+0x18)` bit1**（`modem_lpcon_ll_enable_coex_clock`） | ✅（板侧 `MODEM_LPCON_CLK_CONF 0x4 -> 0xf`） |
| **`SOC_PLL_SOURCE_CG`** | **`HP_SYS_CLKRST.modem_conf(0x205871E0) = 0x3d`**（`modem_clock_hal_enable_soc_pll_source_cg`） | ✅（板侧 `0x25 -> 0x3d`） |

（另：`LPCON.clk_conf` 的 bit0 `clk_wifipwr_en` / bit2 `clk_i2c_mst_en` 也已置；合计 `0xf`。）

所以"时钟依赖没开全"这条**有据可查地**被排除——七项全开、复位脉冲全试过、busy 位仍不清。

### coex 家族：只被调用 `_coex_enable` 一次（2026-11-16，候选 11）

`_coex_*` 一直是全空桩。先给八个最可能的钩子（`init/enable/status_get/pti_get/wifi_request/
wifi_release/schm_interval_set/register_start_cb`）装上 note 观测，上板（pb133）：

| 钩子 | 调用次数 |
| --- | --- |
| `_coex_enable` | **1**（在 `swap#6` 之后、自旋之前） |
| 其余七个 | 0 |

所以 start 路径上 coex 只走到 `enable` 就停了，其余钩子根本没被调用——"coex 调度器拿不到 interval/status
所以 TX/RX 一直忙"这条**在本轮观测下不成立**（没有调用，也就谈不上缺实现）。自旋照旧
（`mac=0x00fff000`）。

若将来要把 coex 做完整，最小语义是：`_coex_enable` → 调 ROM `coex_core_enable`，并把 interval /
start callback 记下来；但**它不解释当前卡点**。

### `_coex_enable` 改成真实调用 `coex_enable()`：也不解开（候选 12）

观测到 `_coex_enable` 确实被调用后，把它从空桩改成调用 `libcoexist.a` 里的真函数：

```zig
fn shellCoexEnable() callconv(.c) usize {
    note(24, 0, 0);
    const f = @extern(*const fn () callconv(.c) void, .{ .name = "coex_enable" });
    f();
    return 0;
}
```

链接 `coex_enable` 会拉进 `coex_core.o`，它需要 ROM RAM 里的表指针——已在 `rom_syms.ld` 补上：

```
g_coex_param_ptr = 0x2f07ff94    g_coa_funcs_p = 0x2f07ff98
coexist_funcs    = 0x2f07ff9c    coex_schm_env_ptr = 0x2f07ffa0
coex_pti_tab_ptr = 0x2f07ffa4    coex_env_ptr = 0x2f07ffa8
```

上板（pb134）：`coex_enable` 真跑了（无 panic），**自旋照旧**（`mac=0x00fff000`）。

### 最后一个变体：不注册 RX 回调（候选 13，同样无效）

`reg_rxcb` 会把我们的 RX 回调挂进 blob，RX 引擎可能因此认为"有人持有缓冲"而永远不静止。把注册也做成
开关（`probe_register_rxcb = false`）后上板（pb135）：`reg_rxcb SKIPPED`，自旋照旧 `mac=0x00fff000`。

**十三候选全表**（每个都有板侧证据）：

| # | 候选 | 结果 |
| --- | --- | --- |
| 1 | 跳过 RF 标定 | ✗ |
| 2 | `_phy_enable` 空桩 | 自旋前未调用 |
| 3 | `_timer_*` 空桩 | 注册 14 次、arm 0 次 |
| 4 | `wifi_rf_phy_enable` 未调用 | ✗ |
| 5 | `_wifi_reset_mac` 空桩 | 被调用，✗ |
| 6 | 时钟位不全 | 七项 dep 全开，✗ |
| 7 | init `internal_tx` 弄脏 TX | ✗ |
| 8 | FE TX/RX 未复位 | ✗ |
| 9 | `rst_wifibb` 未脉冲 | ✗ |
| 10 | clock-gated 复位 | ✗ |
| 11 | coex 调度器缺实现 | 只有 `_coex_enable` 被调用 |
| 12 | `coex_enable` 空桩 | 真实调用后 ✗ |
| 13 | RX 回调持有缓冲 | 不注册，✗ |

### 候选 14：补齐 IDF 标准配置序列（`set_mode`/`set_country`/`set_storage`）

触发 MAC deinit 的函数读 `g_chm`（`0x2f07ff88`，channel manager），所以怀疑"CHM/信道未配置"导致 start
先重配 MAC。探针此前从 init **直接跳到** start，中间三步一步都没做。补齐后（pb136/pb137）：

```text
set_mode(STA) rc=0
set_country(01,1..11) rc=258      # 258 = 0x102 = ESP_ERR_INVALID_ARG
set_country(CN,1..13) rc=258      # 换成真实国家码也一样
set_storage(RAM) rc=0
calling esp_wifi_start ...
irq-sample #16640 .. mepc=0x2f009206 mac=0x00fff000 b13=1 b14=1
```

`set_mode` 与 `set_storage` 成功，`set_country` 一律返回 258（结构体布局已按
`esp_wifi_types_generic.h:69-81` 复刻：`char cc[3]; u8 schan; u8 nchan; i8 max_tx_power; u32 policy`），
**自旋照旧**。所以"配置序列缺失"也不是当前卡点的原因（`set_country` 的 258 另案，但它不影响自旋）。

**十四个候选全部实验排除。**

### 复位基线：`MAC_ST` 在**任何 blob 代码之前**就是 `0x0000e000`

在探针 `begin`（还没调 `esp_wifi_init_internal`）与 init 之后各读一次 `0x20104CAC`：

```text
wifi-init-probe: MAC_ST at begin   = 0x0000e000
wifi-init-probe: MAC_ST after init = 0x0000e000
irq-sample #0 input=25 mepc=0x4004a2fe mac=0x0000e000
```

也就是说 bits 13..15 **是芯片的复位态**，与我们的 init 无关、与任何钩子无关。这也解释了为什么
"blob 自己的清状态函数也写不掉"——它们是硬件独占状态位。

两种读法都指向同一结论：

- 若 1 = busy（TX/RX 未静止）：blob 在等一个它自己永远等不到的状态；
- 若 1 = idle（位是反相的）：那 start 是在**等 TX/RX 起来**，同样需要真实的 MAC/PHY 初始化才会变。

无论哪种，**唯一能让它们改变的是真实的 MAC/PHY 上电初始化（DMA 环 + RF 前端）**，而不是任何宿主钩子。

### 静态确认：**没有任何 blob 代码清 bits 13..15**（搜遍 `libpp.a`）

把 `libpp.a`（54 个成员）解包后逐个 `objdump -dr` 搜 `0x20104CAC` 的访问，只有 `pm.o` 命中，且都是
TX 队列的 block/unblock：

```asm
<hal_pm_unblock_txq>:            # 清 bits 17..19
   lw  a4,0(a5) ; and a4,a4,0xFFF1FFFF ; sw a4,0(a5)
<pm_...>（两处）:                # 置 bits 17..19
   lw  a4,0(a5) ; or  a4,a4,0xE0000   ; sw a4,0(a5)
```

也就是说：**bits 17..19 = "TX 队列被 PM 阻塞"**（软件置/清），而 **bits 13..15 没有任何软件写入点**。
这与我们镜像里 9 处访问的结论一致（唯一清位的那处清的是 17..19）。

所以"等 [15:13] 变 0"等的是**纯硬件状态**，静态层面已无可查的软件路径。

### 极性判据到手：`is_lmac_idle()=1` 而 bits 13..15 也是 1 ⇒ **1 = 空闲**

ROM 导出 `is_lmac_idle = 0x2f800da4`（`esp32s31.rom.pp.ld:58`）。在 start 之前读它，并同时读 `0x20104CAC`：

```text
wifi-init-probe: is_lmac_idle=1 mac=0x0000e000
wifi-init-probe: after ic_mac_init: is_lmac_idle=1 mac=0x0000e000
```

ROM 自己的"LMAC 是否空闲"返回 **1（空闲）**，而寄存器里 bits 13..15 也正好是 **1**。两条独立来源一致：
**这三位是"空闲"标志，不是"忙"标志。**

于是自旋的语义要**反过来读**：

```
while ((REG[0x20104CAC] & 0xE000) != 0) { }   # 等 [15:13] 变成 0
```

等的是"**不再是空闲**"——也就是 blob 在 **启动 MAC**（等引擎变活跃），而不是在等它停下。
`g_mac_deinit_*` 只是 blob 自己的变量名，不能当语义证据（这条判据正好把之前的"deinit 等静止"读法推翻）。

同时试了 ROM 的 `ic_mac_init()`（`0x2f800d9c`）：调用前后 `is_lmac_idle` 仍为 1、`mac` 仍 `0x0000e000`，
自旋照旧——说明"叫一次 ROM 的 MAC init"并不足以让引擎真正跑起来。

**下一步的方向因此明确**：要让 `[15:13]` 变成 0（即 LMAC 变活跃），需要真正的 MAC 启动序列
（`ic_mac_init` + 使能 TX/RX + DMA 环建立），而不是任何"停止/复位"动作。

### 补充读数：`ic_interface_enabled()=0`（接口未使能）

```text
wifi-init-probe: is_lmac_idle=1 ic_interface_enabled=0 mac=0x0000e000
wifi-init-probe: after ic_mac_init: is_lmac_idle=1 mac=0x0000e000
```

ROM 的三个谓词/状态一起读出来，图景很一致：

| 读数 | 含义 |
| --- | --- |
| `is_lmac_idle = 1` | LMAC 空闲 |
| `ic_interface_enabled = 0` | **接口未使能** |
| `0x20104CAC = 0x0000e000` | bits 13..15 = 1（与"空闲"一致） |

所以 blob 的自旋在等"**接口/引擎变成活跃**"，而 `ic_mac_init()` 单独调用**不会**把 `ic_interface_enabled`
翻成 1（调用前后都是 0）。真正使能接口的那一步（多半是带参数的 `ic_mac_init`/`hal_mac` 序列 + DMA 环）
仍是缺口。

### ROM 的 `ic_mac_init` 是跳转桩

`esptool read-mem` 逐字 dump `0x2f800d9c`（ROM 不可变，读取有效）：

```text
0x2f800d9c 0x4f82b06f   # jal x0, +0x164f8  -> 0x2f817294
0x2f800da0 0x5d23806f   # ic_interface_enabled 的桩
0x2f800da4 0x5223306f   # is_lmac_idle 的桩
```

所以 `ic_mac_init` 的真体在 **`0x2f817294`**（`0x2f800d9c + 0x164f8`）。同一段是 16 位压缩指令，
逐字手工解码性价比低；下一步若要继续，直接用
`riscv32-esp-elf-objdump -D -b binary -m riscv:rv32 --adjust-vma=0x2f817294` 反汇编这批 dump 出来的字节。

### 反汇编 `is_lmac_idle` 本体：它读的是 **IC vtable**，不是 `0x20104CAC`

thunk `0x2f800da4` → `j 0x2f8342c6`，真体：

```asm
2f8342c6  addi sp,sp,-16
2f8342d0  li   s0,0                # i = 0
2f8342d2  lui  s2,0x2f080
2f8342d6  li   s1,5                # 5 个接口
2f8342d8  lw   a5,-184(s2)         # a5 = *(0x2f07ff48)   ← IC 上下文指针（g_ic）
2f8342dc  zext.b a0,s0
2f8342e0  lw   a5,220(a5)          # a5 = ic->fns[55]
2f8342e4  jalr a5                  # 调 ic->fns[55](i)
2f8342e6  beqz a0, ret_path        # 返回非 0 就停
2f8342e8  addi s0,s0,1
2f8342ea  bne  s0,s1,0x2f8342d8
```

**两个结论**：

1. `is_lmac_idle` 是通过 **IC 的 vtable**（`*(0x2f07ff48)` 的 `+220` 槽）间接判断的，**并不直接读
   `0x20104CAC`**。所以"它返回 1 而 bits 13..15 也是 1 ⇒ 1=空闲"只是**不矛盾的相关性**，不是证明。
   极性的表述因此降级为**倾向**（文档已按此改写），最终判据要读 `ic->fns[55]` 的真体。
2. **IC 上下文指针在 `0x2f07ff48`**（`g_ic`）——`ic_mac_init` 这类 IC 层函数很可能要它作参数，
   之前那次"无参调用"没生效可能就是 ABI 不对。

### 候选 15：`ic_mac_init(g_ic)`（带 IC 上下文）同样无效

按 `is_lmac_idle` 的反汇编，IC 层函数走 `*(0x2f07ff48)` 的 vtable，所以 `ic_mac_init` 很可能要这个
上下文指针。按此调用（pb142）：

```text
wifi-init-probe: g_ic=0x2f01d3c8
wifi-init-probe: after ic_mac_init(g_ic): is_lmac_idle=1 iface=0 mac=0x0000e000
irq-sample #14336 .. mepc=0x2f009206 mac=0x00fff000 b13=1 b14=1
```

`g_ic` 是一个有效指针（arena 里的对象），调用后**三个读数全不变**、自旋照旧。所以"ABI 不对"这条解释
也被排除——`ic_mac_init` 即使拿到上下文，也不会把接口使能。

**十五个候选全部实验排除。** 剩下的唯一方向是完整实现 MAC 使能链（vtable 里的 `fns[55]` 真体、
`hal_mac_*` 的 TX/RX 使能、DMA 环建立），这已经不是"补一个钩子"能解决的事。

### 决定性读数：`hal_mac_is_dma_enable() = 0` —— **DMA 环没建**

把 ROM 的谓词接进探针（`hal_mac_is_dma_enable = 0x2f800d4c`，无参）：

```text
wifi-init-probe: after ic_mac_init(g_ic): is_lmac_idle=1 iface=0 mac=0x0000e000
wifi-init-probe: dma_enable=0
irq-sample #14336 .. mepc=0x2f009206 mac=0x00fff000 b13=1 b14=1
```

四个读数第一次拼成完整图景：

| 读数 | 值 | 含义 |
| --- | --- | --- |
| `is_lmac_idle` | 1 | LMAC 空闲 |
| `ic_interface_enabled` | 0 | 接口未使能 |
| **`hal_mac_is_dma_enable`** | **0** | **DMA 未使能** |
| `0x20104CAC` | `0x0000e000` | bits 13..15 = 1 |

所以自旋在等的状态跃迁，前提是 **MAC 的 DMA 环被建立并启用**——而我们的宿主层从来没做过这件事
（IDF 里那是 `wifi_hw_start` / `hal_mac` 的活）。这不是"再补一个 osi 钩子"能解决的：缺的是**数据面初始化**。

**踩坑记录**：`hal_mac_get_txq_state`/`hal_mac_get_txq_complete` **带参数**，用垃圾 a0 调会
`store access fault`（实测 `mtval=0xa6b000a`、`mepc=0x4004e0ca`）。ROM 里只有名字带 `is_` 的谓词才可当无参调。

### ⚠ 撤回上一条：`hal_mac_is_dma_enable` 是**恒返回 0 的桩**（2026-11-16）

反汇编 thunk `0x2f800d4c` → `j 0x2f83879a`，真体只有两条指令：

```asm
2f83879a  li  a0,0
2f83879c  ret
```

**它无条件返回 0。** 所以"`dma_enable=0` ⇒ DMA 没使能"这个判读**不成立**——那是常量，不是读数。
上一节把它写成"决定性读数"是错的，已按此撤回。

同时补上 ABI 修正后的实验：`ic_mac_init(0)`（接口号，而不是上下文指针）：

```text
wifi-init-probe: after ic_mac_init(0): is_lmac_idle=1 iface=0 mac=0x0000e000
wifi-init-probe: dma_enable=0        ← 这条现在没有信息量（桩）
无 panic，自旋照旧
```

**现在真正有效的读数只剩两个**：`is_lmac_idle=1`（但它走 IC vtable，不直读寄存器）与
`ic_interface_enabled=0`。要用它们下结论，还得先反汇编 `ic_interface_enabled`（thunk `0x2f800da0`）
确认它不是另一个常量桩——**这是下一次动手前必须做的第一件事**。

### 两个全局符号定名 + `ic_interface_enabled` 是真谓词

`rom_syms.ld` / `esp32s31.rom.pp.ld` 给出：

| 地址 | 符号 |
| --- | --- |
| `0x2f07ff48` | **`pp_wdev_funcs`**（PP/WDEV 的函数表，不是"g_ic"） |
| `0x2f07ff40` | **`wDevCtrl_ptr`**（WDEV 控制块指针） |

`ic_interface_enabled` 的 thunk `0x2f800da0` → `0x2f839372`，真体：

```asm
2f839376  lw   a5,-192(a5)      # a5 = *(0x2f07ff40) = wDevCtrl
2f83937a  lbu  a5,49(a5)        # a5 = wDevCtrl->[49]  ← 各接口的使能位图
2f83937e  srl  a0,a5,a0         # a0 = 位图 >> ifx
2f839382  andi a0,a0,1
2f839384  ret
```

所以 **`ic_interface_enabled(ifx)` 是真函数**：返回 `wDevCtrl->[49]` 的第 `ifx` 位。实测
`ic_interface_enabled(0) = 0` ⇒ **接口 0 的使能位是 0**，这是**有效读数**（与 `hal_mac_is_dma_enable`
那个恒 0 桩不同）。

**下一步的确切目标**：找到**谁把 `wDevCtrl->[49]` 的第 0 位置 1**。在 `/tmp/blobobjs/*.o` 与 `libpp`
里搜 `sb ?,49(base)` 有多个命中（`pp.o` 3 处、`if_hwctrl.o` 2 处、`ieee80211_output.o` 3 处…），
需要按 base 寄存器回溯确认哪一处写的是 `wDevCtrl`——那就是"使能接口"的调用点。

### `wDevCtrl->[49]` 的语义与写入者（`libpp` 静态定位）

`ic_interface_enabled(ifx)` 读的是 `wDevCtrl->[ifx*52 + 49]`（每个接口描述符 52 字节）。在 `libpp.a`
里逐个 `objdump -dr` 搜 `sb ?,49(` 并按所在函数归类：

| 站点 | 函数 | 动作 |
| --- | --- | --- |
| `sb zero,49(a5)` | **`ppEnableQueue`** | 清该接口的"就绪"字节 |
| `sb zero,49(a5)` | `ppSelectNextQueue` | 同上 |
| `sb a4,49(a5)`（a4=1） | **`ppSearchTxframe`** | **置 1**（该接口已有可发的 TX 帧） |

**注意：`wDevCtrl+49` 与 `pp.o` 那三处 `sb ?,49(base)` 不是同一个对象。**

- `ic_interface_enabled` 读的是 **`wDevCtrl+49` 的单个字节位图**（`lbu 49(a5)` 后 `srl by ifx`，地址不含 ifx 缩放）；
  链接镜像同一函数内的读者/写者同形：`0x400315f8 lbu a5,49(a5)`+`srl`、`0x40031612 sb a5,49(s1)`（`s1=0x2f01085c`）。
- `pp.o` 的 `ppSearchTxframe`/`ppEnableQueue`/`ppSelectNextQueue` 用的是 **`base + ifx*52 + 49`**（52 字节步长的
  描述符字段）——那是 TX 队列描述符，**不是** `wDevCtrl`。

所以正确表述是：**`wDevCtrl+49` 是一个单字节位图，第 `ifx` 位表示接口 `ifx` 的某个"就绪/使能"状态**；
`ic_interface_enabled(0)=0` 只说明该位当前为 0，**不能**直接推出引擎状态。

### 修掉一个真实的链接 bug：101 个 ROM 数据符号被做成了空函数桩

`components/wifi-blobs/link/zz_stubs.c` 原本把 `stub-symbols.txt` 里的**每个**符号都生成
`void <sym>(void) {}`。但其中 **101 个是 ROM RAM 里的数据指针**（`rom_syms.ld` 里以
`PROVIDE(name = 0x2f0xxxxx)` 提供），例如：

```
g_chm, g_ic_ptr, g_lmac_cnt_ptr, wDevCtrl_ptr, pp_wdev_funcs,
g_eb_list_desc_ptr, trc_ctl_ptr, xphyQueue, s_bars, regdomain_table, …
```

桩是 `.text` 里的**强定义**，会压过 `PROVIDE`（PROVIDE 只在符号未定义时生效）——于是 **blob 读这些
"指针变量"时拿到的是"一个空函数的地址"**，而不是 ROM RAM 里的真指针。这等于让 blob 的整个
PP/WDEV/CHM 状态层指向垃圾。

修法：`gen-blob-stubs.py` 里解析 `rom_syms.ld`，把这 101 个数据符号排除（桩数 185 → 84）。

上板（pb146）：`esp_wifi_init_internal rc=0`、`register_chipv7_phy rc=0`、无 panic，但**自旋照旧**
（`mac=0x00fff000`，`mepc` 仍是 `0x2f0091fe/0x2f009206`）。所以这个 bug 是**必须修的正确性问题**，
但它不是当前卡点的原因——至少说明 blob 的状态层现在拿到的是真指针，后续观察才可信。

### 调用链归因（**未定案**）：自旋的调用者属于**信道管理路径**

在 `/tmp/blobobjs` 里按重定位搜 `g_chm`（`0x2f07ff88`），命中的是 `wl_chm.o` 的
`chm_acquire_lock / chm_cancel_op / chm_change_channel / **chm_deinit** / chm_end_op / …`。
反汇编 `chm_deinit`：

```asm
chm_deinit:
  lui  s1,%hi(g_chm) ; lw a0,%lo(g_chm)(s1)   # a0 = g_chm
  lui  s0,%hi(g_osi_funcs_p) ; lw a5,0(s0)    # a5 = osi 表
  addi a0,a0,36                               # a0 = g_chm + 36（内嵌的定时器对象）
  lw   a5,232(a5) ; jalr a5                   # 调 osi->fns[58] = _timer_done
  ...                                          # 再调一次 fns[58]
```

即 `chm_deinit` 先 `_timer_done(g_chm+36)`（拆掉信道管理器的定时器），随后走 MAC 拆除。

**注意别过度归因**：`chm_deinit` 的真体只有两次 `_timer_done` 调用，**没有**调用 MAC 拆除包装
（`0x4003eb5a`），所以"自旋在 `chm_deinit` 里"**未被证明**。可证的是：自旋的调用者（`0x4003ef8e`）
**读 `g_chm`**，而 `wl_chm.o` 的 `chm_*` 整族都引用它——所以"自旋的调用者属于**信道管理路径**"是稳妥
的表述，`chm_change_channel`（切信道会触发 MAC 重配）仍是活的候选。

下一步应当去找"进 deinit 之前那次失败"：沿 `wifi_start_process` 的返回值分支看哪一步返回了错误
（trace 里 start 只走到 `alloc → queue_send → semphr_take → swap`，之后就直接进 deinit，说明失败点
很可能就在这几步之间或紧随其后）。

### 信道相关：`set_channel` 在 start 之前被拒（`0x3002`），这不是配置缺失

补上两个读数（pb147）：

```text
wifi-init-probe: set_country(CN,1..13) rc=258
wifi-init-probe: set_channel(6,0) rc=12290      # 12290 = 0x3002 = ESP_ERR_WIFI_NOT_STARTED
wifi-init-probe: wDevCtrl=0x2f01085c pp_wdev_funcs=0x2f01d3c8
```

两点结论：

1. **`set_channel` 必须在 start 之后**（IDF 的语义）——所以"start 前信道是 0"是**正常状态**，
   不是配置缺失；"信道 0 触发 `chm_change_channel` 去 deinit"这条因果因此**不成立**。
2. `wDevCtrl = 0x2f01085c`、`pp_wdev_funcs = 0x2f01d3c8` 都是 **DRAM 里的真指针** ✓ ——
   这正面验证了"解除 101 个数据符号桩化"的修复生效了。

### ★ 修桩之后流程真的前进了：`_phy_enable(2)` 现在**就在自旋之前**被调用

pb147 的 trace（修桩后）在任务上下文里给出完整序列：

```text
trace wifi_clk_en a0=0x0038e7ff
trace phy_enable  a0=0x00000002      ← ★ 以前从未出现！
trace coex_enable a0=0x00000000
trace wifi_reset_mac
trace mutex_lock
trace event_post  a0=0x0000002b a1=0x00000010   ← event 43 / bits 0x10
trace timer_disarm
[进入自旋]
```

两点修正：

1. **候选 2 复活**：早先"`_phy_enable` 在自旋前从未被调用"是在**修桩之前**观测的；修桩后 blob 走得更远，
   确实调了 `_phy_enable(2)`（参数 2 = modem id）。而我们的实现只做"幂等重申时钟位"，**没有做真正的
   PHY 使能/标定**——这正是 IDF 的 `esp_phy_enable(modem)` 该做的事。
2. `event_post(0x2b, 0x10)` 说明 blob 在自旋前向事件系统投了 **event 43**，我们的 `_event_post` 是同步
   派发到自己的 event_bus——若没有 handler 注册，状态机不会推进。

**下一步**：把 PHY 注册/标定**移进 `_phy_enable`**（IDF 的顺序是 `esp_phy_enable` 内部才
`esp_phy_load_cal_and_init()` → `register_chipv7_phy`），而不是像现在这样在探针 init 阶段提前调。

### 把 PHY 注册移进 `_phy_enable`（IDF 的顺序）：仍然自旋

按 IDF 的真实顺序改造：探针 **init 阶段不再**调 `register_chipv7_phy`
（`probe_register_phy_at_init = false`），改由 `_phy_enable(modem)` 钩子在**首次调用**时做
（新增 `Hooks.on_phy_enable` 注入点，探针持有 `phy_init_data`/`cal_data`）。

上板（pb148）：

```text
wifi-init-probe: register_chipv7_phy SKIPPED at init (交给 _phy_enable)
wifi-init-probe: calling wifi_rf_phy_enable()
wifi-init-probe: _phy_enable(modem=0) -> register_chipv7_phy rc=0
trace ... wifi_clk_en → phy_enable → coex_enable → wifi_reset_mac → event_post(0x2b)
irq-sample #19456 .. mepc=0x2f009206 mac=0x00fff000
```

注册在钩子里成功（rc=0），**自旋照旧**。所以"PHY 注册的时机"不是卡点原因——候选 2 再次排除
（这次是在**正确的顺序**下排除的，不再受"修桩前流程没走到"的影响）。

### 补两处观测缺口：`mutex_unlock` 的 note、`event_post` 的处理器计数

1. **`shellMutexUnlock` 之前没有 `note()`** —— trace 里看不到任何解锁行，容易被误读成"只加锁不解锁"。
   已补 `note(3, …)`（id 3 = `mutex_unlock`）。修后 trace 里 `mutex_lock`/`mutex_unlock` 成对出现 ✓。
2. **`event_bus.post` 只做 `(base,id)` 严格相等匹配**，而 IDF 允许用 `ESP_EVENT_ANY_ID`(-1) 注册通配处理器。
   已加 `or entries[i].id == -1`，并新增 `undispatched` 计数（`n == 0` 的 post 次数），探针在
   `event_post` 的 trace 里一并打印。

板侧读数（pb150）：

```text
trace event_post id=43 bits=0x10 handlers=0 undispatched=0
```

`handlers=0` 是**预期**的：探针没有注册任何处理器；而 event 43 正是 `WIFI_EVENT_WIFI_READY`（对应用的
通知）。所以"event 43 落空导致状态机不推进"这条**不成立**——它是信息性事件，不需要处理器。

（注：打印发生在 `note()` 里、`event_bus.post` 之前，所以 `undispatched` 显示的是这次 post **之前**的值。）

### 干净路径复跑：去掉探针侧所有手动 PHY/MAC 调用，仍自旋

把探针里三处"实验遗留"的手动调用全部关掉（`probe_manual_phy_calls = false`、
`probe_manual_ic_mac_init = false`）：`wifi_rf_phy_enable`、`phy_fe_txrx_reset`、`ic_mac_init(0)` 都不再
由探针调用，PHY 注册只在 blob 经 `_phy_enable` 触发时发生——与 IDF 的 wrapper 行为一致。

板侧（pb151）：

```text
（manual calls: 0 次）
_phy_enable(modem=0) -> register_chipv7_phy rc=0
trace ... phy_enable → coex_enable → wifi_reset_mac → mutex_lock → mutex_unlock → timer_disarm
irq-sample #16896 .. mepc=0x2f009206 mac=0x00fff000
无 panic
```

**结论**：探针侧的手动调用不是卡点原因，也不是"半初始化干扰"——在完全干净的 IDF 顺序下自旋照旧。
trace 尾部的顺序（`phy_enable → coex_enable → wifi_reset_mac → 锁/解锁 → timer_disarm → 自旋`）现在
是可信的基线。

### 心跳加打 `a0`/`a1`：给"在等哪个外设"点名

样本行现在带 `frame.a0/a1`。板侧读数（pb152）：

```text
# ROM 轮询助手里的样本
irq-sample #1 mepc=0x2f83efda mac=0x0000e000 a0=0x0000e080 a1=0x00000073
irq-sample #7 mepc=0x2f83efda mac=0x0000e000 a0=0x00006080 a1=0x00000061
# 自旋样本（稳定）
irq-sample #14336 mepc=0x2f009206 mac=0x00fff000 a0=0x00000640 a1=0x2f01cab0
```

- 落在助手 `0x2f83efda` 的样本 `a0` 是它读的**外设索引**，`a1` 是它拿到的字节值。
  （**注意**：ADR 早先那个公式 `(*(u32*)(((a0+0x2038A)<<12)+0x1C) >> 16) & 0xFF` 是**近似重构**，
  代入实测 `a0=0xE080/0x6080` 算出的地址落不进外设窗口，说明反汇编时漏了中间立即数——别直接套用。）
- 自旋样本的 `a0=0x640`、`a1=0x2f01cab0`（arena 指针）**完全稳定**——自旋函数里这两个寄存器不再变化。

### 定时器计数复测（当前构建）：`setfn` 14 次、**`arm` 0 次**、`fire` 0 次

流程变了但结论没变：blob 只注册回调、从不 arm。所以"超时逃逸被饿死"这条**不适用**（没有已武装的定时器）。

**但要记住一个结构性风险**：`serviceTimers()` 只在**让出点**推进，而自旋函数从不让出——一旦将来有定时器
被 arm，它的到期回调永远不会被调用。届时应把 `serviceTimers()` 也挂到采样器 ISR（每 2 ms 一次）里。

### 三个全局指针的实际值 + 自旋的 `a1` 不是 `g_chm`

在 start 之前打印（pb153）：

```text
wifi-init-probe: wDevCtrl=0x2f01085c pp_wdev_funcs=0x2f01d3d8 g_chm=0x2f015264
irq-sample #14336 mepc=0x2f009206 mac=0x00fff000 a0=0x00000640 a1=0x2f01cab0
```

三点：

1. 三个指针都是 **arena 里的真实对象** ✓（`wDevCtrl` 在 0x2f01_0xxx，`pp_wdev_funcs`/`g_chm` 在 0x2f01_5xxx）；
2. **`a0`/`a1` 是调用者的遗留寄存器，不是自旋操作的对象**：自旋函数 `0x2f009190` 只用
   `a4/a5/a3/s0/s1`，**从不读 a0/a1**。所以 `a0=0x640`（`ets_delay_us` 的周期数残留）与
   `a1=0x2f01cab0`（调用者的一个指针残留）**没有额外信息**，不必去给它定名；
3. `a1 ≠ g_chm` 只说明"调用者手里的那个指针不是 g_chm"，**不能**推出"自旋操作另一个对象"。
   "自旋在信道管理路径"的归因依旧只靠"调用者读过 `g_chm`"这一条弱证据。

### 给 `0x2f01cab0` 找归属：不属于任何已知全局（它是 start 期间才分配的）

把一批 ROM 数据指针在 start 之前打出来（pb154）：

```text
g_hmac_cnt_ptr=0x2f0129dc   g_ic_ptr=0x2f012194      g_eb_list_desc_ptr=0x2f00f660
g_lmac_cnt_ptr=0x2f0149b8   pp_sig_cnt_ptr=0x2f011f68  trc_ctl_ptr=0x2f010834
xphyQueue=0x2f01dbd0        g_coex_param_ptr=0x00000000
```

**没有一个等于 `0x2f01cab0`**（自旋的 `a1`）。所以那个对象**是在 start 期间才分配的**（或来自局部指针）。

要给它定名，下一步应记录 start 期间**所有 arena 分配**的返回地址，找出谁拿到 `0x2f01cab0`——
这需要给 `_malloc/_zalloc/_calloc` 加"返回地址落在 0x2f01c000..0x2f01d000 就打印"的过滤。

## ★★ 与 IDF 的实测对照（2026-11-17）：**POWER_ST 是 0 vs 0x64646400**

按"和已知能跑的系统对照"这条最后的路，把 IDF 自己的 `examples/wifi/getting_started/station`
（`idf.py --preview set-target esp32s31` 可直接构建）加上一个每秒打印寄存器的小任务，烧到**同一块板**：

```text
DIAG: MAC_ST=0x00000000 CLK_CONF1=0x00000000 RST_CONF=0x00000000 POWER_ST=0x64646400
DIAG: esp_wifi_start() ...
DIAG: esp_wifi_start() returned OK          ← ★ IDF 的 start 直接返回，不卡
DIAG: MAC_ST=0x00000000 CLK_CONF1=0x0038e7ff RST_CONF=0x00000000 POWER_ST=0x64646400
DIAG: MAC_ST=0x10004000 CLK_CONF1=0x0038e7ff ...
```

对照我们的裸机探针：

| 寄存器 | 我们的裸机 | **IDF（同一块板，正常工作）** | 判定 |
| --- | --- | --- | --- |
| `0x20104CAC`（MAC 状态） | **0x0000e000**（复位态，bits 13..15=1） | **0x00000000**（偶尔 0x10004000） | **1 = busy/未就绪** ⇒ 我们的 MAC 从未就绪 |
| `CLK_CONF1`（0x20109C14） | `0x0038e7ff` | **`0x0038e7ff`** | ✅ **完全一致**，时钟位没配错 |
| **`CLK_CONF_POWER_ST`（0x20109C0C）** | **`0x00000000`** | **`0x64646400`** | ❌❌ **决定性差异**：我们的电源域状态是 0，IDF 是 0x64/0x64/0x64 |
| `RST_CONF`（0x20109C10） | — | `0x00000000` | 正常（无复位在挂） |

**三条结论**：

1. **极性钉死**：MAC 真正跑起来时 `0x20104CAC` 是 **0**，所以 bits 13..15 的 **1 = busy/未就绪**。
   我们读到的 `0x0000e000` 说明 **MAC 从未进入就绪状态**——之前"1 = idle"的倾向**被推翻**。
2. **时钟配置没问题**：`CLK_CONF1` 与 IDF 逐位相同（`0x38e7ff`）。
3. **真正缺的是电源域**：`CLK_CONF_POWER_ST = 0` vs IDF 的 `0x64646400`。也就是说
   `SYSCON_FORCE_ON` 之类的"使能位"并没有让三个域真正上电（与技能里"使能位 ≠ 上电"那句一致），
   而 MAC 引擎在没有真正上电的域里永远报 busy ⇒ 自旋永远等不到。

**下一步**：查 `0x64646400` 是怎么来的——`CLK_CONF_POWER_ST` 的三个字节（0x64/0x64/0x64）分别是
modem APB / modem PERI / WIFI 域的"实际状态"。在 IDF 侧读它前后各打一次（在 `esp_wifi_init` 前后），
就能定位是**哪一步**把域真正打开；我们的 bring-up 缺的正是那一步。

### IDF 侧的 modem 块 dump：`POWER_ST` 是 **init/start 期间**从 0 变成 0x64646400 的

在 IDF 的 station 例程里加了三处整块 dump（`MODEM_SYSCON` / `MODEM_PWR` / `MODEM_LPCON` 各 8 字）：

| 采样点 | `SYSCON+0c`(POWER_ST) | `LPCON+18` | `MAC_ST` |
| --- | --- | --- | --- |
| `app_main` **之前**（还没 init） | `0x00000000` | `0x00000001` | **`0x0000e000`** |
| `esp_wifi_start` 之后 | **`0x64646400`** | `0x00000007` | **`0x00000000`** |
| 连接重试阶段 | `0x64646400` | `0x00000001` | **`0x00ff1000`** |

四条结论：

1. **`MAC_ST = 0x0000e000` 确实是复位态**——IDF 在 init 之前也是这个值 ✓（我们的"复位基线"读数得到独立验证）；
2. 电源域在 **init/start 期间**真正上电（`POWER_ST` 0 → `0x64646400`），而我们的实现无论怎么调 `FORCE_ON`
   都停在 0；
3. `LPCON+18` 在 start 期间是 `0x7`（bits 0,1,2），之后回到 `0x1`——**我们的实现写的是 `0xF`**（多了 bit3），
   而且**从未回到 0x1**；
4. **`MAC_ST = 0x00ff1000` 是工作系统的正常值之一**（bits 12 + 16..23），我们读到 `0x00fff000` 多出的正是
   bits 13..15 —— 与"引擎忙"一致。

**下一步**：`MODEM_PWR` 整块在 IDF 里**始终为 0**，所以域上电不是它做的。要继续找那个写操作，应在 IDF 侧
再加 dump：`HP_SYS_CLKRST`（0x20587000..，`modem_conf` 在 0x205871E0）与 PMU 相关寄存器，在
init/start 前后各一次，然后与我们的值逐字对比。

### 顺着 POWER_ST 追：两条被排除的路径 + 一条对齐的改动

1. **`esp_wifi_bt_power_domain_on()` 在 S31 上是空函数**。它解除 `RTC_CNTL_DIG_PWC_REG` 的
   `WIFI_FORCE_PD`、脉冲 `SYSCON_WIFI_RST_EN`、解除 `RTC_CNTL_DIG_ISO_REG` 的 `WIFI_FORCE_ISO`——
   但整段都在 `#if SOC_PM_MODEM_PD_BY_SW` 里，而 **S31 的 `soc_caps.h` 只定义了
   `SOC_PM_SUPPORT_MODEM_PD=1`，没有 `SOC_PM_MODEM_PD_BY_SW`** ⇒ 那段在 S31 上被编译剔除。
   所以"我们漏了 RTC_CNTL 的掉电解锁"这条**不成立**。
2. **标定数据不是差异**：把 IDF 跑过之后的 `phy_init` NVS 分区（flash `0xf000`，4 KB）读出来，
   **整块是 0xFF（空）** ⇒ IDF 也是当场做标定，没有可复用的出厂数据。
3. **`wifi_bt_common_module_enable()` 在 S31 上 = `modem_clock_module_enable(PERIPH_PHY_MODULE)`**，
   其 deps 是 `MODEM_ADC_COMMON_FE | MODEM_PRIVATE_FE | SOC_PLL_SOURCE_CG | I2C_MASTER` ——
   正是我们手写的那批时钟位。

**一处按 IDF 对齐的改动**：IDF 的 `LPCON+18` 在 start 期间是 **`0x7`**（bit0 wifipwr / bit1 coex /
bit2 i2c_mst），之后回到 `0x1`；我们此前写的是 **`0b1111`**（多开了 bit3 `clk_lp_timer`）。
已改成 `0b0111` 并上板——`POWER_ST` 仍是 0、自旋照旧，所以 bit3 不是原因，但对齐本身是对的。

### ★ 收窄：`POWER_ST` 是 **`esp_wifi_init` 期间**变成 `0x64646400` 的（不是 start）

在 IDF 例程里加了 `before/after esp_wifi_init` 两处 dump：

```text
DUMP[app_main-before-init]      SYSCON+0c=0x00000000  LPCON+18=0x1  MAC_ST=0x0000e000
DUMP[before-esp_wifi_init]      SYSCON+0c=0x00000000  LPCON+18=0x1  MAC_ST=0x0000e000
DUMP[after-esp_wifi_init]       SYSCON+0c=0x64646400  LPCON+18=0x1  MAC_ST=0x00000000   ← ★ 就在这里
DUMP[after-esp_wifi_start]      SYSCON+0c=0x64646400  LPCON+18=0x7  MAC_ST=0x00000000
```

**这大幅收窄了范围**：

1. 域上电与 `MAC_ST → 0` **都发生在 `esp_wifi_init` 内部**，而 `esp_wifi_start` 只额外把 `LPCON+18` 从
   `0x1` 提到 `0x7`（start 期间才开 i2c_mst/coex/wifipwr 时钟）；
2. 我们**也调了同一个 `esp_wifi_init_internal`** 并拿到 rc=0，但 `POWER_ST` 仍是 0 ⇒ 差别不在"调用哪个
   函数"，而在**我们传进去的 `wifi_init_config_t`**（IDF 用的是 `WIFI_INIT_CONFIG_DEFAULT()` 那一整套
   Kconfig 值，我们手写了一份）。

**下一步**：逐字段对比我们的 `InitConfig` 与 IDF 的默认值（重点 `nvs_enable`、`feature_caps`、
`tx_buf_type`、`static/dynamic_*_buf_num`、`magic`/`version`），把差异逐个试；`nvs_enable` 尤其可疑
——blob 可能据此跳过 PHY/校准路径。

### ★ 重要更正：`CLK_CONF_POWER_ST`(0x20109C0C) 是**可写的 ICG 位图**，不是只读状态

`hal/esp32s31/modem_syscon_ll.h:209-241` 里的 `modem_syscon_ll_set_{ieee802154,fe,bt,...}_icg_bitmap`
写的都是 `hw->clk_conf_power_st.*_st_map` —— 这个寄存器是**各域时钟门控（ICG）的位图**：

| 位 | 域 |
| --- | --- |
| 31:28 | modem_apb |
| 27:24 | modem_periph |
| 23:20 | wifi |
| 19:16 | bt |
| 15:12 | fe |
| 11:8 | ieee802154 |

IDF 在 init 之后的值 `0x64646400` 就是"这些域全部解除门控"（6/4/6/4/6/4）。而
`modem_clock_module_enable()` 里的 `modem_clock_module_icg_map_init_all()` 负责编程它
（S31 有 `SOC_PM_SUPPORT_MODEM_CLOCK_DOMAIN_ICG`）。

**我们的探针此前从没写过它**，所以所有域都被门控。已补上写入（照 IDF 的值）：

```text
wifi-init-probe: ICG_POWER_ST 0x0 -> 0x64646400 (IDF=0x64646400)
wifi-init-probe: CLK_CONF_POWER_ST=0x64646400 apb=6 peri=4 wifi=6
```

**但自旋照旧**（`mac=0x00fff000`）。所以"ICG 未解除"是**必要条件但不是充分条件**：解除门控之后，
还差让 MAC 引擎真正跑起来的那一步（很可能在 `esp_wifi_init_internal` 内部，由我们那份手写的
`wifi_init_config_t` 决定走哪条路径）。

**注意**：这条更正推翻了本节前面"POWER_ST 是只读状态、说明域没上电"的读法——它是**可写位图**，
我们读到 0 只说明**我们没解除门控**，不能直接说"硬件没上电"。

### 三处按 IDF 对齐的实测结果（2026-11-17）

按 IDF `after-esp_wifi_init` 的 `MODEM_SYSCON` 值逐字对齐，并补上 IDF wrapper 的 `coex_init()`：

| 寄存器 | IDF | 我们（对齐前） | 结论 |
| --- | --- | --- | --- |
| `+00 test_conf` | `0x00000100` | **已经是 `0x100`** | ✅ 本来就一致 |
| `+04 clk_conf` | `0x00201002` | **已经是 `0x00201002`** | ✅ 本来就一致（模拟前端时钟由 blob 自己设） |
| `+08 force_on` | `0x00000000` | `0x1c` | ⚠ **不能清 0**：清了之后 `phy_open_fe_bb_clk` 的写序列**直接 stall**（实测日志停在 `write 0x20107C80`）。IDF 的 0 是因为它有别的上电路径，我们靠 FORCE_ON 才不 stall |
| `+0c ICG` | `0x64646400` | 已补写，读回一致 | ✅ 但自旋不变 |

另外补上了 **IDF wrapper 的 `coex_init()`**（在 `esp_wifi_init_internal` 之前；`wifi_init.c` 的顺序是
`coex_init(); esp_wifi_set_log_level(); esp_wifi_power_domain_on(); esp_wifi_init_internal(config);`）：

```text
wifi-init-probe: calling coex_init() (IDF wrapper 顺序)
wifi-init-probe: coex_init returned
wifi-init-probe: esp_wifi_init_internal rc=0
irq-sample #14336 .. mac=0x00fff000
```

**`coex_init` 单独也不解开自旋**（但它是 IDF 确实会做、我们此前漏掉的一步，保留）。

至此"寄存器/时钟/顺序"这一层能对齐的都对齐了，剩下的差异只剩 **`wifi_init_config_t` 的字段值**
（IDF 用 `WIFI_INIT_CONFIG_DEFAULT()` 的一整套 Kconfig 值）。

### 补齐 `wifi_init_config_t` 的字段（按 IDF sdkconfig）：仍自旋

`defaults()` 之前漏设的字段按 `/tmp/idfprobe/build/config/sdkconfig.h` 补齐：

| 字段 | 值 | 来源 |
| --- | --- | --- |
| `ampdu_rx_enable` | 1 | `CONFIG_ESP_WIFI_AMPDU_RX_ENABLED` |
| `ampdu_tx_enable` | 1 | `CONFIG_ESP_WIFI_AMPDU_TX_ENABLED` |
| `rx_ba_win` | 6 | `CONFIG_ESP_WIFI_RX_BA_WIN` |
| `tx_hetb_queue_num` | 3 | `CONFIG_ESP_WIFI_TX_HETB_QUEUE_NUM` |
| `sta_disconnected_pm` | true | `CONFIG_ESP_WIFI_STA_DISCONNECTED_PM_ENABLE` |

板侧（pb161）：`esp_wifi_init_internal rc=0`、ICG 写入生效，**自旋照旧**（`mac=0x00fff000`）。

**还没对齐的字段**：`feature_caps`（`WIFI_FEATURE_CAPS` 位掩码，最可能影响 blob 走哪条初始化分支）、
`cache_tx_buf_num`、`csi_enable`、`amsdu_tx_enable`、`nano_enable`、`wifi_task_core_id`、
`dump_hesigb_enable`、`privacy_enhancements`、`rmac_auto_reset_int`。

**下一步**：让 IDF 例程把 `WIFI_INIT_CONFIG_DEFAULT()` 的各字段值打印出来（一次 build 即可），
照抄进 `defaults()`——尤其是 `feature_caps`。

### `wifi_init_config_t` 已与 IDF **逐字段一致**（`feature_caps=0x1a1`）——仍自旋

让 IDF 例程把 `WIFI_INIT_CONFIG_DEFAULT()` 的每个字段打印出来，逐项核对：

```text
CFG: static_rx=10 dyn_rx=32 tx_type=1 static_tx=0 dyn_tx=32 rxmgmt_type=0 rxmgmt_num=5
CFG: cache_tx=0 csi=0 ampdu_rx=1 ampdu_tx=1 amsdu_tx=0 nvs=1 nano=0 rx_ba_win=6
CFG: task_core=0 beacon_max=752 mgmt_sbuf=32 feature_caps=0x1a1 sta_pm=1 espnow=7 hetb=3
```

我们此前唯一不同的是 **`feature_caps`（0 vs `0x1a1`）**，已补上。板侧（pb162）：
`esp_wifi_init_internal rc=0`、ICG 写入生效、**自旋照旧**（`mac=0x00fff000`）。

**至此"宿主能提供的输入"已全部对齐**：

| 层 | 状态 |
| --- | --- |
| 时钟（`CLK_CONF1` / ICG / LPCON / `HP_SYS_CLKRST`） | ✅ 与 IDF 一致 |
| `MODEM_SYSCON` `+00`/`+04` | ✅ 本来就一致 |
| `force_on` | ⚠ 我们保留 `0x1c`（清 0 会 stall），IDF 为 0 但有别的上电路径 |
| `coex_init()` | ✅ 已按 IDF wrapper 顺序补上 |
| `wifi_init_config_t` | ✅ **逐字段一致**（含 `feature_caps=0x1a1`） |

所以卡点**不在**这些可对齐的输入里。剩下的差异只能在 IDF 宿主侧的其他部分（`esp_netif` 创建、
事件处理器注册、`esp_wifi_start` 前后的 netif 绑定），或者 blob 内部依赖某个我们尚未实现的 osi 钩子
（尽管 `_coex_enable`/`_phy_enable`/`_wifi_clock_enable` 都已实现并被调用）。

**下一步建议**：在 IDF 例程里**不创建 netif / 不注册事件**，看 `esp_wifi_start` 是否仍返回 OK——
以此判断"宿主还提供了什么 blob 依赖的东西"。

### 隔离实验：IDF **不建 netif、不注册事件**，`esp_wifi_start` 仍返回 OK

把 IDF 例程里的 `esp_netif_init()` / `esp_event_loop_create_default()` /
`esp_netif_create_default_wifi_sta()` / 两个事件处理器注册全部关掉后重跑：

```text
DIAG: esp_wifi_start() ...
DIAG: esp_wifi_start() returned OK
SYSCON+0c = 0x64646400   MAC_ST = 0x00000000
```

**结论**：netif 与事件系统**不是** blob 的必需输入。宿主侧的最小集合是
`esp_phy_enable`（经 osi 钩子）+ `esp_wifi_init` + `set_mode` + `esp_wifi_start` —— 与我们的探针结构一致。

**因此卡点只可能在 osi 钩子的"行为"上**（不是配置、不是时钟、不是 netif）。已经实现并被调用的有
`_phy_enable` / `_wifi_clock_enable` / `_coex_enable` / `_timer_*` / `_event_post`；尚未验证语义是否与
IDF 一致的候选：`_set_isr` / `_set_intr` / `_clear_intr`（中断注册）、`_wifi_clock_disable`、
`_wifi_reset_mac`（已实现但可能语义不同）、`_event_post` 的同步派发语义。

**下一步**：把 IDF 的 `esp_adapter.c` 里每个 `._xxx = wrapper` 的**真实实现**逐个对照我们的钩子，
重点看 `_set_isr`/`_set_intr`/`_clear_intr`（它们决定 blob 的中断能不能装上）与 `_event_post`。

### 中断注册钩子已真实化，但 blob 在自旋前**根本没调它们**

把三个空桩改成真实实现（IDF 对应 ROM 原语）：

| 钩子 | 实现 |
| --- | --- |
| `_set_intr(cpu, src, num, prio)` | `intr_matrix_set(cpu, src, num)`（ROM `0x2f800768`） |
| `_set_isr(n, f, arg)` | `intr_handler_set(n, f, arg)`（ROM `0x2f800764`） |
| `_ints_on(mask)` / `_ints_off(mask)` | CLIC 每输入 ctrl bit8（IE）+ `csrs/csrc mie` |

`rom_syms.ld` 补上 `intr_handler_set`/`intr_matrix_set`/`ets_intr_register_ctx`/`ets_intr_lock/unlock`。
`chain_other_irqs` 本来就是 `true`（非 25 的输入会转发给 ROM 的 dispatcher）。

板侧（pb165）：**trace 里一条 `set_intr`/`set_isr` 都没有** —— blob 在进入自旋之前**从未安装中断处理器**。
所以"中断注册被空桩吞掉"这条**不解释当前卡点**（虽然这些实现本身是正确的、应当保留）。

**当前状态小结**：宿主侧能对齐/能实现的都已到位（时钟、ICG、config 逐字段、`coex_init`、中断注册原语），
自旋依旧。剩下的最可能方向是 **`_phy_enable`/`_wifi_clock_enable` 的语义深度**（IDF 的实现还会
`phy_wifi_enable_set(1)`、`modem_clock_module_icg_map_init_all()` 等），或 blob 内部依赖某个
我们尚未观察到被调用的钩子。

### 把 CLK_CONF1/FORCE_ON 推迟到 start 阶段（照 IDF 的相位）：**行不通**

IDF 的 `after-esp_wifi_init` 里 `CLK_CONF1 = 0`（Wi-Fi 时钟要到 start 才开），而我们一直是在 init 就写
`0x38e7ff`。于是试了"init 不写、交给 `_wifi_clock_enable`"：

```text
wifi-init-probe: CLK_CONF1 SKIPPED at init (交给 _wifi_clock_enable)
wifi-init-probe: SYSCON_FORCE_ON SKIPPED at init
（之后日志直接停住：连 calling esp_wifi_start 都没到，无 panic）
```

**结论**：`FORCE_ON` 必须**早于** PHY 的 FE/BB 时钟写序列，否则那条写序列直接 stall（与之前"清 force_on
会让 `phy_open_fe_bb_clk` 卡死"是同一件事）。所以"相位对齐 IDF"这条路在我们的裸机 bring-up 上不成立
——IDF 能等，是因为它有别的上电路径。

**顺带记下一条还没试的真实差异**：IDF 的 `esp_phy_enable_wrapper` 是
`esp_phy_enable(PHY_MODEM_WIFI); phy_wifi_enable_set(1); ...`，而 **`phy_wifi_enable_set` 定义在
`libphy.a` 里**（`esp_phy_init.h:288` 只有声明）。如果 libphy 的代码按这个标志门控，我们的 `_phy_enable`
就少了一步——下一步值得把它加进钩子。

### 补上 `phy_wifi_enable_set(1)`（IDF wrapper 的真实一步）：仍自旋

`phy_wifi_enable_set` 不在 libphy.a，而是 **ROM `0x2f80145c`**（`esp32s31.rom.phy.ld:176`）。
已加进 `_phy_enable`（在 ICG 写之后）：

```zig
const phy_wifi_enable_set = @extern(*const fn (u8) callconv(.c) void, .{ .name = "phy_wifi_enable_set" });
phy_wifi_enable_set(1);
```

板侧（pb168）：`esp_wifi_start` 正常进入、无 panic、**自旋照旧**（`mac=0x00fff000`）。

**至此 IDF 宿主侧能列举出来的步骤都做了**：时钟（CLK_CONF1/ICG/LPCON/HP_SYS_CLKRST）、`coex_init`、
`phy_wifi_enable_set(1)`、`register_chipv7_phy`、中断注册原语、`wifi_init_config_t` 逐字段。

**剩下唯一一个已确认的结构性差异还没消除**：**采样器占着 TIMG0_T0 / CLIC 输入 25，而 blob 的 tick
也是它**——我们的 ISR 自己 ack 并重装，blob 的 tick ISR 永远不会被服务。要验证这条，必须把采样器挪到
**T1 / 输入 26**（矩阵 `0x20585068`、CLIC `0x10801068`、mie bit26、`t1config +0x24`、
`t1alarmlo +0x28`、`t1alarmhi +0x2c`、`int_*` 的 bit1），让输入 25 转发给 ROM dispatcher。

### 把采样器挪到 T1/输入 26 的尝试：**数据无效（是中断风暴），已回滚**

想把 T0/输入 25 让给 blob 的 tick，把采样器改到 T1/输入 26。板侧结果看着"输入 25 一次都没触发"，
但那份数据**不可用**：

- 采样数在 ~40 s 内到 **854016**（≈ 21 kHz，而设定是 2 ms = 500 Hz）；
- 前几条样本 `mepc` 全是 `0x4004a764` —— 典型的**同一 PC 风暴**。

根因是我写错了 T1 的三个常量（`soc/esp32s31/register/soc/timer_group_reg.h` + `hp_sys_clkrst_reg.h`）：

| 我写的 | 实际 |
| --- | --- |
| `t1alarmlo = timg0 + 0x28` / `t1alarmhi = +0x2c` | 那是 **T1LO/T1HI（计数器）**；alarm 是 **+0x34 / +0x38** |
| `ctrl_t1_clk_en = 1 << 6` | **bit 8**（bit 6 是 `T1_SRC_SEL[0]`，会改时钟源） |

alarm 目标因此恒为 0、立刻匹配 → 风暴。**已把这段 T1 支持整体删除**（不留错常量），采样器回到
T0/输入 25 自 ack，并验证基线恢复：

```text
esp_wifi_init_internal rc=0
calling esp_wifi_start (idle_calls=199)
irq-sample #11776 .. mepc=0x2f009206 mac=0x00fff000
```

**若以后还要挪采样器**，正确的 T1 参数是：`config +0x24`、`alarm lo/hi +0x34/+0x38`、
`counter lo/hi +0x28/+0x2c`、`update +0x30`、`int_ena/int_st/int_clr` 的 **bit1**、时钟使能 **bit8**。

### 两个真实缺陷已修：`cal_data` 少 10 字节、中断钩子的 note id 撞号

1. **`cal_data` 缓冲区尺寸错误**：`esp_phy_calibration_data_t` = `version[4] + mac[6] + opaque[1894]`
   = **1904 字节**，而探针只声明了 `[1894]u8` 并把 `&cal_data` 当结构体起点传给 `register_chipv7_phy`
   ——库会把前 10 字节当 version/mac，并**读写数组末尾之后 10 字节**（越界）。
   已改为 `[1904]u8`、清零，并按 IDF 的路径在偏移 4 写入 station MAC（`1c:29:04:d1:99:28`）。
2. **note id 撞号**：`note(2)` 同时被 `shellSetIntr` 与 `shellMutexLock` 使用、`note(4)` 被
   `shellSetIsr` 与 `shellQueueRecv`、`note(5)` 被 `shellIntsOn` 与 `shellQueueSend` ——
   ——但这**不会**让"blob 没调 `_set_intr`/`_set_isr`"变成假阴性：两者的 `a0` 是**小整数**
   （`shellSetIntr` 是 `(src<<8)|num`，`shellSetIsr` 是中断号），而真实的 `mutex_lock`/`queue_recv`
   行的 `a0` 都是指针（`0x2f01d370` 之类）。用 `a0=0x0000` 过滤即可确认它们确实没被调用。
   仍给三个钩子换成独立 id（**31/32/33**）并把 `hook_ids` 补齐到 34 项——这是**未来防错**，不是纠正。

**修完后的板侧读数（pb172）**：

```text
_phy_enable(modem=0) -> register_chipv7_phy rc=0     ← 不再越界
（trace 里仍然没有任何 set_intr/set_isr/ints_on）    ← 用独立 id 复核，结论成立
calling esp_wifi_start ... 自旋 mac=0x00fff000
```

所以两处都是**必须修的正确性问题**，但都不改变卡点。

### 决定性实验：把输入 25（blob 的 tick）**ack 后转发给 `rom_mtvec`** → `instruction access fault`

按"ack 再转发"的正确顺序试了一次（先 `ackT0Interrupt` 清 int_st + 重装 alarm，再 `return true` 让入口
跳到 `rom_mtvec & ~3`）：

```text
panic: exception code=1 (instruction access fault) cause=0x8000001
panic: mepc=0x2f8210d2 mtval=0x2f8210d2
panic: ra=0x2f812326
```

**`mepc == mtval == 0x2f8210d2`** ⇒ 跳过去的目标**不是可执行代码**。这正面证实了此前的判断：
`mtvec = 0x2f801703` 的低 2 位是 **CLIC 模式**，掩位后的 `0x2f801700` 是**向量表基址**，
不是 common 入口。所以"把中断转发给 ROM 入口"这条路**在 CLIC 模式下不成立**——要转发必须走
**`mtvt`（向量表）里的第 `id` 项**，那是另一套机制（CSR 号实现相关）。

已回滚（输入 25 恢复自 ack、不转发），基线不受影响。

### 按 IDF 的形状补上"应用侧 handler 表 + 自己的分发"

IDF 的 `intr_handler_set` **不是 ROM 的**：`components/riscv/interrupt.c:36` 写的是应用静态数组
`s_intr_handlers[core][int_no]`（:22），由应用自己的 `vectors.S`/`vectors_clic.S` 分发。
ROM 的 `PROVIDE(intr_handler_set = 0x2f800764)` 只在符号**未定义**时才生效——我们没链接
`components/riscv`，所以 `_set_isr` 一直落到 **ROM 的那张表**上，而 ROM 的分发器正藏在我们覆盖掉的
`mtvec` 后面 ⇒ **handler 即使装上了也永远跑不到，而且 ROM 的表我们也读不到**。

已按 IDF 的形状补齐：

| 件 | 实现 |
| --- | --- |
| 应用侧表 | `trap.zig` 里 `handlers[64]` + `setHandler`/`getHandler` |
| `_set_isr(n, f, arg)` | **同时**写我们的表与 ROM 的 `intr_handler_set` |
| `trapDispatch` | **优先**查我们的表：有 handler 就直接 `f(arg)`（T0 先 ack）；没有才走原来的逻辑 |
| `_set_intr(cpu, src, num, prio)` | `intr_matrix_set` **加** CLIC 每输入 ctrl 的 `[31:24]` 优先级（IDF 的 `set_intr_wrapper` 两步都做） |

板侧（pb176）：基线不变（`calling esp_wifi_start` 到达、无 panic、自旋 `0x2f009206`）——因为 blob
**至今没调用 `_set_isr`**，表是空的。这套机制现在是**正确且可用**的：一旦 blob 真的装 handler，它就会
被我们的 trap 调用（而不是落进 ROM 那张够不着的表）。

### ROM 的 handler 表找到了，而且**输入 25 是空的**

反汇编 `intr_handler_set`（`0x2f800764` -> `j 0x2f80192c`）拿到它的实现，地址是**硬编码的**：

```asm
2f80192c: lui  a5,0x2f07f ; slli a0,a0,3 ; addi a5,a5,112 ; add a5,a5,a0
2f801938: sw   a1,0(a5)   ; sw a2,4(a5)  ; ret
2f80193e: addi a0,a0,-16  ; ... 查表 ; lw a4,0(a5) ; beqz a4,ret ; lw a0,4(a5) ; jr a4
```

即 **表在 `0x2f07f070`**，每项 `{fn, arg}` 8 字节；紧跟其后的 `0x2f80193e` 就是 ROM 的分发器
（`input - 16` 后查表，空则直接返回）。**ROM 读合法**，所以这张表我们读得到。

**两次读数，结论以 app 侧为准**：

| 方式 | 读数 | 判读 |
| --- | --- | --- |
| 调试口 esptool 直读（64 字） | `table[1]=0x2f8117f4/0x2f07f018`、`table[5]=0x2f00133c`，`table[25]=0` | **来源未定**（暖复位残留或调试口别名）；它**不可能**是"ROM 启动自装的项"——那样 CPU 侧在自旋里也该看到它们，而 CPU 侧看到的是 0。已被 CPU 侧证据取代 |
| **自旋锚定扫描 + 哨兵自检**（trap 在**第一个 `mepc==0x2f009206`** 的 input 25 上先 `intr_handler_set(30, sentinel, 0x5a5a5a5a)`，再 `romHandler(i)` 扫 32 项，并读 `mtvt`） | `romtbl-scan n=32 (sample 631) sentinel[30]=0x4004c85a arg=0x5a5a5a5a`；`mtvt=0x0`；`romtbl[30] fn=0x4004c85a arg=0x5a5a5a5a`，**再无其它项** | **权威**：哨兵证明 app 视图就是那张表；扫描锚定在自旋签名上，**除我们自己的哨兵外整张表为空** |

（CPU 侧读这块 ROM RAM 是安全的：`trapDispatch` 在每次 input 25 里都读表，11776 次采样无 fault。
"ROM 读合法"说的是**总线访问**，与调试口读到的内容是否代表运行期状态是两件事。）

**时机也做成显式条件**：早先用 `irq_count>=1000` 触发（事后核对 pb116–pb135，自旋签名在 #256–#512 就出现，
所以那次确实在自旋内）；现在改成锚定 `mepc==0x2f009206`（自旋签名）后第一次命中即扫（sample 631），
结果一致——除哨兵外全空。顺带得到 **`mtvt = 0`**：CLIC 逐输入向量表基址是 0（当前 `mtvec` 是直接模式，
`mtvt` 不参与投递）。

**表的长度是 32 项**：扫到 64 时，entry 34..48 读到的是别的 ROM 数据（`fn=0x780078`、`0x20303a`
这类明显的代码字），不是 handler——所以"整张表"指的就是 entry 0..31（外部号 0..31）。

**为什么哨兵自检是必需的**：`0x2f07f070` **在应用链接窗口之外**——`linker/s31.ld:38-40` 记
应用可用 SRAM 只到 `0x2F07AFC0`，其上的 `0x2F07AFC0–0x2F07FFFF` 是二级 bootloader 的
`iram_loader_seg`。所以"app 读到全 0"本来有两种解释：表真的空，或该地址在 app 上下文另有占用。
哨兵往返（写 `intr_handler_set(30,..)` -> 同一地址读回 `0x4004c85a/0x5a5a5a5a`）证明**在这个 app 里
该地址就是那张表**：RAM 就是 RAM，bootloader 的 loader 段在 app 运行期已不再使用。

**结论**：blob **在 ROM 的表里也没装输入 25 的 handler**——运行期除我们自装的哨兵外整张表是空的。这与"blob 从未调用
`_set_isr`"一致，并且排除了"handler 装在 ROM 表里、只是我们调不到"这一解释——**根本没有 handler 可调**。

于是"把输入 25 转发给某张表"这条路彻底关闭：应用侧表空、ROM 表空、`rom_mtvec` 是 CLIC 向量表基址。
blob 在 `0x400490f4` 里做的 `mie |= 1<<25` / `int_ena |= 1<<1` / 矩阵路由，是**使能了一个没人处理的
中断**（在 IDF 里该 handler 由 app 侧 `esp_intr_alloc` 装，而 blob 自己没装）。

已把 `trapDispatch` 改成三级查找（应用侧表 -> **ROM 表** -> 原来的 ack 逻辑），板侧基线不变
（表空，行为等价），但机制完备：将来 blob 一旦装了 handler，无论装在哪张表都能被调用。

**方法论教训**：用调试口读 RAM 得到的"运行期状态"必须先证明芯片处于运行态（连接会复位）。
本次是 app 侧扫描推翻了调试口读数——**运行期状态只能在 app 里读**。

### 下标约定：表按**外部中断号**索引（= CLIC ID − 16）

IDF 的权威口径：`components/riscv/interrupt.c` 里 `intr_get_item(mcause - RV_EXTERNAL_INT_OFFSET)`，
`RV_EXTERNAL_INT_OFFSET = 16`（`csr_clic.h:29`）；ROM 分发器 `0x2f80193e` 的 `addi a0,a0,-16` 是同一约定。
`_set_isr(n, ...)` 里的 `n` 也是外部号。

所以 **CLIC 输入 25 对应表项 9**。先前 `trapDispatch` 用 `cause & 0x3F`（=25）去查表，装了 handler
也永远查不到——已改为 `input - 16`（`input >= 16` 时）。同理 `_set_intr` 写 CLIC ctrl 时寄存器索引是
`num + 16`（IDF `esp_rom_clic.c:21`：`CLIC_INT_CTRL_REG(rv_int_num + CLIC_EXT_INTR_NUM_OFFSET)`），
并且要设触发类型 `trig [18:17]`（0=电平、1=上升沿）——两处都已修正。

板侧复核（pb184）：自旋锚定扫描与哨兵往返结果不变（除哨兵外全空），基线不变。

### `g_timer_func` 已装并被真实调用 4096+ 次，自旋不变 ⇒ tick handler 不是卡点

`esp32s31.rom.pp.ld:377` 的 `g_timer_func = 0x2f07feb8` 在自旋期间读出来是 **`0x4003012e`**
（blob 代码段），即 ROM WiFi 的定时器回调指针。把它按外部号 9（= CLIC 输入 25）装进 ROM 表：

```text
mtvt=0x0 mtvt2=0x0 g_timer_func=0x4003012e
installed g_timer_func at ext#9 (input 25)
romhandler calls=1024 fn=0x4003012e
romhandler calls=4096 fn=0x4003012e
irq-sample #11776 input=25 mepc=0x2f009206 mac=0x00fff000
```

**handler 确实被我们的 trap 调用了 4096+ 次，`MAC_ST[15:13]` 仍是 `1`，自旋 PC 不变。**

⇒ 结论：**"blob 的 tick handler 从未运行"这个假设已被直接证伪**——它现在会运行，而卡点依旧。
tick 不是阻塞项；`esp_wifi_start` 等的是别的东西（MAC 引擎真正起来 / 校准完成 / 某个我们没喂的输入）。

顺带：**CSR 0x308（mtvt2）在本核不存在**，读它会 `illegal instruction`（`mtval=0x308029f3` 正是
`csrr x19,0x308` 的编码）。所以"选择性向量"开关不存在，`mtvt=0` 也就无所谓。

### 自旋的真实结构：写命令字 `REG[0x20104CAC] |= 0xff1000`，然后等硬件清 bits[15:13]

反汇编 `0x2f009190`（唯一调用者 `0x2f005cc8`）：

```asm
2f009190: lw  a5,-720(a4)      # g_mac_deinit_count (0x2f07fd30)++
2f0091a0: sw  a5,-720(a4)
2f0091ac: lw  a5,[0x20104cac] ; srli 14 ; andi 1 ; sb -> 0x2f07fd2d   # 存 bit14
2f0091b8: lw  a5,[0x20104cac] ; srli 13 ; andi 1 ; sb -> 0x2f07fd2c   # 存 bit13
2f0091c6: jal 0x2f00254e        # 谓词
2f0091ca: beqz a0, 0x2f0091dc   # 谓词为 0 -> 跳过第一段等待
2f0091d2: lw a5,[0x20104cac] ; and 0xe000 ; bnez -> 0x2f0091d2        # 等待 A：bits[15:13] 清零
2f0091dc: lw a4,[0x20104cac]
2f0091ec: or a4,a4,0xff1000 ; sw a4,[0x20104cac]                     # **写命令字**（置 bit12 + bits16..23）
2f0091f0: jal 0x2f80003c                                             # ROM 延时
2f0091fe: lw a5,[0x20104cac] ; and 0xe000 ; bnez -> 0x2f0091fe        # 等待 B：bits[15:13] 清零
```

**我们的采样 PC（`0x2f009204` / `0x2f009206`）落在"等待 B"**，而 `mac=0x00fff000` = 写位
`{12,16..23}` ∪ 复位值 `{13,14,15}` ⇒ **busy 位不是这条命令置的，它们是复位值 `0xE000`，从没被清过**。

判读：这不是"任务不让出"，而是**硬件握手没完成**——blob 发出了一条经 `0x20104CAC` 的命令
（写位不含 busy 位），MAC 侧既没执行、也没把复位以来一直为 1 的 busy 位清掉。所以问题从"调度/中断"转成"**这条命令依赖哪个时钟/复位没给**"。

下一步（未做）：把 `0x20104CAC` 归属的外设块查清，并在 IDF 同一相位读同一寄存器对照；
若 IDF 那边同样写入后立刻清零，则差异就在该块的时钟/复位（我们可能少给了某一个）。

### 复位/时钟现场实测：`rst_wifimac` 是 0、ICG/CLK_CONF1 都正常 —— 不是"MAC 在复位里"

`0x20104CAC` 的归属查清了：`MODEM_BASE(0x20100000) + 0x4CAC` = **`DR_REG_WIFI_MAC_BASE(0x20104000) + 0xCAC`**
（IDF `soc/esp32s31/include/modem/reg_base.h`）。也就是说 blob 写的是 **WiFi MAC 自己的寄存器**。

自旋期间读现场（pb192）：

```text
rst_conf=0x00000000 (bit1 rst_wifimac=0) clk_conf1=0x0038e7ff icg=0x64646400
```

- `modem_rst_conf`(+0x10) **bit9(`rst_wifimac`)/bit8(`rst_wifibb`) 都是 0** ⇒ MAC **不在复位里**（"MAC 被 hold 在 reset"这个假设被否掉）；
- `CLK_CONF1 = 0x0038e7ff`：bits 0..10 全开（wifibb_22m/40m/44m/80m/40x/80x/40x1/80x1/160x1/wifimac/wifi_apb）、
  bits 13..15（fe_80m/fe_160m/fe_apb）、bits 19..21（fe_pwdet_adc/fe_adc/fe_dac）—— 是"全开"的形态；
- `ICG = 0x64646400` 与 IDF 工作值一致。

**所以时钟与复位都不是解释。** 剩下的方向是：MAC+0xCAC 这条命令本身需要的前置（例如 MAC 的 AHB 时钟域
或某条 enable 序列）没满足，或者 blob 期望某处状态由我们喂入——需要拿 IDF 在同一条命令前后的
`MAC+0xCAC` 读数做逐位对照，才能定位到具体缺哪一位。

### 决定性现场：PP 任务**已创建**，MAC 报 `rxing=1 txing=1` 且永不排空

自旋点一次性读四个簿记全局（`esp32s31.rom.pp.ld` 与 ROM 数据窗）：

```text
rst_conf=0x00000000 (bit9 rst_wifimac=0 bit8 rst_wifibb=0) clk_conf1=0x0038e7ff icg=0x64646400
pp_task_hdl=0x2f01ce60 deinit_count=1 rxing=1 txing=1
```

| 读数 | 含义 |
| --- | --- |
| `pp_task_hdl = 0x2f01ce60` | **PP 任务已创建**（非空）——"PP 任务没人跑"这个候选被否掉 |
| `deinit_count = 1` | 是**第一次**进这个 deinit 等待 |
| `rxing = 1` / `txing = 1` | 入口时 MAC_ST 的 **bit14（RX busy）与 bit13（TX busy）都是 1** |
| `MAC_ST = 0x00fff000`（全程） | 命令字已写、MAC 自报 **TX/RX 都在忙**，且**永不排空** |

所以自旋的语义是清楚的：**`g_mac_deinit_*` 这条 deinit 路径在等 MAC 把 TX/RX 排空，而 MAC 自报
TX/RX 一直忙**。也就是说卡点不在"谁去清状态位"，而在**MAC 的 TX/RX 状态机本身没在前进**——
它以为自己在收/发，但没有任何东西推进它。

下一步方向：查 MAC 的 TX/RX 使能是从哪来的（blob 在 deinit 之前应先 stop TX/RX；若那一步被跳过，
这两位就会一直是 1），以及 MAC 的 DMA/AHB 时钟是否真的在该域上（`clk_conf1` 全开只说明门控开了）。

### 问题的真正位置在 **init**，不在 start：`MAC_ST` 从来没到过 0

把两条时间线并排：

| 阶段 | IDF | 我们 |
| --- | --- | --- |
| init 前 | `0x0000E000` | `0x0000E000`（探针 `irq-sample #0` 实测） |
| **init 后** | **`0x00000000`** | **仍是 `0x0000E000`**（没有变过 0） |
| start 中 | `0` | 写命令字后 `0x00FFF000`，deinit 等它清 → 永远等 |

也就是说：**IDF 的 `esp_wifi_init_internal` 会把 MAC 状态机推到 0（引擎就绪）；我们的没有。**
于是 `esp_wifi_start` 走到 `mac_deinit()`（`0x2f005cc4`，唯一的活就是 `jal 0x2f009190`）时，
等的是一个**从来没启动过**的 MAC 的 TX/RX 排空 —— 自旋由此而来，与调度、中断、tick handler 都无关。

**下一步的唯一目标：找出 IDF 在 init 期间把 `MAC+0xCAC` 的 bits[15:13] 清到 0 的那一步。**
候选入口：`ic_mac_init`（`0x2f800d9c` -> thunk `0x2f817294`）与 `hal_mac_*` 系列；
做法是在我们这边给这些 ROM 函数加 note，看 init 期间**哪些被调用了、哪些没被调用**，
再与 IDF 的同相位日志对照。

### `MAC+0xCAC` 的写者图谱（blob 自己代码里的全部访问点）

| 地址 | 操作 | 含义 |
| --- | --- | --- |
| `0x4003458c` | `lw; and 0xfff1ffff; sw` | **清 bits 17..19**（0x000E0000）——"停/关" |
| `0x40034d90` | `lw; or 0x000E0000; sw` | **置 bits 17..19**——"启/开" |
| `0x40035664` / `0x40035730` | 同上 `or 0x000E0000` | 同上 |
| `0x2f0091ec`（deinit） | `lw; or 0xff1000; sw` | 置 **bit12 + bits16..23**（含使能位 17..19），**不含 13..15**；随后**等 bits 15:13 清零** |

⇒ 寄存器语义可读成：**bits 17..19 = 使能对**（置=开、清=关），**bits 15:13 = 忙/ack**（bit14 RX、bit13 TX）。
deinit 先"置使能位 + 写命令"，再等忙位清零——前提是 MAC 真的被使能过并且状态机在跑。

这与"IDF 的 init 后 `MAC_ST=0`、我们的从没到过 0"一致：**我们这边没有走到那条把使能位配上、
让状态机转起来的路**。下一步就是给 `ic_mac_init`(0x2f800d9c -> 0x2f817294) 与 `hal_mac_*` 加 note，
看 init 期间哪些 ROM 调用发生了、哪些没有。

### `rst_wifimac` 脉冲实验：**不是机制**（一次上板否掉）

bits 15:13 在 blob 里**没有软件清除路径**（写者图谱里只有置位/清 17..19 的站点），所以 IDF init 后
`MAC_ST 0xE000 -> 0` 只能是**硬件副作用**——复位脉冲是唯一候选。直接做实验：

```text
pre-pulse  MAC_ST=0x0000e000 rst=0x00000000
post-pulse MAC_ST=0x0000e000 rst=0x00000000 en_bits=0
```

脉冲（`0x20109C10` bit9 置 1 -> 延时 -> 清 0）**没有改变 MAC_ST**，也没改变使能位。

⇒ **复位脉冲不是机制，排除。** 同时 `en_bits=0` 再次确认：**bits 17..19（使能对）在整个 init 期间
从未被置起**——blob 里那三个 `or 0x000E0000` 站点（`0x40034d90` / `0x40035664` / `0x40035730`）
**在我们的 init 路径上没有执行**。

### 于是方向明确：我们的 init 走了错误分支/提前返回

`esp_wifi_init_internal` 返回 0，但内部**没走到 MAC 使能那一步**。

**更正**：此前草稿把这件事与"`set_country` 返回 258"当成同一条线，那是**误归因**——258 是
`esp_wifi_set_country` 的返回值（`ESP_ERR_INVALID_ARG`），与 init 内部的短路无关（ADR 早前已记
"`set_country` 的 258 另案，但不影响自旋"）。这里只保留实测事实：**使能位从未置起**。

下一步：找出 init 里那条**提前返回**的分支。做法是把 init 期间**走到过哪些站点**记下来（我们能在
osi 边界打点，ROM/blob 内部只能靠"某全局是否被写"间接观察），与 IDF 同相位对照；重点看
`0x40034d90`/`0x40035664`/`0x40035730` 这三个使能站点的**前置条件**分别读哪个全局/寄存器。

### 找到了使能路径的门：blob 全局结构 `0x2f013d30` 的 **+14**

MAC 使能函数在 `0x40034d1a`，开头就是门控：

```asm
40034d1e: lui s0,0x2f014 ; addi a5,s0,-720   # s0 = 0x2f013d30（blob 全局结构）
40034d2c: lbu a4,289(a5)                      # +289
40034d36: bltu a5,a4, 0x40034d40              # 1 < a4 -> 跳到 +15 检查
40034d3a: lbu a5,14(s0) ; beqz -> 0x40034d46  # **+14 == 0 -> 直接返回**
40034d40: lbu a5,15(s0) ; bnez -> 0x40034d56  # +15 == 0 -> 返回
...
40034d90: or 0x000E0000                       # 置使能位（只有走到这里才会执行）
```

板侧实测（自旋点读该结构）：

```text
blob_g b1=0 b14=0 b15=1 b16=0 b27=0 b288=0 b289=1
```

**判读（已用实验定案）：使能函数 `0x40034d1a` 在我们的流程里一次都没被调用。**

证据链：
- 成功路径的标志全 0：`b16=0`（`0x40034d0e` 才写）、`b27=0`（`0x40034d7e`）、`b288=0`（`0x40034d84`）；
- **提前返回路径也没走过**：那条路在 `0x40034d46` 会 `sb zero,15(s0)` 清 `b15`，而实测 **`b15=1`**；
- 把 `b14` 强制置 1 提到 **`esp_wifi_init_internal` 之前**再跑：
  `pre-init ctx b14=0 b15=0 b288=0` → `post-init ctx b14=1 b15=0 b16=0 b27=0 b288=0 b289=0 mac=0x0000e000`
  —— 三个成功标志仍然全 0，`MAC_ST` 仍是复位值。

⇒ **`b14=0` 是"没人调用"的结果，不是原因。** 方向必须上移到**谁应该调用它**。

### 调用链已定位到上一层闸门：调用者自己被 `ctx[15]` 挡住

`0x40034d1a` 在全镜像里**只有一个调用点**（`jal 0x40034d1a` @ `0x40035ec4`），调用者函数入口 `0x40035ea8`：

```asm
40035eac: lui s0,0x2f014 ; addi s0,s0,-720   # s0 = 0x2f013d30
40035eb4: lbu a5,15(s0)                       # ctx[15]
40035ebe: beqz a5, 0x40035f10                 # **ctx[15]==0 -> 跳过，不调使能**
40035ec4: jal 0x40034d1a                       # 只有 ctx[15]!=0 才调
```

而实测：**init 之前 `b15=0`**（所以这次调用被跳过），**到自旋时 `b15=1`**（门开了，但没人再调一次）。

⇒ 缺口是：**`ctx[15]` 变 1 之后，没有人再次调用 `0x40035ea8`**。下一步就是找 `0x40035ea8` 的两个调用点
（`0x4002938c`、`0x40044762`）分别属于哪条路径、它们的前置是什么。

### `b14` 没有直接的 `sb` 写者（静态边界）

在整份反汇编里搜 `sb …,14(base)` 与 `sw …,12(base)`（覆盖字节 12..15 的写法）：
**blob 的 `0x4003xxxx` 与 `0x2f0xxxxx` 两段里都没有命中**。也就是说 `b14` 不是某条指令直接 `sb` 出来的，
它要么来自一次**整块拷贝**（结构初始化/`memcpy`），要么由 ROM 侧写。

这给下一步划了界：**不要再找"哪条 `sb` 写 b14"**，而要找**这个结构（`0x2f013d30`）在 init 里是怎么被填的**
（谁拷贝/初始化它），以及 IDF 那边同一结构在 init 后的 `+14` 是不是 1。

### `0x40035ea8` 的两个调用点

| 调用点 | 上下文 |
| --- | --- |
| `0x4002938c` | 一条 `jalr` 回调之后的收尾分支（`li a1,0` 后直接 `jal 0x40035ea8`）——像是"异步完成回调里再跑一次状态推进" |
| `0x40044762` | **状态迁移函数**：`jal 0x40034c88` 之后比较 `lbu a4,0(s4)` 与 `lbu a5,8(s0)`，**相等就跳过**；不等才 `lui a0,0x40044; addi a0,a0,938`（= `0x400443aa`，像是状态名/格式串）→ `jal 0x40035ea8(a0, a1)` |

所以使能能否发生，取决于**状态机有没有走到那次迁移**。我们卡在 `esp_wifi_start` 内部的 deinit 自旋里，
状态机自然不会再推进——**这解释了为什么自旋时 `b15` 已经是 1、使能却仍然没发生**。

**当前的因果链（全部实测）**：
1. `esp_wifi_init_internal` 返回 0，但 `MAC_ST` 停在复位值 `0xE000`（IDF 的 init 后是 0）；
2. MAC 使能函数 `0x40034d1a` 从未被调用（三个成功标志全 0 + 返回路径的 `b15` 未被清 + init 前置 b14 无效）；
3. 它唯一的调用者 `0x40035ea8` 被 `ctx[15]` 挡住，而 init 时 `b15=0`；
4. `b15` 在 start 阶段变 1，但此时流程已进入 deinit 自旋，**没有人再调用 `0x40035ea8`**。

⇒ 要解开自旋，必须在**进入 deinit 之前**让状态机走到那次迁移（即让 init 阶段就把 `b15` 置上、
并触发一次 `0x40035ea8`），或者查明 IDF 里是哪一步在 init 阶段完成了这件事。

### 更上游的分歧点：blob 的回调槽 `0x2f011aa8` 从未被注册

`0x40029366` 那段把机制露出来了：

```asm
40029366: lui  a5,0x2f012 ; addi a5,a5,-1484   # a5 = 0x2f011a34（blob 自己的静态数据）
4002936e: lw   a5,116(a5)                      # a5 = *(u32*)0x2f011aa8   ← 回调槽
40029378: beqz a5, 0x4002938a                  # 为 0 -> 走兜底
4002937e: jalr s0                              # 有回调 -> 回调(0,0)
4002938c: jal  0x40035ea8                      # 兜底 -> 被 ctx[15] 挡住
```

板侧实测（init 前与自旋时各读一次）：

```text
wifi-init-probe: pre-init ctx b14=0 b15=0 b288=0 cb_slot=0x0
blob cb_slot[0x2f011aa8]=0x0
```

**但要注意：这很可能不是分歧点。** 理由：镜像内对 `0x2f011aa8` **只有读、没有任何写**，而我们这边
init 前它就是 0 ⇒ IDF 侧起点也是 0；若有 ROM 侧写者，它在我们这边**同样会跑**。所以 `cb_slot=0`
大概率是**两边的正常状态**，走兜底是设计路径，不是异常。它只解释"为什么走兜底"，不解释"为什么卡"。

**段归属已核对（重要）**：`objdump -h` 的布局是

```text
.iram_blobs  VMA=0x2f0000b0 SIZE=0x0000f5b0   -> 到 0x2f00f660
.data        VMA=0x2f00f660 SIZE=0x00002270   -> 到 0x2f0118d0
.bss         VMA=0x2f0118d0 SIZE=0x0000bca0   -> 到 0x2f01d570
```

`0x2f011a34` / `0x2f011aa8` / `0x2f013d30` **都落在 `.bss`**——这是因为我们把 blob 的 `.o` 链进了
自己的镜像，它们的 `.bss` 被合并进我们的 `.bss`。**不是段重叠/别名问题**，地址语义是可信的。

**下一步仍然是 `ctx[15]`**：它在我们的 start 阶段翻到 1，但后续那次 `0x40035ea8` 调用没有发生。

### 命名尝试：链接后的 ELF 没有符号表

`riscv32-esp-elf-nm zig-out/bin/app.elf` → **0 个符号**（链接时 strip 了）。所以 `0x2f013d30` /
`0x2f011aa8` 这两个 blob 静态地址**没法从镜像里直接拿到名字**；要命名只能按对象逐个分析
（`/tmp/blobobjs/*.o` 的 `.data`/`.bss` 符号 + 段内偏移 + 数据段基址），成本不低。

按价值排序，下一轮应优先做**功能判定**而不是命名：

1. **在 IDF 侧读 `0x2f011aa8`**（blob 静态段，地址两侧一致）。非 0 ⇒ 直接用那个指针去
   `esp32s31.rom.*.ld` / blob 符号查名字，反推注册路径；仍为 0 ⇒ 这条回调在 IDF 里也是空的，
   说明分歧点不在这里，要回到更早的 init 分支。
2. 若 IDF 非 0：在 IDF 的 `esp_adapter.c` / blob 导出符号里找"谁写这个槽"，
   对应到我们适配层缺的那个导出符号或 osi 钩子。

### 段归属与"基址错位"假设：**重定位存在 ⇒ 无错位**

有人会担心：blob 代码里那些硬编码绝对地址（`lui 0x2f014; addi -720`）若打在**我们自己的 .bss** 上，
就说明 `.iram_blobs` 的加载基址偏了，读到的"blob 自己的 ctx"其实是 app 的内存残渣。

**这个假设已被证伪**：`/tmp/blobobjs/*.o` 里带**重定位记录**——

```text
esf_buf.o  RELOCATION RECORDS FOR [.text...]:  00000000 R_RISCV_HI20 .LANCHOR0
hal_ampdu.o:                                   00000102 R_RISCV_HI20 .LANCHOR0
hal_coex.o:                                    00000004 R_RISCV_HI20 g_osi_funcs_p
```

也就是说 blob 的静态数据引用是**符号 + 重定位**，由**我们的链接器**解析到最终地址；它落在 `.bss`
（0x2f0118d0..0x2f01d570）是**合并后的正确位置**，不是"打到别人内存上"。`nm` 看不到名字是因为
这些是 `.LANCHOR0` 一类的**局部符号**，链接时被丢弃。

⇒ 段布局不是问题；`0x2f013d30` / `0x2f011aa8` 的读数可信，`ctx[15]` 这条线成立。

### 支持性观察：自旋期间 CPU **从未**进入 blob 任务

采样器在自旋期间的上万次样本里，`mepc` 始终是 `0x2f009202`/`0x2f009204`/`0x2f009206`（deinit 等待循环），
**没有一次**落在 blob 任务的代码上。也就是说 `esp_wifi_start` 把主上下文钉在这条循环里之后，
**blob 任务一次都没被调度**（我们的调度器是合作式的，而这条循环不调用任何 osi 钩子、不会让出）。

这给出一个与"init 没使能 MAC"并列的解释，两者并不互斥：

| 解释 | 预测 |
| --- | --- |
| **A. init 没使能 MAC**（已实测 `MAC_ST` 停在 `0xE000`） | IDF 的 init 后 `MAC_ST=0`，我们的没有 ⇒ 硬件不会自己排空 |
| **B. 合作式调度饿死 blob 任务** | 即使 MAC 使能了，状态机也需要 blob 任务推进；我们这条循环不让出 ⇒ 死锁 |

A 有直接证据；B 是结构性风险（IDF 用 FreeRTOS 抢占，不存在这个问题）。
**先把 A 解决**（让 init 走到 MAC 使能），再验证 B 是否仍然存在。

### `ctx[15]` 的时间线：**init 期间就翻到 1 了**，但使能仍未发生

把 `ctx[15]` 与使能位加进采样行（每 256 个样本一条）后：

| 样本 | `mepc` | `mac` | `ctx15` | `en`(bits17..19) |
| --- | --- | --- | --- | --- |
| `#0`（早期 init） | `0x4004a9a2` | `0x0000e000` | 0 | 0 |
| `#63` | `0x2f83efd2` | `0x0000e000` | 0 | 0 |
| **`#512`** | `0x2f83efda` | `0x0000e000` | **1** | 0 |
| `#11776`（自旋） | `0x2f009206` | `0x00fff000` | 1 | 7 |

两条要点：

1. **`ctx15` 在 init 期间（~#512）就变成 1** —— 所以"init 时 b15=0 导致调用被跳过"只对**更早的**那次调用成立；
   b15 变 1 之后，使能函数**依然没有被调用**（`b288` 在自旋时仍是 0）。
2. **自旋时的 `en=7` 不能当作"使能发生过"的证据**：deinit 的命令字 `or 0xff1000` 本身就覆盖 bits 16..23
   （含 17..19），所以它区分不了"使能函数置的"和"命令字置的"。

⇒ 现在的缺口更精确：**b15 已经是 1，但没有任何代码再调用 `0x40035ea8`**。下一步要查的是
"谁应该在 b15=1 之后调它"——它的两个调用点（`0x4002938c` 异步回调收尾、`0x40044762` 状态迁移）
各自的前置条件是什么。

### `0x40035ea8` 的完整语义（返回码）

```asm
40035eb4: lbu a5,15(s0) ; beqz a5, 0x40035f10   # ctx[15]==0 -> li a0,2 ; 返回 2
40035ec4: jal 0x40034d1a                         # **MAC 使能**
40035ec8: lbu a5,14(s0) ; beqz -> 0x40035ee8     # ctx[14]==0 -> 返回 0
40035ed0: lbu a5,22(s0) ; beqz -> 0x40035ef4     # ctx[22]==0 -> 另一分支
40035ee6: li a0,1                                # 成功 -> 返回 1
```

| 返回 | 条件 |
| --- | --- |
| **2** | `ctx[15]==0`（未就绪），**根本不会调使能** |
| 0 | `ctx[14]==0` |
| 1 | 走完（使能已执行） |

**判定"在 `ctx[15]=1` 之后没被调用过"的硬证据**（不是靠 `b288`）：

使能函数 `0x40034d1a` 在 `ctx[14]==0` 时会走 `0x40034d46: sb zero,15(s0)` —— **把 `ctx[15]` 清零**。
实测自旋时 `ctx[15]=1` 且 `ctx[14]=0` ⇒ **若 wrapper 在 `ctx[15]` 变 1 之后被调用过，`ctx[15]` 必然已被清成 0**。
所以：**`ctx[15]` 变 1 之后，wrapper 一次都没被调用**（`b288` 那条推断是冗余的，因为 b14=0 时本来也到不了 `sb s1,288`）。

**判决实验（已做）**：在 `esp_wifi_init_internal` **之前**把 `ctx[15]` 置 1：

```text
pre-init  ctx b14=0 b15=0 b288=0 cb_slot=0x0
post-init ctx b14=0 b15=1 b16=0 b27=0 b288=0 b289=0 mac=0x0000e000
```

`b16`/`b27`/`b288` 仍全 0、`MAC_ST` 仍是复位值 ⇒ **即使把门打开，init 期间也没有任何代码调用 wrapper**。

⇒ 缺口最终锁定为：**`0x40035ea8` 在我们整个流程里根本没有调用者被执行**。
它的两个调用点（`0x4002938c` = 异步回调收尾、`0x40044762` = 状态迁移）分别由什么触发，
就是下一步要查的东西——而"触发源是 blob 任务/状态机，而它在我们这儿没被调度"是目前最自洽的解释。

### 泵任务实验：**8 轮全无变化** —— 任务阻塞在等一条永远不来的消息

在 `esp_wifi_start` 之前对 blob 任务做 8 轮"跑到阻塞为止"（`sched.swapContext(&main_ctx, &task_ctx)`）：

```text
pump round 0 before: b14=0 b15=1 b16=0 b27=0 b288=0 mac=0x0000e000
pump round 0 after:  b14=0 b15=1 b16=0 b27=0 b288=0 mac=0x0000e000
...（8 轮全部一模一样）
```

**没有任何推进。** 说明任务并不是"没被调度"，而是**调度了也没事可做**——它阻塞在 `queue_recv` 上，
而**那条本该唤醒它的消息从来没有被投递**。

**限定**：这 8 轮都在 `esp_wifi_start` **之前**，只证明"**那个时刻**任务无事可做"；
**自旋期间**（主上下文被钉在 deinit 循环里）的并发性**尚未验证**，所以"合作式调度饿死任务"这条
**不能算已否**，只是尚未被证实。
下一步该查的是"谁应该 post 那条消息"——候选是某个 osi 钩子（`_event_post`/`_queue_send`）
或某个本应被调用的 blob 内部函数。

### `ppTask` 不能直接调：它是任务体（死循环）

`ppTask`（`esp32s31.esp32s31.rom.pp.ld:193` → `0x2f800fc0`）是 ROM 的 PP worker。从 trap 里调一次：

```text
ppTask: calling once from trap (mepc=0x2f009206)
（"ppTask: returned" 永不打印；采样在 #512 后停止）
```

⇒ **它是任务入口（不返回）**，不能像普通函数那样调用。

**给它自己的栈后能正常让出，但 16 轮泵也不推进**：

```text
ppTask pump 0:  b14=0 b15=1 b16=1 b288=0 mac=0x0000e000
ppTask pump 4:  b14=0 b15=1 b16=1 b288=0 mac=0x0000e000
ppTask pump 8:  b14=0 b15=1 b16=1 b288=0 mac=0x0000e000
ppTask pump 12: b14=0 b15=1 b16=1 b288=0 mac=0x0000e000
```

（`sched.initContext(&pp_ctx, &pp_stack, ppTask, null)` + `swapContext` 能进入并正常让出，
说明"给栈 + 切换"这条路是通的；但**状态机不推进**——`b288` 仍为 0、`MAC_ST` 不变。）

已回滚，基线恢复（`calling esp_wifi_start` 到达、无 panic、自旋 `0x2f009206`）。

### 队列计数：泵期间 `queue_recv` 调用数不变 —— 但读数要正确解读

给 `calls` 加了 `queue_recv`/`queue_send` 计数（`shellQueueRecv`/`shellQueueSend` 入口自增）后：

```text
pump round 0 before: ... recv=5 send=4 delay=1
pump round 0 after:  ... recv=5 send=4 delay=1
...（8 轮全部 recv=5 send=4 delay=1）
```

**注意解读**：计数是**每次调用**自增，而阻塞等待的循环在 `q.recv(...)` **内部**（`shellQueueRecv` 只进一次），
所以"计数不变"**不能**推出"任务没运行"。结合"每轮泵都会返回"这一事实，更合理的读法是：
**任务每轮都在 `q.recv` 的阻塞循环里转到 `idle_spin_limit`(64) 次上限、没拿到消息、然后让出返回**
⇒ **仍然指向"没有人投递那条消息"**，而不是"任务没被调度"。

### 任务创建这条缝：只有 **1 个**任务，且 blob **要求**它成功

| 观察 | 结果 |
| --- | --- |
| `tasks recorded=1` | blob 只通过 `_task_create` 建了**一个**任务（entry `0x2f00d70a`），探针已经在跑它 |
| 让 `_task_create` 返回 **0(pdFAIL)** | `esp_wifi_init_internal` **rc=257**（`ESP_ERR_NO_MEM`） |

⇒ 两个结论：
1. **没有"被漏掉的第二个任务"**——只有那一个，我们已经跑它了；
2. blob **要求建任务成功**，没有"失败则就地同步执行"的回退路径，所以"让 `_task_create` 失败"
   这条捷径不通（已回滚，基线恢复 `rc=0`）。

### 收束：三个可调度实体都泵过了，都不推进

| 实体 | 泵法 | 结果 |
| --- | --- | --- |
| blob 的 Wi-Fi 任务（entry `0x2f00d70a`） | 8 轮 `swapContext` | `b288` 仍 0、`MAC_ST` 不变 |
| ROM 的 PP worker（`ppTask` 0x2f800fc0） | 自己的栈 + 16 轮 `swapContext` | 同上 |
| ROM 的定时回调（`g_timer_func` 0x4003012e） | 装到 ROM 表 ext#9，被 trap 调用 **4096+ 次** | 同上 |

再加上此前否掉的：复位、复位脉冲、时钟、`ctx[15]`/`b14` 门控、段错位、`cb_slot`、任务创建失败回退。

**当前最可能的结论**：卡点**不在软件可达面**——它要么需要真实 PHY/RF 完成（我们的裸机环境没有），
要么需要某个我们还没识别出的硬件事件。这与路线图 R3.2「需要真实 AP / 真 RF 环境」的前置一致。

**如果继续，唯一有信息量的方向**是把 IDF 侧的 `MAC+0xCAC` 变化序列（请求 → 应答两拍）与我们这边
逐位对照，看是"应答从未产生"还是"应答产生了但没人读"。

### 软件定时器：固件里**从未接过** `serviceTimers()` —— 但 blob 也**从未 arm**

先修了一个真实缺口：`serviceTimers()` 此前**只在 host tests 里被调用**，固件里没有任何让出点推进它
⇒ blob 注册的定时器永不到期。已在 `idleHook` 里接上（正是该函数注释里写的设计）。

但接上之后实测：

```text
timers fires=0 armed=0
```

调用统计：

| 钩子 | 次数 |
| --- | --- |
| `timer_setfn` | **14** |
| `timer_disarm` | **7** |
| **`timer_arm` / `timer_arm_us`** | **0** |

⇒ blob 在 init 期间**只注册回调、随后 disarm，从未 arm 过任何定时器**（`armed=0`、`fires=0` 自洽）。

**于是做判决实验：人为上膛 + fire 全部 14 个回调**（`forceArmAll()` 把"已 `setfn` 未 armed"的项设成
立即到期、一次性；由 trap 里新增的 `serviceTimers()` 钩子走**真实路径** fire）：

```text
wifi-init-probe: forceArmAll armed=14
trace timer_fire × 14
timers fires=14 armed=0
irq-sample #11776 input=25 mepc=0x2f009206 mac=0x00fff000   ← 自旋不变
```

⇒ **定时器路径已被验证**：14 个回调全部 fire 过，状态机不推进、`MAC_ST` 不变。
（此前只能写"从未 arm ⇒ 未验证"；现在是实测否掉。）

`serviceTimers()` 在 **trap 的 input-25 分支**里接线（自旋期间没有让出点，只有 tick 在跑），保留。

## ★★★ IDF 侧对照（2026-11-17，决定性）

把 IDF 的 `examples/wifi/getting_started/station` 插桩（读 `0x20104CAC` / `0x20109C10` / `0x20109C14` /
`0x20109C0C`）后在同一块板上跑：

```text
PROBE mac_st before_init =0x0000e000  rst=0x00000000 clk1=0x00000000 icg=0x00000000
PROBE mac_st after_init  =0x00000000
PROBE mac_st before_start=0x00000000
PROBE mac_st after_start =0x00ff1000
```

| 阶段 | IDF | 我们 |
| --- | --- | --- |
| init 前 | `0x0000E000` | `0x0000E000`（一致） |
| **init 后** | **`0x00000000`** | **仍是 `0x0000E000`** ← **唯一分歧** |
| start 后 | `0x00FF1000`（**bits 15:13 = 0**，不忙） | `0x00FFF000`（bits 15:13 = 1，永远忙） |

**两条硬结论**：

1. **根因精确定位**：IDF 的 `esp_wifi_init_internal` 会把 `MAC_ST` 从 `0xE000` 清到 **0**；我们的没有。
   后续 start 里的 deinit 等待就是要等 `bits[15:13]` 清零——IDF 那边它们本来就是 0，我们这边**是复位值
   且从未被清**，所以永远等不到。
2. **命令字 `0xff1000` 不需要"应答"**：IDF 的 start 结束后 `MAC_ST` 就是 `0x00FF1000`（写位仍在、忙位为 0），
   并且 `esp_wifi_start` 返回 OK。所以"写命令字等硬件清忙位"这个模型是**我们这边的现象**，
   不是硬件语义——硬件只需要忙位在**命令之前**已经是 0。

⇒ 下一步唯一目标：**找出 IDF 的 init 里把 `MAC_ST` 从 `0xE000` 清到 0 的那一步**。
   候选是 `esp_phy_enable`/`register_chipv7_phy`（IDF 在 init 里做 PHY 初始化，我们放在 `_phy_enable`），
   以及 `ic_mac_init` 一族。做法：在 IDF 侧把 init 内部按阶段打点（或二分 `esp_phy_enable` 前后）。

### 二分尝试：单独调 `esp_phy_enable` 会把板子搞成重启循环（已回滚）

在 IDF 例程里于 `esp_wifi_init` **之前**单独调 `esp_phy_enable(1)`：

```text
PROBE after_phy_enable rc=1 mac_st=0x0000e000     ← MAC_ST 没变，且 rc=1
（随后板子进入重启循环；after_phy_disable 从未打印）
```

⇒ **单独调 `esp_phy_enable` 既不清 MAC_ST，还会崩**（它必须在 IDF 的 init 序列上下文里调，
不能脱离 `esp_wifi_init` 单独用）。已回滚，IDF 探针恢复为干净的 4 行对照读数。

**结论不变**：清 `MAC_ST` 的那一步在 `esp_wifi_init_internal` **内部**，需要别的手段二分
（例如在 IDF 的 `wifi_init.c` 里于 `esp_wifi_init_internal` 前后插桩，或对 blob 的 init 做分阶段打点）。

### 二分判定：清位发生在 **`esp_wifi_init_internal` 内部**（`esp_wifi_power_domain_on` 排除）

在 IDF 的 `components/esp_wifi/src/wifi_init.c` 里插两处读数（测完已 `git checkout` 还原）：

```text
PROBE2 before_power_domain_on  mac_st=0x0000e000
PROBE2 after_power_domain_on   mac_st=0x0000e000    ← power_domain_on **不清**
PROBE2 before_init_internal    mac_st=0x0000e000
PROBE2 after_init_internal     mac_st=0x00000000    ← **清位在这里**
```

⇒ 排除 `esp_wifi_power_domain_on()`，也排除"单独调 `esp_phy_enable` 能清位"（那一枪 rc=1 且崩）。
**清 `MAC_ST` 的那一步在 blob 的 `esp_wifi_init_internal` 内部**，而我们的调用返回 0 却没清。

⇒ 我们的 init 虽然返回成功，但**内部走到了与 IDF 不同的分支**（少做了清位那一步）。
下一步是在 blob 的 init 里定位"清 `MAC_ST`"的代码位置：`MAC+0xCAC` 的写者图谱我们已经有了
（`0x4003458c` 清 bits 17..19、`0x40034d90` 等置位、`0x2f0091ec` 写命令字），
但**没有任何一处写 0 到 bits 15:13** —— 说明那三位是**被别的寄存器/序列间接清掉的**（例如 MAC 的
软复位/时钟门控脉冲）。这与"使能函数从未被调用"是两条独立的线。

### ⚠ 方法论更正：blob 的静态地址**在两个构建里并不相同**

本来打算"两边 dump `0x2f013d30` 起 512 字节再 diff"。IDF 侧（在 `wifi_init.c` 的
`esp_wifi_init_internal` 之后插 dump）读出来：

```text
CTX 0000: 00000000 00000000 00000000 00000000
...（512 字节**全 0**，非零行数 = 0）
PROBE3 mac_st=0x00000000
```

而我们这边同一地址是 `b14=0 b15=1 b289=1` 等**非零**值。

⇒ **同一个地址在两个构建里指的不是同一个东西**：我们把自己的 blob `.o` 链进镜像，它的 `.data/.bss`
落在**我们的链接器**分配的位置；IDF 构建里 blob 的数据段布局不同 ⇒ `0x2f013d30` 在 IDF 那边是
一块**没被用到的零 RAM**。

**结论（重要）**：跨构建**不能**按地址对比 blob 的静态数据；能对比的只有**硬件寄存器**
（`MAC_ST`、`CLK_CONF1`、`ICG` 等）与 **ROM 表**（ROM 地址两边一致）。已回滚该 dump。

### IDF 侧 ROM 表读数：**entry 9 也是空的** ⇒ 表不是 tick handler 的所在

在 IDF 的 `wifi_init.c` 里于 `esp_wifi_init_internal` 之后扫 ROM 表（`0x2f07f070`，32 项）：

```text
ROMTBL[01] fn=0x00000020  ROMTBL[08] fn=0x400548c4  ROMTBL[10] fn=0x00000020
ROMTBL[17] fn=0x400548b4  ROMTBL[19] fn=0x00000020  ROMTBL[22] fn=0x2f01af18
ROMTBL[26] fn=0x400548a4  ROMTBL[28] fn=0x00000018  ROMTBL[29] fn=0x2f07afc4
ROMTBL[31] fn=0x2f07f14c
ROMTBL-scan done (entry9 fn=0x00000000 arg=0x00000000)     ← **entry 9 空**
ROMGLOB g_timer_func=0x400414e4 pp_task_hdl=0x2f07ec20 mac_st=0x00000000
```

（`0x00000020` / `0x00000018` 显然不是函数指针，说明这一段在 IDF 上下文里也混着别的数据。）

**结论**：
1. **`entry 9` 在 IDF 里同样为空** ⇒ "IDF 把 Wi-Fi tick handler 装在 ROM 表 entry 9"这个假设**被否掉**；
   ROM 表不是 tick handler 的存放处（两边都不是）。
2. `g_timer_func`（IDF `0x400414e4` vs 我们 `0x4003012e`）与 `pp_task_hdl`（IDF `0x2f07ec20` vs 我们
   `0x2f01ce60`）在两边不同，是因为**两边链接的是不同的 blob 构建**——这类 blob 内部指针不能跨构建对比
   （同上一节的方法论更正）。
3. 仍然可跨构建对比的硬事实只有：**IDF 的 init 把 `MAC_ST` 清成 0，我们的没有**。

### IDF 应用侧 handler 表插桩：只看到 `int_no=2/3`，且打印会把启动搞崩

在 IDF 的 `components/riscv/interrupt.c` 的 `intr_handler_set()` 里加一行 `printf`：

```text
APPTBL set int_no=2 fn=0x2f00034c arg=0
APPTBL set int_no=3 fn=0x2f0038ae arg=0x2f01cb38
（随后 abort() at PC 0x2f002bab，早于 esp_wifi_init）
```

两条读数：

1. **IDF 早期只注册了外部号 2 与 3 两个 handler**（CLIC 18/19），**没有 9**（= CLIC 25）。
   ⇒ 至少在 `esp_wifi_init` 之前，IDF 也没有为 input 25 装 handler。
2. **这个插桩本身会破坏启动**（`printf` 在早期中断注册路径里不安全 → `abort()`），所以拿不到完整清单。
   已回滚（`components/riscv` clean）。

**方法论**：不要在 `intr_handler_set` 这种会被早期/中断上下文调用的函数里 `printf`；
要枚举表项，应在**初始化完成后**遍历 `s_intr_handlers`（静态符号，需在同一编译单元里加一个导出函数）。

### `wifi_init_config_t` 逐字段对照：**完全一致** ⇒ 配置不是差异

在 IDF 的 `wifi_init.c` 里于 `esp_wifi_init_internal` 之前把 `wifi_init_config_t` 逐字段打出来：

```text
INITCFG srx=10 drx=32 txtype=1 stx=0 dtx=32 rxmtype=0 rxmn=5 cachetx=0 csi=0
INITCFG ampdu_rx=1 ampdu_tx=1 amsdu_tx=0 nvs=1 nano=0 rx_ba_win=6 core=0 beacon=752 sbuf=32
INITCFG feature_caps=0x1a1 sta_pm=1 espnow=7 hetb=3 dumpsig=0 priv=0 rmac=0 magic=0x1f2f3f4f
```

与我们 `init_config.zig` 的值**逐项相同**（`static_rx=10` / `dyn_rx=32` / `tx_type=1` / `static_tx=0` /
`dyn_tx=32` / `rxmgmt_type=0` / `rxmgmt_num=5` / `cache_tx=0` / `csi=0` / `ampdu_rx=1` / `ampdu_tx=1` /
`amsdu_tx=0` / `nvs=1` / `nano=0` / `rx_ba_win=6` / `task_core=0` / `beacon_max=752` / `mgmt_sbuf=32` /
`feature_caps=0x1a1` / `sta_pm=1` / `espnow=7` / `hetb=3` / `magic=0x1F2F3F4F`）。

⇒ **`wifi_init_config_t` 不是差异**（这条此前只是"看起来一致"，现在是两边实测对照）。

### 顺带：S31 上 `esp_wifi_bt_power_domain_on()` 是**空操作**

查 IDF 头文件：S31 定义了 `SOC_PM_SUPPORT_MODEM_PD`，但**没有** `SOC_PM_MODEM_PD_BY_SW`，
也没有 `SYSCON_WIFI_RST_EN_REG` / `MODEM_RESET_FIELD_WHEN_PU` ⇒ `esp_wifi_bt_power_domain_on()` 里
那整块（清 FORCE_PD → modem 复位脉冲 → 清 FORCE_ISO）**在 S31 上被编译掉了**。
这与二分结论一致（它在 IDF 里不清 `MAC_ST`）。

### NVS 轨迹：blob 读的是 108 字节的键，返回 `0x1102`（NOT_FOUND）——不是长度问题

给 `_nvs_get_blob` 加了轨迹（记录最近一次请求长度与返回码），板侧读数：

```text
nvs get_blob calls=15 last_want=108 last_rc=4354
```

`4354 = 0x1102` = **`ESP_ERR_NVS_NOT_FOUND`**（不是 `INVALID_LENGTH`）⇒ **那个键在全新 NVS 里本来就不存在**，
IDF 在同样的空白 NVS 上也会得到同一个返回码 ⇒ **不是分歧点**。

顺带修了一个真实隐患：`nvs_ram.max_blob` 原来是 **64**，而 `esp_phy_calibration_data_t` 是 **1904 字节** ——
PHY 校准数据**根本存不下**。已提到 **2048**，并把 `max_slots` 从 32 降到 8（静态占用 16 KiB，可接受）。
改完重测：自旋**不变**（`mepc=0x2f0091fe`，`mac=0x00fff000`）——所以"存不下校准数据"也不是当前卡点，
但这个容量 bug 该修（它是真实存在的隐患）。

### `clk_conf_power_st`（+0x0C）**就是**逐域 ICG 控制寄存器——IDF 的写法是逐域 OR

IDF 的 `modem_clock_hal_set_clock_domain_icg_bitmap()`（`components/hal/esp32s31/modem_clock_hal.c:23`）
逐域落到 **`hw->clk_conf_power_st.clk_*_st_map`**（`modem_syscon_ll.h:227-272`）：

| 域 | 字段（+0x0C 的 nibble） |
| --- | --- |
| MODEM_APB | bits 31:28 `clk_modem_apb_st_map` |
| MODEM_PERIPH | bits 27:24 `clk_modem_peri_st_map` |
| **WIFI** | bits 23:20 `clk_wifi_st_map` |
| BT | bits 19:16 `clk_bt_st_map` |
| **FE** | bits 15:12 `clk_fe_st_map` |
| IEEE802154 | bits 11:8 `clk_zb_st_map` |

而 IDF 的初始化（`modem_clock.c:121` `modem_clock_module_icg_map_init_all()`）是**逐域**：
`new = icg_config[domain] | 当前该域字段`，其中 `icg_config` 在 S31 端口里是
`ICG_NOGATING_ACTIVE|ICG_NOGATING_MODEM`（= `BIT(2)|BIT(1)` = **6**）或只有 `ACTIVE`（= **4**）
（`port/esp32s31/modem_clock_impl.c:370`）。**这正好解释了 IDF 的 `0x64646400`**：wifi/fe/modem_apb = 6，
其余 = 4。

⇒ 所以 `+0x0C` **是可写的逐域 ICG 控制**，不是只读状态（此前"写完读回 0"的解读要改）。
我们写 `0x64646400` 不生效，需要单独查：可能是**写的时机**（modem APB 时钟还没开）或写后被别的初始化覆盖。
这条与"MAC 域没真正上电"是同一件事的两面。

### ICG 端口的精确清单（下一步要做的）

IDF 的逐域 setter 写的就是 `clk_conf_power_st.clk_*_st_map`（`modem_syscon_ll.h:251` 等），
所以 **+0x0C 的 nibble 是控制位**。差别在**写的值**与**覆盖面**：

| 项 | IDF | 我们 |
| --- | --- | --- |
| 写什么值 | `icg_config[domain] \| 当前该域 nibble`（`ICG_NOGATING_ACTIVE`=`BIT(2)`，部分域再 `\| BIT(1)`） | 扁平 `0x64646400` 一次写 |
| MODEM_SYSCON 的 4 个域 | 逐域写 | 一次写（值等价时应当可行） |
| **MODEM_LPCON 的 4 个域**（`lp_apb`/`i2c_master`/`coex`/**`wifipwr`**） | **`modem_lpcon_ll_set_*_icg_bitmap`** | **完全没管** ← 最可能的缺口 |
| 顺序 | ICG map → CLK_CONF1 依赖位 | 只有 CLK_CONF1（+ 一次扁平写） |

**端口清单**：
1. 取 `PMU_HP_ICG_MODEM_CODE_*` 的数值（`esp_hal_pmu/include/hal/pmu_types.h`：MODEM=1、ACTIVE=2）；
2. 逐域 `new = config[domain] | 当前 nibble` 写回——**SYSCON 4 个 + LPCON 4 个（含 WIFIPWR）**；
3. 再写 CLK_CONF1 依赖位（已有）。

**判据**：写完逐域读回应与 IDF 一致（IDF 实测 `SYSCON+0x0C = 0x64646400`、`LPCON+0x18 = 0x7 → 0x1`），
然后看 **init 后 `MAC_ST` 是否变 0**、自旋是否消失。

**待查的异常**：我们写 `0x64646400` 读回 0——可能是**写时机**（modem APB 时钟未开）或值不被接受，
需要在写入点前后各读一次来定。

### S31 上两个"IDF 包装步骤"都是编译期空操作（已核对 soc_caps）

| 步骤 | 守卫宏 | S31 | 结论 |
| --- | --- | --- | --- |
| `esp_wifi_bt_power_domain_on()` 的函数体 | `SOC_PM_MODEM_PD_BY_SW` | **未定义** | 空操作 |
| `esp_clk_tree_enable_src(SOC_MOD_CLK_MODEM_APB, true)` | `SOC_CLOCK_TREE_MANAGEMENT_SUPPORTED` | **未定义**（只有 esp32c5 有） | 空操作 |

⇒ 所以 IDF 在 S31 上**不会**通过"电源域上电"或"时钟树管理"去动 modem 时钟；它能做的只有
`modem_clock_module_icg_map_init_all()`（逐域 ICG）+ `modem_clock_device_control()`（CLK_CONF1 依赖位）
+ 把控制权交给 blob。

⇒ 这也把"写 `0x64646400` 读回 0"的候选缩小到：**写时机/顺序**（ICG map 与 CLK_CONF1 的先后）
或值本身不被接受，而不是"少开了某个时钟源"。

⚠ 因此 **"复位脉冲不是机制"这条要标为待重验**：它建立在"对 `MODEM_SYSCON` 的写能生效"这个前提上，
而那个前提本身还没被验证（我们从未逐域读回确认）。

### `+0x0C` 可写性 + 逐域 ICG map 实验：**写成功、与 IDF 一致，但 `MAC_ST` 仍未清**

先纠正一个长期误读：此前"写 `0x64646400` 读回 0"其实是**写 `+0x08`（force_on）、读 `+0x0C`（power_st）**
——**两个不同的寄存器**，那个观测证明不了 `+0x0C` 写不进去。

直接自测（对 `+0x0C` 的 wifi nibble 写 6）：

```text
POWER_ST write test before=0x00000000 after=0x00600000 wifi_nibble=6   ← **可写**
```

然后照 IDF 的 `modem_clock_module_icg_map_init_all()` 写整张表（apb=6 peri=4 wifi=6 bt=4 fe=6 zb=4）：

```text
ICG map before=0x00000000 after=0x64646400        ← 与 IDF 的实测值**完全一致**
post-init ctx ... mac=0x0000e000                   ← **仍然没清**
irq-sample #11776 ... mepc=0x2f009206              ← 自旋不变
```

⇒ **ICG 位图不是缺失的那一步**（至少单独不是）：我们已经把 `+0x0C` 做成与 IDF 一模一样，init 仍不清忙位。
已回滚该写入（保持基线干净）。

### LPCON 的逐域 ICG：**写成功、与 IDF 一致，`MAC_ST` 仍未清** ⇒ ICG 侧彻底排除

先纠正一个寄存器偏移：LPCON 的 `clk_conf_power_st` 在 **`LPCON_BASE + 0x20`**
（`modem_lpcon_reg.h:198`），字段为 `wifipwr=[19:16]`、`coex=[23:20]`、`i2c_mst=[27:24]`、`lp_apb=[31:28]`；
我们一直写的 **`+0x18` 是 `MODEM_LPCON_CLK_CONF_REG`**（时钟配置），**从来不是 ICG 图**。

写 `+0x20 = 0x66660000`（四域各 6，与 IDF 的 `icg_config` 一致）：

```text
LPCON ICG +0x20 before=0x00000000 after=0x66660000 (wifipwr=6)
LPCON +0x18 = 0x00000004          ← 我们以前写的是它
post-init ctx ... mac=0x0000e000   ← **仍然没清**
irq-sample #11776 ... mepc=0x2f009206
```

⇒ 现在 **SYSCON(+0x0C = 0x64646400) 与 LPCON(+0x20 = 0x66660000) 两侧 ICG 都与 IDF 对齐**，
`MAC_ST` 依旧停在复位值 ⇒ **ICG 逐域门控不是缺失的那一步**（彻底排除）。已回滚。

### `_phy_enable` 补齐 IDF 的第三步（`set_bb_wdg`）：**无变化**

IDF 的 `esp_phy_enable_wrapper`（`esp_adapter.c:641`）是三步：

```c
esp_phy_enable(PHY_MODEM_WIFI);
phy_wifi_enable_set(1);
// disable bb idle check(max: 139ms) for temporary to avoid unexpected RXTXPANIC
set_bb_wdg(true, false, 0x18, 0xaa, false, false, false);
```

我们此前只做了第②步。已补上第③步（`set_bb_wdg` 就在我们已链接的 `libphy.a` 里）：

```text
post-init ctx ... mac=0x0000e000     ← 仍然没清
irq-sample #11776 ... mepc=0x2f009206 ← 自旋不变
```

⇒ **BB 看门狗不是缺失的那一步**（第③步单独补上无效）。改动保留（它本来就该有，与 IDF 一致）。

> 注：第①步 `esp_phy_enable(PHY_MODEM_WIFI)` 是 IDF 的 C 层函数（含 NVS 校准加载），我们走的是
> 自己的 `register_chipv7_phy` 路径——这一条的等价性仍未逐项验证。

### `_phy_enable` 还差 IDF 的第①步：`modem_clock_module_enable(PERIPH_PHY_MODULE)`

IDF 的 `esp_phy_enable()`（`phy_init.c:324`）在 `phy_get_modem_flag()==0` 时做：

```c
esp_phy_common_clock_enable();   // = wifi_bt_common_module_enable()
phy_module_enable();             // = modem_clock_module_enable(PERIPH_PHY_MODULE)
assert(phy_module_has_clock_bits(...));
if (!s_is_phy_calibrated) esp_phy_load_cal_and_init();
```

而 `wifi_bt_common_module_enable()` 在 **`SOC_MODEM_CLOCK_IS_INDEPENDENT = 1`** 的 S31 上就是
**`modem_clock_module_enable(PERIPH_PHY_MODULE)`**（`periph_ctrl.c:98-101`）。

`PERIPH_PHY_MODULE` 的时钟依赖（`port/esp32s31/modem_clock_impl.c:20`）：

```c
#define PHY_CLOCK_DEPS  ( MODEM_CLOCKS(MODEM_ADC_COMMON_FE, MODEM_PRIVATE_FE, SOC_PLL_SOURCE_CG) | I2C_ANA_MST_CLOCK_DEPS )
```

⇒ **我们的 `_phy_enable` 从来没有打开 `MODEM_ADC_COMMON_FE` / `MODEM_PRIVATE_FE` / `I2C_ANA_MST` 这几个
时钟依赖**（我们只写了 CLK_CONF1 的 fe/wifibb 位与 ICG 图）。这是 `_phy_enable` 里**唯一还没对齐的部分**。

**下一步（明确）**：把 `modem_clock_module_enable(PERIPH_PHY_MODULE)` 的语义端口过来——
按 `modem_clock_device_t` 枚举与 `modem_clock_hal.c` 的映射，把 `PHY_CLOCK_DEPS` 的四个依赖位写进
`MODEM_SYSCON.CLK_CONF1` / `I2C_ANA_MST` 相关寄存器，再验证 `MAC_ST` 是否在 init 后变 0。

### `_phy_enable` 的时钟依赖核对：**已经覆盖**

`PERIPH_PHY_MODULE` 的依赖（`PHY_CLOCK_DEPS`）逐项对照我们的 `_phy_enable`：

| 依赖 | IDF 落点 | 我们 |
| --- | --- | --- |
| `MODEM_ADC_COMMON_FE` | CLK_CONF1 `fe_apb`(15) + `fe_80m`(13) | ✅ 已写 |
| `MODEM_PRIVATE_FE` | CLK_CONF1 `fe_160m`(14) + `fe_dac`(21) + `fe_pwdet`(19) + `fe_adc`(20) | ✅ 已写 |
| `SOC_PLL_SOURCE_CG` | `HP_SYS_CLKRST.modem_conf = 0x3d` | ✅ 已写 |
| `I2C_ANA_MST` | `MODEM_LPCON.clk_conf.clk_i2c_mst_en`（+0x18 **bit2**） | ✅ 已写（我们写 0x4→0x7 含 bit0/1/2） |

⇒ **`_phy_enable` 的时钟依赖已与 IDF 对齐**，不是缺失的那一步。

至此，软件面上能对齐的都已对齐：config、ICG（SYSCON+LPCON）、CLK_CONF1/依赖位、
`phy_wifi_enable_set`、`set_bb_wdg`、`register_chipv7_phy`（FULL）、中断注册、任务、定时器。
而 **`esp_wifi_init_internal` 依旧不清 `MAC_ST`**。

⇒ 剩余空间只剩两种：① blob 内部某个**我们喂的数据**（NVS 的 108 字节键在两边都是 NOT_FOUND，
所以不是）；② **硬件面**（PHY/RF 的真实就绪状态）。这与路线图 R3.2「需要真实 AP / 真 RF」一致。

### 补上 `SOC_PLL_SOURCE_CG`（`modem_conf = 0x3d`）：**无变化**

`PHY_CLOCK_DEPS` 四项里我们**唯一没写**的是 `SOC_PLL_SOURCE_CG`
（`modem_clock_hal.c:125`：`HP_SYS_CLKRST.modem_conf.val = enable ? 0x3d : 0x25`）。已补：

```text
post-init ctx ... mac=0x0000e000      ← 仍然没清
irq-sample #11776 ... mepc=0x2f009206 ← 自旋不变
```

⇒ **PHY 时钟依赖不是缺失的那一步**（四项现已全部覆盖）。改动保留（与 IDF 一致）。

### 仍未做的一项：**通用 osi 钩子的语义对拍**

此前只对拍了"哪些钩子被调用"，**没有逐项比对语义**。已发现一处明确差异：

| 钩子 | IDF（FreeRTOS） | 我们 |
| --- | --- | --- |
| `_queue_recv(q, item, OSI_FUNCS_TIME_BLOCKING)` | `xQueueReceive(..., portMAX_DELAY)` —— **无限阻塞** | 有界自旋（`idle_spin_limit` = 64 次让出）后**返回 0** |

这类差异（超时单位：tick vs ms/us；返回码：`pdPASS`/`pdFAIL` vs 0/1；阻塞语义）**可能在 MAC 使能之前
就让 `init_internal` 走到不同分支**。下一步应对拍：`queue_*` / `semphr_*` / `mutex_*` / `malloc*` 四族。

### 队列阻塞语义：上限 64 → 20000，**无变化**；`xQueueReceive` 的返回码我们本来就是对的

把阻塞接收的自旋上限从 `idle_spin_limit`(64) 提到 `queue_block_spin_limit`(**20000**)：

```text
post-init ctx ... mac=0x0000e000      ← 仍然没清
irq-sample #11776 ... mepc=0x2f009202 ← 自旋不变
```

⇒ **"有界自旋 vs 无限阻塞"不是缺失的那一步**（至少把上限放大 300 倍无变化）。

顺带核对了一条**曾被怀疑的返回码**：FreeRTOS 的 `xQueueReceive()` 返回的是
**`pdTRUE`(1) / `pdFALSE`(0)**（`freertos/queue.h` 的文档注释原文："pdTRUE if an item was successfully
received from the queue"），**不是拷贝字节数** ⇒ 我们成功时 `return 1` **本来就是对的**，不需要改。
（这条曾被建议改成 `return self.item_size`，核对后**否决**——改了反而是引入 bug。）

真正的差异只剩：IDF 的阻塞是 `portMAX_DELAY`（永不返回 0），我们是有限上限后返回 0。要真正做到"无限阻塞"，
阻塞点必须**切回 main 上下文**（像 `init_probe` 里 `swapContext(&task_ctx, &main_ctx)` 那样），
而那又要求从 trap 的 tick 里驱动泵——两件事需要配套做。

### 队列句柄核对：`queue_send` 与 `queue_recv` **是同一个队列**（`0x2f021300`）

此前"任务在等一条永远不来的消息"这个说法需要修正。实测（pb224）：

```text
trace queue_send a0=0x2f021300 a1=0x00000006   × 5
trace queue_recv a0=0x2f021300 a1=0xffffffff   × 4~5
```

**收发用的是同一个句柄 `0x2f021300`** ⇒ 我们的队列 shim **没有句柄错配**，消息**确实投到了**任务等的那个队列。
（`a1=6` 是载荷首字，不是指针。）

⇒ 于是"blob 任务收不到消息"这条**要改**：消息**被投递过**，任务也**调用了接收**。
剩下的解释是**时序或消费后的处理**：要么消息在任务开始 `recv` 之前就已被别的路径取走/清空，
要么任务收到后走到的分支不推进状态机。

⇒ 下一步：在 `shellQueueRecv` 命中数据时打点（记录取到的载荷首字），与那 5 次 `a1=6` 对账——
**能对上 ⇒ 消息确实被消费了**，问题在消费之后的处理；**对不上 ⇒ 消息在队列里丢了**（容量/覆盖 bug）。

### ⚠ 未解异常：`queue_send` 之后紧接着的 `queue_recv` 仍读到 `count=0`

日志顺序（pb224）：

```text
307: trace queue_send a0=0x2f021300 a1=0x00000006     ← 载荷首字 = 6
313: trace queue_recv a0=0x2f021300 a1=0xffffffff
314: trace recv_probe a0=0x00000000 a1=0x00000008     ← **count=0，item_size=8**
```

**同一条队列、send 在前、recv 在后，recv 却看到队列为空。**

代码上 `shellQueueSend` 传的是 `bytes[0..q.item_size]`（长度必然等于 `item_size`），
`Queue.send` 的尺寸检查必然通过 ⇒ `count` 应当变成 1。而实测为 0。

`unwrapQueue` 的两条路径（wrapper 首字指向 inner / 直接是 inner）都已核对：`Queue` 的首字段是
`item_size`（小整数 8），不会落进 arena 判定 ⇒ 两条路径都返回同一对象。

⇒ **这个矛盾目前没有解释**。可能是：send 与 recv 之间 `count` 被别处清零；或 send 实际落到另一个
`Queue` 对象（句柄数值相同但映射不同）；或 `recv_probe` 记录的是**进入函数时**的 count 而非 send 之后的值。

⇒ 下一步（零成本）：在 `Queue.send` 成功分支里打点（`count` 前后值），与 `recv` 的 `count` 对账。

**追加（同日）**：尝试在 `Queue.send` 成功分支用 `note(17, …)` 打点，但**插错了 `hook_ids` 的插入位置**——
该数组的**下标就是 note id**，在中间插入会把它之后的所有 id 整体移位，打印出来的是错位的值
（实测打出 `a0=0x64646400`，明显不是队列指针）。已回滚。

**教训**：`hook_ids` 是**按 id 索引**的表，新增条目**必须追加到末尾**并同步 `note_id_max`，
不能在中间插入。

### ✅ 队列异常已解决：**消息确实送达并被消费**（5 发 5 收）

加了三个计数器（`send_ok` / `recv_ok` / `last_recv_count`），在自旋点一次性读出：

```text
queue send_ok=5 recv_ok=5 last_recv_count=1
```

- **5 次 send 全部成功**（`Queue.send` 的成功分支）；
- **5 次 recv 全部取到数据**（`last_recv_count=1` 表示最后一次 recv 时队列里有 1 项）。

⇒ **队列通路完全正常**：blob 发的 5 条消息都被 blob 任务收下了。

⇒ 此前那个"send 之后 recv 看到 count=0"的异常是**误读**：`recv_probe` 只记录**前 6 次** recv 的
`count`，而那几次发生在 send **之前**；后续的 recv 确实拿到了数据。

⇒ **"消息没送到"这条假设彻底排除**。blob 任务收到了全部消息、仍然不推进 ⇒ 问题在**消息处理之后**
（即任务拿到消息后走到的分支），或消息**内容/类型**不对。

### ★★ IDF 侧消息流对拍：**与我们完全相同**（`QS type=6`）

在 IDF 的 `esp_adapter.c` 里给 `queue_send_wrapper`/`queue_recv_wrapper` 加打印（`QS queue=… type=…` /
`QR queue=…`），并在 `wifi_init.c` 的 init 前后加窗口标记 `HOOKTRACE begin/end`：

```text
HOOKTRACE begin
QR queue=0x2f07e504
QS queue=0x2f07e504 type=6
QR queue=0x2f07e504
QS queue=0x2f07e504 type=6
...（重复）
HOOKTRACE end
```

**IDF 在 init 期间也是在同一队列上反复投递 `type=6`**，与我们那 5 条 `type=6` **完全一致**
（队列指针不同是跨构建地址差异，不是语义差异）。

⇒ **消息流不是分歧点**（这条彻底排除）。两边发的消息类型、顺序、收/发配对都相同。

⇒ 于是分歧只能落在**消息处理之后**：同一个 `type=6` 消息，IDF 的处理器推进了状态机、我们的没有 ——
即处理器读写的**某个状态**或它调用的**某个钩子**不同。

IDF 树已还原（`components/esp_wifi` clean）。

### ★★ IDF 钩子计数对拍（init 窗口内）：**我们多调了 `_wifi_reset_mac`**

在 IDF 的 `esp_adapter.c` 里加计数器（boot-safe，不用 printf），在 `wifi_init.c` 的 init 窗口结束后打印：

```text
HOOKTRACE begin
HOOKTRACE end
IDFCNT qsend=1 qrecv=2 clken=1 rstmac=0
```

与我们同一窗口内的计数对比：

| 钩子 | IDF | 我们 | 差异 |
| --- | --- | --- | --- |
| `_queue_send` | 1 | **5** | 我们多 4 次（可能是窗口边界不同） |
| `_queue_recv` | 2 | 4~5 | 同上 |
| `_wifi_clock_enable` | 1 | **2** | 我们多 1 次 |
| **`_wifi_reset_mac`** | **0** | **1** | **IDF 在 init 里根本不调它，我们调了** |

⇒ **最有价值的差异是最后一行**：**IDF 的 init 期间从不调用 `_wifi_reset_mac`，我们调了一次**。
（注意这是**同一个 blob** 的调用决策 ⇒ 说明我们的 init 流程把 blob 带到了不同的分支，或者我们的
`_wifi_reset_mac` 被别处触发。）

⇒ 下一步：定位**谁**在我们这边调了 `_wifi_reset_mac`（`note(22, …)` 已有打点，看它在 trace 里的位置），
以及**把它去掉/延后**后 `MAC_ST` 是否会在 init 后变 0。

### ★★ 同窗口对拍（修正上一节）：`rstmac` 两边都是 0；真正差异是 **`clken` IDF=1、我们=0**

上一节把"IDF 的 init 窗口计数"与"我们**整个运行期**的计数"直接比，**口径不同、结论作废**。
现在在我们的探针里加了 **init 窗口快照**（`esp_wifi_init_internal` 前后取计数器差值）：

```text
我们的 INITWIN: qsend=1 qrecv=0 rstmac=0 clken=0
IDF 的 IDFCNT : qsend=1 qrecv=2 rstmac=0 clken=1
```

| 钩子 | IDF（init 窗口） | 我们（init 窗口） | 判读 |
| --- | --- | --- | --- |
| `_queue_send` | 1 | **1** | ✅ 一致 |
| `_wifi_reset_mac` | 0 | **0** | ✅ 一致（**上一节的"差异"是窗口假象**） |
| `_queue_recv` | 2 | **0** | 差异（窗口边界/任务是否在窗口内跑） |
| **`_wifi_clock_enable`** | **1** | **0** | **真差异：IDF 在 init 里开了 WiFi 时钟，我们没开** |

⇒ **目前唯一同口径下的行为差异**：**IDF 的 init 会调用 `_wifi_clock_enable` 一次，我们的 init 没有**。
（我们的 `wifi_clk_en` 共 2 次，都发生在 init 之外。）

⇒ 下一步：既然 blob 是同一份，"init 里不调 `_wifi_clock_enable`" 说明**我们的 init 在更早的地方走了不同分支**，
或那次调用被我们的某个钩子返回值挡掉了（例如某个前置钩子返回 0/失败）。

### tick 驱动的任务泵：**在 init 期间会 panic**（`mepc=0xffffffa0`）

把 blob 任务的泵挂到 trap 的 input-25 分支（带 `pump_active` 重入保护），从 `sched.start` 之后就武装：

```text
panic: exception code=1 (instruction access fault)
panic: mepc=0xffffffa0 mtval=0xffffffa0
panic: ra=0xffffffa0 a0=0x2f014bb4 a1=0x2f014ba8
（采样在 #512 就停了）
```

⇒ **任务在 init 阶段还不能被泵**：它的上下文还没初始化到"可安全恢复"的状态，在 ISR 里 `swapContext`
过去就会崩。这与探针自己早先的注释一致（"blob 的任务体在 `esp_wifi_start` 之前进入会解引用未初始化的上下文"）。

已回滚，基线恢复（`INITWIN qsend=1 qrecv=0 rstmac=0 clken=0`、无 panic、自旋 `0x2f009206`）。

**正确的做法**：泵的开关要放到 **`esp_wifi_init_internal` 返回之后**（即 start/自旋期间）再武装——
那才是 IDF 里 blob 任务与 `esp_wifi_start` 真正并发的时间窗。这条还没试。

### 更正：init 期间**已经有**合作式任务切换（`swap#1..#8`）

此前推断"init 期间没有并发"。查日志否掉了这条：`idleHook` 里本来就有双向 `swapContext`
（`in_task` 时切回 main、否则切到 task），实测在 init 期间就在来回切：

```text
swap#1 in_task=true  hooks=150
swap#2 in_task=false hooks=158
swap#3 in_task=true  hooks=162
...
```

⇒ **"init 期间没有并发"这个假设不成立**：blob 任务在 init 的每个阻塞点都被切进去运行过。

⇒ 于是 init 窗口 `qrecv=0`（IDF 是 2）的差异**不是"任务没被调度"**，而是**任务跑起来后没有去 `queue_recv`**
——即任务在 init 期间走的分支与 IDF 不同。

⇒ 这把问题进一步收窄到"**任务运行时的分支决策**"，而不是调度。

### 判决：真阻塞 + 泵 PP worker = **活锁**（`idle_calls` 涨到 20000，`hooks` 冻结在 17）

IDF 的 `xSemaphoreTake(sem, portMAX_DELAY)` 是**真等到被 give**。我们把 `Semphr.take` 的无限阻塞
改成近似无限（上限 2,000,000 次让出），同时把 **ROM 的 PP worker** 挂到自己的栈、从 tick 里泵：

```text
idle_calls=16000 in_task=false hooks=17
idle_calls=17000 in_task=false hooks=17
idle_calls=18000 in_task=false hooks=17
idle_calls=19000 in_task=false hooks=17
idle_calls=20000 in_task=false hooks=17
idle budget exhausted (20001), halting
```

**`hooks` 从 17 起就冻结不动，`idle_calls` 一路涨到上限** —— 正是旧注释描述过的活锁。

⇒ **实验直接证明的只是**：在 init 期间泵 blob 任务与 PP worker，**blob 的等待都没有被满足**；
而且 **`hooks` 冻结在 17** ⇒ **泵 PP worker 的整个过程里，它一次 osi 钩子都没调用**。

⇒ 所以更准确的说法是：**PP worker 仍可能是那个生产者，只是它自己卡在某个前置条件上**
（`hooks 17 → 17` 说明它没做任何 osi 动作，多半在等某个事件/条件）。
"泵它没效果"只排除了"泵一下就能推进"，**没有**排除"它才是生产者"。

⇒ 下一步：在泵 PP worker 前后各读一次 `impl.event_count` 把"17 → 17"变成显式证据，
再查**它在等什么**（最可能的候选仍是 PHY/RF 就绪——我们从没真正完成过标定）。

⇒ 这解释了为什么"有界让出"是必要的：真等会活锁。两条都已回滚，基线恢复
（`INITWIN qsend=1 qrecv=0 rstmac=0 clken=0`、无 panic、自旋 `0x2f009206`）。

### IDF 侧消息类型分布（宿主侧从已有日志读出，无需再烧板）

从 `/tmp/pb-idf11.log`（带 `QS/QR` 打印的那次）：

```text
HOOKTRACE begin
QR queue=0x2f07e504          ← init 窗口内先"收"
QS queue=0x2f07e504 type=6   ← 再"发"类型 6
HOOKTRACE end
```

整个运行期的 `QS` 类型分布：

| 类型 | 次数 |
| --- | --- |
| 17 | 357 |
| 7 | 83 |
| 0 / 16 / 8 | 各 66 |
| **6** | **12** |

⇒ **关键顺序差异**：**IDF 的 init 窗口是"先收后发"（QR → QS type=6），我们的是"只发不收"（qsend=1 type=6、qrecv=0）**。

⇒ **这两条差异（`qrecv=0` 与 `clken=0`）很可能是同一个根因的两个表征**：没收到回复 ⇒ 所以没走到
开时钟那一步。**不要把它们当两条独立的线分别查。**

⇒ ~~这与窗口计数（IDF `qrecv=2 clken=1` vs 我们 `0/0`）一致：**我们的 init 在第一次"收"之前就走了另一条路**。~~

> [!warning] ⚠ 已撤回（后轮实测推翻）
> 握手修好之后，我们的窗口计数变成 `qsend=1 qrecv=2 clken=1 rstmac=0`，
> **与 IDF 的 `IDFCNT qsend=1 qrecv=2 clken=1 rstmac=0` 四项逐项相同**。
> 所以"我们的 init 走了另一条路"这条读法**不成立**——当时的 `qrecv=0 / clken=0`
> 是**有界让出提前返回 0** 的直接后果（生产者根本没被泵起来），不是"另一条路径"。

⇒ 下一步：在**我们的 init 窗口**里把 `queue_send`/`queue_recv` 的**载荷类型**也打出来（现在只统计次数），
与 IDF 的 `QR`/`QS type=6` 逐条对齐。

### 自旋期间的 tick 泵：**不再 panic，但无任何推进**

上一轮的 tick 泵 panic（`mepc=0xffffffa0`）纯粹是**武装时机**问题：那时泵在 `sched.start` 之后就生效，
会在 **init 期间**切进尚未就绪的任务上下文。把武装改到 **`esp_wifi_init_internal` 返回之后**再试：

```text
INITWIN qsend=1 qrecv=0 rstmac=0 clken=0
post-init ctx ... mac=0x0000e000
queue send_ok=5 recv_ok=5 last_recv_count=1
irq-sample #11776 ... mepc=0x2f009206
panic 0
```

⇒ **不再崩溃**（武装顺序确实修好了），但**自旋期间从 tick 泵 blob 任务没有任何推进**。

⇒ 至此"泵"这条线全部走完：主上下文 8/16 轮、tick 泵（init 期崩、自旋期无效果）、真阻塞+PP worker（活锁）。
**唯一的正面结论**是：**泵本身不是解法** —— 缺的是被泵者需要的前置条件。

已回滚，基线恢复。

### ★ ROM 侧反汇编：`ppTask` 的第一条动作是 **`_semphr_give(s_pp_task_create_sem)`**

`ppTask`（`0x2f800fc0`）是**跳板**（`j 0x2f831f9e`），真体在 `0x2f831f9e`：

```asm
2f831f9e: addi sp,sp,-48
2f831fa6: lw   a5,-188(s0)      # osi_funcs 基址（0x2f07ff44）
2f831fae: lw   a0,-236(a4)      # a0 = *(0x2f07ff14) = s_pp_task_create_sem
2f831fb2: lw   a5,64(a5)        # osi_funcs[16]
2f831fd2: jalr a5               # ← **第一条动作**
```

`osi.zig` 里第 16 项是 **`_semphr_give`** ⇒ **`ppTask` 一启动就 `give(s_pp_task_create_sem)`**，
用它通知"PP 任务已起来"。

**这与我们的一个已知特例直接相关**：`shellSemphrGive` 里有

```zig
if (p == null) { null_give += 1; return 0; }   // 空句柄的 give 被丢弃
```

⇒ 如果 `*(0x2f07ff14)` 在我们这边是 **null**（例如 `pp_create_task` 那条路没把它存进去），
**这次 give 就被丢掉** ⇒ 等它的那一侧永远不醒。

⇒ 下一步（很具体）：在探针里读 **`*(0x2f07ff14)`**（ROM 全局 `s_pp_task_create_sem`），看它是否为空；
并查 `null_give` 计数是否 > 0。

### ★★ 决定性读数：`s_pp_task_create_sem = 0x0`，且有 **1 次空句柄 give 被丢弃**

在自旋点读 ROM 全局与 give 计数：

```text
romglob s_pp_task_create_sem=0x0
semphr give_total=4 null_give=1
```

⇒ **`ppTask` 首条动作要 `give` 的那个信号量是 NULL**，而我们的 `shellSemphrGive` 对空句柄
**直接丢弃并返回 0** ⇒ 那 1 次 `null_give` 就是它。

⇒ 这条链现在闭合了一半：
1. `pp_task_hdl` 非空 ⇒ PP 任务**被创建了**；
2. 但 **`s_pp_task_create_sem`（0x2f07ff14）是 NULL** ⇒ "PP 任务已起来"的通知**发不出去**；
3. 我们的 `_semphr_create` 返回的是**arena 指针**（`shellSemphrCreate`），不会返回 null，
   除非 arena 分配失败 ⇒ 所以更可能是 **blob 的 `pp_create_task` 那条路根本没把信号量存进 0x2f07ff14**
   （例如它先 `_semphr_create` 再存，而中间某个钩子返回 0 让它跳过了存储）。

⇒ 下一步：查 **谁写 0x2f07ff14**（反汇编里搜 `sw …,−236(base)`，base=0x2f080000），
以及它前面判了什么。

### `s_pp_task_create_sem` 的写者：blob 的 **`pp_create_task`**（`pp.o`）

在 blob 的 `pp.o` 里找到对 `s_pp_task_create_sem` 的**重定位**：

```text
c2: R_RISCV_HI20  s_pp_task_create_sem
c6: sw a5, 0(a4)              # ← 写它
fa: lw a0, 0(s2) ; R_RISCV_LO12_I s_pp_task_create_sem   # 读它
```

⇒ **`pp_create_task` 负责创建并存入这个信号量**；我们的运行期它是 **0** ⇒ 那次 `sw` 没执行到，
或写入的值就是 0（`_semphr_create` 返回 null）。

⇒ 而 `pp_task_hdl`（0x2f07ff18）非空 ⇒ 说明 `pp_create_task` **跑过一部分**。

⇒ 下一步：反汇编 `pp_create_task` 里 `sw a5,0(a4)` 前后的几条，看它前面判了什么、
以及 a5 来自哪（是否就是 `_semphr_create` 的返回值）。

### `pp_create_task` 的前半段（`pp.o` 反汇编）

```asm
0:  addi sp,sp,-48
12: lw   s5,52(g_wifi_menuconfig)
16: lw   a5,g_osi_funcs_p
1e: lw   a5,168(a5)      # osi_funcs[42] = _task_get_max_priority
2a: jalr a5
30: lw   a5,pp_task_hdl
36: beqz a5,.L640         # hdl 为空才跳到 .L640
3c: li   a0,6 ; ... wifi_log(...)
4e: lw   a5,g_osi_funcs_p
52: lw   a0,pp_task_hdl
56: lw   a5,152(a5)      # osi_funcs[38]
5a: jalr a5
5c: .L640: lw a5,s_wifi_queue ; beqz a5,.L641
```

⇒ 关键点：`pp_create_task` **先调 `_task_get_max_priority`（我们实现了吗？返回值对不对？）**，
再按 `pp_task_hdl` 是否为空走两条路。

⇒ 下一步（很具体）：
1. 查 `osi_funcs[42]`（`_task_get_max_priority`）在我们表里**是否是真实现**、返回值是多少；
2. 继续反汇编 `.L640` 之后（`s_wifi_queue` 分支），找到 `sw a5,0(s_pp_task_create_sem)` 的位置与其前置条件。

### app 侧创建 `s_pp_task_create_sem`：**被 blob 清回 0**

按"app 应当创建它"的思路，在 `esp_wifi_init_internal` 之前创建并存入：

```text
wifi-init-probe: s_pp_task_create_sem <- 0x2f020ad0     ← 写入成功
romglob s_pp_task_create_sem=0x0                        ← 自旋时读回 **0**
semphr give_total=4 null_give=1                         ← 仍然丢弃
```

⇒ **blob 会把它清零**（`pp_create_task` 先清、再期望某个钩子填）⇒ **单纯"app 侧创建"无效**。
`pp.o` 里只有 `lw a0, s_pp_task_create_sem; beqz`（只读），写者不在 `pp.o`。

⇒ 下一步：找出**清零它的那条指令**（`sw zero, …` 到 `0x2f07ff14`）以及紧随其后的"填值"路径。

### ★★ 找到了写者：`0x40048f08`，而它写出的值**不可能是 0** ⇒ 那条路没执行

全镜像里只有一处**写** `s_pp_task_create_sem`：

```asm
40048eee: li   a0,1
40048ef0: li   a1,0
40048ef6: jalr ...            # → 0x4004c728   （create(1,0)）
40048efa: seqz a1,a0          # a1 = (ret == 0) ? 1 : 0
40048f02: add  a0,a0,a1       # a0 = ret + (ret==0)   ← **保证结果 >= 1**
40048f08: sw   a0,-236(s0)    # ← 写 s_pp_task_create_sem
```

⇒ **这个写入的值恒 >= 1（绝不可能是 0）**。而我们实测读回 **0** ⇒ **这条 store 从未执行过**。

⇒ 结论非常明确：**blob 里"创建 PP 任务信号量"的那段代码（0x40048eee..0x40048f08）在我们的 init 里没有被走到**
——某个更早的分支把它跳过了。**这就是 init 分歧的具体位置**。

⇒ 下一步：反汇编 `0x40048ed8` 之前，找**进入这段代码的条件**（哪个 `beqz`/`bnez` 决定了走不到这里），
再看那个条件读的是哪个全局/返回值。

### ★★ 建与删的两个站点（都在同一对函数里）

**建**（`0x40039892..0x4003989e`）：

```asm
40039892: lw a5,-188(s0)   # osi_funcs
40039896: li a1,0
40039898: li a0,1
4003989a: lw a5,52(a5)     # osi_funcs[13] = _semphr_create
4003989c: jalr a5          # create(1, 0)
4003989e: sw a0,-236(s2)   # ← s_pp_task_create_sem = 返回值
400398a2: bnez a0, ...     # 非空才继续
```

**删**（`0x40039910..0x40039920`）：

```asm
40039914: lw a0,-236(s2)   # 取信号量
40039918: lw a5,56(a5)     # osi_funcs[14] = _semphr_delete
4003991a: jalr a5
40039920: sw zero,-236(s2) # ← 清零
```

⇒ 所以 `s_pp_task_create_sem` 的生命周期是 **`_semphr_create(1,0)` → 存入 → … → `_semphr_delete` → 清零**。
我们读到 **0** ⇒ **要么建的那段没执行，要么删的那段执行了**。

⇒ 下一步：定位这两个站点所属的函数入口，看**进入"建"的条件**（`bnez a0` 之前）与**"删"被谁调用**。

### 建点的门是 `bnez *(s_wifi_queue)`——而我们实测它非空，矛盾

建点前面那段（`0x40039820..0x4003987e`）：

```asm
40039820: lw a5,376(a5)      # osi_funcs[94] = _wifi_create_queue
40039824: jalr a5
40039826: sw a0,-228(s3)     # s_wifi_queue = 返回的包装体
4003982a: bnez a0,0x40039844 # 非空才继续
  ... 错误日志 → 返回 257
40039844: lw a5,0(a0)        # a5 = *(包装体) = 内部队列指针
4003984e: sw a5,-244(a4)     # 存到 0x2f07ff0c
40039852: bnez a5,0x40039892 # ★ 内部指针非空才跳到**建点**
  ... 错误日志（0x800）
4003986a: ... osi_funcs[95] = _wifi_delete_queue → sw zero,s_wifi_queue   # 拆除
```

⇒ **门的判据是 `*(_wifi_create_queue 的返回值)` 非空**。

而我们的实测日志：

```text
wrapper=0x2f021994 inner=0x2f021330     ← 两者都非空
```

⇒ **这道门应该放行**，建点应该执行，`s_pp_task_create_sem` 应该被写成非 0。

**但实测它是 0** ⇒ **矛盾**。可能的解释：
1. 这个函数在我们的流程里**根本没被调用**（它在别的路径上）；
2. 建点执行了，但**之后被 `_semphr_delete` 清掉**（`0x40039920`）。

⇒ 下一步：确认这个函数的**入口地址与调用者**，以及在我们的 init 里是否被走到。

### ★★ 矛盾解开了：`_semphr_create` 调了 2 次（都没返回 null），但 `ppsem` 仍是 0

给 `_semphr_create` 加了窗口计数，并把三个 ROM 全局一起打出来：

```text
INITWIN ... semcreate=2 semnull=0
ROMGLOB swq=0x2f021330 ppq=0x2f0203b0 ppsem=0x0
```

| 读数 | 含义 |
| --- | --- |
| `semcreate=2` / `semnull=0` | `_semphr_create` 在 init 窗口内**被调了两次、从未返回 null** |
| `swq=0x2f021330` | `s_wifi_queue`（内部队列指针）**非空** ⇒ 建点的门 `bnez` 会放行 |
| `ppq=0x2f0203b0` | `pp_task_hdl` 非空 |
| **`ppsem=0x0`** | **`s_pp_task_create_sem` 仍是 0** |

⇒ **`0x4003989e` 那条 `sw` 所在的函数，在我们的 init 流程里根本没有被执行**（否则门放行、store 必然发生，
且它写出的值恒 >= 1）。

⇒ **这就是 init 分歧的最终位置**：blob 里"创建 PP 任务 + 建信号量 + 起任务"的那一整段
（`0x40039820..0x40039920`）在我们的流程里没被走到；而 `pp_task_hdl` 非空说明**另一个入口**创建了任务
（或那是残留值）。

⇒ 下一步：找出**谁调用了 `pp_task_hdl` 的写者**，以及**谁应该调用 `0x40039820` 所在的那个函数**。

### `pp_task_hdl` 在全镜像里**只有清零的 store** ⇒ 非零值来自 ROM

搜 `0x2f07ff18`（`pp_task_hdl`）的所有写：

```text
400386ee: sw zero,-232(s0)
4003988c: sw zero,-232(s1)
2f00d804: sw zero,-232(a5)      # blob 的 IRAM（任务入口 0x2f00d70a 附近）
```

**没有任何一处写入非零值** ⇒ 我们读到的 `0x2f0203b0` 只能来自 **ROM 代码**（不在我们镜像里）。

⇒ 结合上一条（`0x40039820..0x40039920` 那段"建队列 + 建信号量 + 起任务"没被执行）：
**blob 的 `pp_create_task` 在我们的 init 里从未被调用**，`pp_task_hdl` 里的值是 ROM 侧的残留/别的来源。

⇒ **这就是 init 分歧的最终位置**：**`pp_create_task` 没被调用**。
下一步：找它的**调用者**（在 blob 里搜 `jal` 到 `0x40039820` 所在函数入口），
再看那条路径的前置条件。

### `pp_create_task`（`0x40039794`）**没有直接调用者** ⇒ 它靠函数指针调用

`0x40039820` 所在函数入口是 **`0x40039794`**（`addi sp,sp,-48`），结构与本 ADR 早前记的
`pp_create_task` 一致（`lw s5,52(g_wifi_menuconfig)` → `osi_funcs[42]` …）。

全镜像里**搜不到 `jal 0x40039794`** ⇒ 它**不是被直接调用**的，而是经**函数指针**（某个表/导出符号）调用。

⇒ 这与"我们的 init 从未进入这段代码"一致：**调用它的那个指针/入口，我们这边没有被触发**。

⇒ 下一步（两条）：
1. 在 blob 里搜**把 `0x40039794` 放进表/全局**的地方（`lui`+`addi` 或 `.data` 里的初值）；
2. 或按**符号名**在 `blobobjs/*.o` 里 `nm` 出 `pp_create_task` 的引用者（谁 `jal` 到它）。

### `ic_create_wifi_task` → `pp_create_task`：**无条件尾调用**（没有门）

`if_hwctrl.o` 里：

```asm
00000000 <ic_create_wifi_task>:
   0: auipc t1,0x0
      R_RISCV_CALL pp_create_task
   4: jr    t1            # ← 尾调用，无任何条件判断
```

⇒ **只要 `ic_create_wifi_task` 被调用，`pp_create_task` 就必然执行**。

而我们此前在 pdFAIL 实验里观察到：`_task_create` 返回 0 ⇒ `esp_wifi_init_internal` 返回 **257**，
且当时的判读是"错误来自 `ic_create_wifi_task`" ⇒ **说明它在 init 路径上被调用了**。

⇒ **这与"`s_pp_task_create_sem` 的 store 没执行"矛盾**（只要 pp_create_task 跑，store 就该发生）。

**最可能的解释**：我把 `0x40039794` 当成 `pp_create_task` 的**链接后地址**这一步**没有验证过**
（我们的 ELF 无符号表，`.o` 里的偏移不等于链接后地址）。

⇒ 下一步（必须先做）：**用 `.o` 的段内偏移 + 段基址**把 `pp_create_task` 的真实链接地址算出来，
再核对 `0x40039794` 到底是不是它。否则后面所有"这段代码没执行"的结论都建立在错误的地址映射上。

### 地址映射核对：`0x40039794` 是 `pp_create_task`，但它**删**信号量而不是建

`pp.o` 的 `.text.pp_create_task` 里，偏移 `0xfa..0x108`：

```asm
 fa: lw   a0,0(s2)        # a0 = s_pp_task_create_sem
 fe: beqz a0,108          # 为空就跳过
102: lw   a5,56(a5)       # osi_funcs[14] = _semphr_delete
106: jalr a5              # 删掉它
108: sw   zero,0(s1)      # 清 s_wifi_queue
```

⇒ **`pp_create_task` 是"先删旧的再重建"里的删除段**（它删信号量、清队列），**不是建点**。

而**建点 + 存值**在另一个函数（`0x40048eee..0x40048f08`，那里有 `ret + (ret==0)` 的防空技巧）。

⇒ 所以"`0x4003989e` 的 store 没执行"这条**判读是错的**——`0x4003989e` 落在**别的函数**里
（地址映射核对：`0x4003989e − 0x40039794 = 0x10a`，不是 `.o` 里任何一条指令的起点）。

**教训（再次）**：把 `.o` 的段内偏移直接加到某个函数入口上，**必须先验证偏移落在指令边界**，
否则会把不同函数的指令混在一起解读。已据此撤回该判读。

### ⚠ 方法学定论：`.o` 段内偏移**不能**直接加到链接后地址

想在 `pp.o` 里定位 `s_pp_task_create_sem` 的 store（`0x11a: sw a0,0(s2)`，确实在 `.text.pp_create_task` 段），
于是按"入口 + 偏移"推算：

```text
假设入口 = 0x40039794  ⇒  0x40039794 + 0x11a = 0x400398ae
实测 0x400398ae 处：  lw a5,-188(s0)     ← **不是 sw**
```

⇒ **"入口 + `.o` 偏移"这条推算不成立**（链接器会重排/合并段，`.o` 的段内偏移不等于链接后的段内偏移）。

**更正（同日）**：这个"定论"下得太宽。做了**逐条指令对齐**验证：

| `.o` 偏移 | `.o` 指令 | 链接地址 | 链接后指令 |
| --- | --- | --- | --- |
| 0x0 | `addi sp,sp,-48` | `0x40039794` | `addi sp,sp,-48` ✅ |
| 0x2 | `lui a5,g_wifi_menuconfig` | `0x40039796` | `lui a5,0x2f016` ✅ |
| 0x6 | `sw s0,40(sp)` | `0x4003979a` | `sw s0,40(sp)` ✅ |
| 0x8 | `mv a5,a5` | `0x4003979c` | `addi a5,a5,-1920` ✅ |
| 0xc | `lui s0,g_osi_funcs_p` | `0x400397a0` | `lui s0,0x2f080` ✅ |
| 0x10 | `sw s5,20(sp)` | `0x400397a4` | `sw s5,20(sp)` ✅ |
| 0x12 | `lw s5,52(a5)` | `0x400397a6` | `lw s5,52(a5)` ✅ |

⇒ **入口 `0x40039794` 确实是 `pp_create_task`，前段偏移映射成立**。
但**后段偏移对不上**（`0x11a` 处 `.o` 是 `sw`，链接后 `0x400398ae` 是 `lw`）⇒ **链接器对后段做了重排/切分**。

**修正后的规则**：`.o` 偏移 → 链接地址的换算**前段可用、后段不可假定**——
**每一条都要按内容对齐验证**，不能整段套用。

### `pp_create_task`（`0x40039794`）的分支图（链接后，已逐条核对）

```asm
400397ca: beqz a5, 0x400397ec      # 早退 1
400397f4: beqz a5, 0x40039816      # 早退 2
40039820: lw a5,376(a5)            # osi_funcs[94] = _wifi_create_queue
40039824: jalr a5
40039826: sw a0,-228(s3)           # s_wifi_queue(包装体)
4003982a: bnez a0, 0x40039844      # 非空 → 继续
40039842: j 0x4003994c             # 否则 return 257
40039844: lw a5,0(a0)              # 内部队列指针
4003984e: sw a5,-244(a4)           # 存到 0x2f07ff0c
40039852: bnez a5, 0x40039892      # ★ 内部指针非空 → **建信号量块**
40039866: jal 0x40009ae8           # 否则错误日志
4003986e: beqz a0,0x4003987e
40039870: lw a5,380(a5)            # osi_funcs[95] = _wifi_delete_queue
40039878: jalr a5
4003987a: sw zero,-228(s3)         # 清 s_wifi_queue
40039890: j 0x4003983e             # return 257
--- 建信号量块 ---
40039892: lw a5,-188(s0)
4003989a: lw a5,52(a5)             # osi_funcs[13] = _semphr_create
4003989c: jalr a5                  # create(1,0)
4003989e: sw a0,-236(s2)           # ★ 存 s_pp_task_create_sem
400398a2: bnez a0, 0x400398ae      # 非空 → 继续
--- 删除信号量块（另一条路） ---
40039914: lw a0,-236(s2)
40039918: lw a5,56(a5)             # osi_funcs[14] = _semphr_delete
4003991a: jalr a5
40039920: sw zero,-236(s2)         # ★ 清零
```

**矛盾仍在**：我们实测 `*(0x2f07ff0c)=0x2f021330`（非空）⇒ `bnez` 应放行 ⇒ `0x4003989e` 应写入非 0；
但 `0x2f07ff14` 读回 0。

⇒ 两种可能：① `0x40039914..0x40039920`（删+清）在之后执行过；② 我们读 `0x2f07ff0c` 的**时机**晚于它被改写。
⇒ 下一步：**在 init 窗口结束后立刻读 `0x2f07ff14`**（现在只在自旋时读），看它是"从来没写"还是"写了又被清"。

### ★★ 关键分支：`pp_task_hdl` 非零 ⇒ `pp_create_task` 走"删除已有任务"路径

```asm
400397be: jalr a5              # osi_funcs[42] = _task_get_max_priority
400397c0: lui s1,0x2f080
400397c4: lw a5,-232(s1)       # a5 = pp_task_hdl (0x2f07ff18)
400397c8: mv s4,a0             # s4 = max_priority
400397ca: beqz a5, 0x400397ec  # ★ 为 0 → 直接去创建；非 0 → 走下面
400397cc: ... 错误日志
400397de: lw a5,-188(s0)       # osi_funcs
400397e2: lw a0,-232(s1)       # a0 = pp_task_hdl
400397e6: lw a5,152(a5)        # osi_funcs[38] = _task_delete
400397ea: jalr a5              # **删掉"已有"的任务**
```

**我们的 `pp_task_hdl = 0x2f0203b0`（非零）** ⇒ **走的是"先删已有任务"这条路径**。

而 `0x2f0203b0` 很可能是我们 `_task_create` 写出的 **`task_dummy`** 地址（假任务对象），
并不是真正的 PP 任务句柄 ⇒ **`_task_delete` 作用在一个假对象上**，可能把后续流程带偏。

⇒ **这条是"我们的 init 与 IDF 走不同分支"的一个具体、可修的点**：
IDF 那边 `pp_task_hdl` 在 init 时应当为 0（首次创建），我们却带着上一次 `_task_create` 留下的假句柄。

⇒ 下一步：在 `esp_wifi_init_internal` 之前把 **`pp_task_hdl` 清零**（或让 `_task_delete` 对假对象安全），
看分支是否改变。

### 清零 `pp_task_hdl`：**无效**（init 里又被写回 `task_dummy`）

在 `esp_wifi_init_internal` 之前把它清 0：

```text
INITWIN ... semcreate=2 semnull=0
ROMGLOB swq=0x2f021330 ppq=0x2f0203b0 ppsem=0x0    ← ppq **又变回 task_dummy**
```

⇒ **init 期间我们的 `_task_create` 又把它写成 `task_dummy`**，所以"清零让它走首次创建分支"这个思路不成立。

⇒ 更根本的问题在**我们的 `_task_create` 语义**：它把 `handle_out` 写成固定的 `&task_dummy`
（不是每次新建一个对象）。blob 侧对 `pp_task_hdl` 的判断（非零 ⇒ 已有任务）因此恒为真。

⇒ 下一步：让 `_task_create` 返回**每次不同的**句柄（或让 `_task_delete` 对 `task_dummy` 安全无害），
再看 `pp_create_task` 的分支与 `ppsem`。

### ★★ 判决：`_semphr_create(1,0)` **确实被调用过** ⇒ 值是被之后清掉的

给 `_semphr_create` 记录参数（打包成 `max<<16|init`）：

```text
semcreate args: #0=0x00010000  #1=0x00000001
```

- `#0 = 0x00010000` ⇒ **max=1, init=0** ⇒ **`(1, 0)`** —— 正是 `pp_create_task` 建块里的调用形态
  （`li a0,1; li a1,0`）；
- `#1 = 0x00000001` ⇒ (0,1)，另一个信号量。

⇒ **`pp_create_task` 的建块确实执行了** ⇒ `0x4003989e` 的 store 必然写入了非 0 值
⇒ **`s_pp_task_create_sem` 是之后被清成 0 的**。

⇒ 于是问题变成：**谁在之后清了它？** 全镜像里只有两处清/写：
- `0x40039920: sw zero,-236(s2)`（`_semphr_delete` 之后）
- `0x40048f08: sw a0,-236(s0)`（另一个函数，带 `ret+(ret==0)` 防空，写非 0）

⇒ **只能是 `0x40039920` 那条删除路径**。下一步：找它的**调用者/触发条件**。

### ★★★ 完整序列找到了：**take（等 PP 任务报到）→ delay(1) → delete → 清零**

`0x40039900..0x40039924` 这一段：

```asm
40039900: lw a5,60(a5)        # osi_funcs[15] = _semphr_take
40039902: jalr a5             # ★ **等 PP 任务 give（报到）**
40039904: lw a5,-188(s0)
40039908: li a0,1
4003990a: lw a5,156(a5)       # osi_funcs[39] = _task_delay
4003990e: jalr a5             # delay(1)
40039910: lw a5,-188(s0)
40039914: lw a0,-236(s2)      # s_pp_task_create_sem
40039918: lw a5,56(a5)        # osi_funcs[14] = _semphr_delete
4003991a: jalr a5             # 删掉信号量
4003991c: lw a4,-232(s1)
40039920: sw zero,-236(s2)    # ★ 清零
```

⇒ **这是 `pp_create_task` 的正常收尾**：建信号量 → 起 PP 任务 → **`take` 等它 give（报到）** → delay(1)
→ 删掉信号量 → 清零。

⇒ **关键**：我们的 `Semphr.take` 在 `time_blocking` 下**只让出 64 次就返回 0**（"超时"）⇒
blob 以为"等到了/超时了"⇒ **直接走到删信号量 + 清零** ⇒ `ppsem = 0`。

⇒ 而 PP 任务此时才可能去 `give` 一个**已经被删掉**的信号量 ⇒ 被我们的空句柄特例丢弃（`null_give=1`）。

**这就是整条链**：
**bounded take 提前返回 ⇒ blob 删掉信号量 ⇒ PP 任务的"报到"give 落空 ⇒ 后续依赖它的状态机不推进。**

⇒ 下一步：把 `Semphr.take` 的 `time_blocking` 改成**真阻塞**，**同时**保证阻塞期间 PP 任务能被调度
（`on_idle` 里除了切 blob 任务，也要能切 PP 任务）。

### ⚠ 撤回一条判读：曾经的「真阻塞 + idleHook 泵 PP worker ⇒ init 直接挂住」

**曾经的写法**：三处配套改动（真阻塞 take、idleHook 优先切 `pp_ctx`、PP 上下文在 init 前建好）之后
init 挂住（无 INITWIN、无 post-init、`panic 0`）⇒ 结论写成"PP worker 被切进去了，但始终没有 `give`"、
"PP worker 在我们这个环境里跑不到它的 `give`"。

**真相**：那次实验跑在 **`g_osi_funcs_p` 仍为 NULL** 的环境里（见下方「★★★ 崩溃根因」）。`ppTask` 入口
第一条 `lw a5,64(a5)` 就 fault ⇒ **`give` 根本没机会执行** ⇒ "跑不到 give"**从未被验证**。init 挂住的原因是
`take` 等一个**永远到不了的** give，而 give 缺席的原因是 NULL 槽位，不是"PP worker 跑不到"。

⇒ 结论应改成：**"NULL 槽位下，任何形式的泵都只会 fault 或空等"**。泵本身没有被否定。

### ★★ 重新解读：`s_pp_task_create_sem` 在 init 之后为 0 是**设计如此**

回看那条序列：

```asm
40039900: take(sem)          # 等 PP 任务报到
4003990a: task_delay(1)
4003991a: semphr_delete(sem) # **无条件删除**
40039920: sw zero,s_pp_task_create_sem   # 清空全局
```

⇒ **它是一个一次性的"握手信号量"**：建 → 起任务 → `take` 等报到 → 删掉 → 清空。

⇒ **所以 init 结束后 `s_pp_task_create_sem == 0` 是正常状态，不是异常**。
之前把它当成"没建/被误清"的判读**要撤回**——我们一直在追一个**非异常**。

⇒ 真正的信号是 **`null_give=1`**：PP 任务的 `give` **在信号量被删除之后才到**（因为我们的 `take` 提前返回，
blob 已经走到删除那一步）。

⇒ 于是问题收敛成一句话：**`take` 必须真的等到 PP 任务的 `give`**。
而"真阻塞 + 泵 PP worker"实测会让 init 挂死（PP worker 跑不到 give）⇒ **下一步是查"PP worker 为什么跑不到它的 give"**，
而不是继续追信号量本身。

### ⚠ 撤回一条判读：曾经的「进入 `ppTask` 直接崩溃 ⇒ PP worker 无法在合成栈上运行 ⇒ 泵线彻底关闭」

**曾经的写法**：用包装入口泵一次 → 182 次 `load access fault`、"ppEntry entered" 从未打印
⇒ 结论写成"崩溃在**上下文切换/栈切换**这一步"、"`ppTask` 在我们的合成栈上根本跑不起来"、
"**"泵 PP worker"这条路彻底关闭**"。

**真相**（见下方「★★★ 崩溃根因」）：崩溃发生在 **`ppTask` 内部**的 `lw a5,64(a5)`——基址
`g_osi_funcs_p`（ROM 槽位 `0x2F07FF44`）在 init 之前是 NULL，于是从地址 `0x40` 读。装好槽位后，
**同一个合成栈上 `ppTask` 跑得好好的**（不崩，而且真的调到了 `_semphr_give` / `_queue_recv`）。

⇒ 三条都要撤：**不是**"上下文/栈切换崩"、**不是**"合成栈跑不起来"、**不是**"泵线彻底关闭"。

⇒ 准确的说法：**泵"合成入口"无效**（槽位 NULL + 队列未建）；**正确的对象是 blob 用 `_task_create`
建出来的真实任务**（队列已存在、信号量仍在时泵）。

### ⚠ 撤回一条判读：曾经的「`tp`（x4）不是崩溃原因」

`swapAsm` 只保存/恢复 `ra` + `s0..s11`（64 字节帧），**从不保存/设置 `tp`（x4）**——这仍是事实，
若 `ppTask` 用 tp 相对寻址，tp=0 会 `load access fault`。

实验：给包装入口一个清零的 4 KB TLS 区并 `mv tp` 之后再转 `ppTask`。结果仍是 182 次
`load access fault`、"ppEntry(no-tp)" 未打印。

**曾经的结论**："设 tp 无效，tp 不是（唯一）原因"。

**撤回理由**：包装入口的**第一行都没执行到**，`mv tp` 压根没跑过 ⇒ 这个实验**根本没测到 tp**，
不是"否定了 tp"。真正的崩因是 NULL `g_osi_funcs_p`（见下节），与 tp 无关——tp 这条既没被证实、
也没被证伪，**是无效实验**。

### ⚠ 撤回一条判读：曾经的「`mtval` 拿不到」

`trap.zig` 的 panic 行原本带长标签（`panic: mepc=… mtval=… mstatus=…`），ROM 启动横幅会**插进同一行**：

```text
panic: mepc=��SP-ROM:esp32s31-20251218
```

**曾经的结论**："故障地址被横幅覆盖，拿不到；要拿到必须先把 panic 信息缓存、稍后再打，或换独立通道。"

**撤回理由**：不需要那么麻烦——把三元组**放在第一行、不带长标签**就够了
（`log.line("!! {x} {x} {x}", …)`），短行能活下来。已入库（`23a28b4`），并据此拿到
`!! 2f00d726 40 3801` ⇒ 根因闭合。

### ★★★ 崩溃根因：`g_osi_funcs_p` 为 NULL（`lw a5,64(a5)` 从 0x40 读）

把 trap 的 panic 输出改成**先打三元组**（长标签行会被 ROM 横幅截断），拿到了故障现场：

```text
!! 2f00d726 40 3801        # mepc=0x2f00d726  mtval=0x40  mstatus=0x3801
```

反汇编 `0x2f00d71e` 正是 `ppTask` 的入口：

```asm
2f00d712: lw a5,-188(s0)   # a5 = g_osi_funcs_p   (0x2f07ff44)
2f00d71a: lw a0,-236(a4)   # a0 = s_pp_task_create_sem (0x2f07ff14)
2f00d71e: lw a5,64(a5)     # ★ a5 = osi_funcs[16] = _semphr_give  ← a5 是 NULL ⇒ 读 0x40
```

⇒ **`mtval=0x40` = 64 = `osi_funcs[16]` 的偏移**，基址 `a5` 是 **0**。

⇒ 根因：**`g_osi_funcs_p`（ROM 槽位 `0x2F07FF44`）在 init 之前是 NULL**。
`osi.install()` 在生产代码里**从未被调用**（只有主机用例），表是由 `esp_wifi_init_internal` 自己注册的。

### 验证：先装槽位，崩溃消失

```text
wifi-init-probe: slot installed prev=0x0 now=0x2f0206c0
（panic 0 次）
wifi-init-probe: trace semphr_give a0=0x00000000 a1=0x2f00d73c
wifi-init-probe: trace queue_recv a0=0x00000000 a1=0xffffffff   ← 之后一直重复
```

⇒ `prev=0x0` **直接证实**槽位原本是空。装好之后 `ppTask` **不崩了**，而且**真的调到了我们的钩子**：
先 `semphr_give(handle=0)`（信号量已被删，所以句柄是 0），然后 `queue_recv(handle=0, forever)`。

⇒ **第二个问题浮出来**：`queue_recv` 的句柄是 **0**——因为我们是**在 init 之前**泵 `ppTask`，
`pp_create_task` 还没跑，它的队列根本不存在。

### 结论：`ppTask` **不能在 init 之前泵**（两条独立的理由）

1. `g_osi_funcs_p` 还是 NULL ⇒ 入口第一条 `lw` 就 fault；
2. 它的队列还没被 `_wifi_create_queue(200, 8)` 建出来 ⇒ 即使不崩，也会阻塞在空队列上。

⇒ 正确的做法是：**泵 blob 自己 `_task_create` 出来的那个真任务**（在 init 期间/之后、队列已存在时），
而不是我们另起一个合成上下文跑它的入口。**这正是 `_task_create` 需要补的能力**：
现在它只记录，不运行；要让它能被合作式调度器真正跑起来。

### 下一步实现清单（根因闭合之后，泵线重开）

泵"合成入口"无效，但**泵 blob 自己 `_task_create` 出来的真实任务**仍然成立，而且接缝都在：

1. **先装表再泵**：`osi.install(&osi_table)` 必须在 `makeTable()` **之后**（表之前是 `undefined`，
   早装会把垃圾地址发布给 ROM 槽位）。init 里 `esp_wifi_init_internal` 之后还会用同一张表再注册一遍，
   两边地址一致才不会互相覆盖。**目前 `install` 只在主机用例里被调用，生产路径从未调用。**
2. **`_task_create` 要能真跑**：`shellTaskCreatePinned` 现在把 `stack_depth` 丢掉
   （`_ = .{ name, stack_depth, prio, core_id };`），只记 `tasks[n] = .{entry, arg}`。要跑真任务必须
   按 `stack_depth` 从 arena 分栈（先确认单位：IDF `xTaskCreate` 是字节，ROM 这条 osi 变体可能是字），
   再 `sched.initContext(ctx, stack, entry, arg)`。
3. **切走要落在阻塞路径里**：`Semphr.take` 与 `Queue.recv` 的阻塞循环里**已经有** `hooks.on_idle`
   （`osi_impl.zig:172` / `:265`）——把 `on_idle` 从"泵合成上下文"改成"切到下一个可运行的真实任务"即可，
   不用另起机制。
4. **`Queue.recv` 的返回 0 要撤**：代码注释自己写了"IDF 语义是永不返回 0"（`xQueueReceive(portMAX_DELAY)`），
   但当前自旋 `queue_block_spin_limit` 次后仍 `return 0`——blob 会把"空"当成合法答复走进错误分支。
   空队列+永久阻塞必须表现为**切回来源上下文**（RTOS 式 block），不是超时返回。
5. **记账别覆盖**：`sched.zig` 的 `main_context` 是单一全局，两层交替（main ↔ PP）够用；
   但被泵任务内部再进 `on_idle` 时**不能覆盖**它，否则 trampoline 切回时跳错栈。
   先只做两任务交替，语义跑通再扩。
6. **别顺手改句柄**：`tasks[]` 现在共享一个 `task_dummy` 句柄；握手只认 `s_pp_task_create_sem`，
   把句柄改成真对象是另一个实验变量。

### ★★★★ 修复落地：泵真实任务 ⇒ **握手 give 落到活句柄 + 队列句柄变真**

> [!warning] 更正（同轮）：**不是"init 首次成功返回"**
> 本 ADR 更早的日志里 `INIT OK` 已经出现过（`arena free=385376/389232`、`385264/389120`），
> 归档也有 `logs/wifi-init-ok-boot.log`——**init 早期就能返回 rc=0**。
> 本轮真正新的是**握手成了**：`give` 第一次落在**活句柄**上（`null_give` 1→0），
> PP 任务队列句柄变真（`queue_recv a0` 0→`0x2f0213b0`）。
> 以前那些 `INIT OK` 的握手是**坏的**（give 落在空/已删句柄被丢弃），这次是**好的**。

按上面的清单做了最小实现：

1. `Task` 增加 `stack` / `ctx` / `started`，`ensureTaskContext()` 按 `stack_depth` 从 arena 分栈
   （夹在 4 KiB..64 KiB，单位按字节但不确定时夹紧更安全），`shellTaskCreatePinned` 不再丢弃 `stack_depth`；
2. `idleHook` 改成 **round-robin 泵真实任务上下文**（`pumpRealTask()`），并在任务侧 `on_idle` 时
   **切回主上下文**（`cur_task` 记账，RTOS 式 block）。

板侧结果（`/tmp/pb260.log`）：

```text
pump#1 hooks=20  give=1 null_give=0
pump#2 hooks=20  give=1 null_give=0
pump#3 hooks=149 give=2 null_give=0
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315208/353392 B, bad_handle=0, blocking_refused=4
wifi-init-probe: tasks recorded=1
panic 0
```

对比基线（`qsend=1 qrecv=0 rstmac=0 clken=0`、无 `INIT OK`）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `qrecv` | 0 | **2** |
| `clken` | 0 | **1** |
| `give` / `null_give` | 1 / 1 | **2 / 0** |
| `INIT OK` | 早期就有（握手是坏的） | 仍有（握手是好的） |

⇒ **`null_give=0` 是关键**：PP 任务的 `give` 这次落到了一个**还活着**的信号量上（以前落在已删除的句柄上被丢弃）。
⇒ `take` 拿到 1 → blob 正常走完"删信号量 + 清零" → 状态机继续推进（`qrecv 0→2`、`clken 0→1`）。

### 遗留：init 之后的 blob 任务仍会自旋

`tasks recorded=1` 之后，探针照旧去跑 `tasks[0].entry`，那个任务在等 `esp_wifi_start` 的消息，
`hooks` 冻结在 154、`in_task=true`、`idle` 预算耗尽停机。这是**下一个问题**（`start` 之前任务不该被跑），
与本次修复无关——本次要证的"init 能过握手"已经证完。

### 队列句柄现在是真的（`_wifi_create_queue` 成功）

去掉重复的 `sched.start(&task_ctx, …)`（同一 entry 建两份上下文会让 `cur_task` 记账错位）后：

```text
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315208/353392 B, bad_handle=0, blocking_refused=4
wifi-init-probe: trace queue_recv a0=0x2f0213b0 a1=0xffffffff
wifi-init-probe: trace recv_probe a0=0x00000000 a1=0x00000008
panic 0
```

⇒ **`queue_recv` 的句柄从 `0` 变成 `0x2f0213b0`**（落在 arena 里，`table=0x2f020730` 同一片）——
说明 `pp_create_task` 的 `_wifi_create_queue(200, 8)` **这次真的成功了**。
（init 成功注册表之后才调用它，所以不需要我们手动 `install`。）

⇒ 剩下的挂点是**语义**问题，不是句柄问题：PP 任务在**空队列 + 无限超时**上等，而 init 已经返回、
没有人会再往里 post。`Queue.recv` 自旋 `queue_block_spin_limit` 次后 `return 0`，违反 IDF 语义
（`xQueueReceive(portMAX_DELAY)` 永不返回 0），blob 于是把"空"当合法答复。

⇒ 下一个动作：init 成功之后**直接调 `esp_wifi_start`**，让 `idleHook` 在 start 的阻塞里泵任务
（探针目前还停在 init 之后那段手动泵里，走不到 start）。

### 判决（负）：`Queue.recv` 改真阻塞后**仍然挂住**

把 `Queue.recv` 的 `portMAX_DELAY` 路径改成真阻塞（不返回 0，放弃上限 50,000,000 次），
并把 `idle` 预算从 20,000 放大到 4,000,000：

```text
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315192/353376 B, bad_handle=0, blocking_refused=4
wifi-init-probe: pump round 0 before: … recv=5 send=4 delay=1
wifi-init-probe: trace queue_recv a0=0x2f0213c0 a1=0xffffffff
wifi-init-probe: idle budget exhausted (4000001), halting
panic 0
```

⇒ 握手仍然成功（`INITWIN` 与 `INIT OK` 都在），但主上下文**走不到 `esp_wifi_start`**：
`recv=5 send=4 delay=1` 说明还在消息泵里，而 PP 任务在空队列上永久阻塞。

⇒ 结论：**只改 `recv` 的语义不够**。缺的是"谁该被调度"——主上下文此刻应该在跑 `esp_wifi_start`，
而探针还停在 init 之后那段手动泵里。**下一个动作是让控制流真的到 `esp_wifi_start`**，
而不是继续调 `recv` 的返回行为。

### ★★★★ 里程碑：控制流**到达 `esp_wifi_start`**

上一条负判决的原因是记账漏洞：`pump round` 那段走的是旧的 `task_ctx`（不经过 `pumpRealTask`），
而新的任务侧让出只看 `cur_task` ⇒ `cur_task` 为 null 时**直接 return、不切回主上下文** ⇒ 任务在
`on_idle` 里空转、主上下文永远回不去。

修法：任务侧让出时，`cur_task` 为空就**回退到旧的 `task_ctx` 切换**。

板侧结果：

```text
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315192/353376 B, bad_handle=0, blocking_refused=4
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
（之后 ROM tick 0x4003012e 持续运行，无 panic）
panic 0
```

⇒ **`esp_wifi_start` 首次被真正调到**（此前主上下文一直卡在 init 之后的手动泵里，永远走不到这里）。
⇒ ROM 的 tick ISR 在正常跑（`romhandler calls` 持续增长），说明中断与调度都是活的。

⇒ 下一步：看 `start` 是否返回、`MAC_ST` 的使能位（`b16`/`b288`）是否被置起。

### 结构性修正：entry/arg 搬进 `Context`、arena 按自然对齐申请

两个隐患，都会在"多任务泵"下咬人：

1. **`pending_entry`/`pending_arg` 是模块级单槽**（`sched.zig`）：`initContext` 写、`trampoline` 读。
   单任务没事，round-robin 下"先建 N 个、再逐个启动"会让**所有栈跑最后一个注册的 entry**。
   改法：`Context` 增加 `entry`/`arg` 字段，`trampoline` 从 `enterAs(ctx)` 指好的**目标上下文**里读。
2. **`arena_state.alloc(bytes, 16)` 会失败**：arena 只接受**自然对齐**的请求（`pad != 0` 直接跳过），
   第一个块之后全被跳过。改成 `@alignOf(usize)`；栈顶 16 对齐由 `initContext` 的 `alignBackward` 负责。

回归与修复：改完第一次上板**回退到 `esp_wifi_start` 之前**（`hooks` 冻在 154、`in_task=true`），
原因是 `sched.start()` 没调 `enterAs` ⇒ 自测路径的 `trampoline` 拿不到 entry。补上后恢复：

```text
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315160/353344 B, bad_handle=0, blocking_refused=4
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
panic 0
```

### ★ 新判读：start 的等待**不走我们的让出原语**

`idle_calls` 停在 **20**（`calling esp_wifi_start` 之后**再没有一条 idle 心跳行**），而 ROM tick 仍在跑。
⇒ `esp_wifi_start` 的等待**不调 `on_idle`** ⇒ 任务在 start 期间**永远不会被泵** ⇒ start 永等。

⇒ 下一步不是继续调 `recv`/`take`，而是**找到 start 的真实等待原语**（task notification？哪个 `_queue_recv` 变体？），
必要时把"泵"挂到 tick ISR 或那个原语上——就像 init 期挂到 `take` 上一样。

### `Semphr.take` 也改成真阻塞（与 `Queue.recv` 同一套语义）

`take` 此前仍是有界的（自旋 `idle_spin_limit`=64 次就 `return 0`，并 `blocking_refused += 1`）——
blob 的 `semphr_take(ack, BLOCKING)` 于是拿到 **0（假装超时）**，状态机走错分支。
现在生产者（PP 任务）已经能被泵起来并 give（`null_give=0`），"真等会活锁"那条旧结论的前提已不成立。

改成：`count == 0` 且 `blocking == time_blocking` 时循环 `serviceTimers()` + `on_idle()`，**永不返回 0**
（放弃上限 50,000,000 次，`semphr_block_giveup` 计数，正常应为 0）。

板侧无回归：

```text
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315144/353328 B, bad_handle=0, blocking_refused=4
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
panic 0
```

### ★★★★ `esp_wifi_start` 的挂点定位：`while ((MAC_ST & 0xE000) != 0)` 死循环

start 期间 IRQ 采样器的 `mepc` **全部落在同一个环上**（50 次 `0x2f009202`、31 次 `0x2f009206`）。
反汇编那段：

```asm
2f0091f8: lui  a3, 0x20105
2f0091fe: addi a5, a3, -852      # a5 = 0x20104CAC  ← MAC_ST
2f009202: lw   a5, 0(a5)         # ★ 读 MAC_ST
2f009204: and  a5, a5, a4        # a4 = 0xE000（bits 13..15）
2f009206: bnez a5, 0x2f0091fe    # ★ 这三位非 0 就一直转
```

⇒ **`esp_wifi_start` 在等 `MAC_ST` 的 bits 13–15 变成 0**。
我们板子上 `MAC_ST = 0x0000E000` ⇒ 这三位**全 1** ⇒ **死循环**。
（IDF 侧 `MAC_ST` 是 0，所以它能过——这与"IDF init 把 MAC_ST 清 0 而我们没清"那条硬事实完全对上。）

### 但软件写不掉：`MAC_ST = 0` 之后读回仍是 `0xE000`

```text
wifi-init-probe: MAC_ST before start = 0x0000e000 (spin mask 0xE000)
wifi-init-probe: MAC_ST cleared -> 0x0000e000
```

⇒ 这三位是**硬件状态位**（只读或被别的寄存器即时重设），**写 MAC_ST 清不掉**。

⇒ 下一步：找**谁驱动这三位**（时钟/复位域？`0x20100800`？`0x20109C18`？），
或者找 IDF 里把它变 0 的那条**真实动作**——不是写 MAC_ST 本身。

### MAC_ST 的三处软件写入都只碰 bits 17–19，**bits 13–15 没人写**

反汇编里所有触及 `0x20104CAC` 的写点：

| 地址 | 动作 | 掩码 |
|---|---|---|
| `0x40034594..0x4003459e` | 清 | `0xFFF1FFFF`（清 **bits 17–19**，`0xE0000`） |
| `0x40034D98..0x40034DA0` | 置 | `lui 0xe0`（置 **bits 17–19**） |
| `0x4003566C..0x40035674` | 置 | `lui 0xe0`（置 **bits 17–19**） |
| `0x40035738..0x40035740` | 置 | `or a4,a4,a3`（同一组） |

⇒ **没有任何一处写 bits 13–15**（`0xE000`）——而 `esp_wifi_start` 的自旋判据正是 `MAC_ST & 0xE000`。

⇒ 结论：**bits 13–15 是硬件状态位**，软件（包括我们写 0）都动不了它。
`esp_wifi_start` 在等一个**硬件条件**，而不是等某个软件标志。

⇒ 下一步只有两条路：
1. 找**硬件侧**让这三位变 0 的条件（时钟/复位域：`0x20100800`、`0x20109C18`、或 MAC 复位寄存器）；
2. 或者在**它之前**把 MAC 域带到"这三位本来就为 0"的状态（IDF 的 `bootloader_init_mem()` 做的多半就是这个）。

### 两个自旋：一个**有闸门**、一个**无条件**；闸门为 0 说明卡在无条件那个

`0x2f00254e`（闸门函数）反汇编：

```asm
2f00254e: lui  a5, 0x2f017
2f002552: addi a5, a5, 736       # a5 = 0x2F0172E0
2f002556: lbu  a0, 450(a5)       # a0 = b[0x2F0174A2]
2f00255a: bnez a0, 0x2f002560    # 非 0 直接返回它
2f00255c: lbu  a0, 740(a5)       # 否则 a0 = b[0x2F0175C4]
2f002560: ret
```

板侧读数：

```text
wifi-init-probe: gate b[2F0174A2]=0 b[2F0175C4]=0
wifi-init-probe: MAC_ST before start = 0x0000e000 (spin mask 0xE000)
```

⇒ 闸门返回 **0** ⇒ `0x2f0091d2` 那个等待（`beqz a0, 0x2f0091dc`）**本应被跳过**。

⇒ 但采样到的是**另一个自旋** `0x2f0091fe`，它**没有闸门**：

```asm
2f0091dc: lui  a5, 0x20105
2f0091e0: addi a5, a5, -852      # MAC_ST
2f0091e4: lw   a4, 0(a5)
2f0091e6: lui  a3, 0xff1         # 0x0FF10000（bits 12 + 16-23）
2f0091ea: li   a0, 20
2f0091ec: or   a4, a4, a3        # ★ 置 bits 20-23 / 24-31
2f0091ee: sw   a4, 0(a5)         # 写回 MAC_ST
2f0091f0: auipc ra, 0x7f7
2f0091f4: jalr -436(ra)          # 调 0x2f80003c（ROM）
2f0091f8: lui  a3, 0x20105
2f0091fc: lui  a4, 0xe
2f0091fe: addi a5, a3, -852      # MAC_ST
2f009202: lw   a5, 0(a5)
2f009204: and  a5, a5, a4        # & 0xE000
2f009206: bnez a5, 0x2f0091fe    # ★ 无条件死等
```

⇒ 顺序是：**置 MAC_ST 高位 → 调 ROM 函数 `0x2f80003c` → 等 bits 13–15 自己清 0**。

⇒ 它们**一直不清** ⇒ **MAC 域根本没起来**（时钟没真开 / MAC 还在复位），
不是等某个软件标志，而是等**硬件**。

⇒ 这把问题从"调度/语义"彻底推到**MAC 时钟/复位域**：下一步要查 `clken=1` 之后
MAC 的时钟是否真的送到、复位是否已释放（`0x20100800`、`0x20109C18`、MAC 复位寄存器）。

### 那个 ROM 调用是 `ets_delay_us(20)`——整段是「触发 → 等 20 µs → 等硬件清零」

`0x2f80003c` 在链接脚本里 `PROVIDE(ets_delay_us = 0x2f80003c)`（`rom_syms.ld:14`、`s31.ld:200`），
而调用前 `li a0, 20`。所以那段是：

```asm
or  a4, a4, 0x0FF10000   # 置 MAC_ST 高位（触发；`lui 0xff1` = 0x0FF10000，与 IDF after_start 实测的 0x00FF1000 同族）
sw  a4, 0(a5)
ets_delay_us(20)         # 等 20 µs
loop: lw a5, 0(MAC_ST)
      and a5, a5, 0xE000
      bnez a5, loop      # ★ 无条件等 bits 13-15 变 0
```

⇒ 这是一个**"写触发位 → 等 20 µs → 等硬件把状态位清 0"**的握手。
⇒ bits 13–15 **一直不清** ⇒ **MAC 硬件根本没响应这次触发**（没时钟 / 还在复位 / 没上电）。
⇒ 与"软件写不掉这三位"完全自洽：它们由硬件驱动，而硬件没在跑。

### 三处口径更正（读归档日志核对后）

1. **`lui a3, 0xff1` = `0x0FF10000`**（bits 12 + 16–23），不是 `0xFF100000`。它与 IDF `after_start`
   实测的命令字 `0x00FF1000` 同族——**命令写法两边一样**，差别只在命令前的 **MAC_ST 底色**（IDF=0，我们=`0xE000`）。
2. **`semcreate=65536` 不是计数器**：归档里 `semcreate args: 0x00010000 0x00000001` 说明 blob 调的是
   `_semphr_create(max=0x10000, initial=1)`；泵行里那个 `65536` 是**信号量的 max 参数**被误打进了 "semcreate" 标签。
3. **`null_give` 要注明口径**：**泵期间**是 0，但**运行末**是 `give_total=6 null_give=1`——
   `semphr_give a0=0x00000000 a1=0x2f00d73c`（`a1` 正是 ROM PP worker 的返回地址）就是**迟到的 give 落在已删句柄上**。
   所以"`null_give` 1→0"只对 **init 窗口内**成立。
4. **"彻底推到 MAC 时钟/复位域"是过度收口**：自旋 `0x2f0091fe` **不让出** ⇒ **ROM 的 PP worker 在
   `esp_wifi_start` 期间仍然一次都跑不到**。所以"MAC 域没起来"这个结论**仍带着旧前提**（"任务从未被调度"）。
   准确表述：**调度这条线在 init 期间已打通；start 期间的自旋仍不让出 ⇒ PP worker 仍跑不到，
   两种可能（硬件没起来 / 任务没跑到）尚未分离。**

### 判决（负）：`rst_wifimac` 脉冲（已加宽到 20 µs）**清不掉** MAC_ST bits 13–15

```text
wifi-init-probe: MAC_ST before start = 0x0000e000 (spin mask 0xE000)
wifi-init-probe: after rst_wifimac pulse MAC_ST=0x0000e000 (was 0x0000e000)
```

手动脉冲 `_wifi_reset_mac`（`0x20109C10` bit9，set → `ets_delay_us(20)` → clear）之后，
那三位**一位都没变**。

⇒ 两条假设同时被否：
1. **"复位脉冲太窄，异步域采不到"** —— 已加宽到 20 µs，仍无变化；
2. **"bits 13–15 属于 `rst_wifimac` 复位域"** —— 不属于。

结合此前"直写 MAC_ST 不粘"：这三位既**写不动**、也**复位不动** ⇒ 由**另一条路径**驱动
（更可能是某个使能/时钟序列完成后由硬件自己置位，而不是等软件清）。

⇒ 下一个判别点应转向**"谁把这三位置成 1"**，而不是"怎么清"。

### ⚠ 撤回一条判读：这是一次**重复实验**（`rst_wifibb` 早做过并判负）

**先记错**：本轮按 IDF `wifi_module_enable()` 补 `rst_wifibb` 脉冲 + `clk_conf1=0x17b` + `clk_wifibb_80x1_en`，
结果 `MAC_ST` 仍 `0x0000e000`。但 ADR **§候选清单实验 9** 早已写着
「脉冲 `rst_wifibb`（`0x20109C10` bit8）→ `0x0 -> 0x0`，`mac` 仍 `0x0000e000`」——
**这是同一实验的第二遍**。代码改动已回滚（顺带避开 `conf1 = 0x17b` 那次破坏性覆盖）。

⇒ 纪律：**改寄存器/脉冲变体之前，先查 §候选清单**。已连做几轮无进展，该换方向了。

### 判决（负）：补上 IDF 的 `rst_wifibb` 序列，MAC_ST 仍 `0xE000`（已回滚，见上）

IDF `wifi_module_enable()`（`modem_clock_impl.c`）在开 WiFi 模块时做了我们缺的三件事，
现按顺序补进 `_wifi_clock_enable`：

1. `modem_rst_conf.rst_wifibb`（`0x20109C10` **bit 8**）打 1 → `romDelayUs(20)` → 0 脉冲；
2. `clk_conf1` 写 `0x17b`（`clk_conf1_configure(hw, 1, 0x17b)`）；
3. 置 `clk_wifibb_80x1_en`（bit 7）。

板侧：

```text
wifi-init-probe: MAC_ST before start = 0x0000e000 (spin mask 0xE000)
wifi-init-probe: after rst_wifimac pulse MAC_ST=0x0000e000 (was 0x0000e000)
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=315144/353328 B, bad_handle=0, blocking_refused=4
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
panic 0
```

⇒ **`MAC_ST` 仍是 `0xE000`**。无回归（init 与 start 都照旧），但这一步也没解决它。

⇒ 目前已被否掉的"清位"路径：**直写 MAC_ST**、**`rst_wifimac` 脉冲**、**`rst_wifibb` 脉冲 + BB 时钟组**。
⇒ 剩下的可能：这三位根本不是"等清"的忙位，而是**某条更早的初始化链**（PHY/BB 上电、`ic_mac_init`）
完成后才由硬件置/清——下一步应查**谁在 IDF 里让 MAC_ST 变 0**（对比 init 前后的寄存器轨迹），而不是继续猜复位。

### ⚠ 方法学：那段反汇编**边界不可信**，别照着下补丁

采样到的 `mepc` 是 `0x2f009202` / `0x2f009206`——**都是 2 mod 4** ⇒ 那里是**压缩（16 位）指令**。
可是 ELF 的线性反汇编在 `0x2f0091fe`（同样是 2 mod 4）解出一条 **32 位** `addi a5,a3,-852`，
这**违反 RISC-V 的 4 字节对齐**（32 位指令必须 4 字节对齐）⇒ **线性扫描在那一带已经错位**。

⇒ 于是"把 `0x2f0091fe` 那 8 字节改写成 `auipc+jalr`"这个补丁计划**地址不可信**——
在错边界上写 8 字节会把 blob 改成垃圾。**已撤回，未上板。**

⇒ 正确做法（本 ADR 早前写过、这次没照做）：用 `/tmp/blobobjs/*.o` 的**符号表 + 字节匹配**定位函数，
再按 `.o` **自己的**反汇编取指令边界；不要用链接后 ELF 的线性扫描。

⇒ 顺带一条判读纪律：**看到 2 mod 4 的地址上出现 32 位指令，先怀疑反汇编错位**，
而不是先相信那条指令的内容（这次差点据此写坏代码）。

### ⚠⚠ 撤回一条**错误**判读：「offset%4==2 ⇒ 32 位指令不可能」是**错的**

**我写错了 ISA 前提。** 带 **C 扩展**的 RV32（本核 `generic_rv32+m+a+c+f+…`）`IALIGN = 16`，
指令只需 **2 字节对齐**——32 位指令出现在 `offset % 4 == 2` 处**完全合法**。

反例就在本仓的反汇编里（同一批清单）：

```text
2f00d716: 2f080737  lui a4,0x2f080      ← 32 位，地址 2 mod 4
40034d9a: 000e06b7  lui a3,0xe0         ← 32 位，地址 2 mod 4
```

⇒ 所以"线性反汇编错位"这个结论**作废**，`.iram_blobs` 偏移 2 mod 4 什么也证明不了。

⇒ **真实边界就是原来那套**，而且环头自证（`ffe5` 解出 imm=-8，`0x2f009206 - 8 = 0x2f0091fe`）：

```text
2f0091fe: addi a5,a3,-852      # 4 字节
2f009202: lw   a5,0(a5)        # 2 字节
2f009204: and  a5,a5,a4        # 2 字节
2f009206: bnez a5,0x2f0091fe   # 2 字节，回跳 -8
```

⇒ **自旋让出补丁恢复为"可做"**（不是"地址不可信"）。真正的坑是另外两个：
改写后 `ra` 的语义要补（或改用不依赖 `ra` 的跳转）、以及写完必须 `fence.i`。

### ★★★ 自旋让出补丁**成功执行**，且 `MAC_ST` 其实**可写**（推翻了"写不粘"）

补丁（`0x2f0091fe` 前 8 字节 → `auipc ra,hi; jalr ra,lo`，逐字节写 + `fence.i`）板侧确认生效：

```text
wifi-init-probe: spin patched -> 0x4004caac (auipc=0x11044097 jalr=0x8ae080e7)
wifi-init-probe: spin stub gave up rounds=4000001 MAC_ST=0x00fff000
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
panic 0
```

⇒ **桩真的接管了自旋**（跑了 4,000,001 轮），说明"改写 `.iram_blobs` 里的环"这条路是通的。

⇒ **`MAC_ST` 从 `0x0000E000` 变成了 `0x00FFF000`** ⇒ **这个寄存器是可写的**。
之前"写 0 后读回 0xE000"的判读要修正：**不是写不进去，而是写完之后 blob 自己那条
`or 0x0FF10000` 又把它改了**（顺序问题，不是只读）。

⇒ 但 **bits 13–15（`& 0xE000`）在 4,000,001 轮里始终没清** ⇒
**"让 PP worker 在 start 期间跑起来就能清掉这三位"这个假设被否**（在桩确实让出的前提下）。

### ⚠ 一个待查的异常：`idle_calls` 没有涨

桩跑了 4,000,001 轮，而 `idle_calls` 仍停在 20（没有 1000 的心跳行）。
`idleHook` 是**先自增**再判断的，所以这说明 **`idleHook` 没被调用** ⇒ 桩里 `!in_task` 为假
（`in_task` 一直是 true）。⇒ **"桩确实让出了"这一点还没被证实**，
上述"假设被否"要先打上这个保留。

### ⚠⚠ 撤回上一条判决：那次实验**根本没泵任务**，判决无效

**先记错**：上一节把 `idle_calls=4,000,000` 当成"桩让出了 400 万轮、PP worker 被泵了 400 万次"，
据此宣布"让 PP worker 跑起来也清不掉 MAC_ST"。

**真相**（两个数对不上，且日志末尾写着）：

```text
idle_calls=4000000 in_task=true hooks=57 tasks=1 e0=0x2f00d70a
wifi-init-probe: idle budget exhausted (4000001), halting     ← 是 **idleHook 自己的预算**在停机
```

1. **`hooks` 只从 20 涨到 57（37 次）**。PP worker 每被泵一次，它的 `queue_recv`/`take` 都会 `note()`；
   若真泵了 400 万次，`hooks` 应在百万量级。**37 次说明实际切到任务只有几十次。**
2. **`in_task` 一直是 true** ⇒ `idleHook` 每轮走的是"从任务切回主上下文"那个分支
   （`if (in_task) { … swapContext(&cur_task/task_ctx, &main_ctx) … return; }`），**`pumpRealTask()` 根本没被调用**。
3. 更糟的是：那时我们在**主上下文的桩里**，`in_task` 却是 true ⇒ 每轮都在**用错误的基址**做 `swapContext`
   ⇒ 这 400 万次不是"让出"，是**400 万次错位切换**。

⇒ **"让 PP worker 在 start 期间跑起来就能清 MAC_ST"这个假设，至今仍未被测过。**
⇒ 需要先修 `in_task` 的记账（桩里应视为主上下文），再加"实际切任务次数"计数器，
三个数（`idle_calls` / `switches` / `hooks` 增量）同量级才算让出真的生效。

### 已否掉的清位路径（订正后）

1. 直写 `MAC_ST`：**bits 13–15 是只读硬件状态位**（写 0、写 1 读回都是 1；复位值 `0xE000`，只能由硬件清零）；**bits 12 与 16–23 是普通 R/W**（命令字写进去能粘住）。两件事不矛盾——详见下方「★ 写语义定稿」。
2. `rst_wifimac` 脉冲（bit9，20 µs 宽）；
3. `rst_wifibb` 脉冲 + `clk_conf1=0x17b` + `clk_wifibb_80x1_en`（ADR 实验 9 早已判负）。
4. ~~让 PP worker 在 start 期间跑~~ —— **未测**（上一节误记，已撤回）。

### 判决（负）：自旋让出补丁**不安全**，已回滚——上下文记账不支持从 main 的任意点切入

从桩里直接调 `pumpRealTask()`：

```text
!! 3d306120 3d306120 80007881          # mepc = mtval = 0x3d306120（垃圾地址）
panic: exception code=1 (instruction access fault)
```

⇒ 切进任务后跳到了垃圾地址。两条路都不行：

| 走法 | 结果 |
|---|---|
| `idleHook()` | `in_task` 是残留 true ⇒ 走"从任务切回主"分支 ⇒ **用错基址 swap**（400 万次错位切换） |
| `pumpRealTask()` 直调 | **`instruction access fault`**，跳到 `0x3d306120` |

**根因**：`main_ctx` 只由 `sched.start()` 登记过一次。从 main 的**任意点**（这里是 blob 代码里的自旋桩）
让出时，**没有对应的 main 帧**可存 ⇒ 切回来必然错位。

⇒ 要真正做"在 start 的自旋里让出"，必须先让**每个让出点登记自己的 main 帧**
（每处一个 `Context`，或用 `setjmp` 式保存），**不是改几个字节就能解决的**。
⇒ 补丁已回滚，基线恢复（`INITWIN qrecv=2 clken=1` / `INIT OK` / `calling esp_wifi_start`、无 panic）。

---

## 当前状态总表（本轮结束时）

### 已打通（有板侧证据）

| 能力 | 证据 |
|---|---|
| osi 表注册 | `osi.install()` 补上后，`g_osi_funcs_p` 不再为 NULL |
| **init 期握手** | `null_give=0`（give 落到活句柄）、`qrecv 0→2`、`clken 0→1`、`INIT OK` |
| **任务真被调度（init 期）** | `_task_create` 按 `stack_depth` 分栈建上下文；`idleHook` round-robin 泵真实任务 |
| **队列句柄变真** | `queue_recv a0` 由 `0` 变 `0x2f0213b0`（arena 地址） |
| **控制流到达 `esp_wifi_start`** | `calling esp_wifi_start (idle_calls=20)` |

### 阻塞点

`esp_wifi_start` 自旋在 `while ((MAC_ST & 0xE000) != 0)`，而 `MAC_ST = 0x0000E000`，那三位**从不清**。

### 已否掉的清位路径

1. 直写 `MAC_ST`：**写 0 不粘**（写后**立即**读回仍是 `0xE000`，机制未明）；而 start 期命令字的 OR 位（bits 12+16–23）**能粘住**（实测 `0x00fff000`）⇒ **寄存器可写性与 bits 13–15 的行为尚未统一解释**（OR 只置位、且发生在后，解释不了 13–15 为何写 0 也回原值）。
2. `rst_wifimac` 脉冲（bit9，20 µs 宽）；
3. `rst_wifibb` 脉冲 + `clk_conf1=0x17b` + `clk_wifibb_80x1_en`（实验 9，早已判负）；
4. 从自旋桩里让出 —— **技术前提不具备**：`main_ctx` 只登记一次，从 main 任意点让出会错位
   （`idleHook` 走错分支 / `pumpRealTask` 直调跳到 `0x3d306120`）。

### 下一步（按性价比）

1. **对比 IDF 侧的寄存器轨迹**：在**已知正常的 S31** 上读同址 `MAC_ST`（init 前/后），
   确认那三位在 IDF 上到底是不是 0、什么时候变 0——这是唯一能直接回答"谁清它"的证据。
2. 若必须在裸机上做：先让**每个让出点登记自己的 main 帧**（`Context` per yield point），
   再做自旋让出实验；否则实验必然错位。
3. 不要再来回试寄存器/脉冲变体（已连试三项全负）。

### ★ 里程碑（更硬的证据）：**init 窗口的 osi 调用计数与 IDF 四项全同**

| 项 | IDF 侧（`IDFCNT`） | 我们（`INITWIN`） |
|---|---|---|
| `qsend` | 1 | 1 |
| `qrecv` | **2** | **2** |
| `clken` | **1** | **1** |
| `rstmac` | 0 | 0 |

修复前我们是 `qrecv=0 clken=0`——两项都不对。**现在四项逐项相同** ⇒
**init 阶段的 osi 调用行为与 IDF 完全一致**。这比"握手成了"更强，也是同口径、任何人可复核的两组数。

⇒ 因此 ADR 早前那条判读**被推翻**：「我们的 init 在第一次『收』之前就走了另一条路
（`qrecv=0`、`clken=0` 是同一个根因的两个表征）」——那两个差异现在都消失了。

### 更正：`tasks recorded=1` 是**设计如此**，不是"漏建第二个任务"

`ic_create_wifi_task` 是**无条件尾调用 `pp_create_task`**（无任何门），而 pdFAIL 实验
（`_task_create` 返回 0 ⇒ init rc=257）恰恰证明**它在 init 路径上被调用过**。
⇒ S31 上 blob **就只建这一个任务**，`entry=0x2f00d70a` 就是 PP worker。**不是漏建**，
别再顺着"缺 Wi-Fi 命令任务"这条不存在的线索查。

### 证据归档（不再只存在于 `/tmp`）

| 日志 | 内容 |
|---|---|
| `logs/ch25-start-boot.log` | `INITWIN qrecv=2 clken=1` / `INIT OK` / `calling esp_wifi_start` |
| `logs/ch25-spinpatch-yield-boot.log` | 自旋让出那次：`idle_calls` 涨到 4,000,000 而 `hooks` 冻在 57（"大部分 idleHook 没切任务"的实物） |
| `logs/ch25-spinpatch-panic-boot.log` | 桩里直调 `pumpRealTask` 的 `!! 3d306120` 垃圾跳转（回滚依据） |
| `logs/ch25-clock-readback-boot.log` | 时钟六寄存器 × 三时刻读回表（排除"时钟没开"的实物） |

### 取证：`0x3d306120` **不在我们的镜像里**——是"把数据当地址跳"

本镜像的段范围（`objdump -h`）：

```text
.flash.text    0x40000020
.flash.rodata  0x40100020
.trap_ram      0x2f000000
.iram_blobs    0x2f0000b0
.data          0x2f00f660
.bss           0x2f014e80
```

⇒ `0x3d306120` **落在所有这些段之外**（`0x3D000000` 一带是 flash 的 **DROM 数据映射区，不可取指**）。

⇒ 那次 `instruction access fault`（`mepc = mtval = 0x3d306120`）是**把数据当代码跳**——
与"上下文记账错位后恢复出一个被栈残值顶掉的返回地址/指针"一致。
⇒ 这也说明"修好账本再重做"是唯一正路：不是编码问题，是**帧/记账模型**问题。

### ★★★★ 时钟六寄存器 × 三时刻读回表 ⇒ **"时钟没开"被排除**

| 寄存器 | before-init | after-init | before-start |
|---|---|---|---|
| `clk_conf(+04)` | `0x00201002` | `0x00201002` | `0x00201002` |
| `force_on(+08)` | `0x00000000` | `0x00000000` | **`0x0000001C`** |
| `icg(+0C)` | `0x00000000` | **`0x64646400`** | `0x64646400` |
| `rst_conf(+10)` | `0x00000000` | `0x00000000` | `0x00000000` |
| `clk_conf1(+14)` | `0x00000000` | **`0x0038E7FF`** | `0x0038E7FF` |
| `lpcon+18` | `0x00000004` | **`0x00000007`** | `0x00000007` |

⇒ **所有时钟位都真的写进去了**：`icg=0x64646400` 正是 IDF 的实测值、`lpcon=0x7` 对上 IDF 锚点、
`clk_conf1=0x0038E7FF` 也已在位、`rst_conf=0`（不在复位里）。

⇒ **"钩子被调 ≠ 位生效"这个唯一未验证环节，现在验证了：位确实生效。**
⇒ 于是 **"MAC 时钟没开 / 在复位里" 这条被排除**——时钟域配置与 IDF 一致，`MAC_ST` 仍然不清。

⇒ 剩下唯一站得住的候选就是 ADR 早前写的 **`MAC_ST[15:13]` = TX/RX「仍在活动」忙位**：
它要等 blob 的 **stop/deinit 路径真跑起来**才清，而那条路径在 `esp_wifi_start` 之后。

⇒ 顺带一条新差异：`force_on(+08)` 在 after-init 与 before-start 之间从 `0` 变成 `0x1C`
（= bits 2,3,4：`wifi_apb_fo`/`fe_fo`/`fe_apb_fo`），**不含 `clk_wifimac_fo`(bit1) 与 `clk_wifibb_fo`(bit0)**——
这是目前唯一还没和 IDF 对齐的时钟位。

### 补上 LPCON 侧 ICG 位图（`0x2010F020`）——写入生效，但 MAC_ST 仍不清

**新发现的差异**：IDF 的 `modem_clock_hal_set_clock_domain_icg_bitmap()`
（`hal/esp32s31/modem_clock_hal.c:53-64`）对 **SYSCON 侧和 MODEM_LPCON 侧都写**，
而我们只写了 SYSCON 侧（`0x20109C0C = 0x64646400`），**LPCON 侧的位图 `0x2010F020` 一直是 0**。

IDF 的确切值（`modem_clock_impl.c:371-393` + `pmu_types.h:34-36`）：

| 域 | 值 | 位段 |
|---|---|---|
| `LP_APB` | `ICG_NOGATING_ACTIVE \| ICG_NOGATING_MODEM` = `0x6` | `[31:28]` |
| `I2C_MASTER` | `0x6` | `[27:24]` |
| `COEX` | `0x6` | `[23:20]` |
| `WIFIPWR` | `0x6` | `[19:16]` |

（`PMU_HP_ICG_MODEM_CODE_ACTIVE=2` ⇒ `BIT(2)=0x4`；`..._MODEM=1` ⇒ `BIT(1)=0x2`）
⇒ 四域各 `0x6` ⇒ **`0x66660000`**。

写入后：

```text
wifi-init-probe:   lpcon+20_icg=0x66660000     ← 写进去了（原来是 0）
wifi-init-probe: MAC_ST before start = 0x0000e000
wifi-init-probe: calling esp_wifi_start (idle_calls=20, tracing hooks)
panic 0
```

⇒ **位图写入生效**（`0x66660000`），但 `MAC_ST` **仍是 `0xE000`**、start 仍在自旋。

⇒ 这条也是"补上了、但不够"。**`wifipwr` 域的门控图现在对了**，所以"blob 因为 wifipwr 没开才去
force-on"这个解释也站不住（`lpcon+1C_fo` 仍从 `0x4` 变 `0x5`，blob 照样置 bit0）。

⇒ 到这一步，**时钟侧能对的都对了**（SYSCON ICG / clk_conf1 / LPCON clk_conf / LPCON ICG 四张图全在 IDF 值上），
`MAC_ST[15:13]` 依旧不动 ⇒ 剩下唯一方向就是 **IDF init 内部哪一步让这三位归零**（逐 osi 调用点插桩）。

### ★★ 决定性读数：bits 13–15 被**硬件强制置 1**，写什么都回 1

```text
wifi-init-probe: MAC_ST before start = 0x0000e000 (spin mask 0xE000)
wifi-init-probe: after W1C write 0xE000 -> 0x0000e000        # 写 1 不清（不是 W1C）
wifi-init-probe: after write 0x00FF1000 -> 0x00fff000        # ★ 写 0 进去，读回仍是 1
```

`0x00FF1000 | 0xE000 = 0x00FFF000`——**读回值恰好等于"写入值 | 0xE000"**。

⇒ 这三位**既不是 W1C，也不是普通可写位**：它们是**硬件驱动的状态**，
软件写 0 写 1 都改不了，读出来恒为 1。

⇒ 而 IDF start 之后的值是 **`0x00FF1000`**（bits 13–15 = **0**）⇒ **IDF 侧这三位是 0**。

⇒ 所以差异是**硬件状态本身**：IDF 的 init 把 MAC 带到了"这三位为 0"的状态，我们的没有。
时钟四张图（SYSCON ICG / clk_conf1 / LPCON clk_conf / LPCON ICG）**全部已在 IDF 值上**，
所以缺的不是时钟位，而是**某条 MAC 级操作**（`ic_mac_init` / `hal_mac_*` / MAC 复位序列）。

⇒ 唯一还没试的那条：`rstmac=0` 说明 blob 在我们的运行里**从未调用 `_wifi_reset_mac`**，
而 IDF 的 init 会调 —— 下一步要在 **init 期间**（不是 init 之后）补这个复位，
或者让被 b14 挡掉的使能函数（`0x40034d1a`）真正跑起来。

### 判决（负，带范围限定）：在 `0x2f013d30+14/+21` 写 1 **无效**

> [!warning] 范围限定（别写成"b14/b21 门无效"）
> 这两次写入落在**探针那个 blob 上下文** `0x2f013d30` 的 `+14` / `+21`。
> 而闸门函数 `0x2f00254e` 用的是**另一个基址** `0x2f0172e0`；使能函数 `0x40034d94` 附近的
> `lbu 22(s0)`/`lbu 21(s0)` 用的是**它自己的 `s0`**，那个 `s0` 指向哪块**尚未确认**。
> ⇒ 只能表述为「**在 `0x2f013d30+21` 处写 1 无效**」，**不能**表述为「b21 门无效」——
> 否则就是用一个可能没打到位的写入去否掉一个门（本轮反复吃过的亏）。

旧实验（握手还没修好时）得出"置 b14 无效"，但那时 blob 任务根本没被调度，使能函数即使放行也没人推进。
握手成立后原样重跑：

| 实验 | 结果 |
|---|---|
| `b14=1` | `post-init b14=1 b15=1 b16=0 b27=0 **b288=0**`，`MAC_ST=0x0000e000`，`INITWIN` 不变 |
| `b14=1` + `b21=1` | 同上：`b288=0`、`MAC_ST=0x0000e000`、`INITWIN` 不变 |

（板侧读数 `b21=0 b22=0`：按 `0x40034d94` 附近反汇编，`lbu 22(s0)` 需 ==0、`lbu 21(s0)` 需 !=0；
b22 本来满足，b21 补成 1 后**仍没走到** `sb 1,288(s0)`。）

⇒ 两条门都不是解锁点。使能函数 `0x40034d1a` 还有别的前置条件没满足，或者它压根不是清这三位的那条路。

⇒ 已回滚，基线不变（`INITWIN qsend=1 qrecv=2 rstmac=0 clken=1`、`INIT OK`、`MAC_ST=0xE000`、无 panic）。

### ★ 写语义定稿：bits 13–15 只读、只能硬件清；bits 12+16–23 可 R/W

| 位段 | 语义 | 证据 |
|---|---|---|
| **13–15** | **只读状态位**，复位值 `0xE000`，软件写 0/写 1 读回**都是 1** | `after W1C write 0xE000 -> 0x0000e000`（不是 W1C）；`after write 0x00FF1000 -> 0x00fff000`（写 0 也不清） |
| 12, 16–23 | 普通 R/W，命令字写进去能粘住 | 写 `0x00FF1000` 后读回 `0x00fff000` = 写入值 \| `0xE000` |

**重要澄清（别写成"写命令字把忙位置 1"）**：忙位在 **before-start 之前就已经是 `0xE000`**（开机就是），
所以 `0x00fff000` 只是「写进去的位 + 本来就为 1 的 13–15」叠出来的，**并没有新置位**。

⇒ 两条硬结论：
1. **写命令字不触发忙位**——忙位是**复位起就在、一直没被硬件清过**；
2. 与 IDF 的差别就是「**硬件那次清零动作在我们这儿没发生**」（IDF：`0xE000 → 0 → 0x00FF1000`）。

⇒ 因此定位路径只剩一条：**IDF 侧 `wifi_init.c` 每个 osi 调用点后读 `MAC_ST`**，找到哪一步让它归零。
**基建现成**（`examples/wifi/getting_started/station` 插桩 + PROBE/PROBE2/PROBE3 三轮二分都在同一块板跑过），
是在已有装置上加打印，**不是从零的工程投入**（`idf-bootstrap` 那个 stub 与此无关，它只产 bootloader/flash_args）。

### 判决（负）：LPCON ICG 位图挪到 init 期写，**仍不清 MAC_ST**

把 `0x2010F020 = 0x66660000` 从"start 前补写"挪进 `_wifi_clock_enable`（与 IDF 的
`modem_clock_domain_enable` 同序，SYSCON/LPCON 两侧 init 期一起就位）：

```text
wifi-init-probe:   lpcon+20_icg=0x66660000        # after-init 就已经是 0x66660000 ✓
wifi-init-probe: MAC_ST after init = 0x0000e000   # ★ 仍不清
wifi-init-probe: MAC_ST before start = 0x0000e000
panic 0
```

⇒ **时序也对了、位置也对了，`MAC_ST` 依旧不动** ⇒ LPCON ICG 位图不是缺的那一步（保留这个改动，它与 IDF 一致）。

### 更正：IDF 侧对照**不是新工程**，装置早就跑过

**我上一节写错了**——"需要真正的 IDF WiFi app、是主要工程投入"这个判断不成立。

ADR 自己就记着两处：

- **:1993-1997**：把 IDF 的 `examples/wifi/getting_started/station`
  （`idf.py --preview set-target esp32s31` 可直接构建）加一个每秒打印寄存器的小任务，烧到**同一块板**；
  实测输出 `DIAG: MAC_ST=0x00000000 CLK_CONF1=0x00000000 RST_CONF=0x00000000 POWER_ST=0x64646400`。
- **:2930-2933**：把**同一个 example** 插桩（读 `0x20104CAC`/`0x20109C10`/`0x20109C14`/`0x20109C0C`）
  后在同一块板跑。

⇒ 所以下一步是**把那套再跑一遍、多加几个 dump 点**：
拷 example 到临时目录 → `app_main` 里 `esp_wifi_init()` 前后读 `0x20104CAC`（要更细就在
`esp_wifi_init_internal()` 各步之后插读）→ `idf.py --preview set-target esp32s31` → build → flash → 抓日志。

⇒ `idf-bootstrap` 的 `app_main` 是 stub **不影响**它——那个 stub 只负责给链接一个入口、
产出 bootloader/分区表/flash_args；IDF 侧参考工程是 example 本身。

> [!warning] 跑之前先对齐两件事
> ① **同一份 sdkconfig / 分区表**（WiFi blob 版本与 NVS 布局要一致，否则对比不成立）；
> ② 读的是**同一个地址 `0x20104CAC`**，别用 IDF 的寄存器别名。

### ★★★ 决定性静态结论：**全部 133 个 blob 目标文件里没有任何一处写 `MAC_ST` bits 13–15**

把 `components/esp_wifi/lib/esp32s31/*.a` 全部解开（`ar x`，133 个 `.o`），逐个反汇编搜 `20104cac`：

| 目标文件 | 命中 | 内容 |
|---|---|---|
| `hal_mac.o` | 5 | 掩码 `0xFF0…` / `0xFF1…` 等（bits 16–23 那一组） |
| `pm.o` | 4 | `hal_pm_unblock_txq` **清 bits 17–19**（`and 0xFFF1FFFF`）；另三处 **置 bits 17–19**（`or 0xE0000`） |
| `ieee80211_api.o` | 1 | **只读**（在一条诊断日志路径里，`li a1,64` / `li a0,6`） |

⇒ **没有任何一处 `sw` 到 `MAC_ST` 的 bits 13–15。** 软件（blob 侧）从不写这三位。

⇒ 加上此前已知的：**我们写 0 清不掉、写 1 也不清**（只读硬件状态）⇒ 这三位**只可能由硬件清零**。

⇒ 于是"IDF 侧 init 里哪一步清掉它"这个问法要改：**IDF 那边也没有软件去写它**，
它一定是**硬件在某个操作完成后自己清的**。⇒ 差别的根源不在"少写了一个寄存器"，
而在**我们没执行到那个能让硬件完成动作的序列**。

### 同时修正：`esp_wifi_init_internal` 无法按源码插桩

它定义在 **`libnet80211.a:ieee80211_api.o`**（二进制 blob，`nm` 确认 `T esp_wifi_init_internal`），
IDF 源码里**只有声明**（`include/esp_private/wifi.h:437`）。
⇒ "在 `esp_wifi_init_internal()` 各步之后插读"这条路**做不到**（没有源码）。
可行的替代：① 反汇编那个 `.o`（本轮已做）；② 在 IDF 侧的**源码函数**上插桩
（`esp_phy_enable`、`esp_clock_*` 等）；③ 调试口对 `0x20104CAC` 设写监视点。

### 由静态扫描得出的**方向性修正**（并避免了一次重复实验）

上面证明"blob 软件从不写 bits 13–15"。再往下扫一步：

| 寄存器 | 哪些 blob 目标文件碰它 |
|---|---|
| `0x20100800` | **无** |
| `0x20109C18` | **无** |
| `0x20109C10` | **无** |

⇒ 这三处**一个 blob 目标文件都不碰** ⇒ 那条路走的是 **ROM 代码**（blob 调 ROM 函数，ROM 再写这些寄存器）。

⇒ 结合 ADR 早前那条结论（`:1607`）：**ROM 的 `ic_mac_init()`（`0x2f800d9c`）已经试过并判负**
（调用前后 `is_lmac_idle` 仍 1、`mac` 仍 `0x0000e000`、自旋照旧）。

> [!warning] 差点重复实验
> 本轮本来准备"直接调 `ic_mac_init` 试试"——查候选清单才发现**早就做过**。
> 这就是那条纪律存在的理由：**改寄存器/调 ROM 函数前先查 ADR 的候选清单实验表**。

⇒ 到此，**所有零成本/低成本的静态与板侧路径都已走完**：

| 已否 | 证据 |
|---|---|
| 写 `MAC_ST`（0 或 1） | 只读硬件状态位 |
| `rst_wifimac` / `rst_wifibb` 脉冲 | 20 µs 宽仍无变化 |
| 时钟四张图（SYSCON ICG / clk_conf1 / LPCON clk_conf / LPCON ICG） | 全部已在 IDF 值上 |
| `b14` / `b21` 置 1 | `b288` 仍 0（且写入位置未必对） |
| ROM `ic_mac_init` | 早前已判负 |
| 从自旋桩让出 | 记账模型不支持从 main 任意点切入 |
| 找 blob 里写 bits 13–15 的代码 | **不存在** |

⇒ **剩下的唯一手段**：在 IDF 侧用调试探针对 `0x20104CAC` 设**写监视点**，
直接抓"哪条 PC 让它变 0"。这需要 JTAG 探针（当前只有 `/dev/ttyUSB0` 串口，没有 openocd）。
⇒ 没有探针时的次优：在 IDF 侧**源码函数**（`esp_phy_enable`、`esp_clock_*` 等）上插桩，
或在 IDF 侧起一个高优先级任务轮询 `MAC_ST` 拿到时间点，再与串口日志对齐。

### 合并校准：今天的结论**与 ADR `:1425-1427` / `:1567` / `:1689` 的既有结论是同一件事**

> [!warning] 先读这段，别把今天的推导当成新结论
> ADR **`:1425-1427`** 早就写着：「`esp_wifi_start` 的 MAC deinit 在等 TX/RX 引擎的硬件忙位清零；
> 这些位**复位即为 1、软件不可写**，只有**真正完成 MAC/PHY 上电与初始化（DMA 环 + RF 前端）**才会清。
> 我们的裸机探针没有真实 PHY 收发链路，所以永远不清——这不是宿主钩子能修的问题。」
> **`:1567`** 再说一遍：「唯一能让它们改变的是真实的 MAC/PHY 上电初始化（DMA 环 + RF 前端），而不是任何宿主钩子。」
> **`:1689`** 给了现成判据：**`hal_mac_is_dma_enable()`（ROM `0x2f800d4c`，无参）= `0`** ⇒ **DMA 环没建**。

⇒ 今天这条「bits 13–15 是只读硬件状态、全库无人写、只可能由硬件清零」**正是上面那条结论的独立验证**
（静态侧：133 个 `.o` 里没有任何一处写这三位；板侧：写 0/写 1 都读回 1）。

⇒ 所以本 ADR 早前那条"唯一候选 = 等 stop/deinit"（写在 `esp_wifi_start` 之后）**是弱化的重推导，且有逻辑洞**：
IDF 在 **start 之前**这三位就已经是 0，而那时板子还没发过任何 TX/RX ⇒ 不存在"等收发停止"的阶段。
**正确的框架是**：IDF 的 init 期间完成了 **MAC/PHY 上电初始化（DMA 环 + RF 前端）**，我们没做。

### 更正（并再更正一次）：openocd 与 target cfg 都在，但**传输通道不在**

第一次写"没有 openocd"——**错**；第二次写"openocd 有 ⇒ JTAG 可行"——**只对一半**。实测：

| 项 | 状态 |
|---|---|
| `openocd` 二进制 | ✓ `~/.espressif/tools/openocd-esp32/v0.12.0-esp32-20260703/openocd-esp32/bin/openocd` |
| `target/esp32s31.cfg` | ✓ 存在 |
| `interface/esp_usb_jtag.cfg` | ✓ 存在 |
| **`/dev/ttyUSB0` 是什么** | **CP2102N USB-to-UART**（`ID_VENDOR=Silicon_Labs` `ID_VENDOR_ID=10c4` `ID_MODEL_ID=ea60`）——**不是**芯片内置 USB-JTAG |
| USB-JTAG 设备（VID `303a`） | **未枚举**（`lsusb` 无 303a） |

⇒ **结论**：工具与配置齐全，但**没有 JTAG 传输通道**——板子上的 `/dev/ttyUSB0` 是 UART 桥，
芯片的 USB-JTAG 没有接出来/没插。⇒ 写监视点这条路**缺硬件**（需要 ESP-Prog 或把板子的 USB-JTAG 口接上），
不是"缺软件"。

⇒ 若将来接上，attach 顺序不能省：先 `break esp_wifi_init` → continue 到断点 →
再 `awatch *0x20104cac` → continue（否则只能抓到 init 之后的写）。

### 下一步（两条并行，主次明确）

| 线 | 内容 | 判据 / 成本 |
|---|---|---|
| **主线：IDF 侧 osi adapter 插桩** | 在 IDF 的 **osi adapter 低频函数**（`wifi_reset_mac` / `wifi_clock_enable` / `wifi_clock_disable` / `wifi_on`）各加一行 `MAC_ST` printf；blob 在 `esp_wifi_init_internal` 里按序调它们，**第一个打出 0 的函数名就是清位者**。⚠️ 别给 malloc/timer/queue 这类高频钩子加打印。基建现成（PROBE/PROBE2/PROBE3 三轮先例 + `/tmp/idf-station-probe`） | 改完 `idf.py build` + flash；测完 `git checkout` 还原 IDF 树 |
| **备选：JTAG 写监视点** | `openocd -f interface/esp_usb_jtag.cfg -f target/esp32s31.cfg` → gdb `break esp_wifi_init` → `awatch *0x20104cac` | 直接给出 PC；需探针硬件 |
| **并行：MAC 使能链实现** | 补 **DMA 环 + RF 前端**的上电初始化（ADR `:1689` 的 `hal_mac_is_dma_enable()` 是现成状态位判据，现在读 0） | 与上面互证：静态扫描证明"缺的不是寄存器写，是上电初始化动作" |

> [!note] 实操提醒
> ① 烧 IDF app 会覆盖板上的 Zig 探针镜像 ⇒ 实验后把 Zig 探针刷回；
> ② 同板对比前**两边都擦 NVS 分区**（我们固件在板上留过键值，`nvs get_blob calls=15` 就是痕迹）；
> ③ 每条 dump 带**递增序号 + 时间戳**，缺号能看出流程没走到那一步，避免把"没进 init"误读成"init 没清零"。

### ★★★★★ 定位成功：**`wifi_clock_enable` 就是清位者**（IDF 侧 osi adapter 插桩）

按"主线"做法：在 IDF 的 S31 osi adapter（`components/esp_wifi/esp32s31/esp_adapter.c`）三个低频 wrapper
里各加两行 `MAC_ST` printf，用现成的 `/tmp/idf-station-probe`（station example + PROBE 插桩）重建、烧板、抓串口。

**结果（`/tmp/idf-station-run.log`）**：

```text
PROBE mac_st before_init=0x0000e000 rst=0x00000000 clk1=0x00000000 icg=0x00000000
PROBE MAC_ST before clock_en=0x0000e000
PROBE MAC_ST after  clock_en=0x00000000     ← ★★★ 就在这里清的
PROBE MAC_ST before clock_dis=0x00000000
PROBE MAC_ST after  clock_dis=0x00000000
PROBE mac_st after_init=0x00000000
PROBE mac_st before_start=0x00000000
PROBE MAC_ST before reset_mac=0x00000000
PROBE MAC_ST after  reset_mac=0x00000000
PROBE MAC_ST before clock_dis=0x00ff1000
PROBE mac_st after_start=0x00ff1000
```

⇒ **`MAC_ST` 从 `0xE000` 变 `0` 的唯一一步，是 `wifi_clock_enable_wrapper()` → `wifi_module_enable()`。**
⇒ `reset_mac` 之后**没变**（仍是 0）⇒ **`rst_wifimac` 与这三位无关**，这也解释了为什么我们手动脉冲一直无效。
⇒ `clock_disable` 也不改它（0 → 0）。

**IDF 的调用链**（`periph_ctrl.c:141`）：

```c
void wifi_module_enable(void) { modem_clock_module_enable(PERIPH_WIFI_MODULE); }
  → modem_clock_module_icg_map_init_all();            // ICG 位图（两侧）
  → modem_clock_device_control(deps, true);
      → 每个 device 的 configure() → 时钟域使能 + 复位序列
```

⇒ **我们的 `shellWifiClockEnable` 只手写了三处寄存器（ICG / CLK_CONF1 / LPCON clk_conf），
完全没走这条 `configure()` 链** ⇒ 这就是缺的那一步，而且**不是"少写一个寄存器"，是少了一整条 device 配置序列**。

⇒ 下一步：读 S31 的 `modem_clock_impl` device 表里的 `configure`，把它做的寄存器动作逐条复刻进
`shellWifiClockEnable`（或直接调 ROM/等价函数）。

### 判决（负）：照 IDF 的**逐设备顺序**重写 `shellWifiClockEnable`，**仍不清**

按 `WIFI_CLOCK_DEPS` 的顺序重写（`clk_wifimac_en` → `rst_wifibb` 脉冲 → BB 时钟组 OR → `clk_wifibb_80x1_en`
→ 其余位整组 OR）：

```text
wifi-init-probe: MAC_ST after init = 0x0000e000     # 仍不清
wifi-init-probe:   clk_conf1(+14)=0x0038e7ff        # 与之前完全一致
panic 0
```

⇒ **顺序不是关键**。`clk_conf1` 的终值与 IDF 相同（`0x0038e7ff`），`MAC_ST` 依旧 `0xE000`。

⇒ 说明 IDF 的 `wifi_module_enable()` 里**还有我们没复刻的东西**。按源码，它的完整路径是：

```c
modem_clock_module_enable(PERIPH_WIFI_MODULE)
  ├─ modem_clock_module_icg_map_init_all()        // 两侧 ICG 图（我们已写）
  └─ modem_clock_device_control(WIFI_CLOCK_DEPS, true)
       WIFI_MAC, WIFI_APB, WIFI_BB, WIFI_BB_44M, COEXIST, WIFI_BB_80X1, SOC_PLL_SOURCE_CG
```

⇒ **7 个 device 里我们只复刻了 3 个（MAC / BB / BB_80X1）**，
`WIFI_APB`、`WIFI_BB_44M`、`COEXIST`、**`SOC_PLL_SOURCE_CG`** 这 4 个没写。
其中 **`SOC_PLL_SOURCE_CG`（PLL 源时钟门）** 是最可疑的一个——没有 PLL 源，MAC 的状态机当然不动。

⇒ 下一步：把这 4 个 device 的 `modem_syscon_ll_*` 写操作也复刻进来
（`modem_clock_impl.c` 里各自的 `configure()` 就是一行 `modem_syscon_ll_enable_*`，逐个查 LL 头文件即可）。

### 判决（负）：补齐 7 个时钟 device（含从未写过的 `0x205871E0`）**仍不清**

补上最后 4 个 device 中最关键的一个 —— `SOC_PLL_SOURCE_CG`：

```c
// IDF hal/esp32s31/modem_clock_hal.c:122-126
modem_clock_hal_enable_soc_pll_source_cg()
    HP_SYS_CLKRST.modem_conf.val = enable ? 0x3d : 0x25;
// DR_REG_HP_SYS_CLKRST_BASE = 0x20587000   (soc/esp32s31/register/soc/reg_base.h:79)
// HP_SYS_CLKRST_MODEM_CONF_REG = base + 0x1E0  ⇒  0x205871E0
```

⇒ **`0x205871E0 = 0x3D` 是一个我们从来没写过的寄存器**（blob 侧也不写它，见前面的 133 文件扫描）。

写进去之后：

```text
wifi-init-probe: MAC_ST after init = 0x0000e000     # 仍不清
panic 0
```

⇒ **把 7 个 device 全复刻了，仍然不清** ⇒ IDF 的 `wifi_module_enable()` 里**还有别的东西**
（源码里那条链已经走完：`icg_map_init_all` + `device_control(7 devices)`，所以剩下的只能是
`configure()` 内部还有 ROM 调用，或 `enable` 之后紧跟的 ROM 侧初始化）。

⇒ 但**关键定位已经拿到**：清位动作**只发生在 `wifi_clock_enable` 这一步**，
`reset_mac` / `clock_disable` 都不改它。下一步只需把 `wifi_module_enable()` 的**汇编**看一遍
（它在 IDF 里是源码，编出来的 `libesp_hw_support.a` 里就有），逐条对齐我们缺的调用。

### `wifi_module_enable` 的汇编：**只是 `li a0,5` + 一次调用**

```asm
00000000 <wifi_module_enable>:
   0: addi sp,sp,-16
   2: sw   ra,12(sp)
   4: li   a0,5                    # PERIPH_WIFI_MODULE
   6: auipc ra,0x0
   a: jalr ra                      # → modem_clock_module_enable(5)
   e: lw   ra,12(sp)
  10: addi sp,sp,16
  12: ret
```

（`libesp_hw_support.a` 里就是这两条。）

⇒ 所以整条链就是 **`modem_clock_module_enable(5)`**，其内部只有两件事：

1. `modem_clock_module_icg_map_init_all()` —— 对**所有 domain** 做
   `set(domain, icg_config[domain] | get(domain))`（两侧 ICG 图）；
2. `modem_clock_device_control(WIFI_CLOCK_DEPS, true)` —— 7 个 device 各 `configure()`。

⇒ 我们已复刻 2 的全部 7 个 device（含 `0x205871E0=0x3D`），**仍不清** ⇒ 剩下的差异只能在
**第 1 步的逐 domain ICG 值**上（IDF 是"逐 domain 取当前值再 OR"，我们是一次性写死两个常数）。

⇒ 下一步（精确）：把 `modem_clock_hal_get/set_clock_domain_icg_bitmap` 对**每个 domain** 的寄存器与位段查出来，
按"**先读当前值、再 OR 配置值**"的方式逐 domain 写——而不是写常数 `0x64646400` / `0x66660000`。

### ★ 找到机制差异：IDF 写 **ICG 的每个子字段**，我们是**整寄存器覆盖**

`0x20109C0C`（`clk_conf_power_st`）是**多个 ICG 子字段**共用的寄存器：

```c
// hal/esp32s31/include/hal/modem_syscon_ll.h:251-253
modem_syscon_ll_set_wifi_icg_bitmap(hw, bitmap)
    hw->clk_conf_power_st.clk_wifi_st_map = bitmap;     // ← 只写"wifi"那一段
// :275-277
modem_syscon_ll_set_modem_apb_icg_bitmap(hw, bitmap)
    hw->clk_conf_power_st.clk_modem_apb_st_map = bitmap; // ← 只写"modem_apb"那一段
```

⇒ **IDF 是逐字段 RMW**：`set(domain, icg_config[domain] | get(domain))`，
**每个 domain 只改自己那一段**。

⇒ **我们是 `icg.* = 0x6464_6400` —— 整寄存器覆盖**，把其他子字段（`clk_modem_apb_st_map`、
`clk_modem_periph_st_map`、`clk_bt_st_map`、`clk_modem_fe_st_map` …）**一起写成了常数里撞上的值**。

⇒ 这就是"我们写进去的值看起来对、硬件却不动"的机制性解释：单个字段的值可能没错，
但**其他字段被我们覆盖成了错误的数**，整个域的 ICG 握手就配不起来。

⇒ 下一步（精确可做）：把 `modem_syscon_ll_set_*_icg_bitmap` 的**字段位段**逐个查出来，
按 **"读该字段 → 与配置值 OR → 只写回该字段"** 的方式重写 `shellWifiClockEnable` 的 ICG 部分，
**不要**再整寄存器赋值。LPCON 侧（`0x2010F020`）同理。

### 新观测：**blob 自己会把 ICG 写回 `0x64646400`**（我们的值被覆盖）

按 `modem_syscon_struct.h` 的实测布局重算（**注意：不是 4 位 reserved，是 8 位**）：

```c
// components/soc/esp32s31/include/modem/modem_syscon_struct.h:78-89
clk_conf_power_st:
    reserved0              : 8    // [7:0]
    clk_zb_st_map          : 4    // [11:8]
    clk_fe_st_map          : 4    // [15:12]
    clk_bt_st_map          : 4    // [19:16]
    clk_wifi_st_map        : 4    // [23:20]
    clk_modem_peri_st_map  : 4    // [27:24]
    clk_modem_apb_st_map   : 4    // [31:28]
```

IDF 逐域值：FE=`0x6` / BT=`0x4` / WIFI=`0x6` / PERIPH=`0x4` / APB=`0x6`，**zb 域 IDF 不写 ⇒ 0**
⇒ 正确整寄存器值 = **`0x64646000`**（我们原来的 `0x64646400` 唯一差别是 `clk_zb_st_map` 写成了 4）。

写进去之后读回：

```text
wifi-init-probe:   icg(+0C)=0x64646400      # ★ 不是我们写的 0x64646000
```

⇒ **有别人把它改回 `0x64646400`** —— 只可能是 **blob 自己的 `_wifi_clock_enable` 调用链之外**还有一处写，
或 blob 在 init 里直接写了这个寄存器。

⇒ 所以"我们写的 ICG 值错"这条**不成立**（我们的值活不过一个 init 窗口）。
⇒ 这也解释了为什么改这个常量一直没效果：**写了就会被覆盖**。

⇒ 下一步：在 `shellWifiClockEnable` 之后再 dump 一次 ICG，定位是"我们的写没生效"还是"之后被覆盖"，
然后用**调用时序**（而不是改常量）去对——IDF 的 `wifi_module_enable()` 之所以能清位，
是因为它在**正确的时刻**（blob 还没自己配 ICG 之前）做完了整条链。

### ⚠ 撤回我自己的错误：**不是 blob 写回，是我改错了函数**

上一节写"blob 把 ICG 写回 `0x64646400`"——**错**。真相：

```text
grep -n "icg\.\* = " components/wifi-blobs/src/osi_impl.zig
1082:    icg.* = 0x6464_6400;     ← 另一函数（没动）
1185:    icg.* = 0x6464_6000;     ← 真正的 shellWifiClockEnable（我上一轮改到了 1082 那处）
```

⇒ 上一轮"改值"改到了**另一个函数**，`shellWifiClockEnable` 里仍是旧值 ⇒ 板上读回 `0x64646400` **是我们自己写的**，
不是 blob 覆盖。**"blob 会写回"这条撤回。**

改对之后：

```text
wifi-init-probe:   icg(+0C)=0x64646000      ← 写进去了，而且粘住
wifi-init-probe: MAC_ST after init = 0x0000e000   # 仍不清
panic 0
```

⇒ **ICG 内容现在与 IDF 完全一致（`0x64646000`），`MAC_ST` 依旧 `0xE000`** ⇒ **ICG 内容不是分歧因子**。

⇒ 附带一条推论：blob 二进制两边**是同一份**，它对 ICG 的行为两边一致 ⇒ **ICG 相关的一切都不是两边分歧的来源**
（IDF 的 post-init ICG 同样是这个值也能 start 成功）。

### ★★★★★ IDF 侧 `wifi_clock_enable` 的**八寄存器 before/after 快照**（决定性 diff 表）

在 IDF 的 `wifi_clock_enable_wrapper` 里加 `dump_clk("BEFORE"/"AFTER ")`（八寄存器 + `0x205871E0` + `MAC_ST` + `dma`），
重编 station probe、烧板、抓串口。**第一次 enable**：

| 寄存器 | IDF BEFORE | IDF AFTER | 我们的值 |
|---|---|---|---|
| `c04` clk_conf | `0x00201002` | `0x00201002` | `0x00201002` ✓ |
| `c08` force_on | `0x00000000` | `0x00000000` | init 后 **`0x1C`**（blob 在 init→start 之间写） |
| `c0C` ICG | `0x00000000` | **`0x64646400`** | `0x64646000`（按布局正确，差 zb nibble） |
| `c10` rst_conf | `0x00000000` | `0x00000000` | `0x0` ✓ |
| `c14` clk_conf1 | `0x00000000` | **`0x000007FF`** | 现改为 `0x000007FF` ✓（原来 `0x0038E7FF`） |
| `f018` LPCON clk_conf | `0x00000001` | **`0x00000003`** | **`0x00000004`**（写 `lb\|3` 后读回仍是 4） |
| `f01c` LPCON force_on | `0x00000004` | `0x00000004` | `0x4` ✓ |
| `f020` LPCON ICG | `0x00000000` | **`0x66660000`** | `0x66660000` ✓ |
| `205871E0` | `0x00000025` | **`0x0000003D`** | `0x3D`（我们写） |
| **`MAC_ST`** | `0x0000E000` | **`0x00000000`** | **仍 `0xE000`** |
| `dma`（`0x2f800d4c`） | `0` | **`0`** | `0` |

**三条硬结论**：

1. **`dma` 在 IDF 的 enable 前后都是 `0`** ⇒ **"DMA 环没建"不是这次清位的原因**（ADR 早前把忙位归因于 DMA/RF 上电，这条要收窄）。
2. **IDF 的 `clk_conf1` 只写 `0x7FF`**（不是我们原来的 `0x38E7FF`，多 12 位）；`LPCON+0x18` 只写 `0x3`（我们写 `0x7`）。
   ⇒ 我们的**多写位**已按 IDF 收窄（`clk_conf1` 现在 `0x7FF`）。
3. 收窄后 **`MAC_ST` 仍 `0xE000`** ⇒ 差别不在 `clk_conf1` 的位宽上，而在 **`f018` 没到 `0x3`**
   （我们写 `lb|0x3` 读回仍是 `0x4`）+ 可能还有 enable 内部我们没复刻的动作。

⇒ 下一步（唯一剩下的可执行点）：查清 **`LPCON+0x18` 为什么写不进 `0x3`**（是写保护/字段布局，还是写后被覆盖），
把它对齐到 `0x3` 再看 `MAC_ST`。`f018` 的字段是 `clk_wifipwr_fo`/`clk_coex_fo`/`clk_lp_timer_fo`（bits 0-2）。

### ★★★ 全部时钟寄存器对齐 IDF 后，`MAC_ST` 仍不清 ⇒ **清位不是这些寄存器写造成的**

两处实现 bug 被找出并修好（都是我自己编辑时改错的）：

1. **ICG 改到了另一个函数**（第 1090 行 vs 第 1187 行）⇒ `shellWifiClockEnable` 一直写旧值；
2. **`LPCON clk_conf`（`0x2010F018`）的写入整段被我删掉了** ⇒ 读回一直是 `0x4`。

修好并按 IDF 实测值对齐之后：

| 寄存器 | IDF AFTER | 我们（对齐后） |
|---|---|---|
| `clk_conf1` | `0x000007FF` | **`0x000007FF`** ✓ |
| `LPCON+0x18` | `0x00000003` | **`0x00000003`** ✓ |
| `ICG (0xC)` | `0x64646400` | `0x64646000`（差 zb nibble，按布局我们是"更对"的那个） |
| `LPCON ICG` | `0x66660000` | `0x66660000` ✓ |
| `205871E0` | `0x0000003D` | `0x0000003D` ✓ |
| `force_on` | `0x0`（enable 时） | `0x1C`（blob 在 init→start 写） |
| **`MAC_ST`** | **`0x00000000`** | **仍 `0xE000`** |

⇒ **八格能对的全部对上了，`MAC_ST` 依旧不动。**

⇒ **硬结论：清位不是上面任何一次时钟寄存器写造成的。** 它只能来自 `wifi_module_enable()` 里
**我们没复刻的别的动作**——按源码，那条链已经没有更多寄存器写了，所以剩下的只能是：
① `check_enable` 的**读回校验**（IDF 是 `ESP_ERROR_CHECK`，读回不对会 abort；我们没有这层）；
② `configure()` 内部调到的 **ROM 函数**；
③ 或者"清位"本身是**硬件对整条序列的时序响应**（不是单次写）。

⇒ 下一步（唯一）：在 IDF 侧把 `wifi_module_enable()` 的**调用轨迹**抓下来
（给 `modem_clock_module_enable` / `modem_clock_device_control` / 各 `configure` 各加一行打点），
看它实际执行了哪些函数——寄存器已经对齐，剩下的差异只能在**调用**上。

### 判决（负）：在 `modem_clock_device_control` 里 printf ⇒ **重启循环**

按"抓调用轨迹"的思路给 `modem_clock_module_enable` / `modem_clock_device_control` / `configure` 各加 `TRACE` printf：
重新构建 + 烧板 + 抓串口后：

```text
TRACE enter modem_clock_module_enable(5)
TRACE deps=0x000003ec icg_init_done
（"TRACE device_control done" 0 条、  "TRACE configure dev=" 0 条）
（"PROBE mac_st before_init" 出现 24 次 ⇒ 板子一直在重启）
```

⇒ **`device_control` 内部（持临界锁 + IRAM 上下文）的 printf 直接把板子搞崩，进入重启循环。**

⇒ 有用的半截信息：**`deps = 0x000003EC`** —— 正是 `WIFI_CLOCK_DEPS` 的位图（7 个 device），
且 `icg_map_init_all` 那一步是能跑完的。

⇒ **结论：这条路要用"先记录、后打印"的非打印环形缓冲**（在 `device_control` 里只写一个静态数组，
等 `esp_wifi_init()` 返回后再统一打出来），不能在里面 printf。

⇒ IDF 树已 `git checkout` 还原；板子已刷回 Zig 探针（`INITWIN qsend=1 qrecv=2 clken=1` / `INIT OK` /
`calling esp_wifi_start` 均正常）。

### 下一步的具体配方：**非打印环形缓冲**抓 `wifi_module_enable()` 调用轨迹

printf 在 `device_control` 里会崩（持锁 + IRAM）⇒ 改成"只记录、后打印"：

```c
// 放在 modem_clock.c 顶部（不要 IRAM_ATTR，普通 DRAM 即可）
static volatile uint8_t  tr_idx;
static volatile uint8_t  tr_dev[64];
static volatile uint8_t  tr_en[64];
static volatile uint32_t tr_mac[64];

// modem_clock_device_control 的循环里，替换 configure 调用处：
if (tr_idx < 64) {
    tr_dev[tr_idx] = (uint8_t)i;
    tr_en[tr_idx]  = (uint8_t)enable;
    tr_mac[tr_idx] = *(volatile uint32_t *)0x20104CAC;   // 每次 configure 前
    tr_idx++;
}
ctx->dev->configure(ctx, i, enable, config_wrapper);
// 循环外再记一条"全部完成"的哨兵
```

然后在 station 的 `app_main` 里、**`esp_wifi_init()` 返回之后**统一打印：

```c
for (int k = 0; k < tr_idx; k++)
    printf("TRC %d dev=%d en=%d mac_before=%08x\n", k, tr_dev[k], tr_en[k], tr_mac[k]);
```

⇒ 这样能拿到"**每一个 device 的 configure 之前 MAC_ST 是多少**"，
**第一个 `mac_before == 0` 的 device 就是清位者**（或者若全是 0xE000、只有 enable 返回后才是 0，
说明清位发生在 `device_control` 之后、enable 收尾处）。

⇒ 注意：`modem_clock.c` 是 IDF 源码，改完**测完必须 `git checkout` 还原**（本轮已证实 printf 版本会导致重启循环）。

### ★★★ 整块 dump 的结论 + 一个**方法学发现**（探针自己的实验在污染时钟寄存器）

**IDF 的 `wifi_module_enable()` 整块净变更只有 3 个寄存器**（`0x20109C00` 起 13 字 + `0x205871E0` 的 BEFORE/AFTER）：

| 偏移 | BEFORE | AFTER |
|---|---|---|
| `0x00` | `0x00000100` | `0x00000100` |
| `0x04` | `0x00201002` | `0x00201002` |
| `0x08` | `0x0` | `0x0` |
| **`0x0C` ICG** | `0x0` | **`0x64646400`** |
| `0x10` rst_conf | `0x0` | `0x0` |
| **`0x14` clk_conf1** | `0x0` | **`0x000007FF`** |
| `0x18` / `0x1C` | `0x0` | `0x0` |
| `0x20` | `0x00002070` | `0x00002070` |
| `0x24` / `0x28` | `0x0` | `0x0` |
| `0x2C` | `0x00000044` | `0x00000044` |
| `0x30` | `0x02508080` | `0x02508080` |
| **`hp1e0`** | `0x25` | **`0x3D`** |
| **`MAC_ST`** | `0xE000` | **`0`** |

⇒ **只有上面标粗的三个寄存器变化，而这三个我们早就都写了** ⇒ **内容层面已完全对齐，`MAC_ST` 仍不清。**

**方法学发现（重要）**：我们自己的 `before-start` 读数是**被探针自己的 PHY 实验污染的**：

```text
CLKDMP[after-init]  icg=0x64646000  clk_conf1=0x000007ff  hp1e0=0x3d   ← 与 IDF 一致 ✓
CLKDMP[before-start] icg=0x64646400  clk_conf1=0x0038e7ff  hp1e0=0x3d   ← 被改回去了
```

`init_probe.zig:601` 有一段 **PHY bring-up 实验**：`conf1.* = before | bits;`（PHY/FE 组位）
—— 它在 init 之后又把 `clk_conf1` 写回 `0x38e7ff`。`icg` 的 `0x64646400` 同理来自别的探针实验。

⇒ **所以"我们的 `before-start` 与 IDF 不同"这个判读是错的**：`after-init` 才是可比时点，那里三项已全对。

⇒ 下一步：把 `before-start` 那次读数的**探针自身写入**去掉（或把 PHY 实验段挪到 start 之后），
让 `before-start` 保持 `after-init` 的值，再看 start 是否还能自旋——**这才是干净的对照**。

### 更正上一条：那个 `0x38e7ff` 是**故意**写的，不是"污染"

我上一节把它叫"探针自己的实验污染"——**不准确**。`init_probe.zig:69` 写着：

```zig
const probe_clock_at_init = true; // 实测必须 true：关掉会让 FE/BB 时钟写序列 stall
```

⇒ 那段 `conf1.* = before | bits`（PHY/FE 组位，终值 `0x38e7ff`）是**FE/BB 时钟写序列所必需的**，
关掉它会让序列 stall。所以它是**设计的一部分**，不是误写。

⇒ 于是两条都成立、不矛盾：

| 时点 | `clk_conf1` | 谁写的 | 意义 |
|---|---|---|---|
| `after-init` | `0x000007FF` | 我们的 `_wifi_clock_enable`（已对齐 IDF） | 与 IDF 的 enable **逐位相同** ✓ |
| `before-start` | `0x0038E7FF` | 探针的 PHY/FE 时钟序列（**故意**） | 裸机没有 IDF 的 `esp_phy_enable`，只能自己补 |

⇒ **"我们的寄存器与 IDF 不同"这个判读要按行读**：`after-init` 那一行**完全相同**；
`before-start` 的差异来自"裸机得自己做 PHY 时钟"这件事本身，不是配置错误。

⇒ 所以"内容层面已对齐但 `MAC_ST` 仍不清"这条结论**成立**，下一步只能是：
① 让 `before-start` 保持 `after-init` 的值（把 PHY 段挪到 start 之后）做**干净对照**；
② 或抓 `wifi_module_enable()` 的**调用轨迹**（环形缓冲版）。

### ★★★★★ 环形缓冲轨迹：**清位的正是 `dev=7` = `MODEM_CLOCK_WIFI_MAC` 的 `configure(true)`**

用非打印环形缓冲（`device_control` 里只写数组、不 printf）抓到 14 条记录：

```text
TRC dump n=14 done=1
TRC 0 dev=2 en=1 mac_b=0000e000 mac_a=0000e000
TRC 1 dev=3 en=1 mac_b=0000e000 mac_a=0000e000
TRC 2 dev=5 en=1 mac_b=0000e000 mac_a=0000e000
TRC 3 dev=6 en=1 mac_b=0000e000 mac_a=0000e000
TRC 4 dev=7 en=1 mac_b=0000e000 mac_a=00000000   ← ★ 就是这一步清的
TRC 5 dev=8 en=1 mac_b=00000000 mac_a=00000000
TRC 6 dev=9 en=1 mac_b=00000000 mac_a=00000000
TRC 7..13 dev=2,3,5,6,7,8,9 en=0 全 0（disable 路径）
```

设备编号对应 `modem_clock_device_t`（`modem_clock_impl.h:48-70`）：

| idx | 枚举 | configure 做的事 |
|---|---|---|
| 2 | `SOC_PLL_SOURCE_CG` | `HP_SYS_CLKRST.modem_conf = 0x3D` |
| 3 | `COEXIST` | LPCON ICG 位图 |
| 5 | `WIFI_APB` | `clk_conf1` 位 |
| 6 | `WIFI_BB_44M` | `clk_conf1` 位 |
| **7** | **`WIFI_MAC`** | **`clk_conf1.clk_wifimac_en = 1`（bit 0）** |
| 8 | `WIFI_BB` | `rst_wifibb` 脉冲 + BB 时钟组 |
| 9 | `WIFI_BB_80X1` | `clk_conf1` 位 |

⇒ **清位动作 = 写 `clk_conf1` 的 bit 0（`clk_wifimac_en`）**，而已知 `clk_conf1` 的整块终值是 `0x7FF`
⇒ 也就是说：**`clk_conf1` 从 `0` 变成含 bit0 的那一刻**，`MAC_ST` 的 bits 13–15 被硬件清掉。

⇒ **而这一步我们也在写**（`conf1.* = conf1.* | (1 << 0);`，且写前 `clk_conf1` 也是 `0`）——
但我们的 `MAC_ST` 不清 ⇒ **差别只能在"写的时机"上**：
IDF 是在 `device_control` 的**设备循环里第 5 个**写 bit0（前面已写过 SOC_PLL/COEXIST/WIFI_APB/WIFI_BB_44M），
**我们则把它放在自己序列的第一步**。

⇒ 下一步（明确且可做）：把 `shellWifiClockEnable` 的写序**严格改成 IDF 的 device 循环顺序**
（SOC_PLL → COEXIST(LPCON ICG) → WIFI_APB → WIFI_BB_44M → **WIFI_MAC(bit0)** → WIFI_BB(rst+组) → WIFI_BB_80X1），
让写 bit0 的那一刻**前面那四个已经写过**，再看 `MAC_ST` 是否清零。

### 判决（负）：**严格照 IDF 的 device 顺序**重写，`MAC_ST` 仍不清

按轨迹把写序改成 `SOC_PLL → COEXIST → WIFI_APB → WIFI_BB_44M → **WIFI_MAC(bit0)** → WIFI_BB(rst+组) → WIFI_BB_80X1`
（`clk_conf1` 从 `0` 开始，bit0 是第 5 个写入的位）：

```text
wifi-init-probe: MAC_ST after init = 0x0000e000     # 仍不清
panic 0
```

⇒ **同样的写、同样的顺序、同样的底色（`clk_conf1` 写前都是 `0`），IDF 清、我们不清。**

⇒ 到这为止，可以从寄存器/写序层面排除的因素已经穷尽。剩下的唯一解释是**调用时机**：
`_wifi_clock_enable` 在我们这里被 blob 调用的**时点**，与 IDF 的 `wifi_clock_enable` 不同——
虽然计数 `clken=1` 两边一致，但**它在 init 序列中的相对位置**可能与 IDF 不同
（IDF 的 `esp_wifi_init_internal` 是同一份 blob，但外部的 IDF 运行环境不同）。

⇒ 下一步（唯一剩下的）：**记录 `_wifi_clock_enable` 被调用时"init 已经走到哪一步"**——
在钩子里打一个"当前已发生的 osi 调用序号"（我们本来就有 `event_count`），
与 IDF 侧同一钩子被调时的序号对比。若序号不同 ⇒ 就是时机差；若相同 ⇒ 说明还有别的前置状态。

⇒ 已穷尽：寄存器内容（八格全对齐）、写序（照 IDF device 顺序）、复位脉冲（rst_wifimac/rst_wifibb）、
临界区位（b14/b21）、ROM `ic_mac_init`、自旋让出、全库静态搜索（无人写 bits 13-15）。

### 位号修正（重要 bug）+ ICG 回归 IDF 值

**`clk_conf1` 的位号我之前写错了**。按 `modem_syscon_struct.h:130-140` 的字段序：

| bit | 字段 |
|---|---|
| 0 | `clk_wifibb_22m_en` |
| 1 | `clk_wifibb_40m_en` |
| **2** | **`clk_wifibb_44m_en`** |
| 3 | `clk_wifibb_80m_en` |
| 4 | `clk_wifibb_40x_en` |
| 5 | `clk_wifibb_80x_en` |
| 6 | `clk_wifibb_40x1_en` |
| **7** | **`clk_wifibb_80x1_en`** |
| 8 | `clk_wifibb_160x1_en` |
| **9** | **`clk_wifimac_en`** ← 清位点 |
| **10** | **`clk_wifi_apb_en`** |
| 11 | `clk_fe_20m_en` |

⇒ 我之前写的"MAC=bit0 / APB=bit9"是**错的**：`bit0` 根本不是 MAC 时钟，MAC 是 **bit 9**、APB 是 **bit 10**。

同时 **ICG 回退到 `0x64646400`**：那个 zb nibble 的 `4` 是 **IEEE802154 域**的码
（`set_clock_domain_icg_bitmap` 把 802154 映射到 `clk_zb_st_map[11:8]`），
所以 `0x64646400` **本来就是 IDF 对齐值**，我改成 `0x64646000` 反而制造了偏差。

修正后（位号对、ICG 对、顺序对）：

```text
wifi-init-probe: MAC_ST after init = 0x0000e000     # 仍不清
panic 0
```

⇒ **寄存器内容、位号、写序、ICG 全部对齐/修正后，`MAC_ST` 依旧不清。**

### 结论：寄存器层面**彻底穷尽**，剩下的只有"启动环境底色"

两边跑的是**同一份 blob**，所以 blob 调 `_wifi_clock_enable` 之前做的事**相同**。
⇒ "调用时机不同"这个说法其实是"**启动环境底色不同**"的另一种表述：
IDF 在 `app_main` 之前（bootloader / 早期启动）已经把某些 MAC/PHY 前置状态配好了，我们裸机没有。

⇒ **唯一还没做的决定性实验**：把 IDF 的 `before_init` 打印扩成**全表 CLKDMP**
（八寄存器 + `0x205871E0` + MAC 块窗口），与我们的 `CLKDMP[before-init]` **逐格 diff**——
**底色不同的那一格，就是缺的那一拍。**

### ★★★★★ 全表 diff 找到**唯一差异**：`LPCON+0x18`（IDF `0x1`，我们 `0x4`）

把 IDF station 的 `before_init` 打印扩成全表（八寄存器 + `0x205871E0` + MAC 块 `0x20104C00..10`），
与我们的 `CLKDMP[before-init]` 逐格对比：

| 寄存器 | **IDF `before_init`** | **我们 `before-init`** | |
|---|---|---|---|
| `MAC_ST` | `0x0000E000` | `0x0000E000` | ✓ |
| `c04` clk_conf | `0x00201002` | `0x00201002` | ✓ |
| `c08` force_on | `0x0` | `0x0` | ✓ |
| `c0C` icg | `0x0` | `0x0` | ✓ |
| `c10` rst_conf | `0x0` | `0x0` | ✓ |
| `c14` clk_conf1 | `0x0` | `0x0` | ✓ |
| **`f018` LPCON clk_conf** | **`0x00000001`** | **`0x00000004`** | **✗ 唯一差异** |
| `f01C` LPCON force_on | `0x00000004` | `0x00000004` | ✓ |
| `f020` LPCON icg | `0x0` | `0x0` | ✓ |
| `hp1e0` | `0x00000025` | `0x00000025` | ✓ |

`f018` 的字段（`modem_lpcon_struct.h:108-113`）：bit0 `clk_wifipwr_fo` / bit1 `clk_coex_fo` /
bit2 `clk_i2c_mst_fo` / bit3 `clk_lp_timer_fo` / bit4 `clk_fe_mem_fo`。

⇒ **IDF 的启动环境给的是 `clk_wifipwr_fo`（WiFi 电源域 force-on，bit0）**；
**我们被给成的是 `clk_i2c_mst_fo`（bit2）**。

⇒ 这就是"启动环境底色不同"的**具体一格**：**WiFi 电源域的 force-on 在 IDF 的 bootloader 阶段就已经打开，
而我们没有** ⇒ MAC 域始终没有真正上电 ⇒ `MAC_ST[15:13]` 永远不清。

⇒ 下一步（明确）：在 init 之前把 `LPCON+0x18` 的 **bit0 置上、bit2 清掉**（即先写成 `0x1`），
再走原来的 enable 序列，看 `MAC_ST` 是否第一次归零。

### 判决：`before_init` 全表**已与 IDF 完全一致**（含 MAC 块），`MAC_ST` 仍不清

补上 `LPCON+0x18` 的差异（pre-init 置 bit0、清 bit2：`0x4 -> 0x1`）后，再把 MAC 块窗口加进我们的 CLKDMP：

```text
wifi-init-probe: LPCON+18 fixed pre-init 0x4 -> 0x1 (IDF=0x1)
wifi-init-probe:   mac_c00=0x00000000        # IDF m00 = 0x0        ✓
wifi-init-probe:   mac_c10=0xf7c40000        # IDF m10 = 0xf7c40000 ✓
wifi-init-probe: MAC_ST after init = 0x0000e000     # 仍不清
panic 0
```

⇒ **`before_init` 的可观测全表（10 个寄存器 + MAC 块 `0x20104C00..10` + `hp1e0`）现在与 IDF 逐格相同**，
`LPCON+0x18` 那唯一一格差异也已对齐——**`MAC_ST` 依旧 `0xE000`**。

⇒ **这条结论很硬**：**差异不在任何"能在 init 之前观测到的寄存器状态"里。**

⇒ 于是只剩两个方向（都指向"非寄存器状态"）：
1. **调用时点**：`_wifi_clock_enable` 在 init 序列里的位置不同（`clken=1` 只是计数相同）；
2. **不可观测状态**：时钟树内部的 FSM 状态、或某个我们没有任何寄存器可见性的前置条件
   （例如 IDF 的 bootloader 在 `app_main` 之前跑过某段 ROM 代码，其副作用不落在这些寄存器上）。

⇒ 判据很明确：**若两侧 `before_init` 全表相同、`wifi_clock_enable` 的写序列也相同，而结果不同，
那必然有一个我们看不见的状态参与其中**——这时只有调试探针（写监视点）或 IDF 侧逐调用的时间戳能推进。

⇒ 本轮到此，寄存器层面的调查已**完全穷尽**。

### 补最后一格：`test_conf(+0x00) = 0x00000100` 也与 IDF 相同

把 `0x20109C00` 加进 CLKDMP：

```text
CLKDMP[before-init]  test_conf(+00)=0x00000100     # IDF c00 = 0x00000100  ✓
                     clk_conf(+04)=0x00201002     # IDF        0x00201002  ✓
                     lpcon+18=0x00000004          # IDF 是 0x1（已知唯一差异，已对齐验证）
CLKDMP[after-init]   test_conf(+00)=0x00000100     # 不变
```

⇒ **`before_init` 的可观测面（11 个寄存器 + MAC 块 `0x20104C00..10` + `hp1e0`）现在全部与 IDF 一致。**
⇒ `lpcon+18` 那格也已用 pre-init 写 `0x1` 对齐过（置 bit0、清 bit2），`MAC_ST` 仍不清。

### 边界声明：寄存器层面的调查**到此为止**

这条路径能做的都做了：

| 已穷尽 | 结论 |
|---|---|
| boot 底色（11 寄存器 + MAC 块） | **与 IDF 逐格相同** |
| IDF `wifi_module_enable` 的写集 | **只有 3 个寄存器**（`c0C`/`c14`/`hp1e0`），全已复刻 |
| 写序（device 枚举序 2→9） | 已照抄 |
| 位号（`clk_wifimac_en`=bit9 等） | 已修正 |
| ICG 两侧（SYSCON/LPCON） | 已对齐 |
| 复位脉冲（rst_wifimac/rst_wifibb） | 无效 |
| ROM `ic_mac_init` | 早前已判负 |
| 全库 133 个 `.o` 搜写 bits 13-15 | **不存在** |
| 自旋让出 | 记账模型不支持 |

⇒ **剩下的只有"不可观测状态"**：时钟树内部 FSM / PMU 影子状态 / IDF bootloader 在 `app_main` 之前
跑的 ROM 代码留下的、不落在这些寄存器上的副作用。

⇒ 唯一能推进的手段：**调试探针写监视点**（需 ESP-Prog 或接出板子的 USB-JTAG 口；`openocd` 与
`target/esp32s31.cfg` 都在，缺的只是传输通道）。

### ★★ 新线索：`wifi_clock_enable` 的**调用次数**两边差很多

| 侧 | 次数 | 来源 |
|---|---|---|
| IDF | **9 次**（`CLKEN BEFORE` 行数） | `/tmp/idf-clken.log`（覆盖 init + start 全程） |
| 我们 | **init 窗口内 1 次**（`clken=1`） | `INITWIN` 计数 |

⇒ 注意口径：IDF 那 9 次是**全程**计数，我们的 `clken=1` 只统计 **init 窗口**，所以不能直接相减。
但**定性差别是清楚的**：IDF 在 init 期间就**连着调了多次**（前 4 次 CLKEN 成对、第一次就把 `MAC_ST` 从
`0xE000` 清到 `0`），而我们 init 窗口只调 1 次。

⇒ 也就是说：**blob 在两个环境里走的路径确实不同**——这解释了为什么"寄存器全对齐却结果不同"。

⇒ 下一步（可做，零新装备）：把我们的 `clken` 计数改成**全程**计数（不只在 init 窗口），
与 IDF 的 9 次对比；若我们全程也只有 1~2 次 ⇒ 说明 blob 的时钟引用计数在我们这里没涨起来
（很可能因为它依赖的某个前置调用没发生）⇒ 那就是比"不可观测状态"更具体的一层。

### ★★★ 实测：我们的 blob 只调 `_wifi_clock_enable` **1 次**，IDF 侧 **9 次**

加了全程计数：

```text
wifi-init-probe: CLKEN total=1 (IDF=9 over init+start)
wifi-init-probe: MAC_ST before start = 0x0000e000 (spin mask 0xE000)
```

⇒ **这是"blob 走不同路径"的第一个直接读数**：IDF 的环境里 `wifi_module_enable()` 被调 **9 次**
（引用计数涨到 9），我们的环境里只有 **1 次**。

⇒ 含义：IDF 的 init/start 过程中有 **8 次额外的"取 WiFi 时钟"动作**（PHY、coex、或其他模块各自 acquire），
**我们这边那些 acquire 全部没发生** ⇒ 说明**调用方**在两边不同，而不是被调用的实现不同。

⇒ 这也和"寄存器全对齐却结果不同"自洽：**不是写错了，是"多出来的那 8 次调用"里有一次带来了
真正让 MAC 状态机启动的东西**（例如某次 acquire 触发了时钟树的重配置/校准）。

⇒ 下一步（明确且可做）：**在 IDF 侧给每次 `wifi_clock_enable` 记调用者返回地址**
（`__builtin_return_address(0)`），拿到那 9 次的调用者列表 ⇒ 与我们在裸机侧只有 1 次的事实对照 ⇒
**找出"我们缺的那 8 个调用者是谁"**，那就是缺的那一拍。

### ⚠ 更正上一条：**init 窗口内两边都只调 1 次**（"9 次"是全程计数）

在 IDF 的 `wifi_clock_enable_wrapper` 里记 `__builtin_return_address(0)` + 调用前后 `MAC_ST`：

```text
CLKCALLER n=1
CLKCALLER 0 ra=4005700c mac_b=0000e000 mac_a=00000000
```

⇒ **IDF 在 init 窗口内也只调用了 1 次**（`n=1`），且这一次就把 `MAC_ST` 从 `0xE000` 清到 `0`。

⇒ 上一节"1 vs 9"的对比是**口径错误**：那 9 次是**全程**（init + start + 之后），不是 init 窗口。
**init 窗口内两边都是 1 次** ⇒ "缺 8 个调用者"这条假设**作废**。

⇒ 于是形成一个**很尖锐的悖论**：

| 项 | IDF | 我们 |
|---|---|---|
| init 窗口调用次数 | 1 | 1 |
| 调用者 | `0x4005700c`（同一份 blob） | 同一份 blob |
| 调用前寄存器全表 | 见上（与我们逐格相同） | — |
| 调用后的写 | `c0C`/`c14`/`hp1e0` | 同（已对齐） |
| **`MAC_ST` 结果** | **`0x00000000`** | **`0xE000`** |

⇒ **输入状态相同、调用相同、写相同、结果不同** ⇒ 剩下的只能是**blob 自身在调用那一刻的不可见状态**
（它的内部变量、或它此前读过的 efuse/其他寄存器），**不是时钟寄存器**。

⇒ 下一步（唯一）：在 IDF 侧**同一个调用点之前**把 blob 可能依赖的 efuse/chip 信息读一遍对比
（例如 `efuse_ll_get_chip_rev`、`efuse` 里的 MAC/PHY 校准相关位）——
**同一份 blob 在两个环境里走的路径不同，最可能的原因就是它读到的 efuse/芯片信息不同。**

### ⚠⚠ 撤回"调用者不同"：**两边是同一个函数**（`pm_attach`），反汇编逐字节相同

我先看地址不同（IDF `0x4005700c` vs 我们 `0x40036f12`）就判"调用者不同"——**错**。反汇编对照：

| IDF（`pm_attach` 基址 `0x40056e20`，偏移 `0x1EC`） | 我们（基址推定 `0x40036d26`，偏移 `0x1EC`） |
|---|---|
| `40056ff8: sb zero,289(s0)` | `40036efe: sb zero,289(s0)` |
| `40056ffc: li a6,0` | `40036f02: li a6,0` |
| `40056ffe: lw a5,248(a5)` | `40036f04: lw a5,248(a5)` |
| `40057002: sw a6,428(s0)` | `40036f08: sw a6,428(s0)` |
| `40057006: sh zero,398(s0)` | `40036f0c: sh zero,398(s0)` |
| `4005700a: jalr a5` | `40036f10: jalr a5` |
| `4005700c: li a5,3` | `40036f12: li a5,3` |

⇒ **逐字节相同** ⇒ **调用者是同一个函数 `pm_attach`**（`lw a5,248(a5)` = osi 表偏移 248 = index 62），
地址不同**只因链接顺序不同**（我们的 `.flash.text` 从 `0x40000020` 起，IDF 的布局不同）。

⇒ 所以"调用者不同"这条**作废**。悖论回到原样：

> **同一份 blob、同一个函数 `pm_attach`、同一个调用点（同一段指令）、同一份寄存器底色、
> 同样的写序列 —— `MAC_ST` 一个清一个不清。**

⇒ 唯一的解释只剩 **blob 自身在那个时刻的内部状态**（`pm_attach` 里的 `s0` 上下文、它之前读过的
efuse/其他寄存器、或它此前的调用历史）。

⇒ 下一步（唯一且可做）：**对比 init 期间完整的 osi 钩子调用序列**。
两边表同构（`hook id` 就是 IDF 表下标），我们已有事件环；IDF 侧在 `esp_adapter.c` 给每个 entry 记下标即可。
**序列的分叉点就是答案。**

### 拿到我们侧完整的 osi 调用序列：**init 窗口内 152 次**

把事件环从 8 扩到 64，并在 init 前后各做一次重置/打印：

```text
wifi-init-probe: OSISEQ n=152 (ring=64)
OSI 0  timer_setfn    a0=0x2f0173d0 a1=0x40034698
OSI 1  timer_setfn    a0=0x2f017408 a1=0x40034690
...
OSI 9  queue_send_ok  a0=0x0 a1=0x64646400      ← 注意 a1 就是 ICG 值
OSI 10 coex_rel       a0=0x0 a1=0x604
OSI 11 wifi_clk_en    a0=0x0 a1=0x0             ← 我们的 `_wifi_clock_enable` 在第 11 位
OSI 12 calloc / 13 zalloc / 14 alloc
OSI 15 coex_interval / 16-17 timer_setfn / 18 timer_disarm / 19 semphr_give
...
```

（环 64 条，`n=152` ⇒ 只剩**前 64 条**可见；要完整序列得把环再放大或分段记录。）

归档：`logs/ch25-osi-seq-boot.log`。

⇒ 这条序列现在可以直接与 IDF 侧逐条 diff —— **IDF 侧需要给 `esp_adapter.c` 那张表的每个 entry 加"记下标"包装**
（128 个 entry，工作量大但机械；或只包前 30 个高频项，因为分叉点通常很早）。

⇒ 另一个值得注意的读数：**`OSI 9 queue_send_ok a1=0x64646400`** —— blob 自己把 `0x64646400` 作为参数传出去，
这也解释了为什么我们写 `0x64646000` 之后读回会变成 `0x64646400`（**blob 随后又写了一次**，不是我们写错）。

### ⚠ 更正：环存的是**最后** N 条，`wifi_clk_en` 实际在 **139/152** 位

上一节报"`wifi_clk_en` 在第 11 位"是错的——那是**环里最后一个 64 条窗口内的相对索引**，
而 `dump` 循环从 `events[0]` 开始读（环只保最后 64 条 ⇒ 读到的是第 88..151 条，索引错位 88）。

修正两处：

1. **环从 64 扩到 256**（init 实测 152 条，一次装下；`HookEvent` 12 B ⇒ 3 KB `.bss`）；
2. **dump 起点改为 `event_count - n`**（环语义是"最后 n 条"，不是"前 n 条"）。

修正后：

```text
wifi-init-probe: OSISEQ n=152 ring=256 base=0
OSI 0 mutex_create / 1 mutex_lock / 2 calloc / 3 zalloc / 4 alloc / 5 calloc …
OSI 139 wifi_clk_en a0=0x0 a1=0x0        ← **`_wifi_clock_enable` 在 139/152 位**
```

⇒ 所以 **`wifi_clock_enable` 发生在 init 的**接近末尾**（139/152），不是开头**。
⇒ 之前"前 20 条里就有 wifi_clk_en"的判读**作废**。

⇒ 顺带撤一条**伪线索**：`OSI 9 queue_send_ok a1=0x64646400` 里的 `a1` 只是 `note()` 记的**参数**，
与 `0x20109C0C` 的内容无关；静态扫描也已证明 blob 从不写 ICG（只碰 bits 17-19）。
⇒ **"blob 自己把 ICG 写成 0x64646400"这条不成立**，别再当线索。

归档：`logs/ch25-osi-seq-boot.log`（完整 152 条）。

### ★ 闭环：ICG 的 `0x64646400` 是**我们自己写的**（`shellPhyEnable`），且正是 IDF 的值

两件事一起钉死：

**① 静态扫描证明 blob 从不写 ICG**：把 133 个 blob `.o` 全扫 `0x20109C0C`——

```text
（无任何 .o 命中）
```

⇒ **blob 侧从不碰 `0x20109C0C`** ⇒ "blob 自己把 ICG 写成 `0x64646400`"这条**证伪**。

**② 那是谁写的？我们自己的 `_phy_enable` 钩子**：

```zig
fn shellPhyEnable(modem: u32) callconv(.c) usize {
    ...
    const icg: *volatile u32 = @ptrFromInt(0x2010_9C0C);
    const icg_before = icg.*;
    icg.* = 0x6464_6400;      // ← 这里
```

⇒ `shellPhyEnable` 在 init 期间被调用，把 ICG 写成 `0x64646400` —— **而这正是 IDF 的实测值** ⇒
**ICG 一直是对的**，之前"我们写 `0x64646000` 读回变 `0x64646400`"的现象就是**这一步覆盖**。

⇒ 结论：**ICG 这条线彻底关闭**（blob 不写、我们写的就是 IDF 值）。
⇒ 之前那条 `queue_send_ok a1=0x64646400` 的"伪线索"也一并作废（`a1` 只是 `note()` 记的参数）。

### ★★★ 修掉一个 instrumentation bug（`note` id 与 `hook_ids` 系统错位）+ 实现真·`clock_disable`

**① 标签错位**：`hook_ids` 下标与 clock/coex 里的 `note()` id 系统性错开一位：

| 函数 | 原来用的 id | 实际标签 | 改成 |
|---|---|---|---|
| `shellWifiClockDisable` | `21` | `wifi_clk_en` ❌ | **`22`**（`wifi_clk_dis`） |
| `shellWifiResetMac` | `22` | `wifi_clk_dis` ❌ | **`23`**（`wifi_reset_mac`） |
| `shellWifiClockEnable` 入口 | 无 | — | **补 `note(21)`**（`wifi_clk_en`） |
| ICG 写入 | `20` | `queue_send_ok` ❌ | **`33`**（`icg_write`） |

⇒ **之前"OSI 139 wifi_clk_en"其实是 `clock_disable` 被调用**；"OSI 9 queue_send_ok"是 enable 里的 ICG note。
⇒ 修正后：`OSI 137 wifi_clk_en` → `OSI 140 wifi_clk_dis` ⇒ **两边 init 都做了 enable→disable 一对**。

**② `shellWifiClockDisable` 原来是空桩**（只 `note` 不做事），而 IDF 的 `wifi_module_disable()` 会真断电
（deps 反向 `configure(false)` + `SOC_PLL_SOURCE_CG` 写 `0x25`）。已按 IDF 反向顺序实现：
`80x1 off → BB 组清 + rst_wifibb 脉冲 → MAC(bit9) off → 44M/APB off → LPCON ICG 清零 → 0x205871E0=0x25`。

**结果**：

```text
wifi-init-probe: MAC_ST after init = 0x0000e000     # 仍不清
irq-sample … mac=0x00fff000                          # start 仍在自旋
panic 0
```

⇒ **补上真·断电（enable→disable）后仍不清** ⇒ 这条也不是。

⇒ 但这次修掉的是**真 bug**（标签错位会让后续所有序列对照读错），保留。

### 标签全部修好 + **真断电确实生效**（`hp1e0` 走 `0x3d → 0x25 → 0x3d`），但 `MAC_ST` 仍不清

把剩下的 id 冲突也修掉（`shellCoexInit` 的 `23` → **`24`**；`hook_ids` 追加 **`icg_write`（下标 35）**，
`note_id_max` 同步到 `35`），板侧序列现在是正确的：

```text
OSI 137 wifi_clk_en a0=0x0 a1=0x0
OSI 138 icg_write   a0=0x0 a1=0x64646400      ← ICG 写入（原来错标成 queue_send_ok）
OSI 140 wifi_clk_dis a0=0x0 a1=0x0
```

**`hp1e0`（`SOC_PLL_SOURCE_CG`）三时刻**：

```text
before-init  0x00000025
after-init   0x00000025     ← 我们的 disable 真的写进去了（IDF disable 值就是 0x25）
before-start 0x0000003D     ← 之后又被 enable 回 0x3D
```

⇒ **`enable → disable → 再 enable` 的完整周期确实发生了**（`0x25 → 0x3D → 0x25 → 0x3D` 链条可见）。

⇒ **而 `MAC_ST` 仍是 `0x0000E000`** ⇒ **真·断电/上电周期也不是答案**。

⇒ 到此，**"时钟域"这条线（门、源、顺序、断电周期）已全部实测过且全部无效**。
⇒ 按物理视角，剩下的解释更偏向 **LMAC 固件/启动状态**（bits 13-15 = "LMAC 未启动"），
而不是任何时钟寄存器配置。

### ★★★★★ MAC 块 4 KB 全窗口 diff：**唯一差异精确定位到 `0x201044EC` 的 bit 6 / bit 9**

用"分段 hash"把 4 KB（`0x20104000..0x20105000`）逐级缩小（逐字 dump 太占串口）：

| 层级 | 结果 |
|---|---|
| 整窗 `xor`/`sum` | IDF `fda046e5`/`1d7b2820` vs 我们 `499d6ebe`/`bd8c0cdc` ⇒ **不同** |
| 4 个 quarter | Q0 ✓、Q2 ✓、**Q1 ✗**、**Q3 ✗**（Q3 含 `MAC_ST`，已知） |
| Q1 的 16 个 block | block 0-2 ✓、**block 3 ✗**、block 4-15 ✓ |
| block 3 的 16 个字 | **只有 `0x201044EC` 不同** |

**逐字对照**：

| 地址 | IDF | 我们 | 差 |
|---|---|---|---|
| `0x201044EC` | `0x000102C0` | `0x00010080` | xor = `0x00000240` ⇒ **bit 6 与 bit 9 在 IDF 侧为 1、我们侧为 0** |
| 其余 15 字 | — | — | **完全相同** |

⇒ **整个 4 KB MAC 块里，与我们不同的就只有这一个字、这两位**（外加 `MAC_ST` 的忙位）。

⇒ `0x20104xxx` 是 **Wi-Fi MAC 的私有寄存器块**（IDF 的 `soc/esp32s31/**` 头文件里没有它的定义），
所以这条路只能靠**反查写者**：在 IDF 侧对 `0x201044EC` 设写监视点（缺 JTAG），或
**在 blob 的 133 个 `.o` 里搜写 `0x201044EC` 的代码**（纯静态，零成本）——**下一步就是这个**。

### 静态搜 `0x201044EC` 的引用者（初步）

| 搜索 | 结果 |
|---|---|
| `201044ec` 直接常量 | **无任何 `.o` 命中**（寄存器是 `base+offset` 访问） |
| `201044` 前缀 | `hal_mac_ctl.o`(45) / `hal_debug.o`(22) / `hal_mac_tx.o`(10) / `hal_ampdu.o`(3) / `hal_mac.o`(3) / `pp_debug.o`(2) / `wdev.o`(1) |
| `addi …,236`（= `0x20104400+0xEC`） | **只有 `hal_debug.o`** —— 但那是 **`lw`（读）**，不是写 |

⇒ 目前只找到**读**它的地方（`hal_debug.o`，读出来按位屏蔽后使用），**写者还没定位**。

⇒ 下一步（明确）：在 `0x20104400` 基址 + 偏移的访问形式里找**写 `+0xEC`** 的指令
（`sw` 前面的 `addi`/`lui` 组合可能被编译器合并或跳到别处），或直接在 IDF 侧对该地址设写监视点（缺 JTAG）。

⇒ 但**已经拿到的关键事实**：**4 KB MAC 块里与我们不同的只有 `0x201044EC` 的 bit 6 / bit 9**（外加 `MAC_ST` 忙位）
—— 这把"MAC 域状态不同"从模糊判断变成了**两个具体的位**。

### ★★★★ 判决：`0x201044EC` **写不粘**（只读状态位）⇒ 它是**症状**，不是病因

把全 4 KB 里唯一不同的那个字补上 IDF 的 bits 6/9：

```text
wifi-init-probe: 0x201044EC fixed 0x10080 -> 0x10080 (IDF=0x102C0)
```

⇒ **写入完全没生效**（读回仍是 `0x10080`，bit 6/9 仍为 0）。

⇒ 所以 `0x201044EC` 和 `MAC_ST[15:13]` 一样是**只读状态位**：它 **反映** MAC 内部状态，而不是**配置**它。

⇒ 结论：**这唯一一个"不同的字"也不是病因**——它和忙位一样，是"MAC FSM 没启动"的另一个表征。

⇒ 到这里，**寄存器层面的最后一条线索也关闭了**：

| 层 | 状态 |
|---|---|
| 时钟寄存器（门/源/顺序/断电周期） | 全部对齐，全部无效 |
| MAC 块 4 KB | 唯一差异 `0x201044EC` ⇒ **只读，写不进** |
| `MAC_ST[15:13]` | 只读，写不进 |
| blob 软件写点 | 133 个 `.o` 无人写这两处 |
| osi 调用序列 | 两边同构（enable→disable，无 reset_mac） |

⇒ **所有可观测且可写的状态都已对齐；所有仍不同的量都是只读状态位。**
⇒ 这只能是 **MAC/PHY 层面某个我们没执行的动作**（LMAC 固件加载/启动，或 ROM 在 IDF bootloader 阶段做的某事），
而它在**寄存器空间里只留下只读的状态痕迹**，不提供配置入口。

### 判决（负）：**新前提下**重测 ROM `ic_mac_init(0)`（正确 ABI），`MAC_ST` 仍不清

ADR 早前那次是在**旧状态**（握手未修好、blob 任务不调度）下做的，而且 ABI 可能不对（入参应为"接口号"）。
现在握手成立、任务能跑，按正确 ABI 重测：

```text
wifi-init-probe: ic_mac_init(0) rc=0 MAC_ST=0x0000e000
wifi-init-probe: MAC_ST after init = 0x0000e000
panic 0
```

⇒ **`ic_mac_init(0)` 返回 0（成功），但 `MAC_ST` 仍是 `0xE000`。**

⇒ 所以"补一次 ROM 的 MAC init"即使**成功返回**也不清位 ⇒ 真正缺的不是这个调用本身。

⇒ 至此可以列出**全部已否路径**（这次是干净、新前提下的完整清单）：

| # | 路径 | 结果 |
|---|---|---|
| 1 | 直写 `MAC_ST`（0 / 1 / 全 1） | 只读，读回恒为 1 |
| 2 | 直写 `0x201044EC`（唯一差异字） | 只读，读回不变 |
| 3 | `rst_wifimac` / `rst_wifibb` 脉冲（20 µs 宽，含 in-hook） | 无效 |
| 4 | 时钟八寄存器对齐（门 / 源 / ICG 两侧 / `hp1e0`） | 全部已是 IDF 值 |
| 5 | 时钟写序（IDF device 枚举 2→9） | 已照抄 |
| 6 | `clk_conf1` 位号修正（MAC=bit9 / APB=bit10） | 已修正 |
| 7 | **真·U0003clock_disable**（enable→disable→enable 完整周期） | 已实现，`hp1e0` 走 `0x3d→0x25→0x3d`，仍不清 |
| 8 | `b14` / `b21` 置 1 | `b288` 仍 0 |
| 9 | **ROM `ic_mac_init(0)`（新前提 + 正确 ABI）** | **rc=0，仍不清** |
| 10 | 从 `esp_wifi_start` 自旋里让出 | 记账模型不支持从 main 任意点切入 |
| 11 | 全库 133 个 blob `.o` 静态搜写 bits 13-15 / `0x201044EC` | **无人写** |
| 12 | osi 调用序列对照 | 两边同构（enable→disable，无 reset_mac） |

⇒ **结论收敛为一句**：所有**可写**且**可观测**的状态都已与 IDF 一致；
所有**仍不同**的量（`MAC_ST[15:13]`、`0x201044EC` 的 bit6/9）都是**只读状态位**，只能被硬件/固件改变。
⇒ 裸机上缺的是一个**我们无法通过寄存器写触发的 MAC/PHY 启动动作**（LMAC 固件加载/启动，
或 ROM 在 IDF 二级 bootloader 阶段完成的初始化）。

### 收尾：两个未落档项确认 + 下一轮零成本抓手

**① 实验开关归位**：`ic_mac_init(0)` 的调用已收进既有开关 `probe_manual_ic_mac_init`（默认 `false`），
不再有第二个无条件调用点 —— 复跑时翻开关即可。

**② `station before_init` 全表 diff 的判读已归档**（见上"全表 diff：唯一差异 `LPCON+0x18`"节）。
结论：唯一差异是 `f018`（IDF `0x1`=wifipwr_fo vs 我们 `0x4`=i2c_mst_fo），
**pre-init 对齐成 `0x1` 后 `MAC_ST` 仍 `0xE000`** ⇒ 该差异也**不是**病因。

**③ ICG 语义更正已归档**：blob 从不写 `0x20109C0C`（133 `.o` 扫描），
写它的是我们自己的 `shellPhyEnable`（`0x64646400` = IDF 值）⇒ ICG 一直是对的。

**下一轮零成本抓手**：`hal_mac_is_dma_enable()`（ROM `0x2f800d4c`，无参）两边都是 `0`，
但它与清位动作的**时间相关性**还没测过 —— 在 IDF 侧把它也进环形缓冲，
看它是否在 `dev=7` 清位的同一拍变化。若 IDF 侧它在清位后变 `1`（而我们永远 `0`），
它就是比 `MAC_ST` 更早的"LMAC 起来了"信号，可用于我们侧的持续监视。一次 IDF 构建 + 一次烧录。

### 判决（负）：`hal_mac_is_dma_enable()` 在 IDF 的**每一次** configure 里都是 `0`

在 IDF 的 `modem_clock_device_control` 循环里，每次 `configure` 前记 `hal_mac_is_dma_enable()`（ROM `0x2f800d4c`）
与当时的 `MAC_ST`：

```text
DMASEQ n=14
0 dev=2 dma_enable=0 mac_before=0000e000
1 dev=3 dma_enable=0 mac_before=0000e000
2 dev=5 dma_enable=0 mac_before=0000e000
3 dev=6 dma_enable=0 mac_before=0000e000
4 dev=7 dma_enable=0 mac_before=0000e000   ← 清位就发生在这里
5 dev=8 dma_enable=0 mac_before=00000000
6 dev=9 dma_enable=0 mac_before=00000000
7..13（disable 路径）dma_enable=0
```

⇒ **`dma_enable` 全程是 `0`，包括 `dev=7` 清位之后。**

⇒ **IDF 在 init 期间也从未把 DMA 环建起来** ⇒ **DMA 环不是这次清位的原因，也不是两边差异的判据**。
⇒ 这条假设（早前 ADR 里"忙位要等 DMA 环 + RF 前端上电"）**正式排除**。

⇒ 也说明 `hal_mac_is_dma_enable()` 不是"LMAC 起来了"的更早信号 —— 它在 IDF 侧同样是 0。

### ⚠ 撤回：「malloc 5 vs 23」**不可比**（数的是不同表项）

在 IDF 的 `wifi_malloc` / `wifi_zalloc_wrapper` / `wifi_calloc` / `mutex_lock_wrapper` 里加计数器：

```text
HCNT malloc=5 zalloc=6 calloc=6 mutex_lock=28
```

与我们直方图的 `malloc=23 / zalloc=10 / calloc=4 / mutex_lock=25` 一比，`malloc` 差 4.6 倍——**看似重大分叉，其实不成立**：

```zig
// 我们的 note(8, ...)（标签 "malloc"）在 shellMallocInternal 里，不是 shellMalloc
fn shellMallocInternal(size: usize) callconv(.c) ?*anyopaque {
    note(8, size, 0);          // ← 我们数的是 _malloc_internal
```

⇒ **IDF 侧的计数器挂在 `_wifi_malloc`，我们数的是 `_malloc_internal` —— 两个不同的 osi 表项**。
⇒ 所以 5 vs 23（以及其余三项）**都不是同一个钩子的计数** ⇒ **这条对比作废**。

⇒ 教训：**做两侧计数/序列对比前，必须确认"数的确实是同一个表项"**——
这已经是本课题第三次因"标签/表项错位"产生的假线索（前两次：ring 起点错位、`note` id 与 `hook_ids` 错位）。

⇒ 要做对：IDF 侧计数器必须挂在我们**同样标注**的那些表项上（`_malloc_internal` 对应 IDF 的哪一项，需先查表），
或更稳的做法 —— **两侧都用"表下标"计数**，不靠名字。

#### 佐证：我们的计数是**按函数**、不是按表项

`note(8)`（标签 `malloc`）与 `note(13)`（标签 `alloc`）都在 `shellMallocInternal` 里；
而 `note(13)` **还在 `shellZallocInternal` 里**：

```zig
fn shellMallocInternal(...) { note(8, size, 0); ... note(13, size, ...); }
fn shellZallocInternal(...) { note(13, size, ...); }        // ← 第二个 note(13)
```

⇒ 直方图 `malloc=23 / alloc=33 / zalloc=10` 恰好满足 **33 = 23 + 10** ⇒ 印证：
**这些标签是"按函数"统计的**（`shellMallocInternal` / `shellZallocInternal`），
而 IDF 的计数器是**按表项**（`_wifi_malloc` 一项）。

⇒ 我们那张表把 `_malloc_internal` **和** `_wifi_malloc` **都指向 `shellMallocInternal`**：

```zig
t._malloc_internal = @ptrCast(&shellMallocInternal);
t._wifi_malloc     = @ptrCast(&shellMallocInternal);   // ← 两个表项共用同一实现
```

⇒ 所以我们的 `23` 是**两个表项之和**，IDF 的 `5` 只是 `_wifi_malloc` 一项
⇒ **两边不可比**，结论维持撤回。

⇒ 若要做对：在 `shellMallocInternal` 里按**调用来源**（哪个表项）分开计数，
或让 IDF 侧也在 `_malloc_internal` 上加计数器，两边同口径。

### 永久修法：用 comptime 从 `Osi` 结构生成「字段名 → 表下标」

三次假线索都源于"名字/表项错位"。根治办法是把名字**从结构体自动导出**，而不是手工维护第二份清单：

```zig
// components/wifi-blobs/src/osi.zig
pub fn indexOf(comptime name: []const u8) comptime_int {
    const fields = @typeInfo(Osi).@"struct".fields;
    inline for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    @compileError("no such Osi field: " ++ name);
}

pub fn nameOf(i: usize) []const u8 { /* 反查，越界返回 "?" */ }
```

⇒ `Osi` 是 `extern struct`、每项 4 B ⇒ **下标 = 序号 = `offset/4`**，正是 IDF `wifi_osi_funcs_t` 的字段序。

⇒ 以后两侧对照**一律用下标**：`osi.indexOf("_wifi_malloc")` 与 IDF 侧按同一序号计数/记录，
**名字错位问题从根上消失**。

（主机测试已加：抽查 `indexOf("_version") == 0` 且 `nameOf(0) == "_version"`。）

### ⚠ 一次假警报：**不能用文本解析比对 `wifi_os_adapter.h` 的字段序**

想用新加的 `osi.indexOf()` 验证"我们的 128 字段镜像与 IDF 头是否同序"，于是对头文件做正则提取：

```text
IDF 128 个函数指针 / 我们 127 个（去掉 _version）
首个分叉 @53: IDF=_phy_common_clock_enable  我们=_phy_update_country_info
（后续整体错位 2 项）
```

⇒ **表面看像"我们的表从第 53 项起整体错位 2 位"——但这是假警报。**

原因：该头文件有 **9 处 `#if`**（其中至少 3 处按目标裁剪，含 **S31 专属**字段）：

```c
#if CONFIG_IDF_TARGET_ESP32S31
    int (* _coex_configure_preemption_end_cb)(bool is_register, int(*cb)(uint32_t));
#endif
```

⇒ **纯文本解析取到的是"所有分支全算"的顺序，必然与实际 S31 生效顺序不同** ——
这正是 `osi.zig` 注释里早就写过的坑（"**不要**用文本解析：这个头有 5 处按目标裁剪字段的 `#if`"）。
我这次又踩了一遍。

**独立证据表明我们的布局是对的**：`INITWIN … clken=1` —— 说明 blob 调 `_wifi_clock_enable` 时
**确实落到了我们的 `shellWifiClockEnable`**（`cnt_clk_en` 自增）。若从 53 起错位 2 项，
那次调用会落到别的槽位上，`clken` 就不会是 1。

⇒ **正确做法**（`osi.zig` 注释里已有现成命令）：用 `riscv32-esp-elf-gcc -E -P` 带上真实
`sdkconfig.h` 预处理该头，再 `sed -n '/typedef struct wifi_osi_funcs_t {/,/} wifi_osi_funcs_t;/p'` 取生效字段。
⇒ 结论：**布局无需修改**；`indexOf()` 仍然有用（它读的是我们自己的结构，不存在裁剪问题），
但**不能拿它去和未预处理的头文件比对**。

### ✅ 决定性验证：我们的 128 字段镜像**完全正确**（用正确方法预处理后逐项对上）

按 `osi.zig` 注释里的正确做法（`riscv32-esp-elf-gcc -E -P` + 真实 `sdkconfig.h` + S31 头路径），
取 S31 **实际生效**的字段序，与我们结构逐项比对：

```text
S31 生效函数指针数: 126
我们的函数指针数:   127   ← 去掉 `_version` 后
✅ 前 126 项完全一致
```

尾部对照：

| | 末 4 项 |
|---|---|
| IDF(S31) | `_wifi_bb_sleep_retention_attach` / `_detach` / `_wifi_mac_sleep_retention_attach` / `_detach` |
| 我们 | 同上 4 项 **+ `_magic`** |

⇒ 我们的布局 = **`_version` + 126 个函数指针 + `_magic` = 128** —— 与 IDF 的 S31 生效结构**完全一致**。

⇒ **布局问题彻底排除**（之前那次"错位 2 项"确认为文本解析假警报）。

> [!note] 正确方法（可复核）
> ```bash
> GCC=~/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin/riscv32-esp-elf-gcc
> $GCC -E -P -I firmware/idf-bootstrap/build/config \
>   -I $IDF/components/esp_wifi/include -I $IDF/components/esp_wifi/include/esp_private \
>   -I $IDF/components/soc/esp32s31/include -I $IDF/components/hal/esp32s31/include \
>   -include sdkconfig.h - <<<'#include "esp_private/wifi_os_adapter.h"'
> ```
> 然后**按 `;` 切分声明语句、每条取第一个 `(*name)`**（否则嵌套函数指针参数 `int (*cb)(int)` 会被误当字段）。

#### 补充证据：S31 专属的两个字段**确实在我们的结构里，且相对位置完全一致**

有人质疑"`_coex_configure_preemption_end_cb` 与 `_wifi_disable_ac_ax` 可能不在我们 128 字段里"。逐个查下标：

| 字段 | IDF 下标 | 我们下标 |
|---|---|---|
| `_coex_schm_flexible_period_set` | 117 | **118** |
| `_coex_configure_preemption_end_cb` | 120 | **121** |
| `_wifi_disable_ac_ax` | 121 | **122** |

⇒ **恒定 +1 偏移**，正是因为我们在 index 0 多了 `_version` ⇒

**我们的结构 = `_version`(0) + IDF 的 126 个字段(1..126) + `_magic`(127) = 128**，**完全正确**。

⇒ 之前那次"129 个字段 / 从第 53 项错位"是**提取脚本的 bug**（正则把嵌套的 `int (*cb)(uint32_t)` 参数也当成了字段）。
**布局问题彻底关闭。**

### 部分序列对照：`clk_en → coex_rel → clk_dis`（我们）vs `clk_en → clk_dis`（IDF）

按"下一步 ②"给 IDF 的 6 个表项埋记录点（`1=mutex_lock 2=timer_setfn 3=semphr_give 4=coex_rel 5=clk_en 6=clk_dis`），
拿到的子序列：

```text
IDF (n=30):  1×24, 5, 6, 1, 1, 1, 1
我们:        1, 3, 1×23, 2×12, 5, 4, 6, 2, 2, 3, 1
```

**两处差异**：

1. **IDF 序列里完全没有 `2`（timer_setfn）与 `3`（semphr_give）** —— 这不是"IDF 不调"，
   而是**那两个记录点插入失败**（`esp_coex_common_timer_setfn_wrapper` / `esp_coex_common_semphr_give_wrapper`
   定义在别的文件，正则没匹配到）⇒ **这一类对比仍然不完整**；
2. **能比的那几项**：

| 断点 | IDF | 我们 |
|---|---|---|
| `clk_en`(5) 之后 | **直接 `clk_dis`(6)** | **中间夹一个 `coex_rel`(4)** |

⇒ 这是一个**候选分歧**：我们 init 期在时钟 enable 与 disable 之间调了 `coex_rel`，IDF 那一段没有。
⇒ 但**不能当结论**——IDF 的 `coex_rel` 记录点是否真的被调用、以及两个缺失钩子的补齐，都还没验证。

⇒ 下一步（明确）：把 `esp_coex_common_*` 那两个 wrapper 的定义位置找出来（在 `esp_coex` 组件里），
补齐记录点后**重跑一次**，再做完整子序列对照。**这次不算结论。**

### ★★★ 完整子序列对照：**两边完全一致**（补上 `esp_coex` 侧的两个记录点之后）

把 `esp_coex_common_*` 两个 wrapper（在 `components/esp_coex/esp32s31/esp_coex_adapter.c`）也用**同一个共享环**记录后重跑：

```text
IDF  (46): 1, 3, 1×23, 2×12, 5, 6, 2, 2, 3, 1, 1, 2, 1, 1, 3
我们 (43): 1, 3, 1×23, 2×12, 5, 4, 6, 2, 2, 3, 1
```

（`1=mutex_lock 2=timer_setfn 3=semphr_give 4=coex_wifi_release 5=clk_en 6=clk_dis`）

**逐项对齐后**：

| 段 | IDF | 我们 |
|---|---|---|
| 开头 | `1, 3` | `1, 3` ✓ |
| 中段 | `1 × 23` | `1 × 23` ✓ |
| 再中段 | `2 × 12` | `2 × 12` ✓ |
| 时钟段 | `5, 6` | `5, [4], 6` |
| 收尾 | `2, 2, 3, 1` | `2, 2, 3, 1` ✓ |
| 之后 | IDF 还有 `1,1,2,1,1,3`（它的 run 跑得更远） | — |

⇒ **除那一个 `4` 之外，两边序列完全一致**（连 23 个 `1`、12 个 `2` 的数目都一样）。

**而那个 `4` 又是标签问题**：我们的 `hook_ids` 里
`28="coex_req"` / `29="coex_rel"` / `30="coex_interval"`，而 `note(29)` 实际出现在 **`shellCoexSchmIntervalSet`** 里
⇒ 我们的 "coex_rel" 条目其实是 **`coex_schm_interval_set`**，与 IDF 数到的 **`_coex_wifi_release`** 不是同一个钩子。

⇒ **结论：`osi` 调用层两边同构**（6 个可比钩子的数目与顺序**逐项相同**）。
⇒ 这也再次印证：**差异不在"blob 走了不同的 osi 路径"上**，只能落在 osi 之下的东西
（MAC 寄存器写 = 已证一致 / 只读状态位 = 只剩这些）。

#### 补充确认：那个 `4` 确实不是同一个钩子（复核后关闭）

我们的序列里 coex 类条目只有两条：

```text
1 coex_rel
1 coex_interval
```

⇒ **没有任何 `coex_req`、也没有 `coex_wifi_release`**。
而 `hook_ids[29]="coex_rel"` 对应的 `note(29)` 实际写在 **`shellCoexSchmIntervalSet`** 里
⇒ 我们的 "coex_rel" 条目 = **`coex_schm_interval_set`**。

⇒ IDF 的 id 4 是 **`_coex_wifi_release`** ⇒ **两者不是同一个钩子，不能相减**。

⇒ 因此**排除这一项后，两边 6 个可比钩子的序列与计数逐项相同** ⇒
**`osi` 调用层同构，可以正式关闭这条线。**

⇒ 于是整个课题的剩余解释被压缩到一句：
**在 osi 层完全同构、所有可写寄存器完全同构的前提下，`MAC_ST[15:13]`（及 `0x201044EC` bit6/9）
这些只读状态位仍不同** —— 说明差异发生在 **osi 之下、寄存器可见面之外**（MAC/PHY 内部固件或 ROM 早期初始化）。

### 判决（负）：`_coex_init` 返回失败后，**coex 簇仍在、`MAC_ST` 仍不清**

动机：我们的序列里有 coex 调度簇（`timer_setfn` 连发 + `coex_schm_interval_set`），IDF 侧没有——
怀疑是"我们的 coex 桩一律返回成功"让 blob 走了 coex 分支。把 `shellCoexInit` 改成返回 `1`（仍调用真 `coex_init()`，只改返回值）：

```text
wifi-init-probe: INITWIN qsend=1 qrecv=2 rstmac=0 clken=1 semcreate=2 semnull=0
wifi-init-probe: INIT OK, arena free=312168/350352 B, bad_handle=0, blocking_refused=4
（timer_setfn / coex 相关条目仍有 16 条）
wifi-init-probe: MAC_ST after init = 0x0000e000
panic 0
```

⇒ **三态判据落在第二态**：**coex 簇不消失、`MAC_ST` 不清、init 照常成功**
⇒ **`coex` 是旁支，不是门闩**（blob 容忍 `coex_init` 失败并照常走完 init）。

⇒ 开关已翻回 `false`（默认路径不变）。
⇒ 至此"coex 分支"假设也排除 —— 与 osi 层同构的结论一致：那条 `4` 本来就是标签错位，不是行为差异。

### 排除：`.data` 初始化不是缺口（镜像段核对）

怀疑过一条：我们的 `start.zig` 步骤 ①–⑥ 里**只有清 `.bss`、没有显式 `.data` 拷贝**——
若 blob 的已初始化全局变量因此是垃圾，它的状态机就可能走不同分支。

核对镜像段（`esptool image-info`）：

```text
Segments: 5
  1  0x000a8  0x2f000000  DRAM/IRAM
  2  0x0cbe0  0x2f0000b0  DRAM/IRAM
  4  0x081f0  0x2f00cc90  DRAM/IRAM     ← 0x2f00cc90 + 0x81f0 = 0x2f014e80
```

而 `.data` 在 ELF 里是 `VMA 0x2f00f660`、size `0x5820` ⇒ `0x2f00f660 + 0x5820 = 0x2f014e80` **正好等于段 4 的终点**。

⇒ **`.data` 确实被打进 flash 镜像（段 4），并由 IDF 二级 bootloader 拷到 RAM** ⇒ **不是缺口**。
⇒ `.bss` 由我们的 `start.zig` 步骤 4 清零，也在镜像的 `memsz > filesz` 覆盖范围内 ⇒ 同样没问题。

⇒ 这条也排除（清单扩到 **15 条**）。

## 收口补记：两条后加的判负（2026-11-17）

上面那份 `.data` 记录写成"清单扩到 **15 条**"是**当时时点**的计数，保留不动。此后又判负两条，
本节只登记这两条并指回各自的证据节（**权威的完整清单在博客侧 `ch25` 的「已排除的假设」表**；
本 ADR 按实验分组记录，不维护同一套编号，两者粒度不同，不要互相换算）：

| 后加项 | 判负方式 | 本 ADR 中的证据节（标题原文） |
| --- | --- | --- |
| IDF `before_init` 全表 diff | 唯一差异 `f018`（LPCON `clk_conf`），对齐后读回仍是 4 ⇒ 仍不清 | `判决：before_init 全表已与 IDF 完全一致（含 MAC 块），MAC_ST 仍不清` |
| 定时器路径 | 弱观测：`setfn` 14 / **`arm`·`arm_us`·`fire` 均 0**（本 ADR 记录的三个计数；`disarm` 7 见博客 ch25 的同名表）；**强判决**：`forceArmAll()` 后 14 个回调全部 fire ⇒ 状态机不推进、`MAC_ST` 不变 | `定时器计数复测（当前构建）：setfn 14 次、arm 0 次、fire 0 次`；`软件定时器：固件里从未接过 serviceTimers() —— 但 blob 也从未 arm`（含其"判决实验"段） |

⇒ 定时器一条的判据取 **force-arm 强判决**，不是"从未 arm"这个较弱观测——后者在 §软件定时器 里已排除过，
单列会变成重复计数。

## ★★★★ 根因与修复（2026-11-25）：缺的是 IDF `pmu_init()` 里的 modem ICG 码

上面所有判负有一个共同前提：时钟位都开了、门控位图也写了，`MAC_ST[15:13]` 就是不清。这一节换方法——
不再猜"缺哪一步"，而是与官方 IDF 在**同一个时点**做**全量**寄存器对照。此前只对照过 11 个时钟寄存器、
MAC 块校验和与 hp1e0，全部相同，说明差异不在那 11 个里。

### 方法

- oracle（`tools/wifi-idf-oracle/`）加 `CONFIG_ORACLE_REGDUMP`：`esp_wifi_init` 之后把 SoC 头文件里定义过的
  523 个寄存器（12 个外设块，只读）各读一遍，连同 `MAC_ST`（0x20104CAC，blob 私有，不在头文件里）。
  日志 `logs/wifi-idf-oracle-regdump-boot.log`：`REGDUMP after-init begin n=523 mac_st=00000000`。
- 探针侧加同一个 dump（`init_probe.zig` 的 `regDumpAll`，地址表 `regdump_addrs` 与 oracle 的
  `main/regdump_addrs.h` 逐项相同；`probe_regdump = true` 时打印，约 1.4 秒串口时间）。
  日志 `logs/wifi-probe-regdump-before-boot.log`（修复前）：`REGDUMP after-init begin n=523 mac_st=0000e000`。
- 两份日志按地址配对做差，523 对 523，无缺失。

### 差集

**95 个不同**。按外设块：PMU 50、HP_SYS_CLKRST 23、HP_ALIVE_SYS 7、MODEM_LPCON 4、LP_ANA 3、
LP_PERICLKRST 3、LP_SYS 2、I2C_ANA_MST 2、LP_AONCLKRST 1。时钟相关寄存器一个都不在差集里：
`MODEM_SYSCON` 的 `CLK_CONF` / `CLK_CONF1` / `RST_CONF`、`HP_SYS_CLKRST` 的 `REF_*M_CTRL` 与 `modem_conf` 全部相同。

### 移植实验：有 77 个可以安全地照抄，全抄了也没用

排除稳压器电压档、PHY 模拟状态（`I2C_ANA_MST`，init 路径自己会写）、本固件在用的定时器组、CPU 与核 1 的
频率/复位控制、状态寄存器之后，剩下 77 个在 init 之前按 IDF 值写入（读回全部一致、不崩）：

| 实验 | 动作 | init 之后 `MAC_ST` | `esp_wifi_start` | 日志 |
| --- | --- | --- | --- | --- |
| 1 | 只在 init 之前写 `MODEM_LPCON_CLK_CONF_POWER_ST = 0x66660000` | `0x0000e000` | 不返回 | `logs/wifi-probe-exp1-lpcon-power-st-boot.log` |
| 2 | 去掉 `_wifi_clock_disable` 里的 `LPCON+0x20 = 0` | `0x0000e000` | 不返回 | `logs/wifi-probe-exp2-no-icg-clear-boot.log` |
| 3 | 2 + 只写 PMU 的 modem ICG 码（active=2、modem=1），不触发更新 | `0x0000e000` | 不返回 | `logs/wifi-probe-exp3-pmu-icg-code-boot.log` |
| 4 | 77 个全部按 IDF 值写入（含 PMU 各模式的配置） | `0x0000e000` | 不返回 | `logs/wifi-probe-exp4-transplant-all-boot.log` |
| 5 | 4 + 触发两次"立即更新" | **`0x00000000`** | **返回 0** | `logs/wifi-probe-exp5-pmu-imm-update-boot.log` |

实验 1 的读数本身有信息量：写进去的 `0x66660000` 在 init 之前的 dump 里读得回来，init 之后又变回 0——
是 `_wifi_clock_disable` 自己清的（实验 2 去掉那一行之后读回就是 `0x66660000`）。实验 4 之后再做一次全量
dump，与 oracle 的差集从 95 降到 18，剩下的是被排除的那些（`logs/wifi-probe-exp4b-transplant-all-dump-boot.log`）。

### 收窄：必要且充分的是「写码 + 触发更新」

| 实验 | 动作 | `MAC_ST` | `esp_wifi_start` | 日志 |
| --- | --- | --- | --- | --- |
| A | 只移植 PMU 的 `HP_ACTIVE` + `HP_MODEM` 两组（19 个寄存器）+ 触发 | `0x00000000` | 返回 0 | `logs/wifi-probe-expA-pmu-groups-imm-boot.log` |
| B | 只写两个 ICG 码 + 触发 | `0x00000000` | 返回 0 | `logs/wifi-probe-expB-icg-codes-imm-boot.log` |
| C | 只触发（码仍是 0/0/0） | `0x0000e000` | 不返回 | `logs/wifi-probe-expC-imm-only-boot.log` |
| — | 写码 + 触发两次（模拟热复位后 `initModemIcg()` 再跑一次） | `0x00000000` | 返回 0 | `logs/wifi-probe-exp-warm-twice-boot.log` |

### 机理

`modem_clock_module_enable()` 先做 `modem_clock_module_icg_map_init_all()`，给每个 modem 时钟域写一张 4 位的
门控位图（`MODEM_SYSCON` / `MODEM_LPCON` 的 `CLK_CONF_POWER_ST`，各域 `0x6`）。位图的**每一位对应一个码**：
`ICG_NOGATING_ACTIVE = BIT(PMU_HP_ICG_MODEM_CODE_ACTIVE)`、`ICG_NOGATING_MODEM = BIT(PMU_HP_ICG_MODEM_CODE_MODEM)`
（`modem_clock_impl.h:149-151`），码值是 `SLEEP=0` / `MODEM=1` / `ACTIVE=2`（`pmu_types.h:34-36`）。
PMU 当前处于哪个电源模式，就拿那个模式的 `DIG_ICG_MODEM_CODE` 去查位图；位图里没有这个码，该域就被门控。

这三个码是 IDF 启动期写的：`esp_rtc_init()` 调 `pmu_init()`（`esp_system/port/soc/esp32s31/clk.c:47-52`），
`pmu_hp_system_init()` 对 ACTIVE / MODEM / SLEEP 各写一次，每写完一个模式就触发
`pmu_ll_imm_update_dig_icg_modem_code(true)` 与 `pmu_ll_imm_update_dig_icg_switch(true)`（`pmu_init.c`）。
我们的镜像由 IDF 二级 bootloader 加载后直接进应用，这一步没人做：三个码停在复位值 0，位图 `0x6` 里没有码 0。
于是 `CLK_CONF1.clk_wifimac_en` 是 1，Wi-Fi MAC 的核却没在跑，`MAC_ST[15:13]` 停在复位值。

这解释了本 ADR 里的两类判负：写位图本身试过两次（「逐域 ICG map 实验」「LPCON 的逐域 ICG」），写对了但码对不上，
等于没写。写码而不触发更新也不生效：实验 4 的全量 dump 里 `PMU_CLK_STATE0` 读回 `0x91080002`
（`ICG_MODEM_CODE_STATE` 仍是 0，oracle 是 `0x91580002`）；触发之后才读到 `0x91580002`（实验 5）。

### 修复

- `boards/esp32s31-coreboard/src/pmu.zig`：`initModemIcg()` 给三个 HP 电源模式写码（2 / 1 / 0）并按 IDF 的顺序
  触发两次立即更新，写完读回校验；`modemIcgCode()` 读回生效的码。序列照抄 IDF，出处与实测表在文件头。
- `init_probe.zig` 的 `initOnly()` 开头调用，与 `hw.initTimer()` 同类（镜像不做 IDF 的启动初始化，板级前置条件
  由这里补）。探针与合并镜像都走这里。
- `_wifi_clock_disable` 按 IDF 源码补齐两处：清 `clk_coex_en`（此前漏了，init 之后 `LPCON+0x18` 读回 3 而 IDF 是 1）、
  不在 disable 时打 `rst_wifibb` 脉冲（IDF 只在 enable 时复位）。旧注释说"按 IDF 的反向顺序"不对，
  IDF 两次是同一顺序，注释已改。
- 实验用的一次性开关与移植表已删；全量 dump（`probe_regdump`）留作对照工具。

### 板上证据（2026-11-25）

Wi-Fi 探针（`logs/wifi-probe-start-rc0-boot.log`）：

```text
wifi-init-probe: pmu modem ICG code 0->2 (2 = active)
wifi-init-probe: after-init MAC_ST=0x00000000 (init_rc=0)
wifi-init-probe: INIT OK, arena free=263320/301504 B, bad_handle=0, blocking_refused=4
wifi-init-probe: esp_wifi_start rc=0x0 (idle_calls=22)
```

init 之后与 oracle 的 dump 逐位相同的时钟寄存器：`MODEM_SYSCON.CLK_CONF_POWER_ST = 0x64646400`、
`MODEM_SYSCON.FORCE_ON = 0x00000000`、`MODEM_LPCON.CLK_CONF = 0x00000001`（修复前是 3）、
`MODEM_LPCON.CLK_CONF_POWER_ST = 0x66660000`（修复前是 0）。修复后的全量 dump
（`logs/wifi-probe-fix-regdump-boot.log`）与 oracle 的差集从 95 降到 90，时钟相关寄存器全部相同；
剩下 90 个是 IDF 启动初始化的其余部分（外设时钟使能、稳压器电压档、睡眠配置等），实测不影响 init 与 start。

合并镜像（`logs/coex-merged-pmu-icg-boot.log`）：`read: LPCON+18 after wifi init=0x00000001`、
`bt bringup: INITED`、`check: coex sides wifi=inited ble=inited (both inited) ok=1`、`main: verdict=pass`。
主机门禁 `scripts/check-all.sh` 各步通过；量产镜像 `run_e2e.py --board --profile net` 输出 `PASS board:net`、
`firmware: sections: passed=8 failed=0 total=8`。

### 一条负结果：BLE 侧不能照搬

把同一个调用加进 BLE 探针（`bt.probe.initOnly` 与 `run()`）后，镜像 45 秒内两次
`rst:0x1a (CPU_LOCKUP_RESET)`，第一次启动没走到 `INITED`（`logs/bt-probe-pmu-icg-lockup-boot.log`）；
关掉这一调用、其余完全相同的对照镜像与入库基线一致（`INITED`、8 条 `bt-blob-strong-assert`，
`logs/bt-probe-pmu-icg-control-boot.log`）。**BLE 侧的调用已撤回，`bt-blobs` 没有改动。**

| 启动 | 调用前（switched, code） | 调用后 | 结果 |
| --- | --- | --- | --- |
| 1（冷启动） | `false, 0` | `true, 2` | 共存核 boot 处锁死 |
| 2（热启动） | `true, 2` | `false, 2` | `INITED`，之后锁死 |
| 3（热启动） | `false, 2` | `true, 2` | `INITED` |

表里的 `switched` 是 `PMU_CLK_STATE0.ICG_MODEM_SWITCH_STATE`，每应用一次更新序列翻转一次，与功能无关
（Wi-Fi 侧两种取值下 init 与 start 都通过，见上表最后一行实验），所以现在不读它。第 1 次与第 3 次启动结束状态相同、
结局不同，差别在冷启动时各域的 ICG 位图还是复位值 0，热启动保留了前几次写入的位图。
`bt-blobs/src/porting.zig` 的 2.9 节早先在码还是 0 的时候试过 ICG 应用触发、判成"核坍缩触发件"后拔掉，与此一致。
合并镜像里 BLE 的 `bringup.init` 是在 ICG 已生效（Wi-Fi 侧先做了）的状态下跑的，照样 `INITED`——
出问题的是 BLE 探针 `INITED` 之后的实验流程。**未验证**：BLE 在 init 之外（enable、广播、连接）于 ICG 生效下的行为，
属于 R3.3，单独分析。

### 仍未验证

- 扫描、连接、收发：`esp_wifi_start` 返回之后还没有往下走（需要 `on_idle` 接 EMAC 收发与事件循环）。
- `pmu_init()` 的其余部分没做，包括稳压器电压档（IDF 的 `REGULATOR_DBIAS` 是 26，我们是 24；这个 24 是谁写的没有查）。
  需要调压或睡眠时按 `pmu_param.c` 补。
