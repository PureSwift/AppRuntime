import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The user's calendars and the events in them: `EKEventStore`'s place.
///
/// ```swift
/// let store = EventStore.default
/// guard try await store.requestAccess() == .full else { return }
/// let events = try await store.events(from: monthStart, to: monthEnd)
///
/// var lunch = Event(title: "Lunch", start: start, end: start + 3_600_000)
/// lunch = try await store.save(lunch)
/// ```
///
/// The store is the system's: it holds the accounts, syncs them, and
/// expands events that repeat. `events(from:to:)` gives one `Event` for
/// each occurrence. An app that only adds events, with `.writeOnly`
/// access, can `save` a new one and read nothing.
///
/// Every call is asynchronous, with a completion-handler form. It's
/// guest-side only, over the `Calendars` contract, which requires
/// `.calendars` in the manifest. The guest is single-threaded (§6.4).
public final class EventStore: @unchecked Sendable {

    /// The system's store.
    public static let `default` = EventStore()

    /// The longest range `events(from:to:)` takes: four years.
    public static let maximumRange: Int64 = 4 * 366 * 86_400_000

    /// The host's store, made when first used.
    private var made: (any Calendars)?

    private let listener = Listener()

    init() { }

    private var calendars: any Calendars {
        if let made {
            return made
        }
        let calendars = CalendarsProxy.shared()
        made = calendars
        return calendars
    }

    // MARK: Access

    /// How much the app may use now. Never asks.
    public var access: EventStoreAccess {
        // An access from a newer host isn't one to rely on.
        EventStoreAccess(rawValue: calendars.access()) ?? .denied
    }

    /// Asks the user if they haven't decided, for the level the manifest
    /// declares, and gives what the app has afterwards.
    public func requestAccess(completion: @escaping (EventStoreAccess) -> Void) {
        calendars.requestAccess(Receiver { outcome in
            if case .access(let access) = outcome {
                completion(access)
            } else {
                completion(.denied)
            }
        })
    }

    // MARK: Calendars

    /// Every calendar, in the system's order.
    public func calendars(completion: @escaping (Result<[EventCalendar], EventStoreError>) -> Void) {
        calendars.calendars(Receiver { outcome in
            if case .calendars(let calendars) = outcome {
                completion(.success(calendars))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Where the user wants new events; `nil` when no calendar can be
    /// written.
    public func defaultCalendar(completion: @escaping (Result<EventCalendar?, EventStoreError>) -> Void) {
        calendars.defaultCalendar(Receiver { outcome in
            if case .calendar(let calendar) = outcome {
                completion(.success(calendar))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Events

    /// What overlaps the range, one `Event` per occurrence, sorted by
    /// start. `calendars` are the ones to look in; none means all. A range
    /// over four years fails with `invalidRange`.
    public func events(from start: Int64, to end: Int64, in calendars: [EventCalendar] = [], completion: @escaping (Result<[Event], EventStoreError>) -> Void) {
        self.calendars.events(start, end: end, calendars: calendars.map { $0.id }, callback: Receiver { outcome in
            if case .events(let events) = outcome {
                completion(.success(events))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// One event by its identifier: the first occurrence of one that
    /// repeats. `nil` when it's gone.
    public func event(withID identifier: String, completion: @escaping (Result<Event?, EventStoreError>) -> Void) {
        calendars.event(identifier, callback: Receiver.finding(completion))
    }

    /// Adds a new event, or changes one, and gives it back as the store
    /// now has it. For an event that repeats, `span` says whether this
    /// occurrence alone is meant, or it and the ones after. With
    /// `.writeOnly` access, what comes back has no identifier.
    public func save(_ event: Event, span: EventSpan = .thisEvent, completion: @escaping (Result<Event, EventStoreError>) -> Void) {
        let record = calendars.makeEvent()
        event.fill(record)
        record.save(span.rawValue, callback: Receiver { outcome in
            if case .event(let saved?) = outcome {
                completion(.success(saved))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Deletes an event the store has.
    public func remove(_ event: Event, span: EventSpan = .thisEvent, completion: @escaping (Result<Void, EventStoreError>) -> Void) {
        let record = calendars.makeEvent()
        event.fill(record)
        record.remove(span.rawValue, callback: Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Changes

    /// Called when anything in the store changed: another app, a sync, or
    /// this app. It doesn't say what; fetch again. One listener at a time:
    /// a new closure, or a `changes` stream, replaces it, and `nil` stops
    /// it.
    public func onChange(_ handler: (() -> Void)?) {
        listener.handler = handler
        calendars.setDelegate(handler == nil ? nil : listener)
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func requestAccess() async -> EventStoreAccess {
        await withCallback { (callback: Callback<EventStoreAccess, Never>) in
            self.requestAccess { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: .denied)
        }
    }

    public nonisolated(nonsending) func calendars() async throws(EventStoreError) -> [EventCalendar] {
        try await wait { self.calendars(completion: $0) }
    }

    public nonisolated(nonsending) func defaultCalendar() async throws(EventStoreError) -> EventCalendar? {
        try await wait { self.defaultCalendar(completion: $0) }
    }

    public nonisolated(nonsending) func events(from start: Int64, to end: Int64, in calendars: [EventCalendar] = []) async throws(EventStoreError) -> [Event] {
        try await wait { self.events(from: start, to: end, in: calendars, completion: $0) }
    }

    public nonisolated(nonsending) func event(withID identifier: String) async throws(EventStoreError) -> Event? {
        try await wait { self.event(withID: identifier, completion: $0) }
    }

    @discardableResult
    public nonisolated(nonsending) func save(_ event: Event, span: EventSpan = .thisEvent) async throws(EventStoreError) -> Event {
        try await wait { self.save(event, span: span, completion: $0) }
    }

    public nonisolated(nonsending) func remove(_ event: Event, span: EventSpan = .thisEvent) async throws(EventStoreError) {
        try await wait { self.remove(event, span: span, completion: $0) }
    }

    /// One element each time the store changes. Ending the loop stops
    /// listening. It replaces an `onChange` closure, and another stream.
    public var changes: EventStream<Void, Never> {
        let (stream, continuation) = EventStream<Void, Never>.makeStream()
        listener.generation &+= 1
        let generation = listener.generation
        onChange {
            continuation.yield(())
        }
        continuation.onTermination = { [listener, calendars] in
            // Unless something else listens by now.
            guard listener.generation == generation else { return }
            listener.handler = nil
            calendars.setDelegate(nil)
        }
        return stream
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(_ start: (@escaping (Result<Value, EventStoreError>) -> Void) -> Void) async throws(EventStoreError) -> Value {
        try await withCallback { (callback: Callback<Value, EventStoreError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// The delegate the host holds.
private final class Listener: CalendarsDelegate {

    var handler: (() -> Void)?

    /// Counts listeners, so a stream that ends knows whether it's still
    /// the one listening.
    var generation = 0

    func didChange() {
        handler?()
    }
}

/// What a `CalendarCallback` was told.
private enum Outcome {

    case complete
    case access(EventStoreAccess)
    case calendars([EventCalendar])
    case calendar(EventCalendar?)
    case events([Event])
    case event(Event?)
    case failure(EventStoreError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: EventStoreError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: CalendarCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
    }

    /// For the operations that answer `didFindEvent`, where none is no
    /// error.
    static func finding(_ completion: @escaping (Result<Event?, EventStoreError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .event(let event) = outcome {
                completion(.success(event))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: Outcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didChangeAccess(_ access: Int32) {
        answer(.access(EventStoreAccess(rawValue: access) ?? .denied))
    }

    func didListCalendars(_ calendars: [any CalendarRecord]) {
        answer(.calendars(calendars.map { EventCalendar($0) }))
    }

    func didFindCalendar(_ calendar: (any CalendarRecord)?) {
        answer(.calendar(calendar.map { EventCalendar($0) }))
    }

    func didListEvents(_ events: [any CalendarEventRecord]) {
        answer(.events(events.map { Event($0) }))
    }

    func didFindEvent(_ event: (any CalendarEventRecord)?) {
        answer(.event(event.map { Event($0) }))
    }

    func didFail(_ error: Int32) {
        answer(.failure(EventStoreError(rawValue: error) ?? .unknown))
    }
}
