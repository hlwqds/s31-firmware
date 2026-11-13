# net-tcp — TCP 状态机与可靠传输

11 态机、seq/ack 回绕、RFC 6298 RTO、乱序重组、TIME_WAIT。

- 主机测试：**27 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `boards`；不依赖其它组件

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |

历史来源见 `docs/HISTORY.md`。
