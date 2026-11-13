import DynamicRuntime
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example UI app: an observable model, a counter, a text field, a
/// picker, a searchable lazy list with swipe actions that pushes detail
/// forms, a toolbar menu, an alert, a confirmation dialog, a disclosure
/// group with a link, and a sheet with tabs and grids.
@Observable
final class Store {
    var name: String = "World"
    var count: Int = 0
    var favorite: Int = 1
    var query: String = ""
    var items: [Fruit] = [
        Fruit(id: 1, name: "Apple"),
        Fruit(id: 2, name: "Banana"),
        Fruit(id: 3, name: "Cherry"),
    ]
}

struct Fruit: Identifiable {
    let id: Int
    let name: String
}

struct FruitDetail: View {
    let fruit: Fruit
    @State var likes = 0
    @State var confirmingReset = false

    var body: some View {
        Form {
            Section("Likes") {
                Button("Like (\(likes))") { likes += 1 }
            }
            Section {
                DisclosureGroup("More About \(fruit.name)") {
                    Text("Fruit number \(fruit.id).")
                    Link("Search the Web", destination: "https://duckduckgo.com/?q=\(fruit.name)")
                }
            }
            Section {
                Button("Reset Likes…", role: .destructive) { confirmingReset = true }
                    .confirmationDialog("Reset the likes for \(fruit.name)?", isPresented: $confirmingReset, titleVisibility: .visible) {
                        Button("Reset Likes", role: .destructive) { likes = 0 }
                    }
            }
        }
        .navigationTitle(fruit.name)
    }
}

/// The sheet: a tab view with a grid of swatches and an about page.
struct AboutView: View {
    @Binding var isPresented: Bool

    let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]

    var body: some View {
        TabView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 12) {
                    ForEach(0..<colors.count) { index in
                        colors[index]
                            .frame(height: 60)
                            .cornerRadius(8)
                    }
                }
                .padding()
            }
            .tabItem { Label("Colors", systemImage: "square.grid.2x2") }
            VStack(spacing: 12) {
                Text("ExampleUI").font(.title)
                Text("Rendered from an AppRuntime guest.")
                Grid(alignment: .leading, horizontalSpacing: 16) {
                    GridRow {
                        Text("Frontend").foregroundColor(.secondary)
                        Text("DynamicSwiftUI")
                    }
                    GridRow {
                        Text("Renderer").foregroundColor(.secondary)
                        Text("SwiftUI")
                    }
                }
                Button("Done") { isPresented = false }
                    .accessibilityIdentifier("done")
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

struct ContentView: View {
    @Bindable var store: Store
    @State var showingAbout = false
    @State var confirmingReset = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Hello, \(store.name)!")
                    .font(.title)
                    .accessibilityIdentifier("greeting")
                TextField("Name", text: $store.name)
                HStack {
                    Button("−") { store.count -= 1 }
                    Text("\(store.count)").accessibilityIdentifier("count")
                    Button("+") { store.count += 1 }
                    Button("Reset", role: .destructive) { confirmingReset = true }
                        .alert("Reset the count?", isPresented: $confirmingReset) {
                            Button("Reset", role: .destructive) { store.count = 0 }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("It goes back to zero.")
                        }
                }
                Picker("Favorite", selection: $store.favorite) {
                    ForEach(store.items) { fruit in
                        Text(fruit.name)
                    }
                }
                .pickerStyle(.segmented)
                Button("About") { showingAbout = true }
                    .sheet(isPresented: $showingAbout) {
                        AboutView(isPresented: $showingAbout)
                    }
                List(store.items.filter { store.query.isEmpty || $0.name.hasPrefix(store.query) }) { fruit in
                    NavigationLink(fruit.name, destination: FruitDetail(fruit: fruit))
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                store.items.removeAll { $0.id == fruit.id }
                            }
                        }
                }
            }
            .padding()
            .searchable(text: $store.query, prompt: "Fruit")
            .navigationTitle("Example")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Button("By Name") { store.items.sort { $0.name < $1.name } }
                        Button("Reversed") { store.items.reverse() }
                    }
                }
            }
        }
    }
}

struct ExampleUIApp: App {
    let store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleUIMain() -> rt_status {
    Runtime.main { ExampleUIApp.run() }
}
