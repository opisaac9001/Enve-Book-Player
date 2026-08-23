import Foundation
import Logging

struct StorytellerPositionKey: Hashable, Codable, Sendable {
    let providerId: UUID
    let bookId: String

    init(book: Book) {
        providerId = book.providerId
        bookId =
            book.id.hasPrefix("storyalign_")
            ? String(book.id.dropFirst("storyalign_".count))
            : book.id
    }

    init(providerId: UUID, bookId: String) {
        self.providerId = providerId
        self.bookId = bookId
    }

    var storageKey: String {
        "\(providerId.uuidString)|\(bookId)"
    }
}

struct StorytellerSyncedPosition: Codable, Equatable, Sendable {
    let key: StorytellerPositionKey
    let locatorJSON: String
    let timestampMilliseconds: Int

    init?(key: StorytellerPositionKey, locatorJSON: String, timestampMilliseconds: Int) {
        guard timestampMilliseconds > 0,
            let data = locatorJSON.data(using: .utf8),
            let locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            locator["locations"] as? [String: Any] != nil
        else {
            return nil
        }
        self.key = key
        self.locatorJSON = locatorJSON
        self.timestampMilliseconds = timestampMilliseconds
    }

    init?(book: Book, locatorJSON: String, observedAt: Date) {
        self.init(
            key: StorytellerPositionKey(book: book),
            locatorJSON: locatorJSON,
            timestampMilliseconds: Int(observedAt.timeIntervalSince1970 * 1_000)
        )
    }

    var observedAt: Date {
        Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1_000)
    }

    var progression: Double {
        guard let data = locatorJSON.data(using: .utf8),
            let locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = locator["locations"] as? [String: Any]
        else {
            return 0
        }
        let value =
            (locations["totalProgression"] as? NSNumber)?.doubleValue
            ?? (locations["progression"] as? NSNumber)?.doubleValue
            ?? 0
        return min(max(value, 0), 1)
    }

    var storytellerPosition: StorytellerPosition {
        StorytellerPosition(locatorJSONString: locatorJSON, timestamp: timestampMilliseconds)
    }
}

enum StorytellerPositionSendResult: Sendable {
    case accepted
    case conflict(StorytellerSyncedPosition)
}

enum StorytellerPositionSource: Equatable, Sendable {
    case confirmed
    case pending
}

struct StorytellerAuthoritativePosition: Sendable {
    let position: StorytellerSyncedPosition
    let source: StorytellerPositionSource
}

struct StorytellerSnapshotReconciliation: Sendable {
    let authoritative: StorytellerAuthoritativePosition?
    let pushedPendingPosition: Bool
}

func resolveStorytellerPosition(
    localHasPosition: Bool,
    localDate: Date,
    serverHasPosition: Bool,
    serverDate: Date
) -> SyncDirection {
    if !localHasPosition && !serverHasPosition { return .none }
    if !localHasPosition { return .pull }
    if !serverHasPosition { return .push }
    if serverDate > localDate { return .pull }
    if localDate > serverDate { return .push }
    return .none
}

@MainActor
final class StorytellerPositionLedger {
    private struct Slot: Codable {
        var pending: StorytellerSyncedPosition? = nil
        var confirmed: StorytellerSyncedPosition? = nil
    }

    private static let storageKey = "storyteller_position_sync_ledger_v1"

    private let defaults: UserDefaults
    private var slots: [String: Slot]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        slots =
            defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Slot].self, from: $0) }
            ?? [:]
    }

    @discardableResult
    func stage(_ position: StorytellerSyncedPosition) -> Bool {
        var slot = slots[position.key.storageKey] ?? Slot()
        if let pending = slot.pending,
            pending.timestampMilliseconds >= position.timestampMilliseconds
        {
            return false
        }
        if let confirmed = slot.confirmed,
            confirmed.timestampMilliseconds >= position.timestampMilliseconds
        {
            return false
        }
        slot.pending = position
        slots[position.key.storageKey] = slot
        persist()
        return true
    }

    func mergeServer(_ position: StorytellerSyncedPosition) {
        var slot = slots[position.key.storageKey] ?? Slot()
        if position.timestampMilliseconds >= (slot.confirmed?.timestampMilliseconds ?? 0) {
            slot.confirmed = position
        }
        var clearedPending = false
        if let pending = slot.pending,
            position.timestampMilliseconds >= pending.timestampMilliseconds
        {
            slot.pending = nil
            clearedPending = true
        }
        slots[position.key.storageKey] = slot
        if clearedPending {
            persist()
        }
    }

    func reconcileSnapshot(
        _ position: StorytellerSyncedPosition?,
        for key: StorytellerPositionKey
    ) -> StorytellerAuthoritativePosition? {
        guard let slot = slots[key.storageKey] else {
            return position.map {
                StorytellerAuthoritativePosition(position: $0, source: .confirmed)
            }
        }

        if let pending = slot.pending,
            pending.timestampMilliseconds > (position?.timestampMilliseconds ?? 0)
        {
            return StorytellerAuthoritativePosition(position: pending, source: .pending)
        }

        let clearedPending = slot.pending != nil
        slots.removeValue(forKey: key.storageKey)
        if clearedPending {
            persist()
        }
        return position.map {
            StorytellerAuthoritativePosition(position: $0, source: .confirmed)
        }
    }

    func markAccepted(_ position: StorytellerSyncedPosition) {
        var slot = slots[position.key.storageKey] ?? Slot()
        if position.timestampMilliseconds >= (slot.confirmed?.timestampMilliseconds ?? 0) {
            slot.confirmed = position
        }
        let clearedPending = slot.pending?.timestampMilliseconds == position.timestampMilliseconds
        if clearedPending {
            slot.pending = nil
        }
        slots[position.key.storageKey] = slot
        if clearedPending {
            persist()
        }
    }

    func pending(for key: StorytellerPositionKey) -> StorytellerSyncedPosition? {
        slots[key.storageKey]?.pending
    }

    func discard(key: StorytellerPositionKey) {
        guard slots.removeValue(forKey: key.storageKey) != nil else { return }
        persist()
    }

    func authoritative(for key: StorytellerPositionKey) -> StorytellerAuthoritativePosition? {
        guard let slot = slots[key.storageKey] else { return nil }
        if let pending = slot.pending,
            pending.timestampMilliseconds > (slot.confirmed?.timestampMilliseconds ?? 0)
        {
            return StorytellerAuthoritativePosition(position: pending, source: .pending)
        }
        return slot.confirmed.map {
            StorytellerAuthoritativePosition(position: $0, source: .confirmed)
        }
    }

    private func persist() {
        let queued = slots.compactMapValues { slot -> Slot? in
            guard let pending = slot.pending else { return nil }
            return Slot(pending: pending, confirmed: nil)
        }
        guard let data = try? JSONEncoder().encode(queued) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

@MainActor
final class StorytellerPositionSyncService {
    static let shared = StorytellerPositionSyncService(providerResolver: AppState.shared.providerConnections)

    private let ledger: StorytellerPositionLedger
    private let providerResolver: any LibraryProviderResolving

    init(
        ledger: StorytellerPositionLedger = StorytellerPositionLedger(),
        providerResolver: any LibraryProviderResolving
    ) {
        self.ledger = ledger
        self.providerResolver = providerResolver
    }

    func reconcileSnapshot(
        for book: Book,
        through provider: StorytellerProvider
    ) async throws -> StorytellerSnapshotReconciliation {
        guard isValid(book: book, provider: provider) else {
            throw ProviderError.invalidResponse
        }
        let transportBook = transportBook(for: book)
        let key = StorytellerPositionKey(book: transportBook)

        let serverPosition: StorytellerSyncedPosition?
        if let locator = book.epubLocator {
            serverPosition = StorytellerSyncedPosition(
                book: transportBook,
                locatorJSON: locator,
                observedAt: book.lastUpdate
            )
        } else {
            serverPosition = nil
        }
        let snapshotPosition = ledger.reconcileSnapshot(serverPosition, for: key)

        guard let pending = ledger.pending(for: key) else {
            return StorytellerSnapshotReconciliation(
                authoritative: snapshotPosition,
                pushedPendingPosition: false
            )
        }

        _ = try await transmit(
            pending,
            displayBook: book,
            transportBook: transportBook,
            through: provider
        )
        return StorytellerSnapshotReconciliation(
            authoritative: ledger.authoritative(for: key),
            pushedPendingPosition: true
        )
    }

    func authoritativePosition(
        for book: Book,
        through provider: StorytellerProvider
    ) async -> StorytellerAuthoritativePosition? {
        guard isValid(book: book, provider: provider) else { return nil }
        let transportBook = transportBook(for: book)
        let key = StorytellerPositionKey(book: transportBook)

        let server = try? await provider.fetchPipelinePosition(for: transportBook)
        if let server {
            ledger.mergeServer(server)
        }

        if book.isStorytellerReadAloud,
            let current = ledger.authoritative(for: key),
            Self.isAudioLocator(current.position.locatorJSON)
        {
            ledger.discard(key: key)
            if let server {
                ledger.mergeServer(server)
            }
        }

        if let pending = ledger.pending(for: key) {
            do {
                _ = try await transmit(
                    pending,
                    displayBook: book,
                    transportBook: transportBook,
                    through: provider
                )
            } catch {
                AppLogger.sync.debug(
                    "Storyteller position remains queued bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
            }
        }

        return ledger.authoritative(for: key)
    }

    @discardableResult
    func submit(
        book: Book,
        locatorJSON: String,
        observedAt: Date,
        through provider: StorytellerProvider? = nil
    ) async throws -> StorytellerPositionSendResult {
        let provider = provider ?? (providerResolver.provider(for: book) as? StorytellerProvider)
        guard let provider,
            isValid(book: book, provider: provider),
            let position = StorytellerSyncedPosition(
                book: transportBook(for: book),
                locatorJSON: locatorJSON,
                observedAt: observedAt
            )
        else {
            throw ProviderError.invalidResponse
        }
        guard ledger.stage(position) else { return .accepted }
        return try await transmit(
            position,
            displayBook: book,
            transportBook: transportBook(for: book),
            through: provider
        )
    }

    @discardableResult
    func submitAudioPosition(
        book: Book,
        currentTime: TimeInterval,
        observedAt: Date,
        through provider: StorytellerProvider? = nil
    ) async throws -> StorytellerPositionSendResult {
        let provider = provider ?? (providerResolver.provider(for: book) as? StorytellerProvider)
        guard let provider, isValid(book: book, provider: provider) else {
            throw ProviderError.invalidResponse
        }

        guard !book.isStorytellerReadAloud else { return .accepted }

        let locator = try await provider.pipelineAudioLocatorJSONString(
            for: transportBook(for: book),
            currentTime: currentTime
        )
        return try await submit(
            book: book,
            locatorJSON: locator,
            observedAt: observedAt,
            through: provider
        )
    }

    static func isAudioLocator(_ locatorJSON: String) -> Bool {
        guard let data = locatorJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        let type = (json["type"] as? String)?.lowercased() ?? ""
        let href = (json["href"] as? String)?.lowercased() ?? ""
        return type.contains("audio") || href.hasPrefix("audiobook://")
    }

    func reset(
        book: Book,
        observedAt: Date,
        through provider: StorytellerProvider? = nil
    ) async throws {
        guard let locator = StorytellerProvider.readAloudBoundaryLocatorJSONString(progression: 0) else {
            throw ProviderError.invalidResponse
        }
        _ = try await submit(
            book: book,
            locatorJSON: locator,
            observedAt: observedAt,
            through: provider
        )
    }

    func finish(
        book: Book,
        observedAt: Date,
        through provider: StorytellerProvider? = nil
    ) async throws {
        guard let locator = StorytellerProvider.readAloudBoundaryLocatorJSONString(progression: 1) else {
            throw ProviderError.invalidResponse
        }
        _ = try await submit(
            book: book,
            locatorJSON: locator,
            observedAt: observedAt,
            through: provider
        )
    }

    private func transmit(
        _ position: StorytellerSyncedPosition,
        displayBook: Book,
        transportBook: Book,
        through provider: StorytellerProvider
    ) async throws -> StorytellerPositionSendResult {
        let result = try await provider.sendPipelinePosition(position, for: transportBook)
        switch result {
        case .accepted:
            ledger.markAccepted(position)
        case .conflict(let server):
            ledger.mergeServer(server)
            await notifyServerPosition(server, for: displayBook, through: provider)
        }
        return result
    }

    private func notifyServerPosition(
        _ position: StorytellerSyncedPosition,
        for book: Book,
        through provider: StorytellerProvider
    ) async {
        let isAudiobook = book.mediaType == .audiobook && !book.isStorytellerReadAloud
        var userInfo: [String: Any] = [
            "bookId": book.id,
            "providerId": book.providerId,
            "progress": position.progression,
            "locatorJSON": position.locatorJSON,
            "timestamp": position.timestampMilliseconds,
            "progressDomain": isAudiobook ? "audiobook" : "ebook",
        ]
        if isAudiobook,
            let progress = try? await provider.pipelineAudiobookProgress(
                from: position,
                for: transportBook(for: book)
            )
        {
            userInfo["positionSeconds"] = progress.positionSeconds
        }
        NotificationCenter.default.post(
            name: .serverProgressUpdated,
            object: nil,
            userInfo: userInfo
        )
    }

    private func isValid(book: Book, provider: StorytellerProvider) -> Bool {
        book.source == .storyteller && provider.connection.id == book.providerId
    }

    private func transportBook(for book: Book) -> Book {
        guard let sourceStableId = book.readAloudSourceStableId,
            let source = AppState.shared.bookInMemory(stableId: sourceStableId),
            source.readAloudSourceStableId == nil
        else {
            return book
        }
        return source
    }
}
