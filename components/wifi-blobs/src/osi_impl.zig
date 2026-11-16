//! `wifi_osi_funcs_t` 的**裸机实现**（R3 适配层的第一块）。
//!
//! 设计前提（都是实测出来的，不是假设）：
//!
//!   - blob 不直接引用 FreeRTOS / esp_event / esp_timer / heap：三个大归档里
//!     `xTaskCreate`/`xQueue*`/`xSemaphore*`/`esp_event_*`/`esp_timer_*`/`heap_caps_*`
//!     的未定义引用全是 0，所有 OS 访问都经这张表；
//!   - 我们的固件是**单线程 + 关中断**（`mstatus.MIE=0`），所以"阻塞"在这里没有意义：
//!     信号量 take 空时直接返回失败（等价 timeout），互斥锁是空操作；
//!   - 分配器只服务 blob 自己的小对象：第一版用**首次适配 + 显式空闲链表**，够用且可测；
//!     真跑 Wi-Fi 前要换成 TLSF 或与主堆统一，这里先把语义和边界钉住。
//!
//! 主机侧单测覆盖：分配/释放/重分配/耗尽、信号量计数、队列环绕、互斥空操作、
//! 以及"表里哪些字段被填了"。

const std = @import("std");
const osi = @import("osi.zig");

/// 块头：`size` 是**载荷**字节数；`next` 是下一个块头（含空闲与已用）。
const Block = struct {
    size: usize,
    free: bool,
    next: ?*Block,
    prev: ?*Block,
};

pub const Arena = struct {
    head: ?*Block = null,
    bytes_total: usize = 0,
    bytes_free: usize = 0,

    /// 用一段连续内存初始化（裸机上是 `[_heap_start, _heap_end)`，主机上是静态数组）。
    pub fn init(self: *Arena, buf: []u8) void {
        const aligned = std.mem.alignForward(usize, @intFromPtr(buf.ptr), @alignOf(Block));
        const skip = aligned - @intFromPtr(buf.ptr);
        if (buf.len <= skip + @sizeOf(Block)) {
            self.* = .{};
            return;
        }
        const payload_len = (buf.len - skip - @sizeOf(Block)) & ~@as(usize, @alignOf(Block) - 1);
        const b: *Block = @ptrFromInt(aligned);
        b.* = .{ .size = payload_len, .free = true, .next = null, .prev = null };
        self.* = .{ .head = b, .bytes_total = payload_len, .bytes_free = payload_len };
    }

    fn payload(b: *Block) [*]u8 {
        return @as([*]u8, @ptrCast(b)) + @sizeOf(Block);
    }

    pub fn alloc(self: *Arena, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;
        var it = self.head;
        while (it) |b| : (it = b.next) {
            if (!b.free) continue;
            const p = @intFromPtr(payload(b));
            const aligned = std.mem.alignForward(usize, p, alignment);
            const pad = aligned - p;
            if (b.size < pad + size) continue;
            // 前面要留对齐填充时，把块头后移：简化处理——只接受自然对齐的请求。
            if (pad != 0) continue;

            // 切分：剩余部分够放下一个块头 + 8 字节载荷时才切，否则整块给出。
            const need = @sizeOf(Block) + std.mem.alignForward(usize, size, @alignOf(Block));
            if (b.size >= need + @sizeOf(Block) + 8) {
                const rest: *Block = @ptrFromInt(@intFromPtr(payload(b)) + std.mem.alignForward(usize, size, @alignOf(Block)));
                rest.* = .{ .size = b.size - need, .free = true, .next = b.next, .prev = b };
                if (b.next) |n| n.prev = rest;
                b.next = rest;
                b.size = std.mem.alignForward(usize, size, @alignOf(Block));
                self.bytes_free -= need;
            } else {
                self.bytes_free -= b.size;
            }
            b.free = false;
            return payload(b);
        }
        return null;
    }

    pub fn free(self: *Arena, ptr: ?[*]u8) void {
        const p = ptr orelse return;
        const b: *Block = @ptrFromInt(@intFromPtr(p) - @sizeOf(Block));
        if (b.free) return;
        b.free = true;
        self.bytes_free += b.size;
        // 与后继合并
        if (b.next) |n| {
            if (n.free) {
                b.size += @sizeOf(Block) + n.size;
                b.next = n.next;
                if (n.next) |nn| nn.prev = b;
            }
        }
        // 与前驱合并
        if (b.prev) |pv| {
            if (pv.free) {
                pv.size += @sizeOf(Block) + b.size;
                pv.next = b.next;
                if (b.next) |nn| nn.prev = pv;
            }
        }
    }

    pub fn realloc(self: *Arena, ptr: ?[*]u8, size: usize) ?[*]u8 {
        const p = ptr orelse return self.alloc(size, @alignOf(usize));
        const b: *Block = @ptrFromInt(@intFromPtr(p) - @sizeOf(Block));
        if (b.size >= size) return p;
        const np = self.alloc(size, @alignOf(usize)) orelse return null;
        @memcpy(np[0..b.size], p[0..b.size]);
        self.free(p);
        return np;
    }
};

/// `OSI_FUNCS_TIME_BLOCKING`（`wifi_os_adapter.h:23`）：IDF 里表示"无限等"。
pub const time_blocking: u32 = 0xFFFF_FFFF;

/// 观测用计数器：被拒绝的无限阻塞请求。单线程 + 关中断下阻塞=死锁，
/// 所以这里**有意偏离** IDF 语义：返回失败而不是挂住，但要能被看见。
pub var blocking_refused: u32 = 0;
/// 被丢弃的事件（没有事件循环时 `_event_post` 无法投递）。
pub var events_dropped: u32 = 0;

/// 信号量：返回值是 **FreeRTOS 风格**（成功=1、失败/超时=0），与 `esp_adapter.c` 一致。
pub const Semphr = struct {
    count: u32,
    max: u32,

    /// `blocking == time_blocking` 时 IDF 会无限等；我们拒绝并计数（见 `blocking_refused`）。
    pub fn take(self: *Semphr, blocking: u32) i32 {
        if (self.count > 0) {
            self.count -= 1;
            return 1;
        }
        if (blocking == time_blocking) blocking_refused += 1;
        return 0;
    }

    pub fn give(self: *Semphr) i32 {
        if (self.count < self.max) {
            self.count += 1;
            return 1;
        }
        return 0;
    }
};

pub const Mutex = struct {
    /// 单线程下没有竞争者；留着字段是为了将来接中断/任务。
    /// 返回值按 IDF 的 `xSemaphoreTakeRecursive` 约定：成功=1。
    locked: bool = false,

    pub fn lock(self: *Mutex) i32 {
        self.locked = true;
        return 1;
    }

    pub fn unlock(self: *Mutex) i32 {
        self.locked = false;
        return 1;
    }
};

/// 定长元素队列（环形）。`item_size` 由调用方给，载荷紧跟在结构体后面。
pub const Queue = struct {
    item_size: usize,
    cap: usize,
    count: usize = 0,
    head: usize = 0,
    tail: usize = 0,

    pub fn buf(self: *Queue) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + @sizeOf(Queue);
    }

    pub fn bytesNeeded(item_size: usize, cap: usize) usize {
        return @sizeOf(Queue) + item_size * cap;
    }

    /// 队列方向常量（`wifi_os_adapter.h:25-27`）。
    pub const send_front: u32 = 0;
    pub const send_back: u32 = 1;
    pub const send_overwrite: u32 = 2;

    /// 返回值 **FreeRTOS 风格**：成功=1、满/尺寸不符=0。
    pub fn send(self: *Queue, item: []const u8, blocking: u32) i32 {
        if (item.len != self.item_size) return 0;
        if (self.count == self.cap) {
            if (blocking == time_blocking) blocking_refused += 1;
            return 0;
        }
        const b = self.buf();
        @memcpy(b[self.tail * self.item_size ..][0..self.item_size], item);
        self.tail = (self.tail + 1) % self.cap;
        self.count += 1;
        return 1;
    }

    /// `send_to_front`：插到队首（IDF 的 `queueSEND_TO_FRONT`）。
    pub fn sendFront(self: *Queue, item: []const u8) i32 {
        if (item.len != self.item_size or self.count == self.cap) return 0;
        const b = self.buf();
        self.head = (self.head + self.cap - 1) % self.cap;
        @memcpy(b[self.head * self.item_size ..][0..self.item_size], item);
        self.count += 1;
        return 1;
    }

    pub fn recv(self: *Queue, out: []u8, blocking: u32) i32 {
        if (out.len != self.item_size) return 0;
        if (self.count == 0) {
            if (blocking == time_blocking) blocking_refused += 1;
            return 0;
        }
        const b = self.buf();
        @memcpy(out, b[self.head * self.item_size ..][0..self.item_size]);
        self.head = (self.head + 1) % self.cap;
        self.count -= 1;
        return 1;
    }

    pub fn msgWaiting(self: *const Queue) u32 {
        return @intCast(self.count);
    }
};

/// `_event_post` 是 **esp_event 风格：成功=0、失败=-1**（与队列/信号量的 FreeRTOS 风格相反）。
/// 我们没有事件循环，投递必然失败——返回 -1 并计数，让 blob 的 init 明确失败而不是静默丢事件。
pub fn eventPost() i32 {
    events_dropped += 1;
    return -1;
}
