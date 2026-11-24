# Linux on 32-bit PowerPC: G4 now, G3 later

**Status:** a plan, not reviewed. Nothing in it is built.

Native slices for Linux on the PowerPC Macs: a G4 slice now, with the
Swift toolchain swift-linux has for 32-bit PowerPC, and a G3 slice once
swift-linux builds for the G3 too. Target IDs take the CPU names Mach-O
gives these processors (`<mach/machine.h>`, `lipo -archs`), so they read
as they do in a Mac's own binaries.

| Target ID | Processors | Mach-O subtype | AltiVec | Status |
|---|---|---|---|---|
| `linux-ppc7400` | G4: 7400, 7410, 7450, 7447, 7448; and a G5 (970) in 32-bit userland | `CPU_SUBTYPE_POWERPC_7400` | yes | now |
| `linux-ppc750` | G3: 750, 750CX, 750FX, 750GX | `CPU_SUBTYPE_POWERPC_750` | no | when swift-linux builds for the G3 |

Each is a `libapp.so`, as every Linux slice is (`DynamicRuntime.md`
§7.5): one sealed ELF object, with the three guest exports and nothing
else visible, naming no library, binding as it loads. It's built
big-endian, 32-bit, hard-float, for the PowerPC SVR4 ABI.

## What shapes it

- **The toolchain is swift-linux's.** The Swift 6.4.2 toolchain this
  repository builds with has LLVM's PowerPC backend, and knows `-mcpu=750`
  and `-mcpu=7400`, but ships no Embedded Swift standard library for
  PowerPC: `swiftc -target powerpc-unknown-none-elf` (or
  `powerpc-unknown-linux-gnu`) stops at "could not find module 'Swift'".
  swift-linux supplies it, for the G4 today. `guest.py` takes the
  toolchain and the SDK for a target from its entry, so a PowerPC slice
  builds with swift-linux's while every other slice keeps the default.
- **One G4 slice, no G4e slice.** Code for the 7400 runs on every G4, and
  a 7450 slice would differ only in instruction scheduling. A G5 runs it
  too, under a 64-bit kernel with 32-bit userland. 64-bit PowerPC is
  another target, not in this plan.
- **A G3 slice has no AltiVec,** and a standard library built for the
  7400 may use it. So the G3 slice waits for a standard library built
  with `-mcpu=750`, which is what swift-linux is to add.
- **The first big-endian target.** Every format that crosses between
  guest and host already writes its bytes in a fixed order: the render
  codec, contract metadata, the drawing format, the environment payload.
  A native slice shares the host's process, so `rt_slot`'s 64 bits are in
  the same order on both sides, and floats cross as bit patterns. So a
  native slice needs no change for byte order. What needs checking is
  what reinterprets memory (below), and the wasm fallback, where linear
  memory is little-endian by definition.
- **32-bit, as `linux-armv7` and `i686` are.** `Int` is 32 bits, and the
  contracts already use `Int32` and `Int64` where width matters.
- **The slice carries its own compiler helpers,** as the armv7 slices do
  (`Scripts/support/armv7-eabi.c`): 32-bit PowerPC calls out for 64-bit
  division (`__divdi3`, `__udivdi3`, `__moddi3`, `__umoddi3`) and has no
  64-bit atomic instructions (`__atomic_*_8`). Neither is in the libc set
  a runner provides. The guest is single-threaded (§6.4), so the 64-bit
  atomics are plain loads and stores. `guest.py` localizes them as it
  seals the slice.

## What changes

### In this repository

1. **`Scripts/guest.py`:**
   - `TARGETS["linux-ppc7400"]`: `kind="elf"`, a freestanding PowerPC
     triple (`powerpc-unknown-none-elf`, or the hosted triple's Embedded
     runtime as `AARCH64_LINUX` uses, whichever swift-linux ships),
     `cpu="7400"`, `shared=True`, `support=["ppc32.c", "math.c"]`, and
     the toolchain and SDK it builds with.
   - `TARGETS["linux-ppc750"]`, the same with `cpu="750"` and no AltiVec
     (`-mno-altivec`), turned on when swift-linux's G3 library exists.
   - `"linux"` in the groups lists both, so `--target linux` builds them
     where the toolchain is there and says it skipped them where it
     isn't.
   - The sealing checks for a PowerPC ELF: the machine is `EM_PPC`, big
     endian; no TLS, no `DT_NEEDED`, `-z now`, `-Bsymbolic`; only the
     allowed undefined symbols.
2. **`Scripts/support/ppc32.c`:** the 64-bit division helpers and the
   single-threaded 64-bit atomics, freestanding, with no `/` or `%` that
   would call back into them.
3. **A byte-order audit** of what reads or writes memory as a type rather
   than byte by byte: `withUnsafeBytes` and `load(as:)` in the guest
   libraries, `CRuntime`'s `rt.c` and `executor.c`, the wasm2c shim, and
   the decoders (`MemoryImageDecoder`, `TextCoding`), which name their
   byte order. Each either writes its order explicitly or is
   process-local.
4. **Tests:**
   - The slice of `ExampleApp`, the ABI self-check that exercises every
     wire type and both call directions, run on 32-bit PowerPC: under
     QEMU's user mode (`qemu-ppc`) in a Debian Ports `powerpc` root, with
     `BundleRuntime` built for it with swift-linux, or on a real G4.
   - The sealing checks against a PowerPC object, in `Scripts`'
     unittest suite.
   - The big-endian audit's cases as Swift tests where they can run on
     the host: the codecs' byte layout pinned by expected bytes, so a
     change that went through native order would fail on every host.
5. **`Documentation/DynamicRuntime.md`:** the two target IDs in §7.5's
   slice table, and §7.7's selection rows.

### Slice selection on Linux (§7.7)

| Host | rt app order |
|---|---|
| ppc with AltiVec (G4, G5) | `linux-ppc7400` → `linux-ppc750` → `wasm32` |
| ppc without AltiVec (G3) | `linux-ppc750` → `wasm32` |

`uname -m` says `ppc` on a 32-bit kernel and `ppc64` on a G5's 64-bit
kernel; AltiVec is `PPC_FEATURE_HAS_ALTIVEC` in the auxiliary vector's
`AT_HWCAP`, or "altivec supported" in `/proc/cpuinfo`.

`wasm32` on a big-endian host is the open part:

- **WasmKit** must byte-swap every load and store of linear memory. That
  it does on a big-endian host isn't checked, and it's how a bundle with
  no PowerPC slice would run.
- **wasm2c** has a big-endian mode that keeps linear memory reversed,
  which the shim's direct reads of strings and bytes from guest memory
  would get wrong. A wasm2c-made `libapp.so` for PowerPC isn't offered
  until the shim reads through wasm2c's accessors there.

### Outside this repository

- **swift-linux:** the G4 toolchain and SDK as an artifact bundle this
  repository can name, with an Embedded Swift standard library for
  PowerPC (and its concurrency runtime); then the same built for the G3.
- **LinuxAppRuntime:** its runner, `rt-host`, and its renderer built for
  32-bit PowerPC with swift-linux's hosted toolchain, choosing a slice by
  the table above. GLES for `Surface` is Mesa's, which the GPUs in these
  Macs reach only in part: a Radeon 9xxx (r300) has GLES 2, a Rage 128
  in a G3 has none, and an app with `Surface` doesn't run there.

## Not in this plan

- **Mac OS X on PowerPC** (Tiger, Leopard): Mach-O objects for a `ppc750`
  or `ppc7400` Mac. Only the names are Mach-O's here. LLVM no longer
  emits PowerPC Mach-O, so that would need an older assembler and linker,
  or wasm2c's C built with Apple's GCC.
- **64-bit PowerPC** (`ppc970` userland, `ppc64`, `ppc64le`).
- **A G4e slice** tuned for the 7450.

## Questions

1. **swift-linux's PowerPC toolchain.** Which artifact bundle and
   version, which triples it has an Embedded standard library for
   (`powerpc-unknown-none-elf`, or only `powerpc-unknown-linux-gnu`), and
   whether that library is built for the 7400 with AltiVec. The project
   isn't checked out here, and I couldn't find it on GitHub under that
   name, so this plan is written from what you've said of it.
2. **The names.** `linux-ppc7400` and `linux-ppc750`, after Mach-O's
   subtypes, or `linux-ppc-g4` and `linux-ppc-g3`?
3. **Testing.** QEMU user mode in a Debian Ports root, which runs in CI
   and here, or real hardware, or both?
4. **wasm32 on these hosts.** Fall back to WasmKit once it's checked on a
   big-endian host, or offer native slices only?
