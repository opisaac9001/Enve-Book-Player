import Foundation
import Logging
import Pulse
import PulseLogHandler

enum AppLogger {
    nonisolated static let player = Logging.Logger(label: "player")
    nonisolated static let network = Logging.Logger(label: "network")
    nonisolated static let sync = Logging.Logger(label: "sync")
    nonisolated static let library = Logging.Logger(label: "library")
    nonisolated static let general = Logging.Logger(label: "general")
    nonisolated static let carplay = Logging.Logger(label: "carplay")
    nonisolated static let stats = Logging.Logger(label: "stats")
    nonisolated static let feedback = Logging.Logger(label: "feedback")

    static func bootstrap() {
        #if DEBUG
        configureNetworkLogger()

        let pulseEnabled = ProcessInfo.processInfo.environment["ENVE_ENABLE_PULSE_LOGS"] == "1"
        LoggingSystem.bootstrap { label in
            if pulseEnabled {
                return PrivacyRedactingLogHandler(
                    MultiplexLogHandler([
                        StreamLogHandler.standardOutput(label: label),
                        PersistentLogHandler(label: label),
                    ])
                )
            } else {
                return PrivacyRedactingLogHandler(StreamLogHandler.standardOutput(label: label))
            }
        }
        #else
        LoggingSystem.bootstrap { label in
            PrivacyRedactingLogHandler(SwiftLogNoOpLogHandler())
        }
        #endif
    }

    private static func configureNetworkLogger() {
        NetworkLogger.shared = NetworkLogger { config in
            config.sensitiveHeaders = [
                "Authorization",
                "X-Plex-Token",
                "x-refresh-token",
                "x-goog-api-key",
                "X-Emby-Token",
                "X-MediaBrowser-Token",
            ]
            config.sensitiveQueryItems = [
                "token",
                "X-Plex-Token",
                "api_key",
                "apikey",
                "ApiKey",
            ]
            config.sensitiveDataFields = [
                "accessToken",
                "token",
                "refreshToken",
                "password",
                "email",
                "username",
                "secret",
            ]
            config.willHandleEvent = { $0.redacted }
        }
    }
}

extension LoggerStore.Event {
    nonisolated var redacted: Self {
        switch self {
        case .messageStored, .networkTaskProgressUpdated:
            return self
        case .networkTaskCreated(let event):
            var event = event
            event.originalRequest = event.originalRequest.redacted
            event.currentRequest = event.currentRequest?.redacted
            return .networkTaskCreated(event)
        case .networkTaskCompleted(let event):
            var event = event
            event.originalRequest = event.originalRequest.redacted
            event.currentRequest = event.currentRequest?.redacted
            return .networkTaskCompleted(event)
        }
    }
}

extension NetworkLogger.Request {
    nonisolated var redacted: Self {
        var copy = self
        copy.url = url?.redacted
        return copy
    }
}

extension URL {
    nonisolated var redacted: Self {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.host = "server.redacted"
        components?.port = nil
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? self
    }
}
