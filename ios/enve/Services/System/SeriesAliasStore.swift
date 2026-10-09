import Foundation

@MainActor
@Observable
final class SeriesAliasStore {
    static let shared = SeriesAliasStore()

    @ObservationIgnored private static let storageKey = "enve_series_aliases"

    private(set) var aliases: [String: [String]]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
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
        defaults.set(data, forKey: Self.storageKey)
    }
}
