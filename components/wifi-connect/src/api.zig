//! wifi-connect 公共入口。
//!
//! 别的组件按模块名 import 它（`firmware/build.zig` 里的 `wifi_connect` 模块，与 `net-tcp` 的
//! `api.zig` 同一做法）。第一个使用者是 `wifi-blobs/src/wpa_cb.zig`：blob 的 supplicant 回调
//! （attach / detach / 断开通知 / 连接 / 收 EAPOL）驱动这里的 `supplicant.Supplicant`，关联前的
//! 策略选择用 `rsne`，口令 → PMK 用 `wpa2`，成对密码套件的换算用 `akm` 与 `ccmp`。
//!
//! `vectors` 是测试向量：`wifi-blobs` 在自己的主机用例里拿它对拍整条握手（已知的几帧 EAPOL-Key）。
pub const supplicant = @import("supplicant.zig");
pub const rsne = @import("rsne.zig");
pub const wpa2 = @import("wpa2.zig");
pub const akm = @import("akm.zig");
pub const ccmp = @import("ccmp.zig");
pub const bip = @import("bip.zig");
pub const vectors = @import("vectors.zig");
