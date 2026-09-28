import Foundation
import Logging
import SwiftUI

struct SelectedLibraryPreference: Codable, Equatable {
    let type: String
    let id: String
    let key: String
    let backendId: String?
}

enum BookCardStyle: String, Codable, CaseIterable, Identifiable {
    case standard
    case compact
    case coverOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Compact"
        case .coverOnly: return "Cover Only"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Cover with title, author, and narrator"
        case .compact: return "Cover with a smaller title only"
        case .coverOnly: return "Just the cover as a tile"
        }
    }

    var iconName: String {
        switch self {
        case .standard: return "text.below.photo"
        case .compact: return "rectangle.compress.vertical"
        case .coverOnly: return "photo"
        }
    }
}

enum SeriesSortOption: String, Codable {
    case name
    case bookCount
    case recentlyAdded
}

@MainActor
final class LibraryDisplayPreferencesStore {
    static let shared = LibraryDisplayPreferencesStore()

    private static let downloadedOnlyKey = "libraryDownloadedOnly"
    private static let cacheScopeKey = "cacheScopePreference"
    private static let selectedLibraryKey = "selectedLibraryPreference"
    private static let gridLayoutKey = "gridLayout"
    private static let bookCardStyleKey = "bookCardStyle"
    private static let inProgressOnlyKey = "libraryInProgressOnly"
    private static let completedOnlyKey = "libraryCompletedOnly"
    private static let sourceFilterKey = "librarySourceFilter"
    private static let sourceFiltersKey = "librarySourceFilters"
    private static let notStartedOnlyKey = "libraryNotStartedOnly"
    private static let hasBookmarksOnlyKey = "libraryHasBookmarksOnly"
    private static let hasCoverArtOnlyKey = "libraryHasCoverArtOnly"
    private static let multiFileOnlyKey = "libraryMultiFileOnly"
    private static let durationFiltersKey = "libraryDurationFilters"
    private static let authorFiltersKey = "libraryAuthorFilters"
    private static let genreFiltersKey = "libraryGenreFilters"
    private static let seriesFiltersKey = "librarySeriesFilters"
    private static let recentlyAddedDaysKey = "libraryRecentlyAddedDays"
    private static let browseSegmentKey = "browseSelectedSegment"
    private static let seriesSortOptionKey = "seriesSortOption"
    private static let seriesSortDirectionKey = "seriesSortDirection"
    private static let userPreferencesKey = "userPreferences"

    private let userDefaults = UserDefaults.standard

    private init() {}

    private enum CacheScopeRaw: String {
        case local
        case iCloudIfAvailable
    }

    func saveCacheScope(_ scope: CacheScope) {
        let raw: CacheScopeRaw
        switch scope {
        case .local: raw = .local
        case .iCloudIfAvailable: raw = .iCloudIfAvailable
        }
        userDefaults.set(raw.rawValue, forKey: Self.cacheScopeKey)
    }

    func loadCacheScope() -> CacheScope {
        guard let rawValue = userDefaults.string(forKey: Self.cacheScopeKey),
            let raw = CacheScopeRaw(rawValue: rawValue)
        else {
            return .local
        }
        switch raw {
        case .local: return .local
        case .iCloudIfAvailable: return .iCloudIfAvailable
        }
    }

    func saveBookCardStyle(_ style: BookCardStyle) {
        userDefaults.set(style.rawValue, forKey: Self.bookCardStyleKey)
    }

    func loadBookCardStyle() -> BookCardStyle {
        guard let rawValue = userDefaults.string(forKey: Self.bookCardStyleKey),
            let style = BookCardStyle(rawValue: rawValue)
        else {
            return .standard
        }
        return style
    }

    func savePreferences(_ preferences: UserPreferences) {
        guard let encoded = try? JSONEncoder().encode(preferences) else { return }
        if let existing = userDefaults.data(forKey: Self.userPreferencesKey), existing == encoded {
            return
        }
        userDefaults.set(encoded, forKey: Self.userPreferencesKey)
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    func loadPreferences() -> UserPreferences {
        guard let data = userDefaults.data(forKey: Self.userPreferencesKey) else {
            return UserPreferences.default
        }
        do {
            return try JSONDecoder().decode(UserPreferences.self, from: data)
        } catch {
            AppLogger.general.error(
                "UserPreferences decode failed - keeping defaults. The resilient decoder tolerates missing/invalid fields, so this should be rare. Error: \(error.localizedDescription)"
            )
            return UserPreferences.default
        }
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = userDefaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(type, from: data)
        else {
            return nil
        }
        return decoded
    }
}
