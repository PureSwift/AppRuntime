import CRuntime
import RuntimeABI
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Runs the guest's async jobs (§5.4).
///
/// Embedded Swift's default executor drains its queue in a loop that never
/// returns, but the host owns the run loop and the guest runs only while the
/// host calls it. So the guest supplies the executor hooks itself: jobs are
/// queued inside the guest and run just before control returns to the host,
/// when `rt_main` (through `Runtime.main`), `rt_dispatch` or `rt_finalize`
/// returns. A call that re-enters the guest while a job runs (guest → host →
/// guest) doesn't drain, so jobs never interleave. Main actor and global
/// executor are the same queue.
///
/// Delayed jobs go through the `Clock` contract. Deadline jobs run at once:
/// Embedded Swift has no clocks to set a deadline with.
///
/// Outside Embedded Swift (host tests), Swift's own executor runs jobs, and
/// `enter` only runs its body.
public enum GuestExecutor {

    /// Runs `body` as a call from the host, then, if it's the outermost
    /// one, runs every queued job.
    public static func enter<R>(_ body: () -> R) -> R {
        #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
        depth += 1
        let result = body()
        depth -= 1
        drain()
        return result
        #else
        return body()
        #endif
    }

    /// Runs queued jobs, including ones they enqueue, until none are left.
    /// Does nothing inside a call from the host or another drain.
    public static func drain() {
        #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
        guard depth == 0 else { return }
        depth = 1
        while head < jobs.count {
            let job = jobs[head]
            head += 1
            job.runSynchronously(on: genericExecutor)
        }
        jobs.removeAll(keepingCapacity: true)
        head = 0
        depth = 0
        #endif
    }

    /// Jobs waiting to run.
    public static var pendingCount: Int {
        #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
        jobs.count - head
        #else
        0
        #endif
    }

    #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
    static func enqueue(_ job: UnownedJob) {
        jobs.append(job)
    }
    #endif
}

public extension Runtime {

    /// Runs the app's entry point. Call it from `rt_main`; tasks the body
    /// starts run until they first suspend before it returns to the host.
    ///
    /// ```swift
    /// @_expose(wasm, "rt_main")
    /// @c(rt_main)
    /// public func appMain() -> rt_status {
    ///     Runtime.main { App.start() }
    /// }
    /// ```
    static func main(_ body: () -> RuntimeStatus) -> rt_status {
        rt_status(rawValue: GuestExecutor.enter(body).rawValue)
    }
}

#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY

// Single-threaded by contract (§6.4).
nonisolated(unsafe) private var jobs: [UnownedJob] = []
nonisolated(unsafe) private var head = 0
/// Calls from the host (or drains) in progress.
nonisolated(unsafe) private var depth = 0

/// The one executor every job runs on: the generic executor, which also
/// stands for the main actor.
private var genericExecutor: UnownedSerialExecutor {
    unsafeBitCast((UInt(0), UInt(0)), to: UnownedSerialExecutor.self)
}

private func isGeneric(_ executor: UnownedSerialExecutor) -> Bool {
    unsafeBitCast(executor, to: (UInt, UInt).self).0 == 0
}

// MARK: - Executor hooks (swift/ExecutorImpl.h)
//
// The Embedded concurrency runtime leaves these undefined for the platform
// to provide. They use the Swift calling convention, which @_silgen_name
// functions have, and hidden visibility, which internal declarations have.
// Nothing in Swift calls them, so @used keeps them.

@_silgen_name("swift_task_enqueueGlobalImpl")
@used
func _rt_enqueueGlobal(_ job: UnownedJob) {
    GuestExecutor.enqueue(job)
}

@_silgen_name("swift_task_enqueueMainExecutorImpl")
@used
func _rt_enqueueMainExecutor(_ job: UnownedJob) {
    GuestExecutor.enqueue(job)
}

@_silgen_name("swift_task_enqueueGlobalWithDelayImpl")
@used
func _rt_enqueueGlobalWithDelay(_ delay: UInt64, _ job: UnownedJob) {
    do throws(RuntimeError) {
        try RuntimeClock.after(nanoseconds: Int64(clamping: delay)) {
            GuestExecutor.enqueue(job)
        }
    } catch {
        fatalError("Clock.after failed: \(error.message)")
    }
}

@_silgen_name("swift_task_enqueueGlobalWithDeadlineImpl")
@used
func _rt_enqueueGlobalWithDeadline(
    _ seconds: Int64,
    _ nanoseconds: Int64,
    _ toleranceSeconds: Int64,
    _ toleranceNanoseconds: Int64,
    _ clock: Int32,
    _ job: UnownedJob
) {
    GuestExecutor.enqueue(job)
}

@_silgen_name("swift_task_getMainExecutorImpl")
@used
func _rt_getMainExecutor() -> UnownedSerialExecutor {
    genericExecutor
}

@_silgen_name("swift_task_asyncMainDrainQueueImpl")
@used
func _rt_asyncMainDrainQueue() -> Never {
    fatalError("Guests have no async main: the host owns the run loop")
}

@_silgen_name("swift_task_donateThreadToGlobalExecutorUntilImpl")
@used
func _rt_donateThreadToGlobalExecutorUntil(
    _ condition: @convention(c) (UnsafeMutableRawPointer?) -> Bool,
    _ context: UnsafeMutableRawPointer?
) {
    fatalError("The guest can't block the host's thread")
}

// The wasm32 runtime defines these three; the native runtimes don't.
#if !arch(wasm32)
@_silgen_name("swift_task_isMainExecutorImpl")
@used
func _rt_isMainExecutor(_ executor: UnownedSerialExecutor) -> Bool {
    isGeneric(executor)
}

@_silgen_name("swift_task_checkIsolatedImpl")
@used
func _rt_checkIsolated(_ executor: UnownedSerialExecutor) {
    // Every job runs on the one generic executor.
    guard isGeneric(executor) else {
        fatalError("Custom executors aren't supported in a guest")
    }
}

@_silgen_name("swift_task_isIsolatingCurrentContextImpl")
@used
func _rt_isIsolatingCurrentContext(_ executor: UnownedSerialExecutor) -> Int8 {
    // 1: isolated; -1: unknown, so the runtime falls back to checkIsolated.
    isGeneric(executor) ? 1 : -1
}
#endif

#endif
