# s31-zig-system 工程约定

本仓库是 Zig × ESP32-S31 系统的**唯一开发地**（教程正文在 `hl-ljj-quartz`）。
以下约束来自十轮真机 bring-up 的实测，违反会直接导致烧不出、跑飞或假象。

## 工具链

- Zig 0.17.1。会话若带旧 glibc 的 `LD_LIBRARY_PATH`，必须：
  `env -u LD_LIBRARY_PATH /nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig …`
- 交叉编译 CPU 串固定为
  `-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei`；写 `esp32s31` 会在 configure 阶段失败。
- 镜像必须**恰好两个** flash 段：`elf2image` 打印 `Merged 2 ELF sections.`，
  `image-info` 的 `DROM, IROM` 行计数为 2（rodata 因 `align(64)` 可落在 `0x40020040`，段数仍须 2）。

## 板子

- 串口 `/dev/ttyUSB1`，115200 8N1；串口权限掉线重插后需重新 `chmod 666`。
- **一块板**：任何烧录/抓串口都必须串行化：
  `flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'`。
- 抓串口先开端口再拉 RTS 复位（DTR+RTS 同拉会进下载模式）；抓到的日志先看 banner 是否本工程。
- `tools/flash.sh` 依赖同工程 `idf-bootstrap/build/flash_args`；该目录不入库，
  新克隆需先 `cd idf-bootstrap && idf.py --preview set-target esp32s31 && idf.py build`。

## 证据口径

- **只有日志里出现过的字符串才算实测**；其余一律写「待真机验证」并给出判据。
- 每个案例新开日志：`logs/chNN-boot.log`（多轮用 `chNNb-`、`chNNa-` 等后缀），不覆盖旧轮次。
- 章节/README 引用的 `check:`/`checks:`/`main:` 行必须与日志逐行一致。
- 判据数在 `build.zig`、`src/main.zig`、`src/selftest.zig`、`linker/s31.ld`、README 五处一致。

## 目录

- `chNN-<kebab-slug>/`：章节工程（自包含：`src/`、`linker/s31.ld`、`idf-bootstrap/`、`tools/flash.sh`）。
- `logs/`：板侧原始日志（只增不改）。
- `tools/s31-production/`：生产化组件原型；其 `baseline/inventory.py` 默认把本仓库根当作套件根。
- `SPEC.md` / `SUITE-README.md` / `BRINGUP-2026-11-12.md`：契约、总览与十轮实测记录。
