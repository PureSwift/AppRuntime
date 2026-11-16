#!/usr/bin/env python3
"""
OpenGL ES 2.0 under WebGL 1 rules (DynamicRuntime.md §8): one table of the
API, and what's generated from it.

    gles2.py generate    writes the files below
    gles2.py check       fails if any of them is out of date

- Sources/CGLES2/include/gles2.h: what a guest imports. On wasm32 each
  function is an import from module "env.gl"; natively it's the platform's
  own `gl*` symbol.
- Sources/CRuntimeGL/include/gl_shim.h, Sources/CRuntimeGL/gl_shim.c: the
  host's side of the wasm imports. Each function turns guest offsets into
  bounds-checked pointers and calls GL, and applies the WebGL rules that
  keep a guest from reaching host memory through GL.

- Packages/LinkedSlice/Tests/CFakeGL: a GL that only writes down what it's
  asked, for tests that link an app's library. It defines every function,
  as a real GL library does.

wasm2c-shim.py imports this module for the wrappers that connect a
translated module's `env.gl` imports to the shim.

The table is the GLES 2.0 core API without glShaderBinary and
glReleaseShaderCompiler, which WebGL 1 doesn't have. A pointer parameter
says how it's used, in braces after its name:

    {in N}      read; N bytes, a C expression over the parameters
    {out N}     written; N bytes
    {in? N}     may be null (likewise out?)
    {max N}     written; at most N bytes, how many isn't known beforehand
    {str}       a NUL-terminated string, read

`!` after a declaration marks a function written by hand in SHIM_CUSTOM.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUEST_HEADER = ROOT / "Sources" / "CGLES2" / "include" / "gles2.h"
SHIM_HEADER = ROOT / "Sources" / "CRuntimeGL" / "include" / "gl_shim.h"
SHIM_SOURCE = ROOT / "Sources" / "CRuntimeGL" / "gl_shim.c"
FAKE_HEADER = ROOT / "Packages" / "LinkedSlice" / "Tests" / "CFakeGL" / "include" / "fake_gl.h"
FAKE_SOURCE = ROOT / "Packages" / "LinkedSlice" / "Tests" / "CFakeGL" / "fake_gl.c"

# The wasm import module (§8.1).
IMPORT_MODULE = "env.gl"

FUNCTIONS = """
void glActiveTexture(GLenum texture)
void glAttachShader(GLuint program, GLuint shader)
void glBindAttribLocation(GLuint program, GLuint index, const GLchar *name {str})
void glBindBuffer(GLenum target, GLuint buffer) !
void glBindFramebuffer(GLenum target, GLuint framebuffer)
void glBindRenderbuffer(GLenum target, GLuint renderbuffer)
void glBindTexture(GLenum target, GLuint texture)
void glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha)
void glBlendEquation(GLenum mode)
void glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha)
void glBlendFunc(GLenum sfactor, GLenum dfactor)
void glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha)
void glBufferData(GLenum target, GLsizeiptr size, const void *data {in? size}, GLenum usage)
void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void *data {in size})
GLenum glCheckFramebufferStatus(GLenum target)
void glClear(GLbitfield mask)
void glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha)
void glClearDepthf(GLclampf depth)
void glClearStencil(GLint s)
void glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha)
void glCompileShader(GLuint shader)
void glCompressedTexImage2D(GLenum target, GLint level, GLenum internalformat, GLsizei width, GLsizei height, GLint border, GLsizei imageSize, const void *data {in imageSize})
void glCompressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void *data {in imageSize})
void glCopyTexImage2D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y, GLsizei width, GLsizei height, GLint border)
void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height)
GLuint glCreateProgram(void)
GLuint glCreateShader(GLenum type)
void glCullFace(GLenum mode)
void glDeleteBuffers(GLsizei n, const GLuint *buffers {in n * 4}) !
void glDeleteFramebuffers(GLsizei n, const GLuint *framebuffers {in n * 4})
void glDeleteProgram(GLuint program)
void glDeleteRenderbuffers(GLsizei n, const GLuint *renderbuffers {in n * 4})
void glDeleteShader(GLuint shader)
void glDeleteTextures(GLsizei n, const GLuint *textures {in n * 4})
void glDepthFunc(GLenum func)
void glDepthMask(GLboolean flag)
void glDepthRangef(GLclampf zNear, GLclampf zFar)
void glDetachShader(GLuint program, GLuint shader)
void glDisable(GLenum cap)
void glDisableVertexAttribArray(GLuint index) !
void glDrawArrays(GLenum mode, GLint first, GLsizei count) !
void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices) !
void glEnable(GLenum cap)
void glEnableVertexAttribArray(GLuint index) !
void glFinish(void)
void glFlush(void)
void glFramebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer)
void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level)
void glFrontFace(GLenum mode)
void glGenBuffers(GLsizei n, GLuint *buffers {out n * 4})
void glGenerateMipmap(GLenum target)
void glGenFramebuffers(GLsizei n, GLuint *framebuffers {out n * 4})
void glGenRenderbuffers(GLsizei n, GLuint *renderbuffers {out n * 4})
void glGenTextures(GLsizei n, GLuint *textures {out n * 4})
void glGetActiveAttrib(GLuint program, GLuint index, GLsizei bufSize, GLsizei *length {out? 4}, GLint *size {out 4}, GLenum *type {out 4}, GLchar *name {out bufSize})
void glGetActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei *length {out? 4}, GLint *size {out 4}, GLenum *type {out 4}, GLchar *name {out bufSize})
void glGetAttachedShaders(GLuint program, GLsizei maxCount, GLsizei *count {out? 4}, GLuint *shaders {out maxCount * 4})
GLint glGetAttribLocation(GLuint program, const GLchar *name {str})
void glGetBooleanv(GLenum pname, GLboolean *params) !
void glGetBufferParameteriv(GLenum target, GLenum pname, GLint *params {out 4})
GLenum glGetError(void) !
void glGetFloatv(GLenum pname, GLfloat *params) !
void glGetFramebufferAttachmentParameteriv(GLenum target, GLenum attachment, GLenum pname, GLint *params {out 4})
void glGetIntegerv(GLenum pname, GLint *params) !
void glGetProgramiv(GLuint program, GLenum pname, GLint *params {out 4})
void glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei *length {out? 4}, GLchar *infoLog {out bufSize})
void glGetRenderbufferParameteriv(GLenum target, GLenum pname, GLint *params {out 4})
void glGetShaderiv(GLuint shader, GLenum pname, GLint *params {out 4})
void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei *length {out? 4}, GLchar *infoLog {out bufSize})
void glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint *range {out 8}, GLint *precision {out 4})
void glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei *length {out? 4}, GLchar *source {out bufSize})
const GLubyte *glGetString(GLenum name) !
void glGetTexParameterfv(GLenum target, GLenum pname, GLfloat *params {out 4})
void glGetTexParameteriv(GLenum target, GLenum pname, GLint *params {out 4})
void glGetUniformfv(GLuint program, GLint location, GLfloat *params {max 64})
void glGetUniformiv(GLuint program, GLint location, GLint *params {max 64})
GLint glGetUniformLocation(GLuint program, const GLchar *name {str})
void glGetVertexAttribfv(GLuint index, GLenum pname, GLfloat *params {max 16})
void glGetVertexAttribiv(GLuint index, GLenum pname, GLint *params {max 16})
void glGetVertexAttribPointerv(GLuint index, GLenum pname, void **pointer) !
void glHint(GLenum target, GLenum mode)
GLboolean glIsBuffer(GLuint buffer)
GLboolean glIsEnabled(GLenum cap)
GLboolean glIsFramebuffer(GLuint framebuffer)
GLboolean glIsProgram(GLuint program)
GLboolean glIsRenderbuffer(GLuint renderbuffer)
GLboolean glIsShader(GLuint shader)
GLboolean glIsTexture(GLuint texture)
void glLineWidth(GLfloat width)
void glLinkProgram(GLuint program)
void glPixelStorei(GLenum pname, GLint param) !
void glPolygonOffset(GLfloat factor, GLfloat units)
void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void *pixels {out rt_gl_image_size(width, height, format, type, c->pack_alignment)})
void glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height)
void glSampleCoverage(GLclampf value, GLboolean invert)
void glScissor(GLint x, GLint y, GLsizei width, GLsizei height)
void glShaderSource(GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length) !
void glStencilFunc(GLenum func, GLint ref, GLuint mask)
void glStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask)
void glStencilMask(GLuint mask)
void glStencilMaskSeparate(GLenum face, GLuint mask)
void glStencilOp(GLenum fail, GLenum zfail, GLenum zpass)
void glStencilOpSeparate(GLenum face, GLenum fail, GLenum zfail, GLenum zpass)
void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void *pixels {in? rt_gl_image_size(width, height, format, type, c->unpack_alignment)})
void glTexParameterf(GLenum target, GLenum pname, GLfloat param)
void glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params {in 4})
void glTexParameteri(GLenum target, GLenum pname, GLint param)
void glTexParameteriv(GLenum target, GLenum pname, const GLint *params {in 4})
void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels {in rt_gl_image_size(width, height, format, type, c->unpack_alignment)})
void glUniform1f(GLint location, GLfloat x)
void glUniform1fv(GLint location, GLsizei count, const GLfloat *v {in count * 4})
void glUniform1i(GLint location, GLint x)
void glUniform1iv(GLint location, GLsizei count, const GLint *v {in count * 4})
void glUniform2f(GLint location, GLfloat x, GLfloat y)
void glUniform2fv(GLint location, GLsizei count, const GLfloat *v {in count * 8})
void glUniform2i(GLint location, GLint x, GLint y)
void glUniform2iv(GLint location, GLsizei count, const GLint *v {in count * 8})
void glUniform3f(GLint location, GLfloat x, GLfloat y, GLfloat z)
void glUniform3fv(GLint location, GLsizei count, const GLfloat *v {in count * 12})
void glUniform3i(GLint location, GLint x, GLint y, GLint z)
void glUniform3iv(GLint location, GLsizei count, const GLint *v {in count * 12})
void glUniform4f(GLint location, GLfloat x, GLfloat y, GLfloat z, GLfloat w)
void glUniform4fv(GLint location, GLsizei count, const GLfloat *v {in count * 16})
void glUniform4i(GLint location, GLint x, GLint y, GLint z, GLint w)
void glUniform4iv(GLint location, GLsizei count, const GLint *v {in count * 16})
void glUniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value {in count * 16})
void glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value {in count * 36})
void glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value {in count * 64})
void glUseProgram(GLuint program)
void glValidateProgram(GLuint program)
void glVertexAttrib1f(GLuint index, GLfloat x)
void glVertexAttrib1fv(GLuint index, const GLfloat *values {in 4})
void glVertexAttrib2f(GLuint index, GLfloat x, GLfloat y)
void glVertexAttrib2fv(GLuint index, const GLfloat *values {in 8})
void glVertexAttrib3f(GLuint index, GLfloat x, GLfloat y, GLfloat z)
void glVertexAttrib3fv(GLuint index, const GLfloat *values {in 12})
void glVertexAttrib4f(GLuint index, GLfloat x, GLfloat y, GLfloat z, GLfloat w)
void glVertexAttrib4fv(GLuint index, const GLfloat *values {in 16})
void glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *pointer) !
void glViewport(GLint x, GLint y, GLsizei width, GLsizei height)
"""

# Name and value, in gl2.h's order.
CONSTANTS = """
GL_DEPTH_BUFFER_BIT 0x00000100
GL_STENCIL_BUFFER_BIT 0x00000400
GL_COLOR_BUFFER_BIT 0x00004000
GL_FALSE 0
GL_TRUE 1
GL_POINTS 0x0000
GL_LINES 0x0001
GL_LINE_LOOP 0x0002
GL_LINE_STRIP 0x0003
GL_TRIANGLES 0x0004
GL_TRIANGLE_STRIP 0x0005
GL_TRIANGLE_FAN 0x0006
GL_ZERO 0
GL_ONE 1
GL_SRC_COLOR 0x0300
GL_ONE_MINUS_SRC_COLOR 0x0301
GL_SRC_ALPHA 0x0302
GL_ONE_MINUS_SRC_ALPHA 0x0303
GL_DST_ALPHA 0x0304
GL_ONE_MINUS_DST_ALPHA 0x0305
GL_DST_COLOR 0x0306
GL_ONE_MINUS_DST_COLOR 0x0307
GL_SRC_ALPHA_SATURATE 0x0308
GL_FUNC_ADD 0x8006
GL_BLEND_EQUATION 0x8009
GL_BLEND_EQUATION_RGB 0x8009
GL_BLEND_EQUATION_ALPHA 0x883D
GL_FUNC_SUBTRACT 0x800A
GL_FUNC_REVERSE_SUBTRACT 0x800B
GL_BLEND_DST_RGB 0x80C8
GL_BLEND_SRC_RGB 0x80C9
GL_BLEND_DST_ALPHA 0x80CA
GL_BLEND_SRC_ALPHA 0x80CB
GL_CONSTANT_COLOR 0x8001
GL_ONE_MINUS_CONSTANT_COLOR 0x8002
GL_CONSTANT_ALPHA 0x8003
GL_ONE_MINUS_CONSTANT_ALPHA 0x8004
GL_BLEND_COLOR 0x8005
GL_ARRAY_BUFFER 0x8892
GL_ELEMENT_ARRAY_BUFFER 0x8893
GL_ARRAY_BUFFER_BINDING 0x8894
GL_ELEMENT_ARRAY_BUFFER_BINDING 0x8895
GL_STREAM_DRAW 0x88E0
GL_STATIC_DRAW 0x88E4
GL_DYNAMIC_DRAW 0x88E8
GL_BUFFER_SIZE 0x8764
GL_BUFFER_USAGE 0x8765
GL_CURRENT_VERTEX_ATTRIB 0x8626
GL_FRONT 0x0404
GL_BACK 0x0405
GL_FRONT_AND_BACK 0x0408
GL_TEXTURE_2D 0x0DE1
GL_CULL_FACE 0x0B44
GL_BLEND 0x0BE2
GL_DITHER 0x0BD0
GL_STENCIL_TEST 0x0B90
GL_DEPTH_TEST 0x0B71
GL_SCISSOR_TEST 0x0C11
GL_POLYGON_OFFSET_FILL 0x8037
GL_SAMPLE_ALPHA_TO_COVERAGE 0x809E
GL_SAMPLE_COVERAGE 0x80A0
GL_NO_ERROR 0
GL_INVALID_ENUM 0x0500
GL_INVALID_VALUE 0x0501
GL_INVALID_OPERATION 0x0502
GL_OUT_OF_MEMORY 0x0505
GL_CW 0x0900
GL_CCW 0x0901
GL_LINE_WIDTH 0x0B21
GL_ALIASED_POINT_SIZE_RANGE 0x846D
GL_ALIASED_LINE_WIDTH_RANGE 0x846E
GL_CULL_FACE_MODE 0x0B45
GL_FRONT_FACE 0x0B46
GL_DEPTH_RANGE 0x0B70
GL_DEPTH_WRITEMASK 0x0B72
GL_DEPTH_CLEAR_VALUE 0x0B73
GL_DEPTH_FUNC 0x0B74
GL_STENCIL_CLEAR_VALUE 0x0B91
GL_STENCIL_FUNC 0x0B92
GL_STENCIL_FAIL 0x0B94
GL_STENCIL_PASS_DEPTH_FAIL 0x0B95
GL_STENCIL_PASS_DEPTH_PASS 0x0B96
GL_STENCIL_REF 0x0B97
GL_STENCIL_VALUE_MASK 0x0B93
GL_STENCIL_WRITEMASK 0x0B98
GL_STENCIL_BACK_FUNC 0x8800
GL_STENCIL_BACK_FAIL 0x8801
GL_STENCIL_BACK_PASS_DEPTH_FAIL 0x8802
GL_STENCIL_BACK_PASS_DEPTH_PASS 0x8803
GL_STENCIL_BACK_REF 0x8CA3
GL_STENCIL_BACK_VALUE_MASK 0x8CA4
GL_STENCIL_BACK_WRITEMASK 0x8CA5
GL_VIEWPORT 0x0BA2
GL_SCISSOR_BOX 0x0C10
GL_COLOR_CLEAR_VALUE 0x0C22
GL_COLOR_WRITEMASK 0x0C23
GL_UNPACK_ALIGNMENT 0x0CF5
GL_PACK_ALIGNMENT 0x0D05
GL_MAX_TEXTURE_SIZE 0x0D33
GL_MAX_VIEWPORT_DIMS 0x0D3A
GL_SUBPIXEL_BITS 0x0D50
GL_RED_BITS 0x0D52
GL_GREEN_BITS 0x0D53
GL_BLUE_BITS 0x0D54
GL_ALPHA_BITS 0x0D55
GL_DEPTH_BITS 0x0D56
GL_STENCIL_BITS 0x0D57
GL_POLYGON_OFFSET_UNITS 0x2A00
GL_POLYGON_OFFSET_FACTOR 0x8038
GL_TEXTURE_BINDING_2D 0x8069
GL_SAMPLE_BUFFERS 0x80A8
GL_SAMPLES 0x80A9
GL_SAMPLE_COVERAGE_VALUE 0x80AA
GL_SAMPLE_COVERAGE_INVERT 0x80AB
GL_NUM_COMPRESSED_TEXTURE_FORMATS 0x86A2
GL_COMPRESSED_TEXTURE_FORMATS 0x86A3
GL_DONT_CARE 0x1100
GL_FASTEST 0x1101
GL_NICEST 0x1102
GL_GENERATE_MIPMAP_HINT 0x8192
GL_BYTE 0x1400
GL_UNSIGNED_BYTE 0x1401
GL_SHORT 0x1402
GL_UNSIGNED_SHORT 0x1403
GL_INT 0x1404
GL_UNSIGNED_INT 0x1405
GL_FLOAT 0x1406
GL_FIXED 0x140C
GL_DEPTH_COMPONENT 0x1902
GL_ALPHA 0x1906
GL_RGB 0x1907
GL_RGBA 0x1908
GL_LUMINANCE 0x1909
GL_LUMINANCE_ALPHA 0x190A
GL_UNSIGNED_SHORT_4_4_4_4 0x8033
GL_UNSIGNED_SHORT_5_5_5_1 0x8034
GL_UNSIGNED_SHORT_5_6_5 0x8363
GL_FRAGMENT_SHADER 0x8B30
GL_VERTEX_SHADER 0x8B31
GL_MAX_VERTEX_ATTRIBS 0x8869
GL_MAX_VERTEX_UNIFORM_VECTORS 0x8DFB
GL_MAX_VARYING_VECTORS 0x8DFC
GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS 0x8B4D
GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS 0x8B4C
GL_MAX_TEXTURE_IMAGE_UNITS 0x8872
GL_MAX_FRAGMENT_UNIFORM_VECTORS 0x8DFD
GL_SHADER_TYPE 0x8B4F
GL_DELETE_STATUS 0x8B80
GL_LINK_STATUS 0x8B82
GL_VALIDATE_STATUS 0x8B83
GL_ATTACHED_SHADERS 0x8B85
GL_ACTIVE_UNIFORMS 0x8B86
GL_ACTIVE_UNIFORM_MAX_LENGTH 0x8B87
GL_ACTIVE_ATTRIBUTES 0x8B89
GL_ACTIVE_ATTRIBUTE_MAX_LENGTH 0x8B8A
GL_SHADING_LANGUAGE_VERSION 0x8B8C
GL_CURRENT_PROGRAM 0x8B8D
GL_NEVER 0x0200
GL_LESS 0x0201
GL_EQUAL 0x0202
GL_LEQUAL 0x0203
GL_GREATER 0x0204
GL_NOTEQUAL 0x0205
GL_GEQUAL 0x0206
GL_ALWAYS 0x0207
GL_KEEP 0x1E00
GL_REPLACE 0x1E01
GL_INCR 0x1E02
GL_DECR 0x1E03
GL_INVERT 0x150A
GL_INCR_WRAP 0x8507
GL_DECR_WRAP 0x8508
GL_VENDOR 0x1F00
GL_RENDERER 0x1F01
GL_VERSION 0x1F02
GL_EXTENSIONS 0x1F03
GL_NEAREST 0x2600
GL_LINEAR 0x2601
GL_NEAREST_MIPMAP_NEAREST 0x2700
GL_LINEAR_MIPMAP_NEAREST 0x2701
GL_NEAREST_MIPMAP_LINEAR 0x2702
GL_LINEAR_MIPMAP_LINEAR 0x2703
GL_TEXTURE_MAG_FILTER 0x2800
GL_TEXTURE_MIN_FILTER 0x2801
GL_TEXTURE_WRAP_S 0x2802
GL_TEXTURE_WRAP_T 0x2803
GL_TEXTURE 0x1702
GL_TEXTURE_CUBE_MAP 0x8513
GL_TEXTURE_BINDING_CUBE_MAP 0x8514
GL_TEXTURE_CUBE_MAP_POSITIVE_X 0x8515
GL_TEXTURE_CUBE_MAP_NEGATIVE_X 0x8516
GL_TEXTURE_CUBE_MAP_POSITIVE_Y 0x8517
GL_TEXTURE_CUBE_MAP_NEGATIVE_Y 0x8518
GL_TEXTURE_CUBE_MAP_POSITIVE_Z 0x8519
GL_TEXTURE_CUBE_MAP_NEGATIVE_Z 0x851A
GL_MAX_CUBE_MAP_TEXTURE_SIZE 0x851C
GL_TEXTURE0 0x84C0
GL_TEXTURE1 0x84C1
GL_TEXTURE2 0x84C2
GL_TEXTURE3 0x84C3
GL_TEXTURE4 0x84C4
GL_TEXTURE5 0x84C5
GL_TEXTURE6 0x84C6
GL_TEXTURE7 0x84C7
GL_TEXTURE8 0x84C8
GL_TEXTURE9 0x84C9
GL_TEXTURE10 0x84CA
GL_TEXTURE11 0x84CB
GL_TEXTURE12 0x84CC
GL_TEXTURE13 0x84CD
GL_TEXTURE14 0x84CE
GL_TEXTURE15 0x84CF
GL_TEXTURE16 0x84D0
GL_TEXTURE17 0x84D1
GL_TEXTURE18 0x84D2
GL_TEXTURE19 0x84D3
GL_TEXTURE20 0x84D4
GL_TEXTURE21 0x84D5
GL_TEXTURE22 0x84D6
GL_TEXTURE23 0x84D7
GL_TEXTURE24 0x84D8
GL_TEXTURE25 0x84D9
GL_TEXTURE26 0x84DA
GL_TEXTURE27 0x84DB
GL_TEXTURE28 0x84DC
GL_TEXTURE29 0x84DD
GL_TEXTURE30 0x84DE
GL_TEXTURE31 0x84DF
GL_ACTIVE_TEXTURE 0x84E0
GL_REPEAT 0x2901
GL_CLAMP_TO_EDGE 0x812F
GL_MIRRORED_REPEAT 0x8370
GL_FLOAT_VEC2 0x8B50
GL_FLOAT_VEC3 0x8B51
GL_FLOAT_VEC4 0x8B52
GL_INT_VEC2 0x8B53
GL_INT_VEC3 0x8B54
GL_INT_VEC4 0x8B55
GL_BOOL 0x8B56
GL_BOOL_VEC2 0x8B57
GL_BOOL_VEC3 0x8B58
GL_BOOL_VEC4 0x8B59
GL_FLOAT_MAT2 0x8B5A
GL_FLOAT_MAT3 0x8B5B
GL_FLOAT_MAT4 0x8B5C
GL_SAMPLER_2D 0x8B5E
GL_SAMPLER_CUBE 0x8B60
GL_VERTEX_ATTRIB_ARRAY_ENABLED 0x8622
GL_VERTEX_ATTRIB_ARRAY_SIZE 0x8623
GL_VERTEX_ATTRIB_ARRAY_STRIDE 0x8624
GL_VERTEX_ATTRIB_ARRAY_TYPE 0x8625
GL_VERTEX_ATTRIB_ARRAY_NORMALIZED 0x886A
GL_VERTEX_ATTRIB_ARRAY_POINTER 0x8645
GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING 0x889F
GL_IMPLEMENTATION_COLOR_READ_TYPE 0x8B9A
GL_IMPLEMENTATION_COLOR_READ_FORMAT 0x8B9B
GL_COMPILE_STATUS 0x8B81
GL_INFO_LOG_LENGTH 0x8B84
GL_SHADER_SOURCE_LENGTH 0x8B88
GL_SHADER_COMPILER 0x8DFA
GL_SHADER_BINARY_FORMATS 0x8DF8
GL_NUM_SHADER_BINARY_FORMATS 0x8DF9
GL_LOW_FLOAT 0x8DF0
GL_MEDIUM_FLOAT 0x8DF1
GL_HIGH_FLOAT 0x8DF2
GL_LOW_INT 0x8DF3
GL_MEDIUM_INT 0x8DF4
GL_HIGH_INT 0x8DF5
GL_FRAMEBUFFER 0x8D40
GL_RENDERBUFFER 0x8D41
GL_RGBA4 0x8056
GL_RGB5_A1 0x8057
GL_RGB565 0x8D62
GL_DEPTH_COMPONENT16 0x81A5
GL_STENCIL_INDEX8 0x8D48
GL_RENDERBUFFER_WIDTH 0x8D42
GL_RENDERBUFFER_HEIGHT 0x8D43
GL_RENDERBUFFER_INTERNAL_FORMAT 0x8D44
GL_RENDERBUFFER_RED_SIZE 0x8D50
GL_RENDERBUFFER_GREEN_SIZE 0x8D51
GL_RENDERBUFFER_BLUE_SIZE 0x8D52
GL_RENDERBUFFER_ALPHA_SIZE 0x8D53
GL_RENDERBUFFER_DEPTH_SIZE 0x8D54
GL_RENDERBUFFER_STENCIL_SIZE 0x8D55
GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE 0x8CD0
GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME 0x8CD1
GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL 0x8CD2
GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE 0x8CD3
GL_COLOR_ATTACHMENT0 0x8CE0
GL_DEPTH_ATTACHMENT 0x8D00
GL_STENCIL_ATTACHMENT 0x8D20
GL_NONE 0
GL_FRAMEBUFFER_COMPLETE 0x8CD5
GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT 0x8CD6
GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT 0x8CD7
GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS 0x8CD9
GL_FRAMEBUFFER_UNSUPPORTED 0x8CDD
GL_FRAMEBUFFER_BINDING 0x8CA6
GL_RENDERBUFFER_BINDING 0x8CA7
GL_MAX_RENDERBUFFER_SIZE 0x84E8
GL_INVALID_FRAMEBUFFER_OPERATION 0x0506
"""

# Scalar types: (C definition, signed, float).
TYPES = {
    "GLenum": ("uint32_t", False, False),
    "GLboolean": ("uint8_t", False, False),
    "GLbitfield": ("uint32_t", False, False),
    "GLint": ("int32_t", True, False),
    "GLsizei": ("int32_t", True, False),
    "GLuint": ("uint32_t", False, False),
    "GLfloat": ("float", True, True),
    "GLclampf": ("float", True, True),
    "GLintptr": ("intptr_t", True, False),
    "GLsizeiptr": ("intptr_t", True, False),
}
# Only used through pointers.
POINTEE_TYPES = {"GLchar": "char", "GLubyte": "uint8_t", "GLbyte": "int8_t", "GLshort": "int16_t", "GLushort": "uint16_t"}

BOOLEAN_CONSTANTS = {"GL_FALSE", "GL_TRUE"}


class TableError(Exception):
    pass


class Parameter:

    def __init__(self, text):
        match = re.match(r"^(.*?)(\w+)\s*(?:\{(in|out|max|str)(\?)?\s*(.*?)\})?$", text.strip())
        if not match:
            raise TableError(f"can't read parameter {text!r}")
        self.type = match.group(1).strip()
        self.name = match.group(2)
        self.use = match.group(3)
        self.nullable = bool(match.group(4))
        self.size = match.group(5) or None
        self.pointer = self.type.endswith("*")
        if not self.pointer and self.type not in TYPES:
            raise TableError(f"unknown type in {text!r}")

    @property
    def declaration(self):
        return f"{self.type}{'' if self.pointer else ' '}{self.name}"

    @property
    def is_float(self):
        return not self.pointer and TYPES[self.type][2]

    @property
    def wasm(self):
        """The parameter's wasm type: i32 or f32."""
        return "f" if self.is_float else "i"


class Function:

    def __init__(self, line):
        self.custom = line.endswith("!")
        match = re.match(r"^(.*?)(gl\w+)\((.*)\)$", line.rstrip("! "))
        if not match:
            raise TableError(f"can't read {line!r}")
        self.result = match.group(1).strip()
        self.name = match.group(2)
        parameters = match.group(3).strip()
        self.parameters = [] if parameters == "void" else [Parameter(p) for p in split_parameters(parameters)]
        for parameter in self.parameters:
            if parameter.pointer and not parameter.use and not self.custom:
                raise TableError(f"{self.name}: {parameter.name} doesn't say how it's used")

    @property
    def prototype(self):
        parameters = ", ".join(p.declaration for p in self.parameters) or "void"
        space = "" if self.result.endswith("*") else " "
        return f"{self.result}{space}{self.name}({parameters})"

    @property
    def returns_pointer(self):
        return self.result.endswith("*")

    @property
    def wasm_result(self):
        return "v" if self.result == "void" else "i"

    @property
    def wasm_parameters(self):
        return "".join(p.wasm for p in self.parameters)


def split_parameters(text):
    """Splits on the commas outside braces and parentheses."""
    parts, depth, current = [], 0, ""
    for character in text:
        if character in "{(":
            depth += 1
        elif character in "})":
            depth -= 1
        if character == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += character
    parts.append(current)
    return parts


def functions():
    return [Function(line.strip()) for line in FUNCTIONS.strip().splitlines()]


def constants():
    return [tuple(line.split()) for line in CONSTANTS.strip().splitlines()]


def imports():
    """The module's imports, as wasm2c-shim.py and guest.py name them."""
    return {f"{IMPORT_MODULE}.{function.name}" for function in functions()}


GENERATED = "/* Generated by Scripts/gles2.py. Do not edit. */\n"

# ---------------------------------------------------------------------------
# gles2.h
# ---------------------------------------------------------------------------

GUEST_PRELUDE = GENERATED + r"""
/*
 * gles2.h: OpenGL ES 2.0, as a guest sees it (DynamicRuntime.md §8).
 *
 * The functions and constants are those of <GLES2/gl2.h>, without
 * glShaderBinary and glReleaseShaderCompiler.
 *
 *   wasm32:  each function is an import from module "env.gl". The host's shim
 *            turns guest offsets into bounds-checked pointers.
 *   native:  each function is the platform's own symbol (libGLESv2,
 *            OpenGLES.framework, ANGLE), resolved when the host links the
 *            slice.
 *
 * WebGL 1 rules apply in both, so a guest behaves the same everywhere:
 * - Vertex data comes from buffer objects only. glVertexAttribPointer's and
 *   glDrawElements' pointer is an offset into the bound buffer.
 * - There's no glMapBuffer.
 * - Shaders are GLSL ES 1.00 with explicit precision.
 * - Extensions are never assumed: ask glGetString(GL_EXTENSIONS).
 * - The context is current only inside SurfaceDelegate.frame.
 *
 * Constants are typed (`static const`), so Swift code passes them without
 * casts. C code that needs them in a `switch` defines GLES2_CONSTANT_MACROS
 * before including this header.
 *
 * Freestanding: only <stdint.h> and <stddef.h>.
 */
#ifndef RT_GLES2_H
#define RT_GLES2_H

#include <stdint.h>
#include <stddef.h>

#if defined(__wasm__)
#  define RT_GL_IMPORT(name) __attribute__((import_module("@MODULE@"), import_name(#name)))
#else
#  define RT_GL_IMPORT(name) extern __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------- */
/* Types                                                                      */
/* ------------------------------------------------------------------------- */

typedef void GLvoid;
"""

GUEST_END = r"""
#ifdef __cplusplus
}
#endif

#endif /* RT_GLES2_H */
"""


def guest_header():
    lines = [GUEST_PRELUDE.replace("@MODULE@", IMPORT_MODULE)]
    for name, (definition, _, _) in TYPES.items():
        lines.append(f"typedef {definition} {name};\n")
    for name, definition in POINTEE_TYPES.items():
        lines.append(f"typedef {definition} {name};\n")
    lines.append("\n/* ------------------------------------------------------------------------- */\n"
                 "/* Constants                                                                  */\n"
                 "/* ------------------------------------------------------------------------- */\n\n")
    lines.append("#ifdef GLES2_CONSTANT_MACROS\n")
    for name, value in constants():
        lines.append(f"#define {name} {value}\n")
    lines.append("#else\n")
    for name, value in constants():
        if name in BOOLEAN_CONSTANTS:
            kind = "GLboolean"
        elif name.endswith("_BIT"):
            kind = "GLbitfield"
        else:
            kind = "GLenum"
        lines.append(f"static const {kind} {name} = {value};\n")
    lines.append("#endif\n")
    lines.append("\n/* ------------------------------------------------------------------------- */\n"
                 "/* Functions                                                                  */\n"
                 "/* ------------------------------------------------------------------------- */\n\n")
    for function in functions():
        lines.append(f"RT_GL_IMPORT({function.name}) {function.prototype};\n")
    lines.append(GUEST_END)
    return "".join(lines)


# ---------------------------------------------------------------------------
# gl_shim.h
# ---------------------------------------------------------------------------

SHIM_HEADER_PRELUDE = GENERATED + r"""
/*
 * gl_shim.h: the host's side of a wasm guest's "env.gl" imports
 * (DynamicRuntime.md §8.1).
 *
 * Each rt_gl_* function takes a GL call's arguments as the guest passed
 * them: integers and offsets into its linear memory. It checks every offset
 * against the memory's bounds, applies the WebGL rules below, and calls GL.
 * Both wasm engines use it: wasm2c output calls these functions directly,
 * and an interpreter calls them through rt_gl_call.
 *
 * What it enforces, because a guest must never reach host memory:
 * - Every pointer argument lies inside the guest's memory for as many bytes
 *   as GL reads or writes. Otherwise the call isn't made and `trapped` is
 *   set: the engine traps the guest.
 * - Vertex data comes from buffer objects only. glVertexAttribPointer needs
 *   a bound ARRAY_BUFFER, glDrawElements a bound ELEMENT_ARRAY_BUFFER, and a
 *   draw with an enabled attribute that has no buffer fails with
 *   GL_INVALID_OPERATION, as in WebGL. Without this, GL would read the
 *   offset as a host address.
 *
 * What it doesn't: checking a draw call's indices and counts against the
 * sizes of the bound buffers. Whether an out-of-range read is safe is the
 * GL implementation's business. A host that needs that guarantee uses a GL
 * that validates it, such as ANGLE with its WebGL compatibility context.
 *
 * Two ways to reach GL, chosen when this is compiled:
 * - default: through `api`, a table of function pointers the host fills
 *   (rt_gl_api_load). Nothing here links against GL.
 * - RT_GL_DIRECT: the `gl*` symbols themselves, for wasm2c output sealed
 *   into a slice, which then looks to the host like a native one.
 *
 * Single-threaded, like the runtime (§6.4). The host sets `base` and `size`
 * before every call: a guest's memory can move when it grows.
 */
#ifndef RT_GL_SHIM_H
#define RT_GL_SHIM_H

#include <stdint.h>
#include <stddef.h>

#include "gles2.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Vertex attributes the shim tracks. An index past it is GL_INVALID_VALUE. */
#define RT_GL_MAX_VERTEX_ATTRIBS 32
"""

SHIM_HEADER_CONTEXT = r"""
typedef struct rt_gl_context {
#ifndef RT_GL_DIRECT
    /* The GL to call. */
    const rt_gl_api *api;
#endif
    /* The guest's linear memory, valid for the call being made. */
    uint8_t *base;
    uint64_t size;
    /* Set when a call's pointer was out of bounds; the engine traps. */
    int trapped;

    /* The rest is the shim's own. */
    uint32_t error;
    int skip;
    int32_t pack_alignment;
    int32_t unpack_alignment;
    uint32_t array_buffer;
    uint32_t element_array_buffer;
    uint32_t attrib_buffer[RT_GL_MAX_VERTEX_ATTRIBS];
    uint8_t attrib_enabled[RT_GL_MAX_VERTEX_ATTRIBS];
    uint8_t scratch[64];
    uint32_t scratch_offset;
    uint32_t scratch_bytes;
} rt_gl_context;

/* Resets the shim's state to a new GL context's. Call it once before use,
 * and again after a context is lost and recreated. Leaves `api` alone. */
void rt_gl_context_init(rt_gl_context *context);

/* glGetString's result, a host string. The engine copies it into guest
 * memory: that takes the guest's allocator, which the shim doesn't have. */
const uint8_t *rt_gl_get_string(rt_gl_context *context, uint32_t name);

/* One import: its name, its parameters as wasm types ('i' i32, 'f' f32),
 * and its result ('v' none, 'i' i32). glGetString isn't among them. */
typedef struct rt_gl_function {
    const char *name;
    const char *parameters;
    char result;
} rt_gl_function;

uint32_t rt_gl_function_count(void);
const rt_gl_function *rt_gl_function_at(uint32_t index);

/* Calls import `index` with one 64-bit slot per argument: an i32 in the low
 * 32 bits, or an f32's bit pattern there. Returns the result, or 0. */
uint64_t rt_gl_call(rt_gl_context *context, uint32_t index, const uint64_t *arguments);

/* The typed entry points, one per import. */
"""


def shim_result(function):
    return "void" if function.result == "void" else "uint32_t"


def shim_parameters(function):
    parameters = ["rt_gl_context *c"]
    for parameter in function.parameters:
        parameters.append(f"{'float' if parameter.is_float else 'uint32_t'} {parameter.name}")
    return ", ".join(parameters)


def shim_header():
    lines = [SHIM_HEADER_PRELUDE]
    lines.append("\n#ifndef RT_GL_DIRECT\n/* The GL a host provides. */\ntypedef struct rt_gl_api {\n")
    for function in functions():
        parameters = ", ".join(p.declaration for p in function.parameters) or "void"
        space = "" if function.returns_pointer else " "
        lines.append(f"    {function.result}{space}(*{function.name})({parameters});\n")
    lines.append("} rt_gl_api;\n\n"
                 "/* Fills `api` with what `lookup` finds for each function's name (dlsym,\n"
                 " * eglGetProcAddress). Returns how many it didn't find: the API is only\n"
                 " * usable when that's 0. */\n"
                 "typedef void *(*rt_gl_lookup)(const char *name, void *user);\n"
                 "uint32_t rt_gl_api_load(rt_gl_api *api, rt_gl_lookup lookup, void *user);\n"
                 "#endif\n")
    lines.append(SHIM_HEADER_CONTEXT)
    for function in functions():
        if function.returns_pointer:
            continue
        lines.append(f"{shim_result(function)} rt_gl_{function.name}({shim_parameters(function)});\n")
    lines.append("\n#ifdef __cplusplus\n}\n#endif\n\n#endif /* RT_GL_SHIM_H */\n")
    return "".join(lines)


# ---------------------------------------------------------------------------
# gl_shim.c
# ---------------------------------------------------------------------------

SHIM_PRELUDE = GENERATED + r"""
#define GLES2_CONSTANT_MACROS
#include "gl_shim.h"

#include <stdlib.h>
#include <string.h>

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "wasm memory is little-endian; this shim reads it as is"
#endif

#ifdef RT_GL_DIRECT
#  define RT_GL(name) name
#else
#  define RT_GL(name) c->api->name
#endif

/* Refuses the call being made with a GL error, as WebGL would. glGetError
 * reports it before GL's own. */
static void rt_gl_fail(rt_gl_context *c, uint32_t error) {
    if (c->error == GL_NO_ERROR) {
        c->error = error;
    }
    c->skip = 1;
}

/* `bytes` of guest memory at `offset`, or null and a trap. */
static void *rt_gl_pointer(rt_gl_context *c, uint32_t offset, int64_t bytes, int nullable) {
    if (offset == 0 && nullable) {
        return NULL;
    }
    if (bytes < 0) {
        rt_gl_fail(c, GL_INVALID_VALUE);
        return NULL;
    }
    if ((uint64_t)offset + (uint64_t)bytes > c->size) {
        c->trapped = 1;
        return NULL;
    }
    return c->base + offset;
}

/* A NUL-terminated string in guest memory, and its length. */
static const char *rt_gl_string(rt_gl_context *c, uint32_t offset, size_t *length) {
    for (uint64_t end = offset; end < c->size; end++) {
        if (c->base[end] == 0) {
            if (length) {
                *length = (size_t)(end - offset);
            }
            return (const char *)(c->base + offset);
        }
    }
    c->trapped = 1;
    return NULL;
}

/* Where GL may write up to `maximum` bytes for a result at `offset` whose
 * size isn't known beforehand. That's guest memory itself when all of it
 * fits. At the very end of memory it's a copy of what's there, written back
 * by rt_gl_scratch_end, so bytes GL leaves alone keep their values. */
static void *rt_gl_scratch_begin(rt_gl_context *c, uint32_t offset, size_t maximum) {
    c->scratch_bytes = 0;
    if ((uint64_t)offset + maximum <= c->size) {
        return c->base + offset;
    }
    if (offset >= c->size || maximum > sizeof(c->scratch)) {
        c->trapped = 1;
        return NULL;
    }
    memset(c->scratch, 0, sizeof(c->scratch));
    c->scratch_offset = offset;
    c->scratch_bytes = (uint32_t)(c->size - offset);
    memcpy(c->scratch, c->base + offset, c->scratch_bytes);
    return c->scratch;
}

static void rt_gl_scratch_end(rt_gl_context *c) {
    if (c->scratch_bytes) {
        memcpy(c->base + c->scratch_offset, c->scratch, c->scratch_bytes);
        c->scratch_bytes = 0;
    }
}

static uint32_t rt_gl_load32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return value;
}

/* The bytes glTexImage2D reads or glReadPixels writes, or -1 for a format
 * and type the shim doesn't know. Covers core ES 2.0 and the float, half
 * float, depth texture and BGRA extensions. */
static int64_t rt_gl_image_size(int64_t width, int64_t height, int64_t format, int64_t type, int64_t alignment) {
    int64_t components, pixel;
    if (width < 0 || height < 0) {
        return -1;
    }
    switch (format) {
    case GL_ALPHA: case GL_LUMINANCE: case GL_DEPTH_COMPONENT: components = 1; break;
    case GL_LUMINANCE_ALPHA: components = 2; break;
    case GL_RGB: components = 3; break;
    case GL_RGBA: case 0x80E1 /* GL_BGRA_EXT */: components = 4; break;
    default: return -1;
    }
    switch (type) {
    case GL_UNSIGNED_BYTE: pixel = components; break;
    case GL_UNSIGNED_SHORT_5_6_5: case GL_UNSIGNED_SHORT_4_4_4_4: case GL_UNSIGNED_SHORT_5_5_5_1: pixel = 2; break;
    case GL_UNSIGNED_SHORT: case 0x8D61 /* GL_HALF_FLOAT_OES */: pixel = components * 2; break;
    case GL_UNSIGNED_INT: case GL_FLOAT: pixel = components * 4; break;
    default: return -1;
    }
    if (width == 0 || height == 0) {
        return 0;
    }
    /* Every row but the last is padded to the alignment. */
    int64_t row = (width * pixel + alignment - 1) / alignment * alignment;
    return row * (height - 1) + width * pixel;
}

/* How many values glGet* writes for `pname`, or -1 when the shim doesn't
 * know the name (an extension's). */
static int64_t rt_gl_get_count(rt_gl_context *c, uint32_t pname) {
    GLint count = 0;
    (void)c;
    switch (pname) {
    case GL_ALIASED_LINE_WIDTH_RANGE: case GL_ALIASED_POINT_SIZE_RANGE: case GL_DEPTH_RANGE: case GL_MAX_VIEWPORT_DIMS:
        return 2;
    case GL_VIEWPORT: case GL_SCISSOR_BOX: case GL_COLOR_CLEAR_VALUE: case GL_BLEND_COLOR: case GL_COLOR_WRITEMASK:
        return 4;
    case GL_COMPRESSED_TEXTURE_FORMATS:
        RT_GL(glGetIntegerv)(GL_NUM_COMPRESSED_TEXTURE_FORMATS, &count);
        return count < 0 ? 0 : count;
    case GL_SHADER_BINARY_FORMATS:
        RT_GL(glGetIntegerv)(GL_NUM_SHADER_BINARY_FORMATS, &count);
        return count < 0 ? 0 : count;
    case GL_ACTIVE_TEXTURE: case GL_ALPHA_BITS: case GL_ARRAY_BUFFER_BINDING: case GL_BLEND:
    case GL_BLEND_DST_ALPHA: case GL_BLEND_DST_RGB: case GL_BLEND_EQUATION_ALPHA: case GL_BLEND_EQUATION_RGB:
    case GL_BLEND_SRC_ALPHA: case GL_BLEND_SRC_RGB: case GL_BLUE_BITS: case GL_CULL_FACE: case GL_CULL_FACE_MODE:
    case GL_CURRENT_PROGRAM: case GL_DEPTH_BITS: case GL_DEPTH_CLEAR_VALUE: case GL_DEPTH_FUNC: case GL_DEPTH_TEST:
    case GL_DEPTH_WRITEMASK: case GL_DITHER: case GL_ELEMENT_ARRAY_BUFFER_BINDING: case GL_FRAMEBUFFER_BINDING:
    case GL_FRONT_FACE: case GL_GENERATE_MIPMAP_HINT: case GL_GREEN_BITS: case GL_IMPLEMENTATION_COLOR_READ_FORMAT:
    case GL_IMPLEMENTATION_COLOR_READ_TYPE: case GL_LINE_WIDTH: case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS:
    case GL_MAX_CUBE_MAP_TEXTURE_SIZE: case GL_MAX_FRAGMENT_UNIFORM_VECTORS: case GL_MAX_RENDERBUFFER_SIZE:
    case GL_MAX_TEXTURE_IMAGE_UNITS: case GL_MAX_TEXTURE_SIZE: case GL_MAX_VARYING_VECTORS: case GL_MAX_VERTEX_ATTRIBS:
    case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: case GL_MAX_VERTEX_UNIFORM_VECTORS: case GL_NUM_COMPRESSED_TEXTURE_FORMATS:
    case GL_NUM_SHADER_BINARY_FORMATS: case GL_PACK_ALIGNMENT: case GL_POLYGON_OFFSET_FACTOR: case GL_POLYGON_OFFSET_FILL:
    case GL_POLYGON_OFFSET_UNITS: case GL_RED_BITS: case GL_RENDERBUFFER_BINDING: case GL_SAMPLE_ALPHA_TO_COVERAGE:
    case GL_SAMPLE_BUFFERS: case GL_SAMPLE_COVERAGE: case GL_SAMPLE_COVERAGE_INVERT: case GL_SAMPLE_COVERAGE_VALUE:
    case GL_SAMPLES: case GL_SCISSOR_TEST: case GL_SHADER_COMPILER: case GL_STENCIL_BACK_FAIL: case GL_STENCIL_BACK_FUNC:
    case GL_STENCIL_BACK_PASS_DEPTH_FAIL: case GL_STENCIL_BACK_PASS_DEPTH_PASS: case GL_STENCIL_BACK_REF:
    case GL_STENCIL_BACK_VALUE_MASK: case GL_STENCIL_BACK_WRITEMASK: case GL_STENCIL_BITS: case GL_STENCIL_CLEAR_VALUE:
    case GL_STENCIL_FAIL: case GL_STENCIL_FUNC: case GL_STENCIL_PASS_DEPTH_FAIL: case GL_STENCIL_PASS_DEPTH_PASS:
    case GL_STENCIL_REF: case GL_STENCIL_TEST: case GL_STENCIL_VALUE_MASK: case GL_STENCIL_WRITEMASK: case GL_SUBPIXEL_BITS:
    case GL_TEXTURE_BINDING_2D: case GL_TEXTURE_BINDING_CUBE_MAP: case GL_UNPACK_ALIGNMENT:
        return 1;
    default:
        return -1;
    }
}

/* glGetBooleanv, glGetFloatv and glGetIntegerv: `element` bytes a value. */
#define RT_GL_GET(function, element) \
    do { \
        int64_t count = rt_gl_get_count(c, pname); \
        void *values; \
        if (c->trapped) return; \
        if (count >= 0) { \
            values = rt_gl_pointer(c, params, count * (element), 0); \
        } else { \
            /* Unknown names write at most 16 values. */ \
            values = rt_gl_scratch_begin(c, params, 16 * (element)); \
        } \
        if (c->trapped) return; \
        RT_GL(function)((GLenum)pname, values); \
        rt_gl_scratch_end(c); \
    } while (0)

void rt_gl_context_init(rt_gl_context *c) {
    c->base = NULL;
    c->size = 0;
    c->trapped = 0;
    c->error = GL_NO_ERROR;
    c->skip = 0;
    c->pack_alignment = 4;
    c->unpack_alignment = 4;
    c->array_buffer = 0;
    c->element_array_buffer = 0;
    memset(c->attrib_buffer, 0, sizeof(c->attrib_buffer));
    memset(c->attrib_enabled, 0, sizeof(c->attrib_enabled));
    c->scratch_offset = 0;
    c->scratch_bytes = 0;
}

const uint8_t *rt_gl_get_string(rt_gl_context *c, uint32_t name) {
    (void)c;
    return RT_GL(glGetString)((GLenum)name);
}

/* ------------------------------------------------------------------------- */
/* Written by hand: state the shim tracks, and results GL sizes itself        */
/* ------------------------------------------------------------------------- */

void rt_gl_glBindBuffer(rt_gl_context *c, uint32_t target, uint32_t buffer) {
    if (c->trapped) return;
    RT_GL(glBindBuffer)((GLenum)target, (GLuint)buffer);
    if (target == GL_ARRAY_BUFFER) {
        c->array_buffer = buffer;
    } else if (target == GL_ELEMENT_ARRAY_BUFFER) {
        c->element_array_buffer = buffer;
    }
}

void rt_gl_glDeleteBuffers(rt_gl_context *c, uint32_t n, uint32_t buffers) {
    c->skip = 0;
    const uint8_t *names = rt_gl_pointer(c, buffers, (int64_t)(int32_t)n * 4, 0);
    if (c->trapped || c->skip) return;
    RT_GL(glDeleteBuffers)((GLsizei)n, (const GLuint *)names);
    /* GL unbinds a deleted buffer everywhere in the context, which would
     * turn an attribute's offset into a host address. */
    for (uint32_t index = 0; index < n; index++) {
        uint32_t name = rt_gl_load32(names + index * 4);
        if (name == 0) continue;
        if (c->array_buffer == name) c->array_buffer = 0;
        if (c->element_array_buffer == name) c->element_array_buffer = 0;
        for (uint32_t attrib = 0; attrib < RT_GL_MAX_VERTEX_ATTRIBS; attrib++) {
            if (c->attrib_buffer[attrib] == name) c->attrib_buffer[attrib] = 0;
        }
    }
}

void rt_gl_glEnableVertexAttribArray(rt_gl_context *c, uint32_t index) {
    c->skip = 0;
    if (c->trapped) return;
    if (index >= RT_GL_MAX_VERTEX_ATTRIBS) {
        rt_gl_fail(c, GL_INVALID_VALUE);
        return;
    }
    RT_GL(glEnableVertexAttribArray)((GLuint)index);
    c->attrib_enabled[index] = 1;
}

void rt_gl_glDisableVertexAttribArray(rt_gl_context *c, uint32_t index) {
    c->skip = 0;
    if (c->trapped) return;
    if (index >= RT_GL_MAX_VERTEX_ATTRIBS) {
        rt_gl_fail(c, GL_INVALID_VALUE);
        return;
    }
    RT_GL(glDisableVertexAttribArray)((GLuint)index);
    c->attrib_enabled[index] = 0;
}

void rt_gl_glVertexAttribPointer(rt_gl_context *c, uint32_t index, uint32_t size, uint32_t type, uint32_t normalized,
                                 uint32_t stride, uint32_t pointer) {
    c->skip = 0;
    if (c->trapped) return;
    if (index >= RT_GL_MAX_VERTEX_ATTRIBS) {
        rt_gl_fail(c, GL_INVALID_VALUE);
        return;
    }
    if (c->array_buffer == 0) {
        /* No client-side arrays: without a buffer, `pointer` would be a
         * host address. */
        rt_gl_fail(c, GL_INVALID_OPERATION);
        return;
    }
    RT_GL(glVertexAttribPointer)((GLuint)index, (GLint)size, (GLenum)type, (GLboolean)normalized, (GLsizei)stride,
                                 (const void *)(uintptr_t)pointer);
    c->attrib_buffer[index] = c->array_buffer;
}

/* Whether every enabled attribute reads from a buffer. */
static int rt_gl_attributes_ready(rt_gl_context *c) {
    for (uint32_t index = 0; index < RT_GL_MAX_VERTEX_ATTRIBS; index++) {
        if (c->attrib_enabled[index] && c->attrib_buffer[index] == 0) {
            rt_gl_fail(c, GL_INVALID_OPERATION);
            return 0;
        }
    }
    return 1;
}

void rt_gl_glDrawArrays(rt_gl_context *c, uint32_t mode, uint32_t first, uint32_t count) {
    c->skip = 0;
    if (c->trapped || !rt_gl_attributes_ready(c)) return;
    RT_GL(glDrawArrays)((GLenum)mode, (GLint)first, (GLsizei)count);
}

void rt_gl_glDrawElements(rt_gl_context *c, uint32_t mode, uint32_t count, uint32_t type, uint32_t indices) {
    c->skip = 0;
    if (c->trapped || !rt_gl_attributes_ready(c)) return;
    if (c->element_array_buffer == 0) {
        rt_gl_fail(c, GL_INVALID_OPERATION);
        return;
    }
    RT_GL(glDrawElements)((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(uintptr_t)indices);
}

uint32_t rt_gl_glGetError(rt_gl_context *c) {
    if (c->trapped) return 0;
    if (c->error != GL_NO_ERROR) {
        uint32_t error = c->error;
        c->error = GL_NO_ERROR;
        return error;
    }
    return (uint32_t)RT_GL(glGetError)();
}

void rt_gl_glPixelStorei(rt_gl_context *c, uint32_t pname, uint32_t param) {
    if (c->trapped) return;
    RT_GL(glPixelStorei)((GLenum)pname, (GLint)param);
    if (param == 1 || param == 2 || param == 4 || param == 8) {
        if (pname == GL_PACK_ALIGNMENT) {
            c->pack_alignment = (int32_t)param;
        } else if (pname == GL_UNPACK_ALIGNMENT) {
            c->unpack_alignment = (int32_t)param;
        }
    }
}

void rt_gl_glGetBooleanv(rt_gl_context *c, uint32_t pname, uint32_t params) {
    RT_GL_GET(glGetBooleanv, 1);
}

void rt_gl_glGetFloatv(rt_gl_context *c, uint32_t pname, uint32_t params) {
    RT_GL_GET(glGetFloatv, 4);
}

void rt_gl_glGetIntegerv(rt_gl_context *c, uint32_t pname, uint32_t params) {
    RT_GL_GET(glGetIntegerv, 4);
}

void rt_gl_glGetVertexAttribPointerv(rt_gl_context *c, uint32_t index, uint32_t pname, uint32_t pointer) {
    c->skip = 0;
    uint8_t *result = rt_gl_pointer(c, pointer, 4, 0);
    if (c->trapped || c->skip) return;
    /* A pointer is an offset into the attribute's buffer: 32 bits here. */
    void *value = NULL;
    RT_GL(glGetVertexAttribPointerv)((GLuint)index, (GLenum)pname, &value);
    uint32_t offset = (uint32_t)(uintptr_t)value;
    memcpy(result, &offset, sizeof(offset));
}

void rt_gl_glShaderSource(rt_gl_context *c, uint32_t shader, uint32_t count, uint32_t string, uint32_t length) {
    c->skip = 0;
    const uint8_t *offsets = rt_gl_pointer(c, string, (int64_t)(int32_t)count * 4, 0);
    const uint8_t *lengths = rt_gl_pointer(c, length, (int64_t)(int32_t)count * 4, 1);
    if (c->trapped || c->skip) return;
    /* The guest's array holds offsets: GL gets host pointers, and a length
     * for each, so it never looks for a terminator itself. */
    const GLchar **strings = malloc(((size_t)count + 1) * sizeof(*strings));
    GLint *sizes = malloc(((size_t)count + 1) * sizeof(*sizes));
    if (!strings || !sizes) {
        rt_gl_fail(c, GL_OUT_OF_MEMORY);
    }
    for (uint32_t index = 0; index < count && !c->trapped && !c->skip; index++) {
        uint32_t offset = rt_gl_load32(offsets + index * 4);
        int32_t given = lengths ? (int32_t)rt_gl_load32(lengths + index * 4) : -1;
        if (given < 0) {
            size_t measured = 0;
            strings[index] = rt_gl_string(c, offset, &measured);
            sizes[index] = (GLint)measured;
        } else {
            strings[index] = rt_gl_pointer(c, offset, given, 0);
            sizes[index] = given;
        }
    }
    if (!c->trapped && !c->skip) {
        RT_GL(glShaderSource)((GLuint)shader, (GLsizei)count, strings, sizes);
    }
    free(strings);
    free(sizes);
}

/* ------------------------------------------------------------------------- */
/* Generated from the table                                                   */
/* ------------------------------------------------------------------------- */
"""


def cast(parameter):
    """A wasm argument as the C type GL takes."""
    name = parameter.name
    kind = parameter.type
    if parameter.is_float:
        return name
    if kind in ("GLintptr", "GLsizeiptr"):
        return f"({kind})(int32_t){name}"
    return f"({kind}){name}"


def size_expression(function, expression):
    """A size, with each parameter widened to 64 bits by its signedness."""
    for parameter in function.parameters:
        if parameter.pointer:
            continue
        signed = TYPES[parameter.type][1]
        widened = f"(int64_t)(int32_t){parameter.name}" if signed else f"(int64_t){parameter.name}"
        expression = re.sub(rf"\b{parameter.name}\b", widened, expression)
    return expression


def shim_function(function):
    lines = [f"{shim_result(function)} rt_gl_{function.name}({shim_parameters(function)}) {{\n"]
    zero = "" if function.result == "void" else " 0"
    lines.append("    c->skip = 0;\n")
    arguments, scratch = [], False
    for parameter in function.parameters:
        if not parameter.pointer:
            arguments.append(cast(parameter))
            continue
        local = f"{parameter.name}_"
        arguments.append(local)
        if parameter.use == "str":
            lines.append(f"    const char *{local} = rt_gl_string(c, {parameter.name}, NULL);\n")
        elif parameter.use == "max":
            scratch = True
            lines.append(f"    void *{local} = rt_gl_scratch_begin(c, {parameter.name}, {parameter.size});\n")
        else:
            size = size_expression(function, parameter.size)
            lines.append(f"    void *{local} = rt_gl_pointer(c, {parameter.name}, {size}, {int(parameter.nullable)});\n")
    lines.append(f"    if (c->trapped || c->skip) return{zero};\n")
    call = f"RT_GL({function.name})({', '.join(arguments)})"
    if function.result == "void":
        lines.append(f"    {call};\n")
        if scratch:
            lines.append("    rt_gl_scratch_end(c);\n")
    else:
        lines.append(f"    return (uint32_t){call};\n")
    lines.append("}\n\n")
    return "".join(lines)


def slot(parameter, index):
    """An argument out of rt_gl_call's slots."""
    if parameter.is_float:
        return f"rt_gl_float(a[{index}])"
    return f"(uint32_t)a[{index}]"


def shim_source():
    table = [f for f in functions() if not f.returns_pointer]
    lines = [SHIM_PRELUDE, "\n"]
    for function in table:
        if not function.custom:
            lines.append(shim_function(function))

    lines.append("/* ------------------------------------------------------------------------- */\n"
                 "/* The imports, by index                                                      */\n"
                 "/* ------------------------------------------------------------------------- */\n\n")
    lines.append("static const rt_gl_function rt_gl_functions[] = {\n")
    for function in table:
        lines.append(f'    {{"{function.name}", "{function.wasm_parameters}", \'{function.wasm_result}\'}},\n')
    lines.append("};\n\n"
                 "uint32_t rt_gl_function_count(void) {\n"
                 "    return (uint32_t)(sizeof(rt_gl_functions) / sizeof(rt_gl_functions[0]));\n"
                 "}\n\n"
                 "const rt_gl_function *rt_gl_function_at(uint32_t index) {\n"
                 "    return index < rt_gl_function_count() ? &rt_gl_functions[index] : NULL;\n"
                 "}\n\n"
                 "static float rt_gl_float(uint64_t slot) {\n"
                 "    uint32_t bits = (uint32_t)slot;\n"
                 "    float value;\n"
                 "    memcpy(&value, &bits, sizeof(value));\n"
                 "    return value;\n"
                 "}\n\n"
                 "uint64_t rt_gl_call(rt_gl_context *c, uint32_t index, const uint64_t *a) {\n"
                 "    switch (index) {\n")
    for index, function in enumerate(table):
        arguments = ", ".join(["c"] + [slot(p, i) for i, p in enumerate(function.parameters)])
        call = f"rt_gl_{function.name}({arguments})"
        if function.result == "void":
            lines.append(f"    case {index}: {call}; return 0;\n")
        else:
            lines.append(f"    case {index}: return {call};\n")
    lines.append("    default: c->trapped = 1; return 0;\n"
                 "    }\n"
                 "}\n\n"
                 "#ifndef RT_GL_DIRECT\n"
                 "uint32_t rt_gl_api_load(rt_gl_api *api, rt_gl_lookup lookup, void *user) {\n"
                 "    uint32_t missing = 0;\n"
                 "    /* A data pointer to a function pointer, as dlsym's callers do. */\n")
    for function in functions():
        lines.append(f'    *(void **)&api->{function.name} = lookup("{function.name}", user);\n'
                     f"    missing += api->{function.name} == NULL;\n")
    lines.append("    return missing;\n"
                 "}\n"
                 "#endif\n")
    return "".join(lines)


# ---------------------------------------------------------------------------
# fake_gl.c
# ---------------------------------------------------------------------------

FAKE_HEADER_TEXT = GENERATED + r"""
/*
 * fake_gl.h: a GL that draws nothing and writes down what it's asked.
 *
 * It defines every function of gles2.h, as a GL library does, so an app's
 * library links against it: a native slice, or wasm2c output with the GL
 * shim. Shaders always compile, programs always link, and names count up
 * from 100.
 */
#ifndef FAKE_GL_H
#define FAKE_GL_H

#include <stdint.h>

/* One line per call since the last reset: "glViewport(0, 0, 640, 480)".
 * Enums are in hex. A pointer is "*", or "null"; a string is quoted; an
 * attribute's or index buffer's offset is a number. */
const char *fake_gl_log(void);

/* Clears the log. Names keep counting. */
void fake_gl_reset(void);

/* A new GL context: rt_gl_context_generation's answer changes. */
void fake_gl_new_context(void);

#endif /* FAKE_GL_H */
"""

FAKE_PRELUDE = GENERATED + r"""
#include "fake_gl.h"

#include <stdarg.h>
#include <stdio.h>

#include "gles2.h"

static char fake_gl_text[65536];
static size_t fake_gl_length;
static GLuint fake_gl_name = 100;

static uint32_t fake_gl_generation;

/* A wasm2c slice that draws asks its host for this (gl_shim.h). */
uint32_t rt_gl_context_generation(void) {
    return fake_gl_generation;
}

void fake_gl_new_context(void) {
    fake_gl_generation++;
}

const char *fake_gl_log(void) {
    return fake_gl_text;
}

void fake_gl_reset(void) {
    fake_gl_length = 0;
    fake_gl_text[0] = 0;
}

static void fake_gl_record(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    size_t room = sizeof(fake_gl_text) - fake_gl_length;
    int written = vsnprintf(fake_gl_text + fake_gl_length, room, format, arguments);
    va_end(arguments);
    if (written > 0 && (size_t)written + 1 < room) {
        fake_gl_length += (size_t)written;
        fake_gl_text[fake_gl_length++] = '\n';
        fake_gl_text[fake_gl_length] = 0;
    }
}

static const char *fake_gl_mark(const void *pointer) {
    return pointer ? "*" : "null";
}

"""

# What a function does besides writing itself down.
FAKE_BODIES = {
    "glCreateShader": "return fake_gl_name++;",
    "glCreateProgram": "return fake_gl_name++;",
    "glGenBuffers": "for (GLsizei i = 0; i < n; i++) buffers[i] = fake_gl_name++;",
    "glGenFramebuffers": "for (GLsizei i = 0; i < n; i++) framebuffers[i] = fake_gl_name++;",
    "glGenRenderbuffers": "for (GLsizei i = 0; i < n; i++) renderbuffers[i] = fake_gl_name++;",
    "glGenTextures": "for (GLsizei i = 0; i < n; i++) textures[i] = fake_gl_name++;",
    # GL_COMPILE_STATUS, GL_LINK_STATUS and the rest: yes.
    "glGetShaderiv": "*params = 1;",
    "glGetProgramiv": "*params = 1;",
    "glGetUniformLocation": "return 3;",
    "glGetString": 'return (const GLubyte *)"FakeGL";',
    "glCheckFramebufferStatus": "return 0x8CD5; /* GL_FRAMEBUFFER_COMPLETE */",
}

# Pointer parameters that are offsets into a buffer (§8.1).
FAKE_OFFSETS = {("glVertexAttribPointer", "pointer"), ("glDrawElements", "indices")}


def fake_function(function):
    formats, arguments = [], []
    for parameter in function.parameters:
        name = parameter.name
        if (function.name, name) in FAKE_OFFSETS:
            formats.append("%lu")
            arguments.append(f"(unsigned long)(uintptr_t){name}")
        elif parameter.use == "str":
            formats.append('\\"%s\\"')
            arguments.append(name)
        elif parameter.pointer:
            formats.append("%s")
            arguments.append(f"fake_gl_mark({name})")
        elif parameter.is_float:
            formats.append("%g")
            arguments.append(f"(double){name}")
        elif parameter.type in ("GLenum", "GLbitfield"):
            formats.append("0x%04X")
            arguments.append(f"(unsigned){name}")
        elif parameter.type in ("GLintptr", "GLsizeiptr"):
            formats.append("%ld")
            arguments.append(f"(long){name}")
        elif TYPES[parameter.type][1]:
            formats.append("%d")
            arguments.append(f"(int){name}")
        else:
            formats.append("%u")
            arguments.append(f"(unsigned){name}")
    record = ", ".join([f'"{function.name}({", ".join(formats)})"'] + arguments)
    body = FAKE_BODIES.get(function.name)
    if body is None and function.result != "void":
        body = "return 0;"
    lines = [f"{function.prototype} {{", f"    fake_gl_record({record});"]
    if body:
        lines.append(f"    {body}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def fake_source():
    return FAKE_PRELUDE + "\n".join(fake_function(function) for function in functions())


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def outputs():
    return {GUEST_HEADER: guest_header(), SHIM_HEADER: shim_header(), SHIM_SOURCE: shim_source(),
            FAKE_HEADER: FAKE_HEADER_TEXT, FAKE_SOURCE: fake_source()}


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else None
    if command not in ("generate", "check"):
        sys.exit(__doc__)
    try:
        stale = []
        for path, text in outputs().items():
            if command == "generate":
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
                print(path.relative_to(ROOT))
            elif not path.exists() or path.read_text() != text:
                stale.append(str(path.relative_to(ROOT)))
        if stale:
            sys.exit("out of date (run Scripts/gles2.py generate): " + ", ".join(stale))
    except TableError as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
