/*
 * freertos_risc_v_chip_specific_extensions.h
 *
 * RV32IM SoC (Nexys Video) — no FPU, no custom CSRs.
 * 추가 레지스터 저장/복원 불필요.
 */

#ifndef __FREERTOS_RISC_V_EXTENSIONS_H__
#define __FREERTOS_RISC_V_EXTENSIONS_H__

#define portasmHAS_SIFIVE_CLINT         0
#define portasmHAS_MTIME                1
#define portasmADDITIONAL_CONTEXT_SIZE  0

.macro portasmSAVE_ADDITIONAL_REGISTERS
    /* RV32IM: 추가 레지스터 없음 */
.endm

.macro portasmRESTORE_ADDITIONAL_REGISTERS
    /* RV32IM: 추가 레지스터 없음 */
.endm

#endif /* __FREERTOS_RISC_V_EXTENSIONS_H__ */
