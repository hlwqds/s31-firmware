# ADR-002：POSIX 兼容层自持等待队列，而不是借用 `osal`

- 状态：accepted
- 日期：2026-11-18
- 决策者：s31-firmware 维护者

## 背景

要把 POSIX 形状（`sem_*` / `pthread_*` / `cond` / `rwlock` / `errno`）套在既有的
`socket` 表与 `osal` 内核上。最初的做法是最省事的那个：`sem_t` 就是 `osal.Slot`，
`pthread_mutex_t` 就是「令牌数 1 的 `osal.Sem`」。

做下去之后发现 `osal` 的原语带着**为 BLE 归档量身定做**的语义，直接复用会把归档的约束
一起搬进兼容层：

| 约束 | 实测事实 | 后果 |
| --- | --- | --- |
| 单等待者 | `Sem.waiter` 是**单指针** | 同一信号量上第 2 个阻塞者立刻拿到 `EAGAIN`，`cond_broadcast` 之后**复锁退化** |
| 共享静态池 | 句柄来自 `sem_pool`（64 槽），而 `porting.zig` 的 mempool 校验比的是**请求数**、不是剩余槽 | POSIX 侧多开几个信号量就能挤压归档，且**不会报警**；症状是"init 过了但 controller 不动" |
| 定时语义 | `semPend` 只有 `timeout == forever` 才真阻塞 | 有限超时立即返回 ⇒ 无法用它实现 `sem_timedwait` |
| `osal.Mutex` 不是锁 | `mutexPend` 只做 2M 次 `spinLoopHint` 有界忙等、`mutexRelease` 不唤醒、无 owner | 直接映射会让 `pthread_mutex_lock` 在有争用时返回伪 `ETIMEDOUT` |

同时有一条**判据**贯穿整个决定：本项目里"什么算验证过"取决于**哪条门禁能观察到这个行为**。

| 通道 | 能验证阻塞路径吗 |
| --- | --- |
| 主机用例 | ❌ `sched.swapContext` 在 x86_64 上 `@panic` |
| `scripts/check-bt-link.sh` | ❌ 只证明链接 + 镜像尺寸 |
| `scripts/gate-board.sh` | ❌ 走 net-wire 的 TCP，不碰 BLE |
| `-Dbt-probe` 板级运行 | ✅ 唯一有效 |

## 选项

1. **改 `osal`**：给 `Sem` 加 FIFO 等待队列、给 `Mutex` 加 owner/waiter、给 `semPend` 加真超时。
   - 优点：只有一份内核，长期最干净。
   - 代价：改的是**正在服务已编译 BLE 归档**的代码，而其阻塞路径唯一有效的验证手段是
     `-Dbt-probe` 板级运行 —— 当前没有这个步骤。等于提交一段无门禁可观测的内核改动。
2. **在兼容层自持队列**：`sem_t` = 计数 + `waitq` FIFO，阻塞用 `sched.block()`、唤醒用 `resumeTask`。
   - 优点：与归档物理隔离；多等待者天然支持；`sem_t` 是普通结构体；语义可在主机上钉住。
   - 代价：有两套队列实现（`osal` 的单等待者 + 本层的 FIFO），短期内是重复。
3. **不做线程/同步，只做不需要内核的那一半**（`errno`/`time`/`addr`/`fd`）。
   - 优点：零风险。代价：`pthread_*` 永远缺位。

## 决定

**选 2**，并把兼容层登记为**只跑主机测试**的组件（不进镜像）。

> ⚠️ 这条「不进镜像」只描述**决策当时**的状态；2026-11-18 的追加已推翻它（统一模块根后
> 进镜像，并有板级证据）。本 ADR 按追加式记录保留原文，读到这里请继续看文末追加。

理由：选项 1 的收益是"少一份实现"，代价是"改一段**没有门禁能观测**的生产内核"；
在本项目的证据纪律下，这个交换不成立。选项 2 把风险留在 test-only 组件里，且把
真正容易错的部分（队列协议）变成可断言的主机用例。

## 后果

- 正面：
  - `osal` 一行没动，BLE 归档的行为与镜像尺寸都不受影响（闭包镜像仍 116 对象 / 913728 B）。
  - 多等待者、定时等待、读写锁、条件变量都能做，且各有主机用例。
  - 与归档的**存储**彻底隔离：POSIX 侧再多的信号量也不会挤压 `sem_pool`。
- 负面：
  - 两套队列实现并存；`osal` 的 `Sem`/`Mutex` 仍是归档专用语义，读代码的人会看到两副面孔。
  - **本层没有任何板级证据**（⚠️ 已被 2026-11-18 追加取代）：它不进镜像（同一批 `net_sockets` 文件不能属于两个模块），
    因此"能编过 + 用例通过"不等于"板上可用"。
- 需要后续跟进：
  - 统一 `net_sockets` 的模块根，让本层具备进镜像的条件。注意 `selftest.zig` 导入了
    `board`，**不能**把 `api.zig` 直接再导出它 —— 否则会把 `board` 依赖拖进 posix-compat 的
    主机测试目标（那里没有 `board` 模块）。正确形状是让 `selftest.zig` 成为**独立模块**、
    从模块导入（`@import("net_sockets").socket`）而不是从文件导入。
  - 阻塞 `accept`/`connect` 仍有两条硬前置：RX 泵与调用者必须是不同任务（本仓 RX 就是
    调用者在 `emac.rxPollCopy` 里喂 `Table`，原地阻塞即自死锁），且 `Table` 没有就绪通知路径。

## 追加（2026-11-18）：三条队列不变量，以及它们各自对应的一次真实缺陷

节点是**等待者的栈局部**，帧一返回就失效 —— 本层几乎全部 bug 都是这条事实的变体：

1. **令牌交接**：退出循环的条件只能是"节点被 `pop` 了"，不能是"计数非 0"。
   写成后者时，任何**非本信号量 `post`** 引起的唤醒都会让等待者看到别人刚被 post 的令牌就
   抢走它，而计数是 `u16` ⇒ 第二个取用者**下溢 panic**。依赖的前提：`post` 先加计数再 `pop`。
2. **先摘链再唤醒**：`pop()` 清 `linked` 之后才能 `resumeTask`；`unlock` 用**交接**
   （直接交给队首），不是"置 1 再让人抢"——否则 FIFO 没有意义。
3. **定时器到期必须从侵入式链表摘除**：只清 `armed`/`expired` 会留下指向死栈的指针
   （下一次 `pump` 读 use-after-free），而 `disarm` 在 `armed == false` 时早退，永远不会替你收拾。
   到期还**必须唤醒**：`wake_fn` 为空时回落到 `sched.resumeTask`，否则"到期但不唤醒"
   与"定时等待会到期"的契约正好相反。

另有一条**交接窗口**缺陷（`rwlock` 实测）：把锁交给等待者时 `pop` 已把它摘出队列，而
"已持有"标志要等它被调度回来才置位 —— 这中间两个条件都说"没人在等"，新读者就插队，
被唤醒的写者排回队尾（正是写者优先要防的饥饿）。修法是交接时**立刻**置 `writer_pending`。

推广：**任何"取出等待者再唤醒"的交接，都需要一个覆盖这段窗口的标记。**

## 追加（2026-11-18）：注入点收敛为两处

只有 `resumeTask` 一件不可移植（`swapContext` 在 x86_64 上 `@panic`），所以把它做成
`sync.bindHooks(.{ .wake, .now })`，`cond`/`timer`/`rwlock`/`pthread_once` **全部复用同一个**；
板上不绑，默认走 `sched.resumeTask`。另有 `time.zig` 的 `Clock`/`Sleeper` 与
`errno.contextFn` 两套，各只服务于一个主机上不可执行的原语。

## 追加（2026-11-18）：`errno` 不用 TLS，用上下文分槽

POSIX 的 `errno` 是线程私有的。裸机没有 TLS，但 `sched` 的 `*Context` 天然唯一 ⇒
用 8 槽表按上下文索引，表满退回 0 号槽并累加 `overflows`（**可见地**退化）。
任务退出后槽不回收是安全的：POSIX 规定成功调用后 `errno` 是**未指定**值。

## 追加（2026-11-18）：本层已进镜像，并拿到了第一份板级证据

决策后的第一条后续（"统一模块根"）已落地：`net-sockets` 与 `net-tcp` 的 `selftest.zig` 从
**按文件导入**改成**经模块导入**，于是同一批文件不再属于两个模块；`posix` 自身也用同一形状
（`api.zig` 作组件根、`selftest.zig` 作 section 根）。`api.zig` 刻意**不导入 `board`**，
这样主机测试目标仍然只要它一个。

上板（`net` profile）结果：`section: posix` → `checks: passed=26 failed=0 total=26`
（`logs/e2e-net-boot.log`）。它验证的正是主机用例结构上做不到的四件事：任务真的被创建并运行、
`sem_wait` 真的阻塞、`sem_post` 真的唤醒、`join` 真的返回。

代价是容量：`net` +3.1 KB；`full` 的 bin +62 KB，其中 **51 KB 是第二段窗口按 64 KiB 步进产生的
padding**，真实段增长约 10.8 KB（irom +7.8 KB、drom +3.1 KB）。这条值得记下来：本仓的
"镜像大小"不是线性于代码量的，`capacity.json` 的基线因此必须用 `--update` 显式重写并写明原因。

## 追加（2026-11-18）：阻塞 `accept` 补上了"轮询模型 → 阻塞 API"的接缝

`socket.Table` 是轮询的，`accept` 只能说"还没好"。唯一的接缝是新增的 `on_ready` 钩子
（默认 `null`，不绑定时行为与旧版**逐字节一致**）：`deliver`（SYN 填 backlog / 数据段到达）、
`close`、`abort` 时回调。POSIX 侧 `fd.enableBlockingAccept(sem)` 把钩子接到调用方的信号量，
`fd.acceptBlock` 就是 `accept → EAGAIN → sem_wait → 重试`。

三条在实现中撞出来的规则，都写进了代码：

1. **`Table.reset()` 必须保留钩子**：原先 `self.* = .{}` 会连回调一起抹掉，而绑定只做一次 ⇒
   第一次 reset 之后等待者会睡在一个再没人 post 的信号量上。
2. **`abort()` 必须通知**：连接池淘汰走 abort，不通知的话那条路径上的等待者永远醒不来。
3. **唤醒只能发生在主上下文**：`sched.resumeTask` 内部是 `swapContext(&main_ctx, t)`，存的是
   **调用者**帧 ⇒ 从任务里唤醒会把主上下文换成那个任务的帧，之后"任务阻塞回来"会从错的地方
   继续跑。所以 RX 泵必须在主上下文、accepter 必须在任务里；`onReady` 在非主上下文直接丢弃并
   计数（`fd.droppedNotifies()`），宁可丢一次通知也不破坏调度器。

板级判据（`net` profile，26/26）：accepter 阻塞 → 喂 SYN 唤醒后**再次阻塞**（子连接仍在
`syn_rcvd`，`accept` 拿不到）→ 喂 ACK 后 `accept` 返回 fd。中间那一次"被唤醒≠成功"是这个模型里
最容易误判的地方，所以单独断言了。

## 追加（2026-11-18）：阻塞 `connect` 不需要新机制，但需要正确的**重查**

`fd.connectBlock` 与 `acceptBlock` 用同一条就绪钩子。区别在等待者的实现方式：

- 钩子**只报"有事情变了"**，不承诺"你等的那个转换发生了"；
- 所以等待者必须 `sem_wait → 重查自己的 fd 状态 → 不对就再等`。这样与本次连接无关的唤醒
  （别的 fd 收到数据、被淘汰）会被重查自然吸收，不需要给钩子加参数、也不需要分类通知。
- 两个方向的重查次数不同，这来自协议本身：客户端收到 **SYN-ACK 一步即 `established`**
  （一次唤醒）；listener 侧必须等子连接**走完握手**（SYN 只到 `syn_rcvd`，`accept` 仍拿不到 ⇒
  第二次唤醒）。

板级判据（`section: posix`，32/32）：ACCEPT 侧两次唤醒、CONNECT 侧一次，两者都在同一张表上、
同一轮里跑出来，且 `droppedNotifies() == 0` —— 即唤醒确实都发生在主上下文。

顺带修掉一个"返回 -1 却不设 errno"的疏漏：未启用阻塞模式时两个阻塞调用现在都置 `EAGAIN`。

## 追加（2026-11-18）：阻塞读用同一形状；阻塞写没有——原因不在实现而在通知源

`fd.recvBlock` 与 `acceptBlock`/`connectBlock` 完全同构：`recv → EAGAIN → sem_wait → 重试`。
板级判据：`reader` 任务阻塞 → 主上下文投一帧 data → 唤醒 → 返回字节数（`section: posix` 36/36）。

`send` **没有**阻塞版，而且不是"还没做"，是**没有通知源**：发送缓冲腾出空间发生在对端 ACK 到达时，
处理它的是 `net-tcp` 的连接状态机与 `net-sockets` 的 `onSegment`，**不经过 `Table.on_ready`**。
要做阻塞写，先得让那条路径也发通知 —— 那是另一处生产代码改动，收益要等真有阻塞写调用方时再评估。

## 追加（2026-11-18）：posix 与 BLE 闭包**装不进同一个窗口**

把 posix 接成 section 之后，`scripts/check-bt-link.sh` 的闭包链接失败：

```text
error: ld.lld: section '.flash.text' will not fit in region 'irom': overflowed by 2032 bytes
```

原因不是代码质量，是容量：闭包本身占 `.flash.text` 699 856 / 窗口 720 896，posix section
（net profile 实测 +8.75 KB）再加进去就顶爆。**两者都不需要同时存在**：posix 是自检段，
BLE 闭包构建是链接验收，所以 `-Dbt-blob-dir` 或 `-Dbt-probe` 时不再挂 posix section
（`firmware/build.zig` 里有一行跳过 + 注释）。真要三者共存，先扩两段窗口。

这次改动也让闭包镜像从 913 728 变成 **913 744 B**（+16 B；后来 `bt_printf_shim.c` 加了有界
格式化器又涨到 **917 840 B**，该代码只存在于带 `-Dbt-blob-*` 的构建里）：非 probe 的闭包构建不再把
`bt_core` 整个编进来（那会 +2 KB），改成让 probe-off shim 里做一次 `osal.forceExports()`
的 comptime 根引用 —— 只发射归档要的 5 个 `s31_*`。
