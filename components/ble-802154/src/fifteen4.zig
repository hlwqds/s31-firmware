//! ble-802154：802.15.4 MAC 帧头 + 6LoWPAN 适配层（RFC 4944 / RFC 6282）。
//!
//! 这一半和 BLE 那半**不是同一种东西**：S31 上的 802.15.4 MAC/驱动层没有归档，
//! 驱动是 IDF 里的 C 源码；射频层仍是闭源（`libphy.a` + `libbtbb.a`）。
//! 详见全部 27.2 与 `tools/symbols.sh` 的第 6 节：
//! `components/ieee802154/` 10 个文件 3571 行、`esp_hal_ieee802154/esp32s31`
//! 的 `ieee802154_ll.h`）。本组件因此把 802.15.4 侧写成“纯字节变换”，不分配堆内存。
//!
//! 四块的规范出处：
//!
//!   1. MAC 帧头（FCF / 序列号 / 地址模式 / PAN 压缩）——IEEE 802.15.4-2015
//!      §7.2.1（Frame Control）、§7.2.2（Sequence Number）、§7.2.3（Addressing）；
//!   2. `iphc`：LOWPAN_IPHC 压缩与解压，两个方向、全部取值——RFC 6282 §3.1.1（TF /
//!      NH / HLIM / CID / SAC / SAM / M / DAC / DAM）、§3.1.2（图 3，上下文标识）、
//!      §3.2.1（图 4–6，Traffic Class 右旋 2 位）、§3.2.2（由封装头推 IID）、
//!      §3.2.3（图 7–9，组播 48 / 32 / 8 位）、§3.2.4（图 10，基于单播前缀的组播）；
//!      上下文表的有效期状态机——RFC 6775 §4.2（6CO 的 C 位与 Valid Lifetime）、
//!      §5.4.2（存表规则）、§5.4.3（过期后 receive-only 再删除）；
//!   3. NHC——RFC 6282 §4.1、§4.2（图 13 的 IPv6 扩展头：EID 0–4 与 7、Length 以八位组
//!      计、尾部填充的省略与补回）、§4.3（UDP：C 与 P 的全部取值；§4.3.2 省略校验和的
//!      条件与解压方重算）；
//!   4. RFC 4944 的适配层头：§5.1 dispatch（图 2；ESC 的 0x7F 被 RFC 6282 §5 抢占，
//!      RFC 8025 §3 把 1111xxxx 定为分页 dispatch）、§5.2 Mesh 头、§5.3 分片头与重组
//!      规则、§11 转发规则（Hops Left 递减与丢帧）、§11.1 BC0。
//!
//! 边界（都没做）：
//!   * 6LoWPAN-ND（RFC 6775）的协议本体——只实现它的上下文表，不解析 RA / 6CO 报文；
//!   * Mesh 路由——只实现 Mesh 头和 §11 的 hop 规则，不查路由表、不泛洪；
//!   * RFC 8930（多跳转发）与 RFC 8931（分片恢复）；
//!   * RFC 4944 §10 的 LOWPAN_HC1 / HC2 解压（RFC 6282 §2：MAY）、Thread MLE；
//!   * 分页 dispatch 的 Page 2–15（RFC 8025 §4 只把 Page 1 定义成与 IPHC 同值）。
//!
//! FCF 的位序（IEEE 802.15.4-2015 §7.2.1.1，与本文档的 `u16` 小端一致）：
//!
//!   bit0..2   Frame Type     000 beacon / 001 data / 010 ack / 011 command
//!   bit3      Security Enabled
//!   bit4      Frame Pending
//!   bit5      Ack Request
//!   bit6      PAN ID Compression
//!   bit7      Reserved
//!   bit8      Sequence Number Suppression
//!   bit9      IE Present
//!   bit10..11 Destination Addressing Mode  00 none / 10 short / 11 long
//!   bit12..13 Frame Version
//!   bit14..15 Source Addressing Mode
//!
//! 于是“数据帧 + 请求 ACK + PAN 压缩 + 双短地址 + version 0”
//! = 0001 + 0020 + 0040 + 0800 + 8000 = **0x8861**，小端字节序是 `61 88`。
//! 这是判据 ⑨ 的 KAT；同一组位展开成“目标短地址 + 源长地址”就是 0xC861。
//!
//! **旧入口 `decompress`**：只做无状态压缩的 4 个组合、UDP NHC 的全部 P/C 取值。
//! `selftest.zig` 的判据 ⑪⑫ 与 `host_tests.zig` 的 `lowpan: …` 用例绑定了它的行为，那些
//! 文件不在本切片可改范围（除已改的三处期望值），所以原样保留。内联 16 位地址按 RFC 6282
//! §3.2（行 590-591）高字节在前（lwIP `lowpan6_common.c:521-522` 同此）；扩展头 NHC 只按
//! 线上形状核对、不解析链。完整实现见 `iphc`；新代码不要调用这里。

const std = @import("std");

pub const Error = error{
    Short,
    NoSpace,
    /// 地址模式是 01（保留）或与 PAN 压缩组合非法。
    BadAddressMode,
    /// 6LoWPAN dispatch 不是这个入口要解的那种，或适配层头栈的顺序违反 RFC 4944 §5。
    BadDispatch,
    /// 本实现不解的编码：旧入口的“不支持”、分页 dispatch 的 Page 2–15、ESC 的扩展字节。
    UnsupportedCompression,
    /// 待压缩的包不是 IPv6（版本号不是 6）。
    BadVersion,
    /// 上下文定义非法（前缀长度超过 128 位）。
    BadContext,
    /// IPHC 指向一个不存在、已删除或已过保持期的上下文。
    NoContext,
    /// RFC 6282 明确标为 Reserved 的编码。
    Reserved,
    /// NH=1 之后不是任何 NHC 编码，或扩展头的长度与 8 字节单位矛盾。
    BadNhc,
    /// 要省略 UDP 校验和，但这条链路没有另外的完整性保护（RFC 6282 §4.3.2）。
    NoIntegrityCheck,
    /// 要省略的 UDP 校验和本身是错的（RFC 6282 §4.3.2：MUST drop）。
    BadChecksum,
    /// 分片头或分片内容不一致（偏移越界、非末片不是 8 的倍数、首片解出来不是 8 的倍数）。
    BadFrag,
    /// 数据报超过 11 位 datagram_size，或一帧放不下最小的分片。
    TooLong,
    /// 压缩头放不进首片（RFC 6282 §2：放不进首片的头不得压缩）。
    HeaderTooLong,
    /// 重组表已满。
    TableFull,
    /// 重组超时超过 RFC 4944 §5.3 规定的 60 s 上限。
    TimeoutTooLong,
    /// Mesh 头非法（Hops Left 超过 255、地址被截断）。
    BadMesh,
    /// 嵌套的 IPv6 头层数超过 `iphc.max_nesting`。
    TooDeep,
};

/// 802.15.4 帧类型。§7.2.1.1 表 7-1。
pub const FrameType = enum(u3) {
    beacon = 0,
    data = 1,
    ack = 2,
    command = 3,
};

/// 地址模式。§7.2.1.1 表 7-2：00 无、10 短（16 位）、11 长（64 位）。
pub const AddrMode = enum(u2) {
    none = 0,
    reserved = 1,
    short = 2,
    long = 3,
};

/// 帧控制字段的逻辑视图。
pub const Fcf = struct {
    frame_type: FrameType = .data,
    security: bool = false,
    frame_pending: bool = false,
    ack_request: bool = true,
    pan_compress: bool = true,
    seq_suppress: bool = false,
    ie_present: bool = false,
    dest_mode: AddrMode = .short,
    version: u2 = 0,
    src_mode: AddrMode = .short,

    pub fn encode(self: Fcf) u16 {
        var w: u16 = 0;
        w |= @as(u16, @backingInt(self.frame_type));
        w |= @as(u16, @intFromBool(self.security)) << 3;
        w |= @as(u16, @intFromBool(self.frame_pending)) << 4;
        w |= @as(u16, @intFromBool(self.ack_request)) << 5;
        w |= @as(u16, @intFromBool(self.pan_compress)) << 6;
        w |= @as(u16, @intFromBool(self.seq_suppress)) << 8;
        w |= @as(u16, @intFromBool(self.ie_present)) << 9;
        w |= @as(u16, @backingInt(self.dest_mode)) << 10;
        w |= @as(u16, self.version) << 12;
        w |= @as(u16, @backingInt(self.src_mode)) << 14;
        return w;
    }

    pub fn decode(w: u16) Fcf {
        return .{
            .frame_type = @fromBackingInt(@intCast(@as(u3, @truncate(w)))),
            .security = (w & 0x0008) != 0,
            .frame_pending = (w & 0x0010) != 0,
            .ack_request = (w & 0x0020) != 0,
            .pan_compress = (w & 0x0040) != 0,
            .seq_suppress = (w & 0x0100) != 0,
            .ie_present = (w & 0x0200) != 0,
            .dest_mode = @fromBackingInt(@intCast(@as(u2, @truncate(w >> 10)))),
            .version = @truncate(w >> 12),
            .src_mode = @fromBackingInt(@intCast(@as(u2, @truncate(w >> 14)))),
        };
    }
};

/// 802.15.4 地址。
pub const Addr = union(enum) {
    short: u16,
    long: [8]u8,

    pub fn mode(self: Addr) AddrMode {
        return switch (self) {
            .short => .short,
            .long => .long,
        };
    }
};

pub fn addrEql(a: Addr, b: Addr) bool {
    return switch (a) {
        .short => |v| b == .short and b.short == v,
        .long => |v| b == .long and std.mem.eql(u8, &v, &b.long),
    };
}

/// MAC 头（不含辅助安全头/IE，本组件不支持）。
pub const MacHeader = struct {
    fcf: Fcf,
    seq: u8,
    dest_pan: u16,
    dest: Addr,
    src_pan: u16,
    src: Addr,
};

pub const Stats = struct {
    frames_encoded: u32 = 0,
    frames_decoded: u32 = 0,
    decompressed: u32 = 0,
    rejected: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

fn putU16(out: []u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

fn getU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

/// 网络字节序（大端）。6LoWPAN 的 UDP 字段按 RFC 6282 §4.3.3 保持
/// “与 UDP 头里相同的顺序”，也就是网络序；这一点和 802.15.4 自己的
/// 小端字段（PAN/短地址）不同，是最容易写错的一处。
fn getU16Be(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn addrLen(m: AddrMode) Error!usize {
    return switch (m) {
        .none => 0,
        .short => 2,
        .long => 8,
        .reserved => error.BadAddressMode,
    };
}

/// 编码 MAC 头。返回头长度。
///
/// 地址顺序（§7.2.3）：Dest PAN → Dest Address → [Src PAN] → Src Address。
/// `pan_compress` 为真时省略 Src PAN（此时两者必须相同，本组件不校验，
/// 因为真实栈在 PIB 层保证）。
pub fn encodeHeader(out: []u8, h: MacHeader, stats: *Stats) Error!usize {
    const dlen = try addrLen(h.dest.mode());
    const slen = try addrLen(h.src.mode());
    const needs_src_pan = !h.fcf.pan_compress and slen > 0;
    const total = 2 + 1 + 2 + dlen + (if (needs_src_pan) @as(usize, 2) else 0) + slen;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    var i: usize = 0;
    putU16(out[0..2], h.fcf.encode());
    i = 2;
    out[i] = h.seq;
    i += 1;
    putU16(out[i .. i + 2], h.dest_pan);
    i += 2;
    switch (h.dest) {
        .short => |a| {
            putU16(out[i .. i + 2], a);
            i += 2;
        },
        .long => |a| {
            @memcpy(out[i .. i + 8], &a);
            i += 8;
        },
    }
    if (needs_src_pan) {
        putU16(out[i .. i + 2], h.src_pan);
        i += 2;
    }
    switch (h.src) {
        .short => |a| {
            putU16(out[i .. i + 2], a);
            i += 2;
        },
        .long => |a| {
            @memcpy(out[i .. i + 8], &a);
            i += 8;
        },
    }
    stats.frames_encoded += 1;
    return i;
}

/// 解出 MAC 头，返回头与剩余字节（6LoWPAN 载荷）。
pub const Decoded = struct { header: MacHeader, payload: []const u8 };

pub fn decodeHeader(bytes: []const u8, stats: *Stats) Error!Decoded {
    if (bytes.len < 3) {
        stats.rejected += 1;
        return error.Short;
    }
    const fcf = Fcf.decode(getU16(bytes[0..2]));
    if (fcf.security or fcf.ie_present or fcf.seq_suppress) {
        // 辅助安全头、IE、序列号抑制都会改变后续布局，本组件不支持。
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    const dlen = try addrLen(fcf.dest_mode);
    const slen = try addrLen(fcf.src_mode);
    const needs_src_pan = !fcf.pan_compress and slen > 0;
    const total = 2 + 1 + 2 + dlen + (if (needs_src_pan) @as(usize, 2) else 0) + slen;
    if (bytes.len < total) {
        stats.rejected += 1;
        return error.Short;
    }
    var i: usize = 3;
    const dest_pan = getU16(bytes[i .. i + 2]);
    i += 2;
    const dest: Addr = switch (fcf.dest_mode) {
        .short => blk: {
            const a = getU16(bytes[i .. i + 2]);
            i += 2;
            break :blk .{ .short = a };
        },
        .long => blk: {
            var a: [8]u8 = undefined;
            @memcpy(&a, bytes[i .. i + 8]);
            i += 8;
            break :blk .{ .long = a };
        },
        .none => .{ .short = 0 },
        .reserved => return error.BadAddressMode,
    };
    var src_pan: u16 = dest_pan;
    if (needs_src_pan) {
        src_pan = getU16(bytes[i .. i + 2]);
        i += 2;
    }
    const src: Addr = switch (fcf.src_mode) {
        .short => blk: {
            const a = getU16(bytes[i .. i + 2]);
            i += 2;
            break :blk .{ .short = a };
        },
        .long => blk: {
            var a: [8]u8 = undefined;
            @memcpy(&a, bytes[i .. i + 8]);
            i += 8;
            break :blk .{ .long = a };
        },
        .none => .{ .short = 0 },
        .reserved => return error.BadAddressMode,
    };
    stats.frames_decoded += 1;
    return .{
        .header = .{
            .fcf = fcf,
            .seq = bytes[2],
            .dest_pan = dest_pan,
            .dest = dest,
            .src_pan = src_pan,
            .src = src,
        },
        .payload = bytes[total..],
    };
}

// ---------------------------------------------------------------------------
// 由链路层地址推 IID
// ---------------------------------------------------------------------------

/// 由 16 位短地址推出 IID：0000:00ff:fe00:XXXX。
///
/// 出处是 RFC 6282 §3.2.2（“Short addresses are mapped into the restricted
/// space of IEEE EUI-64 addresses by setting the middle 16 bits to 0xfffe, the
/// bottom 16 bits to the short address, and all other bits to zero”）。
/// 注意不要把它说成 RFC 4944 §6 的规则：那一节给的是「PAN ID ‖ 0000 ‖ 短地址」的
/// 伪 48 位派生，会把 PAN ID 掺进 IID；6282 的口径是 PAN 不进 IID。
fn iidFromShort(a: u16, out: *[8]u8) void {
    out.* = .{ 0x00, 0x00, 0x00, 0xff, 0xfe, 0x00, 0x00, 0x00 };
    out[6] = @truncate(a >> 8);
    out[7] = @truncate(a);
}

/// 由 EUI-64 推出 IID：按 RFC 4291 附录 A 的映射，把 U/L 位（第一个字节的 bit1）
/// 取反。RFC 6282 §3.2.2、RFC 4944 §6 引用同一条规则。
fn iidFromLong(a: [8]u8, out: *[8]u8) void {
    out.* = a;
    out[0] ^= 0x02;
}

fn iidFromLink(a: Addr, out: *[8]u8) void {
    switch (a) {
        .short => |s| iidFromShort(s, out),
        .long => |l| iidFromLong(l, out),
    }
}

// ---------------------------------------------------------------------------
// 旧入口：无状态 IPHC 解压（判据 ⑪⑫ 绑定，见文件头）
// ---------------------------------------------------------------------------

/// 解压出的 IPv6 报文：40 字节头 + UDP 头字段 + 应用数据切片。
pub const Ipv6 = struct {
    hdr: [40]u8,
    udp: Udp,
    payload: []const u8,

    pub fn version(self: *const Ipv6) u8 {
        return self.hdr[0] >> 4;
    }
    pub fn payloadLen(self: *const Ipv6) u16 {
        return getU16(self.hdr[4..6]);
    }
    pub fn nextHeader(self: *const Ipv6) u8 {
        return self.hdr[6];
    }
    pub fn hopLimit(self: *const Ipv6) u8 {
        return self.hdr[7];
    }
    pub fn src(self: *const Ipv6) [16]u8 {
        var a: [16]u8 = undefined;
        @memcpy(&a, self.hdr[8..24]);
        return a;
    }
    pub fn dst(self: *const Ipv6) [16]u8 {
        var a: [16]u8 = undefined;
        @memcpy(&a, self.hdr[24..40]);
        return a;
    }
};

pub const Udp = struct {
    src_port: u16,
    dst_port: u16,
    checksum: u16,
    /// false 表示校验和被 6LoWPAN 省略（NHC 的 C=1），值为 0。
    checksum_present: bool,
};

/// 把 IID 写进 16 字节地址的后 8 字节：源地址偏移 16，目标地址偏移 32
/// （前 8 字节是该地址的 fe80:: 前缀）。
fn writeIid(hdr: *[40]u8, off: usize, iid: [8]u8) void {
    @memcpy(hdr[off .. off + 8], &iid);
}

/// UDP NHC（11110CPP，RFC 6282 §4.3.3 图 14）的解码结果。`rest` 是 NHC 之后的载荷。
pub const UdpNhc = struct {
    src_port: u16,
    dst_port: u16,
    checksum: u16,
    /// false 表示校验和被省略（C=1），值为 0。
    checksum_present: bool,
    rest: []const u8,
};

/// 解一个 UDP NHC 头（从 11110CPP 字节开始）。与链路层无关，`ipsp.zig` 与 `iphc` 也用它。
/// 四种 P、两种 C 都解；端口与校验和按网络序。可压缩的端口段：0xf000–0xf0ff
/// 压掉高 8 位，0xf0b0–0xf0bf 压掉高 12 位（RFC 6282 §4.3.1、§4.3.3）。
pub fn decodeUdpNhc(bytes: []const u8) Error!UdpNhc {
    if (bytes.len < 1) return error.Short;
    const nhc = bytes[0];
    if ((nhc & 0xf8) != 0xf0) return error.UnsupportedCompression;
    const checksum_present = (nhc & 0x04) == 0;
    const p: u2 = @truncate(nhc & 0x03);
    var i: usize = 1;
    var sport: u16 = 0;
    var dport: u16 = 0;
    if (p == 0b11) {
        if (bytes.len < i + 1) return error.Short;
        sport = 0xf0b0 | @as(u16, bytes[i] >> 4);
        dport = 0xf0b0 | @as(u16, bytes[i] & 0x0f);
        i += 1;
    } else {
        if (p == 0b00 or p == 0b01) {
            if (bytes.len < i + 2) return error.Short;
            sport = getU16Be(bytes[i .. i + 2]);
            i += 2;
        } else {
            if (bytes.len < i + 1) return error.Short;
            sport = 0xf000 | @as(u16, bytes[i]);
            i += 1;
        }
        if (p == 0b00 or p == 0b10) {
            if (bytes.len < i + 2) return error.Short;
            dport = getU16Be(bytes[i .. i + 2]);
            i += 2;
        } else {
            if (bytes.len < i + 1) return error.Short;
            dport = 0xf000 | @as(u16, bytes[i]);
            i += 1;
        }
    }
    var csum: u16 = 0;
    if (checksum_present) {
        if (bytes.len < i + 2) return error.Short;
        csum = getU16Be(bytes[i .. i + 2]);
        i += 2;
    }
    return .{
        .src_port = sport,
        .dst_port = dport,
        .checksum = csum,
        .checksum_present = checksum_present,
        .rest = bytes[i..],
    };
}

/// 解压一个无状态 IPHC 报文——旧入口，只接受既有用例用到的那一种编码。
///
/// 支持的组合（全部 RFC 6282 §3.1.1 无状态列）：
///   TF=11（Traffic Class 与 Flow Label 全省）、NH=1（下一个头走 NHC）、
///   HLIM=11（Hop Limit=255）、CID=0、SAC=0、SAM∈{10,11}、
///   M=0、DAC=0、DAM∈{10,11}。
/// 下一个头只接受 UDP NHC（11110CPP）的 P=00。其余一律 `UnsupportedCompression`
/// 并把 `stats.rejected` 加一——判据 ⑫ 就是拿这个拒绝路径当被测对象的。
///
/// 完整实现见 `iphc`；新代码不要调用这里。
pub fn decompress(lowpan: []const u8, mac: *const MacHeader, stats: *Stats) Error!Ipv6 {
    if (lowpan.len < 2) {
        stats.rejected += 1;
        return error.Short;
    }
    // dispatch：011xxxxx。低 5 位属于 IPHC 编码。
    if ((lowpan[0] & 0xe0) != 0x60) {
        stats.rejected += 1;
        return error.BadDispatch;
    }
    const b0 = lowpan[0];
    const b1 = lowpan[1];
    const tf: u2 = @truncate((b0 >> 3) & 0x03);
    const nh_compressed = (b0 & 0x04) != 0;
    const hlim: u2 = @truncate(b0 & 0x03);
    const cid = (b1 & 0x80) != 0;
    const sac = (b1 & 0x40) != 0;
    const sam: u2 = @truncate((b1 >> 4) & 0x03);
    const m = (b1 & 0x08) != 0;
    const dac = (b1 & 0x04) != 0;
    const dam: u2 = @truncate(b1 & 0x03);

    if (tf != 0x03 or !nh_compressed or hlim != 0x03 or cid or sac or m or dac) {
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    if (sam == 0x00 or dam == 0x00) {
        // 128 位内联地址：合法但本入口不解（判据 ⑫ 只用 SAC/sam 组合做拒绝用例）。
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }

    var i: usize = 2;
    var hdr: [40]u8 = @splat(0);
    hdr[0] = 0x60; // version 6, TC/FL 全 0
    hdr[6] = 17; // UDP
    hdr[7] = 255; // HLIM=11
    // 源/目标都是 link-local：fe80::/64。
    hdr[8] = 0xfe;
    hdr[9] = 0x80;
    hdr[24] = 0xfe;
    hdr[25] = 0x80;

    // 源地址
    switch (sam) {
        0x02 => {
            if (lowpan.len < i + 2) {
                stats.rejected += 1;
                return error.Short;
            }
            // RFC 6282 §3.2（行 590-591）：内联字段与 IPv6 头同序 → 高字节在前
            // （lwIP lowpan6_common.c:521-522 同此）。
            const short = getU16Be(lowpan[i .. i + 2]);
            i += 2;
            var iid: [8]u8 = undefined;
            iidFromShort(short, &iid);
            writeIid(&hdr, 16, iid);
        },
        0x03 => {
            const src = mac.src;
            var iid: [8]u8 = undefined;
            iidFromLink(src, &iid);
            writeIid(&hdr, 16, iid);
        },
        else => unreachable,
    }

    // 目标地址
    switch (dam) {
        0x02 => {
            if (lowpan.len < i + 2) {
                stats.rejected += 1;
                return error.Short;
            }
            const short = getU16Be(lowpan[i .. i + 2]);
            i += 2;
            var iid: [8]u8 = undefined;
            iidFromShort(short, &iid);
            writeIid(&hdr, 32, iid);
        },
        0x03 => {
            const dst = mac.dest;
            var iid: [8]u8 = undefined;
            iidFromLink(dst, &iid);
            writeIid(&hdr, 32, iid);
        },
        else => unreachable,
    }

    // NHC：11110CPP（UDP，§4.3.3）或 1110ENHN（扩展头，§4.2）。UDP 的四种 P、两种 C
    // 都是合法编码（`decodeUdpNhc` 全解）；扩展头本入口不解，但先按线上形状核对——
    // 缺字节是 Short，链式编码才是“本入口不支持”。
    if (i >= lowpan.len) {
        stats.rejected += 1;
        return error.Short;
    }
    const nhc = lowpan[i];
    if ((nhc & 0xe0) == 0xe0 and (nhc & 0xf8) != 0xf0) {
        // 线上顺序（§4.2）：[NH=0 时 inline 的后继头类型][Length][body]。
        var j = i + 1;
        if (nhc & 0x01 == 0) {
            if (j >= lowpan.len) {
                stats.rejected += 1;
                return error.Short;
            }
            j += 1;
        }
        if (j >= lowpan.len) {
            stats.rejected += 1;
            return error.Short;
        }
        const body: usize = lowpan[j];
        j += 1;
        if (lowpan.len < j + body) {
            stats.rejected += 1;
            return error.Short;
        }
        if (nhc & 0x01 == 0) {
            // NH=0：后继头不走 NHC，本入口到此为止。
            stats.rejected += 1;
            return error.UnsupportedCompression;
        }
        // NH=1：后继还是 NHC 链，本入口不解。
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    if ((nhc & 0xf8) != 0xf0) {
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    const udp = decodeUdpNhc(lowpan[i..]) catch |e| {
        if (e == error.Short) stats.rejected += 1;
        return e;
    };
    const c = !udp.checksum_present;
    const sport = udp.src_port;
    const dport = udp.dst_port;
    const csum = udp.checksum;
    const payload = udp.rest;

    // IPv6 Payload Length = UDP 头 8 字节 + 数据。
    putU16(hdr[4..6], 8 + @as(u16, @intCast(payload.len)));

    stats.decompressed += 1;
    return .{
        .hdr = hdr,
        .udp = .{
            .src_port = sport,
            .dst_port = dport,
            .checksum = csum,
            .checksum_present = !c,
        },
        .payload = payload,
    };
}

// ---------------------------------------------------------------------------
// KAT 固定字节串（判据 ⑨–⑫）
// ---------------------------------------------------------------------------

/// FCF：数据帧 + Ack Request + PAN 压缩 + 双短地址 → 0x8861 → `61 88`。
pub const kat_fcf_short = [2]u8{ 0x61, 0x88 };
/// FCF：同上，但源地址是 64 位 → 0xC861 → `61 c8`。
pub const kat_fcf_long_src = [2]u8{ 0x61, 0xc8 };

/// 帧 A（短/短地址）：FCF + seq(0x2A) + DestPAN(0x1234) + Dest(0x0002) + Src(0x9A3C)。
pub const kat_mac_short = [9]u8{
    0x61, 0x88, // FCF = 0x8861
    0x2a, // sequence number
    0x34, 0x12, // dest PAN 0x1234
    0x02, 0x00, // dest short 0x0002
    0x3c, 0x9a, // src short 0x9A3C
};

/// 帧 A 的 6LoWPAN 载荷：
///   7F 22       IPHC：TF=11 NH=1 HLIM=11 | CID=0 SAC=0 SAM=10 M=0 DAC=0 DAM=10
///   3C 9A       源 16 位
///   02 00       目标 16 位
///   F0          NHC UDP：C=0 P=00
///   12 34 56 78 源端口 0x1234、目标端口 0x5678（网络序）
///   AB CD       校验和 0xABCD
///   6F 6B       "ok"
pub const kat_lowpan_short = [15]u8{
    0x7f, 0x22,
    0x3c, 0x9a,
    0x02, 0x00,
    0xf0, 0x12,
    0x34, 0x56,
    0x78, 0xab,
    0xcd, 'o',
    'k',
};

/// FCF 的完整帧（帧头 + 载荷）——判据 ⑨ 直接对它 encode/decode 往返。
pub const kat_frame_short = kat_mac_short ++ kat_lowpan_short;

/// 帧 B 的 MAC 头：源长地址 02:11:22:33:44:55:66:77，目标短地址 0x0002。
pub const kat_mac_long_src = [15]u8{
    0x61, 0xc8, // FCF = 0xC861
    0x2b,
    0x34, 0x12, // dest PAN
    0x02, 0x00, // dest short
    0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // src long
};

/// 帧 B 的载荷：地址全省略（SAM=11 DAM=11）→ IPHC 字节 7F 33。
pub const kat_lowpan_elided = [11]u8{
    0x7f, 0x33,
    0xf0,
    0x00, 0x50, 0x00, 0x35, // 源端口 0x0050(80)、目标端口 0x0035(53)
    0x12, 0x34, 'h',  'i',
};

/// 判据 ⑫ 的拒绝帧：CID=0、SAC=1、SAM=00（未指定地址 ::）、DAC=1、DAM=10——
/// 目的地址要用上下文 0 才能还原，而这个入口没有上下文表。
/// IPHC = 7F 46。
pub const kat_lowpan_stateful = [4]u8{ 0x7f, 0x46, 0x00, 0x00 };

// ---------------------------------------------------------------------------
// dispatch（RFC 4944 §5.1 图 2；RFC 6282 §5；RFC 8025 §3）
// ---------------------------------------------------------------------------

/// 6LoWPAN 载荷首字节的类别。
pub const Dispatch = enum {
    /// 00xxxxxx：NALP，不是 LoWPAN 帧，收到 SHALL 丢弃。
    nalp,
    /// 01000001（0x41）：后面是未压缩的 IPv6 头。
    ipv6,
    /// 01000010（0x42）：LOWPAN_HC1（RFC 4944 §10，本组件不解）。
    hc1,
    /// 01001000（0x48）：LOWPAN_BC0 广播头（RFC 4944 §11.1）。
    bc0,
    /// 01000000（0x40）：ESC 的替代值。RFC 4944 原来的 ESC 是 0x7F，被 RFC 6282 §5
    /// 抢占给 IPHC；0x40 只是“保留给 ESC、等第一个扩展字节分配时再定”，至今没有
    /// 定义任何扩展字节，所以无法解码。
    esc,
    /// 011xxxxx：LOWPAN_IPHC（RFC 6282 §5）。
    iphc,
    /// 10xxxxxx：Mesh 头（RFC 4944 §5.2）。
    mesh,
    /// 11000xxx：分片头，首片（RFC 4944 §5.3 图 4）。
    frag1,
    /// 11100xxx：分片头，后续片（RFC 4944 §5.3 图 5）。
    fragn,
    /// 1111xxxx：分页 dispatch，低 4 位是页号（RFC 8025 §3 图 1）。
    paging,
    /// 其余：RFC 4944 图 2 与 RFC 6282 §5 标为保留。
    reserved,
};

pub fn dispatchOf(b: u8) Dispatch {
    return switch (b) {
        0x00...0x3f => .nalp,
        0x40 => .esc,
        0x41 => .ipv6,
        0x42 => .hc1,
        0x48 => .bc0,
        0x60...0x7f => .iphc,
        0x80...0xbf => .mesh,
        0xc0...0xc7 => .frag1,
        0xe0...0xe7 => .fragn,
        0xf0...0xff => .paging,
        else => .reserved,
    };
}

// ---------------------------------------------------------------------------
// LOWPAN_IPHC：上下文表（RFC 6282 §3.1.2；RFC 6775 §4.2、§5.4.2、§5.4.3）
// ---------------------------------------------------------------------------

/// RFC 6282 对上下文本身的内容没有规定（§3.1.2：“What information is contained
/// within a context information is out of scope”）。这里采用 RFC 6775 §4.2 的
/// 6LoWPAN Context Option 的三个字段：前缀及其有效长度、C 位、Valid Lifetime。
pub const iphc = struct {
    /// 一个压缩上下文：前缀、有效前缀位数（0–128，可以是任意长度或一个 /128 地址）和 C 位。
    pub const Context = struct {
        prefix: [16]u8 = @splat(0),
        /// 有效前缀位数（RFC 6775 §4.2 Context Length）。
        prefix_len: u8 = 0,
        /// C 位（RFC 6775 §4.2）：true 才能用于压缩；false 只用于解压。
        compression: bool = false,
    };

    pub const ContextState = enum {
        /// 没有上下文：压缩和解压都不能用。
        free,
        /// 可用于压缩和解压。
        valid,
        /// 只用于解压（RFC 6775 §5.4.2：C 位为 0 “MUST NOT be used for compression
        /// when sending packets”；§5.4.3：Valid Lifetime 过期后进入这个模式）。
        receive_only,
    };

    pub const Hit = struct { id: u4, ctx: Context };

    /// 16 个上下文，编号即 CID 扩展里的 SCI / DCI（RFC 6282 §3.1.2 图 3）。
    pub const Contexts = struct {
        /// Valid Lifetime 的单位是 60 s（RFC 6775 §4.2）。
        pub const lifetime_unit_ms: u64 = 60 * 1000;
        /// 过期后在 receive-only 模式停留“两倍默认 Router Lifetime”（RFC 6775 §5.4.3）。
        /// 默认 Router Lifetime = 3 × MaxRtrAdvInterval（RFC 4861 §6.2.1 AdvDefaultLifetime），
        /// MaxRtrAdvInterval 默认 600 s（§6.2.2），即 1800 s。
        pub const receive_only_ms: u64 = 2 * 3 * 600 * 1000;

        const Entry = struct {
            live: bool = false,
            ctx: Context = .{},
            /// 可压缩的截止时刻；之后进入 receive-only。
            valid_until: u64 = 0,
            /// 到这个时刻整条删除。
            remove_at: u64 = 0,
        };

        entries: [16]Entry = @splat(.{}),
        /// 当前时刻（ms），由 `tick` 推进。
        now: u64 = 0,

        /// 按 RFC 6775 §5.4.2 存一条上下文：同一 CID 的条目被更新；Valid Lifetime
        /// 为 0 则该条目立即删除（§4.2：“MUST be removed immediately”），不存在时是空操作。
        /// 其它情况新增条目。时间基准是最近一次 `tick` 的时刻。
        pub fn update(
            self: *Contexts,
            id: u4,
            prefix: [16]u8,
            prefix_len: u8,
            compression: bool,
            lifetime_units: u16,
        ) Error!void {
            if (prefix_len > 128) return error.BadContext;
            if (lifetime_units == 0) {
                self.entries[id] = .{};
                return;
            }
            const valid_until = self.now + @as(u64, lifetime_units) * lifetime_unit_ms;
            self.entries[id] = .{
                .live = true,
                .ctx = .{ .prefix = prefix, .prefix_len = prefix_len, .compression = compression },
                .valid_until = valid_until,
                .remove_at = valid_until + receive_only_ms,
            };
        }

        pub fn remove(self: *Contexts, id: u4) void {
            self.entries[id] = .{};
        }

        /// 推进时间并删掉过了保持期的条目。
        pub fn tick(self: *Contexts, now: u64) void {
            self.now = now;
            for (&self.entries) |*e| {
                if (e.live and now >= e.remove_at) e.* = .{};
            }
        }

        pub fn state(self: *const Contexts, id: u4) ContextState {
            const e = self.entries[id];
            if (!e.live) return .free;
            if (self.now < e.valid_until and e.ctx.compression) return .valid;
            return .receive_only;
        }

        /// 解压用：只要条目还在（valid 或 receive_only）就可以取到。
        pub fn get(self: *const Contexts, id: u4) Error!Context {
            if (self.state(id) == .free) return error.NoContext;
            return self.entries[id].ctx;
        }

        /// 压缩用：在可用于压缩（`valid`）的上下文里找 `addr` 的最长前缀匹配。
        pub fn match(self: *const Contexts, addr: [16]u8) ?Hit {
            var best: ?Hit = null;
            for (self.entries, 0..) |e, i| {
                if (!e.live or self.now >= e.valid_until or !e.ctx.compression) continue;
                if (best) |b| {
                    if (e.ctx.prefix_len <= b.ctx.prefix_len) continue;
                }
                if (prefixMatches(addr, e.ctx.prefix, e.ctx.prefix_len)) {
                    best = .{ .id = @intCast(i), .ctx = e.ctx };
                }
            }
            return best;
        }
    };

    /// SAM=11 / DAM=11 要从封装头取的 IID：链路层地址推出的 IID（RFC 6282 §3.2.2），
    /// 或者嵌套 IPv6 时外层 IPv6 地址的低 64 位（§3.2.2 首段）。
    pub const Link = struct {
        src: [8]u8,
        dst: [8]u8,

        /// 从 802.15.4 MAC 头取两端的 IID。
        pub fn fromMac(mac: *const MacHeader) Link {
            var l: Link = undefined;
            iidFromLink(mac.src, &l.src);
            iidFromLink(mac.dest, &l.dst);
            return l;
        }
    };

    pub const CompressOptions = struct {
        /// 上层已授权省略 UDP 校验和（RFC 6282 §4.3.2：隧道封装，或载荷自带覆盖伪头与
        /// 数据的完整性检查）。默认不授权。
        udp_checksum_elision_authorized: bool = false,
        /// 这条链路另有完整性保护（例如 802.15.4 MAC 层的 MIC）。RFC 6282 §4.3.2：
        /// 发送省略了校验和的帧时 MUST 另有完整性检查；解压 C=1 的帧时 MUST 能无歧义
        /// 地确定并验证过它。
        link_integrity: bool = false,
    };

    pub const DecompressOptions = struct {
        link_integrity: bool = false,
    };

    pub const Compressed = struct {
        /// `out[0..frame_len]` 是压缩后的 6LoWPAN 帧（头 + 没有被压缩的载荷）。
        frame_len: usize,
        /// 压缩头代表的未压缩字节数：IPv6 头 40，加上每个被 NHC 压缩的扩展头，再加上
        /// 被压缩的 UDP 头 8。分片头的 datagram_offset 按未压缩的字节计（RFC 6282 §2），
        /// 所以分片器要用它。
        hidden_len: usize,
    };

    pub const Decompressed = struct {
        /// `out[0..]`：还原后的 IPv6 包（40 字节头 + 后续头 + 载荷）。
        packet: []const u8,
        /// IPv6 头里的 Next Header。
        next_header: u8,
        /// 压缩头消耗的输入字节数；其后的输入原样是载荷。
        consumed: usize,
        /// 输入里 UDP 校验和是省略的（C=1），输出里的值是这里重算出来的。
        udp_checksum_elided: bool,
    };

    /// 压缩一个 IPv6 包（40 字节头 + 载荷）。总是选最短的合法形式；UDP 校验和只有
    /// 在 `opts` 明确授权且链路另有完整性保护时才省略，非 UDP 的下一个头要么走扩展头
    /// NHC（RFC 6282 §4.2），要么内联（NH=0）。
    pub fn compress(
        out: []u8,
        packet: []const u8,
        link: Link,
        ctxs: *const Contexts,
        opts: CompressOptions,
    ) Error!Compressed {
        var w = Writer{ .buf = out };
        var hidden: usize = 0;
        var elided = false;
        try compressInto(&w, packet, link, ctxs, opts, 0, &hidden, &elided);
        return .{ .frame_len = w.n, .hidden_len = hidden };
    }

    /// 解压一个 IPHC 帧（首字节 011xxxxx）。
    pub fn decompress(
        out: []u8,
        frame: []const u8,
        link: Link,
        ctxs: *const Contexts,
        opts: DecompressOptions,
    ) Error!Decompressed {
        var r = Reader{ .buf = frame };
        var w = Writer{ .buf = out };
        var elided = false;
        try decompressInto(&r, &w, link, ctxs, opts, 0, &elided);
        return .{
            .packet = out[0..w.n],
            .next_header = out[6],
            .consumed = r.n,
            .udp_checksum_elided = elided,
        };
    }

    /// UDP 校验和：伪头（RFC 2460 §8.1）+ UDP 头 + 载荷，算法是 RFC 1071。
    /// `udp` 是 UDP 头（8 字节）加载荷；它的校验和字段被当作 0。算出 0 时返回
    /// 0xFFFF（RFC 2460 §8.1）。既用来在省略前核对，也用来在解压时重算。
    pub fn udpChecksum(src: [16]u8, dst: [16]u8, udp: []const u8) u16 {
        var pseudo: [40]u8 = @splat(0);
        @memcpy(pseudo[0..16], &src);
        @memcpy(pseudo[16..32], &dst);
        std.mem.writeInt(u32, pseudo[32..36], @intCast(udp.len), .big);
        pseudo[39] = 17; // Next Header = UDP
        var sum = checksumSum(&pseudo) + checksumSumSkipping(udp, 6);
        while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
        const c: u16 = @truncate(~sum);
        return if (c == 0) 0xffff else c;
    }

    // ---- 实现细节 ----

    /// 嵌套 IPv6 头（EID=7）的层数上限。每层占用的栈不多，但板侧只有 16 KiB。
    const max_nesting: u8 = 4;
    const udp_next_header: u8 = 17;
    const ipv6_next_header: u8 = 41;

    /// 地址怎么编：`stateful` 即 SAC/DAC=1，`mode` 即 SAM/DAM（00 = 128 位内联，
    /// 01 = 64 位内联，10 = 16 位内联，11 = 全省略）。
    const Enc = struct { stateful: bool = false, ctx_id: u4 = 0, mode: u2 = 0 };

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

        fn zeros(self: *Writer, count: usize) Error!void {
            if (count > self.buf.len - self.n) return error.NoSpace;
            @memset(self.buf[self.n..][0..count], 0);
            self.n += count;
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

        fn peek(self: *const Reader) Error!u8 {
            if (self.n >= self.buf.len) return error.Short;
            return self.buf[self.n];
        }
    };

    fn checksumSum(bytes: []const u8) u32 {
        var sum: u32 = 0;
        var i: usize = 0;
        while (i + 1 < bytes.len) : (i += 2) {
            sum += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
        }
        if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
        return sum;
    }

    /// 同 `checksumSum`，但跳过 `[skip..skip + 2)`（UDP 的校验和字段）。
    fn checksumSumSkipping(bytes: []const u8, skip: usize) u32 {
        return checksumSum(bytes[0..skip]) + checksumSum(bytes[skip + 2 ..]);
    }

    /// `addr` 的前 `bits` 位是否等于 `prefix` 的前 `bits` 位。
    fn prefixMatches(addr: [16]u8, prefix: [16]u8, bits: u8) bool {
        const whole: usize = bits / 8;
        if (!std.mem.eql(u8, addr[0..whole], prefix[0..whole])) return false;
        const rest: u3 = @truncate(bits % 8);
        if (rest == 0) return true;
        const mask: u8 = 0xff ^ (@as(u8, 0xff) >> rest);
        return (addr[whole] ^ prefix[whole]) & mask == 0;
    }

    /// `addr` 的第 `[bits, 64)` 位是否全 0（上下文短于 64 位时，“Any remaining bits are
    /// zero”指的就是这一段）。
    fn midBitsZero(addr: [16]u8, bits: u8) bool {
        if (bits >= 64) return true;
        const whole: usize = bits / 8;
        const rest: u3 = @truncate(bits % 8);
        if (!std.mem.allEqual(u8, addr[whole..8], 0)) return false;
        if (rest == 0) return true;
        return (addr[whole] & (@as(u8, 0xff) >> rest)) == 0;
    }

    /// IID 里没有被上下文覆盖的位是否等于 `want` 的对应位（RFC 6282 §3.1.1：没被上下文
    /// 覆盖的 IID 位取自内联或封装头的映射）。
    fn iidTailMatches(addr: [16]u8, ctx_len: u8, want: [8]u8) bool {
        const from: u8 = if (ctx_len > 64) ctx_len - 64 else 0;
        const whole: usize = from / 8;
        const rest: u3 = @truncate(from % 8);
        if (!std.mem.eql(u8, addr[8 + whole .. 16], want[whole..])) return false;
        if (rest == 0) return true;
        return (addr[8 + whole] ^ want[whole]) & (@as(u8, 0xff) >> rest) == 0;
    }

    fn isUnspecified(a: [16]u8) bool {
        return std.mem.allEqual(u8, &a, 0);
    }

    /// 链路本地前缀 fe80:0000:0000:0000（RFC 4291 §2.5.6 的 10 位前缀加 54 个 0）。
    fn isLinkLocal(a: [16]u8) bool {
        return a[0] == 0xfe and a[1] == 0x80 and std.mem.allEqual(u8, a[2..8], 0);
    }

    fn isMulticast(a: [16]u8) bool {
        return a[0] == 0xff;
    }

    /// 短地址映射 0000:00ff:fe00:XXXX 的 IID（RFC 6282 §3.1.1 SAC=0 SAM=10）。
    fn shortIid(a: [16]u8) [8]u8 {
        return .{ 0, 0, 0, 0xff, 0xfe, 0, a[14], a[15] };
    }

    /// 单播地址的最短编法。
    fn unicastEnc(addr: [16]u8, link_iid: [8]u8, ctxs: *const Contexts) Enc {
        // SAC=1、SAM=00 固定表示未指定地址 ::。
        if (isUnspecified(addr)) return .{ .stateful = true, .mode = 0b00 };
        // 链路本地且 IID 就是从链路地址推出来的：全省略，而且不用 CID 扩展字节。
        if (isLinkLocal(addr) and std.mem.eql(u8, addr[8..16], &link_iid)) return .{ .mode = 0b11 };
        if (ctxs.match(addr)) |hit| {
            // 上下文没有覆盖到的 IID 位 MAY 省略——前提是与链路地址映射相符（§3.2.2）。
            if (midBitsZero(addr, hit.ctx.prefix_len)) {
                if (iidTailMatches(addr, hit.ctx.prefix_len, link_iid)) {
                    return .{ .stateful = true, .ctx_id = hit.id, .mode = 0b11 };
                }
                if (iidTailMatches(addr, hit.ctx.prefix_len, shortIid(addr))) {
                    return .{ .stateful = true, .ctx_id = hit.id, .mode = 0b10 };
                }
                return .{ .stateful = true, .ctx_id = hit.id, .mode = 0b01 };
            }
        }
        if (isLinkLocal(addr)) {
            if (std.mem.eql(u8, addr[8..14], shortIid(addr)[0..6])) return .{ .mode = 0b10 };
            return .{ .mode = 0b01 };
        }
        return .{ .mode = 0b00 };
    }

    /// 组播目的地址的编法。无状态（M=1、DAC=0）按 RFC 6282 §3.2.3 取最短的形式；
    /// 只有它是 128 位内联时才考虑 §3.2.4 的 6 字节形式（M=1、DAC=1、DAM=00）。
    fn multicastEnc(addr: [16]u8, ctxs: *const Contexts) Enc {
        const stateless: Enc = if (addr[1] == 0x02 and std.mem.allEqual(u8, addr[2..15], 0))
            .{ .mode = 0b11 }
        else if (std.mem.allEqual(u8, addr[2..13], 0))
            .{ .mode = 0b10 }
        else if (std.mem.allEqual(u8, addr[2..11], 0))
            .{ .mode = 0b01 }
        else
            .{ .mode = 0b00 };
        if (stateless.mode != 0b00) return stateless;
        // ffXX:XXLL:PPPP:PPPP:PPPP:PPPP:XXXX:XXXX：L 是上下文的前缀长度，P 是上下文的
        // 前 64 位。前缀长于 64 位的上下文装不进 P。
        for (ctxs.entries, 0..) |e, i| {
            if (!e.live or ctxs.now >= e.valid_until or !e.ctx.compression) continue;
            if (e.ctx.prefix_len > 64) continue;
            if (addr[3] != e.ctx.prefix_len) continue;
            if (!std.mem.eql(u8, addr[4..12], e.ctx.prefix[0..8])) continue;
            return .{ .stateful = true, .ctx_id = @intCast(i), .mode = 0b00 };
        }
        return stateless;
    }

    fn writeUnicast(w: *Writer, e: Enc, addr: [16]u8) Error!void {
        switch (e.mode) {
            // SAC=1 的 SAM=00 是 ::，没有内联。
            0b00 => if (!e.stateful) try w.raw(&addr),
            0b01 => try w.raw(addr[8..16]),
            0b10 => try w.raw(addr[14..16]),
            else => {},
        }
    }

    fn mcastInlineLen(mode: u2) usize {
        return switch (mode) {
            0b00 => 16,
            0b01 => 6,
            0b10 => 4,
            else => 1,
        };
    }

    /// 压一个 IPv6 头及其后续头链。`packet[0..40]` 是 IPv6 头。
    fn compressInto(
        w: *Writer,
        packet: []const u8,
        link: Link,
        ctxs: *const Contexts,
        opts: CompressOptions,
        depth: u8,
        hidden: *usize,
        elided: *bool,
    ) Error!void {
        if (depth > max_nesting) return error.TooDeep;
        if (packet.len < 40) return error.Short;
        if (packet[0] >> 4 != 6) return error.BadVersion;

        const tc: u8 = ((packet[0] & 0x0f) << 4) | (packet[1] >> 4);
        const fl: u32 = (@as(u32, packet[1] & 0x0f) << 16) | (@as(u32, packet[2]) << 8) | packet[3];
        // TF=01 省掉的是 DSCP，ECN 仍在内联的最高两位（§3.2.1 图 5），所以条件是 DSCP 为 0。
        const tf: u2 = if (tc == 0 and fl == 0)
            0b11
        else if (fl == 0)
            0b10
        else if ((tc & 0x3f) == 0)
            0b01
        else
            0b00;
        const hop = packet[7];
        const hl: u2 = switch (hop) {
            1 => 0b01,
            64 => 0b10,
            255 => 0b11,
            else => 0b00,
        };
        const nh_compressed = nextIsNhc(packet[6], packet, 40);

        var src: [16]u8 = undefined;
        @memcpy(&src, packet[8..24]);
        var dst: [16]u8 = undefined;
        @memcpy(&dst, packet[24..40]);
        const se = unicastEnc(src, link.src, ctxs);
        const m = isMulticast(dst);
        // RFC 6282 §3.1.1 行 501-502：M=0、DAC=1、DAM=00 是 Reserved；目的地址为 :: 时
        // 只能走无状态 128 位内联（SAC=1 SAM=00 的 :: 只定义给源地址）。
        const de: Enc = if (m) multicastEnc(dst, ctxs) else if (isUnspecified(dst))
            .{ .mode = 0b00 }
        else
            unicastEnc(dst, link.dst, ctxs);
        // CID=1 的条件：用了非 0 的上下文（CID=0 时两个地址都默认用上下文 0）。
        const cid = (se.stateful and se.mode != 0b00 and se.ctx_id != 0) or
            (de.stateful and de.mode != 0b00 and de.ctx_id != 0);

        try w.byte(0x60 | (@as(u8, tf) << 3) | (@as(u8, @intFromBool(nh_compressed)) << 2) | hl);
        try w.byte(
            (@as(u8, @intFromBool(cid)) << 7) |
                (@as(u8, @intFromBool(se.stateful)) << 6) |
                (@as(u8, se.mode) << 4) |
                (@as(u8, @intFromBool(m)) << 3) |
                (@as(u8, @intFromBool(de.stateful)) << 2) |
                @as(u8, de.mode),
        );
        // CID 扩展字节紧跟在 2 字节编码之后（§3.1.1：“immediately follows the Destination
        // Address Mode (DAM) field”），在 TF / NH / HLIM 的内联字段之前。
        if (cid) try w.byte((@as(u8, se.ctx_id) << 4) | (if (m) @as(u8, 0) else @as(u8, de.ctx_id)));
        // TF：图 4–6。Traffic Class 右旋 2 位后 ECN 落在最高两位。
        switch (tf) {
            0b00 => {
                try w.byte(tc);
                try w.byte(@truncate(fl >> 16));
                try w.byte(@truncate(fl >> 8));
                try w.byte(@truncate(fl));
            },
            0b01 => {
                try w.byte((tc & 0xc0) | @as(u8, @truncate(fl >> 16)));
                try w.byte(@truncate(fl >> 8));
                try w.byte(@truncate(fl));
            },
            0b10 => try w.byte(tc),
            else => {},
        }
        if (!nh_compressed) try w.byte(packet[6]);
        if (hl == 0b00) try w.byte(hop);
        try writeUnicast(w, se, src);
        if (m) {
            switch (de.mode) {
                0b11 => try w.byte(dst[15]),
                0b10 => {
                    try w.byte(dst[1]);
                    try w.raw(dst[13..16]);
                },
                0b01 => {
                    try w.byte(dst[1]);
                    try w.raw(dst[11..16]);
                },
                0b00 => if (de.stateful) {
                    try w.byte(dst[1]);
                    try w.byte(dst[2]);
                    try w.raw(dst[12..16]);
                } else try w.raw(&dst),
            }
        } else try writeUnicast(w, de, dst);
        hidden.* += 40;
        if (nh_compressed) {
            try compressChain(w, packet, 40, packet[6], src, dst, ctxs, opts, depth, hidden, elided);
        } else try w.raw(packet[40..]);
    }

    /// `packet[pos..]` 处、Next Header 值为 `nh` 的下一个头能不能用 NHC 编码。
    fn nextIsNhc(nh: u8, packet: []const u8, pos: usize) bool {
        if (pos >= packet.len) return false;
        return switch (nh) {
            udp_next_header => packet.len - pos >= 8,
            ipv6_next_header => packet.len - pos >= 40,
            0, 43, 44, 60, 135 => extNhcLength(nh, packet, pos) != null,
            else => false,
        };
    }

    const ExtInfo = struct { body: usize, total: usize, keep_nh: bool };

    /// `packet[pos..]` 处是一个扩展头（类型 `nh`），算出它 NHC 编码时 Length 字段的值。
    /// 返回 null 表示这个头不能用 NHC（被截断，或压缩后仍超过 255 个八位组）。
    fn extNhcLength(nh: u8, packet: []const u8, pos: usize) ?ExtInfo {
        if (pos + 2 > packet.len) return null;
        const total = (@as(usize, packet[pos + 1]) + 1) * 8;
        if (pos + total > packet.len) return null;
        // RFC 6282 §4.2（行 886-895）：只有 Hop-by-Hop 与 Destination Options 可以省略
        // 尾部 Pad1/PadN；其它扩展头（Routing/Fragment/Mobility）的 body 必须原样带全。
        const body = if (nh == 0 or nh == 60) trailingBody(packet[pos .. pos + total]) else total - 2;
        const keep_nh = !nextIsNhc(packet[pos], packet, pos + total);
        // Length 只数 body（行 915-918：超过 255 个八位组不得用 NHC）。
        return if (body > 255) null else .{ .body = body, .total = total, .keep_nh = keep_nh };
    }

    /// 选项类扩展头（Hop-by-Hop、Destination Options）去掉可省略的尾部填充之后的
    /// 选项区长度（不含 Next Header 与 Length 两个字节）。RFC 6282 §4.2：只有“单独一个
    /// 不超过 7 个八位组的尾部 Pad1 或 PadN”才可以省略；选项链本身越界时不省略。
    fn trailingBody(hdr: []const u8) usize {
        const body = hdr[2..];
        var i: usize = 0;
        var last: usize = 0;
        while (i < body.len) {
            last = i;
            if (body[i] == 0) {
                i += 1;
                continue;
            }
            if (i + 2 > body.len) return body.len;
            const size = 2 + @as(usize, body[i + 1]);
            if (i + size > body.len) return body.len;
            i += size;
        }
        const t = body[last];
        if (t == 0) return body.len - 1; // 尾部单独一个 Pad1
        if (t != 1) return body.len;
        const pad = body.len - last;
        if (pad > 7) return body.len;
        // PadN 的内容必须是 0（RFC 2460 §4.2），否则省掉它会改掉报文内容。
        if (!std.mem.allEqual(u8, body[last + 2 ..], 0)) return body.len;
        return last;
    }

    /// `packet[pos..]` 处是一个头，它的 Next Header 值是 `nh`（取自前一个头，而不是 `packet[pos]`——
    /// UDP 头和内层 IPv6 头的首字节都不是 Next Header）。每调一次压一个头，头链靠递归走完。
    fn compressChain(
        w: *Writer,
        packet: []const u8,
        pos: usize,
        nh: u8,
        src: [16]u8,
        dst: [16]u8,
        ctxs: *const Contexts,
        opts: CompressOptions,
        depth: u8,
        hidden: *usize,
        elided: *bool,
    ) Error!void {
        if (pos >= packet.len) return error.Short;
        if (nh == udp_next_header) {
            if (packet.len - pos < 8) return error.Short;
            const sport = getU16Be(packet[pos..][0..2]);
            const dport = getU16Be(packet[pos + 2 ..][0..2]);
            const c_sum = getU16Be(packet[pos + 6 ..][0..2]);
            var elide = false;
            if (opts.udp_checksum_elision_authorized) {
                // §4.3.2：先确认链路另有完整性保护，再核对校验和；核对失败 MUST 丢弃。
                if (!opts.link_integrity) return error.NoIntegrityCheck;
                const computed = udpChecksum(src, dst, packet[pos..]);
                if (c_sum != computed and !(c_sum == 0 and computed == 0xffff)) return error.BadChecksum;
                elide = true;
            }
            try encodeUdpNhc(w, sport, dport, c_sum, elide);
            elided.* = elided.* or elide;
            hidden.* += 8;
            return w.raw(packet[pos + 8 ..]);
        }
        if (nh == ipv6_next_header) {
            // EID=7：NH 位没有用、MUST 为 0，后面按 LOWPAN_IPHC 再压一次。
            if (packet.len - pos < 40) return error.Short;
            try w.byte(0xee);
            hidden.* += 40;
            const inner: Link = .{ .src = src[8..16].*, .dst = dst[8..16].* };
            return compressInto(w, packet[pos..], inner, ctxs, opts, depth + 1, hidden, elided);
        }
        const info = extNhcLength(nh, packet, pos) orelse return error.Short;
        try w.byte(0xe0 | (@as(u8, extHeaderId(nh)) << 1) | @as(u8, @intFromBool(!info.keep_nh)));
        if (info.keep_nh) {
            // RFC 6282 §4.2 图 13：NH=0 时 inline 的 8 位是**后继头**的类型（packet[pos] 是
            // 本头的 Next Header 字段），不是本头自己的类型；它在 Length 之前。
            try w.byte(packet[pos]);
        }
        // Length = Length 字段之后的八位组数（RFC 6282 §4.2 行 878-881），NH 字节不算。
        try w.byte(@intCast(info.body));
        try w.raw(packet[pos + 2 .. pos + 2 + info.body]);
        hidden.* += info.total;
        if (info.keep_nh) {
            // 下一个头没有 NHC 编码：它和后面的载荷原样内联。
            return w.raw(packet[pos + info.total ..]);
        }
        return compressChain(w, packet, pos + info.total, packet[pos], src, dst, ctxs, opts, depth, hidden, elided);
    }

    /// IPv6 扩展头的 NHC EID（RFC 6282 §4.2 图 13）。
    fn extHeaderId(nh: u8) u3 {
        return switch (nh) {
            0 => 0,
            43 => 1,
            44 => 2,
            60 => 3,
            135 => 4,
            ipv6_next_header => 7,
            else => unreachable,
        };
    }

    /// NHC EID → 它标识的扩展头的 IPv6 Next Header 值。EID 5、6 是保留的。
    fn extNextHeader(eid: u3) Error!u8 {
        return switch (eid) {
            0 => 0,
            1 => 43,
            2 => 44,
            3 => 60,
            4 => 135,
            7 => ipv6_next_header,
            else => error.Reserved,
        };
    }

    /// 压一个 UDP 头为 11110CPP（RFC 6282 §4.3.3 图 14）。端口按能省得最多的 P 值编：
    /// 两个都在 0xf0b0–0xf0bf 用 P=11，否则源端口在 0xf000–0xf0ff 用 P=10，目的端口在
    /// 用 P=01。`elide_checksum` 为真时 C=1（调用方已经满足 §4.3.2 的条件）。
    fn encodeUdpNhc(w: *Writer, sport: u16, dport: u16, c_sum: u16, elide_checksum: bool) Error!void {
        const in4 = sport >= 0xf0b0 and sport <= 0xf0bf and dport >= 0xf0b0 and dport <= 0xf0bf;
        const src8 = sport >= 0xf000 and sport <= 0xf0ff;
        const dst8 = dport >= 0xf000 and dport <= 0xf0ff;
        const p: u2 = if (in4) 0b11 else if (src8) 0b10 else if (dst8) 0b01 else 0b00;
        try w.byte(0xf0 | (@as(u8, @intFromBool(elide_checksum)) << 2) | @as(u8, p));
        switch (p) {
            // 两个端口各带低 4 位，合成一个字节：源端口在前。
            0b11 => try w.byte((@as(u8, @truncate(sport & 0x0f)) << 4) | @as(u8, @truncate(dport & 0x0f))),
            0b10 => {
                try w.byte(@truncate(sport));
                try w.raw(&.{ @truncate(dport >> 8), @truncate(dport) });
            },
            0b01 => {
                try w.raw(&.{ @truncate(sport >> 8), @truncate(sport) });
                try w.byte(@truncate(dport));
            },
            else => {
                try w.raw(&.{ @truncate(sport >> 8), @truncate(sport) });
                try w.raw(&.{ @truncate(dport >> 8), @truncate(dport) });
            },
        }
        if (!elide_checksum) try w.raw(&.{ @truncate(c_sum >> 8), @truncate(c_sum) });
    }

    /// 还原一个单播地址。`inl` 是按模式取好的内联字节。
    fn restoreUnicast(
        stateful: bool,
        mode: u2,
        ctx: Context,
        link_iid: [8]u8,
        inl: []const u8,
    ) Error![16]u8 {
        var addr: [16]u8 = @splat(0);
        if (!stateful) {
            switch (mode) {
                0b00 => @memcpy(&addr, inl),
                0b01 => {
                    addr[0] = 0xfe;
                    addr[1] = 0x80;
                    @memcpy(addr[8..16], inl);
                },
                0b10 => {
                    addr[0] = 0xfe;
                    addr[1] = 0x80;
                    addr[11] = 0xff;
                    addr[12] = 0xfe;
                    @memcpy(addr[14..16], inl);
                },
                else => {
                    addr[0] = 0xfe;
                    addr[1] = 0x80;
                    @memcpy(addr[8..16], &link_iid);
                },
            }
            return addr;
        }
        switch (mode) {
            0b01 => @memcpy(addr[8..16], inl),
            0b10 => {
                addr[11] = 0xff;
                addr[12] = 0xfe;
                @memcpy(addr[14..16], inl);
            },
            0b11 => @memcpy(addr[8..16], &link_iid),
            else => return addr, // :: 不需要上下文
        }
        // “Bits covered by context information are always used”：上下文位盖在内联位之上。
        const whole: usize = ctx.prefix_len / 8;
        @memcpy(addr[0..whole], ctx.prefix[0..whole]);
        const rest: u3 = @truncate(ctx.prefix_len % 8);
        if (rest != 0) {
            const mask: u8 = 0xff ^ (@as(u8, 0xff) >> rest);
            addr[whole] = (addr[whole] & ~mask) | (ctx.prefix[whole] & mask);
        }
        return addr;
    }

    fn restoreMulticast(mode: u2, inl: []const u8) Error![16]u8 {
        var a: [16]u8 = @splat(0);
        a[0] = 0xff;
        switch (mode) {
            0b00 => @memcpy(&a, inl),
            0b01 => {
                a[1] = inl[0];
                @memcpy(a[11..16], inl[1..6]);
            },
            0b10 => {
                a[1] = inl[0];
                @memcpy(a[13..16], inl[1..4]);
            },
            else => {
                a[1] = 0x02;
                a[15] = inl[0];
            },
        }
        return a;
    }

    fn decompressInto(
        r: *Reader,
        w: *Writer,
        link: Link,
        ctxs: *const Contexts,
        opts: DecompressOptions,
        depth: u8,
        elided: *bool,
    ) Error!void {
        if (depth > max_nesting) return error.TooDeep;
        const b0 = try r.byte();
        const b1 = try r.byte();
        if ((b0 & 0xe0) != 0x60) return error.BadDispatch;
        const tf: u2 = @truncate((b0 >> 3) & 0x03);
        const nh_compressed = (b0 & 0x04) != 0;
        const hl: u2 = @truncate(b0 & 0x03);
        const cid = (b1 & 0x80) != 0;
        const sac = (b1 & 0x40) != 0;
        const sam: u2 = @truncate((b1 >> 4) & 0x03);
        const m = (b1 & 0x08) != 0;
        const dac = (b1 & 0x04) != 0;
        const dam: u2 = @truncate(b1 & 0x03);
        var sci: u4 = 0;
        var dci: u4 = 0;
        if (cid) {
            const c = try r.byte();
            sci = @truncate(c >> 4);
            dci = @truncate(c);
        }

        var tc: u8 = 0;
        var fl: u32 = 0;
        switch (tf) {
            0b00 => {
                const t = try r.take(4);
                tc = t[0];
                fl = (@as(u32, t[1]) << 16) | (@as(u32, t[2]) << 8) | t[3];
            },
            0b01 => {
                const t = try r.take(3);
                tc = t[0] & 0xc0;
                fl = (@as(u32, t[0] & 0x0f) << 16) | (@as(u32, t[1]) << 8) | t[2];
            },
            0b10 => tc = try r.byte(),
            else => {},
        }
        const nh = if (nh_compressed) 0 else try r.byte();
        const hop: u8 = switch (hl) {
            0b01 => 1,
            0b10 => 64,
            0b11 => 255,
            else => try r.byte(),
        };

        // 源地址：SAC=1 且 SAM≠00 时要上下文。
        var src_ctx = Context{};
        if (sac and sam != 0b00) src_ctx = try ctxs.get(sci);
        const src_inline: usize = switch (sam) {
            0b00 => if (sac) 0 else 16,
            0b01 => 8,
            0b10 => 2,
            else => 0,
        };
        const src = try restoreUnicast(sac, sam, src_ctx, link.src, try r.take(src_inline));

        var dst: [16]u8 = undefined;
        if (m) {
            if (!dac) {
                dst = try restoreMulticast(dam, try r.take(mcastInlineLen(dam)));
            } else {
                // §3.2.4 只定义了 DAM=00。
                if (dam != 0b00) return error.Reserved;
                const ctx = try ctxs.get(dci);
                const t = try r.take(6);
                dst = @splat(0);
                dst[0] = 0xff;
                dst[1] = t[0];
                dst[2] = t[1];
                dst[3] = ctx.prefix_len;
                @memcpy(dst[4..12], ctx.prefix[0..8]);
                @memcpy(dst[12..16], t[2..6]);
            }
        } else {
            // M=0、DAC=1、DAM=00 是 Reserved（§3.1.1）。
            if (dac and dam == 0b00) return error.Reserved;
            var dst_ctx = Context{};
            if (dac) dst_ctx = try ctxs.get(dci);
            const len: usize = switch (dam) {
                0b00 => 16,
                0b01 => 8,
                0b10 => 2,
                else => 0,
            };
            dst = try restoreUnicast(dac, dam, dst_ctx, link.dst, try r.take(len));
        }

        const ip_pos = w.n;
        try w.byte(0x60 | (tc >> 4));
        try w.byte((tc << 4) | @as(u8, @truncate(fl >> 16)));
        try w.byte(@truncate(fl >> 8));
        try w.byte(@truncate(fl));
        try w.byte(0);
        try w.byte(0); // Payload Length，等后面的头都写完再回填
        try w.byte(nh);
        try w.byte(hop);
        try w.raw(&src);
        try w.raw(&dst);

        if (nh_compressed) {
            // 头链的第一个头是谁，直接由 decompressChain 的返回值给出。
            w.buf[ip_pos + 6] = try decompressChain(r, w, ctxs, opts, depth, elided, src, dst);
        } else {
            // 剩下的输入原样是下一个头和载荷。
            const rest = r.buf[r.n..];
            r.n = r.buf.len;
            try w.raw(rest);
        }
        const plen = w.n - ip_pos - 40;
        if (plen > 0xffff) return error.TooLong;
        std.mem.writeInt(u16, w.buf[ip_pos + 4 ..][0..2], @intCast(plen), .big);
    }

    /// 解 IPv6 头之后的 NHC 头链。返回值是这条链上**第一个头**的类型（UDP=17、
    /// 各扩展头自己的 Next Header 值、IPv6=41），调用方拿它回填前一个头的 Next Header
    /// 字段——RFC 6282 §4.2：NH=1 时扩展头自己的 Next Header 字段被省略，解压方要按
    /// “下一个头是什么”补回；所以每个头都要等递归返回后才知道自己该填什么。
    /// `src`/`dst` 是本层 IPv6 头的地址：UDP 校验和伪头与 EID=7 的内层 Link 都取自它们
    /// （RFC 6282 §3.2.2 首段），不能从输出缓冲的“末 32 字节”倒推——中间有扩展头时那是错的。
    fn decompressChain(
        r: *Reader,
        w: *Writer,
        ctxs: *const Contexts,
        opts: DecompressOptions,
        depth: u8,
        elided: *bool,
        src: [16]u8,
        dst: [16]u8,
    ) Error!u8 {
        const id = try r.peek();
        if ((id & 0xf8) == 0xf0) {
            const u = try decodeUdpNhc(r.buf[r.n..]);
            r.n = r.buf.len;
            const udp_pos = w.n;
            try w.byte(@truncate(u.src_port >> 8));
            try w.byte(@truncate(u.src_port));
            try w.byte(@truncate(u.dst_port >> 8));
            try w.byte(@truncate(u.dst_port));
            try w.byte(0);
            try w.byte(0); // UDP Length，下面回填
            try w.byte(0);
            try w.byte(0); // 校验和：C=1 时重算，否则原值
            try w.raw(u.rest);
            const udp_len = w.n - udp_pos;
            std.mem.writeInt(u16, w.buf[udp_pos + 4 ..][0..2], @intCast(udp_len), .big);
            if (u.checksum_present) {
                std.mem.writeInt(u16, w.buf[udp_pos + 6 ..][0..2], u.checksum, .big);
            } else {
                // §4.3.2：解压方 MUST 重算校验和，并且 MUST 能确定并验证另有完整性保护，
                // 否则 MUST 丢弃。
                if (!opts.link_integrity) return error.NoIntegrityCheck;
                const c = udpChecksum(src, dst, w.buf[udp_pos..w.n]);
                std.mem.writeInt(u16, w.buf[udp_pos + 6 ..][0..2], c, .big);
                elided.* = true;
            }
            return udp_next_header;
        }
        if ((id & 0xe0) != 0xe0) return error.BadNhc;
        _ = try r.byte();
        const eid: u3 = @truncate((id >> 1) & 0x07);
        const nh_bit = (id & 0x01) != 0;
        const nh = try extNextHeader(eid);
        if (eid == 7) {
            // EID=7 时 NH 位没有用、MUST 为 0（§4.2）；嵌套 IPv6 头的 IID 取自外层地址
            // （§3.2.2：低 64 位 = 本层 IPv6 头的 IID）。
            // 内层包（含它自己的 NHC 链）由 decompressInto 整体解完。
            if (nh_bit) return error.Reserved;
            const inner: Link = .{ .src = src[8..16].*, .dst = dst[8..16].* };
            const ip_pos = w.n;
            try decompressInto(r, w, inner, ctxs, opts, depth + 1, elided);
            const plen = w.n - ip_pos - 40;
            if (plen > 0xffff) return error.TooLong;
            std.mem.writeInt(u16, w.buf[ip_pos + 4 ..][0..2], @intCast(plen), .big);
            return ipv6_next_header;
        }
        // 线上顺序（RFC 6282 §4.2）：[NHC][NH=0 时 inline 的后继头类型][Length][body]。
        // Length 只数 body 的八位组数；NH 字节在 Length 之前。
        var body: []const u8 = undefined;
        var inline_nh: u8 = 0;
        if (nh_bit) {
            body = try r.take(try r.byte());
        } else {
            inline_nh = try r.byte();
            body = try r.take(try r.byte());
        }
        const hdr_pos = w.n;
        try w.byte(0); // Next Header：等递归返回（或 inline 字节）后回填
        try w.byte(0); // Length，等补齐之后按 8 字节单位回填
        try w.raw(body);
        const total = w.n - hdr_pos;
        if (eid == 0 or eid == 3) {
            // §4.2：解压方 MUST 把选项类扩展头补齐到 8 字节的倍数，用 Pad1 或 PadN。
            const pad = (8 - total % 8) % 8;
            switch (pad) {
                0 => {},
                1 => try w.byte(0),
                else => {
                    try w.byte(1);
                    try w.byte(@intCast(pad - 2));
                    try w.zeros(pad - 2);
                },
            }
        } else if (total % 8 != 0) {
            // 其它扩展头没有填充选项，长度必须是 8 的倍数才能写回 8 字节单位的 Length。
            return error.BadNhc;
        }
        w.buf[hdr_pos + 1] = @intCast((w.n - hdr_pos) / 8 - 1);
        if (nh_bit) {
            // 后继头也是 NHC 编码：它解出来才知道本头的 Next Header 该填什么。
            w.buf[hdr_pos] = try decompressChain(r, w, ctxs, opts, depth, elided, src, dst);
        } else {
            // 后继头没有 NHC 编码：它的类型就是 inline 的那个字节，剩下的输入原样是载荷。
            w.buf[hdr_pos] = inline_nh;
            const rest = r.buf[r.n..];
            r.n = r.buf.len;
            try w.raw(rest);
        }
        return nh;
    }
};

/// 解一个完整的 6LoWPAN 载荷（没有分片，或者是分片重组之后的第一个头）：0x41 是未压缩的
/// IPv6 包，011xxxxx 是 IPHC；其它 dispatch 在这里是错的。
pub fn decodeDatagram(
    out: []u8,
    body: []const u8,
    link: iphc.Link,
    ctxs: *const iphc.Contexts,
    opts: iphc.DecompressOptions,
) Error!iphc.Decompressed {
    if (body.len == 0) return error.Short;
    switch (dispatchOf(body[0])) {
        .ipv6 => {
            const n = body.len - 1;
            if (out.len < n) return error.NoSpace;
            @memcpy(out[0..n], body[1..]);
            return .{
                .packet = out[0..n],
                .next_header = if (n >= 7) out[6] else 0,
                .consumed = 1,
                .udp_checksum_elided = false,
            };
        },
        .iphc => return iphc.decompress(out, body, link, ctxs, opts),
        else => return error.BadDispatch,
    }
}

// ---------------------------------------------------------------------------
// Mesh 头（RFC 4944 §5.2）与转发规则（§11）
// ---------------------------------------------------------------------------

pub const mesh = struct {
    pub const Header = struct {
        originator: Addr,
        final: Addr,
        /// 1–255。4 位字段里的 0xF 是保留值，表示后面跟一个 8 位的 Deep Hops Left。
        hops_left: u16,
    };

    pub const Decoded = struct { header: Header, rest: []const u8 };

    /// 编码 Mesh 头，返回头长度。短地址在 Mesh 头里高字节在前（RFC 4944 没有规定字节序；
    /// 取 OpenThread `thread/lowpan.cpp:1145-1146` 的读法 `BigEndian::ReadUint16`）。
    pub fn encodeHeader(out: []u8, h: Header) Error!usize {
        if (h.hops_left > 255) return error.BadMesh;
        const v = h.originator == .short;
        const f = h.final == .short;
        const deep = h.hops_left >= 15;
        const total: usize = 1 + @as(usize, if (deep) 1 else 0) +
            (if (v) @as(usize, 2) else 8) + (if (f) @as(usize, 2) else 8);
        if (out.len < total) return error.NoSpace;
        var i: usize = 0;
        out[i] = 0x80 | (@as(u8, @intFromBool(v)) << 5) | (@as(u8, @intFromBool(f)) << 4) |
            (if (deep) @as(u8, 15) else @as(u8, @truncate(h.hops_left)));
        i += 1;
        if (deep) {
            out[i] = @truncate(h.hops_left);
            i += 1;
        }
        i += writeAddr(out[i..], h.originator);
        i += writeAddr(out[i..], h.final);
        return total;
    }

    fn writeAddr(out: []u8, a: Addr) usize {
        switch (a) {
            .short => |s| {
                out[0] = @truncate(s >> 8);
                out[1] = @truncate(s);
                return 2;
            },
            .long => |l| {
                @memcpy(out[0..8], &l);
                return 8;
            },
        }
    }

    fn readAddr(bytes: []const u8, short: bool) Error!struct { addr: Addr, len: usize } {
        if (short) {
            if (bytes.len < 2) return error.Short;
            return .{ .addr = .{ .short = getU16Be(bytes[0..2]) }, .len = 2 };
        }
        if (bytes.len < 8) return error.Short;
        return .{ .addr = .{ .long = bytes[0..8].* }, .len = 8 };
    }

    /// 解出 Mesh 头，返回头与后面的字节。首字节必须是 10xxxxxx。
    pub fn decodeHeader(frame: []const u8) Error!@This().Decoded {
        if (frame.len < 1) return error.Short;
        if ((frame[0] & 0xc0) != 0x80) return error.BadDispatch;
        const deep = (frame[0] & 0x0f) == 15;
        var hops: u16 = @as(u16, frame[0] & 0x0f);
        var i: usize = 1;
        if (deep) {
            if (frame.len < 2) return error.Short;
            hops = frame[1];
            i = 2;
        }
        const o = try readAddr(frame[i..], (frame[0] & 0x20) != 0);
        i += o.len;
        const f = try readAddr(frame[i..], (frame[0] & 0x10) != 0);
        i += f.len;
        return .{ .header = .{ .originator = o.addr, .final = f.addr, .hops_left = hops }, .rest = frame[i..] };
    }

    /// RFC 4944 §11：不是最终目的的节点把 Hops Left 减一，结果为 0 就丢弃，否则转发；
    /// §5.2：“The packet is not forwarded any further if Hops Left is decremented to zero.”
    pub const Action = union(enum) {
        /// 本节点就是 Final Destination：按正常投递处理。
        deliver,
        /// 丢弃：Hops Left 减到 0，或者收到时已经是 0（不该被继续转发）。
        expired,
        /// 转发给下一跳，头里的 Hops Left 改成这个值。
        forward: u16,
    };

    pub fn forward(h: Header, me: Addr) Action {
        if (addrEql(h.final, me)) return .deliver;
        if (h.hops_left <= 1) return .expired;
        return .{ .forward = h.hops_left - 1 };
    }

    /// 转发时把帧里的 Hops Left 改成 `hops`。编码形式不变（深编码的保持深编码）。
    pub fn setHopsLeft(frame: []u8, hops: u16) Error!void {
        if (frame.len < 1) return error.Short;
        const deep = (frame[0] & 0x0f) == 15;
        if (deep) {
            if (frame.len < 2) return error.Short;
            if (hops > 255) return error.BadMesh;
            frame[1] = @truncate(hops);
        } else {
            if (hops >= 15) return error.BadMesh;
            frame[0] = (frame[0] & 0xf0) | @as(u8, @truncate(hops));
        }
    }
};

// ---------------------------------------------------------------------------
// 分片头（RFC 4944 §5.3）
// ---------------------------------------------------------------------------

pub const frag = struct {
    /// datagram_size 是 11 位。RFC 4944 §5.3 只要求能表示 1280，但字段本身能到 2047。
    pub const max_datagram_size: u16 = 0x7ff;
    pub const first_header_len: usize = 4;
    pub const rest_header_len: usize = 5;
    /// 一帧里 6LoWPAN 能用的最大字节数：aMaxPHYPacketSize(127) 减去 FCS(2)（RFC 4944 §4）。
    pub const max_frame_payload: usize = 127 - 2;

    pub const Header = struct {
        /// true 是首片（FRAG1，11000DDD），false 是后续片（FRAGN，11100DDD）。
        first: bool,
        /// 整个（未压缩的）IPv6 包的长度，同一包的所有片相同。
        size: u16,
        /// 同一包的所有片相同；发送方每发一个分片包加一。
        tag: u16,
        /// 这一片在未压缩数据报里的偏移，以 8 字节计；首片隐含为 0。
        offset: u8,
    };

    pub const Decoded = struct { header: Header, payload: []const u8 };

    /// 编码分片头：首片 4 字节（图 4），后续片 5 字节（图 5）。返回头长度。
    pub fn encodeHeader(out: []u8, h: Header) Error!usize {
        if (h.size > max_datagram_size) return error.TooLong;
        const n: usize = if (h.first) first_header_len else rest_header_len;
        if (out.len < n) return error.NoSpace;
        out[0] = (if (h.first) @as(u8, 0xc0) else 0xe0) | @as(u8, @truncate(h.size >> 8));
        out[1] = @truncate(h.size);
        out[2] = @truncate(h.tag >> 8);
        out[3] = @truncate(h.tag);
        if (!h.first) out[4] = h.offset;
        return n;
    }

    /// 解出分片头，返回头与片内载荷。首字节必须是 11000xxx 或 11100xxx。
    pub fn decodeHeader(frame: []const u8) Error!@This().Decoded {
        if (frame.len < 1) return error.Short;
        const first = (frame[0] & 0xf8) == 0xc0;
        const n: usize = if (first) first_header_len else rest_header_len;
        if (frame.len < n) return error.Short;
        if (!first and (frame[0] & 0xf8) != 0xe0) return error.BadDispatch;
        const h = Header{
            .first = first,
            .size = (@as(u16, frame[0] & 0x07) << 8) | frame[1],
            .tag = getU16Be(frame[2..4]),
            .offset = if (first) 0 else frame[4],
        };
        return .{ .header = h, .payload = frame[n..] };
    }

    /// 发送方的 datagram_tag：每个分片包用一个，0xFFFF 之后回到 0（RFC 4944 §5.3：
    /// “The sender SHALL increment datagram_tag for successive, fragmented datagrams. The
    /// incremented value of datagram_tag SHALL wrap from 65535 back to zero.”）。
    pub const Sender = struct {
        next: u16 = 0,

        pub fn nextTag(self: *Sender) u16 {
            const t = self.next;
            self.next = if (t == 0xffff) 0 else t + 1;
            return t;
        }
    };

    /// 把一个（已压缩的）6LoWPAN 数据报切成片。每调一次 `next` 产出一帧的 6LoWPAN 载荷，
    /// 写进 `out`，返回长度；都发完之后返回 null。不保存中间缓冲：位置由 `pos` 决定。
    pub const Cursor = struct {
        datagram: []const u8,
        /// 压缩头占的字节数：它必须整个落在首片里（RFC 6282 §2）。
        header_len: usize,
        /// 压缩头代表的未压缩字节数（`iphc.Compressed.hidden_len`；未压缩发送时为 0）。
        hidden: usize,
        /// 一帧里 6LoWPAN 可用的字节数。
        budget: usize,
        tag: u16,
        pos: usize = 0,
        index: u32 = 0,

        pub fn init(datagram: []const u8, header_len: usize, hidden: usize, budget: usize, tag: u16) Error!Cursor {
            if (header_len > datagram.len) return error.BadFrag;
            if (hidden > max_datagram_size or hidden % 8 != 0) return error.BadFrag;
            // datagram_size 是未压缩的整包长度（RFC 4944 §5.3、RFC 6282 §2）。
            if (hidden + datagram.len - header_len > max_datagram_size) return error.TooLong;
            // 单片放得下就不分片；要分片的话，压缩头必须整个落在首片里（RFC 6282 §2），
            // 后续片至少要能带 8 个字节。
            if (datagram.len > budget) {
                if (budget < first_header_len + header_len) return error.HeaderTooLong;
                if (budget < rest_header_len + 8) return error.TooLong;
            }
            return .{ .datagram = datagram, .header_len = header_len, .hidden = hidden, .budget = budget, .tag = tag };
        }

        /// 首片里压缩头之后能带的数据：整 8 字节，这样下一片在未压缩数据报里的偏移才是 8 的倍数
        /// （RFC 4944 §5.3：除末片外每片都是 8 字节的倍数）。
        fn firstCap(self: *const Cursor) usize {
            return (self.budget - first_header_len - self.header_len) & ~@as(usize, 7);
        }

        fn restCap(self: *const Cursor) usize {
            return (self.budget - rest_header_len) & ~@as(usize, 7);
        }

        /// 一共几片（不分片时是 1）。
        pub fn count(self: *const Cursor) u32 {
            if (self.datagram.len <= self.budget) return 1;
            const first_take = self.header_len + @min(self.datagram.len - self.header_len, self.firstCap());
            const rest_len = self.datagram.len - first_take;
            return 2 + @as(u32, @intCast((rest_len - 1) / self.restCap()));
        }

        pub fn next(self: *Cursor, out: []u8) Error!?usize {
            if (self.index > 0 and self.pos >= self.datagram.len) return null;
            var w = iphc.Writer{ .buf = out };
            const total: u16 = @intCast(self.hidden + self.datagram.len - self.header_len);
            if (self.index == 0 and self.datagram.len <= self.budget) {
                try w.raw(self.datagram);
            } else if (self.index == 0) {
                const take = self.header_len + @min(self.datagram.len - self.header_len, self.firstCap());
                w.n = try frag.encodeHeader(out, .{ .first = true, .size = total, .tag = self.tag, .offset = 0 });
                try w.raw(self.datagram[0..take]);
                self.pos = take;
            } else {
                const cap = self.restCap();
                const take = @min(self.datagram.len - self.pos, cap);
                if (take == 0) return error.TooLong;
                w.n = try frag.encodeHeader(out, .{
                    .first = false,
                    .size = total,
                    .tag = self.tag,
                    .offset = @intCast((self.hidden + self.pos - self.header_len) / 8),
                });
                try w.raw(self.datagram[self.pos .. self.pos + take]);
                self.pos += take;
            }
            self.index += 1;
            return w.n;
        }
    };

    /// 重组表：`slots` 个并发数据报，每个最大 `max_datagram` 字节。全部是静态存储，不分配。
    /// 规则出自 RFC 4944 §5.3：四元组（发送方地址、目的地址、datagram_size、datagram_tag）
    /// 标识一个数据报；重叠且大小或偏移不同的片到达时丢弃已积累的片、以最新的片重新开始；
    /// 定时器在收到某个 tag 的第一片时启动，到期没拼完就丢弃并清状态，超时不超过 60 s。
    pub fn Reassembler(comptime slots: usize, comptime max_datagram: usize) type {
        if (max_datagram < 48 or max_datagram > max_datagram_size) @compileError("max_datagram 必须在 48–2047 之间");
        return struct {
            const Self = @This();
            const block_count = (max_datagram + 7) / 8;

            /// RFC 4944 §5.3 四元组里的地址部分；size、tag 来自分片头。
            pub const Key = struct { sender: Addr, dest: Addr, size: u16, tag: u16 };

            pub const Stats = struct {
                completed: u32 = 0,
                expired: u32 = 0,
                overlap: u32 = 0,
                duplicate: u32 = 0,
                rejected: u32 = 0,
            };

            pub const Outcome = union(enum) {
                /// 拼完了：数据报在 `out[0..size]`。
                complete: []const u8,
                waiting,
            };

            /// RFC 4944 §5.3：“The reassembly timeout MUST be set to a maximum of 60 seconds.”
            pub const max_timeout_ms: u32 = 60_000;

            const Slot = struct {
                used: bool = false,
                key: Key = undefined,
                started_at: u32 = 0,
                buf: [max_datagram]u8 = undefined,
                /// 每个字节块（8 字节）是否已经有数据。
                have: [block_count]u8 = @splat(0),
                /// 从这个字节块开始的片的长度；0 表示没有片从这里开始。
                starts: [block_count]u16 = @splat(0),
                /// 首片解压后的长度（未压缩字节）；0 表示首片还没到。
                first_end: u16 = 0,
            };

            slots: [slots]Slot = @splat(.{}),
            timeout_ms: u32 = max_timeout_ms,
            now: u32 = 0,
            stats: Self.Stats = .{},

            pub fn setTimeoutMs(self: *Self, ms: u32) Error!void {
                if (ms == 0 or ms > max_timeout_ms) return error.TimeoutTooLong;
                self.timeout_ms = ms;
            }

            pub fn tick(self: *Self, now_ms: u32) void {
                self.now = now_ms;
                for (&self.slots) |*s| {
                    if (s.used and now_ms -% s.started_at >= self.timeout_ms) {
                        s.used = false;
                        self.stats.expired += 1;
                    }
                }
            }

            /// 丢弃所有拼了一半的数据报，返回丢弃的个数。RFC 4944 §5.3：检测到 802.15.4
            /// Disassociation 事件时接收方 MUST 丢掉所有部分重组的数据报的全部链路片。
            pub fn flush(self: *Self) usize {
                var n: usize = 0;
                for (&self.slots) |*s| {
                    if (s.used) {
                        s.used = false;
                        n += 1;
                    }
                }
                return n;
            }

            pub fn inProgress(self: *const Self) usize {
                var n: usize = 0;
                for (&self.slots) |*s| {
                    if (s.used) n += 1;
                }
                return n;
            }

            /// 喂一个带分片头的 6LoWPAN 载荷。`link` 给首片解压用；有 Mesh 头时 `key` 的两个
            /// 地址取 Originator / Final Destination，否则取 MAC 头的两端（RFC 4944 §5.3）。
            /// 首片在这里解压，所以 `ctxs` / `opts` 要与不分片的接收路径相同。
            pub fn push(
                self: *Self,
                frame: []const u8,
                key: Key,
                link: iphc.Link,
                ctxs: *const iphc.Contexts,
                opts: iphc.DecompressOptions,
                out: []u8,
            ) Error!Outcome {
                const f = try frag.decodeHeader(frame);
                const h = f.header;
                const size: usize = h.size;
                const payload = f.payload;
                if (size > max_datagram) {
                    self.stats.rejected += 1;
                    return error.TooLong;
                }
                if (size < 40 or payload.len == 0) {
                    self.stats.rejected += 1;
                    return error.BadFrag;
                }
                var off: usize = 0;
                if (!h.first) {
                    off = @as(usize, h.offset) << 3;
                    // 偏移 0 是首片的；除末片外每片都必须是 8 的倍数（§5.3）。
                    if (off == 0 or off + payload.len > size or
                        (off + payload.len < size and payload.len % 8 != 0))
                    {
                        self.stats.rejected += 1;
                        return error.BadFrag;
                    }
                }

                var found: ?*Slot = null;
                for (&self.slots) |*s| {
                    if (s.used and keyEq(s.key, key)) {
                        found = s;
                        break;
                    }
                }
                var fresh = false;
                if (found == null) {
                    for (&self.slots) |*s| {
                        if (!s.used) {
                            // 后续片先到：也按 datagram_size 建好缓冲区等首片（§5.3 的 NOTE）。
                            s.* = .{ .used = true, .key = key, .started_at = self.now };
                            found = s;
                            fresh = true;
                            break;
                        }
                    }
                    if (found == null) {
                        self.stats.rejected += 1;
                        return error.TableFull;
                    }
                }
                const s = found.?;
                errdefer if (fresh) {
                    s.used = false;
                };

                if (h.first) {
                    if (payload.len > size) {
                        self.stats.rejected += 1;
                        return error.BadFrag;
                    }
                    const d = decodeDatagram(s.buf[0..size], payload, link, ctxs, opts) catch |e| {
                        self.stats.rejected += 1;
                        return if (e == error.NoSpace) error.BadFrag else e;
                    };
                    const n: u16 = @intCast(d.packet.len);
                    // 首片解出来只知道首片自己的长度：Payload Length 要按整个数据报的 datagram_size
                    // 回填（RFC 4944 §5.3：它等于 40 加上 Payload Length）；UDP 紧跟在 IPv6 头后面
                    // 且整个 UDP 头都在首片里时，UDP Length 同理。
                    std.mem.writeInt(u16, s.buf[4..6], @intCast(size - 40), .big);
                    if (n >= 48 and s.buf[6] == 17) std.mem.writeInt(u16, s.buf[44..46], @intCast(size - 40), .big);
                    // 后续片的偏移是 8 的倍数；首片解出来不是 8 的倍数，中间就会留下永远
                    // 填不上的洞，按坏片处理。
                    if (n % 8 != 0) {
                        self.stats.rejected += 1;
                        return error.BadFrag;
                    }
                    if (s.first_end == n) {
                        // 偏移相同、长度相同：按 §5.3 的判据与已积累的首片没有区别，当作重复。
                        self.stats.duplicate += 1;
                    } else {
                        // §5.3：只有“重叠且大小或偏移不同”才丢已积累的片。已有一片首片、
                        // 或者新首片的 [0, n) 与已收的 FRAGN 数据重叠时，丢掉重来；
                        // 只是首片来晚了（FRAGN 数据都在 [n, size)）就保留它们。
                        if (s.first_end != 0 or anySet(&s.have, 0, n)) {
                            self.stats.overlap += 1;
                            reset(s);
                        }
                        s.first_end = n;
                        fill(&s.have, 0, n);
                    }
                } else {
                    // 首片的偏移隐含为 0，与这一片不同：重叠就丢掉已积累的，以这一片重来。
                    if (off < s.first_end) {
                        self.stats.overlap += 1;
                        reset(s);
                    }
                    const b0 = off / 8;
                    const len: u16 = @intCast(payload.len);
                    if (s.starts[b0] == len) {
                        self.stats.duplicate += 1;
                    } else {
                        if (anySet(&s.have, off, off + payload.len)) {
                            self.stats.overlap += 1;
                            reset(s);
                        }
                        @memcpy(s.buf[off .. off + payload.len], payload);
                        s.starts[b0] = len;
                        fill(&s.have, off, off + payload.len);
                    }
                }

                // 首片之后到 datagram_size 为止每一块都到了才算拼完（不是到缓冲区末尾）。
                if (s.first_end != 0 and allSet(&s.have, s.first_end, size)) {
                    if (out.len < size) return error.NoSpace;
                    @memcpy(out[0..size], s.buf[0..size]);
                    s.used = false;
                    self.stats.completed += 1;
                    return .{ .complete = out[0..size] };
                }
                return .waiting;
            }

            fn keyEq(a: Key, b: Key) bool {
                return a.size == b.size and a.tag == b.tag and addrEql(a.sender, b.sender) and addrEql(a.dest, b.dest);
            }

            fn reset(s: *Slot) void {
                @memset(&s.have, 0);
                @memset(&s.starts, 0);
                s.first_end = 0;
            }

            /// `[from, to)` 里是否已经有收到的字节块。
            fn anySet(have: []const u8, from: usize, to: usize) bool {
                for (have[from / 8 .. (to + 7) / 8]) |v| {
                    if (v != 0) return true;
                }
                return false;
            }

            fn allSet(have: []const u8, from: usize, to: usize) bool {
                for (have[from / 8 .. (to + 7) / 8]) |v| {
                    if (v == 0) return false;
                }
                return true;
            }

            fn fill(have: []u8, from: usize, to: usize) void {
                @memset(have[from / 8 .. (to + 7) / 8], 1);
            }
        };
    }
};

// ---------------------------------------------------------------------------
// 适配层头栈（RFC 4944 §5：Mesh → Broadcast → Fragmentation）
// ---------------------------------------------------------------------------

/// 一个 6LoWPAN 载荷按 RFC 4944 §5 的顺序走完 Mesh / BC0 / 分页 / 分片头之后的结果。
pub const Stack = struct {
    /// RFC 4944 §5.3 四元组的地址部分：有 Mesh 头时是 Originator / Final Destination，
    /// 否则是 MAC 头的两端。
    sender: Addr,
    dest: Addr,
    mesh: ?mesh.Header = null,
    /// LOWPAN_BC0 的序号（RFC 4944 §11.1）。
    bc0_seq: ?u8 = null,
    /// 分片头。
    frag: ?frag.Header = null,
    /// 最里面一层的 dispatch。
    dispatch: Dispatch,
    /// 最里面一层的载荷：有分片头时是这一片的载荷，否则是整个数据报（IPHC 或 0x41）。
    body: []const u8,
};

/// `stack` 是解析结果；`frame` 是从分片头开始的那一段（没有分片头时与 `body` 相同），
/// 可以直接喂给 `frag.Reassembler.push`。
pub const StackDecoded = struct { stack: Stack, frame: []const u8 };

/// 解析头栈。`frame` 是 MAC 头之后的整个 6LoWPAN 载荷，`mac` 是它的 MAC 头。
pub fn parseStack(frame: []const u8, mac: *const MacHeader) Error!StackDecoded {
    if (frame.len == 0) return error.Short;
    var st = Stack{
        .sender = mac.src,
        .dest = mac.dest,
        .dispatch = dispatchOf(frame[0]),
        .body = frame,
    };
    var rest = frame;
    // Mesh、BC0、分页 dispatch 各至多出现有限次；超过这个次数一定是坏帧。
    var rounds: usize = 0;
    while (true) {
        rounds += 1;
        if (rounds > 5) return error.BadDispatch;
        if (rest.len == 0) return error.Short;
        st.dispatch = dispatchOf(rest[0]);
        switch (st.dispatch) {
            .mesh => {
                // 头栈顺序（§5）：Mesh 在最前面。
                if (st.mesh != null or st.bc0_seq != null or st.frag != null) return error.BadDispatch;
                const d = try mesh.decodeHeader(rest);
                st.mesh = d.header;
                st.sender = d.header.originator;
                st.dest = d.header.final;
                rest = d.rest;
            },
            .bc0 => {
                if (st.bc0_seq != null or st.frag != null) return error.BadDispatch;
                if (rest.len < 2) return error.Short;
                st.bc0_seq = rest[1];
                rest = rest[2..];
            },
            .paging => {
                // RFC 8025 §3：低 4 位是页号；§4 只把 Page 1 定义成与 Page 0 的 IPHC 同值。
                if ((rest[0] & 0x0f) != 1) return error.UnsupportedCompression;
                if (rest.len < 2) return error.Short;
                rest = rest[1..];
            },
            .frag1, .fragn => {
                if (st.frag != null) return error.BadDispatch;
                const d = try frag.decodeHeader(rest);
                st.frag = d.header;
                st.body = d.payload;
                return .{ .stack = st, .frame = rest };
            },
            else => break,
        }
    }
    st.body = rest;
    return .{ .stack = st, .frame = rest };
}
