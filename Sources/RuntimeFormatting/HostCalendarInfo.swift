import DynamicFormatting
import Foundation

/// The `CalendarInfo` contract over `Calendar`.
///
/// An object holds what `make` was given and never changes. What was nil
/// is the user's, asked for at each call, so a calendar made for the user
/// follows their settings. A moment that isn't a number, a unit, a kind
/// or a policy the contract doesn't have, answers as no result.
public final class HostCalendarInfo: CalendarInfo {

    struct Settings: Hashable {
        /// One of `identifiers`' names; nil for the user's.
        var identifier: String?
        var timeZone: String?
        var locale: String?
        /// 1...7, or 0 for the locale's.
        var firstWeekday: Int32 = 0
        var minimumDays: Int32 = 0

        /// Whether any of it is the user's, and may change.
        var followsUser: Bool {
            identifier == nil || timeZone == nil || locale == nil
        }
    }

    let settings: Settings

    /// The calendar, when none of it is the user's.
    private let fixed: Calendar?

    init(_ settings: Settings) {
        self.settings = settings
        self.fixed = settings.followsUser ? nil : Self.makeCalendar(settings)
    }

    var calendar: Calendar {
        fixed ?? Self.makeCalendar(settings)
    }

    public static func make(identifier: String?, timeZone: String?, locale: String?,
                            firstWeekday: Int32, minimumDays: Int32) -> HostCalendarInfo? {
        if let identifier, identifiers[identifier] == nil {
            return nil
        }
        if let timeZone, HostTimeZoneInfo.timeZone(timeZone) == nil {
            return nil
        }
        return HostCalendarInfo(Settings(
            identifier: identifier,
            timeZone: timeZone,
            locale: locale,
            firstWeekday: (1...7).contains(firstWeekday) ? firstWeekday : 0,
            minimumDays: (1...7).contains(minimumDays) ? minimumDays : 0
        ))
    }

    static func makeCalendar(_ settings: Settings) -> Calendar {
        let locale = LocaleIdentifiers.locale(settings.locale)
        var calendar: Calendar
        if let identifier = settings.identifier.flatMap({ identifiers[$0] }) {
            calendar = Calendar(identifier: identifier)
            calendar.locale = locale
        } else {
            // The user's calendar, with their own first weekday if they
            // set one.
            calendar = LocaleIdentifiers.user.calendar
            if settings.locale != nil {
                calendar.locale = locale
            }
        }
        calendar.timeZone = settings.timeZone.flatMap(HostTimeZoneInfo.timeZone) ?? HostSystemClock.userTimeZone()
        if settings.firstWeekday != 0 {
            calendar.firstWeekday = Int(settings.firstWeekday)
        }
        if settings.minimumDays != 0 {
            calendar.minimumDaysInFirstWeek = Int(settings.minimumDays)
        }
        return calendar
    }

    // MARK: The calendar

    public func identifier() -> String {
        Self.name(calendar.identifier)
    }

    public func firstWeekday() -> Int32 {
        Int32(calendar.firstWeekday)
    }

    public func minimumDaysInFirstWeek() -> Int32 {
        Int32(calendar.minimumDaysInFirstWeek)
    }

    // MARK: Dates and fields

    public func fields(_ seconds: Double) -> String {
        guard let date = Self.date(seconds) else { return "" }
        let calendar = calendar
        let components = calendar.dateComponents(Self.everyComponent, from: date)
        var fields = Self.fields(components)
        fields[.dayOfYear] = calendar.ordinality(of: .day, in: .year, for: date)
        fields[.isLeapMonth] = components.isLeapMonth == true ? 1 : 0
        return fields.text
    }

    public func date(_ fields: String) -> Double {
        let fields = CalendarFields(fields)
        guard !fields.isEmpty else { return .nan }
        return Self.seconds(calendar.date(from: Self.components(fields)))
    }

    public func adding(_ fields: String, to seconds: Double, wrapping: Bool) -> Double {
        guard let date = Self.date(seconds) else { return .nan }
        let fields = CalendarFields(fields)
        guard !fields.isEmpty else { return seconds }
        return Self.seconds(calendar.date(byAdding: Self.components(fields), to: date, wrappingComponents: wrapping))
    }

    public func difference(_ units: Int32, from start: Double, to end: Double) -> String {
        guard let start = Self.date(start), let end = Self.date(end) else { return "" }
        var components: Set<Calendar.Component> = []
        for unit in CalendarUnit.allCases where units & unit.bit != 0 {
            if let component = Self.component(unit) {
                components.insert(component)
            }
        }
        guard !components.isEmpty else { return "" }
        return Self.fields(calendar.dateComponents(components, from: start, to: end)).text
    }

    public func start(_ unit: Int32, of seconds: Double) -> Double {
        Self.seconds(interval(unit, seconds)?.start)
    }

    public func end(_ unit: Int32, of seconds: Double) -> Double {
        Self.seconds(interval(unit, seconds)?.end)
    }

    private func interval(_ unit: Int32, _ seconds: Double) -> DateInterval? {
        guard let date = Self.date(seconds), let component = Self.component(unit) else { return nil }
        return calendar.dateInterval(of: component, for: date)
    }

    public func range(_ smaller: Int32, in larger: Int32, for seconds: Double) -> String {
        guard let date = Self.date(seconds),
              let smaller = Self.component(smaller), let larger = Self.component(larger),
              let range = calendar.range(of: smaller, in: larger, for: date) else {
            return ""
        }
        return "\(range.lowerBound),\(range.count)"
    }

    public func ordinality(_ smaller: Int32, in larger: Int32, for seconds: Double) -> Int32 {
        guard let date = Self.date(seconds),
              let smaller = Self.component(smaller), let larger = Self.component(larger),
              let ordinality = calendar.ordinality(of: smaller, in: larger, for: date) else {
            return 0
        }
        return Int32(clamping: ordinality)
    }

    public func nextDate(_ seconds: Double, matching fields: String, policy: Int32, backward: Bool) -> Double {
        let fields = CalendarFields(fields)
        guard let date = Self.date(seconds), !fields.isEmpty,
              let policy = CalendarMatchingPolicy(rawValue: policy) else {
            return .nan
        }
        return Self.seconds(calendar.nextDate(
            after: date,
            matching: Self.components(fields),
            matchingPolicy: Self.matchingPolicy(policy),
            repeatedTimePolicy: .first,
            direction: backward ? .backward : .forward
        ))
    }

    public func isWeekend(_ seconds: Double) -> Bool {
        guard let date = Self.date(seconds) else { return false }
        return calendar.isDateInWeekend(date)
    }

    public func symbols(_ kind: Int32) -> [String] {
        guard let kind = CalendarSymbols(rawValue: kind) else {
            HostFormattingModule.log?("Calendar.symbols: unknown kind \(kind); none")
            return []
        }
        let calendar = calendar
        switch kind {
        case .month: return calendar.monthSymbols
        case .shortMonth: return calendar.shortMonthSymbols
        case .veryShortMonth: return calendar.veryShortMonthSymbols
        case .standaloneMonth: return calendar.standaloneMonthSymbols
        case .shortStandaloneMonth: return calendar.shortStandaloneMonthSymbols
        case .veryShortStandaloneMonth: return calendar.veryShortStandaloneMonthSymbols
        case .weekday: return calendar.weekdaySymbols
        case .shortWeekday: return calendar.shortWeekdaySymbols
        case .veryShortWeekday: return calendar.veryShortWeekdaySymbols
        case .standaloneWeekday: return calendar.standaloneWeekdaySymbols
        case .shortStandaloneWeekday: return calendar.shortStandaloneWeekdaySymbols
        case .veryShortStandaloneWeekday: return calendar.veryShortStandaloneWeekdaySymbols
        case .era: return calendar.eraSymbols
        case .longEra: return calendar.longEraSymbols
        case .amPm: return [calendar.amSymbol, calendar.pmSymbol]
        }
    }

    // MARK: Conversions

    /// The calendars the contract names, by their Unicode names.
    static let identifiers: [String: Calendar.Identifier] = [
        "gregorian": .gregorian,
        "iso8601": .iso8601,
        "buddhist": .buddhist,
        "chinese": .chinese,
        "coptic": .coptic,
        "ethiopic": .ethiopicAmeteMihret,
        "ethioaa": .ethiopicAmeteAlem,
        "hebrew": .hebrew,
        "indian": .indian,
        "islamic": .islamic,
        "islamic-civil": .islamicCivil,
        "islamic-tbla": .islamicTabular,
        "islamic-umalqura": .islamicUmmAlQura,
        "japanese": .japanese,
        "persian": .persian,
        "roc": .republicOfChina,
    ]

    /// A calendar's name. One the contract has no name for, which only
    /// the user's can be, is `gregorian`.
    static func name(_ identifier: Calendar.Identifier) -> String {
        identifiers.first { $0.value == identifier }?.key ?? "gregorian"
    }

    /// What `fields(_:)` asks Foundation for. The day of the year is
    /// counted apart: it's a component only from macOS 15 and iOS 18.
    static let everyComponent: Set<Calendar.Component> = [
        .era, .year, .month, .day, .hour, .minute, .second, .nanosecond,
        .weekday, .weekdayOrdinal, .weekOfMonth, .weekOfYear, .yearForWeekOfYear,
    ]

    static func component(_ unit: Int32) -> Calendar.Component? {
        CalendarUnit(rawValue: unit).flatMap(component)
    }

    static func component(_ unit: CalendarUnit) -> Calendar.Component? {
        switch unit {
        case .era: return .era
        case .year: return .year
        case .month: return .month
        case .day: return .day
        case .hour: return .hour
        case .minute: return .minute
        case .second: return .second
        case .nanosecond: return .nanosecond
        case .weekday: return .weekday
        case .weekdayOrdinal: return .weekdayOrdinal
        case .weekOfMonth: return .weekOfMonth
        case .weekOfYear: return .weekOfYear
        case .yearForWeekOfYear: return .yearForWeekOfYear
        case .dayOfYear:
            if #available(iOS 18, macOS 15, *) {
                return .dayOfYear
            }
            return nil
        case .isLeapMonth: return nil
        }
    }

    static func fields(_ components: DateComponents) -> CalendarFields {
        var fields = CalendarFields()
        fields[.era] = components.era
        fields[.year] = components.year
        fields[.month] = components.month
        fields[.day] = components.day
        fields[.hour] = components.hour
        fields[.minute] = components.minute
        fields[.second] = components.second
        fields[.nanosecond] = components.nanosecond
        fields[.weekday] = components.weekday
        fields[.weekdayOrdinal] = components.weekdayOrdinal
        fields[.weekOfMonth] = components.weekOfMonth
        fields[.weekOfYear] = components.weekOfYear
        fields[.yearForWeekOfYear] = components.yearForWeekOfYear
        if #available(iOS 18, macOS 15, *) {
            fields[.dayOfYear] = components.dayOfYear
        }
        fields[.isLeapMonth] = components.isLeapMonth.map { $0 ? 1 : 0 }
        return fields
    }

    static func components(_ fields: CalendarFields) -> DateComponents {
        var components = DateComponents()
        components.era = fields[.era]
        components.year = fields[.year]
        components.month = fields[.month]
        components.day = fields[.day]
        components.hour = fields[.hour]
        components.minute = fields[.minute]
        components.second = fields[.second]
        components.nanosecond = fields[.nanosecond]
        components.weekday = fields[.weekday]
        components.weekdayOrdinal = fields[.weekdayOrdinal]
        components.weekOfMonth = fields[.weekOfMonth]
        components.weekOfYear = fields[.weekOfYear]
        components.yearForWeekOfYear = fields[.yearForWeekOfYear]
        if let dayOfYear = fields[.dayOfYear] {
            if #available(iOS 18, macOS 15, *) {
                components.dayOfYear = dayOfYear
            } else if fields[.month] == nil, fields[.day] == nil {
                // Day 87 of the year is the 87th of January, carried on.
                components.month = 1
                components.day = dayOfYear
            }
        }
        if let leap = fields[.isLeapMonth] {
            components.isLeapMonth = leap != 0
        }
        return components
    }

    static func matchingPolicy(_ policy: CalendarMatchingPolicy) -> Calendar.MatchingPolicy {
        switch policy {
        case .nextTime: .nextTime
        case .nextTimePreservingSmallerComponents: .nextTimePreservingSmallerComponents
        case .previousTimePreservingSmallerComponents: .previousTimePreservingSmallerComponents
        case .strict: .strict
        }
    }

    static func date(_ seconds: Double) -> Date? {
        seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }

    static func seconds(_ date: Date?) -> Double {
        date?.timeIntervalSince1970 ?? .nan
    }
}
