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
            self.links = Dictionary(uniqueKeysWithValues: decoded.map { ($0.bookStableId, $0) })
        }

        self.lastSyncDate = userDefaults.object(forKey: lastSyncKey) as? Date
    }

    func updateConfig(serverURL: String, username: String, plaintextPassword: String?, autoSync: Bool) {
        var next = config
        next.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        next.autoSyncEnabled = autoSync
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
        if http.statusCode == 201 { return }

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
        guard !data.isEmpty else { return nil }
        let decoded = try JSONDecoder().decode(KOReaderProgress.self, from: data)
        return decoded.document.isEmpty ? nil : decoded
    }

    func pushProgress(documentHash: String, progress: String, percentage: Double) async throws {
        guard config.isConfigured, let base = config.baseURL else { throw KOReaderError.notConfigured }
        let body: [String: Any] = [
            "document": documentHash,
            "progress": progress,
            "percentage": min(max(percentage, 0), 1),
            "device": Self.deviceName(),
            "device_id": deviceId(),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await send(url: base.appendingPathComponent("syncs/progress"), method: "PUT", body: payload)
        try Self.validateStatus(response)
    }

    func pushIfLinked(book: Book, progress: Double, locator: String?) async {
        guard config.isConfigured, config.autoSyncEnabled else { return }
        guard let hash = await ensureDocumentHash(for: book) else { return }
        let payloadProgress = (locator?.isEmpty == false) ? locator! : String(format: "%.6f", progress)
        do {
            try await pushProgress(documentHash: hash, progress: payloadProgress, percentage: progress)
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
                guard let hash = await ensureDocumentHash(for: book) else { continue }
                do {
                    guard let remote = try await fetchProgress(documentHash: hash), remote.percentage > 0 else { continue }
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

    func link(book: Book, documentHash: String, isAutomatic: Bool) {
        let trimmed = documentHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 32, trimmed.allSatisfy(\.isHexDigit) else { return }
        var link =
            links[book.stableId]
            ?? KOReaderBookLink(
                bookStableId: book.stableId,
                documentHash: trimmed,
                isAutomatic: isAutomatic,
                lastSyncedAt: nil,
                lastSyncedPercentage: nil
            )
        link.documentHash = trimmed
        link.isAutomatic = isAutomatic
        links[book.stableId] = link
        persistLinks()
    }

    func unlink(bookStableId: String) {
        links.removeValue(forKey: bookStableId)
        persistLinks()
    }

    func link(for bookStableId: String) -> KOReaderBookLink? { links[bookStableId] }

    func ensureDocumentHash(for book: Book) async -> String? {
        if let existing = links[book.stableId] { return existing.documentHash }
        guard book.mediaType == .ebook else { return nil }
        guard let fileURL = EbookChapterSyncService.shared.resolvedFileURL(for: book),
            FileManager.default.fileExists(atPath: fileURL.path),
            let hash = await Self.computePartialMD5(fileURL: fileURL)
        else {
            return nil
        }
        link(book: book, documentHash: hash, isAutomatic: true)
        return hash
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
        switch http.statusCode {
        case 200, 201: return
        case 401, 402: throw KOReaderError.unauthorized
        default: throw KOReaderError.server(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
