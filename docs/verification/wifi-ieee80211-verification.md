# Wi-Fi 验证报告（IEEE Std 802.11-2016）

- 规范依据：IEEE Std 802.11-2016（条款号取自该版目录与各模块文件头，页码为印刷页码）；其上的 RFC：RFC 3394（AES Key Wrap）、RFC 4493（AES-CMAC）、RFC 6070（PBKDF2）、RFC 4231（HMAC 的测试向量）、RFC 2104（HMAC）。
- 组件：`components/wifi-mlme`、`components/wifi-connect`。
- 验证分级见 `docs/REPO-STANDARDS.md` §4。本报告只写实际跑过的命令和输出里出现过的结果。
- **真实 AP 与空口没有任何证据**：`esp_wifi_start` 仍卡在 `MAC_ST[15:13]`。下表的"通过"指离线验证通过。
- 本文把 2026-11-24 加入的 SAE 完整实现、FT 密钥派生层、256 位套件、QoS 与省电称为"第二批"；之前的部分称为"第一批"。
  第二批的板侧自检先在主机上用桩 `board` 模块跑过，随后于同日随 `wifi` profile 上板（§5.2）。

## 1. 结论

三种计数分开写：主机用例数是 `zig test` 报的 total；板侧 checks 数是 `selftest.run()` 的判据数；差分向量数是参照实现生成的条数。

| 项 | 级别 | 结论 | 证据 |
| --- | --- | --- | --- |
| `wifi-mlme` 主机测试 | L1 | 82/82（第一批 61） | §3.1 |
| `wifi-connect` 主机测试 | L1 | 141/141（第一批 57；含 3 条在主机上执行板侧子自检的用例） | §3.2 |
| 与独立参照实现的差分（第一批） | L1 | 13 组 950 条全部一致 | §4.1 |
| suite-256 全量差分（第二批） | L1 | 14 组 3568 条向量、3928 项比较，0 不一致 | §4.2 |
| RV32 目标编译 | L2 | 两个自检都能以固件参数编译（第二批的 24 / 87 条） | §5.1 |
| 板侧自检在主机上的运行（桩 `board`） | L1 | `wifi_mlme` 24/24、`wifi_connect` 87/87 | §5.1 |
| 板侧自检（第一批上板） | L3 | `wifi_mlme` 16/16、`wifi_connect` 28/28 | `logs/wifi-selftest-prefix-boot.log` |
| 板侧自检（第二批） | L3 | `wifi_mlme` 24/24、`wifi_connect` 87/87 | `logs/e2e-wifi-boot.log`；§5.2 |
| 整体判决为 pass 的板级运行 | L3 | 有：14/14 段、`main: verdict=pass`（第一批复验一次、第二批之后一次；后一次覆盖了前一次的同名日志） | `logs/e2e-wifi-boot.log`、`docs/verification/README.md` |

## 2. 逐特性对照

"主机"一栏是 `zig test src/host_tests.zig` 的用例数（按模块），"板侧"是 `selftest.zig` 的判据数。第一批各行的板侧数字含在当时的 16 / 28 条里；第二批各行的判据含在 24 / 87 条里（主机桩跑与上板都是这两个数），逐特性的板侧划分没有单独统计。

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
| 真实 MAC：`esp_wifi_start`、扫描、连接 | 不适用 | — | — | — | — | 阻塞：`MAC_ST[15:13]` |

负面用例（主机）：截断、越界、不一致的输入逐个被拒；MIC 错、重放或重复计数、顺序错、解包失败、RSNE 被改、PN 重放、错 IGTK、SA Query 事务标识不符。第二批追加：口令不同时 Confirm 校验失败并删除 PMK、非法的对端 Commit、回声 Commit、不支持的群、Anti-Clogging token 错、篡改 / 截断 / 标错套件的 256 位帧、KEK 长度不对。

## 3. 主机测试

### 3.1 `wifi-mlme`

```sh
cd components/wifi-mlme && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 82 tests passed.
```

模块分布（2026-11-24）：`host_tests.zig` 61（`frame` 13、`ie` 11、`mgmt` 8、`robust` 4、`mlme` 19、`scan` 6）
+ `qos_tests.zig` 10 + `powersave_tests.zig` 9 + 2 个引在这两个文件上的 wrapper `test` 块 = 82。`zig fmt --check src/` 干净。

### 3.2 `wifi-connect`

```sh
cd components/wifi-connect && env -u LD_LIBRARY_PATH zig test src/host_tests.zig   # All 141 tests passed.
```

模块分布（2026-11-24）：`host_tests.zig` 57 + `sae_full_tests.zig` 31 + `ft_tests.zig` 24 + `suite256_tests.zig` 23
+ 3 个 wrapper `test` 块 + 3 条在主机上执行板侧子自检的用例 = 141。其中 `sae_full_tests.zig` 的 31 项是 `ecc` 5、J.10 5、PWE / rand-mask / Commit / 核心 KAT / 帧体 5、
状态机 14、父进程 1、配置默认值 1。那 3 条分别跑 `sae_full_selftest.run`（24 条判据）、`suite256_selftest.run`（22 条）、
`ft_selftest.run`（13 条），断言零失败且最长一行不超过 `board.log` 的 200 字节上限。`zig fmt --check src/` 干净。

原有 20 项里 18 项原样保留。另 2 项（`four-way happy path reaches done`、`four-way rejects wrong order, stale replay and bad key info`）测的是一个只管顺序的替身 `wpa2.FourWay`，已删除，由用真实帧的四篇请求方测试取代。随之变化的行为：替身要求消息 3 的计数恰好等于上一条加一，而 12.7.6.4 只要求"没用过"，所以"计数跳号即拒绝"不再成立。

## 4. 与独立参照实现的差分

参照实现在 `/tmp/s31-oracle/`（Python，不引用仓库代码）。它们只存在于 `/tmp`，不在仓库里；自检结果（2026-11-24）：
`wifi_oracle.py selftest` 223 PASS、1 KNOWN；`suite256_oracle.py selftest` 253/253；`ft_oracle.py selftest` 51 pass、2 known；
`sae_oracle.py selftest` 的 P-256 与 `cryptography` 在 10 个点上一致。

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

以固件参数编译。根文件 `board_root_guard.zig` 引用 `run()`，并在编译期断言自己确实按 riscv32 / ReleaseSmall 在编；
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
这些标志只作用于紧挨着的那个模块，于是只有 `board` 模块按 riscv32 编，自检本身仍是本机 x86_64：命令退出 0，却什么都没证明
（带 `-femit-bin` 看产物，是 `ELF64 … Machine: Advanced Micro Devices X86-64`）。发现它的是上面这个守卫根文件——
按旧写法编译，它报 `guard: root module is not riscv32 (got x86_64)` 与 `guard: selftest module is not riscv32 (got x86_64)`。
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
  - AKM 11、12、13 在表 12-8 里有算法，但 12.7.2 b) 1) 没有为它们定义 Key Descriptor Version；返回 null。
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

## 7. 未验证

- 真实 AP 互通；消息 3 与组密钥消息 1 的字段宽松度只能靠实网确认。
- CCMP 与 GCMP 在 QoS 加四地址帧上的 30 字节 AAD 只有构造测试，没有官方向量。
- 现代真实 AP 的 Beacon（厂商特定元素、AID 高位）只在 2004 年的抓包里见过。
- 真实 AP 上的 SAE（WPA3 个人）互通；FT 的初始关联与快速切换；256 位套件（CCMP-256 / GCMP-256 / BIP 的 256 位与 GMAC 变体）的协商与互通。
- QoS 与省电的行为：真实 AP 的 Beacon TIM、PS-Poll 响应、DTIM 之后的组播次序、U-APSD 服务期；EDCA 参数对驱动的影响。
- 第二批的板侧自检已上板（§5.2）；板上只验证了判据本身，真实 AP 上的行为见上面几条。
