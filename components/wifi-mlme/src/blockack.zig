//! wifi-mlme：Block Ack——字段、帧、建立/拆除判决、记分板与重排缓冲、A-MSDU 子帧
//! （IEEE Std 802.11-2016，Clause 9 / 10.24 / 11.5）。
//!
//! 对应原文（行号是 /tmp/spec/802.11-2016.txt 的行号；页码为印刷页码，即 `=== PAGE N ===`
//! 的 N−1）：
//!
//! 字段
//!   * 9.4.1.14（行 41365，Figure 9-79）：Block Ack Parameter Set，2 字节：B0 A-MSDU
//!     Supported、B1 Block Ack Policy（1=Immediate，0=Delayed）、B2–B5 TID、B6–B15
//!     Buffer Size（10 位）。ADDBA Response 的 Status=SUCCESS 时 Buffer Size ≥ 1
//!     （行 41403–41406）；ADDBA Request 里 0 = 无信息。
//!   * 9.4.1.15（行 41407，Figure 9-80）：Block Ack Timeout Value，TU；0 关闭超时。
//!   * 9.4.1.16（行 41414，Figure 9-81）：DELBA Parameter Set，2 字节：B0–B10 保留、
//!     B11 Initiator（1=数据发起方，0=接收方）、B12–B15 TID。
//!   * 9.4.2.139（行 58039，Figure 9-530/9-531）：ADDBA Extension 元素，Element ID 159
//!     （Table 9-77，行 43865），Length=1；B0 No-Fragmentation、B1–B7 保留。
//! 帧
//!   * Table 9-47（行 41292）：Category 3 = Block Ack；Table 9-302（行 62538–62544）：
//!     Action 0=ADDBA Request、1=ADDBA Response、2=DELBA、3–255 保留。
//!   * 9.6.5.2（行 62520，Table 9-303）：ADDBA Request = Category+Action+Dialog Token+
//!     BA Parameter Set+BA Timeout+SSC（Dialog Token 非零，行 62547；SSC 的 Fragment
//!     Number = 0，行 62550）。
//!   * 9.6.5.3（行 62559，Table 9-304）：ADDBA Response = Category+Action+Dialog Token+
//!     Status Code+BA Parameter Set+BA Timeout。Status Code 见 Table 9-46（行 40981）：
//!     0=SUCCESS；MLME-ADDBA 的 REFUSED 编码为 1（该表第 1 行的名字列）。
//!   * 9.6.5.4（行 62594，Table 9-305）：DELBA = Category+Action+DELBA Parameter Set+
//!     Reason Code。Reason Code 见 Table 9-45（行 40763）：39=TIMEOUT（行 40861）、
//!     38=UNKNOWN_BA、37=END_BA、1=UNSPECIFIED_REASON。
//!   * 9.3.1.8（行 37853，Figure 9-26/9-27/9-28、Table 9-21/9-22）：BlockAckReq；
//!     9.3.1.9（行 38008，Figure 9-32/9-33、Table 9-23/9-24）：BlockAck。变体位组合
//!     （Multi-TID, Compressed, GCR）：Basic=(0,0,0)、Compressed=(0,1,0)；其余不做。
//! 过程
//!   * 11.5.2.2（行 87850）发起方、11.5.2.3（行 87897）接收方、11.5.2.4 + Table 11-4
//!     （行 87909）协议类型、11.5.3（行 87949）拆除、11.5.4（行 88013）失活定时器与
//!     对端失效恢复。
//!   * 10.24.2（行 74045）：参数协商——响应 Buffer Size 比请求小时发起方必须把 WinSizeO
//!     收到 ≤ 响应值且 ≤ 64（行 74087–74090）；HT 间请求 policy=1 时接受的响应必须
//!     policy=1（行 74081–74083）；超时更新被拒时原协议保持（行 74095–74099）。
//!   * 10.24.4（行 74243）：接收缓冲与 NextExpectedSequenceNumber。
//!   * 10.24.7.3（行 74391）：全状态记分板，WinSizeR = min(64, 响应 Buffer Size)。
//!   * 10.24.7.5（行 74516）：BlockAck 的 SSN 取 (WinEndR−63)..WinStartR；位图覆盖
//!     WinStartR..WinEndR，超过 WinEndR 的位必须 0。
//!   * 10.24.7.6（行 74554，印刷页 1427–1428）：重排缓冲 WinStartB/WinEndB/WinSizeB 的
//!     三段规则与 BlockAckReq 前移（行 74641）：7.6.2 b) 与 7.6.3 a) 都是两端严格
//!     （WinEnd < X < WinStart+2^11；7.6.3 a) 还要求 WinStartB < SSN），d = 2^11 归旧
//!     序号一侧（丢弃 / 不变）。这些不等式在文本转储里是空的（原文是图片），按 PDF
//!     原件（印刷页 1424/1427/1428）逐式核对。
//! A-MSDU
//!   * 9.3.2.2（行 38682，Figure 9-54/9-55）：子帧 = DA(6)+SA(6)+Length(2)+MSDU(0–2304)
//!     +Padding(0–3)；除最后一个子帧外按 4 字节对齐填充（子帧总长）；「The order of these
//!     fields and the bits within these fields are the same as the IEEE 802.3 frame
//!     format」→ Length 大端。Short A-MSDU（9.3.2.2.3）DMG 专用，不做。
//!   * 10.12（行 71468）：A-MSDU 只放 QoS Data 帧体、单 MPDU 不分片、同 TID；响应里
//!     A-MSDU Supported=0 时不得在该 BA 下发 A-MSDU（行 71502–71504）。
//!
//! 序号与回绕：所有序号运算 mod 2^12，比较以 WinStart+半个序号空间分新旧（10.24.1，
//! 行 74040–74043）。TU = 1024 µs（行 8043）。保留字段发送置 0、接收忽略（行 36052）——
//! 所以解码不拒绝保留位，编码恒写 0。
//!
//! 期望值来源：按 Figure 9-26/9-27/9-28/9-32/9-33/9-34/9-35/9-55/9-79/9-80/9-81/9-530
//! 手排的字节 + Python oracle（/tmp/s31-oracle/blockack/，照同一份策略写的独立模型）+
//! 内核头文件交叉核对：/nix/store/j4292pp1j7n772fzwida46i58hvba8bl-linux-6.18.51-dev/
//! lib/modules/6.18.51/source/include/linux/ieee80211.h（WLAN_CATEGORY_BACK=3、
//! WLAN_STATUS_SUCCESS=0、addba_req/resp/delba 字段顺序与小端、WLAN_EID_ADDBA_EXT=159、
//! IEEE80211_ADDBA_EXT_NO_FRAG=BIT(0)；该头的 FRAG_LEVEL/BUF_SIZE 位属于 2020 版之后的
//! ADDBA Extension，不采用）。hostap（IDF 裁剪版）没有 ADDBA/DELBA 常量与结构体，无法对拍。
//!
//! 「64 位与 16 位压缩位图」的读法：Compressed BlockAck 的 64 条目 8 字节位图（10.24.7.5）
//! 与 Basic BlockAck 的每 MSDU 16 分片位（9.3.1.9.2，标 obsolete 只留编解码与位映射）。
//! 明确不做：A-MPDU 分隔符与聚合时序（10.13）、立即/延迟策略里依赖 MAC 时序的部分、
//! Extended Compressed / Multi-TID / VHT 1024 位 / Multi-STA 变体、GCR Block Ack、
//! Short A-MSDU（DMG）、GCR 行的 Table 11-4。
//! 板侧自检条数：19 条（blockack_selftest.zig 文件头）。时间全部注入，无堆、无分配。

const std = @import("std");
const frame = @import("frame.zig");

// ---------------------------------------------------------------------------
// 1) 公共常量：序号回绕、TU、变体
// ---------------------------------------------------------------------------

/// 序号空间 2^12（10.24.1，行 74040）：序号取 0..4095（u12），空间大小 4096。
pub const seq_space: u16 = 4096;
/// 「新旧」分界 = 半个序号空间（10.24.1，行 74041–74043）。
pub const seq_half: u12 = 2048;
/// 1 TU = 1024 µs（术语表，行 8043）。
pub const tu_us: u32 = 1024;

/// (a − b) mod 2^12 落在 [0, 2^11) 时 a 不旧于 b；相等算「不旧于」。
/// 含端点的三段判断一律用 (SN − WinStart) mod 2^12 与窗口大小的比较（10.24.7.3）。
pub inline fn seqOffset(sn: u12, base: u12) u12 {
    return sn -% base;
}

/// Table 9-47（行 41299）：Block Ack 的 Category 值。
pub const category_block_ack: u8 = 3;

/// Table 9-302：Block Ack Action 的取值；3–255 保留。
pub const Action = enum(u8) {
    addba_request = 0,
    addba_response = 1,
    delba = 2,
    _,
};

/// Table 9-46（行 40981–40984）：0=SUCCESS；第 1 行名字列含 REFUSED（11.5.2.3 行 87908
/// 把 MLME-ADDBA 的 ResultCode 指到本表）。
pub const status_success: u16 = 0;
pub const status_refused: u16 = 1;

/// Table 9-45（行 40764–40862）：DELBA 用到的 Reason Code。
pub const Reason = enum(u16) {
    unspecified = 1,
    end_ba = 37,
    unknown_ba = 38,
    timeout = 39,
    _,

    pub fn name(self: Reason) []const u8 {
        return switch (self) {
            .unspecified => "UNSPECIFIED_REASON",
            .end_ba => "END_BA",
            .unknown_ba => "UNKNOWN_BA",
            .timeout => "TIMEOUT",
            _ => "reserved",
        };
    }
};

/// Table 9-22 / Table 9-24（行 37985 / 38060）：(Multi-TID, Compressed, GCR) → 变体。
/// GCR 的两个组合与 0,0,1 / 1,0,1 / 1,1,1 都标 Reserved（GCR Block Ack 不做）。
pub const Variant = enum {
    basic,
    compressed,
    extended_compressed,
    multi_tid,
    reserved,

    pub fn of(multi_tid: bool, compressed: bool, gcr: bool) Variant {
        if (gcr) return .reserved;
        if (multi_tid) return if (compressed) .multi_tid else .extended_compressed;
        return if (compressed) .compressed else .basic;
    }
};

/// 10.24.6（行 74310–74311）：HT STA 对 HT STA 一律 Compressed，否则 0。
pub fn compressedFor(ht_pair: bool) bool {
    return ht_pair;
}

/// BlockAckReq / BlockAck 共用的 Control 字段布局（Figure 9-27 与 Figure 9-33 同形，
/// 行 37957–37959 / 38052–38054）：B0 Ack Policy、B1 Multi-TID、B2 Compressed Bitmap、
/// B3 GCR、B4–B11 保留（8 位）、B12–B15 TID_INFO。
pub const ControlField = struct {
    /// Table 9-21 / 9-23：0=Normal Ack，1=No Ack；仅在 Delayed / HT-delayed 协议下有意义，
    /// 其余协议下保留（行 37962–37963）——解码不拒。
    ack_policy: bool = false,
    multi_tid: bool = false,
    compressed: bool = false,
    gcr: bool = false,
    tid_info: u4 = 0,

    pub fn encode(self: ControlField) u16 {
        return @as(u16, @intFromBool(self.ack_policy)) |
            (@as(u16, @intFromBool(self.multi_tid)) << 1) |
            (@as(u16, @intFromBool(self.compressed)) << 2) |
            (@as(u16, @intFromBool(self.gcr)) << 3) |
            (@as(u16, self.tid_info) << 12); // B4–B11 保留，恒写 0（行 36052）
    }

    pub fn decode(w: u16) ControlField {
        return .{
            .ack_policy = (w & 1) != 0,
            .multi_tid = (w >> 1) & 1 != 0,
            .compressed = (w >> 2) & 1 != 0,
            .gcr = (w >> 3) & 1 != 0,
            .tid_info = @truncate(w >> 12),
        };
    }

    pub fn variant(self: ControlField) Variant {
        return Variant.of(self.multi_tid, self.compressed, self.gcr);
    }
};

/// Figure 9-28（行 37989–37991）：SSC = B0–B3 Fragment Number、B4–B15 Starting Sequence
/// Number。BAR/BA 各变体都规定 Fragment Number 置 0（9.3.1.8.3 行 37999–38000）。
pub const Ssc = struct {
    ssn: u12,
    frag: u4,

    pub fn encode(self: Ssc) u16 {
        return @as(u16, self.ssn) << 4 | self.frag;
    }

    pub fn decode(w: u16) Ssc {
        return .{ .ssn = @truncate(w >> 4), .frag = @truncate(w) };
    }
};

// ---------------------------------------------------------------------------
// 2) 三个字段（9.4.1.14 / 9.4.1.15 / 9.4.1.16 / 9.4.2.139）
// ---------------------------------------------------------------------------

pub const BuildError = error{
    /// TID 超过 4 位。
    BadTid,
    /// Buffer Size 超过 10 位（0–1023，MLME-ADDBA.request 的 BufferSize 值域，行 21189）。
    BadBufferSize,
    /// Timeout 超过 16 位。
    BadTimeout,
};

/// 9.4.1.14 / Figure 9-79。
pub const BaPolicy = enum(u1) {
    delayed = 0,
    immediate = 1,

    pub fn name(self: BaPolicy) []const u8 {
        return switch (self) {
            .delayed => "delayed",
            .immediate => "immediate",
        };
    }
};

pub const BaParameterSet = struct {
    amsdu_supported: bool,
    policy: BaPolicy,
    tid: u4,
    buffer_size: u10,

    /// Table 9-302 的 TID 子字段放行 0–15（TC 或 TS，9.4.1.14 行 41371「the value of the
    /// TC or TS」），所以只查 4 位宽度。
    pub fn build(tid: u8, buffer_size: u32, policy: BaPolicy, amsdu: bool) BuildError!BaParameterSet {
        if (tid > 15) return error.BadTid;
        if (buffer_size > 1023) return error.BadBufferSize;
        return .{
            .amsdu_supported = amsdu,
            .policy = policy,
            .tid = @intCast(tid),
            .buffer_size = @intCast(buffer_size),
        };
    }

    pub fn encode(self: BaParameterSet) u16 {
        return @as(u16, @intFromBool(self.amsdu_supported)) |
            (@as(u16, @backingInt(self.policy)) << 1) |
            (@as(u16, self.tid) << 2) |
            (@as(u16, self.buffer_size) << 6);
    }

    pub fn decode(w: u16) BaParameterSet {
        return .{
            .amsdu_supported = (w & 1) != 0,
            .policy = @fromBackingInt(@as(u1, @truncate(w >> 1))),
            .tid = @truncate(w >> 2),
            .buffer_size = @truncate(w >> 6),
        };
    }
};

/// 9.4.1.15 / Figure 9-80：TU 计，0 关闭超时（行 41412–41413）。
pub fn timeoutValue(tu: u32) BuildError!u16 {
    if (tu > 65535) return error.BadTimeout;
    return @intCast(tu);
}

/// 0 表示关闭（9.4.1.15）。
pub fn timeoutDisabled(tu: u16) bool {
    return tu == 0;
}

pub const DelbaParameterSet = struct {
    /// 1 = 数据发起方，0 = 接收方（9.4.1.16 行 41421–41423）。
    initiator: bool,
    tid: u4,

    pub fn build(tid: u8, initiator: bool) BuildError!DelbaParameterSet {
        if (tid > 15) return error.BadTid;
        return .{ .initiator = initiator, .tid = @intCast(tid) };
    }

    pub fn encode(self: DelbaParameterSet) u16 {
        // B0–B10 保留，恒写 0。
        return (@as(u16, @intFromBool(self.initiator)) << 11) |
            (@as(u16, self.tid) << 12);
    }

    pub fn decode(w: u16) DelbaParameterSet {
        // B0–B10 保留：接收忽略（行 36052），不拒。
        return .{
            .initiator = (w >> 11) & 1 != 0,
            .tid = @truncate(w >> 12),
        };
    }
};

/// 9.4.2.139 / Figure 9-530：Element ID 159、Length 1、ADDBA Capabilities 1 字节。
pub const element_id_addba_ext: u8 = 159;

pub const AddbaExtension = struct {
    /// B0 No-Fragmentation（行 58044–58047）：请求里 1 = 发起方不分片；响应里 1 =
    /// 接收方不能收分片。B1–B7 保留。
    no_fragmentation: bool,

    pub fn capabilities(self: AddbaExtension) u8 {
        return @intFromBool(self.no_fragmentation); // B1–B7 保留，恒写 0
    }

    pub fn decode(capabilities_byte: u8) AddbaExtension {
        return .{ .no_fragmentation = (capabilities_byte & 1) != 0 };
    }

    pub fn encodeElement(self: AddbaExtension, out: []u8) usize {
        out[0] = element_id_addba_ext;
        out[1] = 1;
        out[2] = self.capabilities();
        return 3;
    }
};

// ---------------------------------------------------------------------------
// 3) 动作帧体（9.6.5.2 / 9.6.5.3 / 9.6.5.4）
// ---------------------------------------------------------------------------

pub const FrameError = error{
    /// 帧体长度不足。
    TooShort,
    /// 帧体长度超出（BAR/BA 的定长帧体）。
    TooLong,
    /// 输出缓冲太小。
    NoRoom,
    /// Category ≠ 3（Table 9-47）。
    BadCategory,
    /// Block Ack Action 取值与帧型不符（Table 9-302）。
    BadAction,
    /// Dialog Token 为 0（9.6.5.2「nonzero」；9.6.5.3 从请求拷贝）。
    BadDialogToken,
    /// SSC 的 Fragment Number ≠ 0（9.3.1.8.3 / 9.6.5.2；接收侧按畸形拒，实现选择）。
    BadFragmentNumber,
    /// 元素头截断或元素越过帧体末尾。
    BadElement,
    /// ADDBA Extension 的 Length ≠ 1（Figure 9-530）。
    BadElementLength,
    /// 同一 ADDBA Extension 元素出现两次。
    DuplicateElement,
    /// BAR/BA 的变体组合不在 {Basic, Compressed}（Table 9-22/9-24 其余不做）。
    UnsupportedVariant,
};

/// Table 9-303（行 62547–62556）：1+1+1+2+2+2，其后是可选元素。
pub const addba_request_len = 9;
/// Table 9-304（行 62563–62569）：1+1+1+2+2+2 = 9，其后是可选元素。
pub const addba_response_len = 9;
/// Table 9-305（行 62600–62602）：1+1+2+2 = 6。
pub const delba_len = 6;

/// 从帧体尾部解析可选元素（Table 9-303 的 GCR / Multi-band / TCLAS / ADDBA Extension）。
/// 未知元素按 IE 头跳过；ADDBA Extension 的 Length 必须 = 1 且至多一次。
fn parseElements(rest: []const u8, ext: *?AddbaExtension) FrameError!void {
    var i: usize = 0;
    while (i < rest.len) {
        if (rest.len - i < 2) return error.BadElement;
        const id = rest[i];
        const len: usize = rest[i + 1];
        if (rest.len - i - 2 < len) return error.BadElement;
        if (id == element_id_addba_ext) {
            if (len != 1) return error.BadElementLength;
            if (ext.* != null) return error.DuplicateElement;
            ext.* = AddbaExtension.decode(rest[i + 2]);
        }
        i += 2 + len;
    }
}

pub const AddbaRequest = struct {
    dialog: u8,
    params: BaParameterSet,
    /// TU；0 关闭超时（9.4.1.15）。
    timeout: u16,
    /// Block Ack Starting Sequence Control 的 Starting Sequence Number。
    ssn: u12,
    /// Table 9-303 第 10 项（可选）。
    ext: ?AddbaExtension = null,

    pub fn encode(self: AddbaRequest, out: []u8) FrameError!usize {
        if (self.dialog == 0) return error.BadDialogToken;
        const need = addba_request_len + (if (self.ext != null) @as(usize, 3) else 0);
        if (out.len < need) return error.NoRoom;
        out[0] = category_block_ack;
        out[1] = @backingInt(Action.addba_request);
        out[2] = self.dialog;
        std.mem.writeInt(u16, out[3..5], self.params.encode(), .little);
        std.mem.writeInt(u16, out[5..7], self.timeout, .little);
        std.mem.writeInt(u16, out[7..9], self.ssc().encode(), .little);
        var pos: usize = addba_request_len;
        if (self.ext) |e| pos += e.encodeElement(out[pos..]);
        return pos;
    }

    pub fn ssc(self: AddbaRequest) Ssc {
        return .{ .ssn = self.ssn, .frag = 0 };
    }

    pub fn parse(body: []const u8) FrameError!AddbaRequest {
        if (body.len < addba_request_len) return error.TooShort;
        if (body[0] != category_block_ack) return error.BadCategory;
        if (body[1] != @backingInt(Action.addba_request)) return error.BadAction;
        if (body[2] == 0) return error.BadDialogToken;
        const ssc_word = std.mem.readInt(u16, body[7..9], .little);
        const s = Ssc.decode(ssc_word);
        if (s.frag != 0) return error.BadFragmentNumber;
        var ext: ?AddbaExtension = null;
        try parseElements(body[addba_request_len..], &ext);
        return .{
            .dialog = body[2],
            .params = BaParameterSet.decode(std.mem.readInt(u16, body[3..5], .little)),
            .timeout = std.mem.readInt(u16, body[5..7], .little),
            .ssn = s.ssn,
            .ext = ext,
        };
    }
};

pub const AddbaResponse = struct {
    dialog: u8,
    status: u16,
    params: BaParameterSet,
    timeout: u16,
    ext: ?AddbaExtension = null,

    pub fn encode(self: AddbaResponse, out: []u8) FrameError!usize {
        if (self.dialog == 0) return error.BadDialogToken;
        const need = addba_response_len + (if (self.ext != null) @as(usize, 3) else 0);
        if (out.len < need) return error.NoRoom;
        out[0] = category_block_ack;
        out[1] = @backingInt(Action.addba_response);
        out[2] = self.dialog;
        std.mem.writeInt(u16, out[3..5], self.status, .little);
        std.mem.writeInt(u16, out[5..7], self.params.encode(), .little);
        std.mem.writeInt(u16, out[7..9], self.timeout, .little);
        var pos: usize = addba_response_len;
        if (self.ext) |e| pos += e.encodeElement(out[pos..]);
        return pos;
    }

    pub fn parse(body: []const u8) FrameError!AddbaResponse {
        if (body.len < addba_response_len) return error.TooShort;
        if (body[0] != category_block_ack) return error.BadCategory;
        if (body[1] != @backingInt(Action.addba_response)) return error.BadAction;
        if (body[2] == 0) return error.BadDialogToken;
        var ext: ?AddbaExtension = null;
        try parseElements(body[addba_response_len..], &ext);
        return .{
            .dialog = body[2],
            .status = std.mem.readInt(u16, body[3..5], .little),
            .params = BaParameterSet.decode(std.mem.readInt(u16, body[5..7], .little)),
            .timeout = std.mem.readInt(u16, body[7..9], .little),
            .ext = ext,
        };
    }
};

pub const DelbaFrame = struct {
    params: DelbaParameterSet,
    reason: u16,

    pub fn encode(self: DelbaFrame, out: []u8) FrameError!usize {
        if (out.len < delba_len) return error.NoRoom;
        out[0] = category_block_ack;
        out[1] = @backingInt(Action.delba);
        std.mem.writeInt(u16, out[2..4], self.params.encode(), .little);
        std.mem.writeInt(u16, out[4..6], self.reason, .little);
        return delba_len;
    }

    pub fn parse(body: []const u8) FrameError!DelbaFrame {
        if (body.len < delba_len) return error.TooShort;
        if (body[0] != category_block_ack) return error.BadCategory;
        if (body[1] != @backingInt(Action.delba)) return error.BadAction;
        return .{
            .params = DelbaParameterSet.decode(std.mem.readInt(u16, body[2..4], .little)),
            .reason = std.mem.readInt(u16, body[4..6], .little),
        };
    }
};

// ---------------------------------------------------------------------------
// 4) 建立 / 修改的判决（11.5.2、10.24.2、Table 11-4）
// ---------------------------------------------------------------------------

/// Table 11-4（行 87920–87933）非 DMG 的协议类型；GCR 行不做。
pub const AgreementType = enum {
    immediate,
    delayed,
    ht_immediate,
    ht_delayed,

    pub fn name(self: AgreementType) []const u8 {
        return switch (self) {
            .immediate => "Immediate",
            .delayed => "Delayed",
            .ht_immediate => "HT-immediate",
            .ht_delayed => "HT-delayed",
        };
    }
};

/// Table 11-4：类型由「是否双方都是 HT STA」与 ADDBA 里的 Block Ack Policy 决定。
/// policy 取响应里的值（双方都是 HT 且请求 policy=1 时响应必须也是 1，见 `negotiate`，
/// 所以与请求一致）。
pub fn agreementType(both_ht: bool, both_ht_delayed: bool, policy: BaPolicy) AgreementType {
    if (both_ht) {
        return switch (policy) {
            .immediate => .ht_immediate,
            .delayed => if (both_ht_delayed) .ht_delayed else .delayed,
        };
    }
    return switch (policy) {
        .immediate => .immediate,
        .delayed => .delayed,
    };
}

/// 10.24.7.3（行 74395–74396）/ 10.24.7.6.1（行 74578–74579）：WinSize = min(64, 响应的
/// Buffer Size)。调用方保证 buffer_size ≥ 1（negotiate 已拒 SUCCESS+0）。
pub fn winSizeFor(buffer_size: u10) u7 {
    const n: u16 = @min(64, @as(u16, buffer_size));
    return @intCast(n);
}

pub const NegotiateError = error{
    /// Status Code ≠ SUCCESS（11.5.2.2 d)：协议未建立）。
    Refused,
    /// Dialog Token 与请求不符（11.5.2.2 c)「matching dialog token」）。
    DialogTokenMismatch,
    /// TID 与请求不符（11.5.2.2 c)「and the TID」）。
    TidMismatch,
    /// SUCCESS 但 Buffer Size = 0（9.4.1.14 行 41403–41406：至少 1）。
    BadBufferSize,
    /// 双方都是 HT STA 且请求 policy=1，响应 policy≠1（10.24.2 行 74081–74083）。
    PolicyMismatch,
};

pub const Agreement = struct {
    type: AgreementType,
    /// 发起方发送窗口：min(64, 响应 Buffer Size)（10.24.2 行 74087–74090）。
    win_size_o: u7,
    /// 用响应里的超时（10.24.2 行 74079–74081「the block ack timeout that is used」）。
    timeout: u16,
    tid: u4,
    /// 响应里的 A-MSDU Supported（10.24.2 NOTE 行 74105–74107：响应方可自由选；不可接受时
    /// 发起方可拆除改用普通确认——是否拆除由调用方决策）。
    amsdu_under_ba: bool,
};

pub const NegotiateOpts = struct {
    both_ht: bool,
    both_ht_delayed: bool = false,
};

/// 发起方收到 ADDBA Response 后的判决（11.5.2.2 c)/d)、10.24.2）。更新超时的第二次
/// ADDBA 交换走同一函数：被拒（Refused / 不匹配）时调用方保留原协议（10.24.2 行
/// 74095–74099）。
pub fn negotiate(req: AddbaRequest, resp: AddbaResponse, opts: NegotiateOpts) NegotiateError!Agreement {
    if (resp.dialog != req.dialog) return error.DialogTokenMismatch;
    if (resp.params.tid != req.params.tid) return error.TidMismatch;
    if (resp.status != status_success) return error.Refused;
    if (resp.params.buffer_size == 0) return error.BadBufferSize;
    if (opts.both_ht and req.params.policy == .immediate and resp.params.policy != .immediate) {
        return error.PolicyMismatch;
    }
    return .{
        .type = agreementType(opts.both_ht, opts.both_ht_delayed, resp.params.policy),
        .win_size_o = winSizeFor(resp.params.buffer_size),
        .timeout = resp.timeout,
        .tid = resp.params.tid,
        .amsdu_under_ba = resp.params.amsdu_supported,
    };
}

// ---------------------------------------------------------------------------
// 5) 拆除与失活（11.5.3、11.5.4、10.24.5）
// ---------------------------------------------------------------------------

pub const Role = enum {
    /// 有数据要发、发 ADDBA Request 的一方（10.24.1 行 74017–74019）。
    originator,
    recipient,

    pub fn name(self: Role) []const u8 {
        return switch (self) {
            .originator => "originator",
            .recipient => "recipient",
        };
    }
};

/// 11.5.4（行 88015–88025）里能复位失活定时器的帧事件。`matching_tid` = 该帧属于本
/// 协议的 TID（别的 TID 不复位，行 88020–88021）。
pub const InactivityEvent = enum {
    /// QoS Data，Ack Policy = Block Ack（Table 9-9 的 Block Ack）。
    data_ack_block,
    /// QoS Data，Ack Policy = Normal Ack（= Implicit Block Ack Request，frame.AckPolicy
    /// 注释；11.5.4 行 88017–88019 两种都复位）。
    data_implicit_req,
    /// QoS Data，其余 Ack Policy（No Ack / No Explicit）：不复位。
    data_other_policy,
    /// BlockAckReq（该 TID）。
    block_ack_req,
    /// BlockAck（该 TID，只有发起方会收到）。
    block_ack,

    pub fn resets(self: InactivityEvent, role: Role, matching_tid: bool) bool {
        if (!matching_tid) return false;
        return switch (role) {
            .recipient => switch (self) {
                .data_ack_block, .data_implicit_req, .block_ack_req => true,
                .data_other_policy, .block_ack => false,
            },
            .originator => switch (self) {
                .block_ack => true,
                else => false,
            },
        };
    }
};

/// 每协议一个失活定时器（11.5.4 行 88016「an inactivity timer for every negotiated
/// block ack setup」；GCR 无定时器，GCR 不做）。时间注入。
pub const InactivityTimer = struct {
    /// TU；0 = 关闭（9.4.1.15）。关闭后 `expired` 恒 false。
    timeout_tu: u16,
    deadline_tu: u64,

    pub fn arm(now_tu: u64, timeout_tu: u16) InactivityTimer {
        return .{ .timeout_tu = timeout_tu, .deadline_tu = now_tu + timeout_tu };
    }

    /// 合资格帧交换到达时复位（条件见 `InactivityEvent.resets`）。
    pub fn feed(self: *InactivityTimer, now_tu: u64) void {
        self.deadline_tu = now_tu + self.timeout_tu;
    }

    pub fn expired(self: *const InactivityTimer, now_tu: u64) bool {
        return self.timeout_tu != 0 and now_tu >= self.deadline_tu;
    }
};

/// 失活到期后的动作（11.5.4 行 88023–88025）：发 DELBA（Reason = TIMEOUT，Table 9-45
/// 第 39 行）并发 MLME-DELBA.indication(TIMEOUT)。
pub fn timeoutDelbaReason() u16 {
    return @backingInt(Reason.timeout);
}

/// 收到 DELBA 的发起方动作（11.5.4 行 88066–88073）：
/// a) 丢弃已发未确认的 MPDU；b) 序号取「最后一个已发的（还要重传）」或「+1（不重传）」。
pub const OriginatorOnDelba = struct {
    keep_for_retransmit: bool,
    last_sent: u12,

    /// 下一次使用的序号。
    pub fn nextSeq(self: OriginatorOnDelba) u12 {
        return if (self.keep_for_retransmit) self.last_sent else self.last_sent +% 1;
    }
};

/// 没有活动协议时收到 Block Ack 策略数据的接收方（11.5.4 行 88048–88058）：数据丢弃、
/// 自己的 TXOP 内发 DELBA；收到 BlockAckReq 可回 Ack、必须回 DELBA。发送 DELBA 时把
/// last sequence number received 置为最后收到的 MPDU 序号（行 88058–88060）。
pub const NoBaRx = struct {
    last_seq: ?u12 = null,

    pub fn onQosData(self: *NoBaRx, sn: u12) void {
        // 「discard them and shall send a DELBA frame」：丢弃由调用方执行，这里只记账。
        self.last_seq = sn;
    }

    pub fn onBlockAckReq(self: *NoBaRx, sn: ?u12) void {
        if (sn) |s| self.last_seq = s;
    }
};

// ---------------------------------------------------------------------------
// 6) 控制帧（9.3.1.8 / 9.3.1.9）
// ---------------------------------------------------------------------------

/// 帧体自 RA 起：RA(6) TA(6) BAR Control(2) BAR Information(2)。Figure 9-26（行 37949）。
pub const bar_body_len = 6 + 6 + 2 + 2;
/// Compressed BlockAck 帧体自 RA 起：RA TA BA Control SSC bitmap(8)。Figure 9-35（行 38125）。
pub const ba_compressed_body_len = 6 + 6 + 2 + 2 + 8;
/// Basic BlockAck 帧体：位图 128 字节（Figure 9-34，行 38123；obsolete，保留编解码）。
pub const ba_basic_body_len = 6 + 6 + 2 + 2 + 128;

pub const BarRequest = struct {
    ra: [6]u8,
    ta: [6]u8,
    control: ControlField,
    ssn: u12,
    frag: u4,

    pub fn variant(self: BarRequest) Variant {
        return self.control.variant();
    }
};

pub const BlockAck = struct {
    ra: [6]u8,
    ta: [6]u8,
    control: ControlField,
    ssn: u12,
    frag: u4,
    /// Compressed：8 字节；Basic：128 字节。
    bitmap: []const u8,

    pub fn isCompressed(self: BlockAck) bool {
        return self.control.variant() == .compressed;
    }
};

fn checkControlVariant(control: ControlField, want: Variant) FrameError!void {
    if (control.variant() != want) return error.UnsupportedVariant;
}

/// 解析 Compressed BlockAckReq 的帧体（RA 起，16 字节）。
pub fn parseCompressedBar(body: []const u8) FrameError!BarRequest {
    if (body.len < bar_body_len) return error.TooShort;
    if (body.len > bar_body_len) return error.TooLong;
    const control = ControlField.decode(std.mem.readInt(u16, body[12..14], .little));
    try checkControlVariant(control, .compressed);
    const s = Ssc.decode(std.mem.readInt(u16, body[14..16], .little));
    if (s.frag != 0) return error.BadFragmentNumber;
    return .{
        .ra = body[0..6].*,
        .ta = body[6..12].*,
        .control = control,
        .ssn = s.ssn,
        .frag = s.frag,
    };
}

/// 解析 BlockAck 的帧体（RA 起）。按 BA Control 的变体取 8 或 128 字节位图。
pub fn parseBlockAck(body: []const u8) FrameError!BlockAck {
    const control_word = if (body.len >= 14) std.mem.readInt(u16, body[12..14], .little) else 0;
    const control = ControlField.decode(control_word);
    const want_len: usize = switch (control.variant()) {
        .compressed => ba_compressed_body_len,
        .basic => ba_basic_body_len,
        else => return error.UnsupportedVariant,
    };
    if (body.len < want_len) return error.TooShort;
    if (body.len > want_len) return error.TooLong;
    const s = Ssc.decode(std.mem.readInt(u16, body[14..16], .little));
    if (s.frag != 0) return error.BadFragmentNumber;
    const bitmap_len: usize = want_len - 16;
    return .{
        .ra = body[0..6].*,
        .ta = body[6..12].*,
        .control = control,
        .ssn = s.ssn,
        .frag = s.frag,
        .bitmap = body[16 .. 16 + bitmap_len],
    };
}

/// BAR Control / BA Control 的 TID_INFO 在 Basic/Compressed 变体里都是 TID
/// （9.3.1.8.3 行 37997–37998；9.3.1.9.3 行 38115–38116）。
pub fn tidInfo(control: ControlField) u4 {
    return control.tid_info;
}

/// 控制帧构造。`duration` 由调用方按 9.2.5 给；FCS 不在本模块（frame.fcsOk 可校验整帧）。
pub fn blockAckReqFrame(out: []u8, ra: [6]u8, ta: [6]u8, control: ControlField, ssn: u12, duration: u16) FrameError!usize {
    try checkControlVariant(control, .compressed);
    const need = 2 + 2 + 6 + 6 + 2 + 2; // FC + Duration + RA + TA + BAR Control + BAR Information
    if (out.len < need) return error.NoRoom;
    const fc = frame.FrameControl{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.block_ack_req) };
    var pos: usize = 0;
    std.mem.writeInt(u16, out[pos..][0..2], fc.encode(), .little);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], duration, .little);
    pos += 2;
    @memcpy(out[pos..][0..6], &ra);
    pos += 6;
    @memcpy(out[pos..][0..6], &ta);
    pos += 6;
    std.mem.writeInt(u16, out[pos..][0..2], control.encode(), .little);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], (Ssc{ .ssn = ssn, .frag = 0 }).encode(), .little);
    pos += 2;
    return pos;
}

/// Compressed BlockAck 整帧（不含 FCS）。`bitmap` 必须 8 字节。
pub fn compressedBlockAckFrame(out: []u8, ra: [6]u8, ta: [6]u8, control: ControlField, ssn: u12, bitmap: *const [8]u8, duration: u16) FrameError!usize {
    try checkControlVariant(control, .compressed);
    const need = 2 + 2 + 6 + 6 + 2 + 2 + 8;
    if (out.len < need) return error.NoRoom;
    const fc = frame.FrameControl{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.block_ack) };
    var pos: usize = 0;
    std.mem.writeInt(u16, out[pos..][0..2], fc.encode(), .little);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], duration, .little);
    pos += 2;
    @memcpy(out[pos..][0..6], &ra);
    pos += 6;
    @memcpy(out[pos..][0..6], &ta);
    pos += 6;
    std.mem.writeInt(u16, out[pos..][0..2], control.encode(), .little);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], (Ssc{ .ssn = ssn, .frag = 0 }).encode(), .little);
    pos += 2;
    @memcpy(out[pos..][0..8], bitmap);
    pos += 8;
    return pos;
}

// ---------------------------------------------------------------------------
// 7) Basic 位图的位映射（9.3.1.9.2；obsolete 变体，只留编解码与位语义）
// ---------------------------------------------------------------------------

/// Basic BlockAck 位图：128 字节 = 64 MSDU × 16 位；位 n 对应 SSC+n 的 MPDU，每个 MSDU
/// 的 16 位按 Fragment Number 展开（9.3.1.9.2 行 38096–38104）。
pub const BasicBitmap = struct {
    bytes: [128]u8 = @splat(0),

    /// (ssc, sn, frag) → 位下标。序号差 ≥ 64（位图之外）返回 null。
    pub fn bitIndex(ssc: u12, sn: u12, frag: u4) ?u11 {
        const d: u12 = sn -% ssc;
        if (d >= 64) return null;
        const idx: u16 = @as(u16, d) * 16 + frag;
        return @intCast(idx);
    }

    pub fn set(self: *BasicBitmap, ssc: u12, sn: u12, frag: u4) bool {
        const idx = bitIndex(ssc, sn, frag) orelse return false;
        self.bytes[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
        return true;
    }

    pub fn get(self: *const BasicBitmap, ssc: u12, sn: u12, frag: u4) ?bool {
        const idx = bitIndex(ssc, sn, frag) orelse return null;
        return (self.bytes[idx / 8] >> @intCast(idx % 8)) & 1 != 0;
    }
};

// ---------------------------------------------------------------------------
// 8) 记分板（10.24.7.3 全状态 + 10.24.7.5 的 BlockAck 生成）
// ---------------------------------------------------------------------------

/// Compressed 变体的全状态记分板：64 位位图、WinStartR（12 位）、WinSizeR ≤ 64。
/// 位 i ↔ 序号 (win_start + i) mod 2^12；u64 的位 i 对应帧位图第 i/8 字节的第 i%8 位
/// （LSB 在前，9.2.2 的位传输次序——帧位图手排时最容易搞反的一处）。三段条件以
/// d = (SN − WinStartR) mod 2^12 判（不等式按 PDF 原件，印刷页 1424）：
/// b)1) d < size 置位；b)2) size ≤ d < 2^11 前移（两端严格）；b)3) 2^11 ≤ d 旧序号
/// 不变。BlockAckReq：c)1) 0 < d < size（严格大于 WinStartR）；c)2) size ≤ d < 2^11
/// 前移并全清；c)3) 2^11 ≤ d 不变；SSN = WinStartR（d = 0）三段都不含 → 不改记录。
/// （行 74436–74455；文本转储里公式为空，曾据此错推 d = 2^11 属前移，2026-11-25 按
/// PDF 原件更正。）
pub const Scoreboard = struct {
    win_start: u12,
    win_size: u7,
    bits: u64,

    pub fn init(ssn: u12, win_size: u7) Scoreboard {
        std.debug.assert(win_size >= 1 and win_size <= 64);
        return .{ .win_start = ssn, .win_size = win_size, .bits = 0 };
    }

    fn mask(size: u7) u64 {
        if (size >= 64) return ~@as(u64, 0); // 全 64 位都有效
        return (@as(u64, 1) << @as(u6, @intCast(size))) - 1;
    }

    fn bitAt(self: *const Scoreboard, sn: u12) bool {
        const d = sn -% self.win_start;
        if (d >= self.win_size) return false;
        return (self.bits >> @as(u6, @intCast(d))) & 1 != 0;
    }

    fn setBitAt(self: *Scoreboard, sn: u12) void {
        const d = sn -% self.win_start;
        if (d < self.win_size) self.bits |= @as(u64, 1) << @intCast(d);
    }

    /// 10.24.7.3 b)（印刷页 1424）：收到 Data 帧。返回是否发生了窗口前移。
    pub fn recvData(self: *Scoreboard, sn: u12) bool {
        const d = sn -% self.win_start;
        if (d < self.win_size) { // b)1)：WinStartR ≤ SN ≤ WinEndR
            self.bits |= @as(u64, 1) << @intCast(d);
            return false;
        }
        if (d < seq_half) { // b)2)：WinEndR < SN < WinStartR + 2^11（两端严格）
            const j = d - self.win_size + 1; // u12，≥ 1 且 ≤ 2047
            if (j < self.win_size) {
                // 旧窗 [j, j+win_size) 平移后仍在新窗内（j ≤ 63，可安全移位）。
                self.bits = (self.bits >> @intCast(j)) & mask(self.win_size);
            } else {
                // 新窗整体在旧窗之外（旧窗外的位按不变式本来就是 0）。
                self.bits = 0;
            }
            self.win_start = sn -% (self.win_size - 1);
            // b)2) iv)：SN 的新位置 = win_size − 1。
            self.bits |= @as(u64, 1) << @intCast(self.win_size - 1);
            return true;
        }
        // b)3)：WinStartR + 2^11 ≤ SN < WinStartR（含 d = 2^11），旧序号不变。
        return false;
    }

    /// 10.24.7.3 c)（印刷页 1424）：收到 BlockAckReq。
    /// c)1) 是 WinStartR < SSN ≤ WinEndR（严格大于 WinStartR）；SSN = WinStartR
    /// 不落在三段里的任何一段 → 不改记录。
    pub fn recvBar(self: *Scoreboard, ssn: u12) bool {
        const d = ssn -% self.win_start;
        if (d == 0) return false; // SSN = WinStartR：三段都不含，不改记录
        if (d < self.win_size) { // c)1)：WinStartR < SSN ≤ WinEndR
            // i) 清 WinEndR+1..WinStartR+WinSizeR−1（旧窗外的位，按不变式已是 0）。
            self.win_start = ssn;
            self.bits = (self.bits >> @as(u6, @intCast(d))) & mask(self.win_size);
            return true;
        }
        if (d < seq_half) { // c)2)：WinEndR < SSN < WinStartR + 2^11（两端严格）
            self.win_start = ssn;
            self.bits = 0; // iii) 清 WinStartR..WinEndR
            return true;
        }
        // c)3)：WinStartR + 2^11 ≤ SSN < WinStartR（含 d = 2^11），不变。
        return false;
    }

    /// 10.24.7.5（行 74536–74544）：BlockAck 的 SSN 取 (WinEndR−63)..WinStartR 任一；
    /// 本实现固定取 WinStartR。位图覆盖 WinStartR..WinEndR，超过 WinEndR 的位必须 0。
    pub fn respond(self: *const Scoreboard) struct { ssn: u12, bitmap: u64 } {
        return .{ .ssn = self.win_start, .bitmap = self.bits & mask(self.win_size) };
    }

    /// 查询某序号的接收状态（记分板窗口内的位）。
    pub fn received(self: *const Scoreboard, sn: u12) ?bool {
        const d = sn -% self.win_start;
        if (d >= self.win_size) return null;
        return self.bitAt(sn);
    }
};

// ---------------------------------------------------------------------------
// 9) 重排缓冲（10.24.4 + 10.24.7.6）
// ---------------------------------------------------------------------------

/// 定长重排缓冲模型：槽位数 = WinSizeB（窗口大小），所以「缓冲满 → 交付最早序号」
/// （10.24.4 行 74282–74284）不可达：窗口全满的瞬间 WinStartB 必有条目、随即被
/// passConsecutive 交付，不单列该分支。
///
/// 时间注入：每个缓存条目带 `expire_at`；`expireTick(now)` 丢掉到期条目。802.11-2016
/// 没有定义接收侧重排缓冲的超时（只约束发起方 MSDU lifetime 与失活定时器），丢弃后缺口
/// 保留、等 BAR 前移——这是实现自由度 [INFERENCE]。
pub fn ReorderBuffer(comptime cap: usize) type {
    std.debug.assert(cap >= 1 and cap <= 64);
    return struct {
        const Self = @This();

        pub const Slot = struct {
            present: bool = false,
            sn: u12 = 0,
            token: u16 = 0,
            expire_at: u64 = 0,
        };

        /// WinStartB（10.24.7.6.1 行 74570–74571）。
        win_start: u12,
        win_size: u7,
        slots: [cap]Slot = blk: {
            var s: [cap]Slot = undefined;
            for (&s) |*x| x.* = .{};
            break :blk s;
        },

        pub fn init(ssn: u12, win_size: u7) Self {
            std.debug.assert(win_size >= 1 and @as(usize, win_size) <= cap);
            return .{ .win_start = ssn, .win_size = win_size };
        }

        fn find(self: *const Self, sn: u12) ?usize {
            for (&self.slots, 0..) |*s, i| {
                if (s.present and s.sn == sn) return i;
            }
            return null;
        }

        fn store(self: *Self, sn: u12, expire_at: u64, token: u16) void {
            // 不变量：缓存里的序号都在 [win_start, win_start+win_size) 内（b)/c) 之外的
            // SN 不会进 store，win_start 只前移），且 a) 分支已拒同序号——所以这里不会
            // 覆盖已有条目，槽满也不可达（槽数 = 窗口大小，见文件头）。别在这里加
            // 「满了丢弃」：那会把 b) 前移分支变成静默丢帧。
            for (&self.slots) |*s| {
                if (!s.present) {
                    s.* = .{ .present = true, .sn = sn, .token = token, .expire_at = expire_at };
                    return;
                }
            }
        }

        /// a)2)/b)5)：从 WinStartB 起连续交付，交付后 WinStartB = 最后交付 +1
        /// （10.24.7.6.2 a)3)）。返回交付条数。
        fn passConsecutive(self: *Self, out: []u16) usize {
            var n: usize = 0;
            while (n < out.len) {
                const i = self.find(self.win_start) orelse break;
                out[n] = self.slots[i].token;
                self.slots[i].present = false;
                self.win_start +%= 1;
                n += 1;
            }
            return n;
        }

        /// b)4)/BlockAckReq a)3)：把低于新 WinStartB 的缓存条目按序号递增交付（允许缺口）。
        /// 从旧 WinStartB 起走到新 WinStartB 之前。
        fn flushBelow(self: *Self, old_start: u12, out: []u16) usize {
            var n: usize = 0;
            const steps = self.win_start -% old_start;
            var k: u12 = 0;
            while (k < steps and n < out.len) : (k += 1) {
                const sn = old_start +% k;
                const i = self.find(sn) orelse continue;
                out[n] = self.slots[i].token;
                self.slots[i].present = false;
                n += 1;
            }
            return n;
        }

        /// 10.24.7.6.2：收到 Data 帧（SN）。返回交付条数（token 按交付次序写进 `out`）。
        pub fn recvData(self: *Self, sn: u12, expire_at: u64, token: u16, out: []u16) usize {
            const d = sn -% self.win_start;
            if (d < self.win_size) { // a)：窗内
                if (self.find(sn) != null) return 0; // a)1) 重复丢弃
                self.store(sn, expire_at, token);
                return self.passConsecutive(out); // a)2)–a)3)
            }
            if (d < seq_half) { // b)：WinEndB < SN < WinStartB + 2^11（两端严格）
                self.store(sn, expire_at, token); // b)1)
                const old_start = self.win_start;
                self.win_start = sn -% (self.win_size - 1); // b)3)
                var n = self.flushBelow(old_start, out); // b)4)
                n += self.passConsecutive(out); // b)5)–b)6)
                return n;
            }
            // c)：WinStartB + 2^11 ≤ SN < WinStartB（含 d = 2^11），丢弃。
            return 0;
        }

        /// 10.24.7.6.3（印刷页 1428）：收到 BlockAckReq（SSN）。
        /// a) WinStartB < SSN < WinStartB + 2^11（两端严格）：前移、冲刷下方、再连续交付；
        /// b) WinStartB + 2^11 ≤ SSN < WinStartB：不变。SSN = WinStartB（d = 0）不在
        /// 两段里——本实现照 a) 的路径走，但 win_start 不动、下方无条目、win_start 处
        /// 按不变式无条目，所以不交付也不改状态，与「不变」等价。
        pub fn recvBar(self: *Self, ssn: u12, out: []u16) usize {
            const d = ssn -% self.win_start;
            if (d >= seq_half) return 0; // b)
            const old_start = self.win_start;
            self.win_start = ssn; // a)1)
            var n = self.flushBelow(old_start, out); // a)3)
            n += self.passConsecutive(out); // a)4)–a)5)
            return n;
        }

        /// 模型自由度：丢掉 expire_at ≤ now 的缓存条目（缺口保留，等 BAR 前移）。
        pub fn expireTick(self: *Self, now: u64) usize {
            var n: usize = 0;
            for (&self.slots) |*s| {
                if (s.present and s.expire_at <= now) {
                    s.present = false;
                    n += 1;
                }
            }
            return n;
        }

        pub fn buffered(self: *const Self, sn: u12) bool {
            return self.find(sn) != null;
        }
    };
}

// ---------------------------------------------------------------------------
// 10) A-MSDU 子帧（9.3.2.2）
// ---------------------------------------------------------------------------

pub const AmsduError = error{
    /// 剩余字节不足一个子帧头（14 字节）或 MSDU 被截断。
    TooShort,
    /// Length > 2304（Figure 9-55 的 MSDU 0–2304）。
    BadLength,
    /// 非最后子帧的对齐缺口不足 pad 字节（帧体损坏）。
    BadPadding,
};

/// Figure 9-55（行 38752–38754）：DA(6)+SA(6)+Length(2)+MSDU+Padding。Length 的字段
/// 顺序与位序同 IEEE 802.3（行 38695–38696）→ 大端。
pub const amsdu_header_len = 14;
/// Figure 9-55：MSDU 0–2304。
pub const msdu_max_len: u16 = 2304;

pub const AmsduSubframe = struct {
    da: [6]u8,
    sa: [6]u8,
    /// MSDU 的字节数（0–2304）。
    len: u16,
    /// MSDU 在帧体里的偏移。
    offset: usize,
    /// 除最后一个子帧外的 4 字节对齐填充（0–3 字节，恒为 0）；最后一个子帧无填充
    /// （9.3.2.2.2 行 38690–38691）。
    padding: u8,
};

/// 解析整段 A-MSDU 帧体。解析规则：每步读 14 字节头与 Length；若剩余恰好等于
/// 子帧总长则是最后一个（无填充）；否则补 (4 − 总长 mod 4) mod 4 的填充后继续。
/// 填充内容不在规范里规定，本实现写 0、解析时跳过不校验内容。
pub fn parseAmsdu(body: []const u8, out: []AmsduSubframe) AmsduError!usize {
    var pos: usize = 0;
    var n: usize = 0;
    while (pos < body.len) {
        const left = body.len - pos;
        if (left < amsdu_header_len) return error.TooShort;
        const len = std.mem.readInt(u16, body[pos + 12 ..][0..2], .big);
        if (len > msdu_max_len) return error.BadLength;
        const total: usize = amsdu_header_len + len;
        if (left < total) return error.TooShort; // MSDU 截断
        const pad: u8 = @intCast((4 - (total % 4)) % 4);
        const is_last = left == total;
        if (!is_last) {
            if (left < total + pad) return error.BadPadding;
        }
        if (n == out.len) return error.TooShort; // 描述符表太小
        out[n] = .{
            .da = body[pos..][0..6].*,
            .sa = body[pos + 6 ..][0..6].*,
            .len = len,
            .offset = pos + amsdu_header_len,
            .padding = if (is_last) 0 else pad,
        };
        n += 1;
        pos += total + (if (is_last) @as(usize, 0) else @as(usize, pad));
    }
    return n;
}

/// 构造一个 A-MSDU 子帧（含非最后一个子帧的对齐填充，填充写 0）。返回写入的字节数。
pub fn appendAmsduSubframe(out: []u8, da: [6]u8, sa: [6]u8, msdu: []const u8, is_last: bool) AmsduError!usize {
    if (msdu.len > msdu_max_len) return error.BadLength;
    const total = amsdu_header_len + msdu.len;
    const pad: usize = if (is_last) 0 else (4 - (total % 4)) % 4;
    if (out.len < total + pad) return error.TooShort;
    @memcpy(out[0..6], &da);
    @memcpy(out[6..12], &sa);
    std.mem.writeInt(u16, out[12..14], @intCast(msdu.len), .big);
    @memcpy(out[14 .. 14 + msdu.len], msdu);
    @memset(out[14 + msdu.len ..][0..pad], 0);
    return total + pad;
}

/// 10.12（行 71468–71471）：A-MSDU 里所有 MSDU 的 DA 映射到同一个 RA、SA 映射到同一个
/// TA。DA→RA 的映射依赖转发决策（9.3.2.2.2 NOTE），本模块验不了映射本身；这里给的是
/// 字节级 sanity：SA 必须是单播地址（源地址是发送 STA 的个体地址）[INFERENCE]，DA 允许
/// 组地址（10.12 行 71540–71541 的 PCP 转发场景）。
pub fn saIsIndividual(sa: *const [6]u8) bool {
    return !frame.isGroupAddress(sa.*);
}

// ---------------------------------------------------------------------------
// 11) 便捷判决：无协议时的数据处置（11.5.4 收尾两段）
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}
