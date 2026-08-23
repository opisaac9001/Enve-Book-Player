import Foundation
import Logging

#if os(iOS)
import UIKit
#endif

enum ProgressSaveReason: String {
    case playbackPaused = "Playback Paused"
    case appBackground = "App Background"
    case appTermination = "App Termination"
    case audioInterruption = "Audio Interruption"
    case timerInterval = "Timer Interval"
    case manualSave = "Manual Save"
    case playbackCompleted = "Playback Completed"
}

@MainActor
final class CurrentPlaybackPersister {
    static let shared = CurrentPlaybackPersister()

    private let playbackState: any PlaybackStateProvider = ActivePlayback.controller

    private let minimumCloudSyncInterval: TimeInterval = 10
    private var lastCloudSaveTime: Date?

    private init() {}

    @discardableResult
    func saveCurrent(reason: ProgressSaveReason) async -> Bool {
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled else { return false }
        guard coordinator.isCloudKitAvailable else {
            AppLogger.sync.warning("CloudKit not available, skipping save")
            return false
        }

        if let lastSave = lastCloudSaveTime, Date().timeIntervalSince(lastSave) < minimumCloudSyncInterval {
            if reason != .appBackground && reason != .appTermination && reason != .playbackPaused {
                AppLogger.sync.info("Throttling iCloud save (\(reason.rawValue))")
                return false
            }
        }

        guard let currentBook = currentPlayingBook(),
            playbackState.snapshot.isLoaded,
            currentBook.mediaType == .audiobook,
            !isActiveReadAloudPlayback(currentBook),
            let currentPosition = currentPosition(),
            currentPosition > 0
        else {
            return false
        }

        AppLogger.sync.debug(
            "Saving progress reason=\(reason.rawValue) bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: currentBook.stableId)) positionSeconds=\(Int(currentPosition))"
        )

        let saved = await SyncCoordinator.shared.persistCurrentPlayback(
            book: currentBook,
            position: currentPosition,
            playbackRate: currentRate(),
            isFinished: isCompleted(book: currentBook, position: currentPosition)
        )
        if saved {
            lastCloudSaveTime = Date()
            coordinator.markSynced(deviceName: deviceName())
        }
        return saved
    }

    func save(for book: Book, position: TimeInterval, playbackRate: Double = 1.0) async {
        guard book.mediaType == .audiobook else { return }
        guard !isActiveReadAloudPlayback(book) else { return }
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled else { return }
        guard coordinator.isCloudKitAvailable else { return }
        guard position > 0 else { return }

        if let lastSave = lastCloudSaveTime, Date().timeIntervalSince(lastSave) < minimumCloudSyncInterval {
            return
        }

        AppLogger.sync.debug(
            "Saving progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) positionSeconds=\(Int(position))"
        )

        let saved = await SyncCoordinator.shared.persistCurrentPlayback(
            book: book,
            position: position,
            playbackRate: playbackRate,
            isFinished: isCompleted(book: book, position: position)
        )
        if saved {
            lastCloudSaveTime = Date()
            coordinator.markSynced(deviceName: deviceName())
        }
    }

    private func currentPlayingBook() -> Book? {
        playbackState.currentBook
    }

    private func isActiveReadAloudPlayback(_ book: Book) -> Bool {
        let snapshot = playbackState.snapshot
        guard snapshot.isOverlayPlaybackActive,
            let current = snapshot.currentBook
        else { return false }
        return current.uniqueId == book.uniqueId
    }

    private func currentPosition() -> TimeInterval? {
        let position = playbackState.progress
        return position > 0 ? position : nil
    }

    private func currentRate() -> Double {
        playbackState.playbackSpeed
    }

    private func isCompleted(book: Book, position: TimeInterval) -> Bool {
        guard let duration = book.duration, duration > 0 else { return false }
        return position / duration >= 0.99
    }

    private func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return "Mac"
        #endif
    }
}
