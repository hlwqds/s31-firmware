//! ble-802154：LE Power Control 的 host 侧——命令与事件的编解码、功率范围的钳制、路径损耗
//! 阈值事件的参数校验（Bluetooth Core 5.4）。
//!
//! 规范出处（都是本次从原文读到的，条款号与原文一致）：
//!   * 命令（[Vol 4] Part E）：LE Read Transmit Power §7.8.74、LE Enhanced Read Transmit
//!     Power Level §7.8.117、LE Read Remote Transmit Power Level §7.8.118、LE Set Path Loss
//!     Reporting Parameters §7.8.119、LE Set Path Loss Reporting Enable §7.8.120、LE Set
//!     Transmit Power Reporting Enable §7.8.121；
//!   * 事件（[Vol 4] Part E）：LE Path Loss Threshold §7.7.65.32（子事件码 0x20）、LE
//!     Transmit Power Reporting §7.7.65.33（子事件码 0x21）；LE Set Event Mask 位表
//!     §7.8.1：bit 31 / bit 32；
//!   * 功率电平的管理与路径损耗监测的分区 —— [Vol 6] Part B §4.5.15、§4.5.16；
//!   * 对端请求改功率时的钳制 —— [Vol 6] Part B §5.1.17（Power Control Request）。
//!
//! 本文件只有纯逻辑，不驱动射频。host 在这里做三件事：
//!
//!   * 把上面六条命令编成完整的 H4 命令帧（与 `hci_cmd.zig` 同一口径：多字节参数小端，
//!     [Vol 4] Part E §5.2），把返回参数和两个事件解出来；
//!   * `Responder`：按 §5.1.17 的钳制规则，算一次功率请求会落到哪一档；
//!   * `PathLossTracker`：拿 host 自己下发的阈值参数，校验 controller 报上来的路径损耗
//!     事件是不是自洽。
//!
//! 事件与返回参数里的保留取值不静默接受：值越界 → `BadParam`；长度不对 → `Short` /
//! `Trailing`。

const std = @import("std");

const hci = @import("hci.zig");

/// `Short` / `Trailing` / `NoSpace` / `Oversize` / `UnsupportedEvent` 来自 `hci.packCommand`；
/// 其中 `Short`（输入短于固定长度）、`Trailing`（输入长于声明长度）、`NoSpace`（输出
/// 缓冲放不下）也用在返回参数与事件的解析上。
pub const Error = hci.Error || error{
    /// 取值不在规范允许的范围内。
    BadParam,
    /// 不是本文件解的那两个 LE 子事件。
    UnknownSubevent,
};

// ---------------------------------------------------------------------------
// OpCode、子事件码与事件掩码
// ---------------------------------------------------------------------------

/// LE Read Transmit Power。§7.8.74（OCF 0x004B）。
pub const op_le_read_transmit_power: u16 = hci.opcode(hci.ogf_le_controller, 0x004B);
/// LE Enhanced Read Transmit Power Level。§7.8.117。
pub const op_le_enhanced_read_transmit_power_level: u16 = hci.opcode(hci.ogf_le_controller, 0x0076);
/// LE Read Remote Transmit Power Level。§7.8.118。
pub const op_le_read_remote_transmit_power_level: u16 = hci.opcode(hci.ogf_le_controller, 0x0077);
/// LE Set Path Loss Reporting Parameters。§7.8.119。
pub const op_le_set_path_loss_reporting_parameters: u16 = hci.opcode(hci.ogf_le_controller, 0x0078);
/// LE Set Path Loss Reporting Enable。§7.8.120。
pub const op_le_set_path_loss_reporting_enable: u16 = hci.opcode(hci.ogf_le_controller, 0x0079);
/// LE Set Transmit Power Reporting Enable。§7.8.121。
pub const op_le_set_transmit_power_reporting_enable: u16 = hci.opcode(hci.ogf_le_controller, 0x007A);

/// LE Meta Event 的子事件码。§7.7.65.32、§7.7.65.33。
pub const subevent_path_loss_threshold: u8 = 0x20;
pub const subevent_transmit_power_reporting: u8 = 0x21;

/// LE Set Event Mask 里的两位（§7.8.1 位表：bit 31、bit 32）。掩码是 8 字节小端的 u64，
/// 第 n 个事件对应 bit n。
pub const le_event_mask_path_loss_threshold: u64 = @as(u64, 1) << 31;
pub const le_event_mask_transmit_power_reporting: u64 = @as(u64, 1) << 32;

// ---------------------------------------------------------------------------
// 取值
// ---------------------------------------------------------------------------

/// PHY 参数的取值（§7.8.117 等的 PHY 表）。数值与 LL 的 PHY 位图（[Vol 6] Part B 表 2.23）
/// 是第 n 位对应这里的第 n 个值：1M 是 bit 0，S=2 是 bit 3。
pub const Phy = enum(u8) { le_1m = 0x01, le_2m = 0x02, coded_s8 = 0x03, coded_s2 = 0x04 };

pub fn phyFromHci(v: u8) Error!Phy {
    return switch (v) {
        0x01 => .le_1m,
        0x02 => .le_2m,
        0x03 => .coded_s8,
        0x04 => .coded_s2,
        else => error.BadParam,
    };
}

/// 发射功率的可报范围：−127 到 +20，单位 dBm（§7.8.74、§7.8.117、§7.7.65.33 的
/// “Range: -127 to 20”）。−128 与 21…125 都不在范围内。
pub const tx_power_min: i8 = -127;
pub const tx_power_max: i8 = 20;

/// TX_Power_Level = 0x7E：对端没有在这个 PHY 上管功率（§7.7.65.33）。
pub const power_not_managing: u8 = 0x7E;
/// TX_Power_Level / Current_TX_Power_Level = 0x7F：数值不可用。
pub const power_unavailable: u8 = 0x7F;
/// Delta = 0x7F：变化量不可用或超出范围（§7.7.65.33）；LL 的 LL_POWER_CONTROL_REQ 里
/// Delta = 127 表示“请求升到最大功率”（§2.4.2.33）。
pub const delta_unavailable: u8 = 0x7F;
pub const delta_request_max: u8 = 0x7F;
/// Current_Path_Loss = 0xFF：不可用（§7.7.65.32）。
pub const path_loss_unavailable: u8 = 0xFF;
/// High_Threshold = 0xFF：高阈值不用（§7.8.119）。
pub const high_threshold_unused: u8 = 0xFF;
/// Connection_Handle 只有低 12 位有意义：0x0000–0x0EFF。
pub const handle_max: u16 = 0x0EFF;

fn decodeHandle(bytes: []const u8) Error!u16 {
    const h = std.mem.readInt(u16, bytes[0..2], .little);
    if (h > handle_max) return error.BadParam;
    return h;
}

/// 一个功率字节（按补码读）是否落在可报范围内。
fn dbmOf(v: u8) Error!i8 {
    const x: i8 = @bitCast(v);
    if (x < tx_power_min or x > tx_power_max) return error.BadParam;
    return x;
}

fn need(buf: []const u8, n: usize) Error!void {
    if (buf.len < n) return error.Short;
    if (buf.len > n) return error.Trailing;
}

/// 失败时 controller 可以只回一个 Status；成功却只有 Status 是截断。与 `hci_cmd.zig`
/// 的 `parseReturn` 同一口径。
fn onlyFailure(ret: []const u8) ?u8 {
    if (ret.len == 1 and ret[0] != 0) return ret[0];
    return null;
}

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

/// LE Read Transmit Power：无参数；读所有 PHY 上支持的最小 / 最大发射功率。§7.8.74。
pub fn cmdReadTransmitPower(out: []u8) Error!usize {
    return hci.packCommand(out, op_le_read_transmit_power, &.{});
}

/// Connection_Handle(2) + PHY(1)：§7.8.117 与 §7.8.118 的命令参数。
fn cmdHandlePhy(out: []u8, op: u16, handle: u16, phy: Phy) Error!usize {
    if (handle > handle_max) return error.BadParam;
    var p: [3]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], handle, .little);
    p[2] = @backingInt(phy);
    return hci.packCommand(out, op, &p);
}

/// LE Enhanced Read Transmit Power Level：读本端在某个连接、某个 PHY 上的当前与最大
/// 发射功率。§7.8.117。回 Command Complete。
pub fn cmdEnhancedReadTransmitPowerLevel(out: []u8, handle: u16, phy: Phy) Error!usize {
    return cmdHandlePhy(out, op_le_enhanced_read_transmit_power_level, handle, phy);
}

/// LE Read Remote Transmit Power Level：读对端的发射功率。§7.8.118。它回的是
/// Command Status，结果走之后的 LE Transmit Power Reporting 事件（Reason = 0x02）。
pub fn cmdReadRemoteTransmitPowerLevel(out: []u8, handle: u16, phy: Phy) Error!usize {
    return cmdHandlePhy(out, op_le_read_remote_transmit_power_level, handle, phy);
}

/// LE Set Path Loss Reporting Parameters 的六个参数。§7.8.119。
pub const PathLossParams = struct {
    /// 高阈值，单位 dB；0xFF 表示不用高阈值（只有 Low / Middle 两个区）。
    high_threshold: u8,
    high_hysteresis: u8,
    low_threshold: u8,
    low_hysteresis: u8,
    /// 路径损耗越过阈值后至少观察多少个连接事件才报事件。
    min_time_spent: u16,
    /// 连同 Connection_Handle 的参数总长：2 + 1 + 1 + 1 + 1 + 2 = 8。
    pub const packed_len: usize = 8;

    pub fn highUsed(self: PathLossParams) bool {
        return self.high_threshold != high_threshold_unused;
    }

    // 四个边界（§7.8.119：“the upwards boundary shall equal the threshold plus the
    // hysteresis and the downwards boundary shall equal the threshold minus the
    // hysteresis”）。先过 `validate` 再用，这里的运算才不饱和。

    /// Low 区向上、Middle 区向下的边界。
    pub fn lowUp(self: PathLossParams) u8 {
        return self.low_threshold +| self.low_hysteresis;
    }

    pub fn lowDown(self: PathLossParams) u8 {
        return self.low_threshold -| self.low_hysteresis;
    }

    /// Middle 区向上、High 区向下的边界。
    pub fn highUp(self: PathLossParams) u8 {
        return self.high_threshold +| self.high_hysteresis;
    }

    pub fn highDown(self: PathLossParams) u8 {
        return self.high_threshold -| self.high_hysteresis;
    }

    /// §7.8.119 的四条检查，哪条不满足 controller 就回 0x12。按原文的顺序判，
    /// 所以同时违反几条时报的是最前面那一条。
    pub fn validate(self: PathLossParams) PathLossError!void {
        if (@as(u16, self.high_threshold) + self.high_hysteresis > 0xFF) return error.HighThresholdOverflow;
        if (self.low_threshold < self.low_hysteresis) return error.LowThresholdUnderflow;
        if (self.low_threshold > self.high_threshold) return error.LowAboveHigh;
        // 用带符号的整数算，High − High_Hysteresis 可能是负数。
        const high_down: i16 = @as(i16, self.high_threshold) - self.high_hysteresis;
        if (@as(i16, self.low_threshold) + self.low_hysteresis > high_down) return error.BandsOverlap;
    }
};

/// §7.8.119 的四条检查各给一个错误名，好让“拒绝的理由”可以断言。四个都对应
/// Invalid HCI Command Parameters (0x12)。
pub const PathLossError = error{
    HighThresholdOverflow,
    LowThresholdUnderflow,
    LowAboveHigh,
    BandsOverlap,
};

/// LE Set Path Loss Reporting Parameters：Connection_Handle(2) + High_Threshold(1) +
/// High_Hysteresis(1) + Low_Threshold(1) + Low_Hysteresis(1) + Min_Time_Spent(2)。§7.8.119。
/// 参数先过 `PathLossParams.validate`。
pub fn cmdSetPathLossReportingParameters(out: []u8, handle: u16, p: PathLossParams) Error!usize {
    if (handle > handle_max) return error.BadParam;
    p.validate() catch return error.BadParam;
    var b: [PathLossParams.packed_len]u8 = undefined;
    std.mem.writeInt(u16, b[0..2], handle, .little);
    b[2] = p.high_threshold;
    b[3] = p.high_hysteresis;
    b[4] = p.low_threshold;
    b[5] = p.low_hysteresis;
    std.mem.writeInt(u16, b[6..8], p.min_time_spent, .little);
    return hci.packCommand(out, op_le_set_path_loss_reporting_parameters, &b);
}

/// LE Set Path Loss Reporting Enable：Connection_Handle(2) + Enable(1)。§7.8.120。
pub fn cmdSetPathLossReportingEnable(out: []u8, handle: u16, enable: bool) Error!usize {
    if (handle > handle_max) return error.BadParam;
    var p: [3]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], handle, .little);
    p[2] = @intFromBool(enable);
    return hci.packCommand(out, op_le_set_path_loss_reporting_enable, &p);
}

/// LE Set Transmit Power Reporting Enable：Connection_Handle(2) + Local_Enable(1) +
/// Remote_Enable(1)。§7.8.121。
pub fn cmdSetTransmitPowerReportingEnable(out: []u8, handle: u16, local_enable: bool, remote_enable: bool) Error!usize {
    if (handle > handle_max) return error.BadParam;
    var p: [4]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], handle, .little);
    p[2] = @intFromBool(local_enable);
    p[3] = @intFromBool(remote_enable);
    return hci.packCommand(out, op_le_set_transmit_power_reporting_enable, &p);
}

// ---------------------------------------------------------------------------
// 返回参数
// ---------------------------------------------------------------------------

/// LE Read Transmit Power 的返回：Status + Min_TX_Power(1) + Max_TX_Power(1)。§7.8.74。
pub const TxPowerRange = struct { status: u8, min_dbm: i8, max_dbm: i8 };

pub fn parseTransmitPowerRange(ret: []const u8) Error!TxPowerRange {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .min_dbm = 0, .max_dbm = 0 };
    try need(ret, 3);
    const lo = try dbmOf(ret[1]);
    const hi = try dbmOf(ret[2]);
    if (lo > hi) return error.BadParam;
    return .{ .status = ret[0], .min_dbm = lo, .max_dbm = hi };
}

/// LE Enhanced Read Transmit Power Level 的返回：Status + Connection_Handle(2) + PHY(1) +
/// Current_TX_Power_Level(1) + Max_TX_Power_Level(1)。§7.8.117。`current` 为 null 表示
/// 0x7F（不可用）。
pub const TxPowerLevel = struct {
    status: u8,
    handle: u16,
    phy: Phy,
    current: ?i8,
    max_dbm: i8,
};

pub fn parseEnhancedReadTransmitPowerLevel(ret: []const u8) Error!TxPowerLevel {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .handle = 0, .phy = .le_1m, .current = null, .max_dbm = 0 };
    try need(ret, 6);
    const handle = try decodeHandle(ret[1..3]);
    const phy = try phyFromHci(ret[3]);
    const current: ?i8 = if (ret[4] == power_unavailable) null else try dbmOf(ret[4]);
    return .{ .status = ret[0], .handle = handle, .phy = phy, .current = current, .max_dbm = try dbmOf(ret[5]) };
}

/// Status + Connection_Handle(2)：§7.8.119、§7.8.120、§7.8.121 的返回。
pub const HandleStatus = struct { status: u8, handle: u16 };

pub fn parseHandleStatus(ret: []const u8) Error!HandleStatus {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .handle = 0 };
    try need(ret, 3);
    return .{ .status = ret[0], .handle = try decodeHandle(ret[1..3]) };
}

// ---------------------------------------------------------------------------
// 事件
// ---------------------------------------------------------------------------

/// Zone_Entered。§7.7.65.32：0x00 低区、0x01 中区、0x02 高区。
pub const Zone = enum(u8) { low = 0x00, middle = 0x01, high = 0x02 };

fn zoneOf(v: u8) Error!Zone {
    return switch (v) {
        0x00 => .low,
        0x01 => .middle,
        0x02 => .high,
        else => error.BadParam,
    };
}

/// LE Path Loss Threshold 事件：Connection_Handle(2) + Current_Path_Loss(1) +
/// Zone_Entered(1)。§7.7.65.32。路径损耗 0xFF（不可用）时 `loss` 与 `zone` 都是 null
/// ——原文说这时 Zone_Entered “shall be ignored”，所以那个字节是什么都不报错。
pub const PathLossThreshold = struct { handle: u16, loss: ?u8, zone: ?Zone };

/// `params` 是子事件码之后的那一段。
pub fn decodePathLossThreshold(params: []const u8) Error!PathLossThreshold {
    try need(params, 4);
    const handle = try decodeHandle(params[0..2]);
    if (params[2] == path_loss_unavailable) return .{ .handle = handle, .loss = null, .zone = null };
    return .{ .handle = handle, .loss = params[2], .zone = try zoneOf(params[3]) };
}

/// TX_Power_Level 的三种取值。
pub const Level = union(enum) {
    /// −127…20 的功率值（dBm）。
    dbm: i8,
    /// 0x7E：对端没有在这个 PHY 上管功率。
    not_managed,
    /// 0x7F：数值不可用。
    unavailable,
};

/// Reason。§7.7.65.33：0x00 本端功率变了、0x01 对端功率变了、0x02 读对端功率的命令完成了。
pub const Reason = enum(u8) { local_changed = 0x00, remote_changed = 0x01, read_remote_completed = 0x02 };

/// LE Transmit Power Reporting 事件：Status(1) + Connection_Handle(2) + Reason(1) + PHY(1) +
/// TX_Power_Level(1) + TX_Power_Level_Flag(1) + Delta(1)。§7.7.65.33。
///
/// 原文里“忽略”的几种情况解出来是 null，不报错：Reason 为 0x00 / 0x01 时 Status 被忽略；
/// TX_Power_Level 是 0x7E / 0x7F 时 Flag 被忽略、Delta 为 0x7E 时被忽略；Delta 为 0x7F
/// 表示不可用。
pub const TxPowerReporting = struct {
    handle: u16,
    status: ?u8,
    reason: Reason,
    phy: Phy,
    level: Level,
    /// bit 0：已在最小电平；bit 1：已在最大电平。只有 `level` 是 `.dbm` 时才有意义。
    at_min: ?bool,
    at_max: ?bool,
    delta: ?i8,
};

/// `params` 是子事件码之后的那一段。
pub fn decodeTxPowerReporting(params: []const u8) Error!TxPowerReporting {
    try need(params, 8);
    const handle = try decodeHandle(params[1..3]);
    const reason: Reason = switch (params[3]) {
        0x00 => .local_changed,
        0x01 => .remote_changed,
        0x02 => .read_remote_completed,
        else => return error.BadParam,
    };
    const phy = try phyFromHci(params[4]);
    const level: Level = switch (params[5]) {
        power_not_managing => .not_managed,
        power_unavailable => .unavailable,
        else => .{ .dbm = try dbmOf(params[5]) },
    };
    // 0x7E 的定义只针对对端（“Remote device is not managing…”）；本端功率报告里它没有含义。
    if (level == .not_managed and reason == .local_changed) return error.BadParam;
    var at_min: ?bool = null;
    var at_max: ?bool = null;
    if (level == .dbm) {
        // 只用了 bit 0 / bit 1，其余是 Reserved for future use。
        if (params[6] & ~@as(u8, 0x03) != 0) return error.BadParam;
        at_min = params[6] & 0x01 != 0;
        at_max = params[6] & 0x02 != 0;
    }
    var delta: ?i8 = null;
    if (level != .not_managed and params[7] != delta_unavailable) delta = @bitCast(params[7]);
    // “When this event is generated with Reason set to 0x02, Delta shall be set to zero.”
    if (reason == .read_remote_completed and delta != 0) return error.BadParam;
    return .{
        .handle = handle,
        .status = if (reason == .read_remote_completed) params[0] else null,
        .reason = reason,
        .phy = phy,
        .level = level,
        .at_min = at_min,
        .at_max = at_max,
        .delta = delta,
    };
}

pub const LePowerEvent = union(enum) {
    path_loss_threshold: PathLossThreshold,
    transmit_power_reporting: TxPowerReporting,
};

/// 解一帧完整的 H4 事件（04 + 0x3E + 参数长度 + 子事件码 + 参数）里属于 LE Power
/// Control 的那两个子事件。事件码不是 0x3E、或子事件码不是 0x20 / 0x21 → `BadParam` /
/// `UnknownSubevent`；本文件不负责分发别的 LE 事件。
pub fn decodeEvent(frame: []const u8) Error!LePowerEvent {
    if (frame.len < 4 or frame[0] != hci.h4_event) return error.Short;
    if (frame[1] != hci.evt_le_meta) return error.BadParam;
    const total = 3 + @as(usize, frame[2]);
    if (frame.len < total) return error.Short;
    if (frame.len > total) return error.Trailing;
    if (frame[2] == 0) return error.Short;
    return switch (frame[3]) {
        subevent_path_loss_threshold => .{ .path_loss_threshold = try decodePathLossThreshold(frame[4..]) },
        subevent_transmit_power_reporting => .{ .transmit_power_reporting = try decodeTxPowerReporting(frame[4..]) },
        else => error.UnknownSubevent,
    };
}

// ---------------------------------------------------------------------------
// 路径损耗的分区（[Vol 6] Part B §4.5.16）
// ---------------------------------------------------------------------------

/// 路径损耗现在是 `loss`、当前在 `current` 区，算它算进了哪个区：向上要 ≥ 上边界才
/// 升区，向下要 ≤ 下边界才降区；夹在中间不动（这就是回差）。`p` 要先过 `validate`。
pub fn zoneEntered(current: Zone, loss: u8, p: PathLossParams) Zone {
    return switch (current) {
        .low => if (loss >= p.lowUp()) .middle else .low,
        .middle => blk: {
            if (loss <= p.lowDown()) break :blk .low;
            if (p.highUsed() and loss >= p.highUp()) break :blk .high;
            break :blk .middle;
        },
        .high => if (loss <= p.highDown()) .middle else .high,
    };
}

/// `loss` 是否落在 `zone` 的范围里。范围取这一区的两个回差边界之间：待在这一区里的
/// 条件是既没有越过向上的边界，也没有越过下一区向下的边界。`p` 要先过 `validate`。
pub fn inZone(zone: Zone, loss: u8, p: PathLossParams) bool {
    return switch (zone) {
        .low => loss <= p.lowUp(),
        .middle => loss > p.lowDown() and (!p.highUsed() or loss < p.highUp()),
        .high => p.highUsed() and loss >= p.highDown(),
    };
}

pub const TrackerError = error{
    /// 高阈值没用（0xFF）时 controller 不得报进高区。§7.8.119。
    HighZoneUnused,
    /// 连续两次报的是同一个区。§4.5.16、§7.8.120。
    SameZone,
    /// 报的区与路径损耗的数值对不上 host 下发的阈值。
    ZoneMismatch,
};

/// 拿 host 自己下发的阈值参数校验路径损耗事件，并记住当前在哪个区。
/// 每条连接一个。
pub const PathLossTracker = struct {
    params: PathLossParams,
    /// 上一次报进的是哪个区；null 表示还不知道（刚建连接、或上次报的是不可用）。
    last_zone: ?Zone = null,
    /// 通过校验的事件数。
    events: u32 = 0,

    pub fn init(p: PathLossParams) PathLossError!PathLossTracker {
        try p.validate();
        return .{ .params = p };
    }

    /// 换一套阈值。§7.8.119：监测开着时新参数覆盖旧参数。当前在哪个区不重算，
    /// 等下一个事件来校验。
    pub fn setParams(self: *PathLossTracker, p: PathLossParams) PathLossError!void {
        try p.validate();
        self.params = p;
    }

    pub fn onEvent(self: *PathLossTracker, e: PathLossThreshold) TrackerError!void {
        // 路径损耗不可用：没有区可校验。之后路径损耗恢复可用时 controller 会“如同刚换了
        // 区”再报一次（§4.5.16），所以把上一个区忘掉，别拿它去卡下一次报告。
        if (e.loss == null) {
            self.last_zone = null;
            return;
        }
        const zone = e.zone.?;
        if (zone == .high and !self.params.highUsed()) return error.HighZoneUnused;
        if (self.last_zone == zone) return error.SameZone;
        if (!inZone(zone, e.loss.?, self.params)) return error.ZoneMismatch;
        self.last_zone = zone;
        self.events += 1;
    }
};

// ---------------------------------------------------------------------------
// 功率请求的钳制（[Vol 6] Part B §5.1.17）
// ---------------------------------------------------------------------------

/// 一个 PHY 上本端的功率电平：可用的档位、当前档、是否在管这个 PHY 的功率。host 用它
/// 算一次请求会落到哪一档。
pub const Responder = struct {
    /// 可用的发射功率（dBm），严格升序。由调用方持有。
    levels: []const i8,
    current: usize,
    managing: bool = true,

    /// 对端收到的 LL_POWER_CONTROL_RSP 里的几个字段。
    pub const Reply = struct {
        /// 发送端现在的发射功率；没在管时是 126（§5.1.17：“by setting the power level
        /// to 126”），这时其余字段都被忽略。
        tx_power: i8,
        /// 实际做出的改变。
        delta: i8,
        at_min: bool,
        at_max: bool,
    };

    pub const not_managing_level: i8 = 126;

    pub fn init(levels: []const i8, current: usize) Error!Responder {
        if (levels.len == 0 or current >= levels.len) return error.BadParam;
        for (levels, 0..) |v, i| {
            if (v < tx_power_min or v > tx_power_max) return error.BadParam;
            if (i > 0 and v <= levels[i - 1]) return error.BadParam;
        }
        return .{ .levels = levels, .current = current };
    }

    pub fn level(self: Responder) i8 {
        return self.levels[self.current];
    }

    /// 处理对端的一个功率请求。`delta` 是 LL_POWER_CONTROL_REQ 里 Delta 的原始字节：
    /// 补码的 dB 变化量，0x7F 表示“请求升到最大功率”（§2.4.2.33）。
    ///
    /// §5.1.17：能精确满足就精确满足；请求会超过最大电平就设到最大；做不出精确的
    /// 改变，就落到**比请求值高的最低一档**——所以向下的小请求可能一档都不动。
    /// 没在管这个 PHY 的功率：不动，回 126。
    pub fn apply(self: *Responder, delta: u8) Reply {
        if (!self.managing) return .{ .tx_power = not_managing_level, .delta = 0, .at_min = false, .at_max = false };
        const cur = self.level();
        const last = self.levels.len - 1;
        const target: i16 = if (delta == delta_request_max)
            self.levels[last]
        else
            @as(i16, cur) + @as(i16, @as(i8, @bitCast(delta)));
        var idx = last;
        for (self.levels, 0..) |v, i| {
            if (@as(i16, v) >= target) {
                idx = i;
                break;
            }
        }
        // 请求值比最大档还高时循环不中断，停在最后一档：这就是“设到最大”。
        self.current = idx;
        return .{
            .tx_power = self.level(),
            .delta = self.level() - cur,
            .at_min = idx == 0,
            .at_max = idx == last,
        };
    }
};
