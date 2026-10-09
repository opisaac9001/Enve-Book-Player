import Foundation

struct ProfileServerSyncPreferences {
    let defaults: UserDefaults
    let isOwner: Bool
    private let key = "profileServerSyncEnabled"
    private let enabledSinceKey = "profileServerSyncEnabledSince"

    var enabledSince: Date? { defaults.object(forKey: enabledSinceKey) as? Date }

    var isEnabled: Bool {
        get { defaults.object(forKey: key) as? Bool ?? isOwner }
        nonmutating set {
            if newValue && !isEnabled { defaults.set(Date(), forKey: enabledSinceKey) }
            defaults.set(newValue, forKey: key)
        }
    }

    func allowsHistoryUpload(startedAt: Date) -> Bool {
        isEnabled && (enabledSince.map { startedAt >= $0 } ?? true)
    }
}
