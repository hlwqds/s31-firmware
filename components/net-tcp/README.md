# net-tcp — TCP 状态机与可靠传输

11 态机、seq/ack 回绕、多段在途（有界 32 槽发送队列）、RFC 6298 RTO、乱序重组、TIME_WAIT。

- 主机测试：**33 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `boards`；不依赖其它组件

## `Conn` 的发送模型

`sendData(len, inflight_cap, now_us)` 一次返回**一段**（≤ MSS，且不超过
`inflight_cap - 已在途`），调用方循环调用直到 `send == false`：

- `inflight_cap` 由调用方给（通常是 `min(cwnd, rwnd)`）；本组件不做窗口管理，
  对端窗口 `snd_wnd` 只记录；
- 队列固定 `SEND_SLOTS = 32` 槽（256 B `.bss`），只记 `(seq, len)`、不复制载荷，满了就“不发”，
  没有动态分配；
- 累积 ACK 整段出队，部分 ACK 只裁队首前缀；
- RTO 只重传**队首**（最老未确认段），计时器只在没有计时器在跑时启动
  （RFC 6298 §5.1），收到确认新数据的 ACK 时重启（§5.3）；
- `retransmit_happened`（Karn）在整批数据确认完（flight 清空）时复位，
  不在每次 `sendData` 时清。

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |

历史来源见 `docs/HISTORY.md`。
