//! ble-802154：GATT 服务端——用属性表搭出服务、特征与描述符，管理 Client Characteristic
//! Configuration、通知与指示、Service Changed。
//!
//! 规范出处（Bluetooth Core Specification v5.4，[Vol 3] Part G）：
//!   * 属性分组、哪些类型能在 Read By Group Type 里用 —— §2.5.3；
//!   * 服务声明 —— §3.1（表 3.1）；包含声明 —— §3.2（表 3.2）；特征定义 —— §3.3；
//!     特征声明与 Characteristic Properties —— §3.3.1（表 3.3、表 3.4、表 3.5）；
//!   * 描述符 —— §3.3.3：扩展属性 §3.3.3.1、用户描述 §3.3.3.2、Client Characteristic
//!     Configuration §3.3.3.3（表 3.10、表 3.11）、其余描述符 §3.3.3.4–§3.3.3.6；
//!     UUID 汇总在表 3.17；
//!   * 通知与指示 —— §4.10、§4.11；
//!   * Generic Attribute Profile 服务与 Service Changed 特征 —— §7、§7.1（表 7.2、表 7.3）。
//!
//! `Server(N, V)` 里是一个 `att_server.Db(N, V)`。`addService` / `addInclude` /
//! `addCharacteristic` / `addDescriptor` 按规范的声明格式往属性表里放属性；收发走
//! `att_server`：`server.db.Peer(Q)` 是一个 client，它的 `onPdu()` 处理这个 client 发来
//! 的请求。本文件只是在 ATT 之上加了三样东西：
//!
//!   * 声明值的字节格式（特征声明 = 属性位 ‖ 值句柄 ‖ UUID，包含声明 = 服务句柄 ‖
//!     组尾句柄 ‖ 服务 UUID，等等）；
//!   * Client Characteristic Configuration：每个能通知 / 指示的特征占一个按 client 保存的
//!     槽位，读出来是这个 client 自己的配置位，写进去只影响这个 client（§3.3.3.3）；
//!   * 发通知 / 指示之前先看这个 client 的配置位。
//!
//! CCCD 写入的校验（§4.12.3：尺寸不对或值不合法 → 不写，回 Application Error）通过
//! `att_server` 的 `Validate` 钩子挂上。规范没有给「置了特征不支持的位」规定错误码，
//! 这里取 Application Error 区间的第一个值 0x80（`ccc_not_allowed`）。
//!
//! 本文件没做的：绑定设备的 CCCD / Service Changed 持久化。Database Hash、Client Supported Features、
//! Server Supported Features 三个特征（§7.2–§7.4）与 Robust Caching（§2.5.2.1）在 `robust_cache.zig` 里，
//! EATT bearer 经 `eatt.zig` 的 `ServerAtt()` 接上来。

const std = @import("std");
const att = @import("att.zig");
const svr = @import("att_server.zig");

/// GATT 定义的属性类型 UUID（[Vol 3] Part G 表 3.17）。前四个是声明，后六个是描述符。
pub const uuid_primary_service: u16 = svr.uuid_primary_service;
pub const uuid_secondary_service: u16 = svr.uuid_secondary_service;
pub const uuid_include: u16 = svr.uuid_include;
pub const uuid_characteristic: u16 = svr.uuid_characteristic;
pub const uuid_ext_props: u16 = 0x2900;
pub const uuid_user_desc: u16 = 0x2901;
pub const uuid_cccd: u16 = 0x2902;
pub const uuid_sccd: u16 = 0x2903;
pub const uuid_present_fmt: u16 = 0x2904;
pub const uuid_agg_fmt: u16 = 0x2905;

/// Generic Attribute Profile 服务的 UUID（§7）与 Service Changed 特征的 UUID（§7.1）。
pub const svc_generic_attribute: u16 = 0x1801;
pub const chr_service_changed: u16 = 0x2A05;

/// Client Characteristic Configuration 的配置位（表 3.11）：bit0 通知、bit1 指示。
pub const ccc_notify: u16 = 0x0001;
pub const ccc_indicate: u16 = 0x0002;

/// 写 CCCD 时置了特征不支持的位（或保留位）回的错误码。见文件头的说明。
pub const ccc_not_allowed: u8 = 0x80;

/// Characteristic Properties（表 3.5）。字节里的位序就是线上的位序。
pub const Props = packed struct(u8) {
    broadcast: bool = false,
    read: bool = false,
    write_no_rsp: bool = false,
    write: bool = false,
    notify: bool = false,
    indicate: bool = false,
    signed_write: bool = false,
    extended: bool = false,

    pub fn toInt(self: Props) u8 {
        return @bitCast(self);
    }
};

/// 特征值的安全要求。属性位决定能不能读、写、通知、指示（§3.3.1.1：属性位不看安全
/// 要求）；安全要求是另一回事，由上层 profile 或实现定（§3.3.2）。
pub const Sec = struct {
    read_enc: bool = false,
    read_auth: bool = false,
    read_authz: bool = false,
    write_enc: bool = false,
    write_auth: bool = false,
    write_authz: bool = false,
    /// 发通知 / 指示之前要求链路已认证（[Vol 3] Part F §3.2.5）。
    ntf_auth: bool = false,
    /// 写这个特征的 CCCD 要求链路已认证（表 3.10：可写，是否要认证由上层定）。
    cccd_write_auth: bool = false,
    min_key_size: u8 = 7,
};

/// `addCharacteristic()` 的入参。
pub const CharSpec = struct {
    uuid: att.Uuid,
    props: Props,
    sec: Sec = .{},
    initial: []const u8 = &.{},
    /// 值的最大长度；0 表示等于初值长度。
    max_len: u16 = 0,
    /// 定长值：长度恒等于初值长度，写短了只覆盖前一段。
    fixed: bool = false,
    validate: ?svr.Validate = null,
    validate_arg: u16 = 0,
};

pub const Error = svr.AddError || error{
    /// 按 client 的槽位用完了：每个能通知 / 指示的特征各占一个。
    NoSlots,
    /// 第二次加 Service Changed 特征（§7.1：只能有一个）。
    Duplicate,
    /// `addInclude()` 指向的句柄不是服务声明。
    NotAService,
};

pub const SendError = svr.Error || error{
    /// 句柄在属性表里不存在。
    InvalidHandle,
    /// 这个句柄不是带通知（或指示）属性的特征值。
    NotNotify,
    NotIndicate,
    /// 这个 client 没有在 CCCD 里打开对应的位。
    NotSubscribed,
    /// 服务表里没有 Service Changed 特征。
    NoServiceChanged,
};

/// 一个特征的句柄。`cccd` 为 0 表示没有 CCCD（不能通知也不能指示）。
pub const Char = struct { decl: u16, value: u16, cccd: u16 = 0 };

/// GATT 服务端。`max_attrs`、`value_max` 同 `att_server.Db`。
pub fn Server(comptime max_attrs: usize, comptime value_max: usize) type {
    return struct {
        const Self = @This();

        pub const Db = svr.Db(max_attrs, value_max);

        /// 能通知 / 指示的特征：值句柄、CCCD 句柄、按 client 保存配置位的槽位、允许写的位。
        const Cfg = struct { value: u16, cccd: u16, slot: u8, allowed: u8 };

        db: Db = .{},
        /// Service Changed 特征值的句柄；0 表示没有这个特征。
        service_changed: u16 = 0,
        cfgs: [svr.slot_count]Cfg = undefined,
        cfg_count: u8 = 0,

        pub fn reset(self: *Self) void {
            self.db.reset();
            self.service_changed = 0;
            self.cfg_count = 0;
        }

        fn uuidBytes(uuid: att.Uuid, buf: *[16]u8) []const u8 {
            return buf[0..uuid.put(buf)];
        }

        /// 服务声明（§3.1，表 3.1）：类型 0x2800（primary）或 0x2801（secondary），值是服务
        /// 的 UUID（16 位的写 2 字节，128 位的写 16 字节），只读、不要认证与授权。
        /// 返回服务声明句柄。服务的结束句柄随之后加进来的属性变化，用 `serviceEnd()` 取。
        pub fn addService(self: *Self, uuid: att.Uuid, primary: bool) Error!u16 {
            var buf: [16]u8 = undefined;
            return self.db.add(.{
                .type = .{ .u16 = if (primary) uuid_primary_service else uuid_secondary_service },
                .value = uuidBytes(uuid, &buf),
                .fixed = true,
                .perm = .{ .read = true },
            });
        }

        /// 句柄为 `start` 的服务的结束句柄：服务定义里最后一个属性的句柄（§3.1：到下一条
        /// 服务声明之前）。`start` 不是服务声明时返回 null。
        pub fn serviceEnd(self: *Self, start: u16) ?u16 {
            const i = self.db.indexOf(start) orelse return null;
            if (svr.groupOf(self.db.attrs[i].type) != .service) return null;
            return self.db.groupEnd(i);
        }

        /// 包含声明（§3.2，表 3.2）：类型 0x2802，值 = 被包含服务的句柄（2）‖ 组尾句柄（2）
        /// ‖ 服务 UUID（只有 16 位 UUID 时才带）。被包含的服务此时必须已经完整，组尾
        /// 句柄取它当时的值。返回包含声明句柄。
        pub fn addInclude(self: *Self, service_start: u16) Error!u16 {
            const i = self.db.indexOf(service_start) orelse return error.NotAService;
            const decl = &self.db.attrs[i];
            if (svr.groupOf(decl.type) != .service) return error.NotAService;
            const end = self.db.groupEnd(i);
            var value: [20]u8 = undefined;
            att.putU16(value[0..2], service_start);
            att.putU16(value[2..4], end);
            var n: usize = 4;
            // 声明的值就是服务 UUID 本身：2 字节是 16 位，带上；16 字节是 128 位，不带。
            if (decl.len == 2) {
                att.putU16(value[4..6], att.getU16(decl.value[0..2]));
                n = 6;
            }
            return self.db.add(.{
                .type = .{ .u16 = uuid_include },
                .value = value[0..n],
                .fixed = true,
                .perm = .{ .read = true },
            });
        }

        /// 特征声明 + 特征值声明（§3.3.1、§3.3.2）；带 notify 或 indicate 属性位时再加一个
        /// Client Characteristic Configuration 描述符（§3.3.3.3）。值声明必须紧随特征声明。
        pub fn addCharacteristic(self: *Self, spec: CharSpec) Error!Char {
            const has_ntf = spec.props.notify or spec.props.indicate;
            if (has_ntf and self.cfg_count >= svr.slot_count) return error.NoSlots;
            const max_len: usize = if (spec.max_len == 0 or spec.fixed) spec.initial.len else spec.max_len;
            if (spec.initial.len > max_len or max_len > value_max) return error.TooLong;
            const need: usize = @as(usize, 2) + @intFromBool(has_ntf);
            const first = self.db.next_handle;
            if (first == 0 or @as(usize, first) + need - 1 > 0xFFFF or @as(usize, self.db.count) + need > max_attrs) {
                return error.TableFull;
            }

            var v: [19]u8 = undefined;
            v[0] = spec.props.toInt();
            att.putU16(v[1..3], first + 1);
            const ul = spec.uuid.put(v[3..]);
            const decl = try self.db.add(.{
                .type = .{ .u16 = uuid_characteristic },
                .value = v[0 .. 3 + ul],
                .fixed = true,
                .perm = .{ .read = true },
            });
            const sec = spec.sec;
            const value = try self.db.add(.{
                .type = spec.uuid,
                .value = spec.initial,
                .max_len = spec.max_len,
                .fixed = spec.fixed,
                .perm = .{
                    .read = spec.props.read,
                    .write = spec.props.write or spec.props.write_no_rsp or spec.props.signed_write,
                    .read_enc = sec.read_enc,
                    .read_auth = sec.read_auth,
                    .read_authz = sec.read_authz,
                    .write_enc = sec.write_enc,
                    .write_auth = sec.write_auth,
                    .write_authz = sec.write_authz,
                    .min_key_size = sec.min_key_size,
                    .ntf_auth = sec.ntf_auth,
                },
                .validate = spec.validate,
                .validate_arg = spec.validate_arg,
            });

            var cccd: u16 = 0;
            if (has_ntf) {
                const allowed: u16 = (if (spec.props.notify) ccc_notify else 0) |
                    (if (spec.props.indicate) ccc_indicate else 0);
                const slot = self.cfg_count;
                cccd = try self.db.add(.{
                    .type = .{ .u16 = uuid_cccd },
                    .value = &[_]u8{ 0, 0 },
                    .fixed = true,
                    .perm = .{ .read = true, .write = true, .write_auth = sec.cccd_write_auth },
                    .slot = slot,
                    .validate = checkCcc,
                    .validate_arg = allowed,
                });
                self.cfgs[slot] = .{
                    .value = value,
                    .cccd = cccd,
                    .slot = slot,
                    .allowed = @truncate(allowed),
                };
                self.cfg_count += 1;
            }
            return .{ .decl = decl, .value = value, .cccd = cccd };
        }

        /// 特征描述符（§3.3.3）：放在特征值之后。`uuid` 是描述符的 UUID；权限、是否定长、
        /// 最大长度由调用方给（规范把这些交给上层 profile）。返回描述符句柄。
        pub fn addDescriptor(
            self: *Self,
            uuid: att.Uuid,
            perm: svr.Perm,
            value: []const u8,
            max_len: u16,
            fixed: bool,
        ) Error!u16 {
            return self.db.add(.{
                .type = uuid,
                .value = value,
                .max_len = max_len,
                .fixed = fixed,
                .perm = perm,
            });
        }

        /// Generic Attribute Profile 服务与它的 Service Changed 特征（§7、§7.1）。特征声明
        /// 的属性位是 0x20（只指示），值不可读不可写（表 7.3），带一个只允许指示位的 CCCD。
        /// 只能有一个。
        pub fn addServiceChanged(self: *Self) Error!Char {
            if (self.service_changed != 0) return error.Duplicate;
            if (self.cfg_count >= svr.slot_count) return error.NoSlots;
            if (@as(usize, self.db.count) + 4 > max_attrs) return error.TableFull;
            _ = try self.addService(.{ .u16 = svc_generic_attribute }, true);
            const c = try self.addCharacteristic(.{
                .uuid = .{ .u16 = chr_service_changed },
                .props = .{ .indicate = true },
                .initial = &[_]u8{ 0, 0, 0, 0 },
                .fixed = true,
            });
            self.service_changed = c.value;
            return c;
        }

        fn findCfg(self: *Self, value_handle: u16) ?Cfg {
            for (self.cfgs[0..self.cfg_count]) |c| {
                if (c.value == value_handle) return c;
            }
            return null;
        }

        /// CCCD 写入的校验：必须恰好 2 字节；置了特征没有的位或保留位 → Application Error
        /// （§4.12.3）。`arg` 是允许写的位。
        fn checkCcc(current: []const u8, incoming: []const u8, arg: u16) ?u8 {
            _ = current;
            if (incoming.len != 2) return @backingInt(att.Code.invalid_value_length);
            if (att.getU16(incoming) & ~arg != 0) return ccc_not_allowed;
            return null;
        }

        /// 读这个 client 对某特征的配置位；`value_handle` 不是能通知 / 指示的特征值时为 null。
        pub fn configOf(self: *Self, peer: anytype, value_handle: u16) ?u16 {
            const c = self.findCfg(value_handle) orelse return null;
            return peer.slotU16(c.slot);
        }

        /// Handle Value Notification（§4.10.1）。特征得有 notify 属性位，且这个 client 在
        /// CCCD 里打开了通知位；否则不产生任何字节。
        pub fn notify(
            self: *Self,
            peer: anytype,
            value_handle: u16,
            data: []const u8,
            out: []u8,
        ) SendError!usize {
            const c = self.findCfg(value_handle) orelse return if (self.db.find(value_handle) == null) error.InvalidHandle else error.NotNotify;
            if (c.allowed & ccc_notify == 0) return error.NotNotify;
            if (peer.slotU16(c.slot) & ccc_notify == 0) return error.NotSubscribed;
            return peer.notify(&self.db, value_handle, data, out);
        }

        /// Handle Value Indication（§4.11.1）。特征得有 indicate 属性位，且这个 client 在
        /// CCCD 里打开了指示位。`now_ms` 是发出时刻，用来判 30 秒超时。
        pub fn indicate(
            self: *Self,
            peer: anytype,
            value_handle: u16,
            data: []const u8,
            out: []u8,
            now_ms: u32,
        ) SendError!usize {
            const c = self.findCfg(value_handle) orelse return if (self.db.find(value_handle) == null) error.InvalidHandle else error.NotIndicate;
            if (c.allowed & ccc_indicate == 0) return error.NotIndicate;
            if (peer.slotU16(c.slot) & ccc_indicate == 0) return error.NotSubscribed;
            return peer.indicate(&self.db, value_handle, data, out, now_ms);
        }

        /// Service Changed（§7.1）：向这个 client 指示 `start`–`end` 这一段句柄失效，值是
        /// 两个 16 位句柄首尾相接（表 7.3）；0x0001–0xFFFF 表示全部重新发现。这个 client
        /// 没有打开指示位时，这条指示按规范算丢了（§7.1）：不产生任何字节。
        pub fn serviceChanged(
            self: *Self,
            peer: anytype,
            start: u16,
            end: u16,
            out: []u8,
            now_ms: u32,
        ) SendError!usize {
            const h = self.service_changed;
            if (h == 0) return error.NoServiceChanged;
            const c = self.findCfg(h) orelse return error.NotIndicate;
            if (peer.slotU16(c.slot) & ccc_indicate == 0) return error.NotSubscribed;
            var value: [4]u8 = undefined;
            att.putU16(value[0..2], start);
            att.putU16(value[2..4], end);
            return peer.indicate(&self.db, h, &value, out, now_ms);
        }
    };
}
