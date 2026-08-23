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
        guard cancellables.isEmpty else { return }

        center.publisher(for: events.didEnterBackground)
            .sink { [save] _ in
                Task { @MainActor in await save(.appBackground) }
            }
            .store(in: &cancellables)

        center.publisher(for: events.willTerminate)
            .sink { [save] _ in
                Task { @MainActor in await save(.appTermination) }
            }
            .store(in: &cancellables)

        center.publisher(for: events.willEnterForeground)
            .sink { [enterForeground] _ in
                Task { @MainActor in await enterForeground() }
            }
            .store(in: &cancellables)

        #if os(iOS)
        if let audioInterruption = events.audioInterruption {
            center.publisher(for: audioInterruption)
                .sink { [save] notification in
                    guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        AVAudioSession.InterruptionType(rawValue: typeValue) == .began
                    else {
                        return
                    }
                    Task { @MainActor in await save(.audioInterruption) }
                }
                .store(in: &cancellables)
        }
        #endif
    }

    func stop() {
        cancellables.removeAll()
    }
}
