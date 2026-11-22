import DynamicFormatting
import Foundation

/// The `DateFormat` contract over `DateFormatter`, and Swift Foundation's
/// `Date.AnchoredRelativeFormatStyle` for relative dates.
///
/// A new object uses the medium date and time styles, like
/// `java.text.DateFormat.getDateTimeInstance()`. Each object holds its
/// settings; the formatter for a set of settings comes from
/// `FormatterCache`. An unknown style is ignored, and an unknown time zone
/// is the user's; both are logged (`HostFormattingModule.log`).
public final class HostDateFormat: DateFormat {

    /// What overrides the styles.
    enum Pattern: Hashable {
        /// A fixed TR35 pattern, used as is.
        case fixed(String)
        /// Skeleton fields, localized with
        /// `setLocalizedDateFormatFromTemplate`.
        case template(String)
    }

    /// Everything that shapes the formatter.
    struct Settings: Hashable {
        var locale: String?
        /// An IANA identifier Foundation knows; nil for the user's.
        var timeZone: String?
        var dateStyle: DateStyle = .medium
        var timeStyle: DateStyle = .medium
        var pattern: Pattern?
    }

    private(set) var settings: Settings

    init(_ settings: Settings) {
        self.settings = settings
    }

    public static func make(locale: String?, timeZone: String?) -> HostDateFormat {
        var zone = timeZone
        if let timeZone, TimeZone(identifier: timeZone) == nil {
            HostFormattingModule.log?("DateFormat.make: unknown time zone \(timeZone); using the user's")
            zone = nil
        }
        return HostDateFormat(Settings(locale: locale, timeZone: zone))
    }

    public func setDateStyle(_ style: Int32) {
        guard let style = Self.style(style, method: "setDateStyle") else { return }
        settings.dateStyle = style
    }

    public func setTimeStyle(_ style: Int32) {
        guard let style = Self.style(style, method: "setTimeStyle") else { return }
        settings.timeStyle = style
    }

    public func setPattern(_ pattern: String?) {
        settings.pattern = pattern.map(Pattern.fixed)
    }

    public func setTemplate(_ template: String) {
        settings.pattern = .template(template)
    }

    public func format(_ milliseconds: Int64) -> String {
        formatter.string(from: Self.date(milliseconds))
    }

    public func parse(_ string: String) -> Int64 {
        guard let date = formatter.date(from: string) else {
            return .min
        }
        return Self.milliseconds(date)
    }

    /// "3 hours ago", "in 2 days": `milliseconds` as seen from `reference`.
    public func formatRelative(_ milliseconds: Int64, reference: Int64) -> String {
        let date = Self.date(milliseconds)
        let reference = Self.date(reference)
        let locale = LocaleIdentifiers.locale(settings.locale)
        var calendar = locale.calendar
        calendar.timeZone = Self.timeZone(settings.timeZone)
        if #available(iOS 18, macOS 15, *) {
            // The style describes its anchor as seen from the date it
            // formats.
            let style = Date.AnchoredRelativeFormatStyle(
                anchor: date,
                presentation: .numeric,
                unitsStyle: .wide,
                locale: locale,
                calendar: calendar
            )
            return style.format(reference)
        }
        #if canImport(Darwin)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        return formatter.localizedString(for: date, relativeTo: reference)
        #else
        fatalError("Swift Foundation has the anchored relative style everywhere but older Apple platforms")
        #endif
    }

    // MARK: Formatters

    var formatter: DateFormatter {
        let settings = settings
        return FormatterCache.formatter(for: settings) {
            Self.makeFormatter(settings)
        }
    }

    static func makeFormatter(_ settings: Settings) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LocaleIdentifiers.locale(settings.locale)
        formatter.timeZone = timeZone(settings.timeZone)
        switch settings.pattern {
        case .fixed(let pattern):
            formatter.dateFormat = pattern
        case .template(let template):
            formatter.setLocalizedDateFormatFromTemplate(template)
        case nil:
            formatter.dateStyle = dateFormatterStyle(settings.dateStyle)
            formatter.timeStyle = dateFormatterStyle(settings.timeStyle)
        }
        return formatter
    }

    // MARK: Conversions

    static func dateFormatterStyle(_ style: DateStyle) -> DateFormatter.Style {
        switch style {
        case .none: .none
        case .short: .short
        case .medium: .medium
        case .long: .long
        case .full: .full
        }
    }

    static func timeZone(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? HostSystemClock.userTimeZone()
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func style(_ raw: Int32, method: String) -> DateStyle? {
        guard let style = DateStyle(rawValue: raw) else {
            HostFormattingModule.log?("DateFormat.\(method): unknown style \(raw); ignored")
            return nil
        }
        return style
    }
}
