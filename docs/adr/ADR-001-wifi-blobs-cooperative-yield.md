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
  `on_budget_exhausted`），固件侧接线。

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

它一次都不经过我们的信号量/队列钩子，即**在 blob 内部忙等**一个由 wifi 任务设置的标志。
反汇编确认 `wifi_init_completed` 只读状态字（不等待）、`esp_wifi_start` 先 `_wifi_zalloc`
（表 index 93）再 `ieee80211_ioctl`，所以卡点在 ioctl/状态机内部。

**结论**：合作式让出能覆盖「阻塞在 OS 原语上」的一切路径（init、`reg_rxcb`、
`get_config_channel` 都已实测通过），但覆盖不了「blob 自己 spin」的路径。

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
