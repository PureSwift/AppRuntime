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
/// host calls it. So the guest supplies the executor hooks itself
/// (`CRuntime`'s `executor.c`, forwarding here): jobs are
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

    /// Runs `body` as a call from the host. When the outermost call
    /// returns, runs every queued job, then the `whenIdle` handlers (and
    /// the jobs those queue), so the host sees one consistent update.
    public static func enter<R>(_ body: () -> R) -> R {
        depth += 1
        let result = body()
        depth -= 1
        if depth == 0 {
            finishHostCall()
        }
        return result
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

    /// Runs `body` once, just before control returns to the host: after the
    /// current call from the host and its jobs finish. Outside a host call it
    /// runs at once. The UI frontend sends its updates here.
    public static func whenIdle(_ body: @escaping () -> Void) {
        guard depth > 0 else {
            body()
            return
        }
        idleHandlers.append(body)
    }

    /// Whether a call from the host (or a drain) is in progress.
    public static var isInHostCall: Bool {
        depth > 0
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

    private static func finishHostCall() {
        drain()
        while !idleHandlers.isEmpty {
            let handlers = idleHandlers
            idleHandlers = []
            // Handlers run as part of the host call, so what they schedule
            // waits for the next round instead of running inside them.
            depth = 1
            for handler in handlers {
                handler()
            }
            depth = 0
            drain()
        }
    }
}

// Single-threaded by contract (§6.4).
/// Calls from the host (or drains) in progress.
nonisolated(unsafe) private var depth = 0
nonisolated(unsafe) private var idleHandlers: [() -> Void] = []

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

/// The one executor every job runs on: the generic executor, which also
/// stands for the main actor.
private var genericExecutor: UnownedSerialExecutor {
    unsafeBitCast((UInt(0), UInt(0)), to: UnownedSerialExecutor.self)
}

// MARK: - Executor hooks
//
// The runtime's executor hooks are in CRuntime's executor.c, which forwards
// jobs here.

/// A job for the guest's queue.
@c(rt_executor_enqueue)
public func _rt_executorEnqueue(_ job: UnsafeMutableRawPointer) {
    GuestExecutor.enqueue(unsafeBitCast(job, to: UnownedJob.self))
}

/// A job to queue once `nanoseconds` have passed, timed by the Clock contract.
@c(rt_executor_enqueue_after)
public func _rt_executorEnqueueAfter(_ nanoseconds: UInt64, _ job: UnsafeMutableRawPointer) {
    let job = unsafeBitCast(job, to: UnownedJob.self)
    do throws(RuntimeError) {
        try RuntimeClock.after(nanoseconds: Int64(clamping: nanoseconds)) {
            GuestExecutor.enqueue(job)
        }
    } catch {
        fatalError("Clock.after failed: \(error.message)")
    }
}

#endif
