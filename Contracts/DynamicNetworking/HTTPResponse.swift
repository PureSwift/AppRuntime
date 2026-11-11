import DynamicRuntime

/// Status and headers of an HTTP response (`HTTPURLResponse`). The body
/// arrives through `HTTPTaskDelegate.didReceiveData`.
@DynamicRuntime("org.pureswift.network.HTTPResponse")
public protocol HTTPResponse: AnyObject {

    func statusCode() -> Int32

    /// The URL of this response, after any redirects.
    func url() -> String

    /// Header lookup is case-insensitive.
    func header(_ name: String) -> String?

    func headerNames() -> [String]

    /// Expected body length in bytes, or `-1` if unknown.
    func expectedContentLength() -> Int64

    /// The `Content-Type` media type without parameters, if any.
    func mimeType() -> String?
}
