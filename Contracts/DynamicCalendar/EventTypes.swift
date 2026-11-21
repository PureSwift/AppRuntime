/// Guest-side names for what the `Calendars` contract carries.

/// How much of the user's calendars the app may use.
public enum EventStoreAccess: Int32, Sendable {

    /// The user hasn't been asked.
    case notDetermined = 0

    /// Parental controls or device management prevent access.
    case restricted = 1

    /// The user refused, or the manifest doesn't declare `.calendars`.
    case denied = 2

    /// Reading events and changing them.
    case full = 3

    /// Adding events, and reading none.
    case writeOnly = 4

    /// This host has no calendar store.
    case unavailable = 5
}

/// Why a calendar call failed.
public enum EventStoreError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The operation may
    /// still happen. Hosts never send it.
    case cancelled = 1

    /// No access, or not enough for this call.
    case notAuthorized = 2

    /// This host has no calendar store.
    case unavailable = 3

    /// The event or the calendar is gone.
    case notFound = 4

    /// The calendar can't be changed.
    case readOnly = 5

    /// An event that ends before it starts.
    case invalidDates = 6

    /// A range that ends before it starts, or covers more than four years.
    case invalidRange = 7

    /// A changed rule saved for one occurrence alone.
    case invalidSpan = 8

    /// A rule this store can't hold.
    case unsupportedRecurrence = 9
}

/// Which occurrences of a repeating event a save or a removal reaches.
public enum EventSpan: Int32, Sendable {

    /// This occurrence alone.
    case thisEvent = 0

    /// This occurrence and every one after it.
    case futureEvents = 1
}

/// Whether an event takes up the user's time.
public enum EventAvailability: Int32, Sendable {

    /// The calendar doesn't say.
    case notSupported = -1

    case busy = 0

    case free = 1

    case tentative = 2

    case unavailable = 3
}

/// A reminder before an event starts.
public struct EventAlarm: Equatable, Hashable, Sendable {

    /// How long before the start. 0 is at the start.
    public var minutesBefore: Int

    public init(minutesBefore: Int) {
        self.minutesBefore = max(minutesBefore, 0)
    }

    public static func before(minutes: Int) -> EventAlarm {
        EventAlarm(minutesBefore: minutes)
    }

    /// At the start.
    public static let atStart = EventAlarm(minutesBefore: 0)

    /// Alarms as the contract carries them: decimal minutes with commas
    /// between.
    public static func text(_ alarms: [EventAlarm]) -> String {
        var text = ""
        for alarm in alarms {
            if !text.isEmpty { text += "," }
            text += String(alarm.minutesBefore)
        }
        return text
    }

    /// What isn't a number is left out.
    public static func alarms(_ text: String) -> [EventAlarm] {
        text.split(separator: ",").compactMap { Int($0) }.filter { $0 >= 0 }.map { EventAlarm(minutesBefore: $0) }
    }
}

/// One of the user's calendars.
public struct EventCalendar: Equatable, Hashable, Sendable, Identifiable {

    /// The store's identifier for it.
    public var id: String

    public var title: String

    /// The account it comes from: "iCloud", an email address. Empty for
    /// one that's only on the device.
    public var account: String

    /// `0xAARRGGBB`.
    public var color: UInt32

    /// Whether events can be added to it and changed.
    public var isWritable: Bool

    public init(id: String, title: String, account: String = "", color: UInt32 = 0xFF00_7AFF, isWritable: Bool = true) {
        self.id = id
        self.title = title
        self.account = account
        self.color = color
        self.isWritable = isWritable
    }
}

/// One event, or one occurrence of an event that repeats. A value: change
/// it and give it back to the store to save.
///
/// ```swift
/// var lunch = Event(title: "Lunch", start: start, end: start + 3_600_000)
/// lunch.alarms = [.before(minutes: 15)]
/// lunch.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.tuesday])
/// lunch = try await store.save(lunch)
/// ```
///
/// Times are milliseconds since 1970, as `DateFormat` takes them. An
/// all-day event has `start` at 00:00 UTC of its first day and `end` at
/// 00:00 UTC of the day after its last: it's on those days in every time
/// zone.
public struct Event: Equatable, Hashable, Sendable {

    /// The store's identifier; `nil` until it's saved. Every occurrence of
    /// a repeating event has the same one.
    public var id: String?

    /// An `EventCalendar.id`; `nil` on a new event means the default.
    public var calendar: String?

    public var title: String

    public var location: String

    public var notes: String

    public var url: String

    public var start: Int64

    public var end: Int64

    public var isAllDay: Bool

    /// An IANA name: where 9:00 stays 9:00 as the clocks change. `nil` is
    /// the device's zone.
    public var timeZone: String?

    public var recurrence: RecurrenceRule?

    /// This occurrence's own start, as the rule gave it and before any
    /// change to it. `nil` for an event that doesn't repeat. It says which
    /// occurrence a save or a removal means.
    public var occurrence: Int64?

    /// An occurrence that was changed by itself.
    public var isDetached: Bool

    public var alarms: [EventAlarm]

    public var availability: EventAvailability

    public init(title: String, start: Int64, end: Int64, isAllDay: Bool = false) {
        self.id = nil
        self.calendar = nil
        self.title = title
        self.location = ""
        self.notes = ""
        self.url = ""
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = nil
        self.recurrence = nil
        self.occurrence = nil
        self.isDetached = false
        self.alarms = []
        self.availability = .notSupported
    }

    /// How long it lasts, in milliseconds.
    public var duration: Int64 {
        end - start
    }

    /// Whether any of it is in the range: it ends after the range starts
    /// and starts before the range ends. An event with no length is in a
    /// range it starts in.
    public func overlaps(_ rangeStart: Int64, _ rangeEnd: Int64) -> Bool {
        if end == start {
            return start >= rangeStart && start < rangeEnd
        }
        return end > rangeStart && start < rangeEnd
    }
}

extension Event {

    /// The event a record holds, read whole.
    public init(_ record: any CalendarEventRecord) {
        let identifier = record.identifier()
        let calendar = record.calendar()
        let timeZone = record.timeZone()
        let occurrence = record.occurrence()
        self.id = identifier.isEmpty ? nil : identifier
        self.calendar = calendar.isEmpty ? nil : calendar
        self.title = record.title()
        self.location = record.location()
        self.notes = record.notes()
        self.url = record.url()
        self.start = record.start()
        self.end = record.end()
        self.isAllDay = record.isAllDay()
        self.timeZone = timeZone.isEmpty ? nil : timeZone
        self.recurrence = RecurrenceRule(rrule: record.recurrence())
        self.occurrence = occurrence < 0 ? nil : occurrence
        self.isDetached = record.isDetached()
        self.alarms = EventAlarm.alarms(record.alarms())
        // An availability from a newer host is one the calendar doesn't say.
        self.availability = EventAvailability(rawValue: record.availability()) ?? .notSupported
    }

    /// Fills a record in with this event, to save or to remove.
    public func fill(_ record: any CalendarEventRecord) {
        record.setIdentity(id ?? "", occurrence: occurrence ?? -1)
        record.setCalendar(calendar ?? "")
        record.setText(title, location: location, notes: notes, url: url)
        record.setDates(start, end: end, allDay: isAllDay, timeZone: timeZone ?? "")
        record.setRecurrence(recurrence?.rrule ?? "")
        record.setAlarms(EventAlarm.text(alarms))
        record.setAvailability(availability.rawValue)
    }
}

extension EventCalendar {

    /// The calendar a record holds.
    public init(_ record: any CalendarRecord) {
        self.id = record.identifier()
        self.title = record.title()
        self.account = record.account()
        self.color = UInt32(bitPattern: record.color())
        self.isWritable = record.isWritable()
    }
}
