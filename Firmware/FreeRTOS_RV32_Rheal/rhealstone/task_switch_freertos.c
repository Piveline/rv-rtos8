/*
 * Rhealstone: Task Switch Benchmark
 * FreeRTOS shell-command version for the RV64 FreeRTOS SoC.
 */

#include "rhealstone_io.h"

#define RHEAL_SWITCH_BENCHMARKS 50000UL

static TaskHandle_t xSwitchTask01Handle;
static TaskHandle_t xSwitchTask02Handle;

static volatile rheal_cycles_t switch_loop_overhead;
static volatile rheal_cycles_t switch_dir_overhead;
static volatile uint32_t switch_count1 = 0;
static volatile uint32_t switch_count2 = 0;

static void vSwitchTask02(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start, t_elapsed;

    t_start = rheal_read_cycle();

    for (switch_count1 = 0; switch_count1 < RHEAL_SWITCH_BENCHMARKS - 1UL; switch_count1++) {
        taskYIELD();
    }

    t_elapsed = rheal_read_cycle() - t_start;

    rheal_print_time("Rhealstone: Task Switch",
                     t_elapsed,
                     (RHEAL_SWITCH_BENCHMARKS * 2UL) - 1UL,
                     switch_loop_overhead,
                     switch_dir_overhead);

    vTaskDelete(xSwitchTask01Handle);
    vTaskDelete(NULL);
}

static void vSwitchTask01(void *pvParameters)
{
    (void)pvParameters;

    if (xTaskCreate(vSwitchTask02,
                    "rSw2",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xSwitchTask02Handle) != pdPASS) {
        rheal_print_create_failed("rSw2");
        vTaskDelete(NULL);
    }

    taskYIELD();

    for (switch_count2 = 0; switch_count2 < RHEAL_SWITCH_BENCHMARKS; switch_count2++) {
        taskYIELD();
    }

    shell_puts("[rheal] task switch reached unexpected path\n");
    vTaskDelete(NULL);
}

static void vSwitchBenchmarkInit(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start;

    switch_count1 = 0;
    switch_count2 = 0;

    t_start = rheal_read_cycle();
    for (switch_count1 = 0; switch_count1 < RHEAL_SWITCH_BENCHMARKS - 1UL; switch_count1++) {
    }
    for (switch_count2 = 0; switch_count2 < RHEAL_SWITCH_BENCHMARKS; switch_count2++) {
    }
    switch_loop_overhead = rheal_read_cycle() - t_start;

    t_start = rheal_read_cycle();
    taskYIELD();
    switch_dir_overhead = rheal_read_cycle() - t_start;

    if (xTaskCreate(vSwitchTask01,
                    "rSw1",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xSwitchTask01Handle) != pdPASS) {
        rheal_print_create_failed("rSw1");
    }

    vTaskDelete(NULL);
}

void rhealstone_task_switch_start(void)
{
    rheal_print_start("task switch");

    if (xTaskCreate(vSwitchBenchmarkInit,
                    "rSwitch",
                    configMINIMAL_STACK_SIZE * 2,
                    NULL,
                    tskIDLE_PRIORITY + 3,
                    NULL) != pdPASS) {
        rheal_print_create_failed("rSwitch");
    }
}
