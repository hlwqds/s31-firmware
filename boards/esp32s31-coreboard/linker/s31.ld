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
    _stack_size = 0x4000;
    _stack_top = ORIGIN(sram) + LENGTH(sram);
    _stack_bottom = _stack_top - _stack_size;

    _heap_start = _bss_end;
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
        . = . + 0x8000;
        _bss_end_btdm = .;
    } > sram

    .btdm_data (NOLOAD) : ALIGN(16)
    {
        _data_start_btdm = .;
        . = . + 0x1000;
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
