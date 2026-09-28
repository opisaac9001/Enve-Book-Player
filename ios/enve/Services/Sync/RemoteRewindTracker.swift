import Foundation

struct RemoteProgressWriteKey: Hashable, Sendable {
    let bookStableId: String
    let domainKey: String
    let connectionId: String
}

extension RemoteProgressWriteKey {
    init(book: Book, domain: ProgressSyncDomain) {
        self.init(
            bookStableId: book.stableId,
            domainKey: RemoteProgressScope.domainKey(for: domain),
            connectionId: book.providerId.uuidString
        )
    }
}

struct RemoteProgressScope: Hashable, Sendable {
    let bookStableId: String
    let domainKey: String
    let connectionId: String
    let source: String

    static func domainKey(for domain: ProgressSyncDomain) -> String {
        domain.usesEbookProgress ? "ebook" : "audiobook"
    }

    init(bookStableId: String, domain: ProgressSyncDomain, connectionId: String, source: String) {
        self.bookStableId = bookStableId
        self.domainKey = Self.domainKey(for: domain)
        self.connectionId = connectionId
        self.source = source
    }

    init(book: Book, domain: ProgressSyncDomain, source: String) {
        self.init(
            bookStableId: book.stableId,
            domain: domain,
            connectionId: book.providerId.uuidString,
            source: source
        )
    }

    var writeKey: RemoteProgressWriteKey {
        RemoteProgressWriteKey(
            bookStableId: bookStableId,
            domainKey: domainKey,
            connectionId: connectionId
        )
    }
}

struct RemoteProgressObservation: Equatable, Sendable {
    let progress: Double
    let positionSeconds: TimeInterval?
    let locator: String?
    let observedAt: Date
}

enum RemoteRewindVerdict: Equatable, Sendable {
    case notRewind
    case echo
    case dismissed
    case unconfirmed
    case confirmed
}

@MainActor
final class RemoteRewindTracker {
    static let shared = RemoteRewindTracker()

    private static let equalEpsilon = 0.005
    private static let advanceEpsilon = 0.005
    private static let nearZeroProgress = 0.01
    private static let positionEchoTolerance: TimeInterval = 2
    private static let clockSkew: TimeInterval = 60
    private static let writeRetention: TimeInterval = 30 * 60
    private static let maxWritesPerBook = 4
    private static let maxTrackedKeys = 128
    private static let minimumHighlightAnchor = 8

    private struct OutboundWrite {
        let progress: Double
        let positionSeconds: TimeInterval?
        let locator: String?
        let writtenAt: Date
    }

    private struct ScopeState {
        var candidate: RemoteProgressObservation?
        var confirmed: RemoteProgressObservation?
        var userKeptLocal = false
        var touchedAt = Date.distantPast
    }

    private struct WriteLedger {
        var writes: [OutboundWrite] = []
        var touchedAt = Date.distantPast
    }

    private var scopes: [RemoteProgressScope: ScopeState] = [:]
    private var ledgers: [RemoteProgressWriteKey: WriteLedger] = [:]

    init() {}

    func assess(
        scope: RemoteProgressScope,
        observation: RemoteProgressObservation,
        localProgress: Double
    ) -> RemoteRewindVerdict {
        var state = scopes[scope] ?? ScopeState()
        state.touchedAt = Date()
        defer { store(state, for: scope) }

        if isEcho(observation, writeKey: scope.writeKey) {
            return .echo
        }

        guard observation.progress < localProgress - Self.equalEpsilon else {
            state.candidate = nil
            state.confirmed = nil
            state.userKeptLocal = false
            return .notRewind
        }

        // Several callers assess the same snapshot during one book open; the verdict has to be stable.
        if observation == state.confirmed {
            return .confirmed
        }

        if state.userKeptLocal {
            return .dismissed
        }

        guard observation.observedAt > .distantPast else {
            return .unconfirmed
        }

        if let candidate = state.candidate,
            candidate.observedAt > .distantPast,
            candidate.progress > Self.nearZeroProgress,
            hasPrecisePosition(candidate),
            observation.observedAt > candidate.observedAt,
            observation.progress > candidate.progress + Self.advanceEpsilon,
            observation.progress > Self.nearZeroProgress,
            hasPrecisePosition(observation)
        {
            state.candidate = nil
            state.confirmed = observation
            return .confirmed
        }

        if let candidate = state.candidate {
            if observation.observedAt > candidate.observedAt, observation.progress < candidate.progress {
                state.candidate = observation
            }
        } else {
            state.candidate = observation
        }
        return .unconfirmed
    }

    func recordOutboundWrite(
        key: RemoteProgressWriteKey,
        progress: Double,
        positionSeconds: TimeInterval?,
        locator: String?,
        at date: Date = Date()
    ) {
        var ledger = ledgers[key] ?? WriteLedger()
        ledger.writes = ledger.writes.filter { date.timeIntervalSince($0.writtenAt) <= Self.writeRetention }
        ledger.writes.append(
            OutboundWrite(
                progress: progress,
                positionSeconds: positionSeconds,
                locator: locator,
                writtenAt: date
            )
        )
        if ledger.writes.count > Self.maxWritesPerBook {
            ledger.writes.removeFirst(ledger.writes.count - Self.maxWritesPerBook)
        }
        ledger.touchedAt = date
        ledgers[key] = ledger
        evict(&ledgers, limit: Self.maxTrackedKeys) { $0.touchedAt }
    }

    func recordUserResolution(scope: RemoteProgressScope, acceptedRemote: Bool) {
        var state = scopes[scope] ?? ScopeState()
        state.candidate = nil
        state.confirmed = nil
        state.userKeptLocal = !acceptedRemote
        state.touchedAt = Date()
        store(state, for: scope)
    }

    private func store(_ state: ScopeState, for scope: RemoteProgressScope) {
        scopes[scope] = state
        evict(&scopes, limit: Self.maxTrackedKeys) { $0.touchedAt }
    }

    private func evict<Key: Hashable, Value>(
        _ storage: inout [Key: Value],
        limit: Int,
        age: (Value) -> Date
    ) {
        guard storage.count > limit else { return }
        let overflow = storage.count - limit
        let stalest = storage.sorted { age($0.value) < age($1.value) }.prefix(overflow)
        for entry in stalest {
            storage.removeValue(forKey: entry.key)
        }
    }

    private func isEcho(_ observation: RemoteProgressObservation, writeKey: RemoteProgressWriteKey) -> Bool {
        guard let ledger = ledgers[writeKey] else { return false }
        return ledger.writes.contains { write in
            let sinceWrite = observation.observedAt.timeIntervalSince(write.writtenAt)
            guard sinceWrite >= -Self.clockSkew, sinceWrite <= Self.writeRetention else { return false }
            if let remote = observation.locator, let mine = write.locator, !remote.isEmpty, !mine.isEmpty {
                return remote == mine
            }
            if let remote = observation.positionSeconds, let mine = write.positionSeconds, remote > 0, mine > 0 {
                return abs(remote - mine) <= Self.positionEchoTolerance
            }
            return abs(observation.progress - write.progress) <= Self.equalEpsilon
        }
    }

    private func hasPrecisePosition(_ observation: RemoteProgressObservation) -> Bool {
        if let positionSeconds = observation.positionSeconds, positionSeconds > 0 { return true }
        guard let locator = observation.locator,
            let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if EpubLocationBridge.canonicalFullEPUBCFI(EpubLocationBridge.epubCFI(from: locator)) != nil { return true }
        let text = json["text"] as? [String: Any]
        if let quote = text?["highlight"] as? String,
            quote.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumHighlightAnchor
        {
            return true
        }
        let locations = json["locations"] as? [String: Any]
        let range = locations?["domRange"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        return (start?["cssSelector"] as? String)?.isEmpty == false
    }
}
