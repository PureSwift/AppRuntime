import Testing
import DynamicMapKit
import DynamicRuntime
import RuntimeHost
import RuntimeMaps
import RuntimeNative

/// Serialized: the tests share `HostMaps`' settings and the native runtime.
@Suite(.serialized) struct RuntimeMapsTests {

    init() {
        HostMaps.reset()
    }

    @Test func theServiceIsTheHostsSettings() throws {
        HostMaps.provider = MapProvider(name: "OpenFreeMap", attribution: "© OpenMapTiles © OpenStreetMap contributors",
                                        terms: "https://openfreemap.org/tos/", styles: .standard)
        let maps = HostMaps.shared()
        #expect(maps.provider() == ["OpenFreeMap", "© OpenMapTiles © OpenStreetMap contributors", "https://openfreemap.org/tos/"])
        #expect(maps.styles() == 1)

        HostMaps.provider = MapProvider(name: "Apple Maps", attribution: "", terms: nil, styles: [.imagery, .hybrid])
        #expect(maps.provider() == ["Apple Maps", "", ""])
        #expect(maps.styles() == 7, "standard is always there")
        HostMaps.reset()
        #expect(maps.provider() == ["Map", "", ""])
    }

    @Test func theModuleRegistersTheContract() throws {
        #expect(HostMapsModule.contracts.map(\.name) == ["org.pureswift.maps.Maps"])
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostMapsModule.register(in: native)
        HostMaps.provider = MapProvider(name: "Test", attribution: "© Test", terms: nil, styles: [.standard, .imagery])
        let provider = try #require(MapProvider.current, "the guest finds it")
        #expect(provider.name == "Test")
        #expect(provider.styles == [.standard, .imagery])
        HostMaps.reset()
    }
}
