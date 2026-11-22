import DynamicFormatting
import Foundation

/// The `Collator` contract over Foundation's string comparison.
///
/// A collator holds a locale and options and never changes. One made
/// with no locale uses the user's, asked for at each call; `und` compares
/// by no language's rules.
public final class HostCollator: Collator {

    enum Language: Hashable {
        /// The user's, whatever it becomes.
        case user
        /// No language's rules.
        case none
        case fixed(String)
    }

    let language: Language

    let options: CollatorOptions

    init(language: Language, options: CollatorOptions) {
        self.language = language
        self.options = options
    }

    public static func make(locale: String?, options: Int32) -> HostCollator {
        let language: Language
        switch locale {
        case nil: language = .user
        case "und"?, ""?: language = .none
        case let identifier?: language = .fixed(identifier)
        }
        let known = CollatorOptions(rawValue: options).intersection(Self.every)
        if known.rawValue != options {
            HostFormattingModule.log?("Collator.make: unknown options \(options); using \(known.rawValue)")
        }
        return HostCollator(language: language, options: known)
    }

    static let every: CollatorOptions = [
        .caseInsensitive, .numeric, .diacriticInsensitive, .widthInsensitive, .forcedOrdering,
    ]

    var locale: Locale? {
        switch language {
        case .user: LocaleIdentifiers.user
        case .none: nil
        case .fixed(let identifier): Locale(identifier: identifier)
        }
    }

    /// The options as Foundation has them: the raw values are the same.
    var compareOptions: String.CompareOptions {
        String.CompareOptions(rawValue: UInt(options.rawValue))
    }

    /// The options that say what a search ignores. How strings are
    /// ordered doesn't matter to one.
    var searchOptions: String.CompareOptions {
        String.CompareOptions(rawValue: UInt(options.subtracting([.numeric, .forcedOrdering]).rawValue))
    }

    public func compare(_ first: String, _ second: String) -> Int32 {
        Self.compare(first, second, options: compareOptions, locale: locale)
    }

    static func compare(_ first: String, _ second: String, options: String.CompareOptions, locale: Locale?) -> Int32 {
        switch first.compare(second, options: options, range: nil, locale: locale) {
        case .orderedAscending: -1
        case .orderedSame: 0
        case .orderedDescending: 1
        }
    }

    public func order(_ strings: [String]) -> String {
        let options = compareOptions
        let locale = locale
        let order = strings.indices.sorted { first, second in
            let result = Self.compare(strings[first], strings[second], options: options, locale: locale)
            // Equal strings keep the order they came in.
            return result == 0 ? first < second : result < 0
        }
        return CollatorOptions.text(order)
    }

    public func contains(_ string: String, _ part: String) -> Bool {
        guard !part.isEmpty else { return false }
        return string.range(of: part, options: searchOptions, range: nil, locale: locale) != nil
    }

    public func fold(_ strings: [String]) -> [String] {
        let options = searchOptions
        let locale = locale
        return strings.map { $0.folding(options: options, locale: locale) }
    }
}
