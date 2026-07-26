/*
 * Rhealstone: Intertask Message Latency Benchmark
 * FreeRTOS shell-command version for the RV64 FreeRTOS SoC.
 */

#include "rhealstone_io.h"
#include "queue.h"

#define RHEAL_MSG_BENCHMARKS    50000UL
#define RHEAL_MSG_WORDS         4U
#define RHEAL_MSG_SIZE          (RHEAL_MSG_WORDS * sizeof(long))

static TaskHandle_t xMsgTask01Handle;
static TaskHandle_t xMsgTask02Handle;
static QueueHandle_t xMsgQueue;

static volatile rheal_cycles_t msg_elapsed;
static volatile rheal_cycles_t msg_loop_overhead;
static volatile rheal_cycles_t msg_receive_overhead;
static volatile uint32_t msg_count = 0;

static long msg_buffer[RHEAL_MSG_WORDS];

static void vMsgTask02(void *pvParameters)
{
    (void)pvParameters;
    long rx_buf[RHEAL_MSG_WORDS];
    rheal_cycles_t t_start;

    t_start = rheal_read_cycle();
    xQueueReceive(xMsgQueue, rx_buf, portMAX_DELAY);
    msg_receive_overhead = rheal_read_cycle() - t_start;

    t_start = rheal_read_cycle();
    for (msg_count = 0; msg_count < RHEAL_MSG_BENCHMARKS - 1UL; msg_count++) {
        xQueueReceive(xMsgQueue, rx_buf, portMAX_DELAY);
    }
    msg_elapsed = rheal_read_cycle() - t_start;

    rheal_print_time("Rhealstone: Intertask Message Latency",
                     msg_elapsed,
                     RHEAL_MSG_BENCHMARKS - 1UL,
                     msg_loop_overhead,
                     msg_receive_overhead);

    vTaskDelete(xMsgTask01Handle);
    vTaskDelete(NULL);
}

static void vMsgTask01(void *pvParameters)
{
    (void)pvParameters;

    xQueueSend(xMsgQueue, msg_buffer, portMAX_DELAY);

    if (xTaskCreate(vMsgTask02,
                    "rMsg2",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 3,
                    &xMsgTask02Handle) != pdPASS) {
        rheal_print_create_failed("rMsg2");
        vTaskDelete(NULL);
    }

    for (; msg_count < RHEAL_MSG_BENCHMARKS; msg_count++) {
        xQueueSend(xMsgQueue, msg_buffer, portMAX_DELAY);
    }

    shell_puts("[rheal] message latency reached unexpected path\n");
    vTaskDelete(NULL);
}

static void vMsgBenchmarkInit(void *pvParameters)
{
    (void)pvParameters;
    rheal_cycles_t t_start;

    xMsgQueue = xQueueCreate(1, RHEAL_MSG_SIZE);
    if (xMsgQueue == NULL) {
        rheal_print_create_failed("rMsgQ");
        vTaskDelete(NULL);
    }

    t_start = rheal_read_cycle();
    for (msg_count = 0; msg_count < RHEAL_MSG_BENCHMARKS - 1UL; msg_count++) {
    }
    msg_loop_overhead = rheal_read_cycle() - t_start;
    msg_count = 0;

    for (uint32_t i = 0; i < RHEAL_MSG_WORDS; i++) {
        msg_buffer[i] = (long)i;
    }

    if (xTaskCreate(vMsgTask01,
                    "rMsg1",
                    configMINIMAL_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xMsgTask01Handle) != pdPASS) {
        rheal_print_create_failed("rMsg1");
    }

    vTaskDelete(NULL);
}

void rhealstone_message_latency_start(void)
{
    rheal_print_start("message latency");

    if (xTaskCreate(vMsgBenchmarkInit,
                    "rMsg",
                    configMINIMAL_STACK_SIZE * 2,
                    NULL,
                    tskIDLE_PRIORITY + 4,
                    NULL) != pdPASS) {
        rheal_print_create_failed("rMsg");
    }
}
