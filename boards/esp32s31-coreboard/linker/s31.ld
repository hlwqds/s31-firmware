/*
 * ch28-bootstrap-power-performance —— 形态 B 的链接脚本
 *
 * 骨架与 ch13–ch27 相同（SRAM-only 布局 + 两个 flash 装载段），本章不改
 * 任何结构：otadata 选槽、功耗预算、性能统计与 A/B 回滚状态机都是纯逻辑，
 * 板侧只需要 SRAM 放选槽缓冲区与统计样本，再跑完 src/selftest.zig 的
 * 12 条判据。
 *
 * 段布局（三段，两段在 flash）：
 *
 *     irom 0x40000020  .flash.text     esp_app_desc_t(256B) + .text.trap + .text（上限 0xB0000）
 *     drom 0x40100020  .flash.rodata   .rodata/.srodata（上限 0xB0000）
 *     sram 0x2F000000  .trap_ram       trap 入口（放 flash 会 CPU_LOCKUP_RESET）
 *                      .data           有初值可写数据（LMA == VMA）
 *                      .bss            NOBITS，_start 清零
 *                      [堆]            _heap_start == _bss_end, _heap_end == _stack_bottom
 *                      [栈 16 KiB]     _stack_bottom .. _stack_top，向下增长
 *
 * 三条不变的硬约束（真机实测，见 docs/history/BRINGUP-chapter-era.md）：
 *   1) 镜像里落在 flash 映射窗口的装载段仍只有两个（IROM + DROM），vaddr 按 64 KiB
 *      页对齐：irom 0x40000020 / drom 0x40100020（页偏移 0x00020 同余）。
 *      窗口演进：P0.2 各扩到 0x7F000；P0.3 把 drom 基址移到 0x40100020、两窗各 0xB0000
 *      （合计 1 441 792 B，仍在 factory 1 500 K 内）。芯片侧上限远大于此
 *      （SOC_IROM_HIGH = 0x44000000，MMU 1024 × 64 KiB），但 drom 段必须结束在
 *      0x43FF0000 以下——loader 把 DROM 区间最后一页当分区发现的临时页；
 *   2) trap 向量必须落在 SRAM（.trap_ram）；
 *   3) 第一个装载段最前面是 256 字节 esp_app_desc_t。
 *
 * 与 ch23 的差异：本章不用 AES（没有 align(64) 的软件查表），.flash.rodata
 * 的起点为 ORIGIN(drom) = 0x40100020（按 64 KiB 页对齐）。实际值仍由 LLVM 的输入节对齐决定，
 * 交付时以 `image-info` 打印的两行 DROM/IROM 为准（见本章 README 与
 * 章节 24.10 的镜像事实）。
 *
 * 地址来源（ESP-IDF v6.1）：
 *   components/esp_system/ld/esp32s31/memory.ld.in:19  SRAM_START = 0x2F000000
 *   components/esp_system/ld/esp32s31/memory.ld.in:23  SRAM_SIZE = SRAM_SEG_END - SRAM_START
 *   components/esp_system/ld/esp32s31/ld.hp_mem_defs    SRAM_SEG_END = 0x2F07AFC0
 * SRAM 物理上是 512 KiB（0x80000），末尾 0x5040 被二级 bootloader 的
 * iram_loader_seg 占着，应用可用到 0x2F07AFC0，长度 0x7AFC0。
 */

ENTRY(_start)

MEMORY
{
    /* P0.3：两段各 0xB0000（合计 1 441 792 B，仍在 factory 1 500 K 之内）。
     * drom 基址移到 0x40100020（保持 64 KiB 对齐 + 0x20），irom 因此可用满 0x100000 空间；
     * drom 段必须结束在 0x43FF0000 以下——loader 把 DROM 区间最后一页当分区发现的临时页。 */
    irom (rx)  : ORIGIN = 0x40000020, LENGTH = 0xB0000
    drom (r)   : ORIGIN = 0x40100020, LENGTH = 0xB0000
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

/* ROM 符号（Wi-Fi blob 需要的 ROM 函数/数据地址）。只抄了本仓引用到的那些，
 * 见 rom_syms.ld 的说明。常规镜像不引用它们，包含进来无副作用。
 *
 * 路径相对**构建根**（`zig build` 必须在 firmware/ 下跑，这是 Zig 的约定），
 * 因为 lld 的 INCLUDE 是相对 cwd 解析的，不是相对本脚本。 */

SECTIONS
{
    .flash.text : ALIGN(16)
    {
        /* bootloader 从镜像头 entry 跳到 _start；第一个装载段的第一批字节
         * 必须是 esp_app_desc_t（魔数 0xABCD5432，256 字节）。
         * 本章的 OTA 自检把这个魔数与 256 字节结构体尺寸当成清单的一部分
         * 判据（见 src/ota.zig 的 imageDesc），但**不写 flash**。 */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;

        /* mtvec.BASE 的低 2 位是模式位，必须 4 字节对齐。 */
        . = ALIGN(4);
        KEEP(*(.text.trap))
        . = ALIGN(4);

        *(.text .text.*)
        . = ALIGN(16);
        _text_end = .;
    } > irom

    /* 第二个 flash 装载段 = DROM：少了它 bootloader 的 rom_index == 2 断言会挂。
     *
     * 段起点由 lld 按输入节对齐决定，实测落在 ORIGIN(drom) = 0x40100020；
     * bootloader 只要求页内偏移同余（esp_image_format.c:904），elf2image
     * 会插填充段对齐 paddr。drom 与 irom 的页偏移同为 0x20。 */
    .flash.rodata : ALIGN(16)
    {
        _rodata_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        /* IDF blob（net80211/pp）的只读数据：每条 Wi-Fi 日志串都是一个独立段
         * `.rodata_wlog…`（实测 603 个），不收进来 lld 会各自成段，镜像段数直接爆掉。
         * `.eh_frame*` 我们没有展开器，但仍收进 rodata（丢弃会改变镜像语义）。 */
        *(.rodata_wlog*)
        *(.eh_frame .eh_frame.* .eh_frame_hdr)
        . = ALIGN(16);
        _rodata_end = .;
    } > drom

    /* trap 入口必须在 SRAM：放 flash 时异常投递直接 CPU_LOCKUP_RESET(0x1a)。
     *
     * ⚠ **低 2 KB 必须让给归档**：BLE controller 建任务时把栈基址**硬编码**成
     * `0x2F000000`、大小 2000 字节（`r_btdm_task_init` 的 `lui a5,0x2f000`），
     * 而 `ORIGIN(sram)` 正是 `0x2F000000` ⇒ 任务一启动就会覆盖向量表/`.bss` 头部，
     * 症状是"中断不再递送"。这里把 SRAM 侧的起点抬到 `+0x800`，
     * 让任务栈独占 `0x2F000000..0x2F0007D0`。 */
    .trap_ram ORIGIN(sram) + 0x800 : ALIGN(4)
    {
        _trap_start = .;
        KEEP(*(.trap_ram))
        . = ALIGN(4);
        _trap_end = .;
    } > sram

    /* IDF blob 的 IRAM 变体：这些段带 SHF_ALLOC 且必须落在 SRAM（可执行），
     * 不收集的话 lld 会把它们当 flash 段，段数爆掉、语义也错。
     * 实测体积：.wifislprx* 13 182 B + 其余 iram 变体 49 182 B。 */
    .iram_blobs : ALIGN(16)
    {
        *(.iram1 .iram1.*)
        *(.wifislpiram*)
        *(.wifirxiram*)
        *(.wifiextrairam*)
        *(.wifiorslpiram*)
        *(.wifislprxiram*)
        *(.wifi0iram*)
        /* BLE controller 的 RAM 常驻睡眠代码（`libble_app` 的 .iram_sleep* 族）。
         * 不收集的话它们各自成段，`elf2image` 会报 Invalid segment count。 */
        *(.iram_sleep*)
        *(.iram_single_sleep*)
        /* **`.iram_btslp*` 族（此前遗漏）**：`libble_app` 的 BLE 睡眠代码，
         * IDF 用 `linker_esp_ble_controller.lf` 把 `.iram_sleep+ .iram_btslp+`
         * 收进**同一个** `sleep_text`。我们漏掉后它们成了**孤儿段**，
         * 由 lld 自行按 1,2,14,16,0 顺序放置，段间只有 2 字节间隔
         * （`esp_image` 按 4 字节取整 ⇒ 段会重叠）。
         * 段首在运行时被改为非法指令、且值每次 boot 不同 —— 见 README「根因 5」。 */
        . = ALIGN(4);
        *(.iram_btslp*)
        . = ALIGN(16);
    } > sram

    /* 有初值的可写数据。本布局 LMA == VMA：_start 不需要搬运。 */
    .data : ALIGN(16)
    {
        _data_start = .;
        *(.data .data.*)
        *(.dram1 .dram1.*)
        /* RISC-V small-data anchor：gp = 当前 + 0x800。 */
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(16);
        _data_end = .;
    } > sram

    /* 零初始化数据：NOBITS，内容由 _start 清零。
     * 本章的静态工作区都在这里（只有两个 16 B 的 otadata 扇区缓冲与
     * 自检计数；逐项见章节 28.9）：
     *   g_a          16 B  otadata 扇区 A 的副本
     *   g_b          16 B  otadata 扇区 B 的副本
     *   g_passed      4 B  自检通过数
     *   g_failed      4 B  自检失败数
     * 放 .bss 而不是栈上：主栈只有 16 KiB，栈上副本会被后续调用覆盖。 */
    .bss (NOLOAD) : ALIGN(16)
    {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        _bss_end = .;
    } > sram

    _data_load_start = LOADADDR(.data);
    _data_load_end = LOADADDR(.data) + SIZEOF(.data);

    /* ---------------------------------------------------------------------
     * 堆与栈的边界
     *
     * 主栈 16 KiB 放在 SRAM 最末尾（_start 里 `la sp, _stack_top`）。
     * 堆从 _bss_end 长到 _stack_bottom。自检会打印这四个边界，
     * 并检查 `_heap_start <= _heap_end`、`_bss_end <= _stack_bottom`。
     * ------------------------------------------------------------------- */
    _stack_size = 0x4000;   /* 16 KiB：8 KiB 会栈溢出（实测 panic），不可减 */
    _stack_top = ORIGIN(sram) + LENGTH(sram);
    _stack_bottom = _stack_top - _stack_size;

    /* **堆必须从归档的 .btdm_bss/.btdm_data 之后开始**：
     * 这两个段是 NOLOAD 但**占用真实地址**（32 KiB + 4 KiB），落在 `_bss_end` 之后。
     * 若 `_heap_start == _bss_end`，allocator 会覆盖归档自己的全局对象
     * （锚点槽/事件队列/链表头都在 .btdm_bss 内）—— 本会话已因此出现过多例"不可解释"现象。 */
    _heap_start = _data_end_btdm;   /* 校准段在三段之内，不改变 _heap_start */
    _heap_end = _stack_bottom;

    /* ---------------------------------------------------------------------
     * btdm（BLE controller）边界符号
     *
     * `libble_app.a` 的一个对象会用
     *   memset(&_bss_start_btdm, 0, &_bss_end_btdm - &_bss_start_btdm)
     *   memcpy(&_data_start_btdm, _data_start_btdm_rom, &_data_end_btdm - &_data_start_btdm)
     * 初始化 controller 的工作区。本布局里 controller 自己的 `.bss`/`.data`
     * 就落在上面的常规 `.bss`/`.data` 中，而且：
     *   - `.bss` 已由 `_start` 清零；
     *   - `.data` 的 LMA == VMA（镜像里就是初值），启动时无需搬运。
     * 因此把这两个区间定义成**零长度**（start == end），上面两段变成 no-op，
     * 语义等价，且不必另开一块 RAM 窗口。
     * 只在本板链接 BLE controller 时才有意义；`PROVIDE` 只填未定义符号，
     * 常规镜像不受影响。S31 没有 ROM 里的 btdm 副本，所以 ROM 侧地址也指向同一处。
     * ------------------------------------------------------------------- */
    /* **真实区间**（2026-11-17 修正）：原先是零长度区间，理由是"archive 的 .bss/.data
     * 已经在普通段里"。但 ROM 的 BT 代码可能用这段放**它自己的**状态 ⇒ 零长度 ⇒ 写越界。
     * 现在给两块独立的 RAM：btdm BSS 32 KiB（NOBITS）+ btdm DATA 4 KiB（NOBITS，初值由
     * `_data_start_btdm_rom` 指向同址 ⇒ memcpy 长度为 0，语义仍是"已初始化"）。 */
    .btdm_bss (NOLOAD) : ALIGN(16)
    {
        _bss_start_btdm = .;
        . = . + 0x1800;   /* 6 KiB（原 8 KiB）：让出 2 KiB 给校准段 */
        _bss_end_btdm = .;
    } > sram

    /* **PHY 校准专用缓冲**：位于 .btdm_bss 与 .btdm_data 之间，
     * 三者总长保持 12 KiB ⇒ _data_end_btdm / _heap_start 不变、arena 保持 376 KiB。
     * NOLOAD 且不在 .bss 内 ⇒ _start 不清零，calloc 路径必须自己清零。 */
    .phy_cal_buf (NOLOAD) : ALIGN(16)
    {
        _phy_cal_buf_start = .;
        . = . + 0x800;   /* 2048 B */
        _phy_cal_buf_end = .;
    } > sram

    .btdm_data (NOLOAD) : ALIGN(16)
    {
        _data_start_btdm = .;
        . = . + 0x1000;   /* 4 KiB：减到 2 KiB 只让 free 涨 128 B（归档会吃光给它的空间）*/
        _data_end_btdm = .;
        _data_start_btdm_rom = _data_start_btdm;
    } > sram




    /* 链接期就否决明显错误的布局，免得自检变成唯一的防线。 */
    ASSERT(_image_start == ORIGIN(irom),
        "first flash segment must start at ORIGIN(irom) = 0x40000020")
    ASSERT(_text_end <= ORIGIN(drom),
        ".flash.text must not overlap the drom window (expand layout instead)")
    ASSERT(_rodata_start >= ORIGIN(drom) && _rodata_end <= ORIGIN(drom) + LENGTH(drom),
        ".flash.rodata must live inside the drom window")
    ASSERT(_rodata_start % 32 == 0,
        ".flash.rodata must stay 32-byte aligned (LLVM .rodata input alignment)")
    ASSERT(_trap_start >= ORIGIN(sram) && _trap_end <= ORIGIN(sram) + LENGTH(sram),
        ".trap_ram must live inside SRAM")
    ASSERT(_bss_end <= _stack_bottom,
        "SRAM exhausted: .bss overlaps the 16 KiB main stack")
    ASSERT(_stack_top == ORIGIN(sram) + LENGTH(sram),
        "_stack_top must be the exclusive end of SRAM")

    /*
     * 掩膜 ROM 里的函数，用绝对地址提供：
     *   IDF v6.1 components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     ets_printf   = 0x2f800024
     *     ets_delay_us = 0x2f80003c
     * ROM 区间 0x2F800000..0x2F850000（soc.h 的 SOC_IROM_MASK_LOW/HIGH），
     * 是独立的地址空间，不与应用 SRAM 顶端 0x2F07AFC0 冲突。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
    /*
     * SPI flash 读/写/擦（C5 的 OTA 落盘需要）：
     *   esp_rom_spiflash_erase_sector = 0x2f800160  (参数是**扇区号**)
     *   esp_rom_spiflash_write        = 0x2f800168
     *   esp_rom_spiflash_read         = 0x2f80016c
     * 签名见同版本 `esp_rom_spiflash.h`；地址与 ch09/ch23 的实测快照一致。
     */
    PROVIDE(esp_rom_spiflash_erase_sector = 0x2f800160);
    PROVIDE(esp_rom_spiflash_write = 0x2f800168);
    PROVIDE(esp_rom_spiflash_read = 0x2f80016c);
}

INCLUDE ../boards/esp32s31-coreboard/linker/rom_syms.ld

/* WiFi/BT 预编译归档引用的外设基址符号（121 PROVIDE，esp-idf 组件片段）*/
/*
 * SPDX-FileCopyrightText: 2025-2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0 OR MIT
 */

PROVIDE ( USB_OTGHS           = 0x20300000 );
PROVIDE ( PAU                 = 0x20341000 );
PROVIDE ( SDMMC               = 0x20342000 );
PROVIDE ( AHB_DMA             = 0x20343000 );
PROVIDE ( JPEG                = 0x20344000 );
PROVIDE ( PPA                 = 0x20345000 );
PROVIDE ( DMA2D               = 0x20346000 );
PROVIDE ( AXI_DMA             = 0x20348000 );
PROVIDE ( GMAC                = 0x20350000 );
/* Split GMAC into MAC/PTP/DMA for the HAL layer */
PROVIDE ( EMAC_MAC            = 0x20350000 );
PROVIDE ( EMAC_PTP            = 0x20350700 );
PROVIDE ( EMAC_DMA            = 0x20351000 );
PROVIDE ( PVT                 = 0x20354000 );
PROVIDE ( RMT                 = 0x20355000 );
PROVIDE ( RMTMEM              = 0x20355800 );
PROVIDE ( BITSCRAMBLER        = 0x20356000 );
PROVIDE ( ASRC                = 0x20357000 );
PROVIDE ( CNNT_SYS_REG        = 0x20359000 );
PROVIDE ( USB_UTMI            = 0x20380000 );
PROVIDE ( MCPWM0              = 0x20381000 );
PROVIDE ( MCPWM1              = 0x20382000 );
PROVIDE ( MCPWM2              = 0x20383000 );
PROVIDE ( MCPWM3              = 0x20384000 );
PROVIDE ( I2C0                = 0x20385000 );
PROVIDE ( I2C1                = 0x20386000 );
PROVIDE ( I2S0                = 0x20387000 );
PROVIDE ( I2S1                = 0x20388000 );
PROVIDE ( PCNT0               = 0x20389000 );
PROVIDE ( UART0               = 0x2038A000 );
PROVIDE ( UART1               = 0x2038B000 );
PROVIDE ( UART2               = 0x2038C000 );
PROVIDE ( UART3               = 0x2038D000 );
PROVIDE ( PARL_IO             = 0x2038E000 );
PROVIDE ( GPSPI2              = 0x2038F000 );
PROVIDE ( GPSPI3              = 0x20390000 );
PROVIDE ( USB_SERIAL_JTAG     = 0x20391000 );
PROVIDE ( LEDC0               = 0x20392000 );
PROVIDE ( LEDC0_GAMMA_RAM     = 0x20392400 );
PROVIDE ( SOC_ETM             = 0x20393000 );
PROVIDE ( TWAIFD0             = 0x20394000 );
PROVIDE ( TWAIFD1             = 0x20395000 );
PROVIDE ( LCD_CAM             = 0x20396000 );
PROVIDE ( UHCI0               = 0x20398000 );
PROVIDE ( SYSTIMER            = 0x20399000 );
PROVIDE ( ZERO_DET            = 0x2039A000 );
PROVIDE ( CORDIC              = 0x2039B000 );
PROVIDE ( LEDC1               = 0x2039C000 );
PROVIDE ( LEDC1_GAMMA_RAM     = 0x2039C400 );
PROVIDE ( PCNT1               = 0x2039D000 );
PROVIDE ( SPIMEM0             = 0x20500000 );
PROVIDE ( SPIMEM1             = 0x20501000 );
PROVIDE ( SPIMEM2             = 0x20502000 );
PROVIDE ( SPIMEM3             = 0x20503000 );
PROVIDE ( TEE                 = 0x20504000 );
PROVIDE ( HP_APM              = 0x20504400 );
PROVIDE ( HP_MEM_APM          = 0x20504800 );
PROVIDE ( CPU_APM             = 0x20504C00 );
PROVIDE ( HP_PERI0_PMS        = 0x20505000 );
PROVIDE ( KEYMNG              = 0x20506000 );
PROVIDE ( AES                 = 0x20508000 );
PROVIDE ( SHA                 = 0x20509000 );
PROVIDE ( RSA                 = 0x2050A000 );
PROVIDE ( ECC                 = 0x2050B000 );
PROVIDE ( DS                  = 0x2050C000 );
PROVIDE ( HMAC                = 0x2050D000 );
PROVIDE ( ECDSA               = 0x2050E000 );
PROVIDE ( RMA                 = 0x2050F000 );
PROVIDE ( ICM_SYS             = 0x20510000 );
PROVIDE ( ICM                 = 0x20510400 );
PROVIDE ( AXI_PERF_MON        = 0x20511000 );
PROVIDE ( TIMERG0             = 0x20580000 );
PROVIDE ( TIMERG1             = 0x20581000 );
PROVIDE ( IO_MUX              = 0x20582000 );
PROVIDE ( GPIO                = 0x20583000 );
PROVIDE ( GPIO_EXT            = 0x20583E00 );
PROVIDE ( MSPI_IOMUX          = 0x20584000 );
PROVIDE ( HP_SYSTEM           = 0x20586000 );
PROVIDE ( HP_SYS_CLKRST       = 0x20587000 );
PROVIDE ( CNNT_PAD_CTRL       = 0x20588000 );
PROVIDE ( HP_ALIVE_SYS        = 0x20589000 );
PROVIDE ( HP_PERI1_PMS        = 0x2058A000 );
PROVIDE ( LP_SYS              = 0x20700000 );
PROVIDE ( LP_CLKRST           = 0x20701000 );
PROVIDE ( LP_ANA_PERI         = 0x20702000 );
PROVIDE ( HUK                 = 0x20703000 );
PROVIDE ( PMU                 = 0x20704000 );
PROVIDE ( TOUCH_AON           = 0x20705000 );
PROVIDE ( LP_PERI_PMS         = 0x20706000 );
PROVIDE ( LP_TEE              = 0x20706800 );
PROVIDE ( LP_APM              = 0x20706C00 );
PROVIDE ( LP_PERI_CLKRST      = 0x20710000 );
PROVIDE ( LP_IO_MUX           = 0x20712000 );
PROVIDE ( LP_GPIO             = 0x20713000 );
PROVIDE ( LP_INTR             = 0x20714000 );
PROVIDE ( EFUSE               = 0x20715000 );
PROVIDE ( RTC_TIMER           = 0x20800000 );
PROVIDE ( RTC_WDT             = 0x20801000 );
PROVIDE ( LP_CLOCK_CALI0      = 0x20802000 );
PROVIDE ( LP_CLOCK_CALI1      = 0x20803000 );
PROVIDE ( LP_PWR_REG          = 0x20804000 );
PROVIDE ( LP_ADI              = 0x20805000 );
PROVIDE ( LP_UART             = 0x20810000 );
PROVIDE ( LP_I2C              = 0x20811000 );
PROVIDE ( LP_SPI              = 0x20812000 );
PROVIDE ( LP_I2C_ANA_MST      = 0x20813000 );
PROVIDE ( LP_TRNG             = 0x20814000 );
PROVIDE ( ADC                 = 0x20815000 );
PROVIDE ( TOUCH_SENS          = 0x20816000 );
PROVIDE ( LP_MAILBOX          = 0x20817000 );
PROVIDE ( TSENS               = 0x20818000 );
PROVIDE ( LP_AHB_DMA          = 0x20819000 );
PROVIDE ( LP_DAC              = 0x2081A000 );
PROVIDE ( CACHE               = 0x2C000000 );
PROVIDE ( TRACE0              = 0x2D000000 );
PROVIDE ( TRACE1              = 0x2D001000 );
PROVIDE ( BUS_MONITOR         = 0x2D002000 );
PROVIDE ( MEM_MONITOR0        = 0x2D003000 );
PROVIDE ( MEM_MONITOR1        = 0x2D004000 );

PROVIDE ( MODEM_SYSCON  = 0x20109C00 );
PROVIDE ( MODEM_LPCON   = 0x2010F000 );

PROVIDE ( IEEE802154          = 0x20103000 );


/* **blob 第二镜像入口符号**（bb_v2_init/Cache/FE 的 blob 侧实现）：
 * blob 加载在 0x2f800000+，其导出符号在链接期以绝对地址形式提供。
 * 由 porting.zig 的 blob 加载器在运行时把镜像拷到该区。 */

/* **blob 第二镜像入口符号**（1336 个，由 idf-bt-ctl 链接 map 导出——
 * blob 加载器把镜像拷到 0x2f800000+ 后，这些 PROVIDE 让 HP 侧引用
 * 直达 blob 侧实现。Cache_* / FE / BB / osi 全入口） */
PROVIDE(tlsf_create = 0x2f8003d0);
PROVIDE(tlsf_create_with_pool = 0x2f8003d4);
PROVIDE(tlsf_get_pool = 0x2f8003d8);
PROVIDE(tlsf_add_pool = 0x2f8003dc);
PROVIDE(tlsf_remove_pool = 0x2f8003e0);
PROVIDE(tlsf_malloc = 0x2f8003e4);
PROVIDE(tlsf_memalign = 0x2f8003e8);
PROVIDE(tlsf_memalign_offs = 0x2f8003ec);
PROVIDE(tlsf_malloc_addr = 0x2f8003f0);
PROVIDE(tlsf_realloc = 0x2f8003f4);
PROVIDE(tlsf_free = 0x2f8003f8);
PROVIDE(tlsf_block_size = 0x2f8003fc);
PROVIDE(tlsf_size = 0x2f800400);
PROVIDE(tlsf_pool_overhead = 0x2f800404);
PROVIDE(tlsf_alloc_overhead = 0x2f800408);
PROVIDE(tlsf_walk_pool = 0x2f80040c);
PROVIDE(tlsf_check = 0x2f800410);
PROVIDE(tlsf_check_pool = 0x2f800414);
PROVIDE(tlsf_poison_fill_pfunc_set = 0x2f800418);
PROVIDE(tlsf_poison_check_pfunc_set = 0x2f80041c);
PROVIDE(multi_heap_get_block_address_impl = 0x2f800420);
PROVIDE(multi_heap_get_allocated_size_impl = 0x2f800424);
PROVIDE(multi_heap_register_impl = 0x2f800428);
PROVIDE(multi_heap_set_lock = 0x2f80042c);
PROVIDE(multi_heap_os_funcs_init = 0x2f800430);
PROVIDE(multi_heap_internal_lock = 0x2f800434);
PROVIDE(multi_heap_internal_unlock = 0x2f800438);
PROVIDE(multi_heap_get_first_block = 0x2f80043c);
PROVIDE(multi_heap_get_next_block = 0x2f800440);
PROVIDE(multi_heap_is_free = 0x2f800444);
PROVIDE(multi_heap_malloc_impl = 0x2f800448);
PROVIDE(multi_heap_free_impl = 0x2f80044c);
PROVIDE(multi_heap_realloc_impl = 0x2f800450);
PROVIDE(multi_heap_aligned_alloc_impl_offs = 0x2f800454);
PROVIDE(multi_heap_aligned_alloc_impl = 0x2f800458);
PROVIDE(multi_heap_check = 0x2f80045c);
PROVIDE(multi_heap_dump = 0x2f800460);
PROVIDE(multi_heap_free_size_impl = 0x2f800464);
PROVIDE(multi_heap_minimum_free_size_impl = 0x2f800468);
PROVIDE(multi_heap_get_info_impl = 0x2f80046c);
PROVIDE(rtc_get_reset_reason = 0x2f800018);
PROVIDE(rtc_get_wakeup_cause = 0x2f80001c);
PROVIDE(pmu_enable_unhold_pads = 0x2f800020);
PROVIDE(ets_printf = 0x2f800024);
PROVIDE(ets_install_putc1 = 0x2f800028);
PROVIDE(ets_install_putc2 = 0x2f80002c);
PROVIDE(ets_install_uart_printf = 0x2f800030);
PROVIDE(ets_install_usb_printf = 0x2f800034);
PROVIDE(ets_get_printf_channel = 0x2f800038);
PROVIDE(ets_delay_us = 0x2f80003c);
PROVIDE(ets_get_cpu_frequency = 0x2f800040);
PROVIDE(ets_update_cpu_frequency = 0x2f800044);
PROVIDE(ets_install_lock = 0x2f800048);
PROVIDE(UartRxString = 0x2f80004c);
PROVIDE(UartGetCmdLn = 0x2f800050);
PROVIDE(uart_tx_one_char = 0x2f800054);
PROVIDE(uart_tx_one_char2 = 0x2f800058);
PROVIDE(uart_tx_one_char3 = 0x2f80005c);
PROVIDE(uart_rx_one_char = 0x2f800060);
PROVIDE(uart_rx_one_char_block = 0x2f800064);
PROVIDE(uart_rx_intr_handler = 0x2f800068);
PROVIDE(uart_rx_readbuff = 0x2f80006c);
PROVIDE(uartAttach = 0x2f800070);
PROVIDE(uart_tx_flush = 0x2f800074);
PROVIDE(uart_tx_wait_idle = 0x2f800078);
PROVIDE(uart_div_modify = 0x2f80007c);
PROVIDE(ets_write_char_uart = 0x2f800080);
PROVIDE(uart_tx_switch = 0x2f800084);
PROVIDE(uart_buff_switch = 0x2f800088);
PROVIDE(roundup2 = 0x2f80008c);
PROVIDE(multofup = 0x2f800090);
PROVIDE(software_reset = 0x2f800094);
PROVIDE(software_reset_cpu = 0x2f800098);
PROVIDE(ets_clk_assist_debug_clock_enable = 0x2f80009c);
PROVIDE(clear_super_wdt_reset_flag = 0x2f8000a0);
PROVIDE(disable_default_watchdog = 0x2f8000a4);
PROVIDE(ets_set_appcpu_boot_addr = 0x2f8000a8);
PROVIDE(esp_rom_set_rtc_wake_addr = 0x2f8000ac);
PROVIDE(esp_rom_get_rtc_wake_addr = 0x2f8000b0);
PROVIDE(send_packet = 0x2f8000b4);
PROVIDE(recv_packet = 0x2f8000b8);
PROVIDE(GetUartDevice = 0x2f8000bc);
PROVIDE(UartDwnLdProc = 0x2f8000c0);
PROVIDE(GetSecurityInfoProc = 0x2f8000c4);
PROVIDE(Uart_Init = 0x2f8000c8);
PROVIDE(ets_set_user_start = 0x2f8000cc);
PROVIDE(ets_rom_layout_p = 0x2f84fffc);
PROVIDE(mz_adler32 = 0x2f8000d0);
PROVIDE(mz_free = 0x2f8000d4);
PROVIDE(tdefl_compress = 0x2f8000d8);
PROVIDE(tdefl_compress_buffer = 0x2f8000dc);
PROVIDE(tdefl_compress_mem_to_heap = 0x2f8000e0);
PROVIDE(tdefl_compress_mem_to_mem = 0x2f8000e4);
PROVIDE(tdefl_compress_mem_to_output = 0x2f8000e8);
PROVIDE(tdefl_get_adler32 = 0x2f8000ec);
PROVIDE(tdefl_get_prev_return_status = 0x2f8000f0);
PROVIDE(tdefl_init = 0x2f8000f4);
PROVIDE(tdefl_write_image_to_png_file_in_memory = 0x2f8000f8);
PROVIDE(tdefl_write_image_to_png_file_in_memory_ex = 0x2f8000fc);
PROVIDE(tinfl_decompress = 0x2f800100);
PROVIDE(tinfl_decompress_mem_to_callback = 0x2f800104);
PROVIDE(tinfl_decompress_mem_to_heap = 0x2f800108);
PROVIDE(tinfl_decompress_mem_to_mem = 0x2f80010c);
PROVIDE(jd_prepare = 0x2f800110);
PROVIDE(jd_decomp = 0x2f800114);
PROVIDE(esp_rom_opiflash_exec_cmd = 0x2f800118);
PROVIDE(esp_rom_spi_cmd_config = 0x2f80011c);
PROVIDE(esp_rom_spi_cmd_start = 0x2f800120);
PROVIDE(esp_rom_spi_set_op_mode = 0x2f800124);
PROVIDE(esp_rom_spi_set_dtr_swap_mode = 0x2f800128);
PROVIDE(esp_rom_spiflash_wait_idle = 0x2f80012c);
PROVIDE(esp_rom_spiflash_write_encrypted = 0x2f800130);
PROVIDE(esp_rom_spiflash_write_encrypted_dest = 0x2f800134);
PROVIDE(esp_rom_spiflash_write_encrypted_enable = 0x2f800138);
PROVIDE(esp_rom_spiflash_write_encrypted_disable = 0x2f80013c);
PROVIDE(esp_rom_spiflash_erase_chip = 0x2f800140);
PROVIDE(_esp_rom_spiflash_erase_sector = 0x2f800144);
PROVIDE(_esp_rom_spiflash_erase_block = 0x2f800148);
PROVIDE(_esp_rom_spiflash_write = 0x2f80014c);
PROVIDE(_esp_rom_spiflash_read = 0x2f800150);
PROVIDE(_esp_rom_spiflash_unlock = 0x2f800154);
PROVIDE(_SPIEraseArea = 0x2f800158);
PROVIDE(_SPI_write_enable = 0x2f80015c);
PROVIDE(esp_rom_spiflash_erase_sector = 0x2f800160);
PROVIDE(esp_rom_spiflash_erase_block = 0x2f800164);
PROVIDE(esp_rom_spiflash_write = 0x2f800168);
PROVIDE(esp_rom_spiflash_read = 0x2f80016c);
PROVIDE(esp_rom_spiflash_unlock = 0x2f800170);
PROVIDE(SPIEraseArea = 0x2f800174);
PROVIDE(SPI_write_enable = 0x2f800178);
PROVIDE(esp_rom_spiflash_config_param = 0x2f80017c);
PROVIDE(esp_rom_spiflash_read_user_cmd = 0x2f800180);
PROVIDE(esp_rom_spiflash_select_qio_pins = 0x2f800184);
PROVIDE(esp_rom_spi_flash_auto_sus_res = 0x2f800188);
PROVIDE(esp_rom_spiflash_cache_mode_config = 0x2f80018c);
PROVIDE(esp_rom_spi_flash_send_resume = 0x2f800190);
PROVIDE(esp_rom_spi_flash_update_id = 0x2f800194);
PROVIDE(esp_rom_spiflash_config_clk = 0x2f800198);
PROVIDE(esp_rom_spiflash_config_readmode = 0x2f80019c);
PROVIDE(esp_rom_spiflash_read_status = 0x2f8001a0);
PROVIDE(esp_rom_spiflash_read_statushigh = 0x2f8001a4);
PROVIDE(esp_rom_spiflash_write_status = 0x2f8001a8);
PROVIDE(esp_rom_spiflash_write_disable = 0x2f8001ac);
PROVIDE(spi_cache_mode_switch = 0x2f8001b0);
PROVIDE(spi_common_set_dummy_output = 0x2f8001b4);
PROVIDE(spi_common_set_flash_cs_timing = 0x2f8001b8);
PROVIDE(esp_rom_spi_set_address_bit_len = 0x2f8001bc);
PROVIDE(SPILock = 0x2f8001c0);
PROVIDE(SPIMasterReadModeCnfig = 0x2f8001c4);
PROVIDE(SPI_Common_Command = 0x2f8001c8);
PROVIDE(SPI_WakeUp = 0x2f8001cc);
PROVIDE(SPI_block_erase = 0x2f8001d0);
PROVIDE(SPI_chip_erase = 0x2f8001d4);
PROVIDE(SPI_init = 0x2f8001d8);
PROVIDE(SPI_page_program = 0x2f8001dc);
PROVIDE(SPI_read_data = 0x2f8001e0);
PROVIDE(SPI_sector_erase = 0x2f8001e4);
PROVIDE(SelectSpiFunction = 0x2f8001e8);
PROVIDE(SetSpiDrvs = 0x2f8001ec);
PROVIDE(Wait_SPI_Idle = 0x2f8001f0);
PROVIDE(spi_dummy_len_fix = 0x2f8001f4);
PROVIDE(Disable_QMode = 0x2f8001f8);
PROVIDE(Enable_QMode = 0x2f8001fc);
PROVIDE(spi_flash_attach = 0x2f800200);
PROVIDE(spi_flash_get_chip_size = 0x2f800204);
PROVIDE(spi_flash_guard_set = 0x2f800208);
PROVIDE(spi_flash_guard_get = 0x2f80020c);
PROVIDE(spi_flash_read_encrypted = 0x2f800210);
PROVIDE(Cache_Get_L1_ICache_Line_Size = 0x2f8005d0);
PROVIDE(Cache_Get_L1_DCache_Line_Size = 0x2f8005d4);
PROVIDE(Cache_Get_Mode = 0x2f8005d8);
PROVIDE(Cache_Address_Through_Cache = 0x2f8005dc);
PROVIDE(ROM_Boot_Cache_Init = 0x2f8005e0);
PROVIDE(Cache_Sync_Addr = 0x2f8005e4);
PROVIDE(Cache_Invalidate_Addr = 0x2f8005e8);
PROVIDE(Cache_Clean_Addr = 0x2f8005ec);
PROVIDE(Cache_WriteBack_Addr = 0x2f8005f0);
PROVIDE(Cache_WriteBack_Invalidate_Addr = 0x2f8005f4);
PROVIDE(Cache_Invalidate_All = 0x2f8005f8);
PROVIDE(Cache_Clean_All = 0x2f8005fc);
PROVIDE(Cache_WriteBack_All = 0x2f800600);
PROVIDE(Cache_WriteBack_Invalidate_All = 0x2f800604);
PROVIDE(Cache_Mask_All = 0x2f800608);
PROVIDE(Cache_Suspend_L1_CORE0_ICache_Autoload = 0x2f80060c);
PROVIDE(Cache_Resume_L1_CORE0_ICache_Autoload = 0x2f800610);
PROVIDE(Cache_Suspend_L1_CORE1_ICache_Autoload = 0x2f800614);
PROVIDE(Cache_Resume_L1_CORE1_ICache_Autoload = 0x2f800618);
PROVIDE(Cache_Suspend_L1_DCache_Autoload = 0x2f80061c);
PROVIDE(Cache_Resume_L1_DCache_Autoload = 0x2f800620);
PROVIDE(Cache_Start_L1_CORE0_ICache_Preload = 0x2f800624);
PROVIDE(Cache_L1_CORE0_ICache_Preload_Done = 0x2f800628);
PROVIDE(Cache_End_L1_CORE0_ICache_Preload = 0x2f80062c);
PROVIDE(Cache_Start_L1_CORE1_ICache_Preload = 0x2f800630);
PROVIDE(Cache_L1_CORE1_ICache_Preload_Done = 0x2f800634);
PROVIDE(Cache_End_L1_CORE1_ICache_Preload = 0x2f800638);
PROVIDE(Cache_Start_L1_DCache_Preload = 0x2f80063c);
PROVIDE(Cache_L1_DCache_Preload_Done = 0x2f800640);
PROVIDE(Cache_End_L1_DCache_Preload = 0x2f800644);
PROVIDE(Cache_Config_L1_CORE0_ICache_Autoload = 0x2f800648);
PROVIDE(Cache_Enable_L1_CORE0_ICache_Autoload = 0x2f80064c);
PROVIDE(Cache_Disable_L1_CORE0_ICache_Autoload = 0x2f800650);
PROVIDE(Cache_Config_L1_CORE1_ICache_Autoload = 0x2f800654);
PROVIDE(Cache_Enable_L1_CORE1_ICache_Autoload = 0x2f800658);
PROVIDE(Cache_Disable_L1_CORE1_ICache_Autoload = 0x2f80065c);
PROVIDE(Cache_Config_L1_DCache_Autoload = 0x2f800660);
PROVIDE(Cache_Enable_L1_DCache_Autoload = 0x2f800664);
PROVIDE(Cache_Disable_L1_DCache_Autoload = 0x2f800668);
PROVIDE(Cache_Enable_L1_CORE0_ICache_PreLock = 0x2f80066c);
PROVIDE(Cache_Disable_L1_CORE0_ICache_PreLock = 0x2f800670);
PROVIDE(Cache_Enable_L1_CORE1_ICache_PreLock = 0x2f800674);
PROVIDE(Cache_Disable_L1_CORE1_ICache_PreLock = 0x2f800678);
PROVIDE(Cache_Enable_L1_DCache_PreLock = 0x2f80067c);
PROVIDE(Cache_Disable_L1_DCache_PreLock = 0x2f800680);
PROVIDE(Cache_Lock_Addr = 0x2f800684);
PROVIDE(Cache_Unlock_Addr = 0x2f800688);
PROVIDE(Cache_Disable_L1_CORE0_ICache = 0x2f80068c);
PROVIDE(Cache_Enable_L1_CORE0_ICache = 0x2f800690);
PROVIDE(Cache_Suspend_L1_CORE0_ICache = 0x2f800694);
PROVIDE(Cache_Resume_L1_CORE0_ICache = 0x2f800698);
PROVIDE(Cache_Disable_L1_CORE1_ICache = 0x2f80069c);
PROVIDE(Cache_Enable_L1_CORE1_ICache = 0x2f8006a0);
PROVIDE(Cache_Suspend_L1_CORE1_ICache = 0x2f8006a4);
PROVIDE(Cache_Resume_L1_CORE1_ICache = 0x2f8006a8);
PROVIDE(Cache_Disable_L1_DCache = 0x2f8006ac);
PROVIDE(Cache_Enable_L1_DCache = 0x2f8006b0);
PROVIDE(Cache_Suspend_L1_DCache = 0x2f8006b4);
PROVIDE(Cache_Resume_L1_DCache = 0x2f8006b8);
PROVIDE(Cache_FLASH_MMU_Init = 0x2f8006bc);
PROVIDE(Cache_PSRAM_MMU_Init = 0x2f8006c0);
PROVIDE(Cache_FLASH_MMU_Set = 0x2f8006c4);
PROVIDE(Cache_FLASH_MMU_Set_Secure = 0x2f8006c8);
PROVIDE(Cache_PSRAM_MMU_Set = 0x2f8006cc);
PROVIDE(Cache_PSRAM_MMU_Set_Secure = 0x2f8006d0);
PROVIDE(Cache_Count_Flash_Pages = 0x2f8006d4);
PROVIDE(Cache_Flash_To_SPIRAM_Copy = 0x2f8006d8);
PROVIDE(Cache_Travel_Tag_Memory = 0x2f8006dc);
PROVIDE(Cache_Travel_Tag_Memory2 = 0x2f8006e0);
PROVIDE(Cache_Get_Virtual_Addr = 0x2f8006e4);
PROVIDE(Cache_Set_IDROM_MMU_Size = 0x2f8006e8);
PROVIDE(flash2spiram_instruction_offset = 0x2f8006ec);
PROVIDE(flash2spiram_rodata_offset = 0x2f8006f0);
PROVIDE(flash_instr_rodata_start_page = 0x2f8006f4);
PROVIDE(flash_instr_rodata_end_page = 0x2f8006f8);
PROVIDE(Cache_Set_IDROM_MMU_Info = 0x2f8006fc);
PROVIDE(Cache_Get_IROM_MMU_End = 0x2f800700);
PROVIDE(Cache_Get_DROM_MMU_End = 0x2f800704);
PROVIDE(ets_clk_get_xtal_freq = 0x2f800708);
PROVIDE(ets_clk_get_cpu_freq = 0x2f80070c);
PROVIDE(rom_gpio_set_output_level = 0x2f800710);
PROVIDE(rom_gpio_get_input_level = 0x2f800714);
PROVIDE(rom_gpio_matrix_in = 0x2f800718);
PROVIDE(rom_gpio_matrix_out = 0x2f80071c);
PROVIDE(rom_gpio_bypass_matrix_in = 0x2f800720);
PROVIDE(rom_gpio_output_disable = 0x2f800724);
PROVIDE(rom_gpio_output_enable = 0x2f800728);
PROVIDE(rom_gpio_pad_input_disable = 0x2f80072c);
PROVIDE(rom_gpio_pad_input_enable = 0x2f800730);
PROVIDE(rom_gpio_pad_pulldown = 0x2f800734);
PROVIDE(rom_gpio_pad_pullup = 0x2f800738);
PROVIDE(rom_gpio_pad_select_gpio = 0x2f80073c);
PROVIDE(rom_gpio_pad_set_drv = 0x2f800740);
PROVIDE(rom_gpio_pad_unhold = 0x2f800744);
PROVIDE(rom_gpio_pad_hold = 0x2f800748);
PROVIDE(rom_gpio_lppad_select_mux = 0x2f80074c);
PROVIDE(esprv_intc_int_set_priority = 0x2f800750);
PROVIDE(esprv_intc_int_set_threshold = 0x2f800754);
PROVIDE(esprv_intc_int_enable = 0x2f800758);
PROVIDE(esprv_intc_int_disable = 0x2f80075c);
PROVIDE(esprv_intc_int_set_type = 0x2f800760);
PROVIDE(intr_handler_set = 0x2f800764);
PROVIDE(intr_matrix_set = 0x2f800768);
PROVIDE(ets_intr_register_ctx = 0x2f80076c);
PROVIDE(ets_intr_lock = 0x2f800770);
PROVIDE(ets_intr_unlock = 0x2f800774);
PROVIDE(ets_isr_attach = 0x2f800778);
PROVIDE(ets_isr_mask = 0x2f80077c);
PROVIDE(ets_isr_unmask = 0x2f800780);
PROVIDE(crc32_le = 0x2f800784);
PROVIDE(crc16_le = 0x2f800788);
PROVIDE(crc8_le = 0x2f80078c);
PROVIDE(crc32_be = 0x2f800790);
PROVIDE(crc16_be = 0x2f800794);
PROVIDE(crc8_be = 0x2f800798);
PROVIDE(esp_crc8 = 0x2f80079c);
PROVIDE(crc32_le_table_ptr = 0x2f84fff8);
PROVIDE(crc16_le_table_ptr = 0x2f84fff4);
PROVIDE(crc8_le_table_ptr = 0x2f84fff0);
PROVIDE(crc32_be_table_ptr = 0x2f84ffec);
PROVIDE(crc16_be_table_ptr = 0x2f84ffe8);
PROVIDE(crc8_be_table_ptr = 0x2f84ffe4);
PROVIDE(md5_vector = 0x2f8007a0);
PROVIDE(MD5Init = 0x2f8007a4);
PROVIDE(MD5Update = 0x2f8007a8);
PROVIDE(MD5Final = 0x2f8007ac);
PROVIDE(ets_sha_enable = 0x2f8007b0);
PROVIDE(ets_sha_disable = 0x2f8007b4);
PROVIDE(ets_sha_get_state = 0x2f8007b8);
PROVIDE(ets_sha_init = 0x2f8007bc);
PROVIDE(ets_sha_process = 0x2f8007c0);
PROVIDE(ets_sha_starts = 0x2f8007c4);
PROVIDE(ets_sha_update = 0x2f8007c8);
PROVIDE(ets_sha_finish = 0x2f8007cc);
PROVIDE(ets_sha_clone = 0x2f8007d0);
PROVIDE(ets_hmac_enable = 0x2f8007d4);
PROVIDE(ets_hmac_disable = 0x2f8007d8);
PROVIDE(ets_hmac_calculate_message = 0x2f8007dc);
PROVIDE(ets_hmac_calculate_downstream = 0x2f8007e0);
PROVIDE(ets_hmac_invalidate_downstream = 0x2f8007e4);
PROVIDE(ets_aes_enable = 0x2f8007e8);
PROVIDE(ets_aes_disable = 0x2f8007ec);
PROVIDE(ets_aes_setkey = 0x2f8007f0);
PROVIDE(ets_aes_block = 0x2f8007f4);
PROVIDE(ets_aes_setkey_dec = 0x2f8007f8);
PROVIDE(ets_aes_setkey_enc = 0x2f8007fc);
PROVIDE(ets_bigint_enable = 0x2f800800);
PROVIDE(ets_bigint_disable = 0x2f800804);
PROVIDE(ets_bigint_multiply = 0x2f800808);
PROVIDE(ets_bigint_modmult = 0x2f80080c);
PROVIDE(ets_bigint_modexp = 0x2f800810);
PROVIDE(ets_bigint_wait_finish = 0x2f800814);
PROVIDE(ets_bigint_getz = 0x2f800818);
PROVIDE(ets_ds_enable = 0x2f80081c);
PROVIDE(ets_ds_disable = 0x2f800820);
PROVIDE(ets_ds_start_sign = 0x2f800824);
PROVIDE(ets_ds_is_busy = 0x2f800828);
PROVIDE(ets_ds_finish_sign = 0x2f80082c);
PROVIDE(ets_ds_encrypt_params = 0x2f800830);
PROVIDE(ets_efuse_read = 0x2f800834);
PROVIDE(ets_efuse_program = 0x2f800838);
PROVIDE(ets_efuse_clear_program_registers = 0x2f80083c);
PROVIDE(ets_efuse_write_key = 0x2f800840);
PROVIDE(ets_efuse_get_read_register_address = 0x2f800844);
PROVIDE(ets_efuse_get_key_purpose = 0x2f800848);
PROVIDE(ets_efuse_key_block_unused = 0x2f80084c);
PROVIDE(ets_efuse_find_unused_key_block = 0x2f800850);
PROVIDE(ets_efuse_rs_calculate = 0x2f800854);
PROVIDE(ets_efuse_count_unused_key_blocks = 0x2f800858);
PROVIDE(ets_efuse_secure_boot_enabled = 0x2f80085c);
PROVIDE(ets_efuse_secure_boot_aggressive_revoke_enabled = 0x2f800860);
PROVIDE(ets_efuse_cache_encryption_enabled = 0x2f800864);
PROVIDE(ets_efuse_download_modes_disabled = 0x2f800868);
PROVIDE(ets_efuse_find_purpose = 0x2f80086c);
PROVIDE(ets_efuse_force_send_resume = 0x2f800870);
PROVIDE(ets_efuse_get_flash_delay_us = 0x2f800874);
PROVIDE(ets_efuse_get_uart_print_control = 0x2f800878);
PROVIDE(ets_efuse_direct_boot_mode_disabled = 0x2f80087c);
PROVIDE(ets_efuse_security_download_modes_enabled = 0x2f800880);
PROVIDE(ets_efuse_jtag_disabled = 0x2f800884);
PROVIDE(ets_efuse_usb_print_is_disabled = 0x2f800888);
PROVIDE(ets_efuse_usb_download_mode_disabled = 0x2f80088c);
PROVIDE(ets_efuse_usb_device_disabled = 0x2f800890);
PROVIDE(ets_efuse_get_km_huk_gen_state = 0x2f800894);
PROVIDE(ets_efuse_get_km_deploy_only_once = 0x2f800898);
PROVIDE(ets_efuse_get_force_use_km_key = 0x2f80089c);
PROVIDE(ets_efuse_xts_key_length_256 = 0x2f8008a0);
PROVIDE(ets_efuse_get_km_key_lock = 0x2f8008a4);
PROVIDE(ets_jtag_enable_temporarily = 0x2f8008a8);
PROVIDE(esp_rom_check_recover_key = 0x2f8008ac);
PROVIDE(esp_rom_km_huk_conf = 0x2f8008b0);
PROVIDE(esp_rom_km_huk_risk = 0x2f8008b4);
PROVIDE(esp_rom_recover_key = 0x2f8008b8);
PROVIDE(ets_emsa_pss_verify = 0x2f8008bc);
PROVIDE(ets_rsa_pss_verify = 0x2f8008c0);
PROVIDE(ets_ecdsa_verify = 0x2f8008c4);
PROVIDE(ets_secure_boot_verify_bootloader_with_keys = 0x2f8008c8);
PROVIDE(ets_secure_boot_verify_signature = 0x2f8008cc);
PROVIDE(ets_secure_boot_read_key_digests = 0x2f8008d0);
PROVIDE(ets_mgf1_sha256 = 0x2f8008d4);
PROVIDE(ets_secure_boot_revoke_public_key_digest = 0x2f8008d8);
PROVIDE(usb_serial_device_rx_one_char = 0x2f800a4c);
PROVIDE(usb_serial_device_rx_one_char_block = 0x2f800a50);
PROVIDE(usb_serial_device_tx_flush = 0x2f800a54);
PROVIDE(usb_serial_device_tx_one_char = 0x2f800a58);
PROVIDE(Uart_Init_USB = 0x2f800a5c);
PROVIDE(usb_serial_otg_rx_one_char = 0x2f800a60);
PROVIDE(usb_serial_otg_rx_one_char_block = 0x2f800a64);
PROVIDE(usb_serial_otg_tx_flush = 0x2f800a68);
PROVIDE(usb_serial_otg_tx_one_char = 0x2f800a6c);
PROVIDE(cdc_acm_class_handle_req = 0x2f800a70);
PROVIDE(cdc_acm_init = 0x2f800a74);
PROVIDE(cdc_acm_fifo_fill = 0x2f800a78);
PROVIDE(cdc_acm_rx_fifo_cnt = 0x2f800a7c);
PROVIDE(cdc_acm_fifo_read = 0x2f800a80);
PROVIDE(cdc_acm_irq_tx_enable = 0x2f800a84);
PROVIDE(cdc_acm_irq_tx_disable = 0x2f800a88);
PROVIDE(cdc_acm_irq_state_enable = 0x2f800a8c);
PROVIDE(cdc_acm_irq_state_disable = 0x2f800a90);
PROVIDE(cdc_acm_irq_tx_ready = 0x2f800a94);
PROVIDE(cdc_acm_irq_rx_enable = 0x2f800a98);
PROVIDE(cdc_acm_irq_rx_disable = 0x2f800a9c);
PROVIDE(cdc_acm_irq_rx_ready = 0x2f800aa0);
PROVIDE(cdc_acm_irq_is_pending = 0x2f800aa4);
PROVIDE(cdc_acm_irq_callback_set = 0x2f800aa8);
PROVIDE(cdc_acm_line_ctrl_set = 0x2f800aac);
PROVIDE(cdc_acm_line_ctrl_get = 0x2f800ab0);
PROVIDE(cdc_acm_poll_out = 0x2f800ab4);
PROVIDE(chip_usb_dw_did_persist = 0x2f800ab8);
PROVIDE(chip_usb_dw_init = 0x2f800abc);
PROVIDE(chip_usb_detach = 0x2f800ac0);
PROVIDE(chip_usb_dw_prepare_persist = 0x2f800ac4);
PROVIDE(chip_usb_get_persist_flags = 0x2f800ac8);
PROVIDE(chip_usb_set_persist_flags = 0x2f800acc);
PROVIDE(cpio_start = 0x2f800ad0);
PROVIDE(cpio_feed = 0x2f800ad4);
PROVIDE(cpio_done = 0x2f800ad8);
PROVIDE(cpio_destroy = 0x2f800adc);
PROVIDE(dfu_flash_init = 0x2f800ae0);
PROVIDE(dfu_flash_erase = 0x2f800ae4);
PROVIDE(dfu_flash_program = 0x2f800ae8);
PROVIDE(dfu_flash_read = 0x2f800aec);
PROVIDE(dfu_flash_attach = 0x2f800af0);
PROVIDE(dfu_cpio_callback = 0x2f800af4);
PROVIDE(dfu_updater_get_err = 0x2f800af8);
PROVIDE(dfu_updater_clear_err = 0x2f800afc);
PROVIDE(dfu_updater_enable = 0x2f800b00);
PROVIDE(dfu_updater_begin = 0x2f800b04);
PROVIDE(dfu_updater_feed = 0x2f800b08);
PROVIDE(dfu_updater_end = 0x2f800b0c);
PROVIDE(dfu_updater_set_raw_addr = 0x2f800b10);
PROVIDE(dfu_updater_flash_read = 0x2f800b14);
PROVIDE(usb_dc_prepare_persist = 0x2f800b18);
PROVIDE(usb_dw_isr_handler = 0x2f800b1c);
PROVIDE(usb_dc_attach = 0x2f800b20);
PROVIDE(usb_dc_detach = 0x2f800b24);
PROVIDE(usb_dc_reset = 0x2f800b28);
PROVIDE(usb_dc_set_address = 0x2f800b2c);
PROVIDE(usb_dc_ep_check_cap = 0x2f800b30);
PROVIDE(usb_dc_ep_configure = 0x2f800b34);
PROVIDE(usb_dc_ep_set_stall = 0x2f800b38);
PROVIDE(usb_dc_ep_clear_stall = 0x2f800b3c);
PROVIDE(usb_dc_ep_halt = 0x2f800b40);
PROVIDE(usb_dc_ep_is_stalled = 0x2f800b44);
PROVIDE(usb_dc_ep_enable = 0x2f800b48);
PROVIDE(usb_dc_ep_disable = 0x2f800b4c);
PROVIDE(usb_dc_ep_flush = 0x2f800b50);
PROVIDE(usb_dc_ep_write_would_block = 0x2f800b54);
PROVIDE(usb_dc_ep_write = 0x2f800b58);
PROVIDE(usb_dc_ep_read_wait = 0x2f800b5c);
PROVIDE(usb_dc_ep_read_continue = 0x2f800b60);
PROVIDE(usb_dc_ep_read = 0x2f800b64);
PROVIDE(usb_dc_ep_set_callback = 0x2f800b68);
PROVIDE(usb_dc_set_status_callback = 0x2f800b6c);
PROVIDE(usb_dc_ep_mps = 0x2f800b70);
PROVIDE(usb_dc_check_poll_for_interrupts = 0x2f800b74);
PROVIDE(mac_addr_to_serial_str_desc = 0x2f800b78);
PROVIDE(usb_set_current_descriptor = 0x2f800b7c);
PROVIDE(usb_get_descriptor = 0x2f800b80);
PROVIDE(usb_dev_resume = 0x2f800b84);
PROVIDE(usb_dev_get_configuration = 0x2f800b88);
PROVIDE(usb_set_config = 0x2f800b8c);
PROVIDE(usb_deconfig = 0x2f800b90);
PROVIDE(usb_enable = 0x2f800b94);
PROVIDE(usb_disable = 0x2f800b98);
PROVIDE(usb_write_would_block = 0x2f800b9c);
PROVIDE(usb_write = 0x2f800ba0);
PROVIDE(usb_read = 0x2f800ba4);
PROVIDE(usb_ep_set_stall = 0x2f800ba8);
PROVIDE(usb_ep_clear_stall = 0x2f800bac);
PROVIDE(usb_ep_read_wait = 0x2f800bb0);
PROVIDE(usb_ep_read_continue = 0x2f800bb4);
PROVIDE(usb_transfer_ep_callback = 0x2f800bb8);
PROVIDE(usb_transfer = 0x2f800bbc);
PROVIDE(usb_cancel_transfer = 0x2f800bc0);
PROVIDE(usb_transfer_sync = 0x2f800bc4);
PROVIDE(usb_dfu_set_detach_cb = 0x2f800bc8);
PROVIDE(dfu_class_handle_req = 0x2f800bcc);
PROVIDE(dfu_status_cb = 0x2f800bd0);
PROVIDE(dfu_custom_handle_req = 0x2f800bd4);
PROVIDE(usb_dfu_init = 0x2f800bd8);
PROVIDE(usb_dfu_force_detach = 0x2f800bdc);
PROVIDE(usb_dev_deinit = 0x2f800be0);
PROVIDE(usb_dw_ctrl_deinit = 0x2f800be4);
PROVIDE(ets_get_bootloader_offset = 0x2f800be8);
PROVIDE(ets_set_bootloader_offset = 0x2f800bec);
PROVIDE(__adddf3 = 0x2f800a0c);
PROVIDE(__eqdf2 = 0x2f800a10);
PROVIDE(__fixdfdi = 0x2f800a14);
PROVIDE(__fixdfsi = 0x2f800a18);
PROVIDE(__fixunsdfsi = 0x2f800a1c);
PROVIDE(__floatdidf = 0x2f800a20);
PROVIDE(__floatsidf = 0x2f800a24);
PROVIDE(__floatundidf = 0x2f800a28);
PROVIDE(__floatunsidf = 0x2f800a2c);
PROVIDE(__gedf2 = 0x2f800a30);
PROVIDE(__gtdf2 = 0x2f800a34);
PROVIDE(__ledf2 = 0x2f800a38);
PROVIDE(__ltdf2 = 0x2f800a3c);
PROVIDE(__muldf3 = 0x2f800a40);
PROVIDE(__nedf2 = 0x2f800a44);
PROVIDE(__subdf3 = 0x2f800a48);
PROVIDE(__powisf2 = 0x2f8008dc);
PROVIDE(__truncdfsf2 = 0x2f8008e0);
PROVIDE(__absvdi2 = 0x2f8008e4);
PROVIDE(__absvsi2 = 0x2f8008e8);
PROVIDE(__addvdi3 = 0x2f8008f0);
PROVIDE(__addvsi3 = 0x2f8008f4);
PROVIDE(__ashldi3 = 0x2f8008f8);
PROVIDE(__ashrdi3 = 0x2f8008fc);
PROVIDE(__bswapdi2 = 0x2f800900);
PROVIDE(__bswapsi2 = 0x2f800904);
PROVIDE(__clrsbdi2 = 0x2f800908);
PROVIDE(__clrsbsi2 = 0x2f80090c);
PROVIDE(__clzdi2 = 0x2f800910);
PROVIDE(__clzsi2 = 0x2f800914);
PROVIDE(__cmpdi2 = 0x2f800918);
PROVIDE(__ctzdi2 = 0x2f80091c);
PROVIDE(__ctzsi2 = 0x2f800920);
PROVIDE(__divdc3 = 0x2f800924);
PROVIDE(__divdf3 = 0x2f800928);
PROVIDE(__divdi3 = 0x2f80092c);
PROVIDE(__divsc3 = 0x2f800930);
PROVIDE(__divsi3 = 0x2f800934);
PROVIDE(__extendsfdf2 = 0x2f80093c);
PROVIDE(__ffsdi2 = 0x2f800940);
PROVIDE(__ffssi2 = 0x2f800944);
PROVIDE(__fixsfdi = 0x2f800950);
PROVIDE(__fixunssfdi = 0x2f800958);
PROVIDE(__fixunssfsi = 0x2f80095c);
PROVIDE(__floatdisf = 0x2f800964);
PROVIDE(__floatundisf = 0x2f800970);
PROVIDE(__gcc_bcmp = 0x2f800978);
PROVIDE(__lshrdi3 = 0x2f800988);
PROVIDE(__moddi3 = 0x2f800990);
PROVIDE(__modsi3 = 0x2f800994);
PROVIDE(__muldc3 = 0x2f800998);
PROVIDE(__muldi3 = 0x2f8009a0);
PROVIDE(__mulsc3 = 0x2f8009a4);
PROVIDE(__mulsi3 = 0x2f8009a8);
PROVIDE(__mulvdi3 = 0x2f8009ac);
PROVIDE(__mulvsi3 = 0x2f8009b0);
PROVIDE(__negdf2 = 0x2f8009b8);
PROVIDE(__negdi2 = 0x2f8009bc);
PROVIDE(__negvdi2 = 0x2f8009c0);
PROVIDE(__negvsi2 = 0x2f8009c4);
PROVIDE(__paritysi2 = 0x2f8009c8);
PROVIDE(__popcountdi2 = 0x2f8009cc);
PROVIDE(__popcountsi2 = 0x2f8009d0);
PROVIDE(__powidf2 = 0x2f8009d4);
PROVIDE(__subvdi3 = 0x2f8009dc);
PROVIDE(__subvsi3 = 0x2f8009e0);
PROVIDE(__ucmpdi2 = 0x2f8009e4);
PROVIDE(__udivdi3 = 0x2f8009e8);
PROVIDE(__udivmoddi4 = 0x2f8009ec);
PROVIDE(__udivsi3 = 0x2f8009f0);
PROVIDE(__udiv_w_sdiv = 0x2f8009f4);
PROVIDE(__umoddi3 = 0x2f8009f8);
PROVIDE(__umodsi3 = 0x2f8009fc);
PROVIDE(__unorddf2 = 0x2f800a00);
PROVIDE(__extenddftf2 = 0x2f800a04);
PROVIDE(__trunctfdf2 = 0x2f800a08);
PROVIDE(_rom_chip_id = 0x2f800010);
PROVIDE(_rom_eco_version = 0x2f800014);
PROVIDE(chip764_phyrom_version = 0x2f8011f0);
PROVIDE(chip764_phyrom_version_num = 0x2f8011f4);
PROVIDE(phy_param_addr = 0x2f8011f8);
PROVIDE(phy_get_romfuncs = 0x2f8011fc);
PROVIDE(phy_rate_to_index = 0x2f801200);
PROVIDE(phy_get_target_pwr = 0x2f801204);
PROVIDE(phy_get_max_pwr = 0x2f801208);
PROVIDE(phy_get_pwr_index = 0x2f80120c);
PROVIDE(phy_get_rc_dout = 0x2f801210);
PROVIDE(phy_rc_cal = 0x2f801214);
PROVIDE(phy_abs_temp = 0x2f801218);
PROVIDE(phy_get_data_sat = 0x2f80121c);
PROVIDE(phy_byte_to_word = 0x2f801220);
PROVIDE(phy_bb_bss_cbw40 = 0x2f801224);
PROVIDE(phy_set_chan_reg = 0x2f801228);
PROVIDE(phy_i2c_master_reset = 0x2f80122c);
PROVIDE(phy_chan14_mic_enable = 0x2f801230);
PROVIDE(phy_chan14_mic_cfg = 0x2f801234);
PROVIDE(phy_set_most_tpw = 0x2f801238);
PROVIDE(phy_get_most_tpw = 0x2f80123c);
PROVIDE(phy_tx_state_out = 0x2f801240);
PROVIDE(phy_ant_dft_cfg = 0x2f801244);
PROVIDE(phy_ant_wifitx_cfg = 0x2f801248);
PROVIDE(phy_ant_wifirx_cfg = 0x2f80124c);
PROVIDE(phy_ant_bttx_cfg = 0x2f801250);
PROVIDE(phy_ant_btrx_cfg = 0x2f801254);
PROVIDE(phy_chan_dump_cfg = 0x2f801258);
PROVIDE(phy_enable_low_rate = 0x2f80125c);
PROVIDE(phy_disable_low_rate = 0x2f801260);
PROVIDE(phy_is_low_rate_enabled = 0x2f801264);
PROVIDE(phy_dig_reg_backup = 0x2f801268);
PROVIDE(phy_chan_filt_set = 0x2f80126c);
PROVIDE(phy_rx11blr_cfg = 0x2f801270);
PROVIDE(phy_set_cca = 0x2f801274);
PROVIDE(phy_set_rx_sense = 0x2f801278);
PROVIDE(phy_freq_module_resetn = 0x2f80127c);
PROVIDE(phy_freq_chan_en_sw = 0x2f801280);
PROVIDE(phy_write_chan_freq = 0x2f801284);
PROVIDE(phy_get_freq_mem_param = 0x2f801288);
PROVIDE(phy_get_freq_mem_addr = 0x2f80128c);
PROVIDE(phy_read_rf_freq_mem = 0x2f801290);
PROVIDE(phy_freq_i2c_mem_write = 0x2f801294);
PROVIDE(phy_freq_num_get_data = 0x2f801298);
PROVIDE(phy_freq_i2c_num_addr = 0x2f80129c);
PROVIDE(phy_freq_i2c_write_set = 0x2f8012a0);
PROVIDE(phy_pll_cap_mem_update = 0x2f8012a4);
PROVIDE(phy_en_hw_set_freq = 0x2f8012a8);
PROVIDE(phy_dis_hw_set_freq = 0x2f8012ac);
PROVIDE(phy_wait_freq_set_busy = 0x2f8012b0);
PROVIDE(phy_i2c_enter_critical_ = 0x2f8012b4);
PROVIDE(phy_i2c_exit_critical_ = 0x2f8012b8);
PROVIDE(phy_i2c_clk_sel = 0x2f8012bc);
PROVIDE(phy_get_i2c_read_mask_ = 0x2f8012c0);
PROVIDE(phy_get_i2c_mst0_mask = 0x2f8012c4);
PROVIDE(phy_get_i2c_hostid_ = 0x2f8012c8);
PROVIDE(phy_chip_i2c_readReg_org = 0x2f8012cc);
PROVIDE(phy_chip_i2c_readReg = 0x2f8012d0);
PROVIDE(phy_i2c_paral_set_mst0 = 0x2f8012d4);
PROVIDE(phy_i2c_paral_set_read = 0x2f8012d8);
PROVIDE(phy_i2c_paral_read = 0x2f8012dc);
PROVIDE(phy_i2c_paral_write = 0x2f8012e0);
PROVIDE(phy_i2c_paral_write_num = 0x2f8012e4);
PROVIDE(phy_i2c_paral_write_mask = 0x2f8012e8);
PROVIDE(phy_i2c_readReg = 0x2f8012ec);
PROVIDE(phy_chip_i2c_writeReg = 0x2f8012f0);
PROVIDE(phy_i2c_writeReg = 0x2f8012f4);
PROVIDE(phy_i2c_readReg_Mask = 0x2f8012f8);
PROVIDE(phy_set_txcap_reg = 0x2f8012fc);
PROVIDE(phy_i2c_sar2_init_code = 0x2f801300);
PROVIDE(phy_filter_dcap_set = 0x2f801304);
PROVIDE(phy_i2c_rc_cal_set = 0x2f801308);
PROVIDE(phy_adc_rate_set = 0x2f80130c);
PROVIDE(phy_dac_rate_set = 0x2f801310);
PROVIDE(phy_encode_i2c_master = 0x2f801314);
PROVIDE(phy_i2c_master_fill = 0x2f801318);
PROVIDE(phy_open_fe_bb_clk = 0x2f80131c);
PROVIDE(phy_get_mac_addr = 0x2f801320);
PROVIDE(phy_set_mac_data = 0x2f801324);
PROVIDE(phy_rfcal_data_sub = 0x2f801328);
PROVIDE(phy_rf_cal_data_recovery = 0x2f80132c);
PROVIDE(phy_rf_cal_data_backup = 0x2f801330);
PROVIDE(phy_rfcal_data_check = 0x2f801334);
PROVIDE(phy_pbus_force_mode = 0x2f801338);
PROVIDE(phy_pbus_force_test = 0x2f80133c);
PROVIDE(phy_pbus_rd = 0x2f801340);
PROVIDE(phy_pbus_debugmode = 0x2f801344);
PROVIDE(phy_pbus_workmode = 0x2f801348);
PROVIDE(phy_pbus_clear_reg = 0x2f80134c);
PROVIDE(phy_pbus_set_rxgain = 0x2f801350);
PROVIDE(phy_pbus_set_dco = 0x2f801354);
PROVIDE(phy_set_loopback_gain = 0x2f801358);
PROVIDE(phy_txcal_debuge_mode_ = 0x2f80135c);
PROVIDE(phy_txcal_work_mode = 0x2f801360);
PROVIDE(phy_write_pbus_mem = 0x2f801364);
PROVIDE(phy_set_pbus_mem = 0x2f801368);
PROVIDE(phy_pwdet_reg_init = 0x2f80136c);
PROVIDE(phy_pwdet_sar2_init = 0x2f801370);
PROVIDE(phy_en_pwdet = 0x2f801374);
PROVIDE(phy_get_sar_sig_ref = 0x2f801378);
PROVIDE(phy_pwdet_tone_start = 0x2f80137c);
PROVIDE(phy_get_fm_sar_dout = 0x2f801380);
PROVIDE(phy_txtone_linear_pwr = 0x2f801384);
PROVIDE(phy_linear_to_db = 0x2f801388);
PROVIDE(phy_get_power_db = 0x2f80138c);
PROVIDE(phy_meas_tone_pwr_db = 0x2f801390);
PROVIDE(phy_pwdet_wait_idle = 0x2f801394);
PROVIDE(phy_pkdet_vol_start = 0x2f801398);
PROVIDE(phy_read_sar_dout = 0x2f80139c);
PROVIDE(phy_read_sar2_code = 0x2f8013a0);
PROVIDE(phy_get_sar2_vol = 0x2f8013a4);
PROVIDE(phy_disable_agc = 0x2f8013a8);
PROVIDE(phy_enable_agc = 0x2f8013ac);
PROVIDE(phy_disable_cca = 0x2f8013b0);
PROVIDE(phy_enable_cca = 0x2f8013b4);
PROVIDE(phy_write_gain_mem = 0x2f8013b8);
PROVIDE(phy_bb_bss_cbw40_dig = 0x2f8013bc);
PROVIDE(phy_tx_paon_set = 0x2f8013c0);
PROVIDE(phy_i2cmst_reg_init = 0x2f8013c4);
PROVIDE(phy_bt_gain_offset = 0x2f8013c8);
PROVIDE(phy_fe_reg_init = 0x2f8013cc);
PROVIDE(phy_mac_enable_bb = 0x2f8013d0);
PROVIDE(phy_bb_wdg_cfg = 0x2f8013d4);
PROVIDE(phy_fe_txrx_reset = 0x2f8013d8);
PROVIDE(phy_set_rx_comp_ = 0x2f8013dc);
PROVIDE(phy_agc_reg_init = 0x2f8013e0);
PROVIDE(phy_bb_reg_init = 0x2f8013e4);
PROVIDE(phy_open_i2c_xpd = 0x2f8013e8);
PROVIDE(phy_force_txrx_off = 0x2f8013ec);
PROVIDE(phy_txiq_set_reg = 0x2f8013f0);
PROVIDE(phy_rxiq_set_reg = 0x2f8013f4);
PROVIDE(phy_rx_gain_force = 0x2f8013f8);
PROVIDE(phy_set_txclk_en = 0x2f8013fc);
PROVIDE(phy_set_rxclk_en = 0x2f801400);
PROVIDE(phy_start_tx_tone_step = 0x2f801404);
PROVIDE(phy_stop_tx_tone = 0x2f801408);
PROVIDE(phy_bb_wdg_test_en = 0x2f80140c);
PROVIDE(phy_noise_floor_auto_set = 0x2f801410);
PROVIDE(phy_read_hw_noisefloor = 0x2f801414);
PROVIDE(phy_iq_corr_enable = 0x2f801418);
PROVIDE(phy_wifi_agc_sat_gain = 0x2f80141c);
PROVIDE(phy_bbpll_cal = 0x2f801420);
PROVIDE(phy_ant_init = 0x2f801424);
PROVIDE(phy_wifi_fbw_sel = 0x2f801428);
PROVIDE(phy_bt_filter_reg = 0x2f80142c);
PROVIDE(phy_rx_sense_set = 0x2f801430);
PROVIDE(phy_tx_state_set = 0x2f801434);
PROVIDE(phy_close_pa = 0x2f801438);
PROVIDE(phy_freq_correct = 0x2f80143c);
PROVIDE(phy_set_pbus_reg = 0x2f801440);
PROVIDE(phy_wifi_rifs_mode_en = 0x2f801444);
PROVIDE(phy_nrx_freq_set = 0x2f801448);
PROVIDE(phy_fe_adc_on = 0x2f80144c);
PROVIDE(phy_force_pwr_index = 0x2f801450);
PROVIDE(phy_fft_scale_force = 0x2f801454);
PROVIDE(phy_force_rx_gain = 0x2f801458);
PROVIDE(phy_wifi_enable_set = 0x2f80145c);
PROVIDE(phy_bb_cbw_chan_cfg = 0x2f801460);
PROVIDE(phy_vht_support = 0x2f801464);
PROVIDE(phy_csidump_force_lltf_cfg = 0x2f801468);
PROVIDE(phy_hemu_ru26_good_res = 0x2f80146c);
PROVIDE(phy_bb_cfo_cfg = 0x2f801470);
PROVIDE(phy_freq_band_reg_set = 0x2f801474);
PROVIDE(phy_set_bb_wdg = 0x2f801478);
PROVIDE(phy_sifs_reg_init = 0x2f80147c);
PROVIDE(phy_bbtx_outfilter = 0x2f801480);
PROVIDE(phy_bb_wdt_rst_enable = 0x2f801484);
PROVIDE(phy_bb_wdt_int_enable = 0x2f801488);
PROVIDE(phy_bb_wdt_timeout_clear = 0x2f80148c);
PROVIDE(phy_bb_wdt_get_status = 0x2f801490);
PROVIDE(phy_chan_to_freq = 0x2f801494);
PROVIDE(phy_iq_est_enable = 0x2f801498);
PROVIDE(phy_iq_est_disable = 0x2f80149c);
PROVIDE(phy_dc_iq_est = 0x2f8014a0);
PROVIDE(phy_set_cal_rxdc = 0x2f8014a4);
PROVIDE(phy_rxiq_get_mis = 0x2f8014a8);
PROVIDE(phy_rxiq_cover_mg_mp = 0x2f8014ac);
PROVIDE(phy_rfcal_rxiq = 0x2f8014b0);
PROVIDE(phy_get_rfcal_rxiq_data = 0x2f8014b4);
PROVIDE(phy_get_dco_comp = 0x2f8014b8);
PROVIDE(phy_pbus_rx_dco_cal = 0x2f8014bc);
PROVIDE(phy_rxdc_est_min = 0x2f8014c0);
PROVIDE(phy_set_lb_txiq = 0x2f8014c4);
PROVIDE(phy_set_rx_gain_cal_iq = 0x2f8014c8);
PROVIDE(phy_set_rx_gain_cal_dc = 0x2f8014cc);
PROVIDE(phy_spur_cal = 0x2f8014d0);
PROVIDE(phy_spur_coef_cfg = 0x2f8014d4);
PROVIDE(phy_bb_gain_index = 0x2f8014d8);
PROVIDE(phy_rfrx_gain_index = 0x2f8014dc);
PROVIDE(phy_gen_rx_gain_table = 0x2f8014e0);
PROVIDE(phy_get_rxbb_dc = 0x2f8014e4);
PROVIDE(phy_wr_rx_gain_mem = 0x2f8014e8);
PROVIDE(phy_set_tsens_power_ = 0x2f8014ec);
PROVIDE(phy_get_tsens_value_ = 0x2f8014f0);
PROVIDE(phy_code_to_temp = 0x2f8014f4);
PROVIDE(phy_tsens_dac_to_index = 0x2f8014f8);
PROVIDE(phy_tsens_dac_cal = 0x2f8014fc);
PROVIDE(phy_tsens_code_read = 0x2f801500);
PROVIDE(phy_tsens_temp_read = 0x2f801504);
PROVIDE(phy_tsens_temp_read_local = 0x2f801508);
PROVIDE(phy_bt_txdc_cal = 0x2f80150c);
PROVIDE(phy_bt_txiq_cal = 0x2f801510);
PROVIDE(phy_txdc_cal = 0x2f801514);
PROVIDE(phy_txdc_cal_pwdet = 0x2f801518);
PROVIDE(phy_txiq_get_mis_pwr = 0x2f80151c);
PROVIDE(phy_txiq_cover = 0x2f801520);
PROVIDE(phy_rfcal_txiq = 0x2f801524);
PROVIDE(phy_get_power_atten = 0x2f801528);
PROVIDE(phy_pwdet_ref_code = 0x2f80152c);
PROVIDE(phy_pwdet_code_cal = 0x2f801530);
PROVIDE(phy_rfcal_txcap = 0x2f801534);
PROVIDE(phy_rfcal_pwrctrl = 0x2f801538);
PROVIDE(phy_tx_pwctrl_init_cal = 0x2f80153c);
PROVIDE(phy_txbbgain_to_index = 0x2f801540);
PROVIDE(phy_index_to_txbbgain = 0x2f801544);
PROVIDE(phy_bt_get_tx_gain = 0x2f801548);
PROVIDE(phy_dig_gain_check = 0x2f80154c);
PROVIDE(phy_wifi_get_tx_gain = 0x2f801550);
PROVIDE(phy_wifi_11g_rate_chg = 0x2f801554);
PROVIDE(phy_set_tx_gain_mem = 0x2f801558);
PROVIDE(phy_get_rate_fcc_index = 0x2f80155c);
PROVIDE(phy_get_chan_target_power = 0x2f801560);
PROVIDE(phy_get_tx_gain_value = 0x2f801564);
PROVIDE(phy_wifi_get_target_power = 0x2f801568);
PROVIDE(phy_wifi_get_tx_tab_ = 0x2f80156c);
PROVIDE(phy_wifi_set_tx_gain = 0x2f801570);
PROVIDE(phy_bt_get_tx_tab_ = 0x2f801574);
PROVIDE(phy_bt_set_tx_gain = 0x2f801578);
PROVIDE(phy_bb_agc_reg_update = 0x2f80157c);
PROVIDE(phy_bb_dcmem_clr = 0x2f801580);
PROVIDE(phy_bbpll_recal = 0x2f801584);
PROVIDE(phy_bt_bb_to_index = 0x2f801588);
PROVIDE(phy_bt_index_to_bb = 0x2f80158c);
PROVIDE(phy_bt_track_tx_power = 0x2f801590);
PROVIDE(phy_btbb_wifi_bb_cfg2 = 0x2f801594);
PROVIDE(phy_chip_set_chan_ana = 0x2f801598);
PROVIDE(phy_chip_set_chan_misc = 0x2f80159c);
PROVIDE(phy_dac_scale_set = 0x2f8015a0);
PROVIDE(phy_dcode_cal_init = 0x2f8015a4);
PROVIDE(phy_fe_reg_update = 0x2f8015a8);
PROVIDE(phy_force_rx_gain_trig = 0x2f8015ac);
PROVIDE(phy_freq_reg_init = 0x2f8015b0);
PROVIDE(phy_freq_set_reg = 0x2f8015b4);
PROVIDE(phy_get_cca = 0x2f8015b8);
PROVIDE(phy_get_cca_cnt = 0x2f8015bc);
PROVIDE(phy_get_dreg1p6 = 0x2f8015c0);
PROVIDE(phy_get_iq_value = 0x2f8015c4);
PROVIDE(phy_get_noise_floor = 0x2f8015c8);
PROVIDE(phy_get_oc_dr1 = 0x2f8015cc);
PROVIDE(phy_get_pll_vol = 0x2f8015d0);
PROVIDE(phy_get_rssi = 0x2f8015d4);
PROVIDE(phy_get_rx_sig_pwr = 0x2f8015d8);
PROVIDE(phy_get_tone_sar_dout_ = 0x2f8015dc);
PROVIDE(phy_get_txiq_set = 0x2f8015e0);
PROVIDE(phy_i2c_bbpll_set = 0x2f8015e4);
PROVIDE(phy_i2c_master_mem_txcap = 0x2f8015e8);
PROVIDE(phy_i2c_txrate_init = 0x2f8015ec);
PROVIDE(phy_i2c_writeReg_Mask = 0x2f8015f0);
PROVIDE(phy_lltf_mask_en = 0x2f8015f4);
PROVIDE(phy_loopback_mode_en = 0x2f8015f8);
PROVIDE(phy_mac_tx_chan_offset = 0x2f8015fc);
PROVIDE(phy_mhz2ieee = 0x2f801600);
PROVIDE(phy_pbus_rd_addr = 0x2f801604);
PROVIDE(phy_pbus_rd_shift = 0x2f801608);
PROVIDE(phy_pbus_rx_dco_cal_1step = 0x2f80160c);
PROVIDE(phy_pbus_xpd_rx_off = 0x2f801610);
PROVIDE(phy_pbus_xpd_rx_on = 0x2f801614);
PROVIDE(phy_pbus_xpd_tx_off = 0x2f801618);
PROVIDE(phy_pbus_xpd_tx_on = 0x2f80161c);
PROVIDE(phy_pll_dac_mem_update = 0x2f801620);
PROVIDE(phy_read_pll_cap = 0x2f801624);
PROVIDE(phy_reg_init = 0x2f801628);
PROVIDE(phy_reset_ckgen = 0x2f80162c);
PROVIDE(phy_restart_cal = 0x2f801630);
PROVIDE(phy_rfpll_cap_correct = 0x2f801634);
PROVIDE(phy_rfpll_cap_init_cal = 0x2f801638);
PROVIDE(phy_rfpll_cap_track = 0x2f80163c);
PROVIDE(phy_rfpll_chgp_cal = 0x2f801640);
PROVIDE(phy_rfpll_set_freq = 0x2f801644);
PROVIDE(phy_rfrx_sat_rst = 0x2f801648);
PROVIDE(phy_rx_11b_opt = 0x2f80164c);
PROVIDE(phy_rx_filter_mode = 0x2f801650);
PROVIDE(phy_save_pbus_reg = 0x2f801654);
PROVIDE(phy_set_cca_cnt = 0x2f801658);
PROVIDE(phy_set_chan_cal_interp = 0x2f80165c);
PROVIDE(phy_set_chan_freq_sw_start = 0x2f801660);
PROVIDE(phy_set_channel_dcode = 0x2f801664);
PROVIDE(phy_set_channel_rfpll_freq = 0x2f801668);
PROVIDE(phy_set_ext_dcode = 0x2f80166c);
PROVIDE(phy_set_freq = 0x2f801670);
PROVIDE(phy_set_rf_freq_offset = 0x2f801674);
PROVIDE(phy_set_rfpll_freq = 0x2f801678);
PROVIDE(phy_set_tsens_range_ = 0x2f80167c);
PROVIDE(phy_set_txcap_reset = 0x2f801680);
PROVIDE(phy_spur_reg_write_one_tone = 0x2f801684);
PROVIDE(phy_temp_to_power = 0x2f801688);
PROVIDE(phy_tx_pwctrl_bg_init = 0x2f80168c);
PROVIDE(phy_txgain_comp_pacfg_ = 0x2f801690);
PROVIDE(phy_txpwr_cal_track = 0x2f801694);
PROVIDE(phy_txpwr_correct = 0x2f801698);
PROVIDE(phy_txpwr_track_slow = 0x2f80169c);
PROVIDE(phy_wait_i2c_sdm_stable = 0x2f8016a0);
PROVIDE(phy_wait_rfpll_cal_end = 0x2f8016a4);
PROVIDE(phy_wifi_track_tx_power = 0x2f8016a8);
PROVIDE(phy_wr_rf_freq_mem = 0x2f8016ac);
PROVIDE(phy_write_pll_cap = 0x2f8016b0);
PROVIDE(phy_write_rfpll_sdm = 0x2f8016b4);
PROVIDE(phy_xpd_rf = 0x2f8016b8);
PROVIDE(esp_coex_rom_version_get = 0x2f800bf0);
PROVIDE(coex_bt_release = 0x2f800bf4);
PROVIDE(coex_bt_request = 0x2f800bf8);
PROVIDE(coex_core_ble_conn_dyn_prio_get = 0x2f800bfc);
PROVIDE(coex_core_event_duration_get = 0x2f800c00);
PROVIDE(coex_core_pti_get = 0x2f800c04);
PROVIDE(coex_core_release = 0x2f800c08);
PROVIDE(coex_core_request = 0x2f800c0c);
PROVIDE(coex_core_status_get = 0x2f800c10);
PROVIDE(coex_core_timer_idx_get = 0x2f800c14);
PROVIDE(coex_event_duration_get = 0x2f800c18);
PROVIDE(coex_hw_timer_disable = 0x2f800c1c);
PROVIDE(coex_hw_timer_enable = 0x2f800c20);
PROVIDE(coex_hw_timer_set = 0x2f800c24);
PROVIDE(coex_schm_interval_set = 0x2f800c28);
PROVIDE(coex_schm_lock = 0x2f800c2c);
PROVIDE(coex_schm_unlock = 0x2f800c30);
PROVIDE(coex_status_get = 0x2f800c34);
PROVIDE(coex_wifi_release = 0x2f800c38);
PROVIDE(esp_coex_ble_conn_dynamic_prio_get = 0x2f800c3c);
PROVIDE(esp_net80211_rom_version_get = 0x2f800c40);
PROVIDE(esp_wifi_internal_tx = 0x2f800c44);
PROVIDE(ampdu_dispatch = 0x2f800c48);
PROVIDE(ampdu_dispatch_all = 0x2f800c4c);
PROVIDE(ampdu_dispatch_as_many_as_possible = 0x2f800c50);
PROVIDE(ampdu_dispatch_movement = 0x2f800c54);
PROVIDE(ampdu_dispatch_upto = 0x2f800c58);
PROVIDE(chm_is_at_home_channel = 0x2f800c5c);
PROVIDE(ic_ebuf_recycle_rx = 0x2f800c68);
PROVIDE(ic_ebuf_recycle_tx = 0x2f800c6c);
PROVIDE(ic_reset_rx_ba = 0x2f800c70);
PROVIDE(ic_ebuf_alloc = 0x2f800c74);
PROVIDE(ic_reset_extra_softap_rx_ba = 0x2f800c78);
PROVIDE(ieee80211_align_eb = 0x2f800c7c);
PROVIDE(ieee80211_ampdu_reorder = 0x2f800c80);
PROVIDE(ieee80211_ampdu_start_age_timer = 0x2f800c84);
PROVIDE(ieee80211_is_tx_allowed = 0x2f800c8c);
PROVIDE(ieee80211_output_pending_eb = 0x2f800c90);
PROVIDE(ieee80211_output_process = 0x2f800c94);
PROVIDE(ieee80211_set_tx_desc = 0x2f800c98);
PROVIDE(ieee80211_classify = 0x2f800c9c);
PROVIDE(ieee80211_copy_eb_header = 0x2f800ca0);
PROVIDE(ieee80211_recycle_cache_eb = 0x2f800ca4);
PROVIDE(ieee80211_search_node = 0x2f800ca8);
PROVIDE(ieee80211_crypto_encap = 0x2f800cac);
PROVIDE(ieee80211_crypto_decap = 0x2f800cb0);
PROVIDE(ieee80211_decap = 0x2f800cb4);
PROVIDE(ieee80211_set_tx_pti = 0x2f800cb8);
PROVIDE(ieee80211_gettid = 0x2f800cbc);
PROVIDE(ieee80211_post_hmac_tx = 0x2f800cc0);
PROVIDE(ieee80211_alloc_tx_buf = 0x2f800cc4);
PROVIDE(ieee80211_output_do = 0x2f800cc8);
PROVIDE(ieee80211_find_elem_match = 0x2f800ccc);
PROVIDE(ieee80211_find_ie_match = 0x2f800cd0);
PROVIDE(ieee80211_find_elem = 0x2f800cd4);
PROVIDE(ieee80211_find_ext_elem = 0x2f800cd8);
PROVIDE(ieee80211_find_ie = 0x2f800cdc);
PROVIDE(ieee80211_find_ext_ie = 0x2f800ce0);
PROVIDE(ieee80211_merge_mbssid_profile = 0x2f800ce4);
PROVIDE(ieee80211_encap_esfbuf_htc = 0x2f800ce8);
PROVIDE(wifi_get_macaddr = 0x2f800cec);
PROVIDE(wifi_rf_phy_disable = 0x2f800cf0);
PROVIDE(wifi_rf_phy_enable = 0x2f800cf4);
PROVIDE(wifi_is_started = 0x2f800cf8);
PROVIDE(sta_input = 0x2f800cfc);
PROVIDE(sta_rx_eapol = 0x2f800d00);
PROVIDE(sta_reset_beacon_timeout = 0x2f800d04);
PROVIDE(sta_get_beacon_timeout = 0x2f800d08);
PROVIDE(ampdu_process_multicast_address_qos_frame = 0x2f800d0c);
PROVIDE(esp_pp_rom_version_get = 0x2f800d10);
PROVIDE(RC_GetBlockAckTime = 0x2f800d14);
PROVIDE(ebuf_list_remove = 0x2f800d18);
PROVIDE(esf_buf_alloc = 0x2f800d1c);
PROVIDE(esf_buf_alloc_dynamic = 0x2f800d20);
PROVIDE(esf_buf_recycle = 0x2f800d24);
PROVIDE(GetAccess = 0x2f800d28);
PROVIDE(hal_mac_is_low_rate_enabled = 0x2f800d2c);
PROVIDE(hal_mac_tx_get_blockack = 0x2f800d30);
PROVIDE(hal_mac_tx_set_ppdu = 0x2f800d34);
PROVIDE(hal_mac_tx_clr_mplen = 0x2f800d38);
PROVIDE(hal_mac_get_txq_state = 0x2f800d3c);
PROVIDE(hal_mac_clr_txq_state = 0x2f800d40);
PROVIDE(hal_mac_get_txq_complete = 0x2f800d44);
PROVIDE(hal_mac_deinit_twt_tx = 0x2f800d48);
PROVIDE(hal_mac_is_dma_enable = 0x2f800d4c);
PROVIDE(hal_he_get_bss_color = 0x2f800d50);
PROVIDE(hal_he_set_ersu = 0x2f800d54);
PROVIDE(hal_he_get_mplen_addr_start = 0x2f800d58);
PROVIDE(hal_he_get_mplen_addr_end = 0x2f800d5c);
PROVIDE(hal_he_set_bf_report_rate = 0x2f800d60);
PROVIDE(hal_he_set_ersu_ack_rate = 0x2f800d64);
PROVIDE(hal_he_get_aid = 0x2f800d68);
PROVIDE(hal_random = 0x2f800d6c);
PROVIDE(hal_enable_tx_statistics = 0x2f800d70);
PROVIDE(hal_enable_rx_statistics = 0x2f800d74);
PROVIDE(hal_enable_tsf_timer = 0x2f800d78);
PROVIDE(hal_wdev_timer_target_enable = 0x2f800d7c);
PROVIDE(hal_wdev_timer_set_target = 0x2f800d80);
PROVIDE(hal_tsf_timer_set_target = 0x2f800d84);
PROVIDE(hal_tsf_clear_soc_wakeup_request = 0x2f800d88);
PROVIDE(hal_get_tsf_time = 0x2f800d8c);
PROVIDE(hal_get_sta_tsf = 0x2f800d90);
PROVIDE(ic_get_trc = 0x2f800d94);
PROVIDE(ic_mac_deinit = 0x2f800d98);
PROVIDE(ic_mac_init = 0x2f800d9c);
PROVIDE(ic_interface_enabled = 0x2f800da0);
PROVIDE(is_lmac_idle = 0x2f800da4);
PROVIDE(ic_get_he_rts_threshold_bytes = 0x2f800da8);
PROVIDE(lmacAdjustTimestamp = 0x2f800dac);
PROVIDE(lmacDiscardAgedMSDU = 0x2f800db0);
PROVIDE(lmacDiscardMSDU = 0x2f800db4);
PROVIDE(lmacEndFrameExchangeSequence = 0x2f800db8);
PROVIDE(lmacIsIdle = 0x2f800dbc);
PROVIDE(lmacIsLongFrame = 0x2f800dc0);
PROVIDE(lmacMSDUAged = 0x2f800dc4);
PROVIDE(lmacPostTxComplete = 0x2f800dc8);
PROVIDE(lmacProcessAllTxTimeout = 0x2f800dcc);
PROVIDE(lmacProcessCollisions = 0x2f800dd0);
PROVIDE(lmacProcessRxSucData = 0x2f800dd4);
PROVIDE(lmacReachLongLimit = 0x2f800dd8);
PROVIDE(lmacReachShortLimit = 0x2f800ddc);
PROVIDE(lmacRecycleMPDU = 0x2f800de0);
PROVIDE(lmacRxDone = 0x2f800de4);
PROVIDE(lmacSetTxFrame = 0x2f800de8);
PROVIDE(lmacTxDone = 0x2f800dec);
PROVIDE(lmacTxFrame = 0x2f800df0);
PROVIDE(lmacDisableTransmit = 0x2f800df4);
PROVIDE(lmacDiscardFrameExchangeSequence = 0x2f800df8);
PROVIDE(lmacProcessCollision = 0x2f800dfc);
PROVIDE(lmacProcessAckTimeout = 0x2f800e00);
PROVIDE(lmacProcessShortRetryFail = 0x2f800e04);
PROVIDE(lmacProcessCollisions_task = 0x2f800e08);
PROVIDE(lmacProcessTxRtsError = 0x2f800e0c);
PROVIDE(lmacProcessTxError = 0x2f800e10);
PROVIDE(lmacProcessCtsTimeout = 0x2f800e14);
PROVIDE(lmacProcessLongRetryFail = 0x2f800e18);
PROVIDE(lmacRetryTxFrame = 0x2f800e1c);
PROVIDE(lmacEndRetryAMPDUFail = 0x2f800e20);
PROVIDE(lmacProcessTxSuccess = 0x2f800e24);
PROVIDE(lmacProcessTxComplete = 0x2f800e28);
PROVIDE(lmacProcessLongFrameSuccess = 0x2f800e2c);
PROVIDE(lmacProcessShortFrameSuccess = 0x2f800e30);
PROVIDE(lmacProcessModemStateRxBeacon = 0x2f800e34);
PROVIDE(mac_tx_set_duration = 0x2f800e38);
PROVIDE(mac_tx_set_plcp0 = 0x2f800e3c);
PROVIDE(mac_tx_set_plcp1 = 0x2f800e40);
PROVIDE(mac_tx_set_plcp2 = 0x2f800e44);
PROVIDE(mac_tx_set_len = 0x2f800e48);
PROVIDE(mac_tx_set_htsig = 0x2f800e4c);
PROVIDE(mac_tx_set_hesig = 0x2f800e50);
PROVIDE(mac_tx_set_tb = 0x2f800e54);
PROVIDE(mac_tx_set_mplen = 0x2f800e58);
PROVIDE(mac_tx_set_txop_q = 0x2f800e5c);
PROVIDE(mac_tx_set_pti = 0x2f800e60);
PROVIDE(pm_check_state = 0x2f800e64);
PROVIDE(pm_disable_dream_timer = 0x2f800e68);
PROVIDE(pm_disable_sleep_delay_timer = 0x2f800e6c);
PROVIDE(pm_dream = 0x2f800e70);
PROVIDE(pm_mac_wakeup = 0x2f800e74);
PROVIDE(pm_mac_sleep = 0x2f800e78);
PROVIDE(pm_enable_active_timer = 0x2f800e7c);
PROVIDE(pm_enable_sleep_delay_timer = 0x2f800e80);
PROVIDE(pm_local_tsf_process = 0x2f800e84);
PROVIDE(pm_set_beacon_filter = 0x2f800e88);
PROVIDE(pm_is_in_wifi_slice_threshold = 0x2f800e8c);
PROVIDE(pm_is_waked = 0x2f800e90);
PROVIDE(pm_keep_alive = 0x2f800e94);
PROVIDE(pm_on_beacon_rx = 0x2f800e98);
PROVIDE(pm_on_data_rx = 0x2f800e9c);
PROVIDE(pm_on_data_tx = 0x2f800ea0);
PROVIDE(pm_on_tbtt = 0x2f800ea4);
PROVIDE(pm_on_isr_sleep = 0x2f800ea8);
PROVIDE(pm_on_isr = 0x2f800eac);
PROVIDE(pm_on_isr_set_twt_target = 0x2f800eb0);
PROVIDE(pm_on_isr_twt_wake = 0x2f800eb4);
PROVIDE(pm_on_tsf_timer = 0x2f800eb8);
PROVIDE(pm_on_twt_force_tx = 0x2f800ebc);
PROVIDE(pm_parse_beacon = 0x2f800ec0);
PROVIDE(pm_process_tim = 0x2f800ec4);
PROVIDE(pm_rx_beacon_process = 0x2f800ec8);
PROVIDE(pm_rx_data_process = 0x2f800ecc);
PROVIDE(pm_sleep = 0x2f800ed0);
PROVIDE(pm_sleep_for = 0x2f800ed4);
PROVIDE(pm_tbtt_process = 0x2f800ed8);
PROVIDE(pm_tx_data_done_process = 0x2f800edc);
PROVIDE(pm_allow_tx = 0x2f800ee0);
PROVIDE(pm_extend_tbtt_adaptive_servo = 0x2f800ee4);
PROVIDE(pm_scale_listen_interval = 0x2f800ee8);
PROVIDE(pm_parse_mbssid_element = 0x2f800eec);
PROVIDE(pm_disconnected_wake = 0x2f800ef0);
PROVIDE(pm_tx_data_process = 0x2f800ef4);
PROVIDE(pm_is_twt_awake = 0x2f800ef8);
PROVIDE(pm_enable_twt_keep_alive = 0x2f800efc);
PROVIDE(pm_twt_on_tsf_timer = 0x2f800f00);
PROVIDE(pm_twt_process = 0x2f800f04);
PROVIDE(pm_is_twt_start = 0x2f800f08);
PROVIDE(pm_twt_set_target_wdev_time = 0x2f800f0c);
PROVIDE(pm_twt_set_target_tsf = 0x2f800f10);
PROVIDE(pm_enable_twt_keep_alive_timer = 0x2f800f14);
PROVIDE(pm_mac_try_enable_modem_state = 0x2f800f18);
PROVIDE(pm_beacon_monitor_tbtt_timeout_process = 0x2f800f1c);
PROVIDE(pm_update_next_tbtt = 0x2f800f20);
PROVIDE(pm_twt_disallow_tx = 0x2f800f24);
PROVIDE(pm_clear_wakeup_signal = 0x2f800f28);
PROVIDE(pm_mac_disable_tsf_tbtt_soc_wakeup = 0x2f800f2c);
PROVIDE(pm_mac_disable_tsf_tbtt_modem_wakeup = 0x2f800f30);
PROVIDE(pm_mac_enable_tsf_tbtt_soc_wakeup = 0x2f800f34);
PROVIDE(pm_mac_enable_tsf_tbtt_modem_wakeup = 0x2f800f38);
PROVIDE(pm_mac_modem_params_rt_update = 0x2f800f3c);
PROVIDE(pm_update_at_next_beacon = 0x2f800f40);
PROVIDE(tbtt_adaptive_setup = 0x2f800f44);
PROVIDE(tbtt_adaptive_servo = 0x2f800f48);
PROVIDE(ppAMPDU2Normal = 0x2f800f4c);
PROVIDE(ppHEAMPDU2Normal = 0x2f800f50);
PROVIDE(ppAssembleAMPDU = 0x2f800f54);
PROVIDE(ppCalFrameTimes = 0x2f800f58);
PROVIDE(ppCalSubFrameLength = 0x2f800f5c);
PROVIDE(ppCalTxAMPDULength = 0x2f800f60);
PROVIDE(ppCheckTxAMPDUlength = 0x2f800f64);
PROVIDE(ppDequeueRxq_Locked = 0x2f800f68);
PROVIDE(ppDequeueTxQ = 0x2f800f6c);
PROVIDE(ppEmptyDelimiterLength = 0x2f800f70);
PROVIDE(ppEnqueueRxq = 0x2f800f74);
PROVIDE(ppEnqueueTxDone = 0x2f800f78);
PROVIDE(ppGetTxframe = 0x2f800f7c);
PROVIDE(ppMapTxQueue = 0x2f800f80);
PROVIDE(ppProcTxSecFrame = 0x2f800f84);
PROVIDE(ppProcessRxPktHdr = 0x2f800f88);
PROVIDE(ppProcessTxQ = 0x2f800f8c);
PROVIDE(ppRecordBarRRC = 0x2f800f90);
PROVIDE(ppRecycleAmpdu = 0x2f800f94);
PROVIDE(ppRecycleRxPkt = 0x2f800f98);
PROVIDE(ppResortTxAMPDU = 0x2f800f9c);
PROVIDE(ppResumeTxAMPDU = 0x2f800fa0);
PROVIDE(ppRxFragmentProc = 0x2f800fa4);
PROVIDE(ppRxPkt = 0x2f800fa8);
PROVIDE(ppRxProtoProc = 0x2f800fac);
PROVIDE(ppSearchTxQueue = 0x2f800fb0);
PROVIDE(ppSearchTxframe = 0x2f800fb4);
PROVIDE(ppSelectNextQueue = 0x2f800fb8);
PROVIDE(ppSubFromAMPDU = 0x2f800fbc);
PROVIDE(ppTask = 0x2f800fc0);
PROVIDE(ppTxPkt = 0x2f800fc4);
PROVIDE(ppTxProtoProc = 0x2f800fc8);
PROVIDE(ppTxqUpdateBitmap = 0x2f800fcc);
PROVIDE(pp_coex_tx_request = 0x2f800fd0);
PROVIDE(pp_hdrsize = 0x2f800fd4);
PROVIDE(pp_post = 0x2f800fd8);
PROVIDE(pp_process_hmac_waiting_txq = 0x2f800fdc);
PROVIDE(ppDequeueTxDone_Locked = 0x2f800fe0);
PROVIDE(ppProcTxDone = 0x2f800fe4);
PROVIDE(ppMapWaitTxq = 0x2f800fe8);
PROVIDE(ppProcessWaitingQueue = 0x2f800fec);
PROVIDE(ppDisableQueue = 0x2f800ff0);
PROVIDE(ppCheckTxRTS = 0x2f800ff4);
PROVIDE(ppProcessLifeTime = 0x2f800ff8);
PROVIDE(ppProcTxCallback = 0x2f800ffc);
PROVIDE(ppCalPreFecPaddingFactor = 0x2f801000);
PROVIDE(ppCalDeliNum = 0x2f801004);
PROVIDE(ppRemoveHTC = 0x2f801008);
PROVIDE(ppCheckTxHEAMPDUlength = 0x2f80100c);
PROVIDE(ppCertSetRate = 0x2f801010);
PROVIDE(ppSelectTxFormat = 0x2f801014);
PROVIDE(ppCalTxHEAMPDULength = 0x2f801018);
PROVIDE(pp_coex_tx_release = 0x2f80101c);
PROVIDE(ppAdd2AMPDUTail = 0x2f801020);
PROVIDE(ppDirectRecycleAmpdu = 0x2f801024);
PROVIDE(ppRegressAmpdu = 0x2f801028);
PROVIDE(pp_timer_do_process = 0x2f80102c);
PROVIDE(rcGetAmpduSched = 0x2f801030);
PROVIDE(rcUpdateRxDone = 0x2f801034);
PROVIDE(rc_get_trc = 0x2f801038);
PROVIDE(rc_get_trc_by_index = 0x2f80103c);
PROVIDE(rcAmpduLowerRate = 0x2f801040);
PROVIDE(rcampduuprate = 0x2f801044);
PROVIDE(rcClearCurAMPDUSched = 0x2f801048);
PROVIDE(rcClearCurSched = 0x2f80104c);
PROVIDE(rcClearCurStat = 0x2f801050);
PROVIDE(rcGetSched = 0x2f801054);
PROVIDE(rcLowerSched = 0x2f801058);
PROVIDE(rcSetTxAmpduLimit = 0x2f80105c);
PROVIDE(rcTxUpdatePer = 0x2f801060);
PROVIDE(rcUpdateAckSnr = 0x2f801064);
PROVIDE(rcUpdateRate = 0x2f801068);
PROVIDE(rcUpdateTxDone = 0x2f80106c);
PROVIDE(rcUpdateTxDoneAmpdu2 = 0x2f801070);
PROVIDE(rcUpSched = 0x2f801074);
PROVIDE(rcReachRetryLimit = 0x2f801078);
PROVIDE(rcGetDCMMaxRate = 0x2f80107c);
PROVIDE(rcGetSMPDURate = 0x2f801080);
PROVIDE(rcGetRate = 0x2f801084);
PROVIDE(rx11AXRate2AMPDULimit = 0x2f801088);
PROVIDE(rx11NRate2AMPDULimit = 0x2f80108c);
PROVIDE(rssi_margin = 0x2f801090);
PROVIDE(TRC_AMPDU_PER_DOWN_THRESHOLD = 0x2f801094);
PROVIDE(TRC_AMPDU_PER_UP_THRESHOLD = 0x2f801098);
PROVIDE(TRC_PER_IS_GOOD = 0x2f80109c);
PROVIDE(trc_calc_duration = 0x2f8010a0);
PROVIDE(trc_isTxAmpduOperational = 0x2f8010a4);
PROVIDE(trc_onAmpduOp = 0x2f8010a8);
PROVIDE(trc_SetTxAmpduState = 0x2f8010ac);
PROVIDE(trc_tid_isTxAmpduOperational = 0x2f8010b0);
PROVIDE(trcAmpduSetState = 0x2f8010b4);
PROVIDE(trc_set_bf_report_rate = 0x2f8010b8);
PROVIDE(trc_onPPTxDone = 0x2f8010bc);
PROVIDE(wDevCheckBlockError = 0x2f8010c0);
PROVIDE(wDev_AppendRxBlocks = 0x2f8010c4);
PROVIDE(wDev_DiscardFrame = 0x2f8010c8);
PROVIDE(wDev_GetNoiseFloor = 0x2f8010cc);
PROVIDE(wDev_IndicateAmpdu = 0x2f8010d0);
PROVIDE(wDev_IndicateFrame = 0x2f8010d4);
PROVIDE(wdev_mac_reg_load = 0x2f8010d8);
PROVIDE(wdev_mac_reg_store = 0x2f8010dc);
PROVIDE(wdev_mac_special_reg_load = 0x2f8010e0);
PROVIDE(wdev_mac_special_reg_store = 0x2f8010e4);
PROVIDE(wdev_mac_wakeup = 0x2f8010e8);
PROVIDE(wdev_mac_sleep = 0x2f8010ec);
PROVIDE(wDev_ProcessFiq = 0x2f8010f0);
PROVIDE(wDev_ProcessRxSucData = 0x2f8010f4);
PROVIDE(wdevProcessRxSucDataAll = 0x2f8010f8);
PROVIDE(wdev_csi_len_align = 0x2f8010fc);
PROVIDE(wDev_IndicateBeaconMemoryFrame = 0x2f801100);
PROVIDE(wDev_ProcessBeaconMemoryRxSuc = 0x2f801104);
PROVIDE(wdevProcessModemStateRxBeacon = 0x2f801108);
PROVIDE(wdev_is_data_in_rxlist = 0x2f80110c);
PROVIDE(wdev_process_tbtt = 0x2f801110);
PROVIDE(wdev_process_tsf_timer = 0x2f801114);
PROVIDE(wdev_process_beacon_filter = 0x2f801118);
PROVIDE(wdev_process_mac_modem_beacon_miss = 0x2f80111c);
PROVIDE(config_is_cache_tx_buf_enabled = 0x2f801120);
PROVIDE(esp_test_disable_tx_statistics = 0x2f801124);
PROVIDE(esp_test_enable_tx_statistics = 0x2f801128);
PROVIDE(esp_test_clr_tx_statistics = 0x2f80112c);
PROVIDE(esp_test_get_tx_statistics = 0x2f801130);
PROVIDE(esp_test_clr_tx_tb_statistics = 0x2f801134);
PROVIDE(esp_test_get_tx_tb_statistics = 0x2f801138);
PROVIDE(esp_test_tx_process_complete = 0x2f80113c);
PROVIDE(esp_test_tx_process_txq_state = 0x2f801140);
PROVIDE(esp_test_tx_enab_statistics = 0x2f801144);
PROVIDE(esp_test_tx_tb_complete = 0x2f801148);
PROVIDE(esp_test_tx_count_retry = 0x2f80114c);
PROVIDE(esp_test_tx_count_collision = 0x2f801150);
PROVIDE(esp_test_tx_count_timeout = 0x2f801154);
PROVIDE(esp_test_rx_process_complete = 0x2f801158);
PROVIDE(esp_test_clr_rx_statistics = 0x2f80115c);
PROVIDE(esp_test_get_rx_statistics = 0x2f801160);
PROVIDE(esp_test_set_rx_error_occurs = 0x2f801164);
PROVIDE(esp_test_get_rx_error_occurs = 0x2f801168);
PROVIDE(esp_test_clr_rx_error_occurs = 0x2f80116c);
PROVIDE(esp_test_disable_rx_statistics = 0x2f801170);
PROVIDE(esp_test_enable_rx_statistics = 0x2f801174);
PROVIDE(esp_test_rx_parse_mu = 0x2f801178);
PROVIDE(esp_test_get_rx_mu_statistics = 0x2f80117c);
PROVIDE(esp_test_clr_rx_mu_statistics = 0x2f801180);
PROVIDE(esp_test_enable_rx_mu_statistics = 0x2f801184);
PROVIDE(esp_test_disable_rx_mu_statistics = 0x2f801188);
PROVIDE(test_tx_fail_statistics = 0x2f80118c);
PROVIDE(test_tx_succ_statistics = 0x2f801190);
PROVIDE(test_rx_process_complete_noeb = 0x2f801194);
PROVIDE(test_rx_process_complete_retry = 0x2f801198);
PROVIDE(test_mumimo_get_heltf_num = 0x2f80119c);
PROVIDE(test_mimo_update_user_info = 0x2f8011a0);
PROVIDE(test_parse_rx_mu_mimo = 0x2f8011a4);
PROVIDE(test_nonmimo_update_user_info = 0x2f8011a8);
PROVIDE(test_rx_parse_mumimo_complete_sigb = 0x2f8011ac);
PROVIDE(test_get_nonmumimo_common = 0x2f8011b0);
PROVIDE(test_rx_parse_nonmumimo_complete_sigb = 0x2f8011b4);
PROVIDE(test_rx_parse_nonmumimo = 0x2f8011b8);
PROVIDE(wifi_he_get_hetb_tid_bitmap = 0x2f8011bc);
PROVIDE(wifi_he_get_hetb_tid_bawin = 0x2f8011c0);
PROVIDE(ht_get_min_subframe_len = 0x2f8011c4);
PROVIDE(he_get_min_subframe_len = 0x2f8011c8);
PROVIDE(he_get_min_subframe_len_dcm = 0x2f8011cc);
PROVIDE(is_ndpa_to_dut = 0x2f8011d0);
PROVIDE(is_use_muedca = 0x2f8011d4);
PROVIDE(pwr_hal_clear_mac_modem_state_wakeup_protect_signal = 0x2f8011d8);
PROVIDE(get_estimated_batime = 0x2f8011dc);
PROVIDE(get_sublen_offset = 0x2f8011e0);
PROVIDE(pm_beacon_add_total_counter = 0x2f8011e4);
PROVIDE(pm_coex_recalculate_wifi_time_slice = 0x2f8011e8);
PROVIDE(pm_mac_modem_tsf_tbtt_auto_period_enable_update = 0x2f8011ec);
PROVIDE(our_instances_ptr = 0x2f84ffe0);
PROVIDE(g_wdev_last_desc_reset_ptr = 0x2f84ffdc);
PROVIDE(our_controls_ptr = 0x2f84ffd8);
PROVIDE(sigb_ru_allocation_user_num = 0x2f84ffc8);
PROVIDE(sigb_common_ru_allocation = 0x2f84ff38);
PROVIDE(mu_mimo_special_cfg_user_num_2 = 0x2f84fee8);
PROVIDE(mu_mimo_special_cfg_user_num_3 = 0x2f84fe80);
PROVIDE(mu_mimo_special_cfg_user_num_4 = 0x2f84fe28);
PROVIDE(mu_mimo_special_cfg_user_num_5 = 0x2f84fdf0);
PROVIDE(mu_mimo_special_cfg_user_num_6 = 0x2f84fdd0);
PROVIDE(mu_mimo_special_cfg_user_num_7 = 0x2f84fdc0);
PROVIDE(mu_mimo_special_cfg_user_num_8 = 0x2f84fdb8);
PROVIDE(he_max_apep_length = 0x2f84fd40);
PROVIDE(esp_rom_newlib_init_common_mutexes = 0x2f8004bc);
PROVIDE(memset = 0x2f8004c0);
PROVIDE(memcpy = 0x2f8004c4);
PROVIDE(memmove = 0x2f8004c8);
PROVIDE(memcmp = 0x2f8004cc);
PROVIDE(strcpy = 0x2f8004d0);
PROVIDE(strncpy = 0x2f8004d4);
PROVIDE(strcmp = 0x2f8004d8);
PROVIDE(strncmp = 0x2f8004dc);
PROVIDE(strlen = 0x2f8004e0);
PROVIDE(strstr = 0x2f8004e4);
PROVIDE(bzero = 0x2f8004e8);
PROVIDE(sbrk = 0x2f8004ec);
PROVIDE(isalnum = 0x2f8004f0);
PROVIDE(isalpha = 0x2f8004f4);
PROVIDE(isascii = 0x2f8004f8);
PROVIDE(isblank = 0x2f8004fc);
PROVIDE(iscntrl = 0x2f800500);
PROVIDE(isdigit = 0x2f800504);
PROVIDE(islower = 0x2f800508);
PROVIDE(isgraph = 0x2f80050c);
PROVIDE(isprint = 0x2f800510);
PROVIDE(ispunct = 0x2f800514);
PROVIDE(isspace = 0x2f800518);
PROVIDE(isupper = 0x2f80051c);
PROVIDE(toupper = 0x2f800520);
PROVIDE(tolower = 0x2f800524);
PROVIDE(toascii = 0x2f800528);
PROVIDE(memccpy = 0x2f80052c);
PROVIDE(memchr = 0x2f800530);
PROVIDE(memrchr = 0x2f800534);
PROVIDE(strcasecmp = 0x2f800538);
PROVIDE(strcasestr = 0x2f80053c);
PROVIDE(strcat = 0x2f800540);
PROVIDE(strchr = 0x2f800544);
PROVIDE(strcspn = 0x2f800548);
PROVIDE(strcoll = 0x2f80054c);
PROVIDE(strlcat = 0x2f800550);
PROVIDE(strlcpy = 0x2f800554);
PROVIDE(strlwr = 0x2f800558);
PROVIDE(strncasecmp = 0x2f80055c);
PROVIDE(strncat = 0x2f800560);
PROVIDE(strnlen = 0x2f800564);
PROVIDE(strrchr = 0x2f800568);
PROVIDE(strsep = 0x2f80056c);
PROVIDE(strspn = 0x2f800570);
PROVIDE(strtok_r = 0x2f800574);
PROVIDE(strupr = 0x2f800578);
PROVIDE(longjmp = 0x2f80057c);
PROVIDE(setjmp = 0x2f800580);
PROVIDE(abs = 0x2f800584);
PROVIDE(div = 0x2f800588);
PROVIDE(labs = 0x2f80058c);
PROVIDE(ldiv = 0x2f800590);
PROVIDE(qsort = 0x2f800594);
PROVIDE(utoa = 0x2f800598);
PROVIDE(itoa = 0x2f80059c);
PROVIDE(rom_systimer_hal_init = 0x2f800394);
PROVIDE(rom_systimer_hal_deinit = 0x2f800398);
PROVIDE(systimer_hal_set_tick_rate_ops = 0x2f80039c);
PROVIDE(systimer_hal_get_counter_value = 0x2f8003a0);
PROVIDE(systimer_hal_get_time = 0x2f8003a4);
PROVIDE(systimer_hal_set_alarm_target = 0x2f8003a8);
PROVIDE(systimer_hal_set_alarm_period = 0x2f8003ac);
PROVIDE(systimer_hal_get_alarm_value = 0x2f8003b0);
PROVIDE(systimer_hal_enable_alarm_int = 0x2f8003b4);
PROVIDE(systimer_hal_on_apb_freq_update = 0x2f8003b8);
PROVIDE(systimer_hal_counter_value_advance = 0x2f8003bc);
PROVIDE(systimer_hal_enable_counter = 0x2f8003c0);
PROVIDE(systimer_hal_select_alarm_mode = 0x2f8003c4);
PROVIDE(systimer_hal_connect_alarm_counter = 0x2f8003c8);
PROVIDE(systimer_hal_counter_can_stall_by_cpu = 0x2f8003cc);
PROVIDE(rom_wdt_hal_init = 0x2f800368);
PROVIDE(rom_wdt_hal_deinit = 0x2f80036c);
PROVIDE(rom_wdt_hal_config_stage = 0x2f800370);
PROVIDE(wdt_hal_write_protect_disable = 0x2f800374);
PROVIDE(wdt_hal_write_protect_enable = 0x2f800378);
PROVIDE(wdt_hal_enable = 0x2f80037c);
PROVIDE(wdt_hal_disable = 0x2f800380);
PROVIDE(wdt_hal_handle_intr = 0x2f800384);
PROVIDE(wdt_hal_feed = 0x2f800388);
PROVIDE(wdt_hal_set_flashboot_en = 0x2f80038c);
PROVIDE(wdt_hal_is_enabled = 0x2f800390);


/* **esp-idf 链接符号**（esp_wifi/wpa 归档引用）：由我们的布局定义 */
_iram_start = ORIGIN(sram) + 0x800;
_iram_end = ORIGIN(sram) + 0x10930;
_rtc_reserved_start = 0x2F022140;
_rtc_reserved_end = 0x2F022940;
_thread_local_data_start = 0;
_thread_local_data_end = 0;
_thread_local_bss_start = 0;
_thread_local_bss_end = 0;
_rtc_force_slow_end = 0;
