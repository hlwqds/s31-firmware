# Contributing

## 环境

- Linux x86_64、Zig 0.17.1、Python 3.12（仅 `tools/` 下脚本与 esptool 需要）。
- 会话若设置了旧 glibc 的 `LD_LIBRARY_PATH`，所有 `zig` 命令前加 `env -u LD_LIBRARY_PATH`。
- 烧录/抓串口需要 ESP32-S31 CoreBoard 与 `/dev/ttyUSB1`；CI 的自托管 job 见 `.github/workflows/ci.yml`。

## 提交前

```bash
scripts/check-fmt.sh
scripts/check-host.sh
scripts/build-image.sh firmware                            # 涉及镜像/链接布局时
```

涉及硬件行为的改动还需要一份板侧日志：

```bash
cd firmware
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
python3 ../tools/capture.py /dev/ttyUSB1 ../logs/firmware-boot.log 20
```

日志必须包含 `checks: passed=N failed=0` 与 `main: verdict=pass`，否则按「待真机验证」记录，不得写成已通过。

## 约定

- 提交信息用 Conventional Commits；`feat:`/`fix:` 必须写清验证方式（命令或日志路径）。
- 一个 PR 只做一件事；跨工程改动在描述里列出影响面。
- 新增工程同步更新 `SUITE-README.md`；状态变化同步工程 README 与 `BRINGUP-2026-11-12.md`。
- 破坏 ABI、分区布局、链接布局的改动必须先提 ADR（`docs/adr/`）。
- 不提交生成物与密钥；测试凭据只提交 `*.example`。

## 分支与合并

- `main` 受保护；分支命名 `feat/<topic>`、`fix/<topic>`、`docs/<topic>`。
- 合并方式 squash；合并前 CI 必须绿（`host` + `image` 两个 job）。
