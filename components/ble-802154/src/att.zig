//! ble-802154：ATT（Attribute Protocol）PDU 编解码，覆盖 [Vol 3] Part F §3.4 的全部方法。
//!
//! ATT 是 BLE 的「对象读写」层，跑在 L2CAP 固定通道 CID 0x0004 上。PDU 有六种类型
//! （§3.3 表 3.1）：命令、请求、响应、通知、指示、确认。一个 PDU = 1 字节操作码 +
//! 参数；操作码的 bit7 是签名标志、bit6 是命令标志、bit5–0 是方法（§3.3.1 表 3.2）。
//! 多字节字段一律最低有效字节在前，只有 Attribute Value 例外（§3.3.1）。
//!
//! 规范出处（Bluetooth Core Specification v5.4，[Vol 3] Part F）：
//!   * 各 PDU 的参数布局 —— §3.4.2–§3.4.7，汇总在表 3.43；
//!   * ATT_ERROR_RSP 与错误码 —— §3.4.1.1，表 3.3、表 3.4；
//!   * 每个方法允许回哪些错误码 —— §3.4.9 表 3.44；
//!   * ATT_MTU 默认值 23 —— [Vol 3] Part G §5.2.1 表 5.1；属性值最长 512 字节 —— §3.2.9；
//!   * 签名的算法 —— [Vol 3] Part H §2.4.5，例子见 §3.4.5.4（实现在 `cmac.zig`）。
//!
//! 这个文件只做编解码，不含策略：
//!
//!   * 定长 PDU 长度不符 → `Short` / `Trailing`；列表装不下整数条 → `InvalidList`；
//!     UUID 不是 2 或 16 字节 → `BadUuid`。
//!   * 规范允许截断的响应（Read / Read Blob / Read Multiple 的值、通知与指示的值）按
//!     给定的 ATT_MTU 截断，`stats.truncated` 加一；
//!   * 规范不允许截断的（Prepare Write 的部分值、Write Command、Signed Write Command、
//!     Multiple Variable Length Notification）超出 ATT_MTU → `TooLong`，不写半截。
//!   * 服务端要按「整条、同长、不超 MTU」打包的四个响应各有一个打包器（`InfoBuilder`
//!     等），规则写在各打包器上。
//!
//! 文件末尾保留章节时代的最小 API（`encodeMtuReq` … `kat_*`）：签名与行为不变，
//! 只是在同一条解析路径上。

const std = @import("std");

// ---------------------------------------------------------------------------
// 操作码、PDU 类型、错误码
// ---------------------------------------------------------------------------

/// PDU 类型。[Vol 3] Part F §3.3 表 3.1。
pub const Kind = enum { command, request, response, notification, indication, confirmation };

/// ATT 操作码。[Vol 3] Part F 表 3.43。
pub const Op = enum(u8) {
    error_rsp = 0x01,
    mtu_req = 0x02,
    mtu_rsp = 0x03,
    find_info_req = 0x04,
    find_info_rsp = 0x05,
    find_by_type_req = 0x06,
    find_by_type_rsp = 0x07,
    read_by_type_req = 0x08,
    read_by_type_rsp = 0x09,
    read_req = 0x0a,
    read_rsp = 0x0b,
    read_blob_req = 0x0c,
    read_blob_rsp = 0x0d,
    read_multiple_req = 0x0e,
    read_multiple_rsp = 0x0f,
    read_by_group_req = 0x10,
    read_by_group_rsp = 0x11,
    write_req = 0x12,
    write_rsp = 0x13,
    prepare_write_req = 0x16,
    prepare_write_rsp = 0x17,
    execute_write_req = 0x18,
    execute_write_rsp = 0x19,
    notify = 0x1b,
    indicate = 0x1d,
    confirm = 0x1e,
    read_multiple_var_req = 0x20,
    read_multiple_var_rsp = 0x21,
    multiple_ntf = 0x23,
    write_cmd = 0x52,
    signed_write_cmd = 0xd2,

    /// PDU 类型（表 3.1）。只有 ATT_WRITE_CMD 与 ATT_SIGNED_WRITE_CMD 的 bit6 是 1。
    pub fn kind(self: Op) Kind {
        return switch (self) {
            .write_cmd, .signed_write_cmd => .command,
            .error_rsp,
            .mtu_rsp,
            .find_info_rsp,
            .find_by_type_rsp,
            .read_by_type_rsp,
            .read_rsp,
            .read_blob_rsp,
            .read_multiple_rsp,
            .read_by_group_rsp,
            .write_rsp,
            .prepare_write_rsp,
            .execute_write_rsp,
            .read_multiple_var_rsp,
            => .response,
            .notify, .multiple_ntf => .notification,
            .indicate => .indication,
            .confirm => .confirmation,
            else => .request,
        };
    }

    pub fn fromByte(b: u8) ?Op {
        return std.enums.fromInt(Op, b);
    }

    pub fn name(self: Op) []const u8 {
        return @tagName(self);
    }
};

/// 各 PDU 的最小长度（含操作码），与表 3.43 各参数的尺寸栏一一对应。定长 PDU 的
/// 最小长度就是它的长度。
pub const min_len = struct {
    pub const error_rsp: usize = 5;
    pub const mtu_req: usize = 3;
    pub const mtu_rsp: usize = 3;
    pub const find_info_req: usize = 5;
    /// 操作码 + Format + 一条 (句柄, 16 位 UUID)。
    pub const find_info_rsp: usize = 6;
    pub const find_by_type_req: usize = 7;
    /// 操作码 + 一条 Handles Information。
    pub const find_by_type_rsp: usize = 5;
    /// Attribute Type 是 2 字节时；16 字节时是 21。
    pub const read_by_type_req: usize = 7;
    /// 操作码 + Length + 一条只含句柄的 Attribute Data。
    pub const read_by_type_rsp: usize = 4;
    pub const read_req: usize = 3;
    pub const read_rsp: usize = 1;
    pub const read_blob_req: usize = 5;
    pub const read_blob_rsp: usize = 1;
    /// 两个或更多句柄。
    pub const read_multiple_req: usize = 5;
    pub const read_multiple_rsp: usize = 1;
    pub const read_by_group_req: usize = 7;
    /// 操作码 + Length + 一条只含句柄范围与 0 字节值的 Attribute Data。
    pub const read_by_group_rsp: usize = 6;
    pub const read_multiple_var_req: usize = 5;
    pub const read_multiple_var_rsp: usize = 5;
    pub const write_req: usize = 3;
    pub const write_rsp: usize = 1;
    pub const write_cmd: usize = 3;
    /// 操作码 + 句柄 + 12 字节签名。
    pub const signed_write_cmd: usize = 15;
    pub const prepare_write_req: usize = 5;
    pub const prepare_write_rsp: usize = 5;
    pub const execute_write_req: usize = 2;
    pub const execute_write_rsp: usize = 1;
    pub const notify: usize = 3;
    pub const indicate: usize = 3;
    pub const confirm: usize = 1;
    /// 操作码 + 一条 (句柄, 长度, 0 字节值)。
    pub const multiple_ntf: usize = 9;
    /// Read By Type / Read By Group Type 请求带 128 位 UUID 时的长度。
    pub const type_req_u128: usize = 21;
};

/// ATT 错误码。[Vol 3] Part F §3.4.1.1 表 3.4。应用错误（0x80–0x9F）与 Common Profile
/// and Service Error Codes（0xE0–0xFF）由上层定义，不在枚举里，按原始字节传递。
pub const Code = enum(u8) {
    invalid_handle = 0x01,
    read_not_permitted = 0x02,
    write_not_permitted = 0x03,
    invalid_pdu = 0x04,
    insufficient_authentication = 0x05,
    request_not_supported = 0x06,
    invalid_offset = 0x07,
    insufficient_authorization = 0x08,
    prepare_queue_full = 0x09,
    attribute_not_found = 0x0A,
    attribute_not_long = 0x0B,
    insufficient_key_size = 0x0C,
    invalid_value_length = 0x0D,
    unlikely_error = 0x0E,
    insufficient_encryption = 0x0F,
    unsupported_group_type = 0x10,
    insufficient_resources = 0x11,
    database_out_of_sync = 0x12,
    value_not_allowed = 0x13,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .invalid_handle => "invalid_handle",
            .read_not_permitted => "read_not_permitted",
            .write_not_permitted => "write_not_permitted",
            .invalid_pdu => "invalid_pdu",
            .insufficient_authentication => "insufficient_authentication",
            .request_not_supported => "request_not_supported",
            .invalid_offset => "invalid_offset",
            .insufficient_authorization => "insufficient_authorization",
            .prepare_queue_full => "prepare_queue_full",
            .attribute_not_found => "attribute_not_found",
            .attribute_not_long => "attribute_not_long",
            .insufficient_key_size => "insufficient_key_size",
            .invalid_value_length => "invalid_value_length",
            .unlikely_error => "unlikely_error",
            .insufficient_encryption => "insufficient_encryption",
            .unsupported_group_type => "unsupported_group_type",
            .insufficient_resources => "insufficient_resources",
            .database_out_of_sync => "database_out_of_sync",
            .value_not_allowed => "value_not_allowed",
        };
    }

    pub fn fromByte(b: u8) ?Code {
        return std.enums.fromInt(Code, b);
    }
};

/// Application Error 的取值范围（表 3.4：0x80–0x9F，由上层规范定义）。
pub const app_error_min: u8 = 0x80;
pub const app_error_max: u8 = 0x9F;
/// Common Profile and Service Error Codes 的取值范围（表 3.4：0xE0–0xFF）。
pub const common_error_min: u8 = 0xE0;
pub const common_error_max: u8 = 0xFF;

/// 任意错误码的名字：表 3.4 里的 19 个之外，给出所在区间；其余是 Reserved for future use。
pub fn codeName(code: u8) []const u8 {
    if (Code.fromByte(code)) |c| return c.name();
    return if (code >= app_error_min and code <= app_error_max)
        "application_error"
    else if (code >= common_error_min and code <= common_error_max)
        "common_profile_and_service_error"
    else
        "reserved";
}

/// 默认 ATT_MTU（未交换时）。[Vol 3] Part G §5.2.1 表 5.1。
pub const default_mtu: u16 = 23;
/// 本组件 server 端声明的上限。
///
/// 5.4 的 Part F / Part G 原文没有给出 ATT_MTU 的上限，只有「属性值最长 512 字节」
/// （[Vol 3] Part F §3.2.9）。取 527 是沿用 NimBLE（`ble_att.h:270-273`）：527 的 MTU
/// 正好让最大的 ATT 命令（Signed Write）装下 512 字节属性值（1 + 2 + 512 + 12）。
pub const max_mtu: u16 = 527;
/// 属性值的最大长度（[Vol 3] Part F §3.2.9）。
pub const value_max: usize = 512;
/// 一个 ATT PDU 的最大缓冲：操作码 + 参数，不超过 `max_mtu`。
pub const buf_max: usize = max_mtu;

pub const Error = error{
    /// PDU 比该操作码要求的最小长度短。
    Short,
    /// 定长 PDU 的长度与规定不符，或操作码与期望的不一致。
    Trailing,
    /// 输出缓冲不够。
    NoSpace,
    /// client 请求的 MTU < 23。
    MtuTooSmall,
    /// MTU 超过本实现声明的上限。
    MtuTooLarge,
    /// 操作码不是 ATT 操作码（表 3.43 之外）。
    UnsupportedOp,
    /// 列表装不下整数条，或 Length / Format 字段的值不合法。
    InvalidList,
    /// UUID 的长度不是 2 或 16 字节。
    BadUuid,
    /// Flags 字段的值不是 0x00 或 0x01。
    BadFlags,
    /// 规范不允许截断的内容超过了 ATT_MTU 能装下的长度。
    TooLong,
    /// 空列表：响应至少要有一条。
    Empty,
};

/// 编解码统计。判据 ③④⑥ 都拿这里的计数当被测对象。
pub const Stats = struct {
    mtu_exchanges: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    notifies: u32 = 0,
    errors_emitted: u32 = 0,
    truncated: u32 = 0,
    rejected: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

fn reject(stats: *Stats, e: Error) Error {
    stats.rejected += 1;
    return e;
}

pub fn putU16(out: []u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

pub fn getU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

/// 操作码相符且长度恰为 n。
fn exact(pdu: []const u8, op: Op, n: usize, stats: *Stats) Error!void {
    if (pdu.len < n) return reject(stats, error.Short);
    if (pdu.len > n or pdu[0] != @backingInt(op)) return reject(stats, error.Trailing);
}

/// 操作码相符且长度不小于 n。
fn atLeast(pdu: []const u8, op: Op, n: usize, stats: *Stats) Error!void {
    if (pdu.len < n) return reject(stats, error.Short);
    if (pdu[0] != @backingInt(op)) return reject(stats, error.Trailing);
}

/// 值按 `room` 截断后能放下的长度。写成功之后由 `noteCut` 计数。
fn fit(value: []const u8, room: usize) usize {
    return @min(value.len, room);
}

fn noteCut(stats: *Stats, n: usize, full: usize) void {
    if (n < full) stats.truncated += 1;
}

fn sat(v: i32) usize {
    return if (v <= 0) 0 else @intCast(v);
}

// ---------------------------------------------------------------------------
// UUID
// ---------------------------------------------------------------------------

/// 属性类型：16 位蓝牙 UUID 或 128 位 UUID。[Vol 3] Part G §2.5.4：16 位的恰好占 2 字节，
/// 128 位的恰好占 16 字节；32 位 UUID 在 ATT PDU 里一律转成 128 位。
pub const Uuid = union(enum) {
    u16: u16,
    /// 线上字节序（最低有效字节在前）。
    u128: [16]u8,

    /// 蓝牙 SIG 的基底 UUID 0000xxxx-0000-1000-8000-00805F9B34FB 的线上字节序：128 位数
    /// 最低有效字节在前（§3.3.1），所以 16 位值落在第 12、13 字节，前面的
    /// FB 34 9B 5F 80 00 00 80 00 10 00 00 是基底的固定部分。与本机 NimBLE 的
    /// `ble_uuid_base`（ble_uuid.c:40）逐字节相同。
    pub const base: [16]u8 = .{
        0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80,
        0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    /// 16 位值在 128 位写法里的偏移。
    pub const alias_at: usize = 12;

    pub fn parse(bytes: []const u8) Error!Uuid {
        return switch (bytes.len) {
            2 => .{ .u16 = getU16(bytes) },
            16 => .{ .u128 = bytes[0..16].* },
            else => error.BadUuid,
        };
    }

    /// 线上长度：2 或 16。
    pub fn wireLen(self: Uuid) usize {
        return switch (self) {
            .u16 => 2,
            .u128 => 16,
        };
    }

    /// 按线上字节序写出，返回写入的字节数。
    pub fn put(self: Uuid, out: []u8) usize {
        switch (self) {
            .u16 => |v| {
                putU16(out, v);
                return 2;
            },
            .u128 => |b| {
                @memcpy(out[0..16], &b);
                return 16;
            },
        }
    }

    /// 128 位写法（线上字节序）。
    pub fn to128(self: Uuid) [16]u8 {
        return switch (self) {
            .u128 => |b| b,
            .u16 => |v| blk: {
                var b = base;
                putU16(b[alias_at..], v);
                break :blk b;
            },
        };
    }

    /// 按 128 位比较。§3.4.4.1 注：所有属性类型都按 128 位 UUID 比较，所以用 128 位
    /// 写法请求 0x2800 也能命中类型记成 16 位的属性。
    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.to128(), &b.to128());
    }

    /// 是 16 位 SIG UUID（或它的基底 128 位写法）时取出 16 位值。
    pub fn asU16(self: Uuid) ?u16 {
        return switch (self) {
            .u16 => |v| v,
            .u128 => |b| blk: {
                if (!std.mem.eql(u8, b[0..alias_at], base[0..alias_at]) or
                    !std.mem.eql(u8, b[alias_at + 2 ..], base[alias_at + 2 ..])) break :blk null;
                break :blk getU16(b[alias_at..]);
            },
        };
    }
};

// ---------------------------------------------------------------------------
// 解析结果里的几种视图类型
// ---------------------------------------------------------------------------

/// 起止句柄（Find Information、Find By Type Value、Read By Type、Read By Group Type 的请求）。
pub const Range = struct { start: u16, end: u16 };

/// 带 UUID 的范围请求（Read By Type、Read By Group Type）。
pub const TypeReq = struct { range: Range, uuid: Uuid };

/// 属性句柄 + 值（Write Request / Command、Notification、Indication）。
pub const WriteReq = struct { handle: u16, value: []const u8 };

/// 带偏移的部分值（Prepare Write Request / Response）。
pub const Part = struct { handle: u16, offset: u16, value: []const u8 };

/// 带 Value Offset 的读（Read Blob Request）。
pub const BlobReq = struct { handle: u16, offset: u16 };

/// Find By Type Value Request。属性类型只有 16 位写法（表 3.12）。
pub const FindTypeValue = struct { range: Range, attr_type: u16, value: []const u8 };

/// ATT_SIGNED_WRITE_CMD：值之后跟 12 字节签名（SignCounter 4 + MAC 8，见 `cmac.zig`）。
pub const SignedWrite = struct { handle: u16, value: []const u8, sig: [12]u8 };

/// ATT_EXECUTE_WRITE_REQ 的 Flags（表 3.36）。
pub const ExecuteFlags = enum(u8) {
    cancel = 0x00,
    write = 0x01,
};

pub const ErrorRsp = struct { req_op: u8, handle: u16, code: u8 };

/// 一组 2 字节句柄（Set Of Handles）。
pub const Handles = struct {
    data: []const u8,

    pub fn count(self: Handles) usize {
        return self.data.len / 2;
    }

    pub fn at(self: Handles, i: usize) u16 {
        return getU16(self.data[2 * i ..]);
    }
};

/// Find Information Response 的一条：句柄与它的类型。
pub const Info = struct { handle: u16, uuid: Uuid };

pub const InfoFormat = enum(u8) {
    /// 句柄 + 16 位 UUID，每条 4 字节（表 3.10）。
    u16 = 0x01,
    /// 句柄 + 128 位 UUID，每条 18 字节（表 3.11）。
    u128 = 0x02,

    pub fn itemLen(self: InfoFormat) usize {
        return switch (self) {
            .u16 => 4,
            .u128 => 18,
        };
    }
};

/// ATT_FIND_INFORMATION_RSP 的内容（去掉操作码）。
pub const InfoRsp = struct {
    format: InfoFormat,
    data: []const u8,

    pub fn count(self: InfoRsp) usize {
        return self.data.len / self.format.itemLen();
    }

    pub fn at(self: InfoRsp, i: usize) Info {
        const off = i * self.format.itemLen();
        return .{
            .handle = getU16(self.data[off..]),
            .uuid = switch (self.format) {
                .u16 => .{ .u16 = getU16(self.data[off + 2 ..]) },
                .u128 => .{ .u128 = self.data[off + 2 ..][0..16].* },
            },
        };
    }
};

/// 「Length 字段 + 等长条目」的响应视图：Read By Type（没有组尾句柄）与
/// Read By Group Type（条目里多一个 End Group Handle）。
pub fn LengthListView(comptime has_head: bool) type {
    return struct {
        const Self = @This();
        /// 条目里句柄之后的那 2 字节（End Group Handle）占的长度。
        pub const head_len: usize = if (has_head) 2 else 0;
        /// 一条的最小长度：句柄 + 头 + 空值。
        pub const min_item: usize = 2 + head_len;
        pub const Item = struct {
            handle: u16,
            head: if (has_head) u16 else void,
            value: []const u8,
        };

        /// 每条的字节数，即响应里的 Length 字段。
        len: u8,
        data: []const u8,

        pub fn count(self: Self) usize {
            return self.data.len / self.len;
        }

        pub fn at(self: Self, i: usize) Item {
            const item: usize = self.len;
            const rec = self.data[i * item ..][0..item];
            return .{
                .handle = getU16(rec),
                .head = if (has_head) getU16(rec[2..]) else {},
                .value = rec[2 + head_len ..],
            };
        }
    };
}

/// ATT_READ_BY_TYPE_RSP 的内容。
pub const TypeRsp = LengthListView(false);
/// ATT_READ_BY_GROUP_TYPE_RSP 的内容。
pub const GroupRsp = LengthListView(true);

/// Read Multiple Variable Length Response 的一条 Length Value Tuple。`value.len` 可以小于
/// `len`：§3.4.4.12 注，元组被截断时 Value Length 仍写完整长度。
pub const Tuple = struct { len: u16, value: []const u8 };

pub const TupleList = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *TupleList) ?Tuple {
        if (self.pos >= self.data.len) return null;
        const rest = self.data.len - self.pos;
        if (rest < 2) return null;
        const len = getU16(self.data[self.pos..]);
        const present = @min(@as(usize, len), rest - 2);
        const value = self.data[self.pos + 2 ..][0..present];
        self.pos += 2 + present;
        return .{ .len = len, .value = value };
    }
};

/// ATT_MULTIPLE_HANDLE_VALUE_NTF 的一条 Handle Length Value Tuple（表 3.42）。
pub const MultiNtf = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *MultiNtf) ?WriteReq {
        if (self.pos >= self.data.len) return null;
        const rest = self.data.len - self.pos;
        if (rest < 4) return null;
        const handle = getU16(self.data[self.pos..]);
        const len = getU16(self.data[self.pos + 2 ..]);
        if (rest - 4 < len) return null;
        const value = self.data[self.pos + 4 ..][0..len];
        self.pos += 4 + len;
        return .{ .handle = handle, .value = value };
    }
};

// ---------------------------------------------------------------------------
// 统一解析：一个入口把任意 PDU 解成带标签的联合
// ---------------------------------------------------------------------------

/// `parse` 的结果。载荷是指向输入 PDU 的切片，指向输入的内存。
pub const Pdu = union(Op) {
    error_rsp: ErrorRsp,
    mtu_req: u16,
    mtu_rsp: u16,
    find_info_req: Range,
    find_info_rsp: InfoRsp,
    find_by_type_req: FindTypeValue,
    find_by_type_rsp: HandleRanges,
    read_by_type_req: TypeReq,
    read_by_type_rsp: TypeRsp,
    read_req: u16,
    read_rsp: []const u8,
    read_blob_req: BlobReq,
    read_blob_rsp: []const u8,
    read_multiple_req: Handles,
    read_multiple_rsp: []const u8,
    read_by_group_req: TypeReq,
    read_by_group_rsp: GroupRsp,
    write_req: WriteReq,
    write_rsp,
    prepare_write_req: Part,
    prepare_write_rsp: Part,
    execute_write_req: ExecuteFlags,
    execute_write_rsp,
    notify: WriteReq,
    indicate: WriteReq,
    confirm,
    read_multiple_var_req: Handles,
    read_multiple_var_rsp: []const u8,
    multiple_ntf: []const u8,
    write_cmd: WriteReq,
    signed_write_cmd: SignedWrite,
};

/// 解析任意一个 ATT PDU。只做结构检查，不做取值范围与权限判断（那是 server 的事）：
/// 长度、UUID 尺寸、列表能否装下整数条、Flags 的值。
pub fn parse(pdu: []const u8, stats: *Stats) Error!Pdu {
    if (pdu.len == 0) return reject(stats, error.Short);
    const op = Op.fromByte(pdu[0]) orelse return reject(stats, error.UnsupportedOp);
    switch (op) {
        .error_rsp => {
            try exact(pdu, op, min_len.error_rsp, stats);
            return .{ .error_rsp = .{ .req_op = pdu[1], .handle = getU16(pdu[2..4]), .code = pdu[4] } };
        },
        .mtu_req, .mtu_rsp => {
            try exact(pdu, op, min_len.mtu_req, stats);
            return if (op == .mtu_req) .{ .mtu_req = getU16(pdu[1..3]) } else .{ .mtu_rsp = getU16(pdu[1..3]) };
        },
        .find_info_req => {
            try exact(pdu, op, min_len.find_info_req, stats);
            return .{ .find_info_req = .{ .start = getU16(pdu[1..3]), .end = getU16(pdu[3..5]) } };
        },
        .find_info_rsp => {
            try atLeast(pdu, op, min_len.find_info_rsp, stats);
            const format = std.enums.fromInt(InfoFormat, pdu[1]) orelse return reject(stats, error.InvalidList);
            const data = pdu[2..];
            if (data.len % format.itemLen() != 0) return reject(stats, error.InvalidList);
            return .{ .find_info_rsp = .{ .format = format, .data = data } };
        },
        .find_by_type_req => {
            try atLeast(pdu, op, min_len.find_by_type_req, stats);
            return .{ .find_by_type_req = .{
                .range = .{ .start = getU16(pdu[1..3]), .end = getU16(pdu[3..5]) },
                .attr_type = getU16(pdu[5..7]),
                .value = pdu[7..],
            } };
        },
        .find_by_type_rsp => {
            try atLeast(pdu, op, min_len.find_by_type_rsp, stats);
            if ((pdu.len - 1) % 4 != 0) return reject(stats, error.InvalidList);
            return .{ .find_by_type_rsp = .{ .data = pdu[1..] } };
        },
        .read_by_type_req => {
            try atLeast(pdu, op, min_len.read_by_type_req, stats);
            const uuid = try Uuid.parse(pdu[5..]);
            return .{ .read_by_type_req = .{
                .range = .{ .start = getU16(pdu[1..3]), .end = getU16(pdu[3..5]) },
                .uuid = uuid,
            } };
        },
        .read_by_type_rsp => {
            try atLeast(pdu, op, min_len.read_by_type_rsp, stats);
            const item: usize = pdu[1];
            if (item < TypeRsp.min_item or (pdu.len - 2) % item != 0) return reject(stats, error.InvalidList);
            return .{ .read_by_type_rsp = .{ .len = pdu[1], .data = pdu[2..] } };
        },
        .read_req => {
            try exact(pdu, op, min_len.read_req, stats);
            return .{ .read_req = getU16(pdu[1..3]) };
        },
        .read_rsp => {
            try atLeast(pdu, op, min_len.read_rsp, stats);
            return .{ .read_rsp = pdu[1..] };
        },
        .read_blob_req => {
            try exact(pdu, op, min_len.read_blob_req, stats);
            return .{ .read_blob_req = .{ .handle = getU16(pdu[1..3]), .offset = getU16(pdu[3..5]) } };
        },
        .read_blob_rsp => {
            try atLeast(pdu, op, min_len.read_blob_rsp, stats);
            return .{ .read_blob_rsp = pdu[1..] };
        },
        .read_multiple_req, .read_multiple_var_req => {
            try atLeast(pdu, op, min_len.read_multiple_req, stats);
            if ((pdu.len - 1) % 2 != 0) return reject(stats, error.InvalidList);
            const handles = Handles{ .data = pdu[1..] };
            return if (op == .read_multiple_req) .{ .read_multiple_req = handles } else .{ .read_multiple_var_req = handles };
        },
        .read_multiple_rsp => {
            try atLeast(pdu, op, min_len.read_multiple_rsp, stats);
            return .{ .read_multiple_rsp = pdu[1..] };
        },
        .read_by_group_req => {
            try atLeast(pdu, op, min_len.read_by_group_req, stats);
            const uuid = try Uuid.parse(pdu[5..]);
            return .{ .read_by_group_req = .{
                .range = .{ .start = getU16(pdu[1..3]), .end = getU16(pdu[3..5]) },
                .uuid = uuid,
            } };
        },
        .read_by_group_rsp => {
            try atLeast(pdu, op, min_len.read_by_group_rsp, stats);
            const item: usize = pdu[1];
            if (item < GroupRsp.min_item or (pdu.len - 2) % item != 0) return reject(stats, error.InvalidList);
            return .{ .read_by_group_rsp = .{ .len = pdu[1], .data = pdu[2..] } };
        },
        .read_multiple_var_rsp => {
            try atLeast(pdu, op, min_len.read_multiple_var_rsp, stats);
            var it = TupleList{ .data = pdu[1..] };
            while (it.next()) |_| {}
            if (it.pos != pdu.len - 1) return reject(stats, error.InvalidList);
            return .{ .read_multiple_var_rsp = pdu[1..] };
        },
        .write_req, .write_cmd, .notify, .indicate => {
            try atLeast(pdu, op, min_len.write_req, stats);
            const w = WriteReq{ .handle = getU16(pdu[1..3]), .value = pdu[3..] };
            return switch (op) {
                .write_req => .{ .write_req = w },
                .write_cmd => .{ .write_cmd = w },
                .notify => .{ .notify = w },
                else => .{ .indicate = w },
            };
        },
        .write_rsp => {
            try exact(pdu, op, min_len.write_rsp, stats);
            return .{ .write_rsp = {} };
        },
        .signed_write_cmd => {
            try atLeast(pdu, op, min_len.signed_write_cmd, stats);
            const value_end = pdu.len - 12;
            return .{ .signed_write_cmd = .{
                .handle = getU16(pdu[1..3]),
                .value = pdu[3..value_end],
                .sig = pdu[value_end..][0..12].*,
            } };
        },
        .prepare_write_req, .prepare_write_rsp => {
            try atLeast(pdu, op, min_len.prepare_write_req, stats);
            const part = Part{ .handle = getU16(pdu[1..3]), .offset = getU16(pdu[3..5]), .value = pdu[5..] };
            return if (op == .prepare_write_req) .{ .prepare_write_req = part } else .{ .prepare_write_rsp = part };
        },
        .execute_write_req => {
            try exact(pdu, op, min_len.execute_write_req, stats);
            const flags = std.enums.fromInt(ExecuteFlags, pdu[1]) orelse return reject(stats, error.BadFlags);
            return .{ .execute_write_req = flags };
        },
        .execute_write_rsp => {
            try exact(pdu, op, min_len.execute_write_rsp, stats);
            return .{ .execute_write_rsp = {} };
        },
        .confirm => {
            try exact(pdu, op, min_len.confirm, stats);
            return .{ .confirm = {} };
        },
        .multiple_ntf => {
            try atLeast(pdu, op, min_len.multiple_ntf, stats);
            var it = MultiNtf{ .data = pdu[1..] };
            while (it.next()) |_| {}
            if (it.pos != pdu.len - 1) return reject(stats, error.InvalidList);
            return .{ .multiple_ntf = pdu[1..] };
        },
    }
}

/// 某操作码在该 ATT_MTU 下能携带的属性值最大字节数（表 3.43 各参数的尺寸栏）。
/// 不带属性值的操作码返回 0。
pub fn valueMax(op: Op, mtu: u16) usize {
    const m: i32 = mtu;
    return switch (op) {
        .read_rsp, .read_blob_rsp, .read_multiple_rsp, .read_multiple_var_rsp => sat(m - 1),
        .notify, .indicate, .write_req, .write_cmd => sat(m - 3),
        .prepare_write_req, .prepare_write_rsp => sat(m - 5),
        .find_by_type_req => sat(m - 7),
        .signed_write_cmd => sat(m - 15),
        else => 0,
    };
}

/// ATT_READ_BY_TYPE_RSP 里一个属性值的上限：Length 字段只有 1 字节（§3.4.4.2）。
pub const type_rsp_value_max: usize = 253;
/// ATT_READ_BY_GROUP_TYPE_RSP 里一个属性值的上限（§3.4.4.10）。
pub const group_rsp_value_max: usize = 251;

// ---------------------------------------------------------------------------
// 打包器（服务端组响应用）：整条、同长、不超 ATT_MTU
// ---------------------------------------------------------------------------

/// 打包器的公共底座：缓冲、本 PDU 的长度上限、已写到的位置。
const Pack = struct {
    buf: []u8,
    limit: usize,
    pos: usize,

    fn fits(self: Pack, n: usize) bool {
        return self.pos + n <= self.limit and self.pos + n <= self.buf.len;
    }

    fn push16(self: *Pack, v: u16) void {
        putU16(self.buf[self.pos..], v);
        self.pos += 2;
    }

    fn push(self: *Pack, bytes: []const u8) void {
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }
};

/// ATT_FIND_INFORMATION_RSP 的打包器（§3.4.3.2）：只放完整的 (句柄, UUID) 对，按句柄
/// 升序；一个包里的 UUID 尺寸必须相同，遇到尺寸不同的第一条就停；放不下的留给下一个包。
pub const InfoBuilder = struct {
    p: Pack,
    format: InfoFormat = .u16,
    count: usize = 0,
    stats: *Stats,

    pub fn init(buf: []u8, mtu: usize, stats: *Stats) Error!InfoBuilder {
        if (buf.len < min_len.find_info_rsp or mtu < min_len.find_info_rsp) return error.NoSpace;
        buf[0] = @backingInt(Op.find_info_rsp);
        return .{ .p = .{ .buf = buf, .limit = @min(mtu, buf.len), .pos = 2 }, .stats = stats };
    }

    /// 追加一条。UUID 尺寸与本包不同或放不下 → false，打包器不变。
    pub fn add(self: *InfoBuilder, handle: u16, uuid: Uuid) bool {
        const format: InfoFormat = switch (uuid) {
            .u16 => .u16,
            .u128 => .u128,
        };
        if (self.count == 0) {
            if (!self.p.fits(format.itemLen())) return false;
            self.format = format;
            self.p.buf[1] = @backingInt(format);
        } else if (format != self.format or !self.p.fits(format.itemLen())) {
            return false;
        }
        self.p.push16(handle);
        _ = uuid.put(self.p.buf[self.p.pos..]);
        self.p.pos += uuid.wireLen();
        self.count += 1;
        return true;
    }

    /// 一条都没有 → 0；否则是 PDU 的长度。
    pub fn len(self: *const InfoBuilder) usize {
        return if (self.count == 0) 0 else self.p.pos;
    }
};

/// ATT_READ_BY_TYPE_RSP 的打包器（§3.4.4.2）。值先按 min(ATT_MTU−4, 253) 截断；截断后
/// 长度与本包第一条不同的属性不放（§3.4.4.1：值长度不同的属性要分多次请求）。
pub const TypeBuilder = struct {
    p: Pack,
    item: usize = 0,
    count: usize = 0,
    stats: *Stats,

    pub fn init(buf: []u8, mtu: usize, stats: *Stats) Error!TypeBuilder {
        if (buf.len < min_len.read_by_type_rsp or mtu < min_len.read_by_type_rsp) return error.NoSpace;
        buf[0] = @backingInt(Op.read_by_type_rsp);
        return .{ .p = .{ .buf = buf, .limit = @min(mtu, buf.len), .pos = 2 }, .stats = stats };
    }

    /// 追加一条 (句柄, 值)。与本包第一条截断后长度不同或放不下 → false。
    pub fn add(self: *TypeBuilder, handle: u16, value: []const u8) bool {
        const room = @min(self.p.limit - 4, type_rsp_value_max);
        const n = @min(value.len, room);
        if (self.item == 0) {
            self.item = 2 + n;
        } else if (self.item != 2 + n) {
            return false;
        }
        if (!self.p.fits(self.item)) return false;
        if (n < value.len) self.stats.truncated += 1;
        self.p.buf[1] = @intCast(self.item);
        self.p.push16(handle);
        self.p.push(value[0..n]);
        self.count += 1;
        return true;
    }

    pub fn len(self: *const TypeBuilder) usize {
        return if (self.count == 0) 0 else self.p.pos;
    }
};

/// ATT_READ_BY_GROUP_TYPE_RSP 的打包器（§3.4.4.10）。值先按 min(ATT_MTU−6, 251) 截断。
pub const GroupBuilder = struct {
    p: Pack,
    item: usize = 0,
    count: usize = 0,
    stats: *Stats,

    pub fn init(buf: []u8, mtu: usize, stats: *Stats) Error!GroupBuilder {
        if (buf.len < min_len.read_by_group_rsp or mtu < min_len.read_by_group_rsp) return error.NoSpace;
        buf[0] = @backingInt(Op.read_by_group_rsp);
        return .{ .p = .{ .buf = buf, .limit = @min(mtu, buf.len), .pos = 2 }, .stats = stats };
    }

    /// 追加一条 (句柄, 组尾句柄, 值)。
    pub fn add(self: *GroupBuilder, handle: u16, end: u16, value: []const u8) bool {
        const room = @min(self.p.limit - 6, group_rsp_value_max);
        const n = @min(value.len, room);
        if (self.item == 0) {
            self.item = 4 + n;
        } else if (self.item != 4 + n) {
            return false;
        }
        if (!self.p.fits(self.item)) return false;
        if (n < value.len) self.stats.truncated += 1;
        self.p.buf[1] = @intCast(self.item);
        self.p.push16(handle);
        self.p.push16(end);
        self.p.push(value[0..n]);
        self.count += 1;
        return true;
    }

    pub fn len(self: *const GroupBuilder) usize {
        return if (self.count == 0) 0 else self.p.pos;
    }
};

/// ATT_FIND_BY_TYPE_VALUE_RSP 的打包器（§3.4.3.4）：每条固定 4 字节。
pub const HandleRangeBuilder = struct {
    p: Pack,
    count: usize = 0,

    pub fn init(buf: []u8, mtu: usize) Error!HandleRangeBuilder {
        if (buf.len < min_len.find_by_type_rsp or mtu < min_len.find_by_type_rsp) return error.NoSpace;
        buf[0] = @backingInt(Op.find_by_type_rsp);
        return .{ .p = .{ .buf = buf, .limit = @min(mtu, buf.len), .pos = 1 } };
    }

    /// 追加一条 (Found Attribute Handle, Group End Handle)；放不下 → false。
    pub fn add(self: *HandleRangeBuilder, found: u16, end: u16) bool {
        if (!self.p.fits(4)) return false;
        self.p.push16(found);
        self.p.push16(end);
        self.count += 1;
        return true;
    }

    pub fn len(self: *const HandleRangeBuilder) usize {
        return if (self.count == 0) 0 else self.p.pos;
    }
};

/// ATT_READ_MULTIPLE_VARIABLE_RSP 的打包器（§3.4.4.12）。列表在 (ATT_MTU−1) 处截断：
/// 放不下整条值时截值（Value Length 仍写完整长度）；只剩 1 字节、会切在 Value Length
/// 字段里时整条不放。返回实际写入的值字节数。
pub const VarBuilder = struct {
    p: Pack,
    stats: *Stats,

    pub fn init(buf: []u8, mtu: usize, stats: *Stats) Error!VarBuilder {
        if (buf.len < min_len.read_multiple_var_rsp or mtu < min_len.read_multiple_var_rsp) return error.NoSpace;
        buf[0] = @backingInt(Op.read_multiple_var_rsp);
        return .{ .p = .{ .buf = buf, .limit = @min(mtu, buf.len), .pos = 1 }, .stats = stats };
    }

    /// 追加一个 (Value Length, Value) 元组。
    pub fn add(self: *VarBuilder, value: []const u8) usize {
        const room = self.p.limit - self.p.pos;
        if (room < 2) return 0;
        const n = @min(value.len, room - 2);
        if (n < value.len) self.stats.truncated += 1;
        self.p.push16(@intCast(value.len));
        self.p.push(value[0..n]);
        return n;
    }

    pub fn len(self: *const VarBuilder) usize {
        return self.p.pos;
    }
};

/// ATT_MULTIPLE_HANDLE_VALUE_NTF 的打包器（§3.4.7.4）：元组不得截断，放不下 → false。
pub const MultiBuilder = struct {
    p: Pack,
    count: usize = 0,

    pub fn init(buf: []u8, mtu: usize) Error!MultiBuilder {
        if (buf.len < min_len.multiple_ntf or mtu < min_len.multiple_ntf) return error.NoSpace;
        buf[0] = @backingInt(Op.multiple_ntf);
        return .{ .p = .{ .buf = buf, .limit = @min(mtu, buf.len), .pos = 1 } };
    }

    pub fn add(self: *MultiBuilder, handle: u16, value: []const u8) bool {
        if (!self.p.fits(4 + value.len)) return false;
        self.p.push16(handle);
        self.p.push16(@intCast(value.len));
        self.p.push(value);
        self.count += 1;
        return true;
    }

    pub fn len(self: *const MultiBuilder) usize {
        return if (self.count == 0) 0 else self.p.pos;
    }
};

// ---------------------------------------------------------------------------
// 逐 PDU 的编码器（解码统一走 `parse`，下面另有带类型的薄封装）
// ---------------------------------------------------------------------------

/// Exchange MTU Request：02 <Client Rx MTU:2>。表 3.5。
pub fn encodeMtuReq(out: []u8, client_mtu: u16, stats: *Stats) Error!usize {
    if (out.len < min_len.mtu_req) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.mtu_req);
    putU16(out[1..3], client_mtu);
    return min_len.mtu_req;
}

/// Exchange MTU Response：03 <Server Rx MTU:2>。表 3.6。
pub fn encodeMtuRsp(out: []u8, server_mtu: u16, stats: *Stats) Error!usize {
    if (out.len < min_len.mtu_rsp) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.mtu_rsp);
    putU16(out[1..3], server_mtu);
    stats.mtu_exchanges += 1;
    return min_len.mtu_rsp;
}

/// Find Information Request：04 <Starting Handle:2> <Ending Handle:2>。表 3.7。
pub fn encodeFindInfoReq(out: []u8, range: Range, stats: *Stats) Error!usize {
    if (out.len < min_len.find_info_req) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.find_info_req);
    putU16(out[1..3], range.start);
    putU16(out[3..5], range.end);
    return min_len.find_info_req;
}

/// Find Information Response：05 <Format:1> <Information Data>。`data` 必须是整条。
pub fn encodeFindInfoRsp(out: []u8, format: InfoFormat, data: []const u8, stats: *Stats) Error!usize {
    if (data.len == 0 or data.len % format.itemLen() != 0) return reject(stats, error.InvalidList);
    if (out.len < 2 + data.len) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.find_info_rsp);
    out[1] = @backingInt(format);
    @memcpy(out[2 .. 2 + data.len], data);
    return 2 + data.len;
}

/// Find By Type Value Request：06 <Starting Handle:2> <Ending Handle:2> <Attribute Type:2>
/// <Attribute Value>。表 3.12。
pub fn encodeFindByTypeReq(out: []u8, req: FindTypeValue, stats: *Stats) Error!usize {
    const total = min_len.find_by_type_req + req.value.len;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.find_by_type_req);
    putU16(out[1..3], req.range.start);
    putU16(out[3..5], req.range.end);
    putU16(out[5..7], req.attr_type);
    @memcpy(out[7..total], req.value);
    return total;
}

/// Find By Type Value Response：07 <Handles Information List>，每条 4 字节。表 3.13、表 3.14。
pub fn encodeFindByTypeRsp(out: []u8, list: []const HandleRange, stats: *Stats) Error!usize {
    if (list.len == 0) return reject(stats, error.Empty);
    const total = 1 + 4 * list.len;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.find_by_type_rsp);
    for (list, 0..) |h, i| {
        putU16(out[1 + 4 * i ..], h.found);
        putU16(out[3 + 4 * i ..], h.end);
    }
    return total;
}

/// Handles Information 的一条（表 3.14）。
pub const HandleRange = struct { found: u16, end: u16 };

/// ATT_FIND_BY_TYPE_VALUE_RSP 的 Handles Information List：每条 4 字节（表 3.14）。
pub const HandleRanges = struct {
    data: []const u8,

    pub fn count(self: HandleRanges) usize {
        return self.data.len / 4;
    }

    pub fn at(self: HandleRanges, i: usize) HandleRange {
        const rec = self.data[4 * i ..];
        return .{ .found = getU16(rec), .end = getU16(rec[2..]) };
    }
};

/// Read By Type Request：08 <Starting Handle:2> <Ending Handle:2> <Attribute Type:2|16>。表 3.15。
pub fn encodeReadByTypeReq(out: []u8, req: TypeReq, stats: *Stats) Error!usize {
    const total = 5 + req.uuid.wireLen();
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_by_type_req);
    putRange(out[1..5], req.range);
    _ = req.uuid.put(out[5..]);
    return total;
}

/// Read By Type Response：09 <Length:1> <Attribute Data List>。`list` 必须是 `len` 的整数条。
pub fn encodeReadByTypeRsp(out: []u8, item: u8, list: []const u8, stats: *Stats) Error!usize {
    return encodeLengthList(Op.read_by_type_rsp, out, item, list, TypeRsp.min_item, stats);
}

/// Read By Group Type Request：10 <Starting Handle:2> <Ending Handle:2> <Attribute Group Type:2|16>。
/// 表 3.24。
pub fn encodeReadByGroupReq(out: []u8, req: TypeReq, stats: *Stats) Error!usize {
    const total = 5 + req.uuid.wireLen();
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_by_group_req);
    putRange(out[1..5], req.range);
    _ = req.uuid.put(out[5..]);
    return total;
}

/// Read By Group Type Response：11 <Length:1> <Attribute Data List>。表 3.25。
pub fn encodeReadByGroupRsp(out: []u8, item: u8, list: []const u8, stats: *Stats) Error!usize {
    return encodeLengthList(Op.read_by_group_rsp, out, item, list, GroupRsp.min_item, stats);
}

fn encodeLengthList(op: Op, out: []u8, item: u8, list: []const u8, min_item: usize, stats: *Stats) Error!usize {
    if (item < min_item or list.len == 0 or list.len % item != 0) return reject(stats, error.InvalidList);
    if (out.len < 2 + list.len) return reject(stats, error.NoSpace);
    out[0] = @backingInt(op);
    out[1] = item;
    @memcpy(out[2 .. 2 + list.len], list);
    return 2 + list.len;
}

/// Read Request：0A <Attribute Handle:2>。表 3.18。
pub fn encodeReadReq(out: []u8, handle: u16, stats: *Stats) Error!usize {
    if (out.len < min_len.read_req) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_req);
    putU16(out[1..3], handle);
    return min_len.read_req;
}

/// Read Response：0B <Attribute Value>。值被截断到 `mtu - 1`（表 3.19）。
/// 返回写入的总长度（1 + 有效值长度）。
pub fn encodeReadRsp(out: []u8, value: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const n = fit(value, valueMax(.read_rsp, mtu));
    if (out.len < 1 + n) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_rsp);
    @memcpy(out[1 .. 1 + n], value[0..n]);
    noteCut(stats, n, value.len);
    stats.reads += 1;
    return 1 + n;
}

/// Read Blob Request：0C <Attribute Handle:2> <Value Offset:2>。表 3.20。
pub fn encodeReadBlobReq(out: []u8, req: BlobReq, stats: *Stats) Error!usize {
    if (out.len < min_len.read_blob_req) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_blob_req);
    putU16(out[1..3], req.handle);
    putU16(out[3..5], req.offset);
    return min_len.read_blob_req;
}

/// Read Blob Response：0D <Part Attribute Value>，截断到 `mtu - 1`（表 3.21）。
pub fn encodeReadBlobRsp(out: []u8, part: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const n = fit(part, valueMax(.read_blob_rsp, mtu));
    if (out.len < 1 + n) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_blob_rsp);
    @memcpy(out[1 .. 1 + n], part[0..n]);
    noteCut(stats, n, part.len);
    stats.reads += 1;
    return 1 + n;
}

/// Read Multiple Request / Read Multiple Variable Length Request：0E / 20 <Set Of Handles>。
/// 至少两个句柄（表 3.22、表 3.27）。
pub fn encodeReadMultipleReq(out: []u8, op: Op, handles: []const u16, stats: *Stats) Error!usize {
    if (op != .read_multiple_req and op != .read_multiple_var_req) return reject(stats, error.UnsupportedOp);
    if (handles.len < 2) return reject(stats, error.InvalidList);
    const total = 1 + 2 * handles.len;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(op);
    for (handles, 0..) |h, i| putU16(out[1 + 2 * i ..], h);
    return total;
}

/// Read Multiple Response：0F <Set Of Values>，各值首尾相接，整体截断到 `mtu - 1`（表 3.23）。
pub fn encodeReadMultipleRsp(out: []u8, values: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const n = fit(values, valueMax(.read_multiple_rsp, mtu));
    if (out.len < 1 + n) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_multiple_rsp);
    @memcpy(out[1 .. 1 + n], values[0..n]);
    noteCut(stats, n, values.len);
    stats.reads += 1;
    return 1 + n;
}

/// Read Multiple Variable Length Response：21 <Length Value Tuple List>（表 3.28）。
/// 规范允许最后一个元组被截断，所以这里只要求列表非空；按 MTU 截断请用 `VarBuilder`。
pub fn encodeReadMultipleVarRsp(out: []u8, list: []const u8, stats: *Stats) Error!usize {
    if (list.len == 0) return reject(stats, error.Empty);
    var it = TupleList{ .data = list };
    while (it.next()) |_| {}
    if (it.pos != list.len) return reject(stats, error.InvalidList);
    if (out.len < 1 + list.len) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.read_multiple_var_rsp);
    @memcpy(out[1 .. 1 + list.len], list);
    stats.reads += 1;
    return 1 + list.len;
}

/// Write Request：12 <Attribute Handle:2> <Attribute Value>。表 3.30。
pub fn encodeWriteReq(out: []u8, handle: u16, value: []const u8, stats: *Stats) Error!usize {
    return encodeWrite(Op.write_req, out, handle, value, stats);
}

/// Write Command：52 <Attribute Handle:2> <Attribute Value>。表 3.32。
pub fn encodeWriteCmd(out: []u8, handle: u16, value: []const u8, stats: *Stats) Error!usize {
    return encodeWrite(Op.write_cmd, out, handle, value, stats);
}

fn encodeWrite(op: Op, out: []u8, handle: u16, value: []const u8, stats: *Stats) Error!usize {
    const total = 3 + value.len;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(op);
    putU16(out[1..3], handle);
    @memcpy(out[3..total], value);
    return total;
}

/// ATT_SIGNED_WRITE_CMD：D2 <Attribute Handle:2> <Attribute Value> <Authentication Signature:12>。
/// 表 3.33。值长于 `mtu - 15` → `TooLong`（§4.9.2：这个子过程不能写长属性）。
/// `sig` 由 `cmac.sign` 生成。
pub fn encodeSignedWriteCmd(
    out: []u8,
    req: SignedWrite,
    mtu: u16,
    stats: *Stats,
) Error!usize {
    if (req.value.len > valueMax(.signed_write_cmd, mtu)) return reject(stats, error.TooLong);
    const total = 3 + req.value.len + 12;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.signed_write_cmd);
    putU16(out[1..3], req.handle);
    @memcpy(out[3 .. 3 + req.value.len], req.value);
    @memcpy(out[3 + req.value.len .. total], &req.sig);
    return total;
}

/// Write Response：13，单字节，无参数。表 3.31。
pub fn encodeWriteRsp(out: []u8, stats: *Stats) Error!usize {
    if (out.len < min_len.write_rsp) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.write_rsp);
    return min_len.write_rsp;
}

/// Prepare Write Request（16）/ Response（17）：<Attribute Handle:2> <Value Offset:2>
/// <Part Attribute Value>。表 3.34、表 3.35。部分值长于 `mtu - 5` → `TooLong`。
pub fn encodePrepareWrite(op: Op, out: []u8, part: Part, mtu: u16, stats: *Stats) Error!usize {
    if (op != .prepare_write_req and op != .prepare_write_rsp) return reject(stats, error.UnsupportedOp);
    if (part.value.len > valueMax(.prepare_write_req, mtu)) return reject(stats, error.TooLong);
    const total = 5 + part.value.len;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(op);
    putU16(out[1..3], part.handle);
    putU16(out[3..5], part.offset);
    @memcpy(out[5..total], part.value);
    return total;
}

/// Execute Write Request：18 <Flags:1>。表 3.36。
pub fn encodeExecuteWriteReq(out: []u8, flags: ExecuteFlags, stats: *Stats) Error!usize {
    if (out.len < min_len.execute_write_req) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.execute_write_req);
    out[1] = @backingInt(flags);
    return min_len.execute_write_req;
}

/// Execute Write Response：19，单字节，无参数。表 3.37。
pub fn encodeExecuteWriteRsp(out: []u8, stats: *Stats) Error!usize {
    if (out.len < min_len.execute_write_rsp) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.execute_write_rsp);
    return min_len.execute_write_rsp;
}

/// Handle Value Notification：1B <Attribute Handle:2> <Attribute Value>，值截断到 `mtu - 3`
/// （表 3.38）。
pub fn encodeNotify(out: []u8, handle: u16, value: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const n = try encodeHandleValue(Op.notify, out, handle, value, mtu, stats);
    stats.notifies += 1;
    return n;
}

/// Handle Value Indication：1D，布局同通知，值截断到 `mtu - 3`（表 3.39）。
pub fn encodeIndicate(out: []u8, handle: u16, value: []const u8, mtu: u16, stats: *Stats) Error!usize {
    return encodeHandleValue(Op.indicate, out, handle, value, mtu, stats);
}

fn encodeHandleValue(op: Op, out: []u8, handle: u16, value: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const n = fit(value, valueMax(op, mtu));
    const total = 3 + n;
    if (out.len < total) return reject(stats, error.NoSpace);
    out[0] = @backingInt(op);
    putU16(out[1..3], handle);
    @memcpy(out[3..total], value[0..n]);
    noteCut(stats, n, value.len);
    return total;
}
/// Handle Value Confirmation：1E，单字节，无参数。表 3.40。
pub fn encodeConfirm(out: []u8, stats: *Stats) Error!usize {
    if (out.len < min_len.confirm) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.confirm);
    return min_len.confirm;
}

/// Multiple Variable Length Notification：23 <Handle Length Value Tuple List>（表 3.41、表 3.42）。
/// 元组不得截断，任何一条放不下 → `TooLong`，不写半截。
pub fn encodeMultipleNtf(out: []u8, tuples: []const WriteReq, mtu: u16, stats: *Stats) Error!usize {
    if (tuples.len == 0) return reject(stats, error.Empty);
    var total: usize = 1;
    for (tuples) |t| total += 4 + t.value.len;
    if (total > mtu or out.len < total) return reject(stats, error.TooLong);
    var b = try MultiBuilder.init(out, mtu);
    for (tuples) |t| {
        if (!b.add(t.handle, t.value)) return reject(stats, error.TooLong);
    }
    stats.notifies += 1;
    return b.len();
}

fn putRange(out: []u8, range: Range) void {
    putU16(out[0..2], range.start);
    putU16(out[2..4], range.end);
}

// ---------------------------------------------------------------------------
// Error Response
// ---------------------------------------------------------------------------

/// Error Response：01 <Request Opcode In Error:1> <Attribute Handle In Error:2> <Error Code:1>，
/// 共 5 字节（表 3.3）。句柄为 0x0000 表示错误与具体属性无关（§3.4.1.1）。
pub fn encodeError(out: []u8, req_op: Op, handle: u16, code: Code, stats: *Stats) Error!usize {
    return encodeErrorRaw(out, @backingInt(req_op), handle, @backingInt(code), stats);
}

/// 同上，但请求操作码与错误码按原始字节给：可以是未知操作码，也可以是应用错误 0x80–0x9F。
pub fn encodeErrorRaw(out: []u8, req_op: u8, handle: u16, code: u8, stats: *Stats) Error!usize {
    if (out.len < min_len.error_rsp) return reject(stats, error.NoSpace);
    out[0] = @backingInt(Op.error_rsp);
    out[1] = req_op;
    putU16(out[2..4], handle);
    out[4] = code;
    stats.errors_emitted += 1;
    return min_len.error_rsp;
}

// ---------------------------------------------------------------------------
// 带类型的解码薄封装（都走 `parse`）
// ---------------------------------------------------------------------------

/// 协商：结果 = min(client, server_max)。client 的请求先过 decodeMtuReq 的
/// 合法性检查，所以这里只做取小。
pub fn negotiate(client_mtu: u16, server_max: u16) u16 {
    return @min(client_mtu, @min(server_max, max_mtu));
}

/// 客户端收到的 Server Rx MTU → 生效的 ATT_MTU（§3.4.2.2）：取两端之小；任一端
/// 错误地小于默认值时 ATT_MTU 不变，仍是默认值。
pub fn effectiveMtu(client_rx_mtu: u16, server_rx_mtu: u16) u16 {
    if (client_rx_mtu < default_mtu or server_rx_mtu < default_mtu) return default_mtu;
    return @min(client_rx_mtu, server_rx_mtu);
}

/// 只做长度检查的 Exchange MTU Request（server 用）：Client Rx MTU 的取值由 server 按
/// §3.4.2.2 处理，不在这里拒。
pub fn decodeMtuReqRaw(pdu: []const u8, stats: *Stats) Error!u16 {
    try exact(pdu, .mtu_req, min_len.mtu_req, stats);
    return getU16(pdu[1..3]);
}

pub fn decodeMtuReq(pdu: []const u8, stats: *Stats) Error!u16 {
    const mtu = try decodeMtuReqRaw(pdu, stats);
    // 章节时代的更严策略：小于默认值或超过本组件上限都直接拒，不发 PDU。
    if (mtu < default_mtu) return reject(stats, error.MtuTooSmall);
    if (mtu > max_mtu) return reject(stats, error.MtuTooLarge);
    return mtu;
}

pub fn decodeMtuRsp(pdu: []const u8, stats: *Stats) Error!u16 {
    // 章节时代的行为：长度或操作码不符一律 Short。
    exact(pdu, .mtu_rsp, min_len.mtu_rsp, stats) catch |e| return if (e == error.Trailing) error.Short else e;
    return getU16(pdu[1..3]);
}

pub fn decodeFindInfoReq(pdu: []const u8, stats: *Stats) Error!Range {
    try exact(pdu, .find_info_req, min_len.find_info_req, stats);
    return .{ .start = getU16(pdu[1..3]), .end = getU16(pdu[3..5]) };
}

pub fn decodeFindInfoRsp(pdu: []const u8, stats: *Stats) Error!InfoRsp {
    return (try parse(pdu, stats)).find_info_rsp;
}

pub fn decodeFindByTypeReq(pdu: []const u8, stats: *Stats) Error!FindTypeValue {
    return (try parse(pdu, stats)).find_by_type_req;
}

pub fn decodeFindByTypeRsp(pdu: []const u8, stats: *Stats) Error!HandleRanges {
    return (try parse(pdu, stats)).find_by_type_rsp;
}

pub fn decodeReadByTypeReq(pdu: []const u8, stats: *Stats) Error!TypeReq {
    return (try parse(pdu, stats)).read_by_type_req;
}

pub fn decodeReadByTypeRsp(pdu: []const u8, stats: *Stats) Error!TypeRsp {
    return (try parse(pdu, stats)).read_by_type_rsp;
}

pub fn decodeReadReq(pdu: []const u8, stats: *Stats) Error!u16 {
    try exact(pdu, .read_req, min_len.read_req, stats);
    return getU16(pdu[1..3]);
}

pub fn decodeReadRsp(pdu: []const u8, stats: *Stats) Error![]const u8 {
    const p = parse(pdu, stats) catch |e| return if (e == error.Trailing) error.Short else e;
    return p.read_rsp;
}

pub fn decodeReadBlobReq(pdu: []const u8, stats: *Stats) Error!BlobReq {
    return (try parse(pdu, stats)).read_blob_req;
}

pub fn decodeReadBlobRsp(pdu: []const u8, stats: *Stats) Error![]const u8 {
    return (try parse(pdu, stats)).read_blob_rsp;
}

pub fn decodeReadMultipleReq(pdu: []const u8, stats: *Stats) Error!Handles {
    return (try parse(pdu, stats)).read_multiple_req;
}

pub fn decodeReadMultipleVarReq(pdu: []const u8, stats: *Stats) Error!Handles {
    return (try parse(pdu, stats)).read_multiple_var_req;
}

pub fn decodeReadMultipleRsp(pdu: []const u8, stats: *Stats) Error![]const u8 {
    return (try parse(pdu, stats)).read_multiple_rsp;
}

pub fn decodeReadMultipleVarRsp(pdu: []const u8, stats: *Stats) Error!TupleList {
    return .{ .data = (try parse(pdu, stats)).read_multiple_var_rsp };
}

pub fn decodeReadByGroupReq(pdu: []const u8, stats: *Stats) Error!TypeReq {
    return (try parse(pdu, stats)).read_by_group_req;
}

pub fn decodeReadByGroupRsp(pdu: []const u8, stats: *Stats) Error!GroupRsp {
    return (try parse(pdu, stats)).read_by_group_rsp;
}

pub fn decodeWriteReq(pdu: []const u8, stats: *Stats) Error!WriteReq {
    const w = (try parse(pdu, stats)).write_req;
    stats.writes += 1;
    return w;
}

pub fn decodeWriteCmd(pdu: []const u8, stats: *Stats) Error!WriteReq {
    const w = (try parse(pdu, stats)).write_cmd;
    stats.writes += 1;
    return w;
}

pub fn decodeSignedWriteCmd(pdu: []const u8, stats: *Stats) Error!SignedWrite {
    return (try parse(pdu, stats)).signed_write_cmd;
}

pub fn decodePrepareWriteReq(pdu: []const u8, stats: *Stats) Error!Part {
    return (try parse(pdu, stats)).prepare_write_req;
}

pub fn decodePrepareWriteRsp(pdu: []const u8, stats: *Stats) Error!Part {
    return (try parse(pdu, stats)).prepare_write_rsp;
}

pub fn decodeExecuteWriteReq(pdu: []const u8, stats: *Stats) Error!ExecuteFlags {
    return (try parse(pdu, stats)).execute_write_req;
}

/// Write Response：只校验操作码与长度（单字节）。
pub fn decodeWriteRsp(pdu: []const u8, stats: *Stats) Error!void {
    try exact(pdu, .write_rsp, min_len.write_rsp, stats);
}

/// Execute Write Response：只校验操作码与长度（单字节）。
pub fn decodeExecuteWriteRsp(pdu: []const u8, stats: *Stats) Error!void {
    try exact(pdu, .execute_write_rsp, min_len.execute_write_rsp, stats);
}

/// Handle Value Confirmation：只校验操作码与长度（单字节）。
pub fn decodeConfirm(pdu: []const u8, stats: *Stats) Error!void {
    try exact(pdu, .confirm, min_len.confirm, stats);
}
pub fn decodeNotify(pdu: []const u8, stats: *Stats) Error!WriteReq {
    const p = parse(pdu, stats) catch |e| return if (e == error.Trailing) error.Short else e;
    return p.notify;
}

/// Handle Value Indication：句柄与值。
pub fn decodeIndicate(pdu: []const u8, stats: *Stats) Error!WriteReq {
    return (try parse(pdu, stats)).indicate;
}

/// Multiple Variable Length Notification 的元组列表。
pub fn decodeMultipleNtf(pdu: []const u8, stats: *Stats) Error!MultiNtf {
    return .{ .data = (try parse(pdu, stats)).multiple_ntf };
}

pub fn decodeError(pdu: []const u8, stats: *Stats) Error!ErrorRsp {
    if (pdu.len < min_len.error_rsp) return reject(stats, error.Short);
    if (pdu.len > min_len.error_rsp) return reject(stats, error.Trailing);
    return .{ .req_op = pdu[1], .handle = getU16(pdu[2..4]), .code = pdu[4] };
}

// ---------------------------------------------------------------------------
// KAT 固定字节串（判据 ③④⑥⑦ 逐字节比对）
// ---------------------------------------------------------------------------

/// Exchange MTU Request：client 报 247（0x00F7）→ 02 F7 00。
pub const kat_mtu_req = [3]u8{ 0x02, 0xf7, 0x00 };

/// Exchange MTU Response：server 回 247 → 03 F7 00。
pub const kat_mtu_rsp = [3]u8{ 0x03, 0xf7, 0x00 };

/// Read Request：句柄 0x0025 → 0A 25 00。
pub const kat_read_req = [3]u8{ 0x0a, 0x25, 0x00 };

/// Read Response：值 “ch27” → 0B 63 68 32 37。
pub const kat_read_rsp = [5]u8{ 0x0b, 'c', 'h', '2', '7' };

/// Write Request：句柄 0x0028、值 {0x01, 0x00}（CCCD 打开通知）
///   → 12 28 00 01 00。
pub const kat_write_req = [5]u8{ 0x12, 0x28, 0x00, 0x01, 0x00 };

/// Error Response：对 Read Request、句柄 0x0099、Invalid Handle
///   → 01 0A 99 00 01。
pub const kat_error_rsp = [5]u8{ 0x01, 0x0a, 0x99, 0x00, 0x01 };
