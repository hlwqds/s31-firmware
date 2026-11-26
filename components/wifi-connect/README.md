# wifi-connect — Wi-Fi 连接管理

扫描/连接状态机、PSK/PMK → PMKID → PTK、RSNA 请求方（4 次握手与组密钥握手）、
密钥数据封装（AES Key Wrap）、安全关联与密钥管理状态机、RSNA 策略选择、
管理帧保护与 SA Query、每帧保护（CCMP-128 / GCMP-128 / BIP-CMAC-128）；
第二批加入 SAE 完整协议（group 19）、FT 密钥派生层、256 位套件（CCMP-256 / GCMP-256 / BIP-CMAC-128 /
BIP-GMAC-128 / BIP-GMAC-256、256 位 KEK、表 12-8 的 Key MIC 与 Key Descriptor Version）；
第三批（2026-11-25）加入按 AKM 的 4 次握手（`akm.zig`：AKM 1–6、8、9、11–13、18）、OWE（RFC 8110）、EAP-TLS 的 EAP 层
（RFC 5216 / RFC 3748）、SAE 的其余 14 个群、FT 协议（`ft_proto.zig`）；第四批（2026-11-25）加入 RFC 8110 §4.5 的
OWE PMK caching（`owe.zig` 的 `Cache`、`clientCacheDecision` / `apCacheDecision`）与 FT 快速切换里的 RIC（`ft_proto.zig` 第 5b 节：
RDE 与 Block Ack 的 RIC Descriptor、一条 RIC 的结构规则）。

- 主机测试：**431 项**（2026-11-25，`zig test src/host_tests.zig`；第一批 57 项，第二批加到 141 项，第三批加到 386 项，第四批加到 431 项。
  其中有 10 项是在主机上执行十份板侧子自检：`sae_full_selftest` 24 条、`suite256_selftest` 22 条、`ft_selftest` 13 条、
  `owe_selftest` 18 条、`eap_selftest` 8 条、`supp_akm_selftest` 19 条、`sae_groups_selftest` 33 条、`ft_proto_selftest` 12 条、
  `owe_cache_selftest` 12 条、`ft_ric_selftest` 10 条）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 `check:` 行与 `checks: passed=N failed=M total=N+M`；
  199 条判据（第一批 28 条，第二批 87 条，第三批 177 条，第四批 199 条）。上过板的是前两批的 87 条：2026-11-24 随 `wifi` profile
  上板，`wifi_connect` 87/87（该日志文件已被 2026-11-25 那次 pass 运行覆盖）；第三批、第四批之后是 177、199 条，**当时没有上板**
  （2026-11-25 随第五批的镜像上板：`wifi_connect` 199/199 全过，见「待验证项」）
- 依赖方向：逻辑模块只 import `std` 与同组件文件；仅 `selftest.zig` import `boards` 的 `board`（只用 `board.log`）
- 不依赖其它组件，不做 802.11 帧编解码（归 `wifi-mlme`）；P-256 点运算在本组件的 `ecc.zig` 里
  （群运算用 `std.crypto.ecc.P256`）

## 范围与来源

规范文本：IEEE Std 802.11-2016（下文页码为印刷页码）、RFC 3394、RFC 4493、RFC 6070；
第三批另涉 RFC 8110、RFC 5869、RFC 5903、RFC 6090、RFC 5216、RFC 3748、RFC 2409、RFC 3526。
每条 `per <clause>` 都对着本次会话读过的原文。

| 范围 | 条款（印刷页） |
| --- | --- |
| PSK、PMKID、PTK、GTK 派生 | J.4.1（3416–3417）、12.7.1.2（2008）、12.7.1.3（2009–2011）、12.7.1.4（2011） |
| EAPOL-Key 帧与 Key Information | 12.7.2（2018–2026）、表 12-4（2021）、表 12-5（2022）、表 12-8（2027） |
| KDE：GTK / PMKID / IGTK、填充 | 12.7.2 j)（2023–2026），图 12-34…12-42，表 12-6 |
| 4 次握手（请求方） | 12.7.6（2029–2037） |
| 组密钥握手（请求方） | 12.7.7（2040–2043） |
| 请求方密钥管理状态机 | 12.7.10（2062–2064，图 12-49） |
| 安全关联 PTKSA / GTKSA / IGTKSA | 12.6.1.1（1982–1987）、12.6.18（2001–2002） |
| RSNA 选择与策略 | 12.6.2、12.6.3（1991–1992，表 12-2），9.4.2.25（882–890） |
| 管理帧保护 | 12.2.7、12.2.8（1927）、12.6.19、12.6.20（2002–2003），表 9-47（736–737） |
| SA Query | 11.14（1745–1746）、9.6.10（1210），表 9-331 |
| CCMP-128 | 12.5.3（1967–1974），表 12-1 |
| GCMP-128 | 12.5.5（1977–1982） |
| BIP-CMAC-128 与 MME | 12.5.4（1974–1977）、9.4.2.55（941） |
| 帧头字段（本组件的局部解析） | 9.2.2（636）、9.2.3、9.2.4.1（638–640）、9.2.4.5（648）、9.2.4.6 |
| AES Key Wrap | RFC 3394 §2.2.1、§2.2.2、§4.1 |
| AES-128-CMAC | RFC 4493 §4（= J.8，3426） |
| SAE：PWE 派生（hunting and pecking） | 12.4.4.2.2（1937–1939）；Annex J.10（3429–3430） |
| SAE：rand / mask、Commit 构造、对端 Commit 校验、K 与 k | 12.4.5.2–12.4.5.4（1942–1943） |
| SAE：keyseed / KCK / PMK / PMKID 与 Confirm | 12.4.5.4–12.4.5.6（1943） |
| SAE：帧体编解码 | 12.4.7（1944–1946）；表 9-36（713–715）；表 9-46（732–735） |
| SAE：协议实例状态机、父进程、Anti-Clogging | 12.4.6（1943–1944）、12.4.8（1947–1953）；Annex C 的 MIB 默认值（2840） |
| ECC 群 19 的元素运算与编解码 | 12.4.4.2（1937–1938）；12.4.7.2.4 / 12.4.7.2.5 |
| KDF（FT 与 SAE 共用） | 12.7.1.7.2（2016）；RFC 4231 §4 |
| FT 密钥层次：XXKey、PMK-R0 / PMK-R0Name、PMK-R1 / PMKR1Name、PTK / PTKName | 12.7.1.7（2014–2018）；13.4.2（2092–2094）；表 9-133 |
| Key Descriptor Version 与表 12-8 的算法 | 12.7.2 b) 1)（2019–2020）；12.7.3（2027）；表 12-8（2027）；12.7.2 h)（2022）、j)（2023–2024） |
| 256 位套件：CCMP-256 / GCMP-256 / BIP-GMAC-128 / BIP-GMAC-256 / BIP-CMAC-256 | 12.5；表 12-4；9.4.2.55（941）；9.4.2.25.3（888）；表 9-131（884–885） |
| 按 AKM 的 4 次握手：PMK 长度、PTK 的 PRF / KDF、KCK / KEK、MIC、Key Data 封装、Key Descriptor Version、PMKID 的来源、能否与密码套件合用 | 12.7.1.2（2008）、12.7.1.3（2009–2011）、12.7.1.7（2014–2018）、12.7.2（2018–2026）；表 9-133（886–888）、表 12-4（2021）、表 12-8（2027）、9.4.2.25.3（888） |
| SAE 的其余 14 个群（FFC 2、5、14–18；ECC 20、21、25、26、28–30）、群协商、Password Identifier 与 Rejected Groups 元素 | 12.4.4.1、12.4.4.3、12.4.5.2–12.4.5.5、12.4.7.2、12.4.8.6.3–.4；RFC 2409、RFC 3526。两个元素不在 2016 正文里，依据 hostap 的源码（逐处行号见 `sae_groups.zig` 文件头） |
| FT 协议：MDE / FTE 编解码、认证序列（over-the-air、over-the-DS）、reassociation | 13.5、13.7、13.8；9.4.2.47–9.4.2.48；9.6.9；9.3.3.8–.12；表 9-159 |
| OWE：群 19 的 ECDH、DH Parameter element、PMK / PMKID | RFC 8110 §4.1–§4.4；RFC 5869 §2.2–2.3；RFC 5903、RFC 6090；12.6.3 |
| EAP-TLS 的 EAP 层：EAP 头、Identity / Notification / Nak、Flags、分片与重组、MSK → PMK | RFC 3748 §4、§5；RFC 5216 §2.1、§2.3、§3 |
| OWE 的 PMK caching：请求里同时带 PMKID 与 DH Parameter element、AP 命中与未命中、client 命中 / 回退 / 忽略三种处理、缓存条目与过期 | RFC 8110 §4.5、§4.3；9.4.2.25（PMKID List）。缓存管理（替换、挤兑、过期判据）RFC 没有规定，取自盘上 hostap 的 `rsn_supp/pmksa_cache.c`；期限常量取 `dot11RSNAConfigPMKLifetime` 的 DEFVAL |
| FT 的 RIC：RDE 与 RIC Descriptor（Block Ack）编解码、一条 RIC 的结构规则、进重关联帧的条件 | 9.4.2.50、9.4.2.51（图 9-322、图 9-323、表 9-161）；13.11.2、13.11.3.1、13.11.3.2；13.7.1、13.8.5；表 9-30 注 14；图 9-314 |

**非目标**：802.11 帧的完整编解码（`wifi-mlme`）、TKIP、WEP、Key Descriptor Version 1（HMAC-MD5 与 ARC4）、
TLS 本身（EAP-TLS 的 TLS 引擎由调用方注入）、R0KH→R1KH 的 PMK-R1 分发与 R0KH / R1KH 之间的协议、13.6 的 FT 资源请求协议、
RIC 的 QoS（TSPEC）描述符与 AP 的准入决策、SAE 的 H2E 与恒定时间实现、FFC 1、22–24 与 ECC 27、31–34、
OWE 的 group 19 以外的群与 OWE Transition Mode（不在 RFC 8110 里）、AKM 7（TDLS）与 10（PeerKey/SMK）、扩展 Key ID、QMF、DMG、
GCR、A-MPDU/A-MSDU 重排。

## 验证状态

下面的命令在 x86_64 主机上跑过；空中接口没有任何抓包。

- L3 板侧：第一批 28 条判据于 2026-11-24 随 `wifi` profile 上板一次，自检 28/28（`checks: passed=28 failed=0 total=28`）。
  日志 `logs/wifi-selftest-prefix-boot.log`（该次运行的整体判决因别的 section 失败而是 fail）。
  第二批加到 87 条之后于同日重新上板：`wifi_connect` `checks: passed=87 failed=0 total=87`，整份判决 14/14 段、
  `main: verdict=pass`（`logs/e2e-wifi-boot.log`，命令 `BOARD=/dev/ttyUSB0 python3 tests/e2e/run_e2e.py --board --profile wifi`）。

| 命令 | 结果 |
| --- | --- |
| `zig test src/host_tests.zig` | 431/431 通过（2026-11-25，第四批之后） |
| `zig fmt --check src/` | 干净 |
| `zig test -target riscv32-linux-musl -fno-emit-bin src/host_tests.zig` | 只编译、不链接：通过（证明能过 32 位 RISC-V 的语义分析） |
| 板侧自检在主机上执行（桩 `board` 模块 `/tmp/selftest-host/board_stub.zig`） | 2026-11-25（第四批）：`checks: passed=199 failed=0 total=199`，最长一行 140 字节（原 28 条时是 28/28、125 字节；第二批新增三份子自检的最长一行分别是 75、55、60 字节，第三批新增五份是 87、57、55、91、77 字节，第四批新增两份是 128、62 字节，都低于 `board.log` 的 200 字节上限，这一条同时是 10 条主机用例的断言） |
| 以固件参数交叉编译自检（`zig build-obj`，目标参数写在第一个 `-M` 之前，`-Mboard` 指向真板的 `board.zig`，根文件带目标架构守卫） | 2026-11-25：通过，整份自检 199 条（命令全文与一次假绿的更正见 `docs/verification/wifi-ieee80211-verification.md` §5.1、§5.4、§5.5） |
| 对 `/tmp/s31-oracle/suite256_oracle.py` 的全量差分（一次性驱动 `/tmp/s31-oracle/s256diff/diff.zig`，2026-11-24 复跑） | 14 组 3568 条向量、3928 项比较，0 不一致 |
| 参照实现自检（2026-11-24） | `wifi_oracle.py selftest` 223 PASS、1 KNOWN；`suite256_oracle.py selftest` 253/253；`ft_oracle.py selftest` 51 pass、2 known；`sae_oracle.py selftest` 的 P-256 与 `cryptography` 在 10 个点上一致 |
| 第三批的差分（2026-11-25 复跑；逐项数字见 `docs/verification/wifi-ieee80211-verification.md` §4.4） | OWE 800 组向量 15200 项比较、EAP-TLS 分片 1200 条记录流与 PMK 4096 组、按 AKM 握手四个种子各 2800 条命令的三方对拍、SAE 15 个群 1500 组整链、FT 协议四个种子各 12000 帧，全部 0 不一致 |
| 第三批的参照实现自检（2026-11-25） | `owe_oracle.py selftest` 44 项 0 失败；`akm_oracle.py selftest` 1065/1065；`sae_groups_oracle.py selftest` 160 PASS；`ft_proto_oracle.py selftest` 45 项 0 失败 |
| 第四批的差分（2026-11-25 主代理重跑；细目见 `docs/verification/wifi-ieee80211-verification.md` §4.5） | OWE PMK caching 的缓存策略对 Python 模型两个种子各 400 组，0 不一致（策略模型对拍，不是规范向量）；FT RIC 的完整交换（over-the-air 与 over-the-DS 各一条）六帧、两个 MIC 与 KCK 对独立 Python oracle，逐字节一致 |
| 第四批新增子自检的尺寸与指令数（riscv32 ReleaseSmall；指令数在 QEMU 上数） | `ft_ric_selftest`：text 2802 B、26181 条 rv32 指令；`owe_cache_selftest`：text 12331 B、104108 条 rv32 指令 |

差分用的向量由 `wifi_oracle.py vectors --seed {1,7,42,3,9} --count 24` 生成，落在可比范围内的条数：
psk 120、prf 120、ptk 37、pmkid 120、gtk 51、key_wrap 48、key_unwrap 96、ccmp_encapsulate 43、
ccmp_decapsulate 98、gcmp_encapsulate 41、gcmp_decapsulate 96、bip_protect 20、bip_verify 60
（含篡改类：解包、解封装、BIP 校验必须失败）。

**没有跑的**：任何空口行为。`firmware/` 整机构建与 `tests/e2e` 的 wifi 组，第一批与第二批之后各由集成方补跑过一次；
第二批之后的一次（2026-11-24）：`run_e2e.py --board --profile wifi` → `PASS board:wifi`，14/14 段，
`wifi_connect` 87/87。仍欠的集成项见「待验证项」。

## 快速开始

```sh
cd components/wifi-connect
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG test src/host_tests.zig        # All 431 tests passed.
env -u LD_LIBRARY_PATH $ZIG fmt --check src/               # 无输出
```

板侧入口是 `selftest.run() bool`。请求方的用法：

```zig
var s = supp.Supplicant{ .cfg = .{ .spa, .aa, .akm = rsne.Akm.psk,
    .pairwise = .ccmp128, .group = .ccmp128, .mfp = negotiated,
    .ap_rsne = beacon_rsne, .sta_rsne = assoc_rsne } };
s.start(pmk);            // INITIALIZE
s.step();                // → AUTHENTICATION
_ = s.associate();       // → STAKEYSTART
// 每收到一帧 EAPOL-Key：给一个新的 SNonce，回应写进 out
const n = try s.recvEapol(frame, snonce, out);
// 之后：s.protect(plain, out) / s.unprotect(frame, out) / s.unprotectBip(frame)
```

## 文件职责

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `wpa2.zig` | 421 | PSK、PRF、PTK、PMKID、GTK、AES-128-CMAC 原语、EAPOL-Key 编解码、MIC（HMAC-SHA-1-128 / AES-128-CMAC）、重放计数比较 |
| `keywrap.zig` | 163 | RFC 3394 AES Key Wrap / Unwrap，128 位与 256 位 KEK |
| `kde.zig` | 285 | KDE 格式、GTK/PMKID/IGTK KDE 的拼与拆、Key Data 填充、包裹与解包 |
| `hdr.zig` | 147 | MAC 头的局部解析（只取 CCMP/GCMP/BIP 要用的字段） |
| `ccmp.zig` | 438 | CCMP-128 / GCMP-128 / CCMP-256 / GCMP-256 封装与解封装、AAD、nonce、接收重放计数 |
| `bip.zig` | 371 | BIP-CMAC-128、BIP-CMAC-256、BIP-GMAC-128、BIP-GMAC-256：AAD、MME 构造/解析、保护、校验、IPN 重放 |
| `rsne.zig` | 383 | RSNE 解析/编码、12.6.3 的交集选择、表 12-2、本 STA 的 RSNE、9.4.2.25.3 的 AKM 与密码套件配对、表 9-131 的组管理密码选择器 |
| `supplicant.zig` | 660 | 请求方：4 次握手、组密钥握手、PTKSA/GTKSA/IGTKSA、12.7.10 状态机 |
| `api.zig` | 15 | 公共入口：`supplicant`、`rsne`、`wpa2`、`akm`、`ccmp`、`bip`、`vectors`，别的组件按模块名 `wifi_connect` import（使用者是 `wifi-blobs` 的 supplicant 回调：连接前选 AKM 与套件、由口令算 PMK、收 EAPOL；`vectors` 是它在主机用例里对拍整条握手用的向量） |
| `mfp.zig` | 366 | 稳健帧分类（12.2.8、表 9-47）、12.6.19 收发规则、SA Query |
| `conn.zig` | 322 | 连接状态机、事件队列、重连退避（未改） |
| `sae.zig` | 379 | SAE 字节级函数（KDF、keyseed / KCK / PMK / PMKID、Confirm 的 CN、帧体常量）、`unimplemented` 表 |
| `vectors.zig` | 513 | 第一批的判据常数 |
| `host_tests.zig` | 2446 | 第一批 57 项测试与测试用的假认证方 `FakeAuth`；末尾十个 wrapper `test` 块引入第二、三、四批的测试文件，另有 3 条在主机上执行板侧子自检的用例 |
| `selftest.zig` | 1198 | 板侧自检入口（199 条判据，含各 `*_selftest.zig`） |
| `ecc.zig` | 157 | 群 19 的点运算：仿射点加、由 x 恢复 y、元素编解码；标量乘用 `std.crypto.ecc.P256` |
| `sae_full.zig` | 993 | SAE 完整协议：PWE 派生、Commit / Confirm、帧体编解码、实例状态机、父进程与 Anti-Clogging |
| `sae_full_vectors.zig` | 213 | SAE 的判据常数（J.10 官方值、J.10 输入走协议路径、两组 KAT、基点倍点） |
| `sae_full_tests.zig` | 1485 | SAE 与 ECC 的 31 项主机测试 |
| `sae_full_selftest.zig` | 542 | SAE 的板侧判据 |
| `ft.zig` | 378 | FT 密钥派生层：KDF、XXKey、PMK-R0 / R1 及其名字、PTK / PTKName |
| `ft_vectors.zig` | 295 | FT 的七组固定输入与交叉实现值 |
| `ft_tests.zig` | 697 | FT 的 24 项主机测试 |
| `ft_selftest.zig` | 249 | FT 的板侧判据 |
| `suite256.zig` | 259 | 256 位套件的 EAPOL-Key 原语：Key MIC、Key Data 填充与包裹（128 / 256 位 KEK）、Key Descriptor Version、表 12-8 算法 |
| `suite256_vectors.zig` | 478 | 256 位套件的判据常数（公开标准向量 + 差分样本） |
| `suite256_tests.zig` | 1006 | 256 位套件的 23 项主机测试 |
| `suite256_selftest.zig` | 259 | 256 位套件的板侧判据 |
| `owe_cache_tests.zig` | 475 | RFC 8110 §4.5 的 24 项主机测试与在主机上执行板侧子自检的 1 项 |
| `owe_cache_selftest.zig` | 283 | OWE PMK caching 的 12 条板侧判据（没有点乘） |
| `ft_ric_tests.zig` | 511 | FT RIC 的 17 项主机测试与在主机上执行板侧子自检的 1 项 |
| `ft_ric_selftest.zig` | 125 | FT RIC 的 10 条板侧判据 |

## 特性对照表

| 特性 | 规范条款（印刷页） | 测试名（`host_tests.zig`） | 向量来源 | 状态 |
| --- | --- | --- | --- | --- |
| AES Key Wrap | RFC 3394 §2.2、§4.1 | keywrap: RFC 3394 section 4.1 …；keywrap: length rules and buffer errors | RFC 3394 §4.1 | 完成 |
| PSK | J.4.1、J.4.2（3416–3417） | psk: J.4.2 test cases 1-3 …；wpa2 pmk: passphrase/IEEE and length guards | J.4.2 | 完成 |
| PRF | 12.7.1.2（2008）；J.3.2（3416）；J.6.5（3423–3425） | prf: J.3.2 …；prf: J.6.5 … | J.3.2、表 J-9…J-12 | 完成 |
| PTK | 12.7.1.3（2009–2010）；J.7（3425–3426） | ptk: J.7 …；ptk: 384/512 vectors … | 表 J-13…J-15；`tools/vectors.py` | 完成 |
| PMKID | 12.7.1.3（2011） | pmkid: Truncate-128(…) | 无官方向量；Python 标准库 `hmac` + 参考实现 | 完成 |
| GTK 派生 | 12.7.1.4（2011） | gtk: PRF-128(…) | 无官方向量；参考实现 | 完成 |
| AES-128-CMAC（J.8） | 12.5.4.1（1974）；J.8（3426） | aes-128-cmac: RFC 4493 section 4 … | RFC 4493 §4 例 1–4 | 完成 |
| EAPOL-Key 编解码与 MIC | 12.7.2（2018–2023）；表 12-5、12-8 | eapol encode …；eapol decode …；eapol rsc …；eapol mic …（两篇） | `tools/vectors.py`；RFC 4493 | 完成 |
| KDE 与 Key Data | 12.7.2（2023–2026） | kde: …（四篇） | 独立脚本 + 参考实现（Key Wrap） | 完成 |
| 4 次握手（请求方） | 12.7.6（2029–2037） | supplicant: PSK + CCMP-128 + MFP against a fake authenticator …；supplicant: negative cases …；supplicant: message 1 field checks … | 六帧全部由独立脚本算出 | 完成 |
| 消息 3 的第二个 RSNE | 12.7.6.4（2034）；12.7.2（2025–2026） | supplicant: a second RSNE in message 3 … | 构造 | 完成 |
| 组密钥握手（请求方） | 12.7.7（2040–2043） | 同上「整条会话」与「negative cases」 | 独立脚本 | 完成 |
| SAE 作为 AKM（仅密钥管理） | 表 12-8（2027）；12.7.2 b) 1) | supplicant: SAE AKM uses AES-128-CMAC … | 构造 | 完成 |
| 密钥管理状态机 | 12.7.10（2062–2064） | supplicant key management state machine … | 状态迁移 | 完成 |
| 安全关联 | 12.6.1.1（1985–1986）；12.6.18（2001） | security associations: … | 构造 | 完成 |
| RSNE 与策略选择 | 9.4.2.25（882–890）；12.6.2、12.6.3（1991–1992） | rsne: …（两篇）；rsna selection: …（两篇） | 9.4.2.25.1 样例、表 12-2 | 完成 |
| CCMP-128 | 12.5.3（1967–1974） | ccmp: J.6.4 …；ccmp: J.9.2 …；ccmp: AAD is 22/24/28/30 …；ccmp: encapsulation argument errors …；ccmp: decapsulation rejects … | J.6.4、J.9.2 | 完成 |
| GCMP-128 | 12.5.5（1977–1982） | gcmp: J.11 test vector 2 …；gcmp: J.11 test vector 1 … | J.11 #1、#2 | 完成 |
| PN 重放检测 | 12.5.3.4.4（1973–1974） | replay: PN must exceed … | 规则 | 完成 |
| BIP-CMAC-128 与 MME | 12.5.4（1974–1977）；9.4.2.55（941） | bip: J.9.1 …；bip: wrong IGTK … | J.9.1 | 完成 |
| 稳健帧分类 | 12.2.8（1927）；表 9-47（736–737） | mfp: robust management frames … | 表 9-47 | 完成（非 DMG） |
| 管理帧保护收发规则 | 12.6.19、12.6.20（2002–2003） | mfp: receive and transmit rules … | 规则 | 完成 |
| SA Query | 11.14（1745–1746）；9.6.10（1210） | sa query: responder echoes … | 规则 | 完成 |
| 连接状态机 | 原有 | `conn.zig` 的用例 | 原有 | 未改 |
| SAE：P-256 点运算 | 12.4.4.2（1937–1938）；12.4.7.2.4 / .5 | `ecc: add, double, mul agree with std.crypto.ecc.P256 on random points`；`ecc: recoverY lands on the curve with the requested parity and agrees with std`；`ecc: fromBytes follows 12.4.7.2.5 (range, zero coordinate, on curve)` | `std.crypto.ecc.P256` 与它自带的基点倍点向量 | 完成（group 19） |
| SAE：PWE 派生 | 12.4.4.2.2（1937–1939） | `J.10: pwd-seed with a one-octet counter hits both printed seeds (12.4.4.2.2)`；`J.10: candidate x values need J.10's 1-octet KDF counter; the protocol KDF stops at counter 3`；`sae pwe: pwd-value >= p is skipped and the counter keeps counting (12.4.4.2.2)` | Annex J.10；`sae_oracle.py j10 --kdf-counter 2`（非官方）；差分 KAT | 完成 |
| SAE：rand / mask 与 Commit | 12.4.5.2–12.4.5.4（1942–1943） | `sae secrets: rand and mask constraints and resampling (12.4.5.2)`；`sae commit: peer scalar, element and identity checks (12.4.5.4)`；`J.10: commit-scalar, commit-element, k and keyseed hit from the printed PWE, rand and mask` | Annex J.10；差分 KAT | 完成 |
| SAE：keyseed / KCK / PMK 与 Confirm | 12.4.5.4–12.4.5.6（1943） | `J.10: KCK and PMK are printed for a 1-octet KDF counter; the protocol follows 12.7.1.7.2`；`J.10: both printed confirms hit with the printed KCK and send-confirm = 1 (12.4.5.5)` | Annex J.10（见「实现偏离」16） | 完成 |
| SAE：帧体编解码 | 12.4.7（1944–1946）；表 9-36 | `sae framing: Commit and Confirm bodies, token placement, status codes (12.4.7, Table 9-36)` | 手工构造 | 完成 |
| SAE：状态机与父进程 | 12.4.6、12.4.8（1947–1953） | `sae fsm: initiator and responder reach Accepted; frames, PMK and PMKID equal the oracle KAT`；`sae fsm: different passwords fail the confirm check with status 15 and delete the PMK (12.4.5.6, 12.4.7.6)`；`sae fsm: anti-clogging token round trip, wrong token, token bound to its sender (12.4.6, 12.4.8.6.1)`；`sae core: two oracle KATs (PWE, commit, K, keys, confirm) match end to end` | `sae_oracle.py vectors --seed 20261124` 的两组 KAT（非官方）；其余为规则 | 完成（group 19） |
| KDF | 12.7.1.7.2（2016）；RFC 4231 §4 | `kdf: HMAC-SHA-256 and HMAC-SHA-384 match RFC 4231 test cases 1-7`；`kdf: every block is one HMAC, and i and Length are little-endian 16-bit`；`kdf: J.10 reproduces only with a single-octet counter, not with the 16-bit i of 12.7.1.7.2` | RFC 4231 §4 | 完成 |
| FT：XXKey 与各 AKM 的长度 | 12.7.1.7.3（2016–2017）；表 9-133、表 12-8 | `xxkey: each AKM takes its own slice of its own root key`；`lengths per AKM match table 9-133, 12.7.1.7.3 and table 12-8` | 原文表格 | 完成 |
| FT：PMK-R0 / PMKR0Name | 12.7.1.7.2（2016） | `pmk-r0: R0-Key-Data, PMK-R0, PMK-R0Name-Salt and PMKR0Name match the vectors`；`pmk-r0: the context is SSIDlength \|\| SSID \|\| MDID \|\| R0KHlength \|\| R0KH-ID \|\| S0KH-ID` | `ft_oracle.py` 七组固定输入的交叉实现值（IEEE 无 FT 向量） | 完成 |
| FT：PMK-R1 / PMKR1Name | 12.7.1.7.2（2016） | `pmk-r1: PMK-R1 and PMKR1Name match the vectors`；`pmk-r1: binds PMK-R0, PMKR0Name, R1KH-ID and S1KH-ID` | 同上 | 完成 |
| FT：PTK / PTKName | 12.7.1.7.2（2016） | `ptk: KCK, KEK, TK and PTKName match the vectors`；`ptk: a longer TK is a different KDF run; PTKName does not depend on the cipher` | 同上 | 完成 |
| FT：与 PSK / SAE 的衔接 | 13.4.2（2092–2094） | `chain: all seven vectors replay end to end`；`chain: the J.4.2 case 1 PSK is the XXKey for FT using PSK`；`chain: the SAE PMK is the MPMK for FT over SAE` | J.4.2 用例 1；本组件的 SAE KAT | 完成（只做派生层） |
| CCMP-256 | 12.5.3；表 12-4 | `suite256 ccmp: J.6.4 CCMP-256 (802.11-2016 printed page 3423)`；`suite256 ccmp: the temporal key length follows the suite (Table 12-4)`；`suite256 ccmp: samples from the independent oracle` | Annex J.6.4；差分样本 | 完成 |
| GCMP-256 | 12.5.5；表 12-4 | `suite256 gcmp: J.11 test mpdu #3 GCMP-256 (802.11-2016 printed page 3432)` | Annex J.11 #3 | 完成 |
| BIP-GMAC-128 / BIP-GMAC-256 / BIP-CMAC-256 | 12.5.4.1；9.4.2.55；表 9-131 | `suite256 bip: J.9.1 BIP-CMAC-128, BIP-GMAC-128, BIP-GMAC-256 (802.11-2016 printed pages 3426-3428)`；`suite256 bip: verification rejects tampered, mislabelled and mis-keyed frames`；`suite256 bip: samples from the independent oracle` | Annex J.9.1（BIP-CMAC-256 无官方向量，只有差分样本） | 完成 |
| 256 位 KEK 的 Key Wrap 与 Key Data 封装 | RFC 3394 §4；12.7.2 j)（2023–2024）；表 12-8 | `suite256 keywrap: RFC 3394 section 4 with a 128-bit and a 256-bit KEK`；`suite256 keydata: padding and key wrap (12.7.2 j); KEK of 128 or 256 bits (Table 12-8)` | RFC 3394 §4.1/4.3/4.5/4.6；差分样本 | 完成 |
| Key MIC（表 12-8 的四种完整性算法） | 12.7.2 h)（2022）；RFC 4231 §4 | `suite256 eapol mic: the HMACs behind the Key MIC reproduce RFC 4231 section 4`；`suite256 eapol mic: MIC over the frame with the MIC field zeroed (12.7.2 h)`；`suite256 eapol mic: samples from the independent oracle` | RFC 4231 §4；RFC 4493 §4；差分样本 | 完成（原语层） |
| Key Descriptor Version 与 AKM / 密码套件配对 | 12.7.2 b) 1)（2019–2020）；12.7.3（2027）；表 12-8；9.4.2.25.3（888） | `suite256 kdv: Key Descriptor Version per 12.7.2 b) 1) (802.11-2016 printed pages 2019-2020)`；`suite256 kdv: Table 12-8 algorithms (802.11-2016 printed page 2027)`；`suite256 kdv: AKM and cipher suite pairing of 9.4.2.25.3 (802.11-2016 printed page 888)` | 原文条款与表格 | 完成（缺口见「实现偏离」20） |
| 组管理密码选择器 | 表 9-131（884–885） | `suite256 rsne: group management cipher selectors (Table 9-131, printed pages 884-885)` | 原文表格 | 完成 |

## 实现偏离

1. **解封装后的帧头**：12.5.3.4.3 说把收到的帧头与明文拼接；本组件输出时把 Protected Frame 位清零，
   使 `decapsulate(encapsulate(x)) == x`，下游拿到的就是普通帧。封装时则把该位置 1（12.2.7）。
2. **帧体为空、PN 为 0**：图 12-16/12-24 的 Data 至少 1 个八位组、PN 从 1 起严格递增，所以
   `encapsulate` 拒绝 PN = 0 与空帧体，`decapsulate` 拒绝空帧体。参考实现允许 PN = 0 与空帧体，
   这类向量不在差分范围内。
3. **+HTC/Order 位**：按 12.5.3.3.3 a) 6) ii)，没有 QoS Control 字段的帧（非 QoS 数据帧、管理帧）
   不清该位；按 12.5.4.3 a)，BIP 的 AAD 只清 Retry / Power Management / More Data。参考实现对
   非 QoS 帧和 BIP AAD 都清了该位，与原文不一致，这些向量从差分里剔除（本组件按原文实现）。
4. **J.11 向量 #1**：它的 AAD 里 Protected Frame 位是 0，与 12.5.3.3.3 a) 5)「恒置 1」不一致，
   走不了 `encapsulate`；用公开的 `ccmp.gcm128Seal` 对拍密文与 MIC。
5. **重放计数与顺序的判定次序**：消息 3 / 组密钥消息 1 先判重放计数再判握手阶段，握手完成后
   重放的消息 3 报 `BadReplay` 而不是 `BadOrder`。标准只说「丢弃」，次序是实现选择。
6. **消息 3 的计数**：按 12.7.6.4 / 12.7.2 d) 只要求「没用过」（大于已接受的值）。原来的
   `wpa2.FourWay` 替身要求恰好等于上一条加一，这不在标准里，已随之删除。
7. ** stricter 的字段检查**：Key Descriptor Version 必须等于 AKM 对应值（PSK 2、SAE 3）；消息 1/3 的
   Key Length 必须是 16；消息 3 与组密钥消息 1 的 Encrypted Key Data 必须为 1（12.7.2 j)）：
   明文携带 GTK KDE 的帧应忽略）；协商了管理帧保护而消息 3 没有 IGTK KDE 报 `NoIgtk`。
   EAPOL 协议版本字节恒为 2（沿用原值），Key Descriptor Version 放在 Key Information 的 B0–2。
8. **PMKID 不符**：消息 1 带 PMKID KDE 且与本 PMK 的 PMKID 不同时报 `PmkidMismatch`。
   12.7.6.2 只规定 Key Data「应是这次派生所用 PMK 的 PMKID」，丢弃不符的是实现选择。
9. **PSK 字符范围**：J.4.1 规定每个字符 32–126，`derivePmk` 对此返回新错误 `PassphraseChar`。
10. **GTK / IGTK 的接收重放计数初值**：GTK 取消息里的 Key RSC（12.7.6.4：认证方给 GTK 用的起始 PN），
    IGTK 取 IGTK KDE 的 IPN（12.5.4.4）。
11. **范围裁剪**：Radio Measurement 类别一律按稳健处理（表 9-47 注 1 的 DMG 例外不做）；
    管理帧的优先级取 0（QMF 不做）；不支持 DMG 的 QoS Control 规则；A-MSDU Present 位只在
    `spp_amsdu` 为真时进入 AAD；不做块确认重排。
12. **原地封装/解封装**：`out` 与输入不相交，或就是同一块缓冲。原地解封装时明文比密文提前 8 字节，
    依赖 `std` 的 CTR 从前往后「先读后写」；其它重叠方式报 `BufferOverlap`。
13. **稳健帧分类器在本组件**：组件之间不互相 import，而 12.6.19 的收发规则要判断「是不是稳健帧」，
    所以 `mfp.zig` 自带一个最小分类器（只读帧头与帧体前两个字节），与 `wifi-mlme` 的同类功能并存。
14. **没有超时与重传**：12.7.10 明说状态机不用超时与重试。SA Query 的时刻与间隔由调用方以 TU 给出。
15. **表 12-2 第 8 行**（AP 通告 MFPC = 0、MFPR = 1）：文本抽取把四个单元格并成一串
    「0110 or 1」，STA 两列是按 PDF 里各段文字的边界读出的（STA MFPC = 1、MFPR = 0 或 1）；
    该行的 STA 动作「不得尝试关联」与 STA 两列无关。
16. **Annex J.10 的三行与 12.7.1.7.2 正文不符**：J.10 印出的两个 candidate x value（`a16729e0…`、`103a5b96…`）
    以及 KCK、PMK 两行，只有把 KDF 的 counter 编成**一个八位组**才复现；按 12.7.1.7.2 的小端 16 位算，第一个
    candidate x 是 `695552323edc8c6d…`，与 J.10 不同（Python 的 `hmac` 独立算出，输入取 J.10 印出的 pwd-seed）。
    J.10 的其余各行（pwd-seed、commit-scalar、commit-element、k、keyseed、两条 confirm）本实现都能命中。
    本实现与独立实现 hostapd 都按正文走：
    - 字节序依据：12.7.1.7.2（2017）原文是「i and Length are encoded as 16-bit unsigned integers, represented
      using the bit ordering conventions of 9.2.2」；9.2.2（636）规定多八位组数值字段从最低位所在的八位组起发送，即小端。
      所以 `sae.zig` 的 `kdfHash()`（counter 小端 16 位、从 1 起；Length 小端 16 位、单位是位）与正文一致。
    - 与 hostapd 逐字节同构：ESP-IDF 自带的 `wpa_supplicant/src/crypto/sha256-prf.c` 的 `sha256_prf_bits()`
      （`u16 counter = 1`、两个 16 位字段都 `WPA_PUT_LE16`、`HMAC-SHA256(K, counter ‖ Label ‖ data ‖ length)`），
      SAE 的 hunting and pecking 在 `src/common/sae.c:149` 调的就是它。
    - 所以同一组 J.10 输入下本实现的 pwd-value、KCK、PMK 与 J.10 印出的不同；`sae_full_vectors.zig` 的 `j10_path_*`
      是「J.10 的输入走正文路径」的期望值，由 `sae_oracle.py j10 --kdf-counter 2` 算出，不是官方向量。
17. **pwd-seed 的 counter**：12.4.4.2.2 的 counter 是单个八位组。本组件原来按小端 16 位写，2026-11-24 改正并换了向量
    （期望值由 Python 的 HMAC 独立算出）。
18. **SAE 的范围**：只支持 group 19。恒定时间、H2E、其它群、rejected-groups / password-identifier 元素、
    两个群之间的 DiffGrp 同步都没有做，逐条列在 `sae.zig` 的 `unimplemented` 表里。随机数与发帧由调用方注入。
19. **FT 只做派生层**：KDF、XXKey、PMK-R0 / R1 与名字、PTK / PTKName。FT 认证算法的帧交换、reassociation、
    R0KH→R1KH 的 PMK-R1 分发、MDE / FTE 编解码、EAPOL-Key 帧都不在本组件。IEEE 没有给 FT 派生的测试向量，
    期望值是 `ft_oracle.py` 的交叉实现值。
20. **256 位套件的原文缺口**（`suite256.zig` 文件头同文）：12.7.2 b) 1) iii) 只点名 AKM 3、4、5、6 用版本 3，
    表 12-8 给 AKM 8、9（SAE、FT over SAE）的是与版本 3 相同的算法组合，`descriptorVersion` 据此对 AKM 8、9 返回 3；
    AKM 11、12、13 在表 12-8 里有算法，但 12.7.2 b) 1) 没为它们定义 Key Descriptor Version，返回 null；
    表 12-8 的 Key-wrap algorithm 只有 NIST AES Key Wrap；HMAC-SHA-256 / 384 截到 MIC 长度时取哪几位表里没写，
    这里与 HMAC-SHA-1-128 同一读法，取摘要开头的字节。BIP-CMAC-256 没有官方向量。
    `suite256.zig` 是原语层，不改 `wpa2.zig` / `supplicant.zig` 的 EAPOL-Key 编解码与 4 次握手。

## 待验证项

- 板侧自检：第一批 28 条与第二批加到 87 条之后，各于 2026-11-24 随 `wifi` profile 上板一次；后一次
  `wifi_connect` 87/87、14/14 段（`logs/e2e-wifi-boot.log`）。
- 第二批之后的仓库门禁：`check-host.sh`、`check-coverage.py`、`check-invariants.py` 已重跑并通过
  （`tests/baselines.json` 的基线抬到 141 / 82，前门总数 1047）；`run_e2e.py --host` 与 `check-capacity.py`
  的结果记在 `docs/verification/README.md`。
- 第三批、第四批之后的板侧判据当时没有上板（串口 `/dev/ttyUSB0` 无权限）。2026-11-25 随第五批的镜像上板：
  `wifi_connect` 199/199 全过（本组件的判据数在第五批不变）；整份 `wifi` profile 14/14 个 section 全过、
  `main: verdict=pass`（`logs/e2e-wifi-boot.log`）。串口权限是同日由用户授权 `setfacl` 恢复的。
- 真实 AP 上的 SAE（WPA3 个人）、FT 初始关联与快速切换、256 位套件协商都没有任何互通证据。WPA2-PSK + CCMP-128 已于
  2026-11-26 在一台真实 AP 上走通——请求方经 `wifi-blobs` 的回调表接进真实链路探针，证据见
  `docs/verification/wifi-ieee80211-verification.md` §11。
- 与真实 AP 的互通：消息 3 在那一台 AP 上被本实现接受；组密钥消息 1 在实网上没有出现过（那次运行里 AP 没有换钥匙）。
  宽松度的各条（上面第 7 条）在那台 AP 上是否出现，没有核对。
- CCMP/GCMP 的 QoS + 四地址 AAD（30 字节）只有构造测试，没有官方向量。
- BIP 的 AAD 只有 J.9.1 一帧（Retry / Power Management / More Data 本来就是 0）。
- 差分时发现的参考实现问题（未修改它）：`vectors --seed 20261124` 与 `--seed 5` 在 `_v_frame` 里
  `KeyError: 'mpdu'`；BIP 不检查 Address 1 是否为组地址；篡改类 BIP 向量的 `reason` 标成 `mic`，
  实际 `call bip_verify` 返回 `no-mmie`。
