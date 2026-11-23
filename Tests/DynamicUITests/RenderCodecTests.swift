import Testing
import DynamicUI
import DynamicRuntime
import RuntimeNative

/// The render IR's binary encoding (§9.2) and the renderer contract.
@Suite struct RenderCodecTests {

    static let tree = RenderNode("VStack", id: 1, props: [
        "alignment": "leading",
        "spacing": 8.0,
    ], modifiers: [
        ModifierNode("padding", ["top": 16.0, "leading": 16.0, "bottom": 16.0, "trailing": 16.0]),
        ModifierNode("background", ["color": "red"]),
    ], children: [
        RenderNode("Text", id: 0xFFFF_FFFF_FFFF_FFFF, props: ["text": "héllo"]),
        RenderNode("Slider", id: 3, props: ["value": .double(-0.5), "max": .double(.infinity)]),
        RenderNode("Stepper", id: 4, props: ["value": .int(-42), "step": .int(Int.max), "min": .int(Int.min)]),
        RenderNode("Toggle", id: 5, props: ["isOn": true, "tags": .array(["a", 1, .array([false])])]),
        RenderNode("List", id: 6, props: ["revision": 3], count: 0),
        RenderNode("List", id: 7, count: 1000),
    ])

    @Test func treesRoundTrip() throws {
        let bytes = RenderCodec.encode(Self.tree)
        #expect(Array(bytes.prefix(3)) == [0x52, 0x4E, RenderCodec.version])
        #expect(try RenderCodec.decode(bytes) == Self.tree)
    }

    @Test func encodingIsDeterministicAndCompact() {
        let first = RenderCodec.encode(Self.tree)
        var reordered = Self.tree
        reordered.props = ["spacing": 8.0, "alignment": "leading"]
        #expect(RenderCodec.encode(reordered) == first, "props are sorted")

        // Repeated strings are stored once.
        let rows = RenderNode("VStack", id: 1, children: (0..<100).map {
            RenderNode("Text", id: UInt64($0), props: ["text": "same"])
        })
        let size = RenderCodec.encode(rows).count
        #expect(size < 100 * 17, "\(size) bytes for 100 rows: 16 per row")
    }

    @Test func payloadsAndIDsRoundTrip() throws {
        for value: PropValue in ["text", 1.5, true, -7, .array(["a", 2])] {
            #expect(try RenderCodec.decode(payload: RenderCodec.encode(payload: value)) == value)
        }
        let id: RenderNode.ID = 0x0102_0304_0506_0708
        #expect(RenderCodec.encode(id: id) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(try RenderCodec.decode(id: RenderCodec.encode(id: id)) == id)
    }

    @Test func badInputThrows() {
        let bytes = RenderCodec.encode(Self.tree)
        #expect(throws: RenderDecodingError.notARenderTree) { try RenderCodec.decode([0, 0, 1]) }
        #expect(throws: RenderDecodingError.unsupportedVersion(9)) { try RenderCodec.decode([0x52, 0x4E, 9]) }
        #expect(throws: RenderDecodingError.truncated) { try RenderCodec.decode(Array(bytes.dropLast(4))) }
        #expect(throws: RenderDecodingError.malformed) { try RenderCodec.decode(bytes + [0]) }
        #expect(throws: RenderDecodingError.truncated) { try RenderCodec.decode(id: [1, 2]) }
        // Every truncation fails cleanly.
        for length in 0..<bytes.count {
            #expect(throws: RenderDecodingError.self) { try RenderCodec.decode(Array(bytes.prefix(length))) }
        }
    }

    @Test func treeHelpers() {
        var tree = Self.tree
        #expect(tree.node(5)?.type == "Toggle")
        let replaced = tree.replace(5, with: RenderNode("Text", id: 5))
        #expect(replaced)
        #expect(tree.node(5)?.type == "Text")
        let missing = tree.replace(99, with: RenderNode("Text", id: 99))
        #expect(!missing)
    }

    @Test func rendererContract() {
        let renderer = RendererProxy.descriptor
        #expect(renderer.name == "org.pureswift.ui.Renderer")
        #expect(renderer.method(key: "apply:", kind: .instance)?.signature == Signature("(O)V"))
        #expect(renderer.method(key: "replaceSubtree:tree:", kind: .instance)?.signature == Signature("(OO)V"))
        #expect(renderer.method(key: "environment", kind: .instance)?.signature == Signature("()O"))
        #expect(renderer.version == 1)
        let delegate = RendererDelegateProxy.descriptor
        #expect(delegate.method(key: "event:kind:payload:", kind: .instance)?.signature == Signature("(OIO)V"))
        #expect(delegate.method(key: "rowCount:", kind: .instance)?.signature == Signature("(O)I"))
        #expect(delegate.method(key: "row:index:", kind: .instance)?.signature == Signature("(OI)O"))
    }

    // MARK: The window's values

    @Test func environmentRoundTrips() throws {
        let window = RenderEnvironment(
            horizontalSizeClass: .compact, verticalSizeClass: .regular,
            colorScheme: .dark, colorSchemeContrast: .increased,
            dynamicTypeSize: .accessibility3, layoutDirection: .rightToLeft,
            legibilityWeight: .bold, displayScale: 3,
            reduceMotion: true, reduceTransparency: false, differentiateWithoutColor: true
        )
        #expect(RenderEnvironment(payload: window.payload) == window)
        #expect(RenderEnvironment(bytes: window.bytes) == window)
        #expect(RenderEnvironment(props: window.props) == window)
        #expect(window.props.count == 11, "every value set")
        #expect(window.props["accessibilityReduceMotion"] == true)
        #expect(window.props["dynamicTypeSize"] == "accessibility3")

        // Keys then values, in key order, so equal values encode alike.
        guard case .array(let items) = window.payload else {
            Issue.record("not an array")
            return
        }
        #expect(items.count == 22)
        #expect(items.first == "accessibilityDifferentiateWithoutColor")
        #expect(items[1] == true)
    }

    @Test func environmentKeepsDefaultsAndSkipsWhatItDoesntKnow() {
        let partial = RenderEnvironment(payload: .array(["colorScheme", "dark", "brightness", 0.5, "displayScale", "high", "horizontalSizeClass"]))
        #expect(partial == RenderEnvironment(colorScheme: .dark), "an unknown key, a value of the wrong kind and a key without a value are skipped")
        #expect(RenderEnvironment(payload: "dark").isEmpty)
        #expect(RenderEnvironment(payload: nil).isEmpty)
        #expect(RenderEnvironment(bytes: []) == nil, "a renderer that doesn't report them")
        #expect(RenderEnvironment(bytes: [1, 2, 3]) == nil)
        #expect(RenderEnvironment().payload == .array([]))
        #expect(RenderEnvironment(bytes: RenderEnvironment().bytes) == RenderEnvironment(), "no values is still an answer")

        let merged = RenderEnvironment(horizontalSizeClass: .regular, colorScheme: .light)
            .merging(RenderEnvironment(colorScheme: .dark))
        #expect(merged == RenderEnvironment(horizontalSizeClass: .regular, colorScheme: .dark))
    }

    @Test func textScalesMapToTheNearestSize() {
        #expect(RenderEnvironment.TypeSize(scale: 1) == .large)
        #expect(RenderEnvironment.TypeSize(scale: 0.85) == .small)
        #expect(RenderEnvironment.TypeSize(scale: 1.15) == .xLarge)
        #expect(RenderEnvironment.TypeSize(scale: 1.3) == .xxxLarge)
        #expect(RenderEnvironment.TypeSize(scale: 2) == .accessibility2)
        #expect(RenderEnvironment.TypeSize(scale: 10) == .accessibility5)
        #expect(RenderEnvironment.TypeSize(scale: 0.1) == .xSmall)
        #expect(RenderEnvironment.TypeSize.allCases.map(\.ratio) == RenderEnvironment.TypeSize.allCases.map(\.ratio).sorted())
    }

    @Test func theWindowIsNodeZero() {
        #expect(RenderNode.windowID == 0)
        #expect(RenderEventKind.environment.rawValue == 7)
    }
}
