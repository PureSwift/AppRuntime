/// A wire type code from the signature grammar (§3.1).
///
/// ```
/// sig  := '(' arg* ')' ret
/// arg  := 'Z' | 'I' | 'J' | 'F' | 'D' | 'O'
/// ret  := arg | 'V'
/// ```
public enum WireType: UInt8, Equatable, Hashable, Sendable, CaseIterable {

    /// `Z`: bool, stored as 0 / 1.
    case bool = 0x5A

    /// `I`: int32, sign-extended into the slot.
    case int32 = 0x49

    /// `J`: int64.
    case int64 = 0x4A

    /// `F`: float32, its bit pattern in the low 32 bits.
    case float32 = 0x46

    /// `D`: float64, its bit pattern.
    case float64 = 0x44

    /// `O`: object handle in the low 32 bits. Nullable.
    case object = 0x4F

    /// `V`: no value. Only valid as a return type.
    case void = 0x56
}

public extension WireType {

    /// The signature character for this type.
    var character: Character {
        Character(Unicode.Scalar(rawValue))
    }

    /// Whether this type can appear as an argument.
    var isArgument: Bool {
        self != .void
    }

    /// Number of result slots a method returning this type uses.
    var resultSlotCount: Int {
        self == .void ? 0 : 1
    }
}
