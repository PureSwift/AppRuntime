import DynamicRuntime

/// A URL parsed and resolved by the host (WHATWG URL rules where the
/// platform provides them), so guests don't carry their own parser.
@DynamicRuntime("org.pureswift.network.URL")
public protocol ParsedURL: AnyObject {

    /// Returns nil if `string` isn't a valid absolute URL.
    static func parse(_ string: String) -> Self?

    /// Resolves `reference` against this URL, as a browser does for links.
    func resolve(_ reference: String) -> ParsedURL?

    func absoluteString() -> String

    func scheme() -> String

    func user() -> String?

    func host() -> String?

    /// `-1` if the URL has no explicit port.
    func port() -> Int32

    func path() -> String

    /// Without the leading `?`.
    func query() -> String?

    /// Without the leading `#`.
    func fragment() -> String?

    /// Percent-decoded values of the query items named `name`.
    func queryValues(_ name: String) -> [String]

    /// Percent-encodes `string` for use as a query value.
    static func encodeQueryValue(_ string: String) -> String
}
