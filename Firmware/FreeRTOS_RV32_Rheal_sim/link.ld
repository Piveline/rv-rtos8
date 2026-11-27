/* ============================================================================
 * link.ld — FreeRTOS Linker Script for RV32IM SoC
 * ============================================================================
 * ROM (Instruction Memory): 0x0000_0000, 32KB
 * RAM (Data Memory):        0x1000_0000, 32KB
 *
 * 주의: --gc-sections 사용 시 FreeRTOS trap handler가
 *       제거될 수 있으므로 Makefile에 -Wl,-u,freertos_risc_v_trap_handler 필수
 * ========================================================================= */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 32K
}

SECTIONS
{
    /* --- Code --- */
    .text : {
        *(.text.init)
        *(.text .text.*)
        . = ALIGN(4);
    } > ROM

    /* --- Read-only data --- */
    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > ROM

    /* --- Initialized data (LMA in ROM, VMA in RAM) --- */
    _data_load = LOADADDR(.data);
    .data : ALIGN(4) {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > RAM AT > ROM

    /* --- BSS (zero-initialized) --- */
    .bss (NOLOAD) : ALIGN(4) {
        __global_pointer$ = . + 0x800;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /* 사용량 확인용 */
    _heap_start = _bss_end;
    _heap_end = _stack_top - 2048;  /* 최소 2KB 스택 보호 */
}
