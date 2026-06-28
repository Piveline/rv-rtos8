/*
 * Rhealstone: Task Switch Benchmark
 * Ported from RTEMS to FreeRTOS (RISC-V RV32IM target)
 *
 * 원본: javamonn/rtems-rhealstone / task-switch/task-switch.c
 *
 * 측정 내용:
 *   동일 우선순위 태스크 두 개가 서로 yield하며 전환될 때
 *   1회 태스크 전환에 걸리는 평균 시간 (CPU 사이클)
 */

#include "FreeRTOS.h"
#include "task.h"
#include <stdio.h>
#include <stdint.h>

/* ─────────────────────────────────────────
 * 벤치마크 설정
 * ───────────────────────────────────────── */
#define BENCHMARKS      50000

/* ─────────────────────────────────────────
 * 타이머: RISC-V cycle CSR 사용
 *   rdcycle 명령어로 CPU 사이클 카운터 읽기
 *   (머신 모드에서 mcycle CSR 접근 가능해야 함)
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

static volatile uint32_t loop_overhead;   /* 루프 오버헤드 */
static volatile uint32_t dir_overhead;    /* taskYIELD 자체 오버헤드 */
static volatile uint32_t count1 = 0;
static volatile uint32_t count2 = 0;

/* ─────────────────────────────────────────
 * put_time: 결과 출력 (원본 timesys.h의 매크로와 동일한 계산)
 *   평균 시간 = (전체 시간 - 루프 오버헤드) / 반복 횟수 - 지시어 오버헤드
 * ───────────────────────────────────────── */
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
 * Task02: 벤치마크 실행 후 결과 출력
 * ───────────────────────────────────────── */
static void vTask02(void *pvParameters)
{
    uint32_t t_start, t_elapsed;

    /* 오버헤드 측정 완료 후 본 벤치마크 시작 */
    t_start = read_cycle();

    for (count1 = 0; count1 < BENCHMARKS - 1; count1++) {
        taskYIELD();   /* ← rtems_task_wake_after(RTEMS_YIELD_PROCESSOR) 대응 */
    }

    t_elapsed = read_cycle() - t_start;

    put_time(
        "Rhealstone: Task switch",
        t_elapsed,
        (BENCHMARKS * 2) - 1,   /* 총 전환 횟수 */
        loop_overhead,
        dir_overhead
    );

    /* 완료 — 두 태스크 모두 삭제 */
    vTaskDelete(xTask01Handle);
    vTaskDelete(NULL);           /* 자기 자신 삭제 */
}

/* ─────────────────────────────────────────
 * Task01: Task02 생성 후 함께 yield 반복
 * ───────────────────────────────────────── */
static void vTask01(void *pvParameters)
{
    /* Task02 생성 (동일 우선순위) */
    xTaskCreate(vTask02,
                "TA02",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 1,   /* Task01과 동일 우선순위 */
                &xTask02Handle);

    /* Task02가 먼저 실행될 수 있도록 한 번 양보 */
    taskYIELD();

    for (count2 = 0; count2 < BENCHMARKS; count2++) {
        taskYIELD();
    }

    /* 여기에 도달하면 안 됨 */
    configASSERT(0);
}

/* ─────────────────────────────────────────
 * vTaskSwitchBenchmark: Init 역할
 *   오버헤드 측정 후 Task01 생성
 * ───────────────────────────────────────── */
void vTaskSwitchBenchmark(void *pvParameters)
{
    uint32_t t_start;

    /* ── 루프 오버헤드 측정 (실제 yield 없이 루프만) ── */
    t_start = read_cycle();
    for (count1 = 0; count1 < BENCHMARKS - 1; count1++) {
        /* taskYIELD() 없음 — 루프 자체 비용만 측정 */
    }
    for (count2 = 0; count2 < BENCHMARKS; count2++) {
        /* 마찬가지 */
    }
    loop_overhead = read_cycle() - t_start;

    /* ── taskYIELD 호출 1회 오버헤드 측정 ── */
    t_start = read_cycle();
    taskYIELD();
    dir_overhead = read_cycle() - t_start;

    /* ── Task01 생성 ── */
    xTaskCreate(vTask01,
                "TA01",
                configMINIMAL_STACK_SIZE,
                NULL,
                tskIDLE_PRIORITY + 1,
                &xTask01Handle);

    /* Init 태스크 삭제 (RTEMS의 rtems_task_delete(RTEMS_SELF) 대응) */
    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * main: 스케줄러 시작
 * ───────────────────────────────────────── */
int main(void)
{
    /* 보드 초기화 (BSP에 맞게 수정) */
    /* bsp_init(); */

    xTaskCreate(vTaskSwitchBenchmark,
                "INIT",
                configMINIMAL_STACK_SIZE * 2,
                NULL,
                tskIDLE_PRIORITY + 2,   /* 다른 태스크보다 높은 우선순위로 먼저 실행 */
                NULL);

    vTaskStartScheduler();

    /* 여기에 도달하면 안 됨 */
    for (;;);
    return 0;
}
