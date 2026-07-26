/*
 * Rhealstone: Task Preempt Benchmark
 * FreeRTOS shell-command version for the RV64 FreeRTOS SoC.
 */

#include "rhealstone_io.h"

#define RHEAL_PREEMPT_BENCHMARKS 50000UL

static TaskHandle_t xPreemptTask01Handle;
static TaskHandle_t xPreemptTask02Handle;

static volatile rheal_cycles_t preempt_t_start;
static volatile rheal_cycles_t preempt_loop_overhead;
static volatile rheal_cycles_t preempt_switch_overhead;
static volatile uint32_t preempt_count1 = 0;

static void vPreemptTask02(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_elapsed;

    preempt_t_start = rheal_read_cycle();
    vTaskSuspend(NULL);

    for (; preempt_count1 < RHEAL_PREEMPT_BENCHMARKS - 1UL; ) {
        vTaskSuspend(NULL);
    }

    t_elapsed = rheal_read_cycle() - preempt_t_start;

    rheal_print_time("Rhealstone: Task Preempt",
                     t_elapsed,
                     RHEAL_PREEMPT_BENCHMARKS - 1UL,
                     preempt_loop_overhead,
                     preempt_switch_overhead);

    vTaskDelete(xPreemptTask01Handle);
    vTaskDelete(NULL);
}

static void vPreemptTask01(void *pvParameters)
{
    (void)pvParameters;

    if (xTaskCreate(vPreemptTask02,
                    "rPr2",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 3,
                    &xPreemptTask02Handle) != pdPASS) {
        rheal_print_create_failed("rPr2");
        vTaskDelete(NULL);
    }

    preempt_switch_overhead = rheal_read_cycle() - preempt_t_start;

    preempt_t_start = rheal_read_cycle();
    for (preempt_count1 = 0; preempt_count1 < RHEAL_PREEMPT_BENCHMARKS; preempt_count1++) {
        vTaskResume(xPreemptTask02Handle);
    }

    vTaskDelete(NULL);
}

static void vPreemptBenchmarkInit(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_init;

    t_init = rheal_read_cycle();
    for (preempt_count1 = 0; preempt_count1 < (RHEAL_PREEMPT_BENCHMARKS * 2UL) - 1UL; preempt_count1++) {
    }
    preempt_loop_overhead = rheal_read_cycle() - t_init;
    preempt_count1 = 0;

    if (xTaskCreate(vPreemptTask01,
                    "rPr1",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xPreemptTask01Handle) != pdPASS) {
        rheal_print_create_failed("rPr1");
    }

    vTaskDelete(NULL);
}

void rhealstone_task_preempt_start(void)
{
    rheal_print_start("task preempt");

    if (xTaskCreate(vPreemptBenchmarkInit,
                    "rPreempt",
                    configMINIMAL_STACK_SIZE * 2,
                    NULL,
                    tskIDLE_PRIORITY + 4,
                    NULL) != pdPASS) {
        rheal_print_create_failed("rPreempt");
    }
}
