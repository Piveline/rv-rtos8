/*
 * Rhealstone: Interrupt Latency Benchmark
 * FreeRTOS shell-command version for the RV64 FreeRTOS SoC.
 *
 * This version uses the FreeRTOS tick hook as the benchmark ISR-side hook.
 * It programs MTIMECMP to MTIME+1 and measures from that write-side point
 * to vApplicationTickHook(). Therefore the reported value includes the
 * FreeRTOS/RISC-V timer-entry path up to the tick hook, not only raw trap
 * vector entry latency.
 */

#include "rhealstone_io.h"

#define RHEAL_INTR_BENCHMARKS 5000UL
#define RHEAL_INTR_TIMEOUT_CYCLES 1000000UL

#define RHEAL_MTIME       (*(volatile uint64_t *)0x02000000UL)
#define RHEAL_MTIMECMP    (*(volatile uint64_t *)0x02000008UL)

static volatile uint32_t intr_active = 0;
static volatile uint32_t intr_waiting = 0;
static volatile uint32_t intr_count = 0;
static volatile rheal_cycles_t intr_trigger_time = 0;
static volatile rheal_cycles_t intr_total_latency = 0;
static volatile rheal_cycles_t intr_timer_overhead = 0;

void vApplicationTickHook(void)
{
    if (intr_active && intr_waiting) {
        rheal_cycles_t isr_enter_time = rheal_read_cycle();
        intr_total_latency += isr_enter_time - intr_trigger_time;
        intr_count++;
        intr_waiting = 0;
    }
}

static void vIntrLatencyTask(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start;

    t_start = rheal_read_cycle();
    intr_timer_overhead = rheal_read_cycle() - t_start;

    intr_total_latency = 0;
    intr_count = 0;
    intr_active = 1;

    while (intr_count < RHEAL_INTR_BENCHMARKS) {
        rheal_cycles_t timeout_start;

        intr_waiting = 1;
        RHEAL_MTIMECMP = RHEAL_MTIME + 1ULL;
        intr_trigger_time = rheal_read_cycle();
        timeout_start = intr_trigger_time;

        while (intr_waiting) {
            if ((rheal_read_cycle() - timeout_start) > RHEAL_INTR_TIMEOUT_CYCLES) {
                intr_active = 0;
                intr_waiting = 0;
                shell_puts("Rhealstone: Interrupt Latency timeout; check configUSE_TICK_HOOK/timer ISR\n");
                vTaskDelete(NULL);
            }
            taskYIELD();
        }
    }

    intr_active = 0;

    rheal_print_time("Rhealstone: Interrupt Latency",
                     intr_total_latency,
                     RHEAL_INTR_BENCHMARKS,
                     intr_timer_overhead * RHEAL_INTR_BENCHMARKS,
                     0);

    vTaskDelete(NULL);
}

void rhealstone_interrupt_latency_start(void)
{
    rheal_print_start("interrupt latency");

    if (xTaskCreate(vIntrLatencyTask,
                    "rIntr",
                    configMINIMAL_STACK_SIZE * 2,
                    NULL,
                    tskIDLE_PRIORITY + 3,
                    NULL) != pdPASS) {
        rheal_print_create_failed("rIntr");
    }
}
