import DynamicRuntime
import DynamicFiles
import DynamicTransfers
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example transfers app: downloads. It lists at launch what the host
/// has, those that finished while the app was closed included, starts a
/// download in front or left to the system, and pauses, resumes, cancels
/// and removes them. The host moves every byte.

/// What the app can fetch.
struct Item {
    let title: String
    let url: String
    let file: FilePath
    let carriedOn: Bool
}

/// The closures hold the shelf, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Shelf: @unchecked Sendable {

    static let items = [
        Item(title: "Map", url: "https://example.com/maps/berlin.tiles", file: .documents / "maps/berlin.tiles", carriedOn: false),
        Item(title: "Feed", url: "https://example.com/feed.json", file: .caches / "feed.json", carriedOn: false),
        Item(title: "Podcast", url: "https://example.com/episode.mp3", file: .documents / "episode.mp3", carriedOn: true),
    ]

    /// The host's transfers, oldest first.
    var transfers: [Transfer] = []

    var status: String = "Looking"

    @ObservationIgnored let manager = TransferManager.shared

    init() {
        // A transfer this side hadn't heard of: carried on, and found.
        manager.onChange { transfer in
            if !self.transfers.contains(where: { $0 === transfer }) {
                self.transfers.append(transfer)
            }
        }
        manager.all { result in
            switch result {
            case .success(let transfers):
                self.transfers = transfers
                let finished = transfers.filter { $0.state == .completed }.count
                self.status = transfers.isEmpty ? "No transfers" : "Found \(transfers.count), \(finished) finished"
            case .failure:
                self.status = "Couldn't list them"
            }
        }
    }

    func get(_ item: Item) {
        let options = TransferOptions(title: item.title, continuesInBackground: item.carriedOn,
                                      completionMessage: item.carriedOn ? "\(item.title) is ready" : nil)
        manager.download(TransferRequest(url: item.url), to: item.file, options: options) { result in
            switch result {
            case .success(let transfer):
                if !self.transfers.contains(where: { $0 === transfer }) {
                    self.transfers.append(transfer)
                }
                self.status = "Getting \(item.title)"
            case .failure(let error):
                self.status = "Couldn't get \(item.title): \(Self.name(error))"
            }
        }
    }

    func remove(_ transfer: Transfer) {
        transfer.remove()
        transfers.removeAll { $0 === transfer }
    }

    static func name(_ state: TransferState) -> String {
        switch state {
        case .waiting: "waiting"
        case .running: "running"
        case .paused: "paused"
        case .completed: "done"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    static func name(_ error: TransferError) -> String {
        switch error {
        case .httpStatus(let status): "status \(status)"
        case .network: "no network"
        case .notAllowedInBackground: "not in the background"
        case .fileNotWritable: "can't write"
        case .outOfSpace: "no space"
        case .cancelled: "cancelled"
        default: "error \(error.code)"
        }
    }

    /// "Map: running 40%".
    static func line(_ transfer: Transfer) -> String {
        var line = "\(transfer.options.title): \(name(transfer.state))"
        if let fraction = transfer.fractionCompleted, transfer.state != .cancelled {
            line += " \(Int(fraction * 100))%"
        }
        if let error = transfer.error {
            line += " (\(name(error)))"
        }
        return line
    }
}

struct Row: View {

    let shelf: Shelf

    let transfer: Transfer

    var body: some View {
        let title = transfer.options.title
        let state = transfer.state
        return HStack(spacing: 8) {
            Text(Shelf.line(transfer))
                .accessibilityIdentifier("row-\(title)")
            if state == .running || state == .waiting {
                Button("Pause \(title)") { transfer.pause() }
            }
            if state == .paused {
                Button("Resume \(title)") { transfer.resume() }
            }
            if !state.isFinished {
                Button("Cancel \(title)") { transfer.cancel() }
            } else {
                Button("Remove \(title)") { shelf.remove(transfer) }
            }
        }
    }
}

struct ContentView: View {

    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shelf.status)
                .accessibilityIdentifier("status")
            HStack(spacing: 8) {
                Button("Get Map") { shelf.get(Shelf.items[0]) }
                Button("Get Feed") { shelf.get(Shelf.items[1]) }
                Button("Get Podcast") { shelf.get(Shelf.items[2]) }
            }
            ForEach(shelf.transfers) { transfer in
                Row(shelf: shelf, transfer: transfer)
            }
        }
        .padding()
    }
}

struct ExampleTransfersApp: App {

    let shelf = Shelf()

    var body: some Scene {
        WindowGroup {
            ContentView(shelf: shelf)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleTransfersMain() -> rt_status {
    Runtime.main { ExampleTransfersApp.run() }
}
