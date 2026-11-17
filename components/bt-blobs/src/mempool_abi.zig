//! 归档的池初始化 ABI（`libbtdm_common/14.o` 的 `r_btdm_os_mempool_init`）。
//!
//! IDF 侧 `btdm_mempool_init`（`btdm_mempool.h:105`）只是 inline 包装，
//! 真正干活的是归档里的这个函数：
//!
//! ```c
//! r_btdm_os_mempool_init(struct btdm_mempool *mp, uint16_t blocks,
//!                        uint32_t block_size, void *membuf, const char *name);
//! ```
//!
//! 我们的移植此前**只做容量校验、从不调它** ⇒ 归档的池从未初始化。
//!
//! 主机侧（`zig build test`）没有这个符号，所以这里按目标条件编译：
//! 主机侧退化为"总是成功、不填任何东西"，纯逻辑用例照常跑。

const builtin = @import("builtin");

const on_target = builtin.target.os.tag == .freestanding;

/// `struct btdm_mempool` 约 28 字节；给 48 字节的 4 对齐静态对象，避免把布局写死。
pub const Pool = [48]u8;

/// 初始化一个池。返回归档给的 `rc`（0 = 成功）。
pub fn init(mp: *anyopaque, blocks: u16, block_size: u32, membuf: ?*anyopaque, name: [*:0]const u8) c_int {
    if (!on_target) return 0;
    const f = @extern(
        *const fn (*anyopaque, u16, u32, ?*anyopaque, [*:0]const u8) callconv(.c) c_int,
        .{ .name = "r_btdm_os_mempool_init" },
    );
    return f(mp, blocks, block_size, membuf, name);
}
