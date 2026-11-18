> # ⚠️ 阅读顺序（先读这里）
>
> 本文件按时间**追加**了 60+ 节，其中**多节已被后续实验推翻**（每节都已就地标注"作废/撤回"）。
> 请按此顺序阅读：
>
> 1. **本节下方「当前状态」块** —— 唯一权威，与任何历史节冲突时以它为准；
> 2. **文末「框架修正」节** —— 说明为什么"abort 消失"不是进展；
> 3. 需要过程与反例时再读中间各节。
>
> **一句话现状**：三个根因（`anchor[8]` 自伤、PHY 域时钟缺失、容量缺口）中前两个已修、
> 第三个仍是阻塞；`carve-out` 把 abort 换成了无限重试，**不是修复**。
>
> 相关技能：`s31-ble-probe-bringup`（构建与判读）、
> `baremetal-instrument-selfcheck`（8 条仪器自检，读任何读数前先过一遍）。


> ## 当前状态（唯一权威，2026-11-19 末）
>
> | 项 | 现状 |
> | --- | --- |
> | **默认构建 + `phy_domain_enable=false`（基线，799 KB 级）** | init 跑到 `Xpuq`(`0x4005eb1e`) → `.L547` 首读 `0x2010B000` → **静默停摆（无 panic）**；心跳止于 ~320 tick |
> | **`phy_domain_enable=true`（总线停摆修复）** | 心跳升至 **9728+ 且持续**（`0x2010B000` 一读即挂死**不再成立**）；归档**进到 step 6**（`CODES n=16`）。⇒ 该修复**只解决了总线**，没有解决分配 |
> | **`WITH_PHY=1` + carve-out** | ❗ **不是修复**：`calloc(1,1904)` 不再失败，但 arena 因 4×2048 B 的 `.bss` 缩小到 351 936 B < 归档需要的 ~354 896 B ⇒ **把 abort 换成了无限重试**。详见文末「框架修正」 |
> | 锚点读数 | 取址已修（`@extern` 本身即指针）。**两版都已复验且全为 0**：默认版 `base=0x2f00ffd0: 0×10`，`WITH_PHY=1` 版 `base=0x2f010ee0: 0×10` ⇒ 与"ROM 不填这张表"一致 |
> | 调用序列 | 已可读：`CODES n=16 0120000000000000`（0=malloc 1=mutex_init 2=eventq_init 3=event_init 4=mutex_pend…） |
>
> **关于早前锚点读数的说明**：`&@extern` 取的是**调用栈上临时变量**的地址，
> 所以那段 dump 读的是栈 —— 第一个字是指针值（即 `base`，如 `0x2f010ee0`），
> 后面是栈上的 ASCII。**"指令字节/有效指针"两类读数都是栈噪声，与锚点内容无关。**
>
> **关键默认值**（改动前先看这里）：
> `publish_bohff_anchor=false`（预发布会让 `JwHs` 短路 ⇒ 旧的 -8 回滚签名）、
> `patch_bail_field=false`、`pmu_dump=false`、`anchors_enabled=false`、`phy_before_clocks=true`、
> `probe_stop_at_tick=0`、`log_hook_silent=false`。
>
> **唯一剩余工作**：在 `btdmLpEnableClock` 里移植 `wifi-blobs` 已验证的频域使能
> （`0x2058_71E0←0x3d` + CLK_CONF1 的 FE_* 位 + `I2C_ANA_MST`），**不要照抄 wifi 的 `LPCON+0x18←0x1`**
> （会清掉 bit2 `clk_i2c_mst_fo`，BLE 的 PHY 正走模拟 I2C）；材料见
> `phy_init_data.zig`、`init_probe.zig:686-700`、`osi_impl.zig`（`grep -n 'shellPhyEnable'`）。
> 判据：`initPhy()` 之后能否打印那行 "PHY enabled"，以及随后 `0x2010B000` 是否可读。
>
> 以下历史章节按时间追加，凡与本块冲突的以本块为准。

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
| 真实函数进镜像 | **仅 `WITH_PHY=1` 构建**：`esp_phy_enable` @ `0x40000744`(174 B) · `esp_phy_load_cal_and_init` @ `0x40000580`(452 B)。**默认构建走 ROM**：`esp_phy_enable`=`0x2f00e756`(ABS/PROVIDE)，`phy_get_romfunc_addr`=`0x40061728`(真实在镜像内) |

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

### anchor[0] 在整个镜像/归档里**没有任何软件写者**（2026-11-18 实测）

对链接后的 ELF 全面反汇编，统计"带符号标注的锚点 store"：

```text
sw …,<r_sym_bt_6Q68KSwuQQP4VjQGqiWa>   ×1        ← anchor[8]，已发布
（其余锚点：0 条）
```

而 anchor[0]（`pSy5Wex…`）的情况：

- 定义在 `libbtdm_common_11.o`（BSS），
- 全包 `readelf -r` 只有**一处**引用：`libbtdm_common_12.o` 的 `R_RISCV_HI20`（取地址），
- **没有任何 store 型重定位，也没有任何带标注的 `sw`**。

⇒ **归档里没有代码写 anchor[0]**。这与"7 个未发布锚点属于更晚子系统"是同一模式的极端情况：
anchor[0] 的写者不在归档里。

**假设（明确标注为未证实）**：`0x2f00ffd0` 起这张表可能是 **ROM/PHY 侧拥有的 RAM 状态**，
由 ROM 的 PHY 入口（我们经 `phy_get_romfunc_addr` / `esp_phy_enable` 调的那条链）填充；
ROM 路径下 PHY 使能"返回了"但可能并未真正完成标定 ⇒ 表里仍是 0。
这与 IDF PHY 对象路径行为不同（那条路在 PHY 内就停了）指向同一个方向：**PHY 初始化没有真正完成**。

**验证方式（下一步）**：在 `pp.initPhy()` 前后各读一次 `0x2f00ffd0` 区域的 10 个字并打印 ——
若 `esp_phy_enable` 返回后 anchor[0] 仍为 0，则"ROM 未填表"成立，问题回到 PHY 使能本身。

### ROM 的 PHY 使能**不填**锚点表（2026-11-18，前后对读，假设已否）

在 `pp.initPhy()`（`phy_get_romfunc_addr()` + `esp_phy_enable(2)`）前后各读一次 `0x2f00ffd0`
的 10 个槽：

```text
bt anchors[before-phy]: 0 0 0 0 0 0 0 0 0 0
bt anchors[after-phy]:  0 0 0 0 0 0 0 0 0 0
```

⇒ **"表由 ROM/PHY 填充"这条假设否掉了**：PHY 使能返回后，表仍然全 0。

配合另外两条事实：

- 归档/镜像里**没有**指向 anchor[0] 的 store（全 ELF 只有 anchor[8] 一处 store 标注）；
- 进 step 6 时表仍全 0，而在 `mutex_pend => OK` 那一刻已有 **3 个**槽被填
  （`logs/bt-probe-anchors.log`）。

⇒ 结论收窄为：**这 3 个槽是 `r_btdm_task_init` 内部自己的代码写的（算地址、无符号标注），
而写 anchor[0] 的那一段没有被执行到** —— 也就是 task_init 在到达写 anchor[0] 之前就已经中途退出
（随后走 `r_btdm_task_deinit`，在那里读到 NULL 而崩）。

**下一步只剩一件事**：定位 task_init 里"为什么提前退出"——最直接的手段是把
`ets_printf` 接回我们的 logger（归档自己会报它走到哪），而不是继续反汇编。

### 锚点不是 ROM 表，是归档自己的 BSS 变量；但 `g_phyFuns` 对不上（2026-11-18）

- 本机**没有 S31 的 ROM ELF**（`esp-rom-elfs` 里只有 esp32/c2/c3/c5/c6 等；用 S3 的去解释 S31 地址是张冠李戴）。
  权威来源是 IDF 的 `components/esp_rom/esp32s31/ld/*.ld`。
- 那些 `.ld` 里 **0x2f00f 段没有任何符号** ⇒ `0x2f00ffd0` 不在 ROM 符号表里。
  结合 `sw …,-16(a0) # 2f00fff0 <r_sym_bt_6Q68KSwu…>` 这类标注：**这 10 个"锚点"就是归档各对象的
  BSS 变量**，被链接脚本排成连续的 0x2f00ffd0 + 4i（`anchor[8]` 在 +0x20 = 0xfff0 ✓ 与标注一致）。
  ⇒ "ROM 拥有的状态区"这条假设到此**完全排除**（前景对读也已实测全 0）。
- 顺带一个**对不上**的观察：IDF 的 S31 ROM 符号里 `rom_phyFuns = 0x2f07fc3c`，而板侧
  `BOOTSTATE` 打印的 `g_phyFuns = 0x2f07f944` —— 两者不同址。即 `phy_get_romfunc_addr()`
  填的是 RAM 里的另一张表，而非 ROM 静态表。这条值得单独查（可能与 PHY 使能"未真正完成"有关）。

### 结论：写 anchor[0] 的代码在 `libbtdm_common_11.o` 里但没被执行到

anchor[0] 是该对象的 BSS 变量（`B` 符号），而同对象的 trampoline 会读它。全镜像没有对它的
store 标注、也没有 store 重定位 ⇒ 写者用**别的方式**算地址（例如经 `_bss_start_btdm` + 偏移，
或经另一个锚点导出的指针）。既然进 step 6 时表全 0、`mutex_pend` 时已有 3 个槽被填，
**说明 task_init 里前面那些写成功了、写 anchor[0] 的那段没跑到** ⇒ 故障前 task_init 已提前退出。

### printf 桥接就绪，但归档在这条路径上**不打日志**（2026-11-18）

桥接落地后的板级运行（`logs/bt-probe-fmt.log`）：**归档侧输出 0 行**
（grep `ets_printf`/归档标记 = 0，日志里只有 bootloader 与我们自己的行）。

⇒ "让归档自己报进度"这条在本条路径上**得不到信息**：它要么不打印，要么日志级别过滤掉了。
通道本身是对的（闭包里 7 个对象引用 `ets_printf`，`esp_log_write` 0 个）。

**剩下两条杠杆**（都不需要额外硬件）：

1. 提高归档的日志级别 —— **已查到入口但还没跟进**：`r_ble_log_init_simple`
   （`libble_app_69.o`，8 字节）是 `auipc t1,0 ; jr t1` 的**尾跳**，重定位目标是
   `R_RISCV_CALL r_sym_ble_X6TrvuCkpvS7KEA8Jat8` —— 又一个 per-object 锚点符号。
   顺着这条链追了一跳：`r_sym_ble_X6TrvuCkpvS7KEA8Jat8` 由 `libble_app_71.o` 定义（224 字节），
   入口对 `a0`/`a1` 判空后返回，随后经另一个锚点 `r_sym_ble_pBNUoU5EPgUlFpeQVn6W` 取表 ——
   它是**日志输出函数**的形状，不是"设置级别"的函数。
   ⇒ 级别判断大概率在**各调用点**（每次打印前比较一个全局级别），要继续就得逐个调用点追。
   本条到此为止：再往下是成规模的逆向，不属于"顺带推进"。
2. ~~`rom_phyFuns` vs `g_phyFuns`~~ —— **已撤回**（见上节，地址读错）。

### 新仪器：`bt_mmio_*` 环形记录，崩溃时导出最近 12 次寄存器访问（2026-11-18）

归档的每次 modem 寄存器访问都经过 `board.hw.bt_mmio_read/write`（我们的代码）。现在它们在
**静默环形缓冲**里留痕（16 条，几次普通 store，不打印、不阻塞），trap 在 panic 末尾按发生顺序打出。

首次运行（`logs/bt-probe-mmio.log`）就给出了一条新事实 —— 归档死前在**同一个寄存器**上做
写-清零序列：

```text
R 0x20704100 = 0        R 0x20704104 = 0        R 0x207040f8 = 0
W 0x20109c10 = 0x00010000   W 0x20109c10 = 0
W 0x20109c10 = 0x00008000   W 0x20109c10 = 0
W 0x20109c10 = 0x40000000   W 0x20109c10 = 0
W 0x20109c10 = 0x2e000000   W 0x20109c10 = 0
R 0x20109c10 = 0
```

⇒ 崩前它**不是在遍历数据结构**，而是在对同一个寄存器做"写值 → 清零"（4 组），最后读回 0。

**地址已解码（IDF `soc/esp32s31/include/modem/`）**：

| 地址 | 名称 | 我们写入的位 |
| --- | --- | --- |
| `0x20109C10` | **`MODEM_SYSCON_MODEM_RST_CONF_REG`** | `0x00010000`=bit16、`0x00008000`=bit15、`0x40000000`=**RST_BLE_TIMER**(30)、`0x2e000000`=**RST_MODEM_SEC**(29)+27/26/25 |

每个值之后都跟一次 `0`（**脉冲复位**：置位→清零）。这与我们自己 bringup 里那句
`bt lp: mac reset族 done (btmac/btmac_apb/ble_timer/mod_sec)` **对应同一组位**
⇒ 归档在崩前自己又做了一遍 modem 复位族，最后读 `MODEM_RST_CONF` 得 0（正常：没有挂起的复位），
随后才在 NULL store 上崩。

⇒ 复位序列本身看起来是健康的，问题不在"复位没做"，而在**复位之后那次写**。
`0x2070410x` 三次读全 0 也仍待查（`MODEM_BASE+0x4100` = WIFI_MAC 段内）。

### 40 条寄存器史揭示了真正的动作：归档死前在**给 modem 关时钟**（2026-11-18）

把环从 16 扩到 48、导出 40 条后（`logs/bt-probe-mmio40.log`），崩溃前的序列是：

```text
R PMU +0x0f8 = 0 → W 0x10000000      PMU_IMM_SLEEP_SYSCLK   (bit28)
R PMU +0x0fc = 0 → W 0x80000000      PMU_IMM_HP_FUNC_ICG    (bit31)
R PMU +0x100 = 0 → W 0x80000000      PMU_IMM_HP_APB_ICG     (bit31)
R PMU +0x104 = 0 → W 0x80000000      PMU_IMM_MODEM_ICG      (bit31)
（读回四个寄存器全 0）
→ MODEM_RST_CONF 四组脉冲（bit16 / bit15 / RST_BLE_TIMER / RST_MODEM_SEC+3）
→ R MODEM_RST_CONF = 0 → store fault
```

`PMU = 0x2070_4000`（`esp32s31.peripherals.ld`）；`IMM_*` 是**"immediate"睡眠/门控**寄存器。

⇒ **这不是初始化序列，是下电序列**：先关 HP_FUNC/HP_APB/MODEM 的时钟门控，再脉冲复位 modem 各块，
然后去解引用一个未发布的锚点而崩。**与"崩在 `r_btdm_task_deinit`"完全吻合** ——
即 task_init 先失败，清理路径做了一整套 power-down，最后踩到 NULL。

⇒ 追查方向应回到**"task_init 为什么先失败"**（早于这些寄存器动作），
而不是再解读这段下电序列本身（它是正确的收尾动作，只是收尾时崩了）。
读回 0 也可能只是这些 IMM 位"写入即自清/只写"，不代表写没生效。

### PC 采样器也采不到归档内部：它采到的是我们自己的 UART 自旋（2026-11-18）

探针自带 IRQ 采样（T0，2 ms 周期，`irq-sample #N mepc=…`）。最新运行的 16 条采样**全部**是：

```text
irq-sample #12..15  mepc=0x400695a6  ra=0x40065fb2  a0=0x2f07aea1  a1=0x00000023
```

`a0/a1` 指向一个 0x23 长度的串、`mepc`/`ra` 落在我们自己的日志函数区间 ⇒ 采样器采到的是
**我们打印时的 UART 等待循环**，不是归档的 `r_btdm_task_init`。

原因有两条，都写在这里以免下次再试：
1. 采样周期 2 ms，而归档在 step 6 里**不打印、崩得很快**，整个 step 6 可能短于一个采样周期；
2. 只要我们在打印，采样就会被我们自己的日志函数占满（本板 UART TX FIFO 停在 128，打印很慢）。

⇒ **第三条外围仪器也用尽了**。要在 task_init 内部取样，必须换成"不依赖中断周期、不受我们日志干扰"
的观测：JTAG 写监视点，或把采样换成**在 task_init 前后各采一次高频窗口**（需要先解决打印拖慢）。

### 仪器清单与各自的极限（结论）

| 仪器 | 能回答 | 为什么还不够 |
| --- | --- | --- |
| OSAL trace | 归档调了我们哪些桩、返回什么 | 崩溃发生在下一个归档调用**之前** |
| printf 桥 | 归档自己报的进度 | 该路径输出 0 行 |
| 寄存器环（48/40） | 死前在碰哪些寄存器 | 只看到 deinit 的下电动作（果，不是因） |
| PC 采样 | 谁在占用 CPU | 采到的是我们自己的 UART 自旋；周期 2 ms 太粗 |

**结论**：这四个外围仪器共同把问题**框到了"task_init 内部、任何外部可见行为之前"**，
再往里需要**指令级**手段（JTAG 写监视点），属于另一类工具。

### 静默高频采样窗口：已建成，但**必须同时静音我们自己的日志**（2026-11-18）

本轮给采样器加了三件东西（都在 `trap.zig`/`bringup.zig`）：

1. `pc_ring` 从 8 扩到 **48**，`samplePcs` 相应改签名；
2. `trap.sample_quiet` 开关：为真时 IRQ **只记环不打印**（本板 UART FIFO 停在 128，打印既慢又扰动）；
3. `trap.resetPcs()` + panic 路径导出 PC 环（`panic: pc[i]=…`）。

窗口的接法是：`enter(6, …)` **先打印**（否则采样全落在 print 的 UART 自旋里）→ `resetPcs()` →
`sample_quiet = true` → `armT0Interrupt(100)`（100 µs）→ 进归档 init。
另外 `armT0Interrupt` 会**整字重写 CLIC 控制字**、清掉 probe 给 T0 设的 `nmies`(bit3)
⇒ 窗口里要把它补回去：`reg = (reg & 0x107) | (1<<3)`（`0x10801000 + 25*4`）。

**实测结果（`logs/bt-probe-pcs.log`）：48 条采样仍然全落在 `probe.logHook`** ——
`addr2line` 确认是 `components/bt-blobs/src/probe.zig:111` 的 UART 等待循环。

原因不是窗口没开，而是**窗口里我们还在打印**：归档一取到互斥锁，`gate` 钩子就打出 15 行锚点表，
每行都走 `logHook` 的 UART 自旋，把这 100 µs 的采样槽全占了。

⇒ **下一次要做的**：窗口里把 `Hooks.on_mutex_acquired` 一并清掉（现在 `probe.zig` 是唯一设置它的地方，
需要一个 `osal.clearMutexHook()` 之类的入口），再跑同一个窗口。届时采样才可能落在归档代码上。

### 找到"谁在窗口里打印"：`logHook` 里藏着一行 `osal.trace_hooks = true`（2026-11-18）

根因不是某个调用点，而是 `probe.logHook` **自己**每次打印都执行 `osal.trace_hooks = true` ——
于是调用方设的静音会在下一次打印后**被重新打开**，窗口内的 `bt hook:` 逐调用日志源源不断。

处置：
- 删掉那行副作用（trace 开关应在 probe 入口显式设，不该藏在日志钩子里）；
- 给 `logHook` 加**调用者返回地址环**（`trap.recordLogCaller(@returnAddress())`，16 条，
  panic 时导出 `panic: caller[i]=…`），下次再有人问"谁在打印"可直接答。

板级结果（`logs/bt-probe-pcs3.log`）：窗口内 `caller[]` **一条都没有** ⇒ **logHook 确实静音了** ✓；
而 48 条 PC 采样全部落在 **`hw.mmioRecord`** —— 因为归档在密集访问寄存器，而我们每访问一次就记一条环，
**我们的记录函数自己成了热路径**（观察者效应）。

⇒ 下一步很明确：**采样窗口里把 mmio 环也关掉**（加 `mmio_disabled` 开关，窗口内只置位不记录），
再看那 48 条采样落到归档的哪个函数上。这才是"去掉所有观察者"后的净观测。

### 采样窗口的最终形态：观察者效应已经到底（2026-11-18）

把三处 ISR 打印全部纳入 `sample_quiet`、`resetPcs()` 连 `irq_count`/`rom_handler_calls` 一起清、
并在窗口里 `hw.mmio_off = true` 关掉寄存器记录之后，48 条采样变成：

| 命中的函数 | 数量 |
| --- | --- |
| `hw.bt_mmio_read`（**外壳调用本身**） | 4 个不同地址 |
| `hw.mmioRecord` | 1 |
| `extfuncs.xMalloc`（**归档侧**） | 1 |
| `Io.Writer.print` | 1 |

⇒ 归档在最后几百微秒里**密集访问 modem 寄存器**，以至于"寄存器访问的外壳函数"本身就是热路径 ——
再关掉记录也去不掉这层壳（每次访问都要过一次 `bt_mmio_read`）。这是采样法在这种负载下的**物理上限**。

**两条出路**（都不需要 JTAG）：

1. **ISR 里按地址过滤**：只记录落在归档代码段（`r_sym_bt_*` / `r_btdm_*` / `r_ble_*` 的地址区间）
   的 PC，把 `hw.*`/`probe.*`/`osal.*` 的采样丢掉 —— 环里就只会剩归档的 PC；
2. 用归档的 `r_sym_bt_*` 表反查调用链（但这需要先有调用栈，而 RISC-V 没有帧指针时不现实）。

⇒ 下一步就是第 1 条：给 `recordPc` 加地址白/黑名单。这是当前唯一剩下、且明确可做的一步。

### 窗口内**一条采样都没有**：NMI 在 step 6 里没有触发（2026-11-18 收尾实测）

补上"周期可变"与"`bt_mmio_*` 调用者环"之后的运行（`logs/bt-probe-pcs5.log`）里：

- `panic: pc[...]` **零行**；
- `panic: caller[...]` **零行**；
- `panic: mmiocaller[...]` **零行**；
- 而 `panic: mmio[...]` 有 40 行（**窗口之前**我们自己的 bringup 访问）。

⇒ 结论有三条，都是负结果但确定：

1. **窗口内没有任何 PC 采样** —— 定时器/NMI 在 `r_btdm_task_init` 期间没有触发（`armT0Interrupt`
   重写 CLIC 控制字清掉 `nmies` 的问题，我补回 bit3 仍不够，可能被归档的临界区或 CLIC 配置再清）；
2. **窗口内没有 MMIO 访问** —— 那 40 条寄存器记录全部来自窗口之前的 bringup（含 modem 复位族），
   所以之前"归档在密集访问寄存器"的推断**要修正**为"我们自己的 bringup 在访问"；
3. 因此**采样法在 step 6 上无法取得任何归档侧证据**，不是"被外壳占满"，而是**一条都没有**。

**下一步（唯一可行）**：先让 NMI 在 step 6 内真的跑起来（在 `armT0Interrupt` 内部保留 `nmies`，
或改用不受 `mstatus.MIE` 影响的中断源），否则任何采样方案都无数据。这一步需要对着 CLIC 寄存器
逐位核对，是一次独立的调试。

### 一处尚未解释的矛盾（2026-11-18，留给下一步第一件事）

同一次运行（`logs/bt-probe-pcs6.log`）：

| 导出段 | 行数 |
| --- | --- |
| `panic: pc[...]` | **43**（采样有数据 ✓） |
| `panic: caller[...]` | 0（logHook 静音 ✓ 正确） |
| `panic: mmiocaller[...]` | **0** |
| `panic: mmio[...]` | **40** |

而 `hw.zig` 里 `recordMmioCaller(@returnAddress())` 确实在 `bt_mmio_read` 与 `bt_mmio_write`
的第一行（第 355/362 行），`mmioRecord` 只在同一对函数里被调用 —— 两者应当同进同出。
**但值环有 40 条、调用者环 0 条**，说明至少有一条假设是错的：
要么那 40 条不是本次开机写的，要么 `mmio_caller_n` 被某处清零，要么导出循环有作用域/类型问题。

**下一步第一件事**：在 panic 里先把两个计数器本身打出来
（`panic: mmio_n={d} mmio_caller_n={d}`）—— 一行就能分开"计数为 0"与"导出循环坏了"，
比继续读 40 条寄存器更有判断力。

### 矛盾解决了：不是环为空，而是**那段导出代码没被执行到**（2026-11-18 收尾）

在 `panic: pc[...]` 同一个位置加了 `panic: rings mmio_n=… mmio_caller_n=… pc_n=… caller_n=…`
这一行，结果**它也没有输出** —— 而 `panic: pc[...]` 打出 43 行。

⇒ 两条导出在**不同的代码块**里：pc 那条在会执行的分支，`mmiocaller[]`（以及新加的 rings 行）
在另一条**从未执行**的分支（`trap.zig:429` 附近的那个块）。

所以之前"值环 40 条但调用者环 0 条"的怪现象是**死代码路径**造成的，不是环没写进去。
**下一步（一行）**：把 `mmiocaller[]` 与 rings 行的打印搬到 `panic: pc[...]` 所在的那个块里，
调用者环就会立刻可见 —— 而它记录的是**归档自己的返回地址**，是当前唯一能拿到的归档侧 PC。

### 关键纠正：`bt_mmio_*` **不是**归档的入口，OSAL 钩子才是（2026-11-18）

归档的 undefined 符号只有 **10 个**（`__assert_func`、5 个链接脚本符号、`e_btdm_lp_modem_clock_set`、
`phy_printf`、`rtc_clk_xtal_freq_get`、`sprintf`）—— **`bt_mmio_read` 不在其中**（`flat/unresolved.txt`）。
仓内调用 `bt_mmio_*` 的只有 `porting.zig:190/194` 与 `probe.zig:342`，**全是我们自己的代码**。

⇒ 这也解释了那 40 条寄存器记录：**它们是我们 bringup 写的**（modem 复位族等），不是归档；
`bt_mmio_*` 的调用者环永远只会解析到 `porting.zig`/`probe.zig`，**这条观测路线是死路**。

**归档真正进入我们代码的入口是 OSAL 钩子**（trace 里那 12 次调用）：
`wr_btdm_osal_malloc` / `mutex_pend` / `eventq_init` / `sem_release` …

⇒ 正确的最后一个仪器：在 **OSAL 钩子函数**里记 `@returnAddress()` —— **那些返回地址就是归档的 PC**，
不需要打印、不依赖 mmio，而且是唯一的归档侧观测点。

实现形状（下一步，三处小改）：

1. `osal.zig` 加一个 `caller_ring` + `noteCaller()`（osal 保持零 `board` 依赖，所以只存不打印）；
2. `board/trap` 加 `pub var extra_dump: ?*const fn () void`，panic 时调用；
3. `probe.zig`（同时依赖 board 与 osal）注册一个 dump 函数，把 osal 的环打出来。

做完这一步，43 条采样即使仍落在我们的钩子里，也能通过调用者环得到**归档的返回地址**。

### 第一个"归档调用点"仪器：OSAL 钩子的返回地址环（2026-11-18，首跑无输出）

实现（三处）：
1. `osal.zig`：`caller_ring[32]` + `noteCaller()`，在 9 个入口记 `@returnAddress()`
   （`btdmMalloc/btdmFree/semPend/semRelease/mutexPend/mutexRelease/eventqPut/eventqGet/taskCreate`）；
2. `board/trap`：`pub var extra_dump: ?*const fn () void`，panic 时调用；
3. `probe.zig`：注册 `dumpOsalCallers`，把环里最新 12 条打成 `panic: osalcaller[i]=…`。

首跑（`logs/bt-probe-pcs7.log`）：panic 正常、`panic: pc[...]` 有 43 行，但
**`panic: osalcaller[...]` 0 行** ⇒ 要么 `extra_dump` 未被调用，要么 `osal.caller_n` 为 0。

**下一步第一件事（一行）**：把 `extra_dump` 是否存在、以及 `osal.caller_n` 打一行出来 ——
和上次 `mmio_caller_n` 一样，先分开"没注册"与"计数为 0"，再谈内容。

### 归档的三个 OSAL 调用点已**点名**，崩点就在最后一条之后（2026-11-18）

镜像用 `build-probe.sh`（含 elf2image）重建后 — 此前几次刷的是**旧 `app.bin`**，因此"0 条 osalcaller"
是在测上一版构建 — OSAL 调用者环立刻产出 3 条，全部解析到归档自己的代码：

| 归档调用点 | 所在函数 | 调用的导出 |
| --- | --- | --- |
| `0x4005f8c6` | `r_sym_bt_OkE7MxSSqFt63m8XlU3d` | **`wr_btdm_osal_mutex_init`** |
| `0x4005f8d4` | 同一函数 | **`wr_btdm_osal_eventq_init`** |
| `0x4005fa68` | `r_btdm_task_deinit` | **`wr_btdm_osal_mutex_pend`** |

`objdump` 显示 `OkE7…` 里那两处是**相邻**的：

```
4005f8d4: jal ra, <wr_btdm_osal_eventq_init>
4005f8d8: lw  a5,0(s0)
4005f8da: lw  a5,8(a5)
4005f8dc: beqz a5, 4005f878      <-- 为 0 就跳「退出」路径
```

⇒ **`[a5+8] == 0` 是 task_init 提前退出的直接判据**（不是异常、不是超时）。

随后 `r_btdm_task_deinit`：

```
4005fa5e: jal ra, <wr_btdm_osal_get_time_forever>
4005fa68: jal ra, <wr_btdm_osal_mutex_pend>
4005fa6c: lw  a5,0(s0)      <-- 崩点紧随其后
4005fa70: lbu a3,0(a5)
```

⚠️ **上一句是错的**：`mepc`/`ra` 显示崩点不在这里。`ra=0x4005fa94` 对应的调用点是
`0x4005fa90: jal ra, <r_sym_bt_cKuT2s3WOu8oyZWi8auj>`，真正崩的是**被调函数**，
不是 deinit 本体；`s0=0x2f00ffe8` 属于那个子函数的帧，不能拿来对读 deinit 的 `lw a5,0(s0)`。

**下一步**：`a5` 指向谁。`610` 行那条 `lw a5,8(a5)` 的 `s0` 与 `4005fa6c` 的 `s0` 是同一结构，
把 panic dump 里的 `s0`（`0x2f00ffe8`）与这两处的偏移对读，就能确定是哪个字段未初始化。

### 根因闭合：`anchor[0]` 未发布 → 归档自己 `sb` 到地址 0（2026-11-18）

`!! mepc=0x4005b692 mtval=0x00000000 mstatus=0x00003881`，`mcause=7`（store access fault）。

`mepc` 处的函数是 `r_sym_bt_cKuT2s3WOu8oyZWi8auj`，第一条指令就是读 **anchor[0]**：

```
4005b692: lui  a5,0x2f010
4005b696: lw   a5,-48(a5)        # 0x2f00ffd0 = r_sym_bt_pSy5Wex1v0iXw5RdWtwL = anchor[0]
4005b69a: beqz a5, .L201         # anchor[0]==0 -> 零值路径
4005b69c: lw   a0,28(a5)
4005b69e: jal  zero,<tail>
```

零值路径里：

```
4005b6b2: ori a4,a4,1
4005b6b6: sb  a4,0(a5)           # a5 仍为 0 -> 写地址 0
```

板上 anchor 表实测（`panic: anchor[i]`）：**anchor[0..2]、[5]、[7]、[9] 全为 0**，
非零的是 `[4]`、`[6]`、`[8]`、`[10]`。而 `mtval=0`、`cause=7` 与 `sb 0(a5)`（a5=0）完全吻合。

⚠️ **上面这条"sb 到 0"的结论已撤回**（2026-11-18 复核）：`cKuT...` 的零值目标是
`.L201: c.jr ra`（**仅返回，不写**）；真正的 `sb a4,0(a5)` 在下一个函数
`r_sym_bt_vpbJU7UPeyxEM4bymUIi` 里，同样被 `beqz a5,.L204` 保护。两者都不会写空指针。
而且 `mepc=0x4005b692` 是 `lui a5,0x2f010` —— `lui` 不可能触发访问异常。
⇒ **故障 PC 尚未确定**，`mepc` 与实际 store 指令对不上，是下一个要查的点。

即：**崩溃的直接原因不是缺 OSAL、不是锁、不是 PHY**，而是归档读到自己从未发布的
**anchor[0]** 后走"零值兜底"路径，而那条路径本身就假定指针非空 —— 归档的零值分支写地址 0。

**下一步**：确定 `r_sym_bt_pSy5Wex1v0iXw5RdWtwL`（anchor[0]）本该由谁发布。
它是 10 个 `r_sym_bt_*` 锚点里编号最小的一个；`[a5+8]==0` 的判据与 `lw a0,28(a5)` 的字段
说明它指向一个"表/描述符"。找写者仍用已验证的方法：`objdump -d | grep 'sw.*<r_sym_bt_pSy5'`
（注意 `.o` 未重定位时无效，必须用链接后 ELF）。

### 锚点是**惰性发布**：读取 → 为空则 malloc → 写回（2026-11-18，反汇编确认）

`r_sym_bt_OkE7MxSSqFt63m8XlU3d` 序言：

```
4005f868: addi s0,s0,-24              # s0 = 0x2f00ffe8 =& r_sym_bt_r4auAKWSAFwgQarMHZCc
4005f86c: lw   a5,0(s0)               # 读锚点
4005f876: beqz a5, 4005f886 <.L59>    # 为空 -> 惰性初始化
...
4005f88e: jal  ra,<wr_btdm_osal_malloc>   # malloc(76)
4005f892: sw   a0,0(s0)                    # <-- 把新指针写回锚点 = 发布
4005f896: beqz a0, 4005f878 <.L40>         # malloc 失败 -> 退出
4005f89e: jal  ra,<compiler_rt.smallMemset> # memset(0)
```

⇒ 这解释了"3/10 锚点已发布 = 崩前三次 malloc"：**归档按需发布锚点**，不是启动时统一填表。
`panic: anchor[i]` 打出的非零槽就是"本次运行已被惰性初始化过"的对象。

### 提前退出的真实判据（已确定）

`eventq_init` 之后：

```
4005f8d8: lw a5,0(s0)        # 刚 malloc 并 memset 的对象
4005f8da: lw a5,8(a5)        # 该对象 +8 字段
4005f8dc: beqz a5, .L40      # 为 0 -> 退出
```

对象是**自己刚分配且 memset 成全 0 的 76 字节**，所以 `+8` 必然是 0 —— 除非**别处先把它填上**。
⇒ 提前退出不是错误分支，而是"**依赖的另一个子系统尚未初始化**"的正常返回值。
这也解释了 `[a5+8]==0` 为什么与 anchor[6]/anchor[8] 的板上读数对不上：那个 `a5` 来自
`s0` 指向的**另一个**锚点（`r4auAK…`），不是 panic 里那个属于故障子函数的 `s0`。

**下一步**：`+8` 字段由谁填 —— 在链接后 ELF 里找对 `0(s0)+8` 的 `sw` 写者，
或用 `r_sym_bt_r4auAKWSAFwgQarMHZCc` 的消费点反查（`objdump -d | grep '<r_sym_bt_r4auAK'`）。

### 故障瞬间的实参寄存器：a4=1、a5=0、mtval=0、store（2026-11-18）

`logs/bt-probe-pcs10.log`：

```
!! mepc=0x4005b692 mtval=0x00000000 mstatus=0x00003881
panic: sp=0x2f07ad80 s0=0x2f00ffe8 s1=0x2f015598
panic: regs a4=0x1 a5=0x0 a6=0x40104264 a7=0x2f07acbf
```

这是 `sb a4,0(a5)`（`a4` 先被 `ori a4,a4,1`，`a5` 为 0）的**精确签名**：
`lbu` 得 0 → `ori 1` → 写地址 0 ⇒ `mtval=0`、`cause=7` 全部对上。

**但这条指令前面有 `beqz a5` 保护**，且：
- `nm` 检查 **没有** 重复的 `r_sym_bt_*` 符号（不是 duplicate 模块）；
- `anchor[0]`（`r_sym_bt_pSy5Wex1v0iXw5RdWtwL`）在 **`.bss`（section 11, NOBITS）**，无数据镜像 ⇒ 发布者只能是代码；
- 全镜像有 **48** 处引用 `0x2f00ffd0`（读取者很多，不是孤立变量）。

⇒ **矛盾仍未解开**：寄存器与 mtval 都指向"用 0 指针写"，但已知的两处 store 候选都被 `beqz` 保护，
而 `mepc` 落在一条 `lui`（不可能产生访问异常）。这条 instrument 的极限就在这里。

**下一步候选（按性价比）**：
1. 在 `vpbJU7UPeyxEM4bymUIi`（0x4005b6a4）的 `sb` **前**插一条记录（把 a5 写进静默环），直接看它执行时 a5 是多少；
2. 若确认为 0，则 `beqz` 没生效 ⇒ 查该分支的指令编码/是否被我们的 `gc-sections` 或跳板改写；
3. 或者接受"异步报点"解释（store 缓冲延迟提交），此时应改为**记录所有 `sb/sw` 的地址**而不是依赖 mepc。

### 操作教训（本轮代价最大的一条）

`python heredoc` 改源码时，若 shell 处于"busy session 的副本"状态，**写入不会落盘**，
脚本仍会打印成功。本轮因此有三次"改完刷板但镜像没变"：`strings app.elf | grep <新日志串>`
才是唯一可靠的判据。以后每次改源码都先 `grep -c <新串> 文件` + `strings app.elf | grep -c <新串>`
再烧录。

### 因果实验否掉 anchor[0] 假设（2026-11-18）

把 `anchor[0]` 提前毒化成**有效可写 RAM 指针**（`0x2f012e90`，`+8=0`），再跑一次：

```
poison: anchor[0] -> 0x2f012e90
panic: anchor[0]=0x2f012e90 +8=0x00000000
panic: regs a4=0x1 a5=0x0 a6=0x40104264 a7=0x2f07acbf
!! mepc=0x4005b692 mtval=0x00000000
```

**崩溃照旧**，`a5` 仍是 0 ⇒ **空指针来源不是 `anchor[0]`**。

⇒ 至此，此前"deinit 读未发布 anchor[0] → store 到 0"的整条链**被实验证伪**，不是解释。
`a5=0` 来自别处的某个值为 0 的字段/指针；`anchor[0]` 只是恰好也为 0，被误当成原因。

（`poison_anchor0` 已置回 `false`，开关与其结论都留在代码里供复现。）

**下一步**：既然 `a5` 不是从 `anchor[0]` 来，就必须**直接记录 a5 的来源**：
在归档唯一匹配 `(a4=1, a5=0)` 的 `sb` 之前插桩 —— 但归档代码不可改，
可行替代是让 `osal` 的每个入口把**入参**记进静默环（`a0..a2`），
崩溃时看最后几次调用的参数；若某次传入了 0 指针，那就是 a5 的来源。

### 对照实验与 mepc 可信度（2026-11-18，第三次自我修正）

**实验一：毒化 vs 基线（同组寄存器）**

| 运行 | anchor[0] | a3 | a4 | a5 | mtval | mepc |
| --- | --- | --- | --- | --- | --- | --- |
| 毒化 | `0x2f012e90` | `0x2f0155b8` | 1 | 0 | 0 | `0x4005b692` |
| 基线（poison off） | `0` | `0x2f0155b8` | 1 | 0 | 0 | `0x4005b692` |

⇒ 两组**逐寄存器相同** ⇒ 崩溃与 `anchor[0]` **无关**，"毒化自造崩溃"的猜测也排除。

**实验二：帧里的 mepc 是否陈旧** —— 在 fault 分支直接 `csrr mepc/mtval` 再读一次：

```
!! mepc=0x4005b692 mtval=0x00000000          <- 帧
panic: live mepc=0x4005b692 mtval=0x0        <- 直读 CSR
```

⇒ 帧**不是**陈旧值，CSR 里就是 `0x4005b692`。

**但 `0x4005b692` 是 `lui a5,0x2f010`**——`lui` 不可能产生 store 访问异常。
三条事实同时成立只有一种解释：**store 异常是不精确的（imprecise）**，
真正越界的那次存储被延迟报告到后续指令边界。⇒ **`mepc` 在这条链上不可用于定位指令**，
此前所有"崩在某条指令之后"的推断都因此作废（包括 `0x4005b6b6` 那一条）。

**下一步（唯一能绕开 imprecise 的办法）**：不再依赖 `mepc`，改为**记录每一次写**的
`(目标地址, 数据)` 对进静默环 —— 需要在归档的 `sw/sb` 前插桩不可行，
但可以在**我们自己的** `bt_mmio_*`、以及 `osal` 的分配/发布路径上记录；
若 `a5=0` 来自某个我们交付的指针（比如 `malloc` 返回 0 后未检查），那条记录会直接暴露它。

### 三个对照全部一致：故障可稳定复现，但 PC 不可解释（2026-11-18 收尾）

| 对照组 | 变更 | a4 | a5 | mtval | mepc |
| --- | --- | --- | --- | --- | --- |
| 毒化 | `anchor[0]`=有效指针 | 1 | 0 | 0 | `0x4005b692` |
| 基线 | 不毒化 | 1 | 0 | 0 | `0x4005b692` |
| 无采样器 | `sample_period_us=0x7fffffff` | 1 | 0 | 0 | `0x4005b692` |

三次**逐寄存器完全相同** ⇒ 与 `anchor[0]` 无关、与采样器无关，故障可稳定复现。

并已核对 ELF 字节：`0x4005b692` 处确实是 `lui a5,0x2f010`（`b7 07 01 2f`），
反汇编与镜像一致，不存在"看错镜像"的问题。

**剩下两种解释，各自都有可判据**：

1. **不精确 store 异常**（写缓冲延迟提交）：RISC-V 规范要求精确异常，但带写缓冲的实现可放宽。
   判据：在故障前插入 `fence`（归档代码不可改） ⇒ 不可行；
   替代判据：把同样的写放慢（在 `osal` 每次调用后 `fence`），若 `mepc` 变化，说明是延迟提交。
2. ~~**trap 在异常处理中被嵌套**~~ —— **此条已撤回**：RISC-V 的 `mstatus.MIE` 是 **bit 3**，
   `0x3881 & 0x8 = 0` ⇒ **MIE=0**（我最初按 bit0 判断，属解码错误）。`0x3881` 的
   MPIE=1（bit7）、MPP=3（bit11-12，M 模式）正是"trap 已进入"的标准值，不是嵌套证据。
   `mcause=0x38000007` 的高位在 CLIC/该核下有自定义含义，不能按"标准未定义 ⇒ 嵌套"推断。

**下一位接手者从这里开始**：第 1 条（不精确写）已由自测**证实**（见上一节），第 2 条（嵌套）已撤回。
所以下一步是"记录写目标"，并先用自测量出**延迟多远**（在写 0 之后插 N 条无害写，看 mepc 落多远）
来界定搜索窗口。

### 自测判定：这颗 CPU 的 **store 访问异常是不精确的**（2026-11-18，定论）

自测做法：在 `probe.run()` 里放一条带标签的 `sb zero,0(zero)`（地址 `0x4006a66e`），看 panic 报什么。

```
selftest: store-to-0 at 0x4006a66e      <- 真正的写指令
!! mepc=0x4006eff0 mtval=0x00000000     <- 报出来的 PC
panic: live mepc=0x4006eff0 mtval=0x0
```

`0x4006eff0` 是 **`compiler_rt.memcpySmall`** 里的 `sb a4,0(a3)`，与自测地址**相差约 19 KB**。

⇒ **结论：store 访问异常在这颗芯片上是延迟上报的**（写缓冲/总线提交语义），
`mepc` 只是"错误浮出时正在执行的那条指令"，**不是**出错的那次写。

**这条判定推翻了本 README 里所有"崩在某条指令之后"的推断**（含 `sb a4,0(a5)` 签名、
`cKuT`/`vpbJ` 的候选、以及基于 `a4=1/a5=0` 的所有推理）。它们记录在案作为反例，
不再作为结论。

**对归档那次崩溃的正确读法**：`mepc=0x4005b692`（`cKuT` 入口的 `lui`）意味着
"归档执行到这里时，某次**更早**的写被总线拒绝"，真正写 0 的指令在它**之前**，
需要用写目标记录（而非 PC）来定位。

**下一步（唯一有效方向）**：记录写目标。归档的 `sb/sw` 不可插桩，但可：
1. 在自测里验证"延迟多久"（在写 0 之后插入 N 次无害写，看 mepc 落多远）——用于界定搜索窗口；
2. 用 `osal` 每个入口把 `a0..a2` 记入静默环，看归档是否把 0 当指针传给我们（则写者是我们）。

### 延迟标定：错误在 **`fence` 之后的第一条指令**浮出（2026-11-18，规则确定）

自测序列（坏写 + `fence` + 正常写）在 ELF 里是：

```
40065bd4: sb     zero,0(zero)     <- 真正的坏写
40065bd8: fence  iorw,iorw        <- 排空写队列
40065bdc: lui    a0,0x1           <- panic 报出的 mepc 正是这一条
```

⇒ **规则：本核的 store 访问异常在 `fence` 处浮出，`mepc` = `fence` 之后的第一条指令。**
（上一次未加 `fence` 时错误晚了约 19 KB，正说明它是随写队列排空点上报的。）

顺带否掉一个便利做法：`@intFromPtr(&fn)` 打印出 `0x4006a71a`，而实际代码在 `0x40065bd4`
——**函数指针值不等于代码地址**（中间有跳板），拿它当"标签地址"比对会错配。

**对归档那次崩溃的读法**：`mepc=0x4005b692` 之前若有一条 `fence`（或等价的队列排空点），
真正写 0 的指令就在那条 `fence` **之前**；`cKuT` 入口只是"浮出点"。
下一步据此在 `0x4005b692` 之前反汇编找 `fence`，其前最近的 `sb/sw`（目标可能为 0）即真凶候选。

### 窗口夹小到「deinit 的最后四次调用」（2026-11-18）

在 **OSAL 每个钩子入口**插 `fence iorw,iorw` 后重跑：报出位置**完全不变**（`mepc=0x4005b692`）
⇒ 坏写**不在**任何 OSAL 调用之前。

而 `mutex_pend` 返回到 `jal cKuT` 之间的 36 字节：

```
4005fa6c: lw   a5,0(s0)
4005fa70: lbu  a3,0(a5)
4005fa74: bltu a4,a3, .L80
4005fa78: lw   a0,20(a5)
4005fa7a: jal  <r_sym_bt_gvLJK...>
4005fa7e: lw   a5,0(s0)
4005fa80: lw   a0,16(a5)
4005fa82: jal  <r_sym_bt_gvLJK...>
4005fa86: jal  <r_sym_bt_G1Ui...>
4005fa8a: c.jal <r_sym_bt_0cPe...>
4005fa8c: jal  <r_sym_bt_FzF1...>
4005fa90: jal  <r_sym_bt_cKuT...>     <- 报出点（入口的 lui）
```

**只有 load 和 jal，没有任何 sw/sb** ⇒ 坏写必在四个被调函数之一体内，
且该函数里有排空点（`fence` 或等价）在写之后、返回之前。

**更正**：上一条"`jal` 注释符号不可信"是**错的**。四个 `st_value`
（gvLJK=`0x4005f1c6`、G1Ui=`0x4005d1bc`、0cPe=`0x4005f618`、FzF1=`0x400609b2`）与 `jal` 操作数
**逐一吻合**。上轮"搜错区间"是 `objdump` 的**显示假象**（我的 `tail -12` 截断 + 它跳到下一个符号
边界 `0x40060aa0`），不是符号表错位。正确做法：按 `st_value + st_size` **精确**给区间
（`--start-address/--stop-address`），三小函数各 54/44/18 字节，一次就能看完。

**下一位接手者**：`readelf -sW app.elf | grep -E "FzF1|0cPe|G1Ui|gvLJK"` 取四个 st_value，
各自反汇编找 `fence`；有 fence 的那个函数，其 fence 之前的写就是真凶。

## 根因定位（2026-11-18）：`FzF1` 的零值路径在收尾段往空指针写 0

窗口四选一，`FzF1`（`0x400609b2`，54 字节）命中。它的写指令与零值分支：

```asm
400609c8: lw   a5,0(s0)          # a5 = *(s0)        <- 从这里取的指针
400609ca: beqz a5, .L113         # 为 0 -> 跳到收尾段
400609cc: lw   a0,8(a5)
400609ce: beqz a0, .L113
400609d0: jal  <wr_btdm_osal_intr_free>
400609d4: lw   a5,0(s0)
400609d6: sw   zero,8(a5)        # 清 +8 字段
400609da <.L113>:                # 收尾段：两条 lwsp 恢复寄存器
400609da: lwsp ra,12(sp)
400609dc: lwsp s0,8(sp)
400609de: sb   zero,0(a5)        # <-- 无条件！a5 仍为 0 -> 写地址 0
400609e2: li   a0,0
400609e4: addi sp,16
400609e6: jr   ra
```

⇒ **崩溃原因**：`*(s0) == 0` 时 `beqz` 跳到 `.L113`，而 `.L113` 末尾的
`sb zero,0(a5)` **位于守卫之外、且在恢复 s0 之后**，于是用刚判定为空的 `a5` 写地址 0。

⇒ `mtval=0`、`cause=7`（store）与此精确吻合；`a4=1` 是无关的旁观值
（`sb zero` 的数据是 0，不是 a4）。

⇒ `mepc=0x4005b692`（`cKuT` 入口的 `lui`）仍是**上报点**而非故障点：
这条链上没有 `fence`，错误是随写队列自然排空、在后续指令边界上报的。

### 为什么 `*(s0)` 是 0（仍需一步）

`FzF1` 在 `deinit` 里被调用（`0x4005fa8c`），`s0` 指向归档自己的一个 BSS 槽。
该槽为 0 ⇒ 对应对象**从未被惰性发布**（参见"锚点惰性发布"一节）：
归档按需 `malloc` 并写回槽位，`deinit` 时若该对象**从未初始化过**，槽位仍是 0，
而 `FzF1` 的收尾段无条件解引用它 —— 这就是 `task_init` 提前退出后 `deinit` 崩溃的直接机制。

**下一步（收尾）**：确定 `s0` 对应哪个槽（`FzF1` 序言的 `addi s0,s0,-N` 常量 + 基址 `0x2f010000`
即可算出），并在板上确认该槽在崩前一直为 0。然后决定修补方向：
让归档不走这条 `deinit`（例如修好 `task_init` 的 `[a5+8]==0` 依赖），
或在 `deinit` 前先给缺失对象做一次惰性发布。


### 缺失的槽位已确定：**anchor[9]**（2026-11-18）

`FzF1` 序言给出 `s0` 的来源：

```asm
400609b6: lui  s0,0x2f010
400609c2: addi s0,s0,-12 # 2f00fff4 <r_sym_bt_y5Dip5N8bwiiGRcrWzBO>
```

⇒ `s0 = 0x2f00fff4`，换算成锚点表基址 `0x2f00ffd0`：
`(0x2f00fff4 - 0x2f00ffd0) / 4 = 9` ⇒ **anchor[9]**。

而板上 `panic: anchor[i]` 的实测（多轮一致）：

```
anchor[0]=0 anchor[1]=0 anchor[2]=0 anchor[4]=0x2f0155b8 ... anchor[9]=0x00000000
```

⇒ **`anchor[9]` 从未被惰性发布** ⇒ `*(s0)==0` ⇒ `beqz .L113` ⇒ `sb zero,0(a5)` 写地址 0。

**至此整条链闭合，无推断成分**：

```
task_init: mutex_init -> eventq_init -> [anchor?+8]==0 -> 提前退出
  -> task_deinit -> FzF1 -> lw a5,0(0x2f00fff4)=0 -> beqz .L113
     -> sb zero,0(a5)   (a5=0) -> store access fault, mtval=0, cause=7
                                （上报点 = 排空点之后的指令，故 mepc 落在 cKuT 入口的 lui）
```

**修补方向**：
1. **治本**：找出谁该发布 `anchor[9]`（`r_sym_bt_y5Dip5N8bwiiGRcrWzBO` 的写者），
   并让它先于 `deinit` 执行 —— 用 `readelf -r` 的 LO12_S（写）/LO12_I（读）分类，或对链接后 ELF
   `objdump -d | grep -E '(c\.)?sw.*2f00fff4'` 找直接写者（注意 `lui+addi+sw` 形式的间接写）。
2. **绕过**：在 `deinit` 之前给 `anchor[9]` 预置一个哨兵对象，使 `FzF1` 走正常分支。

## 因果确认：毒化 `anchor[9]` 后崩溃**消失**，故障推进到新点（2026-11-18）

把毒化目标从 `anchor[0]` 改到 **`anchor[9]`（`0x2f00fff4`）**，其余不动：

| 运行 | mepc | mtval | cause | 结论 |
| --- | --- | --- | --- | --- |
| 基线 | `0x4005b692` | `0x0` | 7 (store) | `FzF1` 的 `sb zero,0(a5)` 写地址 0 |
| 毒化 anchor[9] | `0x4005f1c8` | `0x18` | **5 (load)** | **原崩溃消失**，改为 `gvLJK` 里读 `0x18` |

⇒ **`anchor[9] == 0` 是 `sb zero,0(a5)` 的直接原因，因果链闭合。**
（`0x4005f1c8` = `gvLJK` 入口 `0x4005f1c6` +2；`mtval=0x18` 是新的、不同的非法地址。）

**一致性旁证**：OSAL 调用环只有 3 条且**没有** `wr_btdm_osal_intr_free` ——
正好对应 `FzF1` 走 `*(s0)==0` 分支（另一条分支会在 `0x400609d0` 先调 `intr_free`）。

**注意**：`poison:` 那行日志文案仍写 `anchor[0]`，实际写的是 `0x2f00fff4`（文案未同步，勿被误导）。

## 修补顺序（重要）

`anchor[9]` 为 0 很可能**本身就是 `task_init` 提前退出的下游后果**：退出导致本该发布该对象的
步骤没跑到，`deinit` 才撞上未初始化对象。所以：

1. **先修 bail**（`task_init` 里 `[a5+8]==0` 的依赖），而不是先补槽 —— 补槽只会把崩溃挪到
   下一个未初始化对象；
2. `bail` 的形态（同一函数里先 `malloc+memset+sw` 惰性发布，再 `lw a5,0(s0); lw a5,8(a5); beqz`）
   很可能是 **not-ready 协议**：第一次调用只发布并返回"还没好"，拥有者初始化完再调一次。
   判据：在 bringup 里**把归档的 init 再调一次**（或等其它子系统起来后重入），看是否走得更远。

## 补槽的最小实现（若选择绕过）

毒化机制本身就是实现：把 `0x2f00fff4` 指向一块零填充的静态 RAM。
`.L113` 路径里 `lw a0,8(a5); beqz a0` 会命中 `+8==0` 回到 `.L113`，
`sb zero,0(a5)` 落在有效内存上无害，`li a0,0; jr ra` 干净返回 —— 崩溃整体消失。
（只对本故障够用；若上游把返回值 0 当失败，后续行为另说。）

## `deinit` 是归档**内部**的回滚，不在我们的调用链上（2026-11-18）

加了"第一次 rc≠0 就重试一次"的实验后，串口是：

```
bt bringup: enter step 6 r_btdm_task_init
!! mepc=0x4005b692 mtval=0x00000000        <- 直接崩
（没有 "retrying once" 这一行）
```

⇒ **`r_btdm_task_init` 自己调了 `r_btdm_task_deinit` 来回滚**，我们的重试代码永远到不了。
这也修正了更早的一句表述（"task_init 提前退出 → 我们调 deinit"）：**deinit 在归档内部**。

**两个推论**：

1. **not-ready 协议的重试必须发生在 `task_init` 之内**，我们无法在外面重试 ⇒ 该实验路径作废；
2. 要让流程走通，只有两条路：
   - **让第一次 `task_init` 不 bail**（即修 `[a5+8]==0` 那个依赖），
   - 或**在调用 `task_init` 之前就预置 `anchor[9]`**（等于预先满足回滚路径，让 deinit 安全返回）。
     这条已由毒化实验证明可行：毒化后 store-to-0 消失。

**推荐顺序**：先做第 2 条（成本一次 `probe` 改动，已验证可消除崩溃），
用它换取"能跑到 step 7/8"的观测；再回头找 `[a5+8]` 该由谁填 —— 那时拿到的是新卡点而不是崩溃。

## 两处必须在 README 里降级的说法（2026-11-18 末次复核）

### 1「task_init 因 `[a5+8]==0` 提前退出」——**未证实，暂不当作结论**

三条已有事实互相冲突：

| 事实 | 含义 |
| --- | --- |
| `eventq_init` 前 `fillBailField` 已把 `*(anchor[6]+8)` 填成非零（本次实测 `anchor6=0x2f015598 patch=applied`） | 该判据若存在，应被越过 |
| 板级 anchor dump：`anchor[6]=0x2f015598`、`+8=0x2f012628`（非零） | 同上 |
| OSAL 调用环 **n=3**（mutex_init / eventq_init / mutex_pend），**没有** bail 越过后那次 `fqmZk` 的 `malloc` | 说明没走到那一步 |

⇒ 补丁确实生效却仍崩，且没有后续 malloc ⇒ **bail 的位置/判据尚未证实**。
`r_btdm_task_init` 还有别的失败返回（21.o 里 `1c: r_btdm_task_deinit`），
不能把"`[a5+8]==0`"写成已证事实。**本文前面几处这样写，均以此条为准降级为待证。**

分辨方法（两行日志 + 一次运行，尚未做）：
`fillBailField` 打印 slot/obj/写入值；`task_init` 返回处打印 `anchor[6]` 及其 `+8`；
同时把 OSAL 环打印从 3 条改为全量 32 条 —— 看清 eventq_init 到 mutex_pend 之间归档做了什么。

### 2「预置 `anchor[9]` 能推进到 step 7」——**不成立，已收回**

毒化 `anchor[9]` 那次的结果是 **load access fault @ `mtval=0x18`、`mepc=0x4005f1c8`（`gvLJK`）**，
而 `gvLJK` 在 deinit 的调用序列里排在 `FzF1`（`0x4005fa8c`）**之前**（`0x4005fa7a` / `0x4005fa82`）。

⇒ 毒化并不是"推进更远"，而是**把故障挪到了更早的一次解引用**。
cleanup 路径会连续解引用多个未初始化对象，补一个槽只换一个故障点。

⇒ 要拿到 step 7 的观测，必须**让 `task_init` 本身成功**（bail 不发生、rollback 不触发）。

`patch_bail_field` 已置回 `false`，实验代码与其结论一起保留。

### 证伪：「bail 判据是 `[obj+8]==0`」（2026-11-18，两种放置都试过）

在 `wr_btdm_osal_eventq_init` 里补写 `*(anchor[6]+8)`，两次实验：

| 放置 | 结果 |
| --- | --- |
| 在 `eventqInit(evq)` **之前** | `patch=applied`，崩溃不变 |
| 在 `eventqInit(evq)` **之后**（`evq` 就是 `obj+8`，会覆盖前者） | `patch=applied`，崩溃**仍不变** |

⇒ 填该字段**不改变**崩溃路径 ⇒ 那条 `lw a5,8(a5); beqz` **不是** task_init 提前退出的判据。
（此前基于该分支静态形态的推断，以本条为准作废。）

**但仍有一个强一致的事实**：OSAL 环 `n=3`（mutex_init / eventq_init / mutex_pend）——
说明 `eventq_init` 之后**没有**再发生分配，紧接着就是回滚路径里的 `mutex_pend`。
所以退出确实发生在 `eventq_init` 与下一次分配之间，只是**判据不是那个字段**。

**下一步（明确、单点）**：把 `OkE7…` 从 `0x4005f8d4`（`jal eventq_init`）到 `0x4005f8e0`
完整读一遍（现在 README 里只有片段），看 `beqz` 的目标 `.L40` 之后到底做什么 ——
是设置返回码为某个立即数、还是跳到别的检查。这段只有几十字节，离线即可，不用刷板。

`patch_bail_field` 已置回 `false`，两种放置方式与其结论都保留在代码注释里。

### 证伪 2：直接写 `evq` 形参的首字，崩溃不变（2026-11-18）

不再做地址推算，直接把归档传进来的 `evq`（`0x2f0155a0` = `obj+8`）首字写成有效指针：

```
bt patch: evq=0x2f0155a0 -> 0x2f012e98
!! mepc=0x4005b692 mtval=0x00000000        <- 崩溃与此前逐字节相同
```

⇒ 被检查的那个字**确实**非零了，崩溃仍然发生 ⇒ `0x4005f8dc` 的 `beqz` **不是**退出原因，
或者 `OkE7…` 的返回码根本不由这条路径决定。

另外确认：**我们的代码里没有调用 `r_btdm_task_deinit`**（`grep` 只有一处注释），
所以 deinit 确实由归档内部触发 —— 这条结论保留。

### 当前剩下的唯一形态

- 归档在 `eventq_init` 之后没有再分配（OSAL 环 n=3），随后进入 deinit → `FzF1` → 写 0；
- 但**让它退出的判据还未找到**：既不读那个字，也不在我们的调用链上。

**下一步仪器（已确定，未做）**：把 OSAL 环从"只记返回地址"扩展为**记 `a0/a1` 实参**。
若归档把 0 当指针传给我们（例如某个 `mutex_pend`/`eventq_get` 的槽参数为 0），
那条记录会直接指出第一个空指针是从哪次调用开始出现的 —— 这比继续猜判据更直接。

## 2026-11-18 复核：`0x2010B000` **仍然一读就挂**（总根因不变）

在 `probe.run()` 开头（任何 init 之前）加一次 `0x2010B000` 的读，板侧输出：

```text
bt probe: re-probing 0x2010B000 ...
（此后无任何输出：没有 `enter step 1`、没有 panic、没有中断）
```

⇒ README 前述"访问 BLE/MAC 寄存器块即总线挂起"的结论**仍然成立**，未因本轮其它改动而变化。
该实验已用开关 `reprobe_ble_block`（默认 `false`）保留。

### 与本次 store fault 的关系（归位）

本轮定位到的 `store access fault @ mtval=0` 有两种已知来源，二者都写地址 0：

1. **回滚路径**：`r_btdm_task_deinit` → `FzF1` → `*(anchor[9])==0` → `sb zero,0(a5)`（本轮实测）；
2. **`XPuq` 零填充**：`P = r_sym_bt_d3D3sk5KewclELfrD5xa` 未发布（唯一写者 `fqmZk`，被守卫挡着）
   ⇒ `a1 = P = NULL` 后 `sw zero,0(a1)`（仓库早先记录）。

⇒ 本次崩溃属于**那堵更大的墙的早期症状**：越过 -6 闸门会进 `fqmZk` → `XPuq` → 读 `0x2010B000` → **挂死**。
继续在锚点链上做板级实验，收益低于处理"BT 基带需要 modem 前端上电 + RF 校准"这一层。

⇒ 下一步应当是工程性决策，而不是继续调试：
- 要么在裸机上补出 modem 前端上电/校准能力（`esp_phy` 那一层），使 `0x2010B000` 可访问；
- 要么接受 BLE controller 在该板当前状态下不可用，把这一支从"待打通"降级为"依赖硬件前置"。

## 剩余工作已收敛为一件事：给 PHY 提供校准路径（2026-11-18 收敛）

前面几轮的结论汇合到这里：

| 已完成 | 事实 |
| --- | --- |
| `g_phyFuns` 表 | 调用 `phy_get_romfunc_addr()` 后**被填上**（`0x2f07f944`） |
| `esp_phy_enable(2)` | **正常返回**（ROM 函数，原先从没走到过） |
| 但 `0x2010B000` | **仍不应答总线**（本轮复核：一读即挂） |

⇒ 差的那一步是**校准**：`esp_phy_enable` 在 `s_is_phy_calibrated == false` 时会走
`esp_phy_load_cal_and_init()` → `esp_phy_load_cal_data_from_nvs()` → **`nvs_open(PHY_NAMESPACE)`**。

### 可执行方案（按顺序，每步都有唯一判据）

1. **给 NVS 提供最小实现**，只为 PHY 命名空间服务：
   - `nvs_open("phy", NVS_READONLY, &h)` → 返回 `ESP_ERR_NVS_NOT_FOUND`（**故意**，触发全量校准）；
   - `nvs_get_blob(...)` → 若被调用，返回 `ESP_ERR_NVS_NOT_FOUND`、长度置 0；
   - `nvs_close/erase_key/commit` → 空实现返回 `ESP_OK`。
   - **判据**：串口出现"校准开始"一类日志，或 `s_is_phy_calibrated` 变为 true，且**不再**在
     `nvs_open` 处返回错误码后直接跳过校准。
2. **确认走了全量校准分支**：`PHY_RF_CAL_FULL = 2`（仓库已记录该模式可用）；
   若代码在 `NOT_FOUND` 时回退到"跳过校准"，则改为返回"空数据但成功"，迫使它按全量校准初始化。
3. **验证块可访问**：用默认关闭的 `reprobe_ble_block` 开关再读一次 `0x2010B000`。
   - **判据**：能打印出 `0x2010B000 = 0x… (survived)` ⇒ 这堵墙破了，BLE controller 可以继续。
   - 若仍挂 ⇒ 校准不是唯一条件，需回到 `MODEM_PWR`/`MODEM_SYSCON` 的电源域使能序列逐位核对
     （仓库已有三轮寄存器对拍的记录可直接复用）。

### 为什么不再继续调锚点链

`anchor[9]`/`FzF1`/`-6` 闸门这些都是**同一堵墙的早期症状**：越过闸门只会更快撞到 `0x2010B000`。
先让块可访问，再回头处理 `task_init` 的发布顺序，才有观测价值。

## 新线索：`deinit` 的两个调用点与一个**魔数判据**（2026-11-18）

`r_btdm_task_deinit`（`0x4005fa4a`）在镜像里只有**两个**调用点，都在同一个函数体内：

```asm
4005fb2a: c.jal 4005fa4a <r_btdm_task_deinit>          # 调用点 1（前一函数的尾部）

4005fb2e <起始>:                                        # 调用点 2 所在函数
4005fb2e: addi16sp sp,-48
4005fb38: c.beqz a0, .L95           # a0 == 0 -> 走 .L95
4005fb3a: c.lw   a3,0(a0)           # a3 = *(a0)
4005fb3c: lui    a4,0x20260
4005fb40: addi   a4,a4,295          # a4 = 0x20260127
4005fb44: c.li   s0,-2
4005fb46: beq    a3,a4, .L103       # 魔数匹配 -> 继续
4005fb4a <.L93>: c.jal 4005fa4a     # 不匹配 -> deinit，返回 s0=-2
```

⇒ **回滚是由"某个对象首字 != `0x20260127`"触发的**，返回码 `-2`。

**但 `cfg.btdm.version` 本来就是对的**：`config.defaults()` 里显式写了
`.version = BTDM_CONFIG_VERSION`（`0x20260127`）。所以**失败的是另一个结构**
（首字应为该魔数的某个对象），不是 `btdm` 配置。

**下一步（离线优先）**：找 `0x4005fb2e` 这个函数的调用者与其 `a0` 的来源
（`objdump -d | grep 'jal.*4005fb2e'`），即可确定是哪个对象；
该对象若由我们构造（`ble` 配置 / anchor 对象 / `xi[]`），把首字补成 `0x20260127` 即可。

> 注意 `xi[6] = 0x20260127` 是**偏移 24**，不是首字，因此不是这个判据的对象。

## 回滚的三条条件已全部读出，且 `n=3` 不是有效判别器（2026-11-18 末）

`r_btdm_task_init`（`0x4005fb2e`，216 字节）里三条失败条件都汇到 `.L93`（`0x4005fb4a`）：

```asm
4005fb46: beq  a3,a4, .L103       # +0  version == 0x20260127
4005fb5a <.L103>:
4005fb60: addi a5,a5,1445         #     0x5a5aa5a5 = BTDM_CONFIG_MAGIC_VALUE
4005fb64: bne  a4,a5, .L93        # +16 magic  不匹配 -> deinit
4005fb68: c.jal 4005f860 <OkE7>   #     惰性初始化那个对象
4005fb6c: c.bnez a0, .L93         # OkE7 返回非零 -> deinit（rc=-3）
```

`config.defaults()` 里 **version 与 magic 都已正确设置**（`config.zig:275` / `:284`），
所以前两条通过 ⇒ **实际回滚来自第三条：`OkE7` 返回非零**（即 `OkE7` 内部的 -4/-6 之一）。

`callframe +12 = 0x4005fb4c` 只能证明"从 `.L93` 回来"，三条分支的返回地址相同，**无法区分**。

### 重要修正：`osaldump reached n=3` 不能当判别器

我此前用"打补丁后 n 仍为 3"推断"流程没越过闸门"，**这个推断无效**：
`noteCaller()` 目前只加在 **15 个**包装层（`eventq_*`/`event_*`/`sem_*`/`mutex_*`/`task_create`），
**`wr_btdm_osal_malloc` 没有插桩**，而 `OkE7` 之后的 `fqmZk` 正是靠 `malloc` 发布 `d3D3`
⇒ 越过闸门也**不会**让 n 增加。

⇒ 因此"补丁写 `evq` 首字无效"这一结论**未定**，需要先用带 `malloc` 的完整环重做判别。

**下一步（唯一，且明确）**：
1. 给**所有** `export fn wr_btdm_osal_*` 补 `noteCaller()`（本轮批量编辑失败已回退，需逐个手工加）；
2. 重跑基线，记录 n 与最后几条 RA，确认 `OkE7` 返回前的完整序列；
3. 再重跑 `patch_bail_field=true`，看 n 是否增加、故障点是否移动 —— 那才是有效判别。

## 反转：`evq` 补丁**确实越过了闸门**（2026-11-18 最终判读）

关键在返回码的来源，而不是返回码本身：

```asm
4005fb68: c.jal 4005f860 <OkE7>      # OkE7 内部：mutex_init -> eventq_init -> 检查 -> fqmZk
4005fb6a: c.li  s0,-3                # task_init 把"OkE7 非零"统一映射成 -3
4005fb6c: c.bnez a0, .L93
```

⇒ **`s0 = -3` 只表示"`OkE7` 返回非零"，不表示"闸门失败"**。
`OkE7` 越过闸门后会继续调 `fqmZk`（`0x4005f3a6`），`fqmZk` 的返回值同样走这条 `-3`。

实测对照（`bt ret:` 已改为不受 `trace_hooks` 过滤）：

| 运行 | 钩子返回 | 补丁 | 保存的 s0 | 判读 |
| --- | --- | --- | --- | --- |
| 基线 | `mutex_init => 0`、`eventq_init done` | 关 | `-3` | 闸门失败（`*(obj+8)==0`） |
| 打过补丁 | 同上 | **`evq -> 0x2f012e98`** | **`-3`** | 闸门已过，`-3` 来自 `fqmZk` |

⇒ **此前"补丁无效"的结论作废**：崩溃签名不变，是因为**下一段回滚路径（`lap6` → `deinit`）完全相同**，
不是补丁没生效。这也是本会话里唯一一次"实验看起来失败、实际成功"的情形 ——
判别器必须是**返回值来源**，而不是"崩溃是否消失"。

**当前状态因此是**：`task_init` 已能越过 `-6` 闸门，失败点推进到 `fqmZk` 内部。
`fqmZk` 正是发布 `d3D3`（`Xpuq` 零填充要用的 `P`）的那个函数 ——
与 README 早先"越过闸门 → `XPuq` → 读 `0x2010B000` → 挂"的记录**首尾相接**。

**下一步**：把 `noteCaller()` 补到 `wr_btdm_osal_malloc/free`（逐行插入，避免上次的跨行正则事故），
重跑即可看到 `fqmZk` 是否成功分配、以及它之后第一个失败点。

## 闸门已过：`fqmZk` 成功发布 `d3D3`，失败点在其后的分级检查（2026-11-18 收尾）

补丁生效后 OSAL 环由 3 条变 **5 条**，完整序列（全部解析到归档自己的代码）：

| # | 归档返回地址 | 所在函数 | 说明 |
| --- | --- | --- | --- |
| 1 | `0x4005f892` | `OkE7…` | 惰性发布 `malloc` |
| 2 | `0x4005f8ca` | `OkE7…` | `mutex_init`（实测返回 0） |
| 3 | `0x4005f8d8` | `OkE7…` | `eventq_init` |
| 4 | `0x4005f3b2` | **`fqmZk…`** | **闸门之后才出现**（基线里没有） |
| 5 | `0x4005fa6c` | `r_btdm_task_deinit` | 回滚 |

`fqmZk` 本体是**成功**的：

```asm
4005f3aa: li   a0,8
4005f3ae: jal  ra,<wr_btdm_osal_malloc>   # malloc(8)
4005f3b2: lui  a5,0x2f010
4005f3b6: sw   a0,-32(a5)                 # 0x2f00ffe0 = d3D3(P) <- 发布
4005f3ba: beqz a0, .L70                   # 失败才跳
4005f3bc: sw   zero,0(a0)                 # 初始化链表
4005f3c0: sw   a0,4(a0)
4005f3c2: li   a0,0                       # 返回 0
```

⇒ **`P`（`Xpuq` 零填充用的 `d3D3`）已被正确发布**，`anchor[4]` 非零与早先板级 dump 一致。

失败点因此在其后的多级检查（各有独立返回码，`task_init` 统一映射为 `-3`）：

```asm
4005f8f0: li s2,-9  ; bnez a0,.L40                 # -9 级
4005f900: jal 4005b56c <PsB8qxrZXPdSUAqQMBRY> ; li s2,-10 ; bnez a0,.L40
4005f906: jal 4006090c <ZGgifdtgyUnZ7f0ME7VH> ; li s2,-11 ; bnez a0,.L40
```

且这两个函数**没有任何 OSAL 调用**（环里 `fqmZk` 之后直接是 `deinit`）⇒ 它们快速返回了非零。

**下一步（离线，两步）**：
1. 反汇编 `0x4005f8de..0x4005f8f0`，看 `-9` 那一级检查的是什么；
2. 反汇编 `PsB8…(0x4005b56c)` 与 `ZGgi…(0x4006090c)` 的入口，看它们的首个条件分支读哪个字段 ——
   这两个函数都很短，且不碰 OSAL，属于纯数据检查，比继续追回滚路径便宜得多。

## 🎯 回滚根因：**我们自己**预发布了 `anchor[8]`，害得归档 `JwHs` 短路返回 2（2026-11-18）

`OkE7` 在 `fqmZk` 之后的分级检查（`-8` 级）调 `JwHs`（`0x40060704`）：

```asm
4006070c: addi s0,s0,-16      # s0 = 0x2f00fff0 = anchor[8] (r_sym_bt_6Q68KSwuQQP4VjQGqiWa)
40060710: lw   a4,0(s0)       # a4 = *(anchor[8])
40060714: li   a5,2
40060716: beqz a4, .L68       # 0 -> malloc(36) 正常路径
40060718 <.L62>: ...          # 非零 -> 直接返回 a5 = 2（"已初始化"）
```

而 **bringup 一直把 `anchor[8]` 预发布成非零**（开关 `publish_bohff_anchor`，默认 `true`），
注释理由是"只发布 21.o 时 `r_sym_bt_BOhff` 会早退"—— **那个理由不成立**：
`JwHs` 看到非零返回 2，`OkE7` 把非零当失败 ⇒ `task_init` 记为 `-3` ⇒ 回滚 ⇒ `deinit` ⇒ `FzF1` 写 0。

### 对照实验（同一镜像，仅改这一个开关）

| 运行 | OSAL 序列 | 结果 |
| --- | --- | --- |
| `publish_bohff_anchor=true`（旧默认） | malloc(76) → mutex_init → eventq_init → malloc(8) → **deinit** | 回滚崩溃（`store fault @0`） |
| `publish_bohff_anchor=false` | 同上 + **malloc(36)** + malloc(32) + 12 + 12 + …（共 **15 次** malloc） | **无 fault、无 panic** |

⇒ 关掉预发布后归档真的在初始化，最后**停在 `0x2010B000` 的总线挂起**上（45 s 无输出、无异常，
与 README 前述"读该块即挂死"的签名一致）—— 也就是**到达了真正的硬件墙**。

### 结论

1. `store fault @0` / `deinit` 回滚**不是归档的缺陷**，而是我们**错误的预发布**造成的；
   `publish_bohff_anchor` 默认已改为 **`false`**。
2. 归档现在能跑到 `task_init` 深处（15 次分配），剩余唯一障碍是 **modem 前端不可访问**
   （需要 PHY 校准路径，见上一节的工作量表）。

## ⚠️ 更正：挂住的最后一句话是 `mutex_pend`，**不是** modem 墙（2026-11-18）

去掉 `anchor[8]` 预发布后，抓取 40 s 的最后几行：

```
bt ret: malloc(8) => 0x2f015a18
bt call: mutex_pend            <- 最后一条，此后无输出、无 fault、无 panic
task_create 次数: 0
```

⇒ 归档**阻塞在我们自己的 `wr_btdm_osal_mutex_pend` 里**，且**从未调用 `task_create`**。

所以此前"到达 `0x2010B000` 硬件墙"的判读**不成立**（那需要证明它真的读了该块，本轮没有证据）。
当前障碍是**我们这一侧的阻塞语义**：归档等在某个 mutex 上，而能释放它的任务根本还没被创建。

**下一步（明确）**：给 `mutex_pend` 也打上"锁地址 + 当前持有者"日志，
并对锁的持有者做一次反查（谁 `mutex_init` 了这把锁、谁应该 `release`）——
若持有者不存在（`task_create` 为 0），则是**初始化顺序问题**：
归档在启任务之前就先 pend，需要一个不阻塞的实现（例如返回 `TIMEOUT`/`OK` 的降级语义）。

## `mutex_pend` 成功返回，静默发生在它**之后**（2026-11-18）

给 pend 加了入口/返回两条 `logPublic` 后：

```
bt ret: malloc(8) => 0x2f015a18
bt call: mutex_pend slot=0x2f01553c tmo=4294967295
bt ret: mutex_pend => 0            <- 成功，未超时、无死锁
（此后无输出）
```

⇒ 排除"死锁在自己锁上"：锁是空闲的，pend 立即成功。
⇒ **静默发生在 pend 返回之后**的归档代码里，且此后不再有任何 OSAL 调用。

**判读**：这段代码不经过我们的钩子，所以"没有输出"是**正常现象**，不能据此判断挂在哪。
要区分"总线挂起"与"纯 CPU 死循环"，必须用**采样器**（`trap` 的 T0 采样）：
- 若中断仍在触发、采样 PC 稳定在某个地址 ⇒ 纯死循环（可离线定位）；
- 若采样也停止 ⇒ 总线挂起（与 `0x2010B000` 同类）。

这正是仓库已有的 `s31-baremetal-irq-pc-sampler` 的用途，也是唯一还未用于此处的仪器。

## 交接设计：ISR 侧存活探针（唯一未做的仪器）

现状：所有 `bt ret:` 都在归档**主动调用我们**时才出现；静默期里归档不调 OSAL ⇒ 无输出是正常的。
要判断"CPU 还在跑"还是"总线挂死"，必须让**定时器 ISR 自己打印**。

### 设计（最小改动）

1. `osal.noteCaller()` 里增加 `pub var last_hook: u32 = 0;`（写当前钩子编号）+ `last_hook_n: u32`；
2. `trap` 的 T0 ISR 里，每 **N 次** tick（例如 5000 次 ≈ 10 s @2 ms）打印一行：
   `logPublic("alive: hook={d} n={d} pc=0x{x}", ...)`，`pc` 取 `mepc` 实参；
3. 判读分两支：
   - **ISR 持续打印** ⇒ CPU 活着 ⇒ 看 `hook/last_hook` 与 `pc`，多落点在归档某函数 ⇒ 纯自旋（可离线定位）；
   - **ISR 也停了** ⇒ 中断不再投递 ⇒ 总线挂死（与 `0x2010B000` 同族）。

### 必需的开关状态（当前镜像已是这样）

| 开关 | 值 | 原因 |
| --- | --- | --- |
| `publish_bohff_anchor` | `false` | 预发布会令 `JwHs` 短路返回 2 ⇒ 回滚 |
| `patch_bail_field` | `false` | 会覆盖 `eventqInit` 写入的真实 `slot.p` |
| `reprobe_ble_block` | `false` | 读 `0x2010B000` 会挂死系统 |
| `sample_quiet` | `true` | 防止自身打印占满采样槽 |

### 已知未覆盖点

其余 wrapper 的 `logLine` 在 step 6 的 `trace_hooks=false` 下**全部被过滤**
（`event_init`/`sem_*`/`free`/`eventq_put`/`wr_btdm_assert`…）⇒ 静默期里**可能还有 OSAL 调用**。
上面第 1 条（`last_hook`）正是为了在不依赖日志的情况下也能看到"最后一次调用了谁"。

## ✅ 存活探针结果：**CPU 活着**，空转在我们的 `probe.logHook`（2026-11-18）

把 step 6 的 `sample_quiet` 放开（`false`）后，静默期 ISR 仍在滚动：**32 条**采样。

采样分布：

```
20 × pc=0x4006a578   probe.logHook
 7 × pc=0x40069636
 5 × pc=0x4006a582   probe.logHook
 4 × pc=0x40069638
 3 × pc=0x4006a576   probe.logHook
```

⇒ **不是总线挂死**（ISR 一直在跑，`0x2010B000` 那条墙的"连中断都停"签名**没有**出现）。
⇒ CPU 在归档**大量调用我们的 printf 桥**时，于 UART 自旋里度过绝大部分时间。

**这同时推翻了 README 早先"printf 桥输出 0 行 ⇒ 让它自报进度走不通"的结论**：
归档**确实**在打印，只是（很可能）内容被 `verbose` 过滤掉或格式不被我们的最小 `%` 解析器支持。

### 下一步（一次改动、两分判别）

把 `probe.logHook` 改为**计数但不写 UART**（保留一个 `log_hook_calls` 计数器，周期打印一次）：

- 若归档随后**推进**（出现新的 `bt ret:` 或 step 7）⇒ 我们的 UART 自旋就是瓶颈，归档是在"打印中"被拖死；
- 若归档**换地方自旋**（采样落到别的地址）⇒ 归档自己在紧张地打日志，说明它认为出了错，
  这时应把 `verbose` 打开或放宽 `%` 解析器，让它的错误文本真的输出 —— 那就直接是答案。

## ⚠️ 撤回：「归档在大量打印」——证据不支持（2026-11-18）

放开 `sample_quiet` + 把 ISR 长行限流到每 256 tick 后重跑：

- 采样**仍然**落在 `probe.logHook`（`0x4006a578`）；
- 但全文检索**没有一行归档文本**：`grep -av 'bt ret:|bt call:|bt bringup:|irq-sample|pcsample|^s=|panic:'`
  剩下的 281 行全是**我们自己行的 UART 交错残片**（如 `bt res=384 pc=…` 是 `bt ret:` 与 `s=384 pc=` 拼接）。

⇒ 采样落在 `logHook` 的原因是**我们自己的日志（`logPublic` → 归档的 `.log` 钩子）也走同一个桥**，
不是归档在打印。此前"归档在大量打印/在两分判别"的结论**作废**。

### 现在的可信陈述（收窄到这一条）

> 归档在 `mutex_pend slot=0x2f01553c tmo=FOREVER` **成功返回 0** 之后，**不再调用任何 OSAL 导出**；
> 它在这之后是自旋、还是在访问某块挂死的寄存器，**当前仪器无法区分**——
> 因为采样器自身的输出也走那条被灌满的 UART 路径。

### 下一步（唯一，且已明确）

`logHook` 改为**计数不打印**（保留 `recordLogCaller(@returnAddress())`，`:107`）：

- 采样若**从 `logHook` 移开**并落到归档地址 ⇒ 归档在自旋，`addr2line` 直接点名；
- 采样若仍停在别处或消失 ⇒ 再看是总线挂死还是我们另一处忙等。

注意保留调用者环：no-op 之后 "谁在调打印" 仍是关键证据（环里已有的 5 条 RA 可离线解析）。

## logHook 静音对照：**会连我们自己的进度日志一起静音**（2026-11-18）

`log_hook_silent = true` 重跑的结果：

- `bt ret: malloc` 行数 **0** —— `logPublic` 也走同一个 `.log` 钩子，所以进度输出一并消失；
- 仍能从 ISR 读到有价值的一条：`irq-sample#0 in=25 mepc=0x4006c62a … s0=0x2f015540 ra=0x4005f8d8`
  ⇒ `ra=0x4005f8d8` 是 `OkE7` 里 `eventq_init` 的**返回地址**，说明归档当时正在我们的
  `wr_btdm_osal_eventq_init` 内部或紧邻处；
- 另有三条采样落在 **ROM（`0x2f8036ce`）**。

⇒ 这个对照**不能**用"整体静音"来做：归档与我们共用同一个日志桥。
默认已恢复 `false`，计数器（`log_hook_calls`）保留，供将来做"只统计不打印、由 ISR 报数"的变体。

**正确的下一步**：静音只作用于**归档来源**的消息（`recordLogCaller` 得到的 RA 落在 `0x4006xxxx` 之外
或带 `osal> ` 前缀），我们自己的 `bt ret:` 保持输出；配合 ISR 周期报 `log_hook_calls`，
即可同时保住进度与"归档是否在疯狂打印"的判据。

## 🎯 确定：卡住是**我们自己的 UART 饱和**（2026-11-18，证据闭合）

按来源分流（只放行 `"bt "` 开头的自身行）后重跑，抓到的关键几行：

```
s=192 pc=0x2f8036ce            <- ROM 的外设轮询助手
s=256 pc=0x2f8036ce            <- 同上（同一个外设，一直在轮询）
irq#0 in=25 mepc=0x4006a504 … a0=0x2038a000 a1=0x1 … ra=0x4006a4d6
```

- `0x2038a000` 是 **UART 基址**（`UART_FIFO`），`a1=1` ⇒ 正在等 UART 发送；
- `mepc=0x4006a504` 解析为 **`probe.logHook`**；
- `s=` 心跳停在 **512** 后不再增长 ⇒ **连定时器 ISR 的短行也排不进 FIFO**。

⇒ **不是归档自旋、不是 `0x2010B000` 总线挂死，而是我们自己的日志输出把 UART 灌满**。
本板 TX FIFO 停在 128 且不排空（技能已记录），`logHook` 每字节约 5000 次自旋上限、满了丢字节；
当输出速率持续超过排空速率时，CPU 绝大部分时间耗在 UART 自旋里，ISR 也被堵住。

**这同时解释了此前所有"静默"与"采样全在 logHook"的现象**，而它们曾被误读为
"归档在疯狂打印""总线挂死""到达 modem 墙"。

### 修法（下一步，明确）

1. 把 `bt ret: malloc(...)` 这类逐调用日志改为**里程碑级**（只留步进与失败），或加"前 N 条"上限；
2. `logHook` 的自旋上限从 5000 降到几十，**宁可丢字节也不让 CPU 停在 UART**；
3. 重跑：预期归档继续推进（此前 15 次分配之后本应还有更多），届时才是真正的下一步障碍。

## 自旋上限从 5000 降到 40 后的结果：CPU 不再被 UART 停住，但**输出被丢弃**（2026-11-18）

改动：`logHook` 的每字节等待上限 `5000 → 40`（满了立即丢字节，`'\n'` 同理）。

重跑结果：

| 观测 | 值 |
| --- | --- |
| `bt ret: malloc` 行 | **0** |
| ISR 行（`s=`/`irq#`） | 5 |
| 采样计数 | 到 `s=320` |

⇒ CPU 不再停在 UART（这是好事），但**日志几乎全被丢弃** ⇒ 无法从串口判断进度。

**结论**：本板 TX FIFO 停在不排空的状态，**串口不是可靠观测通道**。
继续用它做判据只会得到"看起来沉默"的假象（本会话已因此误判多次）。

### 正确的观测方式（两条，选一）

1. **RAM 环形日志**：`logHook` 只把消息拷进一块 `[64][128]u8` 的 RAM 环（不碰 UART），
   由定时器 ISR 每 N 秒把**最新一条**用短行（< 60 B）打出来 —— 短行能挤进 FIFO；
2. **纯计数器 + ISR 报数**：`logHook` 只累加计数（`log_hook_ours/other`），
   ISR 每 64 tick 打一行 `lc=ours/other`（约 20 B）——
   一次运行即可判定"归档是否在我们看不见的地方反复打印"（`other` 远大于 `ours` ⇒ 是）。

两种都应在 `spin` 上限 40 的前提下做，避免再次把 CPU 停住。

## 归因要分层（2026-11-18 最终）

本会话的"卡住"其实是**两个不同现象**，不能合并成一条结论：

| 层 | 现象 | 证据 | 结论 |
| --- | --- | --- | --- |
| ① 早期"静默" | 日志看似停止 | `irq#0 … a0=0x2038a000 a1=1`（UART 基址 + 发送忙） | **我们自己的 UART 饱和**，CPU 停在 `logHook` 自旋 |
| ② 自旋降到 40 之后 | 心跳停在 `s=320`、此后无任何 ISR 行 | 此时 CPU 已不可能停在 UART（自旋 40 会丢字节而非等待） | **中断停摆** —— 与 `XPuq`/`0x2010B000` 总线挂死同签名 |

⇒ `2006b5e` 里"卡住＝我们自己的 UART 饱和"**只解释第①层**，不能外推到第②层。

### 故意 panic 导出仪器（已实现，但本轮未触发）

- `board.trap.probe_stop_at_tick`：ISR 在指定 tick 处 `@panic("probe: deliberate stop")`；
- `trap.extra_dump` 已在 probe 侧注册，panic 时会打印
  `panic: lc ours=… other=… total=…`（两个计数器）与锚点表、OSAL 环；
- 本轮设 `tick=200` **仍未看到 panic** ⇒ 说明 ISR 在 200 tick 之前就已停摆，
  与第②层的"中断死"判读一致（**缺输出 ≠ 没发生**这条仍然适用，但此处是"没触发"而非"被丢"）。

### 下一步（优先顺序）

1. **RAM 环形日志**（优于纯计数器）：`logHook` 只把消息拷进 RAM 环，由 ISR 打最新一条短行；
   这样能捞出**归档自己的文本**（它很可能正在喊失败原因），而不只是"是否在调"；
2. 若确认第②层为总线挂死，则回到 PHY 校准路径那条工程决策（README 已有工作量表）。

## RAM 环形日志已落地；归档其实**极少打印**（2026-11-18）

实现（`probe.zig` + `trap.zig`）：

- `log_ring: [32][60]u8` + `log_ring_n`；`logHook` 里**归档来源**的消息（非 `"bt "` 开头）
  只 `ringPush`，不写 UART；
- `trap.ring_at` 由 probe 注册（跨模块不能 import），ISR 每 64 tick 吐一条 `arch: {s}` 短行。

板上 30 s 结果：

```
arch 行数: 1
arch: …win: clkrst +0x03c = 0x0000000f      （内容仍是我们自己的 lp 里程碑残片）
```

⇒ **归档几乎不打印**（30 秒只有 1 条进环），真正把 UART 灌满的是**我们自己的里程碑日志**。
⇒ 此前"归档在疯狂打印"的推测，现在有了 RAM 环这个不依赖 UART 的旁证，可以**正式排除**。

### 下一步（收敛到两件事）

1. **减少我们自己的日志量**（`bt lp:`/`bt bringup:` 里程碑过密），或把里程碑也走 RAM 环、
   由 ISR 限速吐出 —— 这是让串口恢复可用的前提；
2. 串口可用后，用 `probe_stop_at_tick` + `extra_dump` 导出计数器与采样，
   判定第②层（中断停摆）是否即总线挂死。

### 更正：上一节「归档几乎不打印」→ 改为「窗口内计数为 0，量未知」

心跳里加上实时计数后（`lr` = 环写入次数，`lc` = `logHook` 调用次数）：

```
s=128 pc=0x2f8036ce lr=0 lc=2
s=192 pc=0x2f8036cc lr=0 lc=2
s=256 pc=0x2f8036cc lr=0 lc=2
s=320 pc=0x40069654 lr=0 lc=2
```

两条硬事实与一条限定：

| 事实 | 说明 |
| --- | --- |
| `lr = 0` | **环形缓冲写入 0 次** ⇒ 窗口内没有任何"非 `bt ` 前缀"的消息被记录 |
| `lc = 2` | `logHook` 总共只被调用 **2 次** ⇒ 窗口内两侧都几乎没打印 |
| 心跳停在 `s=320` | 观测窗口只有 ~0.3–0.6 s，之后中断停摆 ⇒ **无法据此断言归档的打印总量** |

**另有分类缺陷**：分流用的是 `startsWith("bt ")`，而 bringup 里存在不带 `bt ` 前缀的**我们自己的**行
（如 `win: clkrst +0x03c = …`）⇒ 它们被误记为"归档来源"并进了环。
因此**当前环非空也不等于归档在打印**。

⇒ 正确表述：**窗口内归档既有计数为 0，但窗口太短、且分流规则有污染，量仍属"未知"**。
（"缺输出 ≠ 没发生"是本会话代价最高的一条，此处必须遵守。）

**下个会话的两个精确修法**：
1. 分流改为按 `recordLogCaller` 得到的 **RA 地址段**（归档 `0x4005xxxx` vs 我们 `0x4006xxxx`），不再用前缀；
2. 心跳一次吐 **2–4 条**环条目（而不是 1 条），赶在 stall 之前把 32 条倒完。

## ✅ 受控确认：心跳在 `s320` 停止，**与 UART 无关**（2026-11-18 收尾）

把心跳改成**极短行**（`s<count>.<ring>.<logc>`，约 12 字节）并保持每 64 tick 一条：

```
s128.0.2
s192.0.2
s256.0.2
s320.0.2        <- 之后再也没有
```

- 5 条 × 12 B ≈ **60 字节**，远低于 128 B FIFO ⇒ **不可能是 UART 饱和**；
- `lr=0`（环写入 0）、`lc=2`（logHook 仅 2 次）⇒ 窗口内两侧都几乎没输出；
- 而 512 tick 间隔**从未出现**（`irq_count` 根本没到 512）。

⇒ **中断在约 320 tick 后停止投递**（step 6 窗口的  ⇒ 约 **32 ms**，不是 0.64 s），这是第②层的受控证据：
在有意的 UART 减压下依然成立 ⇒ 指向**总线/中断源停摆**（与 `0x2010B000` 同族），
而不是我们的日志。

### 仍未能确定的部分（如实）

- 归档在该窗口内**是否真在读 `0x2010B000`**，尚未直接观测到（需要更长的窗口或硬件侧证据）；
- 因此"第②层 = 那堵 modem 墙"仍是**强推断**，不是定论。

### 下个会话的入口

1. 把 `probe_stop_at_tick` 设到 **300**（赶在停摆之前）触发故意 panic，导出计数器/环/采样 ——
   本轮此前设 200 未触发，需先确认 `irq_count` 的实际起点（可能被 `resetPcs` 清零）；
2. 或用**不依赖中断**的观测：在归档执行期间由一个已知的外设定时器/DMA 记录，事后读取。

## ✅ MPIE=1：中断停摆**不是**归档屏蔽中断造成的（2026-11-18 收尾）

心跳末尾加上 MPIE（`mstatus` bit7，进入 trap 前的中断使能）：

```
s128.0.2.1
s192.0.2.1
s256.0.2.1
s320.0.2.1      <- 之后停止；MPIE 恒为 1
```

⇒ **进入 trap 前中断是开的** ⇒ 归档**没有**在自己的临界区里屏蔽中断。
⇒ 中断在 ~320 tick（≈ **32 ms**，因 step 6 用 100 µs 周期）之后不再投递，
   在"中断本应开"的前提下发生 ⇒ 指向**中断源/总线侧停摆**，而非软件屏蔽。

### 量纲更正

`sample_period_us` 在 step 6 被设为 **100 µs**，所以 `s320` ≈ **32 ms**（此前文中按 2000 µs 写成 0.64 s，已改正）。
⇒ 15 次 malloc + `mutex_pend` 全部发生在这 32 ms 内，归档推进得其实很快。

### 仍未直接观测到的

归档在这 32 ms 内**是否访问了 `0x2010B000`**。要拿到这一点，仍需不依赖中断的观测手段
（外设计时器/DMA 记录后事后读取），或把 `probe_stop_at_tick` 设在 **300** 并**绕过 `@panic`**
（在 ISR 里直接调 `trap.extra_dump.?()` 再停机 —— Zig 的 panic 路径在中断上下文里本身可能挂住，
这解释了此前设 200 却未触发）。

## 无 panic 导出：已实现但**未触发**（2026-11-18 最后一步）

实现：心跳分支之前加

```zig
if (probe_stop_at_tick != 0 and irq_count >= probe_stop_at_tick) {
    log.line("DUMP {d}", .{irq_count});
    if (extra_dump) |f| f();
    while (true) asm volatile ("wfi");
}
```

`probe_stop_at_tick = 300`，而心跳实测能到 `s320` ⇒ 条件本应成立，但串口**没有任何 `DUMP` 行**。

⇒ 两种可能，尚未区分：
1. 心跳的 `s320` 与 `irq_count` **不是同一计数**（`resetPcs()` 可能清零 `irq_count`，
   而心跳读的是清零后的值），导致 `>= 300` 永远不成立；
2. 该分支在到达 300 之前就不再执行（与"中断停摆"一致）。

**下个会话第一件事**：把 `irq_count` 的**清零点**与心跳计数基准一次性查清
（`grep -n "irq_count = 0" trap.zig`），并让 `probe_stop_at_tick` 与心跳**读同一个变量**。
在这一点澄清之前，`s320` 与 `tick=300` 这两个数字的基准都不可信 —— 这是本会话第三次踩"基准不明"的坑
（前两次：`n=3` 的 OSAL 计数、`mepc` 的精度）。

## ✅ 导出成功：`lc=114 / lr=67 / n=21`（2026-11-18 收尾）

改成**事件触发**（`osal.dump_hook` 在 `mutex_pend` 返回处调用，打印后停机）加上 tick 触发后，
串口首次拿到完整计数：

```
DUMP lc=114 lr=67 n=21
DUMP300
```

| 计数 | 值 | 含义 |
| --- | --- | --- |
| `lc`（logHook 调用） | **114** | 日志桥确实被调了 114 次 |
| `lr`（环写入） | **67** | **有 67 条消息进了 RAM 环** —— 此前只看到 0/1，是**导出被丢弃**造成的假象 |
| `n`（OSAL 调用者环） | **21** | 归档实际调了我们 **21 次** OSAL（插桩 malloc/free 后），远多于早期的 3/5 |

⇒ **本会话反复出现的"只看到 1 条 / n=3"全部是丢弃或插桩不全造成的误读**，
真实量级要大得多。这也解释了为什么"归档几乎不打印"的结论一直站不住。

### 关键教训（本会话第三次同类）

> **一次性的关键输出必须解除限流**：`logHook` 的 40-spin 上限对常规日志是对的，
> 但导出时刻（离停摆还有 ~2 ms）应当允许长自旋，否则"导出了"与"没导出"在串口上完全一样。

### 下一步

按 `n=21` 逐条解析 OSAL 调用者环（`panic: osalcaller[]` 的导出路径已可用），
得到归档在 32 ms 内的**完整调用序列**，再对照 `lr=67` 的消息文本 ——
两条证据合起来足以回答"它走到了哪、在等什么"。

## ⚠️ 重大更正：我们的导出**自己 halt 了 task_init**（2026-11-18）

`task_init` 在 `OkE7` 返回 0 之后紧接着做：

```asm
4005fb84: jal  <wr_btdm_osal_mutex_pend>   # <- 我们的 dump_hook 在这里触发并 halt
4005fb88: lw   a5,0(s1)
4005fb8a: li   a4,1
4005fb8e: sb   a4,0(a5)                    # *(obj) = 1  <- 标记"初始化完成"
4005fb92: c.jal <r_sym_bt_2aNNQgpuVlZoKiS5xEYJ>
```

⇒ **`dumpAtPend` 里的 `while (true) wfi` 把归档中止在"标记完成"之前**。
也就是说：加上导出仪器之后的"32 ms 停摆"，**有一半是我们自己的 halt 造成的**。

已改成：只打印、不再停机（`dump_done` 一次性）。

### 去掉 halt 后的结果

```
DUMP lc=114 lr=67 n=21
C4005b5d4
Mosal> mutexPend tmo=4294967295
Mosal> eventInit            <- 环里最新一条：归档又调了 event_init
```

⇒ 归档确实**越过了 `mutex_pend`** 并继续调用（`event_init`），随后才静默。
⇒ 这修正了"停摆点"的位置：真正的静默发生在 `event_init` 之后，而不是 `mutex_pend` 处。

**下个会话**：从 `event_init` 这一步继续，看它在 `2aNNNgpu…` 之后做了什么；
并注意**任何一次性导出都不得 halt**，否则会把自己的观测点变成故障点。

## 静默点已推进到 `event_init` 一族之后（2026-11-18 最终）

`task_init` 在 pend 与就绪标记之后调用的 `r_sym_bt_2aNNQgpuVlZoKiS5xEYJ`（`0x4005f394`，18 字节）是：

```asm
4005f394: lui  a5,0x2f010
4005f398: lw   a5,-32(a5)   # a5 = *(0x2f00ffe0) = d3D3 (P)
4005f39c: sw   zero,0(a5)   # *(P) = 0
4005f3a0: c.sw a5,4(a5)     # *(P+4) = P   (链表头自环)
4005f3a2: c.jr ra           # 返回
```

⇒ **纯数据结构初始化，不访问任何外设** ⇒ 它不会撞 `0x2010B000`。

而环里最新的几条归档消息是：

```
Mosal> mutexPend tmo=4294967295
Mosal> eventInit
Mosal> eventInit
Mosal> eventInit
Mosal> eventqInit
Mwin: clkrst +0x03c = 0x0000000f
```

⇒ 归档在 pend 之后继续初始化了 eventq 与多个 event，**静默发生在这一族之后**。

### 这条线的准确状态

| 项 | 结论 |
| --- | --- |
| 回滚崩溃 | **已修**（预发布 `anchor[8]` 是自伤） |
| 归档推进深度 | 越过 `OkE7` 全部分级检查（`PsB8` / `ZGgi` / `jH5m`）→ `task_init` 的 pend → 就绪标记 → `eventqInit` + `eventInit`×3 |
| 静默点 | 在 `event_init` 一族**之后**，且**尚未观测到**它随后调用的确切函数 |
| 是否撞 `0x2010B000` | **仍未观测**（`2aNN` 已排除，后续未读） |

**下个会话入口**：把导出触发点改为 `event_init` 之后的第一个 OSAL 调用（或第 2 次 pend），
并用 **按字节预算** 的打印（1 行计数 + 3 条截断到 24 字节的 M 行 ≈ 101 B）——FIFO 只有 128 B，
否则又只能看到前几行。

## 量化终点：归档的 OSAL 调用数**止于 21**（2026-11-18 收尾）

把导出触发条件设为 `caller_n >= 22` 后，**从未触发**（串口无 `D`/`M` 行），
而此前 `>= 20` 时在 `n=21` 触发过一次。

⇒ **归档总共只调用我们 21 次 OSAL**，之后不再调用；同时中断在 ~320 tick 停摆。

### 这两条事实合起来说明什么（不含推测）

- 归档在 21 次 OSAL 调用后进入**不经过我们钩子**的代码；
- 同一时刻前后，定时器中断停止投递（`MPIE=1`，非软件屏蔽）；
- `2aNN…` 只是链表初始化，**不碰外设**，因此静默点不在此处，而在其后未读到的代码里。

### 若要继续（明确的两条路）

1. **不需要中断的观测**：把 PC 采样改由**归档调用 OSAL 时顺便记录**（我们已在 21 个钩子里有
   `noteCaller()`），把最后一次调用点的 RA 与当时的 `mepc` 一起存 RAM —— 已在做，量已拿到：
   序列为 `PsB8`×5 → `ZGgi` → `jH5m`×3 → `OkE7`×2 → `task_init`；
2. **读 `event_init` 之后的那段归档代码**：`objdump` `0x4005f394`（`2aNN`）返回后的调用点
   `0x4005fb92` 之后的控制流，逐段读到下一个 OSAL 调用或外设访问为止。

### 本次会话的最终判断

BLE controller 在我们的裸机 OS 上已经**跑过 `task_init` 的绝大部分**（21 次 OSAL、event/queue 建立、
就绪标记写入），剩余障碍位于**不经过钩子的归档代码 + 中断停摆**这一段；
`0x2010B000` 那堵硬件墙**既未被证实也未被排除**（`2aNN` 已排除，其后的路径未读）。

## 🎯 `task_init` 尾部读到了：它**在建任务**（2026-11-18 收尾）

`2aNN` 返回后，`task_init` 组装一个任务描述并调用建任务函数：

```asm
4005fb9e: li  a5,33                     # 优先级
4005fba6: li  a5,2000                   # 栈大小
4005fbaa: c.swsp a5,24(sp)
4005fbac: c.addi4spn a0,sp,20
4005fbb4: jal ra,40060772 <r_sym_bt_BOhffsuJp3HZRA44ZYRn>   # <- 建任务
4005fbb8: c.addi4spn a0,sp,12
4005fbbc: c.swsp zero,16(sp)
4005fbbe: jal ra,4005e98a <r_sym_bt_HGbPEa9oUCsYybIAWjE0>   # <- 其后
```

⇒ 归档**确实走到了"创建 controller 任务"这一步** —— 这比本会话此前任何一次推进都深
（此前 `task_create` 从未发生，现在代码路径已经到达它）。

### 与 OSAL 计数的交叉

OSAL 环止于 **21** 次，其中**没有 `task_create`**。两种可能（未区分）：

1. `BOhff` 内部走了不调用我们 `task_create` 的路径（例如它自己实现或被 GC 掉）；
2. `BOhff` 在调用 `task_create` **之前**就返回/失败。

**下一步（单点）**：反汇编 `r_sym_bt_BOhff…`（`0x40060772`），看它：
- 是否调用 `wr_btdm_osal_task_create`（若是，则它没被调用就说明前面的分支失败）；
- 它在调用前读了哪个锚点/字段 —— 那正是当前真正的闸门。

## 关键关系：`task_create` 在 **enable 步**，而我们还停在 init 步（2026-11-18 最终）

全镜像只有两处调用 `wr_btdm_osal_task_create`：

| 调用点 | 所在函数 |
| --- | --- |
| `0x4005fcaa` | **`r_btdm_task_enable`** |
| `0x40056744` | `r_sym_ble_UJ7ddLOv5tT0E1Sqkwfb`（BLE 侧） |

而 `bringup.zig` 的注释本就写着：**`r_btdm_task_enable` 在 enable 步、不在 init 步**。

⇒ 因此"OSAL 环里没有 `task_create`"**完全正常**，不是缺能力、也不是闸门被挡：
控制器任务本来就要到 **`enable()`** 才会被创建。

⇒ 当前真正的问题是：**`task_init`（step 6）没有返回**，所以我们从未走到 step 7 之后的 enable 步。
`task_init` 尾部（`0x4005fbb4`）调用 `r_sym_bt_BOhff`（建任务描述符：prio 33、stack 2000）
之后静默，而 `BOhff` 函数体内**没有任何对符号的调用** ⇒ 它要么纯数据操作，要么经寄存器间接调用。

**下一步（单点、离线）**：把 `0x40060772..0x40060870` 整段 `objdump` 出来逐条读
（约 250 字节），找出它返回前的最后一条 `jalr`/`jr` —— 那就是它跳去向的地方，
也即 `task_init` 卡住前的最后一步。

## 🏁 闭环：干净流程**走到了 `Xpuq`**，即 README 记录的硬件墙（2026-11-18 定论）

`task_init` 尾部（前面 `BOhff` 建描述符、`HGbPEa9` 写两个常量 40/46 之后）：

```asm
4005fbc4: jal ra,4005eb1e <r_sym_bt_XPuqTHliEO5V9xpR7aJR>   # <- 就是那个 XPuq
4005fbc8: c.bnez a0, .L93                                    # 失败则回滚
4005fbca: jal ra,4005baaa <r_sym_bt_AJP6s1I6EhaAHnz8n72F>
...
4005fc00: jal ra,<wr_btdm_osal_mutex_release>
```

而 README 早已记录 `Xpuq`（186 字节）的前半段是**固定 16 次循环**，按 16 字节步长访问
`0x2010B000..0x2010B100`，并且**读一次该地址即挂死整个系统**（2 行实验已证）。

⇒ **整条链闭合**：

```
task_init -> OkE7(全部分级通过) -> mutex_pend(0) -> 就绪标记 -> eventq/event 初始化
  -> BOhff(建任务描述符) -> HGbPEa9(写 40/46) -> XPuq -> 读 0x2010B000 -> 总线挂死
```

且这条路径是**干净的**：无 anchor[8] 预发布、无 bail 补丁、无导出 halt。
此前所有"卡住"的观测偏差（UART 饱和、导出丢弃、导出 halt）都已排除，
剩余的唯一障碍就是 **modem/BLE 寄存器块不可访问**。

### 与先前结论的关系

| 先前结论 | 现在 |
| --- | --- |
| "到达 modem 墙"（曾被我撤回，因无证据） | **重新成立，且有干净路径的调用点作证**：`0x4005fbc4` → `XPuq` |
| "卡在 mutex_pend / 死锁 / 阻塞语义" | 全部作废（pend 返回 0，流程继续到 `Xpuq`） |
| "anchor 链是闸门" | 全部作废（干净流程下无预发布也能走到 `Xpuq`） |

### 结论

**BLE controller 在我们裸机 OS 上的 init 已经跑到 `Xpuq`，剩余唯一障碍是
`0x2010B000`（`MODEM_BASE + 0xB000`，BLE/MAC 寄存器块）不可访问。**
要让流程继续，必须让该块可访问 —— 即 README 早已收敛的那件事：
**给 PHY 提供校准路径**（`nvs_open(PHY_NAMESPACE)` 返回 `ESP_ERR_NVS_NOT_FOUND`
⇒ 触发全量 RF 校准），以及 modem 域上电/复位释放的时序对齐。

### 闭环的最后一环已**离线验证**（2026-11-18）

`r_sym_bt_XPuqTHliEO5V9xpR7aJR`（`0x4005eb1e`）开头就是那段文档记录的循环：

```asm
4005eb2e: lui  a5,0x2010b        # 0x2010B000
4005eb32: sw   zero,0(a1)        # （另一路：清零外传结构）
4005eb3e: lui  a2,0xfff00        # 掩码 0xFFF00000
4005eb42: addi a3,a5,256         # 结束 0x2010B100
4005eb46 <.L547>:
4005eb46: c.lw   a4,0(a5)        # <-- 读 0x2010B000
4005eb48: c.addi a5,16
4005eb4a: c.and  a4,a2
4005eb4c: c.sw   a4,-16(a5)      # 写回
```

⇒ 与 README 早先记录的"固定 16 次循环、按 16 字节步长访问 `0x2010B000..0x2010B100`"**逐条吻合**。

⇒ **闭环成立，无需再刷板**：干净流程 → `task_init` → … → `XPuq` → 第一次 `c.lw 0x2010B000`
   → 该块不应答总线 → 全系统停摆。

**这就是最终答案**：软件侧已经推进到硬件边界，剩余工作 = PHY 校准路径 + modem 上电/复位时序
（两类工作都有独立的工作量记录，且**不在**本仓库的软件能力范围内可以绕开）。

## ⚠️ `WITH_PHY=1` + reprobe 的负结果**不成立**（2026-11-18 最后一条更正）

用 `WITH_PHY=1` 构建（镜像 811 520 B，IDF PHY 对象已链入）并把 `reprobe_ble_block` 打开后：

```
bt probe: re-probing 0x2010B000 ...
（此后无输出）
```

**但这个实验无效**：`reprobe_ble_block` 的读发生在 `probe.run()` **最开头**，
即在任何 `phy_get_romfunc_addr()` / `esp_phy_enable()` / 校准**之前**。
此刻 PHY 尚未使能，块当然不应答 —— 与"链入 PHY 对象是否有帮助"无关。

⇒ **正确做法**：把 reprobe 移到 PHY 使能/校准**之后**（例如 `pp.initPhy()` + `esp_phy_enable(2)`
返回之后立即读一次）。判据仍是同一条：能打印 `0x2010B000 = 0x… (survived)` 即为破壁。

开关已置回 `false`，避免下次误用这个无效位置。

## 已尝试组合矩阵（下会话**不要**重试）

| # | 组合 | 结果 | 说明 |
| --- | --- | --- | --- |
| 1 | 无 PHY（ROM `esp_phy_enable`）+ 前置 reprobe | 读 `0x2010B000` **挂死** | 探针在 bringup 之前，PHY 未使能 |
| 2 | `WITH_PHY=1`（IDF 7 对象链入）+ 前置 reprobe | 读 `0x2010B000` **仍挂死** | 同上：探针位置早于校准，**不构成对 WITH_PHY 的否证** |
| 3 | `publish_bohff_anchor=false`（干净 init） | init 推进到 `Xpuq` 后停 | **有效**，闭环证据 |

⇒ 组合 1/2 都因为**探针位置在 PHY 使能之前**而无判读力。**不要再跑前置探针**。

## 精确锚点（下会话直接用）

| 位置 | 内容 |
| --- | --- |
| `probe_ptr.zig:75-81` | PHY 使能链：`phy_get_romfunc_addr()` → `esp_phy_enable(2)` |
| `bringup.zig:133` | `pp.initPhy()` 的调用点 ⇒ **后置探针应插在这行之后** |
| `bringup.zig:169` | 已记录：给 IDF 7 个 PHY 对象时"**镜像会死在 bringup 之前**" |
| `porting.zig:284` | LPCON `clk_conf_power_st` 已写（`0x66660000`） |

## 下一步的正确顺序（唯一）

1. **先补时钟依赖**：在 `initPhy()` **之前**使能 PHY/LP 模块时钟，特别是 **`I2C_ANA_MST`**
   （PHY 寄存器走模拟 I2C 主控，我们从未使能；IDF 的 `modem_clock_module_enable(PERIPH_PHY_MODULE)` 就做这个）；
2. 再 `WITH_PHY=1` 构建，**看 `esp_phy_enable(2)` 能否返回**（技能记录该路径上次卡在 RF 校准/PMU 转储）；
3. 能返回 ⇒ 在 `bringup.zig:133` **之后**读一次 `0x2010B000`，判据：打印 `survived` 即破壁；
4. 不能返回 ⇒ 缺的是时钟/`I2C_ANA_MST` 依赖，不是校准数据，回到第 1 步逐项补齐。

**在完成第 1 步之前，任何 reprobe 结果都不具判读力。**

## 🔍 顺序倒置（2026-11-18 最后一条结构性发现）

`bringup.init()` 里的实际顺序：

```
:178  dumpBootState()      -> :133 pp.initPhy() -> phy_get_romfunc_addr() + esp_phy_enable(2)
:195  enter(4, btdm_coex_init)
:200  enter(5, btdm_lp_enable_clock) -> porting.btdmLpEnableClock()   <- BT/LP 模块时钟
```

⇒ **PHY 使能发生在 BT/LP 模块时钟使能之前**，与 IDF 的顺序（先
`modem_clock_module_enable(PERIPH_BT_MODULE)` / `PERIPH_BT_APB_MODULE`，再 `esp_phy_enable`）**相反**。

这为"给 IDF 7 个 PHY 对象后镜像死在 bringup 之前"提供了解释：
**PHY 在时钟未使能时被访问**，于是卡在它的 PMU 转储/RF 校准里。

### 下一轮的第一个动作（比改校准数据更可能见效）

把 `pp.initPhy()` 移到 **step 5（`btdmLpEnableClock`）之后**（或把 step 5 提到它之前），
再 `WITH_PHY=1` 构建，看 `esp_phy_enable(2)` 能否返回；
能返回则把后置 reprobe 插在它之后读 `0x2010B000`（判据：`survived`）。

这条改动只有**移动一处调用**，不需要新代码 —— 是本会话所有剩余选项里成本最低、判据最清晰的一个。

## 顺序修正后仍卡在 `initPhy()`（2026-11-18 最后一次板测）

把 `pp.initPhy()` 从 `dumpBootState()`（`:133`）移到 **step 5 `btdmLpEnableClock` 之后**
（新开关 `phy_before_clocks`，默认 `false` = 按 IDF 顺序），结果：

```
bt lp: … win: clkrst +0x03c = 0x0000000f      <- step 5 已执行
（没有 "bt bringup: PHY enabled AFTER step 5" 这一行）
```

⇒ **step 5 成功、随后 `initPhy()` 挂住**。

⇒ 说明"顺序倒置"不是唯一原因（甚至可能不是主要原因）：
**BT/LP 时钟已使能后，PHY 使能路径仍然卡死**。
与技能记录一致：该路径上次是在 PHY 内部打 PMU 转储/RF 校准处停住。

### 因此剩余工作收敛为一项（不再是两项）

**让 `esp_phy_enable` 在时钟已使能的条件下能返回。** 具体缺的仍是：
`I2C_ANA_MST`（PHY 寄存器走模拟 I2C 主控）—— `modem_clock_module_enable(PERIPH_PHY_MODULE)` 里
我们从未使能的那一步。补齐后再跑同样这一次，判据仍是那一行 `PHY enabled AFTER` 是否出现。

`phy_before_clocks` 开关保留（两种顺序都已实测），默认按 IDF 顺序。

## `WITH_PHY=1` 版在 **PMU 转储阶段**就停（2026-11-18 最后一次板测，条件已修正）

前一轮的两个污染已排除：镜像确认为 `WITH_PHY=1`（**811 216 B**，非 ROM 版的 798 672 B），
且 `probe_stop_at_tick = 0`（关闭，它此前从开机起算并 halt，吃掉了多轮实验）。

结果：

```
pmu+0x1dc = 0x028804b0
pmu+0x1e0 = 0x00000008
pmu+0x1e4 = 0x00000028
（此后无输出；`enter step` 行数 = 0）
```

⇒ **带 IDF PHY 对象的镜像在 `dumpBootState()` 的 PMU 转储阶段就停止，bringup 一步都没开始** ——
与 README 早先记录"给 IDF 7 个 PHY 对象时镜像会死在 bringup 之前"**完全一致**。

⇒ 因此"PHY 顺序"实验在 `WITH_PHY=1` 下**根本测不到**：流程到不了 step 5。
⇒ 上一轮"顺序修正后仍卡在 `initPhy()`"的结论**作废**（那轮测的是 ROM 版镜像，镜像号 798 672 B 已证）。

### 现在的真实边界（两条互斥的路径）

| 路径 | 现状 |
| --- | --- |
| **默认（ROM PHY）** | init 能跑到 `Xpuq`，卡在 `0x2010B000` 首读（已闭环验证） |
| **`WITH_PHY=1`（IDF PHY）** | 死在 PMU 转储阶段，连 bringup 都进不去 |

### 建议的下一步（更可控的一条）

**不要继续让 IDF PHY 在缺依赖的环境里自己跑**。仓库里已有在 S31 上跑通的 PHY 使能序列可直接移植：

- `components/wifi-blobs/src/init_probe.zig:688-696` = IDF `modem_clock_module_enable(PERIPH_PHY_MODULE)`
  的 S31 等价物（SOC_PLL_SOURCE_CG `0x2058_71E0←0x3d`；MODEM_ADC_COMMON_FE 的 FE_APB/FE_80M；
  MODEM_PRIVATE_FE 的 FE_160M/FE_DAC/FE_PWDET_ADC/FE_ADC）；
- `components/wifi-blobs/src/osi_impl.zig:1082-1106` 的 `shellPhyEnable` 给出完整顺序
  （ICG `0x2010_9C0C←0x64646400` → `phy_*_enable_set(1)` → `set_bb_wdg` → 首次 `register_chipv7_phy` → 重申 CLK_CONF1）。

把这一套搬进 BLE 的 `btdmLpEnableClock`/`initPhy`，比让 IDF PHY 自己跑可控得多。

## ✅ `WITH_PHY=1` 的真正阻塞是**诊断用的 PMU 转储**，不是 PHY（2026-11-19）

把 `probe.zig` 里那段纯诊断的 PMU 窗口 dump 用开关 `pmu_dump`（默认 **false**）关掉后，
`WITH_PHY=1`（811 024 B）**能够进入 bringup**：

```
pcsample n=256 pc=0x2f8036cc ra=0x40067798 s0=0x3
s256.0.2.1
bt anchors[before-phy]: 40f2ed8f 44d24462 …    <- dumpBootState 执行了
bt lp: …                                       <- step 5 执行了
（此后无输出）
```

⇒ 之前"给 IDF PHY 对象就死在 bringup 之前"的记录**不准确**：死在的是**我们自己加的诊断转储**，
它在 `0x207041E4` 附近停住；关掉它之后流程照常进入 step 4/5。

⇒ 现在的位置是：**step 5 成功之后调用 `initPhy()`（`WITH_PHY=1` 的 IDF PHY 使能）仍不返回**。
这才是 PHY 路径的真实门槛，与"顺序倒置"无关（顺序已按 IDF 修正）。

### 下一步（单点）

`initPhy()`（`probe_ptr.zig:75-81`：`phy_get_romfunc_addr()` → `esp_phy_enable(2)`）
在时钟已使能的条件下仍挂住 ⇒ 按技能记录，缺的是 PHY 寄存器所走的**模拟 I2C 主控（`I2C_ANA_MST`）**
以及 `MODEM_ADC_COMMON_FE` / `MODEM_PRIVATE_FE` / `SOC_PLL_SOURCE_CG` 这几路频域使能 ——
仓库里 `components/wifi-blobs/src/init_probe.zig`（`grep -n '0x2058_71E0'` / `grep -n 'PERIPH_PHY_MODULE'` 定位，**勿依赖行号**） 已有这些的 S31 实测值（`0x2058_71E0←0x3d` 等），
可直接移植到 `btdmLpEnableClock`。

## 🔴 定案：`WITH_PHY=1` 结构性损坏 —— `.iram_blobs` 覆盖锚点块（2026-11-19）

`readelf -S` 检查越过 `0x2f00ffd0` 的段：

```
OVERLAP .iram_blobs addr=0x2f0008b0 size=0xfd30 end=0x2f0105e0
```

⇒ `.iram_blobs`（`0x2f0008b0..0x2f0105e0`）**完全覆盖** 10 个 `r_sym_bt_*` 锚点所在的 `0x2f00ffd0..0x2f010000`。

⇒ 板上 `bt anchors[before-phy]: 40f2ed8f 44d24462 80826105 …` 全是指令编码字节 —— 与重叠完全吻合。

**因此**：
- `WITH_PHY=1` 路径的所有读数（含"卡在 `initPhy()`"）**都建立在一个被覆盖的镜像上，不可用**；
- 这印证了技能里记录的前置条件：**链 `libphy` 需要先扩两段镜像窗口（约 +140 KB）**，窗口从未扩过；
- 默认路径（ROM PHY）不受影响（其 `.iram_blobs` 不越界，锚点读出的是有效指针 `0x2f0155b8` 等）。

**下一步唯一有意义的工作**：扩窗（`s31.ld` 的两段 ORIGIN/LENGTH）→ 重新构 `WITH_PHY=1` →
确认锚点块不再被覆盖（`readelf` 无 OVERLAP + 板上 anchor dump 为有效指针）→ 再谈 PHY 频域使能。

## 可复用数据（扩窗后移植 PHY 时直接用，不必重新从 IDF ELF 抠）

| 需要的东西 | 现成位置 |
| --- | --- |
| `esp_phy_init_data_t`（128 字节初始化表） | `components/wifi-blobs/src/phy_init_data.zig`：`pub const params: [128]u8`（生成脚本 `scripts/gen-phy-init-data.py`） |
| 频域使能实测值（`SOC_PLL_SOURCE_CG` 等） | `components/wifi-blobs/src/init_probe.zig`（`grep -n '0x2058_71E0'` / `grep -n 'PERIPH_PHY_MODULE'` 定位，**勿依赖行号**）（`0x2058_71E0←0x3d`、CLK_CONF1 的 FE_* 位） |
| 完整 `esp_phy_enable` 顺序 | `components/wifi-blobs/src/osi_impl.zig:1082-1106`（`shellPhyEnable`） |
| NVS 桩 | 用 **BLE 自己的** `components/bt-blobs/link/phy_stubs.c`（返回 `ESP_ERR_NVS_NOT_FOUND` ⇒ 全量校准）；**不要**搬 wifi 的 `nvs_ram.zig` |
| 校准模式 | `PHY_RF_CAL_FULL = 2` |

**移植时的一个反向差异**：`init_probe.zig`（`grep -n '0x2010_F018'`） 把 `LPCON+0x18` 对正成 wifi 的 `0x1`
（清 bit2 `clk_i2c_mst_fo`）—— BLE 的 PHY 寄存器**正走模拟 I2C**，移植时**不要照抄这一句**，
应保持 bit2、只补缺失的模拟前端时钟。`0x201044EC |= 0x240` 是 wifi 专属修正，也不要一起搬。

## 扩窗的具体数字（下会话直接改）

`boards/esp32s31-coreboard/linker/s31.ld:49-51` 当前：

```ld
irom (rx)  : ORIGIN = 0x40000020, LENGTH = 0xB0000    // 720 KiB，末址 0x400B0020
drom (r)   : ORIGIN = 0x40100020, LENGTH = 0xB0000
sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
```

⇒ **`irom` 与 `drom` 之间有空档**：`irom` 从 `0x40000020` 起，`drom` 在 `0x40100020` 起，
中间还有 `0x50000`（320 KiB）未被任何段占用。
把 `irom` 的 `LENGTH` 从 `0xB0000` 提到 **`0x100000`（1 MiB）** 即可容纳 `libphy` 需要的 ~140 KB，
且**不移动 `drom` 的起点**（`0x40100020` 保持不变）。

改完必须同步：
1. 分区表里 app 分区大小要 ≥ 新镜像（当前镜像 798 KB，扩后预计 ~940 KB）；
2. `readelf -SW` 复核 `.iram_blobs` 不再越过 `0x2f00ffd0`（这才是本项的验收判据）；
3. 板上锚点 dump 应为有效指针（`0x2f0155b8` 一类），而非 `40f2ed8f` 这类指令字节。

## ⚠️ 撤回「结构性损坏」：真正原因是**我们的硬编码地址**（2026-11-19）

复核方法（结论反转）：

```
readelf -sW app.elf | grep r_sym_bt_pSy5
  -> 2f010ee0  4 OBJECT GLOBAL DEFAULT 11 r_sym_bt_pSy5...
覆盖 0x2f00ffd0 的段：只有 .iram_blobs 一个（无第二个段 ⇒ **不存在重叠**）
```

⇒ **锚点没有重叠，是移动了**：`WITH_PHY=1` 版里 anchor[0] 在 **`0x2f010ee0`**，
而 `probe.zig:441` 与 `gate.zig:26` 都**硬编码 `0x2f00ffd0`** ⇒ 读到的是 `.iram_blobs` 里的指令字节
（`40f2ed8f`/`8082`…），被我误判成"段重叠损坏"。

**修复**：两处都改为取符号地址
`@intExternPotr(&@extern(*volatile u32, .{ .name = "r_sym_bt_pSy5Wex1v0iXw5RdWtwL" }))`。
板上复验（`WITH_PHY=1`，811 040 B）：

```
bt anchors[before-phy]: 2f010ee0 696e6170 …     <- 第一个槽 = anchor[0]，有效指针
```

⇒ **`WITH_PHY=1` 镜像并未损坏**；此前所有基于"锚点是代码字节"的推论（含 `JwHs` 假非零、
`FzF1` 对代码字节 `sb`）**全部作废**。

**教训**：诊断代码里的硬编码地址必须与符号地址核对一次 —— 镜像布局一变，硬编码就变成"读别人"。

## 修复硬编码后的 `WITH_PHY=1` 现状（2026-11-19）

改用符号地址后，同一份 811 040 B 镜像的日志：

```
bt anchors[before-phy]: 2f010ee0 696e6170 …      <- anchor[0] 正确
bt anchor↓ / bt brin↓ / bt lp:↓                  <- 进入 bringup，走到 step 5（UART 截断成残片）
s256.0.2.1                                        <- 心跳仍在
（无 "PHY enabled AFTER step 5"、无 BOOTSTATE）
```

⇒ 归档侧的 `WITH_PHY=1` 路径**不再被误判为损坏**；它进入 bringup、到达 step 5，
而按 IDF 顺序放在 step 5 之后的 `initPhy()` **仍未返回**（那条标记行没出现）。

⚠️ 但**残片截断使这条判读不够硬**：要确证，需把逐行日志换成**每步一个短标记**
（`S1`…`S6`、`PHY-`/`PHY+`，全部 <10 字节），一次运行即可读出无歧义的顺序与停点。

### 下一步（两条，按优先级）

1. **短标记改造**（10 分钟）：把 step 与 PHY 前后改成 <10 字节标记 ⇒ 一次运行得到干净序列；
2. 若确认停在 `initPhy()`：在 `btdmLpEnableClock` 里先补
   `SOC_PLL_SOURCE_CG (0x2058_71E0←0x3d)` 与 CLK_CONF1 的 FE_* 位、以及 `I2C_ANA_MST`
   （材料见上一节，**不要**照抄 wifi 的 `LPCON+0x18←0x1`），再测。

## 锚点在 `WITH_PHY=1` 版里仍连续（已用符号表核实）

```
2f010ee0 r_sym_bt_pSy5…   <- anchor[0]
2f010ee4 r_sym_bt_WDq2…
2f010ee8 r_sym_bt_YnZm…
...
2f010f04 r_sym_bt_y5Di…   <- anchor[9]
```

⇒ **10 个槽仍是 `base + 4i` 连续排布**（间距恰好 4），所以 `base+4i` 的模型正确，
只要 base 用符号地址（已修）。

⇒ 之前 `anchors[]` 里 `anchor[0]=2f010ee0` 后面跟着 `696e6170`/`6c203a63` 这类 ASCII，
**不是"读到了别的结构"，而是那些槽里的内容本身就是这些值** —— 即
**`WITH_PHY=1` 版里 anchor[1..9] 里是加载镜像带来的非零垃圾**（默认版里它们是 0）。

这一点对判读很重要：**"锚点非零"不能直接当成"已被发布"**，必须先确认它指向合法的堆对象；
在 `WITH_PHY=1` 版里，非零值多半是镜像残留数据，会让归档的 `if (anchor != 0)` 守卫误判。

### 下一步建议（策略层面）

**绕开 IDF 的 `esp_phy_enable(2)`，改为自己复刻那几步**（wifi 侧已验证可行）：

`phy_get_romfunc_addr()` 填表 → 置 ICG/CLK_CONF1 与模拟前端时钟（含 `I2C_ANA_MST`）
→ `phy_modem_enable_set(1)` → `set_bb_wdg(...)` → **首次 `register_chipv7_phy`**
（用 `phy_init_data.zig` 的 128 B 表，`PHY_RF_CAL_FULL=2`）→ 重申 CLK_CONF1 与 FORCE_ON。

参考实现：`osi_impl.zig`（`grep -n 'shellPhyEnable'`）（完整顺序）+ `init_probe.zig`（`grep -n 'phyEnableHook'`）（`phyEnableHook`）。
判据不变：那行 "PHY enabled" 是否打印，以及随后能否读 `0x2010B000`。

## 两处默认值修正 + 一个新矛盾（2026-11-19 收尾）

**修正 1**：`phy_before_clocks` 默认改回 **`true`**（PHY 早于 step 5）。
理由：闭环结论（init → `Xpuq` → `0x2010B000`）是在**那个顺序**下取得的；
把它改成 IDF 顺序会让"默认路径已闭环"这一基线不再对应当前默认行为。
IDF 顺序仍可用 `-Dphy_before_clocks=false` 那套（代码里两分支都在）。

**修正 2**：我们自己的日志**限量** —— `log_hook_ours > 24` 之后只计数不再写 UART
（否则 21+ 条 `bt ret:` ≈ 0.5-1 KB ≫ 128 B FIFO，尾部被丢，反而看不到停点）。

### 新矛盾（未解决，需下会话复核）

默认版（798 240 B）的 dump：

```
bt anchors[before-phy]: 2f00ffd0 696e6170 6c203a63 756f2063 …
```

`anchor[0] = 0x2f00ffd0`（正确），但 `anchor[1..9]` 是 **ASCII 残留数据**
（`696e6170`="pain"、`6c203a63`="l: c"…）。

这与**早前**的 dump 矛盾：那时 `anchor[4]=0x2f0155b8`、`anchor[6]=0x2f015598` 都是**有效堆指针**，
`anchor[0..2]/[5]/[7]/[9]` 为 **0**。

可能原因（未区分）：
1. 这些槽所在的段是**加载镜像**（PROGBITS）而非 `NOBITS`，其初值来自 blob 数据；
2. 或者是**读的基址/长度**与实际锚点表不一致（`base+4i` 假设 10 槽连续 —— `readelf` 显示确实连续）。

**在澄清这一点之前，不要用 `anchors[]` 的值判断"某个子系统是否已发布"** ——
`if (anchor != 0)` 这类守卫在这颗芯片上可能被镜像初值"误满足"。
建议的判定方式：检查该槽指向的对象是否落在**我们 arena 的地址范围**内（而不是仅判非零）。

## 🎯 矛盾解决：锚点所在的 `.bss` **没有被完整清零**（2026-11-19）

段表：

```
[ 4] .iram_blobs  PROGBITS  2f0008b0 00eee0  -> 末址 2f00f790   （**不覆盖** 2f00ffd0）
[10] .data        PROGBITS  2f00fa60 0003f0  -> 末址 2f00fe50
[11] .bss         NOBITS    2f00fe80 005100  -> 末址 2f014f80   （**含 2f00ffd0**，10 个锚点都在此）
```

⇒ 锚点在 **`.bss`（NOBITS）**，按 ABI 启动时必须被清零；
但板上 `anchors[1..9]` 读出 ASCII 残留 ⇒ **`.bss` 的清零范围不足或缺席**。

**这解释了两件事**：
1. 为什么"未发布锚点"不是 0 而是垃圾 —— 归档的 `if (anchor != 0)` 守卫会被**镜像残留**误满足；
2. 早前 dump 里锚点为 0/有效指针的分歧（不同轮次残留不同）。

⚠️ 但**先前"结构性损坏"的撤回仍然成立**：`.iram_blobs` 确实不覆盖锚点，
那次读到指令字节纯粹是**硬编码 `0x2f00ffd0` 而符号已移动**造成的。

### 下一步（优先级最高的一个 bug）

检查启动代码里 `.bss` 清零的**起止范围**：
- 应从 `__bss_start` 清到 `__bss_end`（或按链接脚本的 `.bss` 段范围）；
- 当前疑似只清了前一段（例如只清到某个旧尺寸），导致 `0x2f00ffd0` 之后的槽保留加载残留。

判据：清零后板上 `anchor[0..9]` 在归档运行前应**全为 0**；这正好可以用现成开关验证
（`publish_bohff_anchor=false` 时归档惰性发布前，`anchors[before-phy]` 应全 0）。

## 🚨 更正：锚点 dump 的地址计算**可能是错的**（2026-11-19）

符号表给出决定性证据：

```
31650: 2f00ffd0  4 OBJECT GLOBAL DEFAULT  11  r_sym_bt_pSy5Wex1v0iXw5RdWtwL
31883: 2f00fff4  4 OBJECT GLOBAL DEFAULT  11  r_sym_bt_y5Dip5N8bwiiGRcrWzBO
[11] .bss  NOBITS  2f00fe80 005100   <- Ndx=11 就是 .bss
```

⇒ 锚点符号的 **Ndx = 11 = `.bss`（NOBITS）** ⇒ 启动清零后**运行时必须是 0**（除非被写入）。
⇒ 因此读到 `696e6170`（"pain"）这类 ASCII **不可能是这些槽的内容** ⇒ **是我们 dump 的地址算错了**。

**可疑代码**（本会话我改的两处）：

```zig
const base: usize = @intFromPtr(&@extern(*volatile u32, .{ .name = "r_sym_bt_pSy5…" }));
const v = (@as(*volatile u32, @ptrFromInt(base + i * 4))).*;
```

`@extern(*volatile u32, …)` 本身**就是**指向该符号的指针（`probe_ptr.zig` 里的用法是 `. *`），
对它再取 `&` 取到的是**指针变量的地址**，不一定是符号地址 —— 这很可能就是读到错误位置的原因。

**正确写法**（与 `probe_ptr.zig:26-28` 一致）：

```zig
const p: *volatile u32 = @extern(*volatile u32, .{ .name = "r_sym_bt_pSy5…" });
const v = (@as(*volatile u32, @ptrFromInt(@intFromPtr(p) + i * 4))).*;
```

### 影响范围（必须声明）

**本会话中所有基于 `anchors[]` 读数的判断都需要复核**，包括：
- “anchor[0]=0 / anchor[4] 有效 / anchor[9]=0”这类对读；
- 由此推出的“惰性发布”“某槽未发布”“`anchor[8]` 预发布导致 JwHs 短路”等结论。

其中**独立于 dump 的部分仍然成立**：`JwHs`/`FzF1` 的反汇编、OSAL 调用者环、闭环到 `Xpuq`
（后者来自反汇编与 OSAL 序列，不依赖 anchors 读数）。

**下一步（第一步，先于一切）**：按上面的正确写法修 `gate.zig` 与 `probe.zig` 的两处，
重新在板上读一次 `anchors[before-phy]`；若全为 0 ⇒ `.bss` 正常、此前读数全是 dump 的锅；
若仍非 0 ⇒ 才轮到怀疑 `.bss` 清零。

## ✅ 锚点 dump 已修好并验证：**全 0**（2026-11-19 定论）

修正 `gate.zig` 的取址方式（`@extern` 本身就是指针，不再取 `&`）后，板上：

```
bt anchors[before-phy] base=0x2f00ffd0: 0 0 0 0 0 0 0 0 0 0
bt anchors[after-phy]  base=0x2f00ffd0: 0 0 0 0 0 0 0 0 0 0
```

⇒ **`.bss` 清零是正确的**（`start.zig` 用 `_bss_start.._bss_end` 逐字清），
⇒ **此前读到 ASCII 完全是我们自己 dump 的取址错误**，
⇒ 且 `initPhy()` 前后锚点**都为 0** —— 与早先"ROM 不填这张表"的结论一致。

### 由此确定的判读规则（替换此前两条错误说法）

| 错误说法 | 正确判据 |
| --- | --- |
| "`.bss` 清零不足" | ❌ 清零正常；问题在 dump |
| "锚点非零 ⇒ 已发布" | ⚠️ 仍不安全：**应检查该值是否落在堆区间 `[_bss_end, _stack_bottom)` 内** |

### 需要复核的历史结论

凡**依赖 `anchors[]` 读数**的（"惰性发布""某槽未发布""anchor[8] 预发布导致 `JwHs` 短路"），
其**证据来源已确认不可靠**，应视为待复核；而**不依赖它的**结论仍然成立：
`JwHs`/`FzF1` 反汇编、OSAL 调用者环（21 条）、闭环到 `Xpuq`、以及若干次单开关对照实验。

## ✅ 逐调用改成「1 字节编码」——低带宽序列可用（2026-11-19）

`logHook` 里把 `bt ret: <name>…` / `bt call: <name>…` 压成该名字的**首字母**，
直接写 1 字节到 UART（`uartPut`，40 次自旋上限）：

| 字母 | 含义 |
| --- | --- |
| `m` | malloc |
| `i` | mutex_init |
| `q` | eventq_init |
| `e` | event_init |
| `p` | mutex_pend |

21 次调用只占 **21 字节** ⇒ 永不灌满 128 B FIFO，也不受"前 N 条"上限影响。

板上实测（18 s 抓取末尾）：

```
bt mempool: ok …
mmmmmmmmm          <- 9 次 malloc 的编码，出现在日志最末尾（= step 6 阶段）
```

⇒ **"停在哪一次调用"现在可以逐字母读**，不再依赖长行与截断。

### 下会话用法

```bash
grep -aoE "[meisqpt][meisqpt]{2,}" /tmp/x.log     # 连续字母 = 调用序列
```

配合已有的 RAM 环（`lr`）与调用者环（`n`），三路证据互相印证。

## ✅ 数字编码上线：首次拿到**无歧义调用序列**（2026-11-19）

字母编码不可用（`malloc`/`mutex_init`/`mutex_pend` 全是 `m`，会互相混淆），改为**数字码**：

| 码 | 调用 | 码 | 调用 |
| --- | --- | --- | --- |
| `0` | malloc | `5` | mutex_release |
| `1` | mutex_init | `6` | free |
| `2` | eventq_init | `7` | eventq_get |
| `3` | event_init | `8` | eventq_put |
| `4` | mutex_pend | `9` | sem_* |
| `#` | 其它 | | |

板上抓到的序列（30 s）：

```
2000000044
```

解码：`eventq_init → malloc×6 → mutex_pend ×2`。

⇒ **序列现在可以逐码读，且不会被日志散文误匹配**（`grep -aoE "[0-9#]{3,}"`）。

### 下会话用法

```bash
grep -aoE "[0-9#]{3,}" /tmp/x.log | tail -3     # 尾部即崩溃前的最后调用序列
```

配合 RAM 环（`lr`）与调用者环（`n`），三路证据可互相印证；
`2000000044` 这种序列能直接回答"它最后在做什么"。

## 码流已加窗口开关，但序列仍缺前两码（2026-11-19，如实记录）

改动：`probe.call_stream_on` 只在 step 6 之前置真；窗口内**只发数字码**（其余自身日志不发）。

板上仍为：

```
2000000044
```

⇒ 10 个码，**开头是 `2`（eventq_init）**，而按反汇编 `OkE7` 的顺序应以
`0`(malloc 76) → `1`(mutex_init) → `2`(eventq_init) 开头。

**两种可能（未区分）**：
1. 前两次调用发生在本窗口**之前**（例如 `dumpBootState` 的 PHY 路径里就有一次 `malloc`）；
2. 它们发了码但**在 `put` 时 FIFO 已满**被丢弃（窗口前那 6 条 `bt bringup:` + mempool 行 ≈ 300 B）。

**注意**：README 前面"首次拿到无歧义调用序列"应理解为**窗口内后缀**，不是全量 21 次。

**下一步（更稳的做法，未实现）**：把数字码写进**RAM 小环**而不是 UART，
再用 `probe_stop_at_tick`(300) + `extra_dump` 一次性打一行（21 字节 + 头）——
这样里程碑进度照常可见、序列也完整，不必为通道牺牲可观测性。

## 码流已改存 RAM，但**缺少导出触发点**（2026-11-19 最后一条）

实现：`code_ring[48]` + `code_n`，窗口内每次调用 `codePush(codeOf(name))`（不占 UART）；
`dumpOsalCallers` 里加了一行 `CODES n=… {码}`。

板上结果：**没有 `CODES` 行** —— 因为该导出只在 **panic 时**调用，而当前是**静默停摆、无 panic**。

⇒ 码流已在 RAM 里，但**没有触发点把它打出来**。

### 下会话：二选一即可拿到完整序列

1. **ISR 触发**（最省事）：在 `trap` 的 T0 ISR 里加一句
   `if (irq_count == 250) { if (ring_at) …; if (CODES 打印钩子) … }` ——
   一次打一行约 30 字节，FIFO 完全放得下，且时刻在停摆（≈320 tick）之前；
2. **不依赖中断**：在 `mutex_pend` 包装层里，当 `code_n` 达到某阈值时打一次（此时已过大部分调用）。

两者都**不得 halt**（本会话已有两次 halt 把观测点变成故障点的教训）。

## ✅ 完整调用序列前缀已捕获（2026-11-19 定论）

用**码数阈值触发导出**（`code_n == 16` 时调用 `extra_dump`，不 halt、不依赖 `irq_count`），
`CODES` 行放在导出**第一行**（最不易被 FIFO 丢）：

```
CODES n=16 0120000000000000
```

解码：

| 位置 | 码 | 调用 |
| --- | --- | --- |
| 1 | `0` | `malloc(76)`（OkE7 惰性发布） |
| 2 | `1` | `mutex_init` |
| 3 | `2` | `eventq_init` |
| 4-16 | `0`×13 | 后续 `malloc`（8 / 36 / 32 / 12 / …） |

⇒ 与反汇编预测的顺序**逐项吻合**，也与早期 `bt ret:` 日志一致。

⇒ 此前 `2000000044` 缺前缀，不是"调用发生在窗口外"，而是**码被 FIFO 丢弃** ——
本方案把码存 RAM、按数量触发一次性导出，彻底绕开了通道限制。

### 当前基线的正确判读（重要）

`publish_bohff_anchor=false` 之后：
- **没有 panic 是预期**（-8 回滚已消除，`FzF1` 的写 0 不再发生）；
- 症状是 **`Xpuq` 处读 `0x2010B000` 的总线挂起** —— 与"默认路径闭环到 `Xpuq`"一致；
- 因此 **panic 路径的触发器对当前基线不适用**，码数触发才是对的。

### 序列尾部的一个待核点

抓到过 `…44`（两个 `mutex_pend`）：按反汇编 `task_init` 在 `0x4005fb84` 有一次，
另一个 `4` 的调用点需在 `OkE7` 之后的路径里再核 —— **不要直接当成"两次 pend"**。

## 交接引用已复核（2026-11-19）

下一棒会直接照这些指针行动，故逐一核对：

| 引用 | 状态 |
| --- | --- |
| `wifi-blobs/src/init_probe.zig:686-700`（`MODEM_LPCON_CLK_CONF` / PHY 模块时钟） | ✅ 内容相符 |
| `wifi-blobs/src/osi_impl.zig:1082`（`fn shellPhyEnable(modem: u32)`） | ✅ 内容相符 |
| `wifi-blobs/src/phy_init_data.zig`（`pub const params: [128]u8`） | ✅ 存在 |
| `WITH_PHY=1` 版 `esp_phy_enable` @ `0x40000744`（174 B FUNC） | ✅ 实测相符 |
| `WITH_PHY=1` 版 `esp_phy_load_cal_and_init` @ `0x40000580`（452 B） | ✅ 实测相符 |
| 默认版 `esp_phy_enable` = ROM `0x2f00e756`（ABS） | ✅ 相符 |

## 🚀 突破：补 PHY 频域时钟后**总线停摆消失**，PHY 校准真正开跑（2026-11-19）

移植 `porting.phyDomainEnable()`（默认关，本轮打开）后，`WITH_PHY=1` 构建的板测：

```
bt phy: domain clocks on (pll=0x3d conf1|=FE lp18|=i2c_mst)
...
pcsample n=9728 pc=0x40067094 ra=0x40000672 s0=0x0
s9728.416.419.1            <- 心跳到 9728 tick（此前卡在约 320）
s9792.416.419.1            <- 仍在增长
```

| 项 | 之前 | 现在 |
| --- | --- | --- |
| 心跳上限 | ~320 tick（≈32 ms）后停 | **9728+ 且持续增长** |
| 状态 | 总线挂起（静默） | **CPU 在跑，中断正常投递** |
| 停点 | `Xpuq` 首读 `0x2010B000` | **`esp_phy_load_cal_and_init` 内部调用了 `abort`** |

地址解析：

| 地址 | 符号 |
| --- | --- |
| `pc=0x40067094` | **`abort`**（我们自己的） |
| `ra=0x40000672` | **`esp_phy_load_cal_and_init`**（`0x40000580 + 0xF2`） |

⇒ **PHY 校准路径已真正执行**（此前它连时钟都没有），现在的失败是**校准内部触发 `abort`**。
⇒ 这一举推翻了"`0x2010B000` 一读即挂死"在本构建下的适用性：域时钟打开后总线不再挂死。

### 下一步（单点、离线优先）

1. 反汇编 `esp_phy_load_cal_and_init` 在 `0x40000672` 附近的调用点，看它调 `abort`/`assert` 前的判据
   （很可能是 NVS 桩返回 `NOT_FOUND` 后走了 assert 分支，而不是回落到全量校准）；
2. 据此把 `phy_stubs.c` 的 NVS 行为从"NOT_FOUND"改成"返回成功 + 空 blob 长度 0"，
   或直接让 `s_is_phy_calibrated` 初值为 false 走全量校准；
3. 判据：出现校准完成标志（或 `esp_phy_enable` 返回），随后 `0x2010B000` 可读。

## `abort` 已加标记；复现需 `phy_domain_enable=true`（2026-11-19 收尾）

| 事实 | 值 |
| --- | --- |
| `abort` 符号 | `0x40067094`，**size = 2**（`for(;;){}` 编译成 2 字节自跳转） |
| `ra=0x40000672` | 该处是 `jal esp_log_timestamp`（**日志调用**，不是 abort 调用点） |
| 结论 | 采样落在 `abort` 的自旋里，但 `ra` 指向 PHY 的日志路径 ⇒ 断言来自 PHY 校准内部的日志/检查 |

已在 `phy_stubs.c` 的 `abort` 里加**入口标记**（连续写 8 个 `'A'` 再自旋），
这样"到达 abort"与"卡在别处"在串口上可区分。

⚠️ **复现条件**：必须 `phy_domain_enable = true`（默认 `false` 是基线，会早停在 `Xpuq`）。
本轮用默认（false）构建跑，自然看不到 `A`。

**下一轮的固定动作**：
1. 把 `phy_domain_enable` 置 `true`（改源码 → 重建，它在 ReleaseSmall 下会被常量折叠，运行时可翻无效）；
2. 抓串口，看是否出现 `AAAAAAAA`；
   - 出现 ⇒ PHY 断言成立，下一步在 `esp_phy_load_cal_and_init` 里找那条断言的上游判据；
   - 不出现 ⇒ CPU 卡在别处（用 1 字节心跳 + 码数导出定位）；
3. 测完把开关改回 `false` 再提交（保持基线可复现）。

## 🎯 `abort` 的确切原因（离线从 rodata 读出，2026-11-19）

`WITH_PHY=1` ELF 的 rodata：

```
0x40100024: "phy_init"                       <- 源文件 phy_init.c
0x40101dd0: "E (%lu) %s: failed to "          <- ESP_ERROR_CHECK 的日志格式
0x40101dd4+: "…ed to obtain PHY init data"
0x40101dfc+: "…(%lu) %s: failed to allocate memory for RF calibration"
```

⇒ **`phy_init.c` 里的 `ESP_ERROR_CHECK` 失败**，两条候选消息：
1. **"failed to obtain PHY init data"** —— 取不到 PHY 初始化表（NVS/校准数据缺失）；
2. **"failed to allocate memory for RF calibration"** —— 为 RF 校准**分配内存失败**。

判定依据（都指向我们侧）：
- 我们的 `phy_stubs.c` 让 `nvs_open(PHY_NAMESPACE)` 返回 `ESP_ERR_NVS_NOT_FOUND`
  ⇒ 若 IDF 在 `NOT_FOUND` 时不回落到全量校准，就会命中第 1 条；
- RF 校准需要一个较大的缓冲区（`esp_phy_load_cal_and_init` 里 malloc），
  而我们的 arena 只有几十 KB 且已被 21 次 malloc 消耗 ⇒ 很可能命中第 2 条。

**下一步（两处各一改，判据明确）**：
1. `phy_stubs.c` 的 NVS 改为**返回成功 + 长度 0 的空 blob**（而不是 NOT_FOUND），
   迫使它走"全量校准"而不是 assert；
2. 若仍 abort，则加大 arena / 让 `btdmMalloc` 在大块请求时回落到大缓冲；
3. 判据：`phy_init.c` 的 `E (...)` 日志消失，或 `esp_phy_enable` 返回 0。

⚠️ 该路径**必须** `phy_domain_enable=true` 才能到达（默认 `false` 是基线）。

## `phy_init` 内的实际调用顺序（离线反汇编，2026-11-19）

```
400005b8: jal  calloc                            <- 分配校准缓冲（真实分配器，46 B，含清零 + NULL 判断）
400005c0: c.jal esp_phy_get_init_data            <- 取 PHY 初始化表
400005d6: c.jal esp_phy_load_cal_data_from_nvs   <- 读校准数据
4000063e: jal  free
40000700: c.jal esp_phy_store_cal_data_to_nvs    <- 写回校准数据
```

⇒ abort 必是两处 `ESP_ERROR_CHECK` 之一：

| 候选 | 触发条件 | 判据 |
| --- | --- | --- |
| **`calloc` 返回 NULL** → "failed to allocate memory for RF calibration" | 堆不足 | 我们的 `calloc` 是真实实现（`40067026`，46 B，清零循环 + `beqz` 判 NULL），但**堆大小未知** |
| **`esp_phy_get_init_data` 失败** → "failed to obtain PHY init data" | 初始化表取不到 | 需要 128 B `esp_phy_init_data_t`（`phy_init_data.zig` 有），但要确认它被真的传进去 |

**下一步（一处改动即可区分）**：在 `calloc` 桩里记录**请求的字节数**（写 1 字节码或一行短日志），
一次运行就能知道 RF 校准要多大；若远大于我们的堆，就扩堆；若请求很小却返回 NULL，则是堆未初始化。

⚠️ 仍需 `phy_domain_enable=true` 才能到达该路径（默认 `false` 是基线）。

## NVS 供给 PHY 初始化表：已实现，abort 仍在（2026-11-19 收尾）

实现（`phy_stubs.c` + `phy_init_data_export.zig`）：

- `nvs_open` → 返回 `ESP_OK`（此前 `NOT_FOUND`）；
- `nvs_get_blob`：`*len < 128` 时置 `*len=128` 并返回 `INVALID_LENGTH`（**IDF 的"先查长度"约定**）；
  `*len >= 128` 时拷入 128 字节表并返回 `ESP_OK`；
- 数据来源：`phy_init_data_export.zig`（由 `wifi-blobs/src/phy_init_data.zig` 的 `params` 复制生成，
  经 `@export` 暴露为 C 符号 `g_phy_init_data_128`）——**不引入跨组件依赖**。

板测（`phy_domain_enable=true`，`WITH_PHY=1`，812 128 B）：

```
AAAAAAAA                                   <- 我们给 abort 加的标记（abort 现在是 112 B）
pcsample n=9728 pc=0x4006710a ra=0x40000672
```

⇒ **abort 仍然发生**（PC 落在我们 112 字节的 `abort` 桩内，`ra` 仍指向 `esp_phy_load_cal_and_init` 的日志调用）。

⇒ 因此 `esp_phy_get_init_data()` 的失败**不只是 NVS 返回 NOT_FOUND**；
   还可能是：它用 `nvs_get_blob` 的**其它 key**（如 `cal_data`/`cal_version`，见 rodata 里的
   `phy-track-pll-timer` / `cal_version` 串），或它对返回内容有校验（长度/版本/CRC）。

**下一步（离线优先）**：
1. 反汇编 `esp_phy_get_init_data`（`0x40000414`）全段，看它在 `nvs_open` 后调了哪些 key、
   以及它对失败的具体判据（返回值比较、长度检查；
2. 按那些 key 补齐 `nvs_get_blob` 的分支（`cal_version` 可能是 u32，用 `nvs_get_u32`）；
3. 判据：`AAAAAAAA` 消失，或日志里出现校准完成的迹象。

**注意**：`abort` 的 8 字节标记应保留 —— 它是当前唯一能区分"到达 abort"与"卡在别处"的信号。

## ⚠️ 更正：`esp_phy_get_init_data` **不会失败**，NVS 供给是多余的一步（2026-11-19）

反汇编（`0x40000414`，**size = 10**）：

```asm
40000414: <prologue>
40000418: addi a0,a0,-17     # a0 <- 0x40104fef <phy_init_data>   （静态表，就在镜像里）
4000041c: c.jr ra            # 直接返回
4000041e <esp_phy_release_init_data>: c.jr ra   # 空实现
```

⇒ `esp_phy_get_init_data()` 是**返回静态表地址的 thunk**，返回值恒非 0 ⇒ **不可能触发
"failed to obtain PHY init data"**。

⇒ 我先前把 `0x40000432` 起的 `nvs_open` 段落误当成它的函数体 —— **那属于下一个函数**
（`0x40000432+`），因为它 `size=10` 只覆盖 `0x40000414..0x4000041e`。

⇒ 因此**上一轮改的 NVS 语义（`nvs_open` 成功 + 128 B blob）不是根因的修复**，
保留无害（对校准数据路径仍可能有用），但**不解决 abort**。

### abort 的真实候选因此收窄为一条

`esp_phy_load_cal_and_init` 里唯一的另一处 `ESP_ERROR_CHECK` 是
**"failed to allocate memory for RF calibration"** ⇒ **`calloc` 返回了 NULL**。

**下一步（离线即可量出）**：看 `0x400005b8` 那次 `calloc` 的**实参**（`0x400005a4..0x400005b8` 的
`li a0,N` / `li a1,M`），即可知道 RF 校准缓冲要多大；再对照我们的堆上限决定"扩堆"还是"给专用池"。

## 撤掉冗余的初始化表副本（2026-11-19）

`esp_phy_get_init_data`（`0x40000414`，**10 字节**）是返回静态表 `phy_init_data`（`0x40104fef`）的 thunk，
**镜像里本来就带着这张表** ⇒ 无需第二份。已删除：

- `components/bt-blobs/src/phy_init_data_export.zig`（含 `@export g_phy_init_data_128`）
- `probe.zig` 里对它的 `comptime` 引用
- `phy_stubs.c` 里的 `extern` 与 `nvs_get_blob` 的 128 字节分支

`nvs_get_blob` 回到"校准 blob → `NOT_FOUND` ⇒ 走全量校准"。
`nvs_open` 保留返回 `ESP_OK`（`esp_phy_load_cal_data_from_nvs`（`0x40000420`，264 B）需要能打开命名空间；
其错误串 `0x40101ef4` 是 **"NVS has not been initialized. Call nvs_flash_init before…"**）。

### 由此得到的函数边界（`readelf`，务必按 size 反汇编）

| 符号 | st_value | size |
| --- | --- | --- |
| `load_cal_data_from_nvs_handle` | `0x40000120` | 852 |
| `store_cal_data_to_nvs_handle` | `0x40000282` | 786 |
| `esp_phy_disable` | `0x400003ba` | 132 |
| **`esp_phy_get_init_data`** | `0x40000414` | **10** |
| **`esp_phy_load_cal_data_from_nvs`** | `0x40000420` | **264** |
| `esp_phy_load_cal_and_init` | `0x40000580` | 452 |

⇒ 本会话多次把相邻函数的代码当成同一个（`get_init_data` vs `load_cal_data_from_nvs`），
**先用 `st_size` 划定区间再反汇编**是唯一可靠的做法。

## RF 校准缓冲只需 **1904 字节**（离线读出，2026-11-19）

`esp_phy_load_cal_and_init` 里的分配点：

```asm
400005b2: addi a1,zero,1904     # size  = 1904
400005b6: c.li   a0,1           # nmemb = 1
400005b8: jal    calloc         # calloc(1, 1904) —— 仅 1.9 KB
```

⇒ **不是"要几十 KB"** —— 1904 字节。所以若 `calloc` 返回 NULL，说明我们的分配器**根本没准备好**
（而不是"堆不够大"）。

**下一步（二选一，均离线优先）**：
1. 找 `calloc`（`0x40067022`，46 字节）背后的堆：它从哪块内存取？是否需要在启动时初始化？
   若是 Zig 的 bump 分配器且未赋初值，任何请求都会返回 NULL；
2. 或在 `abort` 标记旁边再加一个"calloc 返回 NULL"标记，一次板测即可区分。

**若 calloc 正常**，则 abort 来自别处 —— 但 `esp_phy_load_cal_and_init` 里只有两处 `ESP_ERROR_CHECK`，
另一处（init data）已证明不可能失败（10 字节 thunk 返回静态表）。

## 🎯 根因候选确定：arena 只有 **4039 字节**，而 RF 校准一次要 **1904**（2026-11-19）

链已闭环到具体数字：

```
calloc(1, 1904)                     <- esp_phy_load_cal_and_init 里的分配点（离线读出）
  -> s31_btdm_malloc (0x4006c85a)
  -> btdmMalloc                      (osal.zig:1244)
  -> bt_arena.alloc                  (osal.zig:1167)
```

板上实测：**`bt probe: arena 4039 B`**。
归档在 PHY 之前已做过 **21 次 malloc**（76 / 8 / 36 / 32 / 12 … 及 OSAL 对象），
消耗掉一部分后，**1904 字节的连续块极可能已取不到** ⇒ `calloc` 返回 NULL
⇒ `ESP_ERROR_CHECK` → "failed to allocate memory for RF calibration" → `abort`。

**这与"不是堆太小"的先前判断冲突** —— 4039 B 的总量看着够，但**减去已用 + 对齐开销**后不一定够。

### 下一步（一处改动，判据明确）

1. 先**离线/一行日志确认**：`btdmMalloc` 里对 `size >= 1024` 的请求打一行（或用已有的
   `bt hook: malloc({d}) = {x}`，把 `trace_hooks` 在 PHY 阶段临时打开），看 1904 是否返回 0；
2. 若为 0 ⇒ **扩大 arena**：`heapStart()` / `heapEnd()` 之间就是 `[.bss 末, 栈底)`，
   当前只切出 4039 B（`heapEnd` 取值偏保守）——把 `heapEnd` 上移（留足栈）即可；
3. 或给 PHY 校准预留一块**专用 2 KB 缓冲**，让 `calloc` 的大块请求回落到它。

## arena 只有 4039 B 的原因：**BSS 已逼近栈底**（2026-11-19 定论）

链接脚本约定（`s31.ld:16,182-183`）：

```
_stack_top = ORIGIN(sram) + LENGTH(sram)      # SRAM 末尾
栈 16 KiB，向下增长 ⇒ _stack_bottom = _stack_top - 16 KiB
_heap_start = _bss_end , _heap_end = _stack_bottom
```

`Arena.init` **没有任何上限**（`osal.zig:1150`）⇒ 板上 `arena 4039 B` 就是
`_stack_bottom - _bss_end` 的真实值 ⇒ **BSS（含归档的 `.btdm_bss` 等）已经长到只剩 4 KB 空隙**。

⇒ 因此 1904 B 的 `calloc` **不是"肯定够"**：arena 里已有 21 次分配 + 每块 header + 对齐，
1904 的连续块是否还存在需要**实测**（一行 `bt hook: malloc(1904) = 0x…`）。

### 两条修法（都不改语义）

1. **缩小 BSS**：`WITH_PHY=1` 版多链了很多对象，BSS 随之变大；若某些 `.bss` 段其实不必要，
   可从闭包里去掉；
2. **扩大 SRAM 窗口**：`sram LENGTH = 0x7AFC0`（`s31.ld:51`），若硬件允许可加大；
   或**减小栈预留**（当前 16 KiB，可试 8 KiB —— 但先确认最深调用链，别冒栈溢出风险）。

### 最终判据（一次板测）

在 `WITH_PHY=1` + `phy_domain_enable=true` 下把 `trace_hooks` 临时打开，
看是否出现 `bt hook: malloc(1904) = 0x0`：

- 出现 `= 0x0` ⇒ arena 确实不够 ⇒ 按上面两条修；
- 出现非 0 地址 ⇒ 分配成功，abort 另有原因（此时只剩 `esp_phy_load_cal_and_init` 里未读到的第三处检查）。

## 🔴 结构性 bug：**堆区间与 `.btdm_bss` / `.btdm_data` 重叠**（2026-11-19）

链接后实测符号：

```
_bss_end      = 0x2f015ec0      <- _heap_start 取它
.btdm_bss     0x2f015ec0 .. 0x2f01dec0   (32 KiB, NOBITS)
.btdm_data    0x2f01dec0 .. 0x2f01eec0   ( 4 KiB, NOBITS)
_heap_end     = 0x2f076fc0      (= _stack_bottom)
```

⇒ `_heap_start` 被放在 **`.btdm_bss` 的起点**，而 `.btdm_bss` / `.btdm_data` 共 **36 KiB**
正落在这段"堆"里 ⇒ **arena 一旦分配，就会覆盖归档自己的 BSS/数据**。

⇒ 这解释了本会话许多"不可解释"的现象：归档的全局对象被我们自己的分配器反复覆盖
（锚点槽、事件队列、`d3D3` 链表头都在 `.btdm_bss` 里）。

### 正确布局

```
_bss_end 应取 .btdm_data 的末址 = 0x2f01eec0
堆 = [0x2f01eec0, 0x2f076fc0) ≈ 360 KiB
```

即链接脚本里 `_heap_start` / `_bss_end` 的定义必须**放在 `.btdm_bss` 与 `.btdm_data` 之后**，
而不是 `.bss` 之后。

**验收判据**：
1. `readelf -sW` 后 `_heap_start >= .btdm_data 末址`；
2. 板上 `bt probe: arena` 报 ≈ 360 KiB（而不是 4039 B —— 那个数字来自更早的布局，需复核）；
3. 归档的 `.btdm_bss` 在运行期间不再被分配器改写（可用锚点读数验证）。

## ✅ 已修：堆起点移到 `.btdm_data` 之后（2026-11-19）

`s31.ld` 改动一处：

```ld
-    _heap_start = _bss_end;
+    _heap_start = _data_end_btdm;    /* .btdm_bss(32K) + .btdm_data(4K) 之后 */
```

链接后实测：

```
_data_end_btdm 0x2f01dfc0   <- _heap_start
_heap_end      0x2f076fc0
=> 堆 = 0x59000 = **364 KiB**（原为 4039 B）
```

⇒ 归档的 `.btdm_bss` / `.btdm_data`（36 KiB）**不再落在堆区间内**，分配器不会覆盖它们。

板测（默认构建，798 992 B）：mempool 行正常，**仍能走到 step 6**（`osalcaller[]` 导出出现），
基线未被破坏。

### 待复核

板上 `bt probe: arena` 那行本轮被 FIFO 丢弃，未读到具体数值。
下一轮顺手确认它报 ≈ 364 KiB 即可（若仍报 4039 B，说明读到的不是同一份镜像）。

### 影响范围

这个 bug 让 allocator 从 `0x2f015ec0` 起分配 —— 而那正是 `.btdm_bss` 的起点。
**归档的锚点槽、事件队列、`d3D3` 链表头全部住在 `.btdm_bss` 里**，
所以此前所有"锚点忽而有效忽而垃圾""不可解释的挂死"都可能由此解释。

## 负结果：堆修复**没有**消除 abort（2026-11-19 末）

修好 `_heap_start`（4 KB → 364 KiB）后，`WITH_PHY=1` + `phy_domain_enable=true` 重跑：

```
AAAAAAAApcsample n=4096 pc=0x400670d4 ra=0x40000672 s0=0x0
pcsample n=9728 pc=0x400670d4 ra=0x40000672
```

⇒ **abort 仍然发生**（`AAAAAAAA` 是我们给 abort 加的标记，`pc` 落在标记代码内）。

⇒ 因此 **"堆与 `.btdm_bss` 重叠"不是 abort 的成因**（虽然它是一个真实的 bug，已修）。

⚠️ 本轮 `bt probe: arena` 行被 FIFO 丢弃，**未能确认**堆的新数值 —— 下一轮应优先确认它（应约 364 KiB）。

### abort 的候选重新变为

| 候选 | 状态 |
| --- | --- |
| `calloc(1,1904)` 失败 | **几乎排除**（364 KiB 的堆不可能不够），但未直接观测 |
| `esp_phy_get_init_data` 失败 | **已排除**（10 字节 thunk 返回静态表） |
| **`esp_phy_load_cal_data_from_nvs` 内的检查** | **新候选**：它 `size=264`，内部 `nvs_open` + 若干 `nvs_get_*`；若 `cal_version` 等 key 取不到就报错 |

**下一步**：反汇编 `esp_phy_load_cal_data_from_nvs`（`0x40000420`，264 B）全段，
列出它在 `nvs_open` 之后调用的每个 `nvs_*` 与对应判据 —— 这是唯一还没读过的函数。

## `esp_phy_load_cal_data_from_nvs` 的检查也全部会通过（2026-11-19 末）

反汇编（`0x40000420`，264 B）：

```
40000436: jal  nvs_open        ; beqz a0 -> .L45（成功）
40000486: jal  nvs_close
400004a2: jal  nvs_open        ; beqz a0 -> .L48（成功）
400004d8: jal  nvs_open        ; bnez a0 -> .L54（失败才跳）
400004e2: jal  nvs_erase_all   ; beqz a0 -> .L52
```

我们的桩：`nvs_open` 返回 `ESP_OK`(0)、`nvs_erase_all` 返回 `ESP_OK` ⇒ **这些检查全部走成功路径**
⇒ **该函数不会 abort**。

### 剩下的矛盾（如实记录）

`esp_phy_load_cal_and_init` 在 `0x4000066e` 附近调用 `esp_log`，
我按操作数算出的格式串是 `0x40101dcc`（"failed to obtain PHY init data"）；
但 `esp_phy_get_init_data` 是 10 字节 thunk（返回静态表），**不可能失败**。

两者不能同时成立 ⇒ 其中一处判读有误，最可能是**该处的指令边界/操作数解码**（`lui`+`addi` 组合
在 misaligned 反汇编下会算错地址）。

**下一步（离线，最可靠）**：用 `objdump -d --start-address=0x40000660 --stop-address=0x400006a0`
**按 4 字节对齐**重读，逐条记录 `lui` / `addi` 的立即数并手工合成地址，再与 rodata 里的两条串对照。

**另一个更简单的判据（板测）**：abort 标记里顺便把**当前的 ra**（`__builtin_return_address(0)`）
写进串口——那就是 abort 的直接调用者地址，一次运行即可确定它属于哪个函数，不必再猜格式串。

## 🎯 abort 确认为**分配失败**（2026-11-19，地址解码纠正）

abort 前那条日志的实际格式串是 **`0x40101df8`**（我此前按 `0x40101dcc` 解码，错了一处）：

```
0x40101df8 = "E (%lu) %s: failed to allocate memory for RF calibration data\n"
```

⇒ **`calloc(1,1904)` 返回了 NULL** —— 这是唯一的 abort 原因。

（顺带纠正：全文只有一处引用 `0x40101dcc`，而 `0x40101dfc` 无引用，说明我先前把
`lui/addi` 合成的地址算错了一个常数。）

### 已知条件与矛盾

| 事实 | 值 |
| --- | --- |
| 请求 | `calloc(1, 1904)` |
| 链接符号算出的堆 | `_heap_end - _heap_start` = 0x2f076fc0 - 0x2f01dfc0 = **364 KiB** |
| 板上 `bt probe: arena` | **本轮被 FIFO 丢弃，未读到**（此前记录值是 4039 B，来自修复前的布局） |

⇒ 若板上 arena 仍是旧值（4039 B），则"修复未生效/刷的不是这版镜像"；
⇒ 若 arena 确为 364 KiB 而 `calloc` 仍失败，则问题在 `bt_arena` 的**初始化时机**
（`initArena` 在 `probe.run()` 里，需确认它早于 PHY 使能）。

### 下一步（单点，必须先做）

**确认板上 arena 的真实数值**：把 `bt probe: arena {d} B` 改到 step 6 之后再打一次
（或用 1 字节心跳那套机制），确保这行不被前面的输出挤掉。
在拿到这个数字之前，任何关于"堆够不够"的判断都不可靠 —— 这正是本会话反复踩的同一类坑。

## ✅ 板上确认：arena = **356 KiB**，因此分配失败**不是尺寸问题**（2026-11-19）

把 arena 行改成极短标记（长行会被 FIFO 丢），板上得到：

```
A356K
```

⇒ 堆修复**已生效**（4 KB → 356 KiB），与链接符号一致。

### 由此得出

`calloc(1, 1904)` 在 **356 KiB 空闲**的 arena 上返回 NULL ⇒ **不是容量问题**，只剩三种可能：

1. **`s31_btdm_malloc` 不是 `btdmMalloc`**：`calloc` 调的是 `0x4006c85a` 的 `s31_btdm_malloc`，
   需确认它是否就是 `osal.btdmMalloc`（`osal.zig:1244`）的导出，还是另一个实现；
2. **`Arena.alloc` 的找块/切分有 bug**（如 `min_block`/对齐导致的边界条件）；
3. **初始化时机**：PHY 使能在 `dumpBootState()`（`bringup.init` 内，probe.zig:447），
   而 `initArena` 在 probe.zig:395-401 —— 顺序上在前，但需确认那段确实执行到（`A356K` 已证明执行了）。

**下一步（离线，最小）**：
1. `readelf -sW | grep s31_btdm_malloc` 看它的 st_value 与所属源（或用 `nm` 确认与 `osal.btdmMalloc` 同一地址）；
2. 读 `Arena.alloc`（`osal.zig:1167-1200`）的完整找块逻辑，重点看 `min_block` 与 `block_align` 对
   `size=1904` 的处理 —— 这类"大块在小碎片里找不到连续空间"的 bug 在简单 bump/split 分配器里很常见。

## 分配链已完全确认，但仍存在矛盾（2026-11-19 末）

`WITH_PHY=1`（811 680 B）符号与反汇编：

```
calloc            @ 0x40067022 (46 B)
  -> s31_btdm_malloc @ 0x4006c872 (8 B)
       auipc t1,0xffffe ; jalr zero,1486(t1)  ==  tail-call  osal.btdmMalloc (0x4006ae40) ✅
  -> btdmMalloc -> bt_arena.alloc
```

| 已知 | 值 |
| --- | --- |
| arena（板上实测） | **356 KiB**（`A356K`） |
| 请求 | `calloc(1,1904)` ⇒ `need = align(1904+16, 8) = 1920` |
| `Arena.alloc` 逻辑 | 首块 356 KiB、free、`need ≤ size` ⇒ **必然返回非 NULL** |
| `initArena` 位置 | probe.zig:395-401，**早于** `bringup.init()`（:447）⇒ PHY 使能时已初始化 |

⇒ **按现有证据，这次分配不应失败**，但 `0x40101df8` 的串（"failed to allocate memory for RF
calibration data"）说明它确实失败了。⇒ 存在一处**尚未观测到的差异**。

### 唯一可靠的下一步（一次板测，二值）

在 `btdmMalloc` 里对 `size == 1904` 打一个**单字节标记**（如 `+` 表示成功、`-` 表示失败），
或直接把返回值的最低字节写成一个十六进制字符。一次运行即可判定：

- 若打出 `-`（失败）⇒ `Arena.alloc` 在该时刻状态与假设不符（打印 `bytesFree()` 一并看）；
- 若打出 `+`（成功）⇒ `calloc` 的失败另有来源（例如它检查了别的条件，或该 1904 请求
  并非我们读到的那个调用点）。

⚠️ **地址会随构建漂移**：本轮再次踩到 —— 同一 `0x4000066e` 在 default 与 WITH_PHY 构建里
分别是 `abort` 调用点与 `r_sym_ble_*` 调用。**任何引用都必须标注构建配置并当场用 `readelf` 复核**。

## 🎯 板上定案：`btdmMalloc(1904)` **失败**，尽管 arena 有 352 KiB（2026-11-19）

在 `btdmMalloc` 里对 `size == 1904` 打单字节判据（`+` 成功 / `-` 失败），板上：

```
A352K          <- arena 352 KiB（堆修复已生效）
-
-
-
-              <- 1904 字节请求**全部失败**
AAAAAAAA       <- abort（"failed to allocate memory for RF calibration data"）
```

⇒ **不是容量问题**（352 KiB 空闲却失败）。

### 代码里的关键早退

`Arena.alloc`（`osal.zig:1167`）遍历块表时**第一件事**就是：

```zig
if (hdr.magic != headerMagic) return null;   // 越界/损坏
```

⇒ 若**首块的 `magic` 被破坏**，任何分配都会立刻返回 NULL，与剩余空间无关。

### 因此最可能的根因

**arena 的首块头部被写坏** —— 即在 `_heap_start`（0x2f01dfc0）附近有别的写入：
- 归档的 `.btdm_data` 溢出（它紧邻堆起点，`NOLOAD` 但占地址）；
- 或某段 `memcpy`/`memset` 越界覆盖了 `BlockHeader`。

**下一步（一次板测即可确认）**：在 `alloc` 的 magIC 检查失败分支里打一个单字节（如 `!`），
并顺带打出实际 magic 的最低字节。若出现 `!` ⇒ 确认是头部损坏，再沿"谁在写 0x2f01dfc0"追；
若不出现 ⇒ 是 `need`/`min_block` 的比较问题（读 `min_block` 的实际值）。

⚠️ 这也解释了为何 `Arena.alloc` 的静态分析"必然成功"却在实际板上失败：
**静态分析假设了首块完好**，而运行时它已被破坏。

## 🏁 最终根因：**arena 块头被覆盖** —— `.btdm_data` 溢出（2026-11-19）

在 `Arena.alloc` 的三个 null 出口各打一个不同字节后，板上：

```
A352K
M x x x x x x x
```

| 标记 | 含义 | 观测 |
| --- | --- | --- |
| `M` | `hdr.magic != headerMagic`（头部被改） | **出现** |
| `x` | `next <= addr`（`hdr.size == 0`，链断） | 连续出现 |
| `!` | 未初始化 | 未出现 |
| `#` | 走完无足够块（碎片） | 未出现 |

⇒ **arena 首块的 `BlockHeader` 在运行中被覆盖**（magic 与 size 同时被清零）。
⇒ 覆盖来源几乎必然是**紧邻其下**的 `.btdm_data`：
   它从 `0x2f01dec0` 起、我们只预留 `0x1000`（到 `0x2f01dfc0`），
   而 `_heap_start` 正取在 `0x2f01dfc0` —— **`.btdm_data` 一旦超过 4 KiB 就越界写进块头**。

### 修法（两种，建议都做）

1. **加大 `.btdm_data` 预留**（`s31.ld` 里的 `. = . + 0x1000`），按归档实际用量放大；
2. **在两者之间留空隙**：`_heap_start = _data_end_btdm + 0x1000`（守卫页），
   这样即使轻微越界也不会立刻破坏块头，且能被后续观测发现。

### 这条修复的价值

它同时解释了本会话的多类怪现象：`calloc(1,1904)` 失败、`-` 标记、`M`/`x` 链断、
以及"352 KiB 空闲却分配不出 1.9 KB"这一表面矛盾。

## 负结果：+0x1000 守卫页**不够**（2026-11-19 末）

```
A348K
- M - x x x x x
AAAAAAAA            <- abort 仍在
```

⇒ 加了 4 KiB 守卫页后**块头仍被破坏** ⇒ 越界写入**超过 4 KiB**，或覆盖者**不是** `.btdm_data`。

### 由此收窄

1. 若是 `.btdm_data` 越界，量级 > 4 KiB ⇒ 应先**量出归档实际用多少**（`.btdm_data` 的真实需求）；
2. 若是别的写入者，候选是**任何写进 `[_data_end_btdm, +∞)` 的代码**：
   - 归档把某个指针当作 `.btdm_bss`/`.btdm_data` 的边界外使用；
   - 或某次 `memset/memcpy` 用越界的长度。

### 下一步（一次板测，二选一）

1. **加大守卫到 0x10000**（64 KiB）再试：若 abort 消失 ⇒ 确认是"越界但幅度有限"，
   再回头精确量出 `.btdm_data` 的真实需求并按其大小预留；
2. 若 64 KiB 守卫仍被踩 ⇒ 覆盖者是**大范围写**（例如按错误长度 memset），
   应在 `btdmMalloc` 成功后立刻校验块头（写入前后各读一次 magic），把破坏时机夹在两次分配之间。

⚠️ 这条链的价值：它把"分配失败"从一个分配器 bug，改定位为**内存被别的代码覆盖** ——
性质完全不同，修法也完全不同。

## 负结果 2：64 KiB 守卫**仍被踩** ⇒ 不是"下方小幅越界"（2026-11-19）

```
A288K
- M - x x x
abort: 1
```

⇒ 堆头再往上推 64 KiB 仍被破坏 ⇒ **覆盖者不是 `.btdm_data` 的小幅溢出**。

### 结论修正

先前"`.btdm_data` 越界写坏块头"的假设**已证伪**。剩下两类可能：

1. **大范围写入**：某处 `memset`/`memcpy` 用了极大的长度（例如按错误的结构体尺寸清零），
   一路写穿到堆头 —— 与"推多远都被踩"完全吻合；
2. **初始化顺序问题**：`Arena.init` 写的块头**随后被别人的清零**覆盖
   （例如某段 `bss` 清零循环的结束地址算错，把堆区也清了）。

### 判别（两种，都很便宜）

1. **打印 magic 的实际值**（已在 `M` 分支里，只是当前只打两位十六进制）——
   若 magic 变成全 0 ⇒ 是被清零（第 2 类）；若是别的常量 ⇒ 是被结构化写入（第 1 类）；
2. **在 `Arena.init` 之后立刻读一次 magic**，再在第一次 `btdmMalloc` 之前读一次 ——
   两次之间若变坏，破坏发生在启动到首次分配之间（范围极小，容易定位）。

⚠️ 本会话到此为止：这个判据需要一次板测，而它所需的改动我已在 `M` 分支里预留好了。

## 一个早前被误读的信号（2026-11-19）

`osal.zig:1143`：`headerMagic = 0xB7A1_0C0D`

而本 README 前文记过：「`deinit` 里读到 `a0=0xb7a10c0d` 这种垃圾，而 IDF 的堆在启动后是干净的」。

⇒ 那不是"垃圾"，**那是我们分配器的 `BlockHeader.magic`** —— 归档读到了 arena 的块头，
说明**某处指针指进了堆区**（与"块头被覆盖"是同一族问题：归档的某个指针/长度越界进入堆）。

⇒ 这条也把"垃圾数据"的判断纠正为"跨区访问"的证据。

## 完整边界符号表（`WITH_PHY=1` 实测，2026-11-19）

```
_bss_start        0x2f010d40
_bss_end          0x2f015ec0      <- **不含** .btdm_* 段（它们是独立的一组符号）
_bss_start_btdm   0x2f015ec0
_bss_end_btdm     0x2f01dec0
_data_start_btdm  0x2f01dec0
_data_end_btdm    0x2f01eec0      (= 0x2f01dec0 + 0x1000)
_heap_start       0x2f01fec0      (= _data_end_btdm + 0x1000 守卫)
_heap_end         0x2f076fc0      (= _stack_bottom)
=> 堆 = 0x57100 = 356 KiB
```

### 由这张表能读出的两件事

1. **`_bss_end` 不含 btdm 段** ⇒ 若归档的某段清零/拷贝循环用 `_bss_start.._bss_end`
   是**安全的**（不碰堆）；
2. 若有代码用 `_bss_start.._data_end_btdm` 或 `_heap_start` 作为清除终点，
   就会清零 `[0x2f015ec0, 0x2f01fec0)` 甚至堆头 —— 与 `M`（magic 变）+ `size=0`（被清零）**完全吻合**。

### 下一步（离线，`nm` 一条命令）

```bash
riscv32-esp-elf-nm -u <每个归档 .o> | grep -E "_bss_|_data_|_heap_"
```

看**归档自己**引用了哪些边界符号。若某个 `.o` 引用 `_heap_start`/`_data_end_btdm` 作为清除终点，
那就是清零循环越过边界、抹掉我们块头的直接证据；若都只用 `_bss_start/_bss_end`，则覆盖者另有其人。

## 排查：归档的 bss 清零 / data 拷贝**范围正确**（2026-11-19）

`r_sym_ble_zEWRSkDdfQbTqLJOuE4J`（`0x4000562e`，116 B）是全镜像里唯一引用 `_bss_end` /
`_bss_end_btdm` / `_data_end_btdm` 的归档函数，反汇编：

```asm
lui  a0,0x2f016 ; addi a0,a0,-320   # a0 = 0x2f015ec0 (_bss_end)
lui  a5,0x2f01e ; addi a5,a5,-320   # a5 = 0x2f01dec0 (_bss_end_btdm)
sub  a2,a5,a2                        # len = 0x8000  (32 KiB)
li   a1,0
jal  smallMemset                     # memset(0x2f015ec0, 0, 0x8000)  -> .btdm_bss
...
addi a5,a5,-320                      # a5 = 0x2f01eec0 (_data_end_btdm)
sub  a2,a5,a2                        # len = 0x1000  (4 KiB)
jal  memcpySmall                     # memcpy(0x2f01dec0, 0, 0x1000) -> .btdm_data
```

⇒ **两者的范围都精确止于 `.btdm_data` 末址（0x2f01eec0），不触及守卫页与堆** ⇒ **不是覆盖者**。

⇒ 因此"清零/拷贝越界"这一假设**也被排除**。

### 覆盖者的候选因此只剩

1. **`.btdm_bss` / `.btdm_data` 内部的越界写**（归档把某个指针当作它们末尾之后使用）；
2. **我们自己的代码**（`osal`/`probe` 里某处写越界）；
3. **canary 扫描本身尚未出数**（仪器已就位，但导出未触发），所以上述判断仍缺少直接证据。

**下一步不变**：让 canary 扫描真正落数（在 `dumpAtPend` 首行打单字节确认它是否被调用），
它给出的"首个被改写地址 + 实际值 + 字数"将直接点名上述三类中的一类。

## 找到导出长期静默的原因：**`dumpAtPend` 里有 `caller_n < 22` 门槛**（2026-11-19 末）

`probe.zig` 里其实有**两处** `dumpAtPend`，实际被注册的是第 117 行那个，它开头：

```zig
if (dump_done or osal.caller_n < 22) return;   // 而 caller_n 实测止于 21 ⇒ **永不触发**
```

⇒ 这解释了前面所有"导出了但没输出"的运行。移除门槛后：

```
D3.0            <- dumpAtPend 被调用（lc=3, caller_n=0）
```

⇒ 导出路径**已打通**（`CN`/`AM`/`CODES` 现在只受 FIFO 影响，不再被逻辑挡死）。

### 下一步（收尾项）

`CN`（canary 扫描）行仍未落数 —— 只剩 FIFO 容量问题。把 `D`/`CN` 合成**一行单字节+短数字**，
或把 `CN` 放在 `D` 之前，即可拿到：

```
CN 0x<首个被改写地址> 0x<该处实际值> <被改写字数>
```

三项合起来直接点名覆盖者（0 = 清零、`0xB7A10C0D` = 我们的块头、ASCII/代码 = 拷贝），
且能给出它写了多远 —— 这是本会话最后需要的一个读数。

## 🏁 canary 落数：堆首只有**一个合法块头**，不是破坏（2026-11-19 定论）

```
CN 0x2f01fec0 0x780 8
```

| 字段 | 值 | 解读 |
| --- | --- | --- |
| 首个被改写地址 | `0x2f01fec0` | = `_heap_start`（堆首字） |
| 该处实际值 | **`0x780` = 1920** | = `alignForward(1904+16, 8)` —— **正是 1904 请求的块大小** |
| 被改写字数 | **8**（32 B） | = 一个 `BlockHeader`（16 B）+ 数据区前 16 B |

⇒ **`Arena.alloc(1904)` 实际成功了**：它写了 `size=1920` 的块头并返回数据区指针。
⇒ 堆里**只有这一个**块头 ⇒ 归档此前那 21 次 malloc **没有落在这一版堆上**
  （它们发生在 arena 初始化之前或另一个分区），与"`caller_n` 停在 21"是一致的。

### 因此推翻两个此前的判读

1. **`M`（magic 错）+ `x`（size=0）标记** —— 是 **FIFO 丢字节/错位**造成的误读，
   不是块头损坏（canary 是绕开 UART 的直接证据，优先级更高）；
2. **"块头被覆盖"整条假设** —— **作废**（4 KiB/64 KiB 守卫实验、清零循环排查都是围绕这个假前提做的）。

### 现在的真实问题

`calloc(1,1904)` **成功了**，但 `phy_init.c` 仍然报
`"failed to allocate memory for RF calibration data"` 并 `abort`。

⇒ 那条 `ESP_ERROR_CHECK` 失败的原因**不是 `calloc` 返回 NULL**，而可能是：
- `calloc` 之后**对返回指针的其它检查**（如 IS NULL 之外的长度/属性校验）；
- 或该日志属于**另一条路径**（我们的 1904 请求只是巧合相同尺寸）。

**下一步（离线单点）**：反汇编 `0x40000650..0x4000066e` 的**条件跳转**，
看清 `abort` 前到底判的是哪个寄存器的什么条件 —— 那是本会话最后一块拼图。

## 最后一块拼图：abort 的判据是 `calloc(...) == NULL`（2026-11-19 收尾）

```asm
400005b8: jal  calloc           # calloc(1, 1904)
400005be: c.beqz a0, .L66       # a0 == NULL -> 错误路径
...
4000064a <.L66>: ... esp_log("failed to allocate memory for RF calibration data") ; abort
```

⇒ **abort 的判据就是"`calloc` 返回 NULL"**，没有别的条件。

### 与实践读数的矛盾（唯一未解）

| 证据 | 结论 |
| --- | --- |
| canary（不经过 UART） | 堆首有 **一个 `size=1920` 的块头** ⇒ 1904 的分配**成功过** |
| `c.beqz a0` 跳转 | 该次 `calloc` **返回了 NULL** |

两者只有在**"成功的 1920 分配"与"失败的 1904 请求"是不同时刻/不同请求**时才能同时成立。

**下一次唯一需要的读数**（不经过 UART，走同一套 canary 通道）：
在 `btdmMalloc` 里把 **`size` 与返回指针**存进两个 RAM 变量，由 `dumpAtPend` 一起打出 ——
那样就能看到"究竟哪一次请求、返回了什么"，而不必再依赖任何串口标记。

## 🔑 能解释全部观测的假说：**归档越界写坏了"下一块的块头"**（2026-11-19 末）

### 先纠正 canary 的一个读数陷阱

canary 扫描把每个字与图案比对，但**分配器自己会改写块头**（offset 0 的 magic/size/free）
⇒ **首个不匹配必然是分配器自己的块头**，`canary_bad_words` 也必然包含合法分配的数据区。

⇒ 因此 `CN 0x2f01fec0 0x780 8` 应读作"**恰好有一次 1920 字节的分配发生过**"，
而不是"堆被破坏"。这与 `c.beqz a0 → abort` 的矛盾因此有了出路：

### 假说（与时序完全吻合）

1. 归档先前的小分配（76/8/36/32/12…）中，**某一次写越过了自己的尾部**，
   写坏了**紧邻的下一个空闲块的 `BlockHeader`**（在 arena 内部，与堆的绝对位置无关）；
2. 块链因此在内部断裂（`hdr.size` 被改成垃圾/0）；
3. 当 PHY 要 1904 字节时，`Arena.alloc` 沿链走，**找不到可用的连续块** ⇒ 返回 NULL
   ⇒ `c.beqz a0` ⇒ `esp_log("failed to allocate…")` ⇒ `abort`。

### 为什么守卫页无效（4 KiB 与 64 KiB 都失败）

因为破坏**发生在 arena 内部**（规则的偏移处），与 `_heap_start` 在哪无关。
⇒ 这也解释了为何"把堆往上推"完全不起作用。

### 验证（一次改动，全走 RAM）

在 `Arena.alloc` 里记录每次分配的 `(ptr, size)` 到小表（≤32 项），
然后让扫描**跳过这些区间与 16 字节块头**，报告：

- 第一个"外来"字的地址与其值；
- **`该分配的 end − 该字地址` = 越界字节数**。

若外来字紧贴某次分配之后 ⇒ **确认是归档越界**，而不是散落的 memset；
修法随之明确：给该分配**留冗余**，或找到那个越界的写入者。

**在此之前，不要再根据 canary 的"首字不匹配"下任何结论** —— 那必然是分配器自己的块头。

## 最终读数：唯一一次写入在**分配之后 160 字节**（2026-11-19 定案数据）

跳过已分配区间与块头后，canary 报告：

```
CN 0x2f020740 0x56880 4
```

| 量 | 值 |
| --- | --- |
| 首个外来字地址 | `0x2f020740` = `_heap_start + 0x880`（2176 B） |
| 该处值 | `0x56880`（353 920） |
| 被写字数 | 4（16 B） |

唯一那次分配：块头 `0x2f01fec0`、数据 `0x2f01fed0`、长度 1920 ⇒ **结束于 `0x2f0206a0`**。
`0x2f020740 - 0x2f0206a0 = 0xA0 = **160 字节**`。

⇒ 有人在**分配区之后 160 字节**处写了 16 字节，值是 `0x56880`（看起来像一个**长度或地址片段**）。

### 判读（如实）

- 这**不是**"紧贴分配末尾 1~4 字节的溢出" ⇒ 不是典型的"少写一个字节"；
- 160 字节的偏移 + 16 字节的写入 + `0x56880` 这个量级 ⇒ 更像**某个结构体被写到了错误的位置**
  （例如某个指针算错，把一块结构体/数组写进了堆的空闲区）；
- 该值 `0x56880 = 353 920` 恰好接近**堆的字节数（356 KiB）** ⇒ 可能是某个**长度字段**被写到了那里。

### 下一步（明确）

1. 把这个地址 `0x2f020740` 与 `0x56880` 拿去和归档的**结构体布局**对照：
   哪个对象的字段是"长度 ≈ 356 KiB"、且它距自己起点约 160 字节 —— 那就是写错位置的结构体；
2. 或直接在 `alloc` 里对**小块请求**（≤ 256 B）多留 192 字节冗余，
   看 abort 是否消失 —— 若是，则确认是某次小分配的越界写，冗余即可规避。

## 🏁 定论：**没有溢出**，堆数据完好（2026-11-19 最终）

dump 分配结束（`0x2f0206a0`）之后的 32 个字：

```
W cafe06e0,cafe06e4,cafe06e8,cafe06ec,cafe06f0,…,cafe0714,…
```

⇒ **canary 图案完整连续**（偏移递增正确）⇒ 1904 字节的缓冲区**没有被越界写**。

### 因此三条结论同时成立

1. **`Arena.alloc(1904)` 成功**（块头 `size=1920` 在堆首）；
2. **没有缓冲区溢出**（其后 128 字节 canary 完好）；
3. `0x2f020740` 处那 16 字节（值 `0x56880`）是**孤立的一次结构化写入** ——
   某个结构体被写到了错误地址，而非溢出。

### 由此推翻的最后两条假设

| 假设 | 状态 |
| --- | --- |
| "PHY 写入超 1904 字节" | **否证**（canary 完好） |
| "块链被越界写坏导致后续分配失败" | **无证据**（链在分配后未被破坏） |

### 现在的准确矛盾

`calloc(1,1904)` 的**第一次调用成功**（堆里有块头），但 `0x400005be` 的 `c.beqz a0` **跳进了错误路径**。

⇒ 唯一自洽的解释：**存在第二次 `calloc`**（或第一次的返回值在到达检查前被覆盖），
而它失败 —— 但 `alloc_recs` 只记录了 1 次成功，说明**第二次请求从未成功过**。

**下一步**：把 `alloc_recs` 的内容（每次的 `ptr/len`）与 `btdmMalloc` 的**调用次数**一起导出 ——
若调用 2 次而成功 1 次，就锁定了"第二次请求为何失败"（看它的 size）。

## 🔴 最终矛盾（全部数字到位，2026-11-19 终止点）

```
MC 1 sz=1904 ret=0x0        <- 只调过 1 次 btdmMalloc；请求 1904；返回 NULL
CN 0x2f01fec0 0x780 8       <- 堆首有 size=0x780(1920) 的块头
W cafe06e0,…                <- 其后 canary 完好（无溢出）
```

| 事实 | 值 |
| --- | --- |
| `btdmMalloc` 调用次数 | **1** |
| 该次请求 | **1904** |
| 返回值 | **NULL** |
| 堆首块头 `size` | **1920**（= `alignForward(1904+16, 8)`） |
| 分配后 canary | **完好** |

### 三条事实无法同时成立 —— 除非

`Arena.alloc` 在**写了 `hdr.size = need` 与 `free = false` 之后、返回之前**就失败了。
该函数里唯一可能的分支是 `recAlloc` 与 `return` 之间 —— 两者之间没有可失败的操作。

⇒ **因此问题不在 `Arena.alloc` 的逻辑，而在"返回值传递"这一环**：
`s31_btdm_malloc`（8 字节 thunk）→ `calloc` 的 `beqz a0` 之间，
寄存器 `a0` 可能被覆盖（例如 thunk 用了 `auipc t1` 之后 `a0` 未被正确保留，
或 `calloc` 的 `mul`/`mv` 在优化后与 thunk 的调用约定不符）。

**下一步（离线，10 分钟）**：反汇编 `calloc` 的完整 46 字节 + `s31_btdm_malloc` 的 8 字节，
逐条确认 `a0` 在 `jalr` 前后是否被正确保留 —— 这是本会话唯一还没逐条核对过的调用约定。

## ⚠️ 我的仪器有 bug：`ret=0x0` 是**未赋值**的初值（2026-11-19 最后一条）

`btdmMalloc` 里的顺序是：

```zig
const r = bt_arena.alloc(size, 8);
if (size == 1904) { if (dump_hook) |f| f(); }   // <- dump 在此触发
...
last_ret = if (r) |v| @intFromPtr(v) else 0;    // <- 赋值在此之后
```

⇒ **dump 在 `last_ret` 赋值之前执行**，读到的是初值 `0`。

⇒ 因此 `MC 1 sz=1904 ret=0x0` 里的 `ret=0x0` **不是"返回 NULL"的证据**，
   只是"记录变量还没被写"。

### 这条纠正推翻了什么

| 之前 | 现在 |
| --- | --- |
| "`calloc` 返回 NULL ⇒ abort" | **无证据**：`last_ret` 读数无效 |
| "分配器成功但返回值丢失" | 也**无证据**：分配器可能正常返回，问题在 `calloc` 之后的判断 |

### 与 canary 的一致性

canary 显示块头 `size=1920` 且其后 canary 完好 ⇒ **分配确实成功、且无溢出**
⇒ 与"`last_ret` 读数无效"完全一致。

### 下一步（一处改动）

把 `last_ret = ...` **移到 `dump_hook` 之前**，并在 `calloc` 里记录 `beqz a0` 前一瞬的 `a0`
（用 RAM 变量），一次运行即可判定：

- `a0` 非 0 却仍进错误路径 ⇒ `beqz` 的对象不是它 / 控制流另有来源；
- `a0` 为 0 而分配器返回非 0 ⇒ 传递链（thunk/calloc）有问题。

## 🏁 算术定论：canary 的"外来写"就是**分配器自己的余块头**（2026-11-19 终）

```
堆总量              = 0x57100
外来字位置           = _heap_start + 0x880
外来字的值           = 0x56880
0x57100 - 0x880      = 0x56880   ← **完全相等**
```

⇒ 那个"外来写入"就是 `Arena.alloc` 走 `used >= need + min_block` 分支时写的
**剩余空闲块头**（`rest_hdr` 在 `addr + need`，`size = 总量 - need`，`free = true`）。

⇒ **canary 报告的"4 个字被改写" = 1 个 `BlockHeader`（16 B）= 合法结构，不是破坏。**

### 于是全部观测终于自洽

| 观测 | 解释 |
| --- | --- |
| 堆首 `size=0x780`(1920) | **第一次**分配（need=1920）的块头 |
| `heap+0x880` 处 `size=0x56880` | **另一个** need=0x880(2176) 分配的余块头 |
| canary 完好 | 没有溢出 |
| `ret=0x0` | **我的仪器 bug**（在赋值前读取） |

⇒ 两次分配**都成功**；堆**完全正常**。

### 因此 abort 的真因仍未定位，但范围已缩到一处

`0x400005be: c.beqz a0, .L66` 的 `a0` 来自 `0x400005b8: jal calloc`。
既然 `calloc` → `btdmMalloc` 成功，那么 `a0` 非 0 ⇒ **不应跳转**。

⇒ **需要确认反汇编的是不是同一份构建**：`0x40000580` 的 `esp_phy_load_cal_and_init`
在 default 构建里是别的函数（本会话已多次踩到地址漂移）。

**下一步（唯一）**：在**当前**镜像上 `readelf` 取 `esp_phy_load_cal_and_init` 的
`st_value`，反汇编它的 `calloc` 调用点与后续 `beqz`，确认请求大小与判据寄存器。

## 🏁 分配**成功**：`ret=0x2f01ffd0`（2026-11-19 定论）

修正仪器（把 `last_ret` 赋值移到 dump 之前）后：

```
MC 1 sz=1904 ret=0x2f01ffd0
```

`0x2f01ffd0 = _heap_start(0x2f01fec0) + 0x110` ⇒ **有效指针，非 NULL**。

⇒ **`calloc(1, 1904)` 成功返回** ⇒ `0x400005be: c.beqz a0` **不会跳转**。

### 因此整条"分配失败"线作废

| 之前的结论 | 现在的证据 |
| --- | --- |
| `calloc` 返回 NULL ⇒ abort | **否证**：返回 `0x2f01ffd0` |
| 堆太小 / 块头被覆盖 / 溢出 | 全部已逐一否证（356 KiB、canary 完好、余块头合法） |

⇒ **abort 来自另一处 `abort` 调用**，而不是 `0x4000066e` 那个"分配失败"分支。

### 下一步（当前镜像上重新定位）

1. 在**当前** ELF 上 `readelf -sW | grep abort` 取 `abort` 的 `st_value`；
2. 反汇编该 `abort` 的所有调用点（`objdump -d | grep "<abort>"`），
   逐个看其前面的条件 —— 找到真正被走到的那个；
3. 或在 `abort` 桩里打印 `__builtin_return_address(0)`（当前它只打 `AAAAAAAA`），
   一次运行即可指出**直接调用者地址**。

**第 3 条最省事**：abort 桩已有，只需把 `ra` 写进 RAM（不是 UART）并由导出打出。

## 最新读数：分配持续成功，abort 在 15 s 内未发生（2026-11-19 末）

```
AB 0x0                              <- abort 桩从未被调用（返回地址变量仍为初值）
MC 1 sz=1904 ret=0x2f020010         <- 分配成功，返回有效指针
```

多次运行中 `ret` 分别为 `0x2f01ffd0` / `0x2f020010`（均非空）⇒ **分配稳定成功**。

⇒ 此前的 `AAAAAAAA` 可能来自**更早的构建**（当时 abort 桩会写 'A'），
   而在当前配置下 abort 在 15 秒抓取窗口内**没有发生**。

### 需要确认的两件事（下一轮）

1. **抓取窗口是否够长**：`AAAAAAAA` 曾出现在 20 s 抓取里，本轮只有 15 s；
   先用 30 s 抓一次，确认 abort 是否仍出现；
2. **`probe_dump_now` 是否真的从 C 侧可调用**：`AB 0x0` 说明 abort 没跑，
   若 30 s 后仍 `AB 0x0` 但串口出现 `AAAAAAAA` 之外的停机，则说明走的是**另一条** abort 路径
   （例如 libc 的 `abort`，不是 `phy_stubs.c` 里我们覆盖的那个）。

### 已确立的事实（不再变动）

| 项 | 状态 |
| --- | --- |
| 堆 | 356 KiB，边界正确，无重叠 |
| 分配器 | 工作正常：1904 请求返回有效指针，块链合法，无溢出 |
| abort（PHY 路径） | 在当前配置下**未复现** |

## 🏁 最终澄清：abort **确实被调用**；`AB 0x0` 是 RA 取不到（2026-11-19 终）

30 s 抓取：

```
AB 0x0                              <- g_abort_ra 为 0
MC 1 sz=1904 ret=0x2f020010         <- 分配成功（有效指针）
pcsample n=14592 pc=0x400670a4 ra=0x400670a4
```

而 `0x400670a4` 落在 **`abort` 符号内**（`0x40067090`，size 34）—— 正是它的自旋段。

⇒ **abort 被调用了**（PC 在它的死循环里）。
⇒ `AB 0x0` 的原因：`__builtin_return_address(0)` 在 **无帧指针的 ReleaseSmall 构建下返回 0**
   （GCC 文档：`-fomit-frame-pointer` 时该内建可能返回 0）。

### 因此当前状态（准确）

| 项 | 结论 |
| --- | --- |
| 分配 | **成功**（`ret=0x2f020010`，多次运行一致） |
| abort | **仍被调用**（PC 在其自旋循环内） |
| `AB 0x0` | **不是"没调用"**，是 RA 不可得 |

### 取到真实调用者的两种办法

1. **`abort` 桩用汇编直接读 `ra`**（Zig 的 `asm volatile ("mv %[v], ra")`，不依赖帧指针）；
2. 或在 `abort` 桩里**把地址 0x400005be 之类的候选逐个比对**：
   既然分配成功，`0x400005be` 的 `c.beqz a0` 不该跳 —— 说明**当前构建里 abort 的调用点是别处**，
   需要在**当前**镜像上 `objdump -d | grep "<abort>"` 列出所有调用点。

**第 2 条最快**：一条 grep 就能列出当前构建的全部 abort 调用点及其前置条件。

## ~~🏁 真正的 abort 点：`esp_phy_get_init_data` 返回垃圾~~ —— **本节已被推翻**

> ⚠️ **作废**：后面的 AB 读数为 `0x40000672` = **`0x4000066e`（calloc 返回 NULL）的返回地址**，
> 而不是 init-data 那条（`0x40000690`）。下表保留仅作过程记录。

### 原分析（已被推翻，供参考）

当前镜像里 `esp_phy_load_cal_and_init` 的完整判据链：

```asm
400005b8: jal  calloc                    # calloc(1,1904) -> 实测成功（ret=0x2f020010）
400005be: c.beqz a0, .L66                # 若 NULL -> "failed to allocate"（站点 1，未命中）
400005c0: c.jal esp_phy_get_init_data    # **调用前没有设置 a0**
400005c4: c.beqz a0, .L67                # 若 0 -> "failed to obtain PHY init data"（站点 2）
400005d6: c.jal esp_phy_load_cal_data_from_nvs
400005da: c.bnez a0, .L68
```

而 thunk 本体（`0x40000414`，10 字节）是：

```asm
addi a0,a0,-17      # 预期 a0 = 0x40105000 ⇒ 得到 &phy_init_data = 0x40104fef
c.jr ra
```

⇒ **它依赖调用者把 `a0` 预置成 `0x40105000`**（这是 `lui`+`jal` 的 PC 相对惯用法），
   但调用点用的是 `c.jal`（**不设置任何参数**）⇒ `a0` 保持 `calloc` 的返回值
   ⇒ `a0 - 17` = 一个堆地址附近的垃圾值。

⇒ 只有当那个垃圾值恰好为 0 时才走 abort；否则后续逻辑拿到的是**错误指针**。

### 结论

**这是 blob 与我们的桩之间的调用约定不匹配**：
`esp_phy_get_init_data` 在 IDF 里由 LTO/内联展开，`a0` 由编译器预设；
我们的镜像把它当普通函数调用，**预设丢失**。

**修法（一处）**：在 `phy_stubs.c` 里**提供我们自己的 `esp_phy_get_init_data`**，
直接返回仓里那张静态表的地址（`0x40104fef` 或我们自备的 128 字节），
覆盖掉那个依赖 `a0` 的 thunk。

## 最后一项仪器修正：abort 时段的导出被 `dump_done` 挡掉（2026-11-19 终）

现状：

- dump 在 `btdmMalloc(1904)` 时触发（**abort 之前**）⇒ 那时 `g_abort_ra` 必然是 0；
- abort 桩里虽调用了 `probe_dump_now()`，但 `dumpAtPend` 开头有 `if (dump_done) return;`
  ⇒ **第二次（abort 时刻）导出是空操作**。

⇒ 所以 `AB 0x0` 只是"第一次导出时 abort 还没发生"，与调用约定无关（RA 已改用
`__asm__ volatile ("mv %0, ra")`，入口处 `ra` 一定有效）。

**修法（两行）**：
1. `probe_dump_now()` 里先把 `dump_done = false;` 再调 `dumpAtPend()`；
2. 或给 abort 路径单独一个不检查 `dump_done` 的导出函数。

之后一次运行即可从 `AB 0x<addr>` 拿到**真实的 abort 调用者**，
与本文件的调用点清单（当前镜像只有两处：`0x4000066e` / `0x40000690`）对照即定案。

## 🏁 abort 的真实调用者：`0x4000066e`（2026-11-19 定案）

修正 `probe_dump_now`（清 `dump_done`）+ 汇编读 `ra` 后：

```
AB 0x0              <- 分配时刻的第一次导出（那时 abort 尚未发生）
AB 0x40000672       <- abort 时刻的导出 = **调用者返回地址**
```

`0x40000672 = 0x4000066e + 4` ⇒ abort 来自 **`0x4000066e`**。

而该处正是：

```asm
400005b8: jal  calloc              # 本次请求 1904
400005be: c.beqz a0, .L66          # a0 == NULL 才跳
...
4000066e: jal  abort               # <- 命中这里
```

⇒ **某一次 `calloc` 确实返回了 NULL**，尽管前面观测到的那次（`ret=0x2f020010`）成功了。

### 结论：存在**多次** `calloc`

第一次成功后，后续某次失败 ⇒ 分配器在**连续多次分配**后无法再满足请求。
这与"canary 只看到一个块头"并不矛盾 —— 那次 dump 发生在**第一次分配时**，
其后的分配没有记录。

**下一步（明确）**：把 `malloc_calls` 与每次的 `(size, ret)` 记录进一个小表（≤16 项），
在 **abort 时刻**导出 —— 就能看到"第几次、多大、失败"。

⚠️ `phy_domain_enable` 已恢复为 `false`（README 基线），推进实验需显式改源码重建。

## 🏁 定论：**186 次分配耗尽/碎片化 356 KiB 堆**（2026-11-19 终）

```
MC 186 sz=1904 ret=0x0          <- 第 186 次请求（1904）失败，返回 NULL
CN 0x2f020780 0x780 73568       <- 73568 字 ≈ **294 KB** 已被改写
```

⇒ 归档在 PHY 校准之前**已经做了 185 次分配**，占用约 **294 KB**；
第 186 次（1904 B）时堆**已无足够的连续空间** ⇒ 返回 NULL ⇒ `0x4000066e` ⇒ abort。

### 这条修正了什么

| 先前判断 | 现在 |
| --- | --- |
| "356 KiB 很充裕，1.9 KB 不可能失败" | **错**：185 次分配已吃掉 294 KB |
| "分配器有 bug" | **错**：分配器工作正常，是**容量真的不够** |
| "canary 只看到一个块头" | 那是**第一次**分配时 dumps 的（当时只有 1 个块） |

### 修法（两条，按优先级）

1. **扩大 SRAM 窗口 / 减小栈预留**：`sram LENGTH = 0x7AFC0`，栈 16 KiB；
   若硬件允许把 `LENGTH` 加大，或把栈降到 8 KiB（需先确认最深调用链），
   即可多出数十 KB —— 足以覆盖 PHY 校准的 1.9 KB 与后续分配；
2. **减少归档的分配次数**：185 次分配中若有可合并/可预分配的，能显著降低峰值。

### 验证

改完重跑，判据：`MC` 行的 `ret` 非 0（且 `AB` 不再出现）。

## 🏁 最终定论：容量不足 + 栈不可再减（2026-11-19 终）

### 决定性数据

```
AB 0x40000672 free=944       <- abort 时刻堆仅剩 944 字节
请求                         = 1904 字节  ⇒ **确实放不下**
```

⇒ **不是碎片化、不是分配器 bug —— 是容量真的不够。**

### 两次尝试（都做了实测）

| 尝试 | 结果 |
| --- | --- |
| 回收 4 KiB 守卫页 | `free` 944 → **1200**，仍不足（归档几乎吃满） |
| 栈 16 KiB → 8 KiB | **栈溢出**：`mepc=0x00000000` + `instruction access fault`（返回地址被破坏）⇒ **不可减** |

⇒ 栈已回退 16 KiB；守卫页保持回收状态（`_heap_start = _data_end_btdm`）。

### 剩余的两条路（都不在"调参数"范围内）

1. **扩大 SRAM 窗口**：`sram LENGTH = 0x7AFC0`（490 KB）。
   需确认 ESP32-S31 实际 SRAM 上限（硬件手册），当前值可能是保守取值；
2. **减少归档的分配次数**：185 次分配占用 ~294 KB，若能合并/预分配即可腾出所需 1.9 KB。

### 当前可交付的状态

- **崩溃已修**（`anchor[8]` 自伤预发布）
- **归档推进到 PHY 校准**（域时钟突破：心跳 320 → 9728+）
- **堆与分配器验证健康**（356 KiB、无溢出、块链合法、`free` 读数准确）
- **abort 精确到 `0x4000066e`**（calloc 返回 NULL），原因是 **free=944 < 1904**

## 分配器拓扑与"是否真的耗尽"（2026-11-19 收尾）

### 镜像里只有**一个**分配器

```
calloc  @ 0x40067022 (46 B)  ->  s31_btdm_malloc (8 B thunk)  ->  osal.btdmMalloc -> bt_arena
free    @ 0x40067050 ( 8 B)  ->  s31_btdm_free                ->  osal.btdmFree  -> bt_arena.freeRaw
```

**没有** `malloc` / `heap_caps_malloc` / `_sbrk` ⇒ 归档的所有分配都走我们的 arena。
⇒ 因此 `free=944` 确实是**唯一堆的剩余**，不存在"第二个看不见的堆"。

### 但 `freeRaw` **不做相邻合并**

```zig
pub fn freeRaw(self: *Arena, ptr: ?*anyopaque) void {
    ... hdr.free = true;          // 只置标志，不与相邻空闲块合并
}
```

⇒ 若归档有 free 动作，释放的空间会被**割裂**，无法满足 1904 的连续请求。

### 两个判据（还需一次板测，二者都很便宜）

| 判据 | 含义 |
| --- | --- |
| `free=944` 但**最大单块** ≥ 1920 | **碎片化** ⇒ 给 `freeRaw` 加合并即可 |
| `free=944` 且最大单块 < 1920 | **真耗尽** ⇒ SRAM 上限所限，只能减少分配或扩窗 |

`arenaFree()` 已经给出 944（= 所有空闲块之和）；还缺**最大单块**这一个数。

**下一步（一行）**：在 `Arena` 里加 `largestFree()`（遍历取 `max(hdr.size)`），
与 `arenaFree()` 一起在 abort 时刻打出。

## 🏁 SRAM 上限已由 IDF 自己的链接脚本确认（2026-11-19 终）

`firmware/idf-bootstrap/build/esp-idf/esp_system/ld/memory.ld` 声明：

```
sram_seg : org = 0x2F000000, len = 0x7AFC0     <- 与我们用的窗口**完全相同**
```

⇒ **没有更多 SRAM 可用** ⇒ "扩大 sram 窗口"这条路**关闭**。
⇒ 因此"堆不够"不能靠扩窗解决，只能**减少需求**或**把缓冲搬到别处**。

### 但存在 PSRAM

同文件里另有 `extern_ram_seg`（`0x50000000` 段）。若该 PSRAM 在本板可用，
PHY 校准那 1904 字节可直接从 PSRAM 分配，而不占 SRAM 的 arena。

### 两条可行的下一步（按成本排序）

1. **实现 `freeRaw` 的相邻合并**（约 10 行）：若归档在失败前 free 过缓冲区，
   合并后即可回收那缺失的 ~1 KB。这是**最可能真实有效**且改动最小的方案；
2. **把大块搬到 PSRAM / `.btdm_bss`**：给 PHY 校准单独一个 1904 字节的静态缓冲
   （`.btdm_bss` 预留 32 KiB，或 PSRAM），不走共享 arena。

### 同时确认的数据（不变）

| 项 | 值 |
| --- | --- |
| arena 总 | 356 KiB |
| abort 时刻 `free` | 944 B < 请求 1904 B |
| 分配器拓扑 | 单一（`calloc` → `s31_btdm_malloc` → arena） |
| 栈 | 16 KiB（8 KiB 实测栈溢出，不可减） |

## 🏁 终局：**真耗尽**（只有一个空闲块，1200 < 1920）（2026-11-19 定案）

```
AB 0x40000672 f=1200 L=1216
```

| 量 | 值 | 含义 |
| --- | --- | --- |
| `f` = `arenaFree()` | **1200 B** | 所有空闲块之和（已扣块头） |
| `L` = 最大单块 `hdr.size` | **1216 B** | 含 16 B 块头 ⇒ 载荷 1200 |
| 请求 need | **1920 B** | 1904 + 16 |

⇒ **`f ≈ L`** ⇒ 空闲区**基本就是一个块** ⇒ **不是碎片化**。
⇒ **1200 < 1920** ⇒ **真耗尽**。

### 因此三条修法的判定

| 方案 | 判定 |
| --- | --- |
| `freeRaw` 加合并 | **无效**（只有一个空闲块，无可合并对象） |
| 扩大 SRAM 窗口 | **不可行**（IDF `memory.ld` 确认 `sram_seg` 已是全部 0x7AFC0） |
| 减小栈 | **不可行**（8 KiB 实测栈溢出） |
| **给 PHY 校准一块专用缓冲** | **唯一可行** —— 从 `.btdm_bss`（预留 32 KiB）或 PSRAM（`0x50000000`）静态分配 |

### 这条线的完整因果链（全部有实测支撑）

```
BLE controller 卡在 init
  → [修] anchor[8] 自伤预发布 → 归档开始推进
  → [突破] PHY 域时钟 → 总线停摆消失（心跳 320 → 9728+），进到 step 6
  → [定位] abort = 0x4000066e（calloc 返回 NULL），调用者 RA = 0x40000672
  → [量化] abort 时刻 free=1200、最大单块 1216、请求 1920
  → [定案] 真耗尽：185 次分配吃掉 355 KB，SRAM 上限已到
  → [修法] 给 PHY 校准一块 1904 B 的专用缓冲（.btdm_bss 或 PSRAM）
```

## 🏁 最后一条实测：归档会吃光给它的**任何**空间（2026-11-19 终）

把 `.btdm_data` 从 4 KiB 减到 2 KiB（多给堆 2 KiB）后：

```
AB 0x40000672 f=1328 L=1344
```

`free` 只从 **1200 → 1328**（+128，而不是 +2048）。

⇒ **归档是"有多少用多少"**：给它的空间越多，它分配得越多，耗尽点几乎不动。

⇒ 因此**任何"多给一点堆"的方案都无效**（无论是扩窗、减栈、还是回收保留段）。

### 唯一有效的修法

**给 PHY 校准的 1904 字节一块专用缓冲**，不参与共享 arena 的竞争：

| 方案 | 做法 |
| --- | --- |
| **A（推荐）** | 在 `phy_stubs.c`/`porting.zig` 里放一个 2048 字节静态数组，提供一个 `calloc` 的**专用分支**：当 `nmemb*size == 1904` 时直接返回该缓冲的首地址 |
| B | 若 PSRAM 确在本板可用，从 `0x50000000` 分配（需确认 PSRAM 存在与缓存属性） |

方案 A 只改一处、不依赖任何外部条件，且判据明确：`MC` 的 `ret` 非 0 且 `AB` 消失。

### 这条线的完整结论

```
崩溃已修 → 归档推进到 PHY 校准（域时钟突破）→ abort = calloc 返回 NULL
→ free=1328 < 1920 → 真耗尽 → 归档"有多少用多少" → 唯一修法：专用缓冲
```

## ✅ 排除"测量被截断"：块链完好、走到了堆尾（2026-11-19 终验）

为回应"`bytesFree` 可能在 magic 不匹配处中断、从而低估空闲"的怀疑，给遍历加了三个计数：

```
AB 0x40000672 f=1200 L=1216 nb=188 st=0x2f076fc0
```

| 量 | 值 | 含义 |
| --- | --- | --- |
| `nb` | **188** | 遍历到的块数（与 ~187 次分配吻合） |
| `st` | **0x2f076fc0** | = `_heap_end` ⇒ **走到了堆的末端，没有提前中断** |
| `f` / `L` | 1200 / 1216 | 真实空闲量 / 最大单块 |

⇒ **块链完好**，`f=1200` 是**真实**值。

### 因此 "真耗尽" 是**已验证的结论**

```
arena 356 KiB  →  188 个块填满  →  abort 时仅剩 1200 B  →  请求 1920 B 失败
```

### 唯一有效的修法（不改产品逻辑，只加一块缓冲）

在 `phy_stubs.c` 里提供一个 2048 字节静态数组，并让 `nfs`/`calloc` 在
`nmemb*size == 1904` 时**直接返回该缓冲**，不进入共享 arena。

判据：`MC` 的 `ret` 非 0、`AB` 消失、`bt phy: domain clocks on` 之后出现新进展。

## 🎉 修法生效：abort 消失，进入 ROM 代码（2026-11-19 最终成果）

在 `phy_stubs.c` 给 `n*sz == 1904` 的请求提供**专用静态缓冲**（2048 B，16 字节对齐，不参与共享 arena）：

```c
static unsigned char g_phy_cal_buf[2048] __attribute__((aligned(16)));
void *calloc(size_t n, size_t sz) {
    size_t total = n * sz;
    if (total == 1904) { /* 清零后返回 g_phy_cal_buf */ }
    ...
}
void free(void *p) { if (p == g_phy_cal_buf) return; ... }
```

板测（`WITH_PHY=1`，815 232 B）：

```
（**没有** AB 行 —— abort 不再发生）
pcsample n=9728 pc=0x2f826484 ra=0x2f826478 s0=0x1
```

| 项 | 之前 | 现在 |
| --- | --- | --- |
| abort | 每轮必现 | **消失** |
| PC 位置 | `abort` 自旋（`0x400670a4`） | **ROM `0x2f826484`** 的紧密循环 |
| 状态 | 停在 PHY 校准的内存分配 | **PHY 校准继续执行，进入 ROM 例程** |

⇒ **PHY 校准真正跑起来了**，进入 ROM 中的 RF/PHY 例程。

### 这条线的完整因果链（每步有实测）

```
BLE controller 卡在 init
  → [修] anchor[8] 自伤预发布                → 归档开始推进
  → [突破] PHY 域时钟（含 I2C_MST_FO）        → 总线停摆消失（心跳 320 → 9728+）
  → [定位] abort = 0x4000066e（calloc NULL）  → RA = 0x40000672
  → [量化] free=1200、最大单块 1216、请求 1920、188 块走到堆尾 ⇒ 真耗尽
  → [实证] 归档"有多少用多少"（多给 2 KiB 只涨 128 B）
  → [修法] 专用缓冲（不参与共享 arena）        → **abort 消失，进入 ROM**
```

### 下一步

PC 在 ROM `0x2f826484` 的紧密循环（`ra` 就在旁边）⇒ 需确认是：
- ROM 的正常忙等（如 PLL 锁定 / 校准等待）⇒ 继续观察更长时间；
- 或另一处卡点 ⇒ 用采样分布在 ROM 内定位，再对照 IDF 的 PHY 校准流程。

## ✅ 40 秒验证：abort 彻底消失，PHY 校准在多个 ROM 例程间执行（2026-11-19 收尾）

```
AB 行数: 0                       <- 40 秒内**一次 abort 都没有**
pc=0x2f828a64  ×16
pc=0x2f826484  ×16
pc=0x2f828a78  ×13               <- 分布在 3 个不同 ROM 地址
```

⇒ **不是卡在单一自旋**，而是在多个 ROM 例程间推进 ⇒ **PHY 校准真正在执行**。
⇒ "abort 只是推迟到下一次分配"这一预期**未发生**。

### 本次会话的最终成果

| 阶段 | 成果 |
| --- | --- |
| 崩溃 | `anchor[8]` 自伤预发布 → **已修** |
| 总线 | PHY 域时钟（含 `I2C_MST_FO`）→ **停摆消失**（心跳 320 → 9728+） |
| 分配 | 归档吃满 356 KiB arena（188 块、走到堆尾）→ **真耗尽**（已实证） |
| abort | `calloc(1,1904)` 返回 NULL → **专用缓冲修复** |
| 现状 | **PHY 校准在 ROM 中执行，40 秒无 abort** |

### 下一阶段的方向

PHY 校准在 ROM 里跑（`0x2f82xxxx`），需观察它最终**收敛到哪里**：
- 若校准完成后回到归档并继续 → 下一步是 `task_init` 之后的流程；
- 若长时间停在 ROM → 用采样分布对照 IDF 的 PHY 校准阶段定位。

## ⚠️ 成功的**准确**含义（重要限定，2026-11-19 收尾）

修法是**按请求尺寸**分流的（`n*sz == 1904` ⇒ 专用缓冲）。因此：

| 已证明 | 未证明 |
| --- | --- |
| **PHY 校准路径确实在执行**（40 秒 0 abort，采样落在 3 个不同 ROM 例程） | **BLE bring-up 完整走通** |
| 那个 1904 的分配不再失败 | 归档的**其它**分配仍走共享 arena（修前已被填满：188 块、free=1200） |
| | **下一次**其它尺寸的分配失败时，会在同一点（`0x4000066e`）再次 abort |

⇒ "verified" 在此处 = **校准开始运行**，不是"问题解决"。

### 持久修法（真正的目标）

归档的工作集约 **350 KB**，而 SRAM 全部只有 490 KB（IDF `memory.ld` 确认窗口 `0x7AFC0`）。
因此持久方案必须是**给归档的工作集分配它自己的内存区**，而不是共享 arena：

| 方案 | 说明 |
| --- | --- |
| A | 把 `.btdm_bss`(32 KiB) + `.btdm_data`(4 KiB) 之外的区域也划给归档的 arena（即把我们自己的 arena 与归档工作集分区） |
| B | 若 PSRAM 在本板确实可用（`extern_ram_seg 0x50000000`，**尚未验证**），把归档的大块分配搬到 PSRAM |

### 仍未验证的两点（下一轮）

1. `calloc` 返回的指针是否**确实**是那个 `.bss` 静态数组（`MC` 行的 `ret` 应落在 `g_phy_cal_buf` 的地址上）；
2. 校准最终**收敛到哪里**（ROM 多点采样是进展，但需确认它最终返回归档或停住）。

## 🔴 撤回："40 秒 0 abort" 不能作为证据（2026-11-19 最后一次自我纠正）

专用缓冲让 `n*sz == 1904` 的请求**绕过 `btdmMalloc`**，而 dump 的触发点就在 `btdmMalloc` 里
⇒ **dump 再也没有执行过**。

核查 pc133（40 秒抓取）：

```
dump 行（AB/MC/CN）: 0 条
"domain clocks on"  : 也没有
```

⇒ **`AB` 缺席证明的是"dump 没跑"，不是"没有 abort"。**

⇒ 因此 "PHY 校准在 ROM 中执行、40 秒无 abort" 这一**结论撤回**。
   ROM 采样（`0x2f82xxxx` 三个地址）仍然真实，但它可能发生在**任何**阶段之后，
   包括 abort 之后（abort 桩自旋本身就会产生采样）。

### 正确的验证方式（下一轮）

把 dump 的触发点从 `btdmMalloc` 改到**与分配无关的位置**，例如：
- `abort` 桩里（已有 `probe_dump_now`，但需确认它真的被调到）；
- 或在 ROM 采样点上加一个"已进入校准"的标志字节。

**判据**：`AB` 行**出现**（证明 abort 发生）或 **`domain clocks on` + 新标记出现**（证明流程推进）。
在没有这两者之前，任何"abort 消失"的说法都不成立。

⚠️ 这一条与本会话反复出现的教训完全同源：**缺输出 ≠ 没发生**。

## 最后状态：判据仍然模糊（2026-11-19 终止点）

加了两个单字节标记（`C` = 专用缓冲被服务、`A` = abort 进入）后：

```
^AB 行数: 0
（原始 A/C 字节与日志文本混在一起，无法可靠区分）
```

⇒ **仍然无法判定** abort 是否发生：
- 若没发生 ⇒ 专用缓冲的修复有效；
- 若发生但输出被 FIFO 丢弃 ⇒ 修复无效。

### 已知的有效手段（下一轮直接用）

单字节标记**必须用不可打印字符**（如 `\x01`/`\x02`）或**成对定界**（`[C]`/`[A]`），
否则与日志文本混淆 —— 这是本轮踩到的最后一个坑。

### 本会话最终的已验证结论（不变）

```
[已证] 崩溃根因 = anchor[8] 自伤预发布（开关对照）
[已证] 总线停摆 = 缺 PHY 频域时钟，含 BLE 专属 I2C_MST_FO（心跳 320 → 9728+）
[已证] 分配器健康、arena 真耗尽（188 块 / 走到 _heap_end / free=1200 < 1920）
[已证] abort 调用点 0x4000066e（RA=0x40000672，汇编读 ra）
[已证] 归档"有多少用多少"（多给 2 KiB 只涨 128 B）
[待证] 专用缓冲是否消除 abort（需不可打印标记或 RAM 导出）
```

### 潜在缺陷（未验证，但需要记住）

专用缓冲对**所有** `n*sz == 1904` 的请求返回**同一块**静态缓冲：
若校准路径请求两次（两个 PHY 模块或重试），两个指针会**别名**，后者静默破坏前者。
⇒ 下一轮应改为 **4 槽轮转的小池**，并记录服务次数。

## 🔴 "没有 AB 行" 的真正原因：**`W` 行超过 FIFO 容量**（2026-11-19 终）

排查发现 `dumpAtPend` 里的 `W` 行一次打印 **32 个 32 位字**（约 **200+ 字节**），
而 TX FIFO 只有 **128 字节且不排空**。

⇒ 该行**自己就超出容量**，它之后的**所有**输出（`AB` / `MC` / `CN` / `M`）**必然被丢弃**。

⇒ **这完整解释了此前所有"AB 行消失"的观测** —— 与 abort 是否发生**无关**。

### 正确的导出预算（下一轮照此实现）

| 顺序 | 内容 | 长度 |
| --- | --- | --- |
| 1 | `AB 0x<ra>` | ~16 B |
| 2 | `<C>` / `<A>` 标志（放**心跳**里，每 64 tick 重复） | 3 B |
| 3 | 其余（`MC`/`CN`/`M`）**全部删掉或改成 RAM 记录** | — |

**合计 < 60 字节**，一次即可完整落地。

### 本轮教训

**仪器的输出预算必须显式小于通道容量**。本会话因此误判过至少五次
（`n=3`、`M/x` 标记、`AB 0x0`、"40 秒无 abort"、`W` 行）。

### 回退说明

本轮后续的代码修改引入了连锁语法错误，已整体回退到 `f6c236d`（构建通过、工作树 clean），
未留下半成品 —— 遵循本项目的收尾纪律。

## ✅ 修复验证：`C` 持续、`A` 从未出现（2026-11-19 定案）

`AB` 行提前 + `W` 行删除后，抓取 (20 s)：

```
.CCCCCCCCCCCCCpcsample n=9472 pc=0x2f8036cc ra=0x40065e1c
CCCCCCCCCCCCCpcsample n=9728 pc=0x2f8036cc ra=0x40065e1c
```

| 标记 | 含义 | 观测 |
| --- | --- | --- |
| `C` | 专用缓冲被服务（`calloc(1904)` 命中专用分支） | **持续、每心跳间隔约 13 次** |
| `A` | 进入 `abort` | **从未出现** |
| `AB 0x…` | abort 时刻的 RA 导出 | 0 行 |

⇒ **专用缓冲消除了 abort**，且归档**反复请求 1904 字节**（PHY 校准的重试/多模块路径）。

### ⚠️ 必须注意的副作用：**别名**

专用缓冲对所有 `n*sz == 1904` 返回**同一块** 2048 B 静态内存。
13 次/interval 的调用意味着**多个指针指向同一块** ⇒ 后到的会覆盖先到的。
若校准路径依赖这些缓冲的内容，行为会不正确（但至少不再 abort）。

**修正方向**：改成 **4 槽轮转**（`g_phy_cal_buf[4][2048]`，索引 `served % 4`）。

### 附带确认

- 心跳恢复（`s9472` / `s9728`）⇒ CPU 正常跑、ISR 正常投递；
- `pc=0x2f8036cc` = ROM 的轮询助手（此前记录过的外设轮询点）。

### 本会话最终成果链

```
崩溃（anchor[8] 自伤）                → 已修
总线停摆（缺 PHY 频域时钟 + I2C_MST_FO） → 已修（心跳 320 → 9728+）
分配失败（calloc(1,1904) 在 1200 B 空闲的堆上）→ 已修（专用缓冲）
现状：PHY 校准反复申请 1904 B，进程推进，无 abort
待修：专用缓冲的别名问题（4 槽轮转）
```

## ✅ 4 槽轮转生效；但暴露**重试循环**（2026-11-19 最终观测）

```
C: 489 次     <- calloc(1904) 被服务 489 次（20 秒内）
A: 0          <- 无 abort
n=9728        <- 心跳正常，CPU 在跑
```

⇒ **abort 已彻底消除**（489 次服务、0 次 abort）。
⇒ 但归档在**反复重试**同一个 1904 字节请求（≈25 次/秒）——
   这是 PHY 校准的**重试循环**，不是在推进。

### 现在的准确状态

| 项 | 状态 |
| --- | --- |
| abort | **已消除**（验证：489 次服务、0 次 abort） |
| 别名 | **已修**（4 槽轮转） |
| PHY 校准 | **在重试循环中**，未收敛 |
| CPU / ISR | 正常（心跳 9728） |

### 下一步

489 次重试说明校准**每次都在同一个判据上失败**。需要看：
1. `calloc(1904)` 之后，归档**用这块内存做了什么**（写入了什么、读回了什么）；
2. 哪个条件让它重试 —— 采样 PC（`0x2f8036cc`，ROM 外设轮询）已指向 ROM，
   说明它在**等某个硬件事件**（PLL 锁定 / 校准完成位）。

**最省事的下一步**：把 `C` 计数与**最近一次 `calloc` 返回的指针**一起打进心跳，
再对照罗马采样点 —— 若指针每次不同（轮转生效）而行为不变，说明问题不在缓冲，
而在**校准本身的硬件握手**（回到 `0x2010B000` 那类外设访问）。

## 本轮核实（2026-11-19）

| 项 | 值 | 结论 |
| --- | --- | --- |
| `_heap_start` | `0x2f021080`（原 `0x2f01fec0`） | 上移 8 KiB |
| arena | **348 KiB**（原 356） | 4 槽 × 2048 B 的 `.bss` 吃掉 8 KiB —— **如预期** |
| `free()` | 遍历 4 个槽并跳过 | ✅ 不会把 `.bss` 指针交给 `freeRaw` |
| abort | **仍为 0** | 缩小 8 KiB 未让它复现（专用缓冲绕过 arena） |

### 仍需修正的一处（下一轮）

`C` 计数来自 `put1()` **直接写 UART**，FIFO 满时会丢字节 ⇒ **489 是下限，真实值未知**。

**修正**：把计数放进 RAM（`g_flag_c_count++`），在心跳里打十六进制 —— 与已建立的
"用计数器而非日志判定"原则一致（本会话因此修过 `n=3`、`M/x`、`AB 0x0`、`W` 行四处）。

### 当前完整状态

```
崩溃（anchor[8] 自伤）                        → 已修
总线停摆（PHY 频域时钟 + I2C_MST_FO）          → 已修（心跳 320 → 9728+）
分配失败（calloc(1,1904)）                    → 已修（4 槽轮转，0 abort）
arena                                        → 348 KiB（牺牲 8 KiB 给专用缓冲）
现存：校准在重试（计数待精确），方向 = ROM 外设轮询（0x2f8036cc）
```

## 精确计数的跨语言读取未生效（2026-11-19 收尾，如实记录）

尝试把 `C` 次数记进 C 侧 `g_c_count` 并由 Zig 心跳读出，结果：

```
心跳 = "."            <- Zig 侧读到 g_c_count == 0
串口 = "CCCCCC..."    <- put1('C') 确实在执行
```

⇒ `put1` 正常，但 **Zig 的 `extern var g_c_count` 读到 0**（符号可见但值不符）。

### 因此当前可用的判据

`C` 字节流**存在性**是可靠的（"专用缓冲被服务过"），但**计数**不可靠。

### 下一轮的两条路（都很短）

1. **不信跨语言全局**：把计数放进 **Zig 侧**（在 `calloc` 调用处由 Zig 侧计数不可行），
   或让 C 侧在**心跳文本生成函数里**直接读自己的变量并返回字符串（C 提供 `flagsText`）；
2. **接受存在性判据**：`C` 出现 + `A` 不出现 = 修复有效；**不追求精确次数**。

### 已确立（不再变动）

| 项 | 证据 |
| --- | --- |
| abort 已消除 | `C` 持续输出、`A` 从未出现、`pc` 在 ROM 多例程间 |
| 专用缓冲 4 槽轮转 | 镜像含 `g_phy_cal_buf[4][2048]`，`free()` 跳过 4 槽 |
| arena 成本 | `_heap_start` 上移 8 KiB ⇒ 348 KiB |
| 校准在重试 | `C` 高频输出（下限 489/20 s），`pc=0x2f82xxxx` ROM |

## 最终状态（2026-11-19 收尾）

去掉裸字节 `C` 后（它们每心跳刷 15 个，正淹没 128 B FIFO），抓取恢复正常：

```
pcsample n=9728 pc=0x2f828a60 ra=0x2f828a44 s0=0x20100000
.
```

| 项 | 状态 |
| --- | --- |
| abort | **未出现**（`AB` 行 0 条，`A` 标志未置） |
| CPU / ISR | 正常（`n=9728`） |
| 采样点 | ROM `0x2f828a60` / `ra=0x2f828a44`，`s0=0x20100000`（**modem 寄存器基址**）|
| 跨语言计数 | 仍读 0（`volatile` 与非 `volatile` 都试过），**未解决** |

### 最后一条有信息量的线索

`s0=0x20100000` —— 正是 **`MODEM_BASE`**。结合采样多在 `0x2f82xxxx`（ROM 外设助手），
说明 PHY 校准**确实在访问 modem 寄存器块**，并在此处等待。

⇒ 与 README 早先记录的 `0x2010B000`（`MODEM_BASE + 0xB000`）同族。
⇒ **域时钟修复让这块不再挂死总线**（心跳 9728 为证），但校准仍在等待某个硬件事件。

### 下一阶段的方向

1. 在 ROM 采样点上确定它**等的是哪个寄存器位**（`s0` 已给出基址，可配合已有的寄存器环）；
2. 若等的是 RF 校准完成位，则需要真实的天线/RF 前端条件 —— 那是硬件前提，不是软件。

## ✅ 收尾核实：两条"无 AB = 无 abort"的前提都成立（2026-11-19 终）

此前担心两件事会让"无 AB 行"失去意义，逐一核实：

| 担心 | 核实结果 |
| --- | --- |
| 早前 `git checkout -- phy_stubs.c` 可能移除了 `probe_dump_now()` 调用 | **仍存在**：`abort()` 里依次做 RA 记录 → `g_flag_a = 1` → `probe_dump_now()` → 自旋 |
| `g_c_count` 可能有重复/局部符号，导致 Zig 读到零页 | **唯一**：`readelf -sW` 显示 `g_c_count` @ `0x2f012f28`，GLOBAL OBJECT，无重复 |

⇒ 两条前提成立 ⇒ **"AB 行 0 条 + `g_flag_a` 未置"= abort 确实没有发生**。

### 仍存在的、但仅影响可读性的问题

`g_c_count` 在 Zig 侧仍读到 0（尽管符号唯一且 GLOBAL）。
这是**显示问题**，不影响"专用缓冲已被服务"这一事实（早期 `C` 字节流为证）。
若下一轮需要精确次数：让 **C 侧自己**生成心跳文本（`extern` 一个 Zig 回调），绕开跨语言读。

### 最终结论（可直接采信）

```
崩溃（anchor[8] 自伤预发布）                   → 已修
总线停摆（PHY 频域时钟 + BLE 专属 I2C_MST_FO） → 已修（心跳 320 → 9728+）
分配失败（calloc(1,1904)）                    → 已修（4 槽专用缓冲，abort 不再发生）
现状：PHY 校准在 modem 寄存器块（s0=0x20100000）轮询等待
```

## ✅ 阳性对照通过：导出路径有效，"无 AB" 可采信（2026-11-19 定案）

临时在首次 `calloc` 时注入 `g_abort_ra = 0x1234` 并调用一次导出：

```
AB 0x1234 C=0 f=352048
```

| 结果 | 含义 |
| --- | --- |
| `AB 0x1234` **出现** | ✅ **导出路径有效**（`probe_dump_now` → `dumpAtPend` → AB 行） |
| `f=352048` | 首次分配时 arena 空闲 **352 KB** |

⇒ **"AB 行 0 条" = "abort 未发生"** —— 这个结论现在有**阳性对照**支撑，不再只是"没看到"。

（对照代码已注释掉，避免影响正常运行。）

### 本会话最终定论

```
崩溃（anchor[8] 自伤预发布）                     → 已修（开关对照）
总线停摆（PHY 频域时钟 + BLE 专属 I2C_MST_FO）   → 已修（心跳 320 → 9728+）
分配失败（calloc(1,1904) 在 188 块之后无空间）    → 已修（4 槽专用缓冲）
  └ 阳性对照证明"无 abort"可信
现状：PHY 校准在 modem 寄存器块（s0=0x20100000）轮询等待
待办：确认等待的是哪个寄存器位（仪器已就位）
```

## 对阳性对照的边界说明（重要，2026-11-19 补）

阳性对照（`AB 0x1234` 出现）证明的是：**`probe_dump_now → dumpAtPend → AB 行` 这条路径可用**。

它**没有**证明：abort 自旋那一刻的调用同样能挤进 FIFO（同样的路径，但时机不同、FIFO 状态不同）。

### 因此"无 abort"的判据应分层

| 判据 | 可靠性 |
| --- | --- |
| `AB` 行缺席 | 中（受 FIFO 影响，但对照片显示 AB 现已排**第一行**，风险已大幅降低） |
| **心跳里的 `g_flag_a` 为 0** | **高**（单字节、每 64 tick 重复、不会被一次性丢失） |

### 一个已经验证的绑定事实

`AB 0x1234` 的打印说明 **Zig 侧 `extern var g_abort_ra` 能正确读取 C 全局**
⇒ 同机制的 `g_flag_a` / `g_c_count` 读到 0 应是**真实值**，不是跨语言绑定失败。

⇒ 但 `g_flag_a` 目前只能通过心跳的 `.` 间接体现（`flagsText` 先查 `g_c_count`）——
   下一轮应让 `flagsText` **优先**返回 `<A>`（abort 优先于计数），使"无 abort"由**标志位**而非**缺席的行**证明。

## 🔴 最后一个仪器缺口（已核实，2026-11-19 收尾）

核实心跳来源：

```
trap.zig:198:  if (irq_count % 512 == 0) log.raw(".");
```

⇒ 心跳是**字面量** `.` —— **完全不查 `g_flag_a` / `g_c_count`**。

| 事实 | 含义 |
| --- | --- |
| `g_flag_a` 由 abort 桩设置 | 但**没有任何代码读取并打印它** |
| 心跳恒为 `.` | 与 abort 是否发生**无关** |
| `flagsText` / `probe_flags_at` | 早前 `git checkout` 后已不存在 |

### 因此"abort 已消除"的准确表述（按建议收紧）

> **在 carve-out 之后的 N 次抓取中未观察到 AB 行；导出路径由"启动调用者"的阳性对照
> （`AB 0x1234`）验证可用。**

即：**路径可用**（已证）+ **该行未出现**（多次观察），但**尚无标志位独立验证**，
且阳性对照来自启动路径而非 abort 自旋时刻（时机/FIFO 状态不同）。

### 下一会话第一步（两文件，机械改动）

1. `trap.zig`：`pub var probe_flags_at: ?*const fn () []const u8 = null;`，
   心跳改为 `log.raw(if (probe_flags_at) |g| g() else ".");`
2. `probe.zig`：`extern var g_flag_a: u32;`（与已验证的 `g_abort_ra` 同款）+
   `pub fn flagsText() []const u8 { return if (g_flag_a != 0) "<A>" else "."; }` +
   在 `run()` 里注册到 `board.trap.probe_flags_at`
3. 阳性对照：注入 `g_flag_a=1`，心跳应显示 `<A>` —— 这是**不会被 FIFO 丢失**的验证

### 当前可交付结论（按证据强度）

| 结论 | 强度 |
| --- | --- |
| 三个根因（anchor[8] / 域时钟 / 分配耗尽）已修 | **强**（对照实验 + 直接读数） |
| PHY 校准在 modem 寄存器块轮询（`s0=0x20100000`） | **强**（采样） |
| abort 已消除 | **中**（AB 行未出现 + 导出路径已对照；缺标志位验证） |

## 🔴 回归：carve-out 的 8 KiB 是**从 arena 里拿的**（2026-11-19 最后一条发现）

数字对照：

| 量 | 值 |
| --- | --- |
| 修复前 arena（`_heap_end - _heap_start`） | 356 096 B |
| 修复后 arena | **351 936 B** |
| 差 | **−4 160 B** |
| 归档崩溃时的占用 | ~354 896 B（188 块，free 仅 1 200） |

⇒ `g_phy_cal_buf[4][2048]` 是普通 `.bss` 静态数组，而 `.bss` 在 `_heap_start` **之前**
   ⇒ 它每涨 1 字节，arena 就少 1 字节。

⇒ **arena 现在装不下归档的工作集**（351 936 < 354 896）⇒ 某个**其它尺寸**的分配必然失败
   ⇒ 归档失败后重试整个校准 ⇒ 每次重试都请求 1904（**这一条被 carve-out 保护**）
   ⇒ 于是看到"1904 被反复服务、却没有任何进展"。**这就是重试循环的来源。**

### 修法（按顺序）

1. **把 carve-out 移出 `.bss`**：给它一个**独立的 NOLOAD 段**，放在 `.btdm_data` **之后**
   （那里已经是保留区，不移动 `_heap_start`），或直接复用 `.btdm_bss` 的预留空间；
2. 移完后重新确认 arena ≥ 归档峰值需求（→ 354 896 B 以上），否则仍会失败；
3. 判据：`AB` 不再出现 **且** 心跳里 1904 的请求速率降到个位数（不再无限重试）。

### 这一条的教训

**"修复"可能消耗它所修复的资源**：给校准腾出一块专用缓冲，代价是缩小了归档的工作堆，
而后者本来就已经不够。任何"专用缓冲"都必须**从保留区拿，而不是从共享池拿**。

## 🔴 框架修正（最高优先级，2026-11-19 最终）

本会话后续几节把"abort 消失"当作进展记录，那**是错的**。正确的因果是：

| 事实 | 正确解读 |
| --- | --- |
| arena 351 936 B（carve-out 后） | 归档工作集需要 **~354 896 B** ⇒ **全局容量缺口 ~3 KB** |
| abort（`calloc(1,1904)` 返回 NULL） | 只是这个缺口的**第一个可见症状** |
| carve-out 让 1904 永不失败 | 把一个**响亮的 abort** 换成**无声的无限重试** |
| 1904 被反复请求、无进展 | 是**失败分配在被重试**，不是校准在推进 |
| `pcsample` 停在 `s0=0x20100000` | 是**重试路径**上的采样，**尚不能**作为"校准在等硬件"的证据 |

### 因此三条结论必须降级

| 原结论 | 修正后 |
| --- | --- |
| "abort 已消除" | ❌ **不是进展**：症状被掩盖，缺口仍在 |
| "PHY 校准在 modem 寄存器块轮询" | ⚠️ **未成立**：那条采样来自重试路径 |
| "剩余是硬件握手" | ⚠️ **未成立**：当前阻塞仍是**容量** |

### 真正的下一步（唯一）

**把 carve-out 移出 `.bss`**（放进 `.btdm_data` 之后的独立 NOLOAD 段），
使 arena 恢复到 ≥ 归档峰值需求（~355 KB），**再重测**：

- 若此时 `calloc(1,1904)` 仍失败 ⇒ 容量缺口是真实的，需要减少归档的需求；
- 若此时校准**不再重试**且采样点**离开** `0x2f82xxxx` ⇒ 才算真正推进。

**在完成这一步之前，不要追"硬件握手"** —— 那会把容量问题误判成硬件问题。

## 🔍 缺口是内生的；真正的杠杆是 `.btdm_bss` 的 32 KiB（2026-11-19 最终分析）

### 算术

| 量 | 值 |
| --- | --- |
| 未 carve-out 的 arena | 356 096 B |
| abort 时已占用（188 块） | 356 096 − 1 200 = **354 896 B** |
| 随后请求 | +1 904 B |
| 合计需求 | **~356 800 B > 356 096 B** |

⇒ **需求本身就超过了整块 arena** ⇒ abort 是**容量缺口的第一症状**，
   carve-out 只是把它**搬进了重试循环**（并没有创造 RAM）。

⇒ 因此"把 carve-out 移到 `.btdm_data` 之后的段"**也不解决问题** ——
   只要 `_heap_start` 仍在它之后，arena 一样少那么多。**移位 ≠ 增加。**

### 真正的杠杆：缩短 `.btdm_bss`（32 KiB → 16 KiB）

关键事实（已在本文件反汇编确证）：

- `.btdm_bss` 由归档自己的 `r_sym_ble_zEWRSkDdfQbTqLJOuE4J` 用
  **符号长度算出的 memset** 清零（`len = _bss_end_btdm − _bss_end`）；
- ⇒ **缩短该段，memset 长度随之缩短** ⇒ 多出的 16 KiB 直接回到堆；
- 这 16 KiB 同时覆盖 carve-out（4.5 KiB）与缺口（~3 KiB）。

### ⚠️ 必须先写进 README 的风险

归档的工作区会**随 `.btdm_bss` 一起变小**。若它实际用量超过新尺寸，
它会**写进堆区**（而不是干净地失败）⇒ 症状会从 abort 变成随机破坏。

**因此这一步必须配合**：缩短后先确认 abort **不再出现**，
再用 canary/块链检查堆区是否被写坏（仪器都已就位）。

### 备选：把需求**测准**而不是推断

已有 `(size, ret)` 表（`mc_sizes`/`mc_rets`）：导出**全部 188 次请求的尺寸分布**
即可得到**真实峰值需求**，据此决定 `.btdm_bss` 缩多少、或是否必须走 PSRAM（未验证）。

## ✅ 真正的修法：缩短 `.btdm_bss` 占位洞（2026-11-19 定案）

`.btdm_bss` 是**纯占位洞**（`. = . + 0x8000`，不匹配任何输入节），
归档只通过 init 的 `memset(_bss_start_btdm, 0, _bss_end_btdm - _bss_start_btdm)` 用它 ——
**长度由符号算出，缩短即少清一段**。

改动（`s31.ld`，一处常量）：

```ld
-        . = . + 0x8000;
+        . = . + 0x2000;   /* 32 KiB -> 8 KiB */
```

结果（`WITH_PHY=1`，814 656 B）：

| 量 | 之前 | 之后 |
| --- | --- | --- |
| `_heap_start` | `0x2f01fec0` | **`0x2f01b080`**（降 19 520 B） |
| arena | 352 KiB | **376 KiB** |
| 归档需求 | ~355 KB | ~355 KB（不变） |
| abort | 每轮出现 | **消失**（`AB: 0`，心跳 `n=8704`） |

⇒ **arena（376 KiB）> 需求（~355 KB）⇒ 缺口消失 ⇒ 分配不再失败。**

⇒ 这与早先的结论一致：**缺口是内生的**，靠"给一个请求开专用缓冲"无法解决，
  必须**增加真正的可用内存** —— 而这 16 KiB 来自我们自己多留的空洞，不是新增硬件资源。

### 风险（已量化，未观测到）

归档若把该洞当 init 临时区、写入超过新长度，会**写进堆区**。
`canary`/块链扫描仪器已就位，可检测；本轮未观察到异常（心跳正常、无 abort）。

### 待确认

`enter step` 行仍因 FIFO 压力未出现 ⇒ 无法确认归档推进到哪一步。
下一步应把引擎推到"step 7 是否出现"这一判据上。

## 💡 更优的杠杆：**需求与我们自己的事件数种子成正比**（2026-11-19 分析）

观察：

```
arena 里 188 个块（≈355 KB，均值 ~1.9 KB）
bt mempool: need evt=187 evtq=33 co=41 sem=20 mutex=16
188 = 187 (evt) + 1
```

⇒ 归档的分配数**恰好等于事件数 + 1** ⇒ 工作集**线性于 `evt_count`**，
   而 `evt_count` 由**我们自己**的 `config.zig` 的 `seed()`（3 + 100）与 LL 的答复决定。

### 这意味着

- 不必动 `.btdm_bss` / 栈 / carve-out，**只要减小事件预算**即可显著降低需求；
- 但要**三处一致**：`seed()`、`elemCalc`、`osal.pool_caps` —— 
  否则归档自己的 mempool 校验（`porting.zig:461-480`）会**提前失败并报另一个错**。

### 验证方式（无需新仪器）

读取已有 `(size, ret)` 表：若那 ~187 次分配**聚集在同一个尺寸**，
即证实"每个事件一块缓冲"，按比例缩小即线性降低峰值。

### 与已做修复的关系

| 手段 | 效果 | 代价 |
| --- | --- | --- |
| `.btdm_bss` 32→8 KiB（**已做**） | +24 KiB 到堆 | 归档的 init 临时区变小（风险已记录） |
| **减小事件预算**（待做） | 线性降低需求（可能省下上百 KB） | 需三处一致，否则早期失败 |

两者不冲突；后者是**更根本**的一条，因为它直接改变需求而非供给。

## 🔴 决定性实验：arena 376 KiB 下 abort **仍然发生**（2026-11-19 终）

移除 carve-out、arena 扩到 376 KiB 后重测：

```
AB 0x0 C=0 f=374704
```

| 事实 | 含义 |
| --- | --- |
| **AB 行出现** | **abort 仍被调用** |
| `f=374704`（366 KiB 空闲） | **容量充足** ⇒ 不是容量问题 |
| `AB 0x0` | RA 读到 0（`asm("mv %0, ra")` 在入口处竟为 0，需另查） |

### 因此两条结论同时被推翻

| 原结论 | 状态 |
| --- | --- |
| "abort = 容量缺口" | ❌ **不成立**（366 KiB 空闲仍 abort）|
| "carve-out 掩盖了症状" | ⚠️ 部分成立：它确实让 1904 不再失败，但 abort 另有原因 |

### 但 `.btdm_bss` 的缩短**仍是真实改进**

arena 从 352 → 376 KiB 是实测的（`_heap_start` 降 19 520 B），
且**没有引入新问题**（心跳正常）。只是它**不解决 abort**。

### 现在的准确状态

```
alloc 成功（堆充裕） → abort 依然发生 → 说明 abort 来自 esp_phy_load_cal_and_init 里
                                        **另一处检查**（不是 calloc 的 NULL 判断）
```

**下一步**：`AB 0x0` 说明 RA 取法有问题（`mv %0, ra` 在函数入口应有效）。
要么改用 `__builtin_return_address` 的另一种实现，要么在 abort 桩里
**把 `ra` 存进一个寄存器备份**再读 —— 拿到真实 RA 才能定位是哪一处检查。

## ⚠️ `.btdm_bss` 缩短的两项验证缺口（2026-11-19 收尾）

`.btdm_bss` 从 32 KiB 缩到 8 KiB，是**实测有效**的（arena 352 → 376 KiB）。
但它带来两个**尚未验证**的风险，必须写明：

### 缺口 1：归档的 init 临时区变小，可能已改为写进堆

- 归档 init 时 `memset(_bss_start_btdm, 0, len)`，`len` 现在只有 **8 KiB**（原 32 KiB）；
- 若归档把这段当 scratch 且用量 > 8 KiB，它会**越过洞尾写进堆区**；
- **检测仪器（canary / 块链扫描）在 `dumpAtPend` 里，其唯一触发是 abort ——
  而 carve-out 移除后 abort 不再由分配触发，该扫描本轮根本没跑**。

⇒ **这项风险目前完全未验证。**

### 缺口 2："188 块 ≈ 187 evt + 1"是**巧合**

- 块均值为 ~1.9 KB，而 `porting.zig` 的 `pool_caps` 里 evt 上限只有 **384 B**；
- ⇒ 这 188 个块**不是**按事件分配的池 ⇒ 那个数字巧合**不能**用作"需求线性于 evt"的证据。

### 正确的下一步（按优先级）

1. **让 dump 在没有 abort 时也能跑**：在 T0 ISR 的固定 tick 处调 `probe_dump_now()`
   （或 step 6 窗口结束时调一次），确认缩短后的洞尾**没有**被写坏；
2. **打印 `(size, ret)` 表的尺寸直方图**（不同尺寸 + 次数）：
   若某一尺寸独占多数 ⇒ 那就是要缩的工作集；若分散 ⇒ 找少数大块；
3. 再用**增长中的 `CODES` 计数**（心跳里加一个短字段）判断"推进 vs 空转"。

⚠️ 这三项都需要**跨 `probe.zig` / `trap.zig` 的改动**，本会话已两次因此产生级联编译错误
（只能回退），故留待新会话按上述顺序执行。

## 🔴 再纠正：`AB 0x0` 来自**分配触发点**，不是 abort（2026-11-19 最终）

上一节把 `AB 0x0 C=0 f=374704` 读作"abort 仍发生"，**这是错的**。逐字段重读：

| 字段 | 值 | 正确含义 |
| --- | --- | --- |
| `AB 0x0` | RA = **0** | **abort 从未执行**（真 abort 会写入非零 RA，如阳性对照的 `0x1234`） |
| `f=374704` | 366 KiB 空闲（总 376 KiB） | 那一刻堆**几乎是空的**，只用掉 ~10 KiB |
| 这行从哪来 | `btdmMalloc(1904)` 里的 `dump_hook` | **分配触发点**，不是故障路径 |

⇒ **AB 行有两个来源**（分配触发 / abort 桩），而我只看了第一个字段就下了结论 ——
   这与本会话反复出现的"没读全就解释"是同一类错误。

### 因此三条结论需要修正

| 结论 | 修正 |
| --- | --- |
| "carve-out 移除后 abort 仍发生" | ❌ **撤回**：没有 abort |
| "容量不是 abort 原因" | ❌ **撤回**：没有 abort 可归因 |
| "`.btdm_bss` 缩短不解决 abort" | ❌ **撤回**：它**解决了分配失败**，且没有 abort 需要解决 |

### 还剩下的真实疑问

`f=374704`（几乎空堆）与早前"188 块 / ~355 KB 占用"**矛盾** ——
说明那 188 块是**重试循环的稳态**，不是必然前提。

⇒ 真相可能是：**重试循环本身**（而非容量）才是持续分配的原因；
   `btdmMalloc(1904)` 反复被调用 ⇒ 每次分配后又释放 ⇒ 堆看起来是空的。

**下一步**：用 `CODES` 计数在心跳里判断"调用在增长还是持平" —— 增长 = 真推进，持平 = 空转。

## 🏁 时序澄清：PHY 校准在 **boot 阶段**，早于 task_init（2026-11-19 定论）

`CODES` 行数为 **0** ⇒ 第一次 `btdmMalloc(1904)` 发生时，**归档一次 OSAL 都还没调用过**。

结合 `phy_before_clocks=true`（默认）⇒ `pp.initPhy()` 在 `dumpBootState()` 里执行
⇒ **PHY 校准发生在 bringup 的 step 1 之前**。

### 这把几条"矛盾"全部解开

| 观察 | 解释 |
| --- | --- |
| `f=374704`（几乎空堆） | 校准在 boot 阶段跑，归档尚未分配任何东西 |
| "188 块 / 355 KB 占用" | 那是 **task_init 阶段**的稳态，与 boot 阶段的校准是**两个不同时刻** |
| `CODES=0` | 校准不使用 OSAL（它直接调 `calloc`/`free`） |
| `AB 0x0` | 来自 `btdmMalloc(1904)` 的触发，那时没有 abort |

⇒ **我此前把两个阶段的数字混在一起比较**，由此得出"容量缺口"的结论 ——
   而容量缺口是 **task_init 阶段**的现象，**不是** PHY 校准失败的原因。

### 因此准确的现状

```
boot 阶段：PHY 校准 → calloc(1,1904) → 成功（堆几乎空，arena 376 KiB）
          → 继续执行（无 abort）
task_init 阶段：188 块 / 355 KB —— 另一个阶段的独立问题
```

**下一步**：分别测量两个阶段。
- boot 阶段校准是否**完成**（`esp_phy_enable` 是否返回）；
- task_init 阶段的容量是否足够（`arenaFree()` 在 step 6 附近）。

## 🏁 定论：卡在 **boot 阶段的 PHY 校准**，从未进入 step 1（2026-11-19 终）

对最近 5 次抓取的统计：

| 行 | 出现次数 | 含义 |
| --- | --- | --- |
| `bt probe:` | **21** | 抓到并解析（早期日志正常捕获）|
| `bt mempool: need` | **0** | **归档从未到达 step 1** |
| `enter step` | **0** | 同上 |
| `CODES` | **0** | 归档从未调用 OSAL |

⇒ **`bringup.init()` 卡在 `dumpBootState()` 里的 `pp.initPhy()`**（step 1 之前），
   PHY 校准**不返回**。

### 因此本会话后半程的所有"容量"结论都是**跨阶段的误读**

| 数字 | 真实所属阶段 |
| --- | --- |
| `f=374704`（几乎空堆） | **boot**：校准在分配，归档尚未启动 |
| "188 块 / 355 KB" | **task_init**：来自**更早、配置不同**的运行 |
| `AB 0x0` | `btdmMalloc(1904)` 的触发，boot 阶段，无 abort |

⇒ **当前真正的阻塞**：`initPhy()` 不返回（不是 abort、不是容量）。

### 下一步（唯一）

`initPhy()` = `phy_get_romfunc_addr()` + `esp_phy_enable(2)`。
需确定它停在**哪一步**：
1. 在两者之间各打一个极短标记（单字节，如 `P`/`Q`）；
2. 或直接看采样：`pc=0x2f82xxxx`（ROM）+ `s0=0x20100000`（modem 基址）
   ⇒ 它在**轮询 modem 寄存器** ⇒ 等某个硬件状态位。

**这与"容量"完全无关** —— 那条线是本会话最大的弯路。

## 🔴 再纠正：两个数字来自**同一阶段的两次 dump**（2026-11-19 最终）

上一节把 `f=374704` 归给 boot、把"188 块 / 355 KB"归给 task_init，**这是错的**。正确的是：

| 数字 | 来自哪次 dump | 说明 |
| --- | --- | --- |
| `f=374704` | `btdmMalloc(1904)` 的**分配触发** | 校准**刚开始**，堆自然几乎空 |
| `f=1200` / 188 块 | **abort 时刻**的 dump | 校准**已分配完**（~355 KB），即将失败 |

⇒ 两者**都是 boot 阶段**，只是**时间点不同**。

⇒ 因此结论是：**boot 阶段的 PHY 校准本身需要 ~355 KB**，
   旧 arena（352 KiB）不够 ⇒ abort；新 arena（376 KiB）够 ⇒ **1904 成功、无 abort**。

⇒ 而"从未到 step 1"是因为**校准还没返回**（它在轮询硬件），**不是**容量问题。

### 当前准确状态

```
boot: initPhy() → 分配 ~355 KB（成功，arena 376 KiB 有余量 ~21 KiB）
               → 轮询 modem 寄存器（s0=0x20100000）
               → 不返回 ⇒ 永远到不了 step 1
```

### 两项待办（按优先级）

1. **在 boot 阶段末尾测 `arenaFree()`**（例如首次 OSAL 调用时或周期 tick），
   验证余量确实 ~21 KiB —— 而不是在第一次 1904 请求时（那时必然空）；
2. **让 dump 在没有 `size==1904` 时也能跑**（周期 tick 或首次 OSAL），
   这样 `.btdm_bss` 缩短的越界风险才真正被 canary/块链检查覆盖。
