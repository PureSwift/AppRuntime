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

struct Grid: View {

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
        let (graph, sink) = graph(Grid(lazy: true))
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
        let (_, sink) = graph(Grid(lazy: false))
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
}
