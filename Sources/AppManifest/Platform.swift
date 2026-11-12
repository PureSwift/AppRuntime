/// A platform the app runs on, with its minimum OS.
public struct Platform: Sendable, Equatable {

    /// `ios`, `macos`, `tvos`, `watchos`, `visionos`, `android` or `linux`.
    public var name: String

    /// The minimum OS version on Apple platforms, such as `15.0`.
    public var minimum: String?

    /// Android's `minSdk`.
    public var minSDK: Int?

    /// Android's `targetSdk`.
    public var targetSDK: Int?

    public init(name: String, minimum: String? = nil, minSDK: Int? = nil, targetSDK: Int? = nil) {
        self.name = name
        self.minimum = minimum
        self.minSDK = minSDK
        self.targetSDK = targetSDK
    }
}

public extension Platform {

    static func iOS(_ minimum: String) -> Platform {
        Platform(name: "ios", minimum: minimum)
    }

    static func macOS(_ minimum: String) -> Platform {
        Platform(name: "macos", minimum: minimum)
    }

    static func tvOS(_ minimum: String) -> Platform {
        Platform(name: "tvos", minimum: minimum)
    }

    static func watchOS(_ minimum: String) -> Platform {
        Platform(name: "watchos", minimum: minimum)
    }

    static func visionOS(_ minimum: String) -> Platform {
        Platform(name: "visionos", minimum: minimum)
    }

    static func android(minSDK: Int, targetSDK: Int) -> Platform {
        Platform(name: "android", minSDK: minSDK, targetSDK: targetSDK)
    }

    static var linux: Platform {
        Platform(name: "linux")
    }
}

/// Apple-only settings, passed to Apple hosts untouched.
public struct AppleSettings: Sendable, Equatable {

    /// The App Store category (`LSApplicationCategoryType`).
    public var category: AppCategory?

    /// Keys merged into the generated `Info.plist`.
    public var extraInfoPlist: [String: PropertyListValue]

    /// The app's own privacy manifest keys, merged into the
    /// `PrivacyInfo.xcprivacy` the packager writes: the data the app
    /// collects and whether it tracks (`NSPrivacyTracking`,
    /// `NSPrivacyTrackingDomains`, `NSPrivacyCollectedDataTypes`). The
    /// host declares the required-reason APIs it uses itself.
    public var privacy: [String: PropertyListValue]

    public init(
        category: AppCategory? = nil,
        extraInfoPlist: [String: PropertyListValue] = [:],
        privacy: [String: PropertyListValue] = [:]
    ) {
        self.category = category
        self.extraInfoPlist = extraInfoPlist
        self.privacy = privacy
    }
}

/// An App Store category.
public struct AppCategory: RawRepresentable, Sendable, Equatable {

    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension AppCategory {

    static var business: AppCategory { AppCategory(rawValue: "public.app-category.business") }
    static var developerTools: AppCategory { AppCategory(rawValue: "public.app-category.developer-tools") }
    static var education: AppCategory { AppCategory(rawValue: "public.app-category.education") }
    static var entertainment: AppCategory { AppCategory(rawValue: "public.app-category.entertainment") }
    static var games: AppCategory { AppCategory(rawValue: "public.app-category.games") }
    static var healthcareFitness: AppCategory { AppCategory(rawValue: "public.app-category.healthcare-fitness") }
    static var lifestyle: AppCategory { AppCategory(rawValue: "public.app-category.lifestyle") }
    static var medical: AppCategory { AppCategory(rawValue: "public.app-category.medical") }
    static var music: AppCategory { AppCategory(rawValue: "public.app-category.music") }
    static var navigation: AppCategory { AppCategory(rawValue: "public.app-category.navigation") }
    static var productivity: AppCategory { AppCategory(rawValue: "public.app-category.productivity") }
    static var utilities: AppCategory { AppCategory(rawValue: "public.app-category.utilities") }
}

/// Android-only settings, passed to Android hosts untouched.
public struct AndroidSettings: Sendable, Equatable {

    /// XML merged into the generated `AndroidManifest.xml`'s `<manifest>`.
    public var extraManifest: String?

    public init(extraManifest: String? = nil) {
        self.extraManifest = extraManifest
    }
}

/// A property list value for `AppleSettings.extraInfoPlist`.
public indirect enum PropertyListValue: Sendable, Equatable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {

    case string(String)
    case integer(Int)
    case real(Double)
    case boolean(Bool)
    case array([PropertyListValue])
    case dictionary([String: PropertyListValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(arrayLiteral elements: PropertyListValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, PropertyListValue)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
