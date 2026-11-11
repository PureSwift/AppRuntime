/// Records reads of an observable object's properties and notifies observers
/// before they change (§5.3).
///
/// Properties are identified by index, assigned by `@Observable` in
/// declaration order. Observers of indices below 64 are summarized in a
/// 64-bit mask, so a write to a property nobody observes skips the observer
/// table. Higher indices take the slow path.
///
/// The guest is single-threaded (§6.4): no locks or atomics.
public final class ObservationRegistrar: @unchecked Sendable {

    struct Registration {
        let observer: Observer
        let mask: UInt64
        let highIndices: [Int]

        func matches(_ index: Int) -> Bool {
            index < 64 ? mask & (1 << UInt64(index)) != 0 : highIndices.contains(index)
        }
    }

    private var registrations: [Registration] = []

    /// Union of the registrations' masks.
    private var observedMask: UInt64 = 0

    /// Whether any registration watches an index of 64 or more.
    private var observesHighIndices = false

    public init() { }

    deinit {
        for registration in registrations {
            registration.observer.forget(self)
        }
    }

    /// A read of a property: recorded if tracking is in progress.
    public func access<Subject: Observable>(_ subject: Subject, propertyIndex: Int) {
        ObservationTracking.current?.record(self, propertyIndex)
    }

    /// A property is about to change: its observers are told now.
    public func willSet<Subject: Observable>(_ subject: Subject, propertyIndex: Int) {
        if propertyIndex < 64 {
            guard observedMask & (1 << UInt64(propertyIndex)) != 0 else { return }
        } else {
            guard observesHighIndices else { return }
        }
        let observers = registrations.filter { $0.matches(propertyIndex) }.map { $0.observer }
        for observer in observers {
            observer.changed()
        }
    }

    /// A property has changed. Observers were told in `willSet`.
    public func didSet<Subject: Observable>(_ subject: Subject, propertyIndex: Int) { }

    /// Wraps a change to a property in `willSet` and `didSet`.
    public func withMutation<Subject: Observable, Result, Failure: Error>(
        of subject: Subject,
        propertyIndex: Int,
        _ mutation: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        willSet(subject, propertyIndex: propertyIndex)
        defer { didSet(subject, propertyIndex: propertyIndex) }
        return try mutation()
    }

    // MARK: Observers

    func add(_ observer: Observer, mask: UInt64, highIndices: [Int]) {
        registrations.append(Registration(observer: observer, mask: mask, highIndices: highIndices))
        observedMask |= mask
        observesHighIndices = observesHighIndices || !highIndices.isEmpty
    }

    func remove(_ observer: Observer) {
        registrations.removeAll { $0.observer === observer }
        observedMask = 0
        observesHighIndices = false
        for registration in registrations {
            observedMask |= registration.mask
            observesHighIndices = observesHighIndices || !registration.highIndices.isEmpty
        }
    }

    /// Number of observers, for tests.
    var observerCount: Int {
        registrations.count
    }
}

/// One `withObservationTracking` call or listener, registered with every
/// registrar it read from. Registrars hold observers; an observer refers back
/// without owning them, and a registrar that goes away removes itself.
final class Observer {

    private struct Source {
        unowned(unsafe) let registrar: ObservationRegistrar
    }

    private let onChange: () -> Void

    /// Cancelled at the first change, as `withObservationTracking` is.
    private let oneShot: Bool

    private var sources: [Source] = []

    init(oneShot: Bool, onChange: @escaping () -> Void) {
        self.oneShot = oneShot
        self.onChange = onChange
    }

    func observe(_ accesses: AccessList) {
        for entry in accesses.entries {
            entry.registrar.add(self, mask: entry.mask, highIndices: entry.highIndices)
            sources.append(Source(registrar: entry.registrar))
        }
    }

    func changed() {
        if oneShot {
            cancel()
        }
        onChange()
    }

    func cancel() {
        let sources = self.sources
        self.sources = []
        for source in sources {
            source.registrar.remove(self)
        }
    }

    func forget(_ registrar: ObservationRegistrar) {
        sources.removeAll { $0.registrar === registrar }
    }
}
