//! sfr：6LoWPAN 分片转发（RFC 8930 的 6LFF / VRB）与选择性分片恢复（RFC 8931 的 RFRAG / RFRAG-ACK）。
//!
//! 一句话：把 6LoWPAN 分片当作 MPLS 标签跨多跳转发（RFC 8930 §6 的 Virtual Reassembly
//! Buffer），并在两个端点之间用 5 位序列号 + 32 位确认位图做逐片选择性恢复（RFC 8931）。
//! 三个角色（发送方 / 接收方 / 转发方）都是纯逻辑状态机：不分配堆、不读时钟、不做
//! 链路层 I/O、不 import board/hw/log；时间由调用方以毫秒注入，Datagram_Tag 由调用方
//! 注入（RFC 8930 §7 行 476-479：tag 应伪随机指派）。
//!
//! 条款对照（行为 → 条款 / 图表 / 原文行号 → 函数）：
//!
//!   RFC 8931 §5（行 371-372）模拟 Link MTU ≤ 2048 → `max_datagram_size`；
//!   §5.1 图 1（行 429-440）RFRAG 头布局：byte0 = 1110100E，byte1 = tag，
//!     byte2 = X|Seq(5)|Size[9:8]，byte3 = Size[7:0]，byte4-5 = Fragment_Offset
//!     → `RfragHeader.encode/decode`；
//!   §5.1 行 422-427 首片以 Sequence 0 识别、末片以 offset+size==datagram_size 识别
//!     → `Receiver` 完成判据；行 449-452 Fragment_Size 10 位（字节单位 ≤ 1023）；
//!   §5.1 行 457-461 Sequence 5 位 [0..31]；行 463-495 Fragment_Offset 双语义
//!     （首片携带 Datagram_Size，其余片携带偏移）与 offset==0 的 abort 语义
//!     → `RfragHeader.decode` 的结构校验 + 各状态机的 reset 分支；
//!   §5.2 图 2/3（行 519-553）确认位图：seq x ↔ 32 位大端字段的位 (31-x)，
//!     NULL=放弃、FULL=全部收到（行 575-580）→ `RfragAck` / `bitmapSet/Get`；
//!   §5.2 图 4（行 556-562）RFRAG-ACK 头：byte0 = 1110101E + tag + 4 字节位图；
//!     行 586-588 ACK 是无载荷的独立头 → `RfragAck.decode` 拒绝尾随字节；
//!   §5 行 442-447 E 位由源清零、中间路由器置位 → 发送方恒发 e=false，
//!     `Forwarder.Args.congestion` 注入置位；
//!   §9 表 1（行 1083-1094）dispatch 位型 11 10100x / 11 10101x（Page 0）
//!     → `rfrag_dispatch_base` / `rfrag_ack_dispatch_base`；
//!   §6 行 597-600 outstanding 定义、行 605-609 收到 X 片必须回 ACK、
//!     行 613-616 X 必须落在末片（窗口末可放中间片）、行 618-625 RTO + 指数退避 +
//!     耗尽后重启（首片带 X）或放弃、行 637-640 ECN 至多回显一次、
//!     行 653-664 完成后发 FULL 并开吸收窗、行 669-672 延迟确认可配置默认关、
//!     行 680-690 round-robin（首发完才重传、最老优先）
//!     → `Sender`；
//!   §6.1.1 行 725-740 首片建 VRB / 前向 LSP / 反向 LSP；§6.1.2 行 747-767
//!     后续片按 (接口、上一跳地址、tag) 查 LSP，查不到就构造 NULL abort RFRAG-ACK
//!     （地址互换、tag 用收到的、NULL 位图）；§6.2 行 780-797 ACK 走反向 LSP、
//!     查不到静默丢、FULL 武装短定时器、窗内迟到片回 FULL、§6.3 行 815-843
//!     reset 伪片（offset==0，SHOULD seq/size 也为 0）、无 X 转发后销毁、
//!     接收方以 NULL 回应、NULL 让发送方必须放弃
//!     → `Forwarder`；
//!   §7.1 行 898-1013 参数：Window_Size ∈ [1,32]（行 947-948）、Fragment_Size < 512
//!     （字节单位，行 944-945）、帧间空隙（行 911-918；8930 行 389-391 MUST、
//!     8931 §4.2 行 301-318）、Min/Opt/MaxARQTimeOut（行 969-989）、
//!     MaxFragRetries 缺省 3（行 991-994）、MaxDatagramRetries 缺省 1（行 996-1000）、
//!     UseECN（行 1006-1013）→ `SenderConfig`（gap 闸在 `Sender.poll`，对首发 /
//!     缺片重传 / RTO 重传一视同仁；转发方一侧的发送间隔归调用方的发送队列，
//!     本模块只产出帧、不发帧）。
//!   §4.4 行 356-363 首片改长时中间节点必须改 Datagram_Size 并把差值存进 VRB、
//!     加到后续片的 Fragment_Offset → `Forwarder.Args.size_delta` / `shiftOffset`；
//!   附录 C 行 1388-1402 收到 E 后窗口至少减 1、至多减到 1，逐数据报生效
//!     → `Sender.onAck`（本实现取减半、下限 1）；
//!   RFC 8930 §5 行 325-331 建状态+转发是原子操作、行 333-343 每跳换 tag 并重写
//!     分片头、无状态的后续片必须丢、行 371-373 未见过首片就收到后续片按错误处理、
//!     §6 行 415-418 VRB 表满丢包、行 484-486 表容量 + 定时器保护
//!     → `Forwarder`（表满丢首片、inactivity 定时器销毁）；
//!   RFC 4944 §5.3 行 685 重组超时 MUST ≤ 60 s → `Receiver.Config.reassembly_timeout_ms`
//!     的缺省值（RFC 8931 §7 行 898-900 只说“分钟量级”，无硬上限，本实现不设上限）。
//!
//! 期望值来源：(a) RFC 原文图表手排（上面给的行号；`=== PAGE N ===` 印刷页 = N-1）；
//! (b) 盘上没有 RFC 8930/8931 的独立实现（lwIP `lowpan6.c` 只有 RFC 4944 分片），
//! 所以 KAT 全部按原文手排；(c) 差分用 Python oracle `/tmp/s31-oracle/sfr/`
//! （随机构造 ≥ 200 组，头解析双向对拍）。禁止拿本实现自证。
//!
//! 与独立实现的差异：无独立实现可对拍；位图位序按图 2/3 的“左 cell = seq 0 = 字段 MSB”
//! 手排并用 oracle 交叉验证；X 在重传帧上的放置取“突发最后一帧”这一乐观方案
//! （附录 C 行 1404-1408），窗口门同时约束首发与重传，被门挡住时靠 RTO 推动。
//!
//! 明确不做：跨路由器真转发 / 路由查找（`Forwarder.Args.next_hop` 由调用方路由）、
//! mesh-under、Thread MLE、逐跳重组的替代网络层、拥塞控制的复杂算法（附录 C 只做
//! 降窗）、RFC 8138 在途改写（只留 size_delta 注入口）、分页 dispatch（Page 1-15，
//! 由适配层处理）。
//!
//! 板侧自检：16 条判据（见 `sfr_selftest.zig`），无椭圆曲线 / 大表；
//! 尺寸与栈：模块自身无大缓冲， Receiver/Forwarder 的存储由调用方以 comptime
//! 参数实例化（板侧自检用 2×(256+32)B 与 4×~64B，全部文件作用域）。

const std = @import("std");
const f15 = @import("fifteen4.zig");

pub const Error = error{
    /// 输入放不下 6 字节头。
    Short,
    /// RFRAG-ACK 头后带了载荷（§6 行 586-588：独立头，无 6LoWPAN 载荷）。
    Trailing,
    /// 首字节不是 RFRAG / RFRAG-ACK 的 dispatch 值（§9 表 1；RFC 4944 的 0xC0/0xE0、
    /// 未指派的 0xEC.. 等都算）。
    BadDispatch,
    /// Fragment_Size == 0 但 Fragment_Offset != 0：既不是有效数据片也不是 reset 伪片。
    BadFragmentSize,
    /// 偏移越界：数据片的 offset+size 越出 2048，或 VRB 差值把 offset 改成负数。
    BadOffset,
    /// 长度越界：Fragment_Size 超过 10 位字段，或首片声明的 Datagram_Size 超过
    /// 本规范模拟的 2048（§5 行 371-372）。
    TooLong,
    /// 输出缓冲不够放头 + 载荷。
    NoSpace,
    /// 编码时 Sequence 超出 5 位字段。
    BadSequence,
    /// 发送方配置违反 §7.1 的边界。
    BadConfig,
    /// 空数据报没有可发的片。
    EmptyDatagram,
    /// 数据报需要多于 32 片（附录 B 行 1327-1329：每包最多 32 片）。
    TooManyFragments,
    /// 转发方收到首片但调用方没有给出下一跳（路由是注入点）。
    NoRoute,
    /// 转发方下一跳命名空间里挑的 Datagram_Tag 已被在途数据报占用
    /// （RFC 8930 §5 行 379-384：tag 必须对该数据报生命周期唯一）。
    TagInUse,
};

// ---------------------------------------------------------------------------
// 头编解码（RFC 8931 §5.1 / §5.2）
// ---------------------------------------------------------------------------

/// RFRAG dispatch 位型 `11 10100x`（§9 表 1 行 1083；§5.1 图 1 行 431-436）。
/// 基值不含 E 位：byte0 = 基值 | E。
pub const rfrag_dispatch_base: u8 = 0xE8; // 1110 1000
/// RFRAG-ACK dispatch 位型 `11 10101x`（§9 表 1 行 1089；§5.2 图 4 行 558-561）。
pub const rfrag_ack_dispatch_base: u8 = 0xEA; // 1110 1010

pub const rfrag_header_len: usize = 6;
pub const rfrag_ack_header_len: usize = 6;

/// 本规范模拟的 Link MTU 上限（§5 行 371-372：“emulate a Link MTU up to 2048 bytes”）。
pub const max_datagram_size: u16 = 2048;
/// Fragment_Size 是 10 位无符号整数，字节单位下最多 1023（§5.1 行 449-452）。
pub const max_fragment_size: u16 = 1023;
/// Sequence 5 位 [0..31]（§5.1 行 457-461；附录 B 行 1327-1329 每包最多 32 片）。
pub const max_sequence: u8 = 31;

/// 确认位图常量（§5.2 行 575-580）：NULL = 放弃，FULL = 全部收到。
pub const bitmap_null: u32 = 0;
pub const bitmap_full: u32 = 0xFFFF_FFFF;

/// seq x ↔ 位 (31-x)：图 2（行 528-535）最左 cell 是 seq 0，即 4 字节大端字段的 MSB。
/// 图 3（行 545-553）的手排校验：seq 0..20 除 1、2、16 全收 → 字节 9F FF 78 00。
pub fn bitmapSet(b: u32, seq: u8) u32 {
    if (seq > max_sequence) return b;
    return b | (@as(u32, 1) << @intCast(31 - @as(u16, seq)));
}

pub fn bitmapGet(b: u32, seq: u8) bool {
    if (seq > max_sequence) return false;
    return (b >> @intCast(31 - @as(u16, seq))) & 1 != 0;
}

/// RFRAG 头（RFC 8931 §5.1 图 1，行 429-440）。
///
///   byte0: `1110100E`（dispatch + E）
///   byte1: Datagram_Tag（8 位，对发送方链路层地址局部唯一，行 454-455）
///   byte2: X(1) | Sequence(5) | Fragment_Size[9:8]
///   byte3: Fragment_Size[7:0]
///   byte4-5: Fragment_Offset（16 位；首片 = Datagram_Size，其余片 = 偏移，行 463-479）
pub const RfragHeader = struct {
    /// Ack-Request（行 442-444）。
    x: bool,
    /// ECN；源清零、中间路由器置位（行 445-447）。
    e: bool,
    seq: u8,
    /// 本片的 Fragment_Size（10 位，行 449-452）。
    size: u16,
    /// 首片 = Datagram_Size，其余片 = 压缩形态偏移（行 463-479）。
    offset: u16,
    tag: u8,

    pub fn encode(self: RfragHeader, out: []u8) Error!usize {
        if (self.seq > max_sequence) return error.BadSequence;
        if (self.size > max_fragment_size) return error.TooLong;
        if (out.len < rfrag_header_len) return error.NoSpace;
        out[0] = rfrag_dispatch_base | @as(u8, @intFromBool(self.e));
        out[1] = self.tag;
        out[2] = @as(u8, @intFromBool(self.x)) << 7 | self.seq << 2 |
            @as(u8, @truncate(self.size >> 8));
        out[3] = @truncate(self.size);
        out[4] = @truncate(self.offset >> 8);
        out[5] = @truncate(self.offset);
        return rfrag_header_len;
    }

    pub const Decoded = struct { header: RfragHeader, payload: []const u8 };

    /// 结构校验（每条拒绝路径一个错误值）：
    ///   len < 6 → Short；dispatch 不对 → BadDispatch；
    ///   size==0 且 offset!=0 → BadFragmentSize（无数据的片又不在 offset==0 的
    ///     reset 语义里；§6.3 行 817-820 的 reset 是 size==0 且 offset==0）；
    ///   seq!=0 时 offset+size 越出 2048 → BadOffset；
    ///   seq==0 时声明的 Datagram_Size 越出 2048 → TooLong（§5 行 371-372）。
    pub fn decode(frame: []const u8) Error!Decoded {
        if (frame.len < rfrag_header_len) return error.Short;
        const b0 = frame[0];
        // ACK 的位型（0xEA/0xEB）归 `RfragAck.decode`；拿它解 RFRAG 是错的。
        if ((b0 & 0xFE) == rfrag_ack_dispatch_base) return error.BadDispatch;
        if ((b0 & 0xFE) != rfrag_dispatch_base) return error.BadDispatch;
        const h = RfragHeader{
            .e = (b0 & 1) != 0,
            .tag = frame[1],
            .x = (frame[2] & 0x80) != 0,
            .seq = (frame[2] >> 2) & 0x1F,
            .size = (@as(u16, frame[2] & 0x03) << 8) | frame[3],
            .offset = (@as(u16, frame[4]) << 8) | frame[5],
        };
        if (h.size == 0 and h.offset != 0) return error.BadFragmentSize;
        if (h.seq == 0) {
            if (h.offset > max_datagram_size) return error.TooLong;
        } else {
            if (@as(u32, h.offset) + h.size > max_datagram_size) return error.BadOffset;
        }
        return .{ .header = h, .payload = frame[rfrag_header_len..] };
    }
};

/// RFRAG-ACK 头（RFC 8931 §5.2 图 4，行 556-562）：byte0 = `1110101E`，
/// byte1 = tag，byte2-5 = 32 位确认位图（大端，seq x ↔ 位 31-x，图 2 行 528-535）。
/// 行 586-588：独立头，无载荷——尾随字节按 Trailing 拒绝。
pub const RfragAck = struct {
    /// ECN Echo（行 564-570）。
    e: bool,
    /// 对链路层接收方局部唯一的 tag（行 572-574）。
    tag: u8,
    bitmap: u32,

    pub fn encode(self: RfragAck, out: []u8) Error!usize {
        if (out.len < rfrag_ack_header_len) return error.NoSpace;
        out[0] = rfrag_ack_dispatch_base | @as(u8, @intFromBool(self.e));
        out[1] = self.tag;
        std.mem.writeInt(u32, out[2..6], self.bitmap, .big);
        return rfrag_ack_header_len;
    }

    pub fn decode(frame: []const u8) Error!RfragAck {
        if (frame.len < rfrag_ack_header_len) return error.Short;
        if ((frame[0] & 0xFE) != rfrag_ack_dispatch_base) return error.BadDispatch;
        if (frame.len != rfrag_ack_header_len) return error.Trailing;
        return .{
            .e = (frame[0] & 1) != 0,
            .tag = frame[1],
            .bitmap = std.mem.readInt(u32, frame[2..6], .big),
        };
    }
};

// ---------------------------------------------------------------------------
// 发送方（fragmenting endpoint，RFC 8931 §6 / §7.1 / 附录 C）
// ---------------------------------------------------------------------------

/// 发送方参数（§7.1 行 898-1013）。时间值毫秒；边界在 `Sender.init` 校验。
pub const SenderConfig = struct {
    /// Window_Size ∈ [1, 32]（行 947-948）；32 是半双工 LLN 的推荐值（行 953-956）。
    window_size: u8 = 32,
    /// 帧间空隙：相邻两次发送之间的最小毫秒数（8930 行 389-391 MUST；8931 §4.2
    /// 行 301-318、§7.1 行 911-918 参数）。任何发送（首发 / 重传 / RTO 重传）
    /// 都必须与上一帧隔开；0 表示链路自身已保证间隔（调用方自证）。
    gap_ms: u32,
    /// MinARQTimeOut：RTO 下限（行 969-972）。必须 ≥ 1。
    min_arq_timeout_ms: u32,
    /// OptARQTimeOut：RTO 初值，推荐 3×最大 RTT（行 974-981）。
    opt_arq_timeout_ms: u32,
    /// MaxARQTimeOut：退避上限（行 982-989）。
    max_arq_timeout_ms: u32,
    /// MaxFragRetries：单片重传上限，缺省 3（行 991-994）。
    max_frag_retries: u8 = 3,
    /// MaxDatagramRetries：整个数据报从头重来的上限，缺省 1（行 996-1000）。
    max_datagram_retries: u8 = 1,
    /// UseECN：是否响应 ECN（行 1006-1013）。
    use_ecn: bool = true,
};

pub const SenderState = enum(u8) {
    /// 传输中。
    active,
    /// 对端确认覆盖了整个数据报。
    complete,
    /// 已放弃（NULL 位图、重传耗尽或调用方 abort；放弃前发过 reset 伪片）。
    aborted,
};

/// 发送方一次 poll 的结果。
pub const Outcome = union(enum) {
    /// 一帧（6 字节头 + 片载荷）已写进 out，长度为值。
    frame: usize,
    /// 现在没有帧可发（窗口门挡住或全部在途），等确认或 RTO。
    wait,
    complete,
    /// 已放弃；poll 不会再产出帧。
    aborted,
};

pub const SenderStats = struct {
    frames_sent: u32 = 0,
    frag_retries: u32 = 0,
    rto_timeouts: u32 = 0,
    rto_retransmits: u32 = 0,
    restarts: u32 = 0,
    aborts: u32 = 0,
    resets_sent: u32 = 0,
    acks: u32 = 0,
    acks_dropped: u32 = 0,
    ecn_events: u32 = 0,
    completes: u32 = 0,
};

/// 发送方状态机（乐观窗口方案，附录 C 行 1404-1408：发满窗口、只在窗口末 / 末片
/// 置 X、等位图、按序重传丢失片）。
///
/// 必须的行为与出处：
///   * 首片 Sequence 0，Fragment_Offset 字段携带 Datagram_Size（§5.1 行 422-427）；
///   * X 必须落在数据报末片（行 613-616），窗口末的中间片可再置 X（行 644-651）；
///   * round-robin：所有片首发完才允许重传任何片；重传按序、最老优先（行 680-685）；
///   * ARQ 由 RTO 保护；带 X 的片超时后按指数退避重传，MaxFragRetries 次耗尽后
///     要么重启（重发带 X 的首片、换新路径，行 621-625）要么放弃（发 reset，§6.3）；
///   * NULL 位图 → 必须放弃（行 838-841）；FULL 位图 / 确认覆盖全数据报 → 完成
///     （§5.1 行 505-508）；
///   * E 位 → 窗口至少减 1、至多减到 1（附录 C 行 1388-1390；本实现减半）；
///   * reset 伪片：offset==0，SHOULD seq/size 也为 0，无 X（§6.3 行 817-820；
///     路径状态由 NULL ACK 自己往回清，行 840-843，所以 NULL 放弃时不再发 reset）。
pub const Sender = struct {
    cfg: SenderConfig,
    /// 压缩形态的数据报（调用方内存；模块不复制）。
    datagram: []const u8,
    /// 本数据报的 Datagram_Tag（注入；RFC 8930 §7 行 476-479 建议伪随机）。
    tag: u8,
    frag_size: u16,
    frag_count: u8,
    state: SenderState = .active,

    sent_first: [max_sequence + 1]bool = @splat(false),
    acked: [max_sequence + 1]bool = @splat(false),
    /// 确认位图报告丢失、待重传（重传发出后清零）。
    needs_retry: [max_sequence + 1]bool = @splat(false),
    /// 每片已因缺片重传的次数（MaxFragRetries 上限）。
    retries: [max_sequence + 1]u8 = @splat(0),

    highest_sent: u8 = 0,
    /// 已发未确认（行 597-600）。
    outstanding: u8 = 0,
    /// 当前窗口（ECN 会减）。
    window: u8,
    /// 重启后的首片强制带 X（行 621-625）。
    force_x: bool = false,
    abort_requested: bool = false,

    rto_armed: bool = false,
    rto_armed_at: u32 = 0,
    rto_ms: u32 = 0,
    /// 当前窗口内 X 片的 RTO 重传次数（MaxFragRetries 上限）。
    rto_retries: u8 = 0,
    last_x_seq: u8 = 0,
    datagram_retries: u8 = 0,

    /// 帧间空隙的发送闸（8930 行 389-391）：上一帧发出的时刻；`tx_armed`
    /// 表示现在允许立即发（首帧或空隙已过）。
    tx_armed: bool = true,
    last_emit_ms: u32 = 0,

    /// 重启时取新 tag 的注入点；null 则沿用旧 tag（§6.1 行 764-768 只对
    /// “首片太大”的场景强制换 tag，RTO 重启不强制）。
    tag_fn: ?*const fn () u8 = null,
    stats: SenderStats = .{},

    /// `datagram` 是压缩形态（§5.1 行 407-409：size/offset 都按压缩形态计）。
    pub fn init(
        datagram: []const u8,
        tag: u8,
        frag_size: u16,
        cfg: SenderConfig,
        tag_fn: ?*const fn () u8,
    ) Error!Sender {
        if (cfg.window_size == 0 or cfg.window_size > 32) return error.BadConfig; // 行 947-948
        // 行 944-945：字节单位 MUST < 512（这也盖住 10 位字段的 1023 上限）。
        if (frag_size == 0 or frag_size >= 512) return error.BadConfig;
        if (cfg.min_arq_timeout_ms == 0) return error.BadConfig;
        if (cfg.opt_arq_timeout_ms < cfg.min_arq_timeout_ms or
            cfg.opt_arq_timeout_ms > cfg.max_arq_timeout_ms) return error.BadConfig; // 行 969-981
        if (datagram.len == 0) return error.EmptyDatagram;
        if (datagram.len > max_datagram_size) return error.TooLong;
        const count = (datagram.len + frag_size - 1) / frag_size;
        if (count > max_sequence + 1) return error.TooManyFragments; // 行 1327-1329
        return .{
            .cfg = cfg,
            .datagram = datagram,
            .tag = tag,
            .frag_size = frag_size,
            .frag_count = @intCast(count),
            .window = cfg.window_size,
            .rto_ms = cfg.opt_arq_timeout_ms,
            .tag_fn = tag_fn,
        };
    }

    /// 推进状态机：产出一帧、或报告等待 / 完成 / 放弃。时间由 `now_ms` 注入。
    pub fn poll(self: *Sender, out: []u8, now_ms: u32) Error!Outcome {
        switch (self.state) {
            .complete => return .complete,
            .aborted => return .aborted,
            .active => {},
        }
        // 帧间空隙（8930 行 389-391 MUST；8931 §4.2 / §7.1 行 911-918）：任何
        // 发送——首发、缺片重传、RTO 重传——都必须与上一帧隔开 gap_ms。
        // 被挡住时 RTO 照常武装，空隙一过就推进。
        if (!self.tx_armed and now_ms -% self.last_emit_ms < self.cfg.gap_ms) {
            if (self.outstanding > 0 and !self.rto_armed) {
                self.rto_armed = true;
                self.rto_armed_at = now_ms;
                self.rto_ms = self.cfg.opt_arq_timeout_ms;
            }
            return .wait;
        }
        // RTO（行 618-625）：X 片超时 → 指数退避重传；耗尽 → 重启或放弃。
        if (self.rto_armed and now_ms -% self.rto_armed_at >= self.rto_ms) {
            self.stats.rto_timeouts += 1;
            if (self.rto_retries < self.cfg.max_frag_retries) {
                self.rto_retries += 1;
                self.rto_ms = @min(self.rto_ms * 2, self.cfg.max_arq_timeout_ms);
                if (self.rto_ms < self.cfg.min_arq_timeout_ms) self.rto_ms = self.cfg.min_arq_timeout_ms;
                const n = try self.emitFragment(out, self.last_x_seq, true, now_ms);
                self.stats.rto_retransmits += 1;
                return .{ .frame = n };
            }
            self.rto_armed = false;
            if (self.datagram_retries < self.cfg.max_datagram_retries) {
                self.restart();
            } else {
                return self.emitReset(out);
            }
        }
        if (self.abort_requested) return self.emitReset(out);
        // 首发优先（行 680-682：所有片首发完才允许重传任何片）。
        if (self.highest_sent < self.frag_count and self.outstanding < self.window) {
            const s = self.highest_sent;
            const x = self.force_x or s == self.frag_count - 1 or !self.hasSendableAfter(true);
            self.force_x = false;
            self.highest_sent += 1;
            self.outstanding += 1;
            self.sent_first[s] = true;
            const n = try self.emitFragment(out, s, x, now_ms);
            return .{ .frame = n };
        }
        // 缺片重传（行 683-685：按序、最老优先）。
        if (self.outstanding < self.window) {
            if (self.nextRetry()) |s| {
                if (self.retries[s] >= self.cfg.max_frag_retries) return self.emitReset(out);
                // 先把这一片移出待重传集，X 的 lookahead 才不会把它自己算成
                // “还有下一帧可发”。
                self.needs_retry[s] = false;
                self.retries[s] += 1;
                const x = !self.hasSendableAfter(false);
                const n = try self.emitFragment(out, s, x, now_ms);
                self.stats.frag_retries += 1;
                return .{ .frame = n };
            }
        }
        // 没帧可发但在途：必须保证 RTO 在走，否则没人再推进度（行 618-619）。
        if (self.outstanding > 0 and !self.rto_armed) {
            self.rto_armed = true;
            self.rto_armed_at = now_ms;
            self.rto_ms = self.cfg.opt_arq_timeout_ms;
        }
        return .wait;
    }

    /// 喂一帧 RFRAG-ACK。格式错误按错误返回；tag 不符或不在传输中的 ACK 静默忽略。
    pub fn onAck(self: *Sender, frame: []const u8, now_ms: u32) Error!void {
        _ = now_ms;
        const a = try RfragAck.decode(frame);
        if (self.state != .active or a.tag != self.tag) {
            self.stats.acks_dropped += 1;
            return;
        }
        self.stats.acks += 1;
        self.rto_armed = false;
        // ECN Echo（附录 C 行 1388-1402）：窗口至少减 1、至多减到 1；逐数据报生效。
        if (a.e and self.cfg.use_ecn) {
            self.window = @max(1, self.window / 2);
            self.stats.ecn_events += 1;
        }
        if (a.bitmap == bitmap_null) {
            // 行 838-841：NULL 位图 → 必须放弃。路径状态由这个 ACK 自己往回清
            // （行 840-843），所以不再补发 reset。
            self.state = .aborted;
            self.stats.aborts += 1;
            return;
        }
        if (a.bitmap == bitmap_full) {
            self.markAllAcked();
            self.state = .complete;
            self.stats.completes += 1;
            return;
        }
        for (0..self.frag_count) |s| {
            if (bitmapGet(a.bitmap, @intCast(s))) {
                self.acked[s] = true;
                self.needs_retry[s] = false;
            } else if (self.sent_first[s] and !self.acked[s]) {
                self.needs_retry[s] = true;
            }
        }
        // outstanding = 已发未确认（行 597-600）：确认一到就缩窗。
        var out_count: u8 = 0;
        for (self.sent_first[0..self.highest_sent], 0..) |st, s| {
            if (st and !self.acked[s]) out_count += 1;
        }
        self.outstanding = out_count;
        // §5.1 行 505-508：确认覆盖整个数据报即完成（FULL 位图蕴含它）。
        var all = true;
        for (self.acked[0..self.frag_count]) |v| if (!v) {
            all = false;
        };
        if (all) {
            self.state = .complete;
            self.stats.completes += 1;
        }
    }

    /// 调用方主动放弃：下一次 poll 产出 reset 伪片（§6.3 行 822-824）。
    pub fn abort(self: *Sender) void {
        if (self.state == .active) self.abort_requested = true;
    }

    fn markAllAcked(self: *Sender) void {
        for (0..self.frag_count) |s| {
            self.acked[s] = true;
            self.needs_retry[s] = false;
        }
    }

    /// 行 621-625：重启 = 从头再来一次（MaxDatagramRetries 上限），重发带 X 的首片。
    fn restart(self: *Sender) void {
        self.datagram_retries += 1;
        self.stats.restarts += 1;
        if (self.tag_fn) |f| self.tag = f();
        self.highest_sent = 0;
        self.outstanding = 0;
        self.rto_retries = 0;
        self.rto_ms = self.cfg.opt_arq_timeout_ms;
        self.force_x = true;
        @memset(&self.sent_first, false);
        @memset(&self.acked, false);
        @memset(&self.needs_retry, false);
        @memset(&self.retries, 0);
    }

    fn nextRetry(self: *const Sender) ?u8 {
        for (self.needs_retry[0..self.highest_sent], 0..) |nr, s| {
            if (nr) return @intCast(s);
        }
        return null;
    }

    /// 刚发完一帧之后，按当前窗口门还有没有下一帧可发（首发 / 重传同一扇门）。
    /// `is_new`：刚发的是首发——用假想的发送后状态判断（窗口门以更新后的
    /// outstanding 计）。
    fn hasSendableAfter(self: *const Sender, is_new: bool) bool {
        var hs = self.highest_sent;
        var o = self.outstanding;
        if (is_new) {
            hs += 1;
            o += 1;
        }
        if (hs < self.frag_count and o < self.window) return true;
        // 还有新片但被窗口门挡住：重传过同一扇门，也没有可发的。
        if (hs < self.frag_count) return false;
        if (o >= self.window) return false;
        for (self.needs_retry[0..hs]) |nr| {
            if (nr) return true;
        }
        return false;
    }

    fn emitFragment(self: *Sender, out: []u8, seq: u8, x: bool, now_ms: u32) Error!usize {
        const start: u32 = @as(u32, seq) * self.frag_size;
        const end: u32 = @min(start + self.frag_size, @as(u32, @intCast(self.datagram.len)));
        const payload = self.datagram[start..end];
        if (out.len < rfrag_header_len + payload.len) return error.NoSpace;
        const offset: u16 = if (seq == 0)
            @intCast(self.datagram.len) // 首片：offset 字段 = Datagram_Size（行 465-469）
        else
            @intCast(start);
        const n = try (RfragHeader{
            .x = x,
            .e = false, // 行 445-447：E 位由源清零
            .seq = seq,
            .size = @intCast(payload.len),
            .offset = offset,
            .tag = self.tag,
        }).encode(out);
        @memcpy(out[n..][0..payload.len], payload);
        if (x) {
            // 全新武装（前一个窗口已被确认）把 RTO 复位到 OptARQTimeOut；
            // RTO 重传路径已经在退避中，保持翻倍后的值（行 618-625）。
            const fresh = !self.rto_armed;
            self.last_x_seq = seq;
            self.rto_armed = true;
            self.rto_armed_at = now_ms;
            if (fresh) self.rto_ms = self.cfg.opt_arq_timeout_ms;
        }
        self.tx_armed = false;
        self.last_emit_ms = now_ms;
        self.stats.frames_sent += 1;
        return n + payload.len;
    }

    /// §6.3 行 817-820：reset 伪片，offset==0，SHOULD seq/size==0；不带 X（选择：
    /// 放弃是单边的，路径状态由各跳的 inactivity 定时器兜底）。
    fn emitReset(self: *Sender, out: []u8) Error!Outcome {
        const n = try (RfragHeader{
            .x = false,
            .e = false,
            .seq = 0,
            .size = 0,
            .offset = 0,
            .tag = self.tag,
        }).encode(out);
        self.state = .aborted;
        self.stats.aborts += 1;
        self.stats.resets_sent += 1;
        return .{ .frame = n };
    }
};

// ---------------------------------------------------------------------------
// 接收方（reassembling endpoint，RFC 8931 §6 行 605-672）
// ---------------------------------------------------------------------------

/// 内部位图助手：重组覆盖按字节跟踪（RFC 8931 的偏移是字节粒度，不像 RFC 4944
/// 按 8 字节计），每字节一位、字节内 MSB 在前。
fn bitTest(have: []const u8, i: usize) bool {
    return (have[i >> 3] >> @intCast(7 - (i & 7))) & 1 != 0;
}

fn bitSet(have: []u8, i: usize) void {
    have[i >> 3] |= @as(u8, 1) << @intCast(7 - (i & 7));
}

fn rangeAll(have: []const u8, from: usize, to: usize) bool {
    for (from..to) |i| {
        if (!bitTest(have, i)) return false;
    }
    return true;
}

/// 接收方状态机（RFC 8931 §6 行 605-672）。
///
/// 必须的行为与出处：
///   * 按（发送方链路层地址、tag）建会话（RFC 8930 §3 行 165-172）；缺口按字节
///     跟踪，重叠片允许（§5.1 行 497-501；§6.1.2 行 769-772）；
///   * 位置与 Sequence / 到达顺序都不相关（§5.1 行 417-421），所以位图按
///     收到的 Sequence 记、完成按字节覆盖判（行 422-427）；
///   * 收到带 X 的片必须回 ACK（行 605-609）；前方的片还缺时可延迟确认
///     （行 669-672，可配置、默认关）；
///   * 覆盖全数据报 → 重组完成、回 FULL 位图、开吸收窗；窗内迟到片不再建状态、
///     带 X 就回 FULL（行 653-664）；吸收窗过了还在来 → 放弃通信（回 NULL）；
///   * E 位必须至多回显一次（行 637-640）；
///   * offset==0 的 reset 伪片 → 清掉全部资源；带 X 就回 NULL 位图（行 830-833）；
///   * 缓冲不够（表满）→ 回 NULL 位图放弃（行 833-836）；
///   * 重组超时（§7 行 898-900，分钟量级）→ 丢弃半成品。
///
/// 与原文的偏差（有意）：孤儿后续片（首片丢了）静默丢弃、不回 NULL——NULL 语义是
/// “放弃”，而发送方 RTO 重启仍可能救回这条数据报；吸收窗过期后的孤儿片由
/// `expired` 槽位回 NULL（行 662-664 的“放弃通信”）。
pub fn Receiver(comptime slots: usize, comptime max_datagram: usize) type {
    if (slots == 0) @compileError("Receiver: slots 必须大于 0");
    if (max_datagram == 0 or max_datagram > max_datagram_size)
        @compileError("Receiver: max_datagram 必须在 1..=2048");
    return struct {
        const Self = @This();
        const have_bytes = (max_datagram + 7) / 8;

        pub const Config = struct {
            /// 重组超时（§7 行 898-900；RFC 4944 行 685 的 60 s 作缺省锚点）。
            reassembly_timeout_ms: u32 = 60_000,
            /// FULL 之后的吸收窗（§6 行 653-657：量级为平均 RTT）。
            absorb_ms: u32 = 500,
            /// 延迟确认（行 669-672：可配置、默认不启用）。
            delay_ack: bool = false,
            ack_delay_ms: u32 = 20,
        };

        pub const Stats = struct {
            completed: u32 = 0,
            acks_sent: u32 = 0,
            delayed_acks: u32 = 0,
            absorb_acks: u32 = 0,
            null_acks: u32 = 0,
            table_full_aborts: u32 = 0,
            expired: u32 = 0,
            orphans_dropped: u32 = 0,
            rejected: u32 = 0,
            duplicates: u32 = 0,
            resets_cleaned: u32 = 0,
        };

        const Phase = enum { reassembling, absorb, expired };

        const Slot = struct {
            used: bool = false,
            peer: f15.Addr = .{ .short = 0 },
            tag: u8 = 0,
            /// Datagram_Size（压缩形态，来自首片，行 465-469）。
            size: u16 = 0,
            phase: Phase = .reassembling,
            started_ms: u32 = 0,
            absorb_set_ms: u32 = 0,
            expired_at_ms: u32 = 0,
            /// 已收到的最高字节端（延迟确认的判据用）。
            high_water: u16 = 0,
            /// [0, size) 内已收到的字节数；== size 即完成。
            filled: u16 = 0,
            ecn_pending: bool = false,
            ack_pending: bool = false,
            ack_set_ms: u32 = 0,
            /// 按收到帧的 Sequence 记位图（位置无关，行 417-421）。
            seq_seen: [max_sequence + 1]bool = @splat(false),
            buf: [max_datagram]u8 = undefined,
            have: [have_bytes]u8 = @splat(0),
        };

        pub const RxEvent = union(enum) {
            waiting,
            /// 重组完成：数据报已复制到 out[0..len]，ack 是要回给对端的 FULL。
            complete: struct { len: u16, ack: RfragAck },
            /// 要回给对端的 ACK（位图 / NULL / 吸收窗内的 FULL）。
            ack: RfragAck,
            /// 语义拒绝（结构错误用 error 返回）。
            dropped: Error,
        };

        slots: [slots]Slot = @splat(.{}),
        config: Config = .{},
        stats: Stats = .{},

        pub fn onFrame(self: *Self, frame: []const u8, peer: f15.Addr, out: []u8, now_ms: u32) Error!RxEvent {
            const d = try RfragHeader.decode(frame);
            const h = d.header;
            if (h.offset == 0) return self.onReset(peer, h, now_ms);
            if (h.seq == 0) return self.onFirst(peer, h, d.payload, out, now_ms);
            return self.onNext(peer, h, d.payload, out, now_ms);
        }

        /// 推进定时器：重组超时（§7 行 898-900）、吸收窗到期、延迟确认到期。
        /// 一次至多返回一条到期应发的 ACK（多条时再调一次）。
        pub fn tick(self: *Self, now_ms: u32) ?RfragAck {
            for (&self.slots) |*s| {
                if (s.used and s.phase == .reassembling and s.ack_pending and
                    now_ms -% s.ack_set_ms >= self.config.ack_delay_ms)
                {
                    s.ack_pending = false;
                    self.stats.acks_sent += 1;
                    return mkAck(s, true, false);
                }
            }
            for (&self.slots) |*s| {
                if (!s.used) continue;
                switch (s.phase) {
                    .reassembling => {
                        if (now_ms -% s.started_ms >= self.config.reassembly_timeout_ms) {
                            s.used = false;
                            self.stats.expired += 1;
                        }
                    },
                    .absorb => {
                        if (now_ms -% s.absorb_set_ms >= self.config.absorb_ms) {
                            s.phase = .expired;
                            s.expired_at_ms = now_ms;
                        }
                    },
                    .expired => {
                        if (now_ms -% s.expired_at_ms >= self.config.reassembly_timeout_ms) {
                            s.used = false;
                        }
                    },
                }
            }
            return null;
        }

        pub fn inProgress(self: *const Self) usize {
            var n: usize = 0;
            for (&self.slots) |*s| {
                if (s.used and s.phase == .reassembling) n += 1;
            }
            return n;
        }

        fn findSlot(self: *Self, peer: f15.Addr, tag: u8) ?*Slot {
            for (&self.slots) |*s| {
                if (s.used and s.tag == tag and f15.addrEql(s.peer, peer)) return s;
            }
            return null;
        }

        /// offset==0 的 reset 伪片（§6.3 行 830-833）：清资源；带 X 回 NULL。
        fn onReset(self: *Self, peer: f15.Addr, h: RfragHeader, now_ms: u32) Error!RxEvent {
            _ = now_ms;
            var echo = false;
            if (self.findSlot(peer, h.tag)) |s| {
                echo = s.ecn_pending;
                s.used = false;
                self.stats.resets_cleaned += 1;
            }
            if (h.x) {
                self.stats.null_acks += 1;
                return .{ .ack = .{ .e = echo, .tag = h.tag, .bitmap = bitmap_null } };
            }
            return .waiting;
        }

        fn onFirst(self: *Self, peer: f15.Addr, h: RfragHeader, payload: []const u8, out: []u8, now_ms: u32) Error!RxEvent {
            if (payload.len == 0 or payload.len > h.offset) {
                // 声明比数据报还长的片是坏的（重组时必留洞）。
                self.stats.rejected += 1;
                return .{ .dropped = if (payload.len == 0) error.BadFragmentSize else error.BadOffset };
            }
            if (self.findSlot(peer, h.tag)) |s| {
                switch (s.phase) {
                    // 吸收窗内重到的首片：FULL ACK 丢了、发送方在重启（行 655-664）。
                    .absorb => {
                        if (h.x) {
                            self.stats.absorb_acks += 1;
                            return .{ .ack = mkAck(s, true, true) };
                        }
                        return .waiting;
                    },
                    .expired => {
                        // 行 662-664：超时后还在来 → 放弃通信。
                        if (h.x) {
                            s.used = false;
                            self.stats.null_acks += 1;
                            return .{ .ack = .{ .e = false, .tag = h.tag, .bitmap = bitmap_null } };
                        }
                        return .waiting;
                    },
                    .reassembling => self.resetSlot(s, peer, h, now_ms),
                }
            } else {
                const s = self.allocSlot(peer, h, now_ms) orelse {
                    // 行 833-836：缓冲不够 → NULL 位图放弃。
                    self.stats.table_full_aborts += 1;
                    self.stats.null_acks += 1;
                    return .{ .ack = .{ .e = false, .tag = h.tag, .bitmap = bitmap_null } };
                };
                return self.acceptAndCheck(s, h, payload, out, now_ms);
            }
            return self.acceptAndCheck(self.findSlot(peer, h.tag).?, h, payload, out, now_ms);
        }

        fn onNext(self: *Self, peer: f15.Addr, h: RfragHeader, payload: []const u8, out: []u8, now_ms: u32) Error!RxEvent {
            const s = self.findSlot(peer, h.tag) orelse {
                // 首片丢了：静默丢（无状态可装；NULL 语义是“放弃”，会错杀
                // 发送方的 RTO 重启）。
                self.stats.orphans_dropped += 1;
                return .waiting;
            };
            switch (s.phase) {
                .absorb => {
                    // 行 655-664：窗内迟到片不建新状态；带 X 回 FULL。
                    if (h.x) {
                        self.stats.absorb_acks += 1;
                        return .{ .ack = mkAck(s, true, true) };
                    }
                    return .waiting;
                },
                .expired => {
                    if (h.x) {
                        s.used = false;
                        self.stats.null_acks += 1;
                        return .{ .ack = .{ .e = false, .tag = h.tag, .bitmap = bitmap_null } };
                    }
                    return .waiting;
                },
                .reassembling => {
                    // 偏移越出首片声明的长度：坏片，丢了不等它（负例判据）。
                    if (payload.len == 0 or @as(u32, h.offset) + payload.len > s.size) {
                        self.stats.rejected += 1;
                        return .{ .dropped = if (payload.len == 0) error.BadFragmentSize else error.BadOffset };
                    }
                    return self.acceptAndCheck(s, h, payload, out, now_ms);
                },
            }
        }

        fn allocSlot(self: *Self, peer: f15.Addr, h: RfragHeader, now_ms: u32) ?*Slot {
            for (&self.slots) |*s| {
                if (!s.used) {
                    self.resetSlot(s, peer, h, now_ms);
                    return s;
                }
            }
            return null;
        }

        fn resetSlot(self: *Self, s: *Slot, peer: f15.Addr, h: RfragHeader, now_ms: u32) void {
            _ = self;
            s.* = .{
                .used = true,
                .peer = peer,
                .tag = h.tag,
                .size = h.offset, // 首片的 offset 字段 = Datagram_Size（行 465-469）
                .started_ms = now_ms,
            };
        }

        fn acceptAndCheck(self: *Self, s: *Slot, h: RfragHeader, payload: []const u8, out: []u8, now_ms: u32) Error!RxEvent {
            // 存字节、记覆盖与位图；重叠片允许（行 497-501 / 769-772）。
            var new_bytes: usize = 0;
            const off: usize = if (h.seq == 0) 0 else h.offset;
            for (payload, 0..) |b, i| {
                const idx = off + i;
                if (!bitTest(&s.have, idx)) {
                    bitSet(&s.have, idx);
                    s.buf[idx] = b;
                    new_bytes += 1;
                }
            }
            s.filled += @intCast(new_bytes);
            s.high_water = @max(s.high_water, @as(u16, @intCast(off + payload.len)));
            if (new_bytes == 0) self.stats.duplicates += 1;
            s.seq_seen[h.seq] = true;
            if (h.e) s.ecn_pending = true; // 行 637-640：至多回显一次

            if (s.filled == s.size) {
                // 行 422-427 / 653-657：覆盖全数据报 → 完成、回 FULL、开吸收窗。
                if (out.len < s.size) return error.NoSpace;
                const size = s.size;
                @memcpy(out[0..size], s.buf[0..size]);
                s.phase = .absorb;
                s.absorb_set_ms = now_ms;
                s.ack_pending = false;
                self.stats.completed += 1;
                // 行 655-657：完成后的 ACK 用 FULL 位图，让中间节点明确知道
                // 数据报收全了（不逐位对账）。
                return .{ .complete = .{ .len = size, .ack = mkAck(s, true, true) } };
            }
            if (h.x) {
                // 行 605-609：必须确认。行 669-672：前方还有洞时可延迟（默认关）。
                if (self.config.delay_ack and s.filled < s.high_water and
                    !rangeAll(&s.have, 0, s.high_water))
                {
                    if (!s.ack_pending) {
                        s.ack_pending = true;
                        s.ack_set_ms = now_ms;
                        self.stats.delayed_acks += 1;
                    }
                    return .waiting;
                }
                self.stats.acks_sent += 1;
                return .{ .ack = mkAck(s, true, false) };
            }
            return .waiting;
        }

        /// 组一条回给上一跳的 RFRAG-ACK。完成 / 吸收窗的 ACK 用 FULL 位图
        /// （行 655-657 / 659-664：让中间节点明确知道数据报收全了）。
        fn mkAck(s: *Slot, consume_ecn: bool, force_full: bool) RfragAck {
            var bm: u32 = bitmap_null;
            for (s.seq_seen, 0..) |seen, sq| {
                if (seen) bm = bitmapSet(bm, @intCast(sq));
            }
            if (force_full) bm = bitmap_full;
            const e = s.ecn_pending and consume_ecn;
            if (consume_ecn) s.ecn_pending = false;
            return .{ .e = e, .tag = s.tag, .bitmap = bm };
        }
    };
}

// ---------------------------------------------------------------------------
// 转发方（中间路由器，RFC 8930 §5/§6 + RFC 8931 §6.1–6.3）
// ---------------------------------------------------------------------------

/// VRB 转发方（RFC 8930 §6 行 395-430；RFC 8931 §6.1-6.3）。
///
/// 必须的行为与出处：
///   * 首片（seq 0）：建状态 + 转发是原子操作，转发失败状态必须撤掉
///     （8930 行 325-331）；按（入接口、上一跳链路层地址、tag）建前向 LSP，
///     按（出接口、自己作为源用的地址、换掉的 tag）建反向 LSP（8931 行 725-740）；
///   * 每跳必须用自己命名空间的新 tag 重写每一片的头（8930 行 333-343）；
///   * 后续片：查前向 LSP，查到就按状态转发，查不到就构造 NULL abort RFRAG-ACK
///     （地址互换、tag 用收到的、NULL 位图，8931 行 747-767）；
///   * 首片改长时把 Datagram_Size 改回来、差值存 VRB 并加到后续片的 offset
///     （8931 §4.4 行 356-363）；reset 伪片的 offset 保持 0；
///   * ACK：查反向 LSP，查不到静默丢（行 786-787）；FULL 武装短定时器，
///     到期销毁 VRB；窗内迟到片带 X 回 FULL、不带 X 静默丢（行 791-797）；
///     NULL → 转发后销毁全部状态（行 840-843）；
///   * reset 伪片：有 VRB 就按 LSP 转发（不看 Sequence）；不带 X 转发后销毁，
///     带 X 等反向 NULL 回来再销毁（§6.3 行 826-828）；
///   * VRB 表满 → 丢包（8930 行 415-418），原子性由“先写帧后装状态”保证；
///   * tag 必须对数据报生命周期唯一（8930 行 379-384）→ 冲突按 TagInUse 拒绝；
///   * 定时器：FULL 短定时器 + inactivity 兜底（8930 行 356-360 / 484-486）。
pub fn Forwarder(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Forwarder: capacity 必须大于 0");
    return struct {
        const Self = @This();

        pub const Config = struct {
            /// 无活动状态多久销毁（8930 §5 行 356-360：应长于接收端重组覆盖的时间）。
            inactivity_timeout_ms: u32 = 120_000,
            /// FULL 之后吸收窗的时长（8931 行 655-657：量级为平均 RTT）。
            full_timer_ms: u32 = 1_000,
        };

        pub const NextHop = struct {
            iface: u8,
            addr: f15.Addr,
        };

        /// 首片的转发参数。真实路由查找不在本模块（非目标），下一跳由调用方给出；
        /// tag / 源地址由调用方注入（伪随机）。
        pub const Args = struct {
            next_hop: ?NextHop = null,
            /// 本机为下一跳命名空间分配的新 tag（8930 行 333-338）。
            out_tag: u8 = 0,
            /// 本机在出接口上作为链路层源用的地址（反向 LSP 索引，8931 行 736-740）。
            src_addr: f15.Addr = .{ .short = 0 },
            /// 首片压缩形态的长度变化（SRH-6LoRH 消耗为负，§4.4 行 356-363）。
            size_delta: i16 = 0,
            /// 本跳经历拥塞 → 置 E 位（§5.1 行 445-447）。
            congestion: bool = false,
            /// 缺省转发入帧载荷；SRH 消耗后由调用方给裁剪过的载荷。
            payload: ?[]const u8 = null,
        };

        pub const Verdict = union(enum) {
            /// out 里是转发帧（头已重写），发给首片的 next_hop / ACK 反向下一跳。
            forwarded: usize,
            /// out 里是生成的 RFRAG-ACK（NULL abort 或迟到 FULL），发回上一跳。
            to_prev_hop: usize,
            /// 静默丢弃（8931 行 786-787；8930 行 415-418 表满）。
            dropped,
        };

        pub const Stats = struct {
            first_installed: u32 = 0,
            forwarded: u32 = 0,
            cleanup_forwarded: u32 = 0,
            abort_acks: u32 = 0,
            late_full_acks: u32 = 0,
            late_dropped: u32 = 0,
            acks_forwarded: u32 = 0,
            acks_dropped: u32 = 0,
            full_armed: u32 = 0,
            vrb_full_drops: u32 = 0,
            destroyed_inactive: u32 = 0,
            destroyed_full_timer: u32 = 0,
            destroyed_null: u32 = 0,
            destroyed_no_ack: u32 = 0,
        };

        const Entry = struct {
            used: bool = false,
            // 前向 LSP：索引（8931 行 725-730）
            in_iface: u8 = 0,
            peer: f15.Addr = .{ .short = 0 },
            in_tag: u8 = 0,
            // 前向 LSP：输出（8930 §5 行 346-356）
            out_iface: u8 = 0,
            next_hop: f15.Addr = .{ .short = 0 },
            out_tag: u8 = 0,
            // 反向 LSP 索引需要的本机源地址（8931 行 736-740）
            own_src: f15.Addr = .{ .short = 0 },
            // §4.4：首片长度差值，加到后续片的 offset 上（行 356-363）
            size_delta: i16 = 0,
            touched_ms: u32 = 0,
            full_seen: bool = false,
            full_at_ms: u32 = 0,
        };

        entries: [capacity]Entry = @splat(.{}),
        config: Config = .{},
        stats: Stats = .{},

        pub fn onRfrag(
            self: *Self,
            in_iface: u8,
            peer: f15.Addr,
            frame: []const u8,
            out: []u8,
            args: Args,
            now_ms: u32,
        ) Error!Verdict {
            const d = try RfragHeader.decode(frame);
            const h = d.header;
            // 首片（seq 0 且 offset>0）：路由决策在这里（8930 §5 行 321-331）。
            if (h.seq == 0 and h.offset > 0) return self.forwardFirst(in_iface, peer, h, args, d.payload, out, now_ms);

            if (self.findForward(in_iface, peer, h.tag)) |e| {
                if (e.full_seen and h.offset != 0) {
                    // 行 791-797：FULL 后窗内迟到片；带 X 回 FULL，否则静默丢。
                    if (h.x) {
                        const n = try (RfragAck{ .e = false, .tag = h.tag, .bitmap = bitmap_full }).encode(out);
                        self.stats.late_full_acks += 1;
                        return .{ .to_prev_hop = n };
                    }
                    self.stats.late_dropped += 1;
                    return .dropped;
                }
                // 有 VRB：按 LSP 转发，不看 Sequence（行 489-491 / §6.3 行 826-828）。
                const out_off: u16 = if (h.offset == 0) 0 else try shiftOffset(h.offset, e.size_delta);
                const n = try writeFrame(out, h.x, h.e or args.congestion, h.seq, h.size, out_off, e.out_tag, args.payload orelse d.payload);
                e.touched_ms = now_ms;
                self.stats.forwarded += 1;
                // reset 且未请求确认：转发后销毁（行 826-828）。
                if (h.offset == 0 and !h.x) self.destroy(e, .no_ack);
                return .{ .forwarded = n };
            }
            // 无 VRB：
            if (h.seq == 0) {
                // seq==0 且 offset==0（行 493-495）：按 6.1.1 路由但不装状态，
                // 把 cleanup 往下游送；tag 不换（会话已中断）。
                const nh = args.next_hop orelse return error.NoRoute;
                _ = nh;
                const n = try writeFrame(out, h.x, h.e, h.seq, h.size, 0, h.tag, args.payload orelse d.payload);
                self.stats.cleanup_forwarded += 1;
                return .{ .forwarded = n };
            }
            // seq!=0 无 VRB（行 747-767 / 489-495）：丢片 + 回 NULL abort。
            const n = try (RfragAck{ .e = false, .tag = h.tag, .bitmap = bitmap_null }).encode(out);
            self.stats.abort_acks += 1;
            return .{ .to_prev_hop = n };
        }

        /// ACK 走反向 LSP（§6.2 行 780-797）：按（入接口、帧的链路层目的地址、tag）查。
        pub fn onAck(
            self: *Self,
            in_iface: u8,
            dst: f15.Addr,
            frame: []const u8,
            out: []u8,
            now_ms: u32,
        ) Error!Verdict {
            const a = try RfragAck.decode(frame);
            var found: ?*Entry = null;
            for (&self.entries) |*e| {
                if (e.used and e.out_iface == in_iface and e.out_tag == a.tag and
                    f15.addrEql(e.own_src, dst))
                {
                    found = e;
                    break;
                }
            }
            const e = found orelse {
                self.stats.acks_dropped += 1;
                return .dropped; // 行 786-787：查不到反向 LSP 静默丢
            };
            const n = try (RfragAck{ .e = a.e, .tag = e.in_tag, .bitmap = a.bitmap }).encode(out);
            e.touched_ms = now_ms;
            if (a.bitmap == bitmap_null) {
                self.destroy(e, .null_ack); // 行 840-843：NULL 清理整条路径
            } else if (a.bitmap == bitmap_full) {
                e.full_seen = true; // 行 791-793：FULL → 武装短定时器
                e.full_at_ms = now_ms;
                self.stats.full_armed += 1;
            }
            self.stats.acks_forwarded += 1;
            return .{ .forwarded = n };
        }

        /// FULL 短定时器到期销毁（行 792-793）；inactivity 兜底销毁（8930 行 356-360）。
        pub fn tick(self: *Self, now_ms: u32) void {
            for (&self.entries) |*e| {
                if (!e.used) continue;
                if (e.full_seen and now_ms -% e.full_at_ms >= self.config.full_timer_ms) {
                    self.destroy(e, .full_timer);
                } else if (now_ms -% e.touched_ms >= self.config.inactivity_timeout_ms) {
                    self.destroy(e, .inactive);
                }
            }
        }

        pub fn inUse(self: *const Self) usize {
            var n: usize = 0;
            for (&self.entries) |*e| {
                if (e.used) n += 1;
            }
            return n;
        }

        const DestroyReason = enum { inactive, full_timer, null_ack, no_ack };

        fn destroy(self: *Self, e: *Entry, reason: DestroyReason) void {
            e.used = false;
            switch (reason) {
                .inactive => self.stats.destroyed_inactive += 1,
                .full_timer => self.stats.destroyed_full_timer += 1,
                .null_ack => self.stats.destroyed_null += 1,
                .no_ack => self.stats.destroyed_no_ack += 1,
            }
        }

        fn findForward(self: *Self, iface: u8, peer: f15.Addr, tag: u8) ?*Entry {
            for (&self.entries) |*e| {
                if (e.used and e.in_iface == iface and e.in_tag == tag and
                    f15.addrEql(e.peer, peer)) return e;
            }
            return null;
        }

        fn forwardFirst(
            self: *Self,
            in_iface: u8,
            peer: f15.Addr,
            h: RfragHeader,
            args: Args,
            payload_in: []const u8,
            out: []u8,
            now_ms: u32,
        ) Error!Verdict {
            const nh = args.next_hop orelse return error.NoRoute;
            // §4.4 行 356-358：首片改长必须同步改 Datagram_Size。
            const out_size = try shiftOffset(h.offset, args.size_delta);
            var slot: ?*Entry = self.findForward(in_iface, peer, h.tag);
            if (slot == null) {
                for (&self.entries) |*e| {
                    if (!e.used) {
                        slot = e;
                        break;
                    }
                }
                if (slot == null) {
                    // 8930 行 415-418：表满只能丢包（原子：状态未装）。
                    self.stats.vrb_full_drops += 1;
                    return .dropped;
                }
            }
            const e = slot.?;
            // 8930 行 379-384 / 8931 行 380-389：tag 对生命周期必须唯一。
            for (&self.entries) |*o| {
                if (o.used and o != e and o.out_tag == args.out_tag) return error.TagInUse;
            }
            // 先写帧、后装状态（8930 行 325-331 的原子性）。
            const n = try writeFrame(out, h.x, h.e or args.congestion, h.seq, h.size, out_size, args.out_tag, args.payload orelse payload_in);
            e.* = .{
                .used = true,
                .in_iface = in_iface,
                .peer = peer,
                .in_tag = h.tag,
                .out_iface = nh.iface,
                .next_hop = nh.addr,
                .own_src = args.src_addr,
                .out_tag = args.out_tag,
                .size_delta = args.size_delta,
                .touched_ms = now_ms,
            };
            self.stats.first_installed += 1;
            return .{ .forwarded = n };
        }

        fn writeFrame(
            out: []u8,
            x: bool,
            e: bool,
            seq: u8,
            size: u16,
            offset: u16,
            tag: u8,
            payload: []const u8,
        ) Error!usize {
            if (out.len < rfrag_header_len + payload.len) return error.NoSpace;
            const n = try (RfragHeader{
                .x = x,
                .e = e,
                .seq = seq,
                .size = size,
                .offset = offset,
                .tag = tag,
            }).encode(out);
            @memcpy(out[n..][0..payload.len], payload);
            return n + payload.len;
        }
    };
}

/// §4.4 行 356-363：offset / Datagram_Size 加上首片差值，负到小于 0 或超过
/// 2048 都是调用方的错（BadOffset）。
fn shiftOffset(v: u16, delta: i16) Error!u16 {
    const r = @as(i32, v) + delta;
    if (r < 0 or r > max_datagram_size) return error.BadOffset;
    return @intCast(r);
}
