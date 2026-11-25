//! ble-802154：PAwR（Periodic Advertising with Responses，周期广播带响应）的 host 侧
//! 收尾——三条 HCI 命令、两个 LE 事件、链路层子事件 PDU 头的许可检查，以及「收到请求 →
//! 选条目 → 发 Subevent Data」的小状态模型。只做纯逻辑，不调度时序，不碰射频。
//!
//! 规范出处（Bluetooth Core 5.4；条款号与原文一致，HCI 在 [Vol 4] Part E，链路层在
//! [Vol 6] Part B；行号是 /tmp/spec/*.txt 抽取文本的行）：
//!   * HCI_LE_Set_Periodic_Advertising_Subevent_Data —— §7.8.125（OCF 0x82，
//!     正文 38249 行；Num_Subevents 表 38287 行）
//!   * HCI_LE_Set_Periodic_Advertising_Response_Data —— §7.8.126（OCF 0x83，38375 行）
//!   * HCI_LE_Set_Periodic_Sync_Subevent —— §7.8.127（OCF 0x84，38501 行；
//!     Periodic_Advertising_Properties 位表 38532 行）
//!   * LE Periodic Advertising Subevent Data Request event —— §7.7.65.36（子事件码
//!     0x27，26302 行；Description 段的计数 shall 与回绕规则在 26315 行）
//!   * LE Periodic Advertising Response Report event —— §7.7.65.37（子事件码 0x28，
//!     26357 行；各条目表 26415–26536 行）
//!   * LE Set Event Mask 的两位 —— §7.8.1：bit 38 / bit 39（27244、27247 行）
//!   * 数组参数按元素交错（Tx_Power[0] RSSI[0] … Data[0] Tx_Power[1] …）—— §5.2
//!     （4948 行；Data[i] 变长的原文注记在 26530 行附近）
//!   * AUX_SYNC_SUBEVENT_IND —— §2.3.1.9 与表 2.8（2863、2898 行）；字段许可已与
//!     盘上 SIG 官方 HTML（/tmp/spec/Core-54-ll.html）逐格对过：IND 的 AdvA / TargetA /
//!     AuxPtr / SyncInfo 是 X（不允许出现），CTE Info / ADI / TxPower / ACAD / AdvData
//!     是 O；RSP（§2.3.1.10、表 2.9，2899、2933 行）的 TargetA / ADI / AuxPtr /
//!     SyncInfo 是 X，AdvA / CTE Info / TxPower / ACAD / AdvData 是 O。两种 PDU 都
//!     没有 M（必带）字段，AdvMode 都必须 0b00。
//!   * Common Extended Advertising Payload Format —— §2.3.4（3084 行起）；扩展头字段
//!     的切分复用 `ext_adv.parseExtPdu`（同一张图 2.14 / 2.15）。
//!   * PAwR 事件与时间参数 —— §4.4.2.2.4（4390 行）：只取「一个 train 最多 128 个
//!     子事件」（4395 行）这一条 host 可判的规则，时间公式不实现；
//!     「Subevent_Data_Count ≤ 子事件总数」「子事件号从小于总数回绕到 0」两条规则
//!     出自 §7.7.65.36（hci.txt 26315 行），ll.txt 里没有这两句。
//!   * 空载荷的 AUX_SYNC_SUBEVENT_IND —— §4.4.2.12.2（ll.txt 4545 行起；4547 行：
//!     “If the Host has not provided any data … should still be sent with an empty
//!     payload”）。
//!   * PAwR 过程（MSC）—— [Vol 6] Part B §3.9–§3.12：正文是图，host 侧行为已由上面
//!     的命令与事件条款覆盖。
//!
//! 与盘上独立实现的对拍情况：NimBLE（IDF v6.1）没有 PAwR——
//! `grep -rin pawr|subevent` 在 nimble/ 下只有 ISO BIG 的子事件，零命中——所以命令
//! 编码没有独立实现可对拍，期望值靠逐字节手排加 Python oracle
//! （/tmp/s31-oracle/pawr/，按同一份原文独立写的模型）。表 2.8 / 2.9 的格子另与
//! SIG 官方 HTML 程序计数核对过一遍（见上）。
//!
//! 三块内容：
//!   1. **命令编码与返回参数解析**（`cmdSet…`、`parse…Return`）：参数按原文参数表
//!      顺序排，7.8.125 的五个数组参数按 §5.2 交错；值越界 / 保留值返回哪个错误见
//!      `Error`；拒绝时输出缓冲一个字节都不写。
//!   2. **事件解析**（`decodeEvent` → `DataRequest` / `ResponseReport`）：事件的
//!      数组参数同样交错；保留取值不静默接受。
//!   3. **状态模型**（`Advertiser`、`SubeventSet`）：广告侧的请求/应答台账（子事件
//!      号回绕；一条请求可由多条命令答完——每条命令 ≤ 15 个条目（§7.8.125
//!      Num_Subevents 0x01–0x0F），请求覆盖的子事件全部答完才关；同一子事件的
//!      数据只发一次）、同步侧的子事件子集表示与增删差分。
//!
//! 明确不做（原文只给了 Controller 侧判据或时序，host 侧算不出来 / 不需要）：
//!   * Packet Too Long / Too Early / Too Late（§7.8.125、§7.8.126）：取决于 Controller
//!     当前子事件区间与 PHY 编码，host 侧没有输入。
//!   * 子事件的时序调度与 §4.4.2.2.4 的时间公式（间隔换算只读不实现）。
//!   * §3.12 Connecting from PAwR 的空口部分（AUX_CONNECT_REQ/RSP 由 Controller 发）。
//!   * §2.3.1.9 「ADI 的 SID 必须与 superior PDU 相同」需要链上上下文，这里只给
//!     `adiSidMatches` 助手由调用方带 expected SID 调用。
//!
//! 比原文严的一处（评审返修时定的取舍，有原文依据）：
//!   * `Advertiser.respond` 拒收同一条命令里重复的 Subevent[i]（`AlreadyAnswered`）：
//!     §7.8.125 只说「The data for a subevent shall be transmitted only once」（38268
//!     行），没写同一命令里条目重复时回什么；按「一次传输」的字面，同一子事件的
//!     数据被给两次（无论同一条命令还是先后两条）都拦下来。跨命令的重复拒收同此。
//!
//! 评审返修（2026-11-25，/tmp/r5c/review-ble.md 第 1、3 条）：
//!   * 第 1 条（P2）确认：`respond` 原来一条请求只允许一条命令应答；改为已答位图
//!     台账——每条命令至多 15 个条目（§7.8.125 参数表），§7.7.65.36 的一次请求最多
//!     覆盖 0x80 个子事件，原文只约束「范围外的子事件拒（0x0C）」与「每个子事件的
//!     数据只发一次」（38268、38271 行），不约束「一请求一命令」。请求覆盖的子事件
//!     全部答完才关闭，未答完前请求保持 pending。
//!   * 第 3 条（文档）：Num_Subevents 表 38344→38287、回绕/计数 shall 26327→26315、
//!     Properties 位表 38574→38532、「空载荷仍发 IND」→ §4.4.2.12.2（ll.txt 4547）、
//!     「Subevent_Data_Count ≤ 子事件数」→ §7.7.65.36（26315；ll.txt 无此句）。
//!
//! 板侧子自检（`pawr_selftest.zig`）共 18 条判据；文件作用域缓冲，栈上不留大数组。

const std = @import("std");

const hci = @import("hci.zig");
const ext_adv = @import("ext_adv.zig");

/// `Short` / `Trailing` / `NoSpace` / `Oversize` 的语义与 `hci.packCommand`、
/// `ext_adv` 同口径：输入短于固定长度 / 长于声明长度 / 输出放不下 / HCI 参数段
/// 超过 255 字节。`ext_adv.Error` 里的那些（`BadAdvMode`、`NotExtPdu`、
/// `ReservedFlag`、`BadHeaderLength` 等）来自复用的 `parseExtPdu` 与
/// `PeriodicAdvParams.validate`，与本文件自己的错误名共用同一套语义。
pub const Error = hci.Error || ext_adv.Error || error{
    /// Advertising_Handle 超过 0xEF（§7.8.125），或 Sync_Handle 超过 0x0EFF
    /// （§7.8.126、§7.8.127 的 “12 bits meaningful”）。
    BadHandle,
    /// Num_Subevents 不在参数表的范围里：§7.8.125 是 0x01–0x0F（“All other values
    /// Reserved for future use”），§7.8.127 是 0x01–0x80，§7.7.65.36 的
    /// Subevent_Data_Count 是 0x01–0x80。
    BadNumSubevents,
    /// 子事件号超过 0x7F（Subevent[i]、Subevent_Start、Subevent、Response_Subevent
    /// 的 Range 上限）。
    BadSubevent,
    /// Subevent_Data_Length / Response_Data_Length 不在 0–251（“All other values
    /// Reserved for future use”）。
    BadDataLength,
    /// §7.8.127 Periodic_Advertising_Properties 的保留位（bit 6 以外）置位。
    BadProperties,
    /// §7.7.65.37 Tx_Status 不是 0x00 / 0x01。
    BadTxStatus,
    /// §7.7.65.37 Num_Responses 超过 0x19。
    BadNumResponses,
    /// §7.7.65.37 CTE_Type 不是 0x00 / 0x01 / 0x02 / 0xFF。
    BadCteType,
    /// §7.7.65.37 Data_Status 不是 0x00 / 0x01 / 0xFF。
    BadDataStatus,
    /// §7.7.65.37 TX_Power / RSSI 不在 −127…+20 dBm，也不是 0x7F（不可用）。
    BadLevel,
    /// 事件里声明的条目数超过调用方给的输出数组。
    NoRoom,
    /// 事件分发的子事件码不是本文件的两个（§7.7.65.36 / §7.7.65.37）。
    UnknownSubevent,
    /// 链路层：这个字段在表 2.8 / 表 2.9 里是 X（不允许出现），却出现在了 PDU 里。
    FieldNotPermitted,
    /// 链路层：AUX_SYNC_SUBEVENT_IND / RSP 的 AdvMode 必须 0b00（§2.3.1.9、
    /// §2.3.1.10 的第一句 shall）。
    BadAdvMode,
    /// 链路层：PDU Type 不是 0b0111（扩展广播共用类型，§2.3.4）。
    NotExtPdu,
    /// 状态模型：这个广播集还没按 §7.8.61 [v2] 配成 PAwR（Num_Subevents = 0x00 是
    /// 没有响应的周期广播，不是 PAwR train）。
    NotPawr,
    /// 状态模型：还没配置就收到了请求。
    NotConfigured,
    /// 状态模型：请求事件的 Advertising_Handle 与台账不一致。
    WrongHandle,
    /// 状态模型：Subevent_Data_Count 超过该 train 的子事件总数（§7.7.65.36 的
    /// “The Subevent_Data_Count parameter shall be less than or equal to the number
    /// of subevents”，hci.txt 26315 行）。
    CountExceedsTrain,
    /// 状态模型：没有未应答的请求就发 Subevent Data。
    NoRequest,
    /// 状态模型：条目的子事件号不在刚收到的请求里（§7.8.125：Controller 会回
    /// Command Disallowed 0x0C，host 侧先拦）。
    NotRequested,
    /// 状态模型：同一子事件的数据被应答第二次（§7.8.125：“The data for a subevent
    /// shall be transmitted only once”，38268 行）。
    AlreadyAnswered,
};

// ---------------------------------------------------------------------------
// OpCode 与子事件码
// ---------------------------------------------------------------------------

fn leOpcode(comptime ocf: u10) u16 {
    return hci.opcode(hci.ogf_le_controller, ocf);
}

/// §7.8.125。
pub const op_le_set_periodic_adv_subevent_data: u16 = leOpcode(0x082);
/// §7.8.126。
pub const op_le_set_periodic_adv_response_data: u16 = leOpcode(0x083);
/// §7.8.127。
pub const op_le_set_periodic_sync_subevent: u16 = leOpcode(0x084);

/// LE Meta 子事件码。§7.7.65.36、§7.7.65.37。
pub const le_subevent_data_request: u8 = 0x27;
pub const le_response_report: u8 = 0x28;

/// LE Set Event Mask 的两位（§7.8.1 位表 bit 38 / bit 39）。掩码是 8 字节小端的
/// u64，第 n 个事件对应 bit n。
pub const le_event_mask_subevent_data_request: u64 = @as(u64, 1) << 38;
pub const le_event_mask_response_report: u64 = @as(u64, 1) << 39;

// ---------------------------------------------------------------------------
// 取值
// ---------------------------------------------------------------------------

/// Advertising_Handle 的范围（§7.8.125）。与 `ext_adv.handle_max` 同一个值。
pub const handle_max: u8 = ext_adv.handle_max;
/// Sync_Handle 只有低 12 位有意义（§7.8.126、§7.8.127 的 “12 bits meaningful”）。
pub const sync_handle_max: u16 = 0x0EFF;
/// 子事件号的 Range 上限（Subevent[i]、Subevent_Start、Subevent、Response_Subevent）。
pub const subevent_max: u8 = 0x7F;
/// 一个 train 最多 128 个子事件（§4.4.2.2.4 “Up to 128 subevents can be used in a
/// Periodic Advertising Interval”；§7.8.127 Num_Subevents 上限同值）。
pub const train_subevents_max: u8 = 0x80;
/// §7.8.125 的 Num_Subevents：一条命令最多 15 个条目（参数表 “0x01 to 0x0F，
/// All other values Reserved for future use”）。
pub const cmd_subevents_max: u8 = 0x0F;
/// Subevent_Data_Length / Response_Data_Length 的上限（参数表 “0 to 251”）。
pub const data_len_max: usize = 251;
/// §7.7.65.37 Num_Responses 的上限（参数表 “0x00 to 0x19”）。
pub const responses_max: u8 = 0x19;
/// TX_Power / RSSI 的可报范围：−127 到 +20 dBm；0x7F 表示不可用（§7.7.65.37）。
pub const level_min: i8 = -127;
pub const level_max: i8 = 20;
pub const level_unavailable: u8 = 0x7F;
/// §7.8.127 Periodic_Advertising_Properties：只有 bit 6（Include TxPower）。
pub const prop_include_tx_power: u16 = 1 << 6;

fn need(buf: []const u8, n: usize) Error!void {
    if (buf.len < n) return error.Short;
    if (buf.len > n) return error.Trailing;
}

/// 失败时 controller 可以只回一个 Status；成功却只有 Status 是截断。与
/// `ext_adv.needReturn` / `power_ctrl.onlyFailure` 同一口径。
fn onlyFailure(ret: []const u8) ?u8 {
    if (ret.len == 1 and ret[0] != 0) return ret[0];
    return null;
}

/// TX_Power / RSSI 的一个字节：0x7F → null（不可用），否则按补码读并查范围。
fn levelOf(v: u8) Error!?i8 {
    if (v == level_unavailable) return null;
    const x: i8 = @bitCast(v);
    if (x < level_min or x > level_max) return error.BadLevel;
    return x;
}

// ---------------------------------------------------------------------------
// §7.8.125 LE Set Periodic Advertising Subevent Data
// ---------------------------------------------------------------------------

/// 一个子事件的应答条目。`data` 为空是合法的：§4.4.2.12.2（ll.txt 4547 行）说
/// Host 没给数据时 Controller 仍应发一个空载荷的 AUX_SYNC_SUBEVENT_IND。
pub const SubeventEntry = struct {
    /// Subevent[i]：Range 0x00–0x7F。
    subevent: u8,
    /// Response_Slot_Start[i]：本子事件要用的第一个响应槽（参数表没有 Range）。
    response_slot_start: u8,
    /// Response_Slot_Count[i]：本子事件要用的响应槽个数（参数表没有 Range）。
    response_slot_count: u8,
    /// Subevent_Data[i]：0–251 字节；长度由它的字节数给出。
    data: []const u8 = &.{},
};

/// §7.8.125 命令编码。参数段（按参数表顺序 + §5.2 的逐条目交错）：
/// Advertising_Handle(1) Num_Subevents(1)，然后每个条目
/// Subevent[i](1) Response_Slot_Start[i](1) Response_Slot_Count[i](1)
/// Subevent_Data_Length[i](1) Subevent_Data[i](len)。
pub fn cmdSetPeriodicAdvSubeventData(out: []u8, adv_handle: u8, entries: []const SubeventEntry) Error!usize {
    if (adv_handle > handle_max) return error.BadHandle;
    if (entries.len == 0 or entries.len > cmd_subevents_max) return error.BadNumSubevents;
    var data_sum: usize = 0;
    for (entries) |e| {
        if (e.subevent > subevent_max) return error.BadSubevent;
        if (e.data.len > data_len_max) return error.BadDataLength;
        data_sum += e.data.len;
    }
    // 参数段 = 2 + Σ(Subevent_Data_Length[i] + 4)；HCI 参数长度是 1 字节（§5.2 / §5.4.2）。
    const plen = 2 + 4 * entries.len + data_sum;
    if (plen > 255) return error.Oversize;
    const total = 4 + plen;
    if (out.len < total) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_set_periodic_adv_subevent_data, .little);
    out[3] = @intCast(plen);
    out[4] = adv_handle;
    out[5] = @intCast(entries.len);
    var p: usize = 6;
    for (entries) |e| {
        out[p] = e.subevent;
        out[p + 1] = e.response_slot_start;
        out[p + 2] = e.response_slot_count;
        out[p + 3] = @intCast(e.data.len);
        @memcpy(out[p + 4 .. p + 4 + e.data.len], e.data);
        p += 4 + e.data.len;
    }
    return total;
}

/// §7.8.125 的返回参数：Status(1) + Advertising_Handle(1)。
pub const SubeventDataReturn = struct { status: u8, adv_handle: u8 = 0 };

pub fn parseSubeventDataReturn(ret: []const u8) Error!SubeventDataReturn {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .adv_handle = 0 };
    try need(ret, 2);
    if (ret[1] > handle_max) return error.BadHandle;
    return .{ .status = ret[0], .adv_handle = ret[1] };
}

// ---------------------------------------------------------------------------
// §7.8.126 LE Set Periodic Advertising Response Data
// ---------------------------------------------------------------------------

/// §7.8.126 命令编码。参数段：Sync_Handle(2) Request_Event(2) Request_Subevent(1)
/// Response_Subevent(1) Response_Slot(1) Response_Data_Length(1) Response_Data(n)。
/// Request_Event 是对端收到那条 AUX_SYNC_SUBEVENT_IND 的 paEventCounter
/// （§7.8.126 参数表；[Vol 6] Part B §4.4.2.1），整 16 位，没有 Range。
/// Request_Subevent 同样没有 Range（对端 train 的子事件号）。
pub fn cmdSetPeriodicAdvResponseData(
    out: []u8,
    sync_handle: u16,
    request_event: u16,
    request_subevent: u8,
    response_subevent: u8,
    response_slot: u8,
    data: []const u8,
) Error!usize {
    if (sync_handle > sync_handle_max) return error.BadHandle;
    if (response_subevent > subevent_max) return error.BadSubevent;
    if (data.len > data_len_max) return error.BadDataLength;
    const plen = 8 + data.len;
    if (plen > 255) return error.Oversize;
    const total = 4 + plen;
    if (out.len < total) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_set_periodic_adv_response_data, .little);
    out[3] = @intCast(plen);
    std.mem.writeInt(u16, out[4..6], sync_handle, .little);
    std.mem.writeInt(u16, out[6..8], request_event, .little);
    out[8] = request_subevent;
    out[9] = response_subevent;
    out[10] = response_slot;
    out[11] = @intCast(data.len);
    @memcpy(out[12 .. 12 + data.len], data);
    return total;
}

/// §7.8.126 与 §7.8.127 共用的返回参数形状：Status(1) + Sync_Handle(2)。
pub const SyncHandleReturn = struct { status: u8, sync_handle: u16 = 0 };

pub fn parseSyncHandleReturn(ret: []const u8) Error!SyncHandleReturn {
    if (ret.len == 0) return error.Short;
    if (onlyFailure(ret)) |s| return .{ .status = s, .sync_handle = 0 };
    try need(ret, 3);
    const h = std.mem.readInt(u16, ret[1..3], .little);
    if (h > sync_handle_max) return error.BadHandle;
    return .{ .status = ret[0], .sync_handle = h };
}

// ---------------------------------------------------------------------------
// §7.8.127 LE Set Periodic Sync Subevent
// ---------------------------------------------------------------------------

/// §7.8.127 命令编码。参数段：Sync_Handle(2) Periodic_Advertising_Properties(2)
/// Num_Subevents(1) Subevent[i](1 × n)。
/// Properties 只有 bit 6（Include TxPower in the advertising PDU）；原文说其余各位
/// “Reserved for future use”，保留位置位按本组件口径回 0x12（`BadProperties`）。
pub fn cmdSetPeriodicSyncSubevent(
    out: []u8,
    sync_handle: u16,
    properties: u16,
    subevents: []const u8,
) Error!usize {
    if (sync_handle > sync_handle_max) return error.BadHandle;
    if ((properties & ~prop_include_tx_power) != 0) return error.BadProperties;
    if (subevents.len == 0 or subevents.len > train_subevents_max) return error.BadNumSubevents;
    for (subevents) |s| {
        if (s > subevent_max) return error.BadSubevent;
    }
    const plen = 5 + subevents.len;
    if (plen > 255) return error.Oversize;
    const total = 4 + plen;
    if (out.len < total) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_set_periodic_sync_subevent, .little);
    out[3] = @intCast(plen);
    std.mem.writeInt(u16, out[4..6], sync_handle, .little);
    std.mem.writeInt(u16, out[6..8], properties, .little);
    out[8] = @intCast(subevents.len);
    @memcpy(out[9 .. 9 + subevents.len], subevents);
    return total;
}

// ---------------------------------------------------------------------------
// §7.7.65.36 LE Periodic Advertising Subevent Data Request
// ---------------------------------------------------------------------------

/// `params` 是 LE Meta 子事件码之后的那一段。
pub const DataRequest = struct {
    adv_handle: u8,
    /// 本 PAwR event 里第一个被请求的子事件号。
    subevent_start: u8,
    /// 请求的子事件个数（含 start）。
    subevent_data_count: u8,

    /// 请求覆盖的子事件号按 §7.7.65.36 的回绕规则展开
    /// （“The subevent numbers wrap from one less than the number of subevents to
    /// zero”）。`num_subevents` 是这个 train 在 §7.8.61 [v2] 里配置的
    /// Num_Subevents；`out` 至少要装得下 count 个。
    pub fn subevents(self: DataRequest, num_subevents: u8, out: []u8) Error!usize {
        if (num_subevents == 0 or num_subevents > train_subevents_max) return error.BadNumSubevents;
        if (self.subevent_data_count == 0 or self.subevent_data_count > num_subevents) return error.CountExceedsTrain;
        if (out.len < self.subevent_data_count) return error.NoRoom;
        var i: usize = 0;
        while (i < self.subevent_data_count) : (i += 1) {
            out[i] = @intCast((@as(u16, self.subevent_start) + @as(u16, @intCast(i))) % num_subevents);
        }
        return self.subevent_data_count;
    }
};

pub fn decodeDataRequest(params: []const u8) Error!DataRequest {
    try need(params, 3);
    if (params[0] > handle_max) return error.BadHandle;
    if (params[1] > subevent_max) return error.BadSubevent;
    if (params[2] == 0 or params[2] > train_subevents_max) return error.BadNumSubevents;
    return .{ .adv_handle = params[0], .subevent_start = params[1], .subevent_data_count = params[2] };
}

// ---------------------------------------------------------------------------
// §7.7.65.37 LE Periodic Advertising Response Report
// ---------------------------------------------------------------------------

/// CTE_Type（§7.7.65.37 的表）：0x00 / 0x01 / 0x02 是 AoA 与两种 AoD 槽宽，
/// 0xFF 表示没有 Constant Tone Extension；其余保留 → `BadCteType`。
pub const CteType = enum(u8) {
    aoa = 0x00,
    aoa_1us = 0x01,
    aoa_2us = 0x02,
    none = 0xFF,
};

fn cteTypeOf(v: u8) Error!CteType {
    return switch (v) {
        0x00 => .aoa,
        0x01 => .aoa_1us,
        0x02 => .aoa_2us,
        0xFF => .none,
        else => error.BadCteType,
    };
}

/// Data_Status（§7.7.65.37 的表）：一次响应可能被拆成多条报告，除最后一条外都是
/// “incomplete, more data to come”；0xFF 表示没收到 AUX_SYNC_SUBEVENT_RSP PDU；
/// 其余保留 → `BadDataStatus`。
pub const DataStatus = enum(u8) {
    complete = 0x00,
    incomplete_more_to_come = 0x01,
    failed_to_receive = 0xFF,
};

fn dataStatusOf(v: u8) Error!DataStatus {
    return switch (v) {
        0x00 => .complete,
        0x01 => .incomplete_more_to_come,
        0xFF => .failed_to_receive,
        else => error.BadDataStatus,
    };
}

/// 一条响应报告。`data` 指向输入缓冲里的那段字节。
pub const Response = struct {
    tx_power: ?i8,
    rssi: ?i8,
    cte_type: CteType,
    response_slot: u8,
    data_status: DataStatus,
    data: []const u8,
};

/// Tx_Status（§7.7.65.37）：Controller 没发出同步包时用 0x01 告诉 Host；其余保留。
pub const TxStatus = enum(u8) {
    /// AUX_SYNC_SUBEVENT_IND packet was transmitted.
    transmitted = 0x00,
    /// AUX_SYNC_SUBEVENT_IND packet was not transmitted.
    not_transmitted = 0x01,
};

pub const ResponseReport = struct {
    adv_handle: u8,
    subevent: u8,
    tx_status: TxStatus,
    responses: []const Response,
};

/// §7.7.65.37 的事件参数解析。`params` 是子事件码之后的那一段；头部是
/// Advertising_Handle(1) Subevent(1) Tx_Status(1) Num_Responses(1)，随后是逐条目
/// 交错的 TX_Power[i] RSSI[i] CTE_Type[i] Response_Slot[i] Data_Status[i]
/// Data_Length[i] Data[i]（§5.2 的交错规则；Data[i] 变长，长度由 Data_Length[i]
/// 给出）。`out` 至少要装得下 Num_Responses 条；解析出的条目切片指向 `params`。
pub fn decodeResponseReport(params: []const u8, out: []Response) Error!ResponseReport {
    if (params.len < 4) return error.Short;
    if (params[0] > handle_max) return error.BadHandle;
    if (params[1] > subevent_max) return error.BadSubevent;
    const tx_status: TxStatus = switch (params[2]) {
        0x00 => .transmitted,
        0x01 => .not_transmitted,
        else => return error.BadTxStatus,
    };
    const n: usize = params[3];
    if (n > responses_max) return error.BadNumResponses;
    if (out.len < n) return error.NoRoom;
    var p: usize = 4;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // 每条固定部分 6 字节（五个标量 + Data_Length）。
        if (params.len < p + 6) return error.Short;
        const len: usize = params[p + 5];
        if (params.len < p + 6 + len) return error.Short;
        out[i] = .{
            .tx_power = try levelOf(params[p]),
            .rssi = try levelOf(params[p + 1]),
            .cte_type = try cteTypeOf(params[p + 2]),
            .response_slot = params[p + 3],
            .data_status = try dataStatusOf(params[p + 4]),
            .data = params[p + 6 .. p + 6 + len],
        };
        p += 6 + len;
    }
    if (params.len > p) return error.Trailing;
    return .{
        .adv_handle = params[0],
        .subevent = params[1],
        .tx_status = tx_status,
        .responses = out[0..n],
    };
}

/// 完整的 LE Meta 事件分发（04 + 0x3E + 参数长度 + 子事件码 + 参数）。事件码不是
/// 0x3E、子事件码不是 0x27 / 0x28 → `BadParam` / `UnknownSubevent`。
pub const LePawrEvent = union(enum) {
    data_request: DataRequest,
    response_report: ResponseReport,
};

pub fn decodeEvent(frame: []const u8, out: []Response) Error!LePawrEvent {
    if (frame.len < 4 or frame[0] != hci.h4_event) return error.Short;
    if (frame[1] != hci.evt_le_meta) return error.BadParam;
    const total = 3 + @as(usize, frame[2]);
    if (frame.len < total) return error.Short;
    if (frame.len > total) return error.Trailing;
    if (frame[2] == 0) return error.Short;
    return switch (frame[3]) {
        le_subevent_data_request => .{ .data_request = try decodeDataRequest(frame[4..]) },
        le_response_report => .{ .response_report = try decodeResponseReport(frame[4..], out) },
        else => error.UnknownSubevent,
    };
}

// ---------------------------------------------------------------------------
// 链路层：AUX_SYNC_SUBEVENT_IND / RSP 的头（表 2.8 / 表 2.9）
// ---------------------------------------------------------------------------

/// 空口上这两种 PDU 共用 PDU Type 0b0111（§2.3.4 的列表），靠时序区分；这里由
/// 调用方指明按哪张表检查。
pub const Kind = enum { aux_sync_subevent_ind, aux_sync_subevent_rsp };

/// 解一帧 AUX_SYNC_SUBEVENT_IND（表 2.8）或 AUX_SYNC_SUBEVENT_RSP（表 2.9），
/// 检查字段的许可：X 的字段出现 → `FieldNotPermitted`；O 的字段可有可无；
/// 两种表都没有 M 字段。AdvMode 必须 0b00（§2.3.1.9、§2.3.1.10 的第一句 shall）。
/// 字段切分本身复用 `ext_adv.parseExtPdu`（同一张图 2.14 / 2.15 / 2.16–2.19）。
pub fn parseSubeventPdu(kind: Kind, pdu: []const u8) Error!ext_adv.ExtPdu {
    const p = try ext_adv.parseExtPdu(pdu);
    if (p.adv_mode != .non_conn_non_scan) return error.BadAdvMode;
    switch (kind) {
        // 表 2.8：AdvA X TargetA X CTE O ADI O AuxPtr X SyncInfo X TxPower O
        //         ACAD O AdvData O。
        .aux_sync_subevent_ind => {
            if (p.adva != null) return error.FieldNotPermitted;
            if (p.targeta != null) return error.FieldNotPermitted;
            if (p.aux_ptr != null) return error.FieldNotPermitted;
            if (p.sync_info != null) return error.FieldNotPermitted;
        },
        // 表 2.9：AdvA O TargetA X CTE O ADI X AuxPtr X SyncInfo X TxPower O
        //         ACAD O AdvData O。
        .aux_sync_subevent_rsp => {
            if (p.targeta != null) return error.FieldNotPermitted;
            if (p.adi != null) return error.FieldNotPermitted;
            if (p.aux_ptr != null) return error.FieldNotPermitted;
            if (p.sync_info != null) return error.FieldNotPermitted;
        },
    }
    return p;
}

/// §2.3.1.9：“The Advertising SID subfield of the ADI field shall have the same
/// value as that in the superior PDU of this PDU.” 没带 ADI 时不判（ADI 是 O）。
pub fn adiSidMatches(p: ext_adv.ExtPdu, sid: u4) bool {
    const adi = p.adi orelse return true;
    return adi.sid == sid;
}

// ---------------------------------------------------------------------------
// §7.8.127 的子集表示：128 个子事件的位图
// ---------------------------------------------------------------------------

/// 同步侧要听哪些子事件（§7.8.127 的 Subevents 参数）。128 个子事件（§4.4.2.2.4）
/// 一张 u128 位图：bit i 是子事件 i。
pub const SubeventSet = struct {
    bits: u128 = 0,

    pub fn add(self: *SubeventSet, subevent: u8) Error!void {
        if (subevent > subevent_max) return error.BadSubevent;
        self.bits |= @as(u128, 1) << @intCast(subevent);
    }

    pub fn remove(self: *SubeventSet, subevent: u8) Error!void {
        if (subevent > subevent_max) return error.BadSubevent;
        self.bits &= ~(@as(u128, 1) << @intCast(subevent));
    }

    pub fn contains(self: SubeventSet, subevent: u8) bool {
        if (subevent > subevent_max) return false;
        return (self.bits >> @intCast(subevent)) & 1 != 0;
    }

    pub fn count(self: SubeventSet) u8 {
        return @popCount(self.bits);
    }

    /// 从 §7.8.127 的 Subevent[i] 数组建子集。范围检查与命令编码一致。
    pub fn fromSlice(subevents: []const u8) Error!SubeventSet {
        var s = SubeventSet{};
        if (subevents.len == 0 or subevents.len > train_subevents_max) return error.BadNumSubevents;
        for (subevents) |e| try s.add(e);
        return s;
    }

    /// 编回 Subevent[i] 数组（按子事件号升序）。`out` 至少 0x80 字节。
    pub fn toSlice(self: SubeventSet, out: []u8) Error!usize {
        if (out.len < train_subevents_max) return error.NoRoom;
        var n: usize = 0;
        var i: u16 = 0;
        while (i <= subevent_max) : (i += 1) {
            if ((self.bits >> @intCast(i)) & 1 != 0) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        return n;
    }

    /// §7.8.127：“If the Controller is synchronized with any subevents that are not
    /// in the subset of subevents in this command, then the Controller shall no
    /// longer synchronize with those subevents.” 换一次子集时不再同步的那些。
    pub fn removed(self: SubeventSet, next: SubeventSet) SubeventSet {
        return .{ .bits = self.bits & ~next.bits };
    }

    /// 新命令里多出来的那些。
    pub fn added(self: SubeventSet, next: SubeventSet) SubeventSet {
        return .{ .bits = next.bits & ~self.bits };
    }
};

// ---------------------------------------------------------------------------
// 广告侧状态模型：收到请求 → 选条目 → 发 Subevent Data
// ---------------------------------------------------------------------------

/// host 侧的 PAwR 广告台账。只记录 host 能看见的状态（§7.8.61 [v2] 配置、当前
/// 未应答的请求与其中已答过的子事件），不含时序调度。
///
/// 一次 §7.7.65.36 的请求最多覆盖 0x80 个子事件，而 §7.8.125 的每条命令最多带
/// 15 个条目（Num_Subevents 0x01–0x0F），所以答完一次请求通常要发多条命令：原文对
/// host 侧只有两条约束——请求范围外的子事件 Controller 回 0x0C（38271 行）、每个
/// 子事件的数据只发一次（38268 行）。台账按「已答位图」记，全部答完才关请求。
pub const Advertiser = struct {
    /// 0 = 未配置。配置成功后是这个集合的 Advertising_Handle。
    handle: u8 = 0,
    /// §7.8.61 [v2] 的 Num_Subevents；PAwR train 至少 1 个子事件。
    num_subevents: u8 = 0,
    request_active: bool = false,
    request_start: u8 = 0,
    request_count: u8 = 0,
    /// 本次请求已应答的子事件位图：bit i 对应请求展开后的第 i 个子事件号
    /// （(start + i) mod num_subevents）。§7.8.125：每个子事件的数据只发一次。
    answered: u128 = 0,

    /// 按 §7.8.61 [v2] 配一个 PAwR train。参数检查复用 `ext_adv` 的
    /// `PeriodicAdvParams.validate(.v2)`（间隔因子、响应槽关系都在那边）；
    /// Num_Subevents = 0x00 是没有响应的周期广播，不是 PAwR → `NotPawr`。
    pub fn configure(self: *Advertiser, p: ext_adv.PeriodicAdvParams) Error!void {
        try p.validate(.v2);
        if (p.num_subevents == 0) return error.NotPawr;
        self.handle = p.handle;
        self.num_subevents = p.num_subevents;
        self.request_active = false;
        self.answered = 0;
    }

    /// §7.7.65.36：Controller 要数据。请求与台账对得上才收下，并给出这次请求
    /// 覆盖的子事件号列表（回绕）。计数 shall 在 §7.7.65.36（hci.txt 26315 行）：
    /// “The Subevent_Data_Count parameter shall be less than or equal to the number
    /// of subevents.”
    pub fn onDataRequest(self: *Advertiser, req: DataRequest, out: []u8) Error!usize {
        if (self.num_subevents == 0) return error.NotConfigured;
        if (req.adv_handle != self.handle) return error.WrongHandle;
        const n = try req.subevents(self.num_subevents, out);
        self.request_active = true;
        self.request_start = req.subevent_start;
        self.request_count = req.subevent_data_count;
        self.answered = 0;
        return n;
    }

    /// 请求展开后第 i 个位置的子事件号。
    fn positionSubevent(self: *const Advertiser, i: usize) u8 {
        return @intCast((@as(u16, self.request_start) + @as(u16, @intCast(i))) % self.num_subevents);
    }

    /// 这个子事件号在请求覆盖范围内且还没答过吗（回绕展开后的比较）。
    /// 已答过的返回 false——「The data for a subevent shall be transmitted only
    /// once」（§7.8.125，38268 行）。
    pub fn requested(self: *const Advertiser, subevent: u8) bool {
        if (!self.request_active) return false;
        var i: usize = 0;
        while (i < self.request_count) : (i += 1) {
            if (self.positionSubevent(i) == subevent) {
                return (self.answered >> @intCast(i)) & 1 == 0;
            }
        }
        return false;
    }

    /// §7.8.125：按刚收到的请求回数据。每个条目的子事件号必须在请求范围内且未答过
    /// （范围外 → Controller 回 Command Disallowed 0x0C，38271 行；已答过 →
    /// 只发一次的 shall，38268 行），host 侧先拦下来。一条命令最多 15 个条目，
    /// 请求覆盖的子事件全部答完才关请求；没答完前请求保持 pending，可以继续
    /// `respond` 补答。
    pub fn respond(self: *Advertiser, out: []u8, entries: []const SubeventEntry) Error!usize {
        if (!self.request_active) return error.NoRequest;
        // 先整批判完再编码、再记账：拒绝时台账与输出缓冲都不动。
        var newly: u128 = 0;
        for (entries) |e| {
            var i: usize = 0;
            while (i < self.request_count) : (i += 1) {
                if (self.positionSubevent(i) == e.subevent) break;
            } else return error.NotRequested;
            const bit = @as(u128, 1) << @intCast(i);
            if ((self.answered & bit) != 0 or (newly & bit) != 0) return error.AlreadyAnswered;
            newly |= bit;
        }
        const n = try cmdSetPeriodicAdvSubeventData(out, self.handle, entries);
        self.answered |= newly;
        // 请求覆盖的子事件全部答完才关闭。
        if (@popCount(self.answered) >= self.request_count) {
            self.request_active = false;
            self.answered = 0;
        }
        return n;
    }

    /// 仅供测试与调试：当前未应答请求的 (start, count)。
    pub fn pendingRequest(self: *const Advertiser) ?DataRequest {
        if (!self.request_active) return null;
        return .{ .adv_handle = self.handle, .subevent_start = self.request_start, .subevent_data_count = self.request_count };
    }
};
