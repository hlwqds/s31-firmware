# wifi-mlme — 非 AP STA 侧的 MAC 帧格式、管理帧、信息元素、MLME 与扫描

IEEE Std 802.11-2016 Clause 9 / 11.1.4 / 11.3 / 12.2.7 / 12.2.8 / 12.6.19 / 12.6.20 的纯逻辑实现。
不做密钥与加解密（归 `wifi-connect`）、不做 SAE 报文内容、不做 AP 行为、PHY、QoS 流量行为与省电。
主机测试 **61 项**，板侧自检 **16 条判据**（2026-11-24 随 `wifi` profile 上板一次，16/16；见「验证状态」）。

## 范围与来源

- 标准：IEEE Std 802.11-2016 全文（本地抽取 `/tmp/80211-extracts/`，页码为印刷页码）。
  代码注释、测试名里的 `p.N` 都出自本回合逐页读过的文本。逐模块：
  - `frame.zig`：9.2.1–9.2.2（p.636–637）、9.2.3（p.637）、9.2.4.1（p.638–644，Table 9-1 p.639–640、
    Table 9-2 p.640–641）、9.2.4.2（p.644，Table 9-5 p.645）、9.2.4.3（p.645–646，Table 9-3/9-4 p.641–642）、
    9.2.4.4（p.646–647）、9.2.4.5（p.647–653，Table 9-6/9-8/9-9）、9.2.4.6.1（p.654）、9.2.4.8（p.665）、
    9.3.1.1–9.3.1.7（p.669–672）、9.3.3.2（p.692–694，Figure 9-58）、9.3.3.14（p.715）、9.4.1.11（p.736）、
    17.3.5.5（p.2292，PSDU 比特顺序）、MIB `dot11RTSThreshold` / `dot11ShortRetryLimit` / `dot11LongRetryLimit`（p.3086–3087）。
  - `ie.zig`：9.4.2.1（p.784，Table 9-77 p.784–790）、9.4.2.2（p.790）、9.4.2.3（p.790–791，Table 9-78）、
    9.4.2.4（p.792）、9.4.2.6（p.792–794）、9.4.2.9（p.795–797）、9.4.2.13（p.799–800）、
    9.4.2.25（p.882–890，Table 9-131/9-133/9-134）、9.4.2.27（p.890–896，Table 9-135）、9.4.2.55（p.941）。
  - `mgmt.zig`：9.3.3.2–9.3.3.14（p.692–716，Table 9-27…9-38）、9.4.1.1–9.4.1.11（p.723–738，
    Table 9-45 p.728–731、Table 9-46 p.732–736）。
  - `robust.zig`：12.2.7（p.1927）、12.2.8（p.1927）、12.6.19（p.2002–2003）、12.6.20（p.2003）、
    Table 9-47（p.736–737，本回合单独重新抽取核对）、Table 9-306（p.1173）、Table 9-331（p.1210）。
  - `mlme.zig`：11.3.1–11.3.5（p.1642–1657）、12.3.3.1–12.3.3.2（p.1931）、10.3.4.4（p.1328）、
    10.3.2.11.2（p.1319）、MIB `dot11AssociationResponseTimeout`（p.2785–2786）、6.3.3.2（p.265–266）、
    6.3.5.2–6.3.5.3（p.279–281）、6.3.7.2–6.3.7.3（p.286–289）、6.3.8.3（p.299）。
  - `scan.zig`：11.1.4.1–11.1.4.3（p.1589–1595）、6.3.3.2（p.265–266）。
- 向量：Annex J.9.1 / J.9.2（p.3426–3428）、9.4.2.25.1 NOTE 的五个 RSNE 样例（p.883–884）、
  Wireshark wiki SampleCaptures 的 `wpa-Induction.pcap`（带帧尾 FCS；1093 帧中 724 帧的末 4 字节等于前文的
  CRC-32，用 CPython `zlib.crc32` 核对）与 `mesh.pcap`（Country / TIM 元素），以及按条款手工构造的向量。
  每个向量的出处写在 `src/vectors.zig` 里。

## 验证状态

- L3 板侧：2026-11-24 随 `wifi` profile 第一次上板，自检 16/16。日志 `logs/wifi-selftest-prefix-boot.log`。
- L1 主机：2026-11-24，61 项（`frame` 13、`ie` 11、`mgmt` 8、`robust` 4、`mlme` 19、`scan` 6），全部通过；
  `zig fmt --check src/` 干净。
- 接入：`firmware/build.zig` 的 `wifi` 组已挂上本组件的 `selftest.zig`，`wifi` 与 `full` 两个 profile 带它。
  上板之前，自检先在主机上以 `board` 桩模块（`log.line` → `std.debug.print`）编译并运行过，
  16 条判据 `passed=16 failed=0`。
- 差分对拍（`/tmp/s31-oracle/wifi_oracle.py`，一次性测试，跑完已删）：
  `bip_protect` 40 条（4 种 BIP × Key ID 4/5 × 随机 IPN）的 MME 经 `ie.parseMmie` 解出的 Key ID / IPN / MIC 全部相等；
  `ccmp_encapsulate` 40 条随机管理帧 / 数据帧（含 3 条四地址、12 条 QoS、15 条 HT Control）的 AAD 长度与 QoS TID
  与 `frame.parse` 的帧头布局全部相等。本组件没有密码学构造（FCS 是 CRC），所以没有密码学向量的差分。
- 空口：未做。

## 快速开始

```sh
cd components/wifi-mlme
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG test src/host_tests.zig      # 61 项
env -u LD_LIBRARY_PATH $ZIG fmt --check src/
```

`zig test` 在 0.17.1 没有 `--summary` 选项（报 `unrecognized parameter`），所以不带它。

## 文件职责

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `src/frame.zig` | 759 | Frame Control 编解码、Duration/ID、Sequence Control、QoS Control、帧头布局与 `parse` / `seal`、FCS（查表 + 逐位参考实现）、Action 帧头 |
| `src/ie.zig` | 781 | 元素遍历器；SSID / Rates / DSSS / TIM / Country / RSNE / Extended Capabilities / MME 解码；SSID / Rates / Ext Rates / RSNE 构造 |
| `src/mgmt.zig` | 615 | Capability、Status / Reason Code 名字表、各管理帧固定字段解码、STA 侧帧体构造（含进程内对端用的 Beacon / Association Response） |
| `src/robust.zig` | 179 | robust 管理帧判定（Table 9-47 逐行）、Protected Frame 位置位条件、12.6.20 的两条选择规则 |
| `src/mlme.zig` | 1069 | State 1–4、Class 1/2/3 过滤、认证 / 关联 / 重关联 / 解除认证 / 去关联流程、重传与 SRC/LRC、指示队列 |
| `src/scan.zig` | 442 | 主动 / 被动扫描调度表、Probe Request 整帧、有界 BSS 表 |
| `src/vectors.zig` | 300 | 固定向量与出处 |
| `src/host_tests.zig` | 2234 | 全部测试 |
| `src/selftest.zig` | 755 | 板侧自检（16 条判据） |

公开接口（要点）：`frame.parse(buf, .none|.present|.checked)`、`frame.seal(hdr, body, with_fcs, out)`、
`frame.crc32` / `fcsOk`；`ie.Walker`、`ie.parseXxx`、`ie.buildXxx`；`mgmt.parseXxx` / `buildXxx`、
`mgmt.statusCodeName` / `reasonCodeName`；`robust.classify` / `categoryVerdict` / `protectedFrameShallBeSet` /
`negotiateMfp` / `useProtectedDual`；`mlme.Machine`（`authenticate` / `associate` / `reassociate` /
`deauthenticate` / `disassociate` / `setProtection` / `receive` / `tick` / `takeTx` / `txResult` / `poll`）、
`mlme.classifyFrame` / `filterByState`；`scan.plan` / `scan.buildProbeRequestMpdu` / `scan.BssTable.update`。

## 特性对照表

| feature | 规范条款 | 测试名 | 向量来源 | 状态 |
| --- | --- | --- | --- | --- |
| FCS 算法与线上字节序 | 9.2.4.8 p.665；9.2.2 p.636；17.3.5.5 p.2292 | `frame 9.2.4.8 p.665: fcs matches eight frames of wpa-Induction.pcap` | 抓包 8 帧的帧尾 FCS | 已测（主机） |
| 逐位参考实现与接收余数 0xC704DD7B | 9.2.4.8 p.665 | `frame 9.2.4.8 p.665: serial reference, table crc and the stated residue agree` | 原文余数多项式 | 已测（主机） |
| Annex J.9.1 / J.9.2 帧的 FCS | 9.2.4.8 | `frame 9.2.4.8: fcs of Annex J.9.1 and J.9.2 frames (zlib.crc32 cross value)` | Annex J.9 + zlib.crc32 | 已测（主机） |
| Type / Subtype 表、Control Frame Extension 布局 | 9.2.4.1.1–9.2.4.1.3，Table 9-1/9-2 | `frame 9.2.4.1.3 Table 9-1: ...`；`frame 9.2.4.1.1 Figure 9-3: ...` | Table 9-1 的二进制值 | 已测（主机） |
| 四种 To DS / From DS 组合的每个帧头字段 | 9.2.4.3 Table 9-3；9.2.4.4；9.2.4.5 | `frame 9.2.4.3 Table 9-3: every header field for each To DS / From DS combination` | 手工构造（按 Figure 9-1） | 已测（主机） |
| Duration/ID、控制帧、Action 帧头 | 9.2.4.2 Table 9-5；9.3.1；9.3.3.14 | `frame 9.2.4.2 Table 9-5: ...`；`frame 9.3.1 p.670-672: ...`；`frame 9.3.3.14 / 9.4.1.11: ...` | 原文表格 + 手工构造 | 已测（主机） |
| Annex J.9.1 / J.9.2 帧解析 | J.9.1 / J.9.2 p.3426–3428 | `frame J.9.1 / J.9.2 p.3426-3428: deauthentication frames parsed` | Annex J.9 | 已测（主机） |
| 解析负例（截断、版本、FCS、Null 带帧体、未支持子类型） | 9.2.3；9.2.4.1.2；9.2.4.1.3 | `frame 9.2.3 / 9.2.4.1.2 / 9.3.1: parse rejections` | 手工构造 | 已测（主机） |
| 元素遍历器与 ID 255 扩展形式 | 9.4.2.1 p.784 | `ie 9.4.2.1 p.784: walker follows id, length and the id 255 extension form` | 手工构造 | 已测（主机） |
| SSID | 9.4.2.2 | `ie 9.4.2.2 p.790: ...` | 抓包 SSID | 已测（主机） |
| Supported / Extended Supported Rates、BSS Membership Selector | 9.4.2.3；9.4.2.13；Table 9-78 | `ie 9.4.2.3 / 9.4.2.13: ...` | 抓包 Rates | 已测（主机） |
| DSSS Parameter Set | 9.4.2.4 | `ie 9.4.2.4 p.792: ...` | 抓包信道号 | 已测（主机） |
| TIM（DTIM 字段、给定 AID 的位） | 9.4.2.6 | `ie 9.4.2.6 p.792-794: ...` | mesh.pcap TIM、抓包 TIM、手工位图 | 已测（主机） |
| Country（Subband / Operating Triplet、Padding） | 9.4.2.9 | `ie 9.4.2.9 p.795-797: ...` | mesh.pcap Country、手工 Operating Triplet | 已测（主机） |
| RSNE（全部固定字段与列表、MFPC/MFPR） | 9.4.2.25 | `ie 9.4.2.25 p.883-884: ...`；`ie 9.4.2.25: RSNE rejections` | 原文五个样例、抓包 RSNE | 已测（主机） |
| Extended Capabilities（选定比特） | 9.4.2.27 Table 9-135 | `ie 9.4.2.27 Table 9-135: ...` | 手工构造 | 已测（主机） |
| Management MIC element | 9.4.2.55 p.941 | `ie 9.4.2.55 p.941: ...` | Annex J.9.1 MME、oracle 差分 40 条 | 已测（主机） |
| STA 侧元素构造（SSID / Rates / Ext Rates / RSNE） | 9.4.2.2 / .3 / .13 / .25 | `ie builders: ssid, rates and RSNE reproduce the printed elements` | 原文样例、抓包元素 | 已测（主机） |
| Beacon / Probe Response / Probe Request 固定字段 | 9.3.3.3 / .11 / .10 | `mgmt 9.3.3.3 Table 9-27: ...`；`mgmt 9.3.3.10 / 9.3.3.11: ...` | 抓包 | 已测（主机） |
| Authentication 固定字段与 Table 9-36 一致性 | 9.3.3.12；Table 9-35/9-36 | `mgmt 9.3.3.12 Table 9-35/9-36: ...` | 抓包第 78 / 80 帧 | 已测（主机） |
| (Re)Association Request / Response、Disassociation | 9.3.3.5–.9 | `mgmt 9.3.3.6 / 9.3.3.7: ...`；`mgmt 9.3.3.8 / 9.3.3.9: ...`；`mgmt 9.3.3.5 / 9.3.3.13: ...` | 抓包第 82 / 84 / 1050 帧 | 已测（主机） |
| Status Code / Reason Code 名字 | 9.4.1.7 / 9.4.1.9，Table 9-45/9-46 | `mgmt 9.4.1.7 / 9.4.1.9: ...` | 原文表格 | 已测（主机） |
| 帧体构造（Probe Request、Open System、(Re)Association Request） | 9.3.3.10 / .12 / .6 / .8 | `mgmt builders: probe request, open system auth and association requests` | 抓包帧体；Table 9-29 顺序重排 | 已测（主机） |
| robust 判定与 Table 9-47 | 12.2.8；Table 9-47 | `robust 12.2.8 + Table 9-47 p.736-737: ...`；`robust 12.2.8 p.1927: ...` | 原文表格 | 已测（主机） |
| Protected Frame 位置位条件 | 12.2.7 | `robust 12.2.7 p.1927: ...` | Annex J.9.1 / J.9.2 | 已测（主机） |
| MFP 协商与 Protected Dual 选择 | 12.6.20 | `robust 12.6.20 p.2003: ...` | 原文两句 | 已测（主机） |
| 帧分类与状态过滤 | 11.3.1–11.3.3 | `mlme 11.3.3 p.1643-1646: ...` | 原文清单 | 已测（主机） |
| Open System 认证成功 / 拒绝 / 超时 | 11.3.4.2；12.3.3.2 | `mlme 11.3.4.2 p.1646: ...`；`mlme 11.3.4.2 p.1647: ...`；`mlme 11.3.4.2 c p.1647: ...` | 抓包第 78 帧（发出的整帧逐字节） | 已测（主机） |
| 关联成功（无 RSNA → State 4；有 RSNA → State 3） | 11.3.5.2 d, h | `mlme 11.3.5.2 p.1649: ...`；`mlme 11.3.5.2 d,h p.1650: ...` | Table 9-29 顺序帧、抓包第 84 帧 | 已测（主机） |
| 关联失败 / 超时 / State 1 被拒 | 11.3.5.2 a, f | `mlme 11.3.5.2 f p.1650: ...`（两条）；`mlme 11.3.5.2 a p.1649: ...` | 进程内对端 | 已测（主机） |
| 重关联（旧 AP 降到 State 2） | 11.3.5.4 | `mlme 11.3.5.4 p.1652-1654: ...` | 手工期望帧 | 已测（主机） |
| 解除认证 / 去关联（收与发） | 11.3.4.4 / .5；11.3.5.6 / .7 | `mlme 11.3.4.5 ...`；`mlme 11.3.5.7 ...`；`mlme 11.3.4.4 ...`；`mlme 11.3.5.6 ...` | 进程内对端、手工期望帧 | 已测（主机） |
| 重传限制（SRC / LRC、Retry 位、序号不变、FCS 重算） | 10.3.4.4；9.2.4.4.2 | `mlme 10.3.4.4 p.1328: ...` | MIB DEFVAL | 已测（主机） |
| 类违规响应、MFP 过滤、地址过滤、序号回绕、对端表上限 | 11.3.4.1 / 11.3.5.1；12.6.19；9.3.3.2；10.3.2.11.2 | `mlme 11.3.4.1 / 11.3.5.1 ...`；`mlme 12.6.19 ...`；`mlme 9.3.3.2 ...`；`mlme 10.3.2.11.2 ...` | 进程内对端 | 已测（主机） |
| 扫描调度表（主动 / 被动 / 拒绝） | 11.1.4.2 / 11.1.4.3；6.3.3.2 | `scan 11.1.4.3.2 ...`；`scan 11.1.4.2.1 ...`；`scan 6.3.3.2.2 ...` | 手工构造 | 已测（主机） |
| Probe Request 整帧 | 11.1.4.3.2 c | `scan 11.1.4.3.2 c p.1591: ...` | 抓包第 58 帧（含 FCS） | 已测（主机） |
| BSS 表（按 BSSID 去重、保留 TSF / 信道 / RSSI / RSNE 摘要） | 11.1.4.1 | `scan 11.1.4.1 p.1589: ...`；`scan: BSS table rejects ...` | 抓包 Beacon / Probe Response | 已测（主机） |

## 实现偏离

- **FCS 与缓冲区形态**：Annex J 与 oracle 的帧不含 FCS，网卡也常在校验后剥离，所以 `frame.parse` 有
  `none` / `present` / `checked` 三种模式；`seal` 默认写 FCS。线上字节序按 p.636 / p.665 / p.2292 三条推出来
  是「反射式 CRC-32 的小端序」，并被抓包 FCS 与 zlib 独立印证。
- **有界表**：RSNE 的 pairwise / AKM / PMKID 各至多 8 个；BSS 摘要各至多 4 个 suite；Country 至多 16 个 Triplet；
  Extended Capabilities 至多 10 字节（Table 9-77 把该元素标为 extensible，超长按 `TooLong` 拒绝，以后加位需放宽）；
  BSS 表 16 条；对端表 4 条。超限都返回具体错误。
- **计时器默认值**：`AuthenticateFailureTimeout`、`dot11AssociationResponseTimeout`、`ProbeDelay`、
  `MinChannelTime` / `MaxChannelTime` 在读过的原文里只有名字与单位、没有默认值，本实现取工程常数
  1024 TU、1024 TU、100 µs、20 TU / 38 TU。`dot11ShortRetryLimit = 7`、`dot11LongRetryLimit = 4`、
  `dot11RTSThreshold = 65536` 取自 MIB 的 DEFVAL。
- **ResultCode 映射**：Association Response 的 Status Code 在 6.3.7.3.2 的枚举里没有对应项时用 `refused_other`
  并保留原值；两个超时与「未关联到同一 ESS」原文只说发 confirm、没给 ResultCode，本实现加了
  `association_response_timeout`、`refused_not_associated`。`SUCCESS_POWER_SAVE_MODE`（85）按 9.4.1.9 视为成功。
- **认证帧的严格度**：Open System 按 Table 9-36 核对（seq 1 无后续字段且 Status 为 0；seq 2 仅在 Status 82 时
  带 Neighbor Report），厂商特定元素按 Table 9-35 末行放行。状态机只处理「在等的 AP 发来的 Open System seq 2」，
  其它认证帧一律 `ignored_unexpected`（含对端发来的 seq 1：非 AP STA 不做 11.3.4.3 的目的方流程）。
- **未实现的帧类型**：控制帧只解析 RTS / CTS / Ack / PS-Poll / CF-End / CF-End+CF-Ack；BlockAckReq、BlockAck、
  Control Wrapper、Control Frame Extension、Beamforming Report Poll、VHT NDP Announcement 返回 `UnsupportedSubtype`
  （布局没有逐条核对原文）。Extension 帧只解最小帧格式。11.3.3 清单外的帧归 `unclassified`：State 1/2 丢弃、
  State 3/4 放行。
- **BSS 表的刷新语义**：同一 BSSID 的新帧覆盖旧值，但新帧没带的 TIM（DTIM Period）与 Country 沿用旧值
  （Probe Response 没有 TIM）；元素出错或同一元素出现两次时整帧拒收、表不变。
- **重复检测**：没有 10.3.2.11 的重复缓存，靠「没有在等的流程」把迟到或重复的响应当成 `ignored_unexpected`。
- **MFP 过滤**：`discard_unprotected_robust` 是 SME 按 12.6.19 置位的开关，12.6.19 里依赖对端 MFPC 的条件没有建模。
- **Duration/ID**：单播管理帧的 Duration 取调用方给的 `unicast_duration`（默认 0），没有按速率算 Ack 时间 + SIFS。
- **Table 9-47 的 21**：原文同时有「21 VHT No」与「21–125 Reserved」两行，本实现把 21（VHT）与 22–125 都判为
  not robust；17 与 128–255 的 Robust 列是「—」，也按 not robust。
- **名字表**：Status / Reason 名字从 PDF 抽取文本转录，被断行的名字已拼接；37 / 38 各有多个名字取第一个，
  Status 1 的两个别名取 `REFUSED_REASON_UNSPECIFIED`。

## 待验证项

- 板侧：已接入 `firmware/build.zig` 并于 2026-11-24 上板一次，`checks: passed=16 failed=0 total=16`。
- 空口：真实 AP 的 Beacon / Probe Response / Authentication / Association（厂商特定元素、顺序不按 ID 升列、
  AID 高 5 位置 1 等已经只在一份 2004 年的抓包里见过）；SA Query / 各类 Action 帧；组地址 Deauthentication。
- FCS 的比特顺序依据只核对了 Clause 17（OFDM）的 17.3.5.5；DSSS / HR-DSSS / HT 的 PSDU 比特顺序条款没有抽取。
- 手工构造、没有独立出处的向量：非零 TIM 位图、Operating Triplet、负的最大发送功率、Extended Capabilities
  的位号（B19 / B22 等）、四地址 / QoS / HT Control 帧头、重关联整帧、STA 发出的解除认证 / 去关联帧。
- 扫描参数的默认值（ProbeDelay 100 µs、Min 20 TU、Max 38 TU）与 `stayPastMinChannelTime` 需要真实驱动配合；
  PHY-RXSTART / PHY-CCA 原语被简化成调度表里的两步。
