# posix-compat — 在我们的系统上提供 POSIX 形状的接口

本文是**梳理**：POSIX 的那些接口，我们已有的对应物是什么、缺口在哪、这一版做哪一段。
代码在同目录 `src/`，逐层落地，每层都有主机用例。

## 1. 现状盘点（2026-11-18）

| 层 | 在哪 | 形态 |
| --- | --- | --- |
| **生产 OSAL：任务 + 调度器** | `components/osal/src/sched.zig`（310 行，2026-11-18 从 bt-blobs 抽出） | `taskCreate(stack, entry, arg)`、`currentContext`、`start`；协作式，已被 BLE blob 使用 |
| **生产 OSAL：同步原语** | `components/osal/src/osal.zig`（1604 行，同上抽出） | `semInit/semPend(timeout)/semRelease/semGetCount/semDeinit`、`mutexInit/mutexPend(timeout)/mutexRelease/mutexDeinit`、`eventqPut/Get(timeout)`、`calloutInit/Reset`（软件定时器） |
| 生产 Wi-Fi OSAL | `components/wifi-blobs/src/osi_impl.zig`（1567 行） | Wi-Fi blob 的 osi 表实现（事件/定时器/锁），形状由 blob ABI 决定 |
| 教学内核 | `practice/zig-esp32-s31/ch10/ch11/ch12` 的 `sched/mutex/sem/events/queue/spin` | 抢占 + 优先级继承的**教学**实现 |
| socket 层（fd 表、状态机、errno 语义） | `s31-firmware/components/net-sockets` | **已是生产组件**，`Table` + `Socket` + `Io{err,n}` |
| 时间基准 | `ch08`/`ch12` 的 tick（1 ms 周期） | lab 内；生产侧是 TIMG0（`hw.nowUs`） |
| C 库 | 无 libc，ROM 提供 `memcpy`/`printf` 等 | 无 POSIX 头文件 |

关键观察（**2026-11-18 更正**）：本文件第一版写"内核只活在 lab 里"是**错的**。
`components/bt-blobs` 里已经有一套**生产级 OSAL**，而且它比教学内核更贴近 POSIX：

| POSIX | `bt-blobs` OSAL | 差距 |
| --- | --- | --- |
| `sem_init/destroy/post/getvalue/wait/trywait` | `semInit/semDeinit/semRelease/semGetCount/semPend(timeout)` | 形状 1:1，但 **`semPend` 只有 `forever` 才真阻塞**；有限超时立即返回 `TIMEOUT` ⇒ `sem_timedwait` **不能**靠它，本层返回 `ENOSYS` |
| `pthread_mutex_init/destroy/lock/unlock/trylock` | `mutexInit/mutexDeinit/mutexRelease/mutexPend(timeout)` | ❌ **不能用**：`mutexPend` 只做 2M 次忙等、`mutexRelease` 不唤醒、Mutex 无 owner/waiter。本层改用令牌数 1 的 `Sem` |
| `pthread_create` | `sched.taskCreate(stack, entry, arg)` | 缺 join/detach；调用方要自备栈 |
| `mq_send/receive` | `eventqPut/eventqGet(timeout)` | 槽位式（`*Slot`）而非字节流 |
| `timer_create` | `calloutInit/calloutReset(ticks)` | 固定周期，无 `itimerspec` |
| `pthread_self` | `sched.currentContext` | ● |

而 socket 层已经用 POSIX 的 errno 词汇（`again`/`bad_fd`/`not_conn`/`conn_reset`/`pool_full`/
`in_progress`）和 `Io{err,n}` 结果 ⇒ 兼容层两半**都是薄适配**，不是重新实现。

⚠️ 这两套 OSAL 原先只服务各自的 blob；**OSAL/sched 已于 2026-11-18 抽成 `components/osal/`**
（见 §6.1）。Wi-Fi 那套仍留在 `wifi-blobs`（形状由 blob ABI 决定，不复用）。

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
| `pthread_mutex_init/lock/trylock/unlock/destroy` | `sync.zig` → **令牌数 1 的 `sem_t`（自持等待队列）** | ✅ 已完成（**不用** `osal.Mutex`：它只忙等、不唤醒） |
| `pthread_cond_init/wait/signal/broadcast` | `cond.zig` → `waitq`（FIFO）+ **注入的 wake** | ✅ 已完成（`wait` 要求调度器已启动，否则 `ENOSYS`；**多等待者复锁已可工作**） |
| `sem_init/wait/trywait/post/getvalue/destroy` | `sync.zig` → 自持计数 + `waitq` FIFO | ✅ 已完成（**多等待者**，与 BLE 不共享静态池） |
| `sem_timedwait` / `pthread_mutex_timedlock` | `sync.sem_timedwait` → `timer.zig` + 应用周期性 `sync.pump()` | ✅ 已完成（**契约**：不调 `pump()` 就永不到期；未绑时钟 ⇒ `ENOSYS`） |
| `pthread_once` | `sync.zig`（CAS + 完成态自旋） | ✅ 已完成 |
| `pthread_rwlock_*` | — | — 本版不做（读者写者饥饿问题需要单独设计） |
| `pthread_spin_*` | — | ○ 待做（`std.atomic.spinLoopHint` 足够，但要知道它在单核上没有意义） |

> ⚠️ **阻塞的前提**：`sem_wait`/`mutex_lock`/`cond_wait` 要求调度器**已启动**
> （`sched.isStarted()`）。没启动时不做真阻塞 —— 有界忙等 2M 次 `spinLoopHint` 后返回
> `EAGAIN`（`cond_wait` 直接 `ENOSYS`）。这是"哪条门禁能观察到"的必然结果：主机上
> `sched.block()` 是 no-op，若不设这个前提，用例会原地死循环而不是失败。
>
> ✅ **单等待者限制已解除**（2026-11-18）：`sem_t` / `pthread_mutex_t` 改成自持计数 + `waitq`
> FIFO，多线程可以排队；也不再从 `osal` 的 `sem_pool`（64 槽，BLE 同池）取句柄。
>
> ⚠️ **勘误（2026-11-18）**：本表原先写的 `mutex.zig`（含 PI）/ `sem.zig` / `spin.zig` /
> `events.zig` 是 **lab 内核**的文件名，固件仓里**没有这些文件**。生产侧只有 `osal` 一套原语，
> 而且 `osal.Mutex` **不是**一把能阻塞的锁：`mutexPend` 只做 2M 次 `spinLoopHint` 的有界
> 忙等、`mutexRelease` 不唤醒等待者、Mutex 本身没有 owner/waiter 字段（它服务的是"不能真阻塞"
> 的归档上下文）。

### 2.3 时间

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `clock_gettime(CLOCK_MONOTONIC)` | `time.clock_gettime`（注入 `Clock = fn () u64` ns） | ✅ 已完成 |
| `nanosleep` / `usleep` / `sleep` | `time.nanosleep/usleep/sleep`（注入 `Sleeper`） | ✅ 已完成（板侧 sleeper 由应用接 tick；轮询式） |
| `clock_getres` | `time.clock_getres`（恒定 1 ms / 1 µs） | ✅ 已完成 |
| `gettimeofday` | — | — 无墙上时钟（板子没有 RTC 校准源），不做；需要时由应用注入 |

### 2.4 fd 与 socket

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `socket(AF_INET, SOCK_STREAM, 0)` | `fd.socket` → `Table.alloc` + family/type/proto 校验 | ✅ 已完成 |
| `bind` | `fd.bind` + 本组件的每 fd `sockaddr_in` 表 | ✅ 已完成 |
| `listen` | `Table.listen` | ● |
| `accept` | `fd.accept` → `backlog` + `accept_token` | ✅ 非阻塞（`EAGAIN`）；⏳ **阻塞等待未做**（见 §6.3） |
| `connect` | `fd.connect` → `Table.connect` | ✅ 非阻塞返回 `EINPROGRESS`；⏳ 阻塞等待未做 |
| `send` / `recv` | `Socket.send` / `Socket.recv` | ● 直接映射到 `ssize_t` + `errno` |
| `sendto` / `recvfrom` / `sendmsg` / `recvmsg` | — | — 只有 TCP，不做 |
| `shutdown` | `closeHalf` | ● |
| `close` | `Table.close` | ● |
| `read` / `write` | `fd.read` / `fd.write`（同 `recv`/`send`） | ✅ 已完成 |
| `select` / `poll` / `epoll` | `fd.poll`（单次、非阻塞） | ✅ `poll` 已完成；`select`/`epoll` 不做 |
| `setsockopt` / `getsockopt` | — | — `SO_REUSEADDR`/`TCP_NODELAY` 无意义（我们只有一条连接、不聚合 Nagle），返回 `ENOPROTOOPT` |
| `fcntl(O_NONBLOCK)` | `Socket.nonblocking` | ● |
| 文件 I/O（`open`/`stat`/`fsync`…） | 无 VFS | — 不做（`ENOSYS`） |

### 2.5 错误

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `errno` 全局 | `errno.zig`：模块级 `value` + `set/get` + `fromNetSockets` | ✅ 已完成（值按 Linux 数值；**每 Task 一份**未做，见 §6.3） |
| `strerror` | `errno.name`（只覆盖本文件定义的子集） | ✅ 已完成 |

## 3. 本版范围（可验证优先）

做：`errno` · `time`（clock_gettime/nanosleep/clock_getres）· `addr`（`sockaddr_in` 编解码 +
每 fd 地址表）· `fd`（socket/bind/listen/accept/connect/send/recv/read/write/shutdown/close/poll）
· `sync`（sem/mutex/once）· `thread`（create/join/detach/self/exit）· `cond`（含 `waitq`）

暂不做：`select`/`epoll`、文件 I/O、`gettimeofday`、`sem_timedwait`/`cond_timedwait`
（内核没有定时阻塞）、阻塞式 `accept`/`connect`（socket 层是轮询的）。

理由：`errno`/`time`/`addr`/`fd` **不需要内核**，可以全部用主机用例钉住（`net-sockets` 的
`Table` 是纯逻辑）。内核在 2026-11-18 已抽成 `components/osal/`，于是 `sync`/`thread`/`cond`
可以接上真内核；它们**真正阻塞的那一段**（`sched.block()`）在主机上不可执行，所以主机用例
只钉策略，阻塞行为仍是板级验收（见 §4.6 与 §6.3）。

## 4. 分层

```text
应用
  ↓  POSIX 形状（int 返回 + errno）
posix-compat: errno | time | addr | fd | sync | thread | waitq | cond
  ↓  组件接口（Io{err,n} / Table / Socket）
net-sockets（生产）    osal（sem/sched）    hw/tick（板级）
```

注入点（为了主机可测，全部做成参数而不是全局）：
- `time.zig`：`Clock = fn () u64`（纳秒）与 `Sleeper = fn (u64) void`
- `fd.zig`：`*socket.Table` 与地址表由调用方持有（无全局状态）
- `cond.zig`：`bindHooks(.{ .wake = fn (*sched.Context) void })` —— 只有 `resumeTask` 一件
  （`swapContext` 在 x86_64 上 `@panic`），见 §4.6
- `osal`（由 `bt-blobs/probe.zig` 绑）：`hooks.now_ms` / `irq_save` / `irq_restore` / `log` /
  `on_mutex_acquired`

## 4.5 绑定决策（2026-11-18 定）

**直接依赖 `osal_kit`，不再造注入 port。** 当初 `time.zig` 用注入，是因为当时没有可复用的内核；
现在 `components/osal/` 零 `board` 依赖、20 项主机用例可驱动，直接 import 就是"在真内核上测真语义"，
§4 那句"假内核自说自话"的前提已经消失。**目前有两处注入点**：`time.zig` 的时钟/睡眠
（`osal` 侧则是 `hooks.now_ms`），以及 `cond.zig` 的 `wake`（见 §4.6）。两者都只为"主机上
不可执行的那一个原语"存在，其余一律直连。

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

- 每层主机用例（`zig build test` 聚合进 `firmware/build.zig` 的 test step）：**67 项**
  （errno 3 · time 4 · addr 3 · fd 6 · **sync 19** · **thread 11** · **waitq 6** · **cond 6** · **timer 8** · 聚合块 1）；
- `tests/baselines.json` 里 `posix-compat: 67`；
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
`sem_post` 唤醒 joiner，然后 `sched.block()` 永不返回。

**安全性别归因错**：`sem_post` 会立刻切给 joiner，joiner 一步步就 `retireSlot()` 了，
同一个 8 KiB 栈可能马上被新线程拿走，而垂死任务的活帧还在上面 —— 之所以无害，是因为
**退出的任务永不再被 resume**（那些帧不会执行，被覆写也无妨）。结构性保证来自 `sched`
不回收任务槽：没人持有它的 `Context`。哪天 `sched` 加了槽回收，这个论证就失效。
回收点也不同：join 路径在 joiner 的栈上回收；detach 路径在**垂死任务自己的栈上**由
`complete()` 回收，随后才落进 `block()`。

主机用例覆盖槽位分配/回收、重复 join、detach、`self` 在主上下文返回 `null`，
走的是 trampoline 收尾的**同一段** `complete()`，不是替身。

### 6.3 剩下的 ○（按价值排序）

| 项 | 阻塞点 | 代价 |
| --- | --- | --- |
| ~~`pthread_cond_*`~~ | ✅ 已完成：`waitq` + `cond.zig`；`wake` 统一注入在 `sync.bindHooks` | — |
| ~~多等待者 / 与 BLE 共用静态池~~ | ✅ 已解除：`sync.zig` 自持计数 + FIFO 队列，不再用 `osal.Sem` 的槽位 | — |
| 阻塞式 `accept`/`connect` | 两个硬前提（**先满足才有意义**）：① RX 泵与调用者必须是**不同任务** —— 本仓的 RX 就是调用者那个任务在 `emac.rxPollCopy` 里喂 `Table`，阻塞 `accept` 会把喂它的那个任务停住 ⇒ 自死锁；② `Table` **没有通知路径**，没人告诉等待者"连接到了"，需要 socket 层加钩子（动生产代码），否则只能退化成"轮询+睡眠"，那不是阻塞 | 判断依据见 `waitq` 的落点原则 |
| ~~`sem_timedwait` / `mutex_timedlock`~~ | ✅ 已完成：`timer.zig`（侵入式到期链表）+ `sync.pump()`。**契约**：应用每个 tick 调一次 `pump()`，否则定时等待永不到期；未绑时钟钩子则 `ENOSYS` | — |
| `pthread_rwlock_*` | 读者写者饥饿 | 独立设计，先不做 |
| 文件 I/O / `fork` | 无 VFS、无 MMU | 不做（`ENOSYS`） |

## 4.6 条件变量的 wake 注入（2026-11-18）

`cond.zig` 只把 **`resumeTask` 一件**做成注入点（`bindHooks(.{ .wake = ... })`），因为
`swapContext` 在 x86_64 上 `@panic`，其余逻辑照常直连 `sched`/`sync`。这样 `signal`/`broadcast`
的**策略**（唤醒谁、FIFO 顺序、唤醒前先摘链、广播先摘完再逐个唤醒）都能在主机上断言，
而板上不绑钩子时默认走 `sched.resumeTask`。

**多等待者队列放在 `posix-compat/waitq.zig`，不放内核**（2026-11-18 定）：往 `osal` 加 FIFO
会改 `bt_core.o`，而它服务的是已编译的 BLE 归档，其阻塞路径**没有任何现有门禁能验证**
（`sched.block()` 在主机被编译掉、`check-bt-link.sh` 只证明链接、`gate-board.sh` 走 net-wire TCP）。
`waitq` 是 test-only 的（不进镜像），语义可以在主机上钉住；等有板级跑 BLE probe 的那一步
再考虑搬进内核，届时必须重建镜像基线。

**队列的生命周期规则**（写进 `waitq.zig` 头，是唯一容易出错的地方）：节点由等待者在栈上分配
⇒ 唤醒方 `pop()` 必须**先摘链清 `linked` 再 `resumeTask`**；等待者只在 `linked == true` 时
继续 `block()`（虚假唤醒不会留毒节点）；超时/取消走 `remove()` 自摘链。
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

| 目标 | 原计划 | **实际落地（2026-11-18）** |
| --- | --- | --- |
| `pthread_create/join/detach/exit/self` | `sched.taskCreate` + 新增 join | ✅ `thread.zig`：`Done` 标志 + 每线程 `done_sem`；**上限 8 次/boot**（`sched` 不回收任务槽） |
| `pthread_mutex_*` | ~~`mutexInit/Pend/Release`~~ | ❌ **原计划不成立**：`osal.Mutex` 只忙等、不唤醒、无 owner。实际用**令牌数 1 的 `osal.Sem`**（`sync.zig`） |
| `sem_*` | `semInit/Pend(timeout)/Release` | ✅ 用 `osal.Sem`；`sem_timedwait` 返回 **`ENOSYS`**（`semPend` 没有真定时阻塞） |
| `pthread_cond_*` | **要新写** | ✅ `waitq.zig` + `cond.zig`（不是 `eventq`：它是信号量语义）；`cond_timedwait` **未做** |
| `poll` 超时 | 接内核后改为 tick 唤醒 | ⏳ 仍是 1 ms 轮询 |

`errno` 也要在那一步改成每 Task 一份（现在是模块级全局，见 `errno.zig` 的说明）。
