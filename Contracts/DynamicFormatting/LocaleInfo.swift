import DynamicRuntime

/// The user's locale and region settings.
@DynamicRuntime("org.pureswift.formatting.Locale")
public protocol LocaleInfo: AnyObject {

    /// The user's current locale.
    static func current() -> Self

    /// A specific locale by BCP 47 identifier; nil if unknown.
    static func make(identifier: String) -> Self?

    /// BCP 47 identifier, for example `en-US`.
    func identifier() -> String

    func languageCode() -> String?

    func regionCode() -> String?

    /// Preferred languages in order, as BCP 47 identifiers.
    static func preferredLanguages() -> [String]

    func decimalSeparator() -> String

    func groupingSeparator() -> String

    func currencyCode() -> String?

    func uses24HourClock() -> Bool

    /// IANA identifier of the user's time zone.
    func timeZoneIdentifier() -> String

    /// Offset from UTC in seconds at `milliseconds`.
    func timeZoneOffset(_ milliseconds: Int64) -> Int32
}
