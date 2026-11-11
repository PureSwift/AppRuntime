/*
 * IEEE 754 binary32 <-> binary16 conversions, on bit patterns, for the
 * compiler-runtime helpers sealed into slices (float16 arithmetic has no
 * hardware support on these targets, and no libc provides the helpers).
 *
 * Rounding is to nearest, ties to even, as compiler-rt does.
 */
#ifndef RT_HALF_FLOAT_H
#define RT_HALF_FLOAT_H

static unsigned int rt_float_to_half(unsigned int f) {
    unsigned int sign = (f >> 16) & 0x8000u;
    int exponent = (int)((f >> 23) & 0xFFu);
    unsigned int mantissa = f & 0x7FFFFFu;

    if (exponent == 0xFF) {
        /* Infinity, or NaN with a nonzero payload. */
        return sign | 0x7C00u | (mantissa ? 0x200u | (mantissa >> 13) : 0);
    }
    int e = exponent - 127 + 15;
    if (e >= 31) {
        return sign | 0x7C00u;              /* overflow */
    }
    unsigned int half, rest, midpoint;
    if (e <= 0) {
        if (e < -10) {
            return sign;                    /* too small */
        }
        mantissa |= 0x800000u;
        int shift = 14 - e;
        half = mantissa >> shift;
        rest = mantissa & ((1u << shift) - 1);
        midpoint = 1u << (shift - 1);
    } else {
        half = ((unsigned int)e << 10) | (mantissa >> 13);
        rest = mantissa & 0x1FFFu;
        midpoint = 0x1000u;
    }
    if (rest > midpoint || (rest == midpoint && (half & 1))) {
        half += 1;                          /* carries into the exponent */
    }
    return sign | half;
}

static unsigned int rt_half_to_float(unsigned int h) {
    unsigned int sign = (h & 0x8000u) << 16;
    int exponent = (int)((h >> 10) & 0x1Fu);
    unsigned int mantissa = h & 0x3FFu;

    if (exponent == 31) {
        return sign | 0x7F800000u | (mantissa << 13);
    }
    if (exponent == 0) {
        if (mantissa == 0) {
            return sign;
        }
        exponent = 1;                       /* normalize a subnormal */
        while (!(mantissa & 0x400u)) {
            mantissa <<= 1;
            exponent -= 1;
        }
        mantissa &= 0x3FFu;
    }
    return sign | ((unsigned int)(exponent + 127 - 15) << 23) | (mantissa << 13);
}

#endif /* RT_HALF_FLOAT_H */
