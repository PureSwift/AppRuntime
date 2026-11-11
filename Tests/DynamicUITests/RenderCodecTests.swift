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
        let delegate = RendererDelegateProxy.descriptor
        #expect(delegate.method(key: "event:kind:payload:", kind: .instance)?.signature == Signature("(OIO)V"))
        #expect(delegate.method(key: "rowCount:", kind: .instance)?.signature == Signature("(O)I"))
        #expect(delegate.method(key: "row:index:", kind: .instance)?.signature == Signature("(OI)O"))
    }
}
