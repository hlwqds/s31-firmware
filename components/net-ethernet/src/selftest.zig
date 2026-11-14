//! 以太网自检：引脚 → PHY 复位 → APLL 125 MHz → 时钟域 → DMA 软复位 →
//! MDIO/PHY ID → MAC/DMA 描述符环 → TX 环回。
//!
//! 判据只依赖寄存器读数与 MDIO 应答。RJ45 的 link 由外部线缆/对端决定，
//! 因此只打印 BMSR/ANLPAR 状态，不作为自检失败项。

const board = @import("board");
const descs = @import("descs.zig");
const emac = @import("emac.zig");
const apll = @import("apll.zig");
const phy = @import("phy.zig");
const pins = @import("pins.zig");
const regs = @import("regs.zig");

const log = board.log;
const hw = board.hw;

const mdio_timeout_us: u32 = 2_000;
const dma_reset_timeout_us: u32 = 10_000;
const pll_timeout_us: u32 = 50_000;
const tx_timeout_us: u32 = 20_000;

var passed: u32 = 0;
var failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) passed += 1 else failed += 1;
    log.line("check: " ++ fmt ++ " ok={d}", args ++ .{@intFromBool(ok)});
}

pub fn run() bool {
    passed = 0;
    failed = 0;
    board.hw.initTimer();

    // 1) 引脚：PHY 先在复位外，RGMII 的 RX 时钟才可能出现在 GPIO14 上。
    emac.enableBusClock();
    log.line("clk: emac_sys_clk_en={d}", .{@intFromBool(emac.busClockEnabled())});
    pins.initRgmii();
    pins.initPhyReset();
    pins.initMdio(pins.default_mdc, pins.default_mdio);
    log.line("pin: mdc=gpio{d} mdio=gpio{d} rst=gpio{d}", .{
        pins.default_mdc, pins.default_mdio, pins.phy_reset_gpio,
    });

    // 2) 寄存器复位 + MAC 签名
    emac.resetRegisters();
    const ver = emac.macVersion();
    check((ver & 0xFF) == 0x37, "mac snps=0x{x:0>2} version=0x{x:0>8}", .{ ver & 0xFF, ver });

    // 3) ref clock：MPLL 校准在本板裸机下不完成（CAL_END 恒 0），改用 APLL。
    //    APLL: 500 MHz 倍频 / 4 = 125 MHz，ref 分频写 0。
    const ap = apll.ensure125(pll_timeout_us);
    log.line("apll: cal_end={d} out_div={d} sdm=0x{x:0>6} clk_en={d}", .{
        @intFromBool(ap.cal_end), ap.out_div, ap.sdm, @intFromBool(ap.clk_en),
    });
    check(ap.cal_end, "apll calibration done", .{});

    emac.enableRgmiiClocks();
    const ref = emac.readRefClock();
    log.line("clk: ref sel={d} div={d} en={d}", .{ ref.sel, ref.div, @intFromBool(ref.enabled) });
    check(ref.enabled and ref.sel == emac.rgmii_ref_src, "ref clock enabled sel={d} div={d}", .{ ref.sel, ref.div });

    emac.dumpCnntEmac();
    const cs = emac.readClockState();
    log.line("clk: gmac_ctrl0=0x{x:0>8} mem_clk_force_on={d} rst_clk_tx_n={d} rst_clk_rx_n={d} cactive={d}", .{
        cs.raw,                           @intFromBool(cs.mem_clk_forced), @intFromBool(cs.tx_clk_released),
        @intFromBool(cs.rx_clk_released), @intFromBool(cs.axi_active),
    });

    // 4) DMA 软复位：TX/RX 时钟域都起来后 SWR 才会自清。
    var swr_ok = true;
    emac.resetDma(dma_reset_timeout_us) catch {
        swr_ok = false;
    };
    const after_cs = emac.readClockState();
    log.line("clk: after swr busmode=0x{x:0>8} rst_clk_tx_n={d} rst_clk_rx_n={d}", .{
        hw.readReg(regs.gmac + regs.dma.bus_mode), @intFromBool(after_cs.tx_clk_released),
        @intFromBool(after_cs.rx_clk_released),
    });
    check(swr_ok, "dma swr cleared busmode=0x{x:0>8}", .{hw.readReg(regs.gmac + regs.dma.bus_mode)});
    check(after_cs.tx_clk_released, "tx clock released", .{});
    check(after_cs.rx_clk_released, "rx clock released", .{});

    // 5) MDIO 扫 PHY
    pins.initMdio(pins.default_mdc, pins.default_mdio);
    emac.setCsrDiv(regs.csr_div_safest);
    const found = emac.scanPhy(mdio_timeout_us);
    if (found) |addr| {
        const snap = emac.readPhy(addr, mdio_timeout_us) catch null;
        if (snap) |s| {
            log.line("mdio: phy_addr={d} ident=0x{x:0>8} oui=0x{x:0>6} model={d} rev={d} vendor={s}", .{
                addr, s.ident.raw, s.ident.oui, s.ident.model, s.ident.revision, s.ident.vendor(),
            });
            check(s.ident.raw != 0 and s.ident.raw != 0xFFFF, "phy ident=0x{x:0>8}", .{s.ident.raw});
        } else {
            check(false, "phy read at addr={d}", .{addr});
        }
    } else {
        log.raw("mdio: no PHY responded\n");
        check(false, "phy scan (all 0x0000/0xffff)", .{});
    }

    // 5a) 自协商必须显式 restart：硬件复位后 BMCR.bit9=0，link 永远起不来。
    emac.restartAutoneg(0, mdio_timeout_us) catch |e| {
        log.line("link: restart autoneg failed: {s}", .{@errorName(e)});
    };
    if (emac.waitLink(0, 5_000_000)) |ls| {
        log.line("link: up bmsr=0x{x:0>4} anlpar=0x{x:0>4} ssr=0x{x:0>4} speed={d} dup={d}", .{
            ls.bmsr, ls.anlpar, ls.ssr, (ls.ssr >> 14) & 0x3, @intFromBool((ls.ssr & (1 << 13)) != 0),
        });
    } else {
        log.raw("link: no partner after 5s (cable/switch dependent)\n");
    }

    // 5b) PHY 状态寄存器（link 由外部对端决定，只打印不判失败）
    {
        const dump = [_]struct { r: u5, name: []const u8 }{
            .{ .r = 0x00, .name = "bmcr" },   .{ .r = 0x01, .name = "bmsr" },
            .{ .r = 0x04, .name = "anar" },   .{ .r = 0x05, .name = "anlpar" },
            .{ .r = 0x09, .name = "gbctrl" }, .{ .r = 0x0A, .name = "gbstat" },
        };
        for (dump) |e| {
            const v = emac.mdioRead(0, e.r, mdio_timeout_us) catch 0;
            log.line("phy-reg: {s}=0x{X:0>4}", .{ e.name, v });
        }
        const bmsr = emac.mdioRead(0, 0x01, mdio_timeout_us) catch 0;
        log.line("phy-link: up={d} (BMSR bit2; 0 = 无对端/网线未接)", .{@intFromBool((bmsr & 0x4) != 0)});
    }

    // 6) MAC + DMA + 描述符环，先用 MAC 内部环回验证 TX→RX。
    {
        const mac = [6]u8{ 0x02, 0x00, 0x00, 0x31, 0x00, 0x01 };
        _ = emac.initMacConfig(.m1000, true);
        emac.setMacAddress(mac);
        emac.setLoopback(true);
        _ = emac.initDmaDefaults();
        emac.setRingAddresses();
        emac.initRxRing(true);
        emac.initTxRing();
        emac.startDma();
        const rp = emac.ringPointers();
        log.line("mac: config=0x{x:0>8} ff=0x{x:0>8} te={d} re={d}", .{
            emac.readMacConfig(),            emac.readFrameFilter(),
            @intFromBool(emac.macTeRe().te), @intFromBool(emac.macTeRe().re),
        });
        log.line("dma: tx_base=0x{x:0>8} rx_base=0x{x:0>8} bus_mode=0x{x:0>8} op_mode=0x{x:0>8} status=0x{x:0>8}", .{
            rp.tx, rp.rx, hw.readReg(regs.gmac + regs.dma.bus_mode), emac.opMode(), emac.dmaStatus(),
        });
        check(emac.macTeRe().te and emac.macTeRe().re, "mac te+re enabled", .{});

        const bcast = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
        const frame = emac.buildTestFrame(bcast, mac, 0x88B5, "ch17-loopback-payload");
        const td = emac.txFrame(frame.len, tx_timeout_us) catch |e| blk: {
            const cur_tx = hw.readReg(regs.gmac + regs.dma.cur_tx_desc);
            log.line("tx: loopback failed err={s} cur_desc=0x{x:0>8} cur_buf=0x{x:0>8} status=0x{x:0>8}", .{
                @errorName(e), cur_tx, hw.readReg(regs.gmac + regs.dma.cur_tx_buf), emac.dmaStatus(),
            });
            var k: u32 = 0;
            while (k < 4) : (k += 1) {
                log.line("tx: desc[{d}]=0x{x:0>8}", .{ k, @as(*const u32, @ptrFromInt(@as(usize, cur_tx) + k * 4)).* });
            }
            break :blk 0;
        };
        log.line("tx: len={d} des0=0x{x:0>8}", .{ frame.len, td });
        check(td != 0 and (td & descs.tdes0.own) == 0 and descs.txErrorMask(td) == 0, "tx loopback frame des0=0x{x:0>8}", .{td});

        const rx = emac.rxPoll(tx_timeout_us) catch |e| blk: {
            log.line("rx: poll err={s}", .{@errorName(e)});
            break :blk null;
        };
        if (rx) |f| {
            log.line("rx: len={d} des0=0x{x:0>8} ethertype=0x{x:0>4}", .{
                f.len, f.des0, (@as(u16, f.head[12]) << 8) | f.head[13],
            });
            check(f.len >= 14 and f.head[12] == 0x88 and f.head[13] == 0xB5, "rx loopback frame", .{});
        } else {
            log.raw("rx: no loopback frame\n");
            check(false, "rx loopback frame", .{});
        }
        emac.setLoopback(false);
    }

    // 7) 时钟确实到了 pad：GPIO13=TXC、GPIO14=RXC 的翻转计数。
    {
        var hi13: u32 = 0;
        var hi14: u32 = 0;
        var prev13 = (hw.readReg(regs.gpio + 0x64) >> 13) & 1;
        var prev14 = (hw.readReg(regs.gpio + 0x64) >> 14) & 1;
        var n: u32 = 0;
        while (n < 20_000) : (n += 1) {
            const v = (hw.readReg(regs.gpio + 0x64) >> 13);
            const b13 = v & 1;
            const b14 = (v >> 1) & 1;
            if (b13 != prev13) hi13 += 1;
            if (b14 != prev14) hi14 += 1;
            prev13 = b13;
            prev14 = b14;
        }
        log.line("pad: gpio13_toggles={d} gpio14_toggles={d} (20k samples)", .{ hi13, hi14 });
        check(hi13 > 1_000 and hi14 > 1_000, "txc/rxc toggling", .{});
    }

    log.line("checks: passed={d} failed={d} total={d}", .{ passed, failed, passed + failed });
    return failed == 0;
}
