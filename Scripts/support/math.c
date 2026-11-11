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
 */

__attribute__((weak)) double sqrt(double x) {
    return __builtin_elementwise_sqrt(x);
}

__attribute__((weak)) float sqrtf(float x) {
    return __builtin_elementwise_sqrt(x);
}
