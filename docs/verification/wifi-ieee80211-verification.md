# Wi-Fi 验证报告（IEEE Std 802.11-2016）

- 规范依据：IEEE Std 802.11-2016（条款号取自该版目录与各模块文件头，页码为印刷页码）；其上的 RFC：RFC 3394（AES Key Wrap）、RFC 4493（AES-CMAC）、RFC 6070（PBKDF2）、RFC 4231（HMAC 的测试向量）、RFC 2104（HMAC）。第三批另涉 RFC 8110（OWE）、RFC 5869（HKDF）、RFC 5903 与 RFC 6090（ECC 的 Diffie-Hellman）、RFC 5216 与 RFC 3748（EAP-TLS 与 EAP）、RFC 2409 与 RFC 3526（MODP 群参数）。
- 组件：`components/wifi-mlme`、`components/wifi-connect`。
- 验证分级见 `docs/REPO-STANDARDS.md` §4。本报告只写实际跑过的命令和输出里出现过的结果。
- **真实 AP 与空口没有任何证据**：`esp_wifi_start` 仍卡在 `MAC_ST[15:13]`。下表的"通过"指离线验证通过。
- 本文把 2026-11-24 加入的 SAE 完整实现、FT 密钥派生层、256 位套件、QoS 与省电称为"第二批"；之前的部分称为"第一批"。
  第二批的板侧自检先在主机上用桩 `board` 模块跑过，随后于同日随 `wifi` profile 上板（§5.2）。
- 本文把 2026-11-25 加入的 OWE、EAP-TLS、按 AKM 的 4 次握手、SAE 其它群、FT 协议、无线测量（radio measurement）与 WNM 称为"第三批"。第三批新增六个板侧子自检，在主机上的读数与复核见 §5.4，上板结果见 §5.5。

## 1. 结论

三种计数分开写：主机用例数是 `zig test` 报的 total；板侧 checks 数是 `selftest.run()` 的判据数；差分向量数是参照实现生成的条数。

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| `wifi-mlme` 主机测试 | L1 | 146/146（第一批 61，第二批 82） | §3.1 |
| `wifi-connect` 主机测试 | L1 | 386/386（第一批 57，第二批 141；含 8 条在主机上执行板侧子自检的用例） | §3.2 |
| 与独立参照实现的差分（第一批） | L1 | 13 组 950 条全部一致 | §4.1 |
| suite-256 全量差分（第二批） | L1 | 14 组 3568 条向量、3928 项比较，0 不一致 | §4.2 |
| 与独立参照实现的差分（第三批） | L1 | 七个特性各自对拍，全部 0 不一致 | §4.4 |
| RV32 目标编译 | L2 | 两个自检都能以固件参数编译（第二批的 24 / 87 条）；第三批之后两个组件的整份自检（37 / 177 条）同样通过 | §5.1、§5.4 |
| 板侧自检在主机上的运行（桩 `board`） | L1 | `wifi_mlme` 24/24、`wifi_connect` 87/87；第三批之后 37/37、177/177 | §5.1、§5.4 |
| 板侧自检（第一批上板） | L3 | `wifi_mlme` 16/16、`wifi_connect` 28/28 | `logs/wifi-selftest-prefix-boot.log` |
| 板侧自检（第二批） | L3 | `wifi_mlme` 24/24、`wifi_connect` 87/87 | `logs/e2e-wifi-boot.log`；§5.2 |
| 整体判决为 pass 的板级运行 | L3 | 有：14/14 段、`main: verdict=pass`（第一批复验一次、第二批之后一次；后一次覆盖了前一次的同名日志） | `logs/e2e-wifi-boot.log`、`docs/verification/README.md` |

## 2. 逐特性对照

"主机"一栏是 `zig test src/host_tests.zig` 的用例数（按模块），"板侧"是 `selftest.zig` 的判据数。第一批各行的板侧数字含在当时的 16 / 28 条里；第二批各行的判据含在 24 / 87 条里（主机桩跑与上板都是这两个数），逐特性的板侧划分没有单独统计。第三批各行的板侧一栏是该特性子自检自己的判据数，含在两个组件的 37 / 177 条里。

| 特性 | 条款 | 实现位置 | 主机 | 向量来源 | 板侧 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| MAC 帧格式与字段（Frame Control、Duration/ID、地址与 To DS / From DS、Sequence Control、QoS Control、FCS） | 9.2.3、9.2.4.1–9.2.4.8 | `wifi-mlme/src/frame.zig` | 13 | 抓包 `wpa-Induction.pcap` 的 8 帧（帧尾 FCS）；Annex J.9 的帧；按条款手工构造 | 含在 24 条内 | 离线验证通过 |
| 管理帧固定字段与构造 | 9.3.3.3–9.3.3.14 | `mgmt.zig` | 8 | 抓包的 Beacon / Probe / Authentication / Association / Disassociation；Annex J.9 | 同上 | 离线验证通过 |
| 信息元素（SSID、Supported Rates、DSSS、TIM、Country、RSNE、Extended Capabilities、MMIE） | 9.4.2.2–9.4.2.158 的子集 | `ie.zig` | 11 | `mesh.pcap` 的 Country 与 TIM；9.4.2.25.1 印出的 RSNE 样例；Annex J.9.1 的 MMIE | 同上 | 离线验证通过 |
| robust 管理帧判定 | 12.2.8、12.6.20、Table 9-47 | `robust.zig` | 4 | 表逐格 | 同上 | 离线验证通过 |
| MLME：认证、关联、重关联、去认证、去关联、状态机与定时器 | 11.3 | `mlme.zig` | 19 | 抓包第 78 帧等；进程内假 AP 对打 | 同上 | 离线验证通过 |
| 扫描（被动、主动、信道驻留）与 BSS 表 | 11.1.4 | `scan.zig` | 6 | 抓包第 58 帧的 Probe Request | 同上 | 离线验证通过 |
| QoS：QoS Control 布局与编解码、UP / TID / AC、Ack Policy、Queue Size / TXOP / AP PS Buffer State、QoS Capability、EDCA Parameter Set、QoS 数据帧解析与封装 | 9.2.4.1.3、9.2.4.5.1–.16（Table 9-6、9-8、9-9）、Table 10-1、10.2.4.2、9.4.2.29（Table 9-136、9-137）、9.4.1.17 / 9.4.2.35（Table 9-48）、10.22.2.2 / .4 / .8、10.12 | `wifi-mlme/src/qos.zig` | 10（`qos_tests.zig`） | Table 9-6 / 9-8 / 9-9 / 9-48 / 9-137 逐格；hostapd 默认 WMM 参数；抓包 `http_PPI.cap`（TID 0）与 `wpa-eap-tls.pcap`（TID 7）；其余按条款手工构造 | 同上 | 离线验证通过 |
| 省电：PM / More Data、PS-Poll、TIM / Bitmap Offset、模式切换、DTIM 唤醒、U-APSD 服务期、进程内 AP 模型 | 9.2.4.1.7 / .8、9.3.1.5、11.2.1–11.2.3（Table 11-1）、9.4.2.6、6.3.2.2–.3、9.4.1.6 / .8 | `wifi-mlme/src/powersave.zig` | 9（`powersave_tests.zig`） | 原文规则；STA 与 AP 两个模型对拍，没有外部向量 | 同上 | 离线验证通过 |
| PSK、PMKID、PTK、GTK 派生 | 12.7.1.2–12.7.1.4 | `wifi-connect/src/wpa2.zig` | 含在 57 内 | Annex J.3、J.4、J.7；RFC 6070 | 含在 87 条内 | 离线验证通过 |
| AES Key Wrap | RFC 3394 | `keywrap.zig` | 同上 | RFC 3394 §4.1 | 同上 | 离线验证通过 |
| 密钥数据封装（KDE、Key Data 包裹与解包） | 12.7.2 | `kde.zig` | 同上 | 标准库 HMAC 加独立脚本 | 同上 | 离线验证通过 |
| 4 次握手与组密钥握手（请求方） | 12.7.6、12.7.7 | `supplicant.zig` | 同上 | 进程内假认证方对打，六帧逐字节等于独立脚本结果 | 同上 | 离线验证通过 |
| 安全关联与 12.7.10 状态机、RSNA 选择 | 12.6.1.1、12.6.2、12.6.3、12.7.10 | `supplicant.zig`、`rsne.zig` | 同上 | 9.4.2.25.1 样例、Table 12-2 | 同上 | 离线验证通过 |
| CCMP-128 | 12.5.3 | `ccmp.zig` | 同上 | Annex J.6.4、J.7、J.9.2 | 同上 | 离线验证通过 |
| GCMP-128 | 12.5.5 | `ccmp.zig` | 同上 | Annex J.11 #1、#2 | 同上 | 离线验证通过 |
| BIP-CMAC-128 与 MMIE | 12.5.4、9.4.2.55 | `bip.zig` | 同上 | Annex J.8、J.9.1 | 同上 | 离线验证通过 |
| 管理帧保护与 SA Query | 12.2.8、12.6.19、12.6.20、11.14、9.6.10 | `mfp.zig` | 同上 | 规则与 Table 9-47 | 同上 | 离线验证通过 |
| SAE 完整实现（group 19）：P-256 点运算、PWE 派生、Commit / Confirm、帧体、实例状态机、父进程与 Anti-Clogging | 12.4.4.2.2、12.4.5、12.4.6、12.4.7、12.4.8；表 9-36、9-46 | `wifi-connect/src/ecc.zig`、`sae.zig`、`sae_full.zig` | 31（`sae_full_tests.zig`） | Annex J.10（官方）；J.10 的输入走协议路径（非官方）；`sae_oracle.py vectors --seed 20261124` 的两组 KAT；`std.crypto.ecc.P256` | 同上 | 离线验证通过；未做项见 §6 |
| FT 密钥层次（派生层）：KDF、XXKey、PMK-R0 / R1 与名字、PTK / PTKName | 12.7.1.7、13.4.2；表 9-133 | `wifi-connect/src/ft.zig` | 24（`ft_tests.zig`） | RFC 4231 §4；`ft_oracle.py` 七组固定输入的交叉实现值（IEEE 没有 FT 向量） | 同上 | 离线验证通过；只做派生层 |
| CCMP-256、GCMP-256、BIP-CMAC-256 / BIP-GMAC-128 / BIP-GMAC-256、256 位 KEK、Key MIC、Key Descriptor Version | 12.5、12.7.2 b) 1) / h) / j)、12.7.3；表 12-4、12-8、9-131；9.4.2.25.3 | `ccmp.zig`、`bip.zig`、`keywrap.zig`、`rsne.zig`、`wifi-connect/src/suite256.zig` | 23（`suite256_tests.zig`） | Annex J.6.4（3423）、J.11 #3（3432）、J.9.1（3426–3428）；RFC 3394 §4；RFC 4231 §4；`suite256_oracle.py` 的样本。BIP-CMAC-256 没有官方向量 | 同上 | 离线验证通过；原文缺口见 §6 |
| OWE（RFC 8110）：群 19 的 ECDH、DH Parameter element、PMK / PMKID 派生、关联请求与响应的双端处理、PMK 与 PMKID 交给 4 次握手 | RFC 8110 §4.1–§4.4；RFC 5869 §2.2–2.3；RFC 5903 §3、§7、§8.1；RFC 6090 §4、附录 B / C；802.11-2016 12.6.3、表 9-46、9.4.2.1 | `wifi-connect/src/owe.zig` | 30（`owe_tests.zig`） | FIPS 180-2 的 SHA-256、RFC 5869 A.1–A.3、RFC 5903 §8.1；`owe_oracle.py`（输入取 RFC 5903 §8.1，期望值来自 oracle 并与盘上 hostap 的代码一致）。RFC 8110 自身没有样例数值 | 18（`owe_selftest.zig`） | 离线验证通过；范围见 §6 |
| EAP（RFC 3748）与 EAP-TLS 分片（RFC 5216）：Code / Identifier / Length、Identity、Notification、Nak 与 Expanded Nak、Flags、分片与重组、Key Material 的切分、PMK 的取法 | RFC 3748 §2.1、§4、§5.1–5.3、§5.7；RFC 5216 §2.1.1、§2.1.3、§2.1.5、§2.3、§3.1–3.2；802.11-2016 12.7.1.3 | `wifi-connect/src/eap.zig`、`eap_tls.zig` | 34（`eap_tests.zig`） | 按条款手排的已知答案；`pmkFromMsk` 与 `splitKeyMaterial` 按 RFC 5216 §2.3；分片重组用随机记录流与切点，两端重组结果逐字节相同 | 8（`eap_selftest.zig`） | 离线验证通过；TLS 引擎由调用方注入 |
| 4 次握手与组密钥握手里随 AKM 变的一切：PMK 长度、PTK 的 PRF / KDF、KCK / KEK 长度、MIC 算法、Key Data 封装、Key Descriptor Version、PMKID 的来源、AKM 与密码套件能否合用 | 12.7.1.2、12.7.1.3、12.7.1.7、12.7.2、12.7.6.1、9.4.2.25.3；表 9-133、12-4、12-8 | `wifi-connect/src/akm.zig`（`supplicant.zig`、`wpa2.zig`、`rsne.zig`、`kde.zig` 按它取值） | 45（`supp_akm_tests.zig`） | `akm_oracle.py`（表行与 oracle 逐条比较）；盘上 hostapd 的 `wpa_auth` 代码 | 19（`supp_akm_selftest.zig`） | 离线验证通过；AKM 1–6、8、9、11–13、18 |
| SAE 的其它群（15 个：FFC 2、5、14–18，ECC 19–21、25、26、28–30）的域参数、hunting-and-pecking、对端 Commit 校验、群协商、Password Identifier 与 Rejected Groups 元素 | 12.4.4.1、12.4.4.2、12.4.4.3、12.4.5.2–12.4.5.5、12.4.7.2、12.4.8.6.3–.4；RFC 2409、RFC 3526（MODP 群参数）。两个元素不在 2016 正文里，依据盘上 hostap 的源码 | `wifi-connect/src/sae_groups.zig`、`bignum.zig`、`sae_full.zig` | 67（`sae_groups_tests.zig`） | hostap `dh_groups.c`、mbedTLS `ecp_curves.c`、`cryptography`；`sae_groups_oracle.py` | 33（`sae_groups_selftest.zig`） | 离线验证通过；没做的见 §6 |
| FT 协议：MDE / FTE / MIC element 的编解码、over-the-air 与 over-the-DS 的认证序列、reassociation、FTO / 目标 AP / R0KH 三方进程内对拍 | 13.5、13.7、13.8；9.4.2.47–9.4.2.50；9.6.9；9.3.3.8–.12；表 9-46、9-159；12.7.1.7 | `wifi-connect/src/ft_proto.zig` | 64（`ft_proto_tests.zig`） | `ft_proto_oracle.py`（IEEE 没有 FT 协议的样例帧）；`ft_vectors.zig` 的同名条目；RFC 4493 §4 | 12（`ft_proto_selftest.zig`） | 离线验证通过 |
| 无线测量：Measurement Request / Report 元素、Beacon request / report、Link Measurement、Neighbor Report 的请求与响应、RCPI / RSNI、TPC Report；量测 STA 的接受 / 回绝与由 BSS 表排出 Beacon report；AP 侧的 Neighbor Report 响应 | 11.11.4、11.11.6、11.11.7、11.11.9.1、11.11.10.3、11.11.13；9.4.2.17、.21、.22、.36、.37、.38、.41；9.6.7；9.4.3 | `wifi-mlme/src/rrm.zig` | 32（在 `rrm_wnm_tests.zig` 里） | 按图逐字节手排；hostap `ieee802_11_defs.h` 的结构体布局（`offsetof` / `sizeof`） | 6（`rrm_wnm_selftest.zig`） | 离线验证通过 |
| WNM：BSS Transition Management 的 Query / Request / Response、STA 侧的决定、AP 侧的请求与 Disassociation Timer；WNM Sleep Mode 的元素与两种帧、STA / AP 两侧的规程 | 11.24.7.1–.4；9.6.14.8–.10；表 9-176、9-357；11.2.3.18；9.4.2.79、9.4.2.82；9.6.14.19–.20；表 9-203、9-204 | `wifi-mlme/src/wnm.zig` | 30（在 `rrm_wnm_tests.zig` 里） | 按图逐字节手排；hostap `ieee802_11_defs.h` 的常量；hostap `wnm_sta.c` | 7（`rrm_wnm_selftest.zig`） | 离线验证通过 |
| 真实 MAC：`esp_wifi_start`、扫描、连接 | 不适用 | — | — | — | — | 阻塞：`MAC_ST[15:13]` |

负面用例（主机）：截断、越界、不一致的输入逐个被拒；MIC 错、重放或重复计数、顺序错、解包失败、RSNE 被改、PN 重放、错 IGTK、SA Query 事务标识不符。第二批追加：口令不同时 Confirm 校验失败并删除 PMK、非法的对端 Commit、回声 Commit、不支持的群、Anti-Clogging token 错、篡改 / 截断 / 标错套件的 256 位帧、KEK 长度不对。
第三批追加：OWE 的公钥不在曲线上、私钥越界、响应里有 OWE AKM 却没有 DH Parameter element；EAP-TLS 的 Flags 与长度字段不合法、重复的 Request、握手完成前收到的 EAP-Success；按 AKM 的握手里 PMK 长度不符、AKM 与密码套件不能合用、消息 1 的 PMKID 不符；SAE 其它群里的非法对端 Commit 与状态码 77 的群协商；FT 协议里 MIC 不对、重放、移动域 / R0KH-ID / ANonce / SNonce 不符、截止时间已过；无线测量与 WNM 里的保留值、Request mode 与可选字段对不上、Query / Response 里 Preference 为 0。每条都断言拒绝的理由是正确的那一个（状态码、丢弃原因或错误名）。

## 3. 主机测试

### 3.1 `wifi-mlme`

```sh
cd components/wifi-mlme && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 146 tests passed.
```

模块分布（2026-11-25）：`host_tests.zig` 64（自身 61：`frame` 13、`ie` 11、`mgmt` 8、`robust` 4、`mlme` 19、`scan` 6；
另有引 `qos_tests.zig`、`powersave_tests.zig`、`rrm_wnm_tests.zig` 的 3 个 wrapper `test` 块）
+ `qos_tests.zig` 10 + `powersave_tests.zig` 9 + `rrm_wnm_tests.zig` 63 = 146。`rrm_wnm_tests.zig` 的 63 条里有一条在主机上执行
`rrm_wnm_selftest.run`（13 条判据），断言零失败且最长一行不超过 200 字节。`zig fmt --check src/` 干净。

### 3.2 `wifi-connect`

```sh
cd components/wifi-connect && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 386 tests passed.
```

模块分布（2026-11-25）：`host_tests.zig` 68（自身 57；引第二批三个测试文件的 3 个 wrapper `test` 块；引第三批五个测试文件的
5 个 wrapper `test` 块；另有 3 条在主机上执行板侧子自检的用例）+ `sae_full_tests.zig` 31 + `ft_tests.zig` 24 + `suite256_tests.zig` 23
+ `owe_tests.zig` 30 + `eap_tests.zig` 34 + `supp_akm_tests.zig` 45 + `sae_groups_tests.zig` 67 + `ft_proto_tests.zig` 64 = 386。
第二批的三条子自检用例分别跑 `sae_full_selftest.run`（24 条判据）、`suite256_selftest.run`（22 条）、`ft_selftest.run`（13 条）；
第三批的五个测试文件各带一条，跑 `owe_selftest.run`（18 条）、`eap_selftest.run`（8 条）、`supp_akm_selftest.run`（19 条）、
`sae_groups_selftest.run`（33 条）、`ft_proto_selftest.run`（12 条）。八条都断言零失败且最长一行不超过 `board.log` 的 200 字节上限。
`zig fmt --check src/` 干净。

原有 20 项里 18 项原样保留。另 2 项（`four-way happy path reaches done`、`four-way rejects wrong order, stale replay and bad key info`）测的是一个只管顺序的替身 `wpa2.FourWay`，已删除，由用真实帧的四篇请求方测试取代。随之变化的行为：替身要求消息 3 的计数恰好等于上一条加一，而 12.7.6.4 只要求"没用过"，所以"计数跳号即拒绝"不再成立。

## 4. 与独立参照实现的差分

参照实现在 `/tmp/s31-oracle/`（Python，不引用仓库代码）。它们只存在于 `/tmp`，不在仓库里。自检结果，第一批与第二批（2026-11-24）：
`wifi_oracle.py selftest` 223 PASS、1 KNOWN；`suite256_oracle.py selftest` 253/253；`ft_oracle.py selftest` 51 pass、2 known；
`sae_oracle.py selftest` 的 P-256 与 `cryptography` 在 10 个点上一致。
第三批（2026-11-25）：`owe_oracle.py selftest` 44 项 0 失败；`akm_oracle.py selftest` 1065/1065；`sae_groups_oracle.py selftest` 160 PASS；
`ft_proto_oracle.py selftest` 45 项 0 失败；`rrm_wnm_oracle.py` 与 `rrm_wnm_oracle_wnm.py` 开头的自检分别核对 36 项布局事实与
67 项布局 / 常量事实，0 不一致；`eap_oracle.py` 在每次对拍前自检，不报错。

### 4.1 第一批（`wifi_oracle.py`）

一次性测试各取随机向量与 Zig 实现比较，跑完删除。

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

### 4.2 suite-256 全量差分（第二批）

向量由 `suite256_oracle.py vectors --seed 256 --count 40` 生成（`/tmp/s31-oracle/suite256_vectors_full.zig`），
一次性驱动是 `/tmp/s31-oracle/s256diff/diff.zig`，仓库里没有留存。

```sh
cd /tmp/s31-oracle/s256diff && env -u LD_LIBRARY_PATH zig test diff.zig
# diff suite256: TOTAL pass=3928 fail=0 ... All 1 tests passed.
```

2026-11-24 复跑的结果。vectors 是向量条数，pass 是比较项数（一条向量可以比多个字段）。

| 组 | vectors | pass | fail |
| --- | --- | --- | --- |
| ccmp256_encapsulate | 40 | 80 | 0 |
| ccmp256_decapsulate | 240 | 320 | 0 |
| gcmp256_encapsulate | 40 | 80 | 0 |
| gcmp256_decapsulate | 240 | 320 | 0 |
| bip_protect | 120 | 240 | 0 |
| bip_verify | 720 | 720 | 0 |
| key_wrap256 | 40 | 40 | 0 |
| key_unwrap256 | 237 | 237 | 0 |
| keydata_wrap | 40 | 40 | 0 |
| keydata_unwrap | 240 | 240 | 0 |
| eapol_mic | 160 | 160 | 0 |
| eapol_verify | 640 | 640 | 0 |
| kdv | 720 | 720 | 0 |
| akm_cipher_allowed | 91 | 91 | 0 |
| 合计（14 组） | 3568 | 3928 | 0 |

### 4.3 SAE 与 FT 向量的出处

两份都没有"跑一遍比全部随机向量"的差分，用的是固定向量；出处分三类，**只有第一类是官方的**。

| 类别 | SAE | FT | 出处 |
| --- | --- | --- | --- |
| 官方 | Annex J.10（3429–3430）里本实现能命中的各行：pwd-seed、commit-scalar / element、k、keyseed、两个 confirm | KDF 的 HMAC：RFC 4231 §4 用例 1–7 | 标准原文 |
| J.10 的输入走正文路径（非官方） | `sae_full_vectors.zig` 的 `j10_path_*`：同一组 J.10 输入按 12.7.1.7.2 的小端 16 位计数器算出的 pwd-value、PWE、KCK、PMK、PMKID、confirm；`ft_tests.zig` 的 J.10 用例证明"J.10 只有单八位组计数器才复现，16 位的 i 不行" | — | `sae_oracle.py j10 --kdf-counter 2` |
| 差分向量（非官方） | `kat_a`、`kat_b` 两组 KAT：固定输入与全部中间值（PWE、Commit、K、keyseed、KCK、PMK、PMKID、confirm、帧体） | 七组固定输入，覆盖四种 FT AKM 与两种 TK 长度；SSID 取 1 / 4 / 6 / 32 八位组，R0KH-ID 取 1 / 6 / 19 / 48 八位组 | `sae_oracle.py vectors --seed 20261124`；`ft_oracle.py` |

- **P-256 层**：`ecc.zig` 自己写的仿射点加、由 x 恢复 y、元素编解码，与 `std.crypto.ecc.P256` 在随机点上一致
  （`ecc: add, double, mul agree with std.crypto.ecc.P256 on random points`、`ecc: recoverY lands on the curve with the requested parity and agrees with std`）；
  基点的倍点与标准库自带的向量一致。`sae_oracle.py` 的 P-256 是纯 Python 的，与 `cryptography` 对过。
- **FT 没有官方向量**：Annex J（3395–3432）、12.7.1.7 与 13.4 的正文里都没有。期望值是按 12.7.1.7 原文独立写的
  `ft_oracle.py` 算出的交叉实现值，写它时没有参考本组件或 hostap。与官方材料的衔接只有两处：
  FT using PSK 的 XXKey 取 J.4.2 用例 1 的 PMK（`chain: the J.4.2 case 1 PSK is the XXKey for FT using PSK`），
  FT over SAE 的 MPMK 取本组件 SAE KAT 的 PMK（`chain: the SAE PMK is the MPMK for FT over SAE`）。

### 4.4 第三批的差分

七个特性各有一组与独立参照实现的对拍。下表的数字是 2026-11-25 主代理在集成后的代码上重跑得到的（§5.4）。参照实现都在 `/tmp/s31-oracle/`，一次性驱动不入库。

| 特性 | 参照实现 | 规模 | 结果 |
| --- | --- | --- | --- |
| OWE（RFC 8110） | `owe_oracle.py`（`cryptography` 的 ECDH 与 HKDF）；盘上 hostap 的 PMK / PMKID 代码（未经改动的 `sha256-kdf.c` 等） | 两个种子各 400 组，每个种子含 d = 1、d = n−1、C = A 五组边界 | Zig 对 oracle 与 hostap：`owe differential: vectors=800 checks=15200 mismatches=0`。oracle 对 hostap 的 PMKID、prk、PMK 各 800 组，0 不一致——这一项是该片的读数，主代理没有重跑 |
| EAP-TLS 分片与 PMK | `eap_oracle.py`（独立的分片器） | 1200 条记录流、910 种长度；4096 组 MSK | `eap differential: fragment cases=1200 mismatches=0 distinct_lengths=910`、`pmk cases=4096 mismatches=0` |
| 按 AKM 的 4 次握手 | `akm_oracle.py`；盘上 hostapd 的请求方与认证方代码（经 C 驱动调用） | 四个种子（20261124、1、2、3）各 2800 条命令、14 种 | 每个种子 `zig_mismatch=0 hostap_mismatch=0`；其中必须被拒绝的 104 / 96 / 93 / 104 条三方都拒绝 |
| SAE 其它群 | `sae_groups_oracle.py`（纯 Python 与 `cryptography`） | 15 个群 × 100 组整链，在 ReleaseFast 的驱动上跑 | `compare: cases=1500 mismatches=0 bad_lines=0 extra_lines=0`。比的是 counter、PWE、双方的 scalar 与 element、k、keyseed、KCK、PMK、PMKID、两条 confirm |
| FT 协议 | `ft_proto_oracle.py`（按 13.5 / 13.7 / 13.8 原文写，密钥层次取 `ft_oracle.py`） | 四个种子（1、2、3、20261125）各 2000 个场景，每个场景六个帧 | 每个种子 `scenarios=2000 frames_compared=12000 mismatches=0` |
| 无线测量 | hostap `ieee802_11_defs.h` 的结构体，用 C 编译器的 `offsetof` / `sizeof` 取真实布局 | 四个种子各 14000 帧：RRM 的六种（Measurement Request / Report 元素、Beacon request / report、Link Measurement 的请求与报告）各 2000，另有 2000 帧是不带候选表的 BTM Response | 每个种子 `cases=14000 … mismatches=0` |
| WNM 与 Neighbor Report 元素 | `rrm_wnm_oracle_wnm.py`：帧体按规范原图排，枚举值与位取 hostap 头文件 | 四个种子各 9000 帧，九种各 1000：Neighbor Report 元素、Neighbor Report 的请求与响应、BTM Request / Query / Response、WNM Sleep Mode 元素、Sleep Mode 的请求与响应 | 每个种子 `cases=9000 … mismatches=0` |

WNM 这一组是集成时补的。交付时的脚本（`rrm_wnm_oracle.py`）只对拍了不带候选表的 BTM Response 一种帧，归在上面那组的 14000 帧里；
其余八种帧体没有对拍。补的过程中找到 `wnm.parseSleepResponse` 的一个缺陷（§5.4）。

## 5. 主代理独立复核

- 按 `scripts/check-fmt.sh`、`check-host.sh`、`check-coverage.py`、`check-invariants.py` 跑仓库门禁，全绿。
- 通读 `ccmp.zig` 的 AAD 与 nonce 构造，逐项对照 12.5.3.3.3 与 12.5.3.3.4 的原文：数据帧只清子类型的 B4–B6；Retry、电源管理、更多数据清零；受保护位置 1；带 QoS Control 的数据帧才清 Order 位；Sequence Control 只清序列号；QoS Control 只留 TID，A-MSDU Present 仅在 SPP 时进入 AAD；AAD 长度 22/24/28/30；nonce 的 PN0 在八位组 12。一致。
- `frame.zig` 的 FCS：由 p.636、p.665、p.2292 三处推出反射式 CRC-32，并用标准给出的接收端余数 0xC704DD7B 自检。
- 两个自检以 `riscv32-freestanding-eabihf`、`generic_rv32+m+a+c+f+zicsr+zifencei`、`ReleaseSmall` 编译通过；用桩 `board` 模块在主机上执行 `selftest.run()`，16/16 与 28/28。

上面四条是第一批的复核，原文保留（16 与 28 是当时上板的判据数）。第二批（SAE / FT / 256 位套件 / QoS / 省电）见下面三节：
§5.1 主机复跑与目标编译，§5.2 板级运行，§5.3 独立复核。

### 5.1 第二批的主机复跑与目标编译（2026-11-24）

在主机上执行板侧自检（桩 `board` 模块）：

```sh
cd /home/huanglin/code/s31-firmware && R=/tmp/selftest-host
for c in wifi-mlme wifi-connect; do
  env -u LD_LIBRARY_PATH zig run --dep selftest -Mroot=$R/main.zig --dep board \
      -Mselftest=components/$c/src/selftest.zig -Mboard=$R/board_stub.zig
done
```

以固件参数编译。目标参数写在第一个 `-M` 之前，后面的模块沿用。根文件 `board_root_guard.zig` 引用 `run()`，并在编译期断言自己确实按 riscv32 / ReleaseSmall 在编；
`selftest_guard.zig` 把组件的自检再包一层，断言落在叶子模块上：

```sh
F="-target riscv32-freestanding-eabihf -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -OReleaseSmall"
for c in wifi-mlme wifi-connect ble-802154 ble-security radio-coex; do
  env -u LD_LIBRARY_PATH zig build-obj $F --dep selftest -Mroot=$R/board_root_guard.zig \
      $F --dep inner -Mselftest=$R/selftest_guard.zig \
      $F --dep board -Minner=components/$c/src/selftest.zig \
      $F -Mboard=boards/esp32s31-coreboard/src/board.zig -fno-emit-bin
done
```

五个组件全部退出 0。`/tmp/selftest-host/` 是一次性的脚手架，不入库。

**一次假绿的更正。** 这一步最初写成把 `-target … -mcpu … -OReleaseSmall` 放在最后一个 `-M` 之后。Zig 0.17.1 的命令行里
这类参数作用于其后声明的模块，写在最后没有任何模块用到：根、自检、`board` 三个模块都是本机 x86_64，命令退出 0，却什么都没证明
（带 `-femit-bin` 看产物，是 `ELF64 … Machine: Advanced Micro Devices X86-64`）。发现它的是上面这个守卫根文件——
按旧写法编译，它报 `guard: root module is not riscv32 (got x86_64)` 与 `guard: selftest module is not riscv32 (got x86_64)`；
`board` 模块同样如此（用一份在末尾追加守卫的 `board.zig` 临时副本测得，副本未入库）。
另一种写法也测过：把参数写成「每个 `-M` 之后」，根模块的守卫同样报 x86_64，因为参数从下一个模块才生效。
结论没有变：五个自检确实能以固件参数编译，`wifi` profile 的镜像构建（§5.2）与板上运行是另一份独立证据。

| 组件 | 桩 `board` 上运行 | 以固件参数交叉编译（带守卫） | 板子 |
| --- | --- | --- | --- |
| `wifi-mlme` | `checks: passed=24 failed=0 total=24`（第一批上板时 16） | 通过 | `wifi_mlme` 24/24（§5.2） |
| `wifi-connect` | `checks: passed=87 failed=0 total=87`（第一批上板时 28） | 通过 | `wifi_connect` 87/87（§5.2） |

### 5.2 第二批之后的板级运行（2026-11-24）

```bash
cd /home/huanglin/code/s31-firmware && . /tmp/idfenv.sh
BOARD=/dev/ttyUSB0 ESPTOOL="python -m esptool" python3 tests/e2e/run_e2e.py --board --profile wifi
```

harness 构建 `wifi` profile、经 `tools/flash.sh` 烧录（读回校验）、抓 30 s 串口并断言 → `PASS board:wifi`。
原始日志 `logs/e2e-wifi-boot.log`（它覆盖了第一批复验那一次的同名文件）。14 个 section 全部通过，聚合行
`firmware: sections: passed=14 failed=0 total=14`、`main: verdict=pass`：

| section | `wifi_mlme` | `wifi_connect` | `ble_802154` | `ble_security` | `radio_coex` | 其余 9 个 |
| --- | --- | --- | --- | --- | --- | --- |
| 判据 | 24/24（第一批 16） | 87/87（第一批 28） | 50/50（第一批 19） | 25/25 | 10/10 | 13、14、11、10、12、11、13、12、36，全部通过 |

### 5.3 主代理对第二批的独立复核

- suite-256 全量差分由主代理重跑（`cd /tmp/s31-oracle/s256diff && env -u LD_LIBRARY_PATH zig test diff.zig`），
  逐组数字见 §4.2，0 不一致。
- KDF 的字节序与形态对着原文和独立实现各核一遍（出处见 §6 第一条）：12.7.1.7.2（印刷页 2017）、9.2.2（636）、
  hostapd 的 `sha256_prf_bits()`。J.10 的两个 candidate x 用 Python `hmac` 分别按单八位组 counter 与小端 16 位 counter
  各算一遍：前者复现，后者不同。
- 12.4.5.4（印刷页 1943–1944）的 `keyseed = H(<0>32, k)`、
  `kck_and_pmk = KDF-Hash-512(keyseed, "SAE KCK and PMK", (commit-scalar + peer-commit-scalar) mod r)`、
  `PMKID = L((commit-scalar + peer-commit-scalar) mod r, 0, 128)` 与 `sae.zig` 的 `deriveKeys()` 逐式一致。

### 5.4 主代理对第三批的独立复核（2026-11-25）

- **逐片验收**：每片跑 `sh /tmp/r5c/accept.sh <组件> <特性>`，内容是 `zig test <特性>_tests.zig`、从输出里取板侧子自检在主机上的读数、
  以固件参数单独编译该子自检（`/tmp/r5c/target-check.sh`，rc=0）、`zig fmt --check`。各片的读数见 §2 的"主机"与"板侧"两栏。
  这两个脚本是一次性的，不入库。
- **整份自检在桩 `board` 模块上运行**（命令同 §5.1）：`wifi_mlme` `checks: passed=37 failed=0 total=37`、
  `wifi_connect` `checks: passed=177 failed=0 total=177`；最长的一行分别是 154 与 125 字节。
- **整份自检以固件参数交叉编译**（带守卫的根文件，命令同 §5.1）：两个组件都退出 0。
- **差分全部在集成后的代码上重跑**，数字见 §4.4；七份 oracle 的自检读数见 §4 开头。OWE 的差分目录是用符号链接引用组件源码的，
  并入按 AKM 的握手之后要先补上 `akm.zig`、`bignum.zig` 两个链接，否则编不过。
- **复核中发现并修掉的实现缺陷，三处**：
  1. `ft_proto.parseAuth` 先读 Authentication 帧体的 6 个八位组、后查长度。帧体来自空口：不足 6 个八位组时 Debug 构建越界 panic，
     ReleaseSmall（固件用的构建）则是越界读。改为先查长度；新增的用例喂 3 个八位组的帧体，断言目标 AP 以 `malformed` 丢弃、
     FTO 报 `Truncated`。同文件其余四个帧头解析函数本来就是先查后读。
  2. `ft_proto.ricProtected`：FTE 声明受保护的元素多于帧里实有的元素时，原先落到元素解析的 `Truncated`，与"被计数的元素自己残缺"
     分不开。改为 `BadElementCount`；元素本身残缺仍是 `Truncated`。wpa_supplicant 的 `wpa_ft_parse_ies`
     （`src/common/wpa_common.c:236–247`）在前一种情形同样报错。
  3. `wnm.parseSleepResponse` 把 WNM Sleep Mode 元素之后直到帧尾的字节都交给 `parseSleepElement`（它要求正好 4 个八位组），
     响应里只要带 TFS Response 元素（图 9-716 的字段）就报 `BadLength`。改为只取元素自己的 4 个八位组，用例补上带 TFS 的响应。
     这个缺陷是补 WNM 差分时找到的：原来的 63 条用例里没有一条在响应里带过非空的 TFS 元素。
- **两片由主代理在子代理中断后收尾**。FT 协议那片交付时只有 28 条单元层面的用例，板侧自检还是空壳：主代理补了向量对拍、拒绝路径、
  配置三组共 36 条用例和 12 条判据的板侧自检。无线测量与 WNM 那片交付时 63 条用例与 13 条判据已写完，但没有上面说的八种帧体的对拍、
  注释里的页码没改：主代理补了 oracle，并按「原文里 `=== PAGE N ===` 的 N 减 1」把 `rrm.zig`、`wnm.zig` 注释里 70 处页码引用
  核对了一遍，更正 24 处。
- **OWE 与 4 次握手的衔接改走 RFC 8110 表 2**。OWE 那片交付时，这条用例走的是请求方原先的 SHA-1 一族，只证明 PMK 能被握手消费。
  按 AKM 握手那片并入后，AKM 18 走 HMAC-SHA-256 的 MIC、KDF-SHA-256 的 PTK，启动时要带上 OWE 算出的 PMKID，消息 1 里的 PMKID
  可以不带、带了必须相等。用例与断言同步改过，多了一条"标识符不由握手计算"的反例。
- **Rejected Groups 元素**：SAE 其它群那片第一版没有做（任务书要求发这个元素，2016 正文里没有）。按 hostap 源码补了接收的一半之后，
  该片 59 → 67 条用例、31 → 33 条判据。
- **集成时对板侧内容做的调整（主机用例与差分都没有变）**：
  1. SAE 其它群的板侧自检收窄：双端对打只做 ECC 25，其余八个群只验群的参数，FFC 2 去掉要模指数的那条拒绝（判据仍是 33 条）。
     依据是主机 ReleaseFast 上的耗时：九个群全做对打时这份自检是 19–36 ms，是已在板上跑过的 `sae_full_selftest.zig`（12 ms）的
     两到三倍，而 `wifi` 镜像的全部 section 要在 e2e 的 30 秒抓取窗口里出判决；收窄之后是 2.4 ms。
  2. 自检入口与判据函数加 `noinline`：第三批的九份子自检入口、`wifi-connect` 里第一、二批的三份入口，以及 SAE 其它群自检里
     每条判据的函数。它们原先被内联进调用方，各自的定长大数组叠在同一个栈帧里：`wifi-connect` 的自检驱动函数栈帧 8144 字节，
     SAE 其它群的内联入口 8400 字节。只给第三批的九份入口加 `noinline` 时驱动函数还有 6144 字节（剩下的来自第一、二批的
     三份入口），最深的一条调用链反而比第三批之前深；三份入口一起加上之后驱动函数是 1120 字节，各判据的大数组落在各自的
     帧里（最大的是群 18 的 `pweOk`，8288 字节）。按保留符号的镜像静态估算，最深的一条调用链从 30384 降到 23248 字节
     （第三批之前的镜像是 26544）。方法、数字与估算时踩过的坑见 `docs/TESTING.md`「板侧自检的两条隐性预算」。
  3. 镜像体积：`wifi` 738848 → 1063200 字节，`full` 853632 → 1182480 字节，其余四个 profile 不变；factory 分区（1500K）的余量
     分别是 472800 与 353520 字节，`capacity.json` 基线已重写。`wifi` 镜像里函数代码的增量是 234412 字节，按源文件归因：
     `wifi-connect` +134912（`eap_selftest.zig` 32186；SAE 其它群四个文件 53490：`sae_groups.zig` 16880、它的自检 12728、
     `ecc.zig` 多 12510、`bignum.zig` 11372；`sae_full.zig` 多 14308；`ft_proto.zig` 11498）、标准库 +28930
     （几乎全是 `std/crypto/pcurves/common.zig` 的 27946：素域曲线的域运算，P-384 即 ECC 群 20 的实例化带进来的）、
     `ble-802154` +53332、`wifi-mlme` +17238。

## 6. 实现偏离

第一批：

- 解封装输出把 Protected Frame 位清零；封装时置 1。封装和拒绝 PN = 0 与空帧体。
- 字段检查比标准严：Key Descriptor Version 必须等于 AKM 对应值，Key Length 必须是 16，Key Data 必须加密，协商了管理帧保护时消息 3 必须带 IGTK。
- 消息 1 的 PMKID 不符时丢弃（实现选择）；消息 3 与组密钥消息 1 先判重放再判顺序。
- `wifi-connect` 自带一个最小 robust 帧分类器，与 `wifi-mlme` 的并存（组件之间不互相导入）。
- Annex J.11 #1 的 AAD 里 Protected Frame 位是 0，与 12.5.3.3.3 a) 5) 不一致，该向量只用来对拍 GCM 核心。
- BSS 表刷新以新帧为准，新帧没带的 TIM 与 Country 沿用旧值。Country 的最大发送功率按 9.4.2.9 存为有符号数。
- 帧解析有 `none` / `present` / `checked` 三种 FCS 模式；Annex J 的帧不含 FCS。

第二批：

- **Annex J.10 的 pwd-value 与 KCK/PMK 三行与 12.7.1.7.2 正文不符**（只有单八位组 counter 才复现）；实现与独立实现
  hostapd 都按正文走。J.10 印出的两个 candidate x（`a16729e0…`、`103a5b96…`）与 KCK、PMK 两行只有把 counter 编成一个
  八位组才复现；按 12.7.1.7.2（小端 16 位）算出的第一个 candidate x 是 `695552323edc8c6d…`，与 J.10 不同
  （Python 的 `hmac` 独立算出，输入取 J.10 印出的 pwd-seed）。J.10 的其余各行（pwd-seed、commit-scalar、commit-element、
  k、keyseed、两条 confirm）本实现都能命中。"J.10 的输入走正文路径"那组期望值不是官方的（§4.3）。
  - 字节序依据：12.7.1.7.2（2017）原文是「i and Length are encoded as 16-bit unsigned integers, represented using
    the bit ordering conventions of 9.2.2」；9.2.2（636）规定多八位组数值字段从最低位所在的八位组起发送，即小端。
    `sae.zig` 的 `kdfHash()`（counter 小端 16 位、从 1 起；Length 小端 16 位、单位是位）与正文一致。
  - 与 hostapd 逐字节同构：ESP-IDF 自带的 `wpa_supplicant/src/crypto/sha256-prf.c` 的 `sha256_prf_bits()`
    （`u16 counter = 1`、两个 16 位字段都 `WPA_PUT_LE16`、`HMAC-SHA256(K, counter ‖ Label ‖ data ‖ length)`），
    SAE 的 hunting and pecking 在 `src/common/sae.c:149` 调的就是它。
- **pwd-seed 的 counter**：12.4.4.2.2 的 counter 是单个八位组。实现原来按小端 16 位写，2026-11-24 改正并换了向量
  （期望值由 Python 的 HMAC 独立算出）。
- **SAE 的范围**：只支持 group 19。恒定时间、H2E、其它群、rejected-groups / password-identifier 元素、两个群之间的
  DiffGrp 同步没有做，逐条列在 `sae.zig` 的 `unimplemented` 表里；PWE 派生不是恒定时间的。随机数与发帧由调用方注入。
- **FT 只做派生层**：KDF、XXKey、PMK-R0 / R1 与名字、PTK / PTKName。FT 认证算法的帧交换、reassociation、
  R0KH→R1KH 的 PMK-R1 分发、MDE / FTE 编解码、EAPOL-Key 帧都没有做；期望值没有官方出处（§4.3）。
- **256 位套件的原文缺口**（`suite256.zig` 文件头同文，本实现不替标准补规定）：
  - 12.7.2 b) 1) iii) 只点名 AKM 3、4、5、6 用 Key Descriptor Version 3；表 12-8 给 AKM 8、9（SAE、FT over SAE）的
    是与版本 3 相同的算法组合，`descriptorVersion` 据此对 AKM 8、9 返回 3，依据是算法组合而不是原文的点名。
  - AKM 11、12、13 在表 12-8 里有算法，但 12.7.2 b) 1) 没有为它们定义 Key Descriptor Version；第二批返回 null，第三批起取 0（见下面第三批）。
  - 802.11-2016 的表 12-8 里 Key-wrap algorithm 只有 NIST AES Key Wrap，没有 AES-GCM 的封装。
  - HMAC-SHA-256 / 384 截到 MIC 长度时取哪几位，表 12-8 没有写；这里与 HMAC-SHA-1-128 条目（octets 0–15）同一读法，
    取摘要开头的字节。
  - BIP-CMAC-256 没有官方向量（J.9.1 只有 BIP-CMAC-128 与两种 BIP-GMAC），它的期望值只有差分样本。
  - `suite256.zig` 是原语层，不改 `wpa2.zig` / `supplicant.zig` 的 EAPOL-Key 编解码与 4 次握手。
- **QoS 的范围**：QoS Control 的布局只做 infrastructure BSS 的六行与 mesh BSS 的那一行；DMG 的 Table 9-7 不在范围。
  做的是字段、参数与元素的编解码，不做 EDCA 竞争、队列调度与聚合。
- **省电的范围**：只取非 DMG infrastructure BSS、没有 PCF 的部分。不做 CFP / PCF、IBSS / MBSS / DMG、S-APSD、FMS、
  TIM Broadcast、WNM sleep mode、VHT TXOP power save、PSMP、TDLS peer PSM，以及 11.2.3.6 的 i)–k)（重传上限、aging）。
  时间全部由调用方以 TU 注入；PS-Poll 之前的随机退避由驱动做。

第三批：

- **OWE（RFC 8110）的范围**：只做 group 19（§4.3 规定必须支持的那一个）和 SHA-256 档；§4.5 的 PMK caching、OWE Transition Mode、
  认证 / 关联状态机的接线都没做。DH Parameter element 按 RFC 8110 §4.3 的图 1 实现（Element ID 255、Element ID Extension 32；
  802.11-2016 的表 9-77 把扩展号 12–255 列为保留），公钥在线上只传 x 坐标（32 个八位组），传 64 个八位组的被拒。
  除 77（群不支持）以外的关联失败回状态码 1：RFC 8110 只规定了 77，1 与盘上 hostap 的 AP 侧代码一致（`ap/ieee802_11.c:856–859`）。
  x = 0 当作合法公钥（P-256 上 (0, ±√b) 满足曲线方程，RFC 6090 §3.3 的判据只有这一条）。
- **EAP-TLS 的范围**：TLS 引擎由调用方注入，仓库里是 EAP 层的分片 / 重组与状态（`eap_tls.zig`），不含 TLS 本身；
  TLS 1.3 的 keying material 导出也不在仓库里。PMK 取 MSK 的前 32 个八位组、MSK / EMSK 的切分按 RFC 5216 §2.3；
  AKM 00-0F-AC:12 需要的 384 位 PMK 没做。
  一次性端到端实验里（`/tmp/eap-e2e/`，不入库），仓库的 EAP 层对 Python `ssl` 服务端与 libssl 服务端各完成一次 TLS 1.3 握手，
  双方的 master secret 一致，peer 侧算出的 MSK 能被独立的 Python HKDF 复现。**没有验证的**：peer 的 MSK 与 OpenSSL 的
  `SSL_export_keying_material()` 输出逐字节一致——两者对不上，原因没有定位（在一次性适配器、ctypes 调用或 OpenSSL 3.6.4 的
  导出行为之间），仓库代码不涉及这一步。
- **按 AKM 的握手**，2016 原文自相矛盾的三处与取法（`akm.zig` 文件头同文；路径相对 ESP-IDF 自带的 `wpa_supplicant/src/`）：
  - AKM 8（SAE）的 PTK：表 9-133 给它的 Key derivation type 是「12.7.1.7.2 using SHA-256」，而 12.7.1.2 与 12.7.1.3 的替换清单
    只列了 5、6、11、12、13。以表 9-133 为准（KDF-SHA-256），hostap 同此（`common/wpa_common.c:1273–1275`）。
  - AKM 8 的 PMKID：12.7.1.3 的「Otherwise」会把它划进 HMAC-SHA-1 那一支，但 12.4.5.4 为 SAE 专门定义了 PMKID。取 12.4.5.4：
    握手用 SAE 阶段算好的那一个。
  - Key Descriptor Version：12.7.2 b) 1) 只点名 AKM 1、2 用 2，AKM 3、4、5、6 用 3，各消息的字段表写的是「其余情形为 0」。
    所以 AKM 11、12、13、18 取 0。AKM 8、9 按原文也是 0，但表 12-8 给它们的正是版本 3 的算法组合，先于这一读法部署的认证方
    发的是 3（`common/wpa_common.c:899–903`）：请求方两种都收，回应里用认证方用的那一个。这一条取代了第二批的取法
    （上面 256 位套件那一项）。
  - 消息 1 里的 PMKID KDE：标识符在握手一开始就有的 AKM（1、2、5、6、8、18）带了就必须相等；AKM 11、12 的 PMKID 以 KCK 为密钥、
    消息 1 到达时 PTK 还不存在，FT 的四种标识符是 PMKR1Name，在消息 2、3 的 RSNE 里核对——这六种不看也不拒消息 1 里的 KDE
    （hostap 的请求方同样不看它，`rsn_supp/wpa.c:395–520`）。本组件不做 PMKSA 缓存，所以没有「必须带」的行。
  - 不实现的行返回 `UnsupportedAkm`：7（TDLS）、10（AP PeerKey，表 12-8 没有这一行）、0 与 14 以上（保留）。
    AKM 18 只做 RFC 8110 的 SHA-256 档；RFC 8110 没有写 SHA-384、SHA-512 档的 PTK 派生，PMK 不是 32 个八位组时按长度不符拒绝。
- **SAE 其它群的范围**：15 个群。没做的与偏离逐条如下（`sae_groups.zig` 文件头同文）：
  - 不在 2016 正文里的三样。H2E 没做（全文里搜不到 hash-to-element / H2E 的字样）。Password Identifier 元素与 Rejected Groups
    元素同样不在 2016 正文里，按盘上 hostap 的源码实现，依据只有源码：
    - Password Identifier 元素，两端都做；
    - Rejected Groups 元素只做接收的一半。hostap 只在 H2E 下发送它（`common/sae.c:1669`），本组件不做 H2E，所以自己不发。
      收到后的处理与 hostap 相同：列表里只要有一个群是本端启用的就判失败（状态码 1），没有「按对方给出的集合重选群」的逻辑
      （盘上 hostap 也没有）。元素畸形时 hostapd 回状态码 1，本实现是解码失败、整帧丢弃。
    - 77 之后换群走 2016 的 12.4.8.6.4（DiffGrp），已实现。
  - 群清单的出处：2016 版的 12.4.4 没有群表，只规定「为互通起见 STA 应支持 group 19」；群号取自 IANA 的 IKE「Group Description」注册表，域参数取 RFC 2409 / RFC 3526（FFC）与 hostap `dh_groups.c`、mbedTLS `ecp_curves.c`（ECC），并与 `cryptography` 交叉核对。15 个群里只有 group 19 是 2016 要求必须支持的。
  - P-521 的 pwd-value 取法只依据 hostap（`crypto/sha256-prf.c:98–102`、`common/sae.c:152–153`），2016 没有给出不同的规定。
  - 没做的群：FFC 1、22（IANA 标为已弃用）；FFC 23、24（r 与 p 的八位组数不同，12.4.7.4 与 hostap 的写法对不上，线上格式无法核实）；
    ECC 27（盘上两份 mbedTLS 与 `cryptography` 都没有它的参数）；ECC 31–34 与 ML-KEM 35–37（不满足 12.4.4.2.1，或盘上没有参数来源）。
  - 恒定时间没做：`bignum.zig` 的模指数与 `ecc.zig` 的 `BigBackend` 标量乘的耗时随操作数的位变化。
  - 仓库里的整链向量：FFC 15–18 在仓库用例里只对 pwd-value、PWE 与小指数模指数，整链只在 ReleaseFast 的差分里对过
    （Debug 模式下一次 2048 位模指数约 3 秒）。期望值都不是官方向量；唯一的官方向量是 group 19 的 Annex J.10。
  - 板侧自检覆盖 15 个群各一条 PWE、ECC 25 的双端对打，其余八个群（ECC 19–21、26、28–30 与 FFC 2）只验群的参数
    （合法元素往返、改一个字节的元素被拒、标量加法模 r）。这八个群与 FFC 5、14–18 的双端对打、FFC 的运算律、
    FFC 子群外元素的拒绝、DiffGrp 双端同时发起、token 与 Password Identifier 同时出现，只在主机用例与差分里对。
- **FT 协议的范围**（`ft_proto.zig` 文件头同文）：
  - 13.8.4 / 13.8.5 只为 AKM 3、4、9 规定 FTE 的 MIC（AES-128-CMAC over KCK）；AKM 13 在编译期拒绝。
  - 13.5.2 的 over-the-air 段只列 AKM 3、4，13.5.3、表 9-31 的注 13、13.8.4 / .5 列的是 3、4、9。本实现两种走法都接受 9
    （与 13.5.2 的字面不同）。
  - FTE 子元素的顺序原文没有给，按图里出现的顺序写（R1KH-ID、R0KH-ID、GTK、IGTK）；同类元素或子元素出现两次即解析失败。
  - RIC（13.11）不做：RIC-Request / RIC-Response 只按字节进 MIC、按元素个数进 Element Count。
  - R0KH 与 R1KH 之间的协议（13.10）、资源请求协议（事务序号 3、4）没做；对拍里的 R0KH 是进程内替身（`R0kh.pull`）。
  - 目标 AP 对重关联请求先验 MIC 再查内容（13.7.1）：MDE 不对回 54、FTE 的字段不对回 55、RSNE 的 PMKID 不对回 53；
    帧体不是该步该有的样子时丢弃。截止时间：目标 AP 从收到第一个消息起算，FTO 从第二个消息核对通过起算。
- **无线测量的取舍**（`rrm.zig` 文件头同文）：
  - Beacon report 的 Reported Frame Body 里 TIM / RSNE 的截断：原文写「only the first 4 octets of the element are reported and
    the element Length field is modified to indicate the truncated length of 4」，两句话不能同时按字面成立。本实现取
    「Information 截到前 4 个八位组、Length 写 4」；盘上的 wpa_supplicant 不截断（`common/rrm.c:466–477`）。
  - Beacon request 是 Passive / Active 而 Measurement Duration = 0：11.11.4 只规定发送方不得置 0，没规定接收端怎么办；
    本实现按 Refused 回绝。
  - 没有可报的 BSS 时发空的 Beacon report（11.11.9.1 允许 refuse 或 empty，取 empty）。
  - Extended Request 子元素（ID 11）、Reporting Condition 5–10 的参考电平、RM Enabled Capabilities 元素、
    Operating Class ↔ 信道的 Annex E 映射都不做。量测本身（离信道、定时、随机退避）由调用方做。
- **WNM 的取舍**（`wnm.zig` 文件头同文）：
  - 候选表里有候选、但本端 BSS 表里一个都没见过时回 2（Table 9-357 的字面含义；11.24.7.4 规定 AP 收到 2 后应留出扫描时间）；
    hostap 同一情形回 7（`common/wnm_sta.c:710–713`）。
  - BTM Status 3 需要 BSS Available Admission Capacity / BSS Load，本端 BSS 表不存，判决模型不会产出 3。
  - TFS（11.24.12）不实现：WNM Sleep Mode 帧里的 TFS 元素原样透传。9.6.14.19 正文写 TFS Request Elements
    "contains one or more"，图 9-715 标的是 variable，本实现接受为空。
  - Key Data（GTK / IGTK 的封装）不实现：只保留长度字段与「该走 Key Data 还是组密钥握手」的判定。
  - 「2016 无明文、依据盘上 hostap」的两条：候选表条目没有 Preference 子元素时不算 excluded（2016 只说 Preference 为 0 即
    excluded；hostap `common/wnm_sta.c:337` 是 `preference_present && preference == 0` 才排除）；Accept 时 Target BSSID 总是
    6 个八位组，不知道目标时写 6 个 0（`common/wnm_sta.c:610–617` 引 P802.11-REVmc 的澄清）。

## 7. 未验证

- 真实 AP 互通；消息 3 与组密钥消息 1 的字段宽松度只能靠实网确认。
- CCMP 与 GCMP 在 QoS 加四地址帧上的 30 字节 AAD 只有构造测试，没有官方向量。
- 现代真实 AP 的 Beacon（厂商特定元素、AID 高位）只在 2004 年的抓包里见过。
- 真实 AP 上的 SAE（WPA3 个人）互通；FT 的初始关联与快速切换；256 位套件（CCMP-256 / GCMP-256 / BIP 的 256 位与 GMAC 变体）的协商与互通。
- QoS 与省电的行为：真实 AP 的 Beacon TIM、PS-Poll 响应、DTIM 之后的组播次序、U-APSD 服务期；EDCA 参数对驱动的影响。
- 第二批的板侧自检已上板（§5.2）；板上只验证了判据本身，真实 AP 上的行为见上面几条。
- 真实 AP 上的 OWE、802.1X / EAP-TLS、SAE 的其它群、FT 的初始关联与快速切换、无线测量与 WNM（BTM、WNM Sleep Mode）：都没有证据；
  第三批只有主机测试、与独立实现的对拍和板侧自检。
- EAP-TLS 的 MSK 与 OpenSSL `SSL_export_keying_material()` 的逐字节一致（见 §6）。
- SAE 其它群里 FFC 大群的整链只在 ReleaseFast 的差分里对过。该片的板侧自检在主机 ReleaseFast 上量过：九个群全做
  双端对打时 19–36 ms，是已在板上跑过的 `sae_full_selftest.zig`（12 ms）的两到三倍，而 `wifi` 镜像的全部 section
  要在 e2e 的 30 秒抓取窗口里出判决；所以板侧的对打收成只做 ECC 25，收完 2.4 ms。板侧耗时没有量过；实际内联后的栈只按序言静态估算过（§5.4），板上没有量过。
