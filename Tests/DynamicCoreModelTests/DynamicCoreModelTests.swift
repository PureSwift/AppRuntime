import Foundation
import Testing
import CoreModel
import DynamicCoreModel
import DynamicRuntime
import RuntimeNative
@testable import RuntimeCoreModel

// MARK: The model

/// Entities written by hand, as a guest writes them: CoreModel's macros
/// are off under Embedded Swift.
struct Person: Entity, Equatable {

    static var entityName: EntityName { "Person" }

    static var attributes: [CodingKeys: AttributeType] {
        [
            .name: .string, .age: .int32, .rank: .int16, .visits: .int64, .ratio: .float, .score: .double,
            .isMember: .bool, .joined: .date, .token: .uuid, .homepage: .url, .balance: .decimal, .photo: .data,
        ]
    }

    static var relationships: [CodingKeys: Relationship] {
        [.team: Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members")]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, age, rank, visits, ratio, score, isMember, joined, token, homepage, balance, photo, team
    }

    let id: String
    var name: String
    var age: Int32
    var rank: Int16 = 0
    var visits: Int64 = 0
    var ratio: Float = 0
    var score: Double = 0
    var isMember = false
    var joined: Date?
    var token: UUID?
    var homepage: URL?
    var balance: Decimal?
    var photo: Data?
    var team: String?

    init(id: String, name: String, age: Int32, score: Double = 0, isMember: Bool = false, team: String? = nil) {
        self.id = id
        self.name = name
        self.age = age
        self.score = score
        self.isMember = isMember
        self.team = team
    }

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        name = try model.decode(String.self, forKey: CodingKeys.name)
        age = try model.decode(Int32.self, forKey: CodingKeys.age)
        rank = try model.decode(Int16.self, forKey: CodingKeys.rank)
        visits = try model.decode(Int64.self, forKey: CodingKeys.visits)
        ratio = try model.decode(Float.self, forKey: CodingKeys.ratio)
        score = try model.decode(Double.self, forKey: CodingKeys.score)
        isMember = try model.decode(Bool.self, forKey: CodingKeys.isMember)
        joined = try model.decode(Date?.self, forKey: CodingKeys.joined)
        token = try model.decode(UUID?.self, forKey: CodingKeys.token)
        homepage = try model.decode(URL?.self, forKey: CodingKeys.homepage)
        balance = try model.decode(Decimal?.self, forKey: CodingKeys.balance)
        photo = try model.decode(Data?.self, forKey: CodingKeys.photo)
        team = try model.decodeRelationship(String?.self, forKey: CodingKeys.team)
    }

    func encode() -> ModelData {
        var data = ModelData(entity: Self.entityName, id: ObjectID(rawValue: id))
        data.encode(name, forKey: CodingKeys.name)
        data.encode(age, forKey: CodingKeys.age)
        data.encode(rank, forKey: CodingKeys.rank)
        data.encode(visits, forKey: CodingKeys.visits)
        data.encode(ratio, forKey: CodingKeys.ratio)
        data.encode(score, forKey: CodingKeys.score)
        data.encode(isMember, forKey: CodingKeys.isMember)
        data.encode(joined, forKey: CodingKeys.joined)
        data.encode(token, forKey: CodingKeys.token)
        data.encode(homepage, forKey: CodingKeys.homepage)
        data.encode(balance, forKey: CodingKeys.balance)
        data.encode(photo, forKey: CodingKeys.photo)
        data.encodeRelationship(team, forKey: CodingKeys.team)
        return data
    }
}

struct Team: Entity, Equatable {

    static var entityName: EntityName { "Team" }

    static var attributes: [CodingKeys: AttributeType] { [.name: .string] }

    static var relationships: [CodingKeys: Relationship] {
        [.members: Relationship(id: "members", type: .toMany, destinationEntity: "Person", inverseRelationship: "team")]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, members
    }

    let id: String
    var name: String
    var members: [String] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        name = try model.decode(String.self, forKey: CodingKeys.name)
        members = try model.decodeRelationship([String].self, forKey: CodingKeys.members).sorted()
    }

    func encode() -> ModelData {
        var data = ModelData(entity: Self.entityName, id: ObjectID(rawValue: id))
        data.encode(name, forKey: CodingKeys.name)
        return data
    }
}

final class Counter: @unchecked Sendable {
    var count = 0
}

/// `RuntimeModelStorage`, `FetchedResults` and `Query` in the guest, over
/// the contracts, against the host adapter and CoreModel's own in-memory
/// backend, which is also the reference for what a request returns.
///
/// Serialized, and on the main actor: the provider and the native runtime
/// are shared, and the guest's calls and the host's answers must share a
/// thread, as they do in a host (§6.4).
@MainActor @Suite(.serialized) final class DynamicCoreModelTests {

    static let model = Model(entities: [
        EntityDescription(entity: Person.self),
        EntityDescription(entity: Team.self),
        // Related to neither.
        EntityDescription(id: "Note", attributes: [Attribute(id: "text", type: .string)], relationships: []),
    ])

    let provider = InMemoryModelStorageProvider()

    /// A store name no other test uses.
    let name = "test-" + UUID().uuidString

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostModelStore.configure(.init(provider: provider))
        HostModelStoreModule.register(in: native)
    }

    func open(_ model: Model = DynamicCoreModelTests.model, migration: ModelMigration = .fail) async throws -> RuntimeModelStorage {
        try await RuntimeModelStorage.open(name, model: model, migration: migration)
    }

    /// The backend the host opened, to compare with.
    func backend() async throws -> InMemoryModelStorage {
        try #require(await provider.storage(name))
    }

    static let people: [Person] = {
        var ada = Person(id: "ada", name: "Ada", age: 36, score: 9.5, isMember: true, team: "engine")
        ada.rank = -3
        ada.visits = 1 << 40
        ada.ratio = 0.25
        ada.joined = Date(timeIntervalSince1970: 1_700_000_000.5)
        ada.token = UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")
        ada.homepage = URL(string: "https://example.com/ada?x=1")
        ada.balance = Decimal(string: "1234.5678")
        ada.photo = Data([0, 1, 2, 255])
        return [
            ada,
            Person(id: "grace", name: "Grace", age: 45, score: 8, isMember: true, team: "engine"),
            Person(id: "alan", name: "alan", age: 41, score: 7.25, team: "theory"),
            Person(id: "edsger", name: "Édsger", age: 17, score: 0),
            Person(id: "linus", name: "Linus", age: 17, score: 3, isMember: true, team: "theory"),
        ]
    }()

    func fill(_ store: RuntimeModelStorage) async throws {
        var changes = ModelChanges()
        changes.insert(Team(id: "engine", name: "Engine").encode())
        changes.insert(Team(id: "theory", name: "Theory").encode())
        for person in Self.people {
            changes.insert(person.encode())
        }
        try await store.perform(changes)
    }

    /// What a failing call failed with; `nil` when it didn't.
    func failure(_ body: () async throws -> Void) async -> ModelStoreError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? ModelStoreError)?.code
        }
    }

    // MARK: Values

    @Test func everyAttributeTypeCrossesAndComesBack() async throws {
        let store = try await open()
        try await fill(store)

        let ada = try #require(try await store.fetch(Person.self, for: "ada"))
        #expect(ada == Self.people[0])

        // The backend holds CoreModel's own values, of the model's types.
        let stored = try #require(try await backend().fetch("Person", for: "ada"))
        #expect(stored.attributes["age"] == .int32(36))
        #expect(stored.attributes["rank"] == .int16(-3))
        #expect(stored.attributes["visits"] == .int64(1 << 40))
        #expect(stored.attributes["ratio"] == .float(0.25))
        #expect(stored.attributes["joined"] == .date(Date(timeIntervalSince1970: 1_700_000_000.5)))
        #expect(stored.attributes["token"] == .uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!))
        #expect(stored.attributes["homepage"] == .url(URL(string: "https://example.com/ada?x=1")!))
        #expect(stored.attributes["balance"] == .decimal(Decimal(string: "1234.5678")!))
        #expect(stored.attributes["photo"] == .data(Data([0, 1, 2, 255])))
        #expect(stored.relationships["team"] == .toOne("engine"))

        // Nulls come back as nulls, not as zeros.
        let grace = try #require(try await store.fetch("Person", for: "grace"))
        #expect(grace.attributes["joined"] == .null)
        #expect(grace.attributes["photo"] == .null)
        #expect(grace.attributes["score"] == .double(8))
        #expect(grace.attributes["rank"] == .int16(0), "a zero that was stored isn't a null")
        let edsger = try #require(try await store.fetch("Person", for: "edsger"))
        #expect(edsger.relationships["team"] == .null)
        #expect(edsger.attributes["isMember"] == .bool(false))

        #expect(try await store.fetch(Person.self, for: "nobody") == nil)
    }

    @Test func valuesCrossAsFiveKinds() {
        let uuid = UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!
        let crossed = ModelValue.crossing(.uuid(uuid))
        #expect(crossed?.value == .string("9e3c1a52-0c1b-4f0e-9d4b-6a1f2c3d4e5f"), "lowercase, for hosts that compare text")
        #expect(crossed?.type == .uuid)
        #expect(ModelValue.string("9e3c1a52-0c1b-4f0e-9d4b-6a1f2c3d4e5f").attributeValue(as: .uuid) == .uuid(uuid))
        #expect(ModelValue.string("not a uuid").attributeValue(as: .uuid) == nil)
        #expect(ModelValue.integer(40_000).attributeValue(as: .int16) == nil, "it doesn't fit")
        #expect(ModelValue.integer(40_000).attributeValue(as: .int32) == .int32(40_000))
        #expect(ModelValue.integer(1).attributeValue(as: .double) == nil, "the wrong kind")
        #expect(ModelValue.double(86_400).attributeValue(as: .date) == .date(Date(timeIntervalSince1970: 86_400)))
        #expect(ModelValue.null.attributeValue(as: .string) == .null)
        #expect(ModelValue.crossing(.composite([:])) == nil)
        for type in ModelAttributeType.allCases {
            #expect(ModelAttributeType(type.attributeType) == type)
        }
        for operation in ModelComparison.allCases {
            #expect(ModelComparison(operation.operation) == operation)
        }
        let options: Set<FetchRequest.Predicate.Comparison.Option> = [.caseInsensitive, .diacriticInsensitive]
        #expect(ModelComparisonOptions(options).rawValue == 3)
        #expect(ModelComparisonOptions(rawValue: 3).options == options)
    }

    // MARK: Fetching

    /// Requests of every shape, each answered through the contracts and by
    /// the backend itself: the two must agree.
    @Test func requestsMatchTheReference() async throws {
        let store = try await open()
        try await fill(store)
        let backend = try await backend()

        typealias Predicate = FetchRequest.Predicate
        let age: Predicate.Expression = .keyPath("age")
        let predicates: [Predicate?] = [
            nil,
            .value(true),
            .value(false),
            Person.CodingKeys.age >= Int32(18),
            Person.CodingKeys.age < Int32(18),
            Person.CodingKeys.age == Int32(17),
            Person.CodingKeys.age != Int32(17),
            Person.CodingKeys.score > 7.5,
            Person.CodingKeys.isMember == true,
            Person.CodingKeys.name == "alan",
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("a")), type: .beginsWith)),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("a")), type: .beginsWith, options: [.caseInsensitive])),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("N")), type: .endsWith, options: [.caseInsensitive])),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("ra")), type: .contains)),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("*a*")), type: .like)),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("Ada Lovelace")), type: .in)),
            .comparison(.init(left: .keyPath("joined"), right: .attribute(.null), type: .equalTo)),
            .comparison(.init(left: .keyPath("joined"), right: .attribute(.date(Date(timeIntervalSince1970: 1_600_000_000))), type: .greaterThan)),
            .comparison(.init(left: .keyPath("token"), right: .attribute(.uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!)), type: .equalTo)),
            .comparison(.init(left: .keyPath("photo"), right: .attribute(.data(Data([0, 1, 2, 255]))), type: .equalTo)),
            .comparison(.init(left: .keyPath("visits"), right: .attribute(.int64(1 << 40)), type: .equalTo)),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.toOne("engine")), type: .equalTo)),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.null), type: .equalTo)),
            .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Theory")), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .add, left: age, right: .attribute(.int32(4)))), right: .attribute(.int32(45)), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .multiply, left: .keyPath("score"), right: .attribute(.double(2)))), right: .attribute(.double(15)), type: .greaterThan)),
            .compound(.and([Person.CodingKeys.age >= Int32(18), Person.CodingKeys.isMember == true])),
            .compound(.or([Person.CodingKeys.age < Int32(18), Person.CodingKeys.name == "Ada"])),
            .compound(.not(Person.CodingKeys.isMember == true)),
            .compound(.and([])),
            .compound(.or([])),
        ]
        let sorts: [[FetchRequest.SortDescriptor]] = [
            [],
            [.init(property: "name")],
            [.init(property: "age"), .init(property: "score", ascending: false)],
            [.init(property: "joined", ascending: false)],
        ]
        var compared = 0
        for predicate in predicates {
            for sort in sorts {
                for (limit, offset) in [(0, 0), (2, 0), (2, 1), (0, 4)] {
                    let request = FetchRequest(entity: "Person", sortDescriptors: sort, predicate: predicate, fetchLimit: limit, fetchOffset: offset)
                    let expected = try await backend.fetch(request)
                    let found = try await store.fetch(request)
                    #expect(found.map(\.id) == expected.map(\.id), "\(String(describing: predicate)) \(sort) \(limit) \(offset)")
                    #expect(try await store.fetchID(request) == expected.map(\.id))
                    #expect(try await store.count(request) == UInt(expected.count))
                    compared += 1
                }
            }
        }
        #expect(compared == predicates.count * 16)

        // Something matched: the reference isn't answering nothing to everything.
        #expect(try await store.count(FetchRequest(entity: "Person", predicate: Person.CodingKeys.age >= Int32(18))) == 3)
        #expect(try await store.fetchID(FetchRequest(entity: "Person", predicate: .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Theory")), type: .equalTo)))) == ["alan", "linus"])

        // The other side of a relationship is the host's to keep.
        let engine = try #require(try await store.fetch("Team", for: "engine"))
        #expect(try Team(from: engine).members == ["ada", "grace"])
        let members: FetchRequest.Predicate = .comparison(.init(left: .keyPath("members"), right: .relationship(.toOne("linus")), type: .contains))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: members)) == ["theory"])
        let anyMember: FetchRequest.Predicate = .comparison(.init(left: .keyPath("members.age"), right: .attribute(.int32(40)), type: .greaterThan, modifier: .any))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: anyMember)) == (try await backend.fetchID(FetchRequest(entity: "Team", predicate: anyMember))))
    }

    @Test func resultsAreReadAsTheyAreUsed() async throws {
        let store = try await open()
        try await fill(store)
        let request = FetchRequest(entity: "Person", sortDescriptors: [.init(property: "name")])
        let results = try await store.results(Person.self, for: request)

        #expect(results.count == 5)
        #expect(results.records.readCount == 0, "the count needs no record")
        #expect(results[1].name == "Grace")
        #expect(results.records.readCount == 1)
        #expect(results[1].name == "Grace")
        #expect(results.records.readCount == 1, "a record is read once")
        #expect(results.last?.id == "edsger")
        #expect(results.map(\.name) == ["Ada", "Grace", "Linus", "alan", "Édsger"])
        #expect(results.records.readCount == 5)
        #expect(try results.element(at: 0) == Self.people[0])

        // A snapshot: what the fetch found, whatever is written afterwards.
        let snapshot = try await store.results(Person.self, for: request)
        try await store.delete("Person", for: "grace")
        try await store.insert(Person(id: "zed", name: "Zed", age: 1).encode())
        #expect(snapshot.count == 5)
        #expect(snapshot[1].name == "Grace")
        #expect(try await store.results(Person.self, for: request).map(\.id) == ["ada", "linus", "zed", "alan", "edsger"])

        #expect(FetchedResults<Person>().isEmpty)
        #expect(FetchedRecords([Self.people[0].encode()]).first?.id == "ada")
    }

    @Test func functionsRunInTheGuest() async throws {
        let store = try await open()
        try await fill(store)
        store.register(function: DatabaseFunction(name: "initial", argumentCount: 1) { arguments in
            guard case .string(let name)? = arguments.first else { return nil }
            return .string(String(name.prefix(1)).uppercased())
        })
        let initial = FetchRequest.Predicate.FunctionExpression(name: "initial", arguments: [.keyPath("name")])
        let request = FetchRequest(
            entity: "Person",
            sortDescriptors: [.init(term: .function(initial)), .init(property: "age")],
            predicate: .comparison(.init(left: .function(initial), right: .attribute(.string("A")), type: .equalTo))
        )
        #expect(try await store.fetch(request).map(\.id) == ["ada", "alan"])
        #expect(try await store.fetchID(request) == ["ada", "alan"])
        #expect(try await store.count(request) == 2)
        #expect(try await store.results(Person.self, for: request).map(\.name) == ["Ada", "alan"])
    }

    // MARK: Changing

    @Test func aBatchIsAppliedInOrderAndMerges() async throws {
        let store = try await open()
        try await fill(store)

        // An insert over an object sets what it has and leaves the rest.
        var partial = ModelData(entity: "Person", id: "ada")
        partial.attributes["age"] = .int32(37)
        partial.attributes["photo"] = .null
        var changes = ModelChanges()
        changes.insert(partial)
        changes.insert(Person(id: "new", name: "New", age: 1).encode())
        changes.delete("Person", for: "new")
        changes.delete("Person", for: "linus")
        changes.delete("Person", for: "never-there")
        try await store.perform(changes)

        let ada = try #require(try await store.fetch(Person.self, for: "ada"))
        #expect(ada.age == 37)
        #expect(ada.name == "Ada", "left as it was")
        #expect(ada.photo == nil, "set to null")
        #expect(ada.team == "engine")
        #expect(try await store.fetchID(FetchRequest(entity: "Person")) == ["ada", "alan", "edsger", "grace"])

        try await store.delete("Person", for: ["alan", "edsger"])
        try await store.insert([Person(id: "b", name: "B", age: 2).encode(), Person(id: "c", name: "C", age: 3).encode()])
        #expect(try await store.fetchID(FetchRequest(entity: "Person")) == ["ada", "b", "c", "grace"])
        try await store.perform(ModelChanges())
    }

    @Test func aBatchThatCannotBeAppliedChangesNothing() async throws {
        let store = try await open()
        try await fill(store)

        var wrongType = ModelData(entity: "Person", id: "x")
        wrongType.attributes["age"] = .string("thirty")
        var unknownKey = ModelData(entity: "Person", id: "x")
        unknownKey.attributes["shoeSize"] = .int32(9)
        var tooBig = ModelData(entity: "Person", id: "x")
        tooBig.attributes["rank"] = .int32(100_000)
        var wrongKind = ModelData(entity: "Person", id: "x")
        wrongKind.relationships["team"] = .toMany(["engine"])
        var composite = ModelData(entity: "Person", id: "x")
        composite.attributes["name"] = .composite([:])

        for (bad, code) in [(wrongType, ModelStoreError.Code.invalidRequest), (unknownKey, .invalidRequest), (tooBig, .invalidRequest),
                            (wrongKind, .invalidRequest), (composite, .unsupported), (ModelData(entity: "Planet", id: "x"), .invalidRequest)] {
            var changes = ModelChanges()
            changes.insert(Person(id: "good", name: "Good", age: 1).encode())
            changes.insert(bad)
            #expect(await failure { try await store.perform(changes) } == code)
        }
        #expect(await failure { try await store.delete("Planet", for: "x") } == .invalidRequest)
        #expect(try await store.count(FetchRequest(entity: "Person")) == 5, "the good insert beside each bad one wasn't made")

        // A number that fits a narrower type is that type's.
        var fits = ModelData(entity: "Person", id: "ada")
        fits.attributes["rank"] = .int64(12)
        try await store.insert(fits)
        #expect(try await backend().fetch("Person", for: "ada")?.attributes["rank"] == .int16(12))
    }

    @Test func requestsTheModelDoesNotHaveAreRefused() async throws {
        let store = try await open()
        try await fill(store)
        #expect(await failure { _ = try await store.fetch(FetchRequest(entity: "Planet")) } == .invalidRequest)
        #expect(await failure { _ = try await store.fetch("Planet", for: "x") } == .invalidRequest)
        #expect(await failure { _ = try await store.fetch(FetchRequest(entity: "Person", sortDescriptors: [.init(property: "shoeSize")])) } == .invalidRequest)
        #expect(await failure { _ = try await store.count(FetchRequest(entity: "Person", predicate: "shoeSize" == Int32(9))) } == .invalidRequest)
        #expect(await failure { _ = try await store.fetchID(FetchRequest(entity: "Person", sortDescriptors: [.init(property: "team")])) } == .invalidRequest)
        let composite: FetchRequest.Predicate = .comparison(.init(left: .keyPath("name"), right: .attribute(.composite([:]))))
        #expect(await failure { _ = try await store.fetch(FetchRequest(entity: "Person", predicate: composite)) } == .unsupported)
        // And the store is still fine.
        #expect(try await store.count(FetchRequest(entity: "Person")) == 5)
    }

    // MARK: Changes

    @Test func observersHearOfEachBatchOnce() async throws {
        let store = try await open()
        var heard = [[EntityName]]()
        let observer = store.addChangeObserver { heard.append($0) }
        let stream = store.changes

        try await fill(store)
        #expect(heard == [["Person", "Team"]])
        try await store.insert(Team(id: "new", name: "New").encode())
        #expect(heard.last == ["Person", "Team"], "a team's members are people")
        try await store.perform(ModelChanges())
        #expect(heard.count == 2, "nothing was touched")
        _ = await failure { try await store.insert(ModelData(entity: "Planet", id: "x")) }
        #expect(heard.count == 2, "nothing was committed")

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == ["Person", "Team"])

        store.removeChangeObserver(observer)
        try await store.delete("Team", for: "new")
        #expect(heard.count == 2)

        // An observer that removes a later one: that one isn't called.
        var later = 0
        var second = 0
        store.addChangeObserver { _ in store.removeChangeObserver(second) }
        second = store.addChangeObserver { _ in later += 1 }
        try await store.insert(Team(id: "again", name: "Again").encode())
        #expect(later == 0)
    }

    @Test func everyStorageOfAStoreHearsItsChanges() async throws {
        let first = try await open()
        let second = try await open()
        var heard = 0
        second.addChangeObserver { _ in heard += 1 }
        try await first.insert(Team(id: "t", name: "T").encode())
        #expect(heard == 1)
        #expect(try await second.count(FetchRequest(entity: "Team")) == 1, "one store, opened twice")
    }

    // MARK: Query

    @Test func aQueryStaysCurrent() async throws {
        let store = try await open()
        try await fill(store)
        let adults = Query<Person>(store, predicate: Person.CodingKeys.age >= Int32(18), sort: [.init(property: "name")])
        #expect(adults.isLoading)
        #expect(adults.results.isEmpty)

        let changes = Counter()
        _ = withObservationTracking { adults.results.count } onChange: { changes.count += 1 }
        #expect(try await store.count(FetchRequest(entity: "Person")) == 5)   // the query's fetch was issued first
        #expect(adults.results.map(\.name) == ["Ada", "Grace", "alan"])
        #expect(!adults.isLoading)
        #expect(adults.error == nil)
        #expect(changes.count == 1)

        // Several writes, each of which it hears of.
        try await store.insert(Person(id: "kay", name: "Kay", age: 50).encode())
        try await store.delete("Person", for: "grace")
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(adults.results.map(\.name) == ["Ada", "Kay", "alan"])

        // A change to another entity isn't its business.
        let before = adults.results.records.snapshotIdentity
        var note = ModelData(entity: "Note", id: "n")
        note.attributes["text"] = .string("unrelated")
        try await store.insert(note)
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(adults.results.records.snapshotIdentity == before, "no new fetch")

        // Changing the request fetches again.
        adults.predicate = Person.CodingKeys.age < Int32(18)
        adults.sort = [.init(property: "name", ascending: false)]
        adults.limit = 1
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(adults.results.map(\.name) == ["Édsger"])
    }

    @Test func aQueryWatchesWhatItsPredicateReaches() async throws {
        let store = try await open()
        try await fill(store)
        let theory: FetchRequest.Predicate = .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Theory")), type: .equalTo))
        let query = Query<Person>(store, predicate: theory)
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(query.results.map(\.id) == ["alan", "linus"])

        try await store.insert(Team(id: "engine", name: "Theory").encode())
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(query.results.map(\.id) == ["ada", "alan", "grace", "linus"], "a team was renamed, and the query is about teams' names")
    }

    @Test func aQueryReportsAFailedFetchAndKeepsWhatItHad() async throws {
        let store = try await open()
        try await fill(store)
        let query = Query<Person>(store)
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(query.results.count == 5)

        query.sort = [.init(property: "shoeSize")]
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(query.error?.code == .invalidRequest)
        #expect(query.results.count == 5)
        #expect(!query.isLoading)

        query.sort = []
        _ = try await store.count(FetchRequest(entity: "Person"))
        #expect(query.error == nil)
    }

    // MARK: Opening

    @Test func aStorageCanBeUsedBeforeItIsOpen() async throws {
        var opened: ModelStoreError?? = nil
        let store = RuntimeModelStorage(name, model: Self.model, indexes: ["Person": [["name"], ["age", "score"]]]) { opened = .some($0) }
        // Issued at once; they wait for the open.
        try await store.insert(Team(id: "t", name: "T").encode())
        #expect(opened == .some(nil))
        #expect(try await store.count(FetchRequest(entity: "Team")) == 1)
        #expect(store.name == name)
    }

    @Test func aStoreKeepsItsObjectsBetweenOpenings() async throws {
        do {
            let store = try await open()
            try await fill(store)
        }
        let again = try await open()
        #expect(try await again.count(FetchRequest(entity: "Person")) == 5)

        try await RuntimeModelStorage.destroy(name)
        let fresh = try await open()
        #expect(try await fresh.count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func modelsThatCannotBeKeptAreRefused() async throws {
        let composite = Model(entities: [EntityDescription(id: "Place", attributes: [Attribute(id: "address", elements: [Attribute(id: "city", type: .string)])], relationships: [])])
        #expect(await failure { _ = try await self.open(composite) } == .invalidModel)

        let dangling = Model(entities: [EntityDescription(id: "Person", attributes: [], relationships: [
            Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members"),
        ])])
        #expect(await failure { _ = try await self.open(dangling) } == .invalidModel)

        let noInverse = Model(entities: [
            EntityDescription(id: "Person", attributes: [], relationships: [Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members")]),
            EntityDescription(id: "Team", attributes: [], relationships: []),
        ])
        #expect(await failure { _ = try await self.open(noInverse) } == .invalidModel)

        #expect(await failure { _ = try await RuntimeModelStorage.open(self.name, model: Self.model, indexes: ["Person": [["shoeSize"]]]) } == .invalidModel)
        #expect(await failure { _ = try await RuntimeModelStorage.open(self.name, model: Self.model, indexes: ["Planet": [["name"]]]) } == .invalidModel)
        #expect(await failure { _ = try await RuntimeModelStorage.open("../escape", model: Self.model) } == .invalidRequest)
        #expect(await failure { _ = try await RuntimeModelStorage.open("", model: Self.model) } == .invalidRequest)
        #expect(await failure { try await RuntimeModelStorage.destroy("a/b") } == .invalidRequest)

        // A storage that didn't open fails everything with why.
        var opened: ModelStoreError?? = nil
        let broken = RuntimeModelStorage(name, model: composite) { opened = .some($0) }
        #expect(opened??.code == .invalidModel)
        #expect(await failure { _ = try await broken.count(FetchRequest(entity: "Place")) } == .invalidModel)
        #expect(await failure { try await broken.insert(ModelData(entity: "Place", id: "x")) } == .invalidModel)
        let refused = RuntimeModelStorage(name, model: dangling)
        #expect(await failure { _ = try await refused.count(FetchRequest(entity: "Person")) } == .invalidModel)
    }

    @Test func storeNamesAreOnePathComponent() {
        for name in ["library", "a", "Library-2.db", "under_score", String(repeating: "x", count: 64)] {
            #expect(HostModelStore.isValid(name: name), "\(name)")
        }
        for name in ["", ".", "..", ".hidden", "a/b", "a\\b", "a b", "naïve", "a\0b", String(repeating: "x", count: 65)] {
            #expect(!HostModelStore.isValid(name: name), "\(name)")
        }
    }

    @Test func aChangedModelMigratesOrIsRefused() async throws {
        do {
            let store = try await open()
            try await fill(store)
        }
        // More and fewer properties and entities: the objects stay.
        var grown = Self.model
        grown.entities[0].attributes.append(Attribute(id: "nickname", type: .string))
        grown.entities[0].attributes.removeAll { $0.id == "photo" }
        grown.entities.append(EntityDescription(id: "Tag", attributes: [Attribute(id: "text", type: .string)], relationships: []))
        grown.entities.removeAll { $0.id == "Note" }
        do {
            let store = try await open(grown)
            let ada = try #require(try await store.fetch("Person", for: "ada"))
            #expect(ada.attributes["name"] == .string("Ada"))
            #expect(ada.attributes["nickname"] == .null, "what's new reads as null")
            #expect(ada.attributes["photo"] == nil)
            #expect(try await store.count(FetchRequest(entity: "Tag")) == 0)
            #expect(await failure { _ = try await store.count(FetchRequest(entity: "Note")) } == .invalidRequest)
        }
        // A type that changed can't be read as the new one.
        var retyped = grown
        retyped.entities[0].attributes.removeAll { $0.id == "age" }
        retyped.entities[0].attributes.append(Attribute(id: "age", type: .string))
        #expect(await failure { _ = try await self.open(retyped) } == .migrationRequired)
        do {
            let untouched = try await open(grown)
            #expect(try await untouched.count(FetchRequest(entity: "Person")) == 5, "the refusal changed nothing")
        }
        let emptied = try await open(retyped, migration: .reset)
        #expect(try await emptied.count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func withoutAProviderThereIsNoStore() async throws {
        // Unconfigure for one open, as a host with nowhere to keep stores.
        HostModelStore.unconfigure()
        defer { HostModelStore.configure(.init(provider: provider)) }
        #expect(await failure { _ = try await self.open() } == .unavailable)
        #expect(await failure { try await RuntimeModelStorage.destroy(self.name) } == .unavailable)
    }

    // MARK: As a ModelStorage

    /// Code that only knows the protocol, with CoreModel's own typed
    /// conveniences.
    func exercise(_ store: some ModelStorage) async throws -> [String] {
        try await store.insert(Person(id: "p", name: "Protocol", age: 20))
        try await store.insert([Team(id: "t", name: "T").encode()])
        let found = try await store.fetch(Person.self, sortDescriptors: [.init(property: "name")], predicate: Person.CodingKeys.age >= Int32(18))
        let count = try await store.count(FetchRequest(entity: "Team"))
        try await store.delete(Team.self, for: "t")
        let teams = try await store.fetchID(FetchRequest(entity: "Team"))
        return found.map(\.name) + ["\(count)", "\(teams.count)"]
    }

    @Test func itIsAModelStorage() async throws {
        let store = try await open()
        #expect(try await exercise(store) == ["Protocol", "1", "0"])
        // The same code, on CoreModel's own backend.
        #expect(try await exercise(InMemoryModelStorage(model: Self.model)) == ["Protocol", "1", "0"])
    }

    // MARK: The host's objects

    @Test func moduleListsItsContracts() {
        #expect(HostModelStoreModule.contracts.map(\.name) == [
            "org.pureswift.data.ModelStore", "org.pureswift.data.ModelSchema", "org.pureswift.data.ModelEntity",
            "org.pureswift.data.ModelProperty", "org.pureswift.data.ModelFetch", "org.pureswift.data.ModelPredicate",
            "org.pureswift.data.ModelExpression", "org.pureswift.data.ModelRecord", "org.pureswift.data.ModelResults",
            "org.pureswift.data.ModelBatch", "org.pureswift.data.ModelStoreCallback", "org.pureswift.data.ModelStoreDelegate",
        ])
        #expect(HostModelStoreModule.isUsed(by: ["org.pureswift.data.ModelStore"]))
    }

    @Test func whatAGuestCannotMeanIsUnreadable() {
        #expect(HostModelExpression.integer(1, type: ModelAttributeType.string.rawValue).value == nil, "an integer isn't a string")
        #expect(HostModelExpression.integer(1, type: 99).value == nil)
        #expect(HostModelExpression.integer(70_000, type: ModelAttributeType.int16.rawValue).value == nil)
        #expect(HostModelExpression.string("x", type: ModelAttributeType.uuid.rawValue).value == nil)
        #expect(HostModelExpression.double(1, type: ModelAttributeType.date.rawValue).value == .attribute(.date(Date(timeIntervalSince1970: 1))))
        #expect(HostModelExpression.keyPath("").value == nil)
        #expect(HostModelExpression.keyPath("team..name").value == nil)
        #expect(HostModelExpression.keyPath("team.name").value == .keyPath("team.name"))

        let good = HostModelExpression.keyPath("age")
        let bad = HostModelExpression.keyPath("")
        #expect(HostModelPredicate.comparison(good, operation: 4, right: good, modifier: 0, options: 0).value != nil)
        #expect(HostModelPredicate.comparison(good, operation: 99, right: good, modifier: 0, options: 0).value == nil)
        #expect(HostModelPredicate.comparison(good, operation: 4, right: good, modifier: 9, options: 0).value == nil)
        #expect(HostModelPredicate.comparison(good, operation: 4, right: good, modifier: 0, options: 16).value == nil)
        #expect(HostModelPredicate.comparison(good, operation: 4, right: bad, modifier: 0, options: 0).value == nil)
        let unreadable = HostModelPredicate.comparison(bad, operation: 4, right: good, modifier: 0, options: 0)
        #expect(HostModelPredicate.and([HostModelPredicate.constant(true), unreadable]).value == nil)
        #expect(HostModelPredicate.not(unreadable).value == nil)
        #expect(HostModelExpression.arithmetic(good, operation: 7, right: good).value == nil)
    }

    @Test func recordsAnswerOnlyForTheirOwnProperties() throws {
        let schema = HostModelSchema.make()
        let person = schema.addEntity("Person")
        let name = person.addAttribute("name", type: ModelAttributeType.string.rawValue)
        let age = person.addAttribute("age", type: ModelAttributeType.int32.rawValue)
        let team = person.addRelationship("team", toMany: false, destination: "Team", inverse: "members")
        let other = schema.addEntity("Team")
        let members = other.addRelationship("members", toMany: true, destination: "Person", inverse: "team")
        let teamName = other.addAttribute("name", type: ModelAttributeType.string.rawValue)
        #expect(name.key() == "name")
        #expect(try schema.model().get().entities.count == 2)

        let record = HostModelRecord.make(person, id: "p")
        #expect(record.id() == "p")
        #expect(record.isNull(name))
        record.setString("Ada", for: name)
        record.setInteger(36, for: age)
        record.setToOne("engine", for: team)
        #expect(record.string(name) == "Ada")
        #expect(record.integer(age) == 36)
        #expect(record.toOne(team) == "engine")
        #expect(!record.isNull(team))
        // The wrong getter, and another entity's property, answer nothing.
        #expect(record.integer(name) == 0)
        #expect(record.string(age) == nil)
        #expect(record.bool(age) == false)
        #expect(record.double(age) == 0)
        #expect(record.data(name) == nil)
        #expect(record.string(teamName) == nil)
        #expect(record.toMany(members) == [])
        #expect(record.isNull(teamName))
        #expect(record.problem == nil)
        record.setNull(team)
        #expect(record.toOne(team) == nil)

        // The wrong setter spoils the record, and so its batch.
        record.setString("x", for: teamName)
        #expect(record.problem != nil)
        let batch = HostModelBatch.make()
        batch.insert(record)
        #expect(throws: ModelStoreError.self) { try batch.changes(in: Self.model).get() }

        // A fetched record is read-only.
        let fetched = HostModelResults([Self.people[0].encode()])
        #expect(fetched.count() == 1)
        let ada = fetched.record(at: 0)
        ada.setString("Changed", for: name)
        #expect(ada.string(name) == "Ada")
        #expect(fetched.record(at: 5).id() == "", "out of range, there's nothing")
        #expect(fetched.record(at: -1).isNull(name))

        // Declaring something twice, or not at all, fails the schema.
        _ = person.addAttribute("name", type: ModelAttributeType.string.rawValue)
        #expect(throws: ModelStoreError.self) { try schema.model().get() }
        let unknownType = HostModelSchema.make()
        _ = unknownType.addEntity("Thing").addAttribute("x", type: 99)
        #expect(throws: ModelStoreError.self) { try unknownType.model().get() }
        let unnamed = HostModelSchema.make()
        _ = unnamed.addEntity("")
        #expect(throws: ModelStoreError.self) { try unnamed.model().get() }
    }

    @Test func nothingIsLeftBehind() async throws {
        let before = NativeRuntime.shared.runtime.handleCount
        do {
            let store = try await open()
            try await fill(store)
            let query = Query<Person>(store)
            let results = try await store.results(Person.self, for: FetchRequest(entity: "Person"))
            #expect(results.map(\.id).count == 5)
            #expect(query.results.count == 5)
        }
        #expect(NativeRuntime.shared.runtime.handleCount == before, "the schema, fetches, records, results, store and callbacks are all released")
    }
}
