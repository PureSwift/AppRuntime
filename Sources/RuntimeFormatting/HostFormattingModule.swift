import DynamicFormatting
import DynamicRuntime
import RuntimeHost

/// The formatting contracts (`DynamicFormatting`) over Swift Foundation,
/// for any host written in Swift: `HostLocaleInfo`, `HostNumberFormat` and
/// `HostDateFormat`.
///
/// ```swift
/// HostFormattingModule.register(in: runtime)
/// ```
///
/// Foundation formats with ICU on every platform, so guests don't link it.
/// Formatters are cached by configuration, and the contracts are the main
/// thread's. The contracts need no capability.
public enum HostFormattingModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            LocaleInfoProxy.descriptor,
            NumberFormatProxy.descriptor,
            DateFormatProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocaleInfoProxy.register(HostLocaleInfo.self, in: registrar)
        NumberFormatProxy.register(HostNumberFormat.self, in: registrar)
        DateFormatProxy.register(HostDateFormat.self, in: registrar)
    }
}
