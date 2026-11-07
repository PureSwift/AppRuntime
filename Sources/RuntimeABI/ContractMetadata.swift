/// Binary encoding of `rt.contracts` section records (§10).
///
/// A section holds one record per contract, concatenated. The linker may pad
/// between records from different object files, so zero bytes between
/// records are skipped. All integers are little-endian.
///
/// ```
/// record := 'R' 'T' 'C' format:u8 kind:u8 version:u32
///           name:str capability:str count:u16 method*
/// method := kind:u8 key:str signature:str
/// str    := length:u16 utf8-bytes          (empty capability = none)
/// ```
public enum ContractMetadata {

    /// Record format version.
    public static let formatVersion: UInt8 = 1

    static let magic: [UInt8] = [0x52, 0x54, 0x43] // "RTC"

    /// Encodes one contract record.
    public static func encode(_ descriptor: ContractDescriptor) -> [UInt8] {
        var bytes = magic
        bytes.append(formatVersion)
        bytes.append(descriptor.kind.rawValue)
        append(descriptor.version, to: &bytes)
        append(descriptor.name.utf8, to: &bytes)
        append((descriptor.capability?.rawValue ?? "").utf8, to: &bytes)
        append(UInt16(truncatingIfNeeded: descriptor.methods.count), to: &bytes)
        for method in descriptor.methods {
            bytes.append(UInt8(truncatingIfNeeded: method.kind.rawValue))
            append(method.key.utf8, to: &bytes)
            append(method.signature.utf8, to: &bytes)
        }
        return bytes
    }

    /// Decodes every record in a section. Returns `nil` if any record is
    /// malformed or uses an unknown format version.
    public static func decode<C: Collection>(_ section: C) -> [ContractDescriptor]? where C.Element == UInt8 {
        var reader = Reader(bytes: Array(section))
        var descriptors = [ContractDescriptor]()
        while true {
            reader.skipZeros()
            if reader.isAtEnd { return descriptors }
            guard let descriptor = reader.readRecord() else { return nil }
            descriptors.append(descriptor)
        }
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func append<C: Collection>(_ string: C, to bytes: inout [UInt8]) where C.Element == UInt8 {
        append(UInt16(truncatingIfNeeded: string.count), to: &bytes)
        bytes.append(contentsOf: string)
    }
}

private struct Reader {

    let bytes: [UInt8]

    var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        offset >= bytes.count
    }

    mutating func skipZeros() {
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }
    }

    mutating func readByte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard let low = readByte(), let high = readByte() else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    mutating func readUInt32() -> UInt32? {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            guard let byte = readByte() else { return nil }
            value |= UInt32(byte) << UInt32(shift)
        }
        return value
    }

    mutating func readString() -> String? {
        guard let length = readUInt16() else { return nil }
        let end = offset + Int(length)
        guard end <= bytes.count else { return nil }
        defer { offset = end }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    mutating func readRecord() -> ContractDescriptor? {
        for expected in ContractMetadata.magic {
            guard readByte() == expected else { return nil }
        }
        guard readByte() == ContractMetadata.formatVersion,
              let kindByte = readByte(),
              let kind = ContractKind(rawValue: kindByte),
              let version = readUInt32(),
              let name = readString(),
              let capability = readString(),
              let count = readUInt16() else {
            return nil
        }
        var methods = [MethodDescriptor]()
        methods.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let kindByte = readByte(),
                  let methodKind = MethodKind(rawValue: UInt32(kindByte)),
                  let key = readString(),
                  let signatureString = readString(),
                  let signature = Signature(signatureString) else {
                return nil
            }
            methods.append(MethodDescriptor(key: key, signature: signature, kind: methodKind))
        }
        return ContractDescriptor(
            name: name,
            kind: kind,
            version: version,
            capability: capability.isEmpty ? nil : Capability(capability),
            methods: methods
        )
    }
}
