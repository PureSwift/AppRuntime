import Testing
import DynamicFiles
import DynamicRuntime
import DynamicTransfers
import RuntimeNative

/// The test's host: it answers as the test says, and tells the guest what
/// the test says changed.
final class ScriptedTransfers: Transfers {

    nonisolated(unsafe) static let instance = ScriptedTransfers()

    var starts: [(kind: Int32, url: String, method: String, headers: [String], directory: Int32, path: String,
                  title: String, message: String, options: Int32)] = []

    var pending: [any TransferCallback] = []

    var delegate: (any TransfersDelegate)?

    var paused: [String] = []
    var resumed: [String] = []
    var cancelled: [String] = []
    var removed: [String] = []

    static func shared() -> ScriptedTransfers { instance }

    func reset() {
        starts = []
        pending = []
        paused = []
        resumed = []
        cancelled = []
        removed = []
    }

    func start(_ kind: Int32, url: String, method: String, headers: [String], directory: Int32, path: String,
               title: String, completionMessage: String, options: Int32, callback: any TransferCallback) {
        starts.append((kind, url, method, headers, directory, path, title, completionMessage, options))
        pending.append(callback)
    }

    func list(_ callback: any TransferCallback) {
        pending.append(callback)
    }

    func pause(_ identifier: String) { paused.append(identifier) }
    func resume(_ identifier: String) { resumed.append(identifier) }
    func cancel(_ identifier: String) { cancelled.append(identifier) }
    func remove(_ identifier: String) { removed.append(identifier) }

    func setDelegate(_ delegate: (any TransfersDelegate)?) {
        self.delegate = delegate
    }

    /// The oldest callback waiting.
    func answer() -> any TransferCallback {
        pending.removeFirst()
    }
}

final class Counter: @unchecked Sendable {
    var count = 0
}

func record(_ id: String, state: TransferState = .waiting, kind: TransferKind = .download, bytes: Int64 = 0,
            expected: Int64? = nil, status: Int? = nil, error: TransferError? = nil) -> TransferRecord {
    TransferRecord(identifier: id, kind: kind, state: state, url: "https://example.com/\(id)", method: "GET",
                   file: .documents / id, title: "Title \(id)", options: 0, bytesTransferred: bytes,
                   bytesExpected: expected, statusCode: status, contentType: status == nil ? "" : "text/plain",
                   suggestedFileName: status == nil ? "" : "\(id).txt", error: error)
}

/// Pins the transfers contract's names, keys and wire signatures, and the
/// guest's `TransferManager` and `Transfer` against a host the test
/// scripts. Serialized: the tests share the native runtime and the one
/// manager.
@Suite(.serialized) struct DynamicTransfersTests {

    let host = ScriptedTransfers.instance

    let manager = TransferManager.shared

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        TransfersProxy.register(ScriptedTransfers.self, in: native)
        TransferCallbackProxy.registerInterface(in: native)
        TransfersDelegateProxy.registerInterface(in: native)
        host.reset()
        manager.onChange(nil)
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    /// A started transfer, as the host answered.
    func started(_ id: String, state: TransferState = .waiting) throws -> Transfer {
        var result: Result<Transfer, TransferError>?
        manager.download(TransferRequest(url: "https://example.com/\(id)"), to: .documents / id,
                         options: TransferOptions(title: "Title \(id)")) { result = $0 }
        host.answer().didStart(record(id, state: state).fields)
        return try #require(try result?.get())
    }

    // MARK: The contract

    @Test func contract() {
        let transfers = TransfersProxy.descriptor
        #expect(transfers.name == "org.pureswift.transfers.Transfers")
        #expect(transfers.capability == .network)
        #expect(method(transfers, "shared") == MethodDescriptor("shared", "()O", .constructor))
        #expect(method(transfers, "start:url:method:headers:directory:path:title:completionMessage:options:callback:")?.signature
            == Signature("(IOOOIOOOIO)V"))
        #expect(method(transfers, "list:")?.signature == Signature("(O)V"))
        #expect(method(transfers, "pause:")?.signature == Signature("(O)V"))
        #expect(method(transfers, "setDelegate:")?.signature == Signature("(O)V"))
        #expect(transfers.methods.count == 8)
        #expect(TransferCallbackProxy.descriptor.name == "org.pureswift.transfers.TransferCallback")
        #expect(method(TransferCallbackProxy.descriptor, "didFail:message:")?.signature == Signature("(IO)V"))
        #expect(TransfersDelegateProxy.descriptor.methods.count == 2)
        let all = [TransfersProxy.descriptor, TransferCallbackProxy.descriptor, TransfersDelegateProxy.descriptor]
        #expect(ContractMetadata.decode(all.flatMap(ContractMetadata.encode)) == all)
    }

    @Test func rawValues() {
        #expect(TransferKind.download.rawValue == 1)
        #expect(TransferState.cancelled.rawValue == 5)
        #expect(TransferState.allFinished == [.completed, .failed, .cancelled])
        for code in Int32(0)...10 {
            #expect(TransferError(code: code, detail: 42).code == code)
        }
        #expect(TransferError(code: 99) == .unknown)
        #expect(TransferError(code: 6, detail: 8) == .network(8))
        #expect(TransferError(code: 7, detail: 404) == .httpStatus(404))
        #expect(TransferError.httpStatus(404).detail == 404)
        let options = TransferOptions(title: "T", continuesInBackground: true, allowsExpensiveNetwork: false, isDiscretionary: true)
        #expect(options.bits == 7)
        #expect(TransferOptions(title: "T", bits: 7) == options)
        #expect(TransferOptions().bits == 0)
        #expect(TransferOptions().allowsExpensiveNetwork)
        #expect(TransferRequest(url: "u").method(for: .download) == "GET")
        #expect(TransferRequest(url: "u").method(for: .upload) == "POST")
        #expect(TransferRequest(url: "u", method: "PUT").method(for: .upload) == "PUT")
        #expect(TransferRequest(url: "u", headers: ["b": "2", "a": "1"]).headerList == ["a", "1", "b", "2"])
    }

    @Test func records() {
        let full = record("one", state: .failed, bytes: 10, expected: 20, status: 500, error: .httpStatus(500))
        #expect(full.fields.count == TransferRecord.fieldCount)
        #expect(TransferRecord(fields: full.fields[...]) == full)
        let bare = record("two")
        #expect(bare.fields[10] == "" && bare.fields[11] == "" && bare.fields[14] == "")
        #expect(TransferRecord(fields: bare.fields[...]) == bare)
        #expect(TransferRecord.records(full.fields + bare.fields + ["stray"]) == [full, bare])
        // What isn't a record.
        #expect(TransferRecord(fields: ["x"][...]) == nil)
        var noID = bare.fields
        noID[0] = ""
        #expect(TransferRecord(fields: noID[...]) == nil)
        // A newer host's kind and state.
        var newer = bare.fields
        newer[1] = "9"
        newer[2] = "42"
        newer[14] = "77"
        let read = TransferRecord(fields: newer[...])
        #expect(read?.kind == .download)
        #expect(read?.state == .waiting)
        #expect(read?.error == .unknown)
    }

    // MARK: The manager

    @Test func startingADownload() throws {
        var result: Result<Transfer, TransferError>?
        let options = TransferOptions(title: "Map", continuesInBackground: true, allowsExpensiveNetwork: false,
                                      completionMessage: "Ready")
        manager.download(TransferRequest(url: "https://example.com/map", headers: ["Accept": "*/*"]),
                         to: .documents / "maps/map", options: options) { result = $0 }
        let start = try #require(host.starts.last)
        #expect(start.kind == 1)
        #expect(start.url == "https://example.com/map")
        #expect(start.method == "GET")
        #expect(start.headers == ["Accept", "*/*"])
        #expect(start.directory == FileDirectory.documents.rawValue)
        #expect(start.path == "maps/map")
        #expect(start.title == "Map")
        #expect(start.message == "Ready")
        #expect(start.options == 3)
        #expect(result == nil, "not until the host has taken it on")
        host.answer().didStart(record("map").fields)
        let transfer = try #require(try result?.get())
        #expect(transfer.id == "map")
        #expect(transfer.kind == .download)
        #expect(transfer.request.headers == ["Accept": "*/*"], "as it was started")
        #expect(transfer.options == options)
        #expect(transfer.file == .documents / "map")
        #expect(transfer.state == .waiting)
        #expect(manager.transfer(withID: "map") === transfer)
    }

    @Test func refused() throws {
        var result: Result<Transfer, TransferError>?
        manager.upload(file: .caches / "x", with: TransferRequest(url: "https://example.com/u")) { result = $0 }
        #expect(host.starts.last?.kind == 2)
        #expect(host.starts.last?.method == "POST")
        let callback = host.answer()
        callback.didFail(9, message: "no")
        // Only the first answer counts.
        callback.didStart(record("late").fields)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error == .notAllowedInBackground)
        #expect(manager.transfer(withID: "late") == nil)
    }

    @Test func aTransferFollowsTheHost() throws {
        let transfer = try started("follow")
        let counter = Counter()
        withObservationTracking {
            _ = transfer.fractionCompleted
        } onChange: {
            counter.count += 1
        }
        #expect(transfer.fractionCompleted == nil, "nil until the size is known")
        let delegate = try #require(host.delegate)
        delegate.didChange(record("follow", state: .running, bytes: 250, expected: 1000, status: 200).fields)
        #expect(counter.count == 1)
        #expect(transfer.state == .running)
        #expect(transfer.bytesTransferred == 250)
        #expect(transfer.bytesExpected == 1000)
        #expect(transfer.fractionCompleted == 0.25)
        #expect(transfer.response == TransferResponse(statusCode: 200, contentType: "text/plain", suggestedFileName: "follow.txt"))
        #expect(transfer.error == nil)

        // A view that read the state alone isn't told of progress.
        let states = Counter()
        withObservationTracking {
            _ = transfer.state
        } onChange: {
            states.count += 1
        }
        delegate.didChange(record("follow", state: .running, bytes: 500, expected: 1000, status: 200).fields)
        #expect(states.count == 0)
        delegate.didChange(record("follow", state: .completed, bytes: 1000, expected: 1000, status: 200).fields)
        #expect(states.count == 1)
        #expect(transfer.fractionCompleted == 1)

        // It ends once: a word after that is a stale one.
        delegate.didChange(record("follow", state: .running, bytes: 3, status: 200).fields)
        #expect(transfer.state == .completed)
        #expect(transfer.bytesTransferred == 1000)
    }

    @Test func whatTheAppDoes() throws {
        let transfer = try started("acts")
        transfer.pause()
        transfer.resume()
        transfer.cancel()
        #expect(host.paused == ["acts"])
        #expect(host.resumed == ["acts"])
        #expect(host.cancelled == ["acts"])
        // Removing one that hasn't ended does nothing.
        transfer.remove()
        #expect(host.removed.isEmpty)
        host.delegate?.didChange(record("acts", state: .cancelled).fields)
        transfer.remove()
        #expect(host.removed == ["acts"])
        #expect(manager.transfer(withID: "acts") == nil)
    }

    @Test func finished() throws {
        let done = try started("done")
        var outcomes: [Result<TransferResponse?, TransferError>] = []
        done.finished { outcomes.append($0) }
        done.finished { outcomes.append($0) }
        #expect(outcomes.isEmpty)
        host.delegate?.didChange(record("done", state: .completed, bytes: 5, expected: 5, status: 200).fields)
        #expect(outcomes.count == 2)
        #expect(try outcomes[0].get()?.statusCode == 200)
        // After the end, at once.
        done.finished { outcomes.append($0) }
        #expect(outcomes.count == 3)

        let failed = try started("failed")
        var failure: TransferError?
        failed.finished { if case .failure(let error) = $0 { failure = error } }
        host.delegate?.didChange(record("failed", state: .failed, status: 404, error: .httpStatus(404)).fields)
        #expect(failure == .httpStatus(404))
        #expect(failed.error == .httpStatus(404))

        let cancelled = try started("cancelled")
        var cancellation: TransferError?
        cancelled.finished { if case .failure(let error) = $0 { cancellation = error } }
        host.delegate?.didChange(record("cancelled", state: .cancelled).fields)
        #expect(cancellation == .cancelled)
        #expect(cancelled.error == nil, "cancelled isn't failed")

        // Removed by the host before this side saw it end.
        let gone = try started("gone")
        var lost: TransferError?
        gone.finished { if case .failure(let error) = $0 { lost = error } }
        host.delegate?.didRemove("gone")
        #expect(lost == .unknown)
        #expect(manager.transfer(withID: "gone") == nil)
    }

    @Test func allOfThem() throws {
        let kept = try started("kept")
        _ = try started("dropped")
        var result: Result<[Transfer], TransferError>?
        manager.all { result = $0 }
        host.answer().didList(record("kept", state: .running).fields + record("found", state: .completed, status: 200).fields)
        let all = try #require(try result?.get())
        #expect(all.map(\.id) == ["kept", "found"])
        #expect(all[0] === kept, "the same object, brought up to date")
        #expect(kept.state == .running)
        #expect(all[1].state == .completed)
        #expect(all[1].request.headers.isEmpty, "the host keeps the headers")
        #expect(all[1].options.title == "Title found")
        #expect(manager.transfer(withID: "dropped") == nil, "what the host no longer has is gone")
    }

    @Test func changes() throws {
        let one = try started("one")
        var heard: [String] = []
        manager.onChange { heard.append($0.id) }
        host.delegate?.didChange(record("one", state: .running).fields)
        host.delegate?.didChange(record("new", state: .running).fields)
        #expect(heard == ["one", "new"])
        #expect(manager.transfer(withID: "new") != nil, "one this side hadn't heard of")
        #expect(one.state == .running)
        // What isn't a record is dropped.
        host.delegate?.didChange(["x"])
        #expect(heard.count == 2)
        manager.onChange(nil)
        host.delegate?.didChange(record("one", state: .paused).fields)
        #expect(heard.count == 2)
        #expect(one.state == .paused)
    }

    #if !EMBEDDED_NO_CONCURRENCY
    @Test @MainActor func async() async throws {
        let task = Task { @MainActor in
            try await TransferManager.shared.download(TransferRequest(url: "https://example.com/a"), to: .caches / "a")
        }
        while ScriptedTransfers.instance.pending.isEmpty {
            await Task.yield()
        }
        ScriptedTransfers.instance.answer().didStart(record("a").fields)
        let transfer = try await task.value
        let waiting = Task { @MainActor in try await transfer.finished() }
        await Task.yield()
        ScriptedTransfers.instance.delegate?.didChange(record("a", state: .completed, status: 204).fields)
        #expect(try await waiting.value?.statusCode == 204)

        let stream = TransferManager.shared.changes
        ScriptedTransfers.instance.delegate?.didChange(record("b", state: .running).fields)
        for await changed in stream {
            #expect(changed.id == "b")
            break
        }
    }
    #endif
}
