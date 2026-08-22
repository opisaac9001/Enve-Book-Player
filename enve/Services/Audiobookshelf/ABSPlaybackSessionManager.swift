import Combine
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

enum ABSSyncStatus: Int {
    case idle = 0
    case syncing = 1
    case success = 2
    case failed = 3
}

struct ABSActiveSession: Codable {
    let sessionId: String
    let libraryItemId: String
    let episodeId: String?
    let backendId: String
    var currentTime: TimeInterval
    var duration: TimeInterval
    var timeListened: TimeInterval
    let startTime: TimeInterval
    let startedAt: Date
    var lastUpdated: Date
    var isClosed: Bool

    let deviceId: String
}

@MainActor
@Observable
final class ABSPlaybackSessionManager {
    static let shared = ABSPlaybackSessionManager()

    private(set) var activeSession: ABSActiveSession?
    private(set) var isSyncing = false
    private(set) var lastSyncTime: Date?
    private(set) var syncError: String?
    private(set) var syncStatus: ABSSyncStatus = .idle

    @ObservationIgnored private let playbackState: any PlaybackStateProvider = ActivePlayback.controller

    @ObservationIgnored private let service = AudiobookshelfService.shared
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    private let userDefaults = UserDefaults.standard

    private let syncIntervalSeconds: TimeInterval = 15
    private let minimumSyncInterval: TimeInterval = 5
    private var lastSyncAttempt: Date?

    @ObservationIgnored
    private lazy var deviceId: String = {
        let key = "absDeviceId"
        if let existing = userDefaults.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: key)
        return newId
    }()

    private let localSessionKey = "absLocalPlaybackSession"

    private init() {
        loadLocalSession()
        setupAppLifecycleObservers()
        AppLogger.player.info("[ABSSession] Manager initialized with deviceId: \(deviceId)")
    }

    func startSession(
        libraryItemId: String,
        episodeId: String? = nil,
        backend: BackendConfig,
        startTime: TimeInterval = 0
    ) async throws -> ABSPlaySession {
        AppLogger.player.info("[ABSSession] Starting session for item: \(libraryItemId)")

        await closeCurrentSession()

        let playSession = try await service.startPlaySession(
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            backend: backend,
            forceDirectPlay: true
        )

        guard let sessionId = playSession.id else {
            throw NSError(
                domain: "ABSPlaybackSessionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Server did not return a session ID"]
            )
        }

        let actualStartTime: TimeInterval
        if startTime > 0 {
            actualStartTime = startTime
        } else if let serverTime = playSession.currentTime, serverTime > 0 {
            actualStartTime = serverTime
        } else {
            actualStartTime = 0
        }

        let session = ABSActiveSession(
            sessionId: sessionId,
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            backendId: backend.id,
            currentTime: actualStartTime,
            duration: playSession.duration ?? 0,
            timeListened: 0,
            startTime: actualStartTime,
            startedAt: Date(),
            lastUpdated: Date(),
            isClosed: false,
            deviceId: deviceId
        )

        activeSession = session
        saveLocalSession()

        AppLogger.player.info("Session started: \(sessionId) at \(actualStartTime)s")

        startSyncTimer()

        return playSession
    }

    func startSession(
        libraryItemId: String,
        episodeId: String? = nil,
        backend: BackendConfig,
        startTime: TimeInterval = 0,
        forceDirectPlay: Bool = true,
        forceTranscode: Bool = false
    ) async throws -> ABSPlaySession {
        AppLogger.player.info(
            "[ABSSession] Starting session for item: \(libraryItemId) (direct: \(forceDirectPlay), transcode: \(forceTranscode))"
        )

        await closeCurrentSession()

        let playSession = try await service.startPlaySession(
            libraryItemId: libraryItemId,
            backend: backend,
            forceDirectPlay: forceDirectPlay,
            forceTranscode: forceTranscode
        )

        guard let sessionId = playSession.id else {
            throw NSError(
                domain: "ABSPlaybackSessionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Server did not return a session ID"]
            )
        }

        let actualStartTime: TimeInterval
        if startTime > 0 {
            actualStartTime = startTime
        } else if let serverTime = playSession.currentTime, serverTime > 0 {
            actualStartTime = serverTime
        } else {
            actualStartTime = 0
        }

        let session = ABSActiveSession(
            sessionId: sessionId,
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            backendId: backend.id,
            currentTime: actualStartTime,
            duration: playSession.duration ?? 0,
            timeListened: 0,
            startTime: actualStartTime,
            startedAt: Date(),
            lastUpdated: Date(),
            isClosed: false,
            deviceId: deviceId
        )

        activeSession = session
        saveLocalSession()

        AppLogger.player.info("Session started: \(sessionId) at \(actualStartTime)s")

        startSyncTimer()

        return playSession
    }

    func syncSession(currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async {
        guard var session = activeSession, !session.isClosed else {
            return
        }

        if let lastSync = lastSyncAttempt,
            Date().timeIntervalSince(lastSync) < minimumSyncInterval
        {
            return
        }

        session.currentTime = currentTime
        session.duration = duration
        session.timeListened += timeListened
        session.lastUpdated = Date()
        activeSession = session
        saveLocalSession()

        guard let backend = AppState.shared.providerConnections.backend(id: session.backendId) else {
            AppLogger.player.warning("Backend not found for session sync")
            return
        }

        lastSyncAttempt = Date()
        isSyncing = true

        do {
            try await service.syncPlaySession(
                sessionId: session.sessionId,
                currentTime: currentTime,
                timeListened: timeListened,
                duration: duration,
                backend: backend
            )

            lastSyncTime = Date()
            syncError = nil

            AppLogger.player.info("Synced: \(Int(currentTime))s / \(Int(duration))s")
        } catch {
            syncError = error.localizedDescription
            AppLogger.player.error("Sync failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    func closeCurrentSession() async {
        guard var session = activeSession, !session.isClosed else {
            return
        }

        stopSyncTimer()

        AppLogger.player.info("[ABSSession] Closing session: \(session.sessionId)")

        guard let backend = AppState.shared.providerConnections.backend(id: session.backendId) else {
            AppLogger.player.warning("Backend not found for session close")
            session.isClosed = true
            activeSession = session
            saveLocalSession()
            return
        }

        do {
            try await service.closePlaySession(
                sessionId: session.sessionId,
                currentTime: session.currentTime,
                timeListened: session.timeListened,
                duration: session.duration,
                backend: backend
            )

            AppLogger.player.info("Session closed successfully")
        } catch {
            AppLogger.player.error("Failed to close session: \(error.localizedDescription)")
        }

        session.isClosed = true
        activeSession = nil
        clearLocalSession()
    }

    func updateMediaProgress(
        libraryItemId: String,
        episodeId: String? = nil,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool = false,
        backend: BackendConfig
    ) async {
        do {
            if let episodeId = episodeId {
                try await service.updateProgress(
                    libraryItemId: libraryItemId,
                    episodeId: episodeId,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinished,
                    backend: backend
                )
            } else {
                try await service.updateProgress(
                    libraryItemId: libraryItemId,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinished,
                    backend: backend
                )
            }
            AppLogger.player.info("Media progress updated: \(Int(currentTime))s / \(Int(duration))s (finished: \(isFinished))")
        } catch {
            AppLogger.player.error("Failed to update media progress: \(error.localizedDescription)")
        }
    }

    func getMediaProgress(libraryItemId: String, backend: BackendConfig) async -> ABSMediaProgress? {
        do {
            return try await service.getProgress(libraryItemId: libraryItemId, backend: backend)
        } catch {
            AppLogger.player.error("Failed to get media progress: \(error.localizedDescription)")
            return nil
        }
    }

    private func startSyncTimer() {
        stopSyncTimer()

        syncTimer = Timer.scheduledTimer(withTimeInterval: syncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                    let session = self.activeSession,
                    !session.isClosed
                else {
                    return
                }

                let currentTime = playbackState.progress
                let duration = playbackState.duration

                guard duration > 0, currentTime > 0 || session.currentTime == 0 else { return }
                let timeSinceLastUpdate = Date().timeIntervalSince(session.lastUpdated)
                let timeListened = min(timeSinceLastUpdate, self.syncIntervalSeconds)
                await self.syncSession(
                    currentTime: currentTime,
                    duration: duration,
                    timeListened: timeListened
                )
            }
        }
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func saveLocalSession() {
        guard let session = activeSession else { return }

        do {
            let data = try JSONEncoder().encode(session)
            userDefaults.set(data, forKey: localSessionKey)
        } catch {
            AppLogger.player.error("Failed to save local session: \(error)")
        }
    }

    private func loadLocalSession() {
        guard let data = userDefaults.data(forKey: localSessionKey) else { return }

        do {
            let session = try JSONDecoder().decode(ABSActiveSession.self, from: data)

            if Date().timeIntervalSince(session.lastUpdated) > 86400 {
                clearLocalSession()
                return
            }

            if !session.isClosed {
                activeSession = session
                AppLogger.player.info("Loaded unclosed session: \(session.sessionId)")

                Task {
                    await closeCurrentSession()
                }
            }
        } catch {
            AppLogger.player.error("Failed to load local session: \(error)")
            clearLocalSession()
        }
    }

    private func clearLocalSession() {
        userDefaults.removeObject(forKey: localSessionKey)
    }

    private func setupAppLifecycleObservers() {
        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.syncBeforeBackground()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.syncBeforeBackground()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.closeCurrentSession()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    if let session = self?.activeSession, !session.isClosed {
                        self?.startSyncTimer()
                    }
                }
            }
            .store(in: &cancellables)
        #elseif os(macOS)
        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.syncBeforeBackground()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.closeCurrentSession()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    if let session = self?.activeSession, !session.isClosed {
                        self?.startSyncTimer()
                    }
                }
            }
            .store(in: &cancellables)
        #endif
    }

    private func syncBeforeBackground() async {
        guard let session = activeSession, !session.isClosed else { return }

        let currentTime = playbackState.progress
        let duration = playbackState.duration

        guard duration > 0 else { return }

        let timeSinceLastUpdate = Date().timeIntervalSince(session.lastUpdated)

        AppLogger.player.info("Syncing before background...")
        await syncSession(
            currentTime: currentTime,
            duration: duration,
            timeListened: min(timeSinceLastUpdate, 60)
        )
    }
}
