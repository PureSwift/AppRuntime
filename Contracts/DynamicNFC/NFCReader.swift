import DynamicRuntime

/// A tag reader session: polls for NFC tags, then reads, writes or sends
/// commands to them. Reader role only; card emulation and peer-to-peer
/// aren't part of the contract.
///
/// Availability first: check `availability()` before offering an NFC
/// feature. There is no runtime permission prompt. On iOS the system scan
/// sheet that `begin` shows is the user's consent; on Android the `NFC`
/// permission is granted at install.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS 13+ (iPhone 7 and later) | `NFCTagReaderSession`, or `NFCNDEFReaderSession` for `.ndef` |
/// | Android | `NfcAdapter.enableReaderMode` on the foreground activity |
/// | Linux | neard / libnfc |
@DynamicRuntime("org.pureswift.nfc.Reader", requires: .nfc)
public protocol NFCReader: AnyObject {

    /// An `NFCAvailability` raw value: whether the device has NFC, and
    /// whether the user turned it on (Android).
    static func availability() -> Int32

    static func make(_ delegate: NFCReaderDelegate) -> Self

    /// Starts polling for `tagTypes` (an `NFCTagTypes` raw value). On iOS
    /// this shows the system sheet with `alertMessage`; other hosts show
    /// their own prompt or nothing. Call it from a user action while the app
    /// is in the foreground. Fails through `didInvalidate` if the reader is
    /// unavailable or another session is active.
    func begin(_ tagTypes: Int32, alertMessage: String?)

    /// Updates the message on the scan sheet, for example "Hold still…".
    func setAlertMessage(_ message: String)

    /// Resumes polling after tags were detected, for example to scan the
    /// next tag.
    func restartPolling()

    /// Connects to one of the detected tags. Commands need a connection;
    /// the result arrives through `didConnect`.
    func connect(_ tag: NFCTag)

    /// Ends the session. A non-nil `errorMessage` is shown as a failure on
    /// the iOS sheet; nil shows success.
    func invalidate(_ errorMessage: String?)

    func isActive() -> Bool
}
