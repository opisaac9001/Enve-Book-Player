import Foundation
import Testing

@testable import enve

@MainActor
struct PerBookSerialQueueTests {
    @Test func operationsForTheSameBookRunInSubmissionOrderExactlyOnce() async {
        let queue = PerBookSerialQueue()
        var events: [String] = []

        let first = Task { @MainActor in
            await queue.enqueue(bookId: "book") {
                events.append("first-start")
                try? await Task.sleep(for: .milliseconds(20))
                events.append("first-end")
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            await queue.enqueue(bookId: "book") {
                events.append("second-start")
                events.append("second-end")
            }
        }

        await first.value
        await second.value

        #expect(events == ["first-start", "first-end", "second-start", "second-end"])
    }

    @Test func differentBooksDoNotBlockEachOther() async {
        let queue = PerBookSerialQueue()
        var secondBookRan = false

        let first = Task { @MainActor in
            await queue.enqueue(bookId: "first") {
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        await Task.yield()
        await queue.enqueue(bookId: "second") {
            secondBookRan = true
        }

        #expect(secondBookRan)
        await first.value
    }

    @Test(.timeLimit(.minutes(1)))
    func retiredWaitersNeverStartWhenTheirPredecessorIgnoresCancellation() async {
        let queue = PerBookSerialQueue()
        let gate = UncancellableGate()
        var events: [String] = []

        let first = Task { @MainActor in
            await queue.enqueue(bookId: "book") {
                events.append("first-start")
                await gate.wait()
                events.append("first-end")
            }
        }
        while !gate.isWaiting { await Task.yield() }
        var submitted = 0
        let second = Task { @MainActor in
            submitted += 1
            await queue.enqueue(bookId: "book") { events.append("second") }
        }
        let third = Task { @MainActor in
            submitted += 1
            await queue.enqueue(bookId: "book") { events.append("third") }
        }
        while submitted < 2 { await Task.yield() }
        var retiring = false
        let retirement = Task { @MainActor in
            retiring = true
            await queue.retire()
        }
        while !retiring { await Task.yield() }

        gate.release()
        await retirement.value
        await first.value
        await second.value
        await third.value

        #expect(events == ["first-start", "first-end"])
    }
}

@MainActor
private final class UncancellableGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
