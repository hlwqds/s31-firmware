# 仓库规范

适用范围：本仓库全部工程、脚本与文档。与 `AGENTS.md`（硬约束速查）冲突时，以本文为准并同步更新 `AGENTS.md`。

## 1. 目录与命名

```
.
├── firmware/                  # 单一固件（start/main、idf-bootstrap、flash.sh）
├── boards/esp32s31-coreboard/ # 板级层（linker、hw/log/trap、板卡说明）
├── components/<subsystem>/     # 子系统（net / apps / wifi / boot-power-perf；各自带 host_tests）
├── tools/s31-production/      # 生产化组件（netmgr/ota/provisioning/recovery/基线/HIL）
├── logs/                      # 板侧原始日志，只增不改
├── scripts/                   # 仓库级脚本（CI 与本地共用）
├── docs/                      # 规范、架构、ADR、历史
├── ROADMAP.md / CHANGELOG.md
└── README.md / AGENTS.md / CONTRIBUTING.md / SECURITY.md
```

- 组件目录名 = kebab-case 子系统名（`net-tcp`、`app-mqtt-ota`…），不按章节编号；历史映射见 `docs/HISTORY.md`。
- 组件内部布局：`src/*.zig` + `src/host_tests.zig`（测试入口）；固件固定布局：`firmware/src/{start,main}.zig`、`firmware/build.zig`、`firmware/idf-bootstrap/`、`firmware/tools/flash.sh`。
- 新增组件必须更新 `docs/HISTORY.md` 的映射与 `ROADMAP.md` 的能力表；涉及决策的变更写 `docs/adr/ADR-NNN-*.md`。
- 日志命名 `logs/<case>-boot.log`；同名案例多轮用后缀 `b-`、`c-`；修复前/后各留一份。

## 2. 构建与工具链

- Zig **0.17.1**；交叉编译 CPU 串固定 `generic_rv32+m+a+c+f+zicsr+zifencei`（`esp32s31` 会在 configure 阶段失败）。
- 主机测试不依赖开发板：`zig build test` 必须在任意 Linux 上通过。
- 镜像必须**恰好两个** flash 段：`elf2image` 打印 `Merged 2 ELF sections.`，`image-info` 的 `DROM, IROM` 行数为 2。
- `linker/s31.ld` 必须把 trap 向量放 SRAM（`.trap_ram`）；`mtvec` 低 2 位恒为 3（只比较 BASE）。
- 裸机启用浮点前必须置 `mstatus.FS=Initial`（`csrs mstatus, 0x2000`）；否则第一条浮点指令即 illegal instruction（见 `logs/ch28a-boot.log`）。
- 生成物一律不入库：`zig-out/`、`.zig-cache/`、`idf-bootstrap/build*/`、`sdkconfig`、`*.bin`、`*.elf`（见 `.gitignore`）。

## 3. 依赖策略

- 只允许 **IDF 树内组件**与 **Zig 标准库**；不引入 managed component、不 vendored 厂商库、不下载二进制到仓库。
- 需要外部归档时，只能在文档里引用本机 IDF 路径并给出 `nm`/`ar` 取证脚本，不复制归档。
- 新依赖必须说明：为什么标准库不够、体积/许可证影响、如何验证（KAT 或等价判据）。

## 4. 测试分级与证据口径

| 级别 | 内容 | 何时必需 |
| --- | --- | --- |
| L1 主机单元 | 纯逻辑、向量、状态机、编解码 | 每次提交（CI 强制） |
| L2 镜像 | 交叉编译 + 两段镜像 + 段表判据 | 每次提交（CI 强制，至少一个代表工程） |
| L3 板侧自检 | 烧录后 `check:` 判据全过、`verdict=pass` | 合并前（有板时）；无板时以 L1/L2 通过并标「待真机验证」 |
| L4 真链路/计量 | 抓包、吞吐、电流、唤醒时间 | 版本发布前，按 ROADMAP 各阶段出口 |

证据规则：

- 只有**日志里出现过的字符串**才算实测；其它一律写「待真机验证」并给出判据。
- 引用日志的文档必须给出路径；日志只增不改，修复前后各留一份。
- 判据条数在 `build.zig`、`src/main.zig`、`src/selftest.zig`、`linker/s31.ld`、`README.md` 五处一致。
- 禁止把模型值写成实测值；模型值与实测值必须分列并标注口径。

## 5. 提交与评审

- 提交信息：Conventional Commits（`feat:`/`fix:`/`docs:`/`test:`/`chore:`/`refactor:`），一行摘要 ≤ 72 字符，正文解释「为什么」与验证方式。
- 分支：`main` 受保护；开发分支 `feat/<topic>`、`fix/<topic>`；合并使用 squash merge。
- 一个 PR 只做一件事；改动跨工程时说明影响面。
- PR 模板中的检查清单必须逐条勾选，未勾选项需在描述中说明原因。
- 评审重点：证据是否可复现、是否有未标注的模型值、是否破坏两段镜像/链接布局、是否引入生成物。

## 6. 版本与发布

- 语义化版本 `vMAJOR.MINOR.PATCH`；`MAJOR` 变更指破坏 ABI/接口/分区布局。
- 每次发布：更新 `CHANGELOG.md`、打 tag、附发布包（镜像 + 日志摘要 + SHA256 + 复现命令）。
- `tools/s31-production/*` 的接口变更必须先写 ADR，再改实现与调用方。
- 发布包不包含 `zig-out/` 全目录，只包含应用镜像与 bootloader/分区表（若适用）。

## 7. 硬件与共享资源

- 板卡：ESP32-S31-Function-CoreBoard-1，UART0 `/dev/ttyUSB1` 115200 8N1。
- 一块板 = 一个独占资源：烧录与抓串口必须 `flock /tmp/s31-board.lock`。
- 串口权限（`chmod 666`）掉线重插后需重做；CI 自托管 runner 上以 udev 规则固化。
- 禁止在仓库写入密钥、Wi-Fi 密码、证书私钥；测试用凭据必须是 `*.example` 模板。

## 8. 文档

- 每个工程 README 必须含：所属章节/来源、验证状态（哪一级证据）、快速开始、文件职责、待验证项。
- 状态变更必须同步：工程 README、`SUITE-README.md`、`BRINGUP` 三处一致。
- ADR 模板见 `docs/adr/ADR-000-template.md`；编号递增，状态 `proposed/accepted/superseded`。

## 9. CI 门禁

合并到 `main` 的前置条件：

1. `scripts/check-fmt.sh` 通过（`zig fmt --check`）。
2. `scripts/check-host.sh` 通过（固件聚合测试 + `tools/s31-production/*`）。
3. `scripts/build-image.sh firmware` 通过（两段镜像判据）。
4. 文档变更需通过 Markdown 链接检查（相对路径必须存在）。

自托管 runner 上的板级任务（`workflow_dispatch` 触发）不属于合并门禁，但发布前必须跑过一次。
