## 变更内容

<!-- 一段话说明做了什么、为什么 -->

## 证据

- [ ] `scripts/check-fmt.sh` 通过
- [ ] `scripts/check-host.sh` 通过（或列出受影响工程的 `zig build test` 结果）
- [ ] `scripts/build-image.sh <工程>` 通过（涉及镜像/链接布局时）
- [ ] 板侧自检日志（涉及硬件行为时）：`logs/...`，含 `checks: passed=N failed=0` 与 `verdict=pass`
- [ ] 未把模型值写成实测值；未引入生成物（`zig-out/`、`.zig-cache/`、`build*/`）

## 影响面

- [ ] 接口/ABI 变更（需 ADR）
- [ ] 分区布局/链接布局变更
- [ ] 文档状态同步（工程 README、SUITE-README、BRINGUP）
