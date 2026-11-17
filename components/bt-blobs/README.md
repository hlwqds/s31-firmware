# bt-blobs —— BLE controller 归档在裸机镜像里的适配面

把 IDF 的 BLE controller 归档（`libble_app` / `libbtdm_common` / `libbtbb` / `libphy`）
链进 ESP32-S31 的两段镜像，并补齐它要求宿主提供的符号。

- 来源章节：博客 `ch27-ble-802154-boundary` §27.11（边界：真实扫描/连接/特征值需要什么）
- 路线图：`practice/zig-esp32-s31/ROADMAP-real-link.md` 的 **R3.3**
- 先例：`components/wifi-blobs/`（Wi-Fi blob，同一套"只从 `.a` 拉需要的对象"手法）

## 验证状态

**只到"链接成立、镜像合法"这一级**（2026-11-17）。**控制器还不能跑**：

| 级别 | 状态 | 证据 |
| --- | --- | --- |
| 归档能链进两段镜像 | ✅ | `.flash.text` 699 856 / 窗口 720 896（余 21 040）；`elf2image` 成功，`image-info` 恰好 2 条 `DROM, IROM` |
| 闭包被真拉进来 | ✅ | 镜像里的字符串可见 `btdm_hci_trans.c`、`btdm_sleep.c`、`btdm_broker.c`；`.iram_blobs` 0 → 60 224 B |
| `r_ble_controller_init` 调用 | ❌ 未做 | 需要 `esp_btdm_controller_config_t`（含 `magic`）的逐字段镜像 |
| HCI 传输口打开 | ❌ 未做 | `hci_transport_init` **不在归档里**，是 IDF C 源 |
| HCI Reset / Read Local Version 有应答 | ❌ 未做 | 需要一个 HCI host 侧（计划自己写 3 个 `hci_driver_ops`） |
| controller 的 56 个弱断言占位 | ✅ **56/56 全部有强定义**（36 OSAL + 11 coex + 8 log + 1 assert；逐条对归档调用集核过，差集为空） | 见下方待验证项 4 |

> 别把"链接成立"读成"controller 可用"。真实扫描/连接离这里有整整一个传输层。

## 快速开始

归档**不入库**（解包产物是生成物）。先解包到本地目录，再给构建两个开关：

```bash
# 1) 解包四个归档（任选一个临时目录）
T=${TMPDIR:-/tmp}/bt_all && rm -rf "$T" && mkdir -p "$T"
AR=$(ls -d ~/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin | head -1)/riscv32-esp-elf-ar
for a in \
  ~/esp/esp-idf/components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libble_app.a \
  ~/esp/esp-idf/components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libbtdm_common.a \
  ~/esp/esp-idf/components/esp_phy/lib/esp32s31/libbtbb.a \
  ~/esp/esp-idf/components/esp_phy/lib/esp32s31/libphy.a ; do
  mkdir -p "$T/$(basename "$a" .a)" && (cd "$T/$(basename "$a" .a)" && $AR x "$a")
done

# 2) 只取闭包里的成员（全量 179 个会到 423 KB，闭包 113 个约 420 KB 里的大头都在 libble_app）
#    闭包用 nm 符号图从归档外的入口算出来；详见 ROADMAP R3.3 与技能
#    idf-blob-adaptation-surface-measure
#    这里直接给"全部成员"的保守用法（等价 --whole-archive）：
mkdir -p "$T/flat"
find "$T" -name '*.o' -exec cp {} "$T/flat/" \;

# 3) 构建（产物仅用于 elf2image 验证段数与容量，**不上板**）
cd firmware
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
  -Dbt-blob-dir="$T/flat" -Dbt-blob-objs="$(ls "$T/flat" | paste -sd,)"
```

镜像与判据：

```bash
PY=~/.espressif/python_env/idf6.1_py3.13_env/bin/python   # 该 venv 的 python 才能 import esptool
$PY -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o /tmp/bt_app.bin zig-out/bin/app.elf
$PY -m esptool --chip esp32s31 image-info /tmp/bt_app.bin | grep -c 'DROM, IROM'   # 必须 == 2
```

## 文件职责

| 文件 | 职责 |
| --- | --- |
| `link/bt_stubs.c` | 归档要求宿主提供、且**确实由我们给**的 C 侧符号（断言/日志/printf 族） |
| `src/osal.zig` | OSAL 核心 + coex 钩子 + **59 个 C ABI 导出**（归档会调的 **36 + 11** 逐个点名核对）；15 个主机用例 |
| `src/host_tests.zig` | 主机测试入口（`zig build test` 会跑到） |
| `src/probe.zig` | 板上探针（`-Dbt-probe`）：装钩子 → arena → init → enable → 进任务 → 发 Reset → 泵任务 |
| `src/root.zig` | 单一模块根：所有文件属于同一个模块（分两个会报"文件属于多个模块"） |
| `tools/gen-bt-closure.sh` | **重新生成闭包对象清单**（解包 4 归档 → 符号图 BFS → 减 ROM → 打印构建命令） |
| `src/sched.zig` | 协作式上下文切换（rv32 64 字节帧）+ 任务表 + `block()`/`resumeTask()` |
| `src/transport.zig` | HCI 传输层（自有 ops + 下行分发 + 事件回程），含 `sendReset()`/`sendReadLocalVersion()` |
| `src/extfuncs.zig` | `ext_funcs_t`（rv32 **40 字节**）：controller 的 malloc/free/rand/assert 表 |
| `src/bringup.zig` | init（13 步）/ enable（6 步）编排，状态机 `idle→inited→enabled`，附 `getStatus()` |
| `src/porting.zig` | IDF porting 层的 C 函数在裸机侧的实现：4 个空实现 + `ble_msys_init` + mempool 容量校验 |
| `src/config.zig` | `esp_bt_controller_config_t` 逐字段镜像（60 字段、**每字段偏移都断言**）、`defaults()`、`elemCalc()`/`mempoolElemNum()` |
| `tools/btcfg-probe.{c,sh}` | 用 rv32 gcc 把 `sizeof`/`offsetof` 发射成常量表再读回（交叉产物跑不了） |

**两条形状纪律**（踩过就炸内存）：

1. **槽位是 4 字节**：C 的 `struct btdm_osal_{event,eventq,callout,mutex,sem}` 全是单个 `void *`，
   而它**内嵌在 controller 自己的结构体里**。`Slot` 是 `extern struct { p: ?*anyopaque }`，
   所有状态对象从**静态记录池**分配、指针写进 `slot.p`。直接把状态对象往传入指针上写会溢出、
   踩坏 controller 的内存——主机用例 `slot: 与 C 的 4 字节句柄同形` 用金丝雀盯着这件事。
2. **不用 allocator**：`std.heap.page_allocator` 在 `riscv32-freestanding` 上**没有后端**
   （主机 x86_64 上却正常 ⇒ 假绿）。池数组本身就是存储，每个记录带 `in_use` 标志。
| `firmware/build.zig` 的 `bt_blob_dir` 块 | 把对象逐个加进链接；`bt_added == 0` 直接 panic |
| `boards/esp32s31-coreboard/linker/s31.ld` | ① 收 `.iram_sleep*` / `.iram_single_sleep*` 进 `.iram_blobs`；② `PROVIDE` 5 个 `*_btdm` 边界 |
| `boards/esp32s31-coreboard/linker/rom_syms.ld` | `abs` / `ets_printf` / `printf` / `phy_set_chan_freq_sw_start` / `ets_clk_get_xtal_freq` |

## 桩语义（哪些是假值，别当真）

| 符号 | 当前实现 | 说明 |
| --- | --- | --- |
| `rtc_clk_xtal_freq_get` | **转发 ROM** `ets_clk_get_xtal_freq` | 返回**真**频率（Hz）。controller 的时基全从这里推，早期写成常数 40 是错的（差 1e6 倍） |
| `__assert_func` | 打印 `file:line func: expr` 到串口后死循环 | 断言时先留线索，不静默挂死 |
| `sprintf` | 写空串、返回 0 | **占位**。若某条路径拿它拼 MAC/版本串再解析，会拿到空串 |
| `phy_printf` | 丢弃 | 占位（controller 的日志）；取证靠 HCI 字节流而不是它 |
| `e_btdm_lp_modem_clock_set` | no-op，返回 0 | 时钟树由 board 层统一管理 |
| `_bss_start_btdm` … `_data_start_btdm_rom` | **零长度区间**（`start == end`） | `112.o` 的用法是 `memset(start, 0, end-start)`；本布局 `.bss` 已由 `_start` 清零、`.data` 的 LMA == VMA，故零长度语义等价 |

`printf` / `ets_printf` 走的是 **ROM 的格式化器**（走 ROM 的 UART 配置，不是我们的板日志）。
里程碑 2 接 HCI 时若要统一日志，需要把这两个换成自己的 shim。

## 布局实测（`tools/btcfg-probe.sh`）

```text
sizeof(esp_bt_controller_config_t) = 192
  ble   @ 0     (112 字节)
  bredr @ 112   (56 字节，含 8 个 C 位域 ⇒ [56]u8)
  btdm  @ 168   (20 字节)
ble 内: config_version@0、rtc_freq@24（u64，Hz）、main_xtal_freq@84（u8，MHz）、config_magic@108
btdm 内: version@0、magic@16
```

`config.zig` 用 13 条 comptime 断言把这些数字钉住——**字段类型写错会当场编译失败**，
不需要上板才发现。`esp_bt.h` 本身交叉编译不出来（它会拉 FreeRTOS 的 `portmacro.h`），
所以探针只抄了 `esp_bt.h:176-323` 的结构体本体。

## 元素计数（`btdm_osal_elem_mempool_init` 的输入）

`elemCalc()` 复刻 `ble.c:1586-1607`：先调归档的 `r_ble_ll_get_npl_element_info(cfg, &ll)`
（传**整个 config**，不是 `&cfg->ble`），再累加。两个必须照抄的点：

1. **seed 不是零**：`bt.c:172-178` 在算之前预置 `{ evt=103, evtq=3, co=10, sem=0, mutex=1 }`
   ⇒ 从零开始会少算 103 个事件。
2. **五个宏是交叉用的**：`evt` 用 `BLE_HOST_CO_COUNT`、`evtq` 用 `BLE_HOST_EV_COUNT`、
   `co` 用 `BLE_HOST_EVQ_COUNT` —— 看着像 IDF 的笔误，但归档依赖这个语义，别"修正"。

NimBLE 开启时 host 常量是 `co=8 / ev=19 / evq=3 / sem=10 / mutex=4`，每项再加 `+10`。
按默认 config 算出的上限（事件 ~181）决定了池要 ≥192。

## porting 层：9 个 C 函数只有 1 个是硬活

| 函数 | 实现 | 依据 |
| --- | --- | --- |
| `btdm_log_init` / `btdm_external_init` / `btdm_coex_init` / `btdm_lp_init` | `return 0` | IDF 原文就是空实现（coex 在 `CONFIG_SW_COEXIST_ENABLE` 关时；lp 的两个分支都不进） |
| `ble_controller_scan_duplicate_config` | 空操作 | 调的是 NimBLE **host** 侧 `ble_vhci_*`（全归档 `grep ble_vhci` 零命中）⇒ controller-only 没有 host |
| `ble_msys_init` | 转调归档 `r_esp_ble_msys_init` | 常量取 `host/nimble/Kconfig.in:480-511` 的 **SOC_ESP_NIMBLE_CONTROLLER 分支**：`24/128`、`24/320`、`from_heap=y` |
| `btdm_osal_elem_mempool_init` | **容量校验**（`elemMempoolInit`） | IDF 池空会回退动态 malloc，我们**没有回退** ⇒ 超限按类返回 `-1..-5` 并打印 5 个数字 |
| `btdm_lp_enable_clock` | 🟡 **空实现 + 大声日志**（故意） | HCI Reset / Read Local Version 是**软件层**命令，未必需要射频时钟 ⇒ 先空着；一旦 controller 碰 MAC 寄存器就 fault，再补下面那张表 |
| `btdm_lp_reset` / `btdm_coex_enable` | 无状态 / 返回 0 | 软件共存未开 |

⚠ **时序**：`btdm_lp_enable_clock` 在 `r_btdm_task_init` **之前**（`bt.c:234` vs `236`）。

### `btdm_lp_enable_clock` 补实现时的规格（已查全，别重查）

`modem_clock_module_enable(PERIPH_BT_MODULE)` = `BLE_CLOCK_DEPS`，**8 个门**：

| 门 | HAL |
| --- | --- |
| BLE_MAC | `clk_conf1.clk_btmac_en` |
| BT_I154_COMMON_BB | `enable_bt_bb_clock` |
| ETM | `enable_etm_clock` |
| **COEXIST** | **在 lpcon 块**（`modem_lpcon_ll_enable_coex_clock`）——别只改 syscon |
| WIFI_BB_80X1 | `enable_wifibb_80x1_clock` |
| SOC_PLL_SOURCE_CG | `modem_clock_hal_enable_soc_pll_source_cg` |
| BT_APB | `enable_bt_apb_clock` + `enable_modem_sec_apb_clock` |
| BT_PERIPHERAL | `enable_modem_sec_clock` + `enable_ble_timer_clock` |

`modem_clock_module_enable(PERIPH_BT_APB_MODULE)` = `BT_APB_CLOCK_DEPS`，**4 个门**：
BT_APB、ETM、SOC_PLL_SOURCE_CG、BLE_MAC。
`modem_clock_module_mac_reset(PERIPH_BT_MODULE)` 单独一份（复位 BT MAC）。

两条纪律：① **宁可多开不要少开** —— 少开一个门，controller 访问该外设就是**总线挂死**（比缺时钟更糟），
多开只浪费功耗 ⇒ 照 `BLE_CLOCK_DEPS` 全开；② 裸机没有 `esp_os_enter_critical_safe` ⇒
单核下用"关中断写寄存器再开"代替。

## 编排（`bringup.zig`）

`init(cfg)` 13 步、`enable()` 6 步，状态机 `idle → inited → enabled`，
并提供 `getStatus()`（HCI 传输层开头就拿它做门禁，非 ENABLED 直接 -1）。

**顺序上最容易错的两点**：

1. **`r_btdm_task_enable` 在 enable 的最后一步**，不在 init 里——只做 init 的话 controller
   任务永不启动，HCI 不会有回包，症状就是"起来了但不发射"。
2. **`r_btdm_hci_fc_env_init` 必调**：`UC_BT_CTRL_CONN_FC_ENABLE` 在 `btdm_user_cfg.h:108`
   是硬编码 1，IDF 的 init 链无条件调用它。

**公有地址（init 第 14 步）**：`r_esp_ble_ll_set_public_addr(mac)`（归档 ✓），`mac` 由
`readEfuseMac` 取到后**字节逆序**（IDF 也是 `swap_in_place(mac, 6)` 之后再设）。
没有公有地址时 **HCI Reset 能过，但扫描/广播命令全部无效** —— 这是"命令有回包但没效果"的典型成因。

**必须注册的一步**：`esp_register_ext_funcs(&table)` —— 那张 `ext_funcs_t`（`ble.c:97-109`，
rv32 上 **40 字节**：`u32 ext_version` + 8 个函数指针 + `u32 magic`）里装的是 controller 侧的
**`_malloc` / `_free` / `_os_random` / `_osi_assert`**。跳过就等于 controller 没有分配器，
`r_ble_controller_init` 必然失败。

| 项 | 值 |
| --- | --- |
| `ext_version` | `0x20250819` |
| `magic` | `0xA5A5A5A5` |
| `_malloc/_free` | 我们的 `wr_btdm_osal_malloc/_free`（都走 arena） |
| `_os_random` | `osal.randomU32()`（板级可注入真 TRNG） |
| `_osi_assert(u32 ln, const char* fn, u32 p1, u32 p2)` | ⚠ **行号在前、函数名在后**（与 `__assert_func` 相反） |
| 三个 ECC 项 | **返回 -1** —— 与 IDF 在 `CONFIG_BT_LE_SM_LEGACY/SC` 未开时一致（`ble.c:506-522`）⇒ 不需要 ROM ECC |

每个失败都记 `stats.failed_step` + `last_rc` 并打印，所以板侧日志能直接指出停在第几步。

## HCI 传输层（`transport.zig`）

我们**自己拥有**这层（不碰归档里没有的 `hci_driver_vhci_ops`/`uart_ops`）：

| 环节 | 做法 |
| --- | --- |
| `ops` | 3 个函数指针：`tx(type,data,len,dir)` / `init(cb)` / `deinit()` |
| 下行 | 我们的 `forward`：`TYPE_CMD` 时 `pkt = @ptrCast(data)` → `r_btdm_hci_trans_rx(pkt)` |
| 事件上行 | `r_ble_hci_trans_cfg_hs(leEvtTx, NULL, leAclTx, NULL)` |
| BTDM 上行 | `r_btdm_hci_trans_register_tx(btdmTx, false)` |

三个必踩点：

1. **别手搓 12 字节包** —— 用归档的 `r_btdm_hci_trans_buf_alloc(TYPE_CMD=0x01, 0)`，
   填 `pkt.data`（载荷）/`pkt.length` 即可。
2. **必须置 BLE 位**（`r_btdm_hci_pkt_flag_ble_setf(pkt, 1)`），否则包被当 BR/EDR 路由，
   症状是"命令没人接"。
3. 回程字节在 `pkt.data`/`pkt.length`；我们是 host ⇒ **读完自己释放**
   （`r_ble_hci_trans_buf_free(载荷指针)`，它收的是**载荷**不是包）。

**判据**：HCI Reset 的成功回程是 **`04 04 0E 03 0C 00`** —— 最后那个 `00` 才是 status 成功，
只看"有回包"不够。

事件字节布局 `[0]=0x04, [1]=len, [2]=event code`，总长 `cmd[1]+2`；回调里先打日志
（每个字节一行，最多 16 个）再转发。

**两条发命令的路，先试 B**：

| 路径 | 写法 | 备注 |
| --- | --- | --- |
| **B**（host 层入口，代码少一半） | `r_ble_hci_trans_buf_alloc(3)` → 填 `opcode小端+plen+params` → `r_ble_hci_trans_hs_cmd_tx(buf)` → `r_ble_hci_trans_buf_free(buf)` | `BLE_HCI_TRANS_BUF_CMD = **3**` |
| **A**（IDF transport 路径） | `r_btdm_hci_trans_buf_alloc(1, 0)` → 填 `pkt.data/length` → `set_ble_flag` → `r_btdm_hci_trans_rx(pkt)` | `HCI_DRIVER_TYPE_CMD = **1**` |

⚠ 两个分配器的 type 值**不同**（3 vs 1），别混用。

**前置**：`sendCmd` 只有在 `bringup.status()==enabled` 后才有意义——`r_btdm_hci_trans_rx`
开头查 `esp_bt_controller_get_status()`，非 ENABLED 直接 -1。

## 调度器（`sched.zig`）

从 `wifi-blobs/src/sched.zig` **复制**而来（不 import 它，否则会把 wifi blob 的依赖拖进来），
并加了 controller 真正需要的东西：

| 能力 | 实现 |
| --- | --- |
| 任务表 | `taskCreate(stack, entry, arg)`：`initContext` 建帧（栈内**最后一个 16 对齐地址**） |
| 阻塞 | `block()` = `swapContext(current, main)` —— 任务的 `sp` 被存下，恢复后**从原地继续** |
| 恢复 | `resumeTask(ctx)` = `swapContext(main, task)` |

**为什么必须有**：BLE 的任务体是 `sem_pend(FOREVER)` / `eventq_get(FOREVER)` 的**死循环**。
只登记不建上下文 ⇒ 任务永不执行 ⇒ init 会"成功"然后什么都不发生；
若建立了却**阻塞时不切回主上下文** ⇒ 主循环饿死、连串口日志都出不来（日志在主循环里）。

**OSAL 侧的接线**（`osal.zig`）：

| 原语 | 行为 |
| --- | --- |
| `sem_pend(FOREVER)` 且计数 0 | 记下 `waiter` → `sched.block()` → 唤醒后**重新检查**（while 循环） |
| `sem_release` | 计数 +1；若有 `waiter` → `resumeTask` |
| `eventq_get(FOREVER)` 且队列空 | 同上 |
| `eventq_put` | 入队；若有 `waiter` → `resumeTask` |

⚠ 调度器**未启动**时（`sched.isStarted()==false`，例如主机测试）阻塞退化成返回 `TIMEOUT`
并计入 `stats.blocked_calls` —— 保证不会无限自旋。

⚠ `task_create` 现在真的从 arena 分 `stack_size` 字节栈（16 对齐）并建上下文；
arena 或任务表满时退回"只登记"并**打一行日志**（不静默）。

## 探针（`src/probe.zig`，`-Dbt-probe`）

**实验脚手架都收在开关后面，默认关**（保留是为了可复现，不干扰正常 bring-up）：

| 开关 | 作用 |
| --- | --- |
| `probe.dump_rom` | 启动时 dump ROM 区（`0x2f83efb0`/`0x2f812180`）与 UART0 寄存器（`0x2038A000`） |
| `probe.ble_block_experiment` | 复位脉冲 + 时钟重开 + `bt_bb_v2_init_cmplx(1)` + 读 `0x2010B000` |
| `bringup.skip_task_init` | 跳过 step 6 让链继续（**默认 false**；设为 true 会崩在 step 10 的空指针，见下） |
| `probe.probe_irqs` | 武装 T0 + 开中断（PC 采样用） |
| `probe.verbose` | 是否把 `osal.logPublic` 每行打到 UART |
| `porting.clock_writes_enabled` | 是否真的写时钟门控（对照实验用） |

⇒ 默认全关时，探针只做"装钩子 → arena → init → enable"，日志干净。


顺序（三个点错一个就白跑一趟）：

1. **先装钩子**：`now_ms = hw.nowUs()/1000`（**毫秒**，不是微秒）、`log` 同步刷 UART、
   `irq_save/restore` 暂空、`setMacHook` 给出厂 MAC。
2. **arena 最先初始化**：`r_btdm_task_init` 内部调我们的 `task_create`，要从 arena 分 8 KiB 栈；
   arena 没初始化 ⇒ `alloc` 返回 null ⇒ `task_create` 返 ENOMEM ⇒ init 链**第 4 步**失败，
   报错会指向"task_init 失败"而不是"arena 没初始化"。
3. `init`（15 步）→ `enable`（6 步）→ **`sched.startScheduler()`**（只有第一次进任务用它）
   → 发 `HCI Reset` → 主循环周期 `resumeTask` + `serviceCallouts`。

**日志怎么读**：

| 现象 | 结论 |
| --- | --- |
| 没有 `bt task round` | 任务从没跑过（`start` 没生效 / 任务没建出来） |
| 有 round、命令已发、没有 `EVT` | 任务跑了但没回包 → 查切片 E / 时钟门控 |
| 有 `EVT` 但 status≠0 | 回包了但命令失败 |

## 构建配方可复现（`tools/gen-bt-closure.sh`）

之前闭包清单只存在于 `/tmp`，换台机器镜像就编不出来。现在一条命令重建：

```bash
bash components/bt-blobs/tools/gen-bt-closure.sh /tmp/bt_all
# → 打印 116 对象闭包、减 ROM 后的未解析符号、以及可直接复制的 zig build 命令
```

**根集合 = 我们的 Zig 直接调用的每一个归档符号**（任务/流控、两个 stack、公有地址、msys/ext_funcs、
HCI A 与 B 两条路径）。少一个就会出现"链接期 undefined"——实测踩过：加 `r_base_stack_initEnv`
才发现闭包漏了它。

## 板上实测（2026-11-17）

跑到 init **step 6 `r_btdm_task_init` 内部**停住。用 TIMG0 T0（2 ms）采样被中断的 PC：

| 观测 | 值 |
| --- | --- |
| PC | `0x2f83efda` ×13、`0x2f812220` ×5（都在 ROM 区） |
| `mac` | **28/28 全是 `0x0000e000`** |

⇒ **`MAC_ST & 0xE000 != 0`** —— 与 Wi-Fi controller 的卡点是**同一组只读忙位**。

**死等的循环本身已经反汇编出来了**（把 ROM 区那两段字节读出来离线反汇编，不需要 JTAG）：

```asm
2f81221a: addi s1,zero,127          # s1 = 127
2f81221e: mv   a0,s0                # ← 循环头
2f812220: swsp a1,12(sp)
2f812222: jal  ra,0x2f83efca        # 调下面的"读字节"叶子函数
2f812226: lwsp a1,12(sp)
2f812228: bltu s1,a0,0x2f81221e     # while (127 < byte) 回到循环头
```

被读的那个字节由叶子函数算出：

```asm
2f83efca: lui  a5,0x20
2f83efce: addi a5,a5,906            # a5 = 0x2038A
2f83efd2: add  a0,a5
2f83efd4: slli a0,0xc               # a0 = (arg + 0x2038A) << 12
2f83efd6: lw   a0,28(a0)            # 读 u32
2f83efd8: srli a0,0x10
2f83efda: andi a0,a0,255            # 取 (val>>16)&0xFF
2f83efde: jr   ra
```

⇒ **判定式**：`while (((*(u32*)(((arg + 0x2038A) << 12) + 28) >> 16) & 0xFF) > 127) {}`。
采样到的 `a0=0xE080` ⇒ 轮询地址 **`0x2E40A01C`**。

**采样点落在 0x2f83efda 上 13 次**不是因为它在那里转，而是因为它是个**叶子函数、被这个循环高频调用**
——采样器每次都恰好打断在这次读字节上。

⇒ 下一步只要弄清 `0x2E40A01C` 是哪个外设的哪个状态字节（以及 127 这个门限的含义），
就知道 MAC 在等什么。**这条路径完全不需要外部设备。**
两个 controller 都停在"MAC/PHY 内部状态从未离开 busy"，是同一个底层状态，不是各自的问题。

**已确证**（板侧，非推断）：12 个时钟门全部置上（`clk_conf=0x72601002`、`clk_conf1=0x00070080`、
`lpcon=0x00000006`）；池需求 `evt=187 evtq=33 co=41 sem=20 mutex=16`；init 链可达 step 5。

### 卡点的**确切位置**（2026-11-17，OSAL 入口追踪）

给 OSAL 每个入口加了有界日志（前 40 次）。板上 `r_btdm_task_init` 内部的调用序列**只打出一行**：

```text
bt bringup: enter step 6 r_btdm_task_init
osal> mutexPend tmo=4294967295        ← FOREVER，且之后再无任何输出
```

对照：把 controller 的 8 个日志桩全部静音（`-DBT_LOG_SILENT=1`，不写串口）后**结果完全一样**。
⇒ 所以既不是"日志灌死 UART"，也不是 `mutexPend` 之后又被别的 OSAL 调用卡住 ——
**卡在我们这次 `mutexPend` 返回之后、归档的下一个 `r_sym_bt_*` 里**。

反汇编 `r_btdm_task_init`（`libbtdm_common/21.o`，284 字节）给出的调用序列：

```asm
a:  beqz a0, .L95                     # cfg==null 检查
c:  lw   a3, 0(a0)                    # cfg->version
12: addi a4,a4,295  → 0x20260127      # BTDM_CONFIG_VERSION
18: beq  a3,a4,.L103                  # 版本校验（我们已填对）
1c: r_btdm_task_deinit                # 失败路径
40: r_sym_bt_OkE7...                  # init 步骤（失败 → s0=-3）
58: wr_btdm_osal_get_time_forever     ← 我们
66: wr_btdm_osal_mutex_pend           ← 我们（FOREVER）
78: r_sym_bt_2aNN...                  ← 卡在这里
a0: r_sym_bt_BOhff...
ae: r_sym_bt_HGbP...
```

### 采样器在卡点处失效的原因（已定位）

卡住期间 **T0 中断不再到来**（2 ms 周期、28 秒窗口本该上万次，实测只来 2 次）。两条补救都试过：

| 尝试 | 结果 |
| --- | --- |
| 关掉 controller 日志、减少 UART 流量 | 无效 |
| 把 CLIC 输入 25 变成 **NMI**（`CLIC_INT_CTRL_REG(25) = 0x10801064`，置 bit3 `nmies`） | 写入 `0x1fc00100 → 0x1fc00000`，**bit3 读回不置位** ⇒ NMI 未生效 |

⇒ 卡住处既不来普通中断、NMI 也配不出来 ⇒ **靠 PC 采样继续往下探这条路到边界了**。
下一步要么换仪器（JTAG 写监视点 / 逻辑分析仪），要么从归档侧继续静态分析。

### `r_btdm_task_init` 的完整调用序列（离线反汇编，284 字节）

```asm
0x0a: beqz a0, .L95                 # cfg==null 检查
0x0c: lw   a3, 0(a0)                # cfg->version
0x12: → 0x20260127                  # BTDM_CONFIG_VERSION
0x18: beq  a3,a4,.L103              # 版本校验
0x1c: r_btdm_task_deinit            # 失败路径
0x40: r_sym_bt_OkE7...              # 146 字节的 init 步骤
0x58: wr_btdm_osal_get_time_forever ← 我们
0x66: wr_btdm_osal_mutex_pend       ← 我们（FOREVER）
0x78: r_sym_bt_2aNN...              # **16 字节的良性 thunk**（初始化自环链表头，立即 ret）
0xa0: r_sym_bt_BOhff...             # ← 卡点在这之后
0xae: r_sym_bt_HGbP...
```

⇒ 已确认 `0x78` 的 thunk 是良性的（`lw a5,[LANCHOR0]; sw zero,0(a5); sw a5,4(a5); ret`），
所以停摆在 `0xa0` 及之后的归档符号里。

### 再排除三条（2026-11-17 晚）

| 假设 | 实验 | 结果 |
| --- | --- | --- |
| `mutex_pend(FOREVER)` 返回 TIMEOUT 让归档拿到意外错误码 | 把 `mutexPend`/`semPend`/`eventqGet` 的 FOREVER 改成**有界忙等**（绝不返回 TIMEOUT，除非自旋耗尽） | 仍卡；且日志显示 mutex 本来是**空的** ⇒ FOREVER 分支根本没走到 ⇒ **OSAL 语义排除** |
| 卡点函数里的 `wr_btdm_assert` 挂住 | 反汇编 `r_sym_bt_BOhff...` 发现它引用了 `wr_btdm_assert`（行号 308/311）；把断言改成**打印后返回** | 仍卡，且 `strong-assert` **命中 0 次** ⇒ **不是断言** |
| CLIC 写把 IE(bit8) 清了 | 掩码改为 `old & 0x107` | 已修（此前 `& 0x7` 会清掉使能位），但 NMI 仍未生效 |

### 日志通道必须**自己写 UART FIFO**（2026-11-17 关键工具）

`board.log.line` 走 ROM 的 `esp_rom_printf`，而 ROM 的路径是
`while (txfifo_cnt > 127) {}` **死等**。一旦 FIFO 不排空，**日志自己也挂住** ——
于是"卡住之后什么都看不到"，无法区分"程序停了"与"只是打印停了"。

⇒ 探针的 `logHook` 改成直接写 `UART_FIFO`(0x2038A000)，每字节做**有界**等待
（`txfifo_cnt >= 120` 时最多自旋 20000 次），等不到就**丢弃该次输出**。
代价是可能丢日志，收益是**日志通道永不堵死**。

用这个通道后确认：`mutexPend` 打印 `osal> mutexPend< OK` 后**正常返回**，
之后才停 ⇒ 卡点在归档随后执行的代码里（`r_sym_bt_HGbP` / `XPuqT` / `AJP6` / `waDX`
四个 14–186 字节的小函数，或其下层）。

### 卡点已收敛到 `r_sym_bt_XPuq` 内部（2026-11-17 最后一步）

用不阻塞的 UART 通道后，OSAL 追踪给出完整序列：

```text
bt bringup: enter step 6 r_btdm_task_init
osal> eventqInit
osal> eventInit            ← ×3（都成功）
osal> mutexPend FOREVER
osal> mutexPend< OK        ← 正常返回
（之后无任何输出）
```

⇒ `XPuq` 里还会再调一次 `wr_btdm_osal_event_init`，但**第 4 次没有出现** ⇒
卡点在 `XPuq` 内部、**它调 `event_init` 之前**。

`XPuq`（186 字节）前半段是一个**固定 16 次**的循环，按 16 字节步长修改 `0x2010B000..0x2010B100`：

```asm
10: lui  a5, 0x2010b        # 0x2010B000
20: lui  a2, 0xfff00        # 掩码 0xFFF00000
24: addi a3, a5, 256        # 结束 0x2010B100
28: lw   a4, 0(a5)
2a: addi a5, a5, 16
2c: and  a4, a4, a2
2e: sw   a4, -16(a5)
32: bne  a5, a3, .L547      # 固定 16 次，有界
```

`0x2010B000` = `MODEM_BASE + 0xB000`，位于 SYSCON(+0x9C00) 与 MODEM_PWR(+0xD000) 之间
⇒ 是 **BLE/MAC 寄存器块**。

⇒ 循环本身有界，所以停摆在它之后、`event_init` 之前的那几条指令（或该块访问触发的异常）。

### ✅ 根因已用 **2 行实验**证明：读 `0x2010B000` 直接挂死

在探针里、**任何 init 之前**加：

```zig
board.log.line("{s}", .{"bt probe: probing 0x2010B000 ..."});
const bleblk: *volatile u32 = @ptrFromInt(0x2010_B000);
const ble0 = bleblk.*;
```

板侧输出：

```text
bt probe: probing 0x2010B000 ...
（整个系统停住，无 panic、无后续、无中断）
```

⇒ **只要读一次 `0x2010B000`，系统就挂死**，与归档、与我们任何代码都无关。
这就是**整个连锁的总根因**：BLE/MAC 寄存器块（`MODEM_BASE + 0xB000`）**当前不可访问**，
访问即总线挂起（不返回错误、不触发异常）。

⇒ 归档里 `r_sym_bt_XPuq` 恰好也要读这个块，所以 init 卡在那里；UART 与中断随后也全部停摆。

**让这块可达的候选**（按 IDF 初始化顺序，逐个排除）：

| # | 候选 | 状态 |
| --- | --- | --- |
| 1 | BT/Wi-Fi 共享**电源域**（`esp_wifi_bt_power_domain_on`） | ❌ **排除**：该函数体被 `#if SOC_PM_MODEM_PD_BY_SW` 包住，而 S31 的 `soc_caps.h` **没有定义**它 ⇒ 这段在 S31 上根本不编译 ⇒ 电源域不由软件控制 |
| 2 | 该块自己的**时钟门** | 未排除。我们已置 `clk_conf1` 的 `bt_apb`/`btbb`/`btmac`（bit16/17/18），但 `MODEM_BASE+0xB000` 在 soc 头里**没有任何定义**（可查的块只到 SYSCON +0x9C00）⇒ 它是**未文档化的私有块**，门可能在别处 |
| 3 | `PAU`（`0x20341000`）的 modem 配置 | 未排除 |
| 4 | **`esp_phy_enable` 前置** | **最可能**：IDA 的流程里 PHY 先起、再碰 modem/BLE 寄存器；我们跳过了 `esp_phy_enable`（ch25 的 `shellPhyEnable` 只做了 Wi-Fi 侧的一部分），BT 侧可能没做 |

⇒ 有了 2 行复现器，验证任何候选都只需**一次烧录**（读通即修好）。

**实验（2026-11-17）**：按 IDF 顺序先开我们那套时钟门控，再调归档里的
`bt_bb_v2_init_cmplx(1)`（= IDF `esp_btbb_enable` 的核心，由 `libbtbb.a` 提供）：

```text
bt probe: clock gates first ...
bt probe: calling bt_bb_v2_init_cmplx(1) ...
（挂死）
```

⇒ **Espressif 自己的 BB 初始化函数也挂在同一处**。这不是我们调用方式的问题，
而是该块在**没有 PHY 前置**的情况下根本不可访问。

**完整复位脉冲也无效（2026-11-17 最后一次实验）**：对 `modem_rst_conf`(0x20109C10)
写全 1 再写全 0（IDF `MODEM_RESET_FIELD_WHEN_PU` 的等价物，此前只脉冲过 bit16），
然后重开时钟、调 `bt_bb_v2_init_cmplx(1)`：

```text
bt probe: rst pulse 0 -> all1 -> 0     ← 写全 1 后读回 0（bit8-31 不可回读）
bt probe: clocks re-enabled after reset pulse
bt probe: calling bt_bb_v2_init_cmplx(1) ...
（挂死）
```

⇒ 复位脉冲不解决。至此**所有能查的寄存器侧前置都已排除**。

### 跳过 step 6 的实验（2026-11-17）：能验证 7–9，但 10 会崩

加 `bringup.skip_task_init` 跳过 `r_btdm_task_init` 后，板上序列：

```text
step 6 r_btdm_task_init SKIPPED (experiment)
step 7 btdm_lp_init                 ✓ 通过
step 8 r_btdm_hci_fc_env_init       ✓ 通过
step 9 esp_register_ext_funcs       ✓ 通过
step 9 esp_ble_register_bb_funcs    ✓ 通过
step 10 r_ble_controller_init
   → !! mepc=0x4005f310 mtval=0x00000000
     panic: exception code=5 (load access fault)
```

⇒ **step 7–9 在板上首次得到验证**（此前它们从未执行过）。

⇒ 但 step 10 崩在**空指针**上。保留符号（探针构建 `strip=false`）后把 PC 映射出来：

| 地址 | 最近的符号 |
| --- | --- |
| `0x4005f310`（mepc） | `r_sym_bt_Hl337IkWeUHjq0EeK30W`（`libbtdm_common/2.o`） |
| `0x40005ba6`（ra） | `r_sym_ble_4W45cnSk8tMbpqkpDdkQ`（`libble_app`） |

那个函数只有 8 字节有效代码：

```asm
lui a5, .LANCHOR0
lw  a5, 0(a5)      # a5 = *(.LANCHOR0)  ← 这个全局指针是 NULL
lw  a5, 0(a5)      # ← 解引用 NULL ⇒ load access fault, mtval=0
```

⇒ **一个全局指针没被初始化**。而它很可能正是 **step 6（被我们跳过的那一步）负责初始化的**
⇒ 所以"跳过 step 6"这个实验**本身引入**了这个崩溃，不能据此判断 step 10 有问题。

⇒ 结论：**step 6 是唯一的总闸门** —— 它不通，后面既不能跑也不能可靠验证。

### 一个关键范围收缩：modem 域**部分可访问**

对比两组板侧读数：

| 地址 | 所属块 | 可读性 |
| --- | --- | --- |
| `0x2010_4CAC`（`MAC_ST`，ch25 全程在采） | `MODEM_BASE + 0x4000`(**WIFI_MAC**) | ✅ **每次采样都读得到**（恒 `0x0000E000`） |
| `0x2010_B000` | `MODEM_BASE + 0xB000`（**私有 BLE/MAC 块**） | ❌ **读一次即总线挂起** |

⇒ 整个 modem 域**不是**整体不可访问：WIFI_MAC 块正常，只有 `+0xB000` 这一块挂。

⇒ 所以缺的不是"modem 域的总开关"（`MODEM_CLK_EN` 读回 1 也印证），而是
**这一块自己的供电/隔离/门控**——而那部分**没有公开的寄存器定义**（soc 头里 `+0xB000` 无任何条目）。

⇒ 这也解释了为什么 ch25 的 17 条排除里没有任何一条命中：那些都在 WIFI_MAC/时钟/PHY 面上，
而问题在**另一块**上。

⇒ **对 R3.1 的含义**：Wi-Fi 卡在 `MAC_ST[15:13]` 忙位不清，而 `MAC_ST` 本身**读得到**
⇒ 那是"块可访问但内部状态没就绪"，与本节的"块根本不可访问"是**两种不同的失败**。
两条线不能合并成一个根因 —— 只有 BLE 这条卡在不可访问的块上。

**再排除两条（2026-11-17）**：

| 候选 | 板上读数 | 结论 |
| --- | --- | --- |
| `HP_SYS_CLKRST.MODEM_CTRL0`(0x20587040) 的 `MODEM_CLK_EN`(bit0) 未开 | **`0x00000001`** ⇒ 已开 | 排除 |
| `modem_rst_conf`(SYSCON+0x10) 有复位位未清 | **`0x00000000`** ⇒ 全部已清 | 排除 |

⇒ 结论：缺的前置是 **`esp_phy_enable(PHY_MODEM_BT)` 那一层**（PHY 的电源/时钟/标定），
而我们的移植从头到尾没做过 PHY 初始化 —— ch25 的 `shellPhyEnable` 只覆盖了 Wi-Fi 侧的一部分，
BT 侧缺失。这解释了为什么两个 controller 都停在"访问 MAC/BB 寄存器"。

### ⛔ 本节以下"总线挂死/硬件阻塞"的结论**已作废**（2026-11-17 晚，官方 IDF 对照）

> **对照实验**：把 IDF v6.1 的最小应用（`esp_bt_controller_init` +
> `esp_bt_controller_enable` + 秒级心跳）烧到**同一块板**：
>
> ```text
> idfbt: controller_init   -> ESP_OK (0x0)
> idfbt: controller_enable -> ESP_OK (0x0)
> idfbt: beat 3 … beat 11                     ← 心跳持续，不卡
> ```
>
> ⇒ **官方栈在这块板上完全正常 ⇒ 硬件没有问题，`0x2010B000 不可达` 的判断是错的。**
> ⇒ 所以下面"17 条排除 + 2 行复现器 + vendor 同挂 ⇒ 硬件/需 JTAG"那套推理**整段作废**；
>   那些排除项是在**错误前提**（把"我们的 init 卡住"归因给该地址）下做的。
>
> **真正的根因（板上实测，已修）**，见下面"真实根因"一节。

### 真实根因（2026-11-17 晚，PC 采样 + 全局直读）

两个独立缺陷，都不在硬件：

| # | 缺陷 | 证据 | 处置 |
| --- | --- | --- | --- |
| 1 | `Xpuq` 的锚点全局是 **NULL** | 直接读 `r_sym_bt_d3D3sk5KewclELfrD5xa` = `0x00000000`；`Xpuq` 用它作基址从地址 0 零填充到 `0x2010B100`（约 1.34 亿次写）= "无声卡死" | 它唯一的写者 `r_sym_bt_fqmZkUKgd5GE6m7i2YFG` 被 `if (*(*s0 + 8) != 0)` 守卫生生跳过 ⇒ 在 step 6 前补调，`P` 变为 `0x2f0139d0` |
| 2 | 归档打印卡在 **ROM 的 UART0 TX-FIFO 空位等待循环** | 新鲜采样 66 条：`mepc=0x2f83efda`×29、`0x2f83efd2`×8（该循环及其读字节叶子）；循环条件 `while (((*(u32*)(0x2038A01C))>>16)&0xFF > 127)`，即 `UART0_STATUS.TXFIFO_CNT` | 给 `ets_printf` 强定义直接丢弃（`bt_printf_shim.c`） |

> [!IMPORTANT] 关于缺陷 2 的**准确措辞**
> FIFO **不是**"永不排空"：连采 4 次（间隔 100 ms）得到
> `0xe0808000 → 0xe0008000 → 0xe0008000 → 0xe0808000`，
> 即 `TXFIFO_CNT` 在 **128 ↔ 0** 之间跳变 ⇒ 发送端在工作。
> 所以卡在这一循环的更可能解释是**打印量远大于 UART 吞吐**（爬行），
> 或者该循环等待的条件在本板上另有含义 —— **这两种还没判别**。
> 已排除的是"我们的时钟写把 UART 弄死"（`clock_writes_enabled=false` 卡点相同）。

**对照**：`clock_writes_enabled=false`（step 5 完全不写时钟）时卡点**完全一样**
⇒ 我们改的时钟门控**不是**原因。

### 已作废的旧结论（保留原文仅供追溯）：**总线挂死**（2026-11-17）

把 panic 输出也改成非阻塞（`hw.rawLine`，直接写 UART FIFO）后，卡住时**依然没有 panic**。

⇒ 不是 load fault，而是**访问本身不返回**。这一条同时解释了此前所有现象：

| 现象 | 由总线挂死解释 |
| --- | --- |
| 没有 panic / trap 输出 | 没有异常被投递 |
| T0 中断只来 2 次后彻底停止 | 中断控制器也挂在同一条总线上 |
| `UART0_STATUS.TXFIFO_CNT` 恒 128、输出停住 | 我们对 UART 的写也不返回 |
| 我们的非阻塞日志通道也打不出后续 | 同上 |

而卡点那次访问正是 `r_sym_bt_XPuq` 里对 **`0x2010B000..0x2010B100`**（`MODEM_BASE + 0xB000`，
BLE/MAC 寄存器块，位于 SYSCON +0x9C00 与 MODEM_PWR +0xD000 之间）的 16 次读-改-写循环。

⇒ **最可能的根因：这个块在访问时没有时钟**，外设不响应 ⇒ AHB 挂起（而不是返回错误）。
这解释了为什么 ch25（Wi-Fi）与本章（BLE）都停在"访问 MAC 侧寄存器"这一步。

### 断言行为（生产 vs 探针）

`bt_stubs.c` 的 `wr_btdm_assert`：**生产默认打印后挂住**；探针构建用 `-DBT_ASSERT_RETURNS=1`
改成打印后返回（挂住只能说明"到了某处"，返回才能看出后续还能走多远）。

### 已排除的假设（都是板上对照，别再重试）

| 假设 | 实验 | 结果 |
| --- | --- | --- |
| 少开时钟 | 12 个 BT 门 + 8 个 PHY FE + SOC PLL + LP timer，全部读回自证 | 仍卡 |
| 我们改时钟把 UART 弄停 | `clock_writes = false`，一笔都不写 | 仍卡 |
| ISR 打印打断 ROM 的 UART 写 | 完全不 arm T0、不开 MIE | 仍卡 |
| SOC PLL 源写坏 | 加开关默认不写 | 仍卡 |
| **BTDM 的 RAM 区间是零长度** | `s31.ld` 给 32 KiB BSS + 4 KiB DATA 真实区间 | **仍卡** |
| 时基没初始化 | `hw.initTimer()` + 打递增自证 | 修正了采样器，但不是卡点原因 |

⚠ **探针必须调 `hw.initTimer()`**：不调则 `nowUs()` 恒 0 ⇒ ① T0 的 alarm 永不到点 ⇒
采样中断一个都不来；② OSAL 的 `now_ms` 恒 0 ⇒ 任何"等到某时刻"的条件永不成立。
ADR-001:729 已因同一个原因记过一次。

## 待验证项

1. **`esp_btdm_controller_config_t` 逐字段镜像**（含结尾的 `magic`，`esp_bt.h:239`）+ `bluetooth_mode` 不能是 IDLE。
2. **任务宿主**：`r_btdm_task_init` 之后 controller 要一个任务在其上跑（栈量级 4 KB），落在我们的协作式调度器上还是自建。
3. **HCI 传输**：`hci_driver_ops_t` 只有 3 个函数指针（`hci_driver_tx` / `init(cb)` / `deinit`）⇒ 计划自己写，
   把 CMD 打进 `btdm_hci_trans_rx`，回程经 `r_ble_hci_trans_cfg_hs` + `btdm_hci_trans_register_tx` 注册的
   回调出来，每个字节进日志。`ble_controller_enable/disable`、`hci_transport_init`、
   `ble_controller_scan_duplicate_config`、`ble_msys_init` 都在**归档外**，同属"我们提供"那一桶。
4. **`wr_btdm_osal_*`（51 个）必须我们实现**：`nm` 显示它们由 `libbtdm_common` 定义，但类型是
   **`W`（弱定义）**，反汇编是 `wr_btdm_assert(file, line)` 的**断言占位**；IDF 的真实实现
   （`porting_btdm/controller/btdm_common/src/btdm_osal_freertos.c`）在真实构建里强定义覆盖它们。
   **准确口径**（按归档实际调用算）：**56 个弱桩** = 36 `wr_btdm_osal_*` + 11 `wr_btdm_coex_*`
   + 8 `wr_btdm_log_*` + 1 `wr_btdm_assert`（归档里弱定义的 `wr_btdm_*` 共 77 个，21 个从不被调）。
   ⇒ 这是"让 controller 跑起来"的主要工作量。**已完成**：8 个 `wr_btdm_log_*`（C 侧）、
   `wr_btdm_assert`、以及 `src/osal.zig` 里的 time/critical/sem/mutex/event/eventq/callout 核心（9 个主机用例）。
   **未完成**：36 个 OSAL 里剩下的 `task_*`/`intr_*`/`malloc`/`free`（要接调度器与 arena）、11 个 coex。

   **「强覆盖弱」已实测**：本文件给 `wr_btdm_assert` 写了强定义，链接无重复符号错误，
   镜像里出现标记串 `bt-blob-strong-assert` ⇒ 被选中是我们的实现。建议先写 8 个 `wr_btdm_log_*`，
   "controller 的第一行日志能打出来"就是第一个独立可观测判据。

   **时基**：`wr_btdm_osal_time_get()` 在 IDF 里是 `esp_timer_get_time() / 1000` ⇒ **毫秒**
   （`BTDM_OSAL_USE_ESP_TIMER` 恒为 1，ms↔ticks 恒等）。返回 µs 会让所有超时窗口大 1000 倍。
   `get_time_forever()` 的哨兵是 `portMAX_DELAY`。
   ⚠ OSAL 的 `time_get` 会被 ISR 调用 ⇒ 刻度源要用 CSR（`mtime`），**不能**用 `hw.nowUs()`
   （它读 APB 寄存器并自旋等 update 位，在 ISR 里会重入冲突）。
