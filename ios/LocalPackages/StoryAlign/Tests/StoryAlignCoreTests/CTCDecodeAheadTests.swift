import XCTest
@testable import StoryAlignCore

private actor DecodeProbe {
    private var loads: [Int] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var stopped = false

    func loaded(_ value: Int) {
        loads.append(value)
        let ready = waiters.filter { $0.0 <= loads.count }
        waiters.removeAll { $0.0 <= loads.count }
        for waiter in ready { waiter.1.resume() }
    }

    func waitForLoads(_ count: Int) async {
        if loads.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func loadCount() -> Int { loads.count }
    func markStopped() { stopped = true }
}

final class CTCDecodeAheadTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Error { case consumer }

    func testProducerNeverGetsMoreThanOneWindowAhead() async throws {
        let probe = DecodeProbe()
        let inputs = Array(0..<5)
        try await CTCDecodeAhead.forEach(inputs: inputs, load: { value in
            await probe.loaded(value)
            return value
        }, consume: { input, output in
            XCTAssertEqual(input, output)
            await probe.waitForLoads(min(input + 2, inputs.count))
            let count = await probe.loadCount()
            XCTAssertEqual(count, min(input + 2, inputs.count))
        })
    }

    func testConsumerFailureCancelsAndJoinsPendingDecode() async throws {
        let probe = DecodeProbe()
        do {
            try await CTCDecodeAhead.forEach(inputs: [0, 1, 2], load: { value in
                await probe.loaded(value)
                if value == 1 {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch {
                        await probe.markStopped()
                        throw error
                    }
                }
                return value
            }, consume: { _, _ in
                await probe.waitForLoads(2)
                throw Failure.consumer
            })
            XCTFail("The consumer error must propagate")
        } catch Failure.consumer {
            let stopped = await probe.stopped
            XCTAssertTrue(stopped)
            let count = await probe.loadCount()
            XCTAssertEqual(count, 2)
        }
    }

    func testCancellationJoinsActiveDecode() async throws {
        let probe = DecodeProbe()
        let task = Task {
            try await CTCDecodeAhead.forEach(inputs: [0, 1], load: { value in
                await probe.loaded(value)
                do { try await Task.sleep(for: .seconds(60)) }
                catch {
                    await probe.markStopped()
                    throw error
                }
                return value
            }, consume: { _, _ in XCTFail("Cancelled audio must not be consumed") })
        }
        await probe.waitForLoads(1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            let stopped = await probe.stopped
            XCTAssertTrue(stopped)
        }
    }
}
