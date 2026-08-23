import Combine
import Foundation
import Logging
import SwiftUI

struct GrimmoryUser: Codable, Sendable {
    let id: Int?
    let username: String?
    let email: String?
    let roles: [String]?
    let permissions: GrimmoryPermissions?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, username, email, roles, permissions, name
    }

    init(id: Int?, username: String?, email: String?, roles: [String]?, permissions: GrimmoryPermissions?, name: String?) {
        self.id = id
        self.username = username
        self.email = email
        self.roles = roles
        self.permissions = permissions
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        roles = try container.decodeIfPresent([String].self, forKey: .roles)
        name = try container.decodeIfPresent(String.self, forKey: .name)

        if let nestedPermissions = try container.decodeIfPresent(GrimmoryPermissions.self, forKey: .permissions) {
            permissions = nestedPermissions
        } else {
            permissions = try? GrimmoryPermissions(from: decoder)
        }
    }

    var isAdmin: Bool {
        if let perms = permissions, perms.isAdmin == true { return true }
        return roles?.contains(where: { $0.lowercased() == "admin" || $0.lowercased() == "role_admin" }) ?? false
    }

    var displayName: String {
        name ?? username ?? email ?? "Unknown User"
    }
}

struct GrimmoryPermissions: Codable, Sendable {
    var isAdmin: Bool?
    var canUpload: Bool?
    var canDownload: Bool?
    var canEditMetadata: Bool?
    var canManageLibrary: Bool?
    var canDeleteBook: Bool?
    var canEmailBook: Bool?
    var canAccessOpds: Bool?
    var canAccessBookdrop: Bool?
    var canAccessLibraryStats: Bool?
    var canAccessUserStats: Bool?
    var canAccessTaskManager: Bool?
    var canSyncKoReader: Bool?
    var canSyncKobo: Bool?
    var canManageMetadataConfig: Bool?
    var canManageGlobalPreferences: Bool?
    var canManageIcons: Bool?
    var canManageFonts: Bool?
    var canBulkAutoFetchMetadata: Bool?
    var canBulkCustomFetchMetadata: Bool?
    var canBulkEditMetadata: Bool?
    var canBulkRegenerateCover: Bool?
    var canMoveOrganizeFiles: Bool?
    var canBulkLockUnlockMetadata: Bool?
    var canBulkResetBookloreReadProgress: Bool?
    var canBulkResetKoReaderReadProgress: Bool?
    var canBulkResetBookReadStatus: Bool?

    enum CodingKeys: String, CodingKey {
        case isAdmin
        case admin
        case permissionAdmin
        case canUpload
        case permissionUpload
        case canDownload
        case permissionDownload
        case canEditMetadata
        case permissionEditMetadata
        case canManageLibrary
        case permissionManageLibrary
        case canDeleteBook
        case permissionDeleteBook
        case canEmailBook
        case permissionEmailBook
        case canAccessOpds
        case permissionAccessOpds
        case canAccessBookdrop
        case permissionAccessBookdrop
        case canAccessLibraryStats
        case permissionAccessLibraryStats
        case canAccessUserStats
        case permissionAccessUserStats
        case canAccessTaskManager
        case permissionAccessTaskManager
        case canSyncKoReader
        case permissionSyncKoreader
        case canSyncKobo
        case permissionSyncKobo
        case canManageMetadataConfig
        case permissionManageMetadataConfig
        case canManageGlobalPreferences
        case permissionManageGlobalPreferences
        case canManageIcons
        case permissionManageIcons
        case canManageFonts
        case permissionManageFonts
        case canBulkAutoFetchMetadata
        case permissionBulkAutoFetchMetadata
        case canBulkCustomFetchMetadata
        case permissionBulkCustomFetchMetadata
        case canBulkEditMetadata
        case permissionBulkEditMetadata
        case canBulkRegenerateCover
        case permissionBulkRegenerateCover
        case canMoveOrganizeFiles
        case permissionMoveOrganizeFiles
        case canBulkLockUnlockMetadata
        case permissionBulkLockUnlockMetadata
        case canBulkResetBookloreReadProgress
        case permissionBulkResetBookloreReadProgress
        case canBulkResetKoReaderReadProgress
        case permissionBulkResetKoReaderReadProgress
        case canBulkResetBookReadStatus
        case permissionBulkResetBookReadStatus
    }

    init(
        isAdmin: Bool? = nil,
        canUpload: Bool? = nil,
        canDownload: Bool? = nil,
        canEditMetadata: Bool? = nil,
        canManageLibrary: Bool? = nil,
        canDeleteBook: Bool? = nil,
        canEmailBook: Bool? = nil,
        canAccessOpds: Bool? = nil,
        canAccessBookdrop: Bool? = nil,
        canAccessLibraryStats: Bool? = nil,
        canAccessUserStats: Bool? = nil,
        canAccessTaskManager: Bool? = nil,
        canSyncKoReader: Bool? = nil,
        canSyncKobo: Bool? = nil,
        canManageMetadataConfig: Bool? = nil,
        canManageGlobalPreferences: Bool? = nil,
        canManageIcons: Bool? = nil,
        canManageFonts: Bool? = nil,
        canBulkAutoFetchMetadata: Bool? = nil,
        canBulkCustomFetchMetadata: Bool? = nil,
        canBulkEditMetadata: Bool? = nil,
        canBulkRegenerateCover: Bool? = nil,
        canMoveOrganizeFiles: Bool? = nil,
        canBulkLockUnlockMetadata: Bool? = nil,
        canBulkResetBookloreReadProgress: Bool? = nil,
        canBulkResetKoReaderReadProgress: Bool? = nil,
        canBulkResetBookReadStatus: Bool? = nil
    ) {
        self.isAdmin = isAdmin; self.canUpload = canUpload; self.canDownload = canDownload
        self.canEditMetadata = canEditMetadata; self.canManageLibrary = canManageLibrary
        self.canDeleteBook = canDeleteBook; self.canEmailBook = canEmailBook
        self.canAccessOpds = canAccessOpds; self.canAccessBookdrop = canAccessBookdrop
        self.canAccessLibraryStats = canAccessLibraryStats; self.canAccessUserStats = canAccessUserStats
        self.canAccessTaskManager = canAccessTaskManager; self.canSyncKoReader = canSyncKoReader
        self.canSyncKobo = canSyncKobo; self.canManageMetadataConfig = canManageMetadataConfig
        self.canManageGlobalPreferences = canManageGlobalPreferences; self.canManageIcons = canManageIcons
        self.canManageFonts = canManageFonts; self.canBulkAutoFetchMetadata = canBulkAutoFetchMetadata
        self.canBulkCustomFetchMetadata = canBulkCustomFetchMetadata
        self.canBulkEditMetadata = canBulkEditMetadata; self.canBulkRegenerateCover = canBulkRegenerateCover
        self.canMoveOrganizeFiles = canMoveOrganizeFiles
        self.canBulkLockUnlockMetadata = canBulkLockUnlockMetadata
        self.canBulkResetBookloreReadProgress = canBulkResetBookloreReadProgress
        self.canBulkResetKoReaderReadProgress = canBulkResetKoReaderReadProgress
        self.canBulkResetBookReadStatus = canBulkResetBookReadStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAdmin =
            try container.decodeIfPresent(Bool.self, forKey: .isAdmin)
            ?? container.decodeIfPresent(Bool.self, forKey: .admin)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionAdmin)
        canUpload =
            try container.decodeIfPresent(Bool.self, forKey: .canUpload)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionUpload)
        canDownload =
            try container.decodeIfPresent(Bool.self, forKey: .canDownload)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionDownload)
        canEditMetadata =
            try container.decodeIfPresent(Bool.self, forKey: .canEditMetadata)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionEditMetadata)
        canManageLibrary =
            try container.decodeIfPresent(Bool.self, forKey: .canManageLibrary)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionManageLibrary)
        canDeleteBook =
            try container.decodeIfPresent(Bool.self, forKey: .canDeleteBook)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionDeleteBook)
        canEmailBook =
            try container.decodeIfPresent(Bool.self, forKey: .canEmailBook)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionEmailBook)
        canAccessOpds =
            try container.decodeIfPresent(Bool.self, forKey: .canAccessOpds)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionAccessOpds)
        canAccessBookdrop =
            try container.decodeIfPresent(Bool.self, forKey: .canAccessBookdrop)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionAccessBookdrop)
        canAccessLibraryStats =
            try container.decodeIfPresent(Bool.self, forKey: .canAccessLibraryStats)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionAccessLibraryStats)
        canAccessUserStats =
            try container.decodeIfPresent(Bool.self, forKey: .canAccessUserStats)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionAccessUserStats)
        canAccessTaskManager =
            try container.decodeIfPresent(Bool.self, forKey: .canAccessTaskManager)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionAccessTaskManager)
        canSyncKoReader =
            try container.decodeIfPresent(Bool.self, forKey: .canSyncKoReader)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionSyncKoreader)
        canSyncKobo =
            try container.decodeIfPresent(Bool.self, forKey: .canSyncKobo)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionSyncKobo)
        canManageMetadataConfig =
            try container.decodeIfPresent(Bool.self, forKey: .canManageMetadataConfig)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionManageMetadataConfig)
        canManageGlobalPreferences =
            try container.decodeIfPresent(Bool.self, forKey: .canManageGlobalPreferences)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionManageGlobalPreferences)
        canManageIcons =
            try container.decodeIfPresent(Bool.self, forKey: .canManageIcons)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionManageIcons)
        canManageFonts =
            try container.decodeIfPresent(Bool.self, forKey: .canManageFonts)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionManageFonts)
        canBulkAutoFetchMetadata =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkAutoFetchMetadata)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkAutoFetchMetadata)
        canBulkCustomFetchMetadata =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkCustomFetchMetadata)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkCustomFetchMetadata)
        canBulkEditMetadata =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkEditMetadata)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkEditMetadata)
        canBulkRegenerateCover =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkRegenerateCover)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkRegenerateCover)
        canMoveOrganizeFiles =
            try container.decodeIfPresent(Bool.self, forKey: .canMoveOrganizeFiles)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionMoveOrganizeFiles)
        canBulkLockUnlockMetadata =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkLockUnlockMetadata)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkLockUnlockMetadata)
        canBulkResetBookloreReadProgress =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkResetBookloreReadProgress)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkResetBookloreReadProgress)
        canBulkResetKoReaderReadProgress =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkResetKoReaderReadProgress)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkResetKoReaderReadProgress)
        canBulkResetBookReadStatus =
            try container.decodeIfPresent(Bool.self, forKey: .canBulkResetBookReadStatus)
            ?? container.decodeIfPresent(Bool.self, forKey: .permissionBulkResetBookReadStatus)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(isAdmin, forKey: .isAdmin)
        try container.encodeIfPresent(canUpload, forKey: .canUpload)
        try container.encodeIfPresent(canDownload, forKey: .canDownload)
        try container.encodeIfPresent(canEditMetadata, forKey: .canEditMetadata)
        try container.encodeIfPresent(canManageLibrary, forKey: .canManageLibrary)
        try container.encodeIfPresent(canDeleteBook, forKey: .canDeleteBook)
        try container.encodeIfPresent(canEmailBook, forKey: .canEmailBook)
        try container.encodeIfPresent(canAccessOpds, forKey: .canAccessOpds)
        try container.encodeIfPresent(canAccessBookdrop, forKey: .canAccessBookdrop)
        try container.encodeIfPresent(canAccessLibraryStats, forKey: .canAccessLibraryStats)
        try container.encodeIfPresent(canAccessUserStats, forKey: .canAccessUserStats)
        try container.encodeIfPresent(canAccessTaskManager, forKey: .canAccessTaskManager)
        try container.encodeIfPresent(canSyncKoReader, forKey: .canSyncKoReader)
        try container.encodeIfPresent(canSyncKobo, forKey: .canSyncKobo)
        try container.encodeIfPresent(canManageMetadataConfig, forKey: .canManageMetadataConfig)
        try container.encodeIfPresent(canManageGlobalPreferences, forKey: .canManageGlobalPreferences)
        try container.encodeIfPresent(canManageIcons, forKey: .canManageIcons)
        try container.encodeIfPresent(canManageFonts, forKey: .canManageFonts)
        try container.encodeIfPresent(canBulkAutoFetchMetadata, forKey: .canBulkAutoFetchMetadata)
        try container.encodeIfPresent(canBulkCustomFetchMetadata, forKey: .canBulkCustomFetchMetadata)
        try container.encodeIfPresent(canBulkEditMetadata, forKey: .canBulkEditMetadata)
        try container.encodeIfPresent(canBulkRegenerateCover, forKey: .canBulkRegenerateCover)
        try container.encodeIfPresent(canMoveOrganizeFiles, forKey: .canMoveOrganizeFiles)
        try container.encodeIfPresent(canBulkLockUnlockMetadata, forKey: .canBulkLockUnlockMetadata)
        try container.encodeIfPresent(canBulkResetBookloreReadProgress, forKey: .canBulkResetBookloreReadProgress)
        try container.encodeIfPresent(canBulkResetKoReaderReadProgress, forKey: .canBulkResetKoReaderReadProgress)
        try container.encodeIfPresent(canBulkResetBookReadStatus, forKey: .canBulkResetBookReadStatus)
    }
}

struct GrimmoryManagedUser: Codable, Identifiable, Sendable {
    var id: Int { _id }
    let _id: Int
    let username: String?
    let name: String?
    let email: String?
    let permissions: GrimmoryPermissions?
    let provisioningMethod: String?
    let isDefaultPassword: Bool?
    let assignedLibraries: [Int]?
    let selectedLibraries: [Int]?

    var effectiveAssignedLibraries: [Int]? {
        assignedLibraries ?? selectedLibraries
    }

    var displayName: String { name ?? username ?? "User \(_id)" }
    var isAdmin: Bool { permissions?.isAdmin == true }

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case username, name, email, permissions, provisioningMethod, isDefaultPassword, assignedLibraries, selectedLibraries
    }

    private struct LibraryRef: Decodable {
        let id: Int
    }

    private enum WireKeys: String, CodingKey {
        case defaultPassword
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(Int.self, forKey: ._id)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        permissions = try container.decodeIfPresent(GrimmoryPermissions.self, forKey: .permissions)
        provisioningMethod = try container.decodeIfPresent(String.self, forKey: .provisioningMethod)
        isDefaultPassword =
            try container.decodeIfPresent(Bool.self, forKey: .isDefaultPassword)
            ?? decoder.container(keyedBy: WireKeys.self).decodeIfPresent(Bool.self, forKey: .defaultPassword)
        assignedLibraries = Self.decodeLibraryIds(container, forKey: .assignedLibraries)
        selectedLibraries = Self.decodeLibraryIds(container, forKey: .selectedLibraries)
    }

    private static func decodeLibraryIds(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [Int]? {
        if let ids = try? container.decode([Int].self, forKey: key) { return ids }
        if let refs = try? container.decode([LibraryRef].self, forKey: key) { return refs.map(\.id) }
        return nil
    }
}

struct GrimmoryCreateUserRequest: Codable, Sendable {
    let username: String
    let password: String
    let name: String
    let email: String
    var permissionAdmin: Bool = false
    var permissionUpload: Bool = false
    var permissionDownload: Bool = true
    var permissionEditMetadata: Bool = false
    var permissionManageLibrary: Bool = false
    var permissionDeleteBook: Bool = false
    var permissionEmailBook: Bool = false
    var permissionAccessOpds: Bool = true
    var permissionAccessBookdrop: Bool = false
    var permissionAccessLibraryStats: Bool = false
    var permissionAccessUserStats: Bool = false
    var permissionAccessTaskManager: Bool = false
    var permissionSyncKoreader: Bool = false
    var permissionSyncKobo: Bool = false
    var permissionManageMetadataConfig: Bool = false
    var permissionManageGlobalPreferences: Bool = false
    var permissionManageIcons: Bool = false
    var permissionManageFonts: Bool = false
    var permissionBulkAutoFetchMetadata: Bool = false
    var permissionBulkCustomFetchMetadata: Bool = false
    var permissionBulkEditMetadata: Bool = false
    var permissionBulkRegenerateCover: Bool = false
    var permissionMoveOrganizeFiles: Bool = false
    var permissionBulkLockUnlockMetadata: Bool = false
    var permissionBulkResetBookloreReadProgress: Bool = false
    var permissionBulkResetKoReaderReadProgress: Bool = false
    var permissionBulkResetBookReadStatus: Bool = false
    var selectedLibraries: [Int]?
}

struct GrimmoryUpdateUserRequest: Codable, Sendable {
    var name: String?
    var email: String?
    var permissions: GrimmoryUpdatePermissions?
    var assignedLibraries: [Int]?
}

struct GrimmoryUpdatePermissions: Codable, Sendable {
    var isAdmin: Bool?
    var canUpload: Bool?
    var canDownload: Bool?
    var canEditMetadata: Bool?
    var canManageLibrary: Bool?
    var canDeleteBook: Bool?
    var canEmailBook: Bool?
    var canAccessOpds: Bool?
    var canAccessBookdrop: Bool?
    var canAccessLibraryStats: Bool?
    var canAccessUserStats: Bool?
    var canAccessTaskManager: Bool?
    var canSyncKoReader: Bool?
    var canSyncKobo: Bool?
    var canManageMetadataConfig: Bool?
    var canManageGlobalPreferences: Bool?
    var canManageIcons: Bool?
    var canManageFonts: Bool?
    var canBulkAutoFetchMetadata: Bool?
    var canBulkCustomFetchMetadata: Bool?
    var canBulkEditMetadata: Bool?
    var canBulkRegenerateCover: Bool?
    var canMoveOrganizeFiles: Bool?
    var canBulkLockUnlockMetadata: Bool?
    var canBulkResetBookloreReadProgress: Bool?
    var canBulkResetKoReaderReadProgress: Bool?
    var canBulkResetBookReadStatus: Bool?

    enum CodingKeys: String, CodingKey {

        case isAdmin = "admin"
        case canUpload, canDownload, canEditMetadata, canManageLibrary, canDeleteBook,
            canEmailBook, canAccessOpds, canAccessBookdrop, canAccessLibraryStats,
            canAccessUserStats, canAccessTaskManager, canSyncKoReader, canSyncKobo,
            canManageMetadataConfig, canManageGlobalPreferences, canManageIcons, canManageFonts,
            canBulkAutoFetchMetadata, canBulkCustomFetchMetadata, canBulkEditMetadata,
            canBulkRegenerateCover, canMoveOrganizeFiles, canBulkLockUnlockMetadata,
            canBulkResetBookloreReadProgress, canBulkResetKoReaderReadProgress, canBulkResetBookReadStatus
    }
}

struct GrimmoryLibrarySummary: Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
}

struct GrimmoryShelf: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let bookCount: Int?
    let icon: String?
    let publicShelf: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, publicShelf, bookCount, numberOfBooks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookCount =
            try container.decodeIfPresent(Int.self, forKey: .bookCount)
            ?? container.decodeIfPresent(Int.self, forKey: .numberOfBooks)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        publicShelf = try container.decodeIfPresent(Bool.self, forKey: .publicShelf)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(bookCount, forKey: .bookCount)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(publicShelf, forKey: .publicShelf)
    }

    init(id: Int, name: String, bookCount: Int?, icon: String? = nil, publicShelf: Bool? = nil) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
        self.icon = icon
        self.publicShelf = publicShelf
    }
}

struct GrimmoryMagicShelf: Codable, Identifiable, Sendable {
    var id: Int?
    var name: String
    var icon: String?
    var iconType: String?
    var filterJson: String
    var isPublic: Bool?

    static func buildFilterJson(join: String, rules: [MagicShelfRule]) -> String {
        let rulesDicts: [[String: Any]] = rules.map { rule in
            var dict: [String: Any] = [
                "type": "rule",
                "field": rule.field,
                "operator": rule.op,
            ]
            if let v = rule.value { dict["value"] = v }
            if let vs = rule.valueStart { dict["valueStart"] = vs }
            if let ve = rule.valueEnd { dict["valueEnd"] = ve }
            return dict
        }
        let root: [String: Any] = [
            "type": "group",
            "join": join,
            "rules": rulesDicts,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}

struct MagicShelfRule: Identifiable {
    let id = UUID()
    var field: String
    var op: String
    var value: String?
    var valueStart: String?
    var valueEnd: String?
}

enum MagicShelfField: String, CaseIterable, Identifiable {
    case library, shelf, readStatus, readingProgress
    case title, subtitle, description, authors, categories, publisher, language, pageCount, ageRating, contentRating
    case seriesName, seriesNumber, seriesTotal, seriesStatus, seriesGaps, seriesPosition
    case publishedDate, dateFinished, lastReadTime, addedOn
    case personalRating, amazonRating, amazonReviewCount, goodreadsRating, goodreadsReviewCount
    case hardcoverRating, hardcoverReviewCount, ranobedbRating, lubimyczytacRating
    case audibleRating, audibleReviewCount
    case metadataScore, metadataPresence
    case tags, moods, genre
    case narrator, abridged, audiobookDuration, audiobookCodec, audiobookChapterCount, audiobookBitrate
    case fileType, fileSize, isbn13, isbn10, isPhysical

    var id: String { rawValue }

    var group: String {
        switch self {
        case .library, .shelf, .readStatus, .readingProgress: return "Organization"
        case .title, .subtitle, .description, .authors, .categories, .publisher, .language, .pageCount, .ageRating, .contentRating:
            return "Book Info"
        case .seriesName, .seriesNumber, .seriesTotal, .seriesStatus, .seriesGaps, .seriesPosition: return "Series"
        case .publishedDate, .dateFinished, .lastReadTime, .addedOn: return "Dates"
        case .personalRating, .amazonRating, .amazonReviewCount, .goodreadsRating, .goodreadsReviewCount,
            .hardcoverRating, .hardcoverReviewCount, .ranobedbRating, .lubimyczytacRating,
            .audibleRating, .audibleReviewCount:
            return "Ratings & Reviews"
        case .metadataScore, .metadataPresence: return "Quality & Metadata"
        case .tags, .moods, .genre: return "Tags & Moods"
        case .narrator, .abridged, .audiobookDuration, .audiobookCodec, .audiobookChapterCount, .audiobookBitrate: return "Audiobook"
        case .fileType, .fileSize, .isbn13, .isbn10, .isPhysical: return "File & Identifiers"
        }
    }

    static var groupedFields: [(group: String, fields: [MagicShelfField])] {
        let order = [
            "Organization", "Book Info", "Series", "Dates", "Ratings & Reviews",
            "Quality & Metadata", "Tags & Moods", "Audiobook", "File & Identifiers",
        ]
        var dict: [String: [MagicShelfField]] = [:]
        for f in allCases { dict[f.group, default: []].append(f) }
        return order.compactMap { g in dict[g].map { (g, $0) } }
    }

    var displayName: String {
        switch self {
        case .library: return "Library"
        case .shelf: return "Shelf"
        case .readStatus: return "Read Status"
        case .readingProgress: return "Reading Progress (%)"
        case .title: return "Title"
        case .subtitle: return "Subtitle"
        case .description: return "Description"
        case .authors: return "Authors"
        case .categories: return "Categories"
        case .publisher: return "Publisher"
        case .language: return "Language"
        case .pageCount: return "Page Count"
        case .ageRating: return "Age Rating"
        case .contentRating: return "Content Rating"
        case .seriesName: return "Series Name"
        case .seriesNumber: return "Series Number"
        case .seriesTotal: return "Books in Series"
        case .seriesStatus: return "Series Status"
        case .seriesGaps: return "Series Gaps"
        case .seriesPosition: return "Series Position"
        case .publishedDate: return "Published Date"
        case .dateFinished: return "Date Finished"
        case .lastReadTime: return "Last Read"
        case .addedOn: return "Date Added"
        case .personalRating: return "Your Rating"
        case .amazonRating: return "Amazon Rating"
        case .amazonReviewCount: return "Amazon Reviews"
        case .goodreadsRating: return "Goodreads Rating"
        case .goodreadsReviewCount: return "Goodreads Reviews"
        case .hardcoverRating: return "Hardcover Rating"
        case .hardcoverReviewCount: return "Hardcover Reviews"
        case .ranobedbRating: return "Ranobedb Rating"
        case .lubimyczytacRating: return "Lubimyczytac Rating"
        case .audibleRating: return "Audible Rating"
        case .audibleReviewCount: return "Audible Reviews"
        case .metadataScore: return "Metadata Score"
        case .metadataPresence: return "Metadata Presence"
        case .tags: return "Tags"
        case .moods: return "Moods"
        case .genre: return "Genre"
        case .narrator: return "Narrator"
        case .abridged: return "Abridged"
        case .audiobookDuration: return "Duration (sec)"
        case .audiobookCodec: return "Codec"
        case .audiobookChapterCount: return "Chapter Count"
        case .audiobookBitrate: return "Bitrate (kbps)"
        case .fileType: return "File Type"
        case .fileSize: return "File Size (KB)"
        case .isbn13: return "ISBN-13"
        case .isbn10: return "ISBN-10"
        case .isPhysical: return "Physical Book"
        }
    }

    var fieldType: MagicShelfFieldType {
        switch self {
        case .title, .subtitle, .description, .authors, .categories, .publisher, .language,
            .narrator, .tags, .moods, .genre, .isbn13, .isbn10, .audiobookCodec,
            .ageRating, .contentRating, .seriesName:
            return .text
        case .readStatus, .fileType, .seriesStatus, .metadataPresence:
            return .enumeration
        case .library, .shelf:
            return .reference
        case .pageCount, .personalRating, .amazonRating, .amazonReviewCount,
            .goodreadsRating, .goodreadsReviewCount, .hardcoverRating, .hardcoverReviewCount,
            .ranobedbRating, .lubimyczytacRating, .audibleRating, .audibleReviewCount,
            .metadataScore, .audiobookDuration, .audiobookChapterCount, .audiobookBitrate,
            .fileSize, .seriesNumber, .seriesTotal, .seriesGaps, .seriesPosition, .readingProgress:
            return .numeric
        case .addedOn, .lastReadTime, .dateFinished, .publishedDate:
            return .date
        case .abridged, .isPhysical:
            return .boolean
        }
    }
}

enum MagicShelfFieldType {
    case text, numeric, date, boolean, enumeration, reference
}

enum MagicShelfOperator: String, CaseIterable, Identifiable {
    case equals, not_equals, contains, does_not_contain
    case starts_with, ends_with
    case greater_than, greater_than_equal_to, less_than, less_than_equal_to
    case in_between, is_empty, is_not_empty
    case includes_any, excludes_all, includes_all
    case within_last, older_than, this_period

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equals: return "Equals"
        case .not_equals: return "Not Equals"
        case .contains: return "Contains"
        case .does_not_contain: return "Doesn't Contain"
        case .starts_with: return "Starts With"
        case .ends_with: return "Ends With"
        case .greater_than: return "Greater Than"
        case .greater_than_equal_to: return "≥"
        case .less_than: return "Less Than"
        case .less_than_equal_to: return "≤"
        case .in_between: return "Between"
        case .is_empty: return "Is Empty"
        case .is_not_empty: return "Is Not Empty"
        case .includes_any: return "Includes Any"
        case .excludes_all: return "Excludes All"
        case .includes_all: return "Includes All"
        case .within_last: return "Within Last"
        case .older_than: return "Older Than"
        case .this_period: return "This Period"
        }
    }

    static func applicableOperators(for field: MagicShelfField) -> [MagicShelfOperator] {
        switch field.fieldType {
        case .text:
            return [
                .equals, .not_equals, .contains, .does_not_contain, .starts_with, .ends_with, .is_empty, .is_not_empty, .includes_any,
                .excludes_all, .includes_all,
            ]
        case .numeric:
            return [
                .equals, .not_equals, .greater_than, .greater_than_equal_to, .less_than, .less_than_equal_to, .in_between, .is_empty,
                .is_not_empty,
            ]
        case .date:
            return [.within_last, .older_than, .this_period, .in_between, .is_empty, .is_not_empty]
        case .boolean:
            return [.equals, .not_equals]
        case .enumeration:
            return [.equals, .not_equals, .includes_any, .excludes_all, .is_empty, .is_not_empty]
        case .reference:
            return [.equals, .not_equals, .includes_any, .excludes_all]
        }
    }
}

struct GrimmoryReadingSessionEntry: Codable, Identifiable, Sendable {
    var id: String { "\(bookId)-\(startTime)" }
    let bookId: Int
    let bookTitle: String?
    let bookType: String?
    let startTime: String
    let endTime: String?
    let durationSeconds: Int?
    let durationFormatted: String?
    let startProgress: Double?
    let endProgress: Double?
    let progressDelta: Double?
}

struct GrimmoryRecentBook: Codable, Identifiable, Sendable {
    var id: String { String(bookId) }
    let bookId: Int
    let title: String
    let author: String?
    let readProgress: Double?
    let lastReadTime: String?
    let readStatus: String?
    let coverURL: String?
}
