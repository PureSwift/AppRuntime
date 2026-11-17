import Foundation
import Testing
import DynamicCoreModel
import DynamicUI
import RuntimeABI
import RuntimeCoreModel
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// The example model app as App.wasm under WasmKit, with the shared host
/// adapter keeping its store in CoreModel's in-memory backend: CoreModel
/// and `RuntimeModelStorage` in an Embedded guest, `Query`, the
/// `ModelStore` contracts and `HostModelStore` end to end, across two
/// launches. Part of `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleModel`; skipped without it.
    static var exampleModelURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleModel/wasm32/App.wasm")
    }

    /// What the to-do screen shows.
    struct TodoScreen: Equatable {
        var summary: String?
        /// The to-dos' buttons, in order.
        var todos: [String]
        var status: String?
    }

    func todos(_ renderer: WasmTestRenderer) -> TodoScreen {
        let screen = renderer.screen
        var titles = [String]()
        func collect(_ node: RenderNode) {
            if node.type == "Button", let title = node.children.first?.props["text"]?.string, title.hasPrefix("Delete ") {
                titles.append(String(title.dropFirst(7)))
            }
            node.children.forEach(collect)
        }
        screen.map(collect)
        // Each to-do's own button says whether it's done.
        let shown = titles.map { screen?.button("Done: \($0)") != nil ? "Done: \($0)" : $0 }
        return TodoScreen(
            summary: screen?.identified("summary")?.props["text"]?.string,
            todos: shown,
            status: screen?.identified("status")?.props["text"]?.string
        )
    }

    /// Taps a button and waits for the store to answer everything that
    /// leads to.
    @MainActor
    func tap(_ title: String, _ renderer: WasmTestRenderer) async throws {
        renderer.send(try #require(renderer.screen?.button(title), "a button titled \(title)"), .tap)
        await HostModelStore.waitUntilIdle()
    }

    @MainActor
    func add(_ title: String, _ renderer: WasmTestRenderer) async throws {
        renderer.send(try #require(renderer.screen?.first { $0.type == "TextField" }), .change, .string(title))
        try await tap("Add", renderer)
    }

    /// The app starts: the host says where stores are kept, then loads it.
    @MainActor
    func launchExampleModel(_ provider: InMemoryModelStorageProvider) async throws -> (app: WasmApp, renderer: WasmTestRenderer) {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        HostModelStore.configure(.init(provider: provider))
        HostModelStoreModule.register(in: native)
        WasmTestRenderer.last = nil
        let bytes = Array(try Data(contentsOf: Self.exampleModelURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [])
        #expect(try app.start() == .ok)
        await HostModelStore.waitUntilIdle()
        return (app, try #require(WasmTestRenderer.last))
    }

    /// On the main actor, where the host's answers arrive: the guest's
    /// calls and they share a thread, as in a host (§6.4).
    @MainActor
    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleModelURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleModel"))
    func exampleModelInWasmMode() async throws {
        let provider = InMemoryModelStorageProvider()

        // The first launch: the app makes its two lists, in one batch.
        var (app, renderer) = try await launchExampleModel(provider)
        #expect(WasmApp.contracts(of: app.module)?.first { $0.name == "org.pureswift.data.ModelStore" }?.capability == nil)
        #expect(todos(renderer) == TodoScreen(summary: "Home 0, Work 0", todos: [], status: ""))

        // Adding fetches the highest number so far, then inserts; both
        // queries hear of it and fetch again.
        try await add("Buy milk", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 1, Work 0", todos: ["Buy milk"], status: "Added Buy milk"))
        try await tap("List: Home", renderer)
        try await add("Write report", renderer)
        try await add("File expenses", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 1, Work 2", todos: ["Buy milk", "Write report", "File expenses"], status: "Added File expenses"))
        try await tap("Add", renderer)
        #expect(todos(renderer).status == "A to-do needs a title.")

        // An insert of one property over the object.
        try await tap("Write report", renderer)
        #expect(todos(renderer).todos == ["Buy milk", "Done: Write report", "File expenses"])
        let stored = try #require(await provider.storage("todos"))
        let report = try #require(try await stored.fetch("Todo", for: "todo-2"))
        #expect(report.attributes["isDone"] == .bool(true))
        #expect(report.attributes["title"] == .string("Write report"), "left as it was")
        #expect(report.attributes["number"] == .int64(2))
        #expect(report.relationships["list"] == .toOne("work"))

        // The query's predicate changes, and it fetches again.
        try await tap("Show: all", renderer)
        #expect(todos(renderer).todos == ["Buy milk", "File expenses"])
        #expect(renderer.screen?.button("Show: open") != nil)

        // `async`/`await` in the guest, and a predicate through the relationship.
        try await tap("Count open", renderer)
        #expect(todos(renderer).status == "1 open in Work")
        try await tap("List: Work", renderer)
        try await tap("Count open", renderer)
        #expect(todos(renderer).status == "1 open in Home")

        // The second launch, in a new instance of the app: it's all there.
        (app, renderer) = try await launchExampleModel(provider)
        #expect(todos(renderer) == TodoScreen(summary: "Home 1, Work 2", todos: ["Buy milk", "Done: Write report", "File expenses"], status: ""))

        try await tap("Clear done", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 1, Work 1", todos: ["Buy milk", "File expenses"], status: "Cleared 1"))
        try await tap("Delete Buy milk", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 0, Work 1", todos: ["File expenses"], status: "Deleted Buy milk"))
        #expect(try await stored.fetchID(FetchRequest(entity: "Todo")) == ["todo-3"])
        // Numbers go on from the highest left.
        try await add("Call back", renderer)
        #expect(try await stored.fetchID(FetchRequest(entity: "Todo")) == ["todo-3", "todo-4"])
        _ = app
    }
}
