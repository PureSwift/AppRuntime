import Dispatch
import DynamicContacts

/// An address book in memory: for a host's tests, and as the contract's
/// rules in their plainest form for a host writing a directory over its
/// platform's own to compare with.
///
/// It is not a store a user's contacts should be in, and `HostContacts`
/// never uses it unasked: it holds nothing after the process ends, and
/// syncs with nothing.
///
/// It names a person by their name's parts in the order written, lists
/// people by family name and then given name, and finds them by the start
/// of any word of their name or of an email address, without regard to
/// case.
public final class MemoryContactDirectory: ContactDirectory, @unchecked Sendable {

    private let lock = DispatchQueue(label: "org.pureswift.runtime.contacts.memory")

    private var people: [String: Contact] = [:]

    private var readOnly: Set<String> = []

    private var nextIdentifier = 1

    public init() { }

    /// How many people it holds.
    public var count: Int {
        lock.sync { people.count }
    }

    /// Marks a person as one that can't be changed, as a company
    /// directory's are.
    public func protect(_ identifier: String) {
        lock.sync { _ = readOnly.insert(identifier) }
    }

    private func locked<Value>(_ body: () throws(ContactStoreError) -> Value) throws(ContactStoreError) -> Value {
        let result: Result<Value, ContactStoreError> = lock.sync {
            do throws(ContactStoreError) {
                return .success(try body())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    // MARK: Names

    /// A person's name as this directory formats it: the parts in the
    /// order written; without a name, the nickname, the organization, an
    /// email address or a phone number.
    public static func displayName(of contact: Contact) -> String {
        let name = [contact.namePrefix, contact.givenName, contact.middleName, contact.familyName, contact.nameSuffix]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if let email = contact.emailAddresses.first { return email.value }
        if let phone = contact.phoneNumbers.first { return phone.value }
        return ""
    }

    /// What a person is listed by: family name, then given name, then
    /// whatever names them.
    private static func sortKey(_ contact: Contact) -> [String] {
        let family = contact.familyName.isEmpty ? contact.displayName : contact.familyName
        return [family.lowercased(), contact.givenName.lowercased(), contact.displayName.lowercased(), contact.id ?? ""]
    }

    private static func precedes(_ first: Contact, _ second: Contact) -> Bool {
        sortKey(first).lexicographicallyPrecedes(sortKey(second))
    }

    /// Whether any word of `text` begins with `prefix`, which is in lower
    /// case.
    private static func hasWord(_ text: String, startingWith prefix: String) -> Bool {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(prefix) }
    }

    // MARK: Finding

    public func contacts() throws(ContactStoreError) -> [Contact] {
        lock.sync { people.values.sorted(by: Self.precedes) }
    }

    public func contacts(matching text: String, limit: Int?) throws(ContactStoreError) -> [Contact] {
        let wanted = String(text.lowercased().drop { $0.isWhitespace })
        return lock.sync {
            let everyone = people.values.sorted(by: Self.precedes)
            // By name first, then by an address alone.
            let byName = everyone.filter { contact in
                (contact.nameParts.prefix(7) + [contact.displayName]).contains { Self.hasWord($0, startingWith: wanted) }
            }
            let byEmail = everyone.filter { contact in
                !byName.contains(contact) && contact.emailAddresses.contains { $0.value.lowercased().hasPrefix(wanted) }
            }
            let found = byName + byEmail
            return limit.map { Array(found.prefix($0)) } ?? found
        }
    }

    public func contact(withID identifier: String) throws(ContactStoreError) -> Contact? {
        lock.sync { people[identifier] }
    }

    // MARK: Changing

    public func save(_ contact: Contact) throws(ContactStoreError) -> Contact {
        try locked { () throws(ContactStoreError) in
            var contact = contact
            if let identifier = contact.id {
                guard people[identifier] != nil else {
                    throw .notFound
                }
                guard !readOnly.contains(identifier) else {
                    throw .readOnly
                }
            } else {
                contact.id = "contact-\(nextIdentifier)"
                nextIdentifier += 1
            }
            let named = contact.named(Self.displayName(of: contact))
            people[named.id ?? ""] = named
            return named
        }
    }

    public func remove(_ contact: Contact) throws(ContactStoreError) {
        try locked { () throws(ContactStoreError) in
            guard let identifier = contact.id, people[identifier] != nil else {
                throw .notFound
            }
            guard !readOnly.contains(identifier) else {
                throw .readOnly
            }
            people[identifier] = nil
        }
    }
}
