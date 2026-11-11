import Testing
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
@testable import DynamicObservation
@testable import ObservationMacros

@Observable
final class Model {
    var name: String = "a"
    var count = 0
    @ObservationIgnored var ignored = 0
    let constant = 1
    var computed: Int { count * 2 }
}

@Observable
final class Person {
    var first: String
    var last: String

    init(first: String, last: String) {
        self.first = first
        self.last = last
    }
}

/// A subject for driving the registrar directly, with any index.
final class Subject: Observable {
    let registrar = ObservationRegistrar()
}

/// Counts calls from `@Sendable` change handlers. Tests run each check on one
/// task, like a guest.
final class Counter: @unchecked Sendable {
    var value = 0
    func increment() { value += 1 }
}

@Suite struct ObservationTests {

    // MARK: withObservationTracking

    @Test func changeToAReadPropertyFiresOnce() {
        let model = Model()
        let changes = Counter()
        let name = withObservationTracking { model.name } onChange: { changes.increment() }
        #expect(name == "a")
        model.count = 1
        #expect(changes.value == 0, "not read")
        model.name = "b"
        model.name = "c"
        #expect(changes.value == 1, "one-shot: cancelled after firing")
    }

    @Test func ignoredAndComputedProperties() {
        let model = Model()
        let changes = Counter()
        _ = withObservationTracking { model.ignored + model.computed } onChange: { changes.increment() }
        model.ignored = 5
        #expect(changes.value == 0, "@ObservationIgnored isn't tracked")
        model.count = 3
        #expect(changes.value == 1, "computed reads track what they read")
    }

    @Test func nestedTrackingCountsTowardTheOuter() {
        let model = Model()
        let outer = Counter(), inner = Counter()
        withObservationTracking {
            _ = model.count
            _ = withObservationTracking { model.name } onChange: { inner.increment() }
        } onChange: { outer.increment() }
        model.name = "x"
        #expect(inner.value == 1)
        #expect(outer.value == 1)
    }

    @Test func initializerAssignmentsAndMutationsInPlace() {
        let person = Person(first: "Ada", last: "L")
        let changes = Counter()
        _ = withObservationTracking { person.first } onChange: { changes.increment() }
        person.first.append("!")
        #expect(person.first == "Ada!")
        #expect(changes.value == 1, "_modify reports the change")
    }

    // MARK: Registrar

    @Test func unobservedWritesSkipTheObserverTable() {
        let subject = Subject()
        let changes = Counter()
        let (_, accesses) = ObservationTracking.record {
            subject.registrar.access(subject, propertyIndex: 3)
            subject.registrar.access(subject, propertyIndex: 70)
        }
        #expect(accesses.entries.first?.mask == 1 << 3)
        #expect(accesses.entries.first?.highIndices == [70])
        let listener = ObservationTracking.Listener(coalescing: false) { changes.increment() }
        listener.track {
            subject.registrar.access(subject, propertyIndex: 3)
            subject.registrar.access(subject, propertyIndex: 70)
        }
        subject.registrar.willSet(subject, propertyIndex: 4)
        subject.registrar.willSet(subject, propertyIndex: 71)
        #expect(changes.value == 0)
        subject.registrar.willSet(subject, propertyIndex: 3)
        subject.registrar.willSet(subject, propertyIndex: 70)
        #expect(changes.value == 2, "both paths")
        listener.cancel()
        #expect(subject.registrar.observerCount == 0)
    }

    // MARK: Listener

    @Test func listenerCoalescesUntilTrackedAgain() {
        let model = Model()
        let changes = Counter()
        let listener = ObservationTracking.Listener { changes.increment() }
        #expect(listener.track { model.name } == "a")
        model.name = "b"
        model.name = "c"
        #expect(changes.value == 1)
        #expect(listener.hasPendingChange)
        _ = listener.track { model.count }
        #expect(!listener.hasPendingChange)
        model.name = "d"
        #expect(changes.value == 1, "the new track doesn't read name")
        model.count = 2
        #expect(changes.value == 2)
    }

    @Test func listenerWithoutCoalescingFiresEveryTime() {
        let model = Model()
        let changes = Counter()
        let listener = ObservationTracking.Listener(coalescing: false) { changes.increment() }
        _ = listener.track { model.name }
        model.name = "b"
        model.name = "c"
        #expect(changes.value == 2)
    }

    @Test func releasedModelsLeaveNoObservers() {
        let changes = Counter()
        let listener = ObservationTracking.Listener { changes.increment() }
        do {
            let model = Model()
            _ = listener.track { model.name }
        }
        // The model's registrar removed itself from the listener, which
        // would otherwise reach a freed registrar here.
        listener.cancel()
        #expect(changes.value == 0)
    }

    // MARK: Bindings

    @Test func bindingsReadAndWriteThroughTheModel() {
        let model = Model()
        let name = model._$bindings.name
        #expect(name.wrappedValue == "a")
        name.wrappedValue = "z"
        #expect(model.name == "z")
        #expect(Binding.constant(3).wrappedValue == 3)
    }

    // MARK: Macro expansion

    static let macros: [String: any Macro.Type] = [
        "Observable": ObservableMacro.self,
        "ObservationTracked": ObservationTrackedMacro.self,
        "ObservationIgnored": ObservationIgnoredMacro.self,
    ]

    func expand(_ source: String) -> (source: String, diagnostics: [String]) {
        let file = Parser.parse(source: source)
        let context = BasicMacroExpansionContext(sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])
        let expanded = file.expand(macros: Self.macros, in: context)
        return (expanded.description, context.diagnostics.map(\.message))
    }

    @Test func expansionAssignsIndicesInOrder() {
        let (source, diagnostics) = expand("""
            @Observable
            public final class Model {
                var name: String = ""
                @ObservationIgnored var cache = 0
                var count = 0
                static var shared = 0
                let id = 1
            }
            """)
        #expect(diagnostics.isEmpty)
        // Compared without whitespace, so formatting doesn't matter.
        let compact = source.filter { !$0.isWhitespace }
        func has(_ fragment: String) -> Bool {
            compact.contains(fragment.filter { !$0.isWhitespace })
        }
        #expect(has("get { access(propertyIndex: 0) return _name }"))
        #expect(has("get { access(propertyIndex: 1) return _count }"))
        #expect(has("private var _name: String = \"\""))
        #expect(has("var cache = 0"), "ignored properties keep their storage")
        #expect(!has("_cache"))
        #expect(has("@storageRestrictions(initializes: _count)"))
        #expect(has("static var shared = 0"))
        #expect(has("public var name: Binding<String>"))
        #expect(!has("var count: Binding"), "no binding without a type annotation")
        // The conformance extension is checked by compiling `Model` above:
        // this harness passes no conformances to extension macros.
    }

    @Test func expansionRejectsNonClasses() {
        let (_, diagnostics) = expand("""
            @Observable
            struct Value {
                var a = 0
            }
            """)
        #expect(diagnostics == ["@Observable applies to classes"])
    }
}
