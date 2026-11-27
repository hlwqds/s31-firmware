//! radio-coex：胶水的公共部分——配置、生命周期状态机、调用记录。
//!
//! 三处 IDF C 源拼起来就是这里的全部语义（路径相对 IDF 的 `components/`）：
//!
//!   * `esp_coex/src/coexist.c:306-311`（`init_coexist`，SECONDARY 级、优先级 204）：
//!     启动时先 `esp_coex_adapter_register(&g_coex_adapter_funcs)`，再 `coex_pre_init()`。
//!   * `esp_wifi/src/wifi_init.c:451-459`：`esp_wifi_init()` 在 `esp_wifi_init_internal()`
//!     之前调 `coex_init()`（tickless 空闲且硬件 TSF 时还先登记低功耗时钟回调）。
//!   * `bt/controller/esp32s31/bt.c:222/304/141/112`：`btdm_coex_init/enable/disable/deinit`
//!     分别落在 controller 的 init / enable / disable / deinit 里。
//!
//! IDF 自己没有"共存顺序检查"——它靠调用方的状态机保证顺序（`esp_wifi_init` 的
//! `s_wifi_inited`、bt.c 的 `s_btdm_controller_status`），乱序时那些上层回
//! `ESP_ERR_INVALID_STATE`。裸机移植里调用方换成了我们的接线，所以把同样的顺序规则
//! 集中到 `State` 上：乱序调用**不进核心**、计一次 `rejected`、回同一个
//! `ESP_ERR_INVALID_STATE`。
//!
//! 每个钩子进入时都给自己计一次 `calls`（"记录调用"）。
//!
//! 本文件只 import 同组件的兄弟文件与 `std`，不碰硬件，所以主机与板侧共用一份。
//!
//! 它同时是模块根：`firmware` 侧把本文件映射成一个模块后，其余文件经文件末尾的转出口到达
//! （`<模块>.wifi`、`<模块>.ble`、`<模块>.bind` …）。

const std = @import("std");

pub const adapter = @import("adapter.zig");
pub const core = @import("core.zig");

pub const ESP_OK = core.ESP_OK;
pub const ESP_ERR_INVALID_STATE = core.ESP_ERR_INVALID_STATE;

// ---------------------------------------------------------------------------
// 配置：IDF 的编译期宏换成运行期开关，默认值取 esp32s31 的 IDF 默认配置
// ---------------------------------------------------------------------------

pub const Config = struct {
    /// `CONFIG_SW_COEXIST_ENABLE`（`esp_coex/Kconfig:9-14`：两个射频同时使能时默认 y；
    /// 本仓 `firmware/idf-bootstrap` 的 sdkconfig 里为 1）
    sw_coexist: bool = true,
    /// `CONFIG_ESP_COEX_EXTERNAL_COEXIST_ENABLE`（`esp_coex/Kconfig:23-26`，默认 n；
    /// esp_adapter.c 里用的是 sdkconfig.rename 映射前的旧名 `CONFIG_EXTERNAL_COEX_ENABLE`）
    external_coexist: bool = false,
    /// `CONFIG_ESP_COEX_POWER_MANAGEMENT`（`esp_coex/Kconfig:32-36`，默认 n）
    power_management: bool = false,
    /// `CONFIG_BT_LE_ISO_SUPPORT`（`bt/porting_btdm/controller/ble/Kconfig.in:120-122`，默认 n）
    ble_iso: bool = false,
    /// `CONFIG_FREERTOS_USE_TICKLESS_IDLE`（`freertos/Kconfig:319-324`，依赖 `PM_ENABLE`，
    /// 默认 n；本仓 sdkconfig 未定义）。`SOC_WIFI_HW_TSF` 在 esp32s31 上恒为 1
    /// （`soc/esp32s31/include/soc/soc_caps.h:629`），所以它单独决定 wifi_init.c:451-453。
    tickless_idle: bool = false,

    /// esp_adapter.c 里反复出现的 `CONFIG_SW_COEXIST_ENABLE || CONFIG_EXTERNAL_COEX_ENABLE`
    pub fn coexOn(self: Config) bool {
        return self.sw_coexist or self.external_coexist;
    }
};

/// esp32s31 上恒为 1 的两个 SoC 能力位，写在这里免得别处再写数字：
/// `SOC_BLE_ISO_SUPPORTED`（`soc_caps.h:646`）决定 esp_adapter.c:627 的条件只剩 `CONFIG_SW_COEXIST_ENABLE`；
/// `SOC_COEX_HW_PTI`（`soc_caps.h:506`）决定 `coex_pti_get` 这个声明存在。
pub const soc_ble_iso_supported = true;
pub const soc_coex_hw_pti = true;

// ---------------------------------------------------------------------------
// 钩子清单
// ---------------------------------------------------------------------------

/// 本组件的每个入口：IDF 自己的两个生命周期入口、Wi-Fi osi 表的 23 个包装函数、
/// BLE 侧的 20 个函数、公共 API `esp_coex_version_get`。下标即 `calls`/`rejected` 的下标。
pub const Hook = enum(u8) {
    boot,
    wifi_init,

    coex_init_wrapper,
    coex_deinit_wrapper,
    coex_enable_wrapper,
    coex_disable_wrapper,
    coex_status_get_wrapper,
    coex_wifi_request_wrapper,
    coex_wifi_release_wrapper,
    coex_wifi_channel_set_wrapper,
    coex_event_duration_get_wrapper,
    coex_pti_get_wrapper,
    coex_schm_status_bit_clear_wrapper,
    coex_schm_status_bit_set_wrapper,
    coex_schm_interval_set_wrapper,
    coex_schm_interval_get_wrapper,
    coex_schm_curr_period_get_wrapper,
    coex_schm_curr_phase_get_wrapper,
    coex_schm_process_restart_wrapper,
    coex_schm_register_cb_wrapper,
    coex_register_start_cb_wrapper,
    coex_schm_flexible_period_set_wrapper,
    coex_schm_flexible_period_get_wrapper,
    coex_schm_get_phase_by_idx_wrapper,
    coex_configure_preemption_end_cb_wrapper,

    btdm_coex_init,
    btdm_coex_deinit,
    btdm_coex_enable,
    btdm_coex_disable,
    wr_btdm_coex_schm_status_bit_set,
    wr_btdm_coex_schm_status_bit_clear,
    wr_btdm_coex_schm_register_btdm_callback,
    wr_btdm_coex_schm_interval_get,
    wr_btdm_coex_schm_curr_period_get,
    wr_btdm_coex_schm_curr_phase_get,
    wr_btdm_coex_register_wifi_channel_change_callback,
    wr_btdm_coex_wifi_channel_get,
    wr_btdm_coex_version_get,
    wr_btdm_coex_iso_start,
    wr_btdm_coex_iso_stop,
    wr_btdm_coex_iso_protect_frame_thres_get,
    wr_btdm_coex_iso_start_int_handle,
    wr_btdm_coex_iso_end_int_handle,
    wr_btdm_coex_ble_idle_time_inform,
    wr_btdm_coex_register_ble_cb,

    esp_coex_version_get,
};

pub const hook_count: usize = @typeInfo(Hook).@"enum".field_names.len;

pub fn hookName(h: Hook) [:0]const u8 {
    return @typeInfo(Hook).@"enum".field_names[@backingInt(h)];
}

// ---------------------------------------------------------------------------
// 生命周期状态机
// ---------------------------------------------------------------------------

pub const Side = enum(u1) { wifi, ble };

/// 一侧（Wi-Fi 或 BLE）相对共存核的位置：init 之前、init 之后 enable 之前、enable 之后。
pub const SideState = enum(u8) { idle, inited, enabled };

pub const State = struct {
    /// `boot()` 成功：适配表已注册、`coex_pre_init` 已回 ESP_OK。
    booted: bool = false,
    wifi: SideState = .idle,
    ble: SideState = .idle,

    pub const Phase = enum { reset, pre_inited, inited };

    pub fn phase(self: State) Phase {
        if (!self.booted) return .reset;
        return if (self.wifi == .idle and self.ble == .idle) .pre_inited else .inited;
    }

    pub fn side(self: State, s: Side) SideState {
        return switch (s) {
            .wifi => self.wifi,
            .ble => self.ble,
        };
    }

    pub fn setSide(self: *State, s: Side, v: SideState) void {
        switch (s) {
            .wifi => self.wifi = v,
            .ble => self.ble = v,
        }
    }
};

pub const Error = error{
    /// `install()` 还没调：没有核心可转发。
    NoCore,
    /// 核心函数表有空槽。
    IncompleteCore,
    /// 配置里软件/外部共存都没开：IDF 在这套配置下没有 `init_coexist`（coexist.c:300）。
    CoexDisabled,
    /// `boot()` 调了第二次。
    AlreadyBooted,
    /// 启动序没走完（适配表未注册、`coex_pre_init` 未成功）就碰核心。
    NotBooted,
    /// 适配表有空的钩子，`adapter.build` 拒绝。
    AdapterIncomplete,
    /// `esp_coex_adapter_register` 返回非 0。
    AdapterRegisterFailed,
    /// `coex_pre_init` 返回非 0。
    PreInitFailed,
    /// 该侧还没 `coex_init` 就 enable。
    NotInited,
    /// IDF 上层自己的 init 被调了第二次（`esp_wifi_init` 对 `s_wifi_inited` 回 INVALID_STATE）。
    AlreadyInited,
    /// 该侧已经 enable 又 enable。
    AlreadyEnabled,
    /// 该侧没 enable 就 disable。
    NotEnabled,
    /// 该侧还 enabled 就 deinit（`wifi_deinit_internal` 的 "Wi-Fi not stop"）。
    Busy,
};

/// BLE 回调的影子记录（按 type）。核心自己按 type 保存（`coex_env+16/+20`），在使能计数
/// 升到 2 时调 type 0、降回 1 时调 type 1；这里只记"谁注册了什么、核心收没收"。
pub const BleCb = struct {
    func: ?*const anyopaque = null,
    ret: c_int = ESP_OK,
};

// ---------------------------------------------------------------------------
// 胶水实例
// ---------------------------------------------------------------------------

pub const Glue = struct {
    installed: bool = false,
    core: core.Core = .{},
    cfg: Config = .{},
    state: State = .{},
    /// 必须是静态存储：`esp_coex_adapter_register` 只存指针（IDF 用全局 `g_coex_adapter_funcs`）。
    adapter_table: adapter.AdapterTable = .{},
    ble_cb: [2]BleCb = .{ .{}, .{} },
    calls: [hook_count]u32 = @splat(0),
    rejected: [hook_count]u32 = @splat(0),
    last_error: ?Error = null,
    /// 最近一次核心调用的返回值（esp_err_t / int 类）。
    last_core_rc: c_int = ESP_OK,
    /// 每个钩子进入时的可选回调（接线层的诊断用）：计数之后、处理之前调用。默认没有。
    on_enter: ?*const fn (Hook) void = null,
    /// enable / disable 返回时的可选回调（钩子名、返回值）。在状态迁移**之后**调用，
    /// 所以此刻读到的就是迁移结果。默认没有。
    on_leave: ?*const fn (Hook, c_int) void = null,

    /// 钩子第一行：给自己计一次。
    pub fn enter(self: *Glue, h: Hook) void {
        self.calls[@backingInt(h)] +%= 1;
        if (self.on_enter) |f| f(h);
    }

    /// enable / disable 的收尾：状态已更新，把返回值交给回调。
    pub fn leave(self: *Glue, h: Hook, rc: c_int) void {
        if (self.on_leave) |f| f(h, rc);
    }

    fn deny(self: *Glue, h: Hook, e: Error) void {
        self.rejected[@backingInt(h)] +%= 1;
        self.last_error = e;
    }

    fn fail(self: *Glue, h: Hook, e: Error) Error {
        self.deny(h, e);
        return e;
    }

    /// "按关闭分支作答"的判定，条件是 esp_adapter.c 的
    /// `CONFIG_SW_COEXIST_ENABLE || CONFIG_EXTERNAL_COEX_ENABLE`：
    ///   * 配置里没开共存——IDF 的包装函数本就是桩，不算拒绝；
    ///   * 开了但还没 `boot()`——IDF 里不可能发生（`init_coexist` 在启动期），
    ///     真核心此时适配表未注册，会解引用空指针。这里降级成同样的桩并记一次拒绝。
    pub fn off(self: *Glue, h: Hook) bool {
        if (!self.cfg.coexOn()) return true;
        if (!self.state.booted) {
            self.deny(h, error.NotBooted);
            return true;
        }
        return false;
    }

    /// 同 `off()`，条件换成 BLE 侧的 `CONFIG_SW_COEXIST_ENABLE`（btdm_coex.c 每个 `#if`）。
    pub fn swOff(self: *Glue, h: Hook) bool {
        if (!self.cfg.sw_coexist) return true;
        return self.off(h);
    }

    fn ready(self: *Glue, h: Hook) Error!void {
        if (!self.installed) return self.fail(h, error.NoCore);
        if (!self.cfg.coexOn()) return self.fail(h, error.CoexDisabled);
        if (!self.state.booted) return self.fail(h, error.NotBooted);
    }

    /// IDF `init_coexist`（coexist.c:306-311）：适配表注册 → `coex_pre_init`。
    ///
    /// IDF 不看这两个返回值（恒回 ESP_OK；`startup_internal.h:62-63` 规定这个函数只能回
    /// ESP_OK，否则启动中止）。这里把失败报出来并停在未启动态，后续钩子按"未启动"降级。
    pub fn boot(self: *Glue, hooks: adapter.Hooks) Error!void {
        self.enter(.boot);
        if (!self.installed) return self.fail(.boot, error.NoCore);
        if (!self.cfg.coexOn()) return self.fail(.boot, error.CoexDisabled);
        if (self.state.booted) return self.fail(.boot, error.AlreadyBooted);
        self.adapter_table = adapter.build(hooks) catch return self.fail(.boot, error.AdapterIncomplete);
        const rc = self.core.adapter_register.?(&self.adapter_table);
        self.last_core_rc = rc;
        if (rc != ESP_OK) return self.fail(.boot, error.AdapterRegisterFailed);
        const rc2 = self.core.pre_init.?();
        self.last_core_rc = rc2;
        if (rc2 != ESP_OK) return self.fail(.boot, error.PreInitFailed);
        self.state.booted = true;
    }

    /// `esp_wifi_init()` 里与共存有关的部分（wifi_init.c:451-459）：可选的低功耗时钟回调
    /// 登记，然后 `coex_init()`。这是 Wi-Fi 侧**唯一**的 init 入口：esp32s31 的 Wi-Fi 归档
    /// 不引用 osi 下标 384（`_coex_init`），见 `initSide` 的说明。
    pub fn wifiInit(self: *Glue, lpclk_cb: ?*const anyopaque) Error!c_int {
        self.enter(.wifi_init);
        try self.ready(.wifi_init);
        // enable 期间（Wi-Fi 没 stop）再 init：wifi_init.c:208-211 的 "Wi-Fi not stop" 那一层
        if (self.state.wifi == .enabled) return self.fail(.wifi_init, error.Busy);
        if (self.cfg.tickless_idle and lpclk_cb != null) {
            self.core.wifi_register_update_lpclk_callback.?(lpclk_cb);
        }
        return self.initSide(.wifi, .wifi_init, false);
    }

    /// `coex_init`（Wi-Fi 与 BLE 共用）。核心返回 ESP_OK 才把该侧记成 inited。
    ///
    /// `once`：该侧已经 inited 时再 init 要不要拒绝。
    ///   * BLE 要（`esp_bt_controller_init` 要求 status 是 IDLE，bt.c:192-194）：`btdm_coex_deinit`
    ///     会把本组件的 BLE 侧复位回 idle，所以"没 deinit 就又 init"分辨得出来。
    ///   * Wi-Fi 不要：IDF 的 Wi-Fi 路径上 `coex_deinit` 没有调用者——C 层 `wifi_deinit_internal`
    ///     没有共存调用，两个 Wi-Fi 归档对 osi 下标 388（`_coex_deinit`）零引用——一侧一旦 inited
    ///     就回不到 idle，而 "stop → esp_wifi_deinit → esp_wifi_init" 是合法序列；
    ///     `esp_wifi_init` 自己的重复检查在 Wi-Fi 驱动里（wifi_init.c:374-377）。
    pub fn initSide(self: *Glue, s: Side, h: Hook, once: bool) c_int {
        if (self.off(h)) return ESP_OK;
        const st = self.state.side(s);
        const refusal: ?Error = switch (st) {
            .idle => null,
            .inited => if (once) error.AlreadyInited else null,
            .enabled => error.Busy,
        };
        if (refusal) |e| {
            self.deny(h, e);
            return ESP_ERR_INVALID_STATE;
        }
        const rc = self.core.init.?();
        self.last_core_rc = rc;
        if (rc == ESP_OK) self.state.setSide(s, .inited);
        return rc;
    }

    /// `coex_enable`（Wi-Fi 与 BLE 共用）。核心返回 ESP_OK 才把该侧记成 enabled。
    pub fn enableSide(self: *Glue, s: Side, h: Hook) c_int {
        if (self.off(h)) return ESP_OK;
        const st = self.state.side(s);
        if (st != .inited) {
            self.deny(h, if (st == .idle) error.NotInited else error.AlreadyEnabled);
            const refused = ESP_ERR_INVALID_STATE;
            self.leave(h, refused);
            return refused;
        }
        const rc = self.core.enable.?();
        self.last_core_rc = rc;
        if (rc == ESP_OK) self.state.setSide(s, .enabled);
        self.leave(h, rc);
        return rc;
    }

    /// `coex_disable`（Wi-Fi 与 BLE 共用）。
    pub fn disableSide(self: *Glue, s: Side, h: Hook) void {
        if (self.off(h)) return;
        if (self.state.side(s) != .enabled) {
            self.deny(h, error.NotEnabled);
            self.leave(h, ESP_ERR_INVALID_STATE);
            return;
        }
        self.core.disable.?();
        self.state.setSide(s, .inited);
        self.leave(h, ESP_OK);
    }

    /// `coex_deinit_wrapper`（esp_adapter.c:444-449）。
    pub fn wifiDeinit(self: *Glue, h: Hook) void {
        if (self.off(h)) return;
        if (self.state.wifi == .enabled) {
            self.deny(h, error.Busy);
            return;
        }
        self.core.deinit.?();
        self.state.wifi = .idle;
    }

    /// `btdm_coex_deinit`（btdm_coex.c:213-217）是空函数，不碰核心。IDF 在
    /// `esp_bt_controller_init` 的失败回滚路径上也会调到它（bt.c:277-280），
    /// 所以 idle 态下调它合法。
    pub fn bleDeinit(self: *Glue, h: Hook) void {
        if (self.state.ble == .enabled) {
            self.deny(h, error.Busy);
            return;
        }
        self.state.ble = .idle;
    }
};

// ---------------------------------------------------------------------------
// 单例：C ABI 钩子的签名里没有上下文指针，所以都作用在这一个实例上
// ---------------------------------------------------------------------------

var singleton: Glue = .{};

/// BT controller 经胶水的两个钩子置 / 清过状态位之后，核里那 5 个状态字各是什么——照反汇编的语义镜像
/// （`fake.zig`：`coex_schm_status_bit_set` 对 type > 4 不理，低 16 位有效）。核里真实的字读不到：
/// `coex_status_get(bitmap)` 只在 bitmap 之外还有别的状态字非零时才回核的状态，不是读字。ADR-003 第 5 节
/// L4b 的「BLE 的状态位非 0」看下标 1。Wi-Fi blob 直接调核、不经胶水的钩子，它那一份在 `wifi-blobs` 的
/// `CoexTraceStats.set_last`。
pub var bt_status_words: [5]u16 = @splat(0);

pub fn mirrorBtStatus(st_type: u32, status: u32, set: bool) void {
    if (st_type > 4) return;
    const bits: u16 = @truncate(status);
    if (set) bt_status_words[st_type] |= bits else bt_status_words[st_type] &= ~bits;
}

/// 核回调两个射频的「都开了共存」入口各被触发了多少次（ADR-003 第 5 节 L4b 的「两侧的 start 回调被触发」）：Wi-Fi 经
/// `_coex_register_start_cb` 登记的那个，与 BLE 经 `coex_register_ble_cb` 登记在 type 0 下的那个——按反汇编的
/// `coex_core_enable`，两个射频都开了共存（计数升到 2）时核先调前者、再调后者。blob 登记的函数指针换成这里的跳板：
/// 跳板记一次数，再调 blob 的函数。别的登记（schm 的按 type 回调、BLE type 1 的回调）原样转给核。
pub var wifi_start_calls: u32 = 0;
pub var ble_start_calls: u32 = 0;
pub var blob_wifi_start: ?*const fn () callconv(.c) c_int = null;
pub var blob_ble_start: ?*const fn () callconv(.c) void = null;

pub fn wifiStartTrampoline() callconv(.c) c_int {
    wifi_start_calls += 1;
    return if (blob_wifi_start) |cb| cb() else 0;
}

pub fn bleStartTrampoline() callconv(.c) void {
    ble_start_calls += 1;
    if (blob_ble_start) |cb| cb();
}

/// 测试与板侧自检用：把跳板记的数与存下的两个 blob 回调清掉。
pub fn resetStartCounters() void {
    wifi_start_calls = 0;
    ble_start_calls = 0;
    blob_wifi_start = null;
    blob_ble_start = null;
}

pub fn instance() *Glue {
    return &singleton;
}

/// 装核心与配置。核心表不全直接报错，免得钩子里解空指针。
pub fn install(c: core.Core, cfg: Config) Error!void {
    if (!c.complete()) return error.IncompleteCore;
    singleton = .{ .installed = true, .core = c, .cfg = cfg };
}

/// 测试与板侧自检用：换核心前存一份、跑完还原，不污染生产实例。
pub fn snapshot() Glue {
    return singleton;
}

pub fn restore(s: Glue) void {
    singleton = s;
}

pub fn boot(hooks: adapter.Hooks) Error!void {
    return singleton.boot(hooks);
}

pub fn wifiInit(lpclk_cb: ?*const anyopaque) Error!c_int {
    return singleton.wifiInit(lpclk_cb);
}

/// `esp_coex_version_get`（coexist.c:43-46）：回核心的版本串。它不在任何 `#if` 里，
/// 也不依赖启动序，所以不受守卫约束。
pub fn esp_coex_version_get() callconv(.c) ?[*:0]const u8 {
    const g = instance();
    g.enter(.esp_coex_version_get);
    return if (g.installed) g.core.version_get.?() else null;
}

// ---------------------------------------------------------------------------
// 读数
// ---------------------------------------------------------------------------

pub fn calls(h: Hook) u32 {
    return singleton.calls[@backingInt(h)];
}

pub fn rejected(h: Hook) u32 {
    return singleton.rejected[@backingInt(h)];
}

pub fn lastError() ?Error {
    return singleton.last_error;
}

pub fn state() State {
    return singleton.state;
}

pub fn config() Config {
    return singleton.cfg;
}

pub fn adapterTable() *const adapter.AdapterTable {
    return &singleton.adapter_table;
}

/// 经 `wr_btdm_coex_register_ble_cb` 登记成功（核心回 ESP_OK）的 BLE 回调，按 type。
/// `kind` 不是 0/1 时回 null。
pub fn bleCallback(kind: u8) ?*const anyopaque {
    return if (kind < 2) singleton.ble_cb[kind].func else null;
}

comptime {
    if (hook_count != 46) @compileError("glue.Hook 条数变了：同步 README 的钩子表");
}

// ---------------------------------------------------------------------------
// 模块根：其余文件的转出口
// ---------------------------------------------------------------------------

pub const wifi = @import("wifi.zig");
pub const ble = @import("ble.zig");
pub const fake = @import("fake.zig");
pub const bind = @import("bind.zig");
/// PHY 与时钟域的归属模型（ADR-003 §4）。纯逻辑，不在钩子路径上。
pub const owner = @import("owner.zig");
