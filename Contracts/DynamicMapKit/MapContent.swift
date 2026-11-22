import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The platform's own pin, with a title: SwiftUI's `Marker`. `tint(_:)`
/// colors it, and `tag(_:)` lets a map's selection pick it.
///
/// A `MapMarker` node has `title` and `coordinate`, and `systemImage` or
/// `monogram`.
public struct Marker: View {

    let props: [String: PropValue]

    public init(_ title: String, coordinate: LocationCoordinate2D) {
        self.props = ["title": .string(title), "coordinate": coordinate.propValue]
    }

    public init(_ title: String, systemImage: String, coordinate: LocationCoordinate2D) {
        self.props = ["title": .string(title), "coordinate": coordinate.propValue, "systemImage": .string(systemImage)]
    }

    /// A pin with up to three letters on it. SwiftUI's takes a `Text`.
    public init(_ title: String, monogram: String, coordinate: LocationCoordinate2D) {
        self.props = ["title": .string(title), "coordinate": coordinate.propValue, "monogram": .string(monogram)]
    }

    public var body: some View {
        _RenderNodeView("MapMarker", props: props)
    }
}

/// A view of the app's, drawn at a coordinate: SwiftUI's `Annotation`.
/// `anchor` is the point of the view that sits on the coordinate.
///
/// A `MapAnnotation` node has `title`, `coordinate` and `anchor`, and the
/// view as its child.
public struct Annotation<Content: View>: View {

    let props: [String: PropValue]

    let content: Content

    public init(_ title: String, coordinate: LocationCoordinate2D, anchor: UnitPoint = .bottom, @ViewBuilder content: () -> Content) {
        self.props = [
            "title": .string(title),
            "coordinate": coordinate.propValue,
            "anchor": .array([.double(anchor.x), .double(anchor.y)]),
        ]
        self.content = content()
    }

    public var body: some View {
        _RenderContainerView("MapAnnotation", props: props) {
            content
        }
    }
}

/// How an overlay is drawn: its fill and its outline.
struct OverlayStyle {

    var fill: Color?

    var stroke: Color?

    var lineWidth: CGFloat?

    func apply(to props: inout [String: PropValue]) {
        if let fill { props["fill"] = fill._propValue }
        if let stroke { props["stroke"] = stroke._propValue }
        if let lineWidth { props["lineWidth"] = .double(lineWidth) }
    }
}

/// A line through coordinates: SwiftUI's `MapPolyline`.
///
/// A `MapPolyline` node has `coordinates`, one flat array, and `stroke`
/// and `lineWidth`.
public struct MapPolyline: View {

    let coordinates: [LocationCoordinate2D]

    var style = OverlayStyle()

    public init(coordinates: [LocationCoordinate2D]) {
        self.coordinates = coordinates
    }

    /// The line's color and width in points.
    public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> MapPolyline {
        var line = self
        line.style.stroke = color
        line.style.lineWidth = lineWidth
        return line
    }

    public var body: some View {
        var props: [String: PropValue] = ["coordinates": LocationCoordinate2D.propValue(coordinates)]
        style.apply(to: &props)
        return _RenderNodeView("MapPolyline", props: props)
    }
}

/// A closed area: SwiftUI's `MapPolygon`.
///
/// A `MapPolygon` node has `coordinates`, and `fill`, `stroke` and
/// `lineWidth`.
public struct MapPolygon: View {

    let coordinates: [LocationCoordinate2D]

    var style = OverlayStyle()

    public init(coordinates: [LocationCoordinate2D]) {
        self.coordinates = coordinates
    }

    /// Fills the area.
    public func foregroundStyle(_ color: Color) -> MapPolygon {
        var polygon = self
        polygon.style.fill = color
        return polygon
    }

    /// Outlines the area.
    public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> MapPolygon {
        var polygon = self
        polygon.style.stroke = color
        polygon.style.lineWidth = lineWidth
        return polygon
    }

    public var body: some View {
        var props: [String: PropValue] = ["coordinates": LocationCoordinate2D.propValue(coordinates)]
        style.apply(to: &props)
        return _RenderNodeView("MapPolygon", props: props)
    }
}

/// A circle on the earth, its radius in meters: SwiftUI's `MapCircle`.
///
/// A `MapCircle` node has `center` and `radius`, and `fill`, `stroke` and
/// `lineWidth`.
public struct MapCircle: View {

    let center: LocationCoordinate2D

    let radius: LocationDistance

    var style = OverlayStyle()

    public init(center: LocationCoordinate2D, radius: LocationDistance) {
        self.center = center
        self.radius = radius
    }

    public func foregroundStyle(_ color: Color) -> MapCircle {
        var circle = self
        circle.style.fill = color
        return circle
    }

    public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> MapCircle {
        var circle = self
        circle.style.stroke = color
        circle.style.lineWidth = lineWidth
        return circle
    }

    public var body: some View {
        var props: [String: PropValue] = ["center": center.propValue, "radius": .double(radius)]
        style.apply(to: &props)
        return _RenderNodeView("MapCircle", props: props)
    }
}

/// Where the user is, for an app that may know: SwiftUI's
/// `UserAnnotation`. The map never asks; ask with `LocationManager` first.
public struct UserAnnotation: View {

    public init() { }

    public var body: some View {
        _RenderNodeView("MapUserLocation")
    }
}
