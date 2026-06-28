# ============================================================================
# crt0.S — FreeRTOS Bare-metal Startup for RV32IM SoC
# ============================================================================
#
# RV32IM / FreeRTOS / -nostdlib startup
#
# 핵심:
#   - .option norelax 필수
#   - sp 설정
#   - gp 설정
#   - mtvec를 FreeRTOS trap handler로 설정
#   - .data: ROM -> RAM 복사
#   - .bss : RAM 영역 0으로 초기화
#   - main() 진입
#
# ============================================================================

.option norelax

.section .text.init, "ax"
.global _start
.align 2

.extern main
.extern freertos_risc_v_trap_handler

_start:
    # ------------------------------------------------------------------------
    # 인터럽트 비활성화
    # ------------------------------------------------------------------------
    csrci   mstatus, 0x8           # MIE = 0

    # ------------------------------------------------------------------------
    # Stack Pointer 설정
    # ------------------------------------------------------------------------
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    # ------------------------------------------------------------------------
    # Global Pointer 설정
    # 주의: .option norelax 필요
    # ------------------------------------------------------------------------
    lui     gp, %hi(__global_pointer$)
    addi    gp, gp, %lo(__global_pointer$)

    # ------------------------------------------------------------------------
    # mtvec ← FreeRTOS trap handler
    # ------------------------------------------------------------------------
    lui     t0, %hi(freertos_risc_v_trap_handler)
    addi    t0, t0, %lo(freertos_risc_v_trap_handler)
    csrw    mtvec, t0

    # ------------------------------------------------------------------------
    # .data 영역 초기화
    #
    # link.ld 기준:
    #   _data_load  : ROM에 있는 .data 초기값 위치, LMA
    #   _data_start : RAM에 배치될 .data 시작 주소, VMA
    #   _data_end   : RAM에 배치될 .data 끝 주소
    # ------------------------------------------------------------------------
    lui     t0, %hi(_data_load)
    addi    t0, t0, %lo(_data_load)      # t0 = source, ROM

    lui     t1, %hi(_data_start)
    addi    t1, t1, %lo(_data_start)     # t1 = destination, RAM

    lui     t2, %hi(_data_end)
    addi    t2, t2, %lo(_data_end)       # t2 = end of .data

data_loop:
    bgeu    t1, t2, data_done
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       data_loop

data_done:

    # ------------------------------------------------------------------------
    # .bss 영역 0으로 초기화
    # ------------------------------------------------------------------------
    lui     t0, %hi(_bss_start)
    addi    t0, t0, %lo(_bss_start)

    lui     t1, %hi(_bss_end)
    addi    t1, t1, %lo(_bss_end)

bss_loop:
    bgeu    t0, t1, bss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       bss_loop

bss_done:

    # ------------------------------------------------------------------------
    # main() 호출
    # ------------------------------------------------------------------------
    jal     ra, main

    # ------------------------------------------------------------------------
    # main 반환 시 무한 루프
    # ------------------------------------------------------------------------
halt:
    j       halt

    # ------------------------------------------------------------------------
    # --gc-sections가 trap handler를 제거하지 못하도록 심볼 유지
    # Makefile의 -Wl,-u,freertos_risc_v_trap_handler와 함께 사용
    # ------------------------------------------------------------------------
.global freertos_risc_v_trap_handler