/*
 * Rhealstone: Deadlock Break Benchmark
 * FreeRTOS shell-command version for the RV64 FreeRTOS SoC.
 */

#include "rhealstone_io.h"
#include "semphr.h"

#define RHEAL_DEADLOCK_BENCHMARKS 20000UL

static TaskHandle_t xDeadTask01Handle;
static TaskHandle_t xDeadTask02Handle;
static TaskHandle_t xDeadTask03Handle;
static SemaphoreHandle_t xDeadMutex;

static volatile uint32_t dead_count = 0;
static volatile rheal_cycles_t dead_elapsed;
static volatile rheal_cycles_t dead_switch_overhead;
static volatile rheal_cycles_t dead_obtain_overhead;
static volatile uint32_t dead_sem_exe = 0;

static void vDeadTask01(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start, t_end;

    t_start = rheal_read_cycle();

    for (dead_count = 0; dead_count < RHEAL_DEADLOCK_BENCHMARKS; dead_count++) {
        if (dead_sem_exe == 1U) {
            xSemaphoreTake(xDeadMutex, portMAX_DELAY);
        }
        if (dead_sem_exe == 1U) {
            xSemaphoreGive(xDeadMutex);
        }
        vTaskSuspend(NULL);
    }

    t_end = rheal_read_cycle();
    dead_elapsed = t_end - t_start;

    if (dead_sem_exe == 0U) {
        dead_switch_overhead = dead_elapsed;
        dead_sem_exe = 1U;
        dead_count = 0;

        vTaskSuspend(xDeadTask02Handle);
        vTaskSuspend(xDeadTask03Handle);

        vTaskResume(xDeadTask03Handle);
        vTaskSuspend(NULL);
    } else {
        rheal_print_time("Rhealstone: Deadlock Break",
                         dead_elapsed,
                         RHEAL_DEADLOCK_BENCHMARKS,
                         dead_switch_overhead,
                         dead_obtain_overhead);

        vTaskDelete(xDeadTask02Handle);
        vTaskDelete(xDeadTask03Handle);
        vTaskDelete(NULL);
    }
}

static void vDeadTask02(void *pvParameters)
{
    (void)pvParameters;

    vTaskResume(xDeadTask01Handle);

    for (;;) {
        vTaskSuspend(NULL);
        vTaskResume(xDeadTask01Handle);
    }
}

static void vDeadTask03(void *pvParameters)
{
    (void)pvParameters;

    for (;;) {
        if (dead_sem_exe == 1U) {
            xSemaphoreTake(xDeadMutex, portMAX_DELAY);
        }

        vTaskResume(xDeadTask02Handle);

        for (; dead_count < RHEAL_DEADLOCK_BENCHMARKS; ) {
            if (dead_sem_exe == 1U) {
                xSemaphoreGive(xDeadMutex);
            }
            if (dead_sem_exe == 1U) {
                xSemaphoreTake(xDeadMutex, portMAX_DELAY);
            }
            vTaskResume(xDeadTask02Handle);
        }
    }
}

static void vDeadBenchmarkInit(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start;

    dead_count = 0;
    dead_sem_exe = 0U;

    xDeadMutex = xSemaphoreCreateMutex();
    if (xDeadMutex == NULL) {
        rheal_print_create_failed("rDeadM");
        vTaskDelete(NULL);
    }

    t_start = rheal_read_cycle();
    xSemaphoreTake(xDeadMutex, portMAX_DELAY);
    dead_obtain_overhead = rheal_read_cycle() - t_start;
    xSemaphoreGive(xDeadMutex);

    if (xTaskCreate(vDeadTask01,
                    "rDl1",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 4,
                    &xDeadTask01Handle) != pdPASS) {
        rheal_print_create_failed("rDl1");
        vTaskDelete(NULL);
    }

    if (xTaskCreate(vDeadTask02,
                    "rDl2",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 3,
                    &xDeadTask02Handle) != pdPASS) {
        rheal_print_create_failed("rDl2");
        vTaskDelete(NULL);
    }

    if (xTaskCreate(vDeadTask03,
                    "rDl3",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xDeadTask03Handle) != pdPASS) {
        rheal_print_create_failed("rDl3");
        vTaskDelete(NULL);
    }

    vTaskSuspend(xDeadTask01Handle);
    vTaskSuspend(xDeadTask02Handle);

    vTaskDelete(NULL);
}

void rhealstone_deadlock_break_start(void)
{
    rheal_print_start("deadlock break");

    if (xTaskCreate(vDeadBenchmarkInit,
                    "rDead",
                    configMINIMAL_STACK_SIZE * 2,
                    NULL,
                    tskIDLE_PRIORITY + 4,
                    NULL) != pdPASS) {
        rheal_print_create_failed("rDead");
    }
}
