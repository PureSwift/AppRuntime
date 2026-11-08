import DynamicRuntime

/// One request in flight (`URLSessionTask`, OkHttp `Call`).
@DynamicRuntime("org.pureswift.network.HTTPTask")
public protocol HTTPTask: AnyObject {

    /// Unique within its session.
    func identifier() -> Int64

    /// Starts a task. Tasks are created suspended. Suspending a running
    /// task isn't portable (OkHttp can't), so there is no `suspend`.
    func resume()

    /// Cancels the task; the delegate gets `didComplete` with
    /// `NetworkError.cancelled`.
    func cancel()

    /// An `HTTPTaskState` raw value.
    func state() -> Int32

    /// The request the task was created with.
    func originalRequest() -> HTTPRequest

    /// The request being sent, after any redirects.
    func currentRequest() -> HTTPRequest?

    /// The response, once received.
    func response() -> HTTPResponse?

    func countOfBytesSent() -> Int64

    func countOfBytesReceived() -> Int64

    /// `-1` if unknown.
    func countOfBytesExpectedToSend() -> Int64

    /// `-1` if unknown.
    func countOfBytesExpectedToReceive() -> Int64

    /// 0 (low) to 1 (high), default 0.5. Hosts without priorities ignore it.
    func setPriority(_ priority: Float)

    func priority() -> Float
}
