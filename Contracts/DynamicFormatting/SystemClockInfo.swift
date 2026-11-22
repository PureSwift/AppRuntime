import DynamicRuntime

/// The system's clock, and word of the user's settings for dates changing
/// (`Documentation/Contracts/Formatting.md`).
///
/// The built-in `Clock` counts from an arbitrary start and never goes
/// back. This one says what the time is, and can be set.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | the system clock, and Foundation's notifications |
/// | Android | `System.currentTimeMillis`, and the time and locale broadcasts |
/// | Linux | `clock_gettime`, `timedated` |
/// | Browser | `Date.now()` |
@DynamicRuntime("org.pureswift.formatting.SystemClock")
public protocol SystemClockInfo: AnyObject {

    /// Seconds since 1970 UTC.
    static func now() -> Double

    /// Told when the settings or the clock change. One delegate at a time;
    /// nil stops it.
    static func setDelegate(_ delegate: SystemClockDelegate?)
}

/// What changed. The host calls it on the main thread.
@DynamicCallback("org.pureswift.formatting.SystemClockDelegate")
public protocol SystemClockDelegate: AnyObject {

    /// `SystemClockChange` bits.
    func didChange(_ changes: Int32)
}

/// What `SystemClockDelegate.didChange` carries.
public struct SystemClockChange: OptionSet, Hashable, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// The user's region, language or calendar.
    public static let locale = SystemClockChange(rawValue: 1)

    /// The user's time zone.
    public static let timeZone = SystemClockChange(rawValue: 2)

    /// The clock was set, by the user or by the network.
    public static let clock = SystemClockChange(rawValue: 4)

    /// A new day began in the user's time zone.
    public static let day = SystemClockChange(rawValue: 8)

    /// Every change a host can report.
    public static let all: SystemClockChange = [.locale, .timeZone, .clock, .day]
}
