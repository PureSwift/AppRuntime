import DynamicRuntime
import DynamicContacts
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example contacts app: an address book. It asks for the user's
/// contacts, lists everyone in the system's order, finds people as a name
/// is typed, shows one person's details, adds someone, changes them,
/// removes them, and looks again whenever the store says it changed.

/// One line of the list.
struct Row: Identifiable {
    let id: String
    let text: String
}

/// The closures hold the book, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class AddressBook: @unchecked Sendable {

    var status: String = "Not asked"

    var rows: [Row] = []

    /// What's typed into the search field.
    var search: String = ""

    /// The details of the first person listed.
    var detail: String = ""

    @ObservationIgnored var people: [Contact] = []

    @ObservationIgnored let store = ContactStore.default

    func start() {
        // The store says when anything changes, this app's own saves
        // included: one place to look again.
        store.onChange {
            self.reload()
        }
        show(store.access)
    }

    func allow() {
        store.requestAccess { access in
            self.show(access)
        }
    }

    func show(_ access: ContactStoreAccess) {
        switch access {
        case .authorized, .limited:
            reload()
        case .notDetermined:
            status = "Not asked"
        case .unavailable:
            status = "No contacts here"
        default:
            status = "Not allowed"
        }
    }

    func find(_ text: String) {
        search = text
        reload()
    }

    /// Everyone, or the people the search finds.
    func reload() {
        let wanted = search
        let finish: (Result<[Contact], ContactStoreError>) -> Void = { result in
            // Something else was typed meanwhile.
            guard wanted == self.search else { return }
            switch result {
            case .success(let people):
                self.people = people
                self.rows = people.map { Row(id: $0.id ?? "", text: Self.line($0)) }
                self.detail = people.first.map(Self.describe) ?? ""
                self.status = people.isEmpty ? "No one" : "\(people.count) people"
            case .failure(let error):
                self.report(error)
            }
        }
        if wanted.isEmpty {
            store.contacts(completion: finish)
        } else {
            // As a To: field would: a few, best first.
            store.contacts(matching: wanted, limit: 5, completion: finish)
        }
    }

    func addAda() {
        var ada = Contact()
        ada.givenName = "Ada"
        ada.familyName = "Lovelace"
        ada.phoneNumbers = [LabeledValue(.mobile, "+353 1 555 0100")]
        ada.emailAddresses = [LabeledValue(.work, "ada@example.com")]
        ada.postalAddresses = [LabeledValue(.home, PostalAddress(city: "London", isoCountryCode: "GB"))]
        ada.birthday = ContactDate(year: 1815, month: 12, day: 10)
        save(ada)
    }

    /// Changes the Ada the store finds: a job, and a second address.
    func promoteAda() {
        withAda { ada in
            var ada = ada
            ada.organizationName = "Analytical Engines"
            ada.jobTitle = "Programmer"
            ada.emailAddresses.append(LabeledValue(.home, "ada@lovelace.example"))
            self.save(ada)
        }
    }

    func removeAda() {
        withAda { ada in
            self.store.remove(ada) { result in
                if case .failure(let error) = result {
                    self.report(error)
                }
            }
        }
    }

    /// Looked up by her family name: the first word of several names
    /// begins with "Ada".
    func withAda(_ body: @escaping (Contact) -> Void) {
        store.contacts(matching: "Lovelace", limit: 1) { result in
            switch result {
            case .success(let found):
                if let ada = found.first {
                    body(ada)
                } else {
                    self.status = "No Ada"
                }
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func save(_ contact: Contact) {
        store.save(contact) { result in
            if case .failure(let error) = result {
                self.report(error)
            }
        }
    }

    func report(_ error: ContactStoreError) {
        switch error {
        case .notAuthorized: status = "Not allowed"
        case .unavailable: status = "No contacts here"
        case .readOnly: status = "That person can't be changed"
        case .notFound: status = "They're gone"
        default: status = "Contacts error \(error.rawValue)"
        }
    }

    /// "Ada Lovelace, ada@example.com": the name the store formatted, and
    /// the first way to reach them.
    static func line(_ contact: Contact) -> String {
        if let email = contact.emailAddresses.first, email.value != contact.displayName {
            return contact.displayName + ", " + email.value
        }
        if let phone = contact.phoneNumbers.first, phone.value != contact.displayName {
            return contact.displayName + ", " + phone.value
        }
        return contact.displayName
    }

    /// Everything about one person, a part to a line.
    static func describe(_ contact: Contact) -> String {
        var lines: [String] = []
        if !contact.jobTitle.isEmpty || !contact.organizationName.isEmpty {
            lines.append([contact.jobTitle, contact.organizationName].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        for phone in contact.phoneNumbers {
            lines.append(phone.label.rawValue + ": " + phone.value)
        }
        for email in contact.emailAddresses {
            lines.append(email.label.rawValue + ": " + email.value)
        }
        for address in contact.postalAddresses {
            lines.append(address.label.rawValue + ": " + [address.value.city, address.value.isoCountryCode].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        if let birthday = contact.birthday {
            lines.append("born " + birthday.text)
        }
        return lines.joined(separator: "; ")
    }
}

struct ContentView: View {

    let book: AddressBook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(book.status)
                .accessibilityIdentifier("status")
            HStack(spacing: 8) {
                Button("Allow") { book.allow() }
                Button("Add Ada") { book.addAda() }
                Button("Promote Ada") { book.promoteAda() }
                Button("Remove Ada") { book.removeAda() }
            }
            TextField("Search", text: Binding(get: { book.search }, set: { book.find($0) }))
                .autocorrectionDisabled()
                .accessibilityIdentifier("search")
            ForEach(book.rows) { row in
                Text(row.text)
                    .textSelection(.enabled)
            }
            Text(book.detail)
                .accessibilityIdentifier("detail")
        }
        .padding()
    }
}

struct ExampleContactsApp: App {

    let book = AddressBook()

    init() {
        book.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(book: book)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleContactsMain() -> rt_status {
    Runtime.main { ExampleContactsApp.run() }
}
