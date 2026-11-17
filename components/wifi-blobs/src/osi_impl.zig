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
const event_bus = @import("event_bus.zig");
const osi = @import("osi.zig");
const nvs = @import("nvs_ram.zig");
const stubs = @import("osi_stubs.zig");

/// 块头：`size` 是**载荷**字节数；`next` 是下一个块头（含空闲与已用）。
const Block = struct {
    size: usize,
    free: bool,
    next: ?*Block,
    prev: ?*Block,
};

pub const Arena = struct {
    head: ?*Block = null,
    base: usize = 0,
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
        self.* = .{ .head = b, .base = @intFromPtr(b), .bytes_total = payload_len, .bytes_free = payload_len };
    }

    fn payload(b: *Block) [*]u8 {
        return @as([*]u8, @ptrCast(b)) + @sizeOf(Block);
    }

    /// 描述某个地址落在哪个块里（探针用它回答"这个坏指针是谁的"）。
    pub const BlockInfo = struct { size: usize, free: bool, offset: usize };

    pub fn describe(self: *Arena, addr: usize) ?BlockInfo {
        var it = self.head;
        while (it) |b| : (it = b.next) {
            const p = @intFromPtr(payload(b));
            if (addr >= p and addr < p + b.size) {
                return .{ .size = b.size, .free = b.free, .offset = addr - p };
            }
        }
        return null;
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
/// `Queue.recv` 在 `portMAX_DELAY` 下长时间等不到而放弃的次数（正常情况下应为 0）。
pub var queue_block_giveup: u32 = 0;
/// 越界句柄（标量被当指针）的次数，探针会打印。
pub var bad_handle: u32 = 0;
/// `_semphr_give(null)` 的次数（ack 的 give 侧句柄从未被赋值）。
pub var null_give: u32 = 0;
/// 诊断：`_semphr_give` 的总次数（与 `null_give` 对比即可看出有多少 give 被丢弃）。
pub var give_total: u32 = 0;
/// recv 探针计数（前 6 次打印 count/item_size）。
pub var recv_probe: u32 = 0;
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
        if (blocking != time_blocking) return 0;
        // 阻塞 = **有界让出**：每次让出后重查，最多 `idle_spin_limit` 次，然后返回 0。
        //
        // 曾经试过"真的等到被 give"（带 5 s 时钟上限），结果与任务互相等待——主上下文等 ack、
        // 任务等消息，`idle_calls` 一路涨到上限而 `hooks` 不再变化（实测活锁）。所以 ack/消息的
        // 生产者本身缺失，不是等待策略的问题；这里保持有界让出，避免把活锁写进固件。
        blocking_refused += 1;
        // **实验：无限阻塞语义**（IDF 的 `xSemaphoreTake(sem, portMAX_DELAY)` 是真等到被 give）。
        // 此前用 `idle_spin_limit`(64) 次让出后返回 0，理由是"真等会活锁"——但那个结论是在
        // `serviceTimers` 未接线、ICG/时钟未对齐之前得到的，需要重验。
        var spins: u32 = 0;
        while (spins < idle_spin_limit) : (spins += 1) {
            serviceTimers();
            serviceTimers();
            if (hooks.on_idle) |idle| idle();
            if (self.count > 0) {
                self.count -= 1;
                return 1;
            }
        }
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
        send_probe += 1;
        send_ok +%= 1;
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
            if (blocking != time_blocking) return 0;
            blocking_refused += 1;
            // **IDF 的语义是"无限阻塞"**（`xQueueReceive(..., portMAX_DELAY)` 永不返回 0）。
            // 我们原先只用 `idle_spin_limit`(64) 次让出就返回 0 —— blob 会把"空"当成一条合法答复，
            // 从而走到不同分支。这里把阻塞上限放大（仍保留有界，避免把板子挂死）。
            // **真阻塞**：`portMAX_DELAY` 语义下永不返回 0。每次让出都重查；
            // 让出点是 `on_idle`，它会把控制权交给别的任务/主上下文（RTOS 式 block）。
            var spins: u64 = 0;
            while (self.count == 0) : (spins += 1) {
                serviceTimers();
                serviceTimers();
                if (hooks.on_idle) |idle| idle();
                // 防御：真的没人会 post 时不要静默返回 0，而是明确记一次（便于判读）。
                if (spins > 50_000_000) {
                    queue_block_giveup +%= 1;
                    return 0;
                }
            }
        }
        const b = self.buf();
        last_recv_count = self.count;
        recv_ok +%= 1;
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

/// 表里用的 `_event_post` 壳：**打点后返回 0（成功）**。
///
/// 这里刻意与 `eventPost()` 的 -1 区分：`esp_wifi_start` 若认为"投递失败"会重试/自旋，
/// 而我们没有事件循环，投递本来就只是丢弃——返回成功才能让状态机继续走。
fn shellEventPost(
    event_base: ?*const anyopaque,
    event_id: u32,
    event_data: ?*const anyopaque,
    data_size: usize,
) callconv(.c) c_int {
    note(12, event_id, data_size);
    // 同步派发：blob 通过 `esp_event_handler_register` 注册的处理函数在这里被调用。
    event_bus.post(event_base, @intCast(event_id), event_data);
    return 0;
}

// ---------------------------------------------------------------------------
// 把原语接成 `Osi` 表（C 调用约定的薄壳）
//
// 这些壳只做类型转换与池化，语义全在上面四个原语里。函数指针按 ilp32 都是 4 字节，
// 用 `@ptrCast` 填进 `?*const anyopaque` 字段即可。
// ---------------------------------------------------------------------------

pub var arena_state: Arena = .{};
var arena_buf: []u8 = &.{};

/// 裸机上传 `[_heap_start, _heap_end)`；主机测试传静态数组。
pub fn initArena(buf: []u8) void {
    arena_buf = buf;
    arena_state.init(buf);
}

fn shellMalloc(size: usize) callconv(.c) ?*anyopaque {
    const p = arena_state.alloc(size, @alignOf(usize)) orelse return null;
    return @ptrCast(p);
}

fn shellFree(p: ?*anyopaque) callconv(.c) void {
    const q: ?[*]u8 = if (p) |v| @ptrCast(v) else null;
    arena_state.free(q);
}

/// `*_internal` / `wifi_*` 这一族只是不同 heap 域的分配器；我们没有多堆，全部走同一个 arena。
fn shellMallocInternal(size: usize) callconv(.c) ?*anyopaque {
    note(8, size, 0);
    const r = mallocRaw(size);
    note(13, size, @intFromPtr(r));
    return r;
}

fn mallocRaw(size: usize) ?*anyopaque {
    return shellMalloc(size);
}
fn shellZallocInternal(size: usize) callconv(.c) ?*anyopaque {
    note(9, size, 0);
    const p = shellMalloc(size) orelse return null;
    note(13, size, @intFromPtr(p));
    @memset(@as([*]u8, @ptrCast(p))[0..size], 0);
    return p;
}
fn shellCallocInternal(n: usize, size: usize) callconv(.c) ?*anyopaque {
    note(10, n, size);
    return shellZallocInternal(n * size);
}
fn shellReallocInternal(p: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const q: ?[*]u8 = if (p) |v| @ptrCast(v) else null;
    const np = arena_state.realloc(q, size) orelse return null;
    return @ptrCast(np);
}
fn shellFreeInternal(p: ?*anyopaque) callconv(.c) void {
    shellFree(p);
}

fn shellFreeHeapSize() callconv(.c) usize {
    return arena_state.bytes_free;
}

fn shellSemphrCreate(max: u32, init_count: u32) callconv(.c) ?*anyopaque {
    cnt_sem_create +%= 1;
    if (cnt_sem_create <= 4) {
        sem_create_args[cnt_sem_create - 1] = (max << 16) | (init_count & 0xFFFF);
    }
    const mem = arena_state.alloc(@sizeOf(Semphr), @alignOf(Semphr)) orelse {
        cnt_sem_create_null +%= 1;
        return null;
    };
    const s: *Semphr = @ptrCast(@alignCast(mem));
    s.* = .{ .count = @min(init_count, max), .max = max };
    return @ptrCast(s);
}

/// 供探针调用：创建信号量（与 `_semphr_create` 同一实现）。
pub fn shellSemphrCreatePublic(max: u32, init_count: u32) ?*anyopaque {
    return shellSemphrCreate(max, init_count);
}

fn shellSemphrDelete(p: ?*anyopaque) callconv(.c) void {
    const q: ?[*]u8 = if (p) |v| @ptrCast(v) else null;
    arena_state.free(q);
}

fn shellSemphrTake(p: ?*anyopaque, blocking: u32) callconv(.c) i32 {
    note(0, @intFromPtr(p), blocking);
    const s: *Semphr = @ptrCast(@alignCast(p orelse return 0));
    return s.take(blocking);
}

fn shellSemphrGive(p: ?*anyopaque) callconv(.c) i32 {
    give_total +%= 1;
    if (p == null) {
        // 实测 ack 的 give 传的是空句柄（take 侧却是有效句柄）→ 这是两个不同变量。
        // 记下调用者 ra，便于反查"give 侧变量本应由谁写"。
        const ra = @returnAddress();
        null_give += 1;
        if (null_give <= 3) note(1, 0, ra); // a1 = 调用者 ra，便于反查
        return 0;
    }
    note(1, @intFromPtr(p), 0);
    const s: *Semphr = @ptrCast(@alignCast(p orelse return 0));
    return s.give();
}

// NVS：极简 RAM 版（见 nvs_ram.zig）。Wi-Fi init 几乎必然读 NVS，留 null 会撞空指针。
fn shellNvsOpen(name: ?[*:0]const u8, mode: c_uint, out_handle: ?*u32) callconv(.c) c_int {
    _ = mode;
    return nvs.open(name orelse return nvs.err_invalid_arg, out_handle);
}
fn shellNvsClose(handle: u32) callconv(.c) void {
    nvs.close(handle);
}
fn shellNvsCommit(handle: u32) callconv(.c) c_int {
    return nvs.commit(handle);
}
fn shellNvsSetI8(handle: u32, key: ?[*:0]const u8, value: i8) callconv(.c) c_int {
    return nvs.setNum(handle, key orelse return nvs.err_invalid_arg, @as(u8, @bitCast(value)), .i8v);
}
fn shellNvsGetI8(handle: u32, key: ?[*:0]const u8, out: ?*i8) callconv(.c) c_int {
    var v: u16 = 0;
    const rc = nvs.getNum(handle, key orelse return nvs.err_invalid_arg, .i8v, &v);
    if (rc == nvs.ok) out.?.* = @bitCast(@as(u8, @truncate(v)));
    return rc;
}
fn shellNvsSetU8(handle: u32, key: ?[*:0]const u8, value: u8) callconv(.c) c_int {
    return nvs.setNum(handle, key orelse return nvs.err_invalid_arg, value, .u8v);
}
fn shellNvsGetU8(handle: u32, key: ?[*:0]const u8, out: ?*u8) callconv(.c) c_int {
    var v: u16 = 0;
    const rc = nvs.getNum(handle, key orelse return nvs.err_invalid_arg, .u8v, &v);
    if (rc == nvs.ok) out.?.* = @truncate(v);
    return rc;
}
fn shellNvsSetU16(handle: u32, key: ?[*:0]const u8, value: u16) callconv(.c) c_int {
    return nvs.setNum(handle, key orelse return nvs.err_invalid_arg, value, .u16v);
}
fn shellNvsGetU16(handle: u32, key: ?[*:0]const u8, out: ?*u16) callconv(.c) c_int {
    return nvs.getNum(handle, key orelse return nvs.err_invalid_arg, .u16v, out orelse return nvs.err_invalid_arg);
}
fn shellNvsSetBlob(handle: u32, key: ?[*:0]const u8, value: ?*const anyopaque, length: usize) callconv(.c) c_int {
    const p: [*]const u8 = @ptrCast(value orelse return nvs.err_invalid_arg);
    return nvs.setBlob(handle, key orelse return nvs.err_invalid_arg, p[0..length]);
}
/// 诊断：最近一次 `_nvs_get_blob` 的请求长度与返回码（由探针打印）。
pub var nvs_last_want: usize = 0;
pub var nvs_last_rc: c_int = 0;
pub var nvs_get_blob_calls: u32 = 0;

fn shellNvsGetBlob(handle: u32, key: ?[*:0]const u8, out: ?*anyopaque, length: ?*usize) callconv(.c) c_int {
    const p: [*]u8 = @ptrCast(out orelse return nvs.err_invalid_arg);
    const l = length orelse return nvs.err_invalid_arg;
    const want = l.*;
    const rc = nvs.getBlob(handle, key orelse return nvs.err_invalid_arg, p[0..want], l);
    // **NVS trace**：记录最近一次 blob 读取的请求长度与返回码。PHY 校准数据是 1904 字节，
    // 而我们的 `nvs.max_blob` 只有 64 —— 这两个数一对比就能看出缺口。
    nvs_last_want = want;
    nvs_last_rc = rc;
    nvs_get_blob_calls += 1;
    return rc;
}
fn shellNvsEraseKey(handle: u32, key: ?[*:0]const u8) callconv(.c) c_int {
    return nvs.eraseKey(handle, key orelse return nvs.err_invalid_arg);
}

/// 时间/随机/MAC 这类钩子需要硬件（`hw.nowUs`、TRNG、efuse MAC），而本组件不 import
/// `board`——所以走**注入**：固件构建时用 `setHooks` 接上真实现，主机测试接测试替身。
/// 没注入时退化为"计数 + 保守返回值"，不会崩。
pub const Hooks = struct {
    now_us: ?*const fn () u64 = null,
    fill_random: ?*const fn (dst: []u8) void = null,
    mac: ?*const fn () [6]u8 = null,
    /// 阻塞等待期间的**合作式让出点**：单线程壳里没有别的线程能填队列，所以
    /// "阻塞"只能是"把控制权让给主循环去做事（收包/发送），再回来查一次"。
    /// 探针用它证明任务体存活且会让出；生产用它跑主循环的收发。
    on_idle: ?*const fn () void = null,
    /// `_phy_enable(modem)` 的**真实实现**：由探针注入（它才有 phy_init_data/cal_data）。
    /// 返回 0 表示成功；非 0 会被忽略（钩子只做副作用）。
    on_phy_enable: ?*const fn (modem: u32) usize = null,
    /// 每次钩子调用都回调（探针用它逐行追踪某个阶段的调用序列，带上限）。
    on_note: ?*const fn (id: u8, a0: usize, a1: usize) void = null,
    /// 钩子调用预算耗尽时回调（探针用它打印现场并停机）。
    /// 单线程壳里"任务体进入自己的等待循环"就等于永不返回，必须有个外部刹车。
    on_budget_exhausted: ?*const fn (total_calls: u32) void = null,
};

var hooks: Hooks = .{};

/// 钩子调用预算：>0 时每调用一次递减，归零即回调（见 `Hooks.on_budget_exhausted`）。
pub var budget: u32 = 0;
/// 见 `shellTaskCreatePinned` 的实验说明。
pub var task_create_fail: bool = false;
/// 一次"阻塞等待"最多让出多少次（每次让出都会跑一遍主循环的 idle 钩子）。
pub const idle_spin_limit: u32 = 64;
/// 阻塞队列接收的自旋上限：IDF 是 `portMAX_DELAY`（无限），我们用一个足够大的有界值近似。
pub const queue_block_spin_limit: u32 = 20_000;
/// 信号量"无限阻塞"的自旋上限（IDF 是 portMAX_DELAY）。设得足够大以近似"一直等"，
/// 但不至于把板子永久挂死。
pub const semphr_block_spin_limit: u32 = 2_000_000;
/// 最近的钩子调用（id = `hook_ids` 的下标），用于停机时说明"它在等什么"。
pub const hook_ids = [_][]const u8{
    "semphr_take",   "semphr_give", "mutex_lock",        "mutex_unlock",
    "queue_recv",    "queue_send",  "queue_msg_waiting", "task_create",
    "malloc",        "zalloc",      "calloc",            "mutex_create",
    "event_post",    "alloc",       "recv_probe",        "phy_enable",
    "timer_fire",    "timer_setfn", "timer_arm",         "timer_disarm",
    // 17 = queue_send_ok（`Queue.send` 成功分支）
    "queue_send_ok", "wifi_clk_en", "wifi_clk_dis",      "wifi_reset_mac",
    "coex_init",     "coex_enable", "coex_status",       "coex_pti",
    "coex_req",      "coex_rel",    "coex_interval",     "coex_start_cb",
    "set_intr",      "set_isr",     "ints_on",
};
pub const HookEvent = struct { id: u8, a0: usize, a1: usize };
/// `note()` 用到的最大 id（新增打点时同步改这里；下面的 comptime 断言会挡住越界）。
pub const note_id_max: u8 = 33;

comptime {
    // 这个断言防的是一类真炸过的事故：`hook_ids` 没跟上新增 id → 事件环打印越界索引 →
    // `{s}` 把相邻 .rodata 的字符串头当切片解引用（实测 mtval=0x69666977 = "wifi" 的 ASCII）。
    if (hook_ids.len < @as(usize, note_id_max) + 1) {
        @compileError("hook_ids 没有覆盖 note() 的全部 id");
    }
}

pub var events: [8]HookEvent = @splat(.{ .id = 0, .a0 = 0, .a1 = 0 });
pub var event_count: u32 = 0;

/// 清空事件环与计数（探针在关键调用前用，确保看到的是"这一阶段"的序列）。
pub fn resetEvents() void {
    events = @splat(.{ .id = 0, .a0 = 0, .a1 = 0 });
    event_count = 0;
}

fn note(id: u8, a0: usize, a1: usize) void {
    events[event_count % events.len] = .{ .id = id, .a0 = a0, .a1 = a1 };
    event_count += 1;
    if (hooks.on_note) |f| f(id, a0, a1);
    if (budget > 0) {
        budget -= 1;
        if (budget == 0) {
            if (hooks.on_budget_exhausted) |f| f(event_count);
        }
    }
}

pub fn setHooks(h: Hooks) void {
    hooks = h;
}

fn shellRand() callconv(.c) u32 {
    var b: [4]u8 = undefined;
    if (hooks.fill_random) |f| {
        f(&b);
    } else {
        b = .{ 0x5a, 0xa5, 0x3c, 0xc3 };
    }
    return std.mem.readInt(u32, &b, .little);
}

/// `unsigned long` 在 ilp32 上就是 32 位。
fn shellRandom() callconv(.c) c_ulong {
    return shellRand();
}

/// esp_err 风格：0 = 成功。
fn shellGetRandom(buf: ?[*]u8, len: usize) callconv(.c) c_int {
    const p = buf orelse return -1;
    if (hooks.fill_random) |f| f(p[0..len]) else @memset(p[0..len], 0x5a);
    return 0;
}

fn shellEspTimerGetTime() callconv(.c) i64 {
    return if (hooks.now_us) |f| @intCast(f()) else 0;
}

fn shellLogTimestamp() callconv(.c) u32 {
    return if (hooks.now_us) |f| @intCast(f() / 1000) else 0;
}

fn shellReadMac(mac: ?[*]u8, mac_type: c_uint) callconv(.c) c_int {
    _ = mac_type;
    const p = mac orelse return -1;
    const m = if (hooks.mac) |f| f() else [6]u8{ 0x02, 0, 0, 0, 0, 0 };
    @memcpy(p[0..6], &m);
    return 0;
}

/// 中断/任务类钩子的调用计数。它们先做成**可观测的空操作**：
/// 若 blob 在 init 期间真的调了，计数非 0 → 说明必须把中断真接上；
/// 若一直是 0 → 说明 S31 这条路径不需要宿主中断（比留 null 崩掉快得多地"把未知变已知"）。
pub var calls: struct {
    set_intr: u32 = 0,
    clear_intr: u32 = 0,
    set_isr: u32 = 0,
    ints_on: u32 = 0,
    ints_off: u32 = 0,
    wifi_int_disable: u32 = 0,
    wifi_int_restore: u32 = 0,
    task_yield_from_isr: u32 = 0,
    task_delay: u32 = 0,
    /// 队列收发计数：泵任务实验必须看它们，否则"任务又阻塞了"无法区分
    /// "没人投递" 与 "投到了别的句柄"。
    queue_recv: u32 = 0,
    queue_send: u32 = 0,
} = .{};

/// 任务的假对象：**一个指针同时充当"创建时写出的 handle"与"当前任务"**。
/// 两者曾经是两个不同的全局，导致 ROM 的身份判断（"我是不是 wifi 任务"）永远为假。
/// blob 会解引用它的字段（实测 `lw s0,12(a0)` → 再把 s0 当指针解引用），
/// 所以必须是**足够大的清零缓冲**：单字节时 `+12` 读到相邻 `.bss`（实测 0x102），
/// 随后 `lw a5,0(s0)` 直接 fault（misaligned, mtval=0x102）。
var task_dummy: [256]u8 align(16) = @splat(0);

/// 主上下文自己的"任务"对象：**与 wifi 任务的 handle 必须是不同对象**。
///
/// `wifi_api_lock` 会用 `current_task_is_wifi_task()` 决定走哪条路：如果主上下文也自称
/// "我是 wifi 任务"，ioctl 会走"就地处理"分支（实测：没有 queue_send，直接自旋等任务侧状态）。
var main_task_dummy: [256]u8 align(16) = @splat(0);

/// 当前 CPU 属于哪个上下文（由调度器/探针维护）。
pub var current_is_task: bool = false;

/// `_set_intr(cpu, src, num, prio)`：把**外设源** `src` 路由到 **CPU 输入** `num`。
/// IDF 里是 `esp_rom_intr_matrix_set`；ROM 符号 `intr_matrix_set = 0x2f800768`。
/// 空桩会把 blob 的中断安装整个丢掉——它装不上 handler 就只能干等。
fn shellSetIntr(cpu: i32, src: u32, num: u32, prio: i32) callconv(.c) void {
    calls.set_intr += 1;
    note(31, (@as(usize, @intCast(src)) << 8) | (num & 0xFF), @intCast(@as(u32, @bitCast(prio))));
    const intr_matrix_set = @extern(*const fn (u32, u32, u32) callconv(.c) void, .{ .name = "intr_matrix_set" });
    intr_matrix_set(@intCast(cpu), src, num);
    // IDF 的 `set_intr_wrapper` 还会设优先级：CLIC 每输入 ctrl 字的 [31:24]。
    if (num < 32 and prio >= 0) {
        // CLIC ctrl 寄存器按 **CLIC ID = 外部号 + 16** 索引（IDF `esp_rom_clic.c:21`：
        // `CLIC_INT_CTRL_REG(rv_int_num + CLIC_EXT_INTR_NUM_OFFSET)`，offset = 16）。
        // 布局：prio [31:24]、trig [18:17]（0=电平，1=上升沿）、IE bit8。
        const ctl: *volatile u32 = @ptrFromInt(0x1080_1000 + (@as(usize, @intCast(num)) + 16) * 4);
        const trig: u32 = 0; // INTR_TYPE_LEVEL
        ctl.* = (ctl.* & ~(@as(u32, 0xFF00_0000) | (@as(u32, 3) << 17))) |
            (@as(u32, @intCast(prio & 0xFF)) << 24) | (trig << 17);
    }
}
fn shellClearIntr(src: u32, num: u32) callconv(.c) void {
    _ = .{ src, num };
    calls.clear_intr += 1;
}
/// `_set_isr(n, f, arg)`：把 handler 装到 CPU 输入 `n` 上（IDF 是 `esp_rom_intr_handler_set`；
/// ROM 符号 `intr_handler_set = 0x2f800764`，内部写 `s_intr_handlers[core][n] = {f, arg}`）。
fn shellSetIsr(n: i32, f: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    calls.set_isr += 1;
    note(32, @intCast(n), @intFromPtr(f));
    // 写**应用侧**的表（我们的 trap 才会分发它）——IDF 的 `s_intr_handlers` 就是应用侧。
    // **约定**：`n` 是 CLIC 输入号（blob 自己的编号，如 `mie |= 1<<25`），`trap.setHandler` 内部
    // 归一化到外部号（`n >= 16` 时存 `n-16`），与 `trapDispatch` 的查找口径一致。
    if (n >= 0) {
        const hf: ?*const fn (?*anyopaque) callconv(.c) void = if (f) |p| @ptrCast(@alignCast(p)) else null;
        @import("board").trap.setHandler(@intCast(n), hf, arg);
    }
    const intr_handler_set = @extern(*const fn (i32, ?*anyopaque, ?*anyopaque) callconv(.c) void, .{
        .name = "intr_handler_set",
    });
    intr_handler_set(n, f, arg);
}
/// `_ints_on(mask)`：打开 `mask` 里那些**外部中断号**的使能位。
/// S31 是 CLIC：ctrl 字下标 = **外部号 + 16**（IDF `esp_rom_clic.c:21` 的
/// `CLIC_INT_CTRL_REG(rv_int_num + CLIC_EXT_INTR_NUM_OFFSET)`，offset=16），bit8 = IE。
/// `mie` 的位是 **CLIC ID**（blob 自己写的是 `mie |= 1<<25`），所以 mask（外部号）要左移 16。
fn shellIntsOn(mask: u32) callconv(.c) void {
    calls.ints_on += 1;
    note(33, mask, 0);
    var m = mask;
    var i: usize = 0;
    while (m != 0 and i < 32) : (i += 1) {
        if ((m & 1) != 0) {
            const ctl: *volatile u32 = @ptrFromInt(0x1080_1000 + (i + 16) * 4);
            ctl.* |= (1 << 8); // IE
        }
        m >>= 1;
    }
    asm volatile ("csrs mie, %[m]"
        :
        : [m] "r" (@as(usize, mask) << 16),
        : .{ .memory = true });
}
fn shellIntsOff(mask: u32) callconv(.c) void {
    calls.ints_off += 1;
    var m = mask;
    var i: usize = 0;
    while (m != 0 and i < 32) : (i += 1) {
        if ((m & 1) != 0) {
            const ctl: *volatile u32 = @ptrFromInt(0x1080_1000 + (i + 16) * 4);
            ctl.* &= ~@as(u32, 1 << 8);
        }
        m >>= 1;
    }
    asm volatile ("csrc mie, %[m]"
        :
        : [m] "r" (@as(usize, mask) << 16),
        : .{ .memory = true });
}
/// 我们永远不在 ISR 里（MIE=0、无中断驱动），如实返回 false。
fn shellIsFromIsr() callconv(.c) bool {
    return false;
}
/// 全局关中断下"保存的状态"就是 0：没有可恢复的东西。
fn shellWifiIntDisable(mux: ?*anyopaque) callconv(.c) u32 {
    _ = mux;
    calls.wifi_int_disable += 1;
    return 0;
}
fn shellWifiIntRestore(mux: ?*anyopaque, saved: u32) callconv(.c) void {
    _ = .{ mux, saved };
    calls.wifi_int_restore += 1;
}
fn shellTaskYieldFromIsr() callconv(.c) void {
    calls.task_yield_from_isr += 1;
}
/// `_task_delay(ms)`：单线程壳里没有别的执行体，所以"延时"= **让出**并按注入时钟计时。
/// 每次让出跑一遍 `on_idle`（主循环），上限 `idle_spin_limit` 次——保证调用方一定能返回。
/// 时钟不可用（`now_us` 为 null）时退化为"让出固定次数"，绝不忙等。
fn shellTaskDelay(ms: u32) callconv(.c) void {
    calls.task_delay += 1;
    const start = if (hooks.now_us) |now| now() else 0;
    const want_us: u64 = @as(u64, ms) * 1000;
    var spins: u32 = 0;
    while (spins < idle_spin_limit) : (spins += 1) {
        serviceTimers();
        if (hooks.on_idle) |idle| idle();
        if (hooks.now_us) |now| {
            if (now() -% start >= want_us) return;
        }
    }
}
/// IDF 默认 tick = 1 ms，所以数值上就是 ms。
fn shellTaskMsToTick(ms: u32) callconv(.c) i32 {
    return @intCast(ms);
}
fn shellTaskGetCurrentTask() callconv(.c) ?*anyopaque {
    return if (current_is_task) @ptrCast(&task_dummy) else @ptrCast(&main_task_dummy);
}
fn shellTaskGetMaxPriority() callconv(.c) i32 {
    return 8;
}

/// 事件组：位集合。`_event_group_create` 必须返回**非空**指针——桩返回 0 时，
/// 驱动随后的 `_event_group_set_bits` 会解引用 null+偏移（实测 mtval=0xc 的 load access fault）。
pub const EventGroup = struct {
    bits: u32 = 0,
};

fn shellEventGroupCreate() callconv(.c) ?*anyopaque {
    const mem = arena_state.alloc(@sizeOf(EventGroup), @alignOf(EventGroup)) orelse return null;
    const g: *EventGroup = @ptrCast(@alignCast(mem));
    g.* = .{};
    return @ptrCast(g);
}

fn shellEventGroupDelete(p: ?*anyopaque) callconv(.c) void {
    shellSemphrDelete(p);
}

fn shellEventGroupSetBits(p: ?*anyopaque, bits: u32) callconv(.c) c_int {
    const g: *EventGroup = @ptrCast(@alignCast(p orelse return 0));
    g.bits |= bits;
    return 1;
}

fn shellEventGroupClearBits(p: ?*anyopaque, bits: u32) callconv(.c) c_int {
    const g: *EventGroup = @ptrCast(@alignCast(p orelse return 0));
    const prev = g.bits;
    g.bits &= ~bits;
    return @bitCast(prev);
}

/// 单线程下没有"等待"：返回当前位（等价于立即超时），不阻塞。
fn shellEventGroupWaitBits(
    p: ?*anyopaque,
    bits: u32,
    clear_on_exit: c_int,
    wait_all: c_int,
    blocking: u32,
) callconv(.c) u32 {
    const g: *EventGroup = @ptrCast(@alignCast(p orelse return 0));
    if (blocking == time_blocking) blocking_refused += 1;
    const want = if (wait_all != 0) bits else (g.bits & bits);
    const got = g.bits & bits;
    const ok = if (wait_all != 0) (got == bits) else (want != 0);
    if (ok and clear_on_exit != 0) g.bits &= ~bits;
    return got;
}

/// 极简"任务"：没有调度器，但 `xTaskCreate` 的返回值是 **pdPASS=1 / pdFAIL=0**（FreeRTOS 约定），
/// 通用桩返回 0 会被当成"创建失败"，`ic_create_wifi_task` 于是报 INVALID_ARG。
/// 这里记下入口与参数、返回 1；主循环需要时自己调用一次（协作式，不是抢占式）。
pub const Task = struct {
    entry: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
    /// 该任务的栈（按 `stack_depth` 从 arena 分配；`&.{}` = 还没建上下文）。
    stack: []u8 = &.{},
    /// 任务上下文（`sched.initContext` 建；`sp == 0` = 未初始化）。
    ctx: @import("sched.zig").Context = .{},
    /// 已经跑过（第一次进入后再让出即视为可再次调度）。
    started: bool = false,
};

/// 给一个任务建上下文（幂等）。栈按 `stack_depth` 从 arena 分；单位按 **字节**（IDF `xTaskCreate` 约定），
/// 夹在 4 KiB..64 KiB 之间——ROM 这条 osi 变体的实参单位未证实，夹紧比信一个未证实的单位安全。
pub fn ensureTaskContext(t: *Task, stack_depth: u32) bool {
    if (t.ctx.sp != 0) return true;
    const entry = t.entry orelse return false;
    var bytes: usize = if (stack_depth == 0) 16 * 1024 else @as(usize, stack_depth);
    if (bytes < 4 * 1024) bytes = 4 * 1024;
    if (bytes > 64 * 1024) bytes = 64 * 1024;
    // **按自然对齐申请**：arena 只接受自然对齐的请求（`pad != 0` 直接跳过），
    // 用 16 会让第一个块之后全部失败。栈顶 16 对齐由 `sched.initContext` 的 alignBackward 负责。
    const mem = arena_state.alloc(bytes, @alignOf(usize)) orelse return false;
    t.stack = mem[0..bytes];
    @import("sched.zig").initContext(&t.ctx, t.stack, entry, t.arg);
    return true;
}
pub var tasks: [4]Task = @splat(.{});
pub var task_count: usize = 0;
/// `_task_delete`：从任务表里移除该 handle 对应的槽位（桩不释放会让重复 init 泄漏槽位）。
fn shellTaskDelete(p: ?*anyopaque) callconv(.c) void {
    if (p == null) return;
    const target = @intFromPtr(p);
    var i: usize = 0;
    while (i < task_count) : (i += 1) {
        if (@intFromPtr(&tasks[i]) == target) {
            var j = i;
            while (j + 1 < task_count) : (j += 1) tasks[j] = tasks[j + 1];
            task_count -= 1;
            tasks[task_count] = .{};
            return;
        }
    }
}

fn shellTaskCreatePinned(
    entry: ?*const fn (?*anyopaque) callconv(.c) void,
    name: ?[*:0]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    handle_out: ?*?*anyopaque,
    core_id: u32,
) callconv(.c) c_int {
    _ = .{ name, prio, core_id };
    if (task_count >= tasks.len) return 0;
    tasks[task_count] = .{ .entry = entry, .arg = param };
    // **建上下文**：泵真任务需要栈与上下文；`stack_depth` 不再丢弃。
    _ = ensureTaskContext(&tasks[task_count], stack_depth);
    task_count += 1;
    // handle 与"当前任务"是同一个对象（见 `task_dummy` 的说明）。
    if (handle_out) |h| h.* = @ptrCast(&task_dummy);
    // 实验开关：返回 0(pdFAIL) 时，部分协议栈会改为"就地同步执行"那段工作，
    // 从而绕开"我们没有调度器"这个结构性问题。
    return if (task_create_fail) 0 else 1;
}

fn shellTaskCreate(
    entry: ?*const fn (?*anyopaque) callconv(.c) void,
    name: ?[*:0]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    handle_out: ?*?*anyopaque,
) callconv(.c) c_int {
    return shellTaskCreatePinned(entry, name, stack_depth, param, prio, handle_out, 0);
}

/// 自旋锁：单线程 + 关中断下没有竞争者，返回一个稳定的非空指针即可（驱动会判空）。
var spin_lock_dummy: u8 = 0;

fn shellSpinLockCreate() callconv(.c) ?*anyopaque {
    return @ptrCast(&spin_lock_dummy);
}

fn shellSpinLockDelete(p: ?*anyopaque) callconv(.c) void {
    _ = p;
}

fn shellMutexCreate() callconv(.c) ?*anyopaque {
    note(11, 0, 0);
    const mem = arena_state.alloc(@sizeOf(Mutex), @alignOf(Mutex)) orelse return null;
    const m: *Mutex = @ptrCast(@alignCast(mem));
    m.* = .{};
    return @ptrCast(m);
}

fn shellMutexDelete(p: ?*anyopaque) callconv(.c) void {
    shellSemphrDelete(p);
}

fn shellMutexLock(p: ?*anyopaque) callconv(.c) i32 {
    note(2, @intFromPtr(p), 0);
    const m: *Mutex = @ptrCast(@alignCast(p orelse return 0));
    return m.lock();
}

fn shellMutexUnlock(p: ?*anyopaque) callconv(.c) i32 {
    note(3, @intFromPtr(p), 0); // id 3 = mutex_unlock（此前没有 note，trace 里看不到解锁）
    const m: *Mutex = @ptrCast(@alignCast(p orelse return 0));
    return m.unlock();
}

/// `_wifi_create_queue` 返回的是**包装对象**：blob 会读它的**第一个字**当真正的队列句柄
/// （实测 `pp_create_task`：`lw a5,0(a0)` → 存全局 → 之后 `_queue_send(该值, …)`）。
/// 所以第一个字段必须是内部 `Queue` 的指针，不能是 `item_size` 之类的标量。
pub const WifiQueue = struct {
    inner: *Queue,
};

/// 最近一次 `_wifi_create_queue` 的包装体/内部队列地址（探针用它对账"坏指针来自哪个对象"）。
pub var last_wrapper: usize = 0;
pub var last_inner: usize = 0;

// ---------------------------------------------------------------------------
// 软件定时器（ets_timer 语义）：`_timer_setfn/_timer_arm/_timer_arm_us/_timer_disarm/_timer_done`
//
// S31 的 ROM 没有 `ets_timer_*`，这五个钩子只能应用侧实现。之前它们是空桩，意味着 blob 注册的
// 定时器**永远不会到期**——而 blob 的 coex/协议栈调度正是靠它推进（静态扫描：`_timer_done` 537、
// `_timer_disarm` 336、`_timer_setfn` 289 次引用）。
//
// 这里用**协作式软件定时器**：不占用硬件定时器/中断，由 `serviceTimers()` 在让出点推进。
// ---------------------------------------------------------------------------
const TimerEntry = struct {
    ptimer: ?*anyopaque = null,
    fn_: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
    deadline_us: u64 = 0,
    period_us: u64 = 0, // 0 = 一次性
    armed: bool = false,
};
var timers: [16]TimerEntry = @splat(TimerEntry{});
var timer_fires: u32 = 0;
/// 诊断：`Queue.send` 成功次数（前 8 次用 note(17) 记录 {队列指针, 之后 count}）。
var send_probe: u32 = 0;
/// 诊断：`Queue.send` 成功次数 / `Queue.recv` 成功次数 / 最近一次 recv 时的 count。
pub var send_ok: u32 = 0;
/// init 窗口对拍用的计数器（与 IDF 侧同口径）。
pub var cnt_reset_mac: u32 = 0;
pub var cnt_clk_en: u32 = 0;
/// init 窗口对拍：`_semphr_create` 的调用次数与返回 null 的次数。
pub var cnt_sem_create: u32 = 0;
pub var cnt_sem_create_null: u32 = 0;
/// 诊断：最近 4 次 `_semphr_create` 的 `(max, init_count)`（打包 max<<16|init），供与 blob 的调用形态对账。
pub var sem_create_args: [4]u32 = @splat(0);
pub var recv_ok: u32 = 0;
pub var last_recv_count: usize = 0;
/// 诊断用：已触发次数与"已武装且到点但还没 fire"的数量（见 `serviceTimers`）。
/// **诊断用强制上膛**：把"已 `setfn` 但未 armed"的定时器全部设成"立即到期、一次性"，
/// 交给 `serviceTimers()` 走真实路径 fire。返回被上膛的个数。
pub fn forceArmAll() u32 {
    const now = if (hooks.now_us) |f| f() else 0;
    var n: u32 = 0;
    for (&timers) |*t| {
        if (t.fn_ == null or t.armed) continue;
        t.armed = true;
        t.deadline_us = now;
        t.period_us = 0;
        n += 1;
    }
    return n;
}

pub fn timerStats() u64 {
    var n: u32 = 0;
    for (&timers) |*t| {
        if (t.armed) n += 1;
    }
    return (@as(u64, n) << 32) | @as(u64, timer_fires);
}

fn findTimer(ptimer: ?*anyopaque) ?*TimerEntry {
    for (&timers) |*t| {
        if (t.ptimer == ptimer) return t;
    }
    return null;
}

fn allocTimer(ptimer: ?*anyopaque) ?*TimerEntry {
    if (findTimer(ptimer)) |t| return t;
    for (&timers) |*t| {
        if (t.ptimer == null) {
            t.* = .{ .ptimer = ptimer };
            return t;
        }
    }
    return null;
}

fn shellTimerSetfn(ptimer: ?*anyopaque, fn_: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) usize {
    note(17, @intFromPtr(ptimer), @intFromPtr(fn_));
    const t = allocTimer(ptimer) orelse return 1;
    t.fn_ = fn_;
    t.arg = arg;
    return 0;
}

fn armTimerCommon(ptimer: ?*anyopaque, us: u64, repeat: bool) usize {
    note(18, @intFromPtr(ptimer), @intCast(us));
    const t = allocTimer(ptimer) orelse return 1;
    const now = if (hooks.now_us) |f| f() else 0;
    t.deadline_us = now + us;
    t.period_us = if (repeat) us else 0;
    t.armed = true;
    return 0;
}

fn shellTimerArm(ptimer: ?*anyopaque, ms: u32, repeat: bool) callconv(.c) usize {
    return armTimerCommon(ptimer, @as(u64, ms) * 1000, repeat);
}

fn shellTimerArmUs(ptimer: ?*anyopaque, us: u32, repeat: bool) callconv(.c) usize {
    return armTimerCommon(ptimer, us, repeat);
}

fn shellTimerDisarm(ptimer: ?*anyopaque) callconv(.c) usize {
    note(19, @intFromPtr(ptimer), 0);
    if (findTimer(ptimer)) |t| t.armed = false;
    return 0;
}

fn shellTimerDone(ptimer: ?*anyopaque) callconv(.c) usize {
    if (findTimer(ptimer)) |t| t.* = .{};
    return 0;
}

/// 由让出点（`on_idle`/`_task_delay`）调用：推进所有到期定时器。
pub fn serviceTimers() void {
    const now = if (hooks.now_us) |f| f() else return;
    for (&timers) |*t| {
        if (!t.armed or t.fn_ == null) continue;
        if (now < t.deadline_us) continue;
        if (t.period_us > 0) {
            t.deadline_us = now + t.period_us;
        } else {
            t.armed = false;
        }
        timer_fires +%= 1;
        note(16, @intFromPtr(t.ptimer), timer_fires);
        t.fn_.?(t.arg);
    }
}

/// `_phy_enable()`：IDF `esp_phy_enable()` 的等价物（幂等）。
///
/// 板级动机（ADR-001）：blob 的 `esp_wifi_start` 在任务上下文里轮询 WiFi MAC 块 `+0xAC`
/// 的 [15:13] 等硬件自清。这个钩子留成空桩时，PHY 在任务上下文里从未被真正打开，
/// 那三位永不清 → 任务恒定自旋。
var phy_enable_calls: u32 = 0;

fn shellPhyEnable(modem: u32) callconv(.c) usize {
    phy_enable_calls +%= 1;
    note(15, modem, phy_enable_calls);
    // 与 IDF 的 `esp_phy_enable` 一致：先保证 ICG 位图解除门控（见 `shellWifiClockEnable` 的注释）。
    const icg: *volatile u32 = @ptrFromInt(0x2010_9C0C);
    icg.* = 0x6464_6400;
    // IDF 的 `esp_phy_enable_wrapper` 还会调 `phy_wifi_enable_set(1)`（ROM `0x2f80145c`）——
    // 我们此前漏了这一步；若 libphy/ROM 的代码按这个标志门控，缺它 PHY 侧就不会真正使能。
    const phy_wifi_enable_set = @extern(*const fn (u8) callconv(.c) void, .{ .name = "phy_wifi_enable_set" });
    phy_wifi_enable_set(1);
    // **IDF 的第三步（我们此前完全没做）**：`esp_phy_enable_wrapper` 在 `phy_wifi_enable_set(1)` 之后
    // 调 `set_bb_wdg(true, false, 0x18, 0xaa, false, false, false)`，注释写着
    // "disable bb idle check(max: 139ms) for temporary to avoid unexpected RXTXPANIC"。
    // BB 的 idle check/看门狗默认是开的 —— 不关它，BB 可能在 139 ms 超时后复位，
    // MAC 的 TX/RX 状态机就永远不排空。`set_bb_wdg` 就在我们已链接的 libphy.a 里。
    const set_bb_wdg = @extern(*const fn (bool, bool, u16, u16, bool, bool, bool) callconv(.c) void, .{ .name = "set_bb_wdg" });
    set_bb_wdg(true, false, 0x18, 0xaa, false, false, false);
    // IDF 的顺序：`esp_phy_enable(modem)` 内部才做"共用时钟 → phy_module_enable → 首次标定"。
    // 探针注入的实现负责首次 `register_chipv7_phy`（它持有 phy_init_data/cal_data）。
    if (hooks.on_phy_enable) |f| _ = f(modem);
    // 重申 PHY 时钟位（MODEM_SYSCON.CLK_CONF1）与两个 FORCE_ON 寄存器，
    // 序列与探针的 init 完全一致；幂等，重复调用无害。
    const conf1: *volatile u32 = @ptrFromInt(0x2010_9C14);
    conf1.* |= (1 << 2) | (1 << 3) | (1 << 7) | (1 << 9) |
        (1 << 13) | (1 << 14) | (1 << 15) | (1 << 19) | (1 << 20) | (1 << 21);
    const fo_sys: *volatile u32 = @ptrFromInt(0x2010_9C08);
    fo_sys.* |= (1 << 2) | (1 << 3) | (1 << 4);
    const fo_lp: *volatile u32 = @ptrFromInt(0x2010_F01C);
    fo_lp.* |= (1 << 0) | (1 << 2);
    // **`SOC_PLL_SOURCE_CG`**：IDF 的 `modem_clock_hal_enable_soc_pll_source_cg()`（`modem_clock_hal.c:125`）
    // 就是 `HP_SYS_CLKRST.modem_conf.val = 0x3d`。它是 `PHY_CLOCK_DEPS` 的四项之一，我们此前**从未写过**。
    const modem_conf: *volatile u32 = @ptrFromInt(0x2058_71E0);
    modem_conf.* = 0x3d;
    return 0;
}

// ---------------------------------------------------------------------------
// coex 家族：**先只做可观测**。ROM 的 coex 调度器（`coexist_funcs`=0x2f07ff9c、
// `g_coa_funcs_p`=0x2f07ff98）会回调这些 app 侧钩子；它们一直是空桩，调度器拿不到
// interval/status，"可以开始发"的回调永远不会到 —— 与 MAC 的 TX/RX 一直 busy 吻合。
// 这一轮先看**谁被调用**，再决定实现语义。
// ---------------------------------------------------------------------------
fn shellCoexInit() callconv(.c) usize {
    note(23, 0, 0);
    // `libcoexist.a` 里就有真正的 `coex_init()`（我们链接了它）。
    const f = @extern(*const fn () callconv(.c) void, .{ .name = "coex_init" });
    f();
    return 0;
}
fn shellCoexEnable() callconv(.c) usize {
    note(24, 0, 0);
    // 空桩时 blob 的 coex 从未真正使能；`coex_enable()` 在 libcoexist.a 里。
    const f = @extern(*const fn () callconv(.c) void, .{ .name = "coex_enable" });
    f();
    return 0;
}
fn shellCoexStatusGet() callconv(.c) usize {
    note(25, 0, 0);
    return 0;
}
fn shellCoexPtiGet(kind: u32, pti: ?*u8) callconv(.c) usize {
    note(26, kind, @intFromPtr(pti));
    if (pti) |q| q.* = 0;
    return 0;
}
fn shellCoexWifiRequest(kind: u32, event: u32, latency: u32) callconv(.c) usize {
    note(27, kind, (@as(usize, event) << 16) | (latency & 0xFFFF));
    return 0;
}
fn shellCoexWifiRelease(kind: u32) callconv(.c) usize {
    note(28, kind, 0);
    return 0;
}
fn shellCoexSchmIntervalSet(interval: u32) callconv(.c) usize {
    note(29, interval, 0);
    return 0;
}
fn shellCoexRegisterStartCb(cb: ?*anyopaque) callconv(.c) usize {
    note(30, @intFromPtr(cb), 0);
    return 0;
}

/// `_wifi_clock_enable/disable` 与 `_wifi_reset_mac`：这三个同样是空桩。
/// 目前先做到"**可观测**"——在自旋前被调用就能从 trace 里看到；时钟位是幂等重申。
/// IDF `wifi_module_enable()` 的 `WIFI_CLOCK_DEPS`（`modem_clock_impl.c:14`）对应的 CLK_CONF1 位。
/// 位名来自 `modem_syscon_struct.h` 的 `clk_conf1` 位域（bit0..21）：
///   0 wifibb_22m / 1 wifibb_40m / 2 wifibb_44m / 3 wifibb_80m / 4 wifibb_40x / 5 wifibb_80x
///   6 wifibb_40x1 / 7 wifibb_80x1 / 8 wifibb_160x1 / **9 wifimac** / **10 wifi_apb**
///   13 fe_80m / 14 fe_160m / 15 fe_apb / 19 fe_pwdet_adc / 20 fe_adc / 21 fe_dac
/// 早先只置了 {2,3,7,9,13,14,15,19,20,21}——**缺 BB 主时钟组（0,1,4,5,6,8）与 WIFI_APB（10）**。
const wifi_clk_conf1_bits: u32 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) |
    (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) |
    (1 << 13) | (1 << 14) | (1 << 15) | (1 << 19) | (1 << 20) | (1 << 21);

fn shellWifiClockEnable() callconv(.c) usize {
    cnt_clk_en +%= 1;
    // ★ IDF 的 `wifi_module_enable()` → `modem_clock_module_enable()` 会先
    // `modem_clock_module_icg_map_init_all()`，把各域的 **ICG 位图**写进 `CLK_CONF_POWER_ST`(0x20109C0C)
    // —— 实测 IDF 工作值是 `0x64646400`。我们此前只写 CLK_CONF1，没写这张位图。
    const icg: *volatile u32 = @ptrFromInt(0x2010_9C0C);
    const icg_before = icg.*;
    icg.* = 0x6464_6400;
    note(20, icg_before, icg.*);
    const conf1: *volatile u32 = @ptrFromInt(0x2010_9C14);
    const before = conf1.*;
    conf1.* = before | wifi_clk_conf1_bits;
    // `WIFI_CLOCK_DEPS` 的最后一项 COEXIST 不在 CLK_CONF1 里：它在
    // `MODEM_LPCON(0x2010F000).clk_conf(+0x18)` 的 bit1（`modem_lpcon_ll_enable_coex_clock`）。
    const lpcon: *volatile u32 = @ptrFromInt(0x2010_F018);
    const lb = lpcon.*;
    lpcon.* = lb | (1 << 0) | (1 << 1) | (1 << 2); // wifipwr | coex | i2c_mst
    return 0;
}

fn shellWifiClockDisable() callconv(.c) usize {
    note(21, 0, 0);
    return 0;
}

/// `_wifi_reset_mac()` = IDF 的 `modem_clock_module_mac_reset(PERIPH_WIFI_MODULE)`，
/// 其内核是 `modem_syscon_ll_reset_wifimac()`：对 `MODEM_SYSCON.modem_rst_conf.rst_wifimac`
/// 打一个 1→0 的脉冲。
///   - `modem_rst_conf` 在 MODEM_SYSCON(0x20109C00) 的 **+0x10**（字段序：test_conf/clk_conf/
///     clk_conf_force_on(0x08)/clk_conf_power_st(0x0c)/modem_rst_conf(0x10)，与探针里
///     FORCE_ON=0x08、POWER_ST=0x0c、CLK_CONF1=0x14 三个锚点一致）；
///   - `rst_wifimac` 是 **bit 9**（`modem_syscon_struct.h` 里 reserved0..7 之后的第二位）。
fn shellWifiResetMac() callconv(.c) usize {
    cnt_reset_mac +%= 1;
    const rst: *volatile u32 = @ptrFromInt(0x2010_9C10);
    const before = rst.*;
    rst.* = before | (1 << 9);
    rst.* = rst.* & ~@as(u32, 1 << 9);
    note(22, before, rst.*);
    return 0;
}

fn shellWifiQueueCreate(len: u32, item_size: u32) callconv(.c) ?*anyopaque {
    const inner = shellQueueCreate(len, item_size) orelse return null;
    const mem = arena_state.alloc(@sizeOf(WifiQueue), @alignOf(WifiQueue)) orelse return null;
    const w: *WifiQueue = @ptrCast(@alignCast(mem));
    w.* = .{ .inner = @ptrCast(@alignCast(inner)) };
    last_wrapper = @intFromPtr(w);
    last_inner = @intFromPtr(inner);
    return @ptrCast(w);
}

/// `_wifi_thread_semphr_get()`：IDF 返回"当前线程的递归信号量"。单线程下就是一个全局信号量。
/// 桩返回 null 会让 init 的检查判成 NO_MEM（实测 rc=257，且 `hits` 里只有它和 `_task_delete`）。
var thread_semphr: ?*anyopaque = null;

fn shellThreadSemphrGet() callconv(.c) ?*anyopaque {
    if (thread_semphr == null) thread_semphr = shellSemphrCreate(1, 0);
    return thread_semphr;
}

fn shellWifiQueueDelete(p: ?*anyopaque) callconv(.c) void {
    const w: *WifiQueue = @ptrCast(@alignCast(p orelse return));
    shellQueueDelete(w.inner);
}

fn shellQueueCreate(len: u32, item_size: u32) callconv(.c) ?*anyopaque {
    if (len == 0 or item_size == 0) return null;
    const need = Queue.bytesNeeded(item_size, len);
    const mem = arena_state.alloc(need, @alignOf(Queue)) orelse return null;
    const q: *Queue = @ptrCast(@alignCast(mem));
    q.* = .{ .item_size = item_size, .cap = len };
    return @ptrCast(q);
}

fn shellQueueDelete(p: ?*anyopaque) callconv(.c) void {
    shellSemphrDelete(p);
}

/// 句柄必须落在 arena 内。blob 传进来一个**标量**当指针时，直接解引用会 fault
/// （实测 `_queue_send(8, …)` → `lw a0,4(s0)` 读 0xc）；先判边界就能把它变成一行日志。
fn inArena(p: ?*anyopaque) bool {
    const addr = @intFromPtr(p orelse return false);
    return addr >= arena_state.base and addr < arena_state.base + arena_state.bytes_total;
}

/// 句柄有两种形态，ROM 两个都存过（`-228(s3)` 存包装体、`0x2f07ff0c` 存首字），
/// 所以收发钩子必须都能接受：
///
/// - **裸 `*Queue`**（`_queue_create` 的返回）：首字是 `item_size`（小标量）；
/// - **包装体 `WifiQueue`**（`_wifi_create_queue` 的返回）：首字是指向 arena 内的 `*Queue`。
///
/// 判别是无歧义的：标量不可能落进 arena 地址区间。包装体再做一次自洽检查
/// （内部队列的 `item_size`/`cap` 必须非 0），避免把野指针当队列。
fn unwrapQueue(p: ?*anyopaque) ?*Queue {
    const raw = p orelse return null;
    if (!inArena(raw)) return null;
    const word0 = @as(*const usize, @ptrCast(@alignCast(raw))).*;
    if (word0 >= arena_state.base and word0 < arena_state.base + arena_state.bytes_total) {
        const inner: *Queue = @ptrFromInt(word0);
        if (inner.item_size > 0 and inner.cap > 0) return inner;
    }
    return @ptrCast(@alignCast(raw));
}

fn shellQueueSend(p: ?*anyopaque, item: ?*const anyopaque, blocking: u32) callconv(.c) i32 {
    calls.queue_send += 1;
    // a1 带上载荷首字：`wifi_ipc_process` 的坏指针就来自消息内容，需要看到消息流。
    // 载荷可能只有 4 字节（item_size 小），按字节读首字，别假设对齐。
    const first_word: usize = if (item) |it| blk: {
        const b: [*]const u8 = @ptrCast(it);
        var w: usize = 0;
        var i: usize = 0;
        while (i < @sizeOf(usize)) : (i += 1) w |= @as(usize, b[i]) << @intCast(8 * i);
        break :blk w;
    } else 0;
    note(5, @intFromPtr(p), first_word);
    const q = unwrapQueue(p) orelse {
        bad_handle += 1;
        return 0;
    };
    const bytes: [*]const u8 = @ptrCast(item orelse return 0);
    return q.send(bytes[0..q.item_size], blocking);
}

fn shellQueueSendFront(p: ?*anyopaque, item: ?*const anyopaque, blocking: u32) callconv(.c) i32 {
    _ = blocking; // 队首插入不阻塞（满了直接失败）
    const q = unwrapQueue(p) orelse return 0;
    const bytes: [*]const u8 = @ptrCast(item orelse return 0);
    return q.sendFront(bytes[0..q.item_size]);
}

fn shellQueueRecv(p: ?*anyopaque, item: ?*anyopaque, blocking: u32) callconv(.c) i32 {
    calls.queue_recv += 1;
    note(4, @intFromPtr(p), blocking);
    const q_probe = unwrapQueue(p);
    if (q_probe) |q0| {
        recv_probe += 1;
        if (recv_probe <= 6) note(14, q0.count, q0.item_size);
    }
    const q = unwrapQueue(p) orelse {
        bad_handle += 1;
        return 0;
    };
    const bytes: [*]u8 = @ptrCast(item orelse return 0);
    return q.recv(bytes[0..q.item_size], blocking);
}

fn shellQueueMsgWaiting(p: ?*anyopaque) callconv(.c) u32 {
    const q = unwrapQueue(p) orelse return 0;
    return q.msgWaiting();
}

/// 把已实现的钩子填进表；未实现的保持 null（调用到会立刻崩，好过静默错值）。
pub fn makeTable() osi.Osi {
    var t = osi.empty;
    t._malloc = @ptrCast(&shellMalloc);
    t._free = @ptrCast(&shellFree);
    t._malloc_internal = @ptrCast(&shellMallocInternal);
    t._zalloc_internal = @ptrCast(&shellZallocInternal);
    t._calloc_internal = @ptrCast(&shellCallocInternal);
    t._realloc_internal = @ptrCast(&shellReallocInternal);
    t._wifi_malloc = @ptrCast(&shellMallocInternal);
    t._wifi_zalloc = @ptrCast(&shellZallocInternal);
    t._wifi_calloc = @ptrCast(&shellCallocInternal);
    t._wifi_realloc = @ptrCast(&shellReallocInternal);
    t._get_free_heap_size = @ptrCast(&shellFreeHeapSize);
    t._semphr_create = @ptrCast(&shellSemphrCreate);
    t._semphr_delete = @ptrCast(&shellSemphrDelete);
    t._semphr_take = @ptrCast(&shellSemphrTake);
    t._semphr_give = @ptrCast(&shellSemphrGive);
    t._nvs_open = @ptrCast(&shellNvsOpen);
    t._nvs_close = @ptrCast(&shellNvsClose);
    t._nvs_commit = @ptrCast(&shellNvsCommit);
    t._nvs_set_i8 = @ptrCast(&shellNvsSetI8);
    t._nvs_get_i8 = @ptrCast(&shellNvsGetI8);
    t._nvs_set_u8 = @ptrCast(&shellNvsSetU8);
    t._nvs_get_u8 = @ptrCast(&shellNvsGetU8);
    t._nvs_set_u16 = @ptrCast(&shellNvsSetU16);
    t._nvs_get_u16 = @ptrCast(&shellNvsGetU16);
    t._nvs_set_blob = @ptrCast(&shellNvsSetBlob);
    t._nvs_get_blob = @ptrCast(&shellNvsGetBlob);
    t._nvs_erase_key = @ptrCast(&shellNvsEraseKey);
    t._rand = @ptrCast(&shellRand);
    t._random = @ptrCast(&shellRandom);
    t._get_random = @ptrCast(&shellGetRandom);
    t._esp_timer_get_time = @ptrCast(&shellEspTimerGetTime);
    t._log_timestamp = @ptrCast(&shellLogTimestamp);
    t._read_mac = @ptrCast(&shellReadMac);
    t._event_group_create = @ptrCast(&shellEventGroupCreate);
    t._event_group_delete = @ptrCast(&shellEventGroupDelete);
    t._event_group_set_bits = @ptrCast(&shellEventGroupSetBits);
    t._event_group_clear_bits = @ptrCast(&shellEventGroupClearBits);
    t._event_group_wait_bits = @ptrCast(&shellEventGroupWaitBits);
    t._task_delete = @ptrCast(&shellTaskDelete);
    t._task_create_pinned_to_core = @ptrCast(&shellTaskCreatePinned);
    t._task_create = @ptrCast(&shellTaskCreate);
    t._set_intr = @ptrCast(&shellSetIntr);
    t._clear_intr = @ptrCast(&shellClearIntr);
    t._set_isr = @ptrCast(&shellSetIsr);
    t._ints_on = @ptrCast(&shellIntsOn);
    t._ints_off = @ptrCast(&shellIntsOff);
    t._is_from_isr = @ptrCast(&shellIsFromIsr);
    t._wifi_int_disable = @ptrCast(&shellWifiIntDisable);
    t._wifi_int_restore = @ptrCast(&shellWifiIntRestore);
    t._task_yield_from_isr = @ptrCast(&shellTaskYieldFromIsr);
    t._task_delay = @ptrCast(&shellTaskDelay);
    t._task_ms_to_tick = @ptrCast(&shellTaskMsToTick);
    t._task_get_current_task = @ptrCast(&shellTaskGetCurrentTask);
    t._task_get_max_priority = @ptrCast(&shellTaskGetMaxPriority);
    t._spin_lock_create = @ptrCast(&shellSpinLockCreate);
    t._spin_lock_delete = @ptrCast(&shellSpinLockDelete);
    t._mutex_create = @ptrCast(&shellMutexCreate);
    t._recursive_mutex_create = @ptrCast(&shellMutexCreate);
    t._mutex_delete = @ptrCast(&shellMutexDelete);
    t._mutex_lock = @ptrCast(&shellMutexLock);
    t._mutex_unlock = @ptrCast(&shellMutexUnlock);
    t._queue_create = @ptrCast(&shellQueueCreate);
    t._queue_delete = @ptrCast(&shellQueueDelete);
    // `_wifi_create_queue`/`_wifi_delete_queue` 是 IDF 的"内部队列"变体，语义同 queue_create/delete。
    // 板级实测：`pp_create_task` 用 `(len=200, item_size=8)` 调 index 94，桩返回 0 → 257(NO_MEM)。
    // coex 家族：先观测（谁被 ROM 的 coex 调度器回调）。
    t._coex_init = @ptrCast(&shellCoexInit);
    t._coex_enable = @ptrCast(&shellCoexEnable);
    t._coex_status_get = @ptrCast(&shellCoexStatusGet);
    t._coex_pti_get = @ptrCast(&shellCoexPtiGet);
    t._coex_wifi_request = @ptrCast(&shellCoexWifiRequest);
    t._coex_wifi_release = @ptrCast(&shellCoexWifiRelease);
    t._coex_schm_interval_set = @ptrCast(&shellCoexSchmIntervalSet);
    t._coex_register_start_cb = @ptrCast(&shellCoexRegisterStartCb);
    // 这三个曾长期是空桩：blob 的 MAC 时钟/复位路径全靠它们（静态引用 19/5 处）。
    t._wifi_clock_enable = @ptrCast(&shellWifiClockEnable);
    t._wifi_clock_disable = @ptrCast(&shellWifiClockDisable);
    t._wifi_reset_mac = @ptrCast(&shellWifiResetMac);
    // 软件定时器五件套：空桩时 blob 注册的定时器永不到期，调度永远不推进。
    t._timer_setfn = @ptrCast(&shellTimerSetfn);
    t._timer_arm = @ptrCast(&shellTimerArm);
    t._timer_arm_us = @ptrCast(&shellTimerArmUs);
    t._timer_disarm = @ptrCast(&shellTimerDisarm);
    t._timer_done = @ptrCast(&shellTimerDone);
    // `_phy_enable`：真正的 PHY 上电（空桩时 blob 的 `esp_wifi_start` 会卡在 MAC+0xAC 轮询）。
    t._phy_enable = @ptrCast(&shellPhyEnable);
    t._wifi_create_queue = @ptrCast(&shellWifiQueueCreate);
    t._wifi_delete_queue = @ptrCast(&shellWifiQueueDelete);
    t._wifi_thread_semphr_get = @ptrCast(&shellThreadSemphrGet);
    t._event_post = @ptrCast(&shellEventPost);
    t._queue_send = @ptrCast(&shellQueueSend);
    t._queue_recv = @ptrCast(&shellQueueRecv);
    t._queue_send_to_front = @ptrCast(&shellQueueSendFront);
    t._queue_send_to_back = @ptrCast(&shellQueueSend);
    t._queue_msg_waiting = @ptrCast(&shellQueueMsgWaiting);
    // 剩下的一律填具名桩：表里不再有 null，被调用时按索引计数（见 osi_stubs.zig）。
    stubs.fill(&t);
    return t;
}

/// 仍然为 null 的钩子（下一步照这张单子填）。由 `osi.zig` 的 128 个字段减去 `makeTable()` 实际赋值的
/// 那些、再减去 `_version`/`_magic` 两个数据字段得出。
/// 注意 `_log_write`/`_log_writev` 是 C 变参函数，**Zig 无法定义**，要么写一小段 C shim，要么保持 null。
/// 已实现的钩子名（由 makeTable() 里实际赋值的字段生成）。
pub const implemented = [_][]const u8{
    "_set_intr",               "_clear_intr",                 "_set_isr",               "_ints_on",
    "_ints_off",               "_is_from_isr",                "_spin_lock_create",      "_spin_lock_delete",
    "_wifi_int_disable",       "_wifi_int_restore",           "_task_yield_from_isr",   "_semphr_create",
    "_semphr_delete",          "_semphr_take",                "_semphr_give",           "_wifi_thread_semphr_get",
    "_mutex_create",           "_recursive_mutex_create",     "_mutex_delete",          "_mutex_lock",
    "_mutex_unlock",           "_queue_create",               "_queue_delete",          "_queue_send",
    "_queue_send_to_back",     "_queue_send_to_front",        "_queue_recv",            "_queue_msg_waiting",
    "_event_group_create",     "_event_group_delete",         "_event_group_set_bits",  "_event_group_clear_bits",
    "_event_group_wait_bits",  "_task_create_pinned_to_core", "_task_create",           "_task_delete",
    "_task_delay",             "_task_ms_to_tick",            "_task_get_current_task", "_task_get_max_priority",
    "_malloc",                 "_free",                       "_event_post",            "_get_free_heap_size",
    "_rand",                   "_phy_enable",                 "_read_mac",              "_timer_arm",
    "_timer_disarm",           "_timer_done",                 "_timer_setfn",           "_timer_arm_us",
    "_wifi_reset_mac",         "_wifi_clock_enable",          "_wifi_clock_disable",    "_esp_timer_get_time",
    "_nvs_set_i8",             "_nvs_get_i8",                 "_nvs_set_u8",            "_nvs_get_u8",
    "_nvs_set_u16",            "_nvs_get_u16",                "_nvs_open",              "_nvs_close",
    "_nvs_commit",             "_nvs_set_blob",               "_nvs_get_blob",          "_nvs_erase_key",
    "_get_random",             "_random",                     "_log_timestamp",         "_malloc_internal",
    "_realloc_internal",       "_calloc_internal",            "_zalloc_internal",       "_wifi_malloc",
    "_wifi_realloc",           "_wifi_calloc",                "_wifi_zalloc",           "_wifi_create_queue",
    "_wifi_delete_queue",      "_coex_init",                  "_coex_enable",           "_coex_status_get",
    "_coex_wifi_request",      "_coex_wifi_release",          "_coex_pti_get",          "_coex_schm_interval_set",
    "_coex_register_start_cb",
};

/// 仍然为桩的钩子（`_version`/`_magic` 是数据字段，不计入）。
pub const unimplemented = [_][]const u8{
    "_env_is_chip",                     "_queue_send_from_isr",            "_dport_access_stall_other_cpu_start_wrap", "_dport_access_stall_other_cpu_end_wrap",
    "_wifi_pm_sleep_lock_acquire",      "_wifi_pm_sleep_lock_release",     "_phy_disable",                             "_phy_update_country_info",
    "_wifi_rtc_enable_iso",             "_wifi_rtc_disable_iso",           "_get_time",                                "_slowclk_cal_get",
    "_log_write",                       "_log_writev",                     "_coex_deinit",                             "_coex_disable",
    "_coex_condition_set",              "_coex_wifi_channel_set",          "_coex_event_duration_get",                 "_coex_schm_status_bit_clear",
    "_coex_schm_status_bit_set",        "_coex_schm_interval_get",         "_coex_schm_curr_period_get",               "_coex_schm_curr_phase_get",
    "_coex_schm_process_restart",       "_coex_schm_register_cb",          "_regdma_link_set_write_wait_content",      "_sleep_retention_find_link_by_id",
    "_coex_schm_flexible_period_set",   "_coex_schm_flexible_period_get",  "_coex_schm_get_phase_by_idx",              "_coex_configure_preemption_end_cb",
    "_wifi_disable_ac_ax",              "_wifi_bb_sleep_retention_attach", "_wifi_bb_sleep_retention_detach",          "_wifi_mac_sleep_retention_attach",
    "_wifi_mac_sleep_retention_detach",
};
