# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- **生产 A/B 与回滚（矩阵 C5，2026-11-18）**：`firmware/idf-bootstrap/partitions.csv` 追加
  `ota_0`(0x190000) / `ota_1`(0x310000) / `otadata`(0x490000, 8K)，factory 仍在 0x10000。
  新增真实落盘层 `components/boot-power-perf/src/{flash,partition,slot}.zig`：按 IDF
  `esp_ota_select_entry_t`（32 B、`crc` **只覆盖 `ota_seq`**、槽位 `=(seq-1)%app_count`、
  两扇区交替写）写 otadata，并解析 0x8000 的分区表。
  **生产 bootloader 未开 `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`（Kconfig 默认 `n`）**，所以
  NEW/VALID/INVALID 全部由应用写；"待确认"判据是 `state ∈ {NEW, PENDING_VERIFY}`。
  失败计数按槽隔离、落在 nvs 末扇区 0xE000（每次 16 B 追加，写满才擦）。
  板上证据：`logs/c5-ab-factory.log`（`ab=yes count=2`、`crc32 mine=rom=0x4743989a`）、
  `logs/c5-ab-stage-confirm.log`（`state=NEW(0) seq=1` → `confirmed VALID`）、
  `logs/c5-ab-rollback.log`（`failure 1/3`→`3/3` → `marked INVALID` → 复位 → `offset 0x190000`），
  已排除项见 `logs/c5-ab-negative.log`。
  注：生产侧只做**落盘 + 选槽 + 回滚**；镜像由 esptool 直接写入槽位，下载/签名仍在 ch23 lab。
  容量基线随之刷新（`capacity.json` 此前停在 `9bd55e4`，早于 TLS/MQTT 落地 ⇒ `tls` 的
  +64 KB 主要是那批工作的累计增长，本次 C5 贡献各 profile 约 +10–15 KB `irom_len`）。

- **周期实测基线与 CPU 频率实测（矩阵 C7 的一部分，2026-11-18）**：新增
  `components/boot-power-perf/src/workload.zig`（4 KiB ARX 固定工作量、注入时钟、p50/p95/周期每字节）
  与 `hw.cycleCount()`（`mcycle` 的防撕裂读法）。用 `-Dperf-run` 打开，默认构建不含这段代码。
  板上读数：`cycles(p50)=59454`、`cycles_per_byte=14.515`、`cpu_mhz(measured)=80`
  （`mcycle` 与 TIMG0 两个独立计数源对算，与 `BOOTLOADER_CPU_CLK_FREQ_MHZ` 默认值一致）。
  证据：`logs/c7-perf-baseline.log`。
- **C7 三档对比完成（2026-11-18）**：新增 `boards/esp32s31-coreboard/src/clock.zig`，按 IDF
  `rtc_clk_cpu_freq_set_config` 的序列与分频表切换 80/160/320 MHz（cpu/mem/sys/apb 四分频 +
  切 CPLL + bus update + `esp_rom_set_cpu_ticks_per_us`），写后读回校验。
  三档实测：`cycles_p50` 同为 59455（⇒ 纯 CPU 受限）、`cycles_per_byte=14.515`、
  `mib_per_s` 5.256/10.512/21.024（恰好 2×/4×，验证 `perf.scaleNs` 模型）；
  用 `mcycle`/`nowUs` 两源对算独立验证频率真的变了（79/160/320）。证据 `logs/c7-perf-tiers.log`。
  附带观测：320 档 `mhz_measured=320` ⇒ APB 未随分频改变，硬件自动纠正（`rtc_clk.c` 注释警告的行为）。
  构建开关 `-Dperf-tiers`，默认构建不含改频代码。

- **C8 综合 demo（2026-11-18）**：新增 `scripts/demo-board.sh [PORT]`，一条命令完成
  构建 → 烧录 → 抓串口 → 断言，并演示 A/B：① 默认固件从 factory 起来（`verdict=pass`）；
  ② 正常镜像写进 ota_0 后切槽（`offset 0x190000` + `confirmed VALID`）；
  ③ `-Dab-revert` 的镜像判废当前槽（`marked INVALID -> reverting`）⇒ 回到 factory（旧版本）；
  ④ 恢复默认固件并清 otadata/计数扇区。
  它不碰网络（不需要 DHCP/监听器/防火墙），发布门禁仍是 `scripts/gate-board.sh`。
  踩到的顺序坑：第 3 步之前必须先把 factory 换回**不带** `-Dab-stage` 的基线镜像，
  否则判废后 bootloader 回到 factory、而那里仍是 stage 构建，会立刻又被切走。
  新增构建开关 `-Dab-revert`。证据：`logs/c8-demo.log`（四段串口原文 + 尾部标注）。

- **POSIX 兼容层第一版（2026-11-18）**：新增 `components/posix-compat/`，把 POSIX 接口映射到
  现有实现。README 是**梳理**产物：逐接口列出「我们的对应物 / 状态（已有·语义要补·缺·不做）/
  决定」，并纠正了一个错误结论 —— 生产侧早有 `bt-blobs` 的 OSAL（`semPend`/`mutexPend` 都**已
  支持超时**），内核并非只活在章节目录里。
  本版实现不需要内核的那一半：`errno`（Linux 数值 + 与 `net-sockets` 枚举的双射）、
  `time`（`clock_gettime`/`nanosleep`/`usleep`/`sleep`，时钟与睡眠注入；`CLOCK_REALTIME`
  明确 `EINVAL`，因为没有墙钟）、`addr`（`sockaddr_in` 16 字节布局与网络序端口）、
  `fd`（`socket/bind/listen/accept/connect/send/recv/read/write/shutdown/close/poll`）。
  共 **17 项**主机用例，含一条 `socket→bind→listen→SYN→ACK→accept` 的完整链路。
  **只登记主机测试目标、不进镜像**：本版无板级行为变更，且其 `net_sockets` 模块与
  `net_sockets` 组件模块包含同一批文件（同时进镜像会撞 Zig 的"一个文件属于两个模块"）。
  `tests/baselines.json` 已加 `posix-compat: 17`。

- **OSAL 抽成独立组件（2026-11-18）**：`components/bt-blobs/src/{sched,osal,probe_ptr}.zig`
  → `components/osal/`（1946 行，零 `board` 依赖，时间/临界区/随机数都是注入钩子）。
  动机是给 POSIX 兼容层一个可复用的内核落点，而不是再造一份。
  搬移本身**行为未变**的证据：闭包链接的镜像大小搬前搬后**逐字节相同**（913728 B）。
  bt-blobs 的 10 个文件、18 处相对 import 改为模块导入；其主机用例 36 → 17（19 项随文件迁走，
  归 `osal` 自己的测试目标，避免同一批用例被两个组件各数一遍）。
  ⚠️ `osal/src/api.zig` 里那行 `comptime { _ = &osal.timeGet; }` **不能删** —— 没有它
  `osal.zig` 的 5 个 `export fn` 不会发射，`bt_core.o` 变 0 符号对象、闭包链接报未定义
  （`scripts/check-bt-link.sh` 会抓到）。新增组件基线：`osal: 20`，`bt-blobs: 17`。

- **`osal` 不再知道自己服务谁（2026-11-18）**：`mutexPend` 里原本内嵌着 BLE bring-up 的门控
  测量（`probe_ptr` 的 env/P + `0x2f00ffd0` 的 10 个 per-object 锚点表，约 37 行）。
  那段代码读的地址和日志前缀都是 bt-blobs 专有的，而且 **`logLine` 只按 `"bt hook: "` 前缀
  过滤日志**，`"bt gate: "`/`"bt env: "`/`"bt anchor["` 不在门内 ⇒ probe 路径下**每次取到
  互斥锁都要往 UART 打 ~15 行**。现在门控搬进 `components/bt-blobs/src/gate.zig`，由
  `Hooks.on_mutex_acquired` 注册；`probe_ptr.zig` 也随 ADR 退回 bt-blobs。
  触发条件与迁移前一致（只有 `probe.zig` 调 `setHooks`，新字段在同一次调用里注册，
  不会被整表替换冲掉），日志格式逐字未变，闭包镜像仍 **913728 B**。
  **未在板上复验本轮日志输出**；静态侧只确认了 `gate.zig` 会被分析（`app_zcu.o` 里有它的
  字面量）且两种构建都 RC=0。另一个实测事实：生产镜像里 `probe.run` 无人引用，
  gc-sections 会把 probe/gate 一起丢掉（`bt bringup` 也不在 ELF 里）—— 而生产路径本来
  也没设过 `.log`，所以"生产不打这些日志"在迁移前后都成立。
- **POSIX 同步层（2026-11-18）**：`components/posix-compat/src/sync.zig` —— `sem_t` 与
  `pthread_mutex_t` 建在 `osal.Sem` 上（**不是** `osal.Mutex`：后者只做有界忙等、不唤醒
  等待者、无 owner/waiter），`pthread_once` 用 CAS。13 项新用例，posix-compat 17 → **30**。
  `sem_timedwait`/`pthread_mutex_timedlock` 返回 `ENOSYS` —— 内核只有无限阻塞，假装超时
  比不做更危险。无定时等待的 `semWait`/`pthread_mutex_lock` 在 `osal.TIMEOUT`（= 没能阻塞住，
  不是到期）时返回 `EAGAIN` 而非 `ETIMEDOUT`，后者是 POSIX 只允许定时变体用的。

- **POSIX 线程层（2026-11-18）**：`components/posix-compat/src/thread.zig` ——
  `pthread_create/join/detach/self/exit` 建在 `sched.taskCreate` + 静态栈池上。
  硬边界写进文件头：`sched` 没有 `taskDelete`/`taskExit`，任务槽**永不回收** ⇒
  每 boot 最多 **8** 次成功创建，第 9 次返回 `EAGAIN`（线程退出也不还槽）。
  退出协议：线程体返回后不能 return，trampoline 记返回值 → `done` → `sem_post` →
  `block()` 永不返回；安全性来自"退出的任务永不再被 resume"。11 项用例（41 总计）。

- **等待队列（2026-11-18）**：`components/posix-compat/src/waitq.zig` —— FIFO 等待者链表，
  6 项主机用例（顺序、摘链清理、中段/队首/队尾自摘、重复摘、`drain` 广播）。
  **刻意不放进 `osal`**：那会改 `bt_core.o`，而归档的阻塞路径没有任何现有门禁能验证
  （主机上 `swapContext` 直接 panic，链接门禁只看链接，板级门禁走 net-wire TCP）。
  因此 `pthread_cond_*` 目前只有队列、没有胶水层 —— 胶水需要一次板级运行才能验收。

- **POSIX 条件变量（2026-11-18）**：`components/posix-compat/src/cond.zig` ——
  `init/destroy/wait/signal/broadcast`，队列用 `waitq`。只有 `resumeTask` 做成注入点
  （`swapContext` 在 x86_64 上 panic），因此「唤醒谁、FIFO 顺序、唤醒前是否已摘链、
  广播是否先摘完再逐个唤醒」全部有主机断言；`wait` 在调度器未启动时返回 `ENOSYS`
  而不是挂住。6 项新用例，posix-compat 47 → **53**。

- **`sync` 改用自持等待队列（2026-11-18）**：`sem_t` / `pthread_mutex_t` 不再借用 `osal.Sem`
  的句柄，改为「计数 + `waitq` FIFO + `sched.block()/resumeTask()`」。一次解掉三个约束：
  多等待者（此前第 2 个阻塞者拿 `EAGAIN`）、不再与 BLE 归档共用 `sem_pool`（64 槽）、
  `sem_t` 变成普通结构体（`in_use` 区分"未初始化"与"计数为 0"）。
  `unlock` 现在把锁**直接交给队首等待者**，不再"置 1 后被第三方抢走"。
  `wake` 注入点统一到 `sync.bindHooks`，`cond.zig` 复用。16 项 sync 用例（总计 **56**）。

- **定时等待（2026-11-18）**：`components/posix-compat/src/timer.zig` —— 侵入式到期链表 +
  `pump(now_ns)`。阻塞中的任务读不到时钟，所以到期必须由外部唤醒；本层提供
  `sync.pump()`，**应用每个 tick 调一次**。到期时 `pump` **从链表摘除**定时器（否则下一次 pump 会读等待者已返回的栈帧），而是真正挂定时器等待；未绑时钟钩子时仍 `ENOSYS`（无法判定到期），
  调度器未启动时 `EAGAIN`（不能假装等过）。7 项 timer 用例 + 2 项新 sync 用例（总计 **66**）。

- **POSIX 读写锁（2026-11-18）**：`components/posix-compat/src/rwlock.zig` —— 两个 `waitq`
  （等读/等写）+ `sync.wake`。策略是**写者优先**：只要有写者排队，新读者就进不来，否则持续
  的读者流会让写者饿死（读写锁最经典的失效模式）。`unlock` 由内部状态判断释放的是读还是写，
  释放写锁时优先交接给写者、没写者才 `drain` 唤醒全部读者；释放最后一个读锁时把写者交接过去。**交接窗口用 `writer_pending` 标记**：写者被 `pop` 出去唤醒时
  `writers_q` 已空而 `l.writer` 还没置位，不标记的话新读者会在这一瞬插队、把写者挤回队尾
  （正是写者优先要防的饥饿）。
  10 项用例（总计 **77**）。**无超时变体**（要接 `timer.zig` 的到期链表，等真实调用方再加）。

### Planned
- P1：以太网 ARP/ICMP 上层（DMA 已闭环）

### Added
- **死等循环已反汇编出来**（2026-11-17，不需要 JTAG）：探针把 ROM 区 `0x2f83efb0` 与 `0x2f812200`
  各 96 字节读出来（`0x2f8xxxxx` 可直接读），离线 `objdump -D -b binary -m riscv:rv32` 反汇编。
  轮询循环在 `0x2f812216`：

  ```asm
  2f81221a: addi s1,zero,127
  2f81221e: mv   a0,s0            # ← 循环头
  2f812222: jal  0x2f83efca       # 读一个字节
  2f812228: bltu s1,a0,0x2f81221e # while (127 < byte) 继续转
  ```

  读字节的叶子函数（`0x2f83efca`）= `((*(u32*)(((arg + 0x2038A) << 12) + 28) >> 16) & 0xFF)`。
  采样到的 `a0=0xE080` ⇒ 轮询地址 **`0x2E40A01C`**；`0x2f83efda` 被采到 13 次不是在那儿转，
  而是它是叶子函数、被这个循环高频调用。⇒ 下一步只需弄清 `0x2E40A01C` 是哪个外设的状态字节，
  MAC 在等什么就明确了。**本条完全不需要外部设备**，也不需要 JTAG。
  另确证：`SOC_PLL_SOURCE_CG`（`0x205871E0` = 0x3d）、PHY 的 8 个 FE 时钟、LP timer 时钟
  （LPCON +0x4/+0x14/+0x18）全部已开并读回自证，仍卡在同一处 —— 排除了"只是少开时钟"。
- **板上结论：BLE 与 Wi-Fi 撞同一面墙**（2026-11-17）：BLE controller 跑到 init step 6
  （`r_btdm_task_init` 内部）停住，用 TIMG0 T0 采样被中断的 PC —— 28 个样本全部 `mac=0x0000e000`，
  PC 集中在 ROM 区的 `0x2f83efda`/`0x2f812220` ⇒ **`MAC_ST & 0xE000 != 0`**，与 ch25 记录的
  Wi-Fi blob 卡点是**同一组只读忙位**。⇒ 两个 controller 都停在"MAC/PHY 内部状态从未离开 busy"，
  是同一个底层状态而非各自的问题；R3.2 与 R3.3 的后续都卡在"让 MAC 从 busy 里出来"这一件事上
  （ch25 已为此排除 17 条路径，下一步仍是 JTAG 写监视点或 ROM 侧情报）。
  顺带确证（板侧实测）：12 个时钟门全部置上；控制器要的池容量 `evt=187 evtq=33 co=41 sem=20 mutex=16`；
  init 链可达 step 5。
  ⚠ 探针漏调 `hw.initTimer()` 的代价：`nowUs()` 恒 0 ⇒ T0 采样中断永不到点、OSAL 时基恒 0
  （ADR-001:729 因同一原因记过一次，这次又踩，已写进 README）。
- **板上探针 + 构建配方可复现**（2026-11-17）：`components/bt-blobs/src/probe.zig`（`-Dbt-probe`）
  按"装钩子 → arena → init → enable → 进任务 → 发 Reset → 泵任务"的顺序跑，并在主循环打
  `bt task round N` —— 日志能直接区分三种失败：**任务从没跑过**（没有 round）/ **跑了但没回包**
  （有 round、没 EVT）/ **回包但 status≠0**。钩子必须在 init 前装：`now_ms = nowUs()/1000`
  （**毫秒**，差 1000 倍会让所有超时窗口变成天文数字）、`log` 同步刷 UART。
  新增 `tools/gen-bt-closure.sh`：解包 4 归档 → 符号图 BFS → 减 ROM → 打印对象清单与构建命令，
  把原先只存在于 `/tmp` 的配方固化。**根集合 = 我们的 Zig 直接调用的每个归档符号**——实测踩到
  `r_base_stack_initEnv` 因不在根里而链接失败，补全后闭包 113 → **116 对象**。
  另：所有 bt-blobs 文件合成**单一模块**（`root.zig`），分两个会报"文件属于多个模块"。
- **协作式调度器 + OSAL 真阻塞**（2026-11-17，`components/bt-blobs/src/sched.zig`）：从
  `wifi-blobs/src/sched.zig` 复制（**不 import**，否则会把 wifi blob 的依赖拖进来），
  在其上加了任务表与 `block()`/`resumeTask()`。BLE 的任务体是 `sem_pend(FOREVER)` /
  `eventq_get(FOREVER)` 的**死循环**：只登记不建上下文 ⇒ 任务永不执行，init 会"成功"
  然后什么都不发生；建立了却不切回主上下文 ⇒ 主循环饿死、连串口日志都出不来。
  `swapContext(from,to)` 存 `from.sp` 恢复 `to.sp` ⇒ 阻塞=切回 main、恢复=切回任务，
  任务的 `sp` 已存下，**从原地继续**。OSAL 侧 `sem_pend`/`eventq_get` 在 FOREVER 且无资源时
  记 `waiter` 再阻塞、唤醒后**重新检查**；`sem_release`/`eventq_put` 有等待者就 `resumeTask`。
  调度器未启动时（主机测试）退化成 `TIMEOUT` 并计入 `blocked_calls`，不会自旋。
  `task_create` 现在真的从 arena 分栈并建上下文，失败时打日志而不是静默。
- **transport.init 接进 init 链（第 15 步）+ B 路径发命令**（2026-11-17）：
  `hci_transport_init` 在 IDF 里是 `esp_bt_controller_init` 的**最后一步、enable 之前**——
  不做它，命令照样发得出去（我们直接调 forward），但 controller **没有回程回调**
  （`r_ble_hci_trans_cfg_hs` / `r_btdm_hci_trans_register_tx` 都没跑）⇒ 症状是
  "init 全绿、命令发了、就是没回包"，极易误判成时钟/中断/任务没做。
  另加 **B 路径**（`r_ble_hci_trans_buf_alloc(3)` + `r_ble_hci_trans_hs_cmd_tx`）——
  比 A 路径少一半代码，先试它；⚠ 两个分配器的 type 值不同（B=3、A=1），别混用。
  **判据**：HCI Reset 的成功回程是 `04 04 0E 03 0C 00`，最后那个 `00` 才是 status 成功。
  enable 的步骤号顺延到 16–20，避免与 init 的 `failed_step` 混淆。
- **公有地址设置**（2026-11-17，init 第 14 步）：`r_esp_ble_ll_set_public_addr(mac)`（归档 ✓），
  `mac` 先 `readEfuseMac` 再**字节逆序**（IDF 同样是 `swap_in_place(mac, 6)` 之后再设）。
  没有这一步 **HCI Reset 能过、但扫描/广播命令全部无效** —— "命令有回包但没效果"的典型成因。
  enable 链的步骤号相应顺延到 15–19（最后仍是 `r_btdm_task_enable`）。
- **HCI 传输层落地**（2026-11-17，`components/bt-blobs/src/transport.zig`）：我们**自己拥有**这一层
  （归档里没有 `hci_driver_vhci_ops`/`uart_ops`），结构照 IDF 的 `hci_transport_init`：
  `ops.init(cb)` → `r_ble_hci_trans_cfg_hs(leEvtTx, NULL, leAclTx, NULL)` → `r_btdm_hci_trans_register_tx(btdmTx, false)`。
  三个必踩点：① **别手搓 12 字节包**——用归档的 `r_btdm_hci_trans_buf_alloc` 拿；② **必须置 BLE 位**
  （`r_btdm_hci_pkt_flag_ble_setf`），否则包被当 BR/EDR 路由、症状是"命令没人接"；③ 我们是 host
  ⇒ 回程读完要**自己释放**（`r_ble_hci_trans_buf_free` 收的是载荷不是包）。
  `sendReset()`/`sendReadLocalVersion()` 已就绪；事件回调按 `cmd[1]+2` 切长度并把每个字节打进日志
  ——这就是里程碑的唯一判据。前提是 `status()==enabled`（rx 路径自己会查）。
- **`ext_funcs_t` 注册**（2026-11-17，`components/bt-blobs/src/extfuncs.zig`）：这是 controller 拿
  **malloc/free/rand/assert** 的那张表（`ble.c:97-109`，rv32 上 **40 字节**）。上一版把它当成
  "可以跳过"是错的——跳过等于 controller 没有分配器，`r_ble_controller_init` 必然失败，
  且失败点会被误判成"时钟/中断没做"。`ext_version=0x20250819`、`magic=0xA5A5A5A5`；
  `_malloc/_free` 接我们的 arena、`_os_random` 接 `osal.randomU32()`（板级可注入真 TRNG）；
  `_osi_assert` 的参数顺序是**行号在前、函数名在后**（与 `__assert_func` 相反）。
  三个 ECC 项给**返回 -1 的桩**——IDF 在 `CONFIG_BT_LE_SM_LEGACY/SC` 未开时本来就 return -1，
  `_ecc_aes_cmac` 转发的是 NimBLE host 的函数（controller-only 没有 host）⇒ 不需要 ROM ECC。
- **init / enable 编排落地**（2026-11-17，`components/bt-blobs/src/bringup.zig`）：init 13 步、
  enable 6 步，状态机 `idle → inited → enabled` + `getStatus()`（HCI 传输层的门禁就查它）。
  两步最容易错：① **`r_btdm_task_enable` 在 enable 的最后一步**，不在 init 里——只做 init
  的话 controller 任务永不启动，HCI 不会有回包；② `r_btdm_hci_fc_env_init` **必调**
  （`UC_BT_CTRL_CONN_FC_ENABLE` 在 `btdm_user_cfg.h:108` 硬编码为 1）。
  跳过 `esp_register_ext_funcs(&ext_funcs_ro)`：归档里有前者，但 **`ext_funcs_ro` 是 NimBLE
  host 的符号、归档里没有** ⇒ 跳过并计数；若事件送不出来第一个回来查这里。
  归档调用写成 `if (freestanding) f(...) else 0`（comptime 条件 ⇒ 主机分支不求值），
  所以 13 个归档符号在主机测试里不进 debug info，29 个用例仍能在 x86_64 上跑。
- **`btdm_lp_enable_clock` 按"空实现 + 大声日志"落地**（2026-11-17）：它是 9 个 porting 函数里唯一的
  真硬件活，但 **HCI Reset / Read Local Version 是软件层命令**，未必需要射频时钟 ⇒ 先空着，
  等 controller 一碰 MAC 寄存器就 fault 再补。补实现所需的规格已查全并写进
  `components/bt-blobs/README.md`：`BLE_CLOCK_DEPS` 的 **8 个门**（BLE_MAC / BT_I154_COMMON_BB /
  ETM / **COEXIST 在 lpcon 块** / WIFI_BB_80X1 / SOC_PLL_SOURCE_CG / BT_APB / BT_PERIPHERAL）
  与 `BT_APB_CLOCK_DEPS` 的 4 个门，外加 `modem_clock_module_mac_reset`。
  纪律：**宁可多开不要少开**（少一个门 = 访问该外设总线挂死，比缺时钟更糟）。
- **porting 层的 9 个 C 函数里 7 个已落 Zig**（2026-11-17）：照 IDF 原文逐条读过之后，估工大幅下调——
  4 个是 `return 0`（`btdm_log_init`/`btdm_external_init`/`btdm_coex_init`/`btdm_lp_init`），
  `ble_controller_scan_duplicate_config` 是 NimBLE **host** 侧的扫描去重（全归档 `grep ble_vhci` 零命中
  ⇒ controller-only 构建没有 host，空实现是对的），`ble_msys_init` 只是转调归档里的
  `r_esp_ble_msys_init`（常量取 `host/nimble/Kconfig.in` 的 SOC_ESP_NIMBLE_CONTROLLER 分支：24/128、24/320）。
  `btdm_osal_elem_mempool_init` 做成**容量校验**：IDF 池空会回退动态 malloc，我们的静态池**没有回退**
  ⇒ 超限按类返回 -1..-5 并把 5 个数字打出来，免得"池不够"表现成"controller 不动"。
  **只剩 `btdm_lp_enable_clock` 是硬活**（CNNT/modem 域时钟门控 + BT MAC 复位，`modem_clock_*` 是 IDF C 不是 ROM）。
- **`ble_osal_elem_calc` 的 Zig 版**（2026-11-17，R3.3 里程碑 2 前置）：`config.elemCalc()` /
  `mempoolElemNum()` 复刻 `ble.c:1586-1607`，作为 `btdm_osal_elem_mempool_init` 的输入。
  两个必须照抄的点：① **seed 不是零**——`bt.c:172-178` 预置 `{evt=103, evtq=3, co=10, sem=0, mutex=1}`，
  从零算会少 103 个事件；② **五个累加宏是交叉用的**（`evt` 用 `BLE_HOST_CO_COUNT`、
  `evtq` 用 `BLE_HOST_EV_COUNT`、`co` 用 `BLE_HOST_EVQ_COUNT`），像笔误但归档依赖它。
  归档符号 `r_ble_ll_get_npl_element_info` 只在目标构建引用（主机走注入 hook），
  所以 4 个用例能在 x86_64 上钉住算术；按默认 config 算出的上限（事件 ~181）正好验证池 ≥192 够用。
- **`esp_bt_controller_config_t` 的逐字段镜像 + 布局实测**（2026-11-17，R3.3 里程碑 2 前置）：
  `components/bt-blobs/src/config.zig` 镜像 60 个字段，13 条 comptime 断言钉死全部偏移
  （总长 **192**、`ble`@0/**112 B**、`bredr`@112/**56 B**、`btdm`@168/**20 B**；
  `ble` 内 `config_version`@0、`rtc_freq`@24、`main_xtal_freq`@84、`config_magic`@108）。
  数字**不是手算**：`tools/btcfg-probe.sh` 用 rv32 gcc 把 `sizeof`/`offsetof` 发射成常量表再读回
  （交叉产物跑不了，而 `esp_bt.h` 会拉 FreeRTOS 的 `portmacro.h` 编不过 ⇒ 探针只抄了结构体本体）。
  三处照抄要点：`bredr` 有 8 个 C 位域 ⇒ Zig 无位域，用 `[56]u8` 占位（`btdm` 的偏移由它决定）；
  `ble.rtc_freq` 是 u64 ⇒ 引入 8 字节对齐填充；4 个 C `bool` 用 `u8`（Zig `bool` 遇非 0/1 字节是 UB）。
- **56 个弱断言桩全部有强定义**（2026-11-17，R3.3 里程碑 2c1 收口）：在 36 个 OSAL 之上补齐
  **11 个 `wr_btdm_coex_*`**（Wi-Fi/BLE 共存钩子）。这批**不能做空桩**——controller 会问
  "Wi-Fi 现在哪个信道"、"这个状态位可用吗"，空桩返回 0 会被当成"可用"或"信道 0"。做法是维持
  真实的状态位图 + 存下回调，并按 IDF 在"未开软件共存"分支下的返回值作答
  （`wifi_channel_get` → **-1**、`iso_protect_frame_thres_get` → **0**，见 `btdm_coex.c:106-114/153-162`）。
  逐条对归档调用集核过：56/56 覆盖，差集为空（我们共提供 68 个 `wr_btdm_*` 强定义）。
  热路径（`ble_idle_time_inform`/`iso_*`）只计数不打印，避免把串口打爆。
- **BT controller 的 OSAL 落成**（2026-11-17，R3.3 里程碑 2c0）：`components/bt-blobs/src/osal.zig`
  实现 time/critical/sem/mutex/event/eventq/callout + 自有 arena，并导出 **48 个** `wr_btdm_osal_*`
  强定义（覆盖归档里的弱断言桩）。归档**实际会调**的 **36 个逐个点名核对**（差集为空），
  因为**漏一个链接期不报错**（同名弱桩兜着）、运行期才以 `wr_btdm_assert` 挂住。
  三处形状/环境的硬约束（都踩过）：
  ① **句柄是 4 字节槽位**（`struct btdm_osal_* { void *x; }` 内嵌在 controller 结构体里）⇒
  `Slot` 是 `extern struct { p: ?*anyopaque }`，状态对象只在静态池里、只把指针写进槽位；
  ② **不能用 `std.heap.page_allocator`**（`riscv32-freestanding` 没有后端，主机上却正常 ⇒ 假绿）；
  ③ 块头必须补到 **16 字节**，否则 `addr+12` 破坏 8 字节对齐（controller 结构里有 u64）。
  14 个主机用例（含槽位金丝雀、arena 对齐、36 个导出点名）。
- **BLE controller 链进两段镜像**（2026-11-17，R3.3 里程碑 1）：`libble_app` + `libbtdm_common` +
  `libbtbb` + `libphy` 的 113 对象闭包全部加进 `zig build`（新开关 `-Dbt-blob-dir` / `-Dbt-blob-objs`），
  `.flash.text` **699 920 / 720 896**（余 20 976）、`.flash.rodata` 110 848、`.iram_blobs` 60 224，
  `elf2image` 成功且 `image-info` 恰好 2 条 `DROM, IROM`。控制器**还不能跑**（config/任务/HCI 传输未做），
  详见 `components/bt-blobs/README.md`。三个落地要点：
  ① `libble_app` 的 `.iram_sleep*`/`.iram_single_sleep*` 不在原 `.iram_blobs` 收集规则里，
  不显式收编就各自成段、`elf2image` 报 `Invalid segment count 27 (max 16)`（与当年 105 对象那次同类）；
  ② 链接期只剩 4 个未定义符号，且**全在 S31 ROM 集里**（`printf`/`ets_printf`/`abs`/
  `phy_set_chan_freq_sw_start`）⇒ 加进 `rom_syms.ld` 而不是写桩——"ROM 集里有"不等于
  "`rom_syms.ld` 里有"，增量链接实验要先对账；
  ③ 5 个 `*_btdm` 边界符号用**零长度区间**即可：`libble_app/112.o` 的用法是
  `memset(start, 0, end-start)`，而本布局 `.bss` 已由 `_start` 清零、`.data` 的 LMA == VMA。
  另：`wr_btdm_osal_*` 51 个虽由归档定义，但类型是 **`W`（弱定义）、函数体是 `wr_btdm_assert` 断言占位**
  ⇒ **必须由我们实现**（IDF 的真实实现是 `btdm_osal_freertos.c`，基于 FreeRTOS）。这是"让 controller
  跑起来"的主要工作量；`nm` 只数"有定义"不够，必须看类型字母。
- **Wi-Fi blob init 返回 0**（2026-11-16，R3 里程碑）：真实 blob 的 `esp_wifi_init_internal`
  在裸机上返回 **0**（`wifi-init-probe: INIT OK`）。三个修复都由故障点反汇编定住：
  `_wifi_create_queue`（表 index 94）是独立钩子且**返回对象的第一个字必须是内部队列指针**
  （`pp_create_task` 把首字当句柄传给 `_queue_send`）；`_wifi_thread_semphr_get` 返回 null
  会让 init 判成 `257`；`osi_stubs.fill` 改成只填仍为 null 的字段（否则新实现的钩子被同名桩
  静默覆盖），并加主机用例断言"已实现 ∩ 桩 = ∅"。仍未闭环：init 创建的任务在协作式单线程壳里
  从未被调度，扫描/关联/收包尚未发生。
- **第一次真正执行 blob 代码**（R3 里程碑）：`-Dwifi-init-probe=true` 编进"装 osi 表 → 构造
  `wifi_init_config_t` → 调 `esp_wifi_init_internal` → 打印返回码与桩命中"的入口，实测：

  ```text
  wifi-init-probe: arena=397936 B
  wifi-init-probe: osi installed prev=0x00000000
  wifi-init-probe: cfg size=160 magic=0x1f2f3f4f
  wifi-init-probe: esp_wifi_init_internal rc=257        ← ESP_ERR_NO_MEM
  wifi-init-probe: osi stub _calloc_internal hits=1
  ```

  补上分配器族（`_malloc_internal`/`_zalloc_internal`/`_calloc_internal`/`_realloc_internal`/
  `_wifi_malloc/_wifi_calloc/_wifi_zalloc/_wifi_realloc`，共 9 个）后 rc 变成 **258**
  （ESP_ERR_INVALID_ARG），失败点前移到链接桩 `net80211_printf`/`pp_printf`——这正是"把清单变成
  实测"的效果：每次只暴露下一个真正缺的东西。探针与常规构建用 comptime 分流（`probe.enabled`），
  常规镜像不受影响（167 520 B、两段）。
- **`wifi_osi_funcs_t` 的 Zig 镜像**（`components/wifi-blobs/src/osi.zig`）：字段表由 IDF 头
  `esp_wifi/include/esp_private/wifi_os_adapter.h` 经 `sdkconfig.h` 预处理后**自动生成**
  （128 个字段，`_version` 首、`_magic` 尾），不是手写。ilp32 下用 comptime 断言钉死
  `@sizeOf == 512`、首尾字段偏移——交叉编译时就会检查（实测通过）。主机用例断言字段数与
  首尾偏移。这张表是 blob 与宿主之间唯一的 OS 契约：三个大归档里
  `xTaskCreate`/`xQueue*`/`xSemaphore*`/`esp_event_*`/`esp_timer_*`/`heap_caps_*` 的未定义引用
  全是 0，所有 OS 访问都经 `g_osi_funcs_p` 回调。
- **链接脚本收集 IDF blob 的段**：`s31.ld` 现在把 `.rodata_wlog*`（603 个 Wi-Fi 日志串段）、
  `.eh_frame*` 并进 `.flash.rodata`，`.iram1/.wifis*piram/.wifirxiram/.wifiextrairam` 等
  IRAM 变体收进 SRAM 的 `.iram_blobs`（62 240 B），`.dram1` 并进 `.data`。没有这一步，
  105 个 blob 对象会让 `elf2image` 报 `Invalid segment count 124 (max 16)`。
  收集后同一实验镜像变成合法两段：irom **586 128 B**、drom **163 360 B**、SRAM 92 KB，
  总镜像 818 368 B（factory 1 536 000 之内），`image-info` 里 DROM/IROM 行正好 2 行
  （`rom_index == 2` 成立）。**这份 blob 镜像已烧上板并正常启动**：
  `sections: passed=1 failed=0 total=1`、`verdict=pass`——586 KB irom + 163 KB drom + 62 KB
  SRAM 的新布局被 loader 正常映射，这是板级事实而非静态账。常规镜像不受影响
  （`elf2image` 仍两段、`gate-board` 7/7 通过）。
  注意 `Merged N ELF section` 是 esptool 的**合并次数**（`before - after`），不是 flash 段数，
  判据看 `image-info` 的 DROM/IROM 行数。
- **分区表落库**：`firmware/idf-bootstrap/partitions.csv`（nvs 0x9000 / phy_init 0xf000 /
  factory 0x10000 + 1500K，与 `SINGLE_APP_LARGE` 的默认表**逐字节一致**），
  `sdkconfig.defaults` 改走 `CONFIG_PARTITION_TABLE_CUSTOM`；新增
  `scripts/gen-partition-table.sh`（`--check` 校验 bin 与 csv 一致，纯 Python、不需要 IDF 工具链）。
  `check-capacity.py` 与 `run_e2e.py` 的 factory 上限改为从表里解析，不再硬编码 `0x177000`。
- **P0.3 两段窗口扩容**：`linker/s31.ld` 的 `irom`/`drom` 各 `0x7F000 → 0xB0000`，drom 基址
  `0x40080020 → 0x40100020`（保持 64 KiB 对齐 + 0x20）。合计 1 441 792 B 仍在 factory 1 500 K
  之内，不需要动分区表；`full` 的 IROM 余量从 214 496 B 涨到 415 200 B、DROM 到 650 128 B。
  板级验证：`gate-board.sh`（net-wire）PASS 7/7，`--profile full` 12 段 `verdict=pass`。
  **单段真的能到 0xB0000** 也补了实测：新增 `-Dfat-rodata=N`（往 `.rodata.fat` 塞 N 字节静态数组），
  `-Dfat-rodata=600000` 的 `net` 镜像 DROM 段 **0x9b5d4 = 636 372 B**（旧的 0x7F000 装不下），
  烧上去 `sections: passed=7 failed=0 total=7`、`verdict=pass`——窗口扩容在 loader 侧成立，
  不只是链接期。
  上限说明写进 `docs/ARCHITECTURE.md`：芯片窗口 64 MiB，但 DROM 段须结束在 `0x43FF0000` 以下
  （loader 保留最后一页做分区发现）。
- **CI 的 board job 走发布前门禁**（R4.1 的另一半）：`workflow_dispatch` 默认
  `profile=net-wire`、`gate=true`，步骤为 `host-prep-wire.sh up` → `gate-board.sh` →
  `trap` 收尾 `down`，与本地同一套脚本；`gate=false` 保留裸 e2e 冒烟路径。
  之前该 job 既不跑 host 预置、`profile` 默认还是 `net`，缺 DHCP 时退化成 skip 且 exit 0。
- **`net-wire` 的 TCP 改由 socket 层驱动**（R2.2d）：`components/net-sockets/src/api.zig` 提供
  统一入口，`firmware/build.zig` 给 wire 组接上 `net_sockets`；探针用 `Table.connect()` 建客户端、
  `tcp.Conn` 保持线上真相，SYN-ACK 学 `peer_iss` 后按偏移去重镜像，应用 64 B 经
  `Socket.send` → `txPeek` → 帧发出，ACK 覆盖后 `drainTx`；仍以 RST 收尾。
  板级 `wire: checks passed=7 failed=0`（新增 `socket layer established` / `socket send accepted` /
  `socket tx acked` 三项）。
- **容量门禁 `scripts/check-capacity.py`**（R4.3）：每个 e2e profile 构建一次，断言
  镜像 ≤ factory 分区、每个 DROM/IROM 段的 `load + Length ≤ 窗口末端`（IROM `0x40000020`、
  DROM `0x40080020`，窗口各 `0x7F000`）、以及相对 `tools/s31-production/baseline/capacity.json`
  的增长 ≤ 8 KiB（`--update` 需在 PR 里说明）。段长按 `image-info` 表头取 **Length 列**——
  早期版本误取了 File offs 列，断言因此恒真，`CAP_WINDOW=0x40000` 自检现在会报
  `IROM ends at 0x4004aa40 > window end`。实测 `full`：镜像 398 560 B、IROM 305 696 B
  （余量 214 496）、DROM 70 768 B（余量 449 424）。
- **matrix 自动更新 `tools/s31-production/baseline/update_matrix.py`**（R4.2）：只改 W1–W3
  状态列，摘录来自 `logs/e2e-net-wire-boot.log`，剥掉 `rcv_nxt` 等易变值；`--check` 进
  `check-all.sh`，`gate-board.sh` 通过后自动刷新。W4 保持人工（需无 DHCP 场景）。
- **发布前板级门禁 `scripts/gate-board.sh`**（R4.1）：`net-wire` 从可选 profile 提升为必跑门禁。
  `scripts/host-prep-wire.sh up|down|check` 固化主机预置（接口地址、dnsmasq、udp 67/53 与
  tcp 9000 放行、监听器，幂等且可撤销）；门禁先删旧日志（证据只能来自本轮），跑
  `run_e2e.py --board --profile net-wire`，再断言 `wire: tcp SYN sent` / `ESTABLISHED` /
  `RST sent` / `checks passed=7 failed=0`（R2.2d 之后探针多了 socket established /
  send accepted / tx acked 三项）；`skipped/no-dhcp-server` 算失败。
  退出码 2 = 前置缺失，1 = 证据不符。实测 `gate-board: PASS — wire: checks passed=7 failed=0`。
  脚本内置 NixOS 的两处坑：剥掉 `LD_LIBRARY_PATH`（否则 esptool/zig 撞 glibc）、
  显式指定带 pyserial 的解释器。
- `net-wire` 可选 profile（`-Dwire=true`）：生产固件在真实链路跑 DHCP
  DORA + TCP 三次握手，host 侧 dnsmasq/socket 监听为前置；无 DHCP 时优雅跳过。
  板级证据 `logs/e2e-net-wire-boot.log`。

### Removed
- `tests/e2e/run_e2e.py` 的 `expect="overflow"` 死分支：P0.2 扩容后已无 profile 使用，
  两段窗口容量改由 `scripts/check-capacity.py` 门禁。

### Fixed
- `tests/e2e/run_e2e.py` 的 board case 现在**自己**删旧日志并要求本轮产生日志：此前只有
  `gate-board.sh` 做这件事，任何直接调 `--board` 的路径（比如手工跑 `--profile full`）在
  flash 失败后都会拿上一轮文本当本轮证据——本轮实测踩到（`esptool: command not found` 后
  断言仍然“通过”）。
- 板子重新枚举成 `/dev/ttyUSB0` 时门禁会假绿：`run_e2e.py` 的 board case 硬编码
  `/dev/ttyUSB1`，于是走 `SKIP` 分支并以 0 退出。现在 `run_e2e.py` 认 `BOARD` 环境变量，
  `gate-board.sh` 在 ttyUSB1/ttyUSB0 里挑存在的那个并把 `BOARD` 传给 e2e；
  junit 的 `<skipped/>` 仍算失败（本轮正是靠这条断言发现的）。
- net-ethernet：DMA 不取描述符的根因是 APM 控制过滤器。IDF app 在
  `bootloader_init_mem()` 里关闭 `HP/MEM/LP_APM_FUNC_CTRL`，二级 bootloader
  因 `#if !BOOTLOADER_BUILD` 跳过；`enableBusClock()` 现补 `enableApmForDma()`。
  板侧：TX `done in 15us`、RX 2 帧 94 B IPv6 组播。
- net-ethernet：补 YT8531 RGMII 专用初始化（EXT `0xA001` bit8、
  EXT `0xA003` 低字节 `0xDD`），并把 MDIO 事务改成 IDF 顺序（先写
  GMIIDATA，再写地址+write+busy）。修正后主机 `rx_packets` 0→1，
  线上 TX 打通。

### Added
- `net-wire` 可选 profile（`-Dwire=true`）：生产固件在真实链路跑 DHCP
  DORA + TCP 三次握手，host 侧 dnsmasq/socket 监听为前置；无 DHCP 时优雅跳过。
  板级证据 `logs/e2e-net-wire-boot.log`。

### Fixed
- net-ethernet：新增 `rxPollCopy`（整帧拷贝，含 FCS 长度语义），供 IPv4/ARP/TCP 使用。
- net-udp-dhcp-dns：DHCP `Builder.finish()` 按 RFC 2131 补到 300 字节；新增
  `findAnswerNamed()` 返回带长度的 DNS 名字视图。
- E2E profile 的 section 清单补上 `net_ethernet`（构建一直包含它，断言漏了，board e2e 会误报 section 集合不匹配）。

### Changed
- P0.2：flash 窗口扩至各 0x7F000、drom 基址 0x40080020，全特性单镜像可链接（板上 11/11）
- 组件内 `hw.zig`/`log.zig` 副本移除，统一引用 `board.hw` / `board.log`
- net-tcp：`checksum.Sum.add` **把进位折叠推迟到末尾**（RFC 1071 §2 允许），并按 4096 字
  做有界折叠以保证任意长度切片都安全。原先每个字都做两次折叠，是 rv32 上校验和的主要开销。
  该轮板级实测（ch21-cwnd-emac-lab）：`cksum_us` 6423 → **4778**（126 → 96 µs/帧，
  口径是“走 `fillTcp` 的数据帧”；零拷贝组帧后数据帧的这项已并入 `asm_us`，
  小帧仍走这条路径）。
- net-tcp：`checksum.Sum.add` 把 16 位字循环**展开 4 个字（8 字节）/轮**；有界折叠
  （每 4096 字）、奇数字节配对与尾部逻辑不变。板级（ch21-cwnd-emac-lab，两轮）：
  `asm_us` 11440 → **8111**、整轮 13.8 → **10.4 ms**、吞吐 4.75 → **6.26–6.32 MB/s**，
  主机 7.5 → 3.3–4.2 ms，`mismatches=0`。线上语义已用生产 `net-wire` 复验：
  `wire: checks passed=4 failed=0`、`main: verdict=pass`。
- net-tls-http: 新增 tls_protect.zig — 记录保护(nonce=iv^seq, AD=外层头, 内层类型藏在明文末尾); seal 成功后自己递增序号，open 失败不推进; 用例 5 条; 48 -> 53.
- net-tls-http：补一条**降级可见性**用例：链模式在 `now == null`（无可信时钟）时校验通过但
  `expiry_checked == false`，该标志必须被日志引用。67 → 68 项。
- net-tls-http：`tls_client` 接上**链模式**。`Options.trust_anchor_der` + `Options.now`：
  收到 Certificate 时把叶证书复制到稳定缓冲（重组缓冲会被下一条消息覆盖），用
  `chain.verifyChain` 校验（签发关系/签名/锚/主机名/有效期），CV 改用**叶证书公钥**验；
  `now == null` 时跳过有效期并置 `expiry_checked = false`（不允许拿构建期常量假装验过）。
  错误分类：`CertificateChainFailed` / `CertificateExpired` / `CertificateHostnameMismatch`。
  用例：fixture 私钥可由固定 seed 复现，所以能造**真签名**的 CV 走完整链；
  过期、主机名不符、坏锚各自在证书这一步失败。65 → 67 项。
- net-tls-http：`Cert` 给 SAN 条目加了**类型标记** `san_is_ip`，`chain.hostnameMatches`
  只匹配 dNSName（RFC 6125 §6.4.4），不再把 iPAddress SAN 当主机名比较。回归用例
  fixture（含 `ch23.local`、`www.ch23.local`、`127.0.0.1`）：DNS 名字匹配、`127.0.0.1`
  必须不匹配。64 → 65 项。
- net-tls-http：新增 `chain.zig`——**信任链校验**的最小实现：叶证书的 issuer 必须等于签发者
  subject、签名必须被签发者公钥验过、有效期包含调用方给的 `now`、SAN/CN 覆盖主机名；
  **信任锚由调用方提供**（不采信对端链里的根），链顶不是锚时明确报 `UntrustedAnchor`
  而不是静默降级。主机名支持单级通配符 `*.example.com`（不匹配裸域/多级）。
  时钟不在组件里——没有 `now` 就不该声称验过有效期。60 → 64 项。
- net-tls-http：**修 Certificate 消息解析**——每个 `CertificateEntry` 在证书数据之后还有一个
  **2 字节的 extensions 长度字段**（RFC 8446 §4.4.2），原实现没读它，于是 `list_len`
  比条目之和多 2。板上实测：DER 完整（entry=426、`30 82 01 a6` 正确）而消息头宣告
  `list=431`，随后 `cert.parse` 因尾部多出 2 字节报 `BadCertificate`。测试用的构造器
  当初也漏了这 2 字节，所以 220 条用例全绿——现在补上并有专门的回归用例。59 → 60 项。
- net-tls-http：**修 `buildSchedule` 的双重哈希**。它接收的是转录**哈希**，但内部走
  `deriveSecret`（对 context 再哈希一次），于是 context 变成 hash(hash(CH‖SH))，与
  对端的 hash(CH‖SH) 不同 → 握手密钥全错、记录层 `RecordAuthFailed`，而转录哈希本身
  打出来是对的。新增 `expandToSecret`（context = 给定哈希）并让 `buildSchedule` 使用它；
  补一条 **RFC 8448 §3 向量测试**（这正是客户端实际走的路径，脚本化服务端两边同样多
  哈希一次，测不出来）。板上定位手段：`openssl s_server -keylogfile` 对拍。58 → 59 项。
- net-tls-http：**修 ServerHello 解析的线上格式错误**——`legacy_compression_method` 在
  ServerHello 里是**单字节**（RFC 8446 §4.1.3），原实现按 ClientHello 的
  `compression_methods`（长度+列表）读了两字节，导致其后所有扩展偏移错一位。
  板侧实测症状：`tlS: onRecord BadServerHello … BadCompression`，服务端其实已完整
  发出飞行（`openssl s_server -state` 显示 write server hello … write finished）。
- net-tls-http：新增 `Client.sealApplication()`——用应用密钥封上层记录（HTTP 走这里）。
  只有 `established` 之后可用；用例用对端的 `client_ap_traffic` 解开并逐字节比对
  （顺带钉住方向：解客户端记录要用 client_ap，不是 server_ap）。57 → 58 项。
- net-tls-http：`trust_cert_der` 收紧为**钉住证书**（PIN）语义——此前只用钉住的公钥验
  CertificateVerify，等于"任何持有自己私钥的服务端都能过"（CV 用它的公钥验它自己的
  签名）。现在对端出示的叶证书必须与钉住的 DER **完全相同**，否则 `CertificatePinMismatch`。
  新用例：钉的是别的证书、服务端出示 fixture → 在证书这一步失败。56 → 57 项。
- net-tls-http：`tls_client` 收口四处会在板上表现为"莫名失败"的问题：
  ① **应用阶段解不开**：`handleProtected` 固定用 `server_hs`，established 后必须换成
  `server_ap`（新用例：服务端用应用密钥发一条 HTTP 数据，客户端必须解开）；
  ② **错误不可分辨**：`BadFinished`/`RecordAuthFailed`/`ServerAlert` 各自独立，不再统统
  折成 `UnexpectedState`（板上日志要能区分伪造 Finished、坏 MAC 与对端 alert）；
  ③ **叶证书切片悬空**：`?cert.Cert` 持有重组缓冲的切片，下一次 push 即失效；改为只留
  SHA-256 指纹与判定布尔；
  ④ **自签校验当门槛**：CA 签发的叶证书本就不是自签的，自签校验失败不再中断握手，
  只记录 `certificate_verified_self_signed`；信任仍由 `trust_cert_der`（PIN）决定。
  55 → 56 项。
- net-tls-http：新增 `tls_client.zig`——**客户端状态机**，把 CH→SH→EE/Cert/CV/Finished→
  client Finished 串起来并完成密钥切换。三处真 bug 在主机侧用例里被抓住：
  ① `MessageReader` 存了 `&msg_buf` 的悬空指针（`Client` 按值返回后失效，症状是深层
  解析 `BadLength`）；改为按 (buf,len) 现场构造视图。② `Client` 与 `Flight` 各持一份
  转录，Finished 校验用的是缺 CH+SH 的那份；改为 Flight 独占。③ Finished 用的是 AEAD
  key（16 B）而非流量密钥（32 B）。用例：脚本化服务端跑完整握手并对拍双方转录哈希、
  客户端 Finished 用 client_hs 密钥解开后逐字节相等、篡改服务端 Finished 必须失败、
  CCS 静默跳过、fixture 证书自洽验证通过且 `certificate_trusted=false`。53 → 55 项。
- net-tls-http：**修掉一个认证漏洞**——`Flight` 收到 Finished 时只把它计入转录、
  从未校验 verify_data，伪造的 Finished 会被接受。现在 `advanceFlight` 必须带
  `server_hs_traffic`，在**计入转录之前**取快照并验（RFC 8446 §4.4.4 的边界），
  失败返回 `BadFinished`；用例补上“伪造 verify_data 被拒”。同时 ClientHello 的
  `signature_algorithms` 只通告 ECDSA P-256（`cert.zig` 只验得了这个），
  不再通告 RSA-PSS——否则服务端选了 PSS 会在 CertificateVerify 处失败。
- net-tls-http：服务端飞行的其余消息与**认证核心**。`parseCertificate`（列表逐张切 DER）、
  `parseCertificateVerify`（scheme + 签名）、`parseFinished`（32 字节 verify_data）、
  `certificateVerifyContent`（64 空格 + 上下文串 + 0x00 + 转录哈希），以及
  `keyschedule.finishedVerifyData`（HKDF-Expand-Label("finished") + HMAC）与常数时间比较。
  `Flight` 状态机强制 EE → Certificate → CertificateVerify → Finished 的**顺序**，
  错序即 `UnexpectedMessage`（顺序是认证链的一部分）。另有 `cert.verifyMessage`
  用于验 CertificateVerify 的签名。44 → 48 项。
- net-tls-http：`parseServerHello` 收紧为**硬校验**——套件只接受 `TLS_AES_128_GCM_SHA256`
  （`BadCipher`）、`supported_versions` 必须是 0x0304 且必须存在（`BadVersion`）、
  `key_share` 必须存在（`MissingKeyShare`）。三者都是“能解析但继续会用错密钥”的情形：
  服务端若选 AES-256-GCM-SHA384，下游会按错误的密钥长度派生，表现为静默算错而不是报错。
  `ServerHello.key_share` 随之去掉 Option。42 → 44 项。
- net-tls-http：握手驱动的前半件——`Transcript`（流式 SHA-256，任意点取快照）与
  `parseServerHello`（random/套件/key_share/supported_versions，缺 key_share 时字段为
  null 由调用方判死，错类型/截断/坏扩展显式报错）。用例：手工按线上格式拼一条
  ServerHello 再解析回来、流式快照与一次性 `hash()` 逐字节一致、两端 ECDHE 交叉
  算出同一共享秘密后喂 `buildSchedule`。38 → 42 项。
- net-tls-http：补上 R2.3 的两个前置件。① `random.zig`——**熵源接缝**：
  `Reader`（tagged union，将来加 `.hardware` 会在编译期逼着所有调用点处理）+
  `Deterministic`（SplitMix64，测试用，`cryptographicallySecure()` 恒 false）；
  生产组件里**不携带**任何弱随机实现（测试流由用例自带）；板侧真熵源在
  `boards/esp32s31-coreboard/src/rng.zig`（LP TRNG 0x20814000，序列照抄 IDF
  `hal/esp32s31/include/hal/trng_ll.h` + `esp_hw_support/hw_random.c`）。② `tls_handshake.zig`——
  ClientHello 编码：记录/握手/扩展三层长度、SNI、supported_versions、
  supported_groups、signature_algorithms、key_share；记录层 legacy_version
  按 RFC 8446 §5.1 用 0x0301。32 → 38 项。
- net-tcp：新增 `Conn.windowUpdate()`。TCP 的接收窗口**不会**因为应用 `recv` 了数据就
  自动变大——只有下一次出向段带的新窗口才生效。接收缓冲排空后若不补发纯 ACK，
  对端会一直以为窗口为 0（症状：发送方 `send` 秒返回、接收方永远等不到下一字节，
  两端日志都"正常"）。只在仍可接收的中间态出段，`seq/ack` 取自当前状态。32 → 33。
- net-sockets：补上**客户端形状**（此前只有服务端）。新增 `State.syn_sent`、
  `Socket.enterConnect()`、`Table.connect()`；收到 `.syn_ack` 转 `established`，
  握手期间 `send`/`recv` 返回 `in_progress`（EINPROGRESS 的等价物，不是 `not_conn`）；
  RST 回 `closed` 并置 `reset_seen`、槽位可复用。线路上的三次握手仍由 `tcp.Conn` 负责，
  本层只镜像状态——这正是 TLS 客户端在板侧需要的入口。36 → 38 项。
- net-sockets：把 `onSegment` **不校验什么**写进状态迁移表的注释，并用一条用例钉死：
  `.data` 不看 `seq`（按序到达假设），重传段再投递一次会把字节**再塞一遍**、`rcv_nxt`
  多算；`.ack` 不看 `ack` 值（`syn_rcvd` 见 ack 即 `established`）。⇒ 接真链路时
  **去重是驱动的责任**（按 `rcv_nxt` 只镜像新段），出向 seq 映射仍必须精确。35 → 36。
- net-sockets：`wire.zig` 改成**带基址**的映射。socket 层的 `seq`/`ack` 是从 0 起的
  **相对偏移**，真实 TCP 的序号从 ISS 起计，所以 RX 做 `seq − peer_iss` / `ack − local_iss`、
  TX 做 `local_iss + seq` / `peer_iss + ack`（`Bases{ local_iss, peer_iss }`，
  都是“数据流第一个字节”的序号，SYN 不占该偏移）。原样抄真实 seq 在注入模型下
  看不出问题，接真链路会立刻错位。另把 `drainTx` 的契约写准：**只在收到 ACK 之后**
  消费（`tx_buf` 是应用数据的唯一副本，重传还要用）。
- net-sockets：补上**真实链路的出向出口**——`txPending()` / `txSeqBase()` / `txPeek()`
  （`drainTx()` 原本就有）。注入模型下 `tx_buf` 只是汇、`tx_len` 只进指纹，
  接真链路时 socket 层写进去的字节必须能取出来发。**序号不变量**：`send()` 在
  缓冲时就推进 `snd_nxt`，所以待发区间的序号恰好是 `[snd_nxt - tx_len, snd_nxt)`，
  真实 `tcp.Conn` 的 ISS 要与之对齐，两套序号才不会分叉（见 `socket.zig` 注释）。
  主机用例 33 → 35（顺序/折返/基线前移）。
- net-sockets：新增 `src/wire.zig`——真实 `tcp.Segment` ⇄ 组件内 `netstub.Segment`
  的适配层（RX 的 kind 判定优先级 rst > syn|ack > syn > fin > data > ack；TX 的
  kind → flags 与端口/窗口上下文），不复制载荷、不碰网卡。主机用例 28 → 32；
  `firmware/build.zig` 的 host-test 模块补 `net_tcp` 导入（仅 net group）。
- net-tcp：`SEND_SLOTS` 8 → 32（每槽只记 `(seq, len)`，代价 256 B `.bss`），
  让慢启动能把 `cwnd` 长到 30 段上下再做拥塞避免。该轮板级实测（ch21-cwnd-emac-lab）：
  在途 10.2 KB → 20.3 KB、`srtt` 3.1 → 2.2 ms，但 64 KiB 传输吞吐 1.87 → 1.89 MB/s
  （噪声内）——队列深度不是瓶颈。后续归因与优化见 quartz 的
  `practice/zig-esp32-s31/logs/ch21-cwnd-cost.log` 与 `ch21-cwnd-opt{1,2,3,4}.log`
  （每帧 CPU 是瓶颈；零拷贝组帧后同一传输 23.4 ms / 2.80 MB/s）。
- net-tcp：`Conn` 从单段模型改成**有界多段在途**——固定发送队列（只记
  `(seq, len)`，不复制载荷、不分配），`sendData(len, inflight_cap, now_us)` 一次
  返回一段、由调用方按 `min(cwnd, rwnd)` 门控循环取值；累积 ACK 整段出队、部分
  ACK 只裁队首前缀；RTO 只重传队首（计时器仍在“未运行”时启动，见 RFC 6298 §5.1）；
  Karn 标志改为 flight 清空时复位。主机用例 27 → 32（覆盖 cap 门控、部分 ACK、
  队首 RTO、队列满、flight 清空）。
- net-wire：TCP 握手改由 `net-tcp` 的 `tcp.Conn` 驱动
  （`activeOpen`/`onSegment`/`tick`），删掉手写的 `syn_seq`/`server_seq`/`established`
  与 `sendTcp`；ESTABLISHED 后仍立刻 RST。板侧 `wire: tcp ESTABLISHED
  state=ESTABLISHED snd_una=0x20263112`（= iss+1，SYN 已被确认）、
  `wire: checks passed=4 failed=0`，`logs/e2e-net-wire-boot.log`。

## [0.3.0] - 2026-11-13

### Changed（破坏性）
- 项目更名 `s31-zig-system` → `s31-firmware`：仓库/目录、`esp_app_desc_t.project_name`、
  固件 banner、IDF 工程名（`zig_s31_system_firmware` → `zig_s31_firmware`）全部更新
- 启动路径唯一化：删除 `boards/.../start.zig`，`_start` 与 app_desc 只归 `firmware/src/start.zig`
- E2E 板级用例先按 profile 构建、镜像同步到 `zig-out/bin/app.bin`，段集合改为精确相等断言

## [0.2.0] - 2026-11-13

### Added
- 测试框架：`docs/TESTING.md`、`scripts/check-all.sh`、单元覆盖率门禁（模块可达性 + 基线）、
  E2E profile 矩阵与 JUnit 报告（`tests/e2e/run_e2e.py`）

### Changed
- 重构为生产结构：`firmware/` + `boards/` + `components/`，移除章节目录（历史见 `docs/HISTORY.md`）
- 新增编译期特性开关与聚合测试（11 个组件，323 项）
- 新增仓库规范、路线图、CI、脚本与 ADR 模板
- 默认配置（boot+net）上板：6 个子系统自检全过，`main: verdict=pass`（`logs/firmware-boot.log`）

## [0.1.0] - 2026-11-13

### Added
- 从 `hl-ljj-quartz@32f10c56` 迁出 28 个章节工程与 `tools/s31-production` 生产化原型
- 板侧日志（`logs/ch05-boot.log` … `logs/ch28-boot.log`，含 ch28 修复前 `ch28a-boot.log`）
- 仓库规范：`AGENTS.md`、`docs/REPO-STANDARDS.md`、`ROADMAP.md`

### Fixed（相对迁出来源）
- Zig 0.17 `[...]T{…} ** n` 数组重复语法（平台迁移到 `@splat`）
- ch28 首烧 `mstatus.FS=0` 导致浮点指令 illegal instruction
- provisioning 两条过强不变量测试
