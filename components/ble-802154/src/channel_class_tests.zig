//! ble-802154：LE Set Host Channel Classification 的信道图（`channel_class.zig`）的主机测试。
//!
//! 期望值来源（逐条写在用例旁的注释里，三类）：
//!   * 规范原文：Bluetooth Core 5.4，HCI 在 [Vol 4] Part E（`Core-54-hci.txt`：§7.8.19 正文 28590，
//!     OCF 0x0014 在 28597、Channel_Map 的 37 个 1 位字段在 28614–28615、bad = 0 / unknown = 1 /
//!     保留位 / 至少一位 unknown 在 28616–28619），LL 在 [Vol 6] Part B（`Core-54-ll.txt`：Table 1.3
//!     的数据信道中心频率 2402–2474 MHz 在 2226–2268，§5.1.2 例 3 的 `channelMapNEW: 0x1FFFFFF7FF`
//!     在 5791）。
//!   * 独立实现：盘上 IDF v6.1 的 NimBLE——`include/nimble/hci_common.h:392-395`
//!     （`BLE_HCI_OCF_LE_SET_HOST_CHAN_CLASS (0x0014)`、`uint8_t chan_map[5]`）、
//!     `controller/src/ble_ll_hci.c:859-862`（`chan_map[4] & 0xe0` 非零即回 Invalid HCI Command
//!     Parameters；它比规范严，used < 2 也拒）。
//!   * IEEE 802.11-2016（`802.11-2016.txt`）：Table 16-6（116757–116795：信道 1–13 是 2412–2472、
//!     信道 14 是 2484）、§17.3.8.4.2 的式 17-27（118688–118694：中心频率 = 起始频率 + 5 × n）、
//!     Annex E 的 Table E-4（178327：全球类 81 的起始频率 2.407 GHz）、§16.3.7.4 的发射频谱掩模
//!     （116945–116950：中心 fc ± 11 MHz 之外 −30 dBr）。
//!
//! 重叠窗口是手算的，规则只有一条：数据信道 k 的区间 [2401 + 2k, 2403 + 2k] 与 Wi-Fi 信道的平顶
//! [c − 11, c + 11] 有正长度的交集，即 2402 + 2k 落在开区间 (c − 12, c + 12) 里。开区间宽 24 MHz：
//!   * c 是奇数（信道号 2、4、…、12）时两端不是数据信道的中心，落进去 12 个；
//!   * c 是偶数（信道号 1、3、…、13）时两端正好是中心、被排除，落进去 11 个。
//! 带边再截掉超出 2402–2474 的。逐个算出来的窗口见「overlap」那条用例。

const std = @import("std");
const testing = std.testing;

const cc = @import("channel_class.zig");

test "channel class: all unknown, one bad channel (the spec's own sample), get and set" {
    // 规范原文：37 位全 1 = 全 unknown；§5.1.2 例 3 的 channelMapNEW = 0x1FFFFFF7FF。
    var m = cc.Map.allUnknown();
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }, &m.bytes);
    try m.set(11, false);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xF7, 0xFF, 0xFF, 0x1F }, &m.bytes);
    try testing.expect(try m.get(10));
    try testing.expect(!try m.get(11));
    try testing.expect(try m.get(36));
    try testing.expectEqual(@as(u8, 36), m.unknownCount());
    // 信道 36 是第 5 个字节的 bit4（36 − 32）：去掉它 0x1F -> 0x0F。
    try m.set(36, false);
    try testing.expectEqual(@as(u8, 0x0F), m.bytes[4]);
    try m.set(36, true);
    try testing.expectEqual(@as(u8, 0x1F), m.bytes[4]);
    // 37..39 是主广播信道，不在图里。
    try testing.expectError(error.BadBleChannel, m.get(37));
    try testing.expectError(error.BadBleChannel, m.set(37, true));
}

test "channel class: validate wants at least one unknown and zero reserved bits" {
    // 规范原文：28619「At least one channel shall be marked as unknown」、28618 保留位。
    try cc.Map.allUnknown().validate();
    var none = cc.Map{};
    try testing.expectError(error.NoUnknownChannel, none.validate());
    try none.set(0, true);
    try none.validate();
    var only_high = cc.Map{};
    try only_high.set(36, true);
    try only_high.validate();
    // 独立实现：NimBLE 的 `chan_map[4] & 0xe0`（bit 37..39）。
    var reserved = cc.Map.allUnknown();
    reserved.bytes[4] = 0x9F; // bit 7 = 第 39 位
    try testing.expectError(error.ReservedBitsSet, reserved.validate());
}

test "channel class: data channels 2402 + 2n, Wi-Fi 2407 + 5c, channel 14 is 2484" {
    // 规范原文：Table 1.3 的 2402 MHz（k = 0）到 2474 MHz（k = 36）。
    try testing.expectEqual(@as(u16, 2402), try cc.freqOf(0));
    try testing.expectEqual(@as(u16, 2426), try cc.freqOf(12));
    try testing.expectEqual(@as(u16, 2474), try cc.freqOf(36));
    try testing.expectError(error.BadBleChannel, cc.freqOf(37));
    // 802.11：Table 16-6 的 1 -> 2412、6 -> 2437、13 -> 2472、14 -> 2484。
    try testing.expectEqual(@as(u16, 2412), try cc.wifiCenterFreqMhz(1));
    try testing.expectEqual(@as(u16, 2437), try cc.wifiCenterFreqMhz(6));
    try testing.expectEqual(@as(u16, 2472), try cc.wifiCenterFreqMhz(13));
    try testing.expectEqual(@as(u16, 2484), try cc.wifiCenterFreqMhz(14));
    try testing.expectError(error.BadWifiChannel, cc.wifiCenterFreqMhz(0));
    try testing.expectError(error.BadWifiChannel, cc.wifiCenterFreqMhz(15));
    // 独立实现：NimBLE 的 OCF。
    try testing.expectEqual(@as(u16, 0x0014), cc.ocf);
    try testing.expectEqual(@as(u16, 0x2014), cc.opcode);
}

test "channel class: overlap window per Wi-Fi channel (12 or 11, clipped at the band edges)" {
    // 信道 1（2412，平顶 2401–2423）：中心落在 (2400, 2424) 里的是 2402..2422，数据信道 0 到 10；
    // 数据信道 11（2424，区间 2423–2425）的下沿 2423 贴着平顶上沿，交集零长度，不算。
    try testing.expectEqual([2]u8{ 0, 10 }, try cc.wifiOverlap(1));
    try testing.expect(try cc.overlapsWifi(0, 1));
    try testing.expect(try cc.overlapsWifi(10, 1));
    try testing.expect(!try cc.overlapsWifi(11, 1));
    // 信道 2（2417）：2406..2428，2 到 13（12 个）；信道 3（2422）：2412..2432，5 到 15（11 个）。
    try testing.expectEqual([2]u8{ 2, 13 }, try cc.wifiOverlap(2));
    try testing.expectEqual([2]u8{ 5, 15 }, try cc.wifiOverlap(3));
    // 信道 6（2437，平顶 2426–2448）：2426..2448，12 到 23（12 个）。
    try testing.expectEqual([2]u8{ 12, 23 }, try cc.wifiOverlap(6));
    // 信道 11（2462）：2452..2472，25 到 35（11 个）；信道 12（2467）：2456..2478，27 起到带边 36（10 个）。
    try testing.expectEqual([2]u8{ 25, 35 }, try cc.wifiOverlap(11));
    try testing.expectEqual([2]u8{ 27, 36 }, try cc.wifiOverlap(12));
    // 信道 13（2472）：2462..2482，30 到带边 36（7 个）；信道 14（2484）：2474..2494，只剩 36。
    try testing.expectEqual([2]u8{ 30, 36 }, try cc.wifiOverlap(13));
    try testing.expectEqual([2]u8{ 36, 36 }, try cc.wifiOverlap(14));
    try testing.expectError(error.BadWifiChannel, cc.wifiOverlap(0));
    try testing.expectError(error.BadWifiChannel, cc.overlapsWifi(0, 15));
    // 公式核对（信道 1..10 都没被带边截）：窗口是中心落在 (c − 12, c + 12) 里的数据信道。
    var n: u8 = 1;
    while (n <= 10) : (n += 1) {
        const w = try cc.wifiOverlap(n);
        const c = try cc.wifiCenterFreqMhz(n);
        // 窗口两端的中心频率在开区间里，紧挨着窗口的两个在外面。
        try testing.expect(try cc.freqOf(w[0]) > c - 12);
        try testing.expect(try cc.freqOf(w[1]) < c + 12);
        if (w[0] > 0) try testing.expect(try cc.freqOf(w[0] - 1) <= c - 12);
        if (w[1] + 1 < cc.channel_count) try testing.expect(try cc.freqOf(w[1] + 1) >= c + 12);
        // 奇数号信道 11 个，偶数号信道 12 个。
        try testing.expectEqual(@as(u8, if (n % 2 == 1) 11 else 12), w[1] - w[0] + 1);
    }
}

test "channel class: avoiding a Wi-Fi channel marks exactly the overlapped data channels bad" {
    // 信道 1：位 0..10 清零 → 0x1FFFFFF800，低字节在前是 00 F8 FF FF 1F。
    const m1 = try cc.avoidingWifiChannel(1);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xF8, 0xFF, 0xFF, 0x1F }, &m1.bytes);
    try testing.expectEqualSlices(u8, &m1.bytes, &m1.payload());
    try testing.expectEqual(@as(u8, 26), m1.unknownCount());
    // 信道 6：位 12..23 清零 → 0x1FFF000FFF。
    const m6 = try cc.avoidingWifiChannel(6);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x0F, 0x00, 0xFF, 0x1F }, &m6.bytes);
    try testing.expectEqual(@as(u8, 25), m6.unknownCount());
    // 每个信道：与 wifiOverlap 的窗口逐位对得上，窗口外全是 unknown，结果过得了 validate。
    var c: u8 = 1;
    while (c <= 14) : (c += 1) {
        const m = try cc.avoidingWifiChannel(c);
        const w = try cc.wifiOverlap(c);
        try m.validate();
        for (0..cc.channel_count) |k| {
            const want_unknown = k < w[0] or k > w[1];
            try testing.expectEqual(want_unknown, try m.get(@intCast(k)));
        }
        try testing.expectEqual(@as(u8, cc.channel_count - (w[1] - w[0] + 1)), m.unknownCount());
    }
    try testing.expectEqual(@as(u8, 30), (try cc.avoidingWifiChannel(13)).unknownCount());
    try testing.expectEqual(@as(u8, 36), (try cc.avoidingWifiChannel(14)).unknownCount());
    try testing.expectError(error.BadWifiChannel, cc.avoidingWifiChannel(0));
    try testing.expectError(error.BadWifiChannel, cc.avoidingWifiChannel(15));
}
