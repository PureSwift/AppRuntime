import DynamicText

/// The search behind `TextStorage.find` and `replaceAll`, the same on
/// every host: over UTF-16 units, with simple case folding and no locale's
/// rules.
public enum TextSearch {

    /// The next match from `location`: the first that starts at or after
    /// it, or going backwards, the last that ends at or before it. With
    /// `wraps` it goes on from the other end. An empty `query` matches
    /// nothing.
    public static func find(_ query: String, in units: [UInt16], options: TextSearchOptions, from location: Int) -> Range<Int>? {
        let pattern = Pattern(query, options: options)
        let count = units.count
        let length = pattern.units.count
        guard length > 0, length <= count else { return nil }
        let location = min(max(location, 0), count)
        let last = count - length
        if options.contains(.backwards) {
            var start = min(location - length, last)
            while start >= 0 {
                if pattern.matches(units, at: start) { return start ..< start + length }
                start -= 1
            }
            guard options.contains(.wraps) else { return nil }
            start = last
            while start > location - length, start >= 0 {
                if pattern.matches(units, at: start) { return start ..< start + length }
                start -= 1
            }
            return nil
        }
        var start = location
        while start <= last {
            if pattern.matches(units, at: start) { return start ..< start + length }
            start += 1
        }
        guard options.contains(.wraps) else { return nil }
        start = 0
        while start < location, start <= last {
            if pattern.matches(units, at: start) { return start ..< start + length }
            start += 1
        }
        return nil
    }

    /// Every match, from the start, none overlapping another.
    public static func matches(of query: String, in units: [UInt16], options: TextSearchOptions) -> [Range<Int>] {
        let pattern = Pattern(query, options: options)
        let length = pattern.units.count
        guard length > 0, length <= units.count else { return [] }
        var found: [Range<Int>] = []
        var start = 0
        let last = units.count - length
        while start <= last {
            if pattern.matches(units, at: start) {
                found.append(start ..< start + length)
                start += length
            } else {
                start += 1
            }
        }
        return found
    }

    private struct Pattern {

        let units: [UInt16]

        let folds: Bool

        let wholeWords: Bool

        init(_ query: String, options: TextSearchOptions) {
            folds = options.contains(.caseInsensitive)
            wholeWords = options.contains(.wholeWords)
            // A text holds `\n` only, so that's what a query's line
            // breaks mean.
            let query = TextCoding.normalizingLineBreaks(query).text
            units = folds ? query.utf16.map(TextSearch.fold) : Array(query.utf16)
        }

        func matches(_ text: [UInt16], at start: Int) -> Bool {
            for offset in units.indices {
                let unit = text[start + offset]
                if (folds ? TextSearch.fold(unit) : unit) != units[offset] {
                    return false
                }
            }
            guard wholeWords else { return true }
            let end = start + units.count
            if start > 0, TextSearch.isWord(text[start - 1]) { return false }
            if end < text.count, TextSearch.isWord(text[end]) { return false }
            return true
        }
    }

    /// A unit's lower-case form, when that's one unit too. Characters
    /// outside the Basic Multilingual Plane are compared as they are.
    static func fold(_ unit: UInt16) -> UInt16 {
        if unit < 0x80 {
            return unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit
        }
        guard let scalar = Unicode.Scalar(unit) else { return unit }
        let lowered = scalar.properties.lowercaseMapping.unicodeScalars
        guard lowered.count == 1, let first = lowered.first, first.value <= 0xFFFF else { return unit }
        return UInt16(first.value)
    }

    /// A letter, a digit or an underscore.
    static func isWord(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
        }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}

/// Where positions go when the text around them changes: the rule a
/// text's selection follows when the guest edits it.
public enum TextPositions {

    /// A position after an edit that turned `removed` units at `location`
    /// into `inserted`. Before the edit it stays; after what was replaced
    /// it moves with the text; inside, it goes to the end of the new text.
    public static func adjusting(_ position: Int, forEditAt location: Int, removed: Int, inserted: Int) -> Int {
        if position < location {
            return position
        }
        if position >= location + removed {
            return position - removed + inserted
        }
        return location + inserted
    }
}
