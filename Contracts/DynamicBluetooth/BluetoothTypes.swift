/// Guest-side names for the integer codes the Bluetooth contracts carry.
/// Contracts use `Int32` on the wire; these never cross the boundary.

/// `Central.state()`.
public enum CentralState: Int32, Sendable {
    case unknown = 0
    case resetting = 1
    case unsupported = 2
    case unauthorized = 3
    case poweredOff = 4
    case poweredOn = 5
}

/// `Characteristic.properties()`, as in the Bluetooth Core specification.
public struct CharacteristicProperties: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static var broadcast: Self { Self(rawValue: 0x01) }
    public static var read: Self { Self(rawValue: 0x02) }
    public static var writeWithoutResponse: Self { Self(rawValue: 0x04) }
    public static var write: Self { Self(rawValue: 0x08) }
    public static var notify: Self { Self(rawValue: 0x10) }
    public static var indicate: Self { Self(rawValue: 0x20) }
    public static var authenticatedSignedWrites: Self { Self(rawValue: 0x40) }
    public static var extendedProperties: Self { Self(rawValue: 0x80) }
}

/// Delegate `error` codes. `0` is success.
public enum BluetoothError: Int32, Error, Sendable {
    case unknown = 1
    case invalidParameters = 2
    case invalidHandle = 3
    case notConnected = 4
    case outOfSpace = 5
    case operationCancelled = 6
    case connectionTimeout = 7
    case peripheralDisconnected = 8
    case uuidNotAllowed = 9
    case alreadyAdvertising = 10
    case connectionFailed = 11
    case connectionLimitReached = 12
    case operationNotSupported = 13
    case unauthorized = 14
    /// An ATT error from the peripheral; the low byte is the ATT code.
    case attribute = 256
}
