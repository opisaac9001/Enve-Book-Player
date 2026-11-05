import Foundation

extension Notification.Name {

    static let bookStoreDidChange = Notification.Name("bookStoreDidChange")
}

enum BookStoreChangeNotifier {
    private static let coalesceWindow: TimeInterval = 0.5
    nonisolated(unsafe) private static var lastPostedAt: Date = .distantPast
    nonisolated(unsafe) private static var pending = false
    nonisolated(unsafe) private static var quietDepth = 0
    nonisolated(unsafe) private static var deferredWhileQuiet = false

    static func notify() {
        guard quietDepth == 0 else {
            deferredWhileQuiet = true
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastPostedAt) >= coalesceWindow {
            lastPostedAt = now
            postNow()
        } else if !pending {
            pending = true
            let delay = max(0, coalesceWindow - now.timeIntervalSince(lastPostedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pending = false
                guard quietDepth == 0 else {
                    deferredWhileQuiet = true
                    return
                }
                lastPostedAt = Date()
                postNow()
            }
        }
    }

    /// While a reader is presented, library-wide refreshes wait so page turns don't reload the screens underneath it.
    @MainActor
    static func beginQuietPeriod() {
        quietDepth += 1
    }

    @MainActor
    static func endQuietPeriod() {
        quietDepth = max(0, quietDepth - 1)
        guard quietDepth == 0, deferredWhileQuiet else { return }
        deferredWhileQuiet = false
        lastPostedAt = Date()
        postNow()
    }

    private static func postNow() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
            }
        }
    }
}
