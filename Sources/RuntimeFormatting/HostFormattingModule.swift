import DynamicFormatting
import DynamicRuntime
import RuntimeHost

/// The formatting contracts (`DynamicFormatting`) over Swift Foundation,
/// for any host written in Swift: `HostLocaleInfo`, `HostNumberFormat`,
/// `HostDateFormat`, `HostSystemClock`, `HostTimeZoneInfo`,
/// `HostCalendarInfo` and `HostCollator`.
///
/// ```swift
/// HostFormattingModule.register(in: runtime)
/// ```
///
/// Foundation formats with ICU on every platform, so guests don't link it.
/// Formatters are cached by configuration, and the contracts are the main
/// thread's. The contracts need no capability.
public enum HostFormattingModule: HostModule {

    /// Told what a guest asked for that the contracts don't know, such as
    /// an unknown style or time zone, and what was used instead. Nil, the
    /// default, drops it. Set it before the guest runs; it's called on the
    /// main thread.
    ///
    /// ```swift
    /// HostFormattingModule.log = { logger.error("\($0, privacy: .public)") }
    /// ```
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    public static var contracts: [ContractDescriptor] {
        [
            LocaleInfoProxy.descriptor,
            NumberFormatProxy.descriptor,
            DateFormatProxy.descriptor,
            SystemClockInfoProxy.descriptor,
            SystemClockDelegateProxy.descriptor,
            TimeZoneInfoProxy.descriptor,
            CalendarInfoProxy.descriptor,
            CollatorProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocaleInfoProxy.register(HostLocaleInfo.self, in: registrar)
        NumberFormatProxy.register(HostNumberFormat.self, in: registrar)
        DateFormatProxy.register(HostDateFormat.self, in: registrar)
        SystemClockInfoProxy.register(HostSystemClock.self, in: registrar)
        SystemClockDelegateProxy.registerInterface(in: registrar)
        TimeZoneInfoProxy.register(HostTimeZoneInfo.self, in: registrar)
        CalendarInfoProxy.register(HostCalendarInfo.self, in: registrar)
        CollatorProxy.register(HostCollator.self, in: registrar)
    }
}
