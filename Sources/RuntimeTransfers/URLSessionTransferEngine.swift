import DynamicNetworking
import DynamicTransfers
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RuntimeNetworking

/// A `TransferEngine` over one `URLSession`, in the host's process: for
/// transfers that run while the app does, on Apple platforms and Linux.
///
/// A download is written to its part file as it arrives. One that goes on
/// asks for the rest with `Range` and `If-Range`; a server that answers
/// with everything instead empties the part file and starts over. An
/// answer outside 200 to 299 isn't written at all. A challenge, other than
/// for the server's own certificate, fails the transfer: there may be
/// nobody to ask.
public final class URLSessionTransferEngine: NSObject, TransferEngine, @unchecked Sendable {

    private let configuration: URLSessionConfiguration

    private let lock = NSLock()

    private var made: URLSession?

    /// The jobs running, by their task's identifier.
    private var running: [Int: Running] = [:]

    /// The task for each job, by the job's identifier.
    private var tasks: [String: URLSessionTask] = [:]

    private final class Running {
        let job: TransferJob
        let reporter: TransferReporter
        var handle: FileHandle?
        /// Where the file's bytes begin counting: the offset the server
        /// went on from, or 0.
        var base: Int64 = 0
        var written: Int64 = 0
        /// The server's status was outside 200 to 299, or it asked for
        /// credentials: the task was cancelled for that.
        var rejected: TransferError??
        var writeFailed: TransferError?

        init(job: TransferJob, reporter: TransferReporter) {
            self.job = job
            self.reporter = reporter
        }
    }

    /// `configuration` is copied. Tests give one whose protocol classes
    /// answer without a network.
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let made {
            return made
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "org.pureswift.runtime.transfers"
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        made = session
        return session
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: TransferEngine

    public func start(_ job: TransferJob, reporter: TransferReporter) {
        guard let url = URL(string: job.url) else {
            reporter.finished(.invalidRequest)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = job.method
        for header in job.headers {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        #if canImport(Darwin)
        request.allowsExpensiveNetworkAccess = job.allowsExpensiveNetwork
        #endif
        let task: URLSessionTask
        switch job.kind {
        case .download:
            if job.offset > 0 {
                request.setValue("bytes=\(job.offset)-", forHTTPHeaderField: "Range")
                if let validator = job.validator {
                    request.setValue(validator, forHTTPHeaderField: "If-Range")
                }
            }
            task = session.dataTask(with: request)
        case .upload:
            task = session.uploadTask(with: request, fromFile: URL(fileURLWithPath: job.file))
        }
        let run = Running(job: job, reporter: reporter)
        locked {
            // A job started again replaces its last run.
            if let old = tasks[job.identifier] {
                running[old.taskIdentifier] = nil
                old.cancel()
            }
            running[task.taskIdentifier] = run
            tasks[job.identifier] = task
        }
        task.resume()
    }

    public func stop(_ identifier: String) {
        let stopped: (URLSessionTask, Running?)? = locked {
            guard let task = tasks.removeValue(forKey: identifier) else { return nil }
            return (task, running.removeValue(forKey: task.taskIdentifier))
        }
        guard let (task, run) = stopped else { return }
        task.cancel()
        try? run?.handle?.close()
    }

    private func run(for task: URLSessionTask) -> Running? {
        locked { running[task.taskIdentifier] }
    }

    private func finish(_ task: URLSessionTask) -> Running? {
        locked {
            guard let run = running.removeValue(forKey: task.taskIdentifier) else { return nil }
            if tasks[run.job.identifier] === task {
                tasks[run.job.identifier] = nil
            }
            return run
        }
    }

    // MARK: Responses

    /// The whole file's size, from a `Content-Range` such as
    /// `bytes 100-999/1000`.
    static func total(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...])
    }

    fileprivate func received(_ response: URLResponse, for task: URLSessionTask) -> Bool {
        guard let run = run(for: task) else { return false }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let headers = http?.allHeaderFields ?? [:]
        func header(_ name: String) -> String? {
            for (key, value) in headers {
                if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                    return value as? String
                }
            }
            return nil
        }
        let validator = header("ETag") ?? header("Last-Modified")
        guard (200...299).contains(status) else {
            run.reporter.response(status: status, contentType: response.mimeType, suggestedFileName: nil)
            run.rejected = .some(nil)
            return false
        }
        switch run.job.kind {
        case .upload:
            run.reporter.response(status: status, contentType: response.mimeType, suggestedFileName: nil,
                                  expectedBytes: nil, validator: nil)
        case .download:
            let goesOn = run.job.offset > 0 && status == 206
            run.base = goesOn ? run.job.offset : 0
            var expected: Int64?
            if goesOn {
                expected = Self.total(fromContentRange: header("Content-Range"))
            }
            if expected == nil, response.expectedContentLength >= 0 {
                expected = run.base + response.expectedContentLength
            }
            if !FileManager.default.fileExists(atPath: run.job.file) {
                FileManager.default.createFile(atPath: run.job.file, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: run.job.file) else {
                run.writeFailed = .fileNotWritable
                return false
            }
            do {
                if goesOn {
                    try handle.seekToEnd()
                } else {
                    try handle.truncate(atOffset: 0)
                }
            } catch {
                run.writeFailed = .fileNotWritable
                return false
            }
            run.handle = handle
            run.reporter.response(status: status, contentType: response.mimeType,
                                  suggestedFileName: response.suggestedFilename, expectedBytes: expected,
                                  validator: validator, startsOver: run.job.offset > 0 && !goesOn)
        }
        return true
    }

    fileprivate func received(_ data: Data, for task: URLSessionTask) {
        guard let run = run(for: task), let handle = run.handle, run.writeFailed == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            run.writeFailed = (error as NSError).code == Int(ENOSPC) ? .outOfSpace : .fileNotWritable
            task.cancel()
            return
        }
        run.written += Int64(data.count)
        run.reporter.progress(run.base + run.written)
    }

    fileprivate func sent(_ total: Int64, of expected: Int64, for task: URLSessionTask) {
        guard let run = run(for: task) else { return }
        run.reporter.progress(total, expectedBytes: expected >= 0 ? expected : nil)
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        // A task stopped by the host says nothing more.
        guard let run = finish(task) else { return }
        try? run.handle?.close()
        if let failure = run.writeFailed {
            run.reporter.finished(failure)
        } else if let rejected = run.rejected {
            // The server's status, which the host judges, or its challenge.
            run.reporter.finished(rejected)
        } else if let error {
            let code = NetworkError(urlSessionError: error)
            run.reporter.finished(code == .cancelled ? .cancelled : .network(code.rawValue))
        } else {
            run.reporter.finished(nil)
        }
    }

    fileprivate func challenged(_ challenge: URLAuthenticationChallenge, for task: URLSessionTask) -> Bool {
        // The server's own certificate is the platform's to judge.
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no constant for it.
        let serverTrust = "NSURLAuthenticationMethodServerTrust"
        #else
        let serverTrust = NSURLAuthenticationMethodServerTrust
        #endif
        guard challenge.protectionSpace.authenticationMethod != serverTrust else {
            return true
        }
        run(for: task)?.rejected = .some(.authenticationRequired)
        return false
    }
}

extension URLSessionTransferEngine: URLSessionDataDelegate {

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(received(response, for: dataTask) ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received(data, for: dataTask)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        sent(totalBytesSent, of: totalBytesExpectedToSend, for: task)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completed(task, error: error)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenged(challenge, for: task) ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
