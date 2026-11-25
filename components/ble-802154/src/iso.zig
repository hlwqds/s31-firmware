//! ble-802154：LE Isochronous 通道在 host 侧的 HCI 接口面（Bluetooth Core 5.4）——
//! CIS / BIG 的命令与事件编解码、HCI ISO Data 包的头、BIGInfo 布局与 BIG 参数公式。
//! 只做纯逻辑；不做时序调度、不做 ISOAL 的分段重组、不做音频、不做广播组加密的运算。
//!
//! 规范出处（条款号与原文一致；HCI 在 [Vol 4] Part E，链路层在 [Vol 6] Part B）：
//!   * HCI_LE_Read_ISO_TX_Sync —— §7.8.96（OCF 0x0061）
//!   * HCI_LE_Set_CIG_Parameters —— §7.8.97（OCF 0x0062）
//!   * HCI_LE_Create_CIS —— §7.8.99（OCF 0x0064）
//!   * HCI_LE_Accept_CIS_Request / HCI_LE_Reject_CIS_Request —— §7.8.101 / §7.8.102
//!     （OCF 0x0066 / 0x0067）
//!   * HCI_LE_Create_BIG —— §7.8.103（OCF 0x0068）
//!   * HCI_LE_BIG_Create_Sync —— §7.8.106（OCF 0x006B）
//!   * HCI_LE_Setup_ISO_Data_Path / HCI_LE_Remove_ISO_Data_Path —— §7.8.109 / §7.8.110
//!     （OCF 0x006E / 0x006F）
//!   * HCI_LE_Read_ISO_Link_Quality —— §7.8.116（OCF 0x0075）
//!   * LE CIS Established —— §7.7.65.25（子事件 0x19）
//!   * LE CIS Request —— §7.7.65.26（0x1A）
//!   * LE Create BIG Complete —— §7.7.65.27（0x1B）
//!   * LE BIG Sync Established —— §7.7.65.29（0x1D）
//!   * LE BIG Sync Lost —— §7.7.65.30（0x1E）
//!   * LE BIGInfo Advertising Report —— §7.7.65.34（0x22）
//!   * HCI ISO Data packets —— §5.4.5
//!   * Isochronous Broadcasting state —— §4.4.6；BIG 参数 §4.4.6.3；BIG event §4.4.6.4；
//!     BIGInfo §4.4.6.11（原文 4729 行起）
//!
//! 图的位布局两处是图（图 5.5、图 4.38），文本转储里没有，位置按独立实现交叉核对。
//! 盘上（~/esp/esp-idf）可指认的实现是：NimBLE（host 与 controller）与 ESP-IDF 里
//! Zephyr 头文件的一份拷贝（esp_ble_iso/include/zephyr/…，只含 HCI ISO 包头，不含
//! BIGInfo）。另有一份从上游 GitHub 抓到 /tmp 的 Zephyr controller 源码（pdu.h、
//! ull_sync_iso.c——不在本机 esp-idf 树里）作第三方参考，引用时标注「上游」：
//!   * HCI ISO Data 包（图 5.5）：盘上两份都对得上——NimBLE host/src/ble_hs_iso.c:
//!     150–176（打包）与 hci_common.h:2896–2915（掩码），加上 esp_ble_iso/include/
//!     zephyr/bluetooth/hci_types.h:95–134 的 bt_hci_iso_hdr / bt_hci_iso_sdu_hdr
//!     （逐位注释）。注意 NimBLE 的 BLE_HCI_ISO_CONN_HANDLE_MASK(0x07ff) 与
//!     BLE_HCI_ISO_HDR_SDU_LENGTH_MASK(0x07ff) 都是少一位的笔误，原文规定
//!     Connection_Handle 12 位、ISO_SDU_Length 12 位、Data_Total_Length 14 位；
//!     本文件按原文位宽实现，并在负例里钉住第 12 位。
//!   * BIGInfo（图 4.38）：盘上只有 NimBLE 一份——controller/src/ble_ll_sync.c:
//!     670–702 的逐字段提取（上游 ffd9177「Fix BIGInfo report parsing」保留其全部
//!     位位置，只修了取值校验与 Framing 语义）；第二份是上游 Zephyr controller 的
//!     pdu.h:1107–1146（struct pdu_big_info，逐字段 [字节].位 注释，不在本机树）。
//!     两条独立线索给出的位偏移一致，字段拼出的总长 33（未加密）/ 57（加密）
//!     八位组与原文 §4.4.6.11 第一句自洽。
//!     BaseCRCInit 的字段宽度原文没有写（§4.4.6.11 只说 “contains the value
//!     described in Section 3.1.1”，那里 CRCInit 是 24 位）——16 位是 [INFERENCE]：
//!     上游 Zephyr 的字段是 uint16_t、上游 NimBLE 不读这 2 字节，且 24 位放不进
//!     264 位的总长。
//!
//! 期望值来源（每处测试注释里标了 (a)(b)(c) 哪一种）：
//!   (a) 规范原文的参数表 / 正文（Core-54-hci.txt / Core-54-ll.txt 的行号见各条注释）
//!   (b) 独立实现：NimBLE（盘上，文件与行号见上）、Zephyr（hci_types.h 是盘上拷贝；
//!       BIGInfo 那半是上游 GitHub 抓取，不在本机 esp-idf 树）
//!   (c) 本切片的 Python oracle：/tmp/s31-oracle/iso/iso_oracle.py（按同一份规范参数表
//!       手写的模型，与 Zig 实现对拍；差分性质写在该目录 NOTES.md）
//!
//! 明确不做的（原文有、本文件没有）：
//!   * CIG / BIG 的时序调度（subevent 布局、BIS_Spacing 的选择）；
//!   * ISOAL（[Vol 1] §3.7）的分段与重组——本文件只编码 / 解码单个 HCI ISO Data 包；
//!   * 广播组加密（§4.4.6.10）：GIV / GSKD 只原样解出，不做任何密钥运算；
//!   * §7.8.97 正文里 RTN 的推荐不等式：PDF 上标在文本转储里被拍平成
//!     “NSE×FT-NSE ÷ BN×BN-1≥RTN+1”，无法可靠还原，本文件不实现（见 NOTES.md）。
//!
//! 边界（接真实 controller 时要注意的一处）：`encodeIsoData` 不带方向参数，双向
//! 复用。Packet_Status_Flag 按原文「only valid in HCI ISO Data packets sent by the
//! Controller and is reserved for future use in packets sent by the Host」（§5.4.5）——
//! Host → Controller 方向必须只发 `status = .valid`；本文件在 `status != .valid`
//! 且 PB ∈ {continuation, last} 时拒，但 complete/first + 非 valid 是 Controller
//! → Host 的形态，编码侧放行，Host 发包前自行约束。
//!
//! 板侧子自检 20 条（iso_selftest.zig）；整份文件不 import board、不分配堆，
//! 输出缓冲一律由调用方给。按 ReleaseSmall riscv32 单独编出的 text ≤ 24 KB（见报告）。

const std = @import("std");

const hci = @import("hci.zig");

pub const Error = hci.Error || error{
    /// 连接句柄超过 0x0EFF（§7.8.99 起所有带句柄的命令：“12 bits meaningful”）。
    BadHandle,
    /// CIG_ID / CIS_ID / BIG_Handle / Advertising_Handle 超过 0xEF。
    BadId,
    /// CIS_Count / Num_BIS 超出参数表的范围。
    BadCount,
    /// SDU 间隔不在 0x0000FF–0x0FFFFF。
    BadSduInterval,
    /// Worst_Case_SCA 超过 0x07。
    BadSca,
    /// Packing 不是 0x00 / 0x01。
    BadPacking,
    /// Framing 不是 0x00 / 0x01。
    BadFraming,
    /// Max_Transport_Latency 不在 0x0005–0x0FA0。
    BadLatency,
    /// Max_SDU 超出参数表的范围。
    BadMaxSdu,
    /// RTN 超过 0x1E（§7.8.103 的参数表「0x00 to 0x1E」）。
    BadRtn,
    /// PHY 位图没有置位或带了保留位；事件的 PHY 不在 0x01–0x03；BIGInfo 的 PHY
    /// 是保留值（§4.4.6.11 引 §4.4.5.2：保留 PHY 的 BIGInfo 不上报）。
    BadPhy,
    /// Encryption 不是 0x00 / 0x01。
    BadEncryption,
    /// Encryption=0 却给了非零 Broadcast_Code（§7.8.103 的 Host 侧 shall）。
    BadBroadcastCode,
    /// BIG_Sync_Timeout 不在 0x000A–0x4000。
    BadSyncTimeout,
    /// MSE 超过 0x1F。
    BadMse,
    /// BIS 索引不在 0x01–0x1F，或列表不是严格递增（§7.8.106 的 shall）。
    BadBisIndex,
    /// 数据路径方向不是 0x00 / 0x01；Remove 方向位图带了 bit 0–1 以外的位。
    BadDirection,
    /// Data_Path_ID = 0xFF（保留）。
    BadPathId,
    /// Controller_Delay 超过 0x3D0900（4 s）。
    BadControllerDelay,
    /// Codec_ID 是 transparent air mode 却给了非零 Codec_Configuration（§7.8.109）。
    BadCodecConfig,
    /// Packet_Status_Flag 用了保留值 0b11；或 status=0b10 却带了数据（§5.4.5 的 shall）。
    BadStatus,
    /// TS_Flag 置位出现在续片 / 末片上（§5.4.5：那两种包不带任何 SDU 头字段）。
    BadTs,
    /// BIGInfo 长度不是 33 / 57；或 ISO 包的 Data_Total_Length 与实际字节数不符。
    BadLength,
    /// BIG_Offset 违反 >600 µs 或 units 位规则（§4.4.6.11 的校验助手，见 offsetValid）。
    BadBigOffset,
    /// NSE 不是 BN 的整数倍（§4.4.6.3 的 shall，GC 公式的前置）。
    BadGroupCount,
    /// 事件参数表里 “All other values Reserved for future use” 的值
    ///（时间参数出窗、NSE/FT 出界、BN>0x0F、Max_PDU>0x00FB、ISO_Interval 出窗）。
    BadParam,
    /// 输入被截断。
    Short,
    /// 输入有多余字节。
    Trailing,
    /// 命令参数超过 255 八位组（H4 参数长度只有 8 位）。
    Oversize,
    /// 输出缓冲放不下。
    NoSpace,
    /// 不是本文件的子事件码 / 命令。
    Unsupported,
};

// ---------------------------------------------------------------------------
// OpCode 与子事件码
// ---------------------------------------------------------------------------

fn leOpcode(comptime ocf: u10) u16 {
    return hci.opcode(hci.ogf_le_controller, ocf);
}

/// §7.8.96。
pub const op_le_read_iso_tx_sync: u16 = leOpcode(0x061);
/// §7.8.97。
pub const op_le_set_cig_params: u16 = leOpcode(0x062);
/// §7.8.99。
pub const op_le_create_cis: u16 = leOpcode(0x064);
/// §7.8.101。
pub const op_le_accept_cis_request: u16 = leOpcode(0x066);
/// §7.8.102。
pub const op_le_reject_cis_request: u16 = leOpcode(0x067);
/// §7.8.103。
pub const op_le_create_big: u16 = leOpcode(0x068);
/// §7.8.106。
pub const op_le_big_create_sync: u16 = leOpcode(0x06B);
/// §7.8.109。
pub const op_le_setup_iso_data_path: u16 = leOpcode(0x06E);
/// §7.8.110。
pub const op_le_remove_iso_data_path: u16 = leOpcode(0x06F);
/// §7.8.116。
pub const op_le_read_iso_link_quality: u16 = leOpcode(0x075);

/// LE Meta 子事件码（各事件参数表的第一格）。
pub const le_cis_established: u8 = 0x19;
pub const le_cis_request: u8 = 0x1A;
pub const le_create_big_complete: u8 = 0x1B;
pub const le_big_sync_established: u8 = 0x1D;
pub const le_big_sync_lost: u8 = 0x1E;
pub const le_biginfo_adv_report: u8 = 0x22;

/// 一条命令由哪种事件报告“已受理”（各命令 Event(s) generated 一段的原文）。
pub const Expect = enum { command_complete, command_status };

/// §7.8.99 / §7.8.101 / §7.8.103 / §7.8.106 回 Command Status（正文：
/// “the Controller sends the HCI_Command_Status event”）；其余回 Command Complete。
pub fn expects(op: u16) ?Expect {
    return switch (op) {
        op_le_create_cis,
        op_le_accept_cis_request,
        op_le_create_big,
        op_le_big_create_sync,
        => .command_status,
        op_le_read_iso_tx_sync,
        op_le_set_cig_params,
        op_le_reject_cis_request,
        op_le_setup_iso_data_path,
        op_le_remove_iso_data_path,
        op_le_read_iso_link_quality,
        => .command_complete,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// 公共范围（参数表里的 Value 列）
// ---------------------------------------------------------------------------

/// 连接句柄范围（12 位 meaningful）。§7.8.96 起所有带句柄的命令。
pub const conn_handle_max: u16 = 0x0EFF;
/// CIG_ID / CIS_ID / BIG_Handle / Advertising_Handle。各参数表 “0x00 to 0xEF”。
pub const id_max: u8 = 0xEF;
/// SDU_Interval（µs）。§7.8.97 / §7.8.103 的参数表。
pub const sdu_interval_min: u24 = 0x0000FF;
pub const sdu_interval_max: u24 = 0x0FFFFF;
/// Max_SDU。§7.8.103 的参数表（0x0001–0x0FFF）；§7.8.97 允许 0（单向时置 0）。
pub const max_sdu_min: u12 = 0x001;
pub const max_sdu_max: u12 = 0x0FFF;
/// Max_Transport_Latency（ms）。§7.8.97 / §7.8.103 的参数表。
pub const transport_latency_min: u16 = 0x0005;
pub const transport_latency_max: u16 = 0x0FA0;
/// Num_BIS / Num_BIS(sync)。§7.8.103 / §7.8.106 的参数表。
pub const num_bis_max: u8 = 0x1F;
/// RTN。§7.8.103 的参数表（§7.8.97 的 RTN 没有列范围）。
pub const rtn_max: u8 = 0x1E;
/// MSE。§7.8.106 的参数表（0x00 = 不设上限，0x01–0x1F）。
pub const mse_max: u8 = 0x1F;
/// BIG_Sync_Timeout（N × 10 ms）。§7.8.106 的参数表。
pub const big_sync_timeout_min: u16 = 0x000A;
pub const big_sync_timeout_max: u16 = 0x4000;
/// Controller_Delay（µs）。§7.8.109 的参数表。
pub const controller_delay_max: u24 = 0x3D0900;

/// PHY 位图：bit 0 = LE 1M、bit 1 = LE 2M、bit 2 = LE Coded，其余保留。
/// §7.8.97 的 PHY_C_To_P[i] / PHY_P_To_C[i] 位表、§7.8.103 的 PHY 位表。
pub const PhyBits = struct {
    pub const le_1m: u8 = 1 << 0;
    pub const le_2m: u8 = 1 << 1;
    pub const le_coded: u8 = 1 << 2;
    pub const mask: u8 = 0x07;
};

/// Worst_Case_SCA。§7.8.97 的参数表（0x00–0x07，其余保留）。
pub const sca_max: u8 = 0x07;

// ---------------------------------------------------------------------------
// 1. 命令编码
// ---------------------------------------------------------------------------

/// §7.8.97 的一条逐连接参数（9 个八位组）。
pub const CigCisParams = struct {
    /// 0x00–0xEF。
    cis_id: u8,
    /// 单向时置 0；否则 0x0000–0x0FFF。
    max_sdu_c_to_p: u12,
    max_sdu_p_to_c: u12,
    /// 至少置一位（bit 0–2）。
    phy_c_to_p: u8,
    phy_p_to_c: u8,
    /// §7.8.97 的 RTN 没有列范围（“0xXX”），任意值都接受。
    rtn_c_to_p: u8,
    rtn_p_to_c: u8,

    pub const packed_len: usize = 9;

    fn validate(self: CigCisParams) Error!void {
        if (self.cis_id > id_max) return error.BadId;
        if (self.max_sdu_c_to_p > max_sdu_max) return error.BadMaxSdu;
        if (self.max_sdu_p_to_c > max_sdu_max) return error.BadMaxSdu;
        if (self.phy_c_to_p == 0 or (self.phy_c_to_p & ~PhyBits.mask) != 0) return error.BadPhy;
        if (self.phy_p_to_c == 0 or (self.phy_p_to_c & ~PhyBits.mask) != 0) return error.BadPhy;
    }

    fn pack(self: CigCisParams, out: *[packed_len]u8) void {
        out[0] = self.cis_id;
        std.mem.writeInt(u16, out[1..3], self.max_sdu_c_to_p, .little);
        std.mem.writeInt(u16, out[3..5], self.max_sdu_p_to_c, .little);
        out[5] = self.phy_c_to_p;
        out[6] = self.phy_p_to_c;
        out[7] = self.rtn_c_to_p;
        out[8] = self.rtn_p_to_c;
    }
};

/// HCI_LE_Set_CIG_Parameters。§7.8.97。
///
/// 参数表顺序：CIG_ID(1) SDU_Interval_C_To_P(3) SDU_Interval_P_To_C(3) Worst_Case_SCA(1)
/// Packing(1) Framing(1) Max_Transport_Latency_C_To_P(2) Max_Transport_Latency_P_To_C(2)
/// CIS_Count(1) [CIS_ID(1) Max_SDU_C_To_P(2) Max_SDU_P_To_C(2) PHY_C_To_P(1) PHY_P_To_C(1)
/// RTN_C_To_P(1) RTN_P_To_C(1)] × CIS_Count。数组按元素交错（§5.2 的默认），
/// 所以逐连接的 9 个八位组是连着放的（NimBLE hci_common.h:1015–1026 的
/// ble_hci_le_set_cig_params_cp 同形）。
pub fn leSetCigParameters(
    out: []u8,
    cig_id: u8,
    sdu_interval_c_to_p: u24,
    sdu_interval_p_to_c: u24,
    worst_case_sca: u8,
    packing: u8,
    framing: u8,
    max_latency_c_to_p: u16,
    max_latency_p_to_c: u16,
    cis: []const CigCisParams,
) Error!usize {
    if (cig_id > id_max) return error.BadId;
    if (sdu_interval_c_to_p < sdu_interval_min or sdu_interval_c_to_p > sdu_interval_max) {
        return error.BadSduInterval;
    }
    if (sdu_interval_p_to_c < sdu_interval_min or sdu_interval_p_to_c > sdu_interval_max) {
        return error.BadSduInterval;
    }
    if (worst_case_sca > sca_max) return error.BadSca;
    if (packing > 0x01) return error.BadPacking;
    if (framing > 0x01) return error.BadFraming;
    if (max_latency_c_to_p < transport_latency_min or max_latency_c_to_p > transport_latency_max) {
        return error.BadLatency;
    }
    if (max_latency_p_to_c < transport_latency_min or max_latency_p_to_c > transport_latency_max) {
        return error.BadLatency;
    }
    // §7.8.97：“0x00 to 0x1F … Total number of CIS configurations”。
    if (cis.len > num_bis_max) return error.BadCount;
    for (cis) |c| try c.validate();
    const plen = 15 + 9 * cis.len;
    if (plen > 255) return error.Oversize;
    if (out.len < 4 + plen) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_set_cig_params, .little);
    out[3] = @intCast(plen);
    var p = out[4 .. 4 + plen];
    p[0] = cig_id;
    std.mem.writeInt(u24, p[1..4], sdu_interval_c_to_p, .little);
    std.mem.writeInt(u24, p[4..7], sdu_interval_p_to_c, .little);
    p[7] = worst_case_sca;
    p[8] = packing;
    p[9] = framing;
    std.mem.writeInt(u16, p[10..12], max_latency_c_to_p, .little);
    std.mem.writeInt(u16, p[12..14], max_latency_p_to_c, .little);
    p[14] = @intCast(cis.len);
    for (cis, 0..) |c, i| {
        var one: [CigCisParams.packed_len]u8 = undefined;
        c.pack(&one);
        @memcpy(p[15 + 9 * i ..][0..9], &one);
    }
    return 4 + plen;
}

/// §7.8.97 的返回参数：Status(1) CIG_ID(1) CIS_Count(1) Connection_Handle[i] (2×n)。
/// `ret` 从 Status 起。失败时 Controller 可以只回 Status；成功却缺字段 → Short。
pub const SetCigReturn = struct { status: u8, cig_id: u8, handles: []const u16 };

pub fn parseSetCigReturn(ret: []const u8, out_handles: []u16) Error!SetCigReturn {
    if (ret.len < 1) return error.Short;
    const status = ret[0];
    if (status != 0x00) return .{ .status = status, .cig_id = 0, .handles = out_handles[0..0] };
    if (ret.len < 3) return error.Short;
    const count = ret[2];
    if (count > num_bis_max) return error.BadCount;
    if (ret.len != 3 + 2 * @as(usize, count)) return error.BadLength;
    if (out_handles.len < count) return error.NoSpace;
    for (0..count) |i| {
        const h = std.mem.readInt(u16, ret[3 + 2 * i ..][0..2], .little);
        if (h > conn_handle_max) return error.BadHandle;
        out_handles[i] = h;
    }
    if (ret[1] > id_max) return error.BadId;
    return .{ .status = status, .cig_id = ret[1], .handles = out_handles[0..count] };
}

/// §7.8.99 的一对句柄（4 个八位组）。
pub const CreateCisPair = struct {
    /// 已在 CIG 里的 CIS 配置句柄。
    cis_handle: u16,
    /// 关联的 ACL 连接句柄；列表顺序与 CIS 句柄一一对应。
    acl_handle: u16,
};

/// HCI_LE_Create_CIS。§7.8.99：CIS_Count(1) [CIS_Connection_Handle(2)
/// ACL_Connection_Handle(2)] × n。CIS_Count 的范围是 0x01–0x1F（没有 0）；
/// 同一个 CIS 句柄出现两次按正文回 Invalid HCI Command Parameters (0x12)，
/// 这里在编码侧就拒掉。
pub fn leCreateCis(out: []u8, cis: []const CreateCisPair) Error!usize {
    if (cis.len < 1 or cis.len > num_bis_max) return error.BadCount;
    for (cis) |p| {
        if (p.cis_handle > conn_handle_max) return error.BadHandle;
        if (p.acl_handle > conn_handle_max) return error.BadHandle;
    }
    for (cis, 0..) |a, i| {
        for (cis[i + 1 ..]) |b| {
            if (a.cis_handle == b.cis_handle) return error.BadHandle;
        }
    }
    const plen = 1 + 4 * cis.len;
    if (out.len < 4 + plen) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_create_cis, .little);
    out[3] = @intCast(plen);
    out[4] = @intCast(cis.len);
    for (cis, 0..) |p, i| {
        std.mem.writeInt(u16, out[5 + 4 * i ..][0..2], p.cis_handle, .little);
        std.mem.writeInt(u16, out[7 + 4 * i ..][0..2], p.acl_handle, .little);
    }
    return 4 + plen;
}

/// HCI_LE_Accept_CIS_Request。§7.8.101：Connection_Handle(2)。
pub fn leAcceptCisRequest(out: []u8, conn_handle: u16) Error!usize {
    if (conn_handle > conn_handle_max) return error.BadHandle;
    var p: [2]u8 = undefined;
    std.mem.writeInt(u16, &p, conn_handle, .little);
    return hci.packCommand(out, op_le_accept_cis_request, &p);
}

/// HCI_LE_Reject_CIS_Request。§7.8.102：Connection_Handle(2) Reason(1)。
pub fn leRejectCisRequest(out: []u8, conn_handle: u16, reason: u8) Error!usize {
    if (conn_handle > conn_handle_max) return error.BadHandle;
    var p: [3]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], conn_handle, .little);
    p[2] = reason;
    return hci.packCommand(out, op_le_reject_cis_request, &p);
}

/// §7.8.102 的返回参数：Status(1) Connection_Handle(2)。
pub const RejectReturn = struct { status: u8, conn_handle: u16 };

pub fn parseRejectReturn(ret: []const u8) Error!RejectReturn {
    if (ret.len < 1) return error.Short;
    const status = ret[0];
    if (status != 0x00) return .{ .status = status, .conn_handle = 0 };
    if (ret.len != 3) return error.BadLength;
    const h = std.mem.readInt(u16, ret[1..3], .little);
    if (h > conn_handle_max) return error.BadHandle;
    return .{ .status = status, .conn_handle = h };
}

/// HCI_LE_Create_BIG 的 12 个参数。§7.8.103。
pub const CreateBigParams = struct {
    big_handle: u8,
    advertising_handle: u8,
    /// 0x01–0x1F。
    num_bis: u8,
    sdu_interval: u24,
    /// 0x0001–0x0FFF（不许 0）。
    max_sdu: u12,
    max_transport_latency: u16,
    /// 0x00–0x1E。
    rtn: u8,
    /// 位图，bit 0–2 至少一位。
    phy: u8,
    packing: u8,
    framing: u8,
    /// 0x00 不加密（此时 Broadcast_Code 必须全零）、0x01 加密。
    encryption: u8,
    /// 16 字节；未加密时必须全零（§7.8.103：shall be set to zero by the Host）。
    broadcast_code: [16]u8 = @splat(0),

    pub const packed_len: usize = 31;

    pub fn validate(self: CreateBigParams) Error!void {
        if (self.big_handle > id_max) return error.BadId;
        if (self.advertising_handle > id_max) return error.BadId;
        if (self.num_bis < 1 or self.num_bis > num_bis_max) return error.BadCount;
        if (self.sdu_interval < sdu_interval_min or self.sdu_interval > sdu_interval_max) {
            return error.BadSduInterval;
        }
        if (self.max_sdu < max_sdu_min or self.max_sdu > max_sdu_max) return error.BadMaxSdu;
        if (self.max_transport_latency < transport_latency_min or
            self.max_transport_latency > transport_latency_max) return error.BadLatency;
        if (self.rtn > rtn_max) return error.BadRtn;
        if (self.phy == 0 or (self.phy & ~PhyBits.mask) != 0) return error.BadPhy;
        if (self.packing > 0x01) return error.BadPacking;
        if (self.framing > 0x01) return error.BadFraming;
        if (self.encryption > 0x01) return error.BadEncryption;
        if (self.encryption == 0 and !std.mem.allEqual(u8, &self.broadcast_code, 0)) {
            return error.BadBroadcastCode;
        }
    }

    fn pack(self: CreateBigParams, p: *[packed_len]u8) void {
        p[0] = self.big_handle;
        p[1] = self.advertising_handle;
        p[2] = self.num_bis;
        std.mem.writeInt(u24, p[3..6], self.sdu_interval, .little);
        std.mem.writeInt(u16, p[6..8], self.max_sdu, .little);
        std.mem.writeInt(u16, p[8..10], self.max_transport_latency, .little);
        p[10] = self.rtn;
        p[11] = self.phy;
        p[12] = self.packing;
        p[13] = self.framing;
        p[14] = self.encryption;
        @memcpy(p[15..31], &self.broadcast_code);
    }
};

/// HCI_LE_Create_BIG。§7.8.103。字段顺序与 NimBLE 的
/// ble_hci_le_create_big_cp（hci_common.h:1098–1113）一致。
pub fn leCreateBig(out: []u8, params: CreateBigParams) Error!usize {
    try params.validate();
    var p: [CreateBigParams.packed_len]u8 = undefined;
    params.pack(&p);
    return hci.packCommand(out, op_le_create_big, &p);
}

/// HCI_LE_BIG_Create_Sync。§7.8.106。
pub const BigCreateSyncParams = struct {
    big_handle: u8,
    /// 周期广播 train 的句柄。
    sync_handle: u16,
    /// 0x00 Broadcast_Code 无效、0x01 有效。
    encryption: u8,
    broadcast_code: [16]u8 = @splat(0),
    /// 0x00–0x1F。
    mse: u8,
    /// 0x000A–0x4000（N × 10 ms）。
    big_sync_timeout: u16,
    /// BIS 索引列表：每个 0x01–0x1F，严格递增、无重复（§7.8.106 的 shall）。
    bis: []const u8,

    pub fn validate(self: BigCreateSyncParams) Error!void {
        if (self.big_handle > id_max) return error.BadId;
        if (self.sync_handle > conn_handle_max) return error.BadHandle;
        if (self.encryption > 0x01) return error.BadEncryption;
        if (self.mse > mse_max) return error.BadMse;
        if (self.big_sync_timeout < big_sync_timeout_min or
            self.big_sync_timeout > big_sync_timeout_max) return error.BadSyncTimeout;
        if (self.bis.len < 1 or self.bis.len > num_bis_max) return error.BadCount;
        var prev: u8 = 0;
        for (self.bis) |b| {
            if (b < 1 or b > num_bis_max) return error.BadBisIndex;
            if (b <= prev) return error.BadBisIndex;
            prev = b;
        }
    }

    pub fn packedLen(self: BigCreateSyncParams) usize {
        return 24 + self.bis.len;
    }
};

/// §7.8.106 的字段顺序与 NimBLE 的 ble_hci_le_big_create_sync_cp
/// （hci_common.h:1140–1151）一致：BIG_Handle(1) Sync_Handle(2) Encryption(1)
/// Broadcast_Code(16) MSE(1) BIG_Sync_Timeout(2) Num_BIS(1) BIS[i](1×n)。
pub fn leBigCreateSync(out: []u8, params: BigCreateSyncParams) Error!usize {
    try params.validate();
    const plen = params.packedLen();
    if (plen > 255) return error.Oversize;
    if (out.len < 4 + plen) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_big_create_sync, .little);
    out[3] = @intCast(plen);
    const p = out[4 .. 4 + plen];
    p[0] = params.big_handle;
    std.mem.writeInt(u16, p[1..3], params.sync_handle, .little);
    p[3] = params.encryption;
    @memcpy(p[4..20], &params.broadcast_code);
    p[20] = params.mse;
    std.mem.writeInt(u16, p[21..23], params.big_sync_timeout, .little);
    p[23] = @intCast(params.bis.len);
    for (params.bis, 0..) |b, i| p[24 + i] = b;
    return 4 + plen;
}

/// §7.8.109 的参数。
pub const SetupIsoDataPathParams = struct {
    conn_handle: u16,
    /// 0x00 输入（Host → Controller）、0x01 输出。
    data_path_direction: u8,
    /// 0x00 HCI；0x01–0xFE 厂商通道；0xFF 保留。
    data_path_id: u8,
    /// Codec_ID 的 5 个八位组：编码格式(1) + 公司 ID(2) + 厂商编码 ID(2)。
    coding_format: u8,
    company_id: u16,
    vs_codec_id: u16,
    /// µs，0x000000–0x3D0900。
    controller_delay: u24,
    codec_config: []const u8,

    pub fn validate(self: SetupIsoDataPathParams) Error!void {
        if (self.conn_handle > conn_handle_max) return error.BadHandle;
        if (self.data_path_direction > 0x01) return error.BadDirection;
        if (self.data_path_id == 0xFF) return error.BadPathId;
        if (self.controller_delay > controller_delay_max) return error.BadControllerDelay;
        if (self.codec_config.len > 255) return error.Oversize;
        // §7.8.109：“Codec_Configuration_Length non-zero and Codec_ID set to
        // transparent air mode … Invalid HCI Command Parameters (0x12)”。
        // 0x03 = transparent air mode：Assigned Numbers Service 的 Coding_Format 表
        // （/tmp/spec/Assigned_Numbers.pdf，§2.11，印刷页 59）写明 `0x03 Transparent`，
        // 并注明被 [Vol 4] Part E 7.8.109 引用。
        if (self.codec_config.len > 0 and self.coding_format == coding_fmt_transparent_air) {
            return error.BadCodecConfig;
        }
    }

    pub fn packedLen(self: SetupIsoDataPathParams) usize {
        return 13 + self.codec_config.len;
    }
};

/// transparent air mode 的 Coding Format 值。正文 7.8.109 只写名字；数值出自 Assigned
/// Numbers Service 的 Coding_Format 表（§2.11，印刷页 59）：`0x03 Transparent`。
pub const coding_fmt_transparent_air: u8 = 0x03;

/// HCI_LE_Setup_ISO_Data_Path。§7.8.109。
pub fn leSetupIsoDataPath(out: []u8, params: SetupIsoDataPathParams) Error!usize {
    try params.validate();
    const plen = params.packedLen();
    if (plen > 255) return error.Oversize;
    if (out.len < 4 + plen) return error.NoSpace;
    out[0] = hci.h4_command;
    std.mem.writeInt(u16, out[1..3], op_le_setup_iso_data_path, .little);
    out[3] = @intCast(plen);
    const p = out[4 .. 4 + plen];
    std.mem.writeInt(u16, p[0..2], params.conn_handle, .little);
    p[2] = params.data_path_direction;
    p[3] = params.data_path_id;
    p[4] = params.coding_format;
    std.mem.writeInt(u16, p[5..7], params.company_id, .little);
    std.mem.writeInt(u16, p[7..9], params.vs_codec_id, .little);
    std.mem.writeInt(u24, p[9..12], params.controller_delay, .little);
    p[12] = @intCast(params.codec_config.len);
    @memcpy(p[13..plen], params.codec_config);
    return 4 + plen;
}

/// §7.8.109 的返回参数：Status(1) Connection_Handle(2)。
pub const ConnHandleReturn = struct { status: u8, conn_handle: u16 };

pub fn parseConnHandleReturn(ret: []const u8) Error!ConnHandleReturn {
    if (ret.len < 1) return error.Short;
    const status = ret[0];
    if (status != 0x00) return .{ .status = status, .conn_handle = 0 };
    if (ret.len != 3) return error.BadLength;
    const h = std.mem.readInt(u16, ret[1..3], .little);
    if (h > conn_handle_max) return error.BadHandle;
    return .{ .status = status, .conn_handle = h };
}

/// Remove 方向位图：bit 0 = 输入、bit 1 = 输出（§7.8.110 的位表，其余位保留）。
pub const RemoveDirection = struct {
    pub const input: u8 = 1 << 0;
    pub const output: u8 = 1 << 1;
    pub const mask: u8 = 0x03;
};

/// HCI_LE_Remove_ISO_Data_Path。§7.8.110。方向位表只有 bit 0 / bit 1 与
/// 「All other bits Reserved for future use」——这一节没有 §7.8.97 / §7.8.103
/// 那样的「shall set at least one bit」句子，所以 0x00（两个方向都不撤）不是
/// 保留值，编码侧接受；带保留位（≥ 0x04）仍然拒。
pub fn leRemoveIsoDataPath(out: []u8, conn_handle: u16, direction: u8) Error!usize {
    if (conn_handle > conn_handle_max) return error.BadHandle;
    if ((direction & ~RemoveDirection.mask) != 0) return error.BadDirection;
    var p: [3]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], conn_handle, .little);
    p[2] = direction;
    return hci.packCommand(out, op_le_remove_iso_data_path, &p);
}

/// HCI_LE_Read_ISO_TX_Sync。§7.8.96：Connection_Handle(2)。
pub fn leReadIsoTxSync(out: []u8, conn_handle: u16) Error!usize {
    if (conn_handle > conn_handle_max) return error.BadHandle;
    var p: [2]u8 = undefined;
    std.mem.writeInt(u16, &p, conn_handle, .little);
    return hci.packCommand(out, op_le_read_iso_tx_sync, &p);
}

/// §7.8.96 的返回参数：Status(1) Connection_Handle(2) Packet_Sequence_Number(2)
/// TX_Time_Stamp(4) Time_Offset(3)。unframed 的 PDU 上 Time_Offset 回 0（正文）。
pub const TxSyncReturn = struct {
    status: u8,
    conn_handle: u16,
    packet_sequence_number: u16,
    tx_time_stamp: u32,
    time_offset: u24,
};

pub fn parseTxSyncReturn(ret: []const u8) Error!TxSyncReturn {
    if (ret.len < 1) return error.Short;
    const status = ret[0];
    if (status != 0x00) return .{ .status = status, .conn_handle = 0, .packet_sequence_number = 0, .tx_time_stamp = 0, .time_offset = 0 };
    if (ret.len != 12) return error.BadLength;
    const h = std.mem.readInt(u16, ret[1..3], .little);
    if (h > conn_handle_max) return error.BadHandle;
    return .{
        .status = status,
        .conn_handle = h,
        .packet_sequence_number = std.mem.readInt(u16, ret[3..5], .little),
        .tx_time_stamp = std.mem.readInt(u32, ret[5..9], .little),
        .time_offset = std.mem.readInt(u24, ret[9..12], .little),
    };
}

/// HCI_LE_Read_ISO_Link_Quality。§7.8.116：Connection_Handle(2)。
pub fn leReadIsoLinkQuality(out: []u8, conn_handle: u16) Error!usize {
    if (conn_handle > conn_handle_max) return error.BadHandle;
    var p: [2]u8 = undefined;
    std.mem.writeInt(u16, &p, conn_handle, .little);
    return hci.packCommand(out, op_le_read_iso_link_quality, &p);
}

/// §7.8.116 的返回参数：Status(1) Connection_Handle(2) + 7 × u32 计数器
/// （表 7.3 的顺序）。计数器只在对应类型的流上有效，其它类型忽略（正文）。
pub const LinkQualityReturn = struct {
    status: u8,
    conn_handle: u16,
    tx_unacked_packets: u32,
    tx_flushed_packets: u32,
    tx_last_subevent_packets: u32,
    retransmitted_packets: u32,
    crc_error_packets: u32,
    rx_unreceived_packets: u32,
    duplicate_packets: u32,

    pub const packed_len: usize = 31;
};

pub fn parseLinkQualityReturn(ret: []const u8) Error!LinkQualityReturn {
    if (ret.len < 1) return error.Short;
    const status = ret[0];
    if (status != 0x00) {
        return .{
            .status = status,
            .conn_handle = 0,
            .tx_unacked_packets = 0,
            .tx_flushed_packets = 0,
            .tx_last_subevent_packets = 0,
            .retransmitted_packets = 0,
            .crc_error_packets = 0,
            .rx_unreceived_packets = 0,
            .duplicate_packets = 0,
        };
    }
    if (ret.len != LinkQualityReturn.packed_len) return error.BadLength;
    const h = std.mem.readInt(u16, ret[1..3], .little);
    if (h > conn_handle_max) return error.BadHandle;
    var r: LinkQualityReturn = .{
        .status = status,
        .conn_handle = h,
        .tx_unacked_packets = 0,
        .tx_flushed_packets = 0,
        .tx_last_subevent_packets = 0,
        .retransmitted_packets = 0,
        .crc_error_packets = 0,
        .rx_unreceived_packets = 0,
        .duplicate_packets = 0,
    };
    inline for (0..7) |i| {
        const v = std.mem.readInt(u32, ret[3 + 4 * i ..][0..4], .little);
        switch (i) {
            0 => r.tx_unacked_packets = v,
            1 => r.tx_flushed_packets = v,
            2 => r.tx_last_subevent_packets = v,
            3 => r.retransmitted_packets = v,
            4 => r.crc_error_packets = v,
            5 => r.rx_unreceived_packets = v,
            6 => r.duplicate_packets = v,
            else => unreachable,
        }
    }
    return r;
}

// ---------------------------------------------------------------------------
// 2. 事件解析
// ---------------------------------------------------------------------------

/// §7.7.65.25 LE CIS Established（Subevent_Code 之后的参数）。
/// 时间参数（3 八位组）的范围是 0x0000EA–0x7FFFFF，表外是保留值 → 拒收；
/// 这与 ext_adv.zig 对“保留值拒收”的先例一致。
pub const CisEstablished = struct {
    status: u8,
    conn_handle: u16,
    cig_sync_delay: u24,
    cis_sync_delay: u24,
    transport_latency_c_to_p: u24,
    transport_latency_p_to_c: u24,
    /// 0x01 LE 1M、0x02 LE 2M、0x03 LE Coded。
    phy_c_to_p: u8,
    phy_p_to_c: u8,
    /// 0x01–0x1F。
    nse: u8,
    /// 0x00（无数据）或 0x01–0x0F。
    bn_c_to_p: u8,
    bn_p_to_c: u8,
    /// 0x01–0xFF。
    ft_c_to_p: u8,
    ft_p_to_c: u8,
    /// 0x0000–0x00FB。
    max_pdu_c_to_p: u16,
    max_pdu_p_to_c: u16,
    /// N × 1.25 ms，0x0004–0x0C80。
    iso_interval: u16,

    /// Status(1)+Handle(2)+4×Delay/Latency(3)+2×PHY(1)+NSE(1)+2×BN(1)+2×FT(1)
    /// +2×Max_PDU(2)+ISO_Interval(2)。
    pub const packed_len: usize = 28;

    pub fn isoIntervalUs(self: CisEstablished) u32 {
        return intervalUs(@as(u32, self.iso_interval));
    }
};

fn validateIsoInterval(v: u16) Error!void {
    if (v < 0x0004 or v > 0x0C80) return error.BadParam;
}

fn validateSyncDelay(v: u24) Error!void {
    if (v < 0x0000EA or v > 0x7FFFFF) return error.BadParam;
}

fn validateEventPhy(v: u8) Error!void {
    if (v < 0x01 or v > 0x03) return error.BadPhy;
}

fn validateBn(v: u8) Error!void {
    if (v > 0x0F) return error.BadParam;
}

pub fn parseCisEstablished(p: []const u8) Error!CisEstablished {
    if (p.len < CisEstablished.packed_len) return error.Short;
    if (p.len > CisEstablished.packed_len) return error.Trailing;
    const status = p[0];
    const h = std.mem.readInt(u16, p[1..3], .little);
    if (h > conn_handle_max) return error.BadHandle;
    const cig_sync = std.mem.readInt(u24, p[3..6], .little);
    const cis_sync = std.mem.readInt(u24, p[6..9], .little);
    const lat_c2p = std.mem.readInt(u24, p[9..12], .little);
    const lat_p2c = std.mem.readInt(u24, p[12..15], .little);
    const pdu_c2p = std.mem.readInt(u16, p[22..24], .little);
    const pdu_p2c = std.mem.readInt(u16, p[24..26], .little);
    const iso_int = std.mem.readInt(u16, p[26..28], .little);
    if (status == 0x00) {
        // 时间范围只在成功的事件上有意义；失败的事件里 Controller 可以把这些
        // 字段填 0（正文只规定了成功路径的字段含义）。
        try validateSyncDelay(cig_sync);
        try validateSyncDelay(cis_sync);
        try validateSyncDelay(lat_c2p);
        try validateSyncDelay(lat_p2c);
        try validateEventPhy(p[15]);
        try validateEventPhy(p[16]);
        if (p[17] < 1 or p[17] > num_bis_max) return error.BadParam;
        try validateBn(p[18]);
        try validateBn(p[19]);
        if (p[20] < 1) return error.BadParam;
        if (p[21] < 1) return error.BadParam;
        if (pdu_c2p > 0x00FB or pdu_p2c > 0x00FB) return error.BadParam;
        try validateIsoInterval(iso_int);
    }
    return .{
        .status = status,
        .conn_handle = h,
        .cig_sync_delay = cig_sync,
        .cis_sync_delay = cis_sync,
        .transport_latency_c_to_p = lat_c2p,
        .transport_latency_p_to_c = lat_p2c,
        .phy_c_to_p = p[15],
        .phy_p_to_c = p[16],
        .nse = p[17],
        .bn_c_to_p = p[18],
        .bn_p_to_c = p[19],
        .ft_c_to_p = p[20],
        .ft_p_to_c = p[21],
        .max_pdu_c_to_p = pdu_c2p,
        .max_pdu_p_to_c = pdu_p2c,
        .iso_interval = iso_int,
    };
}

/// §7.7.65.26 LE CIS Request（Subevent_Code 之后的参数）。
pub const CisRequest = struct {
    acl_conn_handle: u16,
    cis_conn_handle: u16,
    /// 0x00–0xEF。
    cig_id: u8,
    cis_id: u8,
};

pub fn parseCisRequest(p: []const u8) Error!CisRequest {
    if (p.len < 6) return error.Short;
    if (p.len > 6) return error.Trailing;
    const acl = std.mem.readInt(u16, p[0..2], .little);
    const cis = std.mem.readInt(u16, p[2..4], .little);
    if (acl > conn_handle_max or cis > conn_handle_max) return error.BadHandle;
    if (p[4] > id_max or p[5] > id_max) return error.BadId;
    return .{ .acl_conn_handle = acl, .cis_conn_handle = cis, .cig_id = p[4], .cis_id = p[5] };
}

/// §7.7.65.27 LE Create BIG Complete（Subevent_Code 之后的参数）。
/// Connection_Handle[i] 解到调用方给的缓冲里。
pub const BigComplete = struct {
    status: u8,
    big_handle: u8,
    big_sync_delay: u24,
    transport_latency_big: u24,
    phy: u8,
    nse: u8,
    /// 0x01–0x07。
    bn: u8,
    /// 0x00–0x0F。
    pto: u8,
    /// 0x01–0x0F。
    irc: u8,
    /// 0x0001–0x00FB。
    max_pdu: u16,
    iso_interval: u16,
    num_bis: u8,
    handles: []const u16,

    /// Status(1)+Handle(1)+Delay(3)+Latency(3)+PHY(1)+NSE(1)+BN(1)+PTO(1)+IRC(1)
    /// +Max_PDU(2)+ISO_Interval(2)+Num_BIS(1) = 18，句柄数组另加 2×n。
    pub fn packedLen(num_bis: usize) usize {
        return 18 + 2 * num_bis;
    }
};

/// BN 的范围（Create BIG Complete / BIG Sync Established / BIGInfo 的参数表）。
fn validateBigBn(v: u8) Error!void {
    if (v < 1 or v > 0x07) return error.BadParam;
}

fn validatePto(v: u8) Error!void {
    if (v > 0x0F) return error.BadParam;
}

fn validateIrc(v: u8) Error!void {
    if (v < 1 or v > 0x0F) return error.BadParam;
}

pub fn parseCreateBigComplete(p: []const u8, out_handles: []u16) Error!BigComplete {
    if (p.len < 18) return error.Short;
    const status = p[0];
    const big_handle = p[1];
    if (big_handle > id_max) return error.BadId;
    const n = p[17];
    if (n < 1 or n > num_bis_max) return error.BadCount;
    const want = BigComplete.packedLen(n);
    if (p.len < want) return error.Short;
    if (p.len > want) return error.Trailing;
    if (out_handles.len < n) return error.NoSpace;
    const iso_int = std.mem.readInt(u16, p[15..17], .little);
    if (status == 0x00) {
        const big_sync = std.mem.readInt(u24, p[2..5], .little);
        const lat = std.mem.readInt(u24, p[5..8], .little);
        try validateSyncDelay(big_sync);
        try validateSyncDelay(lat);
        try validateEventPhy(p[8]);
        if (p[9] < 1 or p[9] > num_bis_max) return error.BadParam;
        try validateBigBn(p[10]);
        try validatePto(p[11]);
        try validateIrc(p[12]);
        const pdu = std.mem.readInt(u16, p[13..15], .little);
        if (pdu < 1 or pdu > 0x00FB) return error.BadParam;
        try validateIsoInterval(iso_int);
    }
    for (0..n) |i| {
        const h = std.mem.readInt(u16, p[18 + 2 * i ..][0..2], .little);
        if (h > conn_handle_max) return error.BadHandle;
        out_handles[i] = h;
    }
    return .{
        .status = status,
        .big_handle = big_handle,
        .big_sync_delay = std.mem.readInt(u24, p[2..5], .little),
        .transport_latency_big = std.mem.readInt(u24, p[5..8], .little),
        .phy = p[8],
        .nse = p[9],
        .bn = p[10],
        .pto = p[11],
        .irc = p[12],
        .max_pdu = std.mem.readInt(u16, p[13..15], .little),
        .iso_interval = iso_int,
        .num_bis = n,
        .handles = out_handles[0..n],
    };
}

/// §7.7.65.29 LE BIG Sync Established（Subevent_Code 之后的参数）。
pub const BigSyncEstablished = struct {
    status: u8,
    big_handle: u8,
    transport_latency_big: u24,
    nse: u8,
    bn: u8,
    pto: u8,
    irc: u8,
    max_pdu: u16,
    iso_interval: u16,
    num_bis: u8,
    handles: []const u16,
};

pub fn parseBigSyncEstablished(p: []const u8, out_handles: []u16) Error!BigSyncEstablished {
    if (p.len < 14) return error.Short;
    const status = p[0];
    const big_handle = p[1];
    if (big_handle > id_max) return error.BadId;
    const n = p[13];
    if (n < 1 or n > num_bis_max) return error.BadCount;
    const want = 14 + 2 * @as(usize, n);
    if (p.len < want) return error.Short;
    if (p.len > want) return error.Trailing;
    if (out_handles.len < n) return error.NoSpace;
    if (status == 0x00) {
        const lat = std.mem.readInt(u24, p[2..5], .little);
        try validateSyncDelay(lat);
        if (p[5] < 1 or p[5] > num_bis_max) return error.BadParam;
        try validateBigBn(p[6]);
        try validatePto(p[7]);
        try validateIrc(p[8]);
        const pdu = std.mem.readInt(u16, p[9..11], .little);
        if (pdu < 1 or pdu > 0x00FB) return error.BadParam;
        try validateIsoInterval(std.mem.readInt(u16, p[11..13], .little));
    }
    for (0..n) |i| {
        const h = std.mem.readInt(u16, p[14 + 2 * i ..][0..2], .little);
        if (h > conn_handle_max) return error.BadHandle;
        out_handles[i] = h;
    }
    return .{
        .status = status,
        .big_handle = big_handle,
        .transport_latency_big = std.mem.readInt(u24, p[2..5], .little),
        .nse = p[5],
        .bn = p[6],
        .pto = p[7],
        .irc = p[8],
        .max_pdu = std.mem.readInt(u16, p[9..11], .little),
        .iso_interval = std.mem.readInt(u16, p[11..13], .little),
        .num_bis = n,
        .handles = out_handles[0..n],
    };
}

/// §7.7.65.30 LE BIG Sync Lost（Subevent_Code 之后的参数）。
pub const BigSyncLost = struct {
    big_handle: u8,
    /// 0x08 超时、0x13 对端终止、0x3D MIC 失败（正文的三种映射）。
    reason: u8,
};

pub fn parseBigSyncLost(p: []const u8) Error!BigSyncLost {
    if (p.len < 2) return error.Short;
    if (p.len > 2) return error.Trailing;
    if (p[0] > id_max) return error.BadId;
    return .{ .big_handle = p[0], .reason = p[1] };
}

// ---------------------------------------------------------------------------
// 3. BIGInfo（§4.4.6.11；图 4.38）
// ---------------------------------------------------------------------------

/// BIGInfo 的两个长度。§4.4.6.11 第一句；§4.4.6.10：
/// “The Link Layer shall determine if a BIG is encrypted by examining the length”。
pub const biginfo_len: usize = 33;
pub const biginfo_len_encrypted: usize = 57;

/// BIG_Offset_Units 置位时的单位是 300 µs，否则 30 µs（§4.4.6.11 正文）。
pub const big_offset_unit_us: u32 = 30;
pub const big_offset_unit_300_us: u32 = 300;
/// units 位只在 offset ≥ 491,460 µs 时才允许置位（§4.4.6.11 正文）。
pub const big_offset_units_threshold_us: u32 = 491_460;
/// offset 必须大于 600 µs（§4.4.6.11 正文）。
pub const big_offset_min_us: u32 = 600;

/// BIGInfo 的位布局（图 4.38；LSB 在左，§1.2）。位宽表同时给 comptime 程序数格子用
/// （见 iso_tests.zig 的 `cells` 测试）：按字段顺序累加，总宽 264 位 = 33 八位组。
pub const field_widths = [_]u16{
    14, // BIG_Offset            [0].0  – [1].5
    1, //  BIG_Offset_Units     [1].6
    12, // ISO_Interval          [1].7  – [3].2
    5, //  Num_BIS              [3].3  – [3].7
    5, //  NSE                  [4].0  – [4].4
    3, //  BN                   [4].5  – [4].7
    20, // Sub_Interval (µs)     [5].0  – [7].3
    4, //  PTO                  [7].4  – [7].7
    20, // BIS_Spacing (µs)      [8].0  – [10].3
    4, //  IRC                  [10].4 – [10].7
    8, //  Max_PDU              [11].0 – [11].7
    8, //  RFU                  [12].0 – [12].7（Core 5.4 整字节保留）
    32, // SeedAccessAddress     [13..16]
    20, // SDU_Interval (µs)     [17].0 – [19].3
    12, // Max_SDU               [19].4 – [20].7
    16, // BaseCRCInit（原文未写字段宽度——16 位是 [INFERENCE]，见文件头）[21..22]
    37, // ChM（37 位信道图）    [23].0 – [26].4
    3, //  PHY（表 4.3：0=1M 1=2M 2=Coded）[26].5 – [26].7 → 字节 27 的高 3 位
    39, // bisPayloadCount       [28].0 – [32].6
    1, //  Framing              [32].7
};

/// comptime 算出每个字段的起始位；总宽必须是 264 位。
pub const field_offsets: [field_widths.len]u16 = blk: {
    @setEvalBranchQuota(2000);
    var off: [field_widths.len]u16 = undefined;
    var acc: u16 = 0;
    for (field_widths, 0..) |w, i| {
        off[i] = acc;
        acc += w;
    }
    if (acc != 8 * biginfo_len) {
        @compileError("BIGInfo 位宽表加起来不是 264 位");
    }
    break :blk off;
};

/// 表 4.3 的 PHY 值（BIGInfo 里的 2 位有效编码，读出来是 3 位：最高位保留）。
pub const BigInfoPhy = enum(u2) { le_1m = 0, le_2m = 1, le_coded = 2 };

/// 解出的一份 BIGInfo。加密字段在 `encrypted` 时才有效。
pub const BigInfo = struct {
    /// 原始 14 位值；实际时间 = 值 × 单位（`offset_units_300_us` 选单位）。
    offset_raw: u14,
    offset_units_300_us: bool,
    iso_interval: u12,
    num_bis: u8,
    nse: u8,
    bn: u8,
    sub_interval_us: u20,
    pto: u8,
    bis_spacing_us: u20,
    irc: u8,
    max_pdu: u8,
    seed_access_address: u32,
    sdu_interval_us: u20,
    max_sdu: u12,
    base_crc_init: u16,
    /// 5 字节，高 27 位强制 0（37 位信道图）。
    chm: [5]u8,
    phy_ll: BigInfoPhy,
    /// bisPayloadCount，对应 §4.4.6.11：BIG_Offset 指的那个 BIG 事件的第一个 subevent。
    payload_count: u39,
    /// true：BIG 带分帧数据。
    framing: bool,
    /// 57 八位组时为 true，且 `giv` / `gskd` 有效（§4.4.6.10）。
    encrypted: bool,
    giv: [8]u8 = @splat(0),
    gskd: [16]u8 = @splat(0),

    /// BIG_Offset 的实际时间（µs）。
    pub fn offsetUs(self: BigInfo) u32 {
        const unit = if (self.offset_units_300_us) big_offset_unit_300_us else big_offset_unit_us;
        return @as(u32, self.offset_raw) * unit;
    }

    /// 广播侧的 BIG_Offset 合规性（§4.4.6.11 的两句 shall）：
    /// offset > 600 µs；offset < 491,460 µs 时 units 位不得置位。
    pub fn offsetValid(self: BigInfo) bool {
        const t = self.offsetUs();
        if (t <= big_offset_min_us) return false;
        if (t < big_offset_units_threshold_us and self.offset_units_300_us) return false;
        return true;
    }

    /// HCI 事件里的 PHY 编码（0x01/0x02/0x03）。§7.7.65.34 的参数表。
    pub fn phyHci(self: BigInfo) u8 {
        return @backingInt(self.phy_ll) + 1;
    }
};

fn getBits(bytes: []const u8, comptime bit_off: u16, comptime width: u16) u64 {
    // 从字节流按 LSB-first 取 width 位；width ≤ 32，且字段不跨出 4 字节窗口。
    const lo = bit_off / 8;
    var acc: u64 = 0;
    inline for (0..5) |i| {
        const idx = lo + i;
        if (idx < bytes.len) {
            acc |= @as(u64, bytes[idx]) << @intCast(8 * i);
        }
    }
    const shift: u6 = @intCast(bit_off % 8);
    return (acc >> shift) & ((@as(u64, 1) << @intCast(width)) - 1);
}

/// 解析 BIGInfo（ACAD 里的原始 33 / 57 字节）。
///
/// 拒绝路径：长度不是 33 / 57 → BadLength（§4.4.6.11）；PHY 是保留值 → BadPhy
/// （§4.4.6.11 引 §4.4.5.2：保留 / 不支持的 PHY 的 BIGInfo 不上报）。其余保留位
/// （字节 12、ChM 的高 27 位、payload_count 的第 40 位）按“忽略”处理，不拒收。
pub fn parseBigInfo(bytes: []const u8) Error!BigInfo {
    if (bytes.len != biginfo_len and bytes.len != biginfo_len_encrypted) return error.BadLength;
    const o = field_offsets;
    var bi: BigInfo = .{
        .offset_raw = @intCast(getBits(bytes, o[0], field_widths[0])),
        .offset_units_300_us = getBits(bytes, o[1], field_widths[1]) != 0,
        .iso_interval = @intCast(getBits(bytes, o[2], field_widths[2])),
        .num_bis = @intCast(getBits(bytes, o[3], field_widths[3])),
        .nse = @intCast(getBits(bytes, o[4], field_widths[4])),
        .bn = @intCast(getBits(bytes, o[5], field_widths[5])),
        .sub_interval_us = @intCast(getBits(bytes, o[6], field_widths[6])),
        .pto = @intCast(getBits(bytes, o[7], field_widths[7])),
        .bis_spacing_us = @intCast(getBits(bytes, o[8], field_widths[8])),
        .irc = @intCast(getBits(bytes, o[9], field_widths[9])),
        .max_pdu = @intCast(getBits(bytes, o[10], field_widths[10])),
        .seed_access_address = @truncate(getBits(bytes, o[12], field_widths[12])),
        .sdu_interval_us = @intCast(getBits(bytes, o[13], field_widths[13])),
        .max_sdu = @intCast(getBits(bytes, o[14], field_widths[14])),
        .base_crc_init = @intCast(getBits(bytes, o[15], field_widths[15])),
        .chm = undefined,
        .phy_ll = undefined,
        .payload_count = @truncate(getBits(bytes, o[18], field_widths[18])),
        .framing = getBits(bytes, o[19], field_widths[19]) != 0,
        .encrypted = bytes.len == biginfo_len_encrypted,
    };
    // ChM：37 位 + 27 个保留位（忽略）。字节 23–26 全量，字节 27 只留低 5 位。
    @memcpy(bi.chm[0..4], bytes[23..27]);
    bi.chm[4] = bytes[27] & 0x1F;
    // PHY 在字节 27 的高 3 位；表 4.3 只定义 0/1/2，3–7 保留。
    const phy3: u3 = @intCast(bytes[27] >> 5);
    bi.phy_ll = switch (phy3) {
        0 => .le_1m,
        1 => .le_2m,
        2 => .le_coded,
        else => return error.BadPhy,
    };
    if (bi.encrypted) {
        @memcpy(&bi.giv, bytes[biginfo_len .. biginfo_len + 8]);
        @memcpy(&bi.gskd, bytes[biginfo_len + 8 .. biginfo_len_encrypted]);
    }
    return bi;
}

// ---------------------------------------------------------------------------
// 4. HCI ISO Data 包（§5.4.5）
// ---------------------------------------------------------------------------

/// PB_Flag（§5.4.5 的表；图 5.5 里在句柄字的高两位）。
pub const PbFlag = enum(u2) {
    /// 0b00：分片 SDU 的第一片。
    first_fragment = 0b00,
    /// 0b01：中间片（不带任何 SDU 头字段）。
    continuation = 0b01,
    /// 0b10：完整 SDU。
    complete_sdu = 0b10,
    /// 0b11：最后一片（不带任何 SDU 头字段）。
    last_fragment = 0b11,
};

/// Packet_Status_Flag（只在 Controller → Host 方向有效；Host → Controller 保留）。
pub const PacketStatus = enum(u2) {
    /// 0b00：完整 SDU 正确收到。
    valid = 0b00,
    /// 0b01：可能有错（data with possible errors）。
    possibly_invalid = 0b01,
    /// 0b10：丢了数据（lost data）；此时必须无数据、PB=complete、ISO_SDU_Length=0。
    lost = 0b10,
    /// 0b11：保留。
    reserved = 0b11,
};

/// §5.4.5：H4 之外的头是 4 个八位组；PB=00/10 的包在头后面还有 SDU 头
/// （Time_Stamp [TS_Flag=1 时] + Packet_Sequence_Number(2) +
/// ISO_SDU_Length(12)|RFU(2)|Packet_Status_Flag(2)）。
pub const iso_hdr_len: usize = 4;
pub const sdu_hdr_len: usize = 4;
pub const ts_len: usize = 4;

/// HCI ISO Data 包的解析结果。`ts` / `seq` / `sdu_len` / `status` 只在
/// PB = first / complete 的包上有效（其余为 null）；`fragment` 指向 `bytes` 内部。
pub const IsoDataPacket = struct {
    conn_handle: u16,
    pb: PbFlag,
    ts_flag: bool,
    data_total_length: u16,
    ts: ?u32,
    packet_sequence_number: ?u16,
    /// SDU 的总长（不是本片的长度）。
    sdu_len: ?u12,
    status: ?PacketStatus,
    fragment: []const u8,
};

/// 编一个 HCI ISO Data 包（不带 H4 类型指示字节——与 hci.zig 的 ACL 编解码同一约定，
/// ACL 只处理 4 字节头起的载荷；H4 的 ISO 指示字节属 [Vol 4] Part D，盘上没有该卷）。
///
/// PB = first / complete：`ts` 可选（TS_Flag 由它推导）、`seq` / `sdu_len` / `status`
/// 都要带；PB = continuation / last：规范规定不带任何 SDU 头字段，`ts` 必须为 null，
/// `seq` / `sdu_len` 写 0、`status` 强制 valid（该方向的字段本来就保留）。
/// `status` 非 valid 只在 Controller → Host 的包上出现；Host 发包时保留。
pub fn encodeIsoData(
    out: []u8,
    conn_handle: u16,
    pb: PbFlag,
    ts: ?u32,
    seq: u16,
    sdu_len: u12,
    status: PacketStatus,
    fragment: []const u8,
) Error!usize {
    if (conn_handle > conn_handle_max) return error.BadHandle;
    const has_sdu_hdr = switch (pb) {
        .first_fragment, .complete_sdu => true,
        .continuation, .last_fragment => false,
    };
    if (!has_sdu_hdr) {
        if (ts != null) return error.BadTs;
        if (status != .valid) return error.BadStatus;
    } else if (status == .reserved) {
        return error.BadStatus;
    }
    const tail_len = if (has_sdu_hdr) (if (ts != null) ts_len else 0) + sdu_hdr_len + fragment.len else fragment.len;
    if (tail_len > 0x3FFF) return error.Oversize;
    const total = iso_hdr_len + tail_len;
    if (out.len < total) return error.NoSpace;
    const flags: u16 = @as(u16, conn_handle) | (@as(u16, @backingInt(pb)) << 12) |
        (if (ts != null and has_sdu_hdr) @as(u16, 1) << 14 else 0);
    std.mem.writeInt(u16, out[0..2], flags, .little);
    std.mem.writeInt(u16, out[2..4], @intCast(tail_len), .little);
    var i: usize = iso_hdr_len;
    if (has_sdu_hdr) {
        if (ts) |v| {
            std.mem.writeInt(u32, out[i..][0..4], v, .little);
            i += ts_len;
        }
        std.mem.writeInt(u16, out[i..][0..2], seq, .little);
        i += 2;
        const status_bits: u16 = @as(u16, @backingInt(status)) << 14;
        std.mem.writeInt(u16, out[i..][0..2], @as(u16, sdu_len) | status_bits, .little);
        i += 2;
    }
    @memcpy(out[i..total], fragment);
    return total;
}

/// 解一个 HCI ISO Data 包（输入从 4 字节头起，不含 H4 指示字节）。
///
/// 拒绝路径全部来自 §5.4.5 的原文：PB=00/10 时 Data_Total_Length 至少要装下 SDU 头
/// （TS_Flag=0 至少 4、=1 至少 8）；PB=01/11 时不带任何 SDU 头字段，TS_Flag 置位即
/// 违反 shall；status=0b10 时必须无数据、PB=complete、ISO_SDU_Length=0；
/// status=0b11 是保留值；Data_Total_Length 必须与实际字节数一致。句柄字的 bit 15
/// 与长度字的高 2 位是 RFU，按“忽略”处理（原文没有规定收方拒收）。
pub fn decodeIsoData(bytes: []const u8) Error!IsoDataPacket {
    if (bytes.len < iso_hdr_len) return error.Short;
    const flags = std.mem.readInt(u16, bytes[0..2], .little);
    const declared = std.mem.readInt(u16, bytes[2..4], .little) & 0x3FFF;
    const pb: PbFlag = @fromBackingInt(@intCast(@as(u2, @truncate(flags >> 12))));
    const ts_flag = (flags >> 14) & 1 != 0;
    const handle = flags & 0x0FFF;
    if (handle > conn_handle_max) return error.BadHandle;
    const tail = bytes.len - iso_hdr_len;
    if (tail < declared) return error.Short;
    if (tail > declared) return error.Trailing;
    const has_sdu_hdr = switch (pb) {
        .first_fragment, .complete_sdu => true,
        .continuation, .last_fragment => false,
    };
    if (!has_sdu_hdr) {
        // “If PB_Flag equals 0b01 or 0b11, then none of these fields shall be included.”
        if (ts_flag) return error.BadTs;
        if (declared > 0x3FFF) return error.Oversize;
        return .{
            .conn_handle = handle,
            .pb = pb,
            .ts_flag = false,
            .data_total_length = declared,
            .ts = null,
            .packet_sequence_number = null,
            .sdu_len = null,
            .status = null,
            .fragment = bytes[iso_hdr_len..bytes.len],
        };
    }
    const hdr_len: usize = if (ts_flag) sdu_hdr_len + ts_len else sdu_hdr_len;
    if (declared < hdr_len) return error.Short;
    var i: usize = iso_hdr_len;
    var ts: ?u32 = null;
    if (ts_flag) {
        ts = std.mem.readInt(u32, bytes[i..][0..4], .little);
        i += ts_len;
    }
    const seq = std.mem.readInt(u16, bytes[i..][0..2], .little);
    i += 2;
    const sdu_word = std.mem.readInt(u16, bytes[i..][0..2], .little);
    i += 2;
    const sdu_len: u12 = @truncate(sdu_word & 0x0FFF);
    const status: PacketStatus = @fromBackingInt(@intCast(@as(u2, @truncate(sdu_word >> 14))));
    switch (status) {
        .reserved => return error.BadStatus,
        .lost => {
            // “When Packet_Status_Flag is set to 0b10 … there is no data, PB_Flag
            // shall be set to 0b10, and ISO_SDU_Length shall be set to zero.”
            if (pb != .complete_sdu or sdu_len != 0 or declared != hdr_len) return error.BadStatus;
        },
        else => {},
    }
    return .{
        .conn_handle = handle,
        .pb = pb,
        .ts_flag = ts_flag,
        .data_total_length = declared,
        .ts = ts,
        .packet_sequence_number = seq,
        .sdu_len = sdu_len,
        .status = status,
        .fragment = bytes[i..bytes.len],
    };
}

// ---------------------------------------------------------------------------
// 5. LE Meta 事件分发
// ---------------------------------------------------------------------------

/// LE Meta 事件参数（从子事件码起）能解出的六种；其余子事件码原样交给调用方。
/// 带 Connection_Handle[i] 的两个事件把句柄解进 `out_handles`。
pub const LeEvent = union(enum) {
    cis_established: CisEstablished,
    cis_request: CisRequest,
    create_big_complete: BigComplete,
    big_sync_established: BigSyncEstablished,
    big_sync_lost: BigSyncLost,
    biginfo_adv_report: BigInfoReport,
    other: u8,
};

/// §7.7.65.34 LE BIGInfo Advertising Report 的参数（除 Sync_Handle 外都是
/// BIGInfo 字段的展开；PHY 已经换成 HCI 编码 0x01–0x03）。
pub const BigInfoReport = struct {
    sync_handle: u16,
    num_bis: u8,
    nse: u8,
    iso_interval: u16,
    bn: u8,
    pto: u8,
    irc: u8,
    max_pdu: u16,
    sdu_interval: u24,
    max_sdu: u16,
    phy: u8,
    framing: u8,
    encryption: u8,

    /// Handle(2)+Num_BIS(1)+NSE(1)+ISO_Interval(2)+BN(1)+PTO(1)+IRC(1)+Max_PDU(2)
    /// +SDU_Interval(3)+Max_SDU(2)+PHY(1)+Framing(1)+Encryption(1) = 19
    /// （NimBLE 的 ble_hci_ev_le_subev_biginfo_adv_report 含 subev_code 共 20 字节）。
    pub const packed_len: usize = 19;
};

pub fn parseBigInfoReport(p: []const u8) Error!BigInfoReport {
    if (p.len < BigInfoReport.packed_len) return error.Short;
    if (p.len > BigInfoReport.packed_len) return error.Trailing;
    const sh = std.mem.readInt(u16, p[0..2], .little);
    if (sh > conn_handle_max) return error.BadHandle;
    if (p[2] < 1 or p[2] > num_bis_max) return error.BadCount;
    if (p[3] < 1 or p[3] > num_bis_max) return error.BadParam;
    try validateBigBn(p[6]);
    try validatePto(p[7]);
    try validateIrc(p[8]);
    const pdu = std.mem.readInt(u16, p[9..11], .little);
    if (pdu < 1 or pdu > 0x00FB) return error.BadParam;
    const sdu_int = std.mem.readInt(u24, p[11..14], .little);
    if (sdu_int < sdu_interval_min or sdu_int > sdu_interval_max) return error.BadSduInterval;
    const max_sdu = std.mem.readInt(u16, p[14..16], .little);
    if (max_sdu < max_sdu_min or max_sdu > max_sdu_max) return error.BadMaxSdu;
    try validateEventPhy(p[16]);
    if (p[17] > 0x01) return error.BadFraming;
    if (p[18] > 0x01) return error.BadEncryption;
    return .{
        .sync_handle = sh,
        .num_bis = p[2],
        .nse = p[3],
        .iso_interval = std.mem.readInt(u16, p[4..6], .little),
        .bn = p[6],
        .pto = p[7],
        .irc = p[8],
        .max_pdu = pdu,
        .sdu_interval = sdu_int,
        .max_sdu = max_sdu,
        .phy = p[16],
        .framing = p[17],
        .encryption = p[18],
    };
}

/// 解一段 LE Meta 事件参数（`params` 从子事件码开始）；`out_handles` 容量至少 31。
pub fn decodeLeMetaEvent(params: []const u8, out_handles: []u16) Error!LeEvent {
    if (params.len < 1) return error.Short;
    switch (params[0]) {
        le_cis_established => return .{ .cis_established = try parseCisEstablished(params[1..]) },
        le_cis_request => return .{ .cis_request = try parseCisRequest(params[1..]) },
        le_create_big_complete => {
            return .{ .create_big_complete = try parseCreateBigComplete(params[1..], out_handles) };
        },
        le_big_sync_established => {
            return .{ .big_sync_established = try parseBigSyncEstablished(params[1..], out_handles) };
        },
        le_big_sync_lost => return .{ .big_sync_lost = try parseBigSyncLost(params[1..]) },
        le_biginfo_adv_report => return .{ .biginfo_adv_report = try parseBigInfoReport(params[1..]) },
        else => return .{ .other = params[0] },
    }
}

/// 解一帧完整的 H4 事件（04 + 0x3E + 长度 + 参数）。
pub fn decodeEvent(frame: []const u8, out_handles: []u16) Error!LeEvent {
    var stats: hci.Stats = .{};
    const ev = try hci.decodeEventFrame(frame, &stats);
    if (ev.code != hci.evt_le_meta) return error.Unsupported;
    return decodeLeMetaEvent(ev.params, out_handles);
}

// ---------------------------------------------------------------------------
// 6. BIG 参数公式（§4.4.6.3–§4.4.6.4；已知答案在 iso_tests.zig / 板侧自检里）
// ---------------------------------------------------------------------------

/// ISO_Interval 的 µs 值：N × 1.25 ms（§4.4.6.3 “in units of 1.25 ms”；
/// N 的范围 4–3200，即 5 ms–4 s）。
pub fn intervalUs(n: u32) u32 {
    return n * 1250;
}

/// §4.4.6.4：BIG_Sync_Delay = (Num_BIS − 1) × BIS_Spacing + (NSE − 1) × Sub_Interval + MPT。
/// MPT 是“按所用 PHY 发一个 Max_PDU 载荷包的空中时间”（Coded 按 S=8），属于时序
/// 计算，本文件不建模——由调用方给。
pub fn bigSyncDelayUs(num_bis: u32, bis_spacing_us: u32, nse: u32, sub_interval_us: u32, mpt_us: u32) u32 {
    return (num_bis - 1) * bis_spacing_us + (nse - 1) * sub_interval_us + mpt_us;
}

/// §4.4.6.4：BIS n 的 anchor point 在 BIG anchor point 之后 (n − 1) × BIS_Spacing。
pub fn bisAnchorOffsetUs(n: u32, bis_spacing_us: u32) u32 {
    return (n - 1) * bis_spacing_us;
}

/// §4.4.6.3：NSE 必须是 BN 的整数倍；GC = NSE ÷ BN。
pub fn groupCount(nse: u8, bn: u8) Error!u8 {
    if (bn < 1 or nse < 1) return error.BadGroupCount;
    if (nse % bn != 0) return error.BadGroupCount;
    return nse / bn;
}

/// §4.4.6.6：组 g（0 起）在 g < IRC 时装当前 BIS 事件的数据；否则装
/// PTO × (g − IRC + 1) 个 BIS 事件之后的数据。返回那个“事件偏移”（当前事件为 0）。
pub fn groupEventOffset(irc: u8, pto: u8, g: u8) u16 {
    if (g < irc) return 0;
    return @as(u16, pto) * (g - irc + 1);
}

/// §4.4.6.7：BIG_Control_Offset——Sequential 是 Num_BIS × BIS_Spacing，
/// Interleaved 是 NSE × Sub_Interval（µs）。
pub const Packing = enum { sequential, interleaved };

pub fn bigControlOffsetUs(arrangement: Packing, num_bis: u32, bis_spacing_us: u32, nse: u32, sub_interval_us: u32) u32 {
    return switch (arrangement) {
        .sequential => num_bis * bis_spacing_us,
        .interleaved => nse * sub_interval_us,
    };
}

/// §4.4.6.5 的注释：第 e 个 BIS 事件的 burst 是 bisPayloadCounter =
/// e × BN … (e + 1) × BN − 1（§4.4.6.3：bigEventCounter × BN = bisPayloadCounter）。
pub fn payloadRange(event: u39, bn: u8) struct { lo: u39, hi: u39 } {
    const b: u39 = bn;
    return .{ .lo = event * b, .hi = event * b + b - 1 };
}

/// BIG_Offset 的实际时间（µs）：14 位值 × 单位（30 / 300 µs）。
pub fn bigOffsetUs(offset_raw: u14, units_300: bool) u32 {
    const unit: u32 = if (units_300) big_offset_unit_300_us else big_offset_unit_us;
    return @as(u32, offset_raw) * unit;
}

test {
    _ = @import("iso_tests.zig");
}
