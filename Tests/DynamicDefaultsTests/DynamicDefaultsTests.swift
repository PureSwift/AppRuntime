import Testing
import DynamicDefaults
import DynamicRuntime
@testable import DynamicSwiftUI
import DynamicUI
import RuntimeNative

/// A host's store, in memory.
final class MemoryDefaults: Defaults {

    nonisolated(unsafe) static var instance = MemoryDefaults()

    var strings: [String: String] = [:]

    var datas: [String: [UInt8]] = [:]

    /// Values over this many bytes are refused, as a host may.
    var limit = 1024

    var reads = 0

    static func standard() -> MemoryDefaults { instance }

    func string(_ key: String) -> String? {
        reads += 1
        return strings[key]
    }

    func data(_ key: String) -> [UInt8]? {
        reads += 1
        return datas[key]
    }

    func setString(_ value: String, key: String) -> Bool {
        guard value.utf8.count <= limit else { return false }
        datas[key] = nil
        strings[key] = value
        return true
    }

    func setData(_ value: [UInt8], key: String) -> Bool {
        guard value.count <= limit else { return false }
        strings[key] = nil
        datas[key] = value
        return true
    }

    func remove(_ key: String) {
        strings[key] = nil
        datas[key] = nil
    }

    func keys() -> [String] {
        (Array(strings.keys) + Array(datas.keys)).sorted()
    }
}

enum Flavor: String {
    case plain, sweet, sour
}

enum Level: Int {
    case low = 1, high = 9
}

/// A view with settings, as an app writes one.
struct Settings: View {

    @AppStorage("soundOn") var soundOn = true

    @AppStorage("name") var name = "nobody"

    var body: some View {
        VStack {
            Text(soundOn ? "Sound on" : "Sound off")
            Text("Hello, \(name)")
            Toggle("Sound", isOn: $soundOn)
        }
    }
}

final class DefaultsSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }

    /// The text of every `Text` on screen that isn't a control's label.
    var texts: [String] {
        func collect(_ node: RenderNode) -> [String] {
            if node.type == "Text" { return [node.props["text"]?.string ?? ""] }
            if node.type == "Toggle" { return [] }
            return node.children.flatMap(collect)
        }
        return screen.map(collect) ?? []
    }

    func first(_ type: String) -> RenderNode? {
        func find(_ node: RenderNode) -> RenderNode? {
            node.type == type ? node : node.children.lazy.compactMap(find).first
        }
        return screen.flatMap(find)
    }
}

/// Serialized: the tests share the native runtime and the host's store,
/// and the frontend keeps the graph being evaluated in a global.
@Suite(.serialized) struct DynamicDefaultsTests {

    let host: MemoryDefaults

    let defaults: UserDefaults

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        DefaultsProxy.register(MemoryDefaults.self, in: native)
        host = MemoryDefaults()
        MemoryDefaults.instance = host
        defaults = UserDefaults()
    }

    func method(_ key: String) -> MethodDescriptor? {
        DefaultsProxy.descriptor.methods.first { $0.key == key }
    }

    // MARK: Contract

    @Test func defaultsAnswerAtOnce() {
        let descriptor = DefaultsProxy.descriptor
        #expect(descriptor.name == "org.pureswift.data.Defaults")
        #expect(descriptor.capability == nil)
        #expect(method("standard")?.kind == .constructor)
        #expect(method("string:")?.signature == Signature("(O)O"), "synchronous: the value is the result")
        #expect(method("data:")?.signature == Signature("(O)O"))
        #expect(method("setString:key:")?.signature == Signature("(OO)Z"))
        #expect(method("setData:key:")?.signature == Signature("(OO)Z"))
        #expect(method("remove:")?.signature == Signature("(O)V"))
        #expect(method("keys")?.signature == Signature("()O"))
        #expect(descriptor.methods.count == 7)
        #expect(ContractMetadata.decode(ContractMetadata.encode(descriptor)) == [descriptor])
    }

    // MARK: UserDefaults

    @Test func missingValuesReadAsFoundationsDo() {
        #expect(defaults.string(forKey: "none") == nil)
        #expect(defaults.data(forKey: "none") == nil)
        #expect(defaults.bool(forKey: "none") == false)
        #expect(defaults.integer(forKey: "none") == 0)
        #expect(defaults.double(forKey: "none") == 0)
        #expect(!defaults.hasValue(forKey: "none"))
        #expect(defaults.keys.isEmpty)
    }

    @Test func valuesRoundTripAsText() {
        defaults.set(true, forKey: "flag")
        defaults.set(-42, forKey: "count")
        defaults.set(0.1, forKey: "ratio")
        defaults.set("Ada", forKey: "name")
        defaults.set([0, 255, 7], forKey: "blob")
        #expect(defaults.bool(forKey: "flag"))
        #expect(defaults.integer(forKey: "count") == -42)
        #expect(defaults.double(forKey: "ratio") == 0.1)
        #expect(defaults.string(forKey: "name") == "Ada")
        #expect(defaults.data(forKey: "blob") == [0, 255, 7])
        // Readable in the host's own tools.
        #expect(host.strings == ["flag": "true", "count": "-42", "ratio": "0.1", "name": "Ada"])
        #expect(defaults.keys == ["blob", "count", "flag", "name", "ratio"])
        #expect(defaults.hasValue(forKey: "blob") && defaults.hasValue(forKey: "flag"))

        for value in [Double.pi, 1e-300, -0.0, 123456789.125, .greatestFiniteMagnitude] {
            defaults.set(value, forKey: "double")
            #expect(defaults.double(forKey: "double").bitPattern == value.bitPattern, "\(value)")
        }
        for value in [Int.max, Int.min, 0] {
            defaults.set(value, forKey: "int")
            #expect(defaults.integer(forKey: "int") == value)
        }
    }

    @Test func aValueOfAnotherKindReadsAsMissing() {
        defaults.set("seven", forKey: "word")
        #expect(defaults.integer(forKey: "word") == 0)
        #expect(defaults.double(forKey: "word") == 0)
        #expect(defaults.bool(forKey: "word") == false)
        #expect(defaults.data(forKey: "word") == nil)
        defaults.set(3, forKey: "number")
        #expect(defaults.double(forKey: "number") == 3, "a whole number is a number")
        #expect(defaults.string(forKey: "number") == "3")
        // A key holds one value: bytes replace a string.
        defaults.set([1], forKey: "word")
        #expect(defaults.string(forKey: "word") == nil)
        #expect(defaults.keys == ["number", "word"])
    }

    @Test func nilAndRemoveTakeAKeyAway() {
        defaults.set("x", forKey: "a")
        defaults.set([1], forKey: "b")
        defaults.set(nil as String?, forKey: "a")
        defaults.set(nil as [UInt8]?, forKey: "b")
        #expect(defaults.keys.isEmpty)
        defaults.set(1, forKey: "c")
        defaults.removeObject(forKey: "c")
        defaults.removeObject(forKey: "never")
        #expect(!defaults.hasValue(forKey: "c"))
    }

    @Test func aRefusedValueIsReported() {
        #expect(defaults.set("small", forKey: "note"))
        #expect(!defaults.set(String(repeating: "x", count: 2000), forKey: "note"), "over what this host keeps")
        #expect(defaults.string(forKey: "note") == "small", "the old value stays")
        #expect(!defaults.set([UInt8](repeating: 0, count: 2000), forKey: "blob"))
    }

    @Test func readingAKeyObservesIt() {
        nonisolated(unsafe) var changes = 0
        _ = withObservationTracking { defaults.bool(forKey: "soundOn") } onChange: { changes += 1 }
        defaults.set("Ada", forKey: "name")
        #expect(changes == 0, "another key")
        defaults.set(true, forKey: "soundOn")
        #expect(changes == 1)

        _ = withObservationTracking { defaults.keys } onChange: { changes += 1 }
        defaults.set(1, forKey: "new")
        #expect(changes == 2, "the list of keys changed")
        _ = withObservationTracking { defaults.hasValue(forKey: "new") } onChange: { changes += 1 }
        defaults.removeObject(forKey: "new")
        #expect(changes == 3)
    }

    // MARK: AppStorage

    @Test func storageReadsTheDefaultUntilSet() {
        @AppStorage("volume", store: defaults) var volume = 0.5
        @AppStorage("count", store: defaults) var count = 3
        @AppStorage("name", store: defaults) var name = "nobody"
        @AppStorage("on", store: defaults) var on = true
        @AppStorage("blob", store: defaults) var blob: [UInt8] = [9]
        #expect(volume == 0.5 && count == 3 && name == "nobody" && on && blob == [9])
        #expect(defaults.keys.isEmpty, "reading stores nothing")

        volume = 0.75
        count += 1
        name = "Ada"
        on = false
        blob = [1, 2]
        #expect(host.strings == ["volume": "0.75", "count": "4", "name": "Ada", "on": "false"])
        #expect(host.datas == ["blob": [1, 2]])
        #expect(volume == 0.75 && count == 4 && name == "Ada" && !on && blob == [1, 2])

        // Another wrapper on the key, as another view has, sees the same.
        @AppStorage("count", store: defaults) var again = 0
        #expect(again == 4)
        defaults.removeObject(forKey: "count")
        #expect(count == 3 && again == 0, "each falls back to its own default")
    }

    @Test func storageKeepsEnumsByRawValue() {
        @AppStorage("flavor", store: defaults) var flavor = Flavor.plain
        @AppStorage("level", store: defaults) var level = Level.low
        flavor = .sour
        level = .high
        #expect(host.strings == ["flavor": "sour", "level": "9"])
        #expect(flavor == .sour && level == .high)
        // A stored value that's no case reads as the default.
        defaults.set("bitter", forKey: "flavor")
        defaults.set(5, forKey: "level")
        #expect(flavor == .plain && level == .low)
    }

    @Test func storageGivesABinding() {
        @AppStorage("on", store: defaults) var on = false
        let binding = $on
        #expect(!binding.wrappedValue)
        binding.wrappedValue = true
        #expect(on)
        #expect(defaults.bool(forKey: "on"))
    }

    @Test func viewsFollowTheirSettings() throws {
        // The view's wrappers use the standard defaults, which is this host.
        let standard = UserDefaults.standard
        for key in standard.keys {
            standard.removeObject(forKey: key)
        }
        let sink = DefaultsSink()
        let graph = ViewGraph(Settings(), sink: sink)
        graph.update()
        #expect(sink.texts == ["Sound on", "Hello, nobody"])

        // The toggle writes through its binding, and the view reads it back.
        let toggle = try #require(sink.first("Toggle"))
        #expect(toggle.props["isOn"] == true)
        graph.handle(toggle.id, kind: .change, payload: false)
        graph.update()
        #expect(sink.texts == ["Sound off", "Hello, nobody"])
        #expect(host.strings["soundOn"] == "false")

        // A change from elsewhere in the app reaches the view too.
        standard.set("Ada", forKey: "name")
        #expect(graph.needsUpdate)
        graph.update()
        #expect(sink.texts == ["Sound off", "Hello, Ada"])
    }
}
