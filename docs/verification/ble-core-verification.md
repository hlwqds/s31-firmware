# BLE 验证报告（Bluetooth Core Specification 5.4 与 RFC 7668）

- 规范依据：Bluetooth Core Specification 5.4（按卷、部分、节引用，官方 HTML）；其上的 RFC 7668（IPv6 over BLE）；算法核心另对 RFC 4493（AES-CMAC）与 RFC 3610（AES-CCM）。
- 组件：`components/ble-802154`（扩展）、`components/ble-security`（新）。
- 验证分级见 `docs/REPO-STANDARDS.md` §4。本报告只写实际跑过的命令和输出里出现过的结果。
- **空口没有任何证据**：射频 synth PLL 不锁，广播发不出去。下表的"通过"指离线验证通过。

## 1. 结论

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| `ble-802154` 主机测试 | L1 | 68/68 | §3.1 |
| `ble-security` 主机测试 | L1 | 51/51 | §3.2 |
| 与独立参照实现的差分 | L1 | 全部一致 | §4 |
| HCI 命令布局对 NimBLE 头文件 | L1 | 三条逐字段一致 | §5 |
| RV32 目标编译 | L2 | 两个自检都能以固件参数编译 | §5 |
| 板侧自检（第一次上板） | L3 | `ble_security` 25/25；`ble_802154` 18/19，失败的那条是自检自身的差一错误，已修 | `logs/wifi-selftest-prefix-boot.log` |
| 修复后的板级复验 | L3 | 未做 | — |
| 与真实 controller 的 HCI 一致性 | L3 | 未做 | — |

## 2. 逐特性对照

"主机"是 `zig test src/host_tests.zig` 的用例数，"板侧"是 `selftest.zig` 的判据数。

| 特性 | 条款 | 实现位置 | 主机 | 向量来源 | 板侧 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| HCI 控制命令编码（Reset、Read_Local_Version、Read_BD_ADDR、LE 的 Set_Advertising_Parameters / Data / Enable、Create_Connection、Connection_Update、Read_Local_Supported_States、Start_Encryption 等） | Vol 4 Part E §7.8 | `ble-802154/src/hci_cmd.zig` | 含在 68 内 | 按参数布局逐字节搭的向量；NimBLE 头文件交叉核对（§5） | 含在 19 内 | 离线验证通过 |
| 事件分发（Command Complete、Command Status、LE Meta、Disconnection Complete、Number_Of_Completed_Packets） | Vol 4 Part E §5.4、§7.7 | `hci_evt.zig` | 同上 | 同上 | 同上 | 离线验证通过 |
| ACL 分段与重组 | Vol 4 Part E §5.4 | `acl.zig` | 同上 | 61 字节 SDU 分 3 片 | 同上 | 离线验证通过 |
| L2CAP（B 帧、LE 信令、基于信用的流控） | Vol 3 Part A §3、§4、§10 | `l2cap.zig` | 同上 | 双端对打 | 同上 | 离线验证通过 |
| 广播与扫描响应数据、地址类型、可解析私有地址 | Vol 3 Part C §11、§10.8；Vol 3 Part H §2.2.2 | `gap_adv.zig` | 同上 | 往返、31 字节上限、RPA 生成与解析；`ah` 对参照实现 20/20 | 同上 | 离线验证通过 |
| IPv6 over BLE | RFC 7668 §3.2.4、§3.2.5 | `ipsp.zig` | 同上 | RFC 7668 §3.2.4.1 的示例 | 同上 | 离线验证通过 |
| SMP 密码学工具箱（e、ah、c1、s1、f4、f5、f6、g2、h6、h7） | Vol 3 Part H §2.2 | `ble-security/src/toolbox.zig` | 含在 51 内 | FIPS-197 C.1；RFC 4493 §4；Vol 3 Part H Appendix D.1–D.8；c1、s1、g2 的正文算例 | 含在 25 内 | 离线验证通过 |
| 方法选择 | Vol 3 Part H §2.3.5.1，Table 2.6–2.8 | `pairing.zig` | 同上 | 表逐格 | 同上 | 离线验证通过 |
| 配对：legacy 与 LE Secure Connections，Just Works、Passkey、Numeric Comparison、OOB，双角色 | Vol 3 Part H §2.3.5、§3 | `pairing.zig` | 同上 | 自写 Python 参考的黄金值；双端进程内配对 | 同上 | 离线验证通过 |
| 密钥分发与绑定存储 | Vol 3 Part H §2.4.3、§3.6，Appendix B.1 | `pairing.zig`、`bond.zig` | 同上 | Appendix D.7 | 同上 | 离线验证通过 |
| 链路层加密（AES-CCM） | Vol 6 Part B §4.6.1、§5.1.3；Vol 6 Part E §1、§2 | `linklayer.zig` | 同上 | Vol 6 Part C §1、§2.1；RFC 3610 #1、#2 | 同上 | 离线验证通过 |
| CRC-24 | Vol 6 Part B §3.1.1 | `linklayer.zig` | 同上 | Vol 6 Part C §2.1、§4.2.1、§4.3 | 同上 | 离线验证通过 |
| 数据白化 | Vol 6 Part B §3.2 | `linklayer.zig` | 同上 | Vol 6 Part C §4.1（信道 0 到 39）、§4.2、§4.3 | 同上 | 离线验证通过 |
| ATT 签名写 | Vol 3 Part H §2.4.5；Vol 3 Part F §3.4.5.4 | `sign.zig` | 同上 | Part F 的样例 | 同上 | 离线验证通过；互通未验（§6） |
| ATT 与 GATT 扩展（指示、发现、prepared write） | Vol 3 Part F、Part G | — | — | — | — | 未做（现有：8 个 ATT 操作码、服务端定长表） |
| 对真实 controller 的 HCI 一致性自检 | Vol 4 Part E | — | — | — | — | 未做；已证明能回复的命令：0x0C03、0x1001、0x1009、0x2006、0x2008、0x1405 |
| 广播、连接、真实收发 | 不适用 | — | — | — | — | 阻塞：射频 synth PLL 不锁 |

## 3. 主机测试

### 3.1 `ble-802154`

```sh
cd components/ble-802154 && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 68 tests passed.
```

原有 20 项全部保留，新增 48 项。`zig fmt --check src/` 干净。

### 3.2 `ble-security`

```sh
cd components/ble-security && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 51 tests passed.
```

第一次交付时这个组件的最后一轮修改之后没有任何测试结果，被退回重做。重做时对照 Vol 6 Part C 的样例发现并修掉一个真实缺陷：白化 LFSR 的初值把常量 1 放在了输出位，信道 0 的首个八位组算不出 §4.1 给的 0x40。现按 Vol 6 Part B §3.2 与图 3.5：position 0 为 1，position 1 到 6 为信道 bit 5 到 0。

## 4. 与独立参照实现的差分

参照实现：`/tmp/s31-oracle/ble_oracle.py`（Python，AES 取自 OpenSSL，不引用仓库代码；自检 175 PASS、2 KNOWN，22 个函数）。一次性测试取随机向量与 Zig 实现比较，跑完删除。

| 构造 | 条数 | 结果 |
| --- | --- | --- |
| e、ah、c1、s1 | 各 25 | 全部一致 |
| f4、f5、f6、g2、h6、h7 | 各 25 | 全部一致 |
| `ll_encrypt`（整包） | 25 | 全部一致 |
| `ll_decrypt`：合法 PDU | 25 | 全部一致 |
| `ll_decrypt`：翻转一位、缺字节、多字节、改 Length | 50 | 全部返回 `MicFailed` |
| `ll_crc`、`ll_crc_check` | 25 + 25 + 25 | 全部一致 |
| `ll_whiten`、`ll_dewhiten`、`ll_whitening_sequence` | 各 25 | 全部一致 |

`ll_crc_check` 比较前要对 CRC 八位组做位反转：参照实现按"bit 0 在前"打包，本实现按 Vol 6 Part C 样例的写法；寄存器值相等。

没有差分的：AES-CMAC、签名、整段配对流程（参照实现没有这些函数；配对黄金值来自组件自写的 Python 参考）。

参照实现自检里的 2 条 KNOWN 是规范样例自身的不一致：Vol 6 Part C §4.2.1 印出的 PDU 少一个 AdvA 八位组；§4.2.2 印出的 CRC 与印出的 PDU 对不上。

## 5. 主代理独立复核

- HCI 参数布局对 NimBLE 的 C 结构体（`~/esp/esp-idf/components/bt/host/nimble/nimble/nimble/include/nimble/hci_common.h`，另一份独立实现）：LE Set Advertising Parameters 15 字节、LE Create Connection 25 字节 12 个字段、LE Connection Update Complete 事件 10 字节，逐字段顺序一致。
- 仓库门禁（格式、`check-host.sh`、`check-coverage.py`、`check-invariants.py`）全绿。
- 两个自检以固件参数（`riscv32-freestanding-eabihf`、`generic_rv32+m+a+c+f+zicsr+zifencei`、`ReleaseSmall`）编译通过；用桩 `board` 模块在主机上执行 `selftest.run()`，19/19 与 25/25（`ble-802154` 的 19 是修复之后的数）。
- 板侧第一次上板时 `ble-802154` 为 18/19：`check: gap adv kat=1 nospace=1 name=1 hci=0 malformed=1 ok=0`。原因是自检把 32 字节的 HCI 参数与向量的 31 字节切片比较，恒为假；与目标无关，已改为整段比较。这次失败也说明该 agent 只对自检做了交叉编译、从未执行过它。

## 6. 实现偏离

- ATT MTU 上限取 527，规范是 517；小于 23 的 MTU 请求直接拒绝。两条都是原有行为。
- LE Advertising Report 只做 legacy 事件；扩展广播数据在 §7.7.65.13，未实现。
- AD 结构里 Length = 0 按规范当作填充的起点。
- **签名的字节序**：Vol 3 Part H §2.4.5 的文字与 Vol 3 Part F §3.4.5.4 的样例互相矛盾，本实现按样例；与按字面顺序实现的协议栈能否互通未知。
- 规范没规定或自相矛盾、由实现选定的：两端公钥 X 坐标相同时回 Invalid Parameters；乱序命令回 Unspecified Reason；Repeated Attempts 取 1 秒起、上限 64 秒、30 秒回落；随机数用 HKDF-Expand 展开调用方的 256 位种子；AuthReq 保留位忽略；Bonding_Flags 非 01 按 No Bonding；MIC 校验失败时明文缓冲清零。
- Peripheral 的 `LL_START_ENC_REQ` 明文发，Central 与 Peripheral 的 `LL_START_ENC_RSP` 加密发；意外控制 PDU 按 0x3D 丢失。

## 7. 未验证

- 修复后的板级复验（`ble-802154` 19 条）。
- 空口互通：配对、加密、重连、签名写；CRC 八位组的线上打包要先对一次真实字节。
- P-256 点乘在 rv32 上的耗时和栈占用。
- Number Of Completed Packets 的实际布局、PB = 0b11 是否出现、失败命令是否只回 Status。
