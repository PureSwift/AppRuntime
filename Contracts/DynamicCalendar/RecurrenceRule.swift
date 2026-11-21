/// How an event repeats: `EKRecurrenceRule`'s place, with RFC 5545's
/// `RRULE` as its text.
///
/// ```swift
/// RecurrenceRule(.daily)
/// RecurrenceRule(.weekly, interval: 2, daysOfWeek: [.monday, .wednesday])
/// RecurrenceRule(.monthly, daysOfMonth: [1, 15], end: .until(millisecondsSince1970))
/// RecurrenceRule(.monthly, daysOfWeek: [.friday], setPositions: [-1])     // the last Friday
/// RecurrenceRule(.monthly, daysOfWeek: [.nth(2, .tuesday)])               // the second Tuesday
/// RecurrenceRule(.yearly, end: .count(5))
/// RecurrenceRule(rrule: "FREQ=WEEKLY;BYDAY=TU;COUNT=10")
/// ```
///
/// A rule crosses to the host as its text. `init?(rrule:)` reads any rule
/// and keeps the parts it has no property for, so saving one back loses
/// nothing. A store may refuse a rule it can't hold; daily, weekly,
/// monthly and yearly rules with the properties here work everywhere.
public struct RecurrenceRule: Equatable, Hashable, Sendable {

    /// RFC 5545's frequencies. Calendars use the last four; a store may
    /// refuse the others.
    public enum Frequency: String, Sendable, CaseIterable {
        case secondly = "SECONDLY"
        case minutely = "MINUTELY"
        case hourly = "HOURLY"
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    /// Sunday is 1, as EventKit and Foundation count.
    public enum Weekday: Int, Sendable, CaseIterable {
        case sunday = 1
        case monday
        case tuesday
        case wednesday
        case thursday
        case friday
        case saturday

        /// RFC 5545's two letters.
        public var code: String {
            switch self {
            case .sunday: return "SU"
            case .monday: return "MO"
            case .tuesday: return "TU"
            case .wednesday: return "WE"
            case .thursday: return "TH"
            case .friday: return "FR"
            case .saturday: return "SA"
            }
        }

        public init?(code: String) {
            guard let match = Weekday.allCases.first(where: { $0.code == code }) else { return nil }
            self = match
        }
    }

    /// A weekday, or one of them in the month or the year: every Monday,
    /// the second Tuesday, the last Friday.
    public struct DayOfWeek: Equatable, Hashable, Sendable {

        public var weekday: Weekday

        /// 0 is every one. 1 is the first, 2 the second; -1 is the last.
        public var week: Int

        public init(_ weekday: Weekday, week: Int = 0) {
            self.weekday = weekday
            self.week = week
        }

        public static let sunday = DayOfWeek(.sunday)
        public static let monday = DayOfWeek(.monday)
        public static let tuesday = DayOfWeek(.tuesday)
        public static let wednesday = DayOfWeek(.wednesday)
        public static let thursday = DayOfWeek(.thursday)
        public static let friday = DayOfWeek(.friday)
        public static let saturday = DayOfWeek(.saturday)

        /// The `week`th `weekday`: `.nth(2, .tuesday)`, `.nth(-1, .friday)`.
        public static func nth(_ week: Int, _ weekday: Weekday) -> DayOfWeek {
            DayOfWeek(weekday, week: week)
        }
    }

    /// When it stops.
    public enum End: Equatable, Hashable, Sendable {

        case never

        /// After this many occurrences, the first included.
        case count(Int)

        /// No occurrence starts after this: milliseconds since 1970.
        case until(Int64)
    }

    public var frequency: Frequency

    /// Every how many: 1 or more.
    public var interval: Int

    public var daysOfWeek: [DayOfWeek]

    /// 1 to 31, or -1 to -31 from the month's end.
    public var daysOfMonth: [Int]

    /// 1 to 12.
    public var monthsOfYear: [Int]

    /// Which of a period's occurrences to keep: 1 the first, -1 the last.
    public var setPositions: [Int]

    public var end: End

    /// The parts of a rule read from text that have no property here, as
    /// `KEY=VALUE`: `WKST=MO`, `BYHOUR=9`. They're written back.
    public private(set) var otherParts: [String]

    public init(
        _ frequency: Frequency, interval: Int = 1, daysOfWeek: [DayOfWeek] = [], daysOfMonth: [Int] = [],
        monthsOfYear: [Int] = [], setPositions: [Int] = [], end: End = .never
    ) {
        self.frequency = frequency
        self.interval = max(interval, 1)
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.setPositions = setPositions
        self.end = end
        self.otherParts = []
    }

    // MARK: Text

    /// Reads an `RRULE` value, with or without `RRULE:` in front. `nil`
    /// for text that isn't one: no frequency, or a part that can't be
    /// read.
    public init?(rrule: String) {
        var text = Self.uppercased(rrule)
        if text.hasPrefix("RRULE:") {
            text = String(text.dropFirst(6))
        }
        var frequency: Frequency?
        var interval = 1
        var daysOfWeek: [DayOfWeek] = []
        var daysOfMonth: [Int] = []
        var monthsOfYear: [Int] = []
        var setPositions: [Int] = []
        var end = End.never
        var other: [String] = []
        for part in text.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let value = String(pieces[1])
            switch String(pieces[0]) {
            case "FREQ":
                guard let read = Frequency(rawValue: value) else { return nil }
                frequency = read
            case "INTERVAL":
                guard let read = Int(value), read >= 1 else { return nil }
                interval = read
            case "COUNT":
                guard let read = Int(value), read >= 1 else { return nil }
                end = .count(read)
            case "UNTIL":
                guard let read = Self.milliseconds(until: value) else { return nil }
                end = .until(read)
            case "BYDAY":
                for item in value.split(separator: ",") {
                    guard let day = Self.dayOfWeek(String(item)) else { return nil }
                    daysOfWeek.append(day)
                }
            case "BYMONTHDAY":
                guard let read = Self.numbers(value, in: 1...31, signed: true) else { return nil }
                daysOfMonth = read
            case "BYMONTH":
                guard let read = Self.numbers(value, in: 1...12, signed: false) else { return nil }
                monthsOfYear = read
            case "BYSETPOS":
                guard let read = Self.numbers(value, in: 1...366, signed: true) else { return nil }
                setPositions = read
            default:
                other.append(String(part))
            }
        }
        guard let frequency else { return nil }
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.setPositions = setPositions
        self.end = end
        self.otherParts = other
    }

    /// The rule as an `RRULE` value, without `RRULE:` in front.
    public var rrule: String {
        var parts = ["FREQ=" + frequency.rawValue]
        if interval > 1 {
            parts.append("INTERVAL=" + String(interval))
        }
        if !monthsOfYear.isEmpty {
            parts.append("BYMONTH=" + Self.list(monthsOfYear.map { String($0) }))
        }
        if !daysOfMonth.isEmpty {
            parts.append("BYMONTHDAY=" + Self.list(daysOfMonth.map { String($0) }))
        }
        if !daysOfWeek.isEmpty {
            parts.append("BYDAY=" + Self.list(daysOfWeek.map { ($0.week == 0 ? "" : String($0.week)) + $0.weekday.code }))
        }
        if !setPositions.isEmpty {
            parts.append("BYSETPOS=" + Self.list(setPositions.map { String($0) }))
        }
        switch end {
        case .never: break
        case .count(let count): parts.append("COUNT=" + String(max(count, 1)))
        case .until(let until): parts.append("UNTIL=" + Self.until(milliseconds: until))
        }
        parts.append(contentsOf: otherParts)
        return Self.list(parts, separator: ";")
    }

    private static func list(_ items: [String], separator: String = ",") -> String {
        var text = ""
        for item in items {
            if !text.isEmpty { text += separator }
            text += item
        }
        return text
    }

    /// A rule's text is ASCII, so this needs no Unicode tables.
    private static func uppercased(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for byte in text.utf8 where byte != 0x20 && byte != 0x0D && byte != 0x0A {
            bytes.append(byte >= 0x61 && byte <= 0x7A ? byte - 32 : byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func numbers(_ value: String, in range: ClosedRange<Int>, signed: Bool) -> [Int]? {
        var numbers: [Int] = []
        for item in value.split(separator: ",") {
            guard let number = Int(item) else { return nil }
            guard range.contains(number) || (signed && range.contains(-number)) else { return nil }
            numbers.append(number)
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// `MO`, `2TU`, `-1FR`.
    private static func dayOfWeek(_ item: String) -> DayOfWeek? {
        guard item.utf8.count >= 2, let weekday = Weekday(code: String(item.suffix(2))) else { return nil }
        let ordinal = item.dropLast(2)
        if ordinal.isEmpty {
            return DayOfWeek(weekday)
        }
        guard let week = Int(ordinal), week != 0, week >= -53, week <= 53 else { return nil }
        return DayOfWeek(weekday, week: week)
    }

    // MARK: UNTIL

    /// `20261231T235959Z`, or a date alone, as milliseconds since 1970. A
    /// time with no `Z` is read as UTC.
    private static func milliseconds(until value: String) -> Int64? {
        let bytes = Array(value.utf8)
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var result = 0
            for byte in bytes[start ..< start + count] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                result = result * 10 + Int(byte - 0x30)
            }
            return result
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var seconds = 0
        if bytes.count == 8 {
            // A date: the whole of that day.
            seconds = 86_399
        } else {
            guard bytes.count == 15 || (bytes.count == 16 && bytes[15] == 0x5A), bytes[8] == 0x54,
                  let hour = number(9, 2), let minute = number(11, 2), let second = number(13, 2),
                  hour < 24, minute < 60, second < 61 else { return nil }
            seconds = hour * 3600 + minute * 60 + second
        }
        return (CivilDate.days(year: year, month: month, day: day) * 86_400 + Int64(seconds)) * 1000
    }

    private static func until(milliseconds: Int64) -> String {
        // Floor, for times before 1970.
        var seconds = milliseconds / 1000
        if milliseconds % 1000 < 0 { seconds -= 1 }
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 {
            rest += 86_400
            days -= 1
        }
        let date = CivilDate(days: days)
        func digits(_ value: Int, _ count: Int) -> String {
            var text = String(value)
            while text.utf8.count < count { text = "0" + text }
            return text
        }
        return digits(date.year, 4) + digits(date.month, 2) + digits(date.day, 2) + "T"
            + digits(Int(rest / 3600), 2) + digits(Int(rest % 3600 / 60), 2) + digits(Int(rest % 60), 2) + "Z"
    }
}

/// A day of the Gregorian calendar, and its number since 1 January 1970.
/// Embedded guests have no Foundation, so this is the arithmetic itself.
public struct CivilDate: Equatable, Hashable, Sendable {

    public var year: Int

    public var month: Int

    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `days` after 1 January 1970.
    public init(days: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        self.init(year: Int(year), month: Int(month), day: Int(day))
    }

    /// Days since 1 January 1970.
    public var days: Int64 {
        Self.days(year: year, month: month, day: day)
    }

    public static func days(year: Int, month: Int, day: Int) -> Int64 {
        let year = Int64(month <= 2 ? year - 1 : year)
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let shiftedMonth = Int64(month > 2 ? month - 3 : month + 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day a moment falls on, in UTC.
    public init(millisecondsSince1970 milliseconds: Int64) {
        var days = milliseconds / 86_400_000
        if milliseconds % 86_400_000 < 0 { days -= 1 }
        self.init(days: days)
    }

    /// 00:00 UTC of the day, in milliseconds since 1970: where an all-day
    /// event starts.
    public var millisecondsSince1970: Int64 {
        days * 86_400_000
    }

    /// The weekday, as the calendar types count: Sunday is 1.
    public var weekday: RecurrenceRule.Weekday {
        // 1 January 1970 was a Thursday.
        let index = Int(((days % 7) + 7 + 4) % 7)
        return RecurrenceRule.Weekday(rawValue: index + 1) ?? .sunday
    }
}
