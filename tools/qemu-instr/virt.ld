/* tools/qemu-instr：给 QEMU `virt` 机器（riscv32，`-bios none -kernel <elf>`）用的链接脚本。
   RAM 从 0x80000000 起；入口 `_start` 放在最前面；栈单独留 1 MiB（不占镜像）。
   只用于数指令：栈远大于板子的 16 KiB，所以这里不反映板上的栈深度（那是另一回事，见
   docs/TESTING.md「板侧自检的两条隐性预算」）。 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    .data : {
        *(.sdata .sdata.*)
        *(.data .data.*)
    }

    .bss : {
        . = ALIGN(8);
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    .stack (NOLOAD) : {
        . = ALIGN(16);
        . = . + 0x100000;
        __stack_top = .;
    }

    /DISCARD/ : {
        *(.eh_frame .eh_frame_hdr)
        *(.note .note.*)
        *(.riscv.attributes)
        *(.comment)
    }
}
