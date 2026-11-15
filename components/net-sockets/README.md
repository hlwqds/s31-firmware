# net-sockets — Socket API 与事件循环

FD 表、poll 就绪集、超时轮、连接池、部分读写与背压。

- 主机测试：**36 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `net-tcp`（经 `src/wire.zig` 做真实段适配）、`boards`

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |
| `src/wire.zig` | 真实 `tcp.Segment` ⇄ 组件 `netstub.Segment` 的适配层 |

历史来源见 `docs/HISTORY.md`。
