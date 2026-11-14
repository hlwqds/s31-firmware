//! net-ethernet 公共入口（供 net-wire 等组合模块使用）。
pub const emac = @import("emac.zig");
pub const regs = @import("regs.zig");
pub const pins = @import("pins.zig");
pub const apll = @import("apll.zig");
pub const phy = @import("phy.zig");
pub const descs = @import("descs.zig");
