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
| `DynamicCoreModel` | `RuntimeModelStorage`, a `ModelStorage` over the contracts; `FetchedResults`, a fetch read as it's used; `Query`, results that stay current for SwiftUI | new, guest |
| The contracts | a store, and the objects it's described and queried with | hosts |

| Contract | Stands for | Core Data's counterpart |
|---|---|---|
| `ModelStore` | an open store | `NSPersistentContainer` and a context |
| `ModelSchema`, `ModelEntity`, `ModelProperty` | the model | `NSManagedObjectModel`, `NSEntityDescription`, `NSPropertyDescription` |
| `ModelFetch` | a fetch request | `NSFetchRequest` |
| `ModelPredicate`, `ModelExpression` | a predicate tree | `NSPredicate`, `NSExpression` |
| `ModelRecord` | one object's values | `NSManagedObject`, read-only once fetched |
| `ModelResults` | what a fetch found | the fetched array |
| `ModelBatch` | a set of changes to commit together | a context's pending changes |
| `ModelStoreDelegate`, `ModelStoreCallback` | callbacks: changes, and one operation's result | notifications, completion handlers |

| | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|
| Kept in | Core Data, through CoreModel's `CoreDataModel` | SQLite (`android.database.sqlite`) | SQLite, through CoreModel-SQLite | IndexedDB |

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

**An object model, as the platforms have.** The model, a fetch request, a
predicate and a record are host objects with methods (§4.4), the shape of
Core Data's own classes. There's no byte format to version or to write
three times.

**Results are read as they're used.** A fetch answers with a
`ModelResults` the host holds. The guest asks it for the records it
needs, by index, and each record for its values. A list of 10,000 that
shows twenty rows reads twenty records. Reading everything costs a call per
value, so code that wants it all at once pays for that, and code that
shows a screenful doesn't.

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

let request = FetchRequest(
    entity: Person.entityName,
    sortDescriptors: [.init(property: "name")],
    predicate: Person.CodingKeys.age >= Int32(18)
)
let adults = try await store.results(Person.self, for: request)   // read as it's used
let first = adults.first
```

`RuntimeModelStorage` is a `ModelStorage`, so code written against the
protocol runs unchanged on it, on `InMemoryStorage` in tests, and on
CoreModel's own backends in a full-Swift app.

What it adds to the protocol:

- **`open(_:model:indexes:migration:)`**: opens the app's store of that
  name, creating or migrating it.
- **`results(_:for:)`**: a fetch as a `FetchedResults`, below.
- **`perform(_:)`**: one atomic batch of inserts and deletes. `insert` and
  `delete` are batches of their own.
- **`changes`**: an `EventStream` of the entity names each committed batch
  touched.
- **Completion-handler forms** of every call, for slices built without the
  concurrency runtime.

### Two ways to fetch

| | Returns | Reads |
|---|---|---|
| `results(_:for:)` | `FetchedResults<T>`, a `RandomAccessCollection` | a record when it's first subscripted, then kept |
| `fetch(_:)`, the protocol's | `[ModelData]` | every record, before it returns |

- `FetchedResults` knows its `count` at once, without reading a record.
- It's a **snapshot**: what the fetch found, unchanged by later writes.
  The host keeps it until the guest lets go of it.
- The frontend's lists take any `RandomAccessCollection` and ask for rows
  by index, so `List(results)` reads the rows on screen.
- `fetch(_:)` is right for small results and for code shared with other
  backends. For a large one it makes a call per value, about 10,000 for a
  thousand records of ten attributes; give it a `fetchLimit`, or use
  `results`.

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

`Query` is observable: `results` (a `FetchedResults`), `isLoading` and
`error`. It fetches when made, and again when the store reports a change
to its entity or to one its predicate reaches through a relationship. Each
refetch swaps in a new snapshot. Refetches are coalesced to one per turn of
the guest (`GuestExecutor.whenIdle`), and `predicate`, `sort` and `limit`
can be changed, which refetches. This is the place of
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
- **Later, perhaps, `FetchedResults` itself:** a lazily read result is
  useful to the Core Data and SQLite backends too.

## The contracts

### The store

```swift
@DynamicRuntime("org.pureswift.data.ModelStore")
protocol ModelStore {
    /// Opens the store `name` for `schema`. `migration`: 0 fail when the
    /// stored model can't be migrated, 1 empty the store. Operations may
    /// be issued at once; they wait for the open, whose outcome is
    /// `callback`'s `didComplete` or `didFail`.
    static func open(_ name: String, schema: ModelSchema, migration: Int32,
                     delegate: ModelStoreDelegate, callback: ModelStoreCallback) -> Self

    func fetch(_ fetch: ModelFetch, callback: ModelStoreCallback)      // didFetch
    func fetchIDs(_ fetch: ModelFetch, callback: ModelStoreCallback)   // didFetchIDs
    func count(_ fetch: ModelFetch, callback: ModelStoreCallback)      // didCount
    func perform(_ batch: ModelBatch, callback: ModelStoreCallback)    // didComplete

    /// Deletes the store `name` and everything in it.
    static func destroy(_ name: String, callback: ModelStoreCallback)
}

@DynamicCallback("org.pureswift.data.ModelStoreCallback")
protocol ModelStoreCallback {
    func didComplete()
    func didFetch(_ results: ModelResults)
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

### The model

```swift
@DynamicRuntime("org.pureswift.data.ModelSchema")
protocol ModelSchema {
    static func make() -> Self
    func addEntity(_ name: String) -> ModelEntity
}

@DynamicRuntime("org.pureswift.data.ModelEntity")
protocol ModelEntity {
    /// `type`: an `AttributeType` code (the table under Types).
    func addAttribute(_ key: String, type: Int32) -> ModelProperty
    /// A composite attribute: add its elements to the entity returned.
    func addComposite(_ key: String) -> ModelEntity
    func addRelationship(_ key: String, toMany: Bool, destination: String, inverse: String) -> ModelProperty
    func addIndex(_ properties: [ModelProperty])
}

@DynamicRuntime("org.pureswift.data.ModelProperty")
protocol ModelProperty {
    func key() -> String
}
```

A `ModelProperty` is how a record's values are named afterwards. The guest
gets each once, while it builds the schema, and passes the handle from then
on, so reading a value doesn't send its name as a string every time.

### A fetch

```swift
@DynamicRuntime("org.pureswift.data.ModelFetch")
protocol ModelFetch {
    static func make(_ entity: String) -> Self
    func setPredicate(_ predicate: ModelPredicate?)
    func addSort(_ keyPath: String, ascending: Bool)
    func setLimit(_ limit: Int32)       // 0: none
    func setOffset(_ offset: Int32)
    /// Only the objects with these IDs: a fetch by ID.
    func setIDs(_ ids: [String])
}

@DynamicRuntime("org.pureswift.data.ModelPredicate")
protocol ModelPredicate {
    /// `operation`, `modifier` and `options` are CoreModel's `Operator`,
    /// `Modifier` and `Option` set, as codes.
    static func comparison(_ left: ModelExpression, operation: Int32, right: ModelExpression,
                           modifier: Int32, options: Int32) -> Self
    static func and(_ predicates: [ModelPredicate]) -> Self
    static func or(_ predicates: [ModelPredicate]) -> Self
    static func not(_ predicate: ModelPredicate) -> Self
    static func constant(_ value: Bool) -> Self
}

@DynamicRuntime("org.pureswift.data.ModelExpression")
protocol ModelExpression {
    static func keyPath(_ path: String) -> Self
    static func null() -> Self
    static func bool(_ value: Bool) -> Self
    static func integer(_ value: Int64) -> Self
    static func double(_ value: Double) -> Self
    static func string(_ value: String) -> Self
    static func data(_ value: [UInt8]) -> Self
    /// Several values: the right side of `IN` and `BETWEEN`, or a to-many's IDs.
    static func list(_ values: [ModelExpression]) -> Self
    static func arithmetic(_ left: ModelExpression, operation: Int32, right: ModelExpression) -> Self
}
```

It's `NSComparisonPredicate` and `NSCompoundPredicate` over `NSExpression`,
which is also CoreModel's `FetchRequest.Predicate`: a host on Core Data
builds those objects one for one, and a host on SQLite walks the tree into
a `WHERE` clause.

### Records, results and batches

```swift
@DynamicRuntime("org.pureswift.data.ModelRecord")
protocol ModelRecord {
    /// A record to insert.
    static func make(_ entity: ModelEntity, id: String) -> Self
    func id() -> String

    func isNull(_ property: ModelProperty) -> Bool
    func bool(_ property: ModelProperty) -> Bool
    func integer(_ property: ModelProperty) -> Int64
    func double(_ property: ModelProperty) -> Double
    func string(_ property: ModelProperty) -> String?
    func data(_ property: ModelProperty) -> [UInt8]?
    func composite(_ property: ModelProperty) -> ModelRecord?
    func toOne(_ property: ModelProperty) -> String?
    func toMany(_ property: ModelProperty) -> [String]

    func setNull(_ property: ModelProperty)
    func setBool(_ value: Bool, for property: ModelProperty)
    func setInteger(_ value: Int64, for property: ModelProperty)
    func setDouble(_ value: Double, for property: ModelProperty)
    func setString(_ value: String, for property: ModelProperty)
    func setData(_ value: [UInt8], for property: ModelProperty)
    func setComposite(_ value: ModelRecord, for property: ModelProperty)
    func setToOne(_ id: String?, for property: ModelProperty)
    func setToMany(_ ids: [String], for property: ModelProperty)
}

@DynamicRuntime("org.pureswift.data.ModelResults")
protocol ModelResults {
    func count() -> Int32
    func record(at index: Int32) -> ModelRecord
}

@DynamicRuntime("org.pureswift.data.ModelBatch")
protocol ModelBatch {
    static func make() -> Self
    func insert(_ record: ModelRecord)
    func delete(_ entity: String, id: String)
}
```

- **A fetched record is read-only:** its setters do nothing. A record to
  insert is made with `make`, filled in, and added to a batch.
- **Writes aren't lazy.** Inserting a thousand records of ten attributes
  is about eleven thousand calls. Batches that size are rare, and are what
  a first import is; they don't hold up the store, which starts work only
  at `perform`.

### Rules every host follows

- **One callback object per operation**, which the host holds until it has
  called exactly one of its methods, as `Clock.after` holds its delegate.
  Nothing matches request numbers.
- **Order.** A store's operations take effect in the order they were
  issued, and their callbacks arrive in that order, on the main thread. A
  fetch sees every batch issued before it.
- **`didChange` comes after the batch's own callback**, and once per batch.
- **A fetch, a predicate and a batch are read when they're handed over.**
  Changing one afterwards doesn't change an operation already issued.
- **`ModelResults` is a snapshot in the host's memory.** `count` and
  `record(at:)` answer at once, without touching storage: a browser
  couldn't read IndexedDB inside a synchronous call, and no host should
  read a disk on the main thread. Reading lazily saves the calls across
  the boundary, not the host's memory, so a fetch that could match a
  million objects wants a limit.
- **Releasing a store** closes it once its pending operations finish.

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

Each attribute type crosses as one of five kinds of value, which is the
getter, the setter and the `ModelExpression` constant used for it:

| `AttributeType` | Code | Crosses as | Core Data | SQLite | IndexedDB |
|---|---|---|---|---|---|
| `bool` | 0 | `bool` | Boolean | `INTEGER` | boolean |
| `int16`, `int32` | 1, 2 | `integer` | Integer 16 / 32 | `INTEGER` | number |
| `int64` | 3 | `integer` | Integer 64 | `INTEGER` | `BigInt`; in an index, 8 big-endian bytes with the sign bit flipped, since a `BigInt` can't be a key |
| `float`, `double` | 4, 5 | `double` | Float / Double | `REAL` | number |
| `string` | 6 | `string` | String | `TEXT` | string |
| `data` | 7 | `data` | Binary | `BLOB` | `ArrayBuffer` |
| `date` | 8 | `double`: seconds since 1970 UTC | Date | `REAL` | number |
| `uuid` | 9 | `string`: lowercase, hyphenated | UUID | `TEXT` | string |
| `url` | 10 | `string` | URI | `TEXT` | string |
| `decimal` | 11 | `string`: its canonical form | Decimal | `TEXT`, compared in host code | string, compared in script |
| composite | — | a nested `ModelRecord` | flattened attributes | flattened columns (`address.city`) | a nested object |

Every attribute may be `null`: `isNull` says so, and the typed getters
then answer `false`, 0 or `nil`. A getter of the wrong kind for the
attribute answers the same way.

### Indexes

CoreModel's `Model` says what exists, not what's fast, so
`RuntimeModelStorage.open` takes **indexes** beside it and passes them to
`ModelEntity.addIndex`: one property, or several for a compound index. A
host indexes IDs and relationship keys by itself. Indexes change speed,
never results; a host may ignore one it can't build.

### Migration

`open` compares the schema with the one the store was last opened with:

| Change | What happens |
|---|---|
| None | opens |
| A new entity, attribute or relationship; a new or dropped index | migrates by itself: existing objects get `null` or an empty relationship |
| A removed entity, attribute or relationship | migrates by itself; that data is dropped |
| An attribute's type, or a relationship's destination or kind | `open` fails with `migrationRequired` |

`migration` says what to do then: fail (the default), or empty the store.
A custom migration is app code: open the old store under a new name with
its old model, copy across, and `destroy` it. That needs the stored model
back from the host, which is an open question (§15).

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

**The browser's engine is IndexedDB.** It needs no worker, no extra
download and no special headers. SQLite compiled to wasm in a worker was
the alternative: the same engine as Android and Linux, for a worker, about
a megabyte, and in some browsers cross-origin isolation.

### Errors

`ModelStoreError`, from `didFail`:

| Value | Case |
|---|---|
| 0 | `unknown` |
| 1 | `cancelled`: guest-side only, a cancelled task |
| 2 | `invalidModel`: the schema contradicts itself (a relationship to an entity it doesn't have) |
| 3 | `migrationRequired` |
| 4 | `invalidRequest`: an entity or key the schema doesn't have, a property of another schema, or a value of the wrong kind |
| 5 | `unsupported`: a request feature this host lacks |
| 6 | `outOfSpace` |
| 7 | `unavailable`: no storage (a private window, a full disk at open) |
| 8 | `corrupted`: the store can't be read |

A failed batch changes nothing.

## For a host in Swift

The Darwin and Linux hosts are Swift, and CoreModel has backends for both.
A shared host module implements these contracts over **any**
`ModelStorage`: its schema, fetch and record objects are thin wrappers
that build CoreModel's `Model`, `FetchRequest` and `ModelData`; it calls
the backend on a background executor, keeps what a fetch returned as the
`ModelResults`, and answers on the main thread.

| Host | Backend it plugs in |
|---|---|
| iOS / macOS | `CoreDataModel`: an `NSPersistentContainer` whose model is built from the schema |
| Linux | CoreModel-SQLite |
| Android | Kotlin over `android.database.sqlite`, or CoreModel-SQLite if the host carries Swift |
| Browser | JavaScript over IndexedDB |

What the shared module adds around a backend: the stored model and the
migration rules above, serial ordering, batches as one transaction, and
`didChange`.

## Threading

Every callback and delegate method runs on the main thread (§6.4). Hosts
do the I/O elsewhere and hop back. Nothing blocks the main thread: there
is no synchronous fetch, on any host, and reading a `ModelResults` reads
memory.

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
