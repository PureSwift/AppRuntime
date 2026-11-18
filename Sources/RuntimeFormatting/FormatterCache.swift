import Foundation

/// Foundation formatters shared by every contract object with the same
/// configuration.
///
/// Making a formatter loads ICU data and is slow; using one is fast. A key
/// holds the whole configuration, so a cached formatter is never changed
/// after it's made. The cache empties when it grows past `limit`, and on
/// Apple platforms when the user's locale or time zone changes, since
/// formatters for "the user's" settings captured the old ones.
///
/// Main thread only, like the contracts.
enum FormatterCache {

    /// Entries kept before the cache starts over.
    static let limit = 64

    nonisolated(unsafe) private static var entries: [AnyHashable: AnyObject] = [:]

    #if canImport(Darwin)
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
    #endif

    /// The cached formatter for `key`, made with `make` if there's none.
    static func formatter<Key: Hashable, Formatter: AnyObject>(
        for key: Key,
        make: () -> Formatter
    ) -> Formatter {
        observeChanges()
        if let cached = entries[AnyHashable(key)] as? Formatter {
            return cached
        }
        if entries.count >= limit {
            entries.removeAll(keepingCapacity: true)
        }
        let formatter = make()
        entries[AnyHashable(key)] = formatter
        return formatter
    }

    static var count: Int {
        entries.count
    }

    static func removeAll() {
        entries.removeAll()
    }

    /// Elsewhere the user's settings are read once, at start
    /// (`HostLocaleInfo.environment`).
    private static func observeChanges() {
        #if canImport(Darwin)
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                FormatterCache.removeAll()
            })
        }
        #endif
    }
}

/// The user's locale, and conversions between the contracts' BCP 47
/// identifiers and Foundation's.
enum LocaleIdentifiers {

    /// The locale for a BCP 47 identifier; nil is the user's.
    static func locale(_ identifier: String?) -> Locale {
        guard let identifier else {
            return user
        }
        return Locale(identifier: identifier)
    }

    /// The user's locale. On Apple platforms Foundation's, which follows
    /// the settings as they change. Elsewhere Foundation doesn't read the
    /// POSIX environment, so it's `LC_ALL` or `LANG`, read once.
    static var user: Locale {
        #if canImport(Darwin)
        return .autoupdatingCurrent
        #else
        return environmentLocale
        #endif
    }

    nonisolated(unsafe) private static var cachedEnvironmentLocale: (environment: [String: String], locale: Locale)?

    private static var environmentLocale: Locale {
        let environment = HostLocaleInfo.environment
        if let cached = cachedEnvironmentLocale, cached.environment == environment {
            return cached.locale
        }
        let locale = posixLocale(environment).map { Locale(identifier: $0) } ?? .current
        cachedEnvironmentLocale = (environment, locale)
        return locale
    }

    /// The locale a POSIX environment names, as Foundation spells it:
    /// `LC_ALL`, else `LANG`, without its encoding or modifier
    /// (`de_DE.UTF-8@euro` is `de_DE`). Nil when neither names one, and for
    /// `C` and `POSIX`, which name no language.
    static func posixLocale(_ environment: [String: String]) -> String? {
        for key in ["LC_ALL", "LANG"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            let name = value.prefix { $0 != "." && $0 != "@" }
            if name.isEmpty || name == "C" || name == "POSIX" {
                return nil
            }
            return String(name)
        }
        return nil
    }

    /// The user's languages in order, as BCP 47 identifiers: Foundation's
    /// on Apple platforms; elsewhere GNU's `LANGUAGE` list, else the
    /// user's locale's.
    static var preferredLanguages: [String] {
        #if canImport(Darwin)
        return Locale.preferredLanguages
        #else
        let listed = (HostLocaleInfo.environment["LANGUAGE"] ?? "")
            .split(separator: ":")
            .compactMap { posixLocale(["LANG": String($0)]) }
            .map { bcp47(Locale(identifier: $0)) }
        if !listed.isEmpty, posixLocale(HostLocaleInfo.environment) != nil {
            return listed
        }
        return [bcp47(user)]
        #endif
    }

    /// The BCP 47 identifier of `locale`, for example `en-US` for `en_US`.
    static func bcp47(_ locale: Locale) -> String {
        if #available(iOS 16, macOS 13, *) {
            // `autoupdatingCurrent` answers in Foundation's form; a fixed
            // copy converts.
            return Locale(identifier: locale.identifier).identifier(.bcp47)
        }
        return Locale.canonicalLanguageIdentifier(from: locale.identifier)
    }

    /// The locale for `identifier` if Foundation knows its language and
    /// region; nil for an empty or made-up identifier.
    ///
    /// `Locale(identifier:)` accepts any string, so this checks the parts
    /// against ISO 639 and ISO 3166 (or a UN M.49 area such as `419`).
    static func knownLocale(_ identifier: String) -> Locale? {
        let locale = Locale(identifier: identifier)
        guard let language = languageCode(locale), Locale.isoLanguageCodes.contains(language) else {
            return nil
        }
        if let region = regionCode(locale) {
            let isArea = region.count == 3 && region.allSatisfy(\.isASCII) && region.allSatisfy(\.isNumber)
            guard isArea || Locale.isoRegionCodes.contains(region) else {
                return nil
            }
        }
        return locale
    }

    static func languageCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.language.languageCode?.identifier
        }
        return locale.languageCode
    }

    /// The region the identifier names; nil when it names none.
    static func regionCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.region?.identifier
        }
        return locale.regionCode
    }

    static func currencyCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.currency?.identifier
        }
        return locale.currencyCode
    }
}
