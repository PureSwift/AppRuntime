/// Guest-side names for the integer codes the NFC contracts carry.

/// `NFCReader.availability()`.
public enum NFCAvailability: Int32, Sendable {
    /// No NFC hardware, or no reader support (iPad, Mac, Apple TV).
    case unsupported = 0
    /// The user turned NFC off (Android). Point them to the NFC settings.
    case disabled = 1
    case available = 2
}

/// `NFCReader.begin(_:alertMessage:)` polling options.
public struct NFCTagTypes: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// NDEF only. No raw commands, and no UID on iOS, but no extra iOS
    /// entitlement formats are needed. Can't be combined with the others.
    public static var ndef: Self { Self(rawValue: 0x01) }
    /// ISO 14443: ISO 7816 smart cards, MIFARE Ultralight / DESFire / Plus.
    public static var iso14443: Self { Self(rawValue: 0x02) }
    /// ISO 15693 vicinity tags.
    public static var iso15693: Self { Self(rawValue: 0x04) }
    /// ISO 18092: FeliCa.
    public static var iso18092: Self { Self(rawValue: 0x08) }
}

/// `NFCTag.type()`.
public enum NFCTagType: Int32, Sendable {
    case unknown = 0
    /// ISO 7816 smart card (IsoDep).
    case iso7816 = 1
    /// MIFARE Ultralight, DESFire or Plus (NfcA).
    case miFare = 2
    case iso15693 = 3
    case feliCa = 4
    /// Found in an NDEF-only session; only NDEF operations work.
    case ndef = 5
}

/// `NFCReaderDelegate.didQueryNDEF` status.
public enum NDEFStatus: Int32, Sendable {
    case notSupported = 0
    case readWrite = 1
    case readOnly = 2
}

/// NDEF type name format (TNF), as in the NFC Forum specification.
public enum NDEFTypeNameFormat: Int32, Sendable {
    case empty = 0
    case wellKnown = 1
    case media = 2
    case absoluteURI = 3
    case external = 4
    case unknown = 5
    case unchanged = 6
}

/// Delegate `error` codes. `0` is success.
public enum NFCError: Int32, Error, Sendable {
    case unknown = 1
    /// No reader on this device.
    case unsupported = 2
    /// NFC is turned off (Android).
    case disabled = 3
    /// The user closed the scan sheet (iOS).
    case userCancelled = 4
    /// iOS ends sessions after 60 seconds.
    case sessionTimeout = 5
    /// Another session is active, or the system is busy.
    case systemBusy = 6
    /// The app left the foreground; sessions end then.
    case appInBackground = 7
    /// The manifest lacks a required declaration: the iOS entitlement
    /// format, an ISO 7816 AID, or a FeliCa system code.
    case missingDeclaration = 8
    case tagConnectionLost = 9
    case tagNotConnected = 10
    case ndefNotSupported = 11
    case tagReadOnly = 12
    case capacityExceeded = 13
    case transceiveFailed = 14
    case invalidParameter = 15
    case notAvailableInNDEFSession = 16
}
