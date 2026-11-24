import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class ReadwiseExportService {
    private struct Receipt: Codable {
        let remoteID: Int
        let fingerprint: String
    }

    private(set) var isConnected: Bool
    private(set) var isWorking = false
    private(set) var sentCount = 0
    private(set) var totalCount = 0
    private(set) var lastError: String?
    private(set) var lastSentAt: Date?
    private(set) var statusMessage: String?
    @ObservationIgnored private let keychain: SharedKeychainStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: ReadwiseClient
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var isRetired = false
    private static let credentialID = "readwise-highlight-export"
    private static let receiptsKey = "readwise.exportReceipts"
    private static let lastSentKey = "readwise.lastSentAt"

    init(keychain: SharedKeychainStore, defaults: UserDefaults, client: ReadwiseClient = ReadwiseClient()) {
        self.keychain = keychain
        self.defaults = defaults
        self.client = client
        isConnected = keychain.token(forConnectionId: Self.credentialID)?.isEmpty == false
        lastSentAt = defaults.object(forKey: Self.lastSentKey) as? Date
    }

    func connect(token: String) async {
        guard !isRetired, !isWorking else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else { lastError = ReadwiseError.invalidToken.localizedDescription; return }
        beginOperation()
        operation = Task {
            defer { finishOperation() }
            do {
                try await client.validate(token: token)
                try Task.checkCancellation()
                guard !isRetired else { return }
                let oldToken = keychain.token(forConnectionId: Self.credentialID)
                guard keychain.setToken(token, forConnectionId: Self.credentialID) else { throw ReadwiseError.secureStorage }
                if oldToken != token { clearTracking() }
                isConnected = true
                statusMessage = "Connected to Readwise. Highlights are sent only when you choose Send."
            } catch { report(error) }
        }
        await operation?.value
    }

    func disconnect() {
        guard !isRetired, !isWorking else { return }
        keychain.deleteAll(forConnectionId: Self.credentialID)
        guard keychain.token(forConnectionId: Self.credentialID) == nil else { lastError = ReadwiseError.secureStorage.localizedDescription; return }
        clearTracking()
        isConnected = false
        lastError = nil
        statusMessage = "Disconnected. Your highlights in Readwise are unchanged."
    }

    func send(book: Book, annotations: [ReaderAnnotation]) async {
        guard !isRetired, !isWorking else { return }
        guard let token = keychain.token(forConnectionId: Self.credentialID), !token.isEmpty else {
            lastError = ReadwiseError.notConnected.localizedDescription
            return
        }
        beginOperation()
        operation = Task {
            defer { finishOperation() }
            do {
                let highlights = try Self.highlights(book: book, annotations: annotations)
                var receipts = loadReceipts()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let pending = try highlights.compactMap { id, highlight -> (String, ReadwiseClient.Highlight, String)? in
                    let key = Self.digest(Data((book.stableId + "\n" + id).utf8))
                    let fingerprint = Self.digest(try encoder.encode(highlight))
                    return receipts[key]?.fingerprint == fingerprint ? nil : (key, highlight, fingerprint)
                }
                totalCount = pending.count
                for (key, highlight, fingerprint) in pending {
                    try Task.checkCancellation()
                    guard !isRetired else { return }
                    let remoteID: Int
                    if let existing = receipts[key] {
                        do {
                            try await client.update(id: existing.remoteID, highlight: highlight, token: token)
                            remoteID = existing.remoteID
                        } catch ReadwiseError.server(404) {
                            remoteID = try await client.create(highlight, token: token)
                        }
                    } else {
                        remoteID = try await client.create(highlight, token: token)
                    }
                    try Task.checkCancellation()
                    guard !isRetired else { return }
                    receipts[key] = Receipt(remoteID: remoteID, fingerprint: fingerprint)
                    defaults.set(try encoder.encode(receipts), forKey: Self.receiptsKey)
                    sentCount += 1
                    lastSentAt = Date()
                    defaults.set(lastSentAt, forKey: Self.lastSentKey)
                }
                statusMessage = pending.isEmpty
                    ? "No new or changed highlights to send."
                    : "Sent \(sentCount) \(sentCount == 1 ? "highlight" : "highlights") to Readwise."
            } catch { report(error) }
        }
        await operation?.value
    }

    func cancel() { operation?.cancel() }

    func retire() {
        isRetired = true
        cancel()
        client.retire()
    }

    static func highlights(book: Book, annotations: [ReaderAnnotation]) throws -> [(String, ReadwiseClient.Highlight)] {
        let annotations = annotations.filter { !$0.isRemotePlaceholder && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
        return try annotations.map { annotation in
            var notes: [String] = []
            if let note = annotation.note, !note.isEmpty { notes.append(note) }
            if let chapter = annotation.chapterTitle, !chapter.isEmpty { notes.append("Chapter: " + chapter) }
            let note = notes.joined(separator: "\n\n")
            for (name, value, limit) in [("Highlight text", annotation.text, 8191), ("Note", note, 8191), ("Book title", book.title, 511), ("Author", book.author ?? "", 1024)] {
                guard value.unicodeScalars.count <= limit else { throw ReadwiseError.textTooLong(name) }
            }
            let position = annotation.position.isFinite ? min(1, max(0, annotation.position)) : 0
            return (annotation.id, ReadwiseClient.Highlight(
                text: annotation.text, title: book.title, author: book.author, note: note,
                location: Int((position * 1_000_000).rounded()), highlightedAt: ISO8601DateFormatter().string(from: annotation.createdAt)
            ))
        }
    }

    private func beginOperation() {
        isWorking = true
        lastError = nil
        statusMessage = nil
        sentCount = 0
        totalCount = 0
    }

    private func finishOperation() {
        isWorking = false
        operation = nil
    }

    private func report(_ error: Error) {
        guard !isRetired else { return }
        if Task.isCancelled || error is CancellationError {
            statusMessage = "Stopped. \(sentCount) highlights were confirmed; send again to continue."
        } else {
            lastError = error.localizedDescription
        }
    }

    private func loadReceipts() -> [String: Receipt] {
        guard let data = defaults.data(forKey: Self.receiptsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Receipt].self, from: data)) ?? [:]
    }

    private func clearTracking() {
        defaults.removeObject(forKey: Self.receiptsKey)
        defaults.removeObject(forKey: Self.lastSentKey)
        lastSentAt = nil
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
