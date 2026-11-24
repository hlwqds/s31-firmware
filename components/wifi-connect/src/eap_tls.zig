//! wifi-connect：EAP-TLS（RFC 5216）的记录分片 / 重组与握手驱动。
//!
//! 边界：
//!   * **不实现 TLS**。TLS 引擎经 `Engine` 注入：本层把引擎一次给出的一整段 TLS 记录
//!     （RFC 5216 2.1.5 说的「TLS message or set of messages」）切成 EAP-TLS 分片发出去，
//!     把对端的分片重组回一整段再交给引擎，并处理 EAP-TLS Start 与分片确认。
//!   * EAP 包头（Code / Identifier / Length / Type）和 peer 的通用规则（Identity、Nak、
//!     Success / Failure）在 `eap.zig`；本文件不 import 它。
//!   * 不 import board / log，不分配堆内存。缓冲是 `Method` 里的定长数组，大小在编译期定；
//!     板侧栈只有 16 KiB，含 `Method` 的对象要放在文件作用域。
//!
//! 判据与条款（RFC 5216，括号里是印刷页）：
//!   1. EAP-TLS 的 Type 是 13（3.1，20 页）。Flags 八位组 `|L M S R R R R R|`：L=0x80、M=0x40、
//!      S=0x20，低 5 位保留——发方置 0，收方忽略（3.1，21 页；3.2，22 页）。
//!   2. Start 是「an EAP-Request packet with EAP-Type=EAP-TLS, the Start (S) bit set, and no
//!      data」，peer 收到后发 ClientHello（2.1.1，4 页）。S 把 Start 和分片确认区分开（3.1，
//!      21 页）；S 与 L、M 或数据并存都不是 Start。
//!   3. 发送：L「MUST be set for the first fragment of a fragmented TLS message or set of
//!      messages」，M「set on all but the last fragment」，TLS Message Length 占 4 八位组、给总长
//!      （2.1.5，14 页）。未分片的单条消息不带 L，与 wpa_supplicant 相同
//!      （`src/eap_peer/eap_tls_common.c` 的 `eap_tls_process_output`）。
//!   4. 接收：带 M 的 Request 先回「an EAP-Response with EAP-Type=EAP-TLS and no data」当确认，
//!      对方收到确认才发下一片；Identifier 逐片递增，确认带同一个 Identifier（2.1.5，14 页）。
//!   5. 拒绝：L 字段不足 4 八位组、声明总长为 0 或超过缓冲、数据超出或凑不够声明总长、
//!      M 与总长矛盾、首片带 M 却没有 L。
//!   6. 我方分片没发完时对端不该送来新数据（2.1.5，15 页：「The EAP peer MUST wait until it
//!      receives the EAP-Request before sending another fragment」，反过来对服务器也是逐片确认）；
//!      遇到就判本端失败并回空响应，对方随后发 EAP-Failure（2.1.3，8 页）。wpa_supplicant 同样
//!      处理（`eap_tls_common.c` 的 `eap_peer_tls_process_helper` → `eap_tls.c` 的 `eap_tls_failure`）。
//!   7. 密钥：MSK = Key_Material(0,63)，EMSK = Key_Material(64,127)（2.3，18 页，图 2）；
//!      PMK 是 MSK 的前 32 八位组，出处见 `pmkFromMsk`。
//!
//! TLS 本身（版本协商、密码套件、证书校验、Finished、MSK 的 PRF）都在引擎里。wpa_supplicant
//! 为 TLS 1.3 加的受保护成功指示（`eap_tls.c` 引 RFC 9190 2.5）不在这里：RFC 9190 原文不在盘上，
//! 会话形状按 RFC 5216 走——握手完成后 peer 回一个空的 EAP-TLS 响应，等 EAP-Success（2.1.3，9 页）。

const std = @import("std");

// ---------------------------------------------------------------------------
// 常数与错误
// ---------------------------------------------------------------------------

/// EAP-TLS 的 EAP Type（RFC 5216 3.1「Type: 13 -- EAP-TLS」；§4 IANA Considerations）。
pub const eap_type: u8 = 13;

/// Flags 八位组（RFC 5216 3.1、3.2 的图，L 在最高位）。
pub const flag_length_included: u8 = 0x80;
pub const flag_more_fragments: u8 = 0x40;
pub const flag_start: u8 = 0x20;
/// 低 5 位保留：发方置 0，收方忽略（3.1、3.2）。
pub const flag_reserved: u8 = 0x1f;

/// MSK 是 64 八位组（RFC 5216 2.3：MSK = Key_Material(0,63)）。
pub const msk_len = 64;
pub const emsk_len = 64;
pub const key_material_len = msk_len + emsk_len;
/// PMK 是 256 位 = 32 八位组（802.11-2016 12.7.1.3；AKM 00-0F-AC:12 的 384 位不在本函数范围）。
pub const pmk_len = 32;

pub const Error = error{
    /// 没有 Flags 八位组，或 Flags 的组合不成立（Start 带 L / M / 数据、首片带 M 却没有 L）。
    BadFlags,
    /// TLS Message Length 字段不足 4 八位组、声明为 0，或与分片实际长度对不上。
    BadLength,
    /// 声明的总长超过重组缓冲。
    RxTooLong,
    /// 引擎一次给的记录超过发送缓冲。
    TxTooLong,
    /// 输出缓冲放不下这一段 Type-Data。
    NoBufferSpace,
    /// TLS 引擎报错；具体错误在 `Method.last_engine_error`。
    Engine,
    /// 握手已经起过，再次收到 Start，而引擎没有提供 `resetFn`。
    EngineNotResettable,
};

/// 本端判定握手失败的原因。
pub const Failure = enum {
    /// 引擎拒收对端的记录（例如收到 fatal alert、Finished 验不过）。
    engine,
    /// 我方分片没发完，对端却送来了新数据。
    data_while_sending,
};

// ---------------------------------------------------------------------------
// 注入的 TLS 引擎
// ---------------------------------------------------------------------------

/// TLS 引擎。`Method` 只在 EAP-TLS Start 之后、以及每收到一整段对端记录之后调用它。
pub const Engine = struct {
    ctx: ?*anyopaque = null,
    /// 取出下一段待发的 TLS 记录（一整段，可以含多条记录）。**返回值是这一段的总长**，最多往
    /// `buf` 写 `buf.len` 八位组；放不下时不必写，`Method` 见到返回值大于缓冲就报 `TxTooLong`。
    /// 0 = 暂时没有要发的。
    pullFn: *const fn (ctx: ?*anyopaque, buf: []u8) usize,
    /// 喂入对端的一整段记录（已经重组完整）。返回错误表示本端判定握手失败。
    pushFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!void,
    /// 引擎是否已完成握手：客户端 Finished 已经生成，可以经 `pull` 取走。
    doneFn: *const fn (ctx: ?*anyopaque) bool,
    /// MSK，64 八位组（RFC 5216 2.3：MSK = Key_Material(0,63)）。
    mskFn: *const fn (ctx: ?*anyopaque) [msk_len]u8,
    /// 握手重新开始时复位引擎；null = 引擎不支持，再次收到 Start 会报 `EngineNotResettable`。
    resetFn: ?*const fn (ctx: ?*anyopaque) void = null,

    pub fn pull(self: Engine, buf: []u8) usize {
        return self.pullFn(self.ctx, buf);
    }

    pub fn push(self: Engine, bytes: []const u8) anyerror!void {
        return self.pushFn(self.ctx, bytes);
    }

    pub fn isHandshakeDone(self: Engine) bool {
        return self.doneFn(self.ctx);
    }

    pub fn msk(self: Engine) [msk_len]u8 {
        return self.mskFn(self.ctx);
    }

    pub fn reset(self: Engine) void {
        if (self.resetFn) |f| f(self.ctx);
    }
};

// ---------------------------------------------------------------------------
// Flags 八位组
// ---------------------------------------------------------------------------

pub const Flags = struct {
    /// L：后面跟着 4 八位组的 TLS Message Length。
    length_included: bool = false,
    /// M：后面还有分片。
    more: bool = false,
    /// S：EAP-TLS Start。
    start: bool = false,

    /// 保留位收下就丢（3.1、3.2：「MUST ignore them on reception」）。
    pub fn parse(byte: u8) Flags {
        return .{
            .length_included = byte & flag_length_included != 0,
            .more = byte & flag_more_fragments != 0,
            .start = byte & flag_start != 0,
        };
    }

    /// 保留位写 0（3.1、3.2：「MUST set the reserved bits to zero」）。
    pub fn encode(self: Flags) u8 {
        var byte: u8 = 0;
        if (self.length_included) byte |= flag_length_included;
        if (self.more) byte |= flag_more_fragments;
        if (self.start) byte |= flag_start;
        return byte;
    }
};

// ---------------------------------------------------------------------------
// 密钥
// ---------------------------------------------------------------------------

/// PMK = MSK 的前 32 八位组。出处（逐字）：
///
///   RFC 5216 2.3（18 页）：
///     Enc-RECV-Key = MSK(0,31) = Peer to Authenticator Encryption Key
///                    (MS-MPPE-Recv-Key in [RFC2548]).  Also known as the
///                    PMK in [IEEE-802.11].
///
///   IEEE Std 802.11-2016 12.7.1.3（2009 页）：
///     With all other AKM suite selectors, the length of the PMK, PMK_bits, shall be 256 bits.
///     When not using a PSK, the PMK is derived from the MSK. The PMK shall be computed as the first
///     PMK_bits bits (bits 0 to PMK_bits–1) of the MSK: PMK = L(MSK, 0, PMK_bits).
///   （等号在文本抽取里是一个内嵌公式对象，显示为 \003。）
///
/// AKM 00-0F-AC:12 的 PMK 是 384 位，不归这个函数管；调用方按 AKM 取。
pub fn pmkFromMsk(msk: [msk_len]u8) [pmk_len]u8 {
    return msk[0..pmk_len].*;
}

pub const Keys = struct {
    msk: [msk_len]u8,
    emsk: [emsk_len]u8,
};

/// Key_Material 的前后两半：MSK = Key_Material(0,63)，EMSK = Key_Material(64,127)
/// （RFC 5216 2.3，18 页；图 2 画的就是 MSK(0,31) | MSK(32,63) | EMSK(0,63)）。
/// Key_Material 本身（TLS-PRF-128）由引擎算，这里只切。
pub fn splitKeyMaterial(km: [key_material_len]u8) Keys {
    return .{ .msk = km[0..msk_len].*, .emsk = km[msk_len..][0..emsk_len].* };
}

// ---------------------------------------------------------------------------
// Type-Data 的编码
// ---------------------------------------------------------------------------

pub const Fragment = struct {
    data: []const u8,
    /// 这一串分片的总长；只在 `length_included` 时写出去。
    total: usize = 0,
    more: bool = false,
    length_included: bool = false,
};

/// 写一段 Response 的 Type-Data：`Flags [TLS Message Length] TLS data`（RFC 5216 3.2 的图）。
pub fn encodeTypeData(out: []u8, f: Fragment) Error!usize {
    if (f.length_included and f.total > std.math.maxInt(u32)) return error.BadLength;
    const need = 1 + (if (f.length_included) @as(usize, 4) else 0) + f.data.len;
    if (out.len < need) return error.NoBufferSpace;
    out[0] = (Flags{
        .length_included = f.length_included,
        .more = f.more,
    }).encode();
    var n: usize = 1;
    if (f.length_included) {
        std.mem.writeInt(u32, out[1..5], @intCast(f.total), .big);
        n = 5;
    }
    @memcpy(out[n..][0..f.data.len], f.data);
    return need;
}

/// 空的 EAP-TLS 包：只有 Flags 八位组、值为 0。既是分片确认，也是握手完成后 peer 的空响应。
pub fn encodeAck(out: []u8) Error!usize {
    if (out.len < 1) return error.NoBufferSpace;
    out[0] = (Flags{}).encode();
    return 1;
}

/// `Rx.accept` 的结果。
pub const Outcome = union(enum) {
    /// EAP-TLS Start：本端该开始（或重新开始）握手。
    start,
    /// 这一片收下了，对端还有后片：回分片确认。
    ack,
    /// 对端发来的是空包（它对我方分片的确认），没有数据。
    empty,
    /// 一整段记录已经完整，交给引擎。切片指向调用方的输入或 `Rx` 自己的缓冲。
    complete: []const u8,
};

// ---------------------------------------------------------------------------
// 接收：重组
// ---------------------------------------------------------------------------

pub fn RxSized(comptime rx_max: usize) type {
    return struct {
        const Self = @This();
        pub const capacity: usize = rx_max;

        buf: [rx_max]u8 = undefined,
        /// 已经收到的八位组数。
        len: usize = 0,
        /// L 声明的总长；0 = 没有进行中的重组。
        total: usize = 0,

        pub fn busy(self: *const Self) bool {
            return self.total != 0;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.total = 0;
        }

        /// 收一个 Request/EAP-TLS 的 Type-Data（从 Flags 八位组起）。出错时重组状态一并清掉。
        pub fn accept(self: *Self, data: []const u8) Error!Outcome {
            return self.step(data) catch |e| {
                self.clear();
                return e;
            };
        }

        fn step(self: *Self, data: []const u8) Error!Outcome {
            if (data.len == 0) return error.BadFlags;
            const flags = Flags.parse(data[0]);
            var frag: []const u8 = data[1..];

            if (flags.start) {
                // Start 没有数据（2.1.1）；带上别的就是另一个意思，不当成 Start。
                if (flags.length_included or flags.more or frag.len != 0) return error.BadFlags;
                self.clear();
                return .start;
            }

            // L 给出这一串分片的总长；不带 L 时为 null。
            var declared: ?usize = null;
            if (flags.length_included) {
                if (frag.len < 4) return error.BadLength;
                declared = std.mem.readInt(u32, frag[0..4], .big);
                // 长度为 0 的「TLS message or set of messages」不存在；带着数据更对不上。
                if (declared == 0) return error.BadLength;
                frag = frag[4..];
            }

            if (self.total == 0) {
                if (declared == null) {
                    // 不带 L：只能是没分片的单条消息。
                    if (flags.more) return error.BadFlags; // 首片带 M 就必须带 L（2.1.5、3.1）
                    if (frag.len == 0) return .empty;
                    return .{ .complete = frag };
                }
                if (declared.? > rx_max) return error.RxTooLong;
                self.total = declared.?;
            } else if (declared != null and declared.? != self.total) {
                // 续片带 L 时总长必须和首片一致，否则不知道该信哪一个。
                return error.BadLength;
            }
            if (frag.len == 0) return error.BadLength;

            const remaining = self.total - self.len;
            if (frag.len > remaining) return error.BadLength; // 超出声明总长
            if (flags.more and frag.len == remaining) return error.BadLength; // 说还有后片，总长却到头了
            if (!flags.more and frag.len < remaining) return error.BadLength; // 说这是最后一片，总长却没到

            @memcpy(self.buf[self.len..][0..frag.len], frag);
            self.len += frag.len;
            if (flags.more) return .ack;
            const n = self.len;
            self.len = 0;
            self.total = 0;
            return .{ .complete = self.buf[0..n] };
        }
    };
}

// ---------------------------------------------------------------------------
// 握手驱动
// ---------------------------------------------------------------------------

pub const Config = struct {
    /// 重组缓冲：要装得下一整段「TLS message or set of messages」。RFC 5216 2.1.5 建议 64 KB 封顶；
    /// 16384 是一条 TLS 记录的上限，够放一条证书链。
    rx_max: usize = 16384,
    /// 发送缓冲：要装得下引擎一次 `pull` 给出的整段记录。
    tx_max: usize = 16384,
    /// 每个 EAP-TLS 包里 TLS 数据的上限。1398 是 wpa_supplicant 的默认值
    /// （`src/eap_peer/eap_config.h`：fragment_size "(default 1398)"）。
    fragment: usize = 1398,
};

fn validateConfig(comptime cfg: Config) void {
    if (cfg.fragment == 0) @compileError("eap_tls.Config.fragment 不能为 0");
    // EAP Length 字段只有 16 位：EAPOL 头 4 + EAP 头 4 + Type 1 + Flags 1 + Length 4 + 数据。
    if (cfg.fragment > std.math.maxInt(u16) - 14) @compileError("eap_tls.Config.fragment 太大，EAP Length 字段放不下");
}

pub fn MethodSized(comptime cfg: Config) type {
    comptime validateConfig(cfg);
    return struct {
        const Self = @This();
        pub const config: Config = cfg;
        /// 一帧 EAP-TLS 响应里 Type-Data 的最大长度：Flags + Length + 数据。
        pub const type_data_max: usize = 1 + 4 + cfg.fragment;

        engine: Engine,
        rx: RxSized(cfg.rx_max) = .{},
        tx_buf: [cfg.tx_max]u8 = undefined,
        /// 引擎这次给的记录总长；0 = 没有东西要发。
        tx_len: usize = 0,
        /// 已经交给上层发出去的八位组数。
        tx_pos: usize = 0,
        /// 已经因为 Start 调过引擎。
        started: bool = false,
        failure: ?Failure = null,
        /// `failure == .engine` 时引擎给出的具体错误。
        last_engine_error: ?anyerror = null,

        pub fn init(engine: Engine) Self {
            return .{ .engine = engine };
        }

        pub fn txPending(self: *const Self) bool {
            return self.tx_pos < self.tx_len;
        }

        /// 握手算完成：没判过失败、对端的记录都收齐了、我方的记录都发出去了、引擎说完成。
        /// `eap.Peer` 用它判断 EAP-Success 该不该信。
        pub fn handshakeDone(self: *const Self) bool {
            return self.failure == null and !self.rx.busy() and !self.txPending() and
                self.started and self.engine.isHandshakeDone();
        }

        pub fn msk(self: *const Self) [msk_len]u8 {
            return self.engine.msk();
        }

        /// 处理一个 Request/EAP-TLS 的 Type-Data（从 Flags 八位组起），把 Response 的 Type-Data
        /// 写进 `out`，返回写下的长度。报错时不写 `out`、不发任何东西；状态改动只有一种——
        /// 这一片自己不合法时把收了一半的重组清掉（对端的下一片反正接不上）。
        pub fn onRequest(self: *Self, data: []const u8, out: []u8) Error!usize {
            if (data.len == 0) return error.BadFlags;
            const flags = Flags.parse(data[0]);

            if (flags.start) {
                if (flags.length_included or flags.more or data.len != 1) return error.BadFlags;
                // 第一次 Start 时引擎本来就是新的；只有握手已经起过才需要复位重来。
                if (self.started and self.engine.resetFn == null) return error.EngineNotResettable;
                if (self.started) self.engine.reset();
                self.clear();
                self.started = true;
                return self.emit(out);
            }

            if (self.failure != null) {
                // 已经判失败：对端的数据不再交给引擎。还欠着的分片（例如 TLS alert 的后半段）
                // 照发；否则回空响应，对方收到后会发 EAP-Failure（2.1.3，8 页）。
                if (data.len == 1 and self.txPending()) return self.buildNext(out);
                self.dropTx();
                return encodeAck(out);
            }

            switch (try self.rx.accept(data)) {
                .start => unreachable, // 上面已经处理过
                .ack => return encodeAck(out),
                .empty => {
                    // 对端确认了我方上一个分片：发下一片；没有待发的就回空包。
                    if (self.txPending()) return self.buildNext(out);
                    return encodeAck(out);
                },
                .complete => |msg| {
                    if (self.txPending()) {
                        // 我方的分片还没被逐片确认，对端就送来了新数据：它没有在等我。
                        self.dropTx();
                        self.failure = .data_while_sending;
                        return encodeAck(out);
                    }
                    return self.deliver(msg, out);
                },
            }
        }

        /// 把一整段对端记录交给引擎，再把引擎的回答发出去。
        fn deliver(self: *Self, msg: []const u8, out: []u8) Error!usize {
            self.engine.push(msg) catch |e| {
                // 本端判失败后仍要回一个 EAP-TLS 响应，对方才会发 EAP-Failure（2.1.3，8–9 页）。
                // 引擎若留了记录要发（例如 TLS alert），照发；否则回空的。
                self.dropTx();
                self.failure = .engine;
                self.last_engine_error = e;
                return self.emit(out);
            };
            return self.emit(out);
        }

        /// 向引擎要下一段记录，发出第一片（没有就回空包）。
        fn emit(self: *Self, out: []u8) Error!usize {
            const n = self.engine.pull(&self.tx_buf);
            if (n > self.tx_buf.len) return error.TxTooLong;
            self.tx_len = n;
            self.tx_pos = 0;
            if (n == 0) return encodeAck(out);
            return self.buildNext(out);
        }

        fn buildNext(self: *Self, out: []u8) Error!usize {
            std.debug.assert(self.txPending());
            const remaining = self.tx_len - self.tx_pos;
            const take = @min(cfg.fragment, remaining);
            const frag = Fragment{
                .data = self.tx_buf[self.tx_pos..][0..take],
                .total = self.tx_len,
                .more = take < remaining,
                // 只有真的要分片时首片才带 L（2.1.5）。
                .length_included = self.tx_pos == 0 and self.tx_len > cfg.fragment,
            };
            const n = try encodeTypeData(out, frag);
            // 写成功之后才推进：`out` 放不下时这一片还能重发。
            self.tx_pos += take;
            if (!frag.more) self.dropTx();
            return n;
        }

        fn dropTx(self: *Self) void {
            self.tx_len = 0;
            self.tx_pos = 0;
        }

        fn clear(self: *Self) void {
            self.rx.clear();
            self.dropTx();
            self.failure = null;
            self.last_engine_error = null;
        }
    };
}

pub const Method = MethodSized(.{});
