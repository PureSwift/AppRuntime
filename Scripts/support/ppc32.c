/*
 * Runtime support sealed into 32-bit PowerPC ELF slices (linux-ppc7400,
 * linux-ppc750). PowerPC's 32-bit ISA has no 64-bit division, no 64-bit
 * atomics and no conversions between 64-bit integers and floating point,
 * so the compiler calls libgcc's helpers for them. They aren't in the libc
 * set a host provides (§7.5), so the slice carries private copies, which
 * guest.py localizes when it seals the slice: they can't collide with the
 * host's libgcc.
 *
 * Freestanding: no headers. Big-endian: a 64-bit value's high word comes
 * first. Division is written without '/' or '%' on 64-bit values, which
 * would call back into these helpers. Floating-point arguments and results
 * are in FPRs under the PowerPC SVR4 ABI, so the conversions take and give
 * real doubles and floats, and work on their bits inside.
 */

typedef unsigned int u32;
typedef int s32;
typedef unsigned long long u64;
typedef long long s64;

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
typedef union { u64 value; struct { u32 high, low; } half; } u64_parts;
#else
typedef union { u64 value; struct { u32 low, high; } half; } u64_parts;
#endif

/*
 * 64-bit shifts, on 32-bit halves.
 */
u64 __ashldi3(u64 value, int shift) {
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

u64 __lshrdi3(u64 value, int shift) {
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

s64 __ashrdi3(s64 value, int shift) {
    u64_parts in = { (u64)value }, out;
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
    return (s64)out.value;
}

/*
 * 64-bit unsigned division, by shift and subtract on 32-bit halves.
 */
u64 __udivmoddi4(u64 n, u64 d, u64 *remainder) {
    if (d == 0) {
        __builtin_trap();
    }
    u64_parts number = { n }, divisor = { d };
    u32 q_low = 0, q_high = 0, rest_low = 0, rest_high = 0;
    for (int bit = 63; bit >= 0; bit--) {
        rest_high = (rest_high << 1) | (rest_low >> 31);
        u32 word = bit >= 32 ? number.half.high >> (bit - 32) : number.half.low >> bit;
        rest_low = (rest_low << 1) | (word & 1);
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
    if (remainder) {
        *remainder = rest.value;
    }
    return quotient.value;
}

u64 __udivdi3(u64 n, u64 d) {
    return __udivmoddi4(n, d, 0);
}

u64 __umoddi3(u64 n, u64 d) {
    u64 rest;
    __udivmoddi4(n, d, &rest);
    return rest;
}

/*
 * 64-bit signed division, on the unsigned one: the quotient rounds toward
 * zero, and the remainder has the dividend's sign.
 */
s64 __divmoddi4(s64 n, s64 d, s64 *remainder) {
    u64 rest;
    u64 quotient = __udivmoddi4(n < 0 ? 0 - (u64)n : (u64)n, d < 0 ? 0 - (u64)d : (u64)d, &rest);
    if (remainder) {
        *remainder = n < 0 ? (s64)(0 - rest) : (s64)rest;
    }
    return (n < 0) != (d < 0) ? (s64)(0 - quotient) : (s64)quotient;
}

s64 __divdi3(s64 n, s64 d) {
    return __divmoddi4(n, d, 0);
}

s64 __moddi3(s64 n, s64 d) {
    s64 rest;
    __divmoddi4(n, d, &rest);
    return rest;
}

/*
 * Conversions between 64-bit integers and floating point. Contracts carry
 * timestamps as 64-bit nanoseconds, so guest code that turns one into
 * seconds needs them.
 */
static int leading_zeros64(u64 value) {
    u64_parts parts = { value };
    return parts.half.high ? __builtin_clz(parts.half.high) : 32 + __builtin_clz(parts.half.low);
}

/* `value` with `digits` mantissa bits, rounded to nearest, ties to even:
 * the mantissa with its leading 1, and the exponent in *exponent. `value`
 * isn't 0. */
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

typedef union { double d; u64 bits; } double_bits;
typedef union { float f; u32 bits; } float_bits;

float __floatundisf(u64 value) {
    float_bits out = { 0 };
    if (value != 0) {
        int exponent;
        u32 mantissa = (u32)round_to_mantissa(value, 24, &exponent);
        out.bits = ((u32)(exponent + 127) << 23) | (mantissa & 0x7FFFFF);
    }
    return out.f;
}

float __floatdisf(s64 value) {
    return value < 0 ? -__floatundisf(0 - (u64)value) : __floatundisf((u64)value);
}

double __floatundidf(u64 value) {
    double_bits out = { 0 };
    if (value != 0) {
        int exponent;
        u64 mantissa = round_to_mantissa(value, 53, &exponent);
        out.bits = ((u64)(exponent + 1023) << 52) | (mantissa & 0xFFFFFFFFFFFFFull);
    }
    return out.d;
}

double __floatdidf(s64 value) {
    return value < 0 ? -__floatundidf(0 - (u64)value) : __floatundidf((u64)value);
}

/* The integer part of a float given as its mantissa (leading 1 at bit
 * `digits - 1`) and exponent, which is in 0...63. */
static u64 truncate_mantissa(u64 mantissa, int digits, int exponent) {
    int point = digits - 1;
    return exponent >= point ? mantissa << (exponent - point) : mantissa >> (point - exponent);
}

/* Toward zero; out of range goes to the nearest limit, and NaN with it, as
 * compiler-rt does. */
s64 __fixsfdi(float x) {
    float_bits in = { x };
    int exponent = (int)((in.bits >> 23) & 0xFF) - 127;
    int negative = (int)(in.bits >> 31);
    if (exponent < 0) {
        return 0;
    }
    if (exponent >= 63) {
        return negative ? (s64)0x8000000000000000ull : (s64)0x7FFFFFFFFFFFFFFFull;
    }
    u64 magnitude = truncate_mantissa((in.bits & 0x7FFFFF) | 0x800000, 24, exponent);
    return negative ? (s64)(0 - magnitude) : (s64)magnitude;
}

u64 __fixunssfdi(float x) {
    float_bits in = { x };
    int exponent = (int)((in.bits >> 23) & 0xFF) - 127;
    if (exponent < 0 || (in.bits >> 31)) {
        return 0;
    }
    if (exponent >= 64) {
        return 0xFFFFFFFFFFFFFFFFull;
    }
    return truncate_mantissa((in.bits & 0x7FFFFF) | 0x800000, 24, exponent);
}

s64 __fixdfdi(double x) {
    double_bits in = { x };
    int exponent = (int)((in.bits >> 52) & 0x7FF) - 1023;
    int negative = (int)(in.bits >> 63);
    if (exponent < 0) {
        return 0;
    }
    if (exponent >= 63) {
        return negative ? (s64)0x8000000000000000ull : (s64)0x7FFFFFFFFFFFFFFFull;
    }
    u64 magnitude = truncate_mantissa((in.bits & 0xFFFFFFFFFFFFFull) | ((u64)1 << 52), 53, exponent);
    return negative ? (s64)(0 - magnitude) : (s64)magnitude;
}

u64 __fixunsdfdi(double x) {
    double_bits in = { x };
    int exponent = (int)((in.bits >> 52) & 0x7FF) - 1023;
    if (exponent < 0 || (in.bits >> 63)) {
        return 0;
    }
    if (exponent >= 64) {
        return 0xFFFFFFFFFFFFFFFFull;
    }
    return truncate_mantissa((in.bits & 0xFFFFFFFFFFFFFull) | ((u64)1 << 52), 53, exponent);
}

/*
 * 64-bit atomics, which 32-bit PowerPC has no instructions for (lwarx and
 * stwcx. are 32-bit). The guest is single-threaded (§6.4) and nothing else
 * touches its memory, so plain loads and stores are atomic enough: the
 * same reasoning as the single-threaded shims of Embedded Swift's platform
 * layer. The memory order is ignored.
 */
u64 __atomic_load_8(const volatile void *pointer, int order) {
    (void)order;
    return *(const volatile u64 *)pointer;
}

void __atomic_store_8(volatile void *pointer, u64 value, int order) {
    (void)order;
    *(volatile u64 *)pointer = value;
}

u64 __atomic_exchange_8(volatile void *pointer, u64 value, int order) {
    (void)order;
    u64 old = *(volatile u64 *)pointer;
    *(volatile u64 *)pointer = value;
    return old;
}

_Bool __atomic_compare_exchange_8(volatile void *pointer, void *expected, u64 desired,
                                  _Bool weak, int success, int failure) {
    (void)weak; (void)success; (void)failure;
    u64 current = *(volatile u64 *)pointer;
    if (current == *(u64 *)expected) {
        *(volatile u64 *)pointer = desired;
        return 1;
    }
    *(u64 *)expected = current;
    return 0;
}

#define FETCH(name, op) \
    u64 __atomic_fetch_##name##_8(volatile void *pointer, u64 value, int order) { \
        (void)order; \
        u64 old = *(volatile u64 *)pointer; \
        *(volatile u64 *)pointer = old op value; \
        return old; \
    }

FETCH(add, +)
FETCH(sub, -)
FETCH(and, &)
FETCH(or, |)
FETCH(xor, ^)

/*
 * ceil and floor: the G3's and G4's FPUs have no rounding instruction
 * (frin and friz are POWER5+), the Embedded stdlib calls them, and they
 * aren't in the allowed libc set. math.c has round and roundf.
 */
double ceil(double x) {
    double_bits value = { x };
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

double floor(double x) {
    double_bits value = { x };
    int exponent = (int)((value.bits >> 52) & 0x7FF) - 1023;
    if (exponent >= 52) {
        return x;
    }
    if (exponent < 0) {
        if ((value.bits << 1) == 0) {
            return x;
        }
        return (value.bits >> 63) ? -1.0 : 0.0;
    }
    u64 fraction = 0x000FFFFFFFFFFFFFull >> exponent;
    if ((value.bits & fraction) == 0) {
        return x;
    }
    if (value.bits >> 63) {
        value.bits += 1ull << (52 - exponent);
    }
    value.bits &= ~fraction;
    return value.d;
}
