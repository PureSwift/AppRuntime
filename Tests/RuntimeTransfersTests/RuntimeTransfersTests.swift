import DynamicFiles
import DynamicRuntime
import DynamicTransfers
import Foundation
import RuntimeHost
import RuntimeNative
import Testing
@testable import RuntimeTransfers

/// The transfers contract's rules, over `MemoryTransferEngine`, on macOS
/// and Linux. Serialized: the tests share `HostTransfers`, `HostFiles` and
/// the native runtime.
extension TransferHostTests {

@Suite(.serialized) struct RuntimeTransfersTests {

    // MARK: Module

    @Test func registersEveryContract() {
        #expect(HostTransfersModule.contracts.map(\.name) == [
            "org.pureswift.transfers.Transfers", "org.pureswift.transfers.TransferCallback",
            "org.pureswift.transfers.TransfersDelegate",
        ])
        #expect(TransfersProxy.descriptor.capability == .network)
        #expect(HostTransfersModule.permissionProviders().isEmpty)
    }

    // MARK: Downloads

    @Test func aDownloadToTheEnd() throws {
        let fixture = try TransferFixture()
        let map = bytes(1000)
        fixture.engine.serve("https://example.com/map", bytes: map, contentType: "application/octet-stream",
                             suggestedFileName: "berlin.tiles", etag: "\"v1\"")
        let callback = fixture.start(headers: ["Authorization", "Bearer 123", "Accept", "*/*"])
        #expect(callback.answers == 1)
        let started = try #require(callback.started)
        #expect(started.state == .waiting)
        #expect(started.kind == .download)
        #expect(started.url == "https://example.com/map")
        #expect(started.method == "GET")
        #expect(started.file == .documents / "maps/berlin.tiles")
        #expect(started.title == "Berlin map")
        #expect(started.bytesTransferred == 0)
        #expect(started.bytesExpected == nil)
        #expect(started.statusCode == nil)
        let id = started.identifier

        // Handed to the engine after the app heard of it, to a part file of the host's.
        let job = try #require(fixture.engine.started.first)
        #expect(job.identifier == id)
        #expect(job.headers == [TransferHeader("Authorization", "Bearer 123"), TransferHeader("Accept", "*/*")])
        #expect(job.file == fixture.root.appendingPathComponent("Host/Parts/\(id).part").path)
        #expect(job.offset == 0)
        #expect(job.validator == nil)
        #expect(job.allowsExpensiveNetwork)
        #expect(fixture.delegate.changes.isEmpty, "nothing before the engine says so")

        fixture.engine.send(id, bytes: 400)
        #expect(fixture.record(id)?.state == .running)
        #expect(fixture.record(id)?.bytesTransferred == 400)
        #expect(fixture.record(id)?.bytesExpected == 1000)
        #expect(fixture.record(id)?.statusCode == 200)
        #expect(fixture.record(id)?.suggestedFileName == "berlin.tiles")
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == nil, "not there until it's whole")

        fixture.engine.complete(id)
        let done = try #require(fixture.record(id))
        #expect(done.state == .completed)
        #expect(done.bytesTransferred == 1000)
        #expect(done.error == nil)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == map)
        #expect(fixture.parts.isEmpty)
        #expect(fixture.delegate.states(id) == [.running, .completed])
        #expect(fixture.delegate.changes.last?.contentType == "application/octet-stream")

        // It ends once: an engine's word after that is ignored.
        fixture.engine.send(id, bytes: 1)
        fixture.host.pause(id)
        fixture.host.cancel(id)
        #expect(fixture.record(id)?.state == .completed)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == map)
    }

    @Test func aFileThereIsReplacedOnlyAtTheEnd() throws {
        let fixture = try TransferFixture()
        try fixture.write([9, 9, 9], "Caches", "feed.json")
        fixture.engine.serve("https://example.com/feed", bytes: bytes(50, from: 1))
        let id = try #require(fixture.start(url: "https://example.com/feed", to: .caches / "feed.json").started).identifier
        fixture.engine.send(id, bytes: 20)
        #expect(fixture.contents("Caches", "feed.json") == [9, 9, 9])
        fixture.engine.complete(id)
        #expect(fixture.contents("Caches", "feed.json") == bytes(50, from: 1))
    }

    @Test func onlyASuccessIsAFile() throws {
        let fixture = try TransferFixture()
        try fixture.write([9], "Documents", "page.html")
        fixture.engine.serve("https://example.com/missing", bytes: Array("Not found".utf8), status: 404, contentType: "text/html")
        let id = try #require(fixture.start(url: "https://example.com/missing", to: .documents / "page.html").started).identifier
        fixture.engine.complete(id)
        let failed = try #require(fixture.record(id))
        #expect(failed.state == .failed)
        #expect(failed.error == .httpStatus(404))
        #expect(failed.statusCode == 404)
        #expect(fixture.contents("Documents", "page.html") == [9], "an error page is never saved")
        #expect(fixture.parts.isEmpty)
    }

    @Test func aFailureLeavesNothing() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: bytes(100))
        let id = try #require(fixture.start().started).identifier
        fixture.engine.send(id, bytes: 30)
        fixture.engine.fail(id, .network(8))
        let failed = try #require(fixture.record(id))
        #expect(failed.state == .failed)
        #expect(failed.error == .network(8))
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == nil)
        #expect(fixture.parts.isEmpty)
        // The record carries it.
        #expect(TransferRecord(fields: failed.fields[...])?.error == .network(8))
    }

    @Test func waitingForANetwork() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: bytes(10))
        let id = try #require(fixture.start().started).identifier
        fixture.engine.send(id, bytes: 5)
        fixture.engine.wait(id)
        #expect(fixture.record(id)?.state == .waiting)
        fixture.engine.complete(id)
        #expect(fixture.delegate.states(id) == [.running, .waiting, .running, .completed])
    }

    // MARK: Pausing

    @Test func pausedAndResumedFromWhereItStopped() throws {
        let fixture = try TransferFixture()
        let map = bytes(1000)
        fixture.engine.serve("https://example.com/map", bytes: map, etag: "\"v1\"")
        let id = try #require(fixture.start().started).identifier
        fixture.engine.send(id, bytes: 400)
        fixture.host.pause(id)
        #expect(fixture.record(id)?.state == .paused)
        #expect(fixture.record(id)?.bytesTransferred == 400)
        #expect(fixture.engine.stopped == [id])
        #expect(fixture.parts == ["\(id).part"], "it keeps what it has")

        // The engine's word from the run it stopped says nothing.
        #expect(fixture.engine.running.isEmpty)

        fixture.host.resume(id)
        #expect(fixture.record(id)?.state == .waiting)
        let job = try #require(fixture.engine.started.last)
        #expect(job.offset == 400)
        #expect(job.validator == "\"v1\"")
        fixture.engine.send(id, bytes: 100)
        #expect(fixture.record(id)?.bytesTransferred == 500)
        fixture.engine.complete(id)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == map)
        #expect(fixture.delegate.states(id) == [.running, .paused, .waiting, .running, .completed])

        // Pausing and resuming what isn't moving does nothing.
        fixture.host.resume(id)
        fixture.host.pause(id)
        #expect(fixture.record(id)?.state == .completed)
        #expect(fixture.engine.started.count == 2)
    }

    @Test func aServerThatSendsEverythingAgain() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: bytes(100), etag: "\"v1\"")
        let id = try #require(fixture.start().started).identifier
        fixture.engine.send(id, bytes: 60)
        fixture.host.pause(id)
        // The file changed under the same URL.
        let new = bytes(80, from: 50)
        fixture.engine.serve("https://example.com/map", bytes: new, etag: "\"v2\"")
        fixture.host.resume(id)
        fixture.engine.send(id, bytes: 10)
        #expect(fixture.record(id)?.bytesTransferred == 10, "bytesTransferred went back")
        #expect(fixture.record(id)?.bytesExpected == 80)
        fixture.engine.complete(id)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == new)

        // One that ignores ranges starts again too.
        fixture.engine.serve("https://example.com/plain", bytes: bytes(40), etag: "\"p\"", honorsRanges: false)
        let plain = try #require(fixture.start(url: "https://example.com/plain", to: .caches / "plain").started).identifier
        fixture.engine.send(plain, bytes: 30)
        fixture.host.pause(plain)
        fixture.host.resume(plain)
        fixture.engine.complete(plain)
        #expect(fixture.contents("Caches", "plain") == bytes(40))
    }

    @Test func cancelledLeavesNothing() throws {
        let fixture = try TransferFixture()
        try fixture.write([1], "Documents", "maps/berlin.tiles")
        fixture.engine.serve("https://example.com/map", bytes: bytes(100))
        let id = try #require(fixture.start().started).identifier
        fixture.engine.send(id, bytes: 30)
        fixture.host.cancel(id)
        #expect(fixture.record(id)?.state == .cancelled)
        #expect(fixture.record(id)?.error == nil)
        #expect(fixture.engine.stopped == [id])
        #expect(fixture.parts.isEmpty)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == [1], "what was there stays")
        // A paused one can be cancelled, and one that ended can't.
        fixture.engine.serve("https://example.com/other", bytes: bytes(10))
        let other = try #require(fixture.start(url: "https://example.com/other", to: .caches / "other").started).identifier
        fixture.host.pause(other)
        fixture.host.cancel(other)
        #expect(fixture.record(other)?.state == .cancelled)
        fixture.host.resume(other)
        #expect(fixture.record(other)?.state == .cancelled)
    }

    // MARK: Uploads

    @Test func anUpload() throws {
        let fixture = try TransferFixture()
        let photo = bytes(300, from: 7)
        try fixture.write(photo, "Caches", "shot.jpg")
        fixture.engine.serve("https://example.com/upload", bytes: [], status: 201)
        let id = try #require(fixture.start(.upload, url: "https://example.com/upload",
                                            headers: ["Content-Type", "image/jpeg"], to: .caches / "shot.jpg").started).identifier
        let job = try #require(fixture.engine.started.first)
        #expect(job.kind == .upload)
        #expect(job.method == "POST")
        #expect(job.file == fixture.url("Caches", "shot.jpg").path)
        fixture.engine.send(id, bytes: 100)
        #expect(fixture.record(id)?.bytesTransferred == 100)
        #expect(fixture.record(id)?.bytesExpected == 300)
        // Pausing an upload keeps nothing: it starts again.
        fixture.host.pause(id)
        #expect(fixture.record(id)?.bytesTransferred == 0)
        fixture.host.resume(id)
        #expect(fixture.engine.started.last?.offset == 0)
        fixture.engine.complete(id)
        #expect(fixture.record(id)?.state == .completed)
        #expect(fixture.record(id)?.statusCode == 201)
        #expect(fixture.engine.received["https://example.com/upload"] == photo)
        #expect(fixture.contents("Caches", "shot.jpg") == photo, "the file is the app's still")

        fixture.engine.serve("https://example.com/refused", bytes: [], status: 500)
        let refused = try #require(fixture.start(.upload, url: "https://example.com/refused", to: .caches / "shot.jpg").started).identifier
        fixture.engine.complete(refused)
        #expect(fixture.record(refused)?.error == .httpStatus(500))
    }

    // MARK: Refusals

    @Test func whatTheHostRefuses() throws {
        let fixture = try TransferFixture(background: false)
        func refusal(_ callback: RecordingCallback) -> TransferError? {
            #expect(callback.answers == 1)
            #expect(callback.started == nil)
            return callback.failure
        }
        #expect(refusal(fixture.start(url: "ftp://example.com/map")) == .invalidRequest)
        #expect(refusal(fixture.start(url: "https:///map")) == .invalidRequest)
        #expect(refusal(fixture.start(url: "not a url")) == .invalidRequest)
        #expect(refusal(fixture.start(method: "GE T")) == .invalidRequest)
        #expect(refusal(fixture.start(method: "")) == .invalidRequest)
        #expect(refusal(fixture.start(headers: ["Accept"])) == .invalidRequest)
        #expect(refusal(fixture.start(headers: ["Bad Name", "x"])) == .invalidRequest)
        #expect(refusal(fixture.start(to: .documents / "../escape")) == .invalidRequest)
        #expect(refusal(fixture.start(to: .bundle / "map")) == .fileNotWritable)
        #expect(refusal(fixture.start(to: FilePath(.documents))) == .fileNotWritable, "a directory isn't a file")
        #expect(refusal(fixture.start(.upload, url: "https://example.com/upload", to: .caches / "missing.jpg")) == .fileNotFound)
        #expect(refusal(fixture.start(options: TransferOptions(continuesInBackground: true))) == .notAllowedInBackground,
                "a host that can't carry it on refuses it rather than run it in front")
        #expect(fixture.host.transfers.isEmpty)
        #expect(fixture.engine.started.isEmpty)

        HostTransfers.engine = nil
        #expect(refusal(fixture.start()) == .unavailable)
    }

    @Test func whereATransferCarriedOnMayGo() throws {
        let fixture = try TransferFixture()
        let carried = TransferOptions(title: "Map", continuesInBackground: true)
        let refused = fixture.start(to: .temporary / "map", options: carried)
        #expect(refused.failure == .notAllowedInBackground)
        let grant = HostFiles.grant(HostFiles.Grant(path: fixture.root.appendingPathComponent("Data").path, kind: .directory, isWritable: true))
        defer { HostFiles.revoke(grant) }
        #expect(fixture.start(to: FilePath(grant, "picked.bin"), options: carried).failure == .notAllowedInBackground)
        #expect(fixture.start(to: FilePath(grant, "picked.bin")).started != nil, "in front, wherever Files can write")
        for directory in [FileDirectory.documents, .data, .caches] {
            fixture.background.serve("https://example.com/map", bytes: [1])
            #expect(fixture.start(to: FilePath(directory, "map"), options: carried).started != nil)
        }
        // Each goes to the engine that carries transfers on.
        #expect(fixture.background.started.count == 3)
        #expect(fixture.engine.started.count == 1)
    }

    // MARK: Progress

    @Test func progressAtMostFourTimesASecond() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: bytes(100))
        let id = try #require(fixture.start().started).identifier
        // The response is told at once; the bytes right after it wait for
        // the quarter to be up.
        fixture.engine.send(id, bytes: 10)
        let told = fixture.delegate.changes.count
        #expect(fixture.delegate.changes.last?.state == .running)
        #expect(fixture.delegate.changes.last?.bytesTransferred == 0)
        fixture.now += 0.1
        fixture.engine.send(id, bytes: 10)
        fixture.engine.send(id, bytes: 10)
        #expect(fixture.delegate.changes.count == told)
        #expect(fixture.later.count == 1, "one timer for what's held back")
        #expect(abs((fixture.later.first?.seconds ?? 0) - 0.25) < 0.001)
        fixture.now += 0.15
        fixture.runLater()
        #expect(fixture.delegate.changes.count == told + 1)
        #expect(fixture.delegate.changes.last?.bytesTransferred == 30)
        // After the quarter, at once.
        fixture.now += 0.3
        fixture.engine.send(id, bytes: 10)
        #expect(fixture.delegate.changes.last?.bytesTransferred == 40)
        // A change of state is told at once, with what's held back.
        fixture.now += 0.01
        fixture.engine.send(id, bytes: 10)
        fixture.host.pause(id)
        #expect(fixture.delegate.changes.last?.state == .paused)
        #expect(fixture.delegate.changes.last?.bytesTransferred == 50)
        fixture.runLater()
        #expect(fixture.delegate.changes.last?.state == .paused, "nothing after the pause")
    }

    // MARK: The next launch

    @Test func whatTheNextLaunchFinds() throws {
        let fixture = try TransferFixture()
        let map = bytes(200)
        fixture.engine.serve("https://example.com/map", bytes: map, etag: "\"v1\"")
        fixture.engine.serve("https://example.com/done", bytes: [1, 2, 3])
        fixture.background.serve("https://example.com/carried", bytes: bytes(50))
        let cut = try #require(fixture.start().started).identifier
        let done = try #require(fixture.start(url: "https://example.com/done", to: .caches / "done").started).identifier
        let carried = try #require(fixture.start(url: "https://example.com/carried", to: .data / "carried",
                                                 options: TransferOptions(title: "Carried", continuesInBackground: true)).started).identifier
        fixture.engine.send(cut, bytes: 80)
        fixture.engine.complete(done)
        fixture.background.send(carried, bytes: 20)

        // The app stops; the system carries one transfer on.
        fixture.relaunch()
        let list = RecordingCallback()
        fixture.host.list(list)
        let records = try #require(list.listed)
        #expect(records.map(\.identifier) == [cut, done, carried], "oldest first")
        #expect(records[0].state == .paused, "it stopped when the app did")
        #expect(records[0].bytesTransferred == 80, "with what it had")
        #expect(records[1].state == .completed)
        #expect(records[2].state == .running)
        // The engine that carries it on is told again, and goes on as it was.
        #expect(fixture.background.started.map(\.identifier) == [carried, carried])
        #expect(fixture.background.started.last?.offset == 20)

        // The cut one goes on from where it stopped.
        fixture.host.resume(cut)
        #expect(fixture.engine.started.last?.offset == 80)
        fixture.engine.complete(cut)
        #expect(fixture.contents("Documents", "maps/berlin.tiles") == map)

        // Headers and the completion message aren't given back.
        #expect(records[0].fields.count == TransferRecord.fieldCount)
    }

    @Test func endedTransfersAreKeptThirtyDays() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: [1])
        let old = try #require(fixture.start().started).identifier
        fixture.engine.complete(old)
        fixture.now += 29 * 24 * 3600
        let kept = RecordingCallback()
        fixture.host.list(kept)
        #expect(kept.listed?.map(\.identifier) == [old])
        fixture.now += 2 * 24 * 3600
        let gone = RecordingCallback()
        fixture.host.list(gone)
        #expect(gone.listed?.isEmpty == true)
        #expect(fixture.delegate.removed == [old])
        // And at the next launch.
        fixture.relaunch()
        let after = RecordingCallback()
        fixture.host.list(after)
        #expect(after.listed?.isEmpty == true)
    }

    @Test func removing() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: [1])
        let moving = try #require(fixture.start().started).identifier
        fixture.host.remove(moving)
        #expect(fixture.record(moving) != nil, "one still moving is left")
        fixture.engine.complete(moving)
        fixture.host.remove(moving)
        #expect(fixture.record(moving) == nil)
        #expect(fixture.delegate.removed == [moving])
        fixture.relaunch()
        #expect(fixture.host.transfers.isEmpty)
    }

    @Test func theAppStopping() throws {
        let fixture = try TransferFixture()
        fixture.engine.serve("https://example.com/map", bytes: bytes(10))
        fixture.background.serve("https://example.com/carried", bytes: bytes(10))
        let front = try #require(fixture.start().started).identifier
        let carried = try #require(fixture.start(url: "https://example.com/carried", to: .data / "c",
                                                 options: TransferOptions(continuesInBackground: true)).started).identifier
        HostTransfers.applicationWillTerminate()
        #expect(fixture.record(front)?.state == .paused)
        #expect(fixture.record(carried)?.state == .waiting)
        #expect(fixture.engine.stopped == [front])
        #expect(fixture.background.stopped.isEmpty)
    }

    @Test func aNotificationWhenTheAppIsAway() throws {
        let fixture = try TransferFixture()
        fixture.background.serve("https://example.com/a", bytes: [1])
        fixture.background.serve("https://example.com/b", bytes: [1])
        fixture.engine.serve("https://example.com/c", bytes: [1])
        let options = TransferOptions(title: "Map", continuesInBackground: true, completionMessage: "Your map is ready")
        let inFront = try #require(fixture.start(url: "https://example.com/a", to: .data / "a", options: options).started).identifier
        fixture.background.complete(inFront)
        #expect(fixture.notified.isEmpty, "the app is in front")
        HostTransfers.applicationDidEnterBackground()
        let away = try #require(fixture.start(url: "https://example.com/b", to: .data / "b", options: options).started).identifier
        let front = try #require(fixture.start(url: "https://example.com/c", to: .data / "c",
                                               options: TransferOptions(title: "C", completionMessage: "Done")).started).identifier
        fixture.background.complete(away)
        fixture.engine.complete(front)
        #expect(fixture.notified.map(\.identifier) == [away])
        #expect(fixture.notified.first?.title == "Map")
        #expect(fixture.notified.first?.message == "Your map is ready")
        HostTransfers.applicationWillEnterForeground()
    }

    // MARK: Through the contract

    @Test func throughTheContracts() throws {
        let fixture = try TransferFixture()
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostTransfersModule.register(in: native)
        fixture.engine.serve("https://example.com/map", bytes: bytes(20))
        let host = TransfersProxy.shared()
        let delegate = RecordingDelegate()
        host.setDelegate(delegate)
        let callback = RecordingCallback()
        host.start(1, url: "https://example.com/map", method: "GET", headers: ["Accept", "*/*"], directory: 0,
                   path: "map", title: "Map", completionMessage: "", options: 0, callback: callback)
        let id = try #require(callback.started?.identifier)
        fixture.engine.complete(id)
        #expect(delegate.states(id) == [.running, .completed])
        let list = RecordingCallback()
        host.list(list)
        #expect(list.listed?.first?.state == .completed)
        host.remove(id)
        #expect(delegate.removed == [id])
        #expect(fixture.contents("Documents", "map") == bytes(20))
    }
}
}
