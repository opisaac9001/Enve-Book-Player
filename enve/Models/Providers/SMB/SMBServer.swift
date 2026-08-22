import Foundation

nonisolated struct SMBServerConfiguration: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var shareName: String
    var username: String
    var rootPath: String

    init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 445,
        shareName: String,
        username: String,
        rootPath: String = "/"
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.shareName = shareName
        self.username = username
        self.rootPath = rootPath.hasPrefix("/") ? rootPath : "/\(rootPath)"
    }
}

struct SMBScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case enumerating
        case analyzing
        case complete
        case failed(String)
    }

    let phase: Phase
    let currentPath: String?
    let foldersScanned: Int
    let audiobooksFound: Int
    let startTime: Date

    var elapsed: TimeInterval { Date().timeIntervalSince(startTime) }

    static var initial: SMBScanProgress {
        SMBScanProgress(
            phase: .idle,
            currentPath: nil,
            foldersScanned: 0,
            audiobooksFound: 0,
            startTime: Date()
        )
    }
}
