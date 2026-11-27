//! LE Set Host Channel Classification 的信道图（Core 5.4 [Vol 4] Part E §7.8.19），与从 Wi-Fi 的 2.4 GHz 信道
//! 算出这张图的办法。
//!
//! 信道图 5 个字节、37 位有效：数据信道 0..36 各一位，**0 = bad、1 = unknown**，至少一位是 unknown，
//! 高 3 位保留为 0。位序照 [Vol 6] Part B §5.1.2 的例 3（`channelMapNEW: 0x1FFFFFF7FF` 是「除了信道 11
//! 之外都开」）：信道 n 是从低位数第 n 位。数据信道 n 的中心频率是 2402 + 2n MHz、占 2 MHz（[Vol 6] Part B
//! Table 1.3）。三个主广播信道 37 / 38 / 39 不在图里：主机分类只管数据、次广播、周期广播与等时物理信道
//! （§7.8.19 的描述）。
//!
//! 时序要求（§7.8.19）：知道分类变了之后 10 s 内发；两条命令之间至少隔 1 s。由调用方保证。
//!
//! 与 Wi-Fi 的重叠是共存里用它的事（生产仓路线图 C8）。IEEE 802.11-2016 这边的三个数：
//!   - 2.4 GHz 信道 c（1..13）的中心频率是 2407 + 5c MHz：信道起始频率 2.407 GHz（Annex E 的 Table E-4，
//!     全球类 81）加 5 MHz 一档（§17.3.8.4.2 的式 17-27；不带 Operating Class 的那套数就是 Table 16-6）。
//!     信道 14 是 2484 MHz（日本，Table 16-6 / Table E-4）。
//!   - 发射频谱掩模（HR/DSSS 的 §16.3.7.4，DSSS 的 §15.4.5.5）：中心 ±11 MHz 以内不衰减，之外 −30 dBr、
//!     再外 −50 dBr。所以一个 2.4 GHz 信道占中心 ±11 MHz。
//!   - 一个数据信道（2 MHz 宽）只要有一段落进这 22 MHz 里，就算重叠，标成 bad。
//!
//! 纯算术，不发命令、不碰硬件。命令本身（OCF 0x0014，Command Complete 回 Status）由调用方经 HCI 发。

const std = @import("std");

/// OGF 0x08（LE Controller）、OCF 0x0014。
pub const ocf: u16 = 0x0014;
pub const opcode: u16 = 0x2014;

/// 数据信道数（0..36）。
pub const channel_count = 37;
pub const first_data_freq_mhz = 2402;
pub const data_channel_spacing_mhz = 2;
/// 数据信道占 2 MHz：中心 ±1 MHz。
pub const ble_half_width_mhz = 1;
/// 2.4 GHz 信道的发射频谱平顶：中心 ±11 MHz。
pub const wifi_half_width_mhz = 11;

pub const Error = error{
    /// 数据信道号不在 0..36。
    BadBleChannel,
    /// 2.4 GHz 信道号不在 1..14。
    BadWifiChannel,
    /// 一位 unknown 都没有。
    NoUnknownChannel,
    /// 高 3 位（保留位）不是 0。
    ReservedBitsSet,
};

/// 37 位信道图；`bytes` 就是命令的参数。
pub const Map = struct {
    bytes: [5]u8 = @splat(0),

    /// 全部 unknown。
    pub fn allUnknown() Map {
        return .{ .bytes = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F } };
    }

    /// 这个数据信道是 unknown（true）还是 bad（false）。
    pub fn get(self: Map, channel: u8) Error!bool {
        if (channel >= channel_count) return error.BadBleChannel;
        return (self.bytes[channel / 8] >> @intCast(channel % 8)) & 1 != 0;
    }

    pub fn set(self: *Map, channel: u8, unknown: bool) Error!void {
        if (channel >= channel_count) return error.BadBleChannel;
        const bit = @as(u8, 1) << @intCast(channel % 8);
        if (unknown) self.bytes[channel / 8] |= bit else self.bytes[channel / 8] &= ~bit;
    }

    /// §7.8.19 对参数的两条要求：至少一位 unknown，保留位是 0。
    pub fn validate(self: Map) Error!void {
        if (self.bytes[4] & 0xE0 != 0) return error.ReservedBitsSet;
        const low = self.bytes[0] | self.bytes[1] | self.bytes[2] | self.bytes[3];
        if (low == 0 and self.bytes[4] & 0x1F == 0) return error.NoUnknownChannel;
    }

    /// unknown 的信道数。
    pub fn unknownCount(self: Map) u8 {
        var n: u8 = 0;
        for (0..channel_count) |c| {
            if (self.get(@intCast(c)) catch unreachable) n += 1;
        }
        return n;
    }

    /// 命令的参数：5 个字节。
    pub fn payload(self: Map) [5]u8 {
        return self.bytes;
    }
};

/// 数据信道 n 的中心频率（MHz）：2402 + 2n。
pub fn freqOf(channel: u8) Error!u16 {
    if (channel >= channel_count) return error.BadBleChannel;
    return @as(u16, first_data_freq_mhz) + @as(u16, data_channel_spacing_mhz) * channel;
}

/// 2.4 GHz 信道号的中心频率（MHz）：2407 + 5c（c = 1..13），信道 14 是 2484。
pub fn wifiCenterFreqMhz(channel: u8) Error!u16 {
    return switch (channel) {
        1...13 => 2407 + 5 * @as(u16, channel),
        14 => 2484,
        else => error.BadWifiChannel,
    };
}

/// 数据信道与这个 2.4 GHz 信道重叠（有一段落进它的 22 MHz 里）吗。
pub fn overlapsWifi(ble_channel: u8, wifi_channel: u8) Error!bool {
    const f = try freqOf(ble_channel);
    const c = try wifiCenterFreqMhz(wifi_channel);
    // 区间 [f - 1, f + 1] 与 [c - 11, c + 11] 有正长度的交集。
    return f + ble_half_width_mhz > c - wifi_half_width_mhz and
        f - ble_half_width_mhz < c + wifi_half_width_mhz;
}

/// 与这个 2.4 GHz 信道重叠的数据信道的起止号（含两端）。
pub fn wifiOverlap(wifi_channel: u8) Error![2]u8 {
    if (wifi_channel < 1 or wifi_channel > 14) return error.BadWifiChannel;
    var span: [2]u8 = .{ channel_count, 0 };
    for (0..channel_count) |c| {
        if (try overlapsWifi(@intCast(c), wifi_channel)) {
            if (span[0] == channel_count) span[0] = @intCast(c);
            span[1] = @intCast(c);
        }
    }
    // 信道 1 到 14 每一个都至少盖住一个数据信道，所以 span 一定被填过。
    return span;
}

/// 共存用的分类（路线图 C8）：与这个 2.4 GHz 信道重叠的数据信道标成 bad，其余保持 unknown。
/// 结果一定过得了 `validate`：一个 2.4 GHz 信道最多盖住 37 个里的 12 个。
pub fn avoidingWifiChannel(wifi_channel: u8) Error!Map {
    if (wifi_channel < 1 or wifi_channel > 14) return error.BadWifiChannel;
    var m = Map.allUnknown();
    for (0..channel_count) |c| {
        if (try overlapsWifi(@intCast(c), wifi_channel)) try m.set(@intCast(c), false);
    }
    try m.validate();
    return m;
}
