//! ble-802154：Robust Caching —— Client Supported Features、Database Hash、服务端对
//! change-aware / change-unaware 的跟踪，以及客户端「哈希一致就复用缓存」的判定。
//!
//! 规范出处（Bluetooth Core Specification v5.4，[Vol 3] Part G，行号指
//! `/tmp/spec/Core-54-generic-attribute-profile--gatt-.txt`）：
//!   * 属性缓存与作废 —— §2.5.2（2130–2145）：读了 Database Hash 发现变了、收到
//!     Service Changed 的指示、收到 Database Out Of Sync，缓存都作废；发现过程中库再变，
//!     可以再读一次哈希决定这次发现能不能接着用；
//!   * Robust Caching —— §2.5.2.1（2146–2163）：每个连接的客户端要么 change-aware
//!     要么 change-unaware；什么时候回 ATT_ERROR_RSP 0x12；每条 bearer 只回一次；
//!     change-unaware 客户端的命令丢弃、通知与指示不发；
//!   * Client Supported Features 特征 —— §7.2（3279–3342，表 7.4、表 7.5、表 7.6）：
//!     UUID 0x2B29，声明属性位 0x0A，值可读可写，是八位组位域数组、不应有尾随零
//!     八位组，缺的八位组当 0；默认全零；每个连接的客户端一份；客户端不得清除已置的
//!     位，否则回 Value Not Allowed (0x13)；
//!   * Database Hash 特征 —— §7.3（3343–3377，表 7.7、表 7.8）：UUID 0x2B2A，只读，
//!     128 位；输入变了就重算并更新；重算期间读到的新值；
//!   * Database Hash 的计算 —— §7.3.1（3378–3391）：AES-CMAC（RFC 4493），密钥全零，
//!     按句柄升序拼 Attribute Handle / Attribute Type / Attribute Value，哪些类型带值
//!     见 `included()`；附录 B（3846–4023）的例子与结果；
//!   * Server Supported Features 特征 —— §7.4（3392–3435，表 7.9–表 7.11）：UUID
//!     0x2B3A，只读，第 0 个八位组 bit0 是 EATT Supported；
//!   * 特征声明的格式 —— §3.3.1（§7.3.1 的例子：{0x02, 0x0005, 0x2A01} 拼成
//!     02 05 00 01 2A）；
//!   * 回哪些请求时允许 Database Out Of Sync —— [Vol 3] Part F 表 3.44（ATT 文本
//!     3463–3575）：ATT_READ_BY_TYPE_REQ、ATT_READ_REQ、ATT_READ_BLOB_REQ、
//!     ATT_READ_MULTIPLE_REQ、ATT_READ_MULTIPLE_VARIABLE_REQ、ATT_WRITE_REQ、
//!     ATT_PREPARE_WRITE_REQ；出错句柄取请求里的句柄（§3.4.1.1：请求里没有句柄时
//!     才是 0x0000）。
//!
//! UUID 取自 Assigned Numbers（2026-11-16 版）：Client Supported Features 0x2B29、
//! Database Hash 0x2B2A、Server Supported Features 0x2B3A。
//!
//! 与本机 NimBLE 交叉核对过（`~/esp/esp-idf/components/bt/host/nimble/nimble/nimble/`）：
//!   * CSF 写入 —— `host/src/ble_gatts.c` 2477–2554：清除已置的位回 0x13（2518–2528）；
//!   * Database Hash —— `host/src/ble_gatts.c` 723–761：密钥全零（732），算完再整段
//!     字节反转（754）得到附录 B 的写法；
//!   * aware 状态 —— `host/src/ble_att_svr.c` 1403–1456（make / check）与各请求里的
//!     判定（1666–1675、1723–1732 等）；
//!   * 错误码 —— `host/include/host/ble_att.h` 112（0x12）、113（0x13）。
//!
//! 与 NimBLE 不同的一处：NimBLE 对 ATT_EXECUTE_WRITE_REQ 也回 0x12
//! （`ble_att_svr.c` 3044–3045），而表 3.44 没有把这个方法列为允许 0x12 的方法，
//! §2.5.2.1 的两条情形也不含它；本文件不拦它。
//!
//! 三个层各自独立：`Csf` 与 `validateCsf` 管特征值；`Hasher` / `Tracker` 管哈希；
//! `Aware` 是服务端每个客户端的状态机；`Cache` 是客户端的判定。`add*` 把三个特征的
//! 属性放进 `att_server.Db`。没有分配、没有全局状态。

const std = @import("std");
const att = @import("att.zig");
const gs = @import("gatt_server.zig");
const svr = @import("att_server.zig");

const Cmac = std.crypto.auth.cmac.CmacAes128;

/// 三个特征的 UUID。Assigned Numbers：GATT Service 的特征。
pub const uuid_client_supported_features: u16 = 0x2B29;
pub const uuid_database_hash: u16 = 0x2B2A;
pub const uuid_server_supported_features: u16 = 0x2B3A;

// ---------------------------------------------------------------------------
// Client Supported Features（§7.2）
// ---------------------------------------------------------------------------

/// 表 7.6 的三个位，都在第 0 个八位组。
pub const Feature = enum(u8) {
    robust_caching = 0,
    eatt = 1,
    multi_ntf = 2,

    pub fn octet(self: Feature) usize {
        return @as(usize, @backingInt(self)) / 8;
    }

    pub fn bit(self: Feature) u8 {
        return @as(u8, 1) << @intCast(@as(usize, @backingInt(self)) % 8);
    }
};

/// 第 0 个八位组里已定义的位；其余是 Reserved for future use。
pub const csf_defined: u8 = Feature.robust_caching.bit() | Feature.eatt.bit() | Feature.multi_ntf.bit();
/// 服务端为每个客户端保存的八位组数。表 7.6 目前只用到第 0 个八位组。
pub const csf_len: usize = 4;

/// 一个客户端的 Client Supported Features 值。
pub const Csf = struct {
    bytes: [csf_len]u8 = @splat(0),
    /// 值里实际有的八位组数。
    n: u8 = 0,

    /// 从特征值（或属性表里的默认值）取出来。太长的只留前 `csf_len` 个八位组。
    pub fn init(raw: []const u8) Csf {
        var c = Csf{};
        const k = @min(raw.len, csf_len);
        @memcpy(c.bytes[0..k], raw[0..k]);
        c.n = @intCast(k);
        return c;
    }

    /// 第 `i` 个八位组。值太短、没有这个八位组时是 0（§7.2）。
    pub fn octet(self: Csf, i: usize) u8 {
        return if (i < self.n) self.bytes[i] else 0;
    }

    /// 客户端有没有声明支持某个特性。
    pub fn has(self: Csf, f: Feature) bool {
        return self.octet(f.octet()) & f.bit() != 0;
    }

    /// 读回去的值：去掉尾随的零八位组（§7.2：数组不应有尾随零八位组）。
    pub fn value(self: *const Csf) []const u8 {
        var k: usize = self.n;
        while (k > 0 and self.bytes[k - 1] == 0) k -= 1;
        return self.bytes[0..k];
    }
};

/// 写 Client Supported Features 时的校验，签名是 `att_server.Validate` 的（`arg` 不用）。
///
/// §7.2：客户端不得清除已置的位 → Value Not Allowed (0x13)，值不变。超过
/// `csf_len` 的写入由属性的 `max_len` 拦成 Invalid Value Length。保留位原样保存：
/// 它们也是「客户端置过的位」，清除同样回 0x13。
pub fn validateCsf(current: []const u8, incoming: []const u8, arg: u16) ?u8 {
    _ = arg;
    const cur = Csf.init(current);
    const inc = Csf.init(incoming);
    for (0..csf_len) |i| {
        if (cur.octet(i) & ~inc.octet(i) != 0) return @backingInt(att.Code.value_not_allowed);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Database Hash（§7.3.1）
// ---------------------------------------------------------------------------

/// 一个属性进不进哈希的输入。附录 B 表 B.1 的「Included in Hash」栏。
pub const Inclusion = enum {
    /// 其它类型（特征值等）：整条忽略。
    none,
    /// 只有 Attribute Handle 与 Attribute Type。
    ht,
    /// Attribute Handle、Attribute Type、Attribute Value。
    htv,
};

/// §7.3.1 的类型清单：带值的是 «Primary Service»、«Secondary Service»、«Included
/// Service»、«Characteristic»、«Characteristic Extended Properties»；不带值的是
/// «Characteristic User Description»、«Client Characteristic Configuration»、«Server
/// Characteristic Configuration»、«Characteristic Presentation Format»、
/// «Characteristic Aggregate Format»。只有 16 位 UUID 才可能是这些类型。
pub fn included(t: att.Uuid) Inclusion {
    const v = t.asU16() orelse return .none;
    return switch (v) {
        gs.uuid_primary_service, gs.uuid_secondary_service, gs.uuid_include, gs.uuid_characteristic, gs.uuid_ext_props => .htv,
        gs.uuid_user_desc, gs.uuid_cccd, gs.uuid_sccd, gs.uuid_present_fmt, gs.uuid_agg_fmt => .ht,
        else => .none,
    };
}

/// Database Hash 的密钥：128 位全零（§7.3.1）。
pub const zero_key: [16]u8 = @splat(0);

/// 流式计算 AES-CMAC_k(m)：按句柄升序逐个属性喂进来。字段都是小端（§7.3.1）。
pub const Hasher = struct {
    mac: Cmac,

    pub fn init() Hasher {
        return .{ .mac = Cmac.init(&zero_key) };
    }

    /// 一个属性。`value` 是它当前的值。
    pub fn add(self: *Hasher, handle: u16, t: att.Uuid, value: []const u8) void {
        switch (included(t)) {
            .none => {},
            .ht, .htv => {
                var h: [2]u8 = undefined;
                att.putU16(&h, handle);
                self.mac.update(&h);
                var tb: [16]u8 = undefined;
                const n = t.put(&tb);
                self.mac.update(tb[0..n]);
                if (included(t) == .htv) self.mac.update(value);
            },
        }
    }

    pub fn final(self: *Hasher) [16]u8 {
        return self.mac.finalResult();
    }
};

/// 一个属性的三个字段；`hashAttrs()` 的输入，按句柄升序。
pub const Attr = struct { handle: u16, type: att.Uuid, value: []const u8 };

/// 给一批属性算 Database Hash。句柄不是严格升序 → `Unordered`（§2.5.1：属性按句柄升序）。
pub fn hashAttrs(attrs: []const Attr) error{Unordered}![16]u8 {
    var h = Hasher.init();
    var prev: u16 = 0;
    for (attrs) |a| {
        // 句柄非零（§2.5.1：0x0001–0xFFFF）且严格升序。
        if (a.handle == 0 or a.handle <= prev) return error.Unordered;
        prev = a.handle;
        h.add(a.handle, a.type, a.value);
    }
    return h.final();
}

/// 给 `att_server.Db` 算 Database Hash。属性表本来就按句柄升序；按 client 保存的属性
/// （槽位）用它自己的默认值——会进哈希的那几类里只有 CCCD 带槽位，而它不带值。
pub fn hashDb(db: anytype) [16]u8 {
    var h = Hasher.init();
    for (db.list()) |*a| h.add(a.handle, a.type, a.value[0..a.len]);
    return h.final();
}

/// 服务端当前哈希与「变没变」的检测。
pub const Tracker = struct {
    current: [16]u8 = @splat(0),
    /// 还没算过，或者属性表改过之后还没重算。
    dirty: bool = true,
    known: bool = false,

    /// 属性表改了之后调用（§2.5.2：服务变了就重算并更新特征值；§7.3：重算期间读到
    /// 的一定是新的哈希，所以这里不急着算，读的时候再算）。
    pub fn invalidate(self: *Tracker) void {
        self.dirty = true;
    }

    pub const Value = struct { hash: [16]u8, changed: bool };

    /// 当前的 Database Hash。需要时按属性表重算。`changed` 是与上一次的值相比。
    pub fn value(self: *Tracker, db: anytype) Value {
        if (!self.dirty) return .{ .hash = self.current, .changed = false };
        const h = hashDb(db);
        const first = !self.known;
        const changed = !first and !std.mem.eql(u8, &h, &self.current);
        self.current = h;
        self.dirty = false;
        self.known = true;
        return .{ .hash = h, .changed = changed };
    }
};

// ---------------------------------------------------------------------------
// 服务端：change-aware / change-unaware（§2.5.2.1）
// ---------------------------------------------------------------------------

/// 会被回 Database Out Of Sync 的请求，以及回错误时该填的句柄。
pub const Blocked = struct { op: att.Op, handle: u16 };

fn handleAt(pdu: []const u8) u16 {
    return if (pdu.len >= 3) att.getU16(pdu[1..3]) else 0;
}

/// §2.5.2.1 的两条情形：对任意句柄（或句柄列表）的请求；类型不是 «Include» 或
/// «Characteristic»、且范围不是 0x0001–0xFFFF 的 ATT_READ_BY_TYPE_REQ。正好是表 3.44
/// 允许回 0x12 的七种请求。不是请求、或不属于这两种情形 → null。
pub fn blocked(pdu: []const u8) ?Blocked {
    if (pdu.len == 0) return null;
    const op = att.Op.fromByte(pdu[0]) orelse return null;
    if (op.kind() != .request) return null;
    return switch (op) {
        .read_req, .write_req, .read_blob_req, .prepare_write_req => .{ .op = op, .handle = handleAt(pdu) },
        .read_multiple_req, .read_multiple_var_req => blk: {
            // 请求里是句柄列表：出错句柄取第一个（§3.4.1.1：请求里有的那个句柄）。
            if (pdu.len < 5) break :blk null;
            break :blk .{ .op = op, .handle = handleAt(pdu) };
        },
        .read_by_type_req => blk: {
            if (pdu.len < 7) break :blk null;
            const t = att.Uuid.parse(pdu[5..]) catch break :blk null;
            if (t.asU16()) |v| {
                if (v == gs.uuid_include or v == gs.uuid_characteristic) break :blk null;
            }
            const start = att.getU16(pdu[1..3]);
            const end = att.getU16(pdu[3..5]);
            if (start == 0x0001 and end == 0xFFFF) break :blk null;
            break :blk .{ .op = op, .handle = start };
        },
        else => null,
    };
}

/// 请求是不是在读 Database Hash 特征。§7.3：客户端应始终用 Read Using Characteristic
/// UUID（范围 0x0001–0xFFFF）读它。
pub fn readsDatabaseHash(pdu: []const u8) bool {
    if (pdu.len < 7) return false;
    const op = att.Op.fromByte(pdu[0]) orelse return false;
    if (op != .read_by_type_req) return false;
    const t = att.Uuid.parse(pdu[5..]) catch return false;
    const v = t.asU16() orelse return false;
    return v == uuid_database_hash;
}

pub const Verdict = union(enum) {
    /// 交给 ATT 处理。
    allow,
    /// 回 ATT_ERROR_RSP，Error Code = Database Out Of Sync (0x12)，句柄用 `blocked()` 给的。
    out_of_sync,
    /// change-unaware 客户端的命令：忽略，不应答。
    drop,
};

/// 一个客户端在一条连接上的状态。`bearers` 是这条连接最多几条 ATT bearer（EATT
/// bearer 数加 1 条固定信道的 Unenhanced bearer）。
///
/// 规则（§2.5.2.1，2149–2160）：
///   * 连接后：非信任（未绑定）的客户端一开始是 change-aware；信任的客户端沿用上次的
///     状态，但这次没连着的时候库变过就是 change-unaware；
///   * 服务端改了库 → 所有已连接的客户端都变成 change-unaware；
///   * change-unaware 的客户端读了 Database Hash、之后服务端又收到它一条请求 →
///     change-aware；
///   * 只用一条 bearer 的客户端：确认了 Service Changed 的指示，或服务端回了 0x12 之后
///     又收到它一条请求 → change-aware；
///   * 声明了 Robust Caching 的 change-unaware 客户端：发来会被拦的请求 → 回 0x12，
///     每条 bearer 只回一次（库又变了会再回）；发来的命令丢弃；除 Service Changed 的
///     指示外不发通知与指示。
pub fn Aware(comptime bearers: usize) type {
    if (bearers == 0) @compileError("bearers 至少为 1");
    return struct {
        const Self = @This();

        aware: bool = true,
        /// 读了 Database Hash，等它的下一条请求。
        hash_read: bool = false,
        connected: bool = false,
        trusted: bool = false,
        /// 没连着的时候库变过。
        changed_while_away: bool = false,
        /// 上次断开时是不是 change-aware（信任的客户端沿用）。
        last_aware: bool = true,
        /// 这条 bearer 上这次 change-unaware 期间已经回过 0x12。
        oos: [bearers]bool = @splat(false),

        pub fn onConnect(self: *Self, trusted: bool) void {
            self.trusted = trusted;
            self.aware = if (trusted) (self.last_aware and !self.changed_while_away) else true;
            self.hash_read = false;
            self.oos = @splat(false);
            self.connected = true;
        }

        pub fn onDisconnect(self: *Self) void {
            self.last_aware = self.aware;
            self.connected = false;
        }

        /// 服务端改了属性表。
        pub fn onDatabaseChanged(self: *Self) void {
            if (!self.connected) {
                self.changed_while_away = true;
                return;
            }
            self.aware = false;
            self.hash_read = false;
            self.oos = @splat(false);
        }

        /// 客户端确认了 Service Changed 的指示。只有只用一条 ATT bearer 的客户端才因此
        /// 变成 change-aware（§2.5.2.1）。
        pub fn onServiceChangedConfirmed(self: *Self, one_bearer: bool) void {
            if (one_bearer) self.becomeAware();
        }

        fn becomeAware(self: *Self) void {
            self.aware = true;
            self.hash_read = false;
            self.oos = @splat(false);
        }

        fn anyOos(self: *const Self) bool {
            for (self.oos) |v| {
                if (v) return true;
            }
            return false;
        }

        /// 可以给这个客户端发通知与指示（除 Service Changed 的指示外）。
        pub fn mayNotify(self: *const Self) bool {
            return self.aware;
        }

        /// 收到这个客户端的一个 ATT PDU 时调用。`one_bearer`：它现在只连着一条 ATT
        /// bearer。`csf` 是它写进 Client Supported Features 的值（没写过就是默认的全零）。
        pub fn onRequest(self: *Self, bearer: usize, pdu: []const u8, csf: Csf, one_bearer: bool) Verdict {
            const kind: ?att.Kind = if (pdu.len == 0) null else if (att.Op.fromByte(pdu[0])) |op| op.kind() else null;
            if (kind == .request) {
                // 「读了哈希之后又来一条请求」或「只一条 bearer、回了 0x12 之后又来一条请求」。
                if (self.hash_read or (one_bearer and !self.aware and self.anyOos())) {
                    self.becomeAware();
                    return .allow;
                }
            }
            if (self.aware or !csf.has(.robust_caching)) return .allow;
            if (kind == .command) return .drop;
            if (kind != .request) return .allow;
            if (readsDatabaseHash(pdu)) {
                self.hash_read = true;
                return .allow;
            }
            if (blocked(pdu) == null) return .allow;
            if (self.oos[bearer]) return .allow;
            self.oos[bearer] = true;
            return .out_of_sync;
        }
    };
}

// ---------------------------------------------------------------------------
// 客户端：缓存能不能接着用（§2.5.2）
// ---------------------------------------------------------------------------

/// 读了 Database Hash 之后缓存还能不能用。
pub const Use = enum {
    /// 哈希没变：缓存接着用。
    reuse,
    /// 哈希变了（或还没有缓存）：缓存作废，要重新发现。
    rediscover,
};

/// 客户端的缓存状态。`hash` 是这份缓存对应的 Database Hash。
///
/// §2.5.2：哈希与上次读到的不同 → 缓存作废；收到 Database Out Of Sync 或 Service Changed
/// 的指示 → 作废；作废之后不得再用缓存，直到做完发现（或带外拿到新的定义）；发现
/// 过程中收到 Service Changed 指示时，再读一次哈希没变就可以接着做这次发现。
pub const Cache = struct {
    /// 缓存可以用来访问服务。
    valid: bool = false,
    /// 建立过缓存（发现做完过）。
    built: bool = false,
    /// 正在重新发现；`at_start` 是开始之前读到的哈希。
    discovering: bool = false,
    hash: [16]u8 = @splat(0),
    at_start: [16]u8 = @splat(0),
    /// 作废的句柄范围；`stale` 为 false 表示没有作废的范围。
    stale: bool = false,
    stale_lo: u16 = 0,
    stale_hi: u16 = 0,

    fn clearStale(self: *Cache) void {
        self.stale = false;
        self.stale_lo = 0;
        self.stale_hi = 0;
    }

    pub fn usable(self: *const Cache) bool {
        return self.valid;
    }

    /// 读到一个 Database Hash。与这份缓存对应的哈希相同 → 缓存接着用；不同（或还没
    /// 有缓存）→ 整份缓存作废。
    pub fn onHash(self: *Cache, h: [16]u8) Use {
        if (self.built and std.mem.eql(u8, &h, &self.hash)) {
            self.valid = true;
            self.clearStale();
            return .reuse;
        }
        self.invalidate(0x0001, 0xFFFF);
        return .rediscover;
    }

    /// 收到 Error Code = Database Out Of Sync 的应答（§2.5.2.1 末段）。
    pub fn onDbOutOfSync(self: *Cache) void {
        self.invalidate(0x0001, 0xFFFF);
    }

    /// 收到 Service Changed 的指示：`start`–`end` 范围作废。
    pub fn onServiceChanged(self: *Cache, start: u16, end: u16) void {
        self.invalidate(start, end);
    }

    fn invalidate(self: *Cache, lo: u16, hi: u16) void {
        var span_lo = lo;
        var span_hi = hi;
        if (self.stale and !self.valid) {
            // 与已经作废的范围取并；不相接的两段取能把两段都盖住的最小范围。
            span_lo = @min(lo, self.stale_lo);
            span_hi = @max(hi, self.stale_hi);
        }
        self.valid = false;
        self.stale = true;
        self.stale_lo = span_lo;
        self.stale_hi = span_hi;
    }

    /// 一个句柄落不作废的范围里（§2.5.2：落在这儿的在途请求事务按无效处理）。
    pub fn invalidates(self: *const Cache, handle: u16) bool {
        return self.stale and !self.valid and handle >= self.stale_lo and handle <= self.stale_hi;
    }

    /// 开始一次服务发现；`h` 是开始之前读到的哈希（没有 Database Hash 特征时由调用方
    /// 决定要不要走这套流程）。
    pub fn beginDiscovery(self: *Cache, h: [16]u8) void {
        self.discovering = true;
        self.at_start = h;
        self.valid = false;
    }

    /// 发现做完（或发现中途收到 Service Changed 指示之后再读一次哈希）。`h` 是此时
    /// 读到的哈希。返回 false：库在发现期间变过，缓存仍然作废，要重新发现。
    pub fn discoveryDone(self: *Cache, h: [16]u8) bool {
        if (self.discovering and !std.mem.eql(u8, &h, &self.at_start)) {
            self.discovering = false;
            self.valid = false;
            return false;
        }
        self.discovering = false;
        self.built = true;
        self.valid = true;
        self.hash = h;
        self.clearStale();
        return true;
    }
};

// ---------------------------------------------------------------------------
// 三个特征的属性
// ---------------------------------------------------------------------------

pub const ChrHandles = struct { decl: u16, value: u16 };

/// 特征声明 + 特征值声明（§3.3.1、§3.3.2）。声明值 = 属性位 ‖ 值句柄 ‖ UUID。返回两个句柄。
fn addCharacteristic(db: anytype, uuid: u16, props: u8, value: @TypeOf(db.*).New) svr.AddError!ChrHandles {
    const Db = @TypeOf(db.*);
    if (db.next_handle == 0 or @as(usize, db.next_handle) + 1 > 0xFFFF) return error.TableFull;
    if (@as(usize, db.count) + 2 > Db.capacity) return error.TableFull;
    const decl: u16 = db.next_handle;
    var decl_value: [5]u8 = .{ props, 0, 0, @truncate(uuid), @intCast(uuid >> 8) };
    att.putU16(decl_value[1..3], decl + 1);
    _ = try db.add(.{
        .type = .{ .u16 = gs.uuid_characteristic },
        .value = &decl_value,
        .fixed = true,
        .perm = .{ .read = true },
    });
    const value_handle = try db.add(value);
    return .{ .decl = decl, .value = value_handle };
}

/// «Client Supported Features»（表 7.4、表 7.5）。值每个客户端一份：放进槽位 `slot`，
/// 读出来是这个客户端自己的值，没写过是默认的全零。写的时候过 `validateCsf`。
pub fn addClientSupportedFeatures(db: anytype, slot: u8) svr.AddError!ChrHandles {
    return addCharacteristic(db, uuid_client_supported_features, 0x0A, .{
        .type = .{ .u16 = uuid_client_supported_features },
        .value = &.{0},
        .max_len = csf_len,
        .perm = .{ .read = true, .write = true },
        .slot = slot,
        .validate = validateCsf,
    });
}

/// «Database Hash»（表 7.7、表 7.8）。只读，16 字节定长；值由 `setDatabaseHash()` 更新。
pub fn addDatabaseHash(db: anytype) svr.AddError!ChrHandles {
    return addCharacteristic(db, uuid_database_hash, 0x02, .{
        .type = .{ .u16 = uuid_database_hash },
        .value = &@as([16]u8, @splat(0)),
        .fixed = true,
        .perm = .{ .read = true },
    });
}

/// 把算出来的 Database Hash 写进特征值。字节顺序是 RFC 4493 的字节串顺序，也就是
/// 附录 B 印出来的顺序（最左是最高的字节）。
pub fn setDatabaseHash(db: anytype, value_handle: u16, h: [16]u8) void {
    const a = db.find(value_handle) orelse return;
    @memcpy(a.value[0..16], &h);
}

/// «Server Supported Features»（表 7.9、表 7.10、表 7.11）：第 0 个八位组 bit0 是 EATT
/// Supported。§7.4：只在支持时置位；数组不应有尾随零八位组，所以一个特性都不支持时
/// 值是空的。
pub fn addServerSupportedFeatures(db: anytype, eatt_supported: bool) svr.AddError!ChrHandles {
    const value: []const u8 = if (eatt_supported) &.{0x01} else &.{};
    return addCharacteristic(db, uuid_server_supported_features, 0x02, .{
        .type = .{ .u16 = uuid_server_supported_features },
        .value = value,
        .fixed = true,
        .perm = .{ .read = true },
    });
}
