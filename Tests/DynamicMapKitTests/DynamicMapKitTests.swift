import Testing
import DynamicMapKit
import DynamicRuntime
@testable import DynamicSwiftUI
import DynamicUI
import RuntimeNative

/// A host's map service, as a host's settings give it.
final class ScriptedMapsHost: Maps {

    nonisolated(unsafe) static let instance = ScriptedMapsHost()

    var fields = ["Test Maps", "© Test contributors", "https://example.com/terms"]

    var styleBits: Int32 = 3

    static func shared() -> ScriptedMapsHost { instance }

    func provider() -> [String] { fields }

    func styles() -> Int32 { styleBits }
}

/// Records what a view graph sends, as a host's renderer would show it.
final class MapSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

extension RenderNode {

    func first(_ type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }

    var tag: Int? {
        modifiers.first { $0.kind == "tag" }?.args["value"]?.int
    }
}

// MARK: - Views under test

struct Place: Identifiable {
    let id: Int
    let name: String
    let coordinate: LocationCoordinate2D
}

let berlin = LocationCoordinate2D(latitude: 52.52, longitude: 13.405)
let potsdam = LocationCoordinate2D(latitude: 52.39, longitude: 13.065)

final class MapLog {
    var cameras: [MapCameraUpdateContext] = []
    var taps: [LocationCoordinate2D] = []
    var presses: [LocationCoordinate2D] = []
}

struct PlacesMap: View {

    let places: [Place]

    let log: MapLog

    @State var position = MapCameraPosition.automatic

    @State var picked: Int?

    @State var showsRoute = true

    var body: some View {
        VStack {
            Text("picked \(picked.map { "\($0)" } ?? "none")")
            Text(position.camera.map { "camera \($0.centerCoordinate.latitude)" } ?? (position.isAutomatic ? "automatic" : "other"))
            Map(position: $position, selection: $picked) {
                ForEach(places) { place in
                    Marker(place.name, systemImage: "star", coordinate: place.coordinate)
                        .tint(.orange)
                        .tag(place.id)
                }
                Annotation("Start", coordinate: berlin, anchor: .center) {
                    Text("Start here")
                }
                .tag(99)
                if showsRoute {
                    MapPolyline(coordinates: [berlin, potsdam])
                        .stroke(.blue, lineWidth: 4)
                }
                MapPolygon(coordinates: [berlin, potsdam, LocationCoordinate2D(latitude: 52.4, longitude: 13.3)])
                    .foregroundStyle(.green)
                    .stroke(.black, lineWidth: 1)
                MapCircle(center: potsdam, radius: 500)
                    .foregroundStyle(.red)
                UserAnnotation()
            }
            .mapStyle(.hybrid(pointsOfInterest: false))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                if showsRoute {
                    MapScaleView()
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in log.cameras.append(context) }
            .frame(height: 300)
            .onMapLongPress { coordinate in log.presses.append(coordinate) }
            Button("Go to Potsdam") {
                position = .camera(MapCamera(centerCoordinate: potsdam, distance: 2000, heading: 90, pitch: 30))
            }
        }
    }
}

struct PlainMap: View {
    let log: MapLog
    var body: some View {
        Map(initialPosition: .region(CoordinateRegion(center: berlin, span: CoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.2))),
            interactionModes: [.pan, .zoom])
            .onMapTap { coordinate in log.taps.append(coordinate) }
    }
}

// MARK: - Tests

@Suite(.serialized) struct DynamicMapKitTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func graph<V: View>(_ view: V) -> (ViewGraph, MapSink) {
        let sink = MapSink()
        let graph = ViewGraph(view, sink: sink)
        graph.update()
        return (graph, sink)
    }

    // MARK: The contract

    @Test func theContractNeedsTheNetwork() {
        let maps = MapsProxy.descriptor
        #expect(maps.name == "org.pureswift.maps.Maps")
        #expect(maps.capability == .network)
        #expect(method(maps, "shared")?.signature == Signature("()O"))
        #expect(method(maps, "provider")?.signature == Signature("()O"))
        #expect(method(maps, "styles")?.signature == Signature("()I"))
    }

    @Test func theProviderComesFromTheHost() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        MapsProxy.register(ScriptedMapsHost.self, in: native)
        let host = ScriptedMapsHost.instance
        host.fields = ["Test Maps", "© Test contributors", "https://example.com/terms"]
        host.styleBits = 2
        let provider = try #require(MapProvider.current)
        #expect(provider.name == "Test Maps")
        #expect(provider.attribution == "© Test contributors")
        #expect(provider.terms == "https://example.com/terms")
        #expect(provider.styles == [.standard, .imagery], "standard is always there")

        host.fields = ["Other", "", ""]
        host.styleBits = 0xFF
        let other = try #require(MapProvider.current)
        #expect(other.terms == nil)
        #expect(other.styles == [.standard, .imagery, .hybrid], "bits it doesn't know are dropped")
        #expect(MapProvider(fields: [], styles: 1) == nil)
        #expect(MapProvider(fields: [""], styles: 1) == nil)
        #expect(MapProvider(fields: ["Only a name"], styles: 1)?.attribution == "")
    }

    // MARK: Types

    @Test func positionsGoBothWays() throws {
        let region = CoordinateRegion(center: berlin, span: CoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.2))
        let camera = MapCamera(centerCoordinate: potsdam, distance: 1500, heading: 45, pitch: 60)
        let positions: [MapCameraPosition] = [
            .automatic, .region(region), .camera(camera),
            .userLocation(), .userLocation(followsHeading: true, fallback: .region(region)),
        ]
        for position in positions {
            let wire = try #require(MapCameraPosition(propValue: ScriptedWire.prop(position)))
            #expect(wire == position)
        }
        #expect(ScriptedWire.prop(.region(region)) == .array(["region", 52.52, 13.405, 0.1, 0.2]))
        #expect(ScriptedWire.prop(.camera(camera)) == .array(["camera", 52.39, 13.065, 1500.0, 45.0, 60.0]))
        #expect(ScriptedWire.prop(.userLocation()) == .array(["userLocation", false]))
        #expect(ScriptedWire.prop(.userLocation(followsHeading: true, fallback: .camera(camera)))
                == .array(["userLocation", true, "camera", 52.39, 13.065, 1500.0, 45.0, 60.0]))
        #expect(MapCameraPosition(propValue: .array(["sideways"])) == nil)
        #expect(MapCameraPosition(propValue: .array(["camera", 1.0])) == nil)
        #expect(MapCameraPosition.region(region).region == region)
        #expect(MapCameraPosition.camera(camera).camera == camera)
        #expect(MapCameraPosition.userLocation().followsUserLocation)
        #expect(MapCameraPosition.automatic.isAutomatic)
    }

    @Test func theCamerasPayload() throws {
        let context = MapCameraUpdateContext(
            camera: MapCamera(centerCoordinate: berlin, distance: 800, heading: 10, pitch: 20),
            region: CoordinateRegion(center: berlin, span: CoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.02))
        )
        #expect(context.payload == .array([52.52, 13.405, 800.0, 10.0, 20.0, 0.01, 0.02]))
        #expect(MapCameraUpdateContext(payload: context.payload) == context)
        #expect(MapCameraUpdateContext(payload: .array([1.0, 2.0])) == nil)
        #expect(MapCameraUpdateContext(payload: .array([1, 2, 3, 4, 5, 6, "seven"])) == nil)
        #expect(MapCameraUpdateContext(payload: nil) == nil)
    }

    @Test func regionsInMeters() {
        let region = CoordinateRegion(center: LocationCoordinate2D(latitude: 60, longitude: 10),
                                      latitudinalMeters: 111_320, longitudinalMeters: 111_320)
        #expect(abs(region.span.latitudeDelta - 1) < 0.000_001)
        #expect(abs(region.span.longitudeDelta - 2) < 0.000_1, "a degree of longitude is half as long at 60°")
        #expect(LocationCoordinate2D(latitude: 91, longitude: 0).isValid == false)
        #expect(berlin.isValid)
    }

    // MARK: The map in the IR

    @Test func aMapsNodeAndItsContent() throws {
        let places = [Place(id: 1, name: "Berlin", coordinate: berlin), Place(id: 2, name: "Potsdam", coordinate: potsdam)]
        let (_, sink) = graph(PlacesMap(places: places, log: MapLog()))
        let map = try #require(sink.screen?.first("Map"))
        #expect(map.props["position"] == .array(["automatic"]))
        #expect(map.props["style"] == "hybrid")
        #expect(map.props["pointsOfInterest"] == false)
        #expect(map.props["interaction"] == "pan,zoom,rotate,pitch")
        #expect(map.props["controls"] == "userLocationButton,compass,scaleView")
        #expect(map.props["cameraUpdates"] == "continuous")
        #expect(map.props["longPresses"] == true)
        #expect(map.props["taps"] == nil, "not asked for")
        #expect(map.props["selection"] == nil)
        #expect(map.modifiers.map(\.kind) == ["frame"], "modifiers after the settings still reach the map")
        #expect(map.children.map(\.type) == ["MapMarker", "MapMarker", "MapAnnotation", "MapPolyline", "MapPolygon", "MapCircle", "MapUserLocation"])

        let marker = map.children[0]
        #expect(marker.props == ["title": "Berlin", "systemImage": "star", "coordinate": .array([52.52, 13.405])])
        #expect(marker.modifiers.contains(ModifierNode("tint", ["color": "orange"])))
        #expect(marker.tag == 1.hashValue)
        #expect(map.children[1].tag == 2.hashValue)

        let annotation = map.children[2]
        #expect(annotation.props["anchor"] == .array([0.5, 0.5]))
        #expect(annotation.children.first?.props["text"] == "Start here")
        #expect(annotation.tag == 99.hashValue)
        #expect(annotation.children.first?.tag == nil, "an annotation's view isn't a pick of its own")

        #expect(map.children[3].props == ["coordinates": .array([52.52, 13.405, 52.39, 13.065]), "stroke": "blue", "lineWidth": 4.0])
        #expect(map.children[4].props["fill"] == "green")
        #expect(map.children[4].props["stroke"] == "black")
        #expect(map.children[5].props == ["center": .array([52.39, 13.065]), "radius": 500.0, "fill": "red"])
    }

    @Test func theUsersMovesAndTheAppsMoves() throws {
        let log = MapLog()
        let places = [Place(id: 1, name: "Berlin", coordinate: berlin)]
        let (graph, sink) = graph(PlacesMap(places: places, log: log))
        var map = try #require(sink.screen?.first("Map"))

        // The user moves the map: the binding follows, and the app is told.
        let moved = MapCameraUpdateContext(
            camera: MapCamera(centerCoordinate: LocationCoordinate2D(latitude: 52.6, longitude: 13.5), distance: 3000),
            region: CoordinateRegion(center: LocationCoordinate2D(latitude: 52.6, longitude: 13.5), span: CoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.05))
        )
        #expect(graph.handle(map.id, kind: .camera, payload: moved.payload))
        #expect(log.cameras == [moved])
        graph.update()
        map = try #require(sink.screen?.first("Map"))
        #expect(map.props["position"] == .array(["camera", 52.6, 13.5, 3000.0, 0.0, 0.0]), "the echo of where it is")
        #expect(sink.screen?.children[1].props["text"] == "camera 52.6")

        // The same place again changes nothing.
        #expect(graph.handle(map.id, kind: .camera, payload: moved.payload))
        #expect(!graph.needsUpdate)

        // A payload that isn't a camera is dropped.
        #expect(graph.handle(map.id, kind: .camera, payload: "far away"))
        #expect(log.cameras.count == 2)

        // The app moves it.
        let button = try #require(sink.screen?.first("Button"))
        #expect(graph.handle(button.id, kind: .tap))
        graph.update()
        #expect(sink.screen?.first("Map")?.props["position"] == .array(["camera", 52.39, 13.065, 2000.0, 90.0, 30.0]))
    }

    @Test func pickingAMarkerOrAnnotation() throws {
        let places = [Place(id: 1, name: "Berlin", coordinate: berlin), Place(id: 2, name: "Potsdam", coordinate: potsdam)]
        let (graph, sink) = graph(PlacesMap(places: places, log: MapLog()))
        let map = try #require(sink.screen?.first("Map"))
        #expect(graph.handle(map.id, kind: .change, payload: .int(2.hashValue)))
        graph.update()
        #expect(sink.screen?.first("Map")?.props["selection"] == .int(2.hashValue))
        #expect(sink.screen?.children[0].props["text"] == "picked 2")

        #expect(graph.handle(map.id, kind: .change, payload: .int(99.hashValue)))
        graph.update()
        #expect(sink.screen?.children[0].props["text"] == "picked 99")

        // A tap on the map, away from them.
        #expect(graph.handle(map.id, kind: .change))
        graph.update()
        #expect(sink.screen?.first("Map")?.props["selection"] == nil)
        #expect(sink.screen?.children[0].props["text"] == "picked none")
    }

    @Test func tapsAndLongPressesOnlyWhenAsked() throws {
        let log = MapLog()
        let (graph, sink) = graph(PlainMap(log: log))
        let map = try #require(sink.screen?.first("Map"))
        #expect(map.props["position"] == .array(["region", 52.52, 13.405, 0.1, 0.2]))
        #expect(map.props["interaction"] == "pan,zoom")
        #expect(map.props["taps"] == true)
        #expect(map.props["longPresses"] == nil)
        #expect(map.props["cameraUpdates"] == nil, "no binding and no one to tell")
        #expect(map.props["style"] == "standard")
        #expect(map.props["controls"] == nil)
        #expect(map.children.isEmpty)

        #expect(graph.handle(map.id, kind: .tap, payload: berlin.propValueForTests))
        #expect(log.taps == [berlin])
        #expect(!graph.handle(map.id, kind: .longPress, payload: berlin.propValueForTests), "no handler")
        #expect(graph.handle(map.id, kind: .tap, payload: "nowhere"))
        #expect(log.taps.count == 1)

        // A user's move without a binding moves nothing in the guest.
        #expect(graph.handle(map.id, kind: .camera, payload: MapCameraUpdateContext(
            camera: MapCamera(centerCoordinate: potsdam, distance: 100),
            region: CoordinateRegion(center: potsdam, span: CoordinateSpan(latitudeDelta: 0.001, longitudeDelta: 0.001))
        ).payload))
        #expect(!graph.needsUpdate)
    }

    @Test func contentComesAndGoes() throws {
        let places = [Place(id: 1, name: "Berlin", coordinate: berlin)]
        struct Toggle: View {
            let places: [Place]
            @State var shows = true
            var body: some View {
                VStack {
                    Button("Toggle") { shows.toggle() }
                    Map {
                        if shows {
                            MapPolyline(coordinates: [berlin, potsdam])
                        }
                        ForEach(places) { place in
                            Marker(place.name, monogram: "B", coordinate: place.coordinate)
                        }
                    }
                }
            }
        }
        let (graph, sink) = graph(Toggle(places: places))
        var map = try #require(sink.screen?.first("Map"))
        #expect(map.children.map(\.type) == ["MapPolyline", "MapMarker"])
        let marker = map.children[1]
        #expect(marker.props["monogram"] == "B")
        #expect(marker.tag == nil, "no selection, no tags")
        let button = try #require(sink.screen?.first("Button"))
        #expect(graph.handle(button.id, kind: .tap))
        graph.update()
        map = try #require(sink.screen?.first("Map"))
        #expect(map.children.map(\.type) == ["MapMarker"])
        #expect(map.children[0].id == marker.id, "the marker keeps its identity")
    }
}

/// The IR's forms of the map's values, as a test reads them.
enum ScriptedWire {

    static func prop(_ position: MapCameraPosition) -> PropValue {
        let sink = MapSink()
        let graph = ViewGraph(Map(initialPosition: position), sink: sink)
        graph.update()
        return sink.screen?.first("Map")?.props["position"] ?? .array([])
    }
}

extension LocationCoordinate2D {

    var propValueForTests: PropValue {
        .array([.double(latitude), .double(longitude)])
    }
}
