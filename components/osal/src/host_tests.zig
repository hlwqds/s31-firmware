//! osal：主机侧测试入口（x86_64）。
//!
//! 两文件都是纯逻辑 + 注入钩子，没有硬件依赖：`osal.zig` 17 项（信号量/互斥/事件队列/
//! 软件定时器/临界区嵌套），`sched.zig` 2 项（协作式调度的就绪队列）。
const std = @import("std");

test {
    _ = @import("osal.zig");
    _ = @import("sched.zig");
    // 模块根：导入它覆盖门禁才看得到 `api.zig`
    _ = @import("api.zig");
    // 共存钩子（`-Dcoex` 的 BLE 侧）：文件里自带 7 项，覆盖门禁也靠这一行看到它。
    _ = @import("coex_hooks.zig");
    std.testing.refAllDecls(@import("osal.zig"));
    std.testing.refAllDecls(@import("sched.zig"));
}
