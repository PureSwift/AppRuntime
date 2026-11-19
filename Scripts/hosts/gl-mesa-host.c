/*
 * gl-mesa-host.c: a minimal C host that draws examples/ExampleGL on a real
 * GL and looks at the pixels. Scripts/test-gl-mesa.sh builds and runs it in
 * Docker, with Mesa's software renderer, against the example's Linux slice,
 * which it loads, and against its App.wasm translated by wasm2c, which is
 * compiled in.
 *
 * It has just enough of rt.h for the app to start: classes and methods get
 * numbers, constructors return handles, and it remembers the delegate the
 * app gives `Surface.make`. Then it makes an EGL pbuffer context and calls
 * the delegate's `resize` and `frame` through rt_dispatch, as a host does.
 *
 * The triangle points up at angle 0 and turns one radian a second, so pi
 * seconds later it points down. A context is then destroyed and made again,
 * and the app must draw in the new one.
 *
 * HOST_GENERATION: defines rt_gl_context_generation, which a wasm2c slice
 * that draws asks of its host (gl_shim.h), whether it's compiled in or a
 * libapp.so made from App.wasm.
 *
 * HOST_LOADS: the app isn't linked in. The host loads a Linux slice, the
 * libapp.so given as its first argument, as a runner does (DynamicRuntime.md
 * §7.6): the library names no other, and binds rt.h and GL to what this
 * process has. Build it with -rdynamic, so the process exports the rt.h it
 * defines.
 *
 * Usage: gl-mesa-host [libapp.so] [frame1.ppm [frame2.ppm]]
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rt.h"

#ifdef HOST_LOADS
#include <dlfcn.h>
static rt_status (*app_main)(void);
static rt_status (*app_dispatch)(uint32_t context, uint32_t index, rt_obj self,
                                 const rt_slot *args, uint32_t nargs, rt_slot *ret, uint32_t nret);
#define rt_main app_main
#define rt_dispatch app_dispatch
#endif

#define SIZE 256
#define MAX 256

static char class_names[MAX][96];
static uint32_t class_count = 1;
static struct { uint32_t cls; char key[96]; } methods[MAX];
static uint32_t method_count = 1;
static uint32_t next_handle = 100;

static uint32_t surface_class, surface_object, surface_delegate;
static uint32_t delegate_context, frame_index = ~0u, resize_index = ~0u, lost_index = ~0u, restored_index = ~0u;
static struct { uint32_t handle, context; } exported[MAX];
static uint32_t exported_count;

#ifdef HOST_GENERATION
static uint32_t generation;
uint32_t rt_gl_context_generation(void) { return generation; }
#endif

rt_class_id rt_class(const char *name, size_t len) {
    for (uint32_t i = 1; i < class_count; i++)
        if (strlen(class_names[i]) == len && memcmp(class_names[i], name, len) == 0) return i;
    snprintf(class_names[class_count], sizeof class_names[0], "%.*s", (int)len, name);
    if (strcmp(class_names[class_count], "org.pureswift.graphics.Surface") == 0) surface_class = class_count;
    printf("host: class %s\n", class_names[class_count]);
    return class_count++;
}

rt_method_id rt_method(rt_class_id cls, const char *name, size_t name_len, const char *sig, size_t sig_len, uint32_t flags) {
    methods[method_count].cls = cls;
    snprintf(methods[method_count].key, sizeof methods[0].key, "%.*s", (int)name_len, name);
    return method_count++;
}

rt_status rt_call(rt_obj target, rt_method_id method, const rt_slot *args, uint32_t nargs, rt_slot *ret, uint32_t nret) {
    const char *key = methods[method].key;
    for (uint32_t i = 0; i < nret; i++) ret[i] = 0;
    if (strncmp(key, "make", 4) == 0 && nret > 0) {
        ret[0] = next_handle++;
        if (methods[method].cls == surface_class) {
            surface_object = (uint32_t)ret[0];
            surface_delegate = (uint32_t)args[0];
        }
    } else if (strcmp(key, "identifier") == 0 && nret > 0) {
        ret[0] = 42;
    }
    return RT_OK;
}

void rt_retain(rt_obj obj) {}
void rt_release(rt_obj obj) {}
int32_t rt_same(rt_obj a, rt_obj b) { return a == b; }
int32_t rt_is_instance(rt_obj obj, rt_class_id cls) { return 0; }
rt_obj rt_string_new(const char *utf8, size_t len) { return next_handle++; }
size_t rt_string_utf8(rt_obj str, char *buf, size_t cap) { return 0; }
rt_obj rt_bytes_new(const void *ptr, size_t len) { return next_handle++; }
size_t rt_bytes_read(rt_obj bytes, void *buf, size_t cap) { return 0; }
size_t rt_error_message(char *buf, size_t cap) { return 0; }

rt_obj rt_implement(const rt_class_id *interfaces, uint32_t ninterfaces, const rt_method_decl *decls, uint32_t ndecls, uint32_t context) {
    uint32_t handle = next_handle++;
    exported[exported_count].handle = handle;
    exported[exported_count].context = context;
    exported_count++;
    for (uint32_t i = 0; i < ndecls; i++) {
        if (decls[i].name_len >= 16 && memcmp(decls[i].name, "frame:timestamp:", 16) == 0) { frame_index = i; delegate_context = context; }
        if (decls[i].name_len >= 13 && memcmp(decls[i].name, "resize:width:", 13) == 0) resize_index = i;
        if (decls[i].name_len == 12 && memcmp(decls[i].name, "contextLost:", 12) == 0) lost_index = i;
        if (decls[i].name_len == 16 && memcmp(decls[i].name, "contextRestored:", 16) == 0) restored_index = i;
    }
    return handle;
}

static rt_slot float_slot(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }

static void frame(int64_t timestamp) {
    rt_slot args[4] = { surface_object, (rt_slot)timestamp, SIZE, SIZE };
    rt_status status = rt_dispatch(delegate_context, frame_index, surface_delegate, args, 4, NULL, 0);
    if (status != RT_OK) { printf("FAIL frame returned %d\n", (int)status); exit(1); }
    glFinish();
}

static void pixel(int x, int y, unsigned char rgba[4]) {
    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
}

static int is_background(const unsigned char p[4]) {
    return abs(p[0] - 20) <= 2 && abs(p[1] - 20) <= 2 && abs(p[2] - 26) <= 2;
}

static void save(const char *path) {
    static unsigned char image[SIZE * SIZE * 4];
    glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, image);
    FILE *file = fopen(path, "wb");
    if (!file) return;
    fprintf(file, "P6\n%d %d\n255\n", SIZE, SIZE);
    for (int y = SIZE - 1; y >= 0; y--)
        for (int x = 0; x < SIZE; x++) fwrite(image + (y * SIZE + x) * 4, 1, 3, file);
    fclose(file);
}

#define CHECK(condition) if (!(condition)) { printf("FAIL %s\n", #condition); failures++; }

int main(int argc, char **argv) {
    int failures = 0;
#ifdef HOST_LOADS
    if (argc < 2) { printf("FAIL no libapp.so given\n"); return 1; }
    /* RTLD_LAZY: the library itself asks to bind everything now (-z now). */
    void *app = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (!app) { printf("FAIL %s\n", dlerror()); return 1; }
    app_main = dlsym(app, "rt_main");
    app_dispatch = dlsym(app, "rt_dispatch");
    if (!app_main || !app_dispatch || !dlsym(app, "rt_finalize")) { printf("FAIL %s\n", dlerror()); return 1; }
    printf("host: loaded %s\n", argv[1]);
    argv++, argc--;
#endif
    EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint major, minor;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) { printf("FAIL no EGL display (0x%x)\n", eglGetError()); return 1; }
    const EGLint config_attributes[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                         EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
    EGLConfig config; EGLint count;
    if (!eglChooseConfig(display, config_attributes, &config, 1, &count) || count < 1) { printf("FAIL no EGL config\n"); return 1; }
    const EGLint surface_attributes[] = { EGL_WIDTH, SIZE, EGL_HEIGHT, SIZE, EGL_NONE };
    EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attributes);
    const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT || !eglMakeCurrent(display, surface, surface, context)) {
        printf("FAIL no GL context (0x%x)\n", eglGetError()); return 1;
    }
    printf("host: %s | %s | %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_SHADING_LANGUAGE_VERSION));

    rt_status status = rt_main();
    printf("host: rt_main returned %d; surface %u, delegate %u, frame index %u\n", (int)status, surface_object, surface_delegate, frame_index);
    CHECK(status == RT_OK);
    CHECK(surface_object != 0 && frame_index != ~0u && resize_index != ~0u);
    if (failures) return 1;

    rt_slot resize_args[4] = { surface_object, SIZE, SIZE, float_slot(1.0f) };
    CHECK(rt_dispatch(delegate_context, resize_index, surface_delegate, resize_args, 4, NULL, 0) == RT_OK);

    unsigned char corner[4], middle[4], upper[4], lower[4];
    /* Frame 1: angle 0. The triangle points up: (0, 0.6) is inside it, (0, -0.6) below it. */
    frame(1000000000LL);
    CHECK(glGetError() == GL_NO_ERROR);
    pixel(2, 2, corner); pixel(SIZE / 2, SIZE / 2, middle);
    pixel(SIZE / 2, (int)(SIZE * 0.8), upper); pixel(SIZE / 2, (int)(SIZE * 0.2), lower);
    printf("host: frame 1: corner %d,%d,%d middle %d,%d,%d upper %d,%d,%d lower %d,%d,%d\n", corner[0], corner[1], corner[2],
           middle[0], middle[1], middle[2], upper[0], upper[1], upper[2], lower[0], lower[1], lower[2]);
    CHECK(is_background(corner));
    CHECK(!is_background(middle));
    CHECK(!is_background(upper) && upper[0] > upper[1] && upper[0] > upper[2]); /* near the red corner */
    CHECK(is_background(lower));
    if (argc > 1) save(argv[1]);

    /* Frame 2: pi seconds later, half a turn. The triangle points down. */
    frame(1000000000LL + 3141592654LL);
    pixel(SIZE / 2, (int)(SIZE * 0.8), upper); pixel(SIZE / 2, (int)(SIZE * 0.2), lower); pixel(SIZE / 2, SIZE / 2, middle);
    printf("host: frame 2: middle %d,%d,%d upper %d,%d,%d lower %d,%d,%d\n",
           middle[0], middle[1], middle[2], upper[0], upper[1], upper[2], lower[0], lower[1], lower[2]);
    CHECK(is_background(upper));
    CHECK(!is_background(lower) && lower[0] > lower[1] && lower[0] > lower[2]);
    CHECK(!is_background(middle));
    CHECK(glGetError() == GL_NO_ERROR);
    if (argc > 2) save(argv[2]);

    /* A lost context: a new one, and the guest makes its objects again. */
    if (lost_index != ~0u && restored_index != ~0u) {
        rt_slot only[1] = { surface_object };
        CHECK(rt_dispatch(delegate_context, lost_index, surface_delegate, only, 1, NULL, 0) == RT_OK);
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(display, context);
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
        CHECK(eglMakeCurrent(display, surface, surface, context));
#ifdef HOST_GENERATION
        generation++;
#endif
        CHECK(rt_dispatch(delegate_context, restored_index, surface_delegate, only, 1, NULL, 0) == RT_OK);
        frame(1000000000LL + 2 * 3141592654LL);
        pixel(SIZE / 2, (int)(SIZE * 0.8), upper); pixel(2, 2, corner);
        printf("host: after a new context: corner %d,%d,%d upper %d,%d,%d\n", corner[0], corner[1], corner[2], upper[0], upper[1], upper[2]);
        CHECK(is_background(corner));
        CHECK(!is_background(upper) && upper[0] > upper[1]);
        CHECK(glGetError() == GL_NO_ERROR);
    }
    printf(failures ? "FAILED\n" : "ok\n");
    return failures;
}
