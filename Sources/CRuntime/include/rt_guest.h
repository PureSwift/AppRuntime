/*
 * rt_guest.h — guest-side additions that sit next to rt.h.
 *
 * Nothing here changes the rt.h ABI. It holds the ABI version the guest is
 * built against and the metadata section names (§10).
 *
 * Freestanding: only <stdint.h> and <stddef.h>. Guest code never includes libc
 * headers, so the same objects link against glibc, musl, bionic or libSystem.
 */
#ifndef RT_GUEST_H
#define RT_GUEST_H

#include "rt.h"

/* rt ABI version this header describes. Stored in the rt.abi section. */
#define RT_ABI_VERSION 1

/* Metadata section names (§10). wasm32 uses custom sections with the dotted
 * names; Mach-O and ELF use object-file sections. */
#if defined(__wasm__)
#  define RT_SECTION_ABI       "rt.abi"
#  define RT_SECTION_CONTRACTS "rt.contracts"
#elif defined(__APPLE__)
#  define RT_SECTION_ABI       "__DATA,__rt_abi"
#  define RT_SECTION_CONTRACTS "__DATA,__rt_contracts"
#else
#  define RT_SECTION_ABI       ".rt_abi"
#  define RT_SECTION_CONTRACTS ".rt_contracts"
#endif

#endif /* RT_GUEST_H */
