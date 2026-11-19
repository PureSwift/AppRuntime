"""Tests for guest.py's libapp.so: what its checks refuse, read from
`llvm-objdump -p` output written here and from libraries linked from C."""

import tempfile
import unittest
from pathlib import Path

import guest

# `llvm-objdump -p` for a libapp.so as guest.py links one.
HEADERS = """
libapp.so:\tfile format elf64-littleaarch64

Program Header:
    LOAD off    0x0000000000000000 vaddr 0x0000000000000000 paddr 0x0000000000000000 align 2**16
         filesz 0x0000000000015770 memsz 0x0000000000015770 flags r--
 DYNAMIC off    0x00000000000a1ec8 vaddr 0x00000000000c1ec8 paddr 0x00000000000c1ec8 align 2**3
         filesz 0x0000000000000110 memsz 0x0000000000000110 flags rw-
   STACK off    0x0000000000000000 vaddr 0x0000000000000000 paddr 0x0000000000000000 align 2**64
         filesz 0x0000000000000000 memsz 0x0000000000000000 flags rw-

Dynamic Section:
  FLAGS     0x000000000000000a
  FLAGS_1   0x0000000000000001
  SYMTAB    0x0000000000000200
  GNU_HASH  0x0000000000000698
  HASH      0x00000000000006c0
"""


class DynamicProblemsTests(unittest.TestCase):

    def test_a_library_as_linked_has_none(self):
        self.assertEqual(guest.dynamic_problems(HEADERS), [])

    def test_a_needed_library_is_named(self):
        problems = guest.dynamic_problems(HEADERS + "  NEEDED    libc.so.6\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("libc.so.6", problems[0])

    def test_relocations_in_code(self):
        self.assertEqual(guest.dynamic_problems(HEADERS + "  TEXTREL   0x0000000000000000\n"),
                         ["it has relocations in code"])
        flagged = HEADERS.replace("FLAGS     0x000000000000000a", "FLAGS     0x000000000000000e")
        self.assertEqual(guest.dynamic_problems(flagged), ["it has relocations in code"])

    def test_binding_later(self):
        lazy = HEADERS.replace("FLAGS     0x000000000000000a", "FLAGS     0x0000000000000002")
        self.assertEqual(guest.dynamic_problems(lazy), ["it doesn't bind its symbols as it loads (-z now)"])
        without = HEADERS.replace("  FLAGS     0x000000000000000a\n", "")
        self.assertEqual(guest.dynamic_problems(without), ["it doesn't bind its symbols as it loads (-z now)"])

    def test_code_run_on_load(self):
        for tag in ("INIT", "INIT_ARRAY", "PREINIT_ARRAY"):
            problems = guest.dynamic_problems(HEADERS + f"  {tag}   0x00000000000c1ec8\n")
            self.assertEqual(problems, [f"it runs code as it loads ({tag}), before rt_main"])
        # Its size alone isn't code.
        self.assertEqual(guest.dynamic_problems(HEADERS + "  FINI_ARRAYSZ   0x0000000000000008\n"), [])

    def test_thread_local_storage(self):
        segment = "     TLS off    0x00000000000a2178 vaddr 0x00000000000d2178 paddr 0x00000000000d2178 align 2**3\n"
        headers = HEADERS.replace(" DYNAMIC off", segment + " DYNAMIC off")
        self.assertEqual(guest.dynamic_problems(headers), ["it has thread-local storage"])


class UndefinedProblemsTests(unittest.TestCase):

    def test_the_allowed_set(self):
        allowed = ["rt_call", "rt_string_new", "glDrawArrays", "malloc", "memcpy", "arc4random_buf", "write"]
        self.assertEqual(guest.undefined_problems(allowed, macho=False), [])
        self.assertEqual(guest.undefined_problems(["__aeabi_memcpy4"], macho=False), [])

    def test_what_is_outside_it(self):
        for symbol, word in (("printf", "outside the allowed set"),
                             ("memcpy@GLIBC_2.17", "glibc-only"),
                             ("__memcpy_chk", "glibc-only"),
                             ("glBegin", "OpenGL ES 2.0"),
                             ("rt_main", "is undefined"),
                             ("__aeabi_memcpy4", "outside the allowed set")):
            macho = symbol == "__aeabi_memcpy4"
            problems = guest.undefined_problems([symbol], macho=macho)
            self.assertEqual(len(problems), 1, symbol)
            self.assertIn(word, problems[0])


GUEST = """
unsigned rt_class(const char *name, unsigned long length);
__attribute__((section(".rt_abi"), used)) static const unsigned abi = 1;
__attribute__((visibility("default"))) int rt_main(void) { return (int)rt_class("a", 1); }
__attribute__((visibility("default"))) int rt_dispatch(void) { return 0; }
__attribute__((visibility("default"))) void rt_finalize(unsigned context) {}
"""


class LinkedLibraryTests(unittest.TestCase):
    """Links libapp.so from C with the package's toolchain, and checks it."""

    @classmethod
    def setUpClass(cls):
        try:
            cls.toolchain = guest.Toolchain(Path(__file__).resolve().parent.parent)
            for tool in ("clang", "ld.lld", "llvm-objdump", "llvm-nm", "llvm-objcopy"):
                cls.toolchain.tool(tool)
        except (guest.BuildError, OSError) as error:
            raise unittest.SkipTest(f"no toolchain: {error}")

    def link(self, source, triple="aarch64-none-none-elf"):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (directory / "guest.c").write_text(GUEST + source)
        sealed = directory / "app.o"
        guest.run([self.toolchain.tool("clang"), "-target", triple, "-fPIC", "-ffreestanding", "-c",
                   directory / "guest.c", "-o", sealed], quiet=True)
        return self.toolchain, guest.link_shared(self.toolchain, sealed, directory)

    def test_a_guest_links_into_a_library_that_passes(self):
        for triple in ("aarch64-none-none-elf", "armv7-none-none-eabi", "x86_64-unknown-none-elf"):
            with self.subTest(triple):
                self.assertEqual(guest.check_shared(*self.link("", triple)), [])

    def test_it_names_no_library_and_keeps_no_symbol_table(self):
        toolchain, shared = self.link("")
        headers = guest.run([toolchain.tool("llvm-objdump"), "-p", shared], quiet=True)
        self.assertNotIn("NEEDED", headers)
        self.assertEqual(guest.symbols(toolchain, shared, undefined=False), [])
        self.assertEqual(guest.symbols(toolchain, shared, undefined=True, dynamic=True), ["rt_class"])

    def test_the_manifest_section_is_kept(self):
        toolchain, shared = self.link("")
        sealed = shared.with_name("app.o")
        manifest = shared.with_name("rt.manifest.json")
        manifest.write_bytes(b'{"id":"org.example.app"}')
        guest.run([toolchain.tool("llvm-objcopy"), "--add-section", f".rt_manifest={manifest}", sealed])
        shared = guest.link_shared(toolchain, sealed, shared.parent)
        self.assertEqual(guest.check_shared(toolchain, shared, manifest=manifest.read_bytes()), [])
        self.assertEqual(guest.check_shared(toolchain, shared, manifest=b"{}"),
                         ["the .rt_manifest section doesn't hold the manifest"])

    def test_a_constructor_is_refused(self):
        problems = guest.check_shared(*self.link("__attribute__((constructor)) static void early(void) {}\n"))
        self.assertEqual(problems, ["it runs code as it loads (INIT_ARRAY), before rt_main"])

    def test_thread_local_storage_is_refused(self):
        source = "static __thread int counter = 1;\nint *rt_counter(void) { return &counter; }\n"
        problems = guest.check_shared(*self.link(source))
        self.assertIn("it has thread-local storage", problems)

    def test_another_export_and_another_import_are_refused(self):
        source = ("int printf(const char *, ...);\n"
                  '__attribute__((visibility("default"))) int extra(void) { return printf("x"); }\n')
        problems = guest.check_shared(*self.link(source))
        self.assertIn("undefined symbol outside the allowed set: printf", problems)
        self.assertTrue(any("exported symbols are" in p and "extra" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
