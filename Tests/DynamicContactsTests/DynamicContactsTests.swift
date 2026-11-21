import Testing
import DynamicContacts
import DynamicRuntime
import RuntimeCore
import RuntimeNative

/// A host's contact record that only holds what it's given.
final class ScriptedContactRecord: ContactRecord {

    nonisolated(unsafe) static var saved: [(record: ScriptedContactRecord, callback: any ContactCallback)] = []

    nonisolated(unsafe) static var removed: [(record: ScriptedContactRecord, callback: any ContactCallback)] = []

    var id = ""
    var name = ""
    var parts: [String] = []
    var phones: (labels: [String], values: [String]) = ([], [])
    var emails: (labels: [String], values: [String]) = ([], [])
    var links: (labels: [String], values: [String]) = ([], [])
    var addresses: [String] = []
    var born = ""

    func identifier() -> String { id }
    func displayName() -> String { name }
    func nameParts() -> [String] { parts }
    func phoneLabels() -> [String] { phones.labels }
    func phoneNumbers() -> [String] { phones.values }
    func emailLabels() -> [String] { emails.labels }
    func emailAddresses() -> [String] { emails.values }
    func urlLabels() -> [String] { links.labels }
    func urls() -> [String] { links.values }
    func postalAddresses() -> [String] { addresses }
    func birthday() -> String { born }

    func setIdentifier(_ identifier: String) { id = identifier }
    func setNameParts(_ parts: [String]) { self.parts = parts }
    func setPhones(_ labels: [String], numbers: [String]) { phones = (labels, numbers) }
    func setEmails(_ labels: [String], addresses: [String]) { emails = (labels, addresses) }
    func setURLs(_ labels: [String], urls: [String]) { links = (labels, urls) }
    func setPostalAddresses(_ fields: [String]) { addresses = fields }
    func setBirthday(_ date: String) { born = date }

    func save(_ callback: any ContactCallback) {
        Self.saved.append((self, callback))
    }

    func remove(_ callback: any ContactCallback) {
        Self.removed.append((self, callback))
    }
}

/// A host's contacts that only write down what they're asked, and keep the
/// callbacks for the test to answer.
final class ScriptedContacts: Contacts {

    /// The one store, as a host has: the guest keeps what it's given.
    nonisolated(unsafe) static let instance = ScriptedContacts()

    var calls: [String] = []

    var callbacks: [any ContactCallback] = []

    var delegate: (any ContactsDelegate)?

    var level: Int32 = 0

    static func shared() -> ScriptedContacts { instance }

    func access() -> Int32 { level }

    func requestAccess(_ callback: any ContactCallback) {
        calls.append("requestAccess")
        callbacks.append(callback)
    }

    func setDelegate(_ delegate: (any ContactsDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }

    func contacts(_ text: String, all: Bool, limit: Int32, callback: any ContactCallback) {
        calls.append("contacts [\(text)] \(all) \(limit)")
        callbacks.append(callback)
    }

    func contact(_ identifier: String, callback: any ContactCallback) {
        calls.append("contact \(identifier)")
        callbacks.append(callback)
    }

    func makeContact() -> any ContactRecord {
        ScriptedContactRecord()
    }
}

/// Serialized: the tests share the native runtime and the scripted host's
/// one store.
@Suite(.serialized) final class DynamicContactsTests {

    let host = ScriptedContacts.instance

    let store = ContactStore.default

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        ContactsProxy.register(ScriptedContacts.self, in: native)
        ContactRecordProxy.register(ScriptedContactRecord.self, in: native)
        ContactCallbackProxy.registerInterface(in: native)
        ContactsDelegateProxy.registerInterface(in: native)
        store.onChange(nil)
        host.calls = []
        host.callbacks = []
        host.level = 0
        ScriptedContactRecord.saved = []
        ScriptedContactRecord.removed = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func error<Value>(_ result: Result<Value, ContactStoreError>?) -> ContactStoreError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    /// Someone with something in every field.
    static var ada: Contact {
        var ada = Contact()
        ada.namePrefix = "Countess"
        ada.givenName = "Ada"
        ada.middleName = "King"
        ada.familyName = "Lovelace"
        ada.nameSuffix = "FRS"
        ada.nickname = "AAL"
        ada.organizationName = "Analytical Engines"
        ada.departmentName = "Notes"
        ada.jobTitle = "Programmer"
        ada.phoneNumbers = [LabeledValue(.mobile, "+353 1 555 0100"), LabeledValue("Lab", "0100")]
        ada.emailAddresses = [LabeledValue(.work, "ada@example.com")]
        ada.urls = [LabeledValue(.home, "https://example.com/ada")]
        ada.postalAddresses = [
            LabeledValue(.home, PostalAddress(street: "12 St James's Square", city: "London", region: "", postalCode: "SW1Y", country: "United Kingdom", isoCountryCode: "GB")),
            LabeledValue(.work, PostalAddress(city: "Dublin", isoCountryCode: "IE")),
        ]
        ada.birthday = ContactDate(year: 1815, month: 12, day: 10)
        return ada
    }

    // MARK: Contracts

    @Test func theStoreRequiresContacts() {
        let contacts = ContactsProxy.descriptor
        #expect(contacts.name == "org.pureswift.contacts.Contacts")
        #expect(contacts.capability == .contacts)
        #expect(method(contacts, "access")?.signature == Signature("()I"))
        #expect(method(contacts, "contacts:all:limit:callback:")?.signature == Signature("(OZIO)V"))
        #expect(method(contacts, "makeContact")?.signature == Signature("()O"))
        #expect(contacts.methods.count == 7)

        let record = ContactRecordProxy.descriptor
        #expect(record.name == "org.pureswift.contacts.Contact" && record.capability == nil)
        #expect(method(record, "nameParts")?.signature == Signature("()O"))
        #expect(method(record, "setPhones:numbers:")?.signature == Signature("(OO)V"))
        #expect(method(record, "save:")?.signature == Signature("(O)V"))
        #expect(record.methods.count == 20)

        let callback = ContactCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.contacts.Callback" && callback.kind == .callback)
        #expect(callback.methods.count == 5)
        let delegate = ContactsDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.contacts.Delegate" && delegate.kind == .callback)
        #expect(delegate.methods.count == 1)

        let descriptors = [contacts, record, callback, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Types

    @Test func labelsAreWordsOrTheUsersOwn() {
        #expect(ContactLabel.standard.map(\.rawValue) == ["home", "work", "mobile", "main", "other", "homeFax", "workFax", "pager"])
        #expect(ContactLabel.mobile.isStandard && !ContactLabel("Lab").isStandard)
        #expect(ContactLabel("work") == .work && ContactLabel(rawValue: "Lab") == "Lab")
        #expect(LabeledValue(.home, "a") != LabeledValue(.work, "a") && LabeledValue(.home, "a") == LabeledValue(.home, "a"))
        #expect(ContactStoreAccess.authorized.allowsReading && ContactStoreAccess.limited.allowsReading)
        #expect(!ContactStoreAccess.denied.allowsReading && !ContactStoreAccess.notDetermined.allowsReading && !ContactStoreAccess.unavailable.allowsReading)
        #expect(PostalAddress().isEmpty && !PostalAddress(isoCountryCode: "IE").isEmpty)
    }

    @Test func aBirthdayMayHaveNoYear() {
        #expect(ContactDate(year: 1815, month: 12, day: 10).text == "1815-12-10")
        #expect(ContactDate(month: 2, day: 9).text == "--02-09")
        #expect(ContactDate(year: 33, month: 1, day: 1).text == "0033-01-01")
        #expect(ContactDate(text: "1815-12-10") == ContactDate(year: 1815, month: 12, day: 10))
        #expect(ContactDate(text: "--02-29") == ContactDate(month: 2, day: 29))
        for bad in ["", "1815", "1815-13-10", "1815-12-32", "--13-01", "1815/12/10", "-12-10", "18151210", "1815-12-1x"] {
            #expect(ContactDate(text: bad) == nil, "\(bad)")
        }
    }

    @Test func aContactIsAValue() {
        var contact = Contact()
        #expect(contact.isEmpty && contact.id == nil && contact.displayName == "")
        contact.nickname = "Bob"
        #expect(!contact.isEmpty)
        contact.nickname = ""
        contact.birthday = ContactDate(month: 1, day: 1)
        #expect(!contact.isEmpty)
        #expect(contact.named("Robert").displayName == "Robert" && contact.displayName == "", "a store names a copy")

        #expect(Self.ada.nameParts == ["Countess", "Ada", "King", "Lovelace", "FRS", "AAL", "Analytical Engines", "Notes", "Programmer"])
        var short = Contact()
        short.nameParts = ["", "Grace"]
        #expect(short.givenName == "Grace" && short.jobTitle == "", "what a host leaves off is empty")

        #expect(Contact.labeled(["home", "work", "odd"], ["a", "b"]) == [LabeledValue(.home, "a"), LabeledValue(.work, "b")], "what has no partner is left out")
        let fields = Contact.fields(Self.ada.postalAddresses)
        #expect(fields.count == 14 && fields[0] == "home" && fields[6] == "GB" && fields[7] == "work" && fields[9] == "Dublin")
        #expect(Contact.addresses(fields) == Self.ada.postalAddresses)
        #expect(Contact.addresses(fields + ["stray", "fields"]) == Self.ada.postalAddresses, "whole sevens only")
    }

    // MARK: The store

    @Test func accessIsWhatTheHostSays() {
        #expect(store.access == .notDetermined)
        host.level = 4
        #expect(store.access == .limited)
        host.level = 3
        #expect(store.access == .authorized)
        host.level = 77
        #expect(store.access == .denied, "a level from a newer host isn't one to rely on")

        var answers: [ContactStoreAccess] = []
        store.requestAccess { answers.append($0) }
        store.requestAccess { answers.append($0) }
        host.callbacks[0].didChangeAccess(4)
        host.callbacks[0].didChangeAccess(2)
        host.callbacks[1].didComplete()
        #expect(answers == [.limited, .denied], "only a first answer counts, and anything odd is no")
    }

    @Test func aContactCrossesFieldByField() throws {
        var ada = Self.ada
        ada.id = "abc"
        store.save(ada) { _ in }
        let sent = try #require(ScriptedContactRecord.saved.last).record
        #expect(sent.id == "abc" && sent.parts == ada.nameParts)
        #expect(sent.phones.labels == ["mobile", "Lab"] && sent.phones.values == ["+353 1 555 0100", "0100"])
        #expect(sent.emails.labels == ["work"] && sent.emails.values == ["ada@example.com"])
        #expect(sent.links.labels == ["home"] && sent.links.values == ["https://example.com/ada"])
        #expect(sent.addresses.count == 14 && sent.born == "1815-12-10")

        // Read back, with the name the store gave, it's the same person.
        sent.name = "Countess Ada King Lovelace FRS"
        #expect(Contact(sent) == ada.named("Countess Ada King Lovelace FRS"))

        // A new contact has no identity to send, and what it lacks is empty.
        var plain = Contact()
        plain.givenName = "Grace"
        store.save(plain) { _ in }
        let new = try #require(ScriptedContactRecord.saved.last).record
        #expect(new.id == "" && new.parts[1] == "Grace" && new.phones.values.isEmpty && new.addresses.isEmpty && new.born == "")
        #expect(Contact(new) == plain)

        // What a host sends that isn't a date is no birthday.
        new.born = "long ago"
        #expect(Contact(new).birthday == nil)
    }

    @Test func theStoreAsksTheHost() throws {
        var lists: [Result<[Contact], ContactStoreError>] = []
        var found: [Result<Contact?, ContactStoreError>] = []
        store.contacts { lists.append($0) }
        store.contacts(matching: "ad") { lists.append($0) }
        store.contacts(matching: "ad", limit: 8) { lists.append($0) }
        store.contacts(matching: "ad", limit: -3) { lists.append($0) }
        store.contact(withID: "abc") { found.append($0) }
        store.contact(withID: "gone") { found.append($0) }
        #expect(host.calls == ["contacts [] true 0", "contacts [ad] false 0", "contacts [ad] false 8", "contacts [ad] false 0", "contact abc", "contact gone"])

        let record = ScriptedContactRecord()
        record.id = "abc"
        record.name = "Ada Lovelace"
        host.callbacks[0].didListContacts([record, record])
        host.callbacks[1].didListContacts([])
        host.callbacks[2].didFail(ContactStoreError.notAuthorized.rawValue)
        host.callbacks[3].didComplete()
        #expect(try lists[0].get().map(\.displayName) == ["Ada Lovelace", "Ada Lovelace"])
        #expect(try lists[1].get().isEmpty && error(lists[2]) == .notAuthorized)
        #expect(error(lists[3]) == .unknown, "an answer of the wrong kind")
        host.callbacks[4].didFindContact(record)
        host.callbacks[5].didFindContact(nil)
        #expect(try found[0].get()?.id == "abc")
        if case .success(let none) = found[1] { #expect(none == nil, "gone isn't an error") } else { Issue.record("no contact was a failure") }
    }

    @Test func savingAndRemovingAnswerOnce() throws {
        var saves: [Result<Contact, ContactStoreError>] = []
        var removals: [Result<Void, ContactStoreError>] = []
        store.save(Self.ada) { saves.append($0) }
        store.save(Self.ada) { saves.append($0) }
        store.save(Self.ada) { saves.append($0) }
        store.remove(Self.ada) { removals.append($0) }
        store.remove(Self.ada) { removals.append($0) }

        let record = ScriptedContactRecord()
        record.id = "made"
        ScriptedContactRecord.saved[0].callback.didFindContact(record)
        ScriptedContactRecord.saved[0].callback.didFail(0)
        ScriptedContactRecord.saved[1].callback.didFindContact(nil)
        ScriptedContactRecord.saved[2].callback.didFail(ContactStoreError.readOnly.rawValue)
        #expect(saves.count == 3 && (try? saves[0].get())?.id == "made")
        #expect(error(saves[1]) == .unknown, "a save that gives no contact back")
        #expect(error(saves[2]) == .readOnly)

        ScriptedContactRecord.removed[0].callback.didComplete()
        ScriptedContactRecord.removed[1].callback.didFail(77)
        #expect(error(removals[0]) == nil && error(removals[1]) == .unknown, "an error from a newer host")
    }

    @Test func oneListenerHearsOfChanges() {
        var first = 0
        var second = 0
        store.onChange { first += 1 }
        host.delegate?.didChange()
        store.onChange { second += 1 }
        host.delegate?.didChange()
        host.delegate?.didChange()
        #expect(first == 1 && second == 2, "a new closure replaces the one before")
        store.onChange(nil)
        #expect(host.delegate == nil && host.calls == ["setDelegate", "setDelegate", "setDelegate nil"])
    }
}
