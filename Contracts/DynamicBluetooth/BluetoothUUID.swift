/// Canonical Bluetooth UUID strings.
///
/// Every contract method takes and returns UUIDs in one canonical form: the
/// full 128-bit value, uppercase, with hyphens, for example
/// `0000180D-0000-1000-8000-00805F9B34FB`. Hosts convert from their own
/// forms (CoreBluetooth reports 16-bit UUIDs as `180D`, Android as full
/// lowercase strings). These helpers convert app input.
public enum BluetoothUUID {

    /// The Bluetooth Base UUID, `0000xxxx-0000-1000-8000-00805F9B34FB`.
    public static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// The canonical form of a 16-bit, 32-bit or 128-bit UUID string
    /// (`180D`, `0x180D`, `0000180D`, or 32 hex digits with or without
    /// hyphens), or nil if it isn't one.
    public static func canonical(_ string: String) -> String? {
        var digits = [UInt8]()
        var bytes = Array(string.utf8)
        if bytes.count > 2, bytes[0] == 0x30, bytes[1] == 0x78 || bytes[1] == 0x58 {
            bytes.removeFirst(2) // 0x prefix
        }
        for byte in bytes {
            if byte == 0x2D {
                continue // '-'
            }
            guard let digit = hexDigit(byte) else { return nil }
            digits.append(digit)
        }
        switch digits.count {
        case 4:
            digits = [0x30, 0x30, 0x30, 0x30] + digits + base
        case 8:
            digits += base
        case 32:
            break
        default:
            return nil
        }
        var result = [UInt8]()
        result.reserveCapacity(36)
        for (index, digit) in digits.enumerated() {
            if index == 8 || index == 12 || index == 16 || index == 20 {
                result.append(0x2D)
            }
            result.append(digit)
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// The 16-bit short form (`180D`) of a canonical UUID built on the base
    /// UUID, or nil.
    public static func shortForm(_ string: String) -> String? {
        guard let canonical = canonical(string) else { return nil }
        let bytes = Array(canonical.utf8)
        guard bytes[0..<4] == [0x30, 0x30, 0x30, 0x30][...],
              String(decoding: bytes[8...], as: UTF8.self) == baseSuffix else {
            return nil
        }
        return String(decoding: bytes[4..<8], as: UTF8.self)
    }

    /// Uppercase hex digits of the base UUID after the first 8 digits.
    private static let base: [UInt8] = Array("00001000800000805F9B34FB".utf8)

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39, 0x41...0x46: return byte
        case 0x61...0x66: return byte - 0x20
        default: return nil
        }
    }
}
