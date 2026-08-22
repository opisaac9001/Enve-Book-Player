import Foundation

@MainActor
final class WorkOverrideStore {
    static let shared = WorkOverrideStore()
    private init() {}

    enum Override: Equatable {
        case mergeInto(String)
        case split
    }

    private static let key = "imagine.workOverrides.v1"

    private var raw: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    var isEmpty: Bool { raw.isEmpty }

    func override(forStableId id: String) -> Override? {
        guard let value = raw[id] else { return nil }
        if value == "s" { return .split }
        if value.hasPrefix("m:") { return .mergeInto(String(value.dropFirst(2))) }
        return nil
    }

    func effectiveWorkKey(stableId: String, computed: String) -> String {
        switch override(forStableId: stableId) {
        case .mergeInto(let key): return key
        case .split: return "split:\(stableId)"
        case nil: return computed
        }
    }

    func merge(stableIds: [String], intoComputedWorkKey workKey: String) {
        guard !stableIds.isEmpty, !workKey.isEmpty else { return }
        var map = raw
        for id in stableIds { map[id] = "m:\(workKey)" }
        raw = map
    }

    func stableIdsMerged(into key: String) -> [String] {
        raw.compactMap { $0.value == "m:\(key)" ? $0.key : nil }
    }

    func split(stableId: String) {
        var map = raw
        map[stableId] = "s"
        raw = map
    }

    func clear(stableId: String) {
        guard raw[stableId] != nil else { return }
        var map = raw
        map[stableId] = nil
        raw = map
    }

    private static let dismissedKey = "imagine.workSuggestionsDismissed.v1"

    private var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.dismissedKey) }
    }

    func isDismissed(suggestionId id: String) -> Bool { dismissed.contains(id) }

    func dismissSuggestion(id: String) {
        var set = dismissed
        set.insert(id)
        dismissed = set
    }
}
