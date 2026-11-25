//! wifi-mlme：GAS（Generic Advertisement Service）——四种 Public Action 帧的编解码、
//! Advertisement Protocol 元素（9.4.2.93）、ANQP 元素（9.4.5）与 STA（请求方）一侧的
//! 查询流程状态机（11.25.3.2）。纯逻辑：字节 ↔ 结构、时间注入，不碰射频、不分配堆。
//!
//! 对应原文（行号是 `/tmp/spec/802.11-2016.txt` 的原文行；页码为印刷页码 = `=== PAGE N ===` 的 N−1）：
//!
//!   * 9.6.8.1 / Table 9-307（62848，p.1177–1178）：Public Action 值——GAS Initial Request 10、
//!     Initial Response 11、Comeback Request 12、Comeback Response 13；Category = 4（Table 9-47，
//!     p.736；盘上 hostap `ieee802_11_defs.h:293` WLAN_ACTION_PUBLIC = 4、:304–307 WLAN_PA_GAS_*）。
//!   * 9.6.8.12 / Table 9-313（63241，p.1186）：GAS Initial Request = Category + Public Action +
//!     Dialog Token + Advertisement Protocol 元素 + Query Request Length(2) + Query Request +
//!     Multi-band(可选)；Figure 9-666/9-667（p.1187）：Query Request Length 2 字节。
//!   * 9.6.8.13 / Table 9-314（63275，p.1187）：GAS Initial Response 追加 Status Code、
//!     GAS Comeback Delay(2)、Query Response Length(2)、Query Response(可选)；Figure 9-668（p.1188）：
//!     Comeback Delay 2 字节（TU）；「The value 0 will be returned … when a Query Response is
//!     provided in this frame」。
//!   * 9.6.8.14 / Table 9-315（63320，p.1188）：GAS Comeback Request = Category + Public Action +
//!     Dialog Token + Multi-band(可选)。
//!   * 9.6.8.15 / Table 9-316（63346，p.1189）：GAS Comeback Response 再加 GAS Query Response
//!     Fragment ID；9.4.1.34 / Figure 9-104（42184，p.756）：B0–B6 Fragment ID（最大 127）、
//!     B7 More GAS Fragments。
//!   * 9.4.1.12（41357，p.738）：Dialog Token 1 字节（GAS 的请求帧原文没有要求非 0，
//!     与 9.6.7.2 的 Radio Measurement 不同——所以这里没有 ZeroDialogToken）。
//!   * 9.4.2.93 / Figure 9-441–9-443、Table 9-215（55183，p.1019–1022）：Advertisement Protocol
//!     元素（Element ID 108，见 Table 9-26 一带，原文行 43807）；Tuple = Query Response Info
//!     （B0–B6 Length Limit，256 字节单位，0 不允许；B7 PAME-BI）+ Advertisement Protocol ID
//!     （0 ANQP、1 MIH IS、2 MIH 命令/事件发现、3 EAS、4 RLQP、5–220 保留、221 厂商专用、
//!     222–255 保留）；GAS 帧里的元素「includes exactly one Advertisement Protocol ID」。
//!   * 方向规则（9.4.2.93 + 9.2.4.1，p.637）：Query Response Length Limit 在请求方 → 响应方
//!     的发送里保留（55225）、PAME-BI 对非 AP STA 保留（55231）、保留位发送置 0（36052）——
//!     `buildInitialRequest` / `Machine.start` 恒按 0 编码、非 0 拒绝；Query Response Length
//!     Limit = 0 在响应帧里不被允许（55222「A value of 0 is not permitted.」）——
//!     `buildInitialResponse` / `buildComebackResponse` 拒绝 0。
//!   * 11.25.3.2.2（95115，p.1828–1829）：请求 STA 发 Initial Request、启动
//!     dot11GASResponseTimer、等 Dialog Token 相同的 Initial Response、超时 → GAS_QUERY_TIMEOUT。
//!   * 11.25.3.2.4（95213，p.1830–1832）：响应方的 comeback / 分片规则，以及请求方一侧
//!     （p.1832，原文行 95326–95363）：Comeback Delay 过期立即发 Comeback Request；
//!     95 → 等 delay 再来；SUCCESS + More=1 → 立即再发一个 Comeback Request；SUCCESS + More=0
//!     → 校验 0..Fragment ID 的片都到齐；每个 Comeback Response 到达都重置 dot11GASResponseTimer；
//!     62 / 63 → 按码终止；61 → 按码终止。
//!   * 9.4.5.1 / Figure 9-591、Table 9-271（60649，p.1127–1128）：ANQP 元素 = Info ID(2) +
//!     Length(2) + Information，多字节数值按 9.2.2（p.636）小端；Info ID：Query List 256、
//!     Capability List 257、Venue Name 258、Network Authentication Type 260、Roaming Consortium 261、
//!     IP Address Type Availability 262、NAI Realm 263、3GPP Cellular Network 264（9.4.5.11，
//!     原文行 61127）、Domain Name 268、Venue URL 277、Vendor Specific 56797。
//!   * Query List（9.4.5.2，60696，p.1128）：2 字节 Info ID 列表，「ordered by monotonically
//!     increasing Info ID value」；Capability List（9.4.5.3，60707，p.1128–1129）：Info ID 列表 +
//!     尾部可带 Vendor Specific ANQP 元素，「ordered by nondecreasing」（与 Query List 的措辞不同）；
//!     11.25.3.3.2（95472）：收到未知 / 保留 Info ID 忽之继续解析。
//!   * Emergency Call Number（9.4.5.5，60783，Figure 9-596/9-597，p.1130）：零或多个 Duple
//!     （Emergency Call Number Length(1) + UTF-8 号码）；与 Domain Name Duple 同族。
//!   * Venue Name（9.4.5.4，60744，Figure 9-594/9-595，p.1129–1130）：Venue Info(2) + 零或多个
//!     Tuple（Length = 3 + 名字；语言码 3 字节；名字 UTF-8 ≤ 252 字节）；9.4.1.35（42224）：
//!     Venue Info = Venue Group + Venue Type 各 1 字节。
//!   * Network Authentication Type（9.4.5.6，60790，Figure 9-598/9-599、Table 9-272，p.1130–1132）：
//!     Indicator(1) + Redirect URL Length(2) + URL(可选)——「When the Network Authentication Type
//!     Indicator is 1, the Redirect URL Length is set to 0 and the Redirect URL is not present」
//!     （3 同）；仅 0 / 2 可以带 URL；4–255 保留。
//!   * Roaming Consortium（9.4.5.7，60863，Figure 9-600/9-601，p.1132–1133）：零或多个 OI Duple
//!     （OI Length(1) + OI）；11.25.3.3.3（95479）：OI 列表来自 dot11RoamingConsortiumTable。
//!   * IP Address Type Availability（9.4.5.9，60899，Figure 9-603/9-604、Table 9-273/9-274，
//!     p.1133–1134）：1 字节：B0–B1 IPv6（0 无、1 有、2 未知、3 保留），B2–B7 IPv4
//!     （0 无 … 7 未知、8–63 保留）。
//!   * NAI Realm（9.4.5.10，60929，Figure 9-605–9-609、Table 9-275，p.1134–1138）：Count(2) +
//!     每域 Tuple（Data Field Length(2) = 3 + realm + EAP 方法串、Encoding(1)（B0 编码类型、
//!     B1–B7 保留）、Realm Length(1)、Realm、EAP Method Count(1)、EAP 方法（Length(1) = 2 + 参数、
//!     EAP Method(1)、Auth Parameter Count(1)、参数（ID(1) + Length(1) + 值））。
//!   * Domain Name（9.4.5.15，61166，Figure 9-614/9-615，p.1139–1140）：零或多个 Duple
//!     （Length(1) + 名字，名字 ≤ 255 字节）；Venue URL（9.4.5.20，61240，Figure 9-620/9-621，
//!     p.1141–1142）：一或多个 Duple（Length(1) = 1 + URL、Venue Number(1)、URL）。
//!
//! 与独立实现的差异 / 盘上证据：
//!   * 盘上 hostap 是裁剪版：`common/gas.c` 与 `anqp.c` 都不在，ANQP/GAS 帧体没有可对拍的
//!     独立实现；差分用 `/tmp/s31-oracle/gas/` 的 Python oracle（同一份规范排字节的模型），
//!     其性质是「照同一份策略写的模型」对拍，不是独立实现互证。
//!   * `ieee802_11_defs.h` 只剩常量：Category 4、Action 10–13、状态码 59/60/61/62/63/95
//!     （:151–155、:166、:293、:304–307）与本实现一致。
//!   * Status Code 字段是 2 字节小端：Table 9-314 / 9-316 的字段表没有 Octets 行，但表下写的是
//!     「The Status Code values are defined in Table 9-46」，Status Code 字段本身在 9.4.1.9
//!     （行 40953–40956，p.731）定义——「The length of the Status Code field is 2 octets」。所以宽度
//!     是原文规定的，不是按实现惯例定的。盘上同平台的 esp-idf
//!     `esp_supplicant/src/esp_dpp.c:1062–1063` 也用 `WPA_GET_LE16` 读 status_code 与
//!     comeback_delay，`:1367` 的 `frm_len >= 9` 守卫只在该布局下成立；
//!     `ieee802_11_defs.h:405–410` 的 `struct ieee80211_gas_resp` 同布局。
//!     [INFERENCE] hostap 上游按 1 字节读 status code 的说法在本机没有可引用的源文件（`gas.c`
//!     被裁剪），只作为互操作风险记下：遇到按 1 字节布局回帧的对端时状态字节会错位，
//!     本实现按未定义码处理。
//!   * Multi-band 元素（可选尾随）本模块不解释：解析时原样保留在 `multiband` 里以便往返，
//!     构造时原样写回（11.25.3.2.4：带 Multi-band 的请求后续帧都要带着同一份）。
//!
//! 明确不做：Annex R（Hotspot 2.0 厂商扩展）、RLQP（11.25.3.4）、GAS 与多 BSSID 集合
//! （11.25.3.2.5）、Advertisement Server / 响应方一侧的查询代理（11.25.3.2.3 的服务器侧——
//! 模块只提供响应帧的编解码原语，不做查询代理流程）、Protected Dual of Public Action、
//! Multi-band 元素的编解码、Vendor Specific Advertisement Protocol（ID 221）、
//! ANQP Vendor Specific 元素（56797）的内容解析（只在 Capability List 里跳过）、
//! 3GPP Cellular Network（264）与其余未列元素的解码（RAW 透传）。
//!
//! 请求方状态机（11.25.3.2.2 / 11.25.3.2.4 尾部）的两个实现取舍：
//!   * 重复 Fragment ID（< 已收上限）：忽略整帧——不追加、不重置计时器。原文没有定义重复片
//!     的处理；若照「每个 Comeback Response 都重置计时器」字面执行，一个只会重发旧片的响应方
//!     可以无限续命，所以这里不算「receipt」。
//!   * SUCCESS + More=0 但有缺片：不再发请求（原文只在 More=1 时要求再发），留在取片状态，
//!     等 dot11GASResponseTimer 过期报 GAS_QUERY_TIMEOUT。
//!   * 响应存储（调用方给的 `response_buf`）装不下：按 63 GAS_QUERY_RESPONSE_TOO_LARGE 终止
//!     ——原文把「响应超出限制」都映射到这个码（11.25.3.2.4），STA 侧存储耗尽原文没有定义。
//!
//! 比特编号沿用 9.2.2（p.636）：多字节数值低字节在前；Multi-byte 字段的位 0 在第一字节。

const std = @import("std");
const frame = @import("frame.zig");

// ---------------------------------------------------------------------------
// 1) 常量与错误集
// ---------------------------------------------------------------------------

/// Public Action 的 Category（Table 9-47，p.736；hostap `ieee802_11_defs.h:293`）。
pub const category_public: u8 = 4;

/// Advertisement Protocol 元素的 Element ID（Table 9-26 一带，原文行 43807：ID 108）。
pub const adv_proto_element_id: u8 = 108;

/// Table 9-307（62848，p.1177）的四个 GAS Public Action 值。
pub const Action = enum(u8) {
    initial_request = 10,
    initial_response = 11,
    comeback_request = 12,
    comeback_response = 13,
    _,
};

/// Table 9-215（p.1021–1022）的 Advertisement Protocol ID。
pub const AdvertisementProtocol = enum(u8) {
    anqp = 0,
    mih_information_service = 1,
    mih_command_event_discovery = 2,
    emergency_alert_system = 3,
    rlqp = 4,
    vendor_specific = 221,
    _,
};

/// Table 9-46（p.734–735）里 GAS 有关的状态码 + 成功。非穷举：未知码原样携带；
/// 底层取 u16 以容纳 2 字节状态码字段的任意值（表内定义值都 ≤ 255）。
pub const ResultCode = enum(u16) {
    success = 0,
    /// 59 GAS_ADVERTISEMENT_PROTOCOL_NOT_SUPPORTED（41146，p.734）。
    advertisement_protocol_not_supported = 59,
    /// 60 NO_OUTSTANDING_GAS_REQUEST（41146，p.734）。
    no_outstanding_gas_request = 60,
    /// 61 GAS_RESPONSE_NOT_RECEIVED_FROM_SERVER（41153，p.734）。
    response_not_received_from_server = 61,
    /// 62 GAS_QUERY_TIMEOUT（41153，p.734）。
    query_timeout = 62,
    /// 63 GAS_QUERY_RESPONSE_TOO_LARGE（41156，p.734）。
    response_too_large = 63,
    /// 65 SERVER_UNREACHABLE（41161，p.734）。
    server_unreachable = 65,
    /// 95 QUERY_RESPONSE_OUTSTANDING（41230，p.735）。
    query_response_outstanding = 95,
    _,
};

pub const Error = error{
    /// 字节不够（固定字段、元素头、长度声明的内容被截断）。
    Truncated,
    /// 超出有界表 / 1 字节长度域装不下 / 16 位长度域装不下。
    TooLong,
    /// 输出缓冲不够。
    NoRoom,
    /// 不是 Public Action 的 Category。
    BadCategory,
    /// 不是 GAS 的四个 Action 值（或帧分流错了）。
    BadAction,
    /// 不是 Advertisement Protocol 元素（Element ID 对不上）。
    BadElement,
    /// 长度字段与实际布局对不上（元素长度 ≠ 2、元组长度声明自相矛盾、尾随多余字节）。
    BadLength,
    /// 自相矛盾：Indicator 与 URL 并存、SUCCESS 既无响应又无 delay、Venue URL 没有元组。
    BadValue,
    /// 构造侧拒绝保留值（Indicator 4–255、IPv6=3、IPv4 8–63、NAI Encoding B1–B7）。
    ReservedValue,
    /// 厂商专用 Advertisement Protocol（221）不在本模块范围。
    UnsupportedProtocol,
    /// 状态机在当前状态不该收到这帧（或已终止还在收）。
    WrongState,
};

fn le16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

fn w16(out: []u8, v: u16) void {
    std.mem.writeInt(u16, out[0..2], v, .little);
}

/// TU 计时（u32 回绕安全）：now 已到或越过 at。
fn dueOrPast(now_tu: u32, at_tu: u32) bool {
    return @as(i32, @bitCast(now_tu -% at_tu)) >= 0;
}

// ---------------------------------------------------------------------------
// 2) Advertisement Protocol 元素（9.4.2.93）
// ---------------------------------------------------------------------------

/// 一个 Advertisement Protocol Tuple（Figure 9-442 / 9-443）。GAS 帧里恰好一个非厂商 ID，
/// 所以元素定长 4 字节。
pub const AdvProto = struct {
    protocol: AdvertisementProtocol,
    /// Query Response Info 的 B7：响应与 BSSID 无关。非 AP STA 保留（9.4.2.93）。
    pame_bi: bool = false,
    /// Query Response Info 的 B0–B6：Query Response Length Limit，256 字节单位，
    /// 响应方发的帧里 0 不允许、0x7F = 最大；请求方的帧里保留（置 0）。
    length_limit_units: u7 = 0,
};

pub fn buildAdvProtoElement(out: []u8, adv: AdvProto) Error!usize {
    if (adv.protocol == .vendor_specific) return error.UnsupportedProtocol;
    if (out.len < 4) return error.NoRoom;
    out[0] = adv_proto_element_id;
    out[1] = 2;
    out[2] = @as(u8, if (adv.pame_bi) 0x80 else 0) | @as(u8, adv.length_limit_units);
    out[3] = @backingInt(adv.protocol);
    return 4;
}

/// 解析一个独立的 Advertisement Protocol 元素（id + length + 恰好一个 Tuple）。
pub fn parseAdvProtoElement(element: []const u8) Error!AdvProto {
    const adv = try parseAdvProtoAt(element, 0);
    if (adv.next != element.len) return error.BadLength;
    return adv.adv;
}

/// 从帧内 `off` 起解析一个 Advertisement Protocol 元素（Element ID + Length + 一个 Tuple）。
/// 返回元组与下一偏移。
fn parseAdvProtoAt(field: []const u8, off: usize) Error!struct { adv: AdvProto, next: usize } {
    if (field.len < off + 2) return error.Truncated;
    if (field[off] != adv_proto_element_id) return error.BadElement;
    const l: usize = field[off + 1];
    if (field.len < off + 2 + l) return error.Truncated;
    if (l < 2) return error.BadLength;
    const protocol: u8 = field[off + 3];
    if (protocol == @backingInt(AdvertisementProtocol.vendor_specific)) return error.UnsupportedProtocol;
    if (l != 2) return error.BadLength; // GAS 帧里恰好一个协议 ID；多 Tuple / 厂商格式不做
    const info_byte = field[off + 2];
    return .{
        .adv = .{
            .protocol = @fromBackingInt(@intCast(protocol)),
            .pame_bi = (info_byte & 0x80) != 0,
            .length_limit_units = @truncate(info_byte & 0x7f),
        },
        .next = off + 2 + l,
    };
}

// ---------------------------------------------------------------------------
// 3) ANQP 通用格式（9.4.5.1）
// ---------------------------------------------------------------------------

/// Table 9-271（p.1127–1128）里本模块相关的 Info ID。
pub const InfoId = enum(u16) {
    query_list = 256,
    capability_list = 257,
    venue_name = 258,
    emergency_call_number = 259,
    network_authentication_type = 260,
    roaming_consortium = 261,
    ip_address_type_availability = 262,
    nai_realm = 263,
    cellular_network = 264,
    domain_name = 268,
    venue_url = 277,
    vendor_specific = 56797,
    _,
};

/// 一个 ANQP 元素：Info ID(2 LE) + Length(2 LE) + Information（Figure 9-591）。
pub const AnqpElement = struct { info_id: u16, info: []const u8 };

/// 逐个走 ANQP 元素；不认识的 Info ID 原样交出（11.25.3.3.1：未知 / 保留 ID 忽之继续）。
pub const AnqpIter = struct {
    rest: []const u8,

    pub fn next(self: *AnqpIter) Error!?AnqpElement {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 4) return error.Truncated;
        const id = le16(self.rest[0..2]);
        const len: usize = le16(self.rest[2..4]);
        if (self.rest.len < 4 + len) return error.Truncated;
        const info = self.rest[4..][0..len];
        self.rest = self.rest[4 + len ..];
        return .{ .info_id = id, .info = info };
    }
};

pub fn buildAnqpElement(out: []u8, info_id: u16, info: []const u8) Error!usize {
    if (info.len > 65535) return error.TooLong;
    const total = 4 + info.len;
    if (out.len < total) return error.NoRoom;
    w16(out[0..2], info_id);
    w16(out[2..4], @intCast(info.len));
    @memcpy(out[4..][0..info.len], info);
    return total;
}

// ---------------------------------------------------------------------------
// 4) Query List / Capability List（9.4.5.2 / 9.4.5.3）
// ---------------------------------------------------------------------------

/// 构造 Query List ANQP 元素：Info ID 列表。9.4.5.2：「ordered by monotonically increasing
/// Info ID value」——严格递增，乱序 / 重复拒绝。
pub fn buildQueryList(out: []u8, ids: []const u16) Error!usize {
    // 9.4.5.2（60701）：「The ANQP Query IDs field contains one or more 2-octet ANQP
    // Query ID subfields.」——空列表两侧都拒绝。
    if (ids.len == 0) return error.BadValue;
    for (ids, 0..) |id, i| {
        if (i > 0 and ids[i - 1] >= id) return error.BadValue;
    }
    if (ids.len * 2 > 65535) return error.TooLong;
    const total = 4 + ids.len * 2;
    if (out.len < total) return error.NoRoom;
    w16(out[0..2], @backingInt(InfoId.query_list));
    w16(out[2..4], @intCast(ids.len * 2));
    for (ids, 0..) |id, i| w16(out[4 + i * 2 ..][0..2], id);
    return total;
}

/// 解析 Query List 的 Information 字段（不含元素头），拷进调用方的表。
pub fn parseQueryList(info: []const u8, out: []u16) Error!usize {
    if (info.len == 0) return error.BadValue; // 「one or more」（60701）
    if (info.len % 2 != 0) return error.Truncated;
    if (info.len / 2 > out.len) return error.TooLong;
    for (0..info.len / 2) |i| out[i] = le16(info[i * 2 ..][0..2]);
    return info.len / 2;
}

/// 解析 Capability List 的 Information 字段：Info ID 列表，遇到 Vendor Specific（56797，
/// Table 9-271）即停——其后是一个或多个 Vendor Specific ANQP 元素，本模块跳过。
/// 9.4.5.3 只说「ordered by nondecreasing」，解析不查序。
pub fn parseCapabilityList(info: []const u8, out: []u16) Error!usize {
    var pos: usize = 0;
    var got: usize = 0;
    while (pos + 2 <= info.len) {
        const id = le16(info[pos..][0..2]);
        if (id == @backingInt(InfoId.vendor_specific)) return got;
        if (got == out.len) return error.TooLong;
        out[got] = id;
        got += 1;
        pos += 2;
    }
    if (pos != info.len) return error.Truncated; // 尾半个 2 字节 ID
    return got;
}

// ---------------------------------------------------------------------------
// 5) Venue Name / Domain Name（9.4.5.4 / 9.4.5.15）
// ---------------------------------------------------------------------------

/// Venue Name 元素里的一个 Tuple（Figure 9-595）：Length(1) = 3 + 名字、语言码(3)、名字。
pub const VenueNameTuple = struct { language: [3]u8, name: []const u8 };

pub const VenueName = struct {
    /// 9.4.1.35：Venue Group + Venue Type 各 1 字节。
    venue_info: u16,
    tuples: []const VenueNameTuple,
};

/// 名字的上限（9.4.5.4：「The maximum length of this field is 252 octets」）。
pub const venue_name_max: usize = 252;

/// 元素可带零或多个 Tuple（「zero or more venue names」）；Information 至少要有 Venue Info。
pub fn parseVenueName(info: []const u8, out: []VenueNameTuple) Error!VenueName {
    if (info.len < 2) return error.Truncated;
    var pos: usize = 2;
    var got: usize = 0;
    while (pos < info.len) {
        const l: usize = info[pos];
        if (info.len < pos + 1 + l) return error.Truncated;
        if (l < 3) return error.BadLength; // Length = 3 + 名字
        if (got == out.len) return error.TooLong;
        out[got] = .{
            .language = info[pos + 1 ..][0..3].*,
            .name = info[pos + 4 ..][0 .. l - 3],
        };
        got += 1;
        pos += 1 + l;
    }
    return .{ .venue_info = le16(info[0..2]), .tuples = out[0..got] };
}

pub fn buildVenueName(out: []u8, venue_info: u16, tuples: []const VenueNameTuple) Error!usize {
    var total: usize = 2;
    for (tuples) |t| {
        if (t.name.len > venue_name_max) return error.TooLong;
        total += 1 + 3 + t.name.len;
    }
    if (total > 65535) return error.TooLong;
    if (out.len < total) return error.NoRoom;
    w16(out[0..2], venue_info);
    var pos: usize = 2;
    for (tuples) |t| {
        out[pos] = @intCast(3 + t.name.len);
        out[pos + 1 ..][0..3].* = t.language;
        @memcpy(out[pos + 4 ..][0..t.name.len], t.name);
        pos += 4 + t.name.len;
    }
    return total;
}

/// Emergency Call Number 元素里的一个 Duple（Figure 9-597）：Length(1) = 号码字节数、
/// 号码（UTF-8 变长）。「zero or more」——空列表合法（9.4.5.5，60787）。
pub const EmergencyCallNumberDuple = struct { number: []const u8 };

pub fn parseEmergencyCallNumber(info: []const u8, out: []EmergencyCallNumberDuple) Error!usize {
    var pos: usize = 0;
    var got: usize = 0;
    while (pos < info.len) {
        const l: usize = info[pos];
        if (info.len < pos + 1 + l) return error.Truncated;
        if (got == out.len) return error.TooLong;
        out[got] = .{ .number = info[pos + 1 ..][0..l] };
        got += 1;
        pos += 1 + l;
    }
    return got;
}

pub fn buildEmergencyCallNumber(out: []u8, duples: []const EmergencyCallNumberDuple) Error!usize {
    var total: usize = 0;
    for (duples) |d| {
        if (d.number.len > 255) return error.TooLong; // 1 字节长度域
        total += 1 + d.number.len;
    }
    if (out.len < total) return error.NoRoom;
    var pos: usize = 0;
    for (duples) |d| {
        out[pos] = @intCast(d.number.len);
        @memcpy(out[pos + 1 ..][0..d.number.len], d.number);
        pos += 1 + d.number.len;
    }
    return total;
}

/// Domain Name 元素里的一个 Duple（Figure 9-615）：Length(1) + 名字（≤ 255 字节）。
/// 「zero or more」——空列表合法（9.4.5.15）。
pub const DomainNameDuple = struct { name: []const u8 };

pub fn parseDomainName(info: []const u8, out: []DomainNameDuple) Error!usize {
    var pos: usize = 0;
    var got: usize = 0;
    while (pos < info.len) {
        const l: usize = info[pos];
        if (info.len < pos + 1 + l) return error.Truncated;
        if (got == out.len) return error.TooLong;
        out[got] = .{ .name = info[pos + 1 ..][0..l] };
        got += 1;
        pos += 1 + l;
    }
    return got;
}

pub fn buildDomainName(out: []u8, names: []const DomainNameDuple) Error!usize {
    var total: usize = 0;
    for (names) |d| {
        if (d.name.len > 255) return error.TooLong; // 9.4.5.15：最大 255 字节（1 字节长度域）
        total += 1 + d.name.len;
    }
    if (out.len < total) return error.NoRoom;
    var pos: usize = 0;
    for (names) |d| {
        out[pos] = @intCast(d.name.len);
        @memcpy(out[pos + 1 ..][0..d.name.len], d.name);
        pos += 1 + d.name.len;
    }
    return total;
}

// ---------------------------------------------------------------------------
// 6) Network Authentication Type（9.4.5.6）
// ---------------------------------------------------------------------------

/// Table 9-272：0 条款接受、1 在线注册、2 http/https 重定向、3 DNS 重定向、4–255 保留。
pub const NetworkAuthTypeTuple = struct { indicator: u8, redirect_url: []const u8 };

/// Indicator 1 / 3 时 URL 长度必须为 0（9.4.5.6 原文「is set to 0 and the Redirect URL is
/// not present」）；URL 只允许跟在 0 / 2 后面。保留值（4–255）解析时原样保留。
pub fn parseNetworkAuthType(info: []const u8, out: []NetworkAuthTypeTuple) Error!usize {
    var pos: usize = 0;
    var got: usize = 0;
    while (pos < info.len) {
        if (info.len < pos + 3) return error.Truncated; // Indicator(1) + URL Length(2)
        const indicator = info[pos];
        const url_len: usize = le16(info[pos + 1 ..][0..2]);
        if (info.len < pos + 3 + url_len) return error.Truncated;
        if ((indicator == 1 or indicator == 3) and url_len != 0) return error.BadValue;
        if (got == out.len) return error.TooLong;
        out[got] = .{
            .indicator = indicator,
            .redirect_url = info[pos + 3 ..][0..url_len],
        };
        got += 1;
        pos += 3 + url_len;
    }
    return got;
}

pub fn buildNetworkAuthType(out: []u8, tuples: []const NetworkAuthTypeTuple) Error!usize {
    var total: usize = 0;
    for (tuples) |t| {
        if (t.indicator > 3) return error.ReservedValue; // Table 9-272：4–255 保留
        if ((t.indicator == 1 or t.indicator == 3) and t.redirect_url.len != 0) return error.BadValue;
        if (t.redirect_url.len > 65535) return error.TooLong;
        total += 3 + t.redirect_url.len;
    }
    if (out.len < total) return error.NoRoom;
    var pos: usize = 0;
    for (tuples) |t| {
        out[pos] = t.indicator;
        w16(out[pos + 1 ..][0..2], @intCast(t.redirect_url.len));
        @memcpy(out[pos + 3 ..][0..t.redirect_url.len], t.redirect_url);
        pos += 3 + t.redirect_url.len;
    }
    return total;
}

// ---------------------------------------------------------------------------
// 7) Roaming Consortium（9.4.5.7）
// ---------------------------------------------------------------------------

/// 一个 OI Duple（Figure 9-601）：OI Length(1) + OI。OI 的取值范围由
/// dot11RoamingConsortiumTable 给出（11.25.3.3.3），这里不校验。
pub const OiDuple = struct { oi: []const u8 };

pub fn parseRoamingConsortium(info: []const u8, out: []OiDuple) Error!usize {
    var pos: usize = 0;
    var got: usize = 0;
    while (pos < info.len) {
        const l: usize = info[pos];
        if (info.len < pos + 1 + l) return error.Truncated;
        if (got == out.len) return error.TooLong;
        out[got] = .{ .oi = info[pos + 1 ..][0..l] };
        got += 1;
        pos += 1 + l;
    }
    return got;
}

pub fn buildRoamingConsortium(out: []u8, ois: []const OiDuple) Error!usize {
    var total: usize = 0;
    for (ois) |d| {
        if (d.oi.len > 255) return error.TooLong;
        total += 1 + d.oi.len;
    }
    if (out.len < total) return error.NoRoom;
    var pos: usize = 0;
    for (ois) |d| {
        out[pos] = @intCast(d.oi.len);
        @memcpy(out[pos + 1 ..][0..d.oi.len], d.oi);
        pos += 1 + d.oi.len;
    }
    return total;
}

// ---------------------------------------------------------------------------
// 8) IP Address Type Availability（9.4.5.9）
// ---------------------------------------------------------------------------

/// Table 9-273：IPv6 地址可用性（B0–B1）。
pub const Ip6Availability = enum(u2) {
    not_available = 0,
    available = 1,
    not_known = 2,
    reserved = 3,
};

/// Table 9-274：IPv4 地址可用性（B2–B7 的 0–7；8–63 保留，解析时用 null 表达）。
pub const Ip4Availability = enum(u8) {
    not_available = 0,
    public = 1,
    port_restricted = 2,
    single_nat = 3,
    double_nat = 4,
    port_restricted_single_nat = 5,
    port_restricted_double_nat = 6,
    not_known = 7,
};

pub const IpAddressType = struct {
    /// 元素的那 1 个字节（Figure 9-604）。
    raw: u8,

    pub fn ipv6Value(self: IpAddressType) u2 {
        return @truncate(self.raw);
    }

    pub fn ipv4Value(self: IpAddressType) u8 {
        return self.raw >> 2;
    }

    pub fn ipv6(self: IpAddressType) Ip6Availability {
        return @fromBackingInt(@intCast(self.ipv6Value()));
    }

    /// 8–63 保留（Table 9-274）→ null。
    pub fn ipv4(self: IpAddressType) ?Ip4Availability {
        const v = self.ipv4Value();
        return if (v <= 7) @fromBackingInt(@intCast(v)) else null;
    }
};

/// Information 恰好 1 字节（Figure 9-603）；多余 / 少于 1 字节都拒绝。
pub fn parseIpAddressTypeAvailability(info: []const u8) Error!IpAddressType {
    if (info.len != 1) return error.BadLength;
    return .{ .raw = info[0] };
}

pub fn buildIpAddressTypeAvailability(out: []u8, ipv6_avail: u2, ipv4_avail: u6) Error!usize {
    if (ipv6_avail == @backingInt(Ip6Availability.reserved)) return error.ReservedValue;
    if (ipv4_avail > 7) return error.ReservedValue; // Table 9-274：8–63 保留
    if (out.len < 1) return error.NoRoom;
    out[0] = (@as(u8, ipv4_avail) << 2) | ipv6_avail;
    return 1;
}

// ---------------------------------------------------------------------------
// 9) NAI Realm（9.4.5.10）
// ---------------------------------------------------------------------------

/// 一个 NAI Realm（Figure 9-606 的可读部分）。EAP 方法链只做结构校验
/// （每条 Length = 2 + 参数；Data Field Length = 3 + realm + EAP 串）。
pub const NaiRealm = struct {
    /// Figure 9-607：B0 编码类型（0 RFC 4282、1 UTF-8），B1–B7 保留——原样保留。
    encoding: u8,
    realm: []const u8,
};

pub const AuthParamSpec = struct { id: u8, value: []const u8 };
pub const EapMethodSpec = struct { eap_type: u8, params: []const AuthParamSpec = &.{} };
pub const NaiRealmSpec = struct {
    /// 构造只接受 0 / 1（B1–B7 保留置 0）。
    encoding: u8,
    realm: []const u8,
    eap: []const EapMethodSpec = &.{},
};

/// 解析 NAI Realm 元素的 Information 字段：Count(2) + 逐域 Tuple。
/// 结构错误（长度链对不上、域数与 Count 不符、尾随字节）都拒绝。
pub fn parseNaiRealm(info: []const u8, out: []NaiRealm) Error!usize {
    if (info.len < 2) return error.Truncated;
    const count: usize = le16(info[0..2]);
    var pos: usize = 2;
    var got: usize = 0;
    for (0..count) |_| {
        if (info.len < pos + 4) return error.Truncated; // Data Len(2) + Enc(1) + RLen(1)
        const data_len: usize = le16(info[pos..][0..2]);
        const encoding = info[pos + 2];
        const realm_len: usize = info[pos + 3];
        pos += 4;
        // Figure 9-606 的顺序：Data Len、Encoding、Realm Length、Realm、EAP Method Count、EAP
        if (info.len < pos + realm_len + 1) return error.Truncated;
        const realm = info[pos..][0..realm_len];
        pos += realm_len;
        const eap_count: usize = info[pos];
        pos += 1;
        // EAP 方法链：每条 [Length(1) = 2 + 参数、EAP Method(1)、Param Count(1)、参数…]
        var eap_bytes: usize = 0;
        for (0..eap_count) |_| {
            if (info.len < pos + 3) return error.Truncated;
            const eap_len: usize = info[pos];
            const param_count: usize = info[pos + 2];
            if (eap_len < 2) return error.BadLength;
            const eap_end = pos + 1 + eap_len;
            if (info.len < eap_end) return error.Truncated;
            var p = pos + 3;
            for (0..param_count) |_| {
                if (eap_end < p + 2) return error.BadLength;
                const vlen: usize = info[p + 1];
                if (eap_end < p + 2 + vlen) return error.BadLength;
                p += 2 + vlen;
            }
            if (p != eap_end) return error.BadLength; // Length ≠ 2 + 参数
            eap_bytes += 1 + eap_len;
            pos = eap_end;
        }
        // 9.4.5.10：「value is equal to 3 plus the length of the NAI Realm subfield plus
        // the sum of the lengths of the EAP Method subfields」
        if (data_len != 3 + realm_len + eap_bytes) return error.BadLength;
        if (got == out.len) return error.TooLong;
        out[got] = .{ .encoding = encoding, .realm = realm };
        got += 1;
    }
    if (pos != info.len) return error.BadLength; // 域数少于 Count 之后的尾随字节
    return got;
}

pub fn buildNaiRealm(out: []u8, realms: []const NaiRealmSpec) Error!usize {
    if (realms.len > 65535) return error.TooLong;
    // 长度预算一遍过，再写。
    var total: usize = 2;
    for (realms) |r| {
        if (r.encoding > 1) return error.ReservedValue; // Figure 9-607：B0 之外保留
        if (r.realm.len > 255) return error.TooLong; // 9.4.5.10：最大 255 字节
        var eap_bytes: usize = 0;
        for (r.eap) |e| {
            var params_len: usize = 0;
            for (e.params) |p| {
                if (p.value.len > 255) return error.TooLong;
                params_len += 2 + p.value.len;
            }
            const eap_len = 2 + params_len;
            if (eap_len > 255) return error.TooLong;
            eap_bytes += 1 + eap_len;
        }
        const data_len = 3 + r.realm.len + eap_bytes;
        if (data_len > 65535) return error.TooLong;
        total += 2 + data_len;
    }
    if (out.len < total) return error.NoRoom;
    w16(out[0..2], @intCast(realms.len));
    var pos: usize = 2;
    for (realms) |r| {
        const tuple_at = pos;
        pos += 2;
        out[pos] = r.encoding;
        out[pos + 1] = @intCast(r.realm.len);
        pos += 2;
        @memcpy(out[pos..][0..r.realm.len], r.realm);
        pos += r.realm.len;
        out[pos] = @intCast(r.eap.len);
        pos += 1;
        for (r.eap) |e| {
            var params_len: usize = 0;
            for (e.params) |p| params_len += 2 + p.value.len;
            const eap_len: u8 = @intCast(2 + params_len);
            out[pos] = eap_len;
            out[pos + 1] = e.eap_type;
            out[pos + 2] = @intCast(e.params.len);
            pos += 3;
            for (e.params) |p| {
                out[pos] = p.id;
                out[pos + 1] = @intCast(p.value.len);
                @memcpy(out[pos + 2 ..][0..p.value.len], p.value);
                pos += 2 + p.value.len;
            }
        }
        const data_len: u16 = @intCast(pos - tuple_at - 2);
        w16(out[tuple_at..][0..2], data_len);
    }
    return total;
}

// ---------------------------------------------------------------------------
// 10) Venue URL（9.4.5.20）
// ---------------------------------------------------------------------------

/// 一个 Venue URL Duple（Figure 9-621）：Length(1) = 1 + URL、Venue Number(1)、URL
/// （URL 可为空：「If no Venue URL is provided this field is left empty」）。
pub const VenueUrlDuple = struct { venue_number: u8, url: []const u8 };

/// 「The Venue URL Duples field contains one or more Venue URL Duple fields」——空列表拒绝。
pub fn parseVenueUrl(info: []const u8, out: []VenueUrlDuple) Error!usize {
    if (info.len == 0) return error.BadValue; // 「contains one or more Venue URL Duple fields」
    var pos: usize = 0;
    var got: usize = 0;
    while (pos < info.len) {
        const l: usize = info[pos];
        if (l < 1) return error.BadLength; // Length = 1 + URL，至少要有 Venue Number
        if (info.len < pos + 1 + l) return error.Truncated;
        if (got == out.len) return error.TooLong;
        out[got] = .{
            .venue_number = info[pos + 1],
            .url = info[pos + 2 ..][0 .. l - 1],
        };
        got += 1;
        pos += 1 + l;
    }
    return got;
}

pub fn buildVenueUrl(out: []u8, duples: []const VenueUrlDuple) Error!usize {
    if (duples.len == 0) return error.BadValue;
    var total: usize = 0;
    for (duples) |d| {
        if (d.url.len + 1 > 255) return error.TooLong;
        total += 2 + d.url.len;
    }
    if (out.len < total) return error.NoRoom;
    var pos: usize = 0;
    for (duples) |d| {
        out[pos] = @intCast(1 + d.url.len);
        out[pos + 1] = d.venue_number;
        @memcpy(out[pos + 2 ..][0..d.url.len], d.url);
        pos += 2 + d.url.len;
    }
    return total;
}

// ---------------------------------------------------------------------------
// 11) 四种 GAS 帧（9.6.8.12–9.6.8.15）
// ---------------------------------------------------------------------------

fn checkHeader(field: []const u8, action: Action) Error!void {
    if (field.len < 2) return error.Truncated;
    if (field[0] != category_public) return error.BadCategory;
    if (field[1] != @backingInt(action)) return error.BadAction;
}

pub const InitialRequest = struct {
    dialog_token: u8,
    adv_proto: AdvProto,
    /// Query Request 字段（Figure 9-667），例如 `buildQueryList` / `buildAnqpElement` 的输出串。
    query: []const u8 = &.{},
    /// Multi-band（可选）原样透传；本模块不解释。
    multiband: []const u8 = &.{},
};

/// Table 9-313：Category + Public Action + Dialog Token + Advertisement Protocol 元素 +
/// Query Request Length(2) + Query Request + Multi-band(可选)。
/// 方向规则（9.4.2.93）：请求方发出的帧里 Query Response Length Limit 与 PAME-BI 都是
/// 保留（55225、55231），按 9.2.4.1（36052）保留位发送置 0——两者非 0 拒绝。
pub fn buildInitialRequest(out: []u8, p: InitialRequest) Error!usize {
    if (p.adv_proto.pame_bi or p.adv_proto.length_limit_units != 0) return error.BadValue;
    if (p.query.len > 65535) return error.TooLong;
    const total = 9 + p.query.len + p.multiband.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category_public;
    out[1] = @backingInt(Action.initial_request);
    out[2] = p.dialog_token;
    _ = try buildAdvProtoElement(out[3..], p.adv_proto);
    w16(out[7..][0..2], @intCast(p.query.len));
    @memcpy(out[9..][0..p.query.len], p.query);
    @memcpy(out[9 + p.query.len ..][0..p.multiband.len], p.multiband);
    return total;
}

pub fn parseInitialRequest(field: []const u8) Error!InitialRequest {
    try checkHeader(field, .initial_request);
    if (field.len < 5) return error.Truncated;
    const adv = try parseAdvProtoAt(field, 3);
    if (field.len < adv.next + 2) return error.Truncated;
    const qreq_len: usize = le16(field[adv.next..][0..2]);
    const body_at = adv.next + 2;
    if (field.len < body_at + qreq_len) return error.Truncated;
    return .{
        .dialog_token = field[2],
        .adv_proto = adv.adv,
        .query = field[body_at..][0..qreq_len],
        .multiband = field[body_at + qreq_len ..],
    };
}

pub const InitialResponse = struct {
    dialog_token: u8,
    /// 状态码，2 字节小端（9.4.1.9：Status Code 字段是 2 八位组；见文件头）。
    /// Table 9-46 的取值都 ≤ 255，>255 视为未定义码原样携带。
    status: u16,
    /// TU（Figure 9-668）。带 Query Response 时应为 0（9.6.8.13）。
    comeback_delay_tu: u16,
    adv_proto: AdvProto,
    /// Query Response（可选，Length 为 0 即没有，9.6.8.13）。
    query_response: []const u8 = &.{},
    multiband: []const u8 = &.{},
};

/// Table 9-314。响应帧里 Query Response Length Limit = 0 不允许（9.4.2.93，
/// 55222：「A value of 0 is not permitted.」）。
pub fn buildInitialResponse(out: []u8, p: InitialResponse) Error!usize {
    if (p.adv_proto.length_limit_units == 0) return error.BadValue;
    if (p.query_response.len > 65535) return error.TooLong;
    const total = 13 + p.query_response.len + p.multiband.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category_public;
    out[1] = @backingInt(Action.initial_response);
    out[2] = p.dialog_token;
    w16(out[3..][0..2], p.status);
    w16(out[5..][0..2], p.comeback_delay_tu);
    _ = try buildAdvProtoElement(out[7..], p.adv_proto);
    w16(out[11..][0..2], @intCast(p.query_response.len));
    @memcpy(out[13..][0..p.query_response.len], p.query_response);
    @memcpy(out[13 + p.query_response.len ..][0..p.multiband.len], p.multiband);
    return total;
}

pub fn parseInitialResponse(field: []const u8) Error!InitialResponse {
    try checkHeader(field, .initial_response);
    if (field.len < 9) return error.Truncated; // Cat + Act + Token + Status(2) + Delay(2) + 元素头
    const adv = try parseAdvProtoAt(field, 7);
    if (field.len < adv.next + 2) return error.Truncated;
    const qresp_len: usize = le16(field[adv.next..][0..2]);
    const body_at = adv.next + 2;
    if (field.len < body_at + qresp_len) return error.Truncated;
    return .{
        .dialog_token = field[2],
        .status = le16(field[3..5]),
        .comeback_delay_tu = le16(field[5..7]),
        .adv_proto = adv.adv,
        .query_response = field[body_at..][0..qresp_len],
        .multiband = field[body_at + qresp_len ..],
    };
}

pub const ComebackRequest = struct {
    dialog_token: u8,
    multiband: []const u8 = &.{},
};

/// Table 9-315：Category + Public Action + Dialog Token + Multi-band(可选)。
pub fn buildComebackRequest(out: []u8, p: ComebackRequest) Error!usize {
    const total = 3 + p.multiband.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category_public;
    out[1] = @backingInt(Action.comeback_request);
    out[2] = p.dialog_token;
    @memcpy(out[3..][0..p.multiband.len], p.multiband);
    return total;
}

pub fn parseComebackRequest(field: []const u8) Error!ComebackRequest {
    try checkHeader(field, .comeback_request);
    if (field.len < 3) return error.Truncated;
    return .{ .dialog_token = field[2], .multiband = field[3..] };
}

pub const ComebackResponse = struct {
    dialog_token: u8,
    status: u16,
    /// B0–B6（Figure 9-104），初始片 0，其后逐片加 1（9.6.8.15）。
    fragment_id: u7,
    /// B7 More GAS Fragments（Figure 9-104）：1 = 还有后续片。
    more_fragments: bool = false,
    /// TU：片帧里应为 0；95（QUERY_RESPONSE_OUTSTANDING）帧里给出再来的间隔。
    comeback_delay_tu: u16 = 0,
    adv_proto: AdvProto,
    query_response: []const u8 = &.{},
    multiband: []const u8 = &.{},
};

/// Table 9-316。响应帧里 Query Response Length Limit = 0 不允许（9.4.2.93，55222）。
pub fn buildComebackResponse(out: []u8, p: ComebackResponse) Error!usize {
    if (p.adv_proto.length_limit_units == 0) return error.BadValue;
    if (p.query_response.len > 65535) return error.TooLong;
    const total = 14 + p.query_response.len + p.multiband.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category_public;
    out[1] = @backingInt(Action.comeback_response);
    out[2] = p.dialog_token;
    w16(out[3..][0..2], p.status);
    out[5] = @as(u8, p.fragment_id) | @as(u8, if (p.more_fragments) 0x80 else 0);
    w16(out[6..][0..2], p.comeback_delay_tu);
    _ = try buildAdvProtoElement(out[8..], p.adv_proto);
    w16(out[12..][0..2], @intCast(p.query_response.len));
    @memcpy(out[14..][0..p.query_response.len], p.query_response);
    @memcpy(out[14 + p.query_response.len ..][0..p.multiband.len], p.multiband);
    return total;
}

pub fn parseComebackResponse(field: []const u8) Error!ComebackResponse {
    try checkHeader(field, .comeback_response);
    if (field.len < 10) return error.Truncated; // Cat + Act + Token + Status(2) + Frag + Delay(2) + 元素头
    const adv = try parseAdvProtoAt(field, 8);
    if (field.len < adv.next + 2) return error.Truncated;
    const qresp_len: usize = le16(field[adv.next..][0..2]);
    const body_at = adv.next + 2;
    if (field.len < body_at + qresp_len) return error.Truncated;
    const frag_byte = field[5];
    return .{
        .dialog_token = field[2],
        .status = le16(field[3..5]),
        .fragment_id = @truncate(frag_byte),
        .more_fragments = (frag_byte & 0x80) != 0,
        .comeback_delay_tu = le16(field[6..8]),
        .adv_proto = adv.adv,
        .query_response = field[body_at..][0..qresp_len],
        .multiband = field[body_at + qresp_len ..],
    };
}

// ---------------------------------------------------------------------------
// 12) STA 查询流程状态机（11.25.3.2.2 / 11.25.3.2.4 尾部）
// ---------------------------------------------------------------------------

pub const State = enum {
    /// 未开始。
    idle,
    /// Initial Request 已发出，等 Initial Response（11.25.3.2.2 c）。
    waiting_initial_response,
    /// 响应方让稍后再来（Comeback Delay 未到期，或收到 95）。
    waiting_comeback_delay,
    /// 正在按片取 Query Response。
    retrieving_fragments,
    /// 查询成功结束。
    complete,
    /// 查询以失败结束（`result` 给码）。
    failed,
};

pub const Params = struct {
    /// Dialog Token（9.4.1.12，1 字节；GAS 请求原文没有要求非 0）。
    dialog_token: u8,
    protocol: AdvertisementProtocol = .anqp,
    /// dot11GASResponseTimer 初值（TU）。每个收下的 Comeback Response 都会重置。
    response_timeout_tu: u32,
    /// 组装 Query Response 的存储（调用方提供；耗尽按 63 报，见文件头）。
    response_buf: []u8,
};

/// `start()` 的参数。请求方向帧里 Query Response Length Limit 与 PAME-BI 都是保留位
/// （9.4.2.93：55225、55231；9.2.4.1：36052 保留位发送置 0），所以这里没有暴露旋钮——
/// `start` 恒按 0 编码；方向相关的合法取值只出现在响应帧构造里。
pub const Request = struct {
    /// Query Request 字段（例如 `buildQueryList` 的输出）。
    query: []const u8 = &.{},
};

/// `onAction()` / `tick()` 的结果。
pub const Outcome = union(enum) {
    /// 没有待发帧、也没有结论（帧被忽略或仍在等待）。
    none,
    /// 待发帧已写进 out，长度为该值。
    tx: usize,
    /// 查询终止，码在 `result`。
    done: ResultCode,
};

pub const Machine = struct {
    params: Params,
    state: State = .idle,
    /// 终止码（complete 时是 .success）。
    result: ResultCode = .success,
    /// dot11GASResponseTimer 的到期时刻（TU，回绕安全）。
    deadline_tu: u32 = 0,
    /// 下一次该发 Comeback Request 的时刻（TU）。
    comeback_at_tu: u32 = 0,
    /// 下一片的 Fragment ID（= 已收下的片数，片从 0 起连续编）。
    expected_frag: u8 = 0,
    /// Fragment ID 0..127 的已收位图。
    frag_bits: [2]u64 = .{ 0, 0 },
    /// More=0 那一帧声明的最后一片。
    final_frag: ?u8 = null,
    /// 已组装的 Query Response 长度。
    resp_len: usize = 0,
    stats: Stats = .{},

    pub const Stats = struct {
        initial_responses: u8 = 0,
        comeback_responses: u8 = 0,
        comeback_requests_sent: u8 = 0,
        /// Dialog Token 对不上的帧（11.25.3.2.2 c)：只等 Token 相同的响应）。
        ignored_wrong_token: u8 = 0,
        /// Fragment ID 已收过的重复片（实现取舍见文件头）。
        ignored_duplicate_fragment: u8 = 0,
    };

    pub fn init(params: Params) Machine {
        return .{ .params = params };
    }

    /// 11.25.3.2.2 a)：发 GAS Initial Request 并启动 dot11GASResponseTimer。
    pub fn start(self: *Machine, request: Request, now_tu: u32, out: []u8) Error!usize {
        if (self.state != .idle) return error.WrongState;
        const n = try buildInitialRequest(out, .{
            .dialog_token = self.params.dialog_token,
            .adv_proto = .{ .protocol = self.params.protocol },
            .query = request.query,
        });
        self.state = .waiting_initial_response;
        self.deadline_tu = now_tu +% self.params.response_timeout_tu;
        return n;
    }

    /// 收到一个 Action 字段（调用方先按 Category / 帧类型分流，地址过滤也由调用方做：
    /// 11.25.3.2.4 要求 source MAC 匹配，本模块不认识 MAC）。
    pub fn onAction(self: *Machine, action_field: []const u8, now_tu: u32, out: []u8) Error!Outcome {
        const hdr = frame.parseAction(action_field) catch return error.Truncated;
        if (hdr.category != category_public) return error.BadCategory;
        if (hdr.action == @backingInt(Action.initial_response)) {
            return self.onInitialResponse(action_field, now_tu);
        }
        if (hdr.action == @backingInt(Action.comeback_response)) {
            return self.onComebackResponse(action_field, now_tu, out);
        }
        return error.BadAction;
    }

    /// 推进计时：Comeback Delay 到期发 Comeback Request；dot11GASResponseTimer 到期
    /// 报 GAS_QUERY_TIMEOUT（11.25.3.2.2 d)、11.25.3.2.4 p.1832）。
    pub fn tick(self: *Machine, now_tu: u32, out: []u8) Error!Outcome {
        switch (self.state) {
            .idle, .complete, .failed => return .none,
            .waiting_comeback_delay => {
                if (dueOrPast(now_tu, self.deadline_tu)) return self.finish(.query_timeout);
                if (dueOrPast(now_tu, self.comeback_at_tu)) {
                    // 「A requesting STA shall transmit a GAS Comeback Request frame …
                    // immediately after the expiration of the GAS Comeback Delay」
                    const n = try buildComebackRequest(out, .{ .dialog_token = self.params.dialog_token });
                    self.state = .retrieving_fragments;
                    self.stats.comeback_requests_sent += 1;
                    return .{ .tx = n };
                }
                return .none;
            },
            .waiting_initial_response, .retrieving_fragments => {
                if (dueOrPast(now_tu, self.deadline_tu)) return self.finish(.query_timeout);
                return .none;
            },
        }
    }

    /// 组装好的 Query Response；成功时是完整响应，任何终止失败后为空
    /// （11.25.3.2.2 d)/11.25.3.2.4：确认时 Length 置 0）。
    pub fn queryResponse(self: *const Machine) []const u8 {
        return self.params.response_buf[0..self.resp_len];
    }

    /// 已收下的不同 Fragment ID 个数。
    pub fn fragmentsSeen(self: *const Machine) u8 {
        return @popCount(self.frag_bits[0]) + @popCount(self.frag_bits[1]);
    }

    fn finish(self: *Machine, code: ResultCode) Outcome {
        self.state = .failed;
        self.result = code;
        // 11.25.3.2.2 d)（95167）与 11.25.3.2.4（95336、95351、95359）：终止确认一律
        // 「shall set the Query Response Length field to 0」——残片不交给调用方。
        self.resp_len = 0;
        return .{ .done = code };
    }

    fn appendResponse(self: *Machine, frag: []const u8) bool {
        if (self.resp_len + frag.len > self.params.response_buf.len) return false;
        @memcpy(self.params.response_buf[self.resp_len..][0..frag.len], frag);
        self.resp_len += frag.len;
        return true;
    }

    fn markFrag(self: *Machine, id: u8) void {
        self.frag_bits[id >> 6] |= @as(u64, 1) << @intCast(id & 63);
    }

    /// 11.25.3.2.4（p.1832）：「confirming that all fragment IDs from 0 to the value in the
    /// GAS Query Response Fragment ID when the More GAS Fragments field was equal to 0
    /// have been received」。
    fn completeThrough(self: *const Machine, final: u8) bool {
        var id: u8 = 0;
        while (id <= final) : (id += 1) {
            if (self.frag_bits[id >> 6] & (@as(u64, 1) << @intCast(id & 63)) == 0) return false;
        }
        return true;
    }

    fn onInitialResponse(self: *Machine, field: []const u8, now_tu: u32) Error!Outcome {
        if (self.state != .waiting_initial_response) return error.WrongState;
        const f = try parseInitialResponse(field);
        if (f.dialog_token != self.params.dialog_token) {
            self.stats.ignored_wrong_token += 1;
            return .none; // 只等 Dialog Token 相同的响应（11.25.3.2.2 c)
        }
        if (f.adv_proto.protocol != self.params.protocol) return error.UnsupportedProtocol;
        self.stats.initial_responses += 1;
        if (f.status != 0) {
            // Initial Response 阶段的非 0 状态码一律按终止失败处理（hostap gas_query 的做法；
            // 95 在 Initial Response 里的流程原文没有定义）。
            return self.finish(@fromBackingInt(@intCast(f.status)));
        }
        if (f.query_response.len > 0) {
            // SUCCESS + 响应在场：一次往返即完成（9.6.8.13：此时 Comeback Delay = 0）。
            if (!self.appendResponse(f.query_response)) return self.finish(.response_too_large);
            self.state = .complete;
            self.result = .success;
            return .{ .done = .success };
        }
        if (f.comeback_delay_tu == 0) return error.BadValue; // 既无响应又无 delay 的 SUCCESS 说不出话
        self.state = .waiting_comeback_delay;
        self.comeback_at_tu = now_tu +% f.comeback_delay_tu;
        return .none;
    }

    fn onComebackResponse(self: *Machine, field: []const u8, now_tu: u32, out: []u8) Error!Outcome {
        if (self.state != .waiting_comeback_delay and self.state != .retrieving_fragments) {
            return error.WrongState;
        }
        const f = try parseComebackResponse(field);
        if (f.dialog_token != self.params.dialog_token) {
            self.stats.ignored_wrong_token += 1;
            return .none;
        }
        if (f.adv_proto.protocol != self.params.protocol) return error.UnsupportedProtocol;
        const id: u8 = f.fragment_id;
        if (id < self.expected_frag) {
            self.stats.ignored_duplicate_fragment += 1;
            return .none; // 重复片：忽略整帧、不重置计时器（取舍见文件头）
        }
        self.stats.comeback_responses += 1;
        // 「Upon receipt of the first GAS Comeback Response frame and every GAS Comeback
        // Response frame thereafter, the dot11GASResponseTimer shall be reset」
        self.deadline_tu = now_tu +% self.params.response_timeout_tu;
        const status: ResultCode = @fromBackingInt(@intCast(f.status));
        if (f.status != 0) {
            if (status == .query_response_outstanding) {
                // 「the requesting STA shall wait for the GAS Comeback Delay from that frame
                // and upon expiration … transmit another GAS Comeback Request frame」
                self.state = .waiting_comeback_delay;
                self.comeback_at_tu = now_tu +% f.comeback_delay_tu;
                return .none;
            }
            return self.finish(status);
        }
        if (f.more_fragments and id == 127) return error.BadValue; // 9.4.1.34：最大 127
        if (!self.appendResponse(f.query_response)) return self.finish(.response_too_large);
        self.markFrag(id);
        self.expected_frag = id + 1;
        if (f.more_fragments) {
            // 「it shall transmit another GAS Comeback Request frame」
            const n = try buildComebackRequest(out, .{ .dialog_token = self.params.dialog_token });
            self.state = .retrieving_fragments;
            self.stats.comeback_requests_sent += 1;
            return .{ .tx = n };
        }
        self.final_frag = id;
        if (self.completeThrough(id)) {
            self.state = .complete;
            self.result = .success;
            return .{ .done = .success };
        }
        // More=0 但有缺片：不再发请求（取舍见文件头），等计时器超时。
        return .none;
    }
};
