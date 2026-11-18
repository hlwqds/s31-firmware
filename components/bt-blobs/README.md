# bt-blobs —— BLE controller 归档在裸机镜像里的适配面

把 IDF 的 BLE controller 归档（`libble_app` / `libbtdm_common` / `libbtbb` / `libphy`）
链进 ESP32-S31 的两段镜像，并补齐它要求宿主提供的符号。

- 来源章节：博客 `ch27-ble-802154-boundary` §27.11（边界：真实扫描/连接/特征值需要什么）
- 路线图：`practice/zig-esp32-s31/ROADMAP-real-link.md` 的 **R3.3**
- 先例：`components/wifi-blobs/`（Wi-Fi blob，同一套"只从 `.a` 拉需要的对象"手法）

## 验证状态

**当前级别（2026-11-17 收官）：init 链跑到 step 6 并停在内部**。硬件已证明无问题
（官方 IDF 同板 `controller_init`/`enable` 均 `ESP_OK`）。细节见顶部「交接摘要」。

| 级别 | 状态 | 证据 |
| --- | --- | --- |
| 归档能链进两段镜像 | ✅ | `.flash.text` 699 856 / 窗口 720 896；`elf2image` 成功，`image-info` 恰好 2 条 `DROM, IROM` |
| 闭包被真拉进来 | ✅ | 镜像里可见 `btdm_hci_trans.c`、`btdm_sleep.c`、`btdm_broker.c`；`.iram_blobs` 0 → 60 224 B |
| 56 个弱断言占位 | ✅ **56/56 强定义** | 逐条对归档调用集核过，差集为空 |
| init 链 1–5 步 | ✅ | `btdm_osal_elem_mempool_init`（**5 个池全 `rc=0`**）/ `btdm_log_init` / `btdm_external_init` / `btdm_coex_init` / `btdm_lp_enable_clock` |
| init **step 6** `r_btdm_task_init` | ❌ **停在这里** | 板侧 trace 只有 `mutex_pend => OK`，其后**无 hook、无 `task_create`、无任务体** |
| init step 7–15 | ⏸ 未执行 | 被 step 6 挡住 |
| `r_ble_controller_init`（step 10）/ `transport.init`（step 15） | ⏸ **已实现、未执行** | 代码在 `bringup.zig` / `transport.zig`，只是链还没走到 |
| HCI Reset / Read Local Version 有应答 | ⏸ 未执行 | 同上 |
| 板级扫描/连接 | ❌ | 离这里还有一个可用 controller |

> 别把"链接成立"读成"controller 可用"。当前准确表述是：
> **软件栈已完整到 step 6 之前，卡点是归档里多个模块各自的 `.LANCHOR0` 环境指针未被发布**
> （见「系统性发现」一节）。

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

> [!WARNING] 上面这条"全部成员"配方 **2026-11-18 实测不成立**，改用下面的门禁。
>
> 实测到的三件事（都已修）：
>
> 1. **成员名是数字**（`0.o`、`1.o`…），多归档 `cp` 到同一个 `flat/` 会互相覆盖 ——
>    四个归档 179 个成员摊平只剩 142。**不要手工摊平**，用 `tools/gen-bt-closure.sh`
>    的闭包清单（按需取成员，天然规避重复符号，例如我们 `phy_stubs.c` 的
>    `get_phy_version_str` 与 `libphy/phy_debug.o` 撞名）。
> 2. **`export fn` 需要有人强制分析**：`osal.zig` 的 5 个 `export fn` 只在文件被分析时发射，
>    而 `root.zig` 全是转出口。开关在 `components/osal/src/api.zig` 的 `forceExports()`，
>    由**本组件的 `root.zig` 在 comptime 调用**（`osal_kit` 是惰性模块，不调就不会被分析）。
>    少了这次调用，`bt_core.o` 的**符号数是 0**（`nm` 实测），链接报 `s31_now_us` 等 5 个未定义。
>    `-Dbt-probe` 会掩盖它（探针 shim 引用了 `probe.run`）—— **改 `root.zig` 时别删那行**。
> 3. **镜像不能"链接成功但为空"**：没有真实引用时归档成员可能一个都不进来。



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
| `src/osal.zig` | **已迁出** → `components/osal/`（另有 `sched.zig`、`probe_ptr.zig`）；本组件经 `osal_kit` 模块使用 |
| `src/host_tests.zig` | 主机测试入口（`zig build test` 会跑到） |
| `src/probe.zig` | 板上探针（`-Dbt-probe`）：装钩子 → arena → init → enable → 进任务 → 发 Reset → 泵任务 |
| `src/root.zig` | 模块根：所有文件属于同一个模块（分两个会报"文件属于多个模块"）；另含 `forceExports()` 的强引用 |
| `tools/gen-bt-closure.sh` | **重新生成闭包对象清单**（解包 4 归档 → 符号图 BFS → 减 ROM → 打印构建命令） |
| `src/sched.zig` | **已迁出** → `components/osal/src/sched.zig` |
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

### ✅ 本轮真实进展：静默 stall → 可诊断的 fault，并定位到 deinit 路径

**1. 发布锚点后的行为变化**

在 `bringup` 里给 `OkE7` 锚点填一个 arena 结构（`X`，`X+8` 指向第二个 arena 对象）后，
系统**不再静默**，而是打出 panic：

```text
bt bringup: 发布 OkE7 锚点 X=0x2f014858 X+8=0x2f014878
bt hook: mutex_pend
panic: exception code=5 (load access fault) cause=0x38000005
panic: ra=0x4005fa7e a0=0xb7a10c0d a1=0xa a2=0x770001
panic: sp=0x2f07ad70 s0=0x2f00f7e8
panic: ctx[0]=0x2f014858 ctx[1]=0x0
```

⇒ **静默 stall 变成可诊断的 fault**，这是本轮最实质的进步：
   要么有输出、要么能据此改，不再靠猜。

**2. fault 地址映射到位**

```text
ra=0x4005fa7e → r_btdm_task_deinit (0x4005fa4a, size 0x7a)
```

⇒ `mutex_pend` 返回后，`r_btdm_task_init` 走的是**错误清理路径** `r_btdm_task_deinit`。
   也就是说 step 6 是在**报错后清理**时挂的，而不是在正常初始化途中挂的。

**3. oracle 给出的真结构形状（供复刻，别再瞎填）**

```text
X[0]=0x00000001   ← 状态字节（archive 的 `sb 1,0(X)` 写这里；enable 后变 2）
X[1]=0x2f07c8ac   X[2]=0x2f07c670(=*(X+8))   X[3]=0x0
X[4]=0x2f07c914   X[5]=0x2f07c920
X[6]=0x20260127   ← **BTDM_CONFIG_VERSION 魔数**
X[7]=0x00171000
Y = *(X+8) 的内容是一串指针（0x2f07c988, 0x2f07c678 …）
```

⇒ 所以这个"锚点"其实是**控制器 env 结构**，里面有状态字节、若干指针和一个版本魔数。
   我们填的零填充假结构必然导致后续 fault —— 这一步证明"填对了才有意义"。

### ⛔ 以下"系统性发现"已被 oracle 否定（保留追溯）

> **oracle 逐步复刻实测（2026-11-17）**：在**能跑通**的 IDF 应用里按 bt.c 的顺序
> 逐调 `btdm_osal_elem_mempool_init` → `btdm_log_init` → `btdm_external_init`
> → `btdm_coex_init` → `btdm_lp_enable_clock`，**每一步之后三个锚点全为 0**，
> 而 `esp_bt_controller_init` 照样返回 `ESP_OK`：
>
> ```text
> stepbystep: boot         a21=0x00000000 a2=0x00000000 a7=0x00000000
> stepbystep: elem_mempool a21=0x00000000 a2=0x00000000 a7=0x00000000
> stepbystep: log_init     a21=0x00000000 a2=0x00000000 a7=0x00000000
> stepbystep: external     a21=0x00000000 a2=0x00000000 a7=0x00000000
> stepbystep: coex_init    a21=0x00000000 a2=0x00000000 a7=0x00000000
> stepbystep: lp_clock     a21=0x00000000 a2=0x00000000 a7=0x00000000
> I (2433) idfbt: controller_init -> ESP_OK (0x0)
> ```
>
> ⇒ **锚点在 step 6 之前为 0 是正常态**（`after_init` 才变非 0，说明发布者在 step 6 之内或之后）。
> ⇒ 所以 `OkE7` / `2aNN` / `BOhff` 的守卫**在 IDF 里同样取 0**，它们各自早退是**正常行为**。
> ⇒ 下面"s'系统性发现'把锚点为 0 当成缺陷"的推理**整条作废**。
>
> **遗留的真问题**：同样这几个函数、同样这些锚点为 0，IDF 里 `r_btdm_task_init`
> 能返回、我们这里不返回 —— 差异在 `mutex_pend` 之后的归档代码，而**不是**锚点。

### 🔑（已作废）归档多个对象各自守卫**自己的** `.LANCHOR0` 锚点

板侧 hook 追踪（恢复每 hook 一行后）给出 step 6 内的**完整** OSAL 调用：

```text
bt hook: mutex_pend
bt hook: mutex_pend => OK
（到此为止：没有 task_create，没有其它 hook，没有 step 7）
```

⇒ `mutex_pend` **返回了**，其后 stall 在**纯归档代码**里。

静态反汇编显示这不是孤立现象 —— 相邻的建任务辅助函数 `r_sym_bt_BOhff`
（`libbtdm_common/7.o`）用了**同一种模式**：

```asm
lui  s1, .LANCHOR0      ; ← 7.o **自己的**锚点
lw   a5, 0(s1)
beqz a5, .L80           ; 为 0 ⇒ 直接跳错误路径
```

⇒ **每个归档对象都有自己的 `.LANCHOR0`，各自守卫一份"模块状态"指针。**
在 IDF 里这些指针由某处初始化填上；在我们的移植里**它们全为 0**
（`OkE7`=0、`2aNN`/`BOhff` 各一份、`Xpuq` 一份……）。

⇒ 所以"多个对象同时早退"是**同一个缺失前置**的表现，而不是一堆独立 bug。
   `BOhff` 早退 ⇒ **任务根本没被创建** ⇒ 与板侧 `task_create` 日志 0 次完全一致。

**下一步（唯一有意义的）**：找出 IDF 里发布这些 per-object 锚点的是哪一步。
它必然由 IDF 源码侧（我们替换掉的那层，或 `bt.c` 的 prologue）调用；
定位方法：在 oracle 里按 §"时间线采样"每 1 ms 打一次其中两个锚点的值，
看它们各自在哪个调用之后从 0 变非 0。

### ⚠ 一个必须先排除的地雷：归档的硬编码任务栈就在我们 SRAM 的起点

链接脚本：`sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0` —— **我们整个 SRAM 区从
`0x2f000000` 开始**。

而 `r_btdm_task_init` 在建任务时给 `r_sym_bt_BOhff` 的栈是**硬编码**的：

```asm
92: li a5, 2000
9e: sw a5, 28(sp)      ; 0x2f000000
a0: call r_sym_bt_BOhff
```

⇒ `0x2f000000..0x2f0007D0` 正是我们向量表 / `.trap` / `_bss` 起始所在区间。

**已修（布局层）**：`.trap_ram` 的地址改为 `ORIGIN(sram) + 0x800`，
SRAM 侧所有段（`.trap`/`.iram_blobs`/`.data`/`.bss`/堆）随之抬高 2 KB，
低 2 KB 专供归档的任务栈。实测新边界：`_trap_start = 0x2f000800`、
`_bss_end = _heap_start = 0x2f0142c0`，无 ASSERT 失败。
**但板测仍冻结在 `s=256`**（且新增 `deinit+0x4a` 的 fault）⇒ 该冲突是**必要但不充分**的修复。
任务一旦真的建起来，它会**覆盖向量表**，而症状恰好是"**中断不再递送**"——
与板侧计数器停在 256 完全吻合。

⇒ 追 `0xa8` 之前必须先排除这一条（或把它变成不可能：让归档拿到我们自己的栈）。

**`BOhff` 的首字节检查读出来的疑点**（待下轮核）

```asm
12: beqz a5, .L80        ; 7.o 锚点为 0 → 错误路径
14: lbu  a2, 0(a0)       ; a0 = 调用方 sp+20
1a: addi a5, a2, -8
1e: andi a5, a5, 247     ; 247 = 0b1111_0111 ⇒ **bit3 被掩掉** ⇒ (0x10-8)&0xF7 == 0
                         ; ⇒ beqz **命中** ⇒ 归档传的 0x10 是**合法**的，走 .L77 成功分支
```

而归档自己在 `0x80-0x9e` 写进那个结构的是 `0x0b10`（首字节 `0x10`）⇒ 按此读法**必然走错误路径**。
两种可能：① 我对该比较的语义读错了；② `BOhff` 本就不是成功建任务的路径，建任务在别处。
下一轮用同样的 section 级反汇编把 `.L77`（成功分支）读出来即可定案。

### 🔧 JTAG 那一步已备好：`tools/jtag-watch-modem-block.sh`

软件侧能做的已穷尽，剩下的是**硬件动作**。为了让那一步"接上就能用"，准备了现成脚本。

**它做什么**：用 `interface/esp_usb_jtag.cfg` + `target/esp32s31.cfg` 启动 openocd，
对指定地址（默认 `0x2010B000`）下**写观察点**，命中后打印 PC —— 那就是**第一个访问该地址的指令**，
用 `nm -n` 反查符号即可。

**本机已就绪的部分（实测）**

| 项 | 状态 |
| --- | --- |
| openocd-esp32 | ✅ `~/.espressif/tools/openocd-esp32/v0.12.0-esp32-20260703/` |
| `target/esp32s31.cfg` | ✅ 存在（`_CPUTAPID 0x00020C25`，SMP 双核配置） |
| `interface/esp_usb_jtag.cfg` | ✅ 存在 |
| NixOS 的 libusb | ✅ 脚本自动从 `/nix/store/*-libusb-1.0.*/lib` 注入 `LD_LIBRARY_PATH` |
| 脚本语法 + 启动 | ✅ **实测到"找不到设备"这一步**（即除硬件外全通） |

```
$ tools/jtag-watch-modem-block.sh
Error: esp_usb_jtag: could not find or open device!
```

⇒ **这个报错就是唯一剩下的阻塞**：S31 的原生 USB（D+/D-）未接到主机
（本板 CP2102N 只出 UART）。接好后同一命令即可工作。

**接好后有两种用法**

1. 在**本仓固件**上跑 → 看我们**卡在哪条指令**
2. 在 **IDF 固件**上跑 → 看 IDF **如何让它变可访问**（这才是要找的使能动作）

### ✅ 最后一条软件角度也排除了：**bootloader 与 IDF 相同**

曾怀疑"我们的引导程序是否裁剪过、少做了 modem 初始化"。实测否定了这个可能：

| 项 | 我们 | IDF 应用 |
| --- | --- | --- |
| `bootloader.bin` 大小 | 22 224 B | 22 224 B |
| ELF 里 `MODEM_SYSCON`/`MODEM_LPCON` 基址符号 | 有 | 有 |
| ELF 里 `phy`/`modem` 相关符号总数 | **2** | **2**（相同） |

⇒ 两边用的是**同一个** IDF 标准二级 bootloader，bootloader 里**没有任何** modem/PHY 初始化代码。
⇒ **boot 层不是差异来源。**

至此，软件侧可以比较的面全部覆盖完毕：

| 面 | 结论 |
| --- | --- |
| BT init 的寄存器写（step 1–5） | 与 IDF 一致 |
| boot 完成态四窗口 | 差异已补齐 |
| per-object 锚点 | `OkE7` 自己发布；`sitBB3S` 两边都 0 |
| PHY 代码 | **IDF 自己的**，已链入并执行 |
| bootloader | 同一个，无 modem 代码 |
| 配置结构（192 字节） | 逐字节一致 |

⇒ **没有剩余的可比面了。** 差异只能是外部的（JTAG 观察点或 vendor 文档）。

### 🏁 最终诊断：**PHY 校准也会 stall 总线 —— 撞的是同一堵墙**

用 PC 采样器（`probe_irqs=true`，采样器在 `init()` 之前武装）测卡住期间的计数：

```text
第 139 行  s=128 pc=0x2f8036c8
第 141 行  s=192 pc=0x2f8036c8
第 145 行  s=256 pc=0x2f8036ce      ← 计数止于此
第 201 行  phy: (log)
第 202 行  phy: (log)
（之后：无采样、无 panic、100 秒无进展）
```

⇒ **中断在 PHY 代码真正执行之前就停止了**，之后一条采样都没有。

⇒ 结论：**IDF 自己的 PHY 校准代码，在我们的镜像里也会把总线 stall 住** ——
   和 BLE controller 停在 `0x2010B000` 时是**完全相同的签名**（无异常、中断停止、静默）。

**这个发现的意义**：把"缺 PHY"这个假设也排除了。不是"我们没实现 PHY"，
而是**这块硬件（modem 前端的某个私有区域）在我们的镜像里根本不应答任何访问者** ——
无论访问者是 BLE controller 还是 IDF 自己的 PHY 校准。

⇒ 因此这不是"再实现一个子系统"能解决的，而是**镜像层面缺一个我们无法从公开信息推导的前置**
（IDF 的 bootloader / `esp_system` 启动链里做的某件事，或该块自身的硬件使能序列）。

**两条可行路径（均需软件之外的手段）**：

1. **JTAG 写监视点** —— 对可疑地址下 watchpoint，在 IDF 成功路径上抓"谁让它变得可访问"
2. **vendor 文档 / 支持** —— 该区域在 soc 头文件里零定义（公开块止于 `SYSCON+0x9C00` /
   `PWR+0xD000` / `LPCON+0xF000`）

### 🚀 已完成：**IDF 的真实 PHY 实现跑进了我们的固件**

这是整条线走得最远的一次，且是**可用代码**而不是推断。

| 项 | 结果 |
| --- | --- |
| 链接的 IDF 对象 | `phy_init` · `phy_common` · `btbb_init` · `modem_clock` · `modem_clock_impl` · `modem_clock_hal` · `periph_ctrl` |
| 补的桩 | `link/phy_stubs.c`，**37 个**（NVS 故意返回 `NOT_FOUND` ⇒ 走 IDF 自带的 `PHY_RF_CAL_FULL` fallback） |
| 链接结果 | **0 个未定义符号** |
| 真实函数进镜像 | `esp_phy_enable` @ `0x40000744` · `esp_phy_load_cal_and_init` @ `0x40000580` · `modem_clock_module_enable` / `phy_module_enable` 在 IRAM |

**途中抓到两个我自己的真 bug**

1. **`HP_SYS_CLKRST` 被写成变量**（应为绝对符号）。`&HP_SYS_CLKRST` 于是解析到该变量在
   drom 的位置 `0x40104f48`，PHY 往 flash 写 ⇒ `store access fault`。
   改为 `PROVIDE(HP_SYS_CLKRST = 0x20587000)` 后修复。
2. **`esp_log` 桩解引用 tag**。IDF 的 `esp_log` 是宏，调用点第一个参数未必是字符串常量
   （实测 `a0=3`）⇒ `load access fault`。去掉解引用后修复。

**当前状态：PHY 代码执行后卡在 RF 校准**

```text
（step 1-5 不打印 —— PHY 初始化在 init() 入口，先于 step 1）
phy: (log)
phy: (log)
（100 秒无进展，无 panic）
```

⇒ **不是"校准慢"，是真的停住**（100 秒抓取验证）。

### 🎯（已完成）剩余工作精确量化：链 IDF 的 PHY 源码对象，补 **68 个符号**

关键简化：**IDF 的构建目录里已经有编好的 `.o`**，不需要重建头文件树。

```text
build/esp-idf/esp_phy/.../phy_init.c.obj
build/esp-idf/esp_phy/.../phy_common.c.obj
build/esp-idf/esp_phy/.../btbb_init.c.obj
build/esp-idf/esp_hw_support/.../modem_clock.c.obj
build/esp-idf/esp_hw_support/.../periph_ctrl.c.obj
```

**实测差集**（这 5 个对象的未定义符号 vs 我们镜像已定义）：

| 项 | 数 |
| --- | --- |
| 未定义符号总数 | **82** |
| 我们已提供 | 14 |
| **需补桩** | **68** |

68 个按类别分（都可桩或复用现有实现）：

| 类别 | 示例 | 处理 |
| --- | --- | --- |
| 内存 | `calloc` / `free` | 转我们的 arena |
| 日志 | `esp_log` / `esp_log_timestamp` | 转我们的 logger |
| 定时器 | `esp_timer_create/start/stop/delete/get_time` | 桩（PHY 只用于温度跟踪，可空实现） |
| 锁 | `_lock_acquire` / `_lock_release` | 我们的临界区 |
| GPIO | `gpio_config` / `esp_rom_gpio_*` | 桩 |
| efuse/MAC | `esp_efuse_mac_get_default` | 桩 |
| 睡眠 | `esp_sleep_*` / `esp_deep_sleep_register_phy_hook` | 桩 |
| modem_clock 内部 | `modem_clock_*`（约 10 个） | 与 `modem_clock.c.obj` 一起链，再补剩余 |

⇒ **这是整条线最后的、也是唯一还有明确工作量的部分：68 个桩 + 链接。**

**为什么不继续手工推寄存器**：四个窗口已全对齐、`g_phyFuns` 已填、`register_chipv7_phy` 已就位，
但缺的两个使能函数是 **IRAM 代码（IDF 源码）**，地址在我们板上是空的（实测 `illegal instruction`）。
把它们**编进来**比逆向推它们**更可靠、更省时**。

### ✅ 再进一步：PHY 初始化表与调用点都已就位，只差两个 IDF 源码函数

继续按 IDF 的 `esp_phy_enable` 链路推进，逐项实测：

| 项 | 状态 |
| --- | --- |
| `phy_get_romfunc_addr()` | ✅ 调用后 `g_phyFuns: 0x0 → 0x2f07f944` |
| PHY 初始化表 | ✅ **128 字节**（`esp_phy_init_data_t`），从 IDF 的 ELF `.rodata` 抠出（`nm` 确认 `size=0x80`） |
| `register_chipv7_phy` | ✅ 已在镜像（`0x40061c82`），签名 `(init_data, cal_data, mode)` |
| `esp_phy_calibration_data_t` | ✅ **1904 B**（version[4] + mac[6] + opaque[1894]） |
| 校准模式 | ✅ `PHY_RF_CAL_FULL = 2` |
| NVS | ✅ **不需要**：`esp_phy_load_cal_data_from_nvs` 失败时 IDF 自带 `PHY_RF_CAL_FULL` fallback |

**新发现的硬事实（实测报错定位）**

`esp_phy_common_clock_enable`（`0x2f002dbc`）与 `phy_module_enable`（`0x2f0015ba`）
在 IDF 的 ELF 里落在 **`0x2f00xxxx` = DRAM**，即 **IRAM 函数**，是 IDF 应用运行时载入的代码。
我们板上那片区域是空的 ⇒ 直接调用得到 **`illegal instruction`**（`mcause=2`，实测）。

它们的实现都归结为**一个**调用：

```c
wifi_bt_common_module_enable() → modem_clock_module_enable(PERIPH_PHY_MODULE)
phy_module_enable()            → modem_clock_module_enable(PERIPH_PHY_CALIBRATION_MODULE)
```

而 `modem_clock_module_enable` 同样是 **IDF 源码**（`0x2f0021ea`，DRAM），
其 PHY 依赖集是：

```
PHY_CLOCK_DEPS = MODEM_ADC_COMMON_FE + MODEM_PRIVATE_FE + SOC_PLL_SOURCE_CG + I2C_MASTER
```

⇒ **剩余工作**：把 `modem_clock_module_enable(PHY)` 的等效寄存器写补进来
（关键是 **`I2C_ANA_MST`** —— PHY 寄存器访问走模拟 I2C 主控，我们从未使能过它），
再调 `register_chipv7_phy(&init_data, &cal, 2)`。

**修正后的剩余估计：半天到一天。**

### ✅ 重大修正：**`libphy.a` 早已全部链在镜像里**，只是从未初始化

这一步把上面那份估计**大幅推翻**，全部是实测：

| 项 | 原估计 | 实测 |
| --- | --- | --- |
| 窗口够不够 | 需扩 ~140 KB | **早就够**：`libphy.a` 的**可装载内容只有 18 151 B**（text 15 116 + rodata 2 527 + data 508），文件 160 KB 里其余全是调试信息；irom 当前余 **81 344 B** |
| 链接面 | 332 个未定义符号要补 | `libphy.a` 的 **210 个**未定义符号里，**208 个我们已提供**；缺的 `phy_get_sar2_vol` 只是 ROM 表没抄（已从 IDF 的 `esp32s31.rom.phy.ld` 合并 **164 条**，现共 449 条） |
| 要不要额外链 libphy | 要 | **不用**：`libphy.a` 的 **21 个对象全部已在 bt-blobs 闭包内**（`nm` 逐字节比对确认） |
| PHY 表初始化 | 未知 | `phy_get_romfunc_addr` **已在镜像内**（`0x40061728`），只是从没调用 |

**板侧实测（关键）**

```text
BOOTSTATE: g_phyFuns(before)=0x0
BOOTSTATE: g_phyFuns(after)=0x2f07f944      ← 调用后**表被填上**
BOOTSTATE: calling esp_phy_enable(2) ...
BOOTSTATE: esp_phy_enable(2) returned        ← ROM 的 PHY 使能**正常返回**（原先从没走到过）
```

⇒ 所以"缺 PHY 层"这个说法要**修正**为：**PHY 代码一直在，缺的是初始化调用**
（`phy_get_romfunc_addr()` + `esp_phy_enable()`），而这两步现在都做了。

**但块仍不可访问** ⇒ 使能之外还需要**校准**：
`esp_phy_enable` 在 `s_is_phy_calibrated == false` 时会调 `esp_phy_load_cal_and_init()`，
后者经 `nvs_open(PHY_NAMESPACE)` 读**每片芯片的 RF 校准数据** —— 我们裸机**没有 NVS**。

⇒ **剩余工作收窄为一件事**：给 PHY 提供校准路径。

### 🧱（估计已过时）硬前置：**PHY 层缺失**（含 RF 校准数据）

三轮寄存器对拍全部对齐后块仍不可访问，最终定位到一个**被完全跳过的子系统**：PHY。

**证据链**

| 观测 | 事实 |
| --- | --- |
| IDF 应用符号表 | 有完整 PHY 层：`esp_phy_enable`、`esp_phy_load_cal_and_init`、`esp_phy_common_clock_enable`… |
| `esp_phy_enable` 实现 | `esp_phy_common_clock_enable()` → `phy_module_enable()` → `esp_phy_load_cal_and_init()` |
| 校准数据来源 | `esp_phy_load_cal_data_from_nvs()` → **`nvs_open(PHY_NAMESPACE)`** ⇒ 依赖 **NVS 分区** |
| 我们的镜像 | 无 PHY 初始化调用（`esp_phy_enable` 是 ROM 函数 `0x2f00e756`，已尝试调用，**仍不够**） |

⇒ `0x2010B000` 是 **BT 基带**，需要 modem 前端上电并完成 RF 校准后才应答总线；
    这套在 IDF 里由 `esp_phy` 全权负责，裸机移植**完全没有这一层**。

**规模数据（本机实测）**

| 项 | 数值 |
| --- | --- |
| `esp_phy` 组件 | **7 个 C 文件 / 2 158 行** |
| `libphy.a`（esp32s31） | **0.16 MB** |
| `libphy.a` 的未定义符号 | **332 个** |
| 当前 flash 余量 | `irom` 720 896 B 中已用约 700 KB ⇒ **余 ~20 KB** |
| 链接 `libphy.a` 需要 | **再扩 ~140 KB** ⇒ 必须先扩两段镜像窗口 |

**工作量估计（单人，含调试）**

| # | 任务 | 估计 |
| --- | --- | --- |
| 1 | 扩两段镜像窗口（已有 `s31-two-segment-window-expansion` 的方法与板级验证流程） | **0.5 – 1 天** |
| 2 | `libphy.a` 链接面：把 332 个未定义符号分类，补 `wr_*`/ROM/IDF 服务 | **2 – 3 天** |
| 3 | `esp_phy` 核心路径移植：`esp_phy_enable` / `common_clock_enable` / `phy_module_enable` / `load_cal_and_init` | **3 – 5 天** |
| 4 | 校准数据来源：最小 NVS，或强制每次开机全量重校准（省 NVS，但开机慢） | **0.5 – 2 天** |
| 5 | 板级验证 + 调试（本战役的经验：调试点永远是最大项） | **2 – 4 天** |
| | **合计** | **约 8 – 15 个工作日（2–3 周）** |

**最大风险**：第 3 项。`libphy.a` 是预编译 blob，它期望的**调用顺序与状态**没有文档；
本轮"寄存器全对齐但仍不通"已经演示了这类 blob 的不可推断性。
若 PHY 初始化也依赖类似 `0x2010B000` 的私有块，同一堵墙会再出现一次。

**建议的决策点**：先只做第 1 + 2 项（约 3–4 天）——
如果 `libphy.a` 能链进来且 `esp_phy_enable` 调用后 `0x2010B000` 变可读，则第 3 项工作量可控；
否则应停下来评估"是否需要 vendor 支持"，而不是盲目投入两周。

### 🏁 最终结论：可测量的寄存器差异**已全部对齐**，块仍不可访问

三轮对拍完成后，所有能测到的差异都补上了：

| 轮次 | 对齐内容 | 结果 |
| --- | --- | --- |
| 1 | IDF step 5 的 **6 个写**（`clk_conf`/`power_st`/`clk_conf1`/`lpcon+0x04/+0x18/+0x20`） | 板侧逐字一致 |
| 2 | **boot 态差集**（`lpcon+0x08=0x314`、`+0x0c=1`、`clkrst+0x08=1`、`+0x0c=2`） | 已补 |
| 3 | 带对照读的直读验证 | `control read` 成功，`0x2010B000` **挂住** |

⇒ **结论**：`0x2010B000` 的可访问性**不由这四个窗口里的任何寄存器决定**。
   三轮对拍已覆盖 `MODEM_SYSCON`/`MODEM_LPCON`/`MODEM_PWR`/`HP_SYS_CLKRST`
   的全部可写位，以及 IDF boot 与 step 5 的全部可观测差异。

**因此剩下的只有两条路**（均需软件之外的手段）：

1. **JTAG 写监视点** —— 对 `0x2010B000` 下 watchpoint，在 IDF 成功路径上抓"谁让它变得可访问"。
   S31 片上有 USB-Serial-JTAG，本机已有 openocd 与 `target/esp32s31.cfg`；
   缺的只是板上 USB D+/D- 的物理可达性。
2. **vendor 文档** —— `0x2010B000` = `MODEM_BASE + 0xB000`，是**私有块**，
   soc 头里没有任何定义（公开块止于 `SYSCON+0x9C00` / `PWR+0xD000` / `LPCON+0xF000`）。

### 📋 IDF boot 完成态（`app_main` 入口，任何 BT 调用之前）—— 实测

```
syscon +0x000 = 0x00000100    +0x004 = 0x00201002 (clk_conf，step5 才变 0x7e601002)
        +0x020 = 0x00002070    +0x02c = 0x00000044    +0x030 = 0x02508080
lpcon  +0x008 = 0x00000314    +0x00c = 0x00000001    +0x018 = 0x00000001
       +0x01c = 0x00000004    +0x028 = 0x00000027    +0x02c = 0x08888888
       +0x030 = 0x00002070
clkrst +0x000 = 0x1  +0x008 = 0x1  +0x00c = 0x2  +0x010 = 0x1
       +0x01c = 0x3  +0x020 = 0x3  +0x028 = 0x3  +0x034 = 0x1
```

**重要更正**：`lpcon+0x008/0x00c/0x01c` 这三个值是 **boot 阶段**就有的，
不是 step 5 写的 —— 我此前把"我们的 step 5 后差异"整批归因给了 step 5，
其中这三条实际属于 **IDF bootloader / 系统初始化**。

⇒ 因此"我们的 step 5 与 IDF 等价"这个结论**仍然成立**（step 5 只改那 6 个），
但"差异在 boot 层"现在有了**具体候选**：`clkrst` 的若干位（`+0x004`/`+0x020` 两边不同）。

**下一步（最后一次软件测量）**：把我们 boot 结束时的四窗口与上表逐字对拍，
差集就是 IDF boot 做了、我们没做的事 —— 对着 IDF 的 `esp_system` 启动源码补即可。

### 🎯 结论：**我们的 step 5 已与 IDF 完全等价，差异在 boot 层**

在 oracle 里对 step 5 **前后**各 dump 四窗口再相减，得到 IDF 这一步**全部**的写
（以 `before → after` 表示）：

| 寄存器 | IDF step 5 写入 | 我们 |
| --- | --- | --- |
| `syscon+0x004` `clk_conf` | `0x00201002 → 0x7e601002` | ✅ 一致 |
| `syscon+0x00c` `clk_conf_power_st` | `0 → 0x64646400` | ✅ 一致 |
| `syscon+0x014` `clk_conf1` | `0 → 0x00070080` | ✅ 一致 |
| `lpcon+0x004` | `0 → 0x00000041` | ✅ 一致 |
| `lpcon+0x018` | `0x1 → 0x0000000b` | ✅ 一致 |
| `lpcon+0x020` | `0 → 0x66660000` | ✅ 一致 |

⇒ **只有这 6 条。我们全部一致。**

**但直读实测（含对照读）证明块仍不可访问**：

```text
bt probe: control read 0x20109C04 = 0x7e601002      ← 读路径正常
bt probe: BT_BLOCK_PROBE reading 0x2010B000 ...     ← 挂住，无值
```

⇒ ⇒ **差异不在 BT init 的寄存器写里，而在 boot 层**：
IDF 的镜像由 **IDF bootloader + 系统初始化**引导，我们的裸机镜像没有那一层。
oracle 里"step 1–5 之后块就可读"之所以成立，是因为它跑在 IDF 的完整 boot 之上。

**下一步（唯一）**：把四窗口在 **boot 完成、任何 BT 调用之前** 两边各 dump 一次并相减。
那个差集就是 IDF boot 建立了、而我们没有的状态 —— 这是整条线的最后一段。

### 📊（历史）四窗口同点对拍：约 40 个寄存器已对齐，症状不变

在**同一时刻**（`btdm_lp_enable_clock` 返回后、step 6 之前）对拍四个 modem 窗口：

| 窗口 | 结果 |
| --- | --- |
| `MODEM_SYSCON`（16 字） | 对齐（`clk_conf=0x7e601002`、`power_st=0x64646400`、`clk_conf1=0x00070080`） |
| `MODEM_LPCON`（16 字） | 对齐（`+0x04=0x41`、`+0x08=0x314`、`+0x0c=0x01`、`+0x18=0x0b`、`+0x1c=0x04`、`+0x20=0x66660000`） |
| `MODEM_PWR`（16 字） | 对齐 |
| `HP_SYS_CLKRST`（128 字） | 主要项对齐 |

**但 step 6 仍在同一处 fault。** ⇒ 这是本轮最重要的**否定性结果**：
使能 `0x2010B000` 所需的条件**不在这四个窗口能写到的任何寄存器里**。

**本轮纠正的错误**：`MODEM_LPCON+0x20` 我曾按 **step 4** 的快照判为"IDF 不写"并撤销，
而 step 5 边界实测 IDF 确实写 `0x66660000` ⇒ 已恢复。（教训：对拍必须**同点**。）

### 🏁 全表定案：10 个 per-object 锚点里有 **7 个从未被发布**

最终镜像里 `nm | grep " B r_sym_bt_"` 恰好给出 **10 个**锚点（`0x2f00ffd0..0x2f00fff4`，每个 4 字节），
在 `mutex_pend` 钩子处（`OkE7` 已跑完）逐个读出：

| # | 地址 | 符号 | 板侧值 | 说明 |
| --- | --- | --- | --- | --- |
| 0 | `ffd0` | `pSy5Wex1v0iXw5RdWtwL` | **0** | **11.o** —— 当前 fault 处（`cKuT2` 读它） |
| 1 | `ffd4` | `WDq2rzn4KRWP5mort5eS` | **0** | 未发布 |
| 2 | `ffd8` | `YnZmsxu068uuC3PC4iu8` | **0** | 未发布 |
| 3 | `ffdc` | `kfu8vf8dQgqwEzvqhb3d` | **0** | 未发布 |
| 4 | `ffe0` | `d3D3sk5KewclELfrD5xa` | `0x2f0150b8` | 2.o 的 `P`，由 `fqmZk` 发布 ✓ |
| 5 | `ffe4` | `sitBB3SrXn0IePgsPrBY` | **0** | 未发布 |
| 6 | `ffe8` | `r4auAKWSAFwgQarMHZCc` | `0x2f015058` | **21.o**，由 `OkE7` 惰性发布 ✓ |
| 7 | `ffec` | `lRdavKxt45o0gicEyznn` | **0** | 未发布 |
| 8 | `fff0` | `6Q68KSwuQQP4VjQGqiWa` | `0x2f015038` | **7.o**，由我们手动发布 ✓ |
| 9 | `fff4` | `y5Dip5N8bwiiGRcrWzBO` | **0** | 未发布 |

**与 oracle（`esp_bt_controller_init` 完成后）的差集 —— 最终结论**

| # | IDF | 我们 | 判定 |
| --- | --- | --- | --- |
| 0 `pSy5Wex…` | `0x2f07cd28` | 0 | **缺** |
| 1 `WDq2rzn…` | `0x2f07d394` | 0 | **缺** |
| 2 `YnZmsxu…` | `0x2f07cce4` | 0 | **缺** |
| 3 `kfu8vf8…` | `0x2f07be10` | 0 | **缺** |
| 4 `d3D3sk5…`(P) | `0x2f07ccac` | `0x2f0150b8` | ✓ |
| 5 `sitBB3S…` | **`0x0`** | **0** | ✓ **IDF 也不发布 ⇒ 不是问题** |
| 6 `r4auAKW…` | `0x2f07c8e0` | `0x2f015058` | ✓ |
| 7 `lRdavKx…` | `0x2f07d408` | 0 | **缺** |
| 8 `6Q68KSw…` | `0x2f07ccbc` | `0x2f015038` | ✓ |
| 9 `y5Dip5N8…` | `0x2f07d370` | 0 | **缺** |

⇒ **恰好 6 个缺失**：`pSy5Wex / WDq2rzn / YnZmsxu / kfu8vf8 / lRdavKx / y5Dip5N8`。
⇒ 这 6 个必须在 step 6 **之前或之内**被发布，否则各模块消费时就是一次向 0 的访问。
⇒ `sitBB3S` 两边都是 0 ⇒ 它本就永不发布，**不要**去发布它。

⚠ **两条必须同时记住的限制**

1. **oracle 快照是 init 全部完成之后取的** ⇒ 那 6 个"缺"里，有些**可能本就属于 step 7–15**
   （我们从没走到）。所以这张表的准确含义是："IDF 在 init **结束时**是发布过的"，
   **不等于**"我们的 step 6 就需要全部 6 个"。
2. **`cKuT2` 在锚点为 0 时会早退**（`beqz a5, .L201`）⇒ 锚点 #0 为 0 时它**不可能**是 fault 处。
   panic 的 `mepc` 落在它的入口且 `mcause=7`，最可能仍是 **`mepc` 与压缩指令边界的偏差**
   或 fault 其实发生在别的被调函数里（`ra` 已被证明不可靠，`mepc` 的归属同样需留疑）。

⇒ 因此**不能**用"锚点 #0 是 fault 处"来论证这张表，也**不能**据此断定 6 个都要补。
   它是一份**待验证的候选清单**，而非结论。

⇒ **下一步（一次到位）**：在 oracle 里 `nm` 出同一批符号，`esp_bt_controller_init` 完成后
逐个读值 ⇒ 非 0 的即 IDF 发布过的；与我们这张表做差集，就是**必须由我们发布的完整清单**。
拿到后按 `OkE7` 的模式（`malloc` + 写入锚点 + `memset` + 填 cfg）逐个发布，
或找出 IDF 里对应的发布函数并在 bringup 里补调（更忠实）。

### 🔎 `deinit` 的 fault 是**断言**，不是野指针

`r_btdm_task_deinit`（`0x7a`）的调用表与 `+0x4a` 处 callee 的真实身份：

```asm
22: wr_btdm_osal_mutex_pend(env+4, forever)      ← deinit 自己也 pend 一次
2e: lbu a3, 0(env)          # 状态字节
32: bltu 1, a3, .L80        # state > 1 ⇒ 另一支
36: lw  a0, 20(env)  ; call r_sym_bt_gvLJK4crXTPEAF7nrRbG
40: lw  a5, 0(anchor)
42: lw  a0, 16(env)  ; call r_sym_bt_gvLJK4crXTPEAF7nrRbG      ← fault 落在这里
4c/54: 后续两个调用
```

而 `r_sym_bt_gvLJK4crXTPEAF7nrRbG`（`libbtdm_common/2.o`）是**断言函数**：

```asm
0: lw   a5, 4(a0)        # a5 = *(obj+4)
a: beqz a5, .L4          # 为 0 ⇒ 跳过
18: li  a1, 42
20: call wr_btdm_assert  # ← 断言（行号 42）：对象**仍在使用**
```

⇒ 所以 `deinit` 的 "store fault" 实际上是：**归档检测到对仍在使用的对象做清理，触发断言**，
而我们的 `wr_btdm_assert`（`BT_ASSERT_RETURNS=1`）返回后，流程继续在已释放/半初始化的对象上走。

⇒ **这是 `task_init` 失败的后果，不是原因**。因此排查方向必须回到
`task_init` 为何判定失败 —— 而它的四个判据（版本、magic、`OkE7` 返回值、`0xce` 调用的返回值）
里，前三项均已实测通过（env 已与 oracle 逐字节一致）。

### ✅ 已补：`MODEM_LPCON +0x18` 的 bit0/bit1（`wifipwr` / `coex`）

板侧逐字对拍实证：

| 侧 | `MODEM_LPCON + 0x18`（step 5 之后） |
| --- | --- |
| IDF oracle | **`0x0000000b`**（bit0 + bit1 + bit3） |
| 我们（修复前） | 只写 bit3 |

⇒ 我们**从未写过 bit1 `clk_coex_en`**，而 IDF 的 `BLE_CLOCK_DEPS` 里有 `COEXIST` →
`modem_lpcon_ll_enable_coex_clock()` → `clk_conf.clk_coex_en`。已补上 bit0+bit1。

**但板测仍停在 step 6 并进 `deinit`** ⇒ 这一位是**必要但不充分**。

### 📋 `btdm_lp_enable_clock` 的完整对照清单（下一轮的施工图）

IDF（esp32s31）这一函数做四件事，我们逐条对照：

| # | IDF 动作 | 我们 |
| --- | --- | --- |
| 1 | `modem_clock_module_enable(PERIPH_BT_MODULE)`（一次，由 `s_btdm_lp_modem_clk_en` 守卫）→ 先 `icg_map_init_all()`，再 `device_control(BLE_CLOCK_DEPS)`：`BLE_MAC, BT_I154_COMMON_BB, ETM, COEXIST, WIFI_BB_80X1, SOC_PLL_SOURCE_CG, BT_APB, BT_PERIPHERAL` | 逐位手写；**已核对的**：`clk_btbb_en`(clk_conf1 bit17) ✓、`MODEM_CONF=0x3d` ✓、`clk_coex_en`(LPCON bit1) ✓（本轮补） |
| 2 | `modem_clock_module_enable(PERIPH_BT_APB_MODULE)` → `icg_map_init_all()` + `BT_APB_CLOCK_DEPS`：`BT_APB, ETM, SOC_PLL_SOURCE_CG, BLE_MAC` | 部分 |
| 3 | `modem_clock_module_mac_reset(PERIPH_BT_MODULE)` → `reset_btmac / reset_btmac_apb / reset_ble_timer / reset_modem_sec` | ✓ 四族都已做 |
| 4 | `btdm_lp_timer_clk_init(cfg)` | ✓ |

**最强嫌疑（未做）**：`icg_map_init_all()` 覆盖**两个域** ——
`MODEM_SYSCON.clk_conf_power_st`（我们写了 `0x64646400`）**和 `MODEM_LPCON` 自己的
`clk_conf_power_st`**（`clk_coex_st_map / clk_i2c_mst_st_map / clk_lp_apb_st_map`），
**后者我们一个字都没写**。

### 🎯 二分完成：使能者是 **step 5 `btdm_lp_enable_clock`**

| 探读 `0x2010B000` 的时机 | 结果 |
| --- | --- |
| 任何 BT 调用之前 | 挂死 |
| step 1（建池）之后 | 挂死 |
| **step 4（`coex_init`）之后** | **挂死** |
| **step 5（`lp_enable_clock`）之后** | ✅ `0x5ac968f1` |

⇒ **使能者是 step 5** —— 也就是我们自己重写的那一步。

**BB 时钟的具体位（IDF 权威路径）**

```c
// modem_clock_impl.c:176
modem_clock_ble_i154_bb_configure() → mod獸_syscon_ll_enable_bt_bb_clock(dev, enable)
// modem_syscon_ll.h:623
modem_syscon_ll_enable_bt_bb_clock() { hw->clk_conf1.clk_btbb_en = en; }
```

⇒ `clk_conf1` 的 **bit17 = `clk_btbb_en`**。

**而我们的实现已经设了它**：板侧读回 `clk_conf1 = 0x003ff880`（bit16/17/18 全置）。

⇒ 所以缺的**不是** `clk_btbb_en` 这一位，而是 step 5 里 IDF 会做的**其他动作**
（`modem_clock_module_enable` 的 `icg_map_init_all()` 位图应用、或 `BT_PERIPHERAL`/`SOC_PLL_SOURCE_CG`
这类依赖项的精确配置）。

⇒ **最终修复的正确做法**：把 `btdmLpEnableClock` 改写为与 IDF 的
`modem_clock_module_enable(PERIPH_BT_MODULE)` → `modem_clock_module_enable(PERIPH_BT_APB_MODULE)`
→ `modem_clock_module_mac_reset(PERIPH_BT_MODULE)` **逐行等价**（即完整复刻
`esp32s31/modem_clock_impl.c` 的 per-device configure 列表），而不是按推断的位手写。

### 🎯 二分结果：step 1 已排除，**step 4 (`btdm_coex_init`) 在我们的移植里是空的**

**oracle 二分（每次挂死也是有效数据）**

| 探读点 | 结果 |
| --- | --- |
| 启动时（任何 BT 调用之前） | **挂死** |
| step 1 `elem_mempool_init` 之后 | **挂死**（日志出现 3 次 = 3 次重启）⇒ **step 1 不是使能者** |
| step 5 `lp_enable_clock` 之后 | ✅ `0x2010B000 = 0x5ac968f1` |

⇒ 使能者只剩 **step 4** 或 **step 5**。

**关键发现：我们的 step 4 是空壳**

```zig
pub fn btdmCoexInit() c_int {
    return 0;
}
```

而 IDF 的 `btdm_coex.c:204`：

```c
btdm_coex_init(void) {
#if CONFIG_SW_COEXIST_ENABLE
    return coex_init();          // ← 参考构建里该宏为 y（已核对 sdkconfig）
#else
    return ESP_OK;
#endif
}
```

⇒ **参考构建 `CONFIG_SW_COEXIST_ENABLE=y`，所以 IDF 的 step 4 真的跑 `coex_init()`**；
而 `coex_init` 由 IDF 的 `esp_coex` 组件提供（**不在归档里**），我们的移植**完全没有这一层**。

⇒ 这使 step 4 成为最强嫌疑：它是 step 1–5 里唯一"我们写成了空函数、而 IDF 会真正执行"的一步。

**下一步（二选一，都很快）**

1. oracle 里把探读点放到 **step 4 之后**：可读 ⇒ 使能者就是 `coex_init`，需要实现它（或至少复刻它对 modem 域的写）
2. 若 step 4 之后仍挂 ⇒ 使能者是 step 5，那就把我们的 `btdmLpEnableClock` 与 IDF 的
   `modem_clock_module_enable/mac_reset`（`esp_hw_support/modem/modem_clock.c`）**逐行**对齐，
   而不是继续按推断的位写

### 🎯 找到 stall 的确切指令：`Xpuq` 无条件读写 `0x2010B000`

`r_sym_bt_XPuq`（`libbtdm_common/19.o`）的循环体（section 级，逐条）：

```asm
10: lui  a5, 0x2010b        # a5 = 0x2010B000
14-1c: sw zero,0(a1); sw zero,4(a1); sh zero,20(a1)   ; 通过 a1 = P 写（无害）
24: addi a3, a5, 256        # a3 = 0x2010B100（上界）
28: lw   a4, 0(a5)          # ★ **读 0x2010B000**
2a: addi a5, a5, 16
2c: and  a4, a4, 0xfff00000
2e: sw   a4, -16(a5)        # 写回
32: bne  a5, a3, 0x28       # 直到 0x2010B100，共 16 次，**无条件**
```

⇒ **该循环与 `P` 无关**，它总是访问 `0x2010B000..0x2010B100`。
而 `Xpuq` 在 `r_btdm_task_init` 的 `0xb8` 处被调用（`BOhff`→`HGbP`→**`Xpuq`**）。

**oracle 实测：该块的可读性由 step 1–5 建立**

```text
[启动时直读]                          → 挂死（此前已多次验证）
[step 1-5 之后] 0x2010B000 = 0x5ac968f1 → **READABLE**
[init 之后]     0x2010B000 = 0x5ac968f1 → READABLE
```

⇒ 所以使能者就在 **step 1–5** 里；step 2（`btdm_log_init`）与 step 3（`btdm_external_init`）
在 IDF 源码里都是 `return 0`，因此候选只剩：

1. step 1 `btdm_osal_elem_mempool_init`
2. step 4 `btdm_coex_init`
3. **step 5 `btdm_lp_enable_clock`** ← 最可疑：IDF 版做 `modem_clock_module_enable(PERIPH_BT_MODULE)`
   \+ `modem_clock_module_enable(PERIPH_BT_APB_MODULE)` + `modem_clock_module_mac_reset(BT)`，
   而我们重写的版本只覆盖了自己推断出来的那些位

⇒ `HGbP`（`0xae`，`Xpuq` 前一个调用）已读全：只是 `*(u32*)a0 = 40; *(u32*)(a0+4) = 46; ret`，无害。

### 🎯 三个数，把锚点/守卫链**一次性证清**（板侧实测）

在 `wr_btdm_osal_mutex_pend` 的成功路径里（即 `r_btdm_task_init` 偏移 `0x66`：
`OkE7` 已跑完、`2aNN` 还没跑）打印三个值：

```text
bt gate: env=0x2f015058   *(env+8)=0x2f012620   P=0x2f0150b8
```

| 值 | 含义 |
| --- | --- |
| `env = 0x2f015058` | `OkE7` 的 `malloc(76)` 成功并已发布到 21.o 锚点 |
| `*(env+8) = 0x2f012620` | `eventq_init` 写入的槽位指针 ⇒ `fqmZk` 的守卫**通过** |
| `P = 0x2f0150b8` | **`fqmZk` 确实执行了**并把 2.o 锚点设成有效指针 |

⇒ **整条锚点/守卫链是通的**。因此：
- `2aNN`（`0x78`，用 `P` 做 store）**是安全的**；
- 此前"锚点为 0 ⇒ `sb 1,0(NULL)` ⇒ stall"的推断**作废**（那是**修好 cfg 之前**的行为）。

⇒ **stall 在 `0x78` 之后**，候选只剩 `BOhff`(0xa0) / `HGbP`(0xae) / `Xpuq`(0xb8) /
`AJP6`(0xc2) / `waDX`(0xce) / `cgaC`(0xe2) / `FhFt`(0xea) 这七个**归档内部函数**
——它们**不走任何 hook**，所以 hook trace 永远看不到，只能靠 PC 采样器或 oracle 直接调用法。

**关于 `Xpuq` 的更正**：它自身代码里 `lui a5,0x2010b` 只用来算**循环上界**
`a3 = 0x2010B100`，所有 store 都经 `a1 = P`。而 `P = 0x2f0150b8` **大于**该上界
⇒ 若循环条件是 `<`，它就是空操作；若是 `!=`，它会一路跑到回绕（那会抹掉一切，
包括向量表与 UART）。**这两个方向的判别必须从 `Xpuq` 的循环头读出**，不能靠推理。

### 🗺 两个关键函数的**完整调用图**（section 级反汇编，逐条核对）

**`r_sym_bt_OkE7`（`0x146`）——env 的建造者**

```asm
2e: wr_btdm_osal_malloc(76)        ; env = malloc(76)
36: sw a0, 0(anchor)               ; ★ 发布：anchor = env
42: memset(env, 0, 76)
52-56: memcpy(env+24, cfg, 20)     ; cfg 副本 ⇒ 与 oracle 的 X[6]=0x20260127(偏移24) 吻合
66: sw env+52 → 16(env)            ; env[4]
6a: sw env+64 → 20(env)            ; env[5]
72: wr_btdm_osal_mutex_init(env+4)
7c: bnez a0 → 错误 -4
84: wr_btdm_osal_eventq_init(env+8)   ; ← **填出非空指针，这是 fqmZk 的前置**
8e: lw a5, 8(*anchor); beqz → 跳过
92: r_sym_bt_fqmZk                 ; ★ 设 P = malloc(...)（2.o 锚点）
9e/aa/c2/cc: 后续四个调用（event_init 等）
```

⇒ **注意**：`fqmZk`（写 2.o 锚点 `P`）的守卫是 `*(env+8) != 0`，
而 `env+8` 正是 `eventq_init` 写入的槽位指针 ⇒ 只要我们的 `eventqInit` 成功，
`P` 就会被设上 ⇒ `task_init` 的 `0x78 (2aNN)` 是**安全**的。

**`r_btdm_task_init`（`0x11c`）——完整调用序列**

```asm
1c: r_btdm_task_deinit      ; 三条错误路径的汇合点
40: r_sym_bt_OkE7           ; env 建造（见上）
58: wr_btdm_osal_get_time_forever
66: wr_btdm_osal_mutex_pend ; 板侧 trace 最后一条 => OK
78: r_sym_bt_2aNN           ; 通过 2.o 锚点 P 写（P 此时应已有效）
a0: r_sym_bt_BOhff          ; 把调用方结构里的字段**拷进 7.o env**（偏移 0..15）
ae: r_sym_bt_HGbP
b8: r_sym_bt_XPuq           ; 那个 0x2010B000
c2: r_sym_bt_AJP6
ce: r_sym_bt_waDX
e2: r_sym_bt_cgaC
ea: r_sym_bt_FhFt
```

**`r_sym_bt_BOhff`（`0x7a`）不是建任务**：它按首字节（`(x-8)&0xF7==0`，`247=0b1111_0111`
把 bit3 掩掉 ⇒ 归档自己的 `0x10` **合法**）进入 `.L77`，再从调用方结构拷 12 个字节到
`*(7.o env)` 的偏移 0..15 ⇒ **16 字节的 env 刚好够**。

⇒ 因此 `task_create` **不在 step 6 里**；它属于后面的步骤。step 6 的剩余候选是
`ae/b8/c2/ce/e2/ea` 这六个调用。

### 📍 当前前沿（2026-11-17 最终）

`r_btdm_task_init` 的完整控制流（`.text.r_btdm_task_init`，`0x11c`，逐条读全）：

```asm
0x00-0x18  cfg==NULL? / cfg->version==0x20260127?  否则 → .L93(deinit)
0x32-0x3c  cfg->magic==0x5a5aa5a5?                 否则 → .L93(deinit)
0x40       call r_sym_bt_OkE7
0x4a       bnez a0, .L93                            OkE7 非 0 → deinit
0x4c-0x54  s1 = &(21.o 锚点); s2 = 锚点值
0x58-0x62  a1 = get_time_forever(); s2 = 锚点值+4
0x66       call <pend(&mutex@锚点+4, a1)>           ← 板侧 trace: => OK
0x6e-0x74  a5 = 锚点值; sb 1, 0(a5)                 ← 写状态字节（现在是合法内存）
0x78       call <无 OSAL hook>                      ★ 候选 1
0x80-0xa0  sp+20 = {0x0b10, 33, 2000, 0x2f000000}
0xa0       call r_sym_bt_BOhff                      ← 建任务；守卫 7.o 锚点
0xa8       call <sp+12，8 字节零结构，无 OSAL>      ★ 候选 2
```

**已核对的签名事实**：IDF 的 `wr_btdm_osal_eventq_init` / `event_init` **本身就是 `void`**
（`btdm_osal.h:82,91`），所以我们声明成 `void` 是正确的 —— "返回值残留触发 `bnez`"
这条假设**不成立**，已排除。

**唯一未解**：`0x78` 与 `0xa8` 两处调用**不碰任何 hook**，所以永远不出现在 hook trace 里。
它们只能用**短行 PC 采样器**定位（该仪器本轮已修好并验证可用）。

**`BOhff` 的栈是硬编码 `0x2f000000`（2000 字节）** —— 正是我们 bootloader 的 CLIC 向量表
（`_mtvt_table` ≈ `0x2f000070`）与堆起始（`0x2f000a20`）所在区间。一旦任务真的建起来，
它会**覆盖向量表**，症状恰好就是"中断不再递送"。这条在追 `0xa8` 之前必须先排除。

### 🔄 再更正：锚点由 `OkE7` 自己发布，而配置修好后它**成功了**

读 `.text.r_sym_bt_OkE7...` 的完整函数体（`nm -S` 边界，`0x146` 字节）得到真实流程：

```asm
2a: li   a0, 76
2e: call wr_btdm_osal_malloc     ; ← 板侧 trace 里的 malloc(76)
36: sw   a0, 0(s0)               ; ★ **anchor = env**（s0 = &anchor）
42: call memset(env, 0, 76)
52: addi a0, s2, 24
56: call memcpy(env+24, cfg, 20) ; ← cfg 副本落在 +24 ⇒ 与 oracle 的 X[6]=0x20260127(偏移24) 吻合
66: sw   env+52, 16(env)         ; env[4]
6a: sw   env+64, 20(env)         ; env[5]
72: call <env+4>                 ; mutex_init @env+4
7c: bnez a0, .L40                ; 非 0 ⇒ 错误 -4
```

⇒ **所以锚点 = 76 字节的 cfg 环境，由 `OkE7` 自己 malloc 并发布**，
   而且它是 `task_init` 在 `0x40` 处调用的**第一个函数**。

**这意味着**：把 `cfg.btdm.version/magic` 修对之后（本轮已修），`OkE7` 会成功、
锚点会被填上 ⇒ `0x74` 的 `sb 1, 0(env)` 写的是**合法内存**。

⇒ 因此"`sb 1, 0(NULL)` 造成 stall"这一判断**对当前构建不再成立**；
   stall 位置已**后移**到 `BOhff` 之后（`0xa8` 附近的调用），那里**不调任何 OSAL hook**。

⇒ 这也解释了为什么 `ctx[0]` 在伪造实验后总是我们的指针：锚点本来就该由归档自己填。

### ✅（已作废）曾判定：卡住期间**中断停止** ⇒ 是总线 stall

用**极短计数器行**（前 16 条打详细现场，之后每 64 条打一行 `s=<n> pc=0x<x>`，约 18 字节）
重新测量，这次工具本身不再干扰观测：

```text
s=64  pc=0x2f8036ce
s=128 pc=0x2f8036ce
s=192 pc=0x2f8036cc
s=256 pc=0x2f8036ce      ← 最后一条，在第 145 行
bt bringup: enter step 6  ← 第 229 行
（之后没有任何 s= 行，而 bt hook / osal 行仍在正常输出）
```

⇒ 计数**停在 256**，而 step 6 之后**其它日志照常打印**（写入通道正常）
⇒ **中断确实在 step 6 处停止** ⇒ 事务不退休（stall），而非自旋。

**这与反汇编完全吻合**：`mutex_pend => OK` 之后归档执行 `sb a4, 0(a5)`，其中
`a5 = 21.o 锚点值`。锚点为 **0** ⇒ **向地址 0 写一个字节** ⇒ 总线事务永不完成
⇒ 不产生异常、中断不再递送、后续 hook 与建任务全部不发生 —— 就是整场看到的"无声冻结"。

**严格边界复核（`nm -S`：函数体 0x0–0x11c，不再用无界 sed 窗口）**

```asm
4c: lui  s1, .LANCHOR0        ; s1 = &(21.o 的锚点)
54: lw   s2, 0(s1)            ; s2 = 锚点值
58: call wr_btdm_osal_get_time_forever
62: addi s2, s2, 4            ; 锚点值 + 4（作为 eventq 的 slot 传下去）
66: call <pend>
6e: lw   a5, 0(s1)            ; a5 = 锚点值（重新读）
70: li   a4, 1
74: sb   a4, 0(a5)            ; ← *(u8*)锚点值 = 1
```

⇒ 这条 store **确实在 `r_btdm_task_init` 内**，且 `a5` 用的是 **21.o 的锚点**（不是 `2.o` 的 `P`）。
锚点为 0 时它就是**向地址 0 写一个字节**。此结论已按边界复核，不再依赖无界窗口。

**因此唯一剩下的任务**：让那个锚点在 step 6 之前指向**归档自己能用的 env**。
已排除的替代做法：伪造 32 字节结构（能越过 store，但归档随后判定失败并进 `deinit`，
fault 落在它自己没填过的字段上 —— 这条路上限已到）。

### 🔬（历史）采样落在 `hw.rawWrite` 里的含义

board 侧 66 条 PC 采样的分布：

```
39  mepc=0x40068aa4   → hw.rawWrite
11  mepc=0x40068aae   → hw.rawWrite
 7  mepc=0x40068aa0   → hw.rawWrite
 2  mepc=0x40069304   → probe.logHook
 1  mepc=0x4006d414   → (probe 内)
```

⇒ **全部落在我们自己的日志路径上**。两种解释，**尚未区分**：

1. 日志量大 + UART FIFO 常满 ⇒ 采样器每次都恰好打断在写日志处（**观察偏差**），
   stall 另有其地。
2. 日志本身把流程拖到近乎静止（每字符最多自旋 5000 次）。

**采样器的打印策略会伪造"无样本"**：trap 只逐条打印前 64 个样本，之后每 256 个才打一行
⇒ "`enter step 6` 之后没有采样行"**不是** stall 的证据，是打印策略的产物。这条曾导致
两轮错误结论。

**自旋预算的两端都试过**：20000 太慢、400 会把日志**打乱**（实测出现 `btbtbtb…` 这类乱码），
5000 是当前折中值。要看"中断是否还在来"，正确做法是把 ISR 打印改成**极短计数器**
（≤20 字节，每 N 个样本一行），FIFO 压力小几个数量级，不需要跨启动的 RAM 持久化。

### 📋 可直接复用的参考资料（别再重新推导）

| 项 | 值 |
| --- | --- |
| 三个锚点（全局 `B`，可 `@extern` 读写） | `r_sym_bt_d3D3sk5KewclELfrD5xa`(2.o, P) @ `0x2f00f7e0`；`r_sym_bt_r4auAKWSAFwgQarMHZCc`(21.o, OkE7) @ `0x2f00f7e8`；`r_sym_bt_6Q68KSwuQQP4VjQGqiWa`(7.o, BOhff) @ `0x2f00f7f0` |
| oracle 里 env 的形状（init 后） | `X[0]`=状态(1→enable 后 2)、`X[1]/X[2]/X[4]/X[5]`=指针、`X[3]`=0、`X[6]=0x20260127`、`X[7]=0x00171000`；`*(X+8)` 指向一串指针 |
| `esp_btdm_controller_config_t` | **sizeof=20**；`version@0 stack@4 prio@6 cpu@7 hci_cmd@8 hci_conn@9 sleep@10 vnum@11 mode@12 magic@16`（C 的 `offsetof` 权威值，与我们的 extern struct 完全一致） |
| IDF 的 `cfg.btdm` 默认值 | `version=0x20260127 stack=4096 prio=23 cpu=0 hci_cmd=5 hci_conn=3 sleep=0 vnum=0 mode=1 magic=0x5a5aa5a5` |
| 整份 `esp_bt_controller_config_t` | **192 字节**，`ble` 在 0..167、`btdm` 在 **168**；完整 hexdump 已存进 `config.zig` 的 `idf_cfg192` 模板 |
| `r_btdm_task_deinit` 的销毁顺序 | `lwb a0,20(a5)` 调一次、`lw a0,16(a5)` 再调一次；伪造 env 时 fault 落在 **+0x4a**（store access fault） |

**当前两个开放问题**（下一轮从这两条开始）

1. **`r_btdm_task_init` 为什么判定失败**：它的错误码存在 `s2`（`-2` 版本检查、`-4/-6` mutex/eventq、`-14/-15` event-arg），
   而板侧 trace 显示 `mutex_pend => OK` 之后再无任何 hook。已加**每个 hook 的返回值日志**，
   下一轮看最后一个非 0 返回即可。
2. **IDF 里谁发布 env**：oracle 逐步复刻证明步骤 1–5 之后锚点仍为 0，而 `esp_bt_controller_init` 成功后变非 0
   ⇒ 发布者在 step 6 或之后。已排除：配置布局、配置内容（192 字节已对齐）、时钟、复位、池、
   锚点形状（伪造会导致 deinit 收敛循环，是伪路径）、归档强符号替换。

### ⛔ 已整条撤回：`OkE7 → fqmZk → P → 2aNN` 那条推理

**撤回理由（静态反汇编直接读出，2026-11-17）**

`21.o` 里 objdump 的 `.LANCHOR0` 是**每个对象一份**的同一个 4 字节变量，所以
`r_sym_bt_OkE7` 的判空和 `r_btdm_task_init` 的读取**指向同一个变量**：

```asm
; r_btdm_task_init 偏移 0x4c-0x58
lui  s1, .LANCHOR0
mv   s1, s1
lw   s2, 0(s1)          ; ← **读**锚点值（不是写）
call wr_btdm_osal_get_time_forever
```

⇒ 该变量在 `21.o` 里**既无写者、也无初值** ⇒ 恒为 0 ⇒ **IDF 里 `OkE7` 同样走早退分支**
⇒ `fqmZk` 两边都不跑 ⇒ `P` 两边都是 0
⇒ `r_sym_bt_2aNN`（向 `P` 里写）位于早退之后的分支上 ⇒ **两边都不执行**。
   （⚠ 这条是**静态推断**：我曾试图用"替身打日志"实测，但替身链接后
   `nm -S` 显示 size 仍是 `0x10` —— 与归档原版长度**相同**，因此**无法判定**
   是我们的定义还是归档的定义胜出，那次实验**无效**，不能作为"从未被调用"的证据。）

**stall 不在 `2aNN` 那次 store 的\*有效\*依据**（别用"替身没打日志"那条，它无效）：
在 `P` 已被 workaround 填成非 NULL（`0x2f014838`）的那几轮板上实测里，那次 store 是**无害**的，
而**卡点依旧**（仍然没有 `task_create`、没有任务体、没有 step 7）。
⇒ 无论 `2aNN` 有没有被调用，它都不是本次 stall 的位置。

**结论**：`OkE7` / `fqmZk` / `P` / `2aNN` 这一整条线属于**错误路径**，与本次 stall 无关。
此前围绕它得出的"P=NULL 是根因""2aNN 向地址 0 写导致 stall""补调 fqmZk 是最后一步"
**全部作废**。`populate_workaround` 保留但默认关，仅作历史痕迹。

**同时确立的两条工艺结论**

| 结论 | 依据 |
| --- | --- |
| 归档内部**强符号**（`T`）能否被我们的 `export` 覆盖：**未定** | 替身 size `0x10` 与原版同长 ⇒ 判不出来。`ets_printf` 能覆盖是因为 ROM 那份是 `PROVIDE` **弱**符号（这条确定） |
| 找"写某全局"要搜 `lui+addi` 之后的**无重定位 `sw`**，不是 `LO12_S` | `LO12_S` 只出现在"以该全局为基址+偏移"的写 |
| **替换/替身类实验：先 `nm -S` 确认生效，再上板** | 本战役有一次替身 size 与原版同长（`0x10`），事后才发现"测了个寂寞"，白烧一轮板 |

**目前唯一站得住的板侧前沿证据**：**我们自己的** `osal.taskCreate` 入口日志为 **0 次**
（这是我们代码里的 trace，挂在 `wr_btdm_osal_task_create` 上，**真实有效**）。
⇒ stall 发生在 `mutex_pend` 与建任务调用（`BOhff`）之间，**或 `mutex_pend` 本身没返回**
（该 trace 本轮被移除，未知）。

**下一轮第一件事**（按顺序）

1. 用已拿到的 `nm -S` 尺寸（`r_btdm_task_init` = `0x11c`）**精确重切**函数体，
   重读 `0x42`–`0x78` 之间的真实指令流（现版本序列不可靠）。
2. 恢复一行 `mutexPend< OK/TIMEOUT` trace，判定 pend 到底有没有返回。
3. 恢复**每调用一行的 OSAL 入口日志**（writer 已改有界，噪声有界），
   看 step 6 内最后一条是哪个 hook —— 这是唯一还没试过的直接观测手段。

### 📌 交接摘要（2026-11-17 收官，接手从这里读）

**一句话**：官方 IDF 在**同一块板**上 BLE `init`/`enable` 全 `ESP_OK` ⇒ 硬件没问题；
我们的裸机移植卡在 **init step 6**，直接位置是"通过一个空锚点做 store"，任务体与建任务**从未发生**。

**板侧硬事实（可复现，均为实测）**

| # | 观测 | 意义 |
| --- | --- | --- |
| 1 | IDF oracle：`controller_init -> ESP_OK`、`controller_enable -> ESP_OK`、心跳持续 | **硬件与厂商栈正常** |
| 2 | 我们的日志止于 `enter step 6` | 卡在 step 6 内 |
| 3 | PC 采样**最后一条在第 190 行**，`enter step 6` 在**第 212 行** | 卡住期间**无中断** ⇒ 事务不退休（stall），**不是自旋** |
| 4 | `osal.taskCreate` 入口日志 **0 次**、调度器 trampoline 日志 **0 次** | **任务从未被创建**，更没执行 |
| 5 | `OkE7` 锚点（`r_sym_bt_r4auAKWSAFwgQarMHZCc`）直读 = `0x00000000` | 该守卫取"立即返回"分支 |
| 6 | oracle：`before_init` 时 `OkE7_anchor=0`、`Xpuq_P=0`；`after_init` 时分别 `0x2f07bdec` / `0x2f07c1b8` | init **之前**两个锚点都是 0 是**正常态**，不是缺陷 |
| 7 | 5 个池由 `r_btdm_os_mempool_init` 建成，全部 `rc=0` | 池这条已修好（此前从未初始化） |

**因果链（前半段实测，后半段标注不确定）**

```
step 1 建池（已修好，rc=0）
  ...
step 6 r_btdm_task_init
  → r_sym_bt_2aNN：`lw a5,0(anchor2.o)` … `sw zero,0(a5)`   ← 若 a5 为 NULL，向地址 0 写入
  → 事务不退休：无异常、无采样、无后续调用（建任务/任务体都没发生）
```

> [!WARNING] 尚未确证的部分（别当结论引用）
> - `2aNN` 在 stall 瞬间的 `a5` 值**没有直接测到**（init 期间外部读不到）。
> - 我从反汇编拼出的 `.L103` 调用序列（`OkE7 → … → mutex_pend → 2aNN`）
>   **可能混入了同对象里相邻函数的代码块** —— 因为 `21.o` 里**全库没有任何 store**
>   到它自己的锚点，而 `fqmZk`（写 `2.o` 锚点的唯一函数）只被 `OkE7` 调用；
>   若 `OkE7` 恒走早退分支，那 `fqmZk` 永远不跑 —— 这与 IDF 正常工作**矛盾**。
>   矛盾出在"静态归属"这一侧，所以调用序列的归属**需要重新核对**（用 `nm -S` 的大小切分）。

**下一步（有界、可按序做）**

1. 用 `nm -S` 的 `size` 精确切分 `r_btdm_task_init` / `OkE7` / `r_btdm_task_deinit` 的**真实边界**，
   重建调用序列（当前版本不可靠）。
2. 给 `r_sym_bt_2aNN` 一个**强定义替身**（全局符号，`ets_printf` 同一手法）：
   打印锚点值后按原逻辑执行 —— 一次就能定死"`P` 在那一刻是 0 还是有效"。
3. 若确认 `P` 为 NULL：按 oracle 的合同**由我们发布它**（`X != 0` 且 `*(X+8) != 0`，
   值形态参考 oracle 的 `0x2f07bdec` / `0x2f07bb7c`），而不是等归档自己填。

### ⚠ 证据分层（2026-11-17 深夜二次校订）

下面那节把"推测"和"已证实"混在一起了，这里按证据强度重列。**已证实**的是前三步，
hang 的**直接位置**是第四步，而它与 `P` 的因果关系**尚未证明**。

**已证实（板上实测）**

1. 我们的 `btdm_osal_elem_mempool_init` 此前只做容量校验、从不调
   `r_btdm_os_mempool_init` ⇒ 归档的 5 个池从未初始化。
   现已补上，板上 5 个池全部 `rc=0`。
2. `r_sym_bt_OkE7`（`r_btdm_task_init` 的第一个调用）有一个守卫
   `*(*(.LANCHOR0) + 8) != 0`，为假时跳过 `r_sym_bt_fqmZk`；
   而 `fqmZk` 是写 `.LANCHOR0`（= `r_sym_bt_d3D3sk5KewclELfrD5xa`）的唯一函数。
   板上直读该全局 = `0x00000000`。
3. 官方 IDF v6.1 在同一块板上 `controller_init`/`enable` 均 `ESP_OK` ⇒ **硬件无问题**。

**已证实，但含义待定**

4. hang 期间 66 条新鲜 PC 采样几乎全在 ROM `0x2f83efda`/`0x2f83efd2`/`0x2f812220`，
   即 `uart_tx_wait_idle` 族那个 `while (TXFIFO_CNT > 127)` 循环。
   但 `UART0_STATUS` 在 100 ms 间隔下会 `128 → 0` 跳变 ⇒ **FIFO 会排空**，
   所以"永不排空"不成立；该循环是谁调用的、为什么一直不满足，**都还没定**。

**推测，未证实（此前被我写成结论，现收回）**

- "`Xpuq` 从地址 0 零填充到 `0x2010B100`（≈1.34 亿次写）"：
  反汇编只确认了对 `*P` 的 3 条 store 和常量 `a3 = 0x2010B100`，
  **循环条件没有查完**，"1.34 亿次""清零 modem 窗口"都是**推测**。
- "把 `P` 变有效就能过 step 6"：不成立 —— `P` 已被补成非 NULL 后，
  step 6 **仍未走完**（板上日志止于 populate 行）。

**两个待判实验（都还没跑）**

| 实验 | 判别什么 |
| --- | --- |
| 接管 ROM 导出的一整族 `uart_tx_*`（`uart_tx_one_char/one_char2/wait_idle/flush`） | 自旋是否就是"打印阻塞"；若是，step 6 应能走通 |
| 用 IDF oracle 打印锚点 `r_sym_bt_r4auAKWSAFwgQarMHZCc` 在 init 前/后/enable 后的值 | 谁该发布它、该填什么 |

**已修的卫生项**：我们的 `log.line` 每一行原先都走 ROM 的 `esp_rom_printf`（`0x2f800024`），
它正是那个会自旋的实现；现已改为 `hw.rawWrite`（有界，FIFO 满时放弃），
我们的日志不再有可能成为卡死源。

### 真实根因（2026-11-17 晚，PC 采样 + 全局直读）【下文含未证实的推测，见上一节】

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

### 板级调用序列与故障点（2026-11-18，trace 开启）

`components/bt-blobs/tools/build-probe.sh` 默认构建的 probe 镜像（ROM PHY 路径）打开
`osal.trace_hooks`，崩溃前的全部归档调用如下（`logs/bt-probe-trace.log`）：

```text
bt hook: malloc(2244) = 2f0142d0      bt hook: malloc(132) = 2f014ba8
bt hook: malloc(820)  = 2f014c40      bt hook: malloc(80)  = 2f014f88
bt hook: malloc(64)   = 2f014fe8      bt hook: malloc(16)  = 2f015038   ← 锚点[8]
bt hook: malloc(76)   = 2f015058                                        ← 锚点[6]
bt hook: mutex_init => 0              bt hook: eventq_init
bt hook: malloc(8)    = 2f0150b8                                        ← 锚点[4]
bt hook: mutex_pend                    bt hook: mutex_pend => OK
!! mepc=0x4005b692 mtval=0x00000000    panic: exception code=7 (store access fault)
panic: ra=0x4005fa94 a0=0x0
```

两条可判读的事实：

1. **三个已发布的锚点就是崩溃前那三次 `malloc` 的结果**（0x2f015038 / 0x2f015058 / 0x2f0150b8）
   ⇒ 锚点不是"外部填的全局"，而是归档自己 `malloc` 出来、挂到 per-object 锚点位上的对象指针。
2. **崩溃紧跟在 `mutex_pend => OK` 之后**，中间没有任何 hook ⇒ 那次向地址 0 的写是归档的
   **内联代码**，不是 OSAL 回调。`mtval=0` 说明写地址确实是 0。

**7 个未发布锚点的归属**（闭包对象明文 `.symtab` 反查，一次 grep 即可）：

| # | 锚点 | 引用它的对象 → 所属子系统 |
| --- | --- | --- |
| 0 | `pSy5Wex…` | `libbtdm_common_11/12` → HCI pkt flags |
| 1 | `WDq2rzn…` | `libbtdm_common_16` → 数据对象（无常函数名） |
| 2 | `YnZmsxu…` | `libbtdm_common_17/19` → sched list |
| 3 | `kfu8vf8…` | `libble_app_49` + `libbtdm_common_19` → sched/BLE |
| 5 | `sitBB3S…` | `libbtdm_common_20` → sleep |
| 7 | `lRdavKx…` | `libbtdm_common_3` → **HCI flow control**（`r_btdm_hci_fc_env_init`） |
| 9 | `y5Dip5N…` | `libbtdm_common_9` → HAL RTC freq |

⇒ 它们全部属于**更晚的子系统**，本该由各自 init 发布 ⇒ **它们是"没走到那一步"的结果，不是原因**。

**`mepc=0x4005b692` 已定案（手工解码最终 ELF；objdump 因该段缺 ISA 属性只肯打成 `.word`）**：

```asm
4005b692  lui  a5, 0x2f010        ; a5 = 0x2f010000
4005b696  lw   a5, -0x30(a5)      ; a5 = *(0x2f00ffd0)  ← 就是 anchor[0] 槽
4005b69a  c781                    ; beqz a5, …
```

`0x2f00ffd0` 正是 gate 读的锚点表基址 ⇒ 崩溃现场是**在消费 anchor[0]**，而 anchor[0]
（`pSy5Wex1v0iXw5RdWtwL`）恰好是未发布的 `0x0`。

**仍未闭合**：该入口的指令是 `lui`/`lw`，本身不可能是 store；`mtval=0` 的 store fault 要么落在
`beqz` 之后的路径（trap 帧的 mepc 取值点与我的假设不同），要么落在随后 `lw a0,28(a5)` 的下游。
要一句话说死，需要一份 **linker map**（`-Wl,-Map=`；Zig 0.17 的 `addLinkArgs` 不在 `Module` 上，
本轮尝试未落地），把 PC→section 对上。

### 假设"任务没跑导致 init 失败"——**已证伪**（2026-11-18）

推论：归档 init 在等它刚创建的任务发就绪信号，而我们调度器只登记不执行 ⇒ 等不到 ⇒ 失败。

两条证据否掉它：

1. **立即抢占已实现**：`osal.taskCreate` 里有 `if (!sched.isStarted()) sched.startScheduler(task);`
   —— 新任务在创建处直接跑一次，阻塞时回到调用者。所以"只登记不执行"不成立。
2. **崩溃前没有 `task_create`**：那行日志不受 `trace_hooks` 过滤（前缀不是 `bt hook:`），
   而 `logs/bt-probe-trace.log` 里**一次都没有** ⇒ 归档在建任务之前就死在 step 6 里。

⇒ 对本崩溃不成立（对**后续**步骤仍是必要条件）。落点仍是：
`r_btdm_task_init` 在 `mutex_pend => OK` 之后、建任务之前，经 anchor[0]（0）的 trampoline 触发 store to 0。

### 锚点的定义者（`nm --defined-only`，2026-11-18）

`grep -l` 只给**引用者**；要定"谁该发布它"，必须看定义者：

| 锚点 | 定义者 | 引用者 |
| --- | --- | --- |
| `pSy5Wex…`（anchor[0]） | `libbtdm_common_11.o` | `libbtdm_common_11/12.o` |
| `WDq2rzn…`（anchor[1]） | `libbtdm_common_16.o` | `libbtdm_common_16.o` |

⇒ anchor[0] 的**定义者与消费者是同一个对象**（`_11`）：发布它的 init 函数就在这个对象里，
而崩溃的 trampoline 也在同一个对象里读它 ⇒ 定位"哪个函数写这个槽"只需在这一个对象里找。

**未取到的一步**：`objdump -dr` 对该对象没有输出针对该符号的重定位（引用可能在数据段的指针表里），
所以"哪个函数写这个槽"还没定到。下一步：用 `readelf -r libbtdm_common_11.o | grep pSy5Wex`
看它在哪个 section 被重定位，再回到对应函数。

### 锚点表是**固定绝对地址**的结构，发布者不靠符号重定位（2026-11-18 定案）

全包 `readelf -r` 扫描后，针对 anchor[0]（`pSy5Wex…`）的重定位**只有一处**：

```text
libbtdm_common_12.o  00000004  R_RISCV_HI20  r_sym_bt_pSy5Wex1[...]
```

类型是 **HI20（取地址/load）**，**没有任何 store 型重定位**。结合 gate 的事实
（锚点表基址固定为 `0x2f00ffd0`，10 个槽连续排列），结论是：

> 发布者**按固定绝对地址 + 偏移**写这些槽（`lui 0x2f010` + `sw …, -0x30(a5)` 这类），
> 所以编译器**不需要**对它发重定位 —— 用 `grep relocation` 永远找不到发布者。

⇒ 找发布者的正确方法是**在反汇编里搜常量**（`0x2f010000` 附近的 `lui` + 对应的 `sw`），
或者用 linker map 把 `0x2f00ffd0` 归到某个 section。这也解释了为什么"补 7 个锚点"没有意义：
它们各自由**算地址的代码**写，而不是由某个可定位的符号赋值。

### 当前卡点（2026-11-18 净结论，别再重走）

| 事实 | 证据 |
| --- | --- |
| 崩溃前 12 次 OSAL 调用**全部成功**，无 TIMEOUT | `logs/bt-probe-trace.log`（`mutex_pend => OK`，无失败行） |
| `task_create` **从未发生** | 该日志不受 `trace_hooks` 过滤，却一次未出现 |
| 崩溃在 **step 6 前半段**（建任务之前） | 同上 |
| 崩溃读的是 **anchor[0]**（`0x2f00ffd0`，值 0） | `mepc=0x4005b692` 手工解码：`lui a5,0x2f010; lw a5,-0x30(a5)` |
| anchor[0] 定义在 `libbtdm_common_11.o`，由 `_12` 取地址 | `nm --defined-only` / `readelf -r` |
| 发布者用固定地址算术写，无符号重定位 | 全包只有一处 HI20、无 store 重定位 |

**已排除**：任务未运行（立即抢占已实现）、mutex 超时（无 TIMEOUT）。
**下一步**：在闭包反汇编里搜 `0x2f010000` 附近的 `sw`（或拿 linker map），定位"谁该写 anchor[0]"。

### 找发布者的方法边界（2026-11-18 试过，记下结论）

- **对象级 `objdump -d` 没用**：`.o` 未重定位，`lui` 的立即数全是 `0x0`（地址来自 `R_RISCV_HI20`），
  所以"在闭包里搜 `0x2f010000`"必然 0 命中。
- **只能对链接后的 ELF 搜**：`zig-out/bin/app.elf`（probe 构建、strip=false）里
  `lui …,0x2f0xx` 共 **591 处** —— 绝大多数是我们自己的 arena/日志/寄存器访问，
  靠这一条筛选不出发布者。
- ⇒ 正确工具是 **linker map**（把 `0x2f00ffd0` 归到某个 section），或在 ELF 上按
  `sw …, -0x30(...)` + 同函数内 `lui 0x2f010` 的**组合模式**过滤。Zig 0.17 的
  `Build.Module` 没有 `addLinkArgs`，出 map 需要换写法（例如 `compile.link_args`）。
