//! HCI 传输层（我们**自己拥有**，不碰归档里没有的 `hci_driver_vhci_ops`/`uart_ops`）。
//!
//! 结构照 IDF `porting_btdm/transport/src/hci_transport.c`：
//!
//! | 环节 | 做法 |
//! | --- | --- |
//! | `ops` | 3 个函数指针：`tx(type,data,len,dir)` / `init(cb)` / `deinit()` |
//! | 下行（host→controller） | 我们的 `forward`：`TYPE_CMD` 时 `pkt = @ptrCast(data)` 再 `r_btdm_hci_trans_rx(pkt)` |
//! | 事件上行 | `r_ble_hci_trans_cfg_hs(leEvtTx, NULL, leAclTx, NULL)` 注册的回调 |
//! | BTDM 上行 | `r_btdm_hci_trans_register_tx(controllerTx, false)` |
//!
//! ⚠ 三个必踩点：
//! 1. **别手搓 12 字节包**：用归档的 `r_btdm_hci_trans_buf_alloc(TYPE_CMD=0x01, 0)`，
//!    它给我们一个排好版的包；填 `pkt.data`/`pkt.length` 即可。`data` 字段指向**载荷**。
//! 2. **必须置 BLE 位**（`r_btdm_hci_pkt_flag_ble_setf(pkt, 1)`），否则包被当 BR/EDR 路由，
//!    症状是"命令没人接"。
//! 3. 回程字节在 `pkt.data`/`pkt.length`；我们是 host ⇒ **读完要自己释放**
//!    （`r_ble_hci_trans_buf_free(载荷指针)`，注意它收的是**载荷**不是包）。
const std = @import("std");
const builtin = @import("builtin");
const osal = @import("osal.zig");

/// 枚举值照抄 `esp_hci_driver.h`（写错不报错、只会静默路由错）。
pub const TYPE_CMD: u32 = 0x01;
pub const TYPE_EVT: u32 = 0x04;
pub const DIR_LEC2H: u32 = 0x00;
pub const DIR_H2C: u32 = 0x03;

/// `hci_driver_packet_t`：rv32 上 12 字节（`next(4)+data(4)+length(2)+flags(1)+type(1)`）。
pub const Packet = extern struct {
    next: ?*anyopaque = null,
    data: [*]u8,
    length: u16,
    flags: u8 = 0,
    type: u8 = 0,
};

comptime {
    if (@sizeOf(*anyopaque) == 4) {
        std.debug.assert(@sizeOf(Packet) == 12);
        std.debug.assert(@offsetOf(Packet, "data") == 4);
        std.debug.assert(@offsetOf(Packet, "length") == 8);
        std.debug.assert(@offsetOf(Packet, "flags") == 10);
        std.debug.assert(@offsetOf(Packet, "type") == 11);
    }
}

pub const ForwardFn = *const fn (dtype: u32, data: [*]u8, len: u32, dir: u32, src: u8) callconv(.c) c_int;

pub const Ops = extern struct {
    tx: *const fn (dtype: u32, data: [*]u8, len: u32, dir: u32) callconv(.c) c_int,
    init: *const fn (cb: ForwardFn) callconv(.c) c_int,
    deinit: *const fn () callconv(.c) void,
};

// 归档符号
extern fn r_btdm_hci_trans_buf_alloc(flag_type: u8, conn_handle: u16) *Packet;
extern fn r_btdm_hci_trans_buf_free(pkt: *Packet) void;
extern fn r_btdm_hci_pkt_flag_ble_setf(pkt: *Packet, is_ble: u8) void;
extern fn r_btdm_hci_trans_rx(pkt: *Packet) c_int;
extern fn r_btdm_hci_trans_register_tx(tx: *const fn (*Packet) callconv(.c) c_int, async: bool) void;
extern fn r_ble_hci_trans_cfg_hs(
    evt_cb: ?*const fn ([*]u8, ?*anyopaque) callconv(.c) c_int,
    evt_arg: ?*anyopaque,
    acl_cb: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    acl_arg: ?*anyopaque,
) void;
extern fn r_ble_hci_trans_buf_free(buf: [*]u8) void;

const freestanding = builtin.os.tag == .freestanding;

pub const Stats = struct {
    inited: u32 = 0,
    cmds_sent: u32 = 0,
    cmd_alloc_null: u32 = 0,
    evt_bytes: u32 = 0,
    evt_count: u32 = 0,
    btdm_tx: u32 = 0,
    acl_ignored: u32 = 0,
    last_evt_code: u8 = 0,
    last_evt_len: u8 = 0,
};
var stats_state = Stats{};
pub fn stats() Stats {
    return stats_state;
}
pub fn resetStats() void {
    stats_state = .{};
}

var fwd: ?ForwardFn = null;
var inited = false;

/// 回程字节先落一份到日志——这是里程碑唯一的判据。
fn dumpEvt(bytes: []const u8) void {
    if (bytes.len < 3) return;
    stats_state.last_evt_code = bytes[2];
    stats_state.last_evt_len = bytes[1];
    osal.logPublic("bt hci << EVT code=0x{x:0>2} len={d}", .{ bytes[2], bytes[1] });
    var i: usize = 0;
    while (i < bytes.len and i < 16) : (i += 1) {
        osal.logPublic("bt hci    [{d}]=0x{x:0>2}", .{ i, bytes[i] });
    }
}

/// 事件回调（controller → host）。字节布局：`[0]=0x04 EVT, [1]=len, [2]=event code`，总长 `cmd[1]+2`。
fn leEvtTx(cmd: [*]u8, _: ?*anyopaque) callconv(.c) c_int {
    const len: usize = @as(usize, cmd[1]) + 2;
    stats_state.evt_count += 1;
    stats_state.evt_bytes += @intCast(len);
    dumpEvt(cmd[0..len]);
    if (fwd) |f| _ = f(TYPE_EVT, cmd, @intCast(len), DIR_LEC2H, 0);
    // 我们是 host ⇒ 读完自己释放（IDF 是把所有权交给 host 才不释放）
    if (freestanding) r_ble_hci_trans_buf_free(cmd);
    return 0;
}

/// ACL 回调：`ble_mbuf` 不是普通包，HCI Reset 这条路用不到 ⇒ 只计数。
fn leAclTx(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    stats_state.acl_ignored += 1;
    return -1;
}

/// BTDM 上行（BR/EDR 与 BTDMC2H 方向）。本轮只记录。
fn btdmTx(pkt: *Packet) callconv(.c) c_int {
    stats_state.btdm_tx += 1;
    if (fwd) |f| _ = f(@as(u32, pkt.type), pkt.data, pkt.length, @as(u32, 0x02), 0);
    if (freestanding) r_btdm_hci_trans_buf_free(pkt);
    return 0;
}

/// 下行分发：`TYPE_CMD` 时 **`data` 是包结构体指针**（不是裸字节）。
fn forward(dtype: u32, data: [*]u8, _: u32, _: u32, _: u8) callconv(.c) c_int {
    if (dtype == TYPE_CMD) {
        const pkt: *Packet = @ptrCast(@alignCast(data));
        if (freestanding) return r_btdm_hci_trans_rx(pkt);
        return 0;
    }
    return -1;
}

fn ourTx(dtype: u32, data: [*]u8, len: u32, dir: u32) callconv(.c) c_int {
    _ = dir;
    if (dtype == TYPE_EVT) dumpEvt(data[0..@min(len, 300)]);
    return 0;
}
fn ourInit(cb: ForwardFn) callconv(.c) c_int {
    fwd = cb;
    return 0;
}
fn ourDeinit() callconv(.c) void {}

pub const ops: Ops = .{ .tx = ourTx, .init = ourInit, .deinit = ourDeinit };

/// 复刻 `hci_transport_init`：`ops.init(cb)` → `r_ble_hci_trans_cfg_hs` → `r_btdm_hci_trans_register_tx`。
pub fn init() c_int {
    stats_state = .{};
    const rc = ourInit(forward);
    if (rc != 0) return rc;
    if (freestanding) {
        r_ble_hci_trans_cfg_hs(leEvtTx, null, leAclTx, null);
        r_btdm_hci_trans_register_tx(btdmTx, false);
    }
    inited = true;
    stats_state.inited += 1;
    osal.logPublic("bt hci: transport ready (own ops, no VHCI ring)", .{});
    return 0;
}

/// 发一条 HCI 命令。**必须 status == ENABLED**，否则 `r_btdm_hci_trans_rx` 的前置检查会拒掉。
pub fn sendCmd(opcode: u16, params: []const u8) c_int {
    if (!inited) return -1;
    if (params.len > 250) return -2;
    if (!freestanding) {
        stats_state.cmds_sent += 1;
        return 0;
    }
    const pkt = r_btdm_hci_trans_buf_alloc(@intCast(TYPE_CMD), 0);
    if (@intFromPtr(pkt) == 0) {
        stats_state.cmd_alloc_null += 1;
        osal.logPublic("bt hci: buf_alloc returned null", .{});
        return -3;
    }
    // 写载荷：opcode(2, 小端) + len(1) + params
    pkt.data[0] = @truncate(opcode);
    pkt.data[1] = @truncate(opcode >> 8);
    pkt.data[2] = @intCast(params.len);
    for (params, 0..) |b, i| pkt.data[3 + i] = b;
    const total: u16 = @intCast(3 + params.len);
    // 包结构体的 length 由归档的分配器初始化为 0；这里写载荷长度
    pkt.length = total;
    pkt.type = @intCast(TYPE_CMD);
    // **必须置 BLE 位**，否则被当 BR/EDR 路由
    r_btdm_hci_pkt_flag_ble_setf(pkt, 1);

    stats_state.cmds_sent += 1;
    osal.logPublic("bt hci >> CMD opcode=0x{x:0>4} plen={d}", .{ opcode, params.len });
    const f = fwd orelse return -4;
    return f(TYPE_CMD, @ptrCast(pkt), total, DIR_H2C, 0);
}

// ---------------------------------------------------------------------------
// B 路径：走 NimBLE host 层入口，**不碰** 12 字节包结构 / BLE flag / `r_btdm_hci_trans_rx`
//
// 比 A 路径少一半代码，先试这条；失败再回到 A（`sendCmd`）。
// `r_ble_hci_trans_buf_alloc` 的 type 是 `BLE_HCI_TRANS_BUF_CMD = **3**`——
// ⚠ 与 A 路径的 `r_btdm_hci_trans_buf_alloc(HCI_DRIVER_TYPE_CMD = 1)` 是**两个不同的分配器、
// 不同的 type 值**，别混用。
// ---------------------------------------------------------------------------

extern fn r_ble_hci_trans_buf_alloc(flag_type: c_int) ?[*]u8;
extern fn r_ble_hci_trans_hs_cmd_tx(cmd: [*]u8) c_int;

pub const BLE_HCI_TRANS_BUF_CMD: c_int = 3;

/// 用 host 层入口发一条命令（`buf` 里放 HCI 命令**不含 H4 类型字节**：opcode 小端 + plen + params）。
pub fn sendCmdViaHs(opcode: u16, params: []const u8) c_int {
    if (!inited) return -1;
    if (params.len > 250) return -2;
    if (!freestanding) {
        stats_state.cmds_sent += 1;
        return 0;
    }
    const buf = r_ble_hci_trans_buf_alloc(BLE_HCI_TRANS_BUF_CMD) orelse {
        stats_state.cmd_alloc_null += 1;
        osal.logPublic("bt hci(hs): buf_alloc returned null", .{});
        return -3;
    };
    buf[0] = @truncate(opcode);
    buf[1] = @truncate(opcode >> 8);
    buf[2] = @intCast(params.len);
    for (params, 0..) |b, i| buf[3 + i] = b;
    stats_state.cmds_sent += 1;
    osal.logPublic("bt hci(hs) >> CMD opcode=0x{x:0>4} plen={d}", .{ opcode, params.len });
    const rc = r_ble_hci_trans_hs_cmd_tx(buf);
    r_ble_hci_trans_buf_free(buf);
    return rc;
}

/// `HCI Reset`（0x0C03，无参数）—— 里程碑的第一条命令。
pub fn sendReset() c_int {
    return sendCmd(0x0C03, &.{});
}

/// B 路径的 `HCI Reset`：期望回程是 `04 04 0E 03 0C 00`（最后那个 00 才是成功）。
pub fn sendResetViaHs() c_int {
    return sendCmdViaHs(0x0C03, &.{});
}

/// `HCI Read Local Version Information`（0x1001，无参数）。
pub fn sendReadLocalVersion() c_int {
    return sendCmd(0x1001, &.{});
}

// ---------------------------------------------------------------------------
// 主机用例
// ---------------------------------------------------------------------------

/// 主机侧模拟 controller 的回程。
pub fn injectEvent(bytes: []u8) void {
    if (bytes.len >= 2) {
        bytes[1] = @intCast(bytes.len - 2);
    }
    _ = leEvtTx(bytes.ptr, null);
}

test "transport: 包布局与枚举值" {
    if (@sizeOf(*anyopaque) == 4) {
        try std.testing.expectEqual(@as(usize, 12), @sizeOf(Packet));
        try std.testing.expectEqual(@as(usize, 4), @offsetOf(Packet, "data"));
        try std.testing.expectEqual(@as(usize, 8), @offsetOf(Packet, "length"));
    }
    try std.testing.expectEqual(@as(u32, 0x01), TYPE_CMD);
    try std.testing.expectEqual(@as(u32, 0x04), TYPE_EVT);
    try std.testing.expectEqual(@as(u32, 0x03), DIR_H2C);
}

test "transport: 事件回调按 cmd[1]+2 切长度、记下 event code" {
    resetStats();
    var buf = [_]u8{ 0x04, 0, 0x0E, 0xAA, 0xBB }; // 0x0E = Command Complete
    injectEvent(&buf);
    try std.testing.expectEqual(@as(u32, 1), stats().evt_count);
    try std.testing.expectEqual(@as(u8, 0x0E), stats().last_evt_code);
    try std.testing.expectEqual(@as(u8, 3), stats().last_evt_len);
}

test "transport: B 路径同样受 init 门禁，type 常量与 A 路径不同" {
    resetStats();
    inited = false;
    try std.testing.expectEqual(@as(c_int, -1), sendResetViaHs());
    try std.testing.expectEqual(@as(c_int, 0), init());
    try std.testing.expectEqual(@as(c_int, 0), sendResetViaHs());
    try std.testing.expectEqual(@as(u32, 1), stats().cmds_sent);
    // 两个分配器的 type 值不同：A=1（HCI_DRIVER_TYPE_CMD），B=3（BLE_HCI_TRANS_BUF_CMD）
    try std.testing.expectEqual(@as(u32, 1), TYPE_CMD);
    try std.testing.expectEqual(@as(c_int, 3), BLE_HCI_TRANS_BUF_CMD);
}

test "transport: 未 init 时发命令被拒；init 后可发" {
    resetStats();
    inited = false;
    try std.testing.expectEqual(@as(c_int, -1), sendReset());
    try std.testing.expectEqual(@as(c_int, 0), init());
    try std.testing.expectEqual(@as(c_int, 0), sendReset());
    try std.testing.expectEqual(@as(c_int, 0), sendReadLocalVersion());
    try std.testing.expectEqual(@as(u32, 2), stats().cmds_sent);
}
