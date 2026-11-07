/// Guest-side names for the integer codes the Bluetooth contracts carry.
/// Contracts use `Int32` on the wire; these never cross the boundary.

/// `Central.authorizationStatus()`.
public enum BluetoothAuthorization: Int32, Sendable {
    /// Not asked yet (`CBManagerAuthorization.notDetermined`; Android
    /// runtime permission never requested).
    case notDetermined = 0
    /// Parental controls or device management prevent access.
    case restricted = 1
    /// The user refused. Only the Settings app can change it; Android also
    /// reports this after "Don't ask again".
    case denied = 2
    case allowed = 3
}

/// `Central.state()`.
public enum CentralState: Int32, Sendable {
    case unknown = 0
    case resetting = 1
    /// No Bluetooth LE hardware.
    case unsupported = 2
    /// Authorization is not `allowed`.
    case unauthorized = 3
    case poweredOff = 4
    case poweredOn = 5
}

/// `Peripheral.state()`.
public enum PeripheralState: Int32, Sendable {
    case disconnected = 0
    case connecting = 1
    case connected = 2
    case disconnecting = 3
}

/// `Central.scan(services:allowDuplicates:mode:)`. Android only; other hosts
/// ignore it.
public enum ScanMode: Int32, Sendable {
    case balanced = 0
    case lowPower = 1
    case lowLatency = 2
}

/// `Peripheral.writeValue(_:for:type:)`.
public enum WriteType: Int32, Sendable {
    case withResponse = 0
    case withoutResponse = 1
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
    /// Authorization isn't `allowed`.
    case unauthorized = 2
    /// Bluetooth is off.
    case poweredOff = 3
    case unsupported = 4
    case invalidParameters = 5
    /// The operation needs a connection.
    case notConnected = 6
    case connectionTimeout = 7
    case connectionFailed = 8
    case connectionLimitReached = 9
    case peripheralDisconnected = 10
    case operationCancelled = 11
    /// Android refused to start the scan: too many starts in 30 seconds.
    case scanThrottled = 12
    case scanFailed = 13
    /// The peripheral needs pairing or encryption. Pairing is started by
    /// the system (iOS) or by the host (Android) when an encrypted
    /// attribute is accessed; retry after it completes.
    case insufficientAuthentication = 14
    case operationNotSupported = 15
    /// An ATT error from the peripheral; `rawValue - attribute.rawValue` is
    /// the ATT error code.
    case attribute = 256
}
