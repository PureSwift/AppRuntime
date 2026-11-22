import DynamicFormatting
import DynamicRuntime
import Foundation
import RuntimeNative
import Testing
@testable import RuntimeFormatting

/// Seconds since 1970 for an ISO 8601 moment, by a parser the host under
/// test doesn't use.
func at(_ text: String) -> Double {
    ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970
}

/// What a guest's delegate was told.
final class ClockRecorder: SystemClockDelegate {

    var changes: [SystemClockChange] = []

    func didChange(_ changes: Int32) {
        self.changes.append(SystemClockChange(rawValue: changes))
    }
}

/// The clock, time zone, calendar and collator contracts over Swift
/// Foundation, on macOS and Linux. Part of the serialized suite: they
/// share the clock's settings and the native runtime.
extension RuntimeFormattingTests {

    /// 13:30:05 on Saturday 28 March 2026 in Berlin, the day before its
    /// clocks go forward.
    static let saturday = at("2026-03-28T12:30:05Z")

    func berlin(locale: String = "en-US", identifier: String = "gregorian",
                firstWeekday: Int32 = 0, minimumDays: Int32 = 0) throws -> HostCalendarInfo {
        try #require(HostCalendarInfo.make(identifier: identifier, timeZone: "Europe/Berlin", locale: locale,
                                           firstWeekday: firstWeekday, minimumDays: minimumDays))
    }

    func fields(_ values: [CalendarUnit: Int]) -> String {
        var fields = CalendarFields()
        for (unit, value) in values {
            fields[unit] = value
        }
        return fields.text
    }

    // MARK: Fields

    @Test func fieldsText() {
        let text = "1,2026,3,28,13,30,5,0,7,4,4,13,2026,87,0"
        let fields = CalendarFields(text)
        #expect(fields[.era] == 1)
        #expect(fields[.day] == 28)
        #expect(fields[.dayOfYear] == 87)
        #expect(fields[.isLeapMonth] == 0)
        #expect(fields.text == text)
        #expect(fields.units == (1 << 15) - 1)

        var some = CalendarFields()
        #expect(some.isEmpty)
        #expect(some.text == ",,,,,,,,,,,,,,")
        some[.hour] = 7
        some[.minute] = 0
        #expect(some.text == ",,,,7,0,,,,,,,,,")
        #expect(some.units == CalendarUnit.hour.bit | CalendarUnit.minute.bit)
        #expect(CalendarFields(some.text) == some)

        // What isn't a number is left out, and so is what's past the end.
        let odd = CalendarFields("x,2026,,-3,1,2,3,4,5,6,7,8,9,10,11,12,13")
        #expect(odd[.era] == nil)
        #expect(odd[.year] == 2026)
        #expect(odd[.day] == -3)
        #expect(odd[.isLeapMonth] == 11)
        #expect(CalendarFields("").isEmpty)
    }

    // MARK: Calendar

    @Test func fieldsOfAMoment() throws {
        let calendar = try berlin()
        #expect(calendar.fields(Self.saturday) == "1,2026,3,28,13,30,5,0,7,4,4,13,2026,87,0")
        #expect(calendar.identifier() == "gregorian")

        // The same moment is another day in Tokyo.
        let tokyo = try #require(HostCalendarInfo.make(identifier: "gregorian", timeZone: "Asia/Tokyo", locale: "en-US",
                                                       firstWeekday: 0, minimumDays: 0))
        let late = CalendarFields(tokyo.fields(at("2026-03-28T16:00:00Z")))
        #expect(late[.day] == 29)
        #expect(late[.hour] == 1)
        #expect(late[.weekday] == 1)
    }

    @Test func dateFromFields() throws {
        let calendar = try berlin()
        let whole = fields([.year: 2026, .month: 3, .day: 28, .hour: 13, .minute: 30, .second: 5])
        #expect(calendar.date(whole) == Self.saturday)
        // What's left out is the start of it.
        #expect(calendar.date(fields([.year: 2026, .month: 3, .day: 28])) == at("2026-03-27T23:00:00Z"))
        #expect(calendar.date(fields([.year: 2026, .dayOfYear: 87])) == at("2026-03-27T23:00:00Z"))
        #expect(calendar.date("").isNaN)
        // It reads back.
        #expect(calendar.date(calendar.fields(Self.saturday)) == Self.saturday)
    }

    /// The night the clocks go forward has no 02:30, and the night they go
    /// back has two.
    @Test func timesThatArentAndTimesThatAreTwice() throws {
        let calendar = try berlin()
        let missing = fields([.year: 2026, .month: 3, .day: 29, .hour: 2, .minute: 30])
        #expect(calendar.date(missing) == at("2026-03-29T01:30:00Z"), "03:30, moved later by the gap")
        let twice = fields([.year: 2026, .month: 10, .day: 25, .hour: 2, .minute: 30])
        #expect(calendar.date(twice) == at("2026-10-25T00:30:00Z"), "the first 02:30")

        // South of the equator the clocks go the other way round the year.
        let sydney = try #require(HostCalendarInfo.make(identifier: "gregorian", timeZone: "Australia/Sydney", locale: "en-AU",
                                                        firstWeekday: 0, minimumDays: 0))
        let spring = fields([.year: 2026, .month: 10, .day: 4, .hour: 2, .minute: 30])
        #expect(sydney.date(spring) == at("2026-10-03T16:30:00Z"), "03:30 in summer time")
    }

    @Test func adding() throws {
        let calendar = try berlin()
        let month = fields([.month: 1])
        #expect(calendar.adding(month, to: at("2026-01-31T11:00:00Z"), wrapping: false) == at("2026-02-28T11:00:00Z"))
        #expect(calendar.adding(month, to: at("2024-01-31T11:00:00Z"), wrapping: false) == at("2024-02-29T11:00:00Z"))
        #expect(calendar.adding(fields([.year: 1]), to: at("2024-02-29T11:00:00Z"), wrapping: false) == at("2025-02-28T11:00:00Z"))
        #expect(calendar.adding(fields([.month: -1]), to: at("2026-03-31T10:00:00Z"), wrapping: false) == at("2026-02-28T11:00:00Z"))

        // A day keeps the time on the clock; 24 hours are 24 hours.
        let noon = at("2026-03-28T11:00:00Z")
        #expect(calendar.adding(fields([.day: 1]), to: noon, wrapping: false) == at("2026-03-29T10:00:00Z"))
        #expect(calendar.adding(fields([.hour: 24]), to: noon, wrapping: false) == at("2026-03-29T11:00:00Z"))

        // The fraction of a second comes back.
        #expect(calendar.adding(fields([.day: 2]), to: noon + 0.25, wrapping: false) == at("2026-03-30T10:00:00Z") + 0.25)

        // Wrapping doesn't carry: the day after the 31st is the 1st of the same month.
        #expect(calendar.adding(fields([.day: 1]), to: at("2026-01-31T11:00:00Z"), wrapping: true) == at("2026-01-01T11:00:00Z"))

        #expect(calendar.adding("", to: noon, wrapping: false) == noon)
        #expect(calendar.adding(month, to: .nan, wrapping: false).isNaN)
    }

    @Test func difference() throws {
        let calendar = try berlin()
        let start = at("2024-03-01T11:00:00Z")
        let end = at("2026-03-28T12:30:05Z")
        let days = CalendarFields(calendar.difference(CalendarUnit.day.bit, from: start, to: end))
        #expect(days[.day] == 757)
        #expect(days[.year] == nil)
        let parts = CalendarFields(calendar.difference(
            CalendarUnit.year.bit | CalendarUnit.month.bit | CalendarUnit.day.bit, from: start, to: end))
        #expect(parts[.year] == 2)
        #expect(parts[.month] == 0)
        #expect(parts[.day] == 27)
        // Backwards is negative.
        #expect(CalendarFields(calendar.difference(CalendarUnit.hour.bit, from: end, to: end - 7200))[.hour] == -2)
        #expect(calendar.difference(0, from: start, to: end) == "")
        #expect(calendar.difference(CalendarUnit.isLeapMonth.bit, from: start, to: end) == "")
    }

    @Test func whereUnitsStartAndEnd() throws {
        let calendar = try berlin()
        let month = CalendarUnit.month.rawValue
        #expect(calendar.start(month, of: Self.saturday) == at("2026-02-28T23:00:00Z"))
        #expect(calendar.end(month, of: Self.saturday) == at("2026-03-31T22:00:00Z"), "April begins in summer time")
        let day = CalendarUnit.day.rawValue
        #expect(calendar.start(day, of: Self.saturday) == at("2026-03-27T23:00:00Z"))
        // The day the clocks go forward has 23 hours.
        let sunday = at("2026-03-29T10:00:00Z")
        #expect(calendar.end(day, of: sunday) - calendar.start(day, of: sunday) == 23 * 3600)

        // A week starts where the calendar says.
        let week = CalendarUnit.weekOfYear.rawValue
        #expect(calendar.start(week, of: Self.saturday) == at("2026-03-21T23:00:00Z"), "Sunday")
        #expect(try berlin(firstWeekday: 2).start(week, of: Self.saturday) == at("2026-03-22T23:00:00Z"), "Monday")
        #expect(try berlin(locale: "en-GB").start(week, of: Self.saturday) == at("2026-03-22T23:00:00Z"))

        #expect(calendar.start(99, of: Self.saturday).isNaN)
        #expect(calendar.end(CalendarUnit.isLeapMonth.rawValue, of: Self.saturday).isNaN)
        #expect(calendar.start(month, of: .nan).isNaN)
    }

    @Test func rangesAndOrdinals() throws {
        let calendar = try berlin()
        let day = CalendarUnit.day.rawValue, month = CalendarUnit.month.rawValue, year = CalendarUnit.year.rawValue
        #expect(calendar.range(day, in: month, for: Self.saturday) == "1,31")
        #expect(calendar.range(day, in: month, for: at("2024-02-10T12:00:00Z")) == "1,29")
        #expect(calendar.range(day, in: month, for: at("2026-02-10T12:00:00Z")) == "1,28")
        #expect(calendar.range(month, in: year, for: Self.saturday) == "1,12")
        #expect(calendar.ordinality(day, in: year, for: Self.saturday) == 87)
        #expect(calendar.ordinality(day, in: month, for: Self.saturday) == 28)
        #expect(calendar.range(99, in: month, for: Self.saturday) == "")
        #expect(calendar.ordinality(day, in: 99, for: Self.saturday) == 0)
        #expect(calendar.range(day, in: month, for: .nan) == "")
    }

    @Test func weeks() throws {
        #expect(try berlin(locale: "en-US").firstWeekday() == 1)
        #expect(try berlin(locale: "en-GB").firstWeekday() == 2)
        #expect(try berlin(locale: "en-US", firstWeekday: 7).firstWeekday() == 7)
        #expect(try berlin(locale: "en-US", firstWeekday: 9).firstWeekday() == 1, "not a weekday, so the locale's")
        #expect(try berlin(locale: "en-US", minimumDays: 4).minimumDaysInFirstWeek() == 4)

        // ISO 8601: weeks start on Monday, and the first has a Thursday.
        let iso = try berlin(identifier: "iso8601")
        #expect(iso.identifier() == "iso8601")
        #expect(iso.firstWeekday() == 2)
        #expect(iso.minimumDaysInFirstWeek() == 4)
        // Friday 1 January 2027 is in the last week of 2026.
        let newYear = CalendarFields(iso.fields(at("2027-01-01T12:00:00Z")))
        #expect(newYear[.weekOfYear] == 53)
        #expect(newYear[.yearForWeekOfYear] == 2026)
        #expect(newYear[.year] == 2027)
    }

    @Test func otherCalendars() throws {
        let buddhist = try berlin(identifier: "buddhist")
        #expect(buddhist.identifier() == "buddhist")
        let fields = CalendarFields(buddhist.fields(Self.saturday))
        #expect(fields[.year] == 2569)
        #expect(fields[.month] == 3)
        #expect(fields[.day] == 28)

        #expect(HostCalendarInfo.make(identifier: "martian", timeZone: "Europe/Berlin", locale: nil, firstWeekday: 0, minimumDays: 0) == nil)
        #expect(HostCalendarInfo.make(identifier: "gregorian", timeZone: "Mars/Olympus", locale: nil, firstWeekday: 0, minimumDays: 0) == nil)
        for name in HostCalendarInfo.identifiers.keys {
            #expect(HostCalendarInfo.make(identifier: name, timeZone: "UTC", locale: "en-US", firstWeekday: 0, minimumDays: 0)?.identifier() == name)
        }
    }

    @Test func nextDate() throws {
        let calendar = try berlin()
        let seven = fields([.hour: 7, .minute: 0])
        let next = CalendarMatchingPolicy.nextTime.rawValue
        #expect(calendar.nextDate(Self.saturday, matching: seven, policy: next, backward: false) == at("2026-03-29T05:00:00Z"))
        #expect(calendar.nextDate(Self.saturday, matching: seven, policy: next, backward: true) == at("2026-03-28T06:00:00Z"))

        // 02:30 doesn't exist the next morning.
        let missing = fields([.hour: 2, .minute: 30])
        #expect(calendar.nextDate(Self.saturday, matching: missing, policy: next, backward: false) == at("2026-03-29T01:00:00Z"))
        #expect(calendar.nextDate(Self.saturday, matching: missing, policy: CalendarMatchingPolicy.nextTimePreservingSmallerComponents.rawValue, backward: false) == at("2026-03-29T01:30:00Z"))
        #expect(calendar.nextDate(Self.saturday, matching: missing, policy: CalendarMatchingPolicy.previousTimePreservingSmallerComponents.rawValue, backward: false) == at("2026-03-29T00:30:00Z"))
        #expect(calendar.nextDate(Self.saturday, matching: missing, policy: CalendarMatchingPolicy.strict.rawValue, backward: false) == at("2026-03-30T00:30:00Z"))

        // The next Monday.
        #expect(calendar.nextDate(Self.saturday, matching: fields([.weekday: 2]), policy: next, backward: false) == at("2026-03-29T22:00:00Z"))

        #expect(calendar.nextDate(Self.saturday, matching: "", policy: next, backward: false).isNaN)
        #expect(calendar.nextDate(Self.saturday, matching: seven, policy: 99, backward: false).isNaN)
        #expect(calendar.nextDate(.nan, matching: seven, policy: next, backward: false).isNaN)
    }

    @Test func weekendsAndSymbols() throws {
        let calendar = try berlin()
        #expect(calendar.isWeekend(Self.saturday))
        #expect(!calendar.isWeekend(at("2026-03-30T12:00:00Z")))
        #expect(!calendar.isWeekend(.nan))

        #expect(calendar.symbols(CalendarSymbols.month.rawValue)[2] == "March")
        #expect(calendar.symbols(CalendarSymbols.shortMonth.rawValue)[2] == "Mar")
        #expect(calendar.symbols(CalendarSymbols.weekday.rawValue).first == "Sunday")
        #expect(calendar.symbols(CalendarSymbols.veryShortStandaloneWeekday.rawValue) == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(calendar.symbols(CalendarSymbols.amPm.rawValue) == ["AM", "PM"])
        #expect(calendar.symbols(CalendarSymbols.era.rawValue) == ["BC", "AD"])
        for kind in 0...14 {
            #expect(!calendar.symbols(Int32(kind)).isEmpty, "\(kind)")
        }

        let german = try berlin(locale: "de-DE")
        #expect(german.symbols(CalendarSymbols.weekday.rawValue)[1] == "Montag")
        #expect(german.symbols(CalendarSymbols.standaloneMonth.rawValue)[2] == "März")

        var messages: [String] = []
        HostFormattingModule.log = { messages.append($0) }
        defer { HostFormattingModule.log = nil }
        #expect(calendar.symbols(99).isEmpty)
        #expect(messages == ["Calendar.symbols: unknown kind 99; none"])
    }

    @Test func aCalendarForTheUserFollowsThem() throws {
        defer { HostSystemClock.reset() }
        HostSystemClock.userTimeZone = { TimeZone(identifier: "Europe/Berlin")! }
        let calendar = try #require(HostCalendarInfo.make(identifier: "gregorian", timeZone: nil, locale: "en-US", firstWeekday: 0, minimumDays: 0))
        #expect(CalendarFields(calendar.fields(Self.saturday))[.hour] == 13)
        HostSystemClock.userTimeZone = { TimeZone(identifier: "Asia/Tokyo")! }
        #expect(CalendarFields(calendar.fields(Self.saturday))[.hour] == 21)

        // All of it the user's: whatever it is, it answers.
        let user = try #require(HostCalendarInfo.make(identifier: nil, timeZone: nil, locale: nil, firstWeekday: 0, minimumDays: 0))
        #expect(HostCalendarInfo.identifiers[user.identifier()] != nil)
        #expect((1...7).contains(user.firstWeekday()))
        #expect(CalendarFields(user.fields(Self.saturday))[.minute] == 30)
    }

    // MARK: Time zones

    @Test func timeZones() throws {
        let berlin = try #require(HostTimeZoneInfo.make(identifier: "Europe/Berlin"))
        let summer = at("2026-07-01T12:00:00Z")
        #expect(berlin.identifier() == "Europe/Berlin")
        #expect(berlin.offset(Self.saturday) == 3600)
        #expect(berlin.offset(summer) == 7200)
        #expect(berlin.daylightSavingOffset(Self.saturday) == 0)
        #expect(berlin.daylightSavingOffset(summer) == 3600)
        #expect(berlin.nextTransition(Self.saturday) == at("2026-03-29T01:00:00Z"))
        #expect(berlin.nextTransition(summer) == at("2026-10-25T01:00:00Z"))
        #expect(berlin.abbreviation(Self.saturday)?.isEmpty == false)
        #expect(berlin.name(TimeZoneNameStyle.generic.rawValue, locale: "en-US") == "Central European Time")
        #expect(berlin.name(TimeZoneNameStyle.standard.rawValue, locale: "en-US") == "Central European Standard Time")
        #expect(berlin.name(TimeZoneNameStyle.daylightSaving.rawValue, locale: "de-DE") == "Mitteleuropäische Sommerzeit")
        #expect(berlin.name(99, locale: "en-US") == nil)

        // A zone that never changes.
        let utc = try #require(HostTimeZoneInfo.make(identifier: "UTC"))
        #expect(utc.offset(summer) == 0)
        #expect(utc.nextTransition(summer).isNaN)
        #expect(try #require(HostTimeZoneInfo.make(identifier: "GMT+0100")).offset(summer) == 3600)
        #expect(try #require(HostTimeZoneInfo.make(identifier: "GMT")).offset(summer) == 0)
        // A moment that isn't a number is 1970.
        #expect(berlin.offset(.nan) == 3600)

        #expect(HostTimeZoneInfo.make(identifier: "Mars/Olympus") == nil)
        #expect(HostTimeZoneInfo.make(identifier: "") == nil)

        let all = HostTimeZoneInfo.identifiers()
        #expect(all.contains("Asia/Tokyo"))
        #expect(all.contains("America/New_York"))
        #expect(all == all.sorted())
        #expect(all.count > 300)
    }

    @Test func theUsersZone() throws {
        defer { HostSystemClock.reset() }
        let user = try #require(HostTimeZoneInfo.make(identifier: nil))
        HostSystemClock.userTimeZone = { TimeZone(identifier: "Europe/Berlin")! }
        #expect(user.identifier() == "Europe/Berlin")
        #expect(HostLocaleInfo.current().timeZoneIdentifier() == "Europe/Berlin")
        HostSystemClock.userTimeZone = { TimeZone(identifier: "Asia/Tokyo")! }
        #expect(user.identifier() == "Asia/Tokyo")
        #expect(user.offset(Self.saturday) == 9 * 3600)
        #expect(HostLocaleInfo.current().timeZoneOffset(Int64(Self.saturday) * 1000) == 9 * 3600)
    }

    // MARK: Sorting

    @Test func comparing() {
        let standard = HostCollator.make(locale: "en-US", options: CollatorOptions.standard.rawValue)
        #expect(standard.compare("Item 2", "Item 10") == -1)
        #expect(standard.compare("item 10", "Item 2") == 1)
        #expect(standard.compare("same", "same") == 0)
        #expect(standard.compare("apple", "Apple") != 0, "forced ordering tells them apart")
        #expect(standard.compare("apple", "Banana") == -1)

        let loose = HostCollator.make(locale: "en-US", options: CollatorOptions([.caseInsensitive, .diacriticInsensitive, .widthInsensitive]).rawValue)
        #expect(loose.compare("apple", "APPLE") == 0)
        #expect(loose.compare("resume", "Résumé") == 0)
        #expect(loose.compare("ＡＢＣ", "abc") == 0)

        let plain = HostCollator.make(locale: "und", options: 0)
        #expect(plain.compare("Item 2", "Item 10") == 1, "digit by digit")
        #expect(plain.compare("a", "b") == -1)
    }

    @Test func ordering() {
        let standard = HostCollator.make(locale: "en-US", options: CollatorOptions.standard.rawValue)
        #expect(standard.order(["b", "A", "a10", "a2"]) == "1,3,2,0")
        #expect(standard.order([]) == "")
        #expect(standard.order(["one"]) == "0")
        #expect(CollatorOptions.order("1,3,2,0") == [1, 3, 2, 0])
        #expect(CollatorOptions.order("") == [])
        #expect(CollatorOptions.text([2, 0, 1]) == "2,0,1")

        // Strings that compare equal keep the order they came in.
        let loose = HostCollator.make(locale: "en-US", options: CollatorOptions.caseInsensitive.rawValue)
        #expect(loose.order(["b", "B", "a", "b", "A"]) == "2,4,0,1,3")

        // Swedish puts ö after z; English and German don't.
        let letters = ["z", "ö", "o"]
        #expect(HostCollator.make(locale: "sv-SE", options: CollatorOptions.standard.rawValue).order(letters) == "2,0,1")
        #expect(HostCollator.make(locale: "en-US", options: CollatorOptions.standard.rawValue).order(letters) == "2,1,0")
        #expect(HostCollator.make(locale: "de-DE", options: CollatorOptions.standard.rawValue).order(letters) == "2,1,0")
    }

    @Test func searching() {
        let search = HostCollator.make(locale: "en-US", options: CollatorOptions([.caseInsensitive, .diacriticInsensitive]).rawValue)
        #expect(search.contains("Résumé.PDF", "pdf"))
        #expect(search.contains("Résumé.PDF", "resume"))
        #expect(!search.contains("Résumé.PDF", "doc"))
        #expect(!search.contains("Résumé.PDF", ""))
        #expect(search.fold(["Résumé", "PDF", ""]) == ["resume", "pdf", ""])

        let exact = HostCollator.make(locale: "en-US", options: 0)
        #expect(!exact.contains("Résumé.PDF", "pdf"))
        #expect(exact.fold(["Résumé"]) == ["Résumé"])

        // How strings are ordered doesn't change a search.
        let standard = HostCollator.make(locale: "en-US", options: CollatorOptions.standard.rawValue)
        #expect(standard.contains("Item 10", "ITEM"))
        #expect(standard.fold(["ＡＢＣ"]) == ["abc"])
    }

    @Test func collatorOptionsItDoesntKnow() {
        var messages: [String] = []
        HostFormattingModule.log = { messages.append($0) }
        defer { HostFormattingModule.log = nil }
        // 1024 is Foundation's regular expression option.
        let collator = HostCollator.make(locale: nil, options: 1024 | CollatorOptions.numeric.rawValue)
        #expect(collator.options == .numeric)
        #expect(collator.language == .user)
        #expect(messages == ["Collator.make: unknown options 1088; using 64"])
        #expect(collator.compare("a2", "a10") == -1)
    }

    // MARK: The clock

    @Test func theTime() {
        defer { HostSystemClock.reset() }
        #expect(abs(HostSystemClock.now() - Date().timeIntervalSince1970) < 5)
        HostSystemClock.clock = { Date(timeIntervalSince1970: Self.saturday) }
        #expect(HostSystemClock.now() == Self.saturday)
    }

    @Test func midnight() {
        defer { HostSystemClock.reset() }
        var now = at("2026-03-28T22:59:00Z")        // 23:59 in Berlin
        var timers: [(seconds: TimeInterval, body: () -> Void)] = []
        HostSystemClock.clock = { Date(timeIntervalSince1970: now) }
        HostSystemClock.userTimeZone = { TimeZone(identifier: "Europe/Berlin")! }
        HostSystemClock.schedule = { timers.append(($0, $1)) }

        let recorder = ClockRecorder()
        HostSystemClock.setDelegate(recorder)
        #expect(timers.count == 1)
        #expect(timers[0].seconds == 61, "a second after midnight")

        // The timer fires: a new day, and a timer for the next. That day
        // has 23 hours.
        now += 61
        timers[0].body()
        #expect(recorder.changes == [.day])
        #expect(timers.count == 2)
        #expect(timers[1].seconds == 23 * 3600)

        // A timer from before is stale, and one that fires early waits again.
        timers[0].body()
        #expect(recorder.changes == [.day])
        timers[1].body()
        #expect(recorder.changes == [.day])
        #expect(timers.count == 3)

        // The platform reporting the same day again isn't a new day.
        HostSystemClock.changed(.day)
        #expect(recorder.changes == [.day])
    }

    @Test func changes() {
        defer { HostSystemClock.reset() }
        var now = Self.saturday
        var zone = "Europe/Berlin"
        var timers = 0
        HostSystemClock.clock = { Date(timeIntervalSince1970: now) }
        HostSystemClock.userTimeZone = { TimeZone(identifier: zone)! }
        HostSystemClock.schedule = { _, _ in timers += 1 }

        // Nobody listening.
        HostSystemClock.changed(.timeZone)
        HostSystemClock.applicationWillEnterForeground()

        let recorder = ClockRecorder()
        HostSystemClock.setDelegate(recorder)
        HostSystemClock.changed(.locale)
        #expect(recorder.changes == [.locale])
        #expect(timers == 1, "a new locale moves no midnight")

        // 13:30 in Berlin is 21:30 in Tokyo, the same day.
        zone = "Asia/Tokyo"
        HostSystemClock.changed(.timeZone)
        #expect(recorder.changes == [.locale, .timeZone])
        #expect(timers == 2)

        // The clock set forward into tomorrow.
        now += 4 * 3600
        HostSystemClock.changed(.clock)
        #expect(recorder.changes == [.locale, .timeZone, [.clock, .day]])

        // What it doesn't know is dropped.
        HostSystemClock.changed(SystemClockChange(rawValue: 64))
        #expect(recorder.changes.count == 3)

        // Away: the zone and the day change, and nothing says so until
        // the app returns.
        zone = "America/Los_Angeles"
        HostSystemClock.applicationWillEnterForeground()
        #expect(recorder.changes.last == [.timeZone, .day])
        HostSystemClock.applicationWillEnterForeground()
        #expect(recorder.changes.count == 4)

        // Nil stops it.
        HostSystemClock.setDelegate(nil)
        HostSystemClock.changed(.locale)
        #expect(recorder.changes.count == 4)
    }

    /// As a guest calls them: through the proxies and the runtime.
    @Test func datesThroughTheContracts() throws {
        defer { HostSystemClock.reset() }
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostFormattingModule.register(in: native)
        HostSystemClock.clock = { Date(timeIntervalSince1970: Self.saturday) }
        HostSystemClock.schedule = { _, _ in }

        #expect(SystemClockInfoProxy.now() == Self.saturday)
        let recorder = ClockRecorder()
        SystemClockInfoProxy.setDelegate(recorder)
        HostSystemClock.changed(.locale)
        #expect(recorder.changes == [.locale])
        SystemClockInfoProxy.setDelegate(nil)

        let calendar = try #require(CalendarInfoProxy.make(identifier: "gregorian", timeZone: "Europe/Berlin", locale: "en-US",
                                                           firstWeekday: 0, minimumDays: 0))
        #expect(calendar.fields(Self.saturday) == "1,2026,3,28,13,30,5,0,7,4,4,13,2026,87,0")
        #expect(calendar.start(CalendarUnit.month.rawValue, of: Self.saturday) == at("2026-02-28T23:00:00Z"))
        #expect(calendar.date("").isNaN)
        #expect(calendar.symbols(CalendarSymbols.amPm.rawValue) == ["AM", "PM"])
        #expect(CalendarInfoProxy.make(identifier: "martian", timeZone: nil, locale: nil, firstWeekday: 0, minimumDays: 0) == nil)

        let zone = try #require(TimeZoneInfoProxy.make(identifier: "Asia/Tokyo"))
        #expect(zone.offset(Self.saturday) == 9 * 3600)
        #expect(zone.nextTransition(Self.saturday).isNaN)
        #expect(TimeZoneInfoProxy.make(identifier: "Mars/Olympus") == nil)
        #expect(TimeZoneInfoProxy.identifiers().contains("Europe/Berlin"))

        let collator = CollatorProxy.make(locale: "en-US", options: CollatorOptions.standard.rawValue)
        #expect(collator.order(["b", "A", "a10", "a2"]) == "1,3,2,0")
        #expect(collator.contains("Item 10", "item"))
        #expect(collator.fold(["Ａ"]) == ["a"])
    }
}
