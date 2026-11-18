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
    const get_romfuncs = @extern(*const fn () callconv(.c) void, .{ .name = "phy_get_romfunc_addr" });
    const phy_enable = @extern(*const fn (u32) callconv(.c) void, .{ .name = "esp_phy_enable" });
    get_romfuncs(); // 填 `g_phyFuns`（PHY 函数表）
    phy_enable(2); // PHY_MODEM_BT
}
