//! 只读地暴露归档的两个内部符号，并补调那个被守卫跳过的写者。
//!
//! ## 为什么需要这一层
//!
//! 板侧实测（PC 采样 + 直接读全局）：
//!
//! - `r_btdm_task_init` 会调 `r_sym_bt_XPuq`，后者把 `a1 = *(.LANCHOR0)` 当地址，
//!   从 `a1` 开始做 `sw zero, …` 的零填充，一直写到 `0x2010B100`。
//! - `.LANCHOR0` 与 `r_sym_bt_d3D3sk5KewclELfrD5xa` 是同一个 4 字节 BSS 全局。
//! - 它唯一的写者是 `r_sym_bt_fqmZkUKgd5GE6m7i2YFG`：`P = wr_btdm_osal_malloc(...)`。
//! - 那个调用被 `if (*(*s0 + 8) != 0)` 守卫，而该字段在裸机配置下是 0
//!   ⇒ 写者被跳过 ⇒ `P` 停在 NULL ⇒ `Xpuq` 从**地址 0** 开始写约 1.34 亿次。
//!
//! 表现是"无 fault、无 panic、无声卡死"，与真正的总线挂死无法从日志上区分。
//!
//! ## 主机侧
//!
//! 这些符号只存在于固件镜像里，`zig build test` 跑在主机上时不能引用它们，
//! 所以这里按目标条件编译：主机侧退化为常量，供纯逻辑用例使用。

const builtin = @import("builtin");

const on_target = builtin.target.os.tag == .freestanding;

/// 锚点全局的当前值。`0` 表示 `Xpuq` 会用 NULL 作基址零填充。
pub fn get() u32 {
    if (!on_target) return 0;
    return @extern(*volatile u32, .{ .name = "r_sym_bt_d3D3sk5KewclELfrD5xa" }).*;
}

/// **`r_sym_bt_OkE7` 读的那个锚点**（`21.o` 的 `.LANCHOR0`，最终镜像里是具名
/// BSS 全局）。`OkE7` 进门就 `beqz`：为 0 直接返回 -1，不做任何初始化
/// ⇒ 它是**消费者**，发布者在它之前（IDF 里由 init 链的前几步完成）。
pub fn okE7Anchor() u32 {
    if (!on_target) return 0;
    return @extern(*volatile u32, .{ .name = "r_sym_bt_r4auAKWSAFwgQarMHZCc" }).*;
}

/// 写入 `OkE7` 锚点。
///
/// **为什么必须由我们写**：`r_btdm_task_init` 在 `mutex_pend` 返回后紧接着
///
/// ```asm
/// lw   a5, 0(s1)     ; a5 = 锚点值
/// sb   a4, 0(a5)     ; *(u8*)a5 = 1        ← 锚点为 0 时就是**向地址 0 写字节**
/// ```
///
/// 地址 0 的 store 在这块芯片上不产生异常、只让事务不退休 ⇒ 无 fault、无 PC 采样、
/// 后续 hook/建任务全都不再发生 —— 与板侧观测逐条吻合。
/// 因此锚点必须在 step 6 之前指向一段**可写内存**；`OkE7` 的守卫还要求 `*(anchor+8) != 0`。
pub fn setOkE7Anchor(v: u32) void {
    if (!on_target) return;
    @extern(*volatile u32, .{ .name = "r_sym_bt_r4auAKWSAFwgQarMHZCc" }).* = v;
}

/// `7.o` 的锚点：`r_sym_bt_BOhff`（建任务辅助）的守卫。
pub fn bohffAnchor() u32 {
    if (!on_target) return 0;
    return @extern(*volatile u32, .{ .name = "r_sym_bt_6Q68KSwuQQP4VjQGqiWa" }).*;
}
pub fn setBOhffAnchor(v: u32) void {
    if (!on_target) return;
    @extern(*volatile u32, .{ .name = "r_sym_bt_6Q68KSwuQQP4VjQGqiWa" }).* = v;
}

/// 补调写者（`P = wr_btdm_osal_malloc(...)`）。返回归档给的 `rc`。
/// 幂等性由调用方保证：只在 `get() == 0` 时调。
pub fn populate() c_int {
    if (!on_target) return 0;
    const f = @extern(*const fn () callconv(.c) c_int, .{ .name = "r_sym_bt_fqmZkUKgd5GE6m7i2YFG" });
    return f();
}

/// 调 **IDF 真实实现** 的 PHY 使能链（由 `-Dphy-src-objs` 链入）。
pub fn initPhy() void {
    if (!on_target) return;
    // **5F7E 入口标记**：initPhy 已进入（get_romfuncs 之前）
    {
        const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
        const ese = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
        var rec: [4]u32 = .{ 0xADC0_5F7E, 0x2010_9C08, 0x2010_F01C, 0x2010_9400 };
        rec[1] = @as(*volatile u32, @ptrFromInt(0x2010_9C08)).*;
        rec[2] = @as(*volatile u32, @ptrFromInt(0x2010_F01C)).*;
        rec[3] = @as(*volatile u32, @ptrFromInt(0x2010_9400)).*;
        _ = ese(0x18E000 / 0x1000);
        // **CLIC[25] 门控**（防 flash 写期中断打进 XIP trap ⇒ 缓存关 ⇒ 挂死）：
        // 清 nmies(bit3)+IE(bit8)，写完恢复。T0 采样器已武装、125µs 一发，
        // 不门控则与 ms 级 flash 擦写必然相撞。
        const clic25: usize = 0x1080_1000 + 25 * 4;
        const gsaved: u32 = @as(*volatile u32, @ptrFromInt(clic25)).*;
        @as(*volatile u32, @ptrFromInt(clic25)).* = gsaved & ~@as(u32, 0x108);

        _ = esw(0x18E000, &rec, 16);
        @as(*volatile u32, @ptrFromInt(clic25)).* = gsaved;
    }
    const get_romfuncs = @extern(*const fn () callconv(.c) void, .{ .name = "phy_get_romfunc_addr" });
    get_romfuncs(); // 填 `g_phyFuns`（PHY 函数表）—— 实测确实被填写
    // **锁绕行**（2026-11-20 单变量）：esp_phy_enable 入口 _lock_acquire（FreeRTOS
    // 临界锁）与协作式裸机不兼容（EXEC 断点实证：未到 common_clock 即挂死）。
    // 改为直调其有效内部步骤——均为纯寄存器写，无锁：
    //   ① modem_clock_module_enable(9)=PERIPH_PHY_MODULE（deps 含 FE/ADC/I2C_ANA_MST）
    //   ② modem_clock_module_enable(13)=PERIPH_PHY_CALIBRATION_MODULE
    //   ③ esp_phy_load_cal_and_init()（内部 register_chipv7_phy FULL 校准，
    //      含 FE 测量环——此刻 FE 时钟已在①②打开）
    const mce = @extern(*const fn (modem: c_int) callconv(.c) void, .{ .name = "modem_clock_module_enable" });
    const esw = @extern(*const fn (u32, [*]const u32, u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_write" });
    const ese = @extern(*const fn (u32) callconv(.c) c_int, .{ .name = "esp_rom_spiflash_erase_sector" });
    // **5F7F 前置标记**：get_romfuncs 之后、mce(9) 之前——分离"get_romfuncs 挂"
    // 与"mce(9) 挂"（上一轮 0x18E000 残留 fee8，两者不可分）。
    {
        var rec: [4]u32 = .{ 0xADC0_5F7F, 0x20100450, 0x20109C14, 0x201098BC };
        rec[1] = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
        rec[2] = @as(*volatile u32, @ptrFromInt(0x2010_9C14)).*; // clk_conf1（FE 位自证）
        rec[3] = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
        _ = ese(0x18E000 / 0x1000);
        // **CLIC[25] 门控**（防 flash 写期中断打进 XIP trap ⇒ 缓存关 ⇒ 挂死）：
        // 清 nmies(bit3)+IE(bit8)，写完恢复。T0 采样器已武装、125µs 一发，
        // 不门控则与 ms 级 flash 擦写必然相撞。
        const clic25: usize = 0x1080_1000 + 25 * 4;
        const gsaved: u32 = @as(*volatile u32, @ptrFromInt(clic25)).*;
        @as(*volatile u32, @ptrFromInt(clic25)).* = gsaved & ~@as(u32, 0x108);

        _ = esw(0x18E000, &rec, 16);
        @as(*volatile u32, @ptrFromInt(clic25)).* = gsaved;
    }
    // **UART 无关 flash 标记**（pre-enable 窗口安全）：哪个 mce/load_cal 没回来，
    // 0x18E000 的标记就停在哪个编号（80=mce9 后 81=mce13 后 82=load_cal 后）。
    _ = mce(9);
    {
        var rec: [4]u32 = .{ 0xADC0_5F80, 0x20100450, 0x201008D0, 0x201098BC };
        rec[1] = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
        rec[2] = @as(*volatile u32, @ptrFromInt(0x2010_08D0)).*;
        rec[3] = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
        _ = ese(0x18E000 / 0x1000);
        // **CLIC[25] 门控**（防 flash 写期中断打进 XIP trap ⇒ 缓存关 ⇒ 挂死）：
        // 清 nmies(bit3)+IE(bit8)，写完恢复。T0 采样器已武装、125µs 一发，
        // 不门控则与 ms 级 flash 擦写必然相撞。
        const clic25: usize = 0x1080_1000 + 25 * 4;
        const gsaved: u32 = @as(*volatile u32, @ptrFromInt(clic25)).*;
        @as(*volatile u32, @ptrFromInt(clic25)).* = gsaved & ~@as(u32, 0x108);

        _ = esw(0x18E000, &rec, 16);
        @as(*volatile u32, @ptrFromInt(clic25)).* = gsaved;
    }
    mce(13);
    {
        var rec: [4]u32 = .{ 0xADC0_5F81, 0x20100450, 0x2010047C, 0x201098BC };
        rec[1] = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
        rec[2] = @as(*volatile u32, @ptrFromInt(0x2010_047C)).*;
        rec[3] = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
        _ = ese(0x18E000 / 0x1000);
        _ = esw(0x18E000, &rec, 16);
    }
    const load_cal = @extern(*const fn () callconv(.c) void, .{ .name = "esp_phy_load_cal_and_init" });
    load_cal();
    {
        var rec: [4]u32 = .{ 0xADC0_5F82, 0x20100450, 0x2010047C, 0x201098BC };
        rec[1] = @as(*volatile u32, @ptrFromInt(0x2010_0450)).*;
        rec[2] = @as(*volatile u32, @ptrFromInt(0x2010_047C)).*;
        rec[3] = @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
        _ = ese(0x18E000 / 0x1000);
        _ = esw(0x18E000, &rec, 16);
    }
    @import("osal_kit").osal.logPublic("bt phy: lock-free path done (mce 9/13 + load_cal)", .{});
}

/// `esp_phy_enable(modem)` 的**显式实现**（替代 `rom_syms.ld` 里那个冻结的伪造地址）。
///
/// **它不做 PHY 标定** —— 真正的标定在 IDF 的 `libphy.a`（`esp_phy_load_cal_and_init`）
/// 里，本构建没有链入。这里只做我们确实拥有的部分：
/// PHY 域时钟已由 `porting.phyDomainEnable()` 打开，函数表已由 ROM 填好。
///
/// 保留为**真实函数**而不是空桩：日志说明"未标定"，让后续任何失败都是**真实失败**，
/// 而不是继续追一个指向别人函数体中间的地址。
pub fn espPhyEnable(modem: u32) callconv(.c) void {
    // **真正的使能序列**（对齐 IDF `esp_phy_enable` 中我们确实拥有的部分）。
    // 只有首次标定（`register_chipv7_phy`，需要 phy_init_data/cal_data）保持缺失，
    // 这一条在日志里明确说出来，避免后续 RF 失败被误归因。
    const icg: *volatile u32 = @ptrFromInt(0x2010_9C0C);
    icg.* = 0x6464_6400; // ICG 位图解除门控
    const wifi_enable_set = @extern(*const fn (u8) callconv(.c) void, .{ .name = "phy_wifi_enable_set" });
    wifi_enable_set(1);
    // BB idle check/看门狗默认开（139 ms 超时会复位 BB，MAC 状态机永不排空）。
    // ⚠ **必须用 ROM 名 `phy_set_bb_wdg`**（`rom_syms.ld:425` = `0x2f801478`）。
    // 裸名 `set_bb_wdg` 在 blob 里**另有一个函数**（`T 0x40060af4`）——
    // 链接会成功，但调到的不是 ROM 那个 ⇒ BB 看门狗根本没关。
    const bb_wdg = @extern(*const fn (bool, bool, u16, u16, bool, bool, bool) callconv(.c) void, .{ .name = "phy_set_bb_wdg" });
    bb_wdg(true, false, 0x18, 0xaa, false, false, false);
    // 重申 PHY 时钟位（MODEM_SYSCON.CLK_CONF1）
    const conf1: *volatile u32 = @ptrFromInt(0x2010_9C14);
    conf1.* |= (1 << 2) | (1 << 3) | (1 << 7) | (1 << 9) |
        (1 << 13) | (1 << 14) | (1 << 15) | (1 << 19) | (1 << 20) | (1 << 21);
    @import("osal_kit").osal.logPublic(
        "bt phy: enable modem={d} icg+phy_wifi_enable_set+bb_wdg+conf1 done",
        .{modem},
    );

    // **PHY 首次标定**（开放项 3b 的第一次实验）。
    // IDF 的 hxx 变体就是 `register_chipv7_phy(NULL, NULL, PHY_RF_CAL_FULL)`
    // （`phy_init_esp32hxx.c:117`）⇒ **NULL 是合法形式**，所以先试最便宜的那种。
    // 符号在 `.flash.text`（`0x40061c56`，`T`）⇒ 代码已在镜像里，不是"缺 IRAM 代码"。
    // ⚠ 顺序：IDF 的 `esp_phy_load_cal_and_init` 是在 `esp_phy_enable` 的
    // 模块/时钟使能**之后**才调标定 ⇒ 本调用放在使能序列之后（见下方）。
    const calib = @extern(
        *const fn (?*const anyopaque, ?*anyopaque, u32) callconv(.c) c_int,
        .{ .name = "register_chipv7_phy" },
    );
    // ⚠ **`init_data = NULL` 在本芯片上会崩**（实测：`register_chipv7_phy_init_param`
    // 内部解引用 NULL 并对 `0x0C` 执行 store ⇒ cause=7 store access fault，`mepc=0x40061b8a`）。
    // IDF 的 hxx 变体能用 NULL，但**这个芯片不行** ⇒ 必须传真实的 128 字节表。
    const init_tbl = @extern(*const [128]u8, .{ .name = "phy_init_data" });
    // ✅ **实测 rc=0（成功）**：`init_data` = `phy_init_data`（128 B），
    // `cal_data` = 静态 1904 B 缓冲，mode = 2（`PHY_RF_CAL_FULL`）。
    // ⚠ **`cal_data = NULL` 会崩**：`phy_rfcal_data_sub_new` 会对 `cal+0x0c` 执行 store
    // ⇒ `mtval=0x0c`、cause=7。必须给一块真缓冲（1904 B = `esp_phy_calibration_data_t`）。
    // **① 先把 MAC 写进 cal 缓冲的 `[4..10]`**（`esp_phy_calibration_data_t` =
    // `version[4] + mac[6] + opaque[1894]`）。
    // IDF 的 `esp_phy_load_cal_and_init()` 在调 `register_chipv7_phy` **之前**做
    // `memcpy(cal_data->mac, sta_mac, 6)`。我们此前留零 ⇒ 标定结果**内部不一致** ⇒
    // IDF 的一致性检查（`ESP_CAL_DATA_CHECK_FAIL`）会判为"没有有效标定"。
    // 这里用 controller 已经携带的地址（step 14 设置），保持一致。
    const mac: [6]u8 = .{ 0x01, 0xbb, 0x00, 0x00, 0x00, 0x02 };
    @memcpy(phy_cal_buf[4..10], &mac);

    const cal_rc = calib(@ptrCast(init_tbl), @ptrCast(&phy_cal_buf), 2); // PHY_RF_CAL_FULL
    // **验证 `rc=0` 是否真的做了事**：`rc=0` 也可能只是"接受但没产出"。
    // ① cal 缓冲是否被写入（`esp_phy_calibration_data_t` 的 opaque 从 +10 开始）
    // ② `0x2010B000` 是否变为可读（README 里记的成功判据）
    const cal_written: u32 = @as(u32, phy_cal_buf[10]) | (@as(u32, phy_cal_buf[11]) << 8) |
        (@as(u32, phy_cal_buf[12]) << 16) | (@as(u32, phy_cal_buf[13]) << 24);
    var fe_ok: u8 = 0;
    var fe_val: u32 = 0;
    if (cal_rc == 0) {
        fe_val = (@as(*volatile u32, @ptrFromInt(0x2010_B000))).*;
        fe_ok = 1;
    }
    @import("osal_kit").osal.logPublic(
        "bt phy: calib rc={d} cal[10..14]=0x{x} fe_readable={d} fe=0x{x}",
        .{ cal_rc, cal_written, fe_ok, fe_val },
    );
}

/// `esp_phy_calibration_data_t`（1904 B：`version[4] + mac[6] + opaque[1894]`）。
/// 放在 `.bss`，**不能放栈上**。零初始化即可（`PHY_RF_CAL_FULL` 会重填）。
var phy_cal_buf: [1904]u8 align(16) = @splat(0);
