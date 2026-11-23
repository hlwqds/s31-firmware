# ble-security — BLE 安全管理器、配对与链路层保护

LE 配对（legacy 与 LE Secure Connections，发起端和响应端）、密钥分发、绑定表、
链路层 AES-CCM/CRC-24/白化、ATT 签名数据的**纯逻辑实现**。不碰射频、不链接
controller 归档；HCI、L2CAP 传输与 GAP 归 `ble-802154`，本组件不 import 任何其它组件。

## 范围与来源

规范文本均为 Bluetooth Core Specification 5.4 官方 HTML（2026-11-24 读取）：

| 主题 | 出处（条款号取自本次读到的文本） |
| --- | --- |
| 密码学工具箱 e/ah/c1/s1/AES-CMAC/f4/f5/f6/g2/h6/h7 | [Vol 3] Part H 1.2.1、2.2.1–2.2.11，样例在 2.2.3、2.2.4 与附录 D.1–D.12 |
| dm、d1 | [Vol 3] Part H 附录 A.1.1、B.2.1（规范给出的示例方法） |
| 跨传输密钥派生 | [Vol 3] Part H 2.4.2.4、2.4.2.5，样例 D.9–D.12 |
| 配对 | [Vol 3] Part H 2.3（2.3.4 密钥长度、2.3.5.1 方法选择 Table 2.6–2.8、2.3.5.2–2.3.5.6 各方法、2.3.6 重复尝试）、2.4（2.4.3 分发、2.4.5 签名）、3.3–3.6（命令、3.4 超时、3.5.5 原因码、3.6.1 分发顺序）、附录 C 的消息序列 |
| P-256 | [Vol 3] Part H 2.3.5.6.1；[Vol 2] Part H 7.6（P256(u,V) 取 x 坐标、0<u<r） |
| ATT 签名写 | [Vol 3] Part F 3.3.1、3.4.5.4（含 m = D212001337 的样例） |
| 链路层加密 | [Vol 6] Part B 1.2、2.1.4、2.4、2.4.2.4–2.4.2.14、3.1.1、3.2、4.6.1、5.1.3.1、5.1.3.2；[Vol 6] Part E 1、2（CCM 的 M=4、L=2、B0/B1/A_i） |
| 样例数据 | [Vol 6] Part C 1（会话密钥与 4 个加密包）、4.1（40 个信道的白化序列）、4.2/4.3（完整包的 CRC 与白化） |
| 其它 | FIPS-197（2001 版附录 C.1；upd1 版附录 B）、RFC 4493 §4、RFC 3610 §2 与 §8、RFC 5869 §2.3（仅用于随机流展开）、CRC RevEng 目录的 CRC-24/BLE check 值 |

图 3.3（AuthReq 位序）、图 3.11（Key Distribution 位序）、图 2.2–2.6、图 3.4（CRC LFSR）、
图 3.5（白化 LFSR）的位序和连接是对照官方页面的插图核对的，不是凭记忆。

## 验证状态

- L3 板侧：2026-11-24 随 `wifi` profile 第一次上板，自检 25/25（含 P-256 点乘）。日志 `logs/wifi-selftest-prefix-boot.log`。
- L1 主机：2026-11-24，`zig test src/host_tests.zig`，**51/51 通过**；`zig fmt --check src/` 通过。
- 自检目标编译：2026-11-24，`src/selftest.zig` 以 `riscv32-freestanding-eabihf` 编译通过。
  用的是仓库外的一次性检查器：`cd /tmp/s31-stcheck && zig build --summary all
  -Dselftest=<本组件>/src/selftest.zig`，输出以
  `compile obj selftest_check small riscv32-freestanding-eabihf success` 结束。
  只编译了 `selftest.zig`（它引用全部逻辑模块），没有链接整固件。
- 自检主机运行：用桩 `board` 模块（只实现 `log.line`）在 x86_64 上跑 `selftest.run()`，
  输出 `checks: passed=25 failed=0 total=25`。这是逻辑检查，**不是板侧结果**。
- 与独立参考 `/tmp/s31-oracle/ble_oracle.py` 的差分：2026-11-24，
  `vectors --seed 20261124 --count 25`，用一次性测试断言与本实现逐字节相等（跑完已删）：

  | 函数 | 条数 | 结果 |
  | --- | --- | --- |
  | e、ah、c1、s1、f4、f5、f6、g2、h6、h7 | 各 25 | 全部一致 |
  | ll_encrypt（整包：头 ‖ 密文 ‖ MIC） | 25 | 全部一致 |
  | ll_decrypt（合法 PDU） | 25 | 全部一致 |
  | ll_decrypt（翻转密文/MIC 一位、缺一字节、多一字节、Length 改成 4） | 50 | 全部返回 `MicFailed` |
  | ll_crc | 25 | 全部一致 |
  | ll_crc_check（合法 / 翻转一位） | 25 / 25 | 全部通过 / 全部拒绝 |
  | ll_whiten、ll_dewhiten、ll_whitening_sequence | 各 25 | 全部一致 |

  ll_crc、ll_crc_check 的比法：oracle 把 CRC 的三个八位组按「bit 0 在前」打包，本实现按
  [Vol 6] Part C 的写法「position 23 在最高位」打包，所以比较前对每个八位组做位反转；
  寄存器值直接相等，空中比特顺序两边相同（见「实现偏离」第 3 条）。

- 空口：**未测**。本机两台射频都还不工作。

## 快速开始

```sh
cd components/ble-security
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG test src/host_tests.zig      # 主机单测
env -u LD_LIBRARY_PATH $ZIG fmt --check src/             # 格式
```

Zig 0.17.1 的 `zig test` 不接受 `--summary all`（报 `unrecognized parameter`），
该参数只在 `zig build test` 上有效。板侧：`selftest.run()`，每条判据一行
`check: <text> ok=1/0`，最后 `checks: passed=N failed=M total=N+M`。

## 文件职责

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `src/toolbox.zig` | 270 | e、ah、c1、s1、AES-CMAC、f4–h7、dm、d1、跨传输派生、密钥掩码。所有量都是大端字节数组 |
| `src/ecc.zig` | 101 | P-256 公私钥范围检查、公钥在曲线上检查、ECDH 的 x 坐标、调试密钥对 |
| `src/rand.zig` | 55 | 由调用方 256 位种子经 HKDF-Expand 展开的确定性随机流（本组件不采熵） |
| `src/pdu.zig` | 238 | 14 种 SMP 命令的编解码；线上多字节字段的小端换序只在这里发生 |
| `src/pairing.zig` | 1657 | 方法选择、发起端/响应端状态机、legacy 与 Secure Connections、密钥分发、绑定结果、超时、重复尝试 |
| `src/bond.zig` | 214 | 以 identity address 为键的有界绑定表、按 (EDIV, Rand) 查 LTK、RPA 生成与解析 |
| `src/linklayer.zig` | 722 | SKD/IV 拼接与会话密钥、CCM 的块与加解密、CRC-24、白化、Encryption Start/Pause 的链路层侧 |
| `src/sign.zig` | 166 | ATT_SIGNED_WRITE_CMD 的签名、验签、防重放 |
| `src/vectors.zig` | 781 | 全部常数，逐条注明出处 |
| `src/host_tests.zig` | 1533 | 主机单测，51 个用例 |
| `src/selftest.zig` | 290 | 板侧自检，25 条判据 |

调用方式：一个 `pairing.Pairer` 管一条链路上的一次配对。发起端 `start()`，两端收到
SMP 命令调 `onPdu()`，再反复 `nextOut()` 直到 null，并 `nextEvent()` 取上层要做的事
（显示/输入口令、数值比较、密钥就绪、完成、失败）。链路加密后调 `onLinkEncrypted()`
才开始阶段 3。`linklayer.Cipher` 管一条链路的加密状态、两个方向的 packetCounter 与
Encryption Start/Pause。

## 特性对照表

状态一栏「主机」= 该用例在 2026-11-24 的主机运行中通过。

| 特性 | 规范条款 | 测试名（`host_tests.zig`） | 向量来源 | 状态 |
| --- | --- | --- | --- | --- |
| e | [Vol 3] Part H 2.2.1 | e: FIPS-197 C.1 (AES-128) and FIPS-197-upd1 appendix B | FIPS-197 C.1、upd1 附录 B | 主机 |
| AES-CMAC | 2.2.5 / RFC 4493 §2 | cmac: RFC 4493 section 4 = Vol 3 Part H appendix D.1 | RFC 4493 §4（= 附录 D.1） | 主机 |
| ah | 2.2.2 | ah: Vol 3 Part H appendix D.7 | 附录 D.7 | 主机 |
| c1、s1 | 2.2.3、2.2.4 | c1: Vol 3 Part H 2.2.3 worked example / s1: … 2.2.4 worked example | 2.2.3、2.2.4 的算例 | 主机 |
| f4、f5、f6、g2、h6、h7 | 2.2.6–2.2.11 | f4: … D.2 / f5: … D.3 (T, MacKey, LTK) / f6: … D.4 / g2: … D.5 / h6, h7: … D.6, D.8 | 附录 D.2–D.6、D.8 | 主机 |
| 跨传输派生 | 2.4.2.4、2.4.2.5 | cross-transport key derivation: … D.9 to D.12 | 附录 D.9–D.12 | 主机 |
| dm、d1 | 附录 A.1.1、B.2.1 | d1, dm: padded inputs of appendix A.1.1 and B.2.1 examples | 算例给出的填充布局 | 主机 |
| 密钥长度掩码 | 2.3.4 | maskKey: Vol 3 Part H 2.3.4 example | 2.3.4 的例子 | 主机 |
| 工具箱差分（存档） | — | diff: e, cmac, ah (20 random vectors each) / diff: c1, s1, f4, f5, f6, g2, h6, h7, d1, dm | 自写 Python 参考，20 条/构造 | 主机 |
| 工具箱差分（独立 oracle） | 同上各条 | 一次性测试，已删除 | `ble_oracle.py`，各 25 条 | 2026-11-24 一致 |
| P-256 与 ECDH | 2.3.5.6.1；[Vol 2] Part H 7.6 | ecc: debug key pair, public key validation, ECDH vectors … | 调试密钥对 + 20 条差分 | 主机 |
| SMP 命令字节 | 3.3–3.6、1.2.1 | pdu: Pairing Request bytes … / pdu: malformed commands are rejected … | 由字段定义推出 | 主机 |
| AuthReq/KeyDist 位序 | 图 3.3、3.11 | authreq and keydist bit layout … | 插图 | 主机 |
| 方法选择 | 2.3.5.1 Table 2.6–2.8 | method selection: Vol 3 Part H tables 2.6, 2.7, 2.8 | 表逐格 | 主机 |
| legacy Just Works | 2.3.5.2、2.3.5.5、3.6.1 | pairing: legacy Just Works — golden STK on both sides … | Python 黄金值 | 主机 |
| legacy Passkey Entry | 2.3.5.3 | pairing: legacy Passkey Entry — both display/input roles, golden STK … | Python 黄金值 + 2.3.5.3 的 TK 例子 | 主机 |
| legacy OOB | 2.3.5.4 | pairing: legacy Out of Band — TK from OOB data, OOB Not Available … | Python 黄金值 | 主机 |
| SC Just Works | 2.3.5.6.1、2.3.5.6.2、2.3.5.6.5 | pairing: Secure Connections Just Works — golden LTK, Ea, Eb … | Python 黄金值（LTK、Ea、Eb） | 主机 |
| SC Numeric Comparison | 2.2.9、2.3.5.6.2 | pairing: Secure Connections Numeric Comparison — same value both sides … | Python 黄金值（LTK、显示值） | 主机 |
| SC Passkey Entry（逐位 20 轮） | 2.3.5.6.3 | pairing: Secure Connections Passkey Entry — 20 rounds, golden LTK/Ea/Eb … | Python 黄金值（LTK、Ea、Eb） | 主机 |
| SC OOB | 2.3.5.6.4、图 2.5 | pairing: Secure Connections Out of Band — both sides and one-sided … | Python 黄金值（LTK、Ea、Eb） | 主机 |
| 公钥检查 | 2.3.5.6.1、3.5.5 | pairing: SC rejects off-curve, debug and identical public keys … | — | 主机 |
| 失败路径与原因码 | 3.5.5、附录 C.5、C.2.2.2 | pairing: wrong passkey, tampered confirm/nonce/check … / pairing: Pairing Failed from the peer … | — | 主机 |
| 密钥分发与顺序 | 3.6.1 | pairing: key distribution order and Key Rejected (3.6.1) | — | 主机 |
| 密钥长度协商 | 2.3.4、附录 C.5.2、C.5.3 | pairing: key size negotiation and masking … | 2.3.4 的例子 | 主机 |
| 超时、重复尝试 | 3.4、2.3.6 | pairing: SMP timeout 30 s blocks the link until a new one (3.4) / repeated attempts: … | — | 主机 |
| 绑定表 | 2.4.3、附录 B.1、[Vol 6] Part B 1.3.2.3 | bond store: find, replace, evict, EDIV/Rand lookup, RPA resolution … | 附录 D.7 | 主机 |
| 会话密钥、LL_ENC_REQ/RSP | [Vol 6] Part B 5.1.3.1、2.4.2.4、2.4.2.5 | linklayer: SKD/IV concatenation and session key … / linklayer: LL_ENC_REQ / LL_ENC_RSP bytes and nonce … | [Vol 6] Part C 1 | 主机 |
| CCM 块与 MIC | [Vol 6] Part E 1、2 | linklayer: CCM blocks B0, B1, S0 and CBC-MAC match Part C 1.2 … / linklayer: protect/unprotect returns the original PDU … | Part C 1.2、20 条差分 | 主机 |
| CCM 核心对拍 | RFC 3610 §2、§8 | linklayer: CCM core matches RFC 3610 packet vectors 1 and 2 and std AesCcm / linklayer: CCM core with empty and multi-block AAD matches std AesCcm … | RFC 3610 #1/#2、std `Aes128Ccm8` | 主机 |
| CCM 链路层差分（独立 oracle） | [Vol 6] Part B 4.6.1；Part E 1、2 | 一次性测试，已删除 | `ble_oracle.py`：ll_encrypt 25、ll_decrypt 25 + 50 | 2026-11-24 一致 |
| Encryption Start/Pause | [Vol 6] Part B 5.1.3.1、5.1.3.2 | linklayer: Encryption Start reproduces Part C section 1 on air … / linklayer: MIC failure loses the link; rejects; Encryption Pause … | Part C 1 | 主机 |
| CRC-24 | [Vol 6] Part B 3.1.1 | linklayer: CRC-24 on Part C packets and catalogue check … | Part C 4.2.1/4.3.1/4.3.2、CRC RevEng check、20 条差分；oracle ll_crc 25、ll_crc_check 50 | 主机；2026-11-24 一致 |
| 白化 | [Vol 6] Part B 3.2 | linklayer: whitening sequence for 40 channels and complete packets … | Part C 4.1（40×64 位）、4.2/4.3 完整包；oracle 75 条 | 主机；2026-11-24 一致 |
| ATT 签名写 | [Vol 3] Part H 2.4.5、Part F 3.4.5.4 | sign: ATT_SIGNED_WRITE_CMD sample and verification … / sign: 20 differential vectors and the counter starts at zero | Part F 3.4.5.4 样例、20 条差分 | 主机；未与 oracle 比对 |

## 实现偏离

1. **签名数据的 CMAC 输入字节序，规范自相矛盾，本实现按 [Vol 3] Part F 3.4.5.4 的样例数值。**
   Part H 2.4.5 的文字把 M = m || SignCounter 写成自然顺序（D21200133701000000），
   但 Part F 的样例给出的 padding(M) = 0x0000000137130012D2 80 00… 是把 M **逐字节反转**，
   且样例的 CMAC F20F903C… 只有按反转输入才算得出（自然顺序算出 53907596…）。
   `sign.zig` 因此按反转输入实现并逐字节复现样例签名 01000000F1871E933C900FF2。
   与按 2.4.5 字面顺序实现的协议栈能否互通**未验证**。
2. [Vol 6] Part C 4.2.2（AUX_ADV_IND）印出的 CRC 1BC475 用 CRCInit 0x555555 对印出的 PDU
   算不出来（得 65D123），首字节改成 0x27 才一致；该样例只用来测白化，CRC 的已知答案是
   另外三条完整包。FIPS-197 的 C.2/C.3 是 AES-192/256，本组件不用。
3. **CRC 三个八位组的打包方式。** `crc24()` 返回寄存器值（bit i = position i）。`crcBytes()`
   按 [Vol 6] Part C 样例的写法给出三个八位组：position 23 在第一个八位组的最高位，
   [Vol 6] Part B 3.1.1「from position 23 to position 0」。`Whitener.crc()` 按这个打包
   最高位先白化，所以与 PDU（最低位先）不是同一种打包。空中比特顺序与「bit 0 在前」的
   写法完全相同；**如果驱动或射频把 CRC 也按最低位先收发成八位组，它看到的每个 CRC
   八位组是 `crcBytes()` 结果的位反转**，接入时要转换。
4. **Encryption Start / Pause 里哪条控制 PDU 加密**（[Vol 6] Part B 5.1.3）：Peripheral 的
   LL_START_ENC_REQ 明文发；Central 的 LL_START_ENC_RSP 加密发；Peripheral 回的
   LL_START_ENC_RSP 加密发。Encryption Pause 时双方的 LL_PAUSE_ENC_RSP 都加密发，
   Central 收到后回的那条 LL_PAUSE_ENC_RSP 明文发。MIC 校验失败、或过程中收到与本步骤
   不符的控制 PDU，连接按 0x3D（MIC Failure）丢失。CCM 核心的 AAD 为空时 B0 的 Adata
   位清零（RFC 3610 §2.2）；BLE 的 AAD 永远是 1 字节，这条只为核心函数正确。
5. 两端公钥 X 坐标相同（都不是调试密钥）时发 Invalid Parameters；调试公钥不接受时也用
   Invalid Parameters。规范对前者只说 should fail、对后者说 may 用这个原因码。
6. 乱序或与当前步骤不符的 SMP 命令、分发顺序不对的密钥 → Unspecified Reason（规范未规定）。
   空闲设备只对残缺的 Pairing Request 回 Invalid Parameters。
7. Repeated Attempts（2.3.6）只规定了形式。本实现：首次等 1 s，逐次翻倍，上限 64 s，
   每 30 s 无新失败等待减半，成功后清零。
8. 随机数：调用方提供每次配对新鲜的 256 位种子，本组件用 HKDF-Expand 展开成 nonce、私钥
   （拒绝采样到 1..n−1）和口令（拒绝采样到 0..999999）。2.3.5.6.2 允许「以物理随机值为
   种子的良好伪随机发生器」。种子复用等于复用私钥，这是调用方的责任。
9. AuthReq 的保留位与 Bonding_Flags 10/11：保留位忽略，非 01 一律按 No Bonding。
   Key Distribution 的保留位置 1 → Invalid Parameters；LinkKey 位本组件不支持（不置位，收到忽略）。
10. packetCounter 超出 39 位、输出缓冲不够等返回错误；规范没有规定溢出行为。
    MIC 校验失败时明文缓冲被清零（RFC 3610 §2.5 要求校验前不放出明文）。
    `linklayer.Cipher` 的动作函数先查角色（`WrongRole`）再查状态（`WrongState`）。
11. P-256 运算取自 `std.crypto.ecc.P256`，不是自研；白化 LFSR 按图 3.5 逐级模拟。
    `link_key` 在 legacy 配对里是 STK、在 Secure Connections 里是 LTK，同一个字段。

## 待验证项

- 板侧 `selftest.run()` 已于 2026-11-24 随 `wifi` profile 的整固件上板一次（25/25）；P-256 点乘在 rv32 上的耗时和栈占用仍未测。
- 空口互通：与手机或其它协议栈配对、加密、重连、签名写均未测。
- 签名数据与按 2.4.5 字面顺序实现的协议栈能否互通（「实现偏离」第 1 条）。
- 真实射频对 CRC 八位组的打包方式（第 3 条）：接入 `ble-802154` 或 controller 归档时要对一次线上字节。
- ATT 签名没有与 `ble_oracle.py` 比对（oracle 不含签名函数）；配对状态机的端到端流程只有
  自写 Python 黄金值，没有独立参考。
- legacy 配对的黄金值、SC 各方法的黄金值都由本会话自写的 Python 参考生成（该参考先对
  官方样例自检）；`ble_oracle.py` 只差分了密码构造与链路层函数，没有差分整段配对。
