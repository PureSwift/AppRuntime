# Drawing

**Status:** a design, reviewed once (the decisions are at the end). Its
image part is implemented in this repository: the contract, the guest's
`Image` sources, the image node, the zooming scroll view and the shared
host ([Images, built first](#images-built-first)). No platform host
decodes or draws an image yet ([What hosts still need](#what-hosts-still-need)).
The canvas, bitmaps and fonts aren't built.

Module `DynamicDrawing`: 2D vector graphics, drawn by the host's GPU. It
has CoreGraphics' model and method names, and none of its `CG` prefixes.
A guest draws into a SwiftUI `Canvas`, or into a bitmap of its own that it
can read back or show.

| Contract | Kind | What it is in a host |
|---|---|---|
| `DrawingCanvas` | contract (no capability) | a view whose content the guest draws |
| `DrawingCanvasDelegate` | callback | |
| `DrawingBitmap` | contract | a render target off screen |
| `DrawingImage` | contract | a decoded image, or a bitmap's content |
| `DrawingFont` | contract | a platform font at a size |
| `DrawingCallback` | callback | |

Guest-side Swift: `GraphicsContext`, `BitmapContext`, `Path`,
`Gradient`, `StrokeStyle`, and more sources for the frontend's `Image`.
It draws with the `Color`, `Font`, `Point`, `Size`, `Rect` and
`AffineTransform` of the SwiftUI frontend, which it imports. It adds
`Canvas`, and `Shape`s made from a `Path`.

On every host written in Swift the contracts are one module,
`RuntimeDrawing`, which draws with
[Silica](https://github.com/PureSwift/Silica). Silica's `CGContext` is a
protocol with CoreGraphics, Cairo and Android Canvas backends, and this
design adds one over OpenGL ES 2.0 ([Drawn by the GPU](#drawn-by-the-gpu)).

## Images, built first

The image viewer needs four things from this design and nothing more: an
image the host decodes, from a file the user picked, drawn at the size
it's shown, in a view that zooms. Contacts' photos and music artwork need
the image and its view. So the image part is built first, on its own:

| Built now | Built later, with the canvas |
|---|---|
| `DrawingImage` and `DrawingCallback` | `DrawingCanvas`, `DrawingBitmap`, `DrawingFont` |
| `Image` from a file, from bytes and from pixels; its `size` | `GraphicsContext`, `BitmapContext`, `Path`, `Canvas` |
| An `image` prop on the `Image` node | The drawing format and its player |
| `aspectRatio`, `scaledToFit`, `scaledToFill`, `clipped` | `Image` from a bundle resource in a canvas, and from a bitmap |
| A scroll view that zooms | `SilicaGL` |
| `RuntimeDrawing`'s image half, over a host's decoder | |

The four questions at the end stay open: none of them is about images.

### What shapes it

- **A photo doesn't fit through the guest.** A 48-megapixel photo is
  about 20 MB as a file and 190 MB as RGBA. A wasm guest's heap is 4 GB
  at most, and every byte that crosses is copied. So the host reads the
  file, decodes it and draws it, and the guest holds a handle.
- **A picked file is already somewhere the host can reach.** A
  `Document`'s `path` is a `FilePath`, and a contract can take a
  directory and a path, as `MediaPlayback.loadFile` does. Decoding from a
  document needs no handle of a new kind: a document is a directory
  `Files` accepts.
- **Only the host knows the size it shows.** The guest does no layout
  (§9.1), so it can't choose how large to decode. The host decodes for
  the size an image is drawn at, as it draws a `Photo` node from the
  system's thumbnails at the node's size. A guest that wants a small copy
  whatever happens says so.
- **Zooming stays in the host.** An event per frame of a pinch would cross
  to the guest and come back as an update, behind the fingers. The
  platforms' scroll views zoom by themselves; the guest hears the scale
  when the fingers lift.
- **Every SwiftUI app shouldn't declare this.** An app declares every
  contract of the modules it links, and a host refuses one that declares
  a contract the host lacks. `TextEditor` and the clipboard's image type
  found this when they were built. So `Image` stays in the frontend, which
  declares nothing new, and `DynamicDrawing` adds its sources
  ([What this changes](#what-this-changes)).

### For a guest

```swift
import SwiftUI
import DynamicDocuments
import DynamicDrawing

struct Viewer: View {

    let document: Document           // held for as long as it's shown

    @State var zoom = 1.0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(contentsOf: document.path)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(document.name)
        }
        .zoomable(1...8, scale: $zoom)
    }
}
```

```swift
let photo = Image(contentsOf: document.path)        // nothing is read yet
let size = try await photo.size                     // 8064 by 6048: the header, not a decode

let thumbnail = Image(contentsOf: document.path, maximumPixelSize: 256)
let avatar = Image(data: contact.photo)             // encoded bytes the app has
let swatch = Image(pixels: rgba, width: 16, height: 16, scale: 2)

let types = Image.decodableTypes                    // ["image/png", "image/jpeg", "image/heic", …]
```

- **`Image` is the frontend's**, with three more sources. It's still a
  value: copies of one share one host image. Making one reads nothing.
  The host reads the file when the image is first shown or asked its
  size.
- **It's decoded where it's drawn.** The host decodes for the pixels the
  view covers, rounded up to a power of two. That's never more than the
  image has, nor more than `maximumPixelSize` on the longer side. Shown
  larger, because it's zoomed or the window grew, it's decoded again, and
  the old decode is shown scaled until the new one is ready. The host
  holds one decode per image, and may drop one that isn't on screen.
- **Upright.** The orientation the file records is applied, and `size` is
  the size as shown.
- **`size` is `async throws(DrawingError)`**, in points: pixels over the
  scale. A file's or bytes' scale is 1.
- **An image that can't be read draws nothing**, as a `Photo` node
  doesn't, and the host says so once in its log. Its `size` throws
  `undecodable`, `notFound` or `notPermitted`.
- **Hold the document.** A file image reads through the document's
  access, which ends when the app releases the `Document`, as for any
  `FilePath` ([Documents](Documents.md)). An image shown after that draws
  what it already decoded, or nothing.
- **`decodableTypes`** are MIME types, for filtering a picker: PNG and
  JPEG on every host; HEIF, WebP, GIF, TIFF and BMP where the platform
  decodes them. A GIF is its first frame.
- `Image(data:)` copies the bytes to the host once. It's for what the app
  already has in memory, a contact's photo or a song's artwork, not for a
  file it could name.

### Showing it

- **The `Image` node gets an `image` prop:** a `DrawingImage`'s
  identifier. Without `resizable`, the node is the image's size in points.
  With it, the image fills its frame.
- **It's laid out before it's decoded.** The host reads the header first,
  which costs a read of a few kilobytes. Until then the node is empty, and
  the host lays out again when the size arrives.
- **New modifiers, as SwiftUI has them:** `aspectRatio(_:contentMode:)`,
  `scaledToFit()`, `scaledToFill()` and `clipped()`, on any view. In the
  IR, `aspectRatio` has `ratio` (none: the content's own) and
  `contentMode` (`fit`, `fill`), and `clipped` has nothing. A host that
  doesn't know them ignores them, and the image is stretched.
- **The frontend keeps the images it shows.** An `Image` made in `body`
  would be released when `body` returns. The frontend holds every host
  image the last tree it sent names, and lets go of one when a tree no
  longer does.

### Zooming

```swift
ScrollView([.horizontal, .vertical]) { … }
    .zoomable(1...8, scale: $zoom)     // or .zoomable(1...8)
```

SwiftUI has no scroll view that zooms, so this spelling is the
frontend's own. It's a method on `ScrollView`, as `resizable()` is on
`Image`.

- **The content is laid out in the scroll view's own size,** as if it
  didn't scroll, and centered. Zooming scales it, and the scroll view
  scrolls what zooming makes larger than itself.
- **A pinch zooms** around the fingers, and so does a trackpad's. A
  **double tap** zooms in to twice the minimum at the point tapped, or
  back out to the minimum.
- **The guest hears the scale when the gesture ends:** a `change` event
  with the scale. Setting the binding zooms, around the center, animated
  as the platform animates it. The usual control sync applies: the host
  zooms only to a scale that differs from the one it last rendered.
- **Content is drawn sharp at its zoomed size.** An image in it is decoded
  for that size when the gesture ends. While the fingers move, the host
  scales what it has.
- **In the IR,** `ScrollView` gains `minZoom`, `maxZoom` and `zoom`
  (doubles), and a `change` event (double: the scale). A host that doesn't
  know them shows a scroll view that doesn't zoom.
- Not here: zooming a lazy container, rotating, and a pinch on a view
  that isn't a scroll view, which is the frontend's gestures' to add.

### The contract, now

`DrawingImage` as built, in place of the draft
[below](#the-contracts). `named` comes back with the canvas, as an added
method. `DrawingCallback` is as drafted.

```swift
/// An image the host holds and decodes.
@DynamicRuntime("org.pureswift.drawing.Image")
public protocol DrawingImage: AnyObject {

    /// A file `Files` reaches: `directory` is a `FileDirectory`'s value,
    /// the app's own or a document's. Nothing is read yet. `maxPixelSize`
    /// caps the longer side of every decode; 0 doesn't.
    static func open(_ directory: Int32, path: String, maxPixelSize: Int32) -> Self

    /// Encoded bytes, in a format `formats()` names.
    static func decode(_ data: [UInt8], maxPixelSize: Int32) -> Self

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top. Nil when
    /// the bytes don't match the size, or the host refuses the size.
    static func make(pixels: [UInt8], width: Int32, height: Int32, scale: Float) -> Self?

    /// The MIME types this host decodes.
    static func formats() -> [String]

    func identifier() -> Int32

    /// Reads the header if it hasn't been, then `didMeasure` with the
    /// upright size in points and the scale, or `didFail`.
    func size(_ callback: DrawingCallback)
}
```

- **No capability.** Reading a file is the access the app already has to
  its directory, or the user gave with the document.
- `DrawingError` gains `notPermitted`, for a document the app let go of.

### For a host

`RuntimeDrawing`'s image half: `HostImages`, the contract over a host's
`ImageDecoder`, and what a renderer asks it for.

```swift
public protocol ImageDecoder: AnyObject, Sendable {   // off the main thread, one call at a time

    /// The MIME types it decodes.
    var formats: [String] { get }

    /// The upright size in pixels, from the header alone.
    func header(of source: HostImageSource) throws(DrawingError) -> HostImageHeader

    /// Upright, with the longer side no more than `maxPixelSize`.
    func decode(_ source: HostImageSource, maxPixelSize: Int) throws(DrawingError) -> HostDecodedImage

    /// The platform's image of pixels the guest made.
    func image(pixels: [UInt8], width: Int, height: Int) throws(DrawingError) -> HostDecodedImage
}

// HostImageSource: .file(String), an absolute path from HostFiles, or .data([UInt8]).
// HostDecodedImage: its size in pixels, and the decoder's own image as an
// AnyObject: a CGImage, an android.graphics.Bitmap, a GdkTexture.

HostImages.decoder = PlatformImageDecoder()
HostDrawingModule.register(in: runtime)

// In the renderer, for an Image node's `image` prop:
let image = HostImages.image(identifier)
image.header { header in … }                       // for layout
image.decoded(forPixelSize: 1800) { decoded in … } // at once when what it holds is enough
```

- **The file is found through `HostFiles`** when it's first read, as
  `HostMedia` finds a file to play, so a document that's been let go of
  fails with `notPermitted`.
- **The header is read once,** and every `size` and every layout is
  answered from it.
- **Sizes are rounded up** to a power of two and capped by the image's
  own size and its `maxPixelSize`, so a resize by a few points doesn't
  decode again. One decode runs at a time per image; requests that arrive
  meanwhile wait for it, or for one more large enough.
- **It keeps the largest decode** asked for, and lets go of it when the
  guest releases the image. `HostImages.trim()`, for the platform's
  memory warning, drops every decode nothing asked for since the trim
  before.
- **Answers are on the main thread.**
- **`MemoryImageDecoder`,** for tests, reads the sizes in PNG and JPEG
  headers and records each decode asked of it. It isn't a default:
  without a decoder, images can be made, `formats()` is empty, and
  `size` fails with `unavailable`.

What decodes on each platform. These are from what's known of each, and
haven't been checked against its documentation yet:

| Host | Header | Decode at a size | Formats besides PNG and JPEG |
|---|---|---|---|
| iOS / macOS | ImageIO: `CGImageSourceCopyPropertiesAtIndex`, with the orientation | `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`, `CreateThumbnailWithTransform` and `CreateThumbnailFromImageAlways` | HEIF, WebP, GIF, TIFF, BMP |
| Android | `ImageDecoder`'s `OnHeaderDecodedListener` (API 28); `BitmapFactory` with `inJustDecodeBounds` and `ExifInterface` below it | `ImageDecoder.setTargetSize`; `BitmapFactory`'s `inSampleSize` below API 28 | WebP, GIF, BMP; HEIF from API 28 |
| Linux | `gdk_pixbuf_get_file_info`, and the orientation option | `gdk_pixbuf_new_from_file_at_scale`, then `gdk_pixbuf_apply_embedded_orientation` | whatever loaders are installed: often WebP, GIF, TIFF, BMP |
| Browser | `createImageBitmap` of the file, or the `ImageDecoder` API where there is one | `createImageBitmap` with `resizeWidth`, `resizeHeight` and `imageOrientation: "from-image"` | WebP, GIF, BMP; HEIF in Safari |

What a renderer does with the node and the scroll view:

| Host | `Image` with `image` | Zooming |
|---|---|---|
| iOS | a `UIImageView` of the decode's `CGImage` | `UIScrollView`'s `minimumZoomScale`, `maximumZoomScale`, `viewForZooming(in:)`; `scrollViewDidEndZooming` reports |
| macOS | an `NSImageView` | `NSScrollView`'s `allowsMagnification`, `minMagnification`, `maxMagnification`; `didEndLiveMagnifyNotification` reports |
| Android | an `ImageView` of the `Bitmap`, or a Compose `Image` | a `ScaleGestureDetector` and a double-tap detector over the content, or Compose's `transformable` |
| Linux | a `GtkPicture`, or the toolkit's image | `GtkGestureZoom` over the scrolled content |
| Browser | an `<img>` or a canvas with the `ImageBitmap` | a CSS scale on the content, from pointer events and a trackpad's wheel with control held |

### What this changes

Three of the reviewed decisions, and the text that followed from them:

- **`Color`, `Font` and `Image` stay in the frontend.** The review had
  them move to `DynamicDrawing` and the frontend re-export them. Then
  every SwiftUI app would link `DynamicDrawing` and declare its
  contracts. Kept in the frontend, they're still one type each, which is
  what moving them was for, and no file that imports both sees a clash.
- **`DynamicDrawing` imports the frontend,** and `DynamicFiles`, as
  `DynamicMedia` and `DynamicPhotos` do. It needs the frontend's `Image`
  to extend, and its `Canvas` couldn't be in the frontend for the same
  reason as above. An app that draws a bitmap with no window links the
  frontend's code, and declares the renderer.
- **The geometry is the frontend's too.** `Point`, `Size`, `Rect` and
  `AffineTransform` are where SwiftUI's API is, with the `CG` aliases
  beside them. `Size` comes now, for `size`; the rest come with the
  canvas. `DynamicDrawing` still has no `CG` names.
- And one thing in the draft contract: **an image is decoded at the size
  it's drawn,** not once when it's made, and `decode` takes a
  `maxPixelSize`.

### Changed while building

- **`Image` reaches its host image through a protocol,** the frontend's
  `_HostImageOwner`, not by casting the object it holds. Embedded Swift
  compiled the cast, and it failed at run time in every guest: `size`
  answered `unavailable`. The macOS tests, which aren't Embedded, passed.
- **`zoomable` is two methods,** `zoomable(_:)` and `zoomable(_:scale:)`.
  With one taking an optional binding, `$model.zoom` didn't type-check.
- **A lazy row keeps its images until it's fetched again,** or its list
  goes. The host still shows the row it fetched after the guest updates.
- **`Image(pixels:width:height:scale:)` is failable,** as its contract
  call is.
- **`HostImages.maximumSide`,** 16384 by default, is the most pixels on a
  side the host decodes or takes from the guest. `HostImages.log` is where
  an image that can't be read is said, once for each image.
- **A header that failed for want of access is read again** next time:
  the app may be given the file again. Other failures are kept.

### What hosts still need

- **A decoder:** `HostImages.decoder`, the platform's (the table above).
  Without one, every image draws nothing and its size fails with
  `unavailable`.
- **The node:** draw an `Image` with `image` from
  `HostImages.image(identifier)`: lay it out from `header`, draw
  `decodedImage`, and ask `decoded(forPixelSize:)` for the pixels it
  covers.
- **The modifiers:** `aspectRatio` and `clipped`, on any node.
- **The zooming scroll view:** `minZoom`, `maxZoom`, `zoom` and the
  `change` event (`RenderIR.md`).
- **`HostDrawingModule.register(in:)`,** and `HostImages.trim()` on the
  platform's memory warning.
- On Android and in the browser, a `findFile` that gives the decoder what
  it reads a document with, as `HostMediaPlayback.findFile` does.

### Tests and an example

- **Frontend:** the `image` prop, the new modifiers, the zoom props and
  its `change` event, and that the frontend holds an image while a tree
  names it and lets go after.
- **`DynamicDrawing`:** sources, `size` through a test host, errors.
- **`RuntimeDrawing`:** rounding and capping sizes, one decode at a time,
  keeping the largest, `trim()`, `notPermitted` after a grant is revoked,
  `MemoryImageDecoder`'s headers.
- **`ExampleImages`,** on the three engines: it writes a PNG to its own
  directory, shows it fitted in a zooming scroll view with its size and
  the scale beneath, shows a thumbnail of it, and has a button that opens
  a picked image instead. The tests check the tree, the size, and a zoom
  reported by a test renderer.

## The canvas, built next

**Status:** a draft, not reviewed. Nothing in this section is built.

The rest of this design, built the way the image part was: the guest's
side whole, the shared host's player tested against a recorder, and the
platform renderers left to the hosts. It answers the four questions left
from the first review with what it proposes, and asks one more.

| Built now | Left to the hosts, and to Silica |
|---|---|
| `Point`, `Vector`, `Rect`, `AffineTransform` in the frontend | Replaying into a platform's context (`SilicaCoreGraphics`, `SilicaCairo`, `SilicaAndroid`, `SilicaWeb`) |
| `Path`, `GraphicsContext`, `BitmapContext`, `Gradient`, `StrokeStyle` and the rest of the names | `SilicaGL` |
| The drawing format, written by the guest and read by the host | Fonts and text layout, from the platform |
| `DrawingCanvas`, `DrawingBitmap`, `DrawingFont` and their callbacks | Gradients, blend modes and text from a string in Silica |
| `Canvas`, `Shape.path(in:)`, `Image` from a bitmap | |
| `RuntimeDrawing`'s player, over a host's renderer, with a recorder for tests | |

### The questions, answered

1. **A stateful context in `Canvas`:** yes, CoreGraphics' model, with
   SwiftUI's spellings that cost nothing on the same class, as designed.
   Code written for SwiftUI's value-type context needs `saveGState()` or
   `drawLayer` where it copied the context.
2. **Asynchronous reads:** yes. `pixels()`, `png()` and an image's `size`
   are `async`, and answer at once on a host that can.
3. **`SilicaGL` on GLES 2.0, or Metal on Apple:** not decided by this
   build. Nothing here depends on it: the player replays into whatever
   renderer a host gives it. It's decided when `SilicaGL` is designed.
4. **What comes first:** the guest API, the format and the player now; the
   hosts on the CPU backends Silica has; the GPU backends later. A CPU
   backend is a correct host, only a slower one.

### What shapes it

- **The player doesn't import Silica.** Silica's package brings Cairo,
  FontConfig, swift-java and JavaScriptKit for its backends, and every
  host of this package would fetch them all. So `RuntimeDrawing` replays
  into `DrawingRenderer`, a protocol of its own with CoreGraphics'
  operations, and a host adapts it to the `CGContext` it draws with. The
  adapter to Silica is a few dozen lines, one per call, and lives with
  the host until Silica's package can be depended on for its core alone.
- **Text and images are the host's,** named in a drawing by identifier,
  as designed. `DrawingRenderer` takes a font and an image as the host's
  own objects, found by the player.
- **The frontend gets the geometry,** since SwiftUI's API is spelled with
  it: `Point`, `Vector`, `Rect` and `AffineTransform`, with `CGPoint`,
  `CGRect`, `CGVector` and `CGAffineTransform` as aliases, beside the
  `Size` the image part added. `Rect` has SwiftUI's and CoreGraphics'
  `midX`, `insetBy`, `union`, `contains` and the rest a drawing uses.
- **A `Canvas` asks once per size.** The host's `draw` call is answered
  with the bytes at once: the closure runs inside it, reading what it
  reads under observation, as a body does. A change to what it read calls
  `setNeedsDisplay()`, not the closure.
- **A `Shape` with `path(in:)` is a canvas** whose drawing is its path,
  filled or stroked with the shape's style. The five built-in shapes stay
  the nodes they are.

### For a host

`RuntimeDrawing` gains, beside the image half:

```swift
/// What a drawing is replayed into: a view's context, or a bitmap's.
/// CoreGraphics' operations, top-left origin, in points.
public protocol DrawingRenderer: AnyObject {
    func save()
    func restore()
    func concatenate(_ transform: AffineTransform)
    func setAlpha(_ alpha: Double)
    func setBlendMode(_ mode: BlendMode)
    func setAntialias(_ on: Bool)
    func setFill(_ color: DrawingColor)
    func setStroke(_ color: DrawingColor, style: StrokeStyle)
    func setShadow(_ shadow: DrawingShadow?)
    func fill(_ path: Path, rule: FillRule)
    func stroke(_ path: Path)
    func clip(_ path: Path, rule: FillRule)
    func clear(_ rect: Rect)
    func draw(_ image: AnyObject, in rect: Rect)
    func draw(_ text: String, font: AnyObject, at point: Point, anchor: UnitPoint)
    func draw(_ text: String, font: AnyObject, in rect: Rect, alignment: TextAlignment)
    func drawLinearGradient(_ gradient: DrawingGradient, start: Point, end: Point, options: GradientOptions)
    func drawRadialGradient(_ gradient: DrawingGradient, startCenter: Point, startRadius: Double, endCenter: Point, endRadius: Double, options: GradientOptions)
    func beginLayer()
    func endLayer()
}

/// What a host supplies: bitmaps, fonts, and named colors.
public protocol DrawingBackend: AnyObject {
    /// A render target off screen, `nil` for a size it refuses.
    func makeBitmap(width: Int, height: Int, opaque: Bool) -> (any DrawingBitmapTarget)?
    /// A font at a size, its metrics, and what a string occupies in it.
    func makeFont(_ description: DrawingFontDescription) -> any DrawingFontHandle
    /// A named color for an appearance.
    func color(named name: String, dark: Bool) -> DrawingColor
}
```

- **`DrawingPlayer.play(_:into:)`** reads a drawing and replays it,
  skipping commands it doesn't know by their length, and stopping at a
  malformed one, with what was drawn before kept.
- **`HostCanvas`** is the `DrawingCanvas` contract: a host's view asks it
  for a drawing at a size and scale, and is told when it's needed again.
- **`HostBitmap`** and **`HostFont`** are the other two contracts, over
  the backend. A bitmap's pixels and PNG are read through its target.
- **`RecordingRenderer`** writes down each call, for a host's tests and
  this package's.

### For a guest

As designed ([For a guest](#for-a-guest), [The context](#the-context)),
with one thing added: `Canvas` takes `opaque` and `rendersAsynchronously`
as SwiftUI's does, and ignores them. Its closure gets a `GraphicsContext`
and a `Size`.

### The render IR

A new node, `Canvas`, with `canvas`, the `DrawingCanvas`'s identifier. A
player that doesn't know it shows a placeholder (§9.2).

### Tests and an example

- **Frontend:** the geometry's arithmetic; a `Shape`'s path as a canvas.
- **`DynamicDrawing`:** `Path` (building, bounds, `contains` with both
  rules, transforms, arcs as curves); the context's state and its
  recording, command by command, against the format; a `Canvas` drawn at
  the host's size and redrawn when what it read changes; a bitmap's
  pixels and PNG through a test host; fonts measured.
- **`RuntimeDrawing`:** the player against `RecordingRenderer`, for every
  command, an unknown one skipped, a malformed one stopping it; a canvas,
  a bitmap and a font over a test backend.
- **`ExampleDrawing`:** a gauge, a bar chart with labels measured to fit,
  a custom shape, and a button that draws a badge into a bitmap and saves
  its PNG to the app's documents. On the three engines, against a
  recording host.

### Questions

1. **The player's own renderer protocol,** instead of Silica's
   `CGContext`, so this package doesn't fetch Silica's backends'
   dependencies. The adapter to Silica is then each host's. Or should
   Silica's package be split first, and the player use its `CGContext`?

## What shapes it

- **The guest can't rasterize.** A slice may leave undefined only `rt.h`,
  GLES and a small libc set (`DynamicRuntime.md` §7.5), so it can't link
  Cairo, FreeType or a platform's graphics library. Silica's backends
  can't be compiled into a guest. Pixels are made in the host.
- **A call across the boundary costs more than a call.** Each one marshals
  its arguments, and in a wasm host copies them between memories. A
  drawing is hundreds of operations.
- **So a drawing is recorded, and crosses once.** `GraphicsContext` keeps
  its state and the current path in the guest and appends each operation
  to a byte buffer. The buffer goes to the host in one call, and the host
  replays it. Geometry, transforms and paths are plain Swift in the guest:
  building a path, flattening an arc or asking where the current point is
  never leaves it.
- **What only the host knows is asked for.** How wide a string is in a
  font, and how large an image is, are contract calls that return values.
- **The guest does no layout** (§9.1), so it doesn't know a canvas's size.
  The host asks for the drawing when it has one, as it asks a `Surface`
  for a frame.
- **A recorded drawing is data.** The host can replay it on another
  thread, keep it and replay it when only the appearance changed, or draw
  it at another scale, without calling the guest.
- **The GPU draws it.** That's what this is for: vector graphics that
  stay sharp at any scale and cost the CPU little to show. A recording is
  what a GPU renderer wants. The host turns its paths into geometry once,
  keeps the buffers, and draws them again each frame for nothing more than
  the draw calls, until the guest sends another.

## For a guest

### In SwiftUI

```swift
import SwiftUI

struct Gauge: View {

    var value: Double

    var body: some View {
        Canvas { context, size in
            let bounds = Rect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            context.setLineWidth(12)
            context.setLineCap(.round)

            context.setStrokeColor(.gray.opacity(0.3))
            context.addArc(center: bounds.center, radius: bounds.width / 2,
                           startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.strokePath()

            context.setStrokeColor(.accentColor)
            context.addArc(center: bounds.center, radius: bounds.width / 2,
                           startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * value,
                           clockwise: false)
            context.strokePath()

            context.setFont(.system(size: 28, weight: .semibold))
            context.setFillColor(.primary)
            context.draw("\(Int(value * 100))%", at: bounds.center, anchor: .center)
        }
        .frame(width: 120, height: 120)
    }
}
```

- `Canvas` is a view: SwiftUI lays it out, layers it and clips it like any
  other. Its closure runs when the host has a size for it, and again when
  the size, the scale or the user's text size changes.
- A value the closure reads is observed, as in `body`: changing `value`
  redraws this canvas and nothing else.
- Named colors (`.primary`, `.accentColor`) cross by name. When the
  appearance changes the host draws the same recording with the new
  colors; the closure isn't called.
- A custom shape is a path:

  ```swift
  struct Triangle: Shape {
      func path(in rect: Rect) -> Path {
          var path = Path()
          path.move(to: Point(x: rect.midX, y: rect.minY))
          path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
          path.addLine(to: Point(x: rect.minX, y: rect.maxY))
          path.closeSubpath()
          return path
      }
  }

  Triangle().fill(.orange)
  ```

### Off screen

```swift
import DynamicDrawing

guard let context = BitmapContext(width: 256, height: 256, scale: 2) else { return }
context.setFillColor(Color(red: 0.1, green: 0.1, blue: 0.12))
context.fill(Rect(x: 0, y: 0, width: 256, height: 256))
context.setFillColor(.white)
context.addEllipse(in: Rect(x: 64, y: 64, width: 128, height: 128))
context.fillPath()

let image = context.makeImage()          // to show, or draw elsewhere
let png = try await context.png()         // bytes, for a file or an upload
let pixels = try await context.pixels()   // RGBA, 512 by 512
```

- `BitmapContext` needs no view and no window, though `DynamicDrawing`
  imports the frontend for its types.
- `makeImage()` is the bitmap as it is now, as an `Image`: a view
  (`image.resizable()`), or something to draw in another context.
- Reading bytes back is asynchronous, for the browser's sake (below).

## Names

CoreGraphics' names without the prefix. Where SwiftUI already has the
unprefixed name for the same thing, it's that one type, so a file that
imports both sees no clash.

| CoreGraphics | Here | Notes |
|---|---|---|
| `CGFloat` | `Double` | |
| `CGPoint`, `CGSize`, `CGRect`, `CGVector` | `Point`, `Size`, `Rect`, `Vector` | |
| `CGAffineTransform` | `AffineTransform` | |
| `CGContext` | `GraphicsContext` | SwiftUI's name for what `Canvas` hands over |
| bitmap `CGContext` | `BitmapContext` | a `GraphicsContext` |
| `CGPath`, `CGMutablePath` | `Path` | a value type, as in SwiftUI |
| `CGColor` | `Color` | the frontend's |
| `CGFont` + a size, `CTFont` | `Font` | the frontend's |
| `CGImage` | `Image` | the frontend's, with more sources here; also a view |
| `CGGradient` | `Gradient` | |
| `CGLineCap`, `CGLineJoin` | `LineCap`, `LineJoin` | |
| `CGPathFillRule` | `FillRule` | `.winding`, `.evenOdd` |
| `CGPathDrawingMode` | `DrawingMode` | |
| `CGBlendMode` | `BlendMode` | |

`Color`, `Font` and `Image` stay in `DynamicSwiftUI`, where they are
today, and so do `Point`, `Size`, `Rect`, `Vector` and `AffineTransform`
when they come. `DynamicDrawing` imports the frontend and draws with them
([What this changes](#what-this-changes)).

No type has a `CG` name. Where source written for Apple's frameworks
needs one to compile, it's a type alias and nothing more, as the
frontend's `CGFloat` is today. The frontend adds `CGPoint`, `CGSize`,
`CGRect` and `CGAffineTransform`, since SwiftUI's own API is spelled with
them. `DynamicDrawing` itself has none.

## The context

`GraphicsContext` is a class with CoreGraphics' methods. Code written for
`CGContext` ports by dropping the prefix from its types.

| | |
|---|---|
| State | `saveGState()`, `restoreGState()` |
| Transform | `translateBy(x:y:)`, `scaleBy(x:y:)`, `rotate(by:)`, `concatenate(_:)`, `ctm` |
| Stroke | `setLineWidth`, `setLineCap`, `setLineJoin`, `setMiterLimit`, `setLineDash(phase:lengths:)`, `setStrokeColor` |
| Fill | `setFillColor`, `setAlpha`, `setBlendMode`, `setShadow(offset:blur:color:)`, `setShouldAntialias` |
| Path | `beginPath`, `move(to:)`, `addLine(to:)`, `addCurve(to:control1:control2:)`, `addQuadCurve(to:control:)`, `addArc(center:radius:startAngle:endAngle:clockwise:)`, `addArc(tangent1End:tangent2End:radius:)`, `addRect`, `addEllipse(in:)`, `addPath`, `closePath`, `currentPoint`, `path`, `boundingBoxOfPath` |
| Paint | `fillPath(using:)`, `strokePath()`, `drawPath(using:)`, `fill(_:)`, `stroke(_:)`, `fillEllipse(in:)`, `strokeEllipse(in:)`, `clear(_:)` |
| Clip | `clip(using:)`, `clip(to:)` |
| Gradient | `drawLinearGradient(_:start:end:options:)`, `drawRadialGradient(_:startCenter:startRadius:endCenter:endRadius:options:)` |
| Layer | `beginTransparencyLayer()`, `endTransparencyLayer()` |
| Image | `draw(_ image:in:)` |
| Text | `setFont`, `draw(_ text:at:anchor:)`, `draw(_ text:in:alignment:)` |

Where it differs from CoreGraphics:

- **The origin is the top left and y goes down, in points**, as in UIKit,
  SwiftUI and Silica. The host applies the scale.
- **An image draws upright.** CoreGraphics draws it bottom-up in a flipped
  context; here `draw(_:in:)` fills the rect as SwiftUI does.
- **Arcs keep CoreGraphics' arithmetic.** With y down, `clockwise: true`
  looks counterclockwise, as it does in a flipped `CGContext` and in
  SwiftUI's `Path`. Ported code draws what it drew.
- **Text is a string and a `Font`**, laid out by the host. There are no
  glyphs in this version (below).
- **Nothing is read from the context but its own state**: `ctm`,
  `currentPoint` and the path are kept in the guest.

SwiftUI's own spellings that cost nothing are there too, on the same
class: `fill(_ path:with:)`, `stroke(_ path:with:lineWidth:)`,
`stroke(_ path:with:style:)`, `clip(to:)`, `opacity`, and `drawLayer`.
SwiftUI's context is a value, and copying it scopes a change. This one is
a reference, so that code uses `saveGState()` or `drawLayer`.

`Path` is the guest's own: lines, quadratic and cubic curves, with
rectangles, rounded rectangles, ellipses and arcs added as curves. It
answers `boundingRect`, `contains(_:using:)`, `applying(_:)` and
`isEmpty` without the host.

## In SwiftUI

- **`Canvas`** makes a `DrawingCanvas` and puts a `Canvas` node in the
  render tree with the canvas's `identifier()`, as `GLSurface` carries a
  surface's. A player that doesn't know the node shows a placeholder
  (§9.2).
- **The host asks for the drawing** with the canvas's size in points and
  its scale. The frontend runs the closure with a recording context and
  returns the bytes.
- **Redrawing.** The frontend calls `setNeedsDisplay()` when the view's
  body is evaluated again with a canvas already there, and when a value
  the closure read changes. The host asks again before its next frame.
  The host asks by itself when the size, scale or text size changes, and
  never for an appearance change.
- **A `Shape` with `path(in:)`** is a canvas whose drawing is its path,
  filled or stroked. The five built-in shapes stay the nodes they are.
- **`Image`** gains sources besides a name and a symbol: a file
  (`Image(contentsOf:)`), bytes (`Image(data:)`,
  `Image(pixels:width:height:scale:)`), and later a bitmap context's
  `makeImage()`. In the tree such an image is its `DrawingImage`'s
  identifier ([Showing it](#showing-it)).
- **A canvas isn't a `Surface`.** The guest calls no GL in it, and gets no
  frame callback. The host's renderer draws it, in the host's context.
- Not in this version: redrawing every frame (`TimelineView`), gestures
  inside a canvas beyond the frontend's taps, and drawing a SwiftUI view
  into a context. Animation isn't a goal yet; a game's frames are a
  [`Surface`](Graphics.md)'s.

## A drawing

The bytes a context records. Little-endian; every number a 32-bit float
unless said otherwise.

```
"RTDR"  version: u8 (1)  reserved: 3 bytes
then commands:  opcode: u8   length: unsigned LEB128   payload
```

- **Add-only.** A command a host doesn't know is skipped by its length,
  and the host says so once in its log.
- **32-bit floats** halve what crosses, and are what a GPU takes. The
  guest computes in `Double` and narrows as it writes.
- **Curves stay curves.** The host flattens them for the scale it draws
  at, so a drawing is as sharp at 3x as at 1x.

| Opcode | Command | Payload |
|---|---|---|
| `0x01` | save | |
| `0x02` | restore | |
| `0x03` | concatenate | `a b c d tx ty` |
| `0x04` | alpha | value |
| `0x05` | blend mode | `u8` |
| `0x06` | antialias | `u8` |
| `0x07` | fill color | color |
| `0x08` | stroke color | color |
| `0x09` | stroke style | width, cap `u8`, join `u8`, miter limit, dash phase, count `u16`, lengths |
| `0x0A` | shadow | offset `x y`, blur, color; an empty payload removes it |
| `0x0B` | font | a `DrawingFont`'s identifier, `u32` |
| `0x10` | fill | rule `u8`, path |
| `0x11` | stroke | path |
| `0x12` | clip | rule `u8`, path |
| `0x13` | clear | rect |
| `0x14` | image | a `DrawingImage`'s identifier `u32`, rect |
| `0x15` | text at a point | point, anchor `u8`, string |
| `0x16` | text in a rect | rect, alignment `u8`, string |
| `0x17` | linear gradient | gradient, start, end, options `u8` |
| `0x18` | radial gradient | gradient, start center and radius, end center and radius, options `u8` |
| `0x19` | begin layer | |
| `0x1A` | end layer | |

- **A path** is a `u32` count and its elements: a verb (`0` move, `1`
  line, `2` quadratic, `3` cubic, `4` close) and its points. It's written
  in full where it's used.
- **A color** is `0` and `red green blue alpha` in sRGB, not premultiplied,
  or `1`, an opacity and a string: a named color, which the host resolves
  for the appearance it's drawing in.
- **A gradient** is a `u16` count of stops, each a location and a color.
- **A string** is a `u32` length and UTF-8.
- **A rect** is `x y width height`.
- **Fonts and images are host objects**, named by identifier. The guest's
  context keeps their proxies for as long as it or its drawing lives, and
  a host resolves identifiers when it receives a drawing.

## The contracts

```swift
/// A view the guest draws. `Canvas` carries its `identifier()`.
@DynamicRuntime("org.pureswift.drawing.Canvas")
public protocol DrawingCanvas: AnyObject {

    static func make(_ delegate: DrawingCanvasDelegate) -> Self

    func identifier() -> Int32

    /// The host asks for the drawing again before its next frame.
    func setNeedsDisplay()
}

@DynamicCallback("org.pureswift.drawing.CanvasDelegate")
public protocol DrawingCanvasDelegate: AnyObject {

    /// The drawing for a canvas `width` by `height` points.
    func draw(_ canvas: DrawingCanvas, width: Float, height: Float, scale: Float) -> [UInt8]
}

/// Pixels the guest draws into, off screen.
@DynamicRuntime("org.pureswift.drawing.Bitmap")
public protocol DrawingBitmap: AnyObject {

    /// `width` and `height` in points. Nil when the host refuses the size.
    static func make(width: Float, height: Float, scale: Float, opaque: Bool) -> Self?

    /// Replays a drawing over what's there.
    func draw(_ drawing: [UInt8])

    /// What's there now, as an image that won't change.
    func image() -> DrawingImage

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top.
    func pixels(_ callback: DrawingCallback)

    func png(_ callback: DrawingCallback)
}

/// An image the host holds: a resource, decoded bytes or a bitmap's.
/// Superseded by the image part: see "The contract, now".
@DynamicRuntime("org.pureswift.drawing.Image")
public protocol DrawingImage: AnyObject {

    /// From the app's bundle. Loaded when it's first needed.
    static func named(_ name: String) -> Self

    /// PNG on every host, JPEG where the host decodes it.
    static func decode(_ data: [UInt8]) -> Self

    /// RGBA as `DrawingBitmap.pixels` gives it.
    static func make(pixels: [UInt8], width: Int32, height: Int32, scale: Float) -> Self?

    func identifier() -> Int32

    /// Loads or decodes it if that hasn't happened, then `didMeasure`.
    func size(_ callback: DrawingCallback)
}

/// A font at a size, for drawing and measuring text.
@DynamicRuntime("org.pureswift.drawing.Font")
public protocol DrawingFont: AnyObject {

    /// `name` is a font's name, or nil for the system's with `style`,
    /// `weight` and `design` as the frontend's `Font` has them.
    static func make(name: String?, size: Float, style: Int32, weight: Int32, design: Int32) -> Self

    func identifier() -> Int32

    /// Ascent, descent, leading, cap height and x height, in points:
    /// five floats, as a drawing writes them.
    func metrics() -> [UInt8]

    /// Width and height of `text`, wrapped at `maxWidth` when it's over
    /// 0: two floats.
    func measure(_ text: String, maxWidth: Float) -> [UInt8]
}

@DynamicCallback("org.pureswift.drawing.Callback")
public protocol DrawingCallback: AnyObject {
    func didRead(_ data: [UInt8])
    func didMeasure(width: Float, height: Float, scale: Float)
    func didFail(_ code: Int32, message: String)
}
```

A contract carries scalars, strings, bytes and objects, and no array of
floats, so a font answers in bytes.

### Why some answers wait

A browser decodes an image asynchronously, so a bitmap whose drawing uses
one can't be read until it has loaded, and an image's size isn't known
when it's made. So:

- **`image.size`, `context.pixels()` and `context.png()` are `async
  throws`** in the guest. On the other hosts they answer at once.
- **Making an image never waits or fails.** One that can't be loaded
  draws nothing, the host says so in its log, and its `size` throws.
- **Drawing never waits.** A canvas whose image arrives later is drawn
  again by the host.
- **Text measurement returns its value.** Every host, the browser
  included, measures synchronously, and a layout written in a drawing
  closure needs it to.

## Text and fonts

- **A `Font` is the frontend's:** a text style the platform scales
  (`.body`), the system font at a size, weight and design, or, new here, a
  font by name (`Font(name:size:)`).
- **The host lays text out:** shaping, fallback for missing characters,
  and line breaking for `draw(_:in:alignment:)`. A string drawn at a
  point is one line.
- **Measured and drawn alike.** `font.measure(_:maxWidth:)` is what
  `draw` will occupy on that host. It isn't the same number on another
  host: text is the platform's.
- **Not in this version:** glyph indexes and positions, text along a
  path, and fonts shipped in the bundle.

## Images

- **Sources:** a bundle resource by name, a symbol by name (as today), a
  file, encoded bytes, raw pixels, and a bitmap context.
- **Formats:** PNG and JPEG everywhere, decoded by the platform
  ([the image part's host](#for-a-host)). Silica's own decoders, when it has them,
  are for a host whose platform has none.
- **`draw(_:in:)` scales to the rect**, with the host's default
  interpolation. An image has a scale, so its `size` is in points. A
  file image is decoded for the pixels the rect covers, as it is for a
  view.

## Color and scale

- **sRGB, 8 bits a channel** in a bitmap. Components outside 0...1 are
  clamped. Wide color isn't in this version.
- **Named colors** are the frontend's names and follow the appearance. A
  bitmap context draws them light unless it's made with `appearance:
  .dark`.
- **A bitmap's size is in points.** Its pixels are `width * scale` by
  `height * scale`, rounded up.

## Errors and limits

- `BitmapContext.init` is nil when the host refuses the size. Every host
  takes 4096 pixels on a side; some take more.
- A malformed drawing stops being replayed where it's wrong. What was
  drawn before stays, and the host says so in its log. The guest's own
  context can't write one.
- `restoreGState()` without a matching save is ignored, as are a
  degenerate rect and an empty path.
- `DrawingError`, for the calls that throw: `notFound`, `undecodable`,
  `tooLarge`, `unavailable`, `unknown`.

## Threading

- A context is used on the guest's thread, the main one. The contracts
  are called there and the delegate's `draw` arrives there.
- A host may replay a drawing on another thread: it's immutable bytes and
  identifiers of host objects that are immutable too.
- A bitmap's commands are replayed in the order they were sent, and a
  read sees every one sent before it.
- Reading a bitmap back waits for the GPU to finish it, which is one more
  reason `pixels()` and `png()` answer through a callback.

## For a host

`RuntimeDrawing`, in this package, implements the five contracts for any
host written in Swift, as `RuntimeCoreModel` does the model store's:

- **`DrawingPlayer`** decodes a drawing and replays it into any Silica
  `CGContext`. One decoder, tested once.
- **`DrawingBackend`** is what a host supplies: a context for a view or
  for a render target of a size, fonts, image decoding and PNG encoding,
  and a named color for an appearance.
- **The canvas view is the player's.** It asks the delegate for a drawing
  and plays it into the context its toolkit gives it.
- **What a host builds from a drawing, it keeps:** flattened paths, vertex
  buffers, gradient ramps and glyphs, until the canvas's next drawing
  arrives or the scale changes. Showing an unchanged canvas again is draw
  calls only.

### Drawn by the GPU

Silica's backends today, and what rasterizes in each:

| Backend | Rasterizes | |
|---|---|---|
| `SilicaAndroid`, a canvas from a view's draw pass | GPU | Android's own renderer. `init(canvas:)` takes it as it is |
| `SilicaAndroid`, `init(bitmap:)` | CPU | a `Bitmap`'s canvas is software |
| `SilicaWeb` | GPU, in the browsers that accelerate canvas | |
| `SilicaCairo` | CPU | Cairo image surfaces. Cacao draws content with it and composites the layers on the GPU |
| `SilicaCoreGraphics` | CPU | Core Animation composites the result on the GPU |

So only Android's on-screen canvas and the browser are drawn by a GPU
today. The rest need a renderer Silica doesn't have:

- **`SilicaGL`, a new Silica backend: its `CGContext` over OpenGL ES 2.0.**
  It's the one graphics API every AppRuntime host has, since `Surface`
  needs it ([Graphics](Graphics.md)): EAGL on iOS and OpenGL 2.1 on
  macOS in the Darwin host, EGL on Android and Linux, WebGL 1 in a
  browser. One renderer then draws the same way on all of them, on
  screen and off.
- **How it draws.** None of this is built or measured yet:
  - Paths are flattened and strokes widened into triangles in Swift, with
    no dependency, as Silica's 3DS backend rasterizes in Swift today.
  - Fills use the stencil buffer: both fill rules, and any path, without
    triangulating it.
  - Clips are scissor rectangles where they can be, the stencil otherwise.
  - Gradients are a shader and a ramp texture. Images are textured quads.
  - Transparency layers are framebuffer objects.
  - Text is the platform's glyphs, rasterized once into a texture and
    drawn as quads: the font engine stays the host's (CoreText, FreeType,
    `Typeface`).
  - Edges are smoothed by multisampling where the context has it, and by
    a feathered edge in the geometry where it doesn't.
- **Where each host draws:**

| Host | On screen | Off screen (`DrawingBitmap`) |
|---|---|---|
| Android | the view's hardware canvas, through `SilicaAndroid` | `SilicaGL` in an EGL pbuffer; a `Bitmap`'s canvas until then |
| Linux | `SilicaGL`, into a texture Cacao's compositor shows; `SilicaCairo` until then | `SilicaGL` in a framebuffer object; `SilicaCairo` until then |
| iOS / macOS | `SilicaGL` on the GL the Darwin host gives a `Surface`, or a Metal backend later; `SilicaCoreGraphics` until then | the same |
| Browser | a second player in JavaScript, on `CanvasRenderingContext2D` | `OffscreenCanvas` |

- **A CPU backend is a correct host, only a slower one.** The contract
  says what's drawn, not what draws it, so a host can ship on Cairo or
  CoreGraphics and move to the GPU without a guest changing.
- **The same drawing, not the same pixels.** Renderers smooth edges and
  place text differently. A guest that needs exact pixels reads them
  back from the host it's on.

### What Silica gets

Added to Silica, where its backends can do it:

- **Gradients** and **blend modes** in the `CGContext` protocol. It has
  neither. Cairo, CoreGraphics, Android's `Canvas` and the web canvas
  each do, and `SilicaGL` would. A blend mode a backend can't do draws
  as `normal`.
- **Text from a string**, with the platform's shaping and fallback. Silica
  maps scalars to glyphs one by one, which is wrong for scripts that
  shape.
- **Android below API 31.** `SilicaAndroid` draws glyphs with
  `Canvas.drawGlyphs`, which is API 31, and the example manifest's
  minimum is 26. Drawing a string with `Canvas.drawText` needs none of
  it.
- **`SilicaGL`**, above.
- **A JPEG decoder,** or the platform's where there is one.

Its package also lists Cairo, FontConfig, swift-java and JavaScriptKit
for its backends, and SwiftPM would fetch them all for AppRuntime, which
needs only the `Silica` module. That's for Silica's package to solve
(traits, or a package for the core).

## Not in this design

- PDF contexts. Silica has them; a guest would need somewhere to put the
  file, which is the [Files](Files.md) contract's.
- Patterns, masks, image masks and soft clipping.
- Filters and reading pixels of a canvas on screen.
- Color spaces other than sRGB.
- Glyph-level text, text paths and bundled fonts.
- Animation driven by the host's frame clock.

## Alternatives weighed

- **A contract call per operation.** The simplest host, and the slowest
  guest: every `addLine` crosses. Recording is a few hundred lines in the
  guest and a decoder in the host.
- **Silica itself in the guest**, with a recording backend. Its core
  module builds for Embedded Swift, so this works, and the guest would
  get CoreGraphics' names exactly. It keeps the `CG` prefix, defines
  `CGPoint` and `CGFloat` again beside the frontend's, and makes Silica's
  types part of what an app is compiled against. The host half of this
  design is that idea: Silica is where drawings are replayed.
- **The GL renderer in the guest**, drawing into a `Surface`. It needs no
  new contract: the guest has GLES 2.0 already. But every app's slice
  would carry the renderer, it would have no fonts or image decoders
  without contracts for those anyway, GL is callable only inside a frame,
  and a host with a better renderer of its own (Android, a browser)
  couldn't use it.
- **Rasterizing in the guest.** Silica's 3DS backend is a rasterizer in
  pure Swift that builds for Embedded Swift. It would need no contract,
  and would have no fonts, no image codecs and no GPU, in every app's
  slice.

## Decided in review

- The context is **`GraphicsContext`**.
- **No `CG` names.** A type alias where compatibility needs one: the
  frontend's, for SwiftUI's spellings.
- The module is **`DynamicDrawing`**, and `Color`, `Font` and `Image`
  live in it. The image part proposes keeping them in the frontend
  ([What this changes](#what-this-changes)).
- **Silica is the host's renderer,** and what it lacks is added to it.
- **Animation isn't a goal yet.**
- **It's for vector graphics drawn by the GPU.**

## Questions left

1. **A stateful context in `Canvas`.** The closure gets CoreGraphics'
   model, not SwiftUI's value type. Code written for SwiftUI's `Canvas`
   that copies its context needs changes.
2. **Asynchronous reads.** `pixels()`, `png()` and `image.size` are
   `async`, for the browser and for reading back from a GPU.
3. **`SilicaGL` on OpenGL ES 2.0.** It's the one API every host has. But
   Apple has deprecated OpenGL on its platforms, and GLES 2.0 has no
   multisampled framebuffer objects without an extension. Is GLES 2.0 the
   target, with Metal later for Apple, or should Apple be Metal from the
   start?
4. **What comes first.** A host can draw correctly on Cairo or
   CoreGraphics before `SilicaGL` exists. Is that order acceptable: the
   guest API, the format and the player on the backends Silica has, then
   the GL backend?

For the image part:

5. **Keeping `Color`, `Font` and `Image` in the frontend,** which reverses
   a reviewed decision so that a SwiftUI app doesn't declare drawing
   contracts ([What this changes](#what-this-changes)).
6. **Decoding at the size drawn,** chosen by the host, with
   `maximumPixelSize` as the guest's only say. The other way is a guest
   that asks for a size and decodes again when the scale it hears
   changes, which it can't choose well without layout.
7. **`zoomable(_:scale:)`,** a spelling of the frontend's own, since
   SwiftUI has none.
