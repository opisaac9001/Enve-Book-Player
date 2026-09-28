import Combine
import CryptoKit
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class KOReaderSyncService {
    static let shared = KOReaderSyncService()

    private(set) var config: KOReaderConfig
    private(set) var links: [String: KOReaderBookLink] = [:]
    private(set) var lastSyncDate: Date?
    private(set) var isSyncing = false

    @ObservationIgnored private let configKey = "koreaderSyncConfig"
    @ObservationIgnored private let linksKey = "koreaderSyncLinks"
    @ObservationIgnored private let lastSyncKey = "koreaderSyncLastSyncDate"
    @ObservationIgnored private let passwordHashKeychainKey = "koreader.passwordHash"
    @ObservationIgnored private let deviceIdKey = "koreader.deviceId"

    @ObservationIgnored private let userDefaults = UserDefaults.standard
    @ObservationIgnored private let keychain = KeychainHelper.shared

    @ObservationIgnored private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private init() {
        if let data = userDefaults.data(forKey: configKey),
            var decoded = try? JSONDecoder().decode(KOReaderConfig.self, from: data)
        {
            decoded.passwordHash = keychain.get(passwordHashKeychainKey) ?? ""
            self.config = decoded
        } else {
            self.config = KOReaderConfig()
        }

        if let data = userDefaults.data(forKey: linksKey),
            let decoded = try? JSONDecoder().decode([KOReaderBookLink].self, from: data)
        {
            self.links = Self.restoredLinks(decoded)
        }

        self.lastSyncDate = userDefaults.object(forKey: lastSyncKey) as? Date
    }

    func updateConfig(
        serverURL: String,
        username: String,
        plaintextPassword: String?,
        autoSync: Bool,
        documentMatching: KOReaderDocumentMatching? = nil,
        sendsDocumentMetadata: Bool? = nil
    ) {
        var next = config
        next.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        next.autoSyncEnabled = autoSync
        if let documentMatching { next.documentMatching = documentMatching }
        if let sendsDocumentMetadata { next.sendsDocumentMetadata = sendsDocumentMetadata }
        if let pw = plaintextPassword, !pw.isEmpty {
            next.passwordHash = Self.md5Hex(pw)
        }
        config = next
        persistConfig()
    }

    func clearConfig() {
        config = KOReaderConfig()
        keychain.delete(passwordHashKeychainKey)
        userDefaults.removeObject(forKey: configKey)
    }

    private func persistConfig() {
        var onDisk = config
        onDisk.passwordHash = ""
        if let data = try? JSONEncoder().encode(onDisk) {
            userDefaults.set(data, forKey: configKey)
        }
        if config.passwordHash.isEmpty {
            keychain.delete(passwordHashKeychainKey)
        } else {
            keychain.set(config.passwordHash, key: passwordHashKeychainKey)
        }
    }

    enum KOReaderError: Error, LocalizedError {
        case notConfigured
        case invalidURL
        case unauthorized
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "KOReader sync is not configured."
            case .invalidURL: return "KOReader server URL is invalid."
            case .unauthorized: return "Incorrect username or password."
            case .server(let code, let message):
                return "Server error \(code): \(message)"
            }
        }
    }

    @discardableResult
    func authorize() async throws -> Bool {
        guard config.isConfigured, let base = config.baseURL else { throw KOReaderError.notConfigured }
        let (_, response) = try await send(url: base.appendingPathComponent("users/auth"), method: "GET")
        try Self.validateStatus(response)
        return true
    }

    func register(username: String, plaintextPassword: String, serverURL: String) async throws {
        guard let base = KOReaderConfig(serverURL: serverURL, username: username).baseURL else {
            throw KOReaderError.invalidURL
        }
        var req = URLRequest(url: base.appendingPathComponent("users/create"))
        req.httpMethod = "POST"
        req.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": Self.md5Hex(plaintextPassword),
        ])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw KOReaderError.server(-1, "Bad response") }
        if KOReaderResponseClass(statusCode: http.statusCode) == .success { return }

        let serverMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["message"] as? String }
        throw KOReaderError.server(http.statusCode, serverMessage ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    func fetchProgress(documentHash: String) async throws -> KOReaderProgress? {
        guard config.isConfigured, let base = config.baseURL else { throw KOReaderError.notConfigured }
        let url = base.appendingPathComponent("syncs/progress").appendingPathComponent(documentHash)
        let (data, response) = try await send(url: url, method: "GET")
        guard let http = response as? HTTPURLResponse else { throw KOReaderError.server(-1, "Bad response") }
        if http.statusCode == 404 { return nil }
        try Self.validateStatus(response)
        // Spring-based servers can return an empty body when no progress is saved.
        guard http.statusCode != 204, !data.isEmpty else { return nil }
        let decoded = try JSONDecoder().decode(KOReaderProgress.self, from: data)
        return decoded.document.isEmpty ? nil : decoded
    }

    func pushProgress(
        documentHash: String,
        progress: String,
        percentage: Double,
        metadata: KOReaderDocumentMetadata? = nil
    ) async throws {
        guard config.isConfigured, let base = config.baseURL else { throw KOReaderError.notConfigured }
        var body: [String: Any] = [
            "document": documentHash,
            "progress": progress,
            "percentage": min(max(percentage, 0), 1),
            "device": Self.deviceName(),
            "device_id": deviceId(),
        ]
        if let metadataObject = metadata?.jsonObject {
            body["metadata"] = metadataObject
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await send(url: base.appendingPathComponent("syncs/progress"), method: "PUT", body: payload)
        try Self.validateStatus(response)
    }

    func pushIfLinked(book: Book, progress: Double, locator: String?) async {
        guard config.isConfigured, config.autoSyncEnabled else { return }
        guard let plan = await documentMatchPlan(for: book) else { return }
        let fileURL = EbookChapterSyncService.shared.resolvedFileURL(for: book)
        let payloadProgress = await Self.koreaderProgressString(locator: locator, progress: progress, epubFileURL: fileURL)
        do {
            try await pushProgress(
                documentHash: plan.pushHash,
                progress: payloadProgress,
                percentage: progress,
                metadata: documentMetadata(for: book, fileURL: fileURL)
            )
            updateLinkSyncStatus(bookStableId: book.stableId, percentage: progress)
            lastSyncDate = Date()
            userDefaults.set(lastSyncDate, forKey: lastSyncKey)
        } catch {
            AppLogger.sync.error(
                "KOReader push failed bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    func pullAllAndMerge() async -> Int {
        guard config.isConfigured else { return 0 }
        isSyncing = true
        defer { isSyncing = false }

        let books = await AppState.shared.bookStore.firstBooks(mediaType: "ebook", limit: 5000)
        var applied = 0

        await AppState.shared.withAllBooksTransaction {
            for book in books {
                guard let plan = await documentMatchPlan(for: book) else { continue }
                do {
                    guard let remote = try await fetchRemoteProgress(plan: plan, bookStableId: book.stableId),
                        remote.percentage > 0
                    else { continue }
                    if await mergeRemoteProgress(into: book, remote: remote) {
                        applied += 1
                    }
                    updateLinkSyncStatus(bookStableId: book.stableId, percentage: remote.percentage)
                } catch {
                    AppLogger.sync.error(
                        "KOReader pull failed bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                    )
                }
            }
        }

        lastSyncDate = Date()
        userDefaults.set(lastSyncDate, forKey: lastSyncKey)
        return applied
    }

    @discardableResult
    func mergeRemoteProgress(into book: Book, remote: KOReaderProgress) async -> Bool {
        guard let current = AppState.shared.bookInMemory(stableId: book.stableId) else { return false }
        let percentage = max(0, min(1, remote.percentage))
        let local = current.canonicalEbookProgress
        guard percentage > local + 0.005 else { return false }

        var resolvedLocator: String? = nil
        if remote.progress.hasPrefix("{") {
            resolvedLocator = remote.progress
        } else if remote.progress.hasPrefix("/body/DocFragment") {
            let fileURL = EbookChapterSyncService.shared.resolvedFileURL(for: book)
            if let url = fileURL,
                let locatorJSON = await KOReaderXPointerConverter.locatorJSON(
                    xpointer: remote.progress,
                    percentage: percentage,
                    epubFileURL: url
                )
            {
                resolvedLocator = locatorJSON
            }
        }

        AppState.shared.mutateBook(stableId: book.stableId) { updated in
            updated.ebookProgress = percentage
            if let loc = resolvedLocator {
                updated.epubLocator = loc
            }
            updated.lastUpdate = Date()
        }
        EbookLinkStore.shared.saveLinks()
        AppState.shared.allBooksChanged.send(())
        return true
    }

    func link(
        book: Book,
        documentHash: String,
        isAutomatic: Bool,
        fileIdentity: KOReaderFileIdentity? = nil,
        filenameHash: String? = nil
    ) {
        let trimmed = documentHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 32, trimmed.allSatisfy(\.isHexDigit) else { return }
        links[book.stableId] = Self.repairedLink(
            previous: links[book.stableId],
            bookStableId: book.stableId,
            documentHash: trimmed,
            isAutomatic: isAutomatic,
            fileIdentity: fileIdentity,
            filenameHash: filenameHash
        )
        persistLinks()
    }

    static let maxHashHistory = 5

    static func repairedLink(
        previous: KOReaderBookLink?,
        bookStableId: String,
        documentHash: String,
        isAutomatic: Bool,
        fileIdentity: KOReaderFileIdentity?,
        filenameHash: String? = nil
    ) -> KOReaderBookLink {
        guard let previous else {
            return KOReaderBookLink(
                bookStableId: bookStableId,
                documentHash: documentHash,
                isAutomatic: isAutomatic,
                fileIdentity: fileIdentity,
                filenameHash: filenameHash
            )
        }

        let resolvedFilenameHash = filenameHash ?? previous.filenameHash
        // Drop the match if a file edit or rename changed the hash it used.
        let matchedHash = previous.matchedHash.flatMap {
            $0 == documentHash || $0 == resolvedFilenameHash ? $0 : nil
        }

        guard previous.documentHash != documentHash else {
            var refreshed = previous
            refreshed.isAutomatic = isAutomatic
            refreshed.fileIdentity = fileIdentity
            refreshed.filenameHash = resolvedFilenameHash
            refreshed.matchedHash = matchedHash
            return refreshed
        }

        // A new hash is a different document. Reset the old sync state.
        var history = [previous.documentHash] + previous.previousHashes
        history.removeAll { $0 == documentHash }
        return KOReaderBookLink(
            bookStableId: bookStableId,
            documentHash: documentHash,
            isAutomatic: isAutomatic,
            fileIdentity: fileIdentity,
            previousHashes: Array(history.prefix(maxHashHistory)),
            filenameHash: resolvedFilenameHash,
            matchedHash: matchedHash
        )
    }

    func unlink(bookStableId: String) {
        links.removeValue(forKey: bookStableId)
        persistLinks()
    }

    func link(for bookStableId: String) -> KOReaderBookLink? { links[bookStableId] }

    static func restoredLinks(_ decoded: [KOReaderBookLink]) -> [String: KOReaderBookLink] {
        Dictionary(decoded.map { ($0.bookStableId, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    func ensureDocumentHash(for book: Book) async -> String? {
        let existing = links[book.stableId]
        if let existing, !existing.isAutomatic { return existing.documentHash }
        guard book.mediaType == .ebook else { return existing?.documentHash }
        guard let fileURL = EbookChapterSyncService.shared.resolvedFileURL(for: book),
            let identity = KOReaderFileIdentity.read(fileURL: fileURL)
        else {
            return existing?.documentHash
        }
        let filenameHash = Self.filenameHash(fileURL: fileURL)
        if let existing, existing.fileIdentity == identity {
            if existing.filenameHash != filenameHash {
                link(
                    book: book,
                    documentHash: existing.documentHash,
                    isAutomatic: true,
                    fileIdentity: identity,
                    filenameHash: filenameHash
                )
            }
            return existing.documentHash
        }
        guard let hash = await Self.computePartialMD5(fileURL: fileURL),
            !Task.isCancelled, KOReaderFileIdentity.read(fileURL: fileURL) == identity
        else { return nil }

        // The user may have changed the link while this request was running.
        guard links[book.stableId] == existing else { return links[book.stableId]?.documentHash }
        link(book: book, documentHash: hash, isAutomatic: true, fileIdentity: identity, filenameHash: filenameHash)
        return hash
    }

    func documentMatchPlan(for book: Book) async -> KOReaderDocumentMatchPlan? {
        if let pinned = links[book.stableId], !pinned.isAutomatic {
            return KOReaderDocumentMatchPlan(pushHash: pinned.documentHash, fetchCandidates: [pinned.documentHash])
        }
        let binaryHash = await ensureDocumentHash(for: book)
        let link = links[book.stableId]
        let filenameHash =
            EbookChapterSyncService.shared.resolvedFileURL(for: book).map(Self.filenameHash(fileURL:))
            ?? link?.filenameHash
        return KOReaderDocumentMatchPlan.make(
            matching: config.documentMatching,
            link: link,
            binaryHash: binaryHash,
            filenameHash: filenameHash
        )
    }

    private func fetchRemoteProgress(plan: KOReaderDocumentMatchPlan, bookStableId: String) async throws -> KOReaderProgress? {
        var found: [(hash: String, progress: KOReaderProgress)] = []
        for hash in plan.fetchCandidates {
            if let remote = try await fetchProgress(documentHash: hash) { found.append((hash, remote)) }
        }

        // Use a hash written by another device. Ignore our own writes when pairing.
        let localDeviceId = deviceId()
        if let peerHash = Self.preferredPeerHash(found.filter { $0.progress.deviceId != localDeviceId }) {
            noteMatchedHash(bookStableId: bookStableId, hash: peerHash)
        }

        // This merge only moves forward, so use the furthest position.
        return found.max { $0.progress.percentage < $1.progress.percentage }?.progress
    }

    /// Pick the newest write; break timestamp ties by progress, then candidate order.
    static func preferredPeerHash(_ candidates: [(hash: String, progress: KOReaderProgress)]) -> String? {
        candidates.enumerated().max { lhs, rhs in
            let lhsTime = serverTimestamp(lhs.element.progress)
            let rhsTime = serverTimestamp(rhs.element.progress)
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            if lhs.element.progress.percentage != rhs.element.progress.percentage {
                return lhs.element.progress.percentage < rhs.element.progress.percentage
            }
            return lhs.offset > rhs.offset
        }?.element.hash
    }

    /// Treat missing or zero timestamps as unknown.
    private static func serverTimestamp(_ progress: KOReaderProgress) -> TimeInterval {
        max(progress.timestamp ?? 0, 0)
    }

    private func noteMatchedHash(bookStableId: String, hash: String) {
        guard var link = links[bookStableId], link.isAutomatic, link.matchedHash != hash else { return }
        link.matchedHash = hash
        links[bookStableId] = link
        persistLinks()
    }

    private func documentMetadata(for book: Book, fileURL: URL?) -> KOReaderDocumentMetadata? {
        guard config.sendsDocumentMetadata else { return nil }
        return KOReaderDocumentMetadata(
            filename: fileURL?.lastPathComponent ?? "",
            title: book.title,
            authors: book.author ?? ""
        )
    }

    /// Use a KOSync xpointer when possible. Keep the locator as a fallback for Enve-to-Enve sync.
    private static func koreaderProgressString(locator: String?, progress: Double, epubFileURL: URL?) async -> String {
        guard let locator, !locator.isEmpty else { return String(format: "%.6f", progress) }
        guard let epubFileURL,
            let xpointer = await KOReaderXPointerConverter.xpointer(forLocatorJSON: locator, epubFileURL: epubFileURL)
        else { return locator }
        return xpointer
    }

    private func updateLinkSyncStatus(bookStableId: String, percentage: Double) {
        guard var link = links[bookStableId] else { return }
        link.lastSyncedAt = Date()
        link.lastSyncedPercentage = percentage
        links[bookStableId] = link
        persistLinks()
    }

    private func persistLinks() {
        if let data = try? JSONEncoder().encode(Array(links.values)) {
            userDefaults.set(data, forKey: linksKey)
        }
    }

    private func send(url: URL, method: String, body: Data? = nil) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        req.setValue(config.username, forHTTPHeaderField: "x-auth-user")
        req.setValue(config.passwordHash, forHTTPHeaderField: "x-auth-key")
        return try await session.data(for: req)
    }

    private static func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw KOReaderError.server(-1, "Bad response")
        }
        switch KOReaderResponseClass(statusCode: http.statusCode) {
        case .success: return
        case .unauthorized: throw KOReaderError.unauthorized
        case .failure:
            throw KOReaderError.server(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Hash just the filename so different folders still match.
    static func filenameHash(fileURL: URL) -> String {
        md5Hex(fileURL.lastPathComponent)
    }

    static func computePartialMD5(fileURL: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? handle.close() }

            let sampleSize = 1024
            var md5 = Insecure.MD5()

            for i in -1...10 {
                let offset: UInt64 = (i < 0) ? 0 : (UInt64(1024) << (2 * i))
                do {
                    try handle.seek(toOffset: offset)
                } catch {
                    continue
                }
                guard let chunk = try? handle.read(upToCount: sampleSize), !chunk.isEmpty else {
                    continue
                }
                md5.update(data: chunk)
            }

            return md5.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func deviceName() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Enve"
        #endif
    }

    private func deviceId() -> String {
        if let existing = userDefaults.string(forKey: deviceIdKey) { return existing }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        userDefaults.set(generated, forKey: deviceIdKey)
        return generated
    }
}
