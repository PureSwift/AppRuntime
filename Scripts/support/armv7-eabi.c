/*
 * Runtime support sealed into armv7 ELF slices (Linux armhf, Android
 * armeabi-v7a). The toolchain has no bare-metal compiler-rt for ARM, and
 * these aren't in the libc set a host provides (§7.5), so the slice carries
 * private copies. guest.py localizes them when it seals the slice, so they
 * can't collide with the host's libgcc / compiler-rt.
 *
 * Freestanding: no headers. Division is written without '/' or '%', which
 * would call back into these helpers on cores without hardware divide.
 */

#include "half-float.h"

typedef unsigned int u32;
typedef int s32;
typedef unsigned long long u64;
typedef long long s64;

static u32 udivmod32(u32 n, u32 d, u32 *remainder) {
    if (d == 0) {
        __builtin_trap();
    }
    u32 quotient = 0;
    u32 rest = 0;
    for (int bit = 31; bit >= 0; bit--) {
        rest = (rest << 1) | ((n >> bit) & 1);
        if (rest >= d) {
            rest -= d;
            quotient |= 1u << bit;
        }
    }
    *remainder = rest;
    return quotient;
}

u32 __aeabi_uidiv(u32 n, u32 d) {
    u32 remainder;
    return udivmod32(n, d, &remainder);
}

/* Quotient in r0, remainder in r1: a 64-bit return value under AAPCS. */
u64 __aeabi_uidivmod(u32 n, u32 d) {
    u32 remainder;
    u32 quotient = udivmod32(n, d, &remainder);
    return ((u64)remainder << 32) | quotient;
}

static u32 magnitude(s32 value) {
    return value < 0 ? 0u - (u32)value : (u32)value;
}

s32 __aeabi_idiv(s32 n, s32 d) {
    u32 remainder;
    u32 quotient = udivmod32(magnitude(n), magnitude(d), &remainder);
    return (n < 0) != (d < 0) ? -(s32)quotient : (s32)quotient;
}

u64 __aeabi_idivmod(s32 n, s32 d) {
    u32 remainder;
    u32 quotient = udivmod32(magnitude(n), magnitude(d), &remainder);
    s32 q = (n < 0) != (d < 0) ? -(s32)quotient : (s32)quotient;
    s32 r = n < 0 ? -(s32)remainder : (s32)remainder;
    return ((u64)(u32)r << 32) | (u32)q;
}

/*
 * 64-bit shifts, written on 32-bit halves: shifting a 64-bit value in C
 * would call these helpers again.
 */
typedef union { u64 value; struct { u32 low, high; } half; } u64_parts;

u64 __aeabi_llsl(u64 value, int shift) {
    u64_parts in = { value }, out;
    shift &= 63;
    if (shift == 0) {
        return value;
    }
    if (shift >= 32) {
        out.half.low = 0;
        out.half.high = in.half.low << (shift - 32);
    } else {
        out.half.low = in.half.low << shift;
        out.half.high = (in.half.high << shift) | (in.half.low >> (32 - shift));
    }
    return out.value;
}

u64 __aeabi_llsr(u64 value, int shift) {
    u64_parts in = { value }, out;
    shift &= 63;
    if (shift == 0) {
        return value;
    }
    if (shift >= 32) {
        out.half.high = 0;
        out.half.low = in.half.high >> (shift - 32);
    } else {
        out.half.high = in.half.high >> shift;
        out.half.low = (in.half.low >> shift) | (in.half.high << (32 - shift));
    }
    return out.value;
}

u64 __aeabi_lasr(u64 value, int shift) {
    u64_parts in = { value }, out;
    s32 high = (s32)in.half.high;
    shift &= 63;
    if (shift == 0) {
        return value;
    }
    if (shift >= 32) {
        out.half.high = (u32)(high >> 31);
        out.half.low = (u32)(high >> (shift - 32));
    } else {
        out.half.high = (u32)(high >> shift);
        out.half.low = (in.half.low >> shift) | (in.half.high << (32 - shift));
    }
    return out.value;
}

/*
 * 64-bit unsigned division, by shift and subtract on the 32-bit shifts above.
 */
u64 rt_udivmod64(u64 n, u64 d, u64 *remainder) {
    if (d == 0) {
        __builtin_trap();
    }
    u64_parts number = { n }, divisor = { d };
    u32 q_low = 0, q_high = 0, rest_low = 0, rest_high = 0;
    for (int bit = 63; bit >= 0; bit--) {
        /* rest = (rest << 1) | bit of n */
        rest_high = (rest_high << 1) | (rest_low >> 31);
        u32 word = bit >= 32 ? number.half.high >> (bit - 32) : number.half.low >> bit;
        rest_low = (rest_low << 1) | (word & 1);
        /* rest >= divisor */
        if (rest_high > divisor.half.high
            || (rest_high == divisor.half.high && rest_low >= divisor.half.low)) {
            u32 borrow = rest_low < divisor.half.low;
            rest_low -= divisor.half.low;
            rest_high -= divisor.half.high + borrow;
            if (bit >= 32) {
                q_high |= 1u << (bit - 32);
            } else {
                q_low |= 1u << bit;
            }
        }
    }
    u64_parts quotient, rest;
    quotient.half.low = q_low;
    quotient.half.high = q_high;
    rest.half.low = rest_low;
    rest.half.high = rest_high;
    *remainder = rest.value;
    return quotient.value;
}

/* Returns the quotient in r0:r1 and the remainder in r2:r3, which C can't
 * express. The pointer argument goes on the stack, per AAPCS. */
__attribute__((naked)) void __aeabi_uldivmod(void) {
    __asm__(
        "push {r11, lr}\n"
        "sub sp, sp, #16\n"
        "add r12, sp, #8\n"
        "str r12, [sp]\n"
        "bl rt_udivmod64\n"
        "ldrd r2, r3, [sp, #8]\n"
        "add sp, sp, #16\n"
        "pop {r11, pc}\n");
}

/*
 * 64-bit signed division, on the unsigned one: the quotient rounds toward
 * zero, and the remainder has the dividend's sign.
 */
s64 rt_divmod64(s64 n, s64 d, s64 *remainder) {
    u64 rest;
    u64 quotient = rt_udivmod64(n < 0 ? 0 - (u64)n : (u64)n, d < 0 ? 0 - (u64)d : (u64)d, &rest);
    *remainder = n < 0 ? (s64)(0 - rest) : (s64)rest;
    return (n < 0) != (d < 0) ? (s64)(0 - quotient) : (s64)quotient;
}

/* As __aeabi_uldivmod: the quotient in r0:r1 and the remainder in r2:r3. */
__attribute__((naked)) void __aeabi_ldivmod(void) {
    __asm__(
        "push {r11, lr}\n"
        "sub sp, sp, #16\n"
        "add r12, sp, #8\n"
        "str r12, [sp]\n"
        "bl rt_divmod64\n"
        "ldrd r2, r3, [sp, #8]\n"
        "add sp, sp, #16\n"
        "pop {r11, pc}\n");
}

/* Half-precision conversions. Integer signatures use core registers under
 * both the soft-float and hard-float AAPCS variants, as the EABI requires. */
u32 __aeabi_f2h(u32 value) {
    return rt_float_to_half(value);
}

u32 __aeabi_h2f(u32 value) {
    return rt_half_to_float(value);
}

/*
 * Conversions between 64-bit integers and floating point, which VFP has no
 * instructions for. Contracts carry timestamps as 64-bit nanoseconds, so
 * guest code that turns one into seconds needs them. Like every __aeabi_*
 * helper they use the base calling convention on hard-float targets too:
 * a float travels as its bits in r0, a double as its bits in r0:r1. They
 * work on the bits alone, with no floating-point instructions.
 */
static int leading_zeros64(u64 value) {
    u32 high = (u32)(value >> 32);
    return high ? __builtin_clz(high) : 32 + __builtin_clz((u32)value);
}

/* `value` as a float with `digits` mantissa bits, rounded to nearest, ties
 * to even: the mantissa with its leading 1, and the exponent in *exponent.
 * `value` isn't 0. */
static u64 round_to_mantissa(u64 value, int digits, int *exponent) {
    int top = 63 - leading_zeros64(value);
    *exponent = top;
    if (top < digits) {
        return value << (digits - 1 - top);
    }
    int shift = top - (digits - 1);
    if (shift == 0) {
        return value;
    }
    u64 half = (u64)1 << (shift - 1);
    u64 rest = value & ((half << 1) - 1);
    u64 mantissa = value >> shift;
    if (rest > half || (rest == half && (mantissa & 1))) {
        mantissa++;
        if (mantissa >> digits) {
            mantissa >>= 1;
            *exponent = top + 1;
        }
    }
    return mantissa;
}

u32 __aeabi_ul2f(u64 value) {
    int exponent;
    if (value == 0) {
        return 0;
    }
    u32 mantissa = (u32)round_to_mantissa(value, 24, &exponent);
    return ((u32)(exponent + 127) << 23) | (mantissa & 0x7FFFFF);
}

u32 __aeabi_l2f(s64 value) {
    return value < 0 ? 0x80000000u | __aeabi_ul2f(0 - (u64)value) : __aeabi_ul2f((u64)value);
}

u64 __aeabi_ul2d(u64 value) {
    int exponent;
    if (value == 0) {
        return 0;
    }
    u64 mantissa = round_to_mantissa(value, 53, &exponent);
    return ((u64)(exponent + 1023) << 52) | (mantissa & 0xFFFFFFFFFFFFFull);
}

u64 __aeabi_l2d(s64 value) {
    return value < 0 ? 0x8000000000000000ull | __aeabi_ul2d(0 - (u64)value) : __aeabi_ul2d((u64)value);
}

/* The integer part of a float given as its mantissa (leading 1 at bit
 * `digits - 1`) and exponent, which is in 0...63. */
static u64 truncate_mantissa(u64 mantissa, int digits, int exponent) {
    int point = digits - 1;
    return exponent >= point ? mantissa << (exponent - point) : mantissa >> (point - exponent);
}

/* Toward zero; out of range goes to the nearest limit, and NaN with it, as
 * compiler-rt does. */
s64 __aeabi_f2lz(u32 bits) {
    int exponent = (int)((bits >> 23) & 0xFF) - 127;
    int negative = (int)(bits >> 31);
    if (exponent < 0) {
        return 0;
    }
    if (exponent >= 63) {
        return negative ? (s64)0x8000000000000000ull : (s64)0x7FFFFFFFFFFFFFFFull;
    }
    u64 magnitude = truncate_mantissa((bits & 0x7FFFFF) | 0x800000, 24, exponent);
    return negative ? (s64)(0 - magnitude) : (s64)magnitude;
}

u64 __aeabi_f2ulz(u32 bits) {
    int exponent = (int)((bits >> 23) & 0xFF) - 127;
    if (exponent < 0 || (bits >> 31)) {
        return 0;
    }
    if (exponent >= 64) {
        return 0xFFFFFFFFFFFFFFFFull;
    }
    return truncate_mantissa((bits & 0x7FFFFF) | 0x800000, 24, exponent);
}

s64 __aeabi_d2lz(u64 bits) {
    int exponent = (int)((bits >> 52) & 0x7FF) - 1023;
    int negative = (int)(bits >> 63);
    if (exponent < 0) {
        return 0;
    }
    if (exponent >= 63) {
        return negative ? (s64)0x8000000000000000ull : (s64)0x7FFFFFFFFFFFFFFFull;
    }
    u64 magnitude = truncate_mantissa((bits & 0xFFFFFFFFFFFFFull) | ((u64)1 << 52), 53, exponent);
    return negative ? (s64)(0 - magnitude) : (s64)magnitude;
}

u64 __aeabi_d2ulz(u64 bits) {
    int exponent = (int)((bits >> 52) & 0x7FF) - 1023;
    if (exponent < 0 || (bits >> 63)) {
        return 0;
    }
    if (exponent >= 64) {
        return 0xFFFFFFFFFFFFFFFFull;
    }
    return truncate_mantissa((bits & 0xFFFFFFFFFFFFFull) | ((u64)1 << 52), 53, exponent);
}

/*
 * Personality routines referenced by the unwind tables of the prebuilt
 * Embedded runtime archives. Guest code never throws C++ exceptions, so
 * nothing unwinds through it; report failure (_URC_FAILURE) if asked.
 */
int __aeabi_unwind_cpp_pr0(int state, void *exception, void *context) {
    (void)state; (void)exception; (void)context;
    return 9;
}

int __aeabi_unwind_cpp_pr1(int state, void *exception, void *context) {
    (void)state; (void)exception; (void)context;
    return 9;
}

/*
 * ceil for VFPv3, which has no rounding instruction. The Embedded stdlib
 * calls it when sizing hash tables; it isn't in the allowed libc set.
 */
double ceil(double x) {
    union { double d; u64 bits; } value = { x };
    int exponent = (int)((value.bits >> 52) & 0x7FF) - 1023;
    if (exponent >= 52) {
        return x;                       /* integral, infinite or NaN */
    }
    if (exponent < 0) {
        if ((value.bits << 1) == 0) {
            return x;                   /* ±0 */
        }
        return (value.bits >> 63) ? -0.0 : 1.0;
    }
    u64 fraction = 0x000FFFFFFFFFFFFFull >> exponent;
    if ((value.bits & fraction) == 0) {
        return x;
    }
    if (!(value.bits >> 63)) {
        value.bits += 1ull << (52 - exponent);
    }
    value.bits &= ~fraction;
    return value.d;
}

/* floor, the same way: calendar arithmetic on dates calls it. */
double floor(double x) {
    union { double d; u64 bits; } value = { x };
    int exponent = (int)((value.bits >> 52) & 0x7FF) - 1023;
    if (exponent >= 52) {
        return x;                       /* integral, infinite or NaN */
    }
    if (exponent < 0) {
        if ((value.bits << 1) == 0) {
            return x;                   /* ±0 */
        }
        return (value.bits >> 63) ? -1.0 : 0.0;
    }
    u64 fraction = 0x000FFFFFFFFFFFFFull >> exponent;
    if ((value.bits & fraction) == 0) {
        return x;
    }
    if (value.bits >> 63) {
        /* Away from zero: the next integer down. */
        value.bits += 1ull << (52 - exponent);
    }
    value.bits &= ~fraction;
    return value.d;
}

/*
 * roundf (round half away from zero), for the same reason: VFPv3 has no
 * rounding instruction and it isn't in the allowed libc set.
 */
float roundf(float x) {
    union { float f; u32 bits; } value = { x };
    int exponent = (int)((value.bits >> 23) & 0xFF) - 127;
    if (exponent >= 23) {
        return x;                       /* integral, infinite or NaN */
    }
    u32 sign = value.bits & 0x80000000u;
    if (exponent < -1) {
        value.bits = sign;              /* |x| < 0.5 */
        return value.f;
    }
    if (exponent == -1) {
        value.bits = sign | 0x3F800000u; /* 0.5 <= |x| < 1 rounds to ±1 */
        return value.f;
    }
    u32 fraction = 0x007FFFFFu >> exponent;
    if ((value.bits & fraction) == 0) {
        return x;
    }
    value.bits += 0x00400000u >> exponent;  /* add one half */
    value.bits &= ~fraction;
    return value.f;
}
