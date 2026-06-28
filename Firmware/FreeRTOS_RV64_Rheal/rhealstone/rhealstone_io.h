#ifndef RHEALSTONE_IO_H
#define RHEALSTONE_IO_H

#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"

#if __riscv_xlen == 64
typedef uint64_t rheal_cycles_t;
#else
typedef uint32_t rheal_cycles_t;
#endif

static inline rheal_cycles_t rheal_read_cycle(void)
{
    rheal_cycles_t cycle;
    __asm__ volatile ("rdcycle %0" : "=r"(cycle));
    return cycle;
}

void shell_puts(const char *s);
void shell_put_u64(uint64_t v);
void shell_put_hex64(uint64_t v);

static inline void rheal_print_time(const char *message,
                                    rheal_cycles_t total_time,
                                    rheal_cycles_t iterations,
                                    rheal_cycles_t overhead,
                                    rheal_cycles_t direct_overhead)
{
    rheal_cycles_t adjusted = 0;
    rheal_cycles_t avg = 0;

    if (iterations != 0) {
        adjusted = (total_time > overhead) ? (total_time - overhead) : 0;
        avg = adjusted / iterations;
        avg = (avg > direct_overhead) ? (avg - direct_overhead) : 0;
    }

    shell_puts(message);
    shell_puts(" - ");
    shell_put_u64((uint64_t)avg);
    shell_puts(" cycles\n");
}

static inline void rheal_print_start(const char *name)
{
    shell_puts("[rheal] start ");
    shell_puts(name);
    shell_puts("\n");
}

static inline void rheal_print_create_failed(const char *name)
{
    shell_puts("[rheal] xTaskCreate failed: ");
    shell_puts(name);
    shell_puts("\n");
}

#endif /* RHEALSTONE_IO_H */
