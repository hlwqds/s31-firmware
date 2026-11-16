//! ESP32-S31 Wi-Fi blob 链接实验的适配面（**链接期**用，不是可运行实现）。
//!
//! 目标只有一个：让 `libnet80211.a` / `libpp.a` / `libcore.a` 真的被链接进来，看
//! 1) Zig 的 lld + 我们的两段链接脚本能不能吃 GCC 产出的对象；
//! 2) 拉进来的对象在 0xB0000 窗口里放不放得下；
//! 3) 到底还缺哪些外部符号。
//!
//! 这里的实现**故意是桩**：分配返回 null、队列返回错误、phy 钩子空转。任何真的调用
//! 都会失败——所以本模块只在 `-Dwifi-blob-dir=` 打开时参与构建，且**不上板**。
//!
//! 2026-11-16 实测结论（别重复走）：
//!   - lld 吃 GCC 产出的 RISC-V 对象没问题，`elf2image` 仍 `Merged 2 ELF sections`；
//!   - 但 `--gc-sections` 会把所有没被引用的段全丢掉——对象都上了链接行，ELF 仍是 29 KB。
//!     所以"能不能链接"不是问题，"谁引用 blob"才是；下一步要给适配层真实入口
//!     （`esp_wifi_init` 路径），而不是继续调容量；
//!   - 容量按**段字节**算（`readelf -S`），不是对象文件大小：全量 105 个对象 text 384 590 +
//!     rodata 102 518，文件却有 2.6 MB（debug/符号表）。
//!   - 关掉 `app.link_gc_sections` 后 lld 报 **195 个未定义符号**（不是 208；libgcc 那 24 个由
//!     Zig 的 compiler_rt 满足）。用 195 个自动生成的桩补齐后**链接成功**：`.flash.text`
//!     586 384 B（窗口 720 896）、`elf2image` 报 `Invalid segment count 124 (max 16)`。
//!     124 段的来源是 blob 的 **603 个 `.rodata_wlog…`** 独立段 + `.wifislprxiram.*` + `.eh_frame*`，
//!     我们的 `s31.ld` 没收集它们。**R3 的下一步是段收集，不是适配层逻辑。**
//!
//! 等 R3 真正开工时，这些桩要换成 esp_adapter（TLSF 堆、FreeRTOS 队列/信号量、
//! esp_phy/coex 的真实钩子）。

const std = @import("std");

// 让链接器真的把 blob 拉进来：**运行时**取一次符号地址。
// comptime 里取地址不会留下重定位，lld 也就不会去归档里找那个成员
// （实测：comptime `_ = @extern(...)` 时 ELF 停在 29 464 B，什么都没拉进来）。
pub fn probe() usize {
    const tx = @extern(*const anyopaque, .{ .name = "esp_wifi_80211_tx" });
    return @intFromPtr(tx);
}
