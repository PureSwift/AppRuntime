import DynamicRuntime
import DynamicCoreModel
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The example model app: to-dos in lists, kept in a model store across
/// launches. Two entities with a relationship between them, written
/// against CoreModel; two `Query`s that keep the screen current; a batch;
/// a fetch with a sort and a limit; a predicate through the relationship.

/// Entities are written by hand: CoreModel's macros are off under Embedded
/// Swift.
struct Todo: Entity {

    static var entityName: EntityName { "Todo" }

    static var attributes: [CodingKeys: AttributeType] {
        [.title: .string, .isDone: .bool, .number: .int64]
    }

    static var relationships: [CodingKeys: Relationship] {
        [.list: Relationship(id: "list", type: .toOne, destinationEntity: "List", inverseRelationship: "todos")]
    }

    enum CodingKeys: String, CodingKey {
        case id, title, isDone, number, list
    }

    let id: String
    var title: String
    var isDone: Bool
    /// The order they were added in.
    var number: Int64
    var list: String?

    init(number: Int64, title: String, list: String?) {
        self.id = "todo-\(number)"
        self.title = title
        self.isDone = false
        self.number = number
        self.list = list
    }

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        title = try model.decode(String.self, forKey: CodingKeys.title)
        isDone = try model.decode(Bool.self, forKey: CodingKeys.isDone)
        number = try model.decode(Int64.self, forKey: CodingKeys.number)
        list = try model.decodeRelationship(String?.self, forKey: CodingKeys.list)
    }

    func encode() -> ModelData {
        var data = ModelData(entity: Self.entityName, id: ObjectID(rawValue: id))
        data.encode(title, forKey: CodingKeys.title)
        data.encode(isDone, forKey: CodingKeys.isDone)
        data.encode(number, forKey: CodingKeys.number)
        data.encodeRelationship(list, forKey: CodingKeys.list)
        return data
    }
}

struct TodoList: Entity {

    static var entityName: EntityName { "List" }

    static var attributes: [CodingKeys: AttributeType] { [.name: .string] }

    static var relationships: [CodingKeys: Relationship] {
        [.todos: Relationship(id: "todos", type: .toMany, destinationEntity: "Todo", inverseRelationship: "list")]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, todos
    }

    let id: String
    var name: String
    /// The host keeps this side: it's whichever to-dos point here.
    var todos: [String] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        name = try model.decode(String.self, forKey: CodingKeys.name)
        todos = try model.decodeRelationship([String].self, forKey: CodingKeys.todos)
    }

    func encode() -> ModelData {
        var data = ModelData(entity: Self.entityName, id: ObjectID(rawValue: id))
        data.encode(name, forKey: CodingKeys.name)
        return data
    }
}

/// The guest is single-threaded (§6.4), which the compiler can't see: the
/// count's task captures this.
@Observable
final class Todos: @unchecked Sendable {

    var title: String = ""

    var status: String = ""

    /// Whether done to-dos are listed too.
    var showsDone = true

    /// Which list a new to-do goes in: an index into `lists`.
    var listIndex = 0

    @ObservationIgnored let store: RuntimeModelStorage

    /// The to-dos on screen, in the order they were added.
    @ObservationIgnored let items: Query<Todo>

    @ObservationIgnored let lists: Query<TodoList>

    static let model = Model(entities: [EntityDescription(entity: Todo.self), EntityDescription(entity: TodoList.self)])

    init() {
        store = RuntimeModelStorage("todos", model: Self.model, indexes: [Todo.entityName: [["number"], ["isDone"]]])
        items = Query(store, sort: [.init(property: "number")])
        lists = Query(store, sort: [.init(property: "name")])
    }

    /// The closures hold this, which lives as long as the app does:
    /// Embedded Swift has no weak or unowned references.
    func start() {
        store.count(FetchRequest(entity: TodoList.entityName)) { result in
            switch result {
            case .success(0):
                // The first launch: both lists, or neither.
                var changes = ModelChanges()
                changes.insert(TodoList(id: "home", name: "Home").encode())
                changes.insert(TodoList(id: "work", name: "Work").encode())
                self.store.perform(changes) { self.finish("start", $0) }
            case .success:
                break
            case .failure(let error):
                self.report("start", error)
            }
        }
    }

    var list: TodoList? {
        let lists = lists.results
        return lists.isEmpty ? nil : lists[listIndex % lists.count]
    }

    /// "Home 2, Work 1": each list and how many to-dos point at it.
    var summary: String {
        lists.results.map { "\($0.name) \($0.todos.count)" }.joined(separator: ", ")
    }

    func add() {
        let title = self.title
        guard !title.isEmpty else {
            status = "A to-do needs a title."
            return
        }
        let list = self.list?.id
        // The highest number so far: a sort and a limit.
        let last = FetchRequest(entity: Todo.entityName, sortDescriptors: [.init(property: "number", ascending: false)], fetchLimit: 1)
        store.results(Todo.self, for: last) { result in
            switch result {
            case .success(let found):
                let todo = Todo(number: (found.first?.number ?? 0) + 1, title: title, list: list)
                self.store.insert(todo.encode()) { result in
                    if case .success = result {
                        self.title = ""
                    }
                    self.finish("add", result, "Added \(title)")
                }
            case .failure(let error):
                self.report("add", error)
            }
        }
    }

    /// An insert over an object sets the properties it has, and leaves the
    /// rest: here, only `isDone`.
    func toggle(_ todo: Todo) {
        var change = ModelData(entity: Todo.entityName, id: ObjectID(rawValue: todo.id))
        change.encode(!todo.isDone, forKey: Todo.CodingKeys.isDone)
        store.insert(change) { self.finish("change", $0) }
    }

    func delete(_ todo: Todo) {
        store.delete(Todo.entityName, for: ObjectID(rawValue: todo.id)) { self.finish("delete", $0, "Deleted \(todo.title)") }
    }

    func toggleFilter() {
        showsDone.toggle()
        items.predicate = showsDone ? nil : Todo.CodingKeys.isDone == false
    }

    /// Deletes every done to-do in one batch.
    func clearDone() {
        store.fetchID(FetchRequest(entity: Todo.entityName, predicate: Todo.CodingKeys.isDone == true)) { result in
            switch result {
            case .success(let ids):
                self.store.delete(Todo.entityName, for: ids) { self.finish("clear", $0, "Cleared \(ids.count)") }
            case .failure(let error):
                self.report("clear", error)
            }
        }
    }

    #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
    /// How many to-dos are left in the current list, with `async`/`await`
    /// and a predicate that goes through the relationship. Embedded builds
    /// only: in host builds Swift's own executor would run it on another
    /// thread.
    func countOpen() {
        guard let list else { return }
        Task {
            do throws(ModelStoreError) {
                let inList: FetchRequest.Predicate = .comparison(.init(left: .keyPath("list.name"), right: .attribute(.string(list.name)), type: .equalTo))
                let open = FetchRequest(entity: Todo.entityName, predicate: .compound(.and([inList, Todo.CodingKeys.isDone == false])))
                let count = try await self.store.count(open)
                self.status = "\(count) open in \(list.name)"
            } catch {
                self.report("count", error)
            }
        }
    }
    #else
    func countOpen() {
        status = "Counting needs the concurrency runtime."
    }
    #endif

    func finish(_ what: String, _ result: Result<Void, ModelStoreError>, _ done: String? = nil) {
        switch result {
        case .success:
            if let done {
                status = done
            }
        case .failure(let error):
            report(what, error)
        }
    }

    func report(_ what: String, _ error: ModelStoreError) {
        status = "Couldn't \(what): error \(error.code.rawValue)"
    }
}

struct ContentView: View {

    @Bindable var todos: Todos

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(todos.summary)
                .accessibilityIdentifier("summary")
            TextField("Title", text: $todos.title)
            HStack(spacing: 8) {
                Button("List: \(todos.list?.name ?? "none")") { todos.listIndex += 1 }
                Button("Add") { todos.add() }
            }
            HStack(spacing: 8) {
                Button(todos.showsDone ? "Show: all" : "Show: open") { todos.toggleFilter() }
                Button("Clear done") { todos.clearDone() }
                Button("Count open") { todos.countOpen() }
            }
            ForEach(todos.items.results) { todo in
                HStack(spacing: 8) {
                    Button(todo.isDone ? "Done: \(todo.title)" : todo.title) { todos.toggle(todo) }
                    Button("Delete \(todo.title)") { todos.delete(todo) }
                }
            }
            if let error = todos.items.error {
                Text("Couldn't fetch: error \(error.code.rawValue)")
            }
            Text(todos.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleModelApp: App {

    let todos = Todos()

    init() {
        todos.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(todos: todos)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleModelMain() -> rt_status {
    Runtime.main { ExampleModelApp.run() }
}
