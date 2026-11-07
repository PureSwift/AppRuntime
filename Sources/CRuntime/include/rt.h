/*
 * rt.h — portable dynamic-runtime ABI between a wasm32 guest and a native host.
 *
 * The intersection of the Objective-C runtime, JNI, and a plain C host (SDL3).
 * Anything not present in all three is excluded from the core.
 *
 * Backends:
 *   ObjC  — objc_getClass / sel_registerName / objc_msgSend(_stret) via libffi
 *   JNI   — FindClass / Get(Static)MethodID / Call<T>MethodA / NewObjectA
 *   C     — host-side registry of functions and handle-wrapped pointers
 */
#ifndef RT_H
#define RT_H

#include <stdint.h>
#include <stddef.h>

/*
 * One header, two linkages. App source is identical in both.
 *
 *   wasm32:  rt_* are imports from module "rt", provided by the host's wasm
 *            shim, which converts guest offsets to native pointers and calls
 *            the same runtime core. rt_dispatch / rt_finalize are exports.
 *
 *   native:  rt_* are ordinary C symbols exported by the runtime library
 *            (static lib, RT.framework, librt.so). rt_dispatch / rt_finalize
 *            are ordinary symbols defined by the app and called by the runtime.
 *
 * Handles, wire slots and every rule below are the same in both modes.
 * Neither form is an executable: a wasm slice is a WASI reactor module, a
 * native slice is a sealed static library. The host links or loads it.
 */
#if defined(__wasm__)
#  define RT_IMPORT(name) __attribute__((import_module("rt"), import_name(#name)))
#  define RT_EXPORT(name) __attribute__((export_name(#name)))
#else
#  define RT_IMPORT(name) extern __attribute__((visibility("default")))
#  define RT_EXPORT(name) __attribute__((visibility("default")))
#endif

/* ------------------------------------------------------------------------- */
/* Values                                                                     */
/* ------------------------------------------------------------------------- */

/* Opaque, refcounted reference to a host object. 0 is null.
 * Handles are NOT guaranteed unique per object (JNI has no stable identity
 * key); compare objects with rt_same(). */
typedef uint32_t rt_obj;

/* Resolved class / method identifiers. Never released. 0 is invalid. */
typedef uint32_t rt_class_id;
typedef uint32_t rt_method_id;

/* One wire slot per scalar. f32 is stored as its bit pattern in the low 32
 * bits, bool as 0/1, rt_obj in the low 32 bits. */
typedef uint64_t rt_slot;

/*
 * Wire signature grammar (portable, used only for marshaling):
 *
 *   sig    := '(' arg* ')' ret
 *   arg    := 'Z' | 'I' | 'J' | 'F' | 'D' | 'O'
 *   ret    := arg | 'V'
 *
 *   Z bool   I int32   J int64   F float32   D float64   O object (nullable)
 *
 * No unsigned, no 8/16-bit, no pointers, no structs, no varargs.
 * The host narrows/widens to the native type (e.g. I -> BOOL/char/short,
 * J -> NSInteger on armv7, D -> CGFloat on armv7) using the native signature
 * it reads at runtime (method_getTypeEncoding, JNI descriptor, C table).
 *
 * Native structs (CGRect, CGSize, ...) are flattened: one slot per scalar
 * field, in declaration order. Backends without structs never see them.
 */

/* Status codes returned by every fallible call. */
typedef enum {
    RT_OK            = 0,
    RT_ERR_NOT_FOUND = 1,   /* class or method missing on this platform/OS */
    RT_ERR_SIGNATURE = 2,   /* wire sig does not fit the native signature */
    RT_ERR_THROWN    = 3,   /* NSException / Throwable / C error; see rt_error */
    RT_ERR_NULL      = 4,   /* message to null where the backend forbids it */
} rt_status;

/* Method lookup flags. */
enum {
    RT_METHOD_INSTANCE = 0,
    RT_METHOD_STATIC   = 1,  /* ObjC class method, Java static, C function */
    RT_METHOD_CTOR     = 2,  /* ObjC alloc+init…, Java <init>, C constructor */
};

/* ------------------------------------------------------------------------- */
/* Imports (host -> guest)                                                    */
/* ------------------------------------------------------------------------- */

/* Look up a class. Two kinds of name, resolved in this order:
 *
 *   1. Contract name (portable, reverse-DNS), e.g.
 *        "org.pureswift.bluetooth.Central"
 *      Declared once in Swift; the host's registry maps it to whichever
 *      implementation this platform provides (Java class, ObjC class,
 *      Swift type, or C function table).
 *
 *   2. Native name (platform bindings only), e.g.
 *        ObjC "UIView"   JNI "android/view/View"   C "SDL_Window" */
RT_IMPORT(class)
rt_class_id rt_class(const char *name, size_t len);

/* Look up a method.
 *   Contract classes: `name` is the portable selector-style key derived from
 *     the Swift declaration ("connect:timeout:"). Contracts forbid overloads,
 *     so name + arity is unique; each backend maps it (Java method "connect",
 *     ObjC "-connect:timeout:error:", Swift registry entry).
 *   Native classes: `name` is the native key, opaque to the core:
 *     ObjC "setTitle:forState:"
 *     JNI  "setText(Ljava/lang/CharSequence;)V"
 *     C    "SDL_CreateWindow"
 * `sig` is the portable wire signature used for marshaling. */
RT_IMPORT(method)
rt_method_id rt_method(rt_class_id cls,
                       const char *name, size_t name_len,
                       const char *sig,  size_t sig_len,
                       uint32_t flags);

/* Invoke a method.
 *   INSTANCE: target = receiver
 *   STATIC:   target ignored (pass 0)
 *   CTOR:     target ignored; ret[0] receives a new +1 rt_obj
 * Returned objects are always +1; the guest must rt_release them. */
RT_IMPORT(call)
rt_status rt_call(rt_obj target, rt_method_id method,
                  const rt_slot *args, uint32_t nargs,
                  rt_slot *ret, uint32_t nret);

/* Reference counting. Backed by retain/release (ObjC), global refs (JNI),
 * or a host refcount + destroy function (C). */
RT_IMPORT(retain)  void rt_retain(rt_obj obj);
RT_IMPORT(release) void rt_release(rt_obj obj);

/* Identity and type tests. */
RT_IMPORT(same)        int32_t rt_same(rt_obj a, rt_obj b);
RT_IMPORT(is_instance) int32_t rt_is_instance(rt_obj obj, rt_class_id cls);

/* Strings: NSString / java.lang.String / host UTF-8 buffer. +1 result.
 * rt_string_utf8 returns the full UTF-8 length; copies at most `cap` bytes. */
RT_IMPORT(string_new)  rt_obj rt_string_new(const char *utf8, size_t len);
RT_IMPORT(string_utf8) size_t rt_string_utf8(rt_obj str, char *buf, size_t cap);

/* Bytes: NSData / byte[] / host buffer. Same copy semantics as strings.
 * The host never retains pointers into guest memory. */
RT_IMPORT(bytes_new)  rt_obj rt_bytes_new(const void *ptr, size_t len);
RT_IMPORT(bytes_read) size_t rt_bytes_read(rt_obj bytes, void *buf, size_t cap);

/* Callbacks: implement one or more interfaces/protocols with guest functions.
 *   ObjC: runtime class conforming to the protocols, IMPs forward to rt_dispatch
 *   JNI:  java.lang.reflect.Proxy over the interfaces
 *   C:    host callback set (function pointer + userdata)
 * Subclassing concrete classes is NOT in the core (JNI cannot do it at runtime).
 * `context` is passed back to rt_dispatch and rt_finalize. Returns +1. */
typedef struct {
    const char *name;  size_t name_len;  /* native lookup key, as in rt_method */
    const char *sig;   size_t sig_len;   /* wire signature */
} rt_method_decl;

RT_IMPORT(implement)
rt_obj rt_implement(const rt_class_id *interfaces, uint32_t ninterfaces,
                    const rt_method_decl *methods, uint32_t nmethods,
                    uint32_t context);

/* Last error on this thread after RT_ERR_THROWN; clears it.
 * Returns full UTF-8 length of the message; copies at most `cap` bytes. */
RT_IMPORT(error_message)
size_t rt_error_message(char *buf, size_t cap);

/* ------------------------------------------------------------------------- */
/* Exports (guest -> host)                                                    */
/* ------------------------------------------------------------------------- */

/* Entry point. The host owns main() and the run loop; it calls rt_main once
 * after loading the app (after _initialize for a wasm reactor module). The app
 * sets itself up (creates contracts, a renderer, delegates) and returns.
 * Everything afterward arrives through rt_dispatch. */
RT_EXPORT(rt_main)
rt_status rt_main(void);

/* Called when a native caller invokes a method created by rt_implement.
 * `index` is the position in the rt_method_decl array. Argument objects are
 * borrowed (+0); returned objects must be +1. */
RT_EXPORT(rt_dispatch)
rt_status rt_dispatch(uint32_t context, uint32_t index, rt_obj self,
                      const rt_slot *args, uint32_t nargs,
                      rt_slot *ret, uint32_t nret);

/* Called once when the native object created by rt_implement is destroyed
 * (dealloc / Proxy collected / host destroy). Free guest state for `context`. */
RT_EXPORT(rt_finalize)
void rt_finalize(uint32_t context);

/* ------------------------------------------------------------------------- */
/* Rules                                                                      */
/* ------------------------------------------------------------------------- */
/*
 * - Single-threaded: all calls in both directions happen on the UI/main thread.
 *   The host moves callbacks there before entering the guest.
 * - The host never stores pointers into guest linear memory past the call.
 * - Excluded from the core (not in all three runtimes): fields/ivars, weak refs,
 *   structs as values, unsigned/narrow ints, varargs, runtime subclassing of
 *   concrete classes, collections beyond bytes, autorelease pools (host-internal).
 *   Platform binding layers may add backend-specific imports on top.
 */

#endif /* RT_H */
