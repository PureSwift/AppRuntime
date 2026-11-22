import DynamicRuntime

/// A calendar in a time zone and a locale: taking a date apart, putting
/// one together, and counting in days, weeks and months
/// (`Documentation/Contracts/Formatting.md`).
///
/// Dates are seconds since 1970 UTC, and `nan` is no date. Fields cross
/// as `CalendarFields` text. A unit is a `CalendarUnit` raw value, and a
/// set of units has the bit for each. A host calendar never changes: what
/// `make` was given is what it is.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS, Linux | `Calendar` |
/// | Android | `android.icu.util.Calendar` |
/// | Browser | `Temporal`, where there is one |
@DynamicRuntime("org.pureswift.formatting.Calendar")
public protocol CalendarInfo: AnyObject {

    /// Nil for the user's calendar, zone and locale, whatever they become.
    /// `firstWeekday` and `minimumDays` 0: the locale's. Nil result: a
    /// calendar or a zone this host doesn't know.
    static func make(identifier: String?, timeZone: String?, locale: String?,
                     firstWeekday: Int32, minimumDays: Int32) -> Self?

    /// `gregorian`, `iso8601`, `buddhist`: for the user's calendar, what
    /// it is now.
    func identifier() -> String

    /// 1 is Sunday.
    func firstWeekday() -> Int32

    func minimumDaysInFirstWeek() -> Int32

    /// Every field of a moment.
    func fields(_ seconds: Double) -> String

    /// The moment the fields name; `nan` if there's none.
    func date(_ fields: String) -> Double

    /// A moment with amounts added, largest unit first. `wrapping` keeps
    /// each unit from carrying into the next.
    func adding(_ fields: String, to seconds: Double, wrapping: Bool) -> Double

    /// How far apart two moments are, in the units asked for.
    func difference(_ units: Int32, from start: Double, to end: Double) -> String

    /// Where the unit that holds a moment starts; `nan` if the calendar
    /// has no such unit.
    func start(_ unit: Int32, of seconds: Double) -> Double

    /// Where it ends, which is where the next starts.
    func end(_ unit: Int32, of seconds: Double) -> Double

    /// "1,31": the first value the smaller unit takes in the larger, and
    /// how many. Empty if there's no answer.
    func range(_ smaller: Int32, in larger: Int32, for seconds: Double) -> String

    /// Which one of the smaller unit a moment is in, within the larger:
    /// the day of the year. 0 if there's no answer.
    func ordinality(_ smaller: Int32, in larger: Int32, for seconds: Double) -> Int32

    /// The nearest moment after one, or before it, that has the fields
    /// given; `nan` if there's none. `policy` is a `CalendarMatchingPolicy`
    /// raw value.
    func nextDate(_ seconds: Double, matching fields: String, policy: Int32, backward: Bool) -> Double

    func isWeekend(_ seconds: Double) -> Bool

    /// Names in the calendar's locale. `kind` is a `CalendarSymbols` raw
    /// value. Weekdays start at Sunday.
    func symbols(_ kind: Int32) -> [String]
}

/// A field of a date, and its place in `CalendarFields`.
public enum CalendarUnit: Int32, CaseIterable, Sendable {
    case era = 0
    case year = 1
    case month = 2
    case day = 3
    case hour = 4
    case minute = 5
    case second = 6
    case nanosecond = 7
    /// 1 is Sunday, in every calendar.
    case weekday = 8
    /// The second Tuesday of a month is 2.
    case weekdayOrdinal = 9
    case weekOfMonth = 10
    case weekOfYear = 11
    case yearForWeekOfYear = 12
    case dayOfYear = 13
    /// 1 in a leap month, for calendars that have them.
    case isLeapMonth = 14

    /// The unit's bit in a set of units.
    public var bit: Int32 {
        1 << rawValue
    }
}

/// The fields of a date as `CalendarInfo` carries them: decimal integers
/// with commas between, in `CalendarUnit`'s order. One left empty isn't
/// given.
///
/// ```swift
/// CalendarFields("1,2026,3,28,13,30,5,0,7,4,4,13,2026,87,0")[.day]     // 28
/// ```
public struct CalendarFields: Equatable, Hashable, Sendable {

    private var values: [Int?]

    public init() {
        values = Array(repeating: nil, count: CalendarUnit.allCases.count)
    }

    /// What isn't a number is left out, and so is anything past the last
    /// unit.
    public init(_ text: String) {
        self.init()
        var index = 0
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard index < values.count else { break }
            values[index] = Int(part)
            index += 1
        }
    }

    public subscript(unit: CalendarUnit) -> Int? {
        get { values[Int(unit.rawValue)] }
        set { values[Int(unit.rawValue)] = newValue }
    }

    public var isEmpty: Bool {
        !values.contains { $0 != nil }
    }

    /// The bits of the units that are given.
    public var units: Int32 {
        var units: Int32 = 0
        for unit in CalendarUnit.allCases where self[unit] != nil {
            units |= unit.bit
        }
        return units
    }

    public var text: String {
        var text = ""
        var first = true
        for value in values {
            if !first { text += "," }
            first = false
            if let value { text += String(value) }
        }
        return text
    }
}

/// `CalendarInfo.nextDate`: Foundation's `Calendar.MatchingPolicy`.
public enum CalendarMatchingPolicy: Int32, Sendable {

    /// If the time doesn't exist that day, the next that does.
    case nextTime = 0

    /// The same, keeping the smaller fields: 02:30 that doesn't exist
    /// becomes 03:30.
    case nextTimePreservingSmallerComponents = 1

    /// The same, going back: 02:30 becomes 01:30.
    case previousTimePreservingSmallerComponents = 2

    /// Only a moment with exactly these fields.
    case strict = 3
}

/// `CalendarInfo.symbols(_:)`.
public enum CalendarSymbols: Int32, Sendable {
    case month = 0
    case shortMonth = 1
    case veryShortMonth = 2
    case standaloneMonth = 3
    case shortStandaloneMonth = 4
    case veryShortStandaloneMonth = 5
    case weekday = 6
    case shortWeekday = 7
    case veryShortWeekday = 8
    case standaloneWeekday = 9
    case shortStandaloneWeekday = 10
    case veryShortStandaloneWeekday = 11
    case era = 12
    case longEra = 13
    /// Two: AM, then PM.
    case amPm = 14
}
