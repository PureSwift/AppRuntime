import Testing
import DynamicGraphics
import DynamicRuntime
import RuntimeNative

/// A host's surface: keeps the delegate to send frames and input, as a
/// player would.
final class TestSurface: Surface {

    nonisolated(unsafe) static var last: TestSurface?

    let delegate: any SurfaceDelegate

    var captured = false

    /// Whether this host has a mouse to capture.
    var hasMouse = true

    init(delegate: any SurfaceDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any SurfaceDelegate) -> TestSurface {
        let surface = TestSurface(delegate: delegate)
        last = surface
        return surface
    }

    func identifier() -> Int32 { 7 }

    func setPointerCaptured(_ captured: Bool) -> Bool {
        guard hasMouse else { return false }
        self.captured = captured
        delegate.pointerCapture(self, captured: captured)
        return captured
    }
}

/// Serialized: the round trip uses the shared native runtime and
/// `TestSurface.last`.
@Suite(.serialized) struct DynamicGraphicsTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    // MARK: Contracts

    @Test func surfaceNeedsTheGraphicsCapability() {
        let surface = SurfaceProxy.descriptor
        #expect(surface.name == "org.pureswift.graphics.Surface")
        #expect(surface.capability == Capability("graphics"))
        #expect(method(surface, "make:")?.kind == .constructor)
        #expect(method(surface, "identifier")?.signature == Signature("()I"), "fits a render node's int prop on wasm32")
        #expect(method(surface, "setPointerCaptured:")?.signature == Signature("(Z)Z"))
    }

    @Test func framesAndInputAreScalars() {
        let delegate = SurfaceDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.graphics.SurfaceDelegate")
        #expect(delegate.kind == .callback)
        #expect(method(delegate, "frame:timestamp:width:height:")?.signature == Signature("(OJII)V"))
        #expect(method(delegate, "resize:width:height:scale:")?.signature == Signature("(OIIF)V"))
        #expect(method(delegate, "pointer:id:kind:phase:x:y:buttons:timestamp:")?.signature == Signature("(OIIIFFIJ)V"))
        #expect(method(delegate, "pointerDelta:x:y:timestamp:")?.signature == Signature("(OFFJ)V"))
        #expect(method(delegate, "scroll:x:y:")?.signature == Signature("(OFF)V"))
        #expect(method(delegate, "key:code:pressed:modifiers:isRepeat:timestamp:")?.signature == Signature("(OIZIZJ)V"))
        #expect(method(delegate, "focus:focused:")?.signature == Signature("(OZ)V"))
        #expect(method(delegate, "pointerCapture:captured:")?.signature == Signature("(OZ)V"))
        #expect(delegate.methods.count == 10)
    }

    @Test func recordsRoundTrip() {
        let descriptors = [SurfaceProxy.descriptor, SurfaceDelegateProxy.descriptor]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Types

    @Test func keyCodesAreHIDUsages() {
        #expect(KeyCode.a.rawValue == 0x04)
        #expect(KeyCode.w.rawValue == 0x1A)
        #expect(KeyCode.z.rawValue == 0x1D)
        #expect(KeyCode.digit(1).rawValue == 0x1E)
        #expect(KeyCode.digit(9).rawValue == 0x26)
        #expect(KeyCode.digit(0).rawValue == 0x27)
        #expect(KeyCode.return.rawValue == 0x28)
        #expect(KeyCode.space.rawValue == 0x2C)
        #expect(KeyCode.function(1).rawValue == 0x3A)
        #expect(KeyCode.function(12).rawValue == 0x45)
        #expect(KeyCode.up.rawValue == 0x52)
        #expect(KeyCode.leftShift.rawValue == 0xE1)
        #expect(KeyCode.rightMeta.rawValue == 0xE7)
        #expect(KeyCode(rawValue: 0x64) != .a, "codes without a name still compare")
    }

    @Test func buttonAndModifierBits() {
        #expect(PointerButtons([.primary, .middle]).rawValue == 5)
        #expect(KeyModifiers([.shift, .meta]).rawValue == 9)
        #expect(KeyModifiers(rawValue: 6) == [.control, .alt])
    }

    // MARK: SurfaceEvents

    @Test func eventsKeepPointerAndKeyState() {
        let events = SurfaceEvents()
        let surface = TestSurface(delegate: events)
        var received: [PointerEvent] = []
        events.onPointer = { received.append($0) }

        events.resize(surface, width: 640, height: 480, scale: 2)
        #expect(events.width == 640 && events.height == 480 && events.scale == 2)

        // Two touches; one lifts, one is cancelled.
        events.pointer(surface, id: 1, kind: 0, phase: 0, x: 10, y: 20, buttons: 1, timestamp: 100)
        events.pointer(surface, id: 2, kind: 0, phase: 0, x: 30, y: 40, buttons: 1, timestamp: 101)
        events.pointer(surface, id: 1, kind: 0, phase: 1, x: 11, y: 21, buttons: 1, timestamp: 102)
        #expect(events.pointers[1]?.x == 11)
        #expect(events.pointers.count == 2)
        events.pointer(surface, id: 1, kind: 0, phase: 2, x: 11, y: 21, buttons: 0, timestamp: 103)
        events.pointer(surface, id: 2, kind: 0, phase: 3, x: 30, y: 40, buttons: 0, timestamp: 104)
        #expect(events.pointers.isEmpty)
        #expect(received.map(\.phase) == [.down, .down, .move, .up, .cancel])
        #expect(received.first == PointerEvent(id: 1, kind: .touch, phase: .down, x: 10, y: 20, buttons: .primary, timestamp: 100))

        // The mouse stays where it was after its button goes up.
        events.pointer(surface, id: 0, kind: 1, phase: 0, x: 5, y: 5, buttons: 2, timestamp: 105)
        events.pointer(surface, id: 0, kind: 1, phase: 2, x: 6, y: 5, buttons: 0, timestamp: 106)
        #expect(events.pointers[0]?.x == 6)
        #expect(received.last?.kind == .mouse)

        // Values a newer host might send.
        events.pointer(surface, id: 9, kind: 77, phase: 77, x: 0, y: 0, buttons: 0, timestamp: 107)
        #expect(received.last?.kind == .touch)
        #expect(received.last?.phase == .cancel)
    }

    @Test func losingFocusReleasesEveryKey() {
        let events = SurfaceEvents()
        let surface = TestSurface(delegate: events)
        var keys: [KeyEvent] = []
        events.onKey = { keys.append($0) }

        events.focus(surface, focused: true)
        events.key(surface, code: KeyCode.w.rawValue, pressed: true, modifiers: 1, isRepeat: false, timestamp: 1)
        events.key(surface, code: KeyCode.w.rawValue, pressed: true, modifiers: 1, isRepeat: true, timestamp: 2)
        events.key(surface, code: KeyCode.space.rawValue, pressed: true, modifiers: 0, isRepeat: false, timestamp: 3)
        #expect(events.isPressed(.w) && events.isPressed(.space))
        #expect(keys[1] == KeyEvent(code: .w, pressed: true, modifiers: .shift, isRepeat: true, timestamp: 2))

        events.key(surface, code: KeyCode.space.rawValue, pressed: false, modifiers: 0, isRepeat: false, timestamp: 4)
        #expect(!events.isPressed(.space))

        events.focus(surface, focused: false)
        #expect(!events.isFocused)
        #expect(!events.isPressed(.w), "no key-up follows a lost focus")
    }

    // MARK: Through the runtime

    /// The guest's proxy and the host's delegate proxy, as in a native slice.
    @Test func surfaceThroughTheRuntime() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        SurfaceProxy.register(TestSurface.self, in: native)
        SurfaceDelegateProxy.registerInterface(in: native)
        TestSurface.last = nil

        let events = SurfaceEvents()
        var frames: [SurfaceFrame] = []
        var deltas: [Float] = []
        var scrolls: [Float] = []
        var lost = 0, restored = 0
        events.onFrame = { frames.append($0) }
        events.onPointerDelta = { x, y in deltas += [x, y] }
        events.onScroll = { x, y in scrolls += [x, y] }
        events.onContextLost = { lost += 1 }
        events.onContextRestored = { restored += 1 }

        let surface = SurfaceProxy.make(events)
        #expect(surface.identifier() == 7)
        let host = try #require(TestSurface.last)

        // Host to guest: every scalar type survives the trip.
        host.delegate.resize(host, width: 1920, height: 1080, scale: 2.5)
        host.delegate.frame(host, timestamp: 0x1_0000_0001, width: 1920, height: 1080)
        #expect(events.scale == 2.5)
        #expect(frames == [SurfaceFrame(timestamp: 0x1_0000_0001, width: 1920, height: 1080)])

        host.delegate.pointer(host, id: 3, kind: 2, phase: 0, x: 0.5, y: -1.25, buttons: 5, timestamp: 9)
        #expect(events.pointers[3] == PointerEvent(id: 3, kind: .pen, phase: .down, x: 0.5, y: -1.25, buttons: [.primary, .middle], timestamp: 9))
        host.delegate.scroll(host, x: 0, y: -12.5)
        #expect(scrolls == [0, -12.5])

        host.delegate.key(host, code: KeyCode.escape.rawValue, pressed: true, modifiers: 8, isRepeat: false, timestamp: 10)
        #expect(events.isPressed(.escape))
        host.delegate.focus(host, focused: false)
        #expect(!events.isPressed(.escape))

        host.delegate.contextLost(host)
        host.delegate.contextRestored(host)
        #expect(lost == 1 && restored == 1)

        // Guest to host, and the host's answer through the delegate.
        #expect(surface.setPointerCaptured(true))
        #expect(host.captured)
        #expect(events.isPointerCaptured)
        host.delegate.pointerDelta(host, x: 3, y: -4, timestamp: 11)
        #expect(deltas == [3, -4])

        host.hasMouse = false
        #expect(!surface.setPointerCaptured(true), "a host without a mouse")
    }
}
