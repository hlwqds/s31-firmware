# posix-compat — 在我们的系统上提供 POSIX 形状的接口

本文是**梳理**：POSIX 的那些接口，我们已有的对应物是什么、缺口在哪、这一版做哪一段。
代码在同目录 `src/`，逐层落地，每层都有主机用例。

## 1. 现状盘点（2026-11-18）

| 层 | 在哪 | 形态 |
| --- | --- | --- |
| **生产 OSAL：任务 + 调度器** | `components/bt-blobs/src/sched.zig`（310 行） | `taskCreate(stack, entry, arg)`、`currentContext`、`start`；协作式，已被 BLE blob 使用 |
| **生产 OSAL：同步原语** | `components/bt-blobs/src/osal.zig`（1636 行） | `semInit/semPend(timeout)/semRelease/semGetCount/semDeinit`、`mutexInit/mutexPend(timeout)/mutexRelease/mutexDeinit`、`eventqPut/Get(timeout)`、`calloutInit/Reset`（软件定时器） |
| 生产 Wi-Fi OSAL | `components/wifi-blobs/src/osi_impl.zig`（1567 行） | Wi-Fi blob 的 osi 表实现（事件/定时器/锁），形状由 blob ABI 决定 |
| 教学内核 | `practice/zig-esp32-s31/ch10/ch11/ch12` 的 `sched/mutex/sem/events/queue/spin` | 抢占 + 优先级继承的**教学**实现 |
| socket 层（fd 表、状态机、errno 语义） | `s31-firmware/components/net-sockets` | **已是生产组件**，`Table` + `Socket` + `Io{err,n}` |
| 时间基准 | `ch08`/`ch12` 的 tick（1 ms 周期） | lab 内；生产侧是 TIMG0（`hw.nowUs`） |
| C 库 | 无 libc，ROM 提供 `memcpy`/`printf` 等 | 无 POSIX 头文件 |

关键观察（**2026-11-18 更正**）：本文件第一版写"内核只活在 lab 里"是**错的**。
`components/bt-blobs` 里已经有一套**生产级 OSAL**，而且它比教学内核更贴近 POSIX：

| POSIX | `bt-blobs` OSAL | 差距 |
| --- | --- | --- |
| `sem_init/destroy/post/getvalue/wait/trywait` | `semInit/semDeinit/semRelease/semGetCount/semPend(timeout)` | **几乎 1:1**，且 `semPend` 已支持超时（`sem_timedwait` 不用另造） |
| `pthread_mutex_init/destroy/lock/unlock/trylock` | `mutexInit/mutexDeinit/mutexRelease/mutexPend(timeout)` | 同上；超时已在 |
| `pthread_create` | `sched.taskCreate(stack, entry, arg)` | 缺 join/detach；调用方要自备栈 |
| `mq_send/receive` | `eventqPut/eventqGet(timeout)` | 槽位式（`*Slot`）而非字节流 |
| `timer_create` | `calloutInit/calloutReset(ticks)` | 固定周期，无 `itimerspec` |
| `pthread_self` | `sched.currentContext` | ● |

而 socket 层已经用 POSIX 的 errno 词汇（`again`/`bad_fd`/`not_conn`/`conn_reset`/`pool_full`/
`in_progress`）和 `Io{err,n}` 结果 ⇒ 兼容层两半**都是薄适配**，不是重新实现。

⚠️ 但这两套 OSAL **现在只服务各自的 blob**：作为组件私有文件存在，模块根是各自的 `selftest.zig`。
复用它们需要先把 OSAL/sched 抽成独立组件（见 §6）。

## 2. 映射表

`● 已有，直接包` / `◐ 已有但语义要补` / `○ 缺，本组件实现` / `— 明确不做`

### 2.1 进程与线程

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `pthread_create` | `thread.zig` → `sched.taskCreate` + 静态栈池 | ✅ 已完成（**上限 8 次/boot**，见下） |
| `pthread_join` | `thread.zig` → `Slot.done` + 每线程 `done_sem` | ✅ 已完成（重复 join / detach 后 join → `EINVAL`） |
| `pthread_exit` / `pthread_self` | `thread.zig` → `sched.currentContext()` / `sched.block()` | ✅ 已完成（主上下文 `self` 返回 `null`） |
| `pthread_detach` | `thread.zig`（完成时自己回收槽） | ✅ 已完成 |
| `fork` / `exec` / `waitpid` | — | — 单地址空间、无 MMU 进程模型，不做 |
| `getpid` | — | ○ 可返回固定值 |

### 2.2 同步

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `pthread_mutex_init/lock/trylock/unlock/destroy` | `sync.zig` → **令牌数 1 的 `osal.Sem`** | ✅ 已完成（**不是** `osal.Mutex`：它只忙等、不唤醒，见下） |
| `pthread_cond_init/wait/signal/broadcast` | **无** | ○ **要新写**：cond 必须与 mutex 配合、避免丢失唤醒 |
| `sem_init/wait/trywait/post/getvalue/destroy` | `sync.zig` → `osal.Sem` | ✅ 已完成（**限制**：同一 sem 上最多一个阻塞者，见下） |
| `sem_timedwait` / `pthread_mutex_timedlock` | — | ⌛ 内核只有**无限阻塞**；有限超时的 `semPend` 会立即返回，所以这两个返回 `ENOSYS`（不是假装超时） |
| `pthread_once` | `sync.zig`（CAS + 完成态自旋） | ✅ 已完成 |
| `pthread_rwlock_*` | — | — 本版不做（读者写者饥饿问题需要单独设计） |
| `pthread_spin_*` | — | ○ 待做（`std.atomic.spinLoopHint` 足够，但要知道它在单核上没有意义） |

> ⚠️ **单等待者限制**：`osal.Sem` 只有一个 waiter 槽。第二个线程在同一个信号量/互斥量上
> 阻塞会立刻拿到 `EAGAIN`（而不是排队）。多线程争用要在内核里加等待队列，本层不做。
>
> ⚠️ **勘误（2026-11-18）**：本表原先写的 `mutex.zig`（含 PI）/ `sem.zig` / `spin.zig` /
> `events.zig` 是 **lab 内核**的文件名，固件仓里**没有这些文件**。生产侧只有 `osal` 一套原语，
> 而且 `osal.Mutex` **不是**一把能阻塞的锁：`mutexPend` 只做 2M 次 `spinLoopHint` 的有界
> 忙等、`mutexRelease` 不唤醒等待者、Mutex 本身没有 owner/waiter 字段（它服务的是"不能真阻塞"
> 的归档上下文）。

### 2.3 时间

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `clock_gettime(CLOCK_MONOTONIC)` | tick 计数 / `hw.nowUs` | ○ 需要 `timespec` 与单位换算（注入 ns 时钟，便于主机测试） |
| `nanosleep` / `usleep` / `sleep` | tick 阻塞 | ○ 需要"睡到某个 tick"的阻塞等待 |
| `clock_getres` | 恒定 1 ms / 1 µs | ○ |
| `gettimeofday` | — | — 无墙上时钟（板子没有 RTC 校准源），不做；需要时由应用注入 |

### 2.4 fd 与 socket

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `socket(AF_INET, SOCK_STREAM, 0)` | `Table.alloc` + 状态检查 | ○ 要校验 family/type/proto 并记录地址 |
| `bind` | **无**（socket 层不存地址） | ○ 本组件维护每 fd 的 `sockaddr_in` |
| `listen` | `Table.listen` | ● |
| `accept` | `backlog` + `accept_token` | ◐ 需要非阻塞语义（`EAGAIN`）与阻塞等待（接上调度器） |
| `connect` | `Table.connect` + 线路侧握手 | ◐ 同上：非阻塞返回 `EINPROGRESS`，完成后再变可写 |
| `send` / `recv` | `Socket.send` / `Socket.recv` | ● 直接映射到 `ssize_t` + `errno` |
| `sendto` / `recvfrom` / `sendmsg` / `recvmsg` | — | — 只有 TCP，不做 |
| `shutdown` | `closeHalf` | ● |
| `close` | `Table.close` | ● |
| `read` / `write` | 同 `recv`/`send`（fd 都是 socket） | ○ 别名 |
| `select` / `poll` / `epoll` | `Table.readyRead` + 每 socket 的 `readable`/`writable` | ○ 本版提供 `poll`（单次、非阻塞）；`epoll` 不做 |
| `setsockopt` / `getsockopt` | — | — `SO_REUSEADDR`/`TCP_NODELAY` 无意义（我们只有一条连接、不聚合 Nagle），返回 `ENOPROTOOPT` |
| `fcntl(O_NONBLOCK)` | `Socket.nonblocking` | ● |
| 文件 I/O（`open`/`stat`/`fsync`…） | 无 VFS | — 不做（`ENOSYS`） |

### 2.5 错误

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `errno` 全局 | `net-sockets` 的 `Errno` 枚举 | ○ 本组件提供 `errno` 变量 + 双向映射（枚举值按 Linux 数值，便于与主机工具对照） |
| `strerror` | `Errno.name` | ○ |

## 3. 本版范围（可验证优先）

做：`errno` · `time`（clock_gettime/nanosleep/clock_getres）· `addr`（`sockaddr_in` 编解码 +
每 fd 地址表）· `fd`（socket/bind/listen/accept/connect/send/recv/read/write/shutdown/close/poll）

暂不做：线程与条件变量（需要把 ch10–ch12 的内核提成组件，是下一步）、`select`/`epoll`、
文件 I/O、`gettimeofday`。

理由：前三块**不需要内核**，可以全部用主机用例钉住（`net-sockets` 的 `Table` 是纯逻辑）；
线程/条件变量的正确性依赖真实调度器，应当在内核成为组件之后再接，否则只能靠假内核自说自话。

## 4. 分层

```text
应用
  ↓  POSIX 形状（int 返回 + errno）
posix-compat: errno | time | addr | fd
  ↓  组件接口（Io{err,n} / Table / Socket）
net-sockets（生产）        hw/tick（板级）
```

注入点（为了主机可测，全部做成参数而不是全局）：
- `time.zig`：`Clock = fn () u64`（纳秒）与 `Sleeper = fn (u64) void`
- `fd.zig`：`*socket.Table` 与地址表由调用方持有（无全局状态）

## 4.5 绑定决策（2026-11-18 定）

**直接依赖 `osal_kit`，不再造注入 port。** 当初 `time.zig` 用注入，是因为当时没有可复用的内核；
现在 `components/osal/` 零 `board` 依赖、20 项主机用例可驱动，直接 import 就是"在真内核上测真语义"，
§4 那句"假内核自说自话"的前提已经消失。注入点只剩 `hooks.now_ms` 这一项（时钟/睡眠）。

**`pthread_join` 不动 `sched.zig`。** 用包装层实现：每个线程配一个 `Slot`

```zig
const Slot = struct {
    done: std.atomic.Value(bool) = .init(false),
    sem: osal.Sem = undefined,
};
// trampoline 收尾：done = true; osal.semRelease(&sem);
// join：osal.semPend(&sem, timeout); 重复 join 读 done 直接返回
```

好处：`sched.zig` 保持原样（它只有 2 项用例，改内部必然要动上下文切换），而 join 的语义
（重复 join、对未启动线程 join、超时）**全在主机用例的射程内**。

## 5. 验收与登记方式

- 每层主机用例（`zig build test` 聚合进 `firmware/build.zig` 的 test step）：**41 项**
  （errno 3 · time 4 · addr 3 · fd 6 · **sync 13** · **thread 11** · 聚合块 1）；
- `tests/baselines.json` 里 `posix-compat: 41`；
- 板上验收留到接内核那一步（本版没有板级行为变更）。

**本组件只登记主机测试目标，不进镜像**（`firmware/build.zig` 里是单独的 `addTest`，不在
`all_modules` 里）。两个原因：

1. 本版没有板级行为变更 —— 没有 selftest 要跑；
2. 它依赖 `net_sockets` 模块，而 `net_sockets` 组件模块（`selftest.zig` 为根）与
   `api.zig` 为根的模块**包含同一批文件**；两者同时进镜像会撞 Zig 的
   "file exists in modules 'net_sockets' and 'net_sockets0'"。等接内核时把 socket 层的
   模块根统一（api 兼作组件根，并在 test 目标里特殊处理 `host_tests.zig` 的路径映射）再一起进。

## 6. 进度与剩余项

### 6.1 内核抽取（已完成 2026-11-18）

`components/osal/` = `api.zig` + `osal.zig` + `sched.zig` + `host_tests.zig`，**1959 行**，
零 `board` 依赖（`probe_ptr.zig` 在去耦那次退回 `bt-blobs` —— 它读的地址是 BLE 专有的）。
验收：`scripts/check-bt-link.sh`（116 个闭包对象、镜像 913728 B）。

| 步 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 建 `components/osal/`，搬内核两件 + 测试入口 | ✅ |
| 2 | `bt-blobs` 改为 `@import("osal_kit")` | ✅ |
| 3 | `posix-compat` 加 `sync.zig` / `thread.zig` | ✅ 41 项 |

### 6.2 线程层（已完成 2026-11-18）

`thread.zig`（11 项用例）：线程体跑完不能返回 —— trampoline 记返回值、置 `done`、
`sem_post` 唤醒 joiner，然后 `sched.block()` 永不返回；这个顺序安全的前提正是 `sched`
不回收任务槽（没人会再 resume 那个退出的任务，它的栈复用后不会有帧在跑）。

主机用例覆盖槽位分配/回收、重复 join、detach、`self` 在主上下文返回 `null`，
走的是 trampoline 收尾的**同一段** `complete()`，不是替身。

### 6.3 剩下的 ○（按价值排序）

| 项 | 阻塞点 | 代价 |
| --- | --- | --- |
| `pthread_cond_*` | `osal.Sem` 只有**一个** waiter 槽 ⇒ 条件变量必须自己维护等待队列 | 要么在 `osal` 加等待队列（改内核 + 重跑闭包门禁），要么在 `posix-compat` 用 `sched.block()/resumeTask()` 自建 |
| 阻塞式 `accept`/`connect` | socket 层是**轮询**的（`Table` 没有阻塞原语） | 需要同上的一条等待队列，并用 `poll` 包装成阻塞 |
| `sem_timedwait` / `mutex_timedlock` | `semPend` 只有 `forever` 真阻塞 | 需要 tick 驱动的超时唤醒（`callout` + `resumeTask`） |
| `pthread_rwlock_*` | 读者写者饥饿 | 独立设计，先不做 |
| 文件 I/O / `fork` | 无 VFS、无 MMU | 不做（`ENOSYS`） |

**共同前提**：剩下的三项都要一条**多等待者队列**。它应当落在 `osal`（内核该有的东西），
而那会改 `bt_core.o` ⇒ 需重跑 `scripts/check-bt-link.sh` 并重新确立镜像尺寸基线。
**仍未做**：`pthread_cond_*`（需要与 mutex 配合的等待队列，而 `osal` 只有单 waiter 槽）、
`fork`/`waitpid`、文件 I/O。

✅ **搬运所需的门禁已就绪（2026-11-18）**：`scripts/check-bt-link.sh` —— 生成闭包 → 用闭包链接
→ 断言镜像 > 500 KB。实测 116 个对象、镜像 913728 B；去掉 `root.zig` 的根引用后门禁失败（负例验过）。
它需要 IDF 树，不进 `check-all`，**动 `osal.zig`/`sched.zig` 前后各跑一次**即可。

⚠️ 背景（原先的判断）：`bt-blobs` 的 blob 链接路径**不在任何门禁里** —— `check-all` 的六个 profile 都不带 blob 目录，只有它的 36 项主机用例在跑。
而 `osal.zig`/`sched.zig` 被该组件的 **10 个文件、18 处相对 import** 引用（`bringup`/`extfuncs`/
`porting`/`transport`/`probe`/`root`/`xpuq_shim`/`host_tests` 与它们自己）。移动文件会让这些
import 全部改成模块导入，**改错在主机用例里看不出来**（用例只覆盖纯逻辑），要等一次真实链接才暴露。

所以顺序是：先给 blob 链接加一条可跑的验收（至少 `zig build` 带 `-Dbt-blob-dir` 能过），
再搬运。否则就是"为了 POSIX 线程去动一条没人验证过的生产路径"。

搬完才能做：

| 目标 | 落在哪 | 备注 |
| --- | --- | --- |
| `pthread_create/join/detach/exit/self` | `sched.taskCreate` + 新增 join（等待 Task 退出） | 栈由调用方给；`pthread_attr_setstack` 正好对应 |
| `pthread_mutex_*` | `mutexInit/Pend/Release` | `trylock` 用 `mutexPend(0)` |
| `sem_*` / `sem_timedwait` | `semInit/Pend(timeout)/Release` | **超时已支持**，只需把 `timespec` 换算成 tick |
| `pthread_cond_*` | **要新写** | `eventq`/`event` 是信号量语义，不是条件变量；`cond_wait` 必须原子释放 mutex + 入等待队列，且 `cond_timedwait` 要能被打断 |
| `poll` 超时 | 现版用 1 ms 轮询；接内核后改为等待 `eventqGet(timeout)` 或 tick 唤醒 | 现在是"睡一小步再看"，不是真等待 |

`errno` 也要在那一步改成每 Task 一份（现在是模块级全局，见 `errno.zig` 的说明）。
