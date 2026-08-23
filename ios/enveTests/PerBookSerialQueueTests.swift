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
}
