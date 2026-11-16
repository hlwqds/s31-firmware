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

// ---------------------------------------------------------------------------
// 把原语接成 `Osi` 表（C 调用约定的薄壳）
//
// 这些壳只做类型转换与池化，语义全在上面四个原语里。函数指针按 ilp32 都是 4 字节，
// 用 `@ptrCast` 填进 `?*const anyopaque` 字段即可。
// ---------------------------------------------------------------------------

var arena_state: Arena = .{};
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
    return shellMalloc(size);
}
fn shellZallocInternal(size: usize) callconv(.c) ?*anyopaque {
    const p = shellMalloc(size) orelse return null;
    @memset(@as([*]u8, @ptrCast(p))[0..size], 0);
    return p;
}
fn shellCallocInternal(n: usize, size: usize) callconv(.c) ?*anyopaque {
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
    const mem = arena_state.alloc(@sizeOf(Semphr), @alignOf(Semphr)) orelse return null;
    const s: *Semphr = @ptrCast(@alignCast(mem));
    s.* = .{ .count = @min(init_count, max), .max = max };
    return @ptrCast(s);
}

fn shellSemphrDelete(p: ?*anyopaque) callconv(.c) void {
    const q: ?[*]u8 = if (p) |v| @ptrCast(v) else null;
    arena_state.free(q);
}

fn shellSemphrTake(p: ?*anyopaque, blocking: u32) callconv(.c) i32 {
    const s: *Semphr = @ptrCast(@alignCast(p orelse return 0));
    return s.take(blocking);
}

fn shellSemphrGive(p: ?*anyopaque) callconv(.c) i32 {
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
fn shellNvsGetBlob(handle: u32, key: ?[*:0]const u8, out: ?*anyopaque, length: ?*usize) callconv(.c) c_int {
    const p: [*]u8 = @ptrCast(out orelse return nvs.err_invalid_arg);
    const l = length orelse return nvs.err_invalid_arg;
    return nvs.getBlob(handle, key orelse return nvs.err_invalid_arg, p[0..l.*], l);
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
};

var hooks: Hooks = .{};

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
} = .{};

var task_dummy: u8 = 0;

fn shellSetIntr(cpu: i32, src: u32, num: u32, prio: i32) callconv(.c) void {
    _ = .{ cpu, src, num, prio };
    calls.set_intr += 1;
}
fn shellClearIntr(src: u32, num: u32) callconv(.c) void {
    _ = .{ src, num };
    calls.clear_intr += 1;
}
fn shellSetIsr(n: i32, f: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    _ = .{ n, f, arg };
    calls.set_isr += 1;
}
fn shellIntsOn(mask: u32) callconv(.c) void {
    _ = mask;
    calls.ints_on += 1;
}
fn shellIntsOff(mask: u32) callconv(.c) void {
    _ = mask;
    calls.ints_off += 1;
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
fn shellTaskDelay(ms: u32) callconv(.c) void {
    _ = ms;
    calls.task_delay += 1;
}
/// IDF 默认 tick = 1 ms，所以数值上就是 ms。
fn shellTaskMsToTick(ms: u32) callconv(.c) i32 {
    return @intCast(ms);
}
fn shellTaskGetCurrentTask() callconv(.c) ?*anyopaque {
    return @ptrCast(&task_dummy);
}
fn shellTaskGetMaxPriority() callconv(.c) i32 {
    return 8;
}

/// 极简"任务"：没有调度器，但 `xTaskCreate` 的返回值是 **pdPASS=1 / pdFAIL=0**（FreeRTOS 约定），
/// 通用桩返回 0 会被当成"创建失败"，`ic_create_wifi_task` 于是报 INVALID_ARG。
/// 这里记下入口与参数、返回 1；主循环需要时自己调用一次（协作式，不是抢占式）。
pub const Task = struct {
    entry: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
};
pub var tasks: [4]Task = @splat(.{});
pub var task_count: usize = 0;
var task_handle_dummy: u8 = 0;

fn shellTaskCreatePinned(
    entry: ?*const fn (?*anyopaque) callconv(.c) void,
    name: ?[*:0]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    handle_out: ?*?*anyopaque,
    core_id: u32,
) callconv(.c) c_int {
    _ = .{ name, stack_depth, prio, core_id };
    if (task_count >= tasks.len) return 0;
    tasks[task_count] = .{ .entry = entry, .arg = param };
    task_count += 1;
    if (handle_out) |h| h.* = @ptrCast(&task_handle_dummy);
    return 1; // pdPASS
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
    const mem = arena_state.alloc(@sizeOf(Mutex), @alignOf(Mutex)) orelse return null;
    const m: *Mutex = @ptrCast(@alignCast(mem));
    m.* = .{};
    return @ptrCast(m);
}

fn shellMutexDelete(p: ?*anyopaque) callconv(.c) void {
    shellSemphrDelete(p);
}

fn shellMutexLock(p: ?*anyopaque) callconv(.c) i32 {
    const m: *Mutex = @ptrCast(@alignCast(p orelse return 0));
    return m.lock();
}

fn shellMutexUnlock(p: ?*anyopaque) callconv(.c) i32 {
    const m: *Mutex = @ptrCast(@alignCast(p orelse return 0));
    return m.unlock();
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

fn shellQueueSend(p: ?*anyopaque, item: ?*const anyopaque, blocking: u32) callconv(.c) i32 {
    const q: *Queue = @ptrCast(@alignCast(p orelse return 0));
    const bytes: [*]const u8 = @ptrCast(item orelse return 0);
    return q.send(bytes[0..q.item_size], blocking);
}

fn shellQueueSendFront(p: ?*anyopaque, item: ?*const anyopaque, blocking: u32) callconv(.c) i32 {
    _ = blocking; // 队首插入不阻塞（满了直接失败）
    const q: *Queue = @ptrCast(@alignCast(p orelse return 0));
    const bytes: [*]const u8 = @ptrCast(item orelse return 0);
    return q.sendFront(bytes[0..q.item_size]);
}

fn shellQueueRecv(p: ?*anyopaque, item: ?*anyopaque, blocking: u32) callconv(.c) i32 {
    const q: *Queue = @ptrCast(@alignCast(p orelse return 0));
    const bytes: [*]u8 = @ptrCast(item orelse return 0);
    return q.recv(bytes[0..q.item_size], blocking);
}

fn shellQueueMsgWaiting(p: ?*anyopaque) callconv(.c) u32 {
    const q: *const Queue = @ptrCast(@alignCast(p orelse return 0));
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
    t._queue_send = @ptrCast(&shellQueueSend);
    t._queue_recv = @ptrCast(&shellQueueRecv);
    t._queue_send_to_front = @ptrCast(&shellQueueSendFront);
    t._queue_send_to_back = @ptrCast(&shellQueueSend);
    t._queue_msg_waiting = @ptrCast(&shellQueueMsgWaiting);
    // 剩下的一律填具名桩：表里不再有 null，被调用时按索引计数（见 osi_stubs.zig）。
    stubs.fill(&t);
    return t;
}

/// 仍然为 null 的钩子（下一步照这张单子填）。由 `osi.zig` 的 128 个字段减去上面 21 个得出；
/// 中断/任务/定时器/事件/NVS/PHY 这些要么需要真实硬件路径，要么需要 IDF 的 C 层配合。
/// 仍然为 null 的钩子（下一步照这张单子填）。
/// 注意 `_log_write`/`_log_writev` 是 C 变参函数，**Zig 无法定义**，要么写一小段 C shim，要么保持 null。
/// 仍然为 null 的钩子（下一步照这张单子填）。
/// 注意 `_log_write`/`_log_writev` 是 C 变参函数，**Zig 无法定义**，要么写一小段 C shim，要么保持 null。
/// 已实现的钩子名（由 makeTable() 里实际赋值的字段生成）。
pub const implemented = [_][]const u8{
    "_set_intr",              "_clear_intr",       "_set_isr",           "_ints_on",            "_ints_off",               "_is_from_isr",
    "_spin_lock_create",      "_spin_lock_delete", "_wifi_int_disable",  "_wifi_int_restore",   "_task_yield_from_isr",    "_semphr_create",
    "_semphr_delete",         "_semphr_take",      "_semphr_give",       "_mutex_create",       "_recursive_mutex_create", "_mutex_delete",
    "_mutex_lock",            "_mutex_unlock",     "_queue_create",      "_queue_delete",       "_queue_send",             "_queue_send_to_back",
    "_queue_send_to_front",   "_queue_recv",       "_queue_msg_waiting", "_task_delay",         "_task_ms_to_tick",        "_task_get_current_task",
    "_task_get_max_priority", "_malloc",           "_free",              "_get_free_heap_size", "_rand",                   "_read_mac",
    "_esp_timer_get_time",    "_nvs_set_i8",       "_nvs_get_i8",        "_nvs_set_u8",         "_nvs_get_u8",             "_nvs_set_u16",
    "_nvs_get_u16",           "_nvs_open",         "_nvs_close",         "_nvs_commit",         "_nvs_set_blob",           "_nvs_get_blob",
    "_nvs_erase_key",         "_get_random",       "_random",            "_log_timestamp",      "_malloc_internal",        "_realloc_internal",
    "_calloc_internal",       "_zalloc_internal",  "_wifi_malloc",       "_wifi_realloc",       "_wifi_calloc",            "_wifi_zalloc",
};

/// 仍然为桩的钩子（`_version`/`_magic` 是数据字段，不计入）。
pub const unimplemented = [_][]const u8{
    "_env_is_chip",                             "_wifi_thread_semphr_get",                "_queue_send_from_isr",            "_event_group_create",
    "_event_group_delete",                      "_event_group_set_bits",                  "_event_group_clear_bits",         "_event_group_wait_bits",
    "_task_create_pinned_to_core",              "_task_create",                           "_task_delete",                    "_event_post",
    "_dport_access_stall_other_cpu_start_wrap", "_dport_access_stall_other_cpu_end_wrap", "_wifi_pm_sleep_lock_acquire",     "_wifi_pm_sleep_lock_release",
    "_phy_disable",                             "_phy_enable",                            "_phy_update_country_info",        "_timer_arm",
    "_timer_disarm",                            "_timer_done",                            "_timer_setfn",                    "_timer_arm_us",
    "_wifi_reset_mac",                          "_wifi_clock_enable",                     "_wifi_clock_disable",             "_wifi_rtc_enable_iso",
    "_wifi_rtc_disable_iso",                    "_get_time",                              "_slowclk_cal_get",                "_log_write",
    "_log_writev",                              "_wifi_create_queue",                     "_wifi_delete_queue",              "_coex_init",
    "_coex_deinit",                             "_coex_enable",                           "_coex_disable",                   "_coex_status_get",
    "_coex_condition_set",                      "_coex_wifi_request",                     "_coex_wifi_release",              "_coex_wifi_channel_set",
    "_coex_event_duration_get",                 "_coex_pti_get",                          "_coex_schm_status_bit_clear",     "_coex_schm_status_bit_set",
    "_coex_schm_interval_set",                  "_coex_schm_interval_get",                "_coex_schm_curr_period_get",      "_coex_schm_curr_phase_get",
    "_coex_schm_process_restart",               "_coex_schm_register_cb",                 "_coex_register_start_cb",         "_regdma_link_set_write_wait_content",
    "_sleep_retention_find_link_by_id",         "_coex_schm_flexible_period_set",         "_coex_schm_flexible_period_get",  "_coex_schm_get_phase_by_idx",
    "_coex_configure_preemption_end_cb",        "_wifi_disable_ac_ax",                    "_wifi_bb_sleep_retention_attach", "_wifi_bb_sleep_retention_detach",
    "_wifi_mac_sleep_retention_attach",         "_wifi_mac_sleep_retention_detach",
};
