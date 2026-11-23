//! ble-security：LE 配对状态机（发起端与响应端，LE legacy 与 LE Secure Connections）。
//!
//! 出处：Bluetooth Core Specification 5.4 [Vol 3] Part H：
//!   * 2.3 / 2.3.5.1     三个阶段；Table 2.6 / 2.7 / 2.8 的方法选择
//!   * 2.3.4             密钥长度：取两端最大值的较小者，短于本机最小值则失败；掩码
//!   * 2.3.5.2–2.3.5.4   legacy 的 Just Works（TK = 0）、Passkey Entry（TK = 口令）、OOB（TK 经 OOB）
//!   * 2.3.5.5           legacy 阶段 2：LP_CONFIRM_I/R、LP_RAND_I/R、STK = s1(TK, R, I)
//!   * 2.3.5.6.1         公钥交换、公钥合法性、X 坐标相同、调试公钥
//!   * 2.3.5.6.2–2.3.5.6.5  SC 阶段 1（Just Works / Numeric Comparison / Passkey 逐位 /
//!                      OOB）与阶段 2（f5 求 MacKey、LTK，f6 求 Ea、Eb）
//!   * 2.3.6             Repeated Attempts
//!   * 2.4 / 2.4.3       Central 发起、Peripheral 响应；阶段 3 的分发顺序与生效条件
//!   * 3.3–3.6           命令、30 s 计时器、Pairing Failed 的原因码、密钥分发命令
//!   * 附录 C            各成功/失败场景的消息序列（C.2、C.3、C.5）
//!
//! 用法：一个 `Pairer` 只管一条链路上的一次配对。
//!   发起端：`start()` → `nextOut()` 取出要发的命令；
//!   两端：收到 SMP 命令调 `onPdu()`，再调 `nextOut()` 直到返回 null，并周期性调
//!   `nextEvent()` 取上层要做的事（显示/输入口令、数值比较、启动加密、完成、失败）。
//!   链路加密后调 `onLinkEncrypted()`，阶段 3 才开始。
//!
//! 随机数来自调用方给种子的 `rand.Stream`；本文件不碰硬件、不分配内存。

const std = @import("std");

const bond = @import("bond.zig");
const ecc = @import("ecc.zig");
const pdu = @import("pdu.zig");
const rand = @import("rand.zig");
const toolbox = @import("toolbox.zig");

pub const Role = enum { initiator, responder };

/// 3.5.1 Table 3.4。
pub const IoCap = enum(u8) {
    display_only = 0x00,
    display_yes_no = 0x01,
    keyboard_only = 0x02,
    no_input_no_output = 0x03,
    keyboard_display = 0x04,
};

/// 3.5.1 Table 3.6。10、11 保留，收到时按 No Bonding 处理。
pub const Bonding = enum(u2) {
    no_bonding = 0b00,
    bonding = 0b01,
};

/// 3.5.1 Figure 3.3（位序已对照官方插图）。
pub const AuthReq = packed struct(u8) {
    bonding: Bonding = .no_bonding,
    mitm: u1 = 0,
    sc: u1 = 0,
    keypress: u1 = 0,
    ct2: u1 = 0,
    _reserved: u2 = 0,

    pub fn byte(self: AuthReq) u8 {
        return @bitCast(self);
    }

    /// 保留位忽略；Bonding_Flags 不是 01 的一律当作 No Bonding。
    pub fn fromByte(b: u8) AuthReq {
        var out: AuthReq = @bitCast(b);
        if (out.bonding != .bonding) out.bonding = .no_bonding;
        out._reserved = 0;
        return out;
    }
};

/// 3.6.1 Figure 3.11（位序已对照官方插图）。LinkKey 是 BR/EDR 跨传输派生，本组件
/// 不支持：本机永不觉置位，收到后忽略。
pub const KeyDist = packed struct(u8) {
    enc_key: u1 = 0,
    id_key: u1 = 0,
    sign_key: u1 = 0,
    link_key: u1 = 0,
    _reserved: u4 = 0,

    pub fn byte(self: KeyDist) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(b: u8) KeyDist {
        return @bitCast(b);
    }

    pub fn and_(a: KeyDist, b: KeyDist) KeyDist {
        return fromByte(a.byte() & b.byte());
    }

    pub fn isEmpty(self: KeyDist) bool {
        return (self.byte() & 0x0F) == 0;
    }

    /// 除了 EncKey/IdKey/SignKey/LinkKey 之外的位是否被置位。
    pub fn hasReserved(self: KeyDist) bool {
        return (self.byte() & 0xF0) != 0;
    }
};

/// 3.5.5 Table 3.7。
pub const FailReason = enum(u8) {
    passkey_entry_failed = 0x01,
    oob_not_available = 0x02,
    authentication_requirements = 0x03,
    confirm_value_failed = 0x04,
    pairing_not_supported = 0x05,
    encryption_key_size = 0x06,
    command_not_supported = 0x07,
    unspecified_reason = 0x08,
    repeated_attempts = 0x09,
    invalid_parameters = 0x0A,
    dhkey_check_failed = 0x0B,
    numeric_comparison_failed = 0x0C,
    br_edr_pairing_in_progress = 0x0D,
    ctkd_not_allowed = 0x0E,
    key_rejected = 0x0F,

    pub fn name(self: FailReason) []const u8 {
        return switch (self) {
            .passkey_entry_failed => "Passkey Entry Failed",
            .oob_not_available => "OOB Not Available",
            .authentication_requirements => "Authentication Requirements",
            .confirm_value_failed => "Confirm Value Failed",
            .pairing_not_supported => "Pairing Not Supported",
            .encryption_key_size => "Encryption Key Size",
            .command_not_supported => "Command Not Supported",
            .unspecified_reason => "Unspecified Reason",
            .repeated_attempts => "Repeated Attempts",
            .invalid_parameters => "Invalid Parameters",
            .dhkey_check_failed => "DHKey Check Failed",
            .numeric_comparison_failed => "Numeric Comparison Failed",
            .br_edr_pairing_in_progress => "BR/EDR pairing in progress",
            .ctkd_not_allowed => "Cross-transport Key Derivation/Generation not allowed",
            .key_rejected => "Key Rejected",
        };
    }
};

/// 3.4：Security Manager Timer 到 30 s 即失败。
pub const timeout_ms: u32 = 30_000;

pub const Method = enum { just_works, passkey, numeric_comparison, out_of_band };

/// Passkey Entry 里本机是显示方还是输入方。
pub const PasskeySide = enum { none, displays, inputs };

pub const Selection = struct {
    method: Method,
    passkey_side: PasskeySide = .none,
    /// 该方法配出的密钥是否提供 MITM 保护（2.3.5.1 末尾三段）。
    authenticated: bool,
};

/// Table 2.8：行是发起端 IO 能力，列是响应端 IO 能力。
const Cell = enum {
    just_works,
    pk_responder_displays,
    pk_initiator_displays,
    pk_both_input,
    /// legacy 配对是 Just Works，Secure Connections 是 Numeric Comparison。
    nc_or_just_works,
    /// legacy 配对是 Passkey Entry（响应端显示），Secure Connections 是 Numeric Comparison。
    pk_r_disp_or_nc,
    /// legacy 配对是 Passkey Entry（发起端显示），Secure Connections 是 Numeric Comparison。
    pk_i_disp_or_nc,
};

const io_table: [5][5]Cell = .{
    //                         R: DisplayOnly        DisplayYesNo          KeyboardOnly     NoInputNoOutput  KeyboardDisplay
    .{ .just_works, .just_works, .pk_responder_displays, .just_works, .pk_responder_displays }, // I: DisplayOnly
    .{ .just_works, .nc_or_just_works, .pk_responder_displays, .just_works, .pk_r_disp_or_nc }, // I: DisplayYesNo
    .{ .pk_initiator_displays, .pk_initiator_displays, .pk_both_input, .just_works, .pk_initiator_displays }, // I: KeyboardOnly
    .{ .just_works, .just_works, .just_works, .just_works, .just_works }, // I: NoInputNoOutput
    .{ .pk_initiator_displays, .pk_i_disp_or_nc, .pk_responder_displays, .just_works, .pk_i_disp_or_nc }, // I: KeyboardDisplay
};

/// 2.3.5.1（Table 2.6、2.7、2.8）。
pub fn selectMethod(
    sc: bool,
    role: Role,
    initiator_oob: bool,
    responder_oob: bool,
    initiator_mitm: bool,
    responder_mitm: bool,
    initiator_io: IoCap,
    responder_io: IoCap,
    /// OOB 机制是否已知可抗窃听；否则 OOB 配出的密钥算 Unauthenticated。
    oob_secure: bool,
) Selection {
    const use_oob = if (sc) (initiator_oob or responder_oob) else (initiator_oob and responder_oob);
    var out = Selection{ .method = .just_works, .authenticated = false };
    if (use_oob) {
        out.method = .out_of_band;
        out.authenticated = oob_secure;
        return out;
    }
    if (initiator_mitm or responder_mitm) {
        const cell = io_table[@backingInt(initiator_io)][@backingInt(responder_io)];
        switch (cell) {
            .just_works => {},
            .nc_or_just_works => if (sc) {
                out.method = .numeric_comparison;
                out.authenticated = true;
            },
            .pk_responder_displays => {
                out.method = .passkey;
                out.authenticated = true;
                out.passkey_side = if (role == .initiator) .inputs else .displays;
            },
            .pk_initiator_displays => {
                out.method = .passkey;
                out.authenticated = true;
                out.passkey_side = if (role == .initiator) .displays else .inputs;
            },
            .pk_both_input => {
                out.method = .passkey;
                out.authenticated = true;
                out.passkey_side = .inputs;
            },
            .pk_r_disp_or_nc => {
                if (sc) {
                    out.method = .numeric_comparison;
                    out.authenticated = true;
                } else {
                    out.method = .passkey;
                    out.authenticated = true;
                    out.passkey_side = if (role == .initiator) .inputs else .displays;
                }
            },
            .pk_i_disp_or_nc => {
                if (sc) {
                    out.method = .numeric_comparison;
                    out.authenticated = true;
                } else {
                    out.method = .passkey;
                    out.authenticated = true;
                    out.passkey_side = if (role == .initiator) .displays else .inputs;
                }
            },
        }
    }
    return out;
}

/// 2.3.6 Repeated Attempts：失败后必须等待，且逐次指数增长；长期无失败则回落到
/// 最小值。具体数值是本实现的选择（规范只给形式）。
pub const Attempts = struct {
    pub const base_wait_ms: u32 = 1_000;
    pub const max_shift: u5 = 6;
    pub const decay_ms: u32 = 30_000;

    failures: u32 = 0,
    last_fail_ms: u32 = 0,

    pub fn recordFailure(self: *Attempts, now_ms: u32) void {
        self.failures +%= 1;
        self.last_fail_ms = now_ms;
    }

    pub fn recordSuccess(self: *Attempts) void {
        self.failures = 0;
    }

    /// 当前仍需等待的毫秒数：base << (失败次数 − 1 − 回落次数)。
    pub fn waitMs(self: *const Attempts, now_ms: u32) u32 {
        if (self.failures == 0) return 0;
        const elapsed = now_ms -% self.last_fail_ms;
        const halvings = elapsed / decay_ms;
        const level: u32 = if (halvings >= self.failures) 0 else self.failures - 1 - halvings;
        const shift: u5 = @intCast(@min(level, max_shift));
        return base_wait_ms << shift;
    }

    pub fn allowed(self: *const Attempts, now_ms: u32) bool {
        if (self.failures == 0) return true;
        return (now_ms -% self.last_fail_ms) >= self.waitMs(now_ms);
    }
};

/// 对端经 OOB 通道发来的数据。legacy 只用到 `tk`；Secure Connections 用 `r` 与
/// `confirm`（2.3.5.6.4：C = f4(PK, PK, r, 0)）。
pub const OobData = struct {
    tk: toolbox.Key = @splat(0),
    r: toolbox.Key = @splat(0),
    confirm: toolbox.Key = @splat(0),
};

/// 本机要分发的密钥（阶段 3）。LTK 的长度必须不超过协商出的密钥长度，分发前会
/// 再掩码一次（2.3.4）。
pub const LocalKeys = struct {
    ltk: toolbox.Key = @splat(0),
    ediv: u16 = 0,
    rand: u64 = 0,
    irk: toolbox.Key = @splat(0),
    csrk: toolbox.Key = @splat(0),
    identity: bond.Addr = .{ .type = .public },
};

pub const Config = struct {
    role: Role,
    io_cap: IoCap,
    auth_req: AuthReq,
    /// 希望对端分发哪些密钥。
    request: KeyDist = .{},
    /// 本机愿意分发哪些密钥。
    distribute: KeyDist = .{},
    /// 7..16（2.3.4）。
    min_key_size: u8 = 7,
    max_key_size: u8 = 16,
    /// 本连接建立时使用的地址，c1 / f5 / f6 的输入（2.3.5.5 末尾）。
    local_addr: bond.Addr,
    peer_addr: bond.Addr,
    local_keys: LocalKeys = .{},
    pairing_supported: bool = true,
    /// 本机在 Pairing Request / Response 里宣告「已有对端 OOB 数据」。宣告了却
    /// 没有在阶段 1 前用 `setPeerOob` 提供数据，会以 OOB Not Available 失败
    /// （附录 C.20 / C.21）。
    oob_flag: bool = false,
    oob_secure: bool = false,
    /// 2.3.5.6.1：处于可接受调试公钥的模式时置位。
    accept_debug_key: bool = false,
    /// 设了就按 2.3.6 限制重试节奏。
    attempts: ?*Attempts = null,
};

pub const Error = error{
    /// 角色不对（例如响应端调 `start()`）。
    WrongRole,
    /// 已有配对在进行中。
    Busy,
    /// 3.4：超时后本链路上不能再配对，要先 `newLink()`。
    LinkRequired,
    /// `min_key_size`/`max_key_size` 不在 7..16，或最小值大于最大值。
    BadConfig,
    /// 2.3.6：间隔太短，不允许新的尝试。
    RepeatedAttempts,
    /// 当前没有进行中的配对，命令被忽略。
    NotPairing,
    /// 保留码或与本流程无关的命令，按 3.3 忽略。
    Ignored,
    /// 命令长度/字段非法；已排队 Pairing Failed Invalid Parameters。
    Malformed,
    /// 命令与当前步骤不符；已排队 Pairing Failed Unspecified Reason。
    Unexpected,
    /// `providePasskey`、`onLinkEncrypted` 等被在错误的时机调用。
    WrongState,
    InvalidPasskey,
};

pub const Failure = union(enum) {
    /// 收到或发出的 Pairing Failed 原因码（Table 3.7）。
    reason: u8,
    /// 3.4 的 30 s 计时器到期。
    timeout,
};

pub const Event = union(enum) {
    /// 请上层显示 6 位 passkey（含前导 0）。
    passkey_display: u32,
    /// 请上层让用户输入 6 位 passkey，然后调 `providePasskey` 或 `passkeyEntryFailed`。
    passkey_input,
    /// Numeric Comparison：请上层显示 6 位数值并让用户确认，然后调
    /// `numericComparisonReply`（附录 C.2.2.2.1）。
    numeric_comparison: u32,
    /// STK（legacy）或 LTK（Secure Connections）已生成。发起端据此启动链路加密；
    /// 响应端把它交给控制器，等链路加密完成后调 `onLinkEncrypted`。
    keys_ready,
    /// 阶段 3 结束，配对完成。
    complete,
    failed: Failure,
};

/// 阶段 3 从对端收到的密钥。没有分发的那几项保持零值、`has_*` 为 false。
pub const PeerKeys = struct {
    ltk: toolbox.Key = @splat(0),
    has_ltk: bool = false,
    ediv: u16 = 0,
    rand: u64 = 0,
    irk: toolbox.Key = @splat(0),
    /// 3.6.4：全零 IRK 表示对端没有可用的可解析私有地址。
    has_irk: bool = false,
    identity: bond.Addr = .{ .type = .public },
    has_identity: bool = false,
    csrk: toolbox.Key = @splat(0),
    has_csrk: bool = false,
};

pub const State = enum {
    idle,
    wait_pairing_response,
    /// 等上层提供 passkey；`resume_state` 记着回到哪一步。
    wait_passkey,
    /// 等上层回答数值比较。
    wait_nc_confirm,

    lg_stage1_i,
    lg_wait_confirm_r,
    lg_wait_srand,
    lg_wait_confirm_i,
    lg_send_confirm_r,
    lg_wait_mrand,

    sc_wait_pk,
    sc_send_pk,
    sc_stage1,
    sc_send_confirm_b,
    sc_wait_confirm_b,
    sc_send_nonce_a,
    sc_wait_nonce_a,
    sc_wait_nonce_b,
    sc_pk_send_confirm_a,
    sc_pk_wait_confirm_b,
    sc_pk_wait_nonce_b,
    sc_pk_prep_b,
    sc_pk_wait_confirm_a,
    sc_pk_send_confirm_b,
    sc_pk_wait_nonce_a,
    sc_send_check_a,
    sc_wait_check_b,
    sc_wait_check_a,

    wait_encrypt,
    distribute,
    complete,
    failed,
};

/// 阶段 3 每一侧分发密钥的顺序（3.6.1）。
const Item = enum(u8) { none, ltk, ediv_rand, irk, identity, csrk };

fn pushItem(items: *[5]Item, n: *u8, item: Item) void {
    items[n.*] = item;
    n.* += 1;
}

/// 3.6.1：EncKey → LTK、EDIV+Rand（Secure Connections 时 EncKey 被忽略）；IdKey →
/// IRK、地址；SignKey → CSRK。
fn buildItems(items: *[5]Item, n: *u8, dist: KeyDist, sc: bool) void {
    items.* = @splat(.none);
    n.* = 0;
    if (!sc and dist.enc_key == 1) {
        pushItem(items, n, .ltk);
        pushItem(items, n, .ediv_rand);
    }
    if (dist.id_key == 1) {
        pushItem(items, n, .irk);
        pushItem(items, n, .identity);
    }
    if (dist.sign_key == 1) pushItem(items, n, .csrk);
}

fn addr7(a: bond.Addr) [7]u8 {
    return .{
        @backingInt(a.type), a.val[5], a.val[4], a.val[3], a.val[2], a.val[1], a.val[0],
    };
}

fn passkeyBits(passkey: u32) toolbox.Key {
    var out: toolbox.Key = @splat(0);
    std.mem.writeInt(u32, out[12..16], passkey, .big);
    return out;
}

fn allZero(k: toolbox.Key) bool {
    return std.mem.allEqual(u8, &k, 0);
}

fn sameKey(a: toolbox.Key, b: toolbox.Key) bool {
    return std.mem.eql(u8, &a, &b);
}

pub const Pairer = struct {
    cfg: Config,
    rng: rand.Stream,

    state: State = .idle,
    resume_state: State = .idle,
    /// SC OOB：响应端要到收到 Na 才回 Pairing Failed（附录 C.18、C.21）。
    pending_fail: ?FailReason = null,
    link_dead: bool = false,
    timer_on: bool = false,
    last_ms: u32 = 0,
    fail_code: u8 = 0,

    preq: [7]u8 = @splat(0),
    pres: [7]u8 = @splat(0),
    peer_oob_flag: bool = false,
    method: Method = .just_works,
    passkey_side: PasskeySide = .none,
    authenticated: bool = false,
    key_size: u8 = 16,
    init_dist: KeyDist = .{},
    resp_dist: KeyDist = .{},
    bonding: bool = false,
    sc: bool = false,
    passkey: u32 = 0,
    passkey_set: bool = false,

    tk: toolbox.Key = @splat(0),
    rand_i: toolbox.Key = @splat(0),
    rand_r: toolbox.Key = @splat(0),
    confirm_i: toolbox.Key = @splat(0),
    confirm_r: toolbox.Key = @splat(0),
    sk: ecc.Priv = @splat(0),
    pk_local: ecc.Pub = .{ .x = @splat(0), .y = @splat(0) },
    pk_peer: ecc.Pub = .{ .x = @splat(0), .y = @splat(0) },
    dhkey: [ecc.coord_len]u8 = @splat(0),
    nonce_a: toolbox.Key = @splat(0),
    nonce_b: toolbox.Key = @splat(0),
    r_a: toolbox.Key = @splat(0),
    r_b: toolbox.Key = @splat(0),
    round: u8 = 0,
    nc_value: u32 = 0,
    oob_local_r: toolbox.Key = @splat(0),
    oob_peer: ?OobData = null,
    mac_key: toolbox.Key = @splat(0),
    link_key: toolbox.Key = @splat(0),

    send_items: [5]Item = @splat(.none),
    send_n: u8 = 0,
    send_step: u8 = 0,
    recv_items: [5]Item = @splat(.none),
    recv_n: u8 = 0,
    recv_step: u8 = 0,
    peer_keys: PeerKeys = .{},
    bond_cache: ?bond.Bond = null,

    out_buf: [pdu.max_len]u8 = undefined,
    out_len: u8 = 0,
    events: [8]Event = undefined,
    ev_head: u3 = 0,
    ev_tail: u3 = 0,

    /// 事件环最多存 8 条；满了丢最旧的。
    fn pushEvent(self: *Pairer, ev: Event) void {
        self.events[self.ev_tail] = ev;
        self.ev_tail +%= 1;
        if (self.ev_tail == self.ev_head) self.ev_head +%= 1;
    }

    pub fn init(cfg: Config, seed: [rand.seed_len]u8) Error!Pairer {
        if (cfg.min_key_size < 7 or cfg.min_key_size > 16 or
            cfg.max_key_size < 7 or cfg.max_key_size > 16 or
            cfg.min_key_size > cfg.max_key_size) return error.BadConfig;
        if (!cfg.local_keys.identity.isIdentity()) return error.BadConfig;
        return .{ .cfg = cfg, .rng = rand.Stream.init(seed) };
    }

    fn touch(self: *Pairer, now_ms: u32) void {
        self.last_ms = now_ms;
        self.timer_on = true;
    }

    fn emit(self: *Pairer, p: pdu.Pdu) void {
        self.out_len = @intCast(pdu.encode(p, &self.out_buf) catch unreachable);
    }

    fn fail(self: *Pairer, reason: FailReason, notify_peer: bool) void {
        self.out_len = 0;
        self.state = .failed;
        self.fail_code = @backingInt(reason);
        self.timer_on = false;
        self.pending_fail = null;
        self.wipeSecrets();
        if (notify_peer) self.emit(.{ .pairing_failed = self.fail_code });
        self.pushEvent(.{ .failed = .{ .reason = self.fail_code } });
        if (self.cfg.attempts) |a| a.recordFailure(self.last_ms);
    }

    fn failReceived(self: *Pairer, reason: u8) void {
        self.out_len = 0;
        self.state = .failed;
        self.fail_code = reason;
        self.timer_on = false;
        self.pending_fail = null;
        self.wipeSecrets();
        self.pushEvent(.{ .failed = .{ .reason = reason } });
        if (self.cfg.attempts) |a| a.recordFailure(self.last_ms);
    }

    fn wipeSecrets(self: *Pairer) void {
        @memset(&self.tk, 0);
        @memset(&self.sk, 0);
        @memset(&self.dhkey, 0);
        @memset(&self.mac_key, 0);
        @memset(&self.link_key, 0);
        @memset(&self.rand_i, 0);
        @memset(&self.rand_r, 0);
    }

    fn unexpected(self: *Pairer) Error {
        self.fail(.unspecified_reason, true);
        return error.Unexpected;
    }

    /// 新的一次配对：清掉上一轮的过程量，配置与随机流保留。
    fn resetProcedure(self: *Pairer) void {
        self.resume_state = .idle;
        self.pending_fail = null;
        self.method = .just_works;
        self.passkey_side = .none;
        self.authenticated = false;
        self.passkey = 0;
        self.passkey_set = false;
        self.round = 0;
        self.nc_value = 0;
        self.bond_cache = null;
        self.peer_keys = .{};
        self.send_n = 0;
        self.send_step = 0;
        self.recv_n = 0;
        self.recv_step = 0;
        self.out_len = 0;
        self.ev_head = self.ev_tail;
    }

    /// 3.4：超时之后只有建立了新的物理链路才能再配对。
    pub fn newLink(self: *Pairer) void {
        self.link_dead = false;
        self.state = .idle;
        self.timer_on = false;
        self.wipeSecrets();
        self.out_len = 0;
        self.ev_head = self.ev_tail;
    }

    fn isActive(self: *const Pairer) bool {
        return switch (self.state) {
            .idle, .complete, .failed => false,
            else => true,
        };
    }

    // -----------------------------------------------------------------------
    // 发起端入口
    // -----------------------------------------------------------------------

    /// 发起端：开始配对，产生 Pairing Request。之后用 `nextOut` 取出。
    pub fn start(self: *Pairer, now_ms: u32) Error!void {
        if (self.cfg.role != .initiator) return error.WrongRole;
        if (self.link_dead) return error.LinkRequired;
        if (self.isActive()) return error.Busy;
        self.resetProcedure();
        self.touch(now_ms);
        if (self.cfg.attempts) |a| {
            if (!a.allowed(now_ms)) {
                self.fail(.repeated_attempts, false);
                return error.RepeatedAttempts;
            }
        }
        self.preq = .{
            @backingInt(pdu.Code.pairing_request),
            @backingInt(self.cfg.io_cap),
            @intFromBool(self.cfg.oob_flag),
            self.cfg.auth_req.byte(),
            self.cfg.max_key_size,
            self.cfg.distribute.byte(),
            self.cfg.request.byte(),
        };
        self.emit(.{ .pairing_request = featureBytes(&self.preq) });
        self.state = .wait_pairing_response;
    }

    // -----------------------------------------------------------------------
    // 输出与事件
    // -----------------------------------------------------------------------

    /// 取出下一条要发给对端的 SMP 命令；没有就返回 null。状态机里凡是「该发
    /// 什么了」的步骤都在这里推进，所以每收到一条命令后要反复调用直到 null。
    pub fn nextOut(self: *Pairer, out: []u8) ?usize {
        self.pump();
        if (self.out_len == 0) return null;
        if (out.len < self.out_len) return null;
        @memcpy(out[0..self.out_len], self.out_buf[0..self.out_len]);
        const n: usize = self.out_len;
        self.out_len = 0;
        // 交出一条之后状态机往往还能往前走（例如响应端发完公钥就要选 nonce），
        // 在这里推进一步，调用方看到的 state 才是真正在等什么。
        self.pump();
        return n;
    }

    pub fn nextEvent(self: *Pairer) ?Event {
        if (self.ev_head == self.ev_tail) return null;
        const ev = self.events[self.ev_head];
        self.ev_head +%= 1;
        return ev;
    }

    /// 3.4：每个 tick 调一次。返回 true 表示这次刚判定超时。
    pub fn onTick(self: *Pairer, now_ms: u32) bool {
        if (!self.timer_on) return false;
        if (now_ms -% self.last_ms < timeout_ms) return false;
        self.out_len = 0;
        self.state = .failed;
        self.timer_on = false;
        self.link_dead = true;
        self.wipeSecrets();
        self.pushEvent(.{ .failed = .timeout });
        return true;
    }

    // -----------------------------------------------------------------------
    // 上层的动作
    // -----------------------------------------------------------------------

    /// 提供对端经 OOB 通道发来的数据。legacy 用 `tk`，Secure Connections 用 `r` 与
    /// `confirm`。本机自己的 OOB 数据用 `localOob` 取。
    pub fn setPeerOob(self: *Pairer, data: OobData) void {
        self.oob_peer = data;
    }

    /// 本机经 OOB 通道发给对端的数据（Secure Connections；公钥对生成后才有意义）。
    pub fn localOob(self: *const Pairer) OobData {
        return .{
            .r = self.oob_local_r,
            .confirm = toolbox.f4(self.pk_local.x, self.pk_local.x, self.oob_local_r, 0),
        };
    }

    /// 用户输入了 passkey（000000..999999）。在 `passkey_input` 事件之后的任何时刻都可以
    /// 调用；状态机若正停在等它，就地继续。
    pub fn providePasskey(self: *Pairer, passkey: u32) Error!void {
        if (passkey > 999_999) return error.InvalidPasskey;
        if (!self.isActive()) return error.WrongState;
        self.passkey = passkey;
        self.passkey_set = true;
        if (self.state == .wait_passkey) self.state = self.resume_state;
        self.pump();
    }

    /// 2.3.5.3：用户取消或没输入 → Pairing Failed Passkey Entry Failed。
    pub fn passkeyEntryFailed(self: *Pairer) Error!void {
        if (self.state != .wait_passkey) return error.WrongState;
        self.fail(.passkey_entry_failed, true);
    }

    /// Numeric Comparison：用户确认两个 6 位数值是否一致。不一致 →
    /// Pairing Failed Numeric Comparison Failed（附录 C.2.2.2.3、C.2.2.2.4）。
    pub fn numericComparisonReply(self: *Pairer, matches: bool) Error!void {
        if (self.state != .wait_nc_confirm) return error.WrongState;
        if (!matches) {
            self.fail(.numeric_comparison_failed, true);
            return;
        }
        self.state = self.resume_state;
        self.pump();
    }

    /// 3.6.1：上层拒绝刚收到的那把密钥。
    pub fn rejectDistributedKey(self: *Pairer) Error!void {
        if (self.state != .distribute) return error.WrongState;
        self.fail(.key_rejected, true);
    }

    /// 链路已用 STK / LTK 加密（或重新加密）。只有到这一步阶段 3 才开始（2.1）。
    pub fn onLinkEncrypted(self: *Pairer) Error!void {
        if (self.state != .wait_encrypt) return error.WrongState;
        if (self.cfg.role == .responder) {
            buildItems(&self.send_items, &self.send_n, self.resp_dist, self.sc);
            buildItems(&self.recv_items, &self.recv_n, self.init_dist, self.sc);
        } else {
            buildItems(&self.send_items, &self.send_n, self.init_dist, self.sc);
            buildItems(&self.recv_items, &self.recv_n, self.resp_dist, self.sc);
        }
        self.send_step = 0;
        self.recv_step = 0;
        self.state = .distribute;
    }

    // -----------------------------------------------------------------------
    // 结果
    // -----------------------------------------------------------------------

    pub fn ltk(self: *const Pairer) toolbox.Key {
        return self.link_key;
    }

    pub fn keySize(self: *const Pairer) u8 {
        return self.key_size;
    }

    pub fn peerKeys(self: *const Pairer) PeerKeys {
        return self.peer_keys;
    }

    pub fn failureCode(self: *const Pairer) u8 {
        return self.fail_code;
    }

    /// 配对完成且双方 Bonding_Flags 都是 Bonding 时得到的绑定信息；对端 identity
    /// 必须已知（随 IRK 分发，或连接时用的就是 public / static random 地址）。
    pub fn takeBond(self: *Pairer) ?bond.Bond {
        const b = self.bond_cache;
        self.bond_cache = null;
        return b;
    }

    // -----------------------------------------------------------------------
    // 收到的命令
    // -----------------------------------------------------------------------

    /// 处理一条收到的 SMP 命令，然后把状态机推进到下一个要等外界的步骤；所以回来后
    /// `nextOut` 可能已经有命令可发。
    pub fn onPdu(self: *Pairer, bytes: []const u8, now_ms: u32) Error!void {
        try self.onPduInner(bytes, now_ms);
        self.pump();
    }

    fn onPduInner(self: *Pairer, bytes: []const u8, now_ms: u32) Error!void {
        if (self.link_dead) return error.LinkRequired;
        const p = pdu.decode(bytes) catch |err| switch (err) {
            error.UnknownCode => return error.Ignored,
            else => {
                if (!self.cfg.pairing_supported) {
                    self.emit(.{ .pairing_failed = @backingInt(FailReason.pairing_not_supported) });
                    return error.NotPairing;
                }
                // 2.3：收到参数非法的命令回 Invalid Parameters。空闲时只对残缺的
                // Pairing Request 这么做（它是唯一能凭空开始配对的命令）。
                const is_request = bytes.len > 0 and bytes[0] == @backingInt(pdu.Code.pairing_request);
                if (self.isActive() or (is_request and self.cfg.role == .responder)) {
                    self.fail(.invalid_parameters, true);
                    return error.Malformed;
                }
                return error.NotPairing;
            },
        };

        // 3.3：不支持配对的设备对任何命令都回 Pairing Not Supported。
        if (!self.cfg.pairing_supported) {
            self.emit(.{ .pairing_failed = @backingInt(FailReason.pairing_not_supported) });
            return error.NotPairing;
        }

        if (p == .pairing_request and self.cfg.role == .responder and !self.isActive()) {
            return self.onPairingRequest(p.pairing_request, now_ms);
        }
        if (!self.isActive()) return error.NotPairing;

        self.touch(now_ms);
        switch (p) {
            // 3.5.5：对端终止，本端不再回任何命令。
            .pairing_failed => |reason| {
                self.failReceived(reason);
                return;
            },
            // 3.4：Keypress Notification 到达时重置计时器，其余无动作。
            .keypress_notification => return,
            else => {},
        }

        switch (self.state) {
            .wait_pairing_response => switch (p) {
                .pairing_response => |f| return self.onPairingResponse(f),
                else => return self.unexpected(),
            },
            .lg_wait_confirm_i => switch (p) {
                .pairing_confirm => |v| return self.onLegacyConfirmI(v),
                else => return self.unexpected(),
            },
            .lg_wait_confirm_r => switch (p) {
                .pairing_confirm => |v| return self.onLegacyConfirmR(v),
                else => return self.unexpected(),
            },
            .lg_wait_mrand => switch (p) {
                .pairing_random => |v| return self.onLegacyMrand(v),
                else => return self.unexpected(),
            },
            .lg_wait_srand => switch (p) {
                .pairing_random => |v| return self.onLegacySrand(v),
                else => return self.unexpected(),
            },
            .sc_wait_pk => switch (p) {
                .pairing_public_key => |pk| return self.onPeerPublicKey(pk),
                else => return self.unexpected(),
            },
            .sc_wait_confirm_b => switch (p) {
                .pairing_confirm => |v| return self.onConfirmB(v),
                else => return self.unexpected(),
            },
            .sc_wait_nonce_a => switch (p) {
                .pairing_random => |v| return self.onNonceA(v),
                else => return self.unexpected(),
            },
            .sc_wait_nonce_b => switch (p) {
                .pairing_random => |v| return self.onNonceB(v),
                else => return self.unexpected(),
            },
            .sc_pk_wait_confirm_a => switch (p) {
                .pairing_confirm => |v| return self.onPkConfirmA(v),
                else => return self.unexpected(),
            },
            .sc_pk_wait_confirm_b => switch (p) {
                .pairing_confirm => |v| return self.onPkConfirmB(v),
                else => return self.unexpected(),
            },
            .sc_pk_wait_nonce_a => switch (p) {
                .pairing_random => |v| return self.onPkNonceA(v),
                else => return self.unexpected(),
            },
            .sc_pk_wait_nonce_b => switch (p) {
                .pairing_random => |v| return self.onPkNonceB(v),
                else => return self.unexpected(),
            },
            .sc_wait_check_a => switch (p) {
                .pairing_dhkey_check => |v| return self.onCheckA(v),
                else => return self.unexpected(),
            },
            .sc_wait_check_b => switch (p) {
                .pairing_dhkey_check => |v| return self.onCheckB(v),
                else => return self.unexpected(),
            },
            .distribute => return self.onDistribution(p),
            // 等上层（passkey、数值比较）或等链路加密时对端不该再发别的命令。
            .wait_passkey, .wait_nc_confirm, .wait_encrypt => return self.unexpected(),
            .idle, .complete, .failed => unreachable,
            // 这些是「该发了」的步骤，只在 pump 里出现。
            else => return self.unexpected(),
        }
    }

    // -----------------------------------------------------------------------
    // 阶段 1：特征交换
    // -----------------------------------------------------------------------

    fn onPairingRequest(self: *Pairer, f: pdu.Features, now_ms: u32) Error!void {
        self.resetProcedure();
        self.touch(now_ms);
        if (self.cfg.attempts) |a| {
            if (!a.allowed(now_ms)) {
                self.fail(.repeated_attempts, true);
                return error.RepeatedAttempts;
            }
        }
        self.preq = .{
            @backingInt(pdu.Code.pairing_request),
            f.io_cap,
            f.oob,
            f.auth_req,
            f.max_key_size,
            f.initiator_keys,
            f.responder_keys,
        };
        self.peer_oob_flag = f.oob == 0x01;
        if (f.io_cap > @backingInt(IoCap.keyboard_display) or f.oob > 0x01 or
            f.max_key_size < 7 or f.max_key_size > 16 or
            KeyDist.fromByte(f.initiator_keys).hasReserved() or
            KeyDist.fromByte(f.responder_keys).hasReserved())
        {
            self.fail(.invalid_parameters, true);
            return error.Malformed;
        }

        const req_auth = AuthReq.fromByte(f.auth_req);
        self.sc = req_auth.sc == 1 and self.cfg.auth_req.sc == 1;
        self.key_size = @min(f.max_key_size, self.cfg.max_key_size);
        if (self.key_size < self.cfg.min_key_size) {
            self.fail(.encryption_key_size, true);
            return error.Malformed;
        }
        // 3.6.1：响应端不得把发起端请求之外的位置 1。
        self.init_dist = KeyDist.fromByte(f.initiator_keys).and_(self.cfg.request);
        self.resp_dist = KeyDist.fromByte(f.responder_keys).and_(self.cfg.distribute);
        self.bonding = req_auth.bonding == .bonding and self.cfg.auth_req.bonding == .bonding;

        if (!self.negotiateMethod()) return error.Malformed;
        if (self.cfg.oob_flag and !self.sc and self.method == .out_of_band and self.oob_peer == null) {
            // 2.3.5.1：legacy 下响应端没有 OOB 数据时可以用 OOB Not Available 代替 Pairing Response。
            self.fail(.oob_not_available, true);
            return error.Malformed;
        }

        self.pres = .{
            @backingInt(pdu.Code.pairing_response),
            @backingInt(self.cfg.io_cap),
            @intFromBool(self.cfg.oob_flag),
            self.cfg.auth_req.byte(),
            self.cfg.max_key_size,
            self.init_dist.byte(),
            self.resp_dist.byte(),
        };
        self.emit(.{ .pairing_response = featureBytes(&self.pres) });

        if (self.sc) {
            self.newKeyPair();
            self.state = .sc_wait_pk;
        } else {
            self.state = .lg_wait_confirm_i;
        }
        self.requestPasskey();
    }

    fn onPairingResponse(self: *Pairer, f: pdu.Features) Error!void {
        self.pres = .{
            @backingInt(pdu.Code.pairing_response),
            f.io_cap,
            f.oob,
            f.auth_req,
            f.max_key_size,
            f.initiator_keys,
            f.responder_keys,
        };
        self.peer_oob_flag = f.oob == 0x01;
        if (f.io_cap > @backingInt(IoCap.keyboard_display) or f.oob > 0x01 or
            f.max_key_size < 7 or f.max_key_size > 16 or
            KeyDist.fromByte(f.initiator_keys).hasReserved() or
            KeyDist.fromByte(f.responder_keys).hasReserved())
        {
            self.fail(.invalid_parameters, true);
            return error.Malformed;
        }

        const req_auth = self.cfg.auth_req;
        const resp_auth = AuthReq.fromByte(f.auth_req);
        self.sc = req_auth.sc == 1 and resp_auth.sc == 1;
        self.key_size = @min(self.cfg.max_key_size, f.max_key_size);
        if (self.key_size < self.cfg.min_key_size) {
            self.fail(.encryption_key_size, true);
            return error.Malformed;
        }
        // 3.6.1：Pairing Response 定义实际分发的密钥，但不得超出 Pairing Request 的请求。
        self.init_dist = KeyDist.fromByte(f.initiator_keys);
        self.resp_dist = KeyDist.fromByte(f.responder_keys);
        if ((self.init_dist.byte() & ~self.cfg.distribute.byte()) != 0 or
            (self.resp_dist.byte() & ~self.cfg.request.byte()) != 0)
        {
            self.fail(.invalid_parameters, true);
            return error.Malformed;
        }
        self.bonding = req_auth.bonding == .bonding and resp_auth.bonding == .bonding;

        if (!self.negotiateMethod()) return error.Malformed;
        if (self.cfg.oob_flag and self.method == .out_of_band and self.oob_peer == null and !self.sc) {
            self.fail(.oob_not_available, true);
            return error.Malformed;
        }

        self.requestPasskey();
        if (self.sc) {
            self.newKeyPair();
            self.state = .sc_send_pk;
        } else {
            self.state = .lg_stage1_i;
        }
    }

    /// 2.3.5.1。失败时已经排好 Pairing Failed，返回 false。
    fn negotiateMethod(self: *Pairer) bool {
        // 响应端自己的特征此时还没写进 pres，直接取本机配置。
        const is_responder = self.cfg.role == .responder;
        const req = AuthReq.fromByte(self.preq[3]);
        const resp: AuthReq = if (is_responder) self.cfg.auth_req else AuthReq.fromByte(self.pres[3]);
        const resp_oob = if (is_responder) self.cfg.oob_flag else self.pres[2] == 0x01;
        const resp_io: IoCap = if (is_responder) self.cfg.io_cap else @fromBackingInt(@intCast(self.pres[1]));
        const sel = selectMethod(
            self.sc,
            self.cfg.role,
            self.preq[2] == 0x01,
            resp_oob,
            req.mitm == 1,
            resp.mitm == 1,
            @fromBackingInt(@intCast(self.preq[1])),
            resp_io,
            self.cfg.oob_secure,
        );
        self.method = sel.method;
        self.passkey_side = sel.passkey_side;
        self.authenticated = sel.authenticated;
        // 本机要求 MITM 而选出的方法提供不了 → Authentication Requirements。
        if (self.cfg.auth_req.mitm == 1 and !sel.authenticated) {
            self.fail(.authentication_requirements, true);
            return false;
        }
        return true;
    }

    /// 发起端地址。
    fn initiatorAddr(self: *const Pairer) bond.Addr {
        return if (self.cfg.role == .initiator) self.cfg.local_addr else self.cfg.peer_addr;
    }

    fn responderAddr(self: *const Pairer) bond.Addr {
        return if (self.cfg.role == .initiator) self.cfg.peer_addr else self.cfg.local_addr;
    }

    fn pkInitiator(self: *const Pairer) ecc.Pub {
        return if (self.cfg.role == .initiator) self.pk_local else self.pk_peer;
    }

    fn pkResponder(self: *const Pairer) ecc.Pub {
        return if (self.cfg.role == .initiator) self.pk_peer else self.pk_local;
    }

    /// 让上层去显示或输入 passkey。显示方自己生成并把事件发给上层。
    fn requestPasskey(self: *Pairer) void {
        if (self.method != .passkey) return;
        if (self.passkey_side == .displays) {
            self.passkey = self.rng.passkey();
            self.passkey_set = true;
            self.pushEvent(.{ .passkey_display = self.passkey });
        } else {
            self.pushEvent(.passkey_input);
        }
    }

    fn newKeyPair(self: *Pairer) void {
        while (true) {
            const sk = self.rng.bytes(ecc.coord_len);
            if (ecc.publicFromPrivate(sk)) |pk| {
                self.sk = sk;
                self.pk_local = pk;
                self.oob_local_r = self.rng.bytes(16);
                return;
            } else |_| {}
        }
    }

    fn computeConfirm(self: *const Pairer, k: toolbox.Key, r: toolbox.Key) toolbox.Key {
        const ia = self.initiatorAddr();
        const ra = self.responderAddr();
        return toolbox.c1(
            k,
            r,
            &self.preq,
            &self.pres,
            @intCast(@backingInt(ia.type)),
            ia.val,
            @intCast(@backingInt(ra.type)),
            ra.val,
        );
    }

    // -----------------------------------------------------------------------
    // 阶段 2：LE legacy
    // -----------------------------------------------------------------------

    fn onLegacyConfirmI(self: *Pairer, v: toolbox.Key) Error!void {
        self.confirm_i = v;
        self.state = .lg_send_confirm_r;
    }

    fn onLegacyConfirmR(self: *Pairer, v: toolbox.Key) Error!void {
        self.confirm_r = v;
        // 2.3.5.5：发起端发的是算 LP_CONFIRM_I 时用的同一个 LP_RAND_I。
        self.emit(.{ .pairing_random = self.rand_i });
        self.state = .lg_wait_srand;
    }

    fn onLegacyMrand(self: *Pairer, v: toolbox.Key) Error!void {
        self.rand_i = v;
        // 2.3.5.5：响应端重算 LP_CONFIRM_I，不一致 → Confirm Value Failed（附录 C.5.6）。
        if (!sameKey(self.computeConfirm(self.tk, v), self.confirm_i)) {
            self.fail(.confirm_value_failed, true);
            return error.Unexpected;
        }
        self.emit(.{ .pairing_random = self.rand_r });
        self.link_key = toolbox.maskKey(toolbox.s1(self.tk, self.rand_r, self.rand_i), self.key_size);
        self.keysReady();
    }

    fn onLegacySrand(self: *Pairer, v: toolbox.Key) Error!void {
        self.rand_r = v;
        // 2.3.5.5：发起端重算 LP_CONFIRM_R（附录 C.5.7）。
        if (!sameKey(self.computeConfirm(self.tk, v), self.confirm_r)) {
            self.fail(.confirm_value_failed, true);
            return error.Unexpected;
        }
        self.link_key = toolbox.maskKey(toolbox.s1(self.tk, self.rand_r, self.rand_i), self.key_size);
        self.keysReady();
    }

    fn legacyTk(self: *const Pairer) toolbox.Key {
        return switch (self.method) {
            .just_works => @splat(0),
            .passkey => passkeyBits(self.passkey),
            .out_of_band => if (self.oob_peer) |o| o.tk else @splat(0),
            else => @splat(0),
        };
    }

    // -----------------------------------------------------------------------
    // 阶段 2：Secure Connections
    // -----------------------------------------------------------------------

    fn onPeerPublicKey(self: *Pairer, pk: ecc.Pub) Error!void {
        // 2.3.5.6.1：不在曲线上 → 3.5.5 建议 DHKey Check Failed。
        if (!ecc.publicValid(pk)) {
            self.fail(.dhkey_check_failed, true);
            return error.Unexpected;
        }
        const local_is_debug = ecc.isDebugPublic(self.pk_local);
        if (ecc.isDebugPublic(pk) and !self.cfg.accept_debug_key) {
            self.fail(.invalid_parameters, true);
            return error.Unexpected;
        }
        // 两个公钥 X 坐标相同且都不是调试密钥 → 应失败。
        if (std.mem.eql(u8, &pk.x, &self.pk_local.x) and !local_is_debug and !ecc.isDebugPublic(pk)) {
            self.fail(.invalid_parameters, true);
            return error.Unexpected;
        }
        self.pk_peer = pk;
        self.dhkey = ecc.dhkey(self.sk, pk) catch {
            self.fail(.dhkey_check_failed, true);
            return error.Unexpected;
        };
        if (self.cfg.role == .initiator) {
            self.state = .sc_stage1;
        } else {
            self.state = .sc_send_pk;
        }
    }

    fn stage1(self: *Pairer) void {
        if (self.method == .passkey and !self.passkey_set) {
            self.resume_state = .sc_stage1;
            self.state = .wait_passkey;
            return;
        }
        self.round = 0;
        const x_a = self.pkInitiator().x;
        const x_b = self.pkResponder().x;
        switch (self.method) {
            .just_works, .numeric_comparison => {
                // Figure 2.3：ra = rb = 0；响应端先发确认值，发起端再发 Na。
                @memset(&self.r_a, 0);
                @memset(&self.r_b, 0);
                if (self.cfg.role == .initiator) {
                    self.nonce_a = self.rng.bytes(16);
                    self.state = .sc_wait_confirm_b;
                } else {
                    self.nonce_b = self.rng.bytes(16);
                    self.confirm_r = toolbox.f4(x_b, x_a, self.nonce_b, 0);
                    self.state = .sc_send_confirm_b;
                }
            },
            .passkey => {
                // 2.3.5.6.3：20 轮，每轮一位；f6 的 ra、rb 是把 passkey 当 128 位整数。
                self.r_a = passkeyBits(self.passkey);
                self.r_b = self.r_a;
                if (self.cfg.role == .initiator) {
                    self.state = .sc_pk_send_confirm_a;
                } else {
                    self.state = .sc_pk_prep_b;
                }
            },
            .out_of_band => {
                // Figure 2.5 步骤 5：对端的 OOB 数据标志说明它是否拿到了我们的 r；
                // 没拿到时对端把我们的 r 当 0，本机也必须跟着置 0。对端发来的 r 在
                // 没收到时同样按 0 处理。
                const have = self.oob_peer != null;
                const peer_x = if (self.cfg.role == .initiator) x_b else x_a;
                const peer_r: toolbox.Key = if (have) self.oob_peer.?.r else @splat(0);
                const own_r: toolbox.Key = if (self.peer_oob_flag) self.oob_local_r else @splat(0);
                if (self.cfg.oob_flag and !have) {
                    self.pending_fail = .oob_not_available;
                } else if (have and !sameKey(toolbox.f4(peer_x, peer_x, peer_r, 0), self.oob_peer.?.confirm)) {
                    self.pending_fail = .confirm_value_failed;
                }
                if (self.cfg.role == .initiator) {
                    self.r_a = own_r;
                    self.r_b = peer_r;
                    self.nonce_a = self.rng.bytes(16);
                    if (self.pending_fail) |reason| {
                        self.fail(reason, true); // 附录 C.19、C.20：发起端直接失败
                        return;
                    }
                    self.state = .sc_send_nonce_a;
                } else {
                    self.r_b = own_r;
                    self.r_a = peer_r;
                    self.nonce_b = self.rng.bytes(16);
                    self.state = .sc_wait_nonce_a; // 附录 C.18、C.21：收到 Na 后才失败
                }
            },
        }
    }

    fn zBit(self: *const Pairer) u8 {
        return 0x80 | @as(u8, @truncate((self.passkey >> @intCast(self.round)) & 1));
    }

    /// 2.2.9：Va = Vb = g2(PKax, PKbx, Na, Nb) mod 10^6（Figure 2.3 步骤 7a/7b）。
    fn ncValue(self: *const Pairer) u32 {
        return toolbox.compareValue(toolbox.g2(
            self.pkInitiator().x,
            self.pkResponder().x,
            self.nonce_a,
            self.nonce_b,
        ));
    }

    fn onConfirmB(self: *Pairer, v: toolbox.Key) Error!void {
        self.confirm_r = v;
        self.emit(.{ .pairing_random = self.nonce_a });
        self.state = .sc_wait_nonce_b;
    }

    fn onNonceA(self: *Pairer, v: toolbox.Key) Error!void {
        if (self.pending_fail) |reason| {
            self.fail(reason, true);
            return error.Unexpected;
        }
        self.nonce_a = v;
        self.emit(.{ .pairing_random = self.nonce_b });
        self.deriveLtk();
        if (self.method == .numeric_comparison) {
            self.nc_value = self.ncValue();
            self.resume_state = .sc_wait_check_a;
            self.state = .wait_nc_confirm;
            self.pushEvent(.{ .numeric_comparison = self.nc_value });
        } else {
            self.state = .sc_wait_check_a;
        }
    }

    fn onNonceB(self: *Pairer, v: toolbox.Key) Error!void {
        self.nonce_b = v;
        // 附录 C.2.2.2.2：确认值不符 → Confirm Value Failed。OOB 不交换确认值，
        // 对端 OOB 数据的检查已在阶段 1 开始时做过。
        if (self.method != .out_of_band and
            !sameKey(toolbox.f4(self.pkResponder().x, self.pkInitiator().x, v, 0), self.confirm_r))
        {
            self.fail(.confirm_value_failed, true);
            return error.Unexpected;
        }
        if (self.method == .numeric_comparison) {
            self.nc_value = self.ncValue();
            self.resume_state = .sc_send_check_a;
            self.state = .wait_nc_confirm;
            self.pushEvent(.{ .numeric_comparison = self.nc_value });
        } else {
            self.state = .sc_send_check_a;
        }
    }

    fn onPkConfirmA(self: *Pairer, v: toolbox.Key) Error!void {
        self.confirm_i = v;
        self.state = .sc_pk_send_confirm_b;
    }

    fn onPkConfirmB(self: *Pairer, v: toolbox.Key) Error!void {
        self.confirm_r = v;
        self.emit(.{ .pairing_random = self.nonce_a });
        self.state = .sc_pk_wait_nonce_b;
    }

    fn onPkNonceA(self: *Pairer, v: toolbox.Key) Error!void {
        self.nonce_a = v;
        // Figure 2.4 步骤 7a（附录 C.2.2.2.6）。
        if (!sameKey(toolbox.f4(self.pkInitiator().x, self.pkResponder().x, v, self.zBit()), self.confirm_i)) {
            self.fail(.confirm_value_failed, true);
            return error.Unexpected;
        }
        self.emit(.{ .pairing_random = self.nonce_b });
        self.round += 1;
        if (self.round < 20) {
            self.state = .sc_pk_prep_b;
        } else {
            self.deriveLtk();
            self.state = .sc_wait_check_a;
        }
    }

    fn onPkNonceB(self: *Pairer, v: toolbox.Key) Error!void {
        self.nonce_b = v;
        // Figure 2.4 步骤 8a（附录 C.2.2.2.7）。
        if (!sameKey(toolbox.f4(self.pkResponder().x, self.pkInitiator().x, v, self.zBit()), self.confirm_r)) {
            self.fail(.confirm_value_failed, true);
            return error.Unexpected;
        }
        self.round += 1;
        if (self.round < 20) {
            self.state = .sc_pk_send_confirm_a;
        } else {
            self.state = .sc_send_check_a;
        }
    }

    /// 2.2.7 / Figure 2.6 步骤 9：MacKey || LTK = f5(DHKey, Na, Nb, A, B)。
    fn deriveLtk(self: *Pairer) void {
        const r = toolbox.f5(
            self.dhkey,
            self.nonce_a,
            self.nonce_b,
            addr7(self.initiatorAddr()),
            addr7(self.responderAddr()),
        );
        self.mac_key = r.mac_key;
        self.link_key = toolbox.maskKey(r.ltk, self.key_size);
    }

    fn iocapA(self: *const Pairer) [3]u8 {
        return .{ self.preq[3], self.preq[2], self.preq[1] };
    }

    fn iocapB(self: *const Pairer) [3]u8 {
        return .{ self.pres[3], self.pres[2], self.pres[1] };
    }

    fn expectedEa(self: *const Pairer) toolbox.Key {
        return toolbox.f6(self.mac_key, self.nonce_a, self.nonce_b, self.r_b, self.iocapA(), addr7(self.initiatorAddr()), addr7(self.responderAddr()));
    }

    fn expectedEb(self: *const Pairer) toolbox.Key {
        return toolbox.f6(self.mac_key, self.nonce_b, self.nonce_a, self.r_a, self.iocapB(), addr7(self.responderAddr()), addr7(self.initiatorAddr()));
    }

    fn onCheckA(self: *Pairer, v: toolbox.Key) Error!void {
        // 2.3.5.6.5 步骤 11 / 附录 C.2.2.4。
        if (!sameKey(v, self.expectedEa())) {
            self.fail(.dhkey_check_failed, true);
            return error.Unexpected;
        }
        self.emit(.{ .pairing_dhkey_check = self.expectedEb() });
        self.keysReady();
    }

    fn onCheckB(self: *Pairer, v: toolbox.Key) Error!void {
        // 2.3.5.6.5 步骤 12。
        if (!sameKey(v, self.expectedEb())) {
            self.fail(.dhkey_check_failed, true);
            return error.Unexpected;
        }
        self.keysReady();
    }

    fn keysReady(self: *Pairer) void {
        self.pushEvent(.keys_ready);
        self.state = .wait_encrypt;
    }

    // -----------------------------------------------------------------------
    // 阶段 3：密钥分发
    // -----------------------------------------------------------------------

    fn sendItem(self: *Pairer, item: Item) pdu.Pdu {
        const k = self.cfg.local_keys;
        return switch (item) {
            .ltk => .{ .encryption_information = toolbox.maskKey(k.ltk, self.key_size) },
            .ediv_rand => .{ .central_identification = .{ .ediv = k.ediv, .rand = k.rand } },
            .irk => .{ .identity_information = k.irk },
            .identity => .{ .identity_address_information = .{
                .addr_type = @backingInt(k.identity.type),
                .addr = k.identity.val,
            } },
            .csrk => .{ .signing_information = k.csrk },
            .none => unreachable,
        };
    }

    fn onDistribution(self: *Pairer, p: pdu.Pdu) Error!void {
        // 3.6.1：密钥按规定顺序到达；不是在等的那把，或者期望的都收齐了还有，都是协议错误。
        if (self.recv_step >= self.recv_n) return self.unexpected();
        const item = self.recv_items[self.recv_step];
        const pk = &self.peer_keys;
        switch (item) {
            .ltk => switch (p) {
                .encryption_information => |v| {
                    pk.ltk = toolbox.maskKey(v, self.key_size);
                    pk.has_ltk = true;
                },
                else => return self.unexpected(),
            },
            .ediv_rand => switch (p) {
                .central_identification => |v| {
                    pk.ediv = v.ediv;
                    pk.rand = v.rand;
                },
                else => return self.unexpected(),
            },
            .irk => switch (p) {
                .identity_information => |v| {
                    pk.irk = v;
                    pk.has_irk = !allZero(v);
                },
                else => return self.unexpected(),
            },
            .identity => switch (p) {
                .identity_address_information => |v| {
                    if (v.addr_type != pdu.addr_type_public and v.addr_type != pdu.addr_type_random) {
                        self.fail(.invalid_parameters, true);
                        return error.Malformed;
                    }
                    pk.identity = .{ .type = @fromBackingInt(@intCast(v.addr_type)), .val = v.addr };
                    pk.has_identity = true;
                },
                else => return self.unexpected(),
            },
            .csrk => switch (p) {
                .signing_information => |v| {
                    pk.csrk = v;
                    pk.has_csrk = true;
                },
                else => return self.unexpected(),
            },
            .none => return self.unexpected(),
        }
        self.recv_step += 1;
    }

    fn finish(self: *Pairer) void {
        self.state = .complete;
        self.timer_on = false;
        if (self.cfg.attempts) |a| a.recordSuccess();
        self.bond_cache = self.makeBond();
        self.pushEvent(.complete);
    }

    /// 2.4.3：bonding 时保存对端 LTK、EDIV、Rand、IRK、CSRK 与安全属性。
    fn makeBond(self: *Pairer) ?bond.Bond {
        if (!self.bonding) return null;
        var identity: bond.Addr = undefined;
        if (self.peer_keys.has_identity) {
            identity = self.peer_keys.identity;
        } else if (self.cfg.peer_addr.isIdentity()) {
            identity = self.cfg.peer_addr;
        } else {
            return null;
        }
        var out = bond.Bond{ .identity = identity };
        if (self.sc) {
            out.peer_ltk = .{ .key = self.link_key, .key_size = self.key_size };
            out.has_peer_ltk = true;
            out.own_ltk = out.peer_ltk;
            out.has_own_ltk = true;
        } else {
            if (self.peer_keys.has_ltk) {
                out.peer_ltk = .{
                    .key = self.peer_keys.ltk,
                    .key_size = self.key_size,
                    .ediv = self.peer_keys.ediv,
                    .rand = self.peer_keys.rand,
                };
                out.has_peer_ltk = true;
            }
            if (self.send_n > 0 and self.send_items[0] == .ltk) {
                out.own_ltk = .{
                    .key = toolbox.maskKey(self.cfg.local_keys.ltk, self.key_size),
                    .key_size = self.key_size,
                    .ediv = self.cfg.local_keys.ediv,
                    .rand = self.cfg.local_keys.rand,
                };
                out.has_own_ltk = true;
            }
        }
        out.irk = self.peer_keys.irk;
        out.has_irk = self.peer_keys.has_irk;
        out.csrk = self.peer_keys.csrk;
        out.has_csrk = self.peer_keys.has_csrk;
        out.authenticated = self.authenticated;
        out.sc = self.sc;
        out.verified = false;
        out.peer_sign_counter = 0;
        return out;
    }

    // -----------------------------------------------------------------------
    // 推进
    // -----------------------------------------------------------------------

    fn pump(self: *Pairer) void {
        while (self.out_len == 0) switch (self.state) {
            .lg_stage1_i => {
                if (self.method == .passkey and !self.passkey_set) {
                    self.resume_state = .lg_stage1_i;
                    self.state = .wait_passkey;
                    continue;
                }
                self.tk = self.legacyTk();
                self.rand_i = self.rng.bytes(16);
                self.confirm_i = self.computeConfirm(self.tk, self.rand_i);
                self.emit(.{ .pairing_confirm = self.confirm_i });
                self.state = .lg_wait_confirm_r;
            },
            .lg_send_confirm_r => {
                if (self.method == .passkey and !self.passkey_set) {
                    self.resume_state = .lg_send_confirm_r;
                    self.state = .wait_passkey;
                    continue;
                }
                self.tk = self.legacyTk();
                self.rand_r = self.rng.bytes(16);
                self.confirm_r = self.computeConfirm(self.tk, self.rand_r);
                self.emit(.{ .pairing_confirm = self.confirm_r });
                self.state = .lg_wait_mrand;
            },
            .sc_send_pk => {
                self.emit(.{ .pairing_public_key = self.pk_local });
                if (self.cfg.role == .initiator) {
                    self.state = .sc_wait_pk;
                } else {
                    self.state = .sc_stage1;
                }
            },
            .sc_stage1 => self.stage1(),
            .sc_send_confirm_b => {
                self.emit(.{ .pairing_confirm = self.confirm_r });
                self.state = .sc_wait_nonce_a;
            },
            .sc_send_nonce_a => {
                self.emit(.{ .pairing_random = self.nonce_a });
                self.state = .sc_wait_nonce_b;
            },
            .sc_pk_send_confirm_a => {
                // Figure 2.4 步骤 3a/4a。
                self.nonce_a = self.rng.bytes(16);
                self.confirm_i = toolbox.f4(self.pkInitiator().x, self.pkResponder().x, self.nonce_a, self.zBit());
                self.emit(.{ .pairing_confirm = self.confirm_i });
                self.state = .sc_pk_wait_confirm_b;
            },
            .sc_pk_prep_b => {
                self.nonce_b = self.rng.bytes(16);
                self.state = .sc_pk_wait_confirm_a;
            },
            .sc_pk_send_confirm_b => {
                self.confirm_r = toolbox.f4(self.pkResponder().x, self.pkInitiator().x, self.nonce_b, self.zBit());
                self.emit(.{ .pairing_confirm = self.confirm_r });
                self.state = .sc_pk_wait_nonce_a;
            },
            .sc_send_check_a => {
                // Figure 2.6 步骤 10a：Ea = f6(MacKey, Na, Nb, rb, IOcapA, A, B)。
                self.deriveLtk();
                self.emit(.{ .pairing_dhkey_check = self.expectedEa() });
                self.state = .sc_wait_check_b;
            },
            .distribute => {
                const waiting_peer = self.recv_step < self.recv_n;
                if (self.cfg.role == .initiator and waiting_peer) return;
                if (self.send_step < self.send_n) {
                    const item = self.send_items[self.send_step];
                    self.send_step += 1;
                    self.emit(self.sendItem(item));
                } else if (!waiting_peer) {
                    self.finish();
                    return;
                } else {
                    return;
                }
            },
            else => return,
        };
    }
};

fn featureBytes(b: *const [7]u8) pdu.Features {
    return .{
        .io_cap = b[1],
        .oob = b[2],
        .auth_req = b[3],
        .max_key_size = b[4],
        .initiator_keys = b[5],
        .responder_keys = b[6],
    };
}
