//! Host tests for the parts of `hci_conformance.zig` that go beyond a single
//! Command Complete frame: Table 3.1 support classification, the
//! HCI_Command_Status reply shape and `verifyDeclared`. The frame-level rules
//! are tested next to the implementation, in `hci_conformance.zig`; this file
//! pulls them in with the test block below and adds the declared-support
//! cases. References are to Bluetooth Core Specification 5.4, Vol 4 Part E.

const std = @import("std");
const testing = std.testing;

const hc = @import("hci_conformance.zig");

test {
    _ = @import("hci_conformance.zig");
}

// ---------------------------------------------------------------------------
// Frame builders (independent of the implementation's own test helpers)
// ---------------------------------------------------------------------------

const max_frame = 80;

const Frame = struct {
    buf: [max_frame]u8 = @splat(0),
    len: usize = 0,

    fn sl(self: *const Frame) []const u8 {
        return self.buf[0..self.len];
    }
};

/// HCI_Command_Complete (§7.7.14): Event_Code 0x0E, Parameter_Total_Length,
/// Num_HCI_Command_Packets, Command_Opcode (2 octets, little-endian),
/// Return_Parameters.
fn cc(opcode: u16, ret: []const u8) Frame {
    var f: Frame = .{};
    f.buf[0] = 0x0E;
    f.buf[1] = @intCast(3 + ret.len);
    f.buf[2] = 1;
    f.buf[3] = @truncate(opcode);
    f.buf[4] = @truncate(opcode >> 8);
    @memcpy(f.buf[5 .. 5 + ret.len], ret);
    f.len = 5 + ret.len;
    return f;
}

/// HCI_Command_Status (§7.7.15): Event_Code 0x0F, Parameter_Total_Length 4,
/// Status, Num_HCI_Command_Packets, Command_Opcode (2 octets, little-endian).
fn cs(opcode: u16, status: u8, ncmd: u8) Frame {
    var f: Frame = .{};
    f.buf[0] = 0x0F;
    f.buf[1] = 4;
    f.buf[2] = status;
    f.buf[3] = ncmd;
    f.buf[4] = @truncate(opcode);
    f.buf[5] = @truncate(opcode >> 8);
    f.len = 6;
    return f;
}

fn cmd(name: []const u8) hc.Command {
    for (hc.commands) |c| if (std.mem.eql(u8, c.name, name)) return c;
    unreachable;
}

/// A Supported_Commands mask with only the listed bit indices (octet * 8 +
/// bit, §6.27) set.
fn maskOf(bits: []const u16) [64]u8 {
    var m: [64]u8 = @splat(0);
    for (bits) |i| m[i / 8] |= @as(u8, 1) << @as(u3, @intCast(i % 8));
    return m;
}

/// A successful reply of `name` whose return parameters follow the rules.
/// Built field by field from the §7.x parameter tables.
fn good(name: []const u8) Frame {
    const c = cmd(name);
    if (std.mem.eql(u8, name, "read_supported_cmds")) {
        var ret: [65]u8 = @splat(0);
        for (hc.commands) |x| {
            if (x.supp_bit != hc.no_supp_bit) ret[1 + x.supp_bit / 8] |= @as(u8, 1) << @as(u3, @intCast(x.supp_bit % 8));
        }
        return cc(c.opcode, &ret);
    }
    const ret: []const u8 = if (std.mem.eql(u8, name, "read_local_version"))
        &.{ 0x00, 0x0D, 0x34, 0x12, 0x0D, 0xE5, 0x02, 0x78, 0x56 } // §7.4.1
    else if (std.mem.eql(u8, name, "read_bd_addr"))
        &.{ 0x00, 0x24, 0x6F, 0x28, 0x11, 0x22, 0x33 } // §7.4.6
    else if (std.mem.eql(u8, name, "read_local_features"))
        &.{ 0x00, 0x2C, 0x02, 0x40, 0x02, 0x00, 0x00, 0x18, 0x00 } // §7.4.3, LMP_Features bits 2, 3, 5, 25, 38, 41, 51, 52
    else if (std.mem.eql(u8, name, "read_buffer_size"))
        &.{ 0x00, 0xFD, 0x03, 0x3C, 0x0C, 0x00, 0x00, 0x00 } // §7.4.5
    else if (std.mem.eql(u8, name, "read_ext_features_p0"))
        &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x80 } // §7.4.4, page 0 of an LE-only device: LMP bits 37, 38, 63
    else if (std.mem.eql(u8, name, "read_data_block_size"))
        &.{ 0x00, 0xFD, 0x03, 0xD2, 0x04, 0x0A, 0x00 } // §7.4.7
    else if (std.mem.eql(u8, name, "read_codecs_v1"))
        &.{ 0x00, 0x01, 0x02, 0x00 } // §7.4.8 [v1]: one standard codec, no vendor codec
    else if (std.mem.eql(u8, name, "read_codecs_v2"))
        &.{ 0x00, 0x00, 0x00 } // §7.4.8 [v2]: no codecs
    else if (std.mem.eql(u8, name, "read_sp_options"))
        &.{ 0x00, 0x01, 0x10 } // §7.4.9
    else if (std.mem.eql(u8, name, "read_loopback_mode"))
        &.{ 0x00, 0x00 } // §7.6.1
    else if (std.mem.eql(u8, name, "le_read_buffer_size"))
        &.{ 0x00, 0xFB, 0x00, 0x0A } // §7.8.2 [v1]
    else if (std.mem.eql(u8, name, "le_read_buffer_size_v2"))
        &.{ 0x00, 0xFB, 0x00, 0x0A, 0xF8, 0x03, 0x08 } // §7.8.2 [v2]
    else if (std.mem.eql(u8, name, "le_read_features"))
        &.{ 0x00, 0x1F, 0x71, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00 } // §7.8.3, LE_Features bits 0-4, 8, 12, 13, 14, 33, 34
    else if (std.mem.eql(u8, name, "le_read_adv_tx_power"))
        &.{ 0x00, 0xF4 } // §7.8.6, -12 dBm
    else if (std.mem.eql(u8, name, "le_read_fal_size"))
        &.{ 0x00, 0x10 } // §7.8.14
    else if (std.mem.eql(u8, name, "le_read_states"))
        &.{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0x00, 0x00 } // §7.8.27
    else if (std.mem.eql(u8, name, "le_read_default_dl"))
        &.{ 0x00, 0x1B, 0x00, 0x48, 0x01 } // §7.8.34
    else if (std.mem.eql(u8, name, "le_read_rsl_size"))
        &.{ 0x00, 0x05 } // §7.8.41
    else if (std.mem.eql(u8, name, "le_read_max_dl"))
        &.{ 0x00, 0xFB, 0x00, 0x90, 0x42, 0xFB, 0x00, 0x90, 0x42 } // §7.8.46
    else if (std.mem.eql(u8, name, "le_read_max_adv_len"))
        &.{ 0x00, 0x72, 0x06 } // §7.8.57
    else if (std.mem.eql(u8, name, "le_read_adv_sets"))
        &.{ 0x00, 0x0A } // §7.8.58
    else if (std.mem.eql(u8, name, "le_read_pal_size"))
        &.{ 0x00, 0x08 } // §7.8.73
    else if (std.mem.eql(u8, name, "le_read_tx_power"))
        &.{ 0x00, 0xEC, 0x0A } // §7.8.74
    else if (std.mem.eql(u8, name, "le_read_rf_comp"))
        &.{ 0x00, 0xFE, 0xFF, 0x0A, 0x00 } // §7.8.75, RF_TX 0xFFFE (-0.2 dB), RF_RX 0x000A (1.0 dB)
    else if (std.mem.eql(u8, name, "le_read_antenna"))
        &.{ 0x00, 0x03, 0x02, 0x02, 0x10 } // §7.8.87
    else
        unreachable;
    return cc(c.opcode, ret);
}

fn expectFail(cmd_: hc.Command, evt: []const u8, mask: ?*const [64]u8, rule: hc.Rule, detail: u32) !void {
    const d = hc.verifyDeclared(cmd_, evt, mask);
    switch (d) {
        .fail => |f| {
            try testing.expectEqual(rule, f.rule);
            try testing.expectEqual(detail, f.detail);
        },
        else => return testing.expect(false),
    }
}

// ---------------------------------------------------------------------------
// commands table invariants
// ---------------------------------------------------------------------------

test "table: commands sorted by opcode, 26 entries, support equals Table 3.1 LE column" {
    // Vol 4 Part E §3 "Table 3.1: Alphabetical list of commands and events",
    // LE Controller column, copied here independently of `hc.commands`.
    // `[v1]`/`[v2]` commands take the entry of the version `commands` uses.
    const Row = struct { name: []const u8, opcode: u16, support: hc.Support };
    const table = [_]Row{
        .{ .name = "read_local_version", .opcode = 0x1001, .support = .mandatory },
        .{ .name = "read_supported_cmds", .opcode = 0x1002, .support = .mandatory },
        .{ .name = "read_local_features", .opcode = 0x1003, .support = .mandatory },
        .{ .name = "read_ext_features_p0", .opcode = 0x1004, .support = .excluded },
        .{ .name = "read_buffer_size", .opcode = 0x1005, .support = .excluded },
        .{ .name = "read_bd_addr", .opcode = 0x1009, .support = .mandatory },
        .{ .name = "read_data_block_size", .opcode = 0x100A, .support = .excluded },
        .{ .name = "read_codecs_v1", .opcode = 0x100B, .support = .excluded },
        .{ .name = "read_sp_options", .opcode = 0x100C, .support = .excluded },
        .{ .name = "read_codecs_v2", .opcode = 0x100D, .support = .optional },
        .{ .name = "read_loopback_mode", .opcode = 0x1801, .support = .excluded },
        .{ .name = "le_read_buffer_size", .opcode = 0x2002, .support = .conditional },
        .{ .name = "le_read_features", .opcode = 0x2003, .support = .mandatory },
        .{ .name = "le_read_adv_tx_power", .opcode = 0x2007, .support = .conditional },
        .{ .name = "le_read_fal_size", .opcode = 0x200F, .support = .mandatory },
        .{ .name = "le_read_states", .opcode = 0x201C, .support = .mandatory },
        .{ .name = "le_read_default_dl", .opcode = 0x2023, .support = .conditional },
        .{ .name = "le_read_rsl_size", .opcode = 0x202A, .support = .conditional },
        .{ .name = "le_read_max_dl", .opcode = 0x202F, .support = .conditional },
        .{ .name = "le_read_max_adv_len", .opcode = 0x203A, .support = .conditional },
        .{ .name = "le_read_adv_sets", .opcode = 0x203B, .support = .conditional },
        .{ .name = "le_read_pal_size", .opcode = 0x204A, .support = .conditional },
        .{ .name = "le_read_tx_power", .opcode = 0x204B, .support = .conditional },
        .{ .name = "le_read_rf_comp", .opcode = 0x204C, .support = .conditional },
        .{ .name = "le_read_antenna", .opcode = 0x2058, .support = .conditional },
        .{ .name = "le_read_buffer_size_v2", .opcode = 0x2060, .support = .conditional },
    };
    try testing.expectEqual(@as(usize, 26), hc.commands.len);
    try testing.expectEqual(table.len, hc.commands.len);
    for (hc.commands, table) |c, r| {
        try testing.expectEqualStrings(r.name, c.name);
        try testing.expectEqual(r.opcode, c.opcode);
        try testing.expectEqual(r.support, c.support);
    }
    for (hc.commands, 0..) |c, i| {
        if (i == 0) continue;
        try testing.expect(hc.commands[i - 1].opcode < c.opcode);
    }
}

// §6.27 table, octet and bit as printed there ("Octet / Bit / Command
// Supported"), index = octet * 8 + bit:
//   HCI_Read_Local_Version_Information   octet 14 bit 3
//   HCI_Read_Local_Supported_Features    octet 14 bit 5
//   HCI_Read_Buffer_Size                 octet 14 bit 7
//   HCI_Read_BD_ADDR                     octet 15 bit 1
//   HCI_Read_Loopback_Mode               octet 16 bit 0
//   HCI_Read_Data_Block_Size             octet 23 bit 2
//   HCI_LE_Read_Buffer_Size [v1]         octet 25 bit 1
//   HCI_LE_Read_Local_Supported_Features octet 25 bit 2
//   HCI_LE_Read_RF_Path_Compensation     octet 39 bit 0
//   HCI_LE_Read_Buffer_Size [v2]         octet 41 bit 5
//   HCI_Read_Local_Supported_Codecs [v2] octet 45 bit 2
// HCI_Read_Local_Supported_Commands has no entry: octet 14 lists bits 3
// (version), 4 "Reserved for future use" and 5 (features).
test "table: supp_bit equals the section 6.27 octet and bit" {
    const Entry = struct { name: []const u8, octet: u16, bit: u3 };
    const entries = [_]Entry{
        .{ .name = "read_local_version", .octet = 14, .bit = 3 },
        .{ .name = "read_local_features", .octet = 14, .bit = 5 },
        .{ .name = "read_buffer_size", .octet = 14, .bit = 7 },
        .{ .name = "read_bd_addr", .octet = 15, .bit = 1 },
        .{ .name = "read_loopback_mode", .octet = 16, .bit = 0 },
        .{ .name = "read_data_block_size", .octet = 23, .bit = 2 },
        .{ .name = "le_read_buffer_size", .octet = 25, .bit = 1 },
        .{ .name = "le_read_features", .octet = 25, .bit = 2 },
        .{ .name = "le_read_rf_comp", .octet = 39, .bit = 0 },
        .{ .name = "le_read_buffer_size_v2", .octet = 41, .bit = 5 },
        .{ .name = "read_codecs_v2", .octet = 45, .bit = 2 },
    };
    for (entries) |e| {
        try testing.expectEqual(@as(u16, e.octet) * 8 + e.bit, cmd(e.name).supp_bit);
    }
    try testing.expectEqual(hc.no_supp_bit, cmd("read_supported_cmds").supp_bit);
    // Every other entry has a bit that lies inside the 64-octet field.
    for (hc.commands) |c| try testing.expect(c.supp_bit == hc.no_supp_bit or c.supp_bit < 512);
}

test "opc: (ogf << 10) | ocf, Vol 4 Part E 5.4.6" {
    try testing.expectEqual(@as(u16, 0x1001), hc.opc(0x04, 0x001));
    try testing.expectEqual(@as(u16, 0x2060), hc.opc(0x08, 0x060));
    try testing.expectEqual(@as(u16, 0x0000), hc.opc(0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), hc.opc(0x3F, 0x3FF));
}

test "reportsSupport: octet i bit b is index i * 8 + b, bit 0 is the least significant" {
    // §6.27 prints each octet with bit 0 first; HCI_LE_Read_Local_Supported_Features
    // is octet 25 bit 2.
    const le_features = cmd("le_read_features");
    var m: [64]u8 = @splat(0);
    try testing.expect(!hc.reportsSupport(&m, le_features));
    m[25] = 1 << 2;
    try testing.expect(hc.reportsSupport(&m, le_features));
    m[25] = 1 << 5; // bit 5 of the same octet: LE_Set_Advertising_Parameters
    try testing.expect(!hc.reportsSupport(&m, le_features));
    m = maskOf(&.{202});
    try testing.expect(hc.reportsSupport(&m, le_features));
    try testing.expect(!hc.reportsSupport(&m, cmd("le_read_fal_size")));
    // Resolved from the opcode alone.
    try testing.expect(hc.reportsSupport(&m, .{ .name = "x", .opcode = 0x2003 }));
    // Commands without a table entry and unknown opcodes.
    try testing.expect(hc.reportsSupport(&m, cmd("read_supported_cmds")));
    try testing.expect(!hc.reportsSupport(&m, .{ .name = "x", .opcode = 0xFFFF }));
}

// ---------------------------------------------------------------------------
// verifyDeclared
// ---------------------------------------------------------------------------

const M = "le_read_features"; // Table 3.1: M, §6.27 bit 202
const O = "read_codecs_v2"; // Table 3.1: O, §6.27 bit 362
const C = "le_read_buffer_size"; // Table 3.1: C.3, §6.27 bit 201
const E = "read_buffer_size"; // Table 3.1: E, §6.27 bit 119

fn withStatus(name: []const u8, status: u8) Frame {
    var f = good(name);
    f.buf[5] = status;
    return f;
}

/// Mask with only `name`'s own Supported_Commands bit set (all clear when
/// the command has no bit). For an excluded command this is the
/// non-conforming case "the Controller claims it anyway".
fn declared(name: []const u8) ?[64]u8 {
    const c = cmd(name);
    if (c.supp_bit == hc.no_supp_bit) return maskOf(&.{});
    return maskOf(&.{c.supp_bit});
}

test "positive: each command's reply decodes with the return-parameter size of its section (7.4.1 to 7.8.87)" {
    // Name, the section whose Return Parameters table the frame follows, and
    // the size of those return parameters (Status included). The two codec
    // commands are variable length; the sizes are those of the built frames.
    const Row = struct { name: []const u8, section: []const u8, ret_len: u8 };
    const rows = [_]Row{
        .{ .name = "read_local_version", .section = "7.4.1", .ret_len = 1 + 1 + 2 + 1 + 2 + 2 },
        .{ .name = "read_supported_cmds", .section = "7.4.2", .ret_len = 1 + 64 },
        .{ .name = "read_local_features", .section = "7.4.3", .ret_len = 1 + 8 },
        .{ .name = "read_ext_features_p0", .section = "7.4.4", .ret_len = 1 + 1 + 1 + 8 },
        .{ .name = "read_buffer_size", .section = "7.4.5", .ret_len = 1 + 2 + 1 + 2 + 2 },
        .{ .name = "read_bd_addr", .section = "7.4.6", .ret_len = 1 + 6 },
        .{ .name = "read_data_block_size", .section = "7.4.7", .ret_len = 1 + 2 + 2 + 2 },
        .{ .name = "read_codecs_v1", .section = "7.4.8 [v1]", .ret_len = 4 },
        .{ .name = "read_sp_options", .section = "7.4.9", .ret_len = 1 + 1 + 1 },
        .{ .name = "read_codecs_v2", .section = "7.4.8 [v2]", .ret_len = 3 },
        .{ .name = "read_loopback_mode", .section = "7.6.1", .ret_len = 1 + 1 },
        .{ .name = "le_read_buffer_size", .section = "7.8.2 [v1]", .ret_len = 1 + 2 + 1 },
        .{ .name = "le_read_features", .section = "7.8.3", .ret_len = 1 + 8 },
        .{ .name = "le_read_adv_tx_power", .section = "7.8.6", .ret_len = 1 + 1 },
        .{ .name = "le_read_fal_size", .section = "7.8.14", .ret_len = 1 + 1 },
        .{ .name = "le_read_states", .section = "7.8.27", .ret_len = 1 + 8 },
        .{ .name = "le_read_default_dl", .section = "7.8.34", .ret_len = 1 + 2 + 2 },
        .{ .name = "le_read_rsl_size", .section = "7.8.41", .ret_len = 1 + 1 },
        .{ .name = "le_read_max_dl", .section = "7.8.46", .ret_len = 1 + 2 + 2 + 2 + 2 },
        .{ .name = "le_read_max_adv_len", .section = "7.8.57", .ret_len = 1 + 2 },
        .{ .name = "le_read_adv_sets", .section = "7.8.58", .ret_len = 1 + 1 },
        .{ .name = "le_read_pal_size", .section = "7.8.73", .ret_len = 1 + 1 },
        .{ .name = "le_read_tx_power", .section = "7.8.74", .ret_len = 1 + 1 + 1 },
        .{ .name = "le_read_rf_comp", .section = "7.8.75", .ret_len = 1 + 2 + 2 },
        .{ .name = "le_read_antenna", .section = "7.8.87", .ret_len = 1 + 1 + 1 + 1 + 1 },
        .{ .name = "le_read_buffer_size_v2", .section = "7.8.2 [v2]", .ret_len = 1 + 2 + 1 + 2 + 1 },
    };
    try testing.expectEqual(hc.commands.len, rows.len);
    for (rows) |row| {
        const c = cmd(row.name);
        const f = good(row.name);
        // §7.7.14: Parameter_Total_Length = 1 (ncmd) + 2 (opcode) + return
        // parameters; the frame adds the 2-octet event header (§5.4.4).
        try testing.expectEqual(@as(usize, 5) + row.ret_len, f.len);
        try testing.expectEqual(row.ret_len, f.buf[1] - 3);
        try testing.expectEqual(@as(u8, 0x00), f.buf[5]); // Status
        var r: hc.Readout = .{};
        try testing.expect(hc.decode(c, f.sl(), &r));
        try testing.expectEqual(@as(u8, 1), r.ncmd);
        try testing.expect(hc.verify(c, f.sl()) == .ok);
    }
}

test "verifyDeclared: success is ok for every command whose bit is declared" {
    for (hc.commands) |c| {
        if (c.support == .excluded) continue;
        const f = good(c.name);
        var m: [64]u8 = @splat(0);
        if (c.supp_bit != hc.no_supp_bit) m[c.supp_bit / 8] |= @as(u8, 1) << @as(u3, @intCast(c.supp_bit % 8));
        const d = hc.verifyDeclared(c, f.sl(), &m);
        try testing.expect(d == .ok);
        // Without a mask the bit check is skipped.
        try testing.expect(hc.verifyDeclared(c, f.sl(), null) == .ok);
        // decode() reads the same frame back.
        var r: hc.Readout = .{};
        try testing.expect(hc.decode(c, f.sl(), &r));
        try testing.expectEqual(@as(u8, 1), r.ncmd);
    }
}

test "verifyDeclared: excluded command answering with success fails (Table 3.1 E)" {
    for (hc.commands) |c| {
        if (c.support != .excluded) continue;
        const f = good(c.name);
        // Negative: with and without a mask.
        try expectFail(c, f.sl(), null, .excluded_but_supported, 0);
        try expectFail(c, f.sl(), &declared(c.name).?, .excluded_but_supported, 0);
    }
    // Positive: a mandatory command's success is not excluded_but_supported.
    try testing.expect(hc.verifyDeclared(cmd(M), good(M).sl(), &declared(M).?) == .ok);
}

test "verifyDeclared: mandatory command answering Unknown HCI Command fails (Table 3.1 M, 4.5)" {
    for (hc.commands) |c| {
        if (c.support != .mandatory) continue;
        const var_mask: ?[64]u8 = if (declared(c.name)) |m| m else null;
        // Negative, both shapes §4.5 allows.
        try expectFail(c, withStatus(c.name, 0x01).sl(), null, .mandatory_unsupported, 0x01);
        try expectFail(c, withStatus(c.name, 0x01).sl(), if (var_mask) |*m| m else null, .mandatory_unsupported, 0x01);
        const s = cs(c.opcode, 0x01, 1);
        try expectFail(c, s.sl(), null, .mandatory_unsupported, 0x01);
        try expectFail(c, s.sl(), if (var_mask) |*m| m else null, .mandatory_unsupported, 0x01);
    }
    // Positive: the same Status from O, C and E commands is not a violation.
    for ([_][]const u8{ O, C, E }) |n| {
        try testing.expect(hc.verifyDeclared(cmd(n), withStatus(n, 0x01).sl(), null) == .not_supported);
    }
}

test "verifyDeclared: not_supported carries Num_HCI_Command_Packets" {
    for ([_][]const u8{ O, C, E }) |n| {
        const c = cmd(n);
        var f = withStatus(n, 0x01);
        f.buf[2] = 3;
        try testing.expectEqual(@as(u8, 3), hc.verifyDeclared(c, f.sl(), null).not_supported.ncmd);
        try testing.expectEqual(@as(u8, 0), hc.verifyDeclared(c, cs(c.opcode, 0x01, 0).sl(), null).not_supported.ncmd);
    }
}

test "verifyDeclared: Status 0x01 with the Supported_Commands bit set fails (bit set, command unknown)" {
    // The Controller declared support (§6.27) and then answered 0x01 (§4.5).
    const mset = maskOf(&.{ cmd(O).supp_bit, cmd(C).supp_bit, cmd(E).supp_bit });
    // Negative: Command Complete.
    try expectFail(cmd(O), withStatus(O, 0x01).sl(), &mset, .support_bit_mismatch, 1);
    try expectFail(cmd(C), withStatus(C, 0x01).sl(), &mset, .support_bit_mismatch, 1);
    // Negative: Command Status.
    try expectFail(cmd(O), cs(cmd(O).opcode, 0x01, 1).sl(), &mset, .support_bit_mismatch, 1);
    try expectFail(cmd(C), cs(cmd(C).opcode, 0x01, 1).sl(), &mset, .support_bit_mismatch, 1);
    // Positive: bit clear or mask unknown.
    const mclr: [64]u8 = @splat(0);
    for ([_][]const u8{ O, C }) |n| {
        try testing.expect(hc.verifyDeclared(cmd(n), withStatus(n, 0x01).sl(), &mclr) == .not_supported);
        try testing.expect(hc.verifyDeclared(cmd(n), withStatus(n, 0x01).sl(), null) == .not_supported);
    }
}

test "verifyDeclared: an excluded command's Supported_Commands bit shall be clear" {
    for (hc.commands) |c| {
        if (c.support != .excluded) continue;
        const m = maskOf(&.{c.supp_bit});
        // Negative: bit set, answered 0x01 (detail 2).
        try expectFail(c, withStatus(c.name, 0x01).sl(), &m, .support_bit_mismatch, 2);
        try expectFail(c, cs(c.opcode, 0x01, 1).sl(), &m, .support_bit_mismatch, 2);
        // Bit set and success: the success itself is reported first.
        try expectFail(c, good(c.name).sl(), &m, .excluded_but_supported, 0);
        // Positive: bit clear or mask unknown -> not supported.
        const zero: [64]u8 = @splat(0);
        try testing.expect(hc.verifyDeclared(c, withStatus(c.name, 0x01).sl(), &zero) == .not_supported);
        try testing.expect(hc.verifyDeclared(c, withStatus(c.name, 0x01).sl(), null) == .not_supported);
    }
}

test "verifyDeclared: success with the Supported_Commands bit clear fails (bit clear, command succeeded)" {
    const zero: [64]u8 = @splat(0);
    for (hc.commands) |c| {
        if (c.support == .excluded or c.supp_bit == hc.no_supp_bit) continue;
        try expectFail(c, good(c.name).sl(), &zero, .support_bit_mismatch, 0);
        // Positive: bit set -> ok; mask unknown -> ok.
        const m = maskOf(&.{c.supp_bit});
        try testing.expect(hc.verifyDeclared(c, good(c.name).sl(), &m) == .ok);
        try testing.expect(hc.verifyDeclared(c, good(c.name).sl(), null) == .ok);
    }
    // A command without a table bit cannot disagree with the mask.
    try testing.expect(hc.verifyDeclared(cmd("read_supported_cmds"), good("read_supported_cmds").sl(), &zero) == .ok);
}

test "verifyDeclared: any other non-zero Status fails with status_nonzero" {
    // Negative: Command Complete and Command Status, every support class.
    for ([_][]const u8{ M, O, C, E }) |n| {
        const c = cmd(n);
        const m = declared(n);
        for ([_]u8{ 0x02, 0x0C, 0x12, 0xFF }) |st| {
            try expectFail(c, withStatus(n, st).sl(), if (m) |*x| x else null, .status_nonzero, st);
            try expectFail(c, cs(c.opcode, st, 1).sl(), if (m) |*x| x else null, .status_nonzero, st);
        }
        // Positive: 0x01 from a non-mandatory command is not status_nonzero.
        if (c.support != .mandatory) {
            try testing.expect(hc.verifyDeclared(c, withStatus(n, 0x01).sl(), null) == .not_supported);
        }
        // Positive: Status 0 is not status_nonzero.
        const ok_or_excluded = hc.verifyDeclared(c, withStatus(n, 0x00).sl(), if (m) |*x| x else null);
        if (c.support != .excluded) {
            try testing.expect(ok_or_excluded == .ok);
        } else {
            try testing.expectEqual(hc.Rule.excluded_but_supported, ok_or_excluded.fail.rule);
        }
    }
}

test "verifyDeclared: Command Status with Status 0x00 fails with status_event" {
    for ([_][]const u8{ M, O, C, E }) |n| {
        const c = cmd(n);
        const m = declared(n);
        // Negative: §4.4 / §7.7.14: these commands owe a Command Complete event.
        try expectFail(c, cs(c.opcode, 0x00, 1).sl(), if (m) |*x| x else null, .status_event, 0);
        try expectFail(c, cs(c.opcode, 0x00, 1).sl(), null, .status_event, 0);
        // Positive: the same shape with 0x01 is a support answer, not a status_event.
        if (c.support != .mandatory) {
            try testing.expect(hc.verifyDeclared(c, cs(c.opcode, 0x01, 1).sl(), null) == .not_supported);
        }
    }
    // Positive: a Command Complete with Status 0 is ok, never status_event.
    try testing.expect(hc.verifyDeclared(cmd(M), good(M).sl(), &declared(M).?) == .ok);
}

test "verifyDeclared: field rules are applied before the support checks" {
    // LE_Features bit 63 is reserved (Vol 6 Part B Table 4.7): reported even
    // though the command is mandatory and its bit is declared.
    var f = good(M);
    f.buf[5 + 8] |= 0x80;
    try expectFail(cmd(M), f.sl(), &declared(M).?, .reserved_bit_set, 63);
    // Length rule: one octet short.
    f = good(M);
    f.buf[1] -= 1;
    f.len -= 1;
    try expectFail(cmd(M), f.sl(), &declared(M).?, .bad_param_len, (8 << 16) | 9);
    // Support rules: an excluded command whose return parameters also break
    // a field rule reports the field rule.
    var e = good("read_loopback_mode");
    e.buf[6] = 0x03; // §7.6.1: above 0x02, reserved
    try expectFail(cmd("read_loopback_mode"), e.sl(), null, .value_out_of_range, 3);
    // Positive: the untouched frames pass.
    try testing.expect(hc.verifyDeclared(cmd(M), good(M).sl(), &declared(M).?) == .ok);
}

test "verifyDeclared: mask null versus known, all support classes and outcomes" {
    // Every support class x {mask unknown, all bits clear, own bit set,
    // conforming declaration} x {success, 0x01 by Command Complete, 0x01 by
    // Command Status, other error by Command Complete and by Command Status,
    // Command Status with Status 0}.
    const Tag = std.meta.Tag(hc.Declared);
    for ([_][]const u8{ M, O, C, E }) |n| {
        const c = cmd(n);
        const own = declared(n);
        const zero: [64]u8 = @splat(0);
        const set = maskOf(if (c.supp_bit == hc.no_supp_bit) &.{} else &.{c.supp_bit});
        for ([_]?*const [64]u8{ null, &zero, &set, if (own) |*x| x else null }) |m| {
            // Whether the mask in hand declares the command supported.
            const on = m != null and c.supp_bit != hc.no_supp_bit and
                ((m.?[c.supp_bit / 8] >> @as(u3, @intCast(c.supp_bit % 8))) & 1 != 0);
            const success = hc.verifyDeclared(c, good(n).sl(), m);
            const ucc = hc.verifyDeclared(c, withStatus(n, 0x01).sl(), m);
            const ucs = hc.verifyDeclared(c, cs(c.opcode, 0x01, 1).sl(), m);
            const err = hc.verifyDeclared(c, withStatus(n, 0x12).sl(), m);
            const err_cs = hc.verifyDeclared(c, cs(c.opcode, 0x12, 1).sl(), m);
            const st0 = hc.verifyDeclared(c, cs(c.opcode, 0x00, 1).sl(), m);
            // The same for every class and mask.
            try testing.expectEqual(Tag.fail, std.meta.activeTag(err));
            try testing.expectEqual(hc.Rule.status_nonzero, err.fail.rule);
            try testing.expectEqual(@as(u32, 0x12), err.fail.detail);
            try testing.expectEqual(Tag.fail, std.meta.activeTag(err_cs));
            try testing.expectEqual(hc.Rule.status_nonzero, err_cs.fail.rule);
            try testing.expectEqual(Tag.fail, std.meta.activeTag(st0));
            try testing.expectEqual(hc.Rule.status_event, st0.fail.rule);
            // Success from a supported class: ok, unless a known mask has the
            // command's own bit clear. Success from an excluded class always fails.
            const bit_known_clear = m != null and c.supp_bit != hc.no_supp_bit and !on;
            if (c.support == .excluded) {
                try testing.expectEqual(Tag.fail, std.meta.activeTag(success));
                try testing.expectEqual(hc.Rule.excluded_but_supported, success.fail.rule);
            } else if (bit_known_clear) {
                try testing.expectEqual(Tag.fail, std.meta.activeTag(success));
                try testing.expectEqual(hc.Rule.support_bit_mismatch, success.fail.rule);
                try testing.expectEqual(@as(u32, 0), success.fail.detail);
            } else {
                try testing.expectEqual(Tag.ok, std.meta.activeTag(success));
            }
            // Status 0x01, by Command Complete and by Command Status alike.
            for ([_]hc.Declared{ ucc, ucs }) |u| {
                switch (c.support) {
                    .mandatory => {
                        try testing.expectEqual(Tag.fail, std.meta.activeTag(u));
                        try testing.expectEqual(hc.Rule.mandatory_unsupported, u.fail.rule);
                        try testing.expectEqual(@as(u32, 0x01), u.fail.detail);
                    },
                    .excluded => {
                        if (on) {
                            try testing.expectEqual(Tag.fail, std.meta.activeTag(u));
                            try testing.expectEqual(hc.Rule.support_bit_mismatch, u.fail.rule);
                            try testing.expectEqual(@as(u32, 2), u.fail.detail);
                        } else {
                            try testing.expectEqual(Tag.not_supported, std.meta.activeTag(u));
                        }
                    },
                    .optional, .conditional => {
                        if (on) {
                            try testing.expectEqual(Tag.fail, std.meta.activeTag(u));
                            try testing.expectEqual(hc.Rule.support_bit_mismatch, u.fail.rule);
                            try testing.expectEqual(@as(u32, 1), u.fail.detail);
                        } else {
                            try testing.expectEqual(Tag.not_supported, std.meta.activeTag(u));
                        }
                    },
                }
            }
        }
    }
}

test "verifyDeclared: frames that are not this command's reply are other_event" {
    const c = cmd(M);
    const m = declared(M).?;
    // Another command's Command Complete / Command Status.
    try testing.expect(hc.verifyDeclared(c, good(C).sl(), &m) == .other_event);
    try testing.expect(hc.verifyDeclared(c, cs(cmd(C).opcode, 0x01, 1).sl(), &m) == .other_event);
    // Command Status is attributed by opcode, also for excluded commands.
    try testing.expect(hc.verifyDeclared(c, cs(cmd(E).opcode, 0x01, 1).sl(), null) == .other_event);
    try testing.expect(hc.verifyDeclared(c, cs(0x0000, 0x01, 1).sl(), null) == .other_event);
    // Command Status shape (§7.7.15): plen 4 and a frame of 6 octets.
    var f = cs(c.opcode, 0x01, 1);
    f.buf[1] = 3;
    try testing.expect(hc.verifyDeclared(c, f.sl(), null) == .other_event);
    f = cs(c.opcode, 0x01, 1);
    f.buf[1] = 5;
    f.len = 7;
    try testing.expect(hc.verifyDeclared(c, f.sl(), null) == .other_event);
    f = cs(c.opcode, 0x01, 1);
    f.len = 5;
    try testing.expect(hc.verifyDeclared(c, f.sl(), null) == .other_event);
    // Command Complete with plen disagreeing with the frame length.
    f = good(M);
    f.buf[1] -= 1;
    try testing.expect(hc.verifyDeclared(c, f.sl(), &m) == .other_event);
    // A foreign event: Hardware Error (§7.7.16).
    try testing.expect(hc.verifyDeclared(c, &.{ 0x10, 0x01, 0x01 }, null) == .other_event);
    // Shorter than the 5 octets that carry an opcode.
    try testing.expect(hc.verifyDeclared(c, &.{}, null) == .other_event);
    const whole = good(M);
    for (0..5) |k| try testing.expect(hc.verifyDeclared(c, whole.sl()[0..k], null) == .other_event);
    // A command that is not in the table.
    try testing.expect(hc.verifyDeclared(.{ .name = "x", .opcode = 0xFFFF }, whole.sl(), null) == .other_event);
}

test "verifyDeclared: a known mask never turns a conforming reply into a failure" {
    // A full mask with every listed command's bit set, except excluded ones,
    // plus HCI_Reset (octet 2 bit 2).
    var bits: [32]u16 = undefined;
    var n: usize = 0;
    for (hc.commands) |c| {
        if (c.support != .excluded and c.supp_bit != hc.no_supp_bit) {
            bits[n] = c.supp_bit;
            n += 1;
        }
    }
    var m = maskOf(bits[0..n]);
    m[2] |= 1 << 2;
    for (hc.commands) |c| {
        if (c.support == .excluded) continue;
        try testing.expect(hc.verifyDeclared(c, good(c.name).sl(), &m) == .ok);
    }
}

test "describe: 16, 32 and 96 octet buffers, truncation marked and nothing written past the end" {
    // Successful replies decoded by the module under test.
    const ver = cmd("read_local_version");
    var b96: [96]u8 = @splat(0xAA);
    var r: hc.Readout = .{};
    try testing.expect(hc.decode(ver, good("read_local_version").sl(), &r));
    const full = "read_local_version ncmd=1 hci=5.4 lmp=5.4 co=Espressif hsub=0x1234 lsub=0x5678";
    // 96: fits, no marker.
    const l96 = hc.describe(ver, r, &b96);
    try testing.expectEqualStrings(full, l96);
    // 32 and 16: truncated, last octet '~', prefix preserved.
    inline for (.{ 32, 16 }) |n| {
        var small: [n + 8]u8 = @splat(0xAA);
        const line = hc.describe(ver, r, small[0..n]);
        try testing.expectEqual(@as(usize, n), line.len);
        try testing.expectEqual(@as(u8, '~'), line[n - 1]);
        try testing.expect(std.mem.startsWith(u8, full, line[0 .. n - 1]));
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xAA)), small[n..]);
    }
    try testing.expectEqual(@as(usize, 0), hc.describe(ver, r, b96[0..0]).len);
}

test "describe: a 35-octet line fits 96 and 64 octets whole and is marked truncated at 32" {
    var r: hc.Readout = .{};
    try testing.expect(hc.decode(cmd("le_read_states"), good("le_read_states").sl(), &r));
    const full = "le_read_states ncmd=1 bits=42 rfu=0";
    inline for (.{ 96, 64 }) |n| {
        var b: [n]u8 = @splat(0xAA);
        try testing.expectEqualStrings(full, hc.describe(cmd("le_read_states"), r, &b));
    }
    var b32: [32]u8 = @splat(0xAA);
    const cut = hc.describe(cmd("le_read_states"), r, &b32);
    try testing.expectEqual(@as(usize, 32), cut.len);
    try testing.expectEqual(@as(u8, '~'), cut[31]);
    try testing.expectEqualStrings(full[0..31], cut[0..31]);
    try testing.expect(hc.decode(cmd("le_read_fal_size"), good("le_read_fal_size").sl(), &r));
    var b: [32]u8 = @splat(0xAA);
    const line = hc.describe(cmd("le_read_fal_size"), r, &b);
    try testing.expectEqualStrings("le_read_fal_size ncmd=1 n=16", line);
}

test "statusName, hciVersionName, companyName: hit and miss" {
    try testing.expectEqualStrings("Success", hc.statusName(0x00));
    try testing.expectEqualStrings("Unknown HCI Command", hc.statusName(0x01));
    try testing.expectEqualStrings("Reserved for future use", hc.statusName(0x33));
    try testing.expectEqualStrings("unknown", hc.statusName(0x48));
    try testing.expectEqualStrings("unknown", hc.statusName(0xFF));
    try testing.expectEqualStrings("5.4", hc.hciVersionName(0x0D));
    try testing.expectEqualStrings("1.0b", hc.hciVersionName(0x00));
    try testing.expectEqualStrings("unknown", hc.hciVersionName(0x0E));
    try testing.expectEqualStrings("unknown", hc.hciVersionName(0xFF));
    try testing.expectEqualStrings("5.4", hc.lmpVersionName(0x0D));
    try testing.expectEqualStrings("Espressif", hc.companyName(0x02E5));
    try testing.expectEqualStrings("Ericsson", hc.companyName(0x0000));
    try testing.expectEqualStrings("unknown", hc.companyName(0x02E6));
    try testing.expectEqualStrings("unknown", hc.companyName(0xFFFF));
}

test "decode and verify keep their frame-only meaning next to verifyDeclared" {
    const e = cmd(E);
    // verify(): 0x01 is status_nonzero, a Command Status is other_event.
    const v = hc.verify(e, withStatus(E, 0x01).sl());
    try testing.expectEqual(hc.Rule.status_nonzero, v.fail.rule);
    try testing.expect(v != .other_event);
    try testing.expect(hc.verify(e, cs(e.opcode, 0x01, 1).sl()) == .other_event);
    try testing.expect(hc.verify(e, good(E).sl()) == .ok);
    // verify() does not know about Table 3.1 or the mask.
    try testing.expect(hc.verify(e, good(E).sl()) == .ok);
    // Positive: decode reads a conforming success.
    var r: hc.Readout = .{};
    try testing.expect(hc.decode(cmd(M), good(M).sl(), &r));
    try testing.expectEqual(good_le_mask, r.le_features);
    try testing.expectEqual(@as(u8, 11), r.le_feature_count);
}

/// LE_Features of the `good` reply: bits 0-4, 8, 12, 13, 14, 33, 34.
const good_le_mask: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 14) | (1 << 33) | (1 << 34);
