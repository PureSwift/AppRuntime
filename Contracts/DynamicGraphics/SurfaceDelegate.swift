import DynamicRuntime

/// Receives a `Surface`'s frames and input on the main thread.
///
/// Every argument is a scalar, so each call is one dispatch with nothing to
/// release. `SurfaceEvents` wraps them in Swift values.
///
/// Conventions (hosts convert):
/// - Sizes and positions are in pixels of the drawable, with the origin at
///   the top left and y down: the pixels `glViewport` takes.
/// - `timestamp`: nanoseconds on the `Clock.now()` timeline.
/// - The GL context is current only inside `frame`.
@DynamicCallback("org.pureswift.graphics.SurfaceDelegate")
public protocol SurfaceDelegate: AnyObject {

    // MARK: Drawing

    /// Draw one frame. The host presents it when this returns.
    func frame(_ surface: Surface, timestamp: Int64, width: Int32, height: Int32)

    /// The drawable's size changed, or is known for the first time; it comes
    /// before the first `frame` that uses it. `scale` is pixels per point.
    func resize(_ surface: Surface, width: Int32, height: Int32, scale: Float)

    /// The GL context is gone, with every GL object the guest made in it.
    func contextLost(_ surface: Surface)

    /// There's a new, empty context: make the GL objects again.
    func contextRestored(_ surface: Surface)

    // MARK: Input

    /// A touch, the mouse or a pen. `kind` is a `PointerKind`, `phase` a
    /// `PointerPhase` and `buttons` a `PointerButtons` raw value. `id` names
    /// one pointer from `down` to `up` or `cancel`; the mouse is 0.
    ///
    /// The host sends at most one `move` per pointer per frame.
    func pointer(
        _ surface: Surface,
        id: Int32, kind: Int32, phase: Int32,
        x: Float, y: Float,
        buttons: Int32,
        timestamp: Int64
    )

    /// Mouse movement while the pointer is captured, in pixels. At most one
    /// per frame.
    func pointerDelta(_ surface: Surface, x: Float, y: Float, timestamp: Int64)

    /// A wheel or trackpad scroll: how far content under the pointer should
    /// move, in pixels, with the user's scroll direction applied.
    func scroll(_ surface: Surface, x: Float, y: Float)

    /// A key went down or up. `code` is a `KeyCode` raw value: a USB HID
    /// usage ID, which names a physical key whatever the layout.
    /// `modifiers` is a `KeyModifiers` raw value. Keys carry no text: text
    /// entry is a `TextField`'s job.
    func key(
        _ surface: Surface,
        code: Int32, pressed: Bool,
        modifiers: Int32,
        isRepeat: Bool,
        timestamp: Int64
    )

    /// The surface gained or lost keyboard focus. Before a loss the host
    /// sends `cancel` for every pointer in contact; after it, every key
    /// counts as released, and no key-up events follow.
    func focus(_ surface: Surface, focused: Bool)

    /// Pointer capture began or ended, by `setPointerCaptured` or by the
    /// host (Escape in a browser, the app losing focus).
    func pointerCapture(_ surface: Surface, captured: Bool)
}
