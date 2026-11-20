import DynamicNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPResponse` over a `URLResponse`, normally an `HTTPURLResponse`.
public final class HostHTTPResponse: HTTPResponse {

    let response: URLResponse

    init(_ response: URLResponse) {
        self.response = response
    }

    private var http: HTTPURLResponse? {
        response as? HTTPURLResponse
    }

    /// `0` for a response that isn't HTTP.
    public func statusCode() -> Int32 {
        Int32(http?.statusCode ?? 0)
    }

    public func url() -> String {
        response.url?.absoluteString ?? ""
    }

    public func header(_ name: String) -> String? {
        http?.value(forHTTPHeaderField: name)
    }

    public func headerNames() -> [String] {
        (http?.allHeaderFields ?? [:]).keys.compactMap { $0 as? String }.sorted()
    }

    public func expectedContentLength() -> Int64 {
        response.expectedContentLength
    }

    public func mimeType() -> String? {
        response.mimeType
    }
}
