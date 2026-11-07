import DynamicRuntime

/// A mutable HTTP request.
@DynamicRuntime("org.pureswift.network.HTTPRequest")
public protocol HTTPRequest: AnyObject {

    /// `method` is the HTTP method, for example `GET` or `POST`. Returns nil
    /// if `url` isn't an absolute http or https URL.
    static func make(url: String, method: String) -> Self?

    func url() -> String

    func method() -> String

    /// Replaces every value of the header.
    func setHeader(_ name: String, value: String?)

    /// Values of the header joined with `, `, or nil.
    func header(_ name: String) -> String?

    func headerNames() -> [String]

    func setBody(_ body: [UInt8]?)

    func body() -> [UInt8]?

    /// Seconds; `0` uses the host's default.
    func setTimeout(_ seconds: Double)

    func timeout() -> Double
}
