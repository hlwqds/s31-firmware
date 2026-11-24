//! ble-802154：ATT 服务端——属性表、请求分发、排队写、通知与指示。
//!
//! 规范出处（Bluetooth Core Specification v5.4，[Vol 3] Part F）：
//!   * 属性句柄唯一、非零、按句柄有序 —— §3.2.2；
//!   * 权限与安全要求对应的错误码 —— §3.2.5；检查顺序 —— §4（认证与授权先于其它检查）；
//!   * 长属性与 Read Blob、排队写 —— §3.2.9；
//!   * server 对未知请求、非法请求的统一应答，命令不出错应答 —— §3.3、§3.4.1.1；
//!   * 事务与 30 秒超时 —— §3.3.3；
//!   * 各请求的处理规则与出错句柄 —— §3.4.2–§3.4.7，允许的错误码见 §3.4.9 表 3.44；
//!   * 签名写的验签 —— §3.4.5.4，算法在 `cmac.zig`；
//!   * 哪些属性类型是分组类型、一个组到哪里结束 —— [Vol 3] Part G §2.5.3、§3.1、§3.3。
//!
//! 两个对象，都不用分配器：
//!
//!   * `Db(N, V)`：server 的属性表，最多 N 个属性、每个值最多 V 字节，句柄升序。
//!     值可以变长（`max_len` 是上限）也可以定长（§3.4.5.1 对两种的写语义不同）。
//!   * `Db(N, V).Peer(Q)`：一个 client 在这条 ATT bearer 上的状态——生效的 ATT_MTU、
//!     链路的安全状态、按 client 保存的值（槽位）、排队写队列、等确认的指示。
//!     `onPdu()` 吃一个 PDU、吐应答；`notify()` / `indicate()` 是 server 发起的那一半。
//!
//! 属性表由所有 client 共享；槽位（slot）是按 client 保存的值：属性标了槽位号之后，
//! 它的值读写都落在当前 `Peer` 的那个槽里。GATT 的 Client Characteristic Configuration
//! 这类「每个 client 一份」的描述符靠它实现（见 `gatt_server.zig`）。
//!
//! 本文件不做的事：
//!
//!   * 不记时间。指示的 30 秒超时由调用方把当前毫秒数传给 `tick()`；
//!   * 不持久化。断链后排队写的队列清空、不执行（§3.4.6）；槽位在 `reset()` 里回到
//!     默认值（[Vol 3] Part G §3.3.3.3：非绑定设备每次连接都是默认值）。绑定设备的
//!     持久化是上层的事；
//!   * 属性值的业务校验（「值不合法」的应用错误）通过可选的 `Validate` 钩子交给上层；
//!     ATT 只管句柄、权限、尺寸。
//!
//! 规范留了余地、这里定下来的几处（逐条见 README 的「实现偏离」）：
//!
//!   * Read Blob 读定长短属性时不回 Attribute Not Long（§3.4.4.5 写的是 may）；
//!   * ATT_EXECUTE_WRITE_REQ 的 Flags 不是 0x00 / 0x01 → Invalid PDU；
//!   * 排队写的部分值长过属性表的值上限 V → Prepare Queue Full（§3.4.6.1：没有空间
//!     排队就回 0x09；尺寸与偏移的校验照规范留到 Execute）；
//!   * Execute 时遇到 Invalid Offset / Invalid Attribute Value Length，出错句柄取队列里
//!     出问题的那条的句柄（规范只对应用错误写明了这一点）。

const std = @import("std");
const att = @import("att.zig");
const cmac = @import("cmac.zig");

/// 事务超时：[Vol 3] Part F §3.3.3，30 秒。超时的 bearer 上不再收发任何 ATT PDU。
pub const transaction_timeout_ms: u32 = 30_000;

pub const Error = att.Error || error{
    /// 这条 bearer 上有事务超时过（§3.3.3），收发一律拒绝，直到 `reset()`。
    BearerClosed,
    /// 上一条指示还没收到确认，不能再发（§3.4.7.2）。
    IndicationPending,
    /// 通知 / 指示的句柄在属性表里不存在。
    InvalidHandle,
    /// 通知 / 指示要求链路已认证，而当前没有（§3.2.5）。
    InsufficientAuthentication,
};

pub const AddError = error{
    /// 属性表已满，或句柄用尽（0xFFFF 已被占用）。
    TableFull,
    /// 显式给的句柄是 0 或不大于上一个属性的句柄（§3.2.2：唯一、非零、有序）。
    Unordered,
    /// 初值或最大长度超过属性表的值上限（或槽位的上限）。
    TooLong,
    /// 槽位号超出 `slot_count`。
    BadSlot,
};

/// 链路的安全状态（[Vol 3] Part F §3.2.5）。由上层（SMP / GAP）维护，这里只读。
pub const Security = struct {
    encrypted: bool = false,
    /// 加密密钥的字节数；未加密时无意义。
    key_size: u8 = 0,
    authenticated: bool = false,
    /// 应用层授权（GAP 的授权过程通过）。
    authorized: bool = false,
};

/// 一个属性的访问权限与安全要求。读和写分开：同一个属性可以「读不加密、写要认证」。
pub const Perm = struct {
    read: bool = false,
    write: bool = false,
    read_enc: bool = false,
    read_auth: bool = false,
    read_authz: bool = false,
    write_enc: bool = false,
    write_auth: bool = false,
    write_authz: bool = false,
    /// 要求加密时密钥至少要有这么多字节。7 是 LE 密钥长度的下限，默认值不会误拒。
    min_key_size: u8 = 7,
    /// 发通知或指示之前要求链路已认证（§3.2.5）。
    ntf_auth: bool = false,
};

/// 上层的值校验钩子：写入之前调用，`current` 是现在的值、`incoming` 是要写进来的值。
/// 返回 ATT 错误码表示拒绝（值不变），null 表示接受。
pub const Validate = *const fn (current: []const u8, incoming: []const u8, arg: u16) ?u8;

/// 属性不用槽位。
pub const no_slot: u8 = 0xFF;
/// 一个槽位能放的字节数。按 client 保存的值在本组件里都很短（CCCD 2 字节）。
pub const slot_max: usize = 16;
/// 每个 client 的槽位数。
pub const slot_count: usize = 8;

/// GATT 定义的分组类型（[Vol 3] Part G §2.5.3、表 3.17）。
pub const uuid_primary_service: u16 = 0x2800;
pub const uuid_secondary_service: u16 = 0x2801;
pub const uuid_include: u16 = 0x2802;
pub const uuid_characteristic: u16 = 0x2803;

pub const Group = enum {
    /// 不是分组类型。
    none,
    /// «Primary Service» / «Secondary Service»：到下一条服务声明之前结束（Part G §3.1）。
    service,
    /// «Characteristic»：到下一条特征声明或服务声明之前结束（Part G §3.3）。
    characteristic,
};

pub fn groupOf(t: att.Uuid) Group {
    const v = t.asU16() orelse return .none;
    return switch (v) {
        uuid_primary_service, uuid_secondary_service => .service,
        uuid_characteristic => .characteristic,
        else => .none,
    };
}

/// 属性表与每 client 状态。`max_attrs` 是属性数上限，`value_max` 是每个值的字节数上限
/// （不超过 512，[Vol 3] Part F §3.2.9）。
pub fn Db(comptime max_attrs: usize, comptime value_max: usize) type {
    if (value_max == 0 or value_max > att.value_max) @compileError("value_max 必须在 1..512");
    return struct {
        const Self = @This();

        pub const capacity: usize = max_attrs;
        pub const value_limit: usize = value_max;

        pub const Attr = struct {
            handle: u16 = 0,
            type: att.Uuid = .{ .u16 = 0 },
            perm: Perm = .{},
            /// 当前值的长度。
            len: u16 = 0,
            /// 值的最大合法长度。定长属性的长度恒等于它。
            max_len: u16 = 0,
            /// 定长：写进来的值短于它时只覆盖前一段，其余不变（§3.4.5.1）。
            fixed: bool = false,
            /// 不是 `no_slot` 时，值不放在本属性里，而在当前 client 的这个槽位里。
            slot: u8 = no_slot,
            validate: ?Validate = null,
            validate_arg: u16 = 0,
            value: [value_max]u8 = undefined,
        };

        /// `add()` 的入参。
        pub const New = struct {
            type: att.Uuid,
            value: []const u8 = &.{},
            fixed: bool = false,
            /// 变长时的最大合法长度；0 表示等于初值长度。定长时忽略：长度恒等于初值长度。
            max_len: u16 = 0,
            perm: Perm = .{},
            /// 省略时接在最后一个属性之后，从 0x0001 起。
            handle: ?u16 = null,
            slot: u8 = no_slot,
            validate: ?Validate = null,
            validate_arg: u16 = 0,
        };

        attrs: [max_attrs]Attr = undefined,
        count: u16 = 0,
        next_handle: u16 = 0x0001,
        rejected: u32 = 0,

        pub fn reset(self: *Self) void {
            self.count = 0;
            self.next_handle = 0x0001;
            self.rejected = 0;
        }

        /// 按句柄升序的全部属性。
        pub fn list(self: *Self) []Attr {
            return self.attrs[0..self.count];
        }

        pub fn find(self: *Self, handle: u16) ?*Attr {
            for (self.list()) |*a| {
                if (a.handle == handle) return a;
                if (a.handle > handle) break;
            }
            return null;
        }

        /// 句柄为 `handle` 的属性在表里的下标。
        pub fn indexOf(self: *const Self, handle: u16) ?usize {
            for (self.attrs[0..self.count], 0..) |a, i| {
                if (a.handle == handle) return i;
                if (a.handle > handle) break;
            }
            return null;
        }

        /// 加一个属性，返回它的句柄。失败时表不变，`rejected` 加一。
        pub fn add(self: *Self, n: New) AddError!u16 {
            errdefer self.rejected += 1;
            const handle = n.handle orelse self.next_handle;
            if (self.count >= max_attrs or handle == 0) return error.TableFull;
            if (self.count > 0 and handle <= self.attrs[self.count - 1].handle) return error.Unordered;
            const max_len: usize = if (n.max_len == 0 or n.fixed) n.value.len else n.max_len;
            if (n.value.len > max_len) return error.TooLong;
            if (max_len > value_max or (n.slot != no_slot and max_len > slot_max)) return error.TooLong;
            if (n.slot != no_slot and n.slot >= slot_count) return error.BadSlot;

            self.attrs[self.count] = .{
                .handle = handle,
                .type = n.type,
                .perm = n.perm,
                .len = @intCast(n.value.len),
                .max_len = @intCast(max_len),
                .fixed = n.fixed,
                .slot = n.slot,
                .validate = n.validate,
                .validate_arg = n.validate_arg,
            };
            @memcpy(self.attrs[self.count].value[0..n.value.len], n.value);
            self.count += 1;
            self.next_handle = if (handle == 0xFFFF) 0 else handle + 1;
            return handle;
        }

        /// 以第 `i` 个属性为头的组，最后一个属性的下标。不是分组类型时就是 `i` 自己。
        pub fn groupLast(self: *const Self, i: usize) usize {
            const head = groupOf(self.attrs[i].type);
            if (head == .none) return i;
            var j = i + 1;
            while (j < self.count) : (j += 1) {
                const k = groupOf(self.attrs[j].type);
                const ends = if (head == .service) k == .service else k != .none;
                if (ends) break;
            }
            return j - 1;
        }

        /// 以第 `i` 个属性为头的组的组尾句柄：组内最后一个属性的句柄。
        pub fn groupEnd(self: *const Self, i: usize) u16 {
            return self.attrs[self.groupLast(i)].handle;
        }

        /// ---------------------------------------------------------------------
        /// 一个 client 在这条 bearer 上的状态
        /// ---------------------------------------------------------------------
        /// `queue_len` 是这个 client 能同时排队的 Prepare Write 条数（§3.4.6.1：server
        /// 可以限制这个数）。
        pub fn Peer(comptime queue_len: usize) type {
            if (queue_len == 0 or queue_len > 255) @compileError("queue_len 必须在 1..255");
            return struct {
                const P = @This();

                pub const queue_capacity: usize = queue_len;

                pub const Prep = struct {
                    handle: u16,
                    offset: u16,
                    len: u16,
                    value: [value_max]u8 = undefined,
                };

                /// 一个按 client 保存的值。`set` 为 false 表示这个 client 还没写过：值就是
                /// 属性自己的默认值（[Vol 3] Part G §3.3.3.3：非绑定设备每次连接都从默认值开始）。
                pub const Slot = struct { set: bool = false, len: u8 = 0, data: [slot_max]u8 = @splat(0) };

                pub const Stats = struct {
                    requests: u32 = 0,
                    commands: u32 = 0,
                    ignored: u32 = 0,
                    errors: u32 = 0,
                    prep_writes: u32 = 0,
                    executes: u32 = 0,
                    cancels: u32 = 0,
                    signed_writes: u32 = 0,
                    rejected_signatures: u32 = 0,
                    timeouts: u32 = 0,
                    notifications: u32 = 0,
                    indications: u32 = 0,
                };

                /// 生效的 ATT_MTU。交换之前是默认值 23。
                mtu: u16 = att.default_mtu,
                /// 本端能接收的最大 ATT PDU，即 ATT_EXCHANGE_MTU_RSP 里回的 Server Rx MTU。
                server_rx_mtu: u16 = att.max_mtu,
                mtu_exchanged: bool = false,
                security: Security = .{},
                slots: [slot_count]Slot = @splat(.{}),
                queue: [queue_len]Prep = undefined,
                queued: u8 = 0,
                indicating: bool = false,
                indicate_at_ms: u32 = 0,
                dead: bool = false,
                /// 对端（client）的 CSRK：有它才验 ATT_SIGNED_WRITE_CMD。由上层从绑定
                /// 信息里取出来放进来。
                csrk: ?[16]u8 = null,
                /// 最近一次验签通过的 SignCounter（[Vol 3] Part H §2.4.5，防重放）。
                sign_counter: u32 = 0,
                att: att.Stats = .{},
                stats: Stats = .{},

                /// 断链或新连接：ATT_MTU 回到默认值，排队写清空且不执行（§3.4.6），
                /// 未确认的指示作废，按 client 保存的值回到默认值（[Vol 3] Part G
                /// §3.3.3.3）。CSRK 与 SignCounter 属于安全数据库，不动。
                pub fn reset(self: *P) void {
                    self.mtu = att.default_mtu;
                    self.mtu_exchanged = false;
                    self.security = .{};
                    self.slots = @splat(.{});
                    self.queued = 0;
                    self.indicating = false;
                    self.dead = false;
                }

                /// 槽位 `idx` 里值的前两个字节，按小端读成 16 位整数（CCCD 的配置位）。
                /// 这个 client 还没写过时是 0。
                pub fn slotU16(self: *const P, idx: u8) u16 {
                    const s = &self.slots[idx];
                    if (!s.set) return 0;
                    return @as(u16, s.data[0]) | (@as(u16, s.data[1]) << 8);
                }

                fn fail(self: *P, out: []u8, req_op: u8, handle: u16, code: att.Code) Error!usize {
                    return self.failRaw(out, req_op, handle, @backingInt(code));
                }

                fn failRaw(self: *P, out: []u8, req_op: u8, handle: u16, code: u8) Error!usize {
                    self.stats.errors += 1;
                    return att.encodeErrorRaw(out, req_op, handle, code, &self.att);
                }

                /// 解析失败或超长的 PDU。§3.3：不支持的请求回 Request Not Supported，非法
                /// 请求回 Invalid PDU，两者句柄都是 0x0000；命令一律不应答。
                fn onBad(self: *P, e: att.Error, pdu: []const u8, out: []u8) Error!usize {
                    if ((pdu[0] & 0x40) != 0) {
                        self.stats.ignored += 1;
                        return 0;
                    }
                    return switch (e) {
                        error.UnsupportedOp => self.fail(out, pdu[0], 0, .request_not_supported),
                        else => self.fail(out, pdu[0], 0, .invalid_pdu),
                    };
                }

                /// 处理对端发来的一个 PDU。应答写进 `out` 并返回它的长度；返回 0 表示没有
                /// 应答（命令、响应、通知等）。Zig 错误只留给本地故障（见 `Error`）；
                /// 协议层面的出错都体现为一条 ATT_ERROR_RSP。
                pub fn onPdu(self: *P, db: *Self, pdu: []const u8, out: []u8) Error!usize {
                    if (self.dead) return error.BearerClosed;
                    if (pdu.len == 0) return 0;
                    if (pdu.len > self.mtu) return self.onBad(error.Trailing, pdu, out);
                    const p = att.parse(pdu, &self.att) catch |e| return self.onBad(e, pdu, out);
                    const op = att.Op.fromByte(pdu[0]) orelse return self.onBad(error.UnsupportedOp, pdu, out);
                    if (op.kind() == .request) self.stats.requests += 1;

                    switch (p) {
                        .mtu_req => |client_mtu| return self.onMtu(client_mtu, out),
                        .find_info_req => |r| return self.onFindInfo(db, r, out),
                        .find_by_type_req => |req| return self.onFindByType(db, req, out),
                        .read_by_type_req => |req| return self.onReadByType(db, req, out),
                        .read_req => |h| return self.onRead(db, h, out),
                        .read_blob_req => |req| return self.onReadBlob(db, req, out),
                        .read_multiple_req => |hs| return self.onReadMultiple(db, hs, out),
                        .read_multiple_var_req => |hs| return self.onReadMultipleVar(db, hs, out),
                        .read_by_group_req => |req| return self.onReadByGroup(db, req, out),
                        .write_req => |w| return self.onWrite(db, w, out),
                        .prepare_write_req => |part| return self.onPrepareWrite(db, part, out),
                        .execute_write_req => |flags| return self.onExecuteWrite(db, flags, out),
                        .write_cmd => |w| {
                            self.stats.commands += 1;
                            _ = self.writeAttr(db, w.handle, w.value);
                            return 0;
                        },
                        .signed_write_cmd => |sw| return self.onSignedWrite(db, pdu, sw),
                        .confirm => {
                            self.indicating = false;
                            return 0;
                        },
                        // 响应、通知、指示不是发给 server 的，丢弃。
                        else => {
                            self.stats.ignored += 1;
                            return 0;
                        },
                    }
                }

                /// ATT_EXCHANGE_MTU_REQ。§3.4.2.2：回本端能收的最大值；任一端错误地小于
                /// 默认值时 ATT_MTU 不变，仍是默认值。
                fn onMtu(self: *P, client_mtu: u16, out: []u8) Error!usize {
                    self.mtu = att.effectiveMtu(client_mtu, self.server_rx_mtu);
                    self.mtu_exchanged = true;
                    return att.encodeMtuRsp(out, self.server_rx_mtu, &self.att);
                }

                /// §3.4.3.1 等：起始句柄为 0 或大于结束句柄 → Invalid Handle，出错句柄是起始句柄。
                fn rangeOk(r: att.Range) bool {
                    return r.start != 0 and r.start <= r.end;
                }

                /// ATT_FIND_INFORMATION_REQ。§4：这个请求永远允许，不看权限。
                fn onFindInfo(self: *P, db: *Self, r: att.Range, out: []u8) Error!usize {
                    if (!rangeOk(r)) return self.fail(out, @backingInt(att.Op.find_info_req), r.start, .invalid_handle);
                    var b = try att.InfoBuilder.init(out, self.mtu, &self.att);
                    for (db.list()) |*a| {
                        if (a.handle < r.start) continue;
                        if (a.handle > r.end) break;
                        if (!b.add(a.handle, a.type)) break;
                    }
                    const n = b.len();
                    if (n == 0) return self.fail(out, @backingInt(att.Op.find_info_req), r.start, .attribute_not_found);
                    return n;
                }

                /// ATT_FIND_BY_TYPE_VALUE_REQ。§3.4.3.3：范围内类型与值都相同、且有读权限的
                /// 属性才会被返回；值按长度与二进制内容比较。
                fn onFindByType(self: *P, db: *Self, req: att.FindTypeValue, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.find_by_type_req);
                    if (!rangeOk(req.range)) return self.fail(out, op, req.range.start, .invalid_handle);
                    var b = try att.HandleRangeBuilder.init(out, self.mtu);
                    for (db.list(), 0..) |*a, i| {
                        if (a.handle < req.range.start) continue;
                        if (a.handle > req.range.end) break;
                        if (!a.type.eql(.{ .u16 = req.attr_type })) continue;
                        if (self.readPerm(a) != null) continue;
                        if (!std.mem.eql(u8, self.valueOf(a), req.value)) continue;
                        if (!b.add(a.handle, db.groupEnd(i))) break;
                    }
                    const n = b.len();
                    if (n == 0) return self.fail(out, op, req.range.start, .attribute_not_found);
                    return n;
                }

                /// ATT_READ_BY_TYPE_REQ。§3.4.4.1：第一条就出错 → 不考虑其余属性；后面的
                /// 出错 → 返回它之前的。
                fn onReadByType(self: *P, db: *Self, req: att.TypeReq, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.read_by_type_req);
                    if (!rangeOk(req.range)) return self.fail(out, op, req.range.start, .invalid_handle);
                    var b = try att.TypeBuilder.init(out, self.mtu, &self.att);
                    var first = true;
                    for (db.list()) |*a| {
                        if (a.handle < req.range.start) continue;
                        if (a.handle > req.range.end) break;
                        if (!a.type.eql(req.uuid)) continue;
                        if (self.readPerm(a)) |code| {
                            if (first) return self.fail(out, op, a.handle, code);
                            break;
                        }
                        first = false;
                        if (!b.add(a.handle, self.valueOf(a))) break;
                    }
                    const n = b.len();
                    if (n == 0) return self.fail(out, op, req.range.start, .attribute_not_found);
                    return n;
                }

                fn onRead(self: *P, db: *Self, attr_handle: u16, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.read_req);
                    const a = db.find(attr_handle) orelse return self.fail(out, op, attr_handle, .invalid_handle);
                    if (self.readPerm(a)) |code| return self.fail(out, op, attr_handle, code);
                    return att.encodeReadRsp(out, self.valueOf(a), self.mtu, &self.att);
                }

                /// ATT_READ_BLOB_REQ。§3.4.4.5：偏移大于值的长度 → Invalid Offset；等于长度
                /// 时回空值。
                fn onReadBlob(self: *P, db: *Self, req: att.BlobReq, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.read_blob_req);
                    const a = db.find(req.handle) orelse return self.fail(out, op, req.handle, .invalid_handle);
                    if (self.readPerm(a)) |code| return self.fail(out, op, req.handle, code);
                    const value = self.valueOf(a);
                    if (req.offset > value.len) return self.fail(out, op, req.handle, .invalid_offset);
                    return att.encodeReadBlobRsp(out, value[req.offset..], self.mtu, &self.att);
                }

                /// ATT_READ_MULTIPLE_REQ。§3.4.4.7：出错句柄是第一个出错的属性；值首尾相接，
                /// 整体截到 ATT_MTU−1。
                fn onReadMultiple(self: *P, db: *Self, handles: att.Handles, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.read_multiple_req);
                    if (handles.count() < 2) return self.fail(out, op, 0, .invalid_pdu);
                    const limit = @min(@as(usize, self.mtu), out.len);
                    if (limit < 1) return error.NoSpace;
                    out[0] = @backingInt(att.Op.read_multiple_rsp);
                    var pos: usize = 1;
                    for (0..handles.count()) |i| {
                        const h = handles.at(i);
                        const a = db.find(h) orelse return self.fail(out, op, h, .invalid_handle);
                        if (self.readPerm(a)) |code| return self.fail(out, op, h, code);
                        const v = self.valueOf(a);
                        const n = @min(v.len, limit - pos);
                        @memcpy(out[pos..][0..n], v[0..n]);
                        pos += n;
                        if (n < v.len) {
                            self.att.truncated += 1;
                            break;
                        }
                    }
                    self.att.reads += 1;
                    return pos;
                }

                /// ATT_READ_MULTIPLE_VARIABLE_REQ。§3.4.4.11：所有句柄都得合法、可读才会应答。
                fn onReadMultipleVar(self: *P, db: *Self, handles: att.Handles, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.read_multiple_var_req);
                    if (handles.count() < 2) return self.fail(out, op, 0, .invalid_pdu);
                    for (0..handles.count()) |i| {
                        const h = handles.at(i);
                        const a = db.find(h) orelse return self.fail(out, op, h, .invalid_handle);
                        if (self.readPerm(a)) |code| return self.fail(out, op, h, code);
                    }
                    var b = try att.VarBuilder.init(out, self.mtu, &self.att);
                    for (0..handles.count()) |i| _ = b.add(self.valueOf(db.find(handles.at(i)).?));
                    self.att.reads += 1;
                    return b.len();
                }

                /// ATT_READ_BY_GROUP_TYPE_REQ。§3.4.4.9：不是受支持的分组类型 → Unsupported
                /// Group Type。[Vol 3] Part G §2.5.3：只有 «Primary Service» 与
                /// «Secondary Service» 能用在这里。
                fn onReadByGroup(self: *P, db: *Self, req: att.TypeReq, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.read_by_group_req);
                    if (!rangeOk(req.range)) return self.fail(out, op, req.range.start, .invalid_handle);
                    if (groupOf(req.uuid) != .service) return self.fail(out, op, req.range.start, .unsupported_group_type);
                    var b = try att.GroupBuilder.init(out, self.mtu, &self.att);
                    var first = true;
                    var i: usize = 0;
                    while (i < db.count) : (i += 1) {
                        const a = &db.attrs[i];
                        if (a.handle < req.range.start) continue;
                        if (a.handle > req.range.end) break;
                        if (!a.type.eql(req.uuid)) continue;
                        if (self.readPerm(a)) |code| {
                            if (first) return self.fail(out, op, a.handle, code);
                            break;
                        }
                        first = false;
                        const last = db.groupLast(i);
                        if (!b.add(a.handle, db.attrs[last].handle, self.valueOf(a))) break;
                        i = last;
                    }
                    const n = b.len();
                    if (n == 0) return self.fail(out, op, req.range.start, .attribute_not_found);
                    return n;
                }

                fn onWrite(self: *P, db: *Self, w: att.WriteReq, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.write_req);
                    if (self.writeAttr(db, w.handle, w.value)) |code| return self.failRaw(out, op, w.handle, code);
                    return att.encodeWriteRsp(out, &self.att);
                }

                /// 写请求与写命令共用的写入。返回 null 表示已写入，否则是 ATT 错误码，值不变。
                fn writeAttr(self: *P, db: *Self, handle: u16, data: []const u8) ?u8 {
                    const a = db.find(handle) orelse return @backingInt(att.Code.invalid_handle);
                    if (self.writePerm(a)) |code| return @backingInt(code);
                    return self.store(a, data);
                }

                /// §3.4.5.1 的写语义：尺寸 → 上层校验 → 落盘。变长属性截断或加长到新值的
                /// 长度；定长属性只覆盖前一段。
                fn store(self: *P, a: *Attr, data: []const u8) ?u8 {
                    if (data.len > a.max_len) return @backingInt(att.Code.invalid_value_length);
                    if (a.validate) |f| {
                        if (f(self.valueOf(a), data, a.validate_arg)) |code| return code;
                    }
                    const dst = self.storeOf(a);
                    @memcpy(dst[0..data.len], data);
                    if (!a.fixed) self.setLen(a, data.len);
                    return null;
                }

                /// ATT_PREPARE_WRITE_REQ。§3.4.6.1：句柄、写权限、队列空间在这一步查；值的
                /// 尺寸与偏移留到 Execute。应答复述请求里的句柄、偏移与部分值。
                fn onPrepareWrite(self: *P, db: *Self, part: att.Part, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.prepare_write_req);
                    const a = db.find(part.handle) orelse return self.fail(out, op, part.handle, .invalid_handle);
                    if (self.writePerm(a)) |code| return self.fail(out, op, part.handle, code);
                    // 部分值长过属性表的值上限，队列里没有地方放它。
                    if (self.queued >= queue_len or part.value.len > value_max) {
                        return self.fail(out, op, part.handle, .prepare_queue_full);
                    }
                    const e = &self.queue[self.queued];
                    e.handle = part.handle;
                    e.offset = part.offset;
                    e.len = @intCast(part.value.len);
                    @memcpy(e.value[0..part.value.len], part.value);
                    self.queued += 1;
                    self.stats.prep_writes += 1;
                    return att.encodePrepareWrite(.prepare_write_rsp, out, part, self.mtu, &self.att);
                }

                /// 执行后各属性的长度：校验时用来按「前面的排队写已生效」的状态往后推。
                const Sim = struct { handle: u16, len: u32 };

                fn simLen(db: *Self, peer: *P, sims: []const Sim, handle: u16) u32 {
                    for (sims) |s| {
                        if (s.handle == handle) return s.len;
                    }
                    return @intCast(peer.valueOf(db.find(handle).?).len);
                }

                /// ATT_EXECUTE_WRITE_REQ。§3.4.6.3：取消 → 丢弃队列；执行 → 按接收顺序写。
                /// 任何一条的偏移或尺寸不合法，整个队列丢弃、什么都不写。
                fn onExecuteWrite(self: *P, db: *Self, flags: att.ExecuteFlags, out: []u8) Error!usize {
                    const op = @backingInt(att.Op.execute_write_req);
                    defer self.queued = 0;
                    if (flags == .cancel) {
                        self.stats.cancels += 1;
                        return att.encodeExecuteWriteRsp(out, &self.att);
                    }
                    self.stats.executes += 1;

                    var sims: [queue_len]Sim = undefined;
                    var used: usize = 0;
                    for (self.queue[0..self.queued]) |*e| {
                        const a = db.find(e.handle) orelse return self.fail(out, op, e.handle, .invalid_handle);
                        const cur = simLen(db, self, sims[0..used], e.handle);
                        if (e.offset > cur) return self.fail(out, op, e.handle, .invalid_offset);
                        const end = @as(u32, e.offset) + e.len;
                        if (end > a.max_len) return self.fail(out, op, e.handle, .invalid_value_length);
                        var known = false;
                        for (sims[0..used]) |*s| {
                            if (s.handle == e.handle) {
                                s.len = @max(s.len, end);
                                known = true;
                            }
                        }
                        if (!known) {
                            sims[used] = .{ .handle = e.handle, .len = @max(cur, end) };
                            used += 1;
                        }
                    }
                    // 上层校验（§3.4.6.3：写不进去是应用错误时，队列清空、回上层给的错误码，
                    // 出错句柄是队列里那一条的句柄）。按句柄分组：把这个句柄的全部排队写在一份
                    // 副本上依次叠出来，再把叠出来的值交给钩子。
                    var checked: [queue_len]bool = @splat(false);
                    for (self.queue[0..self.queued], 0..) |*first, fi| {
                        if (checked[fi]) continue;
                        checked[fi] = true;
                        const a = db.find(first.handle).?;
                        for (self.queue[fi..self.queued], fi..) |*e, ei| {
                            if (e.handle == first.handle) checked[ei] = true;
                        }
                        const check = a.validate orelse continue;
                        var sim: [value_max]u8 = undefined;
                        const cur = self.valueOf(a);
                        @memcpy(sim[0..cur.len], cur);
                        var sim_len: usize = cur.len;
                        for (self.queue[fi..self.queued]) |*e| {
                            if (e.handle != first.handle) continue;
                            @memcpy(sim[e.offset..][0..e.len], e.value[0..e.len]);
                            if (!a.fixed) sim_len = @max(sim_len, @as(usize, e.offset) + e.len);
                            if (check(cur, sim[0..sim_len], a.validate_arg)) |code| {
                                return self.failRaw(out, op, e.handle, code);
                            }
                        }
                    }
                    for (self.queue[0..self.queued]) |*e| {
                        const a = db.find(e.handle).?;
                        const cur: u32 = @intCast(self.valueOf(a).len);
                        const dst = self.storeOf(a);
                        @memcpy(dst[e.offset..][0..e.len], e.value[0..e.len]);
                        if (!a.fixed) self.setLen(a, @max(cur, @as(u32, e.offset) + e.len));
                    }
                    return att.encodeExecuteWriteRsp(out, &self.att);
                }

                /// ATT_SIGNED_WRITE_CMD。§3.4.5.4：验签失败、不能写，都只是忽略，不应答。
                fn onSignedWrite(self: *P, db: *Self, pdu: []const u8, sw: att.SignedWrite) Error!usize {
                    self.stats.commands += 1;
                    const csrk = self.csrk orelse {
                        self.stats.rejected_signatures += 1;
                        return 0;
                    };
                    // 被签的是操作码加参数，即去掉末尾 12 字节签名（§3.3.1）。
                    const counter = cmac.counterOf(sw.sig);
                    const ok = cmac.verify(csrk, pdu[0 .. pdu.len - cmac.sig_len], sw.sig) and
                        counter > self.sign_counter;
                    if (!ok) {
                        self.stats.rejected_signatures += 1;
                        return 0;
                    }
                    self.sign_counter = counter;
                    self.stats.signed_writes += 1;
                    _ = self.writeAttr(db, sw.handle, sw.value);
                    return 0;
                }

                /// 属性在当前 client 上的值：槽位属性还没被这个 client 写过时就是属性的默认值。
                fn valueOf(self: *P, a: *const Attr) []const u8 {
                    if (a.slot != no_slot) {
                        const s = &self.slots[a.slot];
                        if (s.set) return s.data[0..s.len];
                    }
                    return a.value[0..a.len];
                }

                /// 可写的存储。槽位属性第一次被这个 client 写之前，先把默认值搬进槽位。
                fn storeOf(self: *P, a: *Attr) []u8 {
                    if (a.slot == no_slot) return a.value[0..];
                    const s = &self.slots[a.slot];
                    if (!s.set) {
                        @memcpy(s.data[0..a.len], a.value[0..a.len]);
                        s.len = @intCast(a.len);
                        s.set = true;
                    }
                    return s.data[0..];
                }

                fn setLen(self: *P, a: *Attr, len: usize) void {
                    if (a.slot != no_slot) {
                        self.slots[a.slot].len = @intCast(len);
                    } else {
                        a.len = @intCast(len);
                    }
                }

                /// 读的权限检查。null 表示可以读；否则是要回的错误码。
                fn readPerm(self: *P, a: *const Attr) ?att.Code {
                    return checkPerm(a.perm, self.security, true);
                }

                fn writePerm(self: *P, a: *const Attr) ?att.Code {
                    return checkPerm(a.perm, self.security, false);
                }

                // -----------------------------------------------------------------
                // server 发起的那一半
                // -----------------------------------------------------------------

                /// Handle Value Notification。发不发由上层决定（GATT 要先看 client 的
                /// 订阅）；这里只管句柄、认证要求与 MTU 截断。
                pub fn notify(self: *P, db: *Self, attr_handle: u16, value: []const u8, out: []u8) Error!usize {
                    if (self.dead) return error.BearerClosed;
                    const a = db.find(attr_handle) orelse return error.InvalidHandle;
                    if (a.perm.ntf_auth and !self.security.authenticated) return error.InsufficientAuthentication;
                    self.stats.notifications += 1;
                    return att.encodeNotify(out, attr_handle, value, self.mtu, &self.att);
                }

                /// Handle Value Indication。发出之后到收到确认为止不能再发指示（§3.4.7.2）；
                /// `now_ms` 是发出时刻，`tick()` 用它判 30 秒超时。
                pub fn indicate(
                    self: *P,
                    db: *Self,
                    attr_handle: u16,
                    value: []const u8,
                    out: []u8,
                    now_ms: u32,
                ) Error!usize {
                    if (self.dead) return error.BearerClosed;
                    if (self.indicating) return error.IndicationPending;
                    const a = db.find(attr_handle) orelse return error.InvalidHandle;
                    if (a.perm.ntf_auth and !self.security.authenticated) return error.InsufficientAuthentication;
                    const n = try att.encodeIndicate(out, attr_handle, value, self.mtu, &self.att);
                    self.indicating = true;
                    self.indicate_at_ms = now_ms;
                    self.stats.indications += 1;
                    return n;
                }

                /// 周期调用。有指示等了 30 秒还没确认 → 这条 bearer 的事务超时（§3.3.3），
                /// 返回 true；之后收发都返回 `error.BearerClosed`。
                pub fn tick(self: *P, now_ms: u32) bool {
                    if (self.indicating and now_ms -% self.indicate_at_ms >= transaction_timeout_ms) {
                        self.indicating = false;
                        self.dead = true;
                        self.stats.timeouts += 1;
                        return true;
                    }
                    return false;
                }
            };
        }

        /// 权限检查的顺序。[Vol 3] Part F §4：认证与授权要求先于其它检查，否则 client 可以
        /// 用 Invalid Offset 与 Insufficient Authentication 的差别去探一个它无权读的属性的
        /// 长度。多重错误同时成立时回哪个由实现定（§3.4.1.1），这里依次是：认证 → 授权 →
        /// 加密 → 密钥长度 → 读 / 写权限。
        fn checkPerm(perm: Perm, sec: Security, is_read: bool) ?att.Code {
            const need_auth = if (is_read) perm.read_auth else perm.write_auth;
            const need_authz = if (is_read) perm.read_authz else perm.write_authz;
            if (need_auth and !sec.authenticated) return .insufficient_authentication;
            if (need_authz and !sec.authorized) return .insufficient_authorization;
            const need_enc = if (is_read) perm.read_enc else perm.write_enc;
            if (need_enc or need_auth) {
                if (!sec.encrypted) return .insufficient_encryption;
                if (sec.key_size < perm.min_key_size) return .insufficient_key_size;
            }
            if (is_read and !perm.read) return .read_not_permitted;
            if (!is_read and !perm.write) return .write_not_permitted;
            return null;
        }
    };
}
