import SwiftUI
import WatchKit

@main
struct EnveWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        PhoneLink.shared.activate()
        #if DEBUG
        runAutoTestIfRequested()
        #endif
    }

    #if DEBUG

    private func runAutoTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-watchAutoStream") || args.contains("-watchAutoDownload") || args.contains("-watchAutoRemotePlay") else {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if args.contains("-watchAutoRemotePlay") {
                await WatchLibraryModel.shared.refresh()
                if let first = WatchLibraryModel.shared.snapshot.continueItems.first {
                    PhoneLink.shared.sendCommand(WatchCommandPayload(action: .play, value: first.stableId))
                }
                return
            }
            await WatchLibraryModel.shared.refresh()
            guard let first = WatchLibraryModel.shared.snapshot.continueItems.first else { return }
            if args.contains("-watchAutoStream") {
                await WatchPlayerModel.shared.play(stableId: first.stableId)
            } else {
                await WatchDownloadManager.shared.start(stableId: first.stableId)
            }
        }
    }
    #endif

    func applicationDidBecomeActive() {
        Task { await WatchLibraryModel.shared.refreshIfStale() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask {

                WatchDownloadManager.shared.handle(urlTask)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
