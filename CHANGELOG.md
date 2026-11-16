# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Planned
- P1：以太网 ARP/ICMP 上层（DMA 已闭环）

### Added
- **Wi-Fi blob init 返回 0**（2026-11-16，R3 里程碑）：真实 blob 的 `esp_wifi_init_internal`
  在裸机上返回 **0**（`wifi-init-probe: INIT OK`）。三个修复都由故障点反汇编定住：
  `_wifi_create_queue`（表 index 94）是独立钩子且**返回对象的第一个字必须是内部队列指针**
  （`pp_create_task` 把首字当句柄传给 `_queue_send`）；`_wifi_thread_semphr_get` 返回 null
  会让 init 判成 `257`；`osi_stubs.fill` 改成只填仍为 null 的字段（否则新实现的钩子被同名桩
  静默覆盖），并加主机用例断言"已实现 ∩ 桩 = ∅"。仍未闭环：init 创建的任务在协作式单线程壳里
  从未被调度，扫描/关联/收包尚未发生。
- **第一次真正执行 blob 代码**（R3 里程碑）：`-Dwifi-init-probe=true` 编进"装 osi 表 → 构造
  `wifi_init_config_t` → 调 `esp_wifi_init_internal` → 打印返回码与桩命中"的入口，实测：

  ```text
  wifi-init-probe: arena=397936 B
  wifi-init-probe: osi installed prev=0x00000000
  wifi-init-probe: cfg size=160 magic=0x1f2f3f4f
  wifi-init-probe: esp_wifi_init_internal rc=257        ← ESP_ERR_NO_MEM
  wifi-init-probe: osi stub _calloc_internal hits=1
  ```

  补上分配器族（`_malloc_internal`/`_zalloc_internal`/`_calloc_internal`/`_realloc_internal`/
  `_wifi_malloc/_wifi_calloc/_wifi_zalloc/_wifi_realloc`，共 9 个）后 rc 变成 **258**
  （ESP_ERR_INVALID_ARG），失败点前移到链接桩 `net80211_printf`/`pp_printf`——这正是"把清单变成
  实测"的效果：每次只暴露下一个真正缺的东西。探针与常规构建用 comptime 分流（`probe.enabled`），
  常规镜像不受影响（167 520 B、两段）。
- **`wifi_osi_funcs_t` 的 Zig 镜像**（`components/wifi-blobs/src/osi.zig`）：字段表由 IDF 头
  `esp_wifi/include/esp_private/wifi_os_adapter.h` 经 `sdkconfig.h` 预处理后**自动生成**
  （128 个字段，`_version` 首、`_magic` 尾），不是手写。ilp32 下用 comptime 断言钉死
  `@sizeOf == 512`、首尾字段偏移——交叉编译时就会检查（实测通过）。主机用例断言字段数与
  首尾偏移。这张表是 blob 与宿主之间唯一的 OS 契约：三个大归档里
  `xTaskCreate`/`xQueue*`/`xSemaphore*`/`esp_event_*`/`esp_timer_*`/`heap_caps_*` 的未定义引用
  全是 0，所有 OS 访问都经 `g_osi_funcs_p` 回调。
- **链接脚本收集 IDF blob 的段**：`s31.ld` 现在把 `.rodata_wlog*`（603 个 Wi-Fi 日志串段）、
  `.eh_frame*` 并进 `.flash.rodata`，`.iram1/.wifis*piram/.wifirxiram/.wifiextrairam` 等
  IRAM 变体收进 SRAM 的 `.iram_blobs`（62 240 B），`.dram1` 并进 `.data`。没有这一步，
  105 个 blob 对象会让 `elf2image` 报 `Invalid segment count 124 (max 16)`。
  收集后同一实验镜像变成合法两段：irom **586 128 B**、drom **163 360 B**、SRAM 92 KB，
  总镜像 818 368 B（factory 1 536 000 之内），`image-info` 里 DROM/IROM 行正好 2 行
  （`rom_index == 2` 成立）。**这份 blob 镜像已烧上板并正常启动**：
  `sections: passed=1 failed=0 total=1`、`verdict=pass`——586 KB irom + 163 KB drom + 62 KB
  SRAM 的新布局被 loader 正常映射，这是板级事实而非静态账。常规镜像不受影响
  （`elf2image` 仍两段、`gate-board` 7/7 通过）。
  注意 `Merged N ELF section` 是 esptool 的**合并次数**（`before - after`），不是 flash 段数，
  判据看 `image-info` 的 DROM/IROM 行数。
- **分区表落库**：`firmware/idf-bootstrap/partitions.csv`（nvs 0x9000 / phy_init 0xf000 /
  factory 0x10000 + 1500K，与 `SINGLE_APP_LARGE` 的默认表**逐字节一致**），
  `sdkconfig.defaults` 改走 `CONFIG_PARTITION_TABLE_CUSTOM`；新增
  `scripts/gen-partition-table.sh`（`--check` 校验 bin 与 csv 一致，纯 Python、不需要 IDF 工具链）。
  `check-capacity.py` 与 `run_e2e.py` 的 factory 上限改为从表里解析，不再硬编码 `0x177000`。
- **P0.3 两段窗口扩容**：`linker/s31.ld` 的 `irom`/`drom` 各 `0x7F000 → 0xB0000`，drom 基址
  `0x40080020 → 0x40100020`（保持 64 KiB 对齐 + 0x20）。合计 1 441 792 B 仍在 factory 1 500 K
  之内，不需要动分区表；`full` 的 IROM 余量从 214 496 B 涨到 415 200 B、DROM 到 650 128 B。
  板级验证：`gate-board.sh`（net-wire）PASS 7/7，`--profile full` 12 段 `verdict=pass`。
  **单段真的能到 0xB0000** 也补了实测：新增 `-Dfat-rodata=N`（往 `.rodata.fat` 塞 N 字节静态数组），
  `-Dfat-rodata=600000` 的 `net` 镜像 DROM 段 **0x9b5d4 = 636 372 B**（旧的 0x7F000 装不下），
  烧上去 `sections: passed=7 failed=0 total=7`、`verdict=pass`——窗口扩容在 loader 侧成立，
  不只是链接期。
  上限说明写进 `docs/ARCHITECTURE.md`：芯片窗口 64 MiB，但 DROM 段须结束在 `0x43FF0000` 以下
  （loader 保留最后一页做分区发现）。
- **CI 的 board job 走发布前门禁**（R4.1 的另一半）：`workflow_dispatch` 默认
  `profile=net-wire`、`gate=true`，步骤为 `host-prep-wire.sh up` → `gate-board.sh` →
  `trap` 收尾 `down`，与本地同一套脚本；`gate=false` 保留裸 e2e 冒烟路径。
  之前该 job 既不跑 host 预置、`profile` 默认还是 `net`，缺 DHCP 时退化成 skip 且 exit 0。
- **`net-wire` 的 TCP 改由 socket 层驱动**（R2.2d）：`components/net-sockets/src/api.zig` 提供
  统一入口，`firmware/build.zig` 给 wire 组接上 `net_sockets`；探针用 `Table.connect()` 建客户端、
  `tcp.Conn` 保持线上真相，SYN-ACK 学 `peer_iss` 后按偏移去重镜像，应用 64 B 经
  `Socket.send` → `txPeek` → 帧发出，ACK 覆盖后 `drainTx`；仍以 RST 收尾。
  板级 `wire: checks passed=7 failed=0`（新增 `socket layer established` / `socket send accepted` /
  `socket tx acked` 三项）。
- **容量门禁 `scripts/check-capacity.py`**（R4.3）：每个 e2e profile 构建一次，断言
  镜像 ≤ factory 分区、每个 DROM/IROM 段的 `load + Length ≤ 窗口末端`（IROM `0x40000020`、
  DROM `0x40080020`，窗口各 `0x7F000`）、以及相对 `tools/s31-production/baseline/capacity.json`
  的增长 ≤ 8 KiB（`--update` 需在 PR 里说明）。段长按 `image-info` 表头取 **Length 列**——
  早期版本误取了 File offs 列，断言因此恒真，`CAP_WINDOW=0x40000` 自检现在会报
  `IROM ends at 0x4004aa40 > window end`。实测 `full`：镜像 398 560 B、IROM 305 696 B
  （余量 214 496）、DROM 70 768 B（余量 449 424）。
- **matrix 自动更新 `tools/s31-production/baseline/update_matrix.py`**（R4.2）：只改 W1–W3
  状态列，摘录来自 `logs/e2e-net-wire-boot.log`，剥掉 `rcv_nxt` 等易变值；`--check` 进
  `check-all.sh`，`gate-board.sh` 通过后自动刷新。W4 保持人工（需无 DHCP 场景）。
- **发布前板级门禁 `scripts/gate-board.sh`**（R4.1）：`net-wire` 从可选 profile 提升为必跑门禁。
  `scripts/host-prep-wire.sh up|down|check` 固化主机预置（接口地址、dnsmasq、udp 67/53 与
  tcp 9000 放行、监听器，幂等且可撤销）；门禁先删旧日志（证据只能来自本轮），跑
  `run_e2e.py --board --profile net-wire`，再断言 `wire: tcp SYN sent` / `ESTABLISHED` /
  `RST sent` / `checks passed=7 failed=0`（R2.2d 之后探针多了 socket established /
  send accepted / tx acked 三项）；`skipped/no-dhcp-server` 算失败。
  退出码 2 = 前置缺失，1 = 证据不符。实测 `gate-board: PASS — wire: checks passed=7 failed=0`。
  脚本内置 NixOS 的两处坑：剥掉 `LD_LIBRARY_PATH`（否则 esptool/zig 撞 glibc）、
  显式指定带 pyserial 的解释器。
- `net-wire` 可选 profile（`-Dwire=true`）：生产固件在真实链路跑 DHCP
  DORA + TCP 三次握手，host 侧 dnsmasq/socket 监听为前置；无 DHCP 时优雅跳过。
  板级证据 `logs/e2e-net-wire-boot.log`。

### Removed
- `tests/e2e/run_e2e.py` 的 `expect="overflow"` 死分支：P0.2 扩容后已无 profile 使用，
  两段窗口容量改由 `scripts/check-capacity.py` 门禁。

### Fixed
- `tests/e2e/run_e2e.py` 的 board case 现在**自己**删旧日志并要求本轮产生日志：此前只有
  `gate-board.sh` 做这件事，任何直接调 `--board` 的路径（比如手工跑 `--profile full`）在
  flash 失败后都会拿上一轮文本当本轮证据——本轮实测踩到（`esptool: command not found` 后
  断言仍然“通过”）。
- 板子重新枚举成 `/dev/ttyUSB0` 时门禁会假绿：`run_e2e.py` 的 board case 硬编码
  `/dev/ttyUSB1`，于是走 `SKIP` 分支并以 0 退出。现在 `run_e2e.py` 认 `BOARD` 环境变量，
  `gate-board.sh` 在 ttyUSB1/ttyUSB0 里挑存在的那个并把 `BOARD` 传给 e2e；
  junit 的 `<skipped/>` 仍算失败（本轮正是靠这条断言发现的）。
- net-ethernet：DMA 不取描述符的根因是 APM 控制过滤器。IDF app 在
  `bootloader_init_mem()` 里关闭 `HP/MEM/LP_APM_FUNC_CTRL`，二级 bootloader
  因 `#if !BOOTLOADER_BUILD` 跳过；`enableBusClock()` 现补 `enableApmForDma()`。
  板侧：TX `done in 15us`、RX 2 帧 94 B IPv6 组播。
- net-ethernet：补 YT8531 RGMII 专用初始化（EXT `0xA001` bit8、
  EXT `0xA003` 低字节 `0xDD`），并把 MDIO 事务改成 IDF 顺序（先写
  GMIIDATA，再写地址+write+busy）。修正后主机 `rx_packets` 0→1，
  线上 TX 打通。

### Added
- `net-wire` 可选 profile（`-Dwire=true`）：生产固件在真实链路跑 DHCP
  DORA + TCP 三次握手，host 侧 dnsmasq/socket 监听为前置；无 DHCP 时优雅跳过。
  板级证据 `logs/e2e-net-wire-boot.log`。

### Fixed
- net-ethernet：新增 `rxPollCopy`（整帧拷贝，含 FCS 长度语义），供 IPv4/ARP/TCP 使用。
- net-udp-dhcp-dns：DHCP `Builder.finish()` 按 RFC 2131 补到 300 字节；新增
  `findAnswerNamed()` 返回带长度的 DNS 名字视图。
- E2E profile 的 section 清单补上 `net_ethernet`（构建一直包含它，断言漏了，board e2e 会误报 section 集合不匹配）。

### Changed
- P0.2：flash 窗口扩至各 0x7F000、drom 基址 0x40080020，全特性单镜像可链接（板上 11/11）
- 组件内 `hw.zig`/`log.zig` 副本移除，统一引用 `board.hw` / `board.log`
- net-tcp：`checksum.Sum.add` **把进位折叠推迟到末尾**（RFC 1071 §2 允许），并按 4096 字
  做有界折叠以保证任意长度切片都安全。原先每个字都做两次折叠，是 rv32 上校验和的主要开销。
  该轮板级实测（ch21-cwnd-emac-lab）：`cksum_us` 6423 → **4778**（126 → 96 µs/帧，
  口径是“走 `fillTcp` 的数据帧”；零拷贝组帧后数据帧的这项已并入 `asm_us`，
  小帧仍走这条路径）。
- net-tcp：`checksum.Sum.add` 把 16 位字循环**展开 4 个字（8 字节）/轮**；有界折叠
  （每 4096 字）、奇数字节配对与尾部逻辑不变。板级（ch21-cwnd-emac-lab，两轮）：
  `asm_us` 11440 → **8111**、整轮 13.8 → **10.4 ms**、吞吐 4.75 → **6.26–6.32 MB/s**，
  主机 7.5 → 3.3–4.2 ms，`mismatches=0`。线上语义已用生产 `net-wire` 复验：
  `wire: checks passed=4 failed=0`、`main: verdict=pass`。
- net-tls-http: 新增 tls_protect.zig — 记录保护(nonce=iv^seq, AD=外层头, 内层类型藏在明文末尾); seal 成功后自己递增序号，open 失败不推进; 用例 5 条; 48 -> 53.
- net-tls-http：补一条**降级可见性**用例：链模式在 `now == null`（无可信时钟）时校验通过但
  `expiry_checked == false`，该标志必须被日志引用。67 → 68 项。
- net-tls-http：`tls_client` 接上**链模式**。`Options.trust_anchor_der` + `Options.now`：
  收到 Certificate 时把叶证书复制到稳定缓冲（重组缓冲会被下一条消息覆盖），用
  `chain.verifyChain` 校验（签发关系/签名/锚/主机名/有效期），CV 改用**叶证书公钥**验；
  `now == null` 时跳过有效期并置 `expiry_checked = false`（不允许拿构建期常量假装验过）。
  错误分类：`CertificateChainFailed` / `CertificateExpired` / `CertificateHostnameMismatch`。
  用例：fixture 私钥可由固定 seed 复现，所以能造**真签名**的 CV 走完整链；
  过期、主机名不符、坏锚各自在证书这一步失败。65 → 67 项。
- net-tls-http：`Cert` 给 SAN 条目加了**类型标记** `san_is_ip`，`chain.hostnameMatches`
  只匹配 dNSName（RFC 6125 §6.4.4），不再把 iPAddress SAN 当主机名比较。回归用例
  fixture（含 `ch23.local`、`www.ch23.local`、`127.0.0.1`）：DNS 名字匹配、`127.0.0.1`
  必须不匹配。64 → 65 项。
- net-tls-http：新增 `chain.zig`——**信任链校验**的最小实现：叶证书的 issuer 必须等于签发者
  subject、签名必须被签发者公钥验过、有效期包含调用方给的 `now`、SAN/CN 覆盖主机名；
  **信任锚由调用方提供**（不采信对端链里的根），链顶不是锚时明确报 `UntrustedAnchor`
  而不是静默降级。主机名支持单级通配符 `*.example.com`（不匹配裸域/多级）。
  时钟不在组件里——没有 `now` 就不该声称验过有效期。60 → 64 项。
- net-tls-http：**修 Certificate 消息解析**——每个 `CertificateEntry` 在证书数据之后还有一个
  **2 字节的 extensions 长度字段**（RFC 8446 §4.4.2），原实现没读它，于是 `list_len`
  比条目之和多 2。板上实测：DER 完整（entry=426、`30 82 01 a6` 正确）而消息头宣告
  `list=431`，随后 `cert.parse` 因尾部多出 2 字节报 `BadCertificate`。测试用的构造器
  当初也漏了这 2 字节，所以 220 条用例全绿——现在补上并有专门的回归用例。59 → 60 项。
- net-tls-http：**修 `buildSchedule` 的双重哈希**。它接收的是转录**哈希**，但内部走
  `deriveSecret`（对 context 再哈希一次），于是 context 变成 hash(hash(CH‖SH))，与
  对端的 hash(CH‖SH) 不同 → 握手密钥全错、记录层 `RecordAuthFailed`，而转录哈希本身
  打出来是对的。新增 `expandToSecret`（context = 给定哈希）并让 `buildSchedule` 使用它；
  补一条 **RFC 8448 §3 向量测试**（这正是客户端实际走的路径，脚本化服务端两边同样多
  哈希一次，测不出来）。板上定位手段：`openssl s_server -keylogfile` 对拍。58 → 59 项。
- net-tls-http：**修 ServerHello 解析的线上格式错误**——`legacy_compression_method` 在
  ServerHello 里是**单字节**（RFC 8446 §4.1.3），原实现按 ClientHello 的
  `compression_methods`（长度+列表）读了两字节，导致其后所有扩展偏移错一位。
  板侧实测症状：`tlS: onRecord BadServerHello … BadCompression`，服务端其实已完整
  发出飞行（`openssl s_server -state` 显示 write server hello … write finished）。
- net-tls-http：新增 `Client.sealApplication()`——用应用密钥封上层记录（HTTP 走这里）。
  只有 `established` 之后可用；用例用对端的 `client_ap_traffic` 解开并逐字节比对
  （顺带钉住方向：解客户端记录要用 client_ap，不是 server_ap）。57 → 58 项。
- net-tls-http：`trust_cert_der` 收紧为**钉住证书**（PIN）语义——此前只用钉住的公钥验
  CertificateVerify，等于"任何持有自己私钥的服务端都能过"（CV 用它的公钥验它自己的
  签名）。现在对端出示的叶证书必须与钉住的 DER **完全相同**，否则 `CertificatePinMismatch`。
  新用例：钉的是别的证书、服务端出示 fixture → 在证书这一步失败。56 → 57 项。
- net-tls-http：`tls_client` 收口四处会在板上表现为"莫名失败"的问题：
  ① **应用阶段解不开**：`handleProtected` 固定用 `server_hs`，established 后必须换成
  `server_ap`（新用例：服务端用应用密钥发一条 HTTP 数据，客户端必须解开）；
  ② **错误不可分辨**：`BadFinished`/`RecordAuthFailed`/`ServerAlert` 各自独立，不再统统
  折成 `UnexpectedState`（板上日志要能区分伪造 Finished、坏 MAC 与对端 alert）；
  ③ **叶证书切片悬空**：`?cert.Cert` 持有重组缓冲的切片，下一次 push 即失效；改为只留
  SHA-256 指纹与判定布尔；
  ④ **自签校验当门槛**：CA 签发的叶证书本就不是自签的，自签校验失败不再中断握手，
  只记录 `certificate_verified_self_signed`；信任仍由 `trust_cert_der`（PIN）决定。
  55 → 56 项。
- net-tls-http：新增 `tls_client.zig`——**客户端状态机**，把 CH→SH→EE/Cert/CV/Finished→
  client Finished 串起来并完成密钥切换。三处真 bug 在主机侧用例里被抓住：
  ① `MessageReader` 存了 `&msg_buf` 的悬空指针（`Client` 按值返回后失效，症状是深层
  解析 `BadLength`）；改为按 (buf,len) 现场构造视图。② `Client` 与 `Flight` 各持一份
  转录，Finished 校验用的是缺 CH+SH 的那份；改为 Flight 独占。③ Finished 用的是 AEAD
  key（16 B）而非流量密钥（32 B）。用例：脚本化服务端跑完整握手并对拍双方转录哈希、
  客户端 Finished 用 client_hs 密钥解开后逐字节相等、篡改服务端 Finished 必须失败、
  CCS 静默跳过、fixture 证书自洽验证通过且 `certificate_trusted=false`。53 → 55 项。
- net-tls-http：**修掉一个认证漏洞**——`Flight` 收到 Finished 时只把它计入转录、
  从未校验 verify_data，伪造的 Finished 会被接受。现在 `advanceFlight` 必须带
  `server_hs_traffic`，在**计入转录之前**取快照并验（RFC 8446 §4.4.4 的边界），
  失败返回 `BadFinished`；用例补上“伪造 verify_data 被拒”。同时 ClientHello 的
  `signature_algorithms` 只通告 ECDSA P-256（`cert.zig` 只验得了这个），
  不再通告 RSA-PSS——否则服务端选了 PSS 会在 CertificateVerify 处失败。
- net-tls-http：服务端飞行的其余消息与**认证核心**。`parseCertificate`（列表逐张切 DER）、
  `parseCertificateVerify`（scheme + 签名）、`parseFinished`（32 字节 verify_data）、
  `certificateVerifyContent`（64 空格 + 上下文串 + 0x00 + 转录哈希），以及
  `keyschedule.finishedVerifyData`（HKDF-Expand-Label("finished") + HMAC）与常数时间比较。
  `Flight` 状态机强制 EE → Certificate → CertificateVerify → Finished 的**顺序**，
  错序即 `UnexpectedMessage`（顺序是认证链的一部分）。另有 `cert.verifyMessage`
  用于验 CertificateVerify 的签名。44 → 48 项。
- net-tls-http：`parseServerHello` 收紧为**硬校验**——套件只接受 `TLS_AES_128_GCM_SHA256`
  （`BadCipher`）、`supported_versions` 必须是 0x0304 且必须存在（`BadVersion`）、
  `key_share` 必须存在（`MissingKeyShare`）。三者都是“能解析但继续会用错密钥”的情形：
  服务端若选 AES-256-GCM-SHA384，下游会按错误的密钥长度派生，表现为静默算错而不是报错。
  `ServerHello.key_share` 随之去掉 Option。42 → 44 项。
- net-tls-http：握手驱动的前半件——`Transcript`（流式 SHA-256，任意点取快照）与
  `parseServerHello`（random/套件/key_share/supported_versions，缺 key_share 时字段为
  null 由调用方判死，错类型/截断/坏扩展显式报错）。用例：手工按线上格式拼一条
  ServerHello 再解析回来、流式快照与一次性 `hash()` 逐字节一致、两端 ECDHE 交叉
  算出同一共享秘密后喂 `buildSchedule`。38 → 42 项。
- net-tls-http：补上 R2.3 的两个前置件。① `random.zig`——**熵源接缝**：
  `Reader`（tagged union，将来加 `.hardware` 会在编译期逼着所有调用点处理）+
  `Deterministic`（SplitMix64，测试用，`cryptographicallySecure()` 恒 false）；
  生产组件里**不携带**任何弱随机实现（测试流由用例自带）；板侧真熵源在
  `boards/esp32s31-coreboard/src/rng.zig`（LP TRNG 0x20814000，序列照抄 IDF
  `hal/esp32s31/include/hal/trng_ll.h` + `esp_hw_support/hw_random.c`）。② `tls_handshake.zig`——
  ClientHello 编码：记录/握手/扩展三层长度、SNI、supported_versions、
  supported_groups、signature_algorithms、key_share；记录层 legacy_version
  按 RFC 8446 §5.1 用 0x0301。32 → 38 项。
- net-tcp：新增 `Conn.windowUpdate()`。TCP 的接收窗口**不会**因为应用 `recv` 了数据就
  自动变大——只有下一次出向段带的新窗口才生效。接收缓冲排空后若不补发纯 ACK，
  对端会一直以为窗口为 0（症状：发送方 `send` 秒返回、接收方永远等不到下一字节，
  两端日志都"正常"）。只在仍可接收的中间态出段，`seq/ack` 取自当前状态。32 → 33。
- net-sockets：补上**客户端形状**（此前只有服务端）。新增 `State.syn_sent`、
  `Socket.enterConnect()`、`Table.connect()`；收到 `.syn_ack` 转 `established`，
  握手期间 `send`/`recv` 返回 `in_progress`（EINPROGRESS 的等价物，不是 `not_conn`）；
  RST 回 `closed` 并置 `reset_seen`、槽位可复用。线路上的三次握手仍由 `tcp.Conn` 负责，
  本层只镜像状态——这正是 TLS 客户端在板侧需要的入口。36 → 38 项。
- net-sockets：把 `onSegment` **不校验什么**写进状态迁移表的注释，并用一条用例钉死：
  `.data` 不看 `seq`（按序到达假设），重传段再投递一次会把字节**再塞一遍**、`rcv_nxt`
  多算；`.ack` 不看 `ack` 值（`syn_rcvd` 见 ack 即 `established`）。⇒ 接真链路时
  **去重是驱动的责任**（按 `rcv_nxt` 只镜像新段），出向 seq 映射仍必须精确。35 → 36。
- net-sockets：`wire.zig` 改成**带基址**的映射。socket 层的 `seq`/`ack` 是从 0 起的
  **相对偏移**，真实 TCP 的序号从 ISS 起计，所以 RX 做 `seq − peer_iss` / `ack − local_iss`、
  TX 做 `local_iss + seq` / `peer_iss + ack`（`Bases{ local_iss, peer_iss }`，
  都是“数据流第一个字节”的序号，SYN 不占该偏移）。原样抄真实 seq 在注入模型下
  看不出问题，接真链路会立刻错位。另把 `drainTx` 的契约写准：**只在收到 ACK 之后**
  消费（`tx_buf` 是应用数据的唯一副本，重传还要用）。
- net-sockets：补上**真实链路的出向出口**——`txPending()` / `txSeqBase()` / `txPeek()`
  （`drainTx()` 原本就有）。注入模型下 `tx_buf` 只是汇、`tx_len` 只进指纹，
  接真链路时 socket 层写进去的字节必须能取出来发。**序号不变量**：`send()` 在
  缓冲时就推进 `snd_nxt`，所以待发区间的序号恰好是 `[snd_nxt - tx_len, snd_nxt)`，
  真实 `tcp.Conn` 的 ISS 要与之对齐，两套序号才不会分叉（见 `socket.zig` 注释）。
  主机用例 33 → 35（顺序/折返/基线前移）。
- net-sockets：新增 `src/wire.zig`——真实 `tcp.Segment` ⇄ 组件内 `netstub.Segment`
  的适配层（RX 的 kind 判定优先级 rst > syn|ack > syn > fin > data > ack；TX 的
  kind → flags 与端口/窗口上下文），不复制载荷、不碰网卡。主机用例 28 → 32；
  `firmware/build.zig` 的 host-test 模块补 `net_tcp` 导入（仅 net group）。
- net-tcp：`SEND_SLOTS` 8 → 32（每槽只记 `(seq, len)`，代价 256 B `.bss`），
  让慢启动能把 `cwnd` 长到 30 段上下再做拥塞避免。该轮板级实测（ch21-cwnd-emac-lab）：
  在途 10.2 KB → 20.3 KB、`srtt` 3.1 → 2.2 ms，但 64 KiB 传输吞吐 1.87 → 1.89 MB/s
  （噪声内）——队列深度不是瓶颈。后续归因与优化见 quartz 的
  `practice/zig-esp32-s31/logs/ch21-cwnd-cost.log` 与 `ch21-cwnd-opt{1,2,3,4}.log`
  （每帧 CPU 是瓶颈；零拷贝组帧后同一传输 23.4 ms / 2.80 MB/s）。
- net-tcp：`Conn` 从单段模型改成**有界多段在途**——固定发送队列（只记
  `(seq, len)`，不复制载荷、不分配），`sendData(len, inflight_cap, now_us)` 一次
  返回一段、由调用方按 `min(cwnd, rwnd)` 门控循环取值；累积 ACK 整段出队、部分
  ACK 只裁队首前缀；RTO 只重传队首（计时器仍在“未运行”时启动，见 RFC 6298 §5.1）；
  Karn 标志改为 flight 清空时复位。主机用例 27 → 32（覆盖 cap 门控、部分 ACK、
  队首 RTO、队列满、flight 清空）。
- net-wire：TCP 握手改由 `net-tcp` 的 `tcp.Conn` 驱动
  （`activeOpen`/`onSegment`/`tick`），删掉手写的 `syn_seq`/`server_seq`/`established`
  与 `sendTcp`；ESTABLISHED 后仍立刻 RST。板侧 `wire: tcp ESTABLISHED
  state=ESTABLISHED snd_una=0x20263112`（= iss+1，SYN 已被确认）、
  `wire: checks passed=4 failed=0`，`logs/e2e-net-wire-boot.log`。

## [0.3.0] - 2026-11-13

### Changed（破坏性）
- 项目更名 `s31-zig-system` → `s31-firmware`：仓库/目录、`esp_app_desc_t.project_name`、
  固件 banner、IDF 工程名（`zig_s31_system_firmware` → `zig_s31_firmware`）全部更新
- 启动路径唯一化：删除 `boards/.../start.zig`，`_start` 与 app_desc 只归 `firmware/src/start.zig`
- E2E 板级用例先按 profile 构建、镜像同步到 `zig-out/bin/app.bin`，段集合改为精确相等断言

## [0.2.0] - 2026-11-13

### Added
- 测试框架：`docs/TESTING.md`、`scripts/check-all.sh`、单元覆盖率门禁（模块可达性 + 基线）、
  E2E profile 矩阵与 JUnit 报告（`tests/e2e/run_e2e.py`）

### Changed
- 重构为生产结构：`firmware/` + `boards/` + `components/`，移除章节目录（历史见 `docs/HISTORY.md`）
- 新增编译期特性开关与聚合测试（11 个组件，323 项）
- 新增仓库规范、路线图、CI、脚本与 ADR 模板
- 默认配置（boot+net）上板：6 个子系统自检全过，`main: verdict=pass`（`logs/firmware-boot.log`）

## [0.1.0] - 2026-11-13

### Added
- 从 `hl-ljj-quartz@32f10c56` 迁出 28 个章节工程与 `tools/s31-production` 生产化原型
- 板侧日志（`logs/ch05-boot.log` … `logs/ch28-boot.log`，含 ch28 修复前 `ch28a-boot.log`）
- 仓库规范：`AGENTS.md`、`docs/REPO-STANDARDS.md`、`ROADMAP.md`

### Fixed（相对迁出来源）
- Zig 0.17 `[...]T{…} ** n` 数组重复语法（平台迁移到 `@splat`）
- ch28 首烧 `mstatus.FS=0` 导致浮点指令 illegal instruction
- provisioning 两条过强不变量测试
