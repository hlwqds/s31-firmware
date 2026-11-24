# BLE 验证报告（Bluetooth Core Specification 5.4 与 RFC 7668）

- 规范依据：Bluetooth Core Specification 5.4（按卷、部分、节引用，官方 HTML）；其上的 RFC 7668（IPv6 over BLE）；算法核心另对 RFC 4493（AES-CMAC）与 RFC 3610（AES-CCM）。
- 组件：`components/ble-802154`（扩展）、`components/ble-security`（新）、`components/bt-blobs`（§8 的 HCI 一致性自检）。
- 验证分级见 `docs/REPO-STANDARDS.md` §4。本报告只写实际跑过的命令和输出里出现过的结果。
- **空口没有任何证据**：射频 synth PLL 不锁，广播发不出去。下表的"通过"指离线验证通过。

## 1. 结论

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| `ble-802154` 主机测试 | L1 | 122/122（第一批 68 + 第二批 54） | §3.1 |
| `ble-security` 主机测试 | L1 | 51/51 | §3.2 |
| 与独立参照实现的差分 | L1 | 全部一致 | §4 |
| HCI 命令布局对 NimBLE 头文件 | L1 | 三条逐字段一致 | §5 |
| RV32 目标编译 | L2 | 两个自检都能以固件参数编译 | §5 |
| 板侧自检（第一批，第一次上板） | L3 | `ble_security` 25/25；`ble_802154` 18/19，失败的那条是自检自身的差一错误，已修 | `logs/wifi-selftest-prefix-boot.log` |
| 修复后的板级复验（第一批） | L3 | `ble_802154` 19/19；整份判决 `main: verdict=pass` | 当时的 `logs/e2e-wifi-boot.log`，已被下一行的运行覆盖 |
| 第二批后的板级复验 | L3 | `ble_802154` 50/50；`wifi` profile 14/14 个 section；`main: verdict=pass` | `logs/e2e-wifi-boot.log`；§3.1 |
| 与真实 controller 的 HCI 一致性 | L3 | 板侧 26 条只读命令：20 过 6 不过（16 受支持、4 声明不支持）；bt-blobs 主机用例 21 → 67 | §8 |

## 2. 逐特性对照

"主机"是 `zig test src/host_tests.zig` 的用例数，"板侧"是 `selftest.zig` 的判据数。

| 特性 | 条款 | 实现位置 | 主机 | 向量来源 | 板侧 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| HCI 控制命令编码（Reset、Read_Local_Version、Read_BD_ADDR、LE 的 Set_Advertising_Parameters / Data / Enable、Create_Connection、Connection_Update、Read_Local_Supported_States、Start_Encryption 等） | Vol 4 Part E §7.8 | `ble-802154/src/hci_cmd.zig` | 含在 122 内 | 按参数布局逐字节搭的向量；NimBLE 头文件交叉核对（§5） | 含在 50 内 | 离线验证通过 |
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
| ATT 编解码全表（31 个操作码、PDU 类型、最小长度、定长 PDU 的长度校验、19 个错误码、UUID） | Vol 3 Part F 表 3.43、表 3.1、表 3.4、§3.3 | `ble-802154/src/att.zig` | `att:` 前缀 19 条（本批 +15）。`att: opcode table is Vol 3 Part F table 3.43…`、`att: minimum PDU lengths follow the size columns…`、`att: every PDU parses and fixed-length ones reject wrong lengths…`、`att: error codes are the 19 values of Vol 3 Part F table 3.4`、`att: UUIDs compare as 128 bits…` | 按表 3.43、表 3.1、表 3.4 排出的字节；PDU 尺寸对 NimBLE `ble_att_cmd_priv.h`（§5.1） | ③ ④（Read 与 MTU 交换的字节级 KAT） | 离线验证通过；板侧 50/50 |
| ATT Find Information | Vol 3 Part F §3.4.3.1–3.4.3.2、§3.4.3 | `att.zig`、`att_server.zig` | `att: find information request and response…`、`att_svr: find information lists every attribute and pages by ATT_MTU…` | 按条款排出的字节；行为断言 | ㉕ | 同上 |
| ATT Find By Type Value | Vol 3 Part F §3.4.3.3–3.4.3.4 | `att.zig`、`att_server.zig` | `att: find by type value request and response…`、`att_svr: find by type value returns handle ranges and skips unreadable attributes…` | 同上 | 无 | 同上 |
| ATT Read By Type | Vol 3 Part F §3.4.4.1–3.4.4.2 | `att.zig`、`att_server.zig` | `att: read by type request and response…`、`att_svr: read by type packs equal lengths and stops at an unreadable attribute…` | 同上 | ㉖ | 同上 |
| ATT Read Blob | Vol 3 Part F §3.4.4.5–3.4.4.6 | `att.zig`、`att_server.zig` | `att: read blob request and response cut the value at ATT_MTU-1…`、`att_svr: read and read blob follow ATT_MTU and reject offsets past the value…` | 同上 | ㉘ | 同上 |
| ATT Read Multiple（定长）与 Read Multiple Variable（变长，含两条截断规则） | Vol 3 Part F §3.4.4.7–3.4.4.8、§3.4.4.11–3.4.4.12 | `att.zig`、`att_server.zig` | `att: read multiple and read multiple variable length…`、`att_svr: read multiple and read multiple variable length…` | 同上；§3.4.4.12 原文的独立复核见 §5.1 | ㉙ ㉚ ㉛ | 同上 |
| ATT Read By Group Type | Vol 3 Part F §3.4.4.9–3.4.4.10 | `att.zig`、`att_server.zig` | `att: read by group type request and response…`、`att_svr: read by group type returns groups and rejects non-group types…` | 按条款排出的字节；行为断言 | ㉗ | 同上 |
| ATT 排队写（编解码与服务端两条路径：执行、取消） | Vol 3 Part F §3.4.6.1–3.4.6.4 | `att.zig`、`att_server.zig` | `att: prepare write and execute write…`、`att_svr: prepare and execute write, both paths…` | 行为断言 | ㉜ ㉝ | 同上 |
| ATT 指示与确认、多重变长通知 | Vol 3 Part F §3.4.7.1–3.4.7.4 | `att.zig` | `att: indication, confirmation and multiple variable length notification…` | 按条款排出的字节 | 只有指示（㊵）；多重变长通知无 | 同上 |
| ATT 服务端：MTU 交换、权限与错误码（表 3.4、§4 的检查顺序、§3.3 的未知与非法请求）、定长与变长写、签名写、指示 30 秒超时 | Vol 3 Part F §3.4.2.2、§3.2.5、§4、表 3.4、§3.3、§3.4.5.1–3.4.5.3、§3.4.7.2、§3.3.3 | `att_server.zig` | `att_svr:` 前缀 13 条（全部是本批）。`att_svr: MTU exchange takes the minimum and keeps the default below it…`、`att_svr: permission checks yield the codes of table 3.4 in the order of Vol 3 Part F section 4`、`att_svr: unsupported and malformed requests get the codes of Vol 3 Part F section 3.3`、`att_svr: indication waits for its confirmation and times out after 30 s…` | 行为断言；超时用例把时间直接拨到 30 秒后 | ㉔ ㉓ ㉞ ㊵ | 同上 |
| GATT 服务端声明（服务、包含、特征、描述符） | Vol 3 Part G 表 3.1–3.15 | `gatt_server.zig` | `gatts:` 前缀 5 条（全部是本批）。`gatts: service, characteristic and descriptor declarations match Vol 3 Part G 3.1-3.3 byte for byte` | 表里的字节 | ㉟ ㊱ ㊲ | 同上 |
| CCCD（按 client 保存、门控通知、写入校验） | Vol 3 Part G §3.3.3.3、§4.12.3 | `gatt_server.zig` | `gatts: the Client Characteristic Configuration is kept per client and gates notifications…`、`gatts: invalid CCCD writes are rejected and leave the configuration unchanged…` | 行为断言 | ㊳ ㊴ | 同上 |
| GATT 指示 | Vol 3 Part G §4.11.1 | `gatt_server.zig` | `gatts: indications need the indicate bit, go one at a time, and are confirmed…` | 行为断言 | ㊵ | 同上 |
| Service Changed | Vol 3 Part G §7.1 | `gatt_server.zig` | `gatts: the Service Changed characteristic and its enablement…` | 表 7.2、表 7.3 | ㊶ | 同上 |
| GATT 客户端各过程：Exchange MTU、发现（§4.4–§4.7）、读（§4.8）、写（§4.9）、通知与指示（§4.10–§4.11）、描述符读写（§4.12）、过程失败与 30 秒超时 | Vol 3 Part G §4.3–§4.12、§4.14；附录 A | `gatt_client.zig` | `gattc:` 前缀 18 条（全部是本批）。`gattc: discover all primary services of the appendix A server, byte for byte…`、`gattc: exchange MTU takes the minimum and the result paves every later procedure…`、`gattc: write long values in ATT_MTU-5 pieces then execute…`、`gattc: reliable writes verify every round trip and cancel on a mismatch…`、`gattc: a request that is not answered within 30 s fails and closes the bearer…` | 附录 A 的服务器：对打时记下每一个 PDU，与脚本逐字节比对；其余过程用另搭的属性表 | ㊷–㊿ 共 9 条；按 UUID 发现、包含服务、描述符发现等没有板侧判据 | 同上 |
| AES-CMAC | RFC 4493 §4；Vol 3 Part H 附录 D.1；Vol 3 Part G 附录 B | `cmac.zig` | `cmac:` 前缀的 2 条。`cmac: AES-CMAC matches the RFC 4493 vectors quoted in Vol 3 Part H appendix D.1`、`cmac: AES-CMAC with an all-zero key over the database hash input of Vol 3 Part G appendix B` | RFC 4493 的四个向量（消息长度 0 / 16 / 40 / 64）；附录 B 的 111 字节输入 | ⑳ ㉑ | 同上；没有差分（§4） |
| ATT 签名与签名写（`ble-802154` 的实现） | Vol 3 Part H §2.4.5；Vol 3 Part F §3.4.5.4 | `cmac.zig`、`att.zig`、`att_server.zig` | `cmac: signing reproduces the example of Vol 3 Part F 3.4.5.4…`、`att: signed write command carries the example signature of Vol 3 Part F 3.4.5.4`、`att: write command and signed write command…`、`att_svr: signed write is applied only with a valid, fresh signature…` | Part F §3.4.5.4 的样例 | ㉒ ㉓ | 离线验证通过；板侧 50/50；互通未验（§6、§7） |
| 对真实 controller 的 HCI 一致性自检 | Vol 4 Part E §3.1、§4.4、§4.5、§6.27、§7.4、§7.6、§7.8 | `bt-blobs/src/hci_conformance.zig`、`hci_conformance_tests.zig`、`probe.zig` | bt-blobs 21 → 67（本项 46） | 规范原文表 3.1、§6.27；板上回包 | 26 条：20 过 6 不过 | 已上板：16 条合规且受支持、4 条合规且声明不支持、6 条偏差（§8） |
| 扩展广播与周期广播的 host 侧：17 条 HCI 命令的编码（其中两条分 v1 / v2）、两个事件（LE Extended Advertising Report、LE Advertising Set Terminated）、广播集台账、链路层扩展头解析、广播数据分片器 | [Vol 4] Part E §5.2、§7.7.65.13、§7.7.65.18、§7.8.52–§7.8.69；[Vol 6] Part B §1.2、§2.3、§2.3.4、§2.5.2 | `ble-802154/src/ext_adv.zig` | 115（`ext_adv_tests.zig`） | 按参数表逐字节排的已知答案；NimBLE 的命令结构体、报告遍历代码与 controller 的扩展头位序（行号见 `ext_adv.zig` 文件头） | 27（`ext_adv_selftest.zig`） | 离线验证通过 |
| Enhanced ATT bearer 池；LE 上基于额度的 L2CAP 连接（LE Credit Based Flow Control 与 Enhanced Credit Based Flow Control）；Robust Caching（Client Supported Features、Database Hash、change-aware / change-unaware 的跟踪、客户端缓存的判定） | [Vol 3] Part G §2.5.2、§2.5.2.1、§5.3、§7.2–§7.4、附录 B；[Vol 3] Part F §3.2.8、§3.2.11、§3.3.2、§3.3.3、表 3.44；[Vol 3] Part A §2.1、§3.4、§4、§4.22–§4.28、§7.11、§10.1–§10.2 | `ble-802154/src/eatt.zig`、`l2cap_coc.zig`、`robust_cache.zig` | 57（`eatt_tests.zig`） | 附录 B 的 Database Hash 样例；`eatt_oracle.py`；NimBLE 的信令结构体、EATT 与 GATT 的对应代码（行号见三个文件头） | 10（`eatt_selftest.zig`） | 离线验证通过 |
| LL Privacy 的 host 侧：解析列表（9 条命令）、RPA 的生成与解析、扫描时的解析预算、RPA 超时定时器、隐私模式下的地址过滤；LE Power Control 的 host 侧：命令与事件编解码、路径损耗上报的跟踪、功率钳制与档位选择的模型 | [Vol 4] Part E §7.8.38–§7.8.45、§7.8.74–§7.8.77、§7.8.117–§7.8.121、§7.7.65.32–.33；[Vol 6] Part B §1.3.2.2–.3、§4.5.16、§4.7、§5.1.17、§6.1–§6.5；[Vol 3] Part H §2.2.2；[Vol 3] Part C §10.7 | `ble-802154/src/privacy.zig`、`power_ctrl.zig` | 66（`privacy_tests.zig`：privacy 40、power 25、子自检 1） | 参数表逐字节；`privacy_oracle.py`（FIPS-197 附录 B 与 RFC 4493 的已知答案先自检）；NimBLE 的 `ble_hs_resolv.c`、`ble_gap.c`、`ble_hs_pvcy.c` | 9（`privacy_selftest.zig`） | 离线验证通过 |
| 6LoWPAN 适配层补全：IPHC 压缩与无状态 / 有状态解压（两个方向、全部取值）、上下文表的有效期状态机、NHC（扩展头 EID 0–4 与 7、UDP 的 C 与 P 全部取值、校验和省略）、dispatch 分类、Mesh 头与转发规则、分片头与重组（重叠、乱序、60 秒超时） | RFC 4944 §5.1–§5.3、§11；RFC 6282 §3、§4；RFC 6775 §4.2、§5.4.2–§5.4.3；RFC 8025 §3 | `ble-802154/src/fifteen4.zig` | 50（`sixlowpan_tests.zig`） | RFC 手排的已知答案；lwIP（IDF v6.1 自带）的输出 | 10（`sixlowpan_selftest.zig`） | 离线验证通过 |
| 广播、连接、真实收发 | 不适用 | — | — | — | — | 阻塞：射频 synth PLL 不锁 |

## 3. 主机测试

### 3.1 `ble-802154`

```sh
cd components/ble-802154 && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 122 tests passed.
```

第一批：原有 20 项全部保留，新增 48 项，共 68 项。第二批（ATT / GATT 扩展，2026-11-24）：第一批的 68 项全部保留，新增 54 项，共 122 项。`zig fmt --check src/` 干净（2026-11-24 复跑）。

按用例名前缀的分布。“本批新增”是把 `git show HEAD:components/ble-802154/src/host_tests.zig` 与现文件的 `test "…"` 名字逐条比较数出来的，没有被删掉或改名的用例：

| 前缀 | 第一批（HEAD） | 现在 | 本批新增 |
| --- | --- | --- | --- |
| `att` | 4 | 19 | +15 |
| `gattc` | 0 | 18 | +18 |
| `att_svr` | 0 | 13 | +13 |
| `gatts` | 0 | 5 | +5 |
| `cmac` | 0 | 3 | +3 |
| `gatt` | 5 | 5 | 0 |
| `hci_cmd` | 11 | 11 | 0 |
| `gap_adv` | 9 | 9 | 0 |
| `hci_evt` | 8 | 8 | 0 |
| `ipsp` | 7 | 7 | 0 |
| `hci` | 7 | 7 | 0 |
| `l2cap` | 6 | 6 | 0 |
| `acl` | 5 | 5 | 0 |
| `lowpan` | 4 | 4 | 0 |
| `ieee802154` | 2 | 2 | 0 |
| 合计 | 68 | 122 | +54 |

这 54 条在交付时一次都没有被执行过，第一次执行的结果与用例更正见 §5.1。

板侧自检 `components/ble-802154/src/selftest.zig`（50 条判据，①–⑲ 是第一批，⑳–㊿ 是本批）：

```sh
cd /home/huanglin/code/s31-firmware && R=/tmp/selftest-host && env -u LD_LIBRARY_PATH zig run --dep selftest -Mroot=$R/main.zig --dep board -Mselftest=components/ble-802154/src/selftest.zig -Mboard=$R/board_stub.zig
# 50 行 check: … ok=1；checks: passed=50 failed=0 total=50；selftest returned true
```

- 上面这条在主机上用桩 `board` 模块执行 `selftest.run()`，不碰板子；文档代理 2026-11-24 复跑，结果与板级日志一致。
- 以固件参数交叉编译通过（主代理实测，2026-11-24）：`ble-802154`、`ble-security` 两个自检都按 `riscv32-freestanding-eabihf`、
  `generic_rv32+m+a+c+f+zicsr+zifencei`、`ReleaseSmall` 编译，根文件在编译期断言目标架构。最初那条命令把 `-target` 放在最后一个
  `-M` 之后，产物其实是 x86_64（假绿，已更正）；命令与对照见 `wifi-ieee80211-verification.md` §5.1。
- 板级：`BOARD=/dev/ttyUSB0 python3 tests/e2e/run_e2e.py --board --profile wifi` → `PASS board:wifi`（主代理实测）。`logs/e2e-wifi-boot.log` 里 `section: ble_802154` 之后有 50 行 `check:`，全部 `ok=1`，接着是 `checks: passed=50 failed=0 total=50`；整份日志 14 个 `section:`、`main: verdict=pass`。

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

### 4.1 第三批的差分

下表的数字是 2026-11-25 主代理在集成后的代码上重跑得到的（§5.2）。参照实现都在 `/tmp/s31-oracle/`，一次性驱动不入库。

| 特性 | 参照实现 | 规模 | 结果 |
| --- | --- | --- | --- |
| Robust Caching 的 Database Hash | `eatt_oracle.py`（Python `cryptography` 的 AES-CMAC） | 24 张随机属性表（种子 20261124，期望值入库在 `eatt_tests.zig`）；空表与只含不进哈希的属性的表按「空消息的 AES-CMAC，即 RFC 4493 例 1」核对 | 仓内两条计算路径都是 0 不一致；Vol 3 Part G 附录 B 的例子与表 B.1 的结果逐行相等。oracle 自检：RFC 4493 例 4、附录 B、表 B.1 共 22 行，通过。交付时另做过一次 3000 张表的差分（临时用例，已删）：两条路径 0 / 0 不一致 |
| RPA 的生成与解析 | `privacy_oracle.py`（先用 FIPS-197 附录 B 的已知答案自检，`cryptography` 与一份纯 Python AES 对拍 16 个随机单块） | 仓内 24 组向量（种子 20261124）；仓外 2000 组（种子 20261125），每行换 IRK 与 prand | 仓外差分：`differential: rows=2000 gen-mismatch=0 resolve-miss=0 wrong-irk-hit=0`、`differential(list): rows=2000 wrong=0`。仓内 24 组与 oracle 的输出逐行相同。单次交叉核对：`privacy_oracle.py rpa --irk 2b7e…f3c --prand 213c5a` 的输出等于 `vectors.zig` 里的 `rpa_addr` |
| 扩展广播与 EATT 的 L2CAP 部分 | 没有独立 oracle。期望值是按参数表排出的字节，布局与 NimBLE 的结构体、遍历代码和 controller 的位序交叉核对 | — | 交叉核对，不是差分 |
| 6LoWPAN 的 IPHC 压缩 / 解压、分片与重组、UDP 校验和 | `lwip_lowpan/campaign.py`（盘上 IDF v6.1 自带的 lwIP 源码 `lowpan6.c`、`lowpan6_common.c`，不改一行，编成宿主程序；Zig 侧是仓库现有的 `fifteen4.zig` 编成的动态库） | 种子 7、42、99，每个种子 1000 个随机报文 | Zig 自往返与 UDP 校验和 3000/3000；与 lwIP 不一致的报文全部落在四类里，每一类都对到了 lwIP 的源码或 RFC 6282 的原文（见下表） |

上表 6LoWPAN 那一行是主代理在集成之后重跑的（§5.2），逐个种子的数字：

| 种子 | Zig 压缩 → lwIP 解压与原包一致 | lwIP 压缩 → Zig 解压与原包一致 | Zig 自往返 | UDP 校验和（Python = lwIP = Zig） |
| --- | --- | --- | --- | --- |
| 7 | 992 / 1000 | 838 / 1000 | 1000 / 1000 | 1000 / 1000 |
| 42 | 985 / 1000 | 833 / 1000 | 1000 / 1000 | 1000 / 1000 |
| 99 | 990 / 1000 | 848 / 1000 | 1000 / 1000 | 1000 / 1000 |

每个种子里不平的报文数等于下面相应几类的计数之和（种子 7：Zig → lwIP 的 8 是第二类；lwIP → Zig 的 162 是第三类加第四类，
47 + 115）。四类的归因依据：

| 类别 | 方向 | 依据 |
| --- | --- | --- |
| 短地址（16 位）源帧，lwIP 丢帧 | Zig 分片 → lwIP 重组 | `lowpan6.c:241` 拿**目的**短地址的掩码常量去比**源**地址模式，两个常量数值不同，短地址源帧落进「不支持的地址模式」回 `ERR_VAL` |
| 上下文超过 64 位时，IID 里被上下文覆盖的位 lwIP 按 /64 换成常量 | Zig 压缩 → lwIP 解压 | `lowpan6_context_lookup` 用 `ip6_addr_net_eq` 只比前 64 位，上下文就是 `ip6_addr_t` 数组，没有前缀长度；RFC 6282 行 414–435 规定「Bits covered by context information are always used」 |
| 上下文不足 64 位时，「缝」里的位 lwIP 用上下文的前 64 位填充，Zig 置零 | lwIP 压缩 → Zig 解压 | 同上（lwIP 只会 /64）；RFC 6282 行 414–435 规定「Any remaining bits are zero」 |
| `::` 作源地址时，lwIP 配上空槽的上下文号，Zig 拒解（`NoContext`） | lwIP 压缩 → Zig 解压 | lwIP 的查找拿 `::` 的前 64 位（全零）去比，没用到的槽也是全零，于是「命中」空槽并标成有状态压缩（SAC=1、SAM=00、CID 指向该槽）。RFC 6282 行 412 写明 SAC=1、SAM=00 就是 `::`，不依赖上下文；§3.1.2（行 553–554）对「上下文未知时怎么办」没有规定。两边都不违反 RFC，但这是一个互通缺口（§6） |

脚本另把 14 个 lwIP 的 NHC 不处理的头部组合（扩展头链、IPv6-in-IPv6、`::` 源地址、/128 上下文等）单独列一组：Zig 压缩再解压
14/14 等于原包；lwIP 拒收 8 个、收下 6 个，收下的脚本没有再比较。脚本给「lwIP 收下了」打的标签是 `FAIL unsupported-combo lwip accepted`，
那是脚本原本预期 lwIP 会拒收，不是 Zig 侧的不一致。


## 5. 主代理独立复核

- HCI 参数布局对 NimBLE 的 C 结构体（`~/esp/esp-idf/components/bt/host/nimble/nimble/nimble/include/nimble/hci_common.h`，另一份独立实现）：LE Set Advertising Parameters 15 字节、LE Create Connection 25 字节 12 个字段、LE Connection Update Complete 事件 10 字节，逐字段顺序一致。
- 仓库门禁（格式、`check-host.sh`、`check-coverage.py`、`check-invariants.py`）全绿。
- 两个自检以固件参数（`riscv32-freestanding-eabihf`、`generic_rv32+m+a+c+f+zicsr+zifencei`、`ReleaseSmall`）编译通过；用桩 `board` 模块在主机上执行 `selftest.run()`，19/19 与 25/25（`ble-802154` 的 19 是修复之后的数）。
- 板侧第一次上板时 `ble-802154` 为 18/19：`check: gap adv kat=1 nospace=1 name=1 hci=0 malformed=1 ok=0`。原因是自检把 32 字节的 HCI 参数与向量的 31 字节切片比较，恒为假；与目标无关，已改为整段比较。这次失败也说明该 agent 只对自检做了交叉编译、从未执行过它。
- 复验：同一条命令（`run_e2e.py --board --profile wifi`）再跑一次，`ble_802154` 19/19，14 个 section 全过。

### 5.1 第二批（ATT / GATT 扩展）的独立复核（2026-11-24）

本小节的执行结果、更正记录和三条独立复核来自主代理实测；文档代理只核对了其中标出的几处。

**用例的第一次执行与更正。** 第二批的 54 条新用例在交付时一次都没有被执行过。主代理第一次执行是 119 过 3 败，败的和随后改掉的全是用例里手敲的期望值有误，实现是对的。按规范改正下面 6 处后 122/122：

| # | 用例里的错误 | 应为 | 依据 |
| --- | --- | --- | --- |
| ① | GATT 服务的 UUID 写成 0x1800（`gatts: service, characteristic and descriptor declarations…`，现 `host_tests.zig` 第 3523 行） | 0x1801 | Vol 3 Part G §7 |
| ② | Read Response 的值少 1 个字符；同一条用例里的字符串断言也少 1 | ATT_MTU−1 = 22 字节 | Vol 3 Part F §3.4.4.4 |
| ③ | Read By Type 的值少 1 个字符，字符串断言也少 1 | ATT_MTU−4 = 19 字节 | Vol 3 Part F §3.4.4.2 |
| ④ | Read Multiple Variable 的第三个元组 `present` 期望 0 | 1（脚本里那个元组带 1 个值字节） | Vol 3 Part F §3.4.4.12 |
| ⑤ | Read By Group Type 带围 128 位 UUID 时 Length 写成 0x08 | 4 + 16 = 0x14 | Vol 3 Part F §3.4.4.10 |
| ⑥ | Read By Type 带 2 字节值时 Length 写成 0x05 | 0x04 | Vol 3 Part F §3.4.4.2 |

④ 所在的用例另补了两条真正覆盖截断规则的断言（见下一条）。

**§3.4.4.12（ATT_READ_MULTIPLE_VARIABLE_RSP）的原文复核。** 原文在本地规范文本的第 2936–2970 行。`Value Length` 是 2 个八位组；`Length Value Tuple List` 超过 ATT_MTU−1 就在那里截断，若截点落在某个 `Value Length` 字段之内，则在该元组的起点截断；被截断的元组的 `Value Length` 仍是完整长度（规范注：客户端不得用 `Value Length` 推断实际带来的字节数）。`att.zig` 的 `VarBuilder` 三条规则逐条吻合。独立实现 NimBLE 的 `ble_att_svr_build_read_mult_rsp_var`（本机 IDF 的 `ble_att_svr.c` 第 1930–2022 行）同样用 16 位长度（`htole16`）；不同的是它遇到放不下的元组整条不放、不截值。两种做法都符合原文。

**ATT 线上结构对 NimBLE `ble_att_cmd_priv.h` 的 PDU 尺寸定义。** Error Response 5、Exchange MTU 3、Find Information Request 5、Find By Type Value Request 7 + 值、Read By Type Request 7 / 21 与应答条目 6 / 20、Read Request 3、Read Blob Request 5、Read Multiple Request（句柄表）、Read By Group Type Request 7 / 21 与条目 6 / 20，与 `host_tests.zig` 里的字节脚本一致。文档代理重读了该头文件的 `_SZ` 定义（`BLE_ATT_ERROR_RSP_SZ 5`、`BLE_ATT_MTU_CMD_SZ 3`、`BLE_ATT_FIND_INFO_REQ_SZ 5`、`BLE_ATT_FIND_TYPE_VALUE_REQ_BASE_SZ 7`、`BLE_ATT_READ_REQ_SZ 3`、`BLE_ATT_READ_BLOB_REQ_SZ 5`、`BLE_ATT_READ_TYPE_ADATA_BASE_SZ 2`、`BLE_ATT_READ_GROUP_TYPE_ADATA_BASE_SZ 4`），与上面的数相符。

### 5.2 主代理对第三批的独立复核（2026-11-25）

- **逐片验收**：扩展广播、EATT、LL Privacy 三片各跑 `sh /tmp/r5c/accept.sh ble-802154 <特性>`，内容是 `zig test <特性>_tests.zig`、
  从输出里取板侧子自检在主机上的读数、以固件参数单独编译该子自检、`zig fmt --check`。读数：扩展广播 115/115、
  自检 `passed=27 failed=0`（最长一行 79 字节）；EATT 57/57、`passed=10 failed=0`（97 字节）；LL Privacy 66/66、`passed=9 failed=0`（72 字节）。
- **差分重跑**：`eatt_oracle.py selfcheck`、`privacy_oracle.py selftest`（6 项通过）、仓外 2000 组与仓内 24 组，数字见 §4.1。
- 这三片的实现没有在复核中发现缺陷。集成时只确认了一处边界：新命令与新子事件各自在模块里编解码，没有登记进
  `hci_cmd.zig` / `hci_evt.zig` 的统一分发（§6）。
- **逐片验收（6LoWPAN）**：`zig test sixlowpan_tests.zig` → `All 50 tests passed`，其中的子自检用例读到 `passed=10 failed=0`
  （最长一行 71 字节）；`sixlowpan_selftest.zig` 以固件参数单独编译通过；`zig fmt --check` 干净；10 处 `check(` 调用。
  这一片的差分在逐片验收时没有重跑；§4.1 的数字是集成之后把仓库现有的 `fifteen4.zig` 重新编成动态库再跑出来的
  （`build_zig.sh`，`campaign.py <种子> 1000`，三个种子共 16 秒）。

## 6. 实现偏离

- ATT MTU 上限取 527（`ble-802154/src/att.zig` 的 `max_mtu`）。5.4 的 Part F、Part G 文本里没有给 ATT_MTU 的上限，只有属性值最长 512 字节（Vol 3 Part F §3.2.9）；本地规范文本里检索不到 517。527 沿用 NimBLE，正好让最大的命令 Signed Write（1 + 2 + 512 + 12）装下 512 字节的值。小于 23 的 MTU 请求直接拒绝是章节时代客户端入口 `encodeMtuReq` 的原有行为；服务端对小于默认值的 Client Rx MTU 不改 ATT_MTU（Vol 3 Part F §3.4.2.2）。
- LE Advertising Report（`hci_evt.zig`）只做 legacy 事件；扩展广播数据由第三批的 `ext_adv.zig` 解析（§7.7.65.13），没有并进 `hci_evt.zig` 的统一分发。
- AD 结构里 Length = 0 按规范当作填充的起点。
- **签名的字节序**：Vol 3 Part H §2.4.5 的文字与 Vol 3 Part F §3.4.5.4 的样例互相矛盾，本实现按样例；与按字面顺序实现的协议栈能否互通未知。
- 规范没规定或自相矛盾、由实现选定的：两端公钥 X 坐标相同时回 Invalid Parameters；乱序命令回 Unspecified Reason；Repeated Attempts 取 1 秒起、上限 64 秒、30 秒回落；随机数用 HKDF-Expand 展开调用方的 256 位种子；AuthReq 保留位忽略；Bonding_Flags 非 01 按 No Bonding；MIC 校验失败时明文缓冲清零。
- Peripheral 的 `LL_START_ENC_REQ` 明文发，Central 与 Peripheral 的 `LL_START_ENC_RSP` 加密发；意外控制 PDU 按 0x3D 丢失。
- **第二批 · 规范允许与不允许截断的 PDU**（`att.zig` 文件头）：规范允许截断的响应（Read、Read Blob、Read Multiple 的值，通知与指示的值）按 ATT_MTU 截断并计入 `stats.truncated`；规范不允许截断的（Prepare Write 的部分值、Write Command、Signed Write Command、Multiple Variable Length Notification）超出 ATT_MTU 返回 `TooLong`，不写半截。
- **第二批 · ATT 服务端**（`att_server.zig` 文件头与常量），规范留了余地、由实现选定的：
  - Read Blob 读定长短属性时不回 Attribute Not Long（Vol 3 Part F §3.4.4.5 写的是 may）。
  - ATT_EXECUTE_WRITE_REQ 的 Flags 不是 0x00 / 0x01 → Invalid PDU（Vol 3 Part F §3.4.6.3）。
  - 排队写的部分值长过属性表的值上限 → Prepare Queue Full（Vol 3 Part F §3.4.6.1：没有空间排队就回 0x09）；尺寸与偏移的校验照规范留到 Execute。
  - Execute 时遇到 Invalid Offset / Invalid Attribute Value Length，出错句柄取队列里出问题的那一条（规范只对应用错误写明了这一点，Vol 3 Part F §3.4.6.3）。
  - 不记时间：指示的 30 秒超时（Vol 3 Part F §3.3.3，`transaction_timeout_ms = 30_000`）由调用方把毫秒数传给 `tick()`；超时后这条 bearer 的收发一律 `error.BearerClosed`，直到 `reset()`。
  - 不持久化：断链后排队写的队列清空、不执行（Vol 3 Part F §3.4.6）；槽位在 `reset()` 里回到默认值（Vol 3 Part G §3.3.3.3）；CSRK 与 SignCounter 属于安全数据库，`reset()` 不动。
  - 容量是编译期常量：`Db(N, V)` 最多 N 个属性、每个值最多 V 字节；`Peer(Q)` 的排队写队列 Q 条（1 到 255）；每个 client `slot_count = 8` 个槽位、每槽 `slot_max = 16` 字节。
- **第二批 · GATT 客户端**（`gatt_client.zig` 文件头与 `Config`），规范没写死、由实现选定的：
  - 排队写中途收到 ATT_ERROR_RSP：只要已经有数据排进 server 的队列，就补发一条取消（Execute Write，Flags = 0x00），等它的响应回来这条 bearer 才空闲。
  - server 的响应结构不对（条目装不下整数条、句柄乱序、UUID 不是 2 或 16 字节、与当前过程无关的响应）→ 过程按协议错误失败。
  - Read Using Characteristic UUID 收到 Attribute Not Found 按失败处理（Vol 3 Part G §4.8.2），由调用方看错误码；各发现过程收到 Attribute Not Found 是正常结束。
  - 等响应超过 30 秒（Vol 3 Part F §3.3.3、Part G §4.14，`timeout_ms = 30_000`）→ 过程失败，这条 bearer 作废。
  - `Config` 的默认容量：服务 8、包含服务 4、特征 16、描述符 16、读值缓冲 128 字节、写值缓冲 128 字节、句柄与结果 8 条；放不下时过程按本地错误失败。
- **第二批 · GATT 服务端**（`gatt_server.zig`）：写 CCCD 时置了特征不支持的位（或保留位）回 0x80（Application Error 区间的第一个值，`ccc_not_allowed`）。Vol 3 Part G §4.12.3 规定了尺寸不对或值不合法时不写、回 Application Error，没有规定具体取值。
- **第二批 · 签名的两处字节序**（`cmac.zig` 文件头）：待签消息进 CMAC 前整段字节反转；取 CMAC 结果里最高有效的 64 位，写进 PDU 时最低有效字节在前。本机 IDF 的 NimBLE（`ble_att_svr.c`、`ble_att_clt.c` 的 `swap_in_place`）做法相同，文档代理核对过这两个调用点。
- **第二批 · GATT 没做的**（`gatt_server.zig` 文件头）：Database Hash、Client Supported Features、Server Supported Features 三个特征（Vol 3 Part G §7.2–§7.4），Robust Caching（§2.5.2.1），绑定设备的 CCCD / Service Changed 持久化。前两项第三批已在 `robust_cache.zig` 里做了（见下面第三批）；持久化仍未做。

第三批（BLE 侧）：

- **扩展广播与周期广播的范围**（`ext_adv.zig` 文件头同文）：
  - 取决于 Controller 自身能力或状态、host 侧算不出来的判据没有建模，测试里也不假装算：Memory Capacity Exceeded / Packet Too Long；
    §7.8.56 的「will not fit in the AUX_ADV_IND PDU」只判了能从 8 位的 Length 推出来的那一段；Controller 支持哪些间隔、事件类型、
    PHY、CTE 类型；Own_Address_Type 0x02 / 0x03 时解析列表里有没有对应项、设备有没有公有地址；扫描与同步的时序调度。
    扫描与同步那几条命令只编码，不做调度。
  - 原文没写、由实现定下的三处：多条判据同时违反时的先后（先看句柄是否存在，再看参数是否合法，再看当前状态，最后才算容量）；
    把已经带着超过 31 字节数据的集合改成 legacy 类型回 0x12；句柄不存在时 Set Advertising Set Random Address 回 0x42。
  - 链路层扩展头只做位图解码与字段切分，不涉及时序。
- **EATT 与基于额度的 L2CAP 连接**（`eatt.zig`、`l2cap_coc.zig` 文件头同文）：
  - EATT 的实现限制：每条 bearer 只有一个待发的 ATT PDU 位置，挤不进去的应答返回 `Busy`；CID 固定是 `0x0040 + 槽位`；
    不发 L2CAP 的 DISCONNECTION 请求，本端关闭 bearer 后对端要到用满额度、或发来的 K-frame 被拒之后才知道。
  - 与 NimBLE 不同的两处，都按原文：重配置请求里的 Destination CID 是发请求一方的端点，收它的这一端按对端 CID 找信道；
    ATT_EXECUTE_WRITE_REQ 不回 Database Out Of Sync（0x12）——表 3.44 没有把它列为允许 0x12 的方法，NimBLE 回。
  - 原文没有规定、由实现定下的几处写在各自的函数上：多个拒绝理由同时成立时回哪一个；成功响应里 MTU / MPS 低于最小值怎么处理；
    重配置时哪个方向出错。
- **LL Privacy 与 LE Power Control**（`privacy.zig`、`power_ctrl.zig`）：
  - 四个参数全同的重复 Add：§7.8.38 允许拒绝（0x12），也允许不重复添加并回成功；取拒绝。
  - 检查顺序照原文段落的顺序，先判容量再判内容，所以列表满时重复条目也报 `ListFull`。原文对「又满又重复」没有规定先后；
    盘上 NimBLE 的 host 实现也是先查容量。
  - 「解析超时」按两种含义都做了：RPA_Timeout 定时器（§7.8.45、§6.1）；主机侧解析的时间预算，单位是「这次最多试几个 IRK」，
    不是微秒。
  - `decodeTxPowerReporting` 拒绝 Reason 0x00 时 TX_Power_Level = 0x7E：原文只把 0x7E 定义为「对端没在管功率」，这是较严的读法。
  - `PathLossTracker` 里「报的区与损耗数值对不上」是从 §4.5.16 的边界与回差推导出的 host 侧校验，原文没有定义这样的校验。
  - `Responder` 是 §5.1.17 controller 行为的纯逻辑模型，host 自己在空口上看不到 LL_POWER_CONTROL_REQ。
  - `LocalRpa.regenerate` 的 prand 由调用方给，模块不含随机源。
  - 与 NimBLE 两处不同、跟原文：`BLE_MAX_RPA_TIMEOUT_VAL`（约 11.5 小时）是旧上限，5.4 是 0x0E10；加完条目后把所有对端
    设成 device mode，与默认的 network mode 不符。
- **6LoWPAN 的范围**（`fifteen4.zig` 文件头同文）：
  - 没做的：6LoWPAN-ND（RFC 6775）的协议本体，只实现它的上下文表，不解析 RA / 6CO；Mesh 路由（只有 Mesh 头与 §11 的 hop 规则）；
    RFC 8930、RFC 8931；RFC 4944 §10 的 HC1 / HC2；Thread MLE；分页 dispatch 的 Page 2–15。
  - `NoContext`：IPHC 指向一个不存在、已删除或已过保持期的上下文就拒解，这是设计（错误表里写明）。它也包括 SAC=1、SAM=00 的
    `::` 源地址：RFC 6282 行 412 规定这个地址不依赖上下文，而 lwIP 的压缩器只要上下文表里有没用到的槽，就会给 `::` 配上那个槽的
    上下文号（§4.1）。结果是 lwIP 发的、以 `::` 为源地址的报文（例如重复地址检测、MLD 上报）在 Zig 这边解不出来。
    要不要对 SAM=00 放宽成不看上下文，RFC 没有规定，留给接到真实链路时决定。
- **新命令与新子事件没有登记进统一分发器**：扩展广播、LL Privacy、LE Power Control 的新 OpCode 与子事件码各自在模块里编解码。
  `hci_cmd.expects()` / `parseReturn` 对这些 OpCode 回 `UnknownOpcode`，`hci_evt.decodeParams` 对子事件 0x20 / 0x21 等
  回 `UnknownSubevent`。它们还没有接到发送路径上，并进统一分发留给接线那一步。

## 7. 未验证

- 空口互通：配对、加密、重连、签名写；CRC 八位组的线上打包要先对一次真实字节。
- P-256 点乘在 rv32 上的耗时和栈占用。
- Number Of Completed Packets 的实际布局、PB = 0b11 是否出现、失败命令是否只回 Status。
- 第二批：与真实设备的 ATT / GATT 互通（发现、读、写、订阅、指示）。到 2026-11-24 为止只有进程内对打，没有任何 ATT PDU 上过链路。
- 第二批：30 秒事务超时与指示超时在真实链路上的行为。主机用例（`att_svr: indication waits for its confirmation…`、`gattc: a request that is not answered within 30 s…`）与板侧 ㊵ 都是把时间直接拨到 30 秒后，没有真实等待过。
- 第二批：签名写的 CSRK 由上层从绑定信息提供（`att_server.zig` 的 `Peer.csrk`），`ble-802154` 不导入 `ble-security`，这条接线没有验证过。
- 第二批：板侧自检不覆盖、只有主机用例的分支：ATT 的 Find By Type Value 与多重变长通知；ATT 服务端错误码全表（㉞ 只查 Read Not Permitted、Write Not Permitted 与 Invalid Handle）；GATT 客户端的按 UUID 发现、包含服务、描述符发现、Read Using UUID、定长 Read Multiple、Write / Signed Write / Reliable Write、指示确认与多重通知、过程超时与协议错误。
- 第三批：真实设备上的扩展广播与周期广播、EATT、LL Privacy、LE Power Control，都没有任何证据；只有主机测试与板侧自检。
- 第三批：扩展广播与 EATT 的 L2CAP 部分没有独立 oracle 的差分，只有按参数表排出的字节与对 NimBLE 源码的交叉核对。
- 第三批：新命令与新子事件没有经过 `hci_cmd.zig` / `hci_evt.zig` 的统一分发（§6）。
- 第三批：6LoWPAN 与 lwIP 的互通只在宿主机上对过（§4.1），没有上过链路。§6 里 `::` 源地址的那一类差异，遇到 lwIP 发的帧 Zig 的解压器会拒解。

## 8. 对真实 controller 的 HCI 一致性自检（2026-11-24）

BLE 没有 RFC，本节的依据是 Bluetooth Core Specification 5.4 Vol 4 Part E（HCI）。级别 L3：在真实 BLE controller 上执行。

### 8.1 结论

| 项 | 数 |
| --- | --- |
| 命令条数（都是只读的本地信息命令） | 26 |
| 板侧 checks | 26：20 过，6 不过 |
| 合规且回成功（受支持） | 16 |
| 合规且回 `0x01`（声明不支持） | 4 |
| 偏差 | 6，分三类 |
| bt-blobs 主机用例 | 21 → 67 |

聚合行（`logs/hci-conformance-boot.log`）：`hci-conformance: checks passed=20 failed=6 total=26 supported=16 not_supported=4`。

### 8.2 实现

- `components/bt-blobs/src/hci_conformance.zig` 发 26 条只读命令（不改状态、不需要对端），按 Vol 4 Part E 逐条校验回包。每条命令在 `commands` 表里带表 3.1「LE Controller」列的标注（M / O / C.n / E，脚注原文抄在 `Support` 的注释里）。
- 15 条规则（`Rule` 的 15 个标签）：回包长度、Status、保留位、取值范围、LE ACL 长度的保留缺口、页号回显、LE_States 组合、LMP / LE 特征依赖与必选位、LE 特征 33/34 相等，以及 4 条按声明支持的判决：`mandatory_unsupported`、`excluded_but_supported`、`support_bit_mismatch`、`status_event`。
- 判决入口 `verifyDeclared(cmd, evt, mask)`：先读 HCI_Read_Local_Supported_Commands 的 64 八位组位图，再按「声明支持 / 声明不支持」判。回成功但位图为 0、位图为 1 却回 Unknown、LE Controller 标 E 的命令却回成功，都算违规。按 §4.5，不支持的命令回 `0x01 Unknown HCI Command` 是合规的，回包形态可以是 Command Complete 也可以是 Command Status。`verify()` 保持原语义。

### 8.3 主机验证

```sh
cd firmware && env -u LD_LIBRARY_PATH zig build test --summary all   # 1044/1044
```

bt-blobs 目标 21 → 67。增量 46 = `hci_conformance.zig` 文件内的 23 条（此前 `host_tests.zig` 不 import 这个文件，一条没跑过；第一次执行时 3 条用例自身有错，已修：codec 计数、LE 取值范围的前置字段、LE_States 的位号；另 1 条只改名加注释）+ `hci_conformance_tests.zig` 的 23 条（22 个具名用例 + 1 个 import 块）。

新用例的覆盖：

- 15 个规则标签各有负例与正例；
- 表不变量：按 opcode 升序、26 条、`support` 与表 3.1 逐条相等；
- `verifyDeclared` 的全矩阵：位图未知 / 全 0 / 位置 1 × M / O / C / E × 成功 / `0x01` 的两种回包形态 / 其它错误码 / Command Status 带 Status 0；
- `reportsSupport` 的位序、`describe` 的截断。

表 3.1 的 26 条由两个人独立对着原文复核一致；`supp_bit` 抽了 11 条对 §6.27（115、117、119、121、128、186、201、202、312、333、362），全部吻合。

### 8.4 探针接线（`probe.zig`）

- 自检在探针脚本里**同步**跑完，位置在 A 阶段（HCI Reset、Read Local Version、Read BD_ADDR 三条基础命令都拿到回包）之后、任何射频实验（0x2006 / 0x2008 / 0x200A）之前。
- A 路径的回包在 `sendCmd` 返回之前就经 `btdmTx` 到达（日志里 `btdm_tx` 逐条 +1），所以 `hciConformanceRun()` 把 `hciConformanceTick()` 的状态机连着推进到收尾。
- 每条命令等回包上限 2 s（§4.4 建议主机用 1 s），等待期间喂狗。
- `transport.zig` 为此保留最后一条事件的完整帧（至多 80 八位组）、事件序号与来处通道，并改正了事件帧长：原按 `1 + plen` 切，每条少记最后一个八位组；规范是 `2 + plen`，不含 H4 类型字节。

### 8.5 三次上板

配方：`sh /tmp/probe-board.sh ble <日志名> 45`（BLE 探针 + 共存核）。日志在 `logs/`。

| 次数 | 日志 | 结果 |
| --- | --- | --- |
| 1（10:35） | `hci-conformance-run1-hang.log` | 前 4 条通过后主上下文无限空转。PC 采样钉在 `memcpy`，调用点是 `verify()` 里 `Readout` 初值的拷贝。成因是 tick 自己的缺陷：回包被判为 `other_event` 时先 `return`，超时判断排在它后面永远走不到；第 5 条（Read Buffer Size）的回包不是 Command Complete。已修：超时先判。另：它最初挂在主泵循环上，而脚本在进主循环之前就停在 0x200A 的 synth 墙上，永远轮不到，所以改到 A 阶段之后 |
| 2 | `hci-conformance-run2.log` | 完整跑完，20 过 6 不过 |
| 3（最终） | `hci-conformance-boot.log`（另加整张位图读回） | 与第 2 次相同。自检跑完后探针照旧走到 synth 墙（`ble_hw.c:506` 断言，R3.3），没有 panic / trap |

### 8.6 板上的读数（最终一次）

复核命令：`grep -n "check: hci\|read: hci\|hci-conformance" logs/hci-conformance-boot.log`。

**合规且受支持（16）。**

| 命令 | 读数 |
| --- | --- |
| read_local_version | `hci_version=0x0E lmp_version=0x0E company=0x02E5 hci_subversion=0 lmp_subversion=0`。按 Assigned Numbers §2.1，`0x0E` 是 Core 6.0，`0x02E5` 是 Espressif；模块的名字表按注释停在 5.4，所以板上打 `unknown` |
| read_supported_cmds | 126 位，无保留位 |
| read_local_features | 2 位：BR/EDR Not Supported 与 LE Supported，即 LE-only；无保留位 |
| read_bd_addr | `01:BB:00:00:00:02` |
| read_codecs_v2 | 两个计数都是 0 |
| le_read_buffer_size | acl=517 n=10 |
| le_read_features | 35 位，无保留位 |
| le_read_adv_tx_power | 0 dBm |
| le_read_fal_size | 12 |
| le_read_states | 42 位全支持 |
| le_read_default_dl | 27 八位组 / 328 µs |
| le_read_rsl_size | 4 |
| le_read_max_dl | 251 / 17040，收发相同 |
| le_read_tx_power | −15 … 20 dBm |
| le_read_rf_comp | 0.0 / 0.0 dB |
| le_read_buffer_size_v2 | acl=517 n=10 iso=0 niso=0 |

**合规且声明不支持（4，都回 0x01）。** read_buffer_size、read_data_block_size、read_sp_options、read_loopback_mode。

**偏差（6）。** 括号里是 opcode 与它在位图里的八位组.位；位图原文在日志的 4 行 `read: hci supported_commands[...]`，置位数 126。位图八位组内低位在前（`reportsSupport`，§6.27）。

| 类 | 命令（opcode，八位组.位） | 回包原文 | 违反 |
| --- | --- | --- | --- |
| ① 位图为 0（声明不支持）却回成功 | read_ext_features_p0（0x1004，14.6） | `0e 0e 08 04 10 00 00 02 00 00 00 00 60` | 表 3.1 对 LE Controller 标 E；§3.1 |
| ① | read_codecs_v1（0x100B，29.5） | `0e 06 08 0b 10 00 00 00` | 同上 |
| ② 位图为 1（声明支持）却回 `0x0C Command Disallowed` | le_read_max_adv_len（0x203A，36.6） | `0e 04 08 3a 20 0c` | 位图声明支持 |
| ② | le_read_adv_sets（0x203B，36.7） | `0e 04 08 3b 20 0c` | 同上 |
| ② | le_read_pal_size（0x204A，38.6） | `0e 04 08 4a 20 0c` | 同上 |
| ③ 位图为 0 却回 `0x0C` 而不是 `0x01` | le_read_antenna（0x2058，40.4） | `0e 04 08 58 20 0c` | §4.5 |

回包原文照抄日志的 `raw=` 字段。read_ext_features_p0 这一条日志里是 13 个八位组、`plen=0x0e`；任务书给的转写少了 Status 后面的一个 `00`，以日志为准。同一行的 `n=16` 与 13 对不上，原因未查。

引用的原文：

- §3.1：`Subject to Section 3.2, a Controller shall support the command or event if it is shown as mandatory for at least one of the transports (i.e., BR/EDR or LE) that the Controller supports, otherwise the Controller may support the command or event if it is shown as optional for at least one of the transports that the Controller supports, otherwise it shall not support the command or event.`
- §4.5：`If the Controller does not support an issued command, it shall return the error code Unknown HCI command (0x01) in the Status parameter of either an HCI_Command_Complete event or an HCI_Command_Status event; which event is used is vendor-specific.`

**判读限定。** ②③ 四条分别依赖表 3.1 脚注 C.17（Extended Advertising）、C.21（Periodic Advertising）、C.31（CTE）的特性条件；它们回 `0x0C` 是否与本移植传给 controller 的配置（`components/bt-blobs` 的 config）有关，**未验证**。本自检验的是「按当前配置下发时，controller 对只读命令的回答」。

### 8.7 未验证

- 需要射频、对端或改状态的命令。
- 回包在真实链路上的行为。
- 偏差 ②③ 与 controller 配置的关系。
- 自检只覆盖 26 条只读命令，不是 HCI 一致性测试集。
