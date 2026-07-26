/*
 * Rhealstone: Intertask Message Latency Benchmark
 * Ported from RTEMS to FreeRTOS (RISC-V RV32IM target)
 *
 * 원본: javamonn/rtems-rhealstone / message-latency/message-latency.c
 *
 * 측정 내용:
 *   낮은 우선순위 태스크(TA01)가 큐에 메시지를 보내고
 *   높은 우선순위 태스크(TA02)가 수신할 때의 평균 메시지 전달 지연 시간
 */

#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include <stdio.h>
#include <stdint.h>

/* ─────────────────────────────────────────
 * 벤치마크 설정
 * ───────────────────────────────────────── */
#define BENCHMARKS      50000
#define MESSAGE_WORDS   4                          /* long 4개 = 16바이트 */
#define MESSAGE_SIZE    (MESSAGE_WORDS * sizeof(long))

/* ─────────────────────────────────────────
 * 타이머: RISC-V cycle CSR
 * ───────────────────────────────────────── */
static inline uint32_t read_cycle(void)
{
    uint32_t cycle;
    __asm__ volatile ("rdcycle %0" : "=r"(cycle));
    return cycle;
}

/* ─────────────────────────────────────────
 * 전역 변수
 * ───────────────────────────────────────── */
static TaskHandle_t xTask01Handle;
static TaskHandle_t xTask02Handle;
static QueueHandle_t xQueue;

static volatile uint32_t telapsed;
static volatile uint32_t tloop_overhead;
static volatile uint32_t treceive_overhead;
static volatile uint32_t count = 0;

static long Buffer[MESSAGE_WORDS];   /* 송수신 버퍼 */

static void put_time(const char *message,
                     uint32_t total_time,
                     uint32_t iterations,
                     uint32_t lp_overhead,
                     uint32_t dir_overhead)
{
    uint32_t avg = ((total_time - lp_overhead) / iterations) - dir_overhead;
    printf("%s - %lu cycles\n", message, (unsigned long)avg);
}

/* ─────────────────────────────────────────
 * Task01 (낮은 우선순위): 메시지 송신
 * ───────────────────────────────────────── */
static void vTask01(void *pvParameters)
{
    /* 수신 오버헤드 측정용 메시지 1개 먼저 전송 */
    xQueueSend(xQueue, Buffer, portMAX_DELAY);

    /* Task02 생성 (높은 우선순위) → 즉시 선점되어 Task02 실행 */
    xTaskCreate((TaskFunction_t)pvParameters,   /* Task02 함수 포인터 */
                "TA02",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 2,           /* 높은 우선순위 */
                &xTask02Handle);

    /* 본 벤치마크: 메시지 계속 전송 */
    for (; count < BENCHMARKS; count++) {
        xQueueSend(xQueue, Buffer, portMAX_DELAY);
    }

    /* 여기에 도달하면 안 됨 */
    configASSERT(0);
}

/* ─────────────────────────────────────────
 * Task02 (높은 우선순위): 메시지 수신 + 측정
 * ───────────────────────────────────────── */
static void vTask02(void *pvParameters)
{
    long rx_buf[MESSAGE_WORDS];
    uint32_t t_start;

    /* 수신 오버헤드 측정: 큐에 이미 메시지 있음 (태스크 전환 없이 즉시 수신) */
    t_start = read_cycle();
    xQueueReceive(xQueue, rx_buf, portMAX_DELAY);
    treceive_overhead = read_cycle() - t_start;

    /* 본 벤치마크 */
    t_start = read_cycle();
    for (count = 0; count < BENCHMARKS - 1; count++) {
        xQueueReceive(xQueue, rx_buf, portMAX_DELAY);
    }
    telapsed = read_cycle() - t_start;

    put_time(
        "Rhealstone: Intertask Message Latency",
        telapsed,
        BENCHMARKS - 1,
        tloop_overhead,
        treceive_overhead
    );

    vTaskDelete(xTask01Handle);
    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * Init 태스크
 * ───────────────────────────────────────── */
static void vMessageLatencyBenchmark(void *pvParameters)
{
    uint32_t t_start;

    /* 큐 생성: 메시지 1개 용량 (원본과 동일) */
    xQueue = xQueueCreate(1, MESSAGE_SIZE);

    /* 루프 오버헤드 측정 */
    t_start = read_cycle();
    for (count = 0; count < BENCHMARKS - 1; count++) {
        /* send/receive 없음 */
    }
    tloop_overhead = read_cycle() - t_start;
    count = 0;

    /* Task01 생성 (낮은 우선순위), Task02 함수 포인터를 인자로 전달 */
    xTaskCreate(vTask01,
                "TA01",
                configMINIMAL_STACK_SIZE,
                (void *)vTask02,
                tskIDLE_PRIORITY + 1,
                &xTask01Handle);

    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * main
 * ───────────────────────────────────────── */
int main(void)
{
    xTaskCreate(vMessageLatencyBenchmark,
                "INIT",
                configMINIMAL_STACK_SIZE * 2,
                NULL,
                tskIDLE_PRIORITY + 3,
                NULL);

    vTaskStartScheduler();

    for (;;);
    return 0;
}
