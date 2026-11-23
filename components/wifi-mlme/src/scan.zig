//! wifi-mlme：扫描计划与 BSS 表（IEEE Std 802.11-2016 11.1.4）。
//!
//! 两部分：
//!
//!   1. `plan`：把 MLME-SCAN.request（6.3.3.2，p.265–266）的 ChannelList、
//!      ProbeDelay、MinChannelTime、MaxChannelTime 变成一张**确定性**的调度表。
//!      被动扫描按 11.1.4.2.1（p.1591）：每个信道听不超过 MaxChannelTime；
//!      主动扫描按 11.1.4.3.2（p.1591–1592）a)–h) 的步骤。
//!   2. `BssTable`：有界 BSS 表，喂 Beacon / Probe Response，按 BSSID 去重。
//!
//! 原文没有给 ProbeDelay / MinChannelTime / MaxChannelTime 的默认值（6.3.3.2.2 只
//! 给了单位与范围），本实现用下面三个工程常数作默认。页码为印刷页码。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const mgmt = @import("mgmt.zig");

// ---------------------------------------------------------------------------
// 工程常数（标准正文未给默认值）
// ---------------------------------------------------------------------------

/// ProbeDelay 默认值，微秒。
pub const default_probe_delay_us: u32 = 100;
/// MinChannelTime 默认值，TU（约 20 ms）。
pub const default_min_channel_time_tu: u32 = 20;
/// MaxChannelTime 默认值，TU（约 39 ms）。
pub const default_max_channel_time_tu: u32 = 38;

pub const ScanType = enum {
    /// 11.1.4.3（p.1591）：每个信道发 Probe Request、收 Probe Response。
    active,
    /// 11.1.4.2.1（p.1591）：只听 Beacon。
    passive,
};

/// MLME-SCAN.request 里与调度有关的参数（6.3.3.2.2，p.265–266）。
pub const Request = struct {
    scan_type: ScanType = .active,
    /// BSSID 参数：具体 BSSID 或通配（广播地址）。
    bssid: frame.Mac = frame.broadcast,
    /// SSID 参数：0–32 字节，长度 0 是通配 SSID。
    ssid: []const u8 = &.{},
    /// ProbeDelay：主动扫描发 Probe 帧之前的等待，微秒。
    probe_delay_us: u32 = default_probe_delay_us,
    /// ChannelList：要扫的信道，按给出的顺序遍历（non-DMG STA 的遍历顺序本标准未规定）。
    channel_list: []const u8 = &.{},
    /// MinChannelTime（TU）：每个信道至少停留的时间。
    min_channel_time_tu: u32 = default_min_channel_time_tu,
    /// MaxChannelTime（TU）：每个信道至多停留的时间，有效范围是 ≥ MinChannelTime。
    max_channel_time_tu: u32 = default_max_channel_time_tu,
};

// ---------------------------------------------------------------------------
// 调度表
// ---------------------------------------------------------------------------

pub const max_channels = 32;
/// 主动扫描每个信道 4 步，被动 1 步。
pub const max_steps = max_channels * 4;

pub const StepKind = enum {
    /// 被动扫描：在信道上听 `duration` 个 TU（11.1.4.2.1）。
    listen,
    /// 11.1.4.3.2 a)：等 ProbeDelay（或收到 PHY-RXSTART），微秒。
    probe_delay,
    /// 11.1.4.3.2 b)、c)：基本接入后向广播地址发 Probe Request。
    probe_request,
    /// 11.1.4.3.2 e)、f)：起计时器，至少等到 MinChannelTime。
    dwell_min,
    /// 11.1.4.3.2 g)：信道在 MinChannelTime 之前忙过（收到 PHY-CCA BUSY）才继续
    /// 处理 Probe Response 到 MaxChannelTime；否则 h) 直接跳到下一信道。
    dwell_to_max,
};

pub const Step = struct {
    kind: StepKind,
    channel: u8,
    /// `listen` / `dwell_min` / `dwell_to_max`：TU；`probe_delay`：微秒；`probe_request`：0。
    duration: u32,
    /// 只有 `dwell_to_max` 为 true。
    conditional: bool = false,
};

pub const PlanError = error{
    EmptyChannelList,
    TooManyChannels,
    SsidTooLong,
    /// MaxChannelTime 小于 MinChannelTime、为 0，或主动扫描的 MinChannelTime 为 0。
    BadChannelTime,
    /// `out` 装不下整张调度表。
    NoRoom,
};

/// 生成调度表，返回写入的步数。同一份请求永远得到同一张表：信道顺序 =
/// ChannelList 顺序，每信道一组固定步骤。
pub fn plan(req: Request, out: []Step) PlanError!usize {
    if (req.channel_list.len == 0) return error.EmptyChannelList;
    if (req.channel_list.len > max_channels) return error.TooManyChannels;
    if (req.ssid.len > ie.ssid_max) return error.SsidTooLong;
    const per_channel: usize = if (req.scan_type == .active) 4 else 1;
    const need = req.channel_list.len * per_channel;
    if (out.len < need) return error.NoRoom;
    if (req.max_channel_time_tu == 0 or req.max_channel_time_tu < req.min_channel_time_tu) return error.BadChannelTime;
    if (req.scan_type == .active and req.min_channel_time_tu == 0) return error.BadChannelTime;

    var n: usize = 0;
    for (req.channel_list) |ch| {
        if (req.scan_type == .passive) {
            out[n] = .{ .kind = .listen, .channel = ch, .duration = req.max_channel_time_tu };
            n += 1;
            continue;
        }
        out[n] = .{ .kind = .probe_delay, .channel = ch, .duration = req.probe_delay_us };
        out[n + 1] = .{ .kind = .probe_request, .channel = ch, .duration = 0 };
        out[n + 2] = .{ .kind = .dwell_min, .channel = ch, .duration = req.min_channel_time_tu };
        out[n + 3] = .{ .kind = .dwell_to_max, .channel = ch, .duration = req.max_channel_time_tu - req.min_channel_time_tu, .conditional = true };
        n += 4;
    }
    return n;
}

/// 11.1.4.3.2 f) 的判定：MinChannelTime 之前收到过 PHY-CCA(BUSY) 就留在本信道
/// 处理 Probe Response 到 MaxChannelTime，否则此刻换信道。
pub fn stayPastMinChannelTime(busy_before_min: bool) bool {
    return busy_before_min;
}

/// 调度表在 TU 口径上的驻留总时间上界（每个信道都按最长的分支算）；
/// ProbeDelay 是微秒，不折进 TU，单列在 `probe_delay_us_total` 里。
pub const Duration = struct {
    dwell_tu: u64,
    probe_delay_us_total: u64,
};

pub fn duration(steps: []const Step) Duration {
    var d = Duration{ .dwell_tu = 0, .probe_delay_us_total = 0 };
    for (steps) |s| {
        switch (s.kind) {
            .listen, .dwell_min, .dwell_to_max => d.dwell_tu += s.duration,
            .probe_delay => d.probe_delay_us_total += s.duration,
            .probe_request => {},
        }
    }
    return d;
}

/// 拼一帧 Probe Request（11.1.4.3.2 c，p.1591）：发到广播地址，带请求里的 SSID 与
/// BSSID；组地址管理帧的 Duration/ID 为 0（9.3.3.2，p.693）。帧尾带 FCS。
pub fn buildProbeRequestMpdu(
    req: Request,
    own_address: frame.Mac,
    seq_ctrl: u16,
    rates: []const ie.Rate,
    ext_rates: []const ie.Rate,
    out: []u8,
) mgmt.BuildError!usize {
    var body: [ie.ssid_max + 2 + ie.rates_max + 2 + ie.ext_rates_max + 2]u8 = undefined;
    const n = try mgmt.buildProbeRequest(.{ .ssid = req.ssid, .rates = rates, .ext_rates = ext_rates }, &body);
    const hdr = frame.Header{
        .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.probe_req) },
        .duration_id = .{ .duration = 0 },
        .addr1 = frame.broadcast,
        .addr2 = own_address,
        .addr3 = req.bssid,
        .seq_ctrl = seq_ctrl,
    };
    return frame.seal(hdr, body[0..n], true, out) catch |e| switch (e) {
        error.NoRoom => return error.NoRoom,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// BSS 表
// ---------------------------------------------------------------------------

pub const max_bss = 16;
/// Supported Rates（≤ 8）与 Extended Supported Rates 合并后保留的上限。
pub const bss_rates_max = 16;
pub const bss_suites_max = 4;

/// RSNE 摘要：STA 挑选 BSS 要用的字段（9.4.2.25，p.882–890）。
pub const RsnSummary = struct {
    group_data_cipher: ie.Suite,
    pairwise: [bss_suites_max]ie.Suite = undefined,
    pairwise_len: u8 = 0,
    akms: [bss_suites_max]ie.Suite = undefined,
    akm_len: u8 = 0,
    caps: ie.RsnCaps = .{},
    group_mgmt_cipher: ?ie.Suite = null,

    pub fn pairwiseSlice(self: *const RsnSummary) []const ie.Suite {
        return self.pairwise[0..self.pairwise_len];
    }

    pub fn akmSlice(self: *const RsnSummary) []const ie.Suite {
        return self.akms[0..self.akm_len];
    }
};

pub const Bss = struct {
    bssid: frame.Mac,
    ssid: [ie.ssid_max]u8 = undefined,
    ssid_len: u8 = 0,
    /// Beacon / Probe Response 的 Timestamp（TSF timer 值）。
    tsf: u64 = 0,
    beacon_interval_tu: u16 = 0,
    capability: mgmt.Capability = .{},
    rates: [bss_rates_max]ie.Rate = undefined,
    rates_len: u8 = 0,
    /// DSSS Parameter Set 的 Current Channel；没有该元素时取接收信道。
    channel: u8 = 0,
    rssi: i8 = 0,
    country: [3]u8 = @splat(0),
    country_present: bool = false,
    dtim_period: u8 = 0,
    dtim_present: bool = false,
    /// 没有 RSNE 即非 RSN BSS（11.1.4.1 与 Table 9-27 第 18 项）。
    rsn: ?RsnSummary = null,
    /// 见到过几帧（Beacon + Probe Response）。
    seen_count: u32 = 0,
    last_seen_tu: u64 = 0,

    pub fn ssidSlice(self: *const Bss) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    pub fn ratesSlice(self: *const Bss) []const ie.Rate {
        return self.rates[0..self.rates_len];
    }

    /// Capability Information 的 IBSS 位：独立 BSS。
    pub fn isIbss(self: *const Bss) bool {
        return self.capability.ibss;
    }
};

pub const RxMeta = struct {
    rssi: i8,
    /// 接收到这一帧时本机所在的信道。
    channel: u8,
    now_tu: u64,
};

pub const UpdateError = error{
    /// 帧的类型/子类型不是 Beacon 或 Probe Response，或缺 Address 3。
    NotBssFrame,
    /// 固定字段或元素串被截断。
    Truncated,
    /// 元素串在 Element ID Extension 元素上缺一个字节。
    MissingIdExtension,
    /// 缺 SSID 或 Supported Rates 元素（9.3.3.2，p.694：除非另有说明，字段与元素
    /// 都是必备的；Table 9-27 / 9-34 里这两项都没有「可选」）。
    MissingElement,
    /// 同一个元素在一帧里出现两次。
    DuplicateElement,
    TableFull,
    TooManyRates,
    TooManySuites,
    TooManyPmkids,
    // 以下原样透传 ie.zig 的解码错误。
    TooLong,
    BadLength,
    BadValue,
    BadVersion,
    BadPadding,
    TooManyTriplets,
    ReservedBitsSet,
    BadKeyId,
    Empty,
};

pub const BssTable = struct {
    entries: [max_bss]Bss = undefined,
    len: u8 = 0,
    /// 表满之后新出现、被丢掉的 BSS 个数。
    dropped: u32 = 0,

    pub fn init() BssTable {
        return .{};
    }

    pub fn reset(self: *BssTable) void {
        self.* = .{};
    }

    pub fn count(self: *const BssTable) usize {
        return self.len;
    }

    pub fn get(self: *BssTable, index: usize) ?*Bss {
        if (index >= self.len) return null;
        return &self.entries[index];
    }

    pub fn find(self: *BssTable, bssid: frame.Mac) ?*Bss {
        for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, &e.bssid, &bssid)) return e;
        }
        return null;
    }

    /// 喂一帧 Beacon 或 Probe Response。返回 true 表示新加了条目，false 表示刷新了
    /// 已有的 BSSID。出错时表不变。
    pub fn update(self: *BssTable, rx: frame.Frame, meta: RxMeta) UpdateError!bool {
        const fc = rx.hdr.fc;
        if (fc.type != .mgmt) return error.NotBssFrame;
        const is_beacon = fc.subtype == @backingInt(frame.MgmtSubtype.beacon);
        const is_probe_resp = fc.subtype == @backingInt(frame.MgmtSubtype.probe_resp);
        if (!is_beacon and !is_probe_resp) return error.NotBssFrame;
        // Address 3 = BSSID（9.3.3.2 c)，p.693）。
        const bssid = rx.hdr.addr3 orelse return error.NotBssFrame;

        const fixed: mgmt.BssAnnouncement = if (is_beacon)
            mgmt.parseBeacon(rx.body) catch return error.Truncated
        else
            mgmt.parseProbeResponse(rx.body) catch return error.Truncated;

        var b = Bss{
            .bssid = bssid,
            .tsf = fixed.timestamp,
            .beacon_interval_tu = fixed.beacon_interval,
            .capability = fixed.capability,
            .channel = meta.channel,
            .rssi = meta.rssi,
            .last_seen_tu = meta.now_tu,
        };
        try parseElements(fixed.elements, &b);

        if (self.find(bssid)) |existing| {
            const seen = existing.seen_count;
            // 以新帧为准；新帧没带的 TIM（Probe Response 没有，Table 9-34）与 Country 沿用旧值。
            const keep_dtim = existing.dtim_present and !b.dtim_present;
            const keep_country = existing.country_present and !b.country_present;
            const dtim_period = existing.dtim_period;
            const country = existing.country;
            existing.* = b;
            if (keep_dtim) {
                existing.dtim_present = true;
                existing.dtim_period = dtim_period;
            }
            if (keep_country) {
                existing.country_present = true;
                existing.country = country;
            }
            existing.seen_count = seen + 1;
            return false;
        }
        if (self.len == max_bss) {
            self.dropped += 1;
            return error.TableFull;
        }
        b.seen_count = 1;
        self.entries[self.len] = b;
        self.len += 1;
        return true;
    }

    fn parseElements(elements: []const u8, b: *Bss) UpdateError!void {
        // 同一元素出现两次按不一致处理；用一组标志记录已经见过的元素。
        var seen_ssid = false;
        var seen_rates = false;
        var seen_ext_rates = false;
        var seen_dsss = false;
        var seen_country = false;
        var seen_tim = false;
        var seen_rsn = false;
        var w = ie.Walker.init(elements);
        while (try w.next()) |el| {
            switch (@as(ie.ElementId, @fromBackingInt(@intCast(el.id)))) {
                .ssid => {
                    if (seen_ssid) return error.DuplicateElement;
                    const s = try ie.parseSsid(el.body);
                    @memcpy(b.ssid[0..s.len], s);
                    b.ssid_len = @intCast(s.len);
                    seen_ssid = true;
                },
                .supported_rates => {
                    if (seen_rates) return error.DuplicateElement;
                    var it = try ie.parseSupportedRates(el.body);
                    try appendRates(b, &it);
                    seen_rates = true;
                },
                .ext_supported_rates => {
                    if (seen_ext_rates) return error.DuplicateElement;
                    var it = try ie.parseExtSupportedRates(el.body);
                    try appendRates(b, &it);
                    seen_ext_rates = true;
                },
                .dsss_param_set => {
                    if (seen_dsss) return error.DuplicateElement;
                    b.channel = try ie.parseDsssChannel(el.body);
                    seen_dsss = true;
                },
                .country => {
                    if (seen_country) return error.DuplicateElement;
                    const c = try ie.parseCountry(el.body);
                    b.country = c.string;
                    b.country_present = true;
                    seen_country = true;
                },
                .tim => {
                    if (seen_tim) return error.DuplicateElement;
                    const t = try ie.parseTim(el.body);
                    b.dtim_period = t.dtim_period;
                    b.dtim_present = true;
                    seen_tim = true;
                },
                .rsn => {
                    if (seen_rsn) return error.DuplicateElement;
                    b.rsn = try summarizeRsne(try ie.parseRsne(el.body));
                    seen_rsn = true;
                },
                // 不认识的元素跳过（9.3.3.2，p.694）。
                else => {},
            }
        }
        if (!seen_ssid or !seen_rates) return error.MissingElement;
    }

    fn appendRates(b: *Bss, it: *ie.RateIter) UpdateError!void {
        while (it.next()) |r| {
            if (b.rates_len == bss_rates_max) return error.TooManyRates;
            b.rates[b.rates_len] = r;
            b.rates_len += 1;
        }
    }

    fn summarizeRsne(r: ie.Rsne) UpdateError!RsnSummary {
        var s = RsnSummary{ .group_data_cipher = r.effectiveGroupCipher() };
        if (r.pairwise_len > bss_suites_max or r.akm_len > bss_suites_max) return error.TooManySuites;
        @memcpy(s.pairwise[0..r.pairwise_len], r.pairwise[0..r.pairwise_len]);
        s.pairwise_len = r.pairwise_len;
        @memcpy(s.akms[0..r.akm_len], r.akms[0..r.akm_len]);
        s.akm_len = r.akm_len;
        s.caps = r.caps;
        s.group_mgmt_cipher = r.group_mgmt_cipher;
        return s;
    }
};
