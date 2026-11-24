//! ble-802154：HCI 事件分发与 host 侧的 ACL 包额度。
//!
//! 规范出处：Bluetooth Core 5.4 [Vol 4] Part E。
//!   * 事件帧 = Event_Code(1) + Parameter_Total_Length(1) + 参数 —— §5.4.4；
//!   * Command Complete —— §7.7.14；Command Status —— §7.7.15；
//!   * Disconnection Complete —— §7.7.5；Hardware Error —— §7.7.16；
//!   * Number Of Completed Packets —— §7.7.19；
//!   * LE Meta：Event_Code 0x3E，参数的第一字节是 Subevent_Code —— §7.7.65；
//!     子事件：LE Connection Complete §7.7.65.1、LE Advertising Report §7.7.65.2、
//!     LE Connection Update Complete §7.7.65.3、LE Long Term Key Request
//!     §7.7.65.5、LE Data Length Change §7.7.65.7；
//!   * 数组参数的默认顺序 —— §5.2：“ParameterA[0], ParameterB[0], ParameterA[1],
//!     ParameterB[1] …… unless noted otherwise”。
//!   * 基于包的数据流控 —— §4.1.1：每发一个 HCI 数据包，host 就认为 controller
//!     的空闲缓冲少一个；Number Of Completed Packets 把完成的数量还回来。
//!
//! 分发器只做**解码与归类**，不带回调：返回一个 tagged union，调用方自己
//! switch。两处“不认识”的处理不同，都有原文依据：
//!
//!   * 不认识的事件码 → `Event.ignored`（带上码值）。§5.4.4：“the Host shall
//!     ignore that packet”。
//!   * 不认识的 LE 子事件码 → `error.UnknownSubevent`。同样该忽略，但做成错误
//!     是为了测试能断言“确实拒了”，调用方 catch 掉即可。
//!
//! 5.4 的 LE Advertising Report（§7.7.65.2）只承载 legacy 广播：Data_Length
//! 是 0x00–0x1F，一条事件最多 0x19 条报告。扩展广播数据在另一个子事件
//! （LE Extended Advertising Report，§7.7.65.13），本文件不分发它；它由 `ext_adv.zig` 解析。

const std = @import("std");

const cmd = @import("hci_cmd.zig");
const hci = @import("hci.zig");

pub const Error = hci.Error || error{
    UnknownSubevent,
    /// 取值越界（如 Num_Reports = 0）。
    BadParam,
    /// 命令队列里已有一条未完成的命令。
    Busy,
    /// controller 没有可用的命令额度 / ACL 包额度。
    NoCredits,
    UnknownOpcode,
    BadLength,
};

// ---------------------------------------------------------------------------
// 各事件的解码结果
// ---------------------------------------------------------------------------

/// Command Status：Status + Num_HCI_Command_Packets + Command_Opcode。§7.7.15。
pub const CommandStatus = struct { status: u8, num_packets: u8, op: u16 };

/// Disconnection Complete：Status + Connection_Handle + Reason。§7.7.5。
pub const DisconnComplete = struct { status: u8, handle: u16, reason: u8 };

/// LE Connection Update Complete：Status + Connection_Handle +
/// Connection_Interval + Peripheral_Latency + Supervision_Timeout。§7.7.65.3。
pub const ConnUpdateComplete = struct {
    status: u8,
    handle: u16,
    interval: u16,
    latency: u16,
    supervision_timeout: u16,
};

/// LE Long Term Key Request：Connection_Handle + Random_Number(8) +
/// Encrypted_Diversifier(2)。§7.7.65.5。只在本地角色是 Peripheral 时出现。
pub const LtkRequest = struct { handle: u16, random: [8]u8, ediv: u16 };

/// LE Data Length Change：Connection_Handle + Max_TX_Octets + Max_TX_Time +
/// Max_RX_Octets + Max_RX_Time。§7.7.65.7。
pub const DataLengthChange = struct {
    handle: u16,
    max_tx_octets: u16,
    max_tx_time: u16,
    max_rx_octets: u16,
    max_rx_time: u16,
};

/// 一对 Connection_Handle / Num_Completed_Packets。§7.7.19。
pub const HandleCount = struct { handle: u16, count: u16 };

/// Number Of Completed Packets 能同时报告的句柄数上限。一帧最多 255 字节，
/// 理论上可塞 63 对；16 对够用，超了返回 `NoSpace`。
pub const max_completed_handles: usize = 16;

pub const CompletedPackets = struct {
    count: u8 = 0,
    pairs: [max_completed_handles]HandleCount = @splat(.{ .handle = 0, .count = 0 }),

    /// 实际解出的那些对（按值携带，不引用调用方的栈）。
    pub fn entries(self: *const CompletedPackets) []const HandleCount {
        return self.pairs[0..self.count];
    }
};

/// 一条 LE Advertising Report 能带的报告数上限（Num_Reports 0x01–0x19）。§7.7.65.2。
pub const max_adv_reports: usize = 0x19;

/// 分发结果。`le_advertising_report` 是调用方传入的 `reports` 存储里的一段，
/// 下次解码会被覆盖。
pub const Event = union(enum) {
    command_complete: hci.CommandComplete,
    command_status: CommandStatus,
    disconnection_complete: DisconnComplete,
    /// Hardware_Code。§7.7.16。
    hardware_error: u8,
    completed_packets: CompletedPackets,
    le_connection_complete: hci.ConnComplete,
    le_advertising_report: []const hci.AdvReport,
    le_connection_update_complete: ConnUpdateComplete,
    le_long_term_key_request: LtkRequest,
    le_data_length_change: DataLengthChange,
    /// 本组件不分发的事件码，调用方应忽略。§5.4.4。
    ignored: u8,
};

fn need(params: []const u8, n: usize) Error!void {
    if (params.len < n) return error.Short;
    if (params.len > n) return error.Trailing;
}

/// 解 Number Of Completed Packets 的参数：Num_Handles(1)，之后每对
/// Connection_Handle(2) + Num_Completed_Packets(2)。§7.7.19 + §5.2 的默认顺序。
pub fn decodeCompletedPackets(params: []const u8) Error!CompletedPackets {
    if (params.len < 1) return error.Short;
    const n: usize = params[0];
    if (n > max_completed_handles) return error.NoSpace;
    try need(params, 1 + 4 * n);
    var cp = CompletedPackets{ .count = @intCast(n) };
    for (0..n) |i| {
        cp.pairs[i] = .{
            .handle = std.mem.readInt(u16, params[1 + 4 * i ..][0..2], .little),
            .count = std.mem.readInt(u16, params[3 + 4 * i ..][0..2], .little),
        };
    }
    return cp;
}

/// 解 LE Advertising Report 的参数（不含子事件码）：Num_Reports(1)，然后每条
/// 报告依次是 Event_Type(1) Address_Type(1) Address(6) Data_Length(1)
/// Data(Data_Length) RSSI(1)。§7.7.65.2。
fn decodeAdvReports(
    params: []const u8,
    reports: *[max_adv_reports]hci.AdvReport,
    stats: *hci.Stats,
) Error![]const hci.AdvReport {
    if (params.len < 1) return error.Short;
    const n: usize = params[0];
    // Num_Reports 的范围是 0x01–0x19。
    if (n == 0 or n > reports.len) return error.BadParam;
    var rest = params[1..];
    for (0..n) |i| {
        if (rest.len < hci.adv_report_min) return error.Short;
        const dlen: usize = rest[8];
        if (dlen > hci.adv_data_max) return error.Oversize;
        const size = hci.adv_report_min + dlen;
        if (rest.len < size) return error.Short;
        reports[i] = try hci.decodeAdvReport(rest[0..size], stats);
        rest = rest[size..];
    }
    if (rest.len != 0) return error.Trailing;
    return reports[0..n];
}

/// 按事件码解一段事件参数。`code` 是 Event_Code；LE Meta（0x3E）时
/// `params[0]` 必须是子事件码。
pub fn decodeParams(
    code: u8,
    params: []const u8,
    reports: *[max_adv_reports]hci.AdvReport,
) Error!Event {
    var stats: hci.Stats = .{};
    switch (code) {
        hci.evt_command_complete => {
            const cc = try hci.decodeCommandComplete(params, &stats);
            return .{ .command_complete = cc };
        },
        hci.evt_command_status => {
            try need(params, 4);
            return .{ .command_status = .{
                .status = params[0],
                .num_packets = params[1],
                .op = std.mem.readInt(u16, params[2..4], .little),
            } };
        },
        hci.evt_disconnection_complete => {
            try need(params, 4);
            return .{ .disconnection_complete = .{
                .status = params[0],
                .handle = std.mem.readInt(u16, params[1..3], .little),
                .reason = params[3],
            } };
        },
        hci.evt_hardware_error => {
            try need(params, 1);
            return .{ .hardware_error = params[0] };
        },
        hci.evt_number_of_completed_packets => {
            return .{ .completed_packets = try decodeCompletedPackets(params) };
        },
        hci.evt_le_meta => {
            if (params.len < 1) return error.Short;
            const sub = params[0];
            const body = params[1..];
            switch (sub) {
                hci.le_connection_complete => {
                    const cc = try hci.decodeConnComplete(body, &stats);
                    return .{ .le_connection_complete = cc };
                },
                hci.le_advertising_report => {
                    const list = try decodeAdvReports(body, reports, &stats);
                    return .{ .le_advertising_report = list };
                },
                hci.le_connection_update_complete => {
                    try need(body, 9);
                    return .{ .le_connection_update_complete = .{
                        .status = body[0],
                        .handle = std.mem.readInt(u16, body[1..3], .little),
                        .interval = std.mem.readInt(u16, body[3..5], .little),
                        .latency = std.mem.readInt(u16, body[5..7], .little),
                        .supervision_timeout = std.mem.readInt(u16, body[7..9], .little),
                    } };
                },
                hci.le_long_term_key_request => {
                    try need(body, 12);
                    return .{ .le_long_term_key_request = .{
                        .handle = std.mem.readInt(u16, body[0..2], .little),
                        .random = body[2..10].*,
                        .ediv = std.mem.readInt(u16, body[10..12], .little),
                    } };
                },
                hci.le_data_length_change => {
                    try need(body, 10);
                    return .{ .le_data_length_change = .{
                        .handle = std.mem.readInt(u16, body[0..2], .little),
                        .max_tx_octets = std.mem.readInt(u16, body[2..4], .little),
                        .max_tx_time = std.mem.readInt(u16, body[4..6], .little),
                        .max_rx_octets = std.mem.readInt(u16, body[6..8], .little),
                        .max_rx_time = std.mem.readInt(u16, body[8..10], .little),
                    } };
                },
                else => return error.UnknownSubevent,
            }
        },
        else => return .{ .ignored = code },
    }
}

/// 解一帧完整事件（H4 04 + 事件码 + 参数长度 + 参数）并分发。
pub fn decodeEvent(
    frame: []const u8,
    reports: *[max_adv_reports]hci.AdvReport,
) Error!Event {
    var stats: hci.Stats = .{};
    const ev = try hci.decodeEventFrame(frame, &stats);
    return decodeParams(ev.code, ev.params, reports);
}

// ---------------------------------------------------------------------------
// ACL 包额度（§4.1.1）
// ---------------------------------------------------------------------------

/// host 侧的 ACL 包额度：总量来自 LE_Read_Buffer_Size 的
/// Total_Num_LE_ACL_Data_Packets；每发一个包 `take` 一个；Number Of Completed
/// Packets 还回多少就加多少，但不会超过总量（controller 多报的部分丢弃并计数）。
pub const Credits = struct {
    total: u8 = 0,
    free: u8 = 0,
    /// LE_ACL_Data_Packet_Length：每个 ACL 包数据段的上限。0 表示没有专用 LE 缓冲。
    acl_pkt_len: u16 = 0,
    /// 被丢弃的多余额度（controller 报的完成数超过在途数）。
    over_release: u32 = 0,

    pub fn fromBufferSizeV1(b: cmd.BufferSizeV1) Credits {
        return .{
            .total = b.total_num_le_acl_packets,
            .free = b.total_num_le_acl_packets,
            .acl_pkt_len = b.le_acl_data_packet_length,
        };
    }

    pub fn fromBufferSizeV2(b: cmd.BufferSizeV2) Credits {
        return fromBufferSizeV1(.{
            .status = b.status,
            .le_acl_data_packet_length = b.le_acl_data_packet_length,
            .total_num_le_acl_packets = b.total_num_le_acl_packets,
        });
    }

    pub fn outstanding(self: Credits) u16 {
        return @as(u16, self.total) - @as(u16, self.free);
    }

    pub fn take(self: *Credits) error{NoCredits}!void {
        if (self.free == 0) return error.NoCredits;
        self.free -= 1;
    }

    /// 还回 `n` 个包的额度。
    pub fn release(self: *Credits, n: u16) void {
        const room = self.outstanding();
        const add: u16 = if (n > room) room else n;
        self.over_release += @intCast(n - add);
        self.free += @intCast(add);
    }

    pub fn onCompleted(self: *Credits, cp: CompletedPackets) void {
        for (cp.entries()) |hc| self.release(hc.count);
    }
};

// ---------------------------------------------------------------------------
// 把命令流控与 ACL 额度接起来的 host 状态
// ---------------------------------------------------------------------------

/// 一台 host 需要记住的 HCI 状态：命令额度、ACL 包额度、最近一次连接。
pub const Host = struct {
    ctl: cmd.Ctl = .{},
    credits: Credits = .{},
    /// 最近一条 Command Status 的 Status；0 表示命令已被受理。
    last_status: u8 = 0,
    reports: [max_adv_reports]hci.AdvReport = undefined,
    ignored: u32 = 0,

    /// 发一条命令：先占命令额度，再打包。队列里有未完成的命令 → `Busy`。
    pub fn send(self: *Host, out: []u8, op: u16, params: []const u8) Error!usize {
        try self.ctl.begin(op);
        return cmd.command(out, op, params);
    }

    /// 喂一帧事件：解码、更新命令额度与 ACL 额度，把事件交给调用方。
    ///
    /// 不认识的 LE 子事件码按 §5.4.4 应当忽略；这里返回 `UnknownSubevent` 而
    /// 不是静默吞掉，调用方用 `catch` 计数即可（`ignored` 只记不认识的事件码）。
    pub fn onEvent(self: *Host, frame: []const u8) Error!Event {
        var stats: hci.Stats = .{};
        const ev = try hci.decodeEventFrame(frame, &stats);
        return self.onParams(ev.code, ev.params);
    }

    fn onParams(self: *Host, code: u8, params: []const u8) Error!Event {
        var stats: hci.Stats = .{};
        switch (code) {
            hci.evt_command_complete => {
                const cc = try hci.decodeCommandComplete(params, &stats);
                _ = self.ctl.settle(cc.op, cc.num_packets);
                // LE_Read_Buffer_Size 的返回就是 ACL 额度的初值（§4.1.1）。
                if (cc.op == cmd.op_le_read_buffer_size_v1 or cc.op == cmd.op_le_read_buffer_size_v2) {
                    if (cmd.parseReturn(cc.op, cc.ret)) |ret| {
                        switch (ret) {
                            .le_buffer_size_v1 => |b| self.credits = Credits.fromBufferSizeV1(b),
                            .le_buffer_size_v2 => |b| self.credits = Credits.fromBufferSizeV2(b),
                            else => {},
                        }
                    } else |_| {}
                }
                return .{ .command_complete = cc };
            },
            hci.evt_command_status => {
                try need(params, 4);
                const cs = CommandStatus{
                    .status = params[0],
                    .num_packets = params[1],
                    .op = std.mem.readInt(u16, params[2..4], .little),
                };
                _ = self.ctl.settle(cs.op, cs.num_packets);
                self.last_status = cs.status;
                return .{ .command_status = cs };
            },
            hci.evt_number_of_completed_packets => {
                const cp = try decodeCompletedPackets(params);
                self.credits.onCompleted(cp);
                return .{ .completed_packets = cp };
            },
            hci.evt_le_meta => {
                if (params.len < 1) return error.Short;
                if (params[0] == hci.le_advertising_report) {
                    const list = try decodeAdvReports(params[1..], &self.reports, &stats);
                    return .{ .le_advertising_report = list };
                }
                return decodeParams(code, params, &self.reports);
            },
            else => {
                const ev = try decodeParams(code, params, &self.reports);
                if (ev == .ignored) self.ignored += 1;
                return ev;
            },
        }
    }
};
