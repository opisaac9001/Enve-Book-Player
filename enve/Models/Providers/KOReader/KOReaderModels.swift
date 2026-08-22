import Foundation

struct KOReaderConfig: Codable, Equatable {
    var serverURL: String
    var username: String

    var passwordHash: String
    var autoSyncEnabled: Bool

    init(serverURL: String = "", username: String = "", passwordHash: String = "", autoSyncEnabled: Bool = true) {
        self.serverURL = serverURL
        self.username = username
        self.passwordHash = passwordHash
        self.autoSyncEnabled = autoSyncEnabled
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

struct KOReaderBookLink: Codable, Equatable, Identifiable {
    var id: String { bookStableId }
    let bookStableId: String
    var documentHash: String

    var isAutomatic: Bool
    var lastSyncedAt: Date?
    var lastSyncedPercentage: Double?
}
