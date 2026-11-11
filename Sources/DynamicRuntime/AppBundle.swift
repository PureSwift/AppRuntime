/// The built-in `Bundle` contract (§7.4): the app's metadata and localized
/// strings.
///
/// Every host provides it. The guest reads its bundle through the host, never
/// from files. Named `AppBundle` in Swift, so hosts can still write `Bundle`
/// for Foundation's.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `Bundle.main`: `CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion`, `localizedString(forKey:value:table:)`; `Locale.preferredLanguages` |
/// | Android | `PackageManager` package info; string resources; `LocaleList` |
/// | Linux | the bundle's `Info.plist` and `resources/<language>.lproj` tables; `LANGUAGE` / `LANG` |
@DynamicRuntime("org.pureswift.runtime.Bundle")
public protocol AppBundle: AnyObject {

    /// The app's identifier, such as `org.example.App`.
    static func identifier() throws(RuntimeError) -> String

    /// The user-visible version, such as `1.2`.
    static func version() throws(RuntimeError) -> String

    /// The build number, such as `42`.
    static func build() throws(RuntimeError) -> String

    /// The user's languages as BCP 47 tags, most preferred first.
    static func preferredLanguages() throws(RuntimeError) -> [String]

    /// The string for `key` in `table` (the default table when `nil`), in the
    /// best language the bundle has for the user; `nil` when no table has
    /// the key.
    static func localizedString(_ key: String, table: String?) throws(RuntimeError) -> String?
}
