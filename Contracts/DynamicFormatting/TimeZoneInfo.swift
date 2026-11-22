import DynamicRuntime

/// A time zone: its offset from UTC at any moment, and its names
/// (`Documentation/Contracts/Formatting.md`).
///
/// Dates are seconds since 1970 UTC. Identifiers are IANA names such as
/// `Europe/Berlin`, and `GMT`, `UTC` and `GMT+0100` for fixed offsets.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS, Linux | `TimeZone` |
/// | Android | `android.icu.util.TimeZone` |
/// | Browser | `Intl.DateTimeFormat` |
@DynamicRuntime("org.pureswift.formatting.TimeZone")
public protocol TimeZoneInfo: AnyObject {

    /// Nil identifier: the user's zone, whatever it becomes. Nil result: a
    /// zone this host doesn't know.
    static func make(identifier: String?) -> Self?

    /// Every zone this host knows, sorted.
    static func identifiers() -> [String]

    /// For the user's zone, its identifier now.
    func identifier() -> String

    /// Seconds east of UTC at a moment.
    func offset(_ seconds: Double) -> Int32

    /// What daylight saving adds at a moment; 0 outside it.
    func daylightSavingOffset(_ seconds: Double) -> Int32

    /// The next change of offset after a moment; `nan` if none is known.
    func nextTransition(_ seconds: Double) -> Double

    /// "CET", "GMT+1".
    func abbreviation(_ seconds: Double) -> String?

    /// A `TimeZoneNameStyle` raw value. Locale nil: the user's.
    func name(_ style: Int32, locale: String?) -> String?
}

/// `TimeZoneInfo.name(_:locale:)`: Foundation's `TimeZone.NameStyle`.
public enum TimeZoneNameStyle: Int32, Sendable {

    /// "Central European Standard Time".
    case standard = 0

    /// "CET".
    case shortStandard = 1

    /// "Central European Summer Time".
    case daylightSaving = 2

    /// "CEST".
    case shortDaylightSaving = 3

    /// "Central European Time".
    case generic = 4

    /// "Germany Time".
    case shortGeneric = 5
}
