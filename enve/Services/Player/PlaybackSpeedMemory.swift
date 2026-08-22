import Foundation

@MainActor
final class PlaybackSpeedMemory {
    static let shared = PlaybackSpeedMemory()
    private init() {}

    private static let key = "imagine.perBookSpeed.v1"

    private var map: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    func speed(forStableId id: String) -> Double? {
        guard !id.isEmpty else { return nil }
        return map[id]
    }

    func remember(_ speed: Double, forStableId id: String) {
        guard !id.isEmpty else { return }
        var m = map
        m[id] = speed
        map = m
    }

    func forget(stableId id: String) {
        guard !id.isEmpty, map[id] != nil else { return }
        var m = map
        m[id] = nil
        map = m
    }

    func allSpeeds() -> [String: Double] {
        map
    }

    func restore(_ speeds: [String: Double]) {
        guard !speeds.isEmpty else { return }
        map = speeds.merging(map) { _, local in local }
    }
}
