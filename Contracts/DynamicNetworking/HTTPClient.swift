import DynamicRuntime

/// Sends HTTP requests. TCP and UDP sockets are not part of the spec.
///
/// Implemented over `URLSession`, `HttpURLConnection` / OkHttp, or libcurl.
/// The host handles TLS, proxies, cookies and redirects the way the platform
/// does.
@DynamicRuntime("org.pureswift.network.HTTPClient", requires: .network)
public protocol HTTPClient: AnyObject {

    static func make() -> Self

    /// Starts a request. Events arrive through `delegate` on the main
    /// thread; the task keeps the delegate until it completes.
    func send(_ request: HTTPRequest, delegate: HTTPTaskDelegate) -> HTTPTask
}
