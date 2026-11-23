//! wifi-mlme：判据用的固定向量。
//!
//! 每个向量都写明出处，共三类：
//!
//!   * **IEEE Std 802.11-2016 原文**：Annex J.9（印刷页 3426–3428）的管理帧保护
//!     向量、9.4.2.25.1 NOTE（p.883–884）的 RSNE 样例。页码为印刷页码。
//!   * **Wireshark wiki SampleCaptures 的公开抓包**：`wpa-Induction.pcap`（帧号按
//!     文件内顺序从 1 数起，帧尾保留了 FCS；该文件 1093 帧中有 724 帧的末 4 字节
//!     等于前文的 CRC-32，这里的帧都取自其中）与 `mesh.pcap`（不含 FCS，只取
//!     Country / TIM 元素）。十六进制由脚本按字段切好逐段抄录，再由
//!     `host_tests.zig` 的解析用例逐字段核对。
//!   * **本工程手工构造**：按所引条款的字段布局逐字节搭出来，用来覆盖抓包里
//!     没有的形态（四地址帧、QoS Control、非零 TIM 位图、Operating Triplet、
//!     Extended Capabilities）。
//!
//! 十六进制字面量在编译期解码（`hex`），打错一个字符是编译错误。

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

// ---------------------------------------------------------------------------
// Annex J.9.1（p.3426–3427）：BIP 保护的广播 Deauthentication 帧（原文不含 FCS）
// ---------------------------------------------------------------------------

/// 未保护的广播 Deauthentication 帧，26 字节。
/// FC=c0 00，DA=广播，SA=BSSID=02:00:00:00:00:00，SEQ=09 00，Reason Code=2。
pub const j91_deauth_plain: [26]u8 =
    hex("c0000000ffffffffffff02000000000002000000000009000200");

/// 加了 MME 的同一帧，44 字节。原文注明 Protected 标志**不**置位（组地址帧）。
pub const j91_deauth_bip: [44]u8 =
    hex("c0000000ffffffffffff02000000000002000000000009000200" ++
        "4c100400" ++ "040000000000" ++ "48dfbfa7b8278872");

/// MME 元素（Element ID 76，Length 16）：Key ID=4，IPN=4，MIC 8 字节。
pub const j91_mme_element: [18]u8 = hex("4c100400" ++ "040000000000" ++ "48dfbfa7b8278872");
pub const j91_mmie_body: [16]u8 = j91_mme_element[2..18].*;
pub const j91_mme_mic: [8]u8 = hex("48dfbfa7b8278872");
pub const j91_mmie_key_id: u16 = 4;
pub const j91_mmie_ipn: u64 = 4;

// ---------------------------------------------------------------------------
// Annex J.9.2（p.3428）：CCMP-128 保护的单播 Deauthentication 帧（原文不含 FCS）
// ---------------------------------------------------------------------------

/// 明文单播 Deauthentication 帧，26 字节。DA=02:00:00:00:01:00，SA=BSSID=
/// 02:00:00:00:00:00，SEQ=60 00（序号 6，分片 0），Reason Code=2。
pub const j92_deauth_plain: [26]u8 =
    hex("c000000002000000010002000000000002000000000060000200");

/// 原文 AAD 的前两字节 `c0 40`：Protected Frame 位置 1 之后的 Frame Control。
pub const j92_aad_frame_control: [2]u8 = hex("c040");

// ---------------------------------------------------------------------------
// 9.4.2.25.1 NOTE（p.883–884）：RSNE 样例，逐字节抄自原文
// ---------------------------------------------------------------------------

/// 「802.1X authentication, CCMP-128 pairwise and group cipher suites」。
pub const rsne_8021x_ccmp: [22]u8 = hex("30140100000fac040100000fac040100000fac010000");
/// 同上，但 RSN Capabilities = 0x0001（Preauthentication）。
pub const rsne_8021x_ccmp_preauth: [22]u8 = hex("30140100000fac040100000fac040100000fac010100");
/// 「Use GTK for pairwise cipher suite, WEP-40 group … optional RSN Capabilities omitted」。
pub const rsne_wep40_no_caps: [20]u8 = hex("30120100000fac010100000fac000100000fac01");
/// 「preauthentication and a PMKID」：PMKID = 01 02 … 10。
pub const rsne_8021x_pmkid: [40]u8 =
    hex("30260100000fac040100000fac040100000fac010100" ++
        "01000102030405060708090a0b0c0d0e0f10");
/// 「management frame protection with AES-128-CMAC as the group management suite」：
/// RSN Capabilities = 0x0080（MFPC），PMKID Count = 0，Group Management = BIP-CMAC-128。
pub const rsne_8021x_mfpc_bip: [28]u8 =
    hex("301a0100000fac040100000fac040100000fac0180000000000fac06");

// ---------------------------------------------------------------------------
// Wireshark wiki SampleCaptures：wpa-Induction.pcap（帧尾含 FCS）
// ---------------------------------------------------------------------------

pub const cap_sta: [6]u8 = hex("000d9382363a");
pub const cap_ap: [6]u8 = hex("000c4182b255");
pub const cap_ssid = "Coherer";

/// 第 78 帧：STA→AP 的 Open System Authentication（seq 1），34 字节。
pub const cap_auth_1: [34]u8 =
    hex("b0003a01000c4182b255000d9382363a000c4182b2557001" ++
        "0000" ++ "0100" ++ "0000" ++
        "0df2fd2d");
/// 第 80 帧：AP→STA 的 Authentication（seq 2，SUCCESS），带一个厂商特定元素，42 字节。
pub const cap_auth_2: [42]u8 =
    hex("b0003a01000d9382363a000c4182b255000c4182b25590fc" ++
        "0000" ++ "0200" ++ "0000" ++
        "dd06001018020004" ++
        "65f43096");
/// 第 82 帧：STA→AP 的 Association Request，79 字节。Capability=0x0431，
/// Listen Interval=10，SSID=Coherer，Supported Rates，RSNE，Extended Supported Rates。
/// 这台客户端把 RSNE 排在 Extended Supported Rates 之前，与 Table 9-29 的相对顺序
/// 不同；解析端按元素 ID 取，不依赖顺序。
pub const cap_assoc_req: [79]u8 =
    hex("00003a01000c4182b255000d9382363a000c4182b2558001" ++
        "3104" ++ "0a00" ++
        "0007436f6865726572" ++
        "010882848b962430486c" ++
        "30140100000fac020100000fac040100000fac020000" ++
        "32040c121860" ++
        "21192eed");
/// 第 84 帧：AP→STA 的 Association Response，58 字节。Capability=0x0411，
/// Status=SUCCESS，AID 字段原值 0xc001（高 5 位被 AP 置了 1，按 9.4.1.8 取低 11 位 = 1）。
pub const cap_assoc_resp: [58]u8 =
    hex("10003a01000d9382363a000c4182b255000c4182b255a0fc" ++
        "1104" ++ "0000" ++ "01c0" ++
        "010882848b962430486c" ++
        "32040c121860" ++
        "dd06001018020004" ++
        "4ea3d60e");
/// 第 1050 帧：AP→STA 的 Disassociation，30 字节。SEQ=50 0b（序号 181），
/// Reason Code = 8（LEAVING_NETWORK_DISASSOC）。
pub const cap_disassoc: [30]u8 =
    hex("a0003a01000c4182b255000d9382363a000c4182b255500b" ++
        "0800" ++
        "feaa65ac");
/// 第 58 帧：STA 发出的 Probe Request（Address 3 = 通配 BSSID），53 字节。
pub const cap_probe_req: [53]u8 =
    hex("40000000ffffffffffff000d9382363affffffffffff1000" ++
        "0007436f6865726572" ++
        "010802040b162430486c" ++
        "32040c121860" ++
        "f789666d");
/// 第 59 帧：AP 的 Probe Response，138 字节。Timestamp=0x011c23ff61，
/// Beacon Interval=100，Capability=0x0411，信道 1，RSNE = TKIP 组 /
/// CCMP+TKIP 单播 / PSK。`2f 01 02` 是 Table 9-77 里保留的元素 ID，解析端应跳过。
pub const cap_probe_resp: [138]u8 =
    hex("50003a01000d9382363a000c4182b255000c4182b255f0fb" ++
        "61ff231c01000000" ++ "6400" ++ "1104" ++
        "0007436f6865726572" ++
        "010882848b962430486c" ++
        "030101" ++
        "2a0102" ++
        "2f0102" ++
        "30180100000fac020200000fac04000fac020100000fac020000" ++
        "32040c121860" ++
        "dd06001018020004" ++
        "dd1c0050f20101000050f20202000050f2040050f20201000050f2020000" ++
        "0bbc2c14");
/// 第 1 帧：AP 的 Beacon，144 字节。Timestamp=0x011bd4f189，Beacon Interval=100，
/// Capability=0x0411，DSSS Parameter Set 信道 1，TIM = `05 04 00 01 00 00`。
pub const cap_beacon: [144]u8 =
    hex("80000000ffffffffffff000c4182b255000c4182b25550f8" ++
        "89f1d41b01000000" ++ "6400" ++ "1104" ++
        "0007436f6865726572" ++
        "010882848b962430486c" ++
        "030101" ++
        "050400010000" ++
        "2a0102" ++
        "2f0102" ++
        "30180100000fac020200000fac04000fac020100000fac020000" ++
        "32040c121860" ++
        "dd06001018020004" ++
        "dd1c0050f20101000050f20202000050f2040050f20201000050f2020000" ++
        "9f61c95c");

/// 各帧文件里记录的 FCS（末 4 字节，线上顺序）。
pub const cap_auth_1_fcs: [4]u8 = hex("0df2fd2d");
pub const cap_auth_2_fcs: [4]u8 = hex("65f43096");
pub const cap_assoc_req_fcs: [4]u8 = hex("21192eed");
pub const cap_assoc_resp_fcs: [4]u8 = hex("4ea3d60e");
pub const cap_disassoc_fcs: [4]u8 = hex("feaa65ac");
pub const cap_probe_req_fcs: [4]u8 = hex("f789666d");
pub const cap_probe_resp_fcs: [4]u8 = hex("0bbc2c14");
pub const cap_beacon_fcs: [4]u8 = hex("9f61c95c");

/// 第 82 帧 Association Request 的帧体（51 字节，元素顺序见上）。
pub const cap_assoc_req_body: [51]u8 = cap_assoc_req[24..75].*;
/// 第 84 帧 Association Response 的帧体（30 字节）。
pub const cap_assoc_resp_body: [30]u8 = cap_assoc_resp[24..54].*;

// ---------------------------------------------------------------------------
// Wireshark wiki SampleCaptures：mesh.pcap（不含 FCS），只取 Country / TIM 元素
// ---------------------------------------------------------------------------

/// `mesh.pcap` 第 1 帧 Beacon 里的 Country 元素（Element ID 7，Length 42）：
/// Country String "US "，13 个 Subband Triplet（首信道 36 起每 4 兆一个、1 个信道、
/// 17/23/30 dBm），无 Padding。
pub const mesh_country_element: [44]u8 =
    hex("072a" ++ "555320" ++
        "240111" ++ "280111" ++ "2c0111" ++ "300111" ++
        "340117" ++ "380117" ++ "3c0117" ++ "400117" ++
        "95011e" ++ "99011e" ++ "9d011e" ++ "a1011e" ++ "a5011e");

/// `mesh.pcap` 第 1 帧 Beacon 里的 TIM 元素：DTIM Count 0，DTIM Period 1，
/// Bitmap Control 0，Partial Virtual Bitmap 单字节 0。
pub const mesh_tim_element: [6]u8 = hex("050400010000");

// ---------------------------------------------------------------------------
// 本工程手工构造的向量（按所引条款的字段布局）
// ---------------------------------------------------------------------------

/// TIM（9.4.2.6，p.793）：DTIM Count 3，DTIM Period 4，Bitmap Control 0x0a
/// （组播位 0，Bitmap Offset 5 → 虚拟位图从第 10 字节起），Partial Virtual
/// Bitmap = `20 04`：第 10 字节 bit 5 → AID 85，第 11 字节 bit 2 → AID 90。
pub const tim_aid85_90: [7]u8 = hex("050603" ++ "04" ++ "0a" ++ "2004");
/// TIM：DTIM（Count 0），Period 1，组播位 1，Partial Virtual Bitmap 单字节 0。
pub const tim_multicast: [6]u8 = hex("050400010100");

/// Extended Capabilities（9.4.2.27，Table 9-135，p.891–895），10 字节位图：
///   B0   20/40 BSS Coexistence Management Support = 1   （第 0 字节 bit 0）
///   B22  Multiple BSSID = 1                            （第 2 字节 bit 6）
///   B31  Interworking = 1                              （第 3 字节 bit 7）
///   B48  UTF-8 SSID = 1                                （第 6 字节 bit 0）
///   B62  Operating Mode Notification = 1               （第 7 字节 bit 6）
///   B70  Fine Timing Measurement Responder = 1         （第 8 字节 bit 6）
///   B73  Extended Spectrum Management Capable = 1      （第 9 字节 bit 1）
pub const ext_cap_octets: [10]u8 = hex("0100" ++ "4880" ++ "0000" ++ "0140" ++ "4002");
pub const ext_cap_element: [12]u8 = hex("7f0a") ++ ext_cap_octets;

/// Country 元素体（9.4.2.9，p.795–797）：Country String "US "，一个 Subband
/// Triplet（首信道 36、4 个信道、最大 30 dBm = 0x1e），一个 Operating Triplet
/// （首字节 0xc9 ≥ 201：Operating Extension Identifier 201、Operating Class 81、
/// Coverage Class 0），以及 1 字节 Padding（0）——因为 3+3+3 = 9 是奇数。
pub const country_us_operating: [10]u8 = hex("555320" ++ "24041e" ++ "c95100" ++ "00");
/// Country 元素体：两个 Subband Triplet（6 字节，偶数，无 Padding），
/// 最大发送功率取负值 −23 dBm（0xe9）。
pub const country_fi_negative: [9]u8 = hex("464920" ++ "010d14" ++ "2404e9");

/// 四地址 Data 帧（To DS=1、From DS=1，Table 9-3，p.641），不带 FCS：
/// FC=08 0b（Data，To DS、From DS、More Fragments），Duration=0x002c，四个地址，
/// SC=0x0334（序号 0x33、分片 4），帧体 3 字节。
pub const data_4addr: [34]u8 =
    hex("0807" ++ "2c00" ++
        "020000000001" ++ "020000000002" ++ "020000000003" ++
        "3403" ++ "020000000004" ++ "06050403");

/// QoS Control = 0x07a2（Table 9-6 非 AP STA 行）：TID 2，B4=0，Ack Policy=01
/// （No Ack），A-MSDU Present=1，高字节 0x07（TXOP Duration Requested）。
pub const qos_ctrl_word: u16 = 0x07a2;
pub const qos_data_header: [26]u8 =
    hex("8841" ++ "2c00" ++
        "020000000100" ++ "020000000200" ++ "020000000300" ++ "3403" ++ "a207");

/// 控制帧帧头（9.3.1，p.670–672）：RTS（两个地址，16 字节）。
pub const rts_header: [16]u8 =
    hex("b400" ++ "943a" ++ "020000000001" ++ "020000000002");

pub const sta_mac: [6]u8 = hex("021122334455");
pub const peer_mac: [6]u8 = hex("02aabbccddee");

// ---------------------------------------------------------------------------
// 跨实现值：CPython `zlib.crc32`（与 `frame.zig` 无关的另一份 CRC-32 实现）
// ---------------------------------------------------------------------------

/// Annex J.9.1 明文帧补上 FCS 后的 4 个字节（线上顺序）。
pub const j91_deauth_plain_fcs: [4]u8 = hex("b067882b");
/// Annex J.9.2 明文帧补上 FCS 后的 4 个字节。
pub const j92_deauth_plain_fcs: [4]u8 = hex("a80eb472");

/// STA 发出的 Association Request 整帧（79 字节）：帧头取自 `wpa-Induction.pcap`
/// 第 82 帧，帧体按 Table 9-29 的元素顺序重排（Supported Rates、Extended Supported
/// Rates、RSN），FCS 由 `zlib.crc32` 算出。
pub const assoc_req_table_9_29: [79]u8 =
    hex("00003a01000c4182b255000d9382363a000c4182b2558001" ++
        "3104" ++ "0a00" ++
        "0007436f6865726572" ++
        "010882848b962430486c" ++
        "32040c121860" ++
        "30140100000fac020100000fac040100000fac020000" ++
        "aa0944bf");

/// STA 发给新 AP 的 Reassociation Request 整帧（63 字节）：同一组参数，
/// Current AP Address = 02:00:00:00:00:99，不带 RSNE，SC=0x0118。
pub const reassoc_req_expected: [63]u8 =
    hex("20003a01000c4182b255000d9382363a000c4182b2558001" ++
        "3104" ++ "0a00" ++ "020000000099" ++
        "0007436f6865726572" ++
        "010882848b962430486c" ++
        "32040c121860" ++
        "156680c3");

/// STA 发出的 Deauthentication（Reason Code 3），30 字节，SC=0x0118。
pub const deauth_sta_expected: [30]u8 =
    hex("c0003a01000c4182b255000d9382363a000c4182b2558001" ++
        "0300" ++ "e8985d2f");

/// STA 发出的 Disassociation（Reason Code 8），30 字节，SC=0x0118。
pub const disassoc_sta_expected: [30]u8 =
    hex("a0003a01000c4182b255000d9382363a000c4182b2558001" ++
        "0800" ++ "b196a687");
