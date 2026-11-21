import Foundation
import Testing
import DynamicCalendar
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeCalendar

/// A moment in UTC, in milliseconds since 1970.
func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Int64 {
    CivilDate.days(year: year, month: month, day: day) * 86_400_000 + Int64(hour) * 3_600_000 + Int64(minute) * 60_000
}

let hour: Int64 = 3_600_000

let day: Int64 = 86_400_000

/// `HostCalendars` over a store in memory, driven from the guest's
/// `EventStore` through the runtime.
///
/// Serialized: `HostCalendars` and the native runtime are shared.
@Suite(.serialized) final class RuntimeCalendarTests {

    static let calendars = [
        EventCalendar(id: "home", title: "Home", color: 0xFF34_C759),
        EventCalendar(id: "work", title: "Work", account: "ada@example.com", color: 0xFFFF_3B30),
        EventCalendar(id: "holidays", title: "Holidays in Ireland", account: "Subscribed", isWritable: false),
    ]

    let memory = MemoryCalendarStore(calendars: RuntimeCalendarTests.calendars)

    let store = EventStore.default

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostCalendars.reset()
        HostCalendars.store = memory
        HostCalendars.access = .full
        HostCalendars.work = { $0() }
        HostCalendars.deliver = { $0() }
        HostCalendarsModule.register(in: native)
        store.onChange(nil)
    }

    deinit {
        HostCalendars.reset()
    }

    // MARK: Helpers

    func failure<Value>(_ result: Result<Value, EventStoreError>?) -> EventStoreError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    func save(_ event: Event, _ span: EventSpan = .thisEvent) -> Result<Event, EventStoreError>? {
        var result: Result<Event, EventStoreError>?
        store.save(event, span: span) { result = $0 }
        return result
    }

    /// Saves, and gives the event as stored.
    func saved(_ event: Event, _ span: EventSpan = .thisEvent) throws -> Event {
        try #require(save(event, span)).get()
    }

    func remove(_ event: Event, _ span: EventSpan = .thisEvent) -> EventStoreError? {
        var result: Result<Void, EventStoreError>?
        store.remove(event, span: span) { result = $0 }
        return failure(result)
    }

    func events(_ start: Int64, _ end: Int64, in calendars: [EventCalendar] = []) -> Result<[Event], EventStoreError>? {
        var result: Result<[Event], EventStoreError>?
        store.events(from: start, to: end, in: calendars) { result = $0 }
        return result
    }

    /// The starts of what's in a range.
    func starts(_ start: Int64, _ end: Int64) throws -> [Int64] {
        try #require(events(start, end)).get().map(\.start)
    }

    func event(_ identifier: String) -> Result<Event?, EventStoreError>? {
        var result: Result<Event?, EventStoreError>?
        store.event(withID: identifier) { result = $0 }
        return result
    }

    func repeating(_ title: String, _ start: Int64, _ rule: RecurrenceRule, zone: String? = nil) throws -> Event {
        var event = Event(title: title, start: start, end: start + hour)
        event.recurrence = rule
        event.timeZone = zone
        return try saved(event)
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostCalendarsModule.contracts.map(\.name) == [
            "org.pureswift.calendar.Calendars", "org.pureswift.calendar.Calendar", "org.pureswift.calendar.Event",
            "org.pureswift.calendar.Callback", "org.pureswift.calendar.Delegate",
        ])
        let permission = HostCalendarsModule.permissionProviders()[.calendars]
        #expect(permission?.status() == .granted)
        HostCalendars.declaredAccess = .writeOnly
        #expect(permission?.status() == .limited, "write-only is the built-in contract's limited")
        HostCalendars.access = .denied
        #expect(permission?.status() == .denied)
        HostCalendars.store = nil
        #expect(permission?.status() == .unavailable)
        #expect(HostCalendars.shared() === HostCalendars.shared())
    }

    @Test func withoutAStoreThereAreNoCalendars() {
        HostCalendars.store = nil
        #expect(store.access == .unavailable)
        var calendars: Result<[EventCalendar], EventStoreError>?
        store.calendars { calendars = $0 }
        #expect(failure(calendars) == .unavailable && failure(events(0, day)) == .unavailable)
        #expect(failure(save(Event(title: "x", start: 0, end: 1))) == .unavailable)
        var asked: EventStoreAccess?
        store.requestAccess { asked = $0 }
        #expect(asked == .unavailable)
    }

    // MARK: Access

    @Test func theUserIsAskedOnce() {
        HostCalendars.access = .notDetermined
        var questions = 0
        var answer = EventStoreAccess.full
        HostCalendars.requester = { completion in
            questions += 1
            completion(answer)
            completion(.denied)
        }
        #expect(store.access == .notDetermined)
        #expect(failure(events(0, day)) == .notAuthorized, "nothing is read before the user says")
        #expect(failure(save(Event(title: "x", start: 0, end: 1))) == .notAuthorized)

        var granted: [EventStoreAccess] = []
        store.requestAccess { granted.append($0) }
        store.requestAccess { granted.append($0) }
        #expect(granted == [.full, .full] && questions == 1, "the second isn't a question, and a second answer isn't heard")
        #expect(store.access == .full && failure(events(0, day)) == nil)

        HostCalendars.access = .notDetermined
        answer = .denied
        store.requestAccess { granted.append($0) }
        #expect(granted.last == .denied && failure(events(0, day)) == .notAuthorized)
        HostCalendars.access = .restricted
        store.requestAccess { granted.append($0) }
        #expect(granted.last == .restricted && questions == 2, "what's decided isn't asked again")

        // With nothing to ask through, the answer is what it was.
        HostCalendars.access = .notDetermined
        HostCalendars.requester = nil
        store.requestAccess { granted.append($0) }
        #expect(granted.last == .notDetermined)
    }

    @Test func aWriteOnlyAppAddsAndReadsNothing() throws {
        HostCalendars.declaredAccess = .writeOnly
        #expect(store.access == .writeOnly, "whatever the user granted, the manifest asked for less")
        var invitation = Event(title: "Launch party", start: at(2026, 12, 4, 18), end: at(2026, 12, 4, 21))
        invitation.location = "Dublin"
        let added = try saved(invitation)
        #expect(added.id == nil && added.title == "Launch party" && added.location == "Dublin", "it learns nothing the store made up")
        #expect(memory.count == 1)

        var calendars: Result<[EventCalendar], EventStoreError>?
        var fallback: Result<EventCalendar?, EventStoreError>?
        store.calendars { calendars = $0 }
        store.defaultCalendar { fallback = $0 }
        #expect(failure(calendars) == .notAuthorized && failure(fallback) == .notAuthorized)
        #expect(failure(events(at(2026, 12, 1), at(2027, 1, 1))) == .notAuthorized && failure(event("event-1")) == .notAuthorized)

        // Nor can it change or remove what's there, even by guessing.
        var guessed = invitation
        guessed.id = "event-1"
        #expect(failure(save(guessed)) == .notAuthorized && remove(guessed) == .notAuthorized)
        HostCalendars.access = .writeOnly
        HostCalendars.declaredAccess = .full
        #expect(store.access == .writeOnly && failure(events(0, day)) == .notAuthorized, "the user granted only that")
    }

    // MARK: Calendars

    @Test func calendarsAreListedAsTheSystemHasThem() throws {
        var calendars: Result<[EventCalendar], EventStoreError>?
        var fallback: Result<EventCalendar?, EventStoreError>?
        store.calendars { calendars = $0 }
        store.defaultCalendar { fallback = $0 }
        #expect(try calendars?.get() == Self.calendars, "in its order, with their colours")
        #expect(try fallback?.get()?.id == "home", "the first that can be written")

        HostCalendars.store = MemoryCalendarStore(calendars: Self.calendars, defaultCalendar: "holidays")
        store.defaultCalendar { fallback = $0 }
        if case .success(let none)? = fallback { #expect(none == nil, "a default that can't be written is none") } else { Issue.record("no default was a failure") }
        #expect(failure(save(Event(title: "x", start: 0, end: 1))) == .readOnly, "and a new event has nowhere to go")
    }

    // MARK: Events

    @Test func anEventIsSavedAndFound() throws {
        var lunch = Event(title: "Lunch with Ada", start: at(2026, 11, 3, 12), end: at(2026, 11, 3, 13))
        lunch.location = "Canteen"
        lunch.notes = "Bring the plan"
        lunch.url = "https://example.com/plan"
        lunch.timeZone = "Europe/Dublin"
        lunch.alarms = [.before(minutes: 15), .before(minutes: 60)]
        lunch.availability = .busy
        let stored = try saved(lunch)
        #expect(stored.id == "event-1" && stored.calendar == "home", "the default calendar")
        var expected = lunch
        expected.id = "event-1"
        expected.calendar = "home"
        #expect(stored == expected && stored.occurrence == nil && !stored.isDetached)
        #expect(try event("event-1")?.get() == expected)
        if case .success(let none)? = event("event-9") { #expect(none == nil, "gone isn't an error") } else { Issue.record("no event was a failure") }

        // Changing it keeps its identity.
        var moved = stored
        moved.start += hour
        moved.end += hour
        moved.calendar = "work"
        moved.title = "Late lunch"
        #expect(try saved(moved) == moved && memory.count == 1)
        #expect(try events(at(2026, 11, 3), at(2026, 11, 4))?.get() == [moved])
        #expect(try events(at(2026, 11, 3), at(2026, 11, 4), in: [Self.calendars[0]])?.get() == [], "it's in Work now")
        #expect(try events(at(2026, 11, 3), at(2026, 11, 4), in: [Self.calendars[1], Self.calendars[2]])?.get().count == 1)

        #expect(remove(moved) == nil && memory.count == 0)
        #expect(remove(moved) == .notFound && failure(save(moved)) == .notFound)
        #expect(remove(Event(title: "never saved", start: 0, end: 1)) == .notFound)
    }

    @Test func aRangeGivesWhatOverlapsItInOrder() throws {
        let breakfast = try saved(Event(title: "Breakfast", start: at(2026, 11, 3, 8), end: at(2026, 11, 3, 9)))
        let apple = try saved(Event(title: "Apple", start: at(2026, 11, 3, 12), end: at(2026, 11, 3, 13)))
        let zebra = try saved(Event(title: "Zebra", start: at(2026, 11, 3, 12), end: at(2026, 11, 3, 13)))
        let night = try saved(Event(title: "Night shift", start: at(2026, 11, 3, 22), end: at(2026, 11, 4, 6)))
        let moment = try saved(Event(title: "Deadline", start: at(2026, 11, 4, 9), end: at(2026, 11, 4, 9)))

        #expect(try events(at(2026, 11, 3), at(2026, 11, 4))?.get() == [breakfast, apple, zebra, night], "by start, then title")
        #expect(try events(at(2026, 11, 4), at(2026, 11, 5))?.get() == [night, moment], "one that began the day before, and a moment")
        #expect(try events(at(2026, 11, 3, 9), at(2026, 11, 3, 12))?.get() == [], "touching isn't overlapping")
        #expect(try events(at(2026, 11, 4, 9), at(2026, 11, 4, 9))?.get() == [], "an empty range holds nothing")

        #expect(failure(events(at(2026, 11, 4), at(2026, 11, 3))) == .invalidRange)
        #expect(failure(events(at(2026, 1, 1), at(2030, 1, 6))) == .invalidRange, "more than four years")
        #expect(failure(events(at(2026, 1, 1), at(2030, 1, 1))) == nil)
    }

    @Test func whatCanNotBeSavedIsRefused() throws {
        #expect(failure(save(Event(title: "Backwards", start: at(2026, 11, 3, 13), end: at(2026, 11, 3, 12)))) == .invalidDates)
        var nowhere = Event(title: "Nowhere", start: 0, end: 1)
        nowhere.calendar = "deleted"
        #expect(failure(save(nowhere)) == .notFound)
        var holiday = Event(title: "My own holiday", start: 0, end: day, isAllDay: true)
        holiday.calendar = "holidays"
        #expect(failure(save(holiday)) == .readOnly)
        #expect(memory.count == 0)

        // Nor moved into a calendar that can't be written.
        var mine = try saved(Event(title: "Mine", start: 0, end: 1))
        mine.calendar = "holidays"
        #expect(failure(save(mine)) == .readOnly)
        #expect(try event("event-1")?.get()?.calendar == "home")
    }

    @Test func anAllDayEventIsWholeDaysInUTC() throws {
        // Given loosely: from some time on the 5th to some time on the 6th.
        let loose = Event(title: "Conference", start: at(2026, 11, 5, 9, 30), end: at(2026, 11, 6, 17), isAllDay: true)
        let stored = try saved(loose)
        #expect(stored.start == at(2026, 11, 5) && stored.end == at(2026, 11, 7), "to the midnight after its last day")
        let single = try saved(Event(title: "Birthday", start: at(2026, 11, 9), end: at(2026, 11, 9), isAllDay: true))
        #expect(single.start == at(2026, 11, 9) && single.end == at(2026, 11, 10), "one day at least")
        let exact = try saved(Event(title: "Exact", start: at(2026, 11, 12), end: at(2026, 11, 13), isAllDay: true))
        #expect(exact.start == at(2026, 11, 12) && exact.end == at(2026, 11, 13), "already whole days")
        #expect(try starts(at(2026, 11, 6), at(2026, 11, 7)) == [at(2026, 11, 5)])
        #expect(try starts(at(2026, 11, 7), at(2026, 11, 9)) == [])
    }

    // MARK: Repeats

    @Test func theStoreExpandsRepeats() throws {
        // November 2026 begins on a Sunday.
        let weekly = try repeating("Standup", at(2026, 11, 3, 9), RecurrenceRule(.weekly, daysOfWeek: [.tuesday], end: .count(10)))
        #expect(weekly.id == "event-1" && weekly.occurrence == at(2026, 11, 3, 9), "its own first occurrence")
        let november = try #require(events(at(2026, 11, 1), at(2026, 12, 1))).get()
        #expect(november.map(\.start) == [3, 10, 17, 24].map { at(2026, 11, $0, 9) })
        #expect(november.allSatisfy { $0.id == "event-1" && $0.duration == hour && !$0.isDetached && $0.recurrence == weekly.recurrence })
        #expect(november.map(\.occurrence) == november.map(\.start), "each says which occurrence it is")
        #expect(try starts(at(2027, 1, 1), at(2027, 3, 1)) == [at(2027, 1, 5, 9)], "the tenth is the last")
        #expect(try starts(at(2026, 10, 1), at(2026, 11, 3, 9)) == [], "none before it began")
    }

    @Test func rulesGiveTheDaysTheyName() throws {
        func days(_ rule: RecurrenceRule, from start: Int64, _ range: (Int64, Int64)) throws -> [Int64] {
            let event = try repeating("Rule", start, rule)
            defer { _ = remove(event, .futureEvents) }
            return try starts(range.0, range.1)
        }
        let nine = at(2026, 11, 2, 9)
        #expect(try days(RecurrenceRule(.daily), from: nine, (at(2026, 11, 1), at(2026, 11, 6))) == [2, 3, 4, 5].map { at(2026, 11, $0, 9) })
        #expect(try days(RecurrenceRule(.daily, interval: 3), from: nine, (at(2026, 11, 1), at(2026, 11, 12))) == [2, 5, 8, 11].map { at(2026, 11, $0, 9) })
        #expect(try days(RecurrenceRule(.weekly), from: nine, (at(2026, 11, 1), at(2026, 11, 20))) == [2, 9, 16].map { at(2026, 11, $0, 9) }, "the day it began on")
        #expect(try days(RecurrenceRule(.weekly, interval: 2, daysOfWeek: [.monday, .wednesday]), from: nine, (at(2026, 11, 1), at(2026, 12, 1)))
            == [2, 4, 16, 18, 30].map { at(2026, 11, $0, 9) }, "every second week")

        #expect(try days(RecurrenceRule(.monthly), from: at(2026, 10, 31, 9), (at(2026, 10, 1), at(2027, 2, 1)))
            == [at(2026, 10, 31, 9), at(2026, 12, 31, 9), at(2027, 1, 31, 9)], "a month without the day has none")
        #expect(try days(RecurrenceRule(.monthly, daysOfMonth: [1, 15, -1]), from: at(2026, 11, 1, 9), (at(2026, 11, 1), at(2026, 12, 2)))
            == [at(2026, 11, 1, 9), at(2026, 11, 15, 9), at(2026, 11, 30, 9), at(2026, 12, 1, 9)], "-1 is the month's last day")
        #expect(try days(RecurrenceRule(.monthly, daysOfWeek: [.friday], setPositions: [-1]), from: at(2026, 11, 27, 9), (at(2026, 11, 1), at(2027, 2, 1)))
            == [at(2026, 11, 27, 9), at(2026, 12, 25, 9), at(2027, 1, 29, 9)], "the last Friday")
        #expect(try days(RecurrenceRule(.monthly, daysOfWeek: [.nth(2, .tuesday)]), from: at(2026, 11, 10, 9), (at(2026, 11, 1), at(2027, 2, 1)))
            == [at(2026, 11, 10, 9), at(2026, 12, 8, 9), at(2027, 1, 12, 9)], "the second Tuesday")
        // A range is four years at most, so the leap days are looked for
        // in three of them.
        let leap = try repeating("Leap day", at(2024, 2, 29, 9), RecurrenceRule(.yearly, end: .count(3)))
        #expect(try starts(at(2024, 1, 1), at(2028, 1, 1)) == [at(2024, 2, 29, 9)], "a leap day comes every four years")
        #expect(try starts(at(2028, 1, 1), at(2032, 1, 1)) == [at(2028, 2, 29, 9)])
        #expect(try starts(at(2032, 1, 1), at(2036, 1, 1)) == [at(2032, 2, 29, 9)])
        #expect(try starts(at(2036, 1, 1), at(2040, 1, 1)) == [], "three, and no more")
        #expect(remove(leap, .futureEvents) == nil)
        #expect(try days(RecurrenceRule(.yearly, monthsOfYear: [3, 11]), from: at(2026, 3, 5, 9), (at(2026, 1, 1), at(2027, 6, 1)))
            == [at(2026, 3, 5, 9), at(2026, 11, 5, 9), at(2027, 3, 5, 9)])

        let until = RecurrenceRule(.daily, end: .until(at(2026, 11, 4, 9)))
        #expect(try days(until, from: nine, (at(2026, 11, 1), at(2026, 12, 1))) == [2, 3, 4].map { at(2026, 11, $0, 9) }, "the end is the last it may start at")
        #expect(memory.count == 0)
    }

    @Test func nineOClockStaysNineAsTheClocksChange() throws {
        // Berlin leaves summer time on 25 October 2026.
        _ = try repeating("Run", at(2026, 10, 24, 7), RecurrenceRule(.daily), zone: "Europe/Berlin")
        #expect(try starts(at(2026, 10, 24), at(2026, 10, 27)) == [at(2026, 10, 24, 7), at(2026, 10, 25, 8), at(2026, 10, 26, 8)])

        // An all-day event has no zone to change in.
        var holiday = Event(title: "Day off", start: at(2026, 10, 24), end: at(2026, 10, 25), isAllDay: true)
        holiday.recurrence = RecurrenceRule(.daily, end: .count(3))
        holiday.timeZone = "Europe/Berlin"
        _ = try saved(holiday)
        let daysOff = try #require(events(at(2026, 10, 20), at(2026, 11, 1), in: [])).get().filter { $0.isAllDay }
        #expect(daysOff.map(\.start) == [24, 25, 26].map { at(2026, 10, $0) } && daysOff.allSatisfy { $0.duration == day })
    }

    @Test func oneOccurrenceCanBeChangedOrRemoved() throws {
        let series = try repeating("Standup", at(2026, 11, 3, 9), RecurrenceRule(.weekly, daysOfWeek: [.tuesday]))
        var third = try #require(events(at(2026, 11, 17), at(2026, 11, 18))).get()[0]
        third.start += 2 * hour
        third.end += 2 * hour
        third.title = "Standup, late"
        let detached = try saved(third, .thisEvent)
        #expect(detached.isDetached && detached.occurrence == at(2026, 11, 17, 9) && detached.id == series.id)
        #expect(detached.start == at(2026, 11, 17, 11) && detached.title == "Standup, late")

        var november = try #require(events(at(2026, 11, 1), at(2026, 12, 1))).get()
        #expect(november.map(\.start) == [at(2026, 11, 3, 9), at(2026, 11, 10, 9), at(2026, 11, 17, 11), at(2026, 11, 24, 9)])
        #expect(november.map(\.title) == ["Standup", "Standup", "Standup, late", "Standup"] && november.map(\.isDetached) == [false, false, true, false])

        // Changed again, it's still that occurrence.
        var again = november[2]
        again.title = "Standup, later"
        #expect(try saved(again, .thisEvent).occurrence == at(2026, 11, 17, 9))
        #expect(try events(at(2026, 11, 17), at(2026, 11, 18))?.get().map(\.title) == ["Standup, later"])

        // A changed rule isn't for one occurrence.
        var odd = november[1]
        odd.recurrence = RecurrenceRule(.daily)
        #expect(failure(save(odd, .thisEvent)) == .invalidSpan)

        #expect(remove(november[1], .thisEvent) == nil)
        #expect(remove(november[2], .thisEvent) == nil, "the changed one too")
        november = try #require(events(at(2026, 11, 1), at(2026, 12, 1))).get()
        #expect(november.map(\.start) == [at(2026, 11, 3, 9), at(2026, 11, 24, 9)] && memory.count == 1)
    }

    @Test func thisAndWhatFollowsBecomesANewEvent() throws {
        let series = try repeating("Class", at(2026, 11, 2, 18), RecurrenceRule(.weekly, daysOfWeek: [.monday]))
        var third = try #require(events(at(2026, 11, 16), at(2026, 11, 17))).get()[0]
        third.start = at(2026, 11, 18, 19)
        third.end = at(2026, 11, 18, 20)
        third.title = "Class, Wednesdays"
        third.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.wednesday])
        let moved = try saved(third, .futureEvents)
        #expect(moved.id == "event-2" && moved.occurrence == at(2026, 11, 18, 19) && !moved.isDetached && memory.count == 2)

        let all = try #require(events(at(2026, 11, 1), at(2026, 12, 3))).get()
        #expect(all.map(\.start) == [at(2026, 11, 2, 18), at(2026, 11, 9, 18), at(2026, 11, 18, 19), at(2026, 11, 25, 19), at(2026, 12, 2, 19)])
        #expect(all.map(\.id) == [series.id, series.id, "event-2", "event-2", "event-2"], "the old rule ends before it")
        #expect(try event("event-1")?.get()?.recurrence?.end == .until(at(2026, 11, 16, 18) - 1000), "a second before")

        // From its first occurrence on is the whole event.
        var first = all[0]
        first.title = "Class, Mondays"
        let whole = try saved(first, .futureEvents)
        #expect(whole.id == series.id && memory.count == 2)
        #expect(try events(at(2026, 11, 1), at(2026, 11, 15))?.get().map(\.title) == ["Class, Mondays", "Class, Mondays"])

        // Removing from an occurrence on ends the rule there; from the
        // first, removes the event.
        #expect(remove(all[3], .futureEvents) == nil)
        #expect(try starts(at(2026, 11, 17), at(2027, 1, 1)) == [at(2026, 11, 18, 19)] && memory.count == 2)
        #expect(remove(all[2], .futureEvents) == nil && memory.count == 1)
        #expect(remove(whole, .futureEvents) == nil && memory.count == 0)
    }

    @Test func aRuleTheStoreCanNotHoldIsRefused() throws {
        var hourly = Event(title: "Pills", start: at(2026, 11, 2, 8), end: at(2026, 11, 2, 8))
        hourly.recurrence = RecurrenceRule(rrule: "FREQ=HOURLY;INTERVAL=4")
        #expect(failure(save(hourly)) == .unsupportedRecurrence)
        hourly.recurrence = RecurrenceRule(rrule: "FREQ=DAILY;BYHOUR=8,20")
        #expect(failure(save(hourly)) == .unsupportedRecurrence, "a part it can't expand")
        hourly.recurrence = RecurrenceRule(rrule: "FREQ=YEARLY;BYDAY=20MO")
        #expect(failure(save(hourly)) == .unsupportedRecurrence)
        #expect(memory.count == 0, "nothing was saved")

        hourly.recurrence = RecurrenceRule(rrule: "FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=SU,MO")
        _ = try saved(hourly)
        // Weeks that begin on Sunday: Monday the 2nd, then Sunday the 15th
        // and Monday the 16th.
        #expect(try starts(at(2026, 11, 1), at(2026, 11, 20)) == [at(2026, 11, 2, 8), at(2026, 11, 15, 8), at(2026, 11, 16, 8)])

        // A rule that isn't one, from a guest that didn't use the type.
        let record = HostCalendars.shared().makeEvent()
        record.setText("Odd", location: "", notes: "", url: "")
        record.setRecurrence("EVERY=NOW AND THEN")
        var result: Result<Event, EventStoreError>?
        record.save(0, callback: Answer { result = $0 })
        #expect(failure(result) == .unsupportedRecurrence)
    }

    // MARK: Changes

    @Test func aBurstOfChangesIsSaidOnce() throws {
        var jobs: [@Sendable () -> Void] = []
        nonisolated(unsafe) var heldJobs: [@Sendable () -> Void] = []
        var changes = 0
        store.onChange { changes += 1 }
        _ = try saved(Event(title: "One", start: 0, end: 1))
        #expect(changes == 1, "this app's own save")

        HostCalendars.deliver = { heldJobs.append($0) }
        HostCalendars.storeChanged()
        HostCalendars.storeChanged()
        HostCalendars.storeChanged()
        jobs = heldJobs
        heldJobs = []
        #expect(jobs.count == 1 && changes == 1, "a sync touches many events")
        jobs.forEach { $0() }
        #expect(changes == 2)
        HostCalendars.deliver = { $0() }
        HostCalendars.storeChanged()
        #expect(changes == 3)

        store.onChange(nil)
        HostCalendars.storeChanged()
        #expect(changes == 3, "nobody listens")
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded.

    @MainActor @Test func callsCanBeAwaited() async throws {
        HostCalendars.work = { job in DispatchQueue.global().async(execute: job) }
        HostCalendars.deliver = { DispatchQueue.main.async(execute: $0) }
        #expect(await store.requestAccess() == .full)
        #expect(try await store.calendars().map(\.id) == ["home", "work", "holidays"])
        #expect(try await store.defaultCalendar()?.id == "home")

        var meeting = Event(title: "Planning", start: at(2026, 11, 5, 14), end: at(2026, 11, 5, 15))
        meeting.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.thursday], end: .count(3))
        meeting = try await store.save(meeting)
        let found = try await store.events(from: at(2026, 11, 1), to: at(2026, 12, 1))
        #expect(found.map(\.start) == [5, 12, 19].map { at(2026, 11, $0, 14) })
        #expect(try await store.event(withID: try #require(meeting.id))?.title == "Planning")

        // The stream hears of this app's own change.
        let changes = store.changes
        let listening = Task { @MainActor in
            for await _ in changes { return true }
            return false
        }
        await Task.yield()
        try await store.remove(found[1], span: .thisEvent)
        #expect(await listening.value)
        #expect(try await store.events(from: at(2026, 11, 1), to: at(2026, 12, 1)).count == 2)

        do {
            _ = try await store.events(from: 10, to: 0)
            Issue.record("a backwards range gave events")
        } catch {
            #expect(error == .invalidRange)
        }
    }
}

/// A callback that takes a saved event, or a failure.
final class Answer: CalendarCallback {

    let finish: (Result<Event, EventStoreError>) -> Void

    init(_ finish: @escaping (Result<Event, EventStoreError>) -> Void) {
        self.finish = finish
    }

    func didComplete() { }
    func didChangeAccess(_ access: Int32) { }
    func didListCalendars(_ calendars: [any CalendarRecord]) { }
    func didFindCalendar(_ calendar: (any CalendarRecord)?) { }
    func didListEvents(_ events: [any CalendarEventRecord]) { }
    func didFindEvent(_ event: (any CalendarEventRecord)?) {
        if let event { finish(.success(Event(event))) }
    }
    func didFail(_ error: Int32) {
        finish(.failure(EventStoreError(rawValue: error) ?? .unknown))
    }
}
