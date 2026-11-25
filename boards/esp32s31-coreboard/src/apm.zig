//! 访问权限管理（APM，access permission management）：启动期关掉三条访问路径的控制过滤器。
//!
//! ## 出处
//!
//! IDF 的 `bootloader_init_mem()`（`bootloader_support/src/bootloader_mem.c`）。应用侧启动时调它，
//! 其中"关过滤器"那三行包在 `#if !defined(BOOTLOADER_BUILD)` 里——二级 bootloader 跳过，留给应用做。
//! 本镜像由 IDF 的二级 bootloader 加载后直接进应用，没人替我们做这一步，所以自己写。
//!
//! 对照镜像（`tools/wifi-idf-oracle` 的 ELF）里这个函数就是三条写 0，地址与下面一致：
//!
//! | 寄存器 | 地址 | 复位默认 |
//! | --- | --- | --- |
//! | `LP_APM_FUNC_CTRL` | `0x20706CBC` | `0x0F` |
//! | `HP_APM_FUNC_CTRL` | `0x205044C4` | `0x7F` |
//! | `HP_MEM_APM_FUNC_CTRL` | `0x205048C4` | `0x3F` |
//!
//! ## 为什么必须关
//!
//! 默认值只放行 TEE 模式的 master。上电时除了 HP CPU，其余 master 都是 REE 模式，它们对相应存储区的
//! 访问被**静默拒绝**（不报 bus error，读回也没有异常）。以太网那一章就是它：GMAC 的 AXI master 读
//! 描述符被拒，CPU 看 OWN=1、DMA 永远不取（`docs/` 里 GMAC 的实测）。Wi-Fi MAC 的 DMA 是同一类 master。
//!
//! 同一个函数里 IDF 还把三段外设 PMS 寄存器写成 `0xFF`（`0x20706000..0x20706070`、`0x20505000..0x20505078`、
//! `0x2058A000..0x2058A098`）并调 `esp_cpu_configure_region_protection()`。那几步本模块**没做**：
//! PMS 那几段对照镜像之后还会被改写（读回是 0），本镜像现在的值也不同，照抄 `0xFF` 不会得到同一状态。

const on_target = @import("builtin").target.os.tag == .freestanding;

pub const Error = error{ NotOnTarget, ReadbackMismatch };

const ctrl_regs = [_]usize{
    0x2070_6CBC, // LP_APM_FUNC_CTRL
    0x2050_44C4, // HP_APM_FUNC_CTRL
    0x2050_48C4, // HP_MEM_APM_FUNC_CTRL
};

fn readReg(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

/// 关掉三条访问路径的控制过滤器，写完读回校验。
pub fn disableCtrlFilters() Error!void {
    if (!on_target) return Error.NotOnTarget;
    for (ctrl_regs) |addr| {
        const p: *volatile u32 = @ptrFromInt(addr);
        p.* = 0;
        if (p.* != 0) return Error.ReadbackMismatch;
    }
}

/// 三个寄存器的当前值（诊断用：调用方打印"关之前是多少"）。
pub fn ctrlFilterValues() [ctrl_regs.len]u32 {
    var out: [ctrl_regs.len]u32 = undefined;
    for (ctrl_regs, 0..) |addr, i| out[i] = readReg(addr);
    return out;
}
