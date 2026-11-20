import DynamicNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPRequest` over a `URLRequest`.
///
/// The timeout and cache policy can be left unset (`0` and no policy), in
/// which case the session's configuration decides them when a task is made.
public final class HostHTTPRequest: HTTPRequest {

    private(set) var request: URLRequest

    /// `0` until set: the session's `timeoutForRequest`.
    private var timeoutSeconds: Double

    /// `nil` until set: the session's cache policy.
    private var cachePolicyValue: Int32?

    init(_ request: URLRequest) {
        self.request = request
        self.timeoutSeconds = request.timeoutInterval
        self.cachePolicyValue = request.cachePolicy.contractValue
    }

    private init(url: URL) {
        self.request = URLRequest(url: url)
        self.request.httpMethod = "GET"
        self.timeoutSeconds = 0
        self.cachePolicyValue = nil
    }

    public static func make(url: String) -> HostHTTPRequest? {
        guard let url = URL(string: url), url.isHTTP else {
            return nil
        }
        return HostHTTPRequest(url: url)
    }

    public func url() -> String {
        request.url?.absoluteString ?? ""
    }

    public func setMethod(_ method: String) {
        request.httpMethod = method
    }

    public func method() -> String {
        request.httpMethod ?? "GET"
    }

    public func setHeader(_ name: String, value: String?) {
        request.setValue(value, forHTTPHeaderField: name)
    }

    public func header(_ name: String) -> String? {
        request.value(forHTTPHeaderField: name)
    }

    public func headerNames() -> [String] {
        (request.allHTTPHeaderFields ?? [:]).keys.sorted()
    }

    public func setBody(_ body: [UInt8]?) {
        request.httpBody = body.map { Data($0) }
    }

    public func body() -> [UInt8]? {
        request.httpBody.map { [UInt8]($0) }
    }

    public func setTimeout(_ seconds: Double) {
        timeoutSeconds = max(seconds, 0)
        if seconds > 0 {
            request.timeoutInterval = seconds
        }
    }

    public func timeout() -> Double {
        timeoutSeconds
    }

    public func setCachePolicy(_ policy: Int32) {
        cachePolicyValue = policy
        request.cachePolicy = URLRequest.CachePolicy(contract: policy)
    }

    public func cachePolicy() -> Int32 {
        cachePolicyValue ?? HTTPCachePolicy.useProtocolCachePolicy.rawValue
    }

    /// The request to send in a session with `configuration`, which fills in
    /// what the request leaves unset.
    func urlRequest(in configuration: URLSessionConfiguration) -> URLRequest {
        var request = request
        if timeoutSeconds <= 0 {
            request.timeoutInterval = configuration.timeoutIntervalForRequest
        }
        if cachePolicyValue == nil {
            request.cachePolicy = configuration.requestCachePolicy
        }
        return request
    }

    /// `request` as a `URLRequest` for a session with `configuration`: this
    /// module's own request directly, any other through its protocol. Nil if
    /// the URL isn't absolute `http` or `https`.
    static func urlRequest(for request: any HTTPRequest, in configuration: URLSessionConfiguration) -> URLRequest? {
        if let own = HostNetworkingModule.host(request, as: HostHTTPRequest.self) {
            return own.urlRequest(in: configuration)
        }
        guard let copy = make(url: request.url()) else {
            return nil
        }
        copy.setMethod(request.method())
        for name in request.headerNames() {
            copy.setHeader(name, value: request.header(name))
        }
        copy.setBody(request.body())
        copy.setTimeout(request.timeout())
        if request.cachePolicy() != HTTPCachePolicy.useProtocolCachePolicy.rawValue {
            copy.setCachePolicy(request.cachePolicy())
        }
        return copy.urlRequest(in: configuration)
    }
}

extension URL {

    /// Whether this is an absolute `http` or `https` URL with a host.
    var isHTTP: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return !(host ?? "").isEmpty
    }
}
