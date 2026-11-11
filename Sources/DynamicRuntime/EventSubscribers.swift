#if !EMBEDDED_NO_CONCURRENCY

/// The streams subscribed to one kind of delegate event, for async wrappers
/// that let several consumers watch the same events (state changes, for
/// example). Each subscriber removes itself in its stream's
/// `onTermination`:
///
/// ```swift
/// let (stream, continuation) = EventStream<State, Never>.makeStream()
/// let id = subscribers.add(continuation)
/// continuation.onTermination = { subscribers.remove(id) }
/// ```
///
/// A class, so finishing subscribers kept in a property doesn't hold an
/// access to it while their `onTermination` handlers remove themselves. The
/// guest is single-threaded (§6.4).
public final class EventSubscribers<Element, Failure: Error> {

    private var entries: [(id: Int, target: AnyObject?, continuation: EventStream<Element, Failure>.Continuation)] = []

    private var nextID = 0

    public init() { }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var count: Int {
        entries.count
    }

    /// Adds a subscriber, optionally to the events about one object (a
    /// characteristic, a sensor); returns the ID to remove it with.
    public func add(_ continuation: EventStream<Element, Failure>.Continuation, for target: AnyObject? = nil) -> Int {
        let id = nextID
        nextID &+= 1
        entries.append((id, target, continuation))
        return id
    }

    public func remove(_ id: Int) {
        entries.removeAll { $0.id == id }
    }

    /// Whether anyone subscribes to the events about `target`.
    public func contains(_ target: AnyObject?) -> Bool {
        entries.contains { Self.matches($0.target, target) }
    }

    /// Delivers an element to the subscribers for `target` (`nil`: the
    /// subscribers not tied to an object).
    public func yield(_ element: Element, for target: AnyObject? = nil) {
        for entry in entries where Self.matches(entry.target, target) {
            entry.continuation.yield(element)
        }
    }

    /// Finishes the streams of the subscribers for `target`.
    public func finish(for target: AnyObject?, throwing error: Failure? = nil) {
        let finishing = entries.filter { Self.matches($0.target, target) }
        entries.removeAll { Self.matches($0.target, target) }
        for entry in finishing {
            entry.continuation.finish(throwing: error)
        }
    }

    /// Finishes every subscriber's stream.
    public func finishAll(throwing error: Failure? = nil) {
        let entries = self.entries
        self.entries = []
        for entry in entries {
            entry.continuation.finish(throwing: error)
        }
    }

    private static func matches(_ a: AnyObject?, _ b: AnyObject?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            return DynamicObject.same(a, b)
        default:
            return false
        }
    }
}
#endif
