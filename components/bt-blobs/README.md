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
| controller 的 OSAL（51 个弱断言占位） | ❌ 未实现 | 不实现就一调 `wr_btdm_assert` 挂住；见下方待验证项 4 |

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
find "$T" -name '*.o' -exec cp {} "$T/flat/" \; 2>/dev/null || mkdir -p "$T/flat"

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
| `link/bt_stubs.c` | 归档要求宿主提供、且**确实由我们给**的符号（下表） |
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
   51 个按类：callout 9、event/eventq 11、临界区 3、中断分配 2、内存 2、互斥 4、信号量 5、
   任务 2、时间 5、杂项 5（`ets_delay_us`/`rand`/`srand`/`read_efuse_mac`/`get_time_forever`）。
   ⇒ 这是"让 controller 跑起来"的主要工作量，可复用 `wifi-blobs/src/osi_impl.zig` 与 `sched.zig`。
