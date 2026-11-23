import Testing
@testable import DynamicSwiftUI
import DynamicUI
import RuntimeNative
import DynamicRuntime

// MARK: - Views under test

struct WindowReport: View {

    @Environment(.horizontalSizeClass) var sizeClass
    @Environment(.colorScheme) var colorScheme
    @Environment(.dynamicTypeSize) var typeSize
    @Environment(.displayScale) var scale
    @Environment(.accessibilityReduceMotion) var reduceMotion
    @Environment(.layoutDirection) var direction

    var body: some View {
        VStack {
            Text("size \(sizeClass?.rawValue ?? "none")")
            Text("scheme \(colorScheme.rawValue)")
            Text("type \(typeSize.rawValue) \(typeSize.isAccessibilitySize)")
            Text("scale \(Int(scale)) motion \(reduceMotion) \(direction.rawValue)")
        }
    }
}

struct SchemeLabel: View {
    @Environment(.colorScheme) var colorScheme
    var body: some View {
        Text("scheme \(colorScheme.rawValue)")
    }
}

struct Overridden: View {
    var body: some View {
        VStack {
            SchemeLabel()
            VStack {
                SchemeLabel()
            }
            .environment(.colorScheme, .dark)
            SchemeLabel()
                .environment(.colorScheme, .light)
        }
    }
}

struct Theme: Equatable {
    var accent: String
}

struct ThemeKey: EnvironmentKey {
    static var defaultValue: Theme { Theme(accent: "blue") }
}

extension EnvironmentValues.Key where Value == Theme {
    static var theme: Self { Self(ThemeKey.self) }
}

struct ThemeLabel: View {
    @Environment(.theme) var theme
    var body: some View {
        Text("accent \(theme.accent)")
    }
}

struct Themed: View {
    var body: some View {
        VStack {
            ThemeLabel()
            ThemeLabel().environment(.theme, Theme(accent: "pink"))
        }
    }
}

struct PresentedLabel: View {
    @Environment(.isPresented) var isPresented
    @Environment(.isEnabled) var isEnabled
    @Environment(.dismiss) var dismiss
    let name: String
    var body: some View {
        Button("\(name) presented \(isPresented) enabled \(isEnabled)") { dismiss() }
    }
}

struct Dismissing: View {
    @State var showsSheet = true
    var body: some View {
        NavigationStack {
            VStack {
                PresentedLabel(name: "root")
                PresentedLabel(name: "off").disabled(true)
                NavigationLink("Open", destination: PresentedLabel(name: "pushed"))
            }
            .sheet(isPresented: $showsSheet) {
                PresentedLabel(name: "sheet")
            }
        }
    }
}

struct Folder: Identifiable {
    let id: Int
    let name: String
}

final class Picks {
    var folder: Int?
    var note: String?
}

struct Notes: View {

    let picks: Picks
    @State var folder: Int?
    @State var note: String?

    var body: some View {
        NavigationSplitView {
            List([Folder(id: 1, name: "Work"), Folder(id: 2, name: "Home")], selection: $folder) { folder in
                Text(folder.name)
            }
            .navigationTitle("Folders")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            if let folder {
                List(selection: $note) {
                    Text("Note \(folder)a").tag("\(folder)a")
                    Text("Note \(folder)b").tag("\(folder)b")
                    Text("Not a note")
                }
                .navigationTitle("Folder \(folder)")
            } else {
                Text("No folder")
            }
        } detail: {
            if let note {
                Text("Showing \(note)")
            } else {
                Text("No note")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct LinkedSplit: View {
    var body: some View {
        NavigationSplitView {
            VStack {
                NavigationLink("Inbox", destination: PresentedLabel(name: "inbox"))
                NavigationLink("Sent", destination: Text("Sent mail"))
            }
            .toolbar { Button("Compose") { } }
        } detail: {
            NavigationStack {
                Text("Pick a mailbox")
                    .navigationTitle("Mail")
            }
        }
    }
}

// MARK: - Tests

extension ViewGraphTests {

    func window(_ graph: ViewGraph, _ values: RenderEnvironment) {
        graph.environment = values
        graph.update()
    }

    // MARK: Values

    @Test func valuesHaveTheirDefaultsWithoutAReport() throws {
        let (_, sink) = graph(WindowReport())
        #expect(sink.screen?.texts == [
            "size none", "scheme light", "type large false", "scale 1 motion false leftToRight",
        ])
    }

    @Test func theHostsValuesReachViewsAndAChangeEvaluatesThemAgain() throws {
        let sink = TestSink()
        let graph = ViewGraph(WindowReport(), sink: sink)
        graph.environment = RenderEnvironment(horizontalSizeClass: .compact, colorScheme: .dark,
                                              dynamicTypeSize: .accessibility2, layoutDirection: .rightToLeft,
                                              displayScale: 3, reduceMotion: true)
        graph.update()
        #expect(sink.screen?.texts == [
            "size compact", "scheme dark", "type accessibility2 true", "scale 3 motion true rightToLeft",
        ])

        sink.clear()
        graph.environment = RenderEnvironment(horizontalSizeClass: .regular, colorScheme: .dark,
                                              dynamicTypeSize: .accessibility2, layoutDirection: .rightToLeft,
                                              displayScale: 3, reduceMotion: true)
        #expect(graph.needsUpdate)
        graph.update()
        #expect(sink.applied.isEmpty)
        #expect(sink.replaced.map(\.subtree.texts) == [["size regular"]], "only what changed")

        sink.clear()
        let same = graph.environment
        graph.environment = same
        #expect(!graph.needsUpdate, "the same values change nothing")
    }

    @Test func aSubtreesValuesGoIntoTheIR() throws {
        let (graph, sink) = graph(Overridden())
        let screen = try #require(sink.screen)
        #expect(screen.texts == ["scheme light", "scheme dark", "scheme light"])
        let dark = screen.children[1]
        #expect(dark.modifiers == [ModifierNode("environment", ["colorScheme": "dark"])])
        #expect(screen.children[2].modifiers == [ModifierNode("environment", ["colorScheme": "light"])],
                "the host didn't say, so the subtree does")

        window(graph, RenderEnvironment(colorScheme: .dark))
        let updated = try #require(sink.screen)
        #expect(updated.texts == ["scheme dark", "scheme dark", "scheme light"])
        #expect(updated.children[1].modifiers.isEmpty)
        #expect(updated.children[2].modifiers == [ModifierNode("environment", ["colorScheme": "light"])])
    }

    @Test func anAppsOwnValues() throws {
        let (_, sink) = graph(Themed())
        #expect(sink.screen?.texts == ["accent blue", "accent pink"])
        #expect(sink.screen?.children[1].modifiers.isEmpty == true, "an app's own value isn't the host's")
    }

    @Test func preferredColorSchemeIsAModifier() throws {
        let (_, sink) = graph(Text("Night").preferredColorScheme(.dark))
        #expect(sink.screen?.modifiers == [ModifierNode("preferredColorScheme", ["scheme": "dark"])])
        let (_, system) = graph(Text("Day").preferredColorScheme(nil))
        #expect(system.screen?.modifiers == [ModifierNode("preferredColorScheme")])
    }

    @Test func dismissClosesASheetAndGoesBackALevel() throws {
        let (graph, sink) = graph(Dismissing())
        var screen = try #require(sink.screen)
        #expect(screen.texts.contains("root presented false enabled true"))
        #expect(screen.texts.contains("off presented false enabled false"))
        #expect(screen.texts.contains("sheet presented true enabled true"))

        // Dismissing where there's nothing to close does nothing.
        try tap(graph, sink, "Button", text: nil)
        #expect(!graph.needsUpdate)

        let sheet = try #require(screen.find("Sheet"))
        #expect(sheet.props["isPresented"] == true)
        let sheetButton = try #require(sheet.children[1].find("Button"))
        #expect(graph.handle(sheetButton.id, kind: .tap))
        graph.update()
        screen = try #require(sink.screen)
        #expect(screen.find("Sheet")?.props["isPresented"] == false)

        let link = try #require(screen.find("NavigationLink"))
        #expect(graph.handle(link.id, kind: .tap))
        graph.update()
        screen = try #require(sink.screen)
        let stack = try #require(screen.find("NavStack"))
        #expect(stack.children.count == 2)
        #expect(stack.children[1].texts == ["pushed presented true enabled true"])
        let pushed = try #require(stack.children[1].find("Button"))
        #expect(graph.handle(pushed.id, kind: .tap))
        graph.update()
        #expect(sink.screen?.find("NavStack")?.children.count == 1)
    }

    // MARK: Split views

    @Test func aSplitViewHasItsColumns() throws {
        let picks = Picks()
        let (_, sink) = graph(Notes(picks: picks))
        let split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props == ["style": "balanced", "visibility": "automatic", "compactColumn": "sidebar"])
        #expect(split.children.map(\.type) == ["NavColumn", "NavColumn", "NavColumn"])
        #expect(split.children.map { $0.props["column"] } == ["sidebar", "content", "detail"])
        let sidebar = split.children[0]
        #expect(sidebar.props["title"] == "Folders")
        #expect(sidebar.props["minWidth"] == 180.0)
        #expect(sidebar.props["idealWidth"] == 220.0)
        #expect(sidebar.props["maxWidth"] == 300.0)
        #expect(split.children[1].texts == ["No folder"])
        #expect(split.children[2].texts == ["No note"])
        #expect(Set(split.children.map(\.id)).count == 3)
    }

    @Test func pickingShowsTheNextColumnAndGoingBackClearsIt() throws {
        let (graph, sink) = graph(Notes(picks: Picks()))
        window(graph, RenderEnvironment(horizontalSizeClass: .compact))
        var split = try #require(sink.screen?.find("NavSplit"))
        let folders = try #require(split.children[0].find("List"))
        #expect(folders.count == 2, "lazy")
        #expect(folders.props["selection"] == nil)
        let work = try #require(graph.row(folders.id, index: 0))
        let tag = try #require(work.modifiers.first { $0.kind == "tag" }?.args["value"]?.int)
        #expect(tag == 1.hashValue)

        // The user picks Work: the folder's notes show, collapsed.
        #expect(graph.handle(folders.id, kind: .change, payload: .int(tag)))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "content")
        #expect(split.children[0].find("List")?.props["selection"] == .int(tag))
        let notes = try #require(split.children[1].find("List"))
        #expect(split.children[1].props["title"] == "Folder 1")
        #expect(notes.count == nil, "eager")
        #expect(notes.children.map { $0.modifiers.first { $0.kind == "tag" }?.args["value"] } == [
            .int("1a".hashValue), .int("1b".hashValue), nil,
        ], "a row without a tag can't be picked")

        #expect(graph.handle(notes.id, kind: .change, payload: .int("1b".hashValue)))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "detail")
        #expect(split.children[2].texts == ["Showing 1b"])
        #expect(split.children[1].find("List")?.props["selection"] == .int("1b".hashValue))

        // A tag the list doesn't have changes nothing.
        #expect(graph.handle(notes.id, kind: .change, payload: .int(12345)))
        #expect(!graph.needsUpdate)

        // Back to the notes: the note is no longer picked.
        #expect(graph.handle(split.id, kind: .pop, payload: 2))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "content")
        #expect(split.children[2].texts == ["No note"])
        #expect(split.children[1].find("List")?.props["selection"] == nil)
        #expect(split.children[0].find("List")?.props["selection"] == .int(tag), "the folder still is")

        // Back to the folders.
        #expect(graph.handle(split.id, kind: .pop, payload: 1))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "sidebar")
        #expect(split.children[1].texts == ["No folder"])

        // No value is none.
        #expect(graph.handle(folders.id, kind: .change, payload: .int(tag)))
        graph.update()
        #expect(graph.handle(folders.id, kind: .change))
        graph.update()
        #expect(sink.screen?.find("NavSplit")?.children[1].texts == ["No folder"])
    }

    @Test func theUserChoosesWhichColumnsShow() throws {
        let (graph, sink) = graph(Notes(picks: Picks()))
        let split = try #require(sink.screen?.find("NavSplit"))
        #expect(graph.handle(split.id, kind: .change, payload: "detailOnly"))
        graph.update()
        #expect(sink.screen?.find("NavSplit")?.props["visibility"] == "detailOnly")
        #expect(graph.handle(split.id, kind: .change, payload: "everything"))
        #expect(!graph.needsUpdate, "a visibility it doesn't know")
    }

    @Test func aLinkInAColumnShowsItsDestinationInTheNext() throws {
        let (graph, sink) = graph(LinkedSplit())
        window(graph, RenderEnvironment(horizontalSizeClass: .compact))
        var split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.children.count == 2)
        #expect(split.children[0].children.last?.type == "ToolbarItem", "the column's toolbar")
        #expect(split.children[1].find("NavStack")?.children.first?.props["title"] == "Mail", "a stack in a column")

        let inbox = try #require(split.children[0].find("NavigationLink"))
        #expect(graph.handle(inbox.id, kind: .tap))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "detail")
        #expect(split.children[1].texts == ["inbox presented false enabled true"])

        // dismiss in a column a collapsed view shows goes back a column.
        let button = try #require(split.children[1].find("Button"))
        #expect(graph.handle(button.id, kind: .tap))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "sidebar")
        #expect(split.children[1].texts == ["Pick a mailbox"], "the column's own content again")

        // Expanded, dismiss in a column does nothing.
        window(graph, RenderEnvironment(horizontalSizeClass: .regular))
        let again = try #require(sink.screen?.find("NavSplit")?.children[0].find("NavigationLink"))
        #expect(graph.handle(again.id, kind: .tap))
        graph.update()
        let shown = try #require(sink.screen?.find("NavSplit")?.children[1].find("Button"))
        #expect(graph.handle(shown.id, kind: .tap))
        #expect(!graph.needsUpdate)
    }

    @Test func withoutSplitViewsASplitViewIsAStack() throws {
        let sink = TestSink()
        let graph = ViewGraph(Notes(picks: Picks()), sink: sink)
        graph.supportsSplitViews = false
        graph.update()
        var stack = try #require(sink.screen?.find("NavStack"))
        #expect(sink.screen?.find("NavSplit") == nil)
        #expect(stack.children.map(\.type) == ["NavLevel"])
        #expect(stack.children[0].props["title"] == "Folders")

        let folders = try #require(stack.find("List"))
        #expect(graph.handle(folders.id, kind: .change, payload: .int(2.hashValue)))
        graph.update()
        stack = try #require(sink.screen?.find("NavStack"))
        #expect(stack.children.count == 2)
        #expect(stack.children[1].props["title"] == "Folder 2")

        #expect(graph.handle(stack.id, kind: .pop, payload: 1))
        graph.update()
        #expect(sink.screen?.find("NavStack")?.children.count == 1)
        #expect(sink.screen?.find("List")?.props["selection"] == nil)
    }

    @Test func aBoundCompactColumn() throws {
        struct Bound: View {
            @State var column = NavigationSplitViewColumn.detail
            @State var visibility = NavigationSplitViewVisibility.all
            var body: some View {
                NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $column) {
                    Text("Sidebar \(column == .sidebar)")
                } detail: {
                    Text("Detail \(visibility == .detailOnly)")
                }
            }
        }
        let (graph, sink) = graph(Bound())
        var split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "detail")
        #expect(split.props["visibility"] == "all")
        #expect(graph.handle(split.id, kind: .pop, payload: 1))
        #expect(graph.handle(split.id, kind: .change, payload: "detailOnly"))
        graph.update()
        split = try #require(sink.screen?.find("NavSplit"))
        #expect(split.props["compactColumn"] == "sidebar")
        #expect(split.texts == ["Sidebar true", "Detail true"])
    }

    // MARK: Through the renderer

    @Test func theRendererGivesTheWindowsValuesBeforeTheFirstTree() throws {
        registerRenderer()
        TestRenderer.window = RenderEnvironment(horizontalSizeClass: .regular, colorScheme: .dark)
        _ = GuestExecutor.enter { HostRenderer.start(WindowReport()) }
        let host = try #require(TestRenderer.last)
        #expect(host.trees.count == 1, "laid out once, for the window it's in")
        #expect(host.trees.first?.texts.prefix(2) == ["size regular", "scheme dark"])

        host.report(RenderEnvironment(horizontalSizeClass: .compact, colorScheme: .dark))
        #expect(host.replacements.map(\.subtree.texts) == [["size compact"]])

        // Not the window, or not a payload: nothing.
        host.send(5, .environment, RenderEnvironment(colorScheme: .light).payload)
        host.delegate.event(RenderCodec.encode(id: 0), kind: RenderEventKind.environment.rawValue, payload: [0xFF])
        #expect(host.replacements.count == 1, "bytes that don't decode change nothing")
    }

    @Test func aRendererWithoutSplitViewsGetsAStack() throws {
        registerRenderer()
        _ = GuestExecutor.enter { HostRenderer.start(Notes(picks: Picks())) }
        let host = try #require(TestRenderer.last)
        #expect(host.trees.first?.find("NavStack") != nil)

        registerRenderer()
        TestRenderer.window = RenderEnvironment()
        _ = GuestExecutor.enter { HostRenderer.start(Notes(picks: Picks())) }
        let current = try #require(TestRenderer.last)
        #expect(current.trees.first?.find("NavSplit") != nil, "empty values still mean split views")
    }

    @Test func noNodeIsTheWindow() throws {
        let (_, sink) = graph(Notes(picks: Picks()))
        func check(_ node: RenderNode) {
            #expect(node.id != RenderNode.windowID)
            node.children.forEach(check)
        }
        try check(#require(sink.screen))
    }
}
