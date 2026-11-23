//! bt-blobs 的主机侧测试入口（x86_64）。
//!
//! **OSAL 不在这里**：`osal.zig`/`sched.zig` 已搬到 `components/osal/`，那 19 项用例
//! 归 `osal` 自己的测试目标（否则同一批用例会被两个组件各数一遍）。
//! 本入口只覆盖 bt-blobs 自己的胶水：config / porting / bringup / extfuncs / transport / root。
//! 归档链接是 opt-in 的 `-Dbt-blob-*`，验收见 `scripts/check-bt-link.sh`。
const std = @import("std");

test {
    // 目标侧 extern 的空实现（ROM/libphy/归档/板级符号）——主机目标不链归档。
    _ = @import("host_stubs.zig");
    _ = @import("config.zig");
    _ = @import("est_phy_tables.zig");

    _ = @import("porting.zig");
    _ = @import("bringup.zig");
    _ = @import("extfuncs.zig");
    _ = @import("transport.zig");
    // 共存接线（`-Dcoex`）：主机上是空操作；覆盖门禁靠这一行看到它。
    _ = @import("coex_wiring.zig");
    _ = @import("gate.zig");
    // 模块根：它本身没有逻辑，但导入它才能让覆盖门禁看到 `root.zig`
    // 与它下面那些只经根暴露的文件（如 `xpuq_shim.zig`）。
    _ = @import("root.zig");
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("porting.zig"));
    std.testing.refAllDecls(@import("bringup.zig"));
    std.testing.refAllDecls(@import("extfuncs.zig"));
    std.testing.refAllDecls(@import("transport.zig"));
    std.testing.refAllDecls(@import("gate.zig"));
}

test "est_phy_tables: 24 张 FTM 补偿表各 64B 且全零" {
    const t = @import("est_phy_tables.zig");
    const names = [_][]const u8{
        "est_PHY_INIT_FTM_COMP_20_20D_MHZ", "est_PHY_INIT_FTM_COMP_20_20D_MHZ_DIS",
        "est_PHY_INIT_FTM_COMP_20_20U_MHZ", "est_PHY_INIT_FTM_COMP_20_20U_MHZ_DIS",
        "est_PHY_INIT_FTM_COMP_20_40D_MHZ", "est_PHY_INIT_FTM_COMP_20_40D_MHZ_DIS",
        "est_PHY_INIT_FTM_COMP_20_40U_MHZ", "est_PHY_INIT_FTM_COMP_20_40U_MHZ_DIS",
        "est_PHY_INIT_FTM_COMP_40_40D_MHZ", "est_PHY_INIT_FTM_COMP_40_40D_MHZ_DIS",
        "est_PHY_INIT_FTM_COMP_40_40U_MHZ", "est_PHY_INIT_FTM_COMP_40_40U_MHZ_DIS",
        "est_PHY_RESP_FTM_COMP_20_20D_MHZ", "est_PHY_RESP_FTM_COMP_20_20D_MHZ_DIS",
        "est_PHY_RESP_FTM_COMP_20_20U_MHZ", "est_PHY_RESP_FTM_COMP_20_20U_MHZ_DIS",
        "est_PHY_RESP_FTM_COMP_20_40D_MHZ", "est_PHY_RESP_FTM_COMP_20_40D_MHZ_DIS",
        "est_PHY_RESP_FTM_COMP_20_40U_MHZ", "est_PHY_RESP_FTM_COMP_20_40U_MHZ_DIS",
        "est_PHY_RESP_FTM_COMP_40_40D_MHZ", "est_PHY_RESP_FTM_COMP_40_40D_MHZ_DIS",
        "est_PHY_RESP_FTM_COMP_40_40U_MHZ", "est_PHY_RESP_FTM_COMP_40_40U_MHZ_DIS",
    };
    inline for (names) |nm| {
        const tbl = @field(t, nm);
        try std.testing.expectEqual(@as(usize, 64), tbl.len);
        for (tbl) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
}
