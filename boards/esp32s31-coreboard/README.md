# boards/esp32s31-coreboard

板级层：链接脚本与板级源码（启动、异常、日志、寄存器）。

- `linker/s31.ld`：两个 flash 装载段（`irom 0x40000020` / `drom 0x401D0020`，窗口各 `0x1C0000`；2026-11-24 扩容）、
  `.trap_ram`、栈/堆边界与镜像 ASSERT。
- `src/hw.zig` / `src/log.zig` / `src/trap.zig`：寄存器、串口输出、trap 入口（导出符号）。
- `src/clock.zig` / `src/pmu.zig` / `src/apm.zig` / `src/rng.zig`：时钟适配与慢时钟标定值、modem 的 ICG 码（IDF `pmu_init()` 里的一步）、
  关掉 APM 访问控制过滤器（IDF 应用启动期 `bootloader_init_mem()` 里的一步，裸机镜像必须自己做）、LP TRNG。

固件从 `board` 模块引用 `hw`/`log`/`trap`；组件只经 `board.trap` 使用异常辅助，避免多份 `trapEntry` 符号冲突。

启动路径（`_start`、`esp_app_desc_t`）**唯一归属** `firmware/src/start.zig`；板级层不再保留副本，避免版本号/身份漂移。
