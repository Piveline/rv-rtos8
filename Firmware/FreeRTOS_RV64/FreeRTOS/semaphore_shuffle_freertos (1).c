/*
 * Rhealstone: Semaphore Shuffle Benchmark
 * Ported from RTEMS to FreeRTOS (RISC-V RV32IM target)
 *
 * 원본: javamonn/rtems-rhealstone / semaphore-shuffle/semaphore-shuffle.c
 *
 * 측정 내용:
 *   두 태스크가 바이너리 세마포어를 주고받으며 전환될 때
 *   세마포어 1회 shuffle에 걸리는 평균 시간 (CPU 사이클)
 *
 * 방법:
 *   1단계) 세마포어 없이 태스크 전환만 측정 → tswitch_overhead 확보
 *   2단계) 세마포어 포함하여 측정 → 차이가 순수 세마포어 비용
 */

#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include <stdio.h>
#include <stdint.h>

/* ─────────────────────────────────────────
 * 벤치마크 설정
 * ───────────────────────────────────────── */
#define BENCHMARKS  50000

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
static SemaphoreHandle_t xSemaphore;

static volatile uint32_t telapsed;
static volatile uint32_t tswitch_overhead;
static volatile uint32_t count = 0;
static volatile uint32_t sem_exe = 0;   /* 0: 오버헤드 측정, 1: 본 벤치마크 */

static void put_time(const char *message,
                     uint32_t total_time,
                     uint32_t iterations,
                     uint32_t overhead,
                     uint32_t dir_overhead)
{
    uint32_t avg = ((total_time - overhead) / iterations) - dir_overhead;
    printf("%s - %lu cycles\n", message, (unsigned long)avg);
}

/* ─────────────────────────────────────────
 * Task01: 세마포어 obtain → yield → release → yield 반복
 * ───────────────────────────────────────── */
static void vTask01(void *pvParameters)
{
    for (;;) {
        if (sem_exe == 1) {
            xSemaphoreTake(xSemaphore, portMAX_DELAY);
        }
        taskYIELD();

        if (sem_exe == 1) {
            xSemaphoreGive(xSemaphore);
        }
        taskYIELD();
    }
}

/* ─────────────────────────────────────────
 * Task02: 타이머 측정 주체
 * ───────────────────────────────────────── */
static void vTask02(void *pvParameters)
{
    uint32_t t_start;

    t_start = read_cycle();
    for (count = 0; count < BENCHMARKS; count++) {
        if (sem_exe == 1) {
            xSemaphoreTake(xSemaphore, portMAX_DELAY);
        }
        taskYIELD();

        if (sem_exe == 1) {
            xSemaphoreGive(xSemaphore);
        }
        taskYIELD();
    }
    telapsed = read_cycle() - t_start;

    if (sem_exe == 0) {
        /* 1단계 완료: 태스크 전환 오버헤드 저장 후 재시작 */
        tswitch_overhead = telapsed;
        count = 0;
        sem_exe = 1;

        /* 두 태스크 모두 재시작 */
        vTaskSuspend(xTask01Handle);
        /* Task01을 다시 resume — sem_exe=1로 본 벤치마크 시작 */
        vTaskResume(xTask01Handle);

        /* Task02 자신도 다시 루프 */
        t_start = read_cycle();
        for (count = 0; count < BENCHMARKS; count++) {
            xSemaphoreTake(xSemaphore, portMAX_DELAY);
            taskYIELD();
            xSemaphoreGive(xSemaphore);
            taskYIELD();
        }
        telapsed = read_cycle() - t_start;

        put_time(
            "Rhealstone: Semaphore Shuffle",
            telapsed,
            BENCHMARKS * 2,       /* 총 세마포어 shuffle 횟수 */
            tswitch_overhead,     /* 루프 + 태스크 전환 오버헤드 */
            0
        );

        vTaskDelete(xTask01Handle);
        vTaskDelete(NULL);
    }
}

/* ─────────────────────────────────────────
 * Init 태스크
 * ───────────────────────────────────────── */
static void vSemShuffleBenchmark(void *pvParameters)
{
    /* 바이너리 세마포어 생성 (초기값 1 = available) */
    xSemaphore = xSemaphoreCreateBinary();
    xSemaphoreGive(xSemaphore);   /* 초기값 1로 설정 */

    /* 두 태스크 동일 우선순위로 생성 */
    xTaskCreate(vTask01,
                "TA01",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 1,
                &xTask01Handle);

    xTaskCreate(vTask02,
                "TA02",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 1,
                &xTask02Handle);

    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * main
 * ───────────────────────────────────────── */
int main(void)
{
    xTaskCreate(vSemShuffleBenchmark,
                "INIT",
                configMINIMAL_STACK_SIZE * 2,
                NULL,
                tskIDLE_PRIORITY + 2,
                NULL);

    vTaskStartScheduler();

    for (;;);
    return 0;
}
