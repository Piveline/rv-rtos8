/*
 * Rhealstone: Deadlock Break Benchmark
 * Ported from RTEMS to FreeRTOS (RISC-V RV32IM target)
 *
 * 원본: javamonn/rtems-rhealstone / deadlock-break/deadlock-break.c
 *
 * 측정 내용:
 *   우선순위 역전 상황에서 데드락이 해소되는 데 걸리는 평균 시간
 *
 * 구조:
 *   TA03 (낮은 우선순위): 뮤텍스 보유
 *   TA02 (중간 우선순위): TA01을 깨움
 *   TA01 (높은 우선순위): 뮤텍스 획득 시도 → TA03 우선순위 상속 발생
 *
 * FreeRTOS Mutex는 우선순위 상속(Priority Inheritance)을 자동 지원함
 * → xSemaphoreCreateMutex() 사용
 */

#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include <stdio.h>
#include <stdint.h>

/* ─────────────────────────────────────────
 * 벤치마크 설정
 * ───────────────────────────────────────── */
#define BENCHMARKS  20000

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
static TaskHandle_t xTask01Handle;   /* 높은 우선순위 */
static TaskHandle_t xTask02Handle;   /* 중간 우선순위 */
static TaskHandle_t xTask03Handle;   /* 낮은 우선순위 — 뮤텍스 보유 */
static SemaphoreHandle_t xMutex;

static volatile uint32_t count = 0;
static volatile uint32_t telapsed;
static volatile uint32_t tswitch_overhead;
static volatile uint32_t tobtain_overhead;
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
 * Task01 (높은 우선순위): 뮤텍스 획득/해제 반복
 * ───────────────────────────────────────── */
static void vTask01(void *pvParameters)
{
    uint32_t t_start, t_end;

    t_start = read_cycle();

    for (count = 0; count < BENCHMARKS; count++) {
        if (sem_exe == 1) {
            /* 뮤텍스 획득 시도 — TA03이 보유 중이므로 우선순위 상속 발생 */
            xSemaphoreTake(xMutex, portMAX_DELAY);
        }
        if (sem_exe == 1) {
            xSemaphoreGive(xMutex);
        }
        /* TA02로 이동 */
        vTaskSuspend(NULL);
    }

    t_end = read_cycle();
    telapsed = t_end - t_start;

    if (sem_exe == 0) {
        /* 오버헤드만 측정 완료 */
        tswitch_overhead = telapsed;

        /* 태스크 재시작: sem_exe = 1 */
        sem_exe = 1;
        count = 0;
        vTaskSuspend(xTask02Handle);
        vTaskSuspend(xTask03Handle);

        /* 뮤텍스 다시 TA03에게 줌 */
        xSemaphoreTake(xMutex, portMAX_DELAY);  /* 혹시 남아있으면 비움 */
        xSemaphoreGive(xMutex);

        /* TA03 재시작 → TA03이 뮤텍스 잡고 TA02 깨움 */
        vTaskResume(xTask03Handle);
        vTaskSuspend(NULL);
    } else {
        put_time(
            "Rhealstone: Deadlock Break",
            telapsed,
            BENCHMARKS,
            tswitch_overhead,
            tobtain_overhead
        );
        vTaskDelete(xTask02Handle);
        vTaskDelete(xTask03Handle);
        vTaskDelete(NULL);
    }
}

/* ─────────────────────────────────────────
 * Task02 (중간 우선순위): TA01을 resume
 * ───────────────────────────────────────── */
static void vTask02(void *pvParameters)
{
    /* TA01 시작 → 즉시 선점됨 */
    vTaskResume(xTask01Handle);

    for (;;) {
        vTaskSuspend(NULL);
        vTaskResume(xTask01Handle);
    }
}

/* ─────────────────────────────────────────
 * Task03 (낮은 우선순위): 뮤텍스 보유 상태에서 TA02 깨움
 * ───────────────────────────────────────── */
static void vTask03(void *pvParameters)
{
    for (;;) {
        if (sem_exe == 1) {
            /* 낮은 우선순위 태스크가 뮤텍스 보유 → 우선순위 역전 상황 생성 */
            xSemaphoreTake(xMutex, portMAX_DELAY);
        }

        /* TA02 시작 → 선점됨 */
        vTaskResume(xTask02Handle);

        for (; count < BENCHMARKS; ) {
            if (sem_exe == 1) {
                /* 뮤텍스 해제 → TA01이 획득하며 선점 발생 */
                xSemaphoreGive(xMutex);
            }
            if (sem_exe == 1) {
                /* 다음 반복 준비 */
                xSemaphoreTake(xMutex, portMAX_DELAY);
            }
            vTaskResume(xTask02Handle);
        }
    }
}

/* ─────────────────────────────────────────
 * Init 태스크
 * ───────────────────────────────────────── */
static void vDeadlockBenchmark(void *pvParameters)
{
    uint32_t t_start;

    /* 우선순위 상속 뮤텍스 생성 */
    xMutex = xSemaphoreCreateMutex();

    /* 뮤텍스 obtain 오버헤드 측정 */
    t_start = read_cycle();
    xSemaphoreTake(xMutex, portMAX_DELAY);
    tobtain_overhead = read_cycle() - t_start;
    xSemaphoreGive(xMutex);

    /*
     * 우선순위 할당 (FreeRTOS: 높은 숫자 = 높은 우선순위)
     * RTEMS 원본: TA01=26(높), TA02=28(중), TA03=30(낮)
     */
    xTaskCreate(vTask01, "TA01", configMINIMAL_STACK_SIZE, NULL,
                tskIDLE_PRIORITY + 3, &xTask01Handle);  /* 높은 우선순위 */

    xTaskCreate(vTask02, "TA02", configMINIMAL_STACK_SIZE, NULL,
                tskIDLE_PRIORITY + 2, &xTask02Handle);  /* 중간 우선순위 */

    xTaskCreate(vTask03, "TA03", configMINIMAL_STACK_SIZE, NULL,
                tskIDLE_PRIORITY + 1, &xTask03Handle);  /* 낮은 우선순위 */

    /* 처음엔 TA01, TA02 suspend 상태로 시작 — TA03이 먼저 뮤텍스 획득 */
    vTaskSuspend(xTask01Handle);
    vTaskSuspend(xTask02Handle);

    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * main
 * ───────────────────────────────────────── */
int main(void)
{
    xTaskCreate(vDeadlockBenchmark,
                "INIT",
                configMINIMAL_STACK_SIZE * 2,
                NULL,
                tskIDLE_PRIORITY + 4,
                NULL);

    vTaskStartScheduler();

    for (;;);
    return 0;
}
