# components/wifi-blobs — 真实 Wi-Fi blob 的 osi 适配层

把 IDF 的预编译 Wi-Fi 归档（`libnet80211.a` / `libpp.a` / `libcore.a` / `libphy.a` …）链进
本仓库的两段镜像，并提供 blob 需要的整套 OS 适配层（`wifi_osi_funcs_t`，S31 上 128 个字段）。

> 所属章节：`content/zig-esp32-s31/ch25-wifi-blob-boundary.md`（章节 25.12.5 记录本节结论）

## 验证状态

| 级别 | 结果 | 证据 |
| --- | --- | --- |
| 主机测试 | **31/31**（26 个原有用例 + 共存钩子 4 个 + 替身 1 个） | `tests/baselines.json` → `wifi-blobs: 31`。此前这个组件没有测试目标，26 个用例从没被跑过，测试文件也编不过；2026-11-24 补了目标并修好 |
| 板侧 init | `esp_wifi_init_internal rc=0` | `logs/wifi-init-ok-boot.log` |
| 板侧任务 | 任务体执行自己的循环并合作式让出 | `logs/wifi-task-boot.log` |
| 共存核（`-Dcoex`） | 共存库自己打出两行版本；`wifiInit rc=0`；`esp_wifi_init_internal rc=0`；`g_coex_param_ptr=0x2f01173c`（不开时为 0） | `logs/coex-wifi-probe-boot.log`；对照 `logs/coex-wifi-probe-control.log` |
| 扫描/连接 | **未做** | 需要 `on_idle` 接 EMAC 收发 |

## 用法

```zig
const impl = @import("wifi-blobs").osi_impl;

impl.initArena(heap[0..len]);              // 链接脚本 _heap_start.._heap_end
impl.setHooks(.{
    .now_us = &nowUs,                       // 单调微秒
    .fill_random = &fillRandom,             // TRNG
    .mac = &mac,                            // 出厂 MAC
    .on_idle = &mainLoopPoll,               // ★ 阻塞等待时的让出点（见下）
    .on_budget_exhausted = &onBudget,       // 诊断：钩子预算归零
});
osi_table = impl.makeTable();               // 必须是静态对象
var cfg = init_config.defaults(&osi_table);
_ = esp_wifi_init_internal(&cfg);           // 只能调用一次
```

## `Hooks`：组件不 import 板级代码

| 字段 | 作用 | 为 null 时 |
| --- | --- | --- |
| `now_us` | 单调微秒（RTO、超时、`_esp_timer_get_time`） | 时间恒 0，所有超时判定失效 |
| `fill_random` | 随机数（blob 的 nonce/序列号） | 填 0，安全性失效但能跑 |
| `mac` | 出厂 MAC | 全 0 |
| `on_idle` | **阻塞等待时的让出点**，调用方在这里跑主循环（收包/发送） | 等待退化成忙等：任务体占满 CPU，主循环拿不到执行权 |
| `on_note` | **每次**钩子调用都回调（逐行追踪某个阶段的调用序列） | 无 trace，只能看计数 |
| `on_budget_exhausted` | `impl.budget` 归零时回调（诊断用） | 无刹车 |

### 为什么 `on_idle` 是中心契约

blob 的任务体是「阻塞收消息 → 处理 → 循环」，而本固件没有调度器（MIE=0、单栈）。
`OSI_FUNCS_TIME_BLOCKING` 的等待因此实现为**让出后重试**：

```zig
while (spins < idle_spin_limit) : (spins += 1) {  // 上限 64
    if (hooks.on_idle) |idle| idle();             // 主循环在这里跑
    if (self.count != 0) break;
}
```

两条必须记住的事实：

1. **任务体永不返回**。调用 `entry(arg)` 之后就再也回不到调用点，所以调用方必须自带
   让出点与刹车（探针用 `on_idle` 计数到 200 停机）。
2. **init 自己也会阻塞**，所以让出语义必须对 init 路径同样正确——判据是 `rc` 仍为 0。
   决策记录见 `docs/adr/ADR-001-wifi-blobs-cooperative-yield.md`。

## 两根栈：`src/sched.zig`

blob 的 API 会阻塞等待任务应答，而任务体永不返回——同一根栈上无法共存。`sched.zig` 提供
最小上下文切换（保存/恢复 `sp, ra, s0..s11`），让主上下文继续调 API、任务体在自己的栈上跑，
阻塞时切回主上下文。

```zig
var main_ctx: sched.Context = .{};
var task_ctx: sched.Context = .{};
sched.initContext(&task_ctx, &static_stack, &taskEntry, null);
sched.start(&task_ctx, &main_ctx);     // 进入任务；任务让出后从这里继续
```

三条实现约束（都踩过）：

1. 切换函数**必须 naked**（普通函数的前导会让保存的帧基址与 `ret` 错位 N 字节）；
   Zig 不允许直接调用 naked 函数，所以 `@export` + `@extern` 间接调用。
2. 初始 `sp` 用 `alignBackward`：`alignForward` 会越过分配区间、踩坏相邻 arena 块头。
3. arena 只接受自然对齐请求；要 16 字节对齐的栈就申请 8 字节对齐，栈顶自己对齐。

板侧自检：`logs/wifi-sched-boot.log`（任务 3 轮让出 → `sched-test: PASS`）。

## 文件职责

| 文件 | 作用 |
| --- | --- |
| `src/osi.zig` | `wifi_osi_funcs_t` 的 Zig 镜像（128 字段，comptime 断言 size/偏移） |
| `src/osi_impl.zig` | 适配层实现：arena 分配器、信号量/互斥/队列、任务表、事件组、NVS RAM 版、`Hooks` |
| `src/osi_stubs.zig` | 未实现钩子的**具名桩**（只填空字段，绝不覆盖已实现项） |
| `src/init_config.zig` | `wifi_init_config_t` 默认值（含 `wpa_crypto_funcs.size = 52`） |
| `src/init_probe.zig` | 板侧探针：装表 → 构造 config → init → 跑一次任务体（`-Dwifi-init-probe=true`） |
| `src/coex_hooks.zig` | 共存核回调 OS 层的 18 个适配钩子（`-Dcoex`），全部转给 `osi_impl.zig` 已有的壳 |
| `src/host_stubs.zig` | 主机测试用的 5 个板级符号替身（ROM / PHY / 共存库入口），不进任何镜像 |
| `src/sched.zig` | 两根栈的合作式上下文切换（naked `s31_swap_context`） |
| `src/sched.zig` | 32 位帧的 `initContext`（主机用例覆盖）+ 目标门控的 naked 切换 |
| `src/host_tests.zig` | 主机测试入口（本文件 26 个用例；组件合计 31 个） |

## 待验证项

- **PHY（已解锁）**：`register_chipv7_phy` 现在**返回**（`rc=1`）。关键是把 `SYSCON_FORCE_ON`
  (0x20109C08) 的 `0x1c`（WIFI_APB/FE/FE_APB）与 `LPCON_FORCE_ON` (0x2010F01C) 的 `WIFIPWR_FO`
  设上——使能位不等于上电；`CLK_CONF_POWER_ST` 读 0 不是判据。
  诊断纪律：**不要手工乱序调用 ROM 的 PHY 函数**（会得到假的空指针故障），跑真实路径。
- `esp_wifi_start`：取锁 + `zalloc(24 B)` + `event_post(id=43)` 之后自旋，不投队列；需要定时器中断
  抢占（`MIE=0` 现状）或 post 型入口。
- 当前故障：PHY 之后出现 `illegal instruction`（`mepc=0x2f01c9d4`，SRAM；`ra=0x40017876`）——
  `0x40017874: jalr a5` 通过上下文里的函数指针调用，而该指针落在 arena 范围。
- `on_idle` 接 EMAC：收包 → `esp_wifi_internal_reg_rxcb` 注册的回调；发送走 `esp_wifi_internal_tx`。
- 扫描/连接：需要 `esp_wifi_connect` / `esp_wifi_disconnect` 等 IDF 侧符号的桩。

已完成（此前列在这里）：任务体跑在**自己的静态栈**上（`sched.zig`，`sched-test: PASS`）；
`_task_delay` 已按"让出 + 计时"实现。
