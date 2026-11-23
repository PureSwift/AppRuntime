/*
 * Support for the aarch64-unknown-linux-gnu Embedded concurrency runtime,
 * sealed into linux-arm64 and android-arm64-v8a slices next to
 * concurrency.c and linux-gnu.c. guest.py localizes these when it seals
 * the slice.
 *
 * The toolchain has no concurrency runtime for aarch64-none-none-elf, so
 * those slices use the Linux one (§5.4). Beyond what linux-gnu.c covers for
 * every hosted Linux runtime, this one references outline atomics
 * (__aarch64_cas8_acq and friends), which libgcc or compiler-rt provide on
 * Linux. This file is compiled with -mno-outline-atomics, so the builtins
 * below inline to exclusive load/store loops instead of calling
 * themselves.
 *
 * Every definition is weak, like concurrency.c. Freestanding: only
 * <stddef.h> and <stdint.h>.
 */
#include <stddef.h>
#include <stdint.h>

#define WEAK __attribute__((weak))

/* MARK: Outline atomics
 *
 * The libgcc/compiler-rt ABI: __aarch64_casN_ORDER(expected, desired, ptr)
 * and __aarch64_OPN_ORDER(value, ptr) return the previous value. */

#define CAS(N, T, ORDER, SUCCESS, FAILURE)                                              \
    WEAK T __aarch64_cas##N##_##ORDER(T expected, T desired, T *pointer) {              \
        __atomic_compare_exchange_n(pointer, &expected, desired, 0, SUCCESS, FAILURE);  \
        return expected;                                                                \
    }

#define RMW(NAME, N, T, ORDER, MODEL, BUILTIN, OPERAND)        \
    WEAK T __aarch64_##NAME##N##_##ORDER(T value, T *pointer) { \
        return BUILTIN(pointer, OPERAND, MODEL);                \
    }

#define ORDERS(MACRO, ...)                                                    \
    MACRO(__VA_ARGS__, relax, __ATOMIC_RELAXED, __ATOMIC_RELAXED)            \
    MACRO(__VA_ARGS__, acq, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)              \
    MACRO(__VA_ARGS__, rel, __ATOMIC_RELEASE, __ATOMIC_RELAXED)              \
    MACRO(__VA_ARGS__, acq_rel, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)

#define CAS_ORDER(N, T, ORDER, SUCCESS, FAILURE) CAS(N, T, ORDER, SUCCESS, FAILURE)
#define SWP_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(swp, N, T, ORDER, MODEL, __atomic_exchange_n, value)
#define LDADD_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldadd, N, T, ORDER, MODEL, __atomic_fetch_add, value)
#define LDCLR_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldclr, N, T, ORDER, MODEL, __atomic_fetch_and, ~value)
#define LDSET_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldset, N, T, ORDER, MODEL, __atomic_fetch_or, value)
#define LDEOR_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldeor, N, T, ORDER, MODEL, __atomic_fetch_xor, value)

#define SIZE(N, T)                \
    ORDERS(CAS_ORDER, N, T)       \
    ORDERS(SWP_ORDER, N, T)       \
    ORDERS(LDADD_ORDER, N, T)     \
    ORDERS(LDCLR_ORDER, N, T)     \
    ORDERS(LDSET_ORDER, N, T)     \
    ORDERS(LDEOR_ORDER, N, T)

SIZE(1, uint8_t)
SIZE(2, uint16_t)
SIZE(4, uint32_t)
SIZE(8, uint64_t)
ORDERS(CAS_ORDER, 16, unsigned __int128)
