//! wifi-connect：FT 快速切换里的 RIC 板侧自检（IEEE Std 802.11-2016）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 覆盖（主机测试 `ft_ric_tests.zig` 的子集，全部是纯字节操作，没有点乘，AES/CMAC 都不用）：
//!   ① RDE 按图 9-322 编码（字节与图一致）
//!   ② RDE 解析往返；③ RDE 拒绝非 RDE 元素与错误长度
//!   ④ Block Ack RIC Descriptor 按图 9-323 编码与往返；⑤ 拒绝保留的 Resource Type
//!   ⑥ parseRic 把两条 Resource Request 按 RDE 划界（图 13-20）
//!   ⑦ 请求 RDE 的 Status Code 非 0 被拒（13.11.3.1）
//!   ⑧ Block Ack 描述符个数与 Resource Descriptor Count 不符被拒（表 13-3）
//!   ⑨ RIC-Response 与请求同序同 Identifier 才通过（13.11.3.2）
//!   ⑩ 表 9-30 注 14 的两个前提（ricAllowedInReassoc）与图 9-314 的 B1 位
//!
//! 每个判据函数单独 `noinline`：ReleaseSmall 会把内联函数的大数组叠进同一个栈帧，板侧主栈
//! 标称只有 16 KiB。指令数估算见各判据：全部是几十次内存比较与循环，总计约 5 千条 rv32
//! 指令（≈60 µs @80 MHz），远低于 2400 万条的预算。

const std = @import("std");

const fp = @import("ft_proto.zig");

/// 两个十六进制字符折一个字节（编译期）。
fn h(comptime text: []const u8) [text.len / 2]u8 {
    comptime var out: [text.len / 2]u8 = undefined;
    @setEvalBranchQuota(20000);
    comptime {
        for (0..out.len) |i| {
            const hi = std.fmt.charToDigit(text[2 * i], 16) catch unreachable;
            const lo = std.fmt.charToDigit(text[2 * i + 1], 16) catch unreachable;
            out[i] = hi * 16 + lo;
        }
    }
    return out;
}

/// 两条 Resource Request（图 13-20，手排）：RDE(id=1,count=1) + 一个描述符、
/// RDE(id=2,count=2) + 两个。与主机测试同一份字节。
const two_requests: [39]u8 = h("3904010100004b0701111101000000" ++
    "3904020200004b07012222100000004b0701333220000000");

const ok_rde: [fp.rde_len]u8 = h("390407020000");
const ok_desc: [fp.ric_descriptor_block_ack_len]u8 = h("4b07013412e8030000");

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

noinline fn check1RdeEncode(check: fn (bool, []const u8) void) void {
    var buf: [fp.rde_len]u8 = undefined;
    const r = fp.Rde{ .rde_id = 7, .descriptor_count = 2, .status = 0 };
    r.encode(&buf);
    check(eq(&buf, &ok_rde), "ric: RDE encode matches Figure 9-322");
}

noinline fn check2RdeRoundtrip(check: fn (bool, []const u8) void) void {
    const r = fp.Rde.parse(&ok_rde) catch return check(false, "ric: RDE parse roundtrip failed");
    check(r.rde_id == 7 and r.descriptor_count == 2 and r.status == 0 and r.accepted(), "ric: RDE parse roundtrip keeps id/count/status");
}

noinline fn check3RdeReject(check: fn (bool, []const u8) void) void {
    const wrong_id = fp.Rde.parse(&h("360307020000"));
    const bad_len = fp.Rde.parse(&h("3903070200"));
    check(wrong_id == error.WrongElement and bad_len == error.BadRde, "ric: RDE rejects a wrong element id and a wrong length");
}

noinline fn check4BlockAckDescriptor(check: fn (bool, []const u8) void) void {
    var buf: [fp.ric_descriptor_block_ack_len]u8 = undefined;
    const ie = fp.encodeBlockAckDescriptor(.{ .parameter_set = 0x1234, .timeout_tu = 1000, .ssc = 0 }, &buf);
    if (!eq(ie, &ok_desc)) return check(false, "ric: Block Ack descriptor encode matches Figure 9-323");
    const back = fp.parseBlockAckDescriptor(ie) catch return check(false, "ric: Block Ack descriptor parse failed");
    check(back.parameter_set == 0x1234 and back.timeout_tu == 1000 and back.ssc == 0, "ric: Block Ack descriptor roundtrip keeps the three parameters");
}

noinline fn check5ReservedType(check: fn (bool, []const u8) void) void {
    check(fp.parseRicDescriptor(&h("4b07003412e8030000")) == error.BadRicDescriptor, "ric: reserved resource type 0 rejected (Table 9-161)");
}

noinline fn check6ParseRic(check: fn (bool, []const u8) void) void {
    const r = fp.parseRic(&two_requests) catch return check(false, "ric: parseRic failed on Figure 13-20 bytes");
    const ok = r.len == 2 and r.entries[0].rde.rde_id == 1 and r.entries[1].rde.rde_id == 2 and
        eq(r.entries[0].rest, &h("4b0701111101000000")) and
        eq(r.entries[1].rest, &h("4b07012222100000004b0701333220000000"));
    check(ok, "ric: parseRic splits requests by RDE (Figure 13-20)");
}

noinline fn check7BadStatus(check: fn (bool, []const u8) void) void {
    check(fp.checkRicRequest(&h("390401012100")) == error.RicBadStatus, "ric: request RDE status must be SUCCESS (13.11.3.1)");
}

noinline fn check8CountMismatch(check: fn (bool, []const u8) void) void {
    check(fp.checkRicRequestBlockAck(&h("3904020200004b0701222210000000")) == error.RicDescriptorCountMismatch, "ric: descriptor count must match RDE count (Table 13-3)");
}

noinline fn check9Response(check: fn (bool, []const u8) void) void {
    const response: [12]u8 = h("390401000000" ++ "390402000000");
    fp.checkRicResponse(&two_requests, &response) catch {
        return check(false, "ric: matching response RDEs must pass (13.11.3.2)");
    };
    check(fp.checkRicResponse(&two_requests, &h("390402000000390401000000")) == error.RicResponseMismatch, "ric: response RDEs match request order and ids (13.11.3.2)");
}

const void_value_or_error_ok: void = {};

noinline fn check10Capability(check: fn (bool, []const u8) void) void {
    const ok = fp.ricAllowedInReassoc(true, false) and
        !fp.ricAllowedInReassoc(true, true) and
        !fp.ricAllowedInReassoc(false, false) and
        fp.capResourceRequest(0x03) and !fp.capResourceRequest(0x01);
    check(ok, "ric: Table 9-30 note 14 gating and the B1 capability bit");
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    check1RdeEncode(check);
    check2RdeRoundtrip(check);
    check3RdeReject(check);
    check4BlockAckDescriptor(check);
    check5ReservedType(check);
    check6ParseRic(check);
    check7BadStatus(check);
    check8CountMismatch(check);
    check9Response(check);
    check10Capability(check);
}
