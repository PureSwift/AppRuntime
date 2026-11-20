import DynamicNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RuntimeHost

/// `HTTPTask` over a `URLSessionTask`, or a task that fails as soon as it's
/// resumed because it couldn't be made (an invalid URL, an invalidated
/// session).
///
/// The task keeps its guest delegate until it completes. Once resumed or
/// cancelled, its session's `SessionDelegate` keeps the task until then too,
/// so the guest may drop it. A task the guest drops without resuming is
/// cancelled. Everything here is the main thread's.
public final class HostHTTPTask: HTTPTask {

    /// Nil for a task that never reached URLSession.
    let task: URLSessionTask?

    /// Routes URLSession's callbacks for `task` back here.
    private weak var owner: SessionDelegate?

    /// Why a task without `task` fails.
    private let failure: NetworkError

    /// The request a task without `task` was made with.
    private let request: (any HTTPRequest)?

    private let identifierValue: Int64

    /// Carries a task without `task`'s completion to the main thread.
    private let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Until `didComplete`.
    private(set) var delegate: (any HTTPTaskDelegate)?

    /// The state of a task without `task`.
    private var ownState = HTTPTaskState.suspended

    private var ownPriority = URLSessionTask.defaultPriority

    /// Whether the guest has been told the task completed. URLSession may
    /// set its task's state only after calling back (swift-corelibs-foundation
    /// does), so the guest's view is kept here.
    private var isCompleted = false

    /// The guest refused the response (`didReceiveResponse` returned
    /// `false`): the task completes as cancelled, without the body.
    /// swift-corelibs-foundation disregards the refusal and keeps loading.
    var refusedResponse = false

    /// One wrapper per `URLResponse`, so the guest sees one object for it.
    private var wrappedResponse: HostHTTPResponse?

    init(task: URLSessionTask, owner: SessionDelegate, delegate: any HTTPTaskDelegate) {
        self.task = task
        self.owner = owner
        self.failure = .unknown
        self.request = nil
        self.identifierValue = Int64(task.taskIdentifier)
        self.deliver = owner.deliver
        self.delegate = delegate
    }

    /// A task that completes with `failure` when it's resumed.
    init(
        failing failure: NetworkError,
        request: any HTTPRequest,
        identifier: Int64,
        delegate: any HTTPTaskDelegate,
        deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
        self.task = nil
        self.failure = failure
        self.request = request
        self.identifierValue = identifier
        self.deliver = deliver
        self.delegate = delegate
    }

    deinit {
        if let task, task.state == .suspended {
            task.cancel()
        }
    }

    public func identifier() -> Int64 {
        identifierValue
    }

    public func resume() {
        guard let task else {
            guard ownState == .suspended else { return }
            ownState = .running
            completeLater(error: failure.rawValue, message: "The task couldn't start: \(failure)")
            return
        }
        owner?.track(self)
        task.resume()
    }

    public func cancel() {
        guard let task else {
            guard ownState == .suspended || ownState == .running else { return }
            ownState = .canceling
            completeLater(error: NetworkError.cancelled.rawValue, message: "cancelled")
            return
        }
        guard task.state == .suspended || task.state == .running else { return }
        owner?.track(self)
        task.cancel()
    }

    public func state() -> Int32 {
        if isCompleted {
            return HTTPTaskState.completed.rawValue
        }
        guard let task else {
            return ownState.rawValue
        }
        // `URLSessionTask.State` has the contract's raw values.
        return Int32(task.state.rawValue)
    }

    public func originalRequest() -> any HTTPRequest {
        if let original = task?.originalRequest {
            return HostHTTPRequest(original)
        }
        return request!
    }

    public func currentRequest() -> (any HTTPRequest)? {
        guard let task else {
            return request
        }
        return task.currentRequest.map(HostHTTPRequest.init)
    }

    public func response() -> (any HTTPResponse)? {
        task?.response.map(wrap)
    }

    public func countOfBytesSent() -> Int64 {
        task?.countOfBytesSent ?? 0
    }

    public func countOfBytesReceived() -> Int64 {
        task?.countOfBytesReceived ?? 0
    }

    public func countOfBytesExpectedToSend() -> Int64 {
        task?.countOfBytesExpectedToSend ?? NSURLSessionTransferSizeUnknown
    }

    public func countOfBytesExpectedToReceive() -> Int64 {
        task?.countOfBytesExpectedToReceive ?? NSURLSessionTransferSizeUnknown
    }

    public func setPriority(_ priority: Float) {
        let priority = min(max(priority, 0), 1)
        if let task {
            task.priority = priority
        } else {
            ownPriority = priority
        }
    }

    public func priority() -> Float {
        task?.priority ?? ownPriority
    }

    // MARK: Delivery

    /// The guest's object for `response`.
    func wrap(_ response: URLResponse) -> HostHTTPResponse {
        if let wrapped = wrappedResponse, wrapped.response === response {
            return wrapped
        }
        let wrapped = HostHTTPResponse(response)
        wrappedResponse = wrapped
        return wrapped
    }

    /// Completes a task without `task` from the main loop, not inside the
    /// guest's call to `resume` or `cancel`.
    private func completeLater(error: Int32, message: String) {
        // This task holds the guest's delegate: only the main thread may
        // release it, so whatever `deliver` does with the closure, the
        // closure doesn't own it.
        let held = MainThreadHeld(self)
        deliver {
            held.take()?.complete(error: error, message: message)
        }
    }

    /// Tells the delegate the task is done and lets it go. Later calls do
    /// nothing.
    func complete(error: Int32, message: String?) {
        guard let delegate else { return }
        self.delegate = nil
        isCompleted = true
        if task == nil {
            ownState = .completed
        }
        autoreleasing {
            delegate.didComplete(self, error: error, message: message)
        }
    }
}
