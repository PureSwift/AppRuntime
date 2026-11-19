#!/usr/bin/env python3
"""
The wasm2c import shim: turns App.wasm, translated to C by WABT's wasm2c,
into a library with the same exports and imports as a native slice
(DynamicRuntime.md §7.5), for hosts without a slice for their platform.

    wasm2c-shim.py shim  [--name app] [--rt-h rt.h] [--wasm App.wasm] -o rt_wasm2c.c
    wasm2c-shim.py build --wasm App.wasm --output DIR [--target TRIPLE ...] [--sdk macosx]
    wasm2c-shim.py slice --wasm App.wasm --output DIR --target linux-arm64 [--target ...]
    wasm2c-shim.py slice --bundle App.app --target linux-arm64 [--target ...]
    wasm2c-shim.py sources --wasm App.wasm --output DIR

`shim` generates the C shim from rt.h:
- each `rt.*` import converts guest offsets to host memory, with bounds
  checks, and calls the host's `rt_*` C function;
- `rt_main`, `rt_dispatch` and `rt_finalize` call the translated module,
  placing `rt_dispatch`'s slots in guest memory with its `rt_alloc` /
  `rt_free`, and turn traps into `RT_ERR_THROWN`;
- a minimal WASI preview 1 for what Embedded Swift's libc imports;
- for a module that draws, each `env.gl.*` import (§8.1) calls the GL shim
  (Sources/CRuntimeGL, from gles2.py), which checks the guest's pointers and
  calls the platform's `gl*` function. Such a slice asks one more thing of
  its host: `rt_gl_context_generation`, described in the generated shim.
With --wasm, it checks that the module imports nothing else, and adds the
GL imports if the module uses them (--gl forces them).

`build` runs wasm2c, generates the shim, compiles both with WABT's wasm-rt
runtime, and seals the result like a native slice: one `ld -r` object in
DIR/libapp.a (one per --target, joined with lipo on Apple platforms), only
rt_main, rt_dispatch and rt_finalize global, and the module's rt.abi,
rt.contracts and rt.manifest sections copied in.

`slice` builds a Linux slice, DIR/<target>/libapp.so, for guest.py's Linux
target IDs: the library a runner loads as it is (§7.6), for a bundle that
has no native slice for an architecture. A Linux device has no compiler,
so this runs where the bundle is built or distributed.
- It passes the checks guest.py makes of a native libapp.so: it names no
  library, and leaves undefined only rt.h, GLES 2.0 and the libc set, so
  the same file loads under any libc.
- So nothing is compiled against a libc's headers. The module, wasm-rt and
  the shim are compiled freestanding with the package's Swift toolchain,
  for the triple guest.py compiles that target's native slice for, against
  Scripts/support/wasm2c-freestanding.h. The same support files are
  sealed in.
- With --bundle, the slice is made from the bundle's wasm32/App.wasm and
  added to it: lib/<target>/libapp.so, the target in RTTargets, and
  CodeResources rewritten for the new files. A bundle that was signed
  needs signing again.

`sources` stops before compiling: DIR gets the translated module, the shim,
the wasm-rt runtime, rt.h and, for a module that draws, the GL shim and its
headers, for a build with another toolchain (a cross compiler, a container).
`sources.txt` lists what to compile and `defines.txt` the macros to compile
it with; DIR is the only include path.

wasm-rt is built with explicit bounds checks and stack depth counting, so
it installs no signal handlers in the host.

Requirements: WABT (wasm2c and its wasm2c/ runtime sources; `brew install
wabt`), clang, and on Apple platforms Xcode's ld and lipo. `slice` uses the
package's Swift toolchain instead of clang, as guest.py does.
"""

import argparse
import plistlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gles2  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RT_H = ROOT / "Sources" / "CRuntime" / "include" / "rt.h"
GL_SHIM = ROOT / "Sources" / "CRuntimeGL" / "gl_shim.c"
GL_INCLUDES = [GL_SHIM.parent / "include", gles2.GUEST_HEADER.parent]
EXPORTS = ("rt_main", "rt_dispatch", "rt_finalize")
SECTIONS = ("rt.abi", "rt.contracts", "rt.manifest")
SUPPORT = Path(__file__).resolve().parent / "support"
FREESTANDING = "wasm2c-freestanding"
# The libc headers wasm-rt, the translated module and the shim include. For
# a Linux slice each is a file that includes wasm2c-freestanding.h.
LIBC_HEADERS = ("alloca.h", "assert.h", "math.h", "pthread.h", "setjmp.h", "signal.h", "stdio.h",
                "stdlib.h", "string.h", "time.h", "unistd.h", "sys/mman.h")
# How a Linux slice is compiled, beyond WASM_RT_DEFINES:
# - wasm-rt takes its memory from malloc, not mmap, which isn't in the set;
# - no assertions, which would call the libc's own failure function;
# - no thread-local storage: the guest has one thread (the header says more).
FREESTANDING_DEFINES = ["-DWASM_RT_USE_MMAP=0", "-DNDEBUG", "-D_Thread_local="]

# wasm-rt without signal handlers: explicit bounds checks, mmap-backed
# memory (it never moves on 64-bit hosts), and stack depth counting.
WASM_RT_DEFINES = [
    "-DWASM_RT_MEMCHECK_GUARD_PAGES=0",
    "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1",
    "-DWASM_RT_STACK_DEPTH_COUNT=1",
    "-DWASM_RT_SKIP_SIGNAL_RECOVERY=1",
]


class ShimError(Exception):
    pass


# ---------------------------------------------------------------------------
# rt.h
# ---------------------------------------------------------------------------

# Scalar types: one wasm i32.
SCALARS = {"rt_obj", "rt_class_id", "rt_method_id", "uint32_t", "int32_t", "rt_status", "size_t"}
# Pointer element types: their size in guest memory.
ELEMENTS = {"char": 1, "void": 1, "rt_slot": 8, "rt_class_id": 4, "rt_method_decl": 16}


class Parameter:

    def __init__(self, text):
        match = re.match(r"^(const\s+)?(\w+)\s*(\*?)\s*(\w+)$", " ".join(text.split()))
        if not match:
            raise ShimError(f"rt.h: can't read parameter {text!r}")
        self.const = bool(match.group(1))
        self.type = match.group(2)
        self.pointer = bool(match.group(3))
        self.name = match.group(4)
        if self.pointer and self.type not in ELEMENTS:
            raise ShimError(f"rt.h: no rule for {self.type} *{self.name}")
        if not self.pointer and self.type not in SCALARS:
            raise ShimError(f"rt.h: no rule for {self.type} {self.name}")


class Import:

    def __init__(self, name, result, parameters):
        self.name = name
        self.result = result
        self.parameters = parameters
        # Every pointer is followed by its element count.
        for index, parameter in enumerate(parameters):
            if parameter.pointer:
                following = parameters[index + 1] if index + 1 < len(parameters) else None
                if not following or following.pointer or following.type not in ("size_t", "uint32_t"):
                    raise ShimError(f"rt.h: rt_{name}'s {parameter.name} isn't followed by its count")
                parameter.count = following.name


def read_imports(path):
    text = re.sub(r"/\*.*?\*/", " ", Path(path).read_text(), flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    imports = []
    for match in re.finditer(r"RT_IMPORT\((\w+)\)\s*([\w\s]+?)\s*\brt_(\w+)\s*\(([^)]*)\)\s*;", text):
        name, result, function, parameters = match.groups()
        if name != function:
            raise ShimError(f"rt.h: RT_IMPORT({name}) declares rt_{function}")
        parameters = [Parameter(p) for p in parameters.split(",") if p.strip() not in ("", "void")]
        result = " ".join(result.split())
        if result != "void" and result not in SCALARS:
            raise ShimError(f"rt.h: no rule for rt_{name}'s result {result}")
        imports.append(Import(name, result, parameters))
    if not imports:
        raise ShimError(f"no RT_IMPORT declarations in {path}")
    return imports


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

PRELUDE = r"""/* Generated by Scripts/wasm2c-shim.py from rt.h. Do not edit.
 *
 * Makes a wasm2c-translated App.wasm look like a native slice: it exports
 * rt_main, rt_dispatch and rt_finalize, and its rt.* imports call the host's
 * rt_* functions. Guest memory is only read or written through bounds-checked
 * copies, so it stays correct if a call back into the guest grows its memory.
 * Single-threaded, like the runtime (§6.4).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "rt.h"
#include "wasm-rt-impl.h"
#include "@HEADER@"

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "wasm memory is little-endian; this shim copies it as is"
#endif

#ifndef RT_WASM2C_WRITE
#ifdef RT_WASM2C_WRITE_FUNCTION
/* The host's function that receives the guest's stdout and stderr, such as
 * one that logs them (build --define RT_WASM2C_WRITE_FUNCTION=name). */
void RT_WASM2C_WRITE_FUNCTION(int fd, const void *data, size_t size);
#define RT_WASM2C_WRITE(fd, data, size) RT_WASM2C_WRITE_FUNCTION((fd), (data), (size))
#else
/* Where the guest's stdout and stderr go. A host may define it to log. */
#define RT_WASM2C_WRITE(fd, data, size) ((void)write((fd), (data), (size)))
#endif
#endif

struct w2c_rt { int unused; };
struct w2c_wasi__snapshot__preview1 { int unused; };

static @MODULE@ rt_w2c_instance;
static struct w2c_rt rt_w2c_rt;
static struct w2c_wasi__snapshot__preview1 rt_w2c_wasi;
static int rt_w2c_ready;

static wasm_rt_memory_t *rt_w2c_memory(void) {
    return @PREFIX@_memory(&rt_w2c_instance);
}

/* Traps if [offset, offset + count * size) isn't in guest memory. */
static void rt_w2c_check(uint32_t offset, uint64_t count, uint64_t size) {
    uint64_t end = (uint64_t)offset + count * size;
    if (count > UINT32_MAX || end > rt_w2c_memory()->size) {
        wasm_rt_trap(WASM_RT_TRAP_OOB);
    }
}

/* A host copy of a guest array, or NULL for a null or empty one. Output
 * arrays are copied in too, so the parts the host doesn't write keep their
 * values when copied back. */
static void *rt_w2c_copy_in(uint32_t offset, uint64_t count, uint64_t size) {
    if (offset == 0 || count == 0) {
        return NULL;
    }
    rt_w2c_check(offset, count, size);
    void *copy = malloc((size_t)(count * size));
    if (!copy) {
        wasm_rt_trap(WASM_RT_TRAP_EXHAUSTION);
    }
    memcpy(copy, rt_w2c_memory()->data + offset, (size_t)(count * size));
    return copy;
}

static void rt_w2c_copy_out(uint32_t offset, const void *copy, uint64_t count, uint64_t size) {
    if (copy) {
        memcpy(rt_w2c_memory()->data + offset, copy, (size_t)(count * size));
    }
}

/* rt_method_decl in guest memory: four u32s. Its strings are copied too. */
static rt_method_decl *rt_w2c_methods_in(uint32_t offset, uint32_t count, char ***strings) {
    *strings = NULL;
    uint32_t *guest = rt_w2c_copy_in(offset, count, 16);
    if (!guest) {
        return NULL;
    }
    rt_method_decl *methods = calloc(count, sizeof(rt_method_decl));
    *strings = calloc((size_t)count * 2, sizeof(char *));
    if (!methods || !*strings) {
        wasm_rt_trap(WASM_RT_TRAP_EXHAUSTION);
    }
    for (uint32_t i = 0; i < count; i++) {
        (*strings)[2 * i] = rt_w2c_copy_in(guest[4 * i], guest[4 * i + 1], 1);
        (*strings)[2 * i + 1] = rt_w2c_copy_in(guest[4 * i + 2], guest[4 * i + 3], 1);
        methods[i].name = (*strings)[2 * i];
        methods[i].name_len = guest[4 * i + 1];
        methods[i].sig = (*strings)[2 * i + 1];
        methods[i].sig_len = guest[4 * i + 3];
    }
    free(guest);
    return methods;
}

static void rt_w2c_methods_free(rt_method_decl *methods, char **strings, uint32_t count) {
    if (strings) {
        for (uint32_t i = 0; i < 2 * count; i++) {
            free(strings[i]);
        }
    }
    free(strings);
    free(methods);
}

static uint32_t rt_w2c_u32(size_t value) {
    return value > UINT32_MAX ? UINT32_MAX : (uint32_t)value;
}

/* ------------------------------------------------------------------------- */
/* rt.* imports                                                               */
/* ------------------------------------------------------------------------- */
"""

EXPORTS_C = r"""
/* ------------------------------------------------------------------------- */
/* Exports                                                                    */
/* ------------------------------------------------------------------------- */

/* Calls into the module with its own trap target, restoring the outer one
 * after: the guest can call the host, which can call the guest again. */
#define RT_W2C_GUARDED(trap, ...)                                             \
    do {                                                                      \
        wasm_rt_jmp_buf rt_w2c_outer = g_wasm_rt_jmp_buf;                    \
        uint32_t rt_w2c_depth = wasm_rt_call_stack_depth;                    \
        uint32_t rt_w2c_saved = wasm_rt_saved_call_stack_depth;              \
        wasm_rt_saved_call_stack_depth = rt_w2c_depth;                       \
        trap = (wasm_rt_trap_t)WASM_RT_SETJMP(g_wasm_rt_jmp_buf);            \
        if (trap == WASM_RT_TRAP_NONE) {                                     \
            __VA_ARGS__;                                                     \
        }                                                                     \
        g_wasm_rt_jmp_buf = rt_w2c_outer;                                    \
        wasm_rt_call_stack_depth = rt_w2c_depth;                             \
        wasm_rt_saved_call_stack_depth = rt_w2c_saved;                       \
    } while (0)

static void rt_w2c_report(wasm_rt_trap_t trap) {
    static const char prefix[] = "wasm2c: guest trapped: ";
    const char *reason = wasm_rt_strerror(trap);
    RT_WASM2C_WRITE(2, prefix, sizeof(prefix) - 1);
    RT_WASM2C_WRITE(2, reason, strlen(reason));
    RT_WASM2C_WRITE(2, "\n", 1);
}

/* Instantiates the module and runs its WASI reactor initializer, once. */
static wasm_rt_trap_t rt_w2c_start(void) {
    if (rt_w2c_ready) {
        return WASM_RT_TRAP_NONE;
    }
    wasm_rt_init();
    @INSTANTIATE@(&rt_w2c_instance, @GL_INSTANCE@&rt_w2c_rt, &rt_w2c_wasi);
    rt_w2c_ready = 1;
    volatile wasm_rt_trap_t trap;
    RT_W2C_GUARDED(trap, @PREFIX@_0x5Finitialize(&rt_w2c_instance));
    return trap;
}

__attribute__((visibility("default")))
rt_status rt_main(void) {
    wasm_rt_trap_t trap = rt_w2c_start();
    volatile uint32_t status = RT_ERR_THROWN;
    if (trap == WASM_RT_TRAP_NONE) {
        RT_W2C_GUARDED(trap, status = @PREFIX@_rt_main(&rt_w2c_instance));
    }
    if (trap != WASM_RT_TRAP_NONE) {
        rt_w2c_report(trap);
        return RT_ERR_THROWN;
    }
    return (rt_status)status;
}

__attribute__((visibility("default")))
rt_status rt_dispatch(uint32_t context, uint32_t index, rt_obj self,
                      const rt_slot *args, uint32_t nargs,
                      rt_slot *ret, uint32_t nret) {
    if (!rt_w2c_ready) {
        return RT_ERR_NOT_FOUND;
    }
    volatile uint32_t status = RT_ERR_THROWN;
    volatile uint32_t guest_args = 0, guest_ret = 0;
    wasm_rt_trap_t trap;
    RT_W2C_GUARDED(trap, {
        if (nargs > 0) {
            guest_args = @PREFIX@_rt_alloc(&rt_w2c_instance, nargs * 8u);
            rt_w2c_check(guest_args, nargs, 8);
            memcpy(rt_w2c_memory()->data + guest_args, args, (size_t)nargs * 8);
        }
        if (nret > 0) {
            guest_ret = @PREFIX@_rt_alloc(&rt_w2c_instance, nret * 8u);
            rt_w2c_check(guest_ret, nret, 8);
            memset(rt_w2c_memory()->data + guest_ret, 0, (size_t)nret * 8);
        }
        status = @PREFIX@_rt_dispatch(&rt_w2c_instance, context, index, self,
                                      guest_args, nargs, guest_ret, nret);
        if (nret > 0) {
            memcpy(ret, rt_w2c_memory()->data + guest_ret, (size_t)nret * 8);
        }
        if (guest_args) {
            @PREFIX@_rt_free(&rt_w2c_instance, guest_args);
        }
        if (guest_ret) {
            @PREFIX@_rt_free(&rt_w2c_instance, guest_ret);
        }
    });
    if (trap != WASM_RT_TRAP_NONE) {
        rt_w2c_report(trap);
        return RT_ERR_THROWN;
    }
    return (rt_status)status;
}

__attribute__((visibility("default")))
void rt_finalize(uint32_t context) {
    if (!rt_w2c_ready) {
        return;
    }
    wasm_rt_trap_t trap;
    RT_W2C_GUARDED(trap, @PREFIX@_rt_finalize(&rt_w2c_instance, context));
    if (trap != WASM_RT_TRAP_NONE) {
        rt_w2c_report(trap);
    }
}
"""

# WASI preview 1, as far as Embedded Swift's wasi-libc reaches: no files,
# no arguments or environment, stdout and stderr, clocks, randomness.
WASI_C = r"""
/* ------------------------------------------------------------------------- */
/* WASI preview 1 (minimal)                                                   */
/* ------------------------------------------------------------------------- */

#define RT_W2C_WASI(name) w2c_wasi__snapshot__preview1_##name
typedef struct w2c_wasi__snapshot__preview1 rt_w2c_wasi_t;

enum { RT_WASI_SUCCESS = 0, RT_WASI_BADF = 8, RT_WASI_INVAL = 28, RT_WASI_NOSYS = 52, RT_WASI_SPIPE = 70 };

static void rt_w2c_store32(uint32_t offset, uint32_t value) {
    rt_w2c_check(offset, 1, 4);
    memcpy(rt_w2c_memory()->data + offset, &value, 4);
}

static void rt_w2c_store64(uint32_t offset, uint64_t value) {
    rt_w2c_check(offset, 1, 8);
    memcpy(rt_w2c_memory()->data + offset, &value, 8);
}

uint32_t RT_W2C_WASI(fd_write)(rt_w2c_wasi_t *wasi, uint32_t fd, uint32_t iovs, uint32_t count,
                               uint32_t written) {
    if (fd != 1 && fd != 2) {
        return RT_WASI_BADF;
    }
    uint32_t *vectors = rt_w2c_copy_in(iovs, count, 8);
    uint64_t total = 0;
    for (uint32_t i = 0; i < count; i++) {
        rt_w2c_check(vectors[2 * i], vectors[2 * i + 1], 1);
        RT_WASM2C_WRITE((int)fd, rt_w2c_memory()->data + vectors[2 * i], vectors[2 * i + 1]);
        total += vectors[2 * i + 1];
    }
    free(vectors);
    rt_w2c_store32(written, (uint32_t)total);
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(fd_close)(rt_w2c_wasi_t *wasi, uint32_t fd) {
    return RT_WASI_BADF;
}

uint32_t RT_W2C_WASI(fd_seek)(rt_w2c_wasi_t *wasi, uint32_t fd, uint64_t offset, uint32_t whence,
                              uint32_t result) {
    return fd <= 2 ? RT_WASI_SPIPE : RT_WASI_BADF;
}

/* fdstat: u8 filetype, u16 flags, u64 rights, u64 inherited rights. */
uint32_t RT_W2C_WASI(fd_fdstat_get)(rt_w2c_wasi_t *wasi, uint32_t fd, uint32_t stat) {
    if (fd > 2) {
        return RT_WASI_BADF;
    }
    uint8_t value[24] = {0};
    value[0] = 2; /* character device */
    uint64_t rights = fd == 0 ? 2 /* fd_read */ : 64 /* fd_write */;
    memcpy(value + 8, &rights, 8);
    rt_w2c_check(stat, 1, 24);
    memcpy(rt_w2c_memory()->data + stat, value, 24);
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(fd_prestat_get)(rt_w2c_wasi_t *wasi, uint32_t fd, uint32_t prestat) {
    return RT_WASI_BADF;
}

uint32_t RT_W2C_WASI(fd_prestat_dir_name)(rt_w2c_wasi_t *wasi, uint32_t fd, uint32_t path, uint32_t length) {
    return RT_WASI_BADF;
}

uint32_t RT_W2C_WASI(random_get)(rt_w2c_wasi_t *wasi, uint32_t buffer, uint32_t length) {
    rt_w2c_check(buffer, length, 1);
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__ANDROID__)
    arc4random_buf(rt_w2c_memory()->data + buffer, length);
#else
    for (uint32_t done = 0; done < length;) {
        uint32_t chunk = length - done > 256 ? 256 : length - done;
        if (getentropy(rt_w2c_memory()->data + buffer + done, chunk) != 0) {
            return RT_WASI_INVAL;
        }
        done += chunk;
    }
#endif
    return RT_WASI_SUCCESS;
}

static int rt_w2c_clock(uint32_t id, clockid_t *clock) {
    switch (id) {
    case 0: *clock = CLOCK_REALTIME; return 1;
    case 1: *clock = CLOCK_MONOTONIC; return 1;
    case 2: *clock = CLOCK_PROCESS_CPUTIME_ID; return 1;
    case 3: *clock = CLOCK_THREAD_CPUTIME_ID; return 1;
    default: return 0;
    }
}

uint32_t RT_W2C_WASI(clock_time_get)(rt_w2c_wasi_t *wasi, uint32_t id, uint64_t precision, uint32_t time) {
    clockid_t clock;
    struct timespec now;
    if (!rt_w2c_clock(id, &clock) || clock_gettime(clock, &now) != 0) {
        return RT_WASI_INVAL;
    }
    rt_w2c_store64(time, (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec);
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(clock_res_get)(rt_w2c_wasi_t *wasi, uint32_t id, uint32_t resolution) {
    clockid_t clock;
    struct timespec value;
    if (!rt_w2c_clock(id, &clock) || clock_getres(clock, &value) != 0) {
        return RT_WASI_INVAL;
    }
    rt_w2c_store64(resolution, (uint64_t)value.tv_sec * 1000000000u + (uint64_t)value.tv_nsec);
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(args_sizes_get)(rt_w2c_wasi_t *wasi, uint32_t count, uint32_t size) {
    rt_w2c_store32(count, 0);
    rt_w2c_store32(size, 0);
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(args_get)(rt_w2c_wasi_t *wasi, uint32_t argv, uint32_t buffer) {
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(environ_sizes_get)(rt_w2c_wasi_t *wasi, uint32_t count, uint32_t size) {
    rt_w2c_store32(count, 0);
    rt_w2c_store32(size, 0);
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(environ_get)(rt_w2c_wasi_t *wasi, uint32_t environ, uint32_t buffer) {
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(sched_yield)(rt_w2c_wasi_t *wasi) {
    return RT_WASI_SUCCESS;
}

uint32_t RT_W2C_WASI(poll_oneoff)(rt_w2c_wasi_t *wasi, uint32_t in, uint32_t out, uint32_t count,
                                  uint32_t events) {
    return RT_WASI_NOSYS;
}

/* The guest can't end the host's process: exiting is a trap. */
void RT_W2C_WASI(proc_exit)(rt_w2c_wasi_t *wasi, uint32_t code) {
    wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}
"""

WASI_FUNCTIONS = {
    "fd_write", "fd_close", "fd_seek", "fd_fdstat_get", "fd_prestat_get", "fd_prestat_dir_name",
    "random_get", "clock_time_get", "clock_res_get", "args_sizes_get", "args_get",
    "environ_sizes_get", "environ_get", "sched_yield", "poll_oneoff", "proc_exit",
}


def import_function(item):
    """The C wrapper wasm2c calls for one rt.* import."""
    arguments = ", ".join(["struct w2c_rt *rt"] + [f"uint32_t {p.name}" for p in item.parameters])
    result = "void" if item.result == "void" else "uint32_t"
    lines = [f"{result} w2c_rt_{item.name}({arguments}) {{"]
    call = []
    cleanup = []
    for parameter in item.parameters:
        if not parameter.pointer:
            cast = "(size_t)" if parameter.type == "size_t" else f"({parameter.type})"
            call.append(f"{cast}{parameter.name}")
        elif parameter.type == "rt_method_decl":
            lines.append(f"    char **{parameter.name}_strings;")
            lines.append(f"    rt_method_decl *{parameter.name}_host = "
                         f"rt_w2c_methods_in({parameter.name}, {parameter.count}, &{parameter.name}_strings);")
            call.append(f"{parameter.name}_host")
            cleanup.append(f"    rt_w2c_methods_free({parameter.name}_host, {parameter.name}_strings, {parameter.count});")
        else:
            size = ELEMENTS[parameter.type]
            c_type = f"{'const ' if parameter.const else ''}{parameter.type} *"
            lines.append(f"    void *{parameter.name}_host = rt_w2c_copy_in({parameter.name}, {parameter.count}, {size});")
            call.append(f"({c_type}){parameter.name}_host")
            if not parameter.const:
                cleanup.append(f"    rt_w2c_copy_out({parameter.name}, {parameter.name}_host, {parameter.count}, {size});")
            cleanup.append(f"    free({parameter.name}_host);")
    invocation = f"rt_{item.name}({', '.join(call)})"
    if item.result == "void":
        lines.append(f"    {invocation};")
    elif item.result == "size_t":
        lines.append(f"    uint32_t result = rt_w2c_u32({invocation});")
    else:
        lines.append(f"    uint32_t result = (uint32_t){invocation};")
    lines.extend(cleanup)
    if item.result != "void":
        lines.append("    return result;")
    lines.append("}")
    return "\n".join(lines)


GL_C = r"""
/* ------------------------------------------------------------------------- */
/* env.gl imports (§8.1)                                                      */
/* ------------------------------------------------------------------------- */

/* The GL shim calls the platform's gl* symbols themselves, so this slice
 * links like a native one. gl_shim.c must be compiled with it too. */
#ifndef RT_GL_DIRECT
#define RT_GL_DIRECT
#endif
#include "gl_shim.h"

struct @GL@ { int unused; };

static struct @GL@ rt_w2c_gl;
static rt_gl_context rt_w2c_gl_context;
static uint32_t rt_w2c_gl_generation;
static int rt_w2c_gl_ready;

/* The host defines this: a number that changes whenever the GL context the
 * guest draws in is a new one (it was lost and made again). The shim keeps
 * track of buffer bindings to stop a guest from passing GL a host address;
 * a new context has none of them, and this is how the shim learns of it.
 * A host whose context is never replaced returns a constant. */
uint32_t rt_gl_context_generation(void);

static rt_gl_context *rt_w2c_gl_enter(void) {
    uint32_t generation = rt_gl_context_generation();
    if (!rt_w2c_gl_ready || generation != rt_w2c_gl_generation) {
        rt_gl_context_init(&rt_w2c_gl_context);
        rt_w2c_gl_generation = generation;
        rt_w2c_gl_ready = 1;
    }
    wasm_rt_memory_t *memory = rt_w2c_memory();
    rt_w2c_gl_context.base = memory->data;
    rt_w2c_gl_context.size = memory->size;
    return &rt_w2c_gl_context;
}

/* A pointer outside guest memory traps the guest. */
static void rt_w2c_gl_leave(void) {
    if (rt_w2c_gl_context.trapped) {
        rt_w2c_gl_context.trapped = 0;
        wasm_rt_trap(WASM_RT_TRAP_OOB);
    }
}

/* glGetString: the host's string, copied once into memory from the guest's
 * rt_alloc. A guest may keep the pointer, so the copies are never freed. */
static struct { uint32_t name, offset; } rt_w2c_gl_strings[8];
static uint32_t rt_w2c_gl_string_count;

uint32_t @GL@_glGetString(struct @GL@ *gl, uint32_t name) {
    for (uint32_t i = 0; i < rt_w2c_gl_string_count; i++) {
        if (rt_w2c_gl_strings[i].name == name) {
            return rt_w2c_gl_strings[i].offset;
        }
    }
    const uint8_t *string = rt_gl_get_string(rt_w2c_gl_enter(), name);
    if (!string) {
        return 0;
    }
    size_t size = strlen((const char *)string) + 1;
    uint32_t offset = @PREFIX@_rt_alloc(&rt_w2c_instance, rt_w2c_u32(size));
    if (offset == 0) {
        return 0;
    }
    /* Read the memory again: the allocation may have grown it. */
    rt_w2c_check(offset, size, 1);
    memcpy(rt_w2c_memory()->data + offset, string, size);
    if (rt_w2c_gl_string_count < sizeof(rt_w2c_gl_strings) / sizeof(rt_w2c_gl_strings[0])) {
        rt_w2c_gl_strings[rt_w2c_gl_string_count].name = name;
        rt_w2c_gl_strings[rt_w2c_gl_string_count].offset = offset;
        rt_w2c_gl_string_count++;
    }
    return offset;
}

"""


def mangle_module(name):
    """A wasm import module's name as wasm2c spells it in C identifiers."""
    return "".join(c if c.isalnum() else "__" if c == "_" else f"0x{ord(c):02X}" for c in name)


GL_STRUCT = "w2c_" + mangle_module(gles2.IMPORT_MODULE)


def gl_function(function):
    """The C wrapper wasm2c calls for one env.gl import."""
    parameters = [f"struct {GL_STRUCT} *gl"]
    parameters += [f"{'float' if p.is_float else 'uint32_t'} {p.name}" for p in function.parameters]
    arguments = ", ".join(["rt_w2c_gl_enter()"] + [p.name for p in function.parameters])
    call = f"rt_gl_{function.name}({arguments})"
    if function.result == "void":
        body = f"    {call};\n    rt_w2c_gl_leave();"
        result = "void"
    else:
        body = f"    uint32_t result = {call};\n    rt_w2c_gl_leave();\n    return result;"
        result = "uint32_t"
    return f"{result} {GL_STRUCT}_{function.name}({', '.join(parameters)}) {{\n{body}\n}}"


def gl_functions():
    wrappers = [gl_function(f) for f in gles2.functions() if not f.returns_pointer]
    return GL_C + "\n\n".join(wrappers) + "\n"


def generate(imports, name, header, gl=False):
    prefix = f"w2c_{name}"
    replacements = {"@HEADER@": header, "@MODULE@": prefix, "@PREFIX@": prefix,
                    "@INSTANTIATE@": f"wasm2c_{name}_instantiate",
                    "@GL_INSTANCE@": "&rt_w2c_gl, " if gl else "", "@GL@": GL_STRUCT}
    text = PRELUDE + "\n\n".join(import_function(item) for item in imports) + "\n"
    text += (gl_functions() if gl else "") + EXPORTS_C + WASI_C
    for key, value in replacements.items():
        text = text.replace(key, value)
    return text


# ---------------------------------------------------------------------------
# App.wasm
# ---------------------------------------------------------------------------

def wasm_module(data):
    """Imports ("module.name") and custom sections ({name: bytes}) of a module."""
    if data[:4] != b"\0asm":
        raise ShimError("not a wasm module")

    def leb(i):
        result = shift = 0
        while True:
            byte = data[i]
            i += 1
            result |= (byte & 0x7F) << shift
            shift += 7
            if byte < 0x80:
                return result, i

    def name(i):
        length, i = leb(i)
        return data[i:i + length].decode(), i + length

    imports, custom = [], {}
    i = 8
    while i < len(data):
        section, i = data[i], i + 1
        size, i = leb(i)
        end = i + size
        if section == 0:
            title, j = name(i)
            custom[title] = bytes(data[j:end])
        elif section == 2:
            count, j = leb(i)
            for _ in range(count):
                module, j = name(j)
                field, j = name(j)
                kind, j = data[j], j + 1
                if kind == 0:
                    _, j = leb(j)
                elif kind in (1, 2):
                    if kind == 1:
                        j += 1
                    flags, j = leb(j)
                    _, j = leb(j)
                    if flags & 1:
                        _, j = leb(j)
                elif kind == 3:
                    j += 2
                imports.append(f"{module}.{field}")
        i = end
    return imports, custom


def check_imports(wasm, imports):
    """Imports the shim doesn't provide."""
    names, _ = wasm_module(Path(wasm).read_bytes())
    provided = {f"rt.{item.name}" for item in imports}
    provided |= {f"wasi_snapshot_preview1.{name}" for name in WASI_FUNCTIONS}
    provided |= gles2.imports()
    return sorted(set(names) - provided)


def uses_gl(wasm):
    """Whether the module imports any of env.gl."""
    names, _ = wasm_module(Path(wasm).read_bytes())
    return any(name.startswith(gles2.IMPORT_MODULE + ".") for name in names)


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

def run(arguments):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True)
    if result.returncode != 0:
        command = " ".join(str(a) for a in arguments[:3])
        raise ShimError(f"{command} … failed:\n{(result.stderr or result.stdout).strip()}")
    return result.stdout


def wabt_runtime():
    """WABT's wasm2c runtime directory (wasm-rt-impl.c) and include directory."""
    wasm2c = shutil.which("wasm2c")
    if not wasm2c:
        raise ShimError("wasm2c not found; install WABT (brew install wabt)")
    prefix = Path(wasm2c).resolve().parent.parent
    for runtime in (prefix / "share" / "wabt" / "wasm2c", prefix / "wasm2c"):
        if (runtime / "wasm-rt-impl.c").exists():
            include = prefix / "include"
            return wasm2c, runtime, include if (include / "wasm-rt.h").exists() else runtime
    raise ShimError(f"WABT's wasm-rt-impl.c not found under {prefix}")


def compiler(sdk="macosx"):
    """clang for the target: Xcode's, with the SDK, on Apple platforms."""
    return ["xcrun", "--sdk", sdk, "clang"] if platform.system() == "Darwin" else ["clang"]


def export_sources(wasm, output, name="app"):
    """Translates `wasm` and gathers everything a C compiler needs in `output`."""
    wasm = Path(wasm).resolve()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    wasm2c, runtime, include = wabt_runtime()
    imports = read_imports(RT_H)
    missing = check_imports(wasm, imports)
    if missing:
        raise ShimError(f"{wasm.name} imports what the shim doesn't provide: {', '.join(missing)}")
    gl = uses_gl(wasm)
    run([wasm2c, wasm, "-n", name, "-o", output / f"{name}.c"])
    (output / "rt_wasm2c.c").write_text(generate(imports, name, f"{name}.h", gl=gl))
    for directory in {runtime, include}:
        for path in directory.glob("wasm-rt*"):
            shutil.copy(path, output / path.name)
    shutil.copy(RT_H, output / RT_H.name)
    sources = [f"{name}.c", "rt_wasm2c.c", "wasm-rt-impl.c", "wasm-rt-mem-impl.c"]
    defines = [define[2:] for define in WASM_RT_DEFINES]
    if gl:
        shutil.copy(GL_SHIM, output / GL_SHIM.name)
        for directory in GL_INCLUDES:
            for path in directory.glob("*.h"):
                shutil.copy(path, output / path.name)
        sources.append(GL_SHIM.name)
        defines.append("RT_GL_DIRECT")
    (output / "sources.txt").write_text("".join(f"{source}\n" for source in sources))
    (output / "defines.txt").write_text("".join(f"{define}\n" for define in defines))
    return output


def build(wasm, output, targets, sdk, name="app", defines=()):
    wasm = Path(wasm).resolve()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    wasm2c, runtime, include = wabt_runtime()
    imports = read_imports(RT_H)
    missing = check_imports(wasm, imports)
    if missing:
        raise ShimError(f"{wasm.name} imports what the shim doesn't provide: {', '.join(missing)}")

    gl = uses_gl(wasm)
    run([wasm2c, wasm, "-n", name, "-o", output / f"{name}.c"])
    (output / "rt_wasm2c.c").write_text(generate(imports, name, f"{name}.h", gl=gl))
    _, custom = wasm_module(wasm.read_bytes())
    sections = {}
    for section in SECTIONS:
        if section in custom:
            path = output / f"{section}.bin"
            path.write_bytes(custom[section])
            sections[section] = path

    apple = platform.system() == "Darwin"
    targets = targets or [None]
    archives = []
    for target in targets:
        directory = output / (target or "host")
        directory.mkdir(exist_ok=True)
        clang = compiler(sdk)
        flags = ["-O2", "-fPIC", "-fvisibility=hidden", "-w", *WASM_RT_DEFINES,
                 *[f"-D{define}" for define in defines],
                 "-I", output, "-I", runtime, "-I", include, "-I", RT_H.parent]
        if target:
            flags += ["-target", target]
        sources = [output / f"{name}.c", output / "rt_wasm2c.c",
                   runtime / "wasm-rt-impl.c", runtime / "wasm-rt-mem-impl.c"]
        if gl:
            flags += ["-DRT_GL_DIRECT", *[f"-I{path}" for path in GL_INCLUDES]]
            sources.append(GL_SHIM)
        objects = []
        for source in sources:
            obj = directory / f"{source.stem}.o"
            run([*clang, *flags, "-c", source, "-o", obj])
            objects.append(obj)
        sealed = directory / "app.o"
        if apple:
            exports = directory / "exports.txt"
            exports.write_text("".join(f"_{s}\n" for s in EXPORTS))
            arch = run(["xcrun", "lipo", "-archs", objects[0]]).split()[0]
            created = []
            for section, path in sections.items():
                created += ["-sectcreate", "__DATA", "__" + section.replace(".", "_"), path]
            run(["xcrun", "ld", "-r", "-arch", arch, *created, "-exported_symbols_list", exports,
                 *objects, "-o", sealed])
        else:
            run(["ld.lld" if shutil.which("ld.lld") else "ld", "-r", "-o", sealed, *objects])
            run(["objcopy", *[f"--keep-global-symbol={s}" for s in EXPORTS],
                 *[f"--add-section=.{s.replace('.', '_')}={p}" for s, p in sections.items()], sealed])
        defined = run(["nm", "-gU" if apple else "--defined-only", sealed]).split()
        exported = sorted(s.lstrip("_") for s in defined if s.lstrip("_").startswith("rt_"))
        if apple and exported != sorted(EXPORTS):
            raise ShimError(f"{sealed} exports {exported}, expected {list(EXPORTS)}")
        archive = directory / "libapp.a"
        archive.unlink(missing_ok=True)
        run(["ar", "rcs", archive, sealed])
        archives.append(archive)

    result = output / "libapp.a"
    if len(archives) == 1:
        shutil.copy(archives[0], result)
    else:
        run(["xcrun", "lipo", "-create", *archives, "-output", result])
    return result


def build_slice(wasm, output, target_id, name="app", defines=()):
    """Builds `wasm` as a Linux slice: `output`/<target_id>/libapp.so."""
    import guest
    config = guest.TARGETS.get(target_id)
    if not config or not config.get("shared"):
        linux = ", ".join(t for t, c in guest.TARGETS.items() if c.get("shared"))
        raise ShimError(f"{target_id} isn't a Linux target ({linux})")
    wasm = Path(wasm).resolve()
    output = Path(output).resolve()
    directory = output / target_id
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    wasm2c, runtime, include = wabt_runtime()
    imports = read_imports(RT_H)
    missing = check_imports(wasm, imports)
    if missing:
        raise ShimError(f"{wasm.name} imports what the shim doesn't provide: {', '.join(missing)}")
    gl = uses_gl(wasm)
    run([wasm2c, wasm, "-n", name, "-o", directory / f"{name}.c"])
    (directory / "rt_wasm2c.c").write_text(generate(imports, name, f"{name}.h", gl=gl))

    headers = directory / "libc"
    for header in LIBC_HEADERS:
        path = headers / header
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'#include "{FREESTANDING}.h"\n')
    try:
        toolchain = guest.Toolchain(ROOT)
        flags = ["-target", config["triple"], "-O2", "-fPIC", "-fvisibility=hidden", "-fno-stack-protector",
                 "-ffreestanding", "-w", *config.get("cflags", ()), *WASM_RT_DEFINES, *FREESTANDING_DEFINES,
                 *[f"-D{define}" for define in defines],
                 "-I", headers, "-I", SUPPORT, "-I", directory, "-I", runtime, "-I", include, "-I", RT_H.parent]
        if config.get("cpu"):
            flags.append(f"-march={config['cpu']}")
        sources = [directory / f"{name}.c", directory / "rt_wasm2c.c",
                   runtime / "wasm-rt-impl.c", runtime / "wasm-rt-mem-impl.c",
                   SUPPORT / f"{FREESTANDING}.c", *[SUPPORT / file for file in config.get("support", ())]]
        if gl:
            flags += ["-DRT_GL_DIRECT", *[f"-I{path}" for path in GL_INCLUDES]]
            sources.append(GL_SHIM)
        objects = []
        for source in sources:
            obj = directory / f"{source.stem}.o"
            guest.run([toolchain.tool("clang"), *flags, "-c", source, "-o", obj], quiet=True)
            objects.append(obj)
        sealed = directory / "app.o"
        guest.run([toolchain.tool("ld.lld"), "-r", "-o", sealed, *objects], quiet=True)
        added = []
        _, custom = wasm_module(wasm.read_bytes())
        for section in SECTIONS:
            if section in custom:
                path = directory / f"{section}.bin"
                path.write_bytes(custom[section])
                added.append(f"--add-section=.{section.replace('.', '_')}={path}")
        guest.run([toolchain.tool("llvm-objcopy"), *[f"--keep-global-symbol={s}" for s in EXPORTS], *added, sealed],
                  quiet=True)
        shared = guest.link_shared(toolchain, sealed, directory)
        problems = guest.check_shared(toolchain, shared, manifest=custom.get("rt.manifest"))
    except guest.BuildError as error:
        raise ShimError(str(error))
    if problems:
        raise ShimError(f"{target_id}, {shared.name}:\n  " + "\n  ".join(problems))
    return shared


def add_slices(bundle, target_ids, defines=()):
    """Builds Linux slices from a bundle's App.wasm and adds them to it."""
    import guest
    bundle = Path(bundle).resolve()
    wasm = bundle / "wasm32" / "App.wasm"
    plist = bundle / "Info.plist"
    if not wasm.is_file() or not plist.is_file():
        raise ShimError(f"{bundle} isn't a bundle with wasm32/App.wasm and Info.plist")
    for target_id in target_ids:
        if (bundle / "lib" / target_id).exists():
            raise ShimError(f"{bundle.name} already has a {target_id} slice")
    with tempfile.TemporaryDirectory() as work:
        built = {target_id: build_slice(wasm, work, target_id, defines=defines) for target_id in target_ids}
        for target_id, shared in built.items():
            destination = bundle / "lib" / target_id / shared.name
            destination.parent.mkdir(parents=True)
            shutil.copy(shared, destination)
    with open(plist, "rb") as file:
        info = plistlib.load(file)
    info["RTTargets"] = [*info.get("RTTargets", []), *target_ids]
    with open(plist, "wb") as file:
        plistlib.dump(info, file, sort_keys=True)
    signature = bundle / "_CodeSignature"
    signature.mkdir(exist_ok=True)
    with open(signature / "CodeResources", "wb") as file:
        plistlib.dump(guest.code_resources(bundle), file)
    return [bundle / "lib" / target_id / "libapp.so" for target_id in target_ids]


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1].strip())
    commands = parser.add_subparsers(dest="command", required=True)
    shim = commands.add_parser("shim", help="generate the C shim")
    shim.add_argument("--name", default="app", help="the module name given to wasm2c -n")
    shim.add_argument("--header", help="wasm2c's header; default <name>.h")
    shim.add_argument("--rt-h", default=RT_H)
    shim.add_argument("--wasm", help="App.wasm whose imports to check")
    shim.add_argument("--gl", action="store_true",
                      help="add the env.gl imports; implied when --wasm imports them")
    shim.add_argument("-o", "--output", required=True)
    builder = commands.add_parser("build", help="translate, compile and seal App.wasm into libapp.a")
    builder.add_argument("--wasm", required=True)
    builder.add_argument("--output", required=True)
    builder.add_argument("--target", action="append", help="clang target triple (repeatable); default the host")
    builder.add_argument("--sdk", default="macosx", help="Apple SDK for xcrun (macosx, iphonesimulator, …)")
    builder.add_argument("--define", action="append", default=[], metavar="NAME[=VALUE]",
                         help="C macro for compiling (repeatable), such as "
                              "RT_WASM2C_WRITE_FUNCTION=name to send the guest's stdout and stderr to a host function")
    slicer = commands.add_parser("slice", help="build App.wasm as a Linux slice, libapp.so, a runner loads")
    slicer.add_argument("--wasm", help="App.wasm; with --output")
    slicer.add_argument("--output", help="directory for <target>/libapp.so")
    slicer.add_argument("--bundle", help="a bundle to make the slice from, and add it to")
    slicer.add_argument("--target", action="append", required=True, help="Linux target ID (repeatable)")
    slicer.add_argument("--define", action="append", default=[], metavar="NAME[=VALUE]",
                        help="C macro for compiling (repeatable), as for build")
    exporter = commands.add_parser("sources", help="translate App.wasm and gather the C sources to compile elsewhere")
    exporter.add_argument("--wasm", required=True)
    exporter.add_argument("--output", required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "sources":
            print(f"ok: {export_sources(arguments.wasm, arguments.output)}")
        elif arguments.command == "slice":
            if arguments.bundle and not (arguments.wasm or arguments.output):
                built = add_slices(arguments.bundle, arguments.target, defines=arguments.define)
            elif arguments.wasm and arguments.output and not arguments.bundle:
                built = [build_slice(arguments.wasm, arguments.output, target, defines=arguments.define)
                         for target in arguments.target]
            else:
                raise ShimError("slice takes --bundle, or --wasm with --output")
            for path in built:
                print(f"ok: {path}")
        elif arguments.command == "shim":
            imports = read_imports(arguments.rt_h)
            if arguments.wasm:
                missing = check_imports(arguments.wasm, imports)
                if missing:
                    raise ShimError(f"the module imports what the shim doesn't provide: {', '.join(missing)}")
            gl = arguments.gl or bool(arguments.wasm and uses_gl(arguments.wasm))
            Path(arguments.output).write_text(
                generate(imports, arguments.name, arguments.header or f"{arguments.name}.h", gl=gl))
        else:
            print(f"ok: {build(arguments.wasm, arguments.output, arguments.target, arguments.sdk, defines=arguments.define)}")
    except ShimError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
