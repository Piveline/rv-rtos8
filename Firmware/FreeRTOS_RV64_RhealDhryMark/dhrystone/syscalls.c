/*
 * syscalls.c - minimal BSP support for RV64I
 *
 * 목표:
 *  - Dhrystone 2.1 소스(dhry_1.c/dhry_2.c/dhry.h) 수정 없이 빌드
 *  - newlib(libc) 전체를 링크하지 않아서 ROM 안에 들어가게 만들기
 *
 * 제공:
 *  - UART 출력 (mini_libc.c의 printf/puts/putchar가 사용)
 *  - times() : -DTIMES 측정용 (tick = cycle)
 *
 * 주의:
 *  - crt0.S에 _exit가 이미 있으므로 여기서는 _exit를 정의하지 않는다.
 */

#include <stdint.h>
#include <sys/times.h>

/* ============================================================
 * Shell output hook
 * ============================================================ */
extern void shell_putchar(char c);

/* ============================================================
 * Clock / HZ
 * ============================================================ */
#ifndef HZ
#define HZ 50000000UL
#endif

/* ============================================================
 * CSR read helper for mcycle
 * On RV64, mcycle is a full 64-bit register
 * ============================================================ */
static inline uint64_t csr_read_mcycle(void) {
    uint64_t v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

/* ============================================================
 * Output
 * ============================================================ */
void uart_putchar(char c) {
    shell_putchar(c);
}

void uart_puts(const char *s) {
    while (*s) {
        shell_putchar(*s++);
    }
}

/* ============================================================
 * times() - K&R style (no prototype) to match Dhrystone
 * tick = cycle, and HZ should be set to CPU frequency.
 *
 * NOTE: return type is int because Dhrystone declares `extern int times();`
 * ============================================================ */
int times(buf)
struct tms *buf;
{
    uint64_t cycles = csr_read_mcycle();
    long ticks = (long)cycles;

    if (buf) {
        buf->tms_utime  = ticks;
        buf->tms_stime  = 0;
        buf->tms_cutime = 0;
        buf->tms_cstime = 0;
    }

    return (int)ticks;
}
