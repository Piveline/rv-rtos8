/*
 * Rhealstone: Semaphore Shuffle Benchmark
 * FreeRTOS shell-command version for the RV64 FreeRTOS SoC.
 */

#include "rhealstone_io.h"
#include "semphr.h"

#define RHEAL_SEM_BENCHMARKS 50000UL

static TaskHandle_t xSemTask01Handle;
static TaskHandle_t xSemTask02Handle;
static SemaphoreHandle_t xSemSemaphore;

static volatile rheal_cycles_t sem_elapsed;
static volatile rheal_cycles_t sem_switch_overhead;
static volatile uint32_t sem_count = 0;
static volatile uint32_t sem_exe = 0;

static void vSemTask01(void *pvParameters)
{
    (void)pvParameters;

    for (;;) {
        if (sem_exe == 1U) {
            xSemaphoreTake(xSemSemaphore, portMAX_DELAY);
        }
        taskYIELD();

        if (sem_exe == 1U) {
            xSemaphoreGive(xSemSemaphore);
        }
        taskYIELD();
    }
}

static void vSemTask02(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start;

    t_start = rheal_read_cycle();
    for (sem_count = 0; sem_count < RHEAL_SEM_BENCHMARKS; sem_count++) {
        if (sem_exe == 1U) {
            xSemaphoreTake(xSemSemaphore, portMAX_DELAY);
        }
        taskYIELD();

        if (sem_exe == 1U) {
            xSemaphoreGive(xSemSemaphore);
        }
        taskYIELD();
    }
    sem_elapsed = rheal_read_cycle() - t_start;

    sem_switch_overhead = sem_elapsed;
    sem_count = 0;
    sem_exe = 1U;

    vTaskSuspend(xSemTask01Handle);
    vTaskResume(xSemTask01Handle);

    t_start = rheal_read_cycle();
    for (sem_count = 0; sem_count < RHEAL_SEM_BENCHMARKS; sem_count++) {
        xSemaphoreTake(xSemSemaphore, portMAX_DELAY);
        taskYIELD();
        xSemaphoreGive(xSemSemaphore);
        taskYIELD();
    }
    sem_elapsed = rheal_read_cycle() - t_start;

    rheal_print_time("Rhealstone: Semaphore Shuffle",
                     sem_elapsed,
                     RHEAL_SEM_BENCHMARKS * 2UL,
                     sem_switch_overhead,
                     0);

    vTaskDelete(xSemTask01Handle);
    vTaskDelete(NULL);
}

static void vSemBenchmarkInit(void *pvParameters)
{
    (void)pvParameters;

    sem_count = 0;
    sem_exe = 0U;

    xSemSemaphore = xSemaphoreCreateBinary();
    if (xSemSemaphore == NULL) {
        rheal_print_create_failed("rSemS");
        vTaskDelete(NULL);
    }
    xSemaphoreGive(xSemSemaphore);

    if (xTaskCreate(vSemTask01,
                    "rSem1",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xSemTask01Handle) != pdPASS) {
        rheal_print_create_failed("rSem1");
        vTaskDelete(NULL);
    }

    if (xTaskCreate(vSemTask02,
                    "rSem2",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xSemTask02Handle) != pdPASS) {
        rheal_print_create_failed("rSem2");
    }

    vTaskDelete(NULL);
}

void rhealstone_semaphore_shuffle_start(void)
{
    rheal_print_start("semaphore shuffle");

    if (xTaskCreate(vSemBenchmarkInit,
                    "rSem",
                    configMINIMAL_STACK_SIZE * 2,
                    NULL,
                    tskIDLE_PRIORITY + 3,
                    NULL) != pdPASS) {
        rheal_print_create_failed("rSem");
    }
}
