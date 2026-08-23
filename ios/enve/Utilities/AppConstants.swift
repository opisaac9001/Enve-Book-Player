import Foundation

enum AppConstants {

    enum Cache {
        static let standardTTL: TimeInterval = 3600
        static let shortTTL: TimeInterval = 1800
        static let longTTL: TimeInterval = 86400
    }

    enum Timeout {
        static let request: TimeInterval = 30
        static let resourceDownload: TimeInterval = 3600
        static let largeDownload: TimeInterval = 7200
        static let serverValidation: TimeInterval = 10
    }

    enum Sync {
        static let progressSyncInterval: TimeInterval = 30
        static let hardcoverSyncThreshold: Double = 0.05
        static let launchSyncDelay: UInt64 = 5_000_000_000
        static let launchSyncBookLimit: Int = 1200
    }

    enum Time {
        static let secondsPerHour: Double = 3600
        static let secondsPerMinute: Double = 60
        static let hoursPerDay: Double = 24
        static let daysPerMonth: Double = 30
    }

    enum SmartCollection {
        static let shortBookThresholdHours: Double = 4
        static let epicBookThresholdHours: Double = 20
    }

    enum Session {
        static let estimatedSessionsPerHour: Double = 2
        static let maxSessionsPerMinute: Double = 1
    }

    enum Playback {
        static let defaultSpeed: Float = 1.0
        static let minSpeed: Float = 0.75
        static let maxSpeed: Float = 3.0
        static let defaultSkipForward: TimeInterval = 15
        static let defaultSkipBackward: TimeInterval = 15
        static let mediaLoadTimeout: TimeInterval = 10
        static let maxRetries: Int = 3
        static let seekCorrectionThreshold: Double = 1.0
        static let resumeTimeTolerance: TimeInterval = 30
        static let recentSyncWindow: TimeInterval = 60
        static let syncConflictThreshold: TimeInterval = 10
    }

    enum SleepTimer {
        static let fadeWindowSeconds: TimeInterval = 30
        static let fadeMinScale: Double = 0.03
        static let fadeCurveExponent: Double = 1.8
        static let snoozeDurationMinutes: Int = 5
    }

    enum Audio {
        static let defaultSampleRate: Double = 44100
        static let defaultBandQ: Double = 1.4
        static let butterworthQ: Double = 0.707
        static let eqBandFrequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    }

    enum Probe {
        static let urlProbeTimeout: TimeInterval = 3
    }
}
