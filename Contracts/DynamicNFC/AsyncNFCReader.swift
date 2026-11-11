#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A tag's NDEF support and free space.
public struct NDEFTagStatus: Equatable, Sendable {

    public var status: NDEFStatus

    /// Bytes available for an NDEF message.
    public var capacity: Int32

    public init(status: NDEFStatus, capacity: Int32) {
        self.status = status
        self.capacity = capacity
    }
}

/// Async/await over `NFCReader` (§6.2.1): the guest-side convenience layer.
///
/// A reader session is an `EventStream` of detected tags. Tag calls are
/// async and complete in order per tag.
///
/// ```swift
/// let reader = AsyncNFCReader()
/// for try await tags in reader.session(tagTypes: .ndef, alertMessage: "Hold near a tag") {
///     guard let tag = tags.first else { continue }
///     try await reader.connect(tag)
///     let message = try await reader.readNDEF(tag)
///     reader.invalidate()
/// }
/// ```
///
/// The stream ends when the host ends the session: normally after
/// `invalidate()`, otherwise by throwing why (`userCancelled`,
/// `sessionTimeout`, …). Releasing the stream or cancelling its task ends
/// the session. Pending tag calls then throw. One session at a time. The
/// guest is single-threaded (§6.4).
public final class AsyncNFCReader: @unchecked Sendable {

    /// The underlying contract object.
    public let reader: any NFCReader

    let events: NFCEvents

    public init() {
        let events = NFCEvents()
        self.events = events
        self.reader = NFCReaderProxy.make(events)
    }

    /// The host's NFC hardware state, or `unsupported` if this host doesn't
    /// provide NFC or the capability isn't granted.
    public static var availability: NFCAvailability {
        guard NFCReaderProxy.isAvailable else { return .unsupported }
        return NFCAvailability(rawValue: NFCReaderProxy.availability()) ?? .unsupported
    }

    // MARK: Session

    /// Starts a session and returns the tags detected in it.
    ///
    /// - Parameter alertMessage: Shown in the system sheet where there is one (iOS).
    public func session(tagTypes: NFCTagTypes, alertMessage: String? = nil) -> EventStream<[any NFCTag], NFCError> {
        let (stream, continuation) = EventStream<[any NFCTag], NFCError>.makeStream()
        events.session?.finish()
        events.generation &+= 1
        let generation = events.generation
        events.session = continuation
        continuation.onTermination = { [events, reader] in
            guard events.generation == generation else { return }
            events.session = nil
            if reader.isActive() {
                reader.invalidate(nil)
            }
        }
        reader.begin(tagTypes.rawValue, alertMessage: alertMessage)
        return stream
    }

    public func setAlertMessage(_ message: String) {
        reader.setAlertMessage(message)
    }

    /// Ends the session; with `errorMessage`, shown as a failure where the
    /// host has a sheet.
    public func invalidate(errorMessage: String? = nil) {
        reader.invalidate(errorMessage)
    }

    /// Looks for tags again after a detection, without ending the session.
    public func restartPolling() {
        reader.restartPolling()
    }

    // MARK: Tags

    /// Connects to a detected tag; tag calls need a connection.
    public func connect(_ tag: any NFCTag) async throws(NFCError) {
        try await request { callback in
            events.connections.append(callback, for: tag)
            reader.connect(tag)
        }
    }

    public func ndefStatus(of tag: any NFCTag) async throws(NFCError) -> NDEFTagStatus {
        try await request { callback in
            events.statuses.append(callback, for: tag)
            tag.queryNDEFStatus()
        }
    }

    /// Reads the tag's NDEF message; `nil` if it has none.
    public func readNDEF(_ tag: any NFCTag) async throws(NFCError) -> (any NDEFMessage)? {
        try await request { callback in
            events.reads.append(callback, for: tag)
            tag.readNDEF()
        }
    }

    public func writeNDEF(_ message: any NDEFMessage, to tag: any NFCTag) async throws(NFCError) {
        try await request { callback in
            events.writes.append(callback, for: tag)
            tag.writeNDEF(message)
        }
    }

    /// Makes the tag read-only. Permanent.
    public func lock(_ tag: any NFCTag) async throws(NFCError) {
        try await request { callback in
            events.locks.append(callback, for: tag)
            tag.writeLock()
        }
    }

    /// Sends a raw command (an ISO 7816 APDU, a MIFARE or FeliCa command)
    /// and returns the response.
    public func transceive(_ command: [UInt8], with tag: any NFCTag) async throws(NFCError) -> [UInt8] {
        try await request { callback in
            events.transceives.append(callback, for: tag)
            tag.transceive(command)
        }
    }

    /// One tag call: throws `cancelled` at once if its task is cancelled;
    /// the native call can't be cancelled, and its result is discarded.
    private func request<Value>(_ start: (Callback<Value, NFCError>) -> Void) async throws(NFCError) -> Value {
        try await withCallback(start) { callback in
            callback.resume(throwing: .cancelled)
        }
    }
}

/// The delegate behind `AsyncNFCReader`.
final class NFCEvents: NFCReaderDelegate {

    var session: EventStream<[any NFCTag], NFCError>.Continuation?

    var generation = 0

    let connections = PendingCallbacks<Void, NFCError>()

    let statuses = PendingCallbacks<NDEFTagStatus, NFCError>()

    let reads = PendingCallbacks<(any NDEFMessage)?, NFCError>()

    let writes = PendingCallbacks<Void, NFCError>()

    let locks = PendingCallbacks<Void, NFCError>()

    let transceives = PendingCallbacks<[UInt8], NFCError>()

    private static func result(_ error: Int32) -> Result<Void, NFCError> {
        NFCError(code: error).map { .failure($0) } ?? .success(())
    }

    func didBecomeActive(_ reader: any NFCReader) { }

    func didDetect(_ reader: any NFCReader, tags: [any NFCTag]) {
        session?.yield(tags)
    }

    func didConnect(_ reader: any NFCReader, tag: any NFCTag, error: Int32) {
        connections.resume(for: tag, with: Self.result(error))
    }

    func didQueryNDEF(_ reader: any NFCReader, tag: any NFCTag, status: Int32, capacity: Int32, error: Int32) {
        let result: Result<NDEFTagStatus, NFCError> = NFCError(code: error).map { .failure($0) }
            ?? .success(NDEFTagStatus(status: NDEFStatus(rawValue: status) ?? .notSupported, capacity: capacity))
        statuses.resume(for: tag, with: result)
    }

    func didReadNDEF(_ reader: any NFCReader, tag: any NFCTag, message: (any NDEFMessage)?, error: Int32) {
        reads.resume(for: tag, with: NFCError(code: error).map { .failure($0) } ?? .success(message))
    }

    func didWriteNDEF(_ reader: any NFCReader, tag: any NFCTag, error: Int32) {
        writes.resume(for: tag, with: Self.result(error))
    }

    func didLock(_ reader: any NFCReader, tag: any NFCTag, error: Int32) {
        locks.resume(for: tag, with: Self.result(error))
    }

    func didTransceive(_ reader: any NFCReader, tag: any NFCTag, response: [UInt8], error: Int32) {
        transceives.resume(for: tag, with: NFCError(code: error).map { .failure($0) } ?? .success(response))
    }

    func didInvalidate(_ reader: any NFCReader, error: Int32, message: String?) {
        let reason = NFCError(code: error)
        let pending = reason ?? .tagNotConnected
        connections.failAll(pending)
        statuses.failAll(pending)
        reads.failAll(pending)
        writes.failAll(pending)
        locks.failAll(pending)
        transceives.failAll(pending)
        session?.finish(throwing: reason)
    }
}
#endif
