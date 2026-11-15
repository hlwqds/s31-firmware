//! 板级接口：hw / log / trap / rng 的统一命名空间，供固件与各组件引用。
pub const hw = @import("hw.zig");
pub const rng = @import("rng.zig");
pub const log = @import("log.zig");
pub const trap = @import("trap.zig");
