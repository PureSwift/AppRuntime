# Drawing

**Status:** a design, reviewed once (the decisions are at the end).
Nothing here is implemented.

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

Guest-side Swift: `GraphicsContext`, `BitmapContext`, `Path`, `Point`,
`Size`, `Rect`, `AffineTransform`, `Gradient`, `StrokeStyle`, and the
`Color`, `Font` and `Image` the SwiftUI frontend already has. The SwiftUI
frontend adds `Canvas`, and `Shape`s made from a `Path`.

On every host written in Swift the contracts are one module,
`RuntimeDrawing`, which draws with
[Silica](https://github.com/PureSwift/Silica). Silica's `CGContext` is a
protocol with CoreGraphics, Cairo and Android Canvas backends, and this
design adds one over OpenGL ES 2.0 ([Drawn by the GPU](#drawn-by-the-gpu)).

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

- `BitmapContext` needs no view and no SwiftUI: `DynamicDrawing` doesn't
  depend on the frontend.
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
| `CGColor` | `Color` | the frontend's, moved here |
| `CGFont` + a size, `CTFont` | `Font` | the frontend's, moved here |
| `CGImage` | `Image` | the frontend's, moved here; also a view |
| `CGGradient` | `Gradient` | |
| `CGLineCap`, `CGLineJoin` | `LineCap`, `LineJoin` | |
| `CGPathFillRule` | `FillRule` | `.winding`, `.evenOdd` |
| `CGPathDrawingMode` | `DrawingMode` | |
| `CGBlendMode` | `BlendMode` | |

`Color`, `Font` and `Image` are in `DynamicSwiftUI` today. They move to
`DynamicDrawing` with their API unchanged, and the frontend re-exports
them and keeps how each is written in the render tree.

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
- **`Image`** gains two sources besides a name and a symbol: bytes
  (`Image(data:)`, `Image(pixels:width:height:scale:)`) and a bitmap
  context's `makeImage()`. In the tree such an image is its
  `DrawingImage`'s identifier.
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

- **Sources:** a bundle resource by name, a symbol by name (as today),
  encoded bytes, raw pixels, and a bitmap context.
- **Formats:** PNG everywhere. JPEG where the host has a decoder; Silica
  has none of its own yet.
- **`draw(_:in:)` scales to the rect**, with the host's default
  interpolation. An image has a scale, so its `size` is in points.

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
  live in it.
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
