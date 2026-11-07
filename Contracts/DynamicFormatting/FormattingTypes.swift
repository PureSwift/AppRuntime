/// Guest-side names for the integer codes the Formatting contracts carry.

/// `NumberFormat.make(locale:style:)`.
public enum NumberStyle: Int32, Sendable {
    case decimal = 0
    case percent = 1
    case currency = 2
    case scientific = 3
    case spellOut = 4
    case ordinal = 5
    case compact = 6
}

/// `DateFormat.setDateStyle(_:)` and `setTimeStyle(_:)`.
public enum DateStyle: Int32, Sendable {
    case none = 0
    case short = 1
    case medium = 2
    case long = 3
    case full = 4
}
