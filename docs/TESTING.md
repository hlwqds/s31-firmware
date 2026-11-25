# 测试框架

四层门禁，全部可在 CI 复跑；本地命令与 CI 完全一致。

| 层 | 内容 | 命令 | 门禁 |
| --- | --- | --- | --- |
| L1 单元 | 19 个测试项目的 `test` 块（1818 项） | `scripts/check-host.sh` | 合并前必须绿 |
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

窗口（2026-11-24 R5 扩容后两段各 `0x1C0000`，drom 基址 `0x401D0020`；此前 irom `0xC0000`、drom `0xB0000`）：
窗口只是链接上限，实际占用仍受 factory 分区约束。扩容前的历史数字（2026-11-16 实测，段长取自
`image-info` 的 Length 列）：`full`（TLS+Wi-Fi+apps）镜像 398 576 B（factory 余量 1 137 424 B），
IROM 段 305 696 B、DROM 段 70 796 B。扩容后的当前占用以 `check-capacity.py` 的输出为准。
自检方式：`CAP_WINDOW=0x40000` 跑一次，门禁必须报 `IROM ends at … > window end …`（证明断言不是恒真）。

两段窗口新上限的板级证明（`docs/verification/coex-verification.md` §7）：

```bash
# drom：DROM 段 1 046 816 B（旧上限 720 896 B），烧录后 8/8、verdict=pass
cd firmware && env -u LD_LIBRARY_PATH zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall -Dfat-rodata=1000000
```

irom 一侧的证据是合并镜像本身（IROM 段 825 744 B，旧上限 786 432 B），构建配方见
`docs/verification/coex-verification.md` §6.6。跑完 `-Dfat-rodata` 记得重建常规镜像。

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

### 先确认板上跑的是哪个构建（踩过的坑）

**改源码 ≠ 刷固件。** 做台架实验（ch21/ch22/ch23 的 lab、`-Dbench`/`-Dab-*` 变体）会把 lab 镜像
写到 `0x10000`，覆盖 factory 里的生产固件；随后只改源码、`git checkout` 回退，板上仍然是那份 lab 镜像。
此时抓串口只会看到 bootloader 的 `Loaded app from partition at offset 0x10000`，**容易被误判成"启动回归"**
（本会话就误判过一次）。

判据：串口**第一行**就能认出是谁 ——

| 首行 | 板上是 |
| --- | --- |
| `s31-firmware boot` | 生产固件（随后有 `ota: …` / `section: …` / `verdict=`） |
| `ch21-cwnd-emac-lab \| form B …`（或 ch22/ch23 名称） | 那一章的 lab 镜像 |
| `bench: rounds=…` 紧跟 lab 首行 | 该 lab 的 `-Dbench` 变体（跑完会 `halt`，不再有 `verdict`） |

回收方式：`sh firmware/tools/flash.sh <PORT> <生产 app.bin>`（走 esptool 硬复位，不依赖 DTR/RTS），
再抓一次确认 `ota: ab=…` 与 `main: verdict=pass`。`scripts/demo-board.sh` 的第 4 步会自己做这件事。
生产默认构建的自检要跑 **30~45 s**（net 组做真实计时），窗口给 45 s 才稳定看得到 `verdict`；
20 s 的窗口常常只抓到一半的 `check:` 行，别据此判断板子有问题。

### `zig build-obj` 的 `-target` 作用于其后声明的模块（踩过的坑）

用多模块命令单独编译一个自检时（`--dep … -Mroot=… -Mselftest=… -Mboard=…`），`-target`、`-mcpu`、`-O` 要写在**第一个 `-M` 之前**
（写一次，后面的模块沿用），或者逐模块写在各自 `-M` 的前面。方向记反会得到假绿：参数写在某个 `-M` **之后**，从下一个模块才生效，
根模块落回本机架构；写在最后一个 `-M` 之后，没有任何模块用到——2026-11-24 那条命令就是这样，根、自检、`board` 三个模块全是
本机 x86_64，退出 0 却什么都没证明（产物 `ELF64 … X86-64`）。判据是模块自己的文件里的编译期断言
（`builtin.target.cpu.arch != .riscv32` 即 `@compileError`），并拿错误写法做负对照；只看退出码不够。
命令与对照见 `docs/verification/wifi-ieee80211-verification.md` §5.1。
`firmware/build.zig` 不经命令行传模块：目标由 `b.standardTargetOptions` 定、挂在根模块上（`.target = target`），导入的模块继承它，不受影响。

### 板侧自检的两条隐性预算：抓取窗口与标称的 16 KiB 栈（2026-11-25，估算，未上板）

**抓取窗口。** `run_e2e.py --board` 调 `tools/capture.py … <秒数>`：复位之后抓这么久，全部 section 的判决必须在这之内
出来。默认 30 秒；`wifi` 60 秒、`full` 90 秒（`PROFILES` 里的 `capture_s`）。这两个 profile 的窗口放宽，是因为量过它们的
自检要算多久——工具是 `tools/qemu-instr`，读法见它目录里的 README：

- 把同一份 riscv32 ReleaseSmall 代码放到 QEMU 的 `virt` 机器上，开 `-icount shift=0`，读 RISC-V 的 `minstret` 计数器，
  得到精确的指令数。必须开 `-icount`，否则 `minstret` 是按流逝时间估的。
- 每条指令几个周期，用板上已有的实测校准：`boot-power-perf` 的 `workload.mix`（4096 字节）在 QEMU 里是 59433 条指令，
  板上（`logs/c7-perf-tiers.log`）是 59455 个周期，80 / 160 / 320 MHz 三档相同。**每条约 1 个周期**，即 80 MHz 下每秒
  约 8000 万条指令。只校准了这一种负载（乘法多、分支少），分支密集的代码按 1.0–1.3 理解。

`wifi` profile 各 section 的纯计算（`ok` 都为 1；网络组与 POSIX 的自检时间是注入的，没有真实等待）：

| section | 指令数 | 板上约 |
| --- | --- | --- |
| `wifi_connect`（199 条） | 15.48 亿 | 19.3 秒 |
| `ble_security`（25 条） | 2.19 亿 | 2.7 秒 |
| `net_congestion` | 914 万 | 0.11 秒 |
| `ble_802154`（152 条） | 625 万 | 0.08 秒 |
| `net_sockets`、`wifi_mlme`、`radio_coex`、`net_ipv4`、`net_tcp`、`net_udp_dhcp_dns`、`boot_power_perf`、`wifi_boundary`、`posix` | 合计 237 万 | 合计 0.03 秒 |
| `net_ethernet` | 量不了（真网卡） | — |

合计 17.84 亿条，光计算就 22.3 秒（按 1.3 周期一条是 29 秒），还没算启动、串口输出和 `net_ethernet` 在真链路上的等待。
第三批往 `wifi_connect` 里加了约 6.03 亿条（OWE 2.20 亿、SAE 其它群 3.74 亿、其余 0.09 亿），约 7.5 秒；第二批的
`wifi` 镜像按同一口径是 14.7 秒的计算，它在 30 秒窗口里跑得过。30 秒对第三批的镜像是压线的，所以放宽窗口，而不是
继续砍判据——剩下的每一条判据都对应一个不同的行为，砍掉就是实质减少板级证据。

第四批（2026-11-25）新加的六份子自检合计约 57 万条指令，占 `wifi` profile 的 0.03%；合计仍是 17.84 亿条
（精确值 1,784,445,194）、22.3 秒。这一批没有需要点乘的判据，离分配给每片的预算（2400 万条、0.3 秒）低两个数量级以上：

| 子自检（第四批） | 指令数 | 板上约 |
| --- | --- | --- |
| `wnm_tfs_selftest`（14 条） | 182300 | 0.002 秒 |
| `nd6_selftest`（30 条） | 152883 | 0.002 秒 |
| `owe_cache_selftest`（12 条） | 104108 | 0.001 秒 |
| `sfr_selftest`（16 条） | 75540 | 0.001 秒 |
| `ft_ric_selftest`（10 条） | 26181 | 0.000 秒 |
| `rrm_caps_selftest`（7 条） | 25348 | 0.000 秒 |

耗时集中在少数几处（指令数 / 板上约）：

| 判据 | 指令数 | 板上约 |
| --- | --- | --- |
| `sae_full_selftest.checkFsm`（9 条，每条一次完整的 SAE 交换；第二批） | 5.10 亿 | 6.4 秒 |
| `owe_selftest` 的 8 条（`checkRfc5903` 0.52 亿，`checkKat`、`checkAssoc` 各 0.42 亿，其余各约 0.21 亿） | 2.20 亿 | 2.8 秒 |
| `sae_full_selftest.checkEcc`（4 条；第二批） | 1.42 亿 | 1.8 秒 |
| `sae_groups_selftest` 的 7 条 FFC PWE（群 18 一条就 0.64 亿） | 1.35 亿 | 1.7 秒 |
| `sae_groups_selftest.negotiateOk` | 0.83 亿 | 1.04 秒 |

单位成本：标准库的 P-256 标量乘（常量时间）约 2070 万条指令，板上约 0.26 秒。OWE 的每条判据差不多就是一次点乘；
真实链路上一次 SAE 握手要五六次，约 1.5 秒。SAE 其它群的自检原先九个群全做双端对打，已收窄成只做 ECC 25（其余八个群
只验群的参数；FFC 2 去掉要模指数的那条拒绝），判据仍是 33 条。收窄之前只有主机耗时（x86 ReleaseFast 上 19–36 ms，
收窄后 2.4 ms）——主机耗时换算不到板上，那次收窄的依据是相对关系；指令数是之后才量的。

往自检里加东西，前后各跑一次 `tools/qemu-instr`。板上的实际耗时到现在没有量过（板子不在手边）；上板后如果 `wifi`
profile 仍出不来 `verdict`，用 `tools/qemu-instr` 定位是哪个 section，不要只调窗口。

栈：`boards/esp32s31-coreboard/linker/s31.ld` 给主栈 16 KiB，注释写明 8 KiB 会溢出。拿保留符号的镜像
（`zig build … -Dkeep-symbols=true`），把各函数序言里对 `sp` 的调整量沿调用链相加（调用边取 `jal` / `jalr` 的直接目标；
间接转移、中断与 trap 的帧都不计，所以这是下界）。从 `main.main` 起最深的一条链：

| 镜像 | 调用链（括号里是各自的栈帧，字节） | 合计 |
| --- | --- | --- |
| 第三批之前（`8c2cef8`） | `main.main`（6608）→ `selftest.runChecks.4`（4992）→ BIP 校验 → `bip.micOver`（8960）→ AES-CMAC | 26544 |
| 第三批，对打收窄之后、加 `noinline` 之前 | `main.main`（6608）→ `selftest.runChecks.4`（8144）→ `sae_groups_selftest.run`（8400）→ `montMul`（5168）→ `cmp`（2064） | 30384 |
| 第三批，只给九份新入口加 `noinline` | `main.main`（6608）→ `selftest.runChecks.4`（6144）→ `pweOk`（群 18，8288）→ `montMul`（5168）→ `cmp`（2064） | 28272 |
| 第三批，第一、二批的三份入口也加上之后 | `main.main`（6608）→ `selftest.runChecks.4`（1120）→ `pweOk`（群 18，8288）→ `montMul`（5168）→ `cmp`（2064） | 23248 |
| 第四批之后（2026-11-25） | 同上：`main.main`（6608）→ `selftest.runChecks.4`（1120）→ `pweOk`（群 18，8288）→ `montMul`（5168）→ `cmp`（2064） | 23248 |

五条都越过了标称的栈底。第三批之前的镜像在板上跑得过，而栈底下面是堆区（`_heap_start` 到 `_stack_bottom`，那个镜像里
271 KiB），固件里也没有栈水位或栈底守卫（源码里除链接脚本外没有引用 `_stack_bottom`）——推断是自检期间栈写进了堆区的
空闲部分、没有撞到东西；没有在板上量过。`runChecks.4` 是 `wifi-connect` 的自检驱动函数：第一、二批的三份子自检入口原先
也被内联在它里面，所以只给第三批的入口加 `noinline` 时最深链反而比之前深（28272 对 26544），三份入口一起加上才降下来。
`ble-802154` 与 `wifi-mlme` 的驱动函数（`runChecks.3`、`runChecks.2`）栈帧没变（1136、9232），其下最深分别是 11984 与 12176 字节。
`wifi-mlme` 原为 11248：第四批的 `wnm_tfs_selftest.checkMatch`（栈帧 1504）经 `wnm.parseTclasElement`、`wnm.parseTfsSubelement`
这条链把它抬高了 928。第四批没有改变全局最深链。这一轮的估算脚本是一次性的（`/tmp/r5c/stack_depth.py`，没有入库），
它在改动前的镜像上复现了上表最后两行的数；两个解析上的坑：`nm` 输出里符号名可以带空格（`bignum.ModArith(…).montMul`
的编译期参数里有「, 」），要按「最多切 4 段」解析；`jalr` 省略 rd 时默认是 `ra`，是调用而不是尾调用。
做法只有一条：给自检入口和每条判据的函数加 `noinline`，让各自的大数组落在各自的帧里，而不是叠在调用方上。
做这种估算有两个坑：栈帧大小经由 `li` 加 `slli` 装进寄存器的函数（`bip.micOver` 的 8960 字节就是这样）要跟到常量，
否则会漏掉整帧——第一次估算因此把第三批之前的最深链少报了 2320 字节；链要从 `main.main` 起算，别把尾调用的求和混进来。
往自检里加定长大数组之前先看这张表；`main.main` 那 6608 字节和 `bignum.zig` 的 `cmp`（把两个参数各拷一份进自己的帧）
是以后可以压的两处。

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

## 验证覆盖审计（功能待办清空之后）

「没有 TODO」不等于「都验过」。四个陷阱会让"跑过"变成假象，每条都踩过：

| 陷阱 | 表现 | 规避 |
| --- | --- | --- |
| **缓存静默** | `zig build test` 命中缓存 ⇒ **rc=0 且零输出**；`--summary all` 只打 `run test cached` | 必配 `--summary all` **和** 每次独立的 `--cache-dir` |
| **管道吃输出** | `cmd \| tail -3` 可能什么都不留；`$?` 取的是 `head` 的退出码 | 重定向到文件，再 `grep '^Build Summary'` / 单独取 `$?` |
| **改源码 ≠ 刷固件** | lab/bench/demo 镜像覆盖了 factory，回退源码后串口只剩 bootloader 行 ⇒ 像"启动回归" | 看串口**首行**（见上节表格），需要时重刷生产固件并确认 `verdict=pass` |
| **过期的"预期失败"** | 步骤名写 `xfail tls`，而命令其实跑全部 profile 且 tls 已通过 | 审计时逐个核对步骤名与实际命令 |
| **缺键的基线** | `tests/baselines.json` 里没有某组件的键 ⇒ 基线按 0 算 ⇒ 它的用例**完全不受保护**（`bt-blobs` 曾有 36 项如此） | 加组件时同步加键；改完用 `check-coverage.py` 看 `actual` 与 `baseline` 是否相等 |
| **文档里的数字** | 表格/README 引用的是旧的或别的单元的计数（三处 `14/14` 实为 28；`net-wire` README 曾把 lab 的计数当成组件的） | 改完代码后核对：主机用例数、板侧 checks 数、lab 用例数**是三个不同的数**，别混用 |
| **Debug 下比较可选的错误值** | Zig 0.17.1 的 Debug 构建里 `?E == ?E` 恒为假，ReleaseSafe、ReleaseSmall、ReleaseFast 才正确。主机测试是 Debug、板上固件是 ReleaseSmall ⇒ 断言相等的用例莫名失败，断言不相等的莫名通过 | 先解包再比：`if (opt) \|v\| v == error.X else false`；排查时把合取条件逐项单独打印。最小复现见 `docs/verification/coex-verification.md` §3.5 |
| **没有测试目标的组件** | `check-coverage.py` 只数 `test` 的文本个数，`check-host.sh` 只跑 `zig build test` 里有的目标——没有自检 section 的组件（`wifi-blobs`）两边都覆盖不到：26 个用例从没被跑过，测试文件本身也早就编不过 | 没有自检 section 的组件在 `build.zig` 里加显式测试目标；加组件或加用例后看测试器报告的 total 有没有跟着涨 |
| **用例发现只认直接的 `@import`** | `test` 块里写 `_ = x`（`x` 是文件顶层的 `const x = @import("x.zig")`）不会跑 `x.zig` 里的用例，编译和运行都不报错 | `test { _ = @import("x.zig"); }` 直接写在块里 |
| **保留符号表的镜像不等同于 strip 的镜像** | `-Dkeep-symbols=true` 只是为了用 `nm` 核对符号；`trapDispatch` 按有没有符号信息选诊断路径，`.flash.text` 有 4 个字节随之变化 | 只拿它核对符号；逐字节对比与上板取证都用默认（strip）构建 |

本仓的入口清单（`check-all` 覆盖前 8 项）：

```bash
scripts/check-all.sh                   # yaml/invariants/fmt/host/coverage/update_matrix/partition/capacity + 六 profile
# invariants 含：前门测试总数（README/ROADMAP/TESTING）必须等于 tests/baselines.json 的合计
#             以及 run_e2e.py 每个 profile 的 section 列表必须与 all_modules 的顺序逐项一致（e2e 有序比较）
scripts/build-image.sh firmware <dir>  # 两段镜像断言；<dir> 必须先存在
tests/e2e/run_e2e.py --board --profile net|tls     # 不需要主机网络的板级 e2e
scripts/demo-board.sh <PORT>           # A/B 九项断言
scripts/gate-board.sh                  # 需免密 sudo（host-prep 动 iptables）；前置失败会 exit 2
tools/s31-production/baseline/inventory.py [--strict]   # --strict 只查文件存在，不判断测试是否在别处跑
scripts/gen-blob-stubs.py              # 生成器：无参即重写 zz_stubs.c（幂等，但探活前先看它会写哪些文件）
```

`--strict` 的已知标记（不是缺陷）：`net-wire` 无 `host_tests`（薄 I/O 胶水，见其 README）、
`firmware` 与 `esp32s31-coreboard` 的测试分别聚合在组件与板级包之外。
