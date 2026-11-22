import DynamicTransfers
import Foundation

/// A `TransferEngine` with a server the test scripts, byte by byte, and
/// no network.
///
/// ```swift
/// let engine = MemoryTransferEngine()
/// engine.serve("https://example.com/map", bytes: Array(repeating: 7, count: 1000))
/// HostTransfers.engine = engine
/// // … the guest starts a download …
/// engine.send(identifier, bytes: 400)
/// engine.complete(identifier)
/// ```
///
/// Nothing moves until the test says so. It reports synchronously, on the
/// calling thread: tests set `HostTransfers.deliver` to run at once.
public final class MemoryTransferEngine: TransferEngine, @unchecked Sendable {

    public struct Resource: Equatable, Sendable {
        public var bytes: [UInt8]
        public var status: Int
        public var contentType: String?
        public var suggestedFileName: String?
        /// What the server calls this version of the file.
        public var etag: String?
        /// Whether the server answers a range request with the rest.
        public var honorsRanges: Bool

        public init(bytes: [UInt8], status: Int = 200, contentType: String? = nil, suggestedFileName: String? = nil,
                    etag: String? = nil, honorsRanges: Bool = true) {
            self.bytes = bytes
            self.status = status
            self.contentType = contentType
            self.suggestedFileName = suggestedFileName
            self.etag = etag
            self.honorsRanges = honorsRanges
        }
    }

    /// What the server has, by URL.
    public var resources: [String: Resource] = [:]

    /// Every job started, in order.
    public private(set) var started: [TransferJob] = []

    /// Every job stopped, by identifier, in order.
    public private(set) var stopped: [String] = []

    /// What uploads sent, by URL.
    public private(set) var received: [String: [UInt8]] = [:]

    private struct Run {
        var job: TransferJob
        var reporter: TransferReporter
        var responded = false
        /// Where the bytes sent so far end, in the resource.
        var position = 0
        var body: [UInt8] = []
    }

    private var runs: [String: Run] = [:]

    public init() { }

    public func serve(_ url: String, bytes: [UInt8], status: Int = 200, contentType: String? = nil,
                      suggestedFileName: String? = nil, etag: String? = nil, honorsRanges: Bool = true) {
        resources[url] = Resource(bytes: bytes, status: status, contentType: contentType,
                                  suggestedFileName: suggestedFileName, etag: etag, honorsRanges: honorsRanges)
    }

    /// The jobs running now, by identifier.
    public var running: [String] {
        runs.keys.sorted()
    }

    // MARK: TransferEngine

    public func start(_ job: TransferJob, reporter: TransferReporter) {
        started.append(job)
        var run = Run(job: job, reporter: reporter)
        if job.kind == .upload {
            run.body = FileManager.default.contents(atPath: job.file).map { [UInt8]($0) } ?? []
        }
        runs[job.identifier] = run
    }

    public func stop(_ identifier: String) {
        guard runs.removeValue(forKey: identifier) != nil else { return }
        stopped.append(identifier)
    }

    // MARK: What the test does

    /// The job has to wait: no network.
    public func wait(_ identifier: String) {
        runs[identifier]?.reporter.waiting()
    }

    /// The server answers, if it hasn't, and `bytes` more of the body move.
    public func send(_ identifier: String, bytes: Int) {
        guard var run = runs[identifier] else { return }
        respondIfNeeded(&run)
        guard runs[identifier] != nil else { return }
        switch run.job.kind {
        case .download:
            let resource = resources[run.job.url] ?? Resource(bytes: [], status: 404)
            let end = min(run.position + max(bytes, 0), resource.bytes.count)
            if end > run.position, (200...299).contains(resource.status) {
                append(Array(resource.bytes[run.position..<end]), to: run.job.file)
            }
            run.position = end
            runs[identifier] = run
            run.reporter.progress(Int64(end))
        case .upload:
            let end = min(run.position + max(bytes, 0), run.body.count)
            run.position = end
            runs[identifier] = run
            run.reporter.progress(Int64(end), expectedBytes: Int64(run.body.count))
        }
    }

    /// Everything left moves, and the job ends.
    public func complete(_ identifier: String) {
        guard var run = runs[identifier] else { return }
        respondIfNeeded(&run)
        let remaining: Int
        switch run.job.kind {
        case .download: remaining = (resources[run.job.url]?.bytes.count ?? 0) - run.position
        case .upload: remaining = run.body.count - run.position
        }
        if remaining > 0 {
            runs[identifier] = run
            send(identifier, bytes: remaining)
        }
        guard let finished = runs.removeValue(forKey: identifier) else { return }
        if finished.job.kind == .upload {
            received[finished.job.url] = finished.body
        }
        finished.reporter.finished(nil)
    }

    /// The job fails.
    public func fail(_ identifier: String, _ error: TransferError) {
        guard let run = runs.removeValue(forKey: identifier) else { return }
        run.reporter.finished(error)
    }

    /// Completes every job running.
    public func completeAll() {
        for identifier in running {
            complete(identifier)
        }
    }

    private func respondIfNeeded(_ run: inout Run) {
        guard !run.responded else { return }
        run.responded = true
        let job = run.job
        switch job.kind {
        case .upload:
            let resource = resources[job.url]
            run.reporter.response(status: resource?.status ?? 200, contentType: resource?.contentType)
        case .download:
            guard let resource = resources[job.url] else {
                run.reporter.response(status: 404)
                return
            }
            guard (200...299).contains(resource.status) else {
                run.reporter.response(status: resource.status, contentType: resource.contentType)
                return
            }
            // A range is the rest only if the file is the one the part holds.
            let goesOn = job.offset > 0 && resource.honorsRanges && job.validator != nil && job.validator == resource.etag
                && Int(job.offset) <= resource.bytes.count
            if goesOn {
                run.position = Int(job.offset)
            } else {
                run.position = 0
                FileManager.default.createFile(atPath: job.file, contents: Data())
            }
            run.reporter.response(status: goesOn ? 206 : resource.status, contentType: resource.contentType,
                                  suggestedFileName: resource.suggestedFileName,
                                  expectedBytes: Int64(resource.bytes.count), validator: resource.etag,
                                  startsOver: job.offset > 0 && !goesOn)
        }
        runs[job.identifier] = run
    }

    private func append(_ bytes: [UInt8], to path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(bytes))
    }
}
