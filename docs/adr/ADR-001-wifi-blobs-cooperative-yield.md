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

`phy_get_xtal_freq`/`phy_get_rf_cal_version` 仍返回，但 **`phy_rf_init` 依旧自旋**。
这组依赖里剩下未开的是 `I2C_MASTER` 的 REGI2C 模拟时钟（`ANALOG_CLOCK_ENABLE()`，
`modem_clock_impl.c:229`），以及 `PERIPH_PHY_CALIBRATION_MODULE` 的独立组
（WIFI_APB/WIFI_BB/BB_44M/BB_80X1）。

**更正（此前写错）**：S31 **有**调制解调器寄存器头，位置是
`components/soc/esp32s31/include/modem/`（不是 `register/soc/`）：
`MODEM_BASE=0x20100000`、`MODEM_PWR_BASE=0x2010D000`、`DR_REG_MODEM_LPCON_BASE=0x2010F000`、
`DR_REG_MODEM_SYSCON_BASE=0x20109C00`。另外 `0x20162824` 是给 PHY 的 I2C master 用的
**RF 寄存器地址**，不是 CPU 地址——从 CPU 读它会 load access fault（已实测 `mtval=0x20162824`）。

另一条独立可能：PHY 标定本身可能依赖中断（`MIE=0` 下永远等不到），这与 §"定时器中断抢占"
是同一件事的两面——先做电源域/时钟，若仍挂起，再开中断路径。
