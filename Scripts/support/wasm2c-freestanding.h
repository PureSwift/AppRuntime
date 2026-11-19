/*
 * wasm2c-freestanding.h: the C library a wasm2c slice is compiled against
 * when wasm2c-shim.py builds it as a Linux libapp.so (build --slice).
 *
 * A libapp.so names no library, and leaves undefined only what a runner's
 * process supplies whatever its libc: rt.h, GLES 2.0, and the libc set of
 * DynamicRuntime.md §7.5. So the translated module, WABT's wasm-rt and the
 * shim can't be compiled against a libc's own headers: glibc's would put
 * __sigsetjmp, stderr and a pthread_mutex_t of its own size in the library.
 * They're compiled freestanding, for the triples guest.py compiles native
 * slices for, and every libc header they include is a one-line file that
 * includes this one (wasm2c-shim.py writes them).
 *
 * What's here:
 * - the libc set, declared: the only functions left undefined;
 * - what wasm-rt and the shim use beyond it, defined here or in
 *   wasm2c-freestanding.c, with the libc set and compiler builtins.
 *
 * The guest runs on one thread, the host's main one, so there are no
 * locks, and _Thread_local is compiled away (-D_Thread_local=): a library
 * with thread-local storage isn't a slice.
 */
#ifndef RT_WASM2C_FREESTANDING_H
#define RT_WASM2C_FREESTANDING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- The libc set (§7.5): supplied by the runner's process. ---- */

void *malloc(size_t size);
void free(void *pointer);
void *memcpy(void *destination, const void *source, size_t size);
void *memmove(void *destination, const void *source, size_t size);
void *memset(void *destination, int value, size_t size);
int memcmp(const void *left, const void *right, size_t size);
_Noreturn void abort(void);
long write(int fd, const void *data, size_t size);
int getentropy(void *buffer, size_t size);

/* The `clock_gettime` symbol takes two longs on every Linux this is built
 * for: on 32-bit ARM, glibc and musl give their 64-bit time another name. */
struct timespec {
    long tv_sec;
    long tv_nsec;
};
typedef int clockid_t;
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID 3
int clock_gettime(clockid_t clock, struct timespec *time);

/* ---- <stdlib.h>, <string.h>, <alloca.h> ---- */

/* calloc and realloc aren't in the set. realloc needs a block's size, so
 * every block these files allocate carries it: they never free a block
 * the host allocated, or hand the host one to free. */
void *rt_w2c_malloc(size_t size);
void *rt_w2c_calloc(size_t count, size_t size);
void *rt_w2c_realloc(void *pointer, size_t size);
void rt_w2c_free(void *pointer);
#define malloc(size) rt_w2c_malloc(size)
#define calloc(count, size) rt_w2c_calloc((count), (size))
#define realloc(pointer, size) rt_w2c_realloc((pointer), (size))
#define free(pointer) rt_w2c_free(pointer)

static inline size_t strlen(const char *string) {
    size_t length = 0;
    while (string[length]) {
        length++;
    }
    return length;
}

#define alloca(size) __builtin_alloca(size)

/* ---- <time.h> ---- */

/* Not in the set. Linux clocks count nanoseconds. */
static inline int clock_getres(clockid_t clock, struct timespec *resolution) {
    (void)clock;
    resolution->tv_sec = 0;
    resolution->tv_nsec = 1;
    return 0;
}

/* ---- <assert.h>, <stdio.h> ---- */

/* wasm-rt reports a failed allocation and then fails; the report is lost. */
#define assert(condition) ((void)0)
#define stderr 0
#define fprintf(...) ((void)0)
#define printf(...) ((void)0)
#define perror(message) ((void)0)

/* ---- <setjmp.h> ---- */

/* A setjmp no libc has to match: a libc's jmp_buf has its own size, and
 * glibc's setjmp its own symbol. */
#if defined(__aarch64__)
/* This compiler has no __builtin_setjmp for arm64, so the two are written
 * in assembly (wasm2c-freestanding.c): x19 to x30, sp, and d8 to d15. */
typedef uint64_t jmp_buf[21];
__attribute__((returns_twice)) int rt_w2c_setjmp(jmp_buf buffer);
_Noreturn void rt_w2c_longjmp(jmp_buf buffer, int value);
#define sigsetjmp(buffer, mask) rt_w2c_setjmp(buffer)
#define siglongjmp(buffer, value) rt_w2c_longjmp((buffer), (value))
#else
/* The compiler's own. It resumes with 1, so the value passed to longjmp,
 * a trap's reason, travels beside it. */
typedef void *jmp_buf[5];
extern int rt_w2c_jump_value;
#define sigsetjmp(buffer, mask) (__builtin_setjmp(buffer) ? rt_w2c_jump_value : 0)
#define siglongjmp(buffer, value) (rt_w2c_jump_value = (value), __builtin_longjmp((buffer), 1))
#endif
#define setjmp(buffer) sigsetjmp((buffer), 0)
#define longjmp(buffer, value) siglongjmp((buffer), (value))

/* ---- <pthread.h> ---- */

typedef int pthread_mutex_t;
#define pthread_mutex_init(mutex, attributes) ((void)(mutex), 0)
#define pthread_mutex_lock(mutex) ((void)(mutex), 0)
#define pthread_mutex_unlock(mutex) ((void)(mutex), 0)
#define pthread_mutex_destroy(mutex) ((void)(mutex), 0)

/* ---- <math.h> ---- */

/* Each is an instruction on arm64 and on x86_64 with SSE4.1. 32-bit ARM's
 * VFP rounds only in its current mode, so there the compiler calls the
 * function by name: wasm2c-freestanding.c defines those the slice's other
 * support (armv7-eabi.c) doesn't. */
#define NAN __builtin_nanf("")
#define INFINITY __builtin_inff()
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define signbit(x) __builtin_signbit(x)
#define fabs(x) __builtin_fabs(x)
#define fabsf(x) __builtin_fabsf(x)
#define copysign(x, y) __builtin_copysign((x), (y))
#define copysignf(x, y) __builtin_copysignf((x), (y))
#define sqrt(x) __builtin_elementwise_sqrt((double)(x))
#define sqrtf(x) __builtin_elementwise_sqrt((float)(x))
#define floor(x) __builtin_floor(x)
#define ceil(x) __builtin_ceil(x)
#define trunc(x) __builtin_trunc(x)
#define nearbyint(x) __builtin_nearbyint(x)
#define rint(x) __builtin_rint(x)
#define floorf(x) __builtin_floorf(x)
#define ceilf(x) __builtin_ceilf(x)
#define truncf(x) __builtin_truncf(x)
#define nearbyintf(x) __builtin_nearbyintf(x)
#define rintf(x) __builtin_rintf(x)
double rt_w2c_rint(double x);
double rt_w2c_trunc(double x);
double rt_w2c_floor(double x);
double rt_w2c_ceil(double x);
float rt_w2c_rintf(float x);
float rt_w2c_truncf(float x);
float rt_w2c_floorf(float x);
float rt_w2c_ceilf(float x);

#endif
