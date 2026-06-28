/*
 * Rhealstone: Interrupt Latency Benchmark
 * Ported from RTEMS to FreeRTOS (RISC-V RV32IM target)
 *
 * 원본: javamonn/rtems-rhealstone / interrupt-latency/interrupt-latency.c
 *
 * 측정 내용:
 *   인터럽트 발생 시점부터 ISR 진입까지 걸리는 시간 (CPU 사이클)
 *
 * 동작 원리 (우리 SoC 기준):
 *   1. rdcycle로 시작 시각 기록
 *   2. CLINT mtimecmp를 mtime+1로 설정 → 즉시 타이머 인터럽트 발생
 *   3. ISR 진입 즉시 rdcycle로 종료 시각 기록
 *   4. 차이 = 인터럽트 지연시간
 *
 * CLINT 메모리 맵 (CLINT.v 기준):
 *   0x0200_0000 : mtime    low  32bit
 *   0x0200_0004 : mtime    high 32bit
 *   0x0200_0008 : mtimecmp low  32bit
 *   0x0200_000C : mtimecmp high 32bit
 */

#include "FreeRTOS.h"
#include "task.h"
#include <stdio.h>
#include <stdint.h>

/* ─────────────────────────────────────────
 * CLINT 레지스터 주소 (CLINT.v 메모리맵 기준)
 * ───────────────────────────────────────── */
#define CLINT_BASE          0x02000000UL
#define CLINT_MTIME_LO      (*(volatile uint32_t *)(CLINT_BASE + 0x00))
#define CLINT_MTIME_HI      (*(volatile uint32_t *)(CLINT_BASE + 0x04))
#define CLINT_MTIMECMP_LO   (*(volatile uint32_t *)(CLINT_BASE + 0x08))
#define CLINT_MTIMECMP_HI   (*(volatile uint32_t *)(CLINT_BASE + 0x0C))

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
 * CSR 접근 헬퍼
 * ───────────────────────────────────────── */
/* MIE (Machine Interrupt Enable) 비트 마스크 */
#define MIE_MTIE    (1 << 7)   /* Machine Timer Interrupt Enable */

static inline void enable_machine_timer_interrupt(void)
{
    __asm__ volatile (
        "csrrs zero, mie, %0"
        :: "r"(MIE_MTIE)
    );
}

static inline void disable_machine_timer_interrupt(void)
{
    __asm__ volatile (
        "csrrc zero, mie, %0"
        :: "r"(MIE_MTIE)
    );
}

static inline void enable_global_interrupt(void)
{
    __asm__ volatile ("csrsi mstatus, 0x8");
}

static inline void disable_global_interrupt(void)
{
    __asm__ volatile ("csrci mstatus, 0x8");
}

/* ─────────────────────────────────────────
 * 전역 변수
 * ───────────────────────────────────────── */
static volatile uint32_t isr_enter_time;    /* ISR 진입 시각 */
static volatile uint32_t intr_trigger_time; /* 인터럽트 트리거 시각 */
static volatile uint32_t timer_overhead;    /* rdcycle 자체 오버헤드 */
static volatile uint32_t total_latency = 0;
static volatile uint32_t bench_count = 0;
static volatile uint8_t  bench_done = 0;

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
 * 타이머 인터럽트 핸들러
 *
 * FreeRTOS RISC-V 포트에서 타이머 인터럽트는
 * vPortSetupTimerInterrupt()에서 등록된 핸들러가 처리함.
 * 벤치마크용으로 아래 함수를 FreeRTOS 포트의 타이머 ISR 내부에서
 * bench_count가 BENCHMARKS 미만일 때 호출되도록 연결해야 함.
 *
 * 또는 FreeRTOS의 vApplicationTickHook()을 활용할 수도 있음.
 * ───────────────────────────────────────── */
void vBenchmarkTimerISR(void)
{
    /* ISR 진입 즉시 사이클 읽기 */
    isr_enter_time = read_cycle();

    /* 인터럽트 클리어: mtimecmp를 최댓값으로 설정 */
    CLINT_MTIMECMP_HI = 0xFFFFFFFFUL;
    CLINT_MTIMECMP_LO = 0xFFFFFFFFUL;

    if (bench_count < BENCHMARKS) {
        total_latency += (isr_enter_time - intr_trigger_time);
        bench_count++;
    } else {
        bench_done = 1;
    }
}

/* ─────────────────────────────────────────
 * 인터럽트 즉시 트리거:
 *   mtimecmp = mtime + 1 → 다음 클럭에 인터럽트 발생
 * ───────────────────────────────────────── */
static void trigger_timer_interrupt(void)
{
    uint32_t mtime_lo = CLINT_MTIME_LO;

    /* mtimecmp를 현재 mtime + 1로 설정 */
    CLINT_MTIMECMP_HI = 0UL;
    CLINT_MTIMECMP_LO = mtime_lo + 1;

    /* 트리거 시각 기록 (mtimecmp 설정 직후) */
    intr_trigger_time = read_cycle();
}

/* ─────────────────────────────────────────
 * 벤치마크 태스크
 * ───────────────────────────────────────── */
static void vInterruptLatencyTask(void *pvParameters)
{
    uint32_t t_start;

    /* rdcycle 오버헤드 측정 */
    t_start = read_cycle();
    timer_overhead = read_cycle() - t_start;

    /* 타이머 인터럽트 활성화 */
    enable_machine_timer_interrupt();
    enable_global_interrupt();

    /* 벤치마크 루프 */
    while (bench_count < BENCHMARKS) {
        trigger_timer_interrupt();

        /* ISR가 처리할 때까지 대기 */
        while (CLINT_MTIMECMP_LO != 0xFFFFFFFFUL) {
            /* ISR가 mtimecmp를 최댓값으로 바꿀 때까지 대기 */
        }
    }

    /* 인터럽트 비활성화 */
    disable_machine_timer_interrupt();

    put_time(
        "Rhealstone: Interrupt Latency",
        total_latency,
        BENCHMARKS,
        timer_overhead * BENCHMARKS,   /* 루프 전체 오버헤드 */
        0
    );

    vTaskDelete(NULL);
}

/* ─────────────────────────────────────────
 * main
 * ───────────────────────────────────────── */
int main(void)
{
    xTaskCreate(vInterruptLatencyTask,
                "INTR",
                configMINIMAL_STACK_SIZE * 2,
                NULL,
                tskIDLE_PRIORITY + 1,
                NULL);

    vTaskStartScheduler();

    for (;;);
    return 0;
}
