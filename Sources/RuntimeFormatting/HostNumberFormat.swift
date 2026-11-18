import DynamicFormatting
import Foundation

/// The `NumberFormat` contract over `NumberFormatter`, and Swift
/// Foundation's format styles where it falls short.
///
/// Each object holds its settings; the formatter for a set of settings comes
/// from `FormatterCache`, so objects with the same locale, style and options
/// share one.
///
/// - `NumberStyle.compact` has no `NumberFormatter` style. It formats with
///   `FloatingPointFormatStyle`'s compact-name notation ("1.2K") and parses
///   like `decimal`, since Foundation has no compact parser.
/// - A decimal integer formats with `IntegerFormatStyle`, which keeps every
///   digit: `NumberFormatter` goes through a `Double` on Linux, even from an
///   `NSDecimalNumber`, and loses those past 2^53.
/// - An unknown style is `decimal`, and is logged (`HostFormattingModule.log`).
public final class HostNumberFormat: NumberFormat {

    /// Everything that shapes the formatter. Nil options keep the style's
    /// defaults.
    struct Settings: Hashable {
        var locale: String?
        var style: NumberStyle
        var minimumFractionDigits: Int?
        var maximumFractionDigits: Int?
        var usesGrouping: Bool?
        var currencyCode: String?
    }

    private(set) var settings: Settings

    init(_ settings: Settings) {
        self.settings = settings
    }

    public static func make(locale: String?, style: Int32) -> HostNumberFormat {
        let numberStyle = NumberStyle(rawValue: style) ?? {
            HostFormattingModule.log?("NumberFormat.make: unknown style \(style); using decimal")
            return .decimal
        }()
        return HostNumberFormat(Settings(locale: locale, style: numberStyle))
    }

    /// Raises the maximum if it was set lower.
    public func setMinimumFractionDigits(_ digits: Int32) {
        let minimum = max(0, Int(digits))
        settings.minimumFractionDigits = minimum
        if let maximum = settings.maximumFractionDigits, maximum < minimum {
            settings.maximumFractionDigits = minimum
        }
    }

    /// Lowers the minimum if it was set higher.
    public func setMaximumFractionDigits(_ digits: Int32) {
        let maximum = max(0, Int(digits))
        settings.maximumFractionDigits = maximum
        if let minimum = settings.minimumFractionDigits, minimum > maximum {
            settings.minimumFractionDigits = maximum
        }
    }

    public func setUsesGrouping(_ grouping: Bool) {
        settings.usesGrouping = grouping
    }

    public func setCurrencyCode(_ code: String?) {
        settings.currencyCode = code
    }

    public func format(_ value: Double) -> String {
        if settings.style == .compact {
            return value.formatted(compactStyle)
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public func formatInteger(_ value: Int64) -> String {
        switch settings.style {
        case .compact:
            // Compact output is rounded, so a Double's precision is enough.
            return Double(value).formatted(compactStyle)
        case .decimal:
            return value.formatted(integerStyle)
        default:
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
    }

    public func parse(_ string: String) -> Double {
        formatter.number(from: string)?.doubleValue ?? .nan
    }

    // MARK: Formatters

    /// The cached formatter for the current settings. Compact uses a decimal
    /// formatter, for parsing.
    var formatter: NumberFormatter {
        var key = settings
        if key.style == .compact {
            key.style = .decimal
        }
        return FormatterCache.formatter(for: key) {
            Self.makeFormatter(key)
        }
    }

    static func makeFormatter(_ settings: Settings) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = LocaleIdentifiers.locale(settings.locale)
        formatter.numberStyle = numberStyle(settings.style)
        if let code = settings.currencyCode {
            formatter.currencyCode = code
        }
        if let minimum = settings.minimumFractionDigits {
            formatter.minimumFractionDigits = minimum
            formatter.maximumFractionDigits = max(formatter.maximumFractionDigits, minimum)
        }
        if let maximum = settings.maximumFractionDigits {
            formatter.maximumFractionDigits = maximum
            formatter.minimumFractionDigits = min(formatter.minimumFractionDigits, maximum)
        }
        if let grouping = settings.usesGrouping ?? (Self.isPOSIX(settings.locale) ? false : nil) {
            formatter.usesGroupingSeparator = grouping
        }
        return formatter
    }

    /// Whether `identifier` is the POSIX locale, which is for text a
    /// program reads back: Apple's Foundation doesn't group its digits,
    /// and Linux's does, so it's ungrouped everywhere unless asked.
    static func isPOSIX(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier.hasSuffix("_POSIX") || identifier.lowercased().hasSuffix("-posix")
    }

    static func numberStyle(_ style: NumberStyle) -> NumberFormatter.Style {
        switch style {
        case .decimal, .compact: .decimal
        case .percent: .percent
        case .currency: .currency
        case .scientific: .scientific
        case .spellOut: .spellOut
        case .ordinal: .ordinal
        }
    }

    /// The decimal style for integers: an integer has no fraction, but a
    /// minimum fraction length still shows zeros, as `NumberFormatter` does.
    private var integerStyle: IntegerFormatStyle<Int64> {
        var style = IntegerFormatStyle<Int64>(locale: LocaleIdentifiers.locale(settings.locale))
        if let minimum = settings.minimumFractionDigits, minimum > 0 {
            style = style.precision(.fractionLength(minimum))
        }
        if settings.usesGrouping == false || (settings.usesGrouping == nil && Self.isPOSIX(settings.locale)) {
            style = style.grouping(.never)
        }
        return style
    }

    private var compactStyle: FloatingPointFormatStyle<Double> {
        var style = FloatingPointFormatStyle<Double>(locale: LocaleIdentifiers.locale(settings.locale))
            .notation(.compactName)
        switch (settings.minimumFractionDigits, settings.maximumFractionDigits) {
        case (nil, nil):
            break
        case let (minimum?, nil):
            style = style.precision(.fractionLength(minimum...))
        case let (minimum, maximum?):
            style = style.precision(.fractionLength((minimum ?? 0)...maximum))
        }
        if settings.usesGrouping == false {
            style = style.grouping(.never)
        }
        return style
    }
}
