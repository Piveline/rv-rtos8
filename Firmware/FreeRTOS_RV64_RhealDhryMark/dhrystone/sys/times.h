#ifndef _SYS_TIMES_H
#define _SYS_TIMES_H

/* Shadow header to keep Dhrystone 2.1 unmodified.
 *
 * Dhrystone 2.1 (dhry_1.c) uses K&R-style declaration:
 *   extern int times();
 * and dhry.h includes <sys/times.h>.
 *
 * Newlib's <sys/times.h> declares a prototyped function returning clock_t,
 * which conflicts with the K&R declaration and causes a compile error.
 *
 * So we provide only:
 *  - struct tms definition
 *  - K&R-style declaration for times()
 */

#ifdef __cplusplus
extern "C" {
#endif

struct tms {
    long tms_utime;
    long tms_stime;
    long tms_cutime;
    long tms_cstime;
};

/* K&R-style (no prototype) */
int times();

#ifdef __cplusplus
}
#endif

#endif /* _SYS_TIMES_H */
