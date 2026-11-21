import DynamicRuntime

/// The people in the user's address book, as the system keeps them
/// (`Documentation/Contracts/Contacts.md`). App code uses `ContactStore`,
/// which wraps this contract.
///
/// The store is the system's: its accounts are set up and synced there. A
/// contact is the unified person, with every account's values together,
/// in the system's order and with the system's formatting of the name.
/// Every operation completes through its `callback`, which the host holds
/// until it has called exactly one of its methods, on the main thread.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `CNContactStore` |
/// | Android | `ContactsContract`, through the `ContentResolver` |
/// | Linux | the host's contacts service |
/// | Browser | none |
@DynamicRuntime("org.pureswift.contacts.Contacts", requires: .contacts)
public protocol Contacts: AnyObject {

    static func shared() -> Self

    /// A `ContactStoreAccess` raw value. Never asks.
    func access() -> Int32

    /// Asks the user if they haven't decided. Answered by
    /// `didChangeAccess`.
    func requestAccess(_ callback: ContactCallback)

    /// Told after any change to the store. `nil` stops it.
    func setDelegate(_ delegate: ContactsDelegate?)

    /// People who match `text`, best first; with `all`, everyone, in the
    /// system's order. `limit` 0 is no limit. Answered by
    /// `didListContacts`.
    func contacts(_ text: String, all: Bool, limit: Int32, callback: ContactCallback)

    /// Answered by `didFindContact`.
    func contact(_ identifier: String, callback: ContactCallback)

    /// A contact to fill in and save: a new one, until it's told which
    /// contact it is.
    func makeContact() -> ContactRecord
}

/// One person. The host's object: the guest reads one that arrives, and
/// fills one in to save.
///
/// A label is a word for the eight the contract names (`home`, `work`,
/// `mobile`, `main`, `other`, `homeFax`, `workFax`, `pager`) and the
/// user's own text for any other.
@DynamicRuntime("org.pureswift.contacts.Contact")
public protocol ContactRecord: AnyObject {

    // MARK: Reading

    /// Empty for one that isn't saved.
    func identifier() -> String

    /// The whole name, as the system formats it.
    func displayName() -> String

    /// Nine, in this order: prefix, given, middle, family, suffix,
    /// nickname, organization, department, job title.
    func nameParts() -> [String]

    /// A label for each number, and as many of one as the other.
    func phoneLabels() -> [String]

    func phoneNumbers() -> [String]

    func emailLabels() -> [String]

    func emailAddresses() -> [String]

    func urlLabels() -> [String]

    func urls() -> [String]

    /// Seven for each address: label, street, city, region, postal code,
    /// country, ISO country code.
    func postalAddresses() -> [String]

    /// `1815-12-10`, or `--12-10` with no year; empty for none.
    func birthday() -> String

    // MARK: Filling in

    /// Which contact this is, to change one the store has.
    func setIdentifier(_ identifier: String)

    func setNameParts(_ parts: [String])

    func setPhones(_ labels: [String], numbers: [String])

    func setEmails(_ labels: [String], addresses: [String])

    func setURLs(_ labels: [String], urls: [String])

    func setPostalAddresses(_ fields: [String])

    func setBirthday(_ date: String)

    // MARK: Storing

    /// Adds the contact, or changes the one it's told it is. Answered by
    /// `didFindContact`, with the contact as the store now has it.
    func save(_ callback: ContactCallback)

    /// Answered by `didComplete`.
    func remove(_ callback: ContactCallback)
}

/// One operation's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.contacts.Callback")
public protocol ContactCallback: AnyObject {

    func didComplete()

    /// A `ContactStoreAccess` raw value.
    func didChangeAccess(_ access: Int32)

    func didListContacts(_ contacts: [ContactRecord])

    func didFindContact(_ contact: ContactRecord?)

    /// A `ContactStoreError` raw value.
    func didFail(_ error: Int32)
}

/// What a store tells the app, from the host. Called on the main thread.
@DynamicCallback("org.pureswift.contacts.Delegate")
public protocol ContactsDelegate: AnyObject {

    /// Something changed: another app, a sync, or this app. Not what.
    func didChange()
}
