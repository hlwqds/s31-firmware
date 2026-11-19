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
const bpp = @import("boot_power_perf");
const perf_flag = @import("perf_flag");

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

    // --- C7: 固定工作量的周期实测（`-Dperf-run`，默认关闭）----------------
    if (comptime perf_flag.run) runPerf();
    if (comptime perf_flag.tiers) runPerfTiers();

    // --- C8: 按需切回旧版本（`-Dab-revert`）--------------------------------
    if (comptime ab_flags.revert) revertToOld(boot_state);

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

/// `-Dperf-run`：固定工作量跑若干轮，报告周期统计。
///
/// **只用 `mcycle`**，不碰 `nowUs()`：后者走 TIMG0（APB/40），一旦改 CPU 频率就不再准。
/// 时间/吞吐由周期数按标称频率折算，日志里标明是"按标称频率折算"。
fn runPerf() void {
    const w = bpp.workload;
    // TIMG0 必须先初始化：生产 main 平时不调它，而 `nowUs()` 在未初始化的 TIMG0 上**恒为 0**
    // （与 bt-blobs 探针里记的那条实测一致）。只有「实测 CPU 频率」那一步用到它。
    board.hw.initTimer();
    w.initWork();

    var sink: u64 = 0;
    var samples: [24]u64 = undefined;
    const report = w.measure(&board.hw.cycleCount, &sink, samples.len, &samples) catch |e| {
        board.log.line("perf: measure failed: {s}", .{@errorName(e)});
        return;
    };
    board.log.line(
        "perf: bytes={d} rounds={d} cycles(min/mean/p50/p95)={d}/{d}/{d}/{d} cycles_per_byte={d:.3}",
        .{ report.bytes, report.rounds, report.summary.min, report.summary.mean, report.cycles_p50, report.cycles_p95, report.cycles_per_byte },
    );
    // 实测 CPU 频率：`mcycle` 与 `nowUs()`（TIMG0 = APB/40）是两个独立的计数源，
    // 一段时间内的"周期数 / 微秒数"就是 MHz。这样下面的折算用的是实测频率而不是标称值。
    const mhz = measureCpuMhz();
    if (mhz == 0) {
        board.log.raw("perf: cpu_mhz measurement failed (nowUs did not advance)\n");
    } else {
        const ns = report.cycles_p50 * 1000 / mhz;
        const mib = bpp.perf.mibPerSecond(report.bytes, ns);
        board.log.line("perf: cpu_mhz(measured)={d} p50_ns={d} mib_per_s={d:.3}", .{ mhz, ns, mib });
    }
    board.log.line("perf: sink=0x{x}", .{sink});
}

/// `-Dperf-tiers`：把 CPU 切到 80/160/320 各测一遍固定工作量。
///
/// **每档测完不打印**：320 档的 APB 是 53.33 MHz，UART 与 `nowUs()` 都会失真。
/// 全部测完先切回 80 档（APB=40），再一次性打印。
fn runPerfTiers() void {
    const w = bpp.workload;
    board.hw.initTimer();
    w.initWork();

    const tiers = board.clock.Tiers;
    var cycles_p50: [tiers.len]u64 = @splat(0);
    var cmp: [tiers.len]f64 = @splat(0);
    var ok: [tiers.len]bool = @splat(false);
    var readback: [tiers.len]u32 = @splat(0);
    // 每档的**实测**频率（`mcycle` / `nowUs`）。这是"时钟真的变了"的独立证据：
    // 寄存器读回只能证明"写了什么"。
    var mhz_seen: [tiers.len]u32 = @splat(0);

    var i: usize = 0;
    while (i < tiers.len) : (i += 1) {
        const mhz = tiers[i];
        // 失败用 0 表示（合法分频从 1 起），避免在 catch 里 continue。
        const div: u32 = board.clock.setCpuMhz(mhz) catch 0;
        if (div == 0) continue;
        readback[i] = div;
        mhz_seen[i] = measureCpuMhz();
        var sink: u64 = 0;
        var samples: [16]u64 = undefined;
        if (w.measure(&board.hw.cycleCount, &sink, samples.len, &samples)) |rep| {
            cycles_p50[i] = rep.cycles_p50;
            cmp[i] = rep.cycles_per_byte;
            ok[i] = true;
        } else |_| {}
    }

    // 先回到默认档（APB=40）再加打印，否则串口是乱码。
    _ = board.clock.setCpuMhz(80) catch {};
    const st = board.clock.readState() catch return;

    i = 0;
    while (i < tiers.len) : (i += 1) {
        if (!ok[i]) {
            board.log.line("perf-tier: {d}MHz set/measure FAILED (readback_div={d})", .{ tiers[i], readback[i] });
            continue;
        }
        // 时间由**该档标称频率**折算；周期数是实测，频率无关。
        const ns = cycles_p50[i] * 1000 / tiers[i];
        const mib = bpp.perf.mibPerSecond(w.work_len, ns);
        // `mhz_measured` 是独立的频率证据（`mcycle` 增量 / `nowUs` 增量）。
        //
        // 板上实测：80 → 79、160 → 160、320 → **320**。最后这个 320 同时说明
        // **APB 没有跟着变**（若 APB 变成 53.33 MHz，`nowUs` 会走快 1.333 倍，
        // 这里的读数就只会是 240）。也就是说按 IDF 的表写了 sys/apb 分频之后，
        // 硬件把分频自动纠正了 —— 正是 IDF 在 `rtc_clk.c` 注释里警告的那件事
        // （"Hardware could automatically correct the divider, and it won't be reflected
        // to the registers"）。所以时间折算用**该档标称频率**，不做 APB 修正。
        board.log.line(
            "perf-tier: {d}MHz cycles_p50={d} cycles_per_byte={d:.3} p50_ns={d} mib_per_s={d:.3} div={d} mhz_measured={d}",
            .{ tiers[i], cycles_p50[i], cmp[i], ns, mib, readback[i], mhz_seen[i] },
        );
    }
    board.log.line("perf-tier: restored src={d} cpu_div={d} (4000000/x100 apb check below)", .{ st.src, st.cpu_div });
}

/// 实测 CPU 频率（MHz）：`mcycle` 增量 / `nowUs()` 增量。
///
/// 两个计数源独立：`mcycle` 数的是 CPU 周期，`nowUs()` 数的是 TIMG0（APB/40）。
/// 只要 APB 仍是 40 MHz（本固件没有改频路径），这个比值就是真实的 CPU MHz。
fn measureCpuMhz() u32 {
    const c0 = board.hw.cycleCount();
    const t0 = board.hw.nowUs();
    var guard: u32 = 0;
    while (board.hw.elapsedUs(t0) < 20_000 and guard < 5_000_000) : (guard += 1) {}
    const c1 = board.hw.cycleCount();
    const us = board.hw.elapsedUs(t0);
    if (us == 0) return 0;
    return @intCast((c1 - c0) / us);
}

/// `-Dab-revert`：把当前槽标成 INVALID 后复位 —— bootloader 会跳过它、改走另一槽或 factory。
///
/// 这就是 C5 回滚用的同一个动作（`markInvalid`），只是由人触发而不是由失败计数触发；
/// 因此 C8 的"可通过 OTA 槽位切回旧版本"与 C5 的回滚共用一条代码路径。
fn revertToOld(boot: ?ota_ab.Boot) void {
    if (boot) |b| {
        if (b.selection.slot == null) {
            board.log.raw("ota: already on factory, nothing to revert\n");
            return;
        }
        if (ota_ab.markInvalid(b)) {
            board.log.line("ota: slot {s} marked INVALID -> reverting to the old image", .{b.selection.desc()});
        } else |e| {
            board.log.line("ota: markInvalid failed: {s}", .{@errorName(e)});
            return;
        }
        board.log.raw("ota: resetting to boot the old image\n");
        board.hw.reset();
    }
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

// 跨复位追踪槽的尝试已移除：`adv_trace[8]` 在这个 Zig 版本下仍被编成 offset 0
// （反汇编只出现 `sw zero, -1728(a0)`，`-1696(` 无 store），
// 说明数组索引被折叠。要重做必须先用反汇编确认 `-1696(` 出现。
