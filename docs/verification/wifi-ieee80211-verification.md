# Wi-Fi 验证报告（IEEE Std 802.11-2016）

- 规范依据：IEEE Std 802.11-2016（条款号取自该版目录，页码为印刷页码）；其上的 RFC：RFC 3394（AES Key Wrap）、RFC 4493（AES-CMAC）、RFC 6070（PBKDF2）。
- 组件：`components/wifi-mlme`（新）、`components/wifi-connect`（扩展）。
- 验证分级见 `docs/REPO-STANDARDS.md` §4。本报告只写实际跑过的命令和输出里出现过的结果。
- **真实 AP 与空口没有任何证据**：`esp_wifi_start` 仍卡在 `MAC_ST[15:13]`。下表的"通过"指离线验证通过。

## 1. 结论

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| `wifi-mlme` 主机测试 | L1 | 61/61 | §3.1 |
| `wifi-connect` 主机测试 | L1 | 57/57 | §3.2 |
| 与独立参照实现的差分 | L1 | 13 组 950 条全部一致 | §4 |
| RV32 目标编译 | L2 | 两个自检都能以固件参数编译 | §5 |
| 板侧自检（第一次上板） | L3 | `wifi_mlme` 16/16、`wifi_connect` 28/28 | `logs/wifi-selftest-prefix-boot.log` |
| 整体判决为 pass 的板级运行 | L3 | 没有：那一次因别的 section 失败而是 fail | `docs/verification/README.md` |

## 2. 逐特性对照

"主机"一栏是 `zig test src/host_tests.zig` 的用例数（按模块），"板侧"是 `selftest.zig` 的判据数。

| 特性 | 条款 | 实现位置 | 主机 | 向量来源 | 板侧 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| MAC 帧格式与字段（Frame Control、Duration/ID、地址与 To DS / From DS、Sequence Control、QoS Control、FCS） | 9.2.3、9.2.4.1–9.2.4.8 | `wifi-mlme/src/frame.zig` | 13 | 抓包 `wpa-Induction.pcap` 的 8 帧（帧尾 FCS）；Annex J.9 的帧；按条款手工构造 | 含在 16 条内 | 离线验证通过 |
| 管理帧固定字段与构造 | 9.3.3.3–9.3.3.14 | `mgmt.zig` | 8 | 抓包的 Beacon / Probe / Authentication / Association / Disassociation；Annex J.9 | 同上 | 离线验证通过 |
| 信息元素（SSID、Supported Rates、DSSS、TIM、Country、RSNE、Extended Capabilities、MMIE） | 9.4.2.2–9.4.2.158 的子集 | `ie.zig` | 11 | `mesh.pcap` 的 Country 与 TIM；9.4.2.25.1 印出的 RSNE 样例；Annex J.9.1 的 MMIE | 同上 | 离线验证通过 |
| robust 管理帧判定 | 12.2.8、12.6.20、Table 9-47 | `robust.zig` | 4 | 表逐格 | 同上 | 离线验证通过 |
| MLME：认证、关联、重关联、去认证、去关联、状态机与定时器 | 11.3 | `mlme.zig` | 19 | 抓包第 78 帧等；进程内假 AP 对打 | 同上 | 离线验证通过 |
| 扫描（被动、主动、信道驻留）与 BSS 表 | 11.1.4 | `scan.zig` | 6 | 抓包第 58 帧的 Probe Request | 同上 | 离线验证通过 |
| PSK、PMKID、PTK、GTK 派生 | 12.7.1.2–12.7.1.4 | `wifi-connect/src/wpa2.zig` | 含在 57 内 | Annex J.3、J.4、J.7；RFC 6070 | 含在 28 条内 | 离线验证通过 |
| AES Key Wrap | RFC 3394 | `keywrap.zig` | 同上 | RFC 3394 §4.1 | 同上 | 离线验证通过 |
| 密钥数据封装（KDE、Key Data 包裹与解包） | 12.7.2 | `kde.zig` | 同上 | 标准库 HMAC 加独立脚本 | 同上 | 离线验证通过 |
| 4 次握手与组密钥握手（请求方） | 12.7.6、12.7.7 | `supplicant.zig` | 同上 | 进程内假认证方对打，六帧逐字节等于独立脚本结果 | 同上 | 离线验证通过 |
| 安全关联与 12.7.10 状态机、RSNA 选择 | 12.6.1.1、12.6.2、12.6.3、12.7.10 | `supplicant.zig`、`rsne.zig` | 同上 | 9.4.2.25.1 样例、Table 12-2 | 同上 | 离线验证通过 |
| CCMP-128 | 12.5.3 | `ccmp.zig` | 同上 | Annex J.6.4、J.7、J.9.2 | 同上 | 离线验证通过 |
| GCMP-128 | 12.5.5 | `ccmp.zig` | 同上 | Annex J.11 #1、#2 | 同上 | 离线验证通过 |
| BIP-CMAC-128 与 MMIE | 12.5.4、9.4.2.55 | `bip.zig` | 同上 | Annex J.8、J.9.1 | 同上 | 离线验证通过 |
| 管理帧保护与 SA Query | 12.2.8、12.6.19、12.6.20、11.14、9.6.10 | `mfp.zig` | 同上 | 规则与 Table 9-47 | 同上 | 离线验证通过 |
| SAE 完整实现 | 12.4；Annex J.10 | — | — | — | — | 未做（现有：字节层子集） |
| FT 密钥层次 | 12.7.1.7、13.4 | — | — | — | — | 未做 |
| CCMP-256、GCMP-256、BIP-256 | 12.5 | — | — | — | — | 未做 |
| 真实 MAC：`esp_wifi_start`、扫描、连接 | 不适用 | — | — | — | — | 阻塞：`MAC_ST[15:13]` |

负面用例（主机）：截断、越界、不一致的输入逐个被拒；MIC 错、重放或重复计数、顺序错、解包失败、RSNE 被改、PN 重放、错 IGTK、SA Query 事务标识不符。

## 3. 主机测试

### 3.1 `wifi-mlme`

```sh
cd components/wifi-mlme && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 61 tests passed.
```

模块分布：`frame` 13、`ie` 11、`mgmt` 8、`robust` 4、`mlme` 19、`scan` 6。`zig fmt --check src/` 干净。

### 3.2 `wifi-connect`

```sh
cd components/wifi-connect && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 57 tests passed.
```

原有 20 项里 18 项原样保留。另 2 项（`four-way happy path reaches done`、`four-way rejects wrong order, stale replay and bad key info`）测的是一个只管顺序的替身 `wpa2.FourWay`，已删除，由用真实帧的四篇请求方测试取代。随之变化的行为：替身要求消息 3 的计数恰好等于上一条加一，而 12.7.6.4 只要求"没用过"，所以"计数跳号即拒绝"不再成立。

## 4. 与独立参照实现的差分

参照实现：`/tmp/s31-oracle/wifi_oracle.py`（Python，AES 取自 OpenSSL，不引用仓库代码；自检 223 PASS、1 KNOWN）。一次性测试各取随机向量与 Zig 实现比较，跑完删除。

| 构造 | 条数 | 结果 |
| --- | --- | --- |
| psk、prf、pmkid | 120 + 120 + 120 | 全部一致 |
| ptk | 37 | 全部一致 |
| gtk | 51 | 全部一致 |
| key_wrap、key_unwrap | 48 + 96 | 全部一致 |
| ccmp_encapsulate、ccmp_decapsulate | 43 + 98 | 全部一致 |
| gcmp_encapsulate、gcmp_decapsulate | 41 + 96 | 全部一致 |
| bip_protect、bip_verify | 20 + 60 | 全部一致 |

差分没有覆盖的点：非 QoS 数据帧与管理帧的 Order 位。按 12.5.3.3.3 a) 6) ii) 这些帧的 Order 位不清零，参照实现清了，相关向量已剔除，以规范原文为准。

## 5. 主代理独立复核

- 按 `scripts/check-fmt.sh`、`check-host.sh`、`check-coverage.py`、`check-invariants.py` 跑仓库门禁，全绿。
- 通读 `ccmp.zig` 的 AAD 与 nonce 构造，逐项对照 12.5.3.3.3 与 12.5.3.3.4 的原文：数据帧只清子类型的 B4–B6；Retry、电源管理、更多数据清零；受保护位置 1；带 QoS Control 的数据帧才清 Order 位；Sequence Control 只清序列号；QoS Control 只留 TID，A-MSDU Present 仅在 SPP 时进入 AAD；AAD 长度 22/24/28/30；nonce 的 PN0 在八位组 12。一致。
- `frame.zig` 的 FCS：由 p.636、p.665、p.2292 三处推出反射式 CRC-32，并用标准给出的接收端余数 0xC704DD7B 自检。
- 两个自检以 `riscv32-freestanding-eabihf`、`generic_rv32+m+a+c+f+zicsr+zifencei`、`ReleaseSmall` 编译通过；用桩 `board` 模块在主机上执行 `selftest.run()`，16/16 与 28/28。

## 6. 实现偏离

- 解封装输出把 Protected Frame 位清零；封装时置 1。封装和拒绝 PN = 0 与空帧体。
- 字段检查比标准严：Key Descriptor Version 必须等于 AKM 对应值，Key Length 必须是 16，Key Data 必须加密，协商了管理帧保护时消息 3 必须带 IGTK。
- 消息 1 的 PMKID 不符时丢弃（实现选择）；消息 3 与组密钥消息 1 先判重放再判顺序。
- `wifi-connect` 自带一个最小 robust 帧分类器，与 `wifi-mlme` 的并存（组件之间不互相导入）。
- Annex J.11 #1 的 AAD 里 Protected Frame 位是 0，与 12.5.3.3.3 a) 5) 不一致，该向量只用来对拍 GCM 核心。
- BSS 表刷新以新帧为准，新帧没带的 TIM 与 Country 沿用旧值。Country 的最大发送功率按 9.4.2.9 存为有符号数。
- 帧解析有 `none` / `present` / `checked` 三种 FCS 模式；Annex J 的帧不含 FCS。

## 7. 未验证

- 真实 AP 互通；消息 3 与组密钥消息 1 的字段宽松度只能靠实网确认。
- CCMP 与 GCMP 在 QoS 加四地址帧上的 30 字节 AAD 只有构造测试，没有官方向量。
- 现代真实 AP 的 Beacon（厂商特定元素、AID 高位）只在 2004 年的抓包里见过。
