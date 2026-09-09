import Foundation
import Testing

@testable import enve

@MainActor
struct ProviderLiveSyncTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_LAB_DOCUMENT"] != nil),
          arguments: ["Audiobookshelf", "Jellyfin", "Emby", "Plex", "Komga", "Kavita", "Grimmory", "Storyteller", "BookOrbit", "Silo"].filter {
              guard let selected = ProcessInfo.processInfo.environment["ENVE_LAB_SERVICE"] else { return true }
              return $0 == selected
          })
    func progressRoundTrip(service: String) async throws {
        let document = try #require(ProcessInfo.processInfo.environment["ENVE_LAB_DOCUMENT"])
        let text = try String(contentsOfFile: document, encoding: .utf8)
        var rows: [String: String] = [:]
        var endpoints: [String: String] = [:]
        func values(_ row: String) -> [String] {
            row.split(separator: "`", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        }
        for line in text.split(separator: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            rows[cells[1]] = cells[2]
            if let url = values(cells[2]).first, url.hasPrefix("http") { endpoints[cells[1]] = url }
        }
        let endpoint = try #require(endpoints[service])
        let host = try #require(URL(string: endpoint)?.host)
        let permittedHosts = ["LAN address", "Tailscale address"].flatMap { values(rows[$0] ?? "") }
        guard permittedHosts.contains(host) else { throw LabError.nonLabEndpoint }
        var username = try #require(values(rows["Username"] ?? "").first)
        var password = try #require(values(rows["Password"] ?? "").first)
        if service == "Komga" { username = try #require(values(rows["Email"] ?? "").first) }
        if service == "Storyteller" { username = try #require(values(rows["Storyteller local administrator"] ?? "").first) }
        if service == "BookOrbit" {
            let credentials = values(rows[service] ?? "")
            username = try #require(credentials.first)
            password = try #require(credentials.last)
        }
        let type: ProviderType
        switch service {
        case "Audiobookshelf": type = .audiobookshelf
        case "Jellyfin": type = .jellyfin
        case "Emby": type = .emby
        case "Plex": type = .plex
        case "Komga": type = .komga
        case "Kavita": type = .kavita
        case "Grimmory": type = .booklore
        case "Storyteller": type = .storyteller
        case "BookOrbit": type = .bookOrbit
        default: type = .silo
        }
        let plexToken = service == "Plex" ? values(rows["Plex token"] ?? "").first : nil
        let connection = ServerConnection(name: "Disposable sync test", url: endpoint, type: type,
                                          username: username, password: password, token: plexToken)
        let provider: any LibraryProvider
        switch type {
        case .audiobookshelf: provider = AudiobookshelfProvider(connection: connection)
        case .jellyfin: provider = JellyfinProvider(connection: connection)
        case .emby: provider = EmbyProvider(connection: connection)
        case .plex: provider = PlexProvider(connection: connection)
        case .komga: provider = KomgaProvider(connection: connection)
        case .kavita: provider = KavitaProvider(connection: connection)
        case .booklore: provider = BookloreProvider(connection: connection)
        case .storyteller: provider = StorytellerProvider(connection: connection)
        case .bookOrbit: provider = BookOrbitProvider(connection: connection)
        default: provider = SiloProvider(connection: connection)
        }
        var stage = "authentication"
        do {
            guard try await provider.validateConnection() else { throw LabError.rejected }
            record("LAB \(service) authentication passed")
            stage = "catalog"
            let libraries = try await provider.fetchLibraries()
            var books: [Book] = []
            for library in libraries {
                if service == "Plex", !library.name.localizedCaseInsensitiveContains("audiobook") { continue }
                if service == "Emby" || service == "Jellyfin" || service == "BookOrbit" {
                    books += try await provider.fetchBooks(libraryId: library.id)
                } else {
                    books += try await provider.fetchRecentBooks(libraryId: library.id, limit: 10)
                }
            }
            record("LAB \(service) catalog libraries=\(libraries.count) books=\(books.count) ebooks=\(books.filter { $0.mediaType == .ebook }.count)")
            guard !books.isEmpty else { throw LabError.emptyCatalog }
            if service == "BookOrbit" {
                for book in books {
                    let detail = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
                    guard detail.id == book.id else { throw LabError.rejected }
                }
                record("LAB BookOrbit full catalog and details passed books=\(books.count)")
            }
            if let candidate = books.first(where: { $0.mediaType == .audiobook && ($0.duration ?? 0) <= 0 }),
               let index = books.firstIndex(where: { $0.stableId == candidate.stableId }) {
                books[index] = try await provider.fetchFullBookDetails(bookId: candidate.id, libraryId: candidate.libraryId)
            }
            if let download = provider as? any EbookDownloadProvider,
               let book = books.first(where: { $0.mediaType == .ebook && $0.ebookFormat?.lowercased() == "epub" }) ?? books.first(where: { $0.mediaType == .ebook }) {
                stage = "ebook download"
                let url = try await download.downloadEbook(for: book, onProgress: nil)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 else { throw LabError.rejected }
                record("LAB \(service) ebook downloaded bytes=\(size)")
            }
            if let sync = provider as? any EbookProgressProvider,
               let book = books.first(where: { $0.mediaType == .ebook && $0.ebookFormat?.lowercased() == "epub" }) ?? books.first(where: { $0.mediaType == .ebook }) {
                stage = "ebook round trip"
                record("LAB \(service) ebook fixture=\(book.title)")
                let tolerance: Double
                if let pages = provider as? KomgaProvider {
                    tolerance = 1 / Double(try await pages.fetchPageCount(for: book)) + 0.001
                } else if let kavita = provider as? KavitaProvider {
                    let request = try kavita.makeRequest(path: "/api/Series/volumes?seriesId=\(book.id)")
                    let (data, _) = try await kavita.send(request)
                    let volumes = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                    let chapters = try #require(volumes.first?["chapters"] as? [[String: Any]])
                    let pages = try #require(chapters.first?["pages"] as? Int)
                    tolerance = 1 / Double(pages) + 0.001
                } else { tolerance = 0.06 }
                let original = try await sync.fetchEbookProgress(for: book)
                do {
                    for fraction in [0.42, 1.0, 0.0] {
                        try await sync.updateEbookProgress(for: book, progress: fraction, epubLocator: nil)
                        let remote = try await sync.fetchEbookProgress(for: book)
                        record("LAB \(service) ebook sent=\(fraction) received=\(remote?.progress ?? -1)")
                        guard abs((remote?.progress ?? 0) - fraction) < tolerance else { throw LabError.progressMismatch }
                    }
                } catch {
                    try await sync.updateEbookProgress(for: book, progress: original?.progress ?? 0, epubLocator: original?.locator)
                    throw error
                }
                try await sync.updateEbookProgress(for: book, progress: original?.progress ?? 0, epubLocator: original?.locator)
            }
            if let sync = provider as? any AudiobookProgressProvider,
               let book = books.first(where: { $0.mediaType == .audiobook && ($0.duration ?? 0) > 30 }) {
                stage = "audiobook round trip"
                record("LAB \(service) audio fixture=\(book.title) duration=\(book.duration ?? 0) podcast=\(book.isPodcastEpisode)")
                let original = try await sync.fetchAudiobookProgress(for: book)
                var activeSession: PlaybackSessionInfo?
                do {
                    if let playback = provider as? any PlaybackSessionProvider {
                        stage = "stream and seek"
                        let session = try await playback.startPlaybackSession(for: book)
                        activeSession = session
                        let track = try #require(session.audioTracks.first)
                        let url = try #require(URL(string: track.contentUrl))
                        for offset in [0, 65536] {
                            var request = URLRequest(url: url)
                            request.timeoutInterval = 30
                            for (key, value) in playback.getStreamingHeaders() { request.setValue(value, forHTTPHeaderField: key) }
                            request.setValue("bytes=\(offset)-\(offset + 1023)", forHTTPHeaderField: "Range")
                            let (data, response) = try await URLSession.shared.data(for: request)
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            record("LAB \(service) stream range=\(offset) HTTP=\(status)")
                            guard status == 206, !data.isEmpty else { throw LabError.rejected }
                        }
                        record("LAB \(service) stream and byte-range seek passed")
                    }
                    stage = "audiobook round trip"
                    for seconds in [23.0, 0.0] {
                        try await sync.updatePlaybackProgress(book: book, sessionId: nil, currentTime: seconds, isFinished: false, timeListened: 0)
                        let remote = try await sync.fetchAudiobookProgress(for: book)
                        record("LAB \(service) audiobook sent=\(seconds) received=\(remote?.positionSeconds ?? -1)")
                        guard abs((remote?.positionSeconds ?? 0) - seconds) < 1 else { throw LabError.progressMismatch }
                    }
                } catch {
                    try await sync.updatePlaybackProgress(book: book, sessionId: nil, currentTime: original?.positionSeconds ?? 0, isFinished: book.isFinished, timeListened: 0)
                    try await closeSession(activeSession, provider: provider, book: book, position: original?.positionSeconds ?? 0)
                    throw error
                }
                try await sync.updatePlaybackProgress(book: book, sessionId: nil, currentTime: original?.positionSeconds ?? 0, isFinished: book.isFinished, timeListened: 0)
                try await closeSession(activeSession, provider: provider, book: book, position: original?.positionSeconds ?? 0)
            }
            record("LAB \(service) passed")
        } catch {
            let message: String
            if let decoding = error as? DecodingError {
                switch decoding {
                case .keyNotFound(let key, _): message = "missing key " + key.stringValue
                case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                    message = "decode " + context.codingPath.map(\.stringValue).joined(separator: ".")
                @unknown default: message = "decode failure"
                }
            } else {
                message = String(reflecting: Swift.type(of: error)) + " code " + String((error as NSError).code)
            }
            record("LAB \(service) failed at \(stage): \(message)")
            Issue.record("Lab \(service) failed at \(stage): \(message)")
        }
    }

    private func closeSession(_ session: PlaybackSessionInfo?, provider: any LibraryProvider, book: Book, position: Double) async throws {
        guard let session, let playback = provider as? any PlaybackSessionProvider else { return }
        let path: String
        switch provider.connection.type {
        case .audiobookshelf: path = "/api/session/\(session.sessionId)/close"
        case .silo: path = "/api/v1/playback/\(session.sessionId)"
        default: return
        }
        let url = try #require(URL(string: provider.connection.url + path))
        var request = URLRequest(url: url)
        request.httpMethod = provider.connection.type == .silo ? "DELETE" : "POST"
        for (key, value) in playback.getStreamingHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        if provider.connection.type == .audiobookshelf {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "currentTime": position, "duration": book.duration ?? 0, "timeListened": 0,
            ])
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw LabError.rejected }
    }

    private func record(_ message: String) {
        print(message)
        if let path = ProcessInfo.processInfo.environment["ENVE_LAB_EVENTS"],
           let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data((message + "\n").utf8))
        }
    }

    private enum LabError: Error {
        case nonLabEndpoint, rejected, emptyCatalog, progressMismatch
    }
}
