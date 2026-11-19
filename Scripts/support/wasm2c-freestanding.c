/*
 * wasm2c-freestanding.c: what wasm2c-freestanding.h declares and doesn't
 * define inline. Compiled into a wasm2c slice built as a Linux libapp.so,
 * and sealed in with it.
 */
#include "wasm2c-freestanding.h"

#if defined(__aarch64__) && defined(__ELF__)
/* setjmp and longjmp for arm64: the registers a call preserves, and where
 * it returns to. longjmp returns from setjmp again, with `value`, or 1 for
 * 0. It returns with `ret`, which a process that checks branch targets
 * allows from anywhere. */
__asm__(
    "    .text\n"
    "    .balign 4\n"
    "    .hidden rt_w2c_setjmp\n"
    "    .globl rt_w2c_setjmp\n"
    "    .type rt_w2c_setjmp, %function\n"
    "rt_w2c_setjmp:\n"
    "    stp x19, x20, [x0, #0]\n"
    "    stp x21, x22, [x0, #16]\n"
    "    stp x23, x24, [x0, #32]\n"
    "    stp x25, x26, [x0, #48]\n"
    "    stp x27, x28, [x0, #64]\n"
    "    stp x29, x30, [x0, #80]\n"
    "    mov x2, sp\n"
    "    str x2, [x0, #96]\n"
    "    stp d8, d9, [x0, #104]\n"
    "    stp d10, d11, [x0, #120]\n"
    "    stp d12, d13, [x0, #136]\n"
    "    stp d14, d15, [x0, #152]\n"
    "    mov w0, #0\n"
    "    ret\n"
    "    .size rt_w2c_setjmp, .-rt_w2c_setjmp\n"
    "    .hidden rt_w2c_longjmp\n"
    "    .globl rt_w2c_longjmp\n"
    "    .type rt_w2c_longjmp, %function\n"
    "rt_w2c_longjmp:\n"
    "    ldp x19, x20, [x0, #0]\n"
    "    ldp x21, x22, [x0, #16]\n"
    "    ldp x23, x24, [x0, #32]\n"
    "    ldp x25, x26, [x0, #48]\n"
    "    ldp x27, x28, [x0, #64]\n"
    "    ldp x29, x30, [x0, #80]\n"
    "    ldr x2, [x0, #96]\n"
    "    mov sp, x2\n"
    "    ldp d8, d9, [x0, #104]\n"
    "    ldp d10, d11, [x0, #120]\n"
    "    ldp d12, d13, [x0, #136]\n"
    "    ldp d14, d15, [x0, #152]\n"
    "    cmp w1, #0\n"
    "    csinc w0, w1, wzr, ne\n"
    "    ret\n"
    "    .size rt_w2c_longjmp, .-rt_w2c_longjmp\n"
);
#elif !defined(__aarch64__)
/* The value given to longjmp, for setjmp to return. */
int rt_w2c_jump_value;
#endif

/* ---- Allocation ---- */

/* A block's size is kept ahead of it, in a header as wide as malloc's
 * alignment, so the block stays aligned for anything. */
#undef malloc
#undef free
#define RT_W2C_HEADER 16

void *rt_w2c_malloc(size_t size) {
    if (size > SIZE_MAX - RT_W2C_HEADER) {
        return NULL;
    }
    size_t *block = malloc(size + RT_W2C_HEADER);
    if (!block) {
        return NULL;
    }
    *block = size;
    return (char *)block + RT_W2C_HEADER;
}

void rt_w2c_free(void *pointer) {
    if (pointer) {
        free((char *)pointer - RT_W2C_HEADER);
    }
}

void *rt_w2c_calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) {
        return NULL;
    }
    void *pointer = rt_w2c_malloc(count * size);
    if (pointer) {
        memset(pointer, 0, count * size);
    }
    return pointer;
}

void *rt_w2c_realloc(void *pointer, size_t size) {
    if (!pointer) {
        return rt_w2c_malloc(size);
    }
    size_t old = *(size_t *)((char *)pointer - RT_W2C_HEADER);
    void *moved = rt_w2c_malloc(size);
    if (!moved) {
        return NULL; /* as realloc: the old block is still the caller's */
    }
    memcpy(moved, pointer, old < size ? old : size);
    rt_w2c_free(pointer);
    return moved;
}

/* ---- Rounding, for 32-bit ARM ---- */

/* VFP has no instruction that rounds to an integer in a given direction,
 * so the compiler calls floor and the rest by name, and libm isn't in the
 * libc set. Adding and subtracting 2^52 (2^23 for float) rounds to an
 * integer in the current mode, to nearest with ties to even, which is all
 * WebAssembly uses; the others step from there. Each result has its
 * argument's sign, zeros included. Written without the rounding builtins,
 * which would call back.
 *
 * rt_w2c_floor and the rest are compiled for every architecture, so
 * test_wasm2c_shim.py can check them against a libm. */
#define RT_W2C_ROUNDING(type, suffix, limit)                                   \
    static type rt_w2c_nearest##suffix(type magnitude) {                       \
        if (!(magnitude < limit)) {                                            \
            return magnitude; /* already an integer, infinite or NaN */       \
        }                                                                      \
        volatile type sum = magnitude + limit;                                 \
        return sum - limit;                                                    \
    }                                                                          \
    type rt_w2c_rint##suffix(type x) {                                         \
        return __builtin_copysign##suffix(rt_w2c_nearest##suffix(__builtin_fabs##suffix(x)), x); \
    }                                                                          \
    type rt_w2c_trunc##suffix(type x) {                                        \
        type magnitude = __builtin_fabs##suffix(x);                            \
        type nearest = rt_w2c_nearest##suffix(magnitude);                      \
        return __builtin_copysign##suffix(nearest > magnitude ? nearest - 1 : nearest, x); \
    }                                                                          \
    type rt_w2c_floor##suffix(type x) {                                        \
        type nearest = rt_w2c_rint##suffix(x);                                 \
        return __builtin_copysign##suffix(nearest > x ? nearest - 1 : nearest, x); \
    }                                                                          \
    type rt_w2c_ceil##suffix(type x) {                                         \
        type nearest = rt_w2c_rint##suffix(x);                                 \
        return __builtin_copysign##suffix(nearest < x ? nearest + 1 : nearest, x); \
    }

RT_W2C_ROUNDING(double, , 4503599627370496.0)
RT_W2C_ROUNDING(float, f, 8388608.0f)

#if defined(__arm__)
#undef floor
#undef ceil
#undef trunc
#undef nearbyint
#undef rint
#undef floorf
#undef ceilf
#undef truncf
#undef nearbyintf
#undef rintf

/* Weak: armv7-eabi.c, sealed into the same slice, has floor and ceil. */
#define RT_W2C_LIBM(type, name, function)                                      \
    __attribute__((weak)) type name(type x) {                                  \
        return function(x);                                                    \
    }

RT_W2C_LIBM(double, rint, rt_w2c_rint)
RT_W2C_LIBM(double, nearbyint, rt_w2c_rint)
RT_W2C_LIBM(double, trunc, rt_w2c_trunc)
RT_W2C_LIBM(double, floor, rt_w2c_floor)
RT_W2C_LIBM(double, ceil, rt_w2c_ceil)
RT_W2C_LIBM(float, rintf, rt_w2c_rintf)
RT_W2C_LIBM(float, nearbyintf, rt_w2c_rintf)
RT_W2C_LIBM(float, truncf, rt_w2c_truncf)
RT_W2C_LIBM(float, floorf, rt_w2c_floorf)
RT_W2C_LIBM(float, ceilf, rt_w2c_ceilf)
#endif
