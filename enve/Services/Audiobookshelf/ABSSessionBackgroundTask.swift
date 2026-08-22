import BackgroundTasks
import Foundation
import Logging

@MainActor
final class ABSSessionBackgroundTask {
    static let shared = ABSSessionBackgroundTask()

    private let taskIdentifier = "com.enve.enve.abs-session-close"

    private let inactivityTimeout: TimeInterval = 10 * 60

    private let sessionIDKey = "absActiveSessionIDForBGTask"
    private let retryCountKey = "absSessionCloseRetryCount"

    private var inactivityTask: Task<Void, Never>?

    private init() {}

    nonisolated func registerHandler() {
        let success = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            nonisolated(unsafe) let bgTask = task

            let playbackRate = NowPlayingCoordinator.currentPlaybackRate()

            if playbackRate > 0 {
                Task { @MainActor in
                    ABSSessionBackgroundTask.shared.rescheduleIfNeeded()
                }
                bgTask.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                await ABSSessionBackgroundTask.shared.closeSessionFromBackground()
                bgTask.setTaskCompleted(success: true)
            }
        }
        if success {
            AppLogger.sync.info("Registered background task handler: \(taskIdentifier)")
        } else {
            AppLogger.sync.error("Failed to register background task handler (may already be registered)")
        }
    }

    func scheduleSessionClose(sessionId: String) {
        UserDefaults.standard.set(sessionId, forKey: sessionIDKey)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: inactivityTimeout)

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.warning("Scheduled session close for \(sessionId) in \(Int(inactivityTimeout))s")
        } catch let error as NSError {
            if error.code == 1 {
                AppLogger.sync.info("Background tasks unavailable (Background App Refresh may be disabled)")
            } else {
                AppLogger.sync.error("Failed to schedule background task: \(error)")
            }
        }

        startInactivityTask(sessionId: sessionId)
    }

    func cancelScheduledClose() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        UserDefaults.standard.removeObject(forKey: sessionIDKey)
        UserDefaults.standard.set(0, forKey: retryCountKey)
        cancelInactivityTask()
        AppLogger.sync.info("Cancelled scheduled session close")
    }

    func rescheduleIfNeeded() {
        if let sessionId = UserDefaults.standard.string(forKey: sessionIDKey) {
            AppLogger.sync.info("Rescheduling session close (playback still active)")
            scheduleSessionClose(sessionId: sessionId)
        }
    }

    private func startInactivityTask(sessionId: String) {
        cancelInactivityTask()

        inactivityTask = Task {
            do {
                try await Task.sleep(for: .seconds(inactivityTimeout))

                guard !Task.isCancelled else { return }

                let playbackRate = NowPlayingCoordinator.currentPlaybackRate()

                if playbackRate > 0 {
                    AppLogger.sync.warning("Inactivity timeout but playback active - not closing")
                    return
                }

                AppLogger.sync.warning("Inactivity timeout reached - closing session")
                await closeSessionFromBackground()
            } catch is CancellationError {
            } catch {
                AppLogger.sync.debug("Inactivity task ended unexpectedly: \(error.localizedDescription)")
            }
        }
    }

    private func cancelInactivityTask() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    func closeSessionFromBackground() async {
        let playerVM = PlayerViewModel.shared
        await playerVM.closeABSSessionFromBackground()

        UserDefaults.standard.removeObject(forKey: sessionIDKey)
        UserDefaults.standard.set(0, forKey: retryCountKey)
    }
}
