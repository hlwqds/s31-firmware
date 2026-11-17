# boot-power-perf — 自举、功耗与性能模型

otadata 选槽、A/B 回滚预算、睡眠预算、p50/p95 与频率折算。

- 主机测试：**26 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `boards`；不依赖其它组件

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/flash.zig` | SPI flash 最小封装（ROM `esp_rom_spiflash_read/write/erase_sector`，4 KiB 扇区） |
| `src/partition.zig` | 分区表二进制解析（0x8000，32 字节条目，magic 0xAA50） |
| `src/slot.zig` | **otadata 的真实读写 + 启动槽选择**（见下节） |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |

## otadata 的真实落盘（C5）

`bootslot.zig` 是**教学模型**（16 字节 `S31B` 记录），IDF bootloader 不认。真实格式在
`slot.zig`：`esp_ota_select_entry_t`，32 字节。

```text
0..4    ota_seq     u32   1 起；槽位 = (ota_seq - 1) % ota_app_count
4..24   seq_label   [20]  填充
24..28  ota_state   u32   NEW(0) / PENDING_VERIFY(1) / VALID(2) / INVALID(3) / ABORTED(4)
28..32  crc         u32   CRC32 **只覆盖 ota_seq 那 4 字节**
```

四条容易静默失败的约束（每条都有板上证据或 IDF 源码出处）：

1. **CRC 口径**：`crc32_le(init, buf, len)` 的语义是 `~raw(~init, buf)`（首尾各取反一次）。
   `crc32Le(0xFFFFFFFF, seq_le)` 因此等于 `~raw(0, …)`，即本仓实测/板上真值：
   seq=1 → `0x4743989a`、seq=2 → `0x55f63774`、seq=3 → `0xed4a5011`。
   **注意**：它不等于 `zlib.crc32`（那是 `~raw(0xFFFFFFFF, …)`）；头文件说的"调用方自己加 `~`"
   与本板 ROM 的实际行为相反，以实测为准。
2. **写哪个扇区**：切槽写**另一个**扇区（保留当前记录，断电可回退）；确认/判废写**同一个**
   扇区且 `seq` 不变 —— 两条记录 `seq` 相等时选槽取扇区 0，写到另一个会让 VALID 被旧记录盖掉。
3. **失败计数放 nvs 最后一扇区**（0xE000），不塞 otadata：bootloader 更新条目时整扇区擦除。
   记录 16 字节、追加写（256 条/扇区），`crc32` 自校验。
4. **计数按槽隔离**：换槽后清零，否则上一槽的失败会让新槽一次失败就被判死
   （板上实测出现过跨槽累加到 8/9 的错误行为）。

应用侧职责（`firmware/src/main.zig`）：启动打印真实活动槽 → 自检通过且 `state ∈ {NEW,
PENDING_VERIFY}` 则写 VALID → 自检失败累加计数，到 `max_runtime_failures`(3) 写 INVALID 并
`hw.reset()`，bootloader 跳过它改走另一槽（或 factory）。

> 本仓 bootloader **没有**打开 `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`（Kconfig 默认 `n`），
> 所以 NEW→PENDING_VERIFY / ABORTED 的翻转不会发生，状态位全部由应用负责。

### 静态缓冲（RAM，不是 flash）

| 缓冲 | 大小 | 用途 |
| --- | --- | --- |
| `partition.table_buf` | 0xC00 ≈ 3 KB | 一次读完整张分区表（0x8000 起 0xC00 上限） |
| `slot.sector_buf` | 0x1000 = 4 KB | 一次读写一个 otadata / nvs 扇区 |

两者都在 `.bss`，**不计入**容量门禁的 flash 指标，但确实吃应用 SRAM（本板 512 KB）。
再加同类缓冲前先算一下：读 otadata 一次就要 4 KB，别在每个函数里各开一份。

### 两个镜像、谁刷哪（构造 C5 场景时必读）

`-Dab-stage=a|b` 是**每次启动都会执行**的动作。如果把同一份带 `-Dab-stage` 的构建同时刷进
factory 和某个 OTA 槽，板子会 stage→复位→再 stage→再复位，永远跑不到自检、拿不到证据。
正确次序：

| 步 | 镜像 | 刷到 |
| --- | --- | --- |
| 1 | 正常构建（无 `-Dab-stage`、无 `-Dab-fail`） | `ota_0`（0x190000） |
| 2 | 带 `-Dab-stage=a` | factory（0x10000） |
| 3 | 复位 → factory 写 otadata seq=1 NEW → 复位 → 起 ota_0 → 确认 VALID | — |
| 4 | 失败注入：`-Dab-fail` 构建 | `ota_1`（0x310000） |
| 5 | 带 `-Dab-stage=b` | factory |
| 6 | 复位 → 起 ota_1 → 失败 3 次 → INVALID → 复位 → 回 ota_0 | — |

> 测试收尾时把正常构建刷回 factory 与 ota_0，并擦掉 otadata(0x490000, 2 扇区) 与
> nvs 计数扇区(0xE000, 1 扇区)，否则下一次开机仍按旧 otadata 起槽。

板上证据：`logs/c5-ab-factory.log`、`logs/c5-ab-stage-confirm.log`、`logs/c5-ab-rollback.log`
（矩阵 C5）。切槽/首启用 `-Dab-stage=a|b`、失败注入用 `-Dab-fail` 两个构建开关构造。

历史来源见 `docs/HISTORY.md`。
