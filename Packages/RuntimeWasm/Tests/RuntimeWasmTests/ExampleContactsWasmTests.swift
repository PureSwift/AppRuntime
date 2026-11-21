import Foundation
import Testing
import DynamicContacts
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeContacts
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// The list's rows: every text the user can select.
private func people(_ node: RenderNode?) -> [String] {
    guard let node else { return [] }
    var rows: [String] = []
    if node.type == "Text", node.modifiers.contains(where: { $0.kind == "textSelection" }), case .string(let text)? = node.props["text"] {
        rows.append(text)
    }
    for child in node.children {
        rows += people(child)
    }
    return rows
}

private func someone(_ given: String, _ family: String, email: String) -> Contact {
    var contact = Contact()
    contact.givenName = given
    contact.familyName = family
    contact.emailAddresses = [LabeledValue(.work, email)]
    return contact
}

/// The example contacts app as App.wasm under WasmKit, with the shared
/// host implementation over an address book in memory: the guest's
/// `ContactStore`, the `Contacts` contract and its record, and
/// `HostContacts`, end to end. Part of `WasmShimTests`, which is
/// serialized, since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleContacts`; skipped without it.
    static var exampleContactsURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleContacts/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleContactsURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleContacts"))
    func exampleContactsInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        // The user's address book, as other apps and a sync left it.
        let directory = MemoryContactDirectory()
        _ = try directory.save(someone("Grace", "Hopper", email: "grace@navy.example"))
        _ = try directory.save(someone("Alan", "Turing", email: "alan@bletchley.example"))
        var company = Contact()
        company.organizationName = "Adastral Park"
        company.phoneNumbers = [LabeledValue(.main, "+44 1473 555 0100")]
        _ = try directory.save(company)
        var questions = 0
        HostContacts.reset()
        HostContacts.directory = directory
        HostContacts.requester = { completion in
            questions += 1
            completion(.authorized)
        }
        HostContacts.work = { $0() }
        HostContacts.deliver = { $0() }
        HostContactsModule.register(in: native)
        defer { HostContacts.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleContactsURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.contacts])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.contacts.Contacts" }?.capability == .contacts)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func type(_ search: String) throws {
            renderer.send(try #require(renderer.screen?.identified("search")), .change, .string(search))
        }
        func rows() -> [String] {
            people(renderer.screen)
        }

        // Nothing is read before the user is asked.
        #expect(text("status") == "Not asked" && rows().isEmpty && questions == 0)
        try tap("Add Ada")
        #expect(text("status") == "Not allowed" && directory.count == 3)
        try tap("Allow")
        #expect(questions == 1 && text("status") == "3 people")
        #expect(rows() == [
            "Adastral Park, +44 1473 555 0100", "Grace Hopper, grace@navy.example", "Alan Turing, alan@bletchley.example",
        ], "in the system's order, with the names it formatted")
        #expect(text("detail") == "Adastral Park; main: +44 1473 555 0100", "the first one's details")

        // A new person is named and placed by the store.
        try tap("Add Ada")
        #expect(directory.count == 4 && text("status") == "4 people")
        #expect(rows()[2] == "Ada Lovelace, ada@example.com", "between Hopper and Turing")
        let ada = try #require(try directory.contacts(matching: "lovelace", limit: nil).first)
        #expect(ada.phoneNumbers == [LabeledValue(.mobile, "+353 1 555 0100")] && ada.birthday == ContactDate(year: 1815, month: 12, day: 10))
        #expect(ada.postalAddresses == [LabeledValue(.home, PostalAddress(city: "London", isoCountryCode: "GB"))])

        // Finding is the store's: by the start of any word of a name.
        try type("ad")
        #expect(rows() == ["Adastral Park, +44 1473 555 0100", "Ada Lovelace, ada@example.com"] && text("status") == "2 people")
        try type("LOVE")
        #expect(rows() == ["Ada Lovelace, ada@example.com"])
        #expect(text("detail") == "mobile: +353 1 555 0100; work: ada@example.com; home: London, GB; born 1815-12-10")
        try type("nobody")
        #expect(rows().isEmpty && text("status") == "No one" && text("detail") == "")

        // A change is a whole contact saved again; what wasn't touched stays.
        try type("love")
        try tap("Promote Ada")
        #expect(text("detail") == .string("Programmer, Analytical Engines; mobile: +353 1 555 0100; work: ada@example.com; "
            + "home: ada@lovelace.example; home: London, GB; born 1815-12-10"))
        #expect(directory.count == 4, "the same person")

        // Another app adds someone, and the store says so.
        try type("")
        #expect(rows().count == 4)
        _ = try directory.save(someone("Adele", "Goldberg", email: "adele@parc.example"))
        #expect(rows().count == 4, "not seen until the store says")
        HostContacts.storeChanged()
        #expect(rows().count == 5 && rows()[1] == "Adele Goldberg, adele@parc.example")

        try tap("Remove Ada")
        #expect(directory.count == 4 && !rows().contains("Ada Lovelace, ada@example.com") && text("status") == "4 people")
        try tap("Remove Ada")
        #expect(text("status") == "No Ada")

        // The user takes the access back in the system's settings.
        HostContacts.access = .denied
        try type("gr")
        #expect(text("status") == "Not allowed")
        #expect(questions == 1, "asked once")
    }
}
