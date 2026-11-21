import Dispatch
import DynamicCalendar
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// The platform's calendar store: `EKEventStore`, the calendar provider.
/// It works in the guest's own values. It's called off the main thread, by
/// one thread at a time, in the order the guest asked.
///
/// `HostCalendars` has checked access, dates, ranges and calendars before a
/// store sees a call, and sorts what it returns.
public protocol CalendarStore: AnyObject, Sendable {

    /// Every calendar, in the system's order.
    func calendars() throws(EventStoreError) -> [EventCalendar]

    /// Where the user wants new events; `nil` when there's nowhere.
    func defaultCalendar() throws(EventStoreError) -> EventCalendar?

    /// One `Event` for each occurrence that overlaps the range, in the
    /// calendars named; none named is all. The platform's own expansion of
    /// events that repeat. Each has its `occurrence`, and `isDetached`
    /// when it was changed by itself.
    func events(from start: Int64, to end: Int64, in calendars: [String]) throws(EventStoreError) -> [Event]

    /// One event: the first occurrence of one that repeats. `nil` when
    /// there's none.
    func event(withID identifier: String) throws(EventStoreError) -> Event?

    /// Adds an event with no `id`, or changes the one it names, keeping
    /// what the store holds of it that an `Event` doesn't carry. Gives the
    /// event as stored. For one that repeats, `span` and the event's
    /// `occurrence` say which occurrences are meant. A rule the platform
    /// can't hold is `unsupportedRecurrence`, and nothing is saved.
    func save(_ event: Event, span: EventSpan) throws(EventStoreError) -> Event

    func remove(_ event: Event, span: EventSpan) throws(EventStoreError)
}

/// The `Calendars` contract over a host's `CalendarStore`: what every host
/// written in Swift shares.
///
/// It checks access before every call, and dates, ranges, spans and
/// calendars before a store sees them; runs the store off the main thread
/// in order; sorts; makes the records; and gathers a burst of changes into
/// one report.
///
/// ```swift
/// HostCalendars.store = MyEventStore()
/// HostCalendars.declaredAccess = .full              // RTCapabilityOptions.calendars.access
/// HostCalendars.access = .notDetermined             // what the platform says now
/// HostCalendars.requester = { completion in … }      // the platform's question
/// HostCalendarsModule.register(in: runtime)
///
/// HostCalendars.storeChanged()                      // from the platform
/// ```
///
/// Without a store every call fails with `unavailable`. Main thread only.
public final class HostCalendars: Calendars {

    // MARK: The host's settings

    /// The platform's store.
    nonisolated(unsafe) public static var store: (any CalendarStore)?

    /// What the user has granted, as the platform says: `.full`,
    /// `.writeOnly`, or not.
    nonisolated(unsafe) public static var access = EventStoreAccess.notDetermined

    /// The level the manifest declares: `.full` or `.writeOnly`. An app
    /// that declared write-only never reads, whatever the user granted.
    nonisolated(unsafe) public static var declaredAccess = EventStoreAccess.full

    /// Asks the user, at the declared level, and says what they granted.
    /// Called on the main thread while `access` is `.notDetermined`.
    nonisolated(unsafe) public static var requester: ((@escaping (EventStoreAccess) -> Void) -> Void)?

    /// Runs the store's work off the main thread. The default is a serial
    /// queue; whatever replaces it must keep the order.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.calendar")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// The one store. Never replaced: a guest keeps the object it first
    /// asked for.
    nonisolated(unsafe) private static let instance = HostCalendars()

    public static func shared() -> HostCalendars {
        instance
    }

    /// Forgets the store, the settings and the guest's delegate, for tests
    /// and for a host that starts the guest again.
    public static func reset() {
        store = nil
        access = .notDetermined
        declaredAccess = .full
        requester = nil
        work = defaultWork
        deliver = defaultDeliver
        instance.delegate = nil
        instance.changePending = false
    }

    /// What the app may do now: what the user granted, no more than the
    /// manifest declares, and nothing without a store.
    public static var effectiveAccess: EventStoreAccess {
        guard store != nil else { return .unavailable }
        if access == .full, declaredAccess == .writeOnly {
            return .writeOnly
        }
        return access
    }

    /// Something in the platform's store changed: another app, a sync.
    /// A burst of these reaches the guest as one `didChange`.
    public static func storeChanged() {
        let instance = Self.instance
        guard !instance.changePending else { return }
        instance.changePending = true
        deliver {
            let instance = HostCalendars.shared()
            guard instance.changePending else { return }
            instance.changePending = false
            instance.delegate?.didChange()
        }
    }

    // MARK: State

    private var delegate: (any CalendarsDelegate)?

    private var changePending = false

    // MARK: Answers

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any CalendarCallback, _ answer: @escaping (any CalendarCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func fail(_ callback: any CalendarCallback, _ error: EventStoreError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    /// The store, when the app has at least `needed`; otherwise the
    /// callback is failed.
    private static func store(for callback: any CalendarCallback, needing needed: EventStoreAccess) -> (any CalendarStore)? {
        guard let store else {
            fail(callback, .unavailable)
            return nil
        }
        let has = effectiveAccess
        guard has == .full || (needed == .writeOnly && has == .writeOnly) else {
            fail(callback, .notAuthorized)
            return nil
        }
        return store
    }

    /// Runs `operation` off the main thread, and answers `callback` on it
    /// with what `answer` makes of the result.
    fileprivate static func run<Value: Sendable>(
        _ callback: any CalendarCallback,
        _ operation: @escaping @Sendable () throws(EventStoreError) -> Value,
        _ answer: @escaping (any CalendarCallback, Value) -> Void
    ) {
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld((callback, answer))
        let deliver = Self.deliver
        work {
            let result: Result<Value, EventStoreError>
            do throws(EventStoreError) {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }
            deliver {
                guard let (callback, answer) = held.take() else { return }
                switch result {
                case .success(let value):
                    answer(callback, value)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    // MARK: Access

    public func access() -> Int32 {
        Self.effectiveAccess.rawValue
    }

    /// Asks the user if they haven't decided, and says what the app has.
    public static func requestAccess(_ completion: @escaping (EventStoreAccess) -> Void) {
        guard store != nil, access == .notDetermined, let requester else {
            completion(effectiveAccess)
            return
        }
        var answered = false
        requester { granted in
            // A platform that answers twice is heard once.
            guard !answered else { return }
            answered = true
            access = granted
            completion(effectiveAccess)
        }
    }

    public func requestAccess(_ callback: any CalendarCallback) {
        Self.requestAccess { access in
            Self.later(callback) { $0.didChangeAccess(access.rawValue) }
        }
    }

    public func setDelegate(_ delegate: (any CalendarsDelegate)?) {
        self.delegate = delegate
    }

    // MARK: Reading

    public func calendars(_ callback: any CalendarCallback) {
        guard let store = Self.store(for: callback, needing: .full) else { return }
        Self.run(callback, { () throws(EventStoreError) in try store.calendars() }) { callback, calendars in
            callback.didListCalendars(calendars.map { HostCalendarRecord($0) })
        }
    }

    public func defaultCalendar(_ callback: any CalendarCallback) {
        guard let store = Self.store(for: callback, needing: .full) else { return }
        Self.run(callback, { () throws(EventStoreError) in try Self.writableDefault(of: store) }) { callback, calendar in
            callback.didFindCalendar(calendar.map { HostCalendarRecord($0) })
        }
    }

    /// The default calendar, when it can be written.
    private static func writableDefault(of store: any CalendarStore) throws(EventStoreError) -> EventCalendar? {
        guard let calendar = try store.defaultCalendar(), calendar.isWritable else { return nil }
        return calendar
    }

    public func events(_ start: Int64, end: Int64, calendars: [String], callback: any CalendarCallback) {
        guard let store = Self.store(for: callback, needing: .full) else { return }
        guard end >= start, end - start <= EventStore.maximumRange else {
            Self.fail(callback, .invalidRange)
            return
        }
        Self.run(callback, { () throws(EventStoreError) in
            try store.events(from: start, to: end, in: calendars).sorted(by: Self.precedes)
        }) { callback, events in
            callback.didListEvents(events.map { HostCalendarEventRecord($0) })
        }
    }

    /// By start, then title, then identifier, so every host gives the same
    /// order.
    private static func precedes(_ first: Event, _ second: Event) -> Bool {
        if first.start != second.start { return first.start < second.start }
        if first.title != second.title { return first.title < second.title }
        return (first.id ?? "") < (second.id ?? "")
    }

    public func event(_ identifier: String, callback: any CalendarCallback) {
        guard let store = Self.store(for: callback, needing: .full) else { return }
        Self.run(callback, { () throws(EventStoreError) in try store.event(withID: identifier) }) { callback, event in
            callback.didFindEvent(event.map { HostCalendarEventRecord($0) })
        }
    }

    public func makeEvent() -> any CalendarEventRecord {
        HostCalendarEventRecord(Event(title: "", start: 0, end: 0))
    }

    // MARK: Writing

    /// An all-day event as the contract has it: from 00:00 UTC of its
    /// first day to 00:00 UTC of the day after its last.
    static func normalized(_ event: Event) -> Event {
        guard event.isAllDay else { return event }
        var event = event
        event.start = CivilDate(millisecondsSince1970: event.start).millisecondsSince1970
        let lastDay = CivilDate(millisecondsSince1970: max(event.end - 1, event.start))
        event.end = lastDay.millisecondsSince1970 + 86_400_000
        return event
    }

    fileprivate static func save(_ record: HostCalendarEventRecord, span: Int32, callback: any CalendarCallback) {
        let isNew = record.event.id == nil
        guard let store = store(for: callback, needing: isNew ? .writeOnly : .full) else { return }
        guard !record.hasUnreadableRule else {
            fail(callback, .unsupportedRecurrence)
            return
        }
        guard record.event.end >= record.event.start else {
            fail(callback, .invalidDates)
            return
        }
        // A span from a newer guest is the narrower one.
        let span = EventSpan(rawValue: span) ?? .thisEvent
        let event = normalized(record.event)
        let readsBack = effectiveAccess == .full
        run(callback, { () throws(EventStoreError) in
            var event = event
            if let identifier = event.id {
                guard let existing = try store.event(withID: identifier) else {
                    throw .notFound
                }
                try checkWritable(existing.calendar, in: store)
                if existing.recurrence != nil {
                    if span == .thisEvent, event.recurrence != existing.recurrence {
                        throw .invalidSpan
                    }
                    // With none said, the first occurrence.
                    event.occurrence = event.occurrence ?? existing.occurrence ?? existing.start
                }
                if event.calendar == nil {
                    event.calendar = existing.calendar
                }
            } else if event.calendar == nil {
                guard let calendar = try writableDefault(of: store) else {
                    throw .readOnly
                }
                event.calendar = calendar.id
            }
            try checkWritable(event.calendar, in: store)
            return try store.save(event, span: span)
        }) { callback, saved in
            var saved = saved
            if !readsBack {
                // Write-only: the app learns nothing the store made up.
                saved.id = nil
                saved.occurrence = nil
                saved.isDetached = false
            }
            callback.didFindEvent(HostCalendarEventRecord(saved))
            storeChanged()
        }
    }

    fileprivate static func remove(_ record: HostCalendarEventRecord, span: Int32, callback: any CalendarCallback) {
        guard let store = store(for: callback, needing: .full) else { return }
        guard let identifier = record.event.id else {
            fail(callback, .notFound)
            return
        }
        let span = EventSpan(rawValue: span) ?? .thisEvent
        let event = record.event
        run(callback, { () throws(EventStoreError) in
            guard let existing = try store.event(withID: identifier) else {
                throw .notFound
            }
            try checkWritable(existing.calendar, in: store)
            var event = event
            if existing.recurrence != nil {
                event.occurrence = event.occurrence ?? existing.occurrence ?? existing.start
            }
            try store.remove(event, span: span)
        }) { callback, _ in
            callback.didComplete()
            storeChanged()
        }
    }

    /// Fails unless the calendar is there and can be changed.
    private static func checkWritable(_ identifier: String?, in store: any CalendarStore) throws(EventStoreError) {
        guard let identifier, let calendar = try store.calendars().first(where: { $0.id == identifier }) else {
            throw .notFound
        }
        guard calendar.isWritable else {
            throw .readOnly
        }
    }
}

/// One calendar, as the guest reads it.
final class HostCalendarRecord: CalendarRecord {

    let calendar: EventCalendar

    init(_ calendar: EventCalendar) {
        self.calendar = calendar
    }

    func identifier() -> String { calendar.id }
    func title() -> String { calendar.title }
    func account() -> String { calendar.account }
    func color() -> Int32 { Int32(bitPattern: calendar.color) }
    func isWritable() -> Bool { calendar.isWritable }
}

/// One event: what the guest reads when it arrives, and fills in to save.
public final class HostCalendarEventRecord: CalendarEventRecord {

    public private(set) var event: Event

    /// The guest set a rule that isn't an `RRULE`.
    fileprivate var hasUnreadableRule = false

    init(_ event: Event) {
        self.event = event
    }

    public func identifier() -> String { event.id ?? "" }
    public func calendar() -> String { event.calendar ?? "" }
    public func title() -> String { event.title }
    public func location() -> String { event.location }
    public func notes() -> String { event.notes }
    public func url() -> String { event.url }
    public func start() -> Int64 { event.start }
    public func end() -> Int64 { event.end }
    public func isAllDay() -> Bool { event.isAllDay }
    public func timeZone() -> String { event.timeZone ?? "" }
    public func recurrence() -> String { event.recurrence?.rrule ?? "" }
    public func occurrence() -> Int64 { event.occurrence ?? -1 }
    public func isDetached() -> Bool { event.isDetached }
    public func alarms() -> String { EventAlarm.text(event.alarms) }
    public func availability() -> Int32 { event.availability.rawValue }

    public func setIdentity(_ identifier: String, occurrence: Int64) {
        event.id = identifier.isEmpty ? nil : identifier
        event.occurrence = occurrence < 0 ? nil : occurrence
    }

    public func setCalendar(_ identifier: String) {
        event.calendar = identifier.isEmpty ? nil : identifier
    }

    public func setText(_ title: String, location: String, notes: String, url: String) {
        event.title = title
        event.location = location
        event.notes = notes
        event.url = url
    }

    public func setDates(_ start: Int64, end: Int64, allDay: Bool, timeZone: String) {
        event.start = start
        event.end = end
        event.isAllDay = allDay
        event.timeZone = timeZone.isEmpty ? nil : timeZone
    }

    public func setRecurrence(_ rule: String) {
        event.recurrence = RecurrenceRule(rrule: rule)
        hasUnreadableRule = !rule.isEmpty && event.recurrence == nil
    }

    public func setAlarms(_ minutes: String) {
        event.alarms = EventAlarm.alarms(minutes)
    }

    public func setAvailability(_ availability: Int32) {
        event.availability = EventAvailability(rawValue: availability) ?? .notSupported
    }

    public func save(_ span: Int32, callback: any CalendarCallback) {
        HostCalendars.save(self, span: span, callback: callback)
    }

    public func remove(_ span: Int32, callback: any CalendarCallback) {
        HostCalendars.remove(self, span: span, callback: callback)
    }
}

/// Calendar access as the built-in `Permissions` contract reports it:
/// write-only is its `limited`.
public final class CalendarPermission: PermissionProvider {

    public init() { }

    static func status(_ access: EventStoreAccess) -> PermissionStatus {
        switch access {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .full: return .granted
        case .writeOnly: return .limited
        case .unavailable: return .unavailable
        }
    }

    public func status() -> PermissionStatus {
        Self.status(HostCalendars.effectiveAccess)
    }

    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        HostCalendars.requestAccess { completion(Self.status($0)) }
    }
}

/// The calendar module: the contract, its records, its callback and its
/// delegate.
public enum HostCalendarsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            CalendarsProxy.descriptor, CalendarRecordProxy.descriptor, CalendarEventRecordProxy.descriptor,
            CalendarCallbackProxy.descriptor, CalendarsDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        CalendarsProxy.register(HostCalendars.self, in: registrar)
        CalendarRecordProxy.register(HostCalendarRecord.self, in: registrar)
        CalendarEventRecordProxy.register(HostCalendarEventRecord.self, in: registrar)
        CalendarCallbackProxy.registerInterface(in: registrar)
        CalendarsDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.calendars: CalendarPermission()]
    }
}
