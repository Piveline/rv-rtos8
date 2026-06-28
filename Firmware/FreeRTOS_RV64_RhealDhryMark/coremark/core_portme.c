/*
 * core_portme.c - CoreMark porting layer for RV64I
 *
 * Implements timing using mcycle CSR
 */

#include "coremark.h"
#include "core_portme.h"

/* Volatile seed variables for SEED_VOLATILE method */
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* ============================================================
 * CSR read helper for mcycle (64-bit cycle counter)
 * On RV64, mcycle is a full 64-bit register
 * ============================================================ */
static inline ee_u64 csr_read_mcycle(void) {
    ee_u64 v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

static inline ee_u32 read_mcycle32(void) {
    return (ee_u32)csr_read_mcycle();
}

/* ============================================================
 * Timing implementation using mcycle CSR
 * ============================================================ */

/* Timer resolution: 50MHz = 50,000,000 ticks per second
 * Adjust this value for your hardware clock frequency
 */
#define EE_TICKS_PER_SEC 39583330

static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void)
{
    start_time_val = read_mcycle32();
}

void stop_time(void)
{
    stop_time_val = read_mcycle32();
}

CORE_TICKS get_time(void)
{
    CORE_TICKS elapsed = (CORE_TICKS)(stop_time_val - start_time_val);
    return elapsed;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = (secs_ret)(ticks / EE_TICKS_PER_SEC);
    return retval;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }

    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

void *portable_malloc(ee_size_t size)
{
    (void)size;
    return NULL;
}

void portable_free(void *p)
{
    (void)p;
}

/* Note: get_seed_32 is defined in core_util.c when SEED_METHOD == SEED_VOLATILE */
