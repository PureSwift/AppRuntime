/// The binary encoding of render trees, node IDs and event payloads (§9.2).
///
/// Version 1, little-endian:
///
/// ```text
/// tree      := 0x52 0x4E ("RN"), version u8 = 1, strings, node
/// strings   := varint count, (varint length, UTF-8 bytes)*
/// node      := varint type, u64 id, props, modifiers, children, varint lazy
/// props     := varint count, (varint key, value)*          keys sorted
/// value     := u8 tag, then
///                0 string: varint string index
///                1 double: f64
///                2 bool:   u8 0 or 1
///                3 int:    zigzag varint
///                4 array:  varint count, value*
/// modifiers := varint count, (varint kind, props)*
/// children  := varint count, node*
/// lazy      := 0 for an eager node, rows + 1 for a lazy container
/// payload   := strings, value                               (event payloads)
/// node ID   := u64                                          (8 bytes)
/// ```
///
/// Every string (types, keys, kinds and string values) is stored once, in the
/// table. Props are sorted by key, so equal trees encode to equal bytes.
public enum RenderCodec {

    public static let version: UInt8 = 1

    static let magic: [UInt8] = [0x52, 0x4E]

    // MARK: Encoding

    public static func encode(_ tree: RenderNode) -> [UInt8] {
        var writer = Writer()
        writer.collect(tree)
        var bytes = magic
        bytes.append(version)
        writer.appendStrings(to: &bytes)
        writer.append(tree, to: &bytes)
        return bytes
    }

    public static func encode(payload: PropValue) -> [UInt8] {
        var writer = Writer()
        writer.collect(payload)
        var bytes: [UInt8] = []
        writer.appendStrings(to: &bytes)
        writer.append(payload, to: &bytes)
        return bytes
    }

    public static func encode(id: RenderNode.ID) -> [UInt8] {
        var bytes: [UInt8] = []
        appendFixed(id, to: &bytes)
        return bytes
    }

    // MARK: Decoding

    public static func decode(_ bytes: [UInt8]) throws(RenderDecodingError) -> RenderNode {
        var reader = Reader(bytes)
        guard try reader.byte() == magic[0], try reader.byte() == magic[1] else {
            throw .notARenderTree
        }
        let found = try reader.byte()
        guard found == version else {
            throw .unsupportedVersion(found)
        }
        try reader.readStrings()
        let node = try reader.node()
        try reader.finish()
        return node
    }

    public static func decode(payload bytes: [UInt8]) throws(RenderDecodingError) -> PropValue {
        var reader = Reader(bytes)
        try reader.readStrings()
        let value = try reader.value()
        try reader.finish()
        return value
    }

    public static func decode(id bytes: [UInt8]) throws(RenderDecodingError) -> RenderNode.ID {
        var reader = Reader(bytes)
        let id = try reader.fixed()
        try reader.finish()
        return id
    }

    // MARK: Primitives

    static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    static func appendFixed(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    // MARK: Writer

    struct Writer {

        private var indices: [String: Int] = [:]

        private var strings: [String] = []

        mutating func collect(_ node: RenderNode) {
            intern(node.type)
            collect(node.props)
            for modifier in node.modifiers {
                intern(modifier.kind)
                collect(modifier.args)
            }
            for child in node.children {
                collect(child)
            }
        }

        /// In key order, like `append`, so the table's order (and the bytes)
        /// don't depend on dictionary iteration order.
        mutating func collect(_ props: [String: PropValue]) {
            for key in props.keys.sorted() {
                intern(key)
                collect(props[key]!)
            }
        }

        mutating func collect(_ value: PropValue) {
            switch value {
            case .string(let string):
                intern(string)
            case .array(let values):
                for value in values {
                    collect(value)
                }
            case .double, .bool, .int:
                break
            }
        }

        private mutating func intern(_ string: String) {
            if indices[string] == nil {
                indices[string] = strings.count
                strings.append(string)
            }
        }

        private func index(_ string: String) -> UInt64 {
            UInt64(indices[string] ?? 0)
        }

        func appendStrings(to bytes: inout [UInt8]) {
            RenderCodec.appendVarint(UInt64(strings.count), to: &bytes)
            for string in strings {
                RenderCodec.appendVarint(UInt64(string.utf8.count), to: &bytes)
                bytes.append(contentsOf: string.utf8)
            }
        }

        func append(_ node: RenderNode, to bytes: inout [UInt8]) {
            RenderCodec.appendVarint(index(node.type), to: &bytes)
            RenderCodec.appendFixed(node.id, to: &bytes)
            append(node.props, to: &bytes)
            RenderCodec.appendVarint(UInt64(node.modifiers.count), to: &bytes)
            for modifier in node.modifiers {
                RenderCodec.appendVarint(index(modifier.kind), to: &bytes)
                append(modifier.args, to: &bytes)
            }
            RenderCodec.appendVarint(UInt64(node.children.count), to: &bytes)
            for child in node.children {
                append(child, to: &bytes)
            }
            RenderCodec.appendVarint(node.count.map { UInt64($0) + 1 } ?? 0, to: &bytes)
        }

        func append(_ props: [String: PropValue], to bytes: inout [UInt8]) {
            RenderCodec.appendVarint(UInt64(props.count), to: &bytes)
            for key in props.keys.sorted() {
                RenderCodec.appendVarint(index(key), to: &bytes)
                append(props[key]!, to: &bytes)
            }
        }

        func append(_ value: PropValue, to bytes: inout [UInt8]) {
            switch value {
            case .string(let string):
                bytes.append(0)
                RenderCodec.appendVarint(index(string), to: &bytes)
            case .double(let double):
                bytes.append(1)
                RenderCodec.appendFixed(double.bitPattern, to: &bytes)
            case .bool(let bool):
                bytes.append(2)
                bytes.append(bool ? 1 : 0)
            case .int(let int):
                bytes.append(3)
                let zigzag = UInt64(bitPattern: (Int64(int) << 1) ^ (Int64(int) >> 63))
                RenderCodec.appendVarint(zigzag, to: &bytes)
            case .array(let values):
                bytes.append(4)
                RenderCodec.appendVarint(UInt64(values.count), to: &bytes)
                for value in values {
                    append(value, to: &bytes)
                }
            }
        }
    }

    // MARK: Reader

    struct Reader {

        private let bytes: [UInt8]

        private var position = 0

        private var strings: [String] = []

        /// Guards against deeply nested input.
        private var depth = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func byte() throws(RenderDecodingError) -> UInt8 {
            guard position < bytes.count else { throw .truncated }
            let byte = bytes[position]
            position += 1
            return byte
        }

        mutating func varint() throws(RenderDecodingError) -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try byte()
                guard shift < 64 else { throw .malformed }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        mutating func count() throws(RenderDecodingError) -> Int {
            let value = try varint()
            // Every element takes at least one byte.
            guard value <= UInt64(bytes.count - position) else { throw .truncated }
            return Int(value)
        }

        mutating func fixed() throws(RenderDecodingError) -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 8) {
                value |= UInt64(try byte()) << UInt64(shift)
            }
            return value
        }

        mutating func readStrings() throws(RenderDecodingError) {
            let count = try count()
            strings.reserveCapacity(count)
            for _ in 0..<count {
                let length = try self.count()
                let utf8 = bytes[position..<(position + length)]
                position += length
                strings.append(String(decoding: utf8, as: UTF8.self))
            }
        }

        mutating func string() throws(RenderDecodingError) -> String {
            let index = try varint()
            guard index < UInt64(strings.count) else { throw .malformed }
            return strings[Int(index)]
        }

        mutating func node() throws(RenderDecodingError) -> RenderNode {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 512 else { throw .malformed }
            let type = try string()
            let id = try fixed()
            let props = try self.props()
            var modifiers: [ModifierNode] = []
            for _ in 0..<(try count()) {
                let kind = try string()
                modifiers.append(ModifierNode(kind, try self.props()))
            }
            var children: [RenderNode] = []
            for _ in 0..<(try count()) {
                children.append(try node())
            }
            let lazy = try varint()
            return RenderNode(type, id: id, props: props, modifiers: modifiers, children: children,
                              count: lazy == 0 ? nil : Int(lazy - 1))
        }

        mutating func props() throws(RenderDecodingError) -> [String: PropValue] {
            var props: [String: PropValue] = [:]
            for _ in 0..<(try count()) {
                let key = try string()
                props[key] = try value()
            }
            return props
        }

        mutating func value() throws(RenderDecodingError) -> PropValue {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 512 else { throw .malformed }
            switch try byte() {
            case 0:
                return .string(try string())
            case 1:
                return .double(Double(bitPattern: try fixed()))
            case 2:
                return .bool(try byte() != 0)
            case 3:
                let zigzag = try varint()
                return .int(Int(Int64(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))))
            case 4:
                var values: [PropValue] = []
                for _ in 0..<(try count()) {
                    values.append(try value())
                }
                return .array(values)
            default:
                throw .malformed
            }
        }

        func finish() throws(RenderDecodingError) {
            guard position == bytes.count else { throw .malformed }
        }
    }
}

public enum RenderDecodingError: Error, Equatable, Sendable {
    case notARenderTree
    case unsupportedVersion(UInt8)
    case truncated
    case malformed
}
