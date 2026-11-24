//! ble-802154：`privacy.zig`（解析列表、主机侧地址解析、LL Privacy）与 `power_ctrl.zig`
//! （LE Power Control 的 host 侧）的主机测试（Bluetooth Core 5.4）。
//!
//! 期望值的来源分四类，逐条写在用例旁：
//!
//!   * **按条款排出来的字节**：HCI 命令帧、返回参数、事件帧。出处是 [Vol 4] Part E 的
//!     条款号；字节是先按参数表排好、再让实现去命中的，不是跑一遍实现抄下来的；
//!   * **条款里的句子**：列表增删查的拒绝理由、两种隐私模式的接受规则、RPA_Timeout 的
//!     单位与范围、功率请求的钳制、路径损耗的四条检查。出处是 [Vol 6] Part B、[Vol 3]
//!     Part C、[Vol 4] Part E 的条款号；
//!   * **独立 oracle**：`/tmp/s31-oracle/privacy_oracle.py`——Python `cryptography` 的
//!     AES-128 算出的 24 组随机 (IRK, prand) → RPA，生成时另有一份按 FIPS-197 誊写的纯
//!     Python AES 逐行复核（脚本里的 assert）。不是官方向量，官方式样例只有 FIPS-197
//!     附录 B，oracle 的 selftest 先过它；
//!   * **性质测试**：随机 IRK / prand 的生成 → 解析往返、随机档位上的钳制。
//!
//! 与 NimBLE 的交叉核对（文件:行号）写在对应的用例旁，路径都是
//! `components/bt/host/nimble/nimble/nimble/`。

const std = @import("std");
const testing = std.testing;

const gap = @import("gap_adv.zig");
const hci = @import("hci.zig");
const cmd = @import("hci_cmd.zig");
const vectors = @import("vectors.zig");
const privacy = @import("privacy.zig");
const power = @import("power_ctrl.zig");
const selftest_host = @import("selftest_host.zig");
const privacy_selftest = @import("privacy_selftest.zig");

const hex = privacy.hex;

// ---------------------------------------------------------------------------
// 固定输入
// ---------------------------------------------------------------------------

/// UI 写法 CD:E1:12:34:56:78 的静态随机地址（最高字节 0xCD 的最高两位是 0b11）。
const static_id: gap.Addr = .{ .bytes = hex("78563412e1cd") };
/// 两个公有的 Identity Address。
const public_id: gap.Addr = .{ .bytes = hex("010203040506") };
const third_id: gap.Addr = .{ .bytes = hex("0a0b0c0d0e0f") };
/// 两把 IRK：FIPS-197 附录 B 的 key 与 input（`vectors.zig:59-60`），彼此不同即可。
const irk_a: [16]u8 = vectors.fips197_b_key;
const irk_b: [16]u8 = vectors.fips197_b_input;
const zero_irk: [16]u8 = @splat(0);

const id_static = privacy.Identity{ .addr_type = .random, .addr = static_id };
const id_public = privacy.Identity{ .addr_type = .public, .addr = public_id };

fn entryA() privacy.Entry {
    return .{ .peer_addr_type = .random, .peer_addr = static_id, .peer_irk = irk_a, .local_irk = irk_b };
}

fn entryB() privacy.Entry {
    return .{ .peer_addr_type = .public, .peer_addr = public_id, .peer_irk = irk_b, .local_irk = irk_a };
}

fn entryC() privacy.Entry {
    return .{ .peer_addr_type = .public, .peer_addr = third_id, .peer_irk = zero_irk, .local_irk = irk_a };
}

const accept_a = privacy.Verdict{ .accept = .{ .index = 0, .resolved = false } };
const accept_a_rpa = privacy.Verdict{ .accept = .{ .index = 0, .resolved = true } };

/// 一组路径损耗参数：Low=0x30±5、High=0x50±10。四个边界是 0x2B / 0x35 / 0x46 / 0x5A。
const loss_params = power.PathLossParams{ .high_threshold = 0x50, .high_hysteresis = 0x0A, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 6 };
/// 高阈值不用（0xFF）的两组区。
const loss_two_zones = power.PathLossParams{ .high_threshold = 0xFF, .high_hysteresis = 0x00, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 0 };

const ladder = [_]i8{ -20, -12, -4, 0, 4, 10 };

/// 解出来的结果是不是“第 `index` 条”。不是 resolved → null。
fn indexOf(out: privacy.Outcome) ?usize {
    return switch (out) {
        .resolved => |i| i,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// OpCode 与命令帧
// ---------------------------------------------------------------------------

test "privacy: resolving list opcodes are OGF 0x08 plus the OCF of each clause (Vol 4 Part E 7.8.38-45, 7.8.77)" {
    try testing.expectEqual(@as(u16, 0x2027), privacy.op_le_add_device_to_resolving_list);
    try testing.expectEqual(@as(u16, 0x2028), privacy.op_le_remove_device_from_resolving_list);
    try testing.expectEqual(@as(u16, 0x2029), privacy.op_le_clear_resolving_list);
    try testing.expectEqual(@as(u16, 0x202A), privacy.op_le_read_resolving_list_size);
    try testing.expectEqual(@as(u16, 0x202B), privacy.op_le_read_peer_resolvable_address);
    try testing.expectEqual(@as(u16, 0x202C), privacy.op_le_read_local_resolvable_address);
    try testing.expectEqual(@as(u16, 0x202D), privacy.op_le_set_address_resolution_enable);
    try testing.expectEqual(@as(u16, 0x202E), privacy.op_le_set_resolvable_private_address_timeout);
    try testing.expectEqual(@as(u16, 0x204E), privacy.op_le_set_privacy_mode);
}

test "privacy: LE Add Device To Resolving List frame (Vol 4 Part E 7.8.38)" {
    var buf: [64]u8 = undefined;
    // Peer_Identity_Address_Type(1) + Peer_Identity_Address(6) + Peer_IRK(16) + Local_IRK(16)。
    // 与 NimBLE 的 struct ble_hci_le_add_resolv_list_cp（hci_common.h:534）同一顺序。
    const n = try privacy.cmdAddDeviceToResolvingList(&buf, 0x01, static_id, irk_a, irk_b);
    try frame("012720" ++ "27" ++ "01" ++ "78563412e1cd" ++ "2b7e151628aed2a6abf7158809cf4f3c" ++ "3243f6a8885a308d313198a2e0370734", buf[0..n]);
    const m = try privacy.cmdAddDeviceToResolvingList(&buf, 0x00, public_id, irk_a, irk_b);
    try frame("012720" ++ "27" ++ "00" ++ "010203040506" ++ "2b7e151628aed2a6abf7158809cf4f3c" ++ "3243f6a8885a308d313198a2e0370734", buf[0..m]);
    try testing.expectError(error.NoSpace, privacy.cmdAddDeviceToResolvingList(buf[0..42], 0x01, static_id, irk_a, irk_b));
}

test "privacy: LE Add Device To Resolving List rejects a non-static random identity and a bad type (Vol 4 Part E 7.8.38)" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0xAA);
    // 最高两位置成 0b01：是可解析私有地址的子类型，不是静态地址 → controller 应回 0x12。
    var not_static = static_id;
    not_static.bytes[5] = 0x4D;
    try testing.expectError(error.BadParam, privacy.cmdAddDeviceToResolvingList(&buf, 0x01, not_static, irk_a, irk_b));
    try testing.expectError(error.BadParam, privacy.cmdAddDeviceToResolvingList(&buf, 0x02, static_id, irk_a, irk_b));
    // 值越界时不写半个字节。
    try testing.expectEqualSlices(u8, &@as([64]u8, @splat(0xAA)), &buf);
}

test "privacy: LE Remove / Clear / Read Resolving List Size frames (Vol 4 Part E 7.8.39, 7.8.40, 7.8.41)" {
    var buf: [16]u8 = undefined;
    const r = try privacy.cmdRemoveDeviceFromResolvingList(&buf, 0x01, static_id);
    try frame("012820" ++ "07" ++ "01" ++ "78563412e1cd", buf[0..r]);
    try testing.expectError(error.BadParam, privacy.cmdRemoveDeviceFromResolvingList(&buf, 0x03, static_id));
    const c = try privacy.cmdClearResolvingList(&buf);
    try frame("01292000", buf[0..c]);
    const s = try privacy.cmdReadResolvingListSize(&buf);
    try frame("012a2000", buf[0..s]);
}

test "privacy: LE Read Peer / Local Resolvable Address frames and return parameters (Vol 4 Part E 7.8.42, 7.8.43)" {
    var buf: [16]u8 = undefined;
    const p = try privacy.cmdReadPeerResolvableAddress(&buf, 0x00, public_id);
    try frame("012b20" ++ "07" ++ "00" ++ "010203040506", buf[0..p]);
    const l = try privacy.cmdReadLocalResolvableAddress(&buf, 0x01, static_id);
    try frame("012c20" ++ "07" ++ "01" ++ "78563412e1cd", buf[0..l]);
    // 返回：Status + 6 字节地址。地址取 vectors.zig:72 的 RPA 交叉值。
    const got = try privacy.parseResolvableAddress(&hex("00" ++ "54122a213c5a"));
    try testing.expectEqual(@as(u8, 0), got.status);
    try testing.expectEqualSlices(u8, &vectors.rpa_addr, &got.addr.bytes);
    // 列表里没有这个 Identity Address → 0x02（§7.8.42 的明文），可以只回 Status。
    try testing.expectEqual(@as(u8, 0x02), (try privacy.parseResolvableAddress(&hex("02"))).status);
    try testing.expectError(error.Short, privacy.parseResolvableAddress(""));
    try testing.expectError(error.Short, privacy.parseResolvableAddress(&hex("00")));
    try testing.expectError(error.Trailing, privacy.parseResolvableAddress(&hex("00" ++ "54122a213c5a" ++ "00")));
}

test "privacy: LE Set Address Resolution Enable frame (Vol 4 Part E 7.8.44)" {
    var buf: [8]u8 = undefined;
    const on = try privacy.cmdSetAddressResolutionEnable(&buf, true);
    try frame("012d20" ++ "01" ++ "01", buf[0..on]);
    const off = try privacy.cmdSetAddressResolutionEnable(&buf, false);
    try frame("012d20" ++ "01" ++ "00", buf[0..off]);
}

test "privacy: RPA_Timeout is seconds in 0x0001-0x0E10, default 0x0384 (Vol 4 Part E 7.8.45)" {
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(u16, 900), privacy.rpa_timeout_default);
    try testing.expectEqual(@as(u16, 3600), privacy.rpa_timeout_max);
    try testing.expectEqual(@as(u16, 1), privacy.rpa_timeout_min);
    const d = try privacy.cmdSetResolvablePrivateAddressTimeout(&buf, privacy.rpa_timeout_default);
    try frame("012e20" ++ "02" ++ "8403", buf[0..d]);
    const lo = try privacy.cmdSetResolvablePrivateAddressTimeout(&buf, 0x0001);
    try frame("012e20" ++ "02" ++ "0100", buf[0..lo]);
    const hi = try privacy.cmdSetResolvablePrivateAddressTimeout(&buf, 0x0E10);
    try frame("012e20" ++ "02" ++ "100e", buf[0..hi]);
    try testing.expectError(error.BadParam, privacy.cmdSetResolvablePrivateAddressTimeout(&buf, 0x0000));
    try testing.expectError(error.BadParam, privacy.cmdSetResolvablePrivateAddressTimeout(&buf, 0x0E11));
    try testing.expectError(error.BadParam, privacy.cmdSetResolvablePrivateAddressTimeout(&buf, 0xFFFF));
}

test "privacy: LE Set Privacy Mode frame (Vol 4 Part E 7.8.77)" {
    var buf: [16]u8 = undefined;
    const d = try privacy.cmdSetPrivacyMode(&buf, 0x01, static_id, .device);
    try frame("014e20" ++ "08" ++ "01" ++ "78563412e1cd" ++ "01", buf[0..d]);
    const n = try privacy.cmdSetPrivacyMode(&buf, 0x00, public_id, .network);
    try frame("014e20" ++ "08" ++ "00" ++ "010203040506" ++ "00", buf[0..n]);
    try testing.expectError(error.BadParam, privacy.cmdSetPrivacyMode(&buf, 0x02, public_id, .network));
}

test "privacy: LE Read Resolving List Size return, through the existing Command Complete decoder (Vol 4 Part E 7.7.14, 7.8.41)" {
    var stats: hci.Stats = .{};
    const cc = try hci.decodeCommandComplete(&hex("01" ++ "2a20" ++ "00" ++ "05"), &stats);
    try testing.expectEqual(@as(u16, 0x202A), cc.op);
    try testing.expectEqual(privacy.ResolvingListSize{ .status = 0, .size = 5 }, try privacy.parseResolvingListSize(cc.ret));
    // 失败只回 Status；成功只有 Status 是截断。
    try testing.expectEqual(@as(u8, 0x11), (try privacy.parseResolvingListSize(&hex("11"))).status);
    try testing.expectError(error.Short, privacy.parseResolvingListSize(""));
    try testing.expectError(error.Short, privacy.parseResolvingListSize(&hex("00")));
    try testing.expectError(error.Trailing, privacy.parseResolvingListSize(&hex("000500")));
}

// ---------------------------------------------------------------------------
// 列表
// ---------------------------------------------------------------------------

test "privacy: the list starts empty, fills in order and reports its entries (Vol 6 Part B 4.7; Vol 4 Part E 7.8.38)" {
    var list = privacy.List(4){};
    try testing.expectEqual(@as(usize, 0), list.len());
    try testing.expect(list.find(id_static) == null);
    try list.add(entryA());
    try list.add(entryB());
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqual(@as(?usize, 0), list.find(id_static));
    try testing.expectEqual(@as(?usize, 1), list.find(id_public));
    try testing.expectEqual(entryA(), list.at(0).?);
    try testing.expectEqual(entryB(), list.at(1).?);
    try testing.expect(list.at(2) == null);
}

test "privacy: a new entry is put in network privacy mode whatever the caller asked for (Vol 4 Part E 7.8.38)" {
    var list = privacy.List(2){};
    var e = entryA();
    e.privacy_mode = .device;
    try list.add(e);
    try testing.expectEqual(privacy.PrivacyMode.network, list.at(0).?.privacy_mode);
}

test "privacy: address comparison includes the address type (Vol 6 Part B 1.3)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    // 同样的 48 位当成公有地址：是另一台设备，列表里没有，也可以再加一条。
    try testing.expect(list.find(.{ .addr_type = .public, .addr = static_id }) == null);
    try list.add(.{ .peer_addr_type = .public, .peer_addr = static_id, .peer_irk = irk_b, .local_irk = irk_a });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqual(@as(?usize, 1), list.find(.{ .addr_type = .public, .addr = static_id }));
}

test "privacy: the list rejects each illegal add with its own reason (Vol 4 Part E 7.8.38)" {
    // 三种「内容」上的拒绝放在没满的列表上看，免得与「满了」混在一起。
    var list = privacy.List(4){};
    try list.add(entryA());
    try list.add(entryB());
    try testing.expectError(error.Duplicate, list.add(entryA()));
    // 同一 Identity Address、IRK 不同。
    try testing.expectError(error.IdentityConflict, list.add(.{ .peer_addr_type = .random, .peer_addr = static_id, .peer_irk = irk_b, .local_irk = irk_a }));
    // 同一个非零 Peer IRK 挂在别的 Identity Address 上。
    try testing.expectError(error.IrkConflict, list.add(.{ .peer_addr_type = .public, .peer_addr = third_id, .peer_irk = irk_a, .local_irk = irk_a }));
    try testing.expectEqual(@as(usize, 2), list.len());
    // 被拒的几次都没有改动列表。
    try testing.expectEqual(entryB(), list.at(1).?);
    // 装满之后再放，是 Memory Capacity Exceeded 那一种。
    try list.add(entryC());
    try list.add(.{ .peer_addr_type = .public, .peer_addr = static_id, .peer_irk = zero_irk, .local_irk = irk_b });
    try testing.expectEqual(@as(usize, 4), list.len());
    var fifth = third_id;
    fifth.bytes[5] ^= 0xFF;
    try testing.expectError(error.ListFull, list.add(.{ .peer_addr_type = .public, .peer_addr = fifth, .peer_irk = zero_irk }));
    // 列表满了时先看容量，再看内容（原文的顺序；NimBLE 同样先查容量：ble_hs_resolv.c:801）。
    try testing.expectError(error.ListFull, list.add(entryA()));
    try testing.expectEqual(@as(usize, 4), list.len());
    try testing.expectEqual(entryB(), list.at(1).?);
}

test "privacy: the list rejects a non-static random identity (Vol 4 Part E 7.8.38)" {
    var list = privacy.List(4){};
    var not_static = static_id;
    not_static.bytes[5] = 0x4D;
    try testing.expectError(error.BadParam, list.add(.{ .peer_addr_type = .random, .peer_addr = not_static, .peer_irk = irk_a }));
    // 同一个地址当成公有 Identity Address 就没问题。
    try list.add(.{ .peer_addr_type = .public, .peer_addr = not_static, .peer_irk = irk_a });
    try testing.expectEqual(@as(usize, 1), list.len());
}

test "privacy: all-zero peer IRKs may repeat; findByPeerIrk ignores them (Vol 4 Part E 7.8.38)" {
    var list = privacy.List(4){};
    try list.add(entryC());
    try list.add(.{ .peer_addr_type = .public, .peer_addr = public_id, .peer_irk = zero_irk, .local_irk = irk_b });
    try list.add(entryA());
    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expect(list.findByPeerIrk(zero_irk) == null);
    try testing.expectEqual(@as(?usize, 2), list.findByPeerIrk(irk_a));
    try testing.expect(list.findByPeerIrk(irk_b) == null);
}

test "privacy: list errors map to the controller status codes of each clause" {
    // 0x07 Memory Capacity Exceeded（§7.8.38）；0x02 Unknown Connection Identifier（§7.8.39）；0x12 Invalid HCI Command Parameters。
    try testing.expectEqual(@as(u8, 0x07), privacy.controllerError(error.ListFull));
    try testing.expectEqual(@as(u8, 0x02), privacy.controllerError(error.UnknownConnection));
    try testing.expectEqual(@as(u8, 0x12), privacy.controllerError(error.BadParam));
    try testing.expectEqual(@as(u8, 0x12), privacy.controllerError(error.Duplicate));
    try testing.expectEqual(@as(u8, 0x12), privacy.controllerError(error.IdentityConflict));
    try testing.expectEqual(@as(u8, 0x12), privacy.controllerError(error.IrkConflict));
}

test "privacy: remove reports an unknown identity, frees the slot and forgets the privacy mode (Vol 4 Part E 7.8.39, 7.8.77)" {
    var list = privacy.List(2){};
    try list.add(entryA());
    try list.add(entryB());
    try list.setPrivacyMode(id_static, .device);
    // 不在列表里 → Unknown Connection Identifier。NimBLE 同样回 ENOENT（ble_hs_resolv.c:863）。
    try testing.expectError(error.UnknownConnection, list.remove(.{ .addr_type = .public, .addr = third_id }));
    try testing.expectEqual(@as(usize, 2), list.len());
    try list.remove(id_static);
    try testing.expectEqual(@as(usize, 1), list.len());
    // 之后的条目前移（NimBLE 用 memmove：ble_hs_resolv.c:872）。
    try testing.expectEqual(entryB(), list.at(0).?);
    try testing.expectEqual(@as(?usize, 0), list.find(id_public));
    try list.add(entryC());
    try testing.expectEqual(@as(usize, 2), list.len());
    try list.remove(id_public);
    // 重新加进来：上一次设的 device mode 随条目一起被移除了，回到默认的 network。
    try list.add(entryA());
    try testing.expectEqual(privacy.PrivacyMode.network, list.at(1).?.privacy_mode);
}

test "privacy: clear empties the list and takes the privacy modes with it (Vol 4 Part E 7.8.40)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    try list.add(entryB());
    try list.setPrivacyMode(id_static, .device);
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.len());
    try testing.expect(list.at(0) == null);
    try testing.expect(list.find(id_static) == null);
    try testing.expectError(error.UnknownConnection, list.setPrivacyMode(id_static, .device));
    try list.add(entryA());
    try testing.expectEqual(privacy.PrivacyMode.network, list.at(0).?.privacy_mode);
}

test "privacy: Set Privacy Mode needs the identity to be on the list (Vol 4 Part E 7.8.77)" {
    var list = privacy.List(2){};
    try testing.expectError(error.UnknownConnection, list.setPrivacyMode(id_static, .device));
    try list.add(entryA());
    try list.setPrivacyMode(id_static, .device);
    try testing.expectEqual(privacy.PrivacyMode.device, list.at(0).?.privacy_mode);
    try list.setPrivacyMode(id_static, .network);
    try testing.expectEqual(privacy.PrivacyMode.network, list.at(0).?.privacy_mode);
    // 48 位相同、类型不同：不在列表里。
    try testing.expectError(error.UnknownConnection, list.setPrivacyMode(.{ .addr_type = .public, .addr = static_id }, .device));
}

test "privacy: command timing gate for the list and the resolution switch (Vol 4 Part E 7.8.38-40, 7.8.44, 7.8.77)" {
    var c = privacy.Ctl{};
    try testing.expect(!c.resolution_enabled);
    try c.checkModifyList();
    c.advertising = true;
    try c.checkModifyList();
    // 只有地址解析已启用时才拦。
    c.resolution_enabled = true;
    try testing.expectError(error.CommandDisallowed, c.checkModifyList());
    c.advertising = false;
    c.scanning = true;
    try testing.expectError(error.CommandDisallowed, c.checkModifyList());
    c.scanning = false;
    c.create_connection_pending = true;
    try testing.expectError(error.CommandDisallowed, c.checkModifyList());
    c.create_connection_pending = false;
    try c.checkModifyList();
}

test "privacy: LE Set Address Resolution Enable is gated whenever advertising, scanning or initiating is on (Vol 4 Part E 7.8.44)" {
    var c = privacy.Ctl{};
    try c.checkSetResolutionEnable();
    c.advertising = true;
    try testing.expectError(error.CommandDisallowed, c.checkSetResolutionEnable());
    c.advertising = false;
    c.scanning = true;
    try testing.expectError(error.CommandDisallowed, c.checkSetResolutionEnable());
    c.scanning = false;
    c.create_connection_pending = true;
    try testing.expectError(error.CommandDisallowed, c.setResolutionEnable(true));
    try testing.expect(!c.resolution_enabled);
    c.create_connection_pending = false;
    try c.setResolutionEnable(true);
    try testing.expect(c.resolution_enabled);
    try c.setResolutionEnable(true);
    try testing.expect(c.resolution_enabled);
    try c.setResolutionEnable(false);
    try testing.expect(!c.resolution_enabled);
}

// ---------------------------------------------------------------------------
// 主机侧地址解析
// ---------------------------------------------------------------------------

test "privacy: resolution tries every IRK in order and reports the matching entry (Vol 6 Part B 1.3.2.3)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    try list.add(entryB());
    const addr = try gap.generateRpa(irk_b, vectors.rpa_prand);
    var s = privacy.Scan{};
    const out = s.scan(&list, .peer, addr, 99);
    try testing.expectEqual(@as(?usize, 1), indexOf(out));
    try testing.expectEqual(@as(usize, 2), s.tried);
    try testing.expectEqual(@as(?usize, 1), privacy.resolve(&list, .peer, addr));
}

test "privacy: addresses that are not resolvable private addresses are never tried (Vol 6 Part B 1.3.2.3)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    // NimBLE 的 ble_gap_rpa_resolve 同样先拒非 RPA（ble_gap.c:11096-11097）。
    var nrpa = static_id;
    nrpa.bytes[5] = 0x0D;
    var s = privacy.Scan{};
    try testing.expectEqual(privacy.Outcome.not_resolvable, s.scan(&list, .peer, nrpa, 99));
    try testing.expectEqual(privacy.Outcome.not_resolvable, s.scan(&list, .peer, static_id, 99));
    try testing.expectEqual(@as(usize, 0), s.tried);
}

test "privacy: all-zero IRKs are skipped without spending budget (Vol 6 Part B 4.7)" {
    var list = privacy.List(4){};
    try list.add(entryC());
    try list.add(entryA());
    const addr = try gap.generateRpa(irk_a, vectors.rpa_prand);
    var s = privacy.Scan{};
    // 预算 1：第 0 条的 Peer IRK 全 0，不算一次尝试，所以第 1 条仍在本轮预算内。
    const out = s.scan(&list, .peer, addr, 1);
    try testing.expectEqual(@as(?usize, 1), indexOf(out));
    try testing.expectEqual(@as(usize, 1), s.tried);
    // Local IRK 那一侧：第 0 条的 Local IRK 是 irk_a，所以用 .local 解析会落到第 0 条。
    try testing.expectEqual(@as(?usize, 0), privacy.resolve(&list, .local, addr));
}

test "privacy: not found only after every IRK was tried (Vol 6 Part B 1.3.2.3)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    try list.add(entryB());
    const addr = try gap.generateRpa(zero_irk, vectors.rpa_prand);
    var s = privacy.Scan{};
    try testing.expectEqual(privacy.Outcome.not_found, s.scan(&list, .peer, addr, 99));
    try testing.expectEqual(@as(usize, 2), s.tried);
    try testing.expect(privacy.resolve(&list, .peer, addr) == null);
}

test "privacy: running out of budget is not a verdict; the scan resumes at the next event (Vol 6 Part B 1.3.2.3)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    try list.add(entryB());
    const addr = try gap.generateRpa(irk_b, vectors.rpa_prand);
    var s = privacy.Scan{};
    // 预算 1：只试了第 0 条，没中。这不是 not_found，是没试完。
    try testing.expectEqual(privacy.Outcome.timed_out, s.scan(&list, .peer, addr, 1));
    try testing.expectEqual(@as(usize, 1), s.tried);
    try testing.expectEqual(@as(usize, 1), s.next);
    // 续扫：从第 1 条接着，不重试第 0 条。
    try testing.expectEqual(@as(?usize, 1), indexOf(s.scan(&list, .peer, addr, 1)));
    try testing.expectEqual(@as(usize, 2), s.tried);
    // 预算 0：一步都不走。
    s.reset();
    try testing.expectEqual(privacy.Outcome.timed_out, s.scan(&list, .peer, addr, 0));
    try testing.expectEqual(@as(usize, 0), s.next);
    try testing.expectEqual(@as(usize, 0), s.tried);
}

test "privacy: a local RPA is resolved with the Local IRK of the same record (Vol 6 Part B 4.7, 6.3)" {
    var list = privacy.List(4){};
    try list.add(entryB());
    const target = try gap.generateRpa(entryB().local_irk, vectors.rpa_prand);
    // 发给本端的 RPA 用 Local IRK 解得开；当它是「对端的 RPA」用 Peer IRK 去解则解不开。
    try testing.expect(privacy.resolve(&list, .peer, target) == null);
    try testing.expectEqual(@as(?usize, 0), privacy.resolve(&list, .local, target));
    // 再放一条 Local IRK 相同的记录：按列表顺序先碰到谁就是谁。
    try list.add(.{ .peer_addr_type = .random, .peer_addr = static_id, .peer_irk = irk_a, .local_irk = irk_a });
    try testing.expectEqual(@as(?usize, 0), privacy.resolve(&list, .local, target));
}

// ---------------------------------------------------------------------------
// 独立 oracle 的差分
// ---------------------------------------------------------------------------

const Row = struct { irk: [16]u8, prand: [3]u8, addr: [6]u8 };

// 24 组随机 (IRK, prand) → RPA。来源：`/tmp/s31-oracle/privacy_oracle.py gen 24 0x20261124`。

const o01_irk: [16]u8 = hex("c0bb5518c495f520f945893a14b9fcb7");
const o01_prand: [3]u8 = hex("1a006e");
const o01_addr: [6]u8 = hex("671f4d1a006e");
const o02_irk: [16]u8 = hex("0be2cbebaa548488d44e7bdcdb8bf7eb");
const o02_prand: [3]u8 = hex("a40a40");
const o02_addr: [6]u8 = hex("f6472aa40a40");
const o03_irk: [16]u8 = hex("370a2f1580e606ac7db1b0fd9e2685d5");
const o03_prand: [3]u8 = hex("80fd52");
const o03_addr: [6]u8 = hex("20414480fd52");
const o04_irk: [16]u8 = hex("91cd763ef40c60778f3870780bfcfe81");
const o04_prand: [3]u8 = hex("3ed55f");
const o04_addr: [6]u8 = hex("60e4723ed55f");
const o05_irk: [16]u8 = hex("aebb52b27acb5e81248ddcb2e3524c73");
const o05_prand: [3]u8 = hex("01f16d");
const o05_addr: [6]u8 = hex("24ab6701f16d");
const o06_irk: [16]u8 = hex("5ba9e08fe8ddfd121dc0f82607fb6e48");
const o06_prand: [3]u8 = hex("e5f257");
const o06_addr: [6]u8 = hex("c59e84e5f257");
const o07_irk: [16]u8 = hex("584de45611bb5ba311c6141e29badece");
const o07_prand: [3]u8 = hex("369a47");
const o07_addr: [6]u8 = hex("038c38369a47");
const o08_irk: [16]u8 = hex("619bc3206d04a826d368447bb4c838c4");
const o08_prand: [3]u8 = hex("13065b");
const o08_addr: [6]u8 = hex("58b9cf13065b");
const o09_irk: [16]u8 = hex("a8ce66094ebe6c509bc4937946b081cd");
const o09_prand: [3]u8 = hex("4e3346");
const o09_addr: [6]u8 = hex("7beeef4e3346");
const o10_irk: [16]u8 = hex("659c5e6063eb8fe43385d250b9d9cab7");
const o10_prand: [3]u8 = hex("371c56");
const o10_addr: [6]u8 = hex("0ad8d9371c56");
const o11_irk: [16]u8 = hex("c78ac0f7815e478c10553dc9adce7b53");
const o11_prand: [3]u8 = hex("2d2543");
const o11_addr: [6]u8 = hex("6d577f2d2543");
const o12_irk: [16]u8 = hex("3f9a810dc6b4e51e4799c0dbed901705");
const o12_prand: [3]u8 = hex("cada47");
const o12_addr: [6]u8 = hex("f99839cada47");
const o13_irk: [16]u8 = hex("2db2f1da4cbe70e3533fcf0aba5ec494");
const o13_prand: [3]u8 = hex("6c5b51");
const o13_addr: [6]u8 = hex("edc9aa6c5b51");
const o14_irk: [16]u8 = hex("84c1cc2db0aeeec177800133e65bedf4");
const o14_prand: [3]u8 = hex("c4314d");
const o14_addr: [6]u8 = hex("0b54cfc4314d");
const o15_irk: [16]u8 = hex("52cd0e87d150bf3fbadb818948b036d8");
const o15_prand: [3]u8 = hex("7c2175");
const o15_addr: [6]u8 = hex("e7a98b7c2175");
const o16_irk: [16]u8 = hex("dbca3f574fbf5738cdbc5e0fd16e5f39");
const o16_prand: [3]u8 = hex("f31a75");
const o16_addr: [6]u8 = hex("887246f31a75");
const o17_irk: [16]u8 = hex("60b0739a70041fcde97d5ebb3a4c207f");
const o17_prand: [3]u8 = hex("fab65b");
const o17_addr: [6]u8 = hex("e0ca19fab65b");
const o18_irk: [16]u8 = hex("0a150e056656923372e6f6fc254b0d54");
const o18_prand: [3]u8 = hex("da2074");
const o18_addr: [6]u8 = hex("8e55b5da2074");
const o19_irk: [16]u8 = hex("7c4c4d1f1a96b1ec55fa17fa8056c04a");
const o19_prand: [3]u8 = hex("5ac155");
const o19_addr: [6]u8 = hex("a01a985ac155");
const o20_irk: [16]u8 = hex("12c9b8e7b1b784473a27c4eedde1b624");
const o20_prand: [3]u8 = hex("487676");
const o20_addr: [6]u8 = hex("172c79487676");
const o21_irk: [16]u8 = hex("c550dadef8644b1020347e87941fd965");
const o21_prand: [3]u8 = hex("376f4e");
const o21_addr: [6]u8 = hex("7fcbcf376f4e");
const o22_irk: [16]u8 = hex("1cf160dbd90b2660ef123b0e7dbc3da4");
const o22_prand: [3]u8 = hex("49617b");
const o22_addr: [6]u8 = hex("05a87849617b");
const o23_irk: [16]u8 = hex("a75b3b8909671e696a4cb2d0d8db6cfd");
const o23_prand: [3]u8 = hex("945677");
const o23_addr: [6]u8 = hex("8fe38f945677");
const o24_irk: [16]u8 = hex("22484001c0fecb35919ce014312edba0");
const o24_prand: [3]u8 = hex("5f457f");
const o24_addr: [6]u8 = hex("9890455f457f");

const rows = [_]Row{
    .{ .irk = o01_irk, .prand = o01_prand, .addr = o01_addr },
    .{ .irk = o02_irk, .prand = o02_prand, .addr = o02_addr },
    .{ .irk = o03_irk, .prand = o03_prand, .addr = o03_addr },
    .{ .irk = o04_irk, .prand = o04_prand, .addr = o04_addr },
    .{ .irk = o05_irk, .prand = o05_prand, .addr = o05_addr },
    .{ .irk = o06_irk, .prand = o06_prand, .addr = o06_addr },
    .{ .irk = o07_irk, .prand = o07_prand, .addr = o07_addr },
    .{ .irk = o08_irk, .prand = o08_prand, .addr = o08_addr },
    .{ .irk = o09_irk, .prand = o09_prand, .addr = o09_addr },
    .{ .irk = o10_irk, .prand = o10_prand, .addr = o10_addr },
    .{ .irk = o11_irk, .prand = o11_prand, .addr = o11_addr },
    .{ .irk = o12_irk, .prand = o12_prand, .addr = o12_addr },
    .{ .irk = o13_irk, .prand = o13_prand, .addr = o13_addr },
    .{ .irk = o14_irk, .prand = o14_prand, .addr = o14_addr },
    .{ .irk = o15_irk, .prand = o15_prand, .addr = o15_addr },
    .{ .irk = o16_irk, .prand = o16_prand, .addr = o16_addr },
    .{ .irk = o17_irk, .prand = o17_prand, .addr = o17_addr },
    .{ .irk = o18_irk, .prand = o18_prand, .addr = o18_addr },
    .{ .irk = o19_irk, .prand = o19_prand, .addr = o19_addr },
    .{ .irk = o20_irk, .prand = o20_prand, .addr = o20_addr },
    .{ .irk = o21_irk, .prand = o21_prand, .addr = o21_addr },
    .{ .irk = o22_irk, .prand = o22_prand, .addr = o22_addr },
    .{ .irk = o23_irk, .prand = o23_prand, .addr = o23_addr },
    .{ .irk = o24_irk, .prand = o24_prand, .addr = o24_addr },
};

test "privacy: RPA generation matches the independent oracle on 24 random IRK/prand pairs" {
    var mismatch: usize = 0;
    for (rows) |r| {
        const got = try gap.generateRpa(r.irk, r.prand);
        if (!std.mem.eql(u8, &got.bytes, &r.addr)) mismatch += 1;
    }
    try testing.expectEqual(@as(usize, 0), mismatch);
    try testing.expectEqual(@as(usize, 24), rows.len);
}

test "privacy: every oracle RPA resolves back to its own IRK and to no other (Vol 6 Part B 1.3.2.3)" {
    // 24 把 IRK 全放进列表，每一行只允许解析回自己那一条。
    var list = privacy.List(24){};
    for (rows, 0..) |r, i| {
        var id = public_id;
        id.bytes[0] = @intCast(i);
        try list.add(.{ .peer_addr_type = .public, .peer_addr = id, .peer_irk = r.irk, .local_irk = irk_b });
    }
    var wrong: usize = 0;
    for (rows, 0..) |r, i| {
        const hit = privacy.resolve(&list, .peer, .{ .bytes = r.addr });
        if (hit == null or hit.? != i) wrong += 1;
        // 用相邻那把 IRK 直接解：必须解不开。
        const other = rows[(i + 1) % rows.len].irk;
        if (gap.resolve(.{ .bytes = r.addr }, other)) wrong += 1;
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

// ---------------------------------------------------------------------------
// 性质测试
// ---------------------------------------------------------------------------

test "privacy: property, random IRK and prand survive generate then resolve (200 rounds)" {
    var prng = std.Random.DefaultPrng.init(0x5a1a);
    const rand = prng.random();
    var irk: [16]u8 = undefined;
    var other: [16]u8 = undefined;
    var prand: [3]u8 = undefined;
    var ok: usize = 0;
    for (0..200) |_| {
        rand.bytes(&irk);
        rand.bytes(&other);
        rand.bytes(&prand);
        // prand 的最高两位必须是 0b01；22 位随机部分不得全 0 或全 1（§1.3.2.2）。
        prand[2] = (prand[2] & 0x3F) | 0x40;
        if ((prand[2] & 0x3F) == 0 and prand[0] == 0 and prand[1] == 0) prand[0] = 1;
        if ((prand[2] & 0x3F) == 0x3F and prand[0] == 0xFF and prand[1] == 0xFF) prand[0] ^= 1;
        const a = try gap.generateRpa(irk, prand);
        // prand 原样留在地址的高 3 字节；用自己的 IRK 解得开，用别人的解不开。
        const kept = std.mem.eql(u8, &a.prand(), &prand);
        const hit = gap.resolve(a, irk);
        const miss = !gap.resolve(a, other);
        const kind = a.randomKind() == .resolvable_private;
        if (kept and hit and miss and kind) ok += 1;
    }
    try testing.expectEqual(@as(usize, 200), ok);
}

test "privacy: property, a random RPA from any entry resolves back to that entry (64 rounds)" {
    var prng = std.Random.DefaultPrng.init(0x2026_1114);
    const rand = prng.random();
    var list = privacy.List(8){};
    var irks: [8][16]u8 = undefined;
    var ok: usize = 0;
    for (0..64) |_| {
        list.clear();
        const n: usize = rand.intRangeAtMost(u8, 1, 8);
        for (0..n) |i| {
            rand.bytes(&irks[i]);
            var id = public_id;
            rand.bytes(id.bytes[0..4]);
            try list.add(.{ .peer_addr_type = .public, .peer_addr = id, .peer_irk = irks[i], .local_irk = irk_b });
        }
        const k = rand.intRangeLessThan(usize, 0, n);
        var prand: [3]u8 = undefined;
        rand.bytes(&prand);
        prand[2] = (prand[2] & 0x3F) | 0x40;
        const hit = privacy.resolve(&list, .peer, try gap.generateRpa(irks[k], prand));
        if (hit != null and hit.? == k) ok += 1;
    }
    try testing.expectEqual(@as(usize, 64), ok);
}

// ---------------------------------------------------------------------------
// 本端 RPA 的定时更新
// ---------------------------------------------------------------------------

test "privacy: RPA timer expires exactly when the timeout has elapsed (Vol 6 Part B 6.1)" {
    var t = privacy.RpaTimer{};
    try testing.expectEqual(privacy.rpa_timeout_default, t.timeout_s);
    try testing.expect(!t.expired(1000));
    try t.setTimeout(15, 0);
    t.restart(1000);
    try testing.expect(!t.expired(1000));
    try testing.expect(!t.expired(1014));
    try testing.expect(t.expired(1015));
    try testing.expectEqual(@as(u32, 15), t.elapsed(1015));
    t.restart(1015);
    try testing.expect(!t.expired(1029));
    try testing.expect(t.expired(1030));
    try testing.expect(t.expired(999_999));
}

test "privacy: RPA timer bounds, restart on a new timeout, stop, and counter wrap-around (Vol 4 Part E 7.8.45)" {
    var t = privacy.RpaTimer{};
    try testing.expectError(error.BadParam, t.setTimeout(0, 0));
    try testing.expectError(error.BadParam, t.setTimeout(0x0E11, 0));
    try testing.expectEqual(privacy.rpa_timeout_default, t.timeout_s);
    try t.setTimeout(0x0E10, 0);
    try testing.expectEqual(@as(u16, 0x0E10), t.timeout_s);
    // 改超时时定时器在走：从改的那一刻重新计时（NimBLE：ble_hs_resolv.c:1054）。
    var u = privacy.RpaTimer{};
    u.restart(100);
    try u.setTimeout(20, 110);
    try testing.expectEqual(@as(u32, 10), u.elapsed(120));
    try testing.expect(!u.expired(129));
    try testing.expect(u.expired(130));
    // 停掉之后永不到期；没在计时的定时器改超时也不会被启动。
    u.stop();
    try testing.expect(!u.expired(999_999));
    try testing.expectEqual(@as(u32, 0), u.elapsed(999_999));
    var v = privacy.RpaTimer{};
    try v.setTimeout(5, 50);
    try testing.expect(!v.armed);
    try testing.expect(!v.expired(1000));
    // 秒计数回绕：0xFFFFFFF0 起步，20 s 后是 0x00000004。
    var w = privacy.RpaTimer{};
    w.restart(0xFFFF_FFF0);
    try w.setTimeout(20, 0xFFFF_FFF0);
    try testing.expectEqual(@as(u32, 16), w.elapsed(0));
    try testing.expect(!w.expired(3));
    try testing.expect(w.expired(4));
}

test "privacy: local RPA regenerates on the timer and resolves with the local IRK (Vol 6 Part B 6.1, 1.3.2.2)" {
    var me = privacy.LocalRpa{ .irk = irk_a };
    // 地址期望值是 vectors.zig:70-76 的交叉值（cryptography 算出）。
    try me.regenerate(vectors.rpa_prand, 0);
    try testing.expectEqualSlices(u8, &vectors.rpa_addr, &me.addr.bytes);
    try testing.expectEqual(privacy.Identity{ .addr_type = .random, .addr = .{ .bytes = vectors.rpa_addr } }, me.address(id_public));
    try testing.expectEqual(@as(u32, 1), me.changes);
    try testing.expect(!me.needsNewAddress(899));
    try testing.expect(me.needsNewAddress(900));
    try me.regenerate(vectors.rpa_prand_2, 900);
    try testing.expectEqualSlices(u8, &vectors.rpa_addr_2, &me.addr.bytes);
    try testing.expectEqual(@as(u32, 2), me.changes);
    try testing.expect(!me.needsNewAddress(1799));
    try testing.expect(gap.resolve(me.addr, irk_a));
    // prand 不合规（最高两位不是 0b01）→ 拒绝，地址与计数都不动。
    try testing.expectError(error.BadParam, me.regenerate(.{ 0x00, 0x00, 0x00 }, 1800));
    try testing.expectEqual(@as(u32, 2), me.changes);
}

test "privacy: an all-zero local IRK means the identity address is used and no RPA is generated (Vol 6 Part B 4.7, 6.5)" {
    var me = privacy.LocalRpa{};
    try testing.expectEqual(privacy.Identity{ .addr_type = .random, .addr = static_id }, me.address(id_static));
    try testing.expect(!me.needsNewAddress(999_999));
    try testing.expectError(error.BadParam, me.regenerate(vectors.rpa_prand, 0));
    try testing.expectEqual(@as(u32, 0), me.changes);
}

test "privacy: the directed-advertising target is an RPA only when the peer IRK is non-zero (Vol 6 Part B 6.2.2)" {
    const t = try privacy.targetAddress(entryA(), vectors.rpa_prand_2);
    try testing.expectEqual(gap.Addr.Type.random, t.addr_type);
    try testing.expectEqualSlices(u8, &vectors.rpa_addr_2, &t.addr.bytes);
    try testing.expect(gap.resolve(t.addr, irk_a));
    const u = try privacy.targetAddress(entryC(), vectors.rpa_prand_2);
    try testing.expectEqual(privacy.Identity{ .addr_type = .public, .addr = third_id }, u);
}

// ---------------------------------------------------------------------------
// 两种隐私模式下的接受规则
// ---------------------------------------------------------------------------

test "privacy: network mode rejects the identity address, device mode accepts it, a zero peer IRK always accepts it (Vol 6 Part B 4.7; Vol 3 Part C 10.7)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    try list.add(entryC());
    try testing.expectEqual(privacy.PrivacyMode.network, list.at(0).?.privacy_mode);
    // 网络隐私模式：不接受已分发 IRK 的对端直接用 Identity Address。
    try testing.expectEqual(privacy.Verdict.reject, privacy.filter(&list, true, .random, static_id));
    try list.setPrivacyMode(id_static, .device);
    try testing.expectEqual(accept_a, privacy.filter(&list, true, .random, static_id));
    // Peer IRK 全 0：只接受 Identity Address——不管这一条是什么模式。
    try list.setPrivacyMode(.{ .addr_type = .public, .addr = third_id }, .network);
    try testing.expectEqual(privacy.Verdict{ .accept = .{ .index = 1, .resolved = false } }, privacy.filter(&list, true, .public, third_id));
    // 列表外设备的 Identity Address：隐私规则不表态。
    var other = static_id;
    other.bytes[0] ^= 0xFF;
    try testing.expectEqual(privacy.Verdict.filter_policy, privacy.filter(&list, true, .random, other));
}

test "privacy: an RPA is accepted only when it resolves with a listed peer IRK, and only while resolution is enabled (Vol 6 Part B 6.2.1, 6.3)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    const rpa = try gap.generateRpa(irk_a, vectors.rpa_prand);
    try testing.expectEqual(privacy.Verdict.filter_policy, privacy.filter(&list, false, .random, rpa));
    try testing.expectEqual(accept_a_rpa, privacy.filter(&list, true, .random, rpa));
    // 设备隐私模式同样接受对端用 IRK 生成的 RPA。
    try list.setPrivacyMode(id_static, .device);
    try testing.expectEqual(accept_a_rpa, privacy.filter(&list, true, .random, rpa));
    // 列表里的 IRK 都解不开的 RPA：交给过滤策略。
    const other = try gap.generateRpa(irk_b, vectors.rpa_prand_2);
    try testing.expectEqual(privacy.Verdict.filter_policy, privacy.filter(&list, true, .random, other));
}

test "privacy: non-resolvable and reserved random addresses are left to the filter policy (Vol 6 Part B 6.2.1)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    var nrpa = static_id;
    nrpa.bytes[5] = 0x0D;
    var reserved = static_id;
    reserved.bytes[5] = 0x8D;
    try testing.expectEqual(privacy.Verdict.filter_policy, privacy.filter(&list, true, .random, nrpa));
    try testing.expectEqual(privacy.Verdict.filter_policy, privacy.filter(&list, true, .random, reserved));
}

test "privacy: once resolved, the address reported upward is the identity address (Vol 6 Part B 4.7)" {
    var list = privacy.List(4){};
    try list.add(entryA());
    const rpa = try gap.generateRpa(irk_a, vectors.rpa_prand);
    const v = privacy.filter(&list, true, .random, rpa);
    try testing.expectEqual(id_static, privacy.reportedAddress(&list, v).?);
    try testing.expect(privacy.reportedAddress(&list, .filter_policy) == null);
    try testing.expect(privacy.reportedAddress(&list, .reject) == null);
}

// ---------------------------------------------------------------------------
// LE Power Control：OpCode、事件掩码、命令与返回参数
// ---------------------------------------------------------------------------

fn frame(comptime want: []const u8, got: []const u8) !void {
    try testing.expectEqualSlices(u8, &hex(want), got);
}

test "power: opcodes, subevent codes and the two LE event mask bits (Vol 4 Part E 7.8.74, 7.8.117-121, 7.7.65.32-33, 7.8.1)" {
    try testing.expectEqual(@as(u16, 0x204B), power.op_le_read_transmit_power);
    try testing.expectEqual(@as(u16, 0x2076), power.op_le_enhanced_read_transmit_power_level);
    try testing.expectEqual(@as(u16, 0x2077), power.op_le_read_remote_transmit_power_level);
    try testing.expectEqual(@as(u16, 0x2078), power.op_le_set_path_loss_reporting_parameters);
    try testing.expectEqual(@as(u16, 0x2079), power.op_le_set_path_loss_reporting_enable);
    try testing.expectEqual(@as(u16, 0x207A), power.op_le_set_transmit_power_reporting_enable);
    try testing.expectEqual(@as(u8, 0x20), power.subevent_path_loss_threshold);
    try testing.expectEqual(@as(u8, 0x21), power.subevent_transmit_power_reporting);
    // LE Set Event Mask 的位表：bit 31、bit 32。
    try testing.expectEqual(@as(u64, 0x0000_0000_8000_0000), power.le_event_mask_path_loss_threshold);
    try testing.expectEqual(@as(u64, 0x0000_0001_0000_0000), power.le_event_mask_transmit_power_reporting);
    // 默认掩码 0x1F 再打开这两位，走现成的 LE_Set_Event_Mask 编码器（§7.8.1）。
    var buf: [16]u8 = undefined;
    const mask: u64 = 0x1F | power.le_event_mask_path_loss_threshold | power.le_event_mask_transmit_power_reporting;
    const n = try cmd.leSetEventMask(&buf, mask);
    try frame("01012008" ++ "1f000080" ++ "01000000", buf[0..n]);
}

test "power: LE Read Transmit Power frame and return parameters (Vol 4 Part E 7.8.74)" {
    var buf: [16]u8 = undefined;
    const n = try power.cmdReadTransmitPower(&buf);
    try frame("014b2000", buf[0..n]);
    // Min_TX_Power(1) + Max_TX_Power(1)：−32 dBm 与 +20 dBm。
    try testing.expectEqual(power.TxPowerRange{ .status = 0, .min_dbm = -32, .max_dbm = 20 }, try power.parseTransmitPowerRange(&hex("00e014")));
    try testing.expectEqual(power.TxPowerRange{ .status = 0, .min_dbm = -127, .max_dbm = 0 }, try power.parseTransmitPowerRange(&hex("008100")));
    try testing.expectEqual(@as(u8, 0x11), (try power.parseTransmitPowerRange(&hex("11"))).status);
    // 范围是 −127…20：−128（0x80）、21（0x15）、126、127 都不在范围内。
    try testing.expectError(error.BadParam, power.parseTransmitPowerRange(&hex("008000")));
    try testing.expectError(error.BadParam, power.parseTransmitPowerRange(&hex("000015")));
    try testing.expectError(error.BadParam, power.parseTransmitPowerRange(&hex("00007e")));
    try testing.expectError(error.BadParam, power.parseTransmitPowerRange(&hex("00007f")));
    try testing.expectError(error.BadParam, power.parseTransmitPowerRange(&hex("001405")));
    try testing.expectError(error.Short, power.parseTransmitPowerRange(""));
    try testing.expectError(error.Short, power.parseTransmitPowerRange(&hex("00")));
    try testing.expectError(error.Trailing, power.parseTransmitPowerRange(&hex("00e01400")));
}

test "power: LE Enhanced Read Transmit Power Level frame and return parameters (Vol 4 Part E 7.8.117)" {
    var buf: [16]u8 = undefined;
    const n = try power.cmdEnhancedReadTransmitPowerLevel(&buf, 0x0042, .le_1m);
    try frame("017620" ++ "03" ++ "4200" ++ "01", buf[0..n]);
    const m = try power.cmdEnhancedReadTransmitPowerLevel(&buf, 0x0042, .coded_s2);
    try frame("017620" ++ "03" ++ "4200" ++ "04", buf[0..m]);
    try testing.expectError(error.BadParam, power.cmdEnhancedReadTransmitPowerLevel(&buf, 0x0F00, .le_1m));
    const r = try power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "4200" ++ "01" ++ "04" ++ "14"));
    try testing.expectEqual(power.TxPowerLevel{ .status = 0, .handle = 0x0042, .phy = .le_1m, .current = 4, .max_dbm = 20 }, r);
    // Current_TX_Power_Level = 0x7F：不可用。
    const u = try power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "4200" ++ "02" ++ "7f" ++ "14"));
    try testing.expect(u.current == null);
    try testing.expectEqual(power.Phy.le_2m, u.phy);
    try testing.expectEqual(@as(u8, 0x02), (try power.parseEnhancedReadTransmitPowerLevel(&hex("02"))).status);
    try testing.expectError(error.BadParam, power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "4200" ++ "00" ++ "04" ++ "14")));
    try testing.expectError(error.BadParam, power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "4200" ++ "05" ++ "04" ++ "14")));
    try testing.expectError(error.BadParam, power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "4200" ++ "01" ++ "15" ++ "14")));
    try testing.expectError(error.BadParam, power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "4200" ++ "01" ++ "04" ++ "7e")));
    try testing.expectError(error.BadParam, power.parseEnhancedReadTransmitPowerLevel(&hex("00" ++ "00f0" ++ "01" ++ "04" ++ "14")));
    try testing.expectError(error.Short, power.parseEnhancedReadTransmitPowerLevel(&hex("0042000101")));
    try testing.expectError(error.Trailing, power.parseEnhancedReadTransmitPowerLevel(&hex("00420001011400")));
}

test "power: LE Read Remote Transmit Power Level frame; its answer is an event with Reason 0x02 (Vol 4 Part E 7.8.118, 7.7.65.33)" {
    var buf: [16]u8 = undefined;
    const n = try power.cmdReadRemoteTransmitPowerLevel(&buf, 0x0042, .le_2m);
    try frame("017720" ++ "03" ++ "4200" ++ "02", buf[0..n]);
    // 这条命令没有返回参数（回 Command Status），结果在事件里。
    const e = try power.decodeEvent(&hex("043e" ++ "09" ++ "21" ++ "00" ++ "4200" ++ "02" ++ "02" ++ "0a" ++ "00" ++ "00"));
    const r = e.transmit_power_reporting;
    try testing.expectEqual(@as(?u8, 0), r.status);
    try testing.expectEqual(power.Reason.read_remote_completed, r.reason);
    try testing.expectEqual(@as(?i8, 0), r.delta);
    try testing.expectEqual(power.Level{ .dbm = 10 }, r.level);
}

test "power: path loss parameters, their four boundaries and the frame (Vol 4 Part E 7.8.119)" {
    try loss_params.validate();
    try testing.expectEqual(@as(u8, 0x5A), loss_params.highUp());
    try testing.expectEqual(@as(u8, 0x46), loss_params.highDown());
    try testing.expectEqual(@as(u8, 0x35), loss_params.lowUp());
    try testing.expectEqual(@as(u8, 0x2B), loss_params.lowDown());
    // 与 NimBLE 的 ble_gap_set_path_loss_reporting_param 同一顺序（ble_gap.c:10569-10574）。
    var buf: [24]u8 = undefined;
    const n = try power.cmdSetPathLossReportingParameters(&buf, 0x0042, loss_params);
    try frame("017820" ++ "08" ++ "4200" ++ "50" ++ "0a" ++ "30" ++ "05" ++ "0600", buf[0..n]);
    try testing.expectError(error.BadParam, power.cmdSetPathLossReportingParameters(&buf, 0x0F00, loss_params));
}

test "power: the four path loss parameter checks each reject, with their own reason (Vol 4 Part E 7.8.119)" {
    // High_Threshold + High_Hysteresis > 0xFF：0xF6 + 0x0A = 0x100。
    try testing.expectError(error.HighThresholdOverflow, (power.PathLossParams{ .high_threshold = 0xF6, .high_hysteresis = 0x0A, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 0 }).validate());
    // 正好 0xFF 是允许的。
    try (power.PathLossParams{ .high_threshold = 0xF5, .high_hysteresis = 0x0A, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 0 }).validate();
    // Low_Threshold < Low_Hysteresis：0x05 < 0x06。
    try testing.expectError(error.LowThresholdUnderflow, (power.PathLossParams{ .high_threshold = 0x50, .high_hysteresis = 0x0A, .low_threshold = 0x05, .low_hysteresis = 0x06, .min_time_spent = 0 }).validate());
    // Low_Threshold > High_Threshold：0x31 > 0x30。
    try testing.expectError(error.LowAboveHigh, (power.PathLossParams{ .high_threshold = 0x30, .high_hysteresis = 0x00, .low_threshold = 0x31, .low_hysteresis = 0x00, .min_time_spent = 0 }).validate());
    // Low + Low_Hysteresis > High − High_Hysteresis：0x31 > 0x30。
    try testing.expectError(error.BandsOverlap, (power.PathLossParams{ .high_threshold = 0x30, .high_hysteresis = 0x00, .low_threshold = 0x30, .low_hysteresis = 0x01, .min_time_spent = 0 }).validate());
    // 两个边界相等是允许的（“shall be greater than or equal to”）。
    try (power.PathLossParams{ .high_threshold = 0x31, .high_hysteresis = 0x00, .low_threshold = 0x30, .low_hysteresis = 0x01, .min_time_spent = 0 }).validate();
    // 同时违反几条时报最前面那一条。
    try testing.expectError(error.HighThresholdOverflow, (power.PathLossParams{ .high_threshold = 0xF6, .high_hysteresis = 0x0A, .low_threshold = 0x00, .low_hysteresis = 0x05, .min_time_spent = 0 }).validate());
    try testing.expectError(error.LowThresholdUnderflow, (power.PathLossParams{ .high_threshold = 0x10, .high_hysteresis = 0x00, .low_threshold = 0x00, .low_hysteresis = 0x05, .min_time_spent = 0 }).validate());
}

test "power: High_Threshold 0xFF means no high zone (Vol 4 Part E 7.8.119)" {
    try loss_two_zones.validate();
    try testing.expect(!loss_two_zones.highUsed());
    try testing.expect(loss_params.highUsed());
    var buf: [24]u8 = undefined;
    const n = try power.cmdSetPathLossReportingParameters(&buf, 0x0042, loss_two_zones);
    try frame("017820" ++ "08" ++ "4200" ++ "ff" ++ "00" ++ "30" ++ "05" ++ "0000", buf[0..n]);
    // 高阈值不用时，四条检查照样适用。
    try testing.expectError(error.HighThresholdOverflow, (power.PathLossParams{ .high_threshold = 0xFF, .high_hysteresis = 0x01, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 0 }).validate());
    try testing.expectError(error.BandsOverlap, (power.PathLossParams{ .high_threshold = 0xFF, .high_hysteresis = 0x00, .low_threshold = 0xC0, .low_hysteresis = 0xC0, .min_time_spent = 0 }).validate());
    // 非法参数不写字节。
    @memset(&buf, 0xAA);
    try testing.expectError(error.BadParam, power.cmdSetPathLossReportingParameters(&buf, 0x0042, .{ .high_threshold = 0x30, .high_hysteresis = 0x00, .low_threshold = 0x30, .low_hysteresis = 0x01, .min_time_spent = 0 }));
    try testing.expectEqualSlices(u8, &@as([24]u8, @splat(0xAA)), &buf);
}

test "power: LE Set Path Loss Reporting Enable and LE Set Transmit Power Reporting Enable frames (Vol 4 Part E 7.8.120, 7.8.121)" {
    var buf: [16]u8 = undefined;
    const a = try power.cmdSetPathLossReportingEnable(&buf, 0x0042, true);
    try frame("017920" ++ "03" ++ "4200" ++ "01", buf[0..a]);
    const b = try power.cmdSetPathLossReportingEnable(&buf, 0x0042, false);
    try frame("017920" ++ "03" ++ "4200" ++ "00", buf[0..b]);
    const c = try power.cmdSetTransmitPowerReportingEnable(&buf, 0x0042, true, false);
    try frame("017a20" ++ "04" ++ "4200" ++ "0100", buf[0..c]);
    const d = try power.cmdSetTransmitPowerReportingEnable(&buf, 0x0042, false, true);
    try frame("017a20" ++ "04" ++ "4200" ++ "0001", buf[0..d]);
    const e = try power.cmdSetTransmitPowerReportingEnable(&buf, 0x0042, true, true);
    try frame("017a20" ++ "04" ++ "4200" ++ "0101", buf[0..e]);
    const f = try power.cmdSetTransmitPowerReportingEnable(&buf, 0x0042, false, false);
    try frame("017a20" ++ "04" ++ "4200" ++ "0000", buf[0..f]);
    try testing.expectError(error.BadParam, power.cmdSetPathLossReportingEnable(&buf, 0x0F00, true));
    try testing.expectError(error.BadParam, power.cmdSetTransmitPowerReportingEnable(&buf, 0x0F00, true, true));
    // 三条命令的返回都是 Status + Connection_Handle。
    try testing.expectEqual(power.HandleStatus{ .status = 0, .handle = 0x0042 }, try power.parseHandleStatus(&hex("004200")));
    try testing.expectEqual(@as(u8, 0x0C), (try power.parseHandleStatus(&hex("0c"))).status);
    try testing.expectError(error.BadParam, power.parseHandleStatus(&hex("0000f0")));
    try testing.expectError(error.Short, power.parseHandleStatus(&hex("0042")));
    try testing.expectError(error.Trailing, power.parseHandleStatus(&hex("00420000")));
}

// ---------------------------------------------------------------------------
// LE Power Control：事件
// ---------------------------------------------------------------------------

test "power: LE Path Loss Threshold event (Vol 4 Part E 7.7.65.32)" {
    const e = try power.decodeEvent(&hex("043e" ++ "05" ++ "20" ++ "4200" ++ "3c" ++ "01"));
    try testing.expectEqual(power.PathLossThreshold{ .handle = 0x0042, .loss = 0x3C, .zone = .middle }, e.path_loss_threshold);
    const l = try power.decodePathLossThreshold(&hex("4200" ++ "28" ++ "00"));
    try testing.expectEqual(power.Zone.low, l.zone.?);
    const h = try power.decodePathLossThreshold(&hex("4200" ++ "5b" ++ "02"));
    try testing.expectEqual(power.Zone.high, h.zone.?);
    // Current_Path_Loss = 0xFF：不可用，Zone_Entered 被忽略（这里是 0x7F 也照收）。
    const u = try power.decodePathLossThreshold(&hex("4200" ++ "ff" ++ "7f"));
    try testing.expect(u.loss == null);
    try testing.expect(u.zone == null);
    // Zone_Entered 是保留值 → BadParam；长度不对 → Short / Trailing；句柄越界。
    try testing.expectError(error.BadParam, power.decodePathLossThreshold(&hex("42003c03")));
    try testing.expectError(error.BadParam, power.decodePathLossThreshold(&hex("00f03c01")));
    try testing.expectError(error.Short, power.decodePathLossThreshold(&hex("42003c")));
    try testing.expectError(error.Trailing, power.decodePathLossThreshold(&hex("42003c0100")));
}

test "power: LE Transmit Power Reporting event (Vol 4 Part E 7.7.65.33)" {
    const e = try power.decodeEvent(&hex("043e" ++ "09" ++ "21" ++ "00" ++ "4200" ++ "01" ++ "02" ++ "0a" ++ "01" ++ "03"));
    const r = e.transmit_power_reporting;
    try testing.expectEqual(@as(u16, 0x0042), r.handle);
    // Reason 是 0x00 / 0x01 时 Status 被忽略。
    try testing.expect(r.status == null);
    try testing.expectEqual(power.Reason.remote_changed, r.reason);
    try testing.expectEqual(power.Phy.le_2m, r.phy);
    try testing.expectEqual(power.Level{ .dbm = 10 }, r.level);
    try testing.expectEqual(@as(?bool, true), r.at_min);
    try testing.expectEqual(@as(?bool, false), r.at_max);
    try testing.expectEqual(@as(?i8, 3), r.delta);
    // 本端功率变了：Status 字节随便填什么都被忽略；功率 −127 dBm，已在最大电平，降了 2 dB。
    const l = try power.decodeTxPowerReporting(&hex("ff" ++ "4200" ++ "00" ++ "01" ++ "81" ++ "02" ++ "fe"));
    try testing.expect(l.status == null);
    try testing.expectEqual(power.Reason.local_changed, l.reason);
    try testing.expectEqual(power.Level{ .dbm = -127 }, l.level);
    try testing.expectEqual(@as(?bool, false), l.at_min);
    try testing.expectEqual(@as(?bool, true), l.at_max);
    try testing.expectEqual(@as(?i8, -2), l.delta);
    // Min 与 Max 同时置位：只有一个固定功率档。
    const both = try power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "00" ++ "03" ++ "00"));
    try testing.expectEqual(@as(?bool, true), both.at_min);
    try testing.expectEqual(@as(?bool, true), both.at_max);
    // 0x7F：功率不可用，Flag 被忽略；Delta = 0x7F 表示不可用。
    const u = try power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "7f" ++ "ff" ++ "7f"));
    try testing.expectEqual(power.Level.unavailable, u.level);
    try testing.expect(u.at_min == null);
    try testing.expect(u.at_max == null);
    try testing.expect(u.delta == null);
    // 0x7E：对端没在这个 PHY 上管功率，Flag 与 Delta 都被忽略。
    const m = try power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "01" ++ "01" ++ "7e" ++ "ff" ++ "55"));
    try testing.expectEqual(power.Level.not_managed, m.level);
    try testing.expect(m.at_min == null);
    try testing.expect(m.delta == null);
}

test "power: LE Transmit Power Reporting rejects reserved and inconsistent values (Vol 4 Part E 7.7.65.33)" {
    // 保留的 Reason、PHY；范围外的功率（21 dBm、−128、125）；Flag 的保留位。
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "03" ++ "01" ++ "0a" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "00" ++ "0a" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "05" ++ "0a" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "15" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "80" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "7d" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "0a" ++ "04" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "0a" ++ "fc" ++ "00")));
    // Reason 0x02 时 Delta 必须为 0（0x7F 也不行）。
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "02" ++ "01" ++ "0a" ++ "00" ++ "01")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "02" ++ "01" ++ "0a" ++ "00" ++ "7f")));
    const ok = try power.decodeTxPowerReporting(&hex("11" ++ "4200" ++ "02" ++ "01" ++ "7f" ++ "00" ++ "00"));
    try testing.expectEqual(@as(?u8, 0x11), ok.status);
    try testing.expectEqual(@as(?i8, 0), ok.delta);
    // 0x7E 的定义只针对对端：本端功率报告里它没有含义。
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "4200" ++ "00" ++ "01" ++ "7e" ++ "00" ++ "00")));
    try testing.expectError(error.BadParam, power.decodeTxPowerReporting(&hex("00" ++ "00f0" ++ "01" ++ "01" ++ "0a" ++ "00" ++ "00")));
    try testing.expectError(error.Short, power.decodeTxPowerReporting(&hex("00420001010a00")));
    try testing.expectError(error.Trailing, power.decodeTxPowerReporting(&hex("00420001010a000" ++ "000")));
}

test "power: decodeEvent only accepts the two power subevents inside an LE Meta event" {
    try testing.expectError(error.UnknownSubevent, power.decodeEvent(&hex("043e" ++ "04" ++ "0e" ++ "42003c")));
    try testing.expectError(error.UnknownSubevent, power.decodeEvent(&hex("043e" ++ "05" ++ "22" ++ "42003c01")));
    try testing.expectError(error.BadParam, power.decodeEvent(&hex("04ff" ++ "05" ++ "20" ++ "42003c01")));
    try testing.expectError(error.Short, power.decodeEvent(&hex("013e" ++ "05" ++ "20" ++ "42003c01")));
    try testing.expectError(error.Short, power.decodeEvent(&hex("043e" ++ "06" ++ "20" ++ "42003c01")));
    try testing.expectError(error.Trailing, power.decodeEvent(&hex("043e" ++ "05" ++ "20" ++ "42003c0100")));
    try testing.expectError(error.Short, power.decodeEvent(&hex("043e00")));
}

// ---------------------------------------------------------------------------
// 功率请求的钳制
// ---------------------------------------------------------------------------

test "power: an exact change is made when that level exists (Vol 6 Part B 5.1.17)" {
    var r = try power.Responder.init(&ladder, 3);
    var rep = r.apply(4);
    try testing.expectEqual(@as(i8, 4), rep.tx_power);
    try testing.expectEqual(@as(i8, 4), rep.delta);
    try testing.expect(!rep.at_min and !rep.at_max);
    rep = r.apply(6);
    try testing.expectEqual(@as(i8, 10), rep.tx_power);
    try testing.expect(rep.at_max);
    rep = r.apply(0xF2);
    try testing.expectEqual(@as(i8, -4), rep.tx_power);
    try testing.expectEqual(@as(i8, -14), rep.delta);
    rep = r.apply(0);
    try testing.expectEqual(@as(i8, -4), rep.tx_power);
    try testing.expectEqual(@as(i8, 0), rep.delta);
}

test "power: a request above the maximum clamps to the maximum (Vol 6 Part B 5.1.17)" {
    var r = try power.Responder.init(&ladder, 4);
    const rep = r.apply(0x64);
    try testing.expectEqual(@as(i8, 10), rep.tx_power);
    try testing.expectEqual(@as(i8, 6), rep.delta);
    try testing.expect(rep.at_max);
    try testing.expect(!rep.at_min);
    // Delta = 0x7F：请求升到最大功率（§2.4.2.33）。
    var s = try power.Responder.init(&ladder, 0);
    const q = s.apply(0x7F);
    try testing.expectEqual(@as(i8, 10), q.tx_power);
    try testing.expectEqual(@as(i8, 30), q.delta);
    try testing.expect(q.at_max);
}

test "power: a request below the minimum clamps to the minimum (Vol 6 Part B 5.1.17)" {
    var r = try power.Responder.init(&ladder, 2);
    const rep = r.apply(0x80);
    try testing.expectEqual(@as(i8, -20), rep.tx_power);
    try testing.expectEqual(@as(i8, -16), rep.delta);
    try testing.expect(rep.at_min);
    try testing.expect(!rep.at_max);
}

test "power: a request with no exact level lands on the lowest level above it (Vol 6 Part B 5.1.17)" {
    var r = try power.Responder.init(&ladder, 3);
    var rep = r.apply(2);
    try testing.expectEqual(@as(i8, 4), rep.tx_power);
    try testing.expectEqual(@as(i8, 4), rep.delta);
    // 从 4 请求 −2：比 2 dBm 高的最低一档就是 4 dBm 自己，一档都不动（§5.1.17 的小注）。
    rep = r.apply(0xFE);
    try testing.expectEqual(@as(i8, 4), rep.tx_power);
    try testing.expectEqual(@as(i8, 0), rep.delta);
    try testing.expect(!rep.at_min and !rep.at_max);
    // 向下同理：从 −4 请求 +2，没有 −2 这一档，落到 0。
    var s = try power.Responder.init(&ladder, 2);
    rep = s.apply(2);
    try testing.expectEqual(@as(i8, 0), rep.tx_power);
    try testing.expectEqual(@as(i8, 4), rep.delta);
}

test "power: a responder not managing the PHY reports 126 and does not move (Vol 6 Part B 5.1.17)" {
    var r = try power.Responder.init(&ladder, 2);
    r.managing = false;
    const rep = r.apply(0x64);
    try testing.expectEqual(@as(i8, 126), rep.tx_power);
    try testing.expectEqual(@as(i8, 0), rep.delta);
    try testing.expect(!rep.at_min and !rep.at_max);
    try testing.expectEqual(@as(i8, -4), r.level());
}

test "power: a single level is both minimum and maximum (Vol 6 Part B 2.4.2.34)" {
    const one = [_]i8{0};
    var r = try power.Responder.init(&one, 0);
    const rep = r.apply(0x7F);
    try testing.expect(rep.at_min and rep.at_max);
    try testing.expectEqual(@as(i8, 0), rep.delta);
}

test "power: a responder rejects an empty, unsorted, duplicated or out-of-range ladder" {
    const unsorted = [_]i8{ 0, -4, 4 };
    try testing.expectError(error.BadParam, power.Responder.init(&unsorted, 0));
    const dup = [_]i8{ 0, 0 };
    try testing.expectError(error.BadParam, power.Responder.init(&dup, 0));
    const hot = [_]i8{ 0, 21 };
    try testing.expectError(error.BadParam, power.Responder.init(&hot, 0));
    const cold = [_]i8{ -128, 0 };
    try testing.expectError(error.BadParam, power.Responder.init(&cold, 0));
    const none = [_]i8{};
    try testing.expectError(error.BadParam, power.Responder.init(&none, 0));
    try testing.expectError(error.BadParam, power.Responder.init(&ladder, ladder.len));
}

test "power: property, any request lands on a rung at or above the target and inside the ladder (Vol 6 Part B 5.1.17)" {
    var prng = std.Random.DefaultPrng.init(0x5a1a);
    const rand = prng.random();
    var levels: [8]i8 = undefined;
    var bad: usize = 0;
    var rounds: usize = 0;
    for (0..16) |_| {
        // 严格升序的随机档位：−99…4 dBm，落在可报范围内。
        var x: i16 = rand.intRangeAtMost(i16, -100, -60);
        for (&levels) |*l| {
            x += rand.intRangeAtMost(i16, 1, 8);
            l.* = @intCast(x);
        }
        const last = levels[levels.len - 1];
        for (0..32) |k| {
            var r = try power.Responder.init(&levels, k % levels.len);
            const cur = r.level();
            var d: u8 = rand.int(u8);
            if (d == power.delta_request_max) d = 0x7E;
            const rep = r.apply(d);
            rounds += 1;
            const target: i16 = @as(i16, cur) + @as(i16, @as(i8, @bitCast(d)));
            const clamp = if (target > last) rep.tx_power == last else rep.tx_power >= target;
            const direction = if (d == 0) rep.tx_power == cur else if (d < 0x80) rep.tx_power >= cur else rep.tx_power <= cur;
            const ok = rep.tx_power >= levels[0] and rep.tx_power <= last and rep.delta == rep.tx_power - cur and clamp and direction;
            if (!ok) bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 512), rounds);
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// 路径损耗的分区与事件校验
// ---------------------------------------------------------------------------

test "power: path loss zones change only on crossing a boundary, with hysteresis (Vol 6 Part B 4.5.16)" {
    // Low 区：到 Low_Threshold + Low_Hysteresis = 0x35 才升到 Middle。
    try testing.expectEqual(power.Zone.low, power.zoneEntered(.low, 0x34, loss_params));
    try testing.expectEqual(power.Zone.middle, power.zoneEntered(.low, 0x35, loss_params));
    // Middle 区：≤ 0x2B 回 Low，≥ 0x5A 去 High，夹在中间不动。
    try testing.expectEqual(power.Zone.low, power.zoneEntered(.middle, 0x2B, loss_params));
    try testing.expectEqual(power.Zone.middle, power.zoneEntered(.middle, 0x2C, loss_params));
    try testing.expectEqual(power.Zone.middle, power.zoneEntered(.middle, 0x59, loss_params));
    try testing.expectEqual(power.Zone.high, power.zoneEntered(.middle, 0x5A, loss_params));
    // High 区：≤ High_Threshold − High_Hysteresis = 0x46 才回 Middle。
    try testing.expectEqual(power.Zone.middle, power.zoneEntered(.high, 0x46, loss_params));
    try testing.expectEqual(power.Zone.high, power.zoneEntered(.high, 0x47, loss_params));
    // 高阈值不用：没有 High 区。
    try testing.expectEqual(power.Zone.middle, power.zoneEntered(.middle, 0xFF, loss_two_zones));
    try testing.expectEqual(power.Zone.middle, power.zoneEntered(.low, 0x35, loss_two_zones));
    try testing.expect(!power.inZone(.high, 0xFF, loss_two_zones));
}

test "power: the path loss tracker accepts a consistent walk through the zones (Vol 6 Part B 4.5.16)" {
    var t = try power.PathLossTracker.init(loss_params);
    try t.onEvent(.{ .handle = 0x0042, .loss = 0x3C, .zone = .middle });
    try t.onEvent(.{ .handle = 0x0042, .loss = 0x5B, .zone = .high });
    try t.onEvent(.{ .handle = 0x0042, .loss = 0x40, .zone = .middle });
    try t.onEvent(.{ .handle = 0x0042, .loss = 0x28, .zone = .low });
    try testing.expectEqual(@as(u32, 4), t.events);
    try testing.expectEqual(@as(?power.Zone, .low), t.last_zone);
    // 路径损耗不可用的事件没有区可校验，不计数，并把当前区忘掉。
    try t.onEvent(.{ .handle = 0x0042, .loss = null, .zone = null });
    try testing.expectEqual(@as(u32, 4), t.events);
    try testing.expect(t.last_zone == null);
    // 恢复可用后 controller “如同刚换了区”再报：还是 Low 也要收下。
    try t.onEvent(.{ .handle = 0x0042, .loss = 0x20, .zone = .low });
    try testing.expectEqual(@as(u32, 5), t.events);
    // 回差带里两个区都算自洽。
    var u = try power.PathLossTracker.init(loss_params);
    try u.onEvent(.{ .handle = 0, .loss = 0x33, .zone = .low });
    u.last_zone = null;
    try u.onEvent(.{ .handle = 0, .loss = 0x33, .zone = .middle });
}

test "power: the path loss tracker rejects two reports of the same zone (Vol 6 Part B 4.5.16; Vol 4 Part E 7.8.120)" {
    var t = try power.PathLossTracker.init(loss_params);
    try t.onEvent(.{ .handle = 0, .loss = 0x3C, .zone = .middle });
    try testing.expectError(error.SameZone, t.onEvent(.{ .handle = 0, .loss = 0x50, .zone = .middle }));
    try testing.expectEqual(@as(u32, 1), t.events);
}

test "power: the path loss tracker rejects the high zone when the high threshold is unused (Vol 4 Part E 7.8.119)" {
    var t = try power.PathLossTracker.init(loss_two_zones);
    try testing.expectError(error.HighZoneUnused, t.onEvent(.{ .handle = 0, .loss = 0x60, .zone = .high }));
    try testing.expectEqual(@as(u32, 0), t.events);
    try t.onEvent(.{ .handle = 0, .loss = 0x60, .zone = .middle });
    try testing.expectEqual(@as(u32, 1), t.events);
}

test "power: the path loss tracker rejects a zone that contradicts the measured loss (Vol 6 Part B 4.5.16)" {
    var t = try power.PathLossTracker.init(loss_params);
    try testing.expectError(error.ZoneMismatch, t.onEvent(.{ .handle = 0, .loss = 0x60, .zone = .low }));
    try testing.expectError(error.ZoneMismatch, t.onEvent(.{ .handle = 0, .loss = 0x10, .zone = .high }));
    try testing.expectError(error.ZoneMismatch, t.onEvent(.{ .handle = 0, .loss = 0x10, .zone = .middle }));
    try testing.expectError(error.ZoneMismatch, t.onEvent(.{ .handle = 0, .loss = 0x60, .zone = .middle }));
    try testing.expectEqual(@as(u32, 0), t.events);
    // 换一套阈值之后按新参数校验。
    try t.setParams(.{ .high_threshold = 0x30, .high_hysteresis = 0x05, .low_threshold = 0x10, .low_hysteresis = 0x05, .min_time_spent = 0 });
    try t.onEvent(.{ .handle = 0, .loss = 0x40, .zone = .high });
    try testing.expectEqual(@as(u32, 1), t.events);
    try testing.expectError(error.LowAboveHigh, t.setParams(.{ .high_threshold = 0x30, .high_hysteresis = 0x05, .low_threshold = 0x40, .low_hysteresis = 0x05, .min_time_spent = 0 }));
    try testing.expectError(error.LowAboveHigh, power.PathLossTracker.init(.{ .high_threshold = 0x30, .high_hysteresis = 0x05, .low_threshold = 0x40, .low_hysteresis = 0x05, .min_time_spent = 0 }));
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上再跑一遍
// ---------------------------------------------------------------------------

test "board selftest on host: privacy (privacy_selftest.run) passes every check" {
    try selftest_host.expectAllPass(privacy_selftest.run);
}
