import DynamicRuntime

/// Sends HTTP requests (`URLSession`, OkHttp, libcurl). TCP and UDP sockets
/// aren't part of the spec.
///
/// The host handles TLS, HTTP/2 and HTTP/3, proxies, cookies, caching and
/// redirects as its platform does. Tasks are created suspended; call
/// `HTTPTask.resume()`. Each task reports to its own delegate, which it
/// keeps until it completes.
@DynamicRuntime("org.pureswift.network.HTTPSession", requires: .network)
public protocol HTTPSession: AnyObject {

    /// The process-wide session with the default configuration.
    static func shared() -> Self

    static func make(_ configuration: HTTPSessionConfiguration) -> Self

    /// A copy of the session's configuration.
    func configuration() -> HTTPSessionConfiguration

    /// A task that sends `request` (with its body, if any) and delivers the
    /// response and body through `delegate`.
    func dataTask(_ request: HTTPRequest, delegate: HTTPTaskDelegate) -> HTTPTask

    /// Like `dataTask`, with `body` as the request body and upload progress
    /// through `didSendBodyData`.
    func uploadTask(_ request: HTTPRequest, body: [UInt8], delegate: HTTPTaskDelegate) -> HTTPTask

    /// Lets running tasks finish, then releases the session. New tasks fail.
    func finishTasksAndInvalidate()

    /// Cancels every task and releases the session.
    func invalidateAndCancel()

    /// Clears the session's cookie storage.
    func removeAllCookies()

    /// Clears the session's response cache.
    func removeAllCachedResponses()
}
