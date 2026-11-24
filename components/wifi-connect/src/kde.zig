//! wifi-connect：EAPOL-Key 的 Key Data 字段——元素与 KDE（802.11-2016 12.7.2）。
//!
//! Key Data 字段（12.7.2 j)，印刷页 2023–2026）装的是「零个或多个元素」加
//! 「零个或多个密钥数据封装（KDE）」。元素带 Element ID 与 Length；KDE 用
//! 图 12-34 的固定格式：
//!
//!   Type(0xdd) | Length | OUI(3) | Data Type(1) | Data(Length - 4)
//!
//! Length 只数 OUI、Data Type、Data 三段。表 12-6 的 Data Type：1 = GTK，
//! 4 = PMKID，9 = IGTK。三种 KDE 的 Data 段（图 12-35、12-37、12-42）：
//!
//!   GTK  : Key ID(bits 0–1) | Tx(bit 2) | Reserved(bits 3–7) | Reserved(1 八位组)
//!          | GTK(Length - 6) octets
//!   PMKID: PMKID(16)
//!   IGTK : Key ID(2) | IPN(6) | IGTK(Length - 12)
//!
//! GTK KDE 的 Data 段是两个八位组的头再加 GTK：GTK 长度 = Length - 6，
//! 与 Length = OUI + Data Type + 2 + GTK 的算法自洽。
//!
//! 多八位组数值字段按 9.2.2（印刷页 636）的约定「低位编号的八位组先发」，即小端。
//!
//! 加密前的填充（12.7.2 j)，印刷页 2024）：Key Data 长度小于 16 或不是 8 的
//! 倍数时，追加一个 0xdd 再补零到满足条件；接收方忽略这段尾部填充。
//!
//! 本文件只负责「拼」与「拆」，加解密调用 `keywrap.zig`。
//! 不用分配器；缓冲由调用方提供。本文件不 import hw/log。

const std = @import("std");
const keywrap = @import("keywrap.zig");

pub const oui = [3]u8{ 0x00, 0x0f, 0xac };
pub const kde_type_vendor_specific = 0xdd;

/// 表 12-6（印刷页 2023）的 Data Type。
pub const DataType = struct {
    pub const gtk: u8 = 1;
    pub const mac_addr: u8 = 3;
    pub const pmkid: u8 = 4;
    pub const igtk: u8 = 9;
};

/// Type + Length + OUI + Data Type。
pub const kde_hdr_len = 6;
/// Length 字段只数 OUI + Data Type + Data。
const length_base = 4;
pub const pmkid_len = 16;
/// Key ID/Tx 八位组 + Reserved 八位组，所以 GTK 长度 = Length - 6。
pub const gtk_kde_fixed = kde_hdr_len + 2;
/// Key ID(2) + IPN(6)，所以 IGTK 长度 = Length - 12。
pub const igtk_kde_fixed = kde_hdr_len + 8;
/// 加密前的 Key Data 至少这么长，且是它的倍数（12.7.2 j)）。
pub const pad_min = 16;
pub const pad_unit = 8;

pub const Error = error{
    BufferTooSmall,
    /// 元素或 KDE 的 Length 超出 Key Data 剩余字节。
    Truncated,
    /// KDE 的 Data 段短于该类型的固定部分，或 PMKID 不是 16 字节。
    BadKde,
    /// GTK / IGTK 的长度不是 16 或 32（表 12-4，印刷页 2021）。
    BadKeyLength,
    /// 要写的内容超过单个元素的 255 字节上限。
    TooLong,
    /// 解包后尾部填充不是「0xdd 后跟零」（12.7.2 j)）。
    BadPadding,
};

pub const WrapError = keywrap.Error || Error;

pub const GtkKde = struct {
    key_id: u8,
    /// Tx = 1：这把 GTK 既用于发送也用于接收；Tx = 0：只用于接收（12.7.2，印刷页 2024）。
    tx: bool,
    gtk: []const u8,
};

pub const IgtkKde = struct {
    key_id: u16,
    /// 6 个八位组，低位在前；接收方用它初始化 BIP 重放计数（12.5.4.4，印刷页 1975）。
    ipn: [6]u8,
    igtk: []const u8,
};

/// 解析出来的一项。不认识的元素照样报出来（12.7.2：STA 应忽略不认识的元素和 KDE），
/// 由调用方决定丢不丢。
pub const Item = union(enum) {
    /// `full` 是含 Element ID 与 Length 的整段元素，便于逐字节比对。
    element: struct { id: u8, body: []const u8, full: []const u8 },
    pmkid: [pmkid_len]u8,
    gtk: GtkKde,
    igtk: IgtkKde,
    other_kde: struct { oui: [3]u8, data_type: u8, data: []const u8 },
};

fn checkKeyLen(len: usize) Error!void {
    if (len != 16 and len != 32) return error.BadKeyLength;
}

fn room(buf: []u8, pos: usize, need: usize) Error!void {
    if (pos > buf.len or buf.len - pos < need) return error.BufferTooSmall;
}

/// 追加一个普通元素：Element ID(1) + Length(1) + body。返回新的写入位置。
pub fn putElement(buf: []u8, pos: usize, id: u8, body: []const u8) Error!usize {
    if (body.len > 255) return error.TooLong;
    try room(buf, pos, 2 + body.len);
    buf[pos] = id;
    buf[pos + 1] = @intCast(body.len);
    @memcpy(buf[pos + 2 ..][0..body.len], body);
    return pos + 2 + body.len;
}

fn putKdeHead(buf: []u8, pos: usize, data_type: u8, data_len: usize) Error!usize {
    // Length 字段只有 8 位，装不下 OUI + Type + Data 就没法表示。
    if (length_base + data_len > 255) return error.TooLong;
    try room(buf, pos, kde_hdr_len + data_len);
    buf[pos] = kde_type_vendor_specific;
    buf[pos + 1] = @intCast(length_base + data_len);
    @memcpy(buf[pos + 2 ..][0..3], &oui);
    buf[pos + 5] = data_type;
    return pos + kde_hdr_len;
}

/// 追加 PMKID KDE：dd 14 00 0F AC 04 | PMKID（图 12-37，印刷页 2024）。
pub fn putPmkid(buf: []u8, pos: usize, pmkid: [pmkid_len]u8) Error!usize {
    const p = try putKdeHead(buf, pos, DataType.pmkid, pmkid_len);
    @memcpy(buf[p..][0..pmkid_len], &pmkid);
    return p + pmkid_len;
}

/// 追加 GTK KDE（图 12-35，印刷页 2024）：dd | 6+gtk | 00 0F AC 01 | Key ID/Tx | 00 | GTK。
/// `key_id` 只用低 2 位。
pub fn putGtk(buf: []u8, pos: usize, key_id: u8, tx: bool, gtk: []const u8) Error!usize {
    try checkKeyLen(gtk.len);
    const p = try putKdeHead(buf, pos, DataType.gtk, 2 + gtk.len);
    buf[p] = (key_id & 0x03) | (if (tx) @as(u8, 1 << 2) else 0);
    buf[p + 1] = 0;
    @memcpy(buf[p + 2 ..][0..gtk.len], gtk);
    return p + 2 + gtk.len;
}

/// 追加 IGTK KDE（图 12-42，印刷页 2025）：dd | 12+igtk | 00 0F AC 09 | Key ID(2) | IPN(6) | IGTK。
pub fn putIgtk(buf: []u8, pos: usize, key_id: u16, ipn: [6]u8, igtk: []const u8) Error!usize {
    try checkKeyLen(igtk.len);
    const p = try putKdeHead(buf, pos, DataType.igtk, 8 + igtk.len);
    std.mem.writeInt(u16, buf[p..][0..2], key_id, .little);
    @memcpy(buf[p + 2 ..][0..6], &ipn);
    @memcpy(buf[p + 8 ..][0..igtk.len], igtk);
    return p + 8 + igtk.len;
}

/// 12.7.2 j) 的填充规则算出的目标长度；已经合规则原样返回。
pub fn paddedLen(len: usize) usize {
    if (len >= pad_min and len % pad_unit == 0) return len;
    if (len < pad_min) return pad_min;
    return ((len / pad_unit) + 1) * pad_unit;
}

/// 就地追加填充：一个 0xdd 再补零到 `paddedLen(pos)`。`buf` 至少要有那么多字节。
pub fn appendPadding(buf: []u8, pos: usize) Error!usize {
    const target = paddedLen(pos);
    if (pos > buf.len or buf.len < target) return error.BufferTooSmall;
    if (target > pos) buf[pos] = 0xdd;
    if (target > pos + 1) @memset(buf[pos + 1 .. target], 0);
    return target;
}

/// 去掉接收到的尾部填充（12.7.2 j)：接收方应忽略）。
/// 规则：末尾的零全部去掉，若去掉零之后最末一个字节是 0xdd，它也去掉。
/// 只有零而没有 0xdd 收尾的填充不合规，报 `BadPadding`。
pub fn stripPadding(data: []const u8) Error![]const u8 {
    var end = data.len;
    while (end > 0 and data[end - 1] == 0) end -= 1;
    if (end > 0 and data[end - 1] == 0xdd) {
        end -= 1;
    } else if (end != data.len) {
        return error.BadPadding;
    }
    return data[0..end];
}

/// 逐项读出 Key Data。每调一次 `next` 返回一项，读完返回 null；结构坏了报错。
pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Parser {
        return .{ .data = data };
    }

    pub fn next(self: *Parser) Error!?Item {
        if (self.pos == self.data.len) return null;
        if (self.data.len - self.pos < 2) return error.Truncated;
        const id = self.data[self.pos];
        const len: usize = self.data[self.pos + 1];
        if (self.data.len - self.pos - 2 < len) return error.Truncated;
        const body = self.data[self.pos + 2 ..][0..len];
        const full = self.data[self.pos .. self.pos + 2 + len];
        self.pos += 2 + len;

        if (id != kde_type_vendor_specific) return .{ .element = .{ .id = id, .body = body, .full = full } };
        if (len < length_base) return error.BadKde;
        const kde_oui = body[0..3].*;
        const data_type = body[3];
        const payload = body[4..];
        if (!std.mem.eql(u8, &kde_oui, &oui)) {
            return .{ .other_kde = .{ .oui = kde_oui, .data_type = data_type, .data = payload } };
        }
        switch (data_type) {
            DataType.pmkid => {
                if (payload.len != pmkid_len) return error.BadKde;
                return .{ .pmkid = payload[0..pmkid_len].* };
            },
            DataType.gtk => {
                // Key ID/Tx 八位组 + Reserved 八位组，之后是 GTK。
                if (payload.len < 2) return error.BadKde;
                try checkKeyLen(payload.len - 2);
                return .{ .gtk = .{
                    .key_id = payload[0] & 0x03,
                    .tx = (payload[0] & 0x04) != 0,
                    .gtk = payload[2..],
                } };
            },
            DataType.igtk => {
                if (payload.len < 8) return error.BadKde;
                try checkKeyLen(payload.len - 8);
                return .{ .igtk = .{
                    .key_id = std.mem.readInt(u16, payload[0..2], .little),
                    .ipn = payload[2..8].*,
                    .igtk = payload[8..],
                } };
            },
            else => return .{ .other_kde = .{ .oui = kde_oui, .data_type = data_type, .data = payload } },
        }
    }
};

/// 往一块调用方给的缓冲里顺序追加元素与 KDE。
pub const Builder = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Builder {
        return .{ .buf = buf };
    }

    pub fn data(self: *const Builder) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn appendElement(self: *Builder, id: u8, body: []const u8) Error!void {
        self.len = try putElement(self.buf, self.len, id, body);
    }

    pub fn appendPmkid(self: *Builder, pmkid: [pmkid_len]u8) Error!void {
        self.len = try putPmkid(self.buf, self.len, pmkid);
    }

    pub fn appendGtk(self: *Builder, key_id: u8, tx: bool, gtk: []const u8) Error!void {
        self.len = try putGtk(self.buf, self.len, key_id, tx, gtk);
    }

    pub fn appendIgtk(self: *Builder, key_id: u16, ipn: [6]u8, igtk: []const u8) Error!void {
        self.len = try putIgtk(self.buf, self.len, key_id, ipn, igtk);
    }

    /// 填充并包裹（12.7.2 j)、h)）。填充就地写在 `self.buf` 里，密文写入
    /// `wrapped`（不得与 `self.buf` 重叠），返回密文长度。
    pub fn wrap(self: *Builder, kek: [keywrap.kek_len]u8, wrapped: []u8) WrapError!usize {
        return self.wrapWith(&kek, wrapped);
    }

    /// 同 `wrap`，KEK 是 16 或 32 八位组（表 12-8：AKM 00-0F-AC:12、13 是 256 位）。
    pub fn wrapWith(self: *Builder, kek: []const u8, wrapped: []u8) WrapError!usize {
        const padded = try appendPadding(self.buf, self.len);
        return kekWrap(kek, self.buf[0..padded], wrapped);
    }
};

pub const Unwrapped = struct {
    /// 去掉尾部填充后的明文 Key Data，位于 `out` 的开头。
    plain: []const u8,
};

/// NIST AES Key Wrap（RFC 3394）：KEK 是 16 或 32 八位组（表 12-8 的 KEK_bits 128、256），
/// 别的长度报 `BadKeyLength`。
fn kekWrap(kek: []const u8, plain: []const u8, out: []u8) WrapError!usize {
    return switch (kek.len) {
        keywrap.kek_len => keywrap.wrap(kek[0..keywrap.kek_len].*, plain, out),
        keywrap.kek_len_256 => keywrap.wrap256(kek[0..keywrap.kek_len_256].*, plain, out),
        else => error.BadKeyLength,
    };
}

fn kekUnwrap(kek: []const u8, wrapped: []const u8, out: []u8) WrapError!usize {
    return switch (kek.len) {
        keywrap.kek_len => keywrap.unwrap(kek[0..keywrap.kek_len].*, wrapped, out),
        keywrap.kek_len_256 => keywrap.unwrap256(kek[0..keywrap.kek_len_256].*, wrapped, out),
        else => error.BadKeyLength,
    };
}

/// 解包并去掉尾部填充，KEK 是 128 位（表 12-8 里 KEK_bits 为 128 的 AKM）。明文写进 `out`
/// （至少 `keywrap.max_plain` 字节）。
pub fn unwrapKeyData(kek: [keywrap.kek_len]u8, wrapped: []const u8, out: []u8) WrapError!Unwrapped {
    return unwrapKeyDataKek(&kek, wrapped, out);
}

/// 同 `unwrapKeyData`，KEK 是 16 或 32 八位组（表 12-8：AKM 00-0F-AC:12、13 是 256 位）。
pub fn unwrapKeyDataKek(kek: []const u8, wrapped: []const u8, out: []u8) WrapError!Unwrapped {
    const n = try kekUnwrap(kek, wrapped, out);
    return .{ .plain = try stripPadding(out[0..n]) };
}
