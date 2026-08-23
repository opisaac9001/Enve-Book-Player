import Foundation

public enum HistorySource: String, Codable, Sendable {
    case local
    case audiobookshelf
    case grimmory
    case plex
    case jellyfin
    case hardcover
    case bookOrbit = "bookorbit"
}

public struct HistorySession: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let bookId: String
    public let mediaType: String
    public let startTime: Date
    public let endTime: Date
    public let durationSeconds: Int
    public let startProgress: Double?
    public let endProgress: Double?
    public let progressDelta: Double?
    public let startLocation: String?
    public let endLocation: String?
    public let pagesRead: Int?
    public let source: HistorySource

    public var formattedDuration: String {
        let h = durationSeconds / 3600
        let m = (durationSeconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    public var formattedProgressDelta: String? {
        guard let delta = progressDelta, delta > 0 else { return nil }
        return "+\(Int(delta * 100))%"
    }
}

public actor HistorySessionStore {
    public static let shared = HistorySessionStore()

    private let listeningURL: URL
    private let readingURL: URL
    private var listeningCache: [HistorySession]?
    private var readingCache: [HistorySession]?

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Enve/History", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        listeningURL = dir.appendingPathComponent("listening_sessions.json")
        readingURL = dir.appendingPathComponent("reading_sessions.json")
    }

    public func appendListeningSession(_ session: HistorySession) async {
        var sessions = await loadListeningSessions()
        sessions.insert(session, at: 0)
        if sessions.count > 500 { sessions = Array(sessions.prefix(500)) }
        listeningCache = sessions
        persist(sessions, to: listeningURL)
    }

    public func loadListeningSessions(bookId: String? = nil) async -> [HistorySession] {
        if listeningCache == nil {
            listeningCache = load(from: listeningURL)
        }
        guard let bookId else { return listeningCache ?? [] }
        return (listeningCache ?? []).filter { $0.bookId == bookId }
    }

    public func appendReadingSession(_ session: HistorySession) async {
        var sessions = await loadReadingSessions()
        sessions.insert(session, at: 0)
        if sessions.count > 500 { sessions = Array(sessions.prefix(500)) }
        readingCache = sessions
        persist(sessions, to: readingURL)
    }

    public func loadReadingSessions(bookId: String? = nil) async -> [HistorySession] {
        if readingCache == nil {
            readingCache = load(from: readingURL)
        }
        guard let bookId else { return readingCache ?? [] }
        return (readingCache ?? []).filter { $0.bookId == bookId }
    }

    @discardableResult
    public func replaceBookOrbitSessions(
        _ remoteSessions: [HistorySession],
        connectionId: UUID,
        bookId: String,
        mediaType: AppMediaType
    ) async -> Int {
        let prefix = "bookorbit:\(connectionId.uuidString):"
        var sessions = mediaType == .audiobook
            ? await loadListeningSessions()
            : await loadReadingSessions()
        let previousRemoteIds = Set(
            sessions
                .filter { $0.bookId == bookId && $0.source == .bookOrbit && $0.id.hasPrefix(prefix) }
                .map(\.id)
        )
        let localSessions = sessions.filter { $0.bookId == bookId && $0.source == .local }
        let imported = remoteSessions.filter { remote in
            !localSessions.contains { local in
                abs(local.startTime.timeIntervalSince(remote.startTime)) <= 2
                    && abs(local.endTime.timeIntervalSince(remote.endTime)) <= 2
                    && abs(local.durationSeconds - remote.durationSeconds) <= 2
            }
        }
        let importedIds = Set(imported.map(\.id))

        sessions.removeAll {
            $0.bookId == bookId && $0.source == .bookOrbit && $0.id.hasPrefix(prefix)
        }
        sessions.append(contentsOf: imported)
        sessions.sort { $0.endTime > $1.endTime }
        if sessions.count > 500 { sessions = Array(sessions.prefix(500)) }

        if mediaType == .audiobook {
            listeningCache = sessions
            persist(sessions, to: listeningURL)
        } else {
            readingCache = sessions
            persist(sessions, to: readingURL)
        }
        return previousRemoteIds.symmetricDifference(importedIds).count
    }

    private func load(from url: URL) -> [HistorySession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistorySession].self, from: data)) ?? []
    }

    private func persist(_ sessions: [HistorySession], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
