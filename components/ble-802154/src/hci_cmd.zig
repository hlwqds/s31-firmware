//! ble-802154：HCI 控制命令的编码、返回参数解析与命令流控。
//!
//! 规范出处：Bluetooth Core 5.4 [Vol 4] Part E。每个编码器上方标了小节号；
//! OpCode 由 OGF/OCF 合成（§5.4.1：OCF 占低 10 位、OGF 占高 6 位）。OGF 的
//! 取值来自各章的开头一句：Link Control 0x01（§7.1）、HCI Control and Baseband
//! 0x03（§7.3）、Informational Parameters 0x04（§7.4）、LE Controller 0x08（§7.8）。
//!
//! 三条贯穿全文件的约定：
//!
//!   * **字节序**：§5.2 “Least Significant Octet is transmitted first”，所有多字节
//!     参数小端。6 字节地址也按这个顺序原样放，最低有效字节在前。
//!   * **两种完成方式**（§4.4）：大多数命令回 Command Complete（带返回参数）；
//!     Disconnect、LE_Create_Connection、LE_Connection_Update、LE_Enable_Encryption
//!     回 Command Status（不带返回参数），真正的结果走后续事件。`expects`
//!     给出每个 OpCode 属于哪一种。
//!   * **出错时只有 Status**：Command Complete 的返回参数以 Status 开头，
//!     失败时 controller 可以只回这一个字节（§7.4.6 对 Read_BD_ADDR 明说，
//!     其它命令同样适用）。`parseReturn` 接受“失败 + 仅 Status”，但“成功 +
//!     参数不全”是 `Short`。
//!
//! 编码器输出**完整的 H4 命令帧**（01 + OpCode + 长度 + 参数），可以直接与
//! `vectors.zig` 里按条款排出来的字节逐字节比。输出缓冲不够 → `NoSpace`，
//! 值越界 → `BadParam`；两者都不写半个字节。

const std = @import("std");

const gap = @import("gap_adv.zig");
const hci = @import("hci.zig");

pub const Error = hci.Error || error{ BadParam, BadLength, UnknownOpcode };

// ---------------------------------------------------------------------------
// OpCode
// ---------------------------------------------------------------------------

pub const ogf_link_control: u6 = 0x01;
pub const ogf_controller_baseband: u6 = 0x03;
pub const ogf_informational: u6 = 0x04;
pub const ogf_le_controller: u6 = hci.ogf_le_controller;

/// HCI_Reset。§7.3.2。
pub const op_reset: u16 = hci.opcode(ogf_controller_baseband, 0x0003);
/// HCI_Disconnect。§7.1.6。
pub const op_disconnect: u16 = hci.opcode(ogf_link_control, 0x0006);
/// HCI_Read_Local_Version_Information。§7.4.1。
pub const op_read_local_version: u16 = hci.opcode(ogf_informational, 0x0001);
/// HCI_Read_Local_Supported_Features。§7.4.3。
pub const op_read_local_supported_features: u16 = hci.opcode(ogf_informational, 0x0003);
/// HCI_Read_BD_ADDR。§7.4.6。
pub const op_read_bd_addr: u16 = hci.opcode(ogf_informational, 0x0009);

/// LE_Set_Event_Mask。§7.8.1。
pub const op_le_set_event_mask: u16 = hci.opcode(ogf_le_controller, 0x0001);
/// LE_Read_Buffer_Size [v1]。§7.8.2。
pub const op_le_read_buffer_size_v1: u16 = hci.opcode(ogf_le_controller, 0x0002);
/// LE_Read_Local_Supported_Features。§7.8.3。
pub const op_le_read_local_supported_features: u16 = hci.opcode(ogf_le_controller, 0x0003);
/// LE_Set_Random_Address。§7.8.4。
pub const op_le_set_random_address: u16 = hci.opcode(ogf_le_controller, 0x0005);
/// LE_Set_Advertising_Parameters。§7.8.5。
pub const op_le_set_advertising_parameters: u16 = hci.opcode(ogf_le_controller, 0x0006);
/// LE_Set_Advertising_Data。§7.8.7。
pub const op_le_set_advertising_data: u16 = hci.opcode(ogf_le_controller, 0x0008);
/// LE_Set_Scan_Response_Data。§7.8.8。
pub const op_le_set_scan_response_data: u16 = hci.opcode(ogf_le_controller, 0x0009);
/// LE_Set_Advertising_Enable。§7.8.9（5.4 标题仍写 7.8.9 的 “formerly called
/// LE Set Advertise Enable” 脚注）。
pub const op_le_set_advertising_enable: u16 = hci.opcode(ogf_le_controller, 0x000a);
/// LE_Set_Scan_Parameters。§7.8.10。
pub const op_le_set_scan_parameters: u16 = hci.opcode(ogf_le_controller, 0x000b);
/// LE_Set_Scan_Enable。§7.8.11。
pub const op_le_set_scan_enable: u16 = hci.opcode(ogf_le_controller, 0x000c);
/// LE_Create_Connection。§7.8.12。
pub const op_le_create_connection: u16 = hci.opcode(ogf_le_controller, 0x000d);
/// LE_Connection_Update。§7.8.18。
pub const op_le_connection_update: u16 = hci.opcode(ogf_le_controller, 0x0013);
/// LE_Enable_Encryption（旧名 LE_Start_Encryption）。§7.8.24。
pub const op_le_enable_encryption: u16 = hci.opcode(ogf_le_controller, 0x0019);
/// LE_Long_Term_Key_Request_Reply。§7.8.25。
pub const op_le_long_term_key_request_reply: u16 = hci.opcode(ogf_le_controller, 0x001a);
/// LE_Long_Term_Key_Request_Negative_Reply。§7.8.26。
pub const op_le_long_term_key_request_negative_reply: u16 = hci.opcode(ogf_le_controller, 0x001b);
/// LE_Read_Supported_States（任务书称 LE_Read_Local_Supported_States）。§7.8.27。
pub const op_le_read_supported_states: u16 = hci.opcode(ogf_le_controller, 0x001c);
/// LE_Set_Data_Length。§7.8.33。
pub const op_le_set_data_length: u16 = hci.opcode(ogf_le_controller, 0x0022);
/// LE_Read_Buffer_Size [v2]。§7.8.2。
pub const op_le_read_buffer_size_v2: u16 = hci.opcode(ogf_le_controller, 0x0060);
/// LE_Read_Maximum_Data_Length。§7.8.46。
pub const op_le_read_maximum_data_length: u16 = hci.opcode(ogf_le_controller, 0x002f);

/// 一个命令由哪种事件报告“已受理”。§4.4。
pub const Expect = enum { command_complete, command_status };

/// 本组件认识的 OpCode 才有结果；`null` 表示不认识。
pub fn expects(op: u16) ?Expect {
    return switch (op) {
        op_disconnect,
        op_le_create_connection,
        op_le_connection_update,
        op_le_enable_encryption,
        => .command_status,
        op_reset,
        op_read_local_version,
        op_read_local_supported_features,
        op_read_bd_addr,
        op_le_set_event_mask,
        op_le_read_buffer_size_v1,
        op_le_read_buffer_size_v2,
        op_le_read_local_supported_features,
        op_le_set_random_address,
        op_le_set_advertising_parameters,
        op_le_set_advertising_data,
        op_le_set_scan_response_data,
        op_le_set_advertising_enable,
        op_le_set_scan_parameters,
        op_le_set_scan_enable,
        op_le_read_supported_states,
        op_le_long_term_key_request_reply,
        op_le_long_term_key_request_negative_reply,
        op_le_set_data_length,
        op_le_read_maximum_data_length,
        => .command_complete,
        else => null,
    };
}

/// 返回参数只有 Status 的命令。
fn returnsOnlyStatus(op: u16) bool {
    return switch (op) {
        op_reset,
        op_le_set_event_mask,
        op_le_set_random_address,
        op_le_set_advertising_parameters,
        op_le_set_advertising_data,
        op_le_set_scan_response_data,
        op_le_set_advertising_enable,
        op_le_set_scan_parameters,
        op_le_set_scan_enable,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// 状态码（[Vol 1] Part F §2 的错误码表，只列本组件用到的）
// ---------------------------------------------------------------------------

pub const Status = enum(u8) {
    success = 0x00,
    authentication_failure = 0x05,
    connection_timeout = 0x08,
    command_disallowed = 0x0C,
    invalid_hci_command_parameters = 0x12,
    remote_user_terminated_connection = 0x13,
    connection_terminated_by_local_host = 0x16,
    unsupported_remote_feature = 0x1A,
    ll_response_timeout = 0x22,
    instant_passed = 0x28,
    unacceptable_connection_parameters = 0x3B,
    /// 连接没能建立 / 同步超时（LE_Create_Connection 失败时的典型值）。
    connection_failed_to_be_established = 0x3E,
    limit_reached = 0x43,
    _,
};

// ---------------------------------------------------------------------------
// 参数结构
// ---------------------------------------------------------------------------

/// 连接参数。范围与单位见 §7.8.12 / §7.8.18：间隔 0x0006–0x0C80（N × 1.25 ms），
/// Max_Latency 0x0000–0x01F3，Supervision_Timeout 0x000A–0x0C80（N × 10 ms），
/// Min/Max_CE_Length 0x0000–0xFFFF（N × 0.625 ms）。
pub const ConnParams = struct {
    interval_min: u16 = 0x0018,
    interval_max: u16 = 0x0028,
    max_latency: u16 = 0x0000,
    supervision_timeout: u16 = 0x00C8,
    min_ce_length: u16 = 0x0000,
    max_ce_length: u16 = 0x0000,

    pub const interval_lo: u16 = 0x0006;
    pub const interval_hi: u16 = 0x0C80;
    pub const latency_max: u16 = 0x01F3;
    pub const timeout_lo: u16 = 0x000A;
    pub const timeout_hi: u16 = 0x0C80;
    /// 6 个字段各 2 字节。
    pub const packed_len: usize = 12;

    pub fn validate(self: ConnParams) Error!void {
        const in = struct {
            fn f(v: u16, lo: u16, hi: u16) bool {
                return v >= lo and v <= hi;
            }
        }.f;
        if (!in(self.interval_min, interval_lo, interval_hi)) return error.BadParam;
        if (!in(self.interval_max, interval_lo, interval_hi)) return error.BadParam;
        if (self.interval_min > self.interval_max) return error.BadParam;
        if (self.max_latency > latency_max) return error.BadParam;
        if (!in(self.supervision_timeout, timeout_lo, timeout_hi)) return error.BadParam;
        if (self.min_ce_length > self.max_ce_length) return error.BadParam;
    }

    fn pack(self: ConnParams, out: *[packed_len]u8) void {
        std.mem.writeInt(u16, out[0..2], self.interval_min, .little);
        std.mem.writeInt(u16, out[2..4], self.interval_max, .little);
        std.mem.writeInt(u16, out[4..6], self.max_latency, .little);
        std.mem.writeInt(u16, out[6..8], self.supervision_timeout, .little);
        std.mem.writeInt(u16, out[8..10], self.min_ce_length, .little);
        std.mem.writeInt(u16, out[10..12], self.max_ce_length, .little);
    }
};

/// LE_Create_Connection 的 12 个参数（§7.8.12）。扫描间隔/窗口 0x0004–0x4000
/// （N × 0.625 ms）；Initiator_Filter_Policy 0x00/0x01；Peer_Address_Type
/// 0x00–0x03（0x02/0x03 是身份地址，配合本地解析列表）。
pub const CreateConn = struct {
    scan_interval: u16 = 0x0010,
    scan_window: u16 = 0x0010,
    initiator_filter_policy: u8 = 0x00,
    peer_addr_type: u8 = 0x00,
    peer_addr: gap.Addr = .{},
    own_addr_type: gap.OwnAddrType = .public,
    conn: ConnParams = .{},

    pub const scan_range_lo: u16 = 0x0004;
    pub const scan_range_hi: u16 = 0x4000;
    /// 2+2+1+1+6+1+12。
    pub const packed_len: usize = 25;

    pub fn validate(self: CreateConn) Error!void {
        const in = struct {
            fn f(v: u16) bool {
                return v >= scan_range_lo and v <= scan_range_hi;
            }
        }.f;
        if (!in(self.scan_interval) or !in(self.scan_window)) return error.BadParam;
        if (self.scan_window > self.scan_interval) return error.BadParam;
        if (self.initiator_filter_policy > 0x01) return error.BadParam;
        if (self.peer_addr_type > 0x03) return error.BadParam;
        try self.conn.validate();
    }

    pub fn pack(self: CreateConn, out: *[packed_len]u8) Error!void {
        try self.validate();
        std.mem.writeInt(u16, out[0..2], self.scan_interval, .little);
        std.mem.writeInt(u16, out[2..4], self.scan_window, .little);
        out[4] = self.initiator_filter_policy;
        out[5] = self.peer_addr_type;
        @memcpy(out[6..12], &self.peer_addr.bytes);
        out[12] = @backingInt(self.own_addr_type);
        self.conn.pack(out[13..25]);
    }
};

/// LE_Set_Scan_Parameters 的 5 个参数（§7.8.10）。间隔/窗口 0x0004–0x4000，
/// 窗口 “shall always be set to a value smaller or equal to” 间隔；
/// Scanning_Filter_Policy 0x00–0x03。
pub const ScanParams = struct {
    /// false = 0x00 被动扫描，true = 0x01 主动扫描。
    active: bool = false,
    interval: u16 = 0x0010,
    window: u16 = 0x0010,
    own_addr_type: gap.OwnAddrType = .public,
    filter_policy: u8 = 0x00,

    /// 1+2+2+1+1。
    pub const packed_len: usize = 7;

    pub fn validate(self: ScanParams) Error!void {
        const in = struct {
            fn f(v: u16) bool {
                return v >= CreateConn.scan_range_lo and v <= CreateConn.scan_range_hi;
            }
        }.f;
        if (!in(self.interval) or !in(self.window)) return error.BadParam;
        if (self.window > self.interval) return error.BadParam;
        if (self.filter_policy > 0x03) return error.BadParam;
    }

    pub fn pack(self: ScanParams, out: *[packed_len]u8) Error!void {
        try self.validate();
        out[0] = @intFromBool(self.active);
        std.mem.writeInt(u16, out[1..3], self.interval, .little);
        std.mem.writeInt(u16, out[3..5], self.window, .little);
        out[5] = @backingInt(self.own_addr_type);
        out[6] = self.filter_policy;
    }
};

// ---------------------------------------------------------------------------
// 编码器：每个返回完整 H4 命令帧的长度
// ---------------------------------------------------------------------------

fn noParams(out: []u8, op: u16) Error!usize {
    return hci.packCommand(out, op, &.{});
}

/// HCI_Reset。§7.3.2：无命令参数。
pub fn reset(out: []u8) Error!usize {
    return noParams(out, op_reset);
}

/// HCI_Read_Local_Version_Information。§7.4.1。
pub fn readLocalVersion(out: []u8) Error!usize {
    return noParams(out, op_read_local_version);
}

/// HCI_Read_Local_Supported_Features。§7.4.3。
pub fn readLocalSupportedFeatures(out: []u8) Error!usize {
    return noParams(out, op_read_local_supported_features);
}

/// HCI_Read_BD_ADDR。§7.4.6。
pub fn readBdAddr(out: []u8) Error!usize {
    return noParams(out, op_read_bd_addr);
}

/// HCI_Disconnect：Connection_Handle(2，只有低 12 位有意义) + Reason(1)。
/// Reason 的合法值见 §7.1.6。句柄超过 0x0EFF → `BadParam`。
pub fn disconnect(out: []u8, handle: u16, reason: u8) Error!usize {
    if (handle > 0x0EFF) return error.BadParam;
    var p: [3]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], handle, .little);
    p[2] = reason;
    return hci.packCommand(out, op_disconnect, &p);
}

/// LE_Set_Event_Mask：8 字节掩码。bit n 对应 LE 子事件 n+1（§7.8.1 的位表），
/// 默认值是 bit 0–4（0x1F）。
pub fn leSetEventMask(out: []u8, mask: u64) Error!usize {
    var p: [8]u8 = undefined;
    std.mem.writeInt(u64, &p, mask, .little);
    return hci.packCommand(out, op_le_set_event_mask, &p);
}

/// LE_Read_Buffer_Size [v1]。§7.8.2。
pub fn leReadBufferSize(out: []u8) Error!usize {
    return noParams(out, op_le_read_buffer_size_v1);
}

/// LE_Read_Buffer_Size [v2]：多两个 ISO 的返回参数。§7.8.2。
pub fn leReadBufferSizeV2(out: []u8) Error!usize {
    return noParams(out, op_le_read_buffer_size_v2);
}

/// LE_Read_Local_Supported_Features。§7.8.3。
pub fn leReadLocalSupportedFeatures(out: []u8) Error!usize {
    return noParams(out, op_le_read_local_supported_features);
}

/// LE_Set_Random_Address：Random_Address(6)。§7.8.4。
pub fn leSetRandomAddress(out: []u8, addr: gap.Addr) Error!usize {
    return hci.packCommand(out, op_le_set_random_address, &addr.bytes);
}

/// LE_Set_Advertising_Parameters：8 个参数共 15 字节。§7.8.5。取值先过
/// `gap.AdvParams.validate`。
pub fn leSetAdvertisingParameters(out: []u8, p: gap.AdvParams) Error!usize {
    var buf: [gap.AdvParams.packed_len]u8 = undefined;
    try p.pack(&buf);
    return hci.packCommand(out, op_le_set_advertising_parameters, &buf);
}

/// LE_Set_Advertising_Data 的参数：Advertising_Data_Length(1，0x00–0x1F) +
/// 31 字节定长数据。§7.8.7。数据超过 31 → `NoSpace`。
pub fn leSetAdvertisingData(out: []u8, ad: []const u8) Error!usize {
    var p: [1 + gap.adv_data_max]u8 = undefined;
    try packFixed31(&p, ad);
    return hci.packCommand(out, op_le_set_advertising_data, &p);
}

/// LE_Set_Scan_Response_Data：布局同广播数据。§7.8.8。
pub fn leSetScanResponseData(out: []u8, ad: []const u8) Error!usize {
    var p: [1 + gap.adv_data_max]u8 = undefined;
    try packFixed31(&p, ad);
    return hci.packCommand(out, op_le_set_scan_response_data, &p);
}

fn packFixed31(out: *[1 + gap.adv_data_max]u8, ad: []const u8) Error!void {
    if (ad.len > gap.adv_data_max) return error.NoSpace;
    out[0] = @intCast(ad.len);
    @memcpy(out[1 .. 1 + ad.len], ad);
    @memset(out[1 + ad.len ..], 0);
}

/// LE_Set_Advertising_Enable：Advertising_Enable(1，0x00/0x01)。§7.8.9。
pub fn leSetAdvertisingEnable(out: []u8, enable: bool) Error!usize {
    return hci.packCommand(out, op_le_set_advertising_enable, &[_]u8{@intFromBool(enable)});
}

/// LE_Set_Scan_Parameters：5 个参数共 7 字节。§7.8.10。
pub fn leSetScanParameters(out: []u8, p: ScanParams) Error!usize {
    var buf: [ScanParams.packed_len]u8 = undefined;
    try p.pack(&buf);
    return hci.packCommand(out, op_le_set_scan_parameters, &buf);
}

/// LE_Set_Scan_Enable：LE_Scan_Enable(1) + Filter_Duplicates(1)。§7.8.11。
pub fn leSetScanEnable(out: []u8, enable: bool, filter_duplicates: bool) Error!usize {
    return hci.packCommand(out, op_le_set_scan_enable, &[_]u8{ @intFromBool(enable), @intFromBool(filter_duplicates) });
}

/// LE_Create_Connection：12 个参数共 25 字节。§7.8.12。回 Command Status。
pub fn leCreateConnection(out: []u8, p: CreateConn) Error!usize {
    var buf: [CreateConn.packed_len]u8 = undefined;
    try p.pack(&buf);
    return hci.packCommand(out, op_le_create_connection, &buf);
}

/// LE_Connection_Update：Connection_Handle(2) + 6 个连接参数。§7.8.18。
/// 回 Command Status。
pub fn leConnectionUpdate(out: []u8, handle: u16, p: ConnParams) Error!usize {
    if (handle > 0x0EFF) return error.BadParam;
    try p.validate();
    var buf: [2 + ConnParams.packed_len]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], handle, .little);
    p.pack(buf[2..14]);
    return hci.packCommand(out, op_le_connection_update, &buf);
}

/// LE_Read_Supported_States。§7.8.27。
pub fn leReadSupportedStates(out: []u8) Error!usize {
    return noParams(out, op_le_read_supported_states);
}

/// LE_Enable_Encryption：Connection_Handle(2) + Random_Number(8) +
/// Encrypted_Diversifier(2) + Long_Term_Key(16)。§7.8.24。只用于本机是
/// Central 的连接；回 Command Status。本组件不实现加密本身，只负责把
/// SMP 算出的参数原样交给 controller。
pub fn leEnableEncryption(out: []u8, handle: u16, random: [8]u8, ediv: u16, ltk: [16]u8) Error!usize {
    if (handle > 0x0EFF) return error.BadParam;
    var buf: [28]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], handle, .little);
    @memcpy(buf[2..10], &random);
    std.mem.writeInt(u16, buf[10..12], ediv, .little);
    @memcpy(buf[12..28], &ltk);
    return hci.packCommand(out, op_le_enable_encryption, &buf);
}

/// LE_Long_Term_Key_Request_Reply：Connection_Handle(2) + Long_Term_Key(16)。
/// §7.8.25。只用于本机是 Peripheral 的连接。
pub fn leLongTermKeyRequestReply(out: []u8, handle: u16, ltk: [16]u8) Error!usize {
    if (handle > 0x0EFF) return error.BadParam;
    var buf: [18]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], handle, .little);
    @memcpy(buf[2..18], &ltk);
    return hci.packCommand(out, op_le_long_term_key_request_reply, &buf);
}

/// LE_Long_Term_Key_Request_Negative_Reply：Connection_Handle(2)。§7.8.26。
pub fn leLongTermKeyRequestNegativeReply(out: []u8, handle: u16) Error!usize {
    if (handle > 0x0EFF) return error.BadParam;
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, handle, .little);
    return hci.packCommand(out, op_le_long_term_key_request_negative_reply, &buf);
}

/// LE_Set_Data_Length：Connection_Handle(2) + TX_Octets(2，0x001B–0x00FB) +
/// TX_Time(2，0x0148–0x4290)。§7.8.33。
pub fn leSetDataLength(out: []u8, handle: u16, tx_octets: u16, tx_time: u16) Error!usize {
    if (handle > 0x0EFF) return error.BadParam;
    if (tx_octets < 0x001B or tx_octets > 0x00FB) return error.BadParam;
    if (tx_time < 0x0148 or tx_time > 0x4290) return error.BadParam;
    var buf: [6]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], handle, .little);
    std.mem.writeInt(u16, buf[2..4], tx_octets, .little);
    std.mem.writeInt(u16, buf[4..6], tx_time, .little);
    return hci.packCommand(out, op_le_set_data_length, &buf);
}

/// LE_Read_Maximum_Data_Length。§7.8.46。
pub fn leReadMaximumDataLength(out: []u8) Error!usize {
    return noParams(out, op_le_read_maximum_data_length);
}

/// 通用透传：OpCode + 原样参数。用于本组件没有专门编码器的命令。
pub fn command(out: []u8, op: u16, params: []const u8) Error!usize {
    return hci.packCommand(out, op, params);
}

// ---------------------------------------------------------------------------
// 返回参数解析
// ---------------------------------------------------------------------------

/// Read_Local_Version_Information 的 6 个返回参数。§7.4.1。
pub const LocalVersion = struct {
    status: u8,
    hci_version: u8,
    hci_subversion: u16,
    lmp_version: u8,
    company_identifier: u16,
    lmp_subversion: u16,
};

/// LE_Read_Buffer_Size [v1]：LE_ACL_Data_Packet_Length(2) +
/// Total_Num_LE_ACL_Data_Packets(1)。长度为 0 表示没有专用 LE 缓冲，要改问
/// HCI_Read_Buffer_Size。§7.8.2。
pub const BufferSizeV1 = struct {
    status: u8,
    le_acl_data_packet_length: u16,
    total_num_le_acl_packets: u8,
};

/// LE_Read_Buffer_Size [v2]：在 v1 之后多 ISO_Data_Packet_Length(2) +
/// Total_Num_ISO_Data_Packets(1)。§7.8.2。
pub const BufferSizeV2 = struct {
    status: u8,
    le_acl_data_packet_length: u16,
    total_num_le_acl_packets: u8,
    iso_data_packet_length: u16,
    total_num_iso_data_packets: u8,
};

/// LE_Read_Maximum_Data_Length 的 4 个返回参数，各 2 字节。§7.8.46。
pub const DataLengthLimits = struct {
    status: u8,
    max_tx_octets: u16,
    max_tx_time: u16,
    max_rx_octets: u16,
    max_rx_time: u16,
};

/// Status + Connection_Handle：LE_Long_Term_Key_Request_Reply、
/// Negative_Reply、LE_Set_Data_Length 的返回。§7.8.25、§7.8.26、§7.8.33。
pub const HandleStatus = struct { status: u8, handle: u16 };

/// Status + BD_ADDR / Public Device Address。§7.4.6。
pub const BdAddr = struct { status: u8, addr: gap.Addr };

/// Status + 8 字节位掩码（LMP_Features、LE_Features、LE_States）。
pub const Octets8 = struct { status: u8, bits: [8]u8 };

/// 按 OpCode 解出的返回参数。每个变体对应一条命令，都带 Status。
pub const Return = union(enum) {
    status: u8,
    local_version: LocalVersion,
    bd_addr: BdAddr,
    local_supported_features: Octets8,
    le_buffer_size_v1: BufferSizeV1,
    le_buffer_size_v2: BufferSizeV2,
    le_local_supported_features: Octets8,
    le_supported_states: Octets8,
    le_max_data_length: DataLengthLimits,
    handle_status: HandleStatus,

    /// 所有变体的 Status 字段。
    pub fn statusOf(self: Return) u8 {
        return switch (self) {
            .status => |s| s,
            inline else => |v| v.status,
        };
    }
};

fn need(ret: []const u8, n: usize) Error!void {
    if (ret.len < n) return error.Short;
    if (ret.len > n) return error.Trailing;
}

fn octets8(ret: []const u8) [8]u8 {
    return ret[0..8].*;
}

/// 解析 Command Complete 的返回参数（已去掉 Num_HCI_Command_Packets 与
/// OpCode）。OpCode 不认识 → `UnknownOpcode`。
pub fn parseReturn(op: u16, ret: []const u8) Error!Return {
    // 不认识的 OpCode，以及只回 Command Status（没有返回参数）的那几条命令。
    const kind = expects(op) orelse return error.UnknownOpcode;
    if (kind != .command_complete) return error.UnknownOpcode;
    if (ret.len == 0) return error.Short;
    // 失败时 controller 可以只回 Status；成功却只有 Status 是截断。
    if (ret.len == 1) {
        if (returnsOnlyStatus(op)) return .{ .status = ret[0] };
        if (ret[0] != 0) return .{ .status = ret[0] };
        return error.Short;
    }
    return switch (op) {
        op_reset,
        op_le_set_event_mask,
        op_le_set_random_address,
        op_le_set_advertising_parameters,
        op_le_set_advertising_data,
        op_le_set_scan_response_data,
        op_le_set_advertising_enable,
        op_le_set_scan_parameters,
        op_le_set_scan_enable,
        => blk: {
            try need(ret, 1);
            break :blk .{ .status = ret[0] };
        },
        op_read_local_version => blk: {
            try need(ret, 9);
            break :blk .{ .local_version = .{
                .status = ret[0],
                .hci_version = ret[1],
                .hci_subversion = std.mem.readInt(u16, ret[2..4], .little),
                .lmp_version = ret[4],
                .company_identifier = std.mem.readInt(u16, ret[5..7], .little),
                .lmp_subversion = std.mem.readInt(u16, ret[7..9], .little),
            } };
        },
        op_read_local_supported_features => blk: {
            try need(ret, 9);
            break :blk .{ .local_supported_features = .{ .status = ret[0], .bits = octets8(ret[1..]) } };
        },
        op_read_bd_addr => blk: {
            try need(ret, 7);
            break :blk .{ .bd_addr = .{ .status = ret[0], .addr = .{ .bytes = ret[1..7].* } } };
        },
        op_le_read_buffer_size_v1 => blk: {
            try need(ret, 4);
            break :blk .{ .le_buffer_size_v1 = .{
                .status = ret[0],
                .le_acl_data_packet_length = std.mem.readInt(u16, ret[1..3], .little),
                .total_num_le_acl_packets = ret[3],
            } };
        },
        op_le_read_buffer_size_v2 => blk: {
            try need(ret, 7);
            break :blk .{ .le_buffer_size_v2 = .{
                .status = ret[0],
                .le_acl_data_packet_length = std.mem.readInt(u16, ret[1..3], .little),
                .total_num_le_acl_packets = ret[3],
                .iso_data_packet_length = std.mem.readInt(u16, ret[4..6], .little),
                .total_num_iso_data_packets = ret[6],
            } };
        },
        op_le_read_local_supported_features => blk: {
            try need(ret, 9);
            break :blk .{ .le_local_supported_features = .{ .status = ret[0], .bits = octets8(ret[1..]) } };
        },
        op_le_read_supported_states => blk: {
            try need(ret, 9);
            break :blk .{ .le_supported_states = .{ .status = ret[0], .bits = octets8(ret[1..]) } };
        },
        op_le_read_maximum_data_length => blk: {
            try need(ret, 9);
            break :blk .{ .le_max_data_length = .{
                .status = ret[0],
                .max_tx_octets = std.mem.readInt(u16, ret[1..3], .little),
                .max_tx_time = std.mem.readInt(u16, ret[3..5], .little),
                .max_rx_octets = std.mem.readInt(u16, ret[5..7], .little),
                .max_rx_time = std.mem.readInt(u16, ret[7..9], .little),
            } };
        },
        op_le_long_term_key_request_reply,
        op_le_long_term_key_request_negative_reply,
        op_le_set_data_length,
        => blk: {
            try need(ret, 3);
            break :blk .{ .handle_status = .{
                .status = ret[0],
                .handle = std.mem.readInt(u16, ret[1..3], .little),
            } };
        },
        else => error.UnknownOpcode,
    };
}

// ---------------------------------------------------------------------------
// 命令流控（§4.4）
// ---------------------------------------------------------------------------

/// Host 侧的命令额度。上电与复位后同一时刻只允许 1 条未完成的命令；
/// Command Complete / Command Status 里的 Num_HCI_Command_Packets 是当前
/// 还能发几条。本实现刻意只保留**一条**未完成命令：回调和状态机简单，
/// 也不依赖 controller 的排队行为。
pub const Ctl = struct {
    credits: u8 = 1,
    pending: ?u16 = null,

    pub const Error = error{ Busy, NoCredits };

    pub fn canSend(self: Ctl) bool {
        return self.pending == null and self.credits > 0;
    }

    /// 登记一条即将发出的命令：占一个额度、记为未完成。
    pub fn begin(self: *Ctl, op: u16) Ctl.Error!void {
        if (self.pending != null) return error.Busy;
        if (self.credits == 0) return error.NoCredits;
        self.credits -= 1;
        self.pending = op;
    }

    /// 收到 Command Complete / Command Status：刷新额度。返回 true 表示这条
    /// 事件对应当前未完成的那条命令。OpCode 0x0000 表示“无关联命令”，只是
    /// controller 用来调整额度（§7.7.14），不算完成。
    pub fn settle(self: *Ctl, op: u16, num_packets: u8) bool {
        const match = op != 0x0000 and self.pending != null and self.pending.? == op;
        if (match) self.pending = null;
        self.credits = num_packets;
        return match;
    }

    /// 复位（HCI_Reset 之后 controller 的额度回到 1）。
    pub fn reset(self: *Ctl) void {
        self.* = .{};
    }
};
