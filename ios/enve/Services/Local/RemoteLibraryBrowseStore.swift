import Foundation

final class RemoteLibraryBrowseStore: @unchecked Sendable {
    static let shared = RemoteLibraryBrowseStore()

    static let bookCountThreshold = 5000

    private static let defaultsKey = "enve.library.remoteBrowsedCatalogCounts"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var counts: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        counts = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int] ?? [:]
    }

    func record(providerId: UUID, libraryId: String, bookCount: Int) {
        let key = Self.key(providerId: providerId, libraryId: libraryId)
        lock.lock()
        defer { lock.unlock() }
        if bookCount > Self.bookCountThreshold {
            guard counts[key] != bookCount else { return }
            counts[key] = bookCount
        } else {
            guard counts.removeValue(forKey: key) != nil else { return }
        }
        defaults.set(counts, forKey: Self.defaultsKey)
    }

    func isRemoteBrowsed(providerId: UUID, libraryId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return counts[Self.key(providerId: providerId, libraryId: libraryId)] != nil
    }

    private static func key(providerId: UUID, libraryId: String) -> String {
        "\(providerId.uuidString)|\(libraryId)"
    }
}
