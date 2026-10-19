import AVFoundation
import Foundation
import Testing
import UIKit

@testable import enve

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENVE_LAB_SERVICE"] == "BookloreRefactor"
    && ProcessInfo.processInfo.environment["ENVE_LAB_DOCUMENT"] != nil))
struct BookloreRefactorLiveTests {
    @Test func refreshRecoveryAndReopenedCredentials() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            #expect(provider.refreshToken != nil)
            provider.connection.token = "invalid-refactor-regression-token"
            async let user = provider.fetchCurrentUser()
            async let libraries = provider.fetchLibraries()
            async let shelves = provider.fetchShelfSummaries()
            let values = try await (user, libraries, shelves)
            #expect(values.0.id > 0)
            #expect(!values.1.isEmpty)

            var connection = provider.connection
            connection.token = nil
            let reopened = BookloreProvider(connection: connection, profileSession: fixture.session)
            do {
                #expect(reopened.refreshToken != nil)
                #expect(try await reopened.validateConnection())
                #expect(try await reopened.fetchCurrentUser().id == values.0.id)
            } catch {
                await reopened.retire()
                throw error
            }
            await reopened.retire()
            fixture.record("concurrent 401 recovery and credential-backed reopen")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_LAB_REFRESH_GATE"] == "1"))
    func freshServerRefreshTokenIsAccepted() async throws {
        try await Fixture.run { fixture in
            let original = try #require(fixture.provider.refreshToken)
            if let jwt = BookloreJWT(original), !jwt.isActive() {
                #expect(!fixture.provider.shouldAttemptTokenRefresh())
                #expect(!(await fixture.provider.refreshStreamingTokenIfNeeded(force: true)))
                #expect(fixture.provider.refreshToken == original)
            }
            try await waitForRefreshActivation(fixture.provider)
            try #require(await fixture.provider.refreshStreamingTokenIfNeeded(force: true),
                "Lab server rejected an active refresh token")
            var connection = fixture.provider.connection
            connection.username = nil
            connection.password = nil
            connection.token = nil
            let reopened = BookloreProvider(connection: connection, profileSession: fixture.session)
            defer { reopened.keychain.delete(reopened.refreshTokenKeychainKey) }
            do {
                try await waitForRefreshActivation(reopened)
                #expect(try await reopened.validateConnection())
                await reopened.retire()
            } catch {
                await reopened.retire()
                throw error
            }
            fixture.record("token rotation and refresh-only reopen")
        }
    }

    private func waitForRefreshActivation(_ provider: BookloreProvider) async throws {
        let token = try #require(provider.refreshToken)
        let nbf = BookloreJWT(token)?.nbf ?? 0
        let delay = max(0, nbf - Date().timeIntervalSince1970 + 1)
        try #require(delay <= 125, "Unexpected lab refresh activation delay")
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    @Test func uncachedSearchAcrossSourceAndAllLibraries() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            let target = try await fixture.book(search: "Enve Namespace Prefix Regression")
            let count = try await provider.remoteBookCount(libraryId: target.libraryId)
            try #require(count > RemoteLibraryBrowseStore.bookCountThreshold)
            fixture.session.remoteLibraryBrowse.record(providerId: provider.connection.id, libraryId: target.libraryId, bookCount: count)
            var connection = provider.connection
            connection.isConnected = true
            connection.selectedLibraryIds = [target.libraryId]
            fixture.session.providerConnections.connections = [connection]
            if let generated = fixture.session.providerConnections[connection.id] { await generated.retire() }
            fixture.session.providerConnections[connection.id] = provider
            let library = fixture.session.engine.library
            for scope: LibrarySourceFilter in [.all, .connection(connection.id), .library(providerId: connection.id, libraryId: target.libraryId)] {
                let results = await library.searchBooks(query: "Enve Namespace Prefix Regression", sourceFilter: scope, limit: 200)
                #expect(results.contains { $0.id == target.id })
                #expect(results.allSatisfy { $0.providerId == connection.id })
                #expect(Set(results.map(\.uniqueId)).count == results.count)
            }
            #expect(await library.searchBooks(query: "Enve Namespace Prefix Regression", sourceFilter: .device, limit: 200).isEmpty)
            fixture.record("uncached remote search in all, connection, and selected-library scopes")
        }
    }

    @Test func completeCatalogResumeBrowseDeltaAndCancellation() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            let libraries = try await provider.fetchLibraries()
            var counts: [(Library, Int)] = []
            for library in libraries {
                counts.append((library, try await provider.remoteBookCount(libraryId: library.id)))
            }
            let large = try #require(counts.max { $0.1 < $1.1 })
            let small = try #require(counts.filter { $0.1 > 0 }.min { $0.1 < $1.1 })
            let started = Date()
            var importSession = try await provider.openCatalogImport(libraryId: large.0.id)
            var identities = Set<String>()
            var resumed = false
            while let batch = try await provider.nextCatalogImportBatch(importSession) {
                #expect(!batch.books.isEmpty)
                #expect(Set(batch.books.map(\.uniqueId)).count == batch.books.count)
                for book in batch.books {
                    #expect(book.providerId == provider.connection.id)
                    identities.insert(book.uniqueId)
                }
                try provider.markCatalogImportBatchCommitted(batch, session: importSession)
                if !resumed {
                    let committed = importSession.checkpoint.committedPages
                    importSession = try await provider.openCatalogImport(libraryId: large.0.id)
                    #expect(importSession.checkpoint.committedPages == committed)
                    resumed = true
                }
            }
            var summaryIDs = Set<String>()
            var rejectedCount = 0
            for pageNumber in 0..<importSession.totalPages {
                let data = try provider.catalogCheckpoints.pageData(connectionId: provider.connection.id,
                    libraryId: large.0.id, page: pageNumber)
                let page = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                summaryIDs.formUnion(page.content.map { $0.id.stringValue })
                rejectedCount += page.rejectedItems.count
            }
            let missingIDs = summaryIDs.filter {
                !identities.contains("\(provider.connection.id)_\($0)")
            }
            for id in missingIDs {
                let data = try await fixture.request(path: "/api/v1/books/batch?ids=\(id)")
                let records = try JSONDecoder().decode([BookloreLegacyBook].self, from: data)
                #expect(records.isEmpty, "A valid server format record was lost during import")
            }
            #expect(importSession.completedSnapshot == (rejectedCount == 0 && missingIDs.isEmpty))
            #expect(identities.count >= summaryIDs.count - missingIDs.count)
            fixture.record("catalog safety: \(rejectedCount) rejected summaries, \(missingIDs.count) missing server format records")
            #expect(importSession.checkpoint.committedPages?.count == importSession.totalPages)
            provider.completeCatalogSync(libraryId: large.0.id)
            fixture.record("full catalog and committed resume: \(identities.count) identities, \(Int(Date().timeIntervalSince(started))) seconds")

            let expected = try await provider.remoteBooksPage(libraryId: large.0.id, offset: 0, limit: 60,
                sort: .title, descending: false)
            let window = try await provider.remoteBooksPage(libraryId: large.0.id, offset: 7, limit: 53,
                sort: .title, descending: false)
            #expect(window.books.map(\.id) == Array(expected.books.dropFirst(7)).map(\.id))
            #expect(window.totalCount == large.1)
            let snapshot = try await provider.fetchBooks(libraryId: small.0.id)
            #expect(!snapshot.isEmpty)
            #expect(Set(snapshot.map(\.uniqueId)).count == snapshot.count)
            let future = Date().addingTimeInterval(60)
            let emptyDelta = try #require(try await provider.fetchBooksDelta(libraryId: large.0.id, since: future))
            #expect(emptyDelta.books.isEmpty)
            let delta = try #require(try await provider.fetchBooksDelta(libraryId: large.0.id,
                since: Date().addingTimeInterval(-7 * 86_400)))
            #expect(delta.cursor <= future)
            let task = Task { try await provider.fetchBooksDelta(libraryId: large.0.id, since: .distantPast) }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Cancelled catalog request completed instead of propagating cancellation")
            } catch {
                #expect(BookloreProvider.isCancellation(error))
            }
            fixture.record("paged browse, snapshot, incremental refresh, and cancellation")
        }
    }

    @Test func dualFormatsDownloadsStreamingAndCovers() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            let libraries = try await provider.fetchLibraries()
            for id in ["30279", "30280", "30278"] {
                let detail = try await provider.fetchFullBookDetails(bookId: id, libraryId: "")
                #expect(detail.mediaType == .ebook)
                #expect(detail.ebookFormat == "epub")
                #expect(detail.linkedAudiobookStableId != nil)
                #expect(!detail.hasAlternateFormat)
                let enriched = try await provider.fetchFullBookDetails(
                    bookId: BookloreProvider.companionAudiobookIDPrefix + id, libraryId: detail.libraryId)
                #expect(enriched.mediaType == .audiobook)
                let playback = try await provider.startPlaybackSession(for: enriched)
                #expect(!playback.audioTracks.isEmpty)
                for track in playback.audioTracks {
                    let url = try #require(URL(string: track.contentUrl))
                    let asset = AVURLAsset(url: url, options: [
                        "AVURLAssetHTTPHeaderFieldsKey": provider.getStreamingHeaders(),
                    ])
                    #expect(try await asset.load(.isPlayable))
                    #expect(try await asset.load(.duration).seconds > 0)
                    var request = URLRequest(url: url)
                    provider.addAuthHeaders(&request)
                    let (data, response) = try await provider.send(request)
                    #expect(response.statusCode == 200)
                    #expect(!data.isEmpty)
                    let local = fixture.root.appendingPathComponent("audio-\(id)-\(track.index).m4b")
                    try data.write(to: local)
                    #expect(try await AVURLAsset(url: local).load(.isPlayable))
                    #expect(try await AVURLAsset(url: local).load(.duration).seconds > 0)
                }
                let downloaded = try await provider.downloadEbook(for: detail, onProgress: nil)
                #expect((try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
            }
            let book = try await fixture.book(search: "Enve Namespace Prefix Regression")
            let stream = try await provider.makeEpubStreamingSession(for: book)
            #expect(!stream.entries.isEmpty)
            let page = try #require(stream.entries.first { $0.path.hasSuffix(".xhtml") })
            let text = try await stream.resourceData(atPath: page.path)
            #expect(String(decoding: text, as: UTF8.self).contains("Unicode"))
            for library in libraries {
                let books = try await provider.fetchRecentBooks(libraryId: library.id, limit: 2)
                for book in books {
                    guard let cover = book.coverURL else { continue }
                    let (data, status) = try await provider.fetchImageData(url: cover)
                    #expect(status == 200 || status == 404)
                    if status == 200 { #expect(UIImage(data: data) != nil) }
                }
            }
            fixture.record("both dual-format primary orders, audio sessions, EPUB download/stream, and authenticated covers")
        }
    }

    @Test func shelvesMagicShelvesSavedBooksAndRatings() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            let book = try await fixture.book(search: "Enve Namespace Prefix Regression")
            let bookID = try #require(Int(book.id))
            let prefix = "Enve refactor regression \(UUID().uuidString)"
            let shelf = try await provider.createShelf(name: prefix, icon: "book")
            fixture.cleanup.append { try await provider.deleteShelf(id: shelf.id) }
            try await provider.updateShelf(id: shelf.id, name: prefix + " renamed", icon: "bookmark")
            _ = try await fixture.request(path: "/api/v1/books/shelves", method: "POST", json: [
                "bookIds": [bookID], "shelvesToAssign": [shelf.id], "shelvesToUnassign": [Int](),
            ])
            let collections = try await provider.fetchCollections(libraryId: nil)
            let loaded = try #require(collections.first { $0.id == String(shelf.id) })
            #expect(loaded.name == prefix + " renamed")
            #expect(loaded.books.contains(book.id))
            #expect(loaded.books.count == loaded.bookCount)

            let filter = GrimmoryMagicShelf.buildFilterJson(join: "and", rules: [
                MagicShelfRule(field: "title", op: "contains", value: "Enve Namespace Prefix Regression"),
            ])
            let magic = try await provider.saveMagicShelf(GrimmoryMagicShelf(id: nil, name: prefix,
                icon: nil, iconType: nil, filterJson: filter, isPublic: false))
            let magicID = try #require(magic.id)
            fixture.cleanup.append { try await provider.deleteMagicShelf(id: magicID) }
            #expect(try await provider.fetchMagicShelves().contains { $0.id == magicID })
            #expect(try await provider.fetchCollections(libraryId: nil).contains { $0.id == "magic-\(magicID)" && $0.books.contains(book.id) })

            let original = try await provider.fetchSavedBookIDs(libraryIds: Set([book.libraryId]))
            let shelves = try await provider.fetchGrimmoryShelves()
            for list in SavedBookList.allCases {
                let name = list == .favorites ? "Favorites" : "Enve For Later"
                if !shelves.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    let created = try await provider.createShelf(name: name)
                    fixture.cleanup.append { try await provider.deleteShelf(id: created.id) }
                }
                let wasSaved = original[list]?.contains(book.id) == true
                fixture.cleanup.append { try await provider.setSavedBook(book, list: list, saved: wasSaved) }
                try await provider.setSavedBook(book, list: list, saved: !wasSaved)
                let changed = try await provider.fetchSavedBookIDs(libraryIds: Set([book.libraryId]))
                #expect(changed[list]?.contains(book.id) == !wasSaved)
            }

            let detail = try await fixture.request(path: "/api/v1/app/books/\(bookID)")
            let object = try #require(JSONSerialization.jsonObject(with: detail) as? [String: Any])
            let originalRating = (object["personalRating"] as? NSNumber)?.intValue
            fixture.cleanup.append {
                if let originalRating {
                    _ = try await fixture.request(path: "/api/v1/books/personal-rating", method: "PUT",
                        json: ["ids": [bookID], "rating": originalRating])
                } else {
                    _ = try await fixture.request(path: "/api/v1/books/reset-personal-rating", method: "POST", json: [bookID])
                }
            }
            try await provider.updatePersonalRating(for: book, rating: 4)
            let ratedData = try await fixture.request(path: "/api/v1/app/books/\(bookID)")
            let rated = try #require(JSONSerialization.jsonObject(with: ratedData) as? [String: Any])
            #expect((rated["personalRating"] as? NSNumber)?.intValue == 8)
            fixture.record("shelf create/rename/membership, magic filters, favorites/for-later, and personal rating")
        }
    }

    @Test func notebookBookmarksAnnotationsAndNotes() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            let book = try await fixture.book(search: "Enve Namespace Prefix Regression")
            let cfi = "epubcfi(/6/2!/4/2/2)"
            let label = "Enve refactor regression \(UUID().uuidString)"
            let bookmark = try await provider.createRemoteBookmark(for: book, title: label, note: "Test note",
                locator: cfi, color: "#FF0000", priority: 1)
            fixture.cleanup.append { try await provider.deleteRemoteBookmark(id: bookmark.id) }
            #expect(bookmark.notes == "Test note")
            #expect(try await provider.fetchRemoteBookmarks(for: book).contains { $0.id == bookmark.id })
            var annotation = ReaderAnnotation(bookId: book.id, locator: cfi, text: label, note: "Original")
            let created = try await provider.createRemoteAnnotation(for: book, annotation: annotation)
            fixture.cleanup.append { try await provider.deleteRemoteAnnotation(id: created.id) }
            annotation.style = .underline
            annotation.note = "Edited"
            let updated = try await provider.updateRemoteAnnotation(id: created.id, annotation: annotation)
            #expect(updated.style == "underline")
            #expect(updated.note == "Edited")
            #expect(try await provider.fetchRemoteAnnotations(for: book).contains { $0.id == created.id })
            let note = try await provider.createBookNote(for: book, cfi: cfi, selectedText: label, noteContent: "Test book note")
            fixture.cleanup.append { _ = try await fixture.request(path: "/api/v2/book-notes/\(note.id)", method: "DELETE") }
            #expect(note.noteContent == "Test book note")
            let entries = try await provider.fetchNotebookEntries(for: book)
            #expect(entries.contains { $0.type == .bookmark && $0.id == bookmark.id })
            #expect(entries.contains { $0.type == .highlight && $0.id == created.id })
            #expect(entries.contains { $0.type == .note && $0.id == note.id })
            fixture.record("bookmark create/update, annotation create/update, book notes, and unified notebook")
        }
    }

    @Test func statisticsAdministrationAndCompatibilityTiers() async throws {
        try await Fixture.run { fixture in
            let provider = fixture.provider
            let current = try await provider.fetchCurrentUser()
            let users = try await provider.fetchUsers()
            #expect(users.contains { $0.id == current.id })
            #expect(try await provider.fetchUser(id: current.id).id == current.id)
            let recent = try await provider.fetchRecentBooks(limit: 20)
            #expect(!recent.isEmpty)
            let sessions = try await provider.fetchReadingSessions(limit: 20)
            #expect(sessions.count <= 20)
            let stats = await provider.fetchGrimmoryStats()
            #expect(stats.streak != nil)
            #expect(stats.distributions != nil)
            let book = try await fixture.book(search: "Enve Namespace Prefix Regression")
            _ = try await provider.fetchRecommendations(bookId: book.id)
            let libraries = try await provider.fetchLibraries()
            var smallest: (Library, Int)?
            for library in libraries {
                let count = try await provider.remoteBookCount(libraryId: library.id)
                if count > 0 && count < (smallest?.1 ?? .max) { smallest = (library, count) }
            }
            let library = try #require(smallest).0
            provider.useLegacyRestAPI = true
            #expect(!provider.supportsTransactionalCatalogImport)
            #expect(try await provider.fetchLibraries().contains { $0.id == library.id })
            #expect(!(try await provider.fetchBooksViaLegacyAPI(libraryId: library.id)).books.isEmpty)
            provider.useLegacyRestAPI = false
            provider.useKomgaFallback = true
            #expect(try await provider.fetchLibraries().contains { $0.id == library.id })
            #expect(!(try await provider.fetchBooks(libraryId: library.id)).isEmpty)
            fixture.record("user/admin reads, reading sessions, statistics, recommendations, legacy catalog, and Komga compatibility/demotion")
        }
    }

    private final class Fixture {
        let root: URL
        let defaultsDomain: String
        let session: ProfileSession
        let provider: BookloreProvider
        var cleanup: [() async throws -> Void] = []

        init() async throws {
            let document = try #require(ProcessInfo.processInfo.environment["ENVE_LAB_DOCUMENT"])
            let text = try String(contentsOfFile: document, encoding: .utf8)
            var rows: [String: String] = [:]
            var endpoint: String?
            for line in text.split(separator: "\n") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.count >= 4 else { continue }
                rows[cells[1]] = cells[2]
                if cells[1] == "Grimmory" {
                    let quoted = cells[2].split(separator: "`", omittingEmptySubsequences: false).enumerated()
                        .filter { $0.offset % 2 == 1 }.map { String($0.element) }
                    if let url = quoted.first(where: { $0.hasPrefix("http") }) { endpoint = url }
                }
            }
            func values(_ key: String) -> [String] {
                (rows[key] ?? "").split(separator: "`", omittingEmptySubsequences: false).enumerated()
                    .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            }
            let configured = try #require(endpoint)
            let hosts = values("LAN address") + values("Tailscale address")
            var components = try #require(URLComponents(string: configured))
            guard let host = components.host, hosts.contains(host) else { throw Failure.nonLabEndpoint }
            var reachable: String?
            for candidate in [host] + hosts {
                components.host = candidate
                guard let url = components.url else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                if let (_, response) = try? await URLSession.shared.data(for: request), response is HTTPURLResponse {
                    reachable = url.absoluteString
                    break
                }
            }
            guard let reachable else { throw Failure.unreachable }
            let username = try #require(values("Username").first)
            let password = try #require(values("Password").first)
            let profile = FamilyProfile(id: UUID().uuidString, name: "Refactor test", role: .adult)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BookloreRefactor-\(profile.id)")
            defaultsDomain = "BookloreRefactor.\(profile.id)"
            let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
            provider = BookloreProvider(connection: ServerConnection(name: "Refactor lab", url: reachable,
                type: .booklore, username: username, password: password), profileSession: session)
        }

        static func run(_ body: (Fixture) async throws -> Void) async throws {
            let fixture = try await Fixture()
            do {
                #expect(try await fixture.provider.validateConnection())
                try await body(fixture)
            } catch {
                await fixture.remove()
                throw error
            }
            await fixture.remove()
        }

        func book(search: String) async throws -> Book {
            let request = try provider.makeRequest(path: "/api/v1/app/books", queryItems: [
                URLQueryItem(name: "search", value: search), URLQueryItem(name: "size", value: "100"),
            ])
            let (data, response) = try await provider.performAuthorizedRequest(request)
            #expect(response.statusCode == 200)
            let page = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
            let summary = try #require(page.content.first)
            return try await provider.fetchFullBookDetails(bookId: summary.id.stringValue,
                libraryId: summary.libraryId?.stringValue ?? "")
        }

        func request(path: String, method: String = "GET", json: Any? = nil) async throws -> Data {
            let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
            let request = try provider.makeRequest(path: path, method: method, body: body,
                contentType: json == nil ? nil : "application/json")
            let (data, response) = try await provider.performAuthorizedRequest(request)
            guard (200...204).contains(response.statusCode) else { throw Failure.httpStatus(response.statusCode) }
            return data
        }

        func record(_ stage: String) { print("LAB Booklore refactor checked: \(stage)") }

        func remove() async {
            for action in cleanup.reversed() {
                do { try await action() }
                catch { Issue.record("Failed to restore a disposable Booklore lab fixture") }
            }
            cleanup.removeAll()
            provider.keychain.delete(provider.refreshTokenKeychainKey)
            await provider.retire()
            await session.retire()
            UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum Failure: Error {
        case nonLabEndpoint, unreachable
        case httpStatus(Int)
    }
}
