import Foundation
import Testing
import CRuntime
import DynamicFiles
import DynamicRuntime
import DynamicTransfers
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative
import RuntimeTransfers

/// Starts a transfer from the test, as an app of the last launch did.
final class LinkedSeedCallback: TransferCallback {

    var identifier: String?

    func didStart(_ record: [String]) {
        identifier = record.first
    }

    var listed: [TransferRecord] = []

    func didList(_ records: [String]) {
        listed = TransferRecord.records(records)
    }

    func didFail(_ error: Int32, message: String) { }
}

/// The example transfers app linked into the test, with the shared
/// host over engines the test drives: the guest's `TransferManager`, the
/// `Transfers` contract and `HostTransfers`, end to end, with real files.
/// The test plays the server, and the system that carries a transfer on
/// while the app is closed. An Embedded guest, as a native slice or
/// through wasm2c (see `Package.swift`). The same checks as
/// `RuntimeWasm`'s WasmKit test. Part of `LinkedSliceTests`, which is
/// serialized, since both use `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleTransfers: Bool {
        #if LINKED_EXAMPLETRANSFERS
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: linksExampleTransfers, "Link ExampleTransfers's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleTransfers() throws {
        #if LINKED_EXAMPLETRANSFERS
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleTransfers-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        let documents = root.appendingPathComponent("Container/Documents")
        let caches = root.appendingPathComponent("Container/Caches")
        for directory in [documents, caches, root.appendingPathComponent("Host")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: documents.path,
            .caches: caches.path,
        ], work: { $0() }, deliver: { $0() }))
        let engine = MemoryTransferEngine()
        let system = MemoryTransferEngine()
        HostTransfers.reset()
        HostTransfers.engine = engine
        HostTransfers.backgroundEngine = system
        HostTransfers.storagePath = root.appendingPathComponent("Host/transfers.json").path
        HostTransfers.partsDirectory = root.appendingPathComponent("Host/Parts").path
        HostTransfers.deliver = { $0() }
        // Progress held back is told at once: the test doesn't wait.
        HostTransfers.after = { _, work in work() }
        HostTransfersModule.register(in: native)
        defer { HostTransfers.reset() }
        TestRenderer.last = nil

        let map = (0..<1000).map { UInt8(truncatingIfNeeded: $0) }
        let episode = (0..<500).map { UInt8(truncatingIfNeeded: $0 * 3) }
        engine.serve("https://example.com/maps/berlin.tiles", bytes: map, etag: "\"m1\"")
        engine.serve("https://example.com/feed.json", bytes: Array(repeating: 7, count: 300))
        engine.serve("https://example.com/old.bin", bytes: [1, 2, 3])
        system.serve("https://example.com/episode.mp3", bytes: episode, etag: "\"e1\"")

        // The last launch: an old file finished, and a podcast left to the
        // system, a fifth of the way in.
        let host = HostTransfers.shared()
        let old = LinkedSeedCallback()
        host.start(1, url: "https://example.com/old.bin", method: "GET", headers: [], directory: 0, path: "old.bin",
                   title: "Old", completionMessage: "", options: 0, callback: old)
        engine.complete(try #require(old.identifier))
        let carried = LinkedSeedCallback()
        host.start(1, url: "https://example.com/episode.mp3", method: "GET", headers: [], directory: 0, path: "episode.mp3",
                   title: "Podcast", completionMessage: "Podcast is ready", options: TransferOptions.continuesInBackgroundBit,
                   callback: carried)
        let podcast = try #require(carried.identifier)
        system.send(podcast, bytes: 100)
        // The app closed. The system carries the podcast on.
        HostTransfers.reload()

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        let renderer = try #require(TestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title), "\(title)"), .tap)
        }

        // What the app finds at launch.
        #expect(text("status") == "Found 2, 1 finished")
        #expect(text("row-Old") == "Old: done 100%")
        #expect(text("row-Podcast") == "Podcast: running 20%")
        #expect(system.started.last?.offset == 100, "the system's engine goes on as it was")

        // The system finishes the podcast while the app is open.
        system.complete(podcast)
        #expect(text("row-Podcast") == "Podcast: done 100%")
        #expect(manager.contents(atPath: documents.appendingPathComponent("episode.mp3").path).map { [UInt8]($0) } == episode)

        // A download in front.
        try tap("Get Map")
        #expect(text("status") == "Getting Map")
        #expect(text("row-Map") == "Map: waiting")
        let mapID = try #require(engine.started.last?.identifier)
        engine.send(mapID, bytes: 400)
        #expect(text("row-Map") == "Map: running 40%")
        try tap("Pause Map")
        #expect(text("row-Map") == "Map: paused 40%")
        try tap("Resume Map")
        #expect(text("row-Map") == "Map: waiting 40%")
        #expect(engine.started.last?.offset == 400, "from where it stopped")
        engine.complete(mapID)
        #expect(text("row-Map") == "Map: done 100%")
        #expect(manager.contents(atPath: documents.appendingPathComponent("maps/berlin.tiles").path).map { [UInt8]($0) } == map)

        // One cancelled leaves nothing.
        try tap("Get Feed")
        let feedID = try #require(engine.started.last?.identifier)
        engine.send(feedID, bytes: 100)
        #expect(text("row-Feed") == "Feed: running 33%")
        try tap("Cancel Feed")
        #expect(text("row-Feed") == "Feed: cancelled")
        #expect(!manager.fileExists(atPath: caches.appendingPathComponent("feed.json").path))

        // Removing one that ended forgets it, here and in the host.
        try tap("Remove Old")
        #expect(text("row-Old") == nil)
        let list = LinkedSeedCallback()
        host.list(list)
        #expect(list.listed.map(\.title) == ["Podcast", "Map", "Feed"])
        #endif
    }
}
