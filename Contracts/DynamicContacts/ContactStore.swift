import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The people in the user's address book: `CNContactStore`'s place.
///
/// ```swift
/// let store = ContactStore.default
/// guard try await store.requestAccess().allowsReading else { return }
/// let people = try await store.contacts()
/// let matches = try await store.contacts(matching: "ad", limit: 8)
/// ```
///
/// The store is the system's: it holds the accounts and syncs them, joins
/// one person's cards into one `Contact`, formats names and orders the
/// list. An app whose manifest declares reading alone can't `save` or
/// `remove`.
///
/// Every call is asynchronous, with a completion-handler form. It's
/// guest-side only, over the `Contacts` contract, which requires
/// `.contacts` in the manifest. The guest is single-threaded (§6.4).
public final class ContactStore: @unchecked Sendable {

    /// The system's store.
    public static let `default` = ContactStore()

    /// The host's store, made when first used.
    private var made: (any Contacts)?

    private let listener = Listener()

    init() { }

    private var store: any Contacts {
        if let made {
            return made
        }
        let store = ContactsProxy.shared()
        made = store
        return store
    }

    // MARK: Access

    /// Whether the app may use the contacts now. Never asks.
    public var access: ContactStoreAccess {
        // An access from a newer host isn't one to rely on.
        ContactStoreAccess(rawValue: store.access()) ?? .denied
    }

    /// Asks the user if they haven't decided, and gives what the app has
    /// afterwards.
    public func requestAccess(completion: @escaping (ContactStoreAccess) -> Void) {
        store.requestAccess(Receiver { outcome in
            if case .access(let access) = outcome {
                completion(access)
            } else {
                completion(.denied)
            }
        })
    }

    // MARK: Finding

    /// Everyone, in the system's order.
    public func contacts(completion: @escaping (Result<[Contact], ContactStoreError>) -> Void) {
        store.contacts("", all: true, limit: 0, callback: Receiver.listing(completion))
    }

    /// People whose name or email address matches `text`, best first, and
    /// `limit` of them at most. The search is the system's own: it finds a
    /// person by the start of any word of their name, without regard to
    /// case, at least. An empty text matches no one.
    public func contacts(matching text: String, limit: Int? = nil, completion: @escaping (Result<[Contact], ContactStoreError>) -> Void) {
        store.contacts(text, all: false, limit: Int32(clamping: max(limit ?? 0, 0)), callback: Receiver.listing(completion))
    }

    /// One person by their identifier; `nil` when they're gone.
    public func contact(withID identifier: String, completion: @escaping (Result<Contact?, ContactStoreError>) -> Void) {
        store.contact(identifier, callback: Receiver { outcome in
            if case .contact(let contact) = outcome {
                completion(.success(contact))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Changing

    /// Adds a contact with no `id`, or changes the one it names, and gives
    /// it back as the store now has it. What a `Contact` doesn't carry,
    /// such as a photo, is kept.
    public func save(_ contact: Contact, completion: @escaping (Result<Contact, ContactStoreError>) -> Void) {
        let record = store.makeContact()
        contact.fill(record)
        record.save(Receiver { outcome in
            if case .contact(let saved?) = outcome {
                completion(.success(saved))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Deletes a contact the store has.
    public func remove(_ contact: Contact, completion: @escaping (Result<Void, ContactStoreError>) -> Void) {
        let record = store.makeContact()
        contact.fill(record)
        record.remove(Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Changes

    /// Called when anything in the store changed: another app, a sync, or
    /// this app. It doesn't say what; fetch again. One listener at a time:
    /// a new closure, or a `changes` stream, replaces it, and `nil` stops
    /// it.
    public func onChange(_ handler: (() -> Void)?) {
        listener.handler = handler
        store.setDelegate(handler == nil ? nil : listener)
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func requestAccess() async -> ContactStoreAccess {
        await withCallback { (callback: Callback<ContactStoreAccess, Never>) in
            self.requestAccess { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: .denied)
        }
    }

    public nonisolated(nonsending) func contacts() async throws(ContactStoreError) -> [Contact] {
        try await wait { self.contacts(completion: $0) }
    }

    public nonisolated(nonsending) func contacts(matching text: String, limit: Int? = nil) async throws(ContactStoreError) -> [Contact] {
        try await wait { self.contacts(matching: text, limit: limit, completion: $0) }
    }

    public nonisolated(nonsending) func contact(withID identifier: String) async throws(ContactStoreError) -> Contact? {
        try await wait { self.contact(withID: identifier, completion: $0) }
    }

    @discardableResult
    public nonisolated(nonsending) func save(_ contact: Contact) async throws(ContactStoreError) -> Contact {
        try await wait { self.save(contact, completion: $0) }
    }

    public nonisolated(nonsending) func remove(_ contact: Contact) async throws(ContactStoreError) {
        try await wait { self.remove(contact, completion: $0) }
    }

    /// One element each time the store changes. Ending the loop stops
    /// listening. It replaces an `onChange` closure, and another stream.
    public var changes: EventStream<Void, Never> {
        let (stream, continuation) = EventStream<Void, Never>.makeStream()
        listener.generation &+= 1
        let generation = listener.generation
        onChange {
            continuation.yield(())
        }
        continuation.onTermination = { [listener, store] in
            // Unless something else listens by now.
            guard listener.generation == generation else { return }
            listener.handler = nil
            store.setDelegate(nil)
        }
        return stream
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(_ start: (@escaping (Result<Value, ContactStoreError>) -> Void) -> Void) async throws(ContactStoreError) -> Value {
        try await withCallback { (callback: Callback<Value, ContactStoreError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// The delegate the host holds.
private final class Listener: ContactsDelegate {

    var handler: (() -> Void)?

    /// Counts listeners, so a stream that ends knows whether it's still
    /// the one listening.
    var generation = 0

    func didChange() {
        handler?()
    }
}

/// What a `ContactCallback` was told.
private enum Outcome {

    case complete
    case access(ContactStoreAccess)
    case contacts([Contact])
    case contact(Contact?)
    case failure(ContactStoreError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: ContactStoreError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: ContactCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
    }

    /// For the operations that answer `didListContacts`.
    static func listing(_ completion: @escaping (Result<[Contact], ContactStoreError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .contacts(let contacts) = outcome {
                completion(.success(contacts))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: Outcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didChangeAccess(_ access: Int32) {
        answer(.access(ContactStoreAccess(rawValue: access) ?? .denied))
    }

    func didListContacts(_ contacts: [any ContactRecord]) {
        answer(.contacts(contacts.map { Contact($0) }))
    }

    func didFindContact(_ contact: (any ContactRecord)?) {
        answer(.contact(contact.map { Contact($0) }))
    }

    func didFail(_ error: Int32) {
        answer(.failure(ContactStoreError(rawValue: error) ?? .unknown))
    }
}
