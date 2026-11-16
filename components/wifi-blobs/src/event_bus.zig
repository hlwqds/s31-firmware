//! 极简 `esp_event` 注册表 + **同步派发**。
//!
//! 为什么需要它：blob 通过 `esp_event_handler_register` 注册自己的 IPC/事件处理函数，然后
//! 在 `_event_post` 之后等它被调用。我们原先把它做成"计数后返回 0"的桩——blob 以为注册成功，
//! 但处理函数从未被调用，后续派发读到的是一块**未初始化的函数指针**（实测 `jalr` 跳进 SRAM，
//! `illegal instruction`，地址每次不同）。
//!
//! 单线程壳里没有事件循环，所以 `_event_post` **就地同步派发**：注册表里匹配 `(base, id)` 的
//! 处理函数按注册顺序调用。这是"事件循环"的最简等价物，语义写在这里以免下次误读。

const std = @import("std");

/// `esp_event_handler_t`：`void (*)(void *arg, esp_event_base_t base, int32_t id, void *data)`。
pub const Handler = *const fn (?*anyopaque, ?*const anyopaque, i32, ?*const anyopaque) callconv(.c) void;

pub const Entry = struct {
    base: ?*const anyopaque = null,
    id: i32 = 0,
    handler: ?Handler = null,
    arg: ?*anyopaque = null,
};

pub const capacity = 8;
pub var entries: [capacity]Entry = @splat(.{});
pub var count: usize = 0;
/// 派发次数（探针/调试用）。
pub var posts: u32 = 0;
pub var dispatched: u32 = 0;

pub export fn esp_event_handler_register(
    base: ?*const anyopaque,
    id: i32,
    handler: ?Handler,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    if (handler == null) return 0x102; // ESP_ERR_INVALID_ARG
    if (count >= capacity) return 0x101; // ESP_ERR_NO_MEM
    entries[count] = .{ .base = base, .id = id, .handler = handler, .arg = arg };
    count += 1;
    return 0;
}

pub export fn esp_event_handler_unregister(
    base: ?*const anyopaque,
    id: i32,
    handler: ?Handler,
) callconv(.c) c_int {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (entries[i].base == base and entries[i].id == id and entries[i].handler == handler) {
            var j = i;
            while (j + 1 < count) : (j += 1) entries[j] = entries[j + 1];
            count -= 1;
            entries[count] = .{};
            return 0;
        }
    }
    return 0; // 未注册也算成功（esp_event 的语义）
}

/// 同步派发：调用所有匹配 `(base, id)` 的处理函数。
pub fn post(base: ?*const anyopaque, id: i32, data: ?*const anyopaque) void {
    posts += 1;
    // 复制一份要调用的列表：处理函数里可能注册/注销。
    var snapshot: [capacity]Entry = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (entries[i].base == base and entries[i].id == id) {
            snapshot[n] = entries[i];
            n += 1;
        }
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (snapshot[i].handler) |h| {
            h(snapshot[i].arg, snapshot[i].base, id, data);
            dispatched += 1;
        }
    }
}
