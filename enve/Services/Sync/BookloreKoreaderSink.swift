import CryptoKit
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

struct BookloreKoreaderCredentials: Codable {
    var username: String
    var passwordMD5: String
    var enabled: Bool = false
    var syncWithBookloreReader: Bool = false
}

@MainActor
final class BookloreKoreaderSink {

    static let shared = BookloreKoreaderSink(providerConnections: AppState.shared.providerConnections)

    private var credentialsCache: [UUID: BookloreKoreaderCredentials] = [:]
    private var documentHashCache: [String: String] = [:]
    private var documentHashFingerprint: [String: String] = [:]
    private let providerConnections: any ProviderConnectionAccessing

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private init(providerConnections: any ProviderConnectionAccessing) {
        self.providerConnections = providerConnections
        loadAllCredentials()
    }

    func credentials(for providerId: UUID) -> BookloreKoreaderCredentials? {
        credentialsCache[providerId]
    }

    func setCredentials(_ creds: BookloreKoreaderCredentials, for providerId: UUID) {
        credentialsCache[providerId] = creds
        persistCredentials(creds, for: providerId)
    }

    func clearCredentials(for providerId: UUID) {
        credentialsCache.removeValue(forKey: providerId)
        let usernameKey = keychainKey("username", providerId: providerId)
        let passwordKey = keychainKey("passwordMD5", providerId: providerId)
        let enabledKey = udKey("enabled", providerId: providerId)
        KeychainHelper.shared.delete(usernameKey)
        KeychainHelper.shared.delete(passwordKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    func testAuth(providerId: UUID, baseURL: URL) async throws -> Bool {
        guard let creds = credentialsCache[providerId], !creds.username.isEmpty else { return false }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/koreader/users/auth"))
        req.httpMethod = "GET"
        addKoreaderHeaders(&req, creds: creds)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func push(
        book: Book,
        locatorJSON: String?,
        progress: Double,
        provider: BookloreProvider,
        epubFileURL: URL?
    ) async {
        let providerId = provider.connection.id
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        guard let creds = credentialsCache[providerId], creds.enabled, !creds.username.isEmpty else { return }
        guard let baseURL = buildBaseURL(from: provider.connection) else { return }

        guard let hash = await resolveDocumentHash(for: book, epubFileURL: epubFileURL) else {
            AppLogger.sync.debug("[BookloreKOReader] No document hash bookDiagnosticID=\(diagnosticID)")
            return
        }

        let xpointerProgress: String
        if let locJSON = locatorJSON, !locJSON.isEmpty, let epubURL = epubFileURL {
            if let xptr = await KOReaderXPointerConverter.xpointer(forLocatorJSON: locJSON, epubFileURL: epubURL) {
                xpointerProgress = xptr
            } else {
                xpointerProgress = String(format: "%.6f", progress)
            }
        } else {
            xpointerProgress = String(format: "%.6f", progress)
        }

        let body: [String: Any] = [
            "document": hash,
            "progress": xpointerProgress,
            "percentage": min(max(progress, 0), 1),
            "device": deviceName(),
            "device_id": deviceId(),
            "timestamp": Int(Date().timeIntervalSince1970),
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/koreader/syncs/progress"))
        req.httpMethod = "PUT"
        req.httpBody = payload
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addKoreaderHeaders(&req, creds: creds)

        do {
            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 || status == 201 {
                AppLogger.sync.debug("[BookloreKOReader] Pushed xpointer bookDiagnosticID=\(diagnosticID)")
            } else {
                AppLogger.sync.error("[BookloreKOReader] Push returned HTTP \(status) bookDiagnosticID=\(diagnosticID)")
            }
        } catch {
            AppLogger.sync.error("[BookloreKOReader] Push failed bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)")
        }
    }

    func pull(book: Book, provider: BookloreProvider, epubFileURL: URL?) async -> (progress: Double, xpointer: String?, timestamp: Date)? {
        let providerId = provider.connection.id
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        guard let creds = credentialsCache[providerId], creds.enabled, !creds.username.isEmpty else { return nil }
        guard let baseURL = buildBaseURL(from: provider.connection) else { return nil }
        guard let hash = await resolveDocumentHash(for: book, epubFileURL: epubFileURL) else { return nil }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/koreader/syncs/progress/\(hash)"))
        req.httpMethod = "GET"
        addKoreaderHeaders(&req, creds: creds)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            AppLogger.sync.warning("[KOReader] pull network error bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)")
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            AppLogger.sync.error("[KOReader] auth failed (\(http.statusCode)) - check credentials")
            return nil
        case 404:
            return nil
        case 500...599:
            AppLogger.sync.warning("[KOReader] server error \(http.statusCode) bookDiagnosticID=\(diagnosticID)")
            return nil
        default:
            AppLogger.sync.warning("[KOReader] unexpected status \(http.statusCode) bookDiagnosticID=\(diagnosticID)")
            return nil
        }

        struct KOReaderResponse: Decodable {
            let document: String?
            let progress: String?
            let percentage: Double?
            let timestamp: Int?
        }

        guard let decoded = try? JSONDecoder().decode(KOReaderResponse.self, from: data),
            let pct = decoded.percentage
        else { return nil }

        let ts = decoded.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        return (progress: pct, xpointer: decoded.progress, timestamp: ts)
    }

    func resolveDocumentHash(for book: Book, epubFileURL: URL?) async -> String? {
        let bookId = book.stableId
        guard let fileURL = epubFileURL ?? findLocalEpubURL(for: book) else { return nil }
        let fingerprint = fileFingerprint(at: fileURL)

        if let cached = documentHashCache[bookId],
            let cachedFingerprint = documentHashFingerprint[bookId],
            cachedFingerprint == fingerprint
        {
            return cached
        }

        guard let hash = await KOReaderSyncService.computePartialMD5(fileURL: fileURL) else { return nil }
        documentHashCache[bookId] = hash
        if let fingerprint { documentHashFingerprint[bookId] = fingerprint }
        UserDefaults.standard.set(hash, forKey: "enve.booklore.koreader.documentHash.\(bookId)")
        return hash
    }

    private func fileFingerprint(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(mtime)"
    }

    private func findLocalEpubURL(for book: Book) -> URL? {
        EbookChapterSyncService.shared.resolvedFileURL(for: book)
    }

    private func addKoreaderHeaders(_ req: inout URLRequest, creds: BookloreKoreaderCredentials) {
        req.setValue(creds.username, forHTTPHeaderField: "x-auth-user")
        req.setValue(creds.passwordMD5, forHTTPHeaderField: "x-auth-key")
        req.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
    }

    private func buildBaseURL(from connection: ServerConnection) -> URL? {
        var str = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") { str.removeLast() }

        if !str.hasPrefix("http") { str = "http://\(str)" }
        return URL(string: str)
    }

    private func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Enve"
        #endif
    }

    private func deviceId() -> String {
        StorageService.shared.loadDeviceUUID()
    }

    private func keychainKey(_ field: String, providerId: UUID) -> String {
        "enve.booklore.koreader.\(field).\(providerId.uuidString)"
    }

    private func udKey(_ field: String, providerId: UUID) -> String {
        "enve.booklore.koreader.\(field).\(providerId.uuidString)"
    }

    private func persistCredentials(_ creds: BookloreKoreaderCredentials, for providerId: UUID) {
        if !creds.username.isEmpty {
            KeychainHelper.shared.set(creds.username, key: keychainKey("username", providerId: providerId))
        }
        if !creds.passwordMD5.isEmpty {
            KeychainHelper.shared.set(creds.passwordMD5, key: keychainKey("passwordMD5", providerId: providerId))
        }
        UserDefaults.standard.set(creds.enabled, forKey: udKey("enabled", providerId: providerId))
        UserDefaults.standard.set(creds.syncWithBookloreReader, forKey: udKey("syncWithReader", providerId: providerId))
    }

    private func loadAllCredentials() {
        let connections = providerConnections.connections.filter { $0.type == .booklore }
        for conn in connections {
            let usernameKey = keychainKey("username", providerId: conn.id)
            let passwordKey = keychainKey("passwordMD5", providerId: conn.id)
            let enabledKey = udKey("enabled", providerId: conn.id)
            let readerKey = udKey("syncWithReader", providerId: conn.id)

            guard let username = KeychainHelper.shared.get(usernameKey), !username.isEmpty else { continue }
            let passwordMD5 = KeychainHelper.shared.get(passwordKey) ?? ""
            let enabled = UserDefaults.standard.bool(forKey: enabledKey)
            let syncWithReader = UserDefaults.standard.bool(forKey: readerKey)

            credentialsCache[conn.id] = BookloreKoreaderCredentials(
                username: username,
                passwordMD5: passwordMD5,
                enabled: enabled,
                syncWithBookloreReader: syncWithReader
            )
        }

        let hashKeys = UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("enve.booklore.koreader.documentHash.") }
        for (key, value) in hashKeys {
            if let hash = value as? String {
                let bookId = String(key.dropFirst("enve.booklore.koreader.documentHash.".count))
                documentHashCache[bookId] = hash
            }
        }
    }
}

extension BookloreKoreaderSink {
    static func md5Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension BookloreKoreaderSink: SyncSink {
    var id: String { "booklore.koreader" }
    var displayName: String { "KOReader (Booklore)" }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        guard domain.usesEbookProgress else { return false }
        guard let provider = providerConnections.provider(for: book) as? BookloreProvider else { return false }
        guard let creds = credentialsCache[provider.connection.id], creds.enabled, !creds.username.isEmpty else { return false }
        return true
    }

    func pull(book: Book, domain: ProgressSyncDomain) async -> SyncSnapshot? {
        guard domain.usesEbookProgress else { return nil }
        guard let provider = providerConnections.provider(for: book) as? BookloreProvider else { return nil }
        let epubURL = EbookChapterSyncService.shared.resolvedFileURL(for: book)
        guard let raw = await pull(book: book, provider: provider, epubFileURL: epubURL) else { return nil }
        let sourceName = provider.connection.name.isEmpty ? provider.connection.type.rawValue : provider.connection.name
        return SyncSnapshot(
            progress: raw.progress,
            positionSeconds: 0,
            locator: raw.xpointer,
            lastUpdate: raw.timestamp,
            isFinished: false,
            source: "KOReader@\(sourceName)"
        )
    }

    func push(_ update: ProgressUpdate) async throws {
        guard let provider = providerConnections.provider(for: update.book) as? BookloreProvider else { return }
        let epubURL = EbookChapterSyncService.shared.resolvedFileURL(for: update.book)
        await push(
            book: update.book,
            locatorJSON: update.locator,
            progress: update.progress,
            provider: provider,
            epubFileURL: epubURL
        )
    }
}
