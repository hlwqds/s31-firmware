# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Planned
- P1：以太网 ARP/ICMP 上层（DMA 已闭环）

### Added
- `net-wire` 可选 profile（`-Dwire=true`）：生产固件在真实链路跑 DHCP
  DORA + TCP 三次握手，host 侧 dnsmasq/socket 监听为前置；无 DHCP 时优雅跳过。
  板级证据 `logs/e2e-net-wire-boot.log`。

### Fixed
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
