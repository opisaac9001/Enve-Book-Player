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

#if DEBUG
private struct UnitTestHost: App {
    var body: some Scene {
        WindowGroup { Color.clear }
    }
}

let testEnvironment = ProcessInfo.processInfo.environment
let needsCloudLaunch = ["ENVE_ICLOUD_LIVE_RUN_ID", "ENVE_ICLOUD_AUDIOBOOK_RUN_ID", "ENVE_ICLOUD_LAUNCH_RUN_ID"]
    .contains { testEnvironment[$0] != nil }
if testEnvironment["ENVE_UNIT_TEST_HOST"] == "1", !needsCloudLaunch {
    AppLogger.bootstrap()
    UnitTestHost.main()
} else {
    EnveApp.main()
}
#else
EnveApp.main()
#endif
