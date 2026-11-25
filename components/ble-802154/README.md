# ble-802154 — BLE / 802.15.4 边界

HCI 控制、ACL 分片重组、L2CAP（LE 信令、credit based 通道与基于额度的连接）、GAP 广播数据与地址、
扩展广播与周期广播的 host 侧、EATT 与 Robust Caching、LL Privacy 与 LE Power Control 的 host 侧、
IPv6 over BLE 与 6LoWPAN 适配层（IPHC 两个方向、分片与重组、Mesh 头）、6LoWPAN-ND 的主机侧行为（RFC 6775）、
分片转发与选择性分片恢复（RFC 8930 / 8931），ATT 全部 31 个操作码的编解码、ATT 服务端、GATT 服务端与客户端、AES-CMAC 与签名写，
加上原有的 802.15.4 帧头。

- 主机测试：**485 项**（`firmware` 的 `test` step 聚合；单独 `zig test src/host_tests.zig` 于本目录也是 485：本文件自己 122 项，
  另用 6 个 `test { … }` 块带进 `ext_adv_tests.zig` 115、`eatt_tests.zig` 57、`privacy_tests.zig` 66、`sixlowpan_tests.zig` 50、
  `nd6_tests.zig` 42、`sfr_tests.zig` 27）
- 板侧：`src/selftest.zig` 由固件顺序调用，**152 条**判据（第四批之后；上过板的是前两批的 50 条），打印 `check: … ok=1/0` 与
  `checks: passed=N failed=M total=N+M`
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
- ATT：[Vol 3] Part F §3.2–§3.4。各 PDU 的参数布局在 §3.4.2–§3.4.7，汇总在表 3.43；
  PDU 类型在表 3.1；错误码在 §3.4.1.1 表 3.3、表 3.4；每个方法允许的错误码在 §3.4.9 表 3.44；
  事务与 30 秒超时在 §3.3.3。
- GATT：[Vol 3] Part G §2.5.3（分组）、§3（声明，表 3.1–3.17）、§4.3–§4.14（各过程与超时）、
  §7.1（Service Changed）、附录 A（示例服务器）、附录 B（Database Hash 的输入）。
- AES-CMAC：RFC 4493（[Vol 3] Part H §2.2.5 指向它，附录 D.1 的四个向量与之相同）。
  ATT 数据签名：算法在 [Vol 3] Part H §2.4.5，样例在 [Vol 3] Part F §3.4.5.4。
- 第三批（逐处条款与规范文本的行号见各文件头）：扩展广播——[Vol 4] Part E §5.2、§7.7.65.13、§7.7.65.18、§7.8.52–§7.8.69，
  [Vol 6] Part B §1.2、§2.3、§2.3.4、§2.5.2；EATT 与 Robust Caching——[Vol 3] Part G §2.5.2、§2.5.2.1、§5.3、§7.2–§7.4、
  附录 B，[Vol 3] Part A §2.1、§3.4、§4.22–§4.28、§7.11、§10.1–§10.2，[Vol 3] Part F §3.2.8、§3.2.11、§3.3.2–§3.3.3、表 3.44；
  LL Privacy 与 LE Power Control——[Vol 4] Part E §7.8.38–§7.8.45、§7.8.74–§7.8.77、§7.8.117–§7.8.121、§7.7.65.32–.33，
  [Vol 6] Part B §1.3.2.2–.3、§4.5.16、§4.7、§5.1.17、§6.1–§6.5，[Vol 3] Part H §2.2.2，[Vol 3] Part C §10.7；
  6LoWPAN——RFC 4944 §5.1–§5.3、§11，RFC 6282 §3、§4，RFC 6775 §4.2、§5.4.2–§5.4.3，RFC 8025 §3。
- 第四批（逐处条款与规范文本的行号见各文件头）：6LoWPAN-ND 的主机侧行为——RFC 6775 §3.1、§4.1–§4.3、§5，
  RFC 4861（§4.1–§4.6、§6.1.2、§7.1），RFC 4944 §8；分片转发与选择性分片恢复——RFC 8930 §5、§6，
  RFC 8931 §4.4、§5、§6、§7.1、附录 C。

**不做**：SMP 配对与链路层加密（`ble-security` 组件负责）、802.15.4 的新功能。第三批加的都是 host 侧的编解码与
状态模型，取决于 controller 自身能力或时序调度的部分没有建模（扫描与同步的调度、Memory Capacity Exceeded 之类的判据）。
GATT 里的 Database Hash、Client Supported Features、Server Supported Features 三个特征与 Robust Caching 在
`robust_cache.zig` 里（第三批）；仍没做的是绑定设备的 CCCD / Service Changed 持久化（见 `gatt_server.zig` 文件头）。
6LoWPAN 仍没做的：6LR / 6LBR 与 DAR / DAC（RFC 6775 的路由器侧与多跳重复地址检测）、mesh 路由、HC1 / HC2、
Thread MLE、RFC 8138 的在途改写、分页 dispatch 的 Page 2–15；分片转发里的真实路由查找是注入点。

## 验证状态

第一批（HCI / L2CAP / GAP / IPSP）：

- L3 板侧：2026-11-24 随 `wifi` profile 第一次上板，19 条里 18 条通过。为假的一条是 `gap adv … hci=0`：
  自检把 32 字节的 HCI 参数与向量的 31 字节切片比较（差一），与目标无关，已改为整段比较；
  修复后已板级复验 19/19（当时的 `logs/e2e-wifi-boot.log`，整份判决 pass；这份日志已被第二批 50/50 的那次覆盖）。
  第一次的日志 `logs/wifi-selftest-prefix-boot.log`。
- L1 主机：2026-11-24，68 项（原有 20 项全部保留 + 新增 48 项），`zig fmt --check src/` 干净。
- 差分：`/tmp/s31-oracle/ble_oracle.py`（seed 7）各 20 条随机向量，`ah` 20/20、`e` 20/20 相等
  （一次性测试，跑完已删除）。
- 自检条数 12 → 19，新增 7 条（⑬–⑲）；`tests/baselines.json` 里 `ble-802154` 随本轮抬到 68。

第二批（ATT / GATT 扩展，2026-11-24）：

- L1 主机：`zig test src/host_tests.zig` → `All 122 tests passed`。第一批的 68 条全部保留，新增 54 条：
  `att:` +15、`att_svr:` +13、`gatts:` +5、`gattc:` +18、`cmac:` +3。
- 这 54 条在交付时一次都没有被执行过。第一次执行是 119 过 3 败，原因全是用例里手敲的期望值有误
  （实现是对的）；按规范改正后 122/122。明细见 `docs/verification/ble-core-verification.md` §5。
- L2：`selftest.zig` 以固件参数交叉编译通过；用桩 `board` 模块在主机上执行 `selftest.run()` →
  `checks: passed=50 failed=0 total=50`。
- L3 板侧：自检条数 19 → 50（新增 ⑳–㊿ 共 31 条，清单在 `selftest.zig` 文件头）。`wifi` profile
  板级 `PASS board:wifi`：14/14 个 section、`ble_802154` 50/50、`main: verdict=pass`
  （`logs/e2e-wifi-boot.log`；这一份覆盖了第一批复验的日志）。
- `tests/baselines.json` 里的 `ble-802154` 现为 122。
- 板侧自检与主机用例里的 ATT / GATT 都是进程内对打（请求直接交给服务端、应答直接交回客户端），
  **没有任何 ATT PDU 上过链路**。

第三批（扩展广播、EATT、LL Privacy / LE Power Control、6LoWPAN，2026-11-25）：

- L1 主机：`zig test src/host_tests.zig` → `All 414 tests passed`（122 → 414）。新增四个测试文件：`ext_adv_tests.zig` 115、
  `eatt_tests.zig` 57、`privacy_tests.zig` 66、`sixlowpan_tests.zig` 50；`host_tests.zig` 多 4 个把它们带进来的 `test { … }` 块。
- L2：板侧自检 50 → 106 条（四份子自检 27 + 10 + 9 + 10 接入 `selftest.zig`）。用桩 `board` 模块在主机上执行
  `selftest.run()` → `checks: passed=106 failed=0 total=106`；四份子自检都以固件参数交叉编译通过。
- **这一批没有上板**。上过板的仍然只有前两批的 50 条；`wifi` profile 上板之后应当看到 `ble_802154` 106/106。
- 差分（主代理在集成后的代码上重跑，明细与归因依据见 `docs/verification/ble-core-verification.md` §4.1）：
  Database Hash 对 `eatt_oracle.py`（24 张随机属性表，0 不一致）；RPA 对 `privacy_oracle.py`（仓外 2000 组，0 不一致）；
  6LoWPAN 对 lwIP（三个种子各 1000 个报文；Zig 自往返与 UDP 校验和 3000/3000，与 lwIP 不一致的报文全部归到四类、
  逐类对到了 lwIP 源码或 RFC 6282 原文）。扩展广播与 EATT 的 L2CAP 部分没有独立 oracle，只有按参数表排出的字节
  与对 NimBLE 源码的交叉核对。
- `tests/baselines.json` 里的 `ble-802154` 现为 414。

第四批（6LoWPAN-ND 的主机侧行为、分片转发与选择性分片恢复，2026-11-25）：

- L1 主机：`zig test src/host_tests.zig` → `All 485 tests passed`（414 → 485）。新增 `nd6_tests.zig` 42、`sfr_tests.zig` 27；
  `host_tests.zig` 多 2 个把它们带进来的 `test { … }` 块。
- L2：板侧自检 106 → 152 条（`nd6_selftest` 30 条、`sfr_selftest` 16 条接入 `selftest.zig`）。用桩 `board` 模块在主机上执行
  `selftest.run()` → `checks: passed=152 failed=0 total=152`，最长一行 114 字节；两份子自检与整份自检都以固件参数交叉编译通过。
- **这一批没有上板**（串口 `/dev/ttyUSB0` 当前账号没有权限）。上过板的仍然只有前两批的 50 条。
- 差分（主代理在终态代码上重跑，明细见 `docs/verification/ble-core-verification.md` §4.2）：`nd6` 的 RA / NS / NA 报文与
  选项级畸形对独立手写的 Python 解析器，主代理重跑 9000 例（切片合计 11500 例），0 不一致；被接受的例子里 94.7% 带选项。
  `sfr` 的 RFRAG / RFRAG-ACK 头编解码两个方向 1216 组，0 不一致；发送方、接收方、转发方三个状态机是按原文手排的场景用例，
  盘上没有这两份 RFC 的独立实现。
- 尺寸（riscv32 ReleaseSmall；指令数在 QEMU 上数）：`nd6_selftest` text 15710 B、152883 条 rv32 指令；
  `sfr_selftest` text 17533 B（另 data 1040、bss 880）、75540 条 rv32 指令。
- `tests/baselines.json` 里的 `ble-802154` 现为 485。

## 快速开始

```sh
cd components/ble-802154
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG test src/host_tests.zig      # All 485 tests passed
env -u LD_LIBRARY_PATH $ZIG fmt --check src/
```

0.17.1 的 `zig test` 不认 `--summary all`（报 `unrecognized parameter`），所以上面没带；
`zig build test --summary all` 仍然可用。板侧入口是 `selftest.run()`，打印 152 行
`check: … ok=1/0` 和 `checks: passed=N failed=M total=N+M`（最近一次板级日志是第二批的 50/50；在主机上跑是 152/152）。
同一份自检也能在主机上跑（不碰板子；在仓库根目录执行，`main.zig` 调 `selftest.run()`，
`board_stub.zig` 提供桩）：

```sh
R=/tmp/selftest-host
env -u LD_LIBRARY_PATH zig run --dep selftest -Mroot=$R/main.zig \
  --dep board -Mselftest=components/ble-802154/src/selftest.zig -Mboard=$R/board_stub.zig
```

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
| `src/att.zig` | ATT 全部 31 个操作码（表 3.43）的编解码、最小长度、按 ATT_MTU 截断、服务端组响应的打包器、UUID；末尾保留章节时代的最小 API |
| `src/att_server.zig` | ATT 服务端：属性表 `Db(N, V)`、每个 client 一个 `Peer(Q)`、请求分发、权限检查、排队写、通知与指示、签名写验签 |
| `src/gatt_server.zig` | GATT 服务端：服务 / 包含 / 特征 / 描述符声明、按 client 保存的 CCCD、指示、Service Changed |
| `src/gatt_client.zig` | GATT 客户端：§4.3–§4.12 各过程的状态机（发现、读、写、订阅、指示确认） |
| `src/cmac.zig` | AES-CMAC（标准库 `std.crypto.auth.cmac.CmacAes128`）与 ATT 数据签名 / 验签 |
| `src/gatt.zig`、`src/fifteen4.zig` | 原有定长特征表；`fifteen4` 是 802.15.4 帧头与 6LoWPAN 适配层（`iphc`、`frag`、`mesh`，第三批补全），文件开头的旧入口 `decompress` 原样保留 |
| `src/vectors.zig` | 新增模块与 CMAC / 签名的 KAT 常数（编译期十六进制解码） |
| `src/host_tests.zig` / `src/selftest.zig` | 主机测试（485 项）/ 板侧自检入口（152 条）；第三、四批的 `<特性>_tests.zig` / `<特性>_selftest.zig` 与同名模块一一对应 |
| `src/ext_adv.zig` | 扩展广播与周期广播的 host 侧：17 条 HCI 命令的编码、LE Extended Advertising Report 与 LE Advertising Set Terminated 两个事件、广播集台账、链路层扩展头解析、广播数据分片器 |
| `src/l2cap_coc.zig` | LE 上基于额度的 L2CAP 连接（LE Credit Based Flow Control 与 Enhanced Credit Based Flow Control），两个角色 |
| `src/eatt.zig` | Enhanced ATT bearer 池：ATT 经 L2CAP 信道收发 |
| `src/robust_cache.zig` | Robust Caching：Client Supported Features、Database Hash、change-aware / change-unaware 的跟踪、客户端缓存的判定 |
| `src/privacy.zig` | LL Privacy 的 host 侧：解析列表、RPA 的生成与解析、解析预算、RPA 超时定时器、隐私模式下的地址过滤 |
| `src/power_ctrl.zig` | LE Power Control 的 host 侧：命令与事件编解码、路径损耗上报的跟踪、功率钳定与档位选择 |
| `src/nd6.zig` | 6LoWPAN-ND 的主机侧行为：ARO / 6CO / ABRO / SLLAO 编解码，RS / RA / NS / NA 的校验，上下文表与有效期，地址注册、续期与睡眠，下一跳判定 |
| `src/sfr.zig` | 分片转发（RFC 8930 的 6LFF / VRB）与选择性分片恢复（RFC 8931）：RFRAG / RFRAG-ACK 头，发送方 / 接收方 / 转发方三个状态机 |

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
| ATT 编解码全表：31 个操作码、PDU 类型、最小长度、定长 PDU 的长度校验、19 个错误码 | Vol 3 F 表 3.43、表 3.1、表 3.4、§3.3 | `att: opcode table is Vol 3 Part F table 3.43…`、`att: minimum PDU lengths follow the size columns of Vol 3 Part F table 3.43`、`att: every PDU parses and fixed-length ones reject wrong lengths…`、`att: error codes are the 19 values of Vol 3 Part F table 3.4`、`att: UUIDs compare as 128 bits and the SIG base folds to 16 bits…` | 表 3.43、表 3.1、表 3.4；PDU 尺寸对 NimBLE `ble_att_cmd_priv.h` | 主机通过 |
| ATT Find Information | Vol 3 F 3.4.3.1–3.4.3.2、3.4.3 | `att: find information request and response…`、`att_svr: find information lists every attribute and pages by ATT_MTU…` | 按条款排出的字节、行为断言 | 主机通过；板侧 ㉕ |
| ATT Find By Type Value | Vol 3 F 3.4.3.3–3.4.3.4 | `att: find by type value request and response…`、`att_svr: find by type value returns handle ranges and skips unreadable attributes…` | 按条款排出的字节、行为断言 | 主机通过；板侧无 |
| ATT Read By Type | Vol 3 F 3.4.4.1–3.4.4.2 | `att: read by type request and response…`、`att_svr: read by type packs equal lengths and stops at an unreadable attribute…` | 同上 | 主机通过；板侧 ㉖ |
| ATT Read Blob | Vol 3 F 3.4.4.5–3.4.4.6 | `att: read blob request and response cut the value at ATT_MTU-1…`、`att_svr: read and read blob follow ATT_MTU and reject offsets past the value…` | 同上 | 主机通过；板侧 ㉘ |
| ATT Read Multiple（定长） | Vol 3 F 3.4.4.7–3.4.4.8 | `att: read multiple and read multiple variable length…`、`att_svr: read multiple and read multiple variable length…` | 同上 | 主机通过；板侧 ㉙ |
| ATT Read Multiple Variable（变长，含两条截断规则：超过 ATT_MTU−1 处截断、截点落在 Value Length 字段内则整条元组不放） | Vol 3 F 3.4.4.11–3.4.4.12 | 同上两条 | 同上；原文 2936–2970 行独立复核 | 主机通过；板侧 ㉚ ㉛ |
| ATT Read By Group Type | Vol 3 F 3.4.4.9–3.4.4.10 | `att: read by group type request and response…`、`att_svr: read by group type returns groups and rejects non-group types…` | 按条款排出的字节、行为断言 | 主机通过；板侧 ㉗ |
| ATT 排队写（Prepare / Execute / 取消） | Vol 3 F 3.4.6.1–3.4.6.4 | `att: prepare write and execute write…`、`att_svr: prepare and execute write, both paths…` | 同上 | 主机通过；板侧 ㉜ ㉝ |
| ATT 指示、确认、多重变长通知 | Vol 3 F 3.4.7.2–3.4.7.4 | `att: indication, confirmation and multiple variable length notification…` | 同上 | 主机通过；板侧只有指示（㊵），多重变长通知无 |
| ATT 服务端：MTU 交换 | Vol 3 F 3.4.2.2 | `att_svr: MTU exchange takes the minimum and keeps the default below it…` | 行为断言 | 主机通过；板侧 ㉔ |
| ATT 服务端：权限与错误码（检查顺序、未知 / 非法请求、变长 / 定长写） | Vol 3 F 3.2.5、§4、表 3.4、§3.3、3.4.5.1–3.4.5.3 | `att_svr: permission checks yield the codes of table 3.4 in the order of Vol 3 Part F section 4`、`att_svr: unsupported and malformed requests get the codes of Vol 3 Part F section 3.3`、`att_svr: write request follows variable and fixed length semantics…` | 行为断言 | 主机通过；板侧 ㉞ |
| ATT 服务端：排队写两条路径（执行 / 取消） | Vol 3 F 3.4.6 | `att_svr: prepare and execute write, both paths…` | 行为断言 | 主机通过；板侧 ㉜ ㉝ |
| ATT 服务端：通知、指示与 30 秒超时 | Vol 3 F 3.4.7.1–3.4.7.2、3.3.3 | `att_svr: indication waits for its confirmation and times out after 30 s…` | 行为断言（时间直接拨到超时） | 主机通过；板侧 ㊵ |
| GATT 服务端声明：服务、包含、特征、描述符 | Vol 3 G 表 3.1–3.15、3.17 | `gatts: service, characteristic and descriptor declarations match Vol 3 Part G 3.1-3.3 byte for byte` | 表里的字节 | 主机通过；板侧 ㉟ ㊱ ㊲ |
| CCCD：按 client 保存并门控通知、写入校验 | Vol 3 G 3.3.3.3、4.12.3 | `gatts: the Client Characteristic Configuration is kept per client and gates notifications…`、`gatts: invalid CCCD writes are rejected and leave the configuration unchanged…` | 表 3.10、3.11 的字节；行为断言 | 主机通过；板侧 ㊳ ㊴ |
| GATT 服务端指示 | Vol 3 G 4.11.1 | `gatts: indications need the indicate bit, go one at a time, and are confirmed…` | 行为断言 | 主机通过；板侧 ㊵ |
| Service Changed | Vol 3 G 7.1 | `gatts: the Service Changed characteristic and its enablement…` | 表 7.2、表 7.3 | 主机通过；板侧 ㊶ |
| GATT 客户端：Exchange MTU | Vol 3 G 4.3.1、5.2.1 | `gattc: exchange MTU takes the minimum and the result paves every later procedure…` | 行为断言 | 主机通过；板侧 ㊸ |
| GATT 客户端发现：全部 / 按 UUID 的 primary 服务、包含服务、全部 / 按 UUID 的特征、描述符 | Vol 3 G 4.4.1–4.4.2、4.5.1、4.6.1–4.6.2、4.7.1 | `gattc: discover all primary services of the appendix A server, byte for byte…`、`gattc: discover primary services by UUID uses Find By Type Value…`、`gattc: find included services, including the 128-bit UUID follow-up read…`、`gattc: discover all characteristics of a service…`、`gattc: discover characteristics by UUID keeps only the matching ones…`、`gattc: discover all characteristic descriptors pages by handle…`、`gattc: a read by type response with 128-bit UUIDs looks like the note of Vol 3 Part G 4.6.1` | 附录 A 的服务器，线上字节逐条比对 | 主机通过；板侧 ㊷ ㊹ ㊼ |
| GATT 客户端读：Read、Read Using UUID、Read Long、Read Multiple、Read Multiple Variable | Vol 3 G 4.8.1–4.8.5 | `gattc: read value, read by UUID, read long…`、`gattc: read multiple and read multiple variable length…` | 附录 A 的服务器 + 另搭的属性表 | 主机通过；板侧 ㊺ ㊻ ㊾ |
| GATT 客户端写：Write Without Response、Write、Signed Write、Write Long、Reliable Write | Vol 3 G 4.9.1–4.9.5 | `gattc: write without response, write, signed write…`、`gattc: write long values in ATT_MTU-5 pieces then execute…`、`gattc: reliable writes verify every round trip and cancel on a mismatch…` | 行为断言 | 主机通过；板侧只有 Write Long（㊽） |
| GATT 客户端收通知 / 指示、订阅描述符 | Vol 3 G 4.10、4.11、4.12.1–4.12.4 | `gattc: the client delivers notifications, confirms indications and unpacks multiple notifications…`、`gattc: read and write characteristic descriptors, long and short…` | 行为断言 | 主机通过；板侧只有订阅通知（㊿） |
| GATT 客户端过程失败：ATT 错误、协议错误、30 秒超时 | Vol 3 F 3.4.1.1、3.3.3；Vol 3 G 4.14 | `gattc: ATT errors end the procedure with the server's code…`、`gattc: structurally wrong server responses fail the procedure as protocol errors`、`gattc: a request that is not answered within 30 s fails and closes the bearer…` | 行为断言（时间直接拨到超时） | 主机通过；板侧无 |
| AES-CMAC | RFC 4493 §4；Vol 3 H 附录 D.1；Vol 3 G 附录 B | `cmac: AES-CMAC matches the RFC 4493 vectors quoted in Vol 3 Part H appendix D.1`、`cmac: AES-CMAC with an all-zero key over the database hash input of Vol 3 Part G appendix B` | RFC 4493 四个向量（长度 0 / 16 / 40 / 64）；附录 B 的 111 字节输入 | 主机通过；板侧 ⑳ ㉑ |
| ATT 签名与签名写 | Vol 3 H 2.4.5；Vol 3 F 3.4.5.4 | `cmac: signing reproduces the example of Vol 3 Part F 3.4.5.4…`、`att: signed write command carries the example signature of Vol 3 Part F 3.4.5.4`、`att: write command and signed write command…`、`att_svr: signed write is applied only with a valid, fresh signature…` | Part F §3.4.5.4 的样例 | 主机通过；板侧 ㉒ ㉓；互通未验 |
| 扩展广播与周期广播的 host 侧 | Vol 4 E 7.7.65.13、7.7.65.18、7.8.52–7.8.69；Vol 6 B 1.2、2.3、2.3.4、2.5.2 | `ext_adv_tests.zig`（115） | 按参数表逐字节排的已知答案；与 NimBLE 的命令结构体、报告遍历代码交叉核对 | 主机通过；板侧 27 条（未上板） |
| EATT bearer 池、LE 上基于额度的 L2CAP 连接、Robust Caching | Vol 3 G 2.5.2、2.5.2.1、5.3、7.2–7.4、附录 B；Vol 3 A 4.22–4.28、10.1–10.2 | `eatt_tests.zig`（57） | 附录 B 的 Database Hash 样例；`eatt_oracle.py`；与 NimBLE 交叉核对 | 主机通过；板侧 10 条（未上板） |
| LL Privacy 与 LE Power Control 的 host 侧 | Vol 4 E 7.8.38–7.8.45、7.8.74–7.8.77、7.8.117–7.8.121、7.7.65.32–.33；Vol 6 B 1.3.2.2–.3、4.5.16、4.7、5.1.17、6.1–6.5 | `privacy_tests.zig`（66） | 参数表逐字节；`privacy_oracle.py`；与 NimBLE 交叉核对 | 主机通过；板侧 9 条（未上板） |
| 6LoWPAN 适配层补全（IPHC 双向、NHC、分片与重组、Mesh 头） | RFC 4944 5.1–5.3、11；RFC 6282 3、4；RFC 6775 4.2、5.4.2–5.4.3；RFC 8025 3 | `sixlowpan_tests.zig`（50） | RFC 手排的已知答案；lwIP 的输出（差分） | 主机通过；板侧 10 条（未上板） |
| 6LoWPAN-ND 的主机侧行为：ARO / 6CO / ABRO / SLLAO 编解码、RA / NS / NA 的校验、上下文表、地址注册与续期、睡眠、下一跳判定 | RFC 6775 3.1、4.1–4.3、5；RFC 4861 4.1–4.6、6.1.2、7.1；RFC 4944 8 | `nd6_tests.zig`（42） | 按原文手排的已知答案；独立手写的 Python 解析器（差分） | 主机通过；板侧 30 条（未上板） |
| 分片转发（VRB）与选择性分片恢复：RFRAG / RFRAG-ACK 头，发送方 / 接收方 / 转发方三个状态机 | RFC 8930 5、6；RFC 8931 4.4、5、6、7.1、附录 C | `sfr_tests.zig`（27） | 按原文手排的已知答案；Python oracle（差分，头部编解码） | 主机通过；板侧 16 条（未上板） |

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
16. **ATT MTU 上限取 527**（`att.zig` 的 `max_mtu`）。5.4 的 Part F / Part G 原文没有给 ATT_MTU
    的上限，只规定属性值最长 512 字节（Part F §3.2.9）；527 沿用 NimBLE，正好让最大的命令
    Signed Write（1 + 2 + 512 + 12）装下 512 字节的值。server 端收到小于默认值 23 的
    Client Rx MTU 时不改 ATT_MTU（§3.4.2.2）；章节时代的客户端入口 `encodeMtuReq` 仍对
    小于默认值或超过 527 的请求直接拒绝、不发 PDU。
17. **ATT 服务端**（`att_server.zig` 文件头与常量），规范留了余地、这里定下来的：
    - Read Blob 读定长短属性时不回 Attribute Not Long（§3.4.4.5 写的是 may）；
    - ATT_EXECUTE_WRITE_REQ 的 Flags 不是 0x00 / 0x01 → Invalid PDU；
    - 排队写的部分值长过属性表的值上限 → Prepare Queue Full（§3.4.6.1：没有空间排队就回 0x09）；
      尺寸与偏移的校验照规范留到 Execute；
    - Execute 时遇到 Invalid Offset / Invalid Attribute Value Length，出错句柄取队列里出问题的
      那一条（规范只对应用错误写明了这一点）；
    - 不记时间：指示的 30 秒超时（§3.3.3，`transaction_timeout_ms = 30_000`）由调用方把毫秒数
      传给 `tick()`；超时后这条 bearer 的收发一律 `error.BearerClosed`，直到 `reset()`；
    - 不持久化：断链后排队写的队列清空、不执行（§3.4.6）；槽位在 `reset()` 里回到默认值
      （Part G §3.3.3.3）；CSRK 与 SignCounter 属于安全数据库，`reset()` 不动；
    - 容量都是编译期常量：`Db(N, V)` 最多 N 个属性、每个值最多 V 字节；`Peer(Q)` 的排队写队列
      Q 条（1..255）；每个 client `slot_count = 8` 个槽位、每槽 `slot_max = 16` 字节。
18. **GATT 客户端**（`gatt_client.zig` 文件头与 `Config`），规范没写死、这里定下来的：
    - 排队写中途收到 ATT_ERROR_RSP：只要已经有数据排进 server 的队列，就补发一条取消
      （Execute Write，Flags = 0x00），等它的响应回来这条 bearer 才空闲；
    - server 的响应结构不对（条目装不下整数条、句柄乱序、UUID 不是 2 或 16 字节、与当前过程
      无关的响应）→ 过程按协议错误失败；
    - Read Using Characteristic UUID 收到 Attribute Not Found 按失败处理（§4.8.2），由调用方看
      错误码；各发现过程收到 Attribute Not Found 是正常结束；
    - 等响应超过 30 秒（§3.3.3、Part G §4.14，`timeout_ms = 30_000`）→ 过程失败，这条 bearer 作废；
    - `Config` 的默认容量：服务 8、包含服务 4、特征 16、描述符 16、读值缓冲 128 字节、写值缓冲
      128 字节、句柄 / 结果 8 条；放不下时过程按本地错误失败。
19. **GATT 服务端**（`gatt_server.zig`）：写 CCCD 时置了特征不支持的位（或保留位）回 0x80
    （Application Error 区间的第一个值，`ccc_not_allowed`）；§4.12.3 规定了尺寸不对或值不合法
    时「不写、回 Application Error」，没有规定具体取值。没做的特征见「范围与来源」。
20. **签名的字节序**（`cmac.zig`）：Part H §2.4.5 的文字没有写 Bluetooth 特有的两处字节序，
    本实现按 Part F §3.4.5.4 的样例反推：待签消息进 CMAC 前整段字节反转；取 CMAC 结果里最高
    有效的 64 位，写进 PDU 时最低有效字节在前。验签只接受大于上一次通过值的 SignCounter
    （Part H §2.4.5）。本机 IDF 的 NimBLE（`ble_att_svr.c`、`ble_att_clt.c` 的
    `swap_in_place`）做法相同；与按字面顺序实现的协议栈能否互通未验。

第三批的偏离（扩展广播、EATT、LL Privacy、6LoWPAN 各自的范围与取舍）逐条记在
`docs/verification/ble-core-verification.md` §6「第三批（BLE 侧）」。与上面前两批的条目不同，它们还没有经过板级复验。

第四批的偏离（`nd6` 与 `sfr` 的范围与取舍）记在 `docs/verification/ble-core-verification.md` §6「第四批（BLE 侧）」。要点：保留字段按原文
「接收方必须忽略」处理、不拒收；RFC 6775 §4.3 的 ABRO 字段说明里列了 Reserved，图的 24 字节布局里没有，以图为准；
RFC 8931 §4.4 与 §5.1 对首片 Datagram_Size 所在字段的说法不同，按 §5.1 的布局实现、§4.4 取差值语义。

## 待验证项

- 与真实 controller 走一遍 Reset → Read_Buffer_Size → 广播 → 连接。
- Number Of Completed Packets 的实际布局、PB=0b11 是否出现、失败命令是否只回 Status。
- AD 结构 128 位 UUID 与 BLE 地址 → IID 的字节序，与参考实现（RIOT / Zephyr）对拍。
- L2CAP credit based 通道与真实对端（IPSP）互通；`LE_Data_Length_Change` 后的 MPS/MTU 变化。
- `LE_Enable_Encryption` / LTK Reply 的参数来源要接 `ble-security`（本组件只做编码）。
- 与真实设备的 ATT / GATT 互通：发现、读、写、订阅、指示。到现在为止只有进程内对打。
- 30 秒事务超时与指示超时在真实链路上的行为。主机用例与板侧自检都是把时间直接拨到超时，
  没有真实等待过。
- 签名写的字节序与其它协议栈互通（见「实现偏离」20）。
- 板侧自检没覆盖、只有主机用例的分支：ATT 的 Find By Type Value 与多重变长通知；ATT 服务端
  错误码全表（板侧 ㉞ 只查 Read Not Permitted、Write Not Permitted 与 Invalid Handle）；GATT 客户端的按 UUID 发现、包含服务、
  描述符发现、Read Using UUID、定长 Read Multiple、Write / Signed Write / Reliable Write、
  指示确认与多重通知、过程超时与协议错误。
- 第三批没有上板：`ext_adv`、`eatt`、`privacy`、`sixlowpan` 四份子自检（共 56 条）在板子上一次都没跑过。
- 第三批在真实设备上的行为：扩展广播与周期广播、EATT、LL Privacy、LE Power Control；与 lwIP 节点的 6LoWPAN 互通。
  后者有一个已知的缺口：lwIP 的压缩器把没用到的上下文槽当成与 `::` 的前 64 位匹配，用有状态压缩（SAC=1、SAM=01）编码 `::`
  并指向那个没人配置过的槽，本实现的解压器因上下文不存在而拒解。依据见验证报告 §4.1、§6。
- 第四批没有上板：`nd6_selftest`、`sfr_selftest`（共 46 条）在板子上一次都没跑过。
- `nd6` 与 `sfr` 在真实多跳网络上的行为：与 6LR / 6LBR 的注册、上下文过期、RFRAG 恢复与 VRB 的真实转发。
  `nd6` 的 `syncContexts` 与 `fifteen4` 的上下文表之间的同步有 ±60 s 舍入；`sfr` 的转发方只产出帧，发送间隔归调用方的发送队列。

历史来源见 `docs/HISTORY.md`。
