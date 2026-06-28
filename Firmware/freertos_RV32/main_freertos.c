// ============================================================================
// main_freertos_new.c — FreeRTOS Shell + PS/2 Keyboard
// ============================================================================
//
// MMIO map:
//   UART_TX   : 0x10010000         (write-only)
//   UART_STAT : 0x10010004         (read-only, bit[0] = tx_busy)
//   VRAM      : 0x10020000~095F    (write-only, 80x30 byte-addressed)
//   KB_SCAN   : 0x10030000         (read-only, PS/2 Set 2 scancode)
//   KB_STAT   : 0x10030004         (read: bit[0] = key_valid,
//                                   write: acknowledge/pop)
//   MTIME     : 0x02000000~000F    (CLINT mtime/mtimecmp)
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

#define MTIME_LO      ((volatile uint32_t *)0x02000000)
#define MTIME_HI      ((volatile uint32_t *)0x02000004)
#define MTIMECMP_LO   ((volatile uint32_t *)0x02000008)
#define MTIMECMP_HI   ((volatile uint32_t *)0x0200000C)

#define COLS          80
#define ROWS          30

#define SHELL_PROMPT  "\nRV32> "
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

static void uint2str(uint32_t n, char *buf) {
    if (n == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return;
    }

    char tmp[12];
    int i = 0;

    while (n > 0) {
        tmp[i++] = '0' + (n % 10);
        n /= 10;
    }

    int j = 0;

    while (i > 0) {
        buf[j++] = tmp[--i];
    }

    buf[j] = '\0';
}

static uint32_t hex2uint(const char *s) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }

    uint32_t v = 0;

    while (*s) {
        char c = *s++;

        if (c >= '0' && c <= '9') {
            v = v * 16 + (uint32_t)(c - '0');
        }
        else if (c >= 'a' && c <= 'f') {
            v = v * 16 + (uint32_t)(c - 'a' + 10);
        }
        else if (c >= 'A' && c <= 'F') {
            v = v * 16 + (uint32_t)(c - 'A' + 10);
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

// ============================================================================
// CSR Read Helpers
// ============================================================================

static uint32_t read_mstatus(void) {
    uint32_t v;
    __asm volatile("csrr %0, mstatus" : "=r"(v));
    return v;
}

static uint32_t read_mie(void) {
    uint32_t v;
    __asm volatile("csrr %0, mie" : "=r"(v));
    return v;
}

static uint32_t read_mip(void) {
    uint32_t v;
    __asm volatile("csrr %0, mip" : "=r"(v));
    return v;
}

static uint32_t read_mcause(void) {
    uint32_t v;
    __asm volatile("csrr %0, mcause" : "=r"(v));
    return v;
}

static uint32_t read_mepc(void) {
    uint32_t v;
    __asm volatile("csrr %0, mepc" : "=r"(v));
    return v;
}

static uint32_t read_mtvec(void) {
    uint32_t v;
    __asm volatile("csrr %0, mtvec" : "=r"(v));
    return v;
}

static inline uint32_t read_mcycle(void) {
    uint32_t v;
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
// Dhrystone-lite Benchmark
// ============================================================================

typedef enum {
    Ident1,
    Ident2,
    Ident3,
    Ident4,
    Ident5
} Enumeration;

typedef struct {
    int IntComp;
    char StrComp[31];
    Enumeration EnumComp;
} RecType;

static RecType RecordA;
static RecType *PtrGlb;
static int IntGlb1;
static int BoolGlb;
static char StrGlb1[31];
static char StrGlb2[31];

static Enumeration Func1(char C1, char C2) {
    char L = C1;
    char L2 = L;

    return (L2 != C2) ? Ident1 : Ident2;
}

static int Func2(const char *S1, const char *S2) {
    int I = 2;
    char C = 'A';

    while (I <= 2) {
        if (Func1(S1[I], S2[I + 1]) == Ident1) {
            C = 'A';
            I++;
        }
    }

    if (C >= 'W' && C < 'Z') {
        I = 7;
    }

    if (C == 'X') {
        return 1;
    }

    return (my_strcmp(S1, S2) > 0) ? 1 : 0;
}

static int Func3(Enumeration E) {
    return (E == Ident3) ? 1 : 0;
}

static void Proc1(RecType *P) {
    RecType *N = P;

    N->IntComp = 5;
    P->IntComp = N->IntComp;
    P->EnumComp = Ident1;
    N->IntComp = PtrGlb->IntComp;
    N->EnumComp = P->EnumComp;
}

static void Proc2(int *I) {
    int L;
    Enumeration E = Ident1;

    L = *I + 10;

    do {
        if (Func1('A', 'B') == Ident1) {
            L--;
            *I = L - IntGlb1;
            E = Ident1;
        }
    } while (E != Ident1);
}

static void Proc4(void) {
    BoolGlb = (IntGlb1 == 1) | BoolGlb;
}

static void Proc5(void) {
    StrGlb1[0] = 'A';
    BoolGlb = 0;
}

static void Proc6(Enumeration In, Enumeration *Out) {
    *Out = In;

    if (!Func3(In)) {
        *Out = Ident4;
    }

    switch (In) {
        case Ident1:
            *Out = Ident1;
            break;

        case Ident2:
            *Out = (IntGlb1 > 100) ? Ident1 : Ident4;
            break;

        case Ident3:
            *Out = Ident2;
            break;

        case Ident4:
            break;

        case Ident5:
            *Out = Ident3;
            break;
    }
}

static void Proc7(int I1, int I2, int *O) {
    *O = I2 + (I1 + 2);
}

static void Proc8(int A[], int B[][8], int I1, int I2) {
    int L = I1 + 5;

    A[L] = I2;
    A[L + 1] = A[L];
    B[L][L - 1] = L;
}

#define ITERATIONS 1000

static void dhrystone_run(void) {
    int IL1;
    int IL2;
    int IL3;
    char CI;
    Enumeration EL;
    char SL2[31];
    int AA[51];
    int AB[51][8];
    uint32_t start;
    uint32_t end;
    uint32_t cycles;
    char buf[16];

    PtrGlb = &RecordA;
    PtrGlb->IntComp = 0;
    PtrGlb->EnumComp = Ident2;

    my_strcpy(PtrGlb->StrComp, "DHRYSTONE");
    my_strcpy(StrGlb1, "DHRYSTONE PROGRAM");
    my_strcpy(StrGlb2, "DON'T STOP");

    puts_all("Running Dhrystone...\n");

    start = read_mcycle();

    for (int i = 0; i < ITERATIONS; i++) {
        Proc5();
        Proc4();

        IL1 = 2;
        IL2 = 3;

        my_strcpy(SL2, "DHRYSTONE");
        EL = Ident2;

        BoolGlb = !Func2(StrGlb1, StrGlb2);

        while (IL1 < IL2) {
            IL3 = 5 * IL1 - IL2;
            Proc7(IL1, IL2, &IL3);
            IL1++;
        }

        Proc8(AA, AB, IL1, IL3);
        Proc1(PtrGlb);

        for (CI = 'A'; CI <= 'B'; CI++) {
            if (EL == Func1(CI, 'C')) {
                Proc6(Ident1, &EL);
            }
        }

        IL3 = IL2 * IL1;
        IL2 = IL3 / IL1;
        IL2 = 7 * (IL3 - IL2) - IL1;

        Proc2(&IL1);
    }

    end = read_mcycle();
    cycles = end - start;

    puts_all("Iterations : ");
    uint2str(ITERATIONS, buf);
    puts_all(buf);
    puts_all("\n");

    puts_all("Cycles     : ");
    uint2str(cycles, buf);
    puts_all(buf);
    puts_all("\n");

    puts_all("Cycles/iter: ");
    uint2str(cycles / ITERATIONS, buf);
    puts_all(buf);
    puts_all("\n");
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
    puts_all("  bench                 - Dhrystone benchmark\n");
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

    puts_all("SMU-Pipeline | FreeRTOS RV32IM Shell\n");
    puts_all("Board : Nexys Video (Artix-7 XC7A200T)\n");
    puts_all("Clock : 100MHz sys / 25MHz pixel / 125MHz serial\n");
    puts_all("Output: UART TX + HDMI text VRAM (80x30)\n");
    puts_all("Input : PS/2 keyboard MMIO 0x1003_xxxx\n");
}

static void cmd_csr(int argc, char **argv) {
    (void)argc;
    (void)argv;

    print_hex_line("mstatus ", read_mstatus());
    print_hex_line("mie     ", read_mie());
    print_hex_line("mip     ", read_mip());
    print_hex_line("mcause  ", read_mcause());
    print_hex_line("mepc    ", read_mepc());
    print_hex_line("mtvec   ", read_mtvec());
    print_hex_line("mcycle  ", read_mcycle());
    print_hex_line("mtime   ", *MTIME_LO);
    print_hex_line("mtimecmp", *MTIMECMP_LO);
}

static void cmd_bench(int argc, char **argv) {
    (void)argc;
    (void)argv;

    dhrystone_run();
}

static void cmd_memr(int argc, char **argv) {
    if (argc < 2) {
        puts_all("usage: memr <addr>\n");
        return;
    }

    uint32_t addr = hex2uint(argv[1]);

    if (addr & 0x3u) {
        puts_all("error: addr must be 4-byte aligned\n");
        return;
    }

    uint32_t val = *(volatile uint32_t *)addr;
    char buf[12];

    puts_all("addr=");
    uint2hex(addr, buf);
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

    uint32_t addr = hex2uint(argv[1]);
    uint32_t val = hex2uint(argv[2]);

    if (addr & 0x3u) {
        puts_all("error: addr must be 4-byte aligned\n");
        return;
    }

    *(volatile uint32_t *)addr = val;

    char buf[12];

    puts_all("addr=");
    uint2hex(addr, buf);
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

    uint32_t addr = hex2uint(argv[1]);
    uint32_t len = dec2uint(argv[2]);

    if (addr & 0x3u) {
        puts_all("error: addr must be 4-byte aligned\n");
        return;
    }

    if (len & 0x3u) {
        len = (len + 4u) & ~0x3u;
    }

    char buf[12];

    for (uint32_t i = 0; i < len; i += 4) {
        if ((i % 16u) == 0) {
            uint2hex(addr + i, buf);
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

    uint32_t mtime = *MTIME_LO;
    uint32_t ticks = xTaskGetTickCount();
    char buf[12];

    puts_all("mtime : ");
    uint2str(mtime, buf);
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
    {"bench",   cmd_bench},
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
