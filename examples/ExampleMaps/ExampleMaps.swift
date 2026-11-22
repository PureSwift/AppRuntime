import DynamicRuntime
// Guest builds call the frontend `SwiftUI` and the maps module `MapKit`;
// host builds of this package can't, since Apple's SDK has both. A guest
// package just says `import SwiftUI` and `import MapKit`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if canImport(DynamicMapKit)
import DynamicMapKit
#else
import MapKit
#endif

/// The example maps app: places on a map the host draws, and in a list,
/// picked in either; a walk between them; where the user is; pins dropped
/// with a long press; and where the map looks, as it moves.

struct Place: Identifiable {
    let id: Int
    let name: String
    let coordinate: LocationCoordinate2D
}

/// The guest is single-threaded (§6.4), which the compiler can't see.
@Observable
final class Atlas: @unchecked Sendable {

    var places: [Place] = [
        Place(id: 1, name: "Brandenburg Gate", coordinate: LocationCoordinate2D(latitude: 52.5163, longitude: 13.3777)),
        Place(id: 2, name: "Museum Island", coordinate: LocationCoordinate2D(latitude: 52.5169, longitude: 13.4019)),
        Place(id: 3, name: "Tiergarten", coordinate: LocationCoordinate2D(latitude: 52.5145, longitude: 13.3501)),
    ]

    var pins: [LocationCoordinate2D] = []

    /// Where the map looked when it last stopped.
    var center: String = "Not moved"

    /// The service the host draws with, or none.
    var service: String = MapProvider.current?.name ?? "No maps"

    var walk: [LocationCoordinate2D] {
        places.map { $0.coordinate }
    }

    /// The picked place's name. Not `places.first { … }?.name`: Swift
    /// 6.4.2's Embedded `-Osize` miscompiles an optional `Place`
    /// (`Implementation.md`, guest build findings).
    func name(of id: Int?) -> String {
        for place in places where place.id == id {
            return place.name
        }
        return "Nothing picked"
    }
}

/// Degrees to four places, without Foundation's formatting.
func degrees(_ value: Double) -> String {
    let scaled = Int((value * 10_000).rounded())
    let whole = scaled / 10_000
    var fraction = String(abs(scaled % 10_000))
    while fraction.count < 4 {
        fraction = "0" + fraction
    }
    return (scaled < 0 && whole == 0 ? "-" : "") + "\(whole).\(fraction)"
}

struct ContentView: View {

    let atlas: Atlas

    @State var position = MapCameraPosition.automatic

    @State var picked: Int?

    var body: some View {
        VStack {
            Map(position: $position, selection: $picked) {
                ForEach(atlas.places) { place in
                    Marker(place.name, systemImage: "building.columns", coordinate: place.coordinate)
                        .tint(.orange)
                        .tag(place.id)
                }
                MapPolyline(coordinates: atlas.walk)
                    .stroke(.blue, lineWidth: 4)
                ForEach(atlas.pins.indices, id: { $0 }) { index in
                    Annotation("Pin \(index + 1)", coordinate: atlas.pins[index]) {
                        Text("📍")
                    }
                }
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange { context in
                atlas.center = "\(degrees(context.camera.centerCoordinate.latitude)), \(degrees(context.camera.centerCoordinate.longitude))"
            }
            .onMapLongPress { coordinate in
                atlas.pins.append(coordinate)
            }
            .frame(height: 320)

            Text(atlas.name(of: picked))
                .accessibilityIdentifier("picked")
            Text(atlas.center)
                .accessibilityIdentifier("center")
            Text("\(atlas.pins.count) pins")
                .accessibilityIdentifier("pins")
            Text(atlas.service)
                .accessibilityIdentifier("service")

            List(atlas.places, selection: $picked) { place in
                Text(place.name)
            }
            HStack {
                Button("Show all") { position = .automatic }
                Button("Follow me") { position = .userLocation(fallback: .automatic) }
            }
        }
    }
}

struct ExampleMapsApp: App {

    let atlas = Atlas()

    var body: some Scene {
        WindowGroup {
            ContentView(atlas: atlas)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleMapsMain() -> rt_status {
    Runtime.main { ExampleMapsApp.run() }
}
