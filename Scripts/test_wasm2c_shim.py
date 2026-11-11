"""Tests for wasm2c-shim.py. Run with: python3 -m unittest discover -s Scripts -p 'test_*.py'

The end-to-end tests (ExampleApp and ExampleUI through wasm2c against the real
runtime) are in Packages/LinkedSlice. These check the generator, and the
shim's conversions and traps against a hand-written module and a fake host.
"""

import importlib.util
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wasm2c_shim", SCRIPTS / "wasm2c-shim.py")
shim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shim)

HAS_WABT = bool(shutil.which("wasm2c") and shutil.which("wat2wasm"))

MODULE = r"""
(module
  (import "rt" "string_new" (func $string_new (param i32 i32) (result i32)))
  (import "rt" "string_utf8" (func $string_utf8 (param i32 i32 i32) (result i32)))
  (import "rt" "call" (func $call (param i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "random_get" (func $random_get (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "hello")
  (global $heap (mut i32) (i32.const 1024))
  (global $finalized (export "finalized") (mut i32) (i32.const 0))
  (func (export "_initialize"))
  (func (export "rt_alloc") (param $size i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $heap))
    (global.set $heap (i32.add (global.get $heap)
      (i32.and (i32.add (local.get $size) (i32.const 7)) (i32.const -8))))
    (local.get $p))
  (func (export "rt_free") (param i32))
  (func (export "rt_main") (result i32)
    (local $h i32)
    (local.set $h (call $string_new (i32.const 16) (i32.const 5)))
    (if (i32.ne (local.get $h) (i32.const 7)) (then (return (i32.const 10))))
    (i32.store8 (i32.const 67) (i32.const 120))
    (if (i32.ne (call $string_utf8 (local.get $h) (i32.const 64) (i32.const 8)) (i32.const 3))
      (then (return (i32.const 11))))
    (if (i32.ne (i32.load8_u (i32.const 64)) (i32.const 97)) (then (return (i32.const 12))))
    (if (i32.ne (i32.load8_u (i32.const 66)) (i32.const 99)) (then (return (i32.const 13))))
    ;; A byte the host didn't write keeps its value.
    (if (i32.ne (i32.load8_u (i32.const 67)) (i32.const 120)) (then (return (i32.const 14))))
    (if (i32.ne (call $random_get (i32.const 128) (i32.const 32)) (i32.const 0)) (then (return (i32.const 15))))
    (i32.const 0))
  (func (export "rt_dispatch") (param $ctx i32) (param $index i32) (param $self i32)
        (param $args i32) (param $nargs i32) (param $ret i32) (param $nret i32) (result i32)
    ;; 0: returns its argument plus one.
    (if (i32.eqz (local.get $index)) (then
      (i64.store (local.get $ret) (i64.add (i64.load (local.get $args)) (i64.const 1)))
      (return (i32.const 0))))
    ;; 1: passes an offset outside memory.
    (if (i32.eq (local.get $index) (i32.const 1)) (then
      (drop (call $string_new (i32.const 0xFFFFFFF0) (i32.const 100)))
      (return (i32.const 0))))
    ;; 2: the host calls back into the guest, then the guest traps.
    (drop (call $call (i32.const 1) (i32.const 1) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)))
    (unreachable))
  (func (export "rt_finalize") (param $ctx i32)
    (global.set $finalized (local.get $ctx))))
"""

HOST = r"""
#include <stdio.h>
#include <string.h>
#include "rt.h"

static char seen[64];
static int nested;

rt_obj rt_string_new(const char *utf8, size_t len) {
    memcpy(seen, utf8, len < 63 ? len : 63);
    return 7;
}
size_t rt_string_utf8(rt_obj str, char *buf, size_t cap) {
    if (buf && cap >= 3) memcpy(buf, "abc", 3);
    return 3;
}
rt_status rt_call(rt_obj target, rt_method_id method, const rt_slot *args, uint32_t nargs,
                  rt_slot *ret, uint32_t nret) {
    rt_slot argument = 41, result = 0;
    nested = rt_dispatch(1, 0, 0, &argument, 1, &result, 1) == RT_OK && result == 42;
    return RT_OK;
}
rt_class_id rt_class(const char *name, size_t len) { return 0; }
rt_method_id rt_method(rt_class_id cls, const char *n, size_t nl, const char *s, size_t sl, uint32_t f) { return 0; }
void rt_retain(rt_obj obj) {}
void rt_release(rt_obj obj) {}
int32_t rt_same(rt_obj a, rt_obj b) { return a == b; }
int32_t rt_is_instance(rt_obj obj, rt_class_id cls) { return 0; }
rt_obj rt_bytes_new(const void *ptr, size_t len) { return 0; }
size_t rt_bytes_read(rt_obj bytes, void *buf, size_t cap) { return 0; }
rt_obj rt_implement(const rt_class_id *i, uint32_t ni, const rt_method_decl *m, uint32_t nm, uint32_t c) { return 0; }
size_t rt_error_message(char *buf, size_t cap) { return 0; }

#define CHECK(condition) if (!(condition)) { printf("FAIL %s\n", #condition); failures++; }

int main(void) {
    int failures = 0;
    rt_slot argument = 1, result = 0;
    CHECK(rt_dispatch(1, 0, 0, &argument, 1, &result, 1) == RT_ERR_NOT_FOUND); /* before rt_main */
    CHECK(rt_main() == RT_OK);
    CHECK(strcmp(seen, "hello") == 0);
    CHECK(rt_dispatch(1, 0, 0, &argument, 1, &result, 1) == RT_OK && result == 2);
    CHECK(rt_dispatch(1, 1, 0, NULL, 0, NULL, 0) == RT_ERR_THROWN);
    CHECK(rt_dispatch(1, 2, 0, NULL, 0, NULL, 0) == RT_ERR_THROWN);
    CHECK(nested);
    result = 0;
    CHECK(rt_dispatch(1, 0, 0, &argument, 1, &result, 1) == RT_OK && result == 2);
    rt_finalize(5);
    if (!failures) printf("ok\n");
    return failures;
}
"""


class ParseTests(unittest.TestCase):

    def test_reads_every_import_of_rt_h(self):
        imports = {item.name: item for item in shim.read_imports(shim.RT_H)}
        self.assertEqual(set(imports), {
            "class", "method", "call", "retain", "release", "same", "is_instance",
            "string_new", "string_utf8", "bytes_new", "bytes_read", "implement", "error_message",
        })
        call = imports["call"]
        self.assertEqual([(p.name, p.pointer, p.const) for p in call.parameters if p.pointer],
                         [("args", True, True), ("ret", True, False)])
        self.assertEqual(call.parameters[2].count, "nargs")
        self.assertEqual(imports["string_utf8"].result, "size_t")

    def test_rejects_a_pointer_without_its_count(self):
        with tempfile.TemporaryDirectory() as directory:
            header = Path(directory) / "rt.h"
            header.write_text("RT_IMPORT(bad) rt_obj rt_bad(const char *name, rt_obj other);\n")
            with self.assertRaisesRegex(shim.ShimError, "isn't followed by its count"):
                shim.read_imports(header)

    def test_rejects_unknown_types(self):
        with tempfile.TemporaryDirectory() as directory:
            header = Path(directory) / "rt.h"
            header.write_text("RT_IMPORT(bad) rt_obj rt_bad(double value);\n")
            with self.assertRaisesRegex(shim.ShimError, "no rule for double"):
                shim.read_imports(header)

    def test_generated_wrappers(self):
        text = shim.generate(shim.read_imports(shim.RT_H), "app", "app.h")
        self.assertIn("uint32_t w2c_rt_call(struct w2c_rt *rt, uint32_t target, uint32_t method, "
                      "uint32_t args, uint32_t nargs, uint32_t ret, uint32_t nret) {", text)
        self.assertIn("rt_w2c_copy_out(ret, ret_host, nret, 8);", text)
        self.assertNotIn("rt_w2c_copy_out(args", text, "inputs aren't copied back")
        self.assertIn("rt_w2c_methods_in(methods, nmethods, &methods_strings)", text)
        self.assertIn("uint32_t result = rt_w2c_u32(rt_string_utf8(", text)


@unittest.skipUnless(HAS_WABT, "needs WABT (brew install wabt)")
class ShimTests(unittest.TestCase):

    def run_host(self, defines=(), host=""):
        """Builds MODULE with the shim and HOST (plus `host`), and runs it."""
        wasm2c, runtime, include = shim.wabt_runtime()
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "test.wat").write_text(MODULE)
            subprocess.run(["wat2wasm", work / "test.wat", "-o", work / "test.wasm"], check=True)
            imports = shim.read_imports(shim.RT_H)
            self.assertEqual(shim.check_imports(work / "test.wasm", imports), [])
            subprocess.run([wasm2c, work / "test.wasm", "-n", "app", "-o", work / "app.c"], check=True)
            (work / "rt_wasm2c.c").write_text(shim.generate(imports, "app", "app.h"))
            (work / "host.c").write_text(HOST + host)
            includes = ["-I", work, "-I", runtime, "-I", include, "-I", shim.RT_H.parent]
            macros = [f"-D{define}" for define in defines]
            # The shim itself compiles cleanly.
            subprocess.run([*shim.compiler(), "-Wall", "-Werror", "-Wno-unused-function", *shim.WASM_RT_DEFINES,
                            *macros, *includes, "-c", work / "rt_wasm2c.c", "-o", work / "rt_wasm2c.o"], check=True)
            subprocess.run([*shim.compiler(), "-w", "-O1", *shim.WASM_RT_DEFINES, *macros, *includes,
                            work / "app.c", work / "rt_wasm2c.c", work / "host.c",
                            runtime / "wasm-rt-impl.c", runtime / "wasm-rt-mem-impl.c",
                            "-o", work / "host"], check=True)
            return subprocess.run([work / "host"], capture_output=True, text=True)

    def test_conversions_and_traps(self):
        result = self.run_host()
        self.assertEqual(result.stdout.strip(), "ok", result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0)
        self.assertIn("guest trapped", result.stderr, "traps are reported")

    def test_write_function_receives_the_guests_output(self):
        result = self.run_host(defines=["RT_WASM2C_WRITE_FUNCTION=host_write"], host=textwrap.dedent("""
            void host_write(int fd, const void *data, size_t size) {
                printf("[%d]%.*s", fd, (int)size, (const char *)data);
            }
            """))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], "ok")
        self.assertIn("[2]wasm2c: guest trapped", result.stdout, "traps go to the host function")
        self.assertNotIn("guest trapped", result.stderr)

    def test_rejects_unsupported_imports(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "test.wat").write_text(textwrap.dedent("""
                (module
                  (import "wasi_snapshot_preview1" "path_open" (func (param i32) (result i32)))
                  (import "env" "other" (func)))
                """))
            subprocess.run(["wat2wasm", work / "test.wat", "-o", work / "test.wasm"], check=True)
            self.assertEqual(shim.check_imports(work / "test.wasm", shim.read_imports(shim.RT_H)),
                             ["env.other", "wasi_snapshot_preview1.path_open"])


if __name__ == "__main__":
    unittest.main()
