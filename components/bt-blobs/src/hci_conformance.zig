//! HCI conformance self-check for the controller's local, read-only information
//! commands, checked against Bluetooth Core Specification 5.4.
//!
//! Frame shape (see `transport.zig:112-135`): the event callback hands us the
//! event **without** the H4 type byte: `evt[0]` = event code, `evt[1]` =
//! parameter total length (plen), `evt[2..]` = parameters, `evt.len == 2 + plen`.
//! A Command Complete event (Vol 4 Part E §7.7.14) is
//! `0x0E | plen | ncmd | opcode_lo | opcode_hi | return parameters`.
//!
//! Two classes of check:
//!
//! * **Hard rules** (a hit is a `Violation`). Every one is a "shall" or a
//!   "Reserved for future use" label in the Core Specification; the section is
//!   quoted next to the rule. The general authority for reserved values is
//!   Vol 1 Part C §2.4.1: a device creating a structure to send (explicitly
//!   including Host/Controller messages over HCI) "shall set it to zero", and
//!   "shall not set" a parameter to a value that is reserved for future use.
//! * **Read-only** (decoded into `Readout`, never a `Violation`): values the
//!   Specification leaves to the implementation (vendor subversions, buffer
//!   sizes inside their range, feature masks inside the defined bits, enum
//!   fields such as HCI_Version or Company_Identifier). Those are reported so
//!   the caller can compare them against the vendor's documentation.
//!
//! Deliberately not checked here:
//!
//! * Nothing that needs radio activity or a peer (advertising, scanning,
//!   connections, direct test mode) and nothing that changes controller state.
//! * Frame truncation or concatenation. Those are transport-layer faults; a
//!   frame whose length disagrees with its plen is reported as `other_event`.
//! * The command parameters themselves; `commands` lists what to send.
//! * Values of a *failed* command: per Vol 4 Part E §4.5 the return parameters
//!   may then be short, so only `Status` is checked when it is non-zero.
//! * Num_HCI_Command_Packets: 0 is legal (§7.7.14, §4.4) and is only reported.
//!
//! `verify` judges the frame alone: any non-zero Status is `status_nonzero`.
//! `verifyDeclared` additionally knows what Table 3.1 (Vol 4 Part E §3, "Table
//! 3.1: Alphabetical list of commands and events") lets an LE-only Controller
//! do with each command, and what the Controller itself declared in
//! HCI_Read_Local_Supported_Commands. Per §4.5: "If the Controller does not
//! support an issued command, it shall return the error code Unknown HCI
//! command (0x01) in the Status parameter of either an HCI_Command_Complete
//! event or an HCI_Command_Status event; which event is used is
//! vendor-specific."

const std = @import("std");

/// Event code of HCI_Command_Complete (Vol 4 Part E §7.7.14).
pub const evt_command_complete: u8 = 0x0E;
/// Event code of HCI_Command_Status (Vol 4 Part E §7.7.15): Status,
/// Num_HCI_Command_Packets, Command_Opcode.
pub const evt_command_status: u8 = 0x0F;

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Opcode = (OGF << 10) | OCF, the layout of Command_Opcode
/// (Vol 4 Part E §5.4.6: OGF is the upper 6 bits, OCF the lower 10 bits).
pub fn opc(ogf: u6, ocf: u10) u16 {
    return (@as(u16, ogf) << 10) | @as(u16, ocf);
}

/// Identifies the return-parameter layout of a command.
pub const Kind = enum {
    // OGF 0x04 (Vol 4 Part E §7.4: Informational Parameters)
    local_version,
    supported_commands,
    local_features,
    ext_features,
    buffer_size,
    bd_addr,
    data_block_size,
    codecs_v1,
    sp_options,
    codecs_v2,
    // OGF 0x06 (Vol 4 Part E §7.6: Testing)
    loopback_mode,
    // OGF 0x08 (Vol 4 Part E §7.8: LE Controller)
    le_buffer_size_v1,
    le_features,
    le_adv_tx_power,
    le_fal_size,
    le_states,
    le_default_data_len,
    le_rsl_size,
    le_max_data_len,
    le_max_adv_len,
    le_adv_sets,
    le_pal_size,
    le_tx_power,
    le_rf_comp,
    le_antenna,
    le_buffer_size_v2,
};
/// How Vol 4 Part E Table 3.1 ("Alphabetical list of commands and events")
/// lists the command for an LE Controller. The table gives, per command, one
/// entry for a BR/EDR Controller and one for an LE Controller:
///
/// * `M` Mandatory
/// * `O` Optional
/// * `C.n` Conditional. The footnotes read: C.3 Mandatory if the LE Controller
///   supports Connection State, otherwise excluded. C.8 Mandatory if LE
///   Feature (LE Data Packet Length Extension) is supported, otherwise
///   optional. C.9 Mandatory if LE Feature (LL Privacy) is supported,
///   otherwise excluded. C.17 Mandatory if LE Feature (Extended Advertising)
///   is supported and the LE Controller supports Advertising State, otherwise
///   excluded. C.21 Mandatory if LE Feature (Periodic Advertising) is
///   supported and the LE Controller supports Synchronization State, otherwise
///   excluded. C.22 Mandatory if the LE Controller supports sending Transmit
///   Power in advertisements or if LE Feature (LE Power Control Request) is
///   supported, otherwise optional. C.31 Mandatory if LE Feature (Connection
///   CTE Request) or LE Feature (Connection CTE Response) or LE Feature
///   (Connectionless CTE Transmitter) or LE Feature (Connectionless CTE
///   Receiver) is supported, otherwise excluded. C.55 Mandatory if LE Feature
///   (Connected Isochronous Stream - Central), or LE Feature (Connected
///   Isochronous Stream - Peripheral), or LE Feature (Isochronous Broadcaster)
///   is supported, otherwise optional if the LE Controller supports
///   Connection State, otherwise excluded. C.64 Optional if the Controller
///   supports transmitting packets, otherwise excluded. C.97 Mandatory if
///   Advertising State is supported, otherwise excluded.
/// * `E` Excluded: a conforming LE Controller does not support the command.
///
/// The conditions behind `C.n` are not evaluated here: the Controller's own
/// Supported_Commands mask says which side of the condition it is on.
pub const Support = enum { mandatory, optional, conditional, excluded };

/// No entry in the Supported_Commands table (Vol 4 Part E §6.27).
pub const no_supp_bit: u16 = 0xFFFF;

/// A command the caller sends, plus the layout knowledge needed to verify its
/// Command Complete event. `params` are the command parameter octets.
pub const Command = struct {
    name: []const u8,
    opcode: u16,
    params: []const u8 = &.{},
    /// `null` means "look the opcode up in `commands`".
    kind: ?Kind = null,
    /// Bit index (octet * 8 + bit) in Supported_Commands, Vol 4 Part E §6.27.
    supp_bit: u16 = no_supp_bit,
    /// Table 3.1 entry for an LE Controller. `mandatory` when `kind` is set
    /// and `support` is left out.
    support: Support = .mandatory,
};

/// Commands that take no state-changing parameter and only read local
/// information. Sorted by opcode. `supp_bit` values come from the §6.27 table.
pub const commands: []const Command = &.{
    // §7.4.1 OCF 0x0001: Status, HCI_Version, HCI_Subversion, LMP_Version,
    //                   Company_Identifier, LMP_Subversion
    .{ .name = "read_local_version", .opcode = opc(0x04, 0x001), .kind = .local_version, .supp_bit = 115, .support = .mandatory },
    // §7.4.2 OCF 0x0002: Status, Supported_Commands (64 octets)
    .{ .name = "read_supported_cmds", .opcode = opc(0x04, 0x002), .kind = .supported_commands, .support = .mandatory },
    // §7.4.3 OCF 0x0003: Status, LMP_Features (8 octets)
    .{ .name = "read_local_features", .opcode = opc(0x04, 0x003), .kind = .local_features, .supp_bit = 117, .support = .mandatory },
    // §7.4.4 OCF 0x0004, command parameter Page_Number: Status, Page_Number,
    //                   Max_Page_Number, Extended_LMP_Features. Page 0x00
    //                   "requests the normal LMP features".
    .{ .name = "read_ext_features_p0", .opcode = opc(0x04, 0x004), .kind = .ext_features, .supp_bit = 118, .params = &.{0x00}, .support = .excluded },
    // §7.4.5 OCF 0x0005: Status, ACL_Data_Packet_Length, Synchronous_Data_Packet_Length,
    //                   Total_Num_ACL_Data_Packets, Total_Num_Synchronous_Data_Packets
    .{ .name = "read_buffer_size", .opcode = opc(0x04, 0x005), .kind = .buffer_size, .supp_bit = 119, .support = .excluded },
    // §7.4.6 OCF 0x0009: Status, BD_ADDR
    .{ .name = "read_bd_addr", .opcode = opc(0x04, 0x009), .kind = .bd_addr, .supp_bit = 121, .support = .mandatory },
    // §7.4.7 OCF 0x000A: Status, Max_ACL_Data_Packet_Length, Data_Block_Length,
    //                   Total_Num_Data_Blocks
    .{ .name = "read_data_block_size", .opcode = opc(0x04, 0x00A), .kind = .data_block_size, .supp_bit = 186, .support = .excluded },
    // §7.4.8 [v1] OCF 0x000B: Status, Num_Supported_Standard_Codecs, Standard_Codec_ID[i],
    //                         Num_Supported_Vendor_Specific_Codecs, Vendor_Specific_Codec_ID[k]
    .{ .name = "read_codecs_v1", .opcode = opc(0x04, 0x00B), .kind = .codecs_v1, .supp_bit = 237, .support = .excluded },
    // §7.4.9 OCF 0x000C: Status, Simple_Pairing_Options, Max_Encryption_Key_Size
    .{ .name = "read_sp_options", .opcode = opc(0x04, 0x00C), .kind = .sp_options, .supp_bit = 331, .support = .excluded },
    // §7.4.8 [v2] OCF 0x000D: as [v1] plus a transport octet per codec
    .{ .name = "read_codecs_v2", .opcode = opc(0x04, 0x00D), .kind = .codecs_v2, .supp_bit = 362, .support = .optional },
    // §7.6.1 OCF 0x0001: Status, Loopback_Mode
    .{ .name = "read_loopback_mode", .opcode = opc(0x06, 0x001), .kind = .loopback_mode, .supp_bit = 128, .support = .excluded },
    // §7.8.2 [v1] OCF 0x0002: Status, LE_ACL_Data_Packet_Length, Total_Num_LE_ACL_Data_Packets
    .{ .name = "le_read_buffer_size", .opcode = opc(0x08, 0x002), .kind = .le_buffer_size_v1, .supp_bit = 201, .support = .conditional },
    // §7.8.3 OCF 0x0003: Status, LE_Features (8 octets)
    .{ .name = "le_read_features", .opcode = opc(0x08, 0x003), .kind = .le_features, .supp_bit = 202, .support = .mandatory },
    // §7.8.6 OCF 0x0007: Status, TX_Power_Level
    .{ .name = "le_read_adv_tx_power", .opcode = opc(0x08, 0x007), .kind = .le_adv_tx_power, .supp_bit = 206, .support = .conditional },
    // §7.8.14 OCF 0x000F: Status, Filter_Accept_List_Size
    .{ .name = "le_read_fal_size", .opcode = opc(0x08, 0x00F), .kind = .le_fal_size, .supp_bit = 214, .support = .mandatory },
    // §7.8.27 OCF 0x001C: Status, LE_States (8 octets)
    .{ .name = "le_read_states", .opcode = opc(0x08, 0x01C), .kind = .le_states, .supp_bit = 227, .support = .mandatory },
    // §7.8.34 OCF 0x0023: Status, Suggested_Max_TX_Octets, Suggested_Max_TX_Time
    .{ .name = "le_read_default_dl", .opcode = opc(0x08, 0x023), .kind = .le_default_data_len, .supp_bit = 271, .support = .conditional },
    // §7.8.41 OCF 0x002A: Status, Resolving_List_Size
    .{ .name = "le_read_rsl_size", .opcode = opc(0x08, 0x02A), .kind = .le_rsl_size, .supp_bit = 278, .support = .conditional },
    // §7.8.46 OCF 0x002F: Status, Supported_Max_TX_Octets, Supported_Max_TX_Time,
    //                     Supported_Max_RX_Octets, Supported_Max_RX_Time
    .{ .name = "le_read_max_dl", .opcode = opc(0x08, 0x02F), .kind = .le_max_data_len, .supp_bit = 283, .support = .conditional },
    // §7.8.57 OCF 0x003A: Status, Max_Advertising_Data_Length
    .{ .name = "le_read_max_adv_len", .opcode = opc(0x08, 0x03A), .kind = .le_max_adv_len, .supp_bit = 294, .support = .conditional },
    // §7.8.58 OCF 0x003B: Status, Num_Supported_Advertising_Sets
    .{ .name = "le_read_adv_sets", .opcode = opc(0x08, 0x03B), .kind = .le_adv_sets, .supp_bit = 295, .support = .conditional },
    // §7.8.73 OCF 0x004A: Status, Periodic_Advertiser_List_Size
    .{ .name = "le_read_pal_size", .opcode = opc(0x08, 0x04A), .kind = .le_pal_size, .supp_bit = 310, .support = .conditional },
    // §7.8.74 OCF 0x004B: Status, Min_TX_Power, Max_TX_Power
    .{ .name = "le_read_tx_power", .opcode = opc(0x08, 0x04B), .kind = .le_tx_power, .supp_bit = 311, .support = .conditional },
    // §7.8.75 OCF 0x004C: Status, RF_TX_Path_Compensation_Value, RF_RX_Path_Compensation_Value
    .{ .name = "le_read_rf_comp", .opcode = opc(0x08, 0x04C), .kind = .le_rf_comp, .supp_bit = 312, .support = .conditional },
    // §7.8.87 OCF 0x0058: Status, Supported_Switching_Sampling_Rates, Num_Antennae,
    //                    Max_Switching_Pattern_Length, Max_CTE_Length
    .{ .name = "le_read_antenna", .opcode = opc(0x08, 0x058), .kind = .le_antenna, .supp_bit = 324, .support = .conditional },
    // §7.8.2 [v2] OCF 0x0060: as [v1] plus ISO_Data_Packet_Length, Total_Num_ISO_Data_Packets
    .{ .name = "le_read_buffer_size_v2", .opcode = opc(0x08, 0x060), .kind = .le_buffer_size_v2, .supp_bit = 333, .support = .conditional },
};

fn resolve(cmd: Command) ?Command {
    if (cmd.kind != null) return cmd;
    for (commands) |c| if (c.opcode == cmd.opcode) return c;
    return null;
}

/// Whether the Controller claims, in a Supported_Commands mask obtained from
/// HCI_Read_Local_Supported_Commands, to support `cmd`. Bits: §6.27.
pub fn reportsSupport(mask: *const [64]u8, cmd: Command) bool {
    const c = resolve(cmd) orelse return false;
    if (c.supp_bit == no_supp_bit) return true; // mandatory command, no bit defined
    return bitSet(mask, c.supp_bit);
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------

pub const Rule = enum {
    /// Return parameters shorter or longer than the Specification defines.
    /// detail = (got_length << 16) | expected_length (0xFFFF when variable).
    bad_param_len,
    /// Status was not 0x00. detail = the Status value (see `statusName`).
    status_nonzero,
    /// A bit labelled "Reserved for future use" is set.
    /// detail = bit index; for per-codec transport masks detail = (entry << 8) | bit.
    reserved_bit_set,
    /// A parameter is outside its defined range. detail = the value.
    value_out_of_range,
    /// LE_ACL_Data_Packet_Length fell in the reserved 0x0001..0x001A gap.
    /// detail = the value.
    length_too_small,
    /// Returned Page_Number differs from the requested one.
    /// detail = (got << 8) | requested.
    echo_mismatch,
    /// LE_States: a supported combination requires another one that is clear
    /// (Vol 6 Part B §1.1.1, Table 1.1); or LMP Sniff mode / Sniff subrating
    /// not both set (Vol 2 Part C §3.5.1, Table 3.7).
    /// detail = (set_bit << 16) | required_bit.
    combo_missing,
    /// A supported feature requires another feature that is clear.
    /// detail = (feature_bit << 16) | first missing required bit.
    feature_dep_missing,
    /// A feature the Specification makes mandatory is clear. detail = bit.
    feature_missing,
    /// A feature the Specification forbids is set. detail = bit.
    feature_forbidden,
    /// LE_Features bits 33 and 34 differ. detail = (bit33 << 1) | bit34.
    features_mismatch,
    /// A command Table 3.1 makes mandatory for an LE Controller answered
    /// Unknown HCI Command (0x01). §4.5. detail = the Status value.
    mandatory_unsupported,
    /// A command Table 3.1 excludes for an LE Controller answered with success.
    /// detail = 0.
    excluded_but_supported,
    /// The reply disagrees with the Controller's own Supported_Commands
    /// (§6.27, §7.4.2). detail = 1: the bit is set but the reply was Unknown
    /// HCI Command; 0: the bit is clear but the command succeeded; 2: the bit
    /// of an excluded command is set.
    support_bit_mismatch,
    /// A command of the quickly-completing kind (§5.4.1, §7.7.14) answered
    /// with an HCI_Command_Status whose Status is 0x00. §4.5 reserves
    /// HCI_Command_Status for errors and for commands that take long. detail = 0.
    status_event,
};

pub const Violation = struct {
    rule: Rule,
    detail: u32 = 0,
};

/// Verdict of `verifyDeclared`.
pub const Declared = union(enum) {
    /// Not this command's Command Complete or Command Status.
    other_event,
    /// Success, consistent with Table 3.1 and the Supported_Commands mask.
    ok: Readout,
    /// Unknown HCI Command (0x01) from a command that need not be supported.
    /// `Readout.ncmd` is Num_HCI_Command_Packets.
    not_supported: Readout,
    fail: Violation,
};

/// Decoded return parameters of one successful command. Numeric values only;
/// the name fields point at static strings.
pub const Readout = struct {
    /// Num_HCI_Command_Packets (§7.7.14). 0 is legal: the Controller requires
    /// the Host to stop sending commands (§4.4) until an event with
    /// Command_Opcode 0x0000 arrives. Reported, never a rule.
    ncmd: u8 = 0,

    // §7.4.1
    hci_version: u8 = 0,
    hci_version_name: []const u8 = unknown,
    hci_subversion: u16 = 0,
    lmp_version: u8 = 0,
    lmp_version_name: []const u8 = unknown,
    company_id: u16 = 0,
    company_name: []const u8 = unknown,
    lmp_subversion: u16 = 0,

    // §7.4.2
    supported_commands: [64]u8 = @splat(0),
    supported_cmd_count: u16 = 0,
    supported_cmd_reserved: bool = false,

    // §7.4.3 / §7.4.4
    lmp_features: u64 = 0,
    lmp_feature_count: u8 = 0,
    ext_page: u8 = 0,
    ext_max_page: u8 = 0,

    // §7.4.5
    acl_len: u16 = 0,
    sco_len: u8 = 0,
    num_acl: u16 = 0,
    num_sco: u16 = 0,

    // §7.4.6
    bd_addr: [6]u8 = @splat(0),

    // §7.4.7
    block_acl_len: u16 = 0,
    block_len: u16 = 0,
    num_blocks: u16 = 0,

    // §7.4.8
    codec_std: u8 = 0,
    codec_vendor: u8 = 0,

    // §7.4.9
    sp_options: u8 = 0,
    max_key_size: u8 = 0,

    // §7.6.1
    loopback_mode: u8 = 0,

    // §7.8.2
    le_acl_len: u16 = 0,
    le_num_acl: u8 = 0,
    iso_len: u16 = 0,
    iso_num: u8 = 0,

    // §7.8.3
    le_features: u64 = 0,
    le_feature_count: u8 = 0,

    adv_tx_power: i8 = 0, // §7.8.6, dBm
    fal_size: u8 = 0, // §7.8.14

    le_states: u64 = 0, // §7.8.27
    le_state_count: u8 = 0,

    sugg_tx_octets: u16 = 0, // §7.8.34
    sugg_tx_time: u16 = 0,
    rsl_size: u8 = 0, // §7.8.41
    max_tx_octets: u16 = 0, // §7.8.46
    max_tx_time: u16 = 0,
    max_rx_octets: u16 = 0,
    max_rx_time: u16 = 0,
    max_adv_len: u16 = 0, // §7.8.57
    adv_sets: u8 = 0, // §7.8.58
    pal_size: u8 = 0, // §7.8.73
    min_tx_power: i8 = 0, // §7.8.74, dBm
    max_tx_power: i8 = 0,
    rf_tx: i16 = 0, // §7.8.75, units of 0.1 dB
    rf_rx: i16 = 0,
    ant_rates: u8 = 0, // §7.8.87
    antennae: u8 = 0,
    switch_len: u8 = 0,
    cte_len: u8 = 0,
};

const unknown = "unknown";

pub const Verdict = union(enum) {
    /// Not this command's Command Complete: another event, another opcode, or a
    /// frame too short / inconsistent to tell. The caller keeps waiting.
    other_event,
    ok: Readout,
    fail: Violation,
};

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

fn rd16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}

fn mask64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

fn bitSet(mask: []const u8, i: u16) bool {
    return (mask[i >> 3] >> @as(u3, @intCast(i & 7))) & 1 != 0;
}

fn popcountMask(mask: []const u8) u16 {
    var n: u16 = 0;
    for (mask) |b| n += @as(u16, @popCount(b));
    return n;
}

fn lowBit(v: u64) u32 {
    return @ctz(v);
}

fn inRange(v: u16, lo: u16, hi: u16) bool {
    return v >= lo and v <= hi;
}

/// Length of the return parameters (Status included) for a fixed-layout
/// command. `null` for the two variable-length codec commands.
fn retLen(kind: Kind) ?u16 {
    return switch (kind) {
        .local_version => 1 + 1 + 2 + 1 + 2 + 2,
        .supported_commands => 1 + 64,
        .local_features => 1 + 8,
        .ext_features => 1 + 1 + 1 + 8,
        .buffer_size => 1 + 2 + 1 + 2 + 2,
        .bd_addr => 1 + 6,
        .data_block_size => 1 + 2 + 2 + 2,
        .sp_options => 1 + 1 + 1,
        .loopback_mode => 1 + 1,
        .le_buffer_size_v1 => 1 + 2 + 1,
        .le_buffer_size_v2 => 1 + 2 + 1 + 2 + 1,
        .le_features => 1 + 8,
        .le_adv_tx_power => 1 + 1,
        .le_fal_size => 1 + 1,
        .le_states => 1 + 8,
        .le_default_data_len => 1 + 2 + 2,
        .le_rsl_size => 1 + 1,
        .le_max_data_len => 1 + 2 + 2 + 2 + 2,
        .le_max_adv_len => 1 + 2,
        .le_adv_sets => 1 + 1,
        .le_pal_size => 1 + 1,
        .le_tx_power => 1 + 1 + 1,
        .le_rf_comp => 1 + 2 + 2,
        .le_antenna => 1 + 1 + 1 + 1 + 1,
        .codecs_v1, .codecs_v2 => null,
    };
}

fn fill(kind: Kind, ret: []const u8, out: *Readout) void {
    switch (kind) {
        .local_version => {
            out.hci_version = ret[1];
            out.hci_version_name = versionName(ret[1]);
            out.hci_subversion = rd16(ret[2..4]);
            out.lmp_version = ret[4];
            out.lmp_version_name = versionName(ret[4]);
            out.company_id = rd16(ret[5..7]);
            out.company_name = companyName(out.company_id);
            out.lmp_subversion = rd16(ret[7..9]);
        },
        .supported_commands => {
            @memcpy(&out.supported_commands, ret[1..65]);
            out.supported_cmd_count = popcountMask(&out.supported_commands);
            out.supported_cmd_reserved = firstRfuBit(&out.supported_commands, &rfu_supported_commands) != null;
        },
        .local_features => {
            out.lmp_features = mask64(ret[1..9]);
            out.lmp_feature_count = @popCount(out.lmp_features);
        },
        .ext_features => {
            out.ext_page = ret[1];
            out.ext_max_page = ret[2];
            out.lmp_features = mask64(ret[3..11]);
            out.lmp_feature_count = @popCount(out.lmp_features);
        },
        .buffer_size => {
            out.acl_len = rd16(ret[1..3]);
            out.sco_len = ret[3];
            out.num_acl = rd16(ret[4..6]);
            out.num_sco = rd16(ret[6..8]);
        },
        .bd_addr => @memcpy(&out.bd_addr, ret[1..7]),
        .data_block_size => {
            out.block_acl_len = rd16(ret[1..3]);
            out.block_len = rd16(ret[3..5]);
            out.num_blocks = rd16(ret[5..7]);
        },
        .codecs_v1 => {
            out.codec_std = ret[1];
            out.codec_vendor = ret[2 + @as(usize, ret[1])];
        },
        .codecs_v2 => {
            out.codec_std = ret[1];
            out.codec_vendor = ret[2 + 2 * @as(usize, ret[1])];
        },
        .sp_options => {
            out.sp_options = ret[1];
            out.max_key_size = ret[2];
        },
        .loopback_mode => out.loopback_mode = ret[1],
        .le_buffer_size_v1 => {
            out.le_acl_len = rd16(ret[1..3]);
            out.le_num_acl = ret[3];
        },
        .le_buffer_size_v2 => {
            out.le_acl_len = rd16(ret[1..3]);
            out.le_num_acl = ret[3];
            out.iso_len = rd16(ret[4..6]);
            out.iso_num = ret[6];
        },
        .le_features => {
            out.le_features = mask64(ret[1..9]);
            out.le_feature_count = @popCount(out.le_features);
        },
        .le_adv_tx_power => out.adv_tx_power = @bitCast(ret[1]),
        .le_fal_size => out.fal_size = ret[1],
        .le_states => {
            out.le_states = mask64(ret[1..9]);
            out.le_state_count = @popCount(out.le_states);
        },
        .le_default_data_len => {
            out.sugg_tx_octets = rd16(ret[1..3]);
            out.sugg_tx_time = rd16(ret[3..5]);
        },
        .le_rsl_size => out.rsl_size = ret[1],
        .le_max_data_len => {
            out.max_tx_octets = rd16(ret[1..3]);
            out.max_tx_time = rd16(ret[3..5]);
            out.max_rx_octets = rd16(ret[5..7]);
            out.max_rx_time = rd16(ret[7..9]);
        },
        .le_max_adv_len => out.max_adv_len = rd16(ret[1..3]),
        .le_adv_sets => out.adv_sets = ret[1],
        .le_pal_size => out.pal_size = ret[1],
        .le_tx_power => {
            out.min_tx_power = @bitCast(ret[1]);
            out.max_tx_power = @bitCast(ret[2]);
        },
        .le_rf_comp => {
            out.rf_tx = @bitCast(rd16(ret[1..3]));
            out.rf_rx = @bitCast(rd16(ret[3..5]));
        },
        .le_antenna => {
            out.ant_rates = ret[1];
            out.antennae = ret[2];
            out.switch_len = ret[3];
            out.cte_len = ret[4];
        },
    }
}

const Parsed = union(enum) { other, bad: Violation, ok };

/// Frame shape, opcode, Status and return-parameter length. On `.ok` the
/// return parameters are in `out`. The frame shape test only rejects what the
/// transport layer breaks (truncation, concatenation); that is not a protocol
/// rule, hence `.other`.
fn parse(c: Command, evt: []const u8, out: *Readout) Parsed {
    // Vol 4 Part E §5.4.4: header is Event_Code + Parameter_Total_Length, and
    // Parameter_Total_Length is the length of all parameters.
    if (evt.len < 2 or evt[0] != evt_command_complete or evt.len != 2 + @as(usize, evt[1])) return .other;
    if (evt.len < 5) return .other; // no Command_Opcode field: cannot attribute
    if (rd16(evt[3..5]) != c.opcode) return .other;
    out.ncmd = evt[2];
    const kind = c.kind.?;
    if (evt.len == 5) return .{ .bad = badLen(0, retLen(kind) orelse 0xFFFF) };
    // §7.7.14 / §4.5: the error of a Command Complete command is in Status.
    if (evt[5] != 0) return .{ .bad = .{ .rule = .status_nonzero, .detail = evt[5] } };
    const ret = evt[5..];
    // §7.4.8: the octet counts define the total length. For the fixed-layout
    // commands §7.7.14 defines Return_Parameters as those of the one command
    // named by Command_Opcode, and §5.4.4 gives each parameter a defined
    // size: octets beyond that length therefore fail.
    const want: u16 = switch (kind) {
        .codecs_v1 => codecLenV1(ret) orelse return .{ .bad = badLen(ret.len, 0xFFFF) },
        .codecs_v2 => codecLenV2(ret) orelse return .{ .bad = badLen(ret.len, 0xFFFF) },
        else => retLen(kind).?,
    };
    if (ret.len != want) return .{ .bad = badLen(ret.len, want) };
    fill(kind, ret, out);
    return .ok;
}

/// Length implied by the octet counts of Read Local Supported Codecs [v1];
/// `null` when the counts themselves are not present.
fn codecLenV1(ret: []const u8) ?u16 {
    if (ret.len < 2) return null;
    const n: usize = ret[1];
    if (ret.len < 2 + n + 1) return null;
    return @intCast(2 + n + 1 + 4 * @as(usize, ret[2 + n]));
}

/// As `codecLenV1` for [v2]: two octets per standard codec, five per vendor.
fn codecLenV2(ret: []const u8) ?u16 {
    if (ret.len < 2) return null;
    const n: usize = ret[1];
    if (ret.len < 2 + 2 * n + 1) return null;
    return @intCast(2 + 2 * n + 1 + 5 * @as(usize, ret[2 + 2 * n]));
}

fn badLen(got: usize, want: u16) Violation {
    return .{ .rule = .bad_param_len, .detail = (@as(u32, @intCast(got)) << 16) | want };
}

/// Decodes a successful reply into `out`. `false` when `evt` is not a
/// well-formed, successful Command Complete of `cmd` (i.e. `verify` would not
/// return `.ok`). Field rules are not applied here.
pub fn decode(cmd: Command, evt: []const u8, out: *Readout) bool {
    const c = resolve(cmd) orelse return false;
    return parse(c, evt, out) == .ok;
}

/// Verifies the Command Complete event `evt` of `cmd` against Core 5.4.
pub fn verify(cmd: Command, evt: []const u8) Verdict {
    const c = resolve(cmd) orelse return .other_event;
    var out: Readout = .{};
    switch (parse(c, evt, &out)) {
        .other => return .other_event,
        .bad => |v| return .{ .fail = v },
        .ok => {},
    }
    if (rules(c, evt[5..], &out)) |v| return .{ .fail = v };
    return .{ .ok = out };
}

/// Verifies `evt`, the reply to `cmd`, against Core 5.4 and against what the
/// Controller has declared about itself.
///
/// `evt` is either this command's HCI_Command_Complete (§7.7.14) or its
/// HCI_Command_Status (§7.7.15: Status, Num_HCI_Command_Packets,
/// Command_Opcode). `mask` is the Supported_Commands octets read with
/// HCI_Read_Local_Supported_Commands, or `null` while they are unknown (all
/// bit checks are then skipped).
///
/// * Success: the field rules of `verify` apply first; success from a command
///   Table 3.1 excludes, or whose own Supported_Commands bit is clear, fails.
/// * Status 0x01 (Unknown HCI Command, §4.5): a mandatory command fails;
///   otherwise the Supported_Commands bit decides, and if it is clear (or
///   unknown) the reply is `not_supported`, not a violation.
/// * Any other non-zero Status fails with `status_nonzero`.
/// * HCI_Command_Status with Status 0x00 fails with `status_event`: these
///   commands complete locally and owe a Command Complete event.
pub fn verifyDeclared(cmd: Command, evt: []const u8, mask: ?*const [64]u8) Declared {
    const c = resolve(cmd) orelse return .other_event;
    var out: Readout = .{};
    switch (parse(c, evt, &out)) {
        .other => {},
        .bad => |v| {
            if (v.rule == .status_nonzero) return unsupportedOrError(c, @intCast(v.detail), out.ncmd, mask);
            return .{ .fail = v };
        },
        .ok => {
            if (rules(c, evt[5..], &out)) |v| return .{ .fail = v };
            if (c.support == .excluded) return .{ .fail = .{ .rule = .excluded_but_supported } };
            if (mask) |m| {
                if (c.supp_bit != no_supp_bit and !bitSet(m, c.supp_bit)) {
                    return .{ .fail = .{ .rule = .support_bit_mismatch, .detail = 0 } };
                }
            }
            return .{ .ok = out };
        },
    }
    if (!isCommandStatus(c, evt)) return .other_event;
    // §7.7.15 parameters: Status = evt[2], Num_HCI_Command_Packets = evt[3].
    out.ncmd = evt[3];
    if (evt[2] == 0) return .{ .fail = .{ .rule = .status_event } };
    return unsupportedOrError(c, evt[2], out.ncmd, mask);
}

/// Status 0x01 judged by Table 3.1 and the Supported_Commands bit; any other
/// Status is `status_nonzero`.
fn unsupportedOrError(c: Command, status: u8, ncmd: u8, mask: ?*const [64]u8) Declared {
    if (status != 0x01) return .{ .fail = .{ .rule = .status_nonzero, .detail = status } };
    if (c.support == .mandatory) return .{ .fail = .{ .rule = .mandatory_unsupported, .detail = status } };
    if (mask) |m| {
        if (c.supp_bit != no_supp_bit and bitSet(m, c.supp_bit)) {
            return .{ .fail = .{ .rule = .support_bit_mismatch, .detail = if (c.support == .excluded) 2 else 1 } };
        }
    }
    return .{ .not_supported = .{ .ncmd = ncmd } };
}

/// Whether `evt` is exactly an HCI_Command_Status of `cmd`: event code,
/// Parameter_Total_Length 4 (§7.7.15), frame length and Command_Opcode.
fn isCommandStatus(c: Command, evt: []const u8) bool {
    return evt.len == 6 and evt[0] == evt_command_status and evt[1] == 4 and rd16(evt[4..6]) == c.opcode;
}

// ---------------------------------------------------------------------------
// Specification tables
// ---------------------------------------------------------------------------

/// Supported_Commands octets with "Reserved for future use" in Vol 4 Part E
/// §6.27. The table ends at octet 47; octets 48..63 are "all other octets".
const rfu_supported_commands = [64]u8{
    0x00, 0x00, 0x00, 0xFC, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0xF0, 0x17, 0x00,
    0xC0, 0x08, 0x70, 0x00, 0xE3, 0x00, 0x00, 0x18, 0x82, 0x08, 0x00, 0x00, 0x80, 0x07, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0xFC,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
};

fn firstRfuBit(mask: []const u8, rfu: []const u8) ?u32 {
    for (mask, rfu, 0..) |m, r, i| {
        if (m & r != 0) return @intCast(i * 8 + @ctz(m & r));
    }
    return null;
}

// LMP feature page 0: Vol 2 Part C §3.3 Table 3.2 (bit numbers), §3.5 (rules).
const lmp_rfu: u64 = (1 << 24) | (1 << 34) | (1 << 50) | (1 << 55) | (1 << 59) | (1 << 60) | (1 << 61) | (1 << 62);
const LMP_SNIFF = 7;
const LMP_SNIFF_SUBRATING = 41;
const LMP_BREDR_NOT_SUPPORTED = 37;
const LMP_LE_SUPPORTED = 38;
/// §3.5.1 Table 3.5: mandatory on a BR/EDR device: Encryption (2), Secure
/// Simple Pairing (Controller Support) (51), Encapsulated PDU (52).
const lmp_mandatory_bredr: u64 = (1 << 2) | (1 << 51) | (1 << 52);
/// §3.5.2 Table 3.10: BR/EDR Not Supported (37) and LE Supported (38) shall
/// be set; Table 3.11: Extended features (63) and LE Supported (Host) (65 is
/// page 1) are the only optional ones; "no other feature bit shall be set".
const lmp_mandatory_le_only: u64 = (1 << 37) | (1 << 38);
const lmp_only_le_allowed: u64 = (1 << 37) | (1 << 38) | (1 << 63);

/// §3.5.1 Table 3.9 "Features that require other features", page-0 rows only
/// (rows naming page-1 bits cannot be checked against page 0).
const LmpDep = struct { f: u6, all: []const u6 = &.{}, any: []const u6 = &.{} };
const lmp_deps = [_]LmpDep{
    .{ .f = 5, .all = &.{3} },
    .{ .f = 12, .all = &.{11} },
    .{ .f = 13, .all = &.{11} },
    .{ .f = 14, .any = &.{ 11, 31 } },
    .{ .f = 15, .any = &.{ 11, 31 } },
    .{ .f = 16, .any = &.{ 11, 31 } },
    .{ .f = 19, .any = &.{ 11, 31 } },
    .{ .f = 26, .all = &.{25} },
    .{ .f = 32, .all = &.{31} },
    .{ .f = 33, .all = &.{31} },
    .{ .f = 36, .all = &.{35} },
    .{ .f = 39, .all = &.{25} },
    .{ .f = 40, .all = &.{25} },
    .{ .f = 44, .all = &.{43} },
    .{ .f = 45, .all = &.{31} },
    .{ .f = 46, .all = &.{45} },
    .{ .f = 47, .all = &.{45} },
    .{ .f = 48, .all = &.{30} },
    .{ .f = 49, .all = &.{38} },
    .{ .f = 53, .any = &.{ 11, 31 } },
    .{ .f = 58, .all = &.{ 9, 18 } },
};

// LE_Features: Vol 6 Part B §4.6 Table 4.7. Defined bits are 0..41, 43, 44.
const le_rfu: u64 = (1 << 42) | (~@as(u64, 0) << 45);
const LE_EXT_REJECT = 2;
const LE_EXT_ADV = 12;
const LE_CSA2 = 14;
const LE_PC_REQUEST_A = 33; // Table 4.7 lists 33 and 34 both as "LE Power Control Request"

/// "A Controller that supports X shall support the Y feature": §4.6.2,
/// §4.6.9 (any PHY other than LE 1M: bits 8 and 11), §4.6.13.
const LeDep = struct { f: u6, any: []const u6 = &.{} };
const le_deps = [_]LeDep{
    .{ .f = 1, .any = &.{LE_EXT_REJECT} },
    .{ .f = 8, .any = &.{LE_EXT_REJECT} },
    .{ .f = 11, .any = &.{LE_EXT_REJECT} },
    .{ .f = 13, .any = &.{ LE_EXT_ADV, LE_CSA2 } },
};

// LE_States, Vol 4 Part E §7.8.27 table. Column bits: 0 scannable undirected
// advertising, 1 connectable+scannable undirected advertising, 2 non-connectable
// +non-scannable undirected advertising, 3 high-duty-cycle directed advertising,
// 4 low-duty-cycle directed advertising, 5 active scanning, 6 passive scanning,
// 7 initiating, 8 connection state (central), 9 connection state (peripheral).
const S_SCA: u10 = 1 << 0;
const S_CSA: u10 = 1 << 1;
const S_NCA: u10 = 1 << 2;
const S_HDA: u10 = 1 << 3;
const S_LDA: u10 = 1 << 4;
const S_AS: u10 = 1 << 5;
const S_PS: u10 = 1 << 6;
const S_INI: u10 = 1 << 7;
const S_CEN: u10 = 1 << 8;
const S_PER: u10 = 1 << 9;
const S_CONNECTABLE_ADV: u10 = S_CSA | S_HDA | S_LDA;

/// State combination of each LE_States bit 0..41 as a column mask.
const le_state_cols = [42]u10{
    S_NCA, // 0
    S_SCA, // 1
    S_CSA, // 2
    S_HDA, // 3
    S_PS, // 4
    S_AS, // 5
    S_INI, // 6
    S_PER, // 7
    S_NCA | S_PS, // 8
    S_SCA | S_PS, // 9
    S_CSA | S_PS, // 10
    S_HDA | S_PS, // 11
    S_NCA | S_AS, // 12
    S_SCA | S_AS, // 13
    S_CSA | S_AS, // 14
    S_HDA | S_AS, // 15
    S_NCA | S_INI, // 16
    S_SCA | S_INI, // 17
    S_NCA | S_CEN, // 18
    S_SCA | S_CEN, // 19
    S_NCA | S_PER, // 20
    S_SCA | S_PER, // 21
    S_PS | S_INI, // 22
    S_AS | S_INI, // 23
    S_PS | S_CEN, // 24
    S_AS | S_CEN, // 25
    S_PS | S_PER, // 26
    S_AS | S_PER, // 27
    S_INI | S_CEN, // 28
    S_LDA, // 29
    S_LDA | S_PS, // 30
    S_LDA | S_AS, // 31
    S_CSA | S_INI, // 32
    S_HDA | S_INI, // 33
    S_LDA | S_INI, // 34
    S_CSA | S_CEN, // 35
    S_HDA | S_CEN, // 36
    S_LDA | S_CEN, // 37
    S_CSA | S_PER, // 38
    S_HDA | S_PER, // 39
    S_LDA | S_PER, // 40
    S_INI | S_PER, // 41
};

fn findState(want: u10) u8 {
    for (le_state_cols, 0..) |m, b| if (m == want) return @intCast(b);
    return 0xFF;
}

/// Vol 6 Part B §1.1.1 Table 1.1: "Initiating plus any combination C of other
/// states" requires "Connection (Central role) plus the same combination C";
/// "a connectable Advertising state plus any combination C" requires
/// "Connection (Peripheral role) plus the same combination C". For each bit,
/// the index of the required bit, or 0xFF when the required combination is not
/// an LE_States entry (e.g. central role alone) or the bit implies nothing.
const implied = blk: {
    @setEvalBranchQuota(4000);
    var ini: [42]u8 = @splat(0xFF);
    var per: [42]u8 = @splat(0xFF);
    for (le_state_cols, 0..) |m, b| {
        if (m & S_INI != 0) ini[b] = findState((m & ~S_INI) | S_CEN);
        if (m & S_CONNECTABLE_ADV != 0) per[b] = findState((m & ~S_CONNECTABLE_ADV) | S_PER);
    }
    break :blk .{ .ini = ini, .per = per };
};

/// Vol 1 Part F §1.3 Table 1.1, list of error codes.
const StatusCode = struct { code: u8, name: []const u8 };
const status_table = [_]StatusCode{
    .{ .code = 0x00, .name = "Success" },
    .{ .code = 0x01, .name = "Unknown HCI Command" },
    .{ .code = 0x02, .name = "Unknown Connection Identifier" },
    .{ .code = 0x03, .name = "Hardware Failure" },
    .{ .code = 0x04, .name = "Page Timeout" },
    .{ .code = 0x05, .name = "Authentication Failure" },
    .{ .code = 0x06, .name = "PIN or Key Missing" },
    .{ .code = 0x07, .name = "Memory Capacity Exceeded" },
    .{ .code = 0x08, .name = "Connection Timeout" },
    .{ .code = 0x09, .name = "Connection Limit Exceeded" },
    .{ .code = 0x0A, .name = "Synchronous Connection Limit To A Device Exceeded" },
    .{ .code = 0x0B, .name = "Connection Already Exists" },
    .{ .code = 0x0C, .name = "Command Disallowed" },
    .{ .code = 0x0D, .name = "Connection Rejected due to Limited Resources" },
    .{ .code = 0x0E, .name = "Connection Rejected Due To Security Reasons" },
    .{ .code = 0x0F, .name = "Connection Rejected due to Unacceptable BD_ADDR" },
    .{ .code = 0x10, .name = "Connection Accept Timeout Exceeded" },
    .{ .code = 0x11, .name = "Unsupported Feature or Parameter Value" },
    .{ .code = 0x12, .name = "Invalid HCI Command Parameters" },
    .{ .code = 0x13, .name = "Remote User Terminated Connection" },
    .{ .code = 0x14, .name = "Remote Device Terminated Connection due to Low Resources" },
    .{ .code = 0x15, .name = "Remote Device Terminated Connection due to Power Off" },
    .{ .code = 0x16, .name = "Connection Terminated By Local Host" },
    .{ .code = 0x17, .name = "Repeated Attempts" },
    .{ .code = 0x18, .name = "Pairing Not Allowed" },
    .{ .code = 0x19, .name = "Unknown LMP PDU" },
    .{ .code = 0x1A, .name = "Unsupported Remote Feature" },
    .{ .code = 0x1B, .name = "SCO Offset Rejected" },
    .{ .code = 0x1C, .name = "SCO Interval Rejected" },
    .{ .code = 0x1D, .name = "SCO Air Mode Rejected" },
    .{ .code = 0x1E, .name = "Invalid LMP Parameters / Invalid LL Parameters" },
    .{ .code = 0x1F, .name = "Unspecified Error" },
    .{ .code = 0x20, .name = "Unsupported LMP Parameter Value / Unsupported LL Parameter Value" },
    .{ .code = 0x21, .name = "Role Change Not Allowed" },
    .{ .code = 0x22, .name = "LMP Response Timeout / LL Response Timeout" },
    .{ .code = 0x23, .name = "LMP Error Transaction Collision / LL Procedure Collision" },
    .{ .code = 0x24, .name = "LMP PDU Not Allowed" },
    .{ .code = 0x25, .name = "Encryption Mode Not Acceptable" },
    .{ .code = 0x26, .name = "Link Key cannot be Changed" },
    .{ .code = 0x27, .name = "Requested QoS Not Supported" },
    .{ .code = 0x28, .name = "Instant Passed" },
    .{ .code = 0x29, .name = "Pairing With Unit Key Not Supported" },
    .{ .code = 0x2A, .name = "Different Transaction Collision" },
    .{ .code = 0x2B, .name = "Reserved for future use" },
    .{ .code = 0x2C, .name = "QoS Unacceptable Parameter" },
    .{ .code = 0x2D, .name = "QoS Rejected" },
    .{ .code = 0x2E, .name = "Channel Classification Not Supported" },
    .{ .code = 0x2F, .name = "Insufficient Security" },
    .{ .code = 0x30, .name = "Parameter Out Of Mandatory Range" },
    .{ .code = 0x31, .name = "Reserved for future use" },
    .{ .code = 0x32, .name = "Role Switch Pending" },
    .{ .code = 0x33, .name = "Reserved for future use" },
    .{ .code = 0x34, .name = "Reserved Slot Violation" },
    .{ .code = 0x35, .name = "Role Switch Failed" },
    .{ .code = 0x36, .name = "Extended Inquiry Response Too Large" },
    .{ .code = 0x37, .name = "Secure Simple Pairing Not Supported By Host" },
    .{ .code = 0x38, .name = "Host Busy - Pairing" },
    .{ .code = 0x39, .name = "Connection Rejected due to No Suitable Channel Found" },
    .{ .code = 0x3A, .name = "Controller Busy" },
    .{ .code = 0x3B, .name = "Unacceptable Connection Parameters" },
    .{ .code = 0x3C, .name = "Advertising Timeout" },
    .{ .code = 0x3D, .name = "Connection Terminated due to MIC Failure" },
    .{ .code = 0x3E, .name = "Connection Failed to be Established / Synchronization Timeout" },
    .{ .code = 0x3F, .name = "Previously used" },
    .{ .code = 0x40, .name = "Coarse Clock Adjustment Rejected but Will Try to Adjust Using Clock Dragging" },
    .{ .code = 0x41, .name = "Type0 Submap Not Defined" },
    .{ .code = 0x42, .name = "Unknown Advertising Identifier" },
    .{ .code = 0x43, .name = "Limit Reached" },
    .{ .code = 0x44, .name = "Operation Cancelled by Host" },
    .{ .code = 0x45, .name = "Packet Too Long" },
    .{ .code = 0x46, .name = "Too Late" },
    .{ .code = 0x47, .name = "Too Early" },
};

/// Name of a Status / error code, Vol 1 Part F §1.3 Table 1.1; `unknown` for
/// codes not listed there.
pub fn statusName(code: u8) []const u8 {
    for (status_table) |s| if (s.code == code) return s.name;
    return unknown;
}

const Named = struct { v: u16, name: []const u8 };

/// Assigned Numbers §2.1 "Core specification versions" (document dated
/// 2025-03-28), cut off at Core 5.4: a later value is `unknown` here.
const version_table = [_]Named{
    .{ .v = 0x00, .name = "1.0b" },
    .{ .v = 0x01, .name = "1.1" },
    .{ .v = 0x02, .name = "1.2" },
    .{ .v = 0x03, .name = "2.0+EDR" },
    .{ .v = 0x04, .name = "2.1+EDR" },
    .{ .v = 0x05, .name = "3.0+HS" },
    .{ .v = 0x06, .name = "4.0" },
    .{ .v = 0x07, .name = "4.1" },
    .{ .v = 0x08, .name = "4.2" },
    .{ .v = 0x09, .name = "5.0" },
    .{ .v = 0x0A, .name = "5.1" },
    .{ .v = 0x0B, .name = "5.2" },
    .{ .v = 0x0C, .name = "5.3" },
    .{ .v = 0x0D, .name = "5.4" },
};

/// The Company Identifiers this file can name, from Assigned Numbers §7.1
/// (document dated 2025-03-28). A deliberate subset; everything else is
/// `unknown` by value.
const company_table = [_]Named{
    .{ .v = 0x0000, .name = "Ericsson" },
    .{ .v = 0x0002, .name = "Intel" },
    .{ .v = 0x0006, .name = "Microsoft" },
    .{ .v = 0x000D, .name = "Texas Instruments" },
    .{ .v = 0x000F, .name = "Broadcom" },
    .{ .v = 0x02E5, .name = "Espressif" },
};

/// HCI_Version name (Vol 4 Part E §7.4.1, "see Assigned Numbers"). Read-only.
pub fn hciVersionName(v: u8) []const u8 {
    return versionName(v);
}

/// LMP_Version name (Vol 4 Part E §7.4.1, "see Assigned Numbers"). Read-only.
pub fn lmpVersionName(v: u8) []const u8 {
    return versionName(v);
}

fn versionName(v: u8) []const u8 {
    for (version_table) |e| if (e.v == v) return e.name;
    return unknown;
}

/// Company_Identifier name (Vol 4 Part E §7.4.1, "see Assigned Numbers").
/// Read-only.
pub fn companyName(v: u16) []const u8 {
    for (company_table) |e| if (e.v == v) return e.name;
    return unknown;
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

fn dep(f: u6, r: u6) Violation {
    return .{ .rule = .feature_dep_missing, .detail = (@as(u32, f) << 16) | r };
}

fn lmpRules(v: u64) ?Violation {
    // §3.3 Table 3.2 marks 24, 34, 50, 55, 59..62 "Reserved for future use".
    if (v & lmp_rfu != 0) return .{ .rule = .reserved_bit_set, .detail = lowBit(v & lmp_rfu) };
    if (v & (@as(u64, 1) << LMP_BREDR_NOT_SUPPORTED) != 0) {
        // §3.5.2 "Devices not supporting BR/EDR".
        const missing = lmp_mandatory_le_only & ~v;
        if (missing != 0) return .{ .rule = .feature_missing, .detail = lowBit(missing) };
        const extra = v & ~lmp_only_le_allowed;
        if (extra != 0) return .{ .rule = .feature_forbidden, .detail = lowBit(extra) };
        return null;
    }
    // §3.5.1 "Devices supporting BR/EDR".
    const missing = lmp_mandatory_bredr & ~v;
    if (missing != 0) return .{ .rule = .feature_missing, .detail = lowBit(missing) };
    // Table 3.7: Sniff mode (7) and Sniff subrating (41) go together.
    const sniff = (v >> LMP_SNIFF) & 1;
    const subrating = (v >> LMP_SNIFF_SUBRATING) & 1;
    if (sniff != subrating) {
        const set: u32 = if (sniff == 1) LMP_SNIFF else LMP_SNIFF_SUBRATING;
        const req: u32 = if (sniff == 1) LMP_SNIFF_SUBRATING else LMP_SNIFF;
        return .{ .rule = .combo_missing, .detail = (set << 16) | req };
    }
    for (lmp_deps) |d| {
        if ((v >> d.f) & 1 == 0) continue;
        for (d.all) |r| if ((v >> r) & 1 == 0) return dep(d.f, r);
        if (d.any.len != 0) {
            var ok = false;
            for (d.any) |r| ok = ok or (v >> r) & 1 == 1;
            if (!ok) return dep(d.f, d.any[0]);
        }
    }
    return null;
}

fn leFeatureRules(v: u64) ?Violation {
    // Table 4.7: 42, 45..55, 56..62 and all unlisted bits are reserved.
    if (v & le_rfu != 0) return .{ .rule = .reserved_bit_set, .detail = lowBit(v & le_rfu) };
    // After Table 4.7: "Bits 33 and 34 shall always have the same value."
    const b33: u32 = @intCast((v >> LE_PC_REQUEST_A) & 1);
    const b34: u32 = @intCast((v >> 34) & 1);
    if (b33 != b34) return .{ .rule = .features_mismatch, .detail = (b33 << 1) | b34 };
    for (le_deps) |d| {
        if ((v >> d.f) & 1 == 0) continue;
        for (d.any) |r| if ((v >> r) & 1 == 0) return dep(d.f, r);
    }
    return null;
}

fn leStateRules(v: u64) ?Violation {
    // §7.8.27: "All bits not listed in this table, and the value with all bits
    // set to 0, are reserved for future use."
    const defined: u64 = (@as(u64, 1) << 42) - 1;
    if (v & ~defined != 0) return .{ .rule = .reserved_bit_set, .detail = lowBit(v & ~defined) };
    if (v == 0) return .{ .rule = .value_out_of_range, .detail = 0 };
    var b: usize = 0;
    while (b < 42) : (b += 1) {
        if ((v >> @as(u6, @intCast(b))) & 1 == 0) continue;
        for ([2]u8{ implied.ini[b], implied.per[b] }) |req| {
            if (req == 0xFF) continue;
            if ((v >> @as(u6, @intCast(req))) & 1 == 0) {
                return .{ .rule = .combo_missing, .detail = (@as(u32, @intCast(b)) << 16) | req };
            }
        }
    }
    return null;
}

fn rangeRule(v: u16, lo: u16, hi: u16) ?Violation {
    if (inRange(v, lo, hi)) return null;
    return .{ .rule = .value_out_of_range, .detail = v };
}

fn dbmRule(p: i8) ?Violation {
    const lo: i8 = -127;
    const hi: i8 = 20;
    if (p >= lo and p <= hi) return null;
    return .{ .rule = .value_out_of_range, .detail = @bitCast(@as(i32, p)) };
}

fn leAclLenRule(len: u16) ?Violation {
    // §7.8.2: 0x0000 no dedicated LE buffer, 0x0001..0x001A reserved, 0x001B.. maximum.
    if (len >= 0x0001 and len <= 0x001A) return .{ .rule = .length_too_small, .detail = len };
    return null;
}

fn codecTransportRule(t: u8, entry: usize) ?Violation {
    // §7.4.8 [v2]: bits 0..3 defined, "All other bits: Reserved for future use".
    if (t & 0xF0 == 0) return null;
    return .{ .rule = .reserved_bit_set, .detail = (@as(u32, @intCast(entry)) << 8) | @as(u32, @ctz(t & 0xF0)) };
}

/// Field rules for a successfully parsed reply. `null` = conforms.
fn rules(c: Command, ret: []const u8, out: *const Readout) ?Violation {
    return switch (c.kind.?) {
        // §7.4.2: "Unsupported or undefined commands shall be set to 0."
        .supported_commands => if (firstRfuBit(&out.supported_commands, &rfu_supported_commands)) |b|
            .{ .rule = .reserved_bit_set, .detail = b }
        else
            null,
        .local_features => lmpRules(out.lmp_features),
        .ext_features => blk: {
            // §7.4.4: Page_Number returned is "the page number of the features returned".
            if (c.params.len != 0 and out.ext_page != c.params[0]) {
                break :blk .{ .rule = .echo_mismatch, .detail = (@as(u32, out.ext_page) << 8) | c.params[0] };
            }
            // Page 0x00 returns "the normal LMP features as returned by
            // Read_Local_Supported_Features", so the same rules apply.
            break :blk if (out.ext_page == 0) lmpRules(out.lmp_features) else null;
        },
        // §7.4.5 ranges: ACL length 0x0001..0xFFFF, ACL count 0x0001..0xFFFF,
        // synchronous length 0x01..0xFF (ignored by the Host when the count is 0).
        .buffer_size => rangeRule(out.acl_len, 0x0001, 0xFFFF) orelse
            rangeRule(out.num_acl, 0x0001, 0xFFFF) orelse
            (if (out.num_sco == 0) null else rangeRule(out.sco_len, 0x01, 0xFF)),
        .codecs_v1 => null,
        .codecs_v2 => blk: {
            const n: usize = ret[1];
            for (0..n) |i| {
                if (codecTransportRule(ret[2 + 2 * i + 1], i)) |v| break :blk v;
            }
            const m: usize = ret[2 + 2 * n];
            for (0..m) |k| {
                if (codecTransportRule(ret[2 + 2 * n + 1 + 5 * k + 4], n + k)) |v| break :blk v;
            }
            break :blk null;
        },
        .sp_options => blk: {
            // §7.4.9: "Bit 0 ... shall be set to 1"; other bits reserved.
            if (out.sp_options & 1 == 0) break :blk .{ .rule = .feature_missing, .detail = 0 };
            if (out.sp_options & 0xFE != 0) break :blk .{ .rule = .reserved_bit_set, .detail = @ctz(out.sp_options & 0xFE) };
            break :blk rangeRule(out.max_key_size, 0x07, 0x10);
        },
        // §7.6.1: 0x00..0x02 defined, "All other values: Reserved for future use".
        .loopback_mode => rangeRule(out.loopback_mode, 0x00, 0x02),
        .le_buffer_size_v1 => leAclLenRule(out.le_acl_len),
        .le_buffer_size_v2 => leAclLenRule(out.le_acl_len),
        .le_features => leFeatureRules(out.le_features),
        // §7.8.6: "Range: -127 to 20", dBm.
        .le_adv_tx_power => dbmRule(out.adv_tx_power),
        // §7.8.14: 0x00 "Reserved for future use".
        .le_fal_size => rangeRule(out.fal_size, 0x01, 0xFF),
        .le_states => leStateRules(out.le_states),
        // §7.8.34 ranges.
        .le_default_data_len => rangeRule(out.sugg_tx_octets, 0x001B, 0x00FB) orelse rangeRule(out.sugg_tx_time, 0x0148, 0x4290),
        .le_rsl_size => null, // "0xXX Number of entries": no range stated
        // §7.8.46 ranges.
        .le_max_data_len => rangeRule(out.max_tx_octets, 0x001B, 0x00FB) orelse
            rangeRule(out.max_tx_time, 0x0148, 0x4290) orelse
            rangeRule(out.max_rx_octets, 0x001B, 0x00FB) orelse
            rangeRule(out.max_rx_time, 0x0148, 0x4290),
        // §7.8.57: 0x001F..0x0672, "All other values: Reserved for future use".
        .le_max_adv_len => rangeRule(out.max_adv_len, 0x001F, 0x0672),
        // §7.8.58: 0x01..0xF0.
        .le_adv_sets => rangeRule(out.adv_sets, 0x01, 0xF0),
        // §7.8.73: 0x01..0xFF, 0x00 reserved.
        .le_pal_size => rangeRule(out.pal_size, 0x01, 0xFF),
        // §7.8.74: both "Range: -127 to +20", dBm.
        .le_tx_power => dbmRule(out.min_tx_power) orelse dbmRule(out.max_tx_power),
        // §7.8.75: -128.0 dB (0xFB00) to 128.0 dB (0x0500), signed, 0.1 dB units.
        .le_rf_comp => blk: {
            const lo: i16 = -1280;
            const hi: i16 = 1280;
            if (out.rf_tx < lo or out.rf_tx > hi) break :blk .{ .rule = .value_out_of_range, .detail = @as(u32, @bitCast(@as(i32, out.rf_tx))) & 0xFFFF };
            if (out.rf_rx < lo or out.rf_rx > hi) break :blk .{ .rule = .value_out_of_range, .detail = @as(u32, @bitCast(@as(i32, out.rf_rx))) & 0xFFFF };
            break :blk null;
        },
        // §7.8.87: rate bits 3..7 reserved; antennae 0x01..0x4B; switching
        // pattern length 0x02..0x4B; CTE length 0x02..0x14.
        .le_antenna => blk: {
            if (out.ant_rates & 0xF8 != 0) break :blk .{ .rule = .reserved_bit_set, .detail = @ctz(out.ant_rates & 0xF8) };
            break :blk rangeRule(out.antennae, 0x01, 0x4B) orelse
                rangeRule(out.switch_len, 0x02, 0x4B) orelse
                rangeRule(out.cte_len, 0x02, 0x14);
        },
        // No "shall" on the returned values: §7.4.1 (vendor-specific
        // subversions, "see Assigned Numbers" enums), §7.4.6 (0 means "no
        // Public Device Address"), §7.4.7 (no ranges), §7.4.8 (counts).
        .local_version, .bd_addr, .data_block_size => null,
    };
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// Writes one compact ASCII line for a successful reply into `buf`:
/// `<command name> ncmd=<n> <field>=<value> ...`. Bitmaps are summarised as
/// the number of set bits plus a reserved flag. If the line does not fit it is
/// truncated and the last octet is '~'. Returns the written slice.
pub fn describe(cmd: Command, r: Readout, buf: []u8) []const u8 {
    const c = resolve(cmd) orelse cmd;
    var w = Line{ .buf = buf };
    w.put(c.name);
    w.key("ncmd");
    w.uint(r.ncmd);
    if (c.kind) |k| switch (k) {
        .local_version => {
            w.key("hci");
            w.put(r.hci_version_name);
            w.key("lmp");
            w.put(r.lmp_version_name);
            w.key("co");
            w.put(r.company_name);
            w.key("hsub");
            w.hex(r.hci_subversion);
            w.key("lsub");
            w.hex(r.lmp_subversion);
        },
        .supported_commands => w.summary("bits", r.supported_cmd_count, r.supported_cmd_reserved),
        .local_features => w.summary("bits", r.lmp_feature_count, r.lmp_features & lmp_rfu != 0),
        .ext_features => {
            w.key("page");
            w.uint(r.ext_page);
            w.key("max");
            w.uint(r.ext_max_page);
            w.summary("bits", r.lmp_feature_count, r.ext_page == 0 and r.lmp_features & lmp_rfu != 0);
        },
        .buffer_size => {
            w.key("acl");
            w.uint(r.acl_len);
            w.key("nacl");
            w.uint(r.num_acl);
            w.key("nsco");
            w.uint(r.num_sco);
        },
        .bd_addr => {
            w.key("addr");
            for (r.bd_addr, 0..) |b, i| {
                if (i != 0) w.put(":");
                w.hex2(b);
            }
        },
        .data_block_size => {
            w.key("acl");
            w.uint(r.block_acl_len);
            w.key("blk");
            w.uint(r.block_len);
            w.key("n");
            w.uint(r.num_blocks);
        },
        .codecs_v1, .codecs_v2 => {
            w.key("std");
            w.uint(r.codec_std);
            w.key("vend");
            w.uint(r.codec_vendor);
        },
        .sp_options => {
            w.key("opts");
            w.uint(r.sp_options);
            w.key("keysize");
            w.uint(r.max_key_size);
        },
        .loopback_mode => {
            w.key("mode");
            w.put(switch (r.loopback_mode) {
                0 => "none",
                1 => "local",
                2 => "remote",
                else => unknown,
            });
        },
        .le_buffer_size_v1, .le_buffer_size_v2 => {
            w.key("acl");
            w.uint(r.le_acl_len);
            w.key("n");
            w.uint(r.le_num_acl);
            if (k == .le_buffer_size_v2) {
                w.key("iso");
                w.uint(r.iso_len);
                w.key("niso");
                w.uint(r.iso_num);
            }
        },
        .le_features => w.summary("bits", r.le_feature_count, r.le_features & le_rfu != 0),
        .le_adv_tx_power => {
            w.key("dBm");
            w.int(r.adv_tx_power);
        },
        .le_fal_size => w.keyUint("n", r.fal_size),
        .le_states => w.summary("bits", r.le_state_count, r.le_states >> 42 != 0),
        .le_default_data_len => {
            w.key("oct");
            w.uint(r.sugg_tx_octets);
            w.key("us");
            w.uint(r.sugg_tx_time);
        },
        .le_rsl_size => w.keyUint("n", r.rsl_size),
        .le_max_data_len => {
            w.key("txo");
            w.uint(r.max_tx_octets);
            w.key("txus");
            w.uint(r.max_tx_time);
            w.key("rxo");
            w.uint(r.max_rx_octets);
            w.key("rxus");
            w.uint(r.max_rx_time);
        },
        .le_max_adv_len => w.keyUint("len", r.max_adv_len),
        .le_adv_sets => w.keyUint("n", r.adv_sets),
        .le_pal_size => w.keyUint("n", r.pal_size),
        .le_tx_power => {
            w.key("min");
            w.int(r.min_tx_power);
            w.key("max");
            w.int(r.max_tx_power);
        },
        .le_rf_comp => {
            w.key("txdB");
            w.tenth(r.rf_tx);
            w.key("rxdB");
            w.tenth(r.rf_rx);
        },
        .le_antenna => {
            w.key("rates");
            w.hex2(r.ant_rates);
            w.key("ant");
            w.uint(r.antennae);
            w.key("sw");
            w.uint(r.switch_len);
            w.key("cte");
            w.uint(r.cte_len);
        },
    };
    var end = @min(w.n, buf.len);
    if (w.over and end != 0) {
        end = buf.len;
        buf[end - 1] = '~';
    }
    return buf[0..end];
}

const Line = struct {
    buf: []u8,
    n: usize = 0,
    over: bool = false,

    fn put(self: *Line, s: []const u8) void {
        for (s) |ch| {
            if (self.n < self.buf.len) {
                self.buf[self.n] = ch;
                self.n += 1;
            } else self.over = true;
        }
    }

    fn key(self: *Line, k: []const u8) void {
        self.put(" ");
        self.put(k);
        self.put("=");
    }

    fn keyUint(self: *Line, k: []const u8, v: anytype) void {
        self.key(k);
        self.uint(v);
    }

    fn uint(self: *Line, v: anytype) void {
        var tmp: [20]u8 = undefined;
        var a: u64 = @intCast(v);
        var i = tmp.len;
        while (true) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(a % 10));
            a /= 10;
            if (a == 0) break;
        }
        self.put(tmp[i..]);
    }

    fn int(self: *Line, v: anytype) void {
        const x: i64 = @intCast(v);
        if (x < 0) self.put("-");
        self.uint(@abs(x));
    }

    /// Value in units of 0.1 dB, printed as `d.d`.
    fn tenth(self: *Line, v: i16) void {
        if (v < 0) self.put("-");
        const a: u32 = @abs(v); // |v| <= 32768
        self.uint(a / 10);
        self.put(".");
        self.uint(a % 10);
    }

    fn hex(self: *Line, v: u16) void {
        const digits = "0123456789ABCDEF";
        var tmp: [4]u8 = undefined;
        tmp[0] = digits[(v >> 12) & 0xF];
        tmp[1] = digits[(v >> 8) & 0xF];
        tmp[2] = digits[(v >> 4) & 0xF];
        tmp[3] = digits[v & 0xF];
        self.put("0x");
        self.put(&tmp);
    }

    fn hex2(self: *Line, v: u8) void {
        const digits = "0123456789ABCDEF";
        var tmp: [2]u8 = undefined;
        tmp[0] = digits[v >> 4];
        tmp[1] = digits[v & 0xF];
        self.put(&tmp);
    }

    fn summary(self: *Line, k: []const u8, count: anytype, reserved: bool) void {
        self.key(k);
        self.uint(count);
        self.key("rfu");
        self.put(if (reserved) "1" else "0");
    }
};

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Frame = struct {
    buf: [96]u8 = @splat(0),
    len: usize = 0,

    fn sl(self: *const Frame) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Wraps `ret` (the return parameters, Status included) in a Command Complete
/// event of `opcode` with Num_HCI_Command_Packets = 1:
/// [0]=0x0E event code, [1]=plen (3 + ret.len), [2]=ncmd, [3..5]=opcode
/// little-endian, [5..]=ret. Vol 4 Part E §7.7.14.
fn cc(opcode: u16, ret: []const u8) Frame {
    var f: Frame = .{};
    f.buf[0] = evt_command_complete;
    f.buf[1] = @intCast(3 + ret.len);
    f.buf[2] = 1;
    f.buf[3] = @truncate(opcode);
    f.buf[4] = @truncate(opcode >> 8);
    @memcpy(f.buf[5 .. 5 + ret.len], ret);
    f.len = 5 + ret.len;
    return f;
}

/// Offset of the first return parameter (Status) inside an event frame.
const RET = 5;

/// A well-formed, rule-conforming return-parameter block for each command.
/// `b[0]` is always Status = 0x00; the other octets are listed per command.
fn goodRet(kind: Kind, b: *[80]u8) []const u8 {
    @memset(b, 0);
    var n: usize = retLen(kind) orelse 0;
    switch (kind) {
        // §7.4.1: HCI_Version=0x0D (5.4), HCI_Subversion=0x1234, LMP_Version=0x0D,
        // Company_Identifier=0x02E5 (Espressif), LMP_Subversion=0x5678.
        .local_version => {
            b[1] = 0x0D;
            b[2] = 0x34;
            b[3] = 0x12;
            b[4] = 0x0D;
            b[5] = 0xE5;
            b[6] = 0x02;
            b[7] = 0x78;
            b[8] = 0x56;
        },
        // §7.4.2: bit of every listed command set (octet*8+bit, §6.27) plus
        // HCI_Reset (octet 2 bit 2); no reserved bit.
        .supported_commands => {
            for (commands) |c| {
                if (c.supp_bit != no_supp_bit) b[1 + c.supp_bit / 8] |= @as(u8, 1) << @as(u3, @intCast(c.supp_bit % 8));
            }
            b[1 + 2] |= 1 << 2;
        },
        // §7.4.3: LMP_Features page 0 with bits 2 Encryption, 3 Slot offset,
        // 5 Role switch, 7 Sniff mode, 25 EDR ACL 2 Mb/s, 38 LE Supported,
        // 41 Sniff subrating, 51 SSP, 52 Encapsulated PDU.
        .local_features => put64(b[1..], good_lmp),
        // §7.4.4: Page_Number=0x00, Max_Page_Number=0x00, same features as above.
        .ext_features => put64(b[3..], good_lmp),
        // §7.4.5: ACL_Data_Packet_Length=0x03FD (1021), Synchronous_Data_Packet_Length=0x3C,
        // Total_Num_ACL_Data_Packets=0x000C, Total_Num_Synchronous_Data_Packets=0x0000.
        .buffer_size => {
            b[1] = 0xFD;
            b[2] = 0x03;
            b[3] = 0x3C;
            b[4] = 0x0C;
        },
        // §7.4.6: BD_ADDR 33:22:11:28:6F:24 (invented, little-endian NAP first).
        .bd_addr => @memcpy(b[1..7], &[_]u8{ 0x24, 0x6F, 0x28, 0x11, 0x22, 0x33 }),
        // §7.4.7: Max_ACL_Data_Packet_Length=0x03FD, Data_Block_Length=0x04D2,
        // Total_Num_Data_Blocks=0x000A.
        .data_block_size => {
            b[1] = 0xFD;
            b[2] = 0x03;
            b[3] = 0xD2;
            b[4] = 0x04;
            b[5] = 0x0A;
        },
        // §7.4.8 [v1]: 2 standard codecs (IDs 0x01, 0x02), 1 vendor codec
        // (company 0x1234, ID 0x0000).
        .codecs_v1 => {
            b[1] = 2;
            b[2] = 0x01;
            b[3] = 0x02;
            b[4] = 1;
            b[5] = 0x34;
            b[6] = 0x12;
            n = 9;
        },
        // §7.4.9: Simple_Pairing_Options bit 0 = 1, Max_Encryption_Key_Size = 0x10.
        .sp_options => {
            b[1] = 0x01;
            b[2] = 0x10;
        },
        // §7.4.8 [v2]: 2 standard codecs (0x01 on BR/EDR ACL, 0x02 on LE CIS),
        // 1 vendor codec (company 0x1234, ID 0x0000) on BR/EDR SCO.
        .codecs_v2 => {
            b[1] = 2;
            b[2] = 0x01;
            b[3] = 0x01;
            b[4] = 0x02;
            b[5] = 0x04;
            b[6] = 1;
            b[7] = 0x34;
            b[8] = 0x12;
            b[11] = 0x02;
            n = 12;
        },
        // §7.6.1: Loopback_Mode = 0x00 (no loopback).
        .loopback_mode => b[1] = 0x00,
        // §7.8.2 [v1]: LE_ACL_Data_Packet_Length=0x00FB, Total_Num_LE_ACL_Data_Packets=0x0A.
        .le_buffer_size_v1 => {
            b[1] = 0xFB;
            b[3] = 0x0A;
        },
        // §7.8.2 [v2]: same plus ISO_Data_Packet_Length=0x03F8, Total_Num_ISO_Data_Packets=0x08.
        .le_buffer_size_v2 => {
            b[1] = 0xFB;
            b[3] = 0x0A;
            b[4] = 0xF8;
            b[5] = 0x03;
            b[6] = 0x08;
        },
        // §7.8.3: LE_Features bits 0, 1, 2, 5, 8, 12, 13, 14, 33, 34.
        .le_features => put64(b[1..], good_le),
        // §7.8.6: TX_Power_Level = 0xF4 (-12 dBm).
        .le_adv_tx_power => b[1] = 0xF4,
        // §7.8.14: Filter_Accept_List_Size = 0x10.
        .le_fal_size => b[1] = 0x10,
        // §7.8.27: all 42 listed LE_States bits set; bits 42..63 clear.
        .le_states => {
            @memset(b[1..6], 0xFF);
            b[6] = 0x03;
        },
        // §7.8.34: Suggested_Max_TX_Octets=0x001B, Suggested_Max_TX_Time=0x0148.
        .le_default_data_len => {
            b[1] = 0x1B;
            b[3] = 0x48;
            b[4] = 0x01;
        },
        // §7.8.41: Resolving_List_Size = 0x05.
        .le_rsl_size => b[1] = 0x05,
        // §7.8.46: all four at their maximum: 0x00FB octets, 0x4290 us.
        .le_max_data_len => {
            b[1] = 0xFB;
            b[3] = 0x90;
            b[4] = 0x42;
            b[5] = 0xFB;
            b[7] = 0x90;
            b[8] = 0x42;
        },
        // §7.8.57: Max_Advertising_Data_Length = 0x0672.
        .le_max_adv_len => {
            b[1] = 0x72;
            b[2] = 0x06;
        },
        // §7.8.58: Num_Supported_Advertising_Sets = 0x0A.
        .le_adv_sets => b[1] = 0x0A,
        // §7.8.73: Periodic_Advertiser_List_Size = 0x08.
        .le_pal_size => b[1] = 0x08,
        // §7.8.74: Min_TX_Power = 0xEC (-20 dBm), Max_TX_Power = 0x0A (10 dBm).
        .le_tx_power => {
            b[1] = 0xEC;
            b[2] = 0x0A;
        },
        // §7.8.75: both compensation values 0x0000 (0.0 dB).
        .le_rf_comp => {},
        // §7.8.87: rates 0x03 (1 us switching and sampling), 2 antennae,
        // switching pattern length 2, max CTE length 16.
        .le_antenna => {
            b[1] = 0x03;
            b[2] = 0x02;
            b[3] = 0x02;
            b[4] = 0x10;
        },
    }
    return b[0..n];
}

const good_lmp: u64 = (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 25) | (1 << 38) | (1 << 41) | (1 << 51) | (1 << 52);
const good_le: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 5) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 14) | (1 << 33) | (1 << 34);

fn put64(b: []u8, v: u64) void {
    for (b[0..8], 0..) |*x, i| x.* = @truncate(v >> @as(u6, @intCast(8 * i)));
}

fn cmdOf(kind: Kind) Command {
    for (commands) |c| if (c.kind.? == kind) return c;
    unreachable;
}

fn expectFail(cmd: Command, evt: []const u8, rule: Rule, detail: u32) !void {
    const v = verify(cmd, evt);
    switch (v) {
        .fail => |f| {
            try testing.expectEqual(rule, f.rule);
            try testing.expectEqual(detail, f.detail);
        },
        else => return testing.expect(false),
    }
}

test "opcodes equal (ogf << 10) | ocf, are unique and sorted" {
    const ogf_ocf = [_][2]u16{
        .{ 0x04, 0x001 }, .{ 0x04, 0x002 }, .{ 0x04, 0x003 }, .{ 0x04, 0x004 }, .{ 0x04, 0x005 },
        .{ 0x04, 0x009 }, .{ 0x04, 0x00A }, .{ 0x04, 0x00B }, .{ 0x04, 0x00C }, .{ 0x04, 0x00D },
        .{ 0x06, 0x001 }, .{ 0x08, 0x002 }, .{ 0x08, 0x003 }, .{ 0x08, 0x007 }, .{ 0x08, 0x00F },
        .{ 0x08, 0x01C }, .{ 0x08, 0x023 }, .{ 0x08, 0x02A }, .{ 0x08, 0x02F }, .{ 0x08, 0x03A },
        .{ 0x08, 0x03B }, .{ 0x08, 0x04A }, .{ 0x08, 0x04B }, .{ 0x08, 0x04C }, .{ 0x08, 0x058 },
        .{ 0x08, 0x060 },
    };
    // Same opcodes as literals, cross-checked against NimBLE hci_common.h
    // (BLE_HCI_OCF_*): 0x0001..0x0005, 0x0009..0x000D (OGF 0x04) and the LE set.
    const literals = [_]u16{
        0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1009, 0x100A, 0x100B, 0x100C, 0x100D,
        0x1801, 0x2002, 0x2003, 0x2007, 0x200F, 0x201C, 0x2023, 0x202A, 0x202F, 0x203A,
        0x203B, 0x204A, 0x204B, 0x204C, 0x2058, 0x2060,
    };
    try testing.expectEqual(ogf_ocf.len, commands.len);
    for (commands, ogf_ocf, literals) |c, g, lit| {
        try testing.expectEqual((g[0] << 10) | g[1], c.opcode);
        try testing.expectEqual(lit, c.opcode);
    }
    for (commands, 0..) |c, i| {
        if (i == 0) continue;
        try testing.expect(commands[i - 1].opcode < c.opcode);
    }
}

test "positive: every command's well-formed reply verifies ok" {
    var buf: [80]u8 = undefined;
    for (commands) |c| {
        const f = cc(c.opcode, goodRet(c.kind.?, &buf));
        const v = verify(c, f.sl());
        if (v != .ok) std.debug.print("{s}: {any}\n", .{ c.name, v });
        try testing.expect(v == .ok);
        var r: Readout = .{};
        try testing.expect(decode(c, f.sl(), &r));
    }
}

test "positive: a three-field Command resolves its layout from the opcode" {
    var buf: [80]u8 = undefined;
    const f = cc(0x1001, goodRet(.local_version, &buf));
    const v = verify(.{ .name = "x", .opcode = 0x1001 }, f.sl());
    try testing.expect(v == .ok);
    try testing.expect(verify(.{ .name = "x", .opcode = 0xFFFF }, f.sl()) == .other_event);
}

test "positive: readout fields equal the constructed values" {
    var b: [80]u8 = undefined;
    var r: Readout = .{};

    r = .{};
    try testing.expect(decode(cmdOf(.local_version), cc(0x1001, goodRet(.local_version, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 1), r.ncmd);
    try testing.expectEqual(@as(u8, 0x0D), r.hci_version);
    try testing.expectEqualStrings("5.4", r.hci_version_name);
    try testing.expectEqual(@as(u16, 0x1234), r.hci_subversion);
    try testing.expectEqual(@as(u8, 0x0D), r.lmp_version);
    try testing.expectEqualStrings("5.4", r.lmp_version_name);
    try testing.expectEqual(@as(u16, 0x02E5), r.company_id);
    try testing.expectEqualStrings("Espressif", r.company_name);
    try testing.expectEqual(@as(u16, 0x5678), r.lmp_subversion);

    r = .{};
    try testing.expect(decode(cmdOf(.supported_commands), cc(0x1002, goodRet(.supported_commands, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, commands.len), r.supported_cmd_count);
    try testing.expect(!r.supported_cmd_reserved);
    for (commands) |c| try testing.expect(reportsSupport(&r.supported_commands, c));

    r = .{};
    try testing.expect(decode(cmdOf(.local_features), cc(0x1003, goodRet(.local_features, &b)).sl(), &r));
    try testing.expectEqual(good_lmp, r.lmp_features);
    try testing.expectEqual(@as(u8, 9), r.lmp_feature_count);

    r = .{};
    try testing.expect(decode(cmdOf(.ext_features), cc(0x1004, goodRet(.ext_features, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 0), r.ext_page);
    try testing.expectEqual(@as(u8, 0), r.ext_max_page);
    try testing.expectEqual(good_lmp, r.lmp_features);

    r = .{};
    try testing.expect(decode(cmdOf(.buffer_size), cc(0x1005, goodRet(.buffer_size, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x03FD), r.acl_len);
    try testing.expectEqual(@as(u8, 0x3C), r.sco_len);
    try testing.expectEqual(@as(u16, 0x000C), r.num_acl);
    try testing.expectEqual(@as(u16, 0), r.num_sco);

    r = .{};
    try testing.expect(decode(cmdOf(.bd_addr), cc(0x1009, goodRet(.bd_addr, &b)).sl(), &r));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x24, 0x6F, 0x28, 0x11, 0x22, 0x33 }, &r.bd_addr);

    r = .{};
    try testing.expect(decode(cmdOf(.data_block_size), cc(0x100A, goodRet(.data_block_size, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x03FD), r.block_acl_len);
    try testing.expectEqual(@as(u16, 0x04D2), r.block_len);
    try testing.expectEqual(@as(u16, 0x000A), r.num_blocks);

    r = .{};
    try testing.expect(decode(cmdOf(.codecs_v1), cc(0x100B, goodRet(.codecs_v1, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 2), r.codec_std);
    try testing.expectEqual(@as(u8, 1), r.codec_vendor);

    r = .{};
    try testing.expect(decode(cmdOf(.codecs_v2), cc(0x100D, goodRet(.codecs_v2, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 2), r.codec_std);
    try testing.expectEqual(@as(u8, 1), r.codec_vendor);

    r = .{};
    try testing.expect(decode(cmdOf(.sp_options), cc(0x100C, goodRet(.sp_options, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 0x01), r.sp_options);
    try testing.expectEqual(@as(u8, 0x10), r.max_key_size);

    r = .{};
    try testing.expect(decode(cmdOf(.loopback_mode), cc(0x1801, goodRet(.loopback_mode, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 0), r.loopback_mode);

    r = .{};
    try testing.expect(decode(cmdOf(.le_buffer_size_v1), cc(0x2002, goodRet(.le_buffer_size_v1, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x00FB), r.le_acl_len);
    try testing.expectEqual(@as(u8, 0x0A), r.le_num_acl);

    r = .{};
    try testing.expect(decode(cmdOf(.le_buffer_size_v2), cc(0x2060, goodRet(.le_buffer_size_v2, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x00FB), r.le_acl_len);
    try testing.expectEqual(@as(u8, 0x0A), r.le_num_acl);
    try testing.expectEqual(@as(u16, 0x03F8), r.iso_len);
    try testing.expectEqual(@as(u8, 0x08), r.iso_num);

    r = .{};
    try testing.expect(decode(cmdOf(.le_features), cc(0x2003, goodRet(.le_features, &b)).sl(), &r));
    try testing.expectEqual(good_le, r.le_features);
    try testing.expectEqual(@as(u8, 10), r.le_feature_count);

    r = .{};
    try testing.expect(decode(cmdOf(.le_adv_tx_power), cc(0x2007, goodRet(.le_adv_tx_power, &b)).sl(), &r));
    try testing.expectEqual(@as(i8, -12), r.adv_tx_power);

    r = .{};
    try testing.expect(decode(cmdOf(.le_fal_size), cc(0x200F, goodRet(.le_fal_size, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 0x10), r.fal_size);

    r = .{};
    try testing.expect(decode(cmdOf(.le_states), cc(0x201C, goodRet(.le_states, &b)).sl(), &r));
    try testing.expectEqual(@as(u64, 0x3FF_FFFF_FFFF), r.le_states);
    try testing.expectEqual(@as(u8, 42), r.le_state_count);

    r = .{};
    try testing.expect(decode(cmdOf(.le_default_data_len), cc(0x2023, goodRet(.le_default_data_len, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x001B), r.sugg_tx_octets);
    try testing.expectEqual(@as(u16, 0x0148), r.sugg_tx_time);

    r = .{};
    try testing.expect(decode(cmdOf(.le_rsl_size), cc(0x202A, goodRet(.le_rsl_size, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 5), r.rsl_size);

    r = .{};
    try testing.expect(decode(cmdOf(.le_max_data_len), cc(0x202F, goodRet(.le_max_data_len, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x00FB), r.max_tx_octets);
    try testing.expectEqual(@as(u16, 0x4290), r.max_tx_time);
    try testing.expectEqual(@as(u16, 0x00FB), r.max_rx_octets);
    try testing.expectEqual(@as(u16, 0x4290), r.max_rx_time);

    r = .{};
    try testing.expect(decode(cmdOf(.le_max_adv_len), cc(0x203A, goodRet(.le_max_adv_len, &b)).sl(), &r));
    try testing.expectEqual(@as(u16, 0x0672), r.max_adv_len);

    r = .{};
    try testing.expect(decode(cmdOf(.le_adv_sets), cc(0x203B, goodRet(.le_adv_sets, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 0x0A), r.adv_sets);

    r = .{};
    try testing.expect(decode(cmdOf(.le_pal_size), cc(0x204A, goodRet(.le_pal_size, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 8), r.pal_size);

    r = .{};
    try testing.expect(decode(cmdOf(.le_tx_power), cc(0x204B, goodRet(.le_tx_power, &b)).sl(), &r));
    try testing.expectEqual(@as(i8, -20), r.min_tx_power);
    try testing.expectEqual(@as(i8, 10), r.max_tx_power);

    r = .{};
    try testing.expect(decode(cmdOf(.le_rf_comp), cc(0x204C, goodRet(.le_rf_comp, &b)).sl(), &r));
    try testing.expectEqual(@as(i16, 0), r.rf_tx);
    try testing.expectEqual(@as(i16, 0), r.rf_rx);

    r = .{};
    try testing.expect(decode(cmdOf(.le_antenna), cc(0x2058, goodRet(.le_antenna, &b)).sl(), &r));
    try testing.expectEqual(@as(u8, 0x03), r.ant_rates);
    try testing.expectEqual(@as(u8, 2), r.antennae);
    try testing.expectEqual(@as(u8, 2), r.switch_len);
    try testing.expectEqual(@as(u8, 0x10), r.cte_len);
}

test "edge values inside the ranges verify ok" {
    var b: [80]u8 = undefined;
    // §7.8.2: 0x0000 = "No dedicated LE Buffer exists"; 0x001B is the first legal maximum.
    for ([_]u16{ 0x0000, 0x001B, 0xFFFF }) |len| {
        b[0] = 0;
        put16(b[1..], len);
        b[3] = 0;
        const f = cc(0x2002, b[0..4]);
        try testing.expect(verify(cmdOf(.le_buffer_size_v1), f.sl()) == .ok);
    }
    // §7.4.5: no SCO (count 0) leaves Synchronous_Data_Packet_Length unchecked.
    b[0] = 0;
    b[1] = 0x01;
    b[2] = 0x00;
    b[3] = 0x00;
    b[4] = 0x01;
    b[5] = 0x00;
    b[6] = 0x00;
    b[7] = 0x00;
    try testing.expect(verify(cmdOf(.buffer_size), cc(0x1005, b[0..8]).sl()) == .ok);
    // §7.8.6 / §7.8.74: range endpoints -127 and 20.
    b[0] = 0;
    b[1] = 0x81;
    try testing.expect(verify(cmdOf(.le_adv_tx_power), cc(0x2007, b[0..2]).sl()) == .ok);
    b[1] = 0x14;
    try testing.expect(verify(cmdOf(.le_adv_tx_power), cc(0x2007, b[0..2]).sl()) == .ok);
    // §7.8.75: 0xFB00 = -128.0 dB, 0x0500 = +128.0 dB.
    b[1] = 0x00;
    b[2] = 0xFB;
    b[3] = 0x00;
    b[4] = 0x05;
    try testing.expect(verify(cmdOf(.le_rf_comp), cc(0x204C, b[0..5]).sl()) == .ok);
    // §7.8.14: Filter_Accept_List_Size 0xFF.
    b[1] = 0xFF;
    try testing.expect(verify(cmdOf(.le_fal_size), cc(0x200F, b[0..2]).sl()) == .ok);
}

fn put16(dst: []u8, v: u16) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
}

test "negative: verify reports any non-zero Status with the Status value" {
    // `verify` judges the frame alone and does not know Table 3.1: 0x01 is a
    // violation for every command here, although for an excluded command it
    // is the conforming answer (`verifyDeclared` returns `.not_supported`).
    var b: [80]u8 = undefined;
    for (commands) |c| {
        var f = cc(c.opcode, goodRet(c.kind.?, &b));
        f.buf[RET] = 0x01; // Unknown HCI Command, Vol 1 Part F §1.3
        try expectFail(c, f.sl(), .status_nonzero, 0x01);
        f.buf[RET] = 0x12; // Invalid HCI Command Parameters
        try expectFail(c, f.sl(), .status_nonzero, 0x12);
    }
    // §4.5: a failed command's return parameters may be shorter; only Status is judged.
    const f = cc(0x1001, &[_]u8{0x01});
    try expectFail(cmdOf(.local_version), f.sl(), .status_nonzero, 0x01);
}

test "status names follow Vol 1 Part F Table 1.1" {
    try testing.expectEqualStrings("Unknown HCI Command", statusName(0x01));
    try testing.expectEqualStrings("Invalid HCI Command Parameters", statusName(0x12));
    try testing.expectEqualStrings("Reserved for future use", statusName(0x2B));
    try testing.expectEqualStrings("Too Early", statusName(0x47));
    try testing.expectEqualStrings("unknown", statusName(0x48));
}

test "negative: opcode mismatch and foreign events are other_event" {
    var b: [80]u8 = undefined;
    const cmd = cmdOf(.local_version);
    // Another command's Command Complete.
    try testing.expect(verify(cmd, cc(0x1003, goodRet(.local_features, &b)).sl()) == .other_event);
    // Opcode 0x0000: "No associated command" (§7.7.14).
    try testing.expect(verify(cmd, cc(0x0000, goodRet(.local_version, &b)).sl()) == .other_event);
    // Command Status (§7.7.15, event 0x0F) for our opcode: Status, ncmd, opcode.
    var f = cc(0x1001, &[_]u8{ 0x00, 0x01, 0x01, 0x10 });
    f.buf[0] = 0x0F;
    f.buf[1] = 4;
    try testing.expect(verify(cmd, f.sl()) == .other_event);
    // Number of Completed Packets (§7.7.19, event 0x13): one handle, one count.
    const nocp = [_]u8{ 0x13, 0x04, 0x01, 0x00, 0x02, 0x00 };
    try testing.expect(verify(cmd, &nocp) == .other_event);
    // Hardware Error (§7.7.16, event 0x10).
    const hwErr = [_]u8{ 0x10, 0x01, 0x01 };
    try testing.expect(verify(cmd, &hwErr) == .other_event);
}

test "negative: plen disagreeing with the frame length is other_event" {
    var b: [80]u8 = undefined;
    for (commands) |c| {
        const good = cc(c.opcode, goodRet(c.kind.?, &b));
        var f = good;
        f.buf[1] -= 1; // plen one less than the parameters present
        try testing.expect(verify(c, f.sl()) == .other_event);
        f = good;
        f.buf[1] += 1; // plen claims an octet that is not there
        try testing.expect(verify(c, f.sl()) == .other_event);
        f = good;
        f.len -= 1; // truncated frame
        try testing.expect(verify(c, f.sl()) == .other_event);
        try testing.expect(verify(c, good.buf[0..1]) == .other_event);
        try testing.expect(verify(c, &.{}) == .other_event);
        // Unattributable: Command Complete shorter than its own opcode field.
        f = good;
        f.buf[1] = 2;
        f.len = 4;
        try testing.expect(verify(c, f.sl()) == .other_event);
    }
}

test "negative: return parameter length not equal to the specification" {
    var b: [80]u8 = undefined;
    for (commands) |c| {
        const k = c.kind.?;
        if (retLen(k) == null) continue;
        const want: u32 = retLen(k).?;
        const good = cc(c.opcode, goodRet(k, &b));
        // Trailing octet: §7.7.14 defines Return_Parameters for the one
        // command named by Command_Opcode only.
        var f = good;
        f.buf[1] += 1;
        f.buf[f.len] = 0x00;
        f.len += 1;
        try expectFail(c, f.sl(), .bad_param_len, ((want + 1) << 16) | want);
        // One octet short.
        f = good;
        f.buf[1] -= 1;
        f.len -= 1;
        try expectFail(c, f.sl(), .bad_param_len, ((want - 1) << 16) | want);
        // Status missing altogether.
        f = good;
        f.buf[1] = 3;
        f.len = 5;
        try expectFail(c, f.sl(), .bad_param_len, want);
        // decode() refuses the same frames.
        var r: Readout = .{};
        f = good;
        f.buf[1] += 1;
        f.len += 1;
        try testing.expect(!decode(c, f.sl(), &r));
    }
}

test "negative: codec lists whose octet counts do not add up" {
    var b: [80]u8 = undefined;
    const v1 = [_]u8{ 0x00, 0x02, 0x01, 0x02, 0x01, 0x34, 0x12, 0x00, 0x00 }; // 2 + 2 + 1 + 4
    var r: Readout = .{};
    try testing.expect(!decode(cmdOf(.codecs_v1), cc(0x100B, v1[0..8]).sl(), &r));
    try expectFail(cmdOf(.codecs_v1), cc(0x100B, v1[0..8]).sl(), .bad_param_len, (8 << 16) | 9);
    try expectFail(cmdOf(.codecs_v1), cc(0x100B, v1[0..5]).sl(), .bad_param_len, (5 << 16) | 9);
    try expectFail(cmdOf(.codecs_v1), cc(0x100B, v1[0..1]).sl(), .bad_param_len, (1 << 16) | 0xFFFF);
    const v2 = goodRet(.codecs_v2, &b);
    try expectFail(cmdOf(.codecs_v2), cc(0x100D, v2[0..11]).sl(), .bad_param_len, (11 << 16) | 12);
    // §7.4.8 [v2]: transport bits 4..7 reserved. Standard entry 1 (octet 5), vendor entry 0 (octet 11).
    b[5] |= 0x10;
    try expectFail(cmdOf(.codecs_v2), cc(0x100D, b[0..12]).sl(), .reserved_bit_set, (1 << 8) | 4);
    b[5] = 0x04;
    b[11] = 0x80;
    try expectFail(cmdOf(.codecs_v2), cc(0x100D, b[0..12]).sl(), .reserved_bit_set, (2 << 8) | 7);
    // [v1] has no transport octets.
    b[1] = 0; // Num_Supported_Standard_Codecs = 0
    b[2] = 0; // Num_Supported_Vendor_Specific_Codecs = 0
    // Both count octets are mandatory even when they are zero.
    try expectFail(cmdOf(.codecs_v2), cc(0x100D, b[0..2]).sl(), .bad_param_len, (2 << 16) | 0xFFFF);
    try expectFail(cmdOf(.codecs_v1), cc(0x100B, b[0..2]).sl(), .bad_param_len, (2 << 16) | 0xFFFF);
    try testing.expect(verify(cmdOf(.codecs_v2), cc(0x100D, b[0..3]).sl()) == .ok);
    try testing.expect(verify(cmdOf(.codecs_v1), cc(0x100B, b[0..3]).sl()) == .ok);
}

fn feat(cmd: Command, v: u64) Frame {
    var b: [80]u8 = undefined;
    _ = goodRet(.local_features, &b);
    put64(b[1..], v);
    return cc(cmd.opcode, b[0..9]);
}

test "LMP_Features: reserved bits shall be zero (Vol 2 Part C Table 3.2)" {
    const cmd = cmdOf(.local_features);
    for ([_]u6{ 24, 34, 50, 55, 59, 60, 61, 62 }) |bitIdx| {
        try expectFail(cmd, feat(cmd, good_lmp | (@as(u64, 1) << bitIdx)).sl(), .reserved_bit_set, bitIdx);
    }
    try testing.expect(verify(cmd, feat(cmd, good_lmp).sl()) == .ok);
}

test "LMP_Features: BR/EDR device mandatory, paired and required features (Vol 2 Part C 3.5.1)" {
    const cmd = cmdOf(.local_features);
    // Table 3.5: Encryption (2), SSP (51), Encapsulated PDU (52) shall be set.
    try expectFail(cmd, feat(cmd, good_lmp & ~(@as(u64, 1) << 51)).sl(), .feature_missing, 51);
    try expectFail(cmd, feat(cmd, good_lmp & ~(@as(u64, 1) << 52)).sl(), .feature_missing, 52);
    try expectFail(cmd, feat(cmd, good_lmp & ~(@as(u64, 1) << 2)).sl(), .feature_missing, 2);
    // Table 3.7: Sniff mode (7) and Sniff subrating (41) together.
    try expectFail(cmd, feat(cmd, good_lmp & ~(@as(u64, 1) << 7)).sl(), .combo_missing, (41 << 16) | 7);
    try expectFail(cmd, feat(cmd, good_lmp & ~(@as(u64, 1) << 41)).sl(), .combo_missing, (7 << 16) | 41);
    // Table 3.9: HV2 packets (12) requires SCO link (11) or Extended SCO link (31).
    try expectFail(cmd, feat(cmd, good_lmp | (@as(u64, 1) << 12)).sl(), .feature_dep_missing, (12 << 16) | 11);
    // Table 3.9: EDR ACL 3 Mb/s (26) requires EDR ACL 2 Mb/s (25).
    try expectFail(cmd, feat(cmd, (good_lmp & ~(@as(u64, 1) << 25)) | (@as(u64, 1) << 26)).sl(), .feature_dep_missing, (26 << 16) | 25);
    // Enhanced power control (58) requires both power control requests (9) and power control (18).
    try expectFail(cmd, feat(cmd, good_lmp | (@as(u64, 1) << 58) | (@as(u64, 1) << 9)).sl(), .feature_dep_missing, (58 << 16) | 18);
    try testing.expect(verify(cmd, feat(cmd, good_lmp | (@as(u64, 1) << 58) | (@as(u64, 1) << 9) | (@as(u64, 1) << 18)).sl()) == .ok);
}

test "LMP_Features: LE-only device (Vol 2 Part C 3.5.2)" {
    const cmd = cmdOf(.local_features);
    const le_only: u64 = (1 << 37) | (1 << 38) | (1 << 63);
    try testing.expect(verify(cmd, feat(cmd, le_only).sl()) == .ok);
    try expectFail(cmd, feat(cmd, (1 << 37)).sl(), .feature_missing, 38);
    try expectFail(cmd, feat(cmd, le_only | (@as(u64, 1) << 5)).sl(), .feature_forbidden, 5);
}

test "Read_Local_Extended_Features: page 0 follows LMP rules and echoes the page" {
    const cmd = cmdOf(.ext_features);
    var b: [80]u8 = undefined;
    _ = goodRet(.ext_features, &b);
    put64(b[3..], good_lmp | (@as(u64, 1) << 24));
    try expectFail(cmd, cc(cmd.opcode, b[0..11]).sl(), .reserved_bit_set, 24);
    _ = goodRet(.ext_features, &b);
    put64(b[3..], good_lmp & ~(@as(u64, 1) << 2));
    try expectFail(cmd, cc(cmd.opcode, b[0..11]).sl(), .feature_missing, 2);
    _ = goodRet(.ext_features, &b);
    b[1] = 0x01; // returned page 1 although page 0 was requested
    try expectFail(cmd, cc(cmd.opcode, b[0..11]).sl(), .echo_mismatch, (1 << 8) | 0);
    // Page 1 has no page-0 rules; Max_Page_Number is informational.
    b[1] = 0x01;
    b[2] = 0x01;
    try testing.expect(verify(.{ .name = cmd.name, .opcode = cmd.opcode, .kind = .ext_features, .params = &.{0x01} }, cc(cmd.opcode, b[0..11]).sl()) == .ok);
}

test "Supported_Commands: reserved bits shall be zero (Vol 4 Part E 6.27, 7.4.2)" {
    const cmd = cmdOf(.supported_commands);
    var b: [80]u8 = undefined;
    _ = goodRet(.supported_commands, &b);
    b[1 + 116 / 8] |= 1 << 4;
    try expectFail(cmd, cc(cmd.opcode, b[0..65]).sl(), .reserved_bit_set, 116);
    _ = goodRet(.supported_commands, &b);
    b[1 + 26 / 8] |= 1 << 2;
    try expectFail(cmd, cc(cmd.opcode, b[0..65]).sl(), .reserved_bit_set, 26);
    _ = goodRet(.supported_commands, &b);
    b[1 + 48] |= 1;
    try expectFail(cmd, cc(cmd.opcode, b[0..65]).sl(), .reserved_bit_set, 384);
    // A "Previously used" bit (bit 6) is not a rule hit.
    _ = goodRet(.supported_commands, &b);
    b[1] |= 1 << 6;
    try testing.expect(verify(cmd, cc(cmd.opcode, b[0..65]).sl()) == .ok);
    // reportsSupport
    _ = goodRet(.supported_commands, &b);
    b[1 + 202 / 8] &= ~@as(u8, 1 << 2);
    var r: Readout = .{};
    try testing.expect(decode(cmd, cc(cmd.opcode, b[0..65]).sl(), &r));
    try testing.expect(!reportsSupport(&r.supported_commands, cmdOf(.le_features)));
    try testing.expect(reportsSupport(&r.supported_commands, cmdOf(.le_fal_size)));
    try testing.expect(reportsSupport(&r.supported_commands, cmd));
}

test "Read_Buffer_Size ranges (Vol 4 Part E 7.4.5)" {
    const cmd = cmdOf(.buffer_size);
    var b: [80]u8 = undefined;
    var base: [8]u8 = undefined;
    @memcpy(&base, goodRet(.buffer_size, &b)[0..8]);
    // ACL_Data_Packet_Length = 0x0000 is below its range 0x0001..0xFFFF.
    b[0..8].* = base;
    b[1] = 0x00;
    b[2] = 0x00;
    try expectFail(cmd, cc(cmd.opcode, b[0..8]).sl(), .value_out_of_range, 0);
    // Total_Num_ACL_Data_Packets = 0x0000 is below its range.
    b[0..8].* = base;
    b[4] = 0x00;
    try expectFail(cmd, cc(cmd.opcode, b[0..8]).sl(), .value_out_of_range, 0);
    // Synchronous_Data_Packet_Length = 0 is only a violation when SCO is offered.
    b[0..8].* = base;
    b[3] = 0x00;
    b[7] = 0x01; // Total_Num_Synchronous_Data_Packets = 0x0100
    try expectFail(cmd, cc(cmd.opcode, b[0..8]).sl(), .value_out_of_range, 0);
}

fn le(cmd: Command, ret: []const u8) Frame {
    return cc(cmd.opcode, ret);
}

test "LE values outside their ranges" {
    var b: [16]u8 = @splat(0);

    // §7.8.2: LE_ACL_Data_Packet_Length 0x0001..0x001A is reserved.
    for ([_]u16{ 0x0001, 0x001A }) |len| {
        put16(b[1..], len);
        try expectFail(cmdOf(.le_buffer_size_v1), le(cmdOf(.le_buffer_size_v1), b[0..4]).sl(), .length_too_small, len);
        try expectFail(cmdOf(.le_buffer_size_v2), le(cmdOf(.le_buffer_size_v2), b[0..7]).sl(), .length_too_small, len);
    }
    // §7.8.6: 21 dBm is above the range -127..20.
    b = @splat(0);
    b[1] = 21;
    try expectFail(cmdOf(.le_adv_tx_power), le(cmdOf(.le_adv_tx_power), b[0..2]).sl(), .value_out_of_range, 21);
    b[1] = 0x80; // -128
    try expectFail(cmdOf(.le_adv_tx_power), le(cmdOf(.le_adv_tx_power), b[0..2]).sl(), .value_out_of_range, 0xFFFFFF80);
    // §7.8.14: Filter_Accept_List_Size 0x00 is reserved.
    b[1] = 0x00;
    try expectFail(cmdOf(.le_fal_size), le(cmdOf(.le_fal_size), b[0..2]).sl(), .value_out_of_range, 0);
    // §7.8.34: Suggested_Max_TX_Octets 0x001A and 0x00FC.
    b = @splat(0);
    b[1] = 0x1A;
    try expectFail(cmdOf(.le_default_data_len), le(cmdOf(.le_default_data_len), b[0..5]).sl(), .value_out_of_range, 0x1A);
    put16(b[1..], 0x00FC);
    try expectFail(cmdOf(.le_default_data_len), le(cmdOf(.le_default_data_len), b[0..5]).sl(), .value_out_of_range, 0xFC);
    // §7.8.34: Suggested_Max_TX_Time 0x0147 and 0x4291.
    b = @splat(0);
    b[1] = 0x1B;
    b[3] = 0x47;
    b[4] = 0x01;
    try expectFail(cmdOf(.le_default_data_len), le(cmdOf(.le_default_data_len), b[0..5]).sl(), .value_out_of_range, 0x147);
    b[3] = 0x91;
    b[4] = 0x42;
    try expectFail(cmdOf(.le_default_data_len), le(cmdOf(.le_default_data_len), b[0..5]).sl(), .value_out_of_range, 0x4291);
    // §7.8.46: each of the four parameters at 0x001A.
    for (0..4) |i| {
        b = @splat(0);
        for (0..4) |j| put16(b[1 + 2 * j ..], if (j % 2 == 0) 0x00FB else 0x4290);
        put16(b[1 + 2 * i ..], 0x001A);
        try expectFail(cmdOf(.le_max_data_len), le(cmdOf(.le_max_data_len), b[0..9]).sl(), .value_out_of_range, 0x1A);
    }
    // §7.8.57: 0x001E and 0x0673.
    b = @splat(0);
    put16(b[1..], 0x001E);
    try expectFail(cmdOf(.le_max_adv_len), le(cmdOf(.le_max_adv_len), b[0..3]).sl(), .value_out_of_range, 0x1E);
    put16(b[1..], 0x0673);
    try expectFail(cmdOf(.le_max_adv_len), le(cmdOf(.le_max_adv_len), b[0..3]).sl(), .value_out_of_range, 0x673);
    // §7.8.58: 0x00 and 0xF1.
    b = @splat(0);
    try expectFail(cmdOf(.le_adv_sets), le(cmdOf(.le_adv_sets), b[0..2]).sl(), .value_out_of_range, 0);
    b[1] = 0xF1;
    try expectFail(cmdOf(.le_adv_sets), le(cmdOf(.le_adv_sets), b[0..2]).sl(), .value_out_of_range, 0xF1);
    // §7.8.73: 0x00.
    b = @splat(0);
    try expectFail(cmdOf(.le_pal_size), le(cmdOf(.le_pal_size), b[0..2]).sl(), .value_out_of_range, 0);
    // §7.8.74: Min_TX_Power -128, Max_TX_Power 21.
    b = @splat(0);
    b[1] = 0x80;
    try expectFail(cmdOf(.le_tx_power), le(cmdOf(.le_tx_power), b[0..3]).sl(), .value_out_of_range, 0xFFFFFF80);
    b = @splat(0);
    b[2] = 21;
    try expectFail(cmdOf(.le_tx_power), le(cmdOf(.le_tx_power), b[0..3]).sl(), .value_out_of_range, 21);
    // §7.8.75: 0xFAFF = -128.1 dB and 0x0501 = 128.1 dB.
    b = @splat(0);
    b[1] = 0xFF;
    b[2] = 0xFA;
    try expectFail(cmdOf(.le_rf_comp), le(cmdOf(.le_rf_comp), b[0..5]).sl(), .value_out_of_range, 0xFAFF);
    b = @splat(0);
    b[3] = 0x01;
    b[4] = 0x05;
    try expectFail(cmdOf(.le_rf_comp), le(cmdOf(.le_rf_comp), b[0..5]).sl(), .value_out_of_range, 0x0501);
    // §7.8.87.
    b = @splat(0);
    b[1] = 0x08;
    try expectFail(cmdOf(.le_antenna), le(cmdOf(.le_antenna), b[0..5]).sl(), .reserved_bit_set, 3);
    b = @splat(0);
    b[1] = 0x80;
    try expectFail(cmdOf(.le_antenna), le(cmdOf(.le_antenna), b[0..5]).sl(), .reserved_bit_set, 7);
    b = @splat(0);
    b[2] = 0x4C;
    try expectFail(cmdOf(.le_antenna), le(cmdOf(.le_antenna), b[0..5]).sl(), .value_out_of_range, 0x4C);
    b = @splat(0);
    b[2] = 0x02; // Num_Antennae is checked first: keep it inside 0x01..0x4B
    b[3] = 0x01;
    try expectFail(cmdOf(.le_antenna), le(cmdOf(.le_antenna), b[0..5]).sl(), .value_out_of_range, 1);
    b = @splat(0);
    b[2] = 0x02;
    b[3] = 0x02;
    b[4] = 0x15;
    try expectFail(cmdOf(.le_antenna), le(cmdOf(.le_antenna), b[0..5]).sl(), .value_out_of_range, 0x15);
    // §7.4.9 and §7.6.1.
    b = @splat(0);
    b[2] = 0x10;
    try expectFail(cmdOf(.sp_options), le(cmdOf(.sp_options), b[0..3]).sl(), .feature_missing, 0);
    b = @splat(0);
    b[1] = 0x81;
    try expectFail(cmdOf(.sp_options), le(cmdOf(.sp_options), b[0..3]).sl(), .reserved_bit_set, 7);
    b = @splat(0);
    b[1] = 0x01;
    b[2] = 0x06;
    try expectFail(cmdOf(.sp_options), le(cmdOf(.sp_options), b[0..3]).sl(), .value_out_of_range, 6);
    b[2] = 0x11;
    try expectFail(cmdOf(.sp_options), le(cmdOf(.sp_options), b[0..3]).sl(), .value_out_of_range, 0x11);
    b = @splat(0);
    b[1] = 0x03;
    try expectFail(cmdOf(.loopback_mode), le(cmdOf(.loopback_mode), b[0..2]).sl(), .value_out_of_range, 3);
}

test "LE_Features: reserved bits, 33/34 equality and required features" {
    const cmd = cmdOf(.le_features);
    var b: [80]u8 = undefined;
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le | (@as(u64, 1) << 42));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .reserved_bit_set, 42);
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le | (@as(u64, 1) << 63));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .reserved_bit_set, 63);
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le & ~(@as(u64, 1) << 34));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .features_mismatch, 0b10);
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le & ~(@as(u64, 1) << 33));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .features_mismatch, 0b01);
    // §4.6.2: Connection Parameters Request (1) requires Extended Reject Indication (2).
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le & ~(@as(u64, 1) << 2) & ~(@as(u64, 1) << 1));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .feature_dep_missing, (8 << 16) | 2);
    // §4.6.13: LE Periodic Advertising (13) requires LE Extended Advertising (12) and CSA #2 (14).
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le & ~(@as(u64, 1) << 12));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .feature_dep_missing, (13 << 16) | 12);
    _ = goodRet(.le_features, &b);
    put64(b[1..], good_le & ~(@as(u64, 1) << 14));
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .feature_dep_missing, (13 << 16) | 14);
    // No features at all is a valid, if minimal, controller.
    _ = goodRet(.le_features, &b);
    put64(b[1..], 0);
    try testing.expect(verify(cmd, cc(cmd.opcode, b[0..9]).sl()) == .ok);
}

test "LE_States: reserved bits, all-zero and required combinations" {
    const cmd = cmdOf(.le_states);
    var b: [80]u8 = undefined;
    _ = goodRet(.le_states, &b);
    b[6] |= 0x04; // bit 42
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .reserved_bit_set, 42);
    _ = goodRet(.le_states, &b);
    b[8] |= 0x80; // bit 63
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .reserved_bit_set, 63);
    _ = goodRet(.le_states, &b);
    @memset(b[1..9], 0);
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .value_out_of_range, 0);
    // Table 1.1: initiating + non-connectable advertising (16) requires
    // central connection + non-connectable advertising (18).
    _ = goodRet(.le_states, &b);
    b[1 + 2] = 0xFB; // clears bit 18
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .combo_missing, (16 << 16) | 18);
    // Connectable+scannable undirected advertising + passive scanning (10)
    // requires peripheral connection + passive scanning (26).
    _ = goodRet(.le_states, &b);
    b[1 + 3] = 0xFB; // clears bit 26
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .combo_missing, (10 << 16) | 26);
    // Clearing peripheral connection alone (7) is first reported against
    // connectable+scannable undirected advertising (2), the lowest bit that requires it.
    _ = goodRet(.le_states, &b);
    b[1] = 0x7F; // clears bit 7
    try expectFail(cmd, cc(cmd.opcode, b[0..9]).sl(), .combo_missing, (2 << 16) | 7);
    // Advertising alone and peripheral connection alone imply nothing.
    _ = goodRet(.le_states, &b);
    put64(b[1..], (1 << 0) | (1 << 1) | (1 << 7));
    try testing.expect(verify(cmd, cc(cmd.opcode, b[0..9]).sl()) == .ok);
    // implied table spot checks against Table 1.1.
    try testing.expectEqual(@as(u8, 35), implied.ini[32]);
    try testing.expectEqual(@as(u8, 24), implied.ini[22]);
    try testing.expectEqual(@as(u8, 0xFF), implied.ini[41]);
    try testing.expectEqual(@as(u8, 41), implied.per[34]);
    try testing.expectEqual(@as(u8, 0xFF), implied.ini[6]);
}

test "describe: one ASCII line that fits 96 octets for every command" {
    var b: [80]u8 = undefined;
    for (commands) |c| {
        const f = cc(c.opcode, goodRet(c.kind.?, &b));
        var r: Readout = .{};
        try testing.expect(decode(c, f.sl(), &r));
        var out: [96]u8 = @splat(0xAA);
        const line = describe(c, r, &out);
        try testing.expect(line.len <= out.len);
        try testing.expect(line.len > 0);
        try testing.expect(line[line.len - 1] != '~');
        for (line) |ch| try testing.expect(ch >= 0x20 and ch < 0x7F);
        try testing.expect(std.mem.startsWith(u8, line, c.name));
        try testing.expect(std.mem.indexOf(u8, line, "ncmd=1") != null);
    }
}

test "describe: content and truncation" {
    var b: [80]u8 = undefined;
    var r: Readout = .{};
    var out: [96]u8 = undefined;
    const ver = cmdOf(.local_version);
    try testing.expect(decode(ver, cc(ver.opcode, goodRet(.local_version, &b)).sl(), &r));
    try testing.expectEqualStrings("read_local_version ncmd=1 hci=5.4 lmp=5.4 co=Espressif hsub=0x1234 lsub=0x5678", describe(ver, r, &out));

    const st = cmdOf(.le_states);
    try testing.expect(decode(st, cc(st.opcode, goodRet(.le_states, &b)).sl(), &r));
    try testing.expectEqualStrings("le_read_states ncmd=1 bits=42 rfu=0", describe(st, r, &out));

    const addr = cmdOf(.bd_addr);
    try testing.expect(decode(addr, cc(addr.opcode, goodRet(.bd_addr, &b)).sl(), &r));
    try testing.expectEqualStrings("read_bd_addr ncmd=1 addr=24:6F:28:11:22:33", describe(addr, r, &out));

    const lb = cmdOf(.loopback_mode);
    b[0] = 0;
    b[1] = 2;
    var r2: Readout = .{};
    try testing.expect(decode(lb, cc(lb.opcode, b[0..2]).sl(), &r2));
    try testing.expectEqualStrings("read_loopback_mode ncmd=1 mode=remote", describe(lb, r2, &out));

    // Truncation ends with '~' and never exceeds the buffer.
    const line = describe(ver, r2, out[0..8]);
    try testing.expectEqual(@as(usize, 8), line.len);
    try testing.expectEqual(@as(u8, '~'), line[7]);
    try testing.expectEqual(@as(usize, 0), describe(ver, r2, out[0..0]).len);
}

test "version and company name tables are read-only lookups" {
    try testing.expectEqualStrings("5.4", hciVersionName(0x0D));
    try testing.expectEqualStrings("4.2", lmpVersionName(0x08));
    try testing.expectEqualStrings("unknown", hciVersionName(0x0E));
    try testing.expectEqualStrings("unknown", hciVersionName(0xFF));
    try testing.expectEqualStrings("Espressif", companyName(0x02E5));
    try testing.expectEqualStrings("unknown", companyName(0xFFFF));
}
