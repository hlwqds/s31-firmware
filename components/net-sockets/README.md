# net-sockets — Socket API 与事件循环

FD 表、poll 就绪集、超时轮、连接池、部分读写与背压。

- 主机测试：**38 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `net-tcp`（经 `src/wire.zig` 做真实段适配）、`boards`
- **就绪通知（2026-11-18）**：`socket.Table.on_ready`（默认 `null`，不绑定时行为与旧版完全一致）
  在 `deliver`（SYN 填 backlog / 数据段到达）、`close`、`abort` 改变就绪状态时触发。
  它是"轮询模型"通向"阻塞 API"的唯一接缝：`posix-compat` 的 `fd.acceptBlock` 就靠它把
  `sem_post` 接上一次。回调**同步**跑在喂数据的那个任务里，只能做轻量动作（如 `sem_post`）。
  `Table.reset()` 会**保留**钩子（它描述"这张表怎么被通知"，不是表的内容）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |
| `src/wire.zig` | 真实 `tcp.Segment` ⇄ 组件 `netstub.Segment` 的适配层 |

历史来源见 `docs/HISTORY.md`。
