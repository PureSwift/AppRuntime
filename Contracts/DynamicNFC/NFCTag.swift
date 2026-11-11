import DynamicRuntime

/// A tag in the field. Operations need `NFCReader.connect(_:)` first, and
/// report through the reader's delegate.
@DynamicRuntime("org.pureswift.nfc.Tag")
public protocol NFCTag: AnyObject {

    /// An `NFCTagType` raw value.
    func type() -> Int32

    /// The UID (ISO 14443 / ISO 15693) or IDm (FeliCa). Empty for tags read
    /// in an NDEF-only session, where iOS doesn't expose it. Some cards use
    /// a random UID per tap; don't treat it as a stable identity.
    func identifier() -> [UInt8]

    /// Whether the tag is still in the field.
    func isAvailable() -> Bool

    /// ISO 7816 historical bytes, if any.
    func historicalBytes() -> [UInt8]?

    /// The ISO 7816 application iOS selected from the manifest's AID list.
    func selectedApplicationIdentifier() -> String?

    /// Largest command `transceive` accepts, in bytes.
    func maximumTransceiveLength() -> Int32

    /// Reports NDEF support and capacity through `didQueryNDEF`.
    func queryNDEFStatus()

    func readNDEF()

    func writeNDEF(_ message: NDEFMessage)

    /// Makes the tag permanently read-only.
    func writeLock()

    /// Sends a raw command for the tag's technology: an ISO 7816 APDU
    /// (IsoDep / `NFCISO7816Tag`), a MIFARE Ultralight / DESFire command
    /// (NfcA / `NFCMiFareTag`), a FeliCa command (NfcF), or an ISO 15693
    /// request (NfcV). Not available in NDEF-only sessions.
    func transceive(_ data: [UInt8])
}
