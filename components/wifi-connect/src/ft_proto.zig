//! wifi-connect：FT 协议的消息交换（IEEE Std 802.11-2016 13.5、13.7、13.8；元素格式
//! 9.4.2.47、9.4.2.48；FT Action 帧 9.6.9）。
//!
//! `ft.zig` 只管派生。这里管的是线上那几个帧：
//!
//!   消息 1（13.8.2）  Authentication-Request（FTAA、事务序号 1）或 FT Request
//!                    RSNE[PMKR0Name] ‖ MDE ‖ FTE[SNonce, R0KH-ID]
//!   消息 2（13.8.3）  Authentication-Response（事务序号 2、Status）或 FT Response
//!                    RSNE[PMKR0Name] ‖ MDE ‖ FTE[ANonce, SNonce, R1KH-ID, R0KH-ID]
//!   消息 3（13.8.4）  Reassociation Request
//!                    RSNE[PMKR1Name] ‖ MDE ‖ FTE[MIC, ANonce, SNonce, R1KH-ID, R0KH-ID] ‖ RIC
//!   消息 4（13.8.5）  Reassociation Response
//!                    RSNE[PMKR1Name] ‖ MDE ‖ FTE[MIC, ANonce, SNonce, R1KH-ID, R0KH-ID, GTK, IGTK] ‖ RIC
//!
//! 前两个消息有两条路（13.8.1）：over-the-air 装在 Authentication 帧里（算法号 2，9.4.1.1），
//! over-the-DS 装在 FT Action 帧里经当前 AP 转给目标 AP（图 9-688、图 9-689）；后两个消息
//! 两种走法都装在重关联帧里（表 9-31、表 9-32）。所以 FT 协议下的「T1–T4」就是这四个消息；
//! 事务序号 3、4 的 Authentication-Confirm / Ack 帧属于资源请求协议（13.6），不在本文件。
//!
//! MIC（13.8.4、13.8.5）：AES-128-CMAC over KCK，输入依次是
//!   FTO 的 MAC(6) ‖ 目标 AP 的 MAC(6) ‖ 事务序号(1：Reassociation Request 为 5、Response 为 6)
//!   ‖ RSNE ‖ MDE ‖ MIC 字段清零的 FTE ‖ RIC 的内容。
//! MIC Control 的 Element Count 是这一帧里受 MIC 保护的元素数：RSNE、MDE、FTE，加上 RIC 里的每一个。
//!
//! 三个角色在一个进程里对打：`Sta`（FTO，S0KH + S1KH）、`Ap`（目标 AP，R1KH）、`R0kh`。
//! `R0kh.pull` 是「R0KH 经安全信道把 PMK-R1 SA 送给 R1KH」（13.2.2）的进程内替身；R0KH 与 R1KH
//! 之间的协议（13.10）不在本文件。`Lab` 把同一份配置分给三者。
//!
//! 校验与拒绝的理由一一对应：
//!   目标 AP，消息 1（13.5.2 的顺序）：MDE 不符 → STATUS_INVALID_MDE；RSNE 协商不到 FT AKM →
//!     STATUS_INVALID_AKMP；FTE 没有合法的 R0KH-ID → STATUS_INVALID_FTE；R0KH-ID 不是本 AP 的
//!     R0KH → R0KH_UNREACHABLE；R0KH 里没有这个 PMKR0Name → STATUS_INVALID_PMKID；成对密码套件
//!     与初始关联的不同 → STATUS_INVALID_PAIRWISE_CIPHER。帧体本身不是这一过程的帧 → 丢弃。
//!   目标 AP，消息 3（13.7.1 的顺序）：先验 MIC，不对就丢弃；然后 MDE → STATUS_INVALID_MDE，
//!     FTE 的 ANonce / SNonce / R0KH-ID / R1KH-ID 与消息 2 不同 → STATUS_INVALID_FTE，
//!     RSNE 的 PMKR1Name 不对 → STATUS_INVALID_PMKID。截止时间已过 → 丢弃并删掉 PTKSA。
//!   FTO，消息 2（13.8.3）：MDID、SNonce、R0KH-ID、PMKR0Name 必须与自己的对上。
//!   FTO，消息 4（13.7.1：S1KH 验 MIC，不对就丢弃）：先 MIC，再 MDE、两个 nonce、两个 key
//!     holder 标识、PMKR1Name，最后解开 GTK / IGTK。
//!
//! 与原文不一致、或原文没写而这里做了选择的地方：
//!   — 13.8.4 / 13.8.5 只为 AKM 00-0F-AC:3、:4、:9 规定了 FTE 的 MIC（AES-128-CMAC）。AKM
//!     00-0F-AC:13 的 KCK 是 192 位（表 12-8），2016 版原文没有给它的 FTE MIC 算法，所以
//!     `Sta` / `Ap` 在编译期拒绝 AKM 13。
//!   — 13.5.2 的 over-the-air 段把 FT AKM 只列成 :3、:4；13.5.3、表 9-31 注 13、13.8.4、13.8.5
//!     都列成 :3、:4、:9。这里两条路都接受 :9。
//!   — 原文没给 FTE 子元素的顺序；按 13.5 / 13.7 各图里出现的先后：R1KH-ID、R0KH-ID、GTK、IGTK。
//!   — 同一种元素或同类子元素在一帧里出现两次是歧义，按解析错误处理。
//!   — 第一个消息里缺了哪个元素，就按那个元素的状态码拒绝（MDE → 54、RSNE → 43、FTE → 55）；
//!     元素区本身走不通（截断）→ STATUS_INVALID_ELEMENT（表 9-46 的 40）。
//!   — RIC 的 QoS / Vendor Specific 描述符（表 13-3 的另外两行）本文件不解析：它们是一串
//!     不透明的元素，FT 只需要它的字节和元素个数；RDE 与 Block Ack 的 RIC Descriptor 在
//!     第 5b 节解析。
//!
//!   — RIC 的元素格式（RDE 9.4.2.50、RIC Descriptor 9.4.2.51）与 RIC 的结构规则（13.11.2、
//!     13.11.3.1、13.11.3.2）在第 5b 节；Block Ack 一种描述符（表 13-3），QoS / Vendor Specific
//!     的描述符仍是不透明字节透传。
//!
//! 不在这里：资源请求协议（13.6）、非 RSN 的变体（13.5.4、13.5.5、13.7.2）、FT 4 次握手的
//! EAPOL-Key 帧（13.4.2、12.7.6）、TIE 帧的编解码（截止时间作为配置给出）、MAC 帧头与 FCS。
//!
//! 帧体写进调用方给的缓冲，返回的切片指向它；不用分配器，不 import hw/log。主机测试
//! （`ft_proto_tests.zig`）与板侧自检（`ft_proto_selftest.zig`）共用这一份代码。

const std = @import("std");

const ft = @import("ft.zig");
const rsne = @import("rsne.zig");
const keywrap = @import("keywrap.zig");

const CmacAes128 = std.crypto.auth.cmac.CmacAes128;
const timing = std.crypto.timing_safe;

// ---------------------------------------------------------------------------
// 1) 常量
// ---------------------------------------------------------------------------

/// 表 9-77（印刷页 786–788）里本文件用到的 Element ID。
pub const Eid = struct {
    pub const ssid: u8 = 0;
    pub const rsne: u8 = 48;
    pub const mde: u8 = 54;
    pub const fte: u8 = 55;
    /// RIC Data element：一个 RIC 从它开始（9.4.2.50）。
    pub const rde: u8 = 57;
    /// RIC Descriptor element（9.4.2.51）：Table 9-77 印刷页 786（原文行 43767）。
    pub const ric_descriptor: u8 = 75;
};

/// 9.4.1.1（印刷页 739）：认证算法号 2 是 Fast BSS Transition。
pub const auth_alg_ft: u16 = 2;
/// 13.5.2：FT 认证只用事务序号 1（Request）与 2（Response）。
pub const auth_seq_request: u16 = 1;
pub const auth_seq_response: u16 = 2;
/// 表 9-47（印刷页 737）：Category 6 是 Fast BSS Transition。
pub const category_ft: u8 = 6;
/// 表 9-326（印刷页 1207）的 FT Action 字段值。
pub const ft_action_request: u8 = 1;
pub const ft_action_response: u8 = 2;

/// 13.8.4 / 13.8.5：MIC 输入里的事务序号。资源请求协议用的 3、4 不在本文件范围。
pub const MicSeq = enum(u8) {
    /// 这一条在 Reassociation Request 帧里。
    reassoc_request = 5,
    /// 这一条在 Reassociation Response 帧里。
    reassoc_response = 6,
};

/// 表 9-46（印刷页 733–735）里 FT 协议会用到的状态码。
pub const Status = struct {
    pub const success: u16 = 0;
    pub const refused_reason_unspecified: u16 = 1;
    pub const transaction_sequence_error: u16 = 14;
    pub const rejected_sequence_timeout: u16 = 16;
    pub const r0kh_unreachable: u16 = 28;
    pub const status_invalid_element: u16 = 40;
    pub const status_invalid_pairwise_cipher: u16 = 42;
    pub const status_invalid_akmp: u16 = 43;
    pub const status_invalid_pmkid: u16 = 53;
    pub const status_invalid_mde: u16 = 54;
    pub const status_invalid_fte: u16 = 55;
    /// 表 9-46（印刷页 733）的 33：13.7.1 允许目标 AP 在「13.6 已接受的资源兑现不了」时用它拒
    /// 绝 Reassociation Request（原文行 109102–109105）。
    pub const denied_insufficient_bandwidth: u16 = 33;
};

/// 13.7.1：目标 AP 回这三个状态码之一时，FTO 应放弃这次转换。
pub fn mustAbandon(status: u16) bool {
    return status == Status.refused_reason_unspecified or
        status == Status.transaction_sequence_error or
        status == Status.rejected_sequence_timeout;
}

/// 13.8.4 / 13.8.5 为它规定了 FTE MIC 的 AKM。
pub fn micAkmSupported(suite_type: u8) bool {
    return suite_type == @backingInt(ft.Akm.ft_8021x) or
        suite_type == @backingInt(ft.Akm.ft_psk) or
        suite_type == @backingInt(ft.Akm.ft_sae);
}

fn supportedAkm(comptime akm: ft.Akm) void {
    switch (akm) {
        .ft_8021x, .ft_psk, .ft_sae => {},
        .ft_8021x_sha384 => @compileError("ft_proto: 13.8.4 / 13.8.5 define the FTE MIC only for AKM 00-0F-AC:3, :4 and :9"),
    }
}

/// 成对密码套件（表 9-131 的 suite type）的 TK 长度（表 12-4，印刷页 2022）。FT 用的是 CCMP、GCMP 的四个。
pub fn tkLen(comptime pairwise: u8) usize {
    return switch (pairwise) {
        rsne.Cipher.ccmp128, rsne.Cipher.gcmp128 => 16,
        rsne.Cipher.ccmp256, rsne.Cipher.gcmp256 => 32,
        else => @compileError("ft_proto: the pairwise cipher must be CCMP-128, GCMP-128, CCMP-256 or GCMP-256"),
    };
}

/// 组密码套件（GTK）或 Group Management Cipher Suite（IGTK）的密钥长度（表 12-4）；不是这八个套件时为 null。
pub fn groupKeyLen(suite_type: u8) ?usize {
    return switch (suite_type) {
        rsne.Cipher.ccmp128, rsne.Cipher.gcmp128, rsne.Cipher.bip_cmac128, rsne.Cipher.bip_gmac128 => 16,
        rsne.Cipher.ccmp256, rsne.Cipher.gcmp256, rsne.Cipher.bip_cmac256, rsne.Cipher.bip_gmac256 => 32,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// 2) MDE（9.4.2.47，图 9-313、图 9-314，印刷页 933）
// ---------------------------------------------------------------------------

/// MDID(2) + FT Capability and Policy(1)。
pub const mdie_body_len: u8 = ft.mdid_len + 1;
pub const mdie_len: usize = 2 + @as(usize, mdie_body_len);

pub const Mdie = struct {
    mdid: [ft.mdid_len]u8 = @splat(0),
    /// FT Capability and Policy（图 9-314）：B0 Fast BSS Transition over DS，B1 Resource Request
    /// Protocol Capability，B2–B7 保留。其余位照原样保留，不置零。
    ft_cap: u8 = 0,

    pub fn encode(self: Mdie, out: *[mdie_len]u8) void {
        out[0] = Eid.mde;
        out[1] = mdie_body_len;
        @memcpy(out[2 .. 2 + ft.mdid_len], &self.mdid);
        out[2 + ft.mdid_len] = self.ft_cap;
    }

    /// `ie` 是含 Element ID 与 Length 的整段元素，可以比元素长。表 9-77 把 MDE 标成不可扩展，
    /// 所以 Length 必须正好是 3。
    pub fn parse(ie: []const u8) Error!Mdie {
        if (ie.len < 2 or ie[0] != Eid.mde) return error.WrongElement;
        if (ie[1] != mdie_body_len) return error.BadMdie;
        if (ie.len < mdie_len) return error.Truncated;
        return .{ .mdid = ie[2 .. 2 + ft.mdid_len].*, .ft_cap = ie[2 + ft.mdid_len] };
    }

    /// B0：目标 AP 是否允许 over-the-DS。
    pub fn overDs(self: Mdie) bool {
        return capOverDs(self.ft_cap);
    }
};

/// 图 9-314 的两个位拼成一个八位组。
pub fn ftCapPolicy(over_ds: bool, resource_request_capable: bool) u8 {
    return @as(u8, @intFromBool(over_ds)) | (@as(u8, @intFromBool(resource_request_capable)) << 1);
}

pub fn capOverDs(cap: u8) bool {
    return cap & 0x01 != 0;
}

pub fn capResourceRequest(cap: u8) bool {
    return cap & 0x02 != 0;
}

// ---------------------------------------------------------------------------
// 3) FTE（9.4.2.48，图 9-315 … 图 9-320，表 9-159，印刷页 934–936）
// ---------------------------------------------------------------------------

pub const mic_len = 16;
/// 图 9-315 的固定部分：Element ID、Length、MIC Control(2)、MIC(16)、ANonce(32)、SNonce(32)。
pub const fte_fixed_len = 2 + 2 + mic_len + 2 * ft.nonce_len;
/// FTE 的 MIC 字段在整段元素里的偏移。
const fte_mic_off = 4;
/// MIC Control 的 Element Count 在 B8–B15（图 9-316）：按 9.2.2 的小端，它是第二个八位组。
const fte_count_off = 3;

/// 表 9-159 的 Subelement ID。
pub const Subelem = struct {
    pub const r1kh_id: u8 = 1;
    pub const gtk: u8 = 2;
    pub const r0kh_id: u8 = 3;
    pub const igtk: u8 = 4;
};

pub const rsc_len = 8;
pub const ipn_len = 6;
/// GTK、IGTK 最长 32 个八位组（256 位套件，表 12-4）。
pub const key_max = 32;
/// GTK 子元素里 Wrapped Key 之前的部分：Key Info(2) + Key Length(1) + RSC(8)（图 9-318）。
pub const gtk_subelem_fixed = 2 + 1 + rsc_len;
/// IGTK 子元素里 Wrapped Key 之前的部分：Key ID(2) + IPN(6) + Key Length(1)（图 9-320）。
pub const igtk_subelem_fixed = 2 + ipn_len + 1;

pub const Error = error{
    /// 帧体或元素比它的固定字段短，或元素的 Length 超出它所在的字节范围。
    Truncated,
    /// 元素 ID 不是该元素应有的那一个（RSNE 48、MDE 54、FTE 55）。
    WrongElement,
    /// MDE 的 Length 不是 3（表 9-77：不可扩展）。
    BadMdie,
    /// FTE 比固定部分短。
    BadFte,
    /// R1KH-ID 子元素的 Length 不是 6。
    BadR1khIdLength,
    /// R0KH-ID 子元素的 Length 是 0 或超过 48（13.2.2）。
    BadR0khIdLength,
    /// GTK 子元素比 Key Info、Key Length、RSC 还短。
    BadGtkSubelem,
    /// IGTK 子元素比 Key ID、IPN、Key Length 还短。
    BadIgtkSubelem,
    /// 同一种元素或同类子元素出现两次。
    DuplicateElement,
    DuplicateSubelement,
    /// 帧体固定部分不对：Authentication 的算法号 / 事务序号，或 FT Action 的 Category / FT Action。
    BadHeader,
    /// MIC Control 的 Element Count 与帧里受保护的元素数对不上。
    BadElementCount,
    /// 帧里缺了 RSNE、MDE 或 FTE。
    MissingElement,
    /// 输出的缓冲不够。
    BufferTooSmall,
    /// 元素的 Length 字段装不下（超过 255）。
    TooLong,
    /// RDE 的 Length 不是 4（9.4.2.50 的固定格式，图 9-322）。
    BadRde,
    /// RIC Descriptor 的 Length 与它的 Resource Type 对不上，或 Resource Type 保留（表 9-161）。
    BadRicDescriptor,
    /// 一段 RIC 里一个 RDE 都没有，或以非 RDE 元素开头（13.11.2：RIC 以 Resource Request / Response
    /// 序列组成，每条由一个 RDE 划界）。
    RicNoRde,
    /// 请求里的 RDE 把 Resource Descriptor Count 设成了 0（13.11.3.1：每个 RDE 后至少一个描述符）。
    RicBadDescriptorCount,
    /// 请求里的 RDE 把 Status Code 设成了非 0（13.11.3.1：请求里应为 SUCCESS）。
    RicBadStatus,
    /// 两个 RDE 用了同一个 RDE Identifier（13.11.3.1：RDE Identifier 在 RIC 里唯一）。
    RicDuplicateId,
    /// RIC 的 RDE 条数超过 `max_ric_entries`。
    RicTooManyEntries,
    /// Block Ack 描述符的个数与 RDE 的 Resource Descriptor Count 不符（表 13-3 Block Ack 行）。
    RicDescriptorCountMismatch,
    /// RIC-Response 的 RDE 与请求的不一一对应（13.11.3.2：同一条数、同序、同 RDE Identifier）。
    RicResponseMismatch,
};

/// 构造帧时的错误：只会是缓冲或长度问题。
pub const BuildError = error{ BufferTooSmall, TooLong };

/// 解析出来的 GTK 子元素（图 9-318）。`wrapped` 指向原帧里的 Wrapped Key。
pub const GtkSub = struct {
    /// Key Info 的 B0–B1（图 9-319）。
    key_id: u8,
    /// Key 字段的长度，不含填充（13.8.5）。
    key_len: u8,
    rsc: [rsc_len]u8,
    wrapped: []const u8,
};

/// 解析出来的 IGTK 子元素（图 9-320）。
pub const IgtkSub = struct {
    key_id: u16,
    ipn: [ipn_len]u8,
    key_len: u8,
    wrapped: []const u8,
};

pub const Fte = struct {
    /// MIC Control 的 Element Count（图 9-316）；0 表示没有 MIC。
    element_count: u8 = 0,
    mic: [mic_len]u8 = @splat(0),
    anonce: [ft.nonce_len]u8 = @splat(0),
    snonce: [ft.nonce_len]u8 = @splat(0),
    /// 消息 1 里 FTO 发的 FTE 不带 R1KH-ID（13.8.2）。
    r1kh_id: ?[ft.addr_len]u8 = null,
    /// 指向原帧里的 R0KH-ID；缺席为 null。
    r0kh_id: ?[]const u8 = null,
    gtk: ?GtkSub = null,
    igtk: ?IgtkSub = null,
};

/// `ies[pos..]` 处一个元素的整长（含 Element ID 与 Length）。调用方保证 `pos < ies.len`。
fn ieLen(ies: []const u8, pos: usize) Error!usize {
    if (ies.len - pos < 2) return error.Truncated;
    const len: usize = ies[pos + 1];
    if (ies.len - pos - 2 < len) return error.Truncated;
    return 2 + len;
}

/// 解析含 Element ID 与 Length 的整段 FTE；子元素的切片指向 `ie`。
pub fn parseFte(ie: []const u8) Error!Fte {
    if (ie.len < 2 or ie[0] != Eid.fte) return error.WrongElement;
    const len: usize = ie[1];
    if (len < fte_fixed_len - 2) return error.BadFte;
    if (ie.len < fte_fixed_len) return error.Truncated;
    const end = 2 + len;
    if (ie.len < end) return error.Truncated;

    var f = Fte{
        .element_count = ie[fte_count_off],
        .mic = ie[fte_mic_off .. fte_mic_off + mic_len].*,
        .anonce = ie[20 .. 20 + ft.nonce_len].*,
        .snonce = ie[52 .. 52 + ft.nonce_len].*,
    };
    var pos: usize = fte_fixed_len;
    while (pos < end) {
        const total = try ieLen(ie[0..end], pos);
        const id = ie[pos];
        const data = ie[pos + 2 .. pos + total];
        switch (id) {
            Subelem.r1kh_id => {
                if (data.len != ft.addr_len) return error.BadR1khIdLength;
                if (f.r1kh_id != null) return error.DuplicateSubelement;
                f.r1kh_id = data[0..ft.addr_len].*;
            },
            Subelem.r0kh_id => {
                if (data.len == 0 or data.len > ft.r0kh_id_max) return error.BadR0khIdLength;
                if (f.r0kh_id != null) return error.DuplicateSubelement;
                f.r0kh_id = data;
            },
            Subelem.gtk => {
                if (data.len < gtk_subelem_fixed) return error.BadGtkSubelem;
                if (f.gtk != null) return error.DuplicateSubelement;
                f.gtk = .{
                    .key_id = data[0] & 0x03,
                    .key_len = data[2],
                    .rsc = data[3 .. 3 + rsc_len].*,
                    .wrapped = data[gtk_subelem_fixed..],
                };
            },
            Subelem.igtk => {
                if (data.len < igtk_subelem_fixed) return error.BadIgtkSubelem;
                if (f.igtk != null) return error.DuplicateSubelement;
                f.igtk = .{
                    .key_id = std.mem.readInt(u16, data[0..2], .little),
                    .ipn = data[2 .. 2 + ipn_len].*,
                    .key_len = data[igtk_subelem_fixed - 1],
                    .wrapped = data[igtk_subelem_fixed..],
                };
            },
            // 表 9-159：0 与 5–255 是保留的子元素，跳过它的字节。
            else => {},
        }
        pos += total;
    }
    return f;
}

/// 13.8.5 的填充规则下，`key_len` 长的 Key 字段包裹前有多长：不足 16 个八位组或不是 8 的倍数时，
/// 追加一个 0xdd 再补 0x00 到 8 的倍数。
pub fn paddedKeyLen(key_len: usize) usize {
    if (key_len >= 16 and key_len % 8 == 0) return key_len;
    return @max(((key_len + 1 + 7) / 8) * 8, 16);
}

/// 把 `key` 按上面的规则填进 `out`，返回填好的那一段。`key.len ≤ key_max`。
pub fn padKey(key: []const u8, out: *[key_max + 8]u8) []const u8 {
    @memcpy(out[0..key.len], key);
    const n = paddedKeyLen(key.len);
    if (n > key.len) out[key.len] = 0xdd;
    if (n > key.len + 1) @memset(out[key.len + 1 .. n], 0);
    return out[0..n];
}

pub const UnwrapError = error{ BadKeyLength, BadWrappedLength, KeyIntegrity };

/// 解开 GTK / IGTK 子元素里的 Wrapped Key（13.8.5）：NIST AES key wrap，128 位 KEK（表 12-8，
/// AKM 3、4、9）。接收方取前 `key_len` 个八位组，忽略尾部填充；密文长度必须与 `key_len` 对得上。
pub fn unwrapKey(kek: [keywrap.kek_len]u8, key_len: usize, wrapped: []const u8, out: *[key_max]u8) UnwrapError!void {
    if (key_len == 0 or key_len > key_max) return error.BadKeyLength;
    const padded = paddedKeyLen(key_len);
    if (wrapped.len != padded + keywrap.wrap_overhead) return error.BadWrappedLength;
    var plain: [key_max + 8]u8 = undefined;
    const n = keywrap.unwrap(kek, wrapped, &plain) catch return error.KeyIntegrity;
    std.debug.assert(n == padded);
    @memcpy(out[0..key_len], plain[0..key_len]);
}

// ---------------------------------------------------------------------------
// 4) 帧体固定部分
// ---------------------------------------------------------------------------

/// 表 9-35：算法号(2) | 事务序号(2) | 状态码(2)。
pub const auth_fixed_len = 6;
/// 图 9-688：Category(1) | FT Action(1) | STA Address(6) | Target AP Address(6)。
pub const ft_request_fixed_len = 14;
/// 图 9-689：前四项再加 Status Code(2)。
pub const ft_response_fixed_len = 16;
/// 表 9-31：Capability Information(2) | Listen Interval(2) | Current AP address(6)。
pub const reassoc_request_fixed_len = 10;
/// 表 9-32：Capability Information(2) | Status code(2) | AID(2)。
pub const reassoc_response_fixed_len = 6;

pub const AuthHead = struct { algorithm: u16, seq: u16, status: u16 };
pub const AuthFrame = struct { head: AuthHead, ies: []const u8 };
pub const FtRequestFrame = struct { sta: [ft.addr_len]u8, target_ap: [ft.addr_len]u8, ies: []const u8 };
pub const FtResponseFrame = struct { sta: [ft.addr_len]u8, target_ap: [ft.addr_len]u8, status: u16, ies: []const u8 };
pub const ReassocRequestHead = struct { cap_info: u16, listen_interval: u16, current_ap: [ft.addr_len]u8 };
pub const ReassocRequestFrame = struct { head: ReassocRequestHead, ies: []const u8 };
pub const ReassocResponseHead = struct { cap_info: u16, status: u16, aid: u16 };
pub const ReassocResponseFrame = struct { head: ReassocResponseHead, ies: []const u8 };

fn split(body: []const u8, fixed: usize) Error![]const u8 {
    if (body.len < fixed) return error.Truncated;
    return body[fixed..];
}

/// 解析 Authentication 帧体；元素区从 6 个八位组之后开始。先查长度再读：帧体来自空口，
/// 不足 6 个八位组时不能去取。
pub fn parseAuth(body: []const u8) Error!AuthFrame {
    const ies = try split(body, auth_fixed_len);
    return .{ .head = .{
        .algorithm = std.mem.readInt(u16, body[0..2], .little),
        .seq = std.mem.readInt(u16, body[2..4], .little),
        .status = std.mem.readInt(u16, body[4..6], .little),
    }, .ies = ies };
}

/// 解析 FT Request 帧体（图 9-688）。Category 与 FT Action 由调用方核对（见 `checkFtRequest`）。
pub fn parseFtRequest(body: []const u8) Error!FtRequestFrame {
    if (body.len < ft_request_fixed_len) return error.Truncated;
    return .{ .sta = body[2..8].*, .target_ap = body[8..14].*, .ies = body[ft_request_fixed_len..] };
}

/// 解析 FT Response 帧体（图 9-689）。
pub fn parseFtResponse(body: []const u8) Error!FtResponseFrame {
    if (body.len < ft_response_fixed_len) return error.Truncated;
    return .{
        .sta = body[2..8].*,
        .target_ap = body[8..14].*,
        .status = std.mem.readInt(u16, body[14..16], .little),
        .ies = body[ft_response_fixed_len..],
    };
}

pub fn parseReassocRequest(body: []const u8) Error!ReassocRequestFrame {
    if (body.len < reassoc_request_fixed_len) return error.Truncated;
    return .{ .head = .{
        .cap_info = std.mem.readInt(u16, body[0..2], .little),
        .listen_interval = std.mem.readInt(u16, body[2..4], .little),
        .current_ap = body[4..10].*,
    }, .ies = body[reassoc_request_fixed_len..] };
}

pub fn parseReassocResponse(body: []const u8) Error!ReassocResponseFrame {
    if (body.len < reassoc_response_fixed_len) return error.Truncated;
    return .{ .head = .{
        .cap_info = std.mem.readInt(u16, body[0..2], .little),
        .status = std.mem.readInt(u16, body[2..4], .little),
        .aid = std.mem.readInt(u16, body[4..6], .little),
    }, .ies = body[reassoc_response_fixed_len..] };
}

/// 往缓冲里顺序追加字段的游标。
pub const Cursor = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn room(self: *Cursor, n: usize) BuildError!void {
        if (self.buf.len - self.pos < n) return error.BufferTooSmall;
    }

    pub fn putU8(self: *Cursor, v: u8) BuildError!void {
        try self.room(1);
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    /// 多八位组数值按 9.2.2 的小端。
    pub fn putU16(self: *Cursor, v: u16) BuildError!void {
        try self.room(2);
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }

    /// 追加一段字节（地址、nonce、密文、元素串）。
    pub fn put(self: *Cursor, v: []const u8) BuildError!void {
        try self.room(v.len);
        @memcpy(self.buf[self.pos..][0..v.len], v);
        self.pos += v.len;
    }

    /// 追加一个普通元素：Element ID(1) + Length(1) + body。
    pub fn element(self: *Cursor, id: u8, info: []const u8) BuildError!void {
        if (info.len > 255) return error.TooLong;
        try self.room(2 + info.len);
        try self.putU8(id);
        try self.putU8(@intCast(info.len));
        try self.put(info);
    }

    /// 追加一个子元素：Subelement ID(1) + Length(1) + Data（图 9-317）。
    pub fn subelement(self: *Cursor, id: u8, data: []const u8) BuildError!void {
        try self.element(id, data);
    }

    pub fn body(self: *const Cursor) []const u8 {
        return self.buf[0..self.pos];
    }
};

fn putRsne(c: *Cursor, r: rsne.Rsne) BuildError!void {
    // encode 只会报缓冲不够或太长；NotRsne / BadVersion / BadCount 只在解析时出现。
    c.pos += rsne.encode(r, c.buf[c.pos..]) catch |e| switch (e) {
        error.BufferTooSmall => return error.BufferTooSmall,
        error.TooLong => return error.TooLong,
        else => unreachable,
    };
}

fn putMdie(c: *Cursor, m: Mdie) BuildError!void {
    var buf: [mdie_len]u8 = undefined;
    m.encode(&buf);
    try c.put(&buf);
}

/// 写 FTE 的头与固定部分（图 9-315）：Length 先记成只有固定部分，MIC 为 0。返回 FTE 的起点，
/// 子元素写完后用 `endFte` 回填 Length。
fn putFteHead(c: *Cursor, element_count: u8, anonce: [ft.nonce_len]u8, snonce: [ft.nonce_len]u8) BuildError!usize {
    const at = c.pos;
    try c.putU8(Eid.fte);
    try c.putU8(fte_fixed_len - 2);
    try c.putU8(0); // MIC Control 的 B0–B7 保留
    try c.putU8(element_count);
    try c.put(&@as([mic_len]u8, @splat(0)));
    try c.put(&anonce);
    try c.put(&snonce);
    return at;
}

fn endFte(c: *Cursor, at: usize) BuildError!void {
    const len = c.pos - at - 2;
    if (len > 255) return error.TooLong;
    c.buf[at + 1] = @intCast(len);
}

/// 往 FTE 里追加 GTK 子元素（图 9-318、图 9-319）：Key 字段先按 13.8.5 填充，再用 KEK 做 NIST AES key wrap。
fn putGtkSubelem(c: *Cursor, kek: [keywrap.kek_len]u8, key_id: u8, key: []const u8, rsc: [rsc_len]u8) BuildError!void {
    var padded: [key_max + 8]u8 = undefined;
    const p = padKey(key, &padded);
    const wrapped_len = keywrap.wrappedLen(p.len) catch unreachable; // padKey 保证 ≥ 16 且是 8 的倍数
    try c.room(2 + gtk_subelem_fixed + wrapped_len);
    try c.putU8(Subelem.gtk);
    try c.putU8(@intCast(gtk_subelem_fixed + wrapped_len));
    try c.putU16(key_id & 0x03);
    try c.putU8(@intCast(key.len));
    try c.put(&rsc);
    try c.room(wrapped_len);
    c.pos += keywrap.wrap(kek, p, c.buf[c.pos..]) catch unreachable;
}

/// 往 FTE 里追加 IGTK 子元素（图 9-320）。
fn putIgtkSubelem(c: *Cursor, kek: [keywrap.kek_len]u8, key_id: u16, ipn: [ipn_len]u8, key: []const u8) BuildError!void {
    var padded: [key_max + 8]u8 = undefined;
    const p = padKey(key, &padded);
    const wrapped_len = keywrap.wrappedLen(p.len) catch unreachable;
    try c.room(2 + igtk_subelem_fixed + wrapped_len);
    try c.putU8(Subelem.igtk);
    try c.putU8(@intCast(igtk_subelem_fixed + wrapped_len));
    try c.putU16(key_id);
    try c.put(&ipn);
    try c.putU8(@intCast(key.len));
    try c.room(wrapped_len);
    c.pos += keywrap.wrap(kek, p, c.buf[c.pos..]) catch unreachable;
}

// ---------------------------------------------------------------------------
// 5) 元素扫描与 MIC（13.8.4、13.8.5）
// ---------------------------------------------------------------------------

/// 一帧里 FT 认证序列用到的元素（表 13-1）。`rsne`、`mde`、`fte` 是含 Element ID 与 Length 的
/// 整段元素：MIC 就算在这些字节上。
pub const Elements = struct {
    rsne: []const u8 = &.{},
    mde: []const u8 = &.{},
    fte: []const u8 = &.{},
    /// 从第一个 RDE 起到元素区末尾；没有 RDE 时为空。
    from_rde: []const u8 = &.{},

    pub fn hasRic(self: Elements) bool {
        return self.from_rde.len != 0;
    }
};

/// 在帧体的元素区里找出 RSNE、MDE、FTE 与第一个 RDE。其余元素（SSID、Supported Rates 等）跳过：
/// 它们不受 MIC 保护，也不计入 Element Count。
pub fn scan(ies: []const u8) Error!Elements {
    var els = Elements{};
    var pos: usize = 0;
    while (pos < ies.len) {
        const total = try ieLen(ies, pos);
        const ie = ies[pos .. pos + total];
        switch (ies[pos]) {
            Eid.rsne => {
                if (els.rsne.len != 0) return error.DuplicateElement;
                els.rsne = ie;
            },
            Eid.mde => {
                if (els.mde.len != 0) return error.DuplicateElement;
                els.mde = ie;
            },
            Eid.fte => {
                if (els.fte.len != 0) return error.DuplicateElement;
                els.fte = ie;
            },
            Eid.rde => {
                if (els.from_rde.len == 0) els.from_rde = ies[pos..];
            },
            else => {},
        }
        pos += total;
    }
    return els;
}

/// RSNE、MDE、FTE 三样一定受保护。
const protected_fixed: u8 = 3;

/// 发送端：RIC 里有几个元素，就往 Element Count 里加几。`ric` 是一段不透明的元素串。
pub fn protectedCount(ric: []const u8) Error!u8 {
    var n: usize = protected_fixed;
    var pos: usize = 0;
    while (pos < ric.len) {
        pos += try ieLen(ric, pos);
        n += 1;
        if (n > 255) return error.TooLong;
    }
    return @intCast(n);
}

/// 接收端：MIC 覆盖的 RIC 是从第一个 RDE 起、共 `count - 3` 个元素；`count` 是 FTE 的 Element Count。
/// RSNE、MDE、FTE 缺任何一样、RIC 里有 RDE 却没被计数、被计数的元素在帧里找不全，都对不上。
/// 数目比 RIC 的元素少时，多出来的元素不进 MIC，照 wpa_supplicant 的 `wpa_ft_parse_ies`
/// （src/common/wpa_common.c:236-243）只取被计数的那几个。
pub fn ricProtected(els: Elements, count: u8) Error![]const u8 {
    if (count < protected_fixed or els.rsne.len == 0 or els.mde.len == 0 or els.fte.len == 0) return error.BadElementCount;
    const n: usize = count - protected_fixed;
    if (els.from_rde.len == 0) {
        if (n != 0) return error.BadElementCount;
        return &.{};
    }
    if (n == 0) return error.BadElementCount;
    var pos: usize = 0;
    for (0..n) |_| {
        // 元素区走完了而计数还没完：帧里没有那么多受保护的元素。
        if (pos == els.from_rde.len) return error.BadElementCount;
        pos += try ieLen(els.from_rde, pos);
    }
    return els.from_rde[0..pos];
}

/// AKM 3、4、9 的 KCK 是 128 位（表 12-8，印刷页 2027）。
pub const kck_len = 16;
/// AKM 3、4、9 的 KEK 是 128 位（表 12-8）。
pub const kek_len = 16;

/// FTE 的 MIC（13.8.4、13.8.5）：AES-128-CMAC over KCK，输入是
/// FTO 的 MAC ‖ 目标 AP 的 MAC ‖ 事务序号 ‖ RSNE ‖ MDE ‖ MIC 字段清零的 FTE ‖ RIC。
/// `els` 来自 `scan`，`ric` 来自 `ricProtected`；FTE 至少有固定部分，所以清零 MIC 字段不用拷贝。
pub fn mic(kck: [kck_len]u8, fto: [ft.addr_len]u8, target_ap: [ft.addr_len]u8, seq: MicSeq, els: Elements, ric: []const u8) [mic_len]u8 {
    var ctx = CmacAes128.init(&kck);
    ctx.update(&fto);
    ctx.update(&target_ap);
    ctx.update(&.{@backingInt(seq)});
    ctx.update(els.rsne);
    ctx.update(els.mde);
    ctx.update(els.fte[0..fte_mic_off]);
    ctx.update(&@as([mic_len]u8, @splat(0)));
    ctx.update(els.fte[fte_mic_off + mic_len ..]);
    ctx.update(ric);
    return ctx.finalResult();
}

/// 常量时间的 MIC 比较。
pub fn micEqual(a: [mic_len]u8, b: [mic_len]u8) bool {
    return timing.eql([mic_len]u8, a, b);
}

// ---------------------------------------------------------------------------
// 5b) RIC 的内容：RDE（9.4.2.50，图 9-322）与 RIC Descriptor（9.4.2.51，图 9-323、表 9-161）
// ---------------------------------------------------------------------------
//
// 第 5 节已经管了「RIC 作为一串元素进 MIC」（`protectedCount`、`ricProtected`）；这一节管
// RIC 里那些元素本身长什么样、一条 RIC 的结构规则是什么：
//
//   一条 Resource Request（图 13-21，印刷页 2127）：一个 RDE 后跟一个或多个 Resource
//   Descriptor；RIC-Request（图 13-20）是一条或多条 Resource Request，RIC-Response（图 13-27）
//   是一条或多条 Resource Response，每条与请求里的 RDE 对应（13.11.2）。
//
// 本文件只定义 Block Ack 这一种描述符（表 13-3 的 Block Ack Parameters 行）；QoS 那一路
// （TSPEC / TCLAS，表 13-3 的 802.11 QoS 行）与 Vendor Specific 不建模——它们的描述符由多个
// 元素组成，本模块把它们当不透明字节透传。

/// 图 9-322：Element ID(1) + Length(1) + RDE Identifier(1) + Resource Descriptor Count(1) +
/// Status Code(2)。表 9-77（印刷页 786）没有把 RDE 标成可扩展，长度是定死的。
pub const rde_body_len: u8 = 4;
pub const rde_len: usize = 2 + @as(usize, rde_body_len);

/// 表 9-161（印刷页 937，原文行 51236）：Resource Type 1 是 Block Ack；0 与 2–255 保留。
pub const resource_type_block_ack: u8 = 1;
/// 图 9-323：Block Ack 描述符的 Variable parameters（表 9-161）：Block Ack Parameter Set
/// (2, 9.4.1.14) + Block Ack Timeout(2, 9.4.1.15) + Block Ack Starting Sequence Control
/// (2, 9.3.1.8)，三个都按 9.2.2 的小端。
pub const block_ack_params_len: u8 = 6;
/// Block Ack RIC Descriptor 的整段长度。
pub const ric_descriptor_block_ack_len: usize = 2 + 1 + @as(usize, block_ack_params_len);

/// 一条 RIC 里最多认这么多个 RDE。RIC 走的是重关联帧，一个 FTO 同时要的 TS 不会多。
pub const max_ric_entries = 16;

/// RIC Data element（图 9-322）。
pub const Rde = struct {
    /// 请求方任选、在整条 RIC 里唯一（9.4.2.50、13.11.3.1）。
    rde_id: u8,
    /// 这个 RDE 后面跟着几个备选 Resource Descriptor（9.4.2.50）。
    descriptor_count: u8,
    /// 只在 Resource Response 里有意义（9.4.2.50）；请求里按 13.11.3.1 设为 SUCCESS。
    status: u16,

    pub fn encode(self: Rde, out: *[rde_len]u8) void {
        out[0] = Eid.rde;
        out[1] = rde_body_len;
        out[2] = self.rde_id;
        out[3] = self.descriptor_count;
        std.mem.writeInt(u16, out[4..6], self.status, .little);
    }

    /// `ie` 是含 Element ID 与 Length 的整段元素，可以比元素长。
    pub fn parse(ie: []const u8) Error!Rde {
        if (ie.len < 2 or ie[0] != Eid.rde) return error.WrongElement;
        if (ie[1] != rde_body_len) return error.BadRde;
        if (ie.len < rde_len) return error.Truncated;
        return .{
            .rde_id = ie[2],
            .descriptor_count = ie[3],
            .status = std.mem.readInt(u16, ie[4..6], .little),
        };
    }

    /// 13.11.3.1：「A resource request is considered successful if the status code SUCCESS is
    /// returned in each RDE。」
    pub fn accepted(self: Rde) bool {
        return self.status == Status.success;
    }
};

/// 13.11.3.1：FTO 构造请求里的 RDE：Status Code 设为 SUCCESS（9.4.2.50 说请求里这一栏保留，
/// 13.11.3.1 把它钉在 SUCCESS 上）。
pub fn requestRde(rde_id: u8, descriptor_count: u8) Rde {
    return .{ .rde_id = rde_id, .descriptor_count = descriptor_count, .status = Status.success };
}

/// RIC Descriptor element（图 9-323）：Element ID(1) + Length(1) + Resource Type(1) + 变长参数。
pub const RicDescriptor = struct {
    resource_type: u8,
    /// 指向原元素里 Resource Type 之后的那一段。
    params: []const u8,
};

/// Block Ack 描述符的三个参数（表 9-161 的 Variable parameters 一栏）。
pub const BlockAck = struct {
    /// Block Ack Parameter Set（9.4.1.14，图 9-268）。
    parameter_set: u16,
    /// Block Ack Timeout（9.4.1.15），单位 TU。
    timeout_tu: u16,
    /// Block Ack Starting Sequence Control（9.3.1.8，图 9-31）。
    ssc: u16,
};

/// Block Ack 描述符按图 9-323 写进 `out`，返回写好的整段元素。
pub fn encodeBlockAckDescriptor(ba: BlockAck, out: *[ric_descriptor_block_ack_len]u8) []const u8 {
    out[0] = Eid.ric_descriptor;
    out[1] = 1 + block_ack_params_len;
    out[2] = resource_type_block_ack;
    std.mem.writeInt(u16, out[3..5], ba.parameter_set, .little);
    std.mem.writeInt(u16, out[5..7], ba.timeout_tu, .little);
    std.mem.writeInt(u16, out[7..9], ba.ssc, .little);
    return out[0..];
}

/// 把任意的 Resource Type 与参数写成一个 RIC Descriptor；参数太长装不下时是 `TooLong`。
/// 保留的 Resource Type（表 9-161：0、2–255）在这里放行：发送端不编保留值是 13.11.3.1 的
/// 程序性要求，`parseRicDescriptor` 在接收端拦。
pub fn encodeRicDescriptor(resource_type: u8, params: []const u8, out: []u8) BuildError![]const u8 {
    if (1 + params.len > 255) return error.TooLong;
    if (out.len < 2 + 1 + params.len) return error.BufferTooSmall;
    out[0] = Eid.ric_descriptor;
    out[1] = @intCast(1 + params.len);
    out[2] = resource_type;
    @memcpy(out[3 .. 3 + params.len], params);
    return out[0 .. 2 + 1 + params.len];
}

/// 解析一个 RIC Descriptor；保留的 Resource Type 拒掉（表 9-161：0 与 2–255 保留）。
pub fn parseRicDescriptor(ie: []const u8) Error!RicDescriptor {
    if (ie.len < 2 or ie[0] != Eid.ric_descriptor) return error.WrongElement;
    const len: usize = ie[1];
    if (len < 1) return error.BadRicDescriptor;
    if (ie.len < 2 + len) return error.Truncated;
    if (ie[2] == 0 or ie[2] > resource_type_block_ack) return error.BadRicDescriptor;
    return .{ .resource_type = ie[2], .params = ie[3 .. 2 + len] };
}

/// 把一个 RIC Descriptor 当 Block Ack 描述符解析（表 13-3 Block Ack Parameters 行：请求与
/// 响应都是「RIC Descriptor，Resource Type = Block Ack」一个元素）。
pub fn parseBlockAckDescriptor(ie: []const u8) Error!BlockAck {
    const d = try parseRicDescriptor(ie);
    if (d.resource_type != resource_type_block_ack) return error.BadRicDescriptor;
    if (d.params.len != block_ack_params_len) return error.BadRicDescriptor;
    return .{
        .parameter_set = std.mem.readInt(u16, d.params[0..2], .little),
        .timeout_tu = std.mem.readInt(u16, d.params[2..4], .little),
        .ssc = std.mem.readInt(u16, d.params[4..6], .little),
    };
}

/// 一条 Resource Request / Response：RDE 加上它后面的那一段元素（到下一个 RDE 或 RIC 结束）。
pub const RicEntry = struct {
    rde: Rde,
    /// RDE 之后、下一个 RDE 之前的整段元素。响应里描述符至多一个（13.11.2），
    /// 请求里的备选描述符个数在 RDE 的 `descriptor_count` 里。
    rest: []const u8,
};

/// `parseRic` 的结果：固定容量的条目数组。
pub const Ric = struct {
    entries: [max_ric_entries]RicEntry = undefined,
    len: usize = 0,

    pub fn slice(self: *const Ric) []const RicEntry {
        return self.entries[0..self.len];
    }
};

/// 把一段 RIC 按 RDE 划界拆开（13.11.2：每条 Resource Request / Response 由一个 RDE 开头）。
/// 结构不对就拒：空 RIC、以非 RDE 开头、RDE 长度不对、截断、条目太多。
pub fn parseRic(ric: []const u8) Error!Ric {
    var out = Ric{};
    var starts: [max_ric_entries]usize = undefined;
    var pos: usize = 0;
    var n: usize = 0; // 到目前为止见到的 RDE 条数
    var seen_any = false;
    while (pos < ric.len) {
        const total = try ieLen(ric, pos);
        if (ric[pos] == Eid.rde) {
            const r = try Rde.parse(ric[pos .. pos + total]);
            if (n == max_ric_entries) return error.RicTooManyEntries;
            starts[n] = pos;
            out.entries[n] = .{ .rde = r, .rest = &.{} };
            n += 1;
        } else if (n == 0) {
            // 第一个元素就不是 RDE：RIC 以 Resource Request / Response 序列组成（13.11.2）。
            return error.RicNoRde;
        }
        seen_any = true;
        pos += total;
    }
    if (!seen_any or n == 0) return error.RicNoRde;
    // 每个条目的 rest 是它自己的 RDE 之后到下一个 RDE（或 RIC 结束）的那一段。
    for (0..n) |i| {
        const start = starts[i] + rde_len;
        const end = if (i + 1 < n) starts[i + 1] else ric.len;
        out.entries[i].rest = ric[start..end];
    }
    out.len = n;
    return out;
}

/// 13.11.3.1（FTO 侧的程序性规则）：至少一条 Resource Request；每个 RDE 的 Status Code 是
/// SUCCESS、Resource Descriptor Count 至少 1、RDE Identifier 在整条 RIC 里唯一。
pub fn checkRicRequest(ric: []const u8) Error!void {
    const r = try parseRic(ric);
    for (r.slice()) |e| {
        if (!e.rde.accepted()) return error.RicBadStatus;
        if (e.rde.descriptor_count == 0) return error.RicBadDescriptorCount;
    }
    for (r.slice(), 0..) |a, i| {
        for (r.slice()[i + 1 ..]) |b| {
            if (a.rde.rde_id == b.rde.rde_id) return error.RicDuplicateId;
        }
    }
}

/// 表 13-3 的 Block Ack Parameters 行（请求）：每个 RDE 后跟恰好 `descriptor_count` 个元素，
/// 每个都是 Resource Type = Block Ack 的 RIC Descriptor，没有尾随的其它元素。
pub fn checkRicRequestBlockAck(ric: []const u8) Error!void {
    try checkRicRequest(ric);
    const r = try parseRic(ric);
    for (r.slice()) |e| {
        var pos: usize = 0;
        var n: usize = 0;
        while (pos < e.rest.len) {
            const total = try ieLen(e.rest, pos);
            _ = try parseBlockAckDescriptor(e.rest[pos .. pos + total]);
            n += 1;
            pos += total;
        }
        if (n != e.rde.descriptor_count) return error.RicDescriptorCountMismatch;
    }
}

/// 13.11.3.2：RIC-Response 里每个请求 RDE 对应一条，条数相同、顺序相同、RDE Identifier 相同。
/// 响应里 RDE 之间的描述符元素（零或一个，13.11.2）跳过。
pub fn checkRicResponse(request: []const u8, response: []const u8) Error!void {
    const req = try parseRic(request);
    const rsp = try parseRic(response);
    if (req.len != rsp.len) return error.RicResponseMismatch;
    for (req.slice(), rsp.slice()) |a, b| {
        if (a.rde.rde_id != b.rde.rde_id) return error.RicResponseMismatch;
    }
}

/// 表 9-30 注 14（印刷页 703，原文行 39414–39427）：RIC-Request 出现在 Reassociation Request
/// 里的条件是——目标 AP 通告了 FT capability（Beacon / Probe Response 的 MDE）、且这次转换
/// 不用 13.6 的 FT 资源请求协议。本模块只做 RSN 的 FT（AKM 3/4/9 或非 RSN 里的条件之一已由
/// 类型保证），这两个前提不进参数。
/// 9.4.2.47（图 9-314，原文行 51077）：MDE 的 B1 只通告「STA 可以跑 13.6 的资源请求协议」，
/// 与 RIC 能不能进重关联帧无关——两个说法是并列的，不是一个的门控。
pub fn ricAllowedInReassoc(ap_advertised_ft: bool, resource_request_protocol_used: bool) bool {
    return ap_advertised_ft and !resource_request_protocol_used;
}

/// 图 13-21 的 Block Ack 版：往游标里写一条 Resource Request（RDE + count 个 Block Ack 描述符）。
pub fn putBlockAckResourceRequest(c: *Cursor, rde_id: u8, descriptors: []const BlockAck) BuildError!void {
    if (descriptors.len == 0 or descriptors.len > 255) return error.TooLong;
    var buf: [rde_len]u8 = undefined;
    requestRde(rde_id, @intCast(descriptors.len)).encode(&buf);
    try c.put(&buf);
    for (descriptors) |ba| {
        var d: [ric_descriptor_block_ack_len]u8 = undefined;
        try c.put(encodeBlockAckDescriptor(ba, &d));
    }
}

/// 图 13-27 的一条 Resource Response：RDE（带结果状态码）+ 零或一个 Block Ack 描述符
/// （13.11.2：请求成功时回 AP 改过的那一个，失败时可以回一条建议）。
pub fn putBlockAckResourceResponse(c: *Cursor, rde_id: u8, status: u16, descriptor: ?BlockAck) BuildError!void {
    var buf: [rde_len]u8 = undefined;
    const r = Rde{ .rde_id = rde_id, .descriptor_count = if (descriptor != null) 1 else 0, .status = status };
    r.encode(&buf);
    try c.put(&buf);
    if (descriptor) |ba| {
        var d: [ric_descriptor_block_ack_len]u8 = undefined;
        try c.put(encodeBlockAckDescriptor(ba, &d));
    }
}

// ---------------------------------------------------------------------------
// 6) 帧的收发与角色
// ---------------------------------------------------------------------------

/// 前两个消息的走法（13.8.1）。
pub const Transport = enum {
    /// over-the-air：装在 Authentication 帧里，直接发给目标 AP（13.5.2）。
    air,
    /// over-the-DS：装在 FT Action 帧里，经当前 AP 转给目标 AP（13.5.3）。
    ds,
};

/// over-the-air 帧的 MAC 头里的 DA、SA。13.5.2、13.7.1 规定了它们：请求的 SA 是 FTO、DA 是目标 AP
/// 的 BSSID，响应反过来。over-the-DS 的前两个消息是 FTO 与当前 AP 之间的 Action 帧，FT 关心的
/// 两个地址在帧体里（9.6.9.2、9.6.9.3），所以不带这一对。
pub const AirHeader = struct { da: [ft.addr_len]u8, sa: [ft.addr_len]u8 };

/// 收到的一帧（帧体，不含 MAC 头与 FCS）。`transport` 由收帧的那一层按帧的子类型给出：
/// Authentication 帧是 `.air`，Category 6 的 Action 帧是 `.ds`；重关联帧不用管它。
pub const Rx = struct {
    transport: Transport = .air,
    /// over-the-air 的帧必填；`.ds` 的帧为 null。
    air: ?AirHeader = null,
    body: []const u8,
};

/// 待发出的一帧：帧体写在调用方给的缓冲里。重关联帧总是 over-the-air。
pub const Tx = struct {
    transport: Transport,
    /// over-the-DS 的帧为 null：它的 MAC 头在 FTO 与当前 AP 之间，由发帧的那一层填。
    air: ?AirHeader,
    body: []const u8,
};

fn sameAddr(a: [ft.addr_len]u8, b: [ft.addr_len]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

/// 12.6.3 的选择：按 AP 的偏好顺序，取 AP 也支持的第一个。没有交集为 null。
fn negotiatedAkm(sta: *const rsne.Rsne, ap: *const rsne.Rsne) ?u8 {
    for (ap.akm[0..ap.akm_len]) |a| {
        if (std.mem.indexOfScalar(u8, sta.akm[0..sta.akm_len], a) != null) return a;
    }
    return null;
}

/// 帧里缺了 RSNE、MDE 或 FTE。
fn require(ie: []const u8) Error![]const u8 {
    if (ie.len == 0) return error.MissingElement;
    return ie;
}

/// 一帧的帧体缓冲上限：RSNE 取 `rsne.max_len`、FTE 带 48 八位组的 R0KH-ID 与 32 八位组的
/// GTK、IGTK 时，最长的一帧（Reassociation Response）不到 410 个八位组；RIC 另计。
pub const frame_buf_len = 512;

/// 第四个消息里装进来的组密钥。
pub const GroupKey = struct {
    key_id: u16,
    /// GTK 的 RSC（8 个八位组）；IGTK 的 IPN 放在前 6 个八位组，后两个为 0。
    pn: [rsc_len]u8 = @splat(0),
    key: [key_max]u8 = @splat(0),
    key_len: u8 = 0,

    pub fn keySlice(self: *const GroupKey) []const u8 {
        return self.key[0..self.key_len];
    }
};

/// 消息 3、消息 4 共用的收尾：RSNE、MDE、FTE、RIC 在缓冲里依次排着，`marks` 记下各自的起点。
const MicMarks = struct { rsne: usize, mde: usize, fte: usize, ric: usize };

/// 消息 3、消息 4 的 MIC 算在写好的字节上（此时 FTE 的 MIC 字段为 0），再填回 FTE。
fn sealMic(c: *Cursor, marks: MicMarks, kck: [kck_len]u8, fto: [ft.addr_len]u8, target_ap: [ft.addr_len]u8, seq: MicSeq) void {
    const els = Elements{
        .rsne = c.buf[marks.rsne..marks.mde],
        .mde = c.buf[marks.mde..marks.fte],
        .fte = c.buf[marks.fte..marks.ric],
    };
    const tag = mic(kck, fto, target_ap, seq, els, c.buf[marks.ric..c.pos]);
    @memcpy(c.buf[marks.fte + fte_mic_off ..][0..mic_len], &tag);
}

/// 追加「PMKID List 里是 `name`」的 RSNE：13.8.2–13.8.5 四个消息的 RSNE 都是这个样子。
fn putRsneWithPmkid(c: *Cursor, base: rsne.Rsne, name: [ft.name_len]u8) BuildError!void {
    var r = base;
    r.pmkid_present = true;
    r.pmkid_len = 1;
    r.pmkid[0] = name;
    try putRsne(c, r);
}

/// PMK-R1 安全关联（13.9.2.2：R0KH 交给 R1KH 的那一份）：密钥、名字，以及初始关联时协商的
/// 成对密码套件——目标 AP 用它核对 STA 这次选的套件没有变（12.7.1.7.1）。
pub fn PmkR1Sa(comptime akm: ft.Akm) type {
    return struct { key: [ft.hashLen(akm)]u8, name: [ft.name_len]u8, pairwise: u8 };
}

/// R0KH（13.9.2）：为一个 STA 持有 PMK-R0 安全关联。真实的 R0KH 经安全信道把 PMK-R1 SA 送给
/// R1KH（13.2.2、13.9.2.2 的 FT-R0-SEND-PMKR1SA）；`pull` 是那次交付的进程内替身，
/// R0KH 与 R1KH 之间的协议（13.10）不在本文件。
pub fn R0kh(comptime akm: ft.Akm) type {
    comptime supportedAkm(akm);
    return struct {
        const Self = @This();

        /// 这份 PMK-R0 属于哪个 STA（S0KH-ID）。
        sta: [ft.addr_len]u8,
        pmk_r0: ft.PmkR0(akm),
        /// 初始移动域关联时协商的成对密码套件，随 PMK-R1 SA 一起交给 R1KH。
        pairwise: u8,

        pub const PullError = error{NoPmkR0};

        /// Derive-Key-PMK-R1 (R1KH-ID)（13.9.2.4）。S1KH-ID 与 PMKR0Name 都对上才派生；
        /// 对不上说明这个 STA 在本 R0KH 里没有这个名字的 PMK-R0。
        pub fn pull(self: *const Self, s1kh_id: [ft.addr_len]u8, pmk_r0_name: [ft.name_len]u8, r1kh_id: [ft.addr_len]u8) PullError!PmkR1Sa(akm) {
            if (!sameAddr(self.sta, s1kh_id)) return error.NoPmkR0;
            if (!timing.eql([ft.name_len]u8, self.pmk_r0.name, pmk_r0_name)) return error.NoPmkR0;
            const r1 = ft.derivePmkR1(akm, self.pmk_r0, r1kh_id, s1kh_id);
            return .{ .key = r1.key, .name = r1.name, .pairwise = self.pairwise };
        }
    };
}

/// 配置不成立的原因。SsidLength、R0khIdLength 与 `ft.DeriveError` 同名同义。
pub const ConfigError = error{
    R0khIdLength,
    SsidLength,
    /// RSNE 没有 RSN Capabilities 字段。PMKID List 与 Group Management Cipher Suite 都排在它后面
    /// （图 9-255），而协议层要往 PMKID List 里写名字。
    RsneNoCaps,
    /// 模板 RSNE 的 PMKID List 里已经有 PMKID；这一栏由协议层填。
    RsneHasPmkid,
    /// AKM 或成对密码套件的列表比 `rsne.zig` 能装的多。
    ListTooLong,
    /// AKM 那一栏不对：STA 的 RSNE 只应有本 AKM 一个（12.6.3），AP 的 RSNE 必须含本 AKM。
    AkmNotInRsne,
    /// 成对密码套件那一栏不对：STA 的 RSNE 只应有初始关联的那一个，AP 的 RSNE 必须含它。
    PairwiseNotInRsne,
    /// 组密码套件不是 CCMP、GCMP 的四个之一，或 GTK 的长度与它不符（表 12-4）。
    GroupCipher,
    /// Group Management Cipher Suite 与 IGTK 不配：有套件没给 IGTK、没套件却给了，或长度不符。
    IgtkMismatch,
};

fn checkR0khId(r0kh_id: []const u8) ConfigError!void {
    if (r0kh_id.len == 0 or r0kh_id.len > ft.r0kh_id_max) return error.R0khIdLength;
}

/// 模板 RSNE 的两条通用要求：有 RSN Capabilities，PMKID List 为空。
fn checkRsneTemplate(r: *const rsne.Rsne) ConfigError!void {
    if (!r.caps_present) return error.RsneNoCaps;
    if (r.pmkid_len != 0) return error.RsneHasPmkid;
}

fn checkGroup(r: *const rsne.Rsne, gtk: []const u8, igtk: []const u8) ConfigError!void {
    const gtk_len = groupKeyLen(r.group) orelse return error.GroupCipher;
    if (gtk.len != gtk_len) return error.GroupCipher;
    if (r.gmcs_present) {
        const igtk_len = groupKeyLen(r.gmcs) orelse return error.IgtkMismatch;
        if (igtk.len != igtk_len) return error.IgtkMismatch;
    } else if (igtk.len != 0) {
        return error.IgtkMismatch;
    }
}

// ---------------------------------------------------------------------------
// 6a) 目标 AP：R1KH
// ---------------------------------------------------------------------------

/// 目标 AP 的配置。`r0kh_id`、`gtk`、`igtk` 指向调用方的存储，本对象只借用。
pub const ApConfig = struct {
    bssid: [ft.addr_len]u8,
    mdid: [ft.mdid_len]u8,
    /// 本 AP 在 MDE 里通告的 FT Capability and Policy（13.3）。
    ft_cap: u8,
    /// dot11FTR0KeyHolderID：本 AP 够得着的那个 R0KH。
    r0kh_id: []const u8,
    /// dot11FTR1KeyHolderID（13.2.2）。
    r1kh_id: [ft.addr_len]u8,
    /// Beacon / Probe Response 里的 RSNE。
    rsne: rsne.Rsne,
    cap_info: u16,
    aid: u16,
    gtk: []const u8,
    gtk_key_id: u8 = 0,
    gtk_rsc: [rsc_len]u8 = @splat(0),
    /// 管理帧保护启用时随第四个消息下发；不启用时留空。
    igtk: []const u8 = &.{},
    igtk_key_id: u16 = 0,
    igtk_ipn: [ipn_len]u8 = @splat(0),
    /// 重关联截止时间（TU）。0 表示没有期限（9.4.2.49）。
    deadline_tu: u32 = 0,
};

/// AP 丢弃一帧的原因。
pub const DropReason = enum {
    /// 帧体不是这一步该有的样子：固定部分解析不了，或不是 FT 的算法号 / Category / FT Action。
    malformed,
    /// 这一帧不是发给本 AP 的。
    not_for_us,
    /// 没有先经过第一个消息（没有这个 FTO 的 PTKSA），或重关联已经完成。
    no_ptksa,
    /// FTE 的 MIC 不对（13.7.1：丢弃），或者没法验证：元素区走不通、缺 RSNE / MDE / FTE、
    /// 没有 MIC、Element Count 对不上。
    mic,
    /// 重关联截止时间已过，PTKSA 已删除（13.5.2）。
    deadline,
};

/// AP 处理完一帧之后的动作：回一帧，或者丢弃。
pub const Reply = union(enum) {
    tx: Tx,
    drop: DropReason,
};

pub const ApError = Error || error{
    /// 请求里有 RIC-Request，却没有给 RIC-Response（13.8.5：请求了资源就要回）。
    RicResponseRequired,
    /// 请求里没有 RIC-Request，却给了 RIC-Response。
    RicResponseUnexpected,
};

/// 目标 AP 一侧（R1KH）。一个实例对应一个 FTO 的一次转换（13.9.3.1：每次转换新建一个状态机实例）。
pub fn Ap(comptime akm: ft.Akm, comptime pairwise: u8) type {
    comptime supportedAkm(akm);
    const tk_len = comptime tkLen(pairwise);
    return struct {
        const Self = @This();

        pub const State = enum {
            /// 还没有 PMK-R1 SA。
            idle,
            /// 第二个消息已发出：有 PMK-R1 SA 与 PTKSA，在等重关联。
            authenticated,
            /// 重关联完成（13.7.1）。
            established,
        };

        pub const InitError = ConfigError;

        cfg: ApConfig,
        state: State = .idle,
        /// 发起转换的 FTO 的地址。
        fto: [ft.addr_len]u8 = @splat(0),
        snonce: [ft.nonce_len]u8 = @splat(0),
        anonce: [ft.nonce_len]u8 = @splat(0),
        pmk_r1: ft.PmkR1(akm) = std.mem.zeroes(ft.PmkR1(akm)),
        pmk_r0_name: [ft.name_len]u8 = @splat(0),
        ptk: ft.Ptk(akm, tk_len) = std.mem.zeroes(ft.Ptk(akm, tk_len)),
        /// 收到第一个消息的时刻（TU），截止时间从这里算（图 13-15：PMK-R1 SA 到达时装填计时器）。
        first_tu: u32 = 0,

        pub fn init(cfg: ApConfig) InitError!Self {
            try checkR0khId(cfg.r0kh_id);
            try checkRsneTemplate(&cfg.rsne);
            if (std.mem.indexOfScalar(u8, cfg.rsne.akm[0..cfg.rsne.akm_len], @backingInt(akm)) == null) return error.AkmNotInRsne;
            if (std.mem.indexOfScalar(u8, cfg.rsne.pairwise[0..cfg.rsne.pairwise_len], pairwise) == null) return error.PairwiseNotInRsne;
            try checkGroup(&cfg.rsne, cfg.gtk, cfg.igtk);
            return .{ .cfg = cfg };
        }

        /// 删掉上一次的 PMK-R1 SA 与由它派生的 PTKSA（13.5.2：收到新的 PMK-R1 就这样做）。
        fn reset(self: *Self) void {
            self.state = .idle;
            self.pmk_r1 = std.mem.zeroes(ft.PmkR1(akm));
            self.pmk_r0_name = @splat(0);
            self.ptk = std.mem.zeroes(ft.Ptk(akm, tk_len));
        }

        /// 13.5.2：没在截止时间内收到 Reassociation Request，PTKSA 应被删除。0 表示没有期限。
        fn expired(self: *const Self, now_tu: u32) bool {
            if (self.cfg.deadline_tu == 0) return false;
            return now_tu -% self.first_tu > self.cfg.deadline_tu;
        }

        /// 第一个消息核对的结果：通过时带出 R0KH 交来的 PMK-R1 SA、FTO 的 SNonce 与 PMKR0Name；
        /// 不通过时是状态码。
        const FirstVerdict = union(enum) {
            accept: struct { sa: PmkR1Sa(akm), snonce: [ft.nonce_len]u8, pmk_r0_name: [ft.name_len]u8 },
            reject: u16,
        };

        /// 处理第一个消息（13.8.2）：Authentication-Request（`.air`）或 FT Request（`.ds`）。
        /// `anonce` 是本 AP 为这次转换取的 ANonce，`now_tu` 是当前时刻（TU）。每次调用都从新的
        /// 一次转换算起。帧体写进 `out`。
        pub fn onFirst(self: *Self, rx: Rx, anonce: [ft.nonce_len]u8, r0kh: *const R0kh(akm), now_tu: u32, out: []u8) BuildError!Reply {
            self.reset();
            var fto: [ft.addr_len]u8 = undefined;
            var ies: []const u8 = undefined;
            if (rx.transport == .air) {
                // 13.5.2：SA 是 FTO，DA 是目标 AP 的 BSSID。
                const h = rx.air orelse return .{ .drop = .malformed };
                if (!sameAddr(h.da, self.cfg.bssid)) return .{ .drop = .not_for_us };
                const f = parseAuth(rx.body) catch return .{ .drop = .malformed };
                if (f.head.algorithm != auth_alg_ft or f.head.seq != auth_seq_request) return .{ .drop = .malformed };
                fto = h.sa;
                ies = f.ies;
            } else {
                // 9.6.9.2：STA Address 是 FTO，Target AP Address 是目标 AP 的 BSSID。
                const f = parseFtRequest(rx.body) catch return .{ .drop = .malformed };
                if (rx.body[0] != category_ft or rx.body[1] != ft_action_request) return .{ .drop = .malformed };
                if (!sameAddr(f.target_ap, self.cfg.bssid)) return .{ .drop = .not_for_us };
                fto = f.sta;
                ies = f.ies;
            }

            const verdict = self.checkFirst(fto, ies, r0kh);
            const ok = switch (verdict) {
                .accept => |a| a,
                .reject => |status| return .{ .tx = try self.buildSecond(rx.transport, fto, status, out) },
            };
            self.fto = fto;
            self.snonce = ok.snonce;
            self.anonce = anonce;
            self.pmk_r1 = .{ .key = ok.sa.key, .name = ok.sa.name };
            self.pmk_r0_name = ok.pmk_r0_name;
            self.first_tu = now_tu;
            // R1KH 与 S1KH 各自算 PTK（12.7.1.7.5）。
            self.ptk = ft.derivePtk(akm, tk_len, self.pmk_r1, ok.snonce, anonce, self.cfg.bssid, fto);
            self.state = .authenticated;
            return .{ .tx = try self.buildSecond(rx.transport, fto, Status.success, out) };
        }

        /// 13.5.2、13.5.3 的拒绝顺序。某个元素缺席与它本身不合规，按同一个状态码拒绝。
        fn checkFirst(self: *Self, fto: [ft.addr_len]u8, ies: []const u8, r0kh: *const R0kh(akm)) FirstVerdict {
            const els = scan(ies) catch return .{ .reject = Status.status_invalid_element };
            // MDE 的内容必须与本 AP 在 Beacon 里通告的一样。
            if (els.mde.len == 0) return .{ .reject = Status.status_invalid_mde };
            const m = Mdie.parse(els.mde) catch return .{ .reject = Status.status_invalid_mde };
            if (!std.mem.eql(u8, &m.mdid, &self.cfg.mdid) or m.ft_cap != self.cfg.ft_cap) return .{ .reject = Status.status_invalid_mde };
            // 协商到的 AKM 必须是 FT 的。
            if (els.rsne.len == 0) return .{ .reject = Status.status_invalid_akmp };
            const r = rsne.parse(els.rsne) catch return .{ .reject = Status.status_invalid_akmp };
            const akm_type = negotiatedAkm(&r, &self.cfg.rsne) orelse return .{ .reject = Status.status_invalid_akmp };
            if (!micAkmSupported(akm_type)) return .{ .reject = Status.status_invalid_akmp };
            // FTE 里的 R0KH-ID。
            if (els.fte.len == 0) return .{ .reject = Status.status_invalid_fte };
            const f = parseFte(els.fte) catch return .{ .reject = Status.status_invalid_fte };
            const r0kh_id = f.r0kh_id orelse return .{ .reject = Status.status_invalid_fte };
            if (!std.mem.eql(u8, r0kh_id, self.cfg.r0kh_id)) return .{ .reject = Status.r0kh_unreachable };
            // PMKR0Name 是否有效，只有 R0KH 知道。
            if (!r.pmkid_present or r.pmkid_len != 1) return .{ .reject = Status.status_invalid_pmkid };
            const sa = r0kh.pull(fto, r.pmkid[0], self.cfg.r1kh_id) catch return .{ .reject = Status.status_invalid_pmkid };
            // 成对密码套件必须与初始移动域关联时的一样（12.7.1.7.1）。
            if (std.mem.indexOfScalar(u8, r.pairwise[0..r.pairwise_len], sa.pairwise) == null) return .{ .reject = Status.status_invalid_pairwise_cipher };
            return .{ .accept = .{ .sa = sa, .snonce = f.snonce, .pmk_r0_name = r.pmkid[0] } };
        }

        /// 第二个消息（13.8.3）。状态码不是 SUCCESS 时只有固定部分（表 9-36、9.6.9.3）。
        fn buildSecond(self: *Self, transport: Transport, fto: [ft.addr_len]u8, status: u16, out: []u8) BuildError!Tx {
            var c = Cursor{ .buf = out };
            if (transport == .air) {
                // 表 9-35：算法号 | 事务序号 | 状态码。
                try c.putU16(auth_alg_ft);
                try c.putU16(auth_seq_response);
                try c.putU16(status);
            } else {
                // 图 9-689：Category | FT Action | STA Address | Target AP Address | Status Code。
                try c.putU8(category_ft);
                try c.putU8(ft_action_response);
                try c.put(&fto);
                try c.put(&self.cfg.bssid);
                try c.putU16(status);
            }
            const air: ?AirHeader = if (transport == .air) AirHeader{ .da = fto, .sa = self.cfg.bssid } else null;
            if (status != Status.success) return .{ .transport = transport, .air = air, .body = c.body() };

            // RSNE：与 Beacon 里的一样，PMKID List 换成 PMKR0Name（13.8.3）。
            try putRsneWithPmkid(&c, self.cfg.rsne, self.pmk_r0_name);
            try putMdie(&c, .{ .mdid = self.cfg.mdid, .ft_cap = self.cfg.ft_cap });
            // R0KH-ID 与第一个消息里的相同，R1KH-ID 是本 AP 的，ANonce 是新取的，SNonce 是第一个消息里的；
            // 其余字段为 0（13.8.3）。
            const at = try putFteHead(&c, 0, self.anonce, self.snonce);
            try c.subelement(Subelem.r1kh_id, &self.cfg.r1kh_id);
            try c.subelement(Subelem.r0kh_id, self.cfg.r0kh_id);
            try endFte(&c, at);
            return .{ .transport = transport, .air = air, .body = c.body() };
        }

        /// 处理第三个消息：Reassociation Request（13.8.4）。`ric_response` 是随第四个消息回去的
        /// RIC-Response 的内容（原样放入）：请求里有 RIC-Request 时必须给，没有时必须不给。
        pub fn onThird(self: *Self, rx: Rx, ric_response: []const u8, now_tu: u32, out: []u8) ApError!Reply {
            if (self.state != .authenticated) return .{ .drop = .no_ptksa };
            if (self.expired(now_tu)) {
                self.reset();
                return .{ .drop = .deadline };
            }
            // 13.7.1：SA 是 FTO，DA 是目标 AP 的 BSSID。
            const h = rx.air orelse return .{ .drop = .malformed };
            if (!sameAddr(h.da, self.cfg.bssid)) return .{ .drop = .not_for_us };
            if (!sameAddr(h.sa, self.fto)) return .{ .drop = .no_ptksa };
            const f = parseReassocRequest(rx.body) catch return .{ .drop = .malformed };

            // 先验 MIC（13.7.1）：不对就丢弃。结构上没法验的也算 MIC 不对。
            const els = scan(f.ies) catch return .{ .drop = .mic };
            const fte = parseFte(els.fte) catch return .{ .drop = .mic };
            const ric = ricProtected(els, fte.element_count) catch return .{ .drop = .mic };
            if (!micEqual(mic(self.ptk.kck, h.sa, h.da, .reassoc_request, els, ric), fte.mic)) return .{ .drop = .mic };

            const verdict = self.checkThird(els, fte);
            var mfp = false;
            const status = switch (verdict) {
                .accept => |a| blk: {
                    mfp = a.mfp_negotiated;
                    break :blk Status.success;
                },
                .reject => |s| s,
            };
            if (status != Status.success) {
                var c = Cursor{ .buf = out };
                try c.putU16(self.cfg.cap_info);
                try c.putU16(status);
                try c.putU16(0); // 失败时 AID 为 0
                return .{ .tx = .{ .transport = .air, .air = .{ .da = self.fto, .sa = self.cfg.bssid }, .body = c.body() } };
            }
            // 13.8.5：请求了资源才回 RIC-Response。
            if (ric.len != 0 and ric_response.len == 0) return error.RicResponseRequired;
            if (ric.len == 0 and ric_response.len != 0) return error.RicResponseUnexpected;

            // 表 9-32：Capability Information | Status code | AID。
            var c = Cursor{ .buf = out };
            try c.putU16(self.cfg.cap_info);
            try c.putU16(Status.success);
            try c.putU16(self.cfg.aid);
            const rsne_at = c.pos;
            try putRsneWithPmkid(&c, self.cfg.rsne, self.pmk_r1.name);
            const mde_at = c.pos;
            try putMdie(&c, .{ .mdid = self.cfg.mdid, .ft_cap = self.cfg.ft_cap });
            const count = try protectedCount(ric_response);
            const fte_at = try putFteHead(&c, count, self.anonce, self.snonce);
            try c.subelement(Subelem.r1kh_id, &self.cfg.r1kh_id);
            try c.subelement(Subelem.r0kh_id, self.cfg.r0kh_id);
            try putGtkSubelem(&c, self.ptk.kek, self.cfg.gtk_key_id, self.cfg.gtk, self.cfg.gtk_rsc);
            // 协商了管理帧保护（12.6.3）、且本 AP 配了 IGTK，才下发它。
            if (mfp and self.cfg.igtk.len != 0) try putIgtkSubelem(&c, self.ptk.kek, self.cfg.igtk_key_id, self.cfg.igtk_ipn, self.cfg.igtk);
            try endFte(&c, fte_at);
            const ric_at = c.pos;
            try c.put(ric_response);
            sealMic(&c, .{ .rsne = rsne_at, .mde = mde_at, .fte = fte_at, .ric = ric_at }, self.ptk.kck, self.fto, self.cfg.bssid, .reassoc_response);
            self.state = .established;
            return .{ .tx = .{ .transport = .air, .air = .{ .da = self.fto, .sa = self.cfg.bssid }, .body = c.body() } };
        }

        /// MIC 验过之后的内容核对（13.7.1 的顺序）：不通过时是状态码；通过时带出管理帧保护是否
        /// 已协商（12.6.3：双方 RSNE 的 MFPC 都为 1），它决定第四个消息里带不带 IGTK。
        const ThirdVerdict = union(enum) {
            accept: struct { mfp_negotiated: bool },
            reject: u16,
        };

        fn checkThird(self: *Self, els: Elements, fte: Fte) ThirdVerdict {
            const m = Mdie.parse(els.mde) catch return .{ .reject = Status.status_invalid_mde };
            if (!std.mem.eql(u8, &m.mdid, &self.cfg.mdid) or m.ft_cap != self.cfg.ft_cap) return .{ .reject = Status.status_invalid_mde };
            // FTE 的 ANonce、SNonce、R0KH-ID、R1KH-ID 必须是第二个消息里的那几个。
            const r1kh_ok = if (fte.r1kh_id) |id| sameAddr(id, self.cfg.r1kh_id) else false;
            const r0kh_ok = if (fte.r0kh_id) |id| std.mem.eql(u8, id, self.cfg.r0kh_id) else false;
            if (!r1kh_ok or !r0kh_ok or !std.mem.eql(u8, &fte.anonce, &self.anonce) or !std.mem.eql(u8, &fte.snonce, &self.snonce)) {
                return .{ .reject = Status.status_invalid_fte };
            }
            const r = rsne.parse(els.rsne) catch return .{ .reject = Status.status_invalid_pmkid };
            if (!r.pmkid_present or r.pmkid_len != 1 or !timing.eql([ft.name_len]u8, r.pmkid[0], self.pmk_r1.name)) {
                return .{ .reject = Status.status_invalid_pmkid };
            }
            return .{ .accept = .{ .mfp_negotiated = r.mfpc() and self.cfg.rsne.mfpc() } };
        }
    };
}

// ---------------------------------------------------------------------------
// 6b) FTO：S0KH + S1KH
// ---------------------------------------------------------------------------

/// FTO 的配置，也就是它在初始移动域关联结束时手上的东西（13.4.2）。`r0kh_id`、`ssid` 指向
/// 调用方的存储，本对象只借用。
pub fn StaConfig(comptime akm: ft.Akm) type {
    return struct {
        /// 本 FTO 的地址（S0KH-ID、S1KH-ID、STA-ADDR）。
        own_addr: [ft.addr_len]u8,
        target_ap: [ft.addr_len]u8,
        current_ap: [ft.addr_len]u8,
        /// 初始移动域关联时的 MDID。
        mdid: [ft.mdid_len]u8,
        /// 目标 AP 在 Beacon / Probe Response 的 MDE 里通告的 FT Capability and Policy。
        target_ft_cap: u8,
        /// 初始关联的 (Re)Association Response 的 FTE 里的 R0KH-ID。
        r0kh_id: []const u8,
        /// S0KH 持有的 PMK-R0 安全关联。
        pmk_r0: ft.PmkR0(akm),
        /// 本 STA 的 RSNE 里 PMKID 以外的字段（9.4.2.25、12.6.3：一个 AKM、一个成对密码套件、
        /// AP 的组密码套件）。PMKID List 由协议层填。
        rsne: rsne.Rsne,
        ssid: []const u8,
        cap_info: u16,
        listen_interval: u16,
        /// 重关联截止时间（TU）。0 表示没有期限（9.4.2.49）。
        deadline_tu: u32 = 0,
    };
}

/// FTO 处理一帧的结果。
pub const StaResult = union(enum) {
    ok,
    /// 目标 AP 回了失败的状态码（11.3 的处理由调用方决定）。
    rejected: u16,
};

pub const StaError = Error || rsne.Error || UnwrapError || error{
    /// 这一帧不是当前这一步等的那一种：状态不对，或走法（air / ds）与发起时不同。
    UnexpectedFrame,
    /// 13.5.3：目标 AP 的 MDE 里 Fast BSS Transition over DS 位是 0，不得发起 over-the-DS。
    OverDsNotSupported,
    /// 重关联截止时间已过（13.7.1：FTO 应放弃这次转换）。
    DeadlineExpired,
    /// MAC 头的 DA / SA 不是「FTO ↔ 目标 AP」这一对，或 FT Response 帧体的 STA Address /
    /// Target AP Address 不对。
    WrongAddresses,
    /// MDE 的 MDID 或 FT Capability and Policy 与目标 AP 通告的不同。
    MdieMismatch,
    /// FTE 里的 SNonce 不是自己发出去的那个。
    SnonceMismatch,
    /// FTE 里的 ANonce 与第二个消息里的不同。
    AnonceMismatch,
    MissingR0khId,
    /// FTE 里的 R0KH-ID 与自己记下的不同。
    R0khIdMismatch,
    MissingR1khId,
    /// FTE 里的 R1KH-ID 与第二个消息里的不同。
    R1khIdMismatch,
    /// RSNE 的 PMKID 不是 PMKR0Name。
    PmkR0NameMismatch,
    /// RSNE 的 PMKID 不是 PMKR1Name。
    PmkR1NameMismatch,
    /// FTE 的 MIC 不对（13.7.1：丢弃）。
    MicFailed,
    /// GTK 子元素的 Key Length 与协商的组密码套件不符（表 12-4）。
    GtkLengthMismatch,
    /// IGTK 子元素的 Key Length 与 Group Management Cipher Suite 不符。
    IgtkLengthMismatch,
    /// 没有协商管理帧保护，第四个消息里却带了 IGTK。
    UnexpectedIgtk,
};

/// FTO 一侧。`pmk_r0` 是 S0KH 的那一份；收到第二个消息后 S0KH 派生 PMK-R1，S1KH 派生 PTK。
pub fn Sta(comptime akm: ft.Akm, comptime pairwise: u8) type {
    comptime supportedAkm(akm);
    const tk_len = comptime tkLen(pairwise);
    return struct {
        const Self = @This();

        pub const State = enum {
            idle,
            /// 第一个消息已发出，在等第二个。
            requested,
            /// 第二个消息已核对：有 PTK，可以重关联（状态 2）。
            authenticated,
            /// Reassociation Request 已发出，在等响应。
            reassociating,
            /// 重关联完成（状态 4）。
            done,
        };

        pub const InitError = ConfigError;
        pub const StartError = BuildError || error{OverDsNotSupported};

        cfg: StaConfig(akm),
        state: State = .idle,
        transport: Transport = .air,
        snonce: [ft.nonce_len]u8 = @splat(0),
        anonce: [ft.nonce_len]u8 = @splat(0),
        /// 第二个消息里目标 AP 给的 R1KH-ID。
        r1kh_id: [ft.addr_len]u8 = @splat(0),
        pmk_r1_name: [ft.name_len]u8 = @splat(0),
        ptk: ft.Ptk(akm, tk_len) = std.mem.zeroes(ft.Ptk(akm, tk_len)),
        /// 收到并核对第二个消息的时刻（TU），FTO 的截止时间从这里算（图 13-18）。
        confirm_tu: u32 = 0,
        /// 第四个消息里解出来的组密钥；没带为 null。
        gtk: ?GroupKey = null,
        igtk: ?GroupKey = null,

        pub fn init(cfg: StaConfig(akm)) InitError!Self {
            try checkR0khId(cfg.r0kh_id);
            try checkRsneTemplate(&cfg.rsne);
            // 12.6.3：发起关联的 STA 的 RSNE 里是一个 AKM、一个成对密码套件。
            if (cfg.rsne.akm_len != 1 or cfg.rsne.akm[0] != @backingInt(akm)) return error.AkmNotInRsne;
            if (cfg.rsne.pairwise_len != 1 or cfg.rsne.pairwise[0] != pairwise) return error.PairwiseNotInRsne;
            if (cfg.ssid.len == 0 or cfg.ssid.len > ft.ssid_max) return error.SsidLength;
            if (groupKeyLen(cfg.rsne.group) == null) return error.GroupCipher;
            return .{ .cfg = cfg };
        }

        /// 13.7.1：FTO 没在截止时间内发出 Reassociation Request，就放弃这次转换。0 表示没有期限。
        fn expired(self: *const Self, now_tu: u32) bool {
            if (self.cfg.deadline_tu == 0) return false;
            return now_tu -% self.confirm_tu > self.cfg.deadline_tu;
        }

        /// 第一个消息（13.8.2）：Authentication-Request（`.air`）或 FT Request（`.ds`）。
        /// `snonce` 是为这次转换新取的 SNonce。上一次没走完的转换作废（PMK-R1 SA、PTK、组密钥都清掉）。
        pub fn start(self: *Self, transport: Transport, snonce: [ft.nonce_len]u8, out: []u8) StartError!Tx {
            // 13.5.3：目标 AP 的 over DS 位是 0，就不得经 DS 发起。
            if (transport == .ds and !capOverDs(self.cfg.target_ft_cap)) return error.OverDsNotSupported;
            self.state = .requested;
            self.transport = transport;
            self.snonce = snonce;
            self.anonce = @splat(0);
            self.r1kh_id = @splat(0);
            self.pmk_r1_name = @splat(0);
            self.ptk = std.mem.zeroes(ft.Ptk(akm, tk_len));
            self.gtk = null;
            self.igtk = null;

            var c = Cursor{ .buf = out };
            if (transport == .air) {
                // 表 9-35：算法号 | 事务序号 | 状态码（事务序号 1 时保留，写 0）。
                try c.putU16(auth_alg_ft);
                try c.putU16(auth_seq_request);
                try c.putU16(Status.success);
            } else {
                // 图 9-688：Category | FT Action | STA Address | Target AP Address。
                try c.putU8(category_ft);
                try c.putU8(ft_action_request);
                try c.put(&self.cfg.own_addr);
                try c.put(&self.cfg.target_ap);
            }
            try putRsneWithPmkid(&c, self.cfg.rsne, self.cfg.pmk_r0.name);
            // MDID 与 FT Capability and Policy 取目标 AP 通告的那一个（13.8.2、9.4.2.47）。
            try putMdie(&c, .{ .mdid = self.cfg.mdid, .ft_cap = self.cfg.target_ft_cap });
            // 只有 R0KH-ID 与 SNonce，其余字段为 0（13.8.2）：没有 MIC，ANonce 为 0，不带 R1KH-ID。
            const at = try putFteHead(&c, 0, @splat(0), snonce);
            try c.subelement(Subelem.r0kh_id, self.cfg.r0kh_id);
            try endFte(&c, at);
            const air: ?AirHeader = if (transport == .air) AirHeader{ .da = self.cfg.target_ap, .sa = self.cfg.own_addr } else null;
            return .{ .transport = transport, .air = air, .body = c.body() };
        }

        /// 第二个消息（13.8.3）：Authentication-Response 或 FT Response。核对通过后 S0KH 按 FTE 里的
        /// R1KH-ID 派生 PMK-R1，S1KH 再派生 PTK。`now_tu` 是当前时刻（TU）。
        pub fn onSecond(self: *Self, rx: Rx, now_tu: u32) StaError!StaResult {
            if (self.state != .requested or rx.transport != self.transport) return error.UnexpectedFrame;
            var ies: []const u8 = undefined;
            var status: u16 = undefined;
            if (rx.transport == .air) {
                // 13.5.2：SA 是目标 AP 的 BSSID，DA 是 FTO。
                const h = rx.air orelse return error.WrongAddresses;
                if (!sameAddr(h.da, self.cfg.own_addr) or !sameAddr(h.sa, self.cfg.target_ap)) return error.WrongAddresses;
                const f = try parseAuth(rx.body);
                if (f.head.algorithm != auth_alg_ft or f.head.seq != auth_seq_response) return error.BadHeader;
                status = f.head.status;
                ies = f.ies;
            } else {
                // 9.6.9.3：STA Address 是 FTO，Target AP Address 是目标 AP 的 BSSID。
                const f = try parseFtResponse(rx.body);
                if (rx.body[0] != category_ft or rx.body[1] != ft_action_response) return error.BadHeader;
                if (!sameAddr(f.sta, self.cfg.own_addr) or !sameAddr(f.target_ap, self.cfg.target_ap)) return error.WrongAddresses;
                status = f.status;
                ies = f.ies;
            }
            if (status != Status.success) return .{ .rejected = status };

            const els = try scan(ies);
            const m = try Mdie.parse(try require(els.mde));
            if (!std.mem.eql(u8, &m.mdid, &self.cfg.mdid) or m.ft_cap != self.cfg.target_ft_cap) return error.MdieMismatch;
            const fte = try parseFte(try require(els.fte));
            // 13.8.3：SNonce 是第一个消息里的那一个。
            if (!std.mem.eql(u8, &fte.snonce, &self.snonce)) return error.SnonceMismatch;
            const r0kh_id = fte.r0kh_id orelse return error.MissingR0khId;
            if (!std.mem.eql(u8, r0kh_id, self.cfg.r0kh_id)) return error.R0khIdMismatch;
            const r1kh_id = fte.r1kh_id orelse return error.MissingR1khId;
            const r = try rsne.parse(try require(els.rsne));
            if (!r.pmkid_present or r.pmkid_len != 1 or !timing.eql([ft.name_len]u8, r.pmkid[0], self.cfg.pmk_r0.name)) {
                return error.PmkR0NameMismatch;
            }

            self.anonce = fte.anonce;
            self.r1kh_id = r1kh_id;
            const r1 = ft.derivePmkR1(akm, self.cfg.pmk_r0, r1kh_id, self.cfg.own_addr);
            self.pmk_r1_name = r1.name;
            self.ptk = ft.derivePtk(akm, tk_len, r1, self.snonce, self.anonce, self.cfg.target_ap, self.cfg.own_addr);
            self.confirm_tu = now_tu;
            self.state = .authenticated;
            return .ok;
        }

        /// 第三个消息（13.8.4）：Reassociation Request。`ric_request` 是随请求带上的 RIC-Request
        /// 的内容（原样放入；不请求资源就给空）。
        pub fn buildThird(self: *Self, ric_request: []const u8, now_tu: u32, out: []u8) StaError!Tx {
            if (self.state != .authenticated) return error.UnexpectedFrame;
            if (self.expired(now_tu)) {
                self.state = .idle;
                return error.DeadlineExpired;
            }
            const count = try protectedCount(ric_request);
            var c = Cursor{ .buf = out };
            // 表 9-31：Capability Information | Listen Interval | Current AP address，然后是 SSID。
            try c.putU16(self.cfg.cap_info);
            try c.putU16(self.cfg.listen_interval);
            try c.put(&self.cfg.current_ap);
            try c.element(Eid.ssid, self.cfg.ssid);
            const rsne_at = c.pos;
            try putRsneWithPmkid(&c, self.cfg.rsne, self.pmk_r1_name);
            const mde_at = c.pos;
            // MDE 与第一个消息里的相同（13.8.4）。
            try putMdie(&c, .{ .mdid = self.cfg.mdid, .ft_cap = self.cfg.target_ft_cap });
            // ANonce、SNonce、R0KH-ID、R1KH-ID 都是第二个消息里的值。
            const fte_at = try putFteHead(&c, count, self.anonce, self.snonce);
            try c.subelement(Subelem.r1kh_id, &self.r1kh_id);
            try c.subelement(Subelem.r0kh_id, self.cfg.r0kh_id);
            try endFte(&c, fte_at);
            const ric_at = c.pos;
            try c.put(ric_request);
            sealMic(&c, .{ .rsne = rsne_at, .mde = mde_at, .fte = fte_at, .ric = ric_at }, self.ptk.kck, self.cfg.own_addr, self.cfg.target_ap, .reassoc_request);
            self.state = .reassociating;
            return .{ .transport = .air, .air = .{ .da = self.cfg.target_ap, .sa = self.cfg.own_addr }, .body = c.body() };
        }

        /// 第四个消息（13.8.5）：Reassociation Response。S1KH 先验 MIC（13.7.1），再核对内容，
        /// 最后解开 GTK / IGTK。
        pub fn onFourth(self: *Self, rx: Rx) StaError!StaResult {
            if (self.state != .reassociating) return error.UnexpectedFrame;
            // 13.7.1：SA 是目标 AP 的 BSSID，DA 是 FTO。
            const h = rx.air orelse return error.WrongAddresses;
            if (!sameAddr(h.da, self.cfg.own_addr) or !sameAddr(h.sa, self.cfg.target_ap)) return error.WrongAddresses;
            const f = try parseReassocResponse(rx.body);
            if (f.head.status != Status.success) return .{ .rejected = f.head.status };

            const els = try scan(f.ies);
            const rsne_ie = try require(els.rsne);
            const mde_ie = try require(els.mde);
            const fte_ie = try require(els.fte);
            const fte = try parseFte(fte_ie);
            const ric = try ricProtected(els, fte.element_count);
            if (!micEqual(mic(self.ptk.kck, self.cfg.own_addr, h.sa, .reassoc_response, els, ric), fte.mic)) return error.MicFailed;

            // MIC 对了，再核对内容（13.8.5：都与第二个消息里的相同）。
            const m = try Mdie.parse(mde_ie);
            if (!std.mem.eql(u8, &m.mdid, &self.cfg.mdid) or m.ft_cap != self.cfg.target_ft_cap) return error.MdieMismatch;
            if (!std.mem.eql(u8, &fte.snonce, &self.snonce)) return error.SnonceMismatch;
            if (!std.mem.eql(u8, &fte.anonce, &self.anonce)) return error.AnonceMismatch;
            const r0kh_id = fte.r0kh_id orelse return error.MissingR0khId;
            if (!std.mem.eql(u8, r0kh_id, self.cfg.r0kh_id)) return error.R0khIdMismatch;
            const r1kh_id = fte.r1kh_id orelse return error.MissingR1khId;
            if (!sameAddr(r1kh_id, self.r1kh_id)) return error.R1khIdMismatch;
            const r = try rsne.parse(rsne_ie);
            if (!r.pmkid_present or r.pmkid_len != 1 or !timing.eql([ft.name_len]u8, r.pmkid[0], self.pmk_r1_name)) {
                return error.PmkR1NameMismatch;
            }

            // GTK、IGTK：Key Length 必须是协商出来的密钥长度，Wrapped Key 用 KEK 解开。
            self.gtk = null;
            self.igtk = null;
            if (fte.gtk) |g| {
                const want = groupKeyLen(self.cfg.rsne.group) orelse return error.GtkLengthMismatch;
                if (g.key_len != want) return error.GtkLengthMismatch;
                var key = GroupKey{ .key_id = g.key_id, .pn = g.rsc, .key_len = g.key_len };
                try unwrapKey(self.ptk.kek, g.key_len, g.wrapped, &key.key);
                self.gtk = key;
            }
            if (fte.igtk) |g| {
                // 12.6.3：双方 RSNE 的 MFPC 都为 1 才算协商了管理帧保护。IGTK 的长度随本 STA 的
                // Group Management Cipher Suite（缺席时默认 BIP-CMAC-128，印刷页 885）。
                if (!self.cfg.rsne.mfpc() or !r.mfpc()) return error.UnexpectedIgtk;
                const want = groupKeyLen(self.cfg.rsne.gmcs) orelse return error.IgtkLengthMismatch;
                if (g.key_len != want) return error.IgtkLengthMismatch;
                var key = GroupKey{ .key_id = g.key_id, .key_len = g.key_len };
                @memcpy(key.pn[0..ipn_len], &g.ipn);
                try unwrapKey(self.ptk.kek, g.key_len, g.wrapped, &key.key);
                self.igtk = key;
            }
            self.state = .done;
            return .ok;
        }
    };
}

// ---------------------------------------------------------------------------
// 6c) 实验室：把同一份配置分给三个角色
// ---------------------------------------------------------------------------

/// 一个 ESS 的设定与这次转换的输入。`Lab` 由它派生出 PMK-R0，再生成三个角色各自的配置；
/// 三个角色对拍时看到的是同一个 ESS。切片字段（`ssid`、`r0kh_id`、`gtk`、`igtk`、两个套件
/// 列表）指向调用方的存储，`Lab` 只借用。
pub const Setup = struct {
    ssid: []const u8,
    mdid: [ft.mdid_len]u8,
    /// 目标 AP 在 MDE 里通告的 FT Capability and Policy。
    ft_cap: u8,
    /// R0KH-ID：FTO 在初始关联的 FTE 里记下的那一个，也是目标 AP 够得着的那一个。
    r0kh_id: []const u8,
    sta_addr: [ft.addr_len]u8 = @splat(0),
    current_ap: [ft.addr_len]u8 = @splat(0),
    target_ap: [ft.addr_len]u8 = @splat(0),
    /// 目标 AP 的 R1KH-ID。与 BSSID、STA 地址故意可以不同：传反了就对不上。
    r1kh_id: [ft.addr_len]u8 = @splat(0),
    /// 初始移动域关联时用的根密钥：AKM 3 是 MSK，AKM 4 是 PSK，AKM 9 是 MPMK。
    root: ft.RootKey,
    /// 组密码套件（表 9-131 的 suite type）。
    group: u8 = rsne.Cipher.ccmp128,
    /// 目标 AP 的 Beacon RSNE 里的 AKM 列表与成对密码套件列表，都要含协商到的那一个。
    ap_akms: []const u8 = &.{},
    ap_pairwise: []const u8 = &.{},
    sta_caps: u16 = 0,
    ap_caps: u16 = 0,
    /// 目标 AP 的 Beacon RSNE 里的 Group Management Cipher Suite；null 表示管理帧保护没启用。
    gmcs: ?u8 = null,
    /// FTO 的 RSNE 里是否也带这一个套件。
    sta_gmcs: ?u8 = null,
    cap_info: u16 = 0,
    listen_interval: u16 = 1,
    aid: u16 = 1,
    gtk: []const u8 = &.{},
    gtk_key_id: u8 = 0,
    gtk_rsc: [rsc_len]u8 = @splat(0),
    igtk: []const u8 = &.{},
    igtk_key_id: u16 = 0,
    igtk_ipn: [ipn_len]u8 = @splat(0),
    /// 重关联截止时间（TU）。0 表示没有期限。
    deadline_tu: u32 = 0,
    /// 随第三个消息带上的 RIC-Request、随第四个消息回去的 RIC-Response 的内容（一段不透明的元素串，
    /// 13.11 不在本文件范围）。不请求资源就留空。
    ric_request: []const u8 = &.{},
    ric_response: []const u8 = &.{},
};

fn putList(list: []const u8) ConfigError![rsne.max_akm]u8 {
    if (list.len > rsne.max_akm) return error.ListTooLong;
    var out: [rsne.max_akm]u8 = @splat(rsne.unknown);
    for (list, 0..) |v, i| out[i] = v;
    return out;
}

fn staConfigOf(comptime akm: ft.Akm, comptime pairwise: u8, s: *const Setup, pmk_r0: ft.PmkR0(akm)) ConfigError!StaConfig(akm) {
    var r = rsne.Rsne{
        .group = s.group,
        .pairwise = try putList(&.{pairwise}),
        .pairwise_len = 1,
        .akm = try putList(&.{@backingInt(akm)}),
        .akm_len = 1,
        .caps = s.sta_caps,
        .caps_present = true,
    };
    if (s.sta_gmcs) |g| {
        r.gmcs = g;
        r.gmcs_present = true;
    }
    return .{
        .own_addr = s.sta_addr,
        .target_ap = s.target_ap,
        .current_ap = s.current_ap,
        .mdid = s.mdid,
        .target_ft_cap = s.ft_cap,
        .r0kh_id = s.r0kh_id,
        .pmk_r0 = pmk_r0,
        .rsne = r,
        .ssid = s.ssid,
        .cap_info = s.cap_info,
        .listen_interval = s.listen_interval,
        .deadline_tu = s.deadline_tu,
    };
}

fn apConfigOf(s: *const Setup) ConfigError!ApConfig {
    if (s.ap_akms.len == 0 or s.ap_akms.len > rsne.max_akm or s.ap_pairwise.len == 0 or s.ap_pairwise.len > rsne.max_pairwise) {
        return error.ListTooLong;
    }
    var r = rsne.Rsne{
        .group = s.group,
        .pairwise = try putList(s.ap_pairwise),
        .pairwise_len = @intCast(s.ap_pairwise.len),
        .akm = try putList(s.ap_akms),
        .akm_len = @intCast(s.ap_akms.len),
        .caps = s.ap_caps,
        .caps_present = true,
    };
    if (s.gmcs) |g| {
        r.gmcs = g;
        r.gmcs_present = true;
    }
    return .{
        .bssid = s.target_ap,
        .mdid = s.mdid,
        .ft_cap = s.ft_cap,
        .r0kh_id = s.r0kh_id,
        .r1kh_id = s.r1kh_id,
        .rsne = r,
        .cap_info = s.cap_info,
        .aid = s.aid,
        .gtk = s.gtk,
        .gtk_key_id = s.gtk_key_id,
        .gtk_rsc = s.gtk_rsc,
        .igtk = s.igtk,
        .igtk_key_id = s.igtk_key_id,
        .igtk_ipn = s.igtk_ipn,
        .deadline_tu = s.deadline_tu,
    };
}

/// 实验室：按一份 `Setup` 派生 PMK-R0（S0KH 与 R0KH 的那一份），并保证 FTO、目标 AP 两份配置
/// 都成立。主机测试与板侧自检用它在进程内让三个角色对拍。
pub fn Lab(comptime akm: ft.Akm, comptime pairwise: u8) type {
    comptime supportedAkm(akm);
    comptime {
        _ = tkLen(pairwise);
    }
    return struct {
        const Self = @This();

        pub const StaT = Sta(akm, pairwise);
        pub const ApT = Ap(akm, pairwise);
        pub const R0khT = R0kh(akm);

        pub const InitError = ft.XxKeyError || ft.DeriveError || ConfigError;

        setup: Setup,
        pmk_r0: ft.PmkR0(akm),

        pub fn init(setup: Setup) InitError!Self {
            const xx = try ft.xxkey(akm, setup.root);
            const pmk_r0 = try ft.derivePmkR0(akm, xx, .{
                .ssid = setup.ssid,
                .mdid = setup.mdid,
                .r0kh_id = setup.r0kh_id,
                .s0kh_id = setup.sta_addr,
            });
            _ = try StaT.init(try staConfigOf(akm, pairwise, &setup, pmk_r0));
            _ = try ApT.init(try apConfigOf(&setup));
            return .{ .setup = setup, .pmk_r0 = pmk_r0 };
        }

        pub fn staConfig(self: *const Self) StaConfig(akm) {
            return staConfigOf(akm, pairwise, &self.setup, self.pmk_r0) catch unreachable;
        }

        pub fn apConfig(self: *const Self) ApConfig {
            return apConfigOf(&self.setup) catch unreachable;
        }

        /// 新的 FTO 状态机实例。
        pub fn newSta(self: *const Self) StaT {
            return StaT.init(self.staConfig()) catch unreachable;
        }

        /// 新的目标 AP 状态机实例（一个 FTO 的一次转换）。
        pub fn newAp(self: *const Self) ApT {
            return ApT.init(self.apConfig()) catch unreachable;
        }

        /// R0KH：为这个 STA 持有 PMK-R0，并把初始关联时协商的成对密码套件记在 PMK-R1 SA 里。
        pub fn r0kh(self: *const Self) R0khT {
            return .{ .sta = self.setup.sta_addr, .pmk_r0 = self.pmk_r0, .pairwise = pairwise };
        }
    };
}
