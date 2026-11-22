import DynamicRuntime

/// Comparing strings as a language orders them
/// (`Documentation/Contracts/Formatting.md`).
///
/// A collator is made for a locale and a set of options, and never
/// changes. An order is stable, and total for a host: two hosts may order
/// the same list differently where their rules for a language differ.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS, Linux | `String.compare(_:options:range:locale:)` |
/// | Android | `android.icu.text.Collator` |
/// | Browser | `Intl.Collator` |
@DynamicRuntime("org.pureswift.formatting.Collator")
public protocol Collator: AnyObject {

    /// `options` is a `CollatorOptions` raw value. Locale nil: the
    /// user's. `und`: no language's rules.
    static func make(locale: String?, options: Int32) -> Self

    /// -1, 0 or 1.
    func compare(_ first: String, _ second: String) -> Int32

    /// The strings' indexes in ascending order, decimal with commas
    /// between: "2,0,1". Strings that compare equal keep the order they
    /// came in.
    func order(_ strings: [String]) -> String

    /// Whether `string` has `part` in it, by the options.
    func contains(_ string: String, _ part: String) -> Bool

    /// Each string with what the options ignore taken out, for searching
    /// in the guest.
    func fold(_ strings: [String]) -> [String]
}

/// What a `Collator` ignores and how it orders. The raw values are
/// Foundation's `String.CompareOptions`.
public struct CollatorOptions: OptionSet, Hashable, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let caseInsensitive = CollatorOptions(rawValue: 1)

    /// Digits by their value: `Item 2` before `Item 10`.
    public static let numeric = CollatorOptions(rawValue: 64)

    /// `résumé` as `resume`.
    public static let diacriticInsensitive = CollatorOptions(rawValue: 128)

    /// Full-width forms as their ordinary ones.
    public static let widthInsensitive = CollatorOptions(rawValue: 256)

    /// Strings that differ at all never compare equal.
    public static let forcedOrdering = CollatorOptions(rawValue: 512)

    /// As a file manager orders names: Foundation's
    /// `localizedStandardCompare`.
    public static let standard: CollatorOptions = [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]

    /// The indexes `Collator.order` returned. What isn't a number is left
    /// out.
    public static func order(_ text: String) -> [Int] {
        text.split(separator: ",").compactMap { Int($0) }
    }

    /// Indexes as `Collator.order` returns them.
    public static func text(_ order: [Int]) -> String {
        var text = ""
        for index in order {
            if !text.isEmpty { text += "," }
            text += String(index)
        }
        return text
    }
}
