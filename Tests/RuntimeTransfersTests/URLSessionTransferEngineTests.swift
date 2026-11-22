import DynamicFiles
import DynamicNetworking
import DynamicTransfers
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RuntimeHost
import Testing
@testable import RuntimeTransfers

/// `URLSessionTransferEngine` under `HostTransfers`, against a server with
/// no network, on macOS and Linux. Its callbacks arrive on a queue of the
/// session's and reach the host through `deliver`, on the main thread,
/// where the tests wait for them. Serialized, with the other suite's
/// shared state.
extension TransferHostTests {

@MainActor
@Suite(.serialized) struct URLSessionTransferEngineTests {

    let fixture: TransferFixture

    let engine: URLSessionTransferEngine

    init() throws {
        fixture = try TransferFixture(background: false)
        TransferURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        engine = URLSessionTransferEngine(configuration: configuration)
        HostTransfers.engine = engine
        HostTransfers.deliver = { DispatchQueue.main.async(execute: $0) }
        HostTransfers.after = { seconds, work in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
    }

    func started(_ callback: RecordingCallback) async throws -> String {
        await waitUntil { callback.answers > 0 }
        return try #require(callback.started?.identifier)
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func ended(_ identifier: String) async -> TransferRecord? {
        await waitUntil { fixture.record(identifier)?.state.isFinished == true }
        return fixture.record(identifier)
    }

    @Test func aWholeDownload() async throws {
        let map = bytes(5000, from: 3)
        TransferURLProtocol.serve("/map", .init(bytes: map, etag: "\"v1\"", contentType: "application/x-tiles",
                                                disposition: "attachment; filename=\"berlin.tiles\""))
        let id = try await started(fixture.start(url: "https://example.com/map", headers: ["X-Token", "secret"]))
        let done = try #require(await ended(id))
        #expect(done.state == .completed)
        #expect(done.statusCode == 200)
        #expect(done.bytesTransferred == 5000)
        #expect(done.bytesExpected == 5000)
        #expect(done.contentType == "application/x-tiles")
        #expect(done.suggestedFileName == "berlin.tiles")
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == map)
        #expect(fixture.parts.isEmpty)
        #expect(TransferURLProtocol.received.first?.headers["X-Token"] == "secret")
        #expect(TransferURLProtocol.received.first?.headers["Range"] == nil)
        #expect(fixture.host.transfers.first?.validator == "\"v1\"")
    }

    /// What a paused download held is asked for no more: the server sends
    /// the rest.
    @Test func goingOnFromWhereItStopped() async throws {
        let map = bytes(3000, from: 9)
        // Begun by an engine the test drives, which stops after 1000 bytes.
        let memory = MemoryTransferEngine()
        memory.serve("https://example.com/map", bytes: map, etag: "\"v1\"")
        HostTransfers.engine = memory
        let id = try await started(fixture.start(url: "https://example.com/map"))
        memory.send(id, bytes: 1000)
        await waitUntil { fixture.record(id)?.bytesTransferred == 1000 }
        fixture.host.pause(id)

        HostTransfers.engine = engine
        TransferURLProtocol.serve("/map", .init(bytes: map, etag: "\"v1\""))
        fixture.host.resume(id)
        let done = try #require(await ended(id))
        #expect(done.state == .completed)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == map)
        let request = try #require(TransferURLProtocol.received.last)
        #expect(request.headers["Range"] == "bytes=1000-")
        #expect(request.headers["If-Range"] == "\"v1\"")
        #expect(done.bytesExpected == 3000)
        #expect(done.bytesTransferred == 3000)
    }

    @Test func aServerThatChangedTheFile() async throws {
        let memory = MemoryTransferEngine()
        memory.serve("https://example.com/map", bytes: bytes(3000), etag: "\"v1\"")
        HostTransfers.engine = memory
        let id = try await started(fixture.start(url: "https://example.com/map"))
        memory.send(id, bytes: 1000)
        await waitUntil { fixture.record(id)?.bytesTransferred == 1000 }
        fixture.host.pause(id)

        // The file under the URL is another one now: everything comes again.
        HostTransfers.engine = engine
        let new = bytes(2000, from: 77)
        TransferURLProtocol.serve("/map", .init(bytes: new, etag: "\"v2\""))
        fixture.host.resume(id)
        let done = try #require(await ended(id))
        #expect(done.state == .completed)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == new)
        #expect(done.bytesExpected == 2000)
    }

    @Test func anErrorStatusIsNotWritten() async throws {
        try fixture.write([5], "Documents", "maps/berlin.tiles")
        let id = try await started(fixture.start(url: "https://example.com/nothing-here"))
        let done = try #require(await ended(id))
        #expect(done.state == .failed)
        #expect(done.error == .httpStatus(404))
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == [5])
        #expect(fixture.parts.isEmpty)
    }

    @Test func anUploadFromAFile() async throws {
        let photo = bytes(4000, from: 1)
        try fixture.write(photo, "Caches", "shot.jpg")
        TransferURLProtocol.serve("/upload", .init(bytes: [], status: 201))
        let id = try await started(fixture.start(.upload, url: "https://example.com/upload", method: "PUT",
                                                 headers: ["Content-Type", "image/jpeg"], to: .caches / "shot.jpg"))
        let done = try #require(await ended(id))
        #expect(done.state == .completed)
        #expect(done.statusCode == 201)
        let request = try #require(TransferURLProtocol.received.first)
        #expect(request.path == "/upload")
        #expect(request.headers["Content-Type"] == "image/jpeg")
        #if !canImport(FoundationNetworking)
        // swift-corelibs-foundation doesn't hand an upload task's file to a
        // `URLProtocol`, so the body is seen on Apple platforms alone.
        #expect(request.body == photo)
        #endif
    }

    @Test func aNetworkThatFails() async throws {
        TransferURLProtocol.serve("/map", .init(bytes: [], failure: .notConnectedToInternet))
        let id = try await started(fixture.start(url: "https://example.com/map"))
        let done = try #require(await ended(id))
        #expect(done.state == .failed)
        #expect(done.error == .network(NetworkError.notConnectedToInternet.rawValue))
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == nil)
    }

    @Test func cancelledInFlight() async throws {
        TransferURLProtocol.serve("/map", .init(bytes: bytes(200_000), delay: 0.3))
        let id = try await started(fixture.start(url: "https://example.com/map"))
        await waitUntil { !TransferURLProtocol.received.isEmpty }
        fixture.host.cancel(id)
        #expect(fixture.record(id)?.state == .cancelled)
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(fixture.record(id)?.state == .cancelled, "nothing after the cancel")
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == nil)
        #expect(fixture.parts.isEmpty)
    }

    @Test func contentRange() {
        #expect(URLSessionTransferEngine.total(fromContentRange: "bytes 100-999/1000") == 1000)
        #expect(URLSessionTransferEngine.total(fromContentRange: "bytes 100-999/*") == nil)
        #expect(URLSessionTransferEngine.total(fromContentRange: nil) == nil)
    }
}
}
