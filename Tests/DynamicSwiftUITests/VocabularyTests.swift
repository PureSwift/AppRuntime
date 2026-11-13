import Testing
@testable import DynamicSwiftUI
import DynamicUI

// MARK: - Views under test

enum Flavor: Hashable {
    case vanilla, chocolate, strawberry
}

@Observable
final class Order {
    var flavor: Flavor = .chocolate
    var fruitID: Int = 2
    var tab: String = "home"
}

struct FlavorPicker: View {

    @Bindable var order: Order

    var body: some View {
        VStack {
            Picker("Flavor", selection: $order.flavor) {
                Text("Vanilla").tag(Flavor.vanilla)
                Text("Chocolate").tag(Flavor.chocolate)
                Text("Strawberry").tag(Flavor.strawberry)
                Text("Untagged")
            }
            .pickerStyle(.segmented)
            Picker("Fruit", selection: $order.fruitID) {
                ForEach([Item(id: 1, title: "Apple"), Item(id: 2, title: "Banana")]) { item in
                    Text(item.title)
                }
                Text("Cherry").tag(3)
                Text("Wrong type").tag("4")
            }
        }
    }
}

struct Tabs: View {
    var body: some View {
        TabView {
            Counter()
                .tabItem { Label("Count", systemImage: "number") }
            Text("Settings")
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
    }
}

struct SelectedTabs: View {

    @Bindable var order: Order

    var body: some View {
        TabView(selection: $order.tab) {
            Text("Home").tabItem { Text("Home") }.tag("home")
            Text("Search").tabItem { Text("Search") }.tag("search")
        }
    }
}

struct LazyGridSample: View {

    let lazy: Bool

    var body: some View {
        if lazy {
            LazyVGrid(columns: [GridItem(.fixed(50)), GridItem(.flexible(), spacing: 4)]) {
                ForEach(0..<100) { index in
                    Text("\(index)")
                }
            }
        } else {
            LazyHGrid(rows: [GridItem(.adaptive(minimum: 20, maximum: 40), alignment: .topLeading)], spacing: 2) {
                Text("A")
                Text("B")
            }
        }
    }
}

final class Dismissals {
    var count = 0
}

struct Editor: View {
    @State var edits = 0
    var body: some View {
        Button("Edit \(edits)") { edits += 1 }
    }
}

struct Sheets: View {

    let dismissals: Dismissals

    @State var showing = false

    @State var item: Item?

    var body: some View {
        VStack {
            Button("Show") { showing = true }
                .sheet(isPresented: $showing, onDismiss: { dismissals.count += 1 }) {
                    Editor()
                }
            Text("After")
            Button("Item") { item = Item(id: 7, title: "seven") }
                .sheet(item: $item) { item in
                    Text(item.title)
                }
        }
    }
}

final class Actions {
    var deleted = false
}

struct Alerts: View {

    let actions: Actions

    @State var asking = false

    @State var noted = false

    var body: some View {
        VStack {
            Button("Delete…") { asking = true }
                .alert("Delete the file?", isPresented: $asking) {
                    Button("Delete", role: .destructive) { actions.deleted = true }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("You can't undo this.")
                }
            Text("Note")
                .alert("Noted", isPresented: $noted) { }
        }
    }
}

final class Taps {
    var names: [String] = []
}

struct Settings: View {

    let taps: Taps

    @State var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Text("Signed in")
                }
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Button("Name") { taps.names.append("name") }
                    Divider()
                    Menu("More") {
                        Button("Date") { taps.names.append("date") }
                    }
                }
                Button("Sign Out") { confirming = true }
                    .confirmationDialog("Sign out?", isPresented: $confirming, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) { taps.names.append("signOut") }
                    }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") { taps.names.append("add") }
                }
                Button("Edit") { taps.names.append("edit") }
            }
        }
    }
}

struct LooseToolbar: View {
    var body: some View {
        Text("No stack")
            .toolbar { Button("Ignored") { } }
    }
}

@Observable
final class Library {
    var query: String = ""
    var showsDetails: Bool = false
    var books: [Item] = [Item(id: 1, title: "Dune"), Item(id: 2, title: "Emma")]
    var searches: Int = 0
}

struct Shelf: View {

    @Bindable var library: Library

    var body: some View {
        NavigationStack {
            VStack {
                Grid(alignment: .leading, horizontalSpacing: 12) {
                    GridRow {
                        Text("Title")
                        Text("Year")
                    }
                    Divider()
                    GridRow(alignment: .bottom) {
                        Text("Dune")
                        Text("1965")
                    }
                }
                DisclosureGroup("Details", isExpanded: $library.showsDetails) {
                    Text("Two books")
                }
                DisclosureGroup("Notes") {
                    Text("None yet")
                }
                Link("Website", destination: "https://example.com")
                List {
                    ForEach(library.books) { book in
                        Text(book.title)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    library.books.removeAll { $0.id == book.id }
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button("Pin") { }
                            }
                    }
                }
            }
            .searchable(text: $library.query, prompt: "Books")
            .onSubmit { library.searches += 1 }
        }
    }
}

// MARK: - Tests

/// In `ViewGraphTests`, which is serialized: the frontend keeps the graph
/// being evaluated in a global.
extension ViewGraphTests {

    // MARK: Pickers

    @Test func pickersSelectByTag() throws {
        let order = Order()
        let (graph, sink) = graph(FlavorPicker(order: order))
        let picker = try #require(sink.screen?.find("Picker"))
        #expect(picker.props["title"] == "Flavor")
        #expect(picker.props["style"] == "segmented")
        #expect(picker.props["selection"] == 1)
        #expect(picker.children.map(\.texts) == [["Vanilla"], ["Chocolate"], ["Strawberry"], ["Untagged"]])

        #expect(graph.handle(picker.id, kind: .change, payload: 2))
        #expect(order.flavor == .strawberry)
        graph.handle(picker.id, kind: .change, payload: 3)
        graph.handle(picker.id, kind: .change, payload: 9)
        #expect(order.flavor == .strawberry, "an untagged option or a bad index changes nothing")

        graph.update()
        #expect(sink.screen?.find("Picker")?.props["selection"] == 2)
    }

    @Test func forEachTagsOptionsWithTheirIDs() throws {
        let order = Order()
        let (graph, sink) = graph(FlavorPicker(order: order))
        let picker = try #require(sink.screen?.children.last)
        #expect(picker.props["title"] == "Fruit")
        #expect(picker.props["style"] == nil, "the default style")
        #expect(picker.props["selection"] == 1, "Banana's ID")

        graph.handle(picker.id, kind: .change, payload: 2)
        #expect(order.fruitID == 3)
        graph.handle(picker.id, kind: .change, payload: 3)
        #expect(order.fruitID == 3, "a tag of another type isn't a value")
        graph.handle(picker.id, kind: .change, payload: 0)
        #expect(order.fruitID == 1)
    }

    // MARK: Tab views

    @Test func tabViewsKeepTheirOwnSelection() throws {
        let (graph, sink) = graph(Tabs())
        let tabs = try #require(sink.screen)
        #expect(tabs.type == "TabView")
        #expect(tabs.props["selection"] == 0)
        #expect(tabs.children.map(\.type) == ["Tab", "Tab"])
        #expect(tabs.children[0].props == ["title": "Count", "systemImage": "number"])
        #expect(tabs.children[1].props == ["title": "Settings", "systemImage": "gear"])
        #expect(tabs.children[0].children.map(\.type) == ["VStack"], "the tab's content")
        #expect(tabs.children[1].texts == ["Settings"], "the tab item isn't content")

        // A tab's content works as anywhere else.
        let button = try #require(tabs.find("Button"))
        graph.handle(button.id, kind: .tap)
        graph.update()
        #expect(sink.screen?.find("Text")?.props["text"] == "Count: 1")

        #expect(graph.handle(tabs.id, kind: .change, payload: 1))
        graph.update()
        #expect(sink.screen?.props["selection"] == 1)
        #expect(sink.screen?.children.map(\.id) == tabs.children.map(\.id), "tabs keep their IDs")
    }

    @Test func tabViewsSelectByTag() throws {
        let order = Order()
        let (graph, sink) = graph(SelectedTabs(order: order))
        let tabs = try #require(sink.screen)
        #expect(tabs.props["selection"] == 0)
        graph.handle(tabs.id, kind: .change, payload: 1)
        #expect(order.tab == "search")
        order.tab = "elsewhere"
        graph.update()
        #expect(sink.screen?.props["selection"] == nil, "no tab has the tag")
    }

    // MARK: Grids

    @Test func lazyGridsRenderItemsOnDemand() throws {
        let (graph, sink) = graph(LazyGridSample(lazy: true))
        let grid = try #require(sink.screen)
        #expect(grid.type == "LazyVGrid")
        #expect(grid.count == 100)
        #expect(grid.props["columns"] == .array([
            .array(["fixed", 50.0, 50.0, 8.0, "center", "center"]),
            .array(["flexible", 10.0, .double(.infinity), 4.0, "center", "center"]),
        ]))
        #expect(grid.props["alignment"] == "center")
        #expect(grid.props["spacing"] == 8.0)
        #expect(graph.row(grid.id, index: 42)?.texts == ["42"])
    }

    @Test func eagerGrids() throws {
        let (_, sink) = graph(LazyGridSample(lazy: false))
        let grid = try #require(sink.screen)
        #expect(grid.type == "LazyHGrid")
        #expect(grid.count == nil)
        #expect(grid.texts == ["A", "B"])
        #expect(grid.props["rows"] == .array([.array(["adaptive", 20.0, 40.0, 8.0, "leading", "top"])]))
        #expect(grid.props["spacing"] == 2.0)
    }

    // MARK: Sheets

    @Test func sheetsPresentTheirContent() throws {
        let dismissals = Dismissals()
        let (graph, sink) = graph(Sheets(dismissals: dismissals))
        var sheet = try #require(sink.screen?.find("Sheet"))
        let after = try #require(sink.screen?.find("Text", text: "After"))
        #expect(sheet.props == ["isPresented": false, "style": "sheet"])
        #expect(sheet.children.map(\.texts) == [["Show"]], "only the view it's attached to")

        let show = try #require(sheet.find("Button"))
        graph.handle(show.id, kind: .tap)
        graph.update()
        sheet = try #require(sink.screen?.find("Sheet"))
        #expect(sheet.props["isPresented"] == true)
        #expect(sheet.children.map(\.texts) == [["Show"], ["Edit 0"]])
        #expect(sink.screen?.find("Text", text: "After")?.id == after.id, "presenting doesn't move the views after it")

        // The content has state, kept while it's presented.
        graph.handle(sheet.children[1].id, kind: .tap)
        graph.update()
        #expect(sink.screen?.find("Sheet")?.children[1].texts == ["Edit 1"])
        #expect(dismissals.count == 0)

        // The user dismisses it.
        #expect(graph.handle(sheet.id, kind: .change, payload: false))
        graph.update()
        sheet = try #require(sink.screen?.find("Sheet"))
        #expect(sheet.props["isPresented"] == false)
        #expect(sheet.children.count == 1)
        #expect(dismissals.count == 1, "onDismiss ran")
        #expect(sink.screen?.find("Text", text: "After")?.id == after.id)

        // Presented again, it starts over.
        graph.handle(show.id, kind: .tap)
        graph.update()
        #expect(sink.screen?.find("Sheet")?.children[1].texts == ["Edit 0"])
    }

    @Test func itemSheetsShowTheirItem() throws {
        let (graph, sink) = graph(Sheets(dismissals: Dismissals()))
        var sheet = try #require(sink.screen?.children.last)
        #expect(sheet.type == "Sheet")
        let button = try #require(sheet.children.first)
        #expect(button.texts == ["Item"])
        graph.handle(button.id, kind: .tap)
        graph.update()
        sheet = try #require(sink.screen?.children.last)
        #expect(sheet.props["isPresented"] == true)
        #expect(sheet.children.last?.texts == ["seven"])
        graph.handle(sheet.id, kind: .change, payload: false)
        graph.update()
        #expect(sink.screen?.children.last?.children.count == 1)
    }

    // MARK: Alerts

    @Test func alertsShowTheirActionsWhilePresented() throws {
        let actions = Actions()
        let (graph, sink) = graph(Alerts(actions: actions))
        var alert = try #require(sink.screen?.find("Alert"))
        #expect(alert.props == ["title": "Delete the file?", "isPresented": false])
        #expect(alert.children.count == 1)

        graph.handle(try #require(alert.find("Button")).id, kind: .tap)
        graph.update()
        alert = try #require(sink.screen?.find("Alert"))
        #expect(alert.props["isPresented"] == true)
        #expect(alert.props["message"] == "You can't undo this.")
        let buttons = Array(alert.children.dropFirst())
        #expect(buttons.map(\.texts) == [["Delete"], ["Cancel"]])
        #expect(buttons.map { $0.props["role"] } == ["destructive", "cancel"])

        // An action runs, then the host reports the alert gone.
        #expect(graph.handle(buttons[0].id, kind: .tap))
        #expect(actions.deleted)
        graph.handle(alert.id, kind: .change, payload: false)
        graph.update()
        #expect(sink.screen?.find("Alert")?.children.count == 1)
        #expect(sink.screen?.find("Alert")?.props["isPresented"] == false)
    }

    @Test func alertsWithoutActionsOrMessage() throws {
        let (_, sink) = graph(Alerts(actions: Actions()))
        let alert = try #require(sink.screen?.children.last)
        #expect(alert.type == "Alert")
        #expect(alert.props == ["title": "Noted", "isPresented": false])
        #expect(alert.children.map(\.texts) == [["Note"]])
    }

    @Test func buttonRoles() throws {
        let (_, sink) = graph(Button("Remove", role: .destructive) { })
        #expect(sink.screen?.props == ["role": "destructive"])
        let (_, plain) = graph(Button("Add") { })
        #expect(plain.screen?.props == [:])
    }

    // MARK: Forms, menus, dialogs and toolbars

    @Test func formsAndMenus() throws {
        let taps = Taps()
        let (graph, sink) = graph(Settings(taps: taps))
        let level = try #require(sink.screen?.children.first)
        let form = try #require(level.children.first)
        #expect(form.type == "Form")
        #expect(form.children.map(\.type) == ["Section", "Menu", "Alert"])

        let menu = form.children[1]
        #expect(menu.props == ["title": "Sort", "systemImage": "arrow.up.arrow.down"])
        #expect(menu.children.map(\.type) == ["Button", "Divider", "Menu"])
        #expect(menu.children[2].props == ["title": "More"])
        #expect(graph.handle(menu.children[0].id, kind: .tap))
        #expect(graph.handle(try #require(menu.children[2].find("Button")).id, kind: .tap))
        #expect(taps.names == ["name", "date"])
    }

    @Test func confirmationDialogsAreAlertsInStyle() throws {
        let taps = Taps()
        let (graph, sink) = graph(Settings(taps: taps))
        var dialog = try #require(sink.screen?.find("Alert"))
        #expect(dialog.props == ["title": "Sign out?", "isPresented": false, "style": "dialog", "titleVisibility": "visible"])
        graph.handle(try #require(dialog.find("Button")).id, kind: .tap)
        graph.update()
        dialog = try #require(sink.screen?.find("Alert"))
        #expect(dialog.props["isPresented"] == true)
        let action = try #require(dialog.children.last)
        #expect(action.props == ["role": "destructive"])
        graph.handle(action.id, kind: .tap)
        #expect(taps.names == ["signOut"])
    }

    @Test func toolbarsBelongToTheirLevel() throws {
        let taps = Taps()
        let (graph, sink) = graph(Settings(taps: taps))
        let level = try #require(sink.screen?.children.first)
        #expect(level.props["title"] == "Settings")
        #expect(level.children.map(\.type) == ["Form", "ToolbarItem", "ToolbarItem"])
        let items = level.children.dropFirst()
        #expect(items.map { $0.props["placement"] } == ["primaryAction", "automatic"])
        #expect(items.map(\.texts) == [["Add"], ["Edit"]])
        for item in items {
            graph.handle(try #require(item.find("Button")).id, kind: .tap)
        }
        #expect(taps.names == ["add", "edit"])

        // The same IDs next time.
        graph.setNeedsUpdate()
        graph.update()
        #expect(sink.screen?.children.first?.children.map(\.id) == level.children.map(\.id))
    }

    @Test func toolbarsOutsideAStackAreDropped() throws {
        let (_, sink) = graph(LooseToolbar())
        #expect(sink.screen?.type == "Text")
        #expect(sink.screen?.texts == ["No stack"])
    }

    // MARK: Grids, disclosure groups, links, swipe actions and search

    func shelf(_ library: Library) throws -> (ViewGraph, TestSink, RenderNode) {
        let (graph, sink) = graph(Shelf(library: library))
        let level = try #require(sink.screen?.children.first)
        let searchable = try #require(level.children.first)
        return (graph, sink, searchable)
    }

    @Test func gridsHaveRowsOfCells() throws {
        let (_, _, searchable) = try shelf(Library())
        let grid = try #require(searchable.find("Grid"))
        #expect(grid.props == ["horizontal": "leading", "vertical": "center", "horizontalSpacing": 12.0, "verticalSpacing": 8.0])
        #expect(grid.children.map(\.type) == ["GridRow", "Divider", "GridRow"])
        #expect(grid.children[0].texts == ["Title", "Year"])
        #expect(grid.children[0].props == [:])
        #expect(grid.children[2].props == ["alignment": "bottom"])
    }

    @Test func disclosureGroupsShowContentWhileExpanded() throws {
        let library = Library()
        let (graph, sink, searchable) = try shelf(library)
        var groups = searchable.children[0].children.filter { $0.type == "DisclosureGroup" }
        #expect(groups.map { $0.props["isExpanded"] } == [false, false])
        #expect(groups.map(\.texts) == [["Details"], ["Notes"]], "only the labels")

        // Bound to the model.
        #expect(graph.handle(groups[0].id, kind: .change, payload: true))
        #expect(library.showsDetails)
        // Kept by the group itself.
        graph.handle(groups[1].id, kind: .change, payload: true)
        graph.update()
        groups = try #require(sink.screen?.children.first?.children.first?.children.first?.children.filter { $0.type == "DisclosureGroup" })
        #expect(groups.map(\.texts) == [["Details", "Two books"], ["Notes", "None yet"]])
    }

    @Test func linksCarryTheirURL() throws {
        let (_, _, searchable) = try shelf(Library())
        let link = try #require(searchable.find("Link"))
        #expect(link.props == ["url": "https://example.com"])
        #expect(link.texts == ["Website"])
    }

    @Test func swipeActionsWrapTheirRow() throws {
        let library = Library()
        let (graph, sink, searchable) = try shelf(library)
        let list = try #require(searchable.find("List"))
        let row = try #require(list.children.first)
        #expect(row.type == "SwipeActions")
        #expect(row.props == ["edge": "leading", "allowsFullSwipe": false])
        #expect(row.children.map(\.type) == ["SwipeActions", "Button"])
        let trailing = row.children[0]
        #expect(trailing.props == ["edge": "trailing", "allowsFullSwipe": true])
        #expect(trailing.children.map(\.texts) == [["Dune"], ["Delete"]])
        #expect(trailing.children[1].props == ["role": "destructive"])

        #expect(graph.handle(trailing.children[1].id, kind: .tap))
        #expect(library.books.map(\.title) == ["Emma"])
        graph.update()
        #expect(sink.screen?.find("List")?.children.count == 1)
    }

    @Test func searchFieldsSyncTheirText() throws {
        let library = Library()
        let (graph, _, searchable) = try shelf(library)
        #expect(searchable.type == "Searchable")
        #expect(searchable.props == ["text": "", "prompt": "Books"])
        #expect(searchable.children.map(\.type) == ["VStack"])
        #expect(graph.handle(searchable.id, kind: .change, payload: "Du"))
        #expect(library.query == "Du")
        #expect(graph.handle(searchable.id, kind: .submit))
        #expect(library.searches == 1)
    }
}
