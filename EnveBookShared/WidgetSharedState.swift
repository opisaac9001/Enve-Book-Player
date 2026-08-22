import Foundation

#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

#if !targetEnvironment(macCatalyst)
nonisolated struct BookTTSActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var isPlaying: Bool
    }

    var title: String
    var author: String
}
#endif

enum BookWidgetShared {
    static let appGroup = "group.com.enve.enve"
    static let continueKind = "EnveBookContinue"
    static let lockScreenKind = "EnveBookLockScreen"
    static let darwinCommandName = "com.enve.enve.widget.command"

    private static let snapshotKey = "enve.widget.currentBook"
    private static let commandKey = "enve.widget.command"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static var artworkFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("current-book.jpg")
    }

    static func loadSnapshot() -> BookWidgetSnapshot {
        guard let data = defaults?.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(BookWidgetSnapshot.self, from: data)
        else {
            return .empty
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: BookWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    static func postCommand(_ command: String) {
        defaults?.set(command, forKey: commandKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinCommandName as CFString),
            nil,
            nil,
            true
        )
    }

    static func takeCommand() -> String? {
        let command = defaults?.string(forKey: commandKey)
        defaults?.removeObject(forKey: commandKey)
        return command
    }
}

struct BookWidgetSnapshot: Codable, Equatable {
    var id: String
    var title: String
    var author: String
    var chapter: String
    var isPlaying: Bool
    var hasBook: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    var skipBackward: Int
    var skipForward: Int

    var progress: Double {
        duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
    }

    static let empty = BookWidgetSnapshot(
        id: "",
        title: "",
        author: "",
        chapter: "",
        isPlaying: false,
        hasBook: false,
        elapsed: 0,
        duration: 0,
        skipBackward: 15,
        skipForward: 30
    )
}
