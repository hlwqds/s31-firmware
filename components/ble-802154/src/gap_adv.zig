//! ble-802154：GAP 广播数据、设备地址与广播参数（Bluetooth Core 5.4）。
//!
//! 规范出处（都是本次从原文读到的，条款号与原文一致）：
//!   * AD 结构 = Length(1，非零) + AD Type(1) + AD Data(Length−1)，其后是全 0
//!     的 non-significant part —— [Vol 3] Part C §11（Advertising and Scan
//!     Response data format）；
//!   * AD Type 的编号 —— Bluetooth Assigned Numbers（2026-11-16 版）§2.3
//!     Common Data Types；
//!   * 各 AD Type 的值格式 —— Core Specification Supplement v11 Part A：
//!     Service UUID §1.1、Local name §1.2、Flags §1.3、Manufacturer Specific
//!     Data §1.4、TX Power Level §1.5、Peripheral Connection Interval Range
//!     §1.9、Service Data §1.11、Appearance §1.12；
//!   * Appearance 的位布局（bit 15–6 类别、bit 5–0 子类别）—— Assigned
//!     Numbers §2.6.1；
//!   * 随机地址的三个子类型、生成与解析 —— [Vol 3] Part C §10.8 指向
//!     [Vol 6] Part B §1.3.2.1（静态地址）、§1.3.2.2（私有地址生成）、
//!     §1.3.2.3（解析），子类型位在最高有效字节的最高两位（图 1.2–1.4）；
//!   * 随机地址哈希 ah —— [Vol 3] Part H §2.2.2；安全函数 e 是 AES-128
//!     （§2.2.1）；
//!   * HCI 参数打包 —— [Vol 4] Part E §7.8.5（LE Set Advertising Parameters），
//!     §7.8.7 / §7.8.8（31 字节定长数据，长度字段 0x00–0x1F）。
//!
//! 地址一律用 HCI/空口的字节序：**最低有效字节在前**（[Vol 4] Part E §5.2
//! “Least Significant Octet is transmitted first”）。所以 `bytes[5]` 是最高
//! 有效字节，随机子类型的两位就在它身上。
//!
//! 没有分配、没有全局状态：`Builder` 是调用方栈上的 31 字节缓冲，放不下就
//! 返回 `error.NoSpace` 且缓冲不变（不写一半、不静默截断）。

const std = @import("std");

const Aes128 = std.crypto.core.aes.Aes128;

/// 一个 AD 块（AdvData 或 ScanRspData）的上限。[Vol 4] Part E §7.8.7。
pub const adv_data_max: usize = 31;

pub const Error = error{
    /// 放不下 31 字节；缓冲保持原样。
    NoSpace,
    /// 输入比固定长度短。
    Short,
    /// AD 结构的 Length 越过缓冲末尾，或值长度不是元素宽度的整数倍。
    BadLength,
    /// 取值不在规范允许的范围内。
    BadParam,
};

// ---------------------------------------------------------------------------
// AD Type 编号与 Flags 位
// ---------------------------------------------------------------------------

/// AD Type 编号。Assigned Numbers §2.3（Common Data Types）。
pub const AdType = struct {
    pub const flags: u8 = 0x01;
    pub const uuid16_incomplete: u8 = 0x02;
    pub const uuid16_complete: u8 = 0x03;
    pub const uuid32_incomplete: u8 = 0x04;
    pub const uuid32_complete: u8 = 0x05;
    pub const uuid128_incomplete: u8 = 0x06;
    pub const uuid128_complete: u8 = 0x07;
    pub const name_shortened: u8 = 0x08;
    pub const name_complete: u8 = 0x09;
    pub const tx_power_level: u8 = 0x0A;
    pub const conn_interval_range: u8 = 0x12;
    pub const service_data16: u8 = 0x16;
    pub const appearance: u8 = 0x19;
    pub const service_data32: u8 = 0x20;
    pub const service_data128: u8 = 0x21;
    pub const manufacturer_specific_data: u8 = 0xFF;
};

/// Flags 的低四位。CSS v11 Part A §1.3.2 表 1.4（bit 4 是 Previously Used）。
pub const flag_le_limited_discoverable: u8 = 1 << 0;
pub const flag_le_general_discoverable: u8 = 1 << 1;
pub const flag_bredr_not_supported: u8 = 1 << 2;
pub const flag_simultaneous_le_bredr: u8 = 1 << 3;

/// 解出 Flags：尾部省略的全 0 字节补回，只保留 bit 0–3。
pub fn decodeFlags(data: []const u8) u8 {
    // 零长度（值全 0 被全省略）也是合法的 Flags AD。
    if (data.len == 0) return 0;
    return data[0] & 0x0F;
}

/// 一个 Service UUID 列表 AD Type 的元素宽度与完整性。
pub const UuidWidth = struct { width: u8, complete: bool };

pub fn uuidWidth(ad_type: u8) ?UuidWidth {
    return switch (ad_type) {
        AdType.uuid16_incomplete => .{ .width = 2, .complete = false },
        AdType.uuid16_complete => .{ .width = 2, .complete = true },
        AdType.uuid32_incomplete => .{ .width = 4, .complete = false },
        AdType.uuid32_complete => .{ .width = 4, .complete = true },
        AdType.uuid128_incomplete => .{ .width = 16, .complete = false },
        AdType.uuid128_complete => .{ .width = 16, .complete = true },
        else => null,
    };
}

/// 解出的 Service UUID 列表：`bytes` 是 AD Data 原样（每个元素 `width`
/// 字节，小端；128 位按传输顺序）。元素个数 = `bytes.len / width`。
pub const UuidList = struct { width: u8, complete: bool, bytes: []const u8 };

/// 校验一个 UUID 列表 AD 的值长度；宽度不对或不是整数个元素 → `BadLength`。
pub fn decodeUuidList(ad_type: u8, data: []const u8) Error!UuidList {
    const w = uuidWidth(ad_type) orelse return error.BadParam;
    if (data.len % w.width != 0) return error.BadLength;
    return .{ .width = w.width, .complete = w.complete, .bytes = data };
}

/// 把 128 位 UUID 按“书写顺序”（最高有效字节在前）转成传输顺序。
/// 传输顺序是最低有效字节在前：这一点与 ATT 一致（[Vol 3] Part F §3.3.1
/// “Multi-octet fields … least significant octet first”）；AD 结构里 128 位
/// UUID 的字节序原文没有单独写明，见 README「实现偏离」。
pub fn uuid128ToWire(msb_first: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    for (msb_first, 0..) |b, i| out[15 - i] = b;
    return out;
}

// ---------------------------------------------------------------------------
// 构造
// ---------------------------------------------------------------------------

/// 31 字节 AD 块的构造器。AdvData 与 ScanRspData 用同一个类型。
pub const Builder = struct {
    buf: [adv_data_max]u8 = undefined,
    len: u8 = 0,

    pub fn reset(self: *Builder) void {
        self.len = 0;
    }

    /// significant part（要发上天的字节）。
    pub fn data(self: *const Builder) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn free(self: *const Builder) usize {
        return adv_data_max - @as(usize, self.len);
    }

    /// 追加一个 AD 结构。放不下 → `NoSpace`，缓冲与长度都不动。
    pub fn append(self: *Builder, ad_type: u8, ad_data: []const u8) Error!void {
        return self.appendHead(ad_type, ad_data, &.{});
    }

    fn appendHead(self: *Builder, ad_type: u8, head: []const u8, tail: []const u8) Error!void {
        const body = head.len + tail.len;
        // Length 只有一字节，装不下 1 + 255；31 字节上限之下 30 已是最大值。
        if (body > adv_data_max - 1) return error.NoSpace;
        const need = 2 + body;
        if (need > self.free()) return error.NoSpace;
        const pos: usize = self.len;
        self.buf[pos] = @intCast(1 + body);
        self.buf[pos + 1] = ad_type;
        @memcpy(self.buf[pos + 2 ..][0..head.len], head);
        @memcpy(self.buf[pos + 2 + head.len ..][0..tail.len], tail);
        self.len = @intCast(pos + need);
    }

    /// Flags。值为 0 时只留 Type（CSS §1.3.1：最后一个非 0 字节之后的 0 全省略）。
    pub fn flags(self: *Builder, bits: u8) Error!void {
        if ((bits & ~@as(u8, 0x0F)) != 0) return error.BadParam;
        const one = [_]u8{bits};
        return self.append(AdType.flags, one[0..@intFromBool(bits != 0)]);
    }

    /// 预留一个 UUID 列表 AD 的位置，返回它的起始偏移。
    fn uuidList(self: *Builder, ad_type: u8, width: usize, count: usize, complete: bool) Error!usize {
        // 省略一个类型就等于“空的不完整列表”（CSS §1.1.1），所以空列表只允许 complete。
        if (count == 0 and !complete) return error.BadParam;
        const body = width * count;
        const need = 2 + body;
        if (need > self.free()) return error.NoSpace;
        const pos: usize = self.len;
        self.buf[pos] = @intCast(1 + body);
        self.buf[pos + 1] = ad_type;
        self.len = @intCast(pos + need);
        return pos;
    }

    /// 16 位 Service UUID 列表，每个 2 字节小端。
    pub fn uuids16(self: *Builder, uuids: []const u16, complete: bool) Error!void {
        const pos = try self.uuidList(
            if (complete) AdType.uuid16_complete else AdType.uuid16_incomplete,
            2,
            uuids.len,
            complete,
        );
        for (uuids, 0..) |u, i| std.mem.writeInt(u16, self.buf[pos + 2 + 2 * i ..][0..2], u, .little);
    }

    /// 32 位 Service UUID 列表，每个 4 字节小端。
    pub fn uuids32(self: *Builder, uuids: []const u32, complete: bool) Error!void {
        const pos = try self.uuidList(
            if (complete) AdType.uuid32_complete else AdType.uuid32_incomplete,
            4,
            uuids.len,
            complete,
        );
        for (uuids, 0..) |u, i| std.mem.writeInt(u32, self.buf[pos + 2 + 4 * i ..][0..4], u, .little);
    }

    /// 128 位 Service UUID 列表，每个按传输顺序（见 `uuid128ToWire`）。
    pub fn uuids128(self: *Builder, uuids: []const [16]u8, complete: bool) Error!void {
        const pos = try self.uuidList(
            if (complete) AdType.uuid128_complete else AdType.uuid128_incomplete,
            16,
            uuids.len,
            complete,
        );
        for (uuids, 0..) |u, i| @memcpy(self.buf[pos + 2 + 16 * i ..][0..16], &u);
    }

    /// 本地名。缩短名必须是完整名从头开始的连续片段（CSS §1.2.1）——这一点
    /// 调用方保证，这里只拒绝空串。
    pub fn name(self: *Builder, s: []const u8, complete: bool) Error!void {
        if (s.len == 0) return error.BadParam;
        return self.append(if (complete) AdType.name_complete else AdType.name_shortened, s);
    }

    /// 发射功率，单位 dBm，范围 −127…+127（CSS §1.5.2）。
    pub fn txPower(self: *Builder, dbm: i8) Error!void {
        return self.append(AdType.tx_power_level, &[_]u8{@bitCast(dbm)});
    }

    /// Peripheral 偏好的连接间隔范围。单位 1.25 ms，范围 0x0006–0x0C80，
    /// 0xFFFF 表示“无特殊要求”（CSS §1.9.2）。
    pub fn connIntervalRange(self: *Builder, min: u16, max: u16) Error!void {
        const lo: u16 = 0x0006;
        const hi: u16 = 0x0C80;
        const any: u16 = 0xFFFF;
        const ok = struct {
            fn f(v: u16) bool {
                return v == any or (v >= lo and v <= hi);
            }
        }.f;
        if (!ok(min) or !ok(max)) return error.BadParam;
        if (min != any and max != any and min > max) return error.BadParam;
        var body: [4]u8 = undefined;
        std.mem.writeInt(u16, body[0..2], min, .little);
        std.mem.writeInt(u16, body[2..4], max, .little);
        return self.append(AdType.conn_interval_range, &body);
    }

    /// Service Data − 16 位 UUID：UUID（2 字节小端）后跟服务自定义数据。
    pub fn serviceData16(self: *Builder, uuid: u16, extra: []const u8) Error!void {
        var head: [2]u8 = undefined;
        std.mem.writeInt(u16, &head, uuid, .little);
        return self.appendHead(AdType.service_data16, &head, extra);
    }

    /// Service Data − 32 位 UUID。
    pub fn serviceData32(self: *Builder, uuid: u32, extra: []const u8) Error!void {
        var head: [4]u8 = undefined;
        std.mem.writeInt(u32, &head, uuid, .little);
        return self.appendHead(AdType.service_data32, &head, extra);
    }

    /// Service Data − 128 位 UUID（按传输顺序）。
    pub fn serviceData128(self: *Builder, uuid: [16]u8, extra: []const u8) Error!void {
        return self.appendHead(AdType.service_data128, &uuid, extra);
    }

    /// Appearance 值：bit 15–6 类别、bit 5–0 子类别（Assigned Numbers §2.6.1）。
    pub fn appearanceValue(category: u16, sub_category: u8) Error!u16 {
        if (category > 0x03FF or sub_category > 0x3F) return error.BadParam;
        return (category << 6) | @as(u16, sub_category);
    }

    pub fn appearance(self: *Builder, category: u16, sub_category: u8) Error!void {
        var body: [2]u8 = undefined;
        std.mem.writeInt(u16, &body, try appearanceValue(category, sub_category), .little);
        return self.append(AdType.appearance, &body);
    }

    /// 厂商自定义数据：前两字节是 Company Identifier（小端），其余厂商自定
    /// （CSS §1.4）。
    pub fn manufacturer(self: *Builder, company_id: u16, extra: []const u8) Error!void {
        var head: [2]u8 = undefined;
        std.mem.writeInt(u16, &head, company_id, .little);
        return self.appendHead(AdType.manufacturer_specific_data, &head, extra);
    }

    /// HCI 的 LE_Set_Advertising_Data / LE_Set_Scan_Response_Data 参数：
    /// Length(1) + 31 字节定长，不足处补 0。[Vol 4] Part E §7.8.7、§7.8.8。
    pub fn packHci(self: *const Builder, out: *[1 + adv_data_max]u8) void {
        out[0] = self.len;
        @memcpy(out[1 .. 1 + self.len], self.data());
        @memset(out[1 + self.len ..], 0);
    }
};

/// 一次广播的两段数据。`append` 优先放 AdvData，放不下就挪到 ScanRspData
/// （只在收到 SCAN_REQ 才发的那一段）；两段都放不下才报 `NoSpace`。
pub const AdvSet = struct {
    adv: Builder = .{},
    scan_rsp: Builder = .{},

    pub fn reset(self: *AdvSet) void {
        self.adv.reset();
        self.scan_rsp.reset();
    }

    pub fn append(self: *AdvSet, ad_type: u8, ad_data: []const u8) Error!void {
        if (self.adv.append(ad_type, ad_data)) |_| {
            return;
        } else |err| {
            if (err != error.NoSpace) return err;
        }
        return self.scan_rsp.append(ad_type, ad_data);
    }
};

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

/// 一个 AD 结构：类型 + 值（不含 Length 与 Type）。
pub const Ad = struct { ad_type: u8, data: []const u8 };

/// 遍历 significant part。遇到 0x00（non-significant part 的开始）就停；
/// Length 越过缓冲末尾 → `BadLength`，之后的 `next()` 不再返回东西。
pub const Iterator = struct {
    rest: []const u8,

    pub fn next(self: *Iterator) Error!?Ad {
        if (self.rest.len == 0) return null;
        const len: usize = self.rest[0];
        // [Vol 3] Part C §11：Length “shall not be zero”——0 只可能是填充。
        if (len == 0) {
            self.rest = &.{};
            return null;
        }
        if (self.rest.len < 1 + len) {
            self.rest = &.{};
            return error.BadLength;
        }
        const ad = Ad{ .ad_type = self.rest[1], .data = self.rest[2 .. 1 + len] };
        self.rest = self.rest[1 + len ..];
        return ad;
    }
};

pub fn iterate(ad: []const u8) Iterator {
    return .{ .rest = ad };
}

/// 取第一个该类型的 AD 值；没有返回 null。
pub fn find(ad: []const u8, ad_type: u8) Error!?[]const u8 {
    var it = iterate(ad);
    while (try it.next()) |a| {
        if (a.ad_type == ad_type) return a.data;
    }
    return null;
}

pub const LocalName = struct { name: []const u8, complete: bool };

/// 本地名。同一块里两种都有时优先完整名。
pub fn localName(ad: []const u8) Error!?LocalName {
    if (try find(ad, AdType.name_complete)) |n| return .{ .name = n, .complete = true };
    if (try find(ad, AdType.name_shortened)) |n| return .{ .name = n, .complete = false };
    return null;
}

/// 把一个 UUID 列表 AD 的值读成 `out` 个 u16（仅 16 位列表）。返回元素个数。
pub fn readUuids16(list: UuidList, out: []u16) Error!usize {
    if (list.width != 2) return error.BadParam;
    const n = list.bytes.len / 2;
    if (n > out.len) return error.NoSpace;
    for (0..n) |i| out[i] = std.mem.readInt(u16, list.bytes[2 * i ..][0..2], .little);
    return n;
}

// ---------------------------------------------------------------------------
// 设备地址
// ---------------------------------------------------------------------------

/// BLE 设备地址，6 字节，最低有效字节在前（[Vol 4] Part E §5.2）。
pub const Addr = struct {
    bytes: [6]u8 = @splat(0),

    /// HCI 的 Peer_Address_Type 取值（[Vol 4] Part E §7.8.5）：0 公有，1 随机。
    pub const Type = enum(u8) { public = 0x00, random = 0x01 };

    /// 随机地址的子类型，看最高有效字节（`bytes[5]`）的最高两位。
    /// [Vol 6] Part B 图 1.2–1.4：静态 0b11、不可解析私有 0b00、可解析私有
    /// （prand）0b01。图里 LSB 在左、MSB 在右，读子类型位要从**右**往左数。
    pub fn randomKind(self: Addr) RandomKind {
        return switch (self.bytes[5] & 0xC0) {
            0xC0 => .static,
            0x40 => .resolvable_private,
            0x00 => .non_resolvable_private,
            else => .reserved,
        };
    }

    /// prand：地址的高 3 字节（[Vol 6] Part B §1.3.2.3）。
    pub fn prand(self: Addr) [3]u8 {
        return .{ self.bytes[3], self.bytes[4], self.bytes[5] };
    }

    /// hash：地址的低 3 字节。
    pub fn hash(self: Addr) [3]u8 {
        return .{ self.bytes[0], self.bytes[1], self.bytes[2] };
    }
};

pub const RandomKind = enum { static, resolvable_private, non_resolvable_private, reserved };

/// 安全函数 e：AES-128 单块加密（[Vol 3] Part H §2.2.1）。
pub fn e(key: [16]u8, block: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    Aes128.initEnc(key).encrypt(&out, &block);
    return out;
}

/// 随机地址哈希 ah(k, r) = e(k, r′) mod 2²⁴；r′ = 104 位 0 填充 ‖ r（24 位），
/// r 的最低有效字节在最后。[Vol 3] Part H §2.2.2。
///
/// `prand` 用地址字节序：`prand[2]` 是最高有效字节。
pub fn ah(irk: [16]u8, prand: [3]u8) [3]u8 {
    var block: [16]u8 = @splat(0);
    // r′ 的最低 3 字节是 r：最高有效字节在 `prand[2]`（地址字节序）。
    block[13] = prand[2];
    block[14] = prand[1];
    block[15] = prand[0];
    const out = e(irk, block);
    // 结果按地址字节序返回：hash 的最低有效字节在前，直接拼进地址。
    return .{ out[15], out[14], out[13] };
}

/// 46 位随机部分是否全 0 或全 1（两种都违反 §1.3.2.1 / §1.3.2.2）。
fn randomPartDegenerate(a: Addr) bool {
    var all_zero = true;
    var all_one = true;
    for (a.bytes[0..5]) |b| {
        if (b != 0x00) all_zero = false;
        if (b != 0xFF) all_one = false;
    }
    const top = a.bytes[5] & 0x3F;
    if (top != 0x00) all_zero = false;
    if (top != 0x3F) all_one = false;
    return all_zero or all_one;
}

/// 由 6 个随机字节生成静态地址：最高两位置 0b11。[Vol 6] Part B §1.3.2.1。
/// 随机部分全 0 或全 1 → `BadParam`（换一份随机数再来）。
pub fn generateStatic(rand: [6]u8) Error!Addr {
    var a = Addr{ .bytes = rand };
    a.bytes[5] |= 0xC0;
    if (randomPartDegenerate(a)) return error.BadParam;
    return a;
}

/// 由 6 个随机字节生成不可解析私有地址：最高两位置 0b00；且不得等于本机
/// 公有地址。[Vol 6] Part B §1.3.2.2。
pub fn generateNonResolvable(rand: [6]u8, public: Addr) Error!Addr {
    var a = Addr{ .bytes = rand };
    a.bytes[5] &= 0x3F;
    if (randomPartDegenerate(a)) return error.BadParam;
    if (std.mem.eql(u8, &a.bytes, &public.bytes)) return error.BadParam;
    return a;
}

/// 由 IRK 与 prand 生成可解析私有地址：randomAddress = prand ‖ hash，
/// hash = ah(IRK, prand)。[Vol 6] Part B §1.3.2.2。prand 的最高两位必须是
/// 0b01（图 1.4：靠 MSB 的两格从右往左是 0、1），22 位随机部分不得全 0 或全 1。
pub fn generateRpa(irk: [16]u8, prand: [3]u8) Error!Addr {
    if (prand[2] & 0xC0 != 0x40) return error.BadParam;
    const rnd: u32 = (@as(u32, prand[2] & 0x3F) << 16) | (@as(u32, prand[1]) << 8) | @as(u32, prand[0]);
    if (rnd == 0 or rnd == 0x3F_FFFF) return error.BadParam;
    const hash = ah(irk, prand);
    return .{ .bytes = .{ hash[0], hash[1], hash[2], prand[0], prand[1], prand[2] } };
}

/// 用 IRK 解析一个地址：localHash = ah(IRK, prand) 与地址里的 hash 相等即
/// 解析成功。[Vol 6] Part B §1.3.2.3。子类型不是可解析私有 → false。
/// 比较用恒定时间函数。
pub fn resolve(addr: Addr, irk: [16]u8) bool {
    if (addr.randomKind() != .resolvable_private) return false;
    const local = ah(irk, addr.prand());
    return std.crypto.timing_safe.eql([3]u8, local, addr.hash());
}

// ---------------------------------------------------------------------------
// 广播参数与 HCI 打包
// ---------------------------------------------------------------------------

/// HCI 的 Own_Address_Type（[Vol 4] Part E §7.8.5）。
pub const OwnAddrType = enum(u8) {
    public = 0x00,
    random = 0x01,
    /// controller 用本地 IRK 生成 RPA；解析列表里没有对应项就用公有地址。
    rpa_or_public = 0x02,
    /// 同上，兜底用 LE_Set_Random_Address 设的随机地址。
    rpa_or_random = 0x03,
};

/// HCI 的 Advertising_Type（[Vol 4] Part E §7.8.5）。
pub const AdvType = enum(u8) {
    /// 0x00：可连接可扫描无方向（ADV_IND，默认）。
    adv_ind = 0x00,
    /// 0x01：可连接高占空比定向。
    adv_direct_ind_high = 0x01,
    /// 0x02：可扫描无方向（ADV_SCAN_IND）。
    adv_scan_ind = 0x02,
    /// 0x03：不可连接无方向（ADV_NONCONN_IND）。
    adv_nonconn_ind = 0x03,
    /// 0x04：可连接低占空比定向。
    adv_direct_ind_low = 0x04,
};

/// HCI 的 Advertising_Filter_Policy（[Vol 4] Part E §7.8.5）。
pub const AdvFilterPolicy = enum(u8) {
    all = 0x00,
    scan_from_list = 0x01,
    connect_from_list = 0x02,
    both_from_list = 0x03,
};

/// 广播间隔：Time = N × 0.625 ms，范围 0x0020–0x4000（20 ms–10.24 s），
/// 默认 0x0800（1.28 s）。[Vol 4] Part E §7.8.5。
pub const adv_interval_min: u16 = 0x0020;
pub const adv_interval_max: u16 = 0x4000;
pub const adv_interval_default: u16 = 0x0800;

/// LE Set Advertising Parameters 的 8 个参数（[Vol 4] Part E §7.8.5），共 15 字节。
pub const AdvParams = struct {
    interval_min: u16 = adv_interval_default,
    interval_max: u16 = adv_interval_default,
    type: AdvType = .adv_ind,
    own_addr_type: OwnAddrType = .public,
    peer_addr_type: Addr.Type = .public,
    peer_addr: Addr = .{},
    /// bit 0/1/2 对应信道 37/38/39，至少置一位；默认 0x07。
    channel_map: u8 = 0x07,
    filter_policy: AdvFilterPolicy = .all,

    pub const packed_len: usize = 15;

    /// 取值检查：间隔在范围内且 min ≤ max，信道图至少一位且只用低三位，
    /// 定向广播必须给出对端地址（非全 0）。
    pub fn validate(self: AdvParams) Error!void {
        const in_range = struct {
            fn f(v: u16) bool {
                return v >= adv_interval_min and v <= adv_interval_max;
            }
        }.f;
        if (!in_range(self.interval_min) or !in_range(self.interval_max)) return error.BadParam;
        if (self.interval_min > self.interval_max) return error.BadParam;
        if (self.channel_map == 0 or (self.channel_map & ~@as(u8, 0x07)) != 0) return error.BadParam;
        const directed = self.type == .adv_direct_ind_high or self.type == .adv_direct_ind_low;
        if (directed and std.mem.allEqual(u8, &self.peer_addr.bytes, 0)) return error.BadParam;
    }

    /// 按参数表顺序打包：Interval_Min(2) Interval_Max(2) Type(1)
    /// Own_Address_Type(1) Peer_Address_Type(1) Peer_Address(6)
    /// Advertising_Channel_Map(1) Advertising_Filter_Policy(1)。
    pub fn pack(self: AdvParams, out: *[packed_len]u8) Error!void {
        try self.validate();
        std.mem.writeInt(u16, out[0..2], self.interval_min, .little);
        std.mem.writeInt(u16, out[2..4], self.interval_max, .little);
        out[4] = @backingInt(self.type);
        out[5] = @backingInt(self.own_addr_type);
        out[6] = @backingInt(self.peer_addr_type);
        @memcpy(out[7..13], &self.peer_addr.bytes);
        out[13] = self.channel_map;
        out[14] = @backingInt(self.filter_policy);
    }
};
