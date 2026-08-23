import Foundation

@MainActor
final class HearthDismissedShelfStore {
    static let shared = HearthDismissedShelfStore()

    private static let key = "dismissedContinueBookIds"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var stableIds: Set<String> {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    func insert(stableId: String) {
        var ids = stableIds
        ids.insert(stableId)
        defaults.set((try? JSONEncoder().encode(ids)) ?? Data(), forKey: Self.key)
    }
}
