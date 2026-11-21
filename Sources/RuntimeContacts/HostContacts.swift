import Dispatch
import DynamicContacts
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// The platform's address book: `CNContactStore`, the contacts provider.
/// It works in the guest's own values. It's called off the main thread, by
/// one thread at a time, in the order the guest asked.
///
/// A contact is the unified person, with the system's formatting of the
/// name as its `displayName`. `HostContacts` has checked access before a
/// directory sees a call.
public protocol ContactDirectory: AnyObject, Sendable {

    /// Everyone, in the system's order.
    func contacts() throws(ContactStoreError) -> [Contact]

    /// People who match `text`, which isn't empty, best first, and `limit`
    /// of them at most. The platform's own search: by the start of any
    /// word of a name, without regard to case, at least.
    func contacts(matching text: String, limit: Int?) throws(ContactStoreError) -> [Contact]

    /// `nil` when there's none.
    func contact(withID identifier: String) throws(ContactStoreError) -> Contact?

    /// Adds a contact with no `id`, or changes the one it names, keeping
    /// what the store holds of it that a `Contact` doesn't carry. The
    /// lists it has replace the ones there were. Gives the contact as
    /// stored, named. A person who can't be changed is `readOnly`.
    func save(_ contact: Contact) throws(ContactStoreError) -> Contact

    func remove(_ contact: Contact) throws(ContactStoreError)
}

/// The `Contacts` contract over a host's `ContactDirectory`: what every
/// host written in Swift shares.
///
/// It checks access before every call, refuses a write by an app that
/// declared reading alone and a contact with nothing in it, runs the
/// directory off the main thread in order, makes the records, and gathers
/// a burst of changes into one report.
///
/// ```swift
/// HostContacts.directory = MyContactStore()
/// HostContacts.allowsWriting = true                 // RTCapabilityOptions.contacts.access
/// HostContacts.access = .notDetermined              // what the platform says now
/// HostContacts.requester = { completion in … }       // the platform's question
/// HostContactsModule.register(in: runtime)
///
/// HostContacts.storeChanged()                       // from the platform
/// ```
///
/// Without a directory every call fails with `unavailable`. Main thread
/// only.
public final class HostContacts: Contacts {

    // MARK: The host's settings

    /// The platform's address book.
    nonisolated(unsafe) public static var directory: (any ContactDirectory)?

    /// What the user has granted, as the platform says.
    nonisolated(unsafe) public static var access = ContactStoreAccess.notDetermined

    /// Whether the manifest declares writing: `readWrite`, and not
    /// `readOnly`. An app that declared reading alone never writes,
    /// whatever the user granted.
    nonisolated(unsafe) public static var allowsWriting = true

    /// Asks the user, and says what they granted. Called on the main
    /// thread while `access` is `.notDetermined`.
    nonisolated(unsafe) public static var requester: ((@escaping (ContactStoreAccess) -> Void) -> Void)?

    /// Runs the directory's work off the main thread. The default is a
    /// serial queue; whatever replaces it must keep the order.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.contacts")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// The one store. Never replaced: a guest keeps the object it first
    /// asked for.
    nonisolated(unsafe) private static let instance = HostContacts()

    public static func shared() -> HostContacts {
        instance
    }

    /// Forgets the directory, the settings and the guest's delegate, for
    /// tests and for a host that starts the guest again.
    public static func reset() {
        directory = nil
        access = .notDetermined
        allowsWriting = true
        requester = nil
        work = defaultWork
        deliver = defaultDeliver
        instance.delegate = nil
        instance.changePending = false
    }

    /// What the app has now: what the user granted, and nothing without a
    /// directory.
    public static var effectiveAccess: ContactStoreAccess {
        directory == nil ? .unavailable : access
    }

    /// Something in the platform's store changed: another app, a sync. A
    /// burst of these reaches the guest as one `didChange`.
    public static func storeChanged() {
        let instance = Self.instance
        guard !instance.changePending else { return }
        instance.changePending = true
        deliver {
            let instance = HostContacts.shared()
            guard instance.changePending else { return }
            instance.changePending = false
            instance.delegate?.didChange()
        }
    }

    // MARK: State

    private var delegate: (any ContactsDelegate)?

    private var changePending = false

    // MARK: Answers

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any ContactCallback, _ answer: @escaping (any ContactCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func fail(_ callback: any ContactCallback, _ error: ContactStoreError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    /// The directory, when the app may read it, and write it if `writing`;
    /// otherwise the callback is failed.
    private static func directory(for callback: any ContactCallback, writing: Bool) -> (any ContactDirectory)? {
        guard let directory else {
            fail(callback, .unavailable)
            return nil
        }
        guard access.allowsReading, !writing || allowsWriting else {
            fail(callback, .notAuthorized)
            return nil
        }
        return directory
    }

    /// Runs `operation` off the main thread, and answers `callback` on it
    /// with what `answer` makes of the result.
    private static func run<Value: Sendable>(
        _ callback: any ContactCallback,
        _ operation: @escaping @Sendable () throws(ContactStoreError) -> Value,
        _ answer: @escaping (any ContactCallback, Value) -> Void
    ) {
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld((callback, answer))
        let deliver = Self.deliver
        work {
            let result: Result<Value, ContactStoreError>
            do throws(ContactStoreError) {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }
            deliver {
                guard let (callback, answer) = held.take() else { return }
                switch result {
                case .success(let value):
                    answer(callback, value)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    // MARK: Access

    public func access() -> Int32 {
        Self.effectiveAccess.rawValue
    }

    /// Asks the user if they haven't decided, and says what the app has.
    public static func requestAccess(_ completion: @escaping (ContactStoreAccess) -> Void) {
        guard directory != nil, access == .notDetermined, let requester else {
            completion(effectiveAccess)
            return
        }
        var answered = false
        requester { granted in
            // A platform that answers twice is heard once.
            guard !answered else { return }
            answered = true
            access = granted
            completion(effectiveAccess)
        }
    }

    public func requestAccess(_ callback: any ContactCallback) {
        Self.requestAccess { access in
            Self.later(callback) { $0.didChangeAccess(access.rawValue) }
        }
    }

    public func setDelegate(_ delegate: (any ContactsDelegate)?) {
        self.delegate = delegate
    }

    // MARK: Finding

    public func contacts(_ text: String, all: Bool, limit: Int32, callback: any ContactCallback) {
        guard let directory = Self.directory(for: callback, writing: false) else { return }
        let limit = limit > 0 ? Int(limit) : nil
        Self.run(callback, { () throws(ContactStoreError) in
            if all {
                let everyone = try directory.contacts()
                return limit.map { Array(everyone.prefix($0)) } ?? everyone
            }
            // An empty text matches no one.
            guard text.contains(where: { !$0.isWhitespace }) else { return [] }
            let found = try directory.contacts(matching: text, limit: limit)
            return limit.map { Array(found.prefix($0)) } ?? found
        }) { callback, contacts in
            callback.didListContacts(contacts.map { HostContactRecord($0) })
        }
    }

    public func contact(_ identifier: String, callback: any ContactCallback) {
        guard let directory = Self.directory(for: callback, writing: false) else { return }
        Self.run(callback, { () throws(ContactStoreError) in try directory.contact(withID: identifier) }) { callback, contact in
            callback.didFindContact(contact.map { HostContactRecord($0) })
        }
    }

    public func makeContact() -> any ContactRecord {
        HostContactRecord(Contact())
    }

    // MARK: Changing

    fileprivate static func save(_ contact: Contact, callback: any ContactCallback) {
        guard let directory = directory(for: callback, writing: true) else { return }
        guard !contact.isEmpty else {
            fail(callback, .invalidContact)
            return
        }
        run(callback, { () throws(ContactStoreError) in
            if let identifier = contact.id, try directory.contact(withID: identifier) == nil {
                throw .notFound
            }
            return try directory.save(contact)
        }) { callback, saved in
            callback.didFindContact(HostContactRecord(saved))
            storeChanged()
        }
    }

    fileprivate static func remove(_ contact: Contact, callback: any ContactCallback) {
        guard let directory = directory(for: callback, writing: true) else { return }
        guard let identifier = contact.id else {
            fail(callback, .notFound)
            return
        }
        run(callback, { () throws(ContactStoreError) in
            guard try directory.contact(withID: identifier) != nil else {
                throw .notFound
            }
            try directory.remove(contact)
        }) { callback, _ in
            callback.didComplete()
            storeChanged()
        }
    }
}

/// One person: what the guest reads when one arrives, and fills in to
/// save.
public final class HostContactRecord: ContactRecord {

    public private(set) var contact: Contact

    init(_ contact: Contact) {
        self.contact = contact
    }

    public func identifier() -> String { contact.id ?? "" }
    public func displayName() -> String { contact.displayName }
    public func nameParts() -> [String] { contact.nameParts }
    public func phoneLabels() -> [String] { contact.phoneNumbers.map { $0.label.rawValue } }
    public func phoneNumbers() -> [String] { contact.phoneNumbers.map { $0.value } }
    public func emailLabels() -> [String] { contact.emailAddresses.map { $0.label.rawValue } }
    public func emailAddresses() -> [String] { contact.emailAddresses.map { $0.value } }
    public func urlLabels() -> [String] { contact.urls.map { $0.label.rawValue } }
    public func urls() -> [String] { contact.urls.map { $0.value } }
    public func postalAddresses() -> [String] { Contact.fields(contact.postalAddresses) }
    public func birthday() -> String { contact.birthday?.text ?? "" }

    public func setIdentifier(_ identifier: String) {
        contact.id = identifier.isEmpty ? nil : identifier
    }

    public func setNameParts(_ parts: [String]) {
        contact.nameParts = parts
    }

    public func setPhones(_ labels: [String], numbers: [String]) {
        contact.phoneNumbers = Contact.labeled(labels, numbers)
    }

    public func setEmails(_ labels: [String], addresses: [String]) {
        contact.emailAddresses = Contact.labeled(labels, addresses)
    }

    public func setURLs(_ labels: [String], urls: [String]) {
        contact.urls = Contact.labeled(labels, urls)
    }

    public func setPostalAddresses(_ fields: [String]) {
        contact.postalAddresses = Contact.addresses(fields)
    }

    public func setBirthday(_ date: String) {
        contact.birthday = ContactDate(text: date)
    }

    public func save(_ callback: any ContactCallback) {
        HostContacts.save(contact, callback: callback)
    }

    public func remove(_ callback: any ContactCallback) {
        HostContacts.remove(contact, callback: callback)
    }
}

/// Contacts access as the built-in `Permissions` contract reports it.
public final class ContactsPermission: PermissionProvider {

    public init() { }

    static func status(_ access: ContactStoreAccess) -> PermissionStatus {
        switch access {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        case .limited: return .limited
        case .unavailable: return .unavailable
        }
    }

    public func status() -> PermissionStatus {
        Self.status(HostContacts.effectiveAccess)
    }

    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        HostContacts.requestAccess { completion(Self.status($0)) }
    }
}

/// The contacts module: the contract, its record, its callback and its
/// delegate.
public enum HostContactsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            ContactsProxy.descriptor, ContactRecordProxy.descriptor,
            ContactCallbackProxy.descriptor, ContactsDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        ContactsProxy.register(HostContacts.self, in: registrar)
        ContactRecordProxy.register(HostContactRecord.self, in: registrar)
        ContactCallbackProxy.registerInterface(in: registrar)
        ContactsDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.contacts: ContactsPermission()]
    }
}
