/*
 * rt_guest.h — guest-side additions that sit next to rt.h.
 *
 * Nothing here changes the rt.h ABI. It holds the ABI version the guest is
 * built against, the metadata section names (§10), and the two allocator
 * exports a wasm host needs to pass rt_dispatch arguments and results through
 * linear memory.
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

#if defined(__wasm__)
/*
 * wasm32 only. A native host passes rt_dispatch arguments as native pointers;
 * a wasm host has to place them in the guest's linear memory first. It calls
 * rt_alloc for a block of nargs + nret slots, writes the arguments, calls
 * rt_dispatch with offsets into the block, reads the results and calls
 * rt_free. Blocks are 8-byte aligned. rt_alloc returns 0 on failure.
 */
RT_EXPORT(rt_alloc) void *rt_alloc(size_t size);
RT_EXPORT(rt_free)  void  rt_free(void *ptr);
#endif

#endif /* RT_GUEST_H */
