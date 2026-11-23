//! ble-security：绑定信息库（以 identity address 为键的有界表）。
//!
//! 出处：Bluetooth Core Specification 5.4 [Vol 3] Part H：
//!   * 2.4.1        LTK、EDIV、Rand、IRK、CSRK 的定义
//!   * 2.4.3.1      legacy 分发的密钥；收到的 identity 地址要到用它重连成功才算有效
//!   * 2.4.3.2      Secure Connections 的密钥（EDIV、Rand 为 0）
//!   * 2.4.4.2      重连时用 (EDIV, Rand) 找 LTK
//!   * 附录 B.1     以 EDIV 为索引的数据库查找
//!   * [Vol 6] Part B 1.3.2.3  用 IRK 与 ah 解析 resolvable private address
//!
//! 表是固定容量的数组，没有堆：同 identity 覆盖，满了淘汰最久未用的一条。
//! 「最久未用」用调用方传入的单调计数（任意单位）衡量。

const std = @import("std");

const toolbox = @import("toolbox.zig");

pub const AddrType = enum(u8) {
    public = 0x00,
    random = 0x01,
};

/// 设备地址：类型 + 6 字节（线上顺序，最低位八位组在前）。
pub const Addr = struct {
    type: AddrType,
    val: toolbox.Addr = @splat(0),

    pub fn eql(a: Addr, b: Addr) bool {
        return a.type == b.type and std.mem.eql(u8, &a.val, &b.val);
    }

    /// [Vol 6] Part B 1.3.2 Table 1.2：随机地址最高两位 0b11 是 static。
    pub fn isStaticRandom(a: Addr) bool {
        return a.type == .random and (a.val[5] & 0xC0) == 0xC0;
    }

    /// 最高两位 0b01 是 resolvable private address。
    pub fn isResolvablePrivate(a: Addr) bool {
        return a.type == .random and (a.val[5] & 0xC0) == 0x40;
    }

    /// 可以作为 identity 的只有 public 与 static random 地址。
    pub fn isIdentity(a: Addr) bool {
        return a.type == .public or a.isStaticRandom();
    }
};

/// 一把 LTK 及其在重连时的标识。
pub const Ltk = struct {
    key: toolbox.Key = @splat(0),
    key_size: u8 = 16,
    /// legacy 分发的 LTK 用 EDIV、Rand 标识；Secure Connections 时二者为 0。
    ediv: u16 = 0,
    rand: u64 = 0,
};

/// 与一个对端绑定后保存的全部信息。
pub const Bond = struct {
    identity: Addr,
    /// 对端持有的 LTK：本机做 Central 重连时用它发起加密。legacy 配对时由对端
    /// 分发（EncKey），Secure Connections 时是 f5 派生的那把。
    peer_ltk: Ltk = .{},
    has_peer_ltk: bool = false,
    /// 本机分发过的 LTK（legacy）：对端做 Central 重连时用 (EDIV, Rand) 来要它。
    own_ltk: Ltk = .{},
    has_own_ltk: bool = false,
    irk: toolbox.Key = @splat(0),
    has_irk: bool = false,
    csrk: toolbox.Key = @splat(0),
    has_csrk: bool = false,
    /// 配出密钥的方法是否提供 MITM 保护（2.3.1 的 Security Properties）。
    authenticated: bool = false,
    sc: bool = false,
    /// 2.4.3.1：收到 identity 地址后，要用它重连成功才置位。
    verified: bool = false,
    /// 2.4.5：最近一次验证通过的 SignCounter，用于防重放。
    peer_sign_counter: u32 = 0,
};

pub const PutResult = enum {
    inserted,
    replaced,
    /// 表满，淘汰了最久未用的一条。
    evicted,
    /// identity 不是 public / static random 地址，不能入库。
    invalid_identity,
};

pub fn Store(comptime capacity: u8) type {
    return struct {
        const Self = @This();

        slots: [capacity]?Bond = @splat(null),
        used_seq: [capacity]u32 = @splat(0),
        clock: u32 = 0,

        pub fn count(self: *const Self) u8 {
            var n: u8 = 0;
            for (self.slots) |s| {
                if (s != null) n += 1;
            }
            return n;
        }

        fn tick(self: *Self) u32 {
            self.clock +%= 1;
            return self.clock;
        }

        pub fn find(self: *Self, identity: Addr) ?*Bond {
            for (&self.slots, 0..) |*s, i| {
                if (s.* != null and s.*.?.identity.eql(identity)) {
                    self.used_seq[i] = self.tick();
                    return &s.*.?;
                }
            }
            return null;
        }

        /// 2.4.4.2 / 附录 B.1：对端拿着 (EDIV, Rand) 来要求加密时，找本机分发过的 LTK。
        pub fn findOwnLtk(self: *Self, ediv: u16, rand: u64) ?*Bond {
            for (&self.slots) |*s| {
                const b = &(s.* orelse continue);
                if (b.has_own_ltk and b.own_ltk.ediv == ediv and b.own_ltk.rand == rand) return b;
            }
            return null;
        }

        /// [Vol 6] Part B 1.3.2.3：逐个 IRK 算 ah(IRK, prand)，与地址里的 hash 比较。
        /// 返回的条目是借用的引用；`put` 可能挪动表里的内容。
        pub fn resolve(self: *Self, rpa: toolbox.Addr) ?*Bond {
            if ((rpa[5] & 0xC0) != 0x40) return null;
            const prand: [3]u8 = .{ rpa[5], rpa[4], rpa[3] };
            const hash: [3]u8 = .{ rpa[2], rpa[1], rpa[0] };
            for (&self.slots, 0..) |*s, i| {
                const b = &(s.* orelse continue);
                if (!b.has_irk) continue;
                if (std.mem.eql(u8, &toolbox.ah(b.irk, prand), &hash)) {
                    self.used_seq[i] = self.tick();
                    return b;
                }
            }
            return null;
        }

        /// 插入或替换。同一 identity 覆盖旧条目；表满时淘汰 `used_seq` 最小的。
        pub fn put(self: *Self, bond: Bond) PutResult {
            if (!bond.identity.isIdentity()) return .invalid_identity;
            var free: ?usize = null;
            var oldest: usize = 0;
            for (&self.slots, self.used_seq, 0..) |*s, seq, i| {
                if (s.* != null) {
                    if (s.*.?.identity.eql(bond.identity)) {
                        s.* = bond;
                        self.used_seq[i] = self.tick();
                        return .replaced;
                    }
                } else if (free == null) {
                    free = i;
                }
                if (seq < self.used_seq[oldest]) oldest = i;
            }
            var result: PutResult = .inserted;
            var slot: usize = undefined;
            if (free) |f| {
                slot = f;
            } else {
                slot = oldest;
                result = .evicted;
            }
            self.slots[slot] = bond;
            self.used_seq[slot] = self.tick();
            return result;
        }

        pub fn remove(self: *Self, identity: Addr) bool {
            for (&self.slots) |*s| {
                if (s.* != null and s.*.?.identity.eql(identity)) {
                    s.* = null;
                    return true;
                }
            }
            return false;
        }

        pub fn clear(self: *Self) void {
            self.slots = @splat(null);
            self.used_seq = @splat(0);
        }

        pub fn at(self: *Self, index: u8) ?*Bond {
            if (index >= capacity) return null;
            return if (self.slots[index]) |*b| b else null;
        }
    };
}

/// [Vol 6] Part B 1.3.2.2：randomAddress = prand || hash，hash = ah(IRK, prand)。
/// `prand` 的最高两位必须是 0b01，函数会强制置位。返回线上顺序（hash 的最低位
/// 八位组在前）。
pub fn generateRpa(irk: toolbox.Key, prand: [3]u8) toolbox.Addr {
    var p = prand;
    p[0] = (p[0] & 0x3F) | 0x40;
    const hash = toolbox.ah(irk, p);
    return .{ hash[2], hash[1], hash[0], p[2], p[1], p[0] };
}

/// `rpa` 是否是 `irk` 生成的 resolvable private address。
pub fn resolvesTo(irk: toolbox.Key, rpa: toolbox.Addr) bool {
    if ((rpa[5] & 0xC0) != 0x40) return false;
    const prand: [3]u8 = .{ rpa[5], rpa[4], rpa[3] };
    const hash: [3]u8 = .{ rpa[2], rpa[1], rpa[0] };
    return std.mem.eql(u8, &toolbox.ah(irk, prand), &hash);
}
