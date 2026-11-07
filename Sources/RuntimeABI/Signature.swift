/// A parsed wire signature, for example `(JO)V`.
public struct Signature: Equatable, Hashable, Sendable {

    /// Argument types, in order. Never contains `.void`.
    public let arguments: [WireType]

    /// Return type. `.void` for no result.
    public let result: WireType

    public init(arguments: [WireType], result: WireType) {
        precondition(!arguments.contains(.void), "void is not a valid argument type")
        self.arguments = arguments
        self.result = result
    }
}

public extension Signature {

    /// Parse a signature from its UTF-8 bytes. Returns `nil` if malformed.
    init?<C: Collection>(utf8 bytes: C) where C.Element == UInt8 {
        var iterator = bytes.makeIterator()
        guard iterator.next() == 0x28 else { return nil } // '('
        var arguments = [WireType]()
        while true {
            guard let byte = iterator.next() else { return nil }
            if byte == 0x29 { break } // ')'
            guard let type = WireType(rawValue: byte), type.isArgument else { return nil }
            arguments.append(type)
        }
        guard let resultByte = iterator.next(),
              let result = WireType(rawValue: resultByte),
              iterator.next() == nil else {
            return nil
        }
        self.init(arguments: arguments, result: result)
    }

    /// Parse a signature string. Returns `nil` if malformed.
    init?(_ string: String) {
        self.init(utf8: string.utf8)
    }

    /// The UTF-8 encoding of the signature.
    var utf8: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(arguments.count + 3)
        bytes.append(0x28)
        for argument in arguments {
            bytes.append(argument.rawValue)
        }
        bytes.append(0x29)
        bytes.append(result.rawValue)
        return bytes
    }

    /// Number of result slots.
    var resultSlotCount: Int {
        result.resultSlotCount
    }
}

extension Signature: CustomStringConvertible {

    public var description: String {
        String(decoding: utf8, as: UTF8.self)
    }
}
