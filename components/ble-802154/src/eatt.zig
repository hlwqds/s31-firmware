//! ble-802154：EATT bearer 池——一条 LE 连接上的多条 Enhanced ATT bearer。
//!
//! 规范出处（Bluetooth Core Specification v5.4，行号：GATT 指
//! `/tmp/spec/Core-54-generic-attribute-profile--gatt-.txt`，ATT 指
//! `/tmp/spec/Core-54-attribute-protocol--att-.txt`）：
//!   * [Vol 3] Part G §5.3（3151–3155）：LE 上的 Enhanced ATT bearer 用 Enhanced Credit
//!     Based Flow Control Mode 的信道，经 L2CAP_CREDIT_BASED_CONNECTION_REQ 建立，用 EATT
//!     的固定 PSM（Assigned Numbers：0x0027）；一个 client 与一个 server 之间可以建立
//!     多条 L2CAP 信道；
//!   * §5.3.1（3156–3159）：ATT_MTU 是两端 MTU 字段的较小者，值来自 REQ / RSP 或最新的
//!     L2CAP_CREDIT_BASED_RECONFIGURE_REQ；Enhanced ATT bearer 的 ATT_MTU 最小是 64；
//!   * §5.3.2（3160–3165）：这条信道上的所有包都是 ATT PDU；K-frame 的信息载荷是单个
//!     ATT PDU；信道应加密；
//!   * [Vol 3] Part F §3.2.8（ATT 文本 2152–2156）：动态 CID 上 ATT_MTU 就是 L2CAP MTU；
//!     ATT_MTU 是每条 bearer 一个值；
//!   * §3.2.11（2169–2178）：跑在 Enhanced Credit Based Flow Control Mode 上的 bearer 叫
//!     Enhanced ATT bearer，除明确写明的地方外，行为与别的 bearer 相同；
//!   * §3.3.2（2255–2277）：同一 bearer 上一笔请求没收到响应前不得再发请求；一笔指示
//!     没收到确认前不得再发指示；Enhanced ATT bearer 上的通知必须处理；
//!   * §3.3.3（2278–2288）：一笔事务只在一条 bearer 上，不跨 bearer；30 秒没完成就超时，
//!     之后这条 bearer 上不再收发 ATT PDU，要再发就得另建 bearer；bearer 在事务中被
//!     终止，事务算关闭。
//!   * L2CAP 侧（信令、额度、分段重组）在 `l2cap_coc.zig`。
//!
//! 与本机 NimBLE 交叉核对过（`~/esp/esp-idf/components/bt/host/nimble/nimble/nimble/host/src/`）：
//!   * `ble_eatt.c` 397–398（用 enhanced connect、PSM 0x0027 建信道）、319–323（空 SDU
//!     断开）、327–338（不是 ATT 操作码就断开）、353–357（没加密就断开，都引 Part G
//!     §5.3.2）、559–584（挑一条空闲的 bearer，没有就退回 CID 0x0004）；
//!   * `ble_att.c` 501–513（EATT 的 ATT_MTU = min(tx.mtu, rx.mtu)，引 Part G §5.3.1）；
//!   * `ble_eatt_priv.h` 29（`BLE_EATT_PSM` 0x0027）。
//!
//! `Pool(cfg, App)` 是一条连接上的全部 bearer：L2CAP 部分是 `l2cap_coc.Link`，上面加
//! 四样 ATT 特有的东西——每条 bearer 自己的 ATT_MTU、SDU 必须是 ATT PDU、必须加密、
//! 每条 bearer 一笔事务与 30 秒超时。`App` 是 ATT 的落点：`onAttPdu()` 吃一个完整的
//! ATT PDU、吐应答。`ServerAtt()` 把 `att_server` 的 server 端（加上 Robust Caching）
//! 接上来。
//!
//! 实现限制（都是本组件的取舍，不是规范要求）：每条 bearer 只有一个待发的 ATT PDU
//! 位置，挤不进去的应答返回 `Busy`；CID 固定是 `0x0040 + 槽位`；不发 L2CAP 的
//! DISCONNECTION 请求，bearer 被本端关闭时对端要到用满额度、或发来 K-frame 被拒之后
//! 才知道。
//!
//! 没有分配、没有全局状态。对象比较大（每条 bearer 两个 `sdu_max` 的缓冲），板侧放在
//! 文件作用域。

const std = @import("std");
const att = @import("att.zig");
const l2cap = @import("l2cap.zig");
const svr = @import("att_server.zig");
const coc = @import("l2cap_coc.zig");
const rc = @import("robust_cache.zig");

/// EATT 的 SPSM。Assigned Numbers：EATT，PSM or SPSM。
pub const spsm_eatt: u16 = coc.spsm_eatt;
/// Enhanced ATT bearer 的 ATT_MTU 最小值。[Vol 3] Part G §5.3.1。
pub const min_att_mtu: u16 = coc.ecoc_min_mtu;
/// ATT 事务超时。[Vol 3] Part F §3.3.3：30 秒。
pub const transaction_timeout_ms: u32 = svr.transaction_timeout_ms;

pub const Config = struct {
    /// 这条连接上最多几条 bearer。LE-U 的动态 CID 一共 64 个（表 2.3）。
    bearers: usize = 3,
    /// 每条 bearer 的接收缓冲大小，也是本端 MTU 的上限。
    sdu_max: usize = 256,
    /// 本端给每条信道的初始额度。
    credits: u16 = 8,
};

/// 一条 bearer 上在途的事务。
pub const Tx = enum { none, request, indication };

/// EATT bearer 池。
///
/// `App` 要有：
///   ```zig
///   pub const Error = error{ ... };
///   pub fn onAttPdu(self: *App, bearer: u8, att_mtu: u16, pdu: []const u8, out: []u8) Error!usize;
///   // 可选：bearer 被关闭（§3.3.3：它上面的事务算关闭）。
///   pub fn onBearerClosed(self: *App, bearer: u8) void;
///   ```
pub fn Pool(comptime cfg: Config, comptime App: type) type {
    // 槽位数的上限（64，即 LE-U 的动态 CID 范围，表 2.3）在 `Link` 里查。
    return struct {
        const Self = @This();

        pub const Link = coc.Link(cfg.bearers, cfg.sdu_max);
        pub const Error = coc.Error || App.Error || error{
            /// SDU 的第一个字节不是 ATT 操作码（§5.3.2）：关闭这条 bearer。
            NotAtt,
            /// 链路没加密就在收发 ATT PDU（§5.3.2）。
            NotEncrypted,
            /// ATT PDU 比这条 bearer 的 ATT_MTU 长（[Vol 3] Part F §3.2.8）。
            TooLong,
            /// 同一 bearer 上一笔请求还没收到响应（§3.3.2）。
            RequestPending,
            /// 同一 bearer 上一笔指示还没收到确认（§3.3.2）。
            IndicationPending,
        };

        link: Link,
        app: App,
        /// 链路是否已加密。由上层在加密完成后置位。
        encrypted: bool = false,
        /// 当前毫秒数，`tick()` 更新。
        now_ms: u32 = 0,
        /// 在途的事务（§3.3.2、§3.3.3）：请求与指示各最多一笔，可以同时在途；值是开始
        /// 时刻（毫秒），null 表示没有。
        req_at: [cfg.bearers]?u32 = @splat(null),
        ind_at: [cfg.bearers]?u32 = @splat(null),
        /// 每条 bearer 待发的那个 ATT PDU。
        out: [cfg.bearers][cfg.sdu_max]u8 = undefined,
        out_len: [cfg.bearers]u16 = @splat(0),
        /// App 写应答的地方；应答随即拷进 `out`。
        att_buf: [cfg.sdu_max]u8 = undefined,

        /// 初始化：SPSM 固定是 EATT，只接受 L2CAP_CREDIT_BASED_CONNECTION_REQ（§5.3），
        /// 建信道要求链路已加密（§5.3.2）。`rx_mtu` / `rx_mps` 是本端每条 bearer 能收的
        /// 上限，至少 64（§4.25）；MTU 装不进缓冲 → `NoSpace`。
        pub fn init(self: *Self, app: App, rx_mtu: u16, rx_mps: u16) Error!void {
            self.* = .{ .link = .{}, .app = app };
            self.link.legacy_ok = false;
            self.link.need = .{ .encrypted = true };
            try self.link.setParams(.{ .mtu = rx_mtu, .mps = rx_mps, .credits = cfg.credits });
        }

        /// 这条 bearer 的 ATT_MTU：两端 MTU 的较小者（§5.3.1）。重配置之后自动跟着变。
        pub fn attMtu(self: *const Self, i: usize) u16 {
            const c = &self.link.chans[i];
            return @min(c.rx_mtu, c.tx_mtu);
        }

        pub fn established(self: *const Self, i: usize) bool {
            return self.link.chans[i].established();
        }

        pub fn pending(self: *const Self, i: usize) Tx {
            if (self.req_at[i] != null) return .request;
            return if (self.ind_at[i] != null) .indication else .none;
        }

        /// 本端关闭一条 bearer。它上面在途的事务算关闭（§3.3.3）。
        pub fn close(self: *Self, i: usize) void {
            const was = self.link.chans[i].used();
            self.link.close(i);
            self.out_len[i] = 0;
            self.req_at[i] = null;
            self.ind_at[i] = null;
            if (was) {
                if (@hasDecl(App, "onBearerClosed")) self.app.onBearerClosed(@intCast(i));
            }
        }

        /// 链路断开：全部 bearer 没了。
        pub fn disconnect(self: *Self) void {
            self.link.disconnect();
            self.out_len = @splat(0);
            self.req_at = @splat(null);
            self.ind_at = @splat(null);
        }

        /// L2CAP 那边因为对端违规关掉信道之后，这里把待发与事务状态一并对齐。
        fn sync(self: *Self) void {
            for (&self.link.chans, 0..) |*c, i| {
                if (!c.established() and (self.out_len[i] != 0 or self.pending(i) != .none)) {
                    self.out_len[i] = 0;
                    self.req_at[i] = null;
                    self.ind_at[i] = null;
                }
            }
        }

        // -----------------------------------------------------------------
        // 信令
        // -----------------------------------------------------------------

        /// 发起端：发 L2CAP_CREDIT_BASED_CONNECTION_REQ，建 `n` 条 bearer（1–5）。
        pub fn connect(self: *Self, out: []u8, n: u8) Error!usize {
            return self.link.connect(out, n);
        }

        /// 发起端：重配置，本端以后能收 MTU / MPS。`cids` 是本端 CID。
        pub fn reconfigure(self: *Self, out: []u8, cids: []const u16, mtu: u16, mps: u16) Error!usize {
            return self.link.reconfigure(out, cids, mtu, mps);
        }

        /// 处理对端的一条信令 C-frame（两个角色都可能收到）。应答写进 `out`。
        pub fn onSignal(self: *Self, pdu: []const u8, out: []u8) Error!coc.Outcome {
            const o = try self.link.onSignal(pdu, out);
            self.sync();
            return o;
        }

        /// 把欠对端的额度还回去（§4.24）。没有欠的返回 null。
        pub fn flushCredits(self: *Self, out: []u8) Error!?usize {
            return self.link.flushCredits(out);
        }

        // -----------------------------------------------------------------
        // 数据
        // -----------------------------------------------------------------

        /// 收一个 K-frame。一个完整的 SDU 就是一个 ATT PDU（§5.3.2），交给 `App`；它的
        /// 应答从同一条 bearer 发回去（§3.3.3：事务不跨 bearer）。返回值是这条应答的第
        /// 一个 K-frame 的长度，没有（或还没收全）返回 null。
        ///
        /// 关闭这条 bearer 并返回错误的情况：没加密（§5.3.2）、SDU 不是 ATT PDU（§5.3.2）、
        /// K-frame 违规（§3.4.3、§10.1，见 `Chan.receive`）。
        pub fn onKframe(self: *Self, kframe: []const u8, out: []u8) Error!?usize {
            if (kframe.len < l2cap.header_len) return error.Short;
            const cid = l2cap.Header.decode(kframe[0..l2cap.header_len]).cid;
            const i = Link.slotOf(cid) orelse return error.NoChannel;
            if (!self.link.chans[i].established()) return error.NoChannel;
            if (!self.encrypted) {
                // §5.3.2：The channel shall be encrypted。没加密就送来数据，这条 bearer 不能用
                // （NimBLE：ble_eatt.c 353–357）。
                self.close(i);
                return error.NotEncrypted;
            }
            const sdu = switch (self.link.receive(i, kframe) catch |e| {
                self.close(i);
                return e;
            }) {
                .partial => return null,
                .complete => |s| s,
            };
            const op = if (sdu.len == 0) null else att.Op.fromByte(sdu[0]);
            if (op == null) {
                self.close(i);
                return error.NotAtt;
            }
            // 响应结束在途的请求，确认结束在途的指示（§3.3.3）。
            switch (op.?.kind()) {
                .response => self.req_at[i] = null,
                .confirmation => self.ind_at[i] = null,
                else => {},
            }
            const n = try self.app.onAttPdu(@intCast(i), self.attMtu(i), sdu, &self.att_buf);
            if (n == 0) return null;
            return try self.enqueue(i, self.att_buf[0..n], out);
        }

        /// `App` 主动发一个 ATT PDU（请求、命令、通知、指示）。PDU 被拷进池里，调用方的
        /// 缓冲可以马上复用。返回第一个 K-frame 的长度；额度为 0 时 PDU 留在池里、返回 null
        /// （§10.1），之后用 `pull()` 取。待发位置被占 → `Busy`。
        pub fn send(self: *Self, i: usize, pdu: []const u8, out: []u8) Error!?usize {
            if (!self.link.chans[i].established()) return error.NoChannel;
            if (!self.encrypted) return error.NotEncrypted;
            return try self.enqueue(i, pdu, out);
        }

        fn enqueue(self: *Self, i: usize, pdu: []const u8, out: []u8) Error!?usize {
            const c = &self.link.chans[i];
            if (pdu.len == 0 or att.Op.fromByte(pdu[0]) == null) return error.NotAtt;
            if (pdu.len > self.attMtu(i)) return error.TooLong;
            if (c.sending() or self.out_len[i] != 0) return error.Busy;
            // 第一个 K-frame 得写得下：SDU Length + 不超过 MPS 的那一段。
            const first: usize = 2 + @min(pdu.len, @as(usize, c.tx_mps) - 2);
            if (out.len < l2cap.header_len + first) return error.NoSpace;
            // §3.3.2：同一 bearer 上，请求是顺序的，指示也是顺序的；两者可以同时在途。
            switch (att.Op.fromByte(pdu[0]).?.kind()) {
                .request => {
                    if (self.req_at[i] != null) return error.RequestPending;
                    self.req_at[i] = self.now_ms;
                },
                .indication => {
                    if (self.ind_at[i] != null) return error.IndicationPending;
                    self.ind_at[i] = self.now_ms;
                },
                else => {},
            }
            @memcpy(self.out[i][0..pdu.len], pdu);
            self.out_len[i] = @intCast(pdu.len);
            return try self.pull(i, out);
        }

        /// 取这条 bearer 的下一个 K-frame。当前 PDU 已发完、或者额度用光（§10.1：额度
        /// 为 0 不得发，PDU 留在池里等额度，见 `flushCredits` / `onSignal`）都返回 null。
        pub fn pull(self: *Self, i: usize, out: []u8) Error!?usize {
            if (self.out_len[i] == 0) return null;
            const c = &self.link.chans[i];
            if (!c.sending()) try c.startSend(self.out[i][0..self.out_len[i]]);
            const n = c.sendNext(out) catch |e| switch (e) {
                error.NoCredits => return null,
                else => return e,
            };
            if (!c.sending()) self.out_len[i] = 0;
            return n;
        }

        /// 这条 bearer 上还有 ATT PDU 没发完，而且卡在额度上。
        pub fn stalled(self: *const Self, i: usize) bool {
            return self.out_len[i] != 0 and self.link.chans[i].tx_credits == 0;
        }

        /// 周期调用。有事务等了 30 秒还没结束 → 这条 bearer 关闭（§3.3.3），返回它；
        /// 否则返回 null。
        pub fn tick(self: *Self, now_ms: u32) ?usize {
            self.now_ms = now_ms;
            for (self.req_at, self.ind_at, 0..) |r, d, i| {
                const started: ?u32 = if (r != null) r else d;
                if (started != null and now_ms -% started.? >= transaction_timeout_ms) {
                    self.close(i);
                    return i;
                }
            }
            return null;
        }
    };
}

/// 把 `att_server` 的 server 端接到 `Pool` 上：`peer` 是这个 client 在 ATT 层的状态，
/// `aware` 是它的 Robust Caching 状态。几个 bearer 共用一个 `peer`：按
/// client 保存的东西（CCCD、CSF、排队写、CSRK）本来就是每 client 一份；每条 bearer
/// 自己的 ATT_MTU 在调 `onPdu()` 的那一会儿设进 `peer.mtu`。
pub fn ServerAtt(comptime Db: type, comptime queue: usize, comptime bearers: usize) type {
    return struct {
        const Self = @This();

        pub const Error = svr.Error;

        db: *Db,
        peer: Db.Peer(queue) = .{},
        aware: rc.Aware(bearers) = .{},
        /// Client Supported Features 的值放在哪个按 client 的槽位。
        csf_slot: u8,
        /// 这个客户端现在是不是只用一条 ATT bearer（§2.5.2.1 里两条只对「exactly one
        /// ATT bearer」成立的规则用到它）。
        one_bearer: bool = true,
        stats: struct { out_of_sync: u32 = 0, dropped: u32 = 0 } = .{},

        pub fn init(self: *Self, db: *Db, csf_slot: u8) void {
            self.* = .{ .db = db, .csf_slot = csf_slot };
        }

        /// 链路连上（或重新连上）：ATT 状态复位，Robust Caching 的初始状态按信任关系定
        /// （§2.5.2.1：非信任的客户端一开始 change-aware）。
        pub fn onConnect(self: *Self, trusted: bool) void {
            self.peer.reset();
            self.aware.onConnect(trusted);
        }

        pub fn onDisconnect(self: *Self) void {
            self.aware.onDisconnect();
        }

        pub fn csfOf(self: *const Self) rc.Csf {
            const s = &self.peer.slots[self.csf_slot];
            // §7.2：还没写过就是默认的全零。
            if (!s.set) return .{ .n = 1 };
            return rc.Csf.init(s.data[0..s.len]);
        }

        pub fn onAttPdu(self: *Self, bearer: u8, att_mtu: u16, pdu: []const u8, out: []u8) Error!usize {
            switch (self.aware.onRequest(bearer, pdu, self.csfOf(), self.one_bearer)) {
                .allow => {
                    // Robust Caching 之外，ATT 的处理与 Unenhanced bearer 相同（Part F §3.2.11）；
                    // 只有 ATT_MTU 是这条 bearer 自己的（§3.2.8、Part G §5.3.1）。
                    const saved_mtu = self.peer.mtu;
                    const saved_exchanged = self.peer.mtu_exchanged;
                    self.peer.mtu = att_mtu;
                    defer {
                        self.peer.mtu = saved_mtu;
                        self.peer.mtu_exchanged = saved_exchanged;
                    }
                    return self.peer.onPdu(self.db, pdu, out);
                },
                .out_of_sync => {
                    // §2.5.2.1：回 0x12，出错句柄取请求里的句柄（§3.4.1.1）。
                    const b = rc.blocked(pdu).?;
                    self.stats.out_of_sync += 1;
                    return att.encodeError(out, b.op, b.handle, .database_out_of_sync, &self.peer.att);
                },
                .drop => {
                    self.stats.dropped += 1;
                    return 0;
                },
            }
        }

        /// bearer 被关闭：等确认的那笔指示算关闭（§3.3.3）。
        pub fn onBearerClosed(self: *Self, bearer: u8) void {
            _ = bearer;
            self.peer.indicating = false;
        }
    };
}
