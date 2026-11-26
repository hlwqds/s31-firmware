//! radio-coex：PHY 与时钟域的归属模型（ADR-003 第 4 节）。
//!
//! Wi-Fi 与 BLE 都要用 PHY 和一部分共享的时钟域。IDF 里这两件事是「引用计数 + 一把锁」：
//!
//!   * `esp_phy_enable(modem)`（`esp_phy/src/phy_init.c:324`）：先拿 `s_phy_access_lock`；
//!     当前没有任何 modem 在用时，才打开公共时钟（`esp_phy_common_clock_enable` +
//!     `phy_module_enable`）并做标定或唤醒；最后把自己的 modem 位置进标志。
//!   * `esp_phy_disable(modem)`（同文件 :408）：清掉自己的 modem 位；自己正是最后一个使用者时，
//!     才关射频、关公共时钟。
//!   * 共存时钟 `PERIPH_COEX_MODULE` 是 BT / Wi-Fi 模块时钟的依赖项
//!     （`modem_clock_impl.c` 里 `BLE_CLOCK_DEPS` 含 `COEXIST`），随模块时钟一起计数。
//!
//! 两个射频各自移植时各写了一套「开时钟 / 关时钟」，会互相清对方的位。典型的一处是
//! `MODEM_LPCON_CLK_CONF_REG`（`LPCON+0x18`）：bit0 是 Wi-Fi 电源域、bit1 是共存、bit2 是 PHY 的
//! I2C 主控。Wi-Fi 侧在 init 之前按 IDF 的值把它对正成 `0x1`（清掉 bit2），而 BLE 的 PHY 恰恰要
//! bit2。
//!
//! 本文件把归属收成一处：**PHY 只有一个归属者**，两个子系统只是提出请求。模型只决定
//! 「什么时候、按什么顺序、做几次」，真正去动寄存器的序列由调用方按返回的动作串行执行。
//!
//! 这里不碰硬件。寄存器序列要等两个射频各自打通后才能上板验证（ADR-003 §4）；在那之前，
//! 本模块只在主机上验证，合并镜像的 section 打印 `LPCON+0x18` 的读数作为对照。

const std = @import("std");

const glue = @import("glue.zig");

pub const Side = glue.Side;

/// 调用方要**串行**执行的动作，顺序有意义。执行期间调用方应持有 PHY 的访问锁
/// （对应 IDF 的 `_lock_acquire(&s_phy_access_lock)`），中途不得穿插另一侧的动作。
pub const Op = enum(u8) {
    /// `coex_module_enable()`：`PERIPH_COEX_MODULE`。放在公共部分：第一个使用者到来时开，
    /// 最后一个离开时关（IDF 是把它算进模块时钟的依赖里，效果相同）。
    coex_clock_on,
    /// 首个使用者到来：`esp_phy_common_clock_enable()` + `phy_module_enable()`，
    /// 然后（IDF 同一函数里）首次标定或从睡眠唤醒。
    phy_common_on,
    /// `phy_set_modem_flag(modem)`：把该侧的 modem 位置进标志。
    modem_on,
    /// `phy_clr_modem_flag(modem)`。
    modem_off,
    /// 最后一个使用者离开：`phy_close_rf()` + `phy_xpd_tsens()` + `esp_phy_common_clock_disable()`。
    phy_common_off,
    /// `coex_module_disable()`。
    coex_clock_off,

    pub fn name(self: Op) [:0]const u8 {
        return @typeInfo(Op).@"enum".field_names[@backingInt(self)];
    }
};

pub const op_count: usize = @typeInfo(Op).@"enum".field_names.len;

/// 一次请求产生的动作表。最长的一种是「最后一个使用者离开」：3 个动作。
pub const Plan = struct {
    ops: [3]Op = undefined,
    len: usize = 0,

    pub fn slice(self: *const Plan) []const Op {
        return self.ops[0..self.len];
    }

    fn push(self: *Plan, op: Op) void {
        std.debug.assert(self.len < self.ops.len);
        self.ops[self.len] = op;
        self.len += 1;
    }
};

pub const Error = error{
    /// 该侧没在请求中就放弃（对应 IDF 的 `phy_clr_modem_flag` 对一个本来就没置的位）。
    NotRequested,
    /// 该侧已经在请求中又请求了一次。模型不动任何状态；调用方可以当成成功。
    AlreadyRequested,
};

pub const Owner = struct {
    wifi: bool = false,
    ble: bool = false,
    /// PHY 的公共部分（公共时钟、标定状态）当前是否已打开。
    phy_on: bool = false,
    /// 共存时钟的引用当前是否已持有。
    coex_on: bool = false,
    /// 每种动作累计排进动作表的次数。公共部分只应随「首个使用者」和「末个使用者」各动一次。
    counts: [op_count]u32 = @splat(0),

    fn requestedAt(self: *const Owner, s: Side) bool {
        return switch (s) {
            .wifi => self.wifi,
            .ble => self.ble,
        };
    }

    fn setRequest(self: *Owner, s: Side, v: bool) void {
        switch (s) {
            .wifi => self.wifi = v,
            .ble => self.ble = v,
        }
    }

    /// 该侧是否在请求 PHY。
    pub fn requested(self: *const Owner, s: Side) bool {
        return self.requestedAt(s);
    }

    /// 当前请求 PHY 的子系统个数（0..2）。
    pub fn users(self: *const Owner) u2 {
        return @as(u2, @intFromBool(self.wifi)) + @as(u2, @intFromBool(self.ble));
    }

    fn note(self: *Owner, p: Plan) void {
        for (p.slice()) |op| self.counts[@backingInt(op)] +%= 1;
    }

    /// 该侧请求 PHY。返回要串行执行的动作。
    ///
    /// 第一个使用者：共存时钟 → PHY 公共部分 → 该侧的 modem 位。
    /// 之后的使用者：只置自己的 modem 位（公共部分不动）。
    pub fn acquire(self: *Owner, s: Side) Error!Plan {
        if (self.requestedAt(s)) return error.AlreadyRequested;
        self.setRequest(s, true);
        var p: Plan = .{};
        if (!self.coex_on) {
            p.push(.coex_clock_on);
            self.coex_on = true;
        }
        if (!self.phy_on) {
            p.push(.phy_common_on);
            self.phy_on = true;
        }
        p.push(.modem_on);
        self.note(p);
        return p;
    }

    /// 该侧放弃 PHY。返回要串行执行的动作。
    ///
    /// 先清自己的 modem 位；自己是最后一个使用者时再关 PHY 公共部分与共存时钟。
    pub fn release(self: *Owner, s: Side) Error!Plan {
        if (!self.requestedAt(s)) return error.NotRequested;
        self.setRequest(s, false);
        var p: Plan = .{};
        p.push(.modem_off);
        if (self.users() == 0) {
            p.push(.phy_common_off);
            self.phy_on = false;
            p.push(.coex_clock_off);
            self.coex_on = false;
        }
        self.note(p);
        return p;
    }
};

/// 一组由多个使用者共享的时钟使能位（典型：`MODEM_LPCON_CLK_CONF_REG`）。
///
/// 每个使用者各自记下自己需要的位，寄存器的目标值是所有使用者的**并集**。一侧放弃时只撤掉
/// 自己的位，不会把别人的也清掉——这正是两边各写一套「读-改-写」时出的问题。
pub fn ClockBits(comptime users_count: usize) type {
    comptime std.debug.assert(users_count > 0);
    return struct {
        const Self = @This();

        masks: [users_count]u32 = @splat(0),

        /// 使用者 `who` 需要的位改成 `mask`（覆盖它之前的位，不影响别人）。
        pub fn set(self: *Self, who: usize, mask: u32) void {
            std.debug.assert(who < users_count);
            self.masks[who] = mask;
        }

        /// 使用者 `who` 不再需要任何位。
        pub fn clear(self: *Self, who: usize) void {
            self.set(who, 0);
        }

        /// 应该写进寄存器的值：所有使用者位的并集。
        pub fn value(self: *const Self) u32 {
            var v: u32 = 0;
            for (self.masks) |m| v |= m;
            return v;
        }

        /// `LPCON+0x18` 的三个位：bit0 Wi-Fi 电源域、bit1 共存、bit2 PHY 的 I2C 主控
        /// （`modem_lpcon_ll.h` 的 `clk_wifipwr_fo` / `clk_coex_fo` / `clk_i2c_mst_fo`）。
        pub const lpcon_wifipwr: u32 = 1 << 0;
        pub const lpcon_coex: u32 = 1 << 1;
        pub const lpcon_i2c_mst: u32 = 1 << 2;
    };
}

/// 板上两个射频共享的时钟字，以及「哪个模块依赖哪些位」（S31）。
///
/// 依据：模块到单元的依赖表在 IDF `components/esp_hw_support/modem/port/esp32s31/modem_clock_impl.c:14-21`；
/// 每个单元写哪一位在同目录的 `modem_clock_hal.c:122-163` 与
/// `components/hal/esp32s31/include/hal/modem_syscon_ll.h`（`clk_wifibb_configure` 写 `0x17b`、
/// `enable_wifibb_44m_clock`、`enable_wifibb_80x1_clock`、`enable_wifi_mac_clock`、`enable_wifi_apb_clock`、
/// `enable_bt_mac_clock`、`enable_bt_bb_clock`、`enable_bt_apb_clock`、`enable_modem_sec_clock`、
/// `enable_modem_sec_apb_clock`、`enable_ble_timer_clock`、`enable_etm_clock`）；位的名字在
/// `components/soc/esp32s31/include/modem/modem_syscon_reg.h` 与 `modem_lpcon_reg.h`。
///
/// IDF 按单元带引用计数地置位，从不整字覆盖这些字。两边的适配层照这张表各管各的位（只置位、不清位）；
/// 合并镜像用 `units` / `unionOf` 算出期望值，去和板上的读数比（`firmware/src/coex_merged.zig`）。
pub const clocks = struct {
    pub const Module = enum(u2) { wifi, ble, phy };

    /// 寄存器地址。
    pub const clk_conf: usize = 0x2010_9C04; // MODEM_SYSCON_CLK_CONF
    pub const clk_conf_force_on: usize = 0x2010_9C08; // MODEM_SYSCON_CLK_CONF_FORCE_ON
    pub const clk_conf1: usize = 0x2010_9C14; // MODEM_SYSCON_CLK_CONF1
    pub const lpcon_clk_conf: usize = 0x2010_F018; // MODEM_LPCON_CLK_CONF
    pub const modem_conf: usize = 0x2058_71E0; // HP_SYS_CLKRST_MODEM_CONF

    /// modem 时钟源的整字取值（`modem_clock_hal.c:124`）：有依赖它的单元在用时是 `0x3D`，都没有时是 `0x25`。
    pub const modem_conf_pll: u32 = 0x3D;
    pub const modem_conf_xtal: u32 = 0x25;

    /// 共享字的一组取值：既是「需要的位」（位集），也是「板上的读数」（整字）。`modem_conf` 是整字取值，
    /// 0 表示不要求，非 0 表示应当等于它。
    pub const State = struct {
        clk_conf: u32 = 0,
        clk_conf_force_on: u32 = 0,
        clk_conf1: u32 = 0,
        lpcon_clk_conf: u32 = 0,
        modem_conf: u32 = 0,

        fn pllOn(self: State) bool {
            return (self.modem_conf & 0x3F) == modem_conf_pll;
        }

        /// 取并集：位集相或，时钟源的要求有则保留。
        pub fn orWith(self: State, o: State) State {
            return .{
                .clk_conf = self.clk_conf | o.clk_conf,
                .clk_conf_force_on = self.clk_conf_force_on | o.clk_conf_force_on,
                .clk_conf1 = self.clk_conf1 | o.clk_conf1,
                .lpcon_clk_conf = self.lpcon_clk_conf | o.lpcon_clk_conf,
                .modem_conf = @max(self.modem_conf, o.modem_conf),
            };
        }

        /// `got` 是否包含这组位：逐字「有位」比较，多出来的位不算错。
        pub fn coveredBy(self: State, got: State) bool {
            return (got.clk_conf & self.clk_conf) == self.clk_conf and
                (got.clk_conf_force_on & self.clk_conf_force_on) == self.clk_conf_force_on and
                (got.clk_conf1 & self.clk_conf1) == self.clk_conf1 and
                (got.lpcon_clk_conf & self.lpcon_clk_conf) == self.lpcon_clk_conf and
                (self.modem_conf == 0 or got.pllOn());
        }

        /// 缺的位（给日志看）。
        pub fn missing(self: State, got: State) State {
            return .{
                .clk_conf = self.clk_conf & ~got.clk_conf,
                .clk_conf_force_on = self.clk_conf_force_on & ~got.clk_conf_force_on,
                .clk_conf1 = self.clk_conf1 & ~got.clk_conf1,
                .lpcon_clk_conf = self.lpcon_clk_conf & ~got.lpcon_clk_conf,
                .modem_conf = if (self.modem_conf != 0 and !got.pllOn()) self.modem_conf else 0,
            };
        }
    };

    /// 一个模块依赖的位（IDF 的依赖表，逐单元换成位）。
    pub fn units(m: Module) State {
        return switch (m) {
            // WIFI_CLOCK_DEPS：WIFI_BB(0x17b) | WIFI_BB_44M(2) | WIFI_BB_80X1(7) | WIFI_MAC(9) | WIFI_APB(10)。
            // COEXIST 单元（LPCON bit1）不列：Wi-Fi start 之后它会回到关，不当判据。
            // 时钟源（`modem_conf`）不要求：PLL 源只在 PHY 初始化与标定期间开着，之后被释放——IDF 自己的 station
            // 镜像扫描结束后的读数就是 `0x25`（`logs/wifi-idf-oracle-regdump-boot.log`），本仓的 Wi-Fi 路径相同。
            .wifi => .{ .clk_conf1 = 0x7FF, .lpcon_clk_conf = 1 << 0 },
            // BLE_CLOCK_DEPS + BT_APB_CLOCK_DEPS：BT_APB（CLK_CONF1 bit16 与 CLK_CONF bit28）、BT_I154_COMMON_BB(17)、
            // BLE_MAC(18)、WIFI_BB_80X1(7)、ETM(22)、BT_PERIPHERAL（modem_sec_en / ecb / ccm / bah = 25-29、
            // ble_timer = 30）、COEXIST（LPCON bit1）；LP timer 时钟（LPCON bit3）是 BLE 调度器的时基。
            .ble => .{
                .clk_conf = 0x7E40_0000,
                .clk_conf1 = 0x0007_0080,
                .lpcon_clk_conf = (1 << 1) | (1 << 3),
                .modem_conf = modem_conf_pll,
            },
            // PHY_CLOCK_DEPS：MODEM_ADC_COMMON_FE（fe_80m 13、fe_apb 15）、MODEM_PRIVATE_FE（fe_160m 14、
            // fe_pwdet 19、fe_adc 20、fe_dac 21）、I2C_MASTER（LPCON bit2）。`clk_conf` 的三位是 PHY 打开时写的
            // 模拟前端配置（pwdet 分频、I2C 主控 160M 选择、data dump 选择）。
            .phy => .{
                .clk_conf = 0x0020_1002,
                .clk_conf1 = 0x0038_E000,
                .lpcon_clk_conf = 1 << 2,
                .modem_conf = 0,
            },
        };
    }

    /// 几个模块都开着时，共享字里应当有的位。
    pub fn unionOf(mods: []const Module) State {
        var w: State = .{};
        for (mods) |m| w = w.orWith(units(m));
        return w;
    }
};

// ---------------------------------------------------------------------------
// 主机测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectPlan(want: []const Op, got: Plan) !void {
    testing.expectEqual(want.len, got.len) catch |e| {
        for (got.slice()) |op| std.debug.print(" got:{s}", .{op.name()});
        return e;
    };
    for (want, got.slice()) |w, g| try testing.expectEqual(w, g);
}

test "owner: 第一个使用者开公共部分，第二个只置自己的位" {
    var o: Owner = .{};
    try expectPlan(&.{ .coex_clock_on, .phy_common_on, .modem_on }, try o.acquire(.wifi));
    try testing.expect(o.phy_on and o.coex_on and o.requested(.wifi) and !o.requested(.ble));
    try expectPlan(&.{.modem_on}, try o.acquire(.ble));
    try testing.expectEqual(@as(u2, 2), o.users());
    try testing.expectEqual(@as(u32, 1), o.counts[@backingInt(Op.phy_common_on)]);
    try testing.expectEqual(@as(u32, 1), o.counts[@backingInt(Op.coex_clock_on)]);
}

test "owner: 顺序反过来（BLE 先）得到同样的结构" {
    var o: Owner = .{};
    try expectPlan(&.{ .coex_clock_on, .phy_common_on, .modem_on }, try o.acquire(.ble));
    try expectPlan(&.{.modem_on}, try o.acquire(.wifi));
}

test "owner: 中间的使用者离开不动公共部分，最后一个离开才关" {
    var o: Owner = .{};
    _ = try o.acquire(.wifi);
    _ = try o.acquire(.ble);
    try expectPlan(&.{.modem_off}, try o.release(.wifi));
    try testing.expect(o.phy_on and o.coex_on and o.requested(.ble));
    try expectPlan(&.{ .modem_off, .phy_common_off, .coex_clock_off }, try o.release(.ble));
    try testing.expect(!o.phy_on and !o.coex_on);
    try testing.expectEqual(@as(u2, 0), o.users());
}

test "owner: 全部离开后再请求，公共部分重新走一遍" {
    var o: Owner = .{};
    _ = try o.acquire(.wifi);
    _ = try o.release(.wifi);
    try expectPlan(&.{ .coex_clock_on, .phy_common_on, .modem_on }, try o.acquire(.ble));
    try testing.expectEqual(@as(u32, 2), o.counts[@backingInt(Op.phy_common_on)]);
    try testing.expectEqual(@as(u32, 1), o.counts[@backingInt(Op.phy_common_off)]);
    _ = try o.release(.ble);
    try testing.expectEqual(@as(u32, 2), o.counts[@backingInt(Op.phy_common_off)]);
}

test "owner: 重复请求与无请求的放弃被拒，且不改状态、不排动作" {
    var o: Owner = .{};
    _ = try o.acquire(.wifi);
    const before = o;
    try testing.expectError(error.AlreadyRequested, o.acquire(.wifi));
    try testing.expectError(error.NotRequested, o.release(.ble));
    try testing.expectEqual(before.wifi, o.wifi);
    try testing.expectEqual(before.ble, o.ble);
    try testing.expectEqual(before.phy_on, o.phy_on);
    try testing.expectEqual(before.coex_on, o.coex_on);
    try testing.expectEqual(before.counts, o.counts);
}

test "owner: 公共部分的开、关次数等于使用者数从 0 变 1、从 1 变 0 的次数" {
    var o: Owner = .{};
    var was_zero = true;
    var ups: u32 = 0;
    var downs: u32 = 0;
    var prng = std.Random.DefaultPrng.init(0x5aa5);
    const rand = prng.random();
    var step: usize = 0;
    while (step < 200) : (step += 1) {
        const side: Side = if (rand.boolean()) .wifi else .ble;
        if (rand.boolean()) {
            _ = o.acquire(side) catch {};
        } else {
            _ = o.release(side) catch {};
        }
        const zero = o.users() == 0;
        if (was_zero and !zero) ups += 1;
        if (!was_zero and zero) downs += 1;
        was_zero = zero;
        try testing.expectEqual(o.users() != 0, o.phy_on);
        try testing.expectEqual(o.users() != 0, o.coex_on);
    }
    try testing.expect(ups > 8 and downs > 8);
    try testing.expectEqual(ups, o.counts[@backingInt(Op.phy_common_on)]);
    try testing.expectEqual(downs, o.counts[@backingInt(Op.phy_common_off)]);
    try testing.expectEqual(ups, o.counts[@backingInt(Op.coex_clock_on)]);
    try testing.expectEqual(downs, o.counts[@backingInt(Op.coex_clock_off)]);
}

test "owner: 动作表的长度不超过它声明的容量（随机序列里没有溢出）" {
    // `push` 里的断言在 Debug 下会直接让越界失败；这里只补一条正面的长度读数。
    var o: Owner = .{};
    _ = try o.acquire(.ble);
    const p = try o.release(.ble);
    try testing.expectEqual(@as(usize, 3), p.slice().len);
    try testing.expectEqualStrings("modem_off", p.slice()[0].name());
    try testing.expectEqualStrings("coex_clock_off", p.slice()[2].name());
}

test "clock bits: 目标值是并集，一侧放弃只撤自己的位" {
    var cb: ClockBits(3) = .{};
    cb.set(0, ClockBits(3).lpcon_wifipwr);
    try testing.expectEqual(@as(u32, 0x1), cb.value());
    cb.set(2, ClockBits(3).lpcon_i2c_mst);
    try testing.expectEqual(@as(u32, 0x5), cb.value());
    cb.clear(0);
    try testing.expectEqual(@as(u32, 0x4), cb.value());
    cb.clear(2);
    try testing.expectEqual(@as(u32, 0x0), cb.value());
}

test "clock bits: LPCON+0x18 按 IDF 实测的三个取值走（0x1 → 0x7 → 0x1）" {
    // Wi-Fi 探针注释里的 IDF 实测（station 例程）：init 之后 `LPCON+18 = 0x1`，
    // start 期间是 `0x7`（bit0 wifipwr / bit1 coex / bit2 i2c_mst），之后回到 `0x1`。
    var cb: ClockBits(4) = .{};
    cb.set(0, ClockBits(4).lpcon_wifipwr); // Wi-Fi init：只要自己的电源域
    try testing.expectEqual(@as(u32, 0x1), cb.value());
    var o: Owner = .{};
    for ((try o.acquire(.wifi)).slice()) |op| {
        // 归属模型与位图怎么对接：公共部分打开时 PHY 认领 I2C 主控位，共存时钟认领共存位。
        switch (op) {
            .coex_clock_on => cb.set(1, ClockBits(4).lpcon_coex),
            .phy_common_on => cb.set(2, ClockBits(4).lpcon_i2c_mst),
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 0x7), cb.value());
    // BLE 随后也来用 PHY：它需要的还是同一个 I2C 主控位，值不变。
    const ble_in = try o.acquire(.ble);
    try testing.expectEqual(@as(usize, 1), ble_in.slice().len);
    try testing.expectEqual(Op.modem_on, ble_in.slice()[0]);
    try testing.expectEqual(@as(u32, 0x7), cb.value());
    // 两边都离开：公共部分关掉，PHY 与共存时钟各自撤位，只剩 Wi-Fi 的电源域。
    _ = try o.release(.ble);
    for ((try o.release(.wifi)).slice()) |op| {
        switch (op) {
            .phy_common_off => cb.clear(2),
            .coex_clock_off => cb.clear(1),
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 0x1), cb.value());
}

test "clocks: Wi-Fi、PHY、BLE 三组的位互不覆盖，共用的只有 wifibb_80x1" {
    const w = clocks.units(.wifi);
    const p = clocks.units(.phy);
    const b = clocks.units(.ble);
    // 每组自己的位
    try testing.expectEqual(@as(u32, 0x17B | (1 << 2) | (1 << 7) | (1 << 9) | (1 << 10)), w.clk_conf1);
    try testing.expectEqual(@as(u32, (1 << 13) | (1 << 14) | (1 << 15) | (1 << 19) | (1 << 20) | (1 << 21)), p.clk_conf1);
    try testing.expectEqual(@as(u32, (1 << 7) | (1 << 16) | (1 << 17) | (1 << 18)), b.clk_conf1);
    try testing.expectEqual(@as(u32, (1 << 22) | (1 << 25) | (1 << 26) | (1 << 27) | (1 << 28) | (1 << 29) | (1 << 30)), b.clk_conf);
    // 互不覆盖：任何一组的位不落在另一组里；Wi-Fi 与 BLE 只共用 bit7
    try testing.expectEqual(@as(u32, 0), w.clk_conf1 & p.clk_conf1);
    try testing.expectEqual(@as(u32, 0), w.clk_conf1 & b.clk_conf1 & ~@as(u32, 1 << 7));
    try testing.expectEqual(@as(u32, 0x80), w.clk_conf1 & b.clk_conf1);
    try testing.expectEqual(@as(u32, 0), (w.clk_conf1 | p.clk_conf1) & b.clk_conf1 & ~@as(u32, 1 << 7));
    try testing.expectEqual(@as(u32, 0), p.clk_conf1 & b.clk_conf1);
    try testing.expectEqual(@as(u32, 0), p.clk_conf1 & 0x0007_0000); // PHY 前端不碰 BT 的三位
    try testing.expectEqual(@as(u32, 0), (w.clk_conf | p.clk_conf) & b.clk_conf);
    try testing.expectEqual(@as(u32, 0), w.lpcon_clk_conf & p.lpcon_clk_conf);
    try testing.expectEqual(@as(u32, 0), (w.lpcon_clk_conf | p.lpcon_clk_conf) & b.lpcon_clk_conf);
}

test "clocks: 并集包含每个成员；整字覆盖掉的位会被判成缺位" {
    const all = clocks.unionOf(&.{ .wifi, .phy, .ble });
    // 只置位之后，板上应当读到的值（多出来的 fe_20m / fe_40m 是 BLE 移植层额外开的，不算错）
    const good = clocks.State{ .clk_conf = 0x7E60_1002, .clk_conf1 = 0x003F_FFFF, .lpcon_clk_conf = 0x0F, .modem_conf = 0x3D };
    try testing.expect(all.coveredBy(good));
    try testing.expectEqual(clocks.State{}, all.missing(good));

    // 旧写法一：BLE 的 init 整字覆盖 CLK_CONF1——Wi-Fi 的基带、MAC、APB 位没了（对照 C 的读数）。
    const clobbered = clocks.State{ .clk_conf = 0x7E60_1002, .clk_conf1 = 0x003F_F880, .lpcon_clk_conf = 0x0F, .modem_conf = 0x3D };
    try testing.expect(!all.coveredBy(clobbered));
    const miss = all.missing(clobbered);
    try testing.expectEqual(@as(u32, 0x77F), miss.clk_conf1);
    try testing.expectEqual(@as(u32, 0), miss.clk_conf);

    // 旧写法二：事后按快照整字写回——Wi-Fi 的位回来了，BLE 的全没了（时钟源也跟着回到 XTAL）。
    const restored = clocks.State{ .clk_conf = 0x0020_1002, .clk_conf1 = 0x0038_E7FF, .lpcon_clk_conf = 0x05, .modem_conf = 0x25 };
    try testing.expect(!all.coveredBy(restored));
    const miss2 = all.missing(restored);
    try testing.expectEqual(@as(u32, 0x70000), miss2.clk_conf1);
    try testing.expectEqual(@as(u32, 0x7E40_0000), miss2.clk_conf);
    try testing.expectEqual(@as(u32, 0x0A), miss2.lpcon_clk_conf);
    try testing.expectEqual(@as(u32, 0x3D), miss2.modem_conf);

    // 并集对每个成员都是超集：只开其中一部分的读数，不会被要求包含没开的模块的位。
    const wifi_only = clocks.State{ .clk_conf = 0x0020_1002, .clk_conf1 = 0x0038_E7FF, .lpcon_clk_conf = 0x05, .modem_conf = 0x25 };
    try testing.expect(clocks.unionOf(&.{ .wifi, .phy }).coveredBy(wifi_only));
    try testing.expect(!all.coveredBy(wifi_only));
}
