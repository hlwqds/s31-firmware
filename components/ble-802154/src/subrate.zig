//! ble-802154：Connection Subrating（连接子额定）的 host 侧——两条 HCI 命令、LE Subrate
//! Change 事件、LL_SUBRATE_REQ / IND 的编解码，与 §5.1.19 / §5.1.20 两个判决函数
//! （Bluetooth Core 5.4）。
//!
//! 规范出处（都是本次从原文读到的，条款号与原文一致；行号 = `grep -n` 实测）：
//!   * 命令（[Vol 4] Part E）：LE Set Default Subrate §7.8.123（OCF 0x007D，正文
//!     38046 起）、LE Subrate Request §7.8.124（OCF 0x007E，38137 起）；参数范围与
//!     默认值在两节的参数表里；
//!   * 事件（[Vol 4] Part E）：LE Subrate Change §7.7.65.35（子事件码 0x23，正文
//!     26201 起）；LE Set Event Mask 位表里它是 **bit 34**（27232 附近：32 = Transmit
//!     Power Reporting、33 = BIGInfo、34 = Subrate Change、35 = PA Sync Established）；
//!   * 表（3212–3217、3394–3404）与条件注释（4622）：两条命令与事件引入于 5.3，条件
//!     C.57 =「Mandatory if LE Feature (Connection Subrating) is supported, otherwise
//!     excluded」；OGF/OCF 分配表 6919–6922：OGF 46，OCF 0 = Set Default Subrate、
//!     1 = Subrate Request；
//!   * LL（[Vol 6] Part B）：表 2.20（表题注 3460；REQ/IND 行 3440/3443）LL_SUBRATE_REQ = 0x26、
//!     LL_SUBRATE_IND = 0x27；§2.4.2.36（3758）/ §2.4.2.37（3768）两个 PDU 的
//!     CtrData 各五个字段（图 2.54 / 2.55 是图片，字段宽度 2 八位组由独立实现
//!     NimBLE 钉住：`ble_ll_ctrl.h:290-291` 两个 LEN 都是 10，`ble_ll_ctrl.c:1183-1199`
//!     的 put_le16 布局 offset 0/2/4/6/8）；§4.5.1（4783–4799）参数约束与回绕公式；
//!     §4.5.2（4800 起）监督超时；§5.1.19（6196）/ §5.1.20（6207，正文 6208 起）两个判决规则；
//!     §5.2（6235–6238）过程响应超时 T_PRT = 40 s；
//!   * GAP §9.3.16「Connection Subrate procedure」：盘上三个抽取文本里**只有目录条目**
//!     （Core-54-ll.txt:921、Core-54-generic-attribute-profile--gatt-.txt:966），GAP 卷
//!     正文抽取被截断，本文件不引用它的任何具体要求。
//!
//! 独立实现交叉核对（盘上 IDF v6.1 的 NimBLE，行号实测）：
//!   * `include/nimble/hci_common.h:1295/1304` 两个 OCF（0x007D / 0x007E）+ 两个 packed
//!     结构体（5 × uint16 小端）；`:2559` 子事件码 0x23 + 事件结构体 2560–2567。任务书
//!     说“只有一处常量”——实际是三处常量加结构体，另见下面三条；
//!   * `controller/include/controller/ble_ll_ctrl.h:99-100` LL opcode 0x26 / 0x27；
//!   * `controller/src/ble_ll_ctrl.c:1202-1247`（Central 收 REQ：无 Host Support 位 →
//!     LL_REJECT_EXT_IND 0x1A）、`:1249-1298`（Peripheral 收 IND：注释自己引用 spec
//!     “shall accept”，越界时只做重置 factor=1 的自保）；
//!   * `controller/src/ble_ll_conn.c:4196-4266`（§7.8.124 的 0x12 检查；注意 NimBLE 用
//!     `t1 > t2` 判监督超时，spec 原文是「≥ 半个监督超时即拒」，本文件按原文用 ≥）、
//!     `:4267-4310`（§5.1.20 的接受 / 拒绝与结果取值）；
//!   * 已知偏差：新监督超时 NimBLE 取 `min(当前值, 请求值)`，spec §5.1.20 写的是
//!     `min(Timeout_requested, Supervision_Timeout_acceptable)`——本文件按原文。
//!
//! 本文件只有纯逻辑，不驱动射频、不读时钟（一切“现在几点”都是参数）。host 在这里做
//! 五件事：
//!   * 把两条命令编成完整 H4 命令帧（与 `hci_cmd.zig` 同口径），解析返回参数与事件；
//!   * LL_SUBRATE_REQ / IND 的 Opcode+CtrData 编解码（字段合法性按 §2.4.2.36 的
//!     「SubrateFactorMax × (Max_Latency + 1) ≤ 500」与 §4.5.1 的 shall 一起判）；
//!   * `centralVerdict`：§5.1.20 的五个条件 R1–R5 与接受后的四个结果参数；
//!   * `centralIndFromRequest` / `peripheralReqFromRequest`：§7.8.124 里 Central /
//!     Peripheral 各自发起时往 PDU 里放什么；
//!   * `Session`：设缺省值 → 请求 → 收事件 的小模型，带 §5.2 的 40 s 过程超时。
//!
//! 事件与字段里的「All other values: Reserved for future use」不静默接受：解出来按
//! `BadParam` 拒。长度不对 → `Short` / `Trailing`。

const std = @import("std");

const hci = @import("hci.zig");

/// `Short` / `Trailing` / `NoSpace` / `Oversize` 来自 `hci.packCommand` 与解析路径，
/// 含义与 `power_ctrl.zig` 相同。
pub const Error = hci.Error || error{
    /// 取值不在规范允许的范围内（含保留值）。
    BadParam,
    /// 不是本文件解的那个 LE 子事件（0x23）。
    UnknownSubevent,
};

// ---------------------------------------------------------------------------
// OpCode、子事件码、事件掩码与 LL opcode
// ---------------------------------------------------------------------------

/// LE Set Default Subrate。§7.8.123（OCF 0x007D；NimBLE hci_common.h:1295 同值）。
pub const op_le_set_default_subrate: u16 = hci.opcode(hci.ogf_le_controller, 0x007D);
/// LE Subrate Request。§7.8.124（OCF 0x007E；NimBLE hci_common.h:1304 同值）。
pub const op_le_subrate_request: u16 = hci.opcode(hci.ogf_le_controller, 0x007E);

/// LE Meta 子事件码：LE Subrate Change。§7.7.65.35（0x23；NimBLE hci_common.h:2559）。
pub const subevent_subrate_change: u8 = 0x23;

/// LE Set Event Mask 的 bit 34（§7.8.1 位表）。掩码是 8 字节小端的 u64。
pub const le_event_mask_subrate_change: u64 = @as(u64, 1) << 34;

/// LL Control PDU opcode。表 2.20；NimBLE ble_ll_ctrl.h:99-100 同值。
pub const ll_op_subrate_req: u8 = 0x26;
pub const ll_op_subrate_ind: u8 = 0x27;

// ---------------------------------------------------------------------------
// 取值范围（§7.8.123 / §7.8.124 参数表；两个表的五个参数范围完全一致）
// ---------------------------------------------------------------------------

pub const subrate_min_min: u16 = 0x0001;
pub const subrate_factor_max: u16 = 0x01F4; // Subrate_Min / Subrate_Max 的上界
pub const max_latency_max: u16 = 0x01F3;
pub const continuation_number_max: u16 = 0x01F3;
pub const supervision_timeout_min: u16 = 0x000A; // N × 10 ms = 100 ms
pub const supervision_timeout_max: u16 = 0x0C80; // N × 10 ms = 32 s
/// Connection_Handle 只有低 12 位有意义：0x0000–0x0EFF。
pub const handle_max: u16 = 0x0EFF;
/// §2.4.2.36（3764）与 §4.5.1（4794）：factor × (latency + 1) ≤ 500。
pub const product_limit: u16 = 500;
/// §5.2（6238）：过程响应超时 T_PRT = 40 s。
pub const procedure_response_timeout_us: u64 = 40 * std.time.us_per_s;
/// 连接间隔的单位是 1.25 ms（[Vol 6] Part B §4.5.1 connInterval）。
pub const conn_interval_unit_us: u32 = 1250;
/// 监督超时的单位是 10 ms（§7.8.123 / §7.8.124 参数表 “Time = N × 10 ms”）。
pub const supervision_timeout_unit_us: u32 = 10 * std.time.ms_per_s;

/// 五个 Host 可见参数的集合：§7.8.123 / §7.8.124 的命令参数、LL_SUBRATE_REQ 的
/// CtrData 都是这五个。
pub const SubrateParams = struct {
    /// Subrate_Min：允许的最小子额定因子。
    subrate_min: u16,
    /// Subrate_Max：允许的最大子额定因子。
    subrate_max: u16,
    /// Max_Latency：最大 Peripheral latency（单位：子额定连接间隔）。
    max_latency: u16,
    /// Continuation_Number：非空包后保持活跃的底层连接事件数。
    continuation_number: u16,
    /// Supervision_Timeout：监督超时，N × 10 ms。
    supervision_timeout: u16,

    /// 五个字段都是 2 八位组。
    pub const packed_len: usize = 10;

    /// §7.8.123 参数表给的默认值（0x0001 / 0x0001 / 0x0000 / 0x0000 / 0x0C80）。
    pub const default: SubrateParams = .{
        .subrate_min = 0x0001,
        .subrate_max = 0x0001,
        .max_latency = 0x0000,
        .continuation_number = 0x0000,
        .supervision_timeout = 0x0C80,
    };

    pub fn ctrData(self: SubrateParams) [packed_len]u8 {
        var b: [packed_len]u8 = undefined;
        std.mem.writeInt(u16, b[0..2], self.subrate_min, .little);
        std.mem.writeInt(u16, b[2..4], self.subrate_max, .little);
        std.mem.writeInt(u16, b[4..6], self.max_latency, .little);
        std.mem.writeInt(u16, b[6..8], self.continuation_number, .little);
        std.mem.writeInt(u16, b[8..10], self.supervision_timeout, .little);
        return b;
    }
};

/// LL_SUBRATE_IND 的 CtrData（§2.4.2.37）：五个新参数，比 REQ 多了 base event、少了
/// min/max 这一对。
pub const SubrateIndPdu = struct {
    /// 新的 connSubrateFactor。
    subrate_factor: u16,
    /// 新的 connSubrateBaseEvent（§5.1.19：S15-14 = 排队时 connEventCount 的 15-14）。
    subrate_base_event: u16,
    /// 新的 connPeripheralLatency（单位：子额定连接事件）。
    peripheral_latency: u16,
    /// 新的 connContinuationNumber。
    continuation_number: u16,
    /// 新的 connSupervisionTimeout，N × 10 ms。
    supervision_timeout: u16,

    pub const packed_len: usize = 10;

    pub fn ctrData(self: SubrateIndPdu) [packed_len]u8 {
        var b: [packed_len]u8 = undefined;
        std.mem.writeInt(u16, b[0..2], self.subrate_factor, .little);
        std.mem.writeInt(u16, b[2..4], self.subrate_base_event, .little);
        std.mem.writeInt(u16, b[4..6], self.peripheral_latency, .little);
        std.mem.writeInt(u16, b[6..8], self.continuation_number, .little);
        std.mem.writeInt(u16, b[8..10], self.supervision_timeout, .little);
        return b;
    }
};

/// 连接当前的子额定状态（§4.5.1）：新连接 factor = 1、continuation = 0（4789）。
pub const ConnSubrate = struct {
    subrate_factor: u16 = 1,
    subrate_base_event: u16 = 0,
    peripheral_latency: u16 = 0,
    continuation_number: u16 = 0,
    supervision_timeout: u16 = 0x0C80,
};

/// 每个字段各自的越界错误，好让“拒绝的理由”可以断言。范围来自 §7.8.124 参数表。
pub const RangeError = error{
    SubrateMin,
    SubrateMax,
    MaxLatency,
    ContinuationNumber,
    SupervisionTimeout,
};

/// 五个参数逐字段查范围（错误顺序 = 表里的字段顺序）。
pub fn validateParams(p: SubrateParams) RangeError!void {
    if (p.subrate_min < subrate_min_min or p.subrate_min > subrate_factor_max) return error.SubrateMin;
    if (p.subrate_max < subrate_min_min or p.subrate_max > subrate_factor_max) return error.SubrateMax;
    if (p.max_latency > max_latency_max) return error.MaxLatency;
    if (p.continuation_number > continuation_number_max) return error.ContinuationNumber;
    if (p.supervision_timeout < supervision_timeout_min or p.supervision_timeout > supervision_timeout_max) return error.SupervisionTimeout;
}

fn need(buf: []const u8, n: usize) Error!void {
    if (buf.len < n) return error.Short;
    if (buf.len > n) return error.Trailing;
}

fn decodeHandle(bytes: []const u8) Error!u16 {
    const h = std.mem.readInt(u16, bytes[0..2], .little);
    if (h > handle_max) return error.BadParam;
    return h;
}

/// 失败时 controller 可以只回一个 Status；成功却只有 Status 不是本文件的情况
/// （§7.8.123 的成功返回就是 1 个字节）。与 `power_ctrl.zig` 的 `onlyFailure` 同口径。
fn onlyStatus(ret: []const u8) ?u8 {
    if (ret.len == 1) return ret[0];
    return null;
}

// ---------------------------------------------------------------------------
// §7.8.124 的命令级检查（回 0x12 的四条 + 范围）
// ---------------------------------------------------------------------------

/// §7.8.124 命令的检查。四条 0x12 之间的先后规范没有规定（同时违规时报哪条是实现
/// 自由），这里按 NimBLE `ble_ll_conn.c:4202-4222` 的顺序：范围 → 乘积 → 监督超时 →
/// max < min → cont ≥ max；每一条的判据本身都来自原文。
pub const RequestError = RangeError || error{
    /// Subrate_Max × (Max_Latency + 1) > 500（38178）。
    LatencyProductOver500,
    /// connInterval × Subrate_Max × (Max_Latency + 1) ≥ 监督超时的一半（38178
    /// ）。与描述段前文「Supervision_Timeout shall be greater than 2 ×
    /// connInterval × Subrate_Max × (Max_Latency + 1)」（38160）是同一件事。
    SupervisionTooShort,
    /// Subrate_Max < Subrate_Min（38179）。
    MaxLessThanMin,
    /// Continuation_Number ≥ Subrate_Max（38180）。
    ContinuationBeyondMax,
};

/// `conn_interval_units` 是当前 connInterval，单位 1.25 ms。换算用微秒做，避免除法
/// 舍入：2 × ci_us × factor × (latency+1) ≥ tmo_us ⇔ ci_ms × factor × (latency+1) ≥
/// tmo_ms / 2（原文的两处表述取其一，判据完全一致）。
pub fn validateRequest(p: SubrateParams, conn_interval_units: u16) RequestError!void {
    try validateParams(p);
    const f: u64 = p.subrate_max;
    const l: u64 = p.max_latency;
    if (f * (l + 1) > product_limit) return error.LatencyProductOver500;
    const two_ci: u64 = 2 * @as(u64, conn_interval_units) * conn_interval_unit_us;
    const tmo_us: u64 = @as(u64, p.supervision_timeout) * supervision_timeout_unit_us;
    if (two_ci * f * (l + 1) >= tmo_us) return error.SupervisionTooShort;
    if (p.subrate_max < p.subrate_min) return error.MaxLessThanMin;
    if (p.continuation_number >= p.subrate_max) return error.ContinuationBeyondMax;
}

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

/// LE Set Default Subrate：五个参数，各 2 八位组小端。§7.8.123。只影响以后 Controller
/// 为 Central 的新连接（38062），所以这里只查范围、不查 §7.8.124 的四条关系。
pub fn cmdSetDefaultSubrate(out: []u8, p: SubrateParams) (RangeError || hci.Error)!usize {
    try validateParams(p);
    return hci.packCommand(out, op_le_set_default_subrate, &p.ctrData());
}

/// LE Subrate Request：Connection_Handle(2) + 五个参数。§7.8.124。回 Command Status，
/// 结果走 LE Subrate Change 事件。参数先过 §7.8.124 的检查；handle 只查 12 位范围
/// （0x02 Unknown Connection Identifier 是 controller 对着连接表说的，host 侧模型在
/// `Session.request` 里查）。
pub fn cmdSubrateRequest(out: []u8, handle: u16, p: SubrateParams, conn_interval_units: u16) (RequestError || Error)!usize {
    try validateRequest(p, conn_interval_units);
    if (handle > handle_max) return error.BadParam;
    var b: [SubrateParams.packed_len + 2]u8 = undefined;
    std.mem.writeInt(u16, b[0..2], handle, .little);
    @memcpy(b[2..], &p.ctrData());
    return hci.packCommand(out, op_le_subrate_request, &b);
}

/// §7.8.123 的返回参数：只有 Status(1)。
pub fn parseSetDefaultSubrateStatus(ret: []const u8) Error!u8 {
    if (onlyStatus(ret)) |s| return s;
    try need(ret, 1);
    return ret[0];
}

// ---------------------------------------------------------------------------
// 事件（§7.7.65.35）
// ---------------------------------------------------------------------------

/// LE Subrate Change 事件参数（子事件码之后）：Status(1) + Connection_Handle(2) +
/// Subrate_Factor(2) + Peripheral_Latency(2) + Continuation_Number(2) +
/// Supervision_Timeout(2)。四个参数字段「All other values」是 Reserved（26251–26310），
/// 这里按拒绝处理。
pub const SubrateChange = struct {
    status: u8,
    handle: u16,
    subrate_factor: u16,
    peripheral_latency: u16,
    continuation_number: u16,
    supervision_timeout: u16,
};

/// `params` 是子事件码之后的那一段。
pub fn decodeSubrateChange(params: []const u8) Error!SubrateChange {
    try need(params, 11);
    const status = params[0];
    const handle = try decodeHandle(params[1..3]);
    const factor = std.mem.readInt(u16, params[3..5], .little);
    const latency = std.mem.readInt(u16, params[5..7], .little);
    const cont = std.mem.readInt(u16, params[7..9], .little);
    const tmo = std.mem.readInt(u16, params[9..11], .little);
    if (factor < subrate_min_min or factor > subrate_factor_max) return error.BadParam;
    if (latency > max_latency_max) return error.BadParam;
    if (cont > continuation_number_max) return error.BadParam;
    if (tmo < supervision_timeout_min or tmo > supervision_timeout_max) return error.BadParam;
    return .{
        .status = status,
        .handle = handle,
        .subrate_factor = factor,
        .peripheral_latency = latency,
        .continuation_number = cont,
        .supervision_timeout = tmo,
    };
}

/// 解一帧完整的 H4 事件（04 + 0x3E + 参数长度 + 子事件码 + 参数）里属于本文件的
/// 子事件。事件码不是 0x3E → `BadParam`；子事件码不是 0x23 → `UnknownSubevent`。
pub fn decodeEvent(frame: []const u8) Error!SubrateChange {
    if (frame.len < 4 or frame[0] != hci.h4_event) return error.Short;
    if (frame[1] != hci.evt_le_meta) return error.BadParam;
    const total = 3 + @as(usize, frame[2]);
    if (frame.len < total) return error.Short;
    if (frame.len > total) return error.Trailing;
    if (frame[2] == 0) return error.Short;
    if (frame[3] != subevent_subrate_change) return error.UnknownSubevent;
    return decodeSubrateChange(frame[4..]);
}

// ---------------------------------------------------------------------------
// LL_SUBRATE_REQ / IND（§2.4.2.36 / §2.4.2.37）
// ---------------------------------------------------------------------------

/// LL Control PDU：Opcode(1) + CtrData(10) = 11 字节。
pub const ll_pdu_len: usize = 1 + SubrateParams.packed_len;

fn needPdu(bytes: []const u8) Error!void {
    if (bytes.len < ll_pdu_len) return error.Short;
    if (bytes.len > ll_pdu_len) return error.Trailing;
}

/// 编 LL_SUBRATE_REQ。字段合法性 = §7.8.124 参数表的范围 + §2.4.2.36 的
/// 「SubrateFactorMax × (Max_Latency + 1) ≤ 500」（3764）。LL Control PDU 是
/// Opcode(1) + CtrData(10)，**不是** H4 命令帧（H4 是 host↔controller 的缝，
/// `hci.packCommand` 的口径）。
pub fn encodeSubrateReq(out: []u8, p: SubrateParams) (RequestError || Error)!usize {
    try validateParams(p);
    if (@as(u32, p.subrate_max) * (p.max_latency + 1) > product_limit) return error.BadParam;
    var b: [ll_pdu_len]u8 = undefined;
    b[0] = ll_op_subrate_req;
    @memcpy(b[1..], &p.ctrData());
    if (out.len < ll_pdu_len) return error.NoSpace;
    @memcpy(out[0..ll_pdu_len], &b);
    return ll_pdu_len;
}

/// 编 LL_SUBRATE_IND。新参数必须满足 §4.5.1 的 shall：factor ∈ [1,500]（4789）、
/// factor × (latency + 1) ≤ 500（4794）、continuation ≤ factor − 1（4789）、
/// 监督超时范围（§4.5.2）。base event 是 16 位连接事件计数，不用查。
pub fn encodeSubrateInd(out: []u8, ind: SubrateIndPdu) Error!usize {
    if (ind.subrate_factor < subrate_min_min or ind.subrate_factor > subrate_factor_max) return error.BadParam;
    if (ind.peripheral_latency > max_latency_max) return error.BadParam;
    if (@as(u32, ind.subrate_factor) * (ind.peripheral_latency + 1) > product_limit) return error.BadParam;
    if (ind.continuation_number >= ind.subrate_factor) return error.BadParam;
    if (ind.supervision_timeout < supervision_timeout_min or ind.supervision_timeout > supervision_timeout_max) return error.BadParam;
    var b: [ll_pdu_len]u8 = undefined;
    b[0] = ll_op_subrate_ind;
    @memcpy(b[1..], &ind.ctrData());
    if (out.len < ll_pdu_len) return error.NoSpace;
    @memcpy(out[0..ll_pdu_len], &b);
    return ll_pdu_len;
}

/// 解 LL_SUBRATE_REQ（Opcode 必须是 0x26）。字段合法性同 `encodeSubrateReq`；
/// 越界字段报各自的范围错误名。
pub fn decodeSubrateReq(bytes: []const u8) (RequestError || Error)!SubrateParams {
    try needPdu(bytes);
    if (bytes[0] != ll_op_subrate_req) return error.BadParam;
    const p: SubrateParams = .{
        .subrate_min = std.mem.readInt(u16, bytes[1..3], .little),
        .subrate_max = std.mem.readInt(u16, bytes[3..5], .little),
        .max_latency = std.mem.readInt(u16, bytes[5..7], .little),
        .continuation_number = std.mem.readInt(u16, bytes[7..9], .little),
        .supervision_timeout = std.mem.readInt(u16, bytes[9..11], .little),
    };
    try validateParams(p);
    if (@as(u32, p.subrate_max) * (p.max_latency + 1) > product_limit) return error.BadParam;
    return p;
}

/// 解 LL_SUBRATE_IND（Opcode 必须是 0x27）。字段合法性同 `encodeSubrateInd`。
///
/// §5.1.19 的「The Peripheral shall accept an LL_SUBRATE_IND PDU」（6206）是过程层
/// 的：编解码层拒绝的是字段本身越界的**非法编码**（§4.5.1 的 shall），两件事不冲突
/// ——NimBLE `ble_ll_ctrl.c:1277-1285` 对越界 IND 也是重置参数而不是崩溃。
pub fn decodeSubrateInd(bytes: []const u8) Error!SubrateIndPdu {
    try needPdu(bytes);
    if (bytes[0] != ll_op_subrate_ind) return error.BadParam;
    const ind: SubrateIndPdu = .{
        .subrate_factor = std.mem.readInt(u16, bytes[1..3], .little),
        .subrate_base_event = std.mem.readInt(u16, bytes[3..5], .little),
        .peripheral_latency = std.mem.readInt(u16, bytes[5..7], .little),
        .continuation_number = std.mem.readInt(u16, bytes[7..9], .little),
        .supervision_timeout = std.mem.readInt(u16, bytes[9..11], .little),
    };
    if (ind.subrate_factor < subrate_min_min or ind.subrate_factor > subrate_factor_max) return error.BadParam;
    if (ind.peripheral_latency > max_latency_max) return error.BadParam;
    if (@as(u32, ind.subrate_factor) * (ind.peripheral_latency + 1) > product_limit) return error.BadParam;
    if (ind.continuation_number >= ind.subrate_factor) return error.BadParam;
    if (ind.supervision_timeout < supervision_timeout_min or ind.supervision_timeout > supervision_timeout_max) return error.BadParam;
    return ind;
}

// ---------------------------------------------------------------------------
// 子额定的纯算术（§4.5.1 / §5.1.19）
// ---------------------------------------------------------------------------

/// 连接事件 `event_count` 是不是子额定事件：§4.5.1（4787）(connEventCount −
/// connSubrateBaseEvent) 是 factor 的整数倍。差值用 16 位回绕减法，跨回绕也成立
/// （原文自己的例子：base=42、count=24242、factor=100 → 24200 是 100 的倍数）。
pub fn isSubratedEvent(event_count: u16, base: u16, factor: u16) Error!bool {
    if (factor == 0) return error.BadParam;
    const diff: u16 = event_count -% base;
    return diff % factor == 0;
}

/// §4.5.1（4799）：connEventCounter 回绕时 base ← base + K × factor − 65536，K 使
/// 结果落在 0…65535。K 不唯一，这里取最小的 K（策略，双方实现一致即可）。
pub fn wrapBaseEvent(base: u16, factor: u16) Error!u16 {
    if (factor == 0) return error.BadParam;
    const gap: u32 = @as(u32, 65536) - base;
    const k: u32 = (gap + factor - 1) / factor; // ceil
    const new: u64 = @as(u64, base) + @as(u64, k) * factor - 65536;
    if (new > 65535) return error.BadParam;
    return @intCast(new);
}

/// 有效连接间隔 = connInterval × connSubrateFactor × (1 + connPeripheralLatency)
/// （§7.3.94 的 LE 一段，16874 起，乘积式在 16900；§4.5.1 4794 同一乘积），单位 1.25 ms。输入先满足
/// §4.5.1 的约束。
pub fn effectiveIntervalUnits(conn_interval_units: u16, factor: u16, latency: u16) Error!u32 {
    if (factor < subrate_min_min or factor > subrate_factor_max) return error.BadParam;
    if (@as(u32, factor) * (latency + 1) > product_limit) return error.BadParam;
    const v: u64 = @as(u64, conn_interval_units) * factor * (latency + 1);
    if (v > std.math.maxInt(u32)) return error.BadParam;
    return @intCast(v);
}

/// 子额定连接间隔的微秒数 = connInterval × factor × 1.25 ms。
pub fn subratedIntervalUs(conn_interval_units: u16, factor: u16) Error!u64 {
    if (factor < subrate_min_min or factor > subrate_factor_max) return error.BadParam;
    return @as(u64, conn_interval_units) * factor * conn_interval_unit_us;
}

/// 非空包后的“突发”：`last_active_event` 之后还有 continuation_number 个底层连接
/// 事件保持活跃（§7.8.124 对 Continuation_Number 的定义；§4.5.1 图 4.42–4.44）。
/// 16 位回绕加法。
pub fn continuationEnd(last_active_event: u16, continuation_number: u16) u16 {
    return last_active_event +% continuation_number;
}

/// §5.1.19（6203）：Central 往 LL_SUBRATE_IND 里放的 base 要满足 S15-14 = E15-14，
/// E 是 PDU 首次排队那个连接事件的计数。低 14 位由调用方的策略给。
pub fn centralBaseForQueuedEvent(chosen_base: u16, event_count: u16) u16 {
    return (chosen_base & 0x3FFF) | (event_count & 0xC000);
}

// ---------------------------------------------------------------------------
// §5.1.19 / §5.1.20 的判决函数
// ---------------------------------------------------------------------------

/// §5.1.20 的拒绝理由。对应的 LL_REJECT_EXT_IND 错误码按 NimBLE 的实现映射：
/// host_support_not_set → Unsupported Remote Feature (0x1A)（ble_ll_ctrl.c:1217）；
/// params_not_acceptable → Invalid LL Parameters (0x30)（ble_ll_conn.c:1230）；
/// conn_param_request_busy → Different Transaction Collision (0x2A)
/// （ble_ll_conn.c:1232）。规范原文只说「reject」，错误码没有逐条指定。
pub const RejectReason = enum {
    /// Central 的 Host 没设 Connection Subrating (Host Support) 位（6209）。
    host_support_not_set,
    /// Connection Parameters Request 正在进行（§5.1.19 的发起禁令，6197）。
    conn_param_request_busy,
    /// 五个条件里有一条不成立。`rule` 说明是哪一条。
    params_not_acceptable,
};

/// §5.1.20 的五个条件，一条一个名字。行号对应 Core-54-ll.txt 6211–6217。
pub const Rule = enum {
    /// R1：Max_Latency_requested ≤ Max_Latency_acceptable（6212）。
    r1_latency,
    /// R2：Timeout_requested ≤ Supervision_Timeout_acceptable（6213）。
    r2_timeout,
    /// R3：SubrateFactorMax_requested ≥ Subrate_Min_acceptable（6214）。
    r3_max_below_min,
    /// R4：SubrateFactorMin_requested ≤ Subrate_Max_acceptable（6215）。
    r4_min_above_max,
    /// R5：(connInterval × SubrateFactorMin_requested × (Max_Latency_requested + 1)) × 2
    /// < Timeout_requested（6216）。
    r5_supervision,
};

pub const ParamsReject = struct { reason: RejectReason, rule: ?Rule = null };

/// Central 接受后发起的 Connection Subrate Update 的结果参数（§5.1.20 的「If the
/// Central accepts」块，6218–6221）。
pub const ResultParams = struct {
    subrate_factor: u16,
    continuation_number: u16,
    peripheral_latency: u16,
    supervision_timeout: u16,
};

pub const Verdict = union(enum) {
    accept: ResultParams,
    reject: ParamsReject,
};

/// Central 收到 LL_SUBRATE_REQ 后的判决（§5.1.20，6209–6221）。
///
/// 取值策略（规范允许交集里任意值，这里与 NimBLE `ble_ll_conn.c:4291-4296` 一致，
/// 便于对拍）：factor = min(acc_max, req_max)。新监督超时**按原文**取
/// min(Timeout_requested, Supervision_Timeout_acceptable)（6221）——R2 成立时它就等于
/// Timeout_requested；NimBLE 这里用的是当前值，是它自己的偏差。
///
/// 请求里的参数如果本身越界（不该出现在合法 LL_SUBRATE_REQ 里），返回对应的
/// 范围错误 / `BadParam`。
pub fn centralVerdict(
    acceptable: SubrateParams,
    requested: SubrateParams,
    host_support_set: bool,
    conn_param_req_in_progress: bool,
    conn_interval_units: u16,
) (RangeError || Error)!Verdict {
    try validateParams(acceptable);
    try validateParams(requested);
    if (@as(u32, requested.subrate_max) * (requested.max_latency + 1) > product_limit) return error.BadParam;
    if (!host_support_set) return .{ .reject = .{ .reason = .host_support_not_set } };
    if (conn_param_req_in_progress) return .{ .reject = .{ .reason = .conn_param_request_busy } };

    var rule: ?Rule = null;
    if (requested.max_latency > acceptable.max_latency) {
        rule = .r1_latency;
    } else if (requested.supervision_timeout > acceptable.supervision_timeout) {
        rule = .r2_timeout;
    } else if (requested.subrate_max < acceptable.subrate_min) {
        rule = .r3_max_below_min;
    } else if (requested.subrate_min > acceptable.subrate_max) {
        rule = .r4_min_above_max;
    } else {
        // R5 用微秒做：2 × ci_us × fmin × (latency+1) < tmo_us 才接受（6216）。
        const lhs: u64 = 2 * @as(u64, conn_interval_units) * conn_interval_unit_us *
            requested.subrate_min * (requested.max_latency + 1);
        const rhs: u64 = @as(u64, requested.supervision_timeout) * supervision_timeout_unit_us;
        if (lhs >= rhs) rule = .r5_supervision;
    }
    if (rule) |r| return .{ .reject = .{ .reason = .params_not_acceptable, .rule = r } };

    const factor = @min(acceptable.subrate_max, requested.subrate_max);
    const cont = @min(@max(acceptable.continuation_number, requested.continuation_number), factor - 1);
    return .{ .accept = .{
        .subrate_factor = factor,
        .continuation_number = cont,
        .peripheral_latency = @min(requested.max_latency, acceptable.max_latency),
        .supervision_timeout = @min(requested.supervision_timeout, acceptable.supervision_timeout),
    } };
}

/// §7.8.124（38161–38167）：Central 的 Host 发了 LE Subrate Request 后，Controller
/// 发起 Connection Subrate Update 时往 LL_SUBRATE_IND 里放的值：
/// factor 取 Subrate_Max（策略，与 NimBLE `ble_ll_conn.c:4246` 一致；规范只要求落在
/// [Subrate_Min, Subrate_Max]）；latency = Max_Latency（「shall be less than or equal
/// to」，取等是满足它的最小动作）；continuation = lesser(Continuation_Number,
/// factor − 1)（38166 原文的 “the lesser of”）；timeout = Supervision_Timeout；
/// base = `chosen_base` 的低 14 位 + 排队事件计数的高 2 位（§5.1.19，6203）。
pub fn centralIndFromRequest(
    p: SubrateParams,
    conn_interval_units: u16,
    event_count: u16,
    chosen_base: u16,
) RequestError!SubrateIndPdu {
    try validateRequest(p, conn_interval_units);
    const factor = p.subrate_max;
    return .{
        .subrate_factor = factor,
        .subrate_base_event = centralBaseForQueuedEvent(chosen_base, event_count),
        .peripheral_latency = p.max_latency,
        .continuation_number = @min(p.continuation_number, factor - 1),
        .supervision_timeout = p.supervision_timeout,
    };
}

/// §7.8.124（38172–38176）：Peripheral 的 Host 发了 LE Subrate Request 后，Controller
/// 发起 Connection Subrate Request 时往 LL_SUBRATE_REQ 里放的值：min/max 原样取
/// （Subrate_Min, Subrate_Max）；latency = Max_Latency；continuation =
/// lesser(Continuation_Number, Subrate_Max − 1)（38175 的 “the lesser of”，
/// 用的是 max factor）；timeout = Supervision_Timeout。
pub fn peripheralReqFromRequest(p: SubrateParams, conn_interval_units: u16) RequestError!SubrateParams {
    try validateRequest(p, conn_interval_units);
    return .{
        .subrate_min = p.subrate_min,
        .subrate_max = p.subrate_max,
        .max_latency = p.max_latency,
        .continuation_number = @min(p.continuation_number, p.subrate_max - 1),
        .supervision_timeout = p.supervision_timeout,
    };
}

/// Peripheral 收到 LL_SUBRATE_IND 后的新连接参数（§5.1.19：立即切换，6200）。时间
/// 注入：`event_count` 是收到时本端的 connEventCount。若 S15-14 = 0b11 而计数器的
/// 15-14 = 0b00（6203），更新后按 §4.5.1 视作刚回绕，对 base 做回绕修正。
/// 新参数只取决于 IND 本身与当时的计数（spec 没有别的依赖项）；输入 IND 要先过
/// `decodeSubrateInd`。
pub fn peripheralApplyInd(
    ind: SubrateIndPdu,
    event_count: u16,
) Error!ConnSubrate {
    var new: ConnSubrate = .{
        .subrate_factor = ind.subrate_factor,
        .subrate_base_event = ind.subrate_base_event,
        .peripheral_latency = ind.peripheral_latency,
        .continuation_number = ind.continuation_number,
        .supervision_timeout = ind.supervision_timeout,
    };
    if ((ind.subrate_base_event >> 14) == 0b11 and (event_count >> 14) == 0b00) {
        new.subrate_base_event = try wrapBaseEvent(ind.subrate_base_event, ind.subrate_factor);
    }
    return new;
}

// ---------------------------------------------------------------------------
// host 侧小模型：设缺省值 → 请求 → 收到事件
// ---------------------------------------------------------------------------

pub const Role = enum { central, peripheral };

pub const ModelError = error{
    /// handle 没有对应的连接（§7.8.124：0x02 Unknown Connection Identifier）。
    UnknownHandle,
    /// 没有待完成的过程却来了事件。
    NotPending,
    /// 事件的 handle 与请求的不一致。
    HandleMismatch,
    /// 事件带非零 Status（§7.7.65.35：命令失败）。
    StatusNotSuccess,
    /// 事件里的参数与请求对不上（模型自检，`power_ctrl.PathLossTracker` 同思路）。
    ParamsDontMatchRequest,
    /// §5.2：过程响应超时 T_PRT = 40 s 到了。
    ProcedureTimeout,
};

/// 单连接的 host 会话：`setDefault`（§7.8.123）→ `request`（§7.8.124）→ `onEvent`
/// （§7.7.65.35），`tick` 查 §5.2 的 40 s 过程超时。时间是注入的（微秒）。
pub const Session = struct {
    /// 将来新建连接（Controller 为 Central）时用的 acceptable 参数。§7.8.123：不影响
    /// 已存在的连接。
    defaults: SubrateParams = SubrateParams.default,
    conn: ?Conn = null,

    pub const Conn = struct {
        handle: u16,
        role: Role,
        /// 当前生效的子额定参数（§4.5.1；新连接 factor = 1、cont = 0，4789）。
        current: ConnSubrate = .{},
        /// 当前的 connInterval，单位 1.25 ms（§7.8.124 的监督超时检查要用）。
        conn_interval_units: u16,
        /// 已发请求、等 LE Subrate Change。
        pending: bool = false,
        request: SubrateParams = SubrateParams.default,
        request_started_us: u64 = 0,
    };

    /// §7.8.123：设默认值。只查范围。
    pub fn setDefault(self: *Session, p: SubrateParams) (RangeError || Error)!void {
        try validateParams(p);
        self.defaults = p;
    }

    /// 建一条连接（host 侧视角；真实连接建立事件不归本文件）。
    pub fn openConn(self: *Session, handle: u16, role: Role, conn_interval_units: u16) Error!void {
        if (handle > handle_max) return error.BadParam;
        self.conn = .{ .handle = handle, .role = role, .conn_interval_units = conn_interval_units };
    }

    /// Host 发 LE Subrate Request（§7.8.124）。Central 发时它同时成为对 Peripheral
    /// 请求的 acceptable 集（38168–38170），Peripheral 发时它就是要放进
    /// LL_SUBRATE_REQ 的参数——两种角色模型里都记在 `conn.request`。
    /// `peer_supports`：对端 FeatureSet 里的 Connection Subrating (Host Support) 位
    /// （§7.8.124 最后一条错误，0x1A；本模型不维护 Feature Exchange，由调用方告知）。
    pub fn request(
        self: *Session,
        handle: u16,
        p: SubrateParams,
        now_us: u64,
        peer_supports: bool,
    ) (RequestError || ModelError || Error)!void {
        try validateRequest(p, if (self.conn) |c| c.conn_interval_units else return error.UnknownHandle);
        const c = if (self.conn) |*c| c else return error.UnknownHandle;
        if (c.handle != handle) return error.UnknownHandle;
        if (c.role == .central and !peer_supports) return error.BadParam; // 0x1A → 拒绝路径
        c.pending = true;
        c.request = p;
        c.request_started_us = now_us;
    }

    /// Central 发请求时，Controller 随后发出的 LL_SUBRATE_IND 的预期值（§7.8.124
    /// Central 规则 + §5.1.19 的 S15-14）。测试与板侧自检用它把事件对回去。
    pub fn expectedInd(self: *Session, event_count: u16, chosen_base: u16) (RequestError || ModelError)!SubrateIndPdu {
        const c = self.conn orelse return error.UnknownHandle;
        if (!c.pending or c.role != .central) return error.NotPending;
        return centralIndFromRequest(c.request, c.conn_interval_units, event_count, chosen_base);
    }

    /// LE Subrate Change 事件进来（§7.7.65.35）：与请求对账，通过则更新当前参数。
    pub fn onEvent(self: *Session, ev: SubrateChange) ModelError!void {
        const c = if (self.conn) |*c| c else return error.UnknownHandle;
        if (!c.pending) return error.NotPending;
        if (c.handle != ev.handle) return error.HandleMismatch;
        c.pending = false;
        if (ev.status != 0) return error.StatusNotSuccess;
        // §7.8.124 Central / Peripheral 两套规则的公共下界 + §5.1.20 的结果参数下界：
        // factor 落在请求的 [min, max]（38165、6218）；
        // latency ≤ Max_Latency（38164、6220：≤ min(req, acc) ≤ req）；
        // timeout == 请求值（38167、6221 + R2）；
        // continuation ≤ factor − 1（§4.5.1，4789）；Central 的还 ≤ 请求值
        // （38166、6219：min(max(acc, req), f−1)，而 f ≤ req_max 时
        // max(acc, req) ≤ req 才可能，所以这里只查 ≤ f−1 与 ≤ req 两者都成立的一边）。
        if (ev.subrate_factor < c.request.subrate_min or ev.subrate_factor > c.request.subrate_max) return error.ParamsDontMatchRequest;
        if (ev.peripheral_latency > c.request.max_latency) return error.ParamsDontMatchRequest;
        if (ev.supervision_timeout != c.request.supervision_timeout) return error.ParamsDontMatchRequest;
        if (ev.continuation_number >= ev.subrate_factor) return error.ParamsDontMatchRequest;
        if (c.role == .central and ev.continuation_number > c.request.continuation_number) return error.ParamsDontMatchRequest;
        c.current = .{
            .subrate_factor = ev.subrate_factor,
            .subrate_base_event = c.current.subrate_base_event,
            .peripheral_latency = ev.peripheral_latency,
            .continuation_number = ev.continuation_number,
            .supervision_timeout = ev.supervision_timeout,
        };
    }

    /// §5.2（6235–6238）：LL Control PDU 排队后 40 s 没完成 → 连接丢失。这里只报
    /// 错并清 pending（host 侧把连接拆掉是别处的职责）。
    pub fn tick(self: *Session, now_us: u64) ModelError!void {
        const c = if (self.conn) |*c| c else return;
        if (!c.pending) return;
        if (now_us - c.request_started_us >= procedure_response_timeout_us) {
            c.pending = false;
            return error.ProcedureTimeout;
        }
    }
};
