//! IDF porting 层的 C 函数（**不在归档里**）在裸机侧的 Zig 实现。
//!
//! 这 9 个函数原本住在 `components/bt/porting_btdm/...` 的 C 里。照 IDF 原文逐条读过之后，
//! 除了 `btdm_lp_enable_clock`（要动 CNNT/modem 域的时钟门控与 BT MAC 复位）之外，
//! 其余**都不是硬活**：4 个是 `return 0`，`ble_controller_scan_duplicate_config` 是
//! NimBLE **host** 侧的扫描去重（controller-only 构建没有 host，归档里也从不引用它），
//! `ble_msys_init` 只是转调归档里的 `r_esp_ble_msys_init`。
const std = @import("std");
const osal = @import("osal.zig");
const config = @import("config.zig");

// ---------------------------------------------------------------------------
// 4 个 `return 0`（IDF 原文：日志/外部/共存/低功耗的"初始化"在没有对应子系统时是空实现）
// ---------------------------------------------------------------------------

/// `btdm_log.c`：`return 0;`
pub fn btdmLogInit() c_int {
    return 0;
}

/// `btdm_external.c`：`return 0;`
pub fn btdmExternalInit() c_int {
    return 0;
}

/// `btdm_coex.c`：`CONFIG_SW_COEXIST_ENABLE` 关时 `return ESP_OK;`（我们不开软件共存）
pub fn btdmCoexInit() c_int {
    return 0;
}

/// `btdm_lp.c`：`UC_BT_CTRL_SLEEP_ENABLE=0` 且无 `CONFIG_PM_ENABLE` ⇒ 两个分支都不进，`return ESP_OK;`
pub fn btdmLpInit() c_int {
    return 0;
}

/// `ble.c` 的扫描去重：调的是 `ble_vhci_disc_duplicate_mode_disable/enable` 与
/// `ble_vhci_disc_duplicate_set_max_cache_size` —— 那是 **NimBLE host 侧**的过滤器，
/// 既不在归档里、归档也从不引用（`grep ble_vhci` 在全归档零命中）。
/// controller-only 构建没有 host ⇒ 空实现是对的，**别去找它们的定义**。
pub fn bleControllerScanDuplicateConfig() void {}

// ---------------------------------------------------------------------------
// msys：`ble_msys.c:67-72` 转调归档的 `r_esp_ble_msys_init`
// ---------------------------------------------------------------------------

/// 取值来自 `host/nimble/Kconfig.in:480-511` 的 **SOC_ESP_NIMBLE_CONTROLLER 分支**（S31 就是）。
pub const msys = struct {
    pub const block1_count: u16 = 24; // default 24 if SOC_ESP_NIMBLE_CONTROLLER
    pub const block1_size: u16 = 128; // default 128 if SOC_ESP_NIMBLE_CONTROLLER
    pub const block2_count: u16 = 24;
    pub const block2_size: u16 = 320;
    pub const from_heap: c_int = 1; // BT_NIMBLE_MSYS_BUF_FROM_HEAP default y
};

extern fn r_esp_ble_msys_init(
    s1_size: u32,
    s2_size: u32,
    s1_count: u16,
    s2_count: u16,
    from_heap: c_int,
) c_int;

/// 只在目标构建里引用归档符号；主机侧返回 0（主机没有 msys 子系统）。
pub fn bleMsysInit() c_int {
    if (@import("builtin").os.tag != .freestanding) return 0;
    // `SYSINIT_MSYS_n_MEMBLOCK_SIZE = BLE_MSYS_ALIGN(size, 4)`；128/320 本来就是 4 的倍数。
    return r_esp_ble_msys_init(msys.block1_size, msys.block2_size, msys.block1_count, msys.block2_count, msys.from_heap);
}

// ---------------------------------------------------------------------------
// mempool：IDF 在池空时会回退动态 malloc，我们的静态池**没有回退**
// ⇒ 必须做容量校验，并把 5 个数字打出来，否则"池不够"会表现成 controller 不动
// ---------------------------------------------------------------------------

/// IDF 的 `btdm_memblock_get` 失败码是 -1..-10；这里用 -1 表示"容量不够"，
/// 并把每个超标项单独编号，便于一眼看出是哪一类池。
pub const MempoolErr = struct {
    pub const evt: c_int = -1;
    pub const evtq: c_int = -2;
    pub const co: c_int = -3;
    pub const sem: c_int = -4;
    pub const mutex: c_int = -5;
};

/// 静态池容量（与 `osal.zig` 的池一致；那里也有一条用例断言"默认 config 的 element 数 ≤ 容量"）。
pub const pool_caps = struct {
    pub const evt: u16 = osal.pool_caps.event;
    pub const evtq: u16 = osal.pool_caps.eventq;
    pub const co: u16 = osal.pool_caps.callout;
    pub const sem: u16 = osal.pool_caps.sem;
    pub const mutex: u16 = osal.pool_caps.mutex;
};

/// 复刻 `btdm_osal_elem_mempool_init(&elem)` 的**校验**部分：
/// IDF 会按 `elem` 的 5 个计数建池；我们只能从静态池取，所以超了就直接报错。
pub fn elemMempoolInit(elem: config.ElemNum) c_int {
    if (elem.evt_count > pool_caps.evt) {
        osal.logPublic("bt mempool: evt {d} > cap {d}", .{ elem.evt_count, pool_caps.evt });
        return MempoolErr.evt;
    }
    if (elem.evtq_count > pool_caps.evtq) {
        osal.logPublic("bt mempool: evtq {d} > cap {d}", .{ elem.evtq_count, pool_caps.evtq });
        return MempoolErr.evtq;
    }
    if (elem.co_count > pool_caps.co) {
        osal.logPublic("bt mempool: co {d} > cap {d}", .{ elem.co_count, pool_caps.co });
        return MempoolErr.co;
    }
    if (elem.sem_count > pool_caps.sem) {
        osal.logPublic("bt mempool: sem {d} > cap {d}", .{ elem.sem_count, pool_caps.sem });
        return MempoolErr.sem;
    }
    if (elem.mutex_count > pool_caps.mutex) {
        osal.logPublic("bt mempool: mutex {d} > cap {d}", .{ elem.mutex_count, pool_caps.mutex });
        return MempoolErr.mutex;
    }
    osal.logPublic("bt mempool: ok evt={d} evtq={d} co={d} sem={d} mutex={d}", .{
        elem.evt_count, elem.evtq_count, elem.co_count, elem.sem_count, elem.mutex_count,
    });
    return 0;
}

/// 一步到位：`seed + elemCalc → 容量校验`，就是 `bt.c:172-186` 那三步。
pub fn prepareMempool(cfg: *const config.Config) c_int {
    const elem = config.mempoolElemNum(cfg);
    return elemMempoolInit(elem);
}

test "porting: 4 个空实现都返回 0，扫描去重是空操作" {
    try std.testing.expectEqual(@as(c_int, 0), btdmLogInit());
    try std.testing.expectEqual(@as(c_int, 0), btdmExternalInit());
    try std.testing.expectEqual(@as(c_int, 0), btdmCoexInit());
    try std.testing.expectEqual(@as(c_int, 0), btdmLpInit());
    bleControllerScanDuplicateConfig();
    try std.testing.expectEqual(@as(c_int, 0), bleMsysInit()); // 主机侧早退
}

test "porting: mempool 容量校验按类报错，默认 config 通过" {
    // 默认 config 算出来 181 个事件 ⇒ 192 够
    try std.testing.expectEqual(@as(c_int, 0), prepareMempool(&config.defaults()));
    // 人为超限：每类各报自己的错误码
    var over = config.ElemNum{ .evt_count = 999, .evtq_count = 0, .co_count = 0, .sem_count = 0, .mutex_count = 0 };
    try std.testing.expectEqual(MempoolErr.evt, elemMempoolInit(over));
    over = .{ .evt_count = 0, .evtq_count = 999 };
    try std.testing.expectEqual(MempoolErr.evtq, elemMempoolInit(over));
    over = .{ .co_count = 999 };
    try std.testing.expectEqual(MempoolErr.co, elemMempoolInit(over));
    over = .{ .sem_count = 999 };
    try std.testing.expectEqual(MempoolErr.sem, elemMempoolInit(over));
    over = .{ .mutex_count = 999 };
    try std.testing.expectEqual(MempoolErr.mutex, elemMempoolInit(over));
}
