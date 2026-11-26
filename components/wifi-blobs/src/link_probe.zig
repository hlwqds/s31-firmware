//! 真实链路探针（`-Dwifi-link-probe=true`）：在 `esp_wifi_start` 返回之后继续往下走，
//! 一直走到 IP 层有收发：init → start → 扫描 → 连接 → DHCP → ping 网关。
//!
//! 旧的 `init_probe.run()` 停在 `esp_wifi_start` 返回处，而且 start 之前带着一批针对
//! 「`MAC_ST` 忙位不清」的实验写（往 `MAC_ST` 写值、手动开时钟）。2026-11-25 补上 PMU 的
//! modem ICG 码之后 MAC 真的在跑，那些写不再是无害的，所以真实链路走这个干净入口：
//!
//!   `initOnly()` → `esp_wifi_set_mode(STA)` → `esp_wifi_start()` → 开中断、常驻泵任务 → 扫描 →
//!   （构建时给了 AP 的 SSID 才做）连接 → 核对 MAC 密钥表 → 数据通路（`data_path.zig`：DHCP + ping 网关）
//!   `-Dcoex` 时每走到一个阶段（start 后、扫描后、连上、ping 结束、断开前后）取一次共存核的读数
//!   （`init_probe.coexReadings`）。
//!
//! blob 的 `esp_wifi_scan_start(config, block)`（`libnet80211/ieee80211_api.o`，反汇编核对过）
//! 不用事件，也不用信号量：把命令 5 经 `ieee80211_ioctl` 投给 Wi-Fi 任务，之后每 100 ms
//! （osi 表第 40、39 项：`ms_to_tick` + `task_delay`）查一次 `scan_get_scan_id()`，查到负数就是
//! 扫完了；查满 `get_total_scan_time()` 次返回 `0x300C`。也就是说扫描是在让出循环里推进的，
//! 推进它的是 Wi-Fi 任务——而任务要有活干，MAC 中断得先通。
//!
//! 镜像要最小：`-Dwifi-link-probe=true -Dboot=false -Dnet=false -Dwire=false -Dwifi=false`
//! （`tls` / `apps` 默认关），探针模式下 `--gc-sections` 保持打开，没被引用的自检代码不进镜像。

const std = @import("std");
const board = @import("board");
const log = board.log;
const hw = board.hw;
const trap = board.trap;

const initp = @import("init_probe.zig");
const impl = @import("osi_impl.zig");
const event_bus = @import("event_bus.zig");
const osi_stubs = @import("osi_stubs.zig");
const wpa_cb = @import("wpa_cb.zig");
const ipath = @import("data_path.zig");
/// 构建时给的 AP 凭据：`-Dwifi-ap-ssid` / `-Dwifi-ap-password`（`firmware/build.zig`）。不入库——脚本从对照镜像的
/// 本地 sdkconfig 里取了传进来。给了 SSID 才跑连接阶段。
const probe_opts = @import("probe_opts");
const coex_gate = @import("coex_gate");

/// 供 start.zig 做 comptime 选择：探针构建为 true。
pub const enabled = true;

/// 泵每走一步之后的一个钩子。合并镜像（`-Dcoex-merged` + `-Dcoex-wifi-link`）用它让 BLE 的 controller
/// 任务也走一步，两个控制器在同一个主循环里轮转；探针镜像里是 null，行为不变。
pub var co_pump: ?*const fn () void = null;

// ---------------------------------------------------------------------------
// 结构体布局：用 IDF 参照构建的编译命令（`~/esp/bt-ctl-oracle/build/compile_commands.json`
// 里 `esp_adapter.c` 那一条）编了一个 `sizeof` / `offsetof` 探针，数值取自目标文件：
// `wifi_ap_record_t` 92 字节、`rssi` 在 44、`authmode` 在 48（枚举是 4 字节）；
// `wifi_scan_config_t` 44 字节；`wifi_config_t` 184 字节、`sta.password` 在 32。
// ---------------------------------------------------------------------------

/// `wifi_ap_record_t`（`esp_wifi_types_generic.h`）只列到 `authmode`，其余原样保留。
const ApRecord = extern struct {
    bssid: [6]u8,
    ssid: [33]u8,
    primary: u8,
    /// `wifi_second_chan_t second`（枚举，4 字节）。
    second: c_int,
    rssi: i8,
    _pad: [3]u8,
    authmode: c_int,
    _rest: [92 - 52]u8,
};

comptime {
    std.debug.assert(@sizeOf(ApRecord) == 92);
    std.debug.assert(@offsetOf(ApRecord, "rssi") == 44);
    std.debug.assert(@offsetOf(ApRecord, "authmode") == 48);
}

/// `WIFI_MODE_STA`（`esp_wifi_types_generic.h:28`）。
const wifi_mode_sta: c_int = 1;

/// 中断映射表（每项 4 字节：源号 → CLIC 输入号）。源号**不从头文件枚举里数**：按枚举位置数出来的 Wi-Fi 源号
/// 与板上的实况对不上（2026-11-25 实测：blob 实际映射的是源 120 与 122，枚举里数出来是 112 与 114）。
/// 这里一律读映射表的实况。
const intr_map_base: usize = 0x2058_5000;

const esp_wifi_set_mode = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "esp_wifi_set_mode" });
const esp_wifi_start = @extern(*const fn () callconv(.c) c_int, .{ .name = "esp_wifi_start" });
const esp_wifi_scan_start = @extern(*const fn (?*const anyopaque, bool) callconv(.c) c_int, .{ .name = "esp_wifi_scan_start" });
const esp_wifi_scan_get_ap_num = @extern(*const fn (*u16) callconv(.c) c_int, .{ .name = "esp_wifi_scan_get_ap_num" });
const esp_wifi_scan_get_ap_records = @extern(*const fn (*u16, [*]ApRecord) callconv(.c) c_int, .{ .name = "esp_wifi_scan_get_ap_records" });
/// 事件基名 `WIFI_EVENT`（`link_stubs.zig` 导出）：IDF 里它是 `esp_event_base_t`，即**值为指针的变量**
/// （指向字符串 `"WIFI_EVENT"`）。blob 发事件与登记处理函数用的都是这个指针值，所以要取 `WIFI_EVENT.*`。
const WIFI_EVENT: *const *const u8 = @extern(*const *const u8, .{ .name = "WIFI_EVENT" });

var last_event_id: i32 = -1;
var event_count: u32 = 0;
var scan_done: bool = false;
/// 连接阶段的结果（`onWifiEvent` 置位）。
var sta_connected: bool = false;
var sta_disconnected: bool = false;
var disconnect_reason: u8 = 0;
/// 连上之后那 5 秒里有没有掉线（`linkRest()` 报结果用；`connectPhase()` 置位）。
var stayed_connected: bool = false;

/// 记 blob 发出的每一个 `WIFI_EVENT`（`_event_post` → `event_bus.post` 的同步派发）。
fn onWifiEvent(arg: ?*anyopaque, base: ?*const anyopaque, id: i32, data: ?*const anyopaque) callconv(.c) void {
    _ = arg;
    _ = base;
    event_count += 1;
    last_event_id = id;
    const d: usize = @intFromPtr(data);
    // `id = 1` 是 `WIFI_EVENT_SCAN_DONE`，data 指向 `wifi_event_sta_scan_done_t { status, number, scan_id }`。
    if (id == 1) {
        scan_done = true;
        if (data) |dp| {
            const p: *const [3]u8 = @ptrCast(dp);
            log.line("wifi-link-probe: SCAN_DONE status={d} number={d} scan_id={d}", .{ p[0], p[1], p[2] });
        }
    } else if (data) |dp| {
        // `wifi_event_sta_connected_t`：ssid[32]、ssid_len@32、bssid@33、channel@39、authmode@40（枚举，4 字节）、aid@44。
        // `wifi_event_sta_disconnected_t`：ssid[32]、ssid_len@32、bssid@33、reason@39、rssi@40。
        const p: [*]const u8 = @ptrCast(dp);
        if (id == 4) {
            sta_connected = true;
            const authmode = std.mem.readInt(u32, p[40..44], .little);
            log.line("wifi-link-probe: STA_CONNECTED bssid={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} ch={d} authmode={d} aid={d}", .{
                p[33],                                    p[34], p[35], p[36], p[37], p[38], p[39], authmode,
                std.mem.readInt(u16, p[44..46], .little),
            });
        } else if (id == 5) {
            sta_disconnected = true;
            disconnect_reason = p[39];
            log.line("wifi-link-probe: STA_DISCONNECTED bssid={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} reason={d} rssi={d}", .{
                p[33], p[34], p[35], p[36], p[37], p[38], p[39], @as(i8, @bitCast(p[40])),
            });
        }
    }
    log.line("wifi-link-probe: event id={d} data=0x{x:0>8} (n={d})", .{ id, d, event_count });
}
/// 是否在 `esp_wifi_start` 之后做一次全量寄存器 dump（与 oracle 的 `after-start` 同点对照）。
const dump_after_start = true;
/// start 之前的一步。不带任何动作时 `esp_wifi_start` 不返回（2026-11-25 实测：干净的 init → set_mode → start
/// 卡在 start 里）。旧探针在 start 之前做过一批实验写，其中某一步是 start 能返回的前提；这里逐个找出是哪一步。
const PreStart = enum { none, pulse, write, write_keep, write_pulse, timers };
const pre_start: PreStart = .none;
const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);

/// 中断路由与处理函数表的现状：映射寄存器、ROM 表里的非零项、CSR。只读。
fn dumpIrq(tag: []const u8) void {
    const mstatus: usize = asm volatile ("csrr %[v], mstatus"
        : [v] "=r" (-> usize),
    );
    log.line("wifi-link-probe:   hooks: set_isr={d} ints_on={d} ints_off={d} int_dis={d} int_res={d} delay={d} qrecv={d} qsend={d} | events posts={d} dispatched={d} undispatched={d} mine={d}", .{
        impl.calls.set_isr,          impl.calls.ints_on,    impl.calls.ints_off,    impl.calls.wifi_int_disable,
        impl.calls.wifi_int_restore, impl.calls.task_delay, impl.calls.queue_recv,  impl.calls.queue_send,
        event_bus.posts,             event_bus.dispatched,  event_bus.undispatched, event_count,
    });
    // 整张映射表里非零的项：看 blob 到底把哪些源映射到了哪些输入。
    for (0..160) |src| {
        const v = hw.readReg(intr_map_base + src * 4);
        if (v != 0) log.line("wifi-link-probe:   MAP src {d} -> 0x{x:0>8} (input {d})", .{ src, v, v & 0x3F });
    }
    const mie: usize = asm volatile ("csrr %[v], mie"
        : [v] "=r" (-> usize),
    );
    log.line("wifi-link-probe: IRQ[{s}] mstatus.MIE={d} mie=0x{x:0>8}", .{ tag, (mstatus >> 3) & 1, mie });
    // CLIC 每个输入的控制字（与 oracle 的 `clicdump` 对照）：非零的都是被放行的输入。
    for (0..64) |n| {
        const ctl = hw.readReg(0x1080_1000 + n * 4);
        if (ctl != 0) log.line("wifi-link-probe:   CLIC {d} ctl=0x{x:0>8}", .{ n, ctl });
    }
    for (0..48) |n| {
        const h = trap.romHandler(n);
        if (h.fn_) |f| {
            const arg_int: usize = if (h.arg) |a| @intFromPtr(a) else 0;
            log.line("wifi-link-probe:   ROM handler[{d}] fn=0x{x:0>8} arg=0x{x:0>8}", .{ n, @intFromPtr(f), arg_int });
        }
    }
    var line: [200]u8 = undefined;
    var used: usize = 0;
    for (trap.input_counts, 0..) |c, i| {
        if (c == 0) continue;
        const s = std.fmt.bufPrint(line[used..], " {d}:{d}", .{ i, c }) catch break;
        used += s.len;
    }
    log.line("wifi-link-probe:   trap input counts (input:count) ={s}", .{line[0..used]});
}

/// 常驻泵：每一步把 Wi-Fi 任务推进到它再次让出为止。结束时打这一窗的增量。
fn pumpFor(us: u64, tag: []const u8) void {
    const hooks0 = impl.event_count;
    const posts0 = event_bus.posts;
    const t0 = hw.nowUs();
    while (hw.elapsedUs(t0) < us) {
        initp.idleHook();
        stubWatch();
        if (co_pump) |f| f();
    }
    log.line("wifi-link-probe: {s}: {d} us, hooks +{d}, event posts +{d}", .{
        tag, hw.elapsedUs(t0), impl.event_count - hooks0, event_bus.posts - posts0,
    });
}

/// 泵到某个条件成立或超时（与 `pumpFor` 同一个推进点，不打日志）。返回是否等到了。
fn pumpUntil(cond: *const bool, timeout_us: u64) bool {
    const t0 = hw.nowUs();
    while (!cond.*) {
        if (hw.elapsedUs(t0) >= timeout_us) return false;
        initp.idleHook();
        stubWatch();
        if (co_pump) |f| f();
    }
    return true;
}

/// 请求方的进度（`wpa_cb.status()`）。
fn logSupplicant(tag: []const u8) void {
    const s = wpa_cb.status();
    log.line("wifi-link-probe: supplicant[{s}]: state={s} phase={s} msg4_in_flight={} negotiation_done={} pmk={} ptk={} gtk={} rejects={d} last_error={s}", .{
        tag,                s.state.name(),                               s.phase.name(), s.msg4_in_flight,
        s.negotiation_done, s.pmk_set,                                    s.ptk_valid,    s.gtk_valid,
        s.rejects,          if (s.last_error) |e| @errorName(e) else "-",
    });
    // 每次报进度时带上各任务栈的高水位：请求方跑在 blob 的任务栈上，四次握手是它最深的一段。
    logStacks(tag);
}

/// 连接阶段（R3.2.2）：配 STA（管理帧保护先关着，IDF 的默认是通告）→ `esp_wifi_connect_internal()` →
/// 等结果。连上的判据是 `WIFI_EVENT_STA_CONNECTED`：驱动在四次握手完成、钥匙装好之后才发它。
/// 断开时 `WIFI_EVENT_STA_DISCONNECTED` 带原因码。最长等 20 秒，每 2 秒打一次请求方的进度。
fn connectPhase() void {
    const ssid = probe_opts.ap_ssid;
    const password = probe_opts.ap_password;
    if (ssid.len == 0 or ssid.len > 32 or password.len > 64) {
        log.line("wifi-link-probe: connect skipped: ssid {d} B, password {d} B", .{ ssid.len, password.len });
        return;
    }
    var cfg: wpa_cb.StaConfig = .{ .pmf_cfg = .{ .capable = false, .required = false } };
    @memcpy(cfg.ssid[0..ssid.len], ssid);
    @memcpy(cfg.password[0..password.len], password);
    sta_connected = false;
    sta_disconnected = false;
    const cfg_rc = wpa_cb.setStaConfig(&cfg);
    log.line("wifi-link-probe: esp_wifi_set_config(sta) rc=0x{x} (ssid {d} B, password {d} B, pmf off)", .{
        @as(u32, @bitCast(cfg_rc)), ssid.len, password.len,
    });
    if (cfg_rc != 0) return;
    logSupplicant("after set_config");

    const t0 = hw.nowUs();
    const rc = wpa_cb.connect();
    log.line("wifi-link-probe: esp_wifi_connect_internal rc=0x{x}", .{@as(u32, @bitCast(rc))});
    var t_report = t0;
    var reports: u32 = 0;
    while (!sta_connected and !sta_disconnected) {
        if (hw.elapsedUs(t0) > 20_000_000) break;
        initp.idleHook();
        stubWatch();
        if (hw.elapsedUs(t_report) > 2_000_000) {
            t_report = hw.nowUs();
            reports += 1;
            log.line("wifi-link-probe: connect: waiting {d} ms (hooks={d}, events={d})", .{ hw.elapsedUs(t0) / 1000, impl.event_count, event_count });
            logSupplicant("waiting");
        }
    }
    const elapsed_ms = hw.elapsedUs(t0) / 1000;
    if (sta_connected) {
        log.line("wifi-link-probe: CONNECTED in {d} ms ({d} progress reports)", .{ elapsed_ms, reports });
        logSupplicant("connected");
        // 钥匙落进 MAC 密钥表全不全（只打位图，不打钥匙）。
        keyTableCheck();
        coexStage("connected");
        // 数据通路（R3.2.3）：连上之后把驱动的以太网帧接到 IP 栈——DHCP 拿地址，再 ping 网关。
        dataPhase();
        coexStage("after-ping");
        // 连上之后再泵 5 秒：看稳不稳。
        sta_disconnected = false;
        pumpFor(5_000_000, "connected: pump 5 s");
        stayed_connected = !sta_disconnected;
        ipath.stop(); // 断开之前注销收帧回调
        coexStage("before-disconnect");
        if (sta_disconnected) {
            log.line("wifi-link-probe: DROPPED within 5 s: reason={d}", .{disconnect_reason});
        } else {
            log.line("wifi-link-probe: stayed connected for 5 s", .{});
            logSupplicant("after 5 s");
            _ = wpa_cb.disconnect();
            const left = pumpUntil(&sta_disconnected, 5_000_000);
            log.line("wifi-link-probe: esp_wifi_disconnect_internal -> {s} reason={d}", .{ if (left) "DISCONNECTED" else "timeout", disconnect_reason });
        }
    } else if (sta_disconnected) {
        log.line("wifi-link-probe: DISCONNECTED in {d} ms: reason={d}", .{ elapsed_ms, disconnect_reason });
        logSupplicant("disconnected");
    } else {
        log.line("wifi-link-probe: connect: no result in 20 s", .{});
        logSupplicant("timeout");
    }
    coexStage("after-connect-phase");
}

/// `-Dcoex`：真实链路每走到一个阶段就取一次共存核的读数——L4 的证据点：blob 在连接、收发时怎么用共存核，
/// 核怎么答。读数本身在 `init_probe.coexReadings`。关着共存时这个调用点不生成代码。
fn coexStage(stage: []const u8) void {
    if (comptime coex_gate.enabled) initp.coexReadings(stage);
}

/// MAC 密钥表（`hal_crypto_set_key_entry` 写的那张，条目在 `0x201057F8 + 40 × idx`）与请求方手里的钥匙
/// 逐字节对一遍：条目 4 是成对钥匙的 TK，条目 0 是组钥匙 GTK，都在条目的第 16 字节起。**只打位图，不打钥匙**：
/// `equal` 的 bit i = 第 i 字节相等，`ffff` 才是全落进去了。
/// 2026-11-26 靠它定位过：镜像的 `memcpy` 是 compiler_rt 的逐字节循环，而密钥表是整字寄存器堆，每 4 个字节
/// 只剩最后 1 个——握手照常完成，数据帧却双向都解不开。`memcpy` 指到 ROM 的实现（见 `rom_syms.ld`）之后才是 `ffff`。
fn keyTableCheck() void {
    const Entry = struct { name: []const u8, off: usize };
    for ([_]Entry{ .{ .name = "entry 4 (pairwise TK)", .off = 160 }, .{ .name = "entry 0 (group GTK)", .off = 0 } }) |e| {
        var key: [16]u8 = undefined;
        for (0..4) |w| std.mem.writeInt(u32, key[4 * w ..][0..4], hw.readReg(0x2010_57F8 + e.off + 16 + 4 * w), .little);
        const tk = wpa_cb.tkCompare(&key);
        const gtk = wpa_cb.gtkCompare(&key);
        log.line("wifi-link-probe: key table {s}: equal bits vs tk={x:0>4} vs gtk={x:0>4} (nonzero={x:0>4})", .{
            e.name, tk.equal, gtk.equal, tk.other_nonzero,
        });
    }
}

/// 数据通路的进度（`pollDataPath` 置位）。
var dhcp_bound: bool = false;
var ping_done: bool = false;
/// 收帧回调已经交给驱动：之后泵的每一步都要给 IP 栈一个机会处理收到的帧。
var data_path_on: bool = false;

/// 泵的每一步：把 IP 栈这边的事件打出来。跑在主上下文（收帧回调本身在驱动的任务里，只负责拷帧）。
fn pollDataPath() void {
    if (!data_path_on) return;
    var line: [160]u8 = undefined;
    while (ipath.poll(hw.nowUs())) |ev| {
        log.line("wifi-link-probe: net: {s}", .{ipath.report(ev, &line)});
        switch (ev) {
            .bound => dhcp_bound = true,
            .ping_done => ping_done = true,
            else => {},
        }
    }
}

/// 数据通路（R3.2.3）：注册收帧回调 → DHCP 拿地址（最长 12 秒）→ ping 租约里的网关 10 帧（最长 20 秒）。
/// 判据在日志里：`dhcp ACK: bound`、`ping reply`、`ping done`（收到数 > 0）。
fn dataPhase() void {
    dhcp_bound = false;
    ping_done = false;
    const rc = ipath.start();
    log.line("wifi-link-probe: data path: esp_wifi_internal_reg_rxcb rc=0x{x:0>8}", .{@as(u32, @bitCast(rc))});
    if (rc != 0) return;
    data_path_on = true;

    const t0 = hw.nowUs();
    const got = pumpUntil(&dhcp_bound, 12_000_000);
    if (!got) {
        log.line("wifi-link-probe: data path: no DHCP lease in 12 s", .{});
    } else {
        const l = ipath.lease();
        log.line("wifi-link-probe: data path: DHCP bound in {d} ms ip={d}.{d}.{d}.{d} router={d}.{d}.{d}.{d}", .{
            hw.elapsedUs(t0) / 1000, l.ip[0],     l.ip[1],     l.ip[2],     l.ip[3],
            l.router[0],             l.router[1], l.router[2], l.router[3],
        });
        ipath.startPing(10, hw.nowUs());
        const t1 = hw.nowUs();
        _ = pumpUntil(&ping_done, 20_000_000);
        if (!ping_done) log.line("wifi-link-probe: data path: ping did not finish in 20 s", .{});
        log.line("wifi-link-probe: data path: ping phase {d} ms", .{hw.elapsedUs(t1) / 1000});
    }
    const s = ipath.stats();
    log.line("wifi-link-probe: data path: frames rx={d} (ignored {d}, dropped {d}) tx={d} (failed {d})", .{
        s.rx_frames, s.rx_ignored, s.rx_dropped, s.tx_frames, s.tx_failed,
    });
    // 没拿到地址才打驱动的收发统计（IDF `esp_wifi_statis_dump` 的全部模块）：帧到了驱动的哪一层，看这里。
    if (!dhcp_bound) driverStatsDump("dhcp failed");
}

/// 驱动自己的统计，输出走 blob 的日志。
fn driverStatsDump(tag: []const u8) void {
    const dump = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_wifi_statis_dump" });
    const drc = dump(0xFFFF_FFFF);
    log.line("wifi-link-probe: data path: esp_wifi_statis_dump [{s}] rc=0x{x:0>8}", .{ tag, @as(u32, @bitCast(drc)) });
}

var irq_orig: ?*const fn (?*anyopaque) callconv(.c) void = null;
var irq_orig_arg: ?*anyopaque = null;
var irq_logged: u32 = 0;

/// MAC 中断的包装：blob 的 ISR（IRAM+0xfee）开头读这四个状态字再按位分发——
/// `0x20104C48`、`0x20104C34` 的 bit 12、`0x2010D8B8`、`0x2010_D8BC`——这里先原样记下来。
/// 在中断上下文里打串口，只打前 40 次。
fn irqWrapper(_: ?*anyopaque) callconv(.c) void {
    if (irq_logged < 40) {
        irq_logged += 1;
        const s0: u32 = @as(*volatile u32, @ptrFromInt(0x2010_4C48)).*;
        const s1: u32 = @as(*volatile u32, @ptrFromInt(0x2010_4C34)).*;
        const s2: u32 = @as(*volatile u32, @ptrFromInt(0x2010_D8B8)).*;
        const s3: u32 = @as(*volatile u32, @ptrFromInt(0x2010_D8BC)).*;
        log.line("wifi-link-probe: irq mac=0x{x:0>8} mac2=0x{x:0>8} bb=0x{x:0>8} bb1=0x{x:0>8}", .{ s0, s1, s2, s3 });
    }
    if (irq_orig) |f| f(irq_orig_arg);
}

/// 计数桩的增量：两次快照之间哪些桩被调用了（看 blob 在哪个阶段要哪样东西）。
var last_hits: [osi_stubs.field_count]u32 = @splat(0);

fn stubSnapshot(where: []const u8) void {
    for (osi_stubs.hits, 0..) |n, i| {
        if (n != last_hits[i]) {
            log.line("wifi-link-probe: stub since last @{s}: {s} +{d}", .{ where, osi_stubs.names[i], n - last_hits[i] });
            last_hits[i] = n;
        }
    }
}

/// 各块单次读的耗时：每个地址读 16 次取平均。2026-11-26 发现本镜像读 FE 块（0x20100000 起）每个字约
/// 10 ms，而 MAC 块只要几微秒——像是那一片的时钟被门控住了。与 oracle 的 `readtiming` 同点对照。
fn busReadTiming() void {
    const addrs = [_]usize{
        0x2010_0000, 0x2010_0800, 0x2010_1800, 0x2010_4000, 0x2010_7000,
        0x2010_8000, 0x2010_8400, 0x2010_9000, 0x2010_9C00, 0x2010_D000,
        0x2010_D800, 0x2010_F000, 0x2010_F800,
    };
    for (addrs) |a| {
        var acc: u64 = 0;
        var v: u32 = 0;
        for (0..16) |_| {
            const t0 = hw.nowUs();
            v = hw.readReg(a);
            acc += hw.elapsedUs(t0);
        }
        log.line("wifi-link-probe: read 0x{x:0>8}: {d} us avg (last 0x{x:0>8})", .{ @as(u32, @intCast(a)), acc / 16, v });
    }
}

/// 逐字读一遍、只记耗时：全量 dump FE 块时每行要 80 多毫秒（2026-11-26 实测），而单读某个地址只要
/// 1 微秒——是**个别地址**读得慢。这里找出是哪些地址（读一次、超过 500 微秒的算慢），
/// 之后的有选择 dump 就避开它们。
fn busTimingMap(name: []const u8, base: usize, n: usize) void {
    var total: u64 = 0;
    var slow: u32 = 0;
    var worst: u64 = 0;
    var worst_addr: usize = 0;
    var listed: u32 = 0;
    for (0..n) |i| {
        const a = base + 4 * i;
        const t0 = hw.nowUs();
        const v = hw.readReg(a);
        const dt = hw.elapsedUs(t0);
        total += dt;
        if (dt > 500) {
            slow += 1;
            if (listed < 24) {
                listed += 1;
                log.line("wifi-link-probe: slow read 0x{x:0>8}: {d} us (0x{x:0>8})", .{ @as(u32, @intCast(a)), dt, v });
            }
        }
        if (dt > worst) {
            worst = dt;
            worst_addr = a;
        }
    }
    log.line("wifi-link-probe: timing[{s}]: {d} reads, {d} us total, slow={d}, worst 0x{x:0>8} at {d} us", .{
        name, n, total, slow, @as(u32, @intCast(worst_addr)), worst,
    });
}

/// 泵的每一步之后看计数桩有没有被调：两次快照之间有增量的桩各打一行（与 `stubSnapshot` 共用基准）。
fn stubWatch() void {
    for (osi_stubs.hits, 0..) |n, i| {
        if (n != last_hits[i]) {
            log.line("wifi-link-probe: stub {s} +{d}", .{ osi_stubs.names[i], n - last_hits[i] });
            last_hits[i] = n;
        }
    }
    pollTaskStacks();
    pollDataPath();
    // 被拒的队列句柄：第一个被拒的句柄、blob 侧调用点、拒了多少次（`unwrapQueue` 的诊断）。
    if (impl.bad_queue_n != bad_seen) {
        log.line("wifi-link-probe: bad queue handle: n={d} handle=0x{x:0>8} blob ra=0x{x:0>8}", .{
            impl.bad_queue_n, impl.bad_queue_handle, impl.bad_queue_ra,
        });
        bad_seen = impl.bad_queue_n;
    }
}
var bad_seen: u32 = 0;
var tasks_seen: usize = 0;
var refused_seen: u32 = 0;
var overflow_reported: [4]bool = @splat(false);

// ---------------------------------------------------------------------------
// 任务栈：谁建的、多大、用了多少、有没有过界
// ---------------------------------------------------------------------------
/// 泵的每一步：新建的任务各打一行（名字、入口、blob 给的栈深、实际栈区间）；护栏被动过的任务只报一次。
fn pollTaskStacks() void {
    if (impl.task_create_refused != refused_seen) {
        refused_seen = impl.task_create_refused;
        log.line("wifi-link-probe: task table full: _task_create refused {d} time(s)", .{refused_seen});
    }
    while (tasks_seen < impl.task_count) : (tasks_seen += 1) {
        const t = &impl.tasks[tasks_seen];
        log.line("wifi-link-probe: task[{d}] {s} entry=0x{x:0>8} arg=0x{x:0>8} requested stack={d} -> {d} B at 0x{x:0>8}..0x{x:0>8}", .{
            tasks_seen,        taskName(t), @intFromPtr(t.entry),     @intFromPtr(t.arg),
            t.requested_depth, t.stack.len, @intFromPtr(t.stack.ptr), @intFromPtr(t.stack.ptr) + t.stack.len,
        });
    }
    for (impl.tasks[0..impl.task_count], 0..) |*t, i| {
        if (t.stack.len == 0 or overflow_reported[i]) continue;
        if (!t.stackOverflowed()) continue;
        overflow_reported[i] = true;
        log.line("wifi-link-probe: task[{d}] {s} STACK OVERFLOW: {d} B at 0x{x:0>8}, the guard below it has been written (used>={d})", .{
            i, taskName(t), t.stack.len, @intFromPtr(t.stack.ptr), t.stackUsed(),
        });
    }
}

fn taskName(t: *const impl.Task) []const u8 {
    const n = std.mem.sliceTo(&t.name, 0);
    return if (n.len > 0) n else "(unnamed)";
}

/// 各任务栈的高水位（已用/总量的字节数），一行打完。进度报告用。
fn logStacks(tag: []const u8) void {
    var line: [192]u8 = undefined;
    var used: usize = 0;
    for (impl.tasks[0..impl.task_count], 0..) |*t, i| {
        if (t.stack.len == 0) continue;
        const s = std.fmt.bufPrint(line[used..], " {d}:{s}={d}/{d}", .{ i, taskName(t), t.stackUsed(), t.stack.len }) catch break;
        used += s.len;
    }
    log.line("wifi-link-probe: stacks[{s}]:{s}", .{ tag, line[0..used] });
}

/// 实验：MAC 中断相关的三个字两边不同，按对照镜像的值写一遍，再扫描。
/// 帧已经到了 MAC（0x201040B8 起是硬件抓到的完整信标：`0x0080`、DA 广播、SA=BSSID、序号、时间戳），
/// 但主机侧收不到——接收完成中断从没来过（ISR 入口的状态字只有 bit 7）。这三个字里可能是接收中断的使能位。
/// 上一轮试过的另一组字（0x201042F4 等）写了读回不变，是只读状态，不是配置。
fn macMirrorExperiment() void {
    const W = struct { addr: usize, val: u32 };
    const writes = [_]W{
        .{ .addr = 0x2010_4C44, .val = 0x0400_041F },
        .{ .addr = 0x2010_4C54, .val = 0x1F89_D800 },
        .{ .addr = 0x2010_4C58, .val = 0x0BCE_E4F7 },
    };
    for (writes) |w| {
        const p: *volatile u32 = @ptrFromInt(w.addr);
        const before = p.*;
        p.* = w.val;
        log.line("wifi-link-probe: mac 0x{x:0>8}: 0x{x:0>8} -> 0x{x:0>8}", .{ @as(u32, @intCast(w.addr)), before, p.* });
    }
}

/// 驱动的信道管理器：`g_chm`（0x2f07ff88）持有它的指针。`[4]` 是目标信道、`[82]` 是驱动记的当前信道；
/// blob 在"这是芯片"时靠两者是否相等决定扫描前要不要真的切一次信道（扫描起始函数，flash 0x40029260）。
fn chmDump(tag: []const u8) void {
    const p: *const volatile usize = @ptrFromInt(0x2f07_ff88);
    if (p.* < 0x2f00_0000 or p.* >= 0x2f08_0000) {
        log.line("wifi-link-probe: chm[{s}]: g_chm=0x{x:0>8} (not a pointer)", .{ tag, p.* });
        return;
    }
    const obj: *const volatile [96]u8 = @ptrFromInt(p.*);
    log.line("wifi-link-probe: chm[{s}]: obj=0x{x:0>8} [0..8]={x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} [80..84]={x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        tag,     p.*,     obj[0], obj[1], obj[2],  obj[3],
        obj[4],  obj[5],  obj[6], obj[7], obj[80], obj[81],
        obj[82], obj[83],
    });
}

/// 实验：把 PMU 的电源配置按对照镜像 `esp_wifi_start` 之后的值写一遍。对照镜像的 `pmu_init()` 在启动期写
/// 这些，本镜像停在复位值：`HP_ACTIVE_HP_CK_POWER` 里 `XPD_XTALX2`/`XPD_CPLL`/`XPD_BBPLL` 都没置位，
/// 各电源域的 `FORCE_PU`/`FORCE_NO_RESET`/`FORCE_NO_ISO` 还在（对照里是 0，交给 PMU 状态机）。
/// 电压档（`HP_ACTIVE_HP_REGULATOR0`）先不动。值取自两边的同点 dump（`after-start`）。
fn pmuMirrorActive() void {
    const W = struct { addr: usize, val: u32 };
    const writes = [_]W{
        .{ .addr = 0x2070_4018, .val = 0x0080_0000 }, // HP_ACTIVE_HP_SYS_CNTL
        .{ .addr = 0x2070_401C, .val = 0x19C0_0000 }, // HP_ACTIVE_HP_CK_POWER
        .{ .addr = 0x2070_4020, .val = 0x0200_0000 }, // HP_ACTIVE_BIAS
        .{ .addr = 0x2070_4024, .val = 0x0100_00A0 }, // HP_ACTIVE_BACKUP
        .{ .addr = 0x2070_4028, .val = 0xFFFF_FFFF }, // HP_ACTIVE_BACKUP_CLK
        .{ .addr = 0x2070_402C, .val = 0xFFFF_FFFF }, // HP_ACTIVE_BACKUP1_CLK
        .{ .addr = 0x2070_4030, .val = 0x0800_0000 }, // HP_ACTIVE_SYSCLK
        .{ .addr = 0x2070_4120, .val = 0 }, // POWER_PD_TOP_CNTL
        .{ .addr = 0x2070_4124, .val = 0 }, // POWER_PD_HP_ALIVE_CNTL
        .{ .addr = 0x2070_4128, .val = 0 }, // POWER_PD_MODEM_PWR_CNTL
        .{ .addr = 0x2070_412C, .val = 0 }, // POWER_PD_HPCPU_CNTL
        .{ .addr = 0x2070_4130, .val = 0 }, // POWER_PD_HPCNNT_CNTL
        .{ .addr = 0x2070_4134, .val = 0 }, // POWER_PD_MODEM_TOP_CNTL
        .{ .addr = 0x2070_4138, .val = 0 }, // POWER_PD_LPPERI_CNTL
        .{ .addr = 0x2070_413C, .val = 0 }, // POWER_PD_MEM_CNTL
    };
    for (writes) |w| {
        const p: *volatile u32 = @ptrFromInt(w.addr);
        const before = p.*;
        p.* = w.val;
        log.line("wifi-link-probe: pmu 0x{x:0>8}: 0x{x:0>8} -> 0x{x:0>8}", .{ @as(u32, @intCast(w.addr)), before, p.* });
    }
}

/// 扫描结果缓冲。这个射频环境里两次实测数到 32 和 41 个 AP（对照镜像同一时段 36 个），所以留 64 个
/// （`wifi_ap_record_t` 92 字节一条，放静态区，不占探针任务的栈）。
var scan_records: [64]ApRecord = undefined;

pub fn run() noreturn {
    log.raw("wifi-link-probe: begin\n");
    initp.idle_quiet = true;
    // 诊断用：把 blob 的日志开到 VERBOSE（扫描子模块每一步等的是什么都在这一级）。
    initp.blob_log_level = 5;
    // 诊断用：共存胶水的每一个钩子被 blob 调到时都打一行。
    initp.coex_trace_all = true;
    // 与对照镜像对齐：它的 sdkconfig 下 `WIFI_FEATURE_CAPS` = WPA3_SAE | GMAC | ENTERPRISE | BSS_MAX_IDLE |
    // OWE_SOFTAP = 0x5A1。`init_config.zig` 里的 0x1a1 只少最后那一位（2026-11-26 逐项核对 sdkconfig）。
    initp.feature_caps = 0x5A1;

    const init_rc = initp.initOnly(.{ .experiments = false });
    stubSnapshot("init");
    chmDump("init");
    log.line("wifi-link-probe: init rc={d}", .{init_rc});
    if (init_rc != 0) hw.halt();

    _ = event_bus.esp_event_handler_register(WIFI_EVENT.*, -1, onWifiEvent, null);
    const mode_rc = esp_wifi_set_mode(wifi_mode_sta);
    log.line("wifi-link-probe: esp_wifi_set_mode(STA) rc=0x{x}", .{@as(u32, @bitCast(mode_rc))});

    switch (pre_start) {
        .none => log.raw("wifi-link-probe: pre-start: none\n"),
        .pulse => {
            _ = impl.callResetMac();
            log.line("wifi-link-probe: pre-start: rst_wifimac pulse, MAC_ST=0x{x:0>8}", .{mac_st.*});
        },
        .write => {
            mac_st.* = 0x00FF_1000;
            const kept = mac_st.*;
            mac_st.* = 0;
            log.line("wifi-link-probe: pre-start: MAC_ST <- 0x00ff1000 read 0x{x:0>8}, <- 0 read 0x{x:0>8}", .{ kept, mac_st.* });
        },
        .write_keep => {
            mac_st.* = 0x00FF_1000;
            log.line("wifi-link-probe: pre-start: MAC_ST <- 0x00ff1000 read 0x{x:0>8}", .{mac_st.*});
        },
        .write_pulse => {
            mac_st.* = 0x00FF_1000;
            _ = impl.callResetMac();
            mac_st.* = 0;
            log.line("wifi-link-probe: pre-start: MAC_ST <- 0x00ff1000, rst_wifimac pulse, <- 0, read 0x{x:0>8}", .{mac_st.*});
        },
        .timers => {
            const armed = impl.forceArmAll();
            pumpFor(100_000, "timers: pump after force-arm");
            const st = impl.timerStats();
            log.line("wifi-link-probe: pre-start: force-arm {d} timers, fires={d} armed={d}", .{ armed, st & 0xFFFF_FFFF, st >> 32 });
        },
    }
    dumpIrq("before-start");
    const start_rc = esp_wifi_start();
    log.line("wifi-link-probe: esp_wifi_start rc=0x{x} (hooks={d}, events={d})", .{
        @as(u32, @bitCast(start_rc)), impl.event_count, event_count,
    });
    dumpIrq("after-start");
    // 把 MAC 中断包一层：blob 的 ISR 开头读四个状态字再按位分发，这里先把它们原样打出来，
    // 看每次中断到底是什么。分发先查应用侧的表，所以盖掉下标 1 即可。
    {
        const h = trap.getHandler(1);
        irq_orig = h.fn_;
        irq_orig_arg = h.arg;
        trap.setHandler(1, &irqWrapper, null);
        log.line("wifi-link-probe: irq wrap: orig fn=0x{x:0>8} arg=0x{x:0>8}", .{ @intFromPtr(irq_orig), @intFromPtr(irq_orig_arg) });
    }
    stubSnapshot("after-start");
    chmDump("after-start");
    if (dump_after_start) initp.regDumpAll("after-start");
    coexStage("after-start");
    // 晶振频率这条线：PHY 的 `phy_get_xtal_freq` 把 `xtal - 1` 写进 `MODEM_LPCON_TICK_CONF` 的低 6 位
    // （对照镜像 40 MHz 晶振读回 0x27；修复前这里是 0x3F）。
    {
        const xtal_get = @extern(*const fn () callconv(.c) u32, .{ .name = "rtc_clk_xtal_freq_get" });
        const tick: u32 = hw.readReg(0x2010_F028);
        log.line("wifi-link-probe: xtal={d} MHz, MODEM_LPCON_TICK_CONF=0x{x:0>8} (low6={d} = xtal-1)", .{
            xtal_get(), tick, tick & 0x3F,
        });
    }
    macMirrorExperiment();

    // 先不开中断泵半秒：看任务有没有自己在走（定时器、事件）。
    pumpFor(500_000, "pump, interrupts off");

    // 开中断。blob 在 start 里经 ROM 的 `intr_matrix_set` 把自己的中断源映射到了某个 CLIC 输入，
    // 经 `_set_isr(1, fn)` 把 ISR 装在 ROM 表 [1]，经 `_ints_on(2)` 置了 IE 位——但没人设优先级，
    // 优先级 0 的电平输入不会触发。这里按映射表的实况，给每个有源映射过去的输入补上优先级 1。
    var mie_bits: usize = 0;
    var src: usize = 0;
    while (src < 160) : (src += 1) {
        const input: u5 = @intCast(hw.readReg(intr_map_base + src * 4) & 0x3F);
        if (input < 16) continue;
        // 只开装了处理函数的输入：别的源即使映射了也不碰。
        if (trap.romHandler(input - 16).fn_ == null) continue;
        const ctl: *volatile u32 = @ptrFromInt(0x1080_1000 + @as(usize, input) * 4);
        ctl.* |= (1 << 24) | (1 << 8);
        if (mie_bits & (@as(usize, 1) << input) == 0)
            log.line("wifi-link-probe: enable interrupts: CLIC input {d}: prio=1 IE=1 (src {d} mapped here)", .{ input, src });
        mie_bits |= @as(usize, 1) << input;
    }
    asm volatile ("csrs mie, %[m]"
        :
        : [m] "r" (mie_bits),
    );
    hw.enableInterrupts();
    pumpFor(2_000_000, "pump, interrupts on");
    dumpIrq("after-irq-pump");
    stubSnapshot("after-irq-pump");
    chmDump("after-irq-pump");

    // 扫描那一段也要能看到：trace 共 200 行，init + start 已经用完，这里清零重新计。
    // 注意每行约 70 字节、6 ms 的串口时间，追踪本身会拖慢扫描；只用于诊断。
    const trace_scan = true;
    if (trace_scan) initp.trace_lines = 0;
    // 扫描：`config = NULL` 是 blob 的默认配置（全信道主动扫描）。与 oracle 同步：非阻塞启动，等 100 ms
    // （射频已开、驱动在跳信道）做一次 `in-scan` dump，等到 SCAN_DONE 事件再做一次 `after-scan` dump。
    const dump_in_scan = true;
    const t_scan = hw.nowUs();
    const scan_rc = esp_wifi_scan_start(null, false);
    log.line("wifi-link-probe: esp_wifi_scan_start(NULL, nonblock) rc=0x{x}", .{@as(u32, @bitCast(scan_rc))});
    pumpFor(100_000, "scan: first 100 ms");
    chmDump("in-scan");
    if (dump_in_scan) {
        // 定点采样放在最前：两边都在扫描开始后 100 ms 打这一份，这才是同一相位的收发态。
        initp.focusDump("in-scan");
        initp.regDumpAll("in-scan");
        initp.macDumpAll("in-scan");
    }
    const scan_got = pumpUntil(&scan_done, 10_000_000);
    log.line("wifi-link-probe: wait scan-done 10s -> {s} in {d} ms (hooks={d}, events={d})", .{
        if (scan_got) "GOT" else "timeout", hw.elapsedUs(t_scan) / 1000, impl.event_count, event_count,
    });
    if (dump_in_scan) {
        initp.regDumpAll("after-scan");
        initp.macDumpAll("after-scan");
        // 与 oracle 同序：扫描已结束的空闲态。定点采样与全量块 dump 都放在这里比，
        // 收发态只比上面那一份定点采样（本镜像 dump 期间扫描是停着的，对方不是）。
        initp.focusDump("after-scan");
        initp.rangeDumpAll();
    }
    coexStage("after-scan");

    dumpIrq("after-scan");
    for (osi_stubs.hits, 0..) |n, i| {
        if (n != 0) log.line("wifi-link-probe:   counting stub {s} hits={d}", .{ osi_stubs.names[i], n });
    }
    var n: u16 = 0;
    const num_rc = esp_wifi_scan_get_ap_num(&n);
    log.line("wifi-link-probe: esp_wifi_scan_get_ap_num rc=0x{x} n={d}", .{ @as(u32, @bitCast(num_rc)), n });
    if (num_rc == 0 and n > 0) {
        var got: u16 = @min(n, scan_records.len);
        const rec_rc = esp_wifi_scan_get_ap_records(&got, &scan_records);
        log.line("wifi-link-probe: esp_wifi_scan_get_ap_records rc=0x{x} got={d}", .{ @as(u32, @bitCast(rec_rc)), got });
        if (rec_rc == 0) {
            var i: u16 = 0;
            while (i < got) : (i += 1) {
                const r = scan_records[i];
                var ssid_len: usize = 0;
                while (ssid_len < r.ssid.len and r.ssid[ssid_len] != 0) : (ssid_len += 1) {}
                log.line("wifi-link-probe: ap[{d}] bssid={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} ssid=\"{s}\" ch={d} rssi={d} auth={d}", .{
                    i,                   r.bssid[0], r.bssid[1], r.bssid[2], r.bssid[3], r.bssid[4], r.bssid[5],
                    r.ssid[0..ssid_len], r.primary,  r.rssi,     r.authmode,
                });
            }
        }
    }
    // 连接阶段（R3.2.2）：构建时给了 AP 的 SSID 才做。
    if (probe_opts.ap_ssid.len > 0) {
        connectPhase();
    } else {
        log.raw("wifi-link-probe: connect phase skipped (no -Dwifi-ap-ssid)\n");
    }
    log.raw("wifi-link-probe: done\n");
    hw.halt();
}

// ---------------------------------------------------------------------------
// 合并镜像用的真实链路步骤（`firmware/src/coex_merged.zig`，`-Dcoex-wifi-link`）
// ---------------------------------------------------------------------------

/// `linkRest()` 的结果。每一步的细节都在日志里（前缀 `wifi-link:` 与 `wifi-link-probe:`），这里只留判据要用的几项。
pub const LinkResult = struct {
    scan_done: bool = false,
    /// 全信道扫描结束时的 AP 数；扫描超时就是超时那一刻的数。
    ap_num: u16 = 0,
    /// 构建时没给 AP 的 SSID 时连接阶段整段不做，下面几项保持初值。
    connect_attempted: bool = false,
    connected: bool = false,
    dhcp: bool = false,
    ping_done: bool = false,
    /// 连上之后那 5 秒里没有断开。
    stayed: bool = false,
    /// 连接阶段结束时的断开原因码；本地主动断开是 8。
    disconnect_reason: u8 = 0,
};

fn logArena(tag: []const u8) void {
    log.line("wifi-link: arena[{s}]: free={d}/{d} B", .{ tag, impl.arena_state.bytes_free, impl.arena_state.bytes_total });
}

/// 只做一次全信道扫描，返回扫到的 AP 数。合并镜像用它在 BLE 的 init 之前先量一次，作为"Wi-Fi 单独在合并镜像里
/// 正不正常"的基线。
pub fn linkScan(tag: []const u8) u16 {
    scan_done = false;
    const t0 = hw.nowUs();
    const rc = esp_wifi_scan_start(null, false);
    log.line("wifi-link: scan[{s}]: esp_wifi_scan_start rc=0x{x}", .{ tag, @as(u32, @bitCast(rc)) });
    const got = pumpUntil(&scan_done, 10_000_000);
    var n: u16 = 0;
    const num_rc = esp_wifi_scan_get_ap_num(&n);
    log.line("wifi-link: scan[{s}]: {s} in {d} ms, esp_wifi_scan_get_ap_num rc=0x{x} n={d}", .{
        tag, if (got) "GOT" else "timeout", hw.elapsedUs(t0) / 1000, @as(u32, @bitCast(num_rc)), n,
    });
    return n;
}

/// 合并镜像用的真实链路主干，分两段：`linkStart()`（`esp_wifi_set_mode` → `esp_wifi_start` → 开 blob 的中断）与
/// `linkRest()`（全信道扫描 → 构建时给了 AP 的 SSID 才做：连接、DHCP、ping 网关、断开）。`initOnly` 已经由调用方
/// 做过。不带 `run()` 里的诊断（寄存器转储、ISR 包装、镜像实验、计数桩快照）。泵每走一步之后调 `co_pump`。
///
/// 分两段是为了让调用方能安排顺序：PHY 库的一次性初始化与标定只认第一次使能，谁先使能谁做。合并镜像里
/// （`-Dcoex-wifi-link`）要 Wi-Fi 来做这一次，就在 `linkStart()` 之后才做 BLE 的 init 与 enable，再调 `linkRest()`。
/// `linkStart()` 返回 `esp_wifi_start` 的返回码（0 = 已经 start 并开了中断）。
pub fn linkStart() c_int {
    initp.idle_quiet = true;

    _ = event_bus.esp_event_handler_register(WIFI_EVENT.*, -1, onWifiEvent, null);
    const mode_rc = esp_wifi_set_mode(wifi_mode_sta);
    log.line("wifi-link: esp_wifi_set_mode(STA) rc=0x{x}", .{@as(u32, @bitCast(mode_rc))});

    const start_rc = esp_wifi_start();
    log.line("wifi-link: esp_wifi_start rc=0x{x} (hooks={d}, events={d})", .{
        @as(u32, @bitCast(start_rc)), impl.event_count, event_count,
    });
    if (start_rc != 0) return start_rc;
    coexStage("after-start");

    // 先不开中断泵半秒，再按映射表的实况开中断——与 `run()` 里同一段，原因见那里的注释：blob 在 start 里
    // 装好了 ISR 和映射，但没人给电平输入设优先级，优先级 0 的输入不会触发。
    pumpFor(500_000, "pump, interrupts off");
    var mie_bits: usize = 0;
    var inputs: u32 = 0;
    var src: usize = 0;
    while (src < 160) : (src += 1) {
        const input: u5 = @intCast(hw.readReg(intr_map_base + src * 4) & 0x3F);
        if (input < 16) continue;
        if (trap.romHandler(input - 16).fn_ == null) continue;
        const ctl: *volatile u32 = @ptrFromInt(0x1080_1000 + @as(usize, input) * 4);
        ctl.* |= (1 << 24) | (1 << 8);
        mie_bits |= @as(usize, 1) << input;
        inputs += 1;
    }
    log.line("wifi-link: enable interrupts: {d} inputs, mie=0x{x:0>16}", .{ inputs, mie_bits });
    asm volatile ("csrs mie, %[m]"
        :
        : [m] "r" (mie_bits),
    );
    hw.enableInterrupts();
    pumpFor(2_000_000, "pump, interrupts on");
    logArena("after start");
    return 0;
}

/// 后半段：全信道扫描 →（构建时给了 AP 的 SSID 才做）连接、DHCP、ping 网关、断开。要求 `linkStart()` 已经返回 0。
pub fn linkRest() LinkResult {
    var r: LinkResult = .{};

    // 全信道主动扫描（`config = NULL` 是 blob 的默认配置），最长等 10 秒。
    // 前面可能已经扫过一次（合并镜像里 BLE 的 init 之前的基线扫描），先把上一次的完成标志清掉。
    scan_done = false;
    const t_scan = hw.nowUs();
    const scan_rc = esp_wifi_scan_start(null, false);
    log.line("wifi-link: esp_wifi_scan_start(NULL, nonblock) rc=0x{x}", .{@as(u32, @bitCast(scan_rc))});
    const scan_got = pumpUntil(&scan_done, 10_000_000);
    r.scan_done = scan_got;
    log.line("wifi-link: wait scan-done 10s -> {s} in {d} ms", .{ if (scan_got) "GOT" else "timeout", hw.elapsedUs(t_scan) / 1000 });
    var n: u16 = 0;
    const num_rc = esp_wifi_scan_get_ap_num(&n);
    r.ap_num = n;
    log.line("wifi-link: esp_wifi_scan_get_ap_num rc=0x{x} n={d}", .{ @as(u32, @bitCast(num_rc)), n });
    logArena("after scan");
    coexStage("after-scan");

    if (probe_opts.ap_ssid.len > 0) {
        r.connect_attempted = true;
        connectPhase();
        r.connected = sta_connected;
        r.dhcp = dhcp_bound;
        r.ping_done = ping_done;
        r.stayed = stayed_connected;
        r.disconnect_reason = disconnect_reason;
    } else {
        log.raw("wifi-link: connect phase skipped (no -Dwifi-ap-ssid)\n");
    }
    logArena("after connect");
    log.line("wifi-link: result scan={} ap={d} connected={} dhcp={} ping={} stayed={} reason={d}", .{
        r.scan_done, r.ap_num, r.connected, r.dhcp, r.ping_done, r.stayed, r.disconnect_reason,
    });
    return r;
}
