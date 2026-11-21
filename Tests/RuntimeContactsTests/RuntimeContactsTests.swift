import Foundation
import Testing
import DynamicContacts
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeContacts

/// `HostContacts` over an address book in memory, driven from the guest's
/// `ContactStore` through the runtime.
///
/// Serialized: `HostContacts` and the native runtime are shared.
@Suite(.serialized) final class RuntimeContactsTests {

    let directory = MemoryContactDirectory()

    let store = ContactStore.default

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostContacts.reset()
        HostContacts.directory = directory
        HostContacts.access = .authorized
        HostContacts.work = { $0() }
        HostContacts.deliver = { $0() }
        HostContactsModule.register(in: native)
        store.onChange(nil)
    }

    deinit {
        HostContacts.reset()
    }

    // MARK: Helpers

    func failure<Value>(_ result: Result<Value, ContactStoreError>?) -> ContactStoreError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    func save(_ contact: Contact) -> Result<Contact, ContactStoreError>? {
        var result: Result<Contact, ContactStoreError>?
        store.save(contact) { result = $0 }
        return result
    }

    func saved(_ contact: Contact) throws -> Contact {
        try #require(save(contact)).get()
    }

    func remove(_ contact: Contact) -> ContactStoreError? {
        var result: Result<Void, ContactStoreError>?
        store.remove(contact) { result = $0 }
        return failure(result)
    }

    func everyone() -> Result<[Contact], ContactStoreError>? {
        var result: Result<[Contact], ContactStoreError>?
        store.contacts { result = $0 }
        return result
    }

    func matching(_ text: String, limit: Int? = nil) -> Result<[Contact], ContactStoreError>? {
        var result: Result<[Contact], ContactStoreError>?
        store.contacts(matching: text, limit: limit) { result = $0 }
        return result
    }

    /// The names of who a search finds.
    func names(_ text: String, limit: Int? = nil) throws -> [String] {
        try #require(matching(text, limit: limit)).get().map(\.displayName)
    }

    func contact(_ identifier: String) -> Result<Contact?, ContactStoreError>? {
        var result: Result<Contact?, ContactStoreError>?
        store.contact(withID: identifier) { result = $0 }
        return result
    }

    func person(_ given: String, _ family: String, email: String? = nil) -> Contact {
        var contact = Contact()
        contact.givenName = given
        contact.familyName = family
        if let email {
            contact.emailAddresses = [LabeledValue(.work, email)]
        }
        return contact
    }

    /// Five people and a company.
    func fill() throws {
        _ = try saved(person("Ada", "Lovelace", email: "ada@example.com"))
        _ = try saved(person("Grace", "Hopper", email: "grace@navy.example"))
        _ = try saved(person("Alan", "Turing", email: "alan@bletchley.example"))
        _ = try saved(person("Adele", "Goldberg", email: "adele@parc.example"))
        _ = try saved(person("Mary Ann", "Horton", email: "mah@example.com"))
        var company = Contact()
        company.organizationName = "Adastral Park"
        company.phoneNumbers = [LabeledValue(.main, "+44 1473 555 0100")]
        _ = try saved(company)
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostContactsModule.contracts.map(\.name) == [
            "org.pureswift.contacts.Contacts", "org.pureswift.contacts.Contact",
            "org.pureswift.contacts.Callback", "org.pureswift.contacts.Delegate",
        ])
        let permission = HostContactsModule.permissionProviders()[.contacts]
        #expect(permission?.status() == .granted)
        HostContacts.access = .limited
        #expect(permission?.status() == .limited)
        HostContacts.access = .denied
        #expect(permission?.status() == .denied)
        HostContacts.directory = nil
        #expect(permission?.status() == .unavailable)
        #expect(HostContacts.shared() === HostContacts.shared())
    }

    @Test func withoutADirectoryThereAreNoContacts() {
        HostContacts.directory = nil
        #expect(store.access == .unavailable)
        #expect(failure(everyone()) == .unavailable && failure(matching("a")) == .unavailable)
        #expect(failure(save(person("Ada", "Lovelace"))) == .unavailable && failure(contact("x")) == .unavailable)
        var asked: ContactStoreAccess?
        store.requestAccess { asked = $0 }
        #expect(asked == .unavailable)
    }

    // MARK: Access

    @Test func theUserIsAskedOnce() throws {
        HostContacts.access = .notDetermined
        var questions = 0
        var answer = ContactStoreAccess.authorized
        HostContacts.requester = { completion in
            questions += 1
            completion(answer)
            completion(.denied)
        }
        #expect(store.access == .notDetermined)
        #expect(failure(everyone()) == .notAuthorized && failure(save(person("Ada", "Lovelace"))) == .notAuthorized)

        var granted: [ContactStoreAccess] = []
        store.requestAccess { granted.append($0) }
        store.requestAccess { granted.append($0) }
        #expect(granted == [.authorized, .authorized] && questions == 1, "a second answer isn't heard, and it isn't asked again")
        #expect(failure(everyone()) == nil)

        HostContacts.access = .notDetermined
        answer = .limited
        store.requestAccess { granted.append($0) }
        #expect(granted.last == .limited)
        _ = try saved(person("Ada", "Lovelace"))
        #expect(try everyone()?.get().count == 1, "the contacts the user chose are a store like any other")

        HostContacts.access = .notDetermined
        answer = .denied
        store.requestAccess { granted.append($0) }
        #expect(granted.last == .denied && failure(everyone()) == .notAuthorized && failure(contact("contact-1")) == .notAuthorized)
        #expect(questions == 3)
    }

    @Test func anAppThatDeclaredReadingNeverWrites() throws {
        let ada = try saved(person("Ada", "Lovelace", email: "ada@example.com"))
        HostContacts.allowsWriting = false
        #expect(store.access == .authorized)
        #expect(try names("ada") == ["Ada Lovelace"] && contact("contact-1")?.get() == ada, "it reads as before")
        #expect(failure(save(person("Grace", "Hopper"))) == .notAuthorized)
        var changed = ada
        changed.jobTitle = "Programmer"
        #expect(failure(save(changed)) == .notAuthorized && remove(ada) == .notAuthorized)
        #expect(directory.count == 1)
        #expect(try directory.contact(withID: "contact-1") == ada)
    }

    // MARK: Contacts

    @Test func aContactIsSavedAndFound() throws {
        var ada = person("Ada", "Lovelace")
        ada.namePrefix = "Countess"
        ada.nickname = "AAL"
        ada.organizationName = "Analytical Engines"
        ada.jobTitle = "Programmer"
        ada.phoneNumbers = [LabeledValue(.mobile, " +353 (1) 555-0100 "), LabeledValue("Lab", "0100")]
        ada.emailAddresses = [LabeledValue(.work, "Ada@Example.com")]
        ada.urls = [LabeledValue(.home, "https://example.com/ada")]
        ada.postalAddresses = [LabeledValue(.home, PostalAddress(street: "12 St James's Square", city: "London", postalCode: "SW1Y", country: "United Kingdom", isoCountryCode: "GB"))]
        ada.birthday = ContactDate(year: 1815, month: 12, day: 10)

        let stored = try saved(ada)
        #expect(stored.id == "contact-1" && stored.displayName == "Countess Ada Lovelace", "the store names her")
        var expected = ada
        expected.id = "contact-1"
        #expect(stored == expected.named("Countess Ada Lovelace"), "every value as it was given, the number's spaces too")
        #expect(try contact("contact-1")?.get() == stored)
        if case .success(let none)? = contact("contact-9") { #expect(none == nil, "gone isn't an error") } else { Issue.record("no contact was a failure") }

        // The lists a contact is saved with are the ones it then has.
        var changed = stored
        changed.phoneNumbers = [LabeledValue(.work, "0200")]
        changed.emailAddresses = []
        changed.namePrefix = ""
        changed.birthday = ContactDate(month: 12, day: 10)
        let updated = try saved(changed)
        #expect(updated.id == "contact-1" && updated.displayName == "Ada Lovelace" && directory.count == 1)
        #expect(updated.phoneNumbers == [LabeledValue(.work, "0200")] && updated.emailAddresses.isEmpty && updated.birthday?.year == nil)
        #expect(updated.urls == stored.urls && updated.postalAddresses == stored.postalAddresses, "what wasn't touched stays")

        #expect(remove(updated) == nil && directory.count == 0)
        #expect(remove(updated) == .notFound && failure(save(updated)) == .notFound)
        #expect(remove(person("Never", "Saved")) == .notFound)
    }

    @Test func aNameFallsBackToWhatThereIs() throws {
        var nicknamed = Contact()
        nicknamed.nickname = "Woz"
        #expect(try saved(nicknamed).displayName == "Woz")
        var company = Contact()
        company.organizationName = "Analytical Engines"
        company.jobTitle = "Reception"
        #expect(try saved(company).displayName == "Analytical Engines")
        var address = Contact()
        address.emailAddresses = [LabeledValue(.other, "someone@example.com")]
        address.phoneNumbers = [LabeledValue(.mobile, "0100")]
        #expect(try saved(address).displayName == "someone@example.com")
        var number = Contact()
        number.phoneNumbers = [LabeledValue(.mobile, "0100")]
        #expect(try saved(number).displayName == "0100")
        var full = person("Mary", "Shelley")
        full.middleName = "Wollstonecraft"
        full.nameSuffix = "II"
        #expect(try saved(full).displayName == "Mary Wollstonecraft Shelley II")

        #expect(failure(save(Contact())) == .invalidContact, "nothing in it")
        var named = Contact().named("Only a display name")
        named.id = nil
        #expect(failure(save(named)) == .invalidContact, "a name an app can't set isn't something in it")
        #expect(directory.count == 5)
    }

    @Test func someoneWhoCanNotBeChangedIsReadOnly() throws {
        let colleague = try saved(person("Charles", "Babbage"))
        directory.protect("contact-1")
        var changed = colleague
        changed.jobTitle = "Inventor"
        #expect(failure(save(changed)) == .readOnly && remove(colleague) == .readOnly)
        #expect(try contact("contact-1")?.get() == colleague)
    }

    // MARK: Finding

    @Test func everyoneIsListedInTheSystemsOrder() throws {
        try fill()
        #expect(try everyone()?.get().map(\.displayName) == [
            "Adastral Park", "Adele Goldberg", "Grace Hopper", "Mary Ann Horton", "Ada Lovelace", "Alan Turing",
        ], "by family name, and a company by its own")
    }

    @Test func aSearchFindsTheStartOfAnyWord() throws {
        try fill()
        #expect(try names("ad") == ["Adastral Park", "Adele Goldberg", "Ada Lovelace"], "names first, in the list's order")
        #expect(try names("AD") == names("ad") && names("  ad") == names("ad"), "without regard to case")
        #expect(try names("lov") == ["Ada Lovelace"] && names("ann") == ["Mary Ann Horton"], "any word of the name")
        #expect(try names("ovel") == [], "the start of a word, not its middle")
        #expect(try names("park") == ["Adastral Park"])
        #expect(try names("mah") == ["Mary Ann Horton"], "by the start of an address")
        #expect(try names("a") == ["Adastral Park", "Adele Goldberg", "Mary Ann Horton", "Ada Lovelace", "Alan Turing"])
        #expect(try names("grace hopper") == [], "one word at a time, here")
        #expect(try names("zz") == [])

        #expect(try names("a", limit: 2) == ["Adastral Park", "Adele Goldberg"])
        #expect(try names("a", limit: 0).count == 5, "no limit")
        #expect(try names("") == [] && names("   ") == [], "an empty text matches no one")
    }

    // MARK: Changes

    @Test func aBurstOfChangesIsSaidOnce() throws {
        nonisolated(unsafe) var held: [@Sendable () -> Void] = []
        var changes = 0
        store.onChange { changes += 1 }
        let ada = try saved(person("Ada", "Lovelace"))
        #expect(changes == 1, "this app's own save")
        #expect(remove(ada) == nil && changes == 2)
        #expect(failure(save(Contact())) == .invalidContact && changes == 2, "a save that failed changed nothing")

        HostContacts.deliver = { held.append($0) }
        HostContacts.storeChanged()
        HostContacts.storeChanged()
        HostContacts.storeChanged()
        let jobs = held
        held = []
        #expect(jobs.count == 1 && changes == 2, "a sync touches many people")
        jobs.forEach { $0() }
        #expect(changes == 3)
        HostContacts.deliver = { $0() }

        store.onChange(nil)
        HostContacts.storeChanged()
        #expect(changes == 3, "nobody listens")
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded.

    @MainActor @Test func callsCanBeAwaited() async throws {
        HostContacts.work = { job in DispatchQueue.global().async(execute: job) }
        HostContacts.deliver = { DispatchQueue.main.async(execute: $0) }
        #expect(await store.requestAccess() == .authorized)
        var ada = try await store.save(person("Ada", "Lovelace", email: "ada@example.com"))
        _ = try await store.save(person("Alan", "Turing"))
        #expect(try await store.contacts().map(\.displayName) == ["Ada Lovelace", "Alan Turing"])
        #expect(try await store.contacts(matching: "tur", limit: 3).map(\.displayName) == ["Alan Turing"])
        #expect(try await store.contact(withID: try #require(ada.id)) == ada)

        // The stream hears of this app's own change.
        let changes = store.changes
        let listening = Task { @MainActor in
            for await _ in changes { return true }
            return false
        }
        await Task.yield()
        ada.jobTitle = "Programmer"
        ada = try await store.save(ada)
        #expect(await listening.value)
        try await store.remove(ada)
        #expect(try await store.contacts().count == 1)

        do {
            try await store.remove(ada)
            Issue.record("someone was removed twice")
        } catch {
            #expect(error == .notFound)
        }
    }
}
