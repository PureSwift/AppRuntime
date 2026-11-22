import DynamicRuntime
#if canImport(DynamicObservation)
@_exported import DynamicObservation
#else
@_exported import Observation
#endif

/// The system's clock, and word of the user's settings for dates
/// changing: their region, their time zone, the clock being set, and a
/// new day.
///
/// ```swift
/// SystemClock.onChange { changes in
///     if changes.contains(.day) { reload() }
/// }
/// ```
///
/// A view needs none of this. One that reads the user's calendar, zone or
/// locale is evaluated again when they change, because reading them calls
/// `noteAccess()`.
///
/// It stands where Foundation's notifications are:
/// `NSLocale.currentLocaleDidChangeNotification`,
/// `NSSystemTimeZoneDidChange`, `NSSystemClockDidChange` and
/// `NSCalendarDayChanged`.
public enum SystemClock {

    public typealias Change = SystemClockChange

    /// What the time is: seconds since 1970 UTC. The clock can be set, so
    /// it can go backwards; measure how long something took with
    /// `RuntimeClock.now()`.
    public static var secondsSince1970: Double {
        SystemClockInfoProxy.now()
    }

    /// Called when the settings or the clock change, with what changed.
    /// One listener at a time: a new closure, or a `changes` stream,
    /// replaces it, and `nil` stops it.
    public static func onChange(_ handler: ((Change) -> Void)?) {
        settings.generation &+= 1
        settings.handler = handler
        if handler != nil {
            settings.listen()
        }
    }

    /// Notes that what's being evaluated depends on the user's settings
    /// for dates, so that it's evaluated again when they change. What
    /// reads the user's calendar, zone or locale calls it; an app has no
    /// need to.
    public static func noteAccess() {
        settings.noteAccess()
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// One element each time the settings or the clock change. Ending the
    /// loop stops it. It replaces an `onChange` closure, and another
    /// stream.
    public static var changes: EventStream<Change, Never> {
        let (stream, continuation) = EventStream<Change, Never>.makeStream()
        onChange { continuation.yield($0) }
        let generation = settings.generation
        continuation.onTermination = {
            // Unless something else listens by now.
            guard settings.generation == generation else { return }
            settings.handler = nil
        }
        return stream
    }
    #endif

    /// The one delegate the host holds, for the app's listener and for
    /// views.
    nonisolated(unsafe) static let settings = Settings()

    final class Settings: SystemClockDelegate, Observable {

        private let registrar = ObservationRegistrar()

        var handler: ((Change) -> Void)?

        /// Counts listeners, so a stream that ends knows whether it's
        /// still the one listening.
        var generation = 0

        private var isListening = false

        /// The host is told once, and holds this for as long as the app
        /// runs: a view may read the settings at any time.
        func listen() {
            guard !isListening else { return }
            isListening = true
            SystemClockInfoProxy.setDelegate(self)
        }

        func noteAccess() {
            listen()
            registrar.access(self, propertyIndex: 0)
        }

        func didChange(_ changes: Int32) {
            let changes = Change(rawValue: changes).intersection(.all)
            guard !changes.isEmpty else { return }
            registrar.withMutation(of: self, propertyIndex: 0) {}
            handler?(changes)
        }
    }
}
