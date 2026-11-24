//! ble-802154：LE 扩展广播与周期广播（Bluetooth Core 5.4）——只做纯逻辑，不碰射频。
//!
//! 规范出处（条款号与原文一致；HCI 在 [Vol 4] Part E，链路层在 [Vol 6] Part B）：
//!   * HCI_LE_Set_Advertising_Set_Random_Address —— §7.8.52
//!   * HCI_LE_Set_Extended_Advertising_Parameters [v1] / [v2] —— §7.8.53
//!     （v1 的 OCF 是 0x0036；v2 的 OCF 是 0x007F，只在末尾多
//!     Primary_Advertising_PHY_Options、Secondary_Advertising_PHY_Options）
//!   * HCI_LE_Set_Extended_Advertising_Data —— §7.8.54
//!   * HCI_LE_Set_Extended_Scan_Response_Data —— §7.8.55
//!   * HCI_LE_Set_Extended_Advertising_Enable —— §7.8.56
//!   * HCI_LE_Read_Maximum_Advertising_Data_Length —— §7.8.57
//!   * HCI_LE_Read_Number_of_Supported_Advertising_Sets —— §7.8.58
//!   * HCI_LE_Remove_Advertising_Set —— §7.8.59
//!   * HCI_LE_Clear_Advertising_Sets —— §7.8.60
//!   * HCI_LE_Set_Periodic_Advertising_Parameters [v1] / [v2] —— §7.8.61
//!     （OCF 0x003E / 0x0086）
//!   * HCI_LE_Set_Periodic_Advertising_Data —— §7.8.62
//!   * HCI_LE_Set_Periodic_Advertising_Enable —— §7.8.63
//!   * HCI_LE_Set_Extended_Scan_Parameters —— §7.8.64
//!   * HCI_LE_Set_Extended_Scan_Enable —— §7.8.65（只编码命令，不做扫描调度）
//!   * HCI_LE_Periodic_Advertising_Create_Sync / _Create_Sync_Cancel /
//!     _Terminate_Sync —— §7.8.67 / §7.8.68 / §7.8.69
//!   * HCI_LE_Extended_Advertising_Report —— §7.7.65.13
//!   * HCI_LE_Advertising_Set_Terminated —— §7.7.65.18
//!   * 数组参数默认按元素交错 —— §5.2
//!   * Common Extended Advertising Payload Format —— [Vol 6] Part B §2.3.4、图 2.14、
//!     图 2.15、表 2.13、表 2.14；广播信道 PDU 头 —— §2.3、图 2.5、表 2.3
//!   * AdvA / TargetA —— §2.3.4.1 / §2.3.4.2；CTEInfo —— §2.3.4.3 与 §2.5.2、图 2.60、表 2.25
//!   * AdvDataInfo —— §2.3.4.4、图 2.18；AuxPtr —— §2.3.4.5、图 2.19、表 2.15–2.17
//!   * SyncInfo —— §2.3.4.6、图 2.21、表 2.18；TxPower —— §2.3.4.7；ACAD —— §2.3.4.8
//!   * Host 广播数据的分片与 1650 字节总上限 —— §2.3.4.9
//!   * 图里的位序：LSB 在左 —— §1.2
//!
//! 五块内容：
//!
//!   1. **命令编码**（`leSet…`、`leRead…`、`leRemove…`…）：每条命令的参数按原文
//!      参数表的顺序逐字段排，输出完整的 H4 命令帧（01 + OpCode + 长度 + 参数）。
//!      值越界时返回哪个错误见 `Error`；不写半个字节。
//!   2. **广播集状态机**（`Sets`）：host 侧的“广播集台账”。§7.8.52–§7.8.63 里
//!      只取决于 host 可见状态的 “shall return the error code …” 都是一条判据，
//!      `Sets` 在发命令之前先算出 Controller 会回的状态码，成功才改台账；
//!      取决于 Controller 自身能力的那几条见下面的“没有建模的判据”。
//!   3. **事件解析**：LE Extended Advertising Report、LE Advertising Set Terminated。
//!   4. **链路层扩展头解析**（`parseExtPdu`）：只做位图解码与字段切分，不涉及时序。
//!   5. **分片器**（`Fragmenter`）：把一段 host 数据切成 first / intermediate / last /
//!      complete 的 HCI 命令序列（§7.8.54、§7.8.62 的单片上限，[Vol 6] Part B §2.3.4.9
//!      的 1650 字节总上限）。
//!
//! 两处容易读反的地方，都有原文可对：
//!
//!   * LE Extended Advertising Report 的多条报告是**按报告交错**的，不是“所有
//!     Event_Type 在一起、所有 Address 在一起”。参数表里的 “Size: Num_Reports × N
//!     octets” 只是这个数组参数的总长度；§5.2 规定 “unless noted otherwise, the
//!     order of the parameters are as follows: ParameterA[0], ParameterB[0],
//!     ParameterA[1], ParameterB[1] …”，而 legacy 的 LE Advertising Report
//!     （§7.7.65.2）用的是同一种写法、已知是按报告交错的。
//!   * 扩展头里的多字节字段，图上**左边的字段在低位**（§1.2 “In illustrations,
//!     the LSB is shown on the left side”）：AuxPtr 的 Channel Index 在 bit 0–5，
//!     Aux PHY 在 bit 21–23。
//!
//! 与盘上的 NimBLE 交叉核对过的布局（行号为 `grep -n` 实测，IDF v6.1 的
//! components/bt/host/nimble/nimble/nimble/；括号里是结构体或宏名）：
//!   * 命令结构体：include/nimble/hci_common.h:642–645（set_adv_set_rnd_addr_cp）、
//!     648–664 与 1315–1319（set_ext_adv_params_cp / _v2_cp）、666–668（其 _rp）、
//!     671–677（set_ext_adv_data_cp）、680–686（set_ext_scan_rsp_data_cp）、
//!     689–698（adv_set、set_ext_adv_enable_cp）、701–703（rd_max_adv_data_len_rp）、
//!     706–708（rd_num_of_adv_sets_rp）、711–713（remove_adv_set_cp）、
//!     718–723（set_periodic_adv_params_cp）、726–731（set_periodic_adv_data_cp）、
//!     734–737（set_periodic_adv_enable_cp）、740–758（scan_params、
//!     set_ext_scan_params_cp、set_ext_scan_enable_cp）、797–805（create_sync_cp）、
//!     810–812（periodic_adv_term_sync_cp）
//!   * 属性位、分片上限、子事件码：hci_common.h:1905–1917、1921、1923–1927、1930、
//!     1933、1937、2265、2266–2284（ext_adv_report 与事件结构体）、2350
//!   * 报告按记录逐条遍历：host/src/ble_hs_hci_evt.c:1344–1389、1393–1457
//!   * 扩展头的位序：controller/src/ble_ll_adv.c:532–551（AuxPtr）、592–601
//!     （头长度 / AdvMode / 标志位 / ADI）、3587（SID 在 ADI 的高 4 位）；
//!     controller/src/ble_ll_sync.c:929–948（AuxPtr 解包）、1439–1507（SyncInfo 解包，
//!     在 1390–1545 的函数里）与 2168–2211（SyncInfo 打包）；
//!     controller/src/ble_ll_scan_aux.c:838–895（标志位与字段顺序）
//!   * PDU Type 与标志位：controller/include/controller/ble_ll.h:392–399、404–410
//!     （BLE_LL_EXT_ADV_*_BIT：AdvA 在 bit 0 … TxPower 在 bit 6）
//!
//! 没有建模的判据（都取决于 Controller 自己的能力或状态，host 侧算不出来，
//! 测试里也不假装算）：
//!   * Memory Capacity Exceeded / Packet Too Long（辅助包段能装多少、还剩多少内存）：
//!     §7.8.53、§7.8.54、§7.8.56、§7.8.61、§7.8.62、§7.8.63。
//!   * §7.8.56 的 “will not fit in the AUX_ADV_IND PDU” 只判了能从 Length 只有 8 位
//!     推出来的那一段（`connectable_aux_adv_ind_data_max`）；Controller 实际能发的 PDU
//!     比 255 字节短时，中间那一段同样判不了。
//!   * Controller 支持哪些间隔、哪些事件类型、哪些 PHY、哪些 CTE 类型（Unsupported
//!     Feature or Parameter Value 0x11）：§7.8.53、§7.8.61、§7.8.64、§7.8.67。
//!   * Own_Address_Type 0x02 / 0x03 时解析列表里有没有对应项、设备有没有公有地址：
//!     §7.8.56、§7.8.65。
//!   * 扫描、同步那边的时序与调度（扫描是否已使能、是否已有 Create Sync 在等待）：
//!     §7.8.64、§7.8.65、§7.8.67。本文件只编码这几条命令。
//!
//! 原文没写、由实现定下的三处（注释里都标了“推断”）：
//!   * 多条判据同时违反时回哪一个：先看句柄是否存在，再看参数是否合法，再看当前
//!     状态允不允许，最后才算容量（见 `Sets` 的说明）。
//!   * 把已经带着超过 31 字节数据的集合改成 legacy 类型（§7.8.53 的 shall）回 0x12。
//!   * 句柄不存在时 `setRandomAddress` 回 0x42。

const std = @import("std");

const gap = @import("gap_adv.zig");
const hci = @import("hci.zig");

pub const Error = hci.Error || error{
    /// Advertising_Handle 超过 0xEF。
    BadHandle,
    /// Advertising_Event_Properties：保留位置位；legacy 时不在表 7.2 里或 PHY 不是
    /// LE 1M；扩展广播时同时可连接、可扫描，或用了高占空比定向。
    BadProps,
    /// 间隔越界，或 Min > Max。
    BadInterval,
    /// 信道图为 0，或用了 bit 0–2 以外的位。
    BadChannelMap,
    /// 定向广播却没给对端地址。
    BadPeerAddress,
    /// 发射功率不在 −127…+20 dBm。
    BadTxPower,
    /// Advertising_SID 超过 0x0F。
    BadSid,
    /// PHY Options 超过 0x04。
    BadPhyOptions,
    /// 取值不在参数表列出的范围里（扫描类型、过滤策略、PHY 位图等）。
    BadParam,
    /// 这个命令不接受这个 Operation（扫描响应数据没有 0x04）。
    BadOperation,
    /// Enable 的句柄数组里有重复的 Advertising_Handle。
    DuplicateSet,
    /// PAwR 的 Num_Subevents / Subevent_Interval 不满足 §7.8.61 的关系。
    BadSubevents,
    /// PAwR 的 Response_Slot_Delay / Response_Slot_Spacing / Num_Response_Slots
    /// 不满足 §7.8.61 的关系。
    BadResponseSlots,
    /// Create Sync 的 Skip 超过 0x01F3。
    BadSkip,
    /// Create Sync 的 Sync_Timeout 不在 0x000A–0x4000。
    BadTimeout,
    /// Create Sync 的 Sync_CTE_Type 用了 bit 0–4 以外的位。
    BadCteType,
    /// Sync_CTE_Type 的 bit 0–4 全是 1（Controller 会回 Command Disallowed）。
    CteTypeAllExcluded,
    /// Set Extended Scan Enable 的 Duration / Period / Filter_Duplicates 组合不合法。
    BadScanPeriod,
    /// Sync_Handle 超过 0x0EFF。
    BadSyncHandle,
    /// 这个 PDU Type 不用 Common Extended Advertising Payload Format。
    NotExtPdu,
    /// AdvMode 是 0b11（Reserved for future use）。
    BadAdvMode,
    /// Extended Header Flags 的 bit 7 置位（Reserved for future use）。
    ReservedFlag,
    /// Extended Header Length 装不下标志位所指的那几个字段。
    BadHeaderLength,
};

// ---------------------------------------------------------------------------
// OpCode（OCF 取各命令表格；OGF 固定 0x08，见 §7.8 开头）
// ---------------------------------------------------------------------------

fn leOpcode(comptime ocf: u10) u16 {
    return hci.opcode(hci.ogf_le_controller, ocf);
}

/// §7.8.52。
pub const op_le_set_adv_set_random_address: u16 = leOpcode(0x035);
/// §7.8.53 [v1]。
pub const op_le_set_ext_adv_params_v1: u16 = leOpcode(0x036);
/// §7.8.53 [v2]。
pub const op_le_set_ext_adv_params_v2: u16 = leOpcode(0x07f);
/// §7.8.54。
pub const op_le_set_ext_adv_data: u16 = leOpcode(0x037);
/// §7.8.55。
pub const op_le_set_ext_scan_rsp_data: u16 = leOpcode(0x038);
/// §7.8.56。
pub const op_le_set_ext_adv_enable: u16 = leOpcode(0x039);
/// §7.8.57。
pub const op_le_read_max_adv_data_length: u16 = leOpcode(0x03a);
/// §7.8.58。
pub const op_le_read_num_supported_adv_sets: u16 = leOpcode(0x03b);
/// §7.8.59。
pub const op_le_remove_adv_set: u16 = leOpcode(0x03c);
/// §7.8.60。
pub const op_le_clear_adv_sets: u16 = leOpcode(0x03d);
/// §7.8.61 [v1]。
pub const op_le_set_periodic_adv_params_v1: u16 = leOpcode(0x03e);
/// §7.8.61 [v2]（PAwR）。
pub const op_le_set_periodic_adv_params_v2: u16 = leOpcode(0x086);
/// §7.8.62。
pub const op_le_set_periodic_adv_data: u16 = leOpcode(0x03f);
/// §7.8.63。
pub const op_le_set_periodic_adv_enable: u16 = leOpcode(0x040);
/// §7.8.64。
pub const op_le_set_ext_scan_params: u16 = leOpcode(0x041);
/// §7.8.65。
pub const op_le_set_ext_scan_enable: u16 = leOpcode(0x042);
/// §7.8.67。
pub const op_le_periodic_adv_create_sync: u16 = leOpcode(0x044);
/// §7.8.68。
pub const op_le_periodic_adv_create_sync_cancel: u16 = leOpcode(0x045);
/// §7.8.69。
pub const op_le_periodic_adv_terminate_sync: u16 = leOpcode(0x046);

/// LE Meta 子事件码。§7.7.65.13。
pub const le_ext_adv_report: u8 = 0x0D;
/// LE Meta 子事件码。§7.7.65.18。
pub const le_adv_set_terminated: u8 = 0x12;

/// 一条命令由哪种事件报告“已受理”。§4.4。
pub const Expect = enum { command_complete, command_status };

/// 本文件的 OpCode 才有结果；`null` 表示不认识。只有 Create Sync 回 Command
/// Status（§7.8.67），其余都回 Command Complete。
pub fn expects(op: u16) ?Expect {
    return switch (op) {
        op_le_periodic_adv_create_sync => .command_status,
        op_le_set_adv_set_random_address,
        op_le_set_ext_adv_params_v1,
        op_le_set_ext_adv_params_v2,
        op_le_set_ext_adv_data,
        op_le_set_ext_scan_rsp_data,
        op_le_set_ext_adv_enable,
        op_le_read_max_adv_data_length,
        op_le_read_num_supported_adv_sets,
        op_le_remove_adv_set,
        op_le_clear_adv_sets,
        op_le_set_periodic_adv_params_v1,
        op_le_set_periodic_adv_params_v2,
        op_le_set_periodic_adv_data,
        op_le_set_periodic_adv_enable,
        op_le_set_ext_scan_params,
        op_le_set_ext_scan_enable,
        op_le_periodic_adv_create_sync_cancel,
        op_le_periodic_adv_terminate_sync,
        => .command_complete,
        else => null,
    };
}

/// Advertising_Handle 的范围（§7.8.52 起所有带句柄的命令）。
pub const handle_max: u8 = 0xEF;

/// 命令有两个版本（§7.8.53、§7.8.61）：v1 的 OCF 是 5.0 的那个，v2 在末尾多几个参数。
pub const Version = enum { v1, v2 };

// ---------------------------------------------------------------------------
// 1. 命令编码
// ---------------------------------------------------------------------------

/// 带变长尾部的命令（广播数据最长 252 字节）：头段与尾段直接写进 `out`，不在栈上
/// 再拼一份——板侧栈只有 16 KiB。长度检查在写之前，不够就一个字节都不写。
fn packHeadTail(out: []u8, op: u16, head: []const u8, tail: []const u8) Error!usize {
    const plen = head.len + tail.len;
    if (plen > 255) return error.Oversize;
    const total = 4 + plen;
    if (out.len < total) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op, .little);
    out[3] = @intCast(plen);
    @memcpy(out[4 .. 4 + head.len], head);
    @memcpy(out[4 + head.len .. total], tail);
    return total;
}

fn noParams(out: []u8, op: u16) Error!usize {
    return hci.packCommand(out, op, &.{});
}

/// HCI_LE_Set_Advertising_Set_Random_Address：Advertising_Handle(1) +
/// Random_Address(6)。§7.8.52。
pub fn leSetAdvSetRandomAddress(out: []u8, handle: u8, addr: gap.Addr) Error!usize {
    if (handle > handle_max) return error.BadHandle;
    var p: [7]u8 = undefined;
    p[0] = handle;
    @memcpy(p[1..7], &addr.bytes);
    return hci.packCommand(out, op_le_set_adv_set_random_address, &p);
}

/// Advertising_Event_Properties 的 7 个位。§7.8.53；bit 7–15 保留。
pub const Prop = struct {
    pub const connectable: u16 = 1 << 0;
    pub const scannable: u16 = 1 << 1;
    pub const directed: u16 = 1 << 2;
    /// ≤ 3.75 ms 间隔的高占空比定向（只有 legacy 的 ADV_DIRECT_IND 有）。
    pub const high_duty_directed: u16 = 1 << 3;
    pub const legacy: u16 = 1 << 4;
    /// 匿名：所有 PDU 里都不带广播者地址。
    pub const anonymous: u16 = 1 << 5;
    pub const include_tx_power: u16 = 1 << 6;
    pub const mask: u16 = 0x007F;
};

/// 表 7.2：legacy PDU 的五种 Advertising_Event_Properties。
pub const legacy_props = struct {
    /// ADV_IND：可连接、可扫描、无方向。
    pub const adv_ind: u16 = 0b00010011;
    /// ADV_DIRECT_IND（low duty cycle）。
    pub const adv_direct_ind_low: u16 = 0b00010101;
    /// ADV_DIRECT_IND（high duty cycle）。
    pub const adv_direct_ind_high: u16 = 0b00011101;
    /// ADV_SCAN_IND：可扫描、无方向。
    pub const adv_scan_ind: u16 = 0b00010010;
    /// ADV_NONCONN_IND：不可连接、不可扫描、无方向。
    pub const adv_nonconn_ind: u16 = 0b00010000;

    pub fn contains(props: u16) bool {
        return switch (props) {
            adv_ind, adv_direct_ind_low, adv_direct_ind_high, adv_scan_ind, adv_nonconn_ind => true,
            else => false,
        };
    }
};

/// Primary_Advertising_PHY：0x01 LE 1M、0x03 LE Coded。§7.8.53。
pub const PrimaryPhy = enum(u8) { le_1m = 0x01, le_coded = 0x03 };
/// Secondary_Advertising_PHY：0x01 LE 1M、0x02 LE 2M、0x03 LE Coded。§7.8.53。
pub const SecondaryPhy = enum(u8) { le_1m = 0x01, le_2m = 0x02, le_coded = 0x03 };

/// Advertising_SID 的上限。§7.8.53。
pub const sid_max: u8 = 0x0F;
/// Primary_Advertising_Interval 的范围（N × 0.625 ms）。§7.8.53。
pub const interval_lo: u24 = 0x00_0020;
pub const interval_hi: u24 = 0xFF_FFFF;
/// Advertising_TX_Power 的取值范围（dBm）。§7.8.53。
pub const tx_power_min: i8 = -127;
pub const tx_power_max: i8 = 20;

/// HCI_LE_Set_Extended_Advertising_Parameters 的 17 个参数，按 §7.8.53 的顺序。
/// 前 15 个是 v1；后 2 个只在 v2 里发出。
pub const ExtAdvParams = struct {
    handle: u8,
    props: u16 = 0,
    interval_min: u24 = 0x00_0080,
    interval_max: u24 = 0x00_00C0,
    /// bit 0/1/2 对应信道 37/38/39，至少置一位。
    channel_map: u8 = 0x07,
    own_addr_type: gap.OwnAddrType = .public,
    peer_addr_type: gap.Addr.Type = .public,
    peer_addr: gap.Addr = .{},
    filter_policy: gap.AdvFilterPolicy = .all,
    /// null = 0x7F（Host has no preference）。
    tx_power: ?i8 = null,
    primary_phy: PrimaryPhy = .le_1m,
    secondary_max_skip: u8 = 0,
    secondary_phy: SecondaryPhy = .le_1m,
    sid: u8 = 0,
    scan_req_notif: bool = false,
    /// 0x00–0x04（§7.8.53 的 PHY_Options 表）；v1 命令里没有。
    primary_phy_options: u8 = 0,
    secondary_phy_options: u8 = 0,

    pub const packed_len_v1: usize = 25;
    pub const packed_len_v2: usize = 27;

    /// 取值检查，每条对应 §7.8.53 的一句话；返回值说明违反的是哪一条。
    pub fn validate(self: ExtAdvParams, version: Version) Error!void {
        if (self.handle > handle_max) return error.BadHandle;
        // “All other bits: Reserved for future use”
        if ((self.props & ~Prop.mask) != 0) return error.BadProps;
        const directed = (self.props & Prop.directed) != 0;
        const hd = (self.props & Prop.high_duty_directed) != 0;
        if ((self.props & Prop.legacy) != 0) {
            // “the parameter value shall be one of those specified in Table 7.2”
            if (!legacy_props.contains(self.props)) return error.BadProps;
            // “If legacy advertising PDU types are being used, the
            // Primary_Advertising_PHY shall indicate the LE 1M PHY.”
            if (self.primary_phy != .le_1m) return error.BadProps;
        } else {
            // “The advertisement shall not be both connectable and scannable.”
            if ((self.props & Prop.connectable) != 0 and (self.props & Prop.scannable) != 0) {
                return error.BadProps;
            }
            // “High duty cycle directed connectable advertising … shall not be used (bit 3 = 0).”
            if (hd) return error.BadProps;
        }
        // 高占空比定向（ADV_DIRECT_IND）时间歇参数 “are not used and shall be
        // ignored”，所以这里不查。
        if (!hd) {
            if (self.interval_min < interval_lo or self.interval_min > interval_hi or
                self.interval_max < interval_lo or self.interval_max > interval_hi)
            {
                return error.BadInterval;
            }
            // “Primary_Advertising_Interval_Min … shall be less than or equal to … Max”
            if (self.interval_min > self.interval_max) return error.BadInterval;
        }
        // “At least one channel bit shall be set”；只有 bit 0–2 有定义。
        if (self.channel_map == 0 or (self.channel_map & ~@as(u8, 0x07)) != 0) return error.BadChannelMap;
        // “If Directed advertising is selected, the Peer_Address_Type and
        // Peer_Address shall be valid”
        if (directed and std.mem.allEqual(u8, &self.peer_addr.bytes, 0)) return error.BadPeerAddress;
        if (self.tx_power) |v| {
            if (v < tx_power_min or v > tx_power_max) return error.BadTxPower;
        }
        if (self.sid > sid_max) return error.BadSid;
        if (version == .v2) {
            if (self.primary_phy_options > 0x04 or self.secondary_phy_options > 0x04) {
                return error.BadPhyOptions;
            }
        }
    }

    /// 按参数表顺序打包：Handle(1) Properties(2) Interval_Min(3) Interval_Max(3)
    /// Channel_Map(1) Own_Address_Type(1) Peer_Address_Type(1) Peer_Address(6)
    /// Filter_Policy(1) TX_Power(1) Primary_PHY(1) Secondary_Max_Skip(1)
    /// Secondary_PHY(1) SID(1) Scan_Request_Notification_Enable(1)
    /// [Primary_PHY_Options(1) Secondary_PHY_Options(1)]。
    /// v1 只取前 `packed_len_v1` 个字节。
    pub fn pack(self: ExtAdvParams, version: Version, out: *[packed_len_v2]u8) Error!void {
        try self.validate(version);
        out[0] = self.handle;
        std.mem.writeInt(u16, out[1..3], self.props, .little);
        std.mem.writeInt(u24, out[3..6], self.interval_min, .little);
        std.mem.writeInt(u24, out[6..9], self.interval_max, .little);
        out[9] = self.channel_map;
        out[10] = @backingInt(self.own_addr_type);
        out[11] = @backingInt(self.peer_addr_type);
        @memcpy(out[12..18], &self.peer_addr.bytes);
        out[18] = @backingInt(self.filter_policy);
        out[19] = if (self.tx_power) |v| @bitCast(v) else 0x7F;
        out[20] = @backingInt(self.primary_phy);
        out[21] = self.secondary_max_skip;
        out[22] = @backingInt(self.secondary_phy);
        out[23] = self.sid;
        out[24] = @intFromBool(self.scan_req_notif);
        out[25] = self.primary_phy_options;
        out[26] = self.secondary_phy_options;
    }
};

/// HCI_LE_Set_Extended_Advertising_Parameters。§7.8.53。
pub fn leSetExtAdvParams(out: []u8, p: ExtAdvParams, version: Version) Error!usize {
    var buf: [ExtAdvParams.packed_len_v2]u8 = undefined;
    try p.pack(version, &buf);
    const op = if (version == .v2) op_le_set_ext_adv_params_v2 else op_le_set_ext_adv_params_v1;
    const params = if (version == .v2) buf[0..] else buf[0..ExtAdvParams.packed_len_v1];
    return hci.packCommand(out, op, params);
}

/// §7.8.53 的返回参数：Status(1) + Selected_TX_Power(1)。
pub const SelectedTxPower = struct { status: u8, selected_tx_power: i8 = 0 };

/// 解 `leSetExtAdvParams` 的返回参数（已去掉 Num_HCI_Command_Packets 与 OpCode）。
/// 失败时 Controller 可以只回 Status；成功却只有 Status → `Short`。
pub fn parseExtAdvParamsReturn(ret: []const u8) Error!SelectedTxPower {
    if (ret.len == 0) return error.Short;
    if (ret.len == 1) {
        if (ret[0] != 0) return .{ .status = ret[0] };
        return error.Short;
    }
    if (ret.len != 2) return error.Trailing;
    return .{ .status = ret[0], .selected_tx_power = @bitCast(ret[1]) };
}

/// Operation 参数。§7.8.54、§7.8.55（只有 0x00–0x03）、§7.8.62。
pub const Operation = enum(u8) {
    /// 0x00：分片数据的中间一片。
    intermediate = 0x00,
    /// 0x01：分片数据的第一片（已有的数据全部丢弃）。
    first = 0x01,
    /// 0x02：分片数据的最后一片。
    last = 0x02,
    /// 0x03：完整数据（已有的数据全部丢弃）。
    complete = 0x03,
    /// 0x04：数据不变，只让 Controller 更新 Advertising DID。
    unchanged = 0x04,
};

/// Fragment_Preference 参数。§7.8.54、§7.8.55。
pub const FragmentPreference = enum(u8) {
    /// 0x00：Controller 可以随便分片。
    may_fragment = 0x00,
    /// 0x01：Controller 不该分片，或尽量少分。
    minimize_fragmentation = 0x01,
};

/// §7.8.54 / §7.8.55 的 Advertising_Data_Length、Scan_Response_Data_Length：0–251。
pub const adv_fragment_max: usize = 251;
/// §7.8.62 的 Advertising_Data_Length：0–252（比扩展广播多 1 个字节）。
pub const periodic_fragment_max: usize = 252;
/// 分片之前 Host 广播数据的总上限：[Vol 6] Part B §2.3.4.9 “shall not exceed 1650
/// octets”；也是 §7.8.57 里 Max_Advertising_Data_Length 的范围上限 0x0672。
pub const adv_data_total_max: usize = 1650;

/// 这一段数据是哪一种：广播数据还是扫描响应数据（两者的 Controller 判据不同）。
pub const DataKind = enum { adv, scan_rsp };

fn encodeFragment(out: []u8, op: u16, kind: DataKind, handle: u8, operation: Operation, pref: FragmentPreference, data: []const u8) Error!usize {
    if (handle > handle_max) return error.BadHandle;
    // §7.8.55：扫描响应数据的 Operation 只有 0x00–0x03。
    if (kind == .scan_rsp and operation == .unchanged) return error.BadOperation;
    if (data.len > adv_fragment_max) return error.Oversize;
    const head = [4]u8{ handle, @backingInt(operation), @backingInt(pref), @intCast(data.len) };
    return packHeadTail(out, op, &head, data);
}

/// HCI_LE_Set_Extended_Advertising_Data：Advertising_Handle(1) + Operation(1) +
/// Fragment_Preference(1) + Advertising_Data_Length(1) + Advertising_Data。§7.8.54。
pub fn leSetExtAdvData(out: []u8, handle: u8, op: Operation, pref: FragmentPreference, data: []const u8) Error!usize {
    return encodeFragment(out, op_le_set_ext_adv_data, .adv, handle, op, pref, data);
}

/// HCI_LE_Set_Extended_Scan_Response_Data：Handle(1) + Operation(1) +
/// Fragment_Preference(1) + Scan_Response_Data_Length(1) + Scan_Response_Data。
/// §7.8.55。
pub fn leSetExtScanRspData(out: []u8, handle: u8, op: Operation, pref: FragmentPreference, data: []const u8) Error!usize {
    return encodeFragment(out, op_le_set_ext_scan_rsp_data, .scan_rsp, handle, op, pref, data);
}

/// §7.8.56 里每个集合的三元组：Advertising_Handle(1) + Duration(2，N × 10 ms) +
/// Max_Extended_Advertising_Events(1，0 表示不限)。
pub const EnableSet = struct { handle: u8, duration: u16 = 0, max_events: u8 = 0 };

/// Num_Sets 的范围（§7.8.56：0x01–0x3F）。
pub const num_sets_max: usize = 0x3F;

/// HCI_LE_Set_Extended_Advertising_Enable：Enable(1) + Num_Sets(1)，然后每个集合
/// 依次是 Advertising_Handle(1) + Duration(2) + Max_Extended_Advertising_Events(1)
/// （§5.2 的交错顺序）。`enable` 为 false 且 `sets` 为空就是 “all advertising sets
/// are disabled”。§7.8.56。
pub fn leSetExtAdvEnable(out: []u8, enable: bool, sets: []const EnableSet) Error!usize {
    if (sets.len > num_sets_max) return error.BadParam;
    // “If Num_Sets is set to 0x00, the Controller shall return the error code
    // Invalid HCI Command Parameters”
    if (enable and sets.len == 0) return error.BadParam;
    for (sets, 0..) |a, i| {
        if (a.handle > handle_max) return error.BadHandle;
        for (sets[i + 1 ..]) |b| {
            // “If the same advertising set is identified by more than one entry …”
            if (a.handle == b.handle) return error.DuplicateSet;
        }
    }
    var buf: [2 + 4 * num_sets_max]u8 = undefined;
    buf[0] = @intFromBool(enable);
    buf[1] = @intCast(sets.len);
    for (sets, 0..) |s, i| {
        const o = 2 + 4 * i;
        buf[o] = s.handle;
        std.mem.writeInt(u16, buf[o + 1 ..][0..2], s.duration, .little);
        buf[o + 3] = s.max_events;
    }
    return hci.packCommand(out, op_le_set_ext_adv_enable, buf[0 .. 2 + 4 * sets.len]);
}

/// HCI_LE_Read_Maximum_Advertising_Data_Length：无命令参数。§7.8.57。
pub fn leReadMaxAdvDataLength(out: []u8) Error!usize {
    return noParams(out, op_le_read_max_adv_data_length);
}

/// HCI_LE_Read_Number_of_Supported_Advertising_Sets：无命令参数。§7.8.58。
pub fn leReadNumSupportedAdvSets(out: []u8) Error!usize {
    return noParams(out, op_le_read_num_supported_adv_sets);
}

/// HCI_LE_Remove_Advertising_Set：Advertising_Handle(1)。§7.8.59。
pub fn leRemoveAdvSet(out: []u8, handle: u8) Error!usize {
    if (handle > handle_max) return error.BadHandle;
    return hci.packCommand(out, op_le_remove_adv_set, &[_]u8{handle});
}

/// HCI_LE_Clear_Advertising_Sets：无命令参数。§7.8.60。
pub fn leClearAdvSets(out: []u8) Error!usize {
    return noParams(out, op_le_clear_adv_sets);
}

/// 成功时必须带满返回参数；失败时 Controller 可以只回 Status。
fn needReturn(ret: []const u8, n: usize) Error!void {
    if (ret.len == n) return;
    if (ret.len == 1 and ret[0] != 0) return;
    if (ret.len < n) return error.Short;
    return error.Trailing;
}

/// §7.8.57 的返回参数：Status(1) + Max_Advertising_Data_Length(2，0x001F–0x0672)。
pub const MaxAdvDataLength = struct { status: u8, max: u16 = 0 };

pub fn parseReadMaxAdvDataLength(ret: []const u8) Error!MaxAdvDataLength {
    if (ret.len == 0) return error.Short;
    try needReturn(ret, 3);
    if (ret.len == 1) return .{ .status = ret[0] };
    return .{ .status = ret[0], .max = std.mem.readInt(u16, ret[1..3], .little) };
}

/// §7.8.58 的返回参数：Status(1) + Num_Supported_Advertising_Sets(1，0x01–0xF0)。
pub const NumAdvSets = struct { status: u8, num: u8 = 0 };

pub fn parseReadNumSupportedAdvSets(ret: []const u8) Error!NumAdvSets {
    if (ret.len == 0) return error.Short;
    try needReturn(ret, 2);
    if (ret.len == 1) return .{ .status = ret[0] };
    return .{ .status = ret[0], .num = ret[1] };
}

/// HCI_LE_Set_Periodic_Advertising_Parameters 的 9 个参数，按 §7.8.61 的顺序。
/// 前 4 个是 v1（7 字节）；后 5 个是 PAwR 的，只在 v2 里发出（共 12 字节）。
pub const PeriodicAdvParams = struct {
    handle: u8,
    /// N × 1.25 ms，0x0006–0xFFFF。
    interval_min: u16 = 0x0080,
    interval_max: u16 = 0x00C0,
    /// Periodic_Advertising_Properties 的 bit 6：Include TxPower in the advertising PDU。
    include_tx_power: bool = false,
    /// 0x00–0x80；0x00 时后面四个参数都被 Controller 忽略。
    num_subevents: u8 = 0,
    /// N × 1.25 ms，0x06–0xFF。
    subevent_interval: u8 = 0,
    /// N × 1.25 ms，0x01–0xFE。
    response_slot_delay: u8 = 0,
    /// N × 0.125 ms，0x02–0xFF。
    response_slot_spacing: u8 = 0,
    /// 0x01–0xFF；0x00 时前面两个参数都被 Controller 忽略。
    num_response_slots: u8 = 0,

    pub const packed_len_v1: usize = 7;
    pub const packed_len_v2: usize = 12;
    pub const interval_lo: u16 = 0x0006;
    pub const prop_include_tx_power: u16 = 1 << 6;

    /// 取值检查，每条对应 §7.8.61 的一句话。v2 的几个参数之间的关系（子事件间隔、
    /// 响应槽的延迟与间隔）只在 `version == .v2` 时检查。
    pub fn validate(self: PeriodicAdvParams, version: Version) Error!void {
        if (self.handle > handle_max) return error.BadHandle;
        if (self.interval_min < PeriodicAdvParams.interval_lo or self.interval_max < PeriodicAdvParams.interval_lo or
            self.interval_min > self.interval_max) return error.BadInterval;
        if (version == .v1) return;
        if (self.num_subevents > 0x80) return error.BadSubevents;
        // “If the Num_Subevents parameter value is 0x00, then the Subevent_Interval,
        // Response_Slot_Delay, Response_Slot_Spacing, and Num_Response_Slots
        // parameters shall be ignored.”
        if (self.num_subevents == 0) return;
        if (self.subevent_interval < 0x06) return error.BadSubevents;
        // “The Subevent_Interval shall be less than or equal to the
        // Periodic_Advertising_Interval_Min divided by the Num_Subevents”
        if (@as(u32, self.subevent_interval) * @as(u32, self.num_subevents) > @as(u32, self.interval_min)) {
            return error.BadSubevents;
        }
        // “If the Num_Response_Slots parameter value is 0x00, then the
        // Response_Slot_Delay and Response_Slot_Spacing parameters shall be ignored.”
        if (self.num_response_slots == 0) return;
        if (self.response_slot_delay == 0x00 or self.response_slot_delay == 0xFF) return error.BadResponseSlots;
        // “The Response_Slot_Delay shall be less than the Subevent_Interval.”
        if (self.response_slot_delay >= self.subevent_interval) return error.BadResponseSlots;
        // “If the Num_Response_Slots parameter is set to 1, then the Controller shall
        // ignore the Response_Slot_Spacing parameter.” 所以下面两条都不看它。
        if (self.num_response_slots == 1) return;
        if (self.response_slot_spacing < 0x02) return error.BadResponseSlots;
        // “The Response_Slot_Spacing shall be less than or equal to
        // 10 × (Subevent_Interval - Response_Slot_Delay) / Num_Response_Slots.”
        // 乘 10 把 1.25 ms 换成 0.125 ms；写成乘法，避开整数除法的舍入。
        if (@as(u32, self.response_slot_spacing) * @as(u32, self.num_response_slots) >
            10 * (@as(u32, self.subevent_interval) - @as(u32, self.response_slot_delay)))
        {
            return error.BadResponseSlots;
        }
    }

    /// 按参数表顺序打包：Handle(1) Interval_Min(2) Interval_Max(2) Properties(2)
    /// [Num_Subevents(1) Subevent_Interval(1) Response_Slot_Delay(1)
    /// Response_Slot_Spacing(1) Num_Response_Slots(1)]。
    pub fn pack(self: PeriodicAdvParams, version: Version, out: *[packed_len_v2]u8) Error!void {
        try self.validate(version);
        out[0] = self.handle;
        std.mem.writeInt(u16, out[1..3], self.interval_min, .little);
        std.mem.writeInt(u16, out[3..5], self.interval_max, .little);
        std.mem.writeInt(u16, out[5..7], if (self.include_tx_power) prop_include_tx_power else 0, .little);
        out[7] = self.num_subevents;
        out[8] = self.subevent_interval;
        out[9] = self.response_slot_delay;
        out[10] = self.response_slot_spacing;
        out[11] = self.num_response_slots;
    }
};

/// HCI_LE_Set_Periodic_Advertising_Parameters。§7.8.61。
pub fn leSetPeriodicAdvParams(out: []u8, p: PeriodicAdvParams, version: Version) Error!usize {
    var buf: [PeriodicAdvParams.packed_len_v2]u8 = undefined;
    try p.pack(version, &buf);
    const op = if (version == .v2) op_le_set_periodic_adv_params_v2 else op_le_set_periodic_adv_params_v1;
    const params = if (version == .v2) buf[0..] else buf[0..PeriodicAdvParams.packed_len_v1];
    return hci.packCommand(out, op, params);
}

/// §7.8.61 的返回参数：v1 只有 Status；v2 是 Status(1) + Advertising_Handle(1)。
pub const PeriodicParamsReturn = struct { status: u8, handle: u8 = 0 };

pub fn parsePeriodicAdvParamsReturn(ret: []const u8, version: Version) Error!PeriodicParamsReturn {
    if (ret.len == 0) return error.Short;
    if (ret.len == 1) {
        if (ret[0] != 0) return .{ .status = ret[0] };
        if (version == .v2) return error.Short;
        return .{ .status = 0 };
    }
    if (version == .v1 or ret.len != 2) return error.Trailing;
    return .{ .status = ret[0], .handle = ret[1] };
}

/// HCI_LE_Set_Periodic_Advertising_Data：Advertising_Handle(1) + Operation(1) +
/// Advertising_Data_Length(1，0–252) + Advertising_Data。没有 Fragment_Preference。
/// §7.8.62。
pub fn leSetPeriodicAdvData(out: []u8, handle: u8, op: Operation, data: []const u8) Error!usize {
    if (handle > handle_max) return error.BadHandle;
    if (data.len > periodic_fragment_max) return error.Oversize;
    const head = [3]u8{ handle, @backingInt(op), @intCast(data.len) };
    return packHeadTail(out, op_le_set_periodic_adv_data, &head, data);
}

/// HCI_LE_Set_Periodic_Advertising_Enable：Enable(1：bit 0 使能、bit 1 在
/// AUX_SYNC_IND 里带 ADI) + Advertising_Handle(1)。§7.8.63。
pub fn leSetPeriodicAdvEnable(out: []u8, enable: bool, include_adi: bool, handle: u8) Error!usize {
    if (handle > handle_max) return error.BadHandle;
    const bits: u8 = @as(u8, @intFromBool(enable)) | (@as(u8, @intFromBool(include_adi)) << 1);
    return hci.packCommand(out, op_le_set_periodic_adv_enable, &[_]u8{ bits, handle });
}

/// HCI_LE_Set_Extended_Scan_Parameters 里每个 PHY 的三元组：Scan_Type(1) +
/// Scan_Interval(2) + Scan_Window(2)。§7.8.64。
pub const ScanPhy = struct {
    /// false = 0x00 被动扫描，true = 0x01 主动扫描。
    active: bool = false,
    /// 0x0004–0xFFFF，N × 0.625 ms。
    interval: u16 = 0x0010,
    /// 0x0004–0xFFFF，N × 0.625 ms。
    window: u16 = 0x0010,

    const wire_len: usize = 5;
    const range_lo: u16 = 0x0004;

    fn validate(self: ScanPhy) Error!void {
        if (self.interval < range_lo or self.window < range_lo) return error.BadParam;
    }
};

/// HCI_LE_Set_Extended_Scan_Parameters 的 6 个参数，按 §7.8.64 的顺序。
/// Scanning_PHYs 只有 bit 0（LE 1M）与 bit 2（LE Coded）；数组元素按置位的顺序
/// 排列（从 bit 0 起），所以 LE 1M 的三元组在 LE Coded 的前面。
pub const ExtScanParams = struct {
    own_addr_type: gap.OwnAddrType = .public,
    /// 0x00 Basic unfiltered、0x01 Basic filtered、0x02 Extended unfiltered、
    /// 0x03 Extended filtered。
    filter_policy: u8 = 0x00,
    /// null 表示不在 LE 1M PHY 上扫描。
    le_1m: ?ScanPhy = .{},
    /// null 表示不在 LE Coded PHY 上扫描。
    le_coded: ?ScanPhy = null,

    pub const packed_len_max: usize = 3 + 2 * ScanPhy.wire_len;

    /// 至少要有一个 PHY；过滤策略只有 0x00–0x03。
    pub fn validate(self: ExtScanParams) Error!void {
        if (self.filter_policy > 0x03) return error.BadParam;
        if (self.le_1m == null and self.le_coded == null) return error.BadParam;
        if (self.le_1m) |p| try p.validate();
        if (self.le_coded) |p| try p.validate();
    }

    /// 返回写入的字节数。
    pub fn pack(self: ExtScanParams, out: *[packed_len_max]u8) Error!usize {
        try self.validate();
        out[0] = @backingInt(self.own_addr_type);
        out[1] = self.filter_policy;
        out[2] = (if (self.le_1m != null) @as(u8, 0x01) else 0) |
            (if (self.le_coded != null) @as(u8, 0x04) else 0);
        var n: usize = 3;
        for ([2]?ScanPhy{ self.le_1m, self.le_coded }) |maybe| {
            if (maybe) |p| {
                out[n] = @intFromBool(p.active);
                std.mem.writeInt(u16, out[n + 1 ..][0..2], p.interval, .little);
                std.mem.writeInt(u16, out[n + 3 ..][0..2], p.window, .little);
                n += ScanPhy.wire_len;
            }
        }
        return n;
    }
};

/// HCI_LE_Set_Extended_Scan_Parameters：Own_Address_Type(1) +
/// Scanning_Filter_Policy(1) + Scanning_PHYs(1) + {Scan_Type(1) Scan_Interval(2)
/// Scan_Window(2)}[每个置位的 PHY]。§7.8.64。
pub fn leSetExtScanParams(out: []u8, p: ExtScanParams) Error!usize {
    var buf: [ExtScanParams.packed_len_max]u8 = undefined;
    const n = try p.pack(&buf);
    return hci.packCommand(out, op_le_set_ext_scan_params, buf[0..n]);
}

/// Filter_Duplicates 参数。§7.8.65。
pub const FilterDuplicates = enum(u8) {
    /// 0x00：不过滤。
    disabled = 0x00,
    /// 0x01：过滤，直到扫描被关闭。
    enabled = 0x01,
    /// 0x02：过滤，每个扫描周期重置；只在 Period 与 Duration 都非零时合法。
    enabled_per_period = 0x02,
};

/// HCI_LE_Set_Extended_Scan_Enable：Enable(1) + Filter_Duplicates(1) +
/// Duration(2，N × 10 ms) + Period(2，N × 1.28 s)。§7.8.65。
pub fn leSetExtScanEnable(out: []u8, enable: bool, filter: FilterDuplicates, duration: u16, period: u16) Error!usize {
    // “If it [Enable] is set to 0x00, the remaining parameters shall be ignored.”
    if (enable) {
        // “If Filter_Duplicates is set to 0x02 and either Period or Duration to
        // zero, the Controller shall return the error code Invalid HCI Command
        // Parameters (0x12).”
        if (filter == .enabled_per_period and (duration == 0 or period == 0)) return error.BadScanPeriod;
        // “If both the Duration and Period parameters are non-zero and the
        // Duration is greater than or equal to the Period, … (0x12).”
        if (duration != 0 and period != 0 and duration >= period) return error.BadScanPeriod;
    }
    var buf: [6]u8 = undefined;
    buf[0] = @intFromBool(enable);
    buf[1] = @backingInt(filter);
    std.mem.writeInt(u16, buf[2..4], duration, .little);
    std.mem.writeInt(u16, buf[4..6], period, .little);
    return hci.packCommand(out, op_le_set_ext_scan_enable, &buf);
}

/// Create Sync 的 Options 参数的三个位。§7.8.67。
pub const CreateSyncOptions = struct {
    /// bit 0：用 Periodic Advertiser List 决定听谁（此时 SID 与地址被忽略）。
    use_periodic_advertiser_list: bool = false,
    /// bit 1：上报一开始是关闭的。
    reporting_disabled: bool = false,
    /// bit 2：重复过滤一开始是打开的。
    filter_duplicates: bool = false,

    fn bits(self: CreateSyncOptions) u8 {
        return @as(u8, @intFromBool(self.use_periodic_advertiser_list)) |
            (@as(u8, @intFromBool(self.reporting_disabled)) << 1) |
            (@as(u8, @intFromBool(self.filter_duplicates)) << 2);
    }
};

/// HCI_LE_Periodic_Advertising_Create_Sync 的 7 个参数，按 §7.8.67 的顺序。
/// 回 Command Status，没有返回参数。
pub const CreateSync = struct {
    options: CreateSyncOptions = .{},
    /// Advertising_SID：0x00–0x0F。
    sid: u8 = 0,
    advertiser_addr_type: gap.Addr.Type = .public,
    advertiser_addr: gap.Addr = .{},
    /// 0x0000–0x01F3。
    skip: u16 = 0,
    /// N × 10 ms，0x000A–0x4000。
    sync_timeout: u16 = 0x0010,
    /// bit 0–4 各排除一种 Constant Tone Extension；全 1 不合法。
    sync_cte_type: u8 = 0,

    pub const packed_len: usize = 14;
    pub const skip_max: u16 = 0x01F3;
    pub const timeout_lo: u16 = 0x000A;
    pub const timeout_hi: u16 = 0x4000;

    pub fn validate(self: CreateSync) Error!void {
        if (self.sid > sid_max) return error.BadSid;
        if (self.skip > skip_max) return error.BadSkip;
        if (self.sync_timeout < timeout_lo or self.sync_timeout > timeout_hi) return error.BadTimeout;
        if ((self.sync_cte_type & ~@as(u8, 0x1F)) != 0) return error.BadCteType;
        // “If the Host sets all the non-reserved bits of the Sync_CTE_Type
        // parameter to 1, the Controller shall return the error code Command
        // Disallowed (0x0C).”
        if (self.sync_cte_type == 0x1F) return error.CteTypeAllExcluded;
    }
};

/// HCI_LE_Periodic_Advertising_Create_Sync：Options(1) + Advertising_SID(1) +
/// Advertiser_Address_Type(1) + Advertiser_Address(6) + Skip(2) + Sync_Timeout(2) +
/// Sync_CTE_Type(1)。§7.8.67。
pub fn lePeriodicAdvCreateSync(out: []u8, p: CreateSync) Error!usize {
    try p.validate();
    var buf: [CreateSync.packed_len]u8 = undefined;
    buf[0] = p.options.bits();
    buf[1] = p.sid;
    buf[2] = @backingInt(p.advertiser_addr_type);
    @memcpy(buf[3..9], &p.advertiser_addr.bytes);
    std.mem.writeInt(u16, buf[9..11], p.skip, .little);
    std.mem.writeInt(u16, buf[11..13], p.sync_timeout, .little);
    buf[13] = p.sync_cte_type;
    return hci.packCommand(out, op_le_periodic_adv_create_sync, &buf);
}

/// HCI_LE_Periodic_Advertising_Create_Sync_Cancel：无命令参数。§7.8.68。
pub fn lePeriodicAdvCreateSyncCancel(out: []u8) Error!usize {
    return noParams(out, op_le_periodic_adv_create_sync_cancel);
}

/// HCI_LE_Periodic_Advertising_Terminate_Sync：Sync_Handle(2，只有低 12 位有意义)。
/// §7.8.69。
pub fn lePeriodicAdvTerminateSync(out: []u8, sync_handle: u16) Error!usize {
    if (sync_handle > 0x0EFF) return error.BadSyncHandle;
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, sync_handle, .little);
    return hci.packCommand(out, op_le_periodic_adv_terminate_sync, &buf);
}

// ---------------------------------------------------------------------------
// 3. 事件解析
// ---------------------------------------------------------------------------

/// Data status：Event_Type 的 bit 5–6。§7.7.65.13。
pub const DataStatus = enum(u2) {
    /// 0b00：Complete。
    complete = 0b00,
    /// 0b01：Incomplete, more data to come。
    incomplete = 0b01,
    /// 0b10：Incomplete, data truncated, no more to come。
    truncated = 0b10,
    /// 0b11：Reserved for future use。
    reserved = 0b11,
};

/// TX_Power / RSSI 的 “not available” 哨兵值。§7.7.65.13。
pub const power_not_available: i8 = 0x7F;
/// Advertising_SID 的 “No ADI field provided”。§7.7.65.13。
pub const sid_none: u8 = 0xFF;
/// Address_Type 的 “No address provided (anonymous advertisement)”。§7.7.65.13。
pub const addr_type_anonymous: u8 = 0xFF;

/// LE Extended Advertising Report 的一条报告，字段顺序同 §7.7.65.13。`data`
/// 指向输入的那段字节。
pub const ExtAdvReport = struct {
    event_type: u16,
    addr_type: u8,
    addr: [6]u8,
    primary_phy: u8,
    secondary_phy: u8,
    /// 0x00–0x0F；0xFF 表示没有 ADI 字段。
    sid: u8,
    tx_power: i8,
    rssi: i8,
    /// N × 1.25 ms；0 表示没有周期广播。
    periodic_interval: u16,
    direct_addr_type: u8,
    direct_addr: [6]u8,
    data: []const u8,

    // Event_Type 的位。§7.7.65.13。
    const bit_connectable: u16 = 1 << 0;
    const bit_scannable: u16 = 1 << 1;
    const bit_directed: u16 = 1 << 2;
    const bit_scan_response: u16 = 1 << 3;
    const bit_legacy: u16 = 1 << 4;

    pub fn connectable(self: ExtAdvReport) bool {
        return (self.event_type & bit_connectable) != 0;
    }

    pub fn scannable(self: ExtAdvReport) bool {
        return (self.event_type & bit_scannable) != 0;
    }

    pub fn directed(self: ExtAdvReport) bool {
        return (self.event_type & bit_directed) != 0;
    }

    /// bit 3：这是一条扫描响应，bit 0–2 与 bit 4 描述的是原来的广播事件。
    pub fn scanResponse(self: ExtAdvReport) bool {
        return (self.event_type & bit_scan_response) != 0;
    }

    /// bit 4：用的是 legacy 广播 PDU。
    pub fn legacy(self: ExtAdvReport) bool {
        return (self.event_type & bit_legacy) != 0;
    }

    pub fn dataStatus(self: ExtAdvReport) DataStatus {
        return @fromBackingInt(@intCast(@as(u2, @truncate(self.event_type >> 5))));
    }

    pub fn hasAdi(self: ExtAdvReport) bool {
        return self.sid != sid_none;
    }

    pub fn txPowerAvailable(self: ExtAdvReport) bool {
        return self.tx_power != power_not_available;
    }

    pub fn rssiAvailable(self: ExtAdvReport) bool {
        return self.rssi != power_not_available;
    }

    pub fn anonymous(self: ExtAdvReport) bool {
        return self.addr_type == addr_type_anonymous;
    }

    /// legacy 广播（bit 4 = 1）时，Event_Type 应是表 7.1 里的六个值之一：
    /// 0x13 ADV_IND、0x15 ADV_DIRECT_IND、0x12 ADV_SCAN_IND、0x10 ADV_NONCONN_IND、
    /// 0x1B SCAN_RSP to ADV_IND、0x1A SCAN_RSP to ADV_SCAN_IND。
    pub fn legacyTypeOk(self: ExtAdvReport) bool {
        if (!self.legacy()) return true;
        return switch (self.event_type) {
            0x13, 0x15, 0x12, 0x10, 0x1B, 0x1A => true,
            else => false,
        };
    }

    /// “If the Event_Type indicates a legacy PDU (bit 4 = 1), the Primary_PHY
    /// parameter shall indicate the LE 1M PHY and the Secondary_PHY parameter
    /// shall be set to 0x00.”
    pub fn legacyPhyOk(self: ExtAdvReport) bool {
        if (!self.legacy()) return true;
        return self.primary_phy == 0x01 and self.secondary_phy == 0x00;
    }

    /// §7.7.65.13 的 Primary_PHY / Secondary_PHY 取值表：0x01、0x03，再加
    /// 0x04 —— 它只在 Controller 支持 Advertising Coding Selection (Host Support)
    /// 时是 “LE Coded with S=2”，否则是保留值。
    pub fn primaryPhyOk(self: ExtAdvReport, coding_selection: bool) bool {
        return phyValueOk(self.primary_phy, coding_selection);
    }

    /// Secondary_PHY 自己的取值表（§7.7.65.13）：0x00 “No packets on the secondary
    /// advertising physical channel”、0x01 LE 1M、0x02 LE 2M、0x03 LE Coded，再加 0x04
    /// （只在支持 Advertising Coding Selection 时是 LE Coded S=2）。比 Primary_PHY
    /// 多 0x00 与 0x02。
    pub fn secondaryPhyOk(self: ExtAdvReport, coding_selection: bool) bool {
        return switch (self.secondary_phy) {
            0x00, 0x01, 0x02, 0x03 => true,
            0x04 => coding_selection,
            else => false,
        };
    }

    /// Address_Type：0x00–0x03，或 0xFF（匿名广播）。
    pub fn addrTypeOk(self: ExtAdvReport) bool {
        return self.addr_type <= 0x03 or self.addr_type == addr_type_anonymous;
    }

    /// Direct_Address_Type：0x00–0x03，或 0xFE（Controller 解析不了）。
    pub fn directAddrTypeOk(self: ExtAdvReport) bool {
        return self.direct_addr_type <= 0x03 or self.direct_addr_type == 0xFE;
    }

    /// Advertising_SID：0x00–0x0F，或 0xFF（没有 ADI 字段）。
    pub fn sidOk(self: ExtAdvReport) bool {
        return self.sid <= sid_max or self.sid == sid_none;
    }

    /// Periodic_Advertising_Interval：0x0000（没有周期广播）或 0x0006–0xFFFF。
    pub fn periodicIntervalOk(self: ExtAdvReport) bool {
        return self.periodic_interval == 0 or self.periodic_interval >= 0x0006;
    }
};

/// §7.7.65.13 的 PHY 取值表（Primary_PHY 与 Secondary_PHY 共用）：0x01 LE 1M、
/// 0x03 LE Coded（S=8，或不区分编码时统称 LE Coded）、0x04 LE Coded S=2（仅在
/// 支持 Advertising Coding Selection 时），其余保留。
fn phyValueOk(v: u8, coding_selection: bool) bool {
    return switch (v) {
        0x01, 0x03 => true,
        0x04 => coding_selection,
        else => false,
    };
}

/// 一条报告里定长部分的字节数（不含 Data）：2+1+6+1+1+1+1+1+2+1+6+1。
pub const ext_adv_record_len: usize = 24;
/// Num_Reports 的范围上限（§7.7.65.13：0x01–0x0A）。
pub const ext_adv_reports_max: usize = 0x0A;
/// Data_Length 的范围上限（§7.7.65.13：0 to 229）。
pub const ext_adv_data_max: usize = 229;

fn decodeExtAdvRecord(rec: []const u8) ExtAdvReport {
    return .{
        .event_type = std.mem.readInt(u16, rec[0..2], .little),
        .addr_type = rec[2],
        .addr = rec[3..9].*,
        .primary_phy = rec[9],
        .secondary_phy = rec[10],
        .sid = rec[11],
        .tx_power = @bitCast(rec[12]),
        .rssi = @bitCast(rec[13]),
        .periodic_interval = std.mem.readInt(u16, rec[14..16], .little),
        .direct_addr_type = rec[16],
        .direct_addr = rec[17..23].*,
        .data = rec[24..],
    };
}

/// 解 LE Extended Advertising Report 的 Num_Reports 与各条报告（`body` 从
/// Num_Reports 开始，不含子事件码）。每条报告是一段连续的 24 字节定长部分加
/// Data_Length 个字节的数据；`out` 放解出的报告，返回其中有效的那一段。
/// Num_Reports 为 0 或超过 0x0A → `BadParam`；Data_Length 超过 229 → `Oversize`。
pub fn decodeExtAdvReports(body: []const u8, out: []ExtAdvReport) Error![]const ExtAdvReport {
    if (body.len < 1) return error.Short;
    const n: usize = body[0];
    if (n == 0 or n > ext_adv_reports_max) return error.BadParam;
    if (out.len < n) return error.NoSpace;
    var rest = body[1..];
    for (0..n) |i| {
        if (rest.len < ext_adv_record_len) return error.Short;
        const dlen: usize = rest[ext_adv_record_len - 1];
        if (dlen > ext_adv_data_max) return error.Oversize;
        const size = ext_adv_record_len + dlen;
        if (rest.len < size) return error.Short;
        out[i] = decodeExtAdvRecord(rest[0..size]);
        rest = rest[size..];
    }
    if (rest.len != 0) return error.Trailing;
    return out[0..n];
}

/// LE Advertising Set Terminated 的四个参数，顺序同 §7.7.65.18。
pub const AdvSetTerminated = struct {
    /// 0x00 = 因为建立了连接；0x3C = Duration 到期；0x43 = 达到
    /// Max_Extended_Advertising_Events。
    status: u8,
    adv_handle: u8,
    /// 只有因为建立连接而结束时才有意义；只有低 12 位有意义。
    conn_handle: u16,
    /// Enable 时没给 Max_Extended_Advertising_Events 的话应为 0。
    num_events: u8,
};

/// 解 LE Advertising Set Terminated 的参数（`body` 不含子事件码，恰好 5 字节）。
pub fn decodeAdvSetTerminated(body: []const u8) Error!AdvSetTerminated {
    if (body.len < 5) return error.Short;
    if (body.len > 5) return error.Trailing;
    return .{
        .status = body[0],
        .adv_handle = body[1],
        .conn_handle = std.mem.readInt(u16, body[2..4], .little),
        .num_events = body[4],
    };
}

/// LE Advertising Set Terminated 的三种正常结束原因（§7.7.65.18）。
pub const Termination = enum {
    /// Status 0x00：可连接的广播建立了连接。
    connection_created,
    /// Status 0x3C：Duration 到期。
    duration_expired,
    /// Status 0x43：发完了 Max_Extended_Advertising_Events。
    max_events_reached,
};

/// 把 Status 映射成结束原因；不是这三种 → null。
pub fn terminationOf(status: u8) ?Termination {
    return switch (status) {
        0x00 => .connection_created,
        0x3C => .duration_expired,
        0x43 => .max_events_reached,
        else => null,
    };
}

/// LE Meta 事件经本文件能解出的那两种子事件；其余的子事件码原样交给调用方。
pub const LeEvent = union(enum) {
    ext_adv_report: []const ExtAdvReport,
    adv_set_terminated: AdvSetTerminated,
    other: u8,
};

/// 解一段 LE Meta 事件参数（`params` 从子事件码开始）。`out` 是报告的存放处。
pub fn decodeLeMetaEvent(params: []const u8, out: []ExtAdvReport) Error!LeEvent {
    if (params.len < 1) return error.Short;
    switch (params[0]) {
        le_ext_adv_report => return .{ .ext_adv_report = try decodeExtAdvReports(params[1..], out) },
        le_adv_set_terminated => return .{ .adv_set_terminated = try decodeAdvSetTerminated(params[1..]) },
        else => return .{ .other = params[0] },
    }
}

/// 解一帧完整的 H4 事件（04 + 0x3E + 长度 + 参数）。不是 LE Meta → `UnsupportedEvent`。
pub fn decodeEvent(frame: []const u8, out: []ExtAdvReport) Error!LeEvent {
    var stats: hci.Stats = .{};
    const ev = try hci.decodeEventFrame(frame, &stats);
    if (ev.code != hci.evt_le_meta) return error.UnsupportedEvent;
    return decodeLeMetaEvent(ev.params, out);
}

// ---------------------------------------------------------------------------
// 2. 广播集状态机
// ---------------------------------------------------------------------------

/// Controller 的状态码（[Vol 1] Part F 的错误码表，只列这里用到的；括号里的值取自
/// 各条 HCI 命令正文）。
pub const Code = enum(u8) {
    success = 0x00,
    /// Memory Capacity Exceeded。
    memory_capacity_exceeded = 0x07,
    /// Command Disallowed。
    command_disallowed = 0x0C,
    /// Invalid HCI Command Parameters。
    invalid_hci_command_parameters = 0x12,
    /// Advertising Timeout（Duration 到期）。
    advertising_timeout = 0x3C,
    /// Limit Reached（达到了 Max_Extended_Advertising_Events）。
    limit_reached = 0x43,
    /// Unknown Advertising Identifier。
    unknown_advertising_identifier = 0x42,
    /// Packet Too Long。
    packet_too_long = 0x45,
    _,
};

/// 高占空比定向广播的 Duration 上限：1.28 s，单位 10 ms。§7.8.56。
pub const hd_directed_duration_max: u16 = 128;

/// 可连接的扩展广播集在 AUX_ADV_IND 里最多能装的广播数据：255（Length 是 8 位）− 1
/// （AdvMode 与 Extended Header Length）− 1（Flags）− 6（AdvA）− 2（ADI）。超过它就是
/// §7.8.56 的 “will not fit in the AUX_ADV_IND PDU”；必带字段见 [Vol 6] Part B 表 2.5。
pub const connectable_aux_adv_ind_data_max: usize = 245;

fn isLegacy(props: u16) bool {
    return (props & Prop.legacy) != 0;
}

/// 这个广播集类型能不能带广播数据。legacy 看表 7.2（ADV_DIRECT_IND 那两行是
/// “Not allowed”）；扩展广播的可扫描事件类型在 ADV_EXT_IND 与 AUX_ADV_IND 里都
/// 没有 AdvData（[Vol 6] Part B 表 2.4、表 2.5 的 Adv Data 一栏是 X），数据走扫描响应。
pub fn advDataSupported(props: u16) bool {
    if (isLegacy(props)) return switch (props) {
        legacy_props.adv_ind, legacy_props.adv_scan_ind, legacy_props.adv_nonconn_ind => true,
        else => false,
    };
    return (props & Prop.scannable) == 0;
}

/// 这个广播集类型能不能带扫描响应数据：可扫描的才行。
pub fn scanRspSupported(props: u16) bool {
    return (props & Prop.scannable) != 0;
}

/// 周期广播不能挂在可连接、可扫描、legacy 或匿名的广播集上。§7.8.61、§7.8.63。
fn periodicAllowed(props: u16) bool {
    const forbidden = Prop.connectable | Prop.scannable | Prop.legacy | Prop.anonymous;
    return (props & forbidden) == 0;
}

/// 一段数据（广播 / 扫描响应 / 周期广播）在台账里的样子：只记长度，不存内容。
pub const Data = struct {
    len: u16 = 0,
    /// true：分片还没收齐（最后一片还没到）。
    partial: bool = false,
};

pub const Set = struct {
    used: bool = false,
    enabled: bool = false,
    props: u16 = 0,
    duration: u16 = 0,
    max_events: u8 = 0,
    adv: Data = .{},
    scan_rsp: Data = .{},
    /// 最近一次 Set Parameters 给的 Secondary_Advertising_PHY 与 Own_Address_Type。
    /// 前者对应 §7.8.53 的 “PHY currently being used for the periodic
    /// advertising”，后者是 §7.8.56 随机地址判据的前提。
    secondary_phy: u8 = 0,
    own_addr_type: u8 = 0,
    /// 这个集合的随机地址已经由 HCI_LE_Set_Advertising_Set_Random_Address 给过。
    /// §7.8.56。
    random_addr_set: bool = false,
    periodic_configured: bool = false,
    /// HCI_LE_Set_Periodic_Advertising_Enable 的 bit 0。
    periodic_enabled: bool = false,
    /// 周期广播已经在发。§7.8.63：“If the advertising set is not currently
    /// enabled …, the periodic advertising is not started until the advertising
    /// set is enabled. Once the advertising set has been enabled, the Controller
    /// shall continue periodic advertising until the Host issues … with bit 0 of
    /// Enable set to 0.” 所以集合之后被关掉也不清这一位，只有关周期广播或
    /// 删集合才清。
    periodic_running: bool = false,
    periodic: Data = .{},
};

/// 广播集台账：最多 `max_sets` 个集合，句柄就是下标。每个方法算出 Controller 会回
/// 的状态码；返回 `success` 时台账已更新，返回其它值时台账不变——只有一个例外：
/// 合并后的数据超过容量时原文要求 “all the data shall be discarded”，这时数据被清空。
///
/// 原文没有规定多条判据同时违反时先报哪一个。这里固定为：先看句柄是否存在，
/// 再按参数是否合法，再看当前状态允不允许，最后才算容量。
pub fn Sets(comptime max_sets: usize) type {
    return struct {
        sets: [max_sets]Set = @splat(.{}),
        /// §7.8.57 的 Max_Advertising_Data_Length：Controller 的能力，范围 0x001F–0x0672。
        capacity: u16 = adv_data_total_max,

        const Self = @This();

        pub fn init(capacity: u16) Self {
            return .{ .capacity = capacity };
        }

        fn at(self: *const Self, handle: u8) ?*const Set {
            if (handle >= max_sets) return null;
            if (!self.sets[handle].used) return null;
            return &self.sets[handle];
        }

        fn atMut(self: *Self, handle: u8) ?*Set {
            if (handle >= max_sets) return null;
            if (!self.sets[handle].used) return null;
            return &self.sets[handle];
        }

        /// 只读地看一个集合；不存在返回 null。
        pub fn get(self: *const Self, handle: u8) ?*const Set {
            return self.at(handle);
        }

        /// 已经创建的集合个数。
        pub fn usedCount(self: *const Self) usize {
            var n: usize = 0;
            for (&self.sets) |*s| {
                if (s.used) n += 1;
            }
            return n;
        }

        /// HCI_LE_Set_Extended_Advertising_Parameters：不存在的句柄会被创建。
        /// §7.8.53。
        pub fn setParams(self: *Self, p: ExtAdvParams) Code {
            if (p.handle >= max_sets) {
                // 句柄不在这个台账里，也没有空位了 → Memory Capacity Exceeded。
                return .memory_capacity_exceeded;
            }
            const s = &self.sets[p.handle];
            // “If the Host issues this command when advertising is enabled for the
            // specified advertising set, … Command Disallowed (0x0C).”
            if (s.used and s.enabled) return .command_disallowed;
            // “… when periodic advertising is enabled for the specified advertising set
            // and connectable, scannable, legacy, or anonymous advertising is
            // specified, … Invalid HCI Command Parameters (0x12).”
            if (s.used and s.periodic_enabled and !periodicAllowed(p.props)) {
                return .invalid_hci_command_parameters;
            }
            if (s.used and s.periodic_enabled and
                @backingInt(p.secondary_phy) != s.secondary_phy)
            {
                // “If periodic advertising is enabled for the advertising set and the
                // Secondary_Advertising_PHY parameter does not specify the PHY
                // currently being used for the periodic advertising, … Command
                // Disallowed (0x0C).” “正在用的 PHY” 取最近一次成功设置的值。
                return .command_disallowed;
            }
            if (s.used and isLegacy(p.props)) {
                // “If the advertising set already contains data, the type shall be one
                // that supports advertising data and the amount of data shall not
                // exceed 31 octets.” 前半句违反时按下面那句回 0x12；后半句没写
                // 回什么，这里同样回 0x12（推断）。
                const has_data = s.adv.len != 0 or s.scan_rsp.len != 0;
                if (has_data and !advDataSupported(p.props)) return .invalid_hci_command_parameters;
                if (s.adv.len > gap.adv_data_max or s.scan_rsp.len > gap.adv_data_max) {
                    return .invalid_hci_command_parameters;
                }
            }
            s.used = true;
            s.props = p.props;
            s.secondary_phy = @backingInt(p.secondary_phy);
            s.own_addr_type = @backingInt(p.own_addr_type);
            return .success;
        }

        /// HCI_LE_Set_Advertising_Set_Random_Address。§7.8.52。只记“已经给过”，
        /// 不存地址本身。
        pub fn setRandomAddress(self: *Self, handle: u8) Code {
            // 原文只说这条命令 “may be issued at any time after an advertising set
            // … has been created”，没写句柄不存在时回什么；按惯例回 0x42（推断）。
            const s = self.atMut(handle) orelse return .unknown_advertising_identifier;
            // “… if the Host issues this command while the advertising set … is using
            // connectable advertising and is enabled, … Command Disallowed (0x0C).”
            if (s.enabled and (s.props & Prop.connectable) != 0) return .command_disallowed;
            s.random_addr_set = true;
            return .success;
        }

        /// HCI_LE_Set_Extended_Advertising_Data（`kind == .adv`，§7.8.54）或
        /// HCI_LE_Set_Extended_Scan_Response_Data（`kind == .scan_rsp`，§7.8.55）。
        /// `data_len` 是这一片携带的字节数。
        pub fn setData(self: *Self, handle: u8, kind: DataKind, op: Operation, data_len: usize) Code {
            const s = self.atMut(handle) orelse return .unknown_advertising_identifier;
            const d = if (kind == .adv) &s.adv else &s.scan_rsp;
            const legacy = isLegacy(s.props);
            // Advertising_Data_Length 的取值表是 “0 to 251”，其余是保留值 → 0x12。
            if (data_len > adv_fragment_max) return .invalid_hci_command_parameters;
            if (kind == .adv) {
                // “If the advertising set specifies a type that does not support
                // advertising data, … (0x12).”
                if (!advDataSupported(s.props)) return .invalid_hci_command_parameters;
                // “… uses legacy advertising PDUs that support advertising data and either
                // Operation is not 0x03 or the Advertising_Data_Length parameter exceeds 31
                // octets, … (0x12).”
                if (legacy and (op != .complete or data_len > gap.adv_data_max)) {
                    return .invalid_hci_command_parameters;
                }
                // “If Operation is 0x04 and: advertising is currently disabled …; the
                // advertising set contains no data; the advertising set uses legacy PDUs;
                // or Advertising_Data_Length is not zero; then … (0x12).”
                if (op == .unchanged) {
                    if (!s.enabled or d.len == 0 or legacy or data_len != 0) {
                        return .invalid_hci_command_parameters;
                    }
                }
            } else {
                // §7.8.55 的 Operation 取值表只到 0x03（0x04 只属于广播数据），
                // 其余是 “Reserved for future use”，同样回 0x12。
                if (op == .unchanged) return .invalid_hci_command_parameters;
                // “If the advertising set is non-scannable and the Host uses this command
                // other than to discard existing data, … (0x12).”
                const discard = op == .complete and data_len == 0;
                if (!scanRspSupported(s.props) and !discard) return .invalid_hci_command_parameters;
                // “… uses scannable legacy advertising PDUs and either Operation is not 0x03
                // or the Scan_Response_Data_Length parameter exceeds 31 octets, … (0x12).”
                if (legacy and (op != .complete or data_len > gap.adv_data_max)) {
                    return .invalid_hci_command_parameters;
                }
            }
            // “If Operation is not 0x03 or 0x04 and Advertising_Data_Length is zero, … (0x12).”
            if (op != .complete and op != .unchanged and data_len == 0) {
                return .invalid_hci_command_parameters;
            }
            // “If advertising is currently enabled … and Operation does not have the value
            // 0x03 or 0x04, … Command Disallowed (0x0C).”
            if (s.enabled and op != .complete and op != .unchanged) return .command_disallowed;
            // “If the advertising set uses scannable extended advertising PDUs, advertising is
            // currently enabled …, and Scan_Response_Data_Length is zero, … (0x0C).” 只说
            // 可扫描的扩展广播：不可扫描的集合清空扫描响应数据是允许的丢弃。
            if (kind == .scan_rsp and s.enabled and !legacy and scanRspSupported(s.props) and data_len == 0) {
                return .command_disallowed;
            }
            if (op == .unchanged) return .success;
            return merge(d, op, data_len, self.capacity);
        }

        /// HCI_LE_Set_Periodic_Advertising_Parameters：广播集必须已经存在。
        /// §7.8.61。
        pub fn setPeriodicParams(self: *Self, p: PeriodicAdvParams) Code {
            const s = self.atMut(p.handle) orelse return .unknown_advertising_identifier;
            // “If the advertising set … specified scannable, connectable, legacy, or
            // anonymous advertising, … (0x12).”
            if (!periodicAllowed(s.props)) return .invalid_hci_command_parameters;
            // “If the Host issues this command when periodic advertising is enabled for the
            // specified advertising set, … (0x0C).”
            if (s.periodic_enabled) return .command_disallowed;
            s.periodic_configured = true;
            return .success;
        }

        /// HCI_LE_Set_Periodic_Advertising_Data。§7.8.62。
        pub fn setPeriodicData(self: *Self, handle: u8, op: Operation, data_len: usize) Code {
            // 原文先写 “has not been configured for periodic advertising … (0x0C)”，后写
            // “does not exist … (0x42)”；句柄不存在时两者都成立，这里取更具体的 0x42。
            const s = self.atMut(handle) orelse return .unknown_advertising_identifier;
            if (!s.periodic_configured) return .command_disallowed;
            // §7.8.62 的 Advertising_Data_Length 取值表是 “0 to 252”，其余是保留值 → 0x12。
            if (data_len > periodic_fragment_max) return .invalid_hci_command_parameters;
            // “If Operation is 0x04 and: periodic advertising is currently disabled …; the
            // periodic advertising set contains no data; or Advertising_Data_Length is not
            // zero; then … (0x12).”
            if (op == .unchanged) {
                if (!s.periodic_enabled or s.periodic.len == 0 or data_len != 0) {
                    return .invalid_hci_command_parameters;
                }
            }
            // “If Operation is not 0x03 or 0x04 and Advertising_Data_Length is zero, … (0x12).”
            if (op != .complete and op != .unchanged and data_len == 0) {
                return .invalid_hci_command_parameters;
            }
            // “If periodic advertising is currently enabled … and Operation does not have
            // the value 0x03 or 0x04, … Command Disallowed (0x0C).”
            if (s.periodic_enabled and op != .complete and op != .unchanged) return .command_disallowed;
            if (op == .unchanged) return .success;
            return merge(&s.periodic, op, data_len, self.capacity);
        }

        /// HCI_LE_Set_Extended_Advertising_Enable。§7.8.56。`enable` 为 false 且
        /// `list` 为空表示关闭全部集合。先整体检查，任何一条不过就一个都不改。
        pub fn enable(self: *Self, on: bool, list: []const EnableSet) Code {
            if (list.len > num_sets_max) return .invalid_hci_command_parameters;
            // “If Num_Sets is set to 0x00, the Controller shall return … (0x12).”
            if (on and list.len == 0) return .invalid_hci_command_parameters;
            for (list, 0..) |a, i| {
                for (list[i + 1 ..]) |b| {
                    // “If the same advertising set is identified by more than one entry … (0x12).”
                    if (a.handle == b.handle) return .invalid_hci_command_parameters;
                }
            }
            for (list) |e| {
                // “If the advertising set corresponding to the Advertising_Handle[i]
                // parameter does not exist, … Unknown Advertising Identifier (0x42).”
                const s = self.at(e.handle) orelse return .unknown_advertising_identifier;
                if (!on) continue;
                // “If the advertising set contains partial advertising data or partial scan
                // response data, … Command Disallowed (0x0C).”
                if (s.adv.partial or s.scan_rsp.partial) return .command_disallowed;
                // “If the advertising set uses scannable extended advertising PDUs and no
                // scan response data is currently provided, … (0x0C).”
                if (!isLegacy(s.props) and scanRspSupported(s.props) and s.scan_rsp.len == 0) {
                    return .command_disallowed;
                }
                // “If the advertising set uses connectable extended advertising PDUs and
                // the advertising data in the advertising set will not fit in the
                // AUX_ADV_IND PDU, … (0x12).” 可连接的 AUX_ADV_IND 必带 AdvA 与 ADI、
                // 不带 AuxPtr（[Vol 6] Part B 表 2.5），而 Length 只有 8 位（载荷 ≤ 255，
                // §2.3）：广播数据超过 245 字节（定向再减 6）时一定装不下。TxPower 是在
                // “at least one advertising PDU” 里带，不一定落在 AUX_ADV_IND 上，所以不
                // 再减。Controller 实际能发的 PDU 可能比 255 短，那一段这里判不了。
                if ((s.props & Prop.connectable) != 0 and !isLegacy(s.props)) {
                    const targeta: usize = if ((s.props & Prop.directed) != 0) 6 else 0;
                    if (s.adv.len > connectable_aux_adv_ind_data_max - targeta) {
                        return .invalid_hci_command_parameters;
                    }
                }
                // “If the advertising is high duty cycle connectable directed advertising,
                // then Duration[i] shall be less than or equal to 1.28 seconds and shall
                // not be equal to 0.”
                const hd = (s.props & Prop.high_duty_directed) != 0;
                if (hd and (e.duration == 0 or e.duration > hd_directed_duration_max)) {
                    return .invalid_hci_command_parameters;
                }
                // “If the advertising set's Own_Address_Type parameter is set to 0x01
                // and the random address for the advertising set has not been
                // initialized using the HCI_LE_Set_Advertising_Set_Random_Address
                // command, … Invalid HCI Command Parameters (0x12).”
                if (s.own_addr_type == 0x01 and !s.random_addr_set) {
                    return .invalid_hci_command_parameters;
                }
            }
            if (!on and list.len == 0) {
                // “If Enable and Num_Sets are both set to 0x00, then all advertising sets
                // are disabled.”
                for (&self.sets) |*s| s.enabled = false;
                return .success;
            }
            for (list) |e| {
                const s = &self.sets[e.handle];
                // “Disabling the advertising set … does not disable any periodic advertising
                // associated with that set.”
                s.enabled = on;
                if (on) {
                    s.duration = e.duration;
                    s.max_events = e.max_events;
                    // “If the advertising set is not currently enabled …, the periodic
                    // advertising is not started until the advertising set is enabled.”
                    if (s.periodic_enabled) s.periodic_running = true;
                }
            }
            return .success;
        }

        /// HCI_LE_Set_Periodic_Advertising_Enable。§7.8.63。
        pub fn periodicEnable(self: *Self, on: bool, handle: u8) Code {
            const s = self.atMut(handle) orelse return .unknown_advertising_identifier;
            if (!on) {
                s.periodic_enabled = false;
                s.periodic_running = false;
                return .success;
            }
            // “… contains partial periodic advertising data, … Command Disallowed (0x0C).”
            if (s.periodic.partial) return .command_disallowed;
            // “… has not issued the HCI_LE_Set_Periodic_Advertising_Parameters command …,
            // the Controller shall either use vendor-specified parameters or return …
            // (0x0C).” 这里取 0x0C。
            if (!s.periodic_configured) return .command_disallowed;
            // “… the advertising set identified by the Advertising_Handle specified
            // scannable, connectable, legacy, or anonymous advertising, … (0x0C).”
            if (!periodicAllowed(s.props)) return .command_disallowed;
            s.periodic_enabled = true;
            // “Once the advertising set has been enabled, the Controller shall continue
            // periodic advertising until … bit 0 of Enable set to 0.”
            if (s.enabled) s.periodic_running = true;
            return .success;
        }

        /// HCI_LE_Remove_Advertising_Set。§7.8.59。
        pub fn remove(self: *Self, handle: u8) Code {
            const s = self.atMut(handle) orelse return .unknown_advertising_identifier;
            // “If advertising or periodic advertising on the advertising set is enabled,
            // … Command Disallowed (0x0C).”
            if (s.enabled or s.periodic_enabled) return .command_disallowed;
            // “… The data shall be discarded when the advertising set is removed.”
            s.* = .{};
            return .success;
        }

        /// HCI_LE_Clear_Advertising_Sets。§7.8.60。
        pub fn clear(self: *Self) Code {
            for (&self.sets) |*s| {
                // “If advertising or periodic advertising is enabled on any advertising set,
                // … Command Disallowed (0x0C).”
                if (s.used and (s.enabled or s.periodic_enabled)) return .command_disallowed;
            }
            self.sets = @splat(.{});
            return .success;
        }

        /// 收到 LE Advertising Set Terminated：这个集合不再广播。§7.7.65.18。
        pub fn onSetTerminated(self: *Self, ev: AdvSetTerminated) Code {
            const s = self.atMut(ev.adv_handle) orelse return .unknown_advertising_identifier;
            // 这个事件 “shall not be generated if the Host disables the advertising
            // set”，所以没在广播的集合收到它就是 Controller 出错了。
            if (!s.enabled) return .command_disallowed;
            // “If the Max_Extended_Advertising_Events parameter … was non-zero, … shall
            // be set to the number of completed extended advertising events the
            // Controller had transmitted when either the duration elapsed or the
            // maximum number of extended advertising events was reached; otherwise it
            // shall be set to zero.” 所以只有 0x3C / 0x43 两种结束原因可以带非零
            // 的事件数。
            const counted = ev.status == @backingInt(Code.advertising_timeout) or
                ev.status == @backingInt(Code.limit_reached);
            if (!counted and ev.num_events != 0) return .invalid_hci_command_parameters;
            // 没给过 Max_Extended_Advertising_Events，就不可能是因为“达到了上限”而结束。
            if (ev.status == @backingInt(Code.limit_reached) and s.max_events == 0) {
                return .invalid_hci_command_parameters;
            }
            s.enabled = false;
            return .success;
        }

        /// 合并一片数据。“If the combined length of the data exceeds the capacity …,
        /// all the data shall be discarded and the Controller shall return … Memory
        /// Capacity Exceeded (0x07).”
        fn merge(d: *Data, op: Operation, data_len: usize, capacity: u16) Code {
            // “If Operation indicates the start of new data (values 0x01 or 0x03), then
            // any existing partial or complete … data shall be discarded.”
            const base: usize = if (op == .first or op == .complete) 0 else d.len;
            const total = base + data_len;
            if (total > capacity) {
                d.* = .{};
                return .memory_capacity_exceeded;
            }
            d.len = @intCast(total);
            d.partial = op == .first or op == .intermediate;
            return .success;
        }
    };
}

// ---------------------------------------------------------------------------
// 数据分片
// ---------------------------------------------------------------------------

/// 一段数据放在哪一种命令里：扩展广播 / 扫描响应数据的单条上限是 251，周期广播
/// 数据是 252。
pub const FragmentKind = enum {
    adv,
    periodic,

    pub fn chunkMax(kind: FragmentKind) usize {
        return if (kind == .adv) adv_fragment_max else periodic_fragment_max;
    }
};

pub const Fragment = struct { op: Operation, data: []const u8 };

/// 把一段 Host 数据切成 HCI 命令序列：不超过单片上限的一片 `complete`；更长的
/// 依次是 `first`、若干 `intermediate`、`last`，每片装满为止（片数最少）。
/// 空数据给出唯一一片空的 `complete`——这是“把数据清掉”的写法（§7.8.54：complete
/// 且长度为 0 是合法的，合并后长度为 0 就是没有数据）。总长超过 1650 → `Oversize`。
pub const Fragmenter = struct {
    data: []const u8,
    rest: []const u8,
    kind: FragmentKind,
    done: bool = false,

    pub fn init(kind: FragmentKind, data: []const u8) Error!Fragmenter {
        // [Vol 6] Part B §2.3.4.9：分片前的总长不得超过 1650 字节。
        if (data.len > adv_data_total_max) return error.Oversize;
        return .{ .data = data, .rest = data, .kind = kind };
    }

    pub fn count(self: Fragmenter) usize {
        if (self.data.len == 0) return 1;
        return (self.data.len + self.kind.chunkMax() - 1) / self.kind.chunkMax();
    }

    pub fn next(self: *Fragmenter) ?Fragment {
        if (self.done) return null;
        const chunk = self.kind.chunkMax();
        const first = self.rest.len == self.data.len;
        const left = self.rest.len;
        const n = @min(left, chunk);
        const op: Operation = if (left <= chunk)
            (if (first) .complete else .last)
        else
            (if (first) .first else .intermediate);
        const frag = Fragment{ .op = op, .data = self.rest[0..n] };
        self.rest = self.rest[n..];
        // 最后一片交出去之后才算用完；只看 rest 是否清空，不看本片有多长
        // （`complete` 与 `last` 都可能是空片）。
        self.done = self.rest.len == 0;
        return frag;
    }
};

// ---------------------------------------------------------------------------
// 4. 链路层：扩展广播 PDU 的解析
// ---------------------------------------------------------------------------

/// 用 Common Extended Advertising Payload Format 的 PDU Type（表 2.3）：
/// 0b0111 是 ADV_EXT_IND、AUX_ADV_IND、AUX_SCAN_RSP、AUX_SYNC_IND、AUX_CHAIN_IND
/// 等，0b1000 是 AUX_CONNECT_RSP。
pub const pdu_type_ext: u4 = 0b0111;
pub const pdu_type_aux_connect_rsp: u4 = 0b1000;

/// 广播信道 PDU 头的 16 位（图 2.5，LSB 在左）：PDU Type(4) RFU(1) ChSel(1)
/// TxAdd(1) RxAdd(1)，然后 Length(8)。
pub const AdvPduHeader = struct {
    pdu_type: u4,
    ch_sel: bool,
    /// AdvA 是随机地址（§2.3.4.1）。
    tx_add: bool,
    /// TargetA 是随机地址（§2.3.4.2）。
    rx_add: bool,
    /// 载荷的字节数，1–255。
    length: u8,

    pub fn decode(b: []const u8) Error!AdvPduHeader {
        if (b.len < 2) return error.Short;
        return .{
            .pdu_type = @truncate(b[0]),
            .ch_sel = (b[0] & 0x20) != 0,
            .tx_add = (b[0] & 0x40) != 0,
            .rx_add = (b[0] & 0x80) != 0,
            .length = b[1],
        };
    }
};

/// Extended Header Flags 的七个位（表 2.14）；bit 7 保留。字段在扩展头里的先后
/// 顺序同这七个位。
pub const HeaderFlag = struct {
    pub const adva: u8 = 1 << 0;
    pub const targeta: u8 = 1 << 1;
    pub const cte_info: u8 = 1 << 2;
    pub const adi: u8 = 1 << 3;
    pub const aux_ptr: u8 = 1 << 4;
    pub const sync_info: u8 = 1 << 5;
    pub const tx_power: u8 = 1 << 6;
    pub const all: u8 = 0x7F;
};

/// AdvMode 字段（表 2.13）。
pub const AdvMode = enum(u2) {
    /// 0b00：不可连接、不可扫描。
    non_conn_non_scan = 0b00,
    /// 0b01：可连接、不可扫描。
    conn_non_scan = 0b01,
    /// 0b10：不可连接、可扫描。
    non_conn_scan = 0b10,
};

/// 带类型位的 6 字节地址（最低有效字节在前）。
pub const Addr6 = struct { bytes: [6]u8, random: bool };

/// CTEInfo（图 2.60）：CTETime 是 CTE 的长度，单位 8 µs，取值 2–20；CTEType
/// 见表 2.25。
pub const CteInfo = struct {
    time: u5,
    cte_type: u2,
    /// CTE 的长度，单位 µs。
    pub fn durationUs(self: CteInfo) u32 {
        return @as(u32, self.time) * 8;
    }
    /// §2.5.2：“The value of the CTETime field shall be between 2 and 20”。
    pub fn timeOk(self: CteInfo) bool {
        return self.time >= 2 and self.time <= 20;
    }

    /// 表 2.25：0b00 AoA、0b01 AoD（1 µs 槽）、0b10 AoD（2 µs 槽）、0b11 保留。
    pub fn typeOk(self: CteInfo) bool {
        return self.cte_type != 0b11;
    }
};

/// AdvDataInfo（图 2.18）：DID 在低 12 位，SID 在高 4 位。
pub const Adi = struct {
    did: u12,
    sid: u4,
};

/// AuxPtr（图 2.19）。
pub const AuxPtr = struct {
    /// 辅助包所在的数据信道索引（0–36）。
    channel: u6,
    /// 广播者的时钟精度：0 = 51–500 ppm，1 = 0–50 ppm（表 2.17）。
    ca: u1,
    /// 0 = Aux Offset 的单位是 30 µs，1 = 300 µs（表 2.15）。
    offset_units: u1,
    offset: u13,
    /// 表 2.16：0b000 LE 1M、0b001 LE 2M、0b010 LE Coded。
    phy: u3,

    pub const Phy = enum(u3) { le_1m = 0b000, le_2m = 0b001, le_coded = 0b010, _ };

    /// Aux Offset 换成微秒：偏移值 × 单位。
    pub fn offsetUs(self: AuxPtr) u32 {
        const unit: u32 = if (self.offset_units == 1) 300 else 30;
        return @as(u32, self.offset) * unit;
    }

    pub fn phyKind(self: AuxPtr) Phy {
        return @fromBackingInt(@intCast(self.phy));
    }

    /// §2.3.4.5：偏移为 0 是允许的，意思是不会有辅助包，但当前 PDU 里的 Host 数据
    /// 是不完整的。
    pub fn noAuxPacket(self: AuxPtr) bool {
        return self.offset == 0;
    }

    /// §2.3.4.5：“The Channel Index field contains the general-purpose channel index
    /// used to transmit the auxiliary packet.” 数据信道索引是 0–36。
    pub fn channelOk(self: AuxPtr) bool {
        return self.channel <= 36;
    }
};

/// SyncInfo（图 2.21），18 字节。
pub const SyncInfo = struct {
    /// 低 13 位是 Offset Base；单位由 `offset_units` 给出。
    offset_base: u13,
    offset_units: u1,
    /// §2.3.4.6：置 1 时 syncPacketWindowOffset 要再加 2.4576 s。
    offset_adjust: u1,
    /// N × 1.25 ms，不应小于 6。
    interval: u16,
    /// 周期物理信道的信道图：bit i 对应信道索引 i，共 37 位。
    chm: u37,
    sca: u3,
    aa: u32,
    crc_init: u24,
    event_counter: u16,

    pub const len: usize = 18;
    const chm_mask: u64 = (1 << 37) - 1;
    /// Offset Adjust 置 1 时加上的时间：2.4576 s，单位 µs。
    pub const offset_adjust_us: u32 = 2_457_600;

    /// syncPacketWindowOffset 换成微秒：Offset Base × 单位，Offset Adjust 置位时
    /// 再加 2.4576 s（§2.3.4.6）。
    pub fn windowOffsetUs(self: SyncInfo) u32 {
        const unit: u32 = if (self.offset_units == 1) 300 else 30;
        const extra: u32 = if (self.offset_adjust == 1) offset_adjust_us else 0;
        return @as(u32, self.offset_base) * unit + extra;
    }

    /// §2.3.4.6：“A value of 0 for syncPacketWindowOffset indicates that the time to
    /// the next … packet is greater than can be represented.” 真正的偏移为 0 没有
    /// 意义，所以整个 syncPacketWindowOffset（含 Offset Adjust）为 0 就按“装不下”
    /// 理解。
    pub fn offsetTooLarge(self: SyncInfo) bool {
        return self.windowOffsetUs() == 0;
    }

    /// 单位从 30 µs 换成 300 µs 的门槛，单位 µs。§2.3.4.6。
    pub const units_switch_us: u32 = 245_700;

    /// §2.3.4.6：“The Offset Units field shall be set to 0 if syncPacketWindowOffset
    /// is less than 245,700 µs.” 反过来读：单位为 300 µs 时窗口偏移必须 ≥ 245,700 µs
    /// （含 Offset Adjust）。单位为 30 µs 时原文没有上界约束——恰好 245,700 µs 时
    /// NimBLE 也用 30 µs 档（controller/src/ble_ll_sync.c:2168–2177 用 `>`）。
    pub fn unitsOk(self: SyncInfo) bool {
        if (self.offset_units == 0) return true;
        return self.windowOffsetUs() >= units_switch_us;
    }

    /// §2.3.4.6：“The Offset Adjust field shall be set to 0 if the Offset Units field
    /// is set to 0 or if the SyncInfo field appears within an advertising PDU.”
    /// `in_advertising_pdu` 为 false 表示它出现在 LL_PERIODIC_SYNC_IND 里。
    pub fn adjustOk(self: SyncInfo, in_advertising_pdu: bool) bool {
        if (self.offset_adjust == 0) return true;
        return self.offset_units == 1 and !in_advertising_pdu;
    }
};

/// 解出来的扩展广播 PDU：头 + 载荷的各个字段。切片都指向输入的那段字节。
pub const ExtPdu = struct {
    header: AdvPduHeader,
    adv_mode: AdvMode,
    /// Extended Header Length，0–63；包含那 1 字节标志位。
    ext_hdr_len: u8,
    flags: u8,
    adva: ?Addr6 = null,
    targeta: ?Addr6 = null,
    cte_info: ?CteInfo = null,
    adi: ?Adi = null,
    aux_ptr: ?AuxPtr = null,
    sync_info: ?SyncInfo = null,
    tx_power: ?i8 = null,
    acad: []const u8 = &.{},
    adv_data: []const u8 = &.{},
};

fn fieldLen(flags: u8) usize {
    // 各字段的字节数（图 2.15）。
    var n: usize = 1; // Extended Header Flags
    if ((flags & HeaderFlag.adva) != 0) n += 6;
    if ((flags & HeaderFlag.targeta) != 0) n += 6;
    if ((flags & HeaderFlag.cte_info) != 0) n += 1;
    if ((flags & HeaderFlag.adi) != 0) n += 2;
    if ((flags & HeaderFlag.aux_ptr) != 0) n += 3;
    if ((flags & HeaderFlag.sync_info) != 0) n += SyncInfo.len;
    if ((flags & HeaderFlag.tx_power) != 0) n += 1;
    return n;
}

/// 解一帧扩展广播 PDU（2 字节头 + 载荷；不含 CRC 与白化）。`pdu` 的长度必须恰好
/// 是 2 + Length。只做位图解码与字段切分，不做时序与“这个 PDU Type 允许哪些字段”
/// 的检查。
pub fn parseExtPdu(pdu: []const u8) Error!ExtPdu {
    const hdr = try AdvPduHeader.decode(pdu);
    if (hdr.pdu_type != pdu_type_ext and hdr.pdu_type != pdu_type_aux_connect_rsp) return error.NotExtPdu;
    if (pdu.len < 2 + @as(usize, hdr.length)) return error.Short;
    if (pdu.len > 2 + @as(usize, hdr.length)) return error.Trailing;
    const payload = pdu[2..];
    // Length 的合法范围是 1–255（§2.3）。
    if (payload.len == 0) return error.Short;

    const mode_bits: u2 = @truncate(payload[0] >> 6);
    if (mode_bits == 0b11) return error.BadAdvMode;
    var out = ExtPdu{
        .header = hdr,
        .adv_mode = @fromBackingInt(@intCast(mode_bits)),
        .ext_hdr_len = payload[0] & 0x3F,
        .flags = 0,
    };
    // “The Extended Header field is … present if, and only if, the Extended Header
    // Length field is non-zero.”
    if (out.ext_hdr_len == 0) {
        out.adv_data = payload[1..];
        return out;
    }
    const ext_len: usize = out.ext_hdr_len;
    if (payload.len < 1 + ext_len) return error.Short;
    out.flags = payload[1];
    if ((out.flags & ~@as(u8, HeaderFlag.all)) != 0) return error.ReservedFlag;
    if (fieldLen(out.flags) > ext_len) return error.BadHeaderLength;

    // “The Extended Header fields that are present are always in the same order as the
    // flags … (i.e., the AdvA field is first if present, then the TargetA field if
    // present, etc.).”
    var p: usize = 2;
    if ((out.flags & HeaderFlag.adva) != 0) {
        out.adva = .{ .bytes = payload[p..][0..6].*, .random = hdr.tx_add };
        p += 6;
    }
    if ((out.flags & HeaderFlag.targeta) != 0) {
        out.targeta = .{ .bytes = payload[p..][0..6].*, .random = hdr.rx_add };
        p += 6;
    }
    if ((out.flags & HeaderFlag.cte_info) != 0) {
        // 图 2.60：CTETime(5) RFU(1) CTEType(2)，LSB 在左。
        out.cte_info = .{ .time = @truncate(payload[p]), .cte_type = @truncate(payload[p] >> 6) };
        p += 1;
    }
    if ((out.flags & HeaderFlag.adi) != 0) {
        const v = std.mem.readInt(u16, payload[p..][0..2], .little);
        out.adi = .{ .did = @truncate(v), .sid = @truncate(v >> 12) };
        p += 2;
    }
    if ((out.flags & HeaderFlag.aux_ptr) != 0) {
        const v = std.mem.readInt(u24, payload[p..][0..3], .little);
        out.aux_ptr = .{
            .channel = @truncate(v),
            .ca = @truncate(v >> 6),
            .offset_units = @truncate(v >> 7),
            .offset = @truncate(v >> 8),
            .phy = @truncate(v >> 21),
        };
        p += 3;
    }
    if ((out.flags & HeaderFlag.sync_info) != 0) {
        const s = payload[p..][0..SyncInfo.len];
        const w0 = std.mem.readInt(u16, s[0..2], .little);
        out.sync_info = .{
            .offset_base = @truncate(w0),
            .offset_units = @truncate(w0 >> 13),
            .offset_adjust = @truncate(w0 >> 14),
            .interval = std.mem.readInt(u16, s[2..4], .little),
            .chm = @truncate((@as(u64, std.mem.readInt(u32, s[4..8], .little))) |
                (@as(u64, s[8] & 0x1F) << 32)),
            .sca = @truncate(s[8] >> 5),
            .aa = std.mem.readInt(u32, s[9..13], .little),
            .crc_init = std.mem.readInt(u24, s[13..16], .little),
            .event_counter = std.mem.readInt(u16, s[16..18], .little),
        };
        p += SyncInfo.len;
    }
    if ((out.flags & HeaderFlag.tx_power) != 0) {
        out.tx_power = @bitCast(payload[p]);
        p += 1;
    }
    // §2.3.4.8：“The remainder of the extended header forms the … ACAD field.”
    out.acad = payload[p .. 1 + ext_len];
    // §2.3.4：“The size of the AdvData can be calculated by subtracting the length of
    // the Extended Header plus one octet from the Length …”
    out.adv_data = payload[1 + ext_len ..];
    return out;
}
