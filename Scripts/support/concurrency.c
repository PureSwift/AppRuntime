/*
 * Support for the Embedded concurrency runtime, sealed into every native
 * slice that links it. guest.py localizes these when it seals the slice.
 *
 * The prebuilt runtime references a little libc outside the §7.5 set, all of
 * it on paths a guest never takes: fatal-error printing, and the sleeping and
 * time queries of the cooperative executor that DynamicRuntime's guest
 * executor replaces (§5.4). It also references Swift functions that only a
 * final, dead-stripping link removes; a sealed slice is a relocatable object,
 * which Mach-O can't dead-strip. Messages go to stderr through write(), which
 * is in the allowed set; everything else stops.
 *
 * The bare-metal runtimes use Darwin's spellings (__error, __stderrp) on
 * every triple, and the ELF ones call _fputs and _nanosleep.
 *
 * Every definition is weak, so a slice's own support code (ios6-compat.c
 * defines memset_s and __cxa_pure_virtual) takes precedence.
 *
 * Freestanding: only <stddef.h> and <stdarg.h>.
 */
#include <stdarg.h>
#include <stddef.h>

#define WEAK __attribute__((weak))

long write(int fd, const void *buffer, size_t count);
__attribute__((noreturn)) void abort(void);

static void write_string(const char *string) {
    size_t length = 0;
    while (string[length] != 0) {
        length++;
    }
    write(2, string, length);
}

/* MARK: libc */

WEAK size_t strlen(const char *string) {
    size_t length = 0;
    while (string[length] != 0) {
        length++;
    }
    return length;
}

WEAK char *strncpy(char *destination, const char *source, size_t count) {
    size_t i = 0;
    for (; i < count && source[i] != 0; i++) {
        destination[i] = source[i];
    }
    for (; i < count; i++) {
        destination[i] = 0;
    }
    return destination;
}

/* C11 Annex K. The runtime clears task memory with it. Writes through a
 * volatile pointer so the stores stay. */
WEAK int memset_s(void *s, size_t smax, int c, size_t n) {
    if (s == NULL) {
        return 22; /* EINVAL */
    }
    volatile unsigned char *p = s;
    size_t count = n < smax ? n : smax;
    for (size_t i = 0; i < count; i++) {
        p[i] = (unsigned char)c;
    }
    return n > smax ? 84 : 0; /* EOVERFLOW */
}

/* Fatal-error output. Formatting isn't supported: the format string is
 * written as is, which still says what went wrong. */
WEAK int vsnprintf(char *buffer, size_t size, const char *format, va_list arguments) {
    (void)arguments;
    size_t length = strlen(format);
    if (size > 0) {
        size_t count = length < size - 1 ? length : size - 1;
        for (size_t i = 0; i < count; i++) {
            buffer[i] = format[i];
        }
        buffer[count] = 0;
    }
    return (int)length;
}

WEAK int vprintf(const char *format, va_list arguments) {
    (void)arguments;
    write_string(format);
    return (int)strlen(format);
}

WEAK int puts(const char *string) {
    write_string(string);
    write(2, "\n", 1);
    return 0;
}

WEAK int fputs(const char *string, void *stream) {
    (void)stream;
    write_string(string);
    return 0;
}

WEAK int _fputs(const char *string, void *stream) {
    return fputs(string, stream);
}

WEAK int fflush(void *stream) {
    (void)stream;
    return 0;
}

/* The runtime only writes to stderr; the stream is never dereferenced. */
WEAK void *__stderrp = NULL;

static int error_number;

WEAK int *__error(void) {
    return &error_number;
}

WEAK void exit(int status) {
    (void)status;
    abort();
}

/* The cooperative executor's sleep and clock: replaced by the guest
 * executor, which never blocks the host's thread. */
WEAK int nanosleep(const void *duration, void *remaining) {
    (void)duration;
    (void)remaining;
    abort();
}

WEAK int _nanosleep(const void *duration, void *remaining) {
    return nanosleep(duration, remaining);
}

WEAK int clock_getres(int clock, void *resolution) {
    (void)clock;
    (void)resolution;
    return -1;
}

/* Calling a pure virtual function is a bug: stop. */
WEAK void __cxa_pure_virtual(void) {
    __builtin_trap();
}

/* MARK: Swift runtime */

/* An Embedded Swift object starts with its metadata pointer. */
WEAK const void *swift_getObjectType(const void *object) {
    return *(const void *const *)object;
}

WEAK void swift_reportError(unsigned flags, const char *message) {
    (void)flags;
    write_string(message);
}

/* Unreachable with the guest executor: custom executors, task executor
 * preferences and resilient class metadata don't exist in a guest. */
#define UNREACHABLE(name) WEAK void name(void) { __builtin_trap(); }

UNREACHABLE(swift_getMainExecutor)
UNREACHABLE(_task_serialExecutor_checkIsolated)
UNREACHABLE(_task_serialExecutor_getExecutorRef)
UNREACHABLE(_task_serialExecutor_isIsolatingCurrentContext)
UNREACHABLE(_task_taskExecutor_getTaskExecutorRef)

/* swift::getResilientMetadataBounds(const ClassDescriptor *) */
#if defined(__APPLE__)
#  define CXX_NAME(name) __asm__("_" name)
#else
#  define CXX_NAME(name) __asm__(name)
#endif
WEAK void rt_getResilientMetadataBounds(void)
    CXX_NAME("_ZN5swift26getResilientMetadataBoundsEPKNS_21TargetClassDescriptorINS_9InProcessEEE");
WEAK void rt_getResilientMetadataBounds(void) {
    __builtin_trap();
}
