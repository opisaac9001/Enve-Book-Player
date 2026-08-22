import Foundation

@MainActor
@Observable
final class LastOpenedBookStore {
    static let shared = LastOpenedBookStore()

    private static let stableIdKey = "lastOpenedBookStableId"
    private static let openedAtKey = "lastOpenedBookDate"

    private let defaults: UserDefaults

    private(set) var stableId: String?
    private(set) var openedAt: Date?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stableId = defaults.string(forKey: Self.stableIdKey)
        if defaults.object(forKey: Self.openedAtKey) != nil {
            openedAt = Date(timeIntervalSince1970: defaults.double(forKey: Self.openedAtKey))
        }
    }

    func record(_ book: Book, at date: Date = Date()) {
        stableId = book.stableId
        openedAt = date
        defaults.set(book.stableId, forKey: Self.stableIdKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.openedAtKey)
    }

    func clear() {
        stableId = nil
        openedAt = nil
        defaults.removeObject(forKey: Self.stableIdKey)
        defaults.removeObject(forKey: Self.openedAtKey)
    }
}
