//! ble-802154：host 侧 ACL 数据包的分片与重组。
//!
//! 规范出处：Bluetooth Core 5.4 [Vol 4] Part E。
//!   * ACL 包头 = Handle(12b) | PB(2b) | BC(2b) + Data_Total_Length(16b) ——
//!     §5.4.2。同一张表规定了 LE-U 上各方向允许的 PB：
//!       Host → Controller：首片 0b00（不可自动 flush），续片 0b01；
//!       Controller → Host：首片 0b10，续片 0b01。
//!   * LE_Read_Buffer_Size 的返回决定 host 该按多长切：“The Host shall segment
//!     the data transmitted to the Controller according to these values” —— §7.8.2；
//!     LE-U 上 host 与 controller 至少要能收 27 字节数据段 —— §5.4.2。
//!   * L2CAP PDU = Length(2) + Channel ID(2) + 载荷，Length 用于接收端重组 ——
//!     [Vol 3] Part A §3.1。
//!
//! 两个方向各一个类型，都没有分配：
//!
//!   * `Segmenter`：把一个完整的 L2CAP PDU（含 4 字节头）按 controller 给的
//!     包长切成若干 ACL 包，逐个吐出。输出不含 H4 的类型字节（与 `hci.zig`
//!     的 `encodeAcl` 一致）。
//!   * `Reassembler(comptime 句柄数, comptime PDU 上限)`：按句柄把收到的 ACL
//!     片段攒回 L2CAP PDU。上限由调用方在编译期定；第一个片段一到就能从
//!     L2CAP 头读出总长，超限的 PDU 立刻丢弃并报 `Oversize`，不会先吃内存
//!     再失败。

const std = @import("std");

const hci = @import("hci.zig");

pub const Error = error{
    Short,
    Trailing,
    NoSpace,
    /// controller 给的 ACL 包长或声明的 L2CAP 长度超出缓冲。
    Oversize,
    BadParam,
    /// 收到续片，但这个句柄上没有开始过的 PDU。
    NoStart,
    /// 同时在重组的句柄数超过上限。
    NoHandle,
};

/// LE-U 上必须支持的最小 ACL 数据段长度。§5.4.2。
pub const le_acl_min_data_len: usize = 27;

/// L2CAP 基本头的长度。[Vol 3] Part A §3.1。
pub const l2cap_header_len: usize = 4;

// ---------------------------------------------------------------------------
// 发送方向：分片
// ---------------------------------------------------------------------------

/// 把一个 L2CAP PDU 切成 ACL 包。
pub const Segmenter = struct {
    handle: u12,
    sdu: []const u8,
    pkt_len: usize,
    pos: usize = 0,

    /// `acl_pkt_len` 是 LE_Read_Buffer_Size 返回的 LE_ACL_Data_Packet_Length。
    /// 为 0（没有专用 LE 缓冲）、超过本组件的 ACL 上限，或 PDU 短于 L2CAP 头
    /// → `BadParam`。
    pub fn init(handle: u12, sdu: []const u8, acl_pkt_len: u16) Error!Segmenter {
        if (handle > 0x0EFF) return error.BadParam;
        if (acl_pkt_len == 0 or acl_pkt_len > hci.acl_max_payload) return error.BadParam;
        if (sdu.len < l2cap_header_len) return error.BadParam;
        return .{ .handle = handle, .sdu = sdu, .pkt_len = acl_pkt_len };
    }

    /// 还要发几个 ACL 包。
    pub fn remaining(self: *const Segmenter) usize {
        const left = self.sdu.len - self.pos;
        return (left + self.pkt_len - 1) / self.pkt_len;
    }

    /// 写下一个 ACL 包，返回字节数；都发完了返回 null。
    ///
    /// 首片 PB=0b00、续片 PB=0b01（§5.4.2，LE-U Host→Controller）。
    pub fn next(self: *Segmenter, out: []u8) Error!?usize {
        if (self.pos >= self.sdu.len) return null;
        const left = self.sdu.len - self.pos;
        const n: usize = if (left > self.pkt_len) self.pkt_len else left;
        const total = hci.acl_header_len + n;
        if (out.len < total) return error.NoSpace;
        const hdr = hci.AclHeader{
            .handle = self.handle,
            .pb = if (self.pos == 0) .first_non_flushable else .continuation,
            .bc = .point_to_point,
            .data_len = @intCast(n),
        };
        hdr.encode(out[0..hci.acl_header_len]);
        @memcpy(out[hci.acl_header_len..total], self.sdu[self.pos .. self.pos + n]);
        self.pos += n;
        return total;
    }
};

// ---------------------------------------------------------------------------
// 接收方向：重组
// ---------------------------------------------------------------------------

/// 一次 `push` 的结果。
pub const Pushed = union(enum) {
    /// 还需要更多片段。
    partial,
    /// 一个完整的 L2CAP PDU。切片指向重组器内部的槽，在该句柄的下一次
    /// `push` 之前有效。
    complete: []const u8,
};

/// 按句柄重组 L2CAP PDU。
///
/// 首片的识别：PB 是 0b10（§5.4.2 规定的 Controller→Host 首片）或 0b00（首片，
/// 只是“不可自动 flush”；发回环/自测时出现）；0b01 是续片。0b11 在 5.4 里
/// 标为 Previously used，这里也按首片处理——它过去表示“整包”，放宽只为
/// 兼容旧 controller，板上确认实际取值后可以收紧。
pub fn Reassembler(comptime handle_count: usize, comptime pdu_max: usize) type {
    return struct {
        const Self = @This();

        /// 空槽的句柄标记：0x0F00–0x0FFF 在 §5.4.2 里是保留值。
        pub const empty_handle: u12 = 0x0FFF;

        pub const Slot = struct {
            handle: u12 = empty_handle,
            buf: [pdu_max]u8 = undefined,
            len: usize = 0,
        };

        slots: [handle_count]Slot = @splat(.{}),
        /// 被新首片打断、丢弃的半截 PDU 数。
        stale: u32 = 0,
        /// 因超限被丢弃的 PDU 数。
        dropped: u32 = 0,

        pub fn reset(self: *Self) void {
            self.slots = @splat(.{});
            self.stale = 0;
            self.dropped = 0;
        }

        fn find(self: *Self, handle: u12) ?*Slot {
            for (&self.slots) |*s| {
                if (s.handle == handle) return s;
            }
            return null;
        }

        fn drop(self: *Self, s: *Slot) void {
            s.handle = empty_handle;
            s.len = 0;
            self.dropped += 1;
        }

        fn slotFor(self: *Self, handle: u12, is_start: bool) Error!*Slot {
            if (self.find(handle)) |s| {
                if (!is_start) return s;
                // 旧 PDU 还没拼完就来了新的首片：旧的已被对端放弃，丢掉重来。
                self.stale += 1;
                s.len = 0;
                return s;
            }
            if (!is_start) return error.NoStart;
            for (&self.slots) |*s| {
                if (s.handle == empty_handle) {
                    s.handle = handle;
                    s.len = 0;
                    return s;
                }
            }
            return error.NoHandle;
        }

        /// 喂一个 ACL 包（4 字节头 + 数据段，不含 H4 类型字节）。
        pub fn push(self: *Self, packet: []const u8) Error!Pushed {
            var stats: hci.Stats = .{};
            const pkt = hci.decodeAcl(packet, &stats) catch |err| {
                if (err == error.UnsupportedEvent) return error.BadParam;
                return @errorCast(err);
            };
            const is_start = switch (pkt.header.pb) {
                .first_non_flushable, .first_flushable, .previously_used => true,
                .continuation => false,
            };
            const s = try self.slotFor(pkt.header.handle, is_start);
            if (s.len + pkt.payload.len > pdu_max) {
                self.drop(s);
                return error.Oversize;
            }
            @memcpy(s.buf[s.len .. s.len + pkt.payload.len], pkt.payload);
            s.len += pkt.payload.len;
            if (s.len < l2cap_header_len) return .partial;
            // [Vol 3] Part A §3.1：Length 是载荷长度，不含 4 字节头。
            const total = l2cap_header_len + @as(usize, std.mem.readInt(u16, s.buf[0..2], .little));
            if (total > pdu_max) {
                self.drop(s);
                return error.Oversize;
            }
            if (s.len == total) {
                const pdu = s.buf[0..s.len];
                s.handle = empty_handle;
                return .{ .complete = pdu };
            }
            if (s.len > total) {
                self.drop(s);
                return error.Trailing;
            }
            return .partial;
        }
    };
}
