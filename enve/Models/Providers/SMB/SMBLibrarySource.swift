import Foundation

nonisolated struct SMBLibrarySource: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let hostname: String
    let port: Int
    let shareName: String
    let username: String
    let folderPath: String
    let createdAt: Date
    var lastScanned: Date?
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        hostname: String,
        port: Int = 445,
        shareName: String,
        username: String,
        folderPath: String = "/",
        createdAt: Date = Date(),
        lastScanned: Date? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.shareName = shareName
        self.username = username
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.lastScanned = lastScanned
        self.isEnabled = isEnabled
    }

    nonisolated func toServerConfiguration() -> SMBServerConfiguration {
        SMBServerConfiguration(
            displayName: name,
            hostname: hostname,
            port: port,
            shareName: shareName,
            username: username,
            rootPath: folderPath
        )
    }

    var connectionDisplay: String {
        "\(username)@\(hostname)/\(shareName)\(folderPath)"
    }
}

struct SMBLibraryScanResult: Sendable {
    let booksFound: Int
    let booksAdded: Int
    let booksUpdated: Int
    let errors: [String]
    let scanDuration: TimeInterval
}
