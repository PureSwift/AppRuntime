/*
 * rt.c — guest-side pieces that can only be written in C.
 *
 * - The rt.abi metadata section (§10). Swift globals placed with @section end
 *   up in the wasm data segment, so the wasm custom section is emitted with
 *   module-level assembly instead.
 * - The wasm32 allocator exports, rt_alloc and rt_free (rt.h).
 *
 * Freestanding: no libc headers. malloc and free are in the allowed libc set
 * (§7.5) and are declared here directly.
 */
#include "rt.h"
#include "rt_guest.h"

#define RT_STRINGIFY_(x) #x
#define RT_STRINGIFY(x) RT_STRINGIFY_(x)

#if defined(__wasm__)

/* Custom section "rt.abi": the ABI version as a little-endian uint32. */
__asm__(
    ".section .custom_section.rt.abi,\"\",@\n"
    ".int32 " RT_STRINGIFY(RT_ABI_VERSION) "\n"
    ".text\n");

void *malloc(size_t size);
void free(void *ptr);

void *rt_alloc(size_t size) {
    return malloc(size);
}

void rt_free(void *ptr) {
    free(ptr);
}

#else

/* Object-file section with the same contents as the wasm custom section. */
__attribute__((used, section(RT_SECTION_ABI)))
static const uint32_t rt_abi_version = RT_ABI_VERSION;

#endif
