import Testing
import DynamicCalendar
import DynamicRuntime
import RuntimeCore
import RuntimeNative

/// A host's event record that only holds what it's given.
final class ScriptedEventRecord: CalendarEventRecord {

    nonisolated(unsafe) static var saved: [(record: ScriptedEventRecord, span: Int32, callback: any CalendarCallback)] = []

    nonisolated(unsafe) static var removed: [(record: ScriptedEventRecord, span: Int32, callback: any CalendarCallback)] = []

    var id = ""
    var calendarID = ""
    var text = ["", "", "", ""]
    var startTime: Int64 = 0
    var endTime: Int64 = 0
    var allDay = false
    var zone = ""
    var rule = ""
    var occurrenceStart: Int64 = -1
    var detached = false
    var alarmText = ""
    var availabilityValue: Int32 = -1

    func identifier() -> String { id }
    func calendar() -> String { calendarID }
    func title() -> String { text[0] }
    func location() -> String { text[1] }
    func notes() -> String { text[2] }
    func url() -> String { text[3] }
    func start() -> Int64 { startTime }
    func end() -> Int64 { endTime }
    func isAllDay() -> Bool { allDay }
    func timeZone() -> String { zone }
    func recurrence() -> String { rule }
    func occurrence() -> Int64 { occurrenceStart }
    func isDetached() -> Bool { detached }
    func alarms() -> String { alarmText }
    func availability() -> Int32 { availabilityValue }

    func setIdentity(_ identifier: String, occurrence: Int64) {
        id = identifier
        occurrenceStart = occurrence
    }
    func setCalendar(_ identifier: String) { calendarID = identifier }
    func setText(_ title: String, location: String, notes: String, url: String) { text = [title, location, notes, url] }
    func setDates(_ start: Int64, end: Int64, allDay: Bool, timeZone: String) {
        startTime = start
        endTime = end
        self.allDay = allDay
        zone = timeZone
    }
    func setRecurrence(_ rule: String) { self.rule = rule }
    func setAlarms(_ minutes: String) { alarmText = minutes }
    func setAvailability(_ availability: Int32) { availabilityValue = availability }

    func save(_ span: Int32, callback: any CalendarCallback) {
        Self.saved.append((self, span, callback))
    }

    func remove(_ span: Int32, callback: any CalendarCallback) {
        Self.removed.append((self, span, callback))
    }
}

final class ScriptedCalendarRecord: CalendarRecord {
    func identifier() -> String { "work" }
    func title() -> String { "Work" }
    func account() -> String { "ada@example.com" }
    func color() -> Int32 { Int32(bitPattern: 0xFFFF_3B30) }
    func isWritable() -> Bool { false }
}

/// A host's calendars that only write down what they're asked, and keep
/// the callbacks for the test to answer.
final class ScriptedCalendars: Calendars {

    /// The one store, as a host has: the guest keeps what it's given.
    nonisolated(unsafe) static let instance = ScriptedCalendars()

    var calls: [String] = []

    var callbacks: [any CalendarCallback] = []

    var delegate: (any CalendarsDelegate)?

    var level: Int32 = 0

    static func shared() -> ScriptedCalendars { instance }

    func access() -> Int32 { level }

    func requestAccess(_ callback: any CalendarCallback) {
        calls.append("requestAccess")
        callbacks.append(callback)
    }

    func setDelegate(_ delegate: (any CalendarsDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }

    func calendars(_ callback: any CalendarCallback) {
        calls.append("calendars")
        callbacks.append(callback)
    }

    func defaultCalendar(_ callback: any CalendarCallback) {
        calls.append("defaultCalendar")
        callbacks.append(callback)
    }

    func events(_ start: Int64, end: Int64, calendars: [String], callback: any CalendarCallback) {
        calls.append("events \(start) \(end) \(calendars)")
        callbacks.append(callback)
    }

    func event(_ identifier: String, callback: any CalendarCallback) {
        calls.append("event \(identifier)")
        callbacks.append(callback)
    }

    func makeEvent() -> any CalendarEventRecord {
        ScriptedEventRecord()
    }
}

/// Serialized: the tests share the native runtime and the scripted host's
/// one store.
@Suite(.serialized) final class DynamicCalendarTests {

    let host = ScriptedCalendars.instance

    let store = EventStore.default

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        CalendarsProxy.register(ScriptedCalendars.self, in: native)
        CalendarRecordProxy.register(ScriptedCalendarRecord.self, in: native)
        CalendarEventRecordProxy.register(ScriptedEventRecord.self, in: native)
        CalendarCallbackProxy.registerInterface(in: native)
        CalendarsDelegateProxy.registerInterface(in: native)
        host.calls = []
        host.callbacks = []
        host.level = 0
        store.onChange(nil)
        host.calls = []
        ScriptedEventRecord.saved = []
        ScriptedEventRecord.removed = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func error<Value>(_ result: Result<Value, EventStoreError>?) -> EventStoreError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    // MARK: Contracts

    @Test func theStoreRequiresCalendars() {
        let calendars = CalendarsProxy.descriptor
        #expect(calendars.name == "org.pureswift.calendar.Calendars")
        #expect(calendars.capability == .calendars)
        #expect(method(calendars, "access")?.signature == Signature("()I"))
        #expect(method(calendars, "events:end:calendars:callback:")?.signature == Signature("(JJOO)V"))
        #expect(method(calendars, "makeEvent")?.signature == Signature("()O"))
        #expect(calendars.methods.count == 9)

        let calendar = CalendarRecordProxy.descriptor
        #expect(calendar.name == "org.pureswift.calendar.Calendar" && calendar.capability == nil)
        #expect(calendar.methods.count == 5)

        let event = CalendarEventRecordProxy.descriptor
        #expect(event.name == "org.pureswift.calendar.Event" && event.capability == nil)
        #expect(method(event, "start")?.signature == Signature("()J"))
        #expect(method(event, "setIdentity:occurrence:")?.signature == Signature("(OJ)V"))
        #expect(method(event, "setDates:end:allDay:timeZone:")?.signature == Signature("(JJZO)V"))
        #expect(method(event, "save:callback:")?.signature == Signature("(IO)V"))
        #expect(event.methods.count == 24)

        let callback = CalendarCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.calendar.Callback" && callback.kind == .callback)
        #expect(callback.methods.count == 7)
        let delegate = CalendarsDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.calendar.Delegate" && delegate.kind == .callback)
        #expect(delegate.methods.count == 1)

        let descriptors = [calendars, calendar, event, callback, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Rules

    @Test func aRuleIsWrittenAsAnRRULE() {
        #expect(RecurrenceRule(.daily).rrule == "FREQ=DAILY")
        #expect(RecurrenceRule(.weekly, interval: 2, daysOfWeek: [.monday, .wednesday]).rrule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE")
        #expect(RecurrenceRule(.monthly, daysOfMonth: [1, 15, -1]).rrule == "FREQ=MONTHLY;BYMONTHDAY=1,15,-1")
        #expect(RecurrenceRule(.monthly, daysOfWeek: [.friday], setPositions: [-1]).rrule == "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1")
        #expect(RecurrenceRule(.monthly, daysOfWeek: [.nth(2, .tuesday), .nth(-1, .sunday)]).rrule == "FREQ=MONTHLY;BYDAY=2TU,-1SU")
        #expect(RecurrenceRule(.yearly, monthsOfYear: [3, 11], end: .count(5)).rrule == "FREQ=YEARLY;BYMONTH=3,11;COUNT=5")
        // 31 December 2026, 23:59:59 UTC.
        let until: Int64 = (CivilDate.days(year: 2026, month: 12, day: 31) * 86_400 + 86_399) * 1000
        #expect(RecurrenceRule(.daily, end: .until(until)).rrule == "FREQ=DAILY;UNTIL=20261231T235959Z")
        #expect(RecurrenceRule(.daily, end: .until(-1)).rrule == "FREQ=DAILY;UNTIL=19691231T235959Z", "before 1970 too")
        #expect(RecurrenceRule(.daily, interval: 0).interval == 1, "never less than every one")
    }

    @Test func anRRULEIsReadBack() throws {
        let weekly = try #require(RecurrenceRule(rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10"))
        #expect(weekly == RecurrenceRule(.weekly, interval: 2, daysOfWeek: [.monday, .wednesday], end: .count(10)))
        let monthly = try #require(RecurrenceRule(rrule: "RRULE:freq=monthly;byday=2tu,-1fr;bysetpos=1,-1;bymonth=1,6"))
        #expect(monthly.frequency == .monthly && monthly.daysOfWeek == [.nth(2, .tuesday), .nth(-1, .friday)])
        #expect(monthly.setPositions == [1, -1] && monthly.monthsOfYear == [1, 6], "without case, with its prefix")

        let dated = try #require(RecurrenceRule(rrule: "FREQ=DAILY;UNTIL=20261231"))
        #expect(dated.end == .until((CivilDate.days(year: 2026, month: 12, day: 31) * 86_400 + 86_399) * 1000), "a date is the whole of that day")
        let timed = try #require(RecurrenceRule(rrule: "FREQ=DAILY;UNTIL=20260102T030405Z"))
        #expect(timed.end == .until((CivilDate.days(year: 2026, month: 1, day: 2) * 86_400 + 3 * 3600 + 4 * 60 + 5) * 1000))
        #expect(timed.rrule == "FREQ=DAILY;UNTIL=20260102T030405Z")

        // What it has no property for is kept, and written back.
        let kept = try #require(RecurrenceRule(rrule: "FREQ=WEEKLY;WKST=SU;BYDAY=TU;BYHOUR=9,17"))
        #expect(kept.otherParts == ["WKST=SU", "BYHOUR=9,17"] && kept.daysOfWeek == [.tuesday])
        #expect(kept.rrule == "FREQ=WEEKLY;BYDAY=TU;WKST=SU;BYHOUR=9,17")
        #expect(RecurrenceRule(rrule: kept.rrule) == kept)
        #expect(RecurrenceRule(rrule: "FREQ=HOURLY;INTERVAL=4")?.frequency == .hourly, "a frequency calendars rarely have")

        for bad in ["", "BYDAY=MO", "FREQ=FORTNIGHTLY", "FREQ=DAILY;INTERVAL=0", "FREQ=DAILY;COUNT=x", "FREQ=WEEKLY;BYDAY=XX",
                    "FREQ=MONTHLY;BYMONTHDAY=32", "FREQ=YEARLY;BYMONTH=13", "FREQ=DAILY;UNTIL=2026", "FREQ=DAILY;UNTIL=20261301",
                    "FREQ=DAILY;NONSENSE", "not a rule"] {
            #expect(RecurrenceRule(rrule: bad) == nil, "\(bad)")
        }
    }

    @Test func daysAreCountedWithoutFoundation() {
        #expect(CivilDate(days: 0) == CivilDate(year: 1970, month: 1, day: 1))
        #expect(CivilDate(days: -1) == CivilDate(year: 1969, month: 12, day: 31))
        #expect(CivilDate(year: 2024, month: 2, day: 29).days + 1 == CivilDate(year: 2024, month: 3, day: 1).days, "a leap day")
        #expect(CivilDate(year: 2100, month: 2, day: 28).days + 1 == CivilDate(year: 2100, month: 3, day: 1).days, "and a century that has none")
        #expect(CivilDate(year: 2000, month: 2, day: 29).days + 1 == CivilDate(year: 2000, month: 3, day: 1).days)
        let day = CivilDate(year: 2026, month: 11, day: 20)
        #expect(CivilDate(days: day.days) == day && day.weekday == .friday)
        #expect(CivilDate(year: 1970, month: 1, day: 1).weekday == .thursday && CivilDate(year: 1969, month: 12, day: 28).weekday == .sunday)
        #expect(CivilDate(millisecondsSince1970: day.millisecondsSince1970 + 86_399_999) == day)
        #expect(CivilDate(millisecondsSince1970: -1) == CivilDate(year: 1969, month: 12, day: 31))
        for offset: Int64 in stride(from: -800_000, through: 800_000, by: 997) {
            #expect(CivilDate(days: offset).days == offset)
        }
    }

    @Test func eventsAreValues() {
        var event = Event(title: "Lunch", start: 1000, end: 4000)
        #expect(event.id == nil && event.duration == 3000 && event.availability == .notSupported)
        #expect(event.overlaps(0, 1001) && event.overlaps(3999, 9000) && event.overlaps(2000, 2001))
        #expect(!event.overlaps(4000, 9000) && !event.overlaps(0, 1000), "touching isn't overlapping")
        event.end = 1000
        #expect(event.overlaps(1000, 2000) && !event.overlaps(0, 1000), "a moment is in the range it starts in")

        #expect(EventAlarm.text([.before(minutes: 15), .atStart, .before(minutes: 1440)]) == "15,0,1440")
        #expect(EventAlarm.alarms("15,0,1440") == [.before(minutes: 15), .atStart, .before(minutes: 1440)])
        #expect(EventAlarm.alarms("") == [] && EventAlarm.alarms("10,x,-5,20") == [.before(minutes: 10), .before(minutes: 20)])
        #expect(EventAlarm(minutesBefore: -3).minutesBefore == 0)
        #expect(EventStore.maximumRange == 4 * 366 * 86_400_000)
    }

    // MARK: The store

    @Test func accessIsWhatTheHostSays() {
        #expect(store.access == .notDetermined)
        host.level = 4
        #expect(store.access == .writeOnly)
        host.level = 3
        #expect(store.access == .full)
        host.level = 77
        #expect(store.access == .denied, "a level from a newer host isn't one to rely on")

        var answers: [EventStoreAccess] = []
        store.requestAccess { answers.append($0) }
        store.requestAccess { answers.append($0) }
        store.requestAccess { answers.append($0) }
        host.callbacks[0].didChangeAccess(3)
        host.callbacks[0].didChangeAccess(2)
        host.callbacks[1].didChangeAccess(99)
        host.callbacks[2].didFail(0)
        #expect(answers == [.full, .denied, .denied], "only a first answer counts, and anything odd is no")
    }

    @Test func anEventCrossesFieldByField() throws {
        var event = Event(title: "Review", start: 1_000_000, end: 4_600_000)
        event.id = "abc"
        event.calendar = "work"
        event.location = "Room 4"
        event.notes = "Bring slides"
        event.url = "https://example.com/review"
        event.timeZone = "Europe/Dublin"
        event.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.tuesday], end: .count(4))
        event.occurrence = 1_000_000
        event.alarms = [.before(minutes: 15), .before(minutes: 60)]
        event.availability = .tentative

        store.save(event, span: .futureEvents) { _ in }
        let sent = try #require(ScriptedEventRecord.saved.last)
        #expect(sent.span == 1 && sent.record.id == "abc" && sent.record.occurrenceStart == 1_000_000)
        #expect(sent.record.calendarID == "work" && sent.record.text == ["Review", "Room 4", "Bring slides", "https://example.com/review"])
        #expect(sent.record.startTime == 1_000_000 && sent.record.endTime == 4_600_000 && !sent.record.allDay)
        #expect(sent.record.zone == "Europe/Dublin" && sent.record.rule == "FREQ=WEEKLY;BYDAY=TU;COUNT=4")
        #expect(sent.record.alarmText == "15,60" && sent.record.availabilityValue == 2)

        // Read back, it's the same event.
        sent.record.detached = true
        var changed = event
        changed.isDetached = true
        #expect(Event(sent.record) == changed)

        // A new event has no identity, calendar, zone or rule to send.
        store.save(Event(title: "New", start: 5, end: 9, isAllDay: true)) { _ in }
        let new = try #require(ScriptedEventRecord.saved.last)
        #expect(new.span == 0 && new.record.id == "" && new.record.occurrenceStart == -1 && new.record.calendarID == "")
        #expect(new.record.zone == "" && new.record.rule == "" && new.record.alarmText == "" && new.record.allDay)
        #expect(Event(new.record) == Event(title: "New", start: 5, end: 9, isAllDay: true))

        // What a newer host says that isn't known is taken as nothing.
        new.record.availabilityValue = 42
        new.record.rule = "FREQ=FORTNIGHTLY"
        #expect(Event(new.record).availability == .notSupported && Event(new.record).recurrence == nil)
    }

    @Test func theStoreAsksTheHost() throws {
        var lists: [Result<[Event], EventStoreError>] = []
        var calendars: [Result<[EventCalendar], EventStoreError>] = []
        var found: [Result<Event?, EventStoreError>] = []
        var defaults: [Result<EventCalendar?, EventStoreError>] = []
        store.calendars { calendars.append($0) }
        store.defaultCalendar { defaults.append($0) }
        store.defaultCalendar { defaults.append($0) }
        store.events(from: 100, to: 200) { lists.append($0) }
        store.events(from: 100, to: 200, in: [EventCalendar(id: "work", title: "Work"), EventCalendar(id: "home", title: "Home")]) { lists.append($0) }
        store.event(withID: "abc") { found.append($0) }
        store.event(withID: "gone") { found.append($0) }
        #expect(host.calls == [
            "calendars", "defaultCalendar", "defaultCalendar", "events 100 200 []", "events 100 200 [\"work\", \"home\"]",
            "event abc", "event gone",
        ])

        host.callbacks[0].didListCalendars([ScriptedCalendarRecord()])
        #expect(try calendars[0].get() == [EventCalendar(id: "work", title: "Work", account: "ada@example.com", color: 0xFFFF_3B30, isWritable: false)])
        host.callbacks[1].didFindCalendar(ScriptedCalendarRecord())
        host.callbacks[2].didFindCalendar(nil)
        #expect(try defaults[0].get()?.id == "work")
        if case .success(let none) = defaults[1] { #expect(none == nil) } else { Issue.record("no default was a failure") }

        let record = ScriptedEventRecord()
        record.id = "abc"
        record.text[0] = "Standup"
        record.occurrenceStart = 150
        host.callbacks[3].didListEvents([record, record])
        host.callbacks[4].didFail(EventStoreError.invalidRange.rawValue)
        #expect(try lists[0].get().map(\.title) == ["Standup", "Standup"] && lists[0].get().first?.occurrence == 150)
        #expect(error(lists[1]) == .invalidRange)
        host.callbacks[5].didFindEvent(record)
        host.callbacks[6].didFindEvent(nil)
        #expect(try found[0].get()?.id == "abc")
        if case .success(let none) = found[1] { #expect(none == nil, "gone isn't an error") } else { Issue.record("no event was a failure") }
    }

    @Test func savingAndRemovingAnswerOnce() throws {
        var saves: [Result<Event, EventStoreError>] = []
        var removals: [Result<Void, EventStoreError>] = []
        let event = Event(title: "One", start: 1, end: 2)
        store.save(event) { saves.append($0) }
        store.save(event) { saves.append($0) }
        store.save(event) { saves.append($0) }
        store.remove(event) { removals.append($0) }
        store.remove(event, span: .futureEvents) { removals.append($0) }

        let record = ScriptedEventRecord()
        record.id = "made"
        ScriptedEventRecord.saved[0].callback.didFindEvent(record)
        ScriptedEventRecord.saved[0].callback.didFail(0)
        ScriptedEventRecord.saved[1].callback.didFindEvent(nil)
        ScriptedEventRecord.saved[2].callback.didFail(EventStoreError.readOnly.rawValue)
        #expect(saves.count == 3 && (try? saves[0].get())?.id == "made")
        #expect(error(saves[1]) == .unknown, "a save that gives no event back")
        #expect(error(saves[2]) == .readOnly)

        #expect(ScriptedEventRecord.removed.map(\.span) == [0, 1])
        ScriptedEventRecord.removed[0].callback.didComplete()
        ScriptedEventRecord.removed[1].callback.didFail(77)
        #expect(error(removals[0]) == nil && error(removals[1]) == .unknown, "an error from a newer host")
    }

    @Test func oneListenerHearsOfChanges() {
        var first = 0
        var second = 0
        store.onChange { first += 1 }
        host.delegate?.didChange()
        store.onChange { second += 1 }
        host.delegate?.didChange()
        host.delegate?.didChange()
        #expect(first == 1 && second == 2, "a new closure replaces the one before")
        store.onChange(nil)
        #expect(host.delegate == nil && host.calls == ["setDelegate", "setDelegate", "setDelegate nil"])
    }
}
