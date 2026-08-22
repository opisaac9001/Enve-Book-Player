import Foundation

extension Notification.Name {

    static let bookStoreDidChange = Notification.Name("bookStoreDidChange")
}

enum BookStoreChangeNotifier {
    private static let coalesceWindow: TimeInterval = 0.5
    nonisolated(unsafe) private static var lastPostedAt: Date = .distantPast
    nonisolated(unsafe) private static var pending = false

    static func notify() {
        let now = Date()
        if now.timeIntervalSince(lastPostedAt) >= coalesceWindow {
            lastPostedAt = now
            postNow()
        } else if !pending {
            pending = true
            let delay = max(0, coalesceWindow - now.timeIntervalSince(lastPostedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pending = false
                lastPostedAt = Date()
                postNow()
            }
        }
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
