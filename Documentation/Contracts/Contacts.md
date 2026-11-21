# Contacts

**Status:** implemented in this repository: the guest side, and the part
of the host side every host written in Swift shares. No platform host has
an address book behind it yet, so no real contact has been read: the
tests keep the people in memory.

Module `DynamicContacts`: the people in the user's address book, as the
system keeps them. The Contacts framework's place.

The store is the system's, as the [calendar store](Calendars.md) is. Its
accounts are set up in the system and synced by it. The Contacts app
shows and edits what's there; a mail app looks up an address as the user
types a name.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Contacts` | contract, `requires: .contacts` | `CNContactStore` | `ContactsContract`, through the `ContentResolver` | the host's contacts service | none |
| `ContactRecord` | contract: one person | `CNContact` | a row of `Contacts`, with its `Data` rows | | |
| `ContactCallback` | callback: one operation's result | | | | |
| `ContactsDelegate` | callback: the store changed | `CNContactStoreDidChange` | a `ContentObserver` | | |

Guest-side Swift:

- **`ContactStore`**: the store app code uses. `CNContactStore`'s place.
- **`Contact`**: a value, as the app reads and writes it.
- `LabeledValue`, `ContactLabel`, `PostalAddress`, `ContactDate`,
  `ContactStoreAccess`, `ContactStoreError`.

The render IR doesn't change.

Host-side Swift, in `RuntimeContacts`: `HostContacts`, the contract over
a host's `ContactDirectory`, and `MemoryContactDirectory`.

## What shapes it

- **The system syncs.** iOS and Android already hold the user's contacts
  from each account and keep them current. An app here needs no CardDAV
  and no accounts of its own. On Linux that work is the host's contacts
  service.
- **One person, whatever the accounts.** Both platforms join the same
  person's cards from several accounts into one. A `Contact` is that
  person, as the system's own app shows them.
- **Most apps only read.** A mail app completes an address and changes
  nothing. Android asks for reading and writing apart, so the manifest
  says which.
- **The user may give a few, not all.** iOS 18 lets the user choose which
  contacts an app sees. The store then holds those, and nothing says the
  rest exist.
- **The name is the system's to format.** Whether the family name comes
  first depends on the language and on the person. The host gives a
  display name, and the order to list people in.
- **A value has several of most things.** Phone numbers, addresses: each
  with a label saying which.

## For a guest

```swift
import DynamicContacts

let store = ContactStore.default

guard await store.requestAccess().allowsReading else { return }

// Everyone, in the system's order.
let people = try await store.contacts()

// As the user types into a To: field.
let matches = try await store.contacts(matching: "ad", limit: 8)
for person in matches {
    for email in person.emailAddresses {
        suggest(person.displayName, email.value)
    }
}

// A new person.
var ada = Contact()
ada.givenName = "Ada"
ada.familyName = "Lovelace"
ada.phoneNumbers = [LabeledValue(.mobile, "+353 1 555 0100")]
ada.emailAddresses = [LabeledValue(.work, "ada@example.com")]
ada = try await store.save(ada)             // now she has an identifier

ada.organizationName = "Analytical Engines"
try await store.save(ada)
try await store.remove(ada)
```

### Access

| `ContactStore` | |
|---|---|
| `access` | `.notDetermined`, `.denied`, `.restricted`, `.authorized`, `.limited`, `.unavailable`. Never asks |
| `requestAccess()` | asks the user if they haven't decided |

- **`.limited` is the contacts the user chose.** Everything works, on
  those and on what the app adds.
- **The manifest says whether the app writes** (below). One that declared
  reading alone gets `notAuthorized` from `save` and `remove`.
- **`Permissions` works too,** as for any capability.
- **`allowsReading`** is true for `.authorized` and `.limited`.

### A contact

| `Contact` | |
|---|---|
| `id` | `nil` until it's saved |
| `displayName` | the whole name, as the system formats it. Read-only: the store makes it |
| `namePrefix`, `givenName`, `middleName`, `familyName`, `nameSuffix`, `nickname` | |
| `organizationName`, `departmentName`, `jobTitle` | |
| `phoneNumbers`, `emailAddresses`, `urls` | `[LabeledValue<String>]` |
| `postalAddresses` | `[LabeledValue<PostalAddress>]` |
| `birthday` | a `ContactDate`: a month and a day, and a year if it's known |

- **A `LabeledValue` is a label and a value.** `ContactLabel` has
  `.home`, `.work`, `.mobile`, `.main`, `.other`, `.homeFax`, `.workFax`,
  `.pager`, and any text of the user's own: `ContactLabel("Lab")`. The
  app says each in the user's language.
- **A `PostalAddress`** is `street`, `city`, `region`, `postalCode`,
  `country` and `isoCountryCode`.
- **`displayName` falls back** to the organization, then to an email
  address or a phone number, when there's no name.
- **A phone number is text,** as the user wrote it. Nothing tidies it.
- **`isEmpty`** says a contact has nothing in it. A display name isn't
  something in it: an app can't set one.
- **A `Contact` is a value.** It can be kept, compared and copied. To
  change one the store has, change the value and save it.

### Finding

| | |
|---|---|
| `contacts()` | everyone, in the system's order |
| `contacts(matching:limit:)` | people whose name or email address matches the text, best first; `limit` is how many at most |
| `contact(withID:)` | one, or `nil` when they're gone |

- **The order is the system's:** by family name or by given name, as the
  user set it, in their language's order.
- **Matching is the system's own search.** Every host finds a person by
  the start of any word of their name, without regard to case. What else
  it finds, such as by accents or by a phone number, is the platform's.
- **An empty text matches no one.**

### Saving and removing

- **`save` adds a contact with no `id`, or changes the one it names,**
  and gives it back as the store has it, with its `displayName`.
- **What the app doesn't carry is kept:** the photo, notes, and whatever
  else the store holds that isn't here.
- **The lists are saved whole.** The phone numbers a contact is saved
  with are the ones it then has.
- **A new contact goes where the system puts new ones:** the user's
  default account.
- **Some people can't be changed:** a company directory, a linked
  service. `save` and `remove` fail with `readOnly`.
- **A contact with nothing in it** fails with `invalidContact`.

### Changes

```swift
for await _ in store.changes {
    reload()
}
```

The store says that something changed, not what: another app, a sync, or
this app. `store.onChange { … }` is the same with a closure. Fetch again.

### Errors

| `ContactStoreError` | |
|---|---|
| `notAuthorized` | no access, or a write by an app that declared reading alone |
| `unavailable` | this host has no contacts store |
| `notFound` | the contact is gone |
| `readOnly` | this person can't be changed |
| `invalidContact` | nothing in it |
| `cancelled` | the task waiting was cancelled |

## The contract

```swift
@DynamicRuntime("org.pureswift.contacts.Contacts", requires: .contacts)
public protocol Contacts: AnyObject {

    static func shared() -> Self

    /// A `ContactStoreAccess` raw value. Never asks.
    func access() -> Int32
    /// Answered by `didChangeAccess`.
    func requestAccess(_ callback: ContactCallback)

    func setDelegate(_ delegate: ContactsDelegate?)

    /// People who match `text`, best first; everyone, in the system's
    /// order, when `all`. `limit` 0 is no limit. Answered by
    /// `didListContacts`.
    func contacts(_ text: String, all: Bool, limit: Int32, callback: ContactCallback)
    /// Answered by `didFindContact`.
    func contact(_ identifier: String, callback: ContactCallback)

    /// A contact to fill in and save: a new one, until it's told which
    /// contact it is.
    func makeContact() -> ContactRecord
}

@DynamicRuntime("org.pureswift.contacts.Contact")
public protocol ContactRecord: AnyObject {

    /// Empty for one that isn't saved.
    func identifier() -> String
    func displayName() -> String
    /// Nine, in this order: prefix, given, middle, family, suffix,
    /// nickname, organization, department, job title.
    func nameParts() -> [String]
    /// A label for each value, and as many of one as the other.
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

    func setIdentifier(_ identifier: String)
    func setNameParts(_ parts: [String])
    func setPhones(_ labels: [String], numbers: [String])
    func setEmails(_ labels: [String], addresses: [String])
    func setURLs(_ labels: [String], urls: [String])
    func setPostalAddresses(_ fields: [String])
    func setBirthday(_ date: String)

    /// Answered by `didFindContact`, with the contact as saved.
    func save(_ callback: ContactCallback)
    /// Answered by `didComplete`.
    func remove(_ callback: ContactCallback)
}

@DynamicCallback("org.pureswift.contacts.Callback")
public protocol ContactCallback: AnyObject {
    func didComplete()
    func didChangeAccess(_ access: Int32)
    func didListContacts(_ contacts: [ContactRecord])
    func didFindContact(_ contact: ContactRecord?)
    /// A `ContactStoreError` raw value.
    func didFail(_ error: Int32)
}

@DynamicCallback("org.pureswift.contacts.Delegate")
public protocol ContactsDelegate: AnyObject {
    func didChange()
}
```

A record is the host's object. The guest reads one into a `Contact` value
when it arrives, and lets it go. To save, it asks for a record with
`makeContact`, fills it in from the value, and tells it to save. This is
how [calendar events](Calendars.md) cross.

A label is a word for the eight the contract names (`home`, `work`,
`mobile`, `main`, `other`, `homeFax`, `workFax`, `pager`) and the user's
own text for any other.

### Rules every host follows

- **Every answer is on the main thread, once.** The store is read and
  written off it.
- **A contact is the unified person,** as the system's own app shows
  them, with every account's values together.
- **The list is in the system's order,** and `displayName` is the
  system's formatting. The host doesn't sort or format by rules of its
  own where the platform does.
- **A search finds a person by the start of any word of their name,**
  without regard to case, at least. An empty text finds no one.
- **A save writes what the guest set and keeps the rest.** The lists the
  guest set replace the lists there were.
- **A label the platform has a constant for is that constant,** in both
  directions. Any other is kept as text.
- **Values are kept as given.** A phone number isn't reformatted.
- **With limited access the store is the contacts the user chose.**
  Nothing is said of the others.
- **An app that declared reading alone never writes,** whatever the user
  granted.
- **`didChange` is sent after any change to the store,** this app's
  included, and not more than once for a burst of them.

## The shared host

`HostContacts`, in `RuntimeContacts`, over a host's `ContactDirectory`,
which works in the guest's own values:

```swift
public protocol ContactDirectory: AnyObject, Sendable {   // off the main thread, one call at a time
    /// Everyone, in the system's order.
    func contacts() throws(ContactStoreError) -> [Contact]
    func contacts(matching text: String, limit: Int?) throws(ContactStoreError) -> [Contact]
    func contact(withID identifier: String) throws(ContactStoreError) -> Contact?
    func save(_ contact: Contact) throws(ContactStoreError) -> Contact
    func remove(_ contact: Contact) throws(ContactStoreError)
}

HostContacts.directory = MyContactStore()
HostContacts.allowsWriting = true                  // RTCapabilityOptions.contacts.access
HostContacts.access = .notDetermined               // what the platform says now
HostContacts.requester = { completion in … }        // the platform's question
HostContactsModule.register(in: runtime)

HostContacts.storeChanged()                        // from the platform
```

A directory names each contact it gives, with `Contact.named(_:)`: the
display name is the platform's formatting.

- **Access:** checked before every call. A write by an app that declared
  reading alone is refused, whatever the user granted. The user is asked
  once, and a requester that answers twice is heard once.
- **Before a directory sees a save:** that the contact has something in
  it, and that the one it names is there. Before a search: that the text
  isn't empty.
- **Threads:** the directory is called off the main thread in order, and
  every answer is on it.
- **Changes:** a burst of `storeChanged` is one `didChange`, and this
  app's own saves and removals are said too.
- **`MemoryContactDirectory`** is a directory in memory, for tests, and
  the rules in their plainest form. It is not a default. Without a
  directory, every call fails with `unavailable`.

## The manifest

```swift
capabilities: [.contacts(usage: "Shows your contacts and lets you change them.")]
capabilities: [.contacts(.readOnly, usage: "Suggests addresses as you type a name.")]
```

| | `.readWrite` (the default) | `.readOnly` |
|---|---|---|
| iOS / macOS | `NSContactsUsageDescription` | the same; the host refuses writes |
| Android | `READ_CONTACTS` and `WRITE_CONTACTS` | `READ_CONTACTS` |
| Linux | the contacts service on the session bus | the same; the host refuses writes |
| Browser | nothing: there's no store | |

The option reaches a host as `RTCapabilityOptions.contacts.access`.

## Per host

From each platform's documentation. None of it has been tried.

| | Notes |
|---|---|
| iOS / macOS | `CNContactStore`. `unifiedContacts(matching:keysToFetch:)` with `CNContact.predicateForContacts(matchingName:)` for a search, and `enumerateContacts` with `sortOrder = .userDefault` for everyone. `CNContactFormatter` for `displayName`. A `CNSaveRequest` to add, update and delete. `CNLabelHome` and its neighbours for labels. `CNContactStoreDidChange` for `didChange`. iOS 18 adds limited access, which needs nothing of the host. A contact's note needs an entitlement Apple grants on request, so notes aren't read. |
| Android | `ContactsContract`. `Contacts` rows for people, in `SORT_KEY_PRIMARY` order with `DISPLAY_NAME_PRIMARY`; `Data` rows for names, phones, emails, addresses, websites and events. `Contacts.CONTENT_FILTER_URI` for a search. A new person is a `RawContact` in the default account with its `Data` rows, in one batch. A save of one person may touch several raw contacts: values the guest dropped are deleted from whichever has them, and new ones go to the first that can be written. A `ContentObserver` for `didChange`. |
| Linux | The host's contacts service, which holds the accounts and syncs them. What it is isn't decided: the core apps plan had the Contacts app keep its own records. |
| Browser | No contacts store exists. `access` is `.unavailable`. |

## Not in this design

- **Photos.** There's no way to show one yet: the `Image` node takes a
  bundle image or a symbol. They come with [Drawing](Drawing.md)'s
  images. A save keeps the photo a contact has.
- **The system's contact picker,** which needs no permission: the user
  picks one person, and the app gets that one. It would suit an app that
  wants one address once, and it's the one thing a browser host could
  do.
- **Notes,** which iOS keeps from apps.
- **Groups, and choosing the account** a new contact goes to.
- **The user's own card.**
- **Social profiles, instant-message addresses, relations, and dates
  other than a birthday.**
- **Reading or writing vCards.** That's a guest library.
- **Finding a person by a phone number,** as a dialler does for a call.
- **Formatting a phone number or a postal address** for the user's
  country.
- **What changed.** `didChange` says only that something did.

## Example and tests

`examples/ExampleContacts` is an address book: it asks for access, lists
everyone, finds people as a name is typed, shows one person's details,
adds someone, changes them, removes them, and looks again when the store
says it changed. It runs as `App.wasm` under WasmKit
(`Packages/RuntimeWasm`) and as a sealed native slice and wasm2c output
(`Packages/LinkedSlice`), against `HostContacts` over an address book in
memory.

- `DynamicContactsTests`: the contracts' keys and signatures, labels, a
  birthday's text, a contact as a value, and the guest's `ContactStore`
  against a scripted host.
- `RuntimeContactsTests`: `HostContacts` over `MemoryContactDirectory`,
  from the guest: access, an app that only reads, a contact saved, found,
  changed and removed, what a name falls back to, someone who can't be
  changed, the list's order, searching, a burst of changes, and the
  `async` forms.
- `AppManifestTests` and `Scripts/test_manifest.py`: `.contacts` and
  whether it writes.

## Decided in review

The design was approved as drafted, and built as drafted:

- **Names:** `ContactStore`, `Contact`, `LabeledValue`, `PostalAddress`;
  module `DynamicContacts`.
- **The system syncs, and the Contacts app is its client.** Linux needs a
  contacts service in the host, which isn't decided.
- **Reading and writing are declared apart,** with writing the default.
- **No photos,** until an `Image` can show one.
- **No contact picker.**
- **No notes, groups or accounts.**
- **Search is the platform's own,** with one promise: the start of any
  word of a name, without regard to case.
- **Names and lists cross as arrays of strings in a fixed order.**
- **No stand-in store.**
