//! `ext_funcs_t` —— controller 侧用它拿 **malloc/free/rand/assert**（`ble.c:97-109`）。
//!
//! 这张表**不能跳过**：跳过等于 controller 没有分配器，init 必然失败。
//! rv32 上正好 **40 字节**：`u32 ext_version` + 8 个函数指针 + `u32 magic`，无填充。
//!
//! ⚠ 两个容易抄错的细节：
//! 1. `_osi_assert` 的参数顺序是 **`(行号, 函数名, p1, p2)`** —— 与 `__assert_func`
//!    的 `(文件, 行号, 函数, 表达式)` **相反**，别照抄。
//! 2. 三个 ECC 项给**返回 -1 的桩**即可：IDF 自己在 `CONFIG_BT_LE_SM_LEGACY/SC` 没开时
//!    也是 `return -1`（`ble.c:506-522`），`_ecc_aes_cmac` 转发的是 NimBLE **host** 的
//!    `ble_sm_ecc_aes_cmac`（controller-only 没有 host）。配对/加密不在
//!    HCI Reset / Read Local Version 这条路上 ⇒ 不需要任何 ROM ECC。
const std = @import("std");
const builtin = @import("builtin");
const osal = @import("osal_kit").osal;

pub const EXT_FUNC_VERSION: u32 = 0x20250819;
pub const EXT_FUNC_MAGIC_VALUE: u32 = 0xA5A5A5A5;

pub const ExtFuncs = extern struct {
    ext_version: u32,
    malloc: *const fn (size: u32, flags: u32) callconv(.c) ?*anyopaque,
    free: *const fn (p: ?*anyopaque) callconv(.c) void,
    osi_assert: *const fn (ln: u32, fn_name: ?[*:0]const u8, p1: u32, p2: u32) callconv(.c) void,
    os_random: *const fn () callconv(.c) u32,
    ecc_gen_key_pair: *const fn (public: ?[*]u8, priv: ?[*]u8) callconv(.c) c_int,
    ecc_gen_dh_key: *const fn (
        remote_pub_x: ?[*]const u8,
        remote_pub_y: ?[*]const u8,
        local_priv: ?[*]const u8,
        dhkey: ?[*]u8,
    ) callconv(.c) c_int,
    esp_reset_rpa_moudle: *const fn () callconv(.c) void,
    ecc_aes_cmac: *const fn (key: ?[*]const u8, in: ?[*]const u8, len: usize, out: ?[*]u8) callconv(.c) c_int,
    magic: u32,
};

comptime {
    // rv32 上是 4 + 8×4 + 4 = **40**（与 C 完全一致）；主机（8 字节指针）上是 72。
    // 断言按指针宽度写，另在 32 位目标上额外钉死 40。
    // 只在 **rv32** 上钉死 40 字节（那才是 C 侧的实际布局）。
    // 主机（x86_64）指针 8 字节且 u32 后要补 4 字节对齐 ⇒ 是 80，不该按 40 断言。
    if (@sizeOf(*anyopaque) == 4) {
        std.debug.assert(@sizeOf(ExtFuncs) == 40);
        std.debug.assert(@offsetOf(ExtFuncs, "ext_version") == 0);
        std.debug.assert(@offsetOf(ExtFuncs, "magic") == 36);
    }
}

fn xMalloc(size: u32, flags: u32) callconv(.c) ?*anyopaque {
    return osal.btdmMalloc(size, @intCast(flags));
}
fn xFree(p: ?*anyopaque) callconv(.c) void {
    osal.btdmFree(p);
}
fn xAssert(ln: u32, fn_name: ?[*:0]const u8, p1: u32, p2: u32) callconv(.c) void {
    osal.logPublic("bt controller assert: line={d} fn={s} p1={d} p2={d}", .{
        ln,
        if (fn_name) |f| std.mem.span(f) else "?",
        p1,
        p2,
    });
    _ = osal.hwEnterCritical();
    while (true) {}
}
fn xRandom() callconv(.c) u32 {
    return osal.randomU32();
}
fn xEccKeyPair(_: ?[*]u8, _: ?[*]u8) callconv(.c) c_int {
    return -1; // 同 IDF 在 SM 未开时的行为
}
fn xEccDhKey(_: ?[*]const u8, _: ?[*]const u8, _: ?[*]const u8, _: ?[*]u8) callconv(.c) c_int {
    return -1;
}
fn xResetRpa() callconv(.c) void {}
fn xAesCmac(_: ?[*]const u8, _: ?[*]const u8, _: usize, _: ?[*]u8) callconv(.c) c_int {
    return -1; // host 侧功能，controller-only 没有
}

pub const table: ExtFuncs = .{
    .ext_version = EXT_FUNC_VERSION,
    .malloc = xMalloc,
    .free = xFree,
    .osi_assert = xAssert,
    .os_random = xRandom,
    .ecc_gen_key_pair = xEccKeyPair,
    .ecc_gen_dh_key = xEccDhKey,
    .esp_reset_rpa_moudle = xResetRpa,
    .ecc_aes_cmac = xAesCmac,
    .magic = EXT_FUNC_MAGIC_VALUE,
};

extern fn esp_register_ext_funcs(f: *const ExtFuncs) c_int;
extern fn esp_unregister_ext_funcs(f: *const ExtFuncs) c_int;

/// 注册（目标构建调归档；主机返回 0 并只验证表本身）。
pub fn register() c_int {
    if (builtin.os.tag != .freestanding) return 0;
    return esp_register_ext_funcs(&table);
}

pub fn unregister() c_int {
    if (builtin.os.tag != .freestanding) return 0;
    return esp_unregister_ext_funcs(&table);
}

test "extfuncs: 表是 40 字节、魔数与版本对、四个分配相关项可用" {
    if (@sizeOf(*anyopaque) == 4) try std.testing.expectEqual(@as(usize, 40), @sizeOf(ExtFuncs));
    try std.testing.expectEqual(@as(u32, 0x20250819), table.ext_version);
    try std.testing.expectEqual(@as(u32, 0xA5A5A5A5), table.magic);
    // malloc/free 走我们的 arena
    var region: [2048]u8 align(8) = undefined;
    osal.initArena(&region);
    const p = table.malloc(64, 0);
    try std.testing.expect(p != null);
    table.free(p);
    // rand 有值
    _ = table.os_random();
    // 三种 ECC 是 -1（与 IDF 在 SM 未开时一致）
    try std.testing.expectEqual(@as(c_int, -1), table.ecc_gen_key_pair(null, null));
    try std.testing.expectEqual(@as(c_int, -1), table.ecc_gen_dh_key(null, null, null, null));
    try std.testing.expectEqual(@as(c_int, -1), table.ecc_aes_cmac(null, null, 0, null));
    try std.testing.expectEqual(@as(c_int, 0), register()); // 主机早退
    try std.testing.expectEqual(@as(c_int, 0), unregister());
}
