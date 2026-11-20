import DynamicNetworking
import Foundation

/// `ParsedURL` (`org.pureswift.network.URL`) over Foundation's `URL` and
/// `URLComponents`.
///
/// Foundation parses RFC 3986 rather than WHATWG URLs; the differences that
/// matter to guests are smoothed over here: schemes are lowercase, an `http`
/// or `https` URL's empty path is `/`, and query values decode `+` as a
/// space.
public final class HostURL: ParsedURL {

    let url: URL

    private let components: URLComponents

    private init?(_ url: URL) {
        guard url.scheme != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        self.url = url.absoluteURL
        self.components = components
    }

    public static func parse(_ string: String) -> HostURL? {
        URL(string: string).flatMap(HostURL.init)
    }

    public func resolve(_ reference: String) -> (any ParsedURL)? {
        URL(string: reference, relativeTo: url).flatMap { HostURL($0.absoluteURL) }
    }

    public func absoluteString() -> String {
        url.absoluteString
    }

    public func scheme() -> String {
        (components.scheme ?? "").lowercased()
    }

    public func user() -> String? {
        components.user
    }

    public func host() -> String? {
        components.host
    }

    public func port() -> Int32 {
        components.port.map { Int32(clamping: $0) } ?? -1
    }

    /// Percent-encoded, as in the URL.
    public func path() -> String {
        let path = components.percentEncodedPath
        if path.isEmpty, ["http", "https", "ws", "wss", "ftp"].contains(scheme()) {
            return "/"
        }
        return path
    }

    public func query() -> String? {
        components.percentEncodedQuery
    }

    public func fragment() -> String? {
        components.percentEncodedFragment
    }

    /// Decodes the query as `application/x-www-form-urlencoded`, as browsers
    /// do.
    public func queryValues(_ name: String) -> [String] {
        guard let query = components.percentEncodedQuery else {
            return []
        }
        var values = [String]()
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard Self.formDecode(parts[0]) == name else { continue }
            values.append(parts.count > 1 ? Self.formDecode(parts[1]) : "")
        }
        return values
    }

    /// Leaves only RFC 3986's unreserved characters as they are.
    public static func encodeQueryValue(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formDecode(_ part: Substring) -> String {
        let spaced = part.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
