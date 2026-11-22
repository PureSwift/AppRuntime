import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// A map the host draws: SwiftUI's `Map`, with its content declared in a
/// builder (`Documentation/Contracts/Maps.md`).
///
/// ```swift
/// Map(position: $position, selection: $picked) {
///     Marker("Café", systemImage: "cup.and.saucer", coordinate: cafe)
///         .tag(1)
///     MapPolyline(coordinates: route)
///         .stroke(.blue, lineWidth: 4)
///     UserAnnotation()
/// }
/// ```
///
/// A `Map` node's children are its content. It has the camera's
/// `position`, the `style`, and which gestures, controls and events the
/// host has. The host sends `camera` when the user moved it, `change` when
/// they picked a marker or annotation, and `tap` and `longPress` with the
/// coordinate they touched.
public struct Map<Content: View, SelectionValue: Hashable>: View {

    let position: Binding<MapCameraPosition>?

    let initialPosition: MapCameraPosition

    let interactionModes: MapInteractionModes

    let selection: Binding<SelectionValue?>?

    let content: Content

    @Environment(.mapSettings) var settings

    public init(
        position: Binding<MapCameraPosition>,
        interactionModes: MapInteractionModes = .all,
        selection: Binding<SelectionValue?>,
        @ViewBuilder content: () -> Content
    ) {
        self.position = position
        self.initialPosition = .automatic
        self.interactionModes = interactionModes
        self.selection = selection
        self.content = content()
    }

    /// The map starts at `initialPosition`, and the user moves it.
    public init(
        initialPosition: MapCameraPosition = .automatic,
        interactionModes: MapInteractionModes = .all,
        selection: Binding<SelectionValue?>,
        @ViewBuilder content: () -> Content
    ) {
        self.position = nil
        self.initialPosition = initialPosition
        self.interactionModes = interactionModes
        self.selection = selection
        self.content = content()
    }

    public var body: some View {
        _RenderContainerView("Map", props: props, selection: selection, events: events) {
            content
        }
    }

    var props: [String: PropValue] {
        let settings = self.settings
        var props: [String: PropValue] = [
            "position": (position?.wrappedValue ?? initialPosition).propValue,
            "style": .string(settings.style.name),
            "pointsOfInterest": .bool(settings.style.pointsOfInterest),
            "interaction": interactionModes.propValue,
        ]
        if !settings.controls.isEmpty {
            var text = ""
            for (index, name) in settings.controls.enumerated() {
                text += index == 0 ? name : "," + name
            }
            props["controls"] = .string(text)
        }
        if let change = settings.cameraChange {
            props["cameraUpdates"] = .string(change.frequency.rawValue)
        } else if position != nil {
            // A binding follows the user's moves.
            props["cameraUpdates"] = .string(MapCameraUpdateFrequency.onEnd.rawValue)
        }
        if settings.tap != nil {
            props["taps"] = true
        }
        if settings.longPress != nil {
            props["longPresses"] = true
        }
        return props
    }

    var events: [RenderEventKind: (PropValue?) -> Void] {
        let settings = self.settings
        let position = self.position
        var events: [RenderEventKind: (PropValue?) -> Void] = [:]
        events[.camera] = { payload in
            guard let context = MapCameraUpdateContext(payload: payload) else { return }
            if let position {
                let moved = MapCameraPosition(.camera(context.camera), positionedByUser: true)
                if position.wrappedValue != moved {
                    position.wrappedValue = moved
                }
            }
            settings.cameraChange?.action(context)
        }
        if let tap = settings.tap {
            events[.tap] = { payload in
                if let coordinate = LocationCoordinate2D(payload: payload) { tap(coordinate) }
            }
        }
        if let longPress = settings.longPress {
            events[.longPress] = { payload in
                if let coordinate = LocationCoordinate2D(payload: payload) { longPress(coordinate) }
            }
        }
        return events
    }
}

extension Map where SelectionValue == Never {

    public init(
        position: Binding<MapCameraPosition>,
        interactionModes: MapInteractionModes = .all,
        @ViewBuilder content: () -> Content
    ) {
        self.position = position
        self.initialPosition = .automatic
        self.interactionModes = interactionModes
        self.selection = nil
        self.content = content()
    }

    public init(
        initialPosition: MapCameraPosition = .automatic,
        interactionModes: MapInteractionModes = .all,
        @ViewBuilder content: () -> Content
    ) {
        self.position = nil
        self.initialPosition = initialPosition
        self.interactionModes = interactionModes
        self.selection = nil
        self.content = content()
    }
}

extension Map where SelectionValue == Never, Content == EmptyView {

    /// A map with nothing on it.
    public init(initialPosition: MapCameraPosition = .automatic, interactionModes: MapInteractionModes = .all) {
        self.init(initialPosition: initialPosition, interactionModes: interactionModes) { EmptyView() }
    }

    public init(position: Binding<MapCameraPosition>, interactionModes: MapInteractionModes = .all) {
        self.init(position: position, interactionModes: interactionModes) { EmptyView() }
    }
}

// MARK: - Settings from modifiers

/// What the modifiers around a map say about it: the environment, so they
/// can come after other modifiers, as in SwiftUI.
struct MapSettings {

    var style = MapStyle.standard

    var controls: [String] = []

    var cameraChange: (frequency: MapCameraUpdateFrequency, action: (MapCameraUpdateContext) -> Void)?

    var tap: ((LocationCoordinate2D) -> Void)?

    var longPress: ((LocationCoordinate2D) -> Void)?
}

struct MapSettingsKey: EnvironmentKey {
    static var defaultValue: MapSettings { MapSettings() }
}

extension EnvironmentValues.Key where Value == MapSettings {
    static var mapSettings: Self { Self(MapSettingsKey.self) }
}

/// Changes the settings of the maps inside, keeping what outer modifiers
/// set.
public struct _MapSettingsView<Content: View>: View {

    let content: Content

    let change: (inout MapSettings) -> Void

    @Environment(.mapSettings) var settings

    public var body: some View {
        content.environment(.mapSettings, changed)
    }

    var changed: MapSettings {
        var settings = self.settings
        change(&settings)
        return settings
    }
}

extension View {

    /// How the maps in this view are drawn.
    public func mapStyle(_ style: MapStyle) -> _MapSettingsView<Self> {
        _MapSettingsView(content: self) { $0.style = style }
    }

    /// The controls the maps in this view show. The host places them, and
    /// leaves out those it has none of.
    public func mapControls(@MapControlsBuilder _ content: () -> [String]) -> _MapSettingsView<Self> {
        let controls = content()
        return _MapSettingsView(content: self) { $0.controls = controls }
    }

    /// Tells `action` where the map looks: when the user's gesture ends, or
    /// as it moves (`.continuous`, a crossing for each frame).
    public func onMapCameraChange(
        frequency: MapCameraUpdateFrequency = .onEnd,
        _ action: @escaping (MapCameraUpdateContext) -> Void
    ) -> _MapSettingsView<Self> {
        _MapSettingsView(content: self) { $0.cameraChange = (frequency, action) }
    }

    public func onMapCameraChange(
        frequency: MapCameraUpdateFrequency = .onEnd,
        _ action: @escaping () -> Void
    ) -> _MapSettingsView<Self> {
        onMapCameraChange(frequency: frequency) { (_: MapCameraUpdateContext) in action() }
    }

    /// Gives `action` the coordinate the user tapped, away from the map's
    /// content. SwiftUI does this with `MapReader`, which needs a tap's
    /// location.
    public func onMapTap(_ action: @escaping (LocationCoordinate2D) -> Void) -> _MapSettingsView<Self> {
        _MapSettingsView(content: self) { $0.tap = action }
    }

    /// Gives `action` the coordinate the user held, away from the map's
    /// content: where a pin is dropped.
    public func onMapLongPress(_ action: @escaping (LocationCoordinate2D) -> Void) -> _MapSettingsView<Self> {
        _MapSettingsView(content: self) { $0.longPress = action }
    }
}

// MARK: - Controls

/// A control a map shows over itself.
public protocol MapControl {
    var _name: String { get }
}

/// Moves the map to the user, for an app that may know where they are.
public struct MapUserLocationButton: MapControl {
    public init() { }
    public var _name: String { "userLocationButton" }
}

/// Which way is north, and a tap to turn the map back to it.
public struct MapCompass: MapControl {
    public init() { }
    public var _name: String { "compass" }
}

public struct MapScaleView: MapControl {
    public init() { }
    public var _name: String { "scaleView" }
}

/// Between a flat map and one seen at an angle.
public struct MapPitchToggle: MapControl {
    public init() { }
    public var _name: String { "pitchToggle" }
}

public struct MapZoomStepper: MapControl {
    public init() { }
    public var _name: String { "zoomStepper" }
}

@resultBuilder
public enum MapControlsBuilder {

    public static func buildExpression<Control: MapControl>(_ control: Control) -> [String] {
        [control._name]
    }

    public static func buildBlock(_ parts: [String]...) -> [String] {
        var names: [String] = []
        for part in parts {
            names.append(contentsOf: part)
        }
        return names
    }

    public static func buildOptional(_ part: [String]?) -> [String] {
        part ?? []
    }

    public static func buildEither(first part: [String]) -> [String] {
        part
    }

    public static func buildEither(second part: [String]) -> [String] {
        part
    }
}
