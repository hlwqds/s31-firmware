# 测试框架

四层门禁，全部可在 CI 复跑；本地命令与 CI 完全一致。

| 层 | 内容 | 命令 | 门禁 |
| --- | --- | --- | --- |
| L1 单元 | 11 个组件的 `test` 块（323 项） | `scripts/check-host.sh` | 合并前必须绿 |
| L1 覆盖率 | 逻辑模块可达性 100% + 用例数基线 | `python3 scripts/check-coverage.py` | 合并前必须绿 |
| L2 镜像 | 每个 profile（min/net/tls/full）交叉编译 + 两段镜像 + 分区适配 | `tests/e2e/run_e2e.py --host` | 合并前必须绿 |
| L3 板级 E2E | 烧录默认 profile，断言段集合/逐段 checks/verdict | `tests/e2e/run_e2e.py --board` | 发布前必须绿（自托管 runner） |
| L4 真链路 | 抓包/吞吐/电流/唤醒 | ROADMAP P1–P4 | 版本发布前 |

## 覆盖率的定义（重要）

Zig 0.17 没有暴露 LLVM 覆盖率映射（`-fcoverage-mapping` 不可用），所以本仓库的
"覆盖率"是**模块级可达性 + 用例数基线**，不是行覆盖率：

1. 每个组件的 `host_tests.zig` 是测试根，沿 `@import("*.zig")` 求传递闭包；
   闭包必须覆盖该组件全部逻辑模块（`selftest/hw/log/gen_cert_fixture` 排除）。
   → 阈值 **100%**，防止新增模块没有测试入口。
2. 每个组件用例数不得低于 `tests/baselines.json`；新增功能必须同时抬高基线。
   → 防止"删测试换绿"。

判断标准写在脚本头部与 `docs/REPO-STANDARDS.md` §4；如需真正的行覆盖率，
需要引入外部 LLVM 工具链并在 ADR 中记录（当前不作为门禁）。

## E2E profile 矩阵

| profile | 特性 | 期望 |
| --- | --- | --- |
| `min` | boot | 构建 + 两段镜像 |
| `net` | boot + net | 构建 + 两段镜像（默认板级 E2E） |
| `wifi` | boot + net + wifi | 构建 + 两段镜像 |
| `tls` | boot + net + tls | 构建 + 两段镜像 |
| `full` | boot + net + tls + apps + wifi | 构建 + 两段镜像（11 段自检） |
| `net-wire` | boot + wire | **发布前板级门禁**：真实链路 DHCP+TCP，TCP 走 socket 层（`Table.connect` + `tcp.Conn` 并行驱动，应用 64 B 经 `Socket.send` 发出并被 ACK 确认，checks=7）。前置 `scripts/host-prep-wire.sh up`（接口地址/dnsmasq/防火墙/监听器），门禁 `scripts/gate-board.sh`（skip 视为失败）；无 DHCP 时打印 `wire: skipped/no-dhcp-server` 并跳过 |

板级门禁（发布前必跑）：

```bash
# 本机（NixOS）三处环境都要显式给：zig 与 esptool 在 LD_LIBRARY_PATH 下会撞 glibc，
# 默认 python3 没有 pyserial。
export ZIG=/tmp/bin/zig
export ESPTOOL=/nix/store/.../bin/esptool          # esptool 5.x；`command -v esptool` 有就用它
export PYTHON=/nix/store/.../python3.14            # 必须能 `import serial`
export PYTHONPATH=/nix/store/.../python3.14-pyserial-3.5/lib/python3.14/site-packages

# 板子重新枚举后可能变成 ttyUSB0：`BOARD=` 可覆盖（脚本默认在 ttyUSB1/ttyUSB0 里挑存在的那个，
# run_e2e.py 也认 BOARD；不传时仍是 /dev/ttyUSB1）
export BOARD=/dev/ttyUSB0

sudo scripts/host-prep-wire.sh up     # 幂等：放行 udp 67/53、tcp 9000，起监听器（accept 后读掉字节并停留 2 s）
scripts/gate-board.sh                 # 构建 → 烧录 → 抓 30 s → 断言握手三段 + checks 计数
scripts/demo-board.sh [PORT]          # C8 自检：构建 → 烧录 → 抓串口 → 断言；并演示 A/B 切槽与切回旧版本
sudo scripts/host-prep-wire.sh down   # 收尾：撤销规则与监听器
```

门禁通过后自动跑 `tools/s31-production/baseline/update_matrix.py`，把 matrix §4 的 W1–W3
状态换成**本轮日志的摘录**（对端随机 ISN 这类每跑一次就变的值会被剥掉，避免无意义抖动）；
`--check` 模式在 `scripts/check-all.sh` 里，matrix 与已提交日志漂移即失败。W4（无 DHCP 降级）
要的是另一个场景（`logs/net-wire-no-dhcp.log`），故意保持人工维护，不用正常场景的行去填。

CI 上的同一套入口：`ci.yml` 的 `board` job（`workflow_dispatch`，自托管 runner）默认
`profile=net-wire`、`gate=true`，执行 `sudo scripts/host-prep-wire.sh up` → `scripts/gate-board.sh`
→ `trap` 收尾 `down`；`gate=false` 时才退回裸 `run_e2e.py --board`（只做冒烟）。
再加 `demo=true` 即**在同一个 job 里串行**跑 A/B 演示（不是另一个 job —— 同一条串口不能并发）。

`demo-board.sh` 与发布门禁的分工：它**不碰网络**（不需要 DHCP/监听器/防火墙），只验"这套固件
自己能不能起来、能不能切槽并切回来"，证据落 `logs/c8-demo.log`；发布门禁仍是 `gate-board.sh`。

同一套 A/B 演示也接进了 CI：`workflow_dispatch` 多一个 `demo` 输入（默认 `false`），置 `true`
即在同一 `board` job 里跑 `scripts/demo-board.sh "${BOARD:-}"`。三点接线约束：
① 闸门与演示**在同一个 job ⇒ 天然串行**，不会两个进程抢同一个串口；
② 该步用 `always()`：`gate` 因主机前置缺失而失败时（runner 没做过 host-prep），A/B 仍然值得验
—— 它不需要网络，且第一步就会把 factory 刷成默认镜像、不依赖上一步留下什么状态；
③ 演示最后一步会写回默认固件并清 otadata/计数扇区，所以跑完板子仍是干净的。
`ESPTOOL` 允许是**多词**（CI 里是 `python3 -m esptool`）：脚本按仓库既有约定用未加引号的
`$ESPTOOL` 调用，只有"单段绝对路径"才把它的目录并进 `PATH`。
它跑四步：① 默认固件从 factory 起来（`verdict=pass` / `ab=yes count=2` / crc32 match）；
② 正常镜像写进 ota_0，用 `-Dab-stage=a` 的镜像切槽（`offset 0x190000` + `confirmed VALID`）；
③ 把 `-Dab-revert` 的镜像写进 ota_0，它判废当前槽并复位 ⇒ 回到 factory（旧版本）；
④ 恢复默认固件并清 otadata/计数扇区。**第 3 步之前必须先把 factory 换回基线镜像** ——
否则判废后 bootloader 回到 factory、而那里仍是 stage 构建，会立刻又被切走，看起来像"切回没生效"。

`gate-board.sh` 自己会删掉上一轮的 `logs/e2e-net-wire-boot.log`（证据只能来自本轮），
`skipped/no-dhcp-server` 在门禁里算失败，前置缺失时退出码 2 并打印修复命令。
NixOS 上需要 `env -u LD_LIBRARY_PATH`（脚本已内置）和带 pyserial 的解释器（`PYTHON=` 指定）。

分区表（仓库自有，不再依赖 IDF 默认值）：

```bash
scripts/gen-partition-table.sh          # 从 firmware/idf-bootstrap/partitions.csv 生成 bin
scripts/gen-partition-table.sh --check  # 校验现有 bin 与 csv 一致（不需要 IDF 工具链）
```

`partitions.csv` 的**前三条**与 `CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE` 的默认表一致
（nvs 0x9000 / phy_init 0xf000 / factory 0x10000 + 1500K）；2026-11-18 起在其后**追加**了
A/B 三行（ota_0 0x190000、ota_1 0x310000、otadata 0x490000/8K，见该文件头注释）。
所以 factory 偏移与既有证据都不变（bootloader 的分区表 dump 从 2 条变 6 条是预期变化），
但整张表**已不再是**默认表的逐字节副本；
`check-capacity.py` 与 `run_e2e.py` 的 factory 上限仍从这张表解析。

容量门禁（无板即可跑）：

```bash
ESPTOOL=<esptool> python3 scripts/check-capacity.py            # 镜像 ≤ factory 分区、每段 ≤ 两段窗口、相对基线增长 ≤ 8 KiB
ESPTOOL=<esptool> python3 scripts/check-capacity.py --update   # 确认增长合理后重写 tools/s31-production/baseline/capacity.json
```

现状（2026-11-16 实测，段长取自 `image-info` 的 Length 列，P0.3 扩容后窗口各 `0xB0000`）：
`full`（TLS+Wi-Fi+apps）镜像 398 576 B（factory 余量 1 137 424 B），IROM 段 305 696 B
（窗口余量 415 200 B）、DROM 段 70 796 B（余量 650 100 B）——`full` 用掉 IROM 窗口的 42%。
自检方式：`CAP_WINDOW=0x40000` 跑一次，门禁必须报 `IROM ends at … > window end …`（证明断言不是恒真）。

新增/移动 `all_modules` 里的组件时，必须同步 `PROFILES[*].sections`（board 断言是全等比较）。

E2E 断言：

- `elf2image` 成功，`image-info` 恰好两行 `DROM, IROM`，镜像 ≤ factory 分区（`0x177000`）。
- 板级：banner `s31-firmware boot`、profile 期望的 `section:` 集合、每段
  `checks: passed=N failed=0`、聚合 `firmware: sections: passed=K failed=0 total=K`、
  `main: verdict=pass`；日志写入 `logs/e2e-<profile>-boot.log`。
- 结果输出 JUnit XML（`reports/e2e-*.xml`），供 CI 归档。

## 日志与证据

- 板级日志只增不改；E2E 使用 `logs/e2e-*.log`，历史日志 `logs/*-boot.log` 保持原名。
- 断言失败时 JUnit 的 `<failure>` 会带最后 4 KB 串口输出，便于定位。

## 本地运行

```bash
# 全部门禁
scripts/check-all.sh

# 单跑
scripts/check-fmt.sh
scripts/check-host.sh
python3 scripts/check-coverage.py
. /tmp/idfenv.sh && ESPTOOL="python -m esptool" python3 tests/e2e/run_e2e.py --host
python3 tests/e2e/run_e2e.py --board --profile net     # 需要板子与 idf-bootstrap/build
```
