"""Tests for wasm2c-shim.py. Run with: python3 -m unittest discover -s Scripts -p 'test_*.py'

The end-to-end tests (ExampleApp and ExampleUI through wasm2c against the real
runtime) are in Packages/LinkedSlice. These check the generator, and the
shim's conversions and traps against a hand-written module and a fake host.

A Linux slice (`slice`) is built for every Linux target and checked here.
With APPRUNTIME_DOCKER_TESTS=1, each is also loaded and run in Docker, on
its own architecture, by the same fake host: that needs Docker with
emulation for the architectures that aren't the machine's own.
"""

import importlib.util
import os
import plistlib
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
SUPPORT = SCRIPTS / "support"
# Linux target IDs, with the Docker platform each runs on and the Ubuntu
# package and command of a C compiler for it.
LINUX = {
    "linux-arm64": ("linux/arm64", "gcc-aarch64-linux-gnu", "aarch64-linux-gnu-gcc"),
    "linux-armv7": ("linux/arm/v7", "gcc-arm-linux-gnueabihf", "arm-linux-gnueabihf-gcc"),
    "linux-x86_64": ("linux/amd64", "gcc-x86-64-linux-gnu", "x86_64-linux-gnu-gcc"),
}


def custom_section(name, payload):
    """A wasm custom section, to append to a module."""
    body = bytes([len(name)]) + name.encode() + payload
    assert len(body) < 128
    return b"\x00" + bytes([len(body)]) + body


def write_module(text, path):
    """Assembles `text` at `path`, with the rt.abi section an app has."""
    path.with_suffix(".wat").write_text(text)
    subprocess.run(["wat2wasm", path.with_suffix(".wat"), "-o", path], check=True)
    with open(path, "ab") as file:
        file.write(custom_section("rt.abi", (1).to_bytes(4, "little")))
    return path

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

/* HOST_LOADS: the guest isn't linked in. The host loads the libapp.so
 * given as its argument, as a Linux runner does, and exports the rt.h it
 * defines (-rdynamic). */
#ifdef HOST_LOADS
#include <dlfcn.h>
static rt_status (*app_main)(void);
static rt_status (*app_dispatch)(uint32_t context, uint32_t index, rt_obj self,
                                 const rt_slot *args, uint32_t nargs, rt_slot *ret, uint32_t nret);
static void (*app_finalize)(uint32_t context);
#define rt_main app_main
#define rt_dispatch app_dispatch
#define rt_finalize app_finalize
#endif

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

int main(int argc, char **argv) {
    int failures = 0;
#ifdef HOST_LOADS
    void *app = argc > 1 ? dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL) : NULL;
    if (!app) { printf("FAIL %s\n", argc > 1 ? dlerror() : "no libapp.so given"); return 1; }
    app_main = dlsym(app, "rt_main");
    app_dispatch = dlsym(app, "rt_dispatch");
    app_finalize = dlsym(app, "rt_finalize");
    if (!app_main || !app_dispatch || !app_finalize) { printf("FAIL %s\n", dlerror()); return 1; }
#endif
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


# Compares wasm2c-freestanding.c's rounding with the machine's libm, bit for
# bit: the cases rounding turns on, random bit patterns, and values a
# quarter apart around the integers.
ROUNDING = r"""
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

double rt_w2c_rint(double), rt_w2c_trunc(double), rt_w2c_floor(double), rt_w2c_ceil(double);
float rt_w2c_rintf(float), rt_w2c_truncf(float), rt_w2c_floorf(float), rt_w2c_ceilf(float);

static uint64_t state = 0x9E3779B97F4A7C15ull;
static uint64_t next(void) { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state; }
static int same(double a, double b) { return (isnan(a) && isnan(b)) || memcmp(&a, &b, 8) == 0; }
static int samef(float a, float b) { return (isnan(a) && isnan(b)) || memcmp(&a, &b, 4) == 0; }

static long check(double x, float f) {
    long failures = 0;
    if (!same(rt_w2c_rint(x), rint(x)) || !same(rt_w2c_trunc(x), trunc(x)) ||
        !same(rt_w2c_floor(x), floor(x)) || !same(rt_w2c_ceil(x), ceil(x))) {
        printf("FAIL double %a\n", x);
        failures++;
    }
    if (!samef(rt_w2c_rintf(f), rintf(f)) || !samef(rt_w2c_truncf(f), truncf(f)) ||
        !samef(rt_w2c_floorf(f), floorf(f)) || !samef(rt_w2c_ceilf(f), ceilf(f))) {
        printf("FAIL float %a\n", (double)f);
        failures++;
    }
    return failures;
}

int main(void) {
    static const double edges[] = {0.0, -0.0, 0.3, -0.3, 0.5, -0.5, 0.7, -0.7, 1.0, -1.0, 1.5, -1.5, 2.5, -2.5,
        4503599627370495.5, -4503599627370495.5, 4503599627370496.0, 9007199254740993.0, 1e300, -1e300,
        4.9e-324, -4.9e-324, 2.2250738585072014e-308, 8388607.5, -8388607.5, 8388608.0, 16777217.0,
        INFINITY, -INFINITY, NAN};
    long failures = 0;
    for (unsigned i = 0; i < sizeof edges / sizeof *edges; i++) {
        failures += check(edges[i], (float)edges[i]);
    }
    for (long i = 0; i < 1000000 && failures < 10; i++) {
        uint64_t bits = next();
        uint32_t fbits = (uint32_t)next();
        double x; float f;
        memcpy(&x, &bits, 8);
        memcpy(&f, &fbits, 4);
        failures += check(x, f);
        x = (double)((int64_t)(next() % 2000001) - 1000000) / 4.0 * (i % 2 ? 1 : 1e-3);
        failures += check(x, (float)x);
    }
    if (!failures) printf("ok\n");
    return failures != 0;
}
"""


class FreestandingTests(unittest.TestCase):

    def test_rounding_matches_libm(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "rounding.c").write_text(ROUNDING)
            subprocess.run([*shim.compiler(), "-O2", "-I", SUPPORT, work / "rounding.c",
                            SUPPORT / "wasm2c-freestanding.c", "-lm", "-o", work / "rounding"], check=True)
            result = subprocess.run([work / "rounding"], capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "ok", result.stdout)


@unittest.skipUnless(HAS_WABT, "needs WABT (brew install wabt)")
class LinuxSliceTests(unittest.TestCase):
    """App.wasm as libapp.so, the Linux slice a runner loads."""

    @classmethod
    def setUpClass(cls):
        import guest
        cls.guest = guest
        try:
            cls.toolchain = guest.Toolchain(SCRIPTS.parent)
            for tool in ("clang", "ld.lld", "llvm-objcopy", "llvm-nm"):
                cls.toolchain.tool(tool)
        except (guest.BuildError, OSError) as error:
            raise unittest.SkipTest(f"no toolchain: {error}")

    def setUp(self):
        self.work = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()

    def undefined(self, shared):
        return set(self.guest.symbols(self.toolchain, shared, undefined=True, dynamic=True))

    def test_a_module_builds_for_every_linux_target(self):
        wasm = write_module(MODULE, self.work / "test.wasm")
        for target in LINUX:
            with self.subTest(target):
                shared = shim.build_slice(wasm, self.work, target)
                self.assertEqual(shared, self.work / target / "libapp.so")
                # build_slice ran guest.py's checks; they pass again here.
                self.assertEqual(self.guest.check_shared(self.toolchain, shared), [])
                undefined = self.undefined(shared)
                # What MODULE imports, and the libc set: no libc's own names.
                self.assertTrue({"rt_string_new", "rt_string_utf8", "rt_call", "malloc", "getentropy"} <= undefined)
                self.assertFalse(undefined & {"calloc", "realloc", "strlen", "setjmp", "_setjmp", "__sigsetjmp",
                                              "longjmp", "siglongjmp", "mmap", "stderr", "fprintf",
                                              "pthread_mutex_lock", "clock_getres", "floor", "__assert_fail"})

    def test_a_module_that_draws_asks_for_the_hosts_gl(self):
        wasm = write_module(GL_MODULE, self.work / "test.wasm")
        undefined = self.undefined(shim.build_slice(wasm, self.work, "linux-armv7"))
        self.assertTrue({"glClearColor", "glBufferData", "rt_gl_context_generation"} <= undefined)
        self.assertFalse({name for name in undefined if name.startswith("rt_gl_gl")}, "the shim is inside the slice")

    def test_a_module_without_its_abi_section_is_refused(self):
        (self.work / "test.wat").write_text(MODULE)
        subprocess.run(["wat2wasm", self.work / "test.wat", "-o", self.work / "test.wasm"], check=True)
        with self.assertRaisesRegex(shim.ShimError, "missing .rt_abi section"):
            shim.build_slice(self.work / "test.wasm", self.work, "linux-x86_64")

    def test_only_linux_targets_are_slices(self):
        wasm = write_module(MODULE, self.work / "test.wasm")
        for target in ("android-arm64-v8a", "macos", "linux-riscv64"):
            with self.assertRaisesRegex(shim.ShimError, "isn't a Linux target"):
                shim.build_slice(wasm, self.work, target)

    def bundle(self):
        bundle = self.work / "org.example.app"
        (bundle / "wasm32").mkdir(parents=True)
        (bundle / "lib" / "macos").mkdir(parents=True)
        (bundle / "lib" / "macos" / "libapp.a").write_bytes(b"archive")
        write_module(MODULE, bundle / "wasm32" / "App.wasm")
        (bundle / "wasm32" / "App.wat").unlink()
        with open(bundle / "Info.plist", "wb") as file:
            plistlib.dump({"CFBundleIdentifier": "org.example.app", "RTTargets": ["wasm32", "macos"]}, file)
        (bundle / "_CodeSignature").mkdir()
        with open(bundle / "_CodeSignature" / "CodeResources", "wb") as file:
            plistlib.dump(self.guest.code_resources(bundle), file)
        return bundle

    def test_a_bundle_gains_a_slice(self):
        bundle = self.bundle()
        with open(bundle / "_CodeSignature" / "CodeResources", "rb") as file:
            before = plistlib.load(file)["files"]
        built = shim.add_slices(bundle, ["linux-x86_64"])
        self.assertEqual(built, [bundle / "lib" / "linux-x86_64" / "libapp.so"])
        self.assertEqual(self.guest.check_shared(self.toolchain, built[0]), [])
        with open(bundle / "Info.plist", "rb") as file:
            self.assertEqual(plistlib.load(file)["RTTargets"], ["wasm32", "macos", "linux-x86_64"])
        with open(bundle / "_CodeSignature" / "CodeResources", "rb") as file:
            after = plistlib.load(file)["files"]
        # Every file is listed with its hash, as guest.py lists them.
        self.assertEqual(after, self.guest.code_resources(bundle)["files"])
        self.assertEqual(set(after) - set(before), {"lib/linux-x86_64/libapp.so"})
        self.assertEqual(after["wasm32/App.wasm"], before["wasm32/App.wasm"])
        self.assertNotEqual(after["Info.plist"], before["Info.plist"])

    def test_a_slice_the_bundle_has_isnt_replaced(self):
        bundle = self.bundle()
        with self.assertRaisesRegex(shim.ShimError, "already has a macos slice"):
            shim.add_slices(bundle, ["macos"])
        shim.add_slices(bundle, ["linux-x86_64"])
        with self.assertRaisesRegex(shim.ShimError, "already has a linux-x86_64 slice"):
            shim.add_slices(bundle, ["linux-x86_64"])
        with self.assertRaisesRegex(shim.ShimError, "isn't a bundle"):
            shim.add_slices(self.work, ["linux-x86_64"])

    @unittest.skipUnless(os.environ.get("APPRUNTIME_DOCKER_TESTS"), "set APPRUNTIME_DOCKER_TESTS=1 to run in Docker")
    def test_each_slice_loads_and_traps_on_its_architecture(self):
        wasm = write_module(MODULE, self.work / "test.wasm")
        for target in LINUX:
            shim.build_slice(wasm, self.work, target)
        (self.work / "host.c").write_text(HOST)
        shutil.copy(shim.RT_H, self.work / "rt.h")
        docker = ["docker", "run", "--rm", "-v", f"{self.work}:/work", "-w", "/work"]
        # The hosts are compiled once, on the machine's own architecture: by
        # its own compiler for its own target, and a cross compiler for the
        # others. Every run names its platform: a tag pulled for another
        # platform is otherwise what Docker runs.
        machine = subprocess.run(["docker", "info", "--format", "{{.Architecture}}"],
                                 capture_output=True, text=True, check=True).stdout.strip()
        native = {"aarch64": "linux-arm64", "arm64": "linux-arm64", "x86_64": "linux-x86_64", "amd64": "linux-x86_64"}[machine]
        cross = {target: (package, command) for target, (_, package, command) in LINUX.items() if target != native}
        compile_hosts = "\n".join(
            f"{cross[target][1] if target in cross else 'gcc'} -O1 -w -I. -DHOST_LOADS -rdynamic host.c -ldl -o host-{target}"
            for target in LINUX)
        packages = " ".join(["gcc", "libc6-dev", *[package for package, _ in cross.values()]])
        subprocess.run([*docker, "--platform", LINUX[native][0], "ubuntu:24.04", "sh", "-euc", f"""
            apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq {packages} >/dev/null 2>&1
            {compile_hosts}
            """], check=True)
        for target, (platform, _, _) in LINUX.items():
            with self.subTest(target):
                result = subprocess.run([*docker, "--platform", platform, "ubuntu:24.04",
                                         f"./host-{target}", f"./{target}/libapp.so"], capture_output=True, text=True)
                self.assertEqual(result.stdout.strip(), "ok", result.stdout + result.stderr)
                self.assertEqual(result.stderr.count("guest trapped"), 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
