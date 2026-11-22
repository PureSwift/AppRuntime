import DynamicMapKit
import DynamicRuntime
import RuntimeHost

/// The `Maps` contract over the map service a host is built with
/// (`Documentation/Contracts/Maps.md`). The map itself is the renderer's:
/// a `Map` node, drawn with the platform's map. This says whose maps they
/// are.
///
/// Set `provider` at launch, before the app starts. A host without maps
/// leaves `HostMapsModule` out, so the guest finds no contract.
public final class HostMaps: Maps {

    /// The service: its name, attribution, terms and styles. Apple's on
    /// iOS and macOS; on other hosts whatever the host is built with.
    nonisolated(unsafe) public static var provider = MapProvider(
        name: "Map",
        attribution: "",
        terms: nil,
        styles: .standard
    )

    nonisolated(unsafe) private static let instance = HostMaps()

    public static func shared() -> HostMaps {
        instance
    }

    private init() { }

    public func provider() -> [String] {
        Self.provider.fields
    }

    public func styles() -> Int32 {
        Self.provider.styles.union(.standard).rawValue
    }

    /// Back to a service with no name and only the standard style.
    public static func reset() {
        provider = MapProvider(name: "Map", attribution: "", terms: nil, styles: .standard)
    }
}

/// The maps module: registers `HostMaps` for `Maps`.
public enum HostMapsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [MapsProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        MapsProxy.register(HostMaps.self, in: registrar)
    }
}
