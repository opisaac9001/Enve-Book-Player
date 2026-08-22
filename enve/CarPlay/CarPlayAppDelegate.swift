import CarPlay
import CloudKit
import Logging
import UIKit

final class CarPlayAppDelegate: NSObject, UIApplicationDelegate {

    private var backgroundSessionCompletionHandlers: [String: () -> Void] = [:]

    @MainActor
    func consumeBackgroundCompletionHandler(forIdentifier identifier: String) -> (() -> Void)? {
        backgroundSessionCompletionHandlers.removeValue(forKey: identifier)
    }

    @MainActor
    func storeBackgroundCompletionHandler(_ handler: @escaping () -> Void, forIdentifier identifier: String) {
        backgroundSessionCompletionHandlers[identifier] = handler
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()

        if PlatformRuntime.cloudKitEnabled {
            Task {
                await CloudKitProgressSync.shared.registerForPushNotifications()
            }
        }

        ABSSessionBackgroundTask.shared.registerHandler()

        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        AppLogger.general.info("handleEventsForBackgroundURLSession identifier=\(identifier)")
        backgroundSessionCompletionHandlers[identifier] = completionHandler

        switch identifier {
        case UnifiedDownloadService.backgroundSessionIdentifier:
            _ = UnifiedDownloadService.shared
        case "com.enve.import":
            _ = RemoteImportService.shared
        case "com.narrator.metadata-downloads":
            MetadataBatchDownloader.shared.loadQueue()
        default:
            AppLogger.general.warning("Unknown background URLSession identifier: \(identifier)")
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AppLogger.carplay.info("Registered for remote notifications")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        let message = error.localizedDescription
        #if targetEnvironment(simulator)
        AppLogger.carplay.info("Remote notifications unavailable in simulator: \(message)")
        #else
        if message.localizedCaseInsensitiveContains("aps-environment") {
            AppLogger.carplay.warning("Remote notifications unavailable (missing aps-environment entitlement): \(message)")
        } else {
            AppLogger.carplay.error("Failed to register for remote notifications: \(message)")
        }
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
            notification.subscriptionID == "BookProgressChanges"
        {
            Task {
                await CloudKitProgressSync.shared.handlePushNotification()
                completionHandler(.newData)
            }
        } else {
            completionHandler(.noData)
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(
                name: "CarPlaySceneConfiguration",
                sessionRole: .carTemplateApplication
            )
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        return config
    }
}
