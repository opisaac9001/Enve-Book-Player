import Foundation

/// File and filename hashes differ. Check both when looking for another device's progress.
enum KOReaderDocumentMatching: String, Codable, CaseIterable, Sendable {
    /// Partial MD5 of the file contents. KOReader's default, and Enve's.
    case binary
    /// MD5 of the filename. CrossPoint uses this by default.
    case filename
    /// Check every candidate hash and push to the one the other device uses.
    case smart

    var displayName: String {
        switch self {
        case .binary: return "File contents"
        case .filename: return "File name"
        case .smart: return "Smart"
        }
    }
}

/// The reference server returns 200; Spring-based servers can return 201 on create or 204 on an empty read.
enum KOReaderResponseClass: Equatable, Sendable {
    case success
    case unauthorized
    case failure

    init(statusCode: Int) {
        switch statusCode {
        case 200..<300: self = .success
        // Only 401 and 402 mean bad credentials. A 403 needs a different fix.
        case 401, 402: self = .unauthorized
        default: self = .failure
        }
    }
}

struct KOReaderConfig: Codable, Equatable {
    static let crossPointServerURL = "https://sync.crosspointreader.com"
    static let koreaderServerURL = "https://sync.koreader.rocks"

    var serverURL: String
    var username: String

    var passwordHash: String
    var autoSyncEnabled: Bool
    var documentMatching: KOReaderDocumentMatching
    /// Leave this off unless requested. Metadata can expose library details on a shared server.
    var sendsDocumentMetadata: Bool

    init(
        serverURL: String = "",
        username: String = "",
        passwordHash: String = "",
        autoSyncEnabled: Bool = true,
        documentMatching: KOReaderDocumentMatching = .binary,
        sendsDocumentMetadata: Bool = false
    ) {
        self.serverURL = serverURL
        self.username = username
        self.passwordHash = passwordHash
        self.autoSyncEnabled = autoSyncEnabled
        self.documentMatching = documentMatching
        self.sendsDocumentMetadata = sendsDocumentMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decode(String.self, forKey: .serverURL)
        username = try c.decode(String.self, forKey: .username)
        passwordHash = try c.decode(String.self, forKey: .passwordHash)
        autoSyncEnabled = try c.decode(Bool.self, forKey: .autoSyncEnabled)
        // Keep existing installs on content hashes so their saved progress still matches.
        documentMatching = try c.decodeIfPresent(KOReaderDocumentMatching.self, forKey: .documentMatching) ?? .binary
        sendsDocumentMetadata = try c.decodeIfPresent(Bool.self, forKey: .sendsDocumentMetadata) ?? false
    }

    var isConfigured: Bool {
        !serverURL.isEmpty && !username.isEmpty && !passwordHash.isEmpty
    }

    var baseURL: URL? {
        guard !serverURL.isEmpty else { return nil }
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        return URL(string: trimmed)
    }
}

struct KOReaderProgress: Codable, Equatable {
    let document: String
    let progress: String
    let percentage: Double
    let device: String
    let deviceId: String
    let timestamp: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device
        case deviceId = "device_id"
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        document = try c.decodeIfPresent(String.self, forKey: .document) ?? ""
        progress = try c.decodeIfPresent(String.self, forKey: .progress) ?? ""
        percentage = try c.decodeIfPresent(Double.self, forKey: .percentage) ?? 0
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        timestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

/// Send the filename only. The server does not need the user's folder path.
struct KOReaderDocumentMetadata: Equatable, Sendable {
    let filename: String
    let title: String
    let authors: String

    var jsonObject: [String: String]? {
        var object: [String: String] = [:]
        if !filename.isEmpty { object["filename"] = filename }
        if !title.isEmpty { object["title"] = title }
        if !authors.isEmpty { object["authors"] = authors }
        return object.isEmpty ? nil : object
    }
}

struct KOReaderDocumentMatchPlan: Equatable, Sendable {
    let pushHash: String
    let fetchCandidates: [String]

    static func make(
        matching: KOReaderDocumentMatching,
        link: KOReaderBookLink?,
        binaryHash: String?,
        filenameHash: String?
    ) -> KOReaderDocumentMatchPlan? {
        // Use the hash the user picked. Don't replace it with an automatic match.
        if let link, !link.isAutomatic {
            return KOReaderDocumentMatchPlan(pushHash: link.documentHash, fetchCandidates: [link.documentHash])
        }

        switch matching {
        case .binary:
            guard let hash = binaryHash ?? link?.documentHash else { return nil }
            return KOReaderDocumentMatchPlan(pushHash: hash, fetchCandidates: [hash])
        case .filename:
            guard let hash = filenameHash else { return nil }
            return KOReaderDocumentMatchPlan(pushHash: hash, fetchCandidates: [hash])
        case .smart:
            // Try the paired hash first, but keep the others in case the other device changes methods.
            var ordered: [String] = []
            for candidate in [link?.matchedHash, link?.documentHash, binaryHash, filenameHash] {
                guard let candidate, !candidate.isEmpty, !ordered.contains(candidate) else { continue }
                ordered.append(candidate)
            }
            guard let pushHash = ordered.first else { return nil }
            return KOReaderDocumentMatchPlan(pushHash: pushHash, fetchCandidates: ordered)
        }
    }
}

struct KOReaderFileIdentity: Codable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int64
    let modifiedAtMilliseconds: Int64

    static func read(fileURL: URL) -> KOReaderFileIdentity? {
        guard
            let values = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = values[.size] as? NSNumber,
            let modified = values[.modificationDate] as? Date
        else {
            return nil
        }
        return KOReaderFileIdentity(
            path: fileURL.path,
            sizeBytes: size.int64Value,
            modifiedAtMilliseconds: Int64((modified.timeIntervalSince1970 * 1000).rounded())
        )
    }
}

struct KOReaderBookLink: Codable, Equatable, Identifiable {
    var id: String { bookStableId }
    let bookStableId: String
    var documentHash: String

    var isAutomatic: Bool
    var lastSyncedAt: Date?
    var lastSyncedPercentage: Double?
    // Clear this when the user sets a hash manually.
    var fileIdentity: KOReaderFileIdentity?
    // Old hashes, newest first. Keep for troubleshooting and manual relinking, not sync.
    var previousHashes: [String]
    // Keep the filename hash so matching still works after the local file is removed.
    var filenameHash: String?
    // Push to the last matched hash without changing documentHash.
    var matchedHash: String?

    enum CodingKeys: String, CodingKey {
        case bookStableId, documentHash, isAutomatic, lastSyncedAt, lastSyncedPercentage
        case fileIdentity, previousHashes, filenameHash, matchedHash
    }

    init(
        bookStableId: String,
        documentHash: String,
        isAutomatic: Bool,
        lastSyncedAt: Date? = nil,
        lastSyncedPercentage: Double? = nil,
        fileIdentity: KOReaderFileIdentity? = nil,
        previousHashes: [String] = [],
        filenameHash: String? = nil,
        matchedHash: String? = nil
    ) {
        self.bookStableId = bookStableId
        self.documentHash = documentHash
        self.isAutomatic = isAutomatic
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncedPercentage = lastSyncedPercentage
        self.fileIdentity = fileIdentity
        self.previousHashes = previousHashes
        self.filenameHash = filenameHash
        self.matchedHash = matchedHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookStableId = try c.decode(String.self, forKey: .bookStableId)
        documentHash = try c.decode(String.self, forKey: .documentHash)
        isAutomatic = try c.decode(Bool.self, forKey: .isAutomatic)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastSyncedPercentage = try c.decodeIfPresent(Double.self, forKey: .lastSyncedPercentage)
        fileIdentity = try c.decodeIfPresent(KOReaderFileIdentity.self, forKey: .fileIdentity)
        previousHashes = try c.decodeIfPresent([String].self, forKey: .previousHashes) ?? []
        filenameHash = try c.decodeIfPresent(String.self, forKey: .filenameHash)
        matchedHash = try c.decodeIfPresent(String.self, forKey: .matchedHash)
    }
}
