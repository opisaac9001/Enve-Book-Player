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
    @Test func routesApplicationEventsToSyncActions() async throws {
        let center = NotificationCenter()
        let events = SyncLifecycleEvents(
            didEnterBackground: Notification.Name("test.background"),
            willTerminate: Notification.Name("test.terminate"),
            willEnterForeground: Notification.Name("test.foreground"),
            audioInterruption: nil
        )
        let recorder = SyncLifecycleRecorder()
        let controller = SyncLifecycleController(
            center: center,
            events: events,
            save: { recorder.saves.append($0) },
            enterForeground: { recorder.foregroundCount += 1 }
        )
        controller.start()

        center.post(name: events.didEnterBackground, object: nil)
        center.post(name: events.willTerminate, object: nil)
        center.post(name: events.willEnterForeground, object: nil)
        try await Task.sleep(for: .milliseconds(20))

        #expect(recorder.saves == [.appBackground, .appTermination])
        #expect(recorder.foregroundCount == 1)
    }

    @Test func startIsIdempotentAndStopRemovesObservers() async throws {
        let center = NotificationCenter()
        let events = SyncLifecycleEvents(
            didEnterBackground: Notification.Name("test.background"),
            willTerminate: Notification.Name("test.terminate"),
            willEnterForeground: Notification.Name("test.foreground"),
            audioInterruption: nil
        )
        let recorder = SyncLifecycleRecorder()
        let controller = SyncLifecycleController(
            center: center,
            events: events,
            save: { recorder.saves.append($0) },
            enterForeground: { recorder.foregroundCount += 1 }
        )
        controller.start()
        controller.start()
        center.post(name: events.didEnterBackground, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        controller.stop()
        center.post(name: events.didEnterBackground, object: nil)
        try await Task.sleep(for: .milliseconds(20))

        #expect(recorder.saves == [.appBackground])
    }
}
