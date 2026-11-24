//! ble-802154：IPv6 over Bluetooth LE（RFC 7668）与它的 6LoWPAN IPHC 绑定。
//!
//! 规范出处（条款号与原文一致）：
//!   * RFC 7668 §3.2.2：IID = 48 位设备地址中间插 0xFF、0xFE，位原样拷贝（图 6），
//!     不翻转 U/L 位；链路本地地址 = fe80::/64 + IID（图 7）；
//!   * RFC 7668 §3.2.4：必须用 RFC 6282 的 IPHC；SAC=0/SAM=11 表示“由设备地址
//!     推出的链路本地地址”；SAC=1/SAM=11 的前提是该地址是对该前缀**最近登记**
//!     的地址；未登记的 IID 整个内联（SAM=01），前 48 位与最近登记的相同则只带
//!     后 16 位（SAM=10）；
//!   * RFC 7668 §3.2.4.1：6LN → 远端用 SAC=1 SAM=11，目的有上下文时 DAC=1，
//!     DAM=01（64 位前缀）或 DAM=11（128 位地址）；6LBR → 6LN 反过来；
//!   * RFC 7668 §3.2.4.2：同一前缀下登记多个地址时只有最近的可全省略，其余
//!     SAM=10 或 SAM=01；
//!   * RFC 7668 §3.2.5：BLE 链路层没有组播；6LN 发组播一律单播给 6LBR；6LBR
//!     按链路粒度记录组播监听者，只复制给登记过的 6LN；
//!   * RFC 7668 §3：“Fragmentation features from 6LoWPAN standards are not used”：
//!     分片由 L2CAP 层负责，所以这里不实现 6LoWPAN 分片重组；
//!   * RFC 6282 §3.1（IPHC 编码：TF、NH、HLIM、CID、SAC/SAM、M/DAC/DAM 的取值）、
//!     §3.1.2（上下文标识扩展：SCI | DCI 各 4 位，16 个上下文）、§3.2（内联字段
//!     顺序）、§3.2.1（Traffic Class / Flow Label 的四种内联形式）、§4.3
//!     （UDP NHC：C 与 P 的取值）。
//!
//! 与 `fifteen4.zig` 的关系：UDP NHC 头的解码与链路层无关，直接复用
//! `fifteen4.decodeUdpNhc`（它接受 RFC 6282 §4.3.3 的全部 P/C 取值）。IPHC 的
//! 地址部分不能复用——`fifteen4.iphc` 现在虽已有上下文表（RFC 6775 6CO 的前缀/
//! 有效期/C 位）与全部 SAM/DAM 取值，但它的 IID 推导仍是 802.15.4 口径
//! （16 位短地址映射 `0000:00ff:fe00:XXXX`、64 位 EUI-64 且**翻转 U/L 位**，
//! RFC 6282 §3.2.2）；BLE 是 6 字节地址、位原样拷贝不翻转（RFC 7668 §3.2.2），
//! 还要“最近登记的 IID”语义（§3.2.4），所以这里另写。
//!
//! 上下文的前缀长度只支持 64 位或 128 位——RFC 7668 §3.2.4.1 点名的两种；
//! 其它长度返回 `BadContext`。

const std = @import("std");

const fifteen4 = @import("fifteen4.zig");

pub const Error = error{
    Short,
    NoSpace,
    Trailing,
    /// dispatch 不是 IPHC（011xxxxx）。
    BadDispatch,
    /// 是 IPHC 但用了本组件不支持的编码：非 UDP 的 NHC、带上下文的组播、
    /// 6LoWPAN 分片头等。
    Unsupported,
    /// 前缀长度不是 64 或 128。
    BadContext,
    /// IPHC 指向一个没有配置的上下文。
    NoContext,
    /// UDP 校验和被省略（C=1）。RFC 6282 §4.3.2 要求解压方重算并确认另有完整性
    /// 保护；本组件做不到，按“MUST drop the packet”拒收。
    ChecksumElided,
    BadVersion,
    /// 不是组播地址，或链路句柄非法。
    BadParam,
    TableFull,
};

// ---------------------------------------------------------------------------
// 地址映射（RFC 7668 §3.2.2）
// ---------------------------------------------------------------------------

/// 48 位设备地址 → 64 位 IID：地址中间插入 0xFF 0xFE，每一位都原样拷贝
/// （RFC 7668 §3.2.2 图 6，不翻转 U/L 位）。
///
/// 地址用 HCI 字节序（最低有效字节在前），所以 IID 的前两个字节是地址的最高
/// 两字节。把“48 位地址”当整数、最高位在前读进 IID，是对图 6 的直接读法；
/// 与参考实现的逐字节对拍还没有做，见 README「待验证项」。
pub fn iid(addr: [6]u8) [8]u8 {
    return .{ addr[5], addr[4], 0xFF, 0xFE, addr[3], addr[2], addr[1], addr[0] };
}

/// 链路本地地址 fe80::/64 + IID（RFC 7668 §3.2.2 图 7）。
pub fn linkLocal(addr: [6]u8) [16]u8 {
    var a: [16]u8 = @splat(0);
    a[0] = 0xFE;
    a[1] = 0x80;
    @memcpy(a[8..16], &iid(addr));
    return a;
}

/// fe80::/10（RFC 4291 §2.5.6）。
pub fn isLinkLocal(a: [16]u8) bool {
    return a[0] == 0xFE and (a[1] & 0xC0) == 0x80;
}

/// ff00::/8（RFC 4291 §2.7）。
pub fn isMulticast(a: [16]u8) bool {
    return a[0] == 0xFF;
}

pub fn isUnspecified(a: [16]u8) bool {
    return std.mem.allEqual(u8, &a, 0);
}

/// RFC 7668 推荐的 IPv6 MTU（§3.2：“use of a 1280-octet MTU is RECOMMENDED”）。
pub const recommended_mtu: usize = 1280;

// ---------------------------------------------------------------------------
// 压缩上下文（RFC 6282 §3.1.2；RFC 7668 §3.2.4）
// ---------------------------------------------------------------------------

/// 一个压缩上下文：前缀 + 该前缀下**最近登记**的 IID。
///
/// “最近登记”是 RFC 7668 的概念：6LN 用 ARO 向 6LBR 登记地址，6LBR 记住
/// 设备地址 ↔ IID；只有最近登记的那个地址可以全省略（SAM=11 / DAM=11）。
/// 发送侧（6LN）把它填成自己的 IID，接收侧（6LBR）填成对端登记的 IID。
pub const Context = struct {
    prefix: [16]u8 = @splat(0),
    /// 前缀长度（位）：64 或 128；0 表示这个上下文未使用。
    prefix_len: u8 = 0,
    latest_iid: [8]u8 = @splat(0),
    has_iid: bool = false,

    /// 前缀覆盖的字节数。
    pub fn bytes(self: Context) usize {
        return @as(usize, self.prefix_len) / 8;
    }
};

/// 16 个上下文，编号即 CID 扩展里的 SCI / DCI。RFC 6282 §3.1.2。
pub const Contexts = struct {
    ctx: [16]Context = @splat(.{}),

    /// 设一个前缀。`bits` 只能是 64（DAM=01 那种）或 128（DAM=11 那种）。
    pub fn set(self: *Contexts, id: u4, prefix: [16]u8, bits: u8) Error!void {
        if (bits != 64 and bits != 128) return error.BadContext;
        self.ctx[id] = .{ .prefix = prefix, .prefix_len = bits };
    }

    /// 设前缀并登记该前缀下的最新 IID（RFC 7668 §3.2.4）。
    pub fn setWithIid(self: *Contexts, id: u4, prefix: [16]u8, bits: u8, latest: [8]u8) Error!void {
        try self.set(id, prefix, bits);
        self.ctx[id].latest_iid = latest;
        self.ctx[id].has_iid = true;
    }

    pub fn clear(self: *Contexts, id: u4) void {
        self.ctx[id] = .{};
    }

    pub fn get(self: *const Contexts, id: u4) Error!Context {
        const c = self.ctx[id];
        if (c.prefix_len == 0) return error.NoContext;
        return c;
    }

    /// 前缀匹配 `addr` 的**最长**上下文编号：128 位的优先于 64 位的。
    pub fn match(self: *const Contexts, addr: [16]u8) ?u4 {
        var best: ?u4 = null;
        var best_len: u8 = 0;
        for (self.ctx, 0..) |c, i| {
            if (c.prefix_len == 0 or c.prefix_len <= best_len) continue;
            const n = c.bytes();
            if (std.mem.eql(u8, c.prefix[0..n], addr[0..n])) {
                best = @intCast(i);
                best_len = c.prefix_len;
            }
        }
        return best;
    }
};

// ---------------------------------------------------------------------------
// 地址模式（RFC 6282 §3.1.1 的 SAC/SAM、DAC/DAM 取值）
// ---------------------------------------------------------------------------

/// 一个地址怎么编：`stateful` 即 SAC/DAC=1；`mode` 即 SAM/DAM。
const Mode = struct {
    stateful: bool = false,
    ctx_id: u4 = 0,
    /// 00 = 128 位内联，01 = 64 位内联，10 = 16 位内联，11 = 全省略。
    mode: u2 = 0,
};

/// 单播地址的最短编法。
fn unicastMode(addr: [16]u8, link_addr: [6]u8, ctxs: *const Contexts) Error!Mode {
    // SAC=1、SAM=00 固定表示未指定地址 ::。
    if (isUnspecified(addr)) return .{ .stateful = true, .mode = 0b00 };
    if (ctxs.match(addr)) |id| {
        const c = try ctxs.get(id);
        if (c.bytes() == 16) return .{ .stateful = true, .ctx_id = id, .mode = 0b11 };
        // IID 与最近登记的相同 → 全省略（RFC 7668 §3.2.4 “latest registered”）。
        if (c.has_iid and std.mem.eql(u8, addr[8..16], &c.latest_iid)) {
            return .{ .stateful = true, .ctx_id = id, .mode = 0b11 };
        }
        // 前 48 位与最近登记的相同 → 只带后 16 位（§3.2.4、§3.2.4.2）。
        if (c.has_iid and std.mem.eql(u8, addr[8..14], c.latest_iid[0..6])) {
            return .{ .stateful = true, .ctx_id = id, .mode = 0b10 };
        }
        return .{ .stateful = true, .ctx_id = id, .mode = 0b01 };
    }
    if (isLinkLocal(addr)) {
        if (std.mem.eql(u8, addr[8..16], &iid(link_addr))) return .{ .mode = 0b11 };
        return .{ .mode = 0b01 };
    }
    return .{ .mode = 0b00 };
}

/// 还原一个单播地址。`inline_bytes` 是按模式取好的内联字节。
fn restoreUnicast(
    stateful: bool,
    mode: u2,
    ctx_id: u4,
    ctxs: *const Contexts,
    link_addr: [6]u8,
    inline_bytes: []const u8,
) Error![16]u8 {
    var addr: [16]u8 = @splat(0);
    if (!stateful) {
        switch (mode) {
            0b00 => {
                if (inline_bytes.len != 16) return error.Short;
                @memcpy(&addr, inline_bytes);
                return addr;
            },
            0b01 => {
                if (inline_bytes.len != 8) return error.Short;
                addr[0] = 0xFE;
                addr[1] = 0x80;
                @memcpy(addr[8..16], inline_bytes);
                return addr;
            },
            0b10 => {
                if (inline_bytes.len != 2) return error.Short;
                addr[0] = 0xFE;
                addr[1] = 0x80;
                addr[11] = 0xFF;
                addr[12] = 0xFE;
                @memcpy(addr[14..16], inline_bytes);
                return addr;
            },
            else => {
                addr[0] = 0xFE;
                addr[1] = 0x80;
                @memcpy(addr[8..16], &iid(link_addr));
                return addr;
            },
        }
    }
    // SAC=1：先定 IID，再用上下文覆盖前缀那几位（“Bits covered by context
    // information are always used”）。
    var c = Context{};
    if (mode != 0b00) c = try ctxs.get(ctx_id);
    switch (mode) {
        0b00 => {}, // ::
        0b01 => {
            if (inline_bytes.len != 8) return error.Short;
            @memcpy(addr[8..16], inline_bytes);
        },
        0b10 => {
            if (inline_bytes.len != 2) return error.Short;
            // 前 48 位取最近登记的 IID（RFC 7668 §3.2.4）；没有登记记录时退回
            // RFC 6282 §3.1.1 的 0000:00ff:fe00:XXXX 映射。
            const base: [8]u8 = if (c.has_iid) c.latest_iid else .{ 0, 0, 0, 0xFF, 0xFE, 0, 0, 0 };
            @memcpy(addr[8..14], base[0..6]);
            @memcpy(addr[14..16], inline_bytes);
        },
        else => {
            // 全省略：最近的登记 IID；没有就按设备地址算（§3.2.2 的映射）。
            @memcpy(addr[8..16], if (c.has_iid) &c.latest_iid else &iid(link_addr));
        },
    }
    const n = c.bytes();
    @memcpy(addr[0..n], c.prefix[0..n]);
    return addr;
}

/// 组播目的地址的 DAM（M=1、DAC=0）。RFC 6282 §3.1.1：
/// 11 = ff02::00XX，10 = ffXX::00XX:XXXX，01 = ffXX::00XX:XXXX:XXXX，00 = 128 位。
fn multicastMode(addr: [16]u8) u2 {
    const zero = struct {
        fn f(a: [16]u8, lo: usize, hi: usize) bool {
            return std.mem.allEqual(u8, a[lo..hi], 0);
        }
    }.f;
    if (addr[1] == 0x02 and zero(addr, 2, 15)) return 0b11;
    if (zero(addr, 2, 13)) return 0b10;
    if (zero(addr, 2, 11)) return 0b01;
    return 0b00;
}

fn restoreMulticast(mode: u2, inline_bytes: []const u8) Error![16]u8 {
    var a: [16]u8 = @splat(0);
    a[0] = 0xFF;
    switch (mode) {
        0b00 => {
            if (inline_bytes.len != 16) return error.Short;
            @memcpy(&a, inline_bytes);
        },
        0b01 => {
            if (inline_bytes.len != 6) return error.Short;
            a[1] = inline_bytes[0];
            @memcpy(a[11..16], inline_bytes[1..6]);
        },
        0b10 => {
            if (inline_bytes.len != 4) return error.Short;
            a[1] = inline_bytes[0];
            @memcpy(a[13..16], inline_bytes[1..4]);
        },
        else => {
            if (inline_bytes.len != 1) return error.Short;
            a[1] = 0x02;
            a[15] = inline_bytes[0];
        },
    }
    return a;
}

const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn byte(self: *Writer, v: u8) Error!void {
        if (self.n >= self.buf.len) return error.NoSpace;
        self.buf[self.n] = v;
        self.n += 1;
    }

    fn raw(self: *Writer, s: []const u8) Error!void {
        if (s.len > self.buf.len - self.n) return error.NoSpace;
        @memcpy(self.buf[self.n..][0..s.len], s);
        self.n += s.len;
    }
};

const Reader = struct {
    buf: []const u8,
    n: usize = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.n >= self.buf.len) return error.Short;
        const v = self.buf[self.n];
        self.n += 1;
        return v;
    }

    fn take(self: *Reader, len: usize) Error![]const u8 {
        if (len > self.buf.len - self.n) return error.Short;
        const s = self.buf[self.n .. self.n + len];
        self.n += len;
        return s;
    }
};

fn be16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | @as(u16, b[1]);
}

fn writeUnicast(w: *Writer, mode: Mode, addr: [16]u8) Error!void {
    if (!mode.stateful) {
        switch (mode.mode) {
            0b00 => try w.raw(&addr),
            0b01 => try w.raw(addr[8..16]),
            0b10 => try w.raw(addr[14..16]),
            else => {},
        }
        return;
    }
    switch (mode.mode) {
        0b01 => try w.raw(addr[8..16]),
        0b10 => try w.raw(addr[14..16]),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// 压缩
// ---------------------------------------------------------------------------

/// 一条 BLE 链路两端的设备地址：`local` 是本机，`peer` 是对端。地址字节序同 HCI。
pub const Link = struct { local: [6]u8, peer: [6]u8 };

/// 把一个 IPv6 包（40 字节头 + 载荷；UDP 时带完整 8 字节 UDP 头）压成 IPHC。
///
/// 总是选最短的形式：Traffic Class / Flow Label 全 0 就全省；Hop Limit 是
/// 1 / 64 / 255 就编码；UDP 的校验和始终内联（C=0）——RFC 6282 §4.3.2 规定
/// 省略它必须有上层授权并先验算，本组件不走那条路。非 UDP 的下一个头原样
/// 内联（NH=0），不做 NHC。
pub fn compress(out: []u8, packet: []const u8, link: Link, ctxs: *const Contexts) Error!usize {
    if (packet.len < 40) return error.Short;
    if (packet[0] >> 4 != 6) return error.BadVersion;

    const tc: u8 = ((packet[0] & 0x0F) << 4) | (packet[1] >> 4);
    const fl: u32 = (@as(u32, packet[1] & 0x0F) << 16) | (@as(u32, packet[2]) << 8) | @as(u32, packet[3]);
    const tf: u2 = if (tc == 0 and fl == 0) 0b11 else if (fl == 0) 0b10 else if (tc == 0) 0b01 else 0b00;
    const is_udp = packet[6] == 17 and packet.len >= 48;
    const hl: u2 = switch (packet[7]) {
        1 => 0b01,
        64 => 0b10,
        255 => 0b11,
        else => 0b00,
    };

    var src_addr: [16]u8 = undefined;
    @memcpy(&src_addr, packet[8..24]);
    var dst_addr: [16]u8 = undefined;
    @memcpy(&dst_addr, packet[24..40]);
    const src = try unicastMode(src_addr, link.local, ctxs);
    const m = isMulticast(dst_addr);
    const dst: Mode = if (m) .{} else try unicastMode(dst_addr, link.peer, ctxs);
    const dam: u2 = if (m) multicastMode(dst_addr) else dst.mode;
    const cid = (src.stateful and src.ctx_id != 0) or (!m and dst.stateful and dst.ctx_id != 0);

    var w = Writer{ .buf = out };
    try w.byte(0x60 | (@as(u8, tf) << 3) | (@as(u8, @intFromBool(is_udp)) << 2) | @as(u8, hl));
    try w.byte(
        (@as(u8, @intFromBool(cid)) << 7) |
            (@as(u8, @intFromBool(src.stateful)) << 6) |
            (@as(u8, src.mode) << 4) |
            (@as(u8, @intFromBool(m)) << 3) |
            (@as(u8, @intFromBool(!m and dst.stateful)) << 2) |
            @as(u8, dam),
    );
    // TF：RFC 6282 §3.2.1 图 4–6。Traffic Class 右旋 2 位后 ECN 落在最高两位。
    switch (tf) {
        0b00 => {
            try w.byte(tc);
            try w.byte(@truncate(fl >> 16));
            try w.byte(@truncate(fl >> 8));
            try w.byte(@truncate(fl));
        },
        0b01 => {
            try w.byte((tc & 0xC0) | @as(u8, @truncate(fl >> 16)));
            try w.byte(@truncate(fl >> 8));
            try w.byte(@truncate(fl));
        },
        0b10 => try w.byte(tc),
        else => {},
    }
    if (!is_udp) try w.byte(packet[6]);
    if (hl == 0b00) try w.byte(packet[7]);
    if (cid) {
        try w.byte((@as(u8, src.ctx_id) << 4) | (if (m) @as(u8, 0) else @as(u8, dst.ctx_id)));
    }
    try writeUnicast(&w, src, src_addr);
    if (m) {
        switch (dam) {
            0b11 => try w.byte(dst_addr[15]),
            0b10 => {
                try w.byte(dst_addr[1]);
                try w.raw(dst_addr[13..16]);
            },
            0b01 => {
                try w.byte(dst_addr[1]);
                try w.raw(dst_addr[11..16]);
            },
            else => try w.raw(&dst_addr),
        }
    } else {
        try writeUnicast(&w, dst, dst_addr);
    }
    if (is_udp) {
        const sport = be16(packet[40..42]);
        const dport = be16(packet[42..44]);
        const in4 = struct {
            fn short(p: u16) bool {
                return p >= 0xF0B0 and p <= 0xF0BF;
            }
            fn byte(p: u16) bool {
                return p >= 0xF000 and p <= 0xF0FF;
            }
        };
        const p: u2 = if (in4.short(sport) and in4.short(dport))
            0b11
        else if (in4.byte(dport))
            0b01
        else if (in4.byte(sport))
            0b10
        else
            0b00;
        try w.byte(0xF0 | @as(u8, p));
        switch (p) {
            // 两个端口各带低 4 位，合成一个字节：源端口在前（§4.3.3）。
            0b11 => try w.byte((@as(u8, @truncate(sport & 0x0F)) << 4) | @as(u8, @truncate(dport & 0x0F))),
            0b01 => {
                try w.raw(packet[40..42]);
                try w.byte(@truncate(dport));
            },
            0b10 => {
                try w.byte(@truncate(sport));
                try w.raw(packet[42..44]);
            },
            else => try w.raw(packet[40..44]),
        }
        try w.raw(packet[46..48]); // 校验和，C=0
        try w.raw(packet[48..]);
    } else {
        try w.raw(packet[40..]);
    }
    return w.n;
}

// ---------------------------------------------------------------------------
// 解压
// ---------------------------------------------------------------------------

pub const Decoded = struct {
    /// 还原后的 IPv6 包：40 字节头 + UDP 头（如果被 NHC 压缩）+ 载荷。
    packet: []const u8,
    next_header: u8,
    /// UDP 头是由 NHC 还原的。
    udp_compressed: bool,
};

/// 把一帧 6LoWPAN IPHC 解成 IPv6 包写进 `out`。
pub fn decompress(out: []u8, frame: []const u8, link: Link, ctxs: *const Contexts) Error!Decoded {
    if (frame.len < 2) return error.Short;
    if ((frame[0] & 0xE0) != 0x60) {
        // 6LoWPAN 分片头（11xxxxxx）等其它 dispatch：RFC 7668 §3 明确 BLE 不用。
        return if ((frame[0] & 0xC0) == 0xC0) error.Unsupported else error.BadDispatch;
    }
    if (out.len < 40) return error.NoSpace;
    const b0 = frame[0];
    const b1 = frame[1];
    const tf: u2 = @truncate((b0 >> 3) & 0x03);
    const nh_compressed = (b0 & 0x04) != 0;
    const hl: u2 = @truncate(b0 & 0x03);
    var r = Reader{ .buf = frame, .n = 2 };
    var sci: u4 = 0;
    var dci: u4 = 0;
    if ((b1 & 0x80) != 0) {
        const c = try r.byte();
        sci = @truncate(c >> 4);
        dci = @truncate(c);
    }
    const sac = (b1 & 0x40) != 0;
    const sam: u2 = @truncate((b1 >> 4) & 0x03);
    const m = (b1 & 0x08) != 0;
    const dac = (b1 & 0x04) != 0;
    const dam: u2 = @truncate(b1 & 0x03);

    var hdr: [40]u8 = @splat(0);
    hdr[0] = 0x60;
    var tc: u8 = 0;
    var fl: u32 = 0;
    switch (tf) {
        0b00 => {
            const t = try r.take(4);
            tc = t[0];
            fl = (@as(u32, t[1]) << 16) | (@as(u32, t[2]) << 8) | @as(u32, t[3]);
        },
        0b01 => {
            const t = try r.take(3);
            tc = t[0] & 0xC0;
            fl = (@as(u32, t[0] & 0x0F) << 16) | (@as(u32, t[1]) << 8) | @as(u32, t[2]);
        },
        0b10 => tc = try r.byte(),
        else => {},
    }
    hdr[0] |= tc >> 4;
    hdr[1] = (tc << 4) | @as(u8, @truncate(fl >> 16));
    hdr[2] = @truncate(fl >> 8);
    hdr[3] = @truncate(fl);
    var next_header: u8 = 0;
    if (!nh_compressed) next_header = try r.byte();
    hdr[7] = switch (hl) {
        0b01 => 1,
        0b10 => 64,
        0b11 => 255,
        else => try r.byte(),
    };
    hdr[6] = if (nh_compressed) 17 else next_header;

    // 地址：先按模式读出内联字节，再还原。
    const src_len: usize = switch (sam) {
        0b00 => if (sac) 0 else 16,
        0b01 => 8,
        0b10 => 2,
        else => 0,
    };
    // 源地址由**发送方**的链路地址还原（对端），目的地址由接收方自己的还原。
    const src = try restoreUnicast(sac, sam, sci, ctxs, link.peer, try r.take(src_len));
    @memcpy(hdr[8..24], &src);

    var dst: [16]u8 = undefined;
    if (m) {
        if (dac) return error.Unsupported; // 带上下文的组播（M=1 且 DAC=1）
        const dst_len: usize = switch (dam) {
            0b00 => 16,
            0b01 => 6,
            0b10 => 4,
            else => 1,
        };
        dst = try restoreMulticast(dam, try r.take(dst_len));
    } else {
        // M=0、DAC=1、DAM=00 是 Reserved（RFC 6282 §3.1.1）。
        if (dac and dam == 0b00) return error.Unsupported;
        const dst_len: usize = switch (dam) {
            0b00 => 16,
            0b01 => 8,
            0b10 => 2,
            else => 0,
        };
        dst = try restoreUnicast(dac, dam, dci, ctxs, link.local, try r.take(dst_len));
    }
    @memcpy(hdr[24..40], &dst);

    if (nh_compressed) {
        // 只有 UDP NHC（11110CPP）；其它 NHC 不支持。
        if (r.n >= frame.len) return error.Short;
        if ((frame[r.n] & 0xF8) != 0xF0) return error.Unsupported;
        const nhc = fifteen4.decodeUdpNhc(frame[r.n..]) catch |err| return switch (err) {
            error.Short => error.Short,
            else => error.Unsupported,
        };
        if (!nhc.checksum_present) return error.ChecksumElided;
        if (out.len < 48 + nhc.rest.len) return error.NoSpace;
        std.mem.writeInt(u16, hdr[4..6], @intCast(8 + nhc.rest.len), .big);
        @memcpy(out[0..40], &hdr);
        std.mem.writeInt(u16, out[40..42], nhc.src_port, .big);
        std.mem.writeInt(u16, out[42..44], nhc.dst_port, .big);
        std.mem.writeInt(u16, out[44..46], @intCast(8 + nhc.rest.len), .big);
        std.mem.writeInt(u16, out[46..48], nhc.checksum, .big);
        @memcpy(out[48 .. 48 + nhc.rest.len], nhc.rest);
        return .{ .packet = out[0 .. 48 + nhc.rest.len], .next_header = 17, .udp_compressed = true };
    }
    const rest = frame[r.n..];
    if (out.len < 40 + rest.len) return error.NoSpace;
    std.mem.writeInt(u16, hdr[4..6], @intCast(rest.len), .big);
    @memcpy(out[0..40], &hdr);
    @memcpy(out[40 .. 40 + rest.len], rest);
    return .{ .packet = out[0 .. 40 + rest.len], .next_header = next_header, .udp_compressed = false };
}

// ---------------------------------------------------------------------------
// 组播监听者（RFC 7668 §3.2.5）
// ---------------------------------------------------------------------------

/// 6LBR 侧的组播监听表：按**链路**（HCI Connection_Handle）而不是按子网记录。
/// RFC 7668 §3.2.5：“The 6LBR MUST keep track of multicast listeners at Bluetooth
/// LE link-level granularity …, and it MUST NOT forward multicast packets to 6LNs
/// that have not registered as listeners”。6LN 侧不需要这张表：组播一律单播给
/// 6LBR。
pub const ListenerTable = struct {
    pub const max_entries: usize = 16;
    /// “没有链路”的标记：0x0F00–0x0FFF 是保留的句柄值。
    pub const no_link: u12 = 0x0FFF;

    pub const Entry = struct { link: u12 = no_link, group: [16]u8 = @splat(0) };

    entries: [max_entries]Entry = @splat(.{}),

    /// 登记“这条链路上的 6LN 要收这个组播”。不是组播地址 → `BadParam`；
    /// 重复登记是空操作；表满 → `TableFull`。
    pub fn add(self: *ListenerTable, link: u12, group: [16]u8) Error!void {
        if (!isMulticast(group)) return error.BadParam;
        if (link == no_link or link > 0x0EFF) return error.BadParam;
        if (self.isListening(link, group)) return;
        for (&self.entries) |*e| {
            if (e.link == no_link) {
                e.* = .{ .link = link, .group = group };
                return;
            }
        }
        return error.TableFull;
    }

    pub fn remove(self: *ListenerTable, link: u12, group: [16]u8) bool {
        for (&self.entries) |*e| {
            if (e.link == link and std.mem.eql(u8, &e.group, &group)) {
                e.* = .{};
                return true;
            }
        }
        return false;
    }

    pub fn isListening(self: *const ListenerTable, link: u12, group: [16]u8) bool {
        for (&self.entries) |*e| {
            if (e.link == link and std.mem.eql(u8, &e.group, &group)) return true;
        }
        return false;
    }

    /// 链路断开时清掉它的全部登记。
    pub fn forgetLink(self: *ListenerTable, link: u12) void {
        for (&self.entries) |*e| {
            if (e.link == link) e.* = .{};
        }
    }

    /// 要把发往 `group` 的包复制到哪些链路：按登记顺序写进 `out`，返回个数。
    /// 个数为 0 就是不转发。
    pub fn linksFor(self: *const ListenerTable, group: [16]u8, out: []u12) Error!usize {
        var n: usize = 0;
        for (&self.entries) |*e| {
            if (e.link == no_link) continue;
            if (!std.mem.eql(u8, &e.group, &group)) continue;
            if (n == out.len) return error.NoSpace;
            out[n] = e.link;
            n += 1;
        }
        return n;
    }
};
