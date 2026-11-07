import DynamicRuntime

/// Locale-aware date and time formatting and parsing.
///
/// Dates travel as milliseconds since 1970-01-01 UTC. Implemented over
/// `DateFormatter`, `java.text.DateFormat` / `android.icu.text`, or ICU.
@DynamicRuntime("org.pureswift.formatting.DateFormat")
public protocol DateFormat: AnyObject {

    /// `locale` is a BCP 47 identifier and `timeZone` an IANA identifier;
    /// nil uses the user's.
    static func make(locale: String?, timeZone: String?) -> Self

    /// A `DateStyle` raw value.
    func setDateStyle(_ style: Int32)

    /// A `DateStyle` raw value.
    func setTimeStyle(_ style: Int32)

    /// A Unicode TR35 pattern such as `yyyy-MM-dd HH:mm`; overrides the
    /// styles. Nil returns to the styles.
    func setPattern(_ pattern: String?)

    /// A localized pattern from TR35 skeleton fields such as `yMMMd`.
    func setTemplate(_ template: String)

    func format(_ milliseconds: Int64) -> String

    /// `Int64.min` if `string` doesn't match.
    func parse(_ string: String) -> Int64

    /// Formats the interval between two dates, for example "3 hours ago"
    /// relative to `reference`.
    func formatRelative(_ milliseconds: Int64, reference: Int64) -> String
}
