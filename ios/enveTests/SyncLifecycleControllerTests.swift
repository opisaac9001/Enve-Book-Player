import Foundation
import Testing

@testable import enve

@MainActor
private final class SyncLifecycleRecorder {
    var saves: [ProgressSaveReason] = []
    var foregroundCount = 0
}

@MainActor
struct SyncLifecycleControllerTests {
    @Test(.timeLimit(.minutes(1))) func routesApplicationEventsToSyncActions() async throws {
        let center = NotificationCenter()
        let events = SyncLifecycleEvents(
            didEnterBackground: Notification.Name("test.background"),
            willTerminate: Notification.Name("test.terminate"),
            willEnterForeground: Notification.Name("test.foreground"),
            audioInterruption: nil
        )
        let recorder = SyncLifecycleRecorder()
        let (observedEvents, continuation) = AsyncStream.makeStream(of: Void.self)
        defer { continuation.finish() }
        let controller = SyncLifecycleController(
            center: center,
            events: events,
            save: { recorder.saves.append($0); continuation.yield(()) },
            enterForeground: { recorder.foregroundCount += 1; continuation.yield(()) }
        )
        controller.start()
        defer { controller.stop() }

        center.post(name: events.didEnterBackground, object: nil)
        center.post(name: events.willTerminate, object: nil)
        center.post(name: events.willEnterForeground, object: nil)
        for await _ in observedEvents.prefix(3) {}

        #expect(recorder.saves == [.appBackground, .appTermination])
        #expect(recorder.foregroundCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func startIsIdempotentAndStopRemovesObservers() async throws {
        let center = NotificationCenter()
        let events = SyncLifecycleEvents(
            didEnterBackground: Notification.Name("test.background"),
            willTerminate: Notification.Name("test.terminate"),
            willEnterForeground: Notification.Name("test.foreground"),
            audioInterruption: nil
        )
        let recorder = SyncLifecycleRecorder()
        let (observedEvents, continuation) = AsyncStream.makeStream(of: Void.self)
        defer { continuation.finish() }
        let controller = SyncLifecycleController(
            center: center,
            events: events,
            save: { recorder.saves.append($0); continuation.yield(()) },
            enterForeground: { recorder.foregroundCount += 1; continuation.yield(()) }
        )
        controller.start()
        controller.start()
        center.post(name: events.didEnterBackground, object: nil)
        for await _ in observedEvents.prefix(1) {}
        controller.stop()
        center.post(name: events.didEnterBackground, object: nil)
        await Task.yield()

        #expect(recorder.saves == [.appBackground])
    }
}
