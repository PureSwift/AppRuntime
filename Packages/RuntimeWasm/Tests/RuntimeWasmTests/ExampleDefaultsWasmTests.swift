import Foundation
import Testing
import DynamicDefaults
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// The example settings app as App.wasm under WasmKit, with the shared host
/// store keeping its settings in a real file: `@AppStorage`, the guest's
/// `UserDefaults`, the `Defaults` contract and `HostDefaults` end to end,
/// across two launches. Part of `WasmShimTests`, which is serialized, since
/// both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleDefaults`; skipped without it.
    static var exampleDefaultsURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleDefaults/wasm32/App.wasm")
    }

    /// What the settings screen shows.
    struct SettingsScreen: Equatable {
        var launches: String?
        var soundOn: Bool?
        var volume: String?
        var greeting: String?
        var theme: Bool
        var keys: String?
    }

    func settings(_ renderer: WasmTestRenderer, theme: String) -> SettingsScreen {
        let screen = renderer.screen
        return SettingsScreen(
            launches: screen?.identified("launches")?.props["text"]?.string,
            soundOn: screen?.first { $0.type == "Toggle" }?.props["isOn"]?.bool,
            volume: screen?.identified("volume")?.props["text"]?.string,
            greeting: screen?.identified("greeting")?.props["text"]?.string,
            theme: screen?.button("Theme: \(theme)") != nil,
            keys: screen?.identified("keys")?.props["text"]?.string
        )
    }

    /// Changes every setting, as a user would.
    func changeSettings(_ renderer: WasmTestRenderer) throws {
        var screen = try #require(renderer.screen)
        renderer.send(try #require(screen.first { $0.type == "Toggle" }), .change, false)
        renderer.send(try #require(screen.first { $0.type == "Slider" }), .change, 0.8)
        renderer.send(try #require(screen.first { $0.type == "TextField" }), .change, "Ada")
        screen = try #require(renderer.screen)
        renderer.send(try #require(screen.button("Theme: system")), .tap)
    }

    /// The app starts: the host opens the settings file, then loads the app.
    func launchExampleDefaults(_ path: String) throws -> (app: WasmApp, renderer: WasmTestRenderer) {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        HostDefaults.storage = try FileDefaultsStorage(path: path)
        HostDefaultsModule.register(in: native)
        WasmTestRenderer.last = nil
        let bytes = Array(try Data(contentsOf: Self.exampleDefaultsURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [])
        #expect(try app.start() == .ok)
        return (app, try #require(WasmTestRenderer.last))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleDefaultsURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleDefaults"))
    func exampleDefaultsInWasmMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExampleDefaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Defaults").path

        // The first launch: every setting at its default, one launch counted.
        var (app, renderer) = try launchExampleDefaults(path)
        #expect(WasmApp.contracts(of: app.module)?.first { $0.name == "org.pureswift.data.Defaults" }?.capability == nil)
        #expect(settings(renderer, theme: "system") == SettingsScreen(
            launches: "Launches: 1", soundOn: true, volume: "Volume 50%", greeting: "Hello", theme: true, keys: "launches"))

        try changeSettings(renderer)
        #expect(settings(renderer, theme: "light") == SettingsScreen(
            launches: "Launches: 1", soundOn: false, volume: "Volume 80%", greeting: "Hello, Ada", theme: true,
            keys: "launches, name, soundOn, theme, volume"))

        // The second launch, in a new instance of the app: they're all there.
        (app, renderer) = try launchExampleDefaults(path)
        #expect(settings(renderer, theme: "light") == SettingsScreen(
            launches: "Launches: 2", soundOn: false, volume: "Volume 80%", greeting: "Hello, Ada", theme: true,
            keys: "launches, name, soundOn, theme, volume"))
        let stored = try FileDefaultsStorage(path: path)
        #expect(stored.string("volume") == "0.8" && stored.string("launches") == "2" && stored.string("theme") == "light")

        // Reset removes every key, and each setting is its default again.
        renderer.send(try #require(renderer.screen?.button("Reset")), .tap)
        #expect(settings(renderer, theme: "system") == SettingsScreen(
            launches: "Launches: 0", soundOn: true, volume: "Volume 50%", greeting: "Hello", theme: true, keys: ""))
        #expect(try FileDefaultsStorage(path: path).keys().isEmpty)
        _ = app
    }
}
