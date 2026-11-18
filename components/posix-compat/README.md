# posix-compat — 在我们的系统上提供 POSIX 形状的接口

本文是**梳理**：POSIX 的那些接口，我们已有的对应物是什么、缺口在哪、这一版做哪一段。
代码在同目录 `src/`，逐层落地，每层都有主机用例。

## 1. 现状盘点（2026-11-18）

| 层 | 在哪 | 形态 |
| --- | --- | --- |
| 调度器（抢占、优先级、WaitList） | `practice/zig-esp32-s31/ch10/ch11` 的 `sched.zig` | **lab 内**，尚未成为组件 |
| 互斥/信号量/事件组/队列/spin | `ch12-sync-primitives-ipc` 的 `mutex.zig`/`sem.zig`/`events.zig`/`queue.zig`/`spin.zig` | 同上；mutex 已支持优先级继承 |
| socket 层（fd 表、状态机、errno 语义） | `s31-firmware/components/net-sockets` | **已是生产组件**，`Table` + `Socket` + `Io{err,n}` |
| 时间基准 | `ch08`/`ch12` 的 tick（1 ms 周期） | lab 内；生产侧是 TIMG0（`hw.nowUs`） |
| C 库 | 无 libc，ROM 提供 `memcpy`/`printf` 等 | 无 POSIX 头文件 |

关键观察：**socket 层已经用 POSIX 的 errno 词汇**（`again`/`bad_fd`/`not_conn`/`conn_reset`/
`pool_full`/`in_progress`）和 `Io = {err, n}` 结果类型 ⇒ POSIX 兼容层的这一半只是**薄适配**，
不是重新实现。而**内核那一半**（线程、条件变量）目前只活在 lab 里。

## 2. 映射表

`● 已有，直接包` / `◐ 已有但语义要补` / `○ 缺，本组件实现` / `— 明确不做`

### 2.1 进程与线程

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `pthread_create` | `sched` 的 Task + 就绪队列 | ◐ 需要 create/join 包装与 trampoline（lab 里的任务是静态表） |
| `pthread_join` | `sched.wake` + Task.done | ◐ 需要一个"等待某任务退出"的 WaitList |
| `pthread_exit` / `pthread_self` | `sched.currentTask` | ● |
| `pthread_detach` | — | ○ 简单标志 |
| `fork` / `exec` / `waitpid` | — | — 单地址空间、无 MMU 进程模型，不做 |
| `getpid` | — | ○ 可返回固定值 |

### 2.2 同步

| POSIX | 我们的 | 状态 |
| --- | --- | --- |
| `pthread_mutex_init/lock/unlock/destroy` | `mutex.zig`（含 PI） | ● 直接映射 |
| `pthread_mutex_trylock` | — | ○ 需要一个 tryLock（lab 里只有阻塞版） |
| `pthread_cond_init/wait/signal/broadcast` | **无**（`events.zig` 是信号量语义，不是条件变量） | ○ **要新写**：cond 必须与 mutex 配合、避免丢失唤醒 |
| `sem_init/wait/post/trywait/destroy` | `sem.zig` | ● |
| `pthread_once` | — | ○ |
| `pthread_rwlock_*` | — | — 本版不做（读者写者饥饿问题需要单独设计） |
| `pthread_spin_*` | `spin.zig` | ● |

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

## 5. 验收与登记方式

- 每层主机用例（`zig build test` 聚合进 `firmware/build.zig` 的 test step）：**17 项**
  （errno 3 · time 4 · addr 3 · fd 6 · 聚合块 1）；
- `tests/baselines.json` 里 `posix-compat: 17`；
- 板上验收留到接内核那一步（本版没有板级行为变更）。

**本组件只登记主机测试目标，不进镜像**（`firmware/build.zig` 里是单独的 `addTest`，不在
`all_modules` 里）。两个原因：

1. 本版没有板级行为变更 —— 没有 selftest 要跑；
2. 它依赖 `net_sockets` 模块，而 `net_sockets` 组件模块（`selftest.zig` 为根）与
   `api.zig` 为根的模块**包含同一批文件**；两者同时进镜像会撞 Zig 的
   "file exists in modules 'net_sockets' and 'net_sockets0'"。等接内核时把 socket 层的
   模块根统一（api 兼作组件根，并在 test 目标里特殊处理 `host_tests.zig` 的路径映射）再一起进。

## 6. 下一步（线程与条件变量）

需要先把 `ch10`–`ch12` 的内核提成组件（调度器 + mutex/sem/events/queue/spin），否则
`pthread_*` 只能在假内核上自说自话。提上来之后本组件把 `sync/thread` 建在其上，
`errno` 改为每 Task 一份（现在是一个全局，见 `errno.zig` 的说明）。
