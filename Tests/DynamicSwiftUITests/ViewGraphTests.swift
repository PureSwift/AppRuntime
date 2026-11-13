import Testing
@testable import DynamicSwiftUI
import DynamicUI

/// Records what a view graph sends, and applies it to a copy of the tree,
/// as a host would.
final class TestSink: RenderSink {

    var applied: [RenderNode] = []

    var replaced: [(id: RenderNode.ID, subtree: RenderNode)] = []

    /// The tree the host would show.
    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        applied.append(tree)
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        replaced.append((id, subtree))
        screen?.replace(id, with: subtree)
    }

    func clear() {
        applied = []
        replaced = []
    }
}

extension RenderNode {

    /// Depth first, the first node of `type` (and `text`, if given).
    func find(_ type: String, text: String? = nil) -> RenderNode? {
        if self.type == type, text == nil || props["text"]?.string == text {
            return self
        }
        for child in children {
            if let found = child.find(type, text: text) { return found }
        }
        return nil
    }

    var texts: [String] {
        (props["text"]?.string.map { [$0] } ?? []) + children.flatMap { $0.texts }
    }
}

// MARK: - Views under test

struct Counter: View {

    @State var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Count: \(count)")
            Button("Increment") { count += 1 }
                .padding()
                .background(.blue)
        }
    }
}

@Observable
final class Profile {
    var name: String = "Ada"
    var notifications: Bool = false
    var volume: Double = 0.5
    var visits: Int = 0
}

struct ProfileForm: View {

    @Bindable var profile: Profile

    var body: some View {
        VStack {
            Text(profile.name)
            TextField("Name", text: $profile.name)
            Toggle("Notifications", isOn: $profile.notifications)
            Slider(value: $profile.volume, in: 0...1)
            Stepper("Visits", value: $profile.visits, in: 0...3)
        }
    }
}

struct Conditional: View {

    @State var showBanner = false

    var body: some View {
        VStack {
            if showBanner {
                Text("Banner")
            }
            Text("Content")
            Button("Toggle") { showBanner.toggle() }
        }
    }
}

struct Item: Identifiable {
    let id: Int
    let title: String
}

struct Row: View {

    let item: Item

    @State var taps = 0

    var body: some View {
        Button("\(item.title) \(taps)") { taps += 1 }
    }
}

struct Rows: View {

    let items: [Item]

    var body: some View {
        VStack {
            ForEach(items) { item in
                Row(item: item)
            }
        }
    }
}

struct LazyRows: View {

    let items: [Item]

    var body: some View {
        List(items) { item in
            Row(item: item)
        }
    }
}

struct LazyStack: View {
    var body: some View {
        LazyVStack {
            ForEach(0..<100) { index in
                Text("\(index)")
            }
        }
    }
}

struct Detail: View {
    let title: String
    var body: some View {
        Text("Detail \(title)").navigationTitle(title)
    }
}

struct Navigation: View {
    var body: some View {
        NavigationStack {
            VStack {
                NavigationLink("Open A", destination: Detail(title: "A"))
                NavigationLink("Open B", destination: Detail(title: "B"))
            }
            .navigationTitle("Home")
        }
    }
}

@Observable
final class Session {
    var user: String = "guest"
}

struct Greeting: View {
    @Environment(Session.self) var session
    var body: some View {
        Text("Hello \(session.user)")
    }
}

final class Lifecycle {
    var events: [String] = []
}

struct Appearing: View {
    let lifecycle: Lifecycle
    @State var visible = true
    var body: some View {
        VStack {
            if visible {
                Text("Here")
                    .onAppear { lifecycle.events.append("appear") }
                    .onDisappear { lifecycle.events.append("disappear") }
            }
            Button("Hide") { visible = false }
        }
    }
}

// MARK: - Tests

/// Serialized: the frontend is single-threaded, like the guest (§6.4), and
/// keeps the graph being evaluated in a global.
@Suite(.serialized) struct ViewGraphTests {

    func graph<V: View>(_ view: V) -> (ViewGraph, TestSink) {
        let sink = TestSink()
        let graph = ViewGraph(view, sink: sink)
        graph.update()
        return (graph, sink)
    }

    func tap(_ graph: ViewGraph, _ sink: TestSink, _ type: String, text: String? = nil) throws {
        let node = try #require(sink.screen?.find(type, text: text))
        #expect(graph.handle(node.id, kind: .tap))
    }

    @Test func firstUpdateAppliesTheTree() throws {
        let (_, sink) = graph(Counter())
        let tree = try #require(sink.applied.first)
        #expect(sink.applied.count == 1)
        #expect(tree.type == "VStack")
        #expect(tree.props == ["alignment": "leading", "spacing": 4.0])
        #expect(tree.children.map(\.type) == ["Text", "Button"])
        #expect(tree.texts == ["Count: 0", "Increment"])
        let button = tree.children[1]
        #expect(button.modifiers.map(\.kind) == ["padding", "background"], "in order")
        #expect(button.modifiers[0].args["top"] == 16.0, "defaults are explicit")
        #expect(button.modifiers[1].args["color"] == "blue")
    }

    @Test func stateChangesSendOnlyWhatChanged() throws {
        let (graph, sink) = graph(Counter())
        let before = try #require(sink.screen)
        sink.clear()
        try tap(graph, sink, "Button")
        #expect(graph.needsUpdate)
        graph.update()
        #expect(sink.applied.isEmpty)
        #expect(sink.replaced.map(\.subtree.type) == ["Text"], "only the label")
        #expect(sink.screen?.texts == ["Count: 1", "Increment"])
        #expect(sink.screen?.find("Text")?.id == before.find("Text")?.id, "identity is stable")

        sink.clear()
        graph.update()
        #expect(sink.applied.isEmpty && sink.replaced.isEmpty, "nothing changed")
    }

    @Test func observableModelsAndBindings() throws {
        let profile = Profile()
        let (graph, sink) = graph(ProfileForm(profile: profile))
        let screen = try #require(sink.screen)

        let field = try #require(screen.find("TextField"))
        #expect(field.props["text"] == "Ada")
        #expect(field.props["placeholder"] == "Name")
        graph.handle(field.id, kind: .change, payload: "Grace")
        #expect(profile.name == "Grace")

        let toggle = try #require(screen.find("Toggle"))
        graph.handle(toggle.id, kind: .change, payload: true)
        #expect(profile.notifications)

        let slider = try #require(screen.find("Slider"))
        graph.handle(slider.id, kind: .change, payload: 1.5)
        #expect(profile.volume == 1, "clamped to the range")

        let stepper = try #require(screen.find("Stepper"))
        graph.handle(stepper.id, kind: .change, payload: 2)
        #expect(profile.visits == 2)

        #expect(graph.needsUpdate)
        graph.update()
        #expect(sink.screen?.find("Text", text: "Grace") != nil)
        #expect(sink.screen?.find("Toggle")?.props["isOn"] == true)

        // A change made outside an event also marks the graph dirty.
        profile.name = "Lin"
        #expect(graph.needsUpdate)
    }

    @Test func viewsBehindAnIfDontShiftTheirSiblings() throws {
        let (graph, sink) = graph(Conditional())
        let content = try #require(sink.screen?.find("Text", text: "Content"))
        try tap(graph, sink, "Button")
        graph.update()
        #expect(sink.screen?.texts.first == "Banner")
        #expect(sink.screen?.find("Text", text: "Content")?.id == content.id)
    }

    @Test func forEachStateFollowsIdentity() throws {
        let items = [Item(id: 1, title: "one"), Item(id: 2, title: "two")]
        let first = Rows(items: items)
        let sink = TestSink()
        var root = first
        let graph = ViewGraph(AnyView(RowsHost(rows: { root })), sink: sink)
        graph.update()
        // Taps go to the button that contains the label.
        let button = try #require(sink.screen?.children.first { $0.texts == ["two 0"] })
        graph.handle(button.id, kind: .tap)
        graph.update()
        #expect(sink.screen?.texts == ["one 0", "two 1"])

        // Reordered: the state stays with item two.
        root = Rows(items: items.reversed())
        graph.update()
        #expect(sink.screen?.texts == ["two 1", "one 0"])
    }

    @Test func lazyListsRenderRowsOnDemand() throws {
        let items = (0..<1000).map { Item(id: $0, title: "row \($0)") }
        let (graph, sink) = graph(LazyRows(items: items))
        let list = try #require(sink.screen)
        #expect(list.type == "List")
        #expect(list.count == 1000)
        #expect(list.children.isEmpty)
        #expect(graph.rowCount(list.id) == 1000)

        let row = try #require(graph.row(list.id, index: 500))
        #expect(row.texts == ["row 500 0"])
        #expect(graph.row(list.id, index: 1000) == nil)

        // A row's events and state work like the rest of the tree.
        #expect(graph.handle(row.id, kind: .tap))
        #expect(graph.needsUpdate, "a row read the state that changed")
        graph.update()
        #expect(sink.screen?.props["revision"] != list.props["revision"], "the host re-fetches its rows")
        #expect(graph.row(list.id, index: 500)?.texts == ["row 500 1"])
        #expect(graph.row(list.id, index: 501)?.texts == ["row 501 0"])
    }

    @Test func lazyStacksOfAForEachAreLazy() throws {
        let (graph, sink) = graph(LazyStack())
        let stack = try #require(sink.screen)
        #expect(stack.type == "LazyVStack")
        #expect(stack.count == 100)
        #expect(stack.children.isEmpty)
        #expect(graph.row(stack.id, index: 99)?.texts == ["99"])
    }

    @Test func navigationPushesAndPops() throws {
        let (graph, sink) = graph(Navigation())
        var stack = try #require(sink.screen)
        #expect(stack.type == "NavStack")
        #expect(stack.children.map { $0.props["title"] } == ["Home"])

        let link = try #require(stack.find("NavigationLink"))
        #expect(graph.handle(link.id, kind: .tap))
        graph.update()
        stack = try #require(sink.screen)
        #expect(stack.children.count == 2)
        #expect(stack.children[1].props["title"] == "A")
        #expect(stack.children[1].texts == ["Detail A"])

        #expect(graph.handle(stack.id, kind: .pop, payload: 1))
        graph.update()
        #expect(sink.screen?.children.count == 1)
    }

    @Test func environmentObjects() throws {
        let session = Session()
        let (graph, sink) = graph(Greeting().environment(session))
        #expect(sink.screen?.texts == ["Hello guest"])
        session.user = "ada"
        #expect(graph.needsUpdate)
        graph.update()
        #expect(sink.screen?.texts == ["Hello ada"])
    }

    @Test func appearanceHandlers() throws {
        let lifecycle = Lifecycle()
        let (graph, sink) = graph(Appearing(lifecycle: lifecycle))
        #expect(lifecycle.events == ["appear"])
        graph.update()
        #expect(lifecycle.events == ["appear"], "still on screen")
        try tap(graph, sink, "Button")
        graph.update()
        #expect(lifecycle.events == ["appear", "disappear"])
    }

    @Test func diffFindsTheSmallestChanges() {
        let old = RenderNode("VStack", id: 1, children: [
            RenderNode("Text", id: 2, props: ["text": "a"]),
            RenderNode("HStack", id: 3, children: [RenderNode("Text", id: 4, props: ["text": "b"])]),
        ])
        var new = old
        new.children[1].children[0].props["text"] = "c"
        var changes: [RenderNode] = []
        ViewGraph.diff(old, new, into: &changes)
        #expect(changes.map(\.id) == [4])

        new.children.append(RenderNode("Text", id: 5))
        changes = []
        ViewGraph.diff(old, new, into: &changes)
        #expect(changes.map(\.id) == [1], "a new child replaces its parent")
    }
}

/// Re-reads the view to show on every update, so a test can change it.
struct RowsHost: View {
    let rows: () -> Rows
    var body: some View {
        rows()
    }
}
