//! ble-802154：GATT 客户端过程——发现、读、写、可靠写、通知与指示的接收。
//!
//! 规范出处（Bluetooth Core Specification v5.4，[Vol 3] Part G）：
//!   * Exchange MTU —— §4.3.1；
//!   * Discover All Primary Services —— §4.4.1；Discover Primary Services by Service UUID —— §4.4.2；
//!   * Find Included Services —— §4.5.1；
//!   * Discover All Characteristics of a Service —— §4.6.1；Discover Characteristics by UUID —— §4.6.2；
//!   * Discover All Characteristic Descriptors —— §4.7.1；
//!   * Read Characteristic Value —— §4.8.1；Read Using Characteristic UUID —— §4.8.2；
//!     Read Long Characteristic Values —— §4.8.3；Read Multiple Characteristic Values —— §4.8.4；
//!     Read Multiple Variable Length Characteristic Values —— §4.8.5；
//!   * Write Without Response —— §4.9.1；Signed Write Without Response —— §4.9.2；
//!     Write Characteristic Value —— §4.9.3；Write Long Characteristic Values —— §4.9.4；
//!     Characteristic Value Reliable Writes —— §4.9.5；
//!   * Notifications —— §4.10；Indications —— §4.11；
//!   * 读、写特征描述符 —— §4.12.1–§4.12.4（用的 ATT PDU 与读、写特征值相同，只是句柄
//!     指向描述符）；
//!   * 过程用到的 ATT 操作码 —— §4.13 表 4.2；过程超时 —— §4.14；
//!   * LE 的默认 ATT_MTU 23 —— §5.2.1 表 5.1。
//!   ATT 这一侧的规则（顺序协议、30 秒事务超时、收到指示要回确认）在 [Vol 3] Part F
//!   §3.3.2、§3.3.3、§3.4.7.2；签名在 §3.4.5.4 与 [Vol 3] Part H §2.4.5（实现在 `cmac.zig`）。
//!
//! 一个 `Client(cfg)` 是一条 ATT bearer 上客户端这一半的状态机，不用分配器、不记时间：
//!
//!   * `start…()` 一族编码过程的第一个请求（返回写进 out 的字节数），或者立刻给出本地
//!     错误（已有过程在进行、值长于 ATT_MTU 允许的长度、参数不合法）；
//!   * 对端每发来一个 PDU 就调一次 `onPdu()`：它处理响应、把下一步请求写进 out、把结果
//!     攒进定长数组；返回值说明过程是继续、完成还是失败，或者只是收到了一条通知 / 指示；
//!   * `tick()` 传入当前毫秒数，等响应超过 30 秒 → 过程失败，这条 bearer 作废（§3.3.3：
//!     之后不能再在上面收发）。
//!
//! ATT_MTU 对各过程的约束都落在这里：协商结果 `mtu` 决定一条 Write Request / Command 最多
//! 带多少字节（超出 → 本地错误 `TooLong`，改用写长值）、排队写每段多大、Read Long 何时
//! 读到头（§4.8.3：最后一段短于 ATT_MTU−1），以及 server 每个响应能装几条结果（所以
//! 同样的发现在不同的 MTU 下要发不同次数的请求）。
//!
//! 规范没写死、这里定下来的（逐条见 README 的「实现偏离」）：
//!
//!   * 排队写中途收到 ATT_ERROR_RSP：只要已经有数据排进 server 的队列，就补发一条取消
//!     （Execute Write，Flags = 0x00），等它的响应回来这条 bearer 才空闲；
//!   * server 的响应结构不对（条目装不下整数条、句柄乱序、UUID 不是 2 或 16 字节、
//!     与当前过程无关的响应）→ 过程按协议错误失败；
//!   * Read Using Characteristic UUID 收到 Attribute Not Found 按失败处理（§4.8.2：说明
//!     这个 UUID 在范围内不存在），由调用方看 `error_rsp` 决定；各发现过程收到
//!     Attribute Not Found 是正常结束。

const std = @import("std");
const att = @import("att.zig");
const cmac = @import("cmac.zig");

/// 事务超时（[Vol 3] Part F §3.3.3）与过程超时（[Vol 3] Part G §4.14）：30 秒。
pub const timeout_ms: u32 = 30_000;

pub const Status = enum {
    /// 上一个过程成功结束。
    ok,
    /// server 回了 ATT_ERROR_RSP，看 `error_rsp`。
    att_error,
    /// 等响应超过 30 秒。
    timeout,
    /// server 的响应结构不对或与过程无关，看 `last_err`。
    protocol,
    /// 本地原因（结果数组或值缓冲放不下），看 `last_err`。
    local,
};

/// 一次 `onPdu()` 的结果。
pub const Outcome = enum {
    /// 过程继续，`out_len` 是下一个请求。
    pending,
    /// 过程成功结束。
    done,
    /// 过程失败，看 `status`。`out_len` 可以非零：排队写失败时是取消请求。
    failed,
    /// 取消请求得到了应答，这条 bearer 重新空闲。
    closed,
    /// 收到一条通知，过程照旧进行（或本来就没有过程）。
    notify,
    /// 收到一条指示，确认已写进 out。
    indicate,
    /// 收到一条 Multiple Variable Length Notification（[Vol 3] Part G §4.10.2）：各条的
    /// 句柄与值用 `Step.multi` 逐条取。
    multi,
    /// 与当前无关的 PDU，丢弃。
    ignored,
};

pub const Step = struct {
    outcome: Outcome,
    /// 写进 out 的字节数；0 表示没有要发的。
    out_len: usize = 0,
    /// 收到通知 / 指示时的句柄与值。`value` 指向传给 `onPdu()` 的那个 PDU。
    event: ?att.WriteReq = null,
    /// `outcome == .multi` 时有效：通知里的元组列表。
    multi: ?att.MultiNtf = null,
};

pub const Error = att.Error || error{
    /// 已有过程在等响应（§3.3.2：响应回来之前不能发下一个请求）。
    Busy,
    /// MTU 交换每个连接只能做一次（§4.3.1）。
    AlreadyExchanged,
    /// 本端能接收的 MTU 小于默认值。
    MtuTooSmall,
    /// 参数不合法：句柄范围为空、句柄少于两个。
    BadParam,
    /// 值长于 ATT_MTU 允许这条 PDU 带的长度，或长于值缓冲。
    TooLong,
    /// 这条 bearer 上有事务超时过，不能再用。
    Dead,
    /// Reliable Write：ATT_PREPARE_WRITE_RSP 与请求不一致（§4.9.5）。
    Mismatch,
};

/// `Client()` 的容量。结果放在定长数组里，放不下时过程按本地错误失败。
pub const Config = struct {
    services: usize = 8,
    includes: usize = 4,
    chars: usize = 16,
    descs: usize = 16,
    /// Read、Read Long、Read Multiple 装值的缓冲。
    value: usize = 128,
    /// Write Long、Reliable Write 装值的缓冲（值会拷进来）。
    write: usize = 128,
    /// Read Multiple 的句柄数、Read Using UUID 与 Read Multiple Variable 的结果条数上限。
    handles: usize = 8,
};

pub fn Client(comptime cfg: Config) type {
    if (cfg.value == 0 or cfg.value > 0xFFFF or cfg.write == 0 or cfg.write > 0xFFFF or cfg.handles == 0) {
        @compileError("Config: value / write 在 1..65535，handles 至少 1");
    }
    return struct {
        const Self = @This();

        pub const Service = struct { start: u16, end: u16, uuid: att.Uuid };
        /// 包含声明。被包含的服务是 128 位 UUID 时 `uuid` 为 null：规范不把 128 位 UUID
        /// 放进包含声明，要另外读（§3.2、§4.5.1）。
        pub const Include = struct { handle: u16, service: u16, end: u16, uuid: ?att.Uuid };
        pub const Char = struct { decl: u16, value: u16, props: u8, uuid: att.Uuid };
        pub const Desc = struct { handle: u16, uuid: att.Uuid };
        /// Read Using Characteristic UUID 的一条命中，或 Read Multiple Variable 的一个元组
        /// （此时 `handle` 为 0）：值在 `value[off..][0..present]`；`present` 小于 `len`
        /// 表示被 ATT_MTU 截断（§3.4.4.12 注）。
        pub const Hit = struct { handle: u16, off: u16, len: u16, present: u16 };

        pub const Stats = struct {
            started: u32 = 0,
            completed: u32 = 0,
            failed: u32 = 0,
            requests: u32 = 0,
            events: u32 = 0,
            ignored: u32 = 0,
            timeouts: u32 = 0,
        };

        const Primary = struct { next: u16 };
        const PrimaryUuid = struct { uuid: att.Uuid, next: u16 };
        /// `next` 是下一条请求的起始句柄（最后处理过的声明句柄 + 1）；`want` 是正在补读
        /// 128 位 UUID 的那条包含声明的下标。
        const Included = struct { next: u16, end: u16, want: ?u8 };
        const Chars = struct { next: u16, end: u16, filter: ?att.Uuid };
        const Descs = struct { next: u16, end: u16 };
        /// `exec`：Execute Write 已经发出，在等它的响应。
        const Queued = struct { exec: bool };

        const State = union(enum) {
            idle,
            mtu,
            disc_primary: Primary,
            disc_primary_uuid: PrimaryUuid,
            find_included: Included,
            disc_chars: Chars,
            disc_descs: Descs,
            read,
            read_uuid,
            read_long,
            read_multiple,
            read_multiple_var,
            /// Write Characteristic Value：等 ATT_WRITE_RSP。
            write,
            /// Write Long / Reliable Write。
            queued: Queued,
            /// 取消排队写的请求已发出，在等 ATT_EXECUTE_WRITE_RSP。
            canceling,
        };

        /// 本端能接收的最大 ATT PDU（Exchange MTU 请求里报的 Client Rx MTU）。
        rx_mtu: u16 = att.default_mtu,
        /// 生效的 ATT_MTU：交换之前是默认值 23。
        mtu: u16 = att.default_mtu,
        mtu_exchanged: bool = false,
        state: State = .idle,
        sent_at: u32 = 0,
        /// 事务超时过。之后一切收发都拒绝，直到调用方 `reset()`。
        dead: bool = false,

        status: Status = .ok,
        /// `status == .att_error` 时有效。
        error_rsp: att.ErrorRsp = .{ .req_op = 0, .handle = 0, .code = 0 },
        /// `status` 是 `.protocol` 或 `.local` 时有效。
        last_err: ?anyerror = null,

        /// 正在读、写的属性的句柄。
        handle: u16 = 0,
        /// 排队写的值（已拷进来）、总长、已经被 server 确认收下的字节数。
        wbuf: [cfg.write]u8 = undefined,
        wlen: usize = 0,
        woffset: usize = 0,
        /// Reliable Write：每条 ATT_PREPARE_WRITE_RSP 都要与发出去的请求逐字节一致。
        wverify: bool = false,

        services: [cfg.services]Service = undefined,
        service_count: usize = 0,
        includes: [cfg.includes]Include = undefined,
        include_count: usize = 0,
        chars: [cfg.chars]Char = undefined,
        char_count: usize = 0,
        descs: [cfg.descs]Desc = undefined,
        desc_count: usize = 0,
        hits: [cfg.handles]Hit = undefined,
        hit_count: usize = 0,
        value: [cfg.value]u8 = undefined,
        value_len: usize = 0,

        stats: Stats = .{},
        att: att.Stats = .{},

        pub fn reset(self: *Self) void {
            const rx = self.rx_mtu;
            self.* = .{ .rx_mtu = rx };
        }

        fn begin(self: *Self) Error!void {
            if (self.dead) return error.Dead;
            if (self.state != .idle) return error.Busy;
            self.status = .ok;
            self.last_err = null;
        }

        fn finish(self: *Self) Step {
            self.state = .idle;
            self.stats.completed += 1;
            return .{ .outcome = .done };
        }

        fn fail(self: *Self, why: Status, err: ?anyerror, out: []u8) Step {
            self.status = why;
            self.last_err = err;
            self.stats.failed += 1;
            // 排队写中途失败：已经有数据排进 server 的队列，就补发一条取消。
            const preparing = switch (self.state) {
                .queued => |q| !q.exec and self.woffset > 0,
                else => false,
            };
            if (preparing) return self.cancelNow(out);
            self.state = .idle;
            return .{ .outcome = .failed };
        }

        fn cancelNow(self: *Self, out: []u8) Step {
            self.state = .canceling;
            const n = att.encodeExecuteWriteReq(out, .cancel, &self.att) catch 0;
            return .{ .outcome = .failed, .out_len = n };
        }

        // -----------------------------------------------------------------
        // Server Configuration
        // -----------------------------------------------------------------

        /// Exchange MTU（§4.3.1）。每个连接只能做一次；协商结果 = min(Client Rx MTU,
        /// Server Rx MTU)。server 回 Request Not Supported 时过程照样算完成，ATT_MTU 取
        /// 默认值。
        pub fn exchangeMtu(self: *Self, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (self.mtu_exchanged) return error.AlreadyExchanged;
            if (self.rx_mtu < att.default_mtu) return error.MtuTooSmall;
            const n = try att.encodeMtuReq(out, self.rx_mtu, &self.att);
            self.state = .mtu;
            self.mtu_exchanged = true;
            self.markSent(now_ms);
            return n;
        }

        fn markSent(self: *Self, now_ms: u32) void {
            self.sent_at = now_ms;
            self.stats.requests += 1;
            self.stats.started += 1;
        }

        // -----------------------------------------------------------------
        // Primary Service Discovery
        // -----------------------------------------------------------------

        /// Discover All Primary Services（§4.4.1）：从 0x0001 到 0xFFFF，按 End Group Handle
        /// 分页，直到 Attribute Not Found 或某个 End Group Handle 是 0xFFFF。结果在 `services`。
        pub fn discoverPrimaryServices(self: *Self, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            self.service_count = 0;
            self.state = .{ .disc_primary = .{ .next = 0x0001 } };
            const n = try self.groupReq(0x0001, out);
            self.markSent(now_ms);
            return n;
        }

        fn groupReq(self: *Self, start: u16, out: []u8) Error!usize {
            return att.encodeReadByGroupReq(out, .{
                .range = .{ .start = start, .end = 0xFFFF },
                .uuid = .{ .u16 = 0x2800 },
            }, &self.att);
        }

        /// Discover Primary Services by Service UUID（§4.4.2）。结果在 `services`，范围来自
        /// Find By Type Value 的 Handles Information。
        pub fn discoverPrimaryServicesByUuid(self: *Self, uuid: att.Uuid, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            self.service_count = 0;
            self.state = .{ .disc_primary_uuid = .{ .uuid = uuid, .next = 0x0001 } };
            const n = try self.findByTypeReq(uuid, 0x0001, out);
            self.markSent(now_ms);
            return n;
        }

        fn findByTypeReq(self: *Self, uuid: att.Uuid, start: u16, out: []u8) Error!usize {
            var v: [16]u8 = undefined;
            const vn = uuid.put(&v);
            return att.encodeFindByTypeReq(out, .{
                .range = .{ .start = start, .end = 0xFFFF },
                .attr_type = 0x2800,
                .value = v[0..vn],
            }, &self.att);
        }

        // -----------------------------------------------------------------
        // Relationship Discovery / Characteristic Discovery
        // -----------------------------------------------------------------

        /// Find Included Services（§4.5.1）。结果在 `includes`。
        pub fn findIncludedServices(self: *Self, range: att.Range, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (!rangeOk(range)) return error.BadParam;
            self.include_count = 0;
            self.state = .{ .find_included = .{ .next = range.start, .end = range.end, .want = null } };
            const n = try self.typeReq(range.start, range.end, .{ .u16 = 0x2802 }, out);
            self.markSent(now_ms);
            return n;
        }

        /// Discover All Characteristics of a Service（§4.6.1）；`filter` 非 null 时是
        /// Discover Characteristics by UUID（§4.6.2）：只留 UUID 相符的。结果在 `chars`。
        pub fn discoverCharacteristics(
            self: *Self,
            range: att.Range,
            filter: ?att.Uuid,
            out: []u8,
            now_ms: u32,
        ) Error!usize {
            try self.begin();
            if (!rangeOk(range)) return error.BadParam;
            self.char_count = 0;
            self.state = .{ .disc_chars = .{ .next = range.start, .end = range.end, .filter = filter } };
            const n = try self.typeReq(range.start, range.end, .{ .u16 = 0x2803 }, out);
            self.markSent(now_ms);
            return n;
        }

        fn typeReq(self: *Self, start: u16, end: u16, uuid: att.Uuid, out: []u8) Error!usize {
            return att.encodeReadByTypeReq(out, .{ .range = .{ .start = start, .end = end }, .uuid = uuid }, &self.att);
        }

        /// Discover All Characteristic Descriptors（§4.7.1）：范围是特征值句柄 + 1 到特征定义
        /// 的最后一个句柄。结果在 `descs`。
        pub fn discoverDescriptors(self: *Self, range: att.Range, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (!rangeOk(range)) return error.BadParam;
            self.desc_count = 0;
            self.state = .{ .disc_descs = .{ .next = range.start, .end = range.end } };
            const n = try att.encodeFindInfoReq(out, .{ .start = range.start, .end = range.end }, &self.att);
            self.markSent(now_ms);
            return n;
        }

        fn rangeOk(r: att.Range) bool {
            return r.start != 0 and r.start <= r.end;
        }

        // -----------------------------------------------------------------
        // Reading
        // -----------------------------------------------------------------

        /// Read Characteristic Value（§4.8.1），也用于 Read Characteristic Descriptors（§4.12.1）。
        /// 值在 `value[0..value_len]`，最多 ATT_MTU−1 字节；更长的要用 `readLong()`。
        pub fn read(self: *Self, attr_handle: u16, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            self.handle = attr_handle;
            self.value_len = 0;
            self.state = .read;
            const n = try att.encodeReadReq(out, attr_handle, &self.att);
            self.markSent(now_ms);
            return n;
        }

        /// Read Using Characteristic UUID（§4.8.2）：只取第一个响应装得下的那几条。命中在
        /// `hits`，值在 `value`。
        pub fn readByUuid(self: *Self, uuid: att.Uuid, range: att.Range, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (!rangeOk(range)) return error.BadParam;
            self.hit_count = 0;
            self.value_len = 0;
            self.state = .read_uuid;
            const n = try self.typeReq(range.start, range.end, uuid, out);
            self.markSent(now_ms);
            return n;
        }

        /// Read Long Characteristic Values（§4.8.3），也用于 Read Long Characteristic
        /// Descriptors（§4.12.2）：先 ATT_READ_REQ，再按 ATT_MTU−1 一段一段 ATT_READ_BLOB_REQ，
        /// 直到某一段短于 ATT_MTU−1。值在 `value[0..value_len]`。
        pub fn readLong(self: *Self, attr_handle: u16, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            self.handle = attr_handle;
            self.value_len = 0;
            self.state = .read_long;
            const n = try att.encodeReadReq(out, attr_handle, &self.att);
            self.markSent(now_ms);
            return n;
        }

        /// Read Multiple Characteristic Values（§4.8.4，`variable == false`）或 Read Multiple
        /// Variable Length Characteristic Values（§4.8.5）。前者各值首尾相接放在 `value`；
        /// 后者每个元组一条 `hits`，值放在 `value`。
        pub fn readMultiple(self: *Self, handles: []const u16, variable: bool, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (handles.len < 2) return error.BadParam;
            self.value_len = 0;
            self.hit_count = 0;
            self.state = if (variable) .read_multiple_var else .read_multiple;
            const op: att.Op = if (variable) .read_multiple_var_req else .read_multiple_req;
            const n = try att.encodeReadMultipleReq(out, op, handles, &self.att);
            self.markSent(now_ms);
            return n;
        }

        // -----------------------------------------------------------------
        // Writing
        // -----------------------------------------------------------------

        /// Write Without Response（§4.9.1）。只有前 ATT_MTU−3 字节能这样写；更长是本地错误
        /// `TooLong`。没有响应，所以不占事务。
        pub fn writeWithoutResponse(self: *Self, attr_handle: u16, value: []const u8, out: []u8) Error!usize {
            if (self.dead) return error.Dead;
            if (value.len > att.valueMax(.write_cmd, self.mtu)) return error.TooLong;
            const n = try att.encodeWriteCmd(out, attr_handle, value, &self.att);
            self.stats.requests += 1;
            self.stats.started += 1;
            self.stats.completed += 1;
            return n;
        }

        /// Signed Write Without Response（§4.9.2）。`counter` 是本方 CSRK 的 SignCounter，
        /// 调用方每签一次加一。只有前 ATT_MTU−15 字节能这样写。
        pub fn writeSigned(
            self: *Self,
            attr_handle: u16,
            value: []const u8,
            csrk: [16]u8,
            counter: u32,
            out: []u8,
        ) Error!usize {
            if (self.dead) return error.Dead;
            if (value.len > att.valueMax(.signed_write_cmd, self.mtu)) return error.TooLong;
            const n = try att.encodeSignedWriteCmd(out, .{
                .handle = attr_handle,
                .value = value,
                .sig = @splat(0),
            }, self.mtu, &self.att);
            // 被签的是操作码加参数，也就是签名之前的全部字节（[Vol 3] Part F §3.3.1）。
            const sig = cmac.sign(csrk, counter, out[0 .. n - cmac.sig_len]);
            @memcpy(out[n - cmac.sig_len ..][0..cmac.sig_len], &sig);
            self.stats.requests += 1;
            self.stats.started += 1;
            self.stats.completed += 1;
            return n;
        }

        /// Write Characteristic Value（§4.9.3），也用于 Write Characteristic Descriptors
        /// （§4.12.3）。只有前 ATT_MTU−3 字节能这样写；更长是本地错误 `TooLong`。
        pub fn write(self: *Self, attr_handle: u16, value: []const u8, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (value.len > att.valueMax(.write_req, self.mtu)) return error.TooLong;
            self.state = .write;
            const n = try att.encodeWriteReq(out, attr_handle, value, &self.att);
            self.markSent(now_ms);
            return n;
        }

        /// Write Long Characteristic Values（§4.9.4），也用于 Write Long Characteristic
        /// Descriptors（§4.12.4）：值按 ATT_MTU−5 分段排队，最后 Execute Write。
        pub fn writeLong(self: *Self, attr_handle: u16, value: []const u8, out: []u8, now_ms: u32) Error!usize {
            return self.startQueued(attr_handle, value, false, out, now_ms);
        }

        /// Characteristic Value Reliable Writes（§4.9.5）：与写长值相同，另外每条
        /// ATT_PREPARE_WRITE_RSP 都要与请求逐字节一致；不一致就取消全部排队写。
        pub fn reliableWrite(self: *Self, attr_handle: u16, value: []const u8, out: []u8, now_ms: u32) Error!usize {
            return self.startQueued(attr_handle, value, true, out, now_ms);
        }

        fn startQueued(self: *Self, attr_handle: u16, value: []const u8, verify: bool, out: []u8, now_ms: u32) Error!usize {
            try self.begin();
            if (value.len == 0 or value.len > cfg.write) return error.TooLong;
            @memcpy(self.wbuf[0..value.len], value);
            self.wlen = value.len;
            self.woffset = 0;
            self.wverify = verify;
            self.handle = attr_handle;
            self.state = .{ .queued = .{ .exec = false } };
            const n = try self.prepareReq(out);
            self.markSent(now_ms);
            return n;
        }

        /// 下一段 ATT_PREPARE_WRITE_REQ：从 `woffset` 起，最多 ATT_MTU−5 字节。
        fn prepareReq(self: *Self, out: []u8) Error!usize {
            const chunk = @min(self.wlen - self.woffset, att.valueMax(.prepare_write_req, self.mtu));
            return att.encodePrepareWrite(.prepare_write_req, out, .{
                .handle = self.handle,
                .offset = @intCast(self.woffset),
                .value = self.wbuf[self.woffset..][0..chunk],
            }, self.mtu, &self.att);
        }

        // -----------------------------------------------------------------
        // 收 PDU
        // -----------------------------------------------------------------

        /// 周期调用。有请求等了 30 秒还没响应 → 事务超时（[Vol 3] Part F §3.3.3），过程
        /// 失败、这条 bearer 作废，返回 true。
        pub fn tick(self: *Self, now_ms: u32) bool {
            if (self.state != .idle and now_ms -% self.sent_at >= timeout_ms) {
                self.dead = true;
                self.state = .idle;
                self.status = .timeout;
                self.stats.timeouts += 1;
                self.stats.failed += 1;
                return true;
            }
            return false;
        }

        /// 处理对端发来的一个 PDU。等响应超过 30 秒才来的也算超时，不处理。
        pub fn onPdu(self: *Self, pdu: []const u8, out: []u8, now_ms: u32) Step {
            if (self.dead) return self.drop();
            const p = att.parse(pdu, &self.att) catch |e| {
                if (self.state == .idle) return self.drop();
                return self.fail(.protocol, e, out);
            };
            // 通知与指示不占事务：过程照旧等它的响应。
            switch (p) {
                .notify => |w| {
                    self.stats.events += 1;
                    return .{ .outcome = .notify, .event = w };
                },
                .indicate => |w| {
                    // §3.4.7.2：收到指示就回确认，哪怕句柄或值有问题也是先回。
                    self.stats.events += 1;
                    const n = att.encodeConfirm(out, &self.att) catch 0;
                    return .{ .outcome = .indicate, .out_len = n, .event = w };
                },
                .multiple_ntf => |list| {
                    self.stats.events += 1;
                    return .{ .outcome = .multi, .multi = .{ .data = list } };
                },
                else => {},
            }
            if (self.state == .idle) return self.drop();
            if (now_ms -% self.sent_at >= timeout_ms) {
                _ = self.tick(now_ms);
                return .{ .outcome = .failed };
            }

            const step = self.dispatch(p, out);
            // 下一步请求（或取消）是现在发出去的，事务从现在起计时。
            if (step.out_len > 0 and (step.outcome == .pending or step.outcome == .failed)) {
                self.sent_at = now_ms;
                self.stats.requests += 1;
            }
            return step;
        }

        fn dispatch(self: *Self, p: att.Pdu, out: []u8) Step {
            if (p == .error_rsp) return self.onError(p.error_rsp, out);
            switch (self.state) {
                .idle => return self.drop(),
                // 取消排队写得到了应答：这条 bearer 重新空闲；已经报出去的失败不变。
                .canceling => switch (p) {
                    .execute_write_rsp => {
                        self.state = .idle;
                        return .{ .outcome = .closed };
                    },
                    else => return self.drop(),
                },
                .mtu => switch (p) {
                    .mtu_rsp => |server_rx| {
                        self.mtu = att.effectiveMtu(self.rx_mtu, server_rx);
                        return self.finish();
                    },
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .disc_primary => |*st| switch (p) {
                    .read_by_group_rsp => |rsp| return self.onPrimary(st, rsp, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .disc_primary_uuid => |*st| switch (p) {
                    .find_by_type_rsp => |rsp| return self.onPrimaryByUuid(st, rsp, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .find_included => |*st| switch (p) {
                    .read_by_type_rsp => |rsp| return self.onIncluded(st, rsp, out),
                    .read_rsp => |v| return self.onIncludedUuid(st, v, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .disc_chars => |*st| switch (p) {
                    .read_by_type_rsp => |rsp| return self.onChars(st, rsp, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .disc_descs => |*st| switch (p) {
                    .find_info_rsp => |rsp| return self.onDescs(st, rsp, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .read => switch (p) {
                    .read_rsp => |v| return self.storeFlat(v, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .read_uuid => switch (p) {
                    .read_by_type_rsp => |rsp| return self.onReadByUuid(rsp, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .read_long => switch (p) {
                    .read_rsp, .read_blob_rsp => |v| return self.onBlob(v, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .read_multiple => switch (p) {
                    .read_multiple_rsp => |v| return self.storeFlat(v, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .read_multiple_var => switch (p) {
                    .read_multiple_var_rsp => |list| return self.onTuples(list, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .write => switch (p) {
                    .write_rsp => return self.finish(),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
                .queued => |*q| switch (p) {
                    .prepare_write_rsp => |part| return self.onPrepared(q, part, out),
                    // Execute 还没发出就来了它的响应：结构不对。
                    .execute_write_rsp => return if (q.exec) self.finish() else self.fail(.protocol, error.Trailing, out),
                    else => return self.fail(.protocol, error.Trailing, out),
                },
            }
        }

        fn drop(self: *Self) Step {
            self.stats.ignored += 1;
            return .{ .outcome = .ignored };
        }

        fn onError(self: *Self, e: att.ErrorRsp, out: []u8) Step {
            self.error_rsp = e;
            const not_found = e.code == @backingInt(att.Code.attribute_not_found);
            switch (self.state) {
                // §4.3.1：Request Not Supported → 用默认 MTU，过程照样算完成。
                .mtu => {
                    if (e.code == @backingInt(att.Code.request_not_supported)) {
                        self.mtu = att.default_mtu;
                        return self.finish();
                    }
                },
                // 各发现过程以 Attribute Not Found 为正常结束。
                .disc_primary, .disc_primary_uuid, .find_included, .disc_chars, .disc_descs => {
                    if (not_found) return self.finish();
                },
                // 取消本身成不成功都不改变已经报出去的失败。
                .canceling => {
                    self.state = .idle;
                    return .{ .outcome = .closed };
                },
                else => {},
            }
            return self.fail(.att_error, null, out);
        }

        // -----------------------------------------------------------------
        // 各过程的响应处理
        // -----------------------------------------------------------------

        /// ATT_READ_BY_GROUP_TYPE_RSP。下一条请求从最后一个 End Group Handle + 1 开始
        /// （§4.4.1）。
        fn onPrimary(self: *Self, st: *Primary, rsp: att.GroupRsp, out: []u8) Step {
            var prev_end: u16 = if (st.next == 0x0001) 0 else st.next - 1;
            if (rsp.count() == 0) return self.fail(.protocol, error.InvalidList, out);
            var i: usize = 0;
            while (i < rsp.count()) : (i += 1) {
                const item = rsp.at(i);
                const uuid = att.Uuid.parse(item.value) catch return self.fail(.protocol, error.BadUuid, out);
                if (item.head < item.handle or item.handle <= prev_end) {
                    return self.fail(.protocol, error.InvalidList, out);
                }
                if (self.service_count >= cfg.services) return self.fail(.local, error.NoSpace, out);
                self.services[self.service_count] = .{ .start = item.handle, .end = item.head, .uuid = uuid };
                self.service_count += 1;
                prev_end = item.head;
            }
            if (prev_end == 0xFFFF) return self.finish();
            st.next = prev_end + 1;
            const n = self.groupReq(st.next, out) catch |e| return self.fail(.local, e, out);
            return .{ .outcome = .pending, .out_len = n };
        }

        /// ATT_FIND_BY_TYPE_VALUE_RSP。下一条请求从最后一个 Found Attribute Handle + 1 开始
        /// （§4.4.2）。
        fn onPrimaryByUuid(self: *Self, st: *PrimaryUuid, rsp: att.HandleRanges, out: []u8) Step {
            var last: u16 = if (st.next == 0x0001) 0 else st.next - 1;
            if (rsp.count() == 0) return self.fail(.protocol, error.InvalidList, out);
            var i: usize = 0;
            while (i < rsp.count()) : (i += 1) {
                const pair = rsp.at(i);
                const found = pair.found;
                const end = pair.end;
                if (end < found or found <= last) return self.fail(.protocol, error.InvalidList, out);
                if (self.service_count >= cfg.services) return self.fail(.local, error.NoSpace, out);
                self.services[self.service_count] = .{ .start = found, .end = end, .uuid = st.uuid };
                self.service_count += 1;
                last = found;
            }
            if (last == 0xFFFF) return self.finish();
            st.next = last + 1;
            const n = self.findByTypeReq(st.uuid, st.next, out) catch |e| return self.fail(.local, e, out);
            return .{ .outcome = .pending, .out_len = n };
        }

        /// ATT_READ_BY_TYPE_RSP（«Include»）。每条是句柄(2) ‖ 组尾句柄(2) [‖ 16 位服务 UUID(2)]：
        /// 被包含的服务是 128 位 UUID 时没有后 2 字节（[Vol 3] Part G §3.2 表 3.2）。
        fn onIncluded(self: *Self, st: *Included, rsp: att.TypeRsp, out: []u8) Step {
            var last: u16 = st.next - 1;
            if (rsp.count() == 0) return self.fail(.protocol, error.InvalidList, out);
            var i: usize = 0;
            while (i < rsp.count()) : (i += 1) {
                const item = rsp.at(i);
                const v = item.value;
                if (v.len != 4 and v.len != 6) return self.fail(.protocol, error.InvalidList, out);
                if (item.handle <= last) return self.fail(.protocol, error.InvalidList, out);
                if (self.include_count >= cfg.includes) return self.fail(.local, error.NoSpace, out);
                self.includes[self.include_count] = .{
                    .handle = item.handle,
                    .service = att.getU16(v),
                    .end = att.getU16(v[2..]),
                    .uuid = if (v.len == 6) .{ .u16 = att.getU16(v[4..]) } else null,
                };
                self.include_count += 1;
                last = item.handle;
            }
            st.next = last + 1;
            return self.includedNext(st, out);
        }

        /// 补读被包含服务的 128 位 UUID（§4.5.1：ATT_READ_REQ 读被包含服务的声明），或者
        /// 继续找下一条包含声明；最后一条的句柄等于请求的结束句柄时过程完成。
        fn includedNext(self: *Self, st: *Included, out: []u8) Step {
            var i: usize = if (st.want) |w| @as(usize, w) + 1 else 0;
            while (i < self.include_count) : (i += 1) {
                if (self.includes[i].uuid == null) {
                    st.want = @intCast(i);
                    const n = att.encodeReadReq(out, self.includes[i].service, &self.att) catch |e| {
                        return self.fail(.local, e, out);
                    };
                    return .{ .outcome = .pending, .out_len = n };
                }
            }
            st.want = null;
            if (st.next == 0 or st.next > st.end) return self.finish();
            const n = self.typeReq(st.next, st.end, .{ .u16 = 0x2802 }, out) catch |e| {
                return self.fail(.local, e, out);
            };
            return .{ .outcome = .pending, .out_len = n };
        }

        fn onIncludedUuid(self: *Self, st: *Included, v: []const u8, out: []u8) Step {
            const i = st.want orelse return self.fail(.protocol, error.Trailing, out);
            self.includes[i].uuid = att.Uuid.parse(v) catch return self.fail(.protocol, error.BadUuid, out);
            return self.includedNext(st, out);
        }

        /// ATT_READ_BY_TYPE_RSP（«Characteristic»）。每条是属性位 ‖ 值句柄 ‖ UUID。
        fn onChars(self: *Self, st: *Chars, rsp: att.TypeRsp, out: []u8) Step {
            var last: u16 = st.next - 1;
            if (rsp.count() == 0) return self.fail(.protocol, error.InvalidList, out);
            var i: usize = 0;
            while (i < rsp.count()) : (i += 1) {
                const item = rsp.at(i);
                const v = item.value;
                if (v.len != 5 and v.len != 19) return self.fail(.protocol, error.InvalidList, out);
                if (item.handle <= last) return self.fail(.protocol, error.InvalidList, out);
                last = item.handle;
                const uuid = att.Uuid.parse(v[3..]) catch return self.fail(.protocol, error.BadUuid, out);
                if (st.filter) |f| {
                    if (!f.eql(uuid)) continue;
                }
                if (self.char_count >= cfg.chars) return self.fail(.local, error.NoSpace, out);
                self.chars[self.char_count] = .{
                    .decl = item.handle,
                    .value = att.getU16(v[1..]),
                    .props = v[0],
                    .uuid = uuid,
                };
                self.char_count += 1;
            }
            if (last >= st.end) return self.finish();
            st.next = last + 1;
            const n = self.typeReq(st.next, st.end, .{ .u16 = 0x2803 }, out) catch |e| {
                return self.fail(.local, e, out);
            };
            return .{ .outcome = .pending, .out_len = n };
        }

        fn onDescs(self: *Self, st: *Descs, rsp: att.InfoRsp, out: []u8) Step {
            var last: u16 = st.next - 1;
            if (rsp.count() == 0) return self.fail(.protocol, error.InvalidList, out);
            var i: usize = 0;
            while (i < rsp.count()) : (i += 1) {
                const info = rsp.at(i);
                if (info.handle <= last) return self.fail(.protocol, error.InvalidList, out);
                last = info.handle;
                if (self.desc_count >= cfg.descs) return self.fail(.local, error.NoSpace, out);
                self.descs[self.desc_count] = .{ .handle = info.handle, .uuid = info.uuid };
                self.desc_count += 1;
            }
            if (last >= st.end) return self.finish();
            st.next = last + 1;
            const n = att.encodeFindInfoReq(out, .{ .start = st.next, .end = st.end }, &self.att) catch |e| {
                return self.fail(.local, e, out);
            };
            return .{ .outcome = .pending, .out_len = n };
        }

        fn storeFlat(self: *Self, v: []const u8, out: []u8) Step {
            if (v.len > cfg.value) return self.fail(.local, error.NoSpace, out);
            @memcpy(self.value[0..v.len], v);
            self.value_len = v.len;
            return self.finish();
        }

        fn onReadByUuid(self: *Self, rsp: att.TypeRsp, out: []u8) Step {
            if (rsp.count() == 0) return self.fail(.protocol, error.InvalidList, out);
            var i: usize = 0;
            while (i < rsp.count()) : (i += 1) {
                const item = rsp.at(i);
                if (!self.append(item.handle, @intCast(item.value.len), item.value)) {
                    return self.fail(.local, error.NoSpace, out);
                }
            }
            return self.finish();
        }

        fn onTuples(self: *Self, list: []const u8, out: []u8) Step {
            var it = att.TupleList{ .data = list };
            var any = false;
            while (it.next()) |t| {
                any = true;
                if (!self.append(0, t.len, t.value)) return self.fail(.local, error.NoSpace, out);
            }
            if (!any) return self.fail(.protocol, error.InvalidList, out);
            return self.finish();
        }

        /// 往 `hits` / `value` 里追加一条：声明的长度是 `len`，实际带来的值是 `v`。
        fn append(self: *Self, attr_handle: u16, len: u16, v: []const u8) bool {
            if (self.hit_count >= cfg.handles or self.value_len + v.len > cfg.value) return false;
            self.hits[self.hit_count] = .{
                .handle = attr_handle,
                .off = @intCast(self.value_len),
                .len = len,
                .present = @intCast(v.len),
            };
            self.hit_count += 1;
            @memcpy(self.value[self.value_len..][0..v.len], v);
            self.value_len += v.len;
            return true;
        }

        /// ATT_READ_RSP / ATT_READ_BLOB_RSP（Read Long）。这一段短于 ATT_MTU−1 就是读完了；
        /// 否则从已读的长度处再读一段（§4.8.3）。
        fn onBlob(self: *Self, v: []const u8, out: []u8) Step {
            if (self.value_len + v.len > cfg.value) return self.fail(.local, error.NoSpace, out);
            @memcpy(self.value[self.value_len..][0..v.len], v);
            self.value_len += v.len;
            if (v.len < att.valueMax(.read_blob_rsp, self.mtu)) return self.finish();
            const n = att.encodeReadBlobReq(out, .{
                .handle = self.handle,
                .offset = @intCast(self.value_len),
            }, &self.att) catch |e| return self.fail(.local, e, out);
            return .{ .outcome = .pending, .out_len = n };
        }

        /// ATT_PREPARE_WRITE_RSP。可靠写时它与请求不一致 → 取消全部排队写（§4.9.5）。
        fn onPrepared(self: *Self, q: *Queued, part: att.Part, out: []u8) Step {
            const from = self.woffset;
            const chunk = @min(self.wlen - from, att.valueMax(.prepare_write_req, self.mtu));
            if (self.wverify) {
                const same = part.handle == self.handle and part.offset == from and
                    std.mem.eql(u8, part.value, self.wbuf[from..][0..chunk]);
                if (!same) {
                    // §4.9.5：值在传输中被改过 → 发取消，过程失败。
                    self.status = .protocol;
                    self.last_err = error.Mismatch;
                    self.stats.failed += 1;
                    return self.cancelNow(out);
                }
            }
            self.woffset = from + chunk;
            if (self.woffset < self.wlen) {
                const n = self.prepareReq(out) catch |e| return self.fail(.local, e, out);
                return .{ .outcome = .pending, .out_len = n };
            }
            q.exec = true;
            const n = att.encodeExecuteWriteReq(out, .write, &self.att) catch |e| return self.fail(.local, e, out);
            return .{ .outcome = .pending, .out_len = n };
        }
    };
}
