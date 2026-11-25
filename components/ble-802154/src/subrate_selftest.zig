//! ble-802154：Connection Subrating（`subrate.zig`）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 经 `extCheck` 调用。不 import board，
//! 不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据（主机测试 `subrate_tests.zig` 覆盖得更细，这里每块只挑代表；括号里是条款号，
//! HCI 在 [Vol 4] Part E，链路层在 [Vol 6] Part B）：
//!
//!   ① LE Set Default Subrate 已知答案，五个参数八位组（§7.8.123 参数表的默认值行）
//!   ② LE Subrate Request 已知答案 + 乘积越界被拒（§7.8.124 的 0x12）
//!   ③ LE Subrate Change 事件逐字段解码（§7.7.65.35）
//!   ④ LL_SUBRATE_REQ 的 11 字节已知答案（§2.4.2.36）
//!   ⑤ LL_SUBRATE_IND 的已知答案 + continuation ≥ factor 被拒（§2.4.2.37、§4.5.1）
//!   ⑥ §5.1.20 全部条件成立时的四个结果参数（6218–6221）
//!   ⑦ §5.1.20 R1 与 R5 各拒一次（6212、6216）
//!   ⑧ Host Support 位没设 → 拒（6209）
//!   ⑨ Central 往 IND 里放的 base 高 2 位随排队事件（§7.8.124 Central 规则 + §5.1.19 6203）
//!   ⑩ Peripheral 收 IND：计数器 15-14 = 00 且 base 15-14 = 11 → base 回绕修正
//!     （§5.1.19 6203 + §4.5.1 4799）
//!   ⑪ 有效连接间隔换算 connInterval × factor × (latency+1)（§4.5.1 4794 的乘积）
//!   ⑫ host 模型：请求 → 事件对账 → 参数更新（§7.8.124 → §7.7.65.35）
//!   ⑬ host 模型：40 s 过程响应超时（§5.2 6238）
//!   ⑭ handle 对不上 → 拒（§7.8.124 的 0x02 路径）
//!
//! 每个判据函数单独 `noinline`（ReleaseSmall 会把内联函数的大数组叠进同一个栈帧，
//! 板侧主栈标称只有 16 KiB）；缓冲都在文件作用域。

const std = @import("std");

const subrate = @import("subrate.zig");

fn nib(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("不是十六进制字符"),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    inline for (0..s.len / 2) |i| {
        out[i] = (nib(s[2 * i]) << 4) | nib(s[2 * i + 1]);
    }
    return out;
}

var g_buf: [32]u8 = undefined;

const p_req: subrate.SubrateParams = .{
    .subrate_min = 2,
    .subrate_max = 4,
    .max_latency = 4,
    .continuation_number = 2,
    .supervision_timeout = 100,
};

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    commands(check);
    pdu(check);
    verdict(check);
    arithmetic(check);
    model(check);
}

// ①–② 命令
fn commands(comptime check: fn (bool, []const u8) void) void {
    // §7.8.123 默认值行：0x0001/0x0001/0x0000/0x0000/0x0C80；帧 = 01 7D20 0A + 五个 u16。
    if (subrate.cmdSetDefaultSubrate(&g_buf, subrate.SubrateParams.default)) |n| {
        check(n == 14 and std.mem.eql(u8, &hex("017d200a0100010000000000800c"), g_buf[0..n]), "subrate 7.8.123 set default subrate: defaults known answer");
    } else |_| {
        check(false, "subrate 7.8.123 set default subrate: encode error");
    }
    // §7.8.124：handle + 五个参数；乘积 8×63=504>500 被拒（0x12 的第一条）。
    if (subrate.cmdSubrateRequest(&g_buf, 0x0B12, p_req, 12)) |n| {
        check(n == 16 and std.mem.eql(u8, &hex("017e200c120b02000400040002006400"), g_buf[0..n]), "subrate 7.8.124 subrate request: known answer");
    } else |_| {
        check(false, "subrate 7.8.124 subrate request: encode error");
    }
    const product_bad: subrate.SubrateParams = .{
        .subrate_min = 2,
        .subrate_max = 8,
        .max_latency = 62,
        .continuation_number = 2,
        .supervision_timeout = 1000,
    };
    const rejected = if (subrate.cmdSubrateRequest(&g_buf, 1, product_bad, 12)) |_| false else |e| e == error.LatencyProductOver500;
    check(rejected, "subrate 7.8.124 0x12: Subrate_Max*63=504 > 500 rejected");
}

// ③–⑤ 事件与 LL PDU
fn pdu(comptime check: fn (bool, []const u8) void) void {
    // §7.7.65.35：Status(1) + handle(2) + factor(2) + latency(2) + cont(2) + tmo(2)。
    const ev_params = hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "0200" ++ "f401");
    if (subrate.decodeSubrateChange(&ev_params)) |ev| {
        check(ev.handle == 0x0B12 and ev.subrate_factor == 4 and ev.peripheral_latency == 3 and ev.continuation_number == 2 and ev.supervision_timeout == 500, "subrate 7.7.65.35 subrate change event: field split");
    } else |_| {
        check(false, "subrate 7.7.65.35 subrate change event: decode error");
    }
    // §2.4.2.36：Opcode(0x26) + 五字段 CtrData。
    if (subrate.encodeSubrateReq(&g_buf, p_req)) |n| {
        check(n == 11 and std.mem.eql(u8, &hex("2602000400040002006400"), g_buf[0..n]), "subrate 2.4.2.36 LL_SUBRATE_REQ: known answer");
    } else |_| {
        check(false, "subrate 2.4.2.36 LL_SUBRATE_REQ: encode error");
    }
    // §2.4.2.37 + §4.5.1：合法 IND 编解码；cont ≥ factor 是非法编码。
    if (subrate.encodeSubrateInd(&g_buf, .{
        .subrate_factor = 4,
        .subrate_base_event = 100,
        .peripheral_latency = 3,
        .continuation_number = 2,
        .supervision_timeout = 500,
    })) |n| {
        const round = subrate.decodeSubrateInd(g_buf[0..n]) catch null;
        check(n == 11 and round != null and round.?.subrate_factor == 4 and round.?.subrate_base_event == 100, "subrate 2.4.2.37 LL_SUBRATE_IND: round-trip");
    } else |_| {
        check(false, "subrate 2.4.2.37 LL_SUBRATE_IND: encode error");
    }
    const cont_bad = hex("270400640003000400f401"); // cont 4 ≥ factor 4
    const cont_rejected = if (subrate.decodeSubrateInd(&cont_bad)) |_| false else |e| e == error.BadParam;
    check(cont_rejected, "subrate 4.5.1 IND: continuation >= factor rejected");
}

// ⑥–⑧ 判决
fn verdict(comptime check: fn (bool, []const u8) void) void {
    const acc: subrate.SubrateParams = .{
        .subrate_min = 2,
        .subrate_max = 8,
        .max_latency = 4,
        .continuation_number = 3,
        .supervision_timeout = 100,
    };
    // §5.1.20 接受：factor=min(8,4)=4、cont=min(max(3,2),3)=3、lat=min(4,4)=4、tmo=min(100,100)=100。
    if (subrate.centralVerdict(acc, p_req, true, false, 12)) |v| {
        const a = v.accept;
        check(v == .accept and a.subrate_factor == 4 and a.continuation_number == 3 and a.peripheral_latency == 4 and a.supervision_timeout == 100, "subrate 5.1.20 accept: four result values per 6218-6221");
    } else |_| {
        check(false, "subrate 5.1.20 accept: verdict error");
    }
    // R1（6212）：latency 超过 acceptable。
    const r1_req: subrate.SubrateParams = .{ .subrate_min = 2, .subrate_max = 4, .max_latency = 5, .continuation_number = 2, .supervision_timeout = 100 };
    if (subrate.centralVerdict(acc, r1_req, true, false, 12)) |v| {
        check(v == .reject and v.reject.reason == .params_not_acceptable and v.reject.rule == .r1_latency, "subrate 5.1.20 R1: latency over acceptable rejected");
    } else |_| {
        check(false, "subrate 5.1.20 R1: verdict error");
    }
    // R5（6216）：2×ci×fmin×(lat+1) ≥ tmo；ci=8、fmin=8、lat=0、tmo=16 恰好相等。
    const r5_req: subrate.SubrateParams = .{ .subrate_min = 8, .subrate_max = 8, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 16 };
    if (subrate.centralVerdict(acc, r5_req, true, false, 8)) |v| {
        check(v == .reject and v.reject.rule == .r5_supervision, "subrate 5.1.20 R5: 2*ci*fmin >= timeout rejected at equality");
    } else |_| {
        check(false, "subrate 5.1.20 R5: verdict error");
    }
    // 6209：Host Support 位没设 → 必须拒。
    if (subrate.centralVerdict(acc, p_req, false, false, 12)) |v| {
        check(v == .reject and v.reject.reason == .host_support_not_set, "subrate 5.1.20: no host support bit rejected");
    } else |_| {
        check(false, "subrate 5.1.20 host support: verdict error");
    }
}

// ⑨–⑪ 算术
fn arithmetic(comptime check: fn (bool, []const u8) void) void {
    // §7.8.124 Central 规则 + §5.1.19（6203）：base 高 2 位 = 排队事件计数的高 2 位。
    if (subrate.centralIndFromRequest(p_req, 12, 0xC001, 0x0123)) |ind| {
        check(ind.subrate_factor == 4 and ind.subrate_base_event == 0xC123 and ind.continuation_number == 2 and ind.supervision_timeout == 100, "subrate 7.8.124 central ind: S15-14 = E15-14");
    } else |_| {
        check(false, "subrate 7.8.124 central ind: error");
    }
    // §5.1.19（6203）+ §4.5.1（4799）：base 高 2 位 11、计数器高 2 位 00 → 回绕修正。
    const ind: subrate.SubrateIndPdu = .{
        .subrate_factor = 4,
        .subrate_base_event = 0xF000,
        .peripheral_latency = 3,
        .continuation_number = 2,
        .supervision_timeout = 500,
    };
    if (subrate.peripheralApplyInd(ind, 0x1234)) |cur| {
        check(cur.subrate_base_event == 0 and cur.subrate_factor == 4, "subrate 5.1.19 apply: base unwrapped across counter wrap");
    } else |_| {
        check(false, "subrate 5.1.19 apply: error");
    }
    // §4.5.1（4794）乘积：24 × 4 × 5 = 480。
    const units = subrate.effectiveIntervalUnits(24, 4, 4) catch 0;
    check(units == 480, "subrate 4.5.1: effective interval 24*4*5=480");
}

// ⑫–⑭ 模型
fn model(comptime check: fn (bool, []const u8) void) void {
    var s: subrate.Session = .{};
    var ok = true;
    s.openConn(0x0B12, .central, 12) catch {
        ok = false;
    };
    s.request(0x0B12, p_req, 0, true) catch {
        ok = false;
    };
    // §7.7.65.35：与请求一致的 event 通过并把参数落进去。
    s.onEvent(.{ .status = 0, .handle = 0x0B12, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }) catch {
        ok = false;
    };
    ok = ok and s.conn.?.current.subrate_factor == 4 and !s.conn.?.pending;
    check(ok, "subrate model: request -> event -> params updated");

    // §5.2（6238）：T_PRT 40 s。
    s.request(0x0B12, p_req, 0, true) catch {
        ok = false;
    };
    var timeout = false;
    if (s.tick(40 * std.time.us_per_s)) |_| {
        timeout = false;
    } else |e| timeout = e == error.ProcedureTimeout;
    check(timeout and !s.conn.?.pending, "subrate 5.2: procedure timeout at 40s");

    // §7.8.124：handle 对不上 → 0x02 Unknown Connection Identifier 的模型路径。
    var u: subrate.Session = .{};
    u.openConn(0x0B12, .central, 12) catch {};
    const unknown = if (u.request(0x0B13, p_req, 0, true)) |_| false else |e| e == error.UnknownHandle;
    check(unknown, "subrate 7.8.124: unknown connection handle rejected");
}
