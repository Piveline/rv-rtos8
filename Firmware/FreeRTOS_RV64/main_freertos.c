// ============================================================================
// main_freertos.c — FreeRTOS Shell + PS/2 Keyboard
// ============================================================================
//
// MMIO map:
//   UART_TX   : 0x10010000         (write-only)
//   UART_STAT : 0x10010004         (read-only, bit[0] = tx_busy)
//   VRAM      : 0x10020000~095F    (write-only, 80x30 byte-addressed)
//   KB_SCAN   : 0x10030000         (read-only, PS/2 Set 2 scancode)
//   KB_STAT   : 0x10030004         (read: bit[0] = key_valid,
//                                   write: acknowledge/pop)
//   MTIME     : 0x02000000         (CLINT mtime,    64-bit R/W)
//   MTIMECMP  : 0x02000008         (CLINT mtimecmp, 64-bit R/W)
//
// [RV32→RV64] 변경 사항:
//   - CSR read 함수: uint32_t → unsigned long (XLEN=64)
//   - cmd_csr: 전부 print_hex_line64 사용 (mcause bit63 interrupt flag 등)
//   - hex2uint: uint32_t → uintptr_t (64-bit 주소 지원)
//   - uint2str: uint32_t → uint64_t (mcycle 등 64-bit 카운터)
//   - cmd_memr/memw/dump: 주소를 uintptr_t로 처리
//   - uint2hex: 32-bit 버전 유지 + 64-bit uint2hex64 추가
//
// 키보드 폴링 전략:
//   KB_HAS_FIFO == 0 (현재): busy-wait + taskYIELD, scancode 유실 방지
//   KB_HAS_FIFO == 1 (FIFO 추가 후): vTaskDelay 사용, RTOS 스케줄링 정상화
//
// ============================================================================

#include <stdint.h>
#include <stddef.h>
#include "FreeRTOS.h"
#include "task.h"

// ============================================================================
// 빌드 스위치
// ============================================================================

// RTL에 PS/2 FIFO를 추가한 뒤 1로 변경.
// 0이면 busy-wait 폴링, 1이면 vTaskDelay 기반 폴링.
#define KB_HAS_FIFO  1

// ============================================================================
// FreeRTOS port/data init 확인용 심볼
// ============================================================================

extern uint64_t      ullNextTime;
extern const uint64_t *pullNextTime;
extern size_t        xCriticalNesting;
extern size_t       *pxCriticalNesting;

// ============================================================================
// MMIO Addresses
// ============================================================================

#define UART_TX       ((volatile uint32_t *)0x10010000)
#define UART_STAT     ((volatile uint32_t *)0x10010004)

#define VRAM          ((volatile uint8_t  *)0x10020000)

#define KB_SCAN       ((volatile uint32_t *)0x10030000)
#define KB_STAT       ((volatile uint32_t *)0x10030004)

// CLINT: RV64 — 각 레지스터를 단일 64-bit 주소로 접근.
// HI/LO 분리 접근(+0x04, +0x0C)은 RTL에서 제거됨.
#define MTIME         ((volatile uint64_t *)0x02000000)
#define MTIMECMP      ((volatile uint64_t *)0x02000008)

#define COLS          80
#define ROWS          30

#define SHELL_PROMPT  "\nRV64> "
#define MAX_CMD_LEN   64
#define HISTORY_SIZE  8

// ============================================================================
// UART TX
// ============================================================================

static void uart_putchar(char c) {
    while (*UART_STAT & 1u) {
        // tx_busy wait
    }

    *UART_TX = (uint32_t)c;
}

// ============================================================================
// VRAM Display
// ============================================================================

static int vrow = 0;
static int vcol = 0;

static void vram_scroll_if_needed(void) {
    if (vrow < ROWS)
        return;

    for (int r = 0; r < ROWS - 1; r++) {
        for (int c = 0; c < COLS; c++) {
            VRAM[r * COLS + c] = VRAM[(r + 1) * COLS + c];
        }
    }

    for (int c = 0; c < COLS; c++) {
        VRAM[(ROWS - 1) * COLS + c] = ' ';
    }

    vrow = ROWS - 1;
}

static void vram_putc(char c) {
    if (c == '\n') {
        vcol = 0;
        vrow++;
    }
    else if (c == '\r') {
        vcol = 0;
    }
    else if (c == '\b') {
        if (vcol > 0) {
            vcol--;
            VRAM[vrow * COLS + vcol] = ' ';
        }
    }
    else {
        VRAM[vrow * COLS + vcol] = (uint8_t)c;

        if (++vcol >= COLS) {
            vcol = 0;
            vrow++;
        }
    }

    vram_scroll_if_needed();
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
    for (int i = 0; i < COLS * ROWS; i++) {
        VRAM[i] = ' ';
    }

    vrow = 0;
    vcol = 0;
}

// ============================================================================
// String Utilities
// ============================================================================

static int my_strlen(const char *s) {
    int n = 0;

    while (s[n])
        n++;

    return n;
}

static int my_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }

    return *a - *b;
}

static void my_strcpy(char *d, const char *s) {
    while ((*d++ = *s++)) {
    }
}

// [RV32→RV64] uint32_t → uint64_t: mcycle 등 64-bit 카운터 출력 대응.
static void uint2str(uint64_t n, char *buf) {
    if (n == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return;
    }

    char tmp[21];  // uint64_t 최대 20자리
    int i = 0;

    while (n > 0) {
        tmp[i++] = '0' + (char)(n % 10);
        n /= 10;
    }

    int j = 0;

    while (i > 0) {
        buf[j++] = tmp[--i];
    }

    buf[j] = '\0';
}

// [RV32→RV64] uint32_t → uintptr_t: 64-bit 주소 파싱.
// RV32 호환: 32-bit 범위 주소도 정상 동작.
static uintptr_t hex2uint(const char *s) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }

    uintptr_t v = 0;

    while (*s) {
        char c = *s++;

        if (c >= '0' && c <= '9') {
            v = v * 16 + (uintptr_t)(c - '0');
        }
        else if (c >= 'a' && c <= 'f') {
            v = v * 16 + (uintptr_t)(c - 'a' + 10);
        }
        else if (c >= 'A' && c <= 'F') {
            v = v * 16 + (uintptr_t)(c - 'A' + 10);
        }
        else {
            break;
        }
    }

    return v;
}

static uint32_t dec2uint(const char *s) {
    uint32_t v = 0;

    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (uint32_t)(*s - '0');
        s++;
    }

    return v;
}

static void uint2hex(uint32_t n, char *buf) {
    const char *h = "0123456789ABCDEF";

    buf[0] = '0';
    buf[1] = 'x';

    for (int i = 0; i < 8; i++) {
        buf[2 + i] = h[(n >> (28 - i * 4)) & 0xF];
    }

    buf[10] = '\0';
}

// 64-bit hex 출력 (buf는 19바이트 이상 필요: "0x" + 16nibbles + '\0')
static void uint2hex64(uint64_t n, char *buf) {
    const char *h = "0123456789ABCDEF";

    buf[0] = '0';
    buf[1] = 'x';

    for (int i = 0; i < 16; i++) {
        buf[2 + i] = h[(n >> (60 - i * 4)) & 0xF];
    }

    buf[18] = '\0';
}

// [RV32→RV64] 추가: uintptr_t용 hex 출력.
// 포인터 폭에 따라 32/64-bit 자동 선택.
static void uint2hex_ptr(uintptr_t n, char *buf) {
#if __riscv_xlen == 64
    uint2hex64((uint64_t)n, buf);
#else
    uint2hex((uint32_t)n, buf);
#endif
}

// ============================================================================
// CSR Read Helpers
// ============================================================================
// [RV32→RV64] XLEN=64이므로 CSR은 64-bit.
// unsigned long은 lp64 ABI에서 64-bit, ilp32에서 32-bit → 양쪽 호환.

static unsigned long read_mstatus(void) {
    unsigned long v;
    __asm volatile("csrr %0, mstatus" : "=r"(v));
    return v;
}

static unsigned long read_mie(void) {
    unsigned long v;
    __asm volatile("csrr %0, mie" : "=r"(v));
    return v;
}

static unsigned long read_mip(void) {
    unsigned long v;
    __asm volatile("csrr %0, mip" : "=r"(v));
    return v;
}

static unsigned long read_mcause(void) {
    unsigned long v;
    __asm volatile("csrr %0, mcause" : "=r"(v));
    return v;
}

static unsigned long read_mepc(void) {
    unsigned long v;
    __asm volatile("csrr %0, mepc" : "=r"(v));
    return v;
}

static unsigned long read_mtvec(void) {
    unsigned long v;
    __asm volatile("csrr %0, mtvec" : "=r"(v));
    return v;
}

static inline unsigned long read_mcycle(void) {
    unsigned long v;
    __asm volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static void print_hex_line(const char *name, uint32_t val) {
    char buf[12];

    puts_all(name);
    puts_all(": ");
    uint2hex(val, buf);
    puts_all(buf);
    puts_all("\n");
}

// MTIME/MTIMECMP, CSR 등 64-bit 값 출력용
static void print_hex_line64(const char *name, uint64_t val) {
    char buf[20];

    puts_all(name);
    puts_all(": ");
    uint2hex64(val, buf);
    puts_all(buf);
    puts_all("\n");
}

// ============================================================================
// PS/2 Keyboard Input
// ============================================================================

// PS/2 Set 2 scancode -> ASCII.
static char scancode_to_ascii(uint8_t sc) {
    switch (sc) {
        case 0x1C: return 'a';
        case 0x32: return 'b';
        case 0x21: return 'c';
        case 0x23: return 'd';
        case 0x24: return 'e';
        case 0x2B: return 'f';
        case 0x34: return 'g';
        case 0x33: return 'h';
        case 0x43: return 'i';
        case 0x3B: return 'j';
        case 0x42: return 'k';
        case 0x4B: return 'l';
        case 0x3A: return 'm';
        case 0x31: return 'n';
        case 0x44: return 'o';
        case 0x4D: return 'p';
        case 0x15: return 'q';
        case 0x2D: return 'r';
        case 0x1B: return 's';
        case 0x2C: return 't';
        case 0x3C: return 'u';
        case 0x2A: return 'v';
        case 0x1D: return 'w';
        case 0x22: return 'x';
        case 0x35: return 'y';
        case 0x1A: return 'z';

        case 0x45: return '0';
        case 0x16: return '1';
        case 0x1E: return '2';
        case 0x26: return '3';
        case 0x25: return '4';
        case 0x2E: return '5';
        case 0x36: return '6';
        case 0x3D: return '7';
        case 0x3E: return '8';
        case 0x46: return '9';

        case 0x29: return ' ';
        case 0x5A: return '\n';
        case 0x66: return '\b';

        case 0x4E: return '-';
        case 0x55: return '=';
        case 0x54: return '[';
        case 0x5B: return ']';
        case 0x4C: return ';';
        case 0x52: return '\'';
        case 0x41: return ',';
        case 0x49: return '.';
        case 0x4A: return '/';

        default:
            return 0;
    }
}

// Non-blocking keyboard read.
// FIFO 유무와 무관하게 동작한다.
// 입력이 없거나 break/release code이면 0 반환.
static char kb_getchar(void) {
    static uint8_t break_flag = 0;
    static uint8_t extended_flag = 0;

    if ((*KB_STAT & 1u) == 0) {
        return 0;
    }

    uint8_t sc = (uint8_t)(*KB_SCAN & 0xFFu);

    // acknowledge (FIFO 있으면 pop)
    *KB_STAT = 1u;

    // Extended prefix (E0). 방향키 등 무시.
    if (sc == 0xE0) {
        extended_flag = 1;
        return 0;
    }

    // Break prefix (F0).
    if (sc == 0xF0) {
        break_flag = 1;
        return 0;
    }

    // Key release: break_flag가 세팅된 상태에서 오는 scancode.
    if (break_flag) {
        break_flag = 0;
        extended_flag = 0;
        return 0;
    }

    // Extended make code: 현재 미지원.
    if (extended_flag) {
        extended_flag = 0;
        return 0;
    }

    return scancode_to_ascii(sc);
}

// ============================================================================
// Command Parsing / History
// ============================================================================

static void parse(char *line, char **argv, int *argc) {
    *argc = 0;

    char *p = line;

    while (*p) {
        while (*p == ' ') {
            p++;
        }

        if (!*p) {
            break;
        }

        argv[(*argc)++] = p;

        while (*p && *p != ' ') {
            p++;
        }

        if (*p) {
            *p++ = '\0';
        }

        if (*argc >= 8) {
            break;
        }
    }
}

static char history[HISTORY_SIZE][MAX_CMD_LEN];
static int history_count = 0;

static void history_add(const char *cmd) {
    if (my_strlen(cmd) == 0) {
        return;
    }

    int idx = history_count % HISTORY_SIZE;

    my_strcpy(history[idx], cmd);
    history_count++;
}

// ============================================================================
// Commands
// ============================================================================

static void run_command(char *line);

static void cmd_help(int argc, char **argv) {
    (void)argc;
    (void)argv;

    puts_all("commands:\n");
    puts_all("  help                  - command list\n");
    puts_all("  echo <text>           - print text\n");
    puts_all("  clear                 - clear screen\n");
    puts_all("  info                  - system info\n");
    puts_all("  csr                   - dump CSR registers\n");
    puts_all("  memr <addr>           - read 32-bit memory\n");
    puts_all("  memw <addr> <val>     - write 32-bit memory\n");
    puts_all("  dump <addr> <len>     - memory dump\n");
    puts_all("  uptime                - show mtime and FreeRTOS ticks\n");
    puts_all("  free                  - show free heap\n");
    puts_all("  history               - command history\n");
    puts_all("  fill <char>           - fill VRAM\n");
    puts_all("  repeat <n> <cmd>      - repeat command\n");
}

static void cmd_echo(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        puts_all(argv[i]);

        if (i != argc - 1) {
            puts_all(" ");
        }
    }

    puts_all("\n");
}

static void cmd_clear(int argc, char **argv) {
    (void)argc;
    (void)argv;

    vram_clear_all();
}

static void cmd_info(int argc, char **argv) {
    (void)argc;
    (void)argv;

    puts_all("SMU-Pipeline | FreeRTOS RV64IM Shell\n");
    puts_all("Board : Nexys Video (Artix-7 XC7A200T)\n");
    puts_all("Clock : 100MHz sys / 25MHz pixel / 125MHz serial\n");
    puts_all("Output: UART TX + HDMI text VRAM (80x30)\n");
    puts_all("Input : PS/2 keyboard MMIO 0x1003_xxxx\n");
}

// [RV32→RV64] 모든 CSR을 64-bit로 출력.
// mcause bit[63]이 interrupt flag이므로 32-bit 출력으로는 확인 불가.
static void cmd_csr(int argc, char **argv) {
    (void)argc;
    (void)argv;

    print_hex_line64("mstatus ", (uint64_t)read_mstatus());
    print_hex_line64("mie     ", (uint64_t)read_mie());
    print_hex_line64("mip     ", (uint64_t)read_mip());
    print_hex_line64("mcause  ", (uint64_t)read_mcause());
    print_hex_line64("mepc    ", (uint64_t)read_mepc());
    print_hex_line64("mtvec   ", (uint64_t)read_mtvec());
    print_hex_line64("mcycle  ", (uint64_t)read_mcycle());
    // mtime/mtimecmp: RTL이 64-bit 단일 주소이므로 ld(64-bit load)로 읽음.
    print_hex_line64("mtime   ", *MTIME);
    print_hex_line64("mtimecmp", *MTIMECMP);
}

// [RV32→RV64] 주소를 uintptr_t로 처리.
// 이 SoC의 주소 공간은 32-bit 범위 내이므로 실질적 동작은 동일하나,
// RV64에서 포인터 캐스트가 정확하도록 수정.
static void cmd_memr(int argc, char **argv) {
    if (argc < 2) {
        puts_all("usage: memr <addr>\n");
        return;
    }

    uintptr_t addr = hex2uint(argv[1]);

    if (addr & 0x3u) {
        puts_all("error: addr must be 4-byte aligned\n");
        return;
    }

    uint32_t val = *(volatile uint32_t *)addr;

    char buf[20];

    puts_all("addr=");
    uint2hex_ptr(addr, buf);
    puts_all(buf);

    puts_all(" val=");
    uint2hex(val, buf);
    puts_all(buf);
    puts_all("\n");
}

static void cmd_memw(int argc, char **argv) {
    if (argc < 3) {
        puts_all("usage: memw <addr> <val>\n");
        return;
    }

    uintptr_t addr = hex2uint(argv[1]);
    uint32_t val = (uint32_t)hex2uint(argv[2]);

    if (addr & 0x3u) {
        puts_all("error: addr must be 4-byte aligned\n");
        return;
    }

    *(volatile uint32_t *)addr = val;

    char buf[20];

    puts_all("addr=");
    uint2hex_ptr(addr, buf);
    puts_all(buf);

    puts_all(" val=");
    uint2hex(val, buf);
    puts_all(buf);

    puts_all(" OK\n");
}

static void cmd_dump(int argc, char **argv) {
    if (argc < 3) {
        puts_all("usage: dump <addr> <len>\n");
        return;
    }

    uintptr_t addr = hex2uint(argv[1]);
    uint32_t len = dec2uint(argv[2]);

    if (addr & 0x3u) {
        puts_all("error: addr must be 4-byte aligned\n");
        return;
    }

    if (len & 0x3u) {
        len = (len + 4u) & ~0x3u;
    }

    char buf[20];

    for (uint32_t i = 0; i < len; i += 4) {
        if ((i % 16u) == 0) {
            uint2hex_ptr(addr + i, buf);
            puts_all(buf);
            puts_all(": ");
        }

        uint32_t word = *(volatile uint32_t *)(addr + i);

        for (int b = 0; b < 4; b++) {
            uint8_t byte = (uint8_t)((word >> (b * 8)) & 0xFFu);
            char hex[3];

            hex[0] = "0123456789ABCDEF"[(byte >> 4) & 0xF];
            hex[1] = "0123456789ABCDEF"[byte & 0xF];
            hex[2] = '\0';

            puts_all(hex);
            puts_all(" ");
        }

        if (((i + 4u) % 16u) == 0) {
            puts_all("\n");
        }
    }

    if ((len % 16u) != 0) {
        puts_all("\n");
    }
}

static void cmd_uptime(int argc, char **argv) {
    (void)argc;
    (void)argv;

    // RTL 변경: 64-bit 단일 ld로 읽음. HI/LO 분리 불필요.
    uint64_t mtime = *MTIME;
    uint32_t ticks = xTaskGetTickCount();
    char buf[24];

    puts_all("mtime : ");
    uint2hex64(mtime, buf);
    puts_all(buf);
    puts_all("\n");

    puts_all("ticks : ");
    uint2str(ticks, buf);
    puts_all(buf);
    puts_all("\n");
}

static void cmd_free(int argc, char **argv) {
    (void)argc;
    (void)argv;

    uint32_t heap = xPortGetFreeHeapSize();
    char buf[12];

    puts_all("Free heap: ");
    uint2str(heap, buf);
    puts_all(buf);
    puts_all(" bytes\n");
}

static void cmd_history(int argc, char **argv) {
    (void)argc;
    (void)argv;

    int total = history_count < HISTORY_SIZE ? history_count : HISTORY_SIZE;

    if (total == 0) {
        puts_all("(empty)\n");
        return;
    }

    char buf[12];

    for (int i = 0; i < total; i++) {
        int idx = (history_count - total + i) % HISTORY_SIZE;

        uint2str((uint32_t)(i + 1), buf);
        puts_all(buf);
        puts_all("  ");
        puts_all(history[idx]);
        puts_all("\n");
    }
}

static void cmd_fill(int argc, char **argv) {
    if (argc < 2) {
        puts_all("usage: fill <char>\n");
        return;
    }

    char ch = argv[1][0];

    for (int i = 0; i < COLS * ROWS; i++) {
        VRAM[i] = (uint8_t)ch;
    }

    vrow = 0;
    vcol = 0;

    puts_all("filled\n");
}

static void cmd_repeat(int argc, char **argv) {
    if (argc < 3) {
        puts_all("usage: repeat <n> <cmd>\n");
        return;
    }

    uint32_t n = dec2uint(argv[1]);

    char buf[MAX_CMD_LEN];
    int pos = 0;

    for (int i = 2; i < argc && pos < MAX_CMD_LEN - 2; i++) {
        char *p = argv[i];

        while (*p && pos < MAX_CMD_LEN - 2) {
            buf[pos++] = *p++;
        }

        if (i < argc - 1) {
            buf[pos++] = ' ';
        }
    }

    buf[pos] = '\0';

    char tmp[MAX_CMD_LEN];
    char num[12];

    for (uint32_t i = 0; i < n; i++) {
        puts_all("[");
        uint2str(i + 1, num);
        puts_all(num);
        puts_all("/");
        uint2str(n, num);
        puts_all(num);
        puts_all("] ");

        for (int j = 0; j <= pos; j++) {
            tmp[j] = buf[j];
        }

        run_command(tmp);
    }
}

// ============================================================================
// Command Table
// ============================================================================

typedef struct {
    const char *name;
    void (*fn)(int, char **);
} cmd_t;

static const cmd_t cmds[] = {
    {"help",    cmd_help},
    {"echo",    cmd_echo},
    {"clear",   cmd_clear},
    {"info",    cmd_info},
    {"csr",     cmd_csr},
    {"memr",    cmd_memr},
    {"memw",    cmd_memw},
    {"dump",    cmd_dump},
    {"uptime",  cmd_uptime},
    {"free",    cmd_free},
    {"history", cmd_history},
    {"fill",    cmd_fill},
    {"repeat",  cmd_repeat},
    {0, 0}
};

static void run_command(char *line) {
    char *argv[8];
    int argc;

    parse(line, argv, &argc);

    if (argc == 0) {
        return;
    }

    for (const cmd_t *cmd = cmds; cmd->name; cmd++) {
        if (my_strcmp(argv[0], cmd->name) == 0) {
            cmd->fn(argc, argv);
            return;
        }
    }

    puts_all("unknown: ");
    puts_all(argv[0]);
    puts_all("\n");
}

// ============================================================================
// Shell Task
// ============================================================================

void Shell_Task(void *pvParameters) {
    (void)pvParameters;

    char cmd_buf[MAX_CMD_LEN];
    uint8_t cmd_idx = 0;

    vram_clear_all();

    puts_all("System Initialized.\n");
    puts_all("Input: PS/2 keyboard MMIO 0x10030000\n");
    puts_all(SHELL_PROMPT);

    while (1) {
        char c = kb_getchar();

        if (c == '\n' || c == '\r') {
            cmd_buf[cmd_idx] = '\0';
            puts_all("\n");

            if (cmd_idx > 0) {
                history_add(cmd_buf);
                run_command(cmd_buf);
            }

            cmd_idx = 0;
            puts_all(SHELL_PROMPT);
        }
        else if (c == '\b' || c == 0x7F) {
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

#if KB_HAS_FIFO
        // FIFO가 있으면 vTaskDelay로 yield해도 scancode 유실 없음.
        // FIFO depth >= 8이면 10ms 간격으로도 안전.
        vTaskDelay(pdMS_TO_TICKS(1));
#else
        // FIFO 없음: busy-wait로 충분히 빠르게 폴링해야 scancode 유실 방지.
        // ~20us @100MHz. 그 후 다른 태스크에 양보.
        for (volatile uint32_t i = 0; i < 2000; i++) {
            __asm volatile("nop");
        }
        taskYIELD();
#endif
    }
}

// ============================================================================
// Main
// ============================================================================

int main(void) {
    vram_clear_all();

    // FreeRTOS port data init sanity check.
    // 실패 시 crt0.S의 .data/.bss 초기화 확인 필요.
    if (pullNextTime != &ullNextTime) {
        puts_all("DATA INIT BAD: pullNextTime\n");
    }

    if (pxCriticalNesting != &xCriticalNesting) {
        puts_all("DATA INIT BAD: pxCriticalNesting\n");
    }

    if (xCriticalNesting != (size_t)0xaaaaaaaaUL) {
        puts_all("DATA INIT BAD: xCriticalNesting\n");
    }

    xTaskCreate(Shell_Task, "shell", 1024, NULL, 1, NULL);
    vTaskStartScheduler();

    while (1) {
    }

    return 0;
}
