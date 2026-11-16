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


GL_MODULE = r"""
(module
  (import "rt" "release" (func $release (param i32)))
  (import "wasi_snapshot_preview1" "sched_yield" (func $yield (result i32)))
  (import "env.gl" "glClearColor" (func $clearColor (param f32 f32 f32 f32)))
  (import "env.gl" "glBufferData" (func $bufferData (param i32 i32 i32 i32)))
  (import "env.gl" "glGenBuffers" (func $genBuffers (param i32 i32)))
  (import "env.gl" "glCreateShader" (func $createShader (param i32) (result i32)))
  (import "env.gl" "glGetString" (func $getString (param i32) (result i32)))
  (import "env.gl" "glBindBuffer" (func $bindBuffer (param i32 i32)))
  (import "env.gl" "glVertexAttribPointer" (func $attribPointer (param i32 i32 i32 i32 i32 i32)))
  (import "env.gl" "glGetError" (func $getError (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "\01\02\03\04")
  (global $heap (mut i32) (i32.const 1024))
  (func (export "_initialize"))
  (func (export "rt_alloc") (param $size i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $heap))
    (global.set $heap (i32.add (global.get $heap)
      (i32.and (i32.add (local.get $size) (i32.const 7)) (i32.const -8))))
    (local.get $p))
  (func (export "rt_free") (param i32))
  (func (export "rt_main") (result i32)
    (local $version i32)
    (call $clearColor (f32.const 0.25) (f32.const 0.5) (f32.const 0.75) (f32.const 1))
    ;; glBufferData(GL_ARRAY_BUFFER, 4, 16, GL_STATIC_DRAW)
    (call $bufferData (i32.const 0x8892) (i32.const 4) (i32.const 16) (i32.const 0x88E4))
    (call $genBuffers (i32.const 2) (i32.const 64))
    (if (i32.ne (i32.load (i32.const 64)) (i32.const 100)) (then (return (i32.const 10))))
    (if (i32.ne (i32.load (i32.const 68)) (i32.const 101)) (then (return (i32.const 11))))
    ;; GL_VERTEX_SHADER
    (if (i32.ne (call $createShader (i32.const 0x8B31)) (i32.const 11)) (then (return (i32.const 12))))
    ;; GL_VERSION, copied into memory from rt_alloc: "FakeGL".
    (local.set $version (call $getString (i32.const 0x1F02)))
    (if (i32.ne (local.get $version) (i32.const 1024)) (then (return (i32.const 13))))
    (if (i32.ne (i32.load8_u (local.get $version)) (i32.const 70)) (then (return (i32.const 14))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $version) (i32.const 6))) (i32.const 0)) (then (return (i32.const 15))))
    (if (i32.ne (call $getString (i32.const 0x1F02)) (i32.const 1024)) (then (return (i32.const 16))))
    ;; GL_EXTENSIONS: the host has none.
    (if (i32.ne (call $getString (i32.const 0x1F03)) (i32.const 0)) (then (return (i32.const 17))))
    (drop (call $yield))
    (i32.const 0))
  (func (export "rt_dispatch") (param $ctx i32) (param $index i32) (param $self i32)
        (param $args i32) (param $nargs i32) (param $ret i32) (param $nret i32) (result i32)
    ;; 0: a pointer outside memory.
    (if (i32.eqz (local.get $index)) (then
      (call $bufferData (i32.const 0x8892) (i32.const 100) (i32.const 65500) (i32.const 0x88E4))
      (return (i32.const 0))))
    ;; 1: binds a buffer and points an attribute into it; returns glGetError.
    (if (i32.eq (local.get $index) (i32.const 1)) (then
      (call $bindBuffer (i32.const 0x8892) (i32.const 5))
      (call $attribPointer (i32.const 0) (i32.const 3) (i32.const 0x1406) (i32.const 0) (i32.const 12) (i32.const 24))
      (return (call $getError))))
    ;; 2: points an attribute without binding; returns glGetError.
    (call $attribPointer (i32.const 0) (i32.const 3) (i32.const 0x1406) (i32.const 0) (i32.const 12) (i32.const 24))
    (call $getError))
  (func (export "rt_finalize") (param $ctx i32)
    (call $release (local.get $ctx))))
"""

# A GL that records what the guest draws. Every other gl* function the shim
# refers to is stubbed after it.
GL_HOST = r"""
#include <stdio.h>
#include <string.h>
#include "rt.h"
#include "gles2.h"

static float color[4];
static unsigned char buffer[4];
static int buffer_calls, string_calls, attribute_calls;
static const void *attribute_pointer;
static uint32_t generation;

void glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    color[0] = red; color[1] = green; color[2] = blue; color[3] = alpha;
}
void glBufferData(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
    buffer_calls++;
    if (data && size == 4) memcpy(buffer, data, 4);
}
void glGenBuffers(GLsizei n, GLuint *buffers) {
    for (GLsizei i = 0; i < n; i++) buffers[i] = 100 + (GLuint)i;
}
GLuint glCreateShader(GLenum type) { return type == 0x8B31 ? 11 : 12; }
const GLubyte *glGetString(GLenum name) {
    string_calls++;
    return name == 0x1F02 ? (const GLubyte *)"FakeGL" : NULL;
}
void glBindBuffer(GLenum target, GLuint name) {}
void glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *pointer) {
    attribute_calls++;
    attribute_pointer = pointer;
}
GLenum glGetError(void) { return 0; }

uint32_t rt_gl_context_generation(void) { return generation; }

rt_obj rt_string_new(const char *utf8, size_t len) { return 0; }
size_t rt_string_utf8(rt_obj str, char *buf, size_t cap) { return 0; }
rt_status rt_call(rt_obj t, rt_method_id m, const rt_slot *a, uint32_t na, rt_slot *r, uint32_t nr) { return RT_OK; }
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
    rt_status status = rt_main();
    if (status != RT_OK) printf("rt_main returned %d\n", (int)status);
    CHECK(status == RT_OK);
    CHECK(color[0] == 0.25f && color[1] == 0.5f && color[2] == 0.75f && color[3] == 1.0f);
    CHECK(memcmp(buffer, "\1\2\3\4", 4) == 0);
    CHECK(string_calls == 2); /* GL_VERSION once, and GL_EXTENSIONS */

    /* A pointer outside guest memory traps, and GL isn't called. */
    CHECK(rt_dispatch(1, 0, 0, NULL, 0, NULL, 0) == RT_ERR_THROWN);
    CHECK(buffer_calls == 1);

    /* With a buffer bound, the attribute's pointer is an offset. */
    CHECK(rt_dispatch(1, 1, 0, NULL, 0, NULL, 0) == RT_OK);
    CHECK(attribute_calls == 1 && attribute_pointer == (const void *)24);
    CHECK(rt_dispatch(1, 2, 0, NULL, 0, NULL, 0) == RT_OK);
    CHECK(attribute_calls == 2);

    /* A new GL context has no buffer bound: GL_INVALID_OPERATION, no call. */
    generation++;
    CHECK(rt_dispatch(1, 2, 0, NULL, 0, NULL, 0) == 0x0502);
    CHECK(attribute_calls == 2);
    if (!failures) printf("ok\n");
    return failures;
}
"""

GL_HOST_FUNCTIONS = {"glClearColor", "glBufferData", "glGenBuffers", "glCreateShader", "glGetString",
                     "glBindBuffer", "glVertexAttribPointer", "glGetError"}


def gl_stubs():
    """Definitions of the gl* functions GL_HOST doesn't define."""
    lines = []
    for function in shim.gles2.functions():
        if function.name not in GL_HOST_FUNCTIONS:
            lines.append(f"{function.prototype} {{ {'' if function.result == 'void' else 'return 0; '}}}")
    return "\n".join(lines) + "\n"


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
        self.assertIn("app_instantiate(&rt_w2c_instance, &rt_w2c_rt, &rt_w2c_wasi);", text)
        self.assertNotIn("rt_w2c_gl", text, "nothing of GL without it")

    def test_generated_gl_wrappers(self):
        text = shim.generate(shim.read_imports(shim.RT_H), "app", "app.h", gl=True)
        self.assertEqual(shim.GL_STRUCT, "w2c_env0x2Egl", "wasm2c's spelling of env.gl")
        # wasm2c passes one instance per import module, in the order of their names.
        self.assertIn("app_instantiate(&rt_w2c_instance, &rt_w2c_gl, &rt_w2c_rt, &rt_w2c_wasi);", text)
        self.assertIn("void w2c_env0x2Egl_glClearColor(struct w2c_env0x2Egl *gl, float red, float green, "
                      "float blue, float alpha) {", text)
        self.assertIn("uint32_t result = rt_gl_glCreateShader(rt_w2c_gl_enter(), type);", text)
        self.assertIn("uint32_t w2c_env0x2Egl_glGetString(", text)
        self.assertEqual(text.count("\nvoid w2c_env0x2Egl_") + text.count("\nuint32_t w2c_env0x2Egl_"), 140)

    def test_gl_imports_are_provided(self):
        self.assertIn("env.gl.glDrawArrays", shim.gles2.imports())
        self.assertNotIn("env.gl.glShaderBinary", shim.gles2.imports(), "not in WebGL 1")


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

    def build_gl(self, work):
        """Translates GL_MODULE in `work`; returns the include flags."""
        wasm2c, runtime, include = shim.wabt_runtime()
        (work / "test.wat").write_text(GL_MODULE)
        subprocess.run(["wat2wasm", work / "test.wat", "-o", work / "test.wasm"], check=True)
        self.assertEqual(shim.check_imports(work / "test.wasm", shim.read_imports(shim.RT_H)), [])
        self.assertTrue(shim.uses_gl(work / "test.wasm"))
        return wasm2c, runtime, ["-I", work, "-I", runtime, "-I", include, "-I", shim.RT_H.parent,
                                 *[f"-I{path}" for path in shim.GL_INCLUDES]]

    def test_gl_imports_reach_the_hosts_gl(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            wasm2c, runtime, includes = self.build_gl(work)
            subprocess.run([wasm2c, work / "test.wasm", "-n", "app", "-o", work / "app.c"], check=True)
            (work / "rt_wasm2c.c").write_text(shim.generate(shim.read_imports(shim.RT_H), "app", "app.h", gl=True))
            (work / "host.c").write_text(GL_HOST + gl_stubs())
            flags = [*shim.WASM_RT_DEFINES, "-DRT_GL_DIRECT", *includes]
            # The shim and the GL shim compile cleanly.
            for source in (work / "rt_wasm2c.c", shim.GL_SHIM):
                subprocess.run([*shim.compiler(), "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-parameter",
                                *flags, "-c", source, "-o", work / "check.o"], check=True)
            subprocess.run([*shim.compiler(), "-w", "-O1", *flags,
                            work / "app.c", work / "rt_wasm2c.c", shim.GL_SHIM, work / "host.c",
                            runtime / "wasm-rt-impl.c", runtime / "wasm-rt-mem-impl.c",
                            "-o", work / "host"], check=True)
            result = subprocess.run([work / "host"], capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "ok", result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0)
        self.assertIn("guest trapped", result.stderr, "the bad pointer's trap is reported")

    def test_a_gl_slice_seals_like_a_native_one(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            self.build_gl(work)
            archive = shim.build(work / "test.wasm", work / "slice", None, "macosx")
            undefined = subprocess.run(["nm", "-u", archive], capture_output=True, text=True, check=True).stdout
            names = {line.strip().lstrip("_") for line in undefined.splitlines()}
        # GL comes from the host, by its own names, as for a native slice.
        self.assertIn("glClearColor", names)
        self.assertIn("glDrawElements", names)
        self.assertIn("rt_gl_context_generation", names)
        self.assertFalse({name for name in names if name.startswith("rt_gl_gl")}, "the shim is inside the slice")

    def test_sources_gathers_what_another_compiler_needs(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            self.build_gl(work)
            output = shim.export_sources(work / "test.wasm", work / "sources")
            sources = (output / "sources.txt").read_text().split()
            defines = (output / "defines.txt").read_text().split()
            self.assertEqual(sources, ["app.c", "rt_wasm2c.c", "wasm-rt-impl.c", "wasm-rt-mem-impl.c", "gl_shim.c"])
            self.assertIn("RT_GL_DIRECT", defines)
            self.assertIn("WASM_RT_MEMCHECK_BOUNDS_CHECK=1", defines)
            for name in [*sources, "app.h", "rt.h", "gl_shim.h", "gles2.h", "wasm-rt.h", "wasm-rt-impl.h"]:
                self.assertTrue((output / name).exists(), name)
            # The directory is the only include path needed.
            for source in sources:
                subprocess.run([*shim.compiler(), "-w", *[f"-D{define}" for define in defines], "-I", output,
                                "-c", output / source, "-o", work / "check.o"], check=True)

            # A module that doesn't draw gets no GL.
            (work / "plain.wat").write_text(MODULE)
            subprocess.run(["wat2wasm", work / "plain.wat", "-o", work / "plain.wasm"], check=True)
            plain = shim.export_sources(work / "plain.wasm", work / "plain")
            self.assertNotIn("gl_shim.c", (plain / "sources.txt").read_text())
            self.assertNotIn("RT_GL_DIRECT", (plain / "defines.txt").read_text())
            self.assertFalse((plain / "gl_shim.h").exists())

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
