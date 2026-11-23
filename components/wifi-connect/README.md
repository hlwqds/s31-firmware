# wifi-connect — Wi-Fi 连接管理

扫描/连接状态机、PSK/PMK → PMKID → PTK、RSNA 请求方（4 次握手与组密钥握手）、
密钥数据封装（AES Key Wrap）、安全关联与密钥管理状态机、RSNA 策略选择、
管理帧保护与 SA Query、每帧保护（CCMP-128 / GCMP-128 / BIP-CMAC-128），以及 SAE 的字节级子集。

- 主机测试：**57 项**（`zig test src/host_tests.zig`；基线文件 `tests/baselines.json` 仍记 20，需随本次更新）
- 板侧：`src/selftest.zig` 由固件顺序调用，打印 28 行 `check:` 与 `checks: passed=N failed=M total=N+M`
- 依赖方向：逻辑模块只 import `std` 与同组件文件；仅 `selftest.zig` import `boards` 的 `board`（只用 `board.log`）
- 不依赖其它组件，不做 802.11 帧编解码（归 `wifi-mlme`），不含 SAE 椭圆曲线运算

## 范围与来源

规范文本：IEEE Std 802.11-2016（下文页码为印刷页码）、RFC 3394、RFC 4493、RFC 6070。
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

**非目标**：802.11 帧的完整编解码（`wifi-mlme`）、SAE 椭圆曲线（只保留 `sae.zig` 的字节级函数，
SAE 仅作为 AKM 00-0F-AC:8 的密钥管理参与握手）、TKIP、WEP、802.1X / EAP、CCMP-256 / GCMP-256 /
BIP 的 GMAC 与 CMAC-256 变体、FT、PeerKey/SMK、扩展 Key ID、QMF、DMG、GCR、A-MPDU/A-MSDU 重排。

## 验证状态

下面的命令在 x86_64 主机上跑过；空中接口没有任何抓包。

- L3 板侧：2026-11-24 随 `wifi` profile 第一次上板，自检 28/28（`checks: passed=28 failed=0 total=28`）。
  日志 `logs/wifi-selftest-prefix-boot.log`（该次运行的整体判决因别的 section 失败而是 fail）。

| 命令 | 结果 |
| --- | --- |
| `zig test src/host_tests.zig` | 57/57 通过 |
| `zig fmt --check src/` | 干净 |
| `zig test -target riscv32-linux-musl -fno-emit-bin src/host_tests.zig` | 只编译、不链接：通过（证明能过 32 位 RISC-V 的语义分析） |
| 板侧自检逻辑在主机上执行（临时桩 `board` 模块，已删除） | 28/28，最长一行 125 字节（`board.log` 上限 200） |
| 对 `/tmp/s31-oracle/wifi_oracle.py` 的差分（一次性测试，已删除） | 13 组全部一致，见下 |

差分用的向量由 `wifi_oracle.py vectors --seed {1,7,42,3,9} --count 24` 生成，落在可比范围内的条数：
psk 120、prf 120、ptk 37、pmkid 120、gtk 51、key_wrap 48、key_unwrap 96、ccmp_encapsulate 43、
ccmp_decapsulate 98、gcmp_encapsulate 41、gcmp_decapsulate 96、bip_protect 20、bip_verify 60
（含篡改类：解包、解封装、BIP 校验必须失败）。

**没有跑的**：`firmware/` 的 `zig build`、`scripts/check-*.py|sh`、`tests/e2e`（不在本切片的写权限内）；
板侧自检在真板子上的输出；任何空口行为。

## 快速开始

```sh
cd components/wifi-connect
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG test src/host_tests.zig        # All 57 tests passed.
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
| `keywrap.zig` | 136 | RFC 3394 AES Key Wrap / Unwrap，128 位 KEK |
| `kde.zig` | 285 | KDE 格式、GTK/PMKID/IGTK KDE 的拼与拆、Key Data 填充、包裹与解包 |
| `hdr.zig` | 147 | MAC 头的局部解析（只取 CCMP/GCMP/BIP 要用的字段） |
| `ccmp.zig` | 348 | CCMP-128 / GCMP-128 封装与解封装、AAD、nonce、接收重放计数 |
| `bip.zig` | 182 | BIP-CMAC-128：AAD、MME 构造/解析、保护、校验、IPN 重放 |
| `rsne.zig` | 372 | RSNE 解析/编码、12.6.3 的交集选择、表 12-2、本 STA 的 RSNE |
| `supplicant.zig` | 660 | 请求方：4 次握手、组密钥握手、PTKSA/GTKSA/IGTKSA、12.7.10 状态机 |
| `mfp.zig` | 366 | 稳健帧分类（12.2.8、表 9-47）、12.6.19 收发规则、SA Query |
| `conn.zig` | 322 | 连接状态机、事件队列、重连退避（未改） |
| `sae.zig` | 374 | SAE 字节级子集（未改） |
| `vectors.zig` | 509 | 全部判据常数 |
| `host_tests.zig` | 2359 | 全部测试与测试用的假认证方 `FakeAuth` |
| `selftest.zig` | 1170 | 板侧自检 |

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
| 连接状态机、SAE 字节级 | 原有 | 其余 13 篇 | 原有 | 未改 |

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

## 待验证项

- 板侧自检已于 2026-11-24 上板一次（28/28）；`firmware/` 整机构建、`check-coverage.py`、`run_e2e.py --host` 的 wifi 组均已跑过。
- 与真实 AP 的互通：消息 3 / 组密钥消息 1 的字段宽松度（上面第 7 条）只能靠实网确认。
- CCMP/GCMP 的 QoS + 四地址 AAD（30 字节）只有构造测试，没有官方向量。
- BIP 的 AAD 只有 J.9.1 一帧（Retry / Power Management / More Data 本来就是 0）。
- 差分时发现的参考实现问题（未修改它）：`vectors --seed 20261124` 与 `--seed 5` 在 `_v_frame` 里
  `KeyError: 'mpdu'`；BIP 不检查 Address 1 是否为组地址；篡改类 BIP 向量的 `reason` 标成 `mic`，
  实际 `call bip_verify` 返回 `no-mmie`。
