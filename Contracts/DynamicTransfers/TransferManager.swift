import DynamicFiles
import DynamicRuntime
#if canImport(DynamicObservation)
@_exported import DynamicObservation
#else
@_exported import Observation
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The app's downloads and uploads, which the host moves.
///
/// ```swift
/// let transfers = TransferManager.shared
/// let map = try await transfers.download(
///     TransferRequest(url: "https://example.com/maps/berlin.tiles"),
///     to: .documents / "maps/berlin.tiles",
///     options: TransferOptions(title: "Berlin map", continuesInBackground: true))
/// let response = try await map.finished()
///
/// // At the next launch: what was carried on meanwhile.
/// for transfer in try await transfers.all() where transfer.state == .completed { … }
/// ```
///
/// There is one `Transfer` for each of the host's transfers, the same
/// object however it was found, and it changes as the transfer does. It's
/// guest-side only, over the `Transfers` contract, which requires
/// `.network` in the manifest. The guest is single-threaded (§6.4).
public final class TransferManager: @unchecked Sendable {

    /// The app's transfers.
    public static let shared = TransferManager()

    /// The host's transfers, made when first used.
    private var made: (any Transfers)?

    private let listener = TransferListener()

    /// Every transfer this side has heard of, by identifier.
    private var known: [String: Transfer] = [:]

    private var handler: ((Transfer) -> Void)?

    /// Counts listeners, so a stream that ends knows whether it's still
    /// the one listening.
    private var generation = 0

    init() { }

    var host: any Transfers {
        if let made {
            return made
        }
        let host = TransfersProxy.shared()
        made = host
        listener.manager = Unmanaged.passUnretained(self)
        host.setDelegate(listener)
        return host
    }

    // MARK: Starting

    /// Downloads `request` to `file`. Answered once the host has taken the
    /// transfer on, before any byte moves; the transfer goes on from there.
    public func download(_ request: TransferRequest, to file: FilePath, options: TransferOptions = TransferOptions(),
                         completion: @escaping (Result<Transfer, TransferError>) -> Void) {
        start(.download, request, file, options, completion)
    }

    /// Sends `file`'s bytes as the body of `request`.
    public func upload(file: FilePath, with request: TransferRequest, options: TransferOptions = TransferOptions(),
                       completion: @escaping (Result<Transfer, TransferError>) -> Void) {
        start(.upload, request, file, options, completion)
    }

    private func start(_ kind: TransferKind, _ request: TransferRequest, _ file: FilePath, _ options: TransferOptions,
                       _ completion: @escaping (Result<Transfer, TransferError>) -> Void) {
        host.start(
            kind.rawValue,
            url: request.url,
            method: request.method(for: kind),
            headers: request.headerList,
            directory: file.directory.rawValue,
            path: file.path,
            title: options.title,
            completionMessage: options.completionMessage ?? "",
            options: options.bits,
            callback: TransferReceiver { outcome in
                switch outcome {
                case .started(let record):
                    let transfer = self.update(record, request: request, options: options)
                    completion(.success(transfer))
                case .listed:
                    completion(.failure(.unknown))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        )
    }

    // MARK: Finding

    /// Every transfer the host has, oldest first: those still moving, and
    /// those that ended and haven't been removed.
    public func all(completion: @escaping (Result<[Transfer], TransferError>) -> Void) {
        host.list(TransferReceiver { outcome in
            switch outcome {
            case .listed(let records):
                var transfers: [Transfer] = []
                var listed = Set<String>()
                for record in records {
                    transfers.append(self.update(record))
                    listed.insert(record.identifier)
                }
                // What the host no longer has is gone.
                for identifier in self.known.keys where !listed.contains(identifier) {
                    self.known[identifier] = nil
                }
                completion(.success(transfers))
            case .started:
                completion(.failure(.unknown))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    /// A transfer this side has already heard of.
    public func transfer(withID identifier: String) -> Transfer? {
        known[identifier]
    }

    // MARK: Changes

    /// Called when any transfer changes: its state, how far it has got.
    /// One listener at a time: a new closure, or a `changes` stream,
    /// replaces it, and `nil` stops it.
    public func onChange(_ handler: ((Transfer) -> Void)?) {
        generation &+= 1
        self.handler = handler
        _ = host
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// One element each time a transfer changes. Ending the loop stops
    /// listening. It replaces an `onChange` closure, and another stream.
    public var changes: EventStream<Transfer, Never> {
        let (stream, continuation) = EventStream<Transfer, Never>.makeStream()
        onChange { continuation.yield($0) }
        let generation = self.generation
        continuation.onTermination = {
            // Unless something else listens by now.
            guard self.generation == generation else { return }
            self.handler = nil
        }
        return stream
    }

    public nonisolated(nonsending) func download(_ request: TransferRequest, to file: FilePath,
                                                 options: TransferOptions = TransferOptions()) async throws(TransferError) -> Transfer {
        try await transferResult { self.download(request, to: file, options: options, completion: $0) }
    }

    public nonisolated(nonsending) func upload(file: FilePath, with request: TransferRequest,
                                               options: TransferOptions = TransferOptions()) async throws(TransferError) -> Transfer {
        try await transferResult { self.upload(file: file, with: request, options: options, completion: $0) }
    }

    public nonisolated(nonsending) func all() async throws(TransferError) -> [Transfer] {
        try await transferResult { self.all(completion: $0) }
    }
    #endif

    // MARK: The host's word

    /// The one `Transfer` for a record, made or brought up to date.
    @discardableResult
    func update(_ record: TransferRecord, request: TransferRequest? = nil, options: TransferOptions? = nil) -> Transfer {
        if let transfer = known[record.identifier] {
            transfer.apply(record)
            return transfer
        }
        let transfer = Transfer(record: record, request: request, options: options, manager: self)
        known[record.identifier] = transfer
        return transfer
    }

    func changed(_ record: TransferRecord) {
        let transfer = update(record)
        handler?(transfer)
    }

    func removed(_ identifier: String) {
        guard let transfer = known.removeValue(forKey: identifier) else { return }
        transfer.wasRemoved()
    }

    func forget(_ identifier: String) {
        known[identifier] = nil
    }
}

/// One download or upload: where it is, and how far it has got.
///
/// It's observable: a view that reads `state` or `fractionCompleted` is
/// evaluated again as they change.
///
/// ```swift
/// ProgressView(value: download.fractionCompleted ?? 0)
/// Button("Pause") { download.pause() }
/// ```
public final class Transfer: Observable, Identifiable, @unchecked Sendable {

    /// The host's, the same at every launch.
    public let id: String

    public let kind: TransferKind

    /// As it was started. A transfer found in `TransferManager.all()` has
    /// no headers: the host keeps them to itself.
    public let request: TransferRequest

    /// The destination of a download, or the body of an upload.
    public let file: FilePath

    /// As it was started. One found in `all()` has no completion message.
    public let options: TransferOptions

    private let registrar = ObservationRegistrar()

    private var record: TransferRecord

    /// Who waits for the end.
    private var waiting: [(Result<TransferResponse?, TransferError>) -> Void] = []

    /// The manager, which outlives every transfer: Embedded Swift has no
    /// weak references.
    private let manager: Unmanaged<TransferManager>

    init(record: TransferRecord, request: TransferRequest?, options: TransferOptions?, manager: TransferManager) {
        self.id = record.identifier
        self.kind = record.kind
        self.request = request ?? TransferRequest(url: record.url, method: record.method)
        self.file = record.file
        self.options = options ?? TransferOptions(title: record.title, bits: record.options)
        self.record = record
        self.manager = Unmanaged.passUnretained(manager)
    }

    // MARK: Where it is

    public var state: TransferState {
        registrar.access(self, propertyIndex: 0)
        return record.state
    }

    public var bytesTransferred: Int64 {
        registrar.access(self, propertyIndex: 1)
        return record.bytesTransferred
    }

    /// Nil until the size is known.
    public var bytesExpected: Int64? {
        registrar.access(self, propertyIndex: 1)
        return record.bytesExpected
    }

    /// From 0 to 1; nil until the size is known.
    public var fractionCompleted: Double? {
        registrar.access(self, propertyIndex: 1)
        if record.state == .completed {
            return 1
        }
        guard let expected = record.bytesExpected, expected > 0 else { return nil }
        return min(max(Double(record.bytesTransferred) / Double(expected), 0), 1)
    }

    /// The status, the content type and the suggested file name, once
    /// there is one.
    public var response: TransferResponse? {
        registrar.access(self, propertyIndex: 2)
        guard let status = record.statusCode else { return nil }
        return TransferResponse(
            statusCode: status,
            contentType: record.contentType.isEmpty ? nil : record.contentType,
            suggestedFileName: record.suggestedFileName.isEmpty ? nil : record.suggestedFileName
        )
    }

    /// Why it failed.
    public var error: TransferError? {
        registrar.access(self, propertyIndex: 0)
        return record.state == .failed ? (record.error ?? .unknown) : nil
    }

    // MARK: What the app does

    public func pause() {
        manager.takeUnretainedValue().host.pause(id)
    }

    /// Goes on. A download goes on from where it stopped if the server
    /// allows, and starts again if it doesn't; an upload starts again.
    public func resume() {
        manager.takeUnretainedValue().host.resume(id)
    }

    /// Stops it and discards what it had. A download leaves nothing at its
    /// destination.
    public func cancel() {
        manager.takeUnretainedValue().host.cancel(id)
    }

    /// Forgets a transfer that has ended. One still moving is left.
    public func remove() {
        guard record.state.isFinished else { return }
        let manager = manager.takeUnretainedValue()
        manager.host.remove(id)
        manager.forget(id)
    }

    /// Waits for the end: the server's answer, or why there is none.
    public func finished(completion: @escaping (Result<TransferResponse?, TransferError>) -> Void) {
        if let outcome = outcome {
            completion(outcome)
        } else {
            waiting.append(completion)
        }
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Waits for the end. A cancelled task stops waiting with `cancelled`;
    /// the transfer goes on.
    @discardableResult
    public nonisolated(nonsending) func finished() async throws(TransferError) -> TransferResponse? {
        try await transferResult { self.finished(completion: $0) }
    }
    #endif

    // MARK: The host's word

    /// How it ended, once it has.
    private var outcome: Result<TransferResponse?, TransferError>? {
        switch record.state {
        case .completed:
            return .success(response)
        case .failed:
            return .failure(record.error ?? .unknown)
        case .cancelled:
            return .failure(.cancelled)
        case .waiting, .running, .paused:
            return nil
        }
    }

    func apply(_ new: TransferRecord) {
        // A transfer ends once; a word after that is a stale one.
        guard !record.state.isFinished, new.identifier == id else { return }
        let old = record
        let stateChanged = old.state != new.state || old.error != new.error
        let progressChanged = old.bytesTransferred != new.bytesTransferred || old.bytesExpected != new.bytesExpected
        let responseChanged = old.statusCode != new.statusCode || old.contentType != new.contentType
            || old.suggestedFileName != new.suggestedFileName
        if stateChanged {
            registrar.withMutation(of: self, propertyIndex: 0) { record.state = new.state; record.error = new.error }
        }
        if progressChanged {
            registrar.withMutation(of: self, propertyIndex: 1) {
                record.bytesTransferred = new.bytesTransferred
                record.bytesExpected = new.bytesExpected
            }
        }
        if responseChanged {
            registrar.withMutation(of: self, propertyIndex: 2) {
                record.statusCode = new.statusCode
                record.contentType = new.contentType
                record.suggestedFileName = new.suggestedFileName
            }
        }
        record = new
        finishIfEnded()
    }

    /// The host forgot it before this side saw the end.
    func wasRemoved() {
        guard !waiting.isEmpty else { return }
        let waiting = self.waiting
        self.waiting = []
        let outcome = self.outcome ?? .failure(.unknown)
        for completion in waiting {
            completion(outcome)
        }
    }

    private func finishIfEnded() {
        guard let outcome, !waiting.isEmpty else { return }
        let waiting = self.waiting
        self.waiting = []
        for completion in waiting {
            completion(outcome)
        }
    }
}

#if !EMBEDDED_NO_CONCURRENCY
/// Waits for a completion handler. A cancelled task stops waiting with
/// `cancelled`; the operation itself isn't undone.
nonisolated(nonsending) func transferResult<Value>(_ start: (@escaping (Result<Value, TransferError>) -> Void) -> Void) async throws(TransferError) -> Value {
    try await withCallback { (callback: Callback<Value, TransferError>) in
        start { callback.resume(with: $0) }
    } onCancel: { callback in
        callback.resume(throwing: .cancelled)
    }
}
#endif

/// The delegate the host holds, for as long as the app runs.
private final class TransferListener: TransfersDelegate {

    var manager: Unmanaged<TransferManager>?

    func didChange(_ record: [String]) {
        guard let record = TransferRecord(fields: record[...]) else { return }
        manager?.takeUnretainedValue().changed(record)
    }

    func didRemove(_ identifier: String) {
        manager?.takeUnretainedValue().removed(identifier)
    }
}

/// What a `TransferCallback` was told.
private enum TransferOutcome {
    case started(TransferRecord)
    case listed([TransferRecord])
    case failure(TransferError)
}

/// One operation's callback. The host holds it until it answers.
private final class TransferReceiver: TransferCallback {

    private var finish: ((TransferOutcome) -> Void)?

    init(_ finish: @escaping (TransferOutcome) -> Void) {
        self.finish = finish
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: TransferOutcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didStart(_ record: [String]) {
        guard let record = TransferRecord(fields: record[...]) else {
            answer(.failure(.unknown))
            return
        }
        answer(.started(record))
    }

    func didList(_ records: [String]) {
        answer(.listed(TransferRecord.records(records)))
    }

    func didFail(_ error: Int32, message: String) {
        answer(.failure(TransferError(code: error)))
    }
}
