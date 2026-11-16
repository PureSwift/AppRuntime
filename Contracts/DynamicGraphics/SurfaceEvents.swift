/// A `SurfaceDelegate` that calls closures with Swift values, and keeps the
/// input state a game reads each frame.
///
/// ```swift
/// let events = SurfaceEvents()
/// events.onFrame = { frame in
///     if events.isPressed(.space) { jump() }
///     draw(frame)
/// }
/// let surface = SurfaceProxy.make(events)
/// ```
///
/// It's guest-side only; hosts never see it.
public final class SurfaceEvents: SurfaceDelegate {

    // MARK: Drawing

    public var onFrame: ((SurfaceFrame) -> Void)?

    /// The drawable's new size in pixels, and pixels per point.
    public var onResize: ((_ width: Int32, _ height: Int32, _ scale: Float) -> Void)?

    public var onContextLost: (() -> Void)?

    public var onContextRestored: (() -> Void)?

    // MARK: Input

    public var onPointer: ((PointerEvent) -> Void)?

    /// Captured mouse movement, in pixels.
    public var onPointerDelta: ((_ x: Float, _ y: Float) -> Void)?

    public var onScroll: ((_ x: Float, _ y: Float) -> Void)?

    public var onKey: ((KeyEvent) -> Void)?

    public var onFocus: ((Bool) -> Void)?

    public var onPointerCapture: ((Bool) -> Void)?

    // MARK: State

    /// The drawable's size in pixels and its pixels per point, from the last
    /// `resize`. Zero until the first one.
    public private(set) var width: Int32 = 0
    public private(set) var height: Int32 = 0
    public private(set) var scale: Float = 1

    public private(set) var isFocused = false

    public private(set) var isPointerCaptured = false

    /// The pointers in contact (or the mouse, wherever it last was), by ID.
    public private(set) var pointers: [Int32: PointerEvent] = [:]

    /// The keys held, by HID usage ID.
    private var pressed: Set<Int32> = []

    public init() { }

    public func isPressed(_ key: KeyCode) -> Bool {
        pressed.contains(key.rawValue)
    }

    // MARK: SurfaceDelegate

    public func frame(_ surface: any Surface, timestamp: Int64, width: Int32, height: Int32) {
        onFrame?(SurfaceFrame(timestamp: timestamp, width: width, height: height))
    }

    public func resize(_ surface: any Surface, width: Int32, height: Int32, scale: Float) {
        self.width = width
        self.height = height
        self.scale = scale
        onResize?(width, height, scale)
    }

    public func contextLost(_ surface: any Surface) {
        onContextLost?()
    }

    public func contextRestored(_ surface: any Surface) {
        onContextRestored?()
    }

    public func pointer(
        _ surface: any Surface,
        id: Int32, kind: Int32, phase: Int32,
        x: Float, y: Float,
        buttons: Int32,
        timestamp: Int64
    ) {
        // A newer host may send kinds this guest doesn't know: a pointer is
        // at least a touch.
        let event = PointerEvent(
            id: id,
            kind: PointerKind(rawValue: kind) ?? .touch,
            phase: PointerPhase(rawValue: phase) ?? .cancel,
            x: x, y: y,
            buttons: PointerButtons(rawValue: buttons),
            timestamp: timestamp
        )
        switch event.phase {
        case .down, .move:
            pointers[id] = event
        case .up:
            // The mouse stays, hovering; a lifted touch is gone.
            if event.kind == .mouse {
                pointers[id] = event
            } else {
                pointers[id] = nil
            }
        case .cancel:
            pointers[id] = nil
        }
        onPointer?(event)
    }

    public func pointerDelta(_ surface: any Surface, x: Float, y: Float, timestamp: Int64) {
        onPointerDelta?(x, y)
    }

    public func scroll(_ surface: any Surface, x: Float, y: Float) {
        onScroll?(x, y)
    }

    public func key(
        _ surface: any Surface,
        code: Int32, pressed isPressed: Bool,
        modifiers: Int32,
        isRepeat: Bool,
        timestamp: Int64
    ) {
        if isPressed {
            pressed.insert(code)
        } else {
            pressed.remove(code)
        }
        onKey?(KeyEvent(
            code: KeyCode(rawValue: code),
            pressed: isPressed,
            modifiers: KeyModifiers(rawValue: modifiers),
            isRepeat: isRepeat,
            timestamp: timestamp
        ))
    }

    public func focus(_ surface: any Surface, focused: Bool) {
        isFocused = focused
        if !focused {
            // No key-up events follow a lost focus (§8.6).
            pressed.removeAll()
        }
        onFocus?(focused)
    }

    public func pointerCapture(_ surface: any Surface, captured: Bool) {
        isPointerCaptured = captured
        onPointerCapture?(captured)
    }
}
