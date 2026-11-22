import DynamicFiles
import DynamicRuntime
import DynamicTransfers
import Foundation
import Testing
import RuntimeHost
@testable import RuntimeTransfers

/// Every suite of this target, one after another: they share
/// `HostTransfers`, `HostFiles` and the native runtime.
@Suite(.serialized) enum TransferHostTests { }

/// What the guest was told.
final class RecordingDelegate: TransfersDelegate {

    var changes: [TransferRecord] = []

    var removed: [String] = []

    func didChange(_ record: [String]) {
        if let record = TransferRecord(fields: record[...]) {
            changes.append(record)
        }
    }

    func didRemove(_ identifier: String) {
        removed.append(identifier)
    }

    /// The states one transfer went through, each once in a row.
    func states(_ identifier: String) -> [TransferState] {
        var states: [TransferState] = []
        for change in changes where change.identifier == identifier && states.last != change.state {
            states.append(change.state)
        }
        return states
    }
}

/// One operation's answer.
final class RecordingCallback: TransferCallback {

    var started: TransferRecord?

    var listed: [TransferRecord]?

    var failure: TransferError?

    var answers = 0

    func didStart(_ record: [String]) {
        answers += 1
        started = TransferRecord(fields: record[...])
    }

    func didList(_ records: [String]) {
        answers += 1
        listed = TransferRecord.records(records)
    }

    func didFail(_ error: Int32, message: String) {
        answers += 1
        failure = TransferError(code: error)
    }
}

/// A container in a temporary directory, the shared host over the test's
/// engines, and every answer at once.
final class TransferFixture: @unchecked Sendable {

    let root: URL

    let engine = MemoryTransferEngine()

    let background = MemoryTransferEngine()

    let delegate = RecordingDelegate()

    var now = Date(timeIntervalSince1970: 1_774_701_005)

    /// What `HostTransfers.after` was asked to run later.
    var later: [(seconds: Double, work: @Sendable () -> Void)] = []

    var notified: [(identifier: String, title: String, message: String)] = []

    init(background: Bool = true) throws {
        let manager = Foundation.FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("Transfers-\(UUID().uuidString)").resolvingSymlinksInPath()
        for name in ["Documents", "Data", "Caches", "Temporary", "Bundle", "Host/Parts"] {
            try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Documents").path,
            .data: root.appendingPathComponent("Data").path,
            .caches: root.appendingPathComponent("Caches").path,
            .temporary: root.appendingPathComponent("Temporary").path,
            .bundle: root.appendingPathComponent("Bundle").path,
        ], work: { $0() }, deliver: { $0() }))
        HostTransfers.reset()
        HostTransfers.engine = engine
        HostTransfers.backgroundEngine = background ? self.background : nil
        HostTransfers.storagePath = root.appendingPathComponent("Host/transfers.json").path
        HostTransfers.partsDirectory = root.appendingPathComponent("Host/Parts").path
        HostTransfers.deliver = { $0() }
        HostTransfers.clock = { [unowned self] in now }
        HostTransfers.after = { [unowned self] seconds, work in later.append((seconds, work)) }
        HostTransfers.notifier = { [unowned self] in notified.append(($0, $1, $2)) }
        HostTransfers.shared().setDelegate(delegate)
    }

    deinit {
        HostTransfers.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    var host: HostTransfers {
        HostTransfers.shared()
    }

    func url(_ directory: String, _ path: String) -> URL {
        root.appendingPathComponent(directory).appendingPathComponent(path)
    }

    func contents(_ directory: String, _ path: String) -> [UInt8]? {
        Foundation.FileManager.default.contents(atPath: url(directory, path).path).map { [UInt8]($0) }
    }

    func write(_ bytes: [UInt8], _ directory: String, _ path: String) throws {
        let file = url(directory, path)
        try Foundation.FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: file)
    }

    var parts: [String] {
        (try? Foundation.FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Host/Parts").path)) ?? []
    }

    /// Starts a transfer and gives the host's answer.
    @discardableResult
    func start(_ kind: TransferKind = .download, url: String = "https://example.com/map", method: String? = nil,
               headers: [String] = [], to file: FilePath = .documents / "maps/berlin.tiles",
               options: TransferOptions = TransferOptions(title: "Berlin map")) -> RecordingCallback {
        let callback = RecordingCallback()
        host.start(kind.rawValue, url: url, method: method ?? (kind == .download ? "GET" : "POST"), headers: headers,
                   directory: file.directory.rawValue, path: file.path, title: options.title,
                   completionMessage: options.completionMessage ?? "", options: options.bits, callback: callback)
        return callback
    }

    /// The record the host keeps now.
    func record(_ identifier: String) -> TransferRecord? {
        host.transfers.first { $0.record.identifier == identifier }?.record
    }

    /// What a new launch of the app finds.
    func relaunch() {
        HostTransfers.reload()
        HostTransfers.shared().setDelegate(delegate)
    }

    func runLater() {
        let work = later
        later = []
        for item in work {
            item.work()
        }
    }
}

func bytes(_ count: Int, from start: UInt8 = 0) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: Int(start) + $0) }
}
