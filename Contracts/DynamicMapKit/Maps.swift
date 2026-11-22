import DynamicRuntime

/// The host's map service (`Documentation/Contracts/Maps.md`). The map
/// itself is a `Map` node in the render IR, which the host draws; this is
/// for what the IR can't say. App code uses `MapProvider`.
///
/// It requires `.network`: tiles come over it, so an app that links
/// `MapKit` declares it. A host without maps doesn't register it.
///
/// | Host | Map |
/// |---|---|
/// | iOS, macOS | MapKit |
/// | Android | MapLibre Native, or Google Maps |
/// | Linux | libshumate |
/// | Browser | MapLibre GL JS |
@DynamicRuntime("org.pureswift.maps.Maps", requires: .network)
public protocol Maps: AnyObject {

    static func shared() -> Self

    /// The map service: its name, its attribution as it must be shown,
    /// and a link to its terms (empty if none).
    func provider() -> [String]

    /// The styles the host draws, as bits of `MapProvider.Styles`: 1
    /// standard, 2 imagery, 4 hybrid.
    func styles() -> Int32
}

/// The host's map service: whose maps a `Map` shows.
public struct MapProvider: Equatable, Sendable {

    /// The styles a host draws.
    public struct Styles: OptionSet, Sendable {

        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        public static let standard = Styles(rawValue: 1)
        public static let imagery = Styles(rawValue: 2)
        public static let hybrid = Styles(rawValue: 4)
    }

    /// "Apple Maps", "OpenFreeMap", …
    public let name: String

    /// The attribution the service needs shown. The host shows it over
    /// the map.
    public let attribution: String

    /// A link to the service's terms, if it has one.
    public let terms: String?

    public let styles: Styles

    public init(name: String, attribution: String, terms: String?, styles: Styles) {
        self.name = name
        self.attribution = attribution
        self.terms = terms
        self.styles = styles
    }

    /// The service's fields, as `Maps.provider()` answers.
    public init?(fields: [String], styles: Int32) {
        guard let name = fields.first, !name.isEmpty else { return nil }
        let attribution = fields.count > 1 ? fields[1] : ""
        let terms = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
        // Standard is always there.
        self.init(name: name, attribution: attribution, terms: terms,
                  styles: Styles(rawValue: styles & 7).union(.standard))
    }

    public var fields: [String] {
        [name, attribution, terms ?? ""]
    }

    /// The host's service; `nil` on a host without maps, where a `Map`
    /// shows nothing.
    public static var current: MapProvider? {
        guard MapsProxy.isAvailable else { return nil }
        let maps = MapsProxy.shared()
        return MapProvider(fields: maps.provider(), styles: maps.styles())
    }
}
