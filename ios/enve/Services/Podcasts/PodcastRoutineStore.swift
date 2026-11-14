import Foundation

struct PodcastRoutineRule: Identifiable, Codable, Equatable, Sendable {
    enum Pick: Codable, Equatable, Sendable {
        case newestUnplayed
        case nextUnplayed(Int)

        static let countRange = 1...10

        var maximumEpisodes: Int {
            switch self {
            case .newestUnplayed: 1
            case .nextUnplayed(let count): count
            }
        }
    }

    let id: UUID
    var feedURL: String
    var showTitle: String
    var pick: Pick

    init(id: UUID = UUID(), feedURL: String, showTitle: String, pick: Pick = .newestUnplayed) {
        self.id = id
        self.feedURL = feedURL
        self.showTitle = showTitle
        self.pick = pick
    }
}

struct PodcastRoutine: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rules: [PodcastRoutineRule]

    init(id: UUID = UUID(), name: String, rules: [PodcastRoutineRule] = []) {
        self.id = id
        self.name = name
        self.rules = rules
    }
}

@MainActor
@Observable
final class PodcastRoutineStore {
    static let maximumRoutines = 50
    static let maximumRules = 30
    static let maximumNameLength = 60
    static let defaultName = "Untitled routine"

    @ObservationIgnored private static let storageKey = "podcast_routines"

    private(set) var routines: [PodcastRoutine]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([PodcastRoutine].self, from: data)
        {
            routines = decoded.map(Self.sanitized)
        } else {
            routines = []
        }
    }

    var canCreate: Bool { routines.count < Self.maximumRoutines }

    func routine(id: UUID) -> PodcastRoutine? {
        routines.first { $0.id == id }
    }

    @discardableResult
    func create(named name: String, rules: [PodcastRoutineRule] = []) -> PodcastRoutine? {
        guard canCreate else { return nil }
        let routine = Self.sanitized(PodcastRoutine(name: name, rules: rules))
        routines.append(routine)
        persist()
        return routine
    }

    func save(_ routine: PodcastRoutine) {
        let sanitized = Self.sanitized(routine)
        guard let index = routines.firstIndex(where: { $0.id == routine.id }), routines[index] != sanitized else { return }
        routines[index] = sanitized
        persist()
    }

    func delete(id: UUID) {
        let before = routines.count
        routines.removeAll { $0.id == id }
        if routines.count != before { persist() }
    }

    func move(id: UUID, by delta: Int) {
        guard let source = routines.firstIndex(where: { $0.id == id }), routines.indices.contains(source + delta) else { return }
        routines.swapAt(source, source + delta)
        persist()
    }

    static func sanitized(_ routine: PodcastRoutine) -> PodcastRoutine {
        var copy = routine
        let trimmed = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty ? defaultName : String(trimmed.prefix(maximumNameLength))
        copy.rules = Array(copy.rules.prefix(maximumRules)).map { rule in
            var rule = rule
            if case .nextUnplayed(let count) = rule.pick {
                rule.pick = .nextUnplayed(min(max(count, Pick.countRange.lowerBound), Pick.countRange.upperBound))
            }
            return rule
        }
        return copy
    }

    private typealias Pick = PodcastRoutineRule.Pick

    private func persist() {
        guard let data = try? JSONEncoder().encode(routines) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
