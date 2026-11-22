import DynamicFormatting
import Foundation

/// The `TimeZoneInfo` contract over `TimeZone`.
///
/// An object made with no identifier is the user's zone, asked for at
/// each call (`HostSystemClock.userTimeZone`). A moment that isn't a
/// number answers as 1970.
public final class HostTimeZoneInfo: TimeZoneInfo {

    /// Nil: the user's.
    let fixed: TimeZone?

    init(_ fixed: TimeZone?) {
        self.fixed = fixed
    }

    var zone: TimeZone {
        fixed ?? HostSystemClock.userTimeZone()
    }

    public static func make(identifier: String?) -> HostTimeZoneInfo? {
        guard let identifier else {
            return HostTimeZoneInfo(nil)
        }
        return timeZone(identifier).map(HostTimeZoneInfo.init)
    }

    /// The zone for an IANA name, or `GMT`, `UTC` or `GMT+0100`; nil for
    /// anything else.
    static func timeZone(_ identifier: String) -> TimeZone? {
        guard !identifier.isEmpty else { return nil }
        return TimeZone(identifier: identifier)
    }

    public static func identifiers() -> [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    public func identifier() -> String {
        zone.identifier
    }

    public func offset(_ seconds: Double) -> Int32 {
        Int32(clamping: zone.secondsFromGMT(for: Self.date(seconds)))
    }

    public func daylightSavingOffset(_ seconds: Double) -> Int32 {
        Int32(zone.daylightSavingTimeOffset(for: Self.date(seconds)).rounded())
    }

    public func nextTransition(_ seconds: Double) -> Double {
        zone.nextDaylightSavingTimeTransition(after: Self.date(seconds))?.timeIntervalSince1970 ?? .nan
    }

    public func abbreviation(_ seconds: Double) -> String? {
        zone.abbreviation(for: Self.date(seconds))
    }

    public func name(_ style: Int32, locale: String?) -> String? {
        guard let style = TimeZoneNameStyle(rawValue: style) else {
            HostFormattingModule.log?("TimeZone.name: unknown style \(style); no name")
            return nil
        }
        return zone.localizedName(for: Self.nameStyle(style), locale: LocaleIdentifiers.locale(locale))
    }

    static func nameStyle(_ style: TimeZoneNameStyle) -> NSTimeZone.NameStyle {
        switch style {
        case .standard: .standard
        case .shortStandard: .shortStandard
        case .daylightSaving: .daylightSaving
        case .shortDaylightSaving: .shortDaylightSaving
        case .generic: .generic
        case .shortGeneric: .shortGeneric
        }
    }

    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds.isFinite ? seconds : 0)
    }
}
