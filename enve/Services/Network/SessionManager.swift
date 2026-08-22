// AGENT-LOCKED
import Combine
import Foundation
import Logging

#if os(iOS)
import UIKit
#endif

@Observable
final class SessionManager {
    static let shared = SessionManager()

    private(set) var activeSessionId: String?
    private(set) var lastActivityTime: Date?
    private(set) var isSessionActive = false

    var inactivityTimeout: TimeInterval = 30 * 60

    var warningThreshold: TimeInterval = 5 * 60

    @ObservationIgnored private var inactivityTimer: Timer?
    @ObservationIgnored private var warningTimer: Timer?
    @ObservationIgnored private let persistenceKey = "activePlaybackSession"

    @ObservationIgnored var onSessionWarning: (() -> Void)?
    @ObservationIgnored var onSessionTimeout: (() -> Void)?

    private init() {
        setupObservers()
        restoreSession()
    }

    func startSession(bookId: String) {
        activeSessionId = bookId
        isSessionActive = true
        lastActivityTime = Date()

        resetInactivityTimer()
        persistSession()

        AppLogger.sync.debug(
            "Session started bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
        )
    }

    func recordActivity() {
        lastActivityTime = Date()
        resetInactivityTimer()
        persistSession()

        if !isSessionActive, let sessionId = activeSessionId {
            AppLogger.sync.info("Session resumed: \(sessionId)")
            isSessionActive = true
        }
    }

    func endSession() {
        guard let sessionId = activeSessionId else { return }

        AppLogger.sync.info("Session ended: \(sessionId)")

        activeSessionId = nil
        isSessionActive = false
        lastActivityTime = nil

        invalidateTimers()
        clearPersistedSession()
    }

    func isSessionExpired() -> Bool {
        guard let lastActivity = lastActivityTime else { return true }
        return Date().timeIntervalSince(lastActivity) > inactivityTimeout
    }

    func timeUntilTimeout() -> TimeInterval? {
        guard let lastActivity = lastActivityTime, isSessionActive else { return nil }
        let elapsed = Date().timeIntervalSince(lastActivity)
        let remaining = inactivityTimeout - elapsed
        return max(0, remaining)
    }

    private func setupObservers() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
    }

    @objc private func appDidEnterBackground() {
        invalidateTimers()
        AppLogger.sync.info("App backgrounded, timers paused")
    }

    @objc private func appWillEnterForeground() {
        if isSessionActive && isSessionExpired() {
            AppLogger.sync.warning("Session expired while in background")
            handleSessionTimeout()
        } else if isSessionActive {
            resetInactivityTimer()
            AppLogger.sync.info("App foregrounded, timers resumed")
        }
    }

    private func resetInactivityTimer() {
        invalidateTimers()

        guard isSessionActive else { return }

        let warningTime = inactivityTimeout - warningThreshold
        if warningTime > 0 {
            warningTimer = Timer.scheduledTimer(
                withTimeInterval: warningTime,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionWarning()
                }
            }
        }

        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: inactivityTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSessionTimeout()
            }
        }
    }

    private func invalidateTimers() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        warningTimer?.invalidate()
        warningTimer = nil
    }

    private func handleSessionWarning() {
        AppLogger.sync.warning("Session will timeout soon")
        onSessionWarning?()
    }

    private func handleSessionTimeout() {
        AppLogger.sync.info("Session timed out due to inactivity")
        onSessionTimeout?()
        endSession()
    }

    private struct PersistedSession: Codable {
        let bookId: String
        let lastActivity: Date
        let isActive: Bool
    }

    private func persistSession() {
        guard let bookId = activeSessionId,
            let lastActivity = lastActivityTime
        else { return }

        let session = PersistedSession(
            bookId: bookId,
            lastActivity: lastActivity,
            isActive: isSessionActive
        )

        if let encoded = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
            let session = try? JSONDecoder().decode(PersistedSession.self, from: data)
        else {
            return
        }

        let timeSinceLastActivity = Date().timeIntervalSince(session.lastActivity)
        guard timeSinceLastActivity < inactivityTimeout else {
            AppLogger.sync.warning("Stored session expired, not restoring")
            clearPersistedSession()
            return
        }

        activeSessionId = session.bookId
        lastActivityTime = session.lastActivity
        isSessionActive = session.isActive

        if session.isActive {
            resetInactivityTimer()
        }

        AppLogger.sync.debug(
            "Restored session bookId=\(DiagnosticLogSanitizer.identifier(for: session.bookId))"
        )
    }

    private func clearPersistedSession() {
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }
}
