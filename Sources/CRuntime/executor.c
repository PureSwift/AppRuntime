/*
 * executor.c — the executor hooks of the Embedded concurrency runtime
 * (swift/ExecutorImpl.h), for DynamicRuntime's GuestExecutor (§5.4).
 *
 * The runtime leaves these undefined for the platform to provide. They are
 * written in C, with the Swift calling convention, rather than as Swift
 * @_silgen_name functions: a Swift declaration of one is serialized into
 * DynamicRuntime's module, and every module that imports it then fails to
 * build without optimization ("linkage mismatch"). Same approach as
 * Swift-iOS6's Executor.c.
 *
 * Jobs go to the guest's queue in Swift (rt_executor_enqueue, defined by
 * GuestExecutor), which runs them before control returns to the host.
 * Delayed jobs go through the Clock contract. Every job runs on the generic
 * executor, which also stands for the main actor.
 *
 * Embedded guest builds only: host builds use Swift's own executor, and
 * guests built without concurrency don't link the runtime.
 *
 * Freestanding: only <stdbool.h> and <stdint.h>.
 */
#if defined(__EMBEDDED_SWIFT__) && !defined(EMBEDDED_NO_CONCURRENCY)

#include <stdbool.h>
#include <stdint.h>

#define SWIFT_CC __attribute__((swiftcall))

typedef struct SwiftJob SwiftJob;

typedef struct {
    void *identity;
    uintptr_t implementation;
} SwiftExecutorRef;

/* GuestExecutor (Swift, @c). */
void rt_executor_enqueue(SwiftJob *job);
void rt_executor_enqueue_after(uint64_t nanoseconds, SwiftJob *job);

static const SwiftExecutorRef generic_executor = { 0, 0 };

SWIFT_CC void swift_task_enqueueGlobalImpl(SwiftJob *job) {
    rt_executor_enqueue(job);
}

SWIFT_CC void swift_task_enqueueMainExecutorImpl(SwiftJob *job) {
    rt_executor_enqueue(job);
}

SWIFT_CC void swift_task_enqueueGlobalWithDelayImpl(unsigned long long delay, SwiftJob *job) {
    rt_executor_enqueue_after(delay, job);
}

SWIFT_CC void swift_task_enqueueGlobalWithDeadlineImpl(long long seconds, long long nanoseconds,
                                                      long long tolerance_seconds, long long tolerance_nanoseconds,
                                                      int clock, SwiftJob *job) {
    /* Embedded Swift has no clocks to set a deadline with. */
    (void)seconds;
    (void)nanoseconds;
    (void)tolerance_seconds;
    (void)tolerance_nanoseconds;
    (void)clock;
    rt_executor_enqueue(job);
}

SWIFT_CC SwiftExecutorRef swift_task_getMainExecutorImpl(void) {
    return generic_executor;
}

/* Guests have no async main: the host owns the run loop. */
__attribute__((noreturn)) SWIFT_CC void swift_task_asyncMainDrainQueueImpl(void) {
    __builtin_trap();
}

/* The guest can't block the host's thread. */
SWIFT_CC void swift_task_donateThreadToGlobalExecutorUntilImpl(bool (*condition)(void *), void *context) {
    (void)condition;
    (void)context;
    __builtin_trap();
}

/* The wasm32 runtime defines these three; the native runtimes don't. */
#if !defined(__wasm__)
SWIFT_CC bool swift_task_isMainExecutorImpl(SwiftExecutorRef executor) {
    return executor.identity == 0;
}

/* Every job runs on the generic executor; custom executors aren't
 * supported in a guest. */
SWIFT_CC void swift_task_checkIsolatedImpl(SwiftExecutorRef executor) {
    if (executor.identity != 0) {
        __builtin_trap();
    }
}

/* 1: isolated; -1: unknown, so the runtime falls back to checkIsolated. */
SWIFT_CC int8_t swift_task_isIsolatingCurrentContextImpl(SwiftExecutorRef executor) {
    return executor.identity == 0 ? 1 : -1;
}
#endif

#endif
