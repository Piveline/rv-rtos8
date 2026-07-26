/*
 * ee_printf.c - printf implementation for CoreMark on RV32I46F_5SP
 *
 * Based on EEMBC barebones/ee_printf.c
 * Modified for RV32I with no floating point support (HAS_FLOAT=0)
 *
 * UART MMIO:
 *   TX Data:   0x10010000 (write)
 *   TX Status: 0x10010004 (read, bit 0 = busy)
 */

#include "coremark.h"
#include <stdarg.h>

/* ============================================================
 * Shell output hook
 * ============================================================ */
extern void shell_putchar(char c);

void uart_send_char(char c)
{
    shell_putchar(c);
}

/* ============================================================
 * Printf Implementation
 * ============================================================ */

#define ZEROPAD   (1 << 0) /* Pad with zero */
#define SIGN      (1 << 1) /* Unsigned/signed long */
#define PLUS      (1 << 2) /* Show plus */
#define SPACE     (1 << 3) /* Spacer */
#define LEFT      (1 << 4) /* Left justified */
#define HEX_PREP  (1 << 5) /* 0x */
#define UPPERCASE (1 << 6) /* 'ABCDEF' */

#define is_digit(c) ((c) >= '0' && (c) <= '9')

static char *digits       = "0123456789abcdefghijklmnopqrstuvwxyz";
static char *upper_digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

static ee_size_t
ee_strnlen(const char *s, ee_size_t count)
{
    const char *sc;
    for (sc = s; *sc != '\0' && count--; ++sc)
        ;
    return sc - s;
}

static int
skip_atoi(const char **s)
{
    int i = 0;
    while (is_digit(**s))
        i = i * 10 + *((*s)++) - '0';
    return i;
}

static char *
number(char *str, long num, int base, int size, int precision, int type)
{
    char  c, sign, tmp[66];
    char *dig = digits;
    int   i;

    if (type & UPPERCASE)
        dig = upper_digits;
    if (type & LEFT)
        type &= ~ZEROPAD;
    if (base < 2 || base > 36)
        return 0;

    c    = (type & ZEROPAD) ? '0' : ' ';
    sign = 0;
    if (type & SIGN)
    {
        if (num < 0)
        {
            sign = '-';
            num  = -num;
            size--;
        }
        else if (type & PLUS)
        {
            sign = '+';
            size--;
        }
        else if (type & SPACE)
        {
            sign = ' ';
            size--;
        }
    }

    if (type & HEX_PREP)
    {
        if (base == 16)
            size -= 2;
        else if (base == 8)
            size--;
    }

    i = 0;

    if (num == 0)
        tmp[i++] = '0';
    else
    {
        while (num != 0)
        {
            tmp[i++] = dig[((unsigned long)num) % (unsigned)base];
            num      = ((unsigned long)num) / (unsigned)base;
        }
    }

    if (i > precision)
        precision = i;
    size -= precision;
    if (!(type & (ZEROPAD | LEFT)))
        while (size-- > 0)
            *str++ = ' ';
    if (sign)
        *str++ = sign;

    if (type & HEX_PREP)
    {
        if (base == 8)
            *str++ = '0';
        else if (base == 16)
        {
            *str++ = '0';
            *str++ = digits[33]; /* 'x' */
        }
    }

    if (!(type & LEFT))
        while (size-- > 0)
            *str++ = c;
    while (i < precision--)
        *str++ = '0';
    while (i-- > 0)
        *str++ = tmp[i];
    while (size-- > 0)
        *str++ = ' ';

    return str;
}

static int
ee_vsprintf(char *buf, const char *fmt, va_list args)
{
    int           len;
    unsigned long num;
    int           i, base;
    char         *str;
    char         *s;

    int flags;       /* Flags to number() */
    int field_width; /* Width of output field */
    int precision;   /* Min. # of digits for integers; max chars for string */
    int qualifier;   /* 'h', 'l', or 'L' for integer fields */

    for (str = buf; *fmt; fmt++)
    {
        if (*fmt != '%')
        {
            *str++ = *fmt;
            continue;
        }

        /* Process flags */
        flags = 0;
    repeat:
        fmt++; /* This also skips first '%' */
        switch (*fmt)
        {
            case '-':
                flags |= LEFT;
                goto repeat;
            case '+':
                flags |= PLUS;
                goto repeat;
            case ' ':
                flags |= SPACE;
                goto repeat;
            case '#':
                flags |= HEX_PREP;
                goto repeat;
            case '0':
                flags |= ZEROPAD;
                goto repeat;
        }

        /* Get field width */
        field_width = -1;
        if (is_digit(*fmt))
            field_width = skip_atoi(&fmt);
        else if (*fmt == '*')
        {
            fmt++;
            field_width = va_arg(args, int);
            if (field_width < 0)
            {
                field_width = -field_width;
                flags |= LEFT;
            }
        }

        /* Get the precision */
        precision = -1;
        if (*fmt == '.')
        {
            ++fmt;
            if (is_digit(*fmt))
                precision = skip_atoi(&fmt);
            else if (*fmt == '*')
            {
                ++fmt;
                precision = va_arg(args, int);
            }
            if (precision < 0)
                precision = 0;
        }

        /* Get the conversion qualifier */
        qualifier = -1;
        if (*fmt == 'l' || *fmt == 'L')
        {
            qualifier = *fmt;
            fmt++;
        }

        /* Default base */
        base = 10;

        switch (*fmt)
        {
            case 'c':
                if (!(flags & LEFT))
                    while (--field_width > 0)
                        *str++ = ' ';
                *str++ = (unsigned char)va_arg(args, int);
                while (--field_width > 0)
                    *str++ = ' ';
                continue;

            case 's':
                s = va_arg(args, char *);
                if (!s)
                    s = "<NULL>";
                len = ee_strnlen(s, precision);
                if (!(flags & LEFT))
                    while (len < field_width--)
                        *str++ = ' ';
                for (i = 0; i < len; ++i)
                    *str++ = *s++;
                while (len < field_width--)
                    *str++ = ' ';
                continue;

            case 'p':
                if (field_width == -1)
                {
                    field_width = 2 * sizeof(void *);
                    flags |= ZEROPAD;
                }
                str = number(str,
                             (unsigned long)va_arg(args, void *),
                             16,
                             field_width,
                             precision,
                             flags);
                continue;

            /* Integer number formats - set up the flags and "break" */
            case 'o':
                base = 8;
                break;

            case 'X':
                flags |= UPPERCASE;
                /* fall through */
            case 'x':
                base = 16;
                break;

            case 'd':
            case 'i':
                flags |= SIGN;
                /* fall through */
            case 'u':
                break;

            /* For HAS_FLOAT=0, treat %f as %d */
            case 'f':
            case 'g':
            case 'G':
            case 'e':
            case 'E':
                /* No float support - print as integer or skip */
                *str++ = '?';
                continue;

            default:
                if (*fmt != '%')
                    *str++ = '%';
                if (*fmt)
                    *str++ = *fmt;
                else
                    --fmt;
                continue;
        }

        if (qualifier == 'l')
            num = va_arg(args, unsigned long);
        else if (flags & SIGN)
            num = va_arg(args, int);
        else
            num = va_arg(args, unsigned int);

        str = number(str, num, base, field_width, precision, flags);
    }

    *str = '\0';
    return str - buf;
}

int
ee_printf(const char *fmt, ...)
{
    char    buf[256];
    char   *p;
    va_list args;
    int     n = 0;

    va_start(args, fmt);
    ee_vsprintf(buf, fmt, args);
    va_end(args);
    
    p = buf;
    while (*p)
    {
        if (*p == '\n')
        {
            uart_send_char('\r');
        }
        uart_send_char(*p);
        n++;
        p++;
    }

    return n;
}
