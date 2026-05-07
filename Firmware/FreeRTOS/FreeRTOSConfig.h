#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

// ============================================================================
// FreeRTOSConfig.h — RV32IM SoC (Nexys Video)
// ============================================================================

// --- Hardware ---
#define configCPU_CLOCK_HZ              1000UL
#define configTICK_RATE_HZ              1000UL
#define configMTIME_BASE_ADDRESS        0x02000000UL
#define configMTIMECMP_BASE_ADDRESS     0x02000008UL

// --- Kernel ---
#define configUSE_PREEMPTION            1
#define configUSE_TIME_SLICING          1
#define configMAX_PRIORITIES            5
#define configMINIMAL_STACK_SIZE        256
#define configMAX_TASK_NAME_LEN         16
#define configUSE_16_BIT_TICKS          0
#define configIDLE_SHOULD_YIELD         1

// --- Memory ---
#define configTOTAL_HEAP_SIZE           ( ( size_t ) ( 16 * 1024 ) )
#define configSUPPORT_STATIC_ALLOCATION     0
#define configSUPPORT_DYNAMIC_ALLOCATION    1

// --- ISR Stack ---
#define configISR_STACK_SIZE_WORDS      512

// --- Hook functions ---
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configUSE_MALLOC_FAILED_HOOK    0
#define configCHECK_FOR_STACK_OVERFLOW  0

// --- Software features ---
#define configUSE_MUTEXES               1
#define configUSE_RECURSIVE_MUTEXES     0
#define configUSE_COUNTING_SEMAPHORES   0
#define configUSE_QUEUE_SETS            0
#define configUSE_TASK_NOTIFICATIONS    1
#define configUSE_TRACE_FACILITY        0
#define configUSE_STATS_FORMATTING_FUNCTIONS 0

// --- Timer ---
#define configUSE_TIMERS                0
#define configTIMER_TASK_PRIORITY       2
#define configTIMER_QUEUE_LENGTH        5
#define configTIMER_TASK_STACK_DEPTH    configMINIMAL_STACK_SIZE

// --- Co-routine (unused) ---
#define configUSE_CO_ROUTINES           0
#define configMAX_CO_ROUTINE_PRIORITIES 1

// --- API includes ---
#define INCLUDE_vTaskPrioritySet        0
#define INCLUDE_uxTaskPriorityGet       0
#define INCLUDE_vTaskDelete             0
#define INCLUDE_vTaskCleanUpResources   0
#define INCLUDE_vTaskSuspend            1
#define INCLUDE_vTaskDelayUntil         1
#define INCLUDE_vTaskDelay              1
#define INCLUDE_xTaskGetSchedulerState  1

#endif // FREERTOS_CONFIG_H
