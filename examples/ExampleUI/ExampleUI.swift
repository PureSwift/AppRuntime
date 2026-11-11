import DynamicRuntime
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example UI app: an observable model, a counter, a text field and a
/// lazy list that pushes detail screens.
@Observable
final class Store {
    var name: String = "World"
    var count: Int = 0
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

    var body: some View {
        VStack(spacing: 12) {
            Text(fruit.name).font(.largeTitle)
            Button("Like (\(likes))") { likes += 1 }
        }
        .navigationTitle(fruit.name)
    }
}

struct ContentView: View {
    @Bindable var store: Store

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
                }
                List(store.items) { fruit in
                    NavigationLink(fruit.name, destination: FruitDetail(fruit: fruit))
                }
            }
            .padding()
            .navigationTitle("Example")
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
