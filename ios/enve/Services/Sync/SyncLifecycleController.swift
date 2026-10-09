import Combine
import Foundation

#if os(iOS)
import AVFoundation
import UIKit
#endif

struct SyncLifecycleEvents {
    let didEnterBackground: Notification.Name
    let willTerminate: Notification.Name
    let willEnterForeground: Notification.Name
    let audioInterruption: Notification.Name?

    #if os(iOS)
    static let application = SyncLifecycleEvents(
        didEnterBackground: UIApplication.didEnterBackgroundNotification,
        willTerminate: UIApplication.willTerminateNotification,
        willEnterForeground: UIApplication.willEnterForegroundNotification,
        audioInterruption: AVAudioSession.interruptionNotification
    )
    #endif
}

@MainActor
final class SyncLifecycleController {
    private let center: NotificationCenter
    private let events: SyncLifecycleEvents
    private let save: @MainActor @Sendable (ProgressSaveReason) async -> Void
    private let enterForeground: @MainActor @Sendable () async -> Void
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var isRetired = false
    private var cancellables = Set<AnyCancellable>()

    init(
        center: NotificationCenter = .default,
        events: SyncLifecycleEvents,
        save: @escaping @MainActor @Sendable (ProgressSaveReason) async -> Void,
        enterForeground: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.center = center
        self.events = events
        self.save = save
        self.enterForeground = enterForeground
    }

    func start() {
        guard !isRetired, cancellables.isEmpty else { return }

        center.publisher(for: events.didEnterBackground)
            .sink { [weak self, save] _ in
                Task { @MainActor in self?.enqueue { await save(.appBackground) } }
            }
            .store(in: &cancellables)

        center.publisher(for: events.willTerminate)
            .sink { [weak self, save] _ in
                Task { @MainActor in self?.enqueue { await save(.appTermination) } }
            }
            .store(in: &cancellables)

        center.publisher(for: events.willEnterForeground)
            .sink { [weak self, enterForeground] _ in
                Task { @MainActor in self?.enqueue { await enterForeground() } }
            }
            .store(in: &cancellables)

        #if os(iOS)
        if let audioInterruption = events.audioInterruption {
            center.publisher(for: audioInterruption)
                .sink { [weak self, save] notification in
                    guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        AVAudioSession.InterruptionType(rawValue: typeValue) == .began
                    else {
                        return
                    }
                    Task { @MainActor in self?.enqueue { await save(.audioInterruption) } }
                }
                .store(in: &cancellables)
        }
        #endif
    }

    private func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        guard !isRetired else { return }
        let id = UUID()
        operations[id] = Task {
            await operation()
            self.operations[id] = nil
        }
    }

    func retire() async {
        isRetired = true
        stop()
        let pending = Array(operations.values)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }

    func stop() {
        cancellables.removeAll()
    }
}
