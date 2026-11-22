# Maps

**Status:** implemented on the guest side, with the shared host side
(`RuntimeMaps`) and `ExampleMaps` on three engines. No platform host draws
a `Map` node yet. What changed while building is at the end.

Module `DynamicMapKit`, which guest code imports as `MapKit`: a map the
host draws, in a SwiftUI view, in the shape of MapKit for SwiftUI (iOS 17).

Decided on 2026-11-22 (`PlannedApps.md`, decision 3): the Maps app uses a
host map view, not a renderer of its own on `Surface`. Each platform's map
draws its own tiles, labels and gestures. That's less guest code and three
different maps.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Maps` | contract, `requires: .network` | MapKit | MapLibre Native (or Google Maps) | libshumate | MapLibre GL JS |

Guest-side Swift:

- **`Map`**, the view, with its content: `Marker`, `Annotation`,
  `MapPolyline`, `MapPolygon`, `MapCircle` and `UserAnnotation`.
- **`MapCameraPosition`** and **`MapCamera`**: where the map looks.
- `LocationCoordinate2D`, `CoordinateRegion`, `CoordinateSpan`, `MapStyle`,
  `MapInteractionModes`, the map controls, and `MapProvider`, the host's
  map service.

The render IR gains a `Map` node, with a node for each kind of content. It
has two new event kinds, `camera` (8) and `longPress` (9).

## What shapes it

- **The host draws the map.** Tiles, labels, pinch and pan, inertia and
  rotation stay in the host. Nothing crosses for each frame. The camera
  crosses when a gesture ends, unless the app asks for every change.
- **MapKit for SwiftUI's shape.** Content is declared in a builder, and the
  position is a binding, as in SwiftUI's `Map(position:)`. A binding fits
  the IR's control sync: a prop going out, an event coming back.
- **CoreLocation's and MapKit's prefixes are dropped,** as `Location` and
  `Drawing` drop theirs. `CLLocationCoordinate2D` is
  `LocationCoordinate2D` and `MKCoordinateRegion` is `CoordinateRegion`.
  SwiftUI's own map names (`Map`, `Marker`, `MapCamera`) are unprefixed
  already.
- **Content is IR.** An annotation is a guest view, and the host draws it at
  its coordinate, as it would anywhere else.
- **Three maps.** Their tiles, styles, labels and zoom levels differ. An
  app mustn't depend on how a map looks, only on where it points.
- **No keys in a guest.** The map service is the host's: which one, and
  any key it needs (Google's, MapTiler's), are set when the host app is
  built. The host shows the service's attribution as the service requires.
- **Where the user is stays `Location`'s.** A map shows the user only when
  the app may already know where they are, and it never asks.

## For a guest

```swift
import SwiftUI
import MapKit

struct PlacesMap: View {

    let places: [Place]

    @State var position = MapCameraPosition.automatic

    @State var selected: Place.ID?

    var body: some View {
        Map(position: $position, selection: $selected) {
            ForEach(places) { place in
                Marker(place.name, systemImage: "fork.knife", coordinate: place.coordinate)
                    .tint(.orange)
                    .tag(place.id)
            }
            Annotation("Start", coordinate: route[0]) {
                Image(systemName: "flag.fill").padding(4).background(.white)
            }
            MapPolyline(coordinates: route)
                .stroke(.blue, lineWidth: 4)
            UserAnnotation()
        }
        .mapStyle(.standard)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange { context in
            visible = context.region
        }
        .onMapLongPress { coordinate in
            pins.append(coordinate)
        }
    }
}
```

### Where it looks

`MapCameraPosition` is one of these:

| Position | What the host shows |
|---|---|
| `.automatic` | all the map's content, framed |
| `.region(CoordinateRegion)` | a center and a span, in degrees |
| `.camera(MapCamera)` | a center, a distance in meters, a heading and a pitch in degrees |
| `.userLocation(followsHeading:fallback:)` | the user, followed as they move; the fallback where the user can't be shown |

When the user moves the map, the binding becomes `.camera(…)` with where
it now is, as in SwiftUI. Setting the binding moves the map.
`position.camera` and `position.region` read back what was set.

Without a binding, `Map(initialPosition:)` starts there and leaves the
camera to the user.

### Content

| Content | What it is |
|---|---|
| `Marker(_:coordinate:)`, with `systemImage:` or `monogram:` | the platform's own pin, with a title. `tint(_:)` colors it |
| `Annotation(_:coordinate:anchor:content:)` | a view of the app's, drawn at the coordinate. `anchor` is the point of the view that sits there, `.bottom` by default |
| `MapPolyline(coordinates:)` | a line through the coordinates. `stroke(_:lineWidth:)` |
| `MapPolygon(coordinates:)` | a closed area. `foregroundStyle(_:)` fills it; `stroke(_:lineWidth:)` outlines it |
| `MapCircle(center:radius:)` | a circle, its radius in meters. Fill and stroke as for a polygon |
| `UserAnnotation()` | where the user is, if the app may know |

`ForEach`, `if` and the other builder forms work as they do for views.

### Picking

With `Map(position:selection:)`, a marker or annotation with a `tag(_:)`
can be picked. Tapping one sets the binding to its tag; tapping the map
away from any clears it. Setting the binding picks one: the host shows a
picked marker as its platform does (Apple's grows; MapLibre's is the
host's choice).

### Following the camera

`onMapCameraChange(frequency:_:)` is told where the map looks:
`.onEnd`, the default, when the user's gesture ends; `.continuous` as it
moves, which is a crossing for each frame and best kept for small work.
Its context has `camera` and `region`.

### Taps on the map

`onMapTap(_:)` and `onMapLongPress(_:)` are given the coordinate the user
touched, away from any content. SwiftUI gets this with `MapReader` and a
tap gesture's location, which the frontend doesn't have yet. These two say
what an app wants from it.

### Style, controls and gestures

- `mapStyle(_:)`: `.standard(pointsOfInterest:)`, `.imagery` or `.hybrid`.
  A host without imagery shows `.standard` (`MapProvider.styles` says
  which it has).
- `mapControls { … }`: `MapUserLocationButton`, `MapCompass`,
  `MapScaleView`, `MapPitchToggle` and `MapZoomStepper`. The host places
  them as its platform does, and leaves out those it has none of.
- `Map(…, interactionModes:)`: `.pan`, `.zoom`, `.rotate`, `.pitch`, or
  `.all`, the default.

### The map service

`MapProvider.current` is the host's service: its name, its attribution and
the styles it draws. It's `nil` on a host without maps, where a `Map`
shows nothing. An app can then say so, or link to a map on the web.

## The contract

```swift
@DynamicRuntime("org.pureswift.maps.Maps", requires: .network)
public protocol Maps: AnyObject {

    static func shared() -> Self

    /// The map service: its name, its attribution as it must be shown,
    /// and a link to its terms (empty if none).
    func provider() -> [String]

    /// The styles the host draws, as bits: 1 standard, 2 imagery,
    /// 4 hybrid.
    func styles() -> Int32
}
```

The map itself is a node, not an object, as SwiftUI's is a view: what it
shows is the guest's state and goes out in the IR. The contract is there
for three things the IR can't do:

- **The capability.** Tiles come over the network, so an app that links
  `MapKit` declares `.network`, and the packager checks it, as for any
  contract. On Android that's the `INTERNET` permission the map needs.
- **Whether there are maps,** for the guest to ask before showing one.
- **The service,** for an app that shows its name or terms.

## Render IR

### Nodes

| Type | Props | Children | Events |
|---|---|---|---|
| `Map` | `position` (below); `style` (`standard`, `imagery`, `hybrid`); `pointsOfInterest` (bool); `interaction` (comma-separated: `pan`, `zoom`, `rotate`, `pitch`); `controls` (comma-separated: `userLocationButton`, `compass`, `scaleView`, `pitchToggle`, `zoomStepper`); `selection` (int: a tag); `cameraUpdates` (`onEnd`, `continuous`, absent: none); `taps`, `longPresses` (bool: whether to report them) | its content | `camera` (array: the camera), `change` (int: the tag picked; no value: none), `tap` and `longPress` (array: the coordinate) |
| `MapMarker` | `title`, `coordinate`; `systemImage` or `monogram` | — | — |
| `MapAnnotation` | `title`, `coordinate`, `anchor` (`[x, y]`, 0 to 1 within the view) | the view | — |
| `MapPolyline` | `coordinates`; `stroke` (color), `lineWidth` | — | — |
| `MapPolygon` | `coordinates`; `fill` (color); `stroke`, `lineWidth` | — | — |
| `MapCircle` | `center`, `radius` (meters); `fill`; `stroke`, `lineWidth` | — | — |
| `MapUserLocation` | — | — | — |

A coordinate is `[latitude, longitude]` in degrees (WGS 84), and a list of
them is one flat array, `[lat, lon, lat, lon, …]`. A marker's color is its
`tint` modifier. A marker or annotation that can be picked has a `tag`
modifier, as a list's row has.

`position` is one array:

| Position | Array |
|---|---|
| automatic | `["automatic"]` |
| region | `["region", lat, lon, latitudeDelta, longitudeDelta]` |
| camera | `["camera", lat, lon, distance, heading, pitch]` |
| the user | `["userLocation", followsHeading, …fallback]`: the fallback is another position's array, or absent for automatic |
| none: the user moves it | absent |

The `camera` event's payload is
`[lat, lon, distance, heading, pitch, latitudeDelta, longitudeDelta]`: the
camera, then the region the view shows.

### Events

| Kind | Value | Payload |
|---|---|---|
| `camera` | 8 | where a `Map` looks |
| `longPress` | 9 | the coordinate a `Map` was held at |

`tap` and `change` are the kinds that exist: a `Map`'s `tap` carries the
coordinate.

### Rules every host follows

- **Move the camera only when `position` differs** from what was last
  rendered, and the map isn't already there. The guest's echo of the
  user's own move then moves nothing. A move after the first is animated.
- **`automatic`** frames every marker, annotation, overlay and the user's
  location, with room around them. It frames them again when the content
  changes, while the position is still `automatic`.
- **`userLocation`** follows the user while the app may know where they
  are and a location is to hand. Otherwise it shows the fallback.
- **After the user moves the map,** send `camera` when the gesture ends,
  if `cameraUpdates` is there; with `continuous`, also as it moves, at
  most once a frame. A move the guest asked for is reported too, once it
  stops.
- **Picking:** when the map has `selection`, a tap on a marker or
  annotation with a `tag` sends `change` with it, and a tap on the map away
  from them sends `change` with no value. Show the picked one as picked
  until the guest's update arrives.
- **Taps and long presses** away from content are reported only when the
  map has `taps` or `longPresses`.
- **Annotations** are drawn as their node's view, at the coordinate's
  point, with the view's `anchor` there, and move with the map. Input
  inside an annotation is the annotation's: a button in it is a button.
- **The user's location** is drawn only for an app that has `.location`,
  and only while it's authorized. The map never asks for it. A
  `userLocationButton` on a host where it would ask is left out.
- **Attribution:** show the service's attribution and legal links as it
  requires, over the map. The guest can't hide them.
- **Styles** a host doesn't have are drawn as `standard`.
- **Units:** degrees for coordinates, headings and pitch; meters for
  distances and radii; points for line widths.

## The shared host

`RuntimeMaps`: `HostMaps`, the contract over settings a host gives at
launch, its service's name, attribution, terms and styles, and
`HostMapsModule`. A host without a map leaves the module out, so the
contract isn't there and `MapProvider.current` is `nil`.

## Capability and the manifest

`Maps` requires `.network`. Nothing else is new. `UserAnnotation` uses
`.location` if the app declares it, and asks nothing of its own.

On macOS, a sandboxed host app needs the outgoing network entitlement for
MapKit's tiles, which `.network` gives it.

## Per host

| | Map | Annotations | Notes |
|---|---|---|---|
| iOS 17, macOS 14 | SwiftUI's `Map(position:selection:)`, its content builder from the nodes | `Annotation`, with the node's view | No key. `onMapCameraChange` with `.onEnd` or `.continuous`; `MapReader` for taps. Imagery and hybrid are there |
| iOS 15–16, macOS 12–13 | `MKMapView` | `MKAnnotationView`s hosting the node's view; `MKMarkerAnnotationView` for markers | `regionDidChangeAnimated` for `camera`; overlays as `MKPolyline`, `MKPolygon` and `MKCircle` renderers |
| Android | MapLibre Native, with a style URL set when the host app is built (a service that needs no key, or one with the host's key). Google Maps' SDK instead, where the host has Play services and a key | views placed at the projected point, moved with the camera | Imagery only if the service has a style for it. `OnCameraIdleListener` for `camera` |
| Linux | libshumate's `ShumateSimpleMap`, over the tile source the host is built with | `ShumateMarker`, its child the node's widget | Paths and areas in a `ShumatePathLayer`; a circle as a polygon. OpenStreetMap's own tile servers forbid this use, so a host needs a source of its own |
| Browser | MapLibre GL JS | `Marker`s whose element is the node's | |

## Not in this design

- **Searching for places and geocoding.** MapKit has `MKLocalSearch`;
  elsewhere a web service is needed, which an app can call with
  `HTTPClient`.
- **Directions and routes.** MapKit has `MKDirections`; elsewhere a
  routing service. An app can draw a route it has with `MapPolyline`.
- **Offline maps.** MapLibre has offline packs and MapKit has nothing an
  app can use, so this depends on the service.
- `MapReader` and `MapProxy`, until gestures have locations;
  `onMapTap` and `onMapLongPress` cover what they're for.
- Look Around, snapshots, 3D buildings and elevation, clustering, tile
  overlays of an app's own, and `MKMapItem`'s places.

## Alternatives weighed

- **A renderer in the guest on `Surface`:** one map everywhere, and every
  pixel the guest's: tiles, decoding, labels in every script, gestures
  and their inertia. Turned down on 2026-11-22.
- **MapLibre GL JS in a `WebView` everywhere:** one map, but a page for
  each map, and no way yet for its scripts to call the app.
- **A map object with methods,** as `WebContent` is: SwiftUI's map is a
  view whose state is the app's, and a binding says it in the IR already.
- **SwiftUI's prefixed type names:** dropped, as the other contracts drop
  them.

## Example and tests

`examples/ExampleMaps`: places on a map and in a list, picked in either;
a route; the user's location; a pin dropped with a long press; and the
camera's center shown as the map moves. Its tests stand in for the map, as
`App.wasm` under WasmKit, a sealed macOS slice and wasm2c output: they
read the `Map` node, and report the camera, a pick, a tap and a long
press as a host would.

- **Frontend:** each kind of content and its props; positions both ways;
  a binding that moves the map and the user's move echoed back; picking
  and clearing; camera updates on end and continuous; taps and long
  presses only when asked for; content in `ForEach` and `if`.
- **`DynamicMapKit`:** the contract's keys, positions and the camera's
  payload, coordinates as flat arrays, and `MapProvider` from the host.
- **`RuntimeMaps`:** `HostMaps` from its settings, and no provider without
  them.

## Changed while building

- **A `Marker`'s monogram is a `String`.** SwiftUI's takes a `Text`,
  whose string the frontend keeps to itself.
- **The map's modifiers are environment values** (an app's own key), so
  they work after other modifiers, as SwiftUI's do. That found a bug in
  the environment: an app's own keys weren't told apart in an Embedded
  guest. They are now (`Implementation.md`).
- **The frontend gained `_RenderContainerView`,** a module's node with
  children, picking and events, and `UnitPoint`, for an annotation's
  anchor. `Color` says its IR value to a module (`_propValue`).
- **A binding gets `cameraUpdates` `onEnd`** even with no
  `onMapCameraChange`, so the user's moves come back to it.
- **`positionedByUser`** is true on the position the guest makes from the
  user's move.
- **Swift 6.4.2's Embedded `-Osize` miscompiles an optional struct** of
  the shape `ExampleMaps`' `Place` had (`Implementation.md`, guest build
  findings), so the example reads a place's name with a loop.

## Decided in review

1. MapKit for SwiftUI's shape, with CoreLocation's and MapKit's
   prefixes dropped.
2. `onMapTap` and `onMapLongPress` for now, in place of `MapReader`.
3. MapLibre on Android by default, rather than Google Maps.

## What hosts still need

- **Darwin:** draw `Map` with SwiftUI's `Map` from iOS 17 and macOS 14,
  and `MKMapView` before; its content from the child nodes, annotations
  as `NodeView`s; report `camera` on `onMapCameraChange` and picks from
  the selection; long presses with `MapReader`; register `HostMapsModule`
  with Apple's name and every style.
- **Android:** MapLibre Native in the Compose interpreter, with a style
  URL set when the host app is built, annotations placed at their
  projected points.
- **Linux:** libshumate's `ShumateSimpleMap` over a tile source of the
  host's own, markers and annotations as `ShumateMarker`s.
- Each packager lists the `Maps` contract, and gives the network
  entitlement or permission an app's `.network` asks for.
