import Foundation
import Testing
import CRuntime
import DynamicDefaults
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative

/// `ExampleDefaults`'s library with the shared host store keeping its
/// settings in a real file: `@AppStorage`, the guest's `UserDefaults`, the
/// `Defaults` contract and `HostDefaults` in an Embedded guest, as a native
/// slice or through wasm2c (see `Package.swift`). A linked app starts once
/// per process, so the earlier launches are settings already in the file.
/// Part of `LinkedSliceTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleDefaults: Bool {
        #if LINKED_EXAMPLEDEFAULTS
        true
        #else
        false
        #endif
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

    func settings(_ renderer: TestRenderer, theme: String) -> SettingsScreen {
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
    func changeSettings(_ renderer: TestRenderer) throws {
        var screen = try #require(renderer.screen)
        renderer.send(try #require(screen.first { $0.type == "Toggle" }), .change, false)
        renderer.send(try #require(screen.first { $0.type == "Slider" }), .change, 0.8)
        renderer.send(try #require(screen.first { $0.type == "TextField" }), .change, "Ada")
        screen = try #require(renderer.screen)
        renderer.send(try #require(screen.button("Theme: system")), .tap)
    }

    @Test(.enabled(if: linksExampleDefaults, "Link ExampleDefaults's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleDefaults() throws {
        #if LINKED_EXAMPLEDEFAULTS
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExampleDefaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Defaults").path
        // What four earlier launches left.
        let earlier = try FileDefaultsStorage(path: path)
        #expect(earlier.setString("4", key: "launches") && earlier.setString("0.25", key: "volume"))

        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        HostDefaults.storage = try FileDefaultsStorage(path: path)
        HostDefaultsModule.register(in: native)
        TestRenderer.last = nil

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        let renderer = try #require(TestRenderer.last)
        #expect(settings(renderer, theme: "system") == SettingsScreen(
            launches: "Launches: 5", soundOn: true, volume: "Volume 25%", greeting: "Hello", theme: true,
            keys: "launches, volume"))

        try changeSettings(renderer)
        #expect(settings(renderer, theme: "light") == SettingsScreen(
            launches: "Launches: 5", soundOn: false, volume: "Volume 80%", greeting: "Hello, Ada", theme: true,
            keys: "launches, name, soundOn, theme, volume"))
        // In the file, for the next launch.
        let stored = try FileDefaultsStorage(path: path)
        #expect(stored.string("volume") == "0.8" && stored.string("launches") == "5")
        #expect(stored.string("soundOn") == "false" && stored.string("name") == "Ada" && stored.string("theme") == "light")

        renderer.send(try #require(renderer.screen?.button("Reset")), .tap)
        #expect(settings(renderer, theme: "system") == SettingsScreen(
            launches: "Launches: 0", soundOn: true, volume: "Volume 50%", greeting: "Hello", theme: true, keys: ""))
        #expect(try FileDefaultsStorage(path: path).keys().isEmpty)
        #endif
    }
}
