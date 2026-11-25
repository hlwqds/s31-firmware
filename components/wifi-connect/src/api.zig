//! wifi-connect 公共入口。
//!
//! 别的组件按模块名 import 它（`firmware/build.zig` 里的 `wifi_connect` 模块，与 `net-tcp` 的
//! `api.zig` 同一做法）。第一个使用者是 `wifi-blobs/src/wpa_cb.zig`：blob 的 supplicant 回调
//! （attach / detach / 断开通知）驱动这里的 `supplicant.Supplicant`。
pub const supplicant = @import("supplicant.zig");
