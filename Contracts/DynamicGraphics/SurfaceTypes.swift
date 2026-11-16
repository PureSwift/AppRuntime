/// Guest-side names for the integer codes `SurfaceDelegate` carries.

/// What a pointer is.
public enum PointerKind: Int32, Sendable {
    case touch = 0
    case mouse = 1
    case pen = 2
}

/// Where a pointer is in its life.
public enum PointerPhase: Int32, Sendable {
    /// Contact began, or a mouse button went down with none held.
    case down = 0
    /// It moved. A mouse moves with no button held too.
    case move = 1
    /// Contact ended, or the last held mouse button went up.
    case up = 2
    /// The system took it away (a gesture, a lost focus): undo, don't act.
    case cancel = 3
}

/// The buttons a pointer holds. A touch in contact holds `primary`.
public struct PointerButtons: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static var primary: Self { Self(rawValue: 1) }
    public static var secondary: Self { Self(rawValue: 2) }
    public static var middle: Self { Self(rawValue: 4) }
}

/// The modifier keys held during a key event.
public struct KeyModifiers: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static var shift: Self { Self(rawValue: 1) }
    public static var control: Self { Self(rawValue: 2) }
    /// Alt, or Option on Apple keyboards.
    public static var alt: Self { Self(rawValue: 4) }
    /// Command, the Windows key, Super.
    public static var meta: Self { Self(rawValue: 8) }
}

/// A physical key: a USB HID usage ID from the Keyboard/Keypad page (0x07).
///
/// It names a position, not a character: `.w` is the key above `.s` on
/// every layout, whatever it types. The constants cover what games use; any
/// other usage ID arrives as its raw value.
public struct KeyCode: RawRepresentable, Hashable, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    // Letters, by their position on a US keyboard.
    public static var a: Self { Self(rawValue: 0x04) }
    public static var b: Self { Self(rawValue: 0x05) }
    public static var c: Self { Self(rawValue: 0x06) }
    public static var d: Self { Self(rawValue: 0x07) }
    public static var e: Self { Self(rawValue: 0x08) }
    public static var f: Self { Self(rawValue: 0x09) }
    public static var g: Self { Self(rawValue: 0x0A) }
    public static var h: Self { Self(rawValue: 0x0B) }
    public static var i: Self { Self(rawValue: 0x0C) }
    public static var j: Self { Self(rawValue: 0x0D) }
    public static var k: Self { Self(rawValue: 0x0E) }
    public static var l: Self { Self(rawValue: 0x0F) }
    public static var m: Self { Self(rawValue: 0x10) }
    public static var n: Self { Self(rawValue: 0x11) }
    public static var o: Self { Self(rawValue: 0x12) }
    public static var p: Self { Self(rawValue: 0x13) }
    public static var q: Self { Self(rawValue: 0x14) }
    public static var r: Self { Self(rawValue: 0x15) }
    public static var s: Self { Self(rawValue: 0x16) }
    public static var t: Self { Self(rawValue: 0x17) }
    public static var u: Self { Self(rawValue: 0x18) }
    public static var v: Self { Self(rawValue: 0x19) }
    public static var w: Self { Self(rawValue: 0x1A) }
    public static var x: Self { Self(rawValue: 0x1B) }
    public static var y: Self { Self(rawValue: 0x1C) }
    public static var z: Self { Self(rawValue: 0x1D) }

    /// The top row's digit `digit` (0…9).
    public static func digit(_ digit: Int32) -> Self {
        Self(rawValue: digit == 0 ? 0x27 : 0x1D + digit)
    }

    public static var `return`: Self { Self(rawValue: 0x28) }
    public static var escape: Self { Self(rawValue: 0x29) }
    public static var backspace: Self { Self(rawValue: 0x2A) }
    public static var tab: Self { Self(rawValue: 0x2B) }
    public static var space: Self { Self(rawValue: 0x2C) }
    public static var minus: Self { Self(rawValue: 0x2D) }
    public static var equals: Self { Self(rawValue: 0x2E) }
    public static var leftBracket: Self { Self(rawValue: 0x2F) }
    public static var rightBracket: Self { Self(rawValue: 0x30) }
    public static var backslash: Self { Self(rawValue: 0x31) }
    public static var semicolon: Self { Self(rawValue: 0x33) }
    public static var quote: Self { Self(rawValue: 0x34) }
    public static var grave: Self { Self(rawValue: 0x35) }
    public static var comma: Self { Self(rawValue: 0x36) }
    public static var period: Self { Self(rawValue: 0x37) }
    public static var slash: Self { Self(rawValue: 0x38) }
    public static var capsLock: Self { Self(rawValue: 0x39) }

    /// F1…F12.
    public static func function(_ number: Int32) -> Self {
        Self(rawValue: 0x39 + number)
    }

    public static var insert: Self { Self(rawValue: 0x49) }
    public static var home: Self { Self(rawValue: 0x4A) }
    public static var pageUp: Self { Self(rawValue: 0x4B) }
    /// Forward delete.
    public static var delete: Self { Self(rawValue: 0x4C) }
    public static var end: Self { Self(rawValue: 0x4D) }
    public static var pageDown: Self { Self(rawValue: 0x4E) }
    public static var right: Self { Self(rawValue: 0x4F) }
    public static var left: Self { Self(rawValue: 0x50) }
    public static var down: Self { Self(rawValue: 0x51) }
    public static var up: Self { Self(rawValue: 0x52) }

    public static var leftControl: Self { Self(rawValue: 0xE0) }
    public static var leftShift: Self { Self(rawValue: 0xE1) }
    public static var leftAlt: Self { Self(rawValue: 0xE2) }
    public static var leftMeta: Self { Self(rawValue: 0xE3) }
    public static var rightControl: Self { Self(rawValue: 0xE4) }
    public static var rightShift: Self { Self(rawValue: 0xE5) }
    public static var rightAlt: Self { Self(rawValue: 0xE6) }
    public static var rightMeta: Self { Self(rawValue: 0xE7) }
}

/// One pointer event, as `SurfaceEvents` reports it.
public struct PointerEvent: Equatable, Sendable {

    /// Names one pointer from `down` to `up` or `cancel`.
    public var id: Int32

    public var kind: PointerKind

    public var phase: PointerPhase

    /// Pixels in the surface, from the top left.
    public var x: Float
    public var y: Float

    public var buttons: PointerButtons

    /// Nanoseconds on the `Clock.now()` timeline.
    public var timestamp: Int64

    public init(
        id: Int32, kind: PointerKind, phase: PointerPhase,
        x: Float, y: Float,
        buttons: PointerButtons, timestamp: Int64
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.x = x
        self.y = y
        self.buttons = buttons
        self.timestamp = timestamp
    }
}

/// One key event, as `SurfaceEvents` reports it.
public struct KeyEvent: Equatable, Sendable {

    public var code: KeyCode

    public var pressed: Bool

    public var modifiers: KeyModifiers

    /// The system's auto-repeat of a held key.
    public var isRepeat: Bool

    public var timestamp: Int64

    public init(code: KeyCode, pressed: Bool, modifiers: KeyModifiers, isRepeat: Bool, timestamp: Int64) {
        self.code = code
        self.pressed = pressed
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.timestamp = timestamp
    }
}

/// One frame to draw, as `SurfaceEvents` reports it.
public struct SurfaceFrame: Equatable, Sendable {

    /// Nanoseconds on the `Clock.now()` timeline.
    public var timestamp: Int64

    /// The drawable's size in pixels.
    public var width: Int32
    public var height: Int32

    public init(timestamp: Int64, width: Int32, height: Int32) {
        self.timestamp = timestamp
        self.width = width
        self.height = height
    }
}
