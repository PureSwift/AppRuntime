import DynamicRuntime
import DynamicDefaults
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example settings app: values kept in `UserDefaults` across launches,
/// read and written with `@AppStorage`. A boolean, a number with a
/// fraction, a string, an enum, and a count of launches the app keeps
/// itself.

enum Theme: String {

    case system
    case light
    case dark

    var next: Theme {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

struct ContentView: View {

    @AppStorage("soundOn") var soundOn = true

    @AppStorage("volume") var volume = 0.5

    @AppStorage("name") var name = ""

    @AppStorage("theme") var theme = Theme.system

    @AppStorage("launches") var launches = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launches: \(launches)")
                .accessibilityIdentifier("launches")
            Toggle("Sound", isOn: $soundOn)
            Slider(value: $volume, in: 0...1)
            Text("Volume \(Int(volume * 100))%")
                .accessibilityIdentifier("volume")
            TextField("Name", text: $name)
            Text(name.isEmpty ? "Hello" : "Hello, \(name)")
                .accessibilityIdentifier("greeting")
            Button("Theme: \(theme.rawValue)") { theme = theme.next }
            Button("Reset") {
                let defaults = UserDefaults.standard
                for key in defaults.keys {
                    defaults.removeObject(forKey: key)
                }
            }
            Text(UserDefaults.standard.keys.joined(separator: ", "))
                .accessibilityIdentifier("keys")
        }
        .padding()
    }
}

struct ExampleDefaultsApp: App {

    init() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "launches") + 1, forKey: "launches")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleDefaultsMain() -> rt_status {
    Runtime.main { ExampleDefaultsApp.run() }
}
