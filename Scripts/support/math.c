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
