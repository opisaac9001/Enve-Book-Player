import Foundation
import SwiftUI

private func disableCoreDataDebugLoggingEarly() {
    let keys = [
        "com.apple.CoreData.SQLDebug",
        "com.apple.CoreData.Logging.stderr",

        "com.apple.CoreData.MigrationDebug",
        "com.apple.CoreData.CloudKitDebug",
        "com.apple.CoreData.Debug",
    ]

    for key in keys {
        unsetenv(key)
        setenv(key, "0", 1)
        UserDefaults.standard.set(0, forKey: key)
    }
}

disableCoreDataDebugLoggingEarly()
EnveApp.main()
