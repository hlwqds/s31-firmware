# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed
- **合并镜像在 BLE 发广播时整机失声：中断桥登记错了一个下标（2026-11-27）**：blob 在 enable 里调 `intr_alloc(124)`，
  `components/bt-blobs/src/bringup.zig` 的 `intrArm` 把 MODEM_BT_MAC 路由到 CLIC 输入 24，把中断桥登记进 trap 分发表时用的下标
  是 24，而 `trapDispatch` 按外部中断号（输入号减 16）查表——查的是 8，永远查不到。泵每一轮都开着输入 24 的 IE，广播使能
  一处理，BT MAC 的电平中断进来，查不到 handler 就返回，`mret` 之后立刻再进：中断风暴，主上下文一个指令也执行不到（每秒约
  95 万次中断）。单独的 BLE 探针里没有这个风暴（那边 controller 没有走到拉起这个中断的一步），修前修后各跑一轮，与基线逐段相同。修法一行（`setHandler(routed_input - 16, …)`）；合并镜像
  在发广播使能之前多一条判据，核对源 124 的路由与分发器查到的 handler，收尾多打一行中断桥的计数；`-Dcoex-adv-irq`（trap
  处理器里每个中断调一次的钩子，每 4096 个中断打一行各输入的计数）留作诊断。单变量对照（最终代码，只把下标改回 24）：
  `check: ble interrupt bridge wired: … handler 0x00000000 ok=0`，紧跟在 `0x200A` 的回包行后面累计 2001 万次中断、没有
  `checks:` 汇总行（`logs/coex-merged-wifi-link-ble-adv-storm-boot.log`）；改回去 27/27
  （`logs/coex-merged-wifi-link-ble-adv12-boot.log`）：合成器锁定位在广播使能后 35 ms 置位、15 秒后仍是它，中断桥 15 秒里入环
  957 次、代跑 956 次，Wi-Fi 在 BLE 广播着的时候连上真实 AP、DHCP、ping 10/10（往返平均从 3.5 ms 涨到 45 ms），工作站
  `bluetoothctl scan on` 看到 `s31`。最终代码又上板一次（`logs/coex-merged-wifi-link-ble-adv13-boot.log`，27/27）：代跑的 950 次跑的都是
  blob 经 `intr_alloc(124, …)` 登记的 ISR（纯计数桩 0 次）；核的读数行多打了三组状态位（`coex_status_get` 的 wifi / ble / bt 位图）。
  顺带更正：广播间隔 0x00A0 是 100 ms（这些字段 0.625 ms 一档），此前注释里的 200 ms 是错的。`bt-blobs` 与 `wifi-blobs` 的
  `osi_impl.zig` 里 `_set_isr` 的注释原来写「`trap.setHandler` 内部归一化」，并不属实，已改成实际的约定（原样存、按外部中断号
  索引）；blob 经这条路传的编号是哪一种没有核对过。细目见 `docs/verification/coex-verification.md` §17.5。
  空口上的广播 PDU 也记到了两条（工作站 `btmon` 记 HCI 事件，`logs/coex-merged-wifi-link-ble-adv14-btmon.txt`）：`ADV_NONCONN_IND`、
  Public 地址、Flags 0x06 加名字 `s31`，RSSI -51 / -25 dBm。广播间隔没有量：bluetoothd 的扫描开着重复过滤，不带过滤的原始
  HCI 扫描没有做通。
- **`tools/ap-side/collect.sh` 默认找的 tcpdump 与实际上传的不是同一个路径（2026-11-27）**：脚本默认找 `/tmp/ap-tcpdump`，实际上传的
  二进制在路由器上叫 `/tmp/r5c-tcpdump`（内存盘，不在 PATH 里）——照文档用会静默不抓帧，在路由器上敲 `tcpdump` 也是 not found。
  改成 `$TCPDUMP` > PATH 里的 tcpdump > `/tmp/ap-tcpdump` > `/tmp/r5c-tcpdump`，输出里写明用的是哪一份，找不到时写明原因。
  静态 tcpdump 装到了测试路由器的 `/usr/bin/tcpdump`（overlay 可写，占 1.4 MB，`rm` 即卸载），README 写清上传与安装步骤。
  验证：在路由器上跑仓库里的 `collect.sh` 6 秒，输出 `tcpdump: /usr/bin/tcpdump (tcpdump version 4.99.6)`；把 `TCPDUMP`
  指到不存在的路径并清空 PATH，输出 `(tcpdump not found: …)`。
- **合并镜像在 BLE init 之后整字写回时钟 / 电源寄存器（2026-11-27）**：两边的适配层都整字写过共享的时钟字——BLE 侧
  `btdmLpEnableClock` 把 `CLK_CONF1` 写成 `0x003FF880`（清掉 Wi-Fi 的基带、MAC、APB 时钟位，这就是对照 C 里 `reason=7`
  的原因）、强开位写 `0xFF`、LPCON 写 `0x0B`；Wi-Fi 侧 `_wifi_clock_enable` 把 LPCON 写成 `0x3`，`_wifi_clock_disable`
  无条件清共存时钟、把时钟源写回 `0x25`。事后的快照写回又把 BLE 自己的时钟位（BT 三位、BLE 定时器、modem 安全模块、
  共存与 LP 定时器时钟、PLL 时钟源）全拿掉。修法：照 IDF 的时钟单元表（`modem_clock_impl.c`）两边只置自己的位，共享
  单元另一边还占着就不关，写回删除；合并镜像在四个时点按并集逐位核对。板上：四个时点都是 `CLK_CONF1=0x003FFFFF`、
  `CLK_CONF=0x7E601002`、LPCON=0x0F、时钟源 0x3D，基线 38 个 AP、之后 34 个，20/20；单独的 BLE 探针与基线逐行等价。
  细目见 `docs/verification/coex-verification.md` §16，设计见 ADR-003 第 4 节的实现记录。
- **合并镜像里 BLE 的 init 让 Wi-Fi 收不到帧（2026-11-26）**：Wi-Fi 先 `esp_wifi_start`、BLE 后 `bringup.init` 的顺序下，BLE init
  之前扫描三十多个 AP，之后 1–4 个。根因是 PHY 的一次性初始化只认第一次使能（IDF 的 `esp_phy_enable` 只在 modem 标志为 0 时
  初始化，`phy_init.c:324-342`），而 BLE 的 init 是按"单独跑"写的，有两段会重做 PHY 的打开与标定，哪一段在 Wi-Fi 之后做都伤
  Wi-Fi：`probe_ptr.initPhy()`（ICG、`phy_wifi_enable_set`、`set_bb_wdg`、`CLK_CONF1`，再走一次自己的标定）与第 15 步的
  `esp_phy_load_cal_and_init`（它看的 `s_is_phy_calibrated` 在 Wi-Fi 走探针钩子的镜像里恒为 0，等于一次全量重新标定）。
  修法：Wi-Fi start 成功后置 `probe_ptr.phy_owned_by_wifi`，BLE 的 init 两段都跳过。单独的 BLE 探针不受影响（变量默认是假）。
  - **单变量对照**（最终形态的代码上每次只关一样；日志前缀 `logs/coex-merged-wifi-link-`）：两段都跳过时 34 → 35 个 AP、
    ping 10/10（`boot.log`）；只跳过第 15 步时 31 → 1 个 AP、ping 9/10（平均 70 ms）（`onlyloadcal-boot.log`）；只跳过
    `initPhy` 时 36 → 2 个 AP、连接 `reason=2`（`onlyinitphy-boot.log`）；两段都不跳过时 39 → 4 个 AP、DHCP 3887 ms、
    ping 9/10（`noguard-boot.log`）。
  - **时钟 / 电源寄存器的写回是连接阶段必要的**：两段都跳过但不写回，扫描照常（35 个 AP）、认证与关联成功，随即被 AP 以
    `reason=7` 断开（`norestore-boot.log`）。写回的 13–15 个里哪几个必要没有再分。
  - **原来的判据抓不住接收退化**：两段都不跳过的那一轮 `verdict` 照样是 pass。`coex_merged` 加了一条判据——BLE init 之后
    的扫描 AP 数不得低于基线的一半；在退化的镜像上失败（`2 vs 36`），在最终形态上通过（`35 vs 34`）。
  - 初稿把责任只归给第 15 步的重新标定（`initPhy` 只是"顺带跳过"），对照推翻了它，已更正。排查阶段还排除过（当时的读数，
    原始日志没有入库）：泵里的 BLE 轮转、时基、只或回时钟位、快照全写回、Wi-Fi 停掉再 start；换 IDF 真的 modem clock 对象
    那一轮仍然聋，但与标定被 BLE 用掉混在一起，不能单独归因。
  - 没有做的：两段各自伤在哪一步没有再拆；时钟域的正解（见 Added 的 `-Dcoex-wifi-link`）。细目见
    `docs/verification/coex-verification.md` §15。
- **不开 `-Dcoex` 的 Wi-Fi 探针镜像收不到任何帧（2026-11-26）**：扫描逐信道走完但恒为 0 个 AP，连接 `reason=201`。根因在
  `osi_impl.zig` 的 `shellCoexPtiGet`：它把 PTI 出参写成 0 再返回 0，而 IDF 的关闭分支（`esp_adapter.c` 的 `#else`）返回 0、
  **不写出参**。blob 把 PTI 0 编进 MAC 的 PTI 表（`0x20104DD4` / `0x20104DD8` 全 0），RX 缓冲字跟着全 0，收不到帧。
  修法：桩不再写出参。验证是单变量的——计数桩的镜像只改这一行，扫描 37 个 AP、连上 2625 ms、DHCP 50 ms、ping 10/10
  （修之前 `logs/wifi-link-nocoex-boot.log`，修之后 `logs/wifi-link-stubs-pti-boot.log`）；胶水按 IDF 关闭分支作答、
  核不启动的镜像同样正常（`logs/wifi-link-coex-off-boot.log`）。连带澄清：共存核不是 Wi-Fi 收发的前提，先前所有成功的
  轮次都开着 `-Dcoex`，只是因为真核心回了真的 PTI。没有做：其余钩子的计数桩与 IDF 关闭分支的逐项对照。
  细目见 `docs/verification/coex-verification.md` §13。
- **Wi-Fi 连上真实 AP 之后数据帧解不开、ping 网关时通时不通（2026-11-26，路线图 R3.2.3 的数据通路）**：两处根因，各修一处。
  ① 镜像的 `memcpy` / `memmove` / `memset` 是 compiler_rt 的逐字节循环，而 blob 装钥匙的 MAC 密钥表是整字寄存器堆：每 4 个字节
  只剩最后 1 个。四次握手照常完成、驱动也报成功，数据帧却双向都解不开——连上之后 DHCP 12 秒没有应答。修法：
  `boards/esp32s31-coreboard/linker/rom_syms.ld` 用赋值（不是 `PROVIDE`，它对已定义的符号不起作用）把这三个名字指到 ROM 的实现，
  与 IDF 的同一个文件逐条一致。**全镜像的内存原语因此都换成 ROM 的实现，默认镜像也受影响**：`net` profile 上板复验
  `PASS board:net`（8/8 段、`main: verdict=pass`，`logs/e2e-net-boot.log`）；容量门禁与 e2e（host）六个 profile 通过。
  ② `components/wifi-blobs/src/data_path.zig` 只处理 ARP 应答，不答问本机地址的 ARP 请求：网关的邻居缓存里没有本机时，回显应答
  发不出去（网关每一帧回显请求之后都先来问本机的 MAC）。修法：`handleArp` 加上应答（单播给问的人），并加了主机用例。
- **Wi-Fi 连接路径上的三处运行时问题（2026-11-26，路线图 R3.2.2 的连接）**：① Wi-Fi 任务栈按 blob 请求的 6656 字节给，四次握手实际用
  9252 字节，长了过界 2.6 KiB，压坏栈下面的对象；`osi_impl.zig` 把栈的下限提到 16 KiB，栈底下留 256 字节护栏、泵每一步查一次。
  ② `esp_wifi_set_config` 把 STA 配置逐字段写成四十多个 NVS 键，原先每个槽自带 2048 字节的 RAM 版 NVS 装不下（驱动回 `0x1105`）；
  `nvs_ram.zig` 改成键表加分档的 blob 池。③ `wpa_sta_rx_eapol` 回调返回的是发送结果（成功为 0），而 IDF 的 `wpa_sm_rx_eapol`
  是"处理了 1、解不开的帧 0、校验不过 -1"，驱动按它选日志——板上每一帧处理成功的握手都打 `wpa_psk handle fail`。已按 IDF 的约定改。
- **Wi-Fi blob 扫描不到任何 AP（2026-11-26，路线图 R3.2 的扫描）**：`esp_wifi_start` 之后扫描能逐信道走完，但一条帧都收不到，
  结果恒为 0 个 AP。根因有两个，各修一处。① 裸机镜像没做 IDF 应用启动期 `bootloader_init_mem()` 里关 APM 访问控制过滤器的三行
  （二级 bootloader 里这段被 `#if !BOOTLOADER_BUILD` 跳过），`HP_APM` / `HP_MEM_APM` / `LP_APM` 的 `FUNC_CTRL` 停在复位值
  `0x7F` / `0x3F` / `0x0F`，只放行 TEE master——Wi-Fi MAC 的 DMA 属 REE，射频收到的帧写不进内存（与 ch17 以太网 DMA
  不取描述符是同一个根因）。出处用对照镜像 ELF 的反汇编核对（`bootloader_init_mem` 正好是三条写 0）。修法：板级包新增
  `boards/esp32s31-coreboard/src/apm.zig`（`board.apm.disableCtrlFilters()`，写 0 并读回），`initOnly()` 开头调用。
  ② 镜像里没有 IDF 的 `wpa_supplicant` 组件，`esp_wifi_init()` 收尾的 `esp_supplicant_init()` 没人做，blob 的 supplicant
  回调表指针（`g_ic->[444]`）是空的，而扫描路径对它有一处不判空就解引用，关掉 ① 之后第一帧 beacon 就
  `load access fault @0x54`。修法：`components/wifi-blobs/src/wpa_cb.zig` 登记自己的回调表（`struct wpa_funcs` 的 Zig 镜像，
  偏移用 comptime 断言钉死），先填四个——`wpa_sta_init` / `wpa_sta_deinit` / `wpa_sta_disconnected_cb` 驱动 `wifi-connect`
  自己的请求方（`wifi-connect` 为此新增公共入口 `api.zig`，`firmware/build.zig` 以模块名 `wifi_connect` 给出），
  `wpa_parse_wpa_ie` 是 IDF 同名函数的移植（blob 拿它判每个 AP 的 authmode；位值抄 IDF 的 `defs.h`，编译开关取对照镜像的）。
  连带：探针不再用从对照镜像 NVS 里读出来的 PHY 标定数据（`cal_staged.zig` 删除），每次启动全量标定，只多约 30 ms；
  `wifi-blobs` 的主机测试目标此前编不过（临界区的 RISC-V 汇编与 PHY 壳缺 `board` 模块、缺符号替身），已修。
  验证：板侧扫描 `Send scan done event: status=0, apnum=38`、`esp_wifi_scan_get_ap_records rc=0x0 got=38`
  （`logs/wifi-link-scan-boot.log`，邻居的 SSID 与 BSSID 已脱敏）；连续 5 次上板扫描全部完成（32–41 个 AP）；与同板 oracle
  同一时段的结果逐 AP 对照，oracle 看到的 8 个 AP 里 7 个一致（信道、authmode、SSID 相同，RSSI 差不超过 3 dB），第 8 个那一轮
  没扫到。主机用例 2032 → 2045（`wifi-blobs` 31 → 43、`wifi-connect` 431 → 432）；`scripts/check-fmt.sh`、
  `scripts/check-host.sh`、`scripts/check-coverage.py`、`scripts/check-invariants.py` 通过。没有做：连接（WPA2-PSK 关联 +
  4 次握手）、收发、PHY 标定数据的持久化；回调表里连接路径的入口还没填，其中多处调用点不判空，连接之前必须先填齐。
  （连接与收发已于同日晚打通，见上面两条。）
  **【2026-11-26 补记】**同日曾把"去掉 `-Dcoex` 的同一份探针收不到帧"记成本条的第三个前提，查清后撤回：那是那种构建里
  `_coex_pti_get` 的计数桩把出参写成 0（IDF 的关闭分支不写），不是缺了共存核，见「Fixed」里"不开 `-Dcoex` 的 Wi-Fi 探针镜像
  收不到任何帧"一条。
- **Wi-Fi 探针在扫描走通之前修掉的几处运行时缺陷（2026-11-25 至 26；与上一条同在提交 `a28df73`，当时只写进了提交说明，这里补记）**：
  ① `link_stubs.zig` 的国家码 / 信道表原是 4 KiB 的零值桩——链接能过，但驱动拿到的是「没有国家配置」，扫不到任何 AP；换成 IDF 的真实数据。
  ② `osi_impl.zig` 的软件定时器表只有 16 项，扫描起始的信道定时器排不进表，扫描走不完；扩到 32 项。
  ③ `rtc_clk_xtal_freq_get` 原是返回 0 的计数桩，libphy 的 `phy_get_xtal_freq` 按它把 `xtal - 1` 写进 `MODEM_LPCON_TICK_CONF` 的低 6 位
  （读回 `0x3F`；40 MHz 晶振应是 `0x27`）；改为返回板级晶振频率。
  同批还有：PHY 使能 / 关闭的壳按 IDF `esp_phy_enable` / `esp_phy_disable` 对齐；`_read_mac` 取 eFuse 里的出厂 MAC；`_slowclk_cal_get`
  取同板对照镜像的实测值（本镜像没有做实测）；临界区不再是空实现；`_task_delay` 不再让出 64 次就返回；blob 日志真格式化，
  `initOnly()` 在 init 收尾设日志级别。没有做：慢时钟标定的实测、PHY 标定数据的持久化。
- **Wi-Fi blob 的 `esp_wifi_start` 不返回（2026-11-25，R3.1 的卡点）**：blob 在 `esp_wifi_start` 里等 `MAC_ST`
  （0x20104CAC）的忙位 bit 13–15 自清，我们的运行时里它们停在复位值。根因是裸机镜像没做 IDF 启动期 `pmu_init()`
  （`esp_rtc_init()` 里调）的一步：给 ACTIVE / MODEM / SLEEP 三个 HP 电源模式写 modem 的 ICG 码（2 / 1 / 0）并触发两次
  立即更新。码是复位值 0 时，时钟适配层写的门控位图（各域 `0x6`）对不上，`CLK_CONF1.clk_wifimac_en` 是 1 而 Wi-Fi MAC
  的核没在跑。定位方法是与官方 IDF 在 `esp_wifi_init` 之后对照 523 个有定义的寄存器（差集 95 个）再做单变量实验，
  记录在 ADR-001 文末。修法：板级包新增 `boards/esp32s31-coreboard/src/pmu.zig`，`wifi-blobs` 的 `initOnly()` 开头调用；
  `_wifi_clock_disable` 按 IDF 补齐（清 `clk_coex_en`、不在 disable 时复位 BB），init 之后 `LPCON+0x18` 由 3 变成与 IDF
  相同的 1。验证：板侧 Wi-Fi 探针 `esp_wifi_start rc=0`、init 之后 `MAC_ST=0x00000000`
  （`logs/wifi-probe-start-rc0-boot.log`）；合并镜像重跑 `main: verdict=pass`；`scripts/check-all.sh` 与
  `run_e2e.py --board --profile net` 通过。主机用例数不变。没有做：`esp_wifi_start` 之后的扫描与连接；
  BLE 侧不接这一步（接了 BLE 探针锁死，属 R3.3）。
- **`rrm.maxMeasurementDurationTu` 对 MIB 1–3 下溢（2026-11-25，第四批复核时发现）**：11.11.4 的最大量测时长是
  2^(dot11RMMaxMeasurementDuration − 4) × BeaconInterval，MIB 取 0–7。旧代码做 `u32` 减法，MIB 为 1–3 时下溢，函数返回 `maxInt(u32)`
  （等于不限）。现对这三个值取向下取整的 TU 数；MIB 为 0 与 ≥4 的结果不变。有用例。
- **板侧自检「以固件参数交叉编译」的假绿（2026-11-24）**：本轮复核时用来单独编译自检的 `zig build-obj` 命令把
  `-target … -mcpu … -OReleaseSmall` 放在最后一个 `-M` 之后。Zig 0.17.1 的命令行里这类参数作用于其后声明的模块，
  写在最后没有任何模块用到：根、自检、`board` 三个模块全是本机 x86_64，命令退出 0 却什么都没证明（产物 `ELF64 … X86-64`）。
  改法：参数写在第一个 `-M` 之前（后续模块沿用），根文件加编译期断言（`builtin.target.cpu.arch != .riscv32` 即
  `@compileError`），并用错误写法做负对照（三个模块的守卫都报 x86_64）。方向别记反：参数写在 `-M` **之后**是从下一个模块
  才生效，根模块会落回本机架构。
  重跑：`wifi-mlme`、`wifi-connect`、`ble-802154`、`ble-security`、`radio-coex` 五个自检以固件参数编译通过；
  `wifi` profile 的镜像构建与板上运行是另一份独立证据，结论不变。更正记录在
  `docs/verification/wifi-ieee80211-verification.md` §5.1 与 `docs/TESTING.md`。

- **bt-blobs 主机门禁（2026-11-23）**：`scripts/check-host.sh` 自 BLE 实验轮次起在 `firmware` 上
  失败（`zig build test`：`1df82d5` 通过，`c50a763` 及其后每个被测提交失败；`ci.yml` 的 `host`
  job 跑的正是这一步，`image`/`e2e` 依赖它）。两处补齐，依据是 bt-blobs README 的判读纪律
  （新增目标侧引用必须让主机门禁保持绿）：
  ① `bringup.zig` 新增引用的 `esp_phy_enable`、`phy_i2c_writeReg`/`phy_i2c_readReg`、
  `modem_clock_module_mac_reset` 没有主机桩 ⇒ 链接期 4 个未定义符号；补进只被
  `host_tests.zig` 导入的 `host_stubs.zig`（不进镜像）。
  ② `init` 路径上 4 处裸 MMIO（`enter()` 的 LP 复位原因槽，轮 120t；轮 123g/123i/130 的三个
  实验块）没走同文件的 `mmioRd`/`mmioWr`/`mmioSet` ⇒ 主机上 3 条 bringup 用例段错误；改走助手，
  它们在目标上展开成同样的 volatile 访问。
  验证：`scripts/check-host.sh` → `pass=5 fail=0`（firmware 548，bt-blobs 18/18），
  `build-image.sh firmware` 与 `run_e2e.py --host`（6 个 profile）通过；probe 镜像与父提交逐段
  比对，`.flash.text`/`.flash.rodata`/`.iram_blobs`/`.data`/`.trap_ram`/`.bt_lp_data` 六段
  SHA-256 全部相同（板上机器码不变；未重新上板）。

- **非探针 BLE 闭包链接（2026-11-24）**：`scripts/check-bt-link.sh` 自 BLE 实验轮次起链接失败，11 个未定义
  符号都是只在 `-Dbt-probe` 构建里编译的诊断导出（`probe_dump_now`、`bt_print_osal_stats`、`dbg_tim_*`、
  `s31AssertYield`、`s31_bt_*`），而 `trap.zig` 在 `bt_linked.present` 为真时、
  `components/bt-blobs/link/*.c` 无条件引用它们。非探针的闭包链接是共存的合并镜像要用的形态（ADR-003）。
  新增 `components/bt-blobs/link/closure_stubs.zig` 给出与探针默认行为一致的空实现，经
  `firmware/build.zig` 的非探针分支挂进 app 的模块树；不能单独成对象，否则会把 `board` 的导出再编一份。
  验证：`scripts/check-bt-link.sh` → `bt 链接门禁：OK（116 个对象，镜像 950756 字节）`，
  `.flash.text` 745 056 B；`build-image.sh firmware` → `image: OK`。探针镜像与不带 blob 的镜像不编译该文件。

- **两条本地门禁的既有失败（2026-11-24）**：在 `3194bf6` 上 `scripts/check-all.sh` 本来就过不了，与本轮改动无关。
  `check-capacity.py`：基线停在 2026-11-18（`a59e5d7`），之后六个 profile 的 irom 已有 21 504 到 31 504 B 的漂移。
  漂移的来源量过：`boards/esp32s31-coreboard/src/trap.zig` 在 BLE 调试期间累积的诊断代码让 `trapDispatch`
  从约 5 350 B 长到约 25 600 B，并带进 5 160 B 浮点格式化；它没有构建开关，所有 profile 都编进去，本轮没有动它。
  `update_matrix.py --check`：`2d431d0` 恢复 `logs/e2e-net-wire-boot.log` 之后，矩阵 W1–W3 没有跟着刷新。
  两处都用脚本自带的再生成对齐到已提交的代码与日志，没有手改数字。细目见 `docs/verification/README.md`。
- **`wifi-blobs` 的主机测试从没被跑过（2026-11-24）**：它没有自检 section，`firmware/build.zig` 的通用循环
  建不出它的测试目标；`check-coverage.py` 只数 `test` 的文本个数，照样判 OK。补上目标后连报：
  `host_tests.zig` 里 `testNowUs` 定义两次、一个用例访问私有的 `impl.hooks`、`osi.zig` 的 `indexOf`/`nameOf`
  用了 0.17 已改名的 `.fields`、`osi_impl.zig` 的 `shellSetIntr`/`shellSetIsr`/`shellIntsOn/Off` 在主机上
  直接写 MMIO 并执行 RISC-V 汇编、链接期缺 5 个板级符号。修法：显式测试目标、`host_stubs.zig` 给替身、
  四个壳在非 freestanding 目标上提前返回、`.fields` 改 `.field_names`。26 个旧用例加 5 个新用例，31/31。

### Removed
- `firmware/build.zig`：删掉 152b92a 给 net-tcp / net-ipv4 / net-udp-dhcp-dns / net-sockets 四个模块
  多加的 `net_ethernet` 导入。那是一次没生效的模块冲突修复尝试（真正的冲突是 `wire` 与 `net`
  两个 group 同开），四个组件的源码都不引用它。`build.zig` 由此回到 2f156fa 的状态。

### Changed
- **e2e 板级抓取窗口按 profile 配置：`wifi` 60 秒、`full` 90 秒，其余仍是 30 秒**（`tests/e2e/run_e2e.py` 的 `capture_s`）。
  依据是量过的自检耗时。新工具 `tools/qemu-instr` 把同一份 riscv32 ReleaseSmall 代码放到 QEMU 的 `virt` 机器上，开
  `-icount shift=0` 读 `minstret`，得到精确的指令数；板上每条指令的周期数用 `logs/c7-perf-tiers.log` 的实测校准
  （`workload.mix`：59433 条指令对 59455 个周期，约 1.0）。`wifi` profile 除 `net_ethernet` 外合计 17.84 亿条指令，
  光计算 22.3 秒（第三批往 `wifi_connect` 里加了 6.03 亿条，约 7.5 秒；第二批的镜像按同一口径是 14.7 秒），
  30 秒窗口对它是压线的。耗时集中在 `sae_full_selftest.checkFsm`（5.10 亿条，6.4 秒）、OWE 的 8 条判据
  （2.20 亿条）与 FFC 的 PWE（1.35 亿条）；标准库的 P-256 标量乘一次约 2070 万条指令、0.26 秒。放宽窗口而不是
  继续砍判据：剩下的每一条都对应一个不同的行为。板上的实际耗时没有量过（板子不在手边）。读法见
  `tools/qemu-instr/README.md` 与 `docs/TESTING.md`「板侧自检的两条隐性预算」。

### Added
- **AP 侧的空口证据与工具 `tools/ap-side/`（2026-11-27）**：在工作站上交叉编译静态的 tcpdump（`build-tcpdump.sh`，产物与
  路由器上用的 SHA-256 相同），AP 上每轮临时建 monitor 接口抓 802.11 帧的文字摘要（`collect.sh`、`frames.py`）。五个轮次
  373 帧（`logs/coex-merged-wifi-link-ap-frames.log`，邻居的 SSID / BSSID 换成标签）：板子发来的帧 -21 到 -28 dBm，关联
  过程同序同间隔；按条款的对照见 `docs/verification/wifi-ieee80211-verification.md` §12。三份 AP 侧证据的头部原先只写
  「时钟慢 38 天 22 小时」（墙钟差），改成两个数都写：比标准时间慢 38 天 14 小时 4 分 22 秒，路由器显示的时间加 38 天
  22 小时 4 分 22 秒是本机时间（换算本身一直是对的）。帧清单注明有 5 行是 monitor 接口重复交付的。
  - `tools/ap-side/redact.py`：入库前的脱敏工具进仓库（此前只在 /tmp）：邻居的 SSID / BSSID 换成标签、自检残留，板侧日志与
    帧清单都能用；按字节透明地解码，中文一类非 ASCII 的 SSID 也能匹配上。`--save-map` 把新出现的 BSSID 写回标签表。
  - 单独的 Wi-Fi 真实链路镜像回归（时钟钩子改成只置位之后）：扫描 37 个 AP、连上、DHCP、ping 10/10
    （`logs/wifi-link-clock-union-boot.log`，脱敏）。
  - 主机用例 2064 → 2068（`bt-blobs` 67 → 69、`radio-coex` 55 → 57）：`tests/baselines.json` 与三处前门数字一起抬。
- **工作站自己的静态 tcpdump（2026-11-27）**：装之前工作站上没有 tcpdump（当时 `command -v tcpdump` 为空）。
  `tools/ap-side/build-tcpdump.sh` 加了 `TARGET=`——默认仍是路由器的 `aarch64-linux-musl`，产物与原来逐字节相同
  （sha256 `44126186…`）；`TARGET=x86_64-linux-musl` 编出的静态二进制（1 436 896 字节）装到 `~/.local/bin/tcpdump`
  （sha256 `d2cd67c6…`，`rm` 即卸载），源码目录两个目标共用。验证：`tcpdump --version` 打印 4.99.6，`-D` 列出接口；
  root 下在 `enp0s31f6` 上抓到一帧（ICMP echo request，本机 → 路由器）。
  2026-11-27 复查：登录 shell（bash）与 `sudo` 下 `command -v tcpdump` 都解析到 `~/.local/bin/tcpdump`；路由器上
  `/usr/bin/tcpdump` 在登录 shell 里也找得到，两台机器各抓到一帧。
- **最小合并镜像的构建入口 `scripts/build-coex-link-image.sh`（2026-11-27）**：从 IDF 的归档重新生成三份对象集合（此前只在
  /tmp 里），只编 `coex_merged` 这一段，断言两段镜像，打印体积与归属（`BREAKDOWN=1`）。`BLE=1` 时 1 224 304 B（factory
  分区的 79.7%）。验证镜像只编涉及的 section 的约定写进 ADR-003「验证镜像的最小组成」。
- **合并镜像里 HCI 命令从发送任务里发（2026-11-27）**：`components/bt-blobs/src/probe.zig` 的 `sendFromTask` 把命令交给一个
  独立栈上的任务（8 KB，从 BLE 的 arena 里分），阻塞走「任务 → 主上下文」的正常切换，主上下文每轮泵 controller 任务、
  再恢复发送任务；等发送与等回包按时间、轮数、CPU 周期三重封顶。此前在主上下文里发，三条广播命令连第一条都发不出去
  （整机失声）。板上七次：LE Set Advertising Parameters / Data / Enable 三条都回了 Command Complete、Status 0x00；但广播
  使能被接受之后 controller 任务不再让出，主上下文回不来——回包之后那次 flash 写不返回（落盘前回写时钟也不行），把它
  去掉之后 AP 一侧也没有第二次关联，合成器锁没锁没有读到，广播没有起来。广播实验的落盘记录（flash `0x18E000`，
  `tools/ap-side/decode-adv-marker.py` 解码）只写到 Enable 的"正要发"为止。`osal.zig` 多两个记录变量
  （`last_park_kind` / `last_park_ctx`），等待的语义不变。日志 `logs/coex-merged-wifi-link-ble-adv2-boot.log`、
  `logs/coex-merged-wifi-link-ble-adv4-boot.log`、`logs/coex-merged-wifi-link-ble-adv8-boot.log`、
  `logs/coex-merged-wifi-link-ble-adv8-ap-frames.log`；细目见 `docs/verification/coex-verification.md` §17。
  【2026-11-27 晚更正】"广播使能被接受之后 controller 任务不再让出"是误读——是中断风暴，当晚修掉，见本节顶部的 Fixed。
- **`-Dcoex-ble-adv`（2026-11-27，实验）**：合并镜像在所有判据之后经 HCI 发三条广播命令并读 synth 锁定位。第一版在
  主上下文里同步发，三次上板都停在发完第一条命令之后，整机失声（`logs/coex-merged-wifi-link-ble-adv-boot.log`）；
  当晚改成从发送任务里发，见上一条。【2026-11-27 晚更正】上一条里"广播使能被接受之后 controller 任务不再让出"的读法是错的，
  是中断风暴；修掉之后广播上了空口，见本节顶部的 Fixed。
- **合并镜像里的 Wi-Fi 真实链路：`-Dcoex-wifi-link`（2026-11-26，ADR-003 第 4 节的板级证据）**：`-Dcoex-merged` 的镜像里两个
  控制器同镜，Wi-Fi 走通真实链路——BLE init 之前 34 个 AP、之后 35 个 AP，连上 2059 ms，DHCP 51 ms，ping 网关 10/10
  （rtt 平均 3.8 ms），连着 5 秒，本地断开，16/16 项通过，`verdict=pass`；BLE `INITED`、`ENABLED`（`-Dcoex-ble-enable`）。
  - `firmware/build.zig`、`firmware/src/coex_merged.zig`：section 的顺序是 Wi-Fi init → **Wi-Fi start** → 基线扫描 → BLE init
    （→ enable）→ 时钟 / 电源寄存器写回 → Wi-Fi 扫描、连接、DHCP、ping、断开；判据多一条「BLE init 之后的扫描 AP 数不低于
    基线的一半」。顺序不能反，原因见本节 Fixed。
  - `components/wifi-blobs/src/link_probe.zig`：真实链路主干抽成 `linkStart()` / `linkRest()`，探针的 `run()` 也用它们；
    `LinkResult` 去掉了 `start_rc`，只给"两段连着跑"用的 `linkOnly()` 已删（没有调用方）。
  - `components/wifi-blobs/src/init_probe.zig`：`radioSnapshot()` / `radioRestore(mask)`——存 523 个有文档的与 55 个定点的
    寄存器，把 BLE 的 init 改过的按区域写回。合并镜像只写回时钟 / 电源那一组（13–15 个）；`-Dcoex-dump` 打链路之前的转储。
  - 泵：Wi-Fi 的每一步之后让 BLE 的 controller 任务走一轮（`bt.probe.pumpStep()`）。
  - 镜像 1 226 480 B（只编这一段、不带符号表）；堆 210 240 B（Wi-Fi 114 688 B、BLE 95 552 B）。日志：通的一份
    `logs/coex-merged-wifi-link-boot.log`；单变量对照五份（`-dump-`、`-noguard-`、`-norestore-`、`-onlyloadcal-`、
    `-onlyinitphy-boot.log`，同一个前缀）；BLE 先 init 的那种顺序不通（标定数据是空的、3 个 AP），留作对照
    `logs/coex-merged-wifi-link-deaf-boot.log`。
  - 共存核（BLE enabled）：胶水零拒绝；blob 比只开 Wi-Fi 时多调了三个钩子（`coex_schm_interval_get`、
    `coex_schm_curr_phase_get`、`coex_schm_process_restart`），其余一致。
  - AP 侧证据（2026-11-26 晚，OpenWrt AP，只读采集）：hostapd 的日志里，修之前每一轮都是「板子没有确认认证响应」——
    发得出、收不到。最终形态是完整序列，AP 看板子 -24 dBm、双向 86 Mbit/s、15 秒里重传 0–1 次。只跳过第 15 步时，AP 发给
    板子的帧放弃 51 次（共 51 帧）、速率压到 6–8.6 Mbit/s，而信号一样强：退化在板子的接收侧。晚上又跑了 B、D 各一次，带
    站点统计：B 的第二次关联没完成（28 → 2 个 AP，`reason=4`），D 的第二次同向（30 → 4 个 AP，ping 9/10）。
    板子的 ARP 应答能跨过 AP 的桥到达同网段的另一台主机。日志 `logs/coex-merged-wifi-link-ap-syslog.log`、
    `logs/coex-merged-wifi-link-ap-side.log`；四轮的板侧日志后缀 `-noguard2-`、`-onlyloadcal2-`、`-final-ap-`、
    `-final-ap2-boot.log`（同一个前缀）。
  - 已知缺口（与共存无关）：`wifi-blobs/src/data_path.zig` 的 ICMP 分支只处理回显应答，板子不回应别人的回显请求——
    同网段的工作站 ping 板子 10 次，ARP 解析正常，一个应答都没有。
  - 边界：BLE 的射频没有起（R3.3），这是"一个射频在收发、另一个 enabled"，不是 L4b；没有空口上的帧（路由器没有外网，
    装不了 tcpdump）；时钟寄存器的写回是补救——整字写、在 BLE 的 enable 之后执行，BLE 那一侧的时钟位也被拿掉，正解是
    按两个射频的需求取并集。细目见 `docs/verification/coex-verification.md` §15。（2026-11-27：空口上的帧已补，写回已删除，
    见本节顶部的两条 Fixed 与 Added。）
- **真实链路：连上真实 AP 与数据通路（2026-11-26，路线图 R3.2.2、R3.2.3）**：真实链路探针（`-Dwifi-link-probe`）在扫描之后继续走
  连接 → 核对 MAC 密钥表 → 数据通路（DHCP + ping 网关）→ 再泵 5 秒 → 断开。
  - `components/wifi-blobs/src/wpa_cb.zig`：supplicant 回调表从 4 项填到 12 项。连接路径只做 RSN + PSK，由 `wifi-connect` 的 `Supplicant`
    驱动：`wpa_sta_connect` 选 AKM 与套件、算 PMK、把本 STA 的 RSNE 交给驱动；`wpa_sta_rx_eapol` 收 EAPOL-Key，回应经
    `esp_wifi_internal_tx()` 发出；消息 4「发送完成」后把 PTK、GTK、IGTK 装进驱动；`esp_wifi_auth_done_internal()` 通知驱动协商完成
    （少了它，驱动 10 秒后以 204 去关联）。
  - `components/wifi-blobs/src/data_path.zig`（新）：驱动的以太网帧 ⇄ 本仓库的 IP 栈（`net-ipv4`、`net-udp-dhcp-dns`）。收帧回调跑在
    驱动的 Wi-Fi 任务里（过滤、拷进环形缓冲、交还驱动缓冲），帧由主上下文的 `poll()` 处理。没有路由表、没有 socket。
  - 连带：blob 日志的 C shim 补齐格式化（左对齐、补零在负号之后、`%s` 的宽度）；`tools/wifi-idf-oracle` 在 ping 网关之后打驱动的
    省电 / 收发统计，打开 `CONFIG_ORACLE_REGDUMP` 时连上之后再取一份全量快照。
  - 板侧：`STA_CONNECTED bssid=… ch=1 authmode=3 aid=1`，从发起到连上约 3.0 s；MAC 密钥表里的成对钥匙与组钥匙和请求方手里的
    逐字节相同；DHCP 约 0.1 s 拿到地址；ping 网关连续 4 轮 10/10（rtt 平均 19–23 ms）；连上后稳定 5 秒，`DISCONNECTED reason=8`
    （`logs/wifi-link-connect-boot.log`，邻居的 SSID 与 BSSID 已脱敏）。AP 的凭据经 `-Dwifi-ap-ssid` / `-Dwifi-ap-password` 给，不入库。
    没有抓包；只有 WPA2-PSK + CCMP-128、一台 AP。细目见 `docs/verification/wifi-ieee80211-verification.md` §11。
  - 主机用例 2045 → 2064（`wifi-blobs` 43 → 62：`wpa_cb.zig` 13 → 20、`data_path.zig` 新增 6、`nvs_ram.zig` 新增 5、`host_tests.zig` 25 → 26）。
- **不开共存的对照；合并镜像里的 BLE enable；L4a 定时器读数的更正（2026-11-26）**：
  - **不开共存的对照**（ADR-003 L4a 那条「ping 与不开共存时一样」，判据成立）：`firmware/build.zig` 新增 `-Dcoex-sw-off`
    （要求 `-Dcoex`，只对 Wi-Fi 探针的 `coexBoot` 生效）——胶水照常链着，配置里 `sw_coexist = false`，钩子按 IDF 关闭分支作答，
    `boot()` 被拒、核不启动。板侧：扫描 38 个 AP、连上 2566 ms、DHCP 46 ms、ping 10/10（`logs/wifi-link-coex-off-boot.log`）。
    同日初稿把"只去掉 `-Dcoex` 收不到帧"写成了"共存核是前提"，是错的，根因与更正见「Fixed」里"不开 `-Dcoex` 的 Wi-Fi 探针镜像
    收不到任何帧"一条；`-Dcoex` 仍是可选项。细目见 `docs/verification/coex-verification.md` §13。
  - **合并镜像里的 BLE enable**：`firmware/build.zig` 新增 `-Dcoex-ble-enable`（要求 `-Dcoex-merged`），`coex_merged` section
    在两个 init 之后 enable BLE、把 controller 任务泵 1 秒、前后读 synth 区与时钟 / 射频状态寄存器（`bt-blobs/src/probe.zig`
    新增 `enableOnly` / `pumpFor`）。`bringup.enable()` 里的 anchor[8] 从写死的 `0x2f01_8720` 改成按符号取——合并镜像里那个符号在
    `0x2f024098`。板侧：`bringup.enable rc=0`、`ENABLED`，共存核 BLE 侧 `enabled`，7/7 检查、`verdict=pass`，没有锁死；
    synth 锁定位 `0x201098BC` 的 bit2 在 enable 前后都是 0——这是预期值，对 R3.3 不构成结论（初稿写成了"所以 APM / ICG /
    共存核都不是 R3.3 的解"，已更正）：合成器是广播使能命令处理之后才上电的，官方固件 enable 完成时它也是 0
    （`logs/coex-merged-ble-enable-boot.log`，`coex-verification.md` §14）。
    合并镜像的配方要加 `esp_wifi_regulatory.c.obj`，否则链接期 `regdomain_table` / `regulatory_data` 未定义。
  - **L4a 读数的更正**：`coexReadings` 原先把 `0x2010F008` 当成"核的硬件定时器寄存器"读两次，读的其实是共存低功耗时钟的配置。
    改成读定时器本身（`0x2010F040 + 16*idx` 与 `0x2010F408 + 16*idx`，出自 `coex_hw_timer_set` / `coex_hw_timer_enable`
    的反汇编）。只开 Wi-Fi 的那一轮没有定时器被武装（blob 只申请了没有配定时器的事件）；合并镜像里 BLE enable 之后 5 个定时器的
    使能位也都是 0。
- **共存的 L4a 读数（2026-11-26）**：真实链路探针开着 `-Dcoex` 时，在 start 后、扫描后、连上、ping 结束、断开前后各取一次共存核的读数
  （`init_probe.zig` 的 `coexReadings`：胶水两侧的状态、各钩子被调的次数、每次申请的事件 / 时延 / 时长与返回码、按事件的释放与 PTI、
  置 / 清的状态位、核里的状态位与调度参数、硬件定时器寄存器）。读数：胶水零拒绝；blob 的 13 次申请核都回 `0x102`，因为这些事件在核的
  事件表里没有硬件定时器（只有事件 1、2、36、38、45、46 有）；BLE 没开，核的状态位与硬件定时器都是 0。ADR-003 第 5 节把 L4 拆成
  L4a（只开 Wi-Fi，已有读数）与 L4b（两个射频都开，等 R3.3），并写下 L4b 的做法与判据。细目见 `docs/verification/coex-verification.md` §12。
  **【2026-11-26 更正】**这条里"核的状态位与硬件定时器都是 0"的后半句不成立：当时读的 `0x2010F008` 是 `MODEM_LPCON_COEX_LP_CLK_CONF`
  （共存低功耗时钟的配置），不是计数器，读两次不变说明不了定时器走没走；这一轮 blob 只申请了没有配定时器的事件，没有定时器被武装。
  `coexReadings` 已改成读定时器寄存器（`0x2010F040 + 16*idx`、`0x2010F408 + 16*idx`，出自 `coex_hw_timer_set` /
  同日补的不开共存对照见上面「不开共存的对照」一条；ADR-003 里「ping 与不开共存时一样」这条判据成立。
- **无线离线特性第五批（2026-11-25）**：与前几批同一个口径——按规范条款实现，不依赖射频、不抓空口。证据是主机用例、
  与按原文写的 Python 模型的对拍、板侧自检（主机桩与真板）。验收之后经独立评审两轮（Wi-Fi 15 条 + 残留 6 条、BLE 7 条）返修并复验，
  终态随 `wifi` profile 上板：**`PASS board:wifi`，14/14 个 section 全过、`main: verdict=pass`**——三个无线 section 的判据全部
  在真板上通过（`wifi_mlme` 121/121、`wifi_connect` 199/199、`ble_802154` 207/207，第三、四、五批之后第一次上板），
  `net_ethernet` 11/11；最小验证镜像（新增的 `--only`，只编两个无线 section，512704 B = 整份 `wifi` 镜像的 42%）
  同样 `PASS board:wifi[ble_802154,wifi_mlme]`。串口权限是同日由用户授权 `setfacl` 恢复的（此前第三、四批因此没有上板）。
  期间一次 `net_ethernet` 不过，查明是主机网口在 NetworkManager 里反复尝试激活已消失的配置把链路拉低（板侧只等 5 秒），
  与板子和第五批无关；链路稳定后同一条判据通过（板级前置已写进 `docs/TESTING.md`）。
  `tests/baselines.json` 合计 1818 → 2032（`wifi-mlme` 200 → 316、`ble-802154` 485 → 583；
  `wifi-connect` 431、`ble-security` 51 不变）。本批 Wi-Fi 与 BLE 都不涉新 RFC（BLE 的 IsoHci 引 Bluetooth SIG 的 Assigned Numbers §2.11）。
  - `components/wifi-mlme`（板侧自检 58 → 121 条）：
    - WNM 的其余子域（11.24.2–.17、9.6.14.2–.30 的子集：BSS Max Idle、TIM Broadcast、FMS、DMS、Collocated Interference、
      Channel Usage、WNM Notification、Event / Diagnostic 容器、QoS Traffic Capability；`wnm.zig` 第 15–24 节，取舍与偏离见文件头清单）。
    - GAS / ANQP 的请求方：Public Action 10–13、Initial / Comeback 的分帧与状态机、ANQP 元素子集（含 Emergency Call Number，
      9.4.5.5；`gas.zig`）。Status Code 字段 2 八位组按 9.4.1.9。
    - Block Ack：ADDBA / DELBA 帧编解码、记分板位图语义、接收重排缓冲、A-MSDU 子帧头（`blockack.zig`）。
      只做 Basic 与 Compressed 变体；`SN = WinStart + 2^11` 的归属经渲染 PDF 原文更正（三处 `<=` → `<`）。
  - `components/ble-802154`（板侧自检 152 → 207 条）：
    - PAwR：LE Set Periodic Advertising Subevent Data / Response Data / Sync Subevent 三条命令、两个事件、
      AUX_SYNC_SUBEVENT_IND / RSP 的字段许可（表 2.8 / 2.9）、数据只发一次的语义（`pawr.zig`）。
    - Connection Subrating：LE Set Default Subrate / LE Subrate Request 与 LE Subrate Change 事件、LL 侧接受 / 拒绝规则、
      40 s 过程超时（`subrate.zig`）。
    - LE Isochronous 的 HCI 接口面：ISO 数据包格式、CIS / BIS / BIG 命令与事件、BIGInfo 布局（`iso.zig`）。
  - 对拍（主代理用交付源码重编驱动、一律 `-O ReleaseSafe` 后重跑，六片合计 10513 例，全部 0 不一致；逐项数字见两份验证报告的
    §4.6 与 §4.3）：模型都照同一份规范写，不是独立实现对拍——模型与实现同错时差分抓不出来，本批实际发生两次
    （Block Ack 的窗口边界、GAS 的 NAI Realm 字段顺序），靠渲染 PDF 原文与手排向量抓到。
  - 返修与更正（验收阶段）：BlockAck 首交的窗口边界错误（主机 33 → 38、板侧 16 → 19）；WnmRest 带红测试交付（首交 34/39、
    板侧 5 条不过，另有 QoS Traffic Capability 元素长度严格判等比 9.4.2.78 严）返修后 39/39、31/0；`keepaliveVerdict` 的周期参数
    u16 → u32；GasAnqp 的「Status Code 宽度规范沉默」措辞更正为 9.4.1.9；IsoHci 的 `transparent air mode = 0x03` 补出处
    （Assigned Numbers §2.11）；WnmRest 的占空比公式推断经渲染 PDF 证实。BLE 差分驱动 `driver_pawr.zig` 的暂存区越界是
    切片驱动的缺陷，改驱动（不入库）后重跑；`pawr.zig` 本身没有问题。
  - 独立评审（2026-11-25，只读评审员）与返修：BlockAck 一片逐条核对无发现；其余五片都有实质发现，全部返修并复验——
    **P1**（Wi-Fi，主代理验收时的漏项）：CI Report 元素的 Interference Center Frequency 做成 2 八位组、元素体 19 字节，
    原图 Figure 9-427 的八位组行是 4 4 4 4 2、元素体 21 字节（5 kHz 单位下 2.4 GHz 本信道是 482 400，u16 装不下），
    合规对端的每条 CI Report 都会被拒收；已按原图重做。**P2**（Wi-Fi）：DMS Add 描述符补「恰好 1 个 TCLAS +
    TCLAS Processing」的反方向检查。**P2**（BLE）：PAwR 的 `Advertiser.respond` 改成「已答位图」。P3 七条与比原文严两处、
    文档十处、`iso.zig` 文件头的 Zephyr 引用更正（BIGInfo 只有 NimBLE 一份可对）照验证报告与 BLE 报告处理；
    未覆盖的 9.4.5.5 Emergency Call Number 照原文补齐；存疑三条照实保留。
  - **评审第二轮与一次误判（如实记录）**：Wi-Fi 残留 6 条处理完——Destination URI ≤ 253 八位组（9.4.2.90）两侧强制并补
    253 通过 / 254 拒收的用例；构造侧 URI 元素最小长度与解析侧对齐；注释与页码改正。其中 DMS 描述符构造侧的上限
    `payload > 252` 比原文严一个八位组（9.4.2.88：DMS Length 最大 253，`payload` 就是 DMS Length），主代理核对时只读了 6 行、
    误判为「不成立」并让切片别改；读完整函数后确认评审是对的，自己改成 253，补了 n = 252 可构造、n = 253 被拒的边界用例。
    BLE 第二轮七条全部解决、无新发现。
  - 集成：主机用例 2032；整份板侧自检在主机上 `wifi_mlme` 121/121（最长一行 154 字节）、`wifi_connect` 199/199、
    `ble_802154` 207/207（114 字节）；带守卫的交叉编译 rc=0（负对照触发守卫）；六份子自检 text 合计 46709 B，
    指令数最多 155665 条（预算 2400 万）。门禁：`check-invariants.py` OK、`check-coverage.py` OK；
    终态 `check-all.sh` rc=0 全绿（此前返修前第一遍停在容量门禁，`--update` 后第二遍全绿，终态基线再 `--update` 一次）。
  - 容量：`wifi` 1157568 → 1218736 字节、`full` 1255168 → 1316272 字节；factory 分区余量 317264 与 219728 字节。
    按每批约 60 KB 的增量，`full` 的余量还够 3 批左右，下一批之前要定「扩分区还是把自检移出 full」。
  - 新增验证机制：`firmware/build.zig` 的 `-Donly=<section,…>` 与 `tests/e2e/run_e2e.py --only`（用户要求验证时只编涉及的
    模块、减小镜像；两条构建期负对照验过；用法与板级前置——主机网口要有稳定链路——写进 `docs/TESTING.md`，
    验证分级补进 `docs/REPO-STANDARDS.md` §4 与 `ROADMAP.md`）。
  - 真实 AP 的对照（属路线图 R3，不属于第五批）：官方 IDF 的最小 station（`tools/wifi-idf-oracle/`）在同一块板上连用户提供的 AP
    （SSID `hl-wifi`，密码不进仓库）：关联、WPA2-PSK、DHCP、ping 网关 5/5；`s31-firmware` 自己的 Wi-Fi 仍停在
    `esp_wifi_start` 等 MAC 忙位。日志 `logs/wifi-idf-oracle-sta.log`，详见验证报告 §8。
  - 报告：`docs/verification/wifi-ieee80211-verification.md` §4.6、§5.6、§6、§8，`ble-core-verification.md` §4.3、§5.4、§6、§7；
    板级日志 `logs/e2e-wifi-boot.log` 与 `logs/e2e-wifi-only-ble_802154+wifi_mlme-boot.log`。
- **无线离线特性第四批（2026-11-25）**：与前几批同一个口径——按规范条款实现，不依赖射频、不抓空口。证据是主机用例、
  与参照实现或按原文手排的 oracle 的对拍、板侧自检在主机上的运行。**这一批当时没有上板**（串口 `/dev/ttyUSB0` 当前账号没有权限，
  见下面「板级」；2026-11-25 随第五批的镜像上板、全部通过）。
  `tests/baselines.json` 合计 1648 → 1818（`wifi-connect` 386 → 431、`wifi-mlme` 146 → 200、`ble-802154` 414 → 485）。
  - `components/wifi-connect`（板侧自检 177 → 199 条）：
    - RFC 8110 §4.5 的 OWE PMK caching：请求里同时带 PMKID 与 DH Parameter element、AP 命中与未命中、client 命中 / 回退 / 忽略、
      缓存条目与过期（`owe.zig` 的 `Cache`、`clientCacheDecision` / `apCacheDecision`、`buildAssocRequestWith`）。§4.5 没有规定缓存的有效期
      与替换策略，取自盘上 hostap 的 `rsn_supp/pmksa_cache.c`。OWE Transition Mode 不在 RFC 8110 里，未实现。
    - FT 快速切换里的 RIC：RDE 与 Block Ack 的 RIC Descriptor 编解码、一条 RIC 的结构规则、进重关联帧的条件（`ft_proto.zig` 第 5b 节）。
      只解析 Block Ack 描述符；AP 的准入决策没有建模。
  - `components/wifi-mlme`（板侧自检 37 → 58 条）：
    - RM Enabled Capabilities 元素（9.4.2.45）与 Annex E 的 Operating Class 表和查询（`rrm.zig` 第 13、14 节）；Beacon request 的
      Operating Class / Channel 校验接进判决。
    - WNM 的 TFS（11.24.12：TCLAS、TFS 的四种帧、AP 侧与 STA 侧模型、过滤匹配）与 WNM Sleep Mode Response 的 Key Data 布局
      （`wnm.zig` 第 10–14 节）。Key Data 的加密是注入点，测试只用测试替身。
  - `components/ble-802154`（板侧自检 106 → 152 条）：
    - 6LoWPAN-ND 的主机侧行为（RFC 6775：ARO / 6CO / ABRO 编解码、RA / NS / NA 的校验、上下文表、地址注册与续期、睡眠、下一跳判定，`nd6.zig`）。
    - 分片转发（RFC 8930 的 6LFF / VRB）与选择性分片恢复（RFC 8931 的 RFRAG / RFRAG-ACK 与三个状态机，`sfr.zig`）。
  - 对拍（主代理在终态代码上重跑，逐项数字见两份验证报告的 §4.5 与 §4.2）：FT RIC 的完整交换六帧对独立 oracle；OWE PMK caching 的缓存策略
    对 Python 模型 800 组；RM Enabled Capabilities 与 Annex E 的 516 行手排向量逐字节相同；TFS 与 Key Data 三个种子各 310 例、一组 930 例；
    `nd6` 的报文解析对独立手写的 Python 解析器 11500 例；`sfr` 的头部编解码 1216 组。全部 0 不一致。
    两片 BLE 的驱动二进制在交付时比被测源码旧，是主代理重编后重跑的；`nd6` 第一版差分的被接受例几乎不带选项，重写生成器后才有上表的结果。
  - 集成：主机用例 1818；整份板侧自检在主机上 `wifi_mlme` 58/58、`wifi_connect` 199/199、`ble_802154` 152/152；`scripts/check-all.sh` 全绿。
    板侧指令数在 QEMU 上量：六份新子自检合计 566360 条（`wifi` profile 的 0.03%），最深调用链仍是 23248 字节（`wifi-mlme` 驱动下 11248 → 12176）。
    镜像：`wifi` 1063200 → 1157568 字节、`full` 1182480 → 1255168 字节，`capacity.json` 基线已重写；factory 分区余量 378432 与 280832 字节。
  - 路线图：新增按规范条文的盘点——IEEE Std 802.11-2016 与 Bluetooth Core Specification 5.4 里还没实现的 host 侧领域，带原文锚点与离线可验证范围
    （`ROADMAP.md`「尚未实现的领域」）。OWE Transition Mode 的出处更正为 Wi-Fi 联盟的 OWE 规范，不在 RFC 8110 里。
  - **板级：这一批没有做**（当时的记录；2026-11-25 随第五批的镜像上板，三个 section 199 / 121 / 207 全过）。
  - 报告：`docs/verification/wifi-ieee80211-verification.md` §4.5、§5.5、§6，`ble-core-verification.md` §4.2、§5.3、§6。
- **无线离线特性第三批（2026-11-25）**：与前两批同一个口径——按规范条款实现，不依赖射频、不抓空口。证据是主机用例、
  与独立参照实现的差分、板侧自检在主机上的运行。**这一批没有上板**（见下面「板级」）。
  `tests/baselines.json` 合计 1047 → 1648（`wifi-connect` 141 → 386、`wifi-mlme` 82 → 146、`ble-802154` 122 → 414）。
  - `components/wifi-connect`（板侧自检 87 → 177 条）：
    - OWE（RFC 8110）：group 19 的 ECDH、DH Parameter element、PMK / PMKID 派生、与 4 次握手的衔接（`owe.zig`）。
    - EAP-TLS（RFC 5216 / RFC 3748）：EAP 头、Identity / Notification / Nak、分片与重组、MSK → PMK（`eap.zig`、`eap_tls.zig`）。
      TLS 引擎由调用方注入，仓库不含 TLS 本身。
    - 请求方的 4 次握手按 AKM 选 PMK 长度、PTK 的 KDF、MIC、Key Data 封装与 Key Descriptor Version（`akm.zig`）：AKM 5、6、9–12、18
      与 FT 的 3、4。此前只覆盖 AKM 1、2、8，路线图与验证报告里原先没写明，已补。
    - SAE 的其余 14 个群（`sae_groups.zig`、`bignum.zig`、`ecc.zig` 的通用曲线运算）、群协商、Password Identifier 与 Rejected Groups
      元素。后两者不在 2016 正文里，依据 hostap 源码；2016 的 12.4.4 没有群表，群号取自 IANA 注册表。
    - FT 协议（`ft_proto.zig`）：MDE / FTE 编解码、over-the-air 与 over-the-DS 的认证序列、reassociation。
    - 五份板侧子自检接入 `selftest.zig`（18 + 8 + 19 + 33 + 12 条），并各作为 1 条主机用例执行。
  - `components/wifi-mlme`（板侧自检 24 → 37 条）：无线测量与 WNM（BSS Transition Management、WNM Sleep Mode）（`rrm.zig`、`wnm.zig`）。
  - `components/ble-802154`（板侧自检 50 → 106 条）：扩展广播与周期广播的 host 侧（`ext_adv.zig`）；EATT、LE 上基于额度的 L2CAP
    连接与 Robust Caching（`eatt.zig`、`l2cap_coc.zig`、`robust_cache.zig`）；LL Privacy 与 LE Power Control 的 host 侧
    （`privacy.zig`、`power_ctrl.zig`）；6LoWPAN 适配层补全（`fifteen4.zig`）。
  - 差分（主代理在集成后的代码上重跑，逐项数字见两份验证报告的 §4）：

    | 对象 | 参照实现 | 规模 | 结果 |
    | --- | --- | --- | --- |
    | OWE | Python oracle 与盘上 hostap 的代码 | 800 组向量 | 15200 项比较，0 不一致 |
    | EAP-TLS 分片与 MSK | 独立分片器与 oracle | 1200 条记录流、4096 组 | 0 不一致 |
    | 按 AKM 的 4 次握手 | 三方对拍 | 四个种子各 2800 条命令 | 0 不一致 |
    | SAE 15 个群 | `sae_groups_oracle.py` | 1500 组整链 | 0 不一致 |
    | FT 协议 | `ft_proto_oracle.py` | 四个种子各 12000 帧 | 0 不一致 |
    | 无线测量、WNM | hostap 头文件的布局；按原图排帧的 oracle | 每个种子 12000 / 9000 帧 | 0 不一致 |
    | Database Hash、RPA | `eatt_oracle.py`、`privacy_oracle.py` | 24 张属性表；仓外 2000 组 | 0 不一致 |
    | 6LoWPAN 的 IPHC、分片、UDP 校验和 | 盘上 IDF v6.1 自带的 lwIP 源码 | 种子 7、42、99，各 1000 个报文 | Zig 自往返与 UDP 校验和 3000/3000；与 lwIP 的不一致分四类，逐类对到了 lwIP 源码或 RFC 6282 原文 |

  - 复核中发现并修掉的实现缺陷三处（`ft_proto.parseAuth` 先读后查长度、`ricProtected` 的错误码、`wnm.parseSleepResponse` 对带 TFS 的
    响应），以及 6LoWPAN 与 lwIP 之间的一个已知互通缺口（lwIP 的压缩器把没用到的上下文槽当成与 `::` 的前 64 位匹配，用有状态
    压缩编码 `::` 并指向那个没人配置过的槽，本实现因上下文不存在而拒解），记在两份验证报告的 §5、§6。
  - 集成时对板侧做的三处调整（主机用例与差分不变）：
    ① SAE 其它群的自检收窄：双端对打只做 ECC 25，其余八个群只验群的参数（判据仍是 33 条）。九个群全做对打时这份自检在主机
    ReleaseFast 上是 19–36 ms，是已在板上跑过的 `sae_full_selftest.zig`（12 ms）的两到三倍，而 `wifi` 镜像的全部 section 要在
    e2e 的 30 秒抓取窗口里出判决；收窄之后是 2.4 ms。
    ② 自检入口与判据函数加 `noinline`：第三批的九份子自检入口、`wifi-connect` 里第一、二批的三份入口，以及 SAE 其它群自检的
    判据函数。原先它们的定长大数组被内联、叠在调用方的栈帧里，`wifi-connect` 的自检驱动函数栈帧 8144 字节，按保留符号的镜像
    静态估算最深的一条调用链是 30384 字节。只给第三批的入口加时最深链反而比之前深（28272 对 26544），三份入口一起加上之后
    驱动函数是 1120 字节，最深链 23248。主栈在链接脚本里标称 16 KiB，按这个估算自检早就越过了标称的栈底；在板上没有量过。
    记在 `docs/TESTING.md`「板侧自检的两条隐性预算」。
    ③ 镜像体积：`wifi` 738848 → 1063200 字节、`full` 853632 → 1182480 字节（其余四个 profile 不变），`capacity.json` 基线已重写。
    增长来自第三批新增的模块与子自检：`wifi` 镜像里函数代码多 234412 字节，`wifi-connect` 占 134912，标准库 28930
    （几乎全是 P-384 的域运算），`ble-802154` 53332，`wifi-mlme` 17238。逐文件的归因在
    `docs/verification/wifi-ieee80211-verification.md` §5.4。factory 分区（1500K）的余量是 472800 与 353520 字节。
  - **板级：这一批没有做。** `wifi` profile 上板之前，`wifi_connect`、`wifi_mlme`、`ble_802154` 三个 section 在板上的读数仍然是
    第二批的 87、24、50；第三批之后应当是 177、37、106。板上的耗时与栈的实际占用都没有量过（耗时按指令数的估算见上面「Changed」）。
  - 报告：`docs/verification/wifi-ieee80211-verification.md`、`ble-core-verification.md`。

- **无线离线特性第二批与 HCI 一致性自检（2026-11-24）**：不依赖射频、不抓空口，按规范条款实现——Wi-Fi 取 IEEE Std 802.11-2016，
  BLE 取 Bluetooth Core Specification 5.4（两者都不是 RFC；其上的 RFC 单列）。证据分主机用例与板侧自检两级；空口没有任何证据。
  `tests/baselines.json` 合计 830 → 1047（`wifi-connect` 57 → 141、`wifi-mlme` 61 → 82、`ble-802154` 68 → 122、
  `bt-blobs` 19 → 67、`radio-coex` 45 → 55）。
  - `components/wifi-connect`（板侧自检 28 → 87 条）：
    - SAE 完整协议（12.4）：P-256 点运算（`ecc.zig`，与 `std.crypto.ecc.P256` 在随机点上一致）、hunting-and-pecking、
      Commit / Confirm、12.4.8 状态机、Anti-Clogging Token（`sae_full.zig`）。只支持 group 19。
    - **更正 pwd-seed**：counter 是单个八位组（12.4.4.2.2，与 hostapd 的 `u8 counter` 一致）；原实现编成 LE16。
      `vectors.zig` 的三个值换成 Python `hmac` 独立算出的值。Annex J.10 的 pwd-value 与 KCK/PMK 三行与 12.7.1.7.2 正文不符
      （只有单八位组 KDF counter 才复现）；实现与 hostapd 的 `sha256_prf_bits()` 逐字节同构，按正文走。
    - FT 密钥层次（12.7.1.7、13.4）：KDF、XXKey、PMK-R0 / R1、PTK 与名字（`ft.zig`）。IEEE 没有 FT 派生的测试向量，
      期望值取自独立实现 `/tmp/s31-oracle/ft_oracle.py`。
    - 256 位套件（12.5、12.7.2、12.7.3，表 12-8）：CCMP-256、GCMP-256、BIP 的四个变体、256 位 KEK 的 Key Data 封装、
      Key MIC、Key Descriptor Version（`suite256.zig`）。与独立参照的全量差分：14 组、3568 条向量、3928 项比较，0 不一致。
    - 三份板侧子自检（SAE 24 条、suite-256 22 条、FT 13 条）接入 `selftest.zig`，并作为 3 条主机用例执行。
  - `components/wifi-mlme`（板侧自检 16 → 24 条）：QoS Control 的布局与子字段、UP / AC 映射、EDCA 参数集、QoS Capability
    （`qos.zig`）；省电：PM / More Data、PS-Poll、TIM 与部分虚拟位图、DTIM、监听间隔、U-APSD（`powersave.zig`）。
  - `components/ble-802154`（板侧自检 19 → 50 条）：ATT 服务端（Vol 3 Part F 表 3.43 的全部操作码、排队写、通知与指示，
    `att_server.zig`）、GATT 服务端（`gatt_server.zig`）、GATT 客户端（`gatt_client.zig`：对附录 A 的示例属性表做完全部
    发现、读、写、订阅过程）、AES-CMAC 与签名（`cmac.zig`）。ATT 线上结构与 NimBLE 的 PDU 尺寸定义逐条一致。
    这批用例此前一次都没被执行过；第一次执行 119 过 / 3 败，全是用例里手敲的期望值有误（6 处），按规范改正后 122/122。
  - `components/bt-blobs`（主机 19 → 67 项）：对真实 controller 的 HCI 一致性自检（`hci_conformance.zig`）。26 条只读的本地信息
    命令，按 Vol 4 Part E 校验回包，并按表 3.1「LE Controller」列与 controller 自己声明的 Supported_Commands 位图判决
    （`verifyDeclared`；不支持的命令回 `0x01` 算合规，Command Status 形态的回包也接受）。文件内原有的 23 条用例第一次被执行
    （3 条用例自身有错，已修），新文件 23 条。
  - 板级（2026-11-24）：`run_e2e.py --board --profile wifi` → `PASS board:wifi`，14/14 段、`main: verdict=pass`
    （`wifi_connect` 87/87、`wifi_mlme` 24/24、`ble_802154` 50/50；`logs/e2e-wifi-boot.log`）。HCI 一致性自检随 BLE 探针上板：
    **26 条里 20 条合规、6 条与 5.4 不一致**（`logs/hci-conformance-boot.log`）——2 条声明不支持却回成功
    （Read Local Extended Features、Read Local Supported Codecs [v1]，表 3.1 对 LE 标 E）、3 条声明支持却回 `0x0C`、
    1 条声明不支持却回 `0x0C` 而不是 `0x01`。与 controller 配置的关系未验证。
  - 自检在探针里的位置：A 阶段之后、射频实验之前同步跑完。它原先挂在主泵循环上永远轮不到（脚本在进主循环之前就停在
    0x200A 的 synth 墙上）；第一次上板又因 tick 在回包不是本命令的 Command Complete 时先返回、超时判断走不到而无限空转
    （`logs/hci-conformance-run1-hang.log`），已改为超时先判。
  - 报告：`docs/verification/wifi-ieee80211-verification.md`、`ble-core-verification.md` §2–§8。

- **共存：运行时统一、合并镜像与窗口扩大（路线图 C3、C4，2026-11-24）**：构建开关 `-Dcoex-merged` 把 Wi-Fi 与 BLE 两套适配层和
  两个 blob 链进同一个镜像，各段自检之后多跑一个 `coex_merged` section。
  - 冲突面实测 12 个符号（Zig 层 6 个导出撞名、链接器 6 个重复符号），未定义 0。按「真归档 > 能用的实现 > 计数桩」各留一个
    提供者，落选的一方改成弱符号导出（Zig `@export(…, .{ .linkage = .weak })`，C `__attribute__((weak))`）。没有合并两个上下文
    切换器、没有删除 `bt-blobs` 的 osi 副本、没有把 trap 钩子改成多槽——逐项量过之后不需要，依据见 ADR-003 第 2 节的实现记录。
  - 入口：Wi-Fi 侧的 init 从探针的 `run()` 抽成 `init_probe.initOnly()`；BLE 侧新增 `probe.initOnly(region)`。两边对内存布局写死的
    探针地址由开关关掉；`osal.logLine` 的可执行区判定从写死的地址范围换成链接脚本的 `_text_start` / `_text_end`。
  - 链接脚本：irom `0x40000020` 长度 `0xC0000` → `0x1C0000`，drom 基址 `0x40100020` → `0x401D0020`、长度 `0xB0000` → `0x1C0000`。
    默认镜像因此只有重定位差异（反汇编逐条比较零差异，1 905 处常量各差 `0xD0000`）。分区表没有改。
  - 验证：合并镜像上板 8/8 段通过、`main: verdict=pass`，`esp_wifi_init_internal rc=0`、`bringup.init rc=0`
    （`logs/coex-merged-boot.log`）；irom 新上限由合并镜像自己证明（`.flash.text` 825 744 B），drom 新上限由
    `-Dfat-rodata=1000000` 的镜像证明（DROM 段 1 046 816 B，`logs/fat-rodata-1000000-boot.log`）。细目见
    `docs/verification/coex-verification.md` §6、§7。
- **共存：PHY 与时钟域的归属模型（路线图 C5，2026-11-24）**：`components/radio-coex/src/owner.zig`。`Owner.acquire / release(side)`
  返回一串要串行执行的动作，公共部分（PHY、共存时钟）只随首个与末个使用者各动一次，对应 IDF `esp_phy_enable` / `esp_phy_disable`
  的引用计数；`ClockBits` 让两个子系统共享一组时钟使能位。只有主机验证（`radio-coex` 主机用例 45 → 55）；寄存器序列没有接。

- **Wi-Fi 与 BLE 的离线可验证特性（2026-11-24）**：按规范条款实现的纯逻辑组件，不依赖射频；空口没有任何证据。
  - 新增 `components/wifi-mlme`（61 项）：IEEE Std 802.11-2016 非 AP STA 侧的帧格式（9.2）、管理帧（9.3.3）、
    信息元素（9.4.2 的子集）、robust 判定（12.2.8、12.6.20）、MLME（11.3）、扫描（11.1.4）。FCS 按 9.2.4.8
    的原文推出反射式 CRC-32。向量：Wireshark wiki 的公开抓包、Annex J.9、按条款手工构造。
  - `components/wifi-connect` 扩展（20 → 57 项）：PSK、PMKID、PTK、GTK（12.7.1），完整的请求方 4 次握手与
    组密钥握手（12.7.6、12.7.7、12.7.10），密钥数据封装与 AES Key Wrap（12.7.2；RFC 3394），RSNA 选择
    （12.6），CCMP-128、GCMP-128、BIP-CMAC-128（12.5.3、12.5.5、12.5.4），管理帧保护与 SA Query。
    官方向量：Annex J.3、J.4、J.6.4、J.7、J.8、J.9.1、J.9.2、J.11。
  - `components/ble-802154` 扩展（20 → 68 项）：HCI 控制命令与事件（Vol 4 Part E）、ACL 分段重组、L2CAP
    （Vol 3 Part A）、广播数据与地址（Vol 3 Part C）、IPv6 over BLE（RFC 7668）。
  - 新增 `components/ble-security`（51 项）：SMP 密码学工具箱（Vol 3 Part H 2.2），legacy 与 LE Secure
    Connections 的全部配对方法（双角色），密钥分发与绑定存储，链路层 AES-CCM、CRC-24 与白化（Vol 6 Part B）。
  - 验证：主机测试、与独立 Python 参照实现的差分（全部一致）；板级自检跑了两次。第一次（`wifi` profile）
    `ble-802154` 18/19，失败的一条是自检自身的差一错误；修复后复验 14/14 个 section 全过
    （`logs/e2e-wifi-boot.log`，整体判决 pass）。
    报告在 `docs/verification/`；`tests/baselines.json` 合计 572 → 830（其中 `bt-blobs` 17 → 19、`osal` 20 → 29、
    `wifi-blobs` 26 → 31，含此前已有或从未被跑的用例；前门总数随之改为 830）。
- **BLE 与 Wi-Fi 共存的 glue（2026-11-24）**：设计见 `docs/adr/ADR-003-ble-wifi-coexistence.md`。新增
  `components/radio-coex`（45 项），对照 IDF 的 `esp_adapter.c` 与 `btdm_coex.c` 实现 Wi-Fi 侧 23 个包装函数、
  BLE 侧 16 个钩子加 4 个生命周期函数、20 表项的适配表；真核心经 `bind.zig` 绑定。接进两套适配层见下一条。
  默认镜像逐字节不变：`3194bf6` 与本轮改动后，`min`、`net`、`tls`、`net-wire` 四个 profile 的 `app.bin` 与 `app.elf`
  SHA-256 全部相同（默认镜像即 `net`：`app.bin` 243 488 B、`app.elf` 223 280 B）；只有 `wifi`（irom +176 848 B）与 `full`（irom +142 832 B）变大。
- **共存 glue 接进两套适配层（路线图 C2，2026-11-24）**：构建开关 `-Dcoex`，配 `-Dcoex-objs` 给 `libcoexist.a`
  的成员；默认关。
  **【2026-11-26】**不开 `-Dcoex` 的 Wi-Fi 探针镜像里，`_coex_pti_get` 的计数桩把出参写成 0，会让 blob 收不到帧；已改成不写
  （与 IDF 关闭分支一致，`osi_impl.zig`）。"默认关"不变：胶水按关闭分支作答、核不启动时真实链路照常
  （`docs/verification/coex-verification.md` §13）。
  - BLE 侧：`components/osal/src/osal.zig` 的 11 个 `wr_btdm_coex_*` 开关打开时转发给胶水，另补 5 个缺失的强定义；
    适配表的 18 个 OS 钩子在 `components/osal/src/coex_hooks.zig`（8 项用例）；`bt-blobs` 的 `btdmCoexInit/Enable`
    转发，`src/coex_wiring.zig` 在 `bringup.init` 之前启动核并打诊断。
  - Wi-Fi 侧：`components/wifi-blobs/src/coex_hooks.zig` 给 18 个钩子（4 项用例）；探针在 arena 就位后启动核，
    `makeTable()` 之后把 24 个共存表项换成胶水的包装函数，原位置上的裸 `coex_init()` 改经胶水。
  - 链接层：`components/radio-coex/link/coex_printf_shim.c` 补上库唯一缺的两个符号（`coexist_printf`、`puts`）；
    `s31.ld` 把 `.coexiram*` 收进 `.iram_blobs`（此前是 12 个孤儿段，落在 LP RAM 里），并给两个被探针桩遮住的
    ROM 函数加别名。`firmware/build.zig` 另加辅助开关 `-Dkeep-symbols`（只用来核对符号，镜像不等同于 strip 的）。
  - 验证：开 `-Dcoex` 时 BLE 闭包、BLE 探针、Wi-Fi 探针三种镜像链接通过且恰好两段；关着时默认、BLE 闭包、
    BLE 探针、Wi-Fi 探针四种镜像与 `3f4e575` 逐字节相同。板级（`logs/coex-{ble,wifi}-probe-{boot,control}.log`）：
    BLE 探针读到 `g_coex_param_ptr=0x2f00ffe4`、`fw=2.0.0 rom=cdcf52b`、适配表被核心收下、两个 BLE 回调都已登记；
    Wi-Fi 探针读到共存库自己打的两行版本、`wifiInit rc=0`、`INIT OK`。两次实验各带不开共存的对照。
    两个 blob 同镜（C3、C4）与空口未做。细目见 `docs/verification/coex-verification.md` §4。

- **生产 A/B 与回滚（矩阵 C5，2026-11-18）**：`firmware/idf-bootstrap/partitions.csv` 追加
  `ota_0`(0x190000) / `ota_1`(0x310000) / `otadata`(0x490000, 8K)，factory 仍在 0x10000。
  新增真实落盘层 `components/boot-power-perf/src/{flash,partition,slot}.zig`：按 IDF
  `esp_ota_select_entry_t`（32 B、`crc` **只覆盖 `ota_seq`**、槽位 `=(seq-1)%app_count`、
  两扇区交替写）写 otadata，并解析 0x8000 的分区表。
  **生产 bootloader 未开 `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`（Kconfig 默认 `n`）**，所以
  NEW/VALID/INVALID 全部由应用写；"待确认"判据是 `state ∈ {NEW, PENDING_VERIFY}`。
  失败计数按槽隔离、落在 nvs 末扇区 0xE000（每次 16 B 追加，写满才擦）。
  板上证据：`logs/c5-ab-factory.log`（`ab=yes count=2`、`crc32 mine=rom=0x4743989a`）、
  `logs/c5-ab-stage-confirm.log`（`state=NEW(0) seq=1` → `confirmed VALID`）、
  `logs/c5-ab-rollback.log`（`failure 1/3`→`3/3` → `marked INVALID` → 复位 → `offset 0x190000`），
  已排除项见 `logs/c5-ab-negative.log`。
  注：生产侧只做**落盘 + 选槽 + 回滚**；镜像由 esptool 直接写入槽位，下载/签名仍在 ch23 lab。
  容量基线随之刷新（`capacity.json` 此前停在 `9bd55e4`，早于 TLS/MQTT 落地 ⇒ `tls` 的
  +64 KB 主要是那批工作的累计增长，本次 C5 贡献各 profile 约 +10–15 KB `irom_len`）。

- **周期实测基线与 CPU 频率实测（矩阵 C7 的一部分，2026-11-18）**：新增
  `components/boot-power-perf/src/workload.zig`（4 KiB ARX 固定工作量、注入时钟、p50/p95/周期每字节）
  与 `hw.cycleCount()`（`mcycle` 的防撕裂读法）。用 `-Dperf-run` 打开，默认构建不含这段代码。
  板上读数：`cycles(p50)=59454`、`cycles_per_byte=14.515`、`cpu_mhz(measured)=80`
  （`mcycle` 与 TIMG0 两个独立计数源对算，与 `BOOTLOADER_CPU_CLK_FREQ_MHZ` 默认值一致）。
  证据：`logs/c7-perf-baseline.log`。
- **C7 三档对比完成（2026-11-18）**：新增 `boards/esp32s31-coreboard/src/clock.zig`，按 IDF
  `rtc_clk_cpu_freq_set_config` 的序列与分频表切换 80/160/320 MHz（cpu/mem/sys/apb 四分频 +
  切 CPLL + bus update + `esp_rom_set_cpu_ticks_per_us`），写后读回校验。
  三档实测：`cycles_p50` 同为 59455（⇒ 纯 CPU 受限）、`cycles_per_byte=14.515`、
  `mib_per_s` 5.256/10.512/21.024（恰好 2×/4×，验证 `perf.scaleNs` 模型）；
  用 `mcycle`/`nowUs` 两源对算独立验证频率真的变了（79/160/320）。证据 `logs/c7-perf-tiers.log`。
  附带观测：320 档 `mhz_measured=320` ⇒ APB 未随分频改变，硬件自动纠正（`rtc_clk.c` 注释警告的行为）。
  构建开关 `-Dperf-tiers`，默认构建不含改频代码。

- **C8 综合 demo（2026-11-18）**：新增 `scripts/demo-board.sh [PORT]`，一条命令完成
  构建 → 烧录 → 抓串口 → 断言，并演示 A/B：① 默认固件从 factory 起来（`verdict=pass`）；
  ② 正常镜像写进 ota_0 后切槽（`offset 0x190000` + `confirmed VALID`）；
  ③ `-Dab-revert` 的镜像判废当前槽（`marked INVALID -> reverting`）⇒ 回到 factory（旧版本）；
  ④ 恢复默认固件并清 otadata/计数扇区。
  它不碰网络（不需要 DHCP/监听器/防火墙），发布门禁仍是 `scripts/gate-board.sh`。
  踩到的顺序坑：第 3 步之前必须先把 factory 换回**不带** `-Dab-stage` 的基线镜像，
  否则判废后 bootloader 回到 factory、而那里仍是 stage 构建，会立刻又被切走。
  新增构建开关 `-Dab-revert`。证据：`logs/c8-demo.log`（四段串口原文 + 尾部标注）。

- **POSIX 兼容层第一版（2026-11-18）**：新增 `components/posix-compat/`，把 POSIX 接口映射到
  现有实现。README 是**梳理**产物：逐接口列出「我们的对应物 / 状态（已有·语义要补·缺·不做）/
  决定」，并纠正了一个错误结论 —— 生产侧早有 `bt-blobs` 的 OSAL（`semPend`/`mutexPend` 都**已
  支持超时**），内核并非只活在章节目录里。
  > **更正（2026-11-18，后来的实测）**：这条"已支持超时"本身是**错的** —— `semPend` 只有
  > `timeout == forever` 才真阻塞，有限超时**立即返回**；`mutexPend` 更是从不阻塞（只做 2M 次
  > 有界忙等）。本层的定时等待因此另建了 `timer.zig` + `sync.pump()`，而不是复用它们。
  本版实现不需要内核的那一半：`errno`（Linux 数值 + 与 `net-sockets` 枚举的双射）、
  `time`（`clock_gettime`/`nanosleep`/`usleep`/`sleep`，时钟与睡眠注入；`CLOCK_REALTIME`
  明确 `EINVAL`，因为没有墙钟）、`addr`（`sockaddr_in` 16 字节布局与网络序端口）、
  `fd`（`socket/bind/listen/accept/connect/send/recv/read/write/shutdown/close/poll`）。
  共 **17 项**主机用例，含一条 `socket→bind→listen→SYN→ACK→accept` 的完整链路。
  **只登记主机测试目标、不进镜像**：本版无板级行为变更，且其 `net_sockets` 模块与
  `net_sockets` 组件模块包含同一批文件（同时进镜像会撞 Zig 的"一个文件属于两个模块"）。
  `tests/baselines.json` 已加 `posix-compat: 17`。

- **OSAL 抽成独立组件（2026-11-18）**：`components/bt-blobs/src/{sched,osal,probe_ptr}.zig`
  → `components/osal/`（1946 行，零 `board` 依赖，时间/临界区/随机数都是注入钩子）。
  动机是给 POSIX 兼容层一个可复用的内核落点，而不是再造一份。
  搬移本身**行为未变**的证据：闭包链接的镜像大小搬前搬后**逐字节相同**（913728 B）。
  bt-blobs 的 10 个文件、18 处相对 import 改为模块导入；其主机用例 36 → 17（19 项随文件迁走，
  归 `osal` 自己的测试目标，避免同一批用例被两个组件各数一遍）。
  ⚠️ `osal/src/api.zig` 里那行 `comptime { _ = &osal.timeGet; }` **不能删** —— 没有它
  `osal.zig` 的 5 个 `export fn` 不会发射，`bt_core.o` 变 0 符号对象、闭包链接报未定义
  （`scripts/check-bt-link.sh` 会抓到）。新增组件基线：`osal: 20`，`bt-blobs: 17`。

- **`osal` 不再知道自己服务谁（2026-11-18）**：`mutexPend` 里原本内嵌着 BLE bring-up 的门控
  测量（`probe_ptr` 的 env/P + `0x2f00ffd0` 的 10 个 per-object 锚点表，约 37 行）。
  那段代码读的地址和日志前缀都是 bt-blobs 专有的，而且 **`logLine` 只按 `"bt hook: "` 前缀
  过滤日志**，`"bt gate: "`/`"bt env: "`/`"bt anchor["` 不在门内 ⇒ probe 路径下**每次取到
  互斥锁都要往 UART 打 ~15 行**。现在门控搬进 `components/bt-blobs/src/gate.zig`，由
  `Hooks.on_mutex_acquired` 注册；`probe_ptr.zig` 也随 ADR 退回 bt-blobs。
  触发条件与迁移前一致（只有 `probe.zig` 调 `setHooks`，新字段在同一次调用里注册，
  不会被整表替换冲掉），日志格式逐字未变，闭包镜像仍 **913728 B**。
  **未在板上复验本轮日志输出**；静态侧只确认了 `gate.zig` 会被分析（`app_zcu.o` 里有它的
  字面量）且两种构建都 RC=0。另一个实测事实：生产镜像里 `probe.run` 无人引用，
  gc-sections 会把 probe/gate 一起丢掉（`bt bringup` 也不在 ELF 里）—— 而生产路径本来
  也没设过 `.log`，所以"生产不打这些日志"在迁移前后都成立。
- **POSIX 同步层（2026-11-18）**：`components/posix-compat/src/sync.zig` —— `sem_t` 与
  `pthread_mutex_t` 建在 `osal.Sem` 上（**不是** `osal.Mutex`：后者只做有界忙等、不唤醒
  等待者、无 owner/waiter），`pthread_once` 用 CAS。13 项新用例，posix-compat 17 → **30**。
  `sem_timedwait`/`pthread_mutex_timedlock` 返回 `ENOSYS` —— 内核只有无限阻塞，假装超时
  比不做更危险。无定时等待的 `semWait`/`pthread_mutex_lock` 在 `osal.TIMEOUT`（= 没能阻塞住，
  不是到期）时返回 `EAGAIN` 而非 `ETIMEDOUT`，后者是 POSIX 只允许定时变体用的。

- **POSIX 线程层（2026-11-18）**：`components/posix-compat/src/thread.zig` ——
  `pthread_create/join/detach/self/exit` 建在 `sched.taskCreate` + 静态栈池上。
  硬边界写进文件头：`sched` 没有 `taskDelete`/`taskExit`，任务槽**永不回收** ⇒
  每 boot 最多 **8** 次成功创建，第 9 次返回 `EAGAIN`（线程退出也不还槽）。
  退出协议：线程体返回后不能 return，trampoline 记返回值 → `done` → `sem_post` →
  `block()` 永不返回；安全性来自"退出的任务永不再被 resume"。11 项用例（41 总计）。

- **等待队列（2026-11-18）**：`components/posix-compat/src/waitq.zig` —— FIFO 等待者链表，
  6 项主机用例（顺序、摘链清理、中段/队首/队尾自摘、重复摘、`drain` 广播）。
  **刻意不放进 `osal`**：那会改 `bt_core.o`，而归档的阻塞路径没有任何现有门禁能验证
  （主机上 `swapContext` 直接 panic，链接门禁只看链接，板级门禁走 net-wire TCP）。
  因此 `pthread_cond_*` 目前只有队列、没有胶水层 —— 胶水需要一次板级运行才能验收。

- **POSIX 条件变量（2026-11-18）**：`components/posix-compat/src/cond.zig` ——
  `init/destroy/wait/signal/broadcast`，队列用 `waitq`。只有 `resumeTask` 做成注入点
  （`swapContext` 在 x86_64 上 panic），因此「唤醒谁、FIFO 顺序、唤醒前是否已摘链、
  广播是否先摘完再逐个唤醒」全部有主机断言；`wait` 在调度器未启动时返回 `ENOSYS`
  而不是挂住。6 项新用例，posix-compat 47 → **53**。

- **`sync` 改用自持等待队列（2026-11-18）**：`sem_t` / `pthread_mutex_t` 不再借用 `osal.Sem`
  的句柄，改为「计数 + `waitq` FIFO + `sched.block()/resumeTask()`」。一次解掉三个约束：
  多等待者（此前第 2 个阻塞者拿 `EAGAIN`）、不再与 BLE 归档共用 `sem_pool`（64 槽）、
  `sem_t` 变成普通结构体（`in_use` 区分"未初始化"与"计数为 0"）。
  `unlock` 现在把锁**直接交给队首等待者**，不再"置 1 后被第三方抢走"。
  `wake` 注入点统一到 `sync.bindHooks`，`cond.zig` 复用。16 项 sync 用例（总计 **56**）。

- **定时等待（2026-11-18）**：`components/posix-compat/src/timer.zig` —— 侵入式到期链表 +
  `pump(now_ns)`。阻塞中的任务读不到时钟，所以到期必须由外部唤醒；本层提供
  `sync.pump()`，**应用每个 tick 调一次**。到期时 `pump` **从链表摘除**定时器（否则下一次 pump 会读等待者已返回的栈帧），而是真正挂定时器等待；未绑时钟钩子时仍 `ENOSYS`（无法判定到期），
  调度器未启动时 `EAGAIN`（不能假装等过）。7 项 timer 用例 + 2 项新 sync 用例（总计 **66**）。

- **POSIX 读写锁（2026-11-18）**：`components/posix-compat/src/rwlock.zig` —— 两个 `waitq`
  （等读/等写）+ `sync.wake`。策略是**写者优先**：只要有写者排队，新读者就进不来，否则持续
  的读者流会让写者饿死（读写锁最经典的失效模式）。`unlock` 由内部状态判断释放的是读还是写，
  释放写锁时优先交接给写者、没写者才 `drain` 唤醒全部读者；释放最后一个读锁时把写者交接过去。**交接窗口用 `writer_pending` 标记**：写者被 `pop` 出去唤醒时
  `writers_q` 已空而 `l.writer` 还没置位，不标记的话新读者会在这一瞬插队、把写者挤回队尾
  （正是写者优先要防的饥饿）。
  10 项用例（总计 **77**）。**无超时变体**（要接 `timer.zig` 的到期链表，等真实调用方再加）。

- **每 Task 一份 errno（2026-11-18）**：`errno.Table` 按 `sched` 的上下文指针分槽（8 槽，
  主上下文算一个）。此前是模块级全局 —— 协作式调度下会在 `set()` 与 `get()` 之间被切走，
  另一个任务写进去的值顶掉前一个，表现为"错误码偶尔不对"。表满退回 0 号槽并累加 `overflows`
  （可见而不静默）。3 项新用例（总计 **80**）。

- **`pthread_cond_timedwait`（2026-11-18）**：接上 `timer.zig` 的到期链表，`sync.pump()` 到点唤醒。
  检查顺序刻意如此：解析 `timespec`（`EINVAL`）→ 取时钟（`ENOSYS`）→ 判到期（`ETIMEDOUT`）→
  最后才看调度器（`ENOSYS`），这样"已经过期"在没有调度器的机器上也能给出正确答复。
  入队与挂定时器都在解锁**之前**（解锁可能立刻切走，届时 signal 必须能摘到我们）。3 项新用例
  （总计 **83**）。

- **`pthread_attr_t` 与"栈归调用方"（2026-11-18）**：`thread.zig` 支持
  `pthread_attr_init/destroy/setstack/setstacksize`（最小 1 KiB，只记切片不复制）。
  默认属性才退回小静态池 —— `.bss` 从 8 × 8 KiB = **64 KiB 降到 2 × 8 KiB = 16 KiB**，
  接进镜像时不会先撞容量门禁。3 项新用例（总计 **85**）。

- **`fcntl`（2026-11-18）**：`fd.fcntl` 实现 `F_GETFL`/`F_SETFL`，只认 `O_NONBLOCK`
  （`net_sockets` 的 socket 只有 `nonblocking: bool` 这一个开关，没有 `O_APPEND`/`O_ASYNC` 的概念）；
  其它位与命令返回 `EINVAL`，坏 fd 返回 `EBADF`。**清除 `O_NONBLOCK` 也被拒绝** —— `Socket.nonblocking`
  只是展示字段（socket 层从不读它），允许清除会让调用方以为 fd 阻塞而 `recv` 仍 `EAGAIN`。补它的原因是本轮对账发现 README 把
  `fcntl(O_NONBLOCK)` 标成 ●（"已有"）而**代码里根本没有这个函数** —— 非阻塞应用的必备 API。同时修正 `poll` 行：
  `timeout_ms < 0` 是立即返回，不是 POSIX 的永久等待。1 项新用例（总计 **86**）。

- **POSIX 层进镜像并上板验证（2026-11-18）**：`firmware/build.zig` 把它登记为 section `posix`
  （group `net`），模块根 `api.zig` 不导入 `board`，板级自检在 `selftest.zig`（独立模块）。
  为消除"同一批文件属于两个模块"，`net-sockets` 与 `net-tcp` 的 `selftest.zig` 改为**经模块导入**。
  上板结果：`section: posix` → **15/15**（真任务、`sem_wait` 阻塞、`sem_post` 唤醒、`join`、
  `pthread_self`、每 Task `errno`），`logs/e2e-net-boot.log`；`e2e --board --profile net` PASS。
  容量：`net` +3.1 KB；`full` bin +62 KB 里 **51 KB 是第二段窗口的 64 KiB 步进 padding**，
  真实段增长 ~10.8 KB —— `capacity.json` 已 `--update`，原因写在此处。

- **socket 层就绪通知 + 阻塞 accept（2026-11-18）**：`net_sockets.socket.Table` 新增
  `on_ready` 钩子（默认 `null`，行为与旧版一致），在 `deliver`（收到 SYN 或数据段）与
  `close` 时回调；回调约束是"同步、轻量、只 `sem_post`"。POSIX 侧新增
  `fd.enableBlockingAccept(sem)` / `fd.acceptBlock(fd)`：没连接时睡在就绪信号量上，醒来重试。
  **前置**：RX 泵必须跑在与调用者**不同的任务**里 —— 本仓的 RX 是同一任务在
  `emac.rxPollCopy` 里喂表，原地阻塞即自死锁。3 项新用例（总计 **89**）。
  板级演示（`section: posix`，`net` profile，**26/26**）：主上下文当 RX 泵、任务当 accepter ——
  阻塞 → 喂 SYN 唤醒后**再次阻塞**（子连接仍 `syn_rcvd`，`accept` 拿不到）→ 喂 ACK 后返回 fd。
  这次板级跑出来的第一个失败正是"只喂 SYN"：`accept` 拿不到子连接，值得单独断言。
  **三处修正**（都来自"字段存在≠语义存在"那一类）：`Table.reset()` 原会 `self.* = .{}`
  把钩子一起抹掉 ⇒ 改为保留；`abort()` 原不通知 ⇒ 连接池淘汰时等待者会一直挂着；
  `fd.init(&另一张表)` 原会留下指向旧表的 `g_ready_sem` ⇒ 改为清掉绑定（换表须重绑），
  否则 `acceptBlock` 会睡在一个再没人 post 的信号量上。
  **唤醒上下文**：`sched.resumeTask` 内部是 `swapContext(&main_ctx, t)`（存的是**调用者**帧），
  所以就绪钩子只能从**主上下文**触发 —— 从任务里唤醒会把主上下文换成那个任务的帧。
  `onReady` 因此加了 `sched.inMain()` 守卫，非主上下文的通知丢弃并计数
  （`fd.droppedNotifies()`），而不是破坏调度器。

- **阻塞 `connect`（2026-11-18）**：`fd.connectBlock` —— 与 `acceptBlock` 共用就绪钩子。
  关键点：钩子只报"有事情变了"，等待者**重查自己的 fd 状态**，所以与本次连接无关的唤醒
  （别的 fd 收到数据）会被重查吸收；`accepted` 侧则要多一次 SYN-ACK 之前的重试。板级演示：
  `connector` 任务阻塞 → 主上下文投 SYN-ACK → 唤醒 → 返回 0。`section: posix` 现为 **32/32**。
  另外修了：未启用阻塞模式时两个阻塞调用**没有设 errno**（返回 -1 但 `errno` 还是旧值），
  统一改为 `EAGAIN`。1 项新用例（总计 **90**）。

- **阻塞 `recv`（2026-11-18）**：`fd.recvBlock` —— 与 `acceptBlock`/`connectBlock` 同一形状、
  同一个钩子：没数据就睡，醒来重试。`send` **不做阻塞**：发送缓冲腾出空间发生在**对端 ACK** 的
  线路侧，那条路径不经过 `on_ready`，要做就得先有"tx 有空间"的通知。板级演示：`reader` 任务
  阻塞 → 主上下文投一帧 data → 唤醒 → 返回字节数。`section: posix` 现为 **36/36**。
  1 项新用例（总计 **91**）。
  容量：`net` +8.75 KB（阻塞 IO 的三个 API + 三段板级演示）、`full` +1.5 KB —— 两者都在窗口内，
  没有 64 KiB 步进；`capacity.json` 已 `--update`。

- **W4 降级分支复测（2026-11-18）**：`socket.zig` 加了 `on_ready` 钩子之后要确认生产路径没变，
  但本机 `sudo` 需要交互密码 ⇒ `scripts/host-prep-wire.sh up`（加 iptables 放行）跑不了 ⇒
  **带 DHCP 的发布门禁本轮没跑**。取而代之刷了 `net-wire` profile：EMAC bring-up 仍 ok、
  3 次 DHCP DISCOVER 无应答 ⇒ 走 W4 的 fail-closed 分支（`skipped/no-dhcp-server`、
  `checks passed=1 failed=0`、`main: verdict=pass`），证据存 `logs/net-wire-no-dhcp.log`。
  ⚠️ 这次**没有**用降级日志去更新 W1–W3：那会把"没跑通"洗成发布证据；`e2e-net-wire-boot.log`
  保持原样，`update_matrix.py --check` 通过。

- **`bt-probe` 镜像原来编不出来（2026-11-18 修复）**：带闭包的 probe 构建报三组
  `duplicate symbol`（`bt_swap_context` / `s31_now_us` / `bt_mmio_read` …）—— 根因是
  `bt_core` 既作为**独立对象**（`addObject`）又把 `board`/`osal_kit` 编了进去，而 app 自己
  也编同一批模块 ⇒ 同一模块编两遍、`export fn` 重复。改为 **`bt_core` 作 app 的模块**
  （只编一次；blob 构建已关 `gc-sections`，`export` 不会被裁）。
  另外 `esp_phy_enable` 是 ROM 函数（`0x2f00e756`）却**没在 `rom_syms.ld` 声明** ⇒ 补上。
  ⚠️ 之前"`-Dbt-probe` 构建 RC=0"的结论只覆盖了**不带闭包**的形态（那时 probe 实际是关的）。
  修复后 probe 镜像：bin **790 288 B** / factory 1.5 MB，两段窗口 ✓。
- **首次拿到 BLE 锚点全表（2026-11-18，板级）**：`logs/bt-probe-anchors.log`。init 走到
  step 6，10 个 `r_sym_bt_*` 锚点里 **只有 3 个已发布**（`[4]`/`[6]`/`[8]`），
  **7 个仍是 0**（`[0][1][2][3][5][7][9]`）；随后在 `ra=0x4005fa94`（`r_btdm_task_init`
  +0x4a）处以 `a0=0x0` 触发 **store access fault** —— 与"拿未发布锚点当基址写"一致，
  即此前静默零填充的同一个缺陷，现在变成了可定位的 fault。

- **posix 与 BLE 闭包装不进同一窗口（2026-11-18，门禁实测）**：加 posix section 后
  `scripts/check-bt-link.sh` 报 `.flash.text` 溢出 **2032 B**（闭包占 699 856 / 窗口 720 896，
  posix +8.75 KB）。两者不必共存 ⇒ `-Dbt-blob-dir` / `-Dbt-probe` 时跳过 posix section，
  并在注释与 ADR 写明"要三者共存须先扩窗口"。
  同批修正：非 probe 的闭包构建不再把 `bt_core` 编进 app（那会 +2 KB），改由 probe-off shim
  做一次 `osal.forceExports()` 的 comptime 根引用 —— 只发射归档要的 5 个 `s31_*`；
  闭包镜像因此从 913 728 → **913 744 B**（+16 B），门禁通过。

- **PHY 使能的两条路径行为不同（2026-11-18，板级实测）**：
  | 配置 | 结果 |
  | --- | --- |
  | 不给 `-Dphy-src-objs`（`PROVIDE(esp_phy_enable)` → ROM `0x2f00e756`） | bringup 跑到 **step 6**、打印全部锚点、崩在 deinit 路径 —— **可诊断** |
  | 给 `-Dphy-src-objs`（IDF 编好的 7 个 PHY 对象） | 镜像起来就在 PHY 里打 PMU 寄存器转储（`pmu+0x164…`、`phy: (log)`），**没进 bringup** |
  因此不强制任何一条：`PROVIDE` 作为**回退**保留（有真实定义时自动让位），
  两条路径的差异写进 `build.zig` 注释。IDF 对象那条为何在 bringup 之前就停，待查
  （`logs/bt-probe-phy-src.log`）。

### Planned
- P1：以太网 ARP/ICMP 上层（DMA 已闭环）

### Added
- **死等循环已反汇编出来**（2026-11-17，不需要 JTAG）：探针把 ROM 区 `0x2f83efb0` 与 `0x2f812200`
  各 96 字节读出来（`0x2f8xxxxx` 可直接读），离线 `objdump -D -b binary -m riscv:rv32` 反汇编。
  轮询循环在 `0x2f812216`：

  ```asm
  2f81221a: addi s1,zero,127
  2f81221e: mv   a0,s0            # ← 循环头
  2f812222: jal  0x2f83efca       # 读一个字节
  2f812228: bltu s1,a0,0x2f81221e # while (127 < byte) 继续转
  ```

  读字节的叶子函数（`0x2f83efca`）= `((*(u32*)(((arg + 0x2038A) << 12) + 28) >> 16) & 0xFF)`。
  采样到的 `a0=0xE080` ⇒ 轮询地址 **`0x2E40A01C`**；`0x2f83efda` 被采到 13 次不是在那儿转，
  而是它是叶子函数、被这个循环高频调用。⇒ 下一步只需弄清 `0x2E40A01C` 是哪个外设的状态字节，
  MAC 在等什么就明确了。**本条完全不需要外部设备**，也不需要 JTAG。
  另确证：`SOC_PLL_SOURCE_CG`（`0x205871E0` = 0x3d）、PHY 的 8 个 FE 时钟、LP timer 时钟
  （LPCON +0x4/+0x14/+0x18）全部已开并读回自证，仍卡在同一处 —— 排除了"只是少开时钟"。
- **板上结论：BLE 与 Wi-Fi 撞同一面墙**（2026-11-17）：BLE controller 跑到 init step 6
  （`r_btdm_task_init` 内部）停住，用 TIMG0 T0 采样被中断的 PC —— 28 个样本全部 `mac=0x0000e000`，
  PC 集中在 ROM 区的 `0x2f83efda`/`0x2f812220` ⇒ **`MAC_ST & 0xE000 != 0`**，与 ch25 记录的
  Wi-Fi blob 卡点是**同一组只读忙位**。⇒ 两个 controller 都停在"MAC/PHY 内部状态从未离开 busy"，
  是同一个底层状态而非各自的问题；R3.2 与 R3.3 的后续都卡在"让 MAC 从 busy 里出来"这一件事上
  （ch25 已为此排除 17 条路径，下一步仍是 JTAG 写监视点或 ROM 侧情报）。
  顺带确证（板侧实测）：12 个时钟门全部置上；控制器要的池容量 `evt=187 evtq=33 co=41 sem=20 mutex=16`；
  init 链可达 step 5。
  ⚠ 探针漏调 `hw.initTimer()` 的代价：`nowUs()` 恒 0 ⇒ T0 采样中断永不到点、OSAL 时基恒 0
  （ADR-001:729 因同一原因记过一次，这次又踩，已写进 README）。
- **板上探针 + 构建配方可复现**（2026-11-17）：`components/bt-blobs/src/probe.zig`（`-Dbt-probe`）
  按"装钩子 → arena → init → enable → 进任务 → 发 Reset → 泵任务"的顺序跑，并在主循环打
  `bt task round N` —— 日志能直接区分三种失败：**任务从没跑过**（没有 round）/ **跑了但没回包**
  （有 round、没 EVT）/ **回包但 status≠0**。钩子必须在 init 前装：`now_ms = nowUs()/1000`
  （**毫秒**，差 1000 倍会让所有超时窗口变成天文数字）、`log` 同步刷 UART。
  新增 `tools/gen-bt-closure.sh`：解包 4 归档 → 符号图 BFS → 减 ROM → 打印对象清单与构建命令，
  把原先只存在于 `/tmp` 的配方固化。**根集合 = 我们的 Zig 直接调用的每个归档符号**——实测踩到
  `r_base_stack_initEnv` 因不在根里而链接失败，补全后闭包 113 → **116 对象**。
  另：所有 bt-blobs 文件合成**单一模块**（`root.zig`），分两个会报"文件属于多个模块"。
- **协作式调度器 + OSAL 真阻塞**（2026-11-17，`components/bt-blobs/src/sched.zig`）：从
  `wifi-blobs/src/sched.zig` 复制（**不 import**，否则会把 wifi blob 的依赖拖进来），
  在其上加了任务表与 `block()`/`resumeTask()`。BLE 的任务体是 `sem_pend(FOREVER)` /
  `eventq_get(FOREVER)` 的**死循环**：只登记不建上下文 ⇒ 任务永不执行，init 会"成功"
  然后什么都不发生；建立了却不切回主上下文 ⇒ 主循环饿死、连串口日志都出不来。
  `swapContext(from,to)` 存 `from.sp` 恢复 `to.sp` ⇒ 阻塞=切回 main、恢复=切回任务，
  任务的 `sp` 已存下，**从原地继续**。OSAL 侧 `sem_pend`/`eventq_get` 在 FOREVER 且无资源时
  记 `waiter` 再阻塞、唤醒后**重新检查**；`sem_release`/`eventq_put` 有等待者就 `resumeTask`。
  调度器未启动时（主机测试）退化成 `TIMEOUT` 并计入 `blocked_calls`，不会自旋。
  `task_create` 现在真的从 arena 分栈并建上下文，失败时打日志而不是静默。
- **transport.init 接进 init 链（第 15 步）+ B 路径发命令**（2026-11-17）：
  `hci_transport_init` 在 IDF 里是 `esp_bt_controller_init` 的**最后一步、enable 之前**——
  不做它，命令照样发得出去（我们直接调 forward），但 controller **没有回程回调**
  （`r_ble_hci_trans_cfg_hs` / `r_btdm_hci_trans_register_tx` 都没跑）⇒ 症状是
  "init 全绿、命令发了、就是没回包"，极易误判成时钟/中断/任务没做。
  另加 **B 路径**（`r_ble_hci_trans_buf_alloc(3)` + `r_ble_hci_trans_hs_cmd_tx`）——
  比 A 路径少一半代码，先试它；⚠ 两个分配器的 type 值不同（B=3、A=1），别混用。
  **判据**：HCI Reset 的成功回程是 `04 04 0E 03 0C 00`，最后那个 `00` 才是 status 成功。
  enable 的步骤号顺延到 16–20，避免与 init 的 `failed_step` 混淆。
- **公有地址设置**（2026-11-17，init 第 14 步）：`r_esp_ble_ll_set_public_addr(mac)`（归档 ✓），
  `mac` 先 `readEfuseMac` 再**字节逆序**（IDF 同样是 `swap_in_place(mac, 6)` 之后再设）。
  没有这一步 **HCI Reset 能过、但扫描/广播命令全部无效** —— "命令有回包但没效果"的典型成因。
  enable 链的步骤号相应顺延到 15–19（最后仍是 `r_btdm_task_enable`）。
- **HCI 传输层落地**（2026-11-17，`components/bt-blobs/src/transport.zig`）：我们**自己拥有**这一层
  （归档里没有 `hci_driver_vhci_ops`/`uart_ops`），结构照 IDF 的 `hci_transport_init`：
  `ops.init(cb)` → `r_ble_hci_trans_cfg_hs(leEvtTx, NULL, leAclTx, NULL)` → `r_btdm_hci_trans_register_tx(btdmTx, false)`。
  三个必踩点：① **别手搓 12 字节包**——用归档的 `r_btdm_hci_trans_buf_alloc` 拿；② **必须置 BLE 位**
  （`r_btdm_hci_pkt_flag_ble_setf`），否则包被当 BR/EDR 路由、症状是"命令没人接"；③ 我们是 host
  ⇒ 回程读完要**自己释放**（`r_ble_hci_trans_buf_free` 收的是载荷不是包）。
  `sendReset()`/`sendReadLocalVersion()` 已就绪；事件回调按 `cmd[1]+2` 切长度并把每个字节打进日志
  ——这就是里程碑的唯一判据。前提是 `status()==enabled`（rx 路径自己会查）。
- **`ext_funcs_t` 注册**（2026-11-17，`components/bt-blobs/src/extfuncs.zig`）：这是 controller 拿
  **malloc/free/rand/assert** 的那张表（`ble.c:97-109`，rv32 上 **40 字节**）。上一版把它当成
  "可以跳过"是错的——跳过等于 controller 没有分配器，`r_ble_controller_init` 必然失败，
  且失败点会被误判成"时钟/中断没做"。`ext_version=0x20250819`、`magic=0xA5A5A5A5`；
  `_malloc/_free` 接我们的 arena、`_os_random` 接 `osal.randomU32()`（板级可注入真 TRNG）；
  `_osi_assert` 的参数顺序是**行号在前、函数名在后**（与 `__assert_func` 相反）。
  三个 ECC 项给**返回 -1 的桩**——IDF 在 `CONFIG_BT_LE_SM_LEGACY/SC` 未开时本来就 return -1，
  `_ecc_aes_cmac` 转发的是 NimBLE host 的函数（controller-only 没有 host）⇒ 不需要 ROM ECC。
- **init / enable 编排落地**（2026-11-17，`components/bt-blobs/src/bringup.zig`）：init 13 步、
  enable 6 步，状态机 `idle → inited → enabled` + `getStatus()`（HCI 传输层的门禁就查它）。
  两步最容易错：① **`r_btdm_task_enable` 在 enable 的最后一步**，不在 init 里——只做 init
  的话 controller 任务永不启动，HCI 不会有回包；② `r_btdm_hci_fc_env_init` **必调**
  （`UC_BT_CTRL_CONN_FC_ENABLE` 在 `btdm_user_cfg.h:108` 硬编码为 1）。
  跳过 `esp_register_ext_funcs(&ext_funcs_ro)`：归档里有前者，但 **`ext_funcs_ro` 是 NimBLE
  host 的符号、归档里没有** ⇒ 跳过并计数；若事件送不出来第一个回来查这里。
  归档调用写成 `if (freestanding) f(...) else 0`（comptime 条件 ⇒ 主机分支不求值），
  所以 13 个归档符号在主机测试里不进 debug info，29 个用例仍能在 x86_64 上跑。
- **`btdm_lp_enable_clock` 按"空实现 + 大声日志"落地**（2026-11-17）：它是 9 个 porting 函数里唯一的
  真硬件活，但 **HCI Reset / Read Local Version 是软件层命令**，未必需要射频时钟 ⇒ 先空着，
  等 controller 一碰 MAC 寄存器就 fault 再补。补实现所需的规格已查全并写进
  `components/bt-blobs/README.md`：`BLE_CLOCK_DEPS` 的 **8 个门**（BLE_MAC / BT_I154_COMMON_BB /
  ETM / **COEXIST 在 lpcon 块** / WIFI_BB_80X1 / SOC_PLL_SOURCE_CG / BT_APB / BT_PERIPHERAL）
  与 `BT_APB_CLOCK_DEPS` 的 4 个门，外加 `modem_clock_module_mac_reset`。
  纪律：**宁可多开不要少开**（少一个门 = 访问该外设总线挂死，比缺时钟更糟）。
- **porting 层的 9 个 C 函数里 7 个已落 Zig**（2026-11-17）：照 IDF 原文逐条读过之后，估工大幅下调——
  4 个是 `return 0`（`btdm_log_init`/`btdm_external_init`/`btdm_coex_init`/`btdm_lp_init`），
  `ble_controller_scan_duplicate_config` 是 NimBLE **host** 侧的扫描去重（全归档 `grep ble_vhci` 零命中
  ⇒ controller-only 构建没有 host，空实现是对的），`ble_msys_init` 只是转调归档里的
  `r_esp_ble_msys_init`（常量取 `host/nimble/Kconfig.in` 的 SOC_ESP_NIMBLE_CONTROLLER 分支：24/128、24/320）。
  `btdm_osal_elem_mempool_init` 做成**容量校验**：IDF 池空会回退动态 malloc，我们的静态池**没有回退**
  ⇒ 超限按类返回 -1..-5 并把 5 个数字打出来，免得"池不够"表现成"controller 不动"。
  **只剩 `btdm_lp_enable_clock` 是硬活**（CNNT/modem 域时钟门控 + BT MAC 复位，`modem_clock_*` 是 IDF C 不是 ROM）。
- **`ble_osal_elem_calc` 的 Zig 版**（2026-11-17，R3.3 里程碑 2 前置）：`config.elemCalc()` /
  `mempoolElemNum()` 复刻 `ble.c:1586-1607`，作为 `btdm_osal_elem_mempool_init` 的输入。
  两个必须照抄的点：① **seed 不是零**——`bt.c:172-178` 预置 `{evt=103, evtq=3, co=10, sem=0, mutex=1}`，
  从零算会少 103 个事件；② **五个累加宏是交叉用的**（`evt` 用 `BLE_HOST_CO_COUNT`、
  `evtq` 用 `BLE_HOST_EV_COUNT`、`co` 用 `BLE_HOST_EVQ_COUNT`），像笔误但归档依赖它。
  归档符号 `r_ble_ll_get_npl_element_info` 只在目标构建引用（主机走注入 hook），
  所以 4 个用例能在 x86_64 上钉住算术；按默认 config 算出的上限（事件 ~181）正好验证池 ≥192 够用。
- **`esp_bt_controller_config_t` 的逐字段镜像 + 布局实测**（2026-11-17，R3.3 里程碑 2 前置）：
  `components/bt-blobs/src/config.zig` 镜像 60 个字段，13 条 comptime 断言钉死全部偏移
  （总长 **192**、`ble`@0/**112 B**、`bredr`@112/**56 B**、`btdm`@168/**20 B**；
  `ble` 内 `config_version`@0、`rtc_freq`@24、`main_xtal_freq`@84、`config_magic`@108）。
  数字**不是手算**：`tools/btcfg-probe.sh` 用 rv32 gcc 把 `sizeof`/`offsetof` 发射成常量表再读回
  （交叉产物跑不了，而 `esp_bt.h` 会拉 FreeRTOS 的 `portmacro.h` 编不过 ⇒ 探针只抄了结构体本体）。
  三处照抄要点：`bredr` 有 8 个 C 位域 ⇒ Zig 无位域，用 `[56]u8` 占位（`btdm` 的偏移由它决定）；
  `ble.rtc_freq` 是 u64 ⇒ 引入 8 字节对齐填充；4 个 C `bool` 用 `u8`（Zig `bool` 遇非 0/1 字节是 UB）。
- **56 个弱断言桩全部有强定义**（2026-11-17，R3.3 里程碑 2c1 收口）：在 36 个 OSAL 之上补齐
  **11 个 `wr_btdm_coex_*`**（Wi-Fi/BLE 共存钩子）。这批**不能做空桩**——controller 会问
  "Wi-Fi 现在哪个信道"、"这个状态位可用吗"，空桩返回 0 会被当成"可用"或"信道 0"。做法是维持
  真实的状态位图 + 存下回调，并按 IDF 在"未开软件共存"分支下的返回值作答
  （`wifi_channel_get` → **-1**、`iso_protect_frame_thres_get` → **0**，见 `btdm_coex.c:106-114/153-162`）。
  逐条对归档调用集核过：56/56 覆盖，差集为空（我们共提供 68 个 `wr_btdm_*` 强定义）。
  热路径（`ble_idle_time_inform`/`iso_*`）只计数不打印，避免把串口打爆。
- **BT controller 的 OSAL 落成**（2026-11-17，R3.3 里程碑 2c0）：`components/bt-blobs/src/osal.zig`
  实现 time/critical/sem/mutex/event/eventq/callout + 自有 arena，并导出 **48 个** `wr_btdm_osal_*`
  强定义（覆盖归档里的弱断言桩）。归档**实际会调**的 **36 个逐个点名核对**（差集为空），
  因为**漏一个链接期不报错**（同名弱桩兜着）、运行期才以 `wr_btdm_assert` 挂住。
  三处形状/环境的硬约束（都踩过）：
  ① **句柄是 4 字节槽位**（`struct btdm_osal_* { void *x; }` 内嵌在 controller 结构体里）⇒
  `Slot` 是 `extern struct { p: ?*anyopaque }`，状态对象只在静态池里、只把指针写进槽位；
  ② **不能用 `std.heap.page_allocator`**（`riscv32-freestanding` 没有后端，主机上却正常 ⇒ 假绿）；
  ③ 块头必须补到 **16 字节**，否则 `addr+12` 破坏 8 字节对齐（controller 结构里有 u64）。
  14 个主机用例（含槽位金丝雀、arena 对齐、36 个导出点名）。
- **BLE controller 链进两段镜像**（2026-11-17，R3.3 里程碑 1）：`libble_app` + `libbtdm_common` +
  `libbtbb` + `libphy` 的 113 对象闭包全部加进 `zig build`（新开关 `-Dbt-blob-dir` / `-Dbt-blob-objs`），
  `.flash.text` **699 920 / 720 896**（余 20 976）、`.flash.rodata` 110 848、`.iram_blobs` 60 224，
  `elf2image` 成功且 `image-info` 恰好 2 条 `DROM, IROM`。控制器**还不能跑**（config/任务/HCI 传输未做），
  详见 `components/bt-blobs/README.md`。三个落地要点：
  ① `libble_app` 的 `.iram_sleep*`/`.iram_single_sleep*` 不在原 `.iram_blobs` 收集规则里，
  不显式收编就各自成段、`elf2image` 报 `Invalid segment count 27 (max 16)`（与当年 105 对象那次同类）；
  ② 链接期只剩 4 个未定义符号，且**全在 S31 ROM 集里**（`printf`/`ets_printf`/`abs`/
  `phy_set_chan_freq_sw_start`）⇒ 加进 `rom_syms.ld` 而不是写桩——"ROM 集里有"不等于
  "`rom_syms.ld` 里有"，增量链接实验要先对账；
  ③ 5 个 `*_btdm` 边界符号用**零长度区间**即可：`libble_app/112.o` 的用法是
  `memset(start, 0, end-start)`，而本布局 `.bss` 已由 `_start` 清零、`.data` 的 LMA == VMA。
  另：`wr_btdm_osal_*` 51 个虽由归档定义，但类型是 **`W`（弱定义）、函数体是 `wr_btdm_assert` 断言占位**
  ⇒ **必须由我们实现**（IDF 的真实实现是 `btdm_osal_freertos.c`，基于 FreeRTOS）。这是"让 controller
  跑起来"的主要工作量；`nm` 只数"有定义"不够，必须看类型字母。
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
