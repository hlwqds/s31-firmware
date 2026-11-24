//! ble-802154：新增模块的判据用常数表（HCI 控制 / ACL / L2CAP / GAP / IPSP / ATT）。
//!
//! 每个常数都有出处，分三类：
//!
//!   * **按规范的参数布局逐字节推出来的**（HCI 命令帧、返回参数、事件帧、
//!     L2CAP PDU）：出处是 Bluetooth Core 5.4 的条款号，写在各常数的注释里。
//!     期望值不是“跑一遍实现抄下来的”，而是先按条款把字节排出来，再让实现
//!     去命中；两边写错任何一边都对不上。
//!   * **独立实现算出来的交叉值**：`ah` 的输出由 Python `cryptography` 的
//!     AES-128 算出（2026-11-24），与 `gap_adv.zig` 里的 `std.crypto` AES
//!     是两份实现。不是官方向量，注释里写明。
//!   * **公开标准向量**：AES-128 的 FIPS-197 附录 B 例子。
//!
//! 十六进制字面量在编译期解码（`hex`），所以打错一个字符是编译错误，不是
//! 运行期的静默差异。

const hci = @import("hci.zig");

/// n 个 "00" 的十六进制串。0.17 里字符串不能再用 `**` 重复，所以在编译期循环拼。
fn hexZeros(comptime n: usize) [2 * n]u8 {
    var s: [2 * n]u8 = undefined;
    for (0..n) |i| {
        s[2 * i] = '0';
        s[2 * i + 1] = '0';
    }
    return s;
}

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("不是十六进制字符: " ++ .{c}),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    comptime {
        if (s.len % 2 != 0) @compileError("十六进制字面量必须是偶数长度");
    }
    var out: [s.len / 2]u8 = undefined;
    for (0..s.len / 2) |i| {
        out[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
    }
    return out;
}

/// HCI 字节序（最低有效字节在前）的示例设备地址：UI 写法 CD:E1:12:34:56:78。
/// 最高字节 0xCD = 0b1100_1101，最高两位 0b11 → 静态随机地址。
pub const dev_addr: [6]u8 = hex("78563412e1cd");

// ---------------------------------------------------------------------------
// AES / 随机地址哈希（[Vol 3] Part H §2.2.1、§2.2.2）
// ---------------------------------------------------------------------------

/// FIPS-197 附录 B：输入与密钥取自原文（PDF 第 41 页）；输出
/// 3925841d02dc09fbdc118597196a0b32 由 Python `cryptography` 独立算出。
pub const fips197_b_key: [16]u8 = hex("2b7e151628aed2a6abf7158809cf4f3c");
pub const fips197_b_input: [16]u8 = hex("3243f6a8885a308d313198a2e0370734");
pub const fips197_b_output: [16]u8 = hex("3925841d02dc09fbdc118597196a0b32");

/// §2.2.2 的例子：r = 0x423456 → r′ 的低 3 字节是 42 34 56，其余 13 字节为 0。
pub const ah_r_example_block: [16]u8 = hex("00000000000000000000000000423456");

/// IRK 取 FIPS-197 的密钥；prand = 0x5A3C21（最高两位 0b01，合法）。`rpa_prand`
/// 是地址字节序：最低有效字节 0x21 在前。
/// AES 输出 d65fee86c2bdcc861ca51605382a1254 → hash 取低 24 位 2a1254。
pub const rpa_irk: [16]u8 = fips197_b_key;
pub const rpa_prand: [3]u8 = hex("213c5a");
/// randomAddress = prand ‖ hash，地址字节序：hash 54 12 2a 在前，prand 21 3c 5a。
pub const rpa_addr: [6]u8 = hex("54122a213c5a");
/// 第二组：prand 0x423456（§2.2.2 例子的 r）→ 输出 4fa4d6d3b3486e377cd80a996f9a66b2，
/// hash 9a66b2。
pub const rpa_prand_2: [3]u8 = hex("563442");
pub const rpa_addr_2: [6]u8 = hex("b2669a563442");
/// 一个“错的” IRK：FIPS-197 的输入当密钥。
pub const wrong_irk: [16]u8 = fips197_b_input;

// ---------------------------------------------------------------------------
// HCI 命令帧：H4(01) + OpCode(小端) + 参数长度 + 参数
// OGF/OCF 见各条注释；布局见 [Vol 4] Part E 的对应小节。
// ---------------------------------------------------------------------------

/// HCI_Reset：OGF 0x03 / OCF 0x0003，无参数。§7.3.2。
pub const hci_reset: [4]u8 = hex("01030c00");
/// HCI_Read_Local_Version_Information：OGF 0x04 / OCF 0x0001。§7.4.1。
pub const hci_read_local_version: [4]u8 = hex("01011000");
/// HCI_Read_Local_Supported_Features：OGF 0x04 / OCF 0x0003。§7.4.3。
pub const hci_read_local_features: [4]u8 = hex("01031000");
/// HCI_Read_BD_ADDR：OGF 0x04 / OCF 0x0009。§7.4.6。
pub const hci_read_bd_addr: [4]u8 = hex("01091000");

/// HCI_Disconnect：Connection_Handle=0x0042、Reason=0x13（Remote User Terminated
/// Connection）。OGF 0x01 / OCF 0x0006。§7.1.6。
pub const hci_disconnect: [7]u8 = hex("01060403420013");

/// LE_Set_Event_Mask，掩码 0x1F（规范默认：bit 0–4）。OCF 0x0001。§7.8.1。
pub const hci_le_set_event_mask: [12]u8 = hex("010120081f00000000000000");
/// LE_Read_Buffer_Size [v1]：OCF 0x0002。§7.8.2。
pub const hci_le_read_buffer_size_v1: [4]u8 = hex("01022000");
/// LE_Read_Buffer_Size [v2]：OCF 0x0060。§7.8.2。
pub const hci_le_read_buffer_size_v2: [4]u8 = hex("01602000");
/// LE_Read_Local_Supported_Features：OCF 0x0003。§7.8.3。
pub const hci_le_read_local_features: [4]u8 = hex("01032000");
/// LE_Set_Random_Address：Random_Address = `dev_addr`。OCF 0x0005。§7.8.4。
pub const hci_le_set_random_address: [10]u8 = hex("0105200678563412e1cd");

/// LE_Set_Advertising_Parameters：间隔 0x0800/0x0800（1.28 s）、ADV_IND、
/// 自有地址公有、对端公有、对端地址全 0、信道图 0x07、过滤策略 0。
/// 顺序见 §7.8.5。OCF 0x0006。
pub const hci_le_set_adv_params: [19]u8 = hex("0106200f000800080000000000000000000700");
/// 同上，但高占空比定向：Type=0x01、对端随机地址 `dev_addr`。
pub const hci_le_set_adv_params_directed: [19]u8 = hex("0106200f0008000801000178563412e1cd0700");

/// Flags 0x06 + 完整 16 位 UUID 0x180A + 完整本地名 "ch27"：共 13 字节 AD
/// （与 `hci.kat_adv_data` 相同）。
pub const adv_flags_name: [13]u8 = hex("02010603030a18050963683237");
/// LE_Set_Advertising_Data：长度 13 + 13 字节 + 18 个 0。OCF 0x0008。§7.8.7。
pub const hci_le_set_adv_data: [36]u8 = hex("01082020" ++ "0d" ++ "02010603030a18050963683237" ++ hexZeros(18));

/// 扫描响应数据：TX Power +4 dBm、缩短名 "s31"：共 7 字节 AD。
pub const scan_rsp_txpower_name: [8]u8 = hex("020a040408733331");
/// LE_Set_Scan_Response_Data：长度 7 + 7 字节 + 24 个 0。OCF 0x0009。§7.8.8。
pub const hci_le_set_scan_rsp_data: [36]u8 = hex("01092020" ++ "08" ++ "020a040408733331" ++ hexZeros(23));

/// LE_Set_Advertising_Enable：开 / 关。OCF 0x000A。§7.8.9。
pub const hci_le_set_adv_enable_on: [5]u8 = hex("010a200101");
pub const hci_le_set_adv_enable_off: [5]u8 = hex("010a200100");

/// LE_Set_Scan_Parameters：被动扫描、间隔 0x0010、窗口 0x0010、自有地址公有、
/// 不过滤。OCF 0x000B。§7.8.10。
pub const hci_le_set_scan_params_passive: [11]u8 = hex("010b200700100010000000");
/// 主动扫描、间隔 0x0030、窗口 0x0018、自有地址随机、扩展过滤策略 0x02。
pub const hci_le_set_scan_params_active: [11]u8 = hex("010b200701300018000102");

/// LE_Set_Scan_Enable：开扫描、开重复过滤。OCF 0x000C。§7.8.11。
pub const hci_le_set_scan_enable: [6]u8 = hex("010c20020101");

/// LE_Create_Connection：扫描间隔/窗口 0x0010、不过滤、对端随机地址
/// `dev_addr`、自有地址公有、连接间隔 0x0018–0x0028、Max_Latency 0、
/// Supervision_Timeout 0x00C8、Min/Max_CE_Length 0。12 个参数共 25 字节。
/// OCF 0x000D。§7.8.12。
pub const hci_le_create_connection: [29]u8 = hex("010d2019" ++ "10001000000178563412e1cd00180028000000c80000000000");

/// LE_Connection_Update：句柄 0x0042、间隔 0x0006–0x000C、Max_Latency 4、
/// Supervision_Timeout 0x00C8、CE_Length 0/0。OCF 0x0013。§7.8.18。
pub const hci_le_connection_update: [18]u8 = hex("0113200e" ++ "420006000c000400c80000000000");

/// LE_Read_Supported_States：OCF 0x001C。§7.8.27。
pub const hci_le_read_supported_states: [4]u8 = hex("011c2000");

/// LE_Enable_Encryption：句柄 0x0042、Random 0706050403020100、EDIV 0x1234、
/// LTK = FIPS 密钥。OCF 0x0019。§7.8.24。
pub const enc_random: [8]u8 = hex("0706050403020100");
pub const hci_le_enable_encryption: [32]u8 = hex("0119201c" ++ "4200" ++ "0706050403020100" ++ "3412" ++ "2b7e151628aed2a6abf7158809cf4f3c");

/// LE_Long_Term_Key_Request_Reply：句柄 + LTK。OCF 0x001A。§7.8.25。
pub const hci_le_ltk_request_reply: [22]u8 = hex("011a2012" ++ "4200" ++ "2b7e151628aed2a6abf7158809cf4f3c");
/// LE_Long_Term_Key_Request_Negative_Reply：句柄。OCF 0x001B。§7.8.26。
pub const hci_le_ltk_request_negative_reply: [6]u8 = hex("011b20024200");

/// LE_Read_Maximum_Data_Length：OCF 0x002F。§7.8.46。
pub const hci_le_read_max_data_length: [4]u8 = hex("012f2000");
/// LE_Set_Data_Length：句柄 0x0042、TX_Octets 0x00FB（251）、TX_Time 0x0848
/// （2120 µs，范围下限）。OCF 0x0022。§7.8.33。
pub const hci_le_set_data_length: [10]u8 = hex("01222006" ++ "4200" ++ "fb00" ++ "4808");

// ---------------------------------------------------------------------------
// Command Complete 的返回参数（已去掉 Num_HCI_Command_Packets 与 OpCode）
// ---------------------------------------------------------------------------

/// Read_Local_Version_Information：Status、HCI_Version 0x0B、HCI_Subversion
/// 0x1234、LMP_Version 0x0C、Company_Identifier 0xABCD、LMP_Subversion 0x5678。
/// 版本号只当不透明字节用，不声称对应哪个版本。§7.4.1。
pub const ret_read_local_version: [9]u8 = hex("000b34120ccdab7856");
/// Read_BD_ADDR：Status + `dev_addr`。§7.4.6。
pub const ret_read_bd_addr: [7]u8 = hex("0078563412e1cd");
/// Read_Local_Supported_Features：Status + 8 字节 LMP_Features。§7.4.3。
pub const ret_read_local_features: [9]u8 = hex("000100000000000000");
/// LE_Read_Buffer_Size [v1]：LE_ACL_Data_Packet_Length 0x001B（27）、
/// Total_Num_LE_ACL_Data_Packets 8。§7.8.2。
pub const ret_le_read_buffer_size_v1: [4]u8 = hex("001b0008");
/// LE_Read_Buffer_Size [v2]：同上，外加 ISO 长度 0、ISO 包数 0。§7.8.2。
pub const ret_le_read_buffer_size_v2: [7]u8 = hex("001b0008000000");
/// LE_Read_Local_Supported_Features：Status + 8 字节 LE_Features。§7.8.3。
pub const ret_le_read_local_features: [9]u8 = hex("001f00000000000000");
/// LE_Read_Supported_States：Status + 8 字节 LE_States（bit 0–8 置位）。§7.8.27。
pub const ret_le_read_supported_states: [9]u8 = hex("00ff03000000000000");
/// LE_Read_Maximum_Data_Length：四个 0x00FB / 0x0848。§7.8.46。
pub const ret_le_read_max_data_length: [9]u8 = hex("00" ++ "fb004808" ++ "fb004808");
/// LE_Long_Term_Key_Request_Reply 的返回：Status + Connection_Handle。§7.8.25。
pub const ret_le_ltk_reply: [3]u8 = hex("004200");

// ---------------------------------------------------------------------------
// 事件帧：H4(04) + Event_Code + 参数长度 + 参数
// ---------------------------------------------------------------------------

/// Command Complete：Num_HCI_Command_Packets=1、OpCode=LE_Read_Buffer_Size [v1]、
/// 返回参数 = `ret_le_read_buffer_size_v1`。§7.7.14。
pub const evt_cc_le_read_buffer_size: [10]u8 = hex("040e07" ++ "01" ++ "0220" ++ "001b0008");
/// 同上，但帧比声明的长度短 2 字节。
pub const evt_cc_truncated: [8]u8 = hex("040e07" ++ "01" ++ "0220" ++ "001b");
/// Command Complete 指向一个本组件不认识的 OpCode 0xFCFF。
pub const evt_cc_unknown_opcode: [7]u8 = hex("040e0401fffc00");

/// Command Status：成功（Status 0）、Num=1、OpCode=LE_Create_Connection。§7.7.15。
pub const evt_command_status_ok: [7]u8 = hex("040f0400010d20");
/// Command Status：失败，Status 0x12（Invalid HCI Command Parameters）。
pub const evt_command_status_fail: [7]u8 = hex("040f0412010d20");

/// Disconnection Complete：Status 0、句柄 0x0042、Reason 0x16（Connection
/// Terminated by Local Host）。§7.7.5。
pub const evt_disconnection_complete: [7]u8 = hex("04050400420016");

/// Hardware Error：Hardware_Code 0x07。§7.7.16。
pub const evt_hardware_error: [4]u8 = hex("04100107");

/// Number Of Completed Packets：Num_Handles=2，(0x0042, 3)、(0x0043, 1)。
/// 句柄与计数按 §5.2 的数组默认顺序成对排列。§7.7.19。
pub const evt_number_of_completed_packets: [12]u8 = hex("041309" ++ "02" ++ "42000300" ++ "43000100");
/// 同上，但 Num_Handles 写 3、实际只有 2 对 → 截断。
pub const evt_number_of_completed_packets_short: [12]u8 = hex("041309" ++ "03" ++ "42000300" ++ "43000100");

/// LE Connection Complete 的参数（不含子事件码）：Status 0、句柄 0x0042、
/// 角色 0（Central）、对端公有地址 E0:E1:E2:E3:E4:E5、间隔 0x0006、
/// Peripheral_Latency 0、Supervision_Timeout 0x00C8、CCA 0。§7.7.65.1。
pub const le_conn_complete_params: [18]u8 = hex("0042000000e0e1e2e3e4e506000000c80000");
/// 完整帧：0x3E、长度 19、子事件码 0x01。
pub const evt_le_conn_complete: [22]u8 = hex("043e13" ++ "01" ++ "0042000000e0e1e2e3e4e506000000c80000");

/// LE Advertising Report：子事件 0x02、1 条报告（ADV_IND、公有地址
/// E0:E1:E2:E3:E4:E5、13 字节 AD、RSSI 0xC0 = −64 dBm）。§7.7.65.2。
pub const adv_report_data: [13]u8 = hci.kat_adv_data;
pub const evt_le_adv_report_one: [28]u8 = hex("043e19" ++ "02" ++ "01" ++ "00" ++ "00" ++ "e0e1e2e3e4e5" ++ "0d" ++ "02010603030a18050963683237" ++ "c0");
/// LE Advertising Report：子事件 0x02、2 条报告。第二条是 SCAN_RSP（Event_Type
/// 0x04）、随机地址 `dev_addr`、8 字节扫描响应数据、RSSI 0x9C（−100 dBm）。
pub const evt_le_adv_report_two: [46]u8 = hex("043e2b" ++ "02" ++ "02" ++ "00" ++ "00" ++ "e0e1e2e3e4e5" ++ "0d" ++ "02010603030a18050963683237" ++ "c0" ++ "04" ++ "01" ++ "78563412e1cd" ++ "08" ++ "020a040408733331" ++ "9c");

/// LE Connection Update Complete：Status 0、句柄 0x0042、间隔 0x0018、
/// Peripheral_Latency 4、Supervision_Timeout 0x00C8。§7.7.65.3。
pub const evt_le_conn_update: [13]u8 = hex("043e0a" ++ "03" ++ "00" ++ "4200" ++ "1800" ++ "0400" ++ "c800");

/// LE Long Term Key Request：句柄 0x0042、Random_Number、EDIV 0x1234。§7.7.65.5。
pub const evt_le_ltk_request: [16]u8 = hex("043e0d" ++ "05" ++ "4200" ++ "0706050403020100" ++ "3412");

/// LE Data Length Change：句柄 0x0042、Max_TX/RX_Octets 0x00FB、
/// Max_TX/RX_Time 0x0848。§7.7.65.7。
pub const evt_le_data_length_change: [14]u8 = hex("043e0b" ++ "07" ++ "4200" ++ "fb004808" ++ "fb004808");

/// 一个 5.4 没定义的 LE 子事件码 0x7F。§5.4.4：host 应忽略不认识的子事件。
pub const evt_le_unknown_subevent: [6]u8 = hex("043e03" ++ "7f" ++ "0000");

// ---------------------------------------------------------------------------
// ACL（[Vol 4] Part E §5.4.2）：句柄 0x0002、LE-U Host→Controller
// ---------------------------------------------------------------------------

/// 首片：PB=0b00、Data_Total_Length=27。
pub const acl_hdr_first: [4]u8 = hex("02001b00");
/// 续片：PB=0b01、Data_Total_Length=27。
pub const acl_hdr_cont: [4]u8 = hex("02101b00");
/// 末片：PB=0b01、Data_Total_Length=7（61 = 27 + 27 + 7）。
pub const acl_hdr_last: [4]u8 = hex("02100700");
/// Controller→Host 的首片：PB=0b10。
pub const acl_hdr_from_ctrl: [4]u8 = hex("02201b00");

// ---------------------------------------------------------------------------
// L2CAP（[Vol 3] Part A）
// ---------------------------------------------------------------------------

/// B-frame：ATT Read Request（0A 25 00）走 CID 0x0004。§3.1、表 2.3。
pub const l2cap_bframe_read_req: [7]u8 = hex("030004000a2500");

/// Connection Parameter Update Request：标识符 0x01、间隔 0x0006–0x000C、
/// Latency 0、Timeout 0x00C8。信令头见 §4；字段见 图 4.16 与 §4.20。
pub const l2cap_cpu_req: [16]u8 = hex("0c000500" ++ "1201" ++ "0800" ++ "06000c000000c800");
/// Response：接受（0x0000）/ 拒绝（0x0001）。§4.21 表 4.14。
pub const l2cap_cpu_rsp_accept: [10]u8 = hex("06000500" ++ "1301" ++ "0200" ++ "0000");
pub const l2cap_cpu_rsp_reject: [10]u8 = hex("06000500" ++ "1301" ++ "0200" ++ "0100");

/// LE Credit Based Connection Request：标识符 0x02、SPSM 0x0023（Assigned
/// Numbers 的 LE_PSM_IPSP）、SCID 0x0040、MTU 1280（0x0500）、MPS 128（0x0080）、
/// Initial Credits 10。5 个字段各 2 字节，数据长 10。§4.22 图 4.18。
pub const l2cap_lcbc_req: [18]u8 = hex("0e000500" ++ "1402" ++ "0a00" ++ "23004000000580000a00");
/// Response：DCID 0x0041、MTU 1280、MPS 128、Initial Credits 10、Result 0。§4.23 图 4.19。
pub const l2cap_lcbc_rsp_ok: [18]u8 = hex("0e000500" ++ "1502" ++ "0a00" ++ "4100000580000a000000");
/// Response：拒绝，Result 0x0002（SPSM not supported）。表 4.16。
pub const l2cap_lcbc_rsp_refused: [18]u8 = hex("0e000500" ++ "1502" ++ "0a00" ++ "4100000580000a000200");

/// Flow Control Credit Ind：标识符 0x03、CID 0x0041、Credits 5。§4.24 图 4.20。
pub const l2cap_credit_ind: [12]u8 = hex("08000500" ++ "1603" ++ "0400" ++ "41000500");

/// Command Reject：标识符 0x05、Reason 0x0000（Command not understood）。§4.1。
pub const l2cap_cmd_reject: [10]u8 = hex("06000500" ++ "0105" ++ "0200" ++ "0000");

/// K-frame 首帧：PDU 长度 = 2 + 6、CID 0x0041、SDU 长度 10、载荷 6 字节。§3.4。
pub const l2cap_k_first: [12]u8 = hex("08004100" ++ "0a00" ++ "aabbccddeeff");
/// K-frame 续帧：PDU 长度 4、载荷 4 字节。
pub const l2cap_k_cont: [8]u8 = hex("0400410011223344");

// ---------------------------------------------------------------------------
// IPv6 over BLE（RFC 7668、RFC 6282）
// ---------------------------------------------------------------------------

/// 6LN 的 BLE 地址（地址字节序）；UI 写法 F0:C0:2C:1D:0A:11。
pub const ipsp_addr_6ln: [6]u8 = hex("110a1d2cc0f0");
/// 6LBR 的 BLE 地址；UI 写法 F6:55:44:33:B2:0D。
pub const ipsp_addr_6lbr: [6]u8 = hex("0db2334455f6");
/// 6LN 的 IID（§3.2.2 图 6：地址中间插 FF FE，位原样拷贝）。
pub const ipsp_iid_6ln: [8]u8 = hex("f0c0fffe2c1d0a11");
pub const ipsp_iid_6lbr: [8]u8 = hex("f655fffe4433b20d");
/// 6LN 的链路本地地址（§3.2.2 图 7）。
pub const ipsp_ll_6ln: [16]u8 = hex("fe80000000000000" ++ "f0c0fffe2c1d0a11");
pub const ipsp_ll_6lbr: [16]u8 = hex("fe80000000000000" ++ "f655fffe4433b20d");

/// CoAP 口径的 UDP 载荷 "coap"：源/目的端口 5683（0x1633）、校验和 0x1234。
pub const ipsp_udp_nhc: [9]u8 = hex("f0" ++ "16331633" ++ "1234" ++ "636f6170");

/// 链路本地 → 链路本地，Hop Limit 64，两端地址全省略：
/// IPHC = 011 TF=11 NH=1 HLIM=10 | CID=0 SAC=0 SAM=11 M=0 DAC=0 DAM=11。
pub const iphc_ll_ll_hlim64: [13]u8 = hex("7e33" ++ "f0163316331234636f6170");
/// 同上，Hop Limit 255（HLIM=11）。
pub const iphc_ll_ll_hlim255: [13]u8 = hex("7f33" ++ "f0163316331234636f6170");
/// 目的 ff02::1（all-nodes）：M=1、DAM=11（ff02::00XX），内联 1 字节。
pub const iphc_ll_mcast_ff02_1: [14]u8 = hex("7e3b" ++ "01" ++ "f0163316331234636f6170");
/// 内联 Next Header（ICMPv6 58 = 0x3A），没有 NHC。
pub const iphc_ll_icmp: [11]u8 = hex("7b33" ++ "3a" ++ "8000000101020304");

/// RFC 7668 §3.2.4.1：6LN → 远端。源是已登记的全球地址（上下文 0），目的在
/// 上下文 1 的 64 位前缀下：SAC=1 SAM=11 DAC=1 DAM=01，CID=1（SCI 0、DCI 1），
/// 目的 IID 8 字节内联。
pub const iphc_7668_6ln_to_remote_dam01: [22]u8 = hex("7ef5" ++ "01" ++ "0000000000000005" ++ "f0163316331234636f6170");
/// RFC 7668 §3.2.4.1：目的由 128 位上下文覆盖 → DAM=11，地址不内联。
pub const iphc_7668_6ln_to_remote_dam11: [14]u8 = hex("7ef7" ++ "01" ++ "f0163316331234636f6170");
/// RFC 7668 §3.2.4.1：6LBR → 6LN。源在 64 位上下文下 → SAC=1 SAM=01（IID 内联），
/// 目的是 6LN 最近登记的地址 → DAC=1 DAM=11；两者同上下文 → CID=0。
pub const iphc_7668_6lbr_to_6ln_sam01: [21]u8 = hex("7e57" ++ "f655fffe4433b20d" ++ "f0163316331234636f6170");
/// RFC 7668 §3.2.4.1：源由 128 位上下文（上下文 2）覆盖 → SAM=11，CID=1（SCI 2）。
pub const iphc_7668_6lbr_to_6ln_sam11: [14]u8 = hex("7ef7" ++ "20" ++ "f0163316331234636f6170");

/// RFC 7668 §3.2.4.2：上下文 0 = 2001:db8::/64，最近登记的 IID 是
/// 1111:2222:3333:5555。源 2001:db8::1111:2222:3333:5555（最近登记）→
/// SAC=1 SAM=11；目的是对端链路本地地址 → DAC=0 DAM=11。
pub const iphc_7668_3242_sam11: [13]u8 = hex("7e73" ++ "f0163316331234636f6170");
/// RFC 7668 §3.2.4.2：源 2001:db8::1111:2222:3333:4444（前 48 位与最近登记的
/// 相同）→ SAC=1 SAM=10，内联 4444。
pub const iphc_7668_3242_sam10: [15]u8 = hex("7e63" ++ "4444" ++ "f0163316331234636f6170");
/// RFC 7668 §3.2.4.2：源 2001:db8::9999:2222:3333:4444（前 48 位不同）→
/// SAC=1 SAM=01，IID 8 字节内联。
pub const iphc_7668_3242_sam01: [21]u8 = hex("7e53" ++ "9999222233334444" ++ "f0163316331234636f6170");

/// 一个 UDP 校验和被省略（C=1）的 NHC：RFC 6282 §4.3.2 要求解压方重算并确认
/// 另有完整性保护；本组件做不到，所以拒收。
pub const iphc_udp_checksum_elided: [11]u8 = hex("7f33" ++ "f4" ++ "16331633" ++ "636f6170");
/// 6LoWPAN 分片头（FRAG1，11000xxx）：RFC 7668 §3 明确 BLE 不用 6LoWPAN 分片。
pub const lowpan_frag1: [4]u8 = hex("c0010000");

// ---------------------------------------------------------------------------
// AES-CMAC 与 ATT 数据签名（[Vol 3] Part H §2.2.5、§2.4.5；Part F §3.4.5.4；Part G 附录 B）
// ---------------------------------------------------------------------------

/// [Vol 3] Part H 附录 D.1 引自 RFC 4493 的四个例子：密钥、对全零块的加密结果与两个子密钥。
/// 附录 D 开头写明「字节按最高有效在左排列」，与 RFC 4493 的写法一致。
pub const cmac_key: [16]u8 = hex("2b7e151628aed2a6abf7158809cf4f3c");
pub const cmac_l: [16]u8 = hex("7df76b0c1ab899b33e42f047b91b546f");
pub const cmac_k1: [16]u8 = hex("fbeed618357133667c85e08f7236a8de");
pub const cmac_k2: [16]u8 = hex("f7ddac306ae266ccf90bc11ee46d513b");

/// 例 1（空消息）与例 2（16 字节）。
pub const cmac_t0: [16]u8 = hex("bb1d6929e95937287fa37d129b756746");
pub const cmac_m16: [16]u8 = hex("6bc1bee22e409f96e93d7e117393172a");
pub const cmac_t16: [16]u8 = hex("070a16b46b4d4144f79bdd9dd04a287c");
/// 例 3（40 字节：16 + 16 + 8）与例 4（64 字节）。
pub const cmac_m40: [40]u8 = hex(cmac_m16_hex ++ "ae2d8a571e03ac9c9eb76fac45af8e51" ++ "30c81c46a35ce411");
pub const cmac_t40: [16]u8 = hex("dfa66747de9ae63030ca32611497c827");
pub const cmac_m64: [64]u8 = hex(cmac_m40_hex ++ "e5fbc1191a0a52ef" ++ "f69f2445df4f9b17ad2b417be66c3710");
pub const cmac_t64: [16]u8 = hex("51f0bebf7e3b9d92fc49741779363cfe");

const cmac_m16_hex = "6bc1bee22e409f96e93d7e117393172a";
const cmac_m40_hex = cmac_m16_hex ++ "ae2d8a571e03ac9c9eb76fac45af8e51" ++ "30c81c46a35ce411";

/// [Vol 3] Part G 附录 B：数据库哈希的输入 m（M0–M6，共 111 字节，按原文的写法）与
/// 结果 AES-CMAC（密钥全零）。本组件不实现数据库哈希，只把它当作 CMAC 的多块向量。
pub const gatt_db_hash_m: [111]u8 = hex(
    "010000280018020003280a0300002a04" ++
        "000328020500012a0600002801180700" ++
        "0328200800052a090002290a0003280a" ++
        "0b00292b0c000328020d002a2b0e0000" ++
        "2808180f000228140016000f18100003" ++
        "28a21100182a12000229130000290000" ++
        "140001280f1815000328021600192a",
);
pub const gatt_db_hash: [16]u8 = hex("f1ca2d48ecf58bac8a8830bbb9fba990");

/// [Vol 3] Part F §3.4.5.4 的例子：句柄 0x0012、值 13 37 的 ATT_SIGNED_WRITE_CMD，
/// SignCounter = 1，CSRK 与 CMAC 见下。最后的签名写消息原文写作
/// ‘D21200133701000000F1871E933C900FF2’。
pub const signed_write_pdu: [17]u8 = hex("d212001337" ++ "01000000" ++ "f1871e933c900ff2");
pub const signed_write_csrk: [16]u8 = hex("611b64ebfbcd1fd372ec9196df425e50");
pub const signed_write_cmac: [16]u8 = hex("f20f903c931e87f159b64f012574b4d0");
pub const signed_write_sig: [12]u8 = hex("01000000" ++ "f1871e933c900ff2");
