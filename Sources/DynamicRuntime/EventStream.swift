#if !EMBEDDED_NO_CONCURRENCY
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// An async sequence of delegate events, with a typed failure (§6.2.1).
///
/// The async wrappers over provider contracts return these for event
/// sequences: scan results, location updates, sensor samples. A delegate
/// yields into the stream's continuation; the consumer iterates with
/// `for try await`.
///
/// It plays the part of `AsyncThrowingStream`, which Embedded Swift can't
/// use: that stream's failure is always `any Error`, and Embedded Swift
/// has no `any Error` values.
///
/// One consumer. `onTermination` runs once, when the stream finishes, when
/// the consuming task is cancelled, or when the stream and its iterator are
/// released, so a wrapper can stop the work behind it there. The guest is
/// single-threaded (§6.4), so a stream can be handed to another task.
public struct EventStream<Element, Failure: Error>: AsyncSequence, @unchecked Sendable {

    public typealias AsyncIterator = Iterator

    let storage: Storage

    /// Released with the stream and its iterator; terminates the stream.
    let consumer: Consumer

    /// How many undelivered elements the stream keeps.
    public enum Buffering: Sendable {
        /// Every element.
        case unbounded
        /// The newest `count` elements, dropping older ones: for samples
        /// where only recent ones matter.
        case newest(Int)
    }

    /// Creates a stream; `build` gets the continuation to yield into.
    public init(buffering: Buffering = .unbounded, _ build: (Continuation) -> Void) {
        let storage = Storage(buffering: buffering)
        self.storage = storage
        self.consumer = Consumer(storage)
        build(Continuation(storage: storage))
    }

    /// Creates a stream and returns its continuation.
    public static func makeStream(buffering: Buffering = .unbounded) -> (stream: Self, continuation: Continuation) {
        var continuation: Continuation?
        let stream = Self(buffering: buffering) { continuation = $0 }
        return (stream, continuation!)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(storage: storage, consumer: consumer)
    }

    public struct Iterator: AsyncIteratorProtocol {

        let storage: Storage

        let consumer: Consumer

        /// The next element; `nil` once the stream has finished or the task
        /// is cancelled. Throws the failure the stream finished with, once.
        public mutating func next() async throws(Failure) -> Element? {
            try await storage.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Element? {
            try await storage.next()
        }
    }

    /// The producer side, held by the delegate that feeds the stream. A
    /// class, so finishing a stream kept in a property doesn't hold an
    /// access to that property while `onTermination` runs (which often
    /// clears it).
    public final class Continuation: @unchecked Sendable {

        let storage: Storage

        init(storage: Storage) {
            self.storage = storage
        }

        /// Delivers an element. Ignored after the stream finished.
        public func yield(_ element: Element) {
            storage.yield(element)
        }

        /// Ends the stream, throwing `error` to the consumer if given.
        public func finish(throwing error: Failure? = nil) {
            storage.finish(error)
        }

        /// Whether the stream has finished, so further elements are ignored.
        public var isFinished: Bool {
            storage.isFinished
        }

        /// Runs once when the stream terminates for any reason; at once if
        /// it already has.
        public var onTermination: (() -> Void)? {
            get { storage.onTermination }
            set { storage.onTermination = newValue }
        }
    }

    final class Consumer: @unchecked Sendable {

        let storage: Storage

        init(_ storage: Storage) {
            self.storage = storage
        }

        deinit {
            storage.finish(nil)
        }
    }

    final class Storage: @unchecked Sendable {

        private let buffering: Buffering

        private var elements: [Element] = []

        private var head = 0

        private var finished = false

        private var failure: Failure?

        private var waiting: UnsafeContinuation<Transfer<Result<Element?, Failure>>, Never>?

        private var terminationHandler: (() -> Void)?

        var onTermination: (() -> Void)? {
            get { terminationHandler }
            set {
                if finished {
                    terminationHandler = nil
                    newValue?()
                } else {
                    terminationHandler = newValue
                }
            }
        }

        init(buffering: Buffering) {
            self.buffering = buffering
        }

        var isFinished: Bool {
            finished
        }

        func yield(_ element: Element) {
            guard !finished else { return }
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: Transfer(.success(element)))
                return
            }
            elements.append(element)
            if case .newest(let limit) = buffering, elements.count - head > Swift.max(limit, 0) {
                head += 1
            }
            compact()
        }

        func finish(_ error: Failure?) {
            guard !finished else { return }
            finished = true
            failure = error
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: Transfer(takeEnd()))
            }
            let handler = terminationHandler
            terminationHandler = nil
            handler?()
        }

        func next() async throws(Failure) -> Element? {
            if head < elements.count {
                let element = elements[head]
                head += 1
                compact()
                return element
            }
            if finished {
                return try takeEnd().get()
            }
            let result = await withTaskCancellationHandler {
                await withUnsafeContinuation { (continuation: UnsafeContinuation<Transfer<Result<Element?, Failure>>, Never>) in
                    if finished || Task.isCancelled {
                        finished = true
                        continuation.resume(returning: Transfer(takeEnd()))
                    } else {
                        waiting = continuation
                    }
                }
            } onCancel: {
                self.finish(nil)
            }
            return try result.value.get()
        }

        /// The end of the stream: its failure the first time, then `nil`.
        private func takeEnd() -> Result<Element?, Failure> {
            guard let failure else { return .success(nil) }
            self.failure = nil
            return .failure(failure)
        }

        private func compact() {
            if head > 32, head * 2 > elements.count {
                elements.removeFirst(head)
                head = 0
            }
        }
    }
}
#endif
