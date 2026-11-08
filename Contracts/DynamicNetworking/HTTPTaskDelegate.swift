import DynamicRuntime

/// Receives one `HTTPTask`'s events on the main thread, in order:
/// redirects and challenges as they occur, one response, any number of data
/// chunks, then exactly one completion.
///
/// The methods that return a value are synchronous decisions: the host
/// pauses the request until they return.
@DynamicCallback("org.pureswift.network.HTTPTaskDelegate")
public protocol HTTPTaskDelegate: AnyObject {

    /// A redirect to `newRequest`. Return `true` to follow it, `false` to
    /// complete with the redirect response instead.
    func willPerformRedirect(_ task: HTTPTask, response: HTTPResponse, newRequest: HTTPRequest) -> Bool

    /// The server asked for credentials. `method` is an
    /// `HTTPAuthenticationMethod` raw value. Return nil for the default
    /// handling (fail after the first rejection). Server trust (TLS) is
    /// always evaluated by the host and never reaches the guest.
    func didReceiveChallenge(_ task: HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> HTTPCredential?

    /// The response status and headers. Return `false` to cancel the task
    /// before the body arrives.
    func didReceiveResponse(_ task: HTTPTask, response: HTTPResponse) -> Bool

    /// A chunk of the response body.
    func didReceiveData(_ task: HTTPTask, data: [UInt8])

    /// Upload progress; `totalBytesExpectedToSend` is `-1` if unknown.
    func didSendBodyData(_ task: HTTPTask, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64)

    /// No connection is available and the session waits for one (only with
    /// `setWaitsForConnectivity(true)`).
    func taskIsWaitingForConnectivity(_ task: HTTPTask)

    /// `error` is a `NetworkError` raw value, `0` on success; `message` is
    /// the host's description of a failure.
    func didComplete(_ task: HTTPTask, error: Int32, message: String?)
}
