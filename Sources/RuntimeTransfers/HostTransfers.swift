import DynamicFiles
import DynamicRuntime
import DynamicTransfers
import Foundation
import RuntimeHost
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// The `Transfers` contract for any host written in Swift
/// (`Documentation/Contracts/Transfers.md`), over a platform's
/// `TransferEngine`.
///
/// It keeps every rule of the contract: the records, written to
/// `storagePath` so that they are there at the next launch; identifiers;
/// the states, and that a transfer ends once; progress at most four times a
/// second; a download's bytes in a part file of the host's, which becomes
/// the destination when the last byte is in and the server said yes; and
/// which destinations a transfer carried on may have.
///
/// The contract is the main thread's. An engine reports from any thread,
/// through `deliver`.
public final class HostTransfers: Transfers {

    // MARK: Settings

    /// Moves the bytes of transfers that run while the app does. The
    /// default runs them in this process, over `URLSession`.
    nonisolated(unsafe) public static var engine: (any TransferEngine)? = URLSessionTransferEngine()

    /// Moves the bytes of transfers carried on after the app is closed.
    /// Nil, the default: such transfers are refused with
    /// `notAllowedInBackground`.
    nonisolated(unsafe) public static var backgroundEngine: (any TransferEngine)?

    /// The file the records are kept in, in the host's own space. Nil keeps
    /// them in memory, for this launch alone.
    nonisolated(unsafe) public static var storagePath: String?

    /// Where downloads are written until they are whole.
    nonisolated(unsafe) public static var partsDirectory: String = NSTemporaryDirectory() + "AppRuntimeTransfers"

    /// How long a transfer that ended is kept, if the app doesn't remove
    /// it.
    nonisolated(unsafe) public static var retention: TimeInterval = 30 * 24 * 3600

    /// Shows a notification: a transfer's identifier, its title, and the
    /// app's message. Called on the main thread when a transfer carried on
    /// ends while the app isn't in front, and the app asked for one. Nil
    /// shows nothing.
    nonisolated(unsafe) public static var notifier: ((_ identifier: String, _ title: String, _ message: String) -> Void)?

    /// What the time is. Replaceable, for tests.
    nonisolated(unsafe) public static var clock: () -> Date = { Date() }

    /// Runs an answer on the main thread, after the call that asked has
    /// returned. The default is the main dispatch queue; a host with a
    /// loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    /// Runs something on the main thread after so many seconds.
    nonisolated(unsafe) public static var after: @Sendable (Double, @escaping @Sendable () -> Void) -> Void = defaultAfter

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    private static let defaultAfter: @Sendable (Double, @escaping @Sendable () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The least time between two reports of a transfer's progress.
    static let progressInterval: TimeInterval = 0.25

    /// The one instance. Never replaced: a guest keeps the object it first
    /// asked for.
    nonisolated(unsafe) private static let instance = HostTransfers()

    public static func shared() -> HostTransfers {
        instance.loadIfNeeded()
        return instance
    }

    /// Back to the defaults, with no records and no delegate: for tests.
    public static func reset() {
        engine = URLSessionTransferEngine()
        backgroundEngine = nil
        storagePath = nil
        partsDirectory = NSTemporaryDirectory() + "AppRuntimeTransfers"
        retention = 30 * 24 * 3600
        notifier = nil
        clock = { Date() }
        deliver = defaultDeliver
        after = defaultAfter
        instance.forgetLaunch()
        instance.isInFront = true
    }

    /// Forgets what this launch holds, and reads the records again when
    /// next asked: what a new launch of the app finds. For a host that
    /// starts the guest again, and tests. Reports from before are ignored.
    public static func reload() {
        instance.forgetLaunch()
    }

    // MARK: The app's comings and goings

    public static func applicationDidEnterBackground() {
        instance.isInFront = false
    }

    public static func applicationWillEnterForeground() {
        instance.isInFront = true
    }

    /// The app is about to stop: what isn't carried on stops with it, and
    /// is paused with what it had.
    public static func applicationWillTerminate() {
        let instance = shared()
        for index in instance.transfers.indices where !instance.transfers[index].continuesInBackground
            && !instance.transfers[index].record.state.isFinished && instance.transfers[index].record.state != .paused {
            instance.stopEngine(index)
            instance.transfers[index].record.state = .paused
        }
        instance.save()
    }

    // MARK: State

    /// One transfer as the host keeps it.
    struct Kept: Codable {
        var record: TransferRecord
        var headers: [TransferHeader]
        var completionMessage: String
        /// What the part file holds: its `ETag` or `Last-Modified`.
        var validator: String?
        /// Where a download goes, or the file an upload sends.
        var target: String
        /// Where a download's bytes are until it's whole.
        var part: String
        var endedAt: Double?

        init(record: TransferRecord, headers: [TransferHeader], completionMessage: String, validator: String?,
             target: String, part: String, endedAt: Double?) {
            self.record = record
            self.headers = headers
            self.completionMessage = completionMessage
            self.validator = validator
            self.target = target
            self.part = part
            self.endedAt = endedAt
        }

        enum CodingKeys: String, CodingKey {
            case record, headers, completionMessage, validator, target, part, endedAt
        }

        /// The record is kept as the contract carries it.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fields = try container.decode([String].self, forKey: .record)
            guard let record = TransferRecord(fields: fields[...]) else {
                throw DecodingError.dataCorruptedError(forKey: .record, in: container, debugDescription: "not a transfer record")
            }
            self.record = record
            self.headers = try container.decode([TransferHeader].self, forKey: .headers)
            self.completionMessage = try container.decode(String.self, forKey: .completionMessage)
            self.validator = try container.decodeIfPresent(String.self, forKey: .validator)
            self.target = try container.decode(String.self, forKey: .target)
            self.part = try container.decode(String.self, forKey: .part)
            self.endedAt = try container.decodeIfPresent(Double.self, forKey: .endedAt)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(record.fields, forKey: .record)
            try container.encode(headers, forKey: .headers)
            try container.encode(completionMessage, forKey: .completionMessage)
            try container.encodeIfPresent(validator, forKey: .validator)
            try container.encode(target, forKey: .target)
            try container.encode(part, forKey: .part)
            try container.encodeIfPresent(endedAt, forKey: .endedAt)
        }

        var continuesInBackground: Bool {
            record.options & TransferOptions.continuesInBackgroundBit != 0
        }
    }

    private(set) var transfers: [Kept] = []

    private var delegate: (any TransfersDelegate)?

    private var loaded = false

    private var isInFront = true

    /// Counts launches, so a report from before this one says nothing.
    private var launch = 0

    /// Counts runs of the engines, so a report from a stopped run says
    /// nothing. By identifier.
    private var tokens: [String: Int] = [:]

    private var nextToken = 1

    /// When each transfer's progress was last told, and whether some is
    /// waiting to be.
    private var lastProgress: [String: Date] = [:]

    private var pendingProgress: Set<String> = []

    init() { }

    private func forgetLaunch() {
        transfers = []
        delegate = nil
        loaded = false
        launch += 1
        tokens = [:]
        lastProgress = [:]
        pendingProgress = []
    }

    private func index(of identifier: String) -> Int? {
        transfers.firstIndex { $0.record.identifier == identifier }
    }

    // MARK: The contract

    public func start(_ kind: Int32, url: String, method: String, headers: [String],
                      directory: Int32, path: String,
                      title: String, completionMessage: String, options: Int32,
                      callback: any TransferCallback) {
        let held = MainThreadHeld(callback)
        let refused: (TransferError, String) -> Void = { error, message in
            HostTransfers.deliver {
                held.take()?.didFail(error.code, message: message)
            }
        }
        guard let kind = TransferKind(rawValue: kind) else {
            refused(.invalidRequest, "Transfers.start: unknown kind \(kind)")
            return
        }
        guard Self.isWebURL(url) else {
            refused(.invalidRequest, "Transfers.start: not an http or https URL: \(url)")
            return
        }
        guard Self.isToken(method) else {
            refused(.invalidRequest, "Transfers.start: not a method: \(method)")
            return
        }
        guard headers.count % 2 == 0, headers.enumerated().allSatisfy({ $0.offset % 2 == 1 || Self.isToken($0.element) }) else {
            refused(.invalidRequest, "Transfers.start: headers must be names and values in turn")
            return
        }
        let carriedOn = options & TransferOptions.continuesInBackgroundBit != 0
        if carriedOn {
            guard Self.backgroundEngine != nil else {
                refused(.notAllowedInBackground, "Transfers.start: this host can't carry a transfer on")
                return
            }
            // The app's own directories, which are there without it.
            guard [FileDirectory.documents, .data, .caches].map(\.rawValue).contains(directory) else {
                refused(.notAllowedInBackground, "Transfers.start: a transfer carried on goes to documents, data or caches")
                return
            }
        } else if Self.engine == nil {
            refused(.unavailable, "Transfers.start: this host has no transfers")
            return
        }
        let target: String
        do throws(TransferError) {
            target = try Self.resolve(kind, directory, path)
        } catch {
            refused(error, "Transfers.start: \(directory) \(path): \(error)")
            return
        }
        let identifier = UUID().uuidString
        var pairs: [TransferHeader] = []
        var position = 0
        while position + 1 < headers.count {
            pairs.append(TransferHeader(headers[position], headers[position + 1]))
            position += 2
        }
        let record = TransferRecord(
            identifier: identifier, kind: kind, state: .waiting, url: url, method: method,
            file: FilePath(FileDirectory(rawValue: directory), path), title: title, options: options
        )
        let part = kind == .download ? Self.partsDirectory + "/" + identifier + ".part" : target
        transfers.append(Kept(record: record, headers: pairs, completionMessage: completionMessage,
                              validator: nil, target: target, part: part, endedAt: nil))
        save()
        let fields = record.fields
        let launch = launch
        Self.deliver {
            held.take()?.didStart(fields)
            // Not before the app has heard of it.
            let instance = HostTransfers.instance
            guard instance.launch == launch, let index = instance.index(of: identifier) else { return }
            instance.run(index)
        }
    }

    public func list(_ callback: any TransferCallback) {
        prune()
        var all: [String] = []
        for kept in transfers {
            all += kept.record.fields
        }
        let fields = all
        let held = MainThreadHeld(callback)
        Self.deliver {
            held.take()?.didList(fields)
        }
    }

    public func pause(_ identifier: String) {
        guard let index = index(of: identifier) else { return }
        let state = transfers[index].record.state
        guard state == .waiting || state == .running else { return }
        stopEngine(index)
        // An upload keeps nothing: it starts again.
        if transfers[index].record.kind == .upload {
            transfers[index].record.bytesTransferred = 0
        }
        change(index) { $0.record.state = .paused }
    }

    public func resume(_ identifier: String) {
        guard let index = index(of: identifier), transfers[index].record.state == .paused else { return }
        change(index) { $0.record.state = .waiting }
        run(index)
    }

    public func cancel(_ identifier: String) {
        guard let index = index(of: identifier), !transfers[index].record.state.isFinished else { return }
        stopEngine(index)
        if transfers[index].record.kind == .download {
            Self.removeFile(transfers[index].part)
        }
        end(index, .cancelled, error: nil)
    }

    public func remove(_ identifier: String) {
        guard let index = index(of: identifier), transfers[index].record.state.isFinished else { return }
        transfers.remove(at: index)
        save()
        delegate?.didRemove(identifier)
    }

    public func setDelegate(_ delegate: (any TransfersDelegate)?) {
        self.delegate = delegate
    }

    // MARK: Running

    /// Hands a transfer that's waiting to its engine.
    private func run(_ index: Int) {
        let kept = transfers[index]
        let engine = kept.continuesInBackground ? Self.backgroundEngine : Self.engine
        guard let engine else {
            end(index, .failed, error: kept.continuesInBackground ? .notAllowedInBackground : .unavailable)
            return
        }
        var offset: Int64 = 0
        if kept.record.kind == .download {
            Self.makeDirectory(Self.partsDirectory)
            offset = Self.size(of: kept.part) ?? 0
            if offset == 0 {
                // An empty part file holds nothing to go on from.
                transfers[index].validator = nil
            }
            if transfers[index].record.bytesTransferred != offset {
                transfers[index].record.bytesTransferred = offset
            }
        }
        let token = nextToken
        nextToken += 1
        tokens[kept.record.identifier] = token
        let job = TransferJob(
            identifier: kept.record.identifier,
            kind: kept.record.kind,
            url: kept.record.url,
            method: kept.record.method,
            headers: kept.headers,
            file: kept.part,
            offset: offset,
            validator: offset > 0 ? transfers[index].validator : nil,
            allowsExpensiveNetwork: kept.record.options & TransferOptions.avoidsExpensiveNetworkBit == 0,
            isDiscretionary: kept.record.options & TransferOptions.isDiscretionaryBit != 0,
            title: kept.record.title
        )
        engine.start(job, reporter: TransferReporter(identifier: kept.record.identifier, token: token))
    }

    private func stopEngine(_ index: Int) {
        let identifier = transfers[index].record.identifier
        guard tokens.removeValue(forKey: identifier) != nil else { return }
        let engine = transfers[index].continuesInBackground ? Self.backgroundEngine : Self.engine
        engine?.stop(identifier)
        pendingProgress.remove(identifier)
    }

    /// What an engine said, on the main thread.
    func engineReported(_ identifier: String, token: Int, _ report: TransferReporter.Report) {
        guard tokens[identifier] == token, let index = index(of: identifier),
              !transfers[index].record.state.isFinished, transfers[index].record.state != .paused else {
            return
        }
        switch report {
        case .waiting:
            change(index) { $0.record.state = .waiting }
        case .response(let status, let contentType, let suggestedFileName, let expectedBytes, let validator, let startsOver):
            change(index) { kept in
                kept.record.state = .running
                kept.record.statusCode = status
                kept.record.contentType = contentType ?? ""
                kept.record.suggestedFileName = suggestedFileName ?? ""
                if let expectedBytes, expectedBytes >= 0 {
                    kept.record.bytesExpected = expectedBytes
                }
                if startsOver {
                    kept.record.bytesTransferred = 0
                }
                if validator != nil || startsOver {
                    kept.validator = validator
                }
            }
        case .progress(let bytes, let expectedBytes):
            if transfers[index].record.state != .running {
                change(index) { $0.record.state = .running }
            }
            transfers[index].record.bytesTransferred = max(bytes, 0)
            if let expectedBytes, expectedBytes >= 0 {
                transfers[index].record.bytesExpected = expectedBytes
            }
            tellProgress(identifier)
        case .finished(let error):
            tokens[identifier] = nil
            finish(index, error)
        }
    }

    private func finish(_ index: Int, _ error: TransferError?) {
        let kept = transfers[index]
        if let error {
            if kept.record.kind == .download {
                Self.removeFile(kept.part)
            }
            end(index, error == .cancelled ? .cancelled : .failed, error: error == .cancelled ? nil : error)
            return
        }
        // Only a success is a file.
        let status = kept.record.statusCode ?? 0
        guard (200...299).contains(status) else {
            if kept.record.kind == .download {
                Self.removeFile(kept.part)
            }
            end(index, .failed, error: .httpStatus(status))
            return
        }
        if kept.record.kind == .download {
            do throws(TransferError) {
                try Self.move(kept.part, to: kept.target)
            } catch {
                Self.removeFile(kept.part)
                end(index, .failed, error: error)
                return
            }
            if transfers[index].record.bytesExpected == nil {
                transfers[index].record.bytesExpected = transfers[index].record.bytesTransferred
            }
        }
        end(index, .completed, error: nil)
        if kept.continuesInBackground, !isInFront, !kept.completionMessage.isEmpty {
            Self.notifier?(kept.record.identifier, kept.record.title, kept.completionMessage)
        }
    }

    private func end(_ index: Int, _ state: TransferState, error: TransferError?) {
        change(index) { kept in
            kept.record.state = state
            kept.record.error = state == .failed ? (error ?? .unknown) : nil
            kept.endedAt = Self.clock().timeIntervalSince1970
        }
    }

    /// Changes a transfer, keeps it, and tells the guest at once.
    private func change(_ index: Int, _ body: (inout Kept) -> Void) {
        body(&transfers[index])
        let identifier = transfers[index].record.identifier
        pendingProgress.remove(identifier)
        lastProgress[identifier] = Self.clock()
        save()
        delegate?.didChange(transfers[index].record.fields)
    }

    /// Tells the guest how far a transfer has got, at most four times a
    /// second. What's held back is told when the time comes.
    private func tellProgress(_ identifier: String) {
        let now = Self.clock()
        if let last = lastProgress[identifier], now.timeIntervalSince(last) < Self.progressInterval {
            guard !pendingProgress.contains(identifier) else { return }
            pendingProgress.insert(identifier)
            let launch = launch
            let wait = Self.progressInterval - now.timeIntervalSince(last)
            Self.after(max(wait, 0)) {
                let instance = HostTransfers.instance
                guard instance.launch == launch, instance.pendingProgress.remove(identifier) != nil,
                      let index = instance.index(of: identifier) else { return }
                instance.lastProgress[identifier] = HostTransfers.clock()
                instance.delegate?.didChange(instance.transfers[index].record.fields)
            }
            return
        }
        lastProgress[identifier] = now
        guard let index = index(of: identifier) else { return }
        delegate?.didChange(transfers[index].record.fields)
    }

    // MARK: Keeping

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let path = Self.storagePath, let data = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode([Kept].self, from: data) else {
            return
        }
        transfers = stored
        var restart: [String] = []
        for index in transfers.indices where !transfers[index].record.state.isFinished {
            if transfers[index].record.kind == .download {
                transfers[index].record.bytesTransferred = Self.size(of: transfers[index].part) ?? 0
            } else if transfers[index].record.state != .paused {
                transfers[index].record.bytesTransferred = 0
            }
            if transfers[index].record.state == .paused {
                continue
            }
            if transfers[index].continuesInBackground, Self.backgroundEngine != nil {
                // The system carried it on: its engine goes on as it was.
                restart.append(transfers[index].record.identifier)
            } else {
                // It stopped when the app did.
                transfers[index].record.state = .paused
            }
        }
        prune()
        save()
        for identifier in restart {
            if let index = index(of: identifier) {
                run(index)
            }
        }
    }

    /// Forgets transfers that ended longer ago than `retention`.
    private func prune() {
        let oldest = Self.clock().timeIntervalSince1970 - Self.retention
        let gone = transfers.filter { ($0.endedAt ?? .infinity) < oldest }.map(\.record.identifier)
        guard !gone.isEmpty else { return }
        transfers.removeAll { gone.contains($0.record.identifier) }
        save()
        for identifier in gone {
            delegate?.didRemove(identifier)
        }
    }

    private func save() {
        guard let path = Self.storagePath, let data = try? JSONEncoder().encode(transfers) else { return }
        Self.makeDirectory((path as NSString).deletingLastPathComponent)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: Checks and files

    static func isWebURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else {
            return false
        }
        return true
    }

    /// An HTTP token: a method, or a header's name.
    static func isToken(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9":
                return true
            default:
                return "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
            }
        }
    }

    /// The file a transfer reaches, checked as `Files` checks it.
    static func resolve(_ kind: TransferKind, _ directory: Int32, _ path: String) throws(TransferError) -> String {
        let found: String
        do throws(FileError) {
            found = try HostFiles.path(of: directory, path: path, writing: kind == .download)
        } catch {
            if error == .invalidPath {
                throw .invalidRequest
            }
            throw kind == .upload ? .fileNotFound : .fileNotWritable
        }
        switch kind {
        case .upload:
            guard HostFiles.kind(ofItemAt: found) == .file else { throw .fileNotFound }
        case .download:
            guard !path.isEmpty, HostFiles.kind(ofItemAt: found) != .directory else { throw .fileNotWritable }
            do throws(FileError) {
                try HostFiles.makeDirectories(aboveFile: found)
            } catch {
                throw error == .outOfSpace ? .outOfSpace : .fileNotWritable
            }
        }
        return found
    }

    /// Puts a whole download in place, over whatever was there: a rename,
    /// or a copy where the two are on different volumes.
    static func move(_ part: String, to target: String) throws(TransferError) {
        if kind(of: part) == nil {
            // Nothing came: an empty file.
            FileManager.default.createFile(atPath: part, contents: Data())
        }
        do throws(FileError) {
            try HostFiles.makeDirectories(aboveFile: target)
        } catch {
            throw error == .outOfSpace ? .outOfSpace : .fileNotWritable
        }
        if rename(part, target) == 0 {
            return
        }
        guard errno == EXDEV else {
            throw errno == ENOSPC ? .outOfSpace : .fileNotWritable
        }
        do throws(FileError) {
            try HostFiles.copy(file: part, to: target)
        } catch {
            throw error == .outOfSpace ? .outOfSpace : .fileNotWritable
        }
        removeFile(part)
    }

    static func kind(of path: String) -> FileKind? {
        HostFiles.kind(ofItemAt: path)
    }

    static func size(of path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    static func removeFile(_ path: String) {
        unlink(path)
    }

    static func makeDirectory(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}

/// The transfers contract (`DynamicTransfers`) for any host written in
/// Swift.
///
/// ```swift
/// HostTransfers.storagePath = support + "/transfers.json"
/// HostTransfersModule.register(in: runtime)
/// ```
public enum HostTransfersModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [TransfersProxy.descriptor, TransferCallbackProxy.descriptor, TransfersDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        TransfersProxy.register(HostTransfers.self, in: registrar)
        TransferCallbackProxy.registerInterface(in: registrar)
        TransfersDelegateProxy.registerInterface(in: registrar)
    }
}
