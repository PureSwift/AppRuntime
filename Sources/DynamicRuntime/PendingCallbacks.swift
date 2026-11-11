#if !EMBEDDED_NO_CONCURRENCY

/// Callbacks waiting for delegate events, matched to the object each one is
/// about: a peripheral, a characteristic, a tag.
///
/// Async wrappers keep one list per kind of request. A delegate event takes
/// the oldest callback for its object, so requests about the same object
/// complete in the order they were made, as the native APIs report them.
/// Objects are compared with `DynamicObject.same`, because handles aren't
/// unique per object.
///
/// A callback that was resumed early (its task was cancelled) stays in the
/// list until its event arrives, so later events still line up with later
/// requests.
///
/// A class, so resuming callbacks kept in a property never holds an access
/// to it while other code runs.
public final class PendingCallbacks<Value, Failure: Error> {

    private var entries: [(target: AnyObject?, callback: Callback<Value, Failure>)] = []

    public init() { }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var count: Int {
        entries.count
    }

    /// Adds a callback waiting on `target` (`nil`: not about any object).
    public func append(_ callback: Callback<Value, Failure>, for target: AnyObject? = nil) {
        entries.append((target, callback))
    }

    /// Removes and returns the oldest callback for `target`.
    public func take(for target: AnyObject? = nil) -> Callback<Value, Failure>? {
        guard let index = entries.firstIndex(where: { Self.matches($0.target, target) }) else {
            return nil
        }
        return entries.remove(at: index).callback
    }

    /// Whether a callback is waiting on `target`.
    public func contains(_ target: AnyObject? = nil) -> Bool {
        entries.contains { Self.matches($0.target, target) }
    }

    /// Resumes the oldest callback for `target` with `result`. Returns
    /// whether there was one.
    @discardableResult
    public func resume(for target: AnyObject? = nil, with result: Result<Value, Failure>) -> Bool {
        guard let callback = take(for: target) else { return false }
        callback.resume(with: result)
        return true
    }

    /// Fails every callback, for example when the connection is lost.
    public func failAll(_ error: Failure) {
        let entries = self.entries
        self.entries = []
        for entry in entries {
            entry.callback.resume(throwing: error)
        }
    }

    /// Resolves every callback with the same result.
    public func resumeAll(with result: Result<Value, Failure>) {
        let entries = self.entries
        self.entries = []
        for entry in entries {
            entry.callback.resume(with: result)
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
