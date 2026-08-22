import Foundation
import Logging

@Observable
final class DevModeManager {
    static let shared = DevModeManager()

    private static let persistenceKey = "devModeEnabled"

    private(set) var isDevModeEnabled: Bool {
        didSet {
            #if DEBUG
            UserDefaults.standard.set(isDevModeEnabled, forKey: Self.persistenceKey)
            #else
            UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
            #endif
        }
    }

    private init() {
        #if DEBUG
        self.isDevModeEnabled = UserDefaults.standard.bool(forKey: Self.persistenceKey)
        #else
        self.isDevModeEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
        #endif
        AppLogger.network.info("DevModeManager initialized - isDevModeEnabled: \(isDevModeEnabled)")
    }

    func toggle() {
        #if DEBUG
        isDevModeEnabled.toggle()
        #else
        isDevModeEnabled = false
        #endif
    }

    func logout() {
        AppLogger.network.info("DevModeManager logging out")
        isDevModeEnabled = false
    }

    func forceReset() {
        AppLogger.network.info("DevModeManager force reset")
        isDevModeEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
    }

}
