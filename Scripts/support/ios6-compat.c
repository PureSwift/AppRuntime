/*
 * Runtime support sealed into the iOS 6 armv7 slice: libc and C++ runtime
 * functions the Embedded Swift runtime needs that iOS 6 doesn't have.
 * Same as Swift-iOS6's Compat.c (https://github.com/colemancda/Swift-iOS6).
 * guest.py localizes them when it seals the slice.
 *
 * Freestanding: only <stddef.h>.
 */
#include <stddef.h>
#include "half-float.h"

/* C11 Annex K memset_s (iOS 7 and later). The concurrency runtime uses it to
 * clear task memory. Writes through a volatile pointer so the stores stay. */
int memset_s(void *s, size_t smax, int c, size_t n) {
    if (s == NULL) {
        return 22; /* EINVAL */
    }
    volatile unsigned char *p = s;
    size_t count = n < smax ? n : smax;
    for (size_t i = 0; i < count; i++) {
        p[i] = (unsigned char)c;
    }
    return n > smax ? 84 : 0; /* EOVERFLOW */
}

/* The C++ runtime's handler for calling a pure virtual function, referenced
 * by the concurrency runtime's task groups. Calling one is a bug: stop. */
void __cxa_pure_virtual(void) {
    __builtin_trap();
}

/* Half-precision conversions, in case iOS 6's libSystem lacks them. This
 * target is soft-float, so floats travel as integer bit patterns. */
unsigned int __truncsfhf2(unsigned int value) {
    return rt_float_to_half(value);
}

unsigned int __extendhfsf2(unsigned int value) {
    return rt_half_to_float(value);
}
