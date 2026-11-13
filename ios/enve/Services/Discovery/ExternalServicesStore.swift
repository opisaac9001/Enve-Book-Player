import Foundation
import Observation

nonisolated enum ExternalService: String, CaseIterable, Identifiable, Sendable {
    case audible
    case appleCatalog
    case googleBooks
    case openLibrary
    case comicVine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audible: "Audible catalog"
        case .appleCatalog: "Apple catalog"
        case .googleBooks: "Google Books"
        case .openLibrary: "Open Library"
        case .comicVine: "ComicVine"
        }
    }
}

nonisolated struct ExternalServiceDisabledError: LocalizedError, Sendable {
    let service: ExternalService

    var errorDescription: String? {
        "\(service.displayName) is turned off in Settings › External services."
    }
}

// UserDefaults is thread-safe; the policy is read from the main actor and from iTunesPodcastProvider.
nonisolated final class ExternalServicesPolicy: @unchecked Sendable {
    static let shared = ExternalServicesPolicy()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Stored as an opt-out so every service in use before this setting existed stays allowed.
    private static func disabledKey(_ service: ExternalService) -> String {
        "externalServices.disabled.\(service.rawValue)"
    }

    func isAllowed(_ service: ExternalService) -> Bool {
        !defaults.bool(forKey: Self.disabledKey(service))
    }

    func setAllowed(_ allowed: Bool, for service: ExternalService) {
        if allowed {
            defaults.removeObject(forKey: Self.disabledKey(service))
        } else {
            defaults.set(true, forKey: Self.disabledKey(service))
        }
    }

    func checkAllowed(_ service: ExternalService) throws {
        guard isAllowed(service) else { throw ExternalServiceDisabledError(service: service) }
    }
}

@MainActor
@Observable
final class ExternalServicesStore {
    static let shared = ExternalServicesStore()

    @ObservationIgnored private let policy: ExternalServicesPolicy
    private(set) var disabledServices: Set<ExternalService>

    init(policy: ExternalServicesPolicy = .shared) {
        self.policy = policy
        disabledServices = Set(ExternalService.allCases.filter { !policy.isAllowed($0) })
    }

    func isEnabled(_ service: ExternalService) -> Bool {
        !disabledServices.contains(service)
    }

    func setEnabled(_ enabled: Bool, for service: ExternalService) {
        policy.setAllowed(enabled, for: service)
        if enabled {
            disabledServices.remove(service)
        } else {
            disabledServices.insert(service)
        }
    }
}
