import DynamicRuntime

/// Status and headers of an HTTP response. The body arrives separately
/// through `HTTPTaskDelegate.didReceiveData`.
@DynamicRuntime("org.pureswift.network.HTTPResponse")
public protocol HTTPResponse: AnyObject {

    func statusCode() -> Int32

    /// The final URL, after redirects.
    func url() -> String

    func header(_ name: String) -> String?

    func headerNames() -> [String]

    /// Expected body length in bytes, or `-1` if unknown.
    func expectedContentLength() -> Int64
}
