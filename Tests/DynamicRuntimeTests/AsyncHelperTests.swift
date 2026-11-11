import Testing
import DynamicRuntime

enum TestFailure: Error, Equatable {
    case broken
    case cancelled
}

/// `EventStream`, `withCallback`, `PendingCallbacks` and `EventSubscribers`:
/// the pieces the async wrappers over provider contracts are built from.
@Suite struct AsyncHelperTests {

    // MARK: EventStream

    @Test func streamDeliversBufferedElementsInOrder() async throws {
        let (stream, continuation) = EventStream<Int, TestFailure>.makeStream()
        for value in 1...3 {
            continuation.yield(value)
        }
        continuation.finish()
        continuation.yield(4)
        var values: [Int] = []
        for try await value in stream {
            values.append(value)
        }
        #expect(values == [1, 2, 3], "nothing after finish")
    }

    @Test func newestBufferingDropsTheOldest() async throws {
        let (stream, continuation) = EventStream<Int, TestFailure>.makeStream(buffering: .newest(2))
        for value in 1...5 {
            continuation.yield(value)
        }
        continuation.finish()
        var values: [Int] = []
        for try await value in stream {
            values.append(value)
        }
        #expect(values == [4, 5])
    }

    @Test func failureIsThrownOnceAfterTheBuffer() async {
        let (stream, continuation) = EventStream<Int, TestFailure>.makeStream()
        continuation.yield(1)
        continuation.finish(throwing: .broken)
        var iterator = stream.makeAsyncIterator()
        #expect(try! await iterator.next() == 1)
        await #expect(throws: TestFailure.broken) {
            _ = try await iterator.next()
        }
        #expect(try! await iterator.next() == nil)
    }

    @Test func terminationRunsOnceWhenFinished() {
        let (_, continuation) = EventStream<Int, Never>.makeStream()
        var terminations = 0
        continuation.onTermination = { terminations += 1 }
        continuation.finish()
        continuation.finish()
        #expect(terminations == 1)
        #expect(continuation.isFinished)
    }

    @Test func releasingTheStreamTerminatesIt() {
        var terminations = 0
        var continuation: EventStream<Int, Never>.Continuation?
        do {
            let stream = EventStream<Int, Never> { continuation = $0 }
            continuation?.onTermination = { terminations += 1 }
            _ = stream
        }
        #expect(terminations == 1, "the consumer went away")
        #expect(continuation?.isFinished == true)
    }

    @Test func cancellingTheConsumerEndsTheStream() async {
        let (stream, continuation) = EventStream<Int, Never>.makeStream()
        var terminations = 0
        continuation.onTermination = { terminations += 1 }
        let task = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }
        task.cancel()
        #expect(await task.value == 0)
        #expect(terminations == 1)
    }

    // MARK: withCallback

    @Test func callbackResumedDuringStart() async throws {
        let value = try await withCallback { (callback: Callback<Int, TestFailure>) in
            callback.resume(returning: 7)
            callback.resume(returning: 8)
        } onCancel: { _ in }
        #expect(value == 7, "the first resume wins")
    }

    /// State shared between a test and the task it starts. Each test reads
    /// it only while the task is suspended.
    final class Shared<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    final class Target: @unchecked Sendable { }

    @Test func callbackResumedLater() async {
        let pending = Shared(PendingCallbacks<Int, TestFailure>())
        let task = Task {
            try await withCallback { (callback: Callback<Int, TestFailure>) in
                pending.value.append(callback)
            } onCancel: { _ in }
        }
        while pending.value.isEmpty {
            await Task.yield()
        }
        pending.value.resume(with: .failure(.broken))
        await #expect(throws: TestFailure.broken) {
            _ = try await task.value
        }
    }

    @Test func cancellationRunsTheHandler() async {
        let pending = Shared(PendingCallbacks<Int, TestFailure>())
        let cancelled = Shared(false)
        let task = Task {
            try await withCallback { (callback: Callback<Int, TestFailure>) in
                pending.value.append(callback)
            } onCancel: { callback in
                cancelled.value = true
                callback.resume(throwing: .cancelled)
            }
        }
        while pending.value.isEmpty {
            await Task.yield()
        }
        task.cancel()
        await #expect(throws: TestFailure.cancelled) {
            _ = try await task.value
        }
        #expect(cancelled.value)
        // The late native result goes to the cancelled callback, not a later one.
        let resumed1 = pending.value.resume(with: .success(1))
        #expect(resumed1)
        #expect(pending.value.isEmpty)
    }

    // MARK: PendingCallbacks and EventSubscribers

    @Test func pendingCallbacksMatchTargetsInOrder() async throws {
        let pending = Shared(PendingCallbacks<String, TestFailure>())
        let a = Target(), b = Target()
        func wait(for target: Target) async -> Task<String, any Error> {
            let count = pending.value.count
            let task = Task {
                try await withCallback { (callback: Callback<String, TestFailure>) in
                    pending.value.append(callback, for: target)
                } onCancel: { _ in }
            }
            while pending.value.count == count {
                await Task.yield()
            }
            return task
        }
        let first = await wait(for: a)
        let second = await wait(for: a)
        let other = await wait(for: b)
        let resumed2 = pending.value.resume(for: b, with: .success("b"))
        #expect(resumed2)
        let resumed3 = pending.value.resume(for: a, with: .success("first"))
        #expect(resumed3)
        pending.value.failAll(.broken)
        #expect(try await other.value == "b")
        #expect(try await first.value == "first", "the oldest callback for a")
        await #expect(throws: TestFailure.broken) {
            _ = try await second.value
        }
        let resumed4 = pending.value.resume(for: a, with: .success("none"))
        #expect(!resumed4)
    }

    @Test func subscribersFanOutPerTarget() async throws {
        var subscribers = EventSubscribers<Int, TestFailure>()
        let a = Target(), b = Target()
        let (streamA, continuationA) = EventStream<Int, TestFailure>.makeStream()
        let (streamAll, continuationAll) = EventStream<Int, TestFailure>.makeStream()
        let (streamB, continuationB) = EventStream<Int, TestFailure>.makeStream()
        _ = subscribers.add(continuationA, for: a)
        let idB = subscribers.add(continuationB, for: b)
        _ = subscribers.add(continuationAll)
        subscribers.yield(1, for: a)
        subscribers.yield(2)
        subscribers.yield(3, for: b)
        subscribers.remove(idB)
        subscribers.yield(4, for: b)
        #expect(subscribers.contains(a))
        #expect(!subscribers.contains(b))
        subscribers.finish(for: a, throwing: .broken)
        #expect(subscribers.count == 1)
        subscribers.finishAll()
        continuationB.finish()

        var iteratorA = streamA.makeAsyncIterator()
        #expect(try await iteratorA.next() == 1)
        await #expect(throws: TestFailure.broken) { _ = try await iteratorA.next() }
        var all: [Int] = []
        for try await value in streamAll { all.append(value) }
        #expect(all == [2])
        var onlyB: [Int] = []
        for try await value in streamB { onlyB.append(value) }
        #expect(onlyB == [3])
    }
}
