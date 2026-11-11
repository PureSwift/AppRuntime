import DynamicRuntime

/// A mutable HTTP request (`URLRequest`). `GET` with no body by default.
@DynamicRuntime("org.pureswift.network.HTTPRequest")
public protocol HTTPRequest: AnyObject {

    /// Nil unless `url` is an absolute `http` or `https` URL. Plain `http`
    /// may still fail with `.insecureConnectionNotAllowed` (see
    /// `NetworkError`).
    static func make(url: String) -> Self?

    func url() -> String

    /// For example `GET`, `POST`, `PUT`, `DELETE`.
    func setMethod(_ method: String)

    func method() -> String

    /// Replaces every value of the header; nil removes it.
    func setHeader(_ name: String, value: String?)

    /// Values of the header joined with `, `, or nil.
    func header(_ name: String) -> String?

    func headerNames() -> [String]

    func setBody(_ body: [UInt8]?)

    func body() -> [UInt8]?

    /// Seconds; `0` uses the session's `timeoutForRequest`.
    func setTimeout(_ seconds: Double)

    func timeout() -> Double

    /// An `HTTPCachePolicy` raw value.
    func setCachePolicy(_ policy: Int32)

    func cachePolicy() -> Int32
}
