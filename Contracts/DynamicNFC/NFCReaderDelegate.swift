import DynamicRuntime

/// Receives `NFCReader` and `NFCTag` results on the main thread. `error` is
/// an `NFCError` raw value, `0` on success. Every tag operation gets
/// exactly one callback.
@DynamicCallback("org.pureswift.nfc.ReaderDelegate")
public protocol NFCReaderDelegate: AnyObject {

    /// Polling started; the scan sheet is visible on iOS.
    func didBecomeActive(_ reader: NFCReader)

    /// One or more tags entered the field. Polling pauses until
    /// `connect`, `restartPolling` or `invalidate`.
    func didDetect(_ reader: NFCReader, tags: [NFCTag])

    func didConnect(_ reader: NFCReader, tag: NFCTag, error: Int32)

    /// `status` is an `NDEFStatus` raw value; `capacity` in bytes.
    func didQueryNDEF(_ reader: NFCReader, tag: NFCTag, status: Int32, capacity: Int32, error: Int32)

    /// `message` is nil for an empty tag or on error.
    func didReadNDEF(_ reader: NFCReader, tag: NFCTag, message: NDEFMessage?, error: Int32)

    func didWriteNDEF(_ reader: NFCReader, tag: NFCTag, error: Int32)

    /// The tag was made permanently read-only.
    func didLock(_ reader: NFCReader, tag: NFCTag, error: Int32)

    /// The tag's response to `transceive`. For ISO 7816 the response ends
    /// with the status word (SW1 SW2).
    func didTransceive(_ reader: NFCReader, tag: NFCTag, response: [UInt8], error: Int32)

    /// The session ended: after `invalidate`, the user's cancel, the iOS
    /// 60-second limit, or a failure. Make a new reader to scan again.
    func didInvalidate(_ reader: NFCReader, error: Int32, message: String?)
}
