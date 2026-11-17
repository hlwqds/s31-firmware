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
    std.testing.refAllDecls(@import("osal.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("porting.zig"));
    std.testing.refAllDecls(@import("bringup.zig"));
}
