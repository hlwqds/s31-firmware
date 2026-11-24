//! wifi-connect：SAE 完整协议（IEEE Std 802.11-2016 12.4，印刷页 1935–1953）。
//!
//! `sae.zig` 是字节层，`ecc.zig` / `bignum.zig` / `sae_groups.zig` 是群运算；本文件把它们串成协议：
//!
//!   1. 协议核心（没有状态）
//!      * PWE 派生（hunting and pecking，12.4.4.2.2，1937–1939）
//!      * rand / mask（12.4.5.2，1942）与 Commit 构造（12.4.5.3，1942）
//!      * 对端 Commit 的处理：校验、K = rand·(pcs·PWE + PCE)、k = F(K)（12.4.5.4，1942–1943）
//!      * keyseed / KCK / PMK / PMKID 与 Confirm 的 CN 复用 `sae.zig`（12.4.5.4–12.4.5.6，1943）
//!   2. 帧体编解码（12.4.7，1944–1946；表 9-36，732–735）
//!   3. 协议实例的状态机（12.4.8.2.2、12.4.8.3.2、12.4.8.5.2、12.4.8.6.2–12.4.8.6.6，1947–1953）
//!   4. 父进程（12.4.6、12.4.8.6.1，1943–1944、1949–1950）：实例表、Open 计数、Anti-Clogging Token
//!
//! # 群的集合
//!
//! `Groups(ids)` 给出一整套类型：`ids` 是配置的群（12.4.4.1 的 dot11RSNAConfigDLCGroup 表），
//! 按优先序排列，第 0 项最优先（2016 只说「Configured groups are prioritized in ascending order
//! of preference」，正文 100622–100624；谁最优先是本地策略，这是本实现的约定）。文件头的
//! `Instance`、`Parent`、`decode` 等是只配置了 group 19 的那一组 `Default`。
//!
//! 群协商按 2016 的状态机走，没有 Rejected Groups 元素（2016 全文没有它）：
//!   * 对端给的群不支持（BadGrp）：Nothing 态回状态 77 并 Del（12.4.8.6.3，101319–101326）；
//!     Committed 态 Sync 超限就 Del，否则 Sync 加一、回 77、留在 Committed（12.4.8.6.4，101353–101361）。
//!     77 的 Commit 帧里群字段填被拒的群（12.4.7.6，101072–101080）。
//!   * 被对端用 77 拒掉的群正是我们提供的：配置里还有没提供过的群（moregroups，101244）
//!     就换一个，重新生成 PWE 与秘密值，发新 Commit，Sync 清零（12.4.8.6.4，101343–101350）；
//!     没有就 Del。被拒的群不是我们提供的：静默丢弃，重设 t0。
//!   * 对端给的群受支持但与我们的不同（DiffGrp，101368–101378）：本机 MAC 数值较大的一端丢弃
//!     并重发上一个 Commit；较小的一端换成对端的群，重新生成，处理对端的 Commit，发新 Commit
//!     与 Confirm，进 Confirmed。
//!   * Confirmed 态收到的 Commit 群与之前的不同：静默丢弃（12.4.8.6.5，101404–101406）。
//!
//! # Password Identifier（2016 无此条款，依据 hostap 源码）
//!
//! 802.11-2016 全文没有 Password Identifier。下面的字节布局、携带方式与校验规则都取自盘上的
//! hostap（`~/esp/esp-idf/components/wpa_supplicant/`）：
//!   * 元素 = Element ID 255 || Length || 扩展 ID 33 || 标识符（common/sae.c:1659–1667；
//!     常数在 common/ieee802_11_defs.h:250、268）。
//!   * 只在 Commit 帧里、放在元素之后（common/sae.c:1622–1667）；Confirm 帧不带
//!     （common/sae.c:2303–2338）；Anti-Clogging Token 请求（状态 76）也不带（ap/comeback_token.c:100–124）。
//!   * 校验（common/sae.c:1994–2039）：本端配置了标识而帧里没有、或与配置的不同，都是
//!     「不认识这个口令标识」（状态码 UNKNOWN_PASSWORD_IDENTIFIER = 123，
//!     common/ieee802_11_defs.h:169）。hostapd 此时静默丢弃并删掉该 STA 的状态
//!     （ap/ieee802_11.c:571–576）；本实现同样静默丢弃并结束实例。hostapd 在自己的 Commit 里
//!     回显收到的标识（ap/ieee802_11.c:70–112）。
//!
//! token 有没有、多长，由总长反推（12.4.6，正文 100979–100981）。群字段之后除了 scalar 与元素
//! 还多出来的字节，本实现先看尾部是不是恰好一个 Password Identifier 元素（元素在最后：
//! common/sae.c:1659–1667），是就把它前面的当 token，否则全部都是 token。
//! hostap 的推断更粗：剩下不少于 32 字节就全当 token（common/sae.c:1806–1818），所以 hostap
//! 非 H2E 时 token 与 Password Identifier 不能同时出现。hostap 能解析的帧本实现解析结果相同，
//! 反过来不成立。残留的歧义：只带 token 的帧，token 里恰好出现「255、长度、0x21」且长度
//! 正好对上时（32 字节的随机 token 约 2×10⁻⁶）会被当成带元素，结果是 token 对不上、帧被丢，
//! 对端重传后仍如此，直到这一次认证超时重来。
//!
//! # Rejected Groups（2016 无此条款，依据 hostap 源码）
//!
//! 元素 = Element ID 255 || Length || 扩展 ID 92 || 群号的 LE16 序列（common/sae.c:1672–1676；
//! 常数在 common/ieee802_11_defs.h:271）。hostap 里它只跟 H2E 一起用：发的时候要 `sae->h2e`
//! （common/sae.c:1669），收的时候只从状态码 126 的 Commit 里解析（ap/ieee802_11.c:562–563 把
//! 它当 sae_parse_commit() 的 h2e 参数；common/sae.c:2144–2152）。本组件不做 H2E，所以只实现收的
//! 一半；本端发的 Commit 不带它，状态 0 的帧里这些字节照旧按 token 处理。
//!   * 状态码 126 的 Commit：scalar 与 element 之后依次是可选的 Password Identifier 元素、
//!     可选的 Rejected Groups 元素（common/sae.c:2139–2148）。Length 小于 1 或载荷是奇数个
//!     八位组，解码失败（2059–2068）。
//!   * 对端的列表里只要有一个群是本端启用的，就回一个状态 1 的 Commit（ap/ieee802_11.c:456–493、
//!     589–592），然后照常处理这一帧。hostap 没有「按对端列表重选群」的逻辑，77 之后换群仍走
//!     2016 的 12.4.8.6.4。
//!
//! 没做的：H2E（含只在 H2E 下才变的 keyseed 的盐，common/sae.c:1499–1528；token 容器与 AKM
//! Suite Selector 元素）、恒定时间、本端发送 Rejected Groups 元素，见 `sae.zig` 的 `unimplemented` 表。
//!
//! 随机数与发帧都由调用方注入（`Random`、`Sink`），本文件不读硬件、不分配堆内存。
//! 时间是毫秒。本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

const ecc = @import("ecc.zig");
const sae = @import("sae.zig");
const groups = @import("sae_groups.zig");

// ---------------------------------------------------------------------------
// 与群无关的常量
// ---------------------------------------------------------------------------

/// 文件头那一份（`Default`）唯一配置的 finite cyclic group：19 = P-256。
pub const group: u16 = 19;
/// Authentication Algorithm Number = 3（SAE，表 9-36）。
pub const algorithm: u16 = 3;
/// Commit 的事务序号是 1，Confirm 是 2（12.4.7.3）。
pub const seq_commit: u16 = 1;
pub const seq_confirm: u16 = 2;

/// 状态码（表 9-46；12.4.7.6）。
pub const status_success: u16 = 0;
pub const status_challenge_failure: u16 = 15;
pub const status_token_required: u16 = 76;
pub const status_group_not_supported: u16 = 77;

/// 帧体开头三个字段：算法(2) || 事务序号(2) || 状态(2)，都是小端（表 9-35）。
pub const header_len = 6;
const group_len = 2;
/// Confirm 帧体长度。
pub const confirm_body_len = header_len + sae.send_confirm_len + sae.hash_len;
/// Anti-Clogging Token 的上限（12.4.6 的建议值，正文 100971：「not exceed 256 octets」）；更长的 token 解码失败。
pub const token_max_len = 256;
/// 进入 Accepted 时 Sc 的取值（12.4.8.6.5）。
pub const sc_accepted: u16 = 0xffff;
/// rand / mask 最多重取这么多次（每次取 2m 个随机八位组）。
pub const secret_attempts = 8;

/// 取随机数：把 `out` 填满。逻辑模块不读硬件，由调用方注入。
pub const Random = *const fn (out: []u8) void;

/// 发帧的回调。`body` 是 Authentication 帧体（不含 MAC 头），离开回调后失效。
pub const Sink = struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, peer: [6]u8, body: []const u8) void,
};

// ---------------------------------------------------------------------------
// Password Identifier 元素的编解码（802.11-2016 无此条款；依据 hostap，见文件头）
// ---------------------------------------------------------------------------

/// Element ID 255（hostap ieee802_11_defs.h:250）。
pub const password_id_eid: u8 = 255;
/// 扩展 ID 33（hostap ieee802_11_defs.h:268；十进制 33，线上是 0x21）。
pub const password_id_ext_id: u8 = 33;
/// 标识符最多 254 个八位组：长度字段 1 个八位组（hostap sae.c:1662），去掉扩展 ID。
pub const password_id_max_len: usize = 254;
/// 元素连同头的最大长度：Element ID、Length、扩展 ID 各 1 个八位组。
pub const password_id_elem_max_len: usize = 3 + password_id_max_len;

/// 把 `id` 写成一个 Password Identifier 元素（hostap sae.c:1659–1667）：
/// Element ID 255 || Length || 扩展 ID 33 || 标识符。标识符放不下时返回 null。
pub fn passwordIdElement(out: []u8, id: []const u8) ?[]u8 {
    if (id.len > password_id_max_len) return null;
    out[0] = password_id_eid;
    out[1] = @intCast(1 + id.len);
    out[2] = password_id_ext_id;
    @memcpy(out[3..][0..id.len], id);
    return out[0 .. 3 + id.len];
}

/// `buf` 是不是恰好一个 Password Identifier 元素；是就返回标识符，否则 null。
/// 判别条件照 hostap `sae_is_password_id_elem()`（common/sae.c:1746–1753）：至少 3 个八位组、
/// Element ID 255、Length ≥ 1、Length 不超出实际长度、扩展 ID 33；再加一条「正好占满」。
pub fn passwordIdOf(buf: []const u8) ?[]const u8 {
    if (buf.len < 3) return null;
    const len: usize = buf[1];
    if (buf[0] != password_id_eid or buf[2] != password_id_ext_id) return null;
    if (len < 1 or 2 + len != buf.len) return null;
    return buf[3..];
}

/// 对端 Commit 里的 Password Identifier 与本端配置是否一致（hostap sae.c:2002–2029）：
/// 本端配置了 `want` 就要求帧里带同一个；没配置就要求帧里不带。
pub fn passwordIdMatches(want: ?[]const u8, got: ?[]const u8) bool {
    if (want) |w| {
        const g = got orelse return false;
        return std.mem.eql(u8, w, g);
    }
    return got == null;
}

// ---------------------------------------------------------------------------
// Rejected Groups 元素的编解码（802.11-2016 无此条款；依据 hostap，见文件头）
// ---------------------------------------------------------------------------

/// 扩展 ID 92（hostap ieee802_11_defs.h:271）。
pub const rejected_groups_ext_id: u8 = 92;
/// 最多 127 个群：长度字段 1 个八位组，去掉扩展 ID，每个群 2 个八位组（hostap sae.c:1673–1676）。
pub const rejected_groups_max_count: usize = 127;
/// 元素连同头的最大长度：Element ID、Length、扩展 ID 各 1 个八位组。
pub const rejected_groups_elem_max_len: usize = 3 + 2 * rejected_groups_max_count;
/// 状态码 126：hostap 用它识别「对端在用 H2E」的 Commit（ieee802_11_defs.h:170）。
pub const status_sae_hash_to_element: u16 = 126;
/// 状态码 1（表 9-46）：hostap 在对端的 Rejected Groups 列表有问题时回它。
pub const status_unspecified_failure: u16 = 1;

/// 把 `list` 写成一个 Rejected Groups 元素（hostap sae.c:1672–1676）：
/// Element ID 255 || Length || 扩展 ID 92 || 群号的 LE16 序列。放不下时返回 null。
pub fn rejectedGroupsElement(out: []u8, list: []const u16) ?[]u8 {
    if (list.len > rejected_groups_max_count or out.len < 3 + 2 * list.len) return null;
    out[0] = password_id_eid;
    out[1] = @intCast(1 + 2 * list.len);
    out[2] = rejected_groups_ext_id;
    for (list, 0..) |g, i| std.mem.writeInt(u16, out[3 + 2 * i ..][0..2], g, .little);
    return out[0 .. 3 + 2 * list.len];
}

/// `buf` 开头是不是 Rejected Groups 元素（hostap sae_is_rejected_groups_elem()，common/sae.c:1756–1763）：
/// 至少 3 个八位组、Element ID 255、Length 不超出实际长度、扩展 ID 92。
pub fn isRejectedGroupsElement(buf: []const u8) bool {
    return buf.len >= 3 and buf[0] == password_id_eid and buf.len - 2 >= buf[1] and
        buf[2] == rejected_groups_ext_id;
}

pub const RejectedGroupsError = error{ RejectedGroupsLength, RejectedGroupsOdd };

/// 解析帧尾的 Rejected Groups 元素（hostap sae_parse_rejected_groups()，common/sae.c:2056–2078）。
/// Length 小于 1 或超出帧尾报 RejectedGroupsLength（2059–2060）；载荷长度是奇数报
/// RejectedGroupsOdd（2064–2068）。空列表是合法的。调用方先用 `isRejectedGroupsElement` 判别。
pub fn rejectedGroupsOf(buf: []const u8) RejectedGroupsError!struct { list: []const u8, rest: []const u8 } {
    if (buf.len < 3) return error.RejectedGroupsLength;
    const len: usize = buf[1];
    if (len > buf.len - 2 or len < 1) return error.RejectedGroupsLength;
    const payload = buf[3 .. 2 + len];
    if (payload.len & 1 != 0) return error.RejectedGroupsOdd;
    return .{ .list = payload, .rest = buf[2 + len ..] };
}

/// 对端列表里的每个群都必须是本端没有启用的（hostap check_sae_rejected_groups()，
/// ap/ieee802_11.c:456–493）：有一个是 `enabled` 里的就返回那个群（488–489 返回 1 的那一步）；
/// 列表长度是奇数同样不过（471–476）。空列表通过。
pub fn rejectedGroupsOffending(list: []const u8, enabled: []const u16) RejectedGroupsError!?u16 {
    if (list.len & 1 != 0) return error.RejectedGroupsOdd;
    var i: usize = 0;
    while (i < list.len) : (i += 2) {
        const g = std.mem.readInt(u16, list[i..][0..2], .little);
        for (enabled) |e| {
            if (e == g) return g;
        }
    }
    return null;
}

/// 配置的标识符能放进元素。
fn passwordIdFits(want: ?[]const u8) bool {
    const w = want orelse return true;
    return w.len <= password_id_max_len;
}

// ---------------------------------------------------------------------------
// 1) group 19（P-256）的协议核心：现有调用方用的那一份
// ---------------------------------------------------------------------------

pub const Pwe = struct {
    point: ecc.Point,
    /// 停在第几个 counter。
    counter: u8,
    seed: [sae.hash_len]u8,
};

pub const PweError = error{NotFound};

fn pwdValueOf(seed: [sae.hash_len]u8, counter: u8) [sae.hash_len]u8 {
    _ = counter;
    return sae.pwdValue(seed);
}

/// hunting and pecking（12.4.4.2.2，印刷页 1937–1939）：
///
///   pwd-seed  = H(MAX||MIN, password || counter)，counter 一个八位组，从 1 起
///   pwd-value = KDF-Hash-Length(pwd-seed, "SAE Hunting and Pecking", p)
///   pwd-value >= p 或曲线上没有这个 x：counter 加 1 重来
///   y = sqrt(x³ + ax + b)；pwd-seed 的最低位与 y 的奇偶相同取 (x, y)，否则取 (x, p − y)
///
/// 找到就停（规范「应该」至少跑 k 轮来遮掩轮数，本实现没做，见 `sae.zig` 的
/// `unimplemented`）。循环本身在 `sae_groups.zig`，这里的 counter 是一个八位组，最多到 255。
pub fn derivePwe(own_mac: [6]u8, peer_mac: [6]u8, password: []const u8) PweError!Pwe {
    return derivePweWith(pwdValueOf, own_mac, peer_mac, password);
}

/// 同上，但 pwd-value 由 `pwdValueFn` 算（测试用它把前几轮伪造成 >= p，好走到
/// 「counter 加 1 重来」的分支；正常实现是 `sae.pwdValue`）。
pub fn derivePweWith(
    comptime pwdValueFn: fn (seed: [sae.hash_len]u8, counter: u8) [sae.hash_len]u8,
    own_mac: [6]u8,
    peer_mac: [6]u8,
    password: []const u8,
) PweError!Pwe {
    var buf: [sae.element_len]u8 = undefined;
    const counter = groups.huntHooked(.ecc_19, pwdValueFn, own_mac, peer_mac, password, &buf) catch return error.NotFound;
    const point = ecc.fromBytes(&buf) orelse return error.NotFound;
    return .{ .point = point, .counter = counter, .seed = sae.pwdSeedOctet(own_mac, peer_mac, password, counter) };
}

pub const Secrets = struct {
    rand: [sae.scalar_len]u8,
    mask: [sae.scalar_len]u8,
};

pub const RandomError = error{RandomExhausted};

/// 1 < s < r。
fn scalarInStrictRange(s: sae.U256) bool {
    const one = blk: {
        var v: sae.U256 = @splat(0);
        v[31] = 1;
        break :blk v;
    };
    return sae.cmp(s, one) == .gt and sae.cmp(s, sae.order) == .lt;
}

/// 0 < s < r：12.4.5.4 对对端 commit-scalar 的要求。
fn scalarValid(s: sae.U256) bool {
    const zero: sae.U256 = @splat(0);
    return sae.cmp(s, zero) == .gt and sae.cmp(s, sae.order) == .lt;
}

/// rand 与 mask（12.4.5.2）：1 < rand < r、1 < mask < r，且 (rand + mask) mod r > 1；
/// 不满足就都丢掉重取。每次从 `random` 取 64 字节，按大整数对 r 取模。
/// 连续 `secret_attempts` 次都不行报 RandomExhausted（随机源正常时碰不到）。
pub fn generateSecrets(random: Random) RandomError!Secrets {
    var draw: [2 * sae.scalar_len]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < secret_attempts) : (attempt += 1) {
        random(&draw);
        const s = Secrets{
            .rand = sae.modQ(draw[0..sae.scalar_len].*),
            .mask = sae.modQ(draw[sae.scalar_len..].*),
        };
        const sum = sae.scalarAddModQ(s.rand, s.mask);
        if (scalarInStrictRange(s.rand) and scalarInStrictRange(s.mask) and scalarInStrictRange(sum)) {
            return s;
        }
    }
    return error.RandomExhausted;
}

pub const Commit = struct {
    scalar: [sae.scalar_len]u8,
    element: [sae.element_len]u8,
};

/// 12.4.5.3：commit-scalar = (rand + mask) mod r，
/// COMMIT-ELEMENT = inverse(scalar-op(mask, PWE))。
pub fn buildCommit(secrets: Secrets, pwe: ecc.Point) Commit {
    return .{
        .scalar = sae.scalarAddModQ(secrets.rand, secrets.mask),
        .element = ecc.mul(secrets.mask, pwe).neg().toBytes(),
    };
}

pub const CommitError = error{ Scalar, Element, Identity };

/// 12.4.5.4：校验对端的 commit 并算 k = F(K)，其中
/// K = scalar-op(rand, elem-op(scalar-op(peer-commit-scalar, PWE), PEER-COMMIT-ELEMENT))。
///
/// scalar 不在 (0, r) 内报 Scalar；元素解不出来（坐标为 0 或不小于 p、不在曲线上）
/// 报 Element；K 是无穷远点报 Identity。
pub fn processCommit(
    rand: [sae.scalar_len]u8,
    pwe: ecc.Point,
    peer_scalar: [sae.scalar_len]u8,
    peer_element: [sae.element_len]u8,
) CommitError![sae.scalar_len]u8 {
    if (!scalarValid(peer_scalar)) return error.Scalar;
    const peer_point = ecc.fromBytes(&peer_element) orelse return error.Element;
    const big_k = ecc.mul(rand, ecc.add(ecc.mul(peer_scalar, pwe), peer_point));
    if (big_k.isInfinity()) return error.Identity;
    return big_k.xBytes();
}

// ---------------------------------------------------------------------------
// 2) 与群无关的秘密值与定时
// ---------------------------------------------------------------------------

/// 标量是否大于 1。调用方保证它已经小于 r。
fn aboveOne(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s[0 .. s.len - 1]) |b| {
        if (b != 0) return true;
    }
    return s[s.len - 1] > 1;
}

/// rand 与 mask（12.4.5.2，任意群）：各取 m 个随机八位组对 r 取模，再查
/// 1 < rand < r、1 < mask < r、(rand + mask) mod r > 1，不满足就都丢掉重取。
/// 连续 `secret_attempts` 次都不行报 RandomExhausted。
///
/// 结果：`buf[0..m]` 是 rand，`buf[m..2m]` 是 mask，`buf[2m..3m]` 是算和用的暂存；
/// `buf` 至少要有 3m 个八位组。`order` 是群的阶 r（m 个八位组），由调用方按配置的群取。
fn drawSecrets(order: []const u8, buf: []u8, random: Random) RandomError!void {
    const m: usize = order.len;
    std.debug.assert(buf.len >= 3 * m);
    var attempt: usize = 0;
    while (attempt < secret_attempts) : (attempt += 1) {
        random(buf[0 .. 2 * m]);
        groups.scalarReduceWith(order, buf[0..m]);
        groups.scalarReduceWith(order, buf[m .. 2 * m]);
        const sum = buf[2 * m .. 3 * m];
        groups.scalarAddWith(order, buf[0..m], buf[m .. 2 * m], sum);
        if (aboveOne(buf[0..m]) and aboveOne(buf[m .. 2 * m]) and aboveOne(sum)) return;
    }
    return error.RandomExhausted;
}

// ---------------------------------------------------------------------------
// 3) 状态机各处共用的类型
// ---------------------------------------------------------------------------

/// 12.4.8.2.2 的四个状态。
pub const State = enum { nothing, committed, confirmed, accepted };

/// 12.4.8.4 的两个定时器：t0 重传，t1 密钥过期。
pub const Timer = enum { t0, t1 };

/// 实例发给父进程的事件（12.4.8.3.1）。
pub const Signal = enum {
    /// 对端认证通过。
    auth,
    /// 对端认证失败。
    fail,
    /// 实例遇到致命事件。
    del,
};

/// 一个事件处理完的结果：要么原文要求的「静默丢弃」，要么实例发给父进程的信号。
pub const Result = enum { ok, discarded, auth, fail, del };

/// 定时与上限。默认值取 Annex C 的 DEFVAL（印刷页 2840）：dot11RSNASAERetransPeriod 是
/// 40（毫秒），dot11RSNASAESync 是 5。dot11RSNAConfigPMKLifetime 的定义在 2016 的
/// Annex C 里被省略，没查到默认值，12 h 是本实现的取值。
pub const Timing = struct {
    /// t0 的时长，毫秒（dot11RSNASAERetransPeriod）。
    retrans_period_ms: u32 = 40,
    /// Sync 超过它就放弃（dot11RSNASAESync）。
    sync_max: u16 = 5,
    /// t1 的时长，毫秒（dot11RSNAConfigPMKLifetime）。
    pmk_lifetime_ms: u64 = 43_200_000,
};

/// 实例运行所需的外部条件，由调用方（通常是父进程）持有一份。
pub const Env = struct {
    own_mac: [6]u8,
    /// 口令的 ASCII 字节（12.4.3）；调用方保证它在实例的整个生命周期内有效。
    password: []const u8,
    /// 口令的 Password Identifier（可选，最多 254 个八位组）。设了就写进自己的 Commit，并要求
    /// 对端的 Commit 带同一个；不设则要求对端不带（hostap sae.c:2002–2029；2016 无此条款）。
    /// 调用方保证它在实例的整个生命周期内有效。
    password_id: ?[]const u8 = null,
    random: Random,
    emit: Sink,
    timing: Timing = .{},
};

/// 最后一次发出的 Commit。重传时「把最后发出去的 Commit 再发一遍」。
const Last = union(enum) {
    /// 自己的 commit-scalar / COMMIT-ELEMENT（带收到的 token）。
    offer,
    /// 拒绝对端给的群（状态 77）。
    unsupported_group: u16,
};

/// Commit 帧的前 8 个字节：头部 + 群字段。返回写了几个八位组。
fn putCommitHeader(out: []u8, status: u16, g: u16) usize {
    putHeader(out[0..header_len], seq_commit, status);
    std.mem.writeInt(u16, out[header_len..][0..group_len], g, .little);
    return header_len + group_len;
}

fn putHeader(out: *[header_len]u8, seq: u16, status: u16) void {
    std.mem.writeInt(u16, out[0..2], algorithm, .little);
    std.mem.writeInt(u16, out[2..4], seq, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
}

// ---------------------------------------------------------------------------
// 4) 一组配置的群：帧体编解码、协议实例、父进程
// ---------------------------------------------------------------------------

/// 配置了 `ids` 这些群的 SAE（12.4.4.1 的 dot11RSNAConfigDLCGroup 表）。`ids` 按优先序
/// 给出，第 0 项最优先，不重复，1 到 32 个。
///
/// 实例的缓冲按 `ids` 里最长的群开，同一套类型可以跑其中任何一个群；群在实例里是运行时
/// 才知道的（`Instance.group`），算法按它分派到 `sae_groups.zig`。
/// 只配置 group 19 时 `Instance` 沿用 `ecc.Point` 与 32 / 64 字节的定长数组（现有 API）。
pub fn Groups(comptime ids: []const groups.Id) type {
    comptime {
        if (ids.len == 0 or ids.len > 32) @compileError("一次配置 1 到 32 个群");
        for (ids, 0..) |id, i| {
            for (ids[0..i]) |prev| {
                if (prev == id) @compileError("配置的群不能重复");
            }
        }
    }
    const max_prime: usize = comptime blk: {
        var n: usize = 0;
        for (ids) |id| n = @max(n, @as(usize, groups.params(id).prime_len));
        break :blk n;
    };
    const max_elem: usize = comptime blk: {
        var n: usize = 0;
        for (ids) |id| n = @max(n, @as(usize, groups.params(id).element_len));
        break :blk n;
    };
    // 只配置 group 19：实例沿用 `ecc.Point`（现有 API）。
    const legacy = ids.len == 1 and ids[0] == .ecc_19;
    const Elem = if (legacy) ecc.Point else [max_elem]u8;
    // 「没有元素」：P-256 是无穷远点，其余是全 0。
    const elem_zero: Elem = if (legacy) .{} else @splat(0);

    return struct {
        const Self = @This();

        pub const group_list = ids;
        /// 配置表里最优先的群：发起时用它（12.4.8.6.3 的 select a group from local configuration）。
        pub const most_preferred = ids[0];
        /// 标量（也是素数）在全部群里的最大八位组数。
        pub const scalar_len: usize = max_prime;
        pub const element_len: usize = max_elem;
        /// 不带 token 的 Commit 帧体长度。
        pub const commit_body_len: usize = header_len + group_len + scalar_len + element_len;
        pub const confirm_body_len: usize = header_len + sae.send_confirm_len + sae.hash_len;
        /// 帧体最大长度：带满 token 与 Password Identifier 元素的 Commit。
        pub const body_max_len: usize = Self.commit_body_len + token_max_len + password_id_elem_max_len;

        /// 收到的 Commit（事务序号 1）。
        pub const CommitMsg = struct {
            status: u16,
            /// Finite Cyclic Group 字段。状态不是 0 或 76 时帧里可以没有（表 9-36）。
            group: ?u16 = null,
            token: []const u8 = &.{},
            /// 群在配置表里、帧足够长时才有；帧太短时是 null（等于校验失败）。
            /// 有效长度是群的素数 / 元素的八位组数，其余补 0。
            scalar: ?[scalar_len]u8 = null,
            element: ?[element_len]u8 = null,
            /// Password Identifier 元素里的标识符（hostap sae.c:2139–2142）；帧里没有这个元素时是 null。
            password_id: ?[]const u8 = null,
            /// Rejected Groups 元素里的群号列表（每群 2 个八位组，小端）；只有状态码 126 的 Commit
            /// 才解析它（hostap sae.c:2144–2148）。帧里没有这个元素时是 null。
            rejected_groups: ?[]const u8 = null,
        };

        /// 收到的 Confirm（事务序号 2）。
        pub const ConfirmMsg = struct {
            status: u16,
            send_confirm: u16 = 0,
            confirm: [sae.hash_len]u8 = @splat(0),
        };

        pub const DecodeError = error{ TooShort, NotSae, BadSequence, BadLength, TokenTooLong, RejectedGroupsLength, RejectedGroupsOdd };

        pub const Decoded = union(enum) { commit: Self.CommitMsg, confirm: Self.ConfirmMsg };

        /// `g` 在配置表里就是它，否则 null。
        pub fn configured(g: u16) ?groups.Id {
            for (group_list) |id| {
                if (@backingInt(id) == g) return id;
            }
            return null;
        }

        /// 配置的群号（线上是 2 个八位组的小端整数），给 Rejected Groups 列表的检查用。
        const group_numbers = blk: {
            var out: [group_list.len]u16 = undefined;
            for (group_list, 0..) |id, i| out[i] = @backingInt(id);
            break :blk out;
        };

        /// 配置表里的下标。
        fn indexOf(id: groups.Id) usize {
            for (group_list, 0..) |x, i| {
                if (x == id) return i;
            }
            unreachable;
        }

        /// 解析 Authentication 帧体（表 9-35、表 9-36）。元素之后怎么收尾见文件头。
        pub fn decode(body: []const u8) Self.DecodeError!Self.Decoded {
            if (body.len < header_len) return error.TooShort;
            const alg = std.mem.readInt(u16, body[0..2], .little);
            const seq = std.mem.readInt(u16, body[2..4], .little);
            const status = std.mem.readInt(u16, body[4..6], .little);
            if (alg != algorithm) return error.NotSae;
            switch (seq) {
                seq_commit => {
                    var msg = Self.CommitMsg{ .status = status };
                    // 状态码 126 标记对端在用 H2E，只有这种 Commit 才带 Rejected Groups 元素
                    // （hostap ap/ieee802_11.c:562–563 把它作为 sae_parse_commit() 的 h2e 参数）
                    const h2e = status == status_sae_hash_to_element;
                    // Commit：群字段只在状态为 0 或 76 时必带（表 9-36）
                    if (status != status_success and status != status_token_required and !h2e) {
                        if (body.len >= header_len + group_len) {
                            msg.group = std.mem.readInt(u16, body[6..8], .little);
                        }
                        return .{ .commit = msg };
                    }
                    if (body.len < header_len + group_len) return error.TooShort;
                    msg.group = std.mem.readInt(u16, body[6..8], .little);
                    const rest = body[header_len + group_len ..];
                    if (status == status_token_required) {
                        if (rest.len > token_max_len) return error.TokenTooLong;
                        msg.token = rest;
                        return .{ .commit = msg };
                    }
                    const id = configured(msg.group.?) orelse {
                        // 别的群的 scalar / element 有多长不知道，不往下解析
                        return .{ .commit = msg };
                    };
                    const p = groups.params(id);
                    const se_len: usize = p.prime_len + p.element_len;
                    if (rest.len < se_len) return .{ .commit = msg };
                    if (h2e) return .{ .commit = try decodeH2eTail(msg, p, rest) };
                    // 多出来的字节：token（12.4.6：有没有、多长由总长反推），或者 token 再跟一个
                    // Password Identifier 元素。元素在最后，所以从短到长试「尾部 t 个八位组是不是
                    // 恰好一个元素」；都不是就全是 token。见文件头。
                    const extra = rest.len - se_len;
                    var token_len: usize = extra;
                    var t: usize = 3;
                    while (t <= extra) : (t += 1) {
                        const s = se_len + extra - t;
                        if (rest[s] == password_id_eid and rest[s + 1] >= 1 and
                            @as(usize, rest[s + 1]) + 2 == t and rest[s + 2] == password_id_ext_id)
                        {
                            token_len = extra - t;
                            break;
                        }
                    }
                    // 超过 token 的上限解码失败
                    if (token_len > token_max_len) return error.TokenTooLong;
                    msg.token = rest[0..token_len];
                    if (token_len != extra) msg.password_id = rest[se_len + token_len + 3 ..];
                    const fields = rest[token_len..][0..se_len];
                    msg.scalar = @splat(0);
                    @memcpy(msg.scalar.?[0..p.prime_len], fields[0..p.prime_len]);
                    msg.element = @splat(0);
                    @memcpy(msg.element.?[0..p.element_len], fields[p.prime_len..][0..p.element_len]);
                    return .{ .commit = msg };
                },
                seq_confirm => {
                    const msg = Self.ConfirmMsg{ .status = status };
                    // 拒绝用的 Confirm 只有头部；带 CN 的 Confirm 长度固定（表 9-36）
                    if (status != status_success) return .{ .confirm = msg };
                    if (body.len != Self.confirm_body_len) return error.BadLength;
                    return .{ .confirm = .{
                        .status = status,
                        .send_confirm = std.mem.readInt(u16, body[6..8], .little),
                        .confirm = body[8..][0..sae.hash_len].*,
                    } };
                },
                else => return error.BadSequence,
            }
        }

        /// 状态码 126 的 Commit 在群字段之后的部分（hostap sae.c:2126–2156）：scalar、element、
        /// 可选的 Password Identifier 元素（2139–2142）、可选的 Rejected Groups 元素（2144–2148）。
        /// H2E 的帧里 token 在容器元素里，没有裸的 token 字段（1797–1798）；token 容器与
        /// AKM Suite Selector 元素本实现不解析。调用方保证 `rest` 不少于 scalar 加 element。
        fn decodeH2eTail(msg_in: Self.CommitMsg, p: groups.Params, rest: []const u8) Self.DecodeError!Self.CommitMsg {
            var msg = msg_in;
            msg.scalar = @splat(0);
            @memcpy(msg.scalar.?[0..p.prime_len], rest[0..p.prime_len]);
            msg.element = @splat(0);
            @memcpy(msg.element.?[0..p.element_len], rest[p.prime_len..][0..p.element_len]);
            var tail = rest[p.prime_len + p.element_len ..];
            if (tail.len >= 3 and tail[0] == password_id_eid and tail[1] >= 1 and
                @as(usize, tail[1]) + 2 <= tail.len and tail[2] == password_id_ext_id)
            {
                const n = 2 + @as(usize, tail[1]);
                msg.password_id = tail[3..n];
                tail = tail[n..];
            }
            // 不是这个元素就没有列表（2050–2054）
            if (isRejectedGroupsElement(tail)) {
                msg.rejected_groups = (try rejectedGroupsOf(tail)).list;
            }
            return msg;
        }

        /// 拼一个 Commit 帧体：头部 || 群 || token || scalar || element || [Password Identifier 元素]
        /// （12.4.7.4；元素的位置见文件头）。返回帧体长度；`password_id` 放不下时返回 null。
        pub fn encodeOffer(out: []u8, id: groups.Id, token: []const u8, scalar: []const u8, element: []const u8, password_id: ?[]const u8) ?usize {
            const p = groups.params(id);
            var n = putCommitHeader(out, status_success, @backingInt(id));
            @memcpy(out[n..][0..token.len], token);
            n += token.len;
            @memcpy(out[n..][0..p.prime_len], scalar[0..p.prime_len]);
            n += p.prime_len;
            @memcpy(out[n..][0..p.element_len], element[0..p.element_len]);
            n += p.element_len;
            if (password_id) |want| {
                const e = passwordIdElement(out[n..], want) orelse return null;
                n += e.len;
            }
            return n;
        }

        /// 状态 76 或 77 的 Commit 帧体：头部 || 群 || [token]（12.4.7.6）。
        pub fn encodeStatusCommit(out: []u8, status: u16, g: u16, token: []const u8) usize {
            const n = putCommitHeader(out, status, g);
            @memcpy(out[n..][0..token.len], token);
            return n + token.len;
        }

        /// Confirm 帧体：头部 || send-confirm || CN（12.4.7.5）。
        pub fn encodeConfirm(out: *[Self.confirm_body_len]u8, send_confirm: u16, confirm: [sae.hash_len]u8) void {
            putHeader(out[0..header_len], seq_confirm, status_success);
            std.mem.writeInt(u16, out[6..8], send_confirm, .little);
            out[8..].* = confirm;
        }

        /// 一个协议实例：本机 MAC 与对端 MAC 各一份（12.4.8.1）。
        /// 只配置 group 19 时约 1.2 KiB，放静态区。
        pub const Instance = struct {
            env: *const Env = undefined,
            peer_mac: [6]u8 = @splat(0),
            state: State = .nothing,
            /// 这个实例当前用的群：发起时取最优先的，响应时取对端给的。
            group: groups.Id = most_preferred,
            /// 已经向对端提供过的群：配置表下标 i 对应第 i 位。
            offered: u32 = 0,

            /// 状态重同步的次数。
            sync: u16 = 0,
            /// 已发出的 Confirm 个数，也就是 Confirm 里的 send-confirm。
            sc: u16 = 0,
            /// 最近一次收到的 Confirm 里的 send-confirm。
            rc: u16 = 0,

            t0_at: u64 = 0,
            t0_armed: bool = false,
            t1_at: u64 = 0,
            t1_armed: bool = false,

            pwe: Elem = elem_zero,
            rand: [scalar_len]u8 = @splat(0),
            own_scalar: [scalar_len]u8 = @splat(0),
            own_element: Elem = elem_zero,
            peer_scalar: [scalar_len]u8 = @splat(0),
            peer_element: Elem = elem_zero,
            kck: [sae.kck_len]u8 = @splat(0),
            pmk: [sae.pmk_len]u8 = @splat(0),
            pmkid: [sae.pmkid_len]u8 = @splat(0),

            /// 收到的 Anti-Clogging Token，重发 Commit 时原样带回。
            token_len: u16 = 0,
            token: [token_max_len]u8 = undefined,
            last: Last = .offer,

            // ---- 群与元素的存取 ----

            fn paramsOf(self: *const Self.Instance) groups.Params {
                return groups.params(self.group);
            }

            /// 把一个群的元素（`bytes` 的长度就是它的元素长度）存进实例。
            fn setElem(dst: *Elem, bytes: []const u8) !void {
                if (legacy) {
                    dst.* = ecc.fromBytes(bytes[0..sae.element_len]) orelse return error.InvalidCommit;
                } else {
                    dst.* = @splat(0);
                    @memcpy(dst[0..bytes.len], bytes);
                }
            }

            /// 实例里的元素，按当前群的元素长度取。
            fn elemSlice(e: *const Elem, n: usize, scratch: *[element_len]u8) []const u8 {
                if (legacy) {
                    scratch.* = e.toBytes();
                    return scratch[0..n];
                }
                return e[0..n];
            }

            /// 自己的 commit-scalar，按当前群的素数长度取。
            fn ownScalar(self: *const Self.Instance) []const u8 {
                return self.own_scalar[0..self.paramsOf().prime_len];
            }

            /// 对端的 commit-scalar。
            fn peerScalar(self: *const Self.Instance) []const u8 {
                return self.peer_scalar[0..self.paramsOf().prime_len];
            }

            /// 本机 MAC 是否在数值上大于对端（12.4.8.5.2 的 highmac）。
            fn highMac(self: *const Self.Instance) bool {
                return std.mem.order(u8, &self.env.own_mac, &self.peer_mac) == .gt;
            }

            /// 配置里还有没有没向对端提供过的群（12.4.8.5.2 的 moregroups）。
            fn nextGroup(self: *const Self.Instance) ?groups.Id {
                for (group_list, 0..) |id, i| {
                    if (self.offered & (@as(u32, 1) << @intCast(i)) == 0) return id;
                }
                return null;
            }

            // ---- 定时器（12.4.8.4、12.4.8.6.2）----

            fn bigSync(self: *const Self.Instance) bool {
                return self.sync > self.env.timing.sync_max;
            }

            fn arm(self: *Self.Instance, timer: Timer, now_ms: u64) void {
                switch (timer) {
                    .t0 => {
                        self.t0_at = now_ms + self.env.timing.retrans_period_ms;
                        self.t0_armed = true;
                    },
                    .t1 => {
                        self.t1_at = now_ms + self.env.timing.pmk_lifetime_ms;
                        self.t1_armed = true;
                    },
                }
            }

            fn disarm(self: *Self.Instance, timer: Timer) void {
                switch (timer) {
                    .t0 => self.t0_armed = false,
                    .t1 => self.t1_armed = false,
                }
            }

            /// 「静默丢弃并重设 t0」。
            fn waitT0(self: *Self.Instance, now_ms: u64) Result {
                self.arm(.t0, now_ms);
                return .discarded;
            }

            /// 实例结束：清掉全部秘密回到 Nothing，把信号交给父进程。
            fn die(self: *Self.Instance, signal: Signal) Result {
                std.debug.assert(signal != .auth);
                self.* = .{ .env = self.env };
                return switch (signal) {
                    .fail => .fail,
                    .del => .del,
                    .auth => unreachable,
                };
            }

            // ---- 输出 1(N) 与 2（12.4.8.3.2）----

            /// 1(N)：发 Commit。内容取自 `last`。
            fn sendCommit(self: *Self.Instance) void {
                var body: [Self.body_max_len]u8 = undefined;
                switch (self.last) {
                    .offer => {
                        // 群 || token || scalar || element || [Password Identifier 元素]
                        var scratch: [element_len]u8 = undefined;
                        const n = self.paramsOf().element_len;
                        const len = Self.encodeOffer(&body, self.group, self.token[0..self.token_len], self.ownScalar(), elemSlice(&self.own_element, n, &scratch), self.env.password_id) orelse return;
                        self.emitBody(body[0..len]);
                    },
                    .unsupported_group => |g| {
                        // 群字段填被拒绝的群（12.4.8.6.3、12.4.8.6.4）
                        const len = Self.encodeStatusCommit(&body, status_group_not_supported, g, &.{});
                        self.emitBody(body[0..len]);
                    },
                }
            }

            /// 回一个只有帧头的 Commit：状态 1（hostap ap/ieee802_11.c:676–692；回的状态不是 77，
            /// 所以不带群字段）。
            fn sendUnspecifiedFailure(self: *Self.Instance) void {
                var body: [header_len + group_len]u8 = undefined;
                _ = putCommitHeader(&body, status_unspecified_failure, 0);
                self.emitBody(body[0..header_len]);
            }

            /// 2：发 Confirm：send-confirm(2) || CN（12.4.7.5）。
            fn sendConfirm(self: *Self.Instance) void {
                var body: [Self.confirm_body_len]u8 = undefined;
                Self.encodeConfirm(&body, self.sc, self.confirmValue(self.sc));
                self.emitBody(&body);
            }

            /// 状态 15 的 Confirm（12.4.7.6）：对端 Confirm 没验证过时发，不带 send-confirm 与 CN。
            fn sendChallengeFailure(self: *Self.Instance) void {
                var body: [header_len]u8 = undefined;
                putHeader(&body, seq_confirm, status_challenge_failure);
                self.emitBody(&body);
            }

            fn emitBody(self: *Self.Instance, body: []const u8) void {
                self.env.emit.frame(self.env.emit.ctx, self.peer_mac, body);
            }

            /// CN(KCK, send-confirm, commit-scalar, COMMIT-ELEMENT, peer-commit-scalar,
            /// PEER-COMMIT-ELEMENT)（12.4.5.5）。标量与元素都按当前群的长度取。
            fn confirmValue(self: *const Self.Instance, send_confirm: u16) [sae.hash_len]u8 {
                var own: [element_len]u8 = undefined;
                var peer: [element_len]u8 = undefined;
                const n = self.paramsOf().element_len;
                return sae.confirmMac(self.kck, send_confirm, self.ownScalar(), elemSlice(&self.own_element, n, &own), self.peerScalar(), elemSlice(&self.peer_element, n, &peer));
            }

            /// 12.4.5.6：verifier = CN(KCK, peer-send-confirm, peer-commit-scalar,
            /// PEER-COMMIT-ELEMENT, commit-scalar, COMMIT-ELEMENT)。
            fn confirmOk(self: *const Self.Instance, msg: Self.ConfirmMsg) bool {
                var own: [element_len]u8 = undefined;
                var peer: [element_len]u8 = undefined;
                const n = self.paramsOf().element_len;
                const verifier = sae.confirmMac(self.kck, msg.send_confirm, self.peerScalar(), elemSlice(&self.peer_element, n, &peer), self.ownScalar(), elemSlice(&self.own_element, n, &own));
                return sae.verifyConfirm(verifier, msg.confirm);
            }

            // ---- 12.4.5.2–12.4.5.4 ----

            /// 按当前这个群生成 PWE 与秘密值，再构造自己的 commit。
            fn generate(self: *Self.Instance) !void {
                const id = self.group;
                const p = self.paramsOf();
                var pwe_buf: [element_len]u8 = undefined;
                _ = groups.dispatchIn(group_list, id, groups.huntIn, .{ self.env.own_mac, self.peer_mac, self.env.password, &pwe_buf }) catch return error.InvalidCommit;
                var s: [3 * scalar_len]u8 = undefined;
                const order = groups.dispatchIn(group_list, id, groups.orderIn, .{});
                try drawSecrets(order, &s, self.env.random);
                @memset(self.own_scalar[0..], 0);
                @memset(self.rand[0..], 0);
                groups.scalarAddWith(order, s[0..p.prime_len], s[p.prime_len .. 2 * p.prime_len], self.own_scalar[0..p.prime_len]);
                var elem_buf: [element_len]u8 = undefined;
                try groups.dispatchIn(group_list, id, groups.commitElementIn, .{ s[p.prime_len .. 2 * p.prime_len], pwe_buf[0..p.element_len], elem_buf[0..p.element_len] });
                try setElem(&self.own_element, elem_buf[0..p.element_len]);
                try setElem(&self.pwe, pwe_buf[0..p.element_len]);
                @memcpy(self.rand[0..p.prime_len], s[0..p.prime_len]);
                self.last = .offer;
            }

            /// 12.4.5.4：校验并处理对端的 commit，随后派生 KCK / PMK / PMKID。
            fn acceptPeerCommit(self: *Self.Instance, msg: Self.CommitMsg) !void {
                const id = self.group;
                const p = self.paramsOf();
                const scalar = msg.scalar orelse return error.InvalidCommit;
                const element = msg.element orelse return error.InvalidCommit;
                var pwe_buf: [element_len]u8 = undefined;
                var k: [scalar_len]u8 = undefined;
                var sum: [scalar_len]u8 = undefined;
                try groups.dispatchIn(group_list, id, groups.sharedKIn, .{ self.rand[0..p.prime_len], elemSlice(&self.pwe, p.element_len, &pwe_buf), scalar[0..p.prime_len], element[0..p.element_len], k[0..p.prime_len] });
                @memset(self.peer_scalar[0..], 0);
                @memcpy(self.peer_scalar[0..p.prime_len], scalar[0..p.prime_len]);
                try setElem(&self.peer_element, element[0..p.element_len]);
                const order = groups.dispatchIn(group_list, id, groups.orderIn, .{});
                groups.scalarAddWith(order, self.own_scalar[0..p.prime_len], scalar[0..p.prime_len], sum[0..p.prime_len]);
                const d = sae.kckPmk(k[0..p.prime_len], sum[0..p.prime_len]);
                self.kck = d.kck;
                self.pmk = d.pmk;
                self.pmkid = sum[0..sae.pmkid_len].*;
            }

            // ---- 事件 ----

            /// Nothing + Init（12.4.8.6.3）：清 Sync / Rc / Sc，选配置里最优先的群，生成 PWE 与
            /// 秘密值，发 Commit，设 t0，进 Committed。
            pub fn start(self: *Self.Instance, now_ms: u64) Result {
                if (self.state != .nothing) return .discarded;
                if (!passwordIdFits(self.env.password_id)) return self.die(.del);
                self.sync = 0;
                self.sc = 0;
                self.rc = 0;
                self.group = most_preferred;
                self.offered = 1;
                self.generate() catch return self.die(.del);
                self.sendCommit();
                self.arm(.t0, now_ms);
                self.state = .committed;
                return .ok;
            }

            /// 收到事务序号 1 的帧：状态 0 是 Com 事件，否则是 Rej(N)。
            pub fn onCommit(self: *Self.Instance, msg: Self.CommitMsg, now_ms: u64) Result {
                // 对端的 Rejected Groups 列表里有本端启用的群：回状态 1（hostap
                // check_sae_rejected_groups()，ap/ieee802_11.c:589–592），然后照常处理这一帧
                if (msg.rejected_groups) |list| {
                    const bad = if (rejectedGroupsOffending(list, &group_numbers)) |g| g != null else |_| true;
                    if (bad) self.sendUnspecifiedFailure();
                }
                switch (self.state) {
                    .nothing => return self.nothingOnCommit(msg, now_ms),
                    .committed => return self.committedOnCommit(msg, now_ms),
                    .confirmed => return self.confirmedOnCommit(msg, now_ms),
                    // Accepted 的实例不收 Com，父进程另有处理（12.4.8.6.1）
                    .accepted => return .discarded,
                }
            }

            /// 收到事务序号 2 的帧：状态 0 是 Con 事件，否则是 Rej(N)。
            pub fn onConfirm(self: *Self.Instance, msg: Self.ConfirmMsg, now_ms: u64) Result {
                switch (self.state) {
                    // 父进程不会把 Confirm 交给 Nothing 的实例（12.4.8.6.3 的 NOTE）
                    .nothing => return .discarded,
                    .committed => {
                        self.disarm(.t0);
                        // 其它非零状态：静默丢弃并重设 t0（12.4.8.6.4）
                        if (msg.status != status_success) return self.waitT0(now_ms);
                        // Committed 收到 Confirm：说明对端没收到我们的 Commit
                        if (self.bigSync()) return self.die(.del);
                        self.sync += 1;
                        self.sendCommit();
                        return self.waitT0(now_ms);
                    },
                    .confirmed => {
                        self.disarm(.t0);
                        // Confirmed 收到的拒绝帧一律静默丢弃（12.4.8.6.5）
                        if (msg.status != status_success) return self.waitT0(now_ms);
                        if (!self.confirmOk(msg)) {
                            // 12.4.5.6：拒绝对端认证并删除 PMK
                            self.sendChallengeFailure();
                            return self.die(.fail);
                        }
                        self.rc = msg.send_confirm;
                        self.sc = sc_accepted;
                        // 进 Accepted 后 PWE 与 rand 不再需要
                        self.pwe = elem_zero;
                        self.rand = @splat(0);
                        self.arm(.t1, now_ms);
                        self.state = .accepted;
                        return .auth;
                    },
                    .accepted => return self.acceptedOnConfirm(msg),
                }
            }

            /// 定时器到点。触发过的定时器不再重设（12.4.8.3.2）；要重设由各分支自己设。
            pub fn onTimer(self: *Self.Instance, timer: Timer, now_ms: u64) Result {
                self.disarm(timer);
                switch (timer) {
                    .t0 => switch (self.state) {
                        .committed => {
                            if (self.bigSync()) return self.die(.del);
                            self.sync += 1;
                            self.sendCommit();
                            self.arm(.t0, now_ms);
                            return .ok;
                        },
                        .confirmed => {
                            if (self.bigSync()) return self.die(.del);
                            self.sync += 1;
                            self.sc +|= 1;
                            self.sendConfirm();
                            self.arm(.t0, now_ms);
                            return .ok;
                        },
                        .nothing, .accepted => return .discarded,
                    },
                    // t1 到点：密钥过期，实例结束（12.4.8.6.6）
                    .t1 => return if (self.state == .accepted) self.die(.del) else .discarded,
                }
            }

            /// 推进时间：已到点的定时器依次触发（先 t0 后 t1）。返回最后一个事件的结果。
            pub fn poll(self: *Self.Instance, now_ms: u64) Result {
                var r: Result = .ok;
                if (self.t0_armed and now_ms >= self.t0_at) r = self.onTimer(.t0, now_ms);
                if (self.t1_armed and now_ms >= self.t1_at) r = self.onTimer(.t1, now_ms);
                return r;
            }

            // ---- 各状态收到 Commit ----

            /// Nothing + Com（12.4.8.6.3）。
            fn nothingOnCommit(self: *Self.Instance, msg: Self.CommitMsg, now_ms: u64) Result {
                // 状态不是 SUCCESS：静默丢弃，给父进程发 Del
                if (msg.status != status_success) return self.die(.del);
                const g = msg.group orelse return self.die(.del);
                const id = Self.configured(g) orelse {
                    // 群不支持（BadGrp）：回 77，群字段填被拒绝的群，然后 Del
                    self.last = .{ .unsupported_group = g };
                    self.sendCommit();
                    return self.die(.del);
                };
                // Password Identifier 不一致：静默丢弃并结束实例（hostap ieee802_11.c:571–576）
                if (!passwordIdFits(self.env.password_id) or !passwordIdMatches(self.env.password_id, msg.password_id)) {
                    return self.die(.del);
                }
                self.sc = 0;
                self.rc = 0;
                self.group = id;
                self.offered = @as(u32, 1) << @intCast(Self.indexOf(id));
                self.generate() catch return self.die(.del);
                self.acceptPeerCommit(msg) catch return self.die(.del);
                self.sendCommit();
                self.sc += 1;
                self.sendConfirm();
                self.sync = 0;
                self.arm(.t0, now_ms);
                self.state = .confirmed;
                return .ok;
            }

            /// Committed + Com / Rej(N)（12.4.8.6.4）。
            fn committedOnCommit(self: *Self.Instance, msg: Self.CommitMsg, now_ms: u64) Result {
                self.disarm(.t0);
                if (msg.status == status_token_required) {
                    // Rej(76)：带上 token，用原来发过的 commit-scalar / COMMIT-ELEMENT 重发
                    const n: u16 = @intCast(msg.token.len);
                    @memcpy(self.token[0..n], msg.token);
                    self.token_len = n;
                    self.last = .offer;
                    self.sendCommit();
                    self.sync = 0;
                    self.arm(.t0, now_ms);
                    return .ok;
                }
                if (msg.status == status_group_not_supported) {
                    // Rej(77)：被拒绝的群不是我们给的，静默丢弃并重设 t0
                    const rejected = msg.group orelse return self.waitT0(now_ms);
                    if (rejected != @backingInt(self.group)) return self.waitT0(now_ms);
                    // 正是我们给的群：配置里还有没提供过的群（moregroups）就换一个；没有就 Del
                    const next = self.nextGroup() orelse return self.die(.del);
                    self.group = next;
                    self.offered |= @as(u32, 1) << @intCast(Self.indexOf(next));
                    self.generate() catch return self.die(.del);
                    self.sendCommit();
                    self.sync = 0;
                    self.arm(.t0, now_ms);
                    return .ok;
                }
                if (msg.status != status_success) return self.waitT0(now_ms);

                const g = msg.group orelse return self.die(.del);
                const id = Self.configured(g) orelse {
                    // 群不支持（BadGrp）：Sync 超限就放弃，否则回 77 并留在 Committed
                    if (self.bigSync()) return self.die(.del);
                    self.sync += 1;
                    self.last = .{ .unsupported_group = g };
                    self.sendCommit();
                    return self.waitT0(now_ms);
                };
                if (id != self.group) {
                    // 群受支持但与我们的不同（DiffGrp）
                    if (self.highMac()) {
                        // 本机 MAC 数值较大：丢弃，重发上一个 Commit
                        self.sendCommit();
                        return self.waitT0(now_ms);
                    }
                    // 本机 MAC 数值较小：换成对端的群，重新生成，处理对端的 Commit，发新 Commit 与 Confirm
                    self.sync = 0;
                    self.sc += 1;
                    self.group = id;
                    self.offered |= @as(u32, 1) << @intCast(Self.indexOf(id));
                    self.generate() catch return self.die(.del);
                    self.acceptPeerCommit(msg) catch return self.die(.del);
                    self.sendCommit();
                    self.sendConfirm();
                    self.arm(.t0, now_ms);
                    self.state = .confirmed;
                    return .ok;
                }
                // 群受支持且与我们用的一样
                if (!passwordIdMatches(self.env.password_id, msg.password_id)) return self.die(.del);
                // 反射攻击：对端的 scalar / element 与我们发出去的一样，静默丢弃并重设 t0
                const scalar = msg.scalar;
                const element = msg.element;
                var own: [element_len]u8 = undefined;
                if (scalar != null and element != null and
                    std.mem.eql(u8, scalar.?[0..self.paramsOf().prime_len], self.ownScalar()) and
                    std.mem.eql(u8, element.?[0..self.paramsOf().element_len], elemSlice(&self.own_element, self.paramsOf().element_len, &own)))
                {
                    return self.waitT0(now_ms);
                }
                self.acceptPeerCommit(msg) catch return self.die(.del);
                self.sc += 1; // 此时是 1
                self.sendConfirm();
                self.arm(.t0, now_ms);
                self.state = .confirmed;
                return .ok;
            }

            /// Confirmed + Com / Rej(N)（12.4.8.6.5）。
            fn confirmedOnCommit(self: *Self.Instance, msg: Self.CommitMsg, now_ms: u64) Result {
                self.disarm(.t0);
                if (msg.status != status_success) return self.waitT0(now_ms);
                if (self.bigSync()) return self.die(.del);
                const g = msg.group orelse return self.waitT0(now_ms);
                // 群与之前收到的 Commit 不同：静默丢弃
                if (g != @backingInt(self.group)) {
                    // 原文只说「静默丢弃」。t0 刚被取消而 t1 还没设，照字面实例会永远停在
                    // Confirmed，所以这里同样重设 t0。
                    return self.waitT0(now_ms);
                }
                // Password Identifier 变了：同样静默丢弃（不是 2016 的规则，见文件头）
                if (!passwordIdMatches(self.env.password_id, msg.password_id)) return self.waitT0(now_ms);
                // 对端没收到我们的 Commit + Confirm：各发一遍，Confirm 带新的 Sc
                self.sync += 1;
                self.sc +|= 1;
                self.sendCommit();
                self.sendConfirm();
                self.arm(.t0, now_ms);
                return .ok;
            }

            /// Accepted + Con（12.4.8.6.6）。
            fn acceptedOnConfirm(self: *Self.Instance, msg: Self.ConfirmMsg) Result {
                // 原文没有写 Accepted 怎么处理拒绝帧，这里丢弃
                if (msg.status != status_success) return .discarded;
                if (self.bigSync()) return self.die(.del);
                // send-confirm 不大于 Rc 或等于 2^16 − 1：丢弃。等于 Rc 也算「不大于」
                if (msg.send_confirm <= self.rc or msg.send_confirm == sc_accepted) return .discarded;
                if (!self.confirmOk(msg)) return .discarded;
                self.rc = msg.send_confirm;
                self.sync += 1;
                self.sendConfirm();
                return .ok;
            }
        };

        /// 父进程：实例表、Open 计数、Anti-Clogging Token。
        ///
        /// `slots` 是实例表的容量。同一个对端最多同时有两个实例（一个 Accepted、一个在进行中）。
        /// 建好之后不要再按值拷贝（实例里存着指向 `env` 的指针）。
        pub fn Parent(comptime slots: usize) type {
            return struct {
                const P = @This();

                /// 交给 SME 的事件队列容量；满了丢新来的并计数。
                pub const event_capacity = 4;
                /// 自己生成的 Anti-Clogging Token 长度（HMAC-SHA-256 的输出）。
                pub const token_len = sae.hash_len;

                const Entry = struct {
                    used: bool = false,
                    inst: Self.Instance = .{},
                    /// 是否计入 Open：新建时计入，发出 Auth 或被删除时才减掉。
                    counted: bool = false,
                };

                const Which = enum { in_progress, accepted };

                env: Env,
                cfg: ParentConfig,
                entries: [slots]Entry = @splat(.{}),
                /// Committed 或 Confirmed 状态的实例数（12.4.8.5.1）。
                open: u16 = 0,
                token_secret: [sae.hash_len]u8 = @splat(0),
                token_armed: bool = false,
                events: [event_capacity]ParentEvent = undefined,
                event_head: u8 = 0,
                event_len: u8 = 0,
                events_dropped: u32 = 0,

                pub fn init(env: Env, cfg: ParentConfig) P {
                    var self = P{ .env = env, .cfg = cfg };
                    self.syncToken();
                    return self;
                }

                pub fn openCount(self: *const P) u16 {
                    return self.open;
                }

                /// Initiate（12.4.8.6.1）：该对端已有 Committed / Confirmed 的实例就忽略。
                /// 返回是否新建了实例。
                pub fn initiate(self: *P, peer: [6]u8, now_ms: u64) bool {
                    if (self.find(peer, .in_progress) != null) return false;
                    const e = self.create(peer) orelse return false;
                    const r = e.inst.start(now_ms);
                    self.settle(e, peer, r);
                    return true;
                }

                /// Kill（12.4.8.6.1）：删掉该对端的全部实例。
                pub fn kill(self: *P, peer: [6]u8) void {
                    for (&self.entries) |*e| {
                        if (!e.used or !std.mem.eql(u8, &e.inst.peer_mac, &peer)) continue;
                        if (e.inst.state == .committed or e.inst.state == .confirmed) self.open -= 1;
                        e.* = .{};
                    }
                    self.syncToken();
                }

                /// 收到 SA 为 `peer` 的 Authentication 帧（只传帧体）。不是 SAE 帧就丢弃。
                pub fn receive(self: *P, peer: [6]u8, body: []const u8, now_ms: u64) void {
                    switch (Self.decode(body) catch return) {
                        .confirm => |msg| {
                            // 只有一个实例就交给它；有两个就交给不在 Accepted 的那个；没有就丢弃
                            if (self.find(peer, .in_progress) orelse self.find(peer, .accepted)) |e| {
                                const r = e.inst.onConfirm(msg, now_ms);
                                self.settle(e, peer, r);
                            }
                        },
                        .commit => |msg| {
                            if (self.find(peer, .in_progress)) |e| {
                                const r = e.inst.onCommit(msg, now_ms);
                                self.settle(e, peer, r);
                                return;
                            }
                            // 该对端只有 Accepted 的实例：peer-commit-scalar 与认证时用的相同就丢弃
                            if (self.find(peer, .accepted)) |e| {
                                if (msg.scalar) |s| {
                                    if (std.mem.eql(u8, &s, &e.inst.peer_scalar)) return;
                                }
                            }
                            // Open 达到阈值：带 token 且 token 对才建实例；没带 token 就回 76 要一个
                            // （12.4.6、12.4.8.6.1）
                            if (self.open >= self.cfg.anti_clogging_threshold) {
                                if (msg.token.len > 0) {
                                    if (!self.tokenOk(peer, msg.token)) return;
                                } else {
                                    self.sendTokenRequest(peer, msg.group orelse @backingInt(most_preferred));
                                    return;
                                }
                            }
                            const e = self.create(peer) orelse return;
                            const r = e.inst.onCommit(msg, now_ms);
                            self.settle(e, peer, r);
                        },
                    }
                }

                /// 推进时间：各实例到点的定时器依次触发。
                pub fn tick(self: *P, now_ms: u64) void {
                    for (&self.entries) |*e| {
                        if (!e.used) continue;
                        const peer = e.inst.peer_mac;
                        const r = e.inst.poll(now_ms);
                        self.settle(e, peer, r);
                    }
                }

                /// 取一个待处理的事件。
                pub fn popEvent(self: *P) ?ParentEvent {
                    if (self.event_len == 0) return null;
                    const ev = self.events[self.event_head];
                    self.event_head = (self.event_head + 1) % event_capacity;
                    self.event_len -= 1;
                    return ev;
                }

                /// 该对端处于 Accepted 的实例（PMK 与 PMKID 在里面）；没有就返回 null。
                pub fn accepted(self: *P, peer: [6]u8) ?*const Self.Instance {
                    const e = self.find(peer, .accepted) orelse return null;
                    return &e.inst;
                }

                /// 实例表里在用的条目数。
                pub fn instanceCount(self: *const P) usize {
                    var n: usize = 0;
                    for (&self.entries) |*e| {
                        if (e.used) n += 1;
                    }
                    return n;
                }

                // ---- 内部 ----

                fn find(self: *P, peer: [6]u8, which: Which) ?*Entry {
                    for (&self.entries) |*e| {
                        if (!e.used or !std.mem.eql(u8, &e.inst.peer_mac, &peer)) continue;
                        const hit = switch (which) {
                            .in_progress => e.inst.state == .committed or e.inst.state == .confirmed,
                            .accepted => e.inst.state == .accepted,
                        };
                        if (hit) return e;
                    }
                    return null;
                }

                /// 同一对端的另一个实例（12.4.8.6.1：收到 Auth 时删掉它）。
                fn findOther(self: *P, peer: [6]u8, e: *Entry) ?*Entry {
                    for (&self.entries) |*o| {
                        if (o.used and o != e and std.mem.eql(u8, &o.inst.peer_mac, &peer)) return o;
                    }
                    return null;
                }

                /// 新建实例：置 Nothing、Open 加一、登记进实例表（12.4.8.6.1）。表满返回 null。
                fn create(self: *P, peer: [6]u8) ?*Entry {
                    for (&self.entries) |*e| {
                        if (e.used) continue;
                        e.* = .{};
                        e.used = true;
                        e.counted = true;
                        e.inst.env = &self.env;
                        e.inst.peer_mac = peer;
                        self.open += 1;
                        self.syncToken();
                        return e;
                    }
                    return null;
                }

                /// 实例不再占用 Open 计数（12.4.8.6.1）。Accepted 的实例在发出 Auth 时
                /// 已经减过，之后再结束（Sync 超限、t1 到点）不再减。
                fn release(self: *P, e: *Entry) void {
                    if (!e.counted) return;
                    e.counted = false;
                    self.open -= 1;
                }

                /// 实例发出 Fail / Del：删除实例。发出 Auth：实例留在 Accepted，
                /// 并删掉同一对端的另一个实例（12.4.8.6.1）。
                fn settle(self: *P, e: *Entry, peer: [6]u8, r: Result) void {
                    const signal: Signal = switch (r) {
                        .ok, .discarded => return,
                        .auth => blk: {
                            self.release(e);
                            if (self.findOther(peer, e)) |other| other.* = .{};
                            break :blk .auth;
                        },
                        .fail => blk: {
                            self.release(e);
                            e.* = .{};
                            break :blk .fail;
                        },
                        .del => blk: {
                            self.release(e);
                            e.* = .{};
                            break :blk .del;
                        },
                    };
                    self.syncToken();
                    if (self.event_len == event_capacity) {
                        self.events_dropped += 1;
                        return;
                    }
                    self.events[(self.event_head + self.event_len) % event_capacity] = .{ .peer = peer, .signal = signal };
                    self.event_len += 1;
                }

                /// Open 达到阈值时换一个新的随机秘密（12.4.6 的 NOTE）；降回阈值以下就作废。
                fn syncToken(self: *P) void {
                    if (self.open < self.cfg.anti_clogging_threshold) {
                        self.token_armed = false;
                        self.token_secret = @splat(0);
                    } else if (!self.token_armed) {
                        self.env.random(&self.token_secret);
                        self.token_armed = true;
                    }
                }

                /// token = H(secret, 发送者的 MAC)，不存状态就能验证（12.4.6）。
                fn makeToken(self: *const P, peer: [6]u8, out: *[token_len]u8) void {
                    var ctx = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.token_secret);
                    ctx.update(&peer);
                    ctx.final(out);
                }

                fn tokenOk(self: *const P, peer: [6]u8, token: []const u8) bool {
                    if (token.len != token_len) return false;
                    var want: [token_len]u8 = undefined;
                    self.makeToken(peer, &want);
                    return std.crypto.timing_safe.eql([token_len]u8, want, token[0..token_len].*);
                }

                /// 回一个状态 76 的 Commit：群字段 || token（12.4.7.6、表 9-36）。不带 Password
                /// Identifier 元素（hostap comeback_token.c:100–124）。
                fn sendTokenRequest(self: *P, peer: [6]u8, g: u16) void {
                    var body: [header_len + group_len + token_len]u8 = undefined;
                    var token: [token_len]u8 = undefined;
                    self.makeToken(peer, &token);
                    const len = Self.encodeStatusCommit(&body, status_token_required, g, &token);
                    self.env.emit.frame(self.env.emit.ctx, peer, body[0..len]);
                }
            };
        }
    };
}

/// 父进程交给 SME 的事件（12.4.8.3.1）。
pub const ParentEvent = struct {
    peer: [6]u8,
    signal: Signal,
};

/// 父进程的配置。
pub const ParentConfig = struct {
    /// dot11RSNASAEAntiCloggingThreshold：Open 达到它就对新的 Commit 要 token。
    /// 0 表示一律要。默认值是 Annex C 的 DEFVAL（印刷页 2840）。
    anti_clogging_threshold: u16 = 5,
};

// ---------------------------------------------------------------------------
// 只配置 group 19 的那一组：文件头的这些名字是现有调用方用的
// ---------------------------------------------------------------------------

pub const Default = Groups(&.{.ecc_19});

/// 不带 token 的 Commit 帧体长度。
pub const commit_body_len = Default.commit_body_len;
/// 帧体最大长度：带满 token 与 Password Identifier 元素的 Commit。
pub const body_max_len = Default.body_max_len;

pub const DecodeError = Default.DecodeError;
pub const Decoded = Default.Decoded;
pub const CommitMsg = Default.CommitMsg;
pub const ConfirmMsg = Default.ConfirmMsg;
pub const decode = Default.decode;
pub const Instance = Default.Instance;

pub fn Parent(comptime slots: usize) type {
    return Default.Parent(slots);
}
