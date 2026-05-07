#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"

// ============================================================================
// MMIO Addresses
// ============================================================================

#define UART_TX     ((volatile uint32_t *)0x10010000)
#define UART_STAT   ((volatile uint32_t *)0x10010004)
#define VRAM        ((volatile uint8_t  *)0x10020000)
#define KB_SCAN     ((volatile uint32_t *)0x10030000)
#define KB_STAT     ((volatile uint32_t *)0x10030004)
#define MTIME_LO    ((volatile uint32_t *)0x02000000)
#define MTIMECMP_LO ((volatile uint32_t *)0x02000008)

#define COLS        80
#define ROWS        30
#define SHELL_PROMPT "\nRV32> "
#define MAX_CMD_LEN  64
#define MTIME_HZ     1000UL

// ============================================================================
// UART TX (출력 전용)
// ============================================================================

static void uart_putchar(char c) {
    while (*UART_STAT & 1);     // tx_busy 대기
    *UART_TX = (uint32_t)c;
}

// ============================================================================
// VRAM Display
// ============================================================================

static int vrow = 0, vcol = 0;

static void vram_putc(char c) {
    if (c == '\n') {
        vcol = 0; vrow++;
    } else if (c == '\r') {
        vcol = 0;
    } else if (c == '\b') {
        if (vcol > 0) {
            vcol--;
            VRAM[vrow * COLS + vcol] = ' ';
        }
    } else {
        VRAM[vrow * COLS + vcol] = (uint8_t)c;
        if (++vcol >= COLS) { vcol = 0; vrow++; }
    }

    // 스크롤
    if (vrow >= ROWS) {
        for (int r = 0; r < ROWS - 1; r++)
            for (int c2 = 0; c2 < COLS; c2++)
                VRAM[r * COLS + c2] = VRAM[(r + 1) * COLS + c2];
        for (int c2 = 0; c2 < COLS; c2++)
            VRAM[(ROWS - 1) * COLS + c2] = ' ';
        vrow = ROWS - 1;
    }
}

static void vram_puts(const char *s) {
    while (*s) vram_putc(*s++);
}

// UART + VRAM 동시 출력
static void puts_all(const char *s) {
    while (*s) {
        uart_putchar(*s);
        vram_putc(*s);
        s++;
    }
}

static void vram_clear_all(void) {
    for (int i = 0; i < COLS * ROWS; i++) VRAM[i] = ' ';
    vrow = vcol = 0;
}

// ============================================================================
// PS/2 Keyboard Input (UART RX 대체)
// ============================================================================

// PS/2 Set 2 scancode → ASCII
static char scancode_to_ascii(uint8_t sc) {
    switch (sc) {
        case 0x1C: return 'a';  case 0x32: return 'b';
        case 0x21: return 'c';  case 0x23: return 'd';
        case 0x24: return 'e';  case 0x2B: return 'f';
        case 0x34: return 'g';  case 0x33: return 'h';
        case 0x43: return 'i';  case 0x3B: return 'j';
        case 0x42: return 'k';  case 0x4B: return 'l';
        case 0x3A: return 'm';  case 0x31: return 'n';
        case 0x44: return 'o';  case 0x4D: return 'p';
        case 0x15: return 'q';  case 0x2D: return 'r';
        case 0x1B: return 's';  case 0x2C: return 't';
        case 0x3C: return 'u';  case 0x2A: return 'v';
        case 0x1D: return 'w';  case 0x22: return 'x';
        case 0x35: return 'y';  case 0x1A: return 'z';
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

// Non-blocking keyboard read (returns 0 if no key)
static char kb_getchar(void) {
    static uint8_t break_flag = 0;
    static uint8_t key_down[256];

    if (!(*KB_STAT & 1))
        return 0;

    uint8_t sc = (uint8_t)(*KB_SCAN);
    *KB_STAT = 1;   // acknowledge

    if (sc == 0xF0) {
        break_flag = 1;
        return 0;
    }
    if (break_flag) {
        break_flag = 0;
        key_down[sc] = 0;
        return 0;
    }
    if (key_down[sc]) {
        key_down[sc] = 0;
        return 0;
    }

    key_down[sc] = 1;
    return scancode_to_ascii(sc);
}

// ============================================================================
// String Utilities (nostdlib)
// ============================================================================

static int my_strlen(const char *s) {
    int n = 0; while (s[n]) n++; return n;
}

static int my_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a - *b;
}

static void uint_to_dec(uint32_t val, char *buf, int bufsize) {
    int i = bufsize - 1;
    buf[i] = '\0';
    if (val == 0) {
        buf[--i] = '0';
    } else {
        while (val > 0 && i > 0) {
            buf[--i] = '0' + (val % 10);
            val /= 10;
        }
    }
    int start = i, j = 0;
    while (buf[start]) buf[j++] = buf[start++];
    buf[j] = '\0';
}

static void uint_to_hex(uint32_t val, char *buf) {
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 0; i < 8; i++) {
        buf[i] = hex[(val >> (28 - i * 4)) & 0xF];
    }
    buf[8] = '\0';
}

static uint32_t read_mstatus(void) {
    uint32_t v;
    __asm volatile ("csrr %0, mstatus" : "=r"(v));
    return v;
}

static uint32_t read_mie(void) {
    uint32_t v;
    __asm volatile ("csrr %0, mie" : "=r"(v));
    return v;
}

static uint32_t read_mip(void) {
    uint32_t v;
    __asm volatile ("csrr %0, mip" : "=r"(v));
    return v;
}

static uint32_t read_mcause(void) {
    uint32_t v;
    __asm volatile ("csrr %0, mcause" : "=r"(v));
    return v;
}

static uint32_t read_mepc(void) {
    uint32_t v;
    __asm volatile ("csrr %0, mepc" : "=r"(v));
    return v;
}

static uint32_t read_mtvec(void) {
    uint32_t v;
    __asm volatile ("csrr %0, mtvec" : "=r"(v));
    return v;
}

static void print_hex_line(const char *name, uint32_t val) {
    char buf[9];
    puts_all(name);
    puts_all(": 0x");
    uint_to_hex(val, buf);
    puts_all(buf);
    puts_all("\n");
}

// ============================================================================
// Commands
// ============================================================================

static void cmd_help(void) {
    puts_all("commands: help, clear, info, uptime, csr\n");
}

static void cmd_info(void) {
    puts_all("FreeRTOS RV32IM Shell - SMU Pipeline\n");
    puts_all("Nexys Video / Artix-7 XC7A200T\n");
    puts_all("100MHz sys / 25MHz pixel / 125MHz serial\n");
}

static void cmd_uptime(void) {
    uint32_t mtime = *MTIME_LO;
    uint32_t sec = mtime / MTIME_HZ;
    uint32_t ticks = xTaskGetTickCount();
    char buf[12];

    puts_all("mtime:  ");
    uint_to_dec(sec, buf, 12);
    puts_all(buf);
    puts_all("s\n");

    puts_all("ticks:  ");
    uint_to_dec(ticks, buf, 12);
    puts_all(buf);
    puts_all("\n");
}

static void cmd_csr(void) {
    print_hex_line("mstatus", read_mstatus());
    print_hex_line("mie",     read_mie());
    print_hex_line("mip",     read_mip());
    print_hex_line("mcause",  read_mcause());
    print_hex_line("mepc",    read_mepc());
    print_hex_line("mtvec",   read_mtvec());
    print_hex_line("mtime",   *MTIME_LO);
    print_hex_line("mtimecmp", *MTIMECMP_LO);
}

static void process_command(char *buf) {
    if (my_strlen(buf) == 0) return;

    if      (my_strcmp(buf, "help")   == 0)  cmd_help();
    else if (my_strcmp(buf, "clear")  == 0)  { vram_clear_all(); }
    else if (my_strcmp(buf, "info")   == 0)  cmd_info();
    else if (my_strcmp(buf, "uptime") == 0)  cmd_uptime();
    else if (my_strcmp(buf, "csr")    == 0)  cmd_csr();
    else {
        puts_all("unknown: ");
        puts_all(buf);
        puts_all("\n");
    }
}

// ============================================================================
// Shell Task
// ============================================================================

static void shell_poll_pause(void) {
    for (volatile uint32_t i = 0; i < 2000; i++) {
        __asm volatile ("nop");
    }
}

void Shell_Task(void *pvParameters) {
    (void)pvParameters;
    char cmd_buf[MAX_CMD_LEN];
    uint8_t cmd_idx = 0;

    vram_clear_all();
    puts_all("System Initialized.\n");
    puts_all(SHELL_PROMPT);

    while (1) {
        char c = kb_getchar();

        if (c == '\n') {
            cmd_buf[cmd_idx] = '\0';
            puts_all("\n");
            process_command(cmd_buf);
            cmd_idx = 0;
            puts_all(SHELL_PROMPT);
        }
        else if (c == '\b') {
            if (cmd_idx > 0) {
                cmd_idx--;
                puts_all("\b \b");
            }
        }
        else if (c != 0) {
            if (cmd_idx < MAX_CMD_LEN - 1) {
                cmd_buf[cmd_idx++] = c;
                uart_putchar(c);
                vram_putc(c);
            }
        }

        shell_poll_pause();
    }
}

// ============================================================================
// Main
// ============================================================================

int main(void) {
    xTaskCreate(Shell_Task, "shell", 512, NULL, 1, NULL);
    vTaskStartScheduler();
    while (1);
    return 0;
}
