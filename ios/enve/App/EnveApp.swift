import Logging
import SwiftUI

#if os(iOS)
import AppIntents
import BackgroundTasks
#endif

struct EnveApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CarPlayAppDelegate.self) var carPlayDelegate
    #endif

    @State private var profiles = ProfileSwitchCoordinator.shared
    @StateObject private var themeManager = ThemeManager.shared

    @Environment(\.scenePhase) private var scenePhase

    private static func disableCoreDataDebugLogging() {
        let keys = [
            "com.apple.CoreData.SQLDebug",
            "com.apple.CoreData.Logging.stderr",
            "com.apple.CoreData.ConcurrencyDebug",
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

    init() {
        Self.disableCoreDataDebugLogging()

        StorageMigrationHelper.migrateIfNeeded()
        SyncMigrationManager.runIfNeeded()
        ReaderDataMigration.runIfNeeded()

        AppLogger.bootstrap()
        AppLogger.general.info("Enve source provenance: \(EnveProvenance.identifier)")


        #if os(iOS)
        EnveAppShortcuts.updateAppShortcutParameters()
        #endif

        #if os(iOS)

        RuntimeDiagnosticsCollector.shared.start()
        #endif

        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.enve.enve.storyalign", using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                let coordinator = ProfileSwitchCoordinator.shared
                guard coordinator.activeSession.isOwner, !coordinator.isLocked, !coordinator.activeSession.isRetired else {
                    task.setTaskCompleted(success: false)
                    return
                }
                coordinator.activeSession.storyAlignService.handleContinuedProcessingTask(task)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if profiles.isLocked {
                    ProfilePickerScreen()
                        .environment(profiles)
                        .environmentObject(themeManager)
                        .hearthRoot()
                } else {
                    AppRootView(profileSession: profiles.activeSession)
                        .id(ObjectIdentifier(profiles.activeSession))
                        .enveEnvironment(session: profiles.activeSession)
                }
            }
            .task(id: ObjectIdentifier(profiles.activeSession)) {
                guard !profiles.isLocked else { return }
                let session = profiles.activeSession
                session.start()
                if session.isOwner, #available(iOS 26.0, *) { session.storyAlignService.loadPausedConversion() }
                await session.listeningStats.startTracking()
                await session.appCache.runMaintenance()
                guard !Task.isCancelled, !session.isRetired else { return }
                #if os(iOS)
                session.fileSharing.startWatching()
                session.fileSharing.scheduleRefresh(reason: "app-launch")
                session.activateSystemAccess()
                #endif
                if session.isOwner && PlatformRuntime.cloudKitEnabled {
                    await ServerConnectionCloudKitSync.shared.bootstrap()
                }
            }
            .onChange(of: profiles.isLocked) { _, locked in
                if !locked {
                    profiles.activeSession.start()
                    profiles.activeSession.activateSystemAccess()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                let session = profiles.activeSession
                if phase == .active {
                    guard !profiles.isLocked else { return }
                    #if os(iOS)
                    session.fileSharing.startWatching()
                    session.fileSharing.scheduleRefresh(reason: "scene-active")
                    #endif
                } else if phase == .background {
                    profiles.onBackground()
                    #if os(iOS)
                    session.fileSharing.stopWatching()
                    #endif
                    session.appState.persistStartupCachesImmediately()
                    Task {
                        await session.playback.player.saveProgressOnBackground()
                        await session.listeningStats.endSession(uploadToServer: false)
                        await session.readingStats.endSession(uploadToServer: false)
                    }
                } else {
                    #if os(iOS)
                    session.fileSharing.stopWatching()
                    #endif
                }
            }
        }
        .enveCatalystCommands()
    }
}

private extension Scene {
    @SceneBuilder
    func enveCatalystCommands() -> some Scene {
        #if targetEnvironment(macCatalyst)
        commands { EnveCatalystCommands() }
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct EnveCatalystCommands: Commands {
    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(HearthTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) {
                    NotificationCenter.default.post(
                        name: .enveCatalystSelectTab,
                        object: tab.rawValue
                    )
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .enveCatalystShowSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
