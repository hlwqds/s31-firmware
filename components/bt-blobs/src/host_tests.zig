//! bt-blobs 的主机侧测试入口（x86_64）。
//!
//! OSAL 是纯逻辑（时间/临界区/信号量/互斥/事件/事件队列/callout），不碰硬件，
//! 所以整套语义可以在主机上钉住。归档链接本身是 opt-in 的 `-Dbt-blob-*`，
//! 不参与常规构建。
const std = @import("std");

test {
    _ = @import("osal.zig");
    _ = @import("config.zig");
    _ = @import("porting.zig");
    _ = @import("bringup.zig");
    _ = @import("extfuncs.zig");
    _ = @import("transport.zig");
    _ = @import("sched.zig");
    // 模块根：它本身没有逻辑，但导入它才能让覆盖门禁看到 `root.zig`
    // 与它下面那些只经根暴露的文件（如 `xpuq_shim.zig`）。
    _ = @import("root.zig");
    std.testing.refAllDecls(@import("osal.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("porting.zig"));
    std.testing.refAllDecls(@import("bringup.zig"));
    std.testing.refAllDecls(@import("extfuncs.zig"));
    std.testing.refAllDecls(@import("transport.zig"));
    std.testing.refAllDecls(@import("sched.zig"));
}
