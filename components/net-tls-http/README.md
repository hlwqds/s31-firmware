# net-tls-http — TLS 记录层与 HTTP/1.1

记录层、HKDF/X25519/AES-GCM、证书 DER、HTTP 解析与 chunked。

- 主机测试：**53 项**（`firmware` 的 `test` step 聚合；也可单独 `zig build test` 于 `firmware/`）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `boards`；不依赖其它组件

## 文件

| 文件 | 作用 |
| --- | --- |
| `src/*.zig` | 子系统实现（纯逻辑为主，寄存器访问经板级层） |
| `src/selftest.zig` | 板侧自检入口（`run() bool`） |
| `src/random.zig` | 熵源接缝：`Reader` + 测试用确定性流（**非**密码学安全，日志须标注） |
| `src/tls_handshake.zig` | ClientHello 编码：三层长度、SNI、supported_versions、key_share |
| `src/tls_protect.zig` | 记录保护：nonce=iv⊕seq、AD=外层头、内层类型藏在明文末尾 |
| `src/host_tests.zig` | 主机测试入口（聚合模块内 `test`） |

历史来源见 `docs/HISTORY.md`。
