# Zig × ESP32-S31 系统实现

本仓库是 [Zig × ESP32-S31 全栈开发](https://github.com/hlwqds/hl-ljj-quartz) 系列中**可构建的系统实现**，
从博客仓库 `hl-ljj-quartz` 的 `practice/zig-esp32-s31/` 与 `tools/s31-production/` 迁出，
用于独立开发与版本管理；教程正文仍留在博客仓库的 `content/zig-esp32-s31/`。

- **来源**：`hl-ljj-quartz@32f10c56`（2026-11-13）
- **形态**：每个章节一个自包含工程（形态 B：纯 Zig ELF + IDF 2nd-stage bootloader），
  另外包含 `tools/s31-production/` 生产化组件原型（netmgr / OTA / provisioning / recovery /
  baseline / HIL）。
- **硬件**：ESP32-S31-Function-CoreBoard-1（16 MB flash，UART0 `/dev/ttyUSB1` 115200 8N1）。

## 目录

| 路径 | 内容 |
| --- | --- |
| `ch01-board-id/` … `ch28-bootstrap-power-performance/` | 28 个章节工程（`docs`、`src`、`linker/s31.ld`、`idf-bootstrap/`、`tools/flash.sh`） |
| `logs/` | 板侧串口原始日志（`ch05-boot.log` … `ch28-boot.log`，以及 ch28 修复前的 `ch28a-boot.log`） |
| `SUITE-README.md` | 套件总览：工程清单、状态、约定（原博客仓库套件 README） |
| `SPEC.md` | 实现契约（目录约定、构建/烧录规范、日志与入库边界） |
| `BRINGUP-2026-11-12.md` | 真机 bring-up 报告（十轮实测记录与未闭环项） |
| `tools/s31-production/` | 生产化组件原型与基线/HIL 工具 |

## 快速开始

```bash
# 主机侧单测（不需要开发板）
cd ch20-tcp-state-machine && zig build test

# 交叉编译（Zig 0.17.1）
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# ELF → 镜像（esptool 5.6，需要 IDF python 环境）
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin   # 应恰好两行 DROM, IROM

# 烧录（先在同工程 idf-bootstrap/ 里跑一次 idf.py --preview set-target esp32s31 && idf.py build）
sh tools/flash.sh /dev/ttyUSB1
```

本机注意：`LD_LIBRARY_PATH` 指向旧 glibc 时需 `env -u LD_LIBRARY_PATH zig …`。

## 状态

ch01–ch28 全部落地；ch01–ch06、ch09–ch11、ch13–ch16、ch18、ch19 真机通过；
ch07/ch08/ch12/ch17 部分通过；ch20–ch28 板侧自检通过（非真链路）。
`tools/s31-production/` 的四个 Zig 切片宿主测试全绿（15/15、8/8、18/18、9/9），均未上板。
详细判据与未闭环项见 `SUITE-README.md`、`BRINGUP-2026-11-12.md` 与各工程 README。

## 与博客仓库的关系

- 本仓库当前是 `hl-ljj-quartz@32f10c56` 的**一份副本**（2026-11-13 迁出）；
  后续开发在**本仓库**进行，博客仓库保留快照直到其章节深链改指向本仓库。
- 博客站内代码浏览（`/static/code/`）仍指向 `hl-ljj-quartz` 中的原路径，短期不会失效。
- 章节正文里的 GitHub 源链（尤其 ch28）指向博客仓库；迁移完成后如需改指向本仓库，
  应同时更新正文链接。
