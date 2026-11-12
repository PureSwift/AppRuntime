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
    ///
    /// Delegates see the peripheral's ATT error itself, `attribute` plus
    /// Insufficient Authentication (0x05) or Insufficient Encryption (0x0F);
    /// `init(code:)` turns those into this. Hosts report this code when
    /// pairing itself fails, such as when the peer removed its pairing.
    case insufficientAuthentication = 14
    case operationNotSupported = 15
    /// An ATT error from the peripheral; `rawValue - attribute.rawValue` is
    /// the ATT error code.
    case attribute = 256
}

public extension BluetoothError {

    /// ATT Insufficient Authentication.
    static let attributeInsufficientAuthentication: Int32 = 0x05

    /// ATT Insufficient Encryption.
    static let attributeInsufficientEncryption: Int32 = 0x0F

    /// The error for a delegate `error` code: `nil` for `0`, success. Codes
    /// from 256 to 511 (`attribute` plus an ATT error code) are `attribute`,
    /// except Insufficient Authentication and Insufficient Encryption, which
    /// are `insufficientAuthentication`: retry after pairing. Codes this
    /// version doesn't know are `unknown`.
    init?(code: Int32) {
        guard code != 0 else { return nil }
        if let error = BluetoothError(rawValue: code) {
            self = error
        } else if (256..<512).contains(code) {
            switch code - BluetoothError.attribute.rawValue {
            case Self.attributeInsufficientAuthentication, Self.attributeInsufficientEncryption:
                self = .insufficientAuthentication
            default:
                self = .attribute
            }
        } else {
            self = .unknown
        }
    }
}
