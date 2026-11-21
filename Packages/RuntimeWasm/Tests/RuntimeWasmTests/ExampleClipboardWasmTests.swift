import Foundation
import Testing
import DynamicClipboard
import DynamicFiles
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeClipboard
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// The system's clipboard, kept by the test: it fills it as another app
/// would, and refuses a read as a user would.
final class WasmClipboardPlatform: ClipboardPlatform {

    let held = MemoryClipboard()

    var refusesReads = false

    var reads = 0

    func available() -> ClipboardKinds {
        held.available()
    }

    func clear() {
        held.clear()
    }

    func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void) {
        held.write(content, isSensitive: isSensitive, completion: completion)
    }

    func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void) {
        reads += 1
        if refusesReads {
            completion(.failure(.notAllowed))
        } else {
            held.read(kind, completion: completion)
        }
    }
}

/// The example clipboard app as App.wasm under WasmKit, with the shared
/// host implementation over a clipboard the test keeps: the guest's
/// `Pasteboard`, the `Clipboard` contract and `HostClipboard`, end to end,
/// with real image files. Part of `WasmShimTests`, which is serialized,
/// since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleClipboard`; skipped without it.
    static var exampleClipboardURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleClipboard/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleClipboardURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleClipboard"))
    func exampleClipboardInWasmMode() throws {
        let native = NativeRuntime.shared
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleClipboard-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        // The app's bundle: its logo, a PNG by its first bytes.
        let resources = root.appendingPathComponent("App/resources")
        let caches = root.appendingPathComponent("Container/Caches")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        let logo: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]
        let photo: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]
        try Data(logo).write(to: resources.appendingPathComponent("logo.png"))

        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .bundle: resources.path,
            .caches: caches.path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        let platform = WasmClipboardPlatform()
        HostClipboard.reset()
        HostClipboard.platform = platform
        HostClipboard.work = { $0() }
        HostClipboard.deliver = { $0() }
        HostClipboardModule.register(in: native)
        defer { HostClipboard.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleClipboardURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        let clipboard = try #require(contracts.first { $0.name == "org.pureswift.clipboard.Clipboard" })
        #expect(clipboard.capability == nil, "the clipboard needs no capability")
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func isDisabled(_ title: String) -> Bool {
            renderer.screen?.button(title)?.modifiers.contains { $0.kind == "disabled" && $0.args["value"] == true } ?? false
        }

        // Nothing to paste, and the buttons say so. The sum can be selected.
        #expect(text("offer") == "Nothing to paste")
        #expect(isDisabled("Paste") && isDisabled("Paste Link") && isDisabled("Paste Image"))
        let sum = try #require(renderer.screen?.identified("result"))
        #expect(sum.modifiers.contains { $0.kind == "textSelection" && $0.args == ["enabled": true] })

        // Copying puts it where another app would find it.
        try tap("Copy")
        #expect(platform.held.content == .text("6 × 7 = 42", url: nil) && !platform.held.isSensitive)
        #expect(text("status") == "Copied the sum" && text("offer") == "To paste: text")
        #expect(!isDisabled("Paste") && isDisabled("Paste Link") && isDisabled("Paste Image"))
        try tap("Copy Link")
        #expect(platform.held.content == .text("Swift", url: "https://swift.org"))
        #expect(text("offer") == "To paste: a link, text" && !isDisabled("Paste Link"))
        try tap("Copy Code")
        #expect(platform.held.content == .text("493 201", url: nil) && platform.held.isSensitive, "kept out of previews")
        try tap("Copy Logo")
        #expect(platform.held.content == .image(logo, type: .png), "read from the bundle by the host")
        #expect(text("status") == "Copied the logo" && text("offer") == "To paste: an image")
        #expect(isDisabled("Paste") && !isDisabled("Paste Image"))
        #expect(platform.reads == 0, "none of that read the clipboard")

        // Another app copies something. The app looks, and still doesn't read.
        platform.held.content = .text("from another app", url: nil)
        try tap("Look")
        #expect(text("offer") == "To paste: text" && platform.reads == 0)
        try tap("Paste")
        #expect(text("pasted") == "from another app" && text("status") == "Pasted text" && platform.reads == 1)

        // A link is a link only when the clipboard says so.
        try tap("Copy Link")
        try tap("Paste Link")
        #expect(text("pasted") == "https://swift.org" && text("status") == "Pasted a link")
        try tap("Paste")
        #expect(text("pasted") == "Swift", "as text, a link is its title")

        // An image is pasted into a file, without passing through the app.
        platform.held.content = .image(photo, type: .jpeg)
        try tap("Look")
        try tap("Paste Image")
        #expect(text("status") == "Pasted an image: image/jpeg" && text("pasted") == "caches/pasted")
        #expect(try Data(contentsOf: caches.appendingPathComponent("pasted")) == Data(photo))

        // The user refuses a paste.
        platform.refusesReads = true
        try tap("Paste Image")
        #expect(text("status") == "Not allowed")
        platform.refusesReads = false

        try tap("Clear")
        #expect(platform.held.content == nil && text("status") == "Cleared" && text("offer") == "Nothing to paste")
        #expect(isDisabled("Paste") && isDisabled("Paste Image"))
    }
}
