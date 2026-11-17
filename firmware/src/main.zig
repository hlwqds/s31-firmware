//! 生产固件入口：按构建开关组合子系统自检，跑完后停机。
//!
//! 自 C5 起还负责 A/B 的**应用侧**职责（见 `components/boot-power-perf/src/slot.zig`）：
//!   - 启动时读分区表 + otadata，打印真实活动槽与尝试计数；
//!   - 自检全通过且当前槽尚未确认 → 写 `VALID`；
//!   - 自检失败 → 累加失败计数，达到预算（3）→ 把当前槽写 `INVALID` 并复位，
//!     bootloader 会跳过它改走另一槽（或 factory）。
//!
//! 生产 bootloader **没有**打开 `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`，所以
//! NEW→PENDING_VERIFY / ABORTED 的翻转不会发生，全部由这里负责。
const std = @import("std");
const board = @import("board");
const enabled = @import("enabled");
const ota_ab = @import("ota_ab");
const ab_flags = @import("ab_fail_flag");

pub export fn main() noreturn {
    // `-Dwifi-init-probe` 打开时，入口换成 R3 探针（正常自检不跑）。
    // `enabled` 是 comptime 常量，关闭时整个分支被剪掉。
    const probe = @import("wifi_init_probe");
    if (probe.enabled) probe.run();
    // `-Dbt-probe` 打开时换成 BLE controller 探针（与 wifi 探针同构，二者互斥）
    const bt_probe = @import("bt_probe");
    if (bt_probe.enabled) bt_probe.run();
    board.log.raw("s31-firmware boot\n");

    // --- C5: 真实的槽位状态（只读） ---------------------------------------
    const crc = ota_ab.checkCrc();
    if (crc.applicable) {
        board.log.line("ota: crc32 mine=0x{x:0>8} rom=0x{x:0>8} -> {s}", .{ crc.mine, crc.rom, if (crc.ok) "match" else "MISMATCH" });
    } else {
        board.log.raw("ota: crc32 self-check not applicable (host build)\n");
    }
    if (ota_ab.tableInfo()) |t| {
        board.log.line("ota: table n={d} factory=0x{x} ota0=0x{x} ota1=0x{x} otadata=0x{x}", .{ t.count, t.factory_off, t.ota0_off, t.ota1_off, t.otadata_off });
    } else |e| {
        board.log.line("ota: tableInfo failed: {s}", .{@errorName(e)});
    }
    var boot_state: ?ota_ab.Boot = null;
    if (ota_ab.readBoot()) |b| {
        boot_state = b;
        board.log.line(
            "ota: ab={s} slot={s} state={s}({d}) seq={d} sector={d} attempts={d} failures={d} od=0x{x} count={d}",
            .{
                if (b.ab_configured) "yes" else "no",
                b.selection.desc(),
                ota_ab.State.name(b.selection.state),
                b.selection.state,
                b.selection.seq,
                b.selection.sector,
                b.attempts.boot_attempts,
                b.attempts.failures,
                b.od_off,
                b.app_count,
            },
        );
    } else |e| {
        board.log.line("ota: readBoot failed: {s}", .{@errorName(e)});
    }

    // --- C5: 切槽（`-Dab-stage=a|b`），写完复位让 bootloader 重新选 --------
    if (comptime ab_flags.stage.len > 0) {
        stageBoot(ab_flags.stage);
    }

    var n: u32 = 0;
    var failed: u32 = 0;
    inline for (enabled.entries) |e| {
        board.log.line("section: {s}", .{e.name});
        if (!e.run()) failed += 1;
        n += 1;
    }
    board.log.line("firmware: sections: passed={d} failed={d} total={d}", .{ n - failed, failed, n });
    board.log.line("main: verdict={s}", .{if (failed == 0) "pass" else "fail"});

    // --- C5: 把自检结果落到 otadata ---------------------------------------
    if (boot_state) |b| {
        if (b.selection.slot == null) {
            board.log.raw("ota: running factory, no slot bookkeeping\n");
        } else if (failed == 0) {
            if (ota_ab.needsVerify(b.selection.state)) {
                if (ota_ab.markValid(b)) {
                    board.log.line("ota: slot {s} confirmed VALID", .{b.selection.desc()});
                } else |err| {
                    board.log.line("ota: markValid failed: {s}", .{@errorName(err)});
                }
            } else {
                board.log.line("ota: slot {s} already {s}", .{ b.selection.desc(), ota_ab.State.name(b.selection.state) });
            }
        } else {
            if (ota_ab.noteFailure(b)) |a| {
                board.log.line("ota: slot {s} failure {d}/{d}", .{ b.selection.desc(), a.failures, ota_ab.max_runtime_failures });
                if (a.failures >= ota_ab.max_runtime_failures) {
                    if (ota_ab.markInvalid(b)) {
                        board.log.line("ota: slot {s} marked INVALID -> rolling back", .{b.selection.desc()});
                    } else |err| {
                        board.log.line("ota: markInvalid failed: {s}", .{@errorName(err)});
                    }
                    board.log.raw("ota: resetting to let bootloader pick another slot\n");
                    board.hw.reset();
                }
            } else |err| {
                board.log.line("ota: noteFailure failed: {s}", .{@errorName(err)});
            }
        }
    }

    board.hw.halt();
}

/// `-Dab-stage=a|b`：把下次启动切到指定槽，然后复位。
fn stageBoot(which: []const u8) noreturn {
    const slot: ota_ab.Slot = if (std.mem.eql(u8, which, "a")) .a else .b;
    const count: u32 = 2;
    if (ota_ab.setBootSlot(slot, count)) |sector| {
        board.log.line("ota: staged slot {s} in sector {d}, resetting", .{ if (slot == .a) "ota_0" else "ota_1", sector });
    } else |err| {
        board.log.line("ota: setBootSlot failed: {s}", .{@errorName(err)});
    }
    board.hw.reset();
}
