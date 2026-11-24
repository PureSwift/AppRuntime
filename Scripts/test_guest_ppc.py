"""Tests for guest.py's 32-bit PowerPC slices (Documentation/PowerPC.md),
with libraries linked from C by the package's toolchain, which has LLVM's
PowerPC backend though not Embedded Swift's standard library for it: what
the checks refuse, what Scripts/support/ppc32.c supplies, and that its
helpers compute what the hardware would."""

import os
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import guest
from test_guest_shared import GUEST

SUPPORT = Path(__file__).resolve().parent / "support"

# Guest code that needs each kind of helper 32-bit PowerPC lacks.
HELPERS = """
long long rt_divide(long long a, long long b) { return a / b + a % b; }
unsigned long long rt_udivide(unsigned long long a, unsigned long long b) { return a / b + a % b; }
double rt_seconds(long long nanoseconds) { return (double)nanoseconds / 1e9; }
long long rt_nanoseconds(double seconds) { return (long long)(seconds * 1e9); }
unsigned long long rt_bump(unsigned long long *counter) { return __atomic_fetch_add(counter, 1, __ATOMIC_SEQ_CST); }
double rt_ceiling(double x) { return __builtin_ceil(x); }
"""


class PowerPCLibraryTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        try:
            cls.toolchain = guest.Toolchain(Path(__file__).resolve().parent.parent)
            for tool in ("clang", "ld.lld", "llvm-objdump", "llvm-nm", "llvm-objcopy"):
                cls.toolchain.tool(tool)
        except (guest.BuildError, OSError) as error:
            raise unittest.SkipTest(f"no toolchain: {error}")

    def compile(self, directory, name, source, cpu="7400", triple="powerpc-unknown-none-elf"):
        path = directory / f"{name}.c"
        path.write_text(source)
        obj = directory / f"{name}.o"
        guest.run([self.toolchain.tool("clang"), "-target", triple, f"-mcpu={cpu}", "-Os", "-fPIC",
                   "-ffreestanding", "-fno-stack-protector", "-c", path, "-o", obj], quiet=True)
        return obj

    def link(self, source, cpu="7400", support=False, triple="powerpc-unknown-none-elf"):
        """A sealed object and libapp.so, as guest.py makes them."""
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        objects = [self.compile(directory, "guest", GUEST + source, cpu, triple)]
        if support:
            objects.append(self.compile(directory, "ppc32", (SUPPORT / "ppc32.c").read_text(), cpu, triple))
        sealed = guest.seal_elf(self.toolchain, objects, [], directory)
        return sealed, guest.link_shared(self.toolchain, sealed, directory)

    def test_a_guest_links_for_the_g4_and_the_g3(self):
        for cpu in ("7400", "750"):
            with self.subTest(cpu):
                sealed, shared = self.link("", cpu)
                self.assertEqual(guest.check_sealed(self.toolchain, sealed, macho=False, file_format="elf32-powerpc"), [])
                self.assertEqual(guest.check_shared(self.toolchain, shared, file_format="elf32-powerpc"), [])

    def test_its_format_is_32_bit_big_endian_powerpc(self):
        _, little = self.link("", triple="powerpcle-unknown-none-elf")
        self.assertEqual(guest.file_format_problems(self.toolchain, little, "elf32-powerpc"),
                         ["it's elf32-powerpcle, not elf32-powerpc"])
        _, wide = self.link("", cpu="970", triple="powerpc64-unknown-none-elf")
        self.assertEqual(guest.file_format_problems(self.toolchain, wide, "elf32-powerpc"),
                         ["it's elf64-powerpc, not elf32-powerpc"])

    def test_the_helpers_it_needs_are_outside_the_allowed_set(self):
        sealed, _ = self.link(HELPERS)
        problems = guest.check_sealed(self.toolchain, sealed, macho=False)
        # The remainders come from the quotients, so the division helpers are
        # all it calls.
        for helper in ("__divdi3", "__udivdi3", "__floatdidf", "__fixdfdi", "__atomic_fetch_add_8", "ceil"):
            self.assertIn(f"undefined symbol outside the allowed set: {helper}", problems)

    def test_ppc32_supplies_them(self):
        for cpu in ("7400", "750"):
            with self.subTest(cpu):
                sealed, shared = self.link(HELPERS, cpu, support=True)
                self.assertEqual(guest.check_sealed(self.toolchain, sealed, macho=False, file_format="elf32-powerpc"), [])
                self.assertEqual(guest.check_shared(self.toolchain, shared, file_format="elf32-powerpc"), [])
                # Sealed: the helpers are the slice's own, and the host's
                # libgcc can't be bound in their place.
                exported = guest.symbols(self.toolchain, shared, undefined=False, dynamic=True)
                self.assertEqual(exported, sorted(guest.GUEST_EXPORTS))

    def test_a_g3_slice_has_no_altivec(self):
        vector = "typedef int v4 __attribute__((vector_size(16)));\nv4 rt_add(v4 a, v4 b) { return a + b; }\n"
        g4, _ = self.link(vector, "7400")
        problems = guest.altivec_problems(self.toolchain, g4)
        self.assertEqual(len(problems), 1)
        self.assertIn("vadduwm", problems[0])
        g3, _ = self.link(vector, "750")
        self.assertEqual(guest.altivec_problems(self.toolchain, g3), [])
        g3, _ = self.link(HELPERS, "750", support=True)
        self.assertEqual(guest.altivec_problems(self.toolchain, g3), [], "ppc32.c uses none")

    def test_the_targets(self):
        for target_id, cpu in (("linux-ppc7400", "7400"), ("linux-ppc750", "750")):
            config = guest.TARGETS[target_id]
            self.assertEqual(config["cpu"], cpu)
            self.assertEqual(config["file_format"], "elf32-powerpc")
            self.assertEqual(config["toolchain"], guest.SWIFT_LINUX)
            self.assertIn("ppc32.c", config["support"])
            self.assertTrue(config["shared"])
            self.assertIn(target_id, guest.PLATFORM_GROUPS["linux"])
        self.assertTrue(guest.TARGETS["linux-ppc750"]["no_altivec"])
        self.assertNotIn("no_altivec", guest.TARGETS["linux-ppc7400"])
        compiler = guest.Compiler(self.toolchain, None, None, "powerpc-unknown-none-elf", "/tmp", cpu="750")
        self.assertIn("-mcpu=750", compiler.common_c_flags())
        self.assertNotIn("-mcpu=750", compiler.swift_flags(), "the Swift side says -target-cpu")
        self.assertIn("750", compiler.swift_flags())


class SwiftLinuxToolchainTests(unittest.TestCase):

    def test_a_missing_toolchain_is_none(self):
        with unittest.mock.patch.dict(os.environ, {guest.SWIFT_LINUX_ENVIRONMENT: "/nonexistent/swift-linux"}):
            candidates = guest.toolchain_candidates(guest.SWIFT_LINUX)
            self.assertEqual(candidates[0], Path("/nonexistent/swift-linux"), "the environment comes first")
            if candidates[1:]:
                self.skipTest("a swift-linux toolchain is installed")
            self.assertIsNone(guest.find_toolchain(guest.SWIFT_LINUX, ["powerpc-unknown-none-elf"]))
        self.assertTrue(issubclass(guest.ToolchainMissing, guest.BuildError))


class PPC32HelperTests(unittest.TestCase):
    """ppc32.c compiled for this machine and run against its own arithmetic:
    the algorithms, on the little-endian halves. A PowerPC runs the
    big-endian halves, which this doesn't execute."""

    PROGRAM = r"""
typedef unsigned long long u64;
typedef long long s64;
u64 __udivdi3(u64, u64); u64 __umoddi3(u64, u64); s64 __divdi3(s64, s64); s64 __moddi3(s64, s64);
u64 __ashldi3(u64, int); u64 __lshrdi3(u64, int); s64 __ashrdi3(s64, int);
double __floatdidf(s64); double __floatundidf(u64); float __floatdisf(s64); float __floatundisf(u64);
s64 __fixdfdi(double); u64 __fixunsdfdi(double); s64 __fixsfdi(float); u64 __fixunssfdi(float);
u64 __atomic_fetch_add_8(volatile void *, u64, int); _Bool __atomic_compare_exchange_8(volatile void *, void *, u64, _Bool, int, int);
double ceil(double); double floor(double);
int printf(const char *, ...);

static u64 state = 0x9E3779B97F4A7C15ull;
static u64 next(void) { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state; }

int main(void) {
    int failures = 0;
    for (int i = 0; i < 20000; i++) {
        u64 a = next(), b = next() >> (next() % 64);
        if (b == 0) b = 1;
        s64 sa = (s64)a, sb = (s64)b * ((next() & 1) ? -1 : 1);
        int shift = (int)(next() % 64);
        if (__udivdi3(a, b) != a / b || __umoddi3(a, b) != a % b) failures++;
        if (sb != 0 && !(sa == (s64)0x8000000000000000ull && sb == -1)
            && (__divdi3(sa, sb) != sa / sb || __moddi3(sa, sb) != sa % sb)) failures++;
        if (__ashldi3(a, shift) != a << shift || __lshrdi3(a, shift) != a >> shift
            || __ashrdi3(sa, shift) != sa >> shift) failures++;
        s64 small = sa >> (next() % 60);
        if (__floatdidf(small) != (double)small || __floatundidf(a) != (double)a) failures++;
        if (__floatdisf(small) != (float)small || __floatundisf(a) != (float)a) failures++;
        double d = (double)small / 7.0;
        if (__fixdfdi(d) != (s64)d) failures++;
        if (d >= 0 && __fixunsdfdi(d) != (u64)d) failures++;
        float f = (float)d;
        if (__fixsfdi(f) != (s64)f) failures++;
        if (__builtin_ceil(d) != ceil(d) || __builtin_floor(d) != floor(d)) failures++;
    }
    u64 counter = 41, expected = 42;
    if (__atomic_fetch_add_8(&counter, 1, 5) != 41 || counter != 42) failures++;
    if (!__atomic_compare_exchange_8(&counter, &expected, 7, 0, 5, 5) || counter != 7) failures++;
    if (__atomic_compare_exchange_8(&counter, &expected, 9, 0, 5, 5) || expected != 7) failures++;
    printf("%d\n", failures);
    return failures != 0;
}
"""

    def test_the_helpers_compute_what_the_machine_does(self):
        try:
            toolchain = guest.Toolchain(Path(__file__).resolve().parent.parent)
            clang = toolchain.tool("clang")
        except (guest.BuildError, OSError) as error:
            self.skipTest(f"no toolchain: {error}")
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (directory / "main.c").write_text(self.PROGRAM)
        program = directory / "helpers"
        sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
        flags = ["-isysroot", sdk] if sdk else []
        result = subprocess.run([clang, *flags, "-O1", "-fno-builtin", directory / "main.c", SUPPORT / "ppc32.c",
                                 "-o", program], capture_output=True, text=True)
        if result.returncode != 0:
            self.skipTest(f"can't build for this machine: {result.stderr[:200]}")
        run = subprocess.run([program], capture_output=True, text=True)
        self.assertEqual(run.stdout.strip(), "0", run.stderr)


if __name__ == "__main__":
    unittest.main()
