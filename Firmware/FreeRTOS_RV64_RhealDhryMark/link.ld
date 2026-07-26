/* ============================================================================
 * link.ld — FreeRTOS Linker Script for RV64IM SoC
 * ============================================================================
 * ROM (Instruction Memory): 0x0000_0000, 64KB
 * RAM (Data Memory):        0x1000_0000, 32KB
 *
 * [RV32→RV64] 변경 사항:
 *   - ALIGN 4 → 8 : lp64 ABI는 8-byte 정렬 요구.
 *                   uint64_t / 포인터(8B)가 섹션 경계에서 misalign되지 않도록.
 *   - .text는 ALIGN(4) 유지 : 명령어 정렬은 4-byte 그대로.
 *   - ORIGIN / LENGTH : 메모리 맵 변경 없음.
 *
 * 주의: --gc-sections 사용 시 FreeRTOS trap handler가
 *       제거될 수 있으므로 Makefile에 -Wl,-u,freertos_risc_v_trap_handler 필수
 * ========================================================================= */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 64K
}

SECTIONS
{
    /* --- Code --- */
    .text : {
        *(.text.init)
        *(.text .text.*)
        . = ALIGN(4);           /* 명령어는 4-byte 정렬 유지 */
    } > ROM

    /* --- Read-only data --- */
    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(8);
    } > ROM

    /* --- Initialized data (LMA in ROM, VMA in RAM) --- */
    _data_load = LOADADDR(.data);
    .data : ALIGN(8) {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
        _data_end = .;
    } > RAM AT > ROM

    /* --- BSS (zero-initialized) --- */
    .bss (NOLOAD) : ALIGN(8) {
        __global_pointer$ = . + 0x800;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        _bss_end = .;
    } > RAM

    /* 스택: RAM 끝. RISC-V ABI는 16-byte 스택 정렬 요구.
     * ORIGIN(RAM)+LENGTH(RAM) = 0x10008000 → 16-byte 정렬 만족. */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /* 사용량 확인용 */
    _heap_start = _bss_end;
    _heap_end = _stack_top - 2048;  /* 최소 2KB 스택 보호 */
}
