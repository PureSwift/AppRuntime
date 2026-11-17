import Foundation
import Testing
import CRuntime
import DynamicCoreModel
import DynamicUI
import RuntimeABI
import RuntimeCoreModel
import RuntimeHost
import RuntimeNative

/// `ExampleModel`'s library with the shared host adapter keeping its store
/// in CoreModel's in-memory backend: CoreModel and `RuntimeModelStorage`
/// in an Embedded guest, `Query`, the `ModelStore` contracts and
/// `HostModelStore`, as a native slice or through wasm2c (see
/// `Package.swift`). A linked app starts once per process, so the earlier
/// launches are objects already in the store. Part of `LinkedSliceTests`,
/// which is serialized, since both use `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleModel: Bool {
        #if LINKED_EXAMPLEMODEL
        true
        #else
        false
        #endif
    }

    /// What the to-do screen shows.
    struct TodoScreen: Equatable {
        var summary: String?
        /// The to-dos' buttons, in order.
        var todos: [String]
        var status: String?
    }

    func todos(_ renderer: TestRenderer) -> TodoScreen {
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
    func tap(_ title: String, _ renderer: TestRenderer) async throws {
        renderer.send(try #require(renderer.screen?.button(title), "a button titled \(title)"), .tap)
        await HostModelStore.waitUntilIdle()
    }

    @MainActor
    func add(_ title: String, _ renderer: TestRenderer) async throws {
        renderer.send(try #require(renderer.screen?.first { $0.type == "TextField" }), .change, .string(title))
        try await tap("Add", renderer)
    }

    /// The app's model, as the app declares it.
    static let todoModel = Model(entities: [
        EntityDescription(
            id: "Todo",
            attributes: [Attribute(id: "title", type: .string), Attribute(id: "isDone", type: .bool), Attribute(id: "number", type: .int64)],
            relationships: [Relationship(id: "list", type: .toOne, destinationEntity: "List", inverseRelationship: "todos")]
        ),
        EntityDescription(
            id: "List",
            attributes: [Attribute(id: "name", type: .string)],
            relationships: [Relationship(id: "todos", type: .toMany, destinationEntity: "Todo", inverseRelationship: "list")]
        ),
    ])

    /// On the main actor, where the host's answers arrive: the guest's
    /// calls and they share a thread, as in a host (§6.4).
    @MainActor
    @Test(.enabled(if: linksExampleModel, "Link ExampleModel's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleModel() async throws {
        #if LINKED_EXAMPLEMODEL
        // What earlier launches left: the lists, and a to-do that's done.
        let provider = InMemoryModelStorageProvider()
        let earlier = try await provider.open("todos", model: Self.todoModel, indexes: [:], migration: .fail)
        try await earlier.insert(ModelData(entity: "List", id: "home", attributes: ["name": .string("Home")]))
        try await earlier.insert(ModelData(entity: "List", id: "work", attributes: ["name": .string("Work")]))
        try await earlier.insert(ModelData(
            entity: "Todo", id: "todo-7",
            attributes: ["title": .string("Water plants"), "isDone": .bool(true), "number": .int64(7)],
            relationships: ["list": .toOne("home")]
        ))

        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        HostModelStore.configure(.init(provider: provider))
        HostModelStoreModule.register(in: native)
        TestRenderer.last = nil

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        await HostModelStore.waitUntilIdle()
        let renderer = try #require(TestRenderer.last)
        #expect(todos(renderer) == TodoScreen(summary: "Home 1, Work 0", todos: ["Done: Water plants"], status: ""))
        let stored = try #require(await provider.storage("todos"))
        #expect(try await stored.count(FetchRequest(entity: "List")) == 2, "it's the store that was there: no lists were made again")

        // Adding fetches the highest number so far, then inserts; both
        // queries hear of it and fetch again.
        try await add("Buy milk", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 2, Work 0", todos: ["Done: Water plants", "Buy milk"], status: "Added Buy milk"))
        try await tap("List: Home", renderer)
        try await add("Write report", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 2, Work 1", todos: ["Done: Water plants", "Buy milk", "Write report"], status: "Added Write report"))
        let report = try #require(try await stored.fetch("Todo", for: "todo-9"))
        #expect(report.attributes["title"] == .string("Write report"))
        #expect(report.attributes["isDone"] == .bool(false))
        #expect(report.attributes["number"] == .int64(9))
        #expect(report.relationships["list"] == .toOne("work"))
        try await tap("Add", renderer)
        #expect(todos(renderer).status == "A to-do needs a title.")

        // An insert of one property over the object.
        try await tap("Buy milk", renderer)
        #expect(todos(renderer).todos == ["Done: Water plants", "Done: Buy milk", "Write report"])
        let milk = try #require(try await stored.fetch("Todo", for: "todo-8"))
        #expect(milk.attributes["isDone"] == .bool(true))
        #expect(milk.attributes["title"] == .string("Buy milk"), "left as it was")
        try await tap("Done: Buy milk", renderer)

        // The query's predicate changes, and it fetches again.
        try await tap("Show: all", renderer)
        #expect(todos(renderer).todos == ["Buy milk", "Write report"])
        try await tap("Show: open", renderer)
        #expect(todos(renderer).todos == ["Done: Water plants", "Buy milk", "Write report"])

        // `async`/`await` in the guest, and a predicate through the relationship.
        try await tap("Count open", renderer)
        #expect(todos(renderer).status == "1 open in Work")
        try await tap("List: Work", renderer)
        try await tap("Count open", renderer)
        #expect(todos(renderer).status == "1 open in Home")

        try await tap("Clear done", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 1, Work 1", todos: ["Buy milk", "Write report"], status: "Cleared 1"))
        try await tap("Delete Buy milk", renderer)
        #expect(todos(renderer) == TodoScreen(summary: "Home 0, Work 1", todos: ["Write report"], status: "Deleted Buy milk"))
        #expect(try await stored.fetchID(FetchRequest(entity: "Todo")) == ["todo-9"])
        #endif
    }
}
