# Linux on 32-bit PowerPC: G4 now, G3 later

**Status:** reviewed, and built as far as this machine can: both targets
in `guest.py`, the search for swift-linux's toolchain, the format and
AltiVec checks, `Scripts/support/ppc32.c`, the byte-order audit, and tests
of each against PowerPC objects linked from C. No PowerPC slice of a
Swift guest is built yet: that needs swift-linux's toolchain, which isn't
installed here ("Still to do", below).

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

## Built

- **`linux-ppc7400` and `linux-ppc750`** in `guest.py`'s targets and its
  `linux` group. Each names swift-linux's toolchain, `-mcpu=7400` or
  `-mcpu=750` (Clang's flag for PowerPC, where other targets take
  `-march`), `ppc32.c` and `math.c`, and the format its sealed object must
  be, `elf32-powerpc`.
- **The toolchain** is `$RT_SWIFT_LINUX_TOOLCHAIN`, or one installed as
  `swift-linux*.xctoolchain` or under `/opt/swift-linux*`, that has
  Embedded Swift for `powerpc-unknown-none-elf` or, failing that, for
  `powerpc-unknown-linux-gnu`, whose library and concurrency runtime the
  slice then takes, as the arm64 slice takes the hosted one's. Without
  one, `--target linux` builds the other Linux slices and says it skipped
  these; naming one alone is an error that says what to install.
- **The checks:** a sealed object and its `libapp.so` must be
  `elf32-powerpc`, not little-endian or 64-bit; and a G3 slice is refused
  if its disassembly has any AltiVec instruction, the standard library's
  included, so a G4-only library can't slip into it.
- **`ppc32.c`:** 64-bit shifts, division and remainders; conversions
  between 64-bit integers and `Float` and `Double`; single-threaded
  64-bit atomics; `ceil` and `floor`. Freestanding, written on 32-bit
  halves in big-endian order, with no AltiVec.
- **The audit:** every Swift reader and writer of the formats names its
  byte order (`RenderCodec`, `ContractMetadata`, the drawing format,
  `TextCoding`, `MemoryImageDecoder`), and `GuestExecutor`'s casts and
  `HostFiles`' are within the process. `CRuntime` has no type punning. The
  wasm2c shim copies slots and WASI results into linear memory in the
  host's order (`Scripts/wasm2c-shim.py`, its `memcpy`s of arguments,
  results and `rt_w2c_store32`/`store64`): right only on a little-endian
  host, which is why a wasm2c-made PowerPC slice isn't offered.
- **Tests:** `Scripts/test_guest_ppc.py` links PowerPC libraries from C
  with this toolchain and checks them: both CPUs pass; little-endian and
  64-bit objects are refused; the helpers a guest needs are outside the
  allowed set until `ppc32.c` supplies them, and are sealed in; a G3 slice
  with AltiVec is refused, and `ppc32.c` has none. It also runs `ppc32.c`'s
  helpers on this machine against its own arithmetic, 20,000 cases each,
  which checks the algorithms on the little-endian halves. Swift tests pin
  the render codec's, the contract records' and the drawing format's
  bytes, so a change that went through native order fails on every host.

## Still to do

- **A Swift guest's PowerPC slice,** with swift-linux's toolchain:
  `guest.py slice --target linux-ppc7400` for `ExampleApp`, then the
  examples.
- **Running it:** `ExampleApp`'s self-check on 32-bit PowerPC, under
  `qemu-ppc` in a Debian Ports root or on a G4, with a runner built by
  swift-linux. That's also the first run of `ppc32.c`'s big-endian halves.
- **The G3 slice,** once swift-linux's library is built for the 750: the
  AltiVec check is what will say it's ready.
- **The hosts:** `LinuxAppRuntime`'s runner and renderer for PowerPC, and
  §7.7's selection.

## Changed while building

- **The helpers are libgcc's names, in plain C:** 32-bit PowerPC returns
  a 64-bit value in two registers, which C expresses, so `ppc32.c` needs
  none of `armv7-eabi.c`'s assembly.
- **`ceil` and `floor` are in `ppc32.c`,** as they are in `armv7-eabi.c`:
  the G3's and G4's FPUs can't round to an integer.
- **The questions, as built:** the IDs are `linux-ppc7400` and
  `linux-ppc750`; QEMU's user mode or a real G4 for running a slice, when
  there is one; wasm on these hosts waits on WasmKit being checked on a
  big-endian host.

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
