// ============================================================================
// nosys.c — Minimal libc replacements for -nostdlib build
// ============================================================================
// FreeRTOS 커널이 내부적으로 memset, memcpy, memcmp를 사용함.
// -nostdlib에서는 이들이 링크되지 않으므로 직접 구현.
// ============================================================================

#include <stdint.h>
#include <stddef.h>

void *memset(void *s, int c, size_t n) {
    uint8_t *p = (uint8_t *)s;
    while (n--) *p++ = (uint8_t)c;
    return s;
}

void *memcpy(void *dest, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;
    while (n--) *d++ = *s++;
    return dest;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const uint8_t *a = (const uint8_t *)s1;
    const uint8_t *b = (const uint8_t *)s2;
    while (n--) {
        if (*a != *b) return *a - *b;
        a++; b++;
    }
    return 0;
}
