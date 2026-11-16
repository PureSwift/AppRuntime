/*
 * libm functions the Embedded stdlib calls, sealed into every ELF slice.
 * guest.py localizes them when it seals the slice.
 *
 * Swift's squareRoot() lowers to a sqrt call, and sqrt isn't in the §7.5
 * allowed set (Apple slices get it from libSystem). Every ELF architecture
 * has a square root instruction; __builtin_elementwise_sqrt emits it
 * directly, without the errno path that would call sqrt.
 *
 * Weak, so a slice's own support code takes precedence. Freestanding.
 * Matches libm for every input, signed zeros included (checked against
 * libSystem on arm64 and x86_64).
 */

__attribute__((weak)) double sqrt(double x) {
    return __builtin_elementwise_sqrt(x);
}

__attribute__((weak)) float sqrtf(float x) {
    return __builtin_elementwise_sqrt(x);
}

/* round and roundf: to nearest, ties away from zero. armv7 VFP has no
 * rounding instruction, so the compiler calls these; written without
 * __builtin_round, which would call them back. Adding and subtracting 2^52
 * (2^23 for float) rounds to nearest even; a tie that went down is moved up. */

__attribute__((weak)) double round(double x) {
    double magnitude = __builtin_fabs(x);
    if (!(magnitude < 4503599627370496.0)) {
        return x; /* already integral, infinite or NaN */
    }
    double rounded = (magnitude + 4503599627370496.0) - 4503599627370496.0;
    if (rounded - magnitude <= -0.5) {
        rounded += 1.0;
    }
    return __builtin_copysign(rounded, x);
}

__attribute__((weak)) float roundf(float x) {
    float magnitude = __builtin_fabsf(x);
    if (!(magnitude < 8388608.0f)) {
        return x;
    }
    float rounded = (magnitude + 8388608.0f) - 8388608.0f;
    if (rounded - magnitude <= -0.5f) {
        rounded += 1.0f;
    }
    return __builtin_copysignf(rounded, x);
}

/*
 * fma and fmaf: x * y + z, rounded once.
 *
 * The stdlib's parser of numbers from text (Double("0.1")) calls fma. arm64
 * has an instruction for it. x86-64-v2 and armv7 VFPv3 don't, so there the
 * compiler calls these, and x * y + z in floating point would round twice
 * and sometimes land on the wrong neighbor.
 *
 * fma works on the bits: the 106-bit product of the mantissas and z's
 * mantissa are lined up in 128 bits, with what's shifted out kept as a
 * sticky bit, added or subtracted exactly, and rounded to nearest even.
 * Zeros, infinities and NaNs go through the FPU, where one of the two
 * operations is exact. fmaf has room to do it in doubles: the product of two
 * floats is exact, the sum is rounded to odd, and that rounds correctly to a
 * float.
 *
 * Checked against arm64's instruction on every kind of input: random bits,
 * near-total cancellation, subnormal results, overflow.
 */

typedef unsigned long long rt_u64;

typedef struct {
    rt_u64 high, low;
} rt_u128;

static rt_u64 rt_double_bits(double value) {
    rt_u64 bits;
    __builtin_memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double rt_bits_double(rt_u64 bits) {
    double value;
    __builtin_memcpy(&value, &bits, sizeof(value));
    return value;
}

/* 64 x 64 -> 128, on 32-bit halves. */
static rt_u128 rt_multiply(rt_u64 a, rt_u64 b) {
    rt_u64 a0 = (unsigned)a, a1 = a >> 32, b0 = (unsigned)b, b1 = b >> 32;
    rt_u64 low = a0 * b0, cross1 = a0 * b1, cross2 = a1 * b0, high = a1 * b1;
    rt_u64 middle = (low >> 32) + (unsigned)cross1 + (unsigned)cross2;
    rt_u128 result;
    result.low = (middle << 32) | (unsigned)low;
    result.high = high + (cross1 >> 32) + (cross2 >> 32) + (middle >> 32);
    return result;
}

/* 0 <= count < 128. */
static rt_u128 rt_shift_left(rt_u128 value, int count) {
    rt_u128 result = value;
    if (count >= 64) {
        result.high = value.low << (count - 64);
        result.low = 0;
    } else if (count > 0) {
        result.high = (value.high << count) | (value.low >> (64 - count));
        result.low = value.low << count;
    }
    return result;
}

/* 0 <= count <= 128. */
static rt_u128 rt_shift_right(rt_u128 value, int count) {
    rt_u128 result = value;
    if (count >= 128) {
        result.high = 0;
        result.low = 0;
    } else if (count >= 64) {
        result.low = value.high >> (count - 64);
        result.high = 0;
    } else if (count > 0) {
        result.low = (value.low >> count) | (value.high << (64 - count));
        result.high = value.high >> count;
    }
    return result;
}

/* Whether any of the low `count` bits is set. 0 <= count <= 128. */
static int rt_low_bits(rt_u128 value, int count) {
    if (count >= 128) {
        return (value.high | value.low) != 0;
    }
    if (count >= 64) {
        return value.low != 0 || (count > 64 && (value.high << (128 - count)) != 0);
    }
    return count > 0 && (value.low << (64 - count)) != 0;
}

/* Shifted right by any count, with a 1 left in the lowest bit if anything
 * nonzero was shifted out. */
static rt_u128 rt_shift_right_sticky(rt_u128 value, int count) {
    int lost = rt_low_bits(value, count > 128 ? 128 : count);
    rt_u128 result = rt_shift_right(value, count > 128 ? 128 : count);
    result.low |= (rt_u64)lost;
    return result;
}

static rt_u128 rt_add(rt_u128 a, rt_u128 b) {
    rt_u128 result;
    result.low = a.low + b.low;
    result.high = a.high + b.high + (result.low < a.low);
    return result;
}

static rt_u128 rt_subtract(rt_u128 a, rt_u128 b) {
    rt_u128 result;
    result.low = a.low - b.low;
    result.high = a.high - b.high - (a.low < b.low);
    return result;
}

static int rt_compare(rt_u128 a, rt_u128 b) {
    if (a.high != b.high) {
        return a.high < b.high ? -1 : 1;
    }
    return a.low == b.low ? 0 : (a.low < b.low ? -1 : 1);
}

/* The mantissa with its leading 1 at bit 52, and the exponent that goes
 * with it, for a finite nonzero value. */
static rt_u64 rt_mantissa(rt_u64 bits, int *exponent) {
    rt_u64 mantissa = bits & 0xFFFFFFFFFFFFFull;
    *exponent = (int)((bits >> 52) & 0x7FF);
    if (*exponent == 0) {
        int shift = __builtin_clzll(mantissa) - 11;
        *exponent = 1 - shift;
        return mantissa << shift;
    }
    return mantissa | (1ull << 52);
}

static double rt_soft_fma(double x, double y, double z) {
    rt_u64 x_bits = rt_double_bits(x), y_bits = rt_double_bits(y), z_bits = rt_double_bits(z);
    int x_field = (int)((x_bits >> 52) & 0x7FF), y_field = (int)((y_bits >> 52) & 0x7FF);
    int z_field = (int)((z_bits >> 52) & 0x7FF);
    if (x_field == 0x7FF || y_field == 0x7FF || (x_bits << 1) == 0 || (y_bits << 1) == 0) {
        /* An infinity, a NaN or a zero product: the multiplication is exact. */
        return x * y + z;
    }
    if (z_field == 0x7FF) {
        /* The product is finite, whatever the FPU would round it to. */
        return z;
    }
    if ((z_bits << 1) == 0) {
        return x * y;
    }

    int x_exponent, y_exponent, z_exponent;
    rt_u64 x_mantissa = rt_mantissa(x_bits, &x_exponent);
    rt_u64 y_mantissa = rt_mantissa(y_bits, &y_exponent);
    rt_u64 z_mantissa = rt_mantissa(z_bits, &z_exponent);

    /* Both with their leading bit near the top of 128, and zeros below:
     * the product at bit 124 or 125, z at bit 125. Each is its integer
     * times 2 to its exponent. */
    rt_u128 product = rt_shift_left(rt_multiply(x_mantissa, y_mantissa), 20);
    int product_exponent = x_exponent + y_exponent - 2150 - 20;
    rt_u128 addend = {z_mantissa << 9, 0};
    int addend_exponent = z_exponent - 1075 - 73;
    int product_negative = (int)((x_bits ^ y_bits) >> 63), addend_negative = (int)(z_bits >> 63);

    /* Line them up on the larger exponent. What falls off the smaller one
     * is at least 21 bits down, so it can't meet a cancellation. */
    int exponent;
    if (product_exponent >= addend_exponent) {
        addend = rt_shift_right_sticky(addend, product_exponent - addend_exponent);
        exponent = product_exponent;
    } else {
        product = rt_shift_right_sticky(product, addend_exponent - product_exponent);
        exponent = addend_exponent;
    }

    rt_u128 sum;
    int negative;
    if (product_negative == addend_negative) {
        sum = rt_add(product, addend);
        negative = product_negative;
    } else {
        int order = rt_compare(product, addend);
        if (order == 0) {
            return 0.0; /* exactly nothing: +0 when rounding to nearest */
        }
        sum = order > 0 ? rt_subtract(product, addend) : rt_subtract(addend, product);
        negative = order > 0 ? product_negative : addend_negative;
    }

    /* Round to 53 bits, or to fewer for a subnormal. */
    int top = sum.high ? 127 - __builtin_clzll(sum.high) : 63 - __builtin_clzll(sum.low);
    int field = exponent + top + 1023;
    int drop = top - 52;
    rt_u64 sign = (rt_u64)negative << 63;
    if (field >= 0x7FF) {
        return rt_bits_double(sign | 0x7FF0000000000000ull);
    }
    if (field < 1) {
        drop += 1 - field;
        field = 0;
    }
    rt_u64 mantissa;
    if (drop <= 0) {
        mantissa = rt_shift_left(sum, -drop).low;
    } else if (drop > 128) {
        mantissa = 0;
    } else {
        mantissa = rt_shift_right(sum, drop).low;
        int half = (int)(rt_shift_right(sum, drop - 1).low & 1);
        if (half && (rt_low_bits(sum, drop - 1) || (mantissa & 1))) {
            mantissa++;
        }
    }
    /* A mantissa that rounded up to the next power of two carries into the
     * exponent by itself: into the next binade, the smallest normal, or
     * infinity. */
    if (field > 0) {
        return rt_bits_double(sign | (((rt_u64)field << 52) + (mantissa - (1ull << 52))));
    }
    return rt_bits_double(sign | mantissa);
}

static float rt_soft_fmaf(float x, float y, float z) {
    double product = (double)x * (double)y; /* exact */
    double sum = product + (double)z;
    if (sum != sum || sum - sum != 0) {
        return (float)sum; /* a NaN or an infinity */
    }
    /* What the addition lost, exactly. */
    double part = sum - product;
    double error = (product - (sum - part)) + ((double)z - part);
    if (error != 0) {
        /* Round to odd: the neighbor on the error's side when the sum is
         * even. Rounding that to a float is rounding the exact value. */
        rt_u64 bits = rt_double_bits(sum);
        if ((bits & 1) == 0) {
            bits += ((error > 0) == (sum > 0)) ? 1 : -1;
            sum = rt_bits_double(bits);
        }
    }
    return (float)sum;
}

#if defined(RT_MATH_TEST)
/* For a host test: the software versions, whatever the architecture. */
double rt_test_fma(double x, double y, double z) {
    return rt_soft_fma(x, y, z);
}

float rt_test_fmaf(float x, float y, float z) {
    return rt_soft_fmaf(x, y, z);
}
#endif

__attribute__((weak)) double fma(double x, double y, double z) {
#if defined(__aarch64__) || defined(__FMA__)
    return __builtin_fma(x, y, z);
#else
    return rt_soft_fma(x, y, z);
#endif
}

__attribute__((weak)) float fmaf(float x, float y, float z) {
#if defined(__aarch64__) || defined(__FMA__)
    return __builtin_fmaf(x, y, z);
#else
    return rt_soft_fmaf(x, y, z);
#endif
}
