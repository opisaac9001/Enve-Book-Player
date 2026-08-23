import CryptoKit
import Foundation

enum ServerMirrorDomain: String, Codable, Sendable {
    case catalog
    case activity
    case collections
}

enum ServerMirrorSyncLevel: String, Codable, Sendable {
    case nativeCursorDelta
    case revisionSnapshot
    case fullSnapshot
    case boundedWindow
}

struct ServerMirrorScope: Codable, Hashable, Sendable {
    let connectionId: UUID
    let accountKey: String
    let libraryId: String?
    let domain: ServerMirrorDomain
}

struct ServerMirrorCheckpoint: Codable, Equatable, Sendable {
    let scope: ServerMirrorScope
    let syncLevel: ServerMirrorSyncLevel
    let cursor: String?
    let fingerprint: String
    let itemCount: Int
    let completedAt: Date
}

@MainActor
@Observable
final class ServerMirrorCheckpointStore {
    static let shared = ServerMirrorCheckpointStore()

    @ObservationIgnored private static let storageKey = "serverMirrorCheckpoints.v1"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var checkpoints: [ServerMirrorScope: ServerMirrorCheckpoint] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([ServerMirrorScope: ServerMirrorCheckpoint].self, from: data)
        else { return }
        checkpoints = decoded
    }

    func checkpoint(for scope: ServerMirrorScope) -> ServerMirrorCheckpoint? {
        checkpoints[scope]
    }

    func needsRefresh(
        scope: ServerMirrorScope,
        after interval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let checkpoint = checkpoints[scope] else { return true }
        return now.timeIntervalSince(checkpoint.completedAt) >= interval
    }

    func commit(
        scope: ServerMirrorScope,
        syncLevel: ServerMirrorSyncLevel,
        cursor: String? = nil,
        fingerprint: String,
        itemCount: Int,
        completedAt: Date = Date()
    ) {
        checkpoints[scope] = ServerMirrorCheckpoint(
            scope: scope,
            syncLevel: syncLevel,
            cursor: cursor,
            fingerprint: fingerprint,
            itemCount: itemCount,
            completedAt: completedAt
        )
        persist()
    }

    func commitCompleteSnapshot(
        scope: ServerMirrorScope,
        syncLevel: ServerMirrorSyncLevel,
        cursor: String? = nil,
        fingerprint: String,
        itemCount: Int,
        completedAt: Date = Date()
    ) {
        commit(
            scope: scope,
            syncLevel: syncLevel,
            cursor: cursor,
            fingerprint: fingerprint,
            itemCount: itemCount,
            completedAt: completedAt
        )
    }

    func retainConnections(_ connectionIds: Set<UUID>) {
        let previousCount = checkpoints.count
        checkpoints = checkpoints.filter { connectionIds.contains($0.key.connectionId) }
        if checkpoints.count != previousCount {
            persist()
        }
    }

    func clearAll() {
        checkpoints.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(checkpoints) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum ServerMirrorFingerprint {
    private struct CanonicalCatalogBook: Encodable {
        let uniqueId: String
        let title: String
        let author: String?
        let authors: [String]
        let narrator: String?
        let coverURL: String?
        let duration: TimeInterval?
        let mediaType: String
        let ebookFormat: String?
        let description: String?
        let series: String?
        let seriesSequence: String?
        let publishedYear: Int?
        let personalRating: Double?
        let genres: [String]
        let dateAdded: Date?
        let language: String?
        let hasAlternateFormat: Bool
        let hasMediaOverlay: Bool
    }

    private struct CanonicalCollection: Encodable {
        let providerId: String
        let id: String
        let name: String
        let description: String?
        let books: [String]
        let bookCount: Int
        let iconName: String
        let color: String
        let parentID: String?
        let remoteId: String?
        let serverIcon: String?
        let syncToKobo: Bool
        let displayOrder: Int
        let isServerEditable: Bool
    }

    static func accountKey(for connection: ServerConnection) -> String {
        let identity =
            connection.userId
            ?? connection.plexHomeUserId
            ?? connection.username
            ?? "default"
        return digest("\(connection.type.rawValue)\u{0}\(identity)")
    }

    static func accountKey(for connection: ServerConnection, profileId: String) -> String {
        let identity =
            connection.userId
            ?? connection.plexHomeUserId
            ?? connection.username
            ?? "default"
        return digest("\(connection.type.rawValue)\u{0}\(identity)\u{0}\(profileId)")
    }

    nonisolated static func cursor(_ cursor: String) -> String {
        digest(cursor)
    }

    nonisolated static func activity(_ canonicalRows: [String]) -> String {
        digest(canonicalRows.sorted().joined(separator: "\u{0}"))
    }

    nonisolated static func catalogWindow(_ books: [Book]) -> String {
        let rows = books.map {
            "\($0.uniqueId)|\($0.title)|\($0.dateAdded?.timeIntervalSince1970 ?? 0)|\($0.lastUpdate.timeIntervalSince1970)"
        }
        return digest(rows.sorted().joined(separator: "\u{0}"))
    }

    nonisolated static func catalogSnapshot(_ books: [Book]) -> String {
        let canonical =
            books
            .sorted { $0.uniqueId < $1.uniqueId }
            .map {
                CanonicalCatalogBook(
                    uniqueId: $0.uniqueId,
                    title: $0.title,
                    author: $0.author,
                    authors: $0.authors ?? [],
                    narrator: $0.narrator,
                    coverURL: $0.thumb,
                    duration: $0.duration,
                    mediaType: $0.mediaType.rawValue,
                    ebookFormat: $0.ebookFormat,
                    description: $0.description,
                    series: $0.series,
                    seriesSequence: $0.seriesSequence,
                    publishedYear: $0.publishedYear,
                    personalRating: $0.personalRating,
                    genres: ($0.genres ?? []).sorted(),
                    dateAdded: $0.dateAdded,
                    language: $0.language,
                    hasAlternateFormat: $0.hasAlternateFormat,
                    hasMediaOverlay: $0.epub3Features?.hasMediaOverlay == true
                )
            }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return digest((try? encoder.encode(canonical)) ?? Data())
    }

    nonisolated static func collections(_ collections: [Collection]) -> String {
        let canonical =
            collections
            .sorted {
                let lhs = "\($0.providerId?.uuidString ?? "")\u{0}\($0.id)"
                let rhs = "\($1.providerId?.uuidString ?? "")\u{0}\($1.id)"
                return lhs < rhs
            }
            .map {
                CanonicalCollection(
                    providerId: $0.providerId?.uuidString ?? "",
                    id: $0.id,
                    name: $0.name,
                    description: $0.description,
                    books: $0.books,
                    bookCount: $0.bookCount,
                    iconName: $0.iconName,
                    color: $0.color,
                    parentID: $0.parentID,
                    remoteId: $0.remoteId,
                    serverIcon: $0.serverIcon,
                    syncToKobo: $0.syncToKobo,
                    displayOrder: $0.displayOrder,
                    isServerEditable: $0.isServerEditable
                )
            }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest((try? encoder.encode(canonical)) ?? Data())
    }

    nonisolated private static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
