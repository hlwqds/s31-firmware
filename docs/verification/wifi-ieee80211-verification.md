# Wi-Fi 验证报告（IEEE Std 802.11-2016）

- 规范依据：IEEE Std 802.11-2016（条款号取自该版目录与各模块文件头，页码为印刷页码）；其上的 RFC：RFC 3394（AES Key Wrap）、RFC 4493（AES-CMAC）、RFC 6070（PBKDF2）、RFC 4231（HMAC 的测试向量）、RFC 2104（HMAC）。第三批另涉 RFC 8110（OWE）、RFC 5869（HKDF）、RFC 5903 与 RFC 6090（ECC 的 Diffie-Hellman）、RFC 5216 与 RFC 3748（EAP-TLS 与 EAP）、RFC 2409 与 RFC 3526（MODP 群参数）。第四批的 Wi-Fi 侧只涉 RFC 8110 §4.5（OWE 的 PMK caching）。第五批（2026-11-25）的 Wi-Fi 侧不涉新 RFC。
- 组件：`components/wifi-mlme`、`components/wifi-connect`。
- 验证分级见 `docs/REPO-STANDARDS.md` §4。本报告只写实际跑过的命令和输出里出现过的结果。
- **真实 AP 的证据分三种，别混着看**：厂商栈的对照（§8）；本仓库 blob 移植的板侧证据——2026-11-25 起能从 `esp_wifi_start` 返回（§9），2026-11-26 起能扫描到真实 AP（§10）、连上真实 AP 并在 IP 层收发（§11）；`wifi-connect` 的协议实现与真实 AP 的互通，只在 §11 那一种配置下有证据（WPA2-PSK + CCMP-128，一台 AP）。下表的"通过"指离线验证通过。
- 本文把 2026-11-24 加入的 SAE 完整实现、FT 密钥派生层、256 位套件、QoS 与省电称为"第二批"；之前的部分称为"第一批"。
  第二批的板侧自检先在主机上用桩 `board` 模块跑过，随后于同日随 `wifi` profile 上板（§5.2）。
- 本文把 2026-11-25 加入的 OWE、EAP-TLS、按 AKM 的 4 次握手、SAE 其它群、FT 协议、无线测量（radio measurement）与 WNM 称为"第三批"。第三批新增六个板侧子自检，在主机上的读数与复核见 §5.4；**第三批当时没有上板**（2026-11-25 随第五批的镜像上板，全部通过）。
- 本文把 2026-11-25 加入的 OWE PMK caching、FT 的 RIC、RM Enabled Capabilities 与 Annex E、WNM 的 TFS 与 Key Data 称为"第四批"。第四批新增四份板侧子自检，只到 L1 与 L2，**当时没有上板**（2026-11-25 随第五批的镜像上板，全部通过）；主机上的读数与复核见 §5.5，对拍见 §4.5，偏离见 §6 末尾。
- 本文把 2026-11-25 加入的 WNM 其余子域、GAS / ANQP 与 Block Ack（含 A-MSDU 子帧头）称为"第五批"。第五批新增三份板侧子自检；串口权限于同日恢复，验收后经独立评审两轮（第一轮 15 条、第二轮残留 6 条）返修并复验，随 `wifi` profile 上板：**14/14 个 section 全过、`main: verdict=pass`**（§5.6），三个无线 section 的判据在真板上全部通过。主机上的读数与复核见 §5.6，对拍见 §4.6，偏离见 §6，真实 AP 的厂商栈对照见 §8。

## 1. 结论

三种计数分开写：主机用例数是 `zig test` 报的 total；板侧 checks 数是 `selftest.run()` 的判据数；差分向量数是参照实现生成的条数。

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| `wifi-mlme` 主机测试 | L1 | 316/316（第一批 61，第二批 82，第三批 146，第四批 200，第五批 316） | §3.1 |
| `wifi-connect` 主机测试 | L1 | 431/431（第一批 57，第二批 141，第三批 386；含 10 条在主机上执行板侧子自检的用例） | §3.2 |
| 与独立参照实现的差分（第一批） | L1 | 13 组 950 条全部一致 | §4.1 |
| suite-256 全量差分（第二批） | L1 | 14 组 3568 条向量、3928 项比较，0 不一致 | §4.2 |
| 与独立参照实现的差分（第三批） | L1 | 七个特性各自对拍，全部 0 不一致 | §4.4 |
| 与参照实现对拍（第四批） | L1 | 四个特性各自对拍，全部 0 不一致；性质各不相同（独立 oracle 的整帧、策略模型、手排向量、原图手排），分开写在表里 | §4.5 |
| 与参照实现对拍（第五批） | L1 | 三个特性照同一份规范写的 Python 模型对拍，合计 1216 + 696 + 5012 例，0 不一致；性质与限制见 §4.6（不是独立实现对拍） | §4.6 |
| RV32 目标编译 | L2 | 两个自检都能以固件参数编译（第二批的 24 / 87 条）；第三批之后两个组件的整份自检（37 / 177 条）、第四批之后（58 / 199 条）、第五批之后（121 / 199 条）同样通过 | §5.1、§5.4、§5.5、§5.6 |
| 板侧自检在主机上的运行（桩 `board`） | L1 | `wifi_mlme` 24/24、`wifi_connect` 87/87；第三批之后 37/37、177/177；第四批之后 58/58、199/199；第五批之后 121/121、199/199 | §5.1、§5.4、§5.5、§5.6 |
| 板侧自检（第一批上板） | L3 | `wifi_mlme` 16/16、`wifi_connect` 28/28 | `logs/wifi-selftest-prefix-boot.log` |
| 板侧自检（第二批） | L3 | `wifi_mlme` 24/24、`wifi_connect` 87/87 | `logs/e2e-wifi-boot.log`；§5.2。该文件名已被 2026-11-25 第五批那次运行覆盖，这次的日志只剩 git 历史 |
| 板侧自检（第五批上板） | L3 | **14/14 个 section 全过、`main: verdict=pass`**：`wifi_mlme` 121/121、`wifi_connect` 199/199、`ble_802154` 207/207（第三、四、五批的判据第一次上板）、`net_ethernet` 11/11。最小验证镜像（`--only ble_802154,wifi_mlme`，512704 B，整份 `wifi` 镜像的 42%）同样 `PASS board:wifi[ble_802154,wifi_mlme]` | `logs/e2e-wifi-boot.log`、`logs/e2e-wifi-only-ble_802154+wifi_mlme-boot.log`；§5.6 |
| 整体判决为 pass 的板级运行 | L3 | 有：14/14 段、`main: verdict=pass`——第一批复验一次、第二批之后一次、第五批终态（2026-11-25）再一次；每次都覆盖了 `logs/e2e-wifi-boot.log` 的同名文件，现在盘上这份文件的内容就是第五批终态的 pass 运行 | `docs/verification/README.md`、git 历史 |
| `wifi-connect` 接进真实链路（WPA2-PSK + CCMP-128） | L4 | 本仓库自己的移植连上用户提供的 AP：`STA_CONNECTED`（authmode 3、aid 1、信道 1），从发起到连上约 3.0 s；MAC 密钥表里的成对钥匙与组钥匙和请求方手里的逐字节相同；DHCP 拿到地址，ping 网关 10/10 | `logs/wifi-link-connect-boot.log`；§11 |

## 2. 逐特性对照

"主机"一栏是 `zig test src/host_tests.zig` 的用例数（按模块），"板侧"是 `selftest.zig` 的判据数。第一批各行的板侧数字含在当时的 16 / 28 条里；第二批各行的判据含在 24 / 87 条里（主机桩跑与上板都是这两个数），逐特性的板侧划分没有单独统计。第三批各行的板侧一栏是该特性子自检自己的判据数，含在两个组件的 37 / 177 条里；第四批同理，含在 58 / 199 条里；第五批同理，含在 121 / 199 条里。

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
| OWE 的 PMK caching：请求里同时带 PMKID 与 DH Parameter element、AP 命中与未命中、client 命中 / 回退 / 忽略、缓存条目与过期 | RFC 8110 §4.5、§4.3；802.11-2016 9.4.2.25（PMKID List）、`dot11RSNAConfigPMKLifetime` 的 DEFVAL | `wifi-connect/src/owe.zig`（`Cache`、`clientCacheDecision`、`apCacheDecision`、`buildAssocRequestWith`） | 25（`owe_cache_tests.zig`） | RFC 原文逐条；缓存管理策略对拍盘上 hostap 的 `rsn_supp/pmksa_cache.c` 与按它写的 Python 模型 | 12（`owe_cache_selftest.zig`） | 离线验证通过；§4.5 没有规定缓存策略，见 §6 |
| FT 的 RIC：RDE 与 Block Ack 的 RIC Descriptor 编解码、一条 RIC 的结构规则、进重关联帧的条件 | 9.4.2.50、9.4.2.51（图 9-322、图 9-323、表 9-161）；13.11.2、13.11.3.1、13.11.3.2；13.7.1、13.8.5；表 9-30 注 14；图 9-314 | `wifi-connect/src/ft_proto.zig`（第 5b 节） | 18（`ft_ric_tests.zig`） | 按图手排的字节；带 RIC 的完整交换对 `ric_oracle.py`（复用 `ft_proto_oracle.py`）；hostap 的 Element Count（`rsn_supp/wpa_ft.c:340`） | 10（`ft_ric_selftest.zig`） | 离线验证通过；只解析 Block Ack 描述符，见 §6 |
| RM Enabled Capabilities 元素；Annex E 的 Operating Class 表与查询（类与信道到中心频率） | 9.4.2.45（图 9-311、表 9-157）；11.11.6；11.11.4（表 11-8）；17.3.8.4.2 的式 (17-27)；20.3.1；Annex E 的表 E-1 到 E-5 | `wifi-mlme/src/rrm.zig`（第 13、14 节） | 16（`rrm_caps_tests.zig`） | 按原图与原表手排；`rrm_caps_oracle.py` 的 516 行向量（309 个正例、194 个信道集合外负例、3 个频率负例），内嵌在测试里 | 7（`rrm_caps_selftest.zig`） | 离线验证通过；收录范围见 §6 |
| TFS：TCLAS 八种分类器、TCLAS Processing、TFS Request / Response / Notify 帧、AP 侧与 STA 侧模型、过滤匹配；WNM Sleep Mode Response 的 Key Data（GTK / IGTK 子元素） | 11.24.12.1–.3；9.4.2.31、9.4.2.33、9.4.2.80、9.4.2.81；9.6.14.15–9.6.14.18、9.6.14.20（图 9-716 到 9-718）；表 9-354、9-358 | `wifi-mlme/src/wnm.zig`（第 10–14 节） | 36（`wnm_tfs_tests.zig`） | 按原图手排；`wnm_tfs_oracle.py`（帧体布局与匹配语义）；hostap 头文件的动作值常量 | 14（`wnm_tfs_selftest.zig`） | 离线验证通过；Key Data 的加密是注入点，见 §6 |
| WNM 其余子域：BSS Max Idle（含保活判决）、TIM Broadcast、FMS、DMS、Collocated Interference（含占空比）、Channel Usage、WNM Notification、Event / Diagnostic 容器、QoS Traffic Capability 元素 | 11.24.2、11.24.3、11.24.8、11.24.9、11.24.10、11.24.13、11.24.15、11.24.16.2、11.24.17；9.6.14.2–.5、.11–.15、.21–.27、.29–.30；9.4.2.67–.70、.76–.89（表 9-77 的元素 ID、表 9-354 的动作值、表 9-199、表 9-178、9.4.2.85） | `wifi-mlme/src/wnm.zig`（第 15–24 节）、`wnm_rest_tests.zig`、`wnm_rest_selftest.zig` | 39（`wnm_rest_tests.zig`） | 按原图与原表手排；照同一份规范写的 Python 模型对拍（5012 例：14 种子 × 358，主代理重跑其中 4 个种子共 1432 例，0 不一致）；hostap 只有 `WNM_*` 动作枚举可对拍（`ieee802_11_defs.h:765–792`）；占空比公式 ⌊(2³²−2)×T_B/T_I + 0.5⌋ 对渲染 PDF 的原文（9.4.2.85，印刷页 1009）核实 | 31（`wnm_rest_selftest.zig`） | 离线验证通过；独立评审的 12 条发现（含 P1：CI Report 元素宽度按图 9-427 应为 21 八位组）已返修；没做的边界见 §6（FMS Descriptor 元素 ID 86、WNM Notification 的 AP Descriptor / Firmware Version 子元素内容、FTM / Timing Measurement、Location track、Proxy ARP、AC Station Count 等非目标）；取舍与偏离清单见 `wnm.zig` 文件头 |
| GAS / ANQP 与 Interworking：Public Action 10–13、GAS Initial / Comeback 的分帧与状态机、`dot11GASResponseTimer`、ANQP 元素子集（含 NAI Realm） | 9.6.8.12–.15、9.6.8.1（表 9-307）、表 9-313–9-316、图 9-666–9-670、9.4.2.93、9.4.5（ANQP 元素，图 9-606）、9.4.5.5（Emergency Call Number）、11.25.3.2.2–.4、11.25.3.3、9.4.1.9、9.4.1.12、9.4.1.34、表 9-46 | `wifi-mlme/src/gas.zig`、`gas_tests.zig`、`gas_selftest.zig` | 36（`gas_tests.zig`） | 按条款与原图手排；照同一份规范写的 Python 模型对拍（696 例：接受 563 / 拒绝 133，0 不一致）；盘上 hostap 裁掉了 `gas.c` / `anqp.c`，没有独立实现 | 13（`gas_selftest.zig`） | 离线验证通过；Status Code 字段 2 八位组按 9.4.1.9；Emergency Call Number（9.4.5.5）按评审意见补齐；其余边界见 §6 |
| Block Ack 与 A-MSDU 子帧头：ADDBA Request / Response、DELBA、记分板位图语义、接收重排缓冲（时间注入）、A-MSDU 子帧头 | 9.3.1.8–.9、9.3.2.2、9.4.1.14–.16、9.4.2.139（图 9-79）、9.6.5.2–.4、10.12、10.24.1–.2 / .4 / .7.3 / .7.5–.6、11.5.2–.4（表 9-302、9-303、9-304） | `wifi-mlme/src/blockack.zig`、`blockack_tests.zig`、`blockack_selftest.zig` | 38（`blockack_tests.zig`） | 按条款手排；照同一份规范写的 Python 模型对拍（4 × 240 随机 + 256 条确定性边界 = 1216 例，0 不一致）；窗口边界对渲染 PDF 的原文（印刷页 1424 / 1427 / 1428）逐格核对；A-MSDU Length 的大端序只有规范依据（内核只有头文件） | 19（`blockack_selftest.zig`） | 离线验证通过；独立评审（2026-11-25）对本片逐条核对、无发现；只做 Basic 与 Compressed 变体，边界见 §6 |
| 真实 MAC：`esp_wifi_start`、扫描、连接 | 不适用 | — | — | — | — | `esp_wifi_start` 已返回 0（2026-11-25，§9）；扫描已上板（2026-11-26，§10）；连接与 IP 层收发已上板（2026-11-26，§11，WPA2-PSK + CCMP-128） |

负面用例（主机）：截断、越界、不一致的输入逐个被拒；MIC 错、重放或重复计数、顺序错、解包失败、RSNE 被改、PN 重放、错 IGTK、SA Query 事务标识不符。第二批追加：口令不同时 Confirm 校验失败并删除 PMK、非法的对端 Commit、回声 Commit、不支持的群、Anti-Clogging token 错、篡改 / 截断 / 标错套件的 256 位帧、KEK 长度不对。
第三批追加：OWE 的公钥不在曲线上、私钥越界、响应里有 OWE AKM 却没有 DH Parameter element；EAP-TLS 的 Flags 与长度字段不合法、重复的 Request、握手完成前收到的 EAP-Success；按 AKM 的握手里 PMK 长度不符、AKM 与密码套件不能合用、消息 1 的 PMKID 不符；SAE 其它群里的非法对端 Commit 与状态码 77 的群协商；FT 协议里 MIC 不对、重放、移动域 / R0KH-ID / ANonce / SNonce 不符、截止时间已过；无线测量与 WNM 里的保留值、Request mode 与可选字段对不上、Query / Response 里 Preference 为 0。每条都断言拒绝的理由是正确的那一个（状态码、丢弃原因或错误名）。
第四批追加：OWE PMK caching 里响应没有 PMKID 或不一致、请求没带 PMKID 时响应里的 PMKID、缓存里已没有条目却收到匹配的 PMKID、响应里有两个 PMKID、PMKID 非空而策略的 MFPC 为假；RIC 里 RDE 的 Length 不是 4、保留的 Resource Type、RIC 以非 RDE 开头、Block Ack 描述符个数与计数不符、响应与请求不一一对应、AP 在请求带了 RIC-Request 时没给 RIC-Response、没请求却给了；RM Enabled Capabilities 的保留位在构造时被拒、不支持的类与信道集合外的信道；TFS 里保留的子元素 ID 与分类器类型、长度不符、多个 TCLAS 缺 TCLAS Processing、AP 的部分拒绝、Key Data 的顺序。
第五批追加：WNM 其余子域里 Idle Options / QoS Flags 的保留位、状态 / 类型表的保留段、DMS 在 Ext-Cap 的位 26 不对、无干扰时 Expected Accuracy 不是 15、诊断请求的类型 221（厂商）；GAS 里重复片、响应缓冲耗尽、厂商协议 221、95 在 Initial Response 里出现；Block Ack 里 `SN = WinStartR + 2^11`（不动，严格小于）、ADDBA Request 的 Fragment Number ≠ 0、ADDBA Response 成功而 Buffer Size < 1。每条都断言拒绝的理由是正确的那一个。

## 3. 主机测试

### 3.1 `wifi-mlme`

```sh
cd components/wifi-mlme && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 316 tests passed.
```

模块分布（2026-11-25，第五批返修之后）：`host_tests.zig` 69（自身 61：`frame` 13、`ie` 11、`mgmt` 8、`robust` 4、`mlme` 19、`scan` 6；
另有 8 个 wrapper `test` 块引 `qos_tests.zig`、`powersave_tests.zig`、`rrm_wnm_tests.zig`、`rrm_caps_tests.zig`、`wnm_tfs_tests.zig`、
`wnm_rest_tests.zig`、`blockack_tests.zig`、`gas_tests.zig`）
+ `qos_tests.zig` 10 + `powersave_tests.zig` 9 + `rrm_wnm_tests.zig` 63 + `rrm_caps_tests.zig` 16 + `wnm_tfs_tests.zig` 36
+ `wnm_rest_tests.zig` 39 + `blockack_tests.zig` 38 + `gas_tests.zig` 36 = 316。
六个测试文件各有一条在主机上执行对应的子自检（`rrm_wnm_selftest.run` 13 条判据、`rrm_caps_selftest.run` 7 条、
`wnm_tfs_selftest.run` 14 条、`wnm_rest_selftest.run` 31 条、`blockack_selftest.run` 19 条、`gas_selftest.run` 13 条），
断言零失败且最长一行不超过 200 字节。`zig fmt --check src/` 干净。

### 3.2 `wifi-connect`

```sh
cd components/wifi-connect && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 431 tests passed.
```

模块分布（2026-11-25，第四批之后）：`host_tests.zig` 70（自身 57；引第二批三个测试文件的 3 个、第三批五个测试文件的 5 个、
第四批两个测试文件的 2 个 wrapper `test` 块；另有 3 条在主机上执行板侧子自检的用例）+ `sae_full_tests.zig` 31 + `ft_tests.zig` 24
+ `suite256_tests.zig` 23 + `owe_tests.zig` 30 + `eap_tests.zig` 34 + `supp_akm_tests.zig` 45 + `sae_groups_tests.zig` 67
+ `ft_proto_tests.zig` 64 + `owe_cache_tests.zig` 25 + `ft_ric_tests.zig` 18 = 431。
第二批的三条子自检用例分别跑 `sae_full_selftest.run`（24 条判据）、`suite256_selftest.run`（22 条）、`ft_selftest.run`（13 条）；
第三批的五个测试文件各带一条，跑 `owe_selftest.run`（18 条）、`eap_selftest.run`（8 条）、`supp_akm_selftest.run`（19 条）、
`sae_groups_selftest.run`（33 条）、`ft_proto_selftest.run`（12 条）；第四批的两个测试文件各带一条，跑 `owe_cache_selftest.run`
（12 条）、`ft_ric_selftest.run`（10 条）。十条都断言零失败且最长一行不超过 `board.log` 的 200 字节上限。`zig fmt --check src/` 干净。

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

### 4.5 第四批的对拍

四个特性各有对拍，性质不相同，下表分开写。数字是 2026-11-25 主代理在终态代码上重跑得到的（§5.5）。参照实现都在 `/tmp/s31-oracle/`，一次性驱动不入库。

| 特性 | 参照实现 | 规模 | 结果 | 性质 |
| --- | --- | --- | --- | --- |
| FT 的 RIC | `/tmp/s31-oracle/ft_ric/ric_oracle.py`（复用 `ft_proto_oracle.py`；RIC 按图 9-322、图 9-323、表 9-161 手排） | AKM 4、CCMP-128、一条 Resource Request（RDE + 一个 Block Ack 描述符）；over-the-air 与 over-the-DS 各一条完整交换的六个帧（前两个消息两种走法、消息 3、消息 4） | 重跑 rc=0；`kck`、`mic3`、`mic4`、六个帧、两段 RIC 共 12 个字段与 `expected.json` 一致，全部内嵌在 `ft_ric_tests.zig` 里 | 独立 oracle 的整帧字节 |
| OWE 的 PMK caching | `/tmp/s31-oracle/owe_cache/cache_oracle.py` | seed 20261125 与 77 各 400 次操作 | 每个 seed `compare: cases=400 mismatches=0`；驱动二进制（10:35）晚于 `owe.zig` 的最后一次修改（10:34） | **策略模型对拍**：Python 模型照 `owe.zig` 文件头的策略写、与 hostap `rsn_supp/pmksa_cache.c` 交叉阅读，不是规范向量。PMK / PMKID 的派生沿用第三批 `owe_oracle.py` 的差分（§4.4） |
| RM Enabled Capabilities 与 Annex E | `/tmp/s31-oracle/rrm_caps/rrm_caps_oracle.py`（按原图与原表手排） | 自检 8 个手排中心频率 + 8 个信道集合；向量 309 个正例（每类的首、中、尾信道）+ 194 个信道集合外负例 + 3 个频率负例，共 516 行；3 个能力字节向量 | 重跑 rc=0、自检通过；重新生成的 516 行向量与交付时逐字节相同，全部内嵌在 `rrm_caps_tests.zig` 的 `oracle` 命名空间里 | 规范图表的手排向量 |
| TFS 与 Key Data | `/tmp/s31-oracle/wnm_tfs/wnm_tfs_oracle.py`（帧体按规范原图排，匹配语义按表 9-144 到 9-149） | seed 20261125 / 20261126 / 777 各 310 例；放大一组 930 例（420 例是规则对帧的匹配，其余是 TCLAS 135、Key Data 90、TFS 子元素 60、TFS Request / Response 元素各 45、帧体三种各 30、构造 Sleep Mode Response 45） | 每个 seed `compare: cases=310 mismatches=0`；930 例的一组 `compare: cases=930 mismatches=0`；oracle 自检 12 项 0 失败；harness（11:17）晚于 `wnm.zig`（10:58） | 规范原图的手排对拍。IDF 里的 hostap 把 TFS 与 WNM Sleep 的 GTK / IGTK 处理裁掉了（`common/wnm_sta.c` 无命中），没有独立实现 |

这一批四组都不是规范给出的向量：IEEE 没有 RIC 与 Annex E 的样例数值，RFC 8110 §4.5 没有规定缓存管理，TFS 没有独立实现可对拍。

### 4.6 第五批的对拍

三个特性各有一组与 Python 模型的对拍。数字是 2026-11-25 主代理用交付源码重编驱动（一律 `-O ReleaseSafe`）后在独立评审返修之后的终态代码上重跑得到的（§5.6）。一次性驱动不入库。Wi-Fi 三片合计是 1216 + 696 + 5012 例；含 BLE 三片的六片总计 10513 例（程序算的）。

| 特性 | 规模 | 结果 | 性质 |
| --- | --- | --- | --- |
| WNM 其余子域 | 5012 例（14 种子 × 358；主代理在终态代码上重跑其中 4 个种子共 1432 例；oracle 自检 61 项通过） | 0 不一致 | 照同一份规范写的模型对拍；hostap 只有 `WNM_*` 动作枚举可对拍（`ieee802_11_defs.h:765–792`），元素的实现没有独立实现 |
| Block Ack | 4 × 240 随机 + 256 条确定性边界 = 1216（每个边界格 8 次命中，不靠概率撞） | 0 不一致 | 照同一份规范写的模型对拍；无独立实现（盘上 hostap 是裁剪版，内核只有头文件）。确定性边界用例是返修时补的——模型与实现同错时差分抓不出来，本片的边界错误就是靠渲染 PDF 原文抓到的（§5.6）。独立评审对本片逐条核对、无发现 |
| GAS / ANQP | 3 个种子共 696 例（接受 563 / 拒绝 133：Truncated 94、BadValue 16、ReservedValue 12、BadCategory 4、BadAction 4、UnsupportedProtocol 3） | 0 不一致 | 照同一份规范写的模型对拍；无独立实现。过程里差分没有抓到、手排向量抓到的真缺陷见 §5.6（NAI Realm 的字段顺序） |

**这批三组都不是独立实现对拍**：模型照同一份规范写，模型与实现同错时差分抓不出来；本批实际发生两次（Block Ack 的窗口边界、NAI Realm 的字段顺序，§5.6），独立评审又抓出两处同错的读图错位（CI Report 的八位组行、CI 电平的值域端点）。

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
  4. 抓取窗口：`wifi` profile 的抓取窗口从 30 秒放宽到 60 秒（`full` 90 秒，其余不变）。依据是指令数而不是主机耗时：
     `tools/qemu-instr` 把同一份 riscv32 ReleaseSmall 代码放到 QEMU 上精确数指令，`wifi_connect` 整份是 15.48 亿条
     （第三批新增的部分 6.03 亿条，约 7.5 秒），板上每条约 1 周期（`logs/c7-perf-tiers.log` 校准），光计算就是 19.3 秒。
     `sae_groups_selftest` 3.74 亿条、4.7 秒（FFC 的 PWE 1.7 秒、群协商 1.0 秒、群 25 的对打 0.4 秒）；
     `owe_selftest` 2.20 亿条、2.8 秒，每条判据差不多是一次 P-256 点乘，一次约 2070 万条指令、0.26 秒；
     第二批的 `sae_full_selftest.checkFsm` 5.10 亿条、6.4 秒。数字与读法见 `docs/TESTING.md`「板侧自检的两条隐性预算」。

### 5.5 主代理对第四批的独立复核（2026-11-25）

- **逐片验收**：四片各跑 `sh /tmp/r5c/accept.sh wifi-<组件> <特性>`，再自己重跑它引用的现有测试根。读数：

| 片 | 主机测试 | 子自检在主机上（最长一行） | 目标编译 | 现有测试根的回归 |
| --- | --- | --- | --- | --- |
| `owe_cache` | 25/25 | 12/0（128 字节） | rc=0 | `owe_tests.zig` 30/30，`owe_selftest` 18/0 |
| `ft_ric` | 18/18 | 10/0（62 字节） | rc=0 | `ft_proto_tests.zig` 64/64，`ft_proto_selftest` 12/0 |
| `rrm_caps` | 16/16 | 7/0（96 字节） | rc=0 | `rrm_wnm_tests.zig` 63/63，`rrm_wnm_selftest` 13/0（两片都交回后在终态代码上跑） |
| `wnm_tfs` | 36/36 | 14/0（102 字节） | rc=0 | 同上 |

- **整份自检在桩 `board` 模块上运行**（命令同 §5.1）：`wifi_mlme` `checks: passed=58 failed=0 total=58`（最长一行 154 字节）、
  `wifi_connect` `checks: passed=199 failed=0 total=199`（140 字节）。总数不等于各子自检之和：`wifi-connect` 的驱动 `selftest.zig` 自己有 28 条判据。
- **整份自检以固件参数交叉编译**（带守卫的根文件）：两个组件都退出 0。这一批补了负对照：把目标参数放到最后一个 `-M` 之后，
  守卫报 `guard: root module is not riscv32 (got x86_64)` 并非零退出。`-fno-emit-bin` 只做语义分析，一两秒返回属正常。
- **对拍在终态代码上重跑**，数字见 §4.5。
- **条款锚点逐条打开原文核对**（`/tmp/spec/802.11-2016.txt` 的正文行号）：9.4.2.50 在 51186、图 9-322 在 51205–51207、9.4.2.51 在 51222、
  表 9-161 在 51236–51243、13.11.2 在 110140、13.11.3.1 在 110255、13.11.3.2 在 110302、13.7.1 在 109071、13.8.5 在 109309；
  9.4.2.45 在 50785、11.11.6 在 89387、11.11.4 在 89300、`dot11RSNAConfigPMKLifetime` 在 150617–150634；9.4.2.80 在 54412、
  图 9-418 在 54427–54432、9.4.2.81 在 54497、9.6.14.15–.18 在 65456 起、9.6.14.20 在 65538、表 9-354 在 64990、11.24.12 在 94067。
  切片笔记里的行号有偏 15–20 行的，报告用核过的数。
- **顺手改的已有函数**：`rrm.maxMeasurementDurationTu` 对 MIB 1–3 原先做 `u32` 减法下溢、返回 `maxInt(u32)`。11.11.4 的公式是
  2^(MIB−4) × BeaconInterval，MIB 取 0–7，这几个值是亚 Beacon Interval 的分数时长。现改为向下取整的 TU 数，MIB 为 0 与 ≥4 的结果不变，
  有用例。另：Beacon request 的 Operating Class / Channel 校验接进了 `rrm.decide()`（9.4.2.21.7）。
- **尺寸与指令数**（riscv32 ReleaseSmall）：`ft_ric_selftest` text 2802 B、26181 条 rv32 指令；`owe_cache_selftest` text 12331 B、104108 条；
  `rrm_caps_selftest` text 12983 B、25348 条；`wnm_tfs_selftest` text 24123 B、182300 条。text 用 `zig build-obj` 量（链接级
  `build-exe -fno-entry` 在没人调用 `run()` 时会把内容全部回收，只剩几十字节，不能用）；指令数在 QEMU 上数。
- **镜像与门禁**：`scripts/check-all.sh` 全绿；主机测试 1818；`wifi` 镜像 1063200 → 1157568 字节，函数代码多 63960 字节，
  其中第四批 Wi-Fi 四片 32128 字节、BLE 两片 31274 字节、其余零星几百字节。容量基线已更新。
- **没有上板**（当时的记录）：串口 `/dev/ttyUSB0` 属 `root:dialout`，当前账号没有权限，板上跑的仍是第二批的镜像。
  第四批的判据已于 2026-11-25 随第五批的镜像上板（`wifi_mlme` 121/121、`wifi_connect` 199/199，§5.6）。

### 5.6 主代理对第五批的独立复核（2026-11-25）

- **逐片验收**：每片跑 `sh /tmp/r5c/accept.sh <组件> <特性>`，再自己重跑它引用的现有测试根。读数（三片都在 `wifi-mlme`；下表是返修之后、上板之前的复验读数）：

| 片 | 主机测试 | 子自检在主机上（最长一行） | 目标编译 | 现有测试根的回归 |
| --- | --- | --- | --- | --- |
| WnmRest | 39/39（返修后） | 31/0（114 字节） | rc=0 | `rrm_wnm_tests.zig` 63/63、`wnm_tfs_tests.zig` 36/36（主代理重跑） |
| BlockAck | 38/38（返修后） | 19/0（62 字节） | rc=0 | 同上（同一测试根） |
| GasAnqp | 36/36（评审返修后） | 13/0（66 字节） | rc=0 | 同上 |

- **组件级集成**：整组件 `host_tests.zig` 316/316；整份自检在桩 `board` 模块上运行（命令同 §5.1）：
  `wifi_mlme` `checks: passed=121 failed=0 total=121`（最长一行 154 字节）、`wifi_connect` 199/199 不变。
  整份自检以固件参数交叉编译（带守卫的根文件）退出 0；负对照（目标参数放在最后一个 `-M` 之后）触发守卫。
- **独立评审与返修（2026-11-25，只读评审员；报告 15 条）**：BlockAck 全部核对通过、无发现；WnmRest 与 GasAnqp 共 15 条
  （缺陷 9、比原文严 1、文档 1、存疑 3、未覆盖 1），逐条处理如下，返修后全部复验（上表的读数就是复验读数）：
  1. **P1，CI Report 元素宽度（主代理复核属实，主代理验收时的漏项）**：实现把 Interference Center Frequency 做成
     2 八位组、元素体 19 字节；原图 Figure 9-427（印刷页 1008）第二行 Octets 是 4 4 4 4 2，元素体 **21** 字节
     （center 在 body[15..19]、bandwidth 在 body[19..21]）。以 5 kHz 为单位时 2.4 GHz 本信道是 482 400，u16 装不下，
     合规对端发来的每一条 CI Report 元素都会被拒收。验收时只核了那一页的正文、没回头对图的八位组行。已按原图重做。
  2. DMS Add 描述符漏了「恰好 1 个 TCLAS + TCLAS Processing」的反方向检查（9.4.2.88 的「Otherwise … zero」；响应侧同构检查在位）。已补。
  3. P3 七条已修：Destination URI 被认出后丢弃且 Report 帧不该带（图 9-695 / 9-697 没有 URI 槽位）；GAS 失败路径置
     Query Response Length = 0（11.25.3.2.2 d)）；`buildQueryList` 拒收空列表（9.4.5.2「one or more」）；Advertisement Protocol
     元素分方向（响应侧 limit = 0 是禁止值）；FMS 元素总长与 DMS Length 封顶（≤ 255 / ≤ 253）；CI 电平「未知」+127 不再封顶
     （9.4.2.85：未知 +127 与实测 ≥126 是两个编码）；Diagnostic 类型 0/1/2 拒收子元素（9.4.2.69）。
  4. 比原文严的一条已改：CI Request 的「auto = 0 且 Report Timeout ≠ 0」按 9.2.4.1 在接收时忽略保留子字段，不再整帧拒收。
  5. 文档三处已改（`gas_tests.zig` 的 Status Code 措辞、FMS 注释长度、`wnm.zig` 印刷页码 +1 的零星偏移）。
  6. 存疑三条照实保留（WNM Notification Type 0 子元素的在場校验、QoS TC Update 帧的标志位视图、`parseTimBroadcastRequest`
     的尾随字节），未当缺陷收口；未覆盖的 9.4.5.5 Emergency Call Number 已照原文补编解码、用例与板侧判据（GasAnqp 34 → 36、12 → 13）。
- **评审第二轮（`/tmp/r5c/review-wifi-r2.md`）**：15 条里 14 条已解决，残留 6 条也已在返修中处理——
  Destination URI ≤ 253 八位组（9.4.2.90）两侧强制，补 253 通过 / 254 拒收的用例；构造侧 URI 元素最小长度与解析侧对齐；
  测试向量注释的旧值与「定长 19」的结构注释改正。**其中一条要如实记录主代理的误判**：评审指出 DMS 描述符构造侧的
  `payload > 252` 比原文严一个八位组（9.4.2.88：DMS Length 最大 253，`payload` 就是 DMS Length），主代理核对时只读了 6 行、
  误判为「不成立」并让切片别改；之后读完整函数发现评审是对的，自己改成 253，补了 n = 252（DMS Length = 253）可构造、
  n = 253 被拒的边界用例。WnmRest 的差分与子自检因此各加一点体量（5012 例、21867 B、50356 条指令）。
- **对拍在用交付源码重编的驱动上重跑**（一律 `-O ReleaseSafe`；切片留下的驱动二进制不沿用），数字见 §4.6。
  GasAnqp 的差分 684 → 696 例；WnmRest 的差分扩到 5012 例（14 种子 × 358，评审第二轮给 URI 长度上限补了正负例后主代理重跑 4 个种子 1432 例）。
- **尺寸与指令数**（riscv32 ReleaseSmall；text 用 `zig build-obj` 量，指令数在 QEMU 上数）：`wnm_rest_selftest`
  text 21867 / data 0 / bss 320 B、50356 条 rv32 指令；`blockack_selftest` 3461 / 0 / 160 B、155665 条；
  `gas_selftest` 7810 / 0 / 392 B、9300 条。六片子自检（含 BLE 三片）text 合计 46709 B，指令数最多 155665 条，
  离每片 ≤ 2400 万条的预算低两个数量级；text 最多 21867 B（每片 ≤ 24 KB 预算的 91%）。
- **条款锚点逐条打开原文核对**，其中原文的不等式 / 公式在 txt 转储里是图片、为空的，渲染 PDF 页读原式
  （`pdftoppm`，PDF 页 = 印刷页 + 1）。
- **返修与更正清单（验收阶段）**：
  1. **BlockAck 的窗口边界错误（真缺陷）**：`SN = WinStart + 2^11` 这一格在 3 处被当成「前移」，原文是严格小于、
     属于「旧序号」一侧（10.24.7.3 b)2)/3)、c)2)/3)；10.24.7.6.2 b)/c)，印刷页 1424 / 1427 / 1428）。原因是 txt 转储里
     不等式是图片、为空，切片推断反了，Python 模型同错。渲染 PDF 原件后更正：三处 `<=` → `<`，记分板 BAR 的 c)1) 补
     `SSN = WinStartR` 不改记录；主机用例 33 → 38，板侧判据 16 → 19，text 2523 → 3461 B，QEMU 4824 → 155665 条；
     差分模型同步更正并加确定性边界用例。这条也证明了 §4.6 末尾的判断：模型与实现同错时差分抓不出来。
  2. **WnmRest 带着红测试交付**：首次交回时主机 34/39、板侧自检 5 条不过；另发现 `parseQosTrafficCapabilityElement`
     对元素长度严格判等（`!= 1` 拒收），比原文严——9.4.2.78 规定 Length = 1 + n（n 是位 0–1 里非零位的个数），
     AP 发来的元素可以是 2 或 3 字节。返修后 39/39、31/0。
  3. **主代理改的一处**：`keepaliveVerdict` 的周期参数由 u16 改成 u32。元素里的 Max Idle Period 以 1000 TU 计，
     真实取值是几百（例如 293 ≈ 300 秒 → 293000 TU），u16 装不下换算后的 TU；测试补了这一量级的用例。
  4. **GasAnqp 的出处更正**：切片文件头写「Status Code 字段的宽度原文没有写，此为整份模块唯一的『规范沉默、按实现惯例定宽』的字段」。
     原文不是沉默的：9.4.1.9 规定 Status Code 字段是 2 八位组，表 9-314 / 9-316 的字段表写的就是它。盘上
     esp-idf `esp_supplicant/src/esp_dpp.c:1062–1063` 的 2 字节读法与之相符。「hostap 上游用 1 字节」在本机没有可引用的
     源文件（`gas.c` 被裁剪），只能标 [INFERENCE]（见 §7）。
  5. **WnmRest 的一处推断被证实**：占空比公式在 txt 转储里是残缺的，切片重建成 ⌊(2³²−2)×T_B/T_I + 0.5⌋ 并标了 [推断]；
     渲染 PDF 原件（印刷页 1009）读到的原式正是它。
- 差分过程中另抓到并修掉一处真缺陷（手排向量、差分盲区）：GasAnqp 的 NAI Realm 的 EAP Method Count 读在 Realm 之前
  （违反图 9-606），Zig 与 Python 模型同错；三个 build 函数返回长度少 2；重复片的判定顺序。均已修。
- **板级（终态代码，2026-11-25）**：`BOARD=/dev/ttyUSB0 python3 tests/e2e/run_e2e.py --board --profile wifi` →
  **`PASS board:wifi`**：14/14 个 section 全过（`wifi_mlme` 121/121、`wifi_connect` 199/199、`ble_802154` 207/207、
  `net_ethernet` 11/11），聚合 `firmware: sections: passed=14 failed=0 total=14`、`main: verdict=pass`；
  日志 `logs/e2e-wifi-boot.log`。第三、四、五批的板侧判据都是第一次上板、全部通过。
  最小验证镜像（`tests/e2e/run_e2e.py --board --profile wifi --only ble_802154,wifi_mlme`）同样通过：
  `PASS board:wifi[ble_802154,wifi_mlme]`、207/207 与 121/121，日志 `logs/e2e-wifi-only-ble_802154+wifi_mlme-boot.log`；
  该镜像 512704 B，是整份 `wifi` 镜像（1218736 B）的 42%。
  期间有过一次 `net_ethernet` 不过的运行（MAC 内部回环帧没收回），查明与板子和第五批无关：主机网口 `enp0s31f6` 在
  NetworkManager 里反复尝试激活一个已消失的配置、把链路来回拉低，而板侧只等 5 秒；主机网口链路稳定（激活实验配置、
  `10.42.0.1/24` 共享模式）之后同一条判据即通过。「该判据依赖主机链路稳定」由这一次对照即可说明，无单独对照实验。

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

- **OWE（RFC 8110）的范围**：只做 group 19（§4.3 规定必须支持的那一个）和 SHA-256 档。第三批交付时 §4.5 的 PMK caching、
  OWE Transition Mode、认证 / 关联状态机的接线都没做；PMK caching 已在第四批实现（取舍见本节末尾），后两样仍未做。
  DH Parameter element 按 RFC 8110 §4.3 的图 1 实现（Element ID 255、Element ID Extension 32；
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
  - RIC（13.11）：第三批只把 RIC-Request / RIC-Response 当作不透明的字节进 MIC、按元素个数进 Element Count；第四批起解析 RDE 与 Block Ack 的 RIC Descriptor（取舍见本节末尾）。
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
  - Extended Request 子元素（ID 11）与 Reporting Condition 5–10 的参考电平不做；RM Enabled Capabilities 元素与 Annex E 的映射
    第四批已做（收录范围见本节末尾）。量测本身（离信道、定时、随机退避）由调用方做。
- **WNM 的取舍**（`wnm.zig` 文件头同文）：
  - 候选表里有候选、但本端 BSS 表里一个都没见过时回 2（Table 9-357 的字面含义；11.24.7.4 规定 AP 收到 2 后应留出扫描时间）；
    hostap 同一情形回 7（`common/wnm_sta.c:710–713`）。
  - BTM Status 3 需要 BSS Available Admission Capacity / BSS Load，本端 BSS 表不存，判决模型不会产出 3。
  - TFS（11.24.12）在第三批不实现、原样透传，第四批起实现（取舍见本节末尾）。9.6.14.19 正文写 TFS Request Elements
    "contains one or more"，图 9-715 标的是 variable，本实现接受为空。
  - Key Data：第三批只保留长度字段与「该走 Key Data 还是组密钥握手」的判定；第四批起实现 GTK / IGTK 子元素的布局，加密是注入点（见本节末尾）。
  - 「2016 无明文、依据盘上 hostap」的两条：候选表条目没有 Preference 子元素时不算 excluded（2016 只说 Preference 为 0 即
    excluded；hostap `common/wnm_sta.c:337` 是 `preference_present && preference == 0` 才排除）；Accept 时 Target BSSID 总是
    6 个八位组，不知道目标时写 6 个 0（`common/wnm_sta.c:610–617` 引 P802.11-REVmc 的澄清）。

第四批（`owe.zig`、`ft_proto.zig`、`rrm.zig`、`wnm.zig` 的文件头同文）：

- **OWE 的 PMK caching（RFC 8110 §4.5）**：§4.5 只规定了线上的行为（client 的请求里必须同时带 PMKID 与 DH Parameter element；
  AP 命中时回同一个 PMKID、不带 DH Parameter element，未命中时忽略 PMKID、照常走 OWE；client 在命中、不匹配、请求没带 PMKID
  三种情形下的处理），**没有规定缓存的有效期、替换与挤兑**。实现的做法：
  - 缓存管理取自盘上 hostap 的 `rsn_supp/pmksa_cache.c`：同 PMKID 同 PMK 再次加入时复用旧条目、不刷新时间（186–194）；
    满了移除最早过期的条目（223–245、247–263，链表按过期时间升序）；过期判据是 `expiration < now`。期限常量取 802.11-2016 的
    `dot11RSNAConfigPMKLifetime`（DEFVAL 43200 秒），实际有效期由调用方注入。
  - 与 hostap 的两处不同：按 PMKID 索引（hostap 按认证者地址）；没有「使用中的 `cur_pmksa` 不挤掉」的概念。
  - RFC 没写、实现自己定的：`PmkNotCached`（client 发出了自己缓存里的 PMKID、AP 回了匹配的 PMKID，而 client 的缓存里已经没有这条）当作失败；
    `offerPmkid` 取最新的有效条目；`buildAssocRequestWith` 在 PMKID 非空而策略的 MFPC 为假时拒绝（`PmkidNeedsMfpc`），
    因为本组件的 RSNE 写法只在 MFPC 时写 Capabilities 与 PMKID 字段。
  - 照 hostap 而不是 RFC 的字面：AP 在命中时不要求请求里带 DH Parameter element（RFC 只用 MUST 约束 client 要同时带），
    并扫完请求里的整个 PMKID 列表；响应里有两个 PMKID 不算命中（`rsn_supp/wpa.c:3386–3389`）。
  - 缓存的入队（client 在 4 次握手完成后、AP 在派生新 PMK 成功后）由调用方做，`owe.zig` 只提供 `Cache.add`。
  - OWE Transition Mode 不在 RFC 8110 里（全文没有 "transition" 一词），它出自 Wi-Fi 联盟的 OWE 规范，盘上没有原文，未实现。
- **FT 的 RIC（13.11、9.4.2.50、9.4.2.51）**：
  - 只解析 Block Ack 一种描述符（表 13-3 的 Block Ack Parameters 行）；QoS（TSPEC / TCLAS）与 Vendor Specific 的描述符当不透明字节透传。
  - AP 的准入决策（13.11.3.2、图 13-29 的偏好顺序遍历）没有建模：`Ap.onThird` 只核对 MIC，并要求「请求带了 RIC-Request 就必须给
    RIC-Response、没带就不能给」（13.8.5），RIC-Response 的内容由调用方给。
  - `checkRicRequest`、`checkRicRequestBlockAck`、`checkRicResponse` 是给调用方选用的校验函数，两个角色的状态机对 RIC 的内容不做自动校验。
  - 9.4.2.50 说请求里 RDE 的 Status Code 字段是保留的（接收方忽略），13.11.3.1 说发送方置 SUCCESS（原文行 51220–51221 与 110265–110266）。
    `checkRicRequest` 按 13.11.3.1 把非零拒掉，但它只用在 FTO 一侧；AP 不用它去拒收请求。
  - 一条 RIC 里最多 16 个 RDE（`max_ric_entries`，实现常量）。
- **RM Enabled Capabilities 与 Annex E（9.4.2.45、11.11.6、Annex E）**：
  - 表 9-157 的保留位（36–39）解析时原样保留（往返不变），构造时非 0 拒绝。
  - Annex E 收录 106 行：全球 41（81–87、94–96、101–130、180）、美国 21、欧洲 15、日本 17、中国 12。有意不收录、一律
    `UnsupportedOperatingClass`：ITS 5.9 GHz（表 E-1 的 16–18、表 E-2 的 13a–16）、美国 4.9 GHz 公共安全（表 E-1 的 6–11）、
    日本已废弃的行与 4.9 GHz、DMG 地区类。
  - 与 hostap 的版本差：`common/ieee802_11_common.c` 的 124–127 类含 165–177（后续修订的信道），802.11-2016 原文只到 161 / 169 / 157 / 161
    （原文行 179019–179044），实现按原文。
  - 中心频率有两个公式：6 GHz 以下按 17.3.8.4.2 的式 (17-27)（起始频率 + 5 MHz × 信道号；信道间隔 25 MHz 与 40 MHz 的类也按 5 MHz 光栅算主信道）；
    DMG 的 180 类按 20.3.1（起始频率 + 信道间隔 × 信道号，56.16 GHz + 2160 MHz × n）。85–87 类没有起始频率（`StartFrequencyUndefined`）。
- **TFS 与 Key Data（11.24.12、9.6.14.15–.20）**：
  - AP 侧 `TfsApSta.onRequest` 有意宽松：元素头截断时给该元素回 Status 1 后停止，因为 AP 必须逐元素回应；STA 侧的解析严格。
  - AP「全部接受才提交」，部分拒绝时保留旧规则（11.24.12.2）。
  - 分类器参数一律按大端：类型 1 / 4 / 5 的原文有明说，类型 3（Filter Offset）的 Offset 原文没有明说，按同一约定处理。
  - Key Data 的加密是注入点 `KeyDataCodec`：本组件实现 GTK / IGTK 子元素的布局（图 9-717、图 9-718）、9.4.3 的顺序校验与
    「带不带 Key Data」的分支，测试只用逐字节异或的测试替身。9.6.14.20 的注 2（原文行 65621–65622）说 GTK / IGTK 更新靠管理帧保护
    来保密；真实的密钥封装与帧保护接线由调用方提供，本组件没有验证。
  - IDF 里的 hostap 把 TFS 与 WNM Sleep 的 GTK / IGTK 处理裁掉了，这一片没有独立实现可对拍。

第五批（`wnm.zig` 第 15–24 节、`gas.zig`、`blockack.zig` 的文件头同文）：

- **WNM 其余子域**，要点（逐条见 `wnm.zig` 文件头的偏离清单）：FMS 的 TCLAS Processing 元素可选
  （与 TFS / DMS 的 shall 不同）；GCR 子元素只认到 nibble（GCR 非目标）；Idle Options / QoS Flags 的保留位忽略，
  状态 / 类型表的保留段拒收；保活判决的余量由调用方注入（原文没有规定）；TIM Broadcast 的 STA 侧时间行为按
  11.2.3.17 的 TTTT 网格；CI 占空比只在 Interval 或 Burst Length 为 2³²−1 时有意义；11.24.2 写「without any Event Report
  element」与 9.6.14.3 的「one or more」冲突，按规程条款允许空帧；QoS Traffic Capability 元素按 9.4.2.78 的长度公式
  （Length = 1 + n）解析，`ac_sta_counts` 原样返回。已有代码没有改动（`wnm.zig` 的 diff 是 2145 行新增、6 行删除，
  删的是文件头里被改写的说明）。
- **Block Ack**：变体只做 Basic 与 Compressed（Extended Compressed / Multi-TID / VHT 1024 位 / Multi-STA / GCR 不做）；
  ADDBA Request 的 Fragment Number ≠ 0 按畸形拒收是实现选择（原文只约束发送方置 0）；重排缓冲的「过期丢弃」原文没有定义
  （实现给每条注入 expire_at）；记分板 respond() 固定取 SSN = WinStartR（允许区间的一端）；A-MSDU Length 的大端序只有
  规范依据（内核只有头文件，没有第二实现）。可选元素（GCR / Multi-band / TCLAS）按元素头跳过，只解 ADDBA Extension——
  与表 9-303 / 9-304 的顺序一致。
- **GAS / ANQP**：Multi-band 元素原样透传；重复片（Fragment ID < 已收上限）忽略整帧且不重置计时器——比 11.25.3.2.4 的
  字面要求严格（原文要求每收到一条 Comeback Response 都重置 `dot11GASResponseTimer`），理由是只会重发旧片的响应方
  otherwise 可以无限续命；这是防活锁的实现取舍，只在对方不合规时才有差别。95 在 Initial Response 里按终止失败处理；
  响应缓冲耗尽映射到 63；厂商协议 221 拒绝；GAS 的 Dialog Token 不要求非零（9.4.1.12 与 9.6.8.12 都没有 nonzero 的措辞）。
  不做：Annex R、RLQP、多 BSSID、响应方 / 服务器侧、Protected Dual of Public Action、ANQP 厂商元素内容、
  3GPP Cellular Network（不解码、原样透传）。

独立评审（2026-11-25）返修修掉的缺陷不列在偏离里——CI Report 元素宽度（Figure 9-427 的 21 八位组）、DMS Add 的
TCLAS Processing 反方向、GAS 失败路径的 Query Response Length 与空 Query List、Advertisement Protocol 的方向、
FMS / DMS 的长度封顶、CI 电平 +127 的封顶、Diagnostic 类型 0/1/2 的子元素、CI Request 保留 Report Timeout 的整帧拒收、
Emergency Call Number 的静默缺口——它们已是改正后的行为，经过见 §5.6；评审报告的存疑三条也照实保留在 §5.6。

## 7. 未验证

- 真实 AP 互通：WPA2-PSK + CCMP-128 已在用户提供的 AP 上连上并收发（§11）；SAE、OWE、FT、EAP-TLS、其余套件、多台 AP 与重连都没有证据。消息 3 与组密钥消息 1 的字段宽松度只在这一台 AP 上确认过。
- CCMP 与 GCMP 在 QoS 加四地址帧上的 30 字节 AAD 只有构造测试，没有官方向量。
- 现代真实 AP 的 Beacon（厂商特定元素、AID 高位）只在 2004 年的抓包里见过。
- 真实 AP 上的 SAE（WPA3 个人）互通；FT 的初始关联与快速切换；256 位套件（CCMP-256 / GCMP-256 / BIP 的 256 位与 GMAC 变体）的协商与互通。
- QoS 与省电的行为：真实 AP 的 Beacon TIM、PS-Poll 响应、DTIM 之后的组播次序、U-APSD 服务期；EDCA 参数对驱动的影响。
- 第二批的板侧自检已上板（§5.2）；板上只验证了判据本身，真实 AP 上的行为见上面几条。
- 真实 AP 上的 OWE、802.1X / EAP-TLS、SAE 的其它群、FT 的初始关联与快速切换、无线测量与 WNM（BTM、WNM Sleep Mode）：都没有证据；
  第三批只有主机测试、与独立实现的对拍和板侧自检。
- EAP-TLS 的 MSK 与 OpenSSL `SSL_export_keying_material()` 的逐字节一致（见 §6）。
- SAE 其它群里 FFC 大群的整链只在 ReleaseFast 的差分里对过。该片的板侧自检原先九个群全做双端对打，已收成只做 ECC 25
  （其余八个群只验群的参数）：当时依据的是主机 ReleaseFast 耗时（19–36 ms，对 `sae_full_selftest.zig` 的 12 ms；
  收窄后 2.4 ms），之后按 QEMU 的精确指令数量，收窄后是 3.74 亿条、板上约 4.7 秒（§5.4）；收窄之前的指令数没有量。
  实际内联后的栈只按序言静态估算过（§5.4）。板上的耗时与栈都没有量过。
- 第四批只有主机测试、与参照实现的对拍和板侧自检在主机上的运行，当时没有上板（2026-11-25 随第五批的镜像上板、全部通过）；真实 AP 上的 OWE PMK caching、带 RIC 的重关联、TFS、
  RM Enabled Capabilities 的协商都没有证据。
- OWE PMK caching 的缓存管理策略没有规范依据，取自 hostap 的源码；`KeyDataCodec` 的真实实现（密钥封装与管理帧保护）不在本仓库，没有验证。
- TFS 与 Key Data 没有独立实现对拍；RIC 的 AP 准入决策、QoS 描述符与 13.6 的资源请求协议没有做。
- 第五批的三片（WNM 其余子域、GAS / ANQP、Block Ack）与真实 AP 的互通**没有任何证据**；板级自检已随第五批的镜像上板
  （2026-11-25，`wifi_mlme` 121/121，§5.6），板上只验证了判据本身。真实射频通路的厂商栈对照见 §8。
- 第五批的差分不是独立实现对拍：三组的 Python 模型照同一份规范写，模型与实现同错时抓不出来（Block Ack 的窗口边界、
  NAI Realm 的字段顺序、CI Report 的八位组行与 CI 电平的值域端点是实际发生的四次，§5.6）；GAS 的 Status Code 若上游
  hostap 按 1 字节读，与本实现的 2 字节（9.4.1.9）不能互通 [INFERENCE]——本机没有 hostap 的 `gas.c` 可核对。
  评审报告的存疑三条（WNM Notification Type 0 子元素、QoS TC Update 的标志位视图、TIM Broadcast Request 的尾随字节）
  照实保留，未收口。
- 11.24.2 与 9.6.14.3 的「Event Report 元素个数为零 / 至少一」冲突按规程条款取空帧允许（§6）；重排缓冲的过期丢弃、
  保活判决的余量注入是原文没有规定的实现选择，真实 AP 的行为未验证。

## 8. 真实 AP 的对照（厂商栈，L4；属于路线图 R3「真实链路」，不属于第五批）

用官方 IDF 的最小 station（工程 `tools/wifi-idf-oracle/`，凭据走 menuconfig、不入库）在与本仓库同一块板上连用户提供的 AP：

- `esp_wifi_start` 返回 `ESP_OK`；`init -> auth -> assoc -> run`；`connected with hl-wifi, aid = 1, channel 1, BW20`；
  WPA2-PSK；`GOT_IP`（网关 `192.168.31.1`）；RSSI −28 dBm；ping 网关 5 发 5 收，从启动到拿到 IP 约 2.4 秒。
  日志 `logs/wifi-idf-oracle-sta.log`。主机自己的 Wi-Fi 在同一信道听到同一个 BSSID（旁证）。AP 的密码不进任何仓库或文档。
- ping 公网地址与经网关的 DNS 没通（这台 AP 没有上联，或不对 ICMP / DNS 转发）。
- **这是厂商栈的结果（L4），不是 `s31-firmware` 的结果**。它证明板子的射频、AP、认证与 DHCP 这条路是通的。
  本仓库自己的 Wi-Fi 当时停在 `esp_wifi_start` 等 MAC 忙位（`MAC_ST[15:13]`）清零——同一段 blob、同一个调用点，IDF 里清零、
  我们的运行时里不清。2026-11-25 靠逐时点的全量寄存器对照找到了根因并修复，见 §9。

## 9. 本仓库的 blob 移植：`esp_wifi_start` 首次返回（2026-11-25，L3）

§8 末尾留的问题已解决。做法是 §8 提的"逐时点对照"的全量版：与 oracle 在 `esp_wifi_init` 之后对照 SoC 头文件里
定义过的 523 个寄存器（`logs/wifi-idf-oracle-regdump-boot.log` 对 `logs/wifi-probe-regdump-before-boot.log`），
差集 95 个，再逐个做单变量实验。根因是裸机镜像没做 IDF 启动期 `pmu_init()` 里的一步：给三个 HP 电源模式写 modem 的
ICG 码并触发立即更新。码是复位值 0 时，时钟适配层写的门控位图 `0x6` 对不上，Wi-Fi MAC 的核没在跑。
完整的差集、实验表、机理与 IDF 源码出处见 `docs/adr/ADR-001-wifi-blobs-cooperative-yield.md` 文末；
修复在 `boards/esp32s31-coreboard/src/pmu.zig`。

板侧读数（Wi-Fi 探针，`logs/wifi-probe-start-rc0-boot.log`）：

```text
wifi-init-probe: pmu modem ICG code 0->2 (2 = active)
wifi-init-probe: after-init MAC_ST=0x00000000 (init_rc=0)
wifi-init-probe: esp_wifi_start rc=0x0 (idle_calls=22)
```

边界：

- 只到 `esp_wifi_start` 返回。这是 blob 边界（`wifi-blobs`）的板侧证据，不是 `wifi-mlme` / `wifi-connect` 的：
  扫描、连接、与本仓库自己的 RSNA 实现对接都没有做；与真实 AP 的互通（L4）仍然只有厂商栈的证据。
  （扫描已于 2026-11-26 上板，见 §10。）
- BLE 侧不能接同一步骤（探针锁死），读数在 `docs/verification/coex-verification.md` §11。

## 10. 本仓库的 blob 移植：首次扫描到真实 AP（2026-11-26；真射频，与 oracle 对照，没有抓包）

§9 之后的下一步：`esp_wifi_start` 之后发起主动扫描。探针是 `-Dwifi-link-probe`（`components/wifi-blobs/src/link_probe.zig`）。
上一轮扫描能逐信道走完但恒为 0 个 AP，原因有两处。走到这一步之前还拆过两道更早的闸——国家码 / 信道表是零值桩、
软件定时器表只有 16 项——与下面两处修在同一个提交里，记在 `CHANGELOG.md`。

**【2026-11-26 更正】这两处之前还有一个前提：共存核必须启动。** 这一节的板侧读数和之后的每一轮都开着 `-Dcoex`（共存胶水加
`libcoexist.a` 的真核心）。同一份探针只把 `-Dcoex` 关掉，扫描又是 0 个 AP、连接 `reason=201`，两轮相同：不开共存核时 MAC 不收帧，
有文档的寄存器里共存低功耗时钟的配置（`MODEM_LPCON_COEX_LP_CLK_CONF`）与 `DCMEM_VALID_*` 都是 0。所以扫描通到真实 AP 的条件是
三样——共存核已启动、APM 过滤器已关、supplicant 回调表已登记；后两处各自的单变量实验都是在共存核开着时做的。证据见
`coex-verification.md` §13。

**其一：APM 访问控制过滤器。** IDF 的应用在启动期调 `bootloader_init_mem()`，其中把三条访问路径的控制过滤器关掉：
`LP_APM_FUNC_CTRL`（0x20706CBC）、`HP_APM_FUNC_CTRL`（0x205044C4）、`HP_MEM_APM_FUNC_CTRL`（0x205048C4）写 0
——对照镜像 ELF 里这个函数的反汇编开头正好是这三条写 0。这三行在二级 bootloader 里被 `#if !BOOTLOADER_BUILD` 跳过，
所以由同一个 bootloader 加载的裸机镜像必须自己做。复位值 `0x0F` / `0x7F` / `0x3F` 只放行 TEE master；Wi-Fi MAC 的 DMA
属 REE，射频收到的帧写不进内存，且不报 bus error——与 ch17 以太网 DMA 不取描述符是同一个根因。
修复：`boards/esp32s31-coreboard/src/apm.zig`（写 0 并读回），`initOnly()` 开头调用。

**其二：supplicant 回调表是空指针。** IDF 的 `esp_wifi_init()` 收尾调 `esp_supplicant_init()`（`wifi_init.c:512`），
把一张 `struct wpa_funcs` 登记给 blob（`esp_wifi_register_wpa_cb_internal` 就是 `g_ic->[444] = cb`）。镜像里没有 IDF 的
`wpa_supplicant` 组件，这一步没人做。关掉过滤器之后第一帧 beacon 就让驱动崩在 `scan_add_ssid_do`：
`load access fault`、`mtval=0x54`——那里读 `g_ic->[444]->wpa_sta_rx_mgmt`（偏移 84），连表指针都不判空。
定位：`objdump -dr` 扫 blob 各目标文件里 `lw x,444(y)` 之后读的字段，偏移逐一与 IDF 头文件 `struct wpa_funcs`
（`wpa_supplicant/esp_supplicant/src/esp_wifi_driver.h:138`）对上；oracle 的链接 map 显示这些入口在 IDF 里来自
`esp-idf/wpa_supplicant/libwpa_supplicant.a`。
修复：`components/wifi-blobs/src/wpa_cb.zig` 登记自己的表。blob 里读这张表的地方有几十处，其中
`wifi_station_start`（字段 0 `wpa_sta_init`）、`wifi_station_stop`（字段 4 `wpa_sta_deinit`）只判表指针、不判字段，
`ieee80211_sta_new_state` 进 INIT 态时（字段 16 `wpa_sta_disconnected_cb`）连表指针都不判——扫描结束的 SCAN → INIT
也会走到。现在填了四个：

- `wpa_sta_init` / `wpa_sta_deinit` / `wpa_sta_disconnected_cb`：IDF 的 `wpa_attach()` / `wpa_deattach()` /
  `wpa_sta_disconnected_cb` 的对应物，驱动 `wifi-connect` 的 `Supplicant`（初始态、没有密钥；握手超时等 11 个原因码下
  丢掉安全关联并清认证方地址）。本项目不做 PMKSA 缓存，所以其余原因码下不动。
- `wpa_parse_wpa_ie`：`wpa_parse_wpa_ie_wrapper` 的移植（RSN / WPA / RSNX / WAPI / 厂商形式 RSNE 的分派与解析，
  套件选择器 → supplicant 内部位 → 公共 `wifi_cipher_type_t`）。blob 的扫描代码拿它判每个 AP 的 authmode，所以位值全部
  抄 IDF 的 `defs.h`；编译开关取对照镜像的 `compile_commands.json`（`IEEE80211W`、`WPA3_SAE`、`GMAC`、`OWE_STA`、
  `WPA3_COMPAT` 开，`IEEE80211R`、`SUITEB`、`SUITEB192`、`GCMP`、`DPP` 关）。

主机用例 13 项（`wpa_cb.zig`）。

板侧读数（`logs/wifi-link-scan-boot.log`，`-Dcoex` 开着，它是前提，见本节开头的更正；入库的日志是脱敏副本，除用户自己的 AP
`hl-wifi` 外，邻居的 SSID 与 BSSID 换成了标签，信道、RSSI、authmode 是原值）：

```text
wifi-init-probe: apm ctrl filters LP/HP/HP_MEM: 15/127/63 -> 0/0/0 (0 = off)
wifi-init-probe: wpa cb register rc=0 g_ic[444]=0x2f0158bc table=0x2f0158bc
wifi-init-probe: _phy_enable(modem=0) -> register_chipv7_phy rc=0; cal_data: version=100 mac=1c:29:04:d1:99:28 nonzero=263/1904 ...
wifi-link-probe: esp_wifi_start rc=0x0 (hooks=227, events=2)
wifi-link-probe: esp_wifi_scan_start(NULL, nonblock) rc=0x0
wifi-blob: Send scan done event: status=0, apnum=38
wifi-link-probe: wait scan-done 10s -> GOT in 9079 ms (hooks=2296, events=3)
wifi-link-probe: esp_wifi_scan_get_ap_num rc=0x0 n=38
wifi-link-probe: esp_wifi_scan_get_ap_records rc=0x0 got=38
```

与 oracle 的对照。oracle 是同一块板上跑的官方 IDF 最小 station（`tools/wifi-idf-oracle/`），它的扫描日志没有入库。
本镜像一侧取自入库的日志，oracle 一侧是同一时段（相差约四个小时）的读数：

| SSID | BSSID | 信道（oracle / 本镜像） | RSSI（oracle / 本镜像） | authmode（oracle / 本镜像） |
| --- | --- | --- | --- | --- |
| `hl-wifi` | `44:f7:70:16:fa:ba` | 1 / 1 | -29 / -29 | WPA2_PSK / 3 |
| ssid-01 | ap-01 | 2 / 2 | -37 / -38 | WPA/WPA2_PSK / 4 |
| ssid-02 | ap-02 | 4 / 4 | -43 / -42 | WPA/WPA2_PSK / 4 |
| ssid-03 | ap-03 | 8 / 8 | -52 / -53 | WPA/WPA2_PSK / 4 |
| ssid-04 | ap-04 | 2 / 2 | -55 / -54 | WPA/WPA2_PSK / 4 |
| ssid-05 | ap-05 | 5 / 5 | -63 / -61 | WPA/WPA2_PSK / 4 |
| ssid-06 | ap-06 | 11 / 11 | -59 / -62 | WPA/WPA2_PSK / 4 |
| （oracle 列表里第 7 个） | — | 10 / — | -62 / — | WPA2_PSK / 本镜像这一轮没扫到（此前两轮扫到：-62、-63 dBm，authmode 3） |

`wifi_auth_mode_t`：3 = `WPA2_PSK`，4 = `WPA_WPA2_PSK`。oracle 看到的 8 个 AP 里 7 个一致（信道、authmode、SSID 相同，
RSSI 差 1–3 dB）；第 8 个（-62 dBm）这一轮没扫到，此前两轮扫到过。连续 5 次上板扫描全部完成，每次 32–41 个 AP；
oracle 自己那一次是 36 个。

边界：

- 这是 blob 边界的板侧证据，不是 `wifi-mlme` / `wifi-connect` 的协议证据：扫描完全由 blob 做，`wifi-connect` 只提供了
  回调里的 IE 解析与请求方的生命周期。没有抓包，真射频收发已通的证据是与 oracle 的结果一致。
- 连接与收发已于同日上板（§11）。公开入口 `esp_wifi_connect` / `esp_wifi_disconnect` 仍是 `link_stubs.zig` 里的计数桩，探针调的是驱动的内部入口。
- PHY 标定数据不持久化：探针每次启动全量标定。与用对照镜像存在本板的标定数据（PARTIAL）对照过，31 个共同 AP 的
  authmode / 信道全部相同、RSSI 平均差 0.3 dB，全量只多约 30 ms。

## 11. 本仓库的 blob 移植：连上真实 AP 与数据通路（2026-11-26；WPA2-PSK + CCMP-128）

§10 之后探针（`-Dwifi-link-probe`，构建时另给 `-Dwifi-ap-ssid` / `-Dwifi-ap-password`，凭据不入库）继续往下走：
连接 → 核对 MAC 密钥表 → 数据通路（DHCP + ping 网关）→ 再泵 5 秒 → 断开。

**连接（路线图 R3.2.2）。** 认证、关联与帧的收发都由 blob 做，这里只补请求方的逻辑，分工照 IDF
（`components/wifi-blobs/src/wpa_cb.zig` 中段）。回调表从 4 项填到 12 项：

- `wpa_sta_connect`：驱动选好 BSS 后调它。请求方（`wifi-connect` 的 `Supplicant`）按 AP 的 RSNE 选 AKM 与套件、
  由口令算 PMK、把本 STA 的 RSNE 交给驱动放进关联请求。范围只有 RSN + PSK：选出来的 AKM 不是 PSK 就拒绝，
  WPA v1、企业、SAE、OWE、FT、DPP 都没接。
- `wpa_sta_connected_cb`：关联成功，AUTHENTICATION → STAKEYSTART。
- `wpa_sta_rx_eapol`：AP 的每一帧 EAPOL-Key。回应（消息 2、消息 4、组密钥消息 2）经 `esp_wifi_internal_tx()` 发出；
  钥匙等消息 4 的「发送完成」回调才装进驱动（`esp_wifi_set_sta_key_internal`、`esp_wifi_set_igtk_internal`）。
- 协商完成要单独告诉驱动一次（`esp_wifi_auth_done_internal()`）。少了它，请求方手里钥匙都齐了，驱动照样在
  10 秒后以 204（`4WAY_HANDSHAKE_TIMEOUT`）去关联。
- `wpa_sta_in_4way_handshake`、`wpa_config_parse_string`、`wpa_config_done`、`wpa_sta_clear_curr_pmksa`、
  `wpa_config_reload`：blob 在这条路径上要读的其余几项。

主机用例（`wifi-blobs` 的 `wpa_cb.zig`）拿已知答案走完整条握手：三帧回应逐字节相同、钥匙在消息 4 发送完成之后才装、
组密钥换钥匙、装不进驱动时不回确认。`wpa_sta_rx_eapol` 的返回值按 IDF 的约定（处理了 1、解不开的帧 0、校验不过 -1）：
驱动在这个调用点只拿返回值选一条日志，此前返回的是发送结果（成功为 0），板上每一帧处理成功的握手日志都是
`wpa_psk handle fail`。

这一步修掉的四处都在运行时，不在协议侧：

1. **Wi-Fi 任务栈按 blob 报的尺寸给，长了过界。** blob 只建一个任务（`wifi`，请求 6656 字节），四次握手实际用 9252 字节——
   请求方是本仓库自己的代码，它用多少栈 blob 不知道。修复前的现场是握手完成后 `store access fault`，以及停在断点上、
   返回地址与栈帧里是 `0xff00ffff`、`0xff000000` 这类值（`logs/wifi-link-connect-crash-boot.log`、`logs/wifi-link-connect-watchpoint-boot.log`，
   都只留了从 `esp_wifi_set_config` 起的一段；停机现场里栈与通用寄存器的原始转储入库前已删，只留 `mepc` / `mtval` / `cause` / `ra` / `sp`）。修法在 `osi_impl.zig`：栈的下限 16 KiB（实测用量的 1.7 倍），栈底下留
   256 字节护栏、泵每一步查一次；探针每次报进度都打各任务栈的高水位。
2. **`esp_wifi_set_config` 把 STA 配置逐字段写成四十多个 NVS 键**，原先每个槽自带 2048 字节的 RAM 版 NVS 装不下，
   驱动回 `0x1105`。`nvs_ram.zig` 改成键表加分档的 blob 池。
3. **`memcpy` 用的是 compiler_rt 的逐字节循环**，而 blob 装钥匙的 MAC 密钥表是整字寄存器堆：每 4 个字节只剩最后 1 个。
   握手照常完成、驱动也报成功，数据帧却双向都解不开——连上之后 DHCP 12 秒没有应答，一帧都没收到。探针为此加了一项
   核对（MAC 密钥表里成对钥匙与组钥匙那两格，对请求方手里的钥匙逐字节比，只打位图）。`rom_syms.ld` 把
   `memcpy` / `memmove` / `memset` 用赋值（不是 `PROVIDE`）指到 ROM 的实现之后才对得上；修复前的一段在
   `logs/wifi-link-connect-badkeys-boot.log`，密钥表那几格的位图是 `ffff, 8fff, 88ff, 888f, 8888, 0888, 0088`
   （那一段日志当时还带着一份密钥表的原始转储，入库副本里已删）。
4. **数据通路不答 ARP 请求**，见下。

板侧读数（`logs/wifi-link-connect-boot.log`，`-Dcoex` 开着；入库的是脱敏副本，除用户自己的 AP `hl-wifi` 外，
邻居的 SSID 与 BSSID 换成了标签）：

```text
wifi-link-probe: esp_wifi_set_config(sta) rc=0x0 (ssid 7 B, password 8 B, pmf off)
wpa: connect: pairwise=4 group=4 akm=2 mfp=false sta_rsne=28 B appie rc=0
wifi-blob: state: init -> auth (0xb0)
wifi-blob: state: auth -> assoc (0x0)
wifi-blob: state: assoc -> run (0x10)
wpa: eapol rx msg 1 (99 B) -> tx msg 2 (127 B) rc=0
wifi-blob: wpa_psk handle succeed
wpa: eapol rx msg 3 (155 B) -> tx msg 4 (99 B) rc=0
wifi-blob: wpa_psk handle succeed
wpa: keys installed after msg 4: ptk rc=0, group keys rc=0, port truevalid
wifi-link-probe: STA_CONNECTED bssid=44:f7:70:16:fa:ba ch=1 authmode=3 aid=1
wpa: key negotiation complete: esp_wifi_auth_done_internal -> true
wifi-link-probe: CONNECTED in 3031 ms (1 progress reports)
wifi-link-probe: supplicant[connected]: state=STAKEYSTART phase=ptk_done msg4_in_flight=false negotiation_done=true pmk=true ptk=true gtk=true rejects=0 last_error=-
wifi-link-probe: stacks[connected]: 0:wifi=9252/16384
wifi-link-probe: key table entry 4 (pairwise TK): equal bits vs tk=ffff vs gtk=0000 (nonzero=ffff)
wifi-link-probe: key table entry 0 (group GTK): equal bits vs tk=0000 vs gtk=ffff (nonzero=ffff)
```

`pairwise=4 group=4 akm=2` 是驱动的 `wifi_cipher_type_t` / `wifi_auth_mode_t` 位值：CCMP 与 PSK。`sta_rsne=28 B` 是本 STA 的
RSNE 元素的真实长度（探针把管理帧保护配成不通告，没有 PMKID 列表）。

**数据通路（路线图 R3.2.3）。** 新增 `components/wifi-blobs/src/data_path.zig`：连上之后用 `esp_wifi_internal_reg_rxcb`
登记收帧回调——回调跑在驱动的 Wi-Fi 任务里，只做过滤、拷进环形缓冲、交还驱动缓冲；帧由主上下文的 `poll()` 处理。
IP 一侧是 `net-ipv4`（ARP / ICMP / IPv4）与 `net-udp-dhcp-dns`（DHCP）。没有路由表、没有 socket：地址靠 DHCP 拿
（含续租、重绑、到期），ping 的对象是租约里的网关。

**第四处：ping 网关时通时不通**（0/10 与 9/10 都出现过），DHCP 一直正常。收帧记录显示网关在每一帧回显请求之后都先用
ARP 请求来问本机的 MAC，本机没有答——`handleArp` 当时只处理 ARP 应答。对端的邻居缓存里碰巧还有本机时才通。
IP 主机必须答问自己地址的 ARP 请求（RFC 826），厂商栈也这么做。修法：`handleArp` 加上应答（单播给问的人），
并加了主机用例。修复前的一段在 `logs/wifi-link-connect-noarp-boot.log`。

```text
wifi-link-probe: data path: esp_wifi_internal_reg_rxcb rc=0x00000000
wifi-link-probe: net: dhcp DISCOVER attempt=0 tx rc=0x0
wifi-link-probe: net: dhcp OFFER ip=192.168.31.151 -> REQUEST tx rc=0x0
wifi-link-probe: net: dhcp ACK: bound ip=192.168.31.151 mask=255.255.255.0 router=192.168.31.1 dns=192.168.31.1, esp_wifi_internal_set_sta_ip rc=0x0
wifi-link-probe: data path: DHCP bound in 105 ms ip=192.168.31.151 router=192.168.31.1
wifi-link-probe: net: ping seq=0 tx rc=0x0
wifi-link-probe: net: arp answered 192.168.31.1 (44:f7:70:16:fa:b8) tx rc=0x0
wifi-link-probe: net: ping done: sent=10 received=10 timed_out=0 rtt min/avg/max=13103/23077/30179 us
wifi-link-probe: data path: frames rx=13 (ignored 0, dropped 0) tx=13 (failed 0)
wifi-link-probe: stayed connected for 5 s
wifi-link-probe: esp_wifi_disconnect_internal -> DISCONNECTED reason=8
```

修复之后的四轮（前两轮还没有 `wpa_sta_rx_eapol` 返回值的更正与共存读数，那两处不碰数据通路）：

| 轮 | 连上 | DHCP 拿到地址 | ping 网关 | 网关来问 ARP |
| --- | --- | --- | --- | --- |
| 1 | 3037 ms | 82 ms | 10/10，rtt 最小 / 平均 / 最大 13.0 / 22.6 / 46.4 ms | 1 次 |
| 2 | 2994 ms | 141 ms | 10/10，12.6 / 19.0 / 23.9 ms | 1 次 |
| 3 | 3017 ms | 129 ms | 10/10，13.1 / 22.5 / 30.2 ms | 1 次 |
| 4（入库的那一份） | 3031 ms | 105 ms | 10/10，13.1 / 23.1 / 30.2 ms | 1 次 |

网关什么时候来问不固定（第 1 帧回显之后或第 6 帧之前），取决于它那边的邻居缓存。

边界：

- 一台 AP、一种配置（WPA2-PSK + CCMP-128、信道 1；管理帧保护双方都通告，这次没用上）。SAE、OWE、FT、企业、其余套件、
  多台 AP、漫游、断线重连、长时间稳定性都没有做，连上之后只观察了 5 秒。
- 没有抓包：握手与数据帧在线上的内容没有看过。证据是 AP 的回应（关联成功、四次握手走完、DHCP 应答、回显应答）与
  MAC 密钥表的核对。
- 数据通路只有 DHCP 与 ICMP。TCP、TLS 还没有接到这条链路上，吞吐与丢包没有量。
- PHY 标定数据仍不持久化。
- 同一次运行里共存核开着的读数见 `docs/verification/coex-verification.md` §12。
