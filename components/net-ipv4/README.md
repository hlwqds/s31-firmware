# net-ipv4 — IPv4 / ICMP / ARP / 路由

首部与校验和、分片与有界重组、ARP 缓存状态机、路由 LPM、PMTU。

- 主机测试：**70 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `boards`；不依赖其它组件

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |

历史来源见 `docs/HISTORY.md`。
