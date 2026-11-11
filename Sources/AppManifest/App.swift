/// An app's portable manifest, written in `App.swift` (§7.1).
///
/// ```swift
/// import AppManifest
///
/// let app = App(
///     id: "org.pureswift.blescanner",
///     name: .localized("app.name"),
///     version: "1.4.0", build: 42,
///     languages: ["en", "es"],
///     product: "BLEScanner",
///     capabilities: [
///         .bluetooth(usage: .localized("perm.bluetooth")),
///         .location(.whenInUse, usage: .localized("perm.location")),
///     ],
///     platforms: [.iOS("15.0"), .macOS("12.0"), .android(minSDK: 26, targetSDK: 35), .linux],
///     icon: "AppIcon.png",
///     apple: .init(category: .utilities)
/// )
/// ```
///
/// `guest.py bundle --manifest App.swift` compiles the file with this
/// library and runs it, the way SwiftPM reads `Package.swift`. It must
/// define a top-level `app`. Only fields that exist on every platform are
/// here; platform-only settings go in `apple` and `android`.
public struct App: Sendable {

    /// A reverse-DNS identifier, such as `org.example.App`.
    public var id: String

    /// The name people see.
    public var name: ManifestText

    /// The user-visible version: one to three dot-separated integers.
    public var version: String

    /// The build number. Android uses it as `versionCode`, so it's an
    /// integer that grows with every release.
    public var build: Int

    /// Languages the app is localized for, BCP 47 tags; the first is the
    /// development language. Every `.localized` key must exist in each one's
    /// `resources/<language>.lproj/Manifest.strings`.
    public var languages: [String]

    /// The guest library product `guest.py` builds; `nil` to pass
    /// `--product`.
    public var product: String?

    /// What the app may use. Every capability a contract requires must be
    /// here.
    public var capabilities: [Capability]

    /// Where the app runs, with its minimum OS for each.
    public var platforms: [Platform]

    /// A square PNG, relative to `App.swift`.
    public var icon: String?

    /// Apple-only settings.
    public var apple: AppleSettings?

    /// Android-only settings.
    public var android: AndroidSettings?

    public init(
        id: String,
        name: ManifestText,
        version: String,
        build: Int,
        languages: [String] = ["en"],
        product: String? = nil,
        capabilities: [Capability] = [],
        platforms: [Platform],
        icon: String? = nil,
        apple: AppleSettings? = nil,
        android: AndroidSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.languages = languages
        self.product = product
        self.capabilities = capabilities
        self.platforms = platforms
        self.icon = icon
        self.apple = apple
        self.android = android
    }
}

/// Text in the manifest: written out, or a key into each language's
/// `Manifest.strings`.
///
/// ```swift
/// name: "Example"                    // the same in every language
/// name: .localized("app.name")       // from Manifest.strings
/// ```
public enum ManifestText: Sendable, Equatable, ExpressibleByStringLiteral {

    case verbatim(String)

    /// A key into `resources/<language>.lproj/Manifest.strings`.
    case localized(String)

    public init(stringLiteral value: String) {
        self = .verbatim(value)
    }
}
