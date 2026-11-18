# osal — 任务/调度器 + 同步原语

原本长在 `components/bt-blobs` 里、只服务 BLE controller 的 OSAL，2026-11-18 抽成独立组件。
抽出动机只有一个：**POSIX 兼容层**（`components/posix-compat`）要建在同一套原语上，
而不是再造一份内核。

## 内容

| 文件 | 作用 |
| --- | --- |
| `src/sched.zig` | 协作式调度器：`taskCreate(stack, entry, arg)`、`currentContext`、上下文切换（唯一一处 `asm`） |
| `src/osal.zig` | `semInit/Pend(timeout)/Release/GetCount/Deinit`、`mutexInit/Pend(timeout)/Release/Deinit`、`eventqPut/Get(timeout)`、`calloutInit/Reset`、临界区嵌套、时间与随机数 |
| `src/probe_ptr.zig` | 调试用的指针探针 |
| `src/api.zig` | 模块根（转出口 + `forceExports()`，见下） |

## 依赖面：零 `board`

只有 `std` + `builtin`。时间、临界区、随机数都是**注入钩子**：

```zig
hooks.now_ms / hooks.irq_save / hooks.irq_restore / rand_hook
```

所以整套语义能在主机上跑（**20 项**用例），板级只需在启动时把钩子接到真实实现。

## ⚠️ `forceExports()` 必须由消费者调一次

```zig
// api.zig 提供
pub fn forceExports() void { _ = &osal.timeGet; }

// 消费者（如 bt-blobs/src/root.zig）在 comptime 调
comptime { @import("osal_kit").forceExports(); }
```

`osal.zig` 里有 5 个 `export fn`（`s31_now_us`、`s31_btdm_malloc/free`、`s31_phy_log`、
`s31_bt_log_hook`）供 C 侧桩调用。Zig **只在文件被分析时才发射 `export`**，而 `api.zig`
只是转出口 —— 没有这行引用，`bt_core.o` 会变成 **0 符号**对象，BLE 归档的闭包链接报
5 个未定义符号。

> 为什么开关不能只写在 `api.zig` 的 `comptime` 块里：模块是**惰性**编译的，消费者只写
> `pub const osal = @import("osal_kit").osal` 时 `api.zig` 不会被分析，里面的 comptime 也不跑。
> 实测：把开关搬进 `api.zig` 一次、删掉消费者那次调用 → 闭包链接立刻报 5 个未定义；
> 消费者调 `forceExports()` 后恢复，镜像 913728 B（搬出前后**逐字节同尺寸**）。

## 验收

```bash
cd firmware && zig build test --summary all   # 本组件 20 项（含 osal 17 + sched 2 + 聚合 1）
scripts/check-bt-link.sh                      # 链接验收（需 IDF 树；不在 check-all 里）
```

`scripts/check-bt-link.sh` 是"改动本组件"的兜底：主机用例只覆盖纯逻辑，**改错 import
只有真链接才暴露**。它做三步：生成闭包 → 用闭包链接 → 断言镜像 > 500 KB。

## POSIX 映射（给 `components/posix-compat` 用）

| POSIX | 本组件 |
| --- | --- |
| `sem_init/destroy/post/getvalue/wait/trywait/timedwait` | `semInit/semDeinit/semRelease/semGetCount/semPend(timeout)` |
| `pthread_mutex_init/destroy/lock/trylock/timedlock/unlock` | `mutexInit/mutexDeinit/mutexPend(timeout)/mutexRelease` |
| `pthread_create`（部分） | `sched.taskCreate`（调用方提供栈；无 join/detach） |
| `mq_send/receive` | `eventqPut/eventqGet(timeout)`（槽位式，不是字节流） |
| `timer_create` | `calloutInit/calloutReset(ticks)` |
| `pthread_self` | `sched.currentContext` |

**尚缺**（POSIX 层要新写）：`pthread_join/detach`、`pthread_cond_*`（`eventq` 是信号量语义，
不是条件变量）、每任务 `errno`。
