import DynamicRuntime

/// The user's calendars and the events in them, as the system keeps them
/// (`Documentation/Contracts/Calendars.md`). App code uses `EventStore`,
/// which wraps this contract.
///
/// The store is the system's: its accounts are set up and synced there,
/// and repeating events are expanded by it. An app reads what's there and
/// changes it. Every operation completes through its `callback`, which the
/// host holds until it has called exactly one of its methods, on the main
/// thread.
///
/// Times are milliseconds since 1970. An all-day event runs from 00:00 UTC
/// of its first day to 00:00 UTC of the day after its last. A repeat rule
/// is an RFC 5545 `RRULE` value, without `RRULE:` in front.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `EKEventStore` |
/// | Android | `CalendarContract`, through the `ContentResolver` |
/// | Linux | the host's calendar service |
/// | Browser | none |
@DynamicRuntime("org.pureswift.calendar.Calendars", requires: .calendars)
public protocol Calendars: AnyObject {

    static func shared() -> Self

    /// An `EventStoreAccess` raw value. Never asks.
    func access() -> Int32

    /// Asks the user if they haven't decided, for the level the manifest
    /// declares. Answered by `didChangeAccess`.
    func requestAccess(_ callback: CalendarCallback)

    /// Told after any change to the store. `nil` stops it.
    func setDelegate(_ delegate: CalendarsDelegate?)

    /// Answered by `didListCalendars`.
    func calendars(_ callback: CalendarCallback)

    /// Where the user wants new events. Answered by `didFindCalendar`.
    func defaultCalendar(_ callback: CalendarCallback)

    /// Occurrences that overlap the range, in the calendars named; none
    /// named is all. Answered by `didListEvents`.
    func events(_ start: Int64, end: Int64, calendars: [String], callback: CalendarCallback)

    /// One event: the first occurrence of one that repeats. Answered by
    /// `didFindEvent`.
    func event(_ identifier: String, callback: CalendarCallback)

    /// An event to fill in and save: a new one, until it's told which
    /// event it is.
    func makeEvent() -> CalendarEventRecord
}

/// One calendar. The host's object: the guest reads it when it arrives.
@DynamicRuntime("org.pureswift.calendar.Calendar")
public protocol CalendarRecord: AnyObject {

    func identifier() -> String

    func title() -> String

    /// The account it comes from; empty for one that's only on the device.
    func account() -> String

    /// `0xAARRGGBB`.
    func color() -> Int32

    func isWritable() -> Bool
}

/// One event, or one occurrence of one that repeats. The host's object:
/// the guest reads one that arrives, and fills one in to save.
@DynamicRuntime("org.pureswift.calendar.Event")
public protocol CalendarEventRecord: AnyObject {

    // MARK: Reading

    /// Empty for one that isn't saved.
    func identifier() -> String

    func calendar() -> String

    func title() -> String

    func location() -> String

    func notes() -> String

    func url() -> String

    func start() -> Int64

    func end() -> Int64

    func isAllDay() -> Bool

    /// An IANA name; empty for the device's zone.
    func timeZone() -> String

    /// An `RRULE` value; empty for an event that doesn't repeat.
    func recurrence() -> String

    /// This occurrence's own start, before any change to it; -1 for an
    /// event that doesn't repeat.
    func occurrence() -> Int64

    /// An occurrence that was changed by itself.
    func isDetached() -> Bool

    /// Minutes before the start, as decimal numbers with commas between.
    func alarms() -> String

    /// An `EventAvailability` raw value.
    func availability() -> Int32

    // MARK: Filling in

    /// Which event this is, to change one the store has: its identifier,
    /// and for one that repeats the occurrence, or -1.
    func setIdentity(_ identifier: String, occurrence: Int64)

    /// Empty: the default calendar.
    func setCalendar(_ identifier: String)

    func setText(_ title: String, location: String, notes: String, url: String)

    func setDates(_ start: Int64, end: Int64, allDay: Bool, timeZone: String)

    func setRecurrence(_ rule: String)

    func setAlarms(_ minutes: String)

    func setAvailability(_ availability: Int32)

    // MARK: Storing

    /// Adds the event, or changes the one it's told it is. `span` is an
    /// `EventSpan` raw value. Answered by `didFindEvent`, with the event as
    /// the store now has it.
    func save(_ span: Int32, callback: CalendarCallback)

    /// Answered by `didComplete`.
    func remove(_ span: Int32, callback: CalendarCallback)
}

/// One operation's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.calendar.Callback")
public protocol CalendarCallback: AnyObject {

    func didComplete()

    /// An `EventStoreAccess` raw value.
    func didChangeAccess(_ access: Int32)

    func didListCalendars(_ calendars: [CalendarRecord])

    func didFindCalendar(_ calendar: CalendarRecord?)

    func didListEvents(_ events: [CalendarEventRecord])

    func didFindEvent(_ event: CalendarEventRecord?)

    /// An `EventStoreError` raw value.
    func didFail(_ error: Int32)
}

/// What a store tells the app, from the host. Called on the main thread.
@DynamicCallback("org.pureswift.calendar.Delegate")
public protocol CalendarsDelegate: AnyObject {

    /// Something changed: another app, a sync, or this app. Not what.
    func didChange()
}
