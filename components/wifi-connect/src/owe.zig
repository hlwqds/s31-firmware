//! wifi-connect：OWE（Opportunistic Wireless Encryption，RFC 8110）——AKM 与密码套件的
//! 选择、DH Parameter element、group 19 的密钥协商，以及关联后的 PMK / PMKID 派生。
//! 只做 group 19（256 位随机 ECP 群，即 P-256）。
//!
//! 条款对照（RFC 8110，2017-03；802.11 的部分以 IEEE Std 802.11-2016 为准）：
//!
//!   4.1   哈希算法由群决定：len(p) <= 256 用 SHA-256。group 19 的 p 是 256 位，所以
//!         全程 SHA-256，PMK 的 n 是 256 位。
//!   4.2   表 1：OWE 的 AKM 套件选择器是 OUI 00-0F-AC、Suite Type 18，AP 把它放进 Beacon 与
//!         Probe Response 的 RSNE。发现之后走 Open System 认证，再关联。
//!         （802.11-2016 表 9-133 把 14–255 列为保留，AKM 18 只由 RFC 8110 表 1 定义。）
//!   4.3   图 1：Diffie-Hellman Parameter element =
//!           Element ID(255) | Length | Element ID Extension(32) | group(2，小端) | public key
//!         client 在 Association Request 里、AP 在 Association Response 里各带一个，装各自的
//!         公钥。公钥的编码：group 19 的曲线由 [RFC 6090] 定义，所以用紧凑表示（RFC 6090
//!         §4.2）——只传 x 坐标，32 个八位组，大端（RFC 6090 §6.2）。
//!         「a compliant implementation MUST support group nineteen」；AP 不支持请求里的群时
//!         回 status code 77（印刷页 8，394–400 行：client 收到 77 后 SHOULD 换一个支持的群
//!         重试，MAY 再用导致失败的群试一次，放弃时 SHOULD 记日志并提示用户——本组件只有
//!         group 19，所以「换一个群」无群可换，`nextGroupToTry` 返回 null）。收到的公钥要校验，
//!         无效则关联失败。「PMK caching is not being performed」时 client 收到「指示了 OWE AKM
//!         却没有 DH Parameter element」的 Association Response 必须丢弃（389–393 行）；缓存
//!         命中就是「PMK caching is being performed」，那时响应本来就不带 DH Parameter element。
//!   4.4   z = F(DH(x, Y))
//!         prk = HKDF-extract(C | A | group, z)
//!         PMK = HKDF-expand(prk, "OWE Key Generation", n)
//!         PMKID = Truncate-128(Hash(C | A))
//!         C 是 client 的公钥、A 是 AP 的公钥，取 DH Parameter element 里原样收发的 public key；
//!         group 是元素里那两个小端八位组。HKDF 见 RFC 5869 §2.2、§2.3。z 与 prk 在 PMK
//!         生成后抹掉（SHOULD be irretrievably deleted）。
//!   4.5   PMK caching（印刷页 10，511–542 行）：client 与 AP 可以把 PMK 缓存一段时间，重关联
//!         时用 4 次握手复用它，跳过昂贵的认证。client 把 PMKID 放进 (Re)Association Request
//!         的 RSNE（802.11-2016 9.4.2.25 的 PMKID Count / List，本组件经
//!         `buildAssocRequestWith`，且 525 行规定此时 MUST 同时带 DH Parameter element）；
//!         AP 的缓存里有这个 PMKID 就在 Response 的 RSNE 里回同一个 PMKID、不带 DH Parameter
//!         element（527–529 行），没有就忽略 PMKID、照常走 OWE 关联并带 DH Parameter element
//!         （529–531 行）。client 一侧：响应里的 PMKID 与自己发出的一致时 SHALL 忽略响应里的
//!         DH Parameter element、用缓存的 PMK（533–535 行）；响应没有 PMKID 或不一致时 SHALL
//!         照常走 OWE 关联（536–539 行）；请求里没带 PMKID 时 SHALL 忽略响应里的 PMKID
//!         （540–542 行）。缓存条目与过期 / 替换策略见 `Cache`：「cache a PMK for a certain
//!         period of time」的期限原文没定数，802.11-2016 的 dot11RSNAConfigPMKLifetime
//!         DEFVAL 43200 秒（150617–150634 行）；过期判据与 hostap 一致（expiration < now，
//!         pmksa_cache.c 的 pmksa_cache_expire）；满时移除最早过期的条目（hostap 的链表按
//!         过期时间升序插入，pmksa_cache.c:217-238 挤掉表头「Remove the oldest entry to
//!         make room」）。命中/未命中两侧的
//!         判决在 `clientCacheDecision` / `apCacheDecision`。
//!
//! 椭圆曲线的运算都在 `ecc.zig`；这里只补 OWE 特有的三件事：
//!   * 私钥范围 [1, n−1]（RFC 6090 §4）与拒绝采样生成（RFC 6090 附录 B）；
//!   * 紧凑公钥的校验与还原：p ≡ 3 (mod 4)，y = (x³ + ax + b)^((p+1)/4)，平方验证不过说明
//!     曲线上没有这个 x（RFC 6090 附录 C）；y 取哪个根都行，两个根互为相反数，乘同一个
//!     标量后 x 坐标相同；
//!   * RFC 8110 §4.4 的三步公式。
//!
//! status code 取自 802.11-2016 表 9-46（印刷页 731、735）。RFC 8110 只规定了「群不支持」
//! 用 77；其余失败原文只要求 unsuccessful association，这里取 1（Unspecified failure），与
//! 盘上 hostap 的 `owe_process_assoc_req`（src/ap/ieee802_11.c:856-898）一致。
//!
//! 独立实现对照（`~/esp/esp-idf/components/wpa_supplicant`）：请求方 `owe_process_assoc_resp`
//! （src/rsn_supp/wpa.c:3339-3491）、AP `owe_process_assoc_req`（src/ap/ieee802_11.c:840-993）、
//! 元素常量（src/common/ieee802_11_defs.h:250、267）、只传 x 坐标
//! （esp_supplicant/src/crypto/crypto_mbedtls-ec.c:3003-3021）、HKDF-Expand
//! （src/crypto/sha256-kdf.c:32-87，label = NULL 时就是 RFC 5869 §2.3）。
//!
//! 明确不做：
//!   * RFC 8110 4.4 表 2 规定的 4 次握手算法（HMAC-SHA-256 的 MIC、KCK / KEK 128 位）。
//!     现有 `supplicant.zig` / `wpa2.zig` 只按 AKM 1、2、8 选算法，本文件不改它们；
//!     PMK 的类型与它们一致（32 个八位组），可以直接交给 `Supplicant.start`。
//!   * group 19 以外的群、FFC 群、收发帧与认证 / 关联的状态机。
//!   * OWE Transition Mode：不在 RFC 8110 里（全文没有 "transition" 一词，grep 0 命中）；
//!     它出自 Wi-Fi 联盟的 OWE 规范，盘上没有原文，无从对照，未实现。
//!   * 收发帧：缓存的入队（client 在 4 次握手完成后、AP 在派生新 PMK 成功后，hostap 分别在
//!     `wpa_supplicant_key_neg_complete` 与 `wpa_auth_pmksa_add2` 时做）由调用方完成。
//!
//! 板侧没有随机源：私钥由调用方注入的随机函数生成。不用分配器，不 import hw/log。

const std = @import("std");

const ecc = @import("ecc.zig");
const rsne = @import("rsne.zig");
const sae = @import("sae.zig");

const Fe = std.crypto.ecc.P256.Fe;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// RFC 8110 表 1：OWE 的 AKM suite type（OUI 00-0F-AC），线上的选择器是 00 0F AC 12。
pub const akm_owe: u8 = 18;
/// RFC 8110 4.3：group nineteen，256 位椭圆曲线群（RFC 5903 3.1 的 P-256）。只支持它。
pub const group_19: u16 = 19;
/// 图 1 的 Element ID 与 Element ID Extension（802.11-2016 9.4.2.1：255 表示扩展元素，
/// 扩展号跟在 Length 之后）。
pub const element_id: u8 = 255;
pub const element_ext: u8 = 32;
/// 紧凑公钥（x 坐标）的八位组数，group 19。
pub const public_key_len = ecc.coord_len;
/// group 19 的 DH Parameter element 总长：Element ID + Length + Extension + group + 公钥。
pub const dh_element_len = 2 + 1 + 2 + public_key_len;
/// 4.4 的 n：摘要的位长。SHA-256 → 256 位。
pub const pmk_len = 32;
/// Truncate-128。
pub const pmkid_len = 16;
/// 4.4：HKDF-expand 的 info。
pub const key_label = "OWE Key Generation";

/// 802.11-2016 表 9-46（印刷页 731、735）里与 OWE 有关的 status code。
pub const Status = struct {
    pub const success: u16 = 0;
    /// REFUSED_REASON_UNSPECIFIED：Unspecified failure。
    pub const unspecified_failure: u16 = 1;
    /// UNSUPPORTED_FINITE_CYCLIC_GROUP：offered finite cyclic group is not supported。
    pub const unsupported_finite_cyclic_group: u16 = 77;
};

/// 本端做 OWE 时的策略（12.6.3 的策略选择用）：AKM 只认 OWE。RFC 8110 不限定密码套件，
/// 这里沿用本组件默认的 CCMP-128 与 GCMP-128（表 9-131，印刷页 885；两者 GTK、PTK 皆可，
/// 表 9-132，印刷页 887）。
const owe_akms: [rsne.max_akm]u8 = [1]u8{akm_owe} ++ @as([rsne.max_akm - 1]u8, @splat(rsne.unknown));
pub const policy: rsne.OwnPolicy = .{ .akm = owe_akms, .akm_len = 1 };

pub const Error = error{
    /// 私钥不在 [1, n−1] 内（RFC 6090 §4）。
    BadPrivateKey,
    /// 随机源连续 `generate_attempts` 次都给不出范围内的私钥。
    RandomExhausted,
    /// 对端公钥无效：长度不是 32 个八位组，x 不小于 p，或曲线上没有这个 x（4.3）。
    BadPublicKey,
    /// 共享秘密是无穷远点，没有 z（4.4）。
    SharedInfinity,
    /// 对端的 (Re)Association 帧里没有 RSNE：不是 RSNA，也就不是 OWE。
    NoRsne,
    /// 对端指示了 OWE AKM，却没有 DH Parameter element（4.3）。
    NoDhParameter,
    /// DH Parameter element 的 Length 装不下 Element ID Extension 与 group，或超出帧。
    BadDhElement,
    /// 不是 DH Parameter element（Element ID 或 Element ID Extension 不对）。
    NotDhElement,
    /// 对端用的群本端不支持（只有 19）→ status code 77。
    UnsupportedDhGroup,
    /// client 在请求里带了自己缓存里已经没有（或已过期）的 PMKID，AP 却回了一个匹配的
    /// PMKID：没有可用的 PMK，4.5 的命中路径走不下去。
    PmkNotCached,
    /// 想在 Association Request 的 RSNE 里带 PMKID，但策略的 MFPC 是假的：RSNE 里
    /// PMKID Count 排在 RSN Capabilities 之后（802.11-2016 9.4.2.25），本组件的 RSNE
    /// 写法只在 MFPC 时写 Capabilities 与 PMKID 字段，这样请求会静默丢掉 PMKID。
    PmkidNeedsMfpc,
};

/// 处理对端 (Re)Association 帧时可能出的全部错误：本文件的，加上 RSNE 解析与策略选择的。
pub const ProcessError = Error || rsne.Error || rsne.SelError;

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

/// 私钥 x：[1, n−1] 内的整数，32 个八位组，大端（RFC 6090 §6.2）。
pub const PrivateKey = [ecc.coord_len]u8;
/// 公钥的线上形式：紧凑表示，只带 x 坐标，32 个八位组，大端（RFC 8110 4.3、RFC 6090 §4.2）。
pub const PublicKey = [public_key_len]u8;

pub const KeyPair = struct {
    private: PrivateKey,
    public: PublicKey,
};

/// 4.4 的结果。
pub const Keys = struct {
    pmk: [pmk_len]u8,
    pmkid: [pmkid_len]u8,
};

/// 本端在这次关联里的角色：`.client` 发 Association Request，公钥是 C；`.ap` 发
/// Association Response，公钥是 A。
pub const Role = enum { client, ap };

/// 图 1 的元素解出来之后的内容。
pub const DhElement = struct {
    group: u16,
    public_key: PublicKey,
};

// ---------------------------------------------------------------------------
// 密钥对（RFC 6090 §4、附录 B）
// ---------------------------------------------------------------------------

/// 私钥的合法范围：1 <= x <= n−1。
pub fn privateInRng(private: PrivateKey) bool {
    var one: PrivateKey = @splat(0);
    one[one.len - 1] = 1;
    return sae.cmp(private, one) != .lt and sae.cmp(private, sae.order) == .lt;
}

/// 由私钥得到密钥对。公钥 = x·G，线上只带 x 坐标。
pub fn fromPrivate(private: PrivateKey) Error!KeyPair {
    if (!privateInRng(private)) return error.BadPrivateKey;
    const p = ecc.mul(private, ecc.Point.base);
    // 范围内的私钥乘基点不会是无穷远点；真出现了也只能当私钥不可用。
    if (p.isInfinity()) return error.BadPrivateKey;
    return .{ .private = private, .public = p.xBytes() };
}

/// 取随机数：把 `out` 填满。逻辑模块不读硬件，由调用方注入（与 `sae_full.Random` 同形）。
pub const Random = *const fn (out: []u8) void;

/// 拒绝采样最多试几次。单个 256 位随机数落在 [1, n−1] 之外的概率约 2^-32。
pub const generate_attempts = 8;

/// 生成密钥对：私钥是 [1, n−1] 内均匀随机的整数，每次从 `random` 取 32 个八位组，
/// 落在范围外就丢掉重取（RFC 6090 附录 B 的拒绝法）。
pub fn generate(random: Random) Error!KeyPair {
    var attempt: usize = 0;
    while (attempt < generate_attempts) : (attempt += 1) {
        var private: PrivateKey = undefined;
        random(&private);
        if (privateInRng(private)) return fromPrivate(private);
    }
    return error.RandomExhausted;
}

// ---------------------------------------------------------------------------
// 紧凑公钥的校验（RFC 8110 4.3、RFC 6090 附录 C）
// ---------------------------------------------------------------------------

/// 紧凑公钥 → 曲线上的点。x 不小于 p、或 x³ + ax + b 不是二次剩余（曲线上没有这个 x）
/// 都报 `BadPublicKey`。
///
/// y 取偶数的那个根。另一个根是它的相反数，与同一个标量相乘后 x 坐标相同，所以共享秘密
/// z 不受选择影响（RFC 6090 附录 C）。
///
/// 这里不走 `ecc.fromBytes`：它按 SAE 的 12.4.7.2.5 把坐标为 0 的点也判为非法，而 OWE 的
/// 判据只有「满足曲线方程」（RFC 6090 §3.3）——P-256 上 (0, ±√b) 是合法的点。
pub fn peerPoint(public: PublicKey) Error!ecc.Point {
    const y = ecc.recoverY(public, false) orelse return error.BadPublicKey;
    const x = Fe.fromBytes(public, .big) catch return error.BadPublicKey;
    const y_fe = Fe.fromBytes(y, .big) catch return error.BadPublicKey;
    if (!ecc.isOnCurve(x, y_fe)) return error.BadPublicKey;
    return .{ .inf = false, .x = x, .y = y_fe };
}

// ---------------------------------------------------------------------------
// 4.4：PMK 与 PMKID
// ---------------------------------------------------------------------------

/// 把 z、prk 这类中间值从栈上抹掉：编译器不保证 `@memset` 不被优化掉，所以用 volatile 写。
fn wipe(bytes: []u8) void {
    for (bytes) |*b| {
        const p: *volatile u8 = b;
        p.* = 0;
    }
}

/// 4.4 的三步公式，输入都是八位组串：
///   prk  = HMAC-SHA-256(C | A | group, z)                        （HKDF-extract，RFC 5869 §2.2）
///   PMK  = HMAC-SHA-256(prk, "OWE Key Generation" | 0x01)         （HKDF-expand，RFC 5869 §2.3，
///                                                                 n 是一个摘要长，只有 T(1)）
///   PMKID = SHA-256(C | A) 的前 16 个八位组
/// `z` 是共享点的 x 坐标，32 个八位组，大端，左边补零（RFC 5903 §7）。
pub fn deriveKeys(client: PublicKey, ap: PublicKey, z0: [public_key_len]u8) Keys {
    var z = z0;
    defer wipe(&z);

    // salt 是 HMAC 的密钥，只能一次给全：标准库的 extractInit(salt) 就是 Hmac.init(salt)，
    // 之后的 update 喂的是消息（IKM），所以这里拼一块 66 字节的缓冲。
    var salt: [2 * public_key_len + 2]u8 = undefined;
    salt[0..public_key_len].* = client;
    salt[public_key_len..][0..public_key_len].* = ap;
    std.mem.writeInt(u16, salt[2 * public_key_len ..][0..2], group_19, .little);
    var prk = HkdfSha256.extract(&salt, &z);
    defer wipe(&prk);

    var out: Keys = undefined;
    HkdfSha256.expand(&out.pmk, key_label, prk);

    var h = Sha256.init(.{});
    h.update(&client);
    h.update(&ap);
    out.pmkid = h.finalResult()[0..pmkid_len].*;
    return out;
}

/// 与 `deriveKeys` 相同，只是共享秘密还没取 x 坐标。共享点是无穷远点时报 `SharedInfinity`：
/// 没有可用的 z，不能拿 0 去派生。
pub fn deriveFromShared(client: PublicKey, ap: PublicKey, shared: ecc.Point) Error!Keys {
    if (shared.isInfinity()) return error.SharedInfinity;
    return deriveKeys(client, ap, shared.xBytes());
}

/// 关联完成后由本端密钥对与对端的紧凑公钥算出 PMK 与 PMKID（4.3 的校验 + 4.4）：
/// DH(x, Y) = x·Y，C、A 按本端的角色排。
pub fn agree(role: Role, own: KeyPair, peer_public: PublicKey) Error!Keys {
    if (!privateInRng(own.private)) return error.BadPrivateKey;
    const shared = ecc.mul(own.private, try peerPoint(peer_public));
    const client = if (role == .client) own.public else peer_public;
    const ap = if (role == .client) peer_public else own.public;
    return deriveFromShared(client, ap, shared);
}

// ---------------------------------------------------------------------------
// 4.3：DH Parameter element（图 1）
// ---------------------------------------------------------------------------

/// 编码 group 19 的 DH Parameter element：ff 23 20 13 00 | x。
pub fn encodeDhElement(public: PublicKey, out: *[dh_element_len]u8) void {
    out[0] = element_id;
    out[1] = dh_element_len - 2;
    out[2] = element_ext;
    std.mem.writeInt(u16, out[3..5], group_19, .little);
    out[5..].* = public;
}

/// 解析图 1 的元素。`buf` 从 Element ID 起，可以比元素长（后面还跟着别的元素）。
/// 错误是互斥的，顺序是：不是这个元素 → 长度装不下头或超出帧 → 群不支持 → 公钥长度不对。
/// 公钥是否在曲线上由 `peerPoint` / `agree` 判（那一步要做曲线运算）。
pub fn parseDhElement(buf: []const u8) Error!DhElement {
    if (buf.len < 2 or buf[0] != element_id) return error.NotDhElement;
    // 声明了长度却连 Element ID Extension 都没有：只能当元素坏了。
    if (buf.len < 3) return error.BadDhElement;
    if (buf[2] != element_ext) return error.NotDhElement;
    const len: usize = buf[1];
    // 至少要有 Element ID Extension(1) + group(2)。
    if (len < 3 or buf.len < 2 + len) return error.BadDhElement;
    const group = std.mem.readInt(u16, buf[3..5], .little);
    if (group != group_19) return error.UnsupportedDhGroup;
    // 未压缩的 x||y（64 个八位组）不是 group 19 的线上表示，长度不对就在这里被拒。
    if (len - 3 != public_key_len) return error.BadPublicKey;
    return .{ .group = group, .public_key = buf[5..][0..public_key_len].* };
}

/// 在一串首尾相接的信息元素里找 Element ID 为 `id` 的元素；`ext` 不为 null 时再比
/// Element ID Extension（802.11-2016 9.4.2.1）。返回从该元素开头到末尾的切片，长度由
/// 解析函数按 Length 字段截断。找不到返回 null。
///
/// 中途截断的元素（Length 超出剩余长度）之后不再有完整的元素，扫描到此为止；候选元素
/// 自己被截断时照样返回，让解析函数报错。
pub fn findElement(ies: []const u8, id: u8, ext: ?u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + 2 <= ies.len) {
        if (ies[pos] == id) {
            if (pos + 3 > ies.len) return ies[pos..];
            if (ext == null or ies[pos + 2] == ext.?) return ies[pos..];
        }
        pos += 2 + @as(usize, ies[pos + 1]);
    }
    return null;
}

// ---------------------------------------------------------------------------
// 4.2、4.3：RSNE 与关联
// ---------------------------------------------------------------------------

/// 本 STA 放进 Association Request 的信息元素：RSNE 在前，DH Parameter element 在后
/// （4.3：MUST indicate the OWE AKM、MUST include a DH Parameter element）。`sel` 是按 AP 的
/// RSNE 做出的策略选择（12.6.3），RSNE 的写法与 PSK / SAE 相同（`rsne.buildStaRsne`）。
/// 返回写入长度。
pub fn buildAssocRequest(sel: rsne.Selection, own: KeyPair, out: []u8) rsne.Error!usize {
    const n = try rsne.buildStaRsne(sel, policy, null, out);
    if (out.len - n < dh_element_len) return error.BufferTooSmall;
    encodeDhElement(own.public, out[n..][0..dh_element_len]);
    return n + dh_element_len;
}

/// 处理对端 (Re)Association 帧的结果：PMK / PMKID，以及按 12.6.3 选出的套件。
pub const Assoc = struct {
    keys: Keys,
    sel: rsne.Selection,
};

/// 处理对端发来的 (Re)Association 帧里的信息元素，走完 OWE 的关联：
///   1. RSNE 的策略选择（12.6.3）：AKM 必须是 OWE，密码套件取双方都支持的；
///   2. 必须有 DH Parameter element（4.3），群必须是 19，公钥必须有效；
///   3. 4.4：派生 PMK 与 PMKID。
///
/// `role` 是本端的角色；`ies` 是帧体里 Capability Information、Status Code / Listen Interval、
/// AID 之后的全部信息元素；`own` 是本端放进自己那帧里的密钥对。调用方先确认帧的
/// Status Code 是 0：AP 回 77 时不带 DH Parameter element。
///
/// 检查的次序决定了拒绝的理由：RSNE 在前（对端根本不是 OWE 时不该报「缺 DH 参数」），
/// DH Parameter element 在后。
pub fn processAssoc(role: Role, ies: []const u8, own: KeyPair) ProcessError!Assoc {
    const rsne_bytes = findElement(ies, rsne.element_id, null) orelse return error.NoRsne;
    const peer_rsne = try rsne.parse(rsne_bytes);
    const sel = try rsne.select(peer_rsne, policy);
    const dh = try parseDhElement(findElement(ies, element_id, element_ext) orelse
        return error.NoDhParameter);
    const keys = try agree(role, own, dh.public_key);
    return .{ .keys = keys, .sel = sel };
}

// ---------------------------------------------------------------------------
// 4.5：PMK caching
// ---------------------------------------------------------------------------

/// 802.11-2016 的 dot11RSNAConfigPMKLifetime 的 DEFVAL（150617–150634 行）：PMK 在缓存里的
/// 最长寿命，秒。RFC 8110 只说「for a certain period of time」，没定数；调用方按自己的
/// 时钟单位决定传什么。
pub const pmk_lifetime_80211: u64 = 43200;

/// 缓存的一条：4.4 的 PMK 与 PMKID，加上注入时钟下的有效期。
pub const CacheEntry = struct {
    pmk: [pmk_len]u8,
    pmkid: [pmkid_len]u8,
    /// 入缓存时的时钟读数；有效期是 [added_at, expires_at]（两端都算有效）。
    added_at: u64,
    /// added_at +| lifetime（饱和加，防溢出）。
    expires_at: u64,
};

/// PMK 缓存（4.5）：固定条数、不用分配器、时钟由调用方注入。
///
/// 与 802.11-2016 的 PMKSA 的差别：PMKSA 按（AA, SPA, PMKID）索引，hostap 的
/// `pmksa_cache_get`（src/rsn_supp/pmksa_cache.c:344-364）三个都过滤；这里没有多 AP 的
/// 概念，PMKID 本身就是一次交换的标识（4.4 的 Hash(C|A)），所以按 PMKID 唯一索引。
pub const Cache = struct {
    /// 条数上限。满了挤掉 expires_at 最早的条目（hostap pmksa_cache.c:217-238：链表按过期
    /// 时间升序插入，挤掉表头；「Remove the oldest entry to make room」）。
    pub const max_entries = 4;

    entries: [max_entries]CacheEntry = undefined,
    used: usize = 0,

    pub fn len(self: Cache) usize {
        return self.used;
    }

    /// 加入或刷新一条，与 hostap `pmksa_cache_add_entry`（src/rsn_supp/pmksa_cache.c:168-256）
    /// 同构：
    ///   * 同一 PMKID 且同一 PMK 已在缓存 → 原条目原样保留，有效期不刷新（hostap
    ///     「reusing previous PMKSA entry」，186-194 行）；
    ///   * 同一 PMKID 但 PMK 不同 → 原位替换（hostap 对同一 AA 的旧条目替换，181-215 行）；
    ///   * 有空位就放；满了替换 expires_at 最早的条目（并列取下标小的）——hostap 的链表按
    ///     过期时间升序插入（254-262 行「order by expiration time」），挤掉的是表头即最早
    ///     过期的那条（217-238 行）。hostap 还会跳过使用中的 cur_pmksa；本组件没有「使用中」
    ///     的概念，不跳。当各条目 lifetime 相同时「最早过期」就是「最早加入」。
    /// PMK 与 PMKID 的来历由调用方负责：client 在 4 次握手完成后入缓存，AP 在派生成功后
    /// 入缓存。
    pub fn add(self: *Cache, pmk: [pmk_len]u8, pmkid: [pmkid_len]u8, now: u64, lifetime: u64) void {
        for (self.entries[0..self.used]) |*e| {
            if (std.mem.eql(u8, &e.pmkid, &pmkid)) {
                if (std.mem.eql(u8, &e.pmk, &pmk)) return; // 同一交换：沿用旧条目
                e.pmk = pmk;
                e.added_at = now;
                e.expires_at = now +| lifetime;
                return;
            }
        }
        const entry = CacheEntry{
            .pmk = pmk,
            .pmkid = pmkid,
            .added_at = now,
            .expires_at = now +| lifetime,
        };
        if (self.used < max_entries) {
            self.entries[self.used] = entry;
            self.used += 1;
            return;
        }
        var victim: usize = 0;
        for (1..max_entries) |i| {
            if (self.entries[i].expires_at < self.entries[victim].expires_at) victim = i;
        }
        self.entries[victim] = entry;
    }

    /// 按 PMKID 找一条未过期的。过期判据与 hostap 相同（pmksa_cache_expire 用
    /// expiration < now 判过期）：`now <= expires_at` 有效，`now > expires_at` 视同没有。
    /// 查找不删除：过期条目由 `purge` 清。
    pub fn lookup(self: *const Cache, pmkid: [pmkid_len]u8, now: u64) ?CacheEntry {
        for (self.entries[0..self.used]) |e| {
            if (std.mem.eql(u8, &e.pmkid, &pmkid)) {
                if (now > e.expires_at) return null;
                return e;
            }
        }
        return null;
    }

    /// 删掉所有过期条目（把后面的条目前移，保持相对次序），返回删掉的条数。
    pub fn purge(self: *Cache, now: u64) usize {
        var kept: usize = 0;
        var removed: usize = 0;
        for (self.entries[0..self.used]) |e| {
            if (now > e.expires_at) {
                removed += 1;
            } else {
                self.entries[kept] = e;
                kept += 1;
            }
        }
        self.used = kept;
        return removed;
    }

    /// client 想做 PMK caching 时放进 (Re)Association Request 的「the identifying PMKID」
    /// （4.5，517–518 行）：有效条目里 added_at 最大的那个（并列取下标大的）。没有有效
    /// 条目返回 null——client 不带 PMKID，照常走 OWE 关联（4.5 的规定只约束「带了 PMKID」
    /// 时的两侧行为）。
    pub fn offerPmkid(self: *const Cache, now: u64) ?[pmkid_len]u8 {
        var best: ?usize = null;
        for (0..self.used) |i| {
            if (now > self.entries[i].expires_at) continue;
            if (best == null or self.entries[i].added_at >= self.entries[best.?].added_at) best = i;
        }
        return if (best) |i| self.entries[i].pmkid else null;
    }
};

/// 4.5 缓存判决的结果，client 与 AP 共用一个形状。
pub const CacheDecision = union(enum) {
    /// 命中：PMK 从缓存条目来，DH 交换整个跳过（client SHALL 忽略响应里的 DH Parameter
    /// element，533–535 行；AP 在派生之前就返回，hostap ieee802_11.c:846-850）。
    /// `pmkid` 就是双方认同的那个；AP 把它放进 Response 的 RSNE 且不带 DH Parameter
    /// element，status code 用 0。
    hit: struct {
        pmk: [pmk_len]u8,
        pmkid: [pmkid_len]u8,
        sel: rsne.Selection,
    },
    /// 未命中或帧里没有 PMKID：照常走 OWE 关联（4.5，529–531、536–539 行）。调用方接着调
    /// `processAssoc`——它自带 4.3 的 MUST discard（OWE AKM 而无 DH Parameter element），
    /// 派生成功后由调用方把 PMK 入缓存。
    fresh: struct {
        sel: rsne.Selection,
    },
};

/// client 处理 (Re)Association Response 的缓存判决（4.5，533–542 行）。
///
/// `offered` 是本端放进 Association Request 的 PMKID（`Cache.offerPmkid` 给的那个；没带就是
/// null）。检查次序：RSNE 的策略选择在前（与 `processAssoc` 一致，对端根本不是 OWE 时不该
/// 报缓存的事），PMKID 比对在后。响应要算命中，得恰好带一个 PMKID 且与本端发出的相同：
/// 802.11 的 RSNE 允许最多 4 个 PMKID，hostap 的请求方只认 `num_pmkid == 1`
/// （src/rsn_supp/wpa.c:3386-3389），多带当未命中。命中时 SHALL 忽略响应里的 DH Parameter
/// element（哪怕有），PMK 用 `Cache` 里那条；响应里 PMKID 与发出的一致、可缓存里已经没有
/// 这条（没入过缓存或已过期）→ `PmkNotCached`：4.5 的命中路径没有 PMK 可用。
pub fn clientCacheDecision(ies: []const u8, offered: ?[pmkid_len]u8, cache: *const Cache, now: u64) ProcessError!CacheDecision {
    const rsne_bytes = findElement(ies, rsne.element_id, null) orelse return error.NoRsne;
    const peer_rsne = try rsne.parse(rsne_bytes);
    const sel = try rsne.select(peer_rsne, policy);
    const want = offered orelse return .{ .fresh = .{ .sel = sel } };
    if (peer_rsne.pmkid_present and peer_rsne.pmkid_len == 1 and
        std.mem.eql(u8, &peer_rsne.pmkid[0], &want))
    {
        const entry = cache.lookup(want, now) orelse return error.PmkNotCached;
        return .{ .hit = .{ .pmk = entry.pmk, .pmkid = entry.pmkid, .sel = sel } };
    }
    return .{ .fresh = .{ .sel = sel } };
}

/// AP 处理 (Re)Association Request 的缓存判决（4.5，516–531 行）。
///
/// 请求的 PMKID List 逐个对缓存查，第一个命中算数（hostap 的 AP 侧正是这样遍历，
/// src/ap/wpa_auth_ie.c:813-821；client 侧只认一个，见 `clientCacheDecision`）。命中时
/// 不再看请求里的 DH Parameter element（hostap ieee802_11.c:846-850 在 DH 检查之前就
/// 返回了），Response 的 RSNE 回同一个 PMKID、不带 DH Parameter element、status 0。
/// 未命中（或请求没带 PMKID）时忽略 PMKID，照常走 OWE 关联：调用方接着调
/// `processAssoc(.ap, …)` 派生，成功后 `Cache.add` 入缓存（hostap 在
/// `wpa_auth_pmksa_add2`，src/ap/ieee802_11.c:966-973）。
pub fn apCacheDecision(ies: []const u8, cache: *const Cache, now: u64) ProcessError!CacheDecision {
    const rsne_bytes = findElement(ies, rsne.element_id, null) orelse return error.NoRsne;
    const peer_rsne = try rsne.parse(rsne_bytes);
    const sel = try rsne.select(peer_rsne, policy);
    if (peer_rsne.pmkid_present) {
        for (peer_rsne.pmkid[0..peer_rsne.pmkid_len]) |p| {
            if (cache.lookup(p, now)) |entry| {
                return .{ .hit = .{ .pmk = entry.pmk, .pmkid = entry.pmkid, .sel = sel } };
            }
        }
    }
    return .{ .fresh = .{ .sel = sel } };
}

/// client 想做 PMK caching 时的 Association Request（4.5，523–526 行：PMKID 与 DH
/// Parameter element MUST 都带）。RSNE 用 `own_policy` 写（要带 PMKID 必须开 MFPC，
/// 否则 `PmkidNeedsMfpc`），PMKID 用 `Cache.offerPmkid` 的结果，DH Parameter element 装
/// `own.public`（新一轮的公钥；命中时 AP 不会用它，527–529 行）。`pmkid` 为 null 时与
/// `buildAssocRequest` 等价。
pub fn buildAssocRequestWith(sel: rsne.Selection, own: KeyPair, own_policy: rsne.OwnPolicy, pmkid: ?[pmkid_len]u8, out: []u8) ProcessError!usize {
    if (pmkid != null and !own_policy.mfpc) return error.PmkidNeedsMfpc;
    const n = try rsne.buildStaRsne(sel, own_policy, pmkid, out);
    if (out.len - n < dh_element_len) return error.BufferTooSmall;
    encodeDhElement(own.public, out[n..][0..dh_element_len]);
    return n + dh_element_len;
}

/// 4.3（394–400 行）：client 收到 status code 77 后的动作——SHOULD 换一个支持的群重试；
/// MAY 再用导致失败的群试一次（原文说明了这有风险：802.11 的关联是不加密的）；放弃时
/// SHOULD 记日志并提示用户，这两件由调用方做。本组件按 4.3 的 MUST 只支持 group 19，
/// 所以 `supported` 只有 19 时没有「不同的群」可换，返回 null；「再用同一个群」是 MAY，
/// 由调用方的策略决定，这里不替它选。
pub fn nextGroupToTry(current: u16, supported: []const u16) ?u16 {
    for (supported) |g| {
        if (g != current) return g;
    }
    return null;
}

/// AP 回 Association Response 时用的 status code（表 9-46）。
///
/// RFC 8110 4.3 只规定了「AP 不支持请求里的群」用 77。其余失败原文只要求 unsuccessful
/// association（无效公钥）或没有规定编号（缺 DH Parameter element、元素损坏、本端的私钥与
/// 随机源出错），这里一律取 1，与盘上 hostap 的 `owe_process_assoc_req`
/// （src/ap/ieee802_11.c:856-859、884-888、895-898）一致。
///
/// RSNE 的策略错误（`rsne.SelError`）不在这张表里：那是 12.6.3 的一般规则，不是 OWE 特有的。
/// client 一侧的失败不产生 status code（client 不回 Association Response）。
pub fn statusCode(e: Error) u16 {
    return if (e == error.UnsupportedDhGroup)
        Status.unsupported_finite_cyclic_group
    else
        Status.unspecified_failure;
}
