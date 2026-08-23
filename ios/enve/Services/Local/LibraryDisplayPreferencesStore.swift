import Foundation
import Logging
import SwiftUI

struct SelectedLibraryPreference: Codable, Equatable {
    let type: String
    let id: String
    let key: String
    let backendId: String?
}

enum GridLayout: String, Codable {
    case list
    case twoColumn
    case threeColumn
    case fourColumn
    case fiveColumn
    case sixColumn
    case grid

    var columns: [GridItem] {
        switch self {
        case .list:
            return [GridItem(.flexible())]
        case .twoColumn:
            return Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)
        case .threeColumn:
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        case .fourColumn:
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        case .fiveColumn:
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
        case .sixColumn:
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
        case .grid:
            return Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)
        }
    }

    var iconName: String {
        switch self {
        case .list:
            return "list.bullet"
        case .twoColumn, .grid:
            return "square.grid.2x2"
        case .threeColumn:
            return "square.grid.3x3"
        case .fourColumn:
            return "square.grid.4x3.fill"
        case .fiveColumn, .sixColumn:
            return "square.grid.3x3.fill"
        }
    }
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

enum BrowseSegment: String, Codable {
    case authors
    case narrators
    case series
    case collections
}

enum SeriesSortOption: String, Codable {
    case name
    case bookCount
    case recentlyAdded
}

enum SortDirection: String, Codable {
    case ascending
    case descending
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

    func saveDownloadedOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.downloadedOnlyKey) }
    func loadDownloadedOnly() -> Bool { userDefaults.bool(forKey: Self.downloadedOnlyKey) }

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

    func saveSelectedLibraryPreference(from library: LibrarySection) {
        let preference = SelectedLibraryPreference(
            type: library.type,
            id: library.id,
            key: library.key,
            backendId: library.backendId
        )
        encode(preference, forKey: Self.selectedLibraryKey)
    }

    func loadSelectedLibraryPreference() -> SelectedLibraryPreference? {
        decode(SelectedLibraryPreference.self, forKey: Self.selectedLibraryKey)
    }

    func clearSelectedLibraryPreference() {
        userDefaults.removeObject(forKey: Self.selectedLibraryKey)
    }

    func saveGridLayout(_ layout: GridLayout) {
        userDefaults.set(layout.rawValue, forKey: Self.gridLayoutKey)
    }

    func loadGridLayout() -> GridLayout {
        if let rawValue = userDefaults.string(forKey: Self.gridLayoutKey) {
            if let layout = GridLayout(rawValue: rawValue) { return layout }

            if rawValue == "grid2x" { return .twoColumn }
            if rawValue == "grid3x" { return .threeColumn }
        }
        return .threeColumn
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

    func saveInProgressOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.inProgressOnlyKey) }
    func loadInProgressOnly() -> Bool { userDefaults.bool(forKey: Self.inProgressOnlyKey) }

    func saveCompletedOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.completedOnlyKey) }
    func loadCompletedOnly() -> Bool { userDefaults.bool(forKey: Self.completedOnlyKey) }

    func saveSourceFilter(_ rawSource: String?) {
        if let raw = rawSource, !raw.isEmpty {
            userDefaults.set(raw, forKey: Self.sourceFilterKey)
        } else {
            userDefaults.removeObject(forKey: Self.sourceFilterKey)
        }
    }

    func loadSourceFilter() -> String? { userDefaults.string(forKey: Self.sourceFilterKey) }

    func saveSourceFilters(_ rawSources: [String]) {
        if rawSources.isEmpty {
            userDefaults.removeObject(forKey: Self.sourceFiltersKey)
        } else {
            userDefaults.set(rawSources, forKey: Self.sourceFiltersKey)
        }
    }

    func loadSourceFilters() -> [String]? { userDefaults.stringArray(forKey: Self.sourceFiltersKey) }

    func saveNotStartedOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.notStartedOnlyKey) }
    func loadNotStartedOnly() -> Bool { userDefaults.bool(forKey: Self.notStartedOnlyKey) }

    func saveHasBookmarksOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.hasBookmarksOnlyKey) }
    func loadHasBookmarksOnly() -> Bool { userDefaults.bool(forKey: Self.hasBookmarksOnlyKey) }

    func saveHasCoverArtOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.hasCoverArtOnlyKey) }
    func loadHasCoverArtOnly() -> Bool { userDefaults.bool(forKey: Self.hasCoverArtOnlyKey) }

    func saveMultiFileOnly(_ value: Bool) { userDefaults.set(value, forKey: Self.multiFileOnlyKey) }
    func loadMultiFileOnly() -> Bool { userDefaults.bool(forKey: Self.multiFileOnlyKey) }

    func saveDurationFilters(_ buckets: [String]) {
        if buckets.isEmpty {
            userDefaults.removeObject(forKey: Self.durationFiltersKey)
        } else {
            userDefaults.set(buckets, forKey: Self.durationFiltersKey)
        }
    }

    func loadDurationFilters() -> [String]? { userDefaults.stringArray(forKey: Self.durationFiltersKey) }

    func saveAuthorFilters(_ authors: [String]) {
        if authors.isEmpty {
            userDefaults.removeObject(forKey: Self.authorFiltersKey)
        } else {
            userDefaults.set(authors, forKey: Self.authorFiltersKey)
        }
    }

    func loadAuthorFilters() -> [String]? { userDefaults.stringArray(forKey: Self.authorFiltersKey) }

    func saveGenreFilters(_ genres: [String]) {
        if genres.isEmpty {
            userDefaults.removeObject(forKey: Self.genreFiltersKey)
        } else {
            userDefaults.set(genres, forKey: Self.genreFiltersKey)
        }
    }

    func loadGenreFilters() -> [String]? { userDefaults.stringArray(forKey: Self.genreFiltersKey) }

    func saveSeriesFilters(_ series: [String]) {
        if series.isEmpty {
            userDefaults.removeObject(forKey: Self.seriesFiltersKey)
        } else {
            userDefaults.set(series, forKey: Self.seriesFiltersKey)
        }
    }

    func loadSeriesFilters() -> [String]? { userDefaults.stringArray(forKey: Self.seriesFiltersKey) }

    func saveRecentlyAddedDays(_ days: Int?) {
        if let days, days > 0 {
            userDefaults.set(days, forKey: Self.recentlyAddedDaysKey)
        } else {
            userDefaults.removeObject(forKey: Self.recentlyAddedDaysKey)
        }
    }

    func loadRecentlyAddedDays() -> Int? {
        let value = userDefaults.integer(forKey: Self.recentlyAddedDaysKey)
        return value > 0 ? value : nil
    }

    func saveBrowseSegment(_ segment: BrowseSegment) {
        userDefaults.set(segment.rawValue, forKey: Self.browseSegmentKey)
    }

    func loadBrowseSegment() -> BrowseSegment {
        if let rawValue = userDefaults.string(forKey: Self.browseSegmentKey),
            let segment = BrowseSegment(rawValue: rawValue)
        {
            return segment
        }
        return .authors
    }

    func saveSeriesSortOption(_ option: SeriesSortOption) {
        userDefaults.set(option.rawValue, forKey: Self.seriesSortOptionKey)
    }

    func loadSeriesSortOption() -> SeriesSortOption {
        if let rawValue = userDefaults.string(forKey: Self.seriesSortOptionKey),
            let option = SeriesSortOption(rawValue: rawValue)
        {
            return option
        }
        return .name
    }

    func saveSeriesSortDirection(_ direction: SortDirection) {
        userDefaults.set(direction.rawValue, forKey: Self.seriesSortDirectionKey)
    }

    func loadSeriesSortDirection() -> SortDirection {
        if let rawValue = userDefaults.string(forKey: Self.seriesSortDirectionKey),
            let direction = SortDirection(rawValue: rawValue)
        {
            return direction
        }
        return .ascending
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
