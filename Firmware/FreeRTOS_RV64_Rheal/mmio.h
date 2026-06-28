#ifndef MMIO_H
#define MMIO_H

#include <stdint.h>

// ============================================================================
// SoC Memory Map
// ============================================================================

// CLINT (Machine Timer)
// RTL (XLEN=64): mtime/mtimecmp는 각각 단일 64-bit 주소로 접근.
//   0x02000000: mtime    (64-bit R/W)
//   0x02000008: mtimecmp (64-bit R/W)
// RV32 시절의 HI/LO 분리 접근(0x04, 0x0C)은 RTL에서 제거됨.
#define CLINT_BASE          0x02000000UL
#define CLINT_MTIME         (*(volatile uint64_t *)(CLINT_BASE + 0x00))
#define CLINT_MTIMECMP      (*(volatile uint64_t *)(CLINT_BASE + 0x08))

// UART
#define UART_TX_DATA        (*(volatile uint32_t *)0x10010000UL)
#define UART_STATUS         (*(volatile uint32_t *)0x10010004UL)
#define UART_BUSY           (UART_STATUS & 1)

// VRAM (80x30 text-mode display)
#define VRAM_BASE           ((volatile uint8_t *)0x10020000UL)
#define VRAM_COLS           80
#define VRAM_ROWS           30

// PS/2 Keyboard
#define KB_SCANCODE         (*(volatile uint32_t *)0x10030000UL)
#define KB_STATUS           (*(volatile uint32_t *)0x10030004UL)
#define KB_NEW_DATA         (KB_STATUS & 1)

// ============================================================================
// Display Helpers
// ============================================================================

static inline void vram_putc(int row, int col, char c) {
    VRAM_BASE[row * VRAM_COLS + col] = (uint8_t)c;
}

static inline void vram_puts(int row, int col, const char *s) {
    while (*s) {
        vram_putc(row, col++, *s++);
    }
}

static inline void vram_clear(void) {
    for (int i = 0; i < VRAM_COLS * VRAM_ROWS; i++)
        VRAM_BASE[i] = 0x20;
}

// ============================================================================
// PS/2 Set 2 Scancode → ASCII
// ============================================================================

static inline char scancode_to_ascii(uint8_t sc) {
    switch (sc) {
        case 0x1C: return 'A';  case 0x32: return 'B';
        case 0x21: return 'C';  case 0x23: return 'D';
        case 0x24: return 'E';  case 0x2B: return 'F';
        case 0x34: return 'G';  case 0x33: return 'H';
        case 0x43: return 'I';  case 0x3B: return 'J';
        case 0x42: return 'K';  case 0x4B: return 'L';
        case 0x3A: return 'M';  case 0x31: return 'N';
        case 0x44: return 'O';  case 0x4D: return 'P';
        case 0x15: return 'Q';  case 0x2D: return 'R';
        case 0x1B: return 'S';  case 0x2C: return 'T';
        case 0x3C: return 'U';  case 0x2A: return 'V';
        case 0x1D: return 'W';  case 0x22: return 'X';
        case 0x35: return 'Y';  case 0x1A: return 'Z';
        case 0x45: return '0';  case 0x16: return '1';
        case 0x1E: return '2';  case 0x26: return '3';
        case 0x25: return '4';  case 0x2E: return '5';
        case 0x36: return '6';  case 0x3D: return '7';
        case 0x3E: return '8';  case 0x46: return '9';
        case 0x29: return ' ';
        case 0x5A: return '\n';
        case 0x66: return '\b';
        default:   return 0;
    }
}

#endif // MMIO_H
