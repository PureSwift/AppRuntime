/*
 * Half-precision conversions sealed into x86_64 ELF slices. The toolchain has
 * no bare-metal compiler-rt, and x86-64-v2 has no F16C. guest.py localizes
 * them when it seals the slice.
 */
#include "half-float.h"

float __extendhfsf2(_Float16 value) {
    union { _Float16 half; unsigned short bits; } in = { value };
    union { unsigned int bits; float single; } out = { rt_half_to_float(in.bits) };
    return out.single;
}

_Float16 __truncsfhf2(float value) {
    union { float single; unsigned int bits; } in = { value };
    union { unsigned short bits; _Float16 half; } out = { (unsigned short)rt_float_to_half(in.bits) };
    return out.half;
}
