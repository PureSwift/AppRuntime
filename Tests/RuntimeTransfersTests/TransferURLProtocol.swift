import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A server with no network, for `URLSessionTransferEngine`: files by URL
/// path, which it answers as an HTTP server would, ranges included.
final class TransferURLProtocol: URLProtocol, @unchecked Sendable {

    struct File {
        var bytes: [UInt8]
        var status = 200
        var etag: String?
        var honorsRanges = true
        var contentType = "application/octet-stream"
        var disposition: String?
        /// Fails the request with this instead of answering.
        var failure: URLError.Code?
        /// Seconds before the answer begins.
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()

    nonisolated(unsafe) private static var files: [String: File] = [:]

    nonisolated(unsafe) private static var requests: [(path: String, headers: [String: String], body: [UInt8])] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        files = [:]
        requests = []
    }

    static func serve(_ path: String, _ file: File) {
        lock.lock(); defer { lock.unlock() }
        files[path] = file
    }

    /// What reached the server.
    static var received: [(path: String, headers: [String: String], body: [UInt8])] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopLock = NSLock()

    nonisolated(unsafe) private var stopped = false

    override func stopLoading() {
        stopLock.lock(); defer { stopLock.unlock() }
        stopped = true
    }

    private var isStopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    private var body: [UInt8] {
        if let body = request.httpBody {
            return [UInt8](body)
        }
        guard let stream = request.httpBodyStream else { return [] }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return bytes
    }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        let headers = request.allHTTPHeaderFields ?? [:]
        let body = self.body
        let file: File? = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.requests.append((path, headers, body))
            return Self.files[path]
        }()
        guard let file else {
            answer(url, status: 404, headers: ["Content-Type": "text/plain"], body: Array("Not found".utf8))
            return
        }
        if let failure = file.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var answerHeaders = ["Content-Type": file.contentType]
        if let etag = file.etag { answerHeaders["ETag"] = etag }
        if let disposition = file.disposition { answerHeaders["Content-Disposition"] = disposition }
        let sent = answerHeaders
        // A range is the rest only for the version the client holds.
        if file.honorsRanges, file.status == 200, let range = headers["Range"], range.hasPrefix("bytes="),
           let start = Int(range.dropFirst(6).dropLast()), start <= file.bytes.count,
           headers["If-Range"] == nil || headers["If-Range"] == file.etag {
            var ranged = sent
            ranged["Content-Range"] = "bytes \(start)-\(file.bytes.count - 1)/\(file.bytes.count)"
            let rest = Array(file.bytes[start...])
            let answered = ranged
            later(file.delay) { $0.answer(url, status: 206, headers: answered, body: rest) }
            return
        }
        later(file.delay) { $0.answer(url, status: file.status, headers: sent, body: file.bytes) }
    }

    /// Answers now, or after `delay` unless loading was stopped meanwhile.
    private func later(_ delay: TimeInterval, _ work: @escaping @Sendable (TransferURLProtocol) -> Void) {
        guard delay > 0 else {
            work(self)
            return
        }
        #if canImport(FoundationNetworking)
        // Loading runs on a dispatch queue here, without a run loop.
        let loader = LoaderBox(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            guard !loader.value.isStopped else { return }
            work(loader.value)
        }
        #else
        // From the loading thread's run loop.
        let timer = Timer(timeInterval: delay, repeats: false) { [self] _ in
            guard !isStopped else { return }
            work(self)
        }
        RunLoop.current.add(timer, forMode: .common)
        #endif
    }

    private func answer(_ url: URL, status: Int, headers: [String: String], body: [UInt8]) {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network would send it.
        var start = 0
        while start < body.count {
            let end = min(start + 1024, body.count)
            client?.urlProtocol(self, didLoad: Data(body[start..<end]))
            start = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A loader sent to another queue: swift-corelibs-foundation's
/// `URLProtocol` can't be `Sendable`.
private struct LoaderBox: @unchecked Sendable {
    let value: TransferURLProtocol
    init(_ value: TransferURLProtocol) { self.value = value }
}
