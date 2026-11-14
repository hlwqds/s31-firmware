# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Planned
- P1：以太网 ARP/ICMP 上层（DMA 已闭环）

### Fixed
- net-ethernet：DMA 不取描述符的根因是 APM 控制过滤器。IDF app 在
  `bootloader_init_mem()` 里关闭 `HP/MEM/LP_APM_FUNC_CTRL`，二级 bootloader
  因 `#if !BOOTLOADER_BUILD` 跳过；`enableBusClock()` 现补 `enableApmForDma()`。
  板侧：TX `done in 15us`、RX 2 帧 94 B IPv6 组播。

### Changed
- P0.2：flash 窗口扩至各 0x7F000、drom 基址 0x40080020，全特性单镜像可链接（板上 11/11）
- 组件内 `hw.zig`/`log.zig` 副本移除，统一引用 `board.hw` / `board.log`

## [0.3.0] - 2026-11-13

### Changed（破坏性）
- 项目更名 `s31-zig-system` → `s31-firmware`：仓库/目录、`esp_app_desc_t.project_name`、
  固件 banner、IDF 工程名（`zig_s31_system_firmware` → `zig_s31_firmware`）全部更新
- 启动路径唯一化：删除 `boards/.../start.zig`，`_start` 与 app_desc 只归 `firmware/src/start.zig`
- E2E 板级用例先按 profile 构建、镜像同步到 `zig-out/bin/app.bin`，段集合改为精确相等断言

## [0.2.0] - 2026-11-13

### Added
- 测试框架：`docs/TESTING.md`、`scripts/check-all.sh`、单元覆盖率门禁（模块可达性 + 基线）、
  E2E profile 矩阵与 JUnit 报告（`tests/e2e/run_e2e.py`）

### Changed
- 重构为生产结构：`firmware/` + `boards/` + `components/`，移除章节目录（历史见 `docs/HISTORY.md`）
- 新增编译期特性开关与聚合测试（11 个组件，323 项）
- 新增仓库规范、路线图、CI、脚本与 ADR 模板
- 默认配置（boot+net）上板：6 个子系统自检全过，`main: verdict=pass`（`logs/firmware-boot.log`）

## [0.1.0] - 2026-11-13

### Added
- 从 `hl-ljj-quartz@32f10c56` 迁出 28 个章节工程与 `tools/s31-production` 生产化原型
- 板侧日志（`logs/ch05-boot.log` … `logs/ch28-boot.log`，含 ch28 修复前 `ch28a-boot.log`）
- 仓库规范：`AGENTS.md`、`docs/REPO-STANDARDS.md`、`ROADMAP.md`

### Fixed（相对迁出来源）
- Zig 0.17 `[...]T{…} ** n` 数组重复语法（平台迁移到 `@splat`）
- ch28 首烧 `mstatus.FS=0` 导致浮点指令 illegal instruction
- provisioning 两条过强不变量测试
