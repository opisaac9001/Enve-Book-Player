import Foundation

@MainActor
final class TVReadAlongProgressStore {
    struct Position: Codable, Equatable {
        let href: String
        let fragmentID: String
        let offset: TimeInterval
        let observedAt: Date
    }

    static let shared = TVReadAlongProgressStore()
    private let defaults: UserDefaults
    private let key = "storyteller.tv.readAlongPositions.v1"
    private var positions: [String: Position]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        positions = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: Position].self, from: $0) } ?? [:]
    }

    func position(for bookID: String) -> Position? { positions[bookID] }

    func save(_ position: Position, for bookID: String) {
        positions[bookID] = position
        defaults.set(try? JSONEncoder().encode(positions), forKey: key)
    }
}
