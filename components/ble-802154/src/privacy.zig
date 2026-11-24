//! ble-802154：解析列表（resolving list）、主机侧地址解析与 LL Privacy（Bluetooth Core 5.4）。
//!
//! 规范出处（都是本次从原文读到的，条款号与原文一致）：
//!   * 解析列表的记录、复位后为空、两种隐私模式下接受哪些对端地址 —— [Vol 6] Part B
//!     §4.7（Resolving List）；设备自身的隐私 —— §6.5；
//!   * RPA 的生成与解析 —— [Vol 6] Part B §1.3.2.2 / §1.3.2.3；哈希 ah 与安全函数 e ——
//!     [Vol 3] Part H §2.2.2 / §2.2.1。实现复用 `gap_adv.zig` 的 `generateRpa` / `resolve`，
//!     这里不重写；
//!   * 地址比较必须带上地址类型 —— [Vol 6] Part B §1.3；
//!   * RPA 的定时更新 —— [Vol 6] Part B §6.1；host 自己换地址时同一套规则 —— [Vol 3]
//!     Part C §10.7.1.2、§10.7.2.2、§10.7.3、§10.7.4（定时器 TGAP(private_addr_int)）；
//!   * 两种隐私模式 —— [Vol 3] Part C §10.7；
//!   * 命令（[Vol 4] Part E）：LE Add Device To Resolving List §7.8.38、LE Remove Device
//!     From Resolving List §7.8.39、LE Clear Resolving List §7.8.40、LE Read Resolving List
//!     Size §7.8.41、LE Read Peer / Local Resolvable Address §7.8.42 / §7.8.43、LE Set
//!     Address Resolution Enable §7.8.44、LE Set Resolvable Private Address Timeout
//!     §7.8.45、LE Set Privacy Mode §7.8.77。
//!
//! 本文件只有纯逻辑：不驱动射频、不与 controller 通信。三块内容：
//!
//!   * `List`：解析列表在本端的镜像。host 把条目下发 controller 时用同一份数据编码命令
//!     （`cmd*`）；地址解析由 host 自己做时（例如收到的报告还没被 controller 解析）就查它。
//!     列表容量是类型参数，存储由调用方给出，没有分配；
//!   * `Scan` / `filter`：逐个 IRK 解析收到的 RPA，以及两种隐私模式下的接受规则；
//!   * `RpaTimer` / `LocalRpa`：本端 RPA 的定时更新。
//!
//! 编码器输出**完整的 H4 命令帧**（01 + OpCode + 长度 + 参数），与 `hci_cmd.zig` 同一口径：
//! 多字节参数小端（[Vol 4] Part E §5.2），6 字节地址最低有效字节在前。输出缓冲不够 →
//! `NoSpace`，值越界 → `BadParam`；两者都不写半个字节。

const std = @import("std");

const gap = @import("gap_adv.zig");
const hci = @import("hci.zig");

/// 把十六进制字面量解成字节。`vectors.zig` 里的同名函数是私有的，这里自己放一份给
/// 本特性的测试与板侧自检用。写在常量上就是编译期解码（打错一个字符是编译错误）；
/// 写在测试函数里是运行期解码——同一个测试里几十次调用不会挤占编译期的分支额度。
pub fn hex(comptime s: []const u8) [s.len / 2]u8 {
    comptime {
        if (s.len % 2 != 0) @compileError("十六进制字面量必须是偶数长度");
        for (s) |c| {
            if (!isHex(c)) @compileError("不是十六进制字符: " ++ .{c});
        }
    }
    var out: [s.len / 2]u8 = undefined;
    for (0..s.len / 2) |i| {
        out[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
    }
    return out;
}

fn isHex(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn nibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        // 走不到：不是十六进制字符的话上面已经编译报错了。
        else => 0,
    };
}

/// `Short` / `Trailing` / `NoSpace` / `Oversize` / `UnsupportedEvent` 来自 `hci.packCommand`；
/// 其中 `Short`（输入短于固定长度）、`Trailing`（输入长于声明长度）、`NoSpace`（输出
/// 缓冲放不下）也用在返回参数解析上。
pub const Error = hci.Error || error{
    /// 取值不在规范允许的范围内（controller 回 0x12 Invalid HCI Command Parameters）。
    BadParam,
};

/// 列表操作的错误。每个都对应 controller 会回的那个状态码（见 `controllerError`）。
pub const ListError = error{
    /// 随机类型的 Identity Address 不是静态地址（§7.8.38：应回 0x12）。
    BadParam,
    /// 列表已满（§7.8.38：Memory Capacity Exceeded，0x07）。
    ListFull,
    /// 四个参数完全相同的条目已在列表里。§7.8.38 允许 controller「拒绝（0x12）」或
    /// 「不重复添加并回成功」，两者取一；本实现选拒绝，免得重复下发被静默吞掉。
    Duplicate,
    /// 同一个 Identity Address（类型也相同）已在列表里，IRK 却不一样（§7.8.38：0x12）。
    IdentityConflict,
    /// 同一个非零 Peer IRK 已挂在别的 Identity Address 上（§7.8.38：0x12）。
    IrkConflict,
    /// 列表里没有这个 Identity Address（§7.8.39 / §7.8.77：Unknown Connection
    /// Identifier，0x02）。
    UnknownConnection,
};

/// 不该发这条命令（host 侧的拦截，见 `Ctl`）。
pub const CtlError = error{CommandDisallowed};

/// [Vol 1] Part F 的状态码，只列本文件用到的。数值取自 [Vol 4] Part E 各命令的原文。
pub const err_unknown_connection_identifier: u8 = 0x02;
pub const err_memory_capacity_exceeded: u8 = 0x07;
pub const err_command_disallowed: u8 = 0x0C;
pub const err_invalid_hci_command_parameters: u8 = 0x12;

/// 列表操作出错时 controller 会回的状态码。
pub fn controllerError(e: ListError) u8 {
    return switch (e) {
        error.ListFull => err_memory_capacity_exceeded,
        error.UnknownConnection => err_unknown_connection_identifier,
        else => err_invalid_hci_command_parameters,
    };
}

// ---------------------------------------------------------------------------
// OpCode（OGF 0x08，[Vol 4] Part E §5.4.1）
// ---------------------------------------------------------------------------

/// LE Add Device To Resolving List。§7.8.38。
pub const op_le_add_device_to_resolving_list: u16 = hci.opcode(hci.ogf_le_controller, 0x0027);
/// LE Remove Device From Resolving List。§7.8.39。
pub const op_le_remove_device_from_resolving_list: u16 = hci.opcode(hci.ogf_le_controller, 0x0028);
/// LE Clear Resolving List。§7.8.40。
pub const op_le_clear_resolving_list: u16 = hci.opcode(hci.ogf_le_controller, 0x0029);
/// LE Read Resolving List Size。§7.8.41。
pub const op_le_read_resolving_list_size: u16 = hci.opcode(hci.ogf_le_controller, 0x002A);
/// LE Read Peer Resolvable Address。§7.8.42。
pub const op_le_read_peer_resolvable_address: u16 = hci.opcode(hci.ogf_le_controller, 0x002B);
/// LE Read Local Resolvable Address。§7.8.43。
pub const op_le_read_local_resolvable_address: u16 = hci.opcode(hci.ogf_le_controller, 0x002C);
/// LE Set Address Resolution Enable。§7.8.44。
pub const op_le_set_address_resolution_enable: u16 = hci.opcode(hci.ogf_le_controller, 0x002D);
/// LE Set Resolvable Private Address Timeout。§7.8.45。
pub const op_le_set_resolvable_private_address_timeout: u16 = hci.opcode(hci.ogf_le_controller, 0x002E);
/// LE Set Privacy Mode。§7.8.77。
pub const op_le_set_privacy_mode: u16 = hci.opcode(hci.ogf_le_controller, 0x004E);

// ---------------------------------------------------------------------------
// RPA_Timeout 的取值（§7.8.45）
// ---------------------------------------------------------------------------

/// RPA_Timeout 以**秒**为单位，0x0001–0x0E10（1 s 到 1 h）。
pub const rpa_timeout_min: u16 = 0x0001;
pub const rpa_timeout_max: u16 = 0x0E10;
/// 默认 0x0384（900 s，即 15 分钟）；[Vol 6] Part B §6.1 也推荐 15 分钟。
pub const rpa_timeout_default: u16 = 0x0384;

// ---------------------------------------------------------------------------
// 列表
// ---------------------------------------------------------------------------

/// Privacy_Mode。§7.8.77：0x00 网络隐私模式（默认），0x01 设备隐私模式。
pub const PrivacyMode = enum(u8) { network = 0x00, device = 0x01 };

/// Identity Address 与它的类型：公有地址，或静态随机地址（[Vol 6] Part B §1.3）。
pub const Identity = struct {
    addr_type: gap.Addr.Type = .public,
    addr: gap.Addr = .{},
};

/// 解析列表的一条记录：对端 Identity Address、Peer IRK、Local IRK（§7.8.38 的四个
/// 参数）加上这一条用的隐私模式（§7.8.77）。不适用的 IRK 为全 0（[Vol 3] Part C §10.7）。
pub const Entry = struct {
    peer_addr_type: gap.Addr.Type = .public,
    peer_addr: gap.Addr = .{},
    peer_irk: [16]u8 = @splat(0),
    local_irk: [16]u8 = @splat(0),
    privacy_mode: PrivacyMode = .network,
};

/// 用哪一个 IRK 去解析：对端发来的 RPA 用 Peer IRK；发给本端的 RPA（定向广播的
/// TargetA）用 Local IRK。[Vol 6] Part B §6.3、§6.4、§4.7。
pub const Key = enum { peer, local };

pub fn isZero(key: [16]u8) bool {
    return std.mem.allEqual(u8, &key, 0);
}

/// 一条记录里指定的那个 IRK。
pub fn irkOf(e: Entry, which: Key) [16]u8 {
    return switch (which) {
        .peer => e.peer_irk,
        .local => e.local_irk,
    };
}

/// 解析列表。`capacity` 是 controller 报的 Resolving_List_Size；存储是本结构里的定长
/// 数组，没有分配。条目按加入顺序排列，host 自己解析时也就按这个顺序逐个试 IRK。
pub fn List(comptime capacity: usize) type {
    return struct {
        count: u8 = 0,
        entries: [capacity]Entry = @splat(.{}),

        const Self = @This();

        comptime {
            // `count` 是 u8：Resolving_List_Size 本来就只有 1 字节（§7.8.41）。
            if (capacity > 255) @compileError("解析列表的容量最多 255（Resolving_List_Size 是 1 字节）");
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// 下标 `i` 处的记录。
        pub fn at(self: *const Self, i: usize) ?Entry {
            if (i >= self.count) return null;
            return self.entries[i];
        }

        /// 按 Identity Address 找。比较带上地址类型：类型不同就是不同的设备，即使
        /// 48 位相同（[Vol 6] Part B §1.3）。
        pub fn find(self: *const Self, id: Identity) ?usize {
            for (self.entries[0..self.count], 0..) |e, i| {
                if (id.addr_type == e.peer_addr_type and std.mem.eql(u8, &id.addr.bytes, &e.peer_addr.bytes)) return i;
            }
            return null;
        }

        /// 挂着这个**非零** Peer IRK 的记录。全 0 的 IRK 多条记录都可以有，不参与查找。
        pub fn findByPeerIrk(self: *const Self, irk: [16]u8) ?usize {
            if (isZero(irk)) return null;
            for (self.entries[0..self.count], 0..) |e, i| {
                if (std.mem.eql(u8, &e.peer_irk, &irk)) return i;
            }
            return null;
        }

        /// 加一条。拒绝的理由分五种，见 `ListError`。§7.8.38。
        ///
        /// 几条检查按原文的顺序判：先看地址合不合法，再看有没有空间，最后才看内容上
        /// 是不是重复或冲突——所以列表满了的时候，重复的条目也报 `ListFull`。
        pub fn add(self: *Self, e: Entry) ListError!void {
            // 随机类型的 Identity Address 必须是静态地址。
            if (e.peer_addr_type == .random and e.peer_addr.randomKind() != .static) return error.BadParam;
            // 没有空间：Memory Capacity Exceeded。
            if (self.count >= capacity) return error.ListFull;
            // 同一个 Identity Address 已在列表里：四个参数全同是重复，否则是冲突。
            for (self.entries[0..self.count]) |x| {
                if (x.peer_addr_type == e.peer_addr_type and std.mem.eql(u8, &x.peer_addr.bytes, &e.peer_addr.bytes)) {
                    if (std.mem.eql(u8, &x.peer_irk, &e.peer_irk) and std.mem.eql(u8, &x.local_irk, &e.local_irk)) {
                        return error.Duplicate;
                    }
                    return error.IdentityConflict;
                }
            }
            for (self.entries[0..self.count]) |x| {
                if (!isZero(e.peer_irk) and std.mem.eql(u8, &x.peer_irk, &e.peer_irk)) return error.IrkConflict;
            }
            // §7.8.38：“The added device shall be set to Network Privacy mode.”——
            // 调用方带来的 privacy_mode 不算数。
            var v = e;
            v.privacy_mode = .network;
            self.entries[self.count] = v;
            self.count += 1;
        }

        /// 按 Identity Address 删。找不到 → Unknown Connection Identifier。§7.8.39。
        /// 这一条的隐私模式随条目一起没了（§7.8.77）；之后的条目整体前移。
        pub fn remove(self: *Self, id: Identity) ListError!void {
            const i = self.find(id) orelse return error.UnknownConnection;
            const n: usize = self.count;
            std.mem.copyForwards(Entry, self.entries[i .. n - 1], self.entries[i + 1 .. n]);
            self.count -= 1;
            self.entries[n - 1] = .{};
        }

        /// 全部删除。§7.8.40。
        pub fn clear(self: *Self) void {
            self.count = 0;
            // IRK 是密钥，不留在内存里。
            self.entries = @splat(.{});
        }

        /// 设置某一条的隐私模式。不在列表里 → Unknown Connection Identifier。§7.8.77。
        pub fn setPrivacyMode(self: *Self, id: Identity, mode: PrivacyMode) ListError!void {
            const i = self.find(id) orelse return error.UnknownConnection;
            self.entries[i].privacy_mode = mode;
        }
    };
}

// ---------------------------------------------------------------------------
// HCI 命令
// ---------------------------------------------------------------------------

const add_param_len: usize = 1 + 6 + 16 + 16;
const identity_param_len: usize = 1 + 6;

/// Peer_Identity_Address_Type 取值表（§7.8.38）：只有 0x00（公有）和 0x01（静态随机）。
fn packIdentity(dst: *[identity_param_len]u8, addr_type: u8, addr: gap.Addr) Error!void {
    if (addr_type > 0x01) return error.BadParam;
    dst[0] = addr_type;
    @memcpy(dst[1..7], &addr.bytes);
}

/// LE Add Device To Resolving List：Peer_Identity_Address_Type(1) +
/// Peer_Identity_Address(6) + Peer_IRK(16) + Local_IRK(16)，共 39 字节。§7.8.38。
/// 地址类型随机时地址必须是静态地址（§7.8.38：“should return … 0x12”）。
pub fn cmdAddDeviceToResolvingList(out: []u8, addr_type: u8, addr: gap.Addr, peer_irk: [16]u8, local_irk: [16]u8) Error!usize {
    var p: [add_param_len]u8 = undefined;
    try packIdentity(p[0..identity_param_len], addr_type, addr);
    const t: gap.Addr.Type = @fromBackingInt(@intCast(addr_type));
    if (t == .random and addr.randomKind() != .static) return error.BadParam;
    @memcpy(p[7..23], &peer_irk);
    @memcpy(p[23..39], &local_irk);
    return hci.packCommand(out, op_le_add_device_to_resolving_list, &p);
}

/// LE Remove Device From Resolving List：类型(1) + 地址(6)。§7.8.39。
pub fn cmdRemoveDeviceFromResolvingList(out: []u8, addr_type: u8, addr: gap.Addr) Error!usize {
    var p: [identity_param_len]u8 = undefined;
    try packIdentity(&p, addr_type, addr);
    return hci.packCommand(out, op_le_remove_device_from_resolving_list, &p);
}

/// LE Clear Resolving List：无参数。§7.8.40。
pub fn cmdClearResolvingList(out: []u8) Error!usize {
    return hci.packCommand(out, op_le_clear_resolving_list, &.{});
}

/// LE Read Resolving List Size：无参数。§7.8.41。
pub fn cmdReadResolvingListSize(out: []u8) Error!usize {
    return hci.packCommand(out, op_le_read_resolving_list_size, &.{});
}

/// LE Read Peer Resolvable Address：类型(1) + 地址(6)。§7.8.42。
pub fn cmdReadPeerResolvableAddress(out: []u8, addr_type: u8, addr: gap.Addr) Error!usize {
    var p: [identity_param_len]u8 = undefined;
    try packIdentity(&p, addr_type, addr);
    return hci.packCommand(out, op_le_read_peer_resolvable_address, &p);
}

/// LE Read Local Resolvable Address：类型(1) + 地址(6)。§7.8.43。
pub fn cmdReadLocalResolvableAddress(out: []u8, addr_type: u8, addr: gap.Addr) Error!usize {
    var p: [identity_param_len]u8 = undefined;
    try packIdentity(&p, addr_type, addr);
    return hci.packCommand(out, op_le_read_local_resolvable_address, &p);
}

/// LE Set Address Resolution Enable：Address_Resolution_Enable(1)，0x00 关、0x01 开。§7.8.44。
pub fn cmdSetAddressResolutionEnable(out: []u8, enable: bool) Error!usize {
    return hci.packCommand(out, op_le_set_address_resolution_enable, &[_]u8{@intFromBool(enable)});
}

/// LE Set Resolvable Private Address Timeout：RPA_Timeout(2)，单位秒，范围
/// 0x0001–0x0E10；超出范围 → `BadParam`（controller 回 0x12）。§7.8.45。
pub fn cmdSetResolvablePrivateAddressTimeout(out: []u8, seconds: u16) Error!usize {
    var p: [2]u8 = undefined;
    std.mem.writeInt(u16, &p, try checkRpaTimeout(seconds), .little);
    return hci.packCommand(out, op_le_set_resolvable_private_address_timeout, &p);
}

fn checkRpaTimeout(seconds: u16) Error!u16 {
    if (seconds < rpa_timeout_min or seconds > rpa_timeout_max) return error.BadParam;
    return seconds;
}

/// LE Set Privacy Mode：类型(1) + 地址(6) + Privacy_Mode(1)。§7.8.77。
pub fn cmdSetPrivacyMode(out: []u8, addr_type: u8, addr: gap.Addr, mode: PrivacyMode) Error!usize {
    var p: [identity_param_len + 1]u8 = undefined;
    try packIdentity(p[0..identity_param_len], addr_type, addr);
    p[7] = @backingInt(mode);
    return hci.packCommand(out, op_le_set_privacy_mode, &p);
}

// ---------------------------------------------------------------------------
// 返回参数
// ---------------------------------------------------------------------------

fn need(ret: []const u8, n: usize) Error!void {
    if (ret.len < n) return error.Short;
    if (ret.len > n) return error.Trailing;
}

/// 失败时 controller 可以只回一个 Status；成功却只有 Status 是截断。与 `hci_cmd.zig`
/// 的 `parseReturn` 同一口径。
fn onlyFailure(ret: []const u8) ?u8 {
    if (ret.len == 1 and ret[0] != 0) return ret[0];
    return null;
}

/// LE Read Resolving List Size 的返回：Status + Resolving_List_Size(1)。§7.8.41。
pub const ResolvingListSize = struct { status: u8, size: u8 };

pub fn parseResolvingListSize(ret: []const u8) Error!ResolvingListSize {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .size = 0 };
    try need(ret, 2);
    return .{ .status = ret[0], .size = ret[1] };
}

/// LE Read Peer / Local Resolvable Address 的返回：Status + 6 字节地址。
/// §7.8.42、§7.8.43。
pub const ResolvableAddress = struct { status: u8, addr: gap.Addr };

pub fn parseResolvableAddress(ret: []const u8) Error!ResolvableAddress {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .addr = .{} };
    try need(ret, 7);
    return .{ .status = ret[0], .addr = .{ .bytes = ret[1..7].* } };
}

// ---------------------------------------------------------------------------
// 命令时机（host 侧的拦截）
// ---------------------------------------------------------------------------

/// host 对 controller 忙闲状态的镜像，用来在发命令之前拦住不该发的那几条。
///
/// §7.8.38–§7.8.40、§7.8.77：地址解析**已启用**且「广播（周期广播除外）已开、扫描已开、
/// 或 LE_Create_Connection 一类的命令还没完成」时不得改列表；§7.8.44：上面三种情况有
/// 一种在进行时不得改地址解析开关。原文只说 “shall not be used”，没说 controller 回
/// 什么状态码，所以这里是 host 自己不发，不是替 controller 猜错码。
pub const Ctl = struct {
    /// §7.8.44：默认 0x00（disabled）。
    resolution_enabled: bool = false,
    advertising: bool = false,
    scanning: bool = false,
    create_connection_pending: bool = false,

    fn busy(self: Ctl) bool {
        return self.advertising or self.scanning or self.create_connection_pending;
    }

    /// 改列表的命令（Add / Remove / Clear / Set Privacy Mode）之前调用。
    pub fn checkModifyList(self: Ctl) CtlError!void {
        if (self.resolution_enabled and self.busy()) return error.CommandDisallowed;
    }

    /// LE Set Address Resolution Enable 之前调用。与当前是否已启用无关。
    pub fn checkSetResolutionEnable(self: Ctl) CtlError!void {
        if (self.busy()) return error.CommandDisallowed;
    }

    /// 镜像一次成功的 LE Set Address Resolution Enable。重复设置没有效果（§7.8.44）。
    pub fn setResolutionEnable(self: *Ctl, enable: bool) CtlError!void {
        try self.checkSetResolutionEnable();
        self.resolution_enabled = enable;
    }
};

// ---------------------------------------------------------------------------
// 主机侧地址解析
// ---------------------------------------------------------------------------

/// 一次解析的结果。
pub const Outcome = union(enum) {
    /// 地址不是可解析私有地址：没有可解析的东西，一个 IRK 都不试
    /// （§1.3.2.3：“A non-resolvable private address cannot be resolved”）。
    not_resolvable,
    /// 解析成功，值是匹配的那一条的列表下标。
    resolved: usize,
    /// 列表里的 IRK 全试过了，没有匹配：这个地址不属于列表里的任何设备。
    not_found,
    /// 这次的预算用完，还有 IRK 没试到；结果未定，下次从这里继续。
    timed_out,
};

/// 逐个 IRK 解析一个 RPA 的扫描进度。[Vol 6] Part B §1.3.2.3：localHash = ah(IRK, prand)，
/// “repeats the above procedure for each stored IRK … until either address resolution is
/// successful for one of the IRKs or all have been tried”。
///
/// 试 IRK 要花时间，列表越长越久。同一节的小注：“A device that cannot resolve a private
/// address within T_IFS may respond on the reception of the next event”。所以解析可以分几次
/// 做：每次给一个 `budget`（这次最多试几个 IRK），没试完就返回 `timed_out`，进度留在
/// `Scan` 里，下次接着试；全试完没中才是 `not_found`——两者不能混为一谈，前者只是
/// 还没结论。换了一个地址要 `reset()`。
pub const Scan = struct {
    /// 下一个要试的列表下标。
    next: usize = 0,
    /// 到目前为止真正算过 ah 的次数。
    tried: usize = 0,

    pub fn reset(self: *Scan) void {
        self.* = .{};
    }

    pub fn scan(self: *Scan, list: anytype, which: Key, addr: gap.Addr, budget: usize) Outcome {
        if (addr.randomKind() != .resolvable_private) return .not_resolvable;
        const n = list.len();
        var left = budget;
        while (self.next < n) {
            const e = list.at(self.next).?;
            self.next += 1;
            const irk = irkOf(e, which);
            // 全 0 的 IRK 不参与解析（§4.7：那一侧用 Identity Address），也不占预算。
            if (isZero(irk)) continue;
            if (left == 0) {
                self.next -= 1;
                return .timed_out;
            }
            left -= 1;
            self.tried += 1;
            if (gap.resolve(addr, irk)) return .{ .resolved = self.next - 1 };
        }
        return .not_found;
    }
};

/// 一次把列表试完。解析成功返回列表下标，否则 null。
pub fn resolve(list: anytype, which: Key, addr: gap.Addr) ?usize {
    var s = Scan{};
    return switch (s.scan(list, which, addr, std.math.maxInt(usize))) {
        .resolved => |i| i,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// 两种隐私模式下的接受规则
// ---------------------------------------------------------------------------

/// 隐私规则对来包地址的裁决。
pub const Verdict = union(enum) {
    /// 是列表里某个对端的合法地址。后面按它的 Identity Address 交给过滤策略
    /// （[Vol 6] Part B §4.7）。`resolved` 为 true 表示这是解析出来的 RPA。
    accept: struct { index: usize, resolved: bool },
    /// 隐私规则明确不接受。
    reject,
    /// 隐私规则不表态：地址与列表无关、不是 RPA、或地址解析没开。由 Filter Accept
    /// List 的过滤策略决定。
    filter_policy,
};

/// 隐私规则裁决一个来包的地址。[Vol 6] Part B §4.7、§6.2.1、§6.3、§6.4；[Vol 3] Part C §10.7。
///
///   * 地址解析没开，或地址是不可解析私有地址：RPA 不被解析，只是个不认识的地址，
///     交给过滤策略；
///   * RPA 且解析开着：用 Peer IRK 逐个试，解析出来就接受，否则交给过滤策略；
///   * Identity Address（公有或静态随机）：不在列表里 → 交给过滤策略。在列表里则看那一条：
///       - Peer IRK 全 0：只接受它的 Identity Address；
///       - 设备隐私模式：Identity Address 与 RPA 都接受；
///       - 网络隐私模式：只接受 RPA，Identity Address 不接受。
pub fn filter(list: anytype, resolution_enabled: bool, addr_type: gap.Addr.Type, addr: gap.Addr) Verdict {
    const kind = addr.randomKind();
    if (addr_type == .random and kind == .resolvable_private) {
        if (!resolution_enabled) return .filter_policy;
        if (resolve(list, .peer, addr)) |i| return .{ .accept = .{ .index = i, .resolved = true } };
        return .filter_policy;
    }
    if (addr_type == .random and kind != .static) return .filter_policy;
    const i = list.find(.{ .addr_type = addr_type, .addr = addr }) orelse return .filter_policy;
    return switch (identityVerdict(list.at(i).?)) {
        true => .{ .accept = .{ .index = i, .resolved = false } },
        false => .reject,
    };
}

/// 列表里的一条记录是否接受对端直接用 Identity Address。§4.7、§6.5。
fn identityVerdict(e: Entry) bool {
    if (isZero(e.peer_irk)) return true;
    return e.privacy_mode == .device;
}

/// 解析成功后交给上层的对端地址：Identity Address，不是空中看到的那个 RPA
/// （§4.7：“the Address returned to the Host is the peer device’s Identity Address”）。
pub fn reportedAddress(list: anytype, v: Verdict) ?Identity {
    const a = switch (v) {
        .accept => |a| a,
        else => return null,
    };
    const e = list.at(a.index) orelse return null;
    return .{ .addr_type = e.peer_addr_type, .addr = e.peer_addr };
}

/// 定向广播的目标地址（TargetA）：对端 IRK 可用就用它生成 RPA；对端 IRK 全 0 就用
/// 对端的 Identity Address。[Vol 6] Part B §6.2.2、§6.2.5；全 0 Peer IRK 的那一半
/// §4.7 也写了（“the peer address … shall use the peer’s Identity Address”）。
pub fn targetAddress(e: Entry, prand: [3]u8) Error!Identity {
    if (isZero(e.peer_irk)) return .{ .addr_type = e.peer_addr_type, .addr = e.peer_addr };
    return .{ .addr_type = .random, .addr = try rpa(e.peer_irk, prand) };
}

fn rpa(irk: [16]u8, prand: [3]u8) Error!gap.Addr {
    // `generateRpa` 实际只会因为 prand 不合规而失败。
    return gap.generateRpa(irk, prand) catch return error.BadParam;
}

// ---------------------------------------------------------------------------
// 本端 RPA 的定时更新
// ---------------------------------------------------------------------------

/// RPA_Timeout 的定时器（§7.8.45；[Vol 6] Part B §6.1：“A new resolvable private address
/// shall be generated when the timer expires”）。时间用调用方给的秒计数；相减按回绕
/// 算，计数器回绕也不会误判。
pub const RpaTimer = struct {
    timeout_s: u16 = rpa_timeout_default,
    armed: bool = false,
    /// 当前这个地址是什么时候开始用的。
    started_s: u32 = 0,

    /// 设置超时，单位秒，范围 `rpa_timeout_min`–`rpa_timeout_max`。定时器正在走的时候
    /// 从 `now_s` 重新计时（与 NimBLE 的 `ble_hs_resolv_set_rpa_tmo` 一致：
    /// ble_hs_resolv.c:1054 在解析已启用时重置 callout）。
    pub fn setTimeout(self: *RpaTimer, seconds: u16, now_s: u32) Error!void {
        self.timeout_s = try checkRpaTimeout(seconds);
        if (self.armed) self.started_s = now_s;
    }

    /// 一个新地址从 `now_s` 开始使用，定时器从头走。
    pub fn restart(self: *RpaTimer, now_s: u32) void {
        self.armed = true;
        self.started_s = now_s;
    }

    pub fn stop(self: *RpaTimer) void {
        self.armed = false;
    }

    /// 已经过了多久（秒）。
    pub fn elapsed(self: RpaTimer, now_s: u32) u32 {
        if (!self.armed) return 0;
        return now_s -% self.started_s;
    }

    /// 到期了没有。满 `timeout_s` 秒整算到期；没有在计时的定时器永不到期。
    pub fn expired(self: RpaTimer, now_s: u32) bool {
        return self.armed and self.elapsed(now_s) >= self.timeout_s;
    }
};

/// 本端的私有地址。Local IRK 全 0 时不生成 RPA，对外一律用 Identity Address
/// （§4.7、§6.5：“the Controller will use the Identity Address”）。
pub const LocalRpa = struct {
    irk: [16]u8 = @splat(0),
    addr: gap.Addr = .{},
    timer: RpaTimer = .{},
    /// 到目前为止换过几次地址。
    changes: u32 = 0,

    /// 现在该用的本地地址。
    pub fn address(self: *const LocalRpa, identity: Identity) Identity {
        if (isZero(self.irk)) return identity;
        return .{ .addr_type = .random, .addr = self.addr };
    }

    /// 定时器到期，该换地址了。Local IRK 全 0 的设备没有 RPA 可换。
    pub fn needsNewAddress(self: *const LocalRpa, now_s: u32) bool {
        return !isZero(self.irk) and self.timer.expired(now_s);
    }

    /// 生成一个新的本地 RPA 并从 `now_s` 起重新计时。两个触发点都落到这里：定时器
    /// 到期（§6.1）；对端地址解析成功但加密失败时立即丢弃当前 RPA（§4.7）。
    /// `prand` 的随机性由调用方提供。
    pub fn regenerate(self: *LocalRpa, prand: [3]u8, now_s: u32) Error!void {
        if (isZero(self.irk)) return error.BadParam;
        self.addr = try rpa(self.irk, prand);
        self.timer.restart(now_s);
        self.changes += 1;
    }
};
