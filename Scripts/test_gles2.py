"""Tests for gles2.py. Run with: python3 -m unittest discover -s Scripts -p 'test_*.py'"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import gles2


def ios_sdk():
    """The iOS SDK, whose OpenGLES headers are a second opinion on the table."""
    if not shutil.which("xcrun"):
        return None
    result = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True)
    path = Path(result.stdout.strip())
    header = path / "System/Library/Frameworks/OpenGLES.framework/Headers/ES2/gl.h"
    return path if result.returncode == 0 and header.exists() else None


class TableTests(unittest.TestCase):

    def test_generated_files_are_current(self):
        for path, text in gles2.outputs().items():
            self.assertTrue(path.exists(), f"{path} is missing: run Scripts/gles2.py generate")
            self.assertEqual(path.read_text(), text, f"{path.name} is out of date: run Scripts/gles2.py generate")

    def test_the_api_is_gles2_without_what_webgl_lacks(self):
        names = [function.name for function in gles2.functions()]
        self.assertEqual(len(names), 140)
        self.assertEqual(len(set(names)), 140)
        self.assertNotIn("glShaderBinary", names)
        self.assertNotIn("glReleaseShaderCompiler", names)
        self.assertEqual(len(gles2.constants()), 301)
        self.assertIn(("GL_TRIANGLES", "0x0004"), gles2.constants())

    def test_every_pointer_says_how_its_used(self):
        for function in gles2.functions():
            for parameter in function.parameters:
                if parameter.pointer and not function.custom:
                    self.assertIn(parameter.use, ("in", "out", "max", "str"), f"{function.name}: {parameter.name}")
                    if parameter.use in ("in", "out"):
                        self.assertTrue(parameter.size, f"{function.name}: {parameter.name} has no size")

    def test_sizes_widen_parameters_by_their_signedness(self):
        functions = {function.name: function for function in gles2.functions()}
        # GLsizei is signed: a negative count must stay negative, to be refused.
        self.assertEqual(gles2.size_expression(functions["glGenBuffers"], "n * 4"), "(int64_t)(int32_t)n * 4")
        self.assertEqual(gles2.size_expression(functions["glReadPixels"], "f(width, format)"),
                         "f((int64_t)(int32_t)width, (int64_t)format)")

    def test_wasm_signatures(self):
        functions = {function.name: function for function in gles2.functions()}
        self.assertEqual(functions["glClearColor"].wasm_parameters, "ffff")
        self.assertEqual(functions["glVertexAttribPointer"].wasm_parameters, "iiiiii")
        self.assertEqual(functions["glTexParameterf"].wasm_parameters, "iif")
        self.assertEqual(functions["glGetError"].wasm_result, "i")
        self.assertEqual(functions["glFlush"].wasm_result, "v")
        self.assertEqual(gles2.imports() & {"env.gl.glClear", "env.gl.glGetString"},
                         {"env.gl.glClear", "env.gl.glGetString"})

    def test_guest_header_declares_imports_and_typed_constants(self):
        header = gles2.guest_header()
        self.assertIn('import_module("env.gl")', header)
        self.assertIn("RT_GL_IMPORT(glDrawArrays) void glDrawArrays(GLenum mode, GLint first, GLsizei count);", header)
        self.assertIn("RT_GL_IMPORT(glGetString) const GLubyte *glGetString(GLenum name);", header)
        self.assertIn("static const GLenum GL_TRIANGLES = 0x0004;", header)
        self.assertIn("static const GLbitfield GL_COLOR_BUFFER_BIT = 0x00004000;", header)
        self.assertIn("static const GLboolean GL_FALSE = 0;", header)
        self.assertIn("static const GLenum GL_RED_BITS = ", header, "a count of bits isn't a bit")
        self.assertEqual(len(re.findall(r"^RT_GL_IMPORT\(", header, flags=re.M)), 140)

    @unittest.skipUnless(shutil.which("clang") or shutil.which("xcrun"), "needs clang")
    def test_shim_compiles_cleanly_both_ways(self):
        clang = ["xcrun", "clang"] if shutil.which("xcrun") else ["clang"]
        for mode in ([], ["-DRT_GL_DIRECT"]):
            subprocess.run([*clang, "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror", "-fsyntax-only", *mode,
                            f"-I{gles2.GUEST_HEADER.parent}", f"-I{gles2.SHIM_HEADER.parent}", gles2.SHIM_SOURCE],
                           check=True)

    @unittest.skipUnless(ios_sdk(), "needs the iOS SDK's OpenGLES headers")
    def test_header_agrees_with_the_ios_sdk(self):
        # Declaring everything twice only compiles if the prototypes and
        # the constants' values are the same.
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "check.c"
            source.write_text("#include <OpenGLES/ES2/gl.h>\n#define GLES2_CONSTANT_MACROS\n#include \"gles2.h\"\n")
            subprocess.run(["xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios15.0", "-std=c11",
                            "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-fsyntax-only",
                            f"-I{gles2.GUEST_HEADER.parent}", source], check=True)


if __name__ == "__main__":
    unittest.main()
