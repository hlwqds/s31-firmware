//! ble-802154：6LoWPAN 邻居发现的主机侧（RFC 6775 第 5 章），离线可验证的部分。
//!
//! 规范出处（条款号与原文一致；行号指 /tmp/spec/rfc<N>.txt，印刷页码 = `=== PAGE N ===` 的 N−1）：
//!   * 报文与选项格式 —— RFC 4861 §4.1–§4.4（RS 行 980 / RA 行 1037 / NS 行 1187 /
//!     NA 行 1262）、§4.6（选项骨架与“长度 0 丢整包”行 1528–1532）、§4.6.1（SLLAO/TLLAO
//!     行 1553）、§4.6.2（PIO 行 1602）、§4.6.4（MTU 行 1757）；802.15.4 的 SLLAO 形状
//!     —— RFC 4944 §8 图 7（行 754–846：EUI-64 Length=2、短地址 Length=1，填充零）。
//!     RFC 6775 的三个新选项 —— §4.1 ARO（行 823，Type=33 行 883）、§4.2 6CO（行 926，
//!     Type=34 行 959）、§4.3 ABRO（行 1015，Type=35 行 1052）；§12（行 2696–2705）注册号。
//!   * 接收校验 —— RFC 4861 §6.1.2（RA：源必须 link-local 行 2178–2180、Code=0
//!     行 2198、ICMP 长度 ≥16 行 2199、选项长度 >0 行 2201）、§7.1.1（NS：hop limit
//!     255 行 3274、Code=0 行 3282、长度 ≥24 行 3284、Target 非组播 行 3286、未指定源
//!     时目的必须是 solicited-node 组播且无 SLLAO 行 3288–3292）、§7.1.2（NA：同上 +
//!     目的为组播时 Solicited 必须 0 行 3334–3336）；校验和 —— RFC 4443 §2.3 伪头
//!     （RFC 4861 引作 [ICMPv6]，行 1021 等；盘上无 rfc4443.txt），算法 RFC 1071，
//!     与 lwIP 的 ICMPv6 走 ip6_chksum（src/core/ipv6/ip6.c，next header 58）同口径。
//!   * 主机行为（本文件的状态机）—— RFC 6775 §5：§5.1 禁止组播 NS（行 1212）；
//!     §5.3 RS 节奏（行 1254–1262：先至多 3 条间隔 10s，再截断指数退避封顶 60s，收到
//!     RA 终止）；§5.4 RA 处理（行 1266–1277；带 L 旗标的 PIO 必须忽略 行 1278–1280；
//!     SLLAO 必须在场 行 1276——发送方义务，缺席不拒收）；§5.4.1 地址配置（行
//!     1281–1297：M 旗标 → DHCPv6，本文件只记录旗标）；§5.4.2 上下文表（行 1298–1323：
//!     同 CID 更新、Valid Lifetime 0 立即删除 行 1317–1319）；§5.4.3（行 1325–1349：
//!     过期 → receive-only 行 1329–1332，保持 2×默认 Router Lifetime 后删除；RS 触发 =
//!     Router Lifetime / PIO / 6CO 寿命的最短者 行 1337–1343）；§5.5/§5.5.1 注册 NS
//!     （行 1351–1382：重传至多 MAX_UNICAST_SOLICIT 次、至少隔 RETRANS_TIMER 行
//!     1360–1362；必须带 SLLAO 行 1379–1381；未指定源禁止 行 1378）；§5.5.2 NA 处理
//!     （行 1386–1410：ARO Length≠2 整条忽略、EUI-64 不符忽略 行 1392–1395，
//!     Status=0 存下 Registration Lifetime 行 1407–1408）；§5.5.3 失败恢复（行
//!     1413–1436：NUD 失败删路由器条目 行 1413–1417；Status=1 不得再用该地址并以
//!     lifetime=0 注销其它路由器上的注册 行 1425–1429；Status=2 摘除该默认路由器
//!     行 1431–1434）；§5.6 下一跳（行 1439–1459：link-local → 目的地本身、组播 →
//!     on-link、其余 off-link → 默认路由器）；§5.7 地址解析（行 1471–1492：链路地址
//!     与 IID 推导值一致——只差 U/L 位——就不存 NCE）；§5.8 睡眠（行 1488–1535：
//!     注册 lifetime 必须大于睡眠时长 行 1496–1500；醒来刷新将过期的注册 行
//!     1528–1530，最短寿命快到就单播 RS 行 1530–1532）。
//!   * 协议常量 —— RFC 6775 §9（行 2247–2293：RS 间隔 10s 行 2255–2258、RS 上限 3、
//!     RS 退避封顶 60s）；RFC 4861 §10（行 4340–4383：MAX_UNICAST_SOLICIT=3 行 4362、
//!     RETRANS_TIMER=1000ms 行 4377、MIN/MAX_RANDOM_FACTOR=.5/1.5 行 4381–4383）；
//!     默认 Router Lifetime = 3×MaxRtrAdvInterval = 1800s（RFC 4861 行 2373 默认式 +
//!     行 2275 MaxRtrAdvInterval 默认 600s）；IPv6 最小 MTU 1280（RFC 2460 §5 行 1316）。
//!   * IID ↔ 链路地址 —— 802.15.4 短地址 IID `0000:00ff:fe00:XXXX`（RFC 6282 §3.2.2
//!     行 640–648，XXXX 大端）、EUI-64 翻 U/L 位（行 626–630）；BLE 48 位地址插
//!     FF FE 不翻位（RFC 7668 §3.2.2，`ipsp.iid` 同口径）；BLE 不得注册 link-local、
//!     ARO 的 EUI-64 = 48 位地址转 modified EUI-64（RFC 7668 §3.2.3 行 661–698）。
//!
//! 与 `fifteen4.zig` 的关系：它的 `iphc.Contexts` 已按 §5.4.2/§5.4.3 实现了同一套
//! 上下文有效期语义，本文件不重写压缩表，只通过公开 API `update/remove` 把本表同步
//! 进去（`Host.syncContexts`）。它的 RFC 1071 求和是私有的且与 UDP 伪头绑定
//! （Next Header=17），这里自己放一份通用实现给 ICMPv6 用（Next Header=58）。
//!
//! 明确不做：6LR/6LBR 行为与 DAR/DAC 报文（RFC 6775 第 6/8 章）；mesh 路由；DHCPv6
//! （M/O 旗标只记录）；SLAAC 本体（只存 PIO + 提供“前缀+IID 拼地址”助手）；发送 NA
//! （主机不发）；重定向；完整 RFC 4861 邻居缓存状态机——STALE/DELAY/PROBE 简化成
//! known/unreachable，因为 6LoWPAN-ND 的 NUD 就是注册 NS 本身（§5.5 行 1351–1362）。
//!
//! 保留字段的裁定：RFC 6775/4861 对所有保留字段写的是“MUST be ignored by the
//! receiver”——ARO Reserved 6775 行 892–894、6CO Res/Reserved 行 987–989、ABRO
//! Reserved 行 1087–1089；RFC 4861 的 RS/RA/NS/NA 各自的“Reserved 字段与未知选项
//! 必须忽略”段在行 2158–2161 / 2201–2204 / 3295–3298 / 3339–3342——所以保留字段
//! 非零**不是**拒绝路径（有正例用例钉住：nd6_tests 的 “reserved fields are
//! ignored, not rejected”）。拒绝路径只有整包级（校验和、Code、长度、hop limit、组播
//! Target/Solicited、未指定源）与选项级（ARO Length≠2、6CO Length 矛盾、
//! Context Length>128、ABRO Length≠3、PIO Length≠4）——每一类一个错误值。
//!
//! 时间与随机数全部注入：`now`（毫秒）与 `prand`（u32）一律是参数；不读时钟、
//! 不分配堆（定长数组、文件作用域缓冲）。表容量：上下文 16 = CID 4 位空间
//! （RFC 6282 §3.1.2）；路由器/前缀/注册/邻居条目超容量时新条目丢弃（RFC 4861
//! 行 2955–2958 允许主机不全存，但至少要保 2 条路由器）。

const std = @import("std");
const fifteen4 = @import("fifteen4.zig");
const ipsp = @import("ipsp.zig");

// ---------------------------------------------------------------------------
// 常量（每条带出处）
// ---------------------------------------------------------------------------

/// ICMPv6 类型（RFC 4861 §4.1–§4.4 行 1024/1081/1230/1277）。
pub const icmpv6_rs: u8 = 133;
pub const icmpv6_ra: u8 = 134;
pub const icmpv6_ns: u8 = 135;
pub const icmpv6_na: u8 = 136;

/// ND 选项类型（RFC 4861 §4.6 表 行 1538–1546；RFC 6775 §12 行 2699–2701）。
pub const opt_sllao: u8 = 1;
pub const opt_tllao: u8 = 2;
pub const opt_pio: u8 = 3;
pub const opt_mtu: u8 = 5;
pub const opt_aro: u8 = 33;
pub const opt_6co: u8 = 34;
pub const opt_abro: u8 = 35;

/// ARO/6CO/ABRO 的 Valid Lifetime 单位：60 s（6775 行 903–905、991–993、1080–1082）。
pub const lifetime_unit_s: u64 = 60;
/// ABRO Valid Lifetime 为 0 时假定 10000（≈一周）（6775 行 1083–1085）。
pub const abro_default_units: u64 = 10000;
/// ARO 状态值（6775 §4.1 Table 1 行 905–918；§12 行 2711–2722 Table 2）。
pub const aro_status_success: u8 = 0;
pub const aro_status_duplicate: u8 = 1;
pub const aro_status_cache_full: u8 = 2;

/// RS 节奏（6775 §9 行 2255–2268：10s 间隔、3 次、退避封顶 60s）。
pub const rtr_solicitation_interval_ms: u64 = 10_000;
pub const max_rtr_solicitations: u8 = 3;
pub const max_rtr_solicitation_interval_ms: u64 = 60_000;
/// 注册 NS 重传（6775 行 1360–1362 引 RFC 4861 §10：行 4362、4377）。
pub const max_unicast_solicit: u8 = 3;
pub const retrans_timer_ms: u64 = 1_000;
/// REACHABLE 随机区间 [0.5, 1.5]×BaseReachableTime（RFC 4861 行 2986–2988、4381–4383）。
/// 定点 16 位小数。
pub const reachable_factor_min_fp16: u32 = 0x8000; // 0.5
pub const reachable_factor_max_fp16: u32 = 0x18000; // 1.5
/// 默认 Router Lifetime（RFC 4861 行 2373 默认式 + 行 2275 MaxRtrAdvInterval 默认 600s）。
pub const default_router_lifetime_s: u64 = 3 * 600;
/// receive-only 保持期 = 2 × 默认 Router Lifetime（6775 行 1330–1332）。
pub const receive_only_hold_s: u64 = 2 * default_router_lifetime_s;
/// IPv6 最小链路 MTU（RFC 2460 §5 行 1316–1317）；MTU 选项低于它不采纳（RFC 4861 行 3050）。
pub const ipv6_min_mtu: u32 = 1280;
/// 全路由器组播 ff02::2（RFC 4291 §2.7.1；RS 的默认目的，RFC 4861 行 1001）。
pub const all_routers: [16]u8 = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };

/// 表容量。上下文 16 个 = CID 4 位空间（RFC 6282 §3.1.2 图 3）。
pub const max_routers: usize = 4;
pub const max_prefixes: usize = 4;
pub const max_contexts: usize = 16;
pub const max_registrations: usize = 6;
pub const max_neighbors: usize = 8;
pub const max_abrs: usize = 2;
/// 一条 RA 里最多细看的选项数；超出的有效选项计入 ignored（容量哨兵，非协议值）。
pub const max_ra_opts: usize = 8;

pub const Error = error{
    /// 报文比该类型的最小 ICMP 长度还短，或选项越过报文结尾（RFC 4861 行 2199、
    /// 3284、3331）。
    Short,
    /// ICMPv6 校验和不符（RFC 4443 §2.3 伪头 + RFC 1071）。
    BadChecksum,
    /// ICMP Code 不是 0 或类型不符（RFC 4861 行 2198/3282/3329）。
    BadCode,
    /// 选项长度 0 —— “MUST silently discard an ND packet”（RFC 4861 行 1528–1532）。
    ZeroLengthOption,
    /// 选项的 Length 字段与类型不符：ARO≠2、ABRO≠3、PIO≠4、SLLAO/TLLAO 形状未知、
    /// 6CO 的 Context Length>64 却 Length=2（6775 行 1393、1056–1058、968–969；
    /// 4861 行 1621；4944 图 7）。
    BadOptionLength,
    /// 6CO 的 Context Length > 128（6775 行 963–965 “ranges from 0 to 128”）。
    BadContextLength,
    /// NS/NA 的 Target Address 是组播（RFC 4861 行 3286/3337）。
    BadTarget,
    /// NA 目的地址是组播但 Solicited 旗标为 1（RFC 4861 行 3338–3340）。
    BadSolicited,
    /// IP 层校验：hop limit ≠ 255（RFC 4861 行 2174/3274/3321）、RA 源不是
    /// link-local（行 2178–2180）、NS 未指定源但目的不是 solicited-node 组播或带了
    /// SLLAO（行 3288–3292）。
    BadPacketSource,
    /// 参数非法：注册 link-local 地址、NS 目标是组播、睡眠时长超过可表达的注册寿命、
    /// RS/NS 用未指定源。
    BadParam,
    /// 编码输出缓冲放不下（选项/报文完整形状）。
    NoSpace,
    /// 注册表满（本实现的容量哨兵；上下文按 CID 定址不会满）。
    TableFull,
};

// ---------------------------------------------------------------------------
// 字节序与校验和
// ---------------------------------------------------------------------------

fn be16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn setBe16(b: []u8, v: u16) void {
    b[0] = @truncate(v >> 8);
    b[1] = @truncate(v);
}

fn setBe32(b: []u8, v: u32) void {
    b[0] = @truncate(v >> 24);
    b[1] = @truncate(v >> 16);
    b[2] = @truncate(v >> 8);
    b[3] = @truncate(v);
}

/// RFC 1071 求和：16 位大端逐字累加，奇数长度最后一字节当高字节。
fn sumWords(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    return sum;
}

/// 同 sumWords，但跳过 `[skip..skip+2)`（ICMPv6 的校验和字段——按 0 计）。
fn sumWordsSkipping(bytes: []const u8, skip: usize) u32 {
    return sumWords(bytes[0..skip]) + sumWords(bytes[skip + 2 ..]);
}

fn fold(sum0: u32) u16 {
    var sum = sum0;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

/// ICMPv6 校验和：RFC 4443 §2.3 伪头（源、目的、上层长度 32 位、3 个零、
/// Next Header=58）+ 报文本体，RFC 1071 一补码；报文的校验和字段按 0 计
/// （编码与验证同一口径，RFC 1071 §1.4 “To check a checksum, the receiver
/// ... adds ... including the checksum field; the result must be all 1 bits” 的
/// 等价形式）。与 lwIP 的 IP6 卷积（ip6_chksum 把字段置零后算）同口径。
pub fn icmpv6Checksum(src: [16]u8, dst: [16]u8, msg: []const u8) u16 {
    var pseudo: [40]u8 = @splat(0);
    @memcpy(pseudo[0..16], &src);
    @memcpy(pseudo[16..32], &dst);
    setBe32(pseudo[32..36], @intCast(msg.len));
    pseudo[39] = 58; // ICMPv6
    const body = if (msg.len >= 4) sumWordsSkipping(msg, 2) else sumWords(msg);
    return fold(sumWords(&pseudo) + body);
}

fn verifyChecksum(src: [16]u8, dst: [16]u8, msg: []const u8) Error!void {
    if (msg.len < 4) return error.Short;
    if (be16(msg[2..4]) != icmpv6Checksum(src, dst, msg)) return error.BadChecksum;
}

fn setChecksum(msg: []u8, src: [16]u8, dst: [16]u8) void {
    setBe16(msg[2..4], icmpv6Checksum(src, dst, msg));
}

// ---------------------------------------------------------------------------
// 地址分类（RFC 4291 §2.5.6 / §2.7 的口径，与 ipsp.zig 相同）
// ---------------------------------------------------------------------------

pub fn isLinkLocal(a: [16]u8) bool {
    return a[0] == 0xFE and (a[1] & 0xC0) == 0x80;
}

pub fn isMulticast(a: [16]u8) bool {
    return a[0] == 0xFF;
}

pub fn isUnspecified(a: [16]u8) bool {
    return std.mem.allEqual(u8, &a, 0);
}

/// solicited-node 组播 ff02::1:ffXX:XXXX（RFC 4291 §2.7.1；低 24 位 = 目标地址低 24 位）。
pub fn solicitedNode(target: [16]u8) [16]u8 {
    var m: [16]u8 = all_routers;
    m[11] = 0x01;
    m[12] = 0xFF;
    m[13] = target[13];
    m[14] = target[14];
    m[15] = target[15];
    return m;
}

// ---------------------------------------------------------------------------
// 链路地址 ↔ IID（5.6 行 1443–1446 “reversing the procedure”）
// ---------------------------------------------------------------------------

/// 主机所在链路的种类：决定 SLLAO 的 Length=1 形式读法（802.15.4 短地址 2 字节
/// / BLE 地址 6 字节）与 IID 的反推规则。
pub const LinkKind = enum { ieee802154, ble };

/// 链路层地址。802.15.4 短地址按线上大端当整数存（RFC 4944 §8 行 846
/// “canonical bit order”）；BLE 地址用 HCI 字节序（`ipsp.iid` 的口径）。
pub const LinkAddr = union(enum) {
    short16: u16,
    eui64: [8]u8,
    ble48: [6]u8,
};

/// 链路地址 → IID。802.15.4 短地址 → `0000:00ff:fe00:XXXX`（RFC 6282 §3.2.2
/// 行 640–648）；EUI-64 → 翻 U/L 位（行 626–630）；BLE → 中间插 FF FE 不翻位
/// （RFC 7668 §3.2.2，即 `ipsp.iid`）。
pub fn iidFromLink(lla: LinkAddr) [8]u8 {
    var iid: [8]u8 = @splat(0);
    switch (lla) {
        .short16 => |s| {
            // RFC 6282 §3.2.2 行 640-648：0000:00ff:fe00:XXXX → 字节序
            // {00,00,00,FF,FE,00,hi,lo}（与 fifteen4.iidFromShort 同一口径）。
            iid[3] = 0xFF;
            iid[4] = 0xFE;
            iid[6] = @truncate(s >> 8);
            iid[7] = @truncate(s);
        },
        .eui64 => |e| {
            @memcpy(&iid, &e);
            iid[0] ^= 0x02; // U/L 位（RFC 2464 §4；RFC 6282 行 629–630）
        },
        .ble48 => |b| iid = ipsp.iid(b),
    }
    return iid;
}

/// IID → 链路地址（5.6 行 1443–1446；RFC 4291 附录 A 的逆）。歧义裁定顺序：
/// 受限空间 `0000:00ff:fe00:XXXX` 先判（RFC 6282 行 645–648）；然后中间 FF FE
/// 的形式——BLE 链路读成 48 位设备地址，802.15.4 链路读成 EUI-64（反推 U/L）；
/// 其余当 EUI-64 反推。
pub fn linkFromIid(kind: LinkKind, iid: [8]u8) ?LinkAddr {
    // 受限空间 0000:00ff:fe00:XXXX → 字节 {00,00,00,FF,FE,00,hi,lo}。
    const short_pattern = iid[0] == 0 and iid[1] == 0 and iid[2] == 0 and
        iid[3] == 0xFF and iid[4] == 0xFE and iid[5] == 0;
    if (short_pattern) return .{ .short16 = (@as(u16, iid[6]) << 8) | iid[7] };
    if (iid[2] == 0xFF and iid[3] == 0xFE and kind == .ble) {
        return .{ .ble48 = .{ iid[7], iid[6], iid[5], iid[4], iid[1], iid[0] } };
    }
    var e = iid;
    e[0] ^= 0x02;
    return .{ .eui64 = e };
}

/// §5.7 行 1483–1486 的比较规则：“与 IID 推导值不同才存”——只差 U/L 位
/// （byte0 的 0x02）不算不同。
pub fn sameIidModuloUl(a: [8]u8, b: [8]u8) bool {
    if (a[0] & 0xFD != b[0] & 0xFD) return false;
    return std.mem.eql(u8, a[1..8], b[1..8]);
}

// ---------------------------------------------------------------------------
// 选项编解码
// ---------------------------------------------------------------------------

/// ARO 16 字节（RFC 6775 §4.1 图 行 874–881）：Type=33、Length=2、Status、
/// Reserved(1)、Reserved(16)、Registration Lifetime（60s 单位，大端）、EUI-64。
pub fn encodeAro(out: []u8, status: u8, lifetime_units: u16, eui64: [8]u8) Error!usize {
    if (out.len < 16) return error.NoSpace;
    out[0] = opt_aro;
    out[1] = 2;
    out[2] = status;
    out[3] = 0;
    out[4] = 0;
    out[5] = 0;
    setBe16(out[6..8], lifetime_units);
    @memcpy(out[8..16], &eui64);
    return 16;
}

pub const Aro = struct {
    status: u8,
    lifetime_units: u16,
    eui64: [8]u8,
};

/// 解析 ARO。Length 必须 2（6775 行 860–862 “Always 2”；接收侧行 1393–1395 不是 2
/// 就整条忽略——调用方拿 error 决定忽略）。
pub fn decodeAro(opt: []const u8) Error!Aro {
    if (opt.len < 2) return error.Short;
    if (opt[0] != opt_aro) return error.BadOptionLength;
    if (opt[1] != 2) return error.BadOptionLength;
    if (opt.len < 16) return error.Short;
    return .{
        .status = opt[2],
        .lifetime_units = be16(opt[6..8]),
        .eui64 = opt[8..16].*,
    };
}

/// 6CO（RFC 6775 §4.2 图 1 行 937–949）：Type=34、Length 2 或 3、Context Length、
/// Res(3)|C(1)|CID(4)、Reserved(16)、Valid Lifetime（60s 单位，大端）、前缀补零到
/// 8/16 字节。Context Length > 64 时 Length 必须 3（行 968–969）。
pub fn encode6co(out: []u8, cid: u4, prefix: [16]u8, prefix_len: u8, compression: bool, lifetime_units: u16) Error!usize {
    if (prefix_len > 128) return error.BadContextLength;
    const len: u8 = if (prefix_len > 64) 3 else 2;
    const total: usize = @as(usize, len) * 8;
    if (out.len < total) return error.NoSpace;
    @memset(out[0..total], 0);
    out[0] = opt_6co;
    out[1] = len;
    out[2] = prefix_len;
    out[3] = (@as(u8, @intFromBool(compression)) << 4) | @as(u8, cid);
    setBe16(out[6..8], lifetime_units);
    const prefix_bytes: usize = (@as(usize, prefix_len) + 7) / 8;
    @memcpy(out[8 .. 8 + prefix_bytes], prefix[0..prefix_bytes]);
    return total;
}

pub const Co = struct {
    cid: u4,
    prefix: [16]u8,
    prefix_len: u8,
    compression: bool,
    lifetime_units: u16,
};

pub fn decode6co(opt: []const u8) Error!Co {
    if (opt.len < 8) return error.Short;
    if (opt[0] != opt_6co) return error.BadOptionLength;
    const len = opt[1];
    if (len != 2 and len != 3) return error.BadOptionLength;
    const ctx_len = opt[2];
    if (ctx_len > 128) return error.BadContextLength;
    if (ctx_len > 64 and len != 3) return error.BadOptionLength; // 行 968–969
    const total: usize = @as(usize, len) * 8;
    if (opt.len < total) return error.Short;
    var prefix: [16]u8 = @splat(0);
    const carried: usize = 8 * (len - 1); // len2 → 8 字节、len3 → 16 字节
    @memcpy(prefix[0..carried], opt[8 .. 8 + carried]);
    return .{
        .cid = @truncate(opt[3] & 0x0F),
        .compression = (opt[3] & 0x10) != 0,
        .prefix_len = ctx_len,
        .lifetime_units = be16(opt[6..8]),
        .prefix = prefix,
    };
}

/// ABRO 24 字节（RFC 6775 §4.3 图 行 1032–1041）：Type=35、Length=3、
/// Version Low（低 16 位，先发）＋ Version High、Valid Lifetime（60s 单位，
/// 0 → 10000 行 1083–1085）、6LBR 地址。
pub fn encodeAbro(out: []u8, version: u32, lifetime_units: u16, lbr: [16]u8) Error!usize {
    if (out.len < 24) return error.NoSpace;
    @memset(out[0..24], 0);
    out[0] = opt_abro;
    out[1] = 3;
    setBe16(out[2..4], @truncate(version & 0xFFFF)); // Version Low
    setBe16(out[4..6], @truncate(version >> 16)); // Version High
    setBe16(out[6..8], lifetime_units);
    @memcpy(out[8..24], &lbr);
    return 24;
}

pub const Abro = struct {
    version: u32,
    lifetime_units: u16,
    lbr: [16]u8,
};

pub fn decodeAbro(opt: []const u8) Error!Abro {
    if (opt.len < 8) return error.Short;
    if (opt[0] != opt_abro) return error.BadOptionLength;
    if (opt[1] != 3) return error.BadOptionLength;
    if (opt.len < 24) return error.Short;
    const low: u32 = be16(opt[2..4]);
    const high: u32 = be16(opt[4..6]);
    return .{
        .version = (high << 16) | low,
        .lifetime_units = be16(opt[6..8]),
        .lbr = opt[8..24].*,
    };
}

/// SLLAO/TLLAO。支持的形状（RFC 4944 §8 图 7 行 754–846；BLE 形式 RFC 7668 没有专门
/// 定义，按 RFC 4861 §4.6.1 的一般规则补到 8 字节、Length=1，实现口径见报告）：
/// short16 / ble48 → Length=1（8 字节）；eui64 → Length=2（16 字节）。填充一律写零
/// （图 7 “all zeros”）；解码不校验填充（原文只规定发送方填零，接收侧没有拒绝规则）。
pub fn encodeSllao(out: []u8, t: LinkAddr, target: bool) Error!usize {
    const opt_type: u8 = if (target) opt_tllao else opt_sllao;
    switch (t) {
        .short16 => |s| {
            if (out.len < 8) return error.NoSpace;
            @memset(out[0..8], 0);
            out[0] = opt_type;
            out[1] = 1;
            setBe16(out[2..4], s);
            return 8;
        },
        .ble48 => |b| {
            if (out.len < 8) return error.NoSpace;
            @memset(out[0..8], 0);
            out[0] = opt_type;
            out[1] = 1;
            @memcpy(out[2..8], &b);
            return 8;
        },
        .eui64 => |e| {
            if (out.len < 16) return error.NoSpace;
            @memset(out[0..16], 0);
            out[0] = opt_type;
            out[1] = 2;
            @memcpy(out[2..10], &e);
            return 16;
        },
    }
}

/// 解析 SLLAO/TLLAO（802.15.4 口径：Length=1 读 2 字节短地址）。
pub fn decodeSllao(opt: []const u8) Error!LinkAddr {
    if (opt.len < 2) return error.Short;
    if (opt[0] != opt_sllao and opt[0] != opt_tllao) return error.BadOptionLength;
    switch (opt[1]) {
        1 => {
            if (opt.len < 8) return error.Short;
            return .{ .short16 = be16(opt[2..4]) };
        },
        2 => {
            if (opt.len < 16) return error.Short;
            return .{ .eui64 = opt[2..10].* };
        },
        else => return error.BadOptionLength,
    }
}

/// 同上，BLE 口径：Length=1 读 6 字节设备地址。
pub fn decodeSllaoBle(opt: []const u8) Error!LinkAddr {
    if (opt.len < 2) return error.Short;
    if (opt[0] != opt_sllao and opt[0] != opt_tllao) return error.BadOptionLength;
    if (opt[1] == 2) {
        if (opt.len < 16) return error.Short;
        return .{ .eui64 = opt[2..10].* };
    }
    if (opt[1] != 1) return error.BadOptionLength;
    if (opt.len < 8) return error.Short;
    return .{ .ble48 = opt[2..8].* };
}

fn decodeSllaoFor(kind: LinkKind, opt: []const u8) Error!LinkAddr {
    return if (kind == .ble) decodeSllaoBle(opt) else decodeSllao(opt);
}

// ---------------------------------------------------------------------------
// 报文解析（接收校验 + 选项走读）
// ---------------------------------------------------------------------------

/// ICMPv6 报文的 IP 层参数（校验和覆盖 src/dst；hop limit 是 ND 的接收校验之一）。
pub const PacketMeta = struct {
    src: [16]u8,
    dst: [16]u8,
    hop_limit: u8,
};

/// 一条 RA 选项的解析结果（按线上顺序）。被忽略的选项不计入 `opts`，只计入
/// `ignored`（差分对拍的 token 依赖这个约定）。
pub const RaOpt = union(enum) {
    sllao: LinkAddr,
    pio: Pio,
    mtu: u32,
    co: Co,
    abro: Abro,
};

/// 解析后的 PIO（RFC 4861 §4.6.2 行 1602–1692；Option Length 必须 4 —— 行 1621）。
pub const Pio = struct {
    prefix: [16]u8,
    prefix_len: u8,
    autonomous: bool,
    /// 秒；0xffffffff = 无穷（行 1668–1669），原样保存。
    valid_s: u32,
    preferred_s: u32,
};

pub const RaParsed = struct {
    /// Cur Hop Limit（0 = 未指定，RFC 4861 行 1096–1097）。
    cur_hop_limit: u8,
    managed: bool,
    other_config: bool,
    /// Router Lifetime（秒；0 = 不是默认路由器，行 1113–1114）。
    router_lifetime_s: u16,
    reachable_ms: u32,
    retrans_ms: u32,
    opts: [max_ra_opts]RaOpt = undefined,
    opts_n: usize = 0,
    /// 被忽略的选项条数（未知类型、TLLAO、带 L 的 PIO、link-local 前缀的 PIO、
    /// ARO、长度不符或满槽的选项）。
    ignored: usize = 0,
};

/// 解析 RA（RFC 4861 §6.1.2 行 2172–2201 + §6.3.4 行 2919 起；RFC 6775 §5.4）。
pub fn parseRa(meta: PacketMeta, msg: []const u8, kind: LinkKind) Error!RaParsed {
    if (meta.hop_limit != 255) return error.BadPacketSource; // 行 2174–2176
    if (!isLinkLocal(meta.src)) return error.BadPacketSource; // 行 2178–2180
    if (msg.len < 16) return error.Short; // 行 2199：ICMP 长度 ≥ 16
    try verifyChecksum(meta.src, meta.dst, msg);
    if (msg[0] != icmpv6_ra or msg[1] != 0) return error.BadCode; // 行 2198

    var r: RaParsed = .{
        .cur_hop_limit = msg[4],
        .managed = (msg[5] & 0x80) != 0,
        .other_config = (msg[5] & 0x40) != 0,
        .router_lifetime_s = be16(msg[6..8]),
        .reachable_ms = be32(msg[8..12]),
        .retrans_ms = be32(msg[12..16]),
    };

    var i: usize = 16;
    while (i < msg.len) {
        if (msg.len - i < 2) return error.Short; // 选项头被截断
        const t = msg[i];
        const l = msg[i + 1];
        if (l == 0) return error.ZeroLengthOption; // 行 1528–1532
        const opt_len: usize = @as(usize, l) * 8;
        if (i + opt_len > msg.len) return error.Short;
        const opt = msg[i .. i + opt_len];
        var consumed: bool = false;
        switch (t) {
            opt_sllao => {
                // 形状不明的 SLLAO（Length 不是 1/2）按未知选项忽略（RFC 4861
                // 行 2201 的精神）；长度 0 已在前面整包拒绝。
                if (decodeSllaoFor(kind, opt)) |lla| {
                    if (r.opts_n < max_ra_opts) {
                        r.opts[r.opts_n] = .{ .sllao = lla };
                        r.opts_n += 1;
                        consumed = true;
                    }
                } else |_| {}
            },
            opt_pio => {
                if (l == 4) { // 行 1621：Length 必须 4，不符整条忽略
                    const prefix_len = opt[2];
                    if (prefix_len <= 128) {
                        const on_link = (opt[3] & 0x80) != 0;
                        // 6775 行 1278–1280：带 L 必须忽略；RFC 4861 行 3047–3049：
                        // link-local 前缀忽略。Prefix Length > 128 不在“0 到 128”
                        // 的取值域里（行 1614–1616），同样整条忽略。
                        const ignore = on_link or (opt[16] == 0xFE and (opt[17] & 0xC0) == 0x80);
                        if (!ignore and r.opts_n < max_ra_opts) {
                            r.opts[r.opts_n] = .{ .pio = .{
                                .prefix = opt[16..32].*,
                                .prefix_len = prefix_len,
                                .autonomous = (opt[3] & 0x40) != 0,
                                .valid_s = be32(opt[4..8]),
                                .preferred_s = be32(opt[8..12]),
                            } };
                            r.opts_n += 1;
                            consumed = true;
                        }
                    }
                }
            },
            opt_mtu => {
                if (l == 1) { // RFC 4861 行 1763–1766：Length 必须 1
                    if (r.opts_n < max_ra_opts) {
                        r.opts[r.opts_n] = .{ .mtu = be32(opt[4..8]) };
                        r.opts_n += 1;
                        consumed = true;
                    }
                }
            },
            opt_6co => {
                if (decode6co(opt)) |co| {
                    if (r.opts_n < max_ra_opts) {
                        r.opts[r.opts_n] = .{ .co = co };
                        r.opts_n += 1;
                        consumed = true;
                    }
                } else |_| {} // 长度/上下文长度不符：整条忽略（§5.4.2 的输入不受信任）
            },
            opt_abro => {
                if (decodeAbro(opt)) |ab| {
                    if (r.opts_n < max_ra_opts) {
                        r.opts[r.opts_n] = .{ .abro = ab };
                        r.opts_n += 1;
                        consumed = true;
                    }
                } else |_| {}
            },
            else => {}, // 未知类型与 ARO/TLLAO：忽略（RFC 4861 行 2201–2204（RA）、3295–3298（NS）、3339–3342（NA））
        }
        if (!consumed) r.ignored += 1;
        i += opt_len;
    }
    return r;
}

pub const NsParsed = struct {
    target: [16]u8,
    sllao: ?LinkAddr = null,
    /// NS 里只有 SLLAO 是被定义的（RFC 4861 行 3301–3303）；其它已定义选项忽略。
    ignored: usize = 0,
};

/// 解析 NS（RFC 4861 §7.1.1 行 3272–3308）。主机通常只发不收，这里为编解码完备性而设。
pub fn parseNs(meta: PacketMeta, msg: []const u8, kind: LinkKind) Error!NsParsed {
    if (meta.hop_limit != 255) return error.BadPacketSource;
    if (msg.len < 24) return error.Short; // 行 3284
    try verifyChecksum(meta.src, meta.dst, msg);
    if (msg[0] != icmpv6_ns or msg[1] != 0) return error.BadCode; // 行 3282
    if (isMulticast(msg[8..24].*)) return error.BadTarget; // 行 3286
    var r: NsParsed = .{ .target = msg[8..24].* };
    var i: usize = 24;
    while (i < msg.len) {
        if (msg.len - i < 2) return error.Short;
        const t = msg[i];
        const l = msg[i + 1];
        if (l == 0) return error.ZeroLengthOption;
        const opt_len: usize = @as(usize, l) * 8;
        if (i + opt_len > msg.len) return error.Short;
        if (t == opt_sllao) {
            if (decodeSllaoFor(kind, msg[i .. i + opt_len])) |lla| {
                r.sllao = lla;
            } else |_| {
                r.ignored += 1;
            }
        } else {
            r.ignored += 1;
        }
        i += opt_len;
    }
    // 行 3288–3292：未指定源时目的必须是 solicited-node 组播且不得带 SLLAO。
    if (isUnspecified(meta.src)) {
        if (!std.mem.eql(u8, &meta.dst, &solicitedNode(r.target))) return error.BadPacketSource;
        if (r.sllao != null) return error.BadPacketSource;
    }
    return r;
}

pub const NaParsed = struct {
    /// R / S / O 旗标（RFC 4861 行 1285–1288）。
    router: bool,
    solicited: bool,
    override_flag: bool,
    target: [16]u8,
    tllao: ?LinkAddr = null,
    aro: ?Aro = null,
    /// ARO 在场但被 §5.5.2 忽略（Length≠2 或 EUI-64 不符）；NA 本体继续处理。
    aro_ignored: bool = false,
    ignored: usize = 0,
};

/// 解析 NA（RFC 4861 §7.1.2 行 3319–3342 + RFC 6775 §5.5.2 行 1386–1410）。
/// `my_eui64` 是本接口的 EUI-64（ARO 的 EUI-64 不符时整条忽略）。
pub fn parseNa(meta: PacketMeta, msg: []const u8, my_eui64: [8]u8, kind: LinkKind) Error!NaParsed {
    if (meta.hop_limit != 255) return error.BadPacketSource;
    if (msg.len < 24) return error.Short; // 行 3331
    try verifyChecksum(meta.src, meta.dst, msg);
    if (msg[0] != icmpv6_na or msg[1] != 0) return error.BadCode;
    if (isMulticast(msg[8..24].*)) return error.BadTarget; // 行 3337
    const flags = msg[4];
    const solicited = (flags & 0x40) != 0;
    if (isMulticast(meta.dst) and solicited) return error.BadSolicited; // 行 3338–3340
    var r: NaParsed = .{
        .router = (flags & 0x80) != 0,
        .solicited = solicited,
        .override_flag = (flags & 0x20) != 0,
        .target = msg[8..24].*,
    };
    var i: usize = 24;
    while (i < msg.len) {
        if (msg.len - i < 2) return error.Short;
        const t = msg[i];
        const l = msg[i + 1];
        if (l == 0) return error.ZeroLengthOption;
        const opt_len: usize = @as(usize, l) * 8;
        if (i + opt_len > msg.len) return error.Short;
        const opt = msg[i .. i + opt_len];
        switch (t) {
            opt_tllao => {
                if (decodeSllaoFor(kind, opt)) |lla| {
                    r.tllao = lla;
                } else |_| {
                    r.ignored += 1;
                }
            },
            opt_aro => {
                if (decodeAro(opt)) |aro| {
                    if (!std.mem.eql(u8, &aro.eui64, &my_eui64)) {
                        r.aro_ignored = true; // 行 1394–1395
                    } else {
                        r.aro = aro;
                    }
                } else |_| {
                    r.aro_ignored = true; // 行 1393–1394
                }
            },
            else => r.ignored += 1,
        }
        i += opt_len;
    }
    return r;
}

// ---------------------------------------------------------------------------
// 报文编码（RS / 注册 NS / RA 头 / NA 头 —— 编码往返与测试用）
// ---------------------------------------------------------------------------

/// RS（RFC 4861 §4.1 行 1010–1014）：8 字节头 + SLLAO。SLLAO 必须给（RFC 6775 §5.3
/// 行 1242–1243）；未指定源禁止（行 1246）。
pub fn encodeRs(out: []u8, src: [16]u8, dst: [16]u8, lla: LinkAddr) Error!usize {
    if (isUnspecified(src)) return error.BadParam; // 行 1246
    const n: usize = switch (lla) {
        .eui64 => 8 + 16,
        else => 8 + 8,
    };
    if (out.len < n) return error.NoSpace;
    out[0] = icmpv6_rs;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    out[4] = 0;
    out[5] = 0;
    out[6] = 0;
    out[7] = 0;
    const opt_len = try encodeSllao(out[8..n], lla, false);
    setChecksum(out[0 .. 8 + opt_len], src, dst);
    return 8 + opt_len;
}

/// 注册 NS（RFC 6775 §5.5.1 + RFC 4861 §4.3 行 1212–1236）：Target = 路由器地址，
/// ARO + SLLAO。源地址 = 注册地址（6775 行 866–867）；lifetime_units = 0 是注销
/// （行 1369–1371）。BLE 上不得注册 link-local（RFC 7668 §3.2.3 行 661–663）。
pub fn encodeRegistrationNs(out: []u8, registered: [16]u8, router: [16]u8, lifetime_units: u16, eui64: [8]u8, lla: LinkAddr) Error!usize {
    if (isUnspecified(registered)) return error.BadParam; // 行 1378
    if (isLinkLocal(registered)) return error.BadParam; // RFC 7668 行 661–663
    if (isMulticast(router)) return error.BadTarget; // §5.1 行 1212 的前提：单播
    const slla_len: usize = switch (lla) {
        .eui64 => 16,
        else => 8,
    };
    const n = 24 + 16 + slla_len;
    if (out.len < n) return error.NoSpace;
    @memset(out[0..24], 0);
    out[0] = icmpv6_ns;
    @memcpy(out[8..24], &router); // Target Address
    _ = try encodeAro(out[24..40], aro_status_success, lifetime_units, eui64);
    _ = try encodeSllao(out[40..n], lla, false);
    setChecksum(out[0..n], registered, router);
    return n;
}

/// RA 头 16 字节（RFC 4861 §4.2 行 1039–1046），校验和先置 0；选项由调用方追加后
/// 调 `finalizeChecksum`。
pub fn encodeRaHeader(out: []u8, cur_hop_limit: u8, managed: bool, other: bool, lifetime_s: u16, reachable_ms: u32, retrans_ms: u32) Error!void {
    if (out.len < 16) return error.NoSpace;
    out[0] = icmpv6_ra;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    out[4] = cur_hop_limit;
    out[5] = (@as(u8, @intFromBool(managed)) << 7) | (@as(u8, @intFromBool(other)) << 6);
    setBe16(out[6..8], lifetime_s);
    setBe32(out[8..12], reachable_ms);
    setBe32(out[12..16], retrans_ms);
}

/// NA 头 24 字节（RFC 4861 §4.4 行 1266–1273）。主机不发 NA；编码侧供往返测试与
/// 对拍驱动用。
pub fn encodeNaHeader(out: []u8, router: bool, solicited: bool, override_flag: bool, target: [16]u8) Error!void {
    if (out.len < 24) return error.NoSpace;
    out[0] = icmpv6_na;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    out[4] = (@as(u8, @intFromBool(router)) << 7) |
        (@as(u8, @intFromBool(solicited)) << 6) |
        (@as(u8, @intFromBool(override_flag)) << 5);
    out[5] = 0;
    out[6] = 0;
    out[7] = 0;
    @memcpy(out[8..24], &target);
    if (out.len > 24) @memset(out[24..], 0);
}

/// 报文选项追加完之后补校验和。
pub fn finalizeChecksum(msg: []u8, src: [16]u8, dst: [16]u8) void {
    setChecksum(msg, src, dst);
}

// ---------------------------------------------------------------------------
// 主机状态（RFC 6775 第 5 章）
// ---------------------------------------------------------------------------

pub const RouterEntry = struct {
    live: bool = false,
    addr: [16]u8 = @splat(0),
    /// RA 的 SLLAO（§5.4 行 1276 要求 RA 带 SLLAO；缺席则暂无）。
    lla: ?LinkAddr = null,
    /// Router Lifetime 到期时刻（ms）。
    valid_until: u64 = 0,
    managed: bool = false,
    other_config: bool = false,
};

pub const PrefixEntry = struct {
    live: bool = false,
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    autonomous: bool = false,
    valid_until: u64 = 0,
    /// Valid Lifetime 0xffffffff（无穷）不设到期。
    infinite: bool = false,
};

/// 上下文表条目（§5.4.2/§5.4.3）。C=0 或过期 → receive-only：只能解压（行 1304–1306、
/// 1329–1332），保持期满整条删除。
pub const ContextEntry = struct {
    live: bool = false,
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    compression: bool = false,
    valid_until: u64 = 0,
    hold_until: u64 = 0,
};

pub const ContextState = enum { free, valid, receive_only };

pub const AbrEntry = struct {
    live: bool = false,
    lbr: [16]u8 = @splat(0),
    version: u32 = 0,
    valid_until: u64 = 0,
};

pub const RegState = enum {
    /// 注册进行中（NS 已发，等带 ARO 的 NA）。
    probing,
    /// 已注册，`expires_at` 前要续期（§5.5 行 1357–1360）。
    registered,
    /// Status=1：地址重复，不得再用（§5.5.3 行 1425–1429 + RFC 4862 §5.4.5）。
    failed_duplicate,
    /// Status=2：对方缓存满（§5.5.3 行 1431–1434）。
    failed_cache_full,
    /// 重传耗尽（NUD 失败，§5.5.3 行 1413–1417）或其它非零状态（行 1434–1436）。
    failed_nud,
    /// 正在以 lifetime=0 注销（dup 失败后对其它路由器）。
    deregistering,
};

pub const RegEntry = struct {
    live: bool = false,
    addr: [16]u8 = @splat(0),
    router: [16]u8 = @splat(0),
    state: RegState = .probing,
    expires_at: u64 = 0,
    retries_left: u8 = 0,
    next_action_at: u64 = 0,
    /// 失败动作已做（避免重复注销/摘除）。
    handled: bool = false,
};

pub const NeighborEntry = struct {
    live: bool = false,
    addr: [16]u8 = @splat(0),
    /// 存在这里的值都和 IID 推导值不同（§5.7 行 1483–1486）。
    lla: ?LinkAddr = null,
    reachable: bool = false,
    last_confirmed_ms: u64 = 0,
};

pub const SolicitState = struct {
    active: bool = false,
    count: u8 = 0,
    next_at: u64 = 0,
    interval_ms: u64 = rtr_solicitation_interval_ms,
};

/// 发给调用方的动作：所有发送都由外部完成，本模块只描述“现在该发什么”。
/// NS 的 Registration Lifetime 由调用方决定（§5.8.1 的睡眠策略），所以动作里
/// 只区分“注销（lifetime=0）”与“正常注册/续期”。
pub const Action = union(enum) {
    /// RS（§5.3）：DRL 空发全路由器组播（行 1240–1241），否则对现有路由器单播
    /// （§5.4.3 行 1341–1344）。
    send_rs: [16]u8,
    /// 注册 NS（§5.5.1）。dereg=true 时 Registration Lifetime 填 0（行 1369–1371）。
    send_register: struct { registered: [16]u8, router: [16]u8, dereg: bool },
    /// 注册 NS 重传耗尽（§5.5.3 行 1413–1417）：该路由器条目已删除。
    nud_failed: [16]u8,
};

pub const Host = struct {
    /// 本接口 EUI-64（ARO 用，RFC 6775 §4.1 行 879–881；BLE 上是 48 位地址转的
    /// modified EUI-64，RFC 7668 §3.2.3 行 696–698）。
    eui64: [8]u8,
    kind: LinkKind,
    /// 当前时刻（ms），各入口的 `now` 参数推进。
    now: u64 = 0,
    cur_hop_limit: u8 = 0,
    base_reachable_ms: u32 = 0,
    /// 随机化后的当前值（RFC 4861 行 2986–2988）。
    reachable_ms: u32 = 0,
    retrans_timer_ms: u32 = 0,
    link_mtu: u32 = 0,
    solicit: SolicitState = .{},
    routers: [max_routers]RouterEntry = @splat(.{}),
    prefixes: [max_prefixes]PrefixEntry = @splat(.{}),
    contexts: [max_contexts]ContextEntry = @splat(.{}),
    abrs: [max_abrs]AbrEntry = @splat(.{}),
    regs: [max_registrations]RegEntry = @splat(.{}),
    neighbors: [max_neighbors]NeighborEntry = @splat(.{}),

    pub fn init(eui64: [8]u8, kind: LinkKind) Host {
        return .{ .eui64 = eui64, .kind = kind };
    }

    // ---- RA ----

    /// 处理 RA：parseRa 的校验全部生效，然后按 §5.4/§6.3.4 落表。
    /// `prand` 用于 BaseReachableTime 变化时重抽 ReachableTime（RFC 4861 行 2986–2988）。
    /// 收到 RA 终止 RS 重传（§5.3 行 1261–1262）。
    pub fn processRa(self: *Host, meta: PacketMeta, msg: []const u8, now: u64, prand: u32) Error!RaParsed {
        const r = try parseRa(meta, msg, self.kind);
        self.now = now;
        self.applyRa(meta.src, r, prand);
        self.solicit = .{};
        return r;
    }

    fn applyRa(self: *Host, src: [16]u8, r: RaParsed, prand: u32) void {
        // 默认路由器（RFC 4861 行 2941–2954；Router Lifetime 0 → 立即摘除 行 2949–2954）。
        // 表满且是新路由器时丢弃该条（行 2955–2958 允许不全存；至少保 2 条是主机的义务）。
        const ri = self.routerIndex(src);
        if (r.router_lifetime_s == 0) {
            if (ri) |i| self.routers[i] = .{};
        } else if (ri != null or self.routerFree() != null) {
            const i = ri orelse self.routerFree().?;
            self.routers[i] = .{
                .live = true,
                .addr = src,
                .valid_until = self.now + @as(u64, r.router_lifetime_s) * 1000,
                .managed = r.managed,
                .other_config = r.other_config,
            };
        }
        if (r.cur_hop_limit != 0) self.cur_hop_limit = r.cur_hop_limit;
        if (r.reachable_ms != 0) {
            self.base_reachable_ms = r.reachable_ms;
            self.reachable_ms = randomReachable(r.reachable_ms, prand);
        }
        if (r.retrans_ms != 0) self.retrans_timer_ms = r.retrans_ms;

        for (r.opts[0..r.opts_n]) |o| switch (o) {
            .sllao => |lla| {
                if (self.routerIndex(src)) |i| {
                    self.routers[i].lla = lla;
                    self.learnNeighbor(src, lla, self.now, true);
                }
            },
            .pio => |p| {
                const n: usize = (@as(usize, p.prefix_len) + 7) / 8;
                if (p.valid_s == 0) {
                    // Valid Lifetime 0：删同前缀条目（RFC 4861 行 3056–3059）。
                    for (&self.prefixes) |*e| {
                        if (e.live and e.prefix_len == p.prefix_len and
                            std.mem.eql(u8, e.prefix[0..n], p.prefix[0..n])) e.* = .{};
                    }
                } else if (self.prefixIndex(p.prefix, p.prefix_len) != null or self.prefixFree() != null) {
                    const i = self.prefixIndex(p.prefix, p.prefix_len) orelse self.prefixFree().?;
                    const infinite = p.valid_s == 0xFFFF_FFFF; // 行 1668–1669
                    self.prefixes[i] = .{
                        .live = true,
                        .prefix = p.prefix,
                        .prefix_len = p.prefix_len,
                        .autonomous = p.autonomous,
                        .valid_until = if (infinite) 0 else self.now + @as(u64, p.valid_s) * 1000,
                        .infinite = infinite,
                    };
                }
            },
            .mtu => |m| {
                // ≥ IPv6 最小 MTU 才采纳（RFC 4861 行 3050–3053；RFC 2460 §5 行 1316）。
                if (m >= ipv6_min_mtu) self.link_mtu = m;
            },
            .co => |c| self.applyContext(c), // §5.4.2 行 1310–1323
            .abro => |a| {
                var units: u64 = a.lifetime_units;
                if (units == 0) units = abro_default_units; // 行 1083–1085
                if (self.abrIndex(a.lbr)) |i| {
                    self.abrs[i].version = a.version;
                    self.abrs[i].valid_until = self.now + units * lifetime_unit_s * 1000;
                } else if (self.abrFree()) |i| {
                    self.abrs[i] = .{
                        .live = true,
                        .lbr = a.lbr,
                        .version = a.version,
                        .valid_until = self.now + units * lifetime_unit_s * 1000,
                    };
                }
            },
        };
    }

    // ---- 上下文表（§5.4.2 / §5.4.3） ----

    /// 上下文长度 > 128 的输入在 decode6co 已拒；这里是防御性兜底（直接丢弃）。
    pub fn applyContext(self: *Host, c: Co) void {
        const id: usize = c.cid;
        if (c.lifetime_units == 0) {
            self.contexts[id] = .{}; // 行 1317–1319：立即删除
            return;
        }
        const valid_until = self.now + @as(u64, c.lifetime_units) * lifetime_unit_s * 1000;
        self.contexts[id] = .{
            .live = true,
            .prefix = c.prefix,
            .prefix_len = c.prefix_len,
            .compression = c.compression,
            .valid_until = valid_until,
            .hold_until = valid_until + receive_only_hold_s * 1000, // 行 1330–1332
        };
    }

    pub fn contextState(self: *const Host, cid: u4, now: u64) ContextState {
        const e = self.contexts[cid];
        if (!e.live or now >= e.hold_until) return .free;
        if (now < e.valid_until and e.compression) return .valid;
        return .receive_only; // C=0 或过期：只解压（行 1304–1306、1329–1332）
    }

    /// 上下文表 → fifteen4 的 IPHC 压缩表（只读调用它的公开 API `update`/`remove`，
    /// 并把它的时钟拨到本表时钟）。有效条目按剩余寿命向上取整到 60s 单位同步
    /// （±60s 舍入）；receive-only 条目按剩余保持期同步成 C=0 条目——fifteen4 的表
    /// 会在其后多挂一轮 receive-only 窗口（它的 remove_at = valid_until + 2×1800s），
    /// 权威状态始终是本表；差值在报告里注明。
    pub fn syncContexts(self: *const Host, target: *fifteen4.iphc.Contexts) void {
        target.now = self.now;
        for (self.contexts, 0..) |e, i| {
            const id: u4 = @intCast(i);
            if (!e.live or self.now >= e.hold_until) {
                target.remove(id);
                continue;
            }
            const unit_ms: u64 = lifetime_unit_s * 1000;
            if (self.now < e.valid_until) {
                const remaining = e.valid_until - self.now;
                const units: u16 = @intCast(@min((remaining + unit_ms - 1) / unit_ms, 0xFFFF));
                target.update(id, e.prefix, e.prefix_len, e.compression, units) catch {};
            } else {
                const remaining = e.hold_until - self.now;
                const units: u16 = @intCast(@min((remaining + unit_ms - 1) / unit_ms, 0xFFFF));
                target.update(id, e.prefix, e.prefix_len, false, units) catch {};
            }
        }
    }

    // ---- 注册（§5.5） ----

    /// 开始/续期注册：建表项，NS 由 tick 产出动作后由调用方编码发送。
    /// link-local 拒绝（RFC 7668 §3.2.3 行 661–663；RFC 6775 注册的是配置出来的
    /// 地址，§5.4.1 行 1283–1289）。
    pub fn register(self: *Host, addr: [16]u8, router: [16]u8, now: u64) Error!void {
        if (isLinkLocal(addr)) return error.BadParam;
        self.now = now;
        if (self.regIndex(addr, router) == null and self.regFree() == null) return error.TableFull;
        const i = self.regIndex(addr, router) orelse self.regFree().?;
        self.regs[i] = .{
            .live = true,
            .addr = addr,
            .router = router,
            .state = .probing,
            .retries_left = max_unicast_solicit,
            .next_action_at = now,
        };
    }

    /// 处理带 ARO 的 NA（§5.5.2）。返回命中的注册地址（没有命中返回 null）。
    pub fn processNa(self: *Host, meta: PacketMeta, msg: []const u8, now: u64) Error!?[16]u8 {
        const r = try parseNa(meta, msg, self.eui64, self.kind);
        self.now = now;
        var hit: ?usize = null;
        // 成功路径：目的 = 注册地址、源 = 路由器（RFC 6775 图 5 行 2507–2510）。
        for (&self.regs, 0..) |*e, i| {
            if (!e.live) continue;
            if (std.mem.eql(u8, &e.router, &meta.src) and std.mem.eql(u8, &e.addr, &meta.dst)) hit = i;
        }
        // 失败路径：错误 NA 发给按 EUI-64 推出的 link-local（§4.1 行 885–886、
        // 图 5 行 2517–2519），按路由器匹配正在探测的注册。
        if (hit == null) {
            for (&self.regs, 0..) |*e, i| {
                if (!e.live or e.state != .probing) continue;
                if (std.mem.eql(u8, &e.router, &meta.src)) {
                    hit = i;
                    break;
                }
            }
        }
        const i = hit orelse return null;
        const e = &self.regs[i];
        if (r.aro) |aro| {
            if (aro.status == aro_status_success) {
                e.state = .registered;
                e.expires_at = now + @as(u64, aro.lifetime_units) * lifetime_unit_s * 1000; // 行 1407–1408
            } else {
                e.state = if (aro.status == aro_status_duplicate)
                    .failed_duplicate
                else if (aro.status == aro_status_cache_full)
                    .failed_cache_full
                else
                    .failed_nud; // 其它码按失败处理（行 1434–1436），允许再试
                e.handled = false;
            }
            return e.addr;
        }
        // 没有 ARO 的 NA 不完成注册（行 1360–1362），只按 RFC 4861 §7.2.5 更新邻居表。
        self.learnNeighbor(r.target, r.tllao, now, r.solicited);
        return null;
    }

    // ---- 下一跳（§5.6）与地址解析（§5.7） ----

    pub const Hop = union(enum) {
        /// link-local 目的地本身（行 1440–1446）。
        neighbor: [16]u8,
        /// 送到默认路由器（行 1455–1458）。
        router: [16]u8,
        /// 组播：链路层封包按 RFC 4944 §9 / RFC 7668 §3.2.5（不在本模块）。
        multicast,
        /// 没有默认路由器可用。
        no_route,
    };

    pub fn nextHop(self: *const Host, dst: [16]u8) Hop {
        if (isMulticast(dst)) return .multicast; // 行 1448–1452
        if (isLinkLocal(dst)) return .{ .neighbor = dst }; // 行 1440–1446
        // 其余前缀一律 off-link（行 1453–1458）；anycast 无法从地址分辨，同样走这里。
        for (self.routers) |e| {
            if (e.live and self.now < e.valid_until) return .{ .router = e.addr };
        }
        return .no_route;
    }

    /// 记录一条邻居链路地址。§5.7 行 1483–1486：与 IID 推导值一致（只差 U/L 位）
    /// 就不存；表满或推导失败的输入直接丢弃。
    pub fn learnNeighbor(self: *Host, addr: [16]u8, lla: ?LinkAddr, now: u64, reachable: bool) void {
        const given = lla orelse return;
        var ni: ?usize = null;
        for (&self.neighbors, 0..) |*e, i| {
            if (e.live and std.mem.eql(u8, &e.addr, &addr)) ni = i;
        }
        if (ni == null) {
            for (&self.neighbors, 0..) |*e, idx| {
                if (!e.live) {
                    ni = idx;
                    break;
                }
            }
        }
        const i = ni orelse return;
        const derived = linkFromIid(self.kind, addr[8..16].*) orelse return;
        const identical = switch (derived) {
            .eui64 => |de| switch (given) {
                .eui64 => |ge| sameIidModuloUl(de, ge),
                else => false,
            },
            .short16 => |ds| switch (given) {
                .short16 => |gs| ds == gs,
                else => false,
            },
            .ble48 => |db| switch (given) {
                .ble48 => |gb| std.mem.eql(u8, &db, &gb),
                else => false,
            },
        };
        if (identical) return; // 行 1483–1486
        self.neighbors[i] = .{
            .live = true,
            .addr = addr,
            .lla = given,
            .reachable = reachable,
            .last_confirmed_ms = now,
        };
    }

    /// 地址解析：邻居表 → IID 反推（5.6 行 1443–1446 / 5.7 行 1476–1483）。
    /// §5.7 的前提是“多数全球地址由链路地址构成”；IID 推导不可信的地址由调用方
    /// 决定是否落到默认路由器。
    pub fn resolveLinkAddr(self: *const Host, addr: [16]u8) ?LinkAddr {
        for (self.neighbors) |e| {
            if (e.live and std.mem.eql(u8, &e.addr, &addr)) return e.lla;
        }
        return linkFromIid(self.kind, addr[8..16].*);
    }

    // ---- 睡眠（§5.8） ----

    /// 给定本次睡眠时长（ms），选注册寿命：必须严格大于睡眠时长（§5.8.1 行
    /// 1496–1500），向上取整到 60s 单位再加 1（预留一整个重传周期 + 时钟漂移的
    /// 下限）。0xFFFF 单位 ≈ 45.8 天是上限。
    pub fn pickRegistrationLifetime(sleep_ms: u64) Error!u16 {
        const unit_ms: u64 = lifetime_unit_s * 1000;
        const units = (sleep_ms + unit_ms - 1) / unit_ms + 1;
        if (units > 0xFFFF) return error.BadParam;
        return @intCast(units);
    }

    /// §5.8.2 行 1528–1530：醒来时刷新将在下次醒来前过期的注册（发续期 NS）。
    /// 返回写进 `out` 的动作数。
    pub fn onWakeup(self: *Host, now: u64, next_sleep_ms: u64, out: []Action) usize {
        self.now = now;
        var n: usize = 0;
        for (&self.regs) |*e| {
            if (!e.live or e.state != .registered) continue;
            if (e.expires_at < now + next_sleep_ms) {
                e.state = .probing;
                e.retries_left = max_unicast_solicit - 1;
                e.next_action_at = now + retrans_timer_ms;
                if (n < out.len) {
                    out[n] = .{ .send_register = .{ .registered = e.addr, .router = e.router, .dereg = false } };
                    n += 1;
                }
            }
        }
        return n;
    }

    /// RA 信息（默认 Router Lifetime / PIO / 6CO 的最短寿命，§5.4.3 行 1337–1347）
    /// 相对 `now` 还剩多久；null 表示没有任何带寿命的信息（无需刷新）。
    pub fn infoRefreshIn(self: *const Host, now: u64) ?u64 {
        var best: ?u64 = null;
        for (self.routers) |e| if (e.live) consider(&best, e.valid_until, now);
        for (self.prefixes) |e| if (e.live and !e.infinite) consider(&best, e.valid_until, now);
        for (self.contexts) |e| if (e.live) consider(&best, e.valid_until, now);
        return best;
    }

    fn consider(best: *?u64, at: u64, now: u64) void {
        const d = if (at <= now) 0 else at - now;
        if (best.* == null or d < best.*.?) best.* = d;
    }

    // ---- 主循环 ----

    /// 推进时钟并产出动作。动作槽满时丢弃多余项（条件仍在，下一轮 tick 会再产出）。
    pub fn tick(self: *Host, now: u64, out: []Action) usize {
        self.now = now;
        var n: usize = 0;
        const push = struct {
            fn f(out0: []Action, n0: *usize, a: Action) void {
                if (n0.* < out0.len) {
                    out0[n0.*] = a;
                    n0.* += 1;
                }
            }
        }.f;

        // 过期清理：上下文保持期（行 1332）、ABRO、PIO（RFC 4861 前缀超时）、
        // 默认路由器（RFC 4861 §6.3.5）。
        for (&self.contexts) |*e| {
            if (e.live and now >= e.hold_until) e.* = .{};
        }
        for (&self.abrs) |*e| {
            if (e.live and now >= e.valid_until) e.* = .{};
        }
        for (&self.prefixes) |*e| {
            if (e.live and !e.infinite and now >= e.valid_until) e.* = .{};
        }
        for (&self.routers) |*e| {
            if (e.live and now >= e.valid_until) e.* = .{};
        }

        // 注册状态机（§5.5 / §5.5.3）。
        const retrans = if (self.retrans_timer_ms != 0) @as(u64, self.retrans_timer_ms) else retrans_timer_ms;
        for (&self.regs) |*e| {
            if (!e.live) continue;
            switch (e.state) {
                .probing => {
                    if (now >= e.next_action_at) {
                        if (e.retries_left > 0) {
                            e.retries_left -= 1;
                            e.next_action_at = now + retrans; // 行 1360–1362
                            push(out, &n, .{ .send_register = .{ .registered = e.addr, .router = e.router, .dereg = false } });
                        } else {
                            // 重传耗尽：NUD 失败，摘路由器（行 1413–1417）。
                            e.state = .failed_nud;
                            push(out, &n, .{ .nud_failed = e.router });
                            if (self.routerIndex(e.router)) |ri| self.routers[ri] = .{};
                        }
                    }
                },
                .registered => {
                    // “well before”的量化：留出整整一轮重传（3×RETRANS_TIMER）。
                    if (e.expires_at <= now + retrans * max_unicast_solicit) {
                        e.state = .probing;
                        e.retries_left = max_unicast_solicit - 1;
                        e.next_action_at = now + retrans;
                        push(out, &n, .{ .send_register = .{ .registered = e.addr, .router = e.router, .dereg = false } });
                    }
                },
                .failed_duplicate => {
                    // 行 1425–1429：不得再用该地址，注销其它路由器上的有效注册。
                    if (!e.handled) {
                        e.handled = true;
                        for (&self.regs) |*o| {
                            if (o.live and o != e and o.state == .registered and
                                std.mem.eql(u8, &o.addr, &e.addr))
                            {
                                o.state = .deregistering;
                                push(out, &n, .{ .send_register = .{ .registered = o.addr, .router = o.router, .dereg = true } });
                            }
                        }
                    }
                },
                .failed_cache_full => {
                    // 行 1431–1434：摘除该路由器；改注册别的路由器 / 重新 RS。
                    if (!e.handled) {
                        e.handled = true;
                        if (self.routerIndex(e.router)) |ri| self.routers[ri] = .{};
                    }
                },
                .deregistering => {
                    // 注销 NS 已发出；条目生命周期结束。
                    e.live = false;
                },
                .failed_nud => {},
            }
        }

        // RS 状态机（§5.3 行 1254–1262；§5.4.3 行 1337–1347）。“well before” 的
        // 量化：最短寿命 ≤ 一个 RS 间隔（10s）时触发刷新。
        const refresh_left = self.infoRefreshIn(now);
        const refresh_due = refresh_left != null and refresh_left.? <= rtr_solicitation_interval_ms;
        const need_routers = !self.hasRouter();
        if (need_routers or refresh_due) {
            if (!self.solicit.active) {
                self.solicit = .{
                    .active = true,
                    .count = 1,
                    .next_at = now + rtr_solicitation_interval_ms,
                    .interval_ms = rtr_solicitation_interval_ms,
                };
                self.emitRs(need_routers, out, &n);
            } else if (now >= self.solicit.next_at) {
                if (self.solicit.count < max_rtr_solicitations) {
                    self.solicit.count += 1;
                    self.solicit.next_at = now + rtr_solicitation_interval_ms;
                } else {
                    // 截断指数退避，封顶 60s（行 1256–1261）。
                    self.solicit.interval_ms = @min(self.solicit.interval_ms * 2, max_rtr_solicitation_interval_ms);
                    self.solicit.next_at = now + self.solicit.interval_ms;
                }
                self.emitRs(need_routers, out, &n);
            }
        } else {
            self.solicit = .{};
        }
        return n;
    }

    fn emitRs(self: *Host, multicast: bool, out: []Action, n: *usize) void {
        if (multicast) {
            self.pushAction(out, n, .{ .send_rs = all_routers });
            return;
        }
        for (self.routers) |e| {
            if (e.live and self.now < e.valid_until) self.pushAction(out, n, .{ .send_rs = e.addr });
        }
    }

    fn pushAction(self: *Host, out: []Action, n: *usize, a: Action) void {
        _ = self;
        if (n.* < out.len) {
            out[n.*] = a;
            n.* += 1;
        }
    }

    // ---- 表的小工具 ----

    fn routerIndex(self: *const Host, addr: [16]u8) ?usize {
        for (&self.routers, 0..) |*e, i| {
            if (e.live and std.mem.eql(u8, &e.addr, &addr)) return i;
        }
        return null;
    }
    fn routerFree(self: *const Host) ?usize {
        for (&self.routers, 0..) |*e, i| {
            if (!e.live) return i;
        }
        return null;
    }
    fn prefixIndex(self: *const Host, prefix: [16]u8, len: u8) ?usize {
        const n: usize = (@as(usize, len) + 7) / 8;
        for (&self.prefixes, 0..) |*e, i| {
            if (e.live and e.prefix_len == len and std.mem.eql(u8, e.prefix[0..n], prefix[0..n])) return i;
        }
        return null;
    }
    fn prefixFree(self: *const Host) ?usize {
        for (&self.prefixes, 0..) |*e, i| {
            if (!e.live) return i;
        }
        return null;
    }
    fn regIndex(self: *const Host, addr: [16]u8, router: [16]u8) ?usize {
        for (&self.regs, 0..) |*e, i| {
            if (e.live and std.mem.eql(u8, &e.addr, &addr) and std.mem.eql(u8, &e.router, &router)) return i;
        }
        return null;
    }
    fn regFree(self: *const Host) ?usize {
        for (&self.regs, 0..) |*e, i| {
            if (!e.live) return i;
        }
        return null;
    }
    fn abrIndex(self: *const Host, lbr: [16]u8) ?usize {
        for (&self.abrs, 0..) |*e, i| {
            if (e.live and std.mem.eql(u8, &e.lbr, &lbr)) return i;
        }
        return null;
    }
    fn abrFree(self: *const Host) ?usize {
        for (&self.abrs, 0..) |*e, i| {
            if (!e.live) return i;
        }
        return null;
    }
    fn hasRouter(self: *const Host) bool {
        for (self.routers) |e| {
            if (e.live and self.now < e.valid_until) return true;
        }
        return false;
    }
};

/// ReachableTime = [0.5, 1.5] × BaseReachableTime 的均匀抽样（RFC 4861 行 2986–2988、
/// 行 4381–4383，含两端）。`prand` 是任意 u32；`base` 为 0 返回 0。
pub fn randomReachable(base: u32, prand: u32) u32 {
    if (base == 0) return 0;
    const span: u64 = reachable_factor_max_fp16 - reachable_factor_min_fp16 + 1;
    const f: u64 = reachable_factor_min_fp16 + (prand % span);
    return @intCast((@as(u64, base) * f) >> 16);
}

/// SLAAC 助手（RFC 4862 §5.5.3 行 2140 起）：前缀 + IID 拼出地址。M 旗标置位时
/// 本助手不适用（DHCPv6，§5.4.1 行 1285–1289，明确不做）。
pub fn formAddress(prefix: [16]u8, iid: [8]u8) [16]u8 {
    var a = prefix;
    a[8..16].* = iid;
    return a;
}
