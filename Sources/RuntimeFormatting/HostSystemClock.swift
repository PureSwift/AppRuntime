import DynamicFormatting
import Foundation

/// The `SystemClockInfo` contract: the system's clock, and word of the
/// user's settings for dates changing.
///
/// On Apple platforms it listens for Foundation's notifications. On every
/// platform it keeps a timer for the next midnight in the user's zone. A
/// platform tells it what Foundation doesn't report with `changed(_:)`,
/// and when the app returns from the background with
/// `applicationWillEnterForeground()`.
///
/// Main thread only, like the contracts.
public final class HostSystemClock: SystemClockInfo {

    // MARK: Settings

    /// What the time is. Replaceable, for tests.
    nonisolated(unsafe) public static var clock: () -> Date = { Date() }

    /// The user's time zone. Replaceable, for tests and for a host that
    /// keeps its own.
    nonisolated(unsafe) public static var userTimeZone: () -> TimeZone = { .autoupdatingCurrent }

    /// Runs `body` on the main thread once `seconds` of the system's
    /// clock have passed. Replaceable, for tests.
    nonisolated(unsafe) public static var schedule: (_ seconds: TimeInterval, _ body: @escaping () -> Void) -> Void = defaultSchedule

    private static func defaultSchedule(_ seconds: TimeInterval, _ body: @escaping () -> Void) {
        // The body runs where it was made: on the main thread.
        nonisolated(unsafe) let body = body
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds) { body() }
    }

    /// Back to the system's clock and zone, with no delegate.
    public static func reset() {
        clock = { Date() }
        userTimeZone = { .autoupdatingCurrent }
        schedule = defaultSchedule
        delegate = nil
        reported = nil
        generation += 1
        FormatterCache.removeAll()
    }

    // MARK: The contract

    public static func now() -> Double {
        clock().timeIntervalSince1970
    }

    public static func setDelegate(_ delegate: SystemClockDelegate?) {
        self.delegate = delegate
        generation += 1
        guard delegate != nil else {
            reported = nil
            return
        }
        observeNotifications()
        reported = current()
        scheduleMidnight()
    }

    // MARK: For a platform

    /// What the platform saw change. `.day` is sent on only if a new day
    /// has begun since the last one reported; `.locale` and `.timeZone`
    /// are taken at the platform's word.
    public static func changed(_ changes: SystemClockChange) {
        if !changes.intersection([.locale, .timeZone]).isEmpty {
            FormatterCache.removeAll()
        }
        guard let last = reported else { return }
        let now = current()
        reported = now
        var changes = changes.intersection(.all)
        // A new zone or a set clock can begin a new day too.
        if now.day != last.day {
            changes.insert(.day)
        } else {
            changes.remove(.day)
        }
        if changes.contains(.clock) || changes.contains(.timeZone) || changes.contains(.day) {
            scheduleMidnight()
        }
        send(changes)
    }

    /// Reports what changed while the app couldn't be told: the zone, the
    /// locale and the day, each compared with what was last reported.
    public static func applicationWillEnterForeground() {
        guard let last = reported else { return }
        let now = current()
        var changes: SystemClockChange = []
        if now.timeZone != last.timeZone { changes.insert(.timeZone) }
        if now.locale != last.locale { changes.insert(.locale) }
        if now.day != last.day { changes.insert(.day) }
        guard !changes.isEmpty else {
            scheduleMidnight()
            return
        }
        changed(changes)
    }

    // MARK: State

    /// What the guest was last told, or what was so when it began to
    /// listen.
    struct Reported: Equatable {
        var timeZone: String
        var locale: String
        /// Days since 1970 in the user's zone.
        var day: Int
    }

    nonisolated(unsafe) static var delegate: (any SystemClockDelegate)?

    nonisolated(unsafe) static var reported: Reported?

    /// Timers from before this are stale.
    nonisolated(unsafe) private static var generation = 0

    static func current() -> Reported {
        let zone = userTimeZone()
        let date = clock()
        let local = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        return Reported(
            timeZone: zone.identifier,
            locale: LocaleIdentifiers.bcp47(LocaleIdentifiers.user),
            day: Int((local / 86_400).rounded(.down))
        )
    }

    /// When the next day begins in the user's zone, as the user's
    /// calendar has it.
    static func nextMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = userTimeZone()
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    private static func scheduleMidnight() {
        generation += 1
        let scheduled = generation
        let now = clock()
        // A second late, so the day has surely begun.
        let wait = max(nextMidnight(after: now).timeIntervalSince(now), 0) + 1
        schedule(wait) {
            guard scheduled == generation, delegate != nil else { return }
            // Sends `.day` if one began, and schedules the next.
            changed(.day)
            if scheduled == generation {
                scheduleMidnight()
            }
        }
    }

    private static func send(_ changes: SystemClockChange) {
        guard !changes.isEmpty else { return }
        delegate?.didChange(changes.rawValue)
    }

    // MARK: Foundation's notifications

    #if canImport(Darwin)
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
    #endif

    private static func observeNotifications() {
        #if canImport(Darwin)
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [(Notification.Name, SystemClockChange)] = [
            (NSLocale.currentLocaleDidChangeNotification, .locale),
            (.NSSystemTimeZoneDidChange, .timeZone),
            (.NSSystemClockDidChange, .clock),
            (.NSCalendarDayChanged, .day),
        ]
        for (name, change) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                HostSystemClock.changed(change)
            })
        }
        #endif
    }
}
