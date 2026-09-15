import Foundation
import Observation

struct RejectedContentCandidate: Equatable, Sendable {
    let itemIdentifier: String?
    let title: String?
    let reason: String
    let fallbackIdentifier: String
}

struct LossyDecodableArray<Element: Decodable>: Decodable {
    let values: [Element]
    let rejectedItems: [RejectedContentCandidate]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        var rejectedItems: [RejectedContentCandidate] = []
        var index = 0

        while !container.isAtEnd {
            let decoded = try container.decode(RejectedDecodable<Element>.self)
            if let value = decoded.value {
                values.append(value)
            } else if let rejection = decoded.rejection {
                rejectedItems.append(
                    RejectedContentCandidate(
                        itemIdentifier: rejection.itemIdentifier,
                        title: rejection.title,
                        reason: rejection.reason,
                        fallbackIdentifier: "item-\(index)"
                    )
                )
            }
            index += 1
        }

        self.values = values
        self.rejectedItems = rejectedItems
    }
}

struct RejectedDecodable<Element: Decodable>: Decodable {
    let value: Element?
    let rejection: RejectedContentFailure?

    init(from decoder: Decoder) throws {
        let identity = try? RejectedContentIdentity(from: decoder)
        do {
            value = try Element(from: decoder)
            rejection = nil
        } catch {
            value = nil
            rejection = RejectedContentFailure(
                itemIdentifier: identity?.itemIdentifier,
                title: identity?.title,
                reason: RejectedContentFailure.describe(error)
            )
        }
    }
}

struct RejectedContentFailure: Sendable {
    let itemIdentifier: String?
    let title: String?
    let reason: String

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "Missing \(key.stringValue) at \(location(context.codingPath))."
        case DecodingError.typeMismatch(_, let context):
            return "Unexpected value at \(location(context.codingPath))."
        case DecodingError.valueNotFound(_, let context):
            return "Missing value at \(location(context.codingPath))."
        case DecodingError.dataCorrupted(let context):
            return "Invalid data at \(location(context.codingPath))."
        default:
            return "The source returned an unsupported item format."
        }
    }

    private static func location(_ codingPath: [CodingKey]) -> String {
        let value = codingPath.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "item" : value
    }
}

private struct RejectedContentIdentity: Decodable {
    let itemIdentifier: String?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case id, Id, uuid, key, ratingKey, contentID = "content_id"
        case title, Title, name, Name, media, metadata
    }

    private struct MediaIdentity: Decodable {
        let metadata: MetadataIdentity?
    }

    private struct MetadataIdentity: Decodable {
        let identifier: String?
        let title: String?

        private enum CodingKeys: String, CodingKey {
            case identifier, id, title, name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier =
                (try? container.decode(String.self, forKey: .identifier))
                ?? (try? container.decode(String.self, forKey: .id))
                ?? (try? container.decode(Int.self, forKey: .id)).map(String.init)
            title =
                (try? container.decode(String.self, forKey: .title))
                ?? (try? container.decode(String.self, forKey: .name))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try? container.decode(MetadataIdentity.self, forKey: .metadata)
        itemIdentifier = Self.identifier(in: container) ?? metadata?.identifier
        let media = try? container.decode(MediaIdentity.self, forKey: .media)
        title = Self.string(in: container, keys: [.title, .Title, .name, .Name])
            ?? metadata?.title
            ?? media?.metadata?.title
    }

    private static func identifier(in container: KeyedDecodingContainer<CodingKeys>) -> String? {
        for key in [CodingKeys.id, .Id, .uuid, .ratingKey, .contentID, .key] {
            if let value = try? container.decode(String.self, forKey: key) { return value }
            if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        }
        return nil
    }

    private static func string(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key) { return value }
        }
        return nil
    }
}

struct RejectedContentEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let providerId: UUID
    let providerType: ProviderType
    let sourceName: String
    let libraryId: String
    let itemIdentifier: String?
    let title: String?
    let reason: String
    let firstRejectedAt: Date
    var lastRejectedAt: Date
    var rejectionCount: Int
}

@MainActor
@Observable
final class RejectedContentStore {
    static let shared = RejectedContentStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var entries: [RejectedContentEntry]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "enve.rejectedContent.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode([RejectedContentEntry].self, from: data)
        {
            entries = stored
        } else {
            entries = []
        }
        sortAndLimit()
    }

    func record(
        providerId: UUID,
        providerType: ProviderType,
        sourceName: String,
        libraryId: String,
        candidates: [RejectedContentCandidate],
        at date: Date = .now
    ) {
        guard !candidates.isEmpty else { return }

        for candidate in candidates {
            let itemKey = candidate.itemIdentifier ?? candidate.fallbackIdentifier
            let id = "\(providerId.uuidString)|\(libraryId)|\(itemKey)"
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].lastRejectedAt = date
                entries[index].rejectionCount += 1
            } else {
                entries.append(
                    RejectedContentEntry(
                        id: id,
                        providerId: providerId,
                        providerType: providerType,
                        sourceName: sourceName,
                        libraryId: libraryId,
                        itemIdentifier: candidate.itemIdentifier,
                        title: candidate.title,
                        reason: candidate.reason,
                        firstRejectedAt: date,
                        lastRejectedAt: date,
                        rejectionCount: 1
                    )
                )
            }
        }

        sortAndLimit()
        persist()
    }

    func update(
        connection: ServerConnection,
        libraryId: String,
        acceptedItemIdentifiers: Set<String>,
        rejectedItems: [RejectedContentCandidate],
        fallbackScope: String? = nil
    ) {
        resolve(
            providerId: connection.id,
            libraryId: libraryId,
            itemIdentifiers: acceptedItemIdentifiers
        )
        let scopedItems = rejectedItems.map { candidate in
            RejectedContentCandidate(
                itemIdentifier: candidate.itemIdentifier,
                title: candidate.title,
                reason: candidate.reason,
                fallbackIdentifier: fallbackScope.map { "\($0)-\(candidate.fallbackIdentifier)" }
                    ?? candidate.fallbackIdentifier
            )
        }
        record(
            providerId: connection.id,
            providerType: connection.type,
            sourceName: connection.name,
            libraryId: libraryId,
            candidates: scopedItems
        )
    }

    func resolve(providerId: UUID, libraryId: String, itemIdentifiers: Set<String>) {
        guard !itemIdentifiers.isEmpty else { return }
        let priorCount = entries.count
        entries.removeAll {
            $0.providerId == providerId
                && $0.libraryId == libraryId
                && $0.itemIdentifier.map(itemIdentifiers.contains) == true
        }
        if entries.count != priorCount { persist() }
    }

    func dismiss(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    private func sortAndLimit() {
        entries.sort { $0.lastRejectedAt > $1.lastRejectedAt }
        entries = Array(entries.prefix(200))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
