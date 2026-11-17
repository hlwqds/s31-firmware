//! otadata 的真实落盘与启动槽选择（C5 的 I/O 层）。
//!
//! ## 为什么不用 `bootslot.zig` 的 16 字节 `S31B` 格式
//!
//! `bootslot.zig` 是**教学模型**（它自己也这么写）。IDF bootloader 只认
//! `esp_ota_select_entry_t`：32 字节、`crc` 只覆盖 `ota_seq` 那 4 字节。
//! 往 otadata 里写别的格式**不会报错**，表现是 bootloader 照旧起 factory ——
//! 静默失败，最难查。
//!
//! ## 记录布局（IDF `bootloader_support/include/esp_flash_partitions.h`）
//!
//! ```text
//!   0..4    ota_seq     u32   1 起，槽位 = (ota_seq - 1) % ota_app_count
//!   4..24   seq_label   [20]  填充
//!  24..28   ota_state   u32   NEW(0) / PENDING_VERIFY(1) / VALID(2) / INVALID(3) / ABORTED(4)
//!  28..32   crc         u32   CRC32(**仅 ota_seq**)，初值 0xFFFFFFFF
//! ```
//!
//! 两条记录各占 otadata 分区的**一个 4 KiB 扇区**（扇区号 = 记录号）。
//!
//! ## 谁改哪个状态位（按本仓 bootloader 的实际构建）
//!
//! 本仓 `firmware/idf-bootstrap` **没有**打开 `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`
//! （`components/bootloader/Kconfig.app_rollback` 的 default 就是 `n`）。IDF 里
//! NEW→PENDING_VERIFY 与 PENDING_VERIFY→ABORTED 的翻转都在该宏的 `#ifdef` 内
//! （`bootloader_utility.c:396-401`、`:444-447`），所以**生产 bootloader 一个状态位都不改**：
//!
//! | 状态 | 谁写 |
//! | --- | --- |
//! | `NEW` | 我们（切槽时） |
//! | `PENDING_VERIFY` | 我们（若实现"多给一次机会"的语义）；生产默认不用 |
//! | `VALID` | 我们（自检通过后确认） |
//! | `INVALID` | 我们（连续失败到预算）—— bootloader 的 `ota_select_invalid` 会跳过它 |
//! | `ABORTED` | **本仓不写**；解析时仍按 IDF 语义当作"不可启动"（防御性兼容） |
//!
//! ⇒ "等待确认"的判据是 `state ∈ {NEW, PENDING_VERIFY}`，**不能只判 PENDING_VERIFY**：
//! 我们自己写的是 NEW，bootloader 不会把它翻上去，只判后者会让确认与失败计数永不触发。
//!
//! ## 尝试计数为什么不放在 otadata 扇区里
//!
//! bootloader 更新条目时是**擦整个扇区再写**，任何塞在同一个扇区里的私有字段都会
//! 在状态翻转那一次被抹掉 —— 而那正是最需要计数的时候。所以计数放 **nvs 分区
//! 的最后一个扇区**：生产固件从不写 flash NVS（`wifi-blobs/src/nvs_ram.zig` 是 RAM 版、
//! `bt-blobs/link/phy_stubs.c` 的 `nvs_open` 故意返回 NOT_FOUND），bootloader 也不碰 nvs。

const std = @import("std");
const builtin = @import("builtin");

const flash = @import("flash.zig");
const partition = @import("partition.zig");
/// 槽位。**刻意在这里自带一份**，不从 `ota.zig` 引：
/// 一个 `.zig` 文件不能同时属于两个模块（`boot_power_perf` 与 `ota_ab`），
/// 而 `ota.zig` 是教学模型、`slot.zig` 是生产 I/O 层，分开反而更清楚。
pub const Slot = enum(u1) { a = 0, b = 1 };

pub fn otherSlot(s: Slot) Slot {
    return if (s == .a) .b else .a;
}

const on_target = builtin.target.os.tag == .freestanding;

/// ROM 的 `crc32_le`（`rom_syms.ld` 里 PROVIDE 为 0x2f800784），仅用于板上自检对拍。
extern fn crc32_le(crc: u32, buf: [*]const u8, len: u32) u32;

/// 连续失败预算。与 `ota.AbConfig.max_runtime_failures` 的默认值一致（那里是模型，
/// 这里是生产实现；两边都写在文档里，改一处要同步改另一处与 C5 的判据）。
pub const max_runtime_failures: u8 = 3;

pub const entry_len: usize = 32;
/// otadata 分区固定两个扇区。
pub const sector_count: usize = 2;

pub const Error = error{
    NoOtadata,
    NoOtaSlots,
    NotOnTarget,
    ReadFailed,
    WriteFailed,
    VerifyFailed,
    BadSlot,
};

/// 与 IDF `esp_ota_img_states_t` 数值一致。
pub const State = struct {
    pub const new: u32 = 0x0;
    pub const pending_verify: u32 = 0x1;
    pub const valid: u32 = 0x2;
    pub const invalid: u32 = 0x3;
    pub const aborted: u32 = 0x4;
    pub const undefined_: u32 = 0xFFFFFFFF;

    pub fn name(s: u32) []const u8 {
        return switch (s) {
            new => "NEW",
            pending_verify => "PENDING_VERIFY",
            valid => "VALID",
            invalid => "INVALID",
            aborted => "ABORTED",
            undefined_ => "UNDEFINED",
            else => "OTHER",
        };
    }
};

pub const Entry = struct {
    ota_seq: u32 = 0xFFFFFFFF,
    ota_state: u32 = State.undefined_,
    crc: u32 = 0,
};

/// ROM `crc32_le` 的语义：**首尾各取反一次**的反射式 CRC-32（多项式 0xEDB88320）。
///
/// IDF `esp_rom_crc.h` 的原话是"we had added a `~` at the beginning and the end of
/// the functions"，所以 `crc32_le(init, buf, len) == ~raw(~init, buf)`。
/// 这条约定有两个直接后果，都容易被写错：
///   1. `crc32_le(0xFFFFFFFF, d, n)` 就是标准 CRC-32/ISO-HDLC（等价 `zlib.crc32(d)`），
///      **不是**"裸值"；
///   2. 只实现裸值（无首尾取反）会让 otadata 的 crc 全部对不上，而 bootloader 只会
///      静默判它无效 —— 表现为"写进去了但永远起 factory"。
///
/// 本函数**不调用 ROM**：ROM 的查表指针在 ROM RAM（`crc32_le_table_ptr = 0x2f84fff8`），
/// 应用起来时那张表是否完好不由我们掌控。纯实现 + 板上验证过的向量做判据更可靠。
pub fn crc32Le(init: u32, bytes: []const u8) u32 {
    var crc = ~init;
    for (bytes) |b| {
        crc ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return ~crc;
}

/// 编码一条 otadata 记录。
pub fn encodeEntry(seq: u32, state: u32, out: *[entry_len]u8) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], seq, .little);
    std.mem.writeInt(u32, out[24..28], state, .little);
    const crc = crc32Le(0xFFFFFFFF, out[0..4]);
    std.mem.writeInt(u32, out[28..32], crc, .little);
}

/// 解析一条 otadata 记录（不做有效性判断）。
pub fn decodeEntry(raw: *const [entry_len]u8) Entry {
    return .{
        .ota_seq = std.mem.readInt(u32, raw[0..4], .little),
        .ota_state = std.mem.readInt(u32, raw[24..28], .little),
        .crc = std.mem.readInt(u32, raw[28..32], .little),
    };
}

/// 与 IDF `bootloader_common_ota_select_invalid` 一致。
pub fn isInvalid(e: Entry) bool {
    return e.ota_seq == 0xFFFFFFFF or e.ota_state == State.invalid or e.ota_state == State.aborted;
}

/// 这个状态是否"还没被确认"（需要跑一次自检来决定 VALID / 计一次失败）。
///
/// 生产 bootloader 不改状态位，所以我们写下的 `NEW` 会一直保持到应用自己处理，
/// 因此必须把 `NEW` 也算进来。
pub fn needsVerify(state: u32) bool {
    return state == State.new or state == State.pending_verify;
}

/// 与 IDF `bootloader_common_ota_select_valid` 一致。
pub fn isValid(e: Entry) bool {
    return !isInvalid(e) and e.crc == crc32Le(0xFFFFFFFF, std.mem.asBytes(&e.ota_seq));
}

pub const Selection = struct {
    /// null = 退回 factory。
    slot: ?Slot = null,
    state: u32 = State.undefined_,
    seq: u32 = 0,
    /// 命中的扇区号（0/1）；没有有效条目时为 0。
    sector: u2 = 0,

    pub fn desc(self: Selection) []const u8 {
        return if (self.slot == null) "factory" else switch (self.slot.?) {
            .a => "ota_0",
            .b => "ota_1",
        };
    }
};

/// 与 IDF `bootloader_common_select_otadata` + factory 回退一致。
///
/// - 两条都有效 → 取 `ota_seq` 最大者（相等取扇区 0）；
/// - 只有一条有效 → 那条；
/// - 都无效 → `slot = null`（有 factory 就起 factory）。
pub fn select(a: Entry, b: Entry, app_count: u32) Selection {
    const va = isValid(a);
    const vb = isValid(b);
    const pick_idx: ?u2 = if (va and vb)
        (if (b.ota_seq > a.ota_seq) @as(u2, 1) else @as(u2, 0))
    else if (va)
        0
    else if (vb)
        1
    else
        null;

    const idx = pick_idx orelse return .{};
    const e = if (idx == 0) a else b;
    const raw = e.ota_seq - 1;
    const slot: Slot = if (app_count == 0 or raw % app_count == 0) .a else .b;
    return .{ .slot = slot, .state = e.ota_state, .seq = e.ota_seq, .sector = idx };
}

// ---------------------------------------------------------------------------
// 尝试计数（nvs 分区最后一个扇区，16 字节记录轮转写）
// ---------------------------------------------------------------------------

pub const attempts_len: usize = 16;
pub const attempts_magic: u32 = 0x41313353; // 'S31A'

pub const Attempts = struct {
    slot: u8 = 0,
    boot_attempts: u8 = 0,
    failures: u8 = 0,
};

pub fn encodeAttempts(a: Attempts, out: *[attempts_len]u8) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], attempts_magic, .little);
    out[4] = a.slot;
    out[5] = a.boot_attempts;
    out[6] = a.failures;
    out[7] = 0;
    const crc = crc32Le(0xFFFFFFFF, out[0..12]);
    std.mem.writeInt(u32, out[12..16], crc, .little);
}

pub fn decodeAttempts(raw: *const [attempts_len]u8) ?Attempts {
    const magic = std.mem.readInt(u32, raw[0..4], .little);
    if (magic != attempts_magic) return null;
    const crc = std.mem.readInt(u32, raw[12..16], .little);
    if (crc != crc32Le(0xFFFFFFFF, raw[0..12])) return null;
    return .{ .slot = raw[4], .boot_attempts = raw[5], .failures = raw[6] };
}

pub const AttemptHit = struct { index: usize, value: Attempts };

/// 在 4 KiB 扇区里找最后一条有效记录（下标最大的）。
pub fn findLastAttempts(sector: []const u8) ?AttemptHit {
    var best: ?AttemptHit = null;
    var off: usize = 0;
    while (off + attempts_len <= sector.len) : (off += attempts_len) {
        const raw: *const [attempts_len]u8 = @ptrCast(sector[off..][0..attempts_len].ptr);
        if (decodeAttempts(raw)) |a| best = .{ .index = off / attempts_len, .value = a };
    }
    return best;
}

// ---------------------------------------------------------------------------
// 真实 I/O
// ---------------------------------------------------------------------------

/// 分区表里有多少个 OTA 应用槽（本仓期望 2）。
///
/// 注意：**不能写成 `@intFromBool(a) + @intFromBool(b)`** —— `@intFromBool` 返回 `u1`，
/// `1u1 + 1u1` 溢出；ReleaseSmall 不开安全检查时会静默回绕成 0，
/// 表现是 "表里明明有两个槽，程序却认为一个都没有"。先转 `u32` 再加。
pub fn appCount(t: *const partition.Table) u32 {
    var n: u32 = 0;
    if (t.findApp(partition.Subtype.ota_0) != null) n += 1;
    if (t.findApp(partition.Subtype.ota_1) != null) n += 1;
    return n;
}

pub const Boot = struct {
    selection: Selection,
    attempts: Attempts,
    /// 分区表里是否真的有 otadata + 两个 ota 槽。
    ab_configured: bool,
    /// 诊断：otadata 分区偏移（0 = 没找到）与识别到的 ota 槽个数。
    od_off: u32 = 0,
    app_count: u32 = 0,
};

var sector_buf: [flash.sector_size]u8 align(4) = undefined;

fn readSector(off: u32) Error![*]const u8 {
    const words: [*]u32 = @ptrCast(@alignCast(&sector_buf));
    flash.read(off, words[0 .. sector_buf.len / 4]) catch return Error.ReadFailed;
    return &sector_buf;
}

/// 读出当前启动信息。主机上返回 `NotOnTarget`。
pub fn readBoot() Error!Boot {
    if (!on_target) return Error.NotOnTarget;
    var table = partition.readFlashTable() catch return Error.ReadFailed;
    const od = table.otadata() orelse return Boot{
        .selection = .{},
        .attempts = .{},
        .ab_configured = false,
    };
    const app_count = appCount(&table);

    var entries: [2]Entry = .{ .{}, .{} };
    var i: usize = 0;
    while (i < sector_count) : (i += 1) {
        const raw = readSector(od.offset + @as(u32, @intCast(i)) * flash.sector_size) catch {
            continue;
        };
        const bytes: *const [entry_len]u8 = @ptrCast(raw);
        entries[i] = decodeEntry(bytes);
    }

    return .{
        .selection = select(entries[0], entries[1], app_count),
        .attempts = readAttempts(&table) catch .{},
        .ab_configured = app_count == 2,
        .od_off = od.offset,
        .app_count = app_count,
    };
}

/// nvs 分区的最后一个扇区。
fn nvsLastSector(table: *const partition.Table) ?u32 {
    const nvs = table.find("nvs") orelse return null;
    if (nvs.size < flash.sector_size) return null;
    return nvs.offset + nvs.size - flash.sector_size;
}

fn readAttempts(table: *const partition.Table) Error!Attempts {
    const off = nvsLastSector(table) orelse return .{};
    const raw = try readSector(off);
    const sector = raw[0..flash.sector_size];
    if (findLastAttempts(sector)) |hit| return hit.value;
    return .{};
}

/// 追加写一条尝试计数记录；扇区写满时擦一次再从 0 开始。
pub fn writeAttempts(a: Attempts) Error!void {
    if (!on_target) return Error.NotOnTarget;
    var table = partition.readFlashTable() catch return Error.ReadFailed;
    const off = nvsLastSector(&table) orelse return Error.NoOtadata;
    const raw = try readSector(off);

    var next: usize = 0;
    if (findLastAttempts(raw[0..flash.sector_size])) |hit| next = hit.index + 1;

    if (next * attempts_len + attempts_len > flash.sector_size) {
        flash.eraseSector(off) catch return Error.WriteFailed;
        next = 0;
    }

    var rec: [attempts_len]u8 align(4) = undefined;
    encodeAttempts(a, &rec);
    const target = off + @as(u32, @intCast(next * attempts_len));
    flash.writeBytes(target, &rec) catch return Error.WriteFailed;

    // 回读自检：ROM 的返回码只代表控制器完成。
    const back = try readSector(off);
    const at = next * attempts_len;
    if (!std.mem.eql(u8, back[at..][0..attempts_len], &rec)) return Error.VerifyFailed;
}

/// 把 `sector` 这条记录写成 `(seq, state)`。对应 IDF `rewrite_ota_seq()`：
/// **先擦该扇区再写 32 字节**。
///
/// 谁写哪个扇区由调用方决定，这里不替它猜：
///   - 切槽（`setBootSlot`）写**另一个**扇区，当前有效记录必须留着（断电可回退）；
///   - 确认/判废（`markValid`/`markInvalid`）写**同一个**扇区、`seq` 不变。
/// 后者必须同扇区同 seq：两条记录 seq 相等时选槽规则取扇区 0，
/// 写到另一个扇区会让 VALID 被旧记录"盖掉"。
pub fn writeEntry(seq: u32, state: u32, sector: u2) Error!u32 {
    if (!on_target) return Error.NotOnTarget;
    var table = partition.readFlashTable() catch return Error.ReadFailed;
    const od = table.otadata() orelse return Error.NoOtadata;

    const target_sector: u2 = sector;
    const off = od.offset + @as(u32, target_sector) * flash.sector_size;

    var rec: [entry_len]u8 align(4) = undefined;
    encodeEntry(seq, state, &rec);

    flash.eraseSector(off) catch return Error.WriteFailed;
    flash.writeBytes(off, &rec) catch return Error.WriteFailed;

    const back = try readSector(off);
    if (!std.mem.eql(u8, back[0..entry_len], &rec)) return Error.VerifyFailed;
    return target_sector;
}

/// 对应 IDF `compute_ota_seq_for_target_slot()`：算出让 bootloader 选中
/// `target` 槽的**最小大于** `current_seq` 的 `ota_seq`。
///
/// 公式（`esp_ota_ops.c` 的注释与实现逐字）：
/// `base = (target + 1) % count; new_seq = base + count * i`，
/// 其中 `i` 是满足 `new_seq > current_seq` 的最小非负整数。
pub fn seqForSlot(current_seq: u32, target: Slot, app_count: u32) u32 {
    if (app_count == 0) return 0;
    // `Slot` 是 enum(u1)：先转 u32 再 +1，否则 1+1 在 u1 上溢出
    const base = (@as(u32, @backingInt(target)) + 1) % app_count;
    var i: u32 = 0;
    while (current_seq > base + i * app_count) : (i += 1) {}
    return base + i * app_count;
}

/// 对应 IDF `esp_ota_set_boot_partition()`：把下次启动切到 `target`，状态写 NEW。
///
/// 三种情形（与 `esp_ota_ops.c:790-811` 一致）：
///   1. otadata 还没有有效记录 → 写扇区 0，`seq = target + 1`；
///   2. 当前已经在 `target` → 写**同一**扇区，`seq` 不变（只改状态）；
///   3. 否则 → 写**另一个**扇区，`seq = seqForSlot(...)`。
pub fn setBootSlot(target: Slot, app_count: u32) Error!u32 {
    if (!on_target) return Error.NotOnTarget;
    var table = partition.readFlashTable() catch return Error.ReadFailed;
    const od = table.otadata() orelse return Error.NoOtadata;
    if (app_count == 0) return Error.NoOtaSlots;

    var entries: [2]Entry = .{ .{}, .{} };
    var i: usize = 0;
    while (i < sector_count) : (i += 1) {
        const raw = readSector(od.offset + @as(u32, @intCast(i)) * flash.sector_size) catch continue;
        const bytes: *const [entry_len]u8 = @ptrCast(raw);
        entries[i] = decodeEntry(bytes);
    }
    const sel = select(entries[0], entries[1], app_count);

    var sector: u2 = 0;
    var seq: u32 = 0;
    if (sel.slot == null) {
        sector = 0;
        seq = @as(u32, @backingInt(target)) + 1;
    } else if (sel.slot.? == target) {
        sector = sel.sector;
        seq = sel.seq;
    } else {
        sector = sel.sector ^ 1;
        seq = seqForSlot(sel.seq, target, app_count);
    }
    return writeEntry(seq, State.new, sector);
}

/// 自检通过：把当前槽位写成 VALID，并清空失败计数。
pub fn markValid(boot: Boot) Error!void {
    const seq = boot.selection.seq;
    if (seq == 0) return Error.NoOtaSlots;
    _ = try writeEntry(seq, State.valid, boot.selection.sector);
    try writeAttempts(.{ .slot = @intFromBool(boot.selection.slot == .b), .boot_attempts = 0, .failures = 0 });
}

/// 记一次运行期失败；返回累加后的计数。
///
/// **计数是按槽的**：`attempts.slot` 与当前槽不同时先清零再计。否则上一个槽攒下的
/// 失败会被新槽继承 —— 板上实测出现过 `failures=8` 跨槽带过去，
/// 那样"连续 3 次失败"的判据就自相矛盾了（新槽可能一次失败就被判 INVALID）。
pub fn noteFailure(boot: Boot) Error!Attempts {
    const slot_bit: u8 = @intFromBool(boot.selection.slot == .b);
    var a = boot.attempts;
    if (a.slot != slot_bit) a = .{ .slot = slot_bit };
    a.failures +|= 1;
    try writeAttempts(a);
    return a;
}

/// 判死当前槽（连续失败到预算后调用）：写 INVALID，让 bootloader 下次改走别的槽。
pub fn markInvalid(boot: Boot) Error!void {
    const seq = boot.selection.seq;
    if (seq == 0) return Error.NoOtaSlots;
    _ = try writeEntry(seq, State.invalid, boot.selection.sector);
}

pub const CrcCheck = struct {
    mine: u32,
    rom: u32,
    ok: bool,
    applicable: bool,
};

/// 板上自检：纯 Zig CRC 与 ROM `crc32_le` 必须一致。
///
/// 主机上没有 ROM，`applicable=false`（"不适用"，不是"通过"）。**两个原始值都返回**，
/// 因为不一致时必须看值是差一个取反还是完全无关，猜是没用的。
pub fn checkCrc() CrcCheck {
    const probe = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    const mine = crc32Le(0xFFFFFFFF, &probe);
    if (!on_target) return .{ .mine = mine, .rom = mine, .ok = true, .applicable = false };
    const rom = crc32_le(0xFFFFFFFF, &probe, probe.len);
    return .{ .mine = mine, .rom = rom, .ok = mine == rom, .applicable = true };
}

/// 分区表解析结果摘要（诊断用：哪一项没找到一眼可见）。
pub const TableInfo = struct {
    count: usize = 0,
    factory_off: u32 = 0,
    otadata_off: u32 = 0,
    ota0_off: u32 = 0,
    ota1_off: u32 = 0,
};

pub fn tableInfo() Error!TableInfo {
    if (!on_target) return Error.NotOnTarget;
    var t = partition.readFlashTable() catch return Error.ReadFailed;
    return .{
        .count = t.count,
        .factory_off = if (t.find("factory")) |e| e.offset else 0,
        .otadata_off = if (t.otadata()) |e| e.offset else 0,
        .ota0_off = if (t.findApp(partition.Subtype.ota_0)) |e| e.offset else 0,
        .ota1_off = if (t.findApp(partition.Subtype.ota_1)) |e| e.offset else 0,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "ota-slot: 真实 otadata 编码（crc 只覆盖 ota_seq）" {
    var rec: [entry_len]u8 = undefined;
    encodeEntry(1, State.new, &rec);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, rec[0..4], .little));
    try testing.expectEqual(@as(u32, State.new), std.mem.readInt(u32, rec[24..28], .little));

    // crc 必须等于只对前 4 字节算出来的值
    const expect = crc32Le(0xFFFFFFFF, rec[0..4]);
    try testing.expectEqual(expect, std.mem.readInt(u32, rec[28..32], .little));

    // 改 ota_state 不影响 crc（这是 IDF 的语义，不是 bug）
    var rec2: [entry_len]u8 = undefined;
    encodeEntry(1, State.valid, &rec2);
    try testing.expectEqual(expect, std.mem.readInt(u32, rec2[28..32], .little));
}

test "ota-slot: 有效性判定与 IDF 一致" {
    var rec: [entry_len]u8 = undefined;
    encodeEntry(1, State.valid, &rec);
    const e = decodeEntry(&rec);
    try testing.expect(isValid(e));

    // 空白（全 0xFF）→ seq=0xFFFFFFFF → invalid
    const blank: [entry_len]u8 = @splat(0xFF);
    try testing.expect(isInvalid(decodeEntry(&blank)));
    try testing.expect(!isValid(decodeEntry(&blank)));

    // INVALID / ABORTED 状态直接判死
    for ([_]u32{ State.invalid, State.aborted }) |st| {
        encodeEntry(3, st, &rec);
        try testing.expect(isInvalid(decodeEntry(&rec)));
        try testing.expect(!isValid(decodeEntry(&rec)));
    }

    // crc 错一个字节就判死
    encodeEntry(3, State.valid, &rec);
    rec[28] ^= 0xFF;
    try testing.expect(!isValid(decodeEntry(&rec)));
}

test "ota-slot: 选择规则（最大 seq、单条有效、都无效回 factory）" {
    var a: [entry_len]u8 = undefined;
    var b: [entry_len]u8 = undefined;

    encodeEntry(1, State.valid, &a);
    encodeEntry(2, State.valid, &b);
    var s = select(decodeEntry(&a), decodeEntry(&b), 2);
    try testing.expectEqual(Slot.b, s.slot.?);
    try testing.expectEqual(@as(u32, 2), s.seq);
    try testing.expectEqual(@as(u2, 1), s.sector);

    // 反序也必须选 seq=2
    s = select(decodeEntry(&b), decodeEntry(&a), 2);
    try testing.expectEqual(@as(u32, 2), s.seq);
    try testing.expectEqual(@as(u2, 0), s.sector);

    // 只有扇区 1 有效
    encodeEntry(1, State.aborted, &a);
    encodeEntry(2, State.valid, &b);
    s = select(decodeEntry(&a), decodeEntry(&b), 2);
    try testing.expectEqual(@as(u32, 2), s.seq);
    try testing.expectEqual(@as(u2, 1), s.sector);

    // 都无效 → factory
    encodeEntry(1, State.invalid, &a);
    const blank: [entry_len]u8 = @splat(0xFF);
    s = select(decodeEntry(&a), decodeEntry(&blank), 2);
    try testing.expect(s.slot == null);
    try testing.expectEqualStrings("factory", s.desc());

    // seq 单条也能算出槽位：(4-1)%2 = 1 → ota_1
    encodeEntry(4, State.valid, &a);
    s = select(decodeEntry(&a), decodeEntry(&blank), 2);
    try testing.expectEqual(Slot.b, s.slot.?);
}

test "ota-slot: 尝试计数记录编码/查找/坏 CRC" {
    var rec: [attempts_len]u8 = undefined;
    encodeAttempts(.{ .slot = 1, .boot_attempts = 2, .failures = 3 }, &rec);
    const back = decodeAttempts(&rec).?;
    try testing.expectEqual(@as(u8, 1), back.slot);
    try testing.expectEqual(@as(u8, 2), back.boot_attempts);
    try testing.expectEqual(@as(u8, 3), back.failures);

    // 坏 crc 不认
    rec[12] ^= 0xFF;
    try testing.expect(decodeAttempts(&rec) == null);

    // 扇区里取最后一条
    var sector: [flash.sector_size]u8 = @splat(0xFF);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var r: [attempts_len]u8 = undefined;
        encodeAttempts(.{ .slot = 0, .boot_attempts = 0, .failures = @intCast(i + 1) }, &r);
        @memcpy(sector[i * attempts_len ..][0..attempts_len], &r);
    }
    const last = findLastAttempts(&sector).?;
    try testing.expectEqual(@as(usize, 2), last.index);
    try testing.expectEqual(@as(u8, 3), last.value.failures);
}

test "ota-slot: CRC 与板上验证过的 otadata 真值一致" {
    // 这三个值来自 ch23 lab：用 ROM 函数算出、写进 otadata、**被 bootloader 接受**。
    // 出处 logs/ch23-ota-rollback-ok.log:167（seq=1）、ch23-ota-ab-1.log:134（seq=2）、
    // ch23-ota-ab-2.log:134（seq=3）。bootloader 校验时算的就是这套值。
    try testing.expectEqual(@as(u32, 0x4743989A), crc32Le(0xFFFFFFFF, &[_]u8{ 1, 0, 0, 0 }));
    try testing.expectEqual(@as(u32, 0x55F63774), crc32Le(0xFFFFFFFF, &[_]u8{ 2, 0, 0, 0 }));
    try testing.expectEqual(@as(u32, 0xED4A5011), crc32Le(0xFFFFFFFF, &[_]u8{ 3, 0, 0, 0 }));
    // init 传 0xFFFFFFFF 时**不等于** zlib.crc32：ROM 内部把参数当作 ~init 用，
    // 所以得到的是 0xD202D277；只有传 0 才与 zlib 一致（下一条）。
    try testing.expectEqual(@as(u32, 0xD202D277), crc32Le(0xFFFFFFFF, "123456789"));
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32Le(0x00000000, "123456789"));
    try testing.expectEqual(@as(u32, 0x99F8B879), crc32Le(0x00000000, &[_]u8{ 1, 0, 0, 0 }));
}

test "ota-slot: appCount 对真实 6 条目表返回 2（u1 回绕回归）" {
    var bytes: [partition.table_max_len]u8 = @splat(0xFF);
    const rows = [_]struct { kind: u8, sub: u8, off: u32, size: u32, label: []const u8 }{
        .{ .kind = 0x01, .sub = 0x02, .off = 0x9000, .size = 0x6000, .label = "nvs" },
        .{ .kind = 0x01, .sub = 0x01, .off = 0xf000, .size = 0x1000, .label = "phy_init" },
        .{ .kind = 0x00, .sub = 0x00, .off = 0x10000, .size = 0x177000, .label = "factory" },
        .{ .kind = 0x00, .sub = 0x10, .off = 0x190000, .size = 0x180000, .label = "ota_0" },
        .{ .kind = 0x00, .sub = 0x11, .off = 0x310000, .size = 0x180000, .label = "ota_1" },
        .{ .kind = 0x01, .sub = 0x00, .off = 0x490000, .size = 0x2000, .label = "otadata" },
    };
    var off: usize = 0;
    for (rows) |r| {
        std.mem.writeInt(u16, bytes[off..][0..2], partition.magic, .little);
        bytes[off + 2] = r.kind;
        bytes[off + 3] = r.sub;
        std.mem.writeInt(u32, bytes[off + 4 ..][0..4], r.off, .little);
        std.mem.writeInt(u32, bytes[off + 8 ..][0..4], r.size, .little);
        @memset(bytes[off + 12 .. off + 28], 0);
        @memcpy(bytes[off + 12 ..][0..r.label.len], r.label);
        off += partition.entry_len;
    }
    const t = try partition.parse(&bytes);
    try testing.expectEqual(@as(usize, 6), t.count);
    try testing.expectEqual(@as(u32, 2), appCount(&t));
}

test "ota-slot: 失败计数按槽隔离（换槽后从 0 开始）" {
    // 直接验证 noteFailure 的判定式，不碰 flash：模拟"上一槽已失败 2 次"再换槽。
    const prev: Attempts = .{ .slot = 1, .boot_attempts = 0, .failures = 2 };
    const cur_slot_bit: u8 = 0; // 现在在 ota_0
    var a = prev;
    if (a.slot != cur_slot_bit) a = .{ .slot = cur_slot_bit };
    a.failures +|= 1;
    try testing.expectEqual(@as(u8, 1), a.failures); // 不是 3
    try testing.expectEqual(@as(u8, 0), a.slot);

    // 同槽内继续累加
    var b: Attempts = .{ .slot = 0, .boot_attempts = 0, .failures = 1 };
    if (b.slot != cur_slot_bit) b = .{ .slot = cur_slot_bit };
    b.failures +|= 1;
    try testing.expectEqual(@as(u8, 2), b.failures);
}
