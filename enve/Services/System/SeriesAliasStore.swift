import Foundation

@MainActor
@Observable
final class SeriesAliasStore {
    static let shared = SeriesAliasStore()

    @ObservationIgnored private static let storageKey = "enve_series_aliases"

    private(set) var aliases: [String: [String]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        {
            self.aliases = decoded
        } else {
            self.aliases = [:]
        }
    }

    func add(displayName: String, aliases: [String]) {
        self.aliases[displayName] = aliases
        persist()
    }

    func remove(displayName: String) {
        guard aliases[displayName] != nil else { return }
        aliases.removeValue(forKey: displayName)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
