# Persistence

> **Draft.** Nothing here is implemented: no module, no host. It specifies
> §7.9 of `DynamicRuntime.md`.

A model store for apps: entities, attributes and relationships, fetched with
predicates and kept across launches, on iOS, macOS, Android, Linux and the
web. App code is written against [CoreModel](https://github.com/PureSwift/CoreModel);
each host keeps the data in what its platform has.

| Piece | What | Where |
|---|---|---|
| CoreModel | `@Entity`, `Model`, `ModelData`, `FetchRequest`, `ModelStorage` | the guest, unchanged |
| `DynamicCoreModel` | `RuntimeModelStorage`, a `ModelStorage` over the contract; `Query`, observable results for SwiftUI; the wire codec | new, guest and Swift hosts |
| `ModelStore` | the contract | hosts |

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `ModelStore` | contract (no capability) | Core Data, through CoreModel's `CoreDataModel` | SQLite (`android.database.sqlite`) | SQLite, through CoreModel-SQLite | IndexedDB |
| `ModelStoreDelegate` | callback: changes | `NSManagedObjectContextDidSave` | the host's own writes | the host's own writes | its writes, and `BroadcastChannel` for other tabs |
| `ModelStoreCallback` | callback: one operation's result | | | | |

For small settings, see [Defaults](#small-values-defaults) at the end. For
files, see [Files](Files.md).

## What shapes it

**The web makes it asynchronous.** A browser's storage that holds more
than a few megabytes (IndexedDB, the origin's private file system) can't be
used synchronously on the main thread, and the guest runs there. So every
operation that touches the store completes later, through a callback. That
suits the other hosts too: they do the I/O off the main thread. CoreModel's
`ModelStorage` is already `async throws`.

**No transactions that stay open.** IndexedDB commits a transaction as soon
as control returns to the event loop, so "begin, work, commit" across guest
turns can't exist. A write is one **batch**, a list of inserts and deletes
applied together or not at all.

**Records cross as bytes.** A fetch of 1,000 records with ten attributes
would be 10,000 calls if each value were a getter on a host object. Like the
render tree, a batch of records is one byte buffer in a documented format
([wire format](#wire-format)), and a fetch is one call and one callback.
This departs from "structured data is objects with getters" (§4.4), for
the reason the render IR does.

**Values, not managed objects.** As in CoreModel, the store returns values.
There's no context, no faulting, no change tracking and no undo; an entity
is a struct the app decodes from `ModelData` and encodes back.

**The guest has no Foundation.** CoreModel compiles under Embedded Swift,
with `Date`, `UUID`, `Data`, `URL` and `Decimal` from
swift-embedded-foundation. Nothing here needs `Codable`, `Mirror` or key
paths.

## For a guest

```swift
import CoreModel
import DynamicCoreModel

@Entity
struct Person: Identifiable {
    let id: UUID
    @Attribute var name: String
    @Attribute var age: Int32
    @Relationship(destination: Team.self, inverse: .members)
    var team: Team.ID?
}

let model = Model(entities: [EntityDescription(entity: Person.self),
                             EntityDescription(entity: Team.self)])
let store = try await RuntimeModelStorage.open(
    "library",
    model: model,
    indexes: [Person.entityName: [["name"], ["age"]]]
)

try await store.insert(person.encode())
let adults = try await store.fetch(FetchRequest(
    entity: Person.entityName,
    sortDescriptors: [.init(property: "name")],
    predicate: Person.CodingKeys.age >= Int32(18),
    fetchLimit: 50
))
```

`RuntimeModelStorage` is a `ModelStorage`, so code written against the
protocol runs unchanged on it, on `InMemoryStorage` in tests, and on
CoreModel's own backends in a full-Swift app.

What it adds to the protocol:

- **`open(_:model:indexes:migration:)`**: opens the app's store of that
  name, creating or migrating it.
- **`perform(_:)`**: one atomic batch of inserts and deletes. `insert` and
  `delete` are batches of their own.
- **`changes`**: an `EventStream` of the entity names each committed batch
  touched.
- **Completion-handler forms** of every call, for slices built without the
  concurrency runtime.

### Query: results that stay current

```swift
struct PeopleList: View {

    let people: Query<Person>

    var body: some View {
        List(people.results) { person in
            Text(person.name)
        }
    }
}

let people = Query<Person>(store, sort: [.init(property: "name")])
```

`Query` is observable: `results`, `isLoading` and `error`. It fetches when
made, and again when the store reports a change to its entity or to one its
predicate reaches through a relationship. Refetches are coalesced to one per
turn of the guest (`GuestExecutor.whenIdle`), and `predicate`, `sort` and
`limit` can be changed, which refetches. This is the place of
`NSFetchedResultsController` and SwiftData's `@Query`.

### What CoreModel needs first

- **`@Entity` under Embedded Swift.** CoreModel turns its macros off there,
  because swift-syntax can't be built for the target. AppRuntime builds
  macro plugins for the build machine, so they can run; their expansion
  must then write `init(from:)` and `encode()` out with
  `ModelData.decode` / `encode` instead of leaning on `Codable`. Until
  then, entities are written by hand, as CoreModel's README shows.
- **A batch requirement on `ModelStorage`** (inserts and deletes together),
  so atomic writes aren't particular to this backend.

## The contract

```swift
@DynamicRuntime("org.pureswift.data.ModelStore")
protocol ModelStore {
    /// Opens the store `name`, for `model` (wire format). Operations may
    /// be issued at once; they wait for the open, whose outcome is
    /// `callback`'s `didComplete` or `didFail`.
    static func open(_ name: String, model: [UInt8], options: [UInt8],
                     delegate: ModelStoreDelegate, callback: ModelStoreCallback) -> Self

    func fetch(_ request: [UInt8], callback: ModelStoreCallback)      // didFetch
    func fetchIDs(_ request: [UInt8], callback: ModelStoreCallback)   // didFetchIDs
    func count(_ request: [UInt8], callback: ModelStoreCallback)      // didCount
    func perform(_ batch: [UInt8], callback: ModelStoreCallback)      // didComplete

    /// Deletes the store `name` and everything in it.
    static func destroy(_ name: String, callback: ModelStoreCallback)
}

@DynamicCallback("org.pureswift.data.ModelStoreCallback")
protocol ModelStoreCallback {
    func didComplete()
    func didFetch(_ records: [UInt8])
    func didFetchIDs(_ ids: [String])
    func didCount(_ count: Int64)
    func didFail(_ error: Int32, message: String)
}

@DynamicCallback("org.pureswift.data.ModelStoreDelegate")
protocol ModelStoreDelegate {
    /// A batch was committed that touched these entities: by this store
    /// object, or by another on the same store (another tab, an extension).
    func didChange(_ store: ModelStore, entities: [String])
}
```

- **One callback object per operation**, which the host holds until it has
  called exactly one of its methods, as `Clock.after` holds its delegate.
  Nothing matches request numbers.
- **Order.** A store's operations take effect in the order they were
  issued, and their callbacks arrive in that order, on the main thread. A
  fetch sees every batch issued before it.
- **`didChange` comes after the batch's own callback**, and once per batch.
- **Releasing the store** closes it once its pending operations finish.

### Rules every host follows

**The reference is CoreModel's own evaluator.** `FetchRequest.evaluate`
and the in-memory `filtered` / `sorted` define what a request returns:
comparison of every attribute type, the string options (`[c]`, `[d]`),
`ANY` / `ALL` over to-many relationships, where `null` sorts. A host pushes
down to its engine what the engine does exactly that way, and filters and
sorts the rest itself. Results must match the reference; a set of
**conformance vectors** (a model, records, requests, the expected IDs),
generated from `InMemoryStorage`, is how a host checks.

| Request feature | Core Data | SQLite | IndexedDB |
|---|---|---|---|
| `==`, `<`, `>`, `BETWEEN`, `IN` on an indexed attribute | predicate | `WHERE`, uses the index | a key range on the index |
| The same, not indexed | predicate | `WHERE` | cursor scan, filtered in script |
| `BEGINSWITH` | predicate | `WHERE … >= ? AND … < ?` on the index | a key range |
| `CONTAINS`, `ENDSWITH`, `LIKE` | predicate | `LIKE` / `GLOB` when case-sensitive | in script |
| Case- and diacritic-insensitive | `[cd]` | in host code: Android's SQLite takes no custom functions | in script (`Intl.Collator`) |
| `MATCHES` | ICU regular expressions | in host code | `RegExp` with the `u` flag |
| Key paths through relationships | predicate | joins | lookups by ID |
| Sort, limit, offset | fetch request | `ORDER BY … LIMIT … OFFSET` | an index's order when it matches, else in script |

**Relationships.** A to-one holds the destination's ID, a to-many a list of
IDs. The host keeps a relationship and its declared inverse in step:
setting one side sets the other in the same batch. Deleting an object
removes it from the relationships that point at it (nullify).

**Custom functions** (`ModelStorage.register(function:)`) are closures in
the guest, which a host can't call per row. A request that uses one is
fetched without its predicate and sort, and evaluated in the guest with the
reference evaluator. It's correct and reads the whole entity; apps keep
such requests to small entities.

**IDs** are the app's strings (`ObjectID`), unique within an entity. An
insert with an existing ID replaces that object's attributes and
relationships, as CoreModel's `insert` does.

### Types

| `AttributeType` | Wire | Core Data | SQLite | IndexedDB |
|---|---|---|---|---|
| `bool` | 1 byte | Boolean | `INTEGER` | boolean |
| `int16`, `int32` | varint | Integer 16 / 32 | `INTEGER` | number |
| `int64` | varint | Integer 64 | `INTEGER` | `BigInt`; in an index, 8 big-endian bytes with the sign bit flipped, since a `BigInt` can't be a key |
| `float`, `double` | 4 / 8 bytes | Float / Double | `REAL` | number |
| `string` | UTF-8 | String | `TEXT` | string |
| `data` | bytes | Binary | `BLOB` | `ArrayBuffer` |
| `date` | double, seconds since 1970 UTC | Date | `REAL` | number |
| `uuid` | 16 bytes | UUID | `BLOB` | lowercase hyphenated string, which sorts as the bytes do |
| `url` | UTF-8 | URI | `TEXT` | string |
| `decimal` | its canonical string | Decimal | `TEXT`, compared in host code | string, compared in script |
| `composite` | nested values | flattened attributes | flattened columns (`address.city`) | a nested object |

Every attribute may be `null`.

### Indexes

CoreModel's `Model` says what exists, not what's fast. `open` takes
**indexes** beside it: per entity, lists of attribute keys (one key, or
several for a compound index). A host indexes IDs and relationship keys by
itself. Indexes change speed, never results; a host may ignore one it
can't build.

### Migration

`open` compares the model with the one the store was last opened with:

| Change | What happens |
|---|---|
| None | opens |
| A new entity, attribute or relationship; a new or dropped index | migrates by itself: existing objects get `null` or an empty relationship |
| A removed entity, attribute or relationship | migrates by itself; that data is dropped |
| An attribute's type, or a relationship's destination or kind | `open` fails with `migrationRequired` |

The `migration` option says what to do then: fail (the default), or
`destructive`, which empties the store. A custom migration is app code:
open the old store under a new name with its old model, copy across, and
`destroy` it. That needs the stored model back from the host, which is an
open question (§15).

### Where it's kept

In the app's container, never visible to other apps, with no capability:

| Host | Place | Backed up | Notes |
|---|---|---|---|
| iOS / macOS | `Application Support/Stores/<name>` | yes | Data Protection: complete until first unlock |
| Android | `getDatabasePath(name)` | Auto Backup, if the app allows it | |
| Linux distro | `/data/stores/<name>.sqlite` | the distro's business | |
| Browser | IndexedDB database `<app id>.<name>` | no | see below |

`name` is one safe path component (§7.5's rule).

**The browser can throw the data away.** Storage is "best effort" until
the host asks for it to persist (`navigator.storage.persist()`), which the
browser may refuse; Safari deletes script-written storage of sites unused
for seven days unless they're installed to the home screen; private windows
keep nothing. Quotas are per origin. `open` reports `unavailable` when
there's no storage at all, and writes report `outOfSpace` at the quota. An
app that can't lose its data needs a server.

**A browser host may use SQLite instead:** compiled to wasm, in a worker,
on the origin's private file system. The contract is asynchronous, so it
fits, and it gives the same engine as Android and Linux. It costs a worker,
about a megabyte of download, and in some browsers cross-origin isolation
headers. IndexedDB needs none of that, so it's the default.

### Errors

`ModelStoreError`, from `didFail`:

| Value | Case |
|---|---|
| 0 | `unknown` |
| 1 | `cancelled`: guest-side only, a cancelled task |
| 2 | `invalidModel`: the model or options don't decode, or contradict themselves |
| 3 | `migrationRequired` |
| 4 | `invalidRequest`: an entity or key the model doesn't have, or a value of the wrong type |
| 5 | `unsupported`: a request feature this host lacks |
| 6 | `outOfSpace` |
| 7 | `unavailable`: no storage (a private window, a full disk at open) |
| 8 | `corrupted`: the store can't be read |

A failed batch changes nothing.

## Wire format

Four messages, each a byte buffer: little-endian, LEB128 varints, strings
as a varint length and UTF-8, and a string table first so entity and
property names appear once. Each starts with two magic bytes and a version
byte; a host refuses a version it doesn't know with `invalidModel`.

```
model    := "RM" version strings entity*
entity   := name attribute* relationship*
attribute    := key type            type: one byte per AttributeType; composite nests
relationship := key kind destination inverse

options  := "RO" version strings index* migration
index    := entity key+

request  := "RQ" version strings entity ids? predicate? sort* limit offset
predicate := comparison | and | or | not | bool      as CoreModel's enum, by tag
expression := value | relationship | keyPath | arithmetic

records  := "RR" version strings record*
record   := entity id (key value)* (key relation)*
value    := tag payload             tag: null, then one per AttributeType
relation := null | toOne id | toMany id*

batch    := "RB" version strings insert:record* delete:(entity id)*
```

The codec is one Swift source in `DynamicCoreModel`, for the guest and for
hosts written in Swift. Kotlin and JavaScript hosts write theirs from this
grammar, as the players do for the render IR. Its exact bytes are fixed
when it's implemented, and tested by round trips and by the conformance
vectors.

## For a host in Swift

The Darwin and Linux hosts are Swift, and CoreModel has backends for both.
`DynamicCoreModel` carries a host half too: an implementation of
`ModelStore` over **any** `ModelStorage`. It decodes the wire into
CoreModel's own types, calls the backend on a background executor, and
answers on the main thread.

| Host | Backend it plugs in |
|---|---|
| iOS / macOS | `CoreDataModel`: an `NSPersistentContainer` whose model is built from the schema |
| Linux | CoreModel-SQLite |
| Android | Kotlin over `android.database.sqlite`, or CoreModel-SQLite if the host carries Swift |
| Browser | JavaScript over IndexedDB |

What the shared half adds around a backend: the stored model and the
migration rules above, serial ordering, batches as one transaction, and
`didChange`.

## Threading

Every callback and delegate method runs on the main thread (§6.4). Hosts
do the I/O elsewhere and hop back. Nothing blocks the main thread: there
is no synchronous fetch, on any host.

## Not in this design

- Syncing between devices (iCloud, a server): an app's own code, over the
  HTTP contracts.
- Aggregates (`sum`, `average`, grouping) beyond `count`.
- Full-text search.
- Entity inheritance, derived attributes, undo.
- Sharing a store between apps.

## Small values: Defaults

A model store is the wrong tool for "has the user seen the welcome
screen". Every platform has a small synchronous key-value store, and so
does the web, so this one contract is synchronous:

```swift
@DynamicRuntime("org.pureswift.data.Defaults")
protocol Defaults {
    static func standard() -> Self
    func string(_ key: String) -> String?
    func setString(_ value: String?, key: String)     // nil removes
    func data(_ key: String) -> [UInt8]?
    func setData(_ value: [UInt8]?, key: String)
    func keys() -> [String]
}
```

| Host | Backed by |
|---|---|
| iOS / macOS | `UserDefaults` |
| Android | `SharedPreferences` |
| Linux distro | a file in `/data`, written atomically |
| Browser | `localStorage`, under the app's prefix |

Guest-side Swift layers typed accessors (`bool`, `int`, `double`) over
strings, and SwiftUI's `@AppStorage`. It's for small values: a host may
refuse a value over 64 KB, and the browser's limit for all of them
together is about 5 MB.
