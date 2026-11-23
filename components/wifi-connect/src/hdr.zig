//! wifi-connect：MAC 头的本地解析——只取 CCMP/GCMP/BIP 构造用得到的字段。
//!
//! 802.11 帧的完整编解码属于 `wifi-mlme`，组件之间不互相 import，所以这里
//! 按图 9-1（9.2.3，印刷页 636）自己读一遍头：
//!
//!   FC(2) | Duration/ID(2) | A1 | A2 | A3 | SC(2) | A4(0/6) | QC(0/2) | HT Control(0/4)
//!
//! 帧控制字段（图 9-2，9.2.4.1.1，印刷页 638）：
//!   八位组 0：B0–1 协议版本，B2–3 类型，B4–7 子类型
//!   八位组 1：B8 To DS，B9 From DS，B10 More Fragments，B11 Retry，
//!             B12 Power Management，B13 More Data，B14 Protected Frame，
//!             B15 +HTC/Order
//! 数据帧里子类型的最高位 B7 是 QoS 位（9.2.4.1.3，印刷页 639），QoS 数据帧
//! 才有 QoS Control 字段（9.2.4.5.1，印刷页 648）。To DS 与 From DS 同时为 1
//! 是四地址格式（表 9-3，印刷页 640）。HT Control 字段只在 QoS 数据帧与管理帧
//! 里按 +HTC/Order 位出现（9.2.4.6.1，印刷页 656）。
//!
//! 不 import hw/log；所有读取都按下标的显式字节序，不做类型双关。

const std = @import("std");

pub const base_hdr_len = 24;
pub const a4_len = 6;
pub const qc_len = 2;
pub const htc_len = 4;

pub const type_mgmt: u8 = 0;
pub const type_ctrl: u8 = 1;
pub const type_data: u8 = 2;

/// 表 9-1（印刷页 639）里与保护有关的子类型。
pub const Subtype = struct {
    pub const disassoc: u8 = 10;
    pub const deauth: u8 = 12;
    pub const action: u8 = 13;
    pub const action_no_ack: u8 = 14;
};

pub const Error = error{
    /// 帧短于它的 MAC 头。
    Truncated,
};

pub const FrameKind = enum { mgmt, data, other };

pub const Header = struct {
    kind: FrameKind,
    subtype: u8,
    to_ds: bool,
    from_ds: bool,
    protected: bool,
    /// 帧控制 B15：+HTC/Order。
    order: bool,
    qos: bool,
    a4: bool,
    /// MAC 头总长（含 A4、QoS Control、HT Control）。
    hdr_len: usize,
    /// QoS Control 字段在帧里的偏移；没有则为 0（它只可能出现在 24 或 30 之后）。
    qc_off: usize,
    a1: [6]u8,
    a2: [6]u8,
    a3: [6]u8,
    /// QoS Control 的 TID（B0–3）；非 QoS 帧为 0。
    tid: u4,

    /// Address 1 的 I/G 位（9.2.2：Individual/Group 位是第一个八位组的 bit 0）。
    pub fn groupAddressed(self: Header) bool {
        return (self.a1[0] & 0x01) != 0;
    }
};

pub fn frameType(fc0: u8) u8 {
    return (fc0 >> 2) & 0x03;
}

pub fn frameSubtype(fc0: u8) u8 {
    return fc0 >> 4;
}

pub fn isQosData(fc0: u8) bool {
    return frameType(fc0) == type_data and (fc0 & 0x80) != 0;
}

/// 读帧控制 B14。
pub fn isProtected(fc1: u8) bool {
    return (fc1 & 0x40) != 0;
}

/// 置位或清除帧控制 B14（Protected Frame）。
pub fn setProtected(frame: []u8, on: bool) void {
    if (frame.len < 2) return;
    if (on) {
        frame[1] |= 0x40;
    } else {
        frame[1] &= ~@as(u8, 0x40);
    }
}

fn addr6(frame: []const u8, off: usize) [6]u8 {
    return frame[off..][0..6].*;
}

/// 解析 MAC 头。控制帧与扩展帧也返回（`kind == .other`），头长按 24 计，
/// 是否接受由调用方决定——CCMP/GCMP/BIP 都只定义了数据帧与管理帧的用法。
pub fn parse(frame: []const u8) Error!Header {
    if (frame.len < base_hdr_len) return error.Truncated;
    const fc0 = frame[0];
    const fc1 = frame[1];
    const ftype = frameType(fc0);
    const kind: FrameKind = switch (ftype) {
        type_mgmt => .mgmt,
        type_data => .data,
        else => .other,
    };
    const to_ds = (fc1 & 0x01) != 0;
    const from_ds = (fc1 & 0x02) != 0;
    const order = (fc1 & 0x80) != 0;
    const qos = isQosData(fc0);
    const a4 = kind == .data and to_ds and from_ds;

    var len: usize = base_hdr_len;
    if (a4) len += a4_len;
    var qc_off: usize = 0;
    if (qos) {
        qc_off = len;
        len += qc_len;
    }
    if (order and (qos or kind == .mgmt)) len += htc_len;
    if (frame.len < len) return error.Truncated;

    return .{
        .kind = kind,
        .subtype = frameSubtype(fc0),
        .to_ds = to_ds,
        .from_ds = from_ds,
        .protected = isProtected(fc1),
        .order = order,
        .qos = qos,
        .a4 = a4,
        .hdr_len = len,
        .qc_off = qc_off,
        .a1 = addr6(frame, 4),
        .a2 = addr6(frame, 10),
        .a3 = addr6(frame, 16),
        .tid = if (qos) @truncate(frame[qc_off]) else 0,
    };
}
