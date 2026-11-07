import DynamicRuntime

/// Locale-aware number formatting and parsing, so guests don't link ICU.
///
/// Implemented over `NumberFormatter`, `java.text.NumberFormat` /
/// `android.icu.text.NumberFormat`, or ICU on Linux.
@DynamicRuntime("org.pureswift.formatting.NumberFormat")
public protocol NumberFormat: AnyObject {

    /// `locale` is a BCP 47 identifier, nil for the user's locale. `style`
    /// is a `NumberStyle` raw value.
    static func make(locale: String?, style: Int32) -> Self

    func setMinimumFractionDigits(_ digits: Int32)

    func setMaximumFractionDigits(_ digits: Int32)

    func setUsesGrouping(_ grouping: Bool)

    /// ISO 4217 code for `NumberStyle.currency`, nil for the locale's.
    func setCurrencyCode(_ code: String?)

    func format(_ value: Double) -> String

    func formatInteger(_ value: Int64) -> String

    /// Parses a formatted number; `nan` if it isn't one.
    func parse(_ string: String) -> Double
}
