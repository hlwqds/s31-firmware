# radio-coex — BLE 与 Wi-Fi 共存胶水（ESP32-S31）

把 ESP-IDF 里围绕共存核的三层 C 胶水逐项写成可主机测试的 Zig：

| IDF 的 C | 本组件 |
| --- | --- |
| `esp_coex/esp32s31/esp_coex_adapter.c`：`coex_adapter_funcs_t` 适配表 | `adapter.zig` |
| `esp_wifi/esp32s31/esp_adapter.c` 的 `coex_*_wrapper`：Wi-Fi osi 表的 24 个共存表项 | `wifi.zig` |
| `bt/porting_btdm/controller/btdm_common/src/btdm_coex.c`：16 个 `wr_btdm_coex_*` + 4 个生命周期函数 | `ble.zig` |
| `esp_coex/src/coexist.c` 的 `init_coexist` / `esp_coex_version_get`、`wifi_init.c` / `bt.c` 的调用顺序 | `glue.zig` |
| （IDF 没有）可注入的核心函数表 | `core.zig`，目标板由 `bind.zig` 填真实符号 |

**本组件不是仲裁器。** 仲裁器是 ROM 里的 coex 代码加 `libcoexist.a`；这里只做它们外面的薄转发，
外加一层 IDF 自己没有、而裸机移植需要的顺序守卫。设计背景见 `docs/adr/ADR-003-ble-wifi-coexistence.md`。

## 范围与来源

"规范"就是 IDF v6.1 的源码（下文路径相对 `~/esp/esp-idf/components/`，行号均本次逐行读过）：

| 事实 | 出处 |
| --- | --- |
| 适配表：`_version`=2、`_magic`=0xDEADBEAF、20 个字段（1 + 18 个钩子 + 1） | `esp_coex/include/private/esp_coexist_adapter.h:16-17`、`:21-52`；18 个钩子各是什么见 `esp_coex/esp32s31/esp_coex_adapter.c:160-181` |
| Wi-Fi osi 表的 24 个共存字段及其顺序 | `esp_wifi/include/esp_private/wifi_os_adapter.h:132-161`；赋值在 `esp_wifi/esp32s31/esp_adapter.c:796-822` |
| 每个 Wi-Fi 包装函数的转发目标与 `#if` 条件 | `esp_adapter.c:435-632` |
| 16 个 `wr_btdm_coex_*` 与 4 个生命周期函数 | `bt/porting_btdm/controller/btdm_common/src/btdm_coex.c:40-235`；调用点 `bt/controller/esp32s31/bt.c:112/141/222/304` |
| 核心入口的声明 | `esp_coex/include/private/esp_coexist_internal.h:43-326`；`btdm_coex.c:15-24` 的 extern |
| 启动序：适配表注册 → `coex_pre_init` | `esp_coex/src/coexist.c:306-311`（`ESP_SYSTEM_INIT_FN(init_coexist, SECONDARY, BIT(0), 204)`，宏在 `esp_system/include/esp_private/startup_internal.h:71-79`） |
| Wi-Fi init 序：`coex_init()` 先于 `esp_wifi_init_internal` | `esp_wifi/src/wifi_init.c:451-459`、`:471` |
| esp32s31 的配置取值 | `esp_coex/Kconfig:9-36`；`bt/porting_btdm/controller/ble/Kconfig.in:120-122`；`freertos/Kconfig:319-324`；`soc/esp32s31/include/soc/soc_caps.h:506/629/646`；本仓 `firmware/idf-bootstrap/build/config/sdkconfig.h` |
| `libcoexist.a` 导出哪些符号 | `riscv32-esp-elf-nm -A --defined-only esp_coex/lib/esp32s31/libcoexist.a` |
| ROM 里有哪些 coex 符号 | `esp_rom/esp32s31/ld/esp32s31.rom.coexist.ld:21-47` |
| 核心的实际行为（回调在哪个点被调等） | `riscv32-esp-elf-objdump -dr libcoexist.a` 的反汇编，见文末「假核心依据」 |

不在范围内：外部共存（GPIO 交给片外芯片）、`esp_coex_preference_set` / `esp_coex_status_bit_set/clear`
这两个应用侧 API、`CONFIG_ESP_COEX_GPIO_DEBUG`、802.15.4 共存、仲裁器本身。

## 验证状态

只列实际跑过的；板上只跑过对假核心的自检（见下）。

- L3 板侧：2026-11-24 随 `wifi` profile 第一次上板，自检 10/10（对着假核心）。日志 `logs/wifi-selftest-prefix-boot.log`。真核心仍未测。

| 级别 | 内容 | 结果 |
| --- | --- | --- |
| L1 主机 | `zig test src/host_tests.zig` | 2026-11-24，**45 项全过** |
| L1 格式 | `zig fmt --check src/` | 通过 |
| L2 目标编译 | `zig build-obj -target riscv32-freestanding-eabihf -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -OReleaseSmall -fno-emit-bin src/bind.zig` | 通过。另在一次性副本里给 `coex_wifi_request_wrapper`、`wr_btdm_coex_iso_stop` 各注入一处类型错误，同一条命令都报错——说明 43 个钩子加 `esp_coex_version_get` 的函数体在目标构建里确实被分析 |
| L2 链接面 | RV32 上以 `src/glue.zig` 为模块根编译一个消费方对象（`bind.boot` + `wifi.fill` + `wifiInit`），`nm -u` 读它的未定义符号 | 39 个 = 37 个核心符号 + `memcpy`/`memset`；37 个全部由 `libcoexist.a` 导出，其中 3 个 ROM 里也有同名定义 |
| L1 机械差分 | 一次性脚本用正则从 `esp_adapter.c:435-632`、`btdm_coex.c:40-235` 重新推出每个函数的（`#if` 条件、关闭分支返回值、转发目标），与 `wifi.zig`、`ble.zig` 对拍 | Wi-Fi 23 个、BLE 20 个函数，0 处不一致 |
| L1 静态扫描 | `objdump -dr` 扫 7 个 Wi-Fi 归档里对 `g_osi_funcs_p` 偏移 384–484 的取用 | 见下方「Wi-Fi 归档实际引用的 coex 表项」 |
| L1 布局实测 | esp-gcc 15.2 用本仓 `sdkconfig.h` 编译 IDF 头：`sizeof(coex_adapter_funcs_t)`=80、偏移 0,4,…,76；`sizeof(wifi_osi_funcs_t)`=512、共存字段在 384–484（即下标 96–121）；枚举 0/1/2、0..4、位图 1 | 与 `adapter.zig` / `core.zig` 一致 |
| L1 布局实测 | 同一 C 结构在 x86_64（`zig cc -target x86_64-linux-gnu`）：160 字节、`_magic`@152 | 与主机上的 `AdapterTable` 一致 |
| L2 布局实测 | RV32 上导出 `AdapterTable` 变量，`nm -S` 读到 80 字节；导出常量读到 `_magic`@76、`_env_is_chip`@48、`_esp_timer_get_time`@44 | 一致 |
| L3 板侧自检 | 未上板。`selftest.run()` 只在主机上用桩 `board.log` 跑过（一次性副本）：10/10 | 待真机验证 |
| 差分 | 未做：`/tmp/s31-oracle/wifi_oracle.py` 只覆盖 RSNA 密码学构造，没有 coex；本组件也没有密码学构造 | — |

关于命令：`zig test … --summary all` 在本机 Zig 0.17.1 上不被识别（`error: unrecognized parameter: --summary`，
现有组件 `wifi-connect` 同样）；`--summary` 是 `zig build` 的参数，`zig test` 直接打印 `N/45 … OK`。

## 快速开始

```bash
cd components/radio-coex
Z=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig

env -u LD_LIBRARY_PATH $Z test src/host_tests.zig          # 45 项
env -u LD_LIBRARY_PATH $Z fmt --check src/
env -u LD_LIBRARY_PATH $Z build-obj -target riscv32-freestanding-eabihf \
    -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -OReleaseSmall -fno-emit-bin src/bind.zig

# 符号名出处
NM=~/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/bin/riscv32-esp-elf-nm
$NM -A --defined-only ~/esp/esp-idf/components/esp_coex/lib/esp32s31/libcoexist.a
cat ~/esp/esp-idf/components/esp_rom/esp32s31/ld/esp32s31.rom.coexist.ld
```

接线（由 `firmware` 侧完成，本组件不改 `build.zig`）。把 `src/glue.zig` 映射成一个模块（下面叫 `radio_coex`），
其余文件经它转出口：

```zig
const coex = @import("radio_coex");            // 模块根 = src/glue.zig

// 1) 启动期（IDF init_coexist）：核心换成 libcoexist.a，18 个适配钩子由 OS 层提供
try coex.bind.boot(.{ ._semphr_create = …, ._is_in_isr = …, /* 共 18 项，缺一项即 error.AdapterIncomplete */ }, .{});

// 2) Wi-Fi osi 表：24 个共存字段一次装齐（_coex_condition_set 置空，同 IDF）。
//    要在 wifi-blobs 的 stubs.fill(&t) **之后**调：那份具名桩连 IDF 留空的 _coex_condition_set 也会填上。
coex.wifi.fill(&osi_table);
//    esp_wifi_init 的 coex 部分（在 Wi-Fi 库 init 之前）：
_ = try coex.wifiInit(null);

// 3) BLE 侧：osal 的 export / bt-blobs 的 porting 直接转发（20 个函数见 ble.entries）
export fn wr_btdm_coex_schm_status_bit_set(t: u32, s: u32) callconv(.c) void {
    coex.ble.wr_btdm_coex_schm_status_bit_set(t, s);
}
```

读数：`coex.state()`（三态 + 两侧 idle/inited/enabled）、`coex.calls(h)` / `coex.rejected(h)`（每个钩子的
进入次数与被守卫拒绝的次数）、`coex.lastError()`、`coex.bleCallback(type)`、`coex.snapshot()` / `coex.restore()`。

**Wi-Fi 归档实际引用的 coex 表项**（`objdump -dr` 全量扫描，osi 下标 = 偏移/4）：`_coex_init`（96）、`_coex_deinit`（97）、
`_coex_condition_set`（101）**零引用**；`_coex_enable`（98）只在 `libnet80211.a` 的 `wifi_hw_start` 里（`_phy_enable` 之后、
`wifi_reset_mac` 之前），`_coex_disable`（99）只在 `wifi_hw_stop` 里；`_coex_schm_register_cb`、`_coex_register_start_cb`、
`_coex_configure_preemption_end_cb` 在 `libpp.a` 的 `ic_init`（最后一个还在 `ic_deinit`）；其余数据面表项各 1–51 处。
所以 Wi-Fi 侧的 `coex_init` 只来自 C 层的 `esp_wifi_init`（本组件的 `wifiInit`），`coex_deinit_wrapper` 保留只为与 IDF 表一致；
也正因为 Wi-Fi 路径上没人把这一侧复位回 idle，`wifiInit` 接受 inited 态、只拒绝 enabled 态。

接线另注意：`wifi-blobs/src/osi.zig:30,39` 与 `bt-blobs/src/osi.zig:30,39` 的 `indexOf`/`nameOf` 还在用 0.17.1 已删除的
`@typeInfo(…).@"struct".fields`，一调用就是编译错误（实测）；要按下标取字段名得改成 `field_names`。

## 文件职责

| 文件 | 作用 |
| --- | --- |
| `src/core.zig` | `Core`：37 个核心入口的函数指针表（可注入）、`esp_err_t` 常量子集、回调/状态类型枚举 |
| `src/adapter.zig` | `coex_adapter_funcs_t` 的镜像、`Hooks`（18 个可选钩子）、`build()`（缺一不可）、ilp32/LP64 布局断言 |
| `src/glue.zig` | 配置开关、46 个入口的计数、生命周期状态机、单例、`boot()` / `wifiInit()` / `esp_coex_version_get()`；兼模块根（转出口） |
| `src/wifi.zig` | Wi-Fi osi 表 23 个 `coex_*_wrapper`（IDF 同名）、`entries`（含留空的 `_coex_condition_set`）、`fill()` |
| `src/ble.zig` | BLE 侧 16 个 `wr_btdm_coex_*` + `btdm_coex_init/deinit/enable/disable`（IDF 同名） |
| `src/fake.zig` | 记录型假核心：每次调用的参数/返回值日志 + 按反汇编建模的生命周期行为；只给测试与自检用 |
| `src/bind.zig` | 目标专用：`realCore()`（37 个 `@extern`）、`boot(hooks, cfg)`；主机不编译其目标部分 |
| `src/host_tests.zig` | 全部 45 项主机测试 |
| `src/selftest.zig` | 板侧自检（10 条判据，胶水 + 假核心；跑前存、跑完还原胶水单例） |

逻辑模块只 import `std` 与同组件的兄弟文件；没有 allocator、没有 `board`（`selftest.zig` 只为打日志 import 它）。

## 特性对照表

| 特性 | 规范条款（IDF） | 测试名 | 向量来源 | 状态 |
| --- | --- | --- | --- | --- |
| 适配表字段顺序、常量 | `esp_coexist_adapter.h:16-17,21-52` | `adapter table: field order is the esp32s31 coex_adapter_funcs_t`；`adapter table: version 2 and magic 0xDEADBEAF` | esp-gcc 对本仓 sdkconfig 的 `offsetof` / 枚举值实测 | 主机通过 |
| 适配表布局（ilp32 / LP64） | 同上 | `adapter table: layout matches the C struct measured on this pointer width` | esp-gcc（RV32）、`zig cc`（x86_64）实测 | 主机通过；RV32 由 comptime 断言在每次目标构建核对 |
| 适配表构建缺钩子即拒绝 | `esp_coex_adapter.c:160-181`（18 项全给） | `adapter build rejects a missing hook and says which`；`… an all-null hook set`；`… fills all 18 slots` | — | 主机通过 |
| `esp_err_t` 与类型枚举 | `esp_err.h:22-31`；`esp_coexist_internal.h:25-41`；`esp_coexist_adapter.h:56-60` | `core: constants match the IDF headers` | esp-gcc 实测 | 主机通过 |
| 37 个真实符号名 | `nm libcoexist.a`；`esp32s31.rom.coexist.ld:21-40` | `bind: every symbol name is exported as text by libcoexist.a`；`… dual-provider names …` | `nm` 的 107 个文本符号、ROM 脚本的 19 个 | 主机通过 |
| Wi-Fi 钩子原样转发 | `esp_adapter.c:435-632` | `wifi hooks forward the same arguments and return what the core returns` | 假核心的可编排返回值（互不相同的数） | 主机通过 |
| Wi-Fi 留空项 `_coex_condition_set` | `wifi_os_adapter.h:137`（有声明）；`esp_adapter.c:796-822`（无赋值） | `wifi table: _coex_condition_set is the only entry IDF leaves NULL` | — | 主机通过 |
| Wi-Fi 表项顺序 | `wifi_os_adapter.h:132-161` | `wifi table: entries follow wifi_osi_funcs_t (osi indices 96 to 121)`；`wifi fill puts each wrapper …` | esp-gcc 实测的 `offsetof`/4 | 主机通过 |
| 关闭分支返回值 | `esp_adapter.c:437-632` 各 `#else` | `with coex disabled every wifi hook returns its IDF stub value` | IDF 源码 | 主机通过 |
| 未启动时的降级 | （IDF 无此层，见「实现偏离」） | `before boot every wifi hook degrades to the stub value and counts a rejection` | — | 主机通过 |
| `CONFIG_ESP_COEX_POWER_MANAGEMENT` | `esp_adapter.c:598-614` | `flexible period hooks follow CONFIG_ESP_COEX_POWER_MANAGEMENT` | IDF 源码（关闭时 get 回 1） | 主机通过 |
| 只看 `CONFIG_SW_COEXIST_ENABLE` 的四个钩子 | `esp_adapter.c:571-596,625-632` | `start, restart and register hooks need SW coexist; external alone is not enough` | IDF 源码 | 主机通过 |
| BLE 钩子原样转发 | `btdm_coex.c:40-235` | `ble hooks forward the same arguments and return what the core returns` | 假核心 | 主机通过 |
| BLE 关闭分支返回值（三个登记函数各不相同） | `btdm_coex.c:57-65,97-105,188-196` 等 | `with SW coexist disabled the ble hooks return IDF's per-hook stub values` | IDF 源码 | 主机通过 |
| `version_get` 不写出参 | `btdm_coex.c:117-132` | `ble version_get returns 0 and leaves the outputs alone when SW coexist is on` | IDF 源码（`#if 0`） | 主机通过 |
| `CONFIG_BT_LE_ISO_SUPPORT` | `btdm_coex.c:134-178` | `ble ISO hooks follow CONFIG_BT_LE_ISO_SUPPORT` | IDF 源码 | 主机通过 |
| `register_ble_cb` 的 type 截成 8 位 | `btdm_coex.c:23,188-196` | `ble register_ble_cb truncates the type to 8 bits like IDF's uint8_t parameter` | IDF 源码 | 主机通过 |
| BLE 回调按 type 保存、在定义点被调 | `libcoexist.a` 反汇编 `coex_core_register_ble_cb/enable/disable` | `both BLE callback types are stored and each is invoked at its defined point`；`with Wi-Fi enabled first, BLE's enable is the second one …` | 反汇编；controller 实际登记 type 0/1 见 `libble_app.a:107.o` 与 `components/bt-blobs/logs/btfix1.log:240-241` | 主机通过（模型）；真核心待板测 |
| `btdm_coex_deinit` 是空函数 | `btdm_coex.c:213-217`；`bt.c:277-280` | `btdm_coex_deinit is empty: no core call, and BLE returns to idle` | IDF 源码 | 主机通过 |
| 启动序：注册 → pre_init | `coexist.c:306-311` | `boot registers the adapter table then pre-inits, as IDF init_coexist does`；`boot's pre_init picks the hw timer profile from env_is_chip` | 反汇编 `coex_core_pre_init` | 主机通过 |
| boot 幂等与失败 | `startup_internal.h:62-63` | `boot twice is rejected …`；`boot failure leaves the glue unbooted and hooks degrade`；`boot with a missing adapter hook …`；`without an installed core boot is rejected` | — | 主机通过 |
| Wi-Fi init 的共存部分 | `wifi_init.c:451-459` | `wifiInit registers the lpclk callback only with tickless idle, then coex_init` | IDF 源码 | 主机通过 |
| 生命周期守卫 | `wifi_init.c:208-211,374-377`；`bt.c:192-194,277-280,298-300` | `lifecycle: driver-level re-init is rejected …`；`lifecycle after boot: enable before init, double enable, …`；`before boot the ble hooks degrade …` | IDF 上层的状态检查 | 主机通过 |
| 核心失败透传 | — | `a failing core init or enable is passed through and does not advance the side` | — | 主机通过 |
| IDF 全序 | `coexist.c:306-311`、`wifi_init.c:457-471`、`bt.c:112/141/222/304` | `the IDF order boot, Wi-Fi init, BLE init, BLE enable, Wi-Fi enable, shutdown is accepted in full` | IDF 源码 | 主机通过 |
| `esp_coex_version_get` | `coexist.c:43-46` | `esp_coex_version_get returns the core's version string` | — | 主机通过 |
| 假核心模型自检 | 反汇编 | `fake model: …`（4 项） | 反汇编 | 主机通过 |
| 模块根转出口 | （接线约定，非 IDF） | `module root: glue.zig re-exports the other six files` | — | 主机通过 |

## 钩子表

"关闭分支"是该钩子在 `#if` 条件不成立时 IDF 回的值。"本组件函数"与 IDF 同名。

### Wi-Fi 侧（`wifi.zig`；源文件 `esp_wifi/esp32s31/esp_adapter.c`）

| osi 表项 | 条件 | IDF 行 | 关闭分支 | 本组件函数 | 测试名 |
| --- | --- | --- | --- | --- | --- |
| `_coex_init` | SW ∥ EXT | 435-442 | 0 | `coex_init_wrapper` | `wifi hooks forward …`、`lifecycle: driver-level re-init …` |
| `_coex_deinit` | SW ∥ EXT | 444-449 | 空操作 | `coex_deinit_wrapper` | `wifi hooks forward …`、`lifecycle after boot …` |
| `_coex_enable` | SW ∥ EXT | 451-458 | 0 | `coex_enable_wrapper` | `wifi hooks forward …`、`both BLE callback types …` |
| `_coex_disable` | SW ∥ EXT | 460-465 | 空操作 | `coex_disable_wrapper` | `wifi hooks forward …`、`with Wi-Fi enabled first …` |
| `_coex_status_get` | SW ∥ EXT | 467-474 | 0 | `coex_status_get_wrapper`（补位图 1） | `wifi hooks forward …` |
| `_coex_condition_set` | — | `wifi_os_adapter.h:137` | **留空** | 无（`entries` 里为 null） | `wifi table: _coex_condition_set is the only entry IDF leaves NULL` |
| `_coex_wifi_request` | SW ∥ EXT | 476-483 | 0 | `coex_wifi_request_wrapper` | `wifi hooks forward …` |
| `_coex_wifi_release` | SW ∥ EXT | 485-492 | 0 | `coex_wifi_release_wrapper` | `wifi hooks forward …` |
| `_coex_wifi_channel_set` | SW ∥ EXT | 494-501 | 0 | `coex_wifi_channel_set_wrapper` | `wifi hooks forward …`、`ble hooks forward …` |
| `_coex_event_duration_get` | SW ∥ EXT | 503-510 | 0（不写出参） | `coex_event_duration_get_wrapper` | `wifi hooks forward …` |
| `_coex_pti_get` | SW ∥ EXT | 512-519 | 0（不写出参） | `coex_pti_get_wrapper` | `wifi hooks forward …` |
| `_coex_schm_status_bit_clear` | SW ∥ EXT | 521-526 | 空操作 | `coex_schm_status_bit_clear_wrapper` | `wifi hooks forward …` |
| `_coex_schm_status_bit_set` | SW ∥ EXT | 528-533 | 空操作 | `coex_schm_status_bit_set_wrapper` | `wifi hooks forward …` |
| `_coex_schm_interval_set` | SW ∥ EXT | 535-542 | 0 | `coex_schm_interval_set_wrapper` | `wifi hooks forward …` |
| `_coex_schm_interval_get` | SW ∥ EXT | 544-551 | 0 | `coex_schm_interval_get_wrapper` | `wifi hooks forward …` |
| `_coex_schm_curr_period_get` | SW ∥ EXT | 553-560 | 0 | `coex_schm_curr_period_get_wrapper` | `wifi hooks forward …` |
| `_coex_schm_curr_phase_get` | SW ∥ EXT | 562-569 | NULL | `coex_schm_curr_phase_get_wrapper` | `wifi hooks forward …` |
| `_coex_schm_process_restart` | SW | 580-587 | 0 | `coex_schm_process_restart_wrapper` | `wifi hooks forward …`、`start, restart and register hooks …` |
| `_coex_schm_register_cb` | SW | 589-596 | 0 | `coex_schm_register_cb_wrapper` | 同上 |
| `_coex_register_start_cb` | SW | 571-578 | 0 | `coex_register_start_cb_wrapper` | `wifi hooks forward …`、`start, restart and register hooks …` |
| `_coex_schm_flexible_period_set` | PM | 598-605 | 0 | `coex_schm_flexible_period_set_wrapper` | `flexible period hooks follow …` |
| `_coex_schm_flexible_period_get` | PM | 607-614 | **1** | `coex_schm_flexible_period_get_wrapper` | `flexible period hooks follow …`、`with coex disabled …` |
| `_coex_schm_get_phase_by_idx` | SW ∥ EXT | 616-623 | NULL | `coex_schm_get_phase_by_idx_wrapper` | `wifi hooks forward …` |
| `_coex_configure_preemption_end_cb` | SW（SoC 的 `SOC_BLE_ISO_SUPPORTED`=1） | 625-632 | 0 | `coex_configure_preemption_end_cb_wrapper` | `wifi hooks forward …`、`start, restart and register hooks …` |

SW = `CONFIG_SW_COEXIST_ENABLE`，EXT = `CONFIG_EXTERNAL_COEX_ENABLE`（Kconfig 名 `ESP_COEX_EXTERNAL_COEXIST_ENABLE`），PM = `CONFIG_ESP_COEX_POWER_MANAGEMENT`，
对应 `glue.Config` 的 `sw_coexist` / `external_coexist` / `power_management`。

### BLE 侧（`ble.zig`；源文件 `bt/porting_btdm/controller/btdm_common/src/btdm_coex.c`）

| 钩子 | 条件 | IDF 行 | 关闭分支 | 本组件函数 | 测试名 |
| --- | --- | --- | --- | --- | --- |
| `wr_btdm_coex_schm_status_bit_set` | SW | 40-46 | 空操作 | 同名 | `ble hooks forward …` |
| `wr_btdm_coex_schm_status_bit_clear` | SW | 48-55 | 空操作 | 同名 | `ble hooks forward …` |
| `wr_btdm_coex_schm_register_btdm_callback` | SW | 57-65 | 0 | 同名（登记在 type BT=1 下） | `ble hooks forward …`、`with SW coexist disabled …` |
| `wr_btdm_coex_schm_interval_get` | SW | 67-75 | 0 | 同名 | `ble hooks forward …`、`with SW coexist disabled …` |
| `wr_btdm_coex_schm_curr_period_get` | SW | 77-85 | **1** | 同名 | 同上 |
| `wr_btdm_coex_schm_curr_phase_get` | SW | 87-95 | NULL | 同名 | 同上 |
| `wr_btdm_coex_register_wifi_channel_change_callback` | SW | 97-105 | **-1** | 同名 | `ble hooks forward …`、`with SW coexist disabled …` |
| `wr_btdm_coex_wifi_channel_get` | SW | 107-115 | **-1** | 同名 | 同上 |
| `wr_btdm_coex_version_get` | SW | 117-132 | **-1**（开时 0、不写出参） | 同名 | `ble version_get returns 0 …`、`with SW coexist disabled …` |
| `wr_btdm_coex_iso_start` | SW ∧ ISO | 134-142 | ESP_OK | 同名 | `ble ISO hooks follow …`、`ble hooks forward …` |
| `wr_btdm_coex_iso_stop` | SW ∧ ISO | 144-152 | ESP_OK | 同名 | 同上 |
| `wr_btdm_coex_iso_protect_frame_thres_get` | SW ∧ ISO | 154-162 | 0 | 同名 | 同上 |
| `wr_btdm_coex_iso_start_int_handle` | SW ∧ ISO | 164-170 | 空操作 | 同名 | `ble ISO hooks follow …` |
| `wr_btdm_coex_iso_end_int_handle` | SW ∧ ISO | 172-178 | 空操作 | 同名 | `ble hooks forward …`、`ble ISO hooks follow …` |
| `wr_btdm_coex_ble_idle_time_inform` | SW | 180-186 | 空操作 | 同名 | `ble hooks forward …` |
| `wr_btdm_coex_register_ble_cb` | SW | 188-196 | ESP_OK | 同名（type 截 8 位，影子表按 type 记） | `ble register_ble_cb truncates …`、`both BLE callback types …` |
| `btdm_coex_init`（`bt.c:222`） | SW | 203-211 | ESP_OK | 同名 | `lifecycle: driver-level re-init …` |
| `btdm_coex_deinit`（`bt.c:112`） | 无（空函数） | 213-217 | 空操作 | 同名 | `btdm_coex_deinit is empty …` |
| `btdm_coex_enable`（`bt.c:304`） | SW | 219-227 | ESP_OK | 同名 | `both BLE callback types …`、`lifecycle after boot …` |
| `btdm_coex_disable`（`bt.c:141`） | SW | 229-235 | 空操作 | 同名 | `with Wi-Fi enabled first …` |

ISO = `CONFIG_BT_LE_ISO_SUPPORT`（`glue.Config.ble_iso`）。

### 胶水自己的入口（`glue.zig`）

| 入口 | IDF 对应 | 测试名 |
| --- | --- | --- |
| `glue.boot(hooks)` | `coexist.c:306-311` | `boot registers the adapter table then pre-inits …` 等 5 项 |
| `glue.wifiInit(lpclk_cb)` | `wifi_init.c:451-459` | `wifiInit registers the lpclk callback only with tickless idle, then coex_init` |
| `esp_coex_version_get` | `coexist.c:43-46` | `esp_coex_version_get returns the core's version string` |

## 实现偏离

与 IDF 不同、或 IDF 没有的行为，都在这里：

1. **顺序守卫是加上的**。IDF 没有共存层的顺序检查，它靠调用方（`esp_wifi_init` 的 `s_wifi_inited`、
   bt.c 的 `s_btdm_controller_status`）保证顺序。这里把同样的规则集中到 `glue.State`：
   `boot` 只能一次；`init` 要在 `boot` 之后；`enable` 要在该侧 `init` 之后且不重复；
   `disable` 要在该侧 `enable` 之后；`deinit` 不能在该侧 `enable` 期间。被拒的调用**不进核心**，
   回 `ESP_ERR_INVALID_STATE`（IDF 上层在同样情况下回的就是它）或空操作，并计一次 `rejected`。
2. **未启动时的降级**。IDF 里 `init_coexist` 在启动期，钩子不可能早于它。这里若有人在 `boot()` 前
   调钩子，按"视同共存关闭"的桩值作答并记拒绝——真核心此时适配表未注册，会解引用空指针。
3. **`boot()` 把核心的失败报出来**。IDF 的 `init_coexist` 不看 `esp_coex_adapter_register` /
   `coex_pre_init` 的返回值（`startup_internal.h:62-63` 要求它恒回 ESP_OK）；这里回
   `error.AdapterRegisterFailed` / `error.PreInitFailed` 并停在未启动态。配置里两种共存都没开时
   `boot()` 回 `error.CoexDisabled`（那套配置下 IDF 根本没有这个函数，`coexist.c:300`）。
4. **编译期宏换成运行期开关**。`glue.Config` 的默认值 = esp32s31 的 IDF 默认配置
   （SW 开、EXT 关、PM 关、ISO 关、tickless 关）。
5. **"配置没开"与"未启动"的返回值相同，但只有后者计拒绝**。
6. **核心按 type 保存并调用 BLE 回调，胶水不重复调**。`wr_btdm_coex_register_ble_cb` 只把 (type, func)
   原样送到核心；回调的调用点在 `libcoexist.a` 里（见「假核心依据」）。胶水另存一份按 type 的影子记录
   （`glue.bleCallback`），只在核心回 ESP_OK 时写。现有的 `osal.zig:2005-2007` 是单槽，第二个 type 覆盖第一个。
7. **参数名**：IDF 的 `type` 是 Zig 的保留字，改叫 `st_type` / `cb_type`；函数名保持不变。
8. **`entries` 里的 `@ptrCast`**：把函数指针装进 `?*const anyopaque` 是 osi 表的字段类型所迫
   （`wifi-blobs/src/osi.zig` 也是这么存钩子的），不是类型双关；逻辑路径上没有任何 cast。
9. **假核心与真核心的三处刻意不同**（`fake.zig` 文件头）：适配表没注册时 `pre_init` 回 ESP_FAIL 而不是
   解引用空指针；`register_ble_cb` 收到 0/1 以外的 type 回 259 而不是死循环；ROM 的 `coex_schm_lock`
   没有反汇编，模型假设方案环境未初始化时它失败。
10. **没有提供的 IDF 胶水**：`coexist_printf`（`esp_coex/src/lib_printf.c:44-54`，C 变参函数，Zig 定义不了；
    `libcoexist.a` 的两行版本日志靠它打出来）、`esp_coex_preference_set`、`esp_coex_status_bit_set/clear`、
    外部共存的 GPIO 配置、`coex_wifi_register_update_lpclk_callback` 之外的电源管理项。

11. 自检里 `lastError()` 的比较先解包再比（`lastErrorIs`）：Zig 0.17.1 的 Debug 构建下 `?E == ?E` 恒为假，
   在主机上跑自检会假失败；板上是 ReleaseSmall，原本就是对的。最小复现见 `docs/verification/coex-verification.md`。

## 待验证项

都要上板，且要真核心（`bind.zig`）而不是假核心：

1. **适配表被核心接受**：`bind.boot()` 回 `ESP_OK`；`g_coa_funcs_p`（ROM 槽位 `0x2f07ff98`）等于
   `glue.adapterTable()` 的地址；`g_coex_param_ptr`（`0x2f07ff94`）非零——仓内现在是 0
   （`logs/ch25-clock-readback-boot.log:386`）。
2. **两行版本日志**：官方固件启动时有 `coexist: coex firmware version: …` 与 `coexist: coexist rom version …`
   （`components/bt-blobs/logs/bt-ana-i2c-official-trace.log:59-60`）；两个格式串都在 `libcoexist.a` 里，
   经 `coexist_printf` 打印，所以这一条同时验证那一个 C 变参胶水。`coex_version_get()` 具体回哪个串未核对。
3. **18 个适配钩子的真实现**：信号量/定时器/`_is_in_isr`/`_malloc_internal`/`_xtal_freq_get` 得从 `osal` 与
   Wi-Fi osi 外壳转接；IDF 的实现在 `esp_coex/esp32s31/esp_coex_adapter.c:31-158`。本组件只校验"给齐了"。
4. **BLE 两个回调在真核心上被调**：登记 type 0/1 都回 ESP_OK；按反汇编，type 0 在第二个射频 `coex_enable`
   时被调、type 1 在使能计数降回 1 时被调。ADR-003 的 L3 判据"`coex_wifi_request` 之后 BLE 回调被触发"
   指的是方案回调（`coex_schm_register_callback(BT, …)` 登记的那个），由调度器在相位切换时调——
   那条路径的反汇编没读，本组件只验证了登记。
5. **三个两处同名的符号由链接器取谁**（`coex_event_duration_get`、`coex_wifi_release`、`coex_schm_interval_set`）：
   IDF 的参照构建里 `coex_event_duration_get` 落在 ROM 的 `0x2f800c18`；本仓 `s31.ld:1304` 还多了一条
   `PROVIDE(coex_status_get = 0x2f800c34)`（IDF 的 ROM 脚本里这行是注释掉的），要确认 `libcoexist.a` 的
   `coex_status_get`（`.coexiram.12`）没被段级 gc 掉。
6. **与现有胶水的符号冲突**：`components/bt-blobs/src/wifi_glue.zig:33-42` 导出了 `coex_core_ble_conn_dyn_prio_get`、
   `esp_coex_rom_version_get` 的桩，`coexist_printf` 也在那里；接进真核心时这三者与 ROM 脚本 / `libcoexist.a`
   的同名符号要各留一份。
7. **现有接线的缺口**（接线时要补）：`osal.zig:2025-2082` 只导出了 16 个 `wr_btdm_coex_*` 里的 11 个，
   缺 `schm_interval_get`、`schm_curr_period_get`、`schm_curr_phase_get`、`version_get`、`iso_start_int_handle`；
   `wifi-blobs/src/osi_impl.zig:1132-1170` 的 8 个 coex 外壳参数名与顺序同 IDF 不一致
   （例如 `shellCoexWifiRequest(kind, event, latency)` 对应 IDF 的 `(event, latency, duration)`）；其余 16 个
   共存字段与 IDF 留空的 `_coex_condition_set` 由 `osi_stubs.zig:316-341` 的具名桩 `stub24`–`stub29`、`stub31`–`stub49` 填上（桩体没读）。
8. **L4 真链路**：共存下的吞吐、PTI 行为——两个射频各自打通之后。

## 假核心依据

`fake.zig` 的行为模型来自 `riscv32-esp-elf-objdump -dr libcoexist.a`（`components/esp_coex/lib/esp32s31/`）：

| 函数（归档成员） | 读到的事实 |
| --- | --- |
| `esp_coex_adapter_register`（coexist_api.o） | 已注册 → 0 且不再校验；表空 / `_version != 2` / `_magic != 0xDEADBEAF` → 258；`_magic` 取自偏移 76 |
| `coex_core_pre_init`（coexist_core.o） | `coex_env.sem` 为空时 `_semphr_create(1, 1)`（偏移 8），失败 → 257；`coex_schm_init` 失败 → 257；上锁后 `_env_is_chip()`（偏移 48）为真设 `coex_hw_timer_freq_set(4, 50)`，否则 `(8, 1)` |
| `coex_core_lock`（coexist_core.o） | 信号量不存在 → 259；`_is_in_isr`（偏移 32）决定走 `_semphr_take_from_isr`（hptw 非零再 `_task_yield_from_isr`）还是 `_semphr_take(sem, 0xffffffff)`；返回值非 1 ⇒ -1 |
| `coex_core_init` / `coex_core_deinit` | `li a0,0; ret` |
| `coex_core_enable` | 计数 +1；`bltu 1,new` 成立（新计数 > 1）才 `status=1`、解锁、`start_cb()`（`coex_env+12`）、`ble_cb[0]()`（+16）；新计数为 1 时只解锁返回 |
| `coex_core_disable` | 计数 -1；等于 1 才 `status=0`、解锁、`ble_cb[1]()`（+20） |
| `coex_core_register_start_cb` | 锁失败 259；存 `coex_env+12`；回 0 |
| `coex_core_register_ble_cb` | 锁失败 259；type 0 → `coex_env+16`、1 → `+20`；其它 type 打印后死循环 |
| `coex_status_get`（coexist_api.o） | `(~bitmap & coex_schm_status_bitmap_get()) != 0` 才回 `coex_core_status_get`（= `coex_env+4`），否则 0 |
| `coex_schm_status_bitmap_get` / `coex_schm_status_bit_set`（coexist_scheme.o） | 五个 16 位状态字在 `coex_schm_env+6/8/10/56/60`，第 i 位 = 第 i 个字非零；置位是按位或，type > 4 不理 |
| `coex_wifi_channel_set` / `coex_wifi_channel_get` | 主/辅信道在 `coex_schm_env+24/25`；set 之后有登记的信道变化回调就调 `cb(primary, secondary)`；get 任一出参空 → 258 |
| `coex_schm_register_callback` | type 0 → `+52`、1 → `+20`，其它 → -1 |
| `coex_schm_interval_set/get`、`coex_schm_flexible_period_set/get`、`coex_schm_curr_period_get`、`coex_schm_curr_phase_get`、`coex_schm_get_phase_by_idx` | 锁失败分别回 -1 / 0 / -1 / 环境值 / 1 / NULL / NULL；相位数在方案表首字节，每相位 4 字节 |
| `coex_version_get_value` | 出参空 → 258；否则写 {2, 0, 0}，回 0 |
| `coex_core_pti_get` / `coex_core_event_duration_get` | 出参空 → 258 / -1，不写 |

BLE controller 实际登记的两个 type（`libble_app.a:107.o` 的 `r_sym_ble_5rFaVDMhVRYRmiaooc1c`：
`register_ble_cb(0, …)`、`register_ble_cb(1, …)`）与板侧日志 `btfix1.log:240-241` 一致。
