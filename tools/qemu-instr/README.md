# qemu-instr：数板侧自检在 rv32 上执行了多少条指令

`wifi` 镜像的自检要在 e2e 的抓取窗口内出判决，而板子常常不在手边。这个工具用 QEMU 把**同一份
riscv32 代码**跑一遍，精确数出指令数，再按「指令数 ÷ 80 MHz」折算板上的计算耗时。

为什么不用主机耗时：主机上 x86 的指令流与 rv32 完全不同（更宽的寄存器、向量化），同一份自检在主机上是
几毫秒、在板上是几秒，两者之间没有可靠的换算比例。这里跑的就是板子那份指令流，只差「每条指令几个周期」
一个系数，而这个系数可以用板上的实测来校准。

## 跑

前置：`zig` 在 PATH 里；`qemu-system-riscv32`。NixOS 上：

```sh
nix shell nixpkgs#qemu --command sh tools/qemu-instr/run.sh        # 全部
QEMU=/nix/store/…/bin/qemu-system-riscv32 sh tools/qemu-instr/run.sh cal section   # 只跑某几组
```

四组：`cal`（校准）、`section`（纯逻辑组件的整份自检）、`sub`（各份子自检本体）、`net`（网络组、POSIX、
功耗性能）。输出一张表：名称、指令数、判据条数或 `ok`、`board_s`（指令数 ÷ 80 MHz）、QEMU 墙钟秒数。

## 读

- **`cal` 行**是校准：`workload.mix`（4096 字节的 64 位 ARX 混合）在 QEMU 里是多少条指令。板上对同一个
  负载有实测，`logs/c7-perf-tiers.log` 的 `cycles_p50=59455`，三档频率下相同。两者相除就是这块板子跑这类
  代码时每条指令的周期数。2026-11-25：59433 条指令对 59455 个周期，**约 1.0**，即 80 MHz 下每秒约 8000 万条
  指令。五次读数不全相同，说明 `-icount` 没开（那时 `minstret` 是按时间估的），结果不能用。
- **`board_s` 一列**是纯计算耗时，按 1 周期一条指令折算。校准只做了这一种负载（乘法多、分支少）；分支密集
  或首次取指的代码每条指令可能略多，按 1.0–1.3 理解。
- **`section:*` 行**是各 section 的整份自检，板级桩不打印，所以不含串口输出时间（约 11.5 KB/s）。
  `net` 一组的桩让时钟按板子的速度走，自检里按时间等待的循环因此被如实数进去（实测这几个 section 的自检
  时间都是注入的，没有真实等待）；`net_ethernet` 依赖真网卡，量不了。

## 局限

- 只量计算。串口输出、flash 冷缓存取指、板上中断与 trap 的开销都不在内。
- 每指令周期数只用一种负载校准过，没有在板上直接量过任何一份自检的耗时。
- 栈是 1 MiB，不反映板上的栈深度（那是另一回事，见 `docs/TESTING.md`「板侧自检的两条隐性预算」）。
- 自检本体与镜像里的是同一份源码、同样的编译参数；入口与板级桩不同，所以自检之外的几条指令有出入。
  没有拿镜像里的指令流逐条对过。

## 2026-11-25 的读数（提交 `3faca4e` 的代码）

| 对象 | 指令数 | 板上约 |
| --- | --- | --- |
| `section:wifi-connect`（177 条） | 15.48 亿 | 19.3 秒 |
| 其中 `sae_full_selftest`（24 条，第二批） | 7.88 亿 | 9.8 秒 |
| 其中 `sae_groups_selftest`（33 条，第三批） | 3.74 亿 | 4.7 秒 |
| 其中 `owe_selftest`（18 条，第三批） | 2.20 亿 | 2.8 秒 |
| `section:ble-security`（25 条） | 2.19 亿 | 2.7 秒 |
| `section:net-congestion` | 914 万 | 0.11 秒 |
| `section:ble-802154`（106 条） | 600 万 | 0.08 秒 |
| `section:net-sockets`、`wifi-mlme`、`radio-coex`、`net-ipv4`、`net-tcp`、`net-udp-dhcp-dns`、`boot-power-perf`、`wifi-boundary`、`posix` | 合计 215 万 | 合计 0.03 秒 |

`wifi` profile 除 `net_ethernet` 外合计 17.84 亿条，光计算 22.3 秒（按 1.3 周期一条是 29 秒）。

单次成本：标准库的 P-256 标量乘（常量时间）约 2070 万条指令，板上约 0.26 秒。`sae_full_selftest` 的
`checkFsm`（9 条，每条一次完整的 SAE 交换）5.10 亿条，6.4 秒；OWE 的每条判据差不多就是一次点乘。

第三批往 `wifi_connect` 里加了约 6.03 亿条指令（OWE 2.20 亿、SAE 其它群 3.74 亿、其余 0.09 亿），
约 7.5 秒；第二批的 `wifi` 镜像按同一口径是 14.7 秒的计算，在 30 秒窗口里跑得过。30 秒对第三批的镜像压线，
所以 `tests/e2e/run_e2e.py` 给 `wifi` 的抓取窗口放宽到 60 秒（`full` 是它的超集，90 秒）；其余 profile 不变。

## 第四批之后的读数（2026-11-25）

- `section:wifi-connect`（199 条）1547931525 条、19.35 秒；`section:ble-802154`（152 条）6254862 条、0.08 秒；
  `section:wifi-mlme` 889505 条；其余 section 与上表相同（`cal` 读数仍是 59433）。
- `wifi` profile 除 `net_ethernet` 外合计 1784445194 条（17.84 亿）、22.31 秒。第四批新加的六份子自检合计 566360 条，
  占 0.03%：`sub:wnm_tfs` 182300、`sub:nd6` 152883、`sub:owe_cache` 104108、`sub:sfr` 75540、`sub:ft_ric` 26181、
  `sub:rrm_caps` 25348。
- `sub` 组会把三个组件下所有 `*_selftest.zig` 都量一遍。只量其中几份时，照 `run.sh` 的编译与测量逻辑写一个按文件名过滤的包装，
  并先跑一次 `cal` 确认读数稳定。

## 第五批之后的读数（2026-11-25，独立评审返修之后的终态）

- 第五批新增六份子自检，逐片（riscv32 ReleaseSmall，`build-obj` text / QEMU 指令数）：`wnm_rest` 21867 B、50356 条；
  `blockack` 3461 B、155665 条；`gas` 7810 B、9300 条；`pawr` 5709 B、10630 条；`subrate` 1348 B、3954 条；`iso` 6514 B、9011 条。
  六片 text 合计 46709 B（数字取自逐片验收记录）。
- 整份 section 在第五批终态的读数（标定 59433，稳定）：`section:wifi-connect`（199 条）1547931525 条、19.349 秒（不变）；
  `section:wifi-mlme`（121 条）1136527 条、0.014 秒；`section:ble-802154`（207 条）6307161 条、0.079 秒；
  `section:ble-security` 218744606 条、`section:radio-coex` 195876 条、`section:wifi-boundary` 34675 条（与之前相同）。
  整份 profile 的合计没有重算。

## 文件

| 文件 | 作用 |
| --- | --- |
| `start.zig` | 根模块：入口（关中断、打开浮点状态、清 BSS、设栈）、读 `minstret`、经 UART 打印、经 `virt` 机器的测试设备退出 |
| `section.zig` / `sub.zig` / `cal.zig` | 三种测量模块（接口都是 `pub fn run() u32`），由命令行的 `-Mmeasure=` 选一个 |
| `board_stub_bare.zig` / `board_stub_time.zig` | 顶替 `board` 模块的桩：时钟不走 / 时钟按板子的速度走 |
| `virt.ld` | `virt` 机器的链接脚本（RAM 从 0x80000000 起，栈 1 MiB） |
| `run.sh` | 驱动：按固件同样的参数编译、在 `-icount shift=0` 下运行、汇总成表 |
