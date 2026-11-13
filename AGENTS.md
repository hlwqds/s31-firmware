# s31-firmware 工程约定

本仓库是 ESP32-S31 系统的**唯一开发地**。以下约束来自真机 bring-up 的实测。

## 工具链

- Zig 0.17.1；如会话带旧 glibc 的 `LD_LIBRARY_PATH`：
  `env -u LD_LIBRARY_PATH /nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig …`
- 交叉编译固定 `-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei`（写 `esp32s31` 会 configure 失败）。
- 镜像必须**恰好两个** flash 段：`Merged 2 ELF sections.`，`image-info` 的 `DROM, IROM` 行数为 2。
- 裸机浮点：`_start` 必须置 `mstatus.FS=Initial`（`csrs mstatus, 0x2000`），否则第一条浮点指令即非法指令。

## 结构

- `firmware/`：唯一固件入口（`src/start.zig`），特性开关在 `firmware/build.zig`。
- `boards/esp32s31-coreboard/`：链接脚本、板级文档、板级源码参考。
- `components/<subsystem>/src/`：子系统逻辑 + `host_tests.zig`（`firmware` 的 `test` step 聚合）。
- `tools/s31-production/`：生产化组件原型与 HIL/基线工具。
- `logs/`：历史板侧日志，**只增不改**；`docs/history/`：章节时代的 SPEC/总览/bring-up 报告。

## 板子与证据

- 串口 `/dev/ttyUSB1` 115200 8N1；一块板，烧录/抓串口必须
  `flock /tmp/s31-board.lock`。抓串口用 `python3 tools/capture.py`。
- **只有日志里出现过的才算实测**；其余写「待真机验证」并给判据。不得把模型值写成实测值。
- 每个案例新开日志 `logs/<case>-boot.log`，修复前后各留一份。

## 提交

- Conventional Commits；`feat:`/`fix:` 附验证命令或日志路径。
- 提交前：`scripts/check-fmt.sh`、`scripts/check-host.sh`，涉及镜像时 `scripts/build-image.sh firmware`。
- 不提交生成物（`zig-out/`、`.zig-cache/`、`build*/`、`sdkconfig`、`*.bin`、`*.elf`）与密钥。
