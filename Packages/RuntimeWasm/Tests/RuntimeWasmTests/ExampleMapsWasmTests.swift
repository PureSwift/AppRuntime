import Foundation
import Testing
import DynamicMapKit
import DynamicUI
import RuntimeABI
import RuntimeMaps
import RuntimeNative
import RuntimeWasm

/// The example maps app as App.wasm under WasmKit: a `Map` node and its
/// content, the camera, picking, long presses and the host's service, in an
/// Embedded guest. The test stands in for the map, reporting as a host
/// would. Part of `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleMaps`; skipped without it.
    static var exampleMapsURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleMaps/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleMapsURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleMaps"))
    func exampleMapsInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        HostMaps.provider = MapProvider(name: "Test Maps", attribution: "© Test", terms: nil, styles: .standard)
        HostMapsModule.register(in: native)
        defer { HostMaps.reset() }
        WasmTestRenderer.last = nil
        WasmTestRenderer.window = RenderEnvironment(horizontalSizeClass: .compact)
        defer { WasmTestRenderer.window = nil }

        let bytes = Array(try Data(contentsOf: Self.exampleMapsURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.network])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        let maps = try #require(contracts.first { $0.name == "org.pureswift.maps.Maps" })
        #expect(maps.capability == .network)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func map() throws -> RenderNode {
            try #require(renderer.screen?.first { $0.type == "Map" })
        }
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tag(_ node: RenderNode) -> Int? {
            node.modifiers.first { $0.kind == "tag" }?.args["value"]?.int
        }

        // What the map shows.
        var node = try map()
        #expect(text("service") == "Test Maps")
        #expect(node.props["position"] == .array(["automatic"]))
        #expect(node.props["controls"] == "userLocationButton,compass,scaleView")
        #expect(node.props["cameraUpdates"] == "onEnd")
        #expect(node.props["longPresses"] == true)
        #expect(node.modifiers.contains { $0.kind == "frame" && $0.args["height"] == 320.0 })
        #expect(node.children.map(\.type) == ["MapMarker", "MapMarker", "MapMarker", "MapPolyline", "MapUserLocation"])
        #expect(node.children[0].props["title"] == "Brandenburg Gate")
        #expect(node.children[0].props["coordinate"] == .array([52.5163, 13.3777]))
        #expect(node.children[3].props["coordinates"] == .array([52.5163, 13.3777, 52.5169, 13.4019, 52.5145, 13.3501]))
        let museum = try #require(tag(node.children[1]))

        // The user picks a marker: the list picks it too.
        renderer.send(node, .change, .int(museum))
        #expect(text("picked") == "Museum Island")
        node = try map()
        #expect(node.props["selection"] == .int(museum))
        let list = try #require(renderer.screen?.first { $0.type == "List" })
        #expect(list.props["selection"] == .int(museum))

        // And one in the list: the map picks it.
        let listID = RenderCodec.encode(id: list.id)
        let garden = try RenderCodec.decode(renderer.delegate.row(listID, index: 2))
        renderer.send(list, .change, .int(try #require(tag(garden))))
        #expect(text("picked") == "Tiergarten")
        #expect(try map().props["selection"] == .int(try #require(tag(garden))))

        // A tap away from the markers.
        renderer.send(try map(), .change)
        #expect(text("picked") == "Nothing picked")

        // The user moves the map.
        let moved = MapCameraUpdateContext(
            camera: MapCamera(centerCoordinate: LocationCoordinate2D(latitude: 52.52, longitude: 13.405), distance: 2500),
            region: CoordinateRegion(center: LocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                                     span: CoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.03))
        )
        renderer.send(try map(), .camera, moved.payload)
        #expect(text("center") == "52.5200, 13.4050")
        #expect(try map().props["position"] == .array(["camera", 52.52, 13.405, 2500.0, 0.0, 0.0]))

        // A pin dropped with a long press: an annotation.
        renderer.send(try map(), .longPress, .array([52.5, 13.4]))
        #expect(text("pins") == "1 pins")
        node = try map()
        let pin = try #require(node.children.first { $0.type == "MapAnnotation" })
        #expect(pin.props["title"] == "Pin 1")
        #expect(pin.props["coordinate"] == .array([52.5, 13.4]))
        #expect(pin.props["anchor"] == .array([0.5, 1.0]))
        #expect(pin.children.first?.props["text"] == "📍")

        // The app moves it.
        renderer.send(try #require(renderer.screen?.button("Follow me")), .tap)
        #expect(try map().props["position"] == .array(["userLocation", false]))
        renderer.send(try #require(renderer.screen?.button("Show all")), .tap)
        #expect(try map().props["position"] == .array(["automatic"]))
    }
}
