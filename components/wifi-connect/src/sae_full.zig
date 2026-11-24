//! wifi-connect：SAE 完整协议（IEEE Std 802.11-2016 12.4，印刷页 1935–1953）。
//!
//! `sae.zig` 是字节层，`ecc.zig` 是 P-256 点运算；本文件把它们串成协议：
//!
//!   1. 协议核心（没有状态）
//!      * PWE 派生（hunting and pecking，12.4.4.2.2，印刷页 1937–1939）
//!      * rand / mask（12.4.5.2，1942）与 Commit 构造（12.4.5.3，1942）
//!      * 对端 Commit 的处理：校验、K = rand·(pcs·PWE + PCE)、k = F(K)
//!        （12.4.5.4，1942–1943）
//!      * keyseed / KCK / PMK / PMKID 与 Confirm 的 CN 复用 `sae.zig`
//!        （12.4.5.4–12.4.5.6，1943）
//!   2. 帧体编解码（12.4.7，1944–1946；表 9-36，713–715；表 9-46，732–735）
//!   3. 协议实例的状态机（12.4.8.2.2、12.4.8.3.2、12.4.8.5.2、12.4.8.6.2–12.4.8.6.6，
//!      1947–1953）
//!   4. 父进程（12.4.6、12.4.8.6.1，1943–1944、1949–1950）：实例表、Open 计数、
//!      Anti-Clogging Token
//!
//! 只支持 group 19（12.4.4.1 要求必须支持的那个）。没做的：H2E、别的群、
//! 恒定时间、rejected-groups / password-identifier 元素、两个群之间的 DiffGrp 同步
//! （只有一个群时走不到）。
//!
//! 随机数与发帧都由调用方注入（`Random`、`Sink`），本文件不读硬件、不分配堆内存。
//! 时间是毫秒。本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

const ecc = @import("ecc.zig");
const sae = @import("sae.zig");

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 本实现唯一支持的 finite cyclic group：19 = P-256。
pub const group: u16 = 19;
/// Authentication Algorithm Number = 3（SAE，表 9-36）。
pub const algorithm: u16 = 3;
/// Commit 的事务序号是 1，Confirm 是 2（12.4.7.3）。
pub const seq_commit: u16 = 1;
pub const seq_confirm: u16 = 2;

/// Status code（表 9-46；12.4.7.6）。
pub const status_success: u16 = 0;
pub const status_challenge_failure: u16 = 15;
pub const status_token_required: u16 = 76;
pub const status_group_not_supported: u16 = 77;

/// 帧体开头三个字段：算法(2) || 事务序号(2) || 状态(2)，都是小端（表 9-35）。
pub const header_len = 6;
const group_len = 2;
const scalar_elem_len = sae.scalar_len + sae.element_len;
/// 不带 token 的 Commit 帧体长度。
pub const commit_body_len = header_len + group_len + scalar_elem_len;
/// Confirm 帧体长度。
pub const confirm_body_len = header_len + sae.send_confirm_len + sae.hash_len;
/// Anti-Clogging Token 的上限（12.4.6 的建议值）；更长的 token 解码失败。
pub const token_max_len = 256;
/// 帧体最大长度：带满 token 的 Commit。
pub const body_max_len = commit_body_len + token_max_len;

/// 进入 Accepted 时 Sc 的取值（12.4.8.6.5）。
pub const sc_accepted: u16 = 0xffff;
/// rand / mask 最多重取这么多次（每次 64 字节）。
pub const secret_attempts = 8;

/// 取随机数：把 `out` 填满。逻辑模块不读硬件，由调用方注入。
pub const Random = *const fn (out: []u8) void;

/// 发帧的回调。`body` 是 Authentication 帧体（不含 MAC 头），离开回调后失效。
pub const Sink = struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, peer: [6]u8, body: []const u8) void,
};

// ---------------------------------------------------------------------------
// 1) 帧体编解码（12.4.7）
// ---------------------------------------------------------------------------

/// 收到的 Commit（事务序号 1）。
pub const CommitMsg = struct {
    status: u16,
    /// Finite Cyclic Group 字段。状态不是 0 或 76 时帧里可以没有（表 9-36）。
    group: ?u16 = null,
    token: []const u8 = &.{},
    /// 状态为 0、群是 19 时才有；帧太短时是 null（等于校验失败）。
    scalar: ?[sae.scalar_len]u8 = null,
    element: ?[sae.element_len]u8 = null,
};

/// 收到的 Confirm（事务序号 2）。
pub const ConfirmMsg = struct {
    status: u16,
    send_confirm: u16 = 0,
    confirm: [sae.hash_len]u8 = @splat(0),
};

pub const DecodeError = error{ TooShort, NotSae, BadSequence, BadLength, TokenTooLong };

pub const Decoded = union(enum) { commit: CommitMsg, confirm: ConfirmMsg };

/// 解析 Authentication 帧体（表 9-35、表 9-36）。
pub fn decode(body: []const u8) DecodeError!Decoded {
    if (body.len < header_len) return error.TooShort;
    const alg = std.mem.readInt(u16, body[0..2], .little);
    const seq = std.mem.readInt(u16, body[2..4], .little);
    const status = std.mem.readInt(u16, body[4..6], .little);
    if (alg != algorithm) return error.NotSae;
    switch (seq) {
        seq_commit => {
            var msg = CommitMsg{ .status = status };
            // Commit：群字段只在状态为 0 或 76 时必带（表 9-36）
            if (status != status_success and status != status_token_required) {
                if (body.len >= header_len + group_len) {
                    msg.group = std.mem.readInt(u16, body[6..8], .little);
                }
                return .{ .commit = msg };
            }
            if (body.len < header_len + group_len) return error.TooShort;
            msg.group = std.mem.readInt(u16, body[6..8], .little);
            const rest = body[header_len + group_len ..];
            if (status == status_token_required) {
                if (rest.len > token_max_len) return error.TokenTooLong;
                msg.token = rest;
                return .{ .commit = msg };
            }
            if (msg.group.? != group) {
                // 别的群的 scalar / element 有多长不知道，不往下解析
                return .{ .commit = msg };
            }
            // token 有没有、多长，由总长度反推（12.4.6）
            if (rest.len < scalar_elem_len) return .{ .commit = msg };
            const token_len = rest.len - scalar_elem_len;
            if (token_len > token_max_len) return error.TokenTooLong;
            msg.token = rest[0..token_len];
            msg.scalar = rest[token_len..][0..sae.scalar_len].*;
            msg.element = rest[token_len + sae.scalar_len ..][0..sae.element_len].*;
            return .{ .commit = msg };
        },
        seq_confirm => {
            const msg = ConfirmMsg{ .status = status };
            // 拒绝用的 Confirm 只有头部；带 CN 的 Confirm 长度固定（表 9-36）
            if (status != status_success) return .{ .confirm = msg };
            if (body.len != confirm_body_len) return error.BadLength;
            return .{ .confirm = .{
                .status = status,
                .send_confirm = std.mem.readInt(u16, body[6..8], .little),
                .confirm = body[8..][0..sae.hash_len].*,
            } };
        },
        else => return error.BadSequence,
    }
}

fn putHeader(out: *[header_len]u8, seq: u16, status: u16) void {
    std.mem.writeInt(u16, out[0..2], algorithm, .little);
    std.mem.writeInt(u16, out[2..4], seq, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
}

// ---------------------------------------------------------------------------
// 2) 协议核心（12.4.4.2.2、12.4.5.2–12.4.5.6）
// ---------------------------------------------------------------------------

/// 1 < s < r。
fn scalarInStrictRange(s: sae.U256) bool {
    const one = blk: {
        var v: sae.U256 = @splat(0);
        v[31] = 1;
        break :blk v;
    };
    return sae.cmp(s, one) == .gt and sae.cmp(s, sae.order) == .lt;
}

/// 0 < s < r：12.4.5.4 对对端 commit-scalar 的要求。
fn scalarValid(s: sae.U256) bool {
    const zero: sae.U256 = @splat(0);
    return sae.cmp(s, zero) == .gt and sae.cmp(s, sae.order) == .lt;
}

pub const Pwe = struct {
    point: ecc.Point,
    /// 停在第几个 counter。
    counter: u8,
    seed: [sae.hash_len]u8,
};

pub const PweError = error{NotFound};

fn pwdValueOf(seed: [sae.hash_len]u8, counter: u8) [sae.hash_len]u8 {
    _ = counter;
    return sae.pwdValue(seed);
}

/// hunting and pecking（12.4.4.2.2，印刷页 1937–1939）：
///
///   pwd-seed  = H(MAX||MIN, password || counter)，counter 一个八位组，从 1 起
///   pwd-value = KDF-Hash-Length(pwd-seed, "SAE Hunting and Pecking", p)
///   pwd-value >= p 或曲线上没有这个 x：counter 加 1 重来
///   y = sqrt(x³ + ax + b)；pwd-seed 的最低位与 y 的奇偶相同取 (x, y)，否则取 (x, p − y)
///
/// 找到就停（规范「应该」至少跑 k 轮来遮掩轮数，本实现没做，见 `sae.zig` 的
/// `unimplemented`）。counter 是一个八位组，最多到 255。
pub fn derivePwe(own_mac: [6]u8, peer_mac: [6]u8, password: []const u8) PweError!Pwe {
    return derivePweWith(pwdValueOf, own_mac, peer_mac, password);
}

/// 同上，但 pwd-value 由 `pwdValueFn` 算（测试用它把前几轮伪造成 >= p，好走到
/// 「counter 加 1 重来」的分支；正常实现是 `sae.pwdValue`）。
pub fn derivePweWith(
    comptime pwdValueFn: fn (seed: [sae.hash_len]u8, counter: u8) [sae.hash_len]u8,
    own_mac: [6]u8,
    peer_mac: [6]u8,
    password: []const u8,
) PweError!Pwe {
    var counter: u16 = 1;
    while (counter <= 255) : (counter += 1) {
        const c: u8 = @intCast(counter);
        const seed = sae.pwdSeedOctet(own_mac, peer_mac, password, c);
        const value = pwdValueFn(seed, c);
        if (!sae.pwdValueUsable(value)) continue;
        const y = ecc.recoverY(value, seed[31] & 1 == 1) orelse continue;
        const point = ecc.fromBytes(&(value ++ y)) orelse continue;
        return .{ .point = point, .counter = c, .seed = seed };
    }
    return error.NotFound;
}

pub const Secrets = struct {
    rand: [sae.scalar_len]u8,
    mask: [sae.scalar_len]u8,
};

pub const RandomError = error{RandomExhausted};

/// rand 与 mask（12.4.5.2）：1 < rand < r、1 < mask < r，且 (rand + mask) mod r > 1；
/// 不满足就都丢掉重取。每次从 `random` 取 64 字节，按大整数对 r 取模。
/// 连续 `secret_attempts` 次都不行报 RandomExhausted（随机源正常时碰不到）。
pub fn generateSecrets(random: Random) RandomError!Secrets {
    var draw: [2 * sae.scalar_len]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < secret_attempts) : (attempt += 1) {
        random(&draw);
        const s = Secrets{
            .rand = sae.modQ(draw[0..sae.scalar_len].*),
            .mask = sae.modQ(draw[sae.scalar_len..].*),
        };
        const sum = sae.scalarAddModQ(s.rand, s.mask);
        if (scalarInStrictRange(s.rand) and scalarInStrictRange(s.mask) and scalarInStrictRange(sum)) {
            return s;
        }
    }
    return error.RandomExhausted;
}

pub const Commit = struct {
    scalar: [sae.scalar_len]u8,
    element: [sae.element_len]u8,
};

/// 12.4.5.3：commit-scalar = (rand + mask) mod r，
/// COMMIT-ELEMENT = inverse(scalar-op(mask, PWE))。
pub fn buildCommit(secrets: Secrets, pwe: ecc.Point) Commit {
    return .{
        .scalar = sae.scalarAddModQ(secrets.rand, secrets.mask),
        .element = ecc.mul(secrets.mask, pwe).neg().toBytes(),
    };
}

pub const CommitError = error{ Scalar, Element, Identity };

/// 12.4.5.4：校验对端的 commit 并算 k = F(K)，其中
/// K = scalar-op(rand, elem-op(scalar-op(peer-commit-scalar, PWE), PEER-COMMIT-ELEMENT))。
///
/// scalar 不在 (0, r) 内报 Scalar；元素解不出来（坐标为 0 或不小于 p、不在曲线上）
/// 报 Element；K 是无穷远点报 Identity。
pub fn processCommit(
    rand: [sae.scalar_len]u8,
    pwe: ecc.Point,
    peer_scalar: [sae.scalar_len]u8,
    peer_element: [sae.element_len]u8,
) CommitError![sae.scalar_len]u8 {
    if (!scalarValid(peer_scalar)) return error.Scalar;
    const peer_point = ecc.fromBytes(&peer_element) orelse return error.Element;
    const big_k = ecc.mul(rand, ecc.add(ecc.mul(peer_scalar, pwe), peer_point));
    if (big_k.isInfinity()) return error.Identity;
    return big_k.xBytes();
}

// ---------------------------------------------------------------------------
// 3) 协议实例的状态机（12.4.8）
// ---------------------------------------------------------------------------

/// 12.4.8.2.2 的四个状态。
pub const State = enum { nothing, committed, confirmed, accepted };

/// 12.4.8.4 的两个定时器：t0 重传，t1 密钥过期。
pub const Timer = enum { t0, t1 };

/// 实例发给父进程的事件（12.4.8.3.1）。
pub const Signal = enum {
    /// 对端认证通过。
    auth,
    /// 对端认证失败。
    fail,
    /// 实例遇到致命事件。
    del,
};

/// 一个事件处理完的结果：要么原文要求的「静默丢弃」，要么实例发给父进程的信号。
pub const Result = enum { ok, discarded, auth, fail, del };

/// 定时与上限。默认值取 Annex C 的 DEFVAL（印刷页 2840）：dot11RSNASAERetransPeriod 是
/// 40（毫秒），dot11RSNASAESync 是 5。dot11RSNAConfigPMKLifetime 的定义在 2016 的
/// Annex C 里被省略，没查到默认值，12 h 是本实现的取值。
pub const Timing = struct {
    /// t0 的时长，毫秒（dot11RSNASAERetransPeriod）。
    retrans_period_ms: u32 = 40,
    /// Sync 超过它就放弃（dot11RSNASAESync）。
    sync_max: u16 = 5,
    /// t1 的时长，毫秒（dot11RSNAConfigPMKLifetime）。
    pmk_lifetime_ms: u64 = 43_200_000,
};

/// 实例运行所需的外部条件，由调用方（通常是父进程）持有一份。
pub const Env = struct {
    own_mac: [6]u8,
    /// 口令的 ASCII 字节（12.4.3）；调用方保证它在实例的整个生命周期内有效。
    password: []const u8,
    random: Random,
    emit: Sink,
    timing: Timing = .{},
};

/// 最后一次发出的 Commit。重传时「把最后发出去的 Commit 再发一遍」。
const Last = union(enum) {
    /// 自己的 commit-scalar / COMMIT-ELEMENT（带收到的 token）。
    offer,
    /// 拒绝对端给的群（状态 77）。
    unsupported_group: u16,
};

/// 一个协议实例：本机 MAC 与对端 MAC 各一份（12.4.8.1）。约 700 字节，放静态区。
pub const Instance = struct {
    env: *const Env = undefined,
    peer_mac: [6]u8 = @splat(0),
    state: State = .nothing,

    /// 状态重同步的次数。
    sync: u16 = 0,
    /// 已发出的 Confirm 个数，也就是 Confirm 里的 send-confirm。
    sc: u16 = 0,
    /// 最近一次收到的 Confirm 里的 send-confirm。
    rc: u16 = 0,

    t0_at: u64 = 0,
    t0_armed: bool = false,
    t1_at: u64 = 0,
    t1_armed: bool = false,

    pwe: ecc.Point = .{},
    rand: [sae.scalar_len]u8 = @splat(0),
    own_scalar: [sae.scalar_len]u8 = @splat(0),
    own_element: ecc.Point = .{},
    peer_scalar: [sae.scalar_len]u8 = @splat(0),
    peer_element: ecc.Point = .{},
    kck: [sae.kck_len]u8 = @splat(0),
    pmk: [sae.pmk_len]u8 = @splat(0),
    pmkid: [sae.pmkid_len]u8 = @splat(0),

    /// 收到的 Anti-Clogging Token，重发 Commit 时原样带回。
    token_len: u16 = 0,
    token: [token_max_len]u8 = undefined,
    last: Last = .offer,

    // ---- 定时器（12.4.8.4、12.4.8.6.2）----

    fn bigSync(self: *const Instance) bool {
        return self.sync > self.env.timing.sync_max;
    }

    fn arm(self: *Instance, timer: Timer, now_ms: u64) void {
        switch (timer) {
            .t0 => {
                self.t0_at = now_ms + self.env.timing.retrans_period_ms;
                self.t0_armed = true;
            },
            .t1 => {
                self.t1_at = now_ms + self.env.timing.pmk_lifetime_ms;
                self.t1_armed = true;
            },
        }
    }

    fn disarm(self: *Instance, timer: Timer) void {
        switch (timer) {
            .t0 => self.t0_armed = false,
            .t1 => self.t1_armed = false,
        }
    }

    /// 「静默丢弃并重设 t0」。
    fn waitT0(self: *Instance, now_ms: u64) Result {
        self.arm(.t0, now_ms);
        return .discarded;
    }

    /// 实例结束：清掉全部秘密回到 Nothing，把信号交给父进程。
    fn die(self: *Instance, signal: Signal) Result {
        std.debug.assert(signal != .auth);
        self.* = .{ .env = self.env };
        return switch (signal) {
            .fail => .fail,
            .del => .del,
            .auth => unreachable,
        };
    }

    // ---- 输出 1(N) 与 2（12.4.8.3.2）----

    /// 1(N)：发 Commit。内容取自 `last`。
    fn sendCommit(self: *Instance) void {
        var body: [body_max_len]u8 = undefined;
        switch (self.last) {
            .offer => {
                // 群(2) || token || scalar(32) || element(64)（12.4.7.4）
                putCommitHeader(body[0 .. header_len + group_len], status_success, group);
                const n = header_len + group_len + self.token_len;
                @memcpy(body[8..n], self.token[0..self.token_len]);
                @memcpy(body[n..][0..sae.scalar_len], &self.own_scalar);
                @memcpy(body[n + sae.scalar_len ..][0..sae.element_len], &self.own_element.toBytes());
                self.emitBody(body[0 .. n + scalar_elem_len]);
            },
            .unsupported_group => |g| {
                // 群字段填被拒绝的群（12.4.8.6.3、12.4.8.6.4）
                putCommitHeader(body[0 .. header_len + group_len], status_group_not_supported, g);
                self.emitBody(body[0 .. header_len + group_len]);
            },
        }
    }

    /// 2：发 Confirm：send-confirm(2) || CN（12.4.7.5）。
    fn sendConfirm(self: *Instance) void {
        var body: [confirm_body_len]u8 = undefined;
        putHeader(body[0..header_len], seq_confirm, status_success);
        std.mem.writeInt(u16, body[6..8], self.sc, .little);
        body[8..].* = self.confirmValue(self.sc);
        self.emitBody(&body);
    }

    /// 状态 15 的 Confirm（12.4.7.6）：对端 Confirm 没验证过时发，不带 send-confirm 与 CN。
    fn sendChallengeFailure(self: *Instance) void {
        var body: [header_len]u8 = undefined;
        putHeader(&body, seq_confirm, status_challenge_failure);
        self.emitBody(&body);
    }

    fn emitBody(self: *Instance, body: []const u8) void {
        self.env.emit.frame(self.env.emit.ctx, self.peer_mac, body);
    }

    /// CN(KCK, send-confirm, commit-scalar, COMMIT-ELEMENT, peer-commit-scalar,
    /// PEER-COMMIT-ELEMENT)（12.4.5.5）。
    fn confirmValue(self: *const Instance, send_confirm: u16) [sae.hash_len]u8 {
        return sae.deriveConfirm(
            self.kck,
            send_confirm,
            self.own_scalar,
            self.own_element.toBytes(),
            self.peer_scalar,
            self.peer_element.toBytes(),
        );
    }

    /// 12.4.5.6：verifier = CN(KCK, peer-send-confirm, peer-commit-scalar,
    /// PEER-COMMIT-ELEMENT, commit-scalar, COMMIT-ELEMENT)。
    fn confirmOk(self: *const Instance, msg: ConfirmMsg) bool {
        const verifier = sae.deriveConfirm(
            self.kck,
            msg.send_confirm,
            self.peer_scalar,
            self.peer_element.toBytes(),
            self.own_scalar,
            self.own_element.toBytes(),
        );
        return sae.verifyConfirm(verifier, msg.confirm);
    }

    // ---- 12.4.5.2–12.4.5.4 ----

    /// 生成 PWE 与秘密值，再构造自己的 commit。
    fn generate(self: *Instance) !void {
        const pwe = try derivePwe(self.env.own_mac, self.peer_mac, self.env.password);
        const secrets = try generateSecrets(self.env.random);
        self.pwe = pwe.point;
        self.rand = secrets.rand;
        const commit = buildCommit(secrets, pwe.point);
        self.own_scalar = commit.scalar;
        self.own_element = ecc.fromBytes(&commit.element) orelse return error.InvalidCommit;
        self.last = .offer;
    }

    /// 12.4.5.4：校验并处理对端的 commit，随后派生 KCK / PMK / PMKID。
    fn acceptPeerCommit(self: *Instance, msg: CommitMsg) !void {
        const scalar = msg.scalar orelse return error.Scalar;
        const element = msg.element orelse return error.Element;
        const k = try processCommit(self.rand, self.pwe, scalar, element);
        const keys = sae.deriveKeys(k, self.own_scalar, scalar);
        self.peer_scalar = scalar;
        self.peer_element = ecc.fromBytes(&element) orelse return error.Element;
        self.kck = keys.kck;
        self.pmk = keys.pmk;
        self.pmkid = keys.pmkid;
    }

    // ---- 事件 ----

    /// Nothing + Init（12.4.8.6.3）：清 Sync / Rc / Sc，生成 PWE 与秘密值，
    /// 发 Commit，设 t0，进 Committed。
    pub fn start(self: *Instance, now_ms: u64) Result {
        if (self.state != .nothing) return .discarded;
        self.sync = 0;
        self.sc = 0;
        self.rc = 0;
        self.generate() catch return self.die(.del);
        self.sendCommit();
        self.arm(.t0, now_ms);
        self.state = .committed;
        return .ok;
    }

    /// 收到事务序号 1 的帧：状态 0 是 Com 事件，否则是 Rej(N)。
    pub fn onCommit(self: *Instance, msg: CommitMsg, now_ms: u64) Result {
        switch (self.state) {
            .nothing => return self.nothingOnCommit(msg, now_ms),
            .committed => return self.committedOnCommit(msg, now_ms),
            .confirmed => return self.confirmedOnCommit(msg, now_ms),
            // Accepted 的实例不收 Com，父进程另有处理（12.4.8.6.1）
            .accepted => return .discarded,
        }
    }

    /// 收到事务序号 2 的帧：状态 0 是 Con 事件，否则是 Rej(N)。
    pub fn onConfirm(self: *Instance, msg: ConfirmMsg, now_ms: u64) Result {
        switch (self.state) {
            // 父进程不会把 Confirm 交给 Nothing 的实例（12.4.8.6.3 的 NOTE）
            .nothing => return .discarded,
            .committed => {
                self.disarm(.t0);
                // 其它非零状态：静默丢弃并重设 t0（12.4.8.6.4）
                if (msg.status != status_success) return self.waitT0(now_ms);
                // Committed 收到 Confirm：说明对端没收到我们的 Commit
                if (self.bigSync()) return self.die(.del);
                self.sync += 1;
                self.sendCommit();
                return self.waitT0(now_ms);
            },
            .confirmed => {
                self.disarm(.t0);
                // Confirmed 收到的拒绝帧一律静默丢弃（12.4.8.6.5）
                if (msg.status != status_success) return self.waitT0(now_ms);
                if (!self.confirmOk(msg)) {
                    // 12.4.5.6：拒绝对端认证并删除 PMK
                    self.sendChallengeFailure();
                    return self.die(.fail);
                }
                self.rc = msg.send_confirm;
                self.sc = sc_accepted;
                // 进 Accepted 后 PWE 与 rand 不再需要
                self.pwe = .{};
                self.rand = @splat(0);
                self.arm(.t1, now_ms);
                self.state = .accepted;
                return .auth;
            },
            .accepted => return self.acceptedOnConfirm(msg),
        }
    }

    /// 定时器到点。触发过的定时器不再重设（12.4.8.3.2）；要重设由各分支自己设。
    pub fn onTimer(self: *Instance, timer: Timer, now_ms: u64) Result {
        self.disarm(timer);
        switch (timer) {
            .t0 => switch (self.state) {
                .committed => {
                    if (self.bigSync()) return self.die(.del);
                    self.sync += 1;
                    self.sendCommit();
                    self.arm(.t0, now_ms);
                    return .ok;
                },
                .confirmed => {
                    if (self.bigSync()) return self.die(.del);
                    self.sync += 1;
                    self.sc +|= 1;
                    self.sendConfirm();
                    self.arm(.t0, now_ms);
                    return .ok;
                },
                .nothing, .accepted => return .discarded,
            },
            // t1 到点：密钥过期，实例结束（12.4.8.6.6）
            .t1 => return if (self.state == .accepted) self.die(.del) else .discarded,
        }
    }

    /// 推进时间：已到点的定时器依次触发（先 t0 后 t1）。返回最后一个事件的结果。
    pub fn poll(self: *Instance, now_ms: u64) Result {
        var r: Result = .ok;
        if (self.t0_armed and now_ms >= self.t0_at) r = self.onTimer(.t0, now_ms);
        if (self.t1_armed and now_ms >= self.t1_at) r = self.onTimer(.t1, now_ms);
        return r;
    }

    // ---- 各状态收到 Commit ----

    /// Nothing + Com（12.4.8.6.3）。
    fn nothingOnCommit(self: *Instance, msg: CommitMsg, now_ms: u64) Result {
        // 状态不是 SUCCESS：静默丢弃，给父进程发 Del
        if (msg.status != status_success) return self.die(.del);
        const g = msg.group orelse return self.die(.del);
        if (g != group) {
            // 群不支持（BadGrp）：回 77，群字段填被拒绝的群，然后 Del
            self.last = .{ .unsupported_group = g };
            self.sendCommit();
            return self.die(.del);
        }
        self.sc = 0;
        self.rc = 0;
        self.generate() catch return self.die(.del);
        self.acceptPeerCommit(msg) catch return self.die(.del);
        self.sendCommit();
        self.sc += 1;
        self.sendConfirm();
        self.sync = 0;
        self.arm(.t0, now_ms);
        self.state = .confirmed;
        return .ok;
    }

    /// Committed + Com / Rej(N)（12.4.8.6.4）。
    fn committedOnCommit(self: *Instance, msg: CommitMsg, now_ms: u64) Result {
        self.disarm(.t0);
        if (msg.status == status_token_required) {
            // Rej(76)：带上 token，用原来发过的 commit-scalar / COMMIT-ELEMENT 重发
            const n: u16 = @intCast(msg.token.len);
            @memcpy(self.token[0..n], msg.token);
            self.token_len = n;
            self.last = .offer;
            self.sendCommit();
            self.sync = 0;
            self.arm(.t0, now_ms);
            return .ok;
        }
        if (msg.status == status_group_not_supported) {
            // Rej(77)：被拒绝的群不是我们给的，静默丢弃并重设 t0
            const rejected = msg.group orelse return self.waitT0(now_ms);
            if (rejected != group) return self.waitT0(now_ms);
            // 只配置了 group 19，没有别的群可换：Del，回 Nothing
            return self.die(.del);
        }
        if (msg.status != status_success) return self.waitT0(now_ms);

        const g = msg.group orelse return self.die(.del);
        if (g != group) {
            // 群不支持（BadGrp）：Sync 超限就放弃，否则回 77 并留在 Committed
            if (self.bigSync()) return self.die(.del);
            self.sync += 1;
            self.last = .{ .unsupported_group = g };
            self.sendCommit();
            return self.waitT0(now_ms);
        }
        // 群受支持且与我们用的一样（只支持一个群，DiffGrp 走不到）。
        // 反射攻击：对端的 scalar / element 与我们发出去的一样，静默丢弃并重设 t0
        const scalar = msg.scalar;
        const element = msg.element;
        if (scalar != null and element != null and
            std.mem.eql(u8, &scalar.?, &self.own_scalar) and
            std.mem.eql(u8, &element.?, &self.own_element.toBytes()))
        {
            return self.waitT0(now_ms);
        }
        self.acceptPeerCommit(msg) catch return self.die(.del);
        self.sc += 1; // 此时是 1
        self.sendConfirm();
        self.arm(.t0, now_ms);
        self.state = .confirmed;
        return .ok;
    }

    /// Confirmed + Com / Rej(N)（12.4.8.6.5）。
    fn confirmedOnCommit(self: *Instance, msg: CommitMsg, now_ms: u64) Result {
        self.disarm(.t0);
        if (msg.status != status_success) return self.waitT0(now_ms);
        if (self.bigSync()) return self.die(.del);
        const g = msg.group orelse return self.waitT0(now_ms);
        if (g != group) {
            // 原文只说「静默丢弃」。t0 刚被取消而 t1 还没设，照字面实例会永远停在
            // Confirmed，所以这里同样重设 t0。
            return self.waitT0(now_ms);
        }
        // 对端没收到我们的 Commit + Confirm：各发一遍，Confirm 带新的 Sc
        self.sync += 1;
        self.sc +|= 1;
        self.sendCommit();
        self.sendConfirm();
        self.arm(.t0, now_ms);
        return .ok;
    }

    /// Accepted + Con（12.4.8.6.6）。
    fn acceptedOnConfirm(self: *Instance, msg: ConfirmMsg) Result {
        // 原文没有写 Accepted 怎么处理拒绝帧，这里丢弃
        if (msg.status != status_success) return .discarded;
        if (self.bigSync()) return self.die(.del);
        // send-confirm 不大于 Rc 或等于 2^16 − 1：丢弃。等于 Rc 也算「不大于」
        if (msg.send_confirm <= self.rc or msg.send_confirm == sc_accepted) return .discarded;
        if (!self.confirmOk(msg)) return .discarded;
        self.rc = msg.send_confirm;
        self.sync += 1;
        self.sendConfirm();
        return .ok;
    }
};

// ---------------------------------------------------------------------------
// 4) 父进程（12.4.6、12.4.8.6.1）
// ---------------------------------------------------------------------------

pub const ParentConfig = struct {
    /// dot11RSNASAEAntiCloggingThreshold：Open 达到它就对新的 Commit 要 token。
    /// 0 表示一律要。默认值是 Annex C 的 DEFVAL（印刷页 2840）。
    anti_clogging_threshold: u16 = 5,
};

/// 父进程交给 SME 的事件（12.4.8.3.1）。
pub const ParentEvent = struct {
    peer: [6]u8,
    signal: Signal,
};

/// Commit 帧的前 8 个字节：头部 + 群字段。
fn putCommitHeader(out: *[header_len + group_len]u8, status: u16, g: u16) void {
    putHeader(out[0..header_len], seq_commit, status);
    std.mem.writeInt(u16, out[header_len..][0..group_len], g, .little);
}

/// 父进程：实例表、Open 计数、Anti-Clogging Token。
///
/// `slots` 是实例表的容量。同一个对端最多同时有两个实例（一个 Accepted、一个在进行中）。
/// 建好之后不要再按值拷贝（实例里存着指向 `env` 的指针）。
pub fn Parent(comptime slots: usize) type {
    return struct {
        const Self = @This();

        /// 交给 SME 的事件队列容量；满了丢新来的并计数。
        pub const event_capacity = 4;
        /// 自己生成的 Anti-Clogging Token 长度（HMAC-SHA-256 的输出）。
        pub const token_len = sae.hash_len;

        const Entry = struct {
            used: bool = false,
            inst: Instance = .{},
            /// 是否计入 Open：新建时计入，发出 Auth 或被删除时才减掉。
            counted: bool = false,
        };

        const Which = enum { in_progress, accepted };

        env: Env,
        cfg: ParentConfig,
        entries: [slots]Entry = @splat(.{}),
        /// Committed 或 Confirmed 状态的实例数（12.4.8.5.1）。
        open: u16 = 0,
        token_secret: [sae.hash_len]u8 = @splat(0),
        token_armed: bool = false,
        events: [event_capacity]ParentEvent = undefined,
        event_head: u8 = 0,
        event_len: u8 = 0,
        events_dropped: u32 = 0,

        pub fn init(env: Env, cfg: ParentConfig) Self {
            var self = Self{ .env = env, .cfg = cfg };
            self.syncToken();
            return self;
        }

        pub fn openCount(self: *const Self) u16 {
            return self.open;
        }

        /// Initiate（12.4.8.6.1）：该对端已有 Committed / Confirmed 的实例就忽略。
        /// 返回是否新建了实例。
        pub fn initiate(self: *Self, peer: [6]u8, now_ms: u64) bool {
            if (self.find(peer, .in_progress) != null) return false;
            const e = self.create(peer) orelse return false;
            const r = e.inst.start(now_ms);
            self.settle(e, peer, r);
            return true;
        }

        /// Kill（12.4.8.6.1）：删掉该对端的全部实例。
        pub fn kill(self: *Self, peer: [6]u8) void {
            for (&self.entries) |*e| {
                if (!e.used or !std.mem.eql(u8, &e.inst.peer_mac, &peer)) continue;
                if (e.inst.state == .committed or e.inst.state == .confirmed) self.open -= 1;
                e.* = .{};
            }
            self.syncToken();
        }

        /// 收到 SA 为 `peer` 的 Authentication 帧（只传帧体）。不是 SAE 帧就丢弃。
        pub fn receive(self: *Self, peer: [6]u8, body: []const u8, now_ms: u64) void {
            switch (decode(body) catch return) {
                .confirm => |msg| {
                    // 只有一个实例就交给它；有两个就交给不在 Accepted 的那个；没有就丢弃
                    if (self.find(peer, .in_progress) orelse self.find(peer, .accepted)) |e| {
                        const r = e.inst.onConfirm(msg, now_ms);
                        self.settle(e, peer, r);
                    }
                },
                .commit => |msg| {
                    if (self.find(peer, .in_progress)) |e| {
                        const r = e.inst.onCommit(msg, now_ms);
                        self.settle(e, peer, r);
                        return;
                    }
                    // 该对端只有 Accepted 的实例：peer-commit-scalar 与认证时用的相同就丢弃
                    if (self.find(peer, .accepted)) |e| {
                        if (msg.scalar) |s| {
                            if (std.mem.eql(u8, &s, &e.inst.peer_scalar)) return;
                        }
                    }
                    // Open 达到阈值：带 token 且 token 对才建实例；没带 token 就回 76 要一个
                    // （12.4.6、12.4.8.6.1）
                    if (self.open >= self.cfg.anti_clogging_threshold) {
                        if (msg.token.len > 0) {
                            if (!self.tokenOk(peer, msg.token)) return;
                        } else {
                            self.sendTokenRequest(peer, msg.group orelse group);
                            return;
                        }
                    }
                    const e = self.create(peer) orelse return;
                    const r = e.inst.onCommit(msg, now_ms);
                    self.settle(e, peer, r);
                },
            }
        }

        /// 推进时间：各实例到点的定时器依次触发。
        pub fn tick(self: *Self, now_ms: u64) void {
            for (&self.entries) |*e| {
                if (!e.used) continue;
                const peer = e.inst.peer_mac;
                const r = e.inst.poll(now_ms);
                self.settle(e, peer, r);
            }
        }

        /// 取一个待处理的事件。
        pub fn popEvent(self: *Self) ?ParentEvent {
            if (self.event_len == 0) return null;
            const ev = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % event_capacity;
            self.event_len -= 1;
            return ev;
        }

        /// 该对端处于 Accepted 的实例（PMK 与 PMKID 在里面）；没有就返回 null。
        pub fn accepted(self: *Self, peer: [6]u8) ?*const Instance {
            const e = self.find(peer, .accepted) orelse return null;
            return &e.inst;
        }

        /// 实例表里在用的条目数。
        pub fn instanceCount(self: *const Self) usize {
            var n: usize = 0;
            for (&self.entries) |*e| {
                if (e.used) n += 1;
            }
            return n;
        }

        // ---- 内部 ----

        fn find(self: *Self, peer: [6]u8, which: Which) ?*Entry {
            for (&self.entries) |*e| {
                if (!e.used or !std.mem.eql(u8, &e.inst.peer_mac, &peer)) continue;
                const hit = switch (which) {
                    .in_progress => e.inst.state == .committed or e.inst.state == .confirmed,
                    .accepted => e.inst.state == .accepted,
                };
                if (hit) return e;
            }
            return null;
        }

        /// 同一对端的另一个实例（12.4.8.6.1：收到 Auth 时删掉它）。
        fn findOther(self: *Self, peer: [6]u8, e: *Entry) ?*Entry {
            for (&self.entries) |*o| {
                if (o.used and o != e and std.mem.eql(u8, &o.inst.peer_mac, &peer)) return o;
            }
            return null;
        }

        /// 新建实例：置 Nothing、Open 加一、登记进实例表（12.4.8.6.1）。表满返回 null。
        fn create(self: *Self, peer: [6]u8) ?*Entry {
            for (&self.entries) |*e| {
                if (e.used) continue;
                e.* = .{};
                e.used = true;
                e.counted = true;
                e.inst.env = &self.env;
                e.inst.peer_mac = peer;
                self.open += 1;
                self.syncToken();
                return e;
            }
            return null;
        }

        /// 实例不再占用 Open 计数（12.4.8.6.1）。Accepted 的实例在发出 Auth 时
        /// 已经减过，之后再结束（Sync 超限、t1 到点）不再减。
        fn release(self: *Self, e: *Entry) void {
            if (!e.counted) return;
            e.counted = false;
            self.open -= 1;
        }

        /// 实例发出 Fail / Del：删除实例。发出 Auth：实例留在 Accepted，
        /// 并删掉同一对端的另一个实例（12.4.8.6.1）。
        fn settle(self: *Self, e: *Entry, peer: [6]u8, r: Result) void {
            const signal: Signal = switch (r) {
                .ok, .discarded => return,
                .auth => blk: {
                    self.release(e);
                    if (self.findOther(peer, e)) |other| other.* = .{};
                    break :blk .auth;
                },
                .fail => blk: {
                    self.release(e);
                    e.* = .{};
                    break :blk .fail;
                },
                .del => blk: {
                    self.release(e);
                    e.* = .{};
                    break :blk .del;
                },
            };
            self.syncToken();
            if (self.event_len == event_capacity) {
                self.events_dropped += 1;
                return;
            }
            self.events[(self.event_head + self.event_len) % event_capacity] = .{ .peer = peer, .signal = signal };
            self.event_len += 1;
        }

        /// Open 达到阈值时换一个新的随机秘密（12.4.6 的 NOTE）；降回阈值以下就作废。
        fn syncToken(self: *Self) void {
            if (self.open < self.cfg.anti_clogging_threshold) {
                self.token_armed = false;
                self.token_secret = @splat(0);
            } else if (!self.token_armed) {
                self.env.random(&self.token_secret);
                self.token_armed = true;
            }
        }

        /// token = H(secret, 发送者的 MAC)，不存状态就能验证（12.4.6）。
        fn makeToken(self: *const Self, peer: [6]u8, out: *[token_len]u8) void {
            var ctx = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.token_secret);
            ctx.update(&peer);
            ctx.final(out);
        }

        fn tokenOk(self: *const Self, peer: [6]u8, token: []const u8) bool {
            if (token.len != token_len) return false;
            var want: [token_len]u8 = undefined;
            self.makeToken(peer, &want);
            return std.crypto.timing_safe.eql([token_len]u8, want, token[0..token_len].*);
        }

        /// 回一个状态 76 的 Commit：群字段 || token（12.4.7.6、表 9-36）。
        fn sendTokenRequest(self: *Self, peer: [6]u8, g: u16) void {
            var body: [header_len + group_len + token_len]u8 = undefined;
            putCommitHeader(body[0 .. header_len + group_len], status_token_required, g);
            self.makeToken(peer, body[header_len + group_len ..][0..token_len]);
            self.env.emit.frame(self.env.emit.ctx, peer, &body);
        }
    };
}
