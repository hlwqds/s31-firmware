# osal — 任务/调度器 + 同步原语

原本长在 `components/bt-blobs` 里、只服务 BLE controller 的 OSAL，2026-11-18 抽成独立组件。
抽出动机只有一个：**POSIX 兼容层**（`components/posix-compat`）要建在同一套原语上，
而不是再造一份内核。

## 内容

| 文件 | 作用 |
| --- | --- |
| `src/sched.zig` | 协作式调度器：`taskCreate(stack, entry, arg)`、`currentContext`、上下文切换（唯一一处 `asm`） |
| `src/osal.zig` | `semInit/Pend(timeout)/Release/GetCount/Deinit`、`mutexInit/Pend(timeout)/Release/Deinit`、`eventqPut/Get(timeout)`、`calloutInit/Reset`、临界区嵌套、时间与随机数 |
| `src/coex_hooks.zig` | 共存核回调 OS 层的 18 个适配钩子（`-Dcoex` 时由 BLE 侧接线层取用）：信号量走本组件的池，内存走 `btdmMalloc`，`ets_timer` 是软件定时器侧表 |
| `src/probe_ptr.zig` | 调试用的指针探针 |
| `src/api.zig` | 模块根（转出口 + `forceExports()`，见下） |

## 归档核对记录（从 bt-blobs 迁来时保留）

`osal.zig` 持 **59 个 C ABI 导出**给 BLE controller 归档用。逐项核对过两处清单：

| 来源 | 数量 | 说明 |
| --- | --- | --- |
| `bt-blobs/link/bt_stubs.c` 的 `BT_STUB_LIST` 宏 | **36** | controller 会调、由我们提供 |
| `bt-blobs` 各文件里的 `export fn` | **11** | 我们自己发的（`s31_*` 等） |
| 其余 | 12 | coex / 日志 / 时间等基础钩子（其中 11 个 `wr_btdm_coex_*`；开 `-Dcoex` 时另发 5 个，共 16 个） |

迁移只改了文件的**位置**，导出符号与签名未动 —— 闭包链接的镜像大小搬前搬后逐字节相同
（913728 B）就是这一点的执行证据。

## 依赖面：零 `board`

只有 `std` + `builtin`。时间、临界区、随机数都是**注入钩子**：

```zig
hooks.now_ms / hooks.irq_save / hooks.irq_restore / rand_hook
```

所以整套语义能在主机上跑（**29 项**用例：原有 21 项，加共存钩子 8 项），板级只需在启动时把钩子接到真实实现。

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

## 日志钩子的地址门（2026-11-24 改）

`osal.logLine` 只调用落在可执行区里的日志钩子（防止归档把 `hooks` 结构体写坏后调用垃圾地址）。
可执行区 = 链脚本的 `_text_start .. _text_end` 加 ROM 的 `0x2f80_0000 .. 0x2f85_0000`。
以前这里写死成 `0x4000_0020 .. 0x400A_0300`（某一次构建的实测值）：镜像一大（两个射频同链的合并镜像
text 约 826 KB），排到上界之外的日志钩子会被整段丢弃，而且不报错。主机测试里没有链接符号，只排除空指针。

## 与 Wi-Fi 同链时的两处约定（`-Dcoex-merged`）

- `-Dcoex` 时的 `s31_coex_log_hook` 以**弱符号**导出：合并镜像里共存库的日志行走 Wi-Fi 侧的钩子；
  只链 BLE 时没有别的定义，行为不变。
- 本组件的调度器（`src/sched.zig`）与 `wifi-blobs/src/sched.zig` 的切换原语机器码相同（链接器把它们折到
  同一地址），各存各的主栈指针。两个射频的 init 顺序是「主 → Wi-Fi 任务 → 主 → BLE 任务 → 主」，不嵌套，
  所以没有把两边合并成一个调度器；依据与取舍见 `docs/verification/coex-verification.md` §6.3。

## 验收

```bash
cd firmware && zig build test --summary all   # 本组件 29 项（osal 21 + 共存钩子 8）
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
