/*
 * Rhealstone: Task Preempt Benchmark
 * Ported from RTEMS to FreeRTOS (RISC-V RV32IM target)
 *
 * 원본: javamonn/rtems-rhealstone / task-preempt/task-preempt.c
 *
 * 측정 내용:
 *   낮은 우선순위 태스크(TA01)가 높은 우선순위 태스크(TA02)를 resume할 때
 *   선점(preemption)이 발생하는 데 걸리는 평균 시간 (CPU 사이클)
 *
 * 수정 이력:
 *   - t_start를 전역 변수로 변경 (태스크 간 공유 필요)
 *   - 함수 포인터 전달 방식 → 전방 선언 방식으로 변경 (가독성 향상)
 */

#include "FreeRTOS.h"
#include "task.h"
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
 * 전역 변수 (태스크 간 공유를 위해 전역으로 선언)
 * ───────────────────────────────────────── */
static TaskHandle_t xTask01Handle;
static TaskHandle_t xTask02Handle;

static volatile uint32_t t_start;          /* 측정 시작 시각 — 두 태스크가 공유 */
static volatile uint32_t tloop_overhead;   /* 루프 오버헤드 */
static volatile uint32_t tswitch_overhead; /* TA02→TA01 단순 전환 오버헤드 */
static volatile uint32_t count1 = 0;

/* 태스크 함수 전방 선언 */
static void vTask01(void *pvParameters);
static void vTask02(void *pvParameters);

static void put_time(const char *message,
                     uint32_t total_time,
                     uint32_t iterations,
                     uint32_t lp_overhead,
                     uint32_t overhead)
{
    uint32_t avg = ((total_time - lp_overhead) / iterations) - overhead;
    printf("%s - %lu cycles\n", message, (unsigned long)avg);
}

/* ─────────────────────────────────────────
 * Task01 (낮은 우선순위): TA02를 깨워서 선점을 유도
 * ───────────────────────────────────────── */
static void vTask01(void *pvParameters)
{
    /* Task02 생성 (높은 우선순위) — 생성 즉시 TA02가 실행됨 */
    xTaskCreate(vTask02,
                "TA02",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 2,
                &xTask02Handle);

    /* TA02가 t_start를 찍고 suspend된 후 여기로 돌아옴
     * → t_start는 전역이므로 TA02가 찍은 값을 그대로 읽을 수 있음 */
    tswitch_overhead = read_cycle() - t_start;

    /* 본 벤치마크 시작 */
    t_start = read_cycle();
    for (count1 = 0; count1 < BENCHMARKS; count1++) {
        vTaskResume(xTask02Handle);   /* TA02 깨우기 → 즉시 선점 발생 */
    }

    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * Task02 (높은 우선순위): 깨어나자마자 다시 잠듦
 * ───────────────────────────────────────── */
static void vTask02(void *pvParameters)
{
    uint32_t t_elapsed;

    /* TA02→TA01 단순 전환 비용 측정용: t_start 찍고 바로 suspend */
    t_start = read_cycle();
    vTaskSuspend(NULL);

    /* 본 벤치마크 루프: TA01이 Resume할 때마다 한 번씩 돔 */
    for (; count1 < BENCHMARKS - 1; ) {
        vTaskSuspend(NULL);
    }

    t_elapsed = read_cycle() - t_start;

    put_time(
        "Rhealstone: Task Preempt",
        t_elapsed,
        BENCHMARKS - 1,
        tloop_overhead,
        tswitch_overhead
    );

    vTaskDelete(xTask01Handle);
    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * Init 태스크: 루프 오버헤드 측정 후 TA01 생성
 * ───────────────────────────────────────── */
static void vTaskPreemptBenchmark(void *pvParameters)
{
    uint32_t t_init;

    /* 루프 오버헤드 측정 (전역 t_start와 구분하기 위해 지역 변수 사용) */
    t_init = read_cycle();
    for (count1 = 0; count1 < (BENCHMARKS * 2) - 1; count1++) {
        /* vTaskResume 없음 */
    }
    tloop_overhead = read_cycle() - t_init;
    count1 = 0;

    /* Task01 생성 (낮은 우선순위) */
    xTaskCreate(vTask01,
                "TA01",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 1,
                &xTask01Handle);

    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * main
 * ───────────────────────────────────────── */
int main(void)
{
    xTaskCreate(vTaskPreemptBenchmark,
                "INIT",
                configMINIMAL_STACK_SIZE * 2,
                NULL,
                tskIDLE_PRIORITY + 3,
                NULL);

    vTaskStartScheduler();

    for (;;);
    return 0;
}
