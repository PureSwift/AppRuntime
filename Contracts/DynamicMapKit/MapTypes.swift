import DynamicUI

/// Degrees, WGS 84: CoreLocation's `CLLocationDegrees`.
public typealias LocationDegrees = Double

/// Meters: CoreLocation's `CLLocationDistance`.
public typealias LocationDistance = Double

/// A point on the earth: CoreLocation's `CLLocationCoordinate2D`.
public struct LocationCoordinate2D: Equatable, Hashable, Sendable {

    public var latitude: LocationDegrees

    public var longitude: LocationDegrees

    public init(latitude: LocationDegrees, longitude: LocationDegrees) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init() {
        self.init(latitude: 0, longitude: 0)
    }

    /// Whether it's a coordinate at all: latitude within ±90, longitude
    /// within ±180.
    public var isValid: Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    /// `[lat, lon]`, as the IR has it.
    var propValue: PropValue {
        .array([.double(latitude), .double(longitude)])
    }

    /// The coordinates as one flat array, `[lat, lon, lat, lon, …]`.
    static func propValue(_ coordinates: [LocationCoordinate2D]) -> PropValue {
        var items: [PropValue] = []
        items.reserveCapacity(coordinates.count * 2)
        for coordinate in coordinates {
            items.append(.double(coordinate.latitude))
            items.append(.double(coordinate.longitude))
        }
        return .array(items)
    }

    /// A coordinate from `[lat, lon]`, the first two of `values`.
    init?(_ values: ArraySlice<PropValue>) {
        guard values.count >= 2,
              let latitude = values[values.startIndex].double,
              let longitude = values[values.startIndex + 1].double else {
            return nil
        }
        self.init(latitude: latitude, longitude: longitude)
    }

    init?(payload: PropValue?) {
        guard case .array(let items)? = payload else { return nil }
        self.init(items[...])
    }
}

/// How much of the map a region shows, in degrees: MapKit's
/// `MKCoordinateSpan`.
public struct CoordinateSpan: Equatable, Hashable, Sendable {

    public var latitudeDelta: LocationDegrees

    public var longitudeDelta: LocationDegrees

    public init(latitudeDelta: LocationDegrees, longitudeDelta: LocationDegrees) {
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    public init() {
        self.init(latitudeDelta: 0, longitudeDelta: 0)
    }
}

/// A center and a span: MapKit's `MKCoordinateRegion`.
public struct CoordinateRegion: Equatable, Hashable, Sendable {

    public var center: LocationCoordinate2D

    public var span: CoordinateSpan

    public init(center: LocationCoordinate2D, span: CoordinateSpan) {
        self.center = center
        self.span = span
    }

    /// A region `latitudinalMeters` tall and `longitudinalMeters` wide
    /// around `center`.
    public init(center: LocationCoordinate2D, latitudinalMeters: LocationDistance, longitudinalMeters: LocationDistance) {
        let metersPerDegree = 111_320.0
        let latitude = latitudinalMeters / metersPerDegree
        let scale = Swift.max(cosine(degrees: center.latitude), 0.000_001)
        let longitude = longitudinalMeters / (metersPerDegree * scale)
        self.init(center: center, span: CoordinateSpan(latitudeDelta: latitude, longitudeDelta: Swift.min(longitude, 360)))
    }

    public init() {
        self.init(center: LocationCoordinate2D(), span: CoordinateSpan())
    }
}

/// The cosine of an angle in degrees, without Foundation: a Taylor series
/// after reducing the angle, good to well under a meter at a region's scale.
func cosine(degrees: Double) -> Double {
    var x = degrees.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x < -180 { x += 360 }
    // cos is even: fold into [0, 180], then [0, 90] with a sign.
    x = Swift.abs(x)
    var sign = 1.0
    if x > 90 {
        x = 180 - x
        sign = -1
    }
    let radians = x * Double.pi / 180
    let r2 = radians * radians
    var term = 1.0
    var sum = 1.0
    for n in 1...10 {
        term *= -r2 / Double((2 * n - 1) * (2 * n))
        sum += term
    }
    return sign * sum
}

/// Where the map looks from: SwiftUI's `MapCamera`.
public struct MapCamera: Equatable, Hashable, Sendable {

    public var centerCoordinate: LocationCoordinate2D

    /// Meters from the center.
    public var distance: LocationDistance

    /// Degrees clockwise from north.
    public var heading: LocationDegrees

    /// Degrees from looking straight down.
    public var pitch: LocationDegrees

    public init(centerCoordinate: LocationCoordinate2D, distance: LocationDistance, heading: LocationDegrees = 0, pitch: LocationDegrees = 0) {
        self.centerCoordinate = centerCoordinate
        self.distance = distance
        self.heading = heading
        self.pitch = pitch
    }
}

/// Where a `Map` looks: SwiftUI's `MapCameraPosition`.
public struct MapCameraPosition: Equatable, Sendable {

    enum Storage: Equatable, Sendable {
        case automatic
        case region(CoordinateRegion)
        case camera(MapCamera)
        indirect case userLocation(followsHeading: Bool, fallback: Storage)
    }

    let storage: Storage

    /// Whether the user moved the map here, rather than the app.
    public let positionedByUser: Bool

    init(_ storage: Storage, positionedByUser: Bool = false) {
        self.storage = storage
        self.positionedByUser = positionedByUser
    }

    /// All the map's content, framed.
    public static let automatic = MapCameraPosition(.automatic)

    public static func region(_ region: CoordinateRegion) -> MapCameraPosition {
        MapCameraPosition(.region(region))
    }

    public static func camera(_ camera: MapCamera) -> MapCameraPosition {
        MapCameraPosition(.camera(camera))
    }

    /// The user, followed as they move; `fallback` where they can't be
    /// shown.
    public static func userLocation(followsHeading: Bool = false, fallback: MapCameraPosition = .automatic) -> MapCameraPosition {
        MapCameraPosition(.userLocation(followsHeading: followsHeading, fallback: fallback.storage))
    }

    /// Whether the map frames its content.
    public var isAutomatic: Bool {
        storage == .automatic
    }

    /// Whether the map follows the user.
    public var followsUserLocation: Bool {
        if case .userLocation = storage { return true }
        return false
    }

    public var region: CoordinateRegion? {
        if case .region(let region) = storage { return region }
        return nil
    }

    public var camera: MapCamera? {
        if case .camera(let camera) = storage { return camera }
        return nil
    }

    /// The position as the IR has it.
    var propValue: PropValue {
        .array(Self.items(storage))
    }

    static func items(_ storage: Storage) -> [PropValue] {
        switch storage {
        case .automatic:
            return ["automatic"]
        case .region(let region):
            return ["region", .double(region.center.latitude), .double(region.center.longitude),
                    .double(region.span.latitudeDelta), .double(region.span.longitudeDelta)]
        case .camera(let camera):
            return ["camera", .double(camera.centerCoordinate.latitude), .double(camera.centerCoordinate.longitude),
                    .double(camera.distance), .double(camera.heading), .double(camera.pitch)]
        case .userLocation(let followsHeading, let fallback):
            var items: [PropValue] = ["userLocation", .bool(followsHeading)]
            if fallback != .automatic {
                items.append(contentsOf: Self.items(fallback))
            }
            return items
        }
    }

    /// A position from the IR's array, for tests and hosts written in Swift.
    public init?(propValue: PropValue) {
        guard case .array(let items) = propValue, let storage = Self.storage(items[...]) else { return nil }
        self.init(storage)
    }

    static func storage(_ items: ArraySlice<PropValue>) -> Storage? {
        guard let kind = items.first?.string else { return nil }
        let values = items.dropFirst()
        switch kind {
        case "automatic":
            return .automatic
        case "region":
            guard let center = LocationCoordinate2D(values), values.count >= 4,
                  let latitudeDelta = values[values.startIndex + 2].double,
                  let longitudeDelta = values[values.startIndex + 3].double else { return nil }
            return .region(CoordinateRegion(center: center, span: CoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)))
        case "camera":
            guard let center = LocationCoordinate2D(values), values.count >= 5,
                  let distance = values[values.startIndex + 2].double,
                  let heading = values[values.startIndex + 3].double,
                  let pitch = values[values.startIndex + 4].double else { return nil }
            return .camera(MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: pitch))
        case "userLocation":
            guard let followsHeading = values.first?.bool else { return nil }
            let rest = values.dropFirst()
            let fallback = rest.isEmpty ? .automatic : storage(rest)
            return fallback.map { .userLocation(followsHeading: followsHeading, fallback: $0) }
        default:
            return nil
        }
    }
}

/// Where a map looks once it moved: what `onMapCameraChange` is given.
public struct MapCameraUpdateContext: Equatable, Sendable {

    public let camera: MapCamera

    /// What the view shows.
    public let region: CoordinateRegion

    public init(camera: MapCamera, region: CoordinateRegion) {
        self.camera = camera
        self.region = region
    }

    /// The `camera` event's payload,
    /// `[lat, lon, distance, heading, pitch, latitudeDelta, longitudeDelta]`.
    public var payload: PropValue {
        .array([
            .double(camera.centerCoordinate.latitude), .double(camera.centerCoordinate.longitude),
            .double(camera.distance), .double(camera.heading), .double(camera.pitch),
            .double(region.span.latitudeDelta), .double(region.span.longitudeDelta),
        ])
    }

    public init?(payload: PropValue?) {
        guard case .array(let items)? = payload, items.count >= 7 else { return nil }
        var values: [Double] = []
        for item in items.prefix(7) {
            guard let value = item.double else { return nil }
            values.append(value)
        }
        let center = LocationCoordinate2D(latitude: values[0], longitude: values[1])
        self.init(camera: MapCamera(centerCoordinate: center, distance: values[2], heading: values[3], pitch: values[4]),
                  region: CoordinateRegion(center: center, span: CoordinateSpan(latitudeDelta: values[5], longitudeDelta: values[6])))
    }
}

/// When `onMapCameraChange` is told.
public enum MapCameraUpdateFrequency: String, Sendable {
    /// When the user's gesture ends.
    case onEnd
    /// As the map moves: a crossing for each frame.
    case continuous
}

/// How a map is drawn: SwiftUI's `MapStyle`. A host without imagery draws
/// `standard`.
public struct MapStyle: Equatable, Sendable {

    let name: String

    let pointsOfInterest: Bool

    public static let standard = MapStyle(name: "standard", pointsOfInterest: true)

    public static func standard(pointsOfInterest: Bool) -> MapStyle {
        MapStyle(name: "standard", pointsOfInterest: pointsOfInterest)
    }

    /// Satellite and aerial pictures.
    public static let imagery = MapStyle(name: "imagery", pointsOfInterest: false)

    /// Pictures with roads and labels.
    public static let hybrid = MapStyle(name: "hybrid", pointsOfInterest: true)

    public static func hybrid(pointsOfInterest: Bool) -> MapStyle {
        MapStyle(name: "hybrid", pointsOfInterest: pointsOfInterest)
    }
}

/// The gestures a map takes: SwiftUI's `MapInteractionModes`.
public struct MapInteractionModes: OptionSet, Sendable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let pan = MapInteractionModes(rawValue: 1)
    public static let zoom = MapInteractionModes(rawValue: 2)
    public static let rotate = MapInteractionModes(rawValue: 4)
    public static let pitch = MapInteractionModes(rawValue: 8)
    public static let all: MapInteractionModes = [.pan, .zoom, .rotate, .pitch]

    /// The `interaction` prop: comma-separated, in this order.
    var propValue: PropValue {
        var names: [String] = []
        if contains(.pan) { names.append("pan") }
        if contains(.zoom) { names.append("zoom") }
        if contains(.rotate) { names.append("rotate") }
        if contains(.pitch) { names.append("pitch") }
        var text = ""
        for (index, name) in names.enumerated() {
            text += index == 0 ? name : "," + name
        }
        return .string(text)
    }
}
