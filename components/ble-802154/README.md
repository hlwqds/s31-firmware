# ble-802154 — BLE / 802.15.4 边界

HCI 控制、ACL 分片重组、L2CAP（LE 信令与 credit based 通道）、GAP 广播数据与地址、
IPv6 over BLE，加上原有的 ATT/GATT、802.15.4 FCF、6LoWPAN 无状态解压。

- 主机测试：**68 项**（`firmware` 的 `test` step 聚合；也可单独 `zig test src/host_tests.zig` 于本目录）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 与 `checks: passed=N`
- 依赖方向：本组件 → `boards`；不依赖其它组件（**不**导入 `ble-security`）

## 范围与来源

规范原文都在本次实现时读过，条款号与原文一致：

- Bluetooth Core 5.4 [Vol 4] Part E：HCI 分帧（§5.2、§5.4.1、§5.4.2、§5.4.4）、命令
  （§7.1.6、§7.3.2、§7.4.1/3/6、§7.8.1–7.8.12、7.8.18、7.8.24–7.8.27、7.8.33、7.8.46）、
  事件（§7.7.5、§7.7.14–7.7.16、§7.7.19、§7.7.65.1/.2/.3/.5/.7）、流控（§4.1.1、§4.4）；
  状态码取自 [Vol 1] Part F §2。
- [Vol 3] Part A：CID 表 2.3、B-frame §3.1、K-frame §3.4、信令 §4（4.1、4.20–4.24）、
  credit based flow control §10.1。字段布局取自官方 HTML 的图 4.16–4.20（图片逐格读）。
- [Vol 3] Part C §10.8、§11；[Vol 6] Part B §1.3.2.1–1.3.2.3（含图 1.2–1.4）；
  [Vol 3] Part H §2.2.1、§2.2.2。
- AD 类型编号：Bluetooth Assigned Numbers（2026-11-16 版）§2.3；值格式：Core Specification
  Supplement v11 Part A §1.1–1.12（从官网取，本次未在本地保存目录里）。
- RFC 7668 §3、§3.2.2、§3.2.4（含 3.2.4.1、3.2.4.2）、§3.2.5；RFC 6282 §3.1、§3.1.2、§3.2、
  §3.2.1、§4.3。
- AES：FIPS-197 附录 B。

**不做**：SMP 配对与链路层加密（`ble-security` 组件负责）、ATT/GATT 的新功能、802.15.4 的新功能、
扩展广播、LE Extended Advertising Report。

## 验证状态

- L3 板侧：2026-11-24 随 `wifi` profile 第一次上板，19 条里 18 条通过。为假的一条是 `gap adv … hci=0`：
  自检把 32 字节的 HCI 参数与向量的 31 字节切片比较（差一），与目标无关，已改为整段比较；
  修复后的板级复验待做。日志 `logs/wifi-selftest-prefix-boot.log`。
- L1 主机：2026-11-24，68 项（原有 20 项全部保留 + 新增 48 项），`zig fmt --check src/` 干净。
- 差分：`/tmp/s31-oracle/ble_oracle.py`（seed 7）各 20 条随机向量，`ah` 20/20、`e` 20/20 相等
  （一次性测试，跑完已删除）。
- rv32 交叉编译：`src/selftest.zig` 用固件同一组参数（`riscv32-freestanding-eabihf`、
  `generic_rv32+m+a+c+f+zicsr+zifencei`、`ReleaseSmall`）配真实的 `boards` 模块（只把
  `bt_linked` 桩成 `present = false`）编译通过；只证明能编译，未上板。
- 板侧：**未运行**。自检条数 12 → 19，新增 7 条（⑬–⑲）。
- 基线未动：`tests/baselines.json` 里 `ble-802154` 仍是 20，仓库 README / ROADMAP /
  `docs/TESTING.md` 的前门总数也没改（这些文件不在本组件的改动范围内），需要仓库
  所有者抬到 68。

## 快速开始

```sh
cd components/ble-802154
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG test src/host_tests.zig      # All 68 tests passed
env -u LD_LIBRARY_PATH $ZIG fmt --check src/
```

0.17.1 的 `zig test` 不认 `--summary all`（报 `unrecognized parameter`），所以上面没带；
`zig build test --summary all` 仍然可用。板侧入口是 `selftest.run()`，打印 19 行
`check: … ok=1/0` 和 `checks: passed=N failed=M total=N+M`。

## 文件职责

| 文件 | 作用 |
| --- | --- |
| `src/hci.zig` | HCI 分帧原语：ACL 头、Command/Event 包、事件码、旧的单事件解码器 |
| `src/hci_cmd.zig` | OpCode 表、24 条命令编码器、返回参数解析、命令流控 `Ctl` |
| `src/hci_evt.zig` | 事件分发 `decodeEvent`、ACL 包额度 `Credits`、host 状态 `Host` |
| `src/acl.zig` | 发送分片 `Segmenter`、按句柄重组 `Reassembler(N, 上限)` |
| `src/l2cap.zig` | B-frame、LE 信令、连接参数更新两个角色、credit based 通道 `Channel(上限)` |
| `src/gap_adv.zig` | AD 构造/解析、AdvData/ScanRsp 分配、地址子类型、`ah`、RPA、广播参数打包 |
| `src/ipsp.zig` | BLE 地址 ↔ IID、IPHC 压缩/解压（上下文、最近登记 IID）、组播监听表 |
| `src/vectors.zig` | 新增模块的全部 KAT 常数（编译期十六进制解码） |
| `src/att.zig`、`src/gatt.zig`、`src/fifteen4.zig` | 原有；`fifteen4` 新增共享的 `decodeUdpNhc` |
| `src/host_tests.zig` / `src/selftest.zig` | 主机测试 / 板侧自检入口 |

## 特性对照表

| 特性 | 规范条款 | 测试名 | 向量来源 | 状态 |
| --- | --- | --- | --- | --- |
| HCI 分帧、ACL 头、截断/尾随帧 | Vol 4 E 5.4.1/5.4.2/5.4.4 | `hci: ACL header KAT…`、`hci: truncated and trailing command frames` | 按条款排出的字节 | 主机通过 |
| Reset / Read_Local_Version / Features / BD_ADDR / Disconnect | 7.3.2 / 7.4.1 / 7.4.3 / 7.4.6 / 7.1.6 | `hci_cmd: base command KAT…` | `vectors.hci_*`、`ret_*` | 主机通过 |
| LE_Set_Event_Mask / Read_Buffer_Size v1+v2 / Read_Local_Supported_Features | 7.8.1 / 7.8.2 / 7.8.3 | `hci_cmd: LE event mask and buffer size KAT…` | `vectors.hci_le_*`、`ret_le_*` | 主机通过 |
| LE_Set_Random_Address / Advertising_Parameters / Data / Scan_Response_Data / Enable | 7.8.4–7.8.9 | `hci_cmd: LE advertising KAT…`、`gap_adv: advertising parameter packing` | `vectors.hci_le_set_*` | 主机通过 |
| LE_Set_Scan_Parameters / Scan_Enable | 7.8.10 / 7.8.11 | `hci_cmd: LE scan KAT…` | 同上 | 主机通过 |
| LE_Create_Connection / Connection_Update / Read_Supported_States | 7.8.12 / 7.8.18 / 7.8.27 | `hci_cmd: LE connection KAT…` | 同上 | 主机通过 |
| LE_Enable_Encryption、LTK Reply / Negative Reply | 7.8.24 / 7.8.25 / 7.8.26 | `hci_cmd: encryption and LTK reply KAT…` | 同上 | 主机通过 |
| LE_Set_Data_Length / Read_Maximum_Data_Length | 7.8.33 / 7.8.46 | `hci_cmd: data length KAT…` | 同上 | 主机通过 |
| 返回参数解析；失败只回 Status；未知 OpCode | 7.7.14 | `…return parameters KAT…`、`…return parameter negatives` | `vectors.ret_*` | 主机通过 |
| 命令流控（一条未完成、额度刷新） | 4.4 | `hci_cmd: command flow control`、`…completion event kind per opcode` | 行为断言 | 主机通过 |
| Command Complete / Command Status 事件 | 7.7.14 / 7.7.15 | `hci_evt: Command Complete and Command Status…`、`…truncated and trailing event frames…` | `vectors.evt_cc_*`、`evt_command_status_*` | 主机通过 |
| Disconnection Complete、Hardware Error | 7.7.5 / 7.7.16 | `hci_evt: Disconnection Complete and Hardware Error` | `vectors.evt_disconnection_complete`、`evt_hardware_error` | 主机通过 |
| Number Of Completed Packets 与 ACL 包额度 | 7.7.19、5.2、4.1.1 | `hci_evt: Number Of Completed Packets`、`…fake controller drives the Host state` | `vectors.evt_number_of_completed_packets*` | 主机通过 |
| LE Connection Complete | 7.7.65.1 | `hci: LE Connection Complete`、`hci_evt: LE Connection Complete / Update / LTK request / Data Length` | `vectors.evt_le_conn_complete` | 主机通过 |
| LE Advertising Report（1 条 / 2 条 / 负例） | 7.7.65.2 | `hci_evt: LE Advertising Report with one and two reports` | `vectors.evt_le_adv_report_one/two` | 主机通过 |
| LE Connection Update / LTK Request / Data Length Change | 7.7.65.3 / .5 / .7 | `hci_evt: LE Connection Complete / Update / LTK request / Data Length` | `vectors.evt_le_*` | 主机通过 |
| 未知 LE 子事件、未知事件码 | 5.4.4 | `hci_evt: unknown subevent and unknown event code` | `vectors.evt_le_unknown_subevent` | 主机通过 |
| ACL 发送分片（PB=00/01） | Vol 4 E 5.4.2、7.8.2 | `acl: 61-byte L2CAP PDU is segmented into 27/27/7…` | `vectors.acl_hdr_*` | 主机通过 |
| ACL 按句柄重组、乱序/超限/截断 | Vol 3 A 3.1 | `acl: reassembly per handle…`、`…interleaved handles…`、`…out-of-order, oversized and truncated…` | 行为断言 | 主机通过 |
| L2CAP B-frame、CID | 3.1、表 2.3 | `l2cap: B-frame KAT and strict length` | `vectors.l2cap_bframe_read_req` | 主机通过 |
| LE 信令头、Identifier、负例 | 4 | `l2cap: LE signaling KAT…`、`l2cap: signaling negatives` | `vectors.l2cap_cpu_*`、`l2cap_lcbc_*`、`l2cap_credit_ind`、`l2cap_cmd_reject` | 主机通过 |
| Connection Parameter Update（两个角色） | 4.20 / 4.21 | `l2cap: connection parameter update runs both roles` | 行为断言 | 主机通过 |
| LE Credit Based Connection、Credit Ind、K-frame | 4.22 / 4.23 / 4.24、3.4、10.1 | `l2cap: LE credit based channel, both roles`、`l2cap: credits gate sending and non-sequential frames are rejected` | 行为断言 | 主机通过 |
| AD 构造 / 31 字节上限 / 解析 | Vol 3 C 11；CSS v11 A 1.1–1.12；Assigned Numbers 2.3 | `gap_adv: builder lays out every AD type…`、`…does not fit 31 octets…`、`…parser walks AD structures…` | `hci.kat_adv_data`、按条款排出的字节 | 主机通过 |
| AdvData / ScanRsp 自动分配 | 7.8.7 / 7.8.8 | `gap_adv: advertising and scan response split at the 31-octet boundary` | 行为断言 | 主机通过 |
| 随机地址子类型、静态 / 不可解析 / 可解析私有地址 | Vol 6 B 1.3.2.1–1.3.2.3、图 1.2–1.4 | `gap_adv: resolvable private address generates and resolves`、`…static and non-resolvable private address generation` | Python `cryptography` 交叉值（非官方向量） | 主机通过 |
| `ah`、AES `e` | Vol 3 H 2.2.2 / 2.2.1、FIPS-197 附录 B | `gap_adv: random address hash ah`、`gap_adv: AES-128 matches FIPS-197 appendix B` | FIPS-197 附录 B + 交叉值 | 主机通过；差分 20/20 |
| BLE 地址 ↔ IID、链路本地地址 | RFC 7668 3.2.2 | `ipsp: IID and link-local address from a BLE address` | `vectors.ipsp_*` | 主机通过 |
| IPHC 链路本地 / 组播 / 内联 NH | RFC 6282 3.1；RFC 7668 3.2.4 | `ipsp: link-local and multicast compression KAT…` | `vectors.iphc_ll_*` | 主机通过 |
| RFC 7668 3.2.4.1 远端目的例子 | RFC 7668 3.2.4.1 | `ipsp: RFC 7668 3.2.4.1 remote destination example` | `vectors.iphc_7668_6ln_*`、`iphc_7668_6lbr_*` | 主机通过 |
| 多个登记地址的省略 | RFC 7668 3.2.4.2 | `ipsp: RFC 7668 3.2.4.2 multiple registered addresses` | `vectors.iphc_7668_3242_*` | 主机通过 |
| TF / 内联 Hop Limit / UDP 端口压缩、UDP NHC | RFC 6282 3.2.1、4.3 | `ipsp: TF, inline hop limit and UDP port compression round trips`、`lowpan: shared UDP NHC decoder…` | 按条款排出的字节 | 主机通过 |
| 压缩帧负例（C=1、分片头、无上下文、保留组合） | RFC 6282、RFC 7668 3 | `ipsp: unsupported and malformed compressed frames are rejected` | `vectors.iphc_udp_checksum_elided`、`lowpan_frag1` | 主机通过 |
| 组播监听表 | RFC 7668 3.2.5 | `ipsp: multicast listener table at link granularity` | 行为断言 | 主机通过 |

## 实现偏离

1. **LE Advertising Report 只做 legacy 事件**：5.4 的该事件 Data_Length 是 0x00–0x1F；扩展广播
   数据在另一个子事件（§7.7.65.13），本组件未实现。
2. **Number Of Completed Packets 按 §5.2 的默认数组顺序解**（句柄、计数成对）。HTML 版里
   没有该事件的布局图，无法从图上确认；上板第一条要核对这个。
3. **重组器把 PB=0b11 也当首片**：5.4 把它标为 Previously used，放宽只为兼容旧 controller，
   板上确认实际取值后可以收紧。
4. **UDP 校验和被省略（C=1）的帧一律拒收**：RFC 6282 §4.3.2 要求解压方重算并确认另有完整性
   保护，本组件做不到；压缩端从不省略校验和。
5. **上下文前缀长度只支持 64 / 128 位**（RFC 7668 §3.2.4.1 点名的两种）；其余 `BadContext`。
6. **状态压缩 SAM=10 在没有登记 IID 时**退回 RFC 6282 §3.1.1 的 0000:00ff:fe00:XXXX；有登记
   IID 时按 RFC 7668 §3.2.4 取“最近登记地址的前 48 位”。两份文本对此不一致，以 RFC 7668
   （BLE 绑定）为准。
7. **Command Reject 只解 Reason 0x0000**（不带 Reason Data 的形式）。
8. **额度溢出按 16 位字段处理**（`CreditOverflow`）；§10.1 关于溢出的原文本次没读到。
9. **命令流控只保留一条未完成命令**，不利用 controller 的排队。
10. **AD 结构里 128 位 UUID 的字节序**原文没有单独写明，采用最低有效字节在前（与 ATT 一致）。
11. **RPA 子类型位**：图 1.4 里 LSB 在左、MSB 在右，靠 MSB 的两格从右往左读是 0、1，即最高
    两位 `01`（静态 `11`、不可解析私有 `00`）。实现时一度把方向读反成 `10`，已按图改正；
    这是最容易踩的读图陷阱。
12. **6LoWPAN 分片重组未实现**：RFC 7668 §3 明确 BLE 不用 6LoWPAN 分片，分片由 L2CAP 负责
    （`acl.zig` + `l2cap.Channel`）。
13. **`hci.zig` 的接口变动**：`Pb.complete` 改名 `Pb.previously_used`（5.4 里 0b11 不是“整包”）；
    `findLocalName` 移到 `gap_adv.localName`；`decodeCommand` 对截断帧返回 `Short` 而不是
    `Trailing`；新增不带计数的 `packCommand` 和 `decodeEventFrame`。
14. **`fifteen4.decompress` 行为不变**（仍只收 P=00），只把 UDP NHC 解码抽成共享函数。
15. **IDF / 参考实现的逐字节对拍没做**（IID 映射、PB 取值、NOCP 布局）。

## 待验证项

- 上板复验 19 条自检（第一次上板 18/19，见「验证状态」）；与真实 controller 走一遍 Reset → Read_Buffer_Size → 广播 → 连接。
- Number Of Completed Packets 的实际布局、PB=0b11 是否出现、失败命令是否只回 Status。
- AD 结构 128 位 UUID 与 BLE 地址 → IID 的字节序，与参考实现（RIOT / Zephyr）对拍。
- L2CAP credit based 通道与真实对端（IPSP）互通；`LE_Data_Length_Change` 后的 MPS/MTU 变化。
- `LE_Enable_Encryption` / LTK Reply 的参数来源要接 `ble-security`（本组件只做编码）。

历史来源见 `docs/HISTORY.md`。
