import DynamicFormatting
import DynamicRuntime
import Foundation
import RuntimeNative
import Testing
@testable import RuntimeFormatting

/// Records what a module registers.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [ContractDescriptor] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        registered.append(descriptor)
    }
}

/// 2024-03-04 17:06:07.250 UTC.
let sample: Int64 = 1_709_571_967_250

/// The formatting contracts over Swift Foundation, on macOS and Linux.
///
/// Serialized: the tests share `FormatterCache`, the environment the user's
/// locale comes from, and the native runtime.
@Suite(.serialized) struct RuntimeFormattingTests {

    // MARK: Module

    @Test func registersEveryContract() {
        let registrar = RecordingRegistrar()
        HostFormattingModule.register(in: registrar)
        #expect(registrar.registered.map(\.name) == HostFormattingModule.contracts.map(\.name))
        #expect(Set(HostFormattingModule.contracts.map(\.name)) == [
            LocaleInfoProxy.descriptor.name, NumberFormatProxy.descriptor.name, DateFormatProxy.descriptor.name,
        ])
        #expect(HostFormattingModule.permissionProviders().isEmpty)
    }

    @Test func logsWhatItReplaces() {
        var messages: [String] = []
        HostFormattingModule.log = { messages.append($0) }
        defer { HostFormattingModule.log = nil }

        _ = HostNumberFormat.make(locale: "en-US", style: 99)
        let date = HostDateFormat.make(locale: "en-US", timeZone: "Mars/Olympus")
        date.setDateStyle(42)
        date.setTimeStyle(-1)
        #expect(messages == [
            "NumberFormat.make: unknown style 99; using decimal",
            "DateFormat.make: unknown time zone Mars/Olympus; using the user's",
            "DateFormat.setDateStyle: unknown style 42; ignored",
            "DateFormat.setTimeStyle: unknown style -1; ignored",
        ])

        // Known values log nothing.
        messages.removeAll()
        _ = HostNumberFormat.make(locale: "en-US", style: NumberStyle.percent.rawValue)
        HostDateFormat.make(locale: "en-US", timeZone: "UTC").setDateStyle(DateStyle.short.rawValue)
        #expect(messages.isEmpty)
    }

    /// As a guest calls them: through the proxies and the runtime.
    @Test func throughTheContracts() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostFormattingModule.register(in: native)

        let number = NumberFormatProxy.make(locale: "de-DE", style: NumberStyle.decimal.rawValue)
        number.setMaximumFractionDigits(1)
        #expect(number.format(1234.56) == "1.234,6")
        #expect(number.parse("1.234,5") == 1234.5)

        let date = DateFormatProxy.make(locale: "en_US_POSIX", timeZone: "UTC")
        date.setPattern("yyyy-MM-dd HH:mm")
        #expect(date.format(sample) == "2024-03-04 17:06")
        #expect(date.parse("nope") == .min)

        let locale = try #require(LocaleInfoProxy.make(identifier: "fr-FR"))
        #expect(locale.identifier() == "fr-FR")
        #expect(locale.currencyCode() == "EUR")
        #expect(LocaleInfoProxy.make(identifier: "zz") == nil)
    }

    // MARK: Locale

    @Test func locale() throws {
        let german = try #require(HostLocaleInfo.make(identifier: "de-DE"))
        #expect(german.identifier() == "de-DE")
        #expect(german.languageCode() == "de")
        #expect(german.regionCode() == "DE")
        #expect(german.decimalSeparator() == ",")
        #expect(german.groupingSeparator() == ".")
        #expect(german.currencyCode() == "EUR")
        #expect(german.uses24HourClock())

        let american = try #require(HostLocaleInfo.make(identifier: "en_US"))
        #expect(american.identifier() == "en-US", "BCP 47, not Foundation's underscore form")
        #expect(american.currencyCode() == "USD")
        #expect(!american.uses24HourClock())

        let english = try #require(HostLocaleInfo.make(identifier: "en"))
        #expect(english.regionCode() == nil)
        #expect(HostLocaleInfo.make(identifier: "es-419")?.regionCode() == "419")
    }

    @Test(arguments: ["", "zz", "xx-YY", "en-QQ", "!!"])
    func unknownLocale(_ identifier: String) {
        #expect(HostLocaleInfo.make(identifier: identifier) == nil)
    }

    @Test func currentLocale() {
        let current = HostLocaleInfo.current()
        #expect(!current.identifier().contains("_"))
        #expect(current.timeZoneIdentifier() == TimeZone.current.identifier)
        let now = Date()
        let offset = current.timeZoneOffset(Int64(now.timeIntervalSince1970 * 1000))
        #expect(Int(offset) == TimeZone.current.secondsFromGMT(for: now))
        #expect(!HostLocaleInfo.preferredLanguages().isEmpty)
    }

    /// Outside Apple platforms Foundation doesn't read the POSIX
    /// environment, so the host does.
    @Test func theEnvironmentsLocale() {
        #expect(LocaleIdentifiers.posixLocale(["LANG": "de_DE.UTF-8"]) == "de_DE")
        #expect(LocaleIdentifiers.posixLocale(["LANG": "de_DE.UTF-8@euro", "LC_ALL": "fr_CA.UTF-8"]) == "fr_CA")
        #expect(LocaleIdentifiers.posixLocale(["LANG": "sr_RS@latin"]) == "sr_RS")
        #expect(LocaleIdentifiers.posixLocale(["LC_ALL": "", "LANG": "pt_BR"]) == "pt_BR")
        #expect(LocaleIdentifiers.posixLocale(["LANG": "C.UTF-8"]) == nil)
        #expect(LocaleIdentifiers.posixLocale(["LANG": "POSIX"]) == nil)
        #expect(LocaleIdentifiers.posixLocale([:]) == nil)

        #if !canImport(Darwin)
        let saved = HostLocaleInfo.environment
        defer {
            HostLocaleInfo.environment = saved
            FormatterCache.removeAll()
        }
        // Formatters for the user's locale were made for the old one.
        FormatterCache.removeAll()
        HostLocaleInfo.environment = ["LANG": "de_DE.UTF-8", "LANGUAGE": "de_CH:de:en"]
        #expect(HostLocaleInfo.current().identifier() == "de-DE")
        #expect(HostLocaleInfo.current().decimalSeparator() == ",")
        #expect(HostLocaleInfo.preferredLanguages() == ["de-CH", "de", "en"])
        #expect(HostNumberFormat.make(locale: nil, style: NumberStyle.decimal.rawValue).format(1234.5) == "1.234,5")
        // GNU ignores LANGUAGE under the C locale.
        HostLocaleInfo.environment = ["LANG": "C", "LANGUAGE": "de"]
        #expect(HostLocaleInfo.preferredLanguages() != ["de"])
        HostLocaleInfo.environment = ["LANG": "ja_JP.UTF-8"]
        #expect(HostLocaleInfo.preferredLanguages() == ["ja-JP"])
        #endif
    }

    @Test func hourPatterns() {
        #expect(HourFormat.uses24Hours("HH 'Uhr'"))
        #expect(HourFormat.uses24Hours("k"))
        #expect(!HourFormat.uses24Hours("h a"))
        #expect(!HourFormat.uses24Hours("h 'Hours' a"), "quoted literals don't count")
    }

    // MARK: Numbers

    @Test func decimal() {
        let posix = HostNumberFormat.make(locale: "en_US_POSIX", style: NumberStyle.decimal.rawValue)
        #expect(posix.format(1234.5) == "1234.5")
        #expect(posix.formatInteger(1_234_567) == "1234567", "ungrouped on every platform")
        posix.setUsesGrouping(true)
        #expect(posix.format(1234.5) == "1,234.5")

        let english = HostNumberFormat.make(locale: "en-US", style: NumberStyle.decimal.rawValue)
        #expect(english.format(1234.5678) == "1,234.568")
        #expect(english.formatInteger(9_007_199_254_740_993) == "9,007,199,254,740,993", "exact past 2^53")
        #expect(english.formatInteger(.min) == "-9,223,372,036,854,775,808")
        english.setUsesGrouping(false)
        english.setMaximumFractionDigits(1)
        #expect(english.format(1234.56) == "1234.6")
        #expect(english.formatInteger(1234) == "1234")
        english.setMinimumFractionDigits(3)
        #expect(english.format(2) == "2.000", "a larger minimum raises the maximum")
        #expect(english.formatInteger(2) == "2.000")

        let german = HostNumberFormat.make(locale: "de-DE", style: NumberStyle.decimal.rawValue)
        #expect(german.format(1234.5) == "1.234,5")
        #expect(german.formatInteger(1234) == "1.234")
        #expect(german.parse("1.234,5") == 1234.5)
        #expect(german.parse("abc").isNaN)
    }

    @Test func numberStyles() {
        let percent = HostNumberFormat.make(locale: "en-US", style: NumberStyle.percent.rawValue)
        #expect(percent.format(0.25) == "25%")
        #expect(percent.parse("25%") == 0.25)

        let currency = HostNumberFormat.make(locale: "en-US", style: NumberStyle.currency.rawValue)
        #expect(currency.format(3.5) == "$3.50")
        #expect(currency.formatInteger(3) == "$3.00")
        currency.setCurrencyCode("EUR")
        #expect(currency.format(3.5) == "€3.50")
        currency.setCurrencyCode(nil)
        #expect(currency.format(3.5) == "$3.50")

        let spellOut = HostNumberFormat.make(locale: "en-US", style: NumberStyle.spellOut.rawValue)
        #expect(spellOut.formatInteger(42) == "forty-two")
        #expect(spellOut.parse("forty-two") == 42)

        let ordinal = HostNumberFormat.make(locale: "en-US", style: NumberStyle.ordinal.rawValue)
        #expect(ordinal.formatInteger(3) == "3rd")

        let scientific = HostNumberFormat.make(locale: "en-US", style: NumberStyle.scientific.rawValue)
        #expect(scientific.format(12345) == "1.2345E4")

        let compact = HostNumberFormat.make(locale: "en-US", style: NumberStyle.compact.rawValue)
        #expect(compact.format(1_200) == "1.2K")
        #expect(compact.formatInteger(3_000_000) == "3M")
        #expect(compact.parse("1,200") == 1200, "parses like decimal")

        let unknown = HostNumberFormat.make(locale: "en-US", style: 99)
        #expect(unknown.settings.style == .decimal)
    }

    @Test func numberFormattersAreShared() {
        FormatterCache.removeAll()
        let first = HostNumberFormat.make(locale: "fr-FR", style: NumberStyle.decimal.rawValue)
        let second = HostNumberFormat.make(locale: "fr-FR", style: NumberStyle.decimal.rawValue)
        #expect(first.formatter === second.formatter)
        #expect(FormatterCache.count == 1)

        second.setMaximumFractionDigits(0)
        #expect(first.formatter !== second.formatter, "a changed object gets its own formatter")
        #expect(first.format(1.5) == "1,5", "the shared one is unchanged")
        #expect(second.format(1.4) == "1")
        #expect(HostNumberFormat.make(locale: "fr-FR", style: NumberStyle.percent.rawValue).formatter !== first.formatter)
    }

    // MARK: Dates

    @Test func pattern() {
        let format = HostDateFormat.make(locale: "en_US_POSIX", timeZone: "UTC")
        format.setPattern("yyyy-MM-dd'T'HH:mm:ss.SSS")
        #expect(format.format(sample) == "2024-03-04T17:06:07.250")
        #expect(format.parse("2024-03-04T17:06:07.250") == sample)
        #expect(format.parse("March 4") == .min)

        let berlin = HostDateFormat.make(locale: "en_US_POSIX", timeZone: "Europe/Berlin")
        berlin.setPattern("HH:mm")
        #expect(berlin.format(sample) == "18:06")
    }

    @Test func dateStyles() {
        let format = HostDateFormat.make(locale: "en-US", timeZone: "UTC")
        format.setDateStyle(DateStyle.short.rawValue)
        format.setTimeStyle(DateStyle.none.rawValue)
        #expect(format.format(sample) == "3/4/24")

        format.setDateStyle(DateStyle.long.rawValue)
        #expect(format.format(sample) == "March 4, 2024")

        let german = HostDateFormat.make(locale: "de-DE", timeZone: "UTC")
        german.setDateStyle(DateStyle.medium.rawValue)
        german.setTimeStyle(DateStyle.short.rawValue)
        #expect(german.format(sample) == "04.03.2024, 17:06")

        // A pattern overrides the styles until it's cleared.
        german.setPattern("yyyy")
        #expect(german.format(sample) == "2024")
        german.setPattern(nil)
        #expect(german.format(sample) == "04.03.2024, 17:06")

        // Unknown styles are ignored.
        german.setTimeStyle(42)
        #expect(german.settings.timeStyle == .short)
    }

    @Test func defaultStyles() {
        let format = HostDateFormat.make(locale: "en_US_POSIX", timeZone: "UTC")
        #expect(format.settings.dateStyle == .medium)
        #expect(format.settings.timeStyle == .medium)
        #expect(!format.format(sample).isEmpty)
    }

    @Test func template() {
        let english = HostDateFormat.make(locale: "en-US", timeZone: "UTC")
        english.setTemplate("yMMMd")
        #expect(english.format(sample) == "Mar 4, 2024")

        let german = HostDateFormat.make(locale: "de-DE", timeZone: "UTC")
        german.setTemplate("yMMMd")
        #expect(german.format(sample) == "4. März 2024")
    }

    @Test func unknownTimeZone() {
        let format = HostDateFormat.make(locale: "en-US", timeZone: "Mars/Olympus")
        #expect(format.settings.timeZone == nil)
        #expect(format.formatter.timeZone == TimeZone.autoupdatingCurrent)
    }

    @Test func relative() {
        let format = HostDateFormat.make(locale: "en-US", timeZone: "UTC")
        let hour: Int64 = 3_600_000
        #expect(format.formatRelative(sample - 3 * hour, reference: sample) == "3 hours ago")
        #expect(format.formatRelative(sample + 2 * 24 * hour, reference: sample) == "in 2 days")

        let german = HostDateFormat.make(locale: "de-DE", timeZone: "UTC")
        #expect(german.formatRelative(sample - 3 * hour, reference: sample) == "vor 3 Stunden")
    }
}
