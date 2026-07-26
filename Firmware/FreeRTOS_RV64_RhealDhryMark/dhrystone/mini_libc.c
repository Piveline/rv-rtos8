/*
 * mini_libc.c - tiny libc substitutes (enough for Dhrystone 2.1)
 *
 * 제공:
 *  - printf: %s %c %d %u %x %% (그리고 %ld/%lu/%lx 지원)
 *  - strcpy
 *  - malloc/free: bump allocator (Dhrystone는 free를 안 씀)
 *  - putchar/puts
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

/* from syscalls.c */
void uart_putchar(char c);
void uart_puts(const char *s);

/* ============================================================
 * Heap (linker.ld의 .heap 섹션 심볼 사용)
 * ============================================================ */
extern char _heap_start;
extern char _heap_end;

static uint8_t *g_brk = NULL;

void dhry_heap_reset(void) {
    g_brk = NULL;
}

static void *bump_alloc(size_t n) {
    uintptr_t cur, next, end;

    if (g_brk == NULL) {
        g_brk = (uint8_t *)&_heap_start;
    }

    cur = (uintptr_t)g_brk;
    end = (uintptr_t)&_heap_end;

    /* align 8 */
    n = (n + 7u) & ~7u;
    next = cur + (uintptr_t)n;

    if (next > end) {
        return NULL;
    }

    g_brk = (uint8_t *)next;
    return (void *)cur;
}

void *malloc(size_t n) {
    if (n == 0) {
        return NULL;
    }
    return bump_alloc(n);
}

void free(void *p) {
    (void)p;
    /* no-op (bump allocator) */
}

/* ============================================================
 * string
 * ============================================================ */
char *strcpy(char *dst, const char *src) {
    char *d = dst;
    while ((*d++ = *src++) != 0) {
        /* copy */
    }
    return dst;
}

/* ============================================================
 * basic output helpers
 * ============================================================ */
int putchar(int c) {
    uart_putchar((char)c);
    return c;
}

int puts(const char *s) {
    uart_puts(s);
    uart_putchar('\n');
    return 0;
}

static void out_char(char c) {
    uart_putchar(c);
}

static void out_str(const char *s) {
    uart_puts(s ? s : "(null)");
}

static void out_uint(unsigned long v, unsigned base, int upper) {
    char buf[32];
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int i = 0;

    if (v == 0) {
        out_char('0');
        return;
    }

    while (v && i < (int)sizeof(buf)) {
        buf[i++] = digits[v % base];
        v /= base;
    }

    while (i--) {
        out_char(buf[i]);
    }
}

static void out_int(long v) {
    if (v < 0) {
        out_char('-');
        out_uint((unsigned long)(-v), 10u, 0);
    } else {
        out_uint((unsigned long)v, 10u, 0);
    }
}

/* ============================================================
 * printf (tiny)
 * ============================================================ */
int printf(const char *fmt, ...) {
    va_list ap;
    int written = 0;

    va_start(ap, fmt);

    while (fmt && *fmt) {
        if (*fmt != '%') {
            out_char(*fmt++);
            written++;
            continue;
        }

        fmt++; /* skip % */

        /* length modifier */
        int is_long = 0;
        if (*fmt == 'l') {
            is_long = 1;
            fmt++;
        }

        char spec = *fmt ? *fmt++ : '\0';
        switch (spec) {
            case '%':
                out_char('%');
                written++;
                break;
            case 'c': {
                int c = va_arg(ap, int);
                out_char((char)c);
                written++;
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                out_str(s);
                /* written count is approximate; not critical */
                break;
            }
            case 'd':
            case 'i': {
                long v = is_long ? va_arg(ap, long) : (long)va_arg(ap, int);
                out_int(v);
                break;
            }
            case 'u': {
                unsigned long v = is_long ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
                out_uint(v, 10u, 0);
                break;
            }
            case 'x': {
                unsigned long v = is_long ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
                out_uint(v, 16u, 0);
                break;
            }
            case 'X': {
                unsigned long v = is_long ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
                out_uint(v, 16u, 1);
                break;
            }
            default:
                /* unsupported: print as-is */
                out_char('%');
                out_char(spec ? spec : '?');
                written += 2;
                break;
        }
    }

    va_end(ap);
    return written;
}
