# Persistence

Module `DynamicCoreModel`: a model store for apps. Entities, attributes and
relationships, fetched with predicates and kept across launches. App code
is written against [CoreModel](https://github.com/PureSwift/CoreModel);
each host keeps the data in what its platform has. It specifies §7.9 of
`DynamicRuntime.md`.

| Piece | What | Where |
|---|---|---|
| CoreModel | `Entity`, `Model`, `ModelData`, `FetchRequest`, `ModelStorage` | the guest, unchanged; re-exported by `DynamicCoreModel` |
| `DynamicCoreModel` | the contracts; `RuntimeModelStorage`, a `ModelStorage` over them; `FetchedResults`, a fetch read as it's used; `Query`, results that stay current for SwiftUI | guest and host |
| `RuntimeCoreModel` | `HostModelStore`: the contracts over any CoreModel backend, for hosts written in Swift | host |

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

The guest side is implemented, and so is the host side for any host
written in Swift: `HostModelStore` in `RuntimeCoreModel`, which takes a
CoreModel backend from the host. The Darwin host gives it CoreModel's Core
Data store on iOS and macOS (DarwinAppRuntime's `DarwinModelStore`). The
Linux host has that to do, and Android and the browser need hosts of their
own. The backend the tests use is CoreModel's in-memory one.

For small settings, see [Defaults](Defaults.md). For files, see
[Files](Files.md).

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
swift-embedded-foundation, which the guest build brings in with it.
Nothing here needs `Codable`, `Mirror` or key paths.

## For a guest

```swift
import DynamicCoreModel   // CoreModel comes with it

struct Person: Entity {

    static var entityName: EntityName { "Person" }
    static var attributes: [CodingKeys: AttributeType] { [.name: .string, .age: .int32] }
    static var relationships: [CodingKeys: Relationship] {
        [.team: Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members")]
    }
    enum CodingKeys: String, CodingKey { case id, name, age, team }

    let id: String
    var name: String
    var age: Int32
    var team: String?

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        name = try model.decode(String.self, forKey: CodingKeys.name)
        age = try model.decode(Int32.self, forKey: CodingKeys.age)
        team = try model.decodeRelationship(String?.self, forKey: CodingKeys.team)
    }

    func encode() -> ModelData { … }
}

let model = Model(entities: [EntityDescription(entity: Person.self),
                             EntityDescription(entity: Team.self)])
let store = RuntimeModelStorage(
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

Entities are written by hand, as CoreModel's README shows: its macros are
off under Embedded Swift (below).

`RuntimeModelStorage` is a `ModelStorage`, so code written against the
protocol runs unchanged on it, on `InMemoryModelStorage` in tests, and on
CoreModel's own backends in a full-Swift app. (Under Embedded Swift the
conformance itself is missing, because a typed `throws` can't witness the
protocol's untyped one there; the methods are the same.)

- **A storage can be used as soon as it's made.** Operations wait for the
  store to open, and fail with what it failed with if it doesn't.
  `RuntimeModelStorage.open(…)` is the same, awaited: it returns once the
  store is open, or throws.
- **Errors are `ModelStoreError`:** a `code` (the table below) and the
  backend's own `message`, for logs.
- **Releasing the storage** closes the store, once its pending operations
  finish. `RuntimeModelStorage.destroy(_:)` deletes a store by name.

What it adds to the protocol:

| | |
|---|---|
| `results(_:for:)`, `records(for:)` | a fetch as a `FetchedResults` or `FetchedRecords`, below |
| `fetch(_:for:)` with an entity type | one entity by ID, decoded |
| `perform(_:)` | a `ModelChanges`: inserts and deletes applied together, in order. `insert` and `delete` are batches of their own |
| `addChangeObserver(_:)`, `changes` | the entity names each committed batch touched: a closure, or an `EventStream` |
| a `completion:` form of every call | for code that isn't `async`, and for slices built without the concurrency runtime |

**An insert over an object merges.** Where there's an object with the
record's ID, the properties the record has are set and the others are left
as they are, which is CoreModel's `insert`. So one property can be changed
without reading the object first:

```swift
var change = ModelData(entity: Person.entityName, id: "ada")
change.encode(Int32(37), forKey: Person.CodingKeys.age)
try await store.insert(change)
```

### Two ways to fetch

| | Returns | Reads |
|---|---|---|
| `results(_:for:)` | `FetchedResults<T>`, a `RandomAccessCollection` of entities | a record when it's first subscripted, then kept |
| `records(for:)` | `FetchedRecords`, the same of `ModelData` | the same |
| `fetch(_:)`, the protocol's | `[ModelData]` | every record, before it returns |

- `FetchedResults` knows its `count` at once, without reading a record.
- It's a **snapshot**: what the fetch found, unchanged by later writes.
  The host keeps it until the guest lets go of it.
- The frontend's lists take any `RandomAccessCollection` and ask for rows
  by index, so `List(results)` reads the rows on screen.
- `fetch(_:)` is right for small results and for code shared with other
  backends. For a large one it makes a call or two per value; give it a
  `fetchLimit`, or use `results`.
- **A record that doesn't decode stops the app** when `FetchedResults` is
  subscripted, as a force-unwrap would. The usual cause is an attribute
  added to the model since the object was stored: it reads as null, so the
  property wants to be optional. `element(at:)` throws instead, and
  `records` has the `ModelData`.

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
refetch swaps in a new snapshot; a failed one leaves the last, and sets
`error`. Refetches are coalesced to one per turn of the guest
(`GuestExecutor.whenIdle`), and `predicate`, `sort` and `limit` can be
changed, which refetches. This is the place of
`NSFetchedResultsController` and SwiftData's `@Query`.

### Custom functions

`register(function:)` takes a CoreModel `DatabaseFunction`, a closure in
the guest, which a host can't call per row. A request that uses one in its
predicate or its sort is fetched whole, without them, and evaluated in the
guest with CoreModel's evaluator. It's correct and reads the entire
entity, so apps keep such requests to small entities. Key paths through
relationships aren't followed in them.

### What CoreModel needs first

- **`@Entity` under Embedded Swift.** CoreModel turns its macros off there,
  because swift-syntax can't be built for the target. AppRuntime builds
  macro plugins for the build machine, so they can run; their expansion
  must then write `init(from:)` and `encode()` out with
  `ModelData.decode` / `encode` instead of leaning on `Codable`. Until
  then, entities are written by hand.
- **A batch requirement on `ModelStorage`** (inserts and deletes together),
  so atomic writes aren't particular to this module. Until then,
  `RuntimeCoreModel` has `AtomicModelStorage` for backends that can.
- **Composite attributes** aren't kept: a model with one fails to open
  with `invalidModel`.
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
    /// `callback`'s `didComplete` or `didFail`, and fail as it did.
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
    /// `type`: a `ModelAttributeType` code (the table under Types).
    func addAttribute(_ key: String, type: Int32) -> ModelProperty
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

A key is unique within its entity and has no `.` in it. Every relationship
names its inverse, which the destination entity must have.

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
    /// `Modifier` and `Option` set, as codes (below).
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
    /// `type`: which attribute type the constant is (the table under Types).
    static func integer(_ value: Int64, type: Int32) -> Self
    static func double(_ value: Double, type: Int32) -> Self
    static func string(_ value: String, type: Int32) -> Self
    static func data(_ value: [UInt8]) -> Self
    /// The ID of a to-one relationship's object, and the IDs of a to-many's.
    static func toOne(_ id: String) -> Self
    static func toMany(_ ids: [String]) -> Self
    static func arithmetic(_ left: ModelExpression, operation: Int32, right: ModelExpression) -> Self
}
```

It's `NSComparisonPredicate` and `NSCompoundPredicate` over `NSExpression`,
which is also CoreModel's `FetchRequest.Predicate`: a host on Core Data
builds those objects one for one, and a host on SQLite walks the tree into
a `WHERE` clause.

- **A constant carries its type**, so a date isn't taken for a number, or
  a UUID for a string. One that isn't of its type (an integer called a
  string, text that isn't a UUID, a number too big for `int16`) makes the
  fetch fail with `invalidRequest`.
- **There's no list of values**, because CoreModel's expressions have
  none. `IN` is membership in a to-many relationship, or, for strings, "is
  a substring of"; `BETWEEN` matches nothing.
- **A sort is by an attribute's key.** After the sorts, and with none,
  objects are in order of their IDs.

| Code | `operation` | | Code | `operation` |
|---|---|---|---|---|
| 0 | `<` | | 7 | `LIKE` |
| 1 | `<=` | | 8 | `BEGINSWITH` |
| 2 | `>` | | 9 | `ENDSWITH` |
| 3 | `>=` | | 10 | `IN` |
| 4 | `==` | | 11 | `CONTAINS` |
| 5 | `!=` | | 12 | `BETWEEN` |
| 6 | `MATCHES` | | | |

`modifier`: 0 none, 1 `ALL`, 2 `ANY`. `options` is a set of bits: 1 case
insensitive, 2 diacritic insensitive, 4 normalized, 8 locale sensitive.
An arithmetic `operation`: 0 add, 1 subtract, 2 multiply, 3 divide,
4 modulus.

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
    func toOne(_ property: ModelProperty) -> String?
    func toMany(_ property: ModelProperty) -> [String]

    func setNull(_ property: ModelProperty)
    func setBool(_ value: Bool, for property: ModelProperty)
    func setInteger(_ value: Int64, for property: ModelProperty)
    func setDouble(_ value: Double, for property: ModelProperty)
    func setString(_ value: String, for property: ModelProperty)
    func setData(_ value: [UInt8], for property: ModelProperty)
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
- **An insert merges.** Where there's an object with the record's ID, the
  properties the record has values for are set, and the object's others
  are left as they are. A property set to null is set; one never
  mentioned isn't touched.
- **A batch's changes are applied in the order they were added.** Deleting
  an object that isn't there is fine.
- **A record that was given something it can't hold** fails its batch with
  `invalidRequest`: a property of another entity, a value of the wrong
  kind for its attribute, a number that doesn't fit, text that isn't a
  UUID. A number that fits a narrower integer type is that type's.
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
generated from `InMemoryModelStorage`, is to be how a host checks.

| Request feature | Core Data | SQLite | IndexedDB |
|---|---|---|---|
| `==`, `<`, `>` on an indexed attribute | predicate | `WHERE`, uses the index | a key range on the index |
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

CoreModel's in-memory backend does the first half only: the to-many side
of a one-to-many is whichever objects point back, worked out when it's
read. It doesn't nullify, so a to-one there can hold the ID of an object
that's gone.

**Custom functions** never reach a host: the guest evaluates the requests
that use them (above).

**IDs** are the app's strings (`ObjectID`), unique within an entity.

**`didChange`'s entities** are the ones a batch's objects belong to, and
the ones their relationships point at, whose other side changes with them.
A host may say more than changed, never less: a `Query` fetches again for
any entity it reads.

### Types

Each attribute type crosses as one of five kinds of value, which is the
getter, the setter and the `ModelExpression` constant used for it:

| `ModelAttributeType` | Code | Crosses as | Core Data | SQLite | IndexedDB |
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
| `decimal` | 11 | `string`: its description | Decimal | `TEXT`, compared in host code | string, compared in script |

CoreModel's composite attributes have no code: a store doesn't keep them
yet, and a model with one fails to open.

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

`migration` says what to do then: fail (the default, `ModelMigration.fail`),
or empty the store (`.reset`). A refused open changes nothing.
A custom migration is app code: open the old store under a new name with
its old model, copy across, and `destroy` it. That needs the stored model
back from the host, which is an open question (§15).

### Where it's kept

In the app's container, never visible to other apps, with no capability:

| Host | Place | Backed up | Notes |
|---|---|---|---|
| iOS / macOS | `Library/Stores/<name>/Store.sqlite`; without a sandbox, `Application Support/<bundle ID>/Stores` | yes | Data Protection: complete until first unlock. Beside the `Files` directories, not in `data`, so the app's files can't reach a store |
| Android | `getDatabasePath(name)` | Auto Backup, if the app allows it | |
| Linux distro | `/data/stores/<name>.sqlite` | the distro's business | |
| Browser | IndexedDB database `<app id>.<name>` | no | see below |

`name` is one path component: up to 64 letters, digits, `-`, `_` and `.`,
not starting with `.`. Anything else fails with `invalidRequest`.

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
| 2 | `invalidModel`: the schema contradicts itself or has what a store doesn't keep (a relationship to an entity it doesn't have, an inverse that isn't there, a key used twice, a composite attribute, an index on a key that isn't the entity's) |
| 3 | `migrationRequired` |
| 4 | `invalidRequest`: an entity or key the schema doesn't have, a property of another entity, a value of the wrong kind, a store name that isn't one |
| 5 | `unsupported`: a request feature this host lacks; guest-side, a composite value |
| 6 | `outOfSpace` |
| 7 | `unavailable`: no storage (a private window, a full disk at open, a host that keeps no stores) |
| 8 | `corrupted`: the store can't be read |
| 9 | `undecodable`: guest-side only, a record that doesn't decode as the entity asked for |

A code a guest doesn't know reads as `unknown`. Two `ModelStoreError`s are
equal when their codes are.

A failed batch changes nothing.

## For a host in Swift

`RuntimeCoreModel` implements these contracts over **any** CoreModel
`ModelStorage`. A host says where stores are kept and registers the
module:

```swift
HostModelStore.configure(.init(provider: MyStores(directory: container + "/Stores")))
HostModelStoreModule.register(in: runtime)
```

```swift
public protocol ModelStorageProvider: Sendable {
    /// Opens the store `name` for `model`, creating or migrating it.
    func open(_ name: String, model: Model, indexes: [EntityName: [[PropertyKey]]],
              migration: ModelMigration) async throws -> any ModelStorage
    func destroy(_ name: String) async throws
}
```

| Host | The backend its provider opens |
|---|---|
| iOS / macOS | `CoreDataModel`: an `NSPersistentContainer` whose model is built from the `Model`. DarwinAppRuntime's `DarwinModelStore` keeps the stored model in the store's metadata, and migrates with a mapping Core Data infers |
| Linux | CoreModel-SQLite |
| Tests, and a host with nowhere to keep stores yet | `InMemoryModelStorageProvider`, in this module |
| Android | Kotlin over `android.database.sqlite`, or CoreModel-SQLite if the host carries Swift: not this module |
| Browser | JavaScript over IndexedDB: not this module |

What the adapter does:

- **The objects.** Its schema, fetch, predicate, expression and record
  objects build CoreModel's `Model`, `FetchRequest` and `ModelData`, and
  check what the guest gives them against the model: that's where
  `invalidModel` and `invalidRequest` come from, before a backend is asked
  anything.
- **Order.** Operations for one store name run one at a time, in the order
  issued, off the main thread; `destroy` takes its turn among them.
- **Answers** go to the main dispatch queue, or wherever `deliver` posts
  them, for a host with a loop of its own. What a fetch returned is kept
  as its `ModelResults`.
- **`didChange`**, after a batch's callback, to every open store of that
  name.
- **Errors.** A `ModelStoreError` a backend or provider throws goes to the
  guest as it is; CoreModel's `invalidEntity` is `invalidRequest`; any
  other error is `unknown`, with its description as the message.

What's the provider's and its backend's:

- **Where a store is, and the stored model.** The provider compares the
  model with the one the store was made with, migrates, and throws
  `ModelStoreError(.migrationRequired)` or empties the store, by the rules
  above. `InMemoryModelStorageProvider` follows them, and
  `canMigrate(from:to:)` is the check.
- **Atomic batches.** A backend that conforms to `AtomicModelStorage` gets
  the batch whole (`perform(_:)`). Any other gets its inserts and deletes
  one after another, and one that fails leaves the ones before it in
  place. The adapter has checked every change against the model by then,
  so what's left to fail is the storage itself.
- **Relationships:** keeping the two sides in step, and what a delete does
  to the objects that pointed at it.
- **Indexes**, which it may ignore.

`HostModelStore.waitUntilIdle()` returns once every operation issued has
been answered, and every one those answers led the guest to issue: for
tests that drive a guest and then look at what it shows.

A callback or a delegate is the runtime's object, and so the main
thread's, to release as well as to call. Work on another thread carries
one in a `MainThreadHeld` (in `RuntimeHost`), which the main thread
empties.

### Not checked yet

**Conformance vectors** (a model, records, requests, the expected IDs,
generated from the in-memory backend) are how a host that isn't built on
CoreModel will check itself against the reference. They don't exist yet:
the tests here compare the adapter with the backend it's over.

**`CoreDataModel` against the reference.** DarwinAppRuntime's tests compare
the Core Data store with the in-memory backend, and it differs. These are
CoreModel's to fix:

- Without a sort, and among objects that sort equal, results come in Core
  Data's order, not in order of their IDs.
- An offset without a limit, and `IN` with a string, raise exceptions in
  Core Data.
- A batch isn't atomic: its changes are applied one after another.

And the reference itself has two bugs: it finds "ra" in "Édsger", since
its substring search steps through the pattern with the subject's indices,
and it doesn't read `[d]`.

## Threading

Every callback and delegate method runs on the main thread (§6.4). Hosts
do the I/O elsewhere and hop back. Nothing blocks the main thread: there
is no synchronous fetch, on any host, and reading a `ModelResults` reads
memory.

In host-side Swift, `RuntimeModelStorage`'s `async` methods run where
they're called from, so code on the main actor makes its contract calls
there. Called through the `ModelStorage` protocol they run on Swift's
pool, as any `async` requirement does: fine for one call after another,
and not for two at once.

## Example

`examples/ExampleModel`: to-dos in lists. Two entities and the
relationship between them; two `Query`s that keep the screen current; the
lists made in one batch at the first launch; a fetch with a sort and a
limit to number a new to-do; an insert of one property to tick one off; a
predicate through the relationship, counted with `async`/`await`. Its
tests run it against `HostModelStore` and the in-memory backend, across
two launches, as `App.wasm` under WasmKit (`Packages/RuntimeWasm`) and as a
sealed native slice and wasm2c output (`Packages/LinkedSlice`). The Darwin
host runs it over Core Data (DarwinAppRuntime's `DarwinModelStore`).

## Not in this design

- Syncing between devices (iCloud, a server): an app's own code, over the
  HTTP contracts.
- Aggregates (`sum`, `average`, grouping) beyond `count`.
- Full-text search.
- Entity inheritance, derived attributes, undo.
- Sharing a store between apps.

## Small values

A model store is the wrong tool for "has the user seen the welcome
screen". That's [Defaults](Defaults.md): a small synchronous key-value
store, with `UserDefaults` and `@AppStorage` for the guest.
