import Foundation
import Testing

@testable import enve

@MainActor
struct BookOrbitFeatureLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_UI_ACTION"] != nil))
    func configureUIProfile() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_FEATURE_CONFIG"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let coordinator = ProfileSwitchCoordinator.shared
        let stateURL = URL(fileURLWithPath: path + ".ui-state.json")
        if ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_UI_ACTION"] == "verify" {
            let state = try JSONDecoder().decode(UIProfileState.self, from: Data(contentsOf: stateURL))
            #expect(coordinator.activeProfile.id == state.labID)
            let connection = try #require(coordinator.activeSession.providerConnections.connections.first)
            #expect(BookOrbitAccess.connections.map(\.id) == [connection.id])
            let provider = try #require(BookOrbitAccess.provider(connection.id))
            #expect(try await provider.fetchSmartScopes().count >= 2)
            return
        }
        if ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_UI_ACTION"] == "cleanup" {
            let state = try JSONDecoder().decode(UIProfileState.self, from: Data(contentsOf: stateURL))
            try await coordinator.switchProfile(id: state.originalID)
            try await coordinator.removeProfile(id: state.labID)
            if !state.originallyEnabled { try coordinator.disable() }
            try FileManager.default.removeItem(at: stateURL)
            return
        }
        let originalID = coordinator.activeProfile.id
        let originallyEnabled = coordinator.isEnabled
        if !originallyEnabled { try coordinator.enable(ownerName: coordinator.activeProfile.name) }
        let lab = try coordinator.addProfile(name: "BookOrbit UI Lab", role: .adult, serverSyncEnabled: true)
        try JSONEncoder().encode(UIProfileState(originalID: originalID, originallyEnabled: originallyEnabled, labID: lab.id))
            .write(to: stateURL, options: .atomic)
        try await coordinator.switchProfile(id: lab.id)
        let profile = coordinator.activeSession
        let provider = BookOrbitProvider(connection: ServerConnection(name: "BookOrbit Feature Lab", url: config.base_url,
            type: .bookOrbit, username: config.username, password: config.password), profileSession: profile)
        guard try await provider.validateConnection() else { throw Failure.rejected }
        profile.providerConnections.connections = [provider.connection]
        var books: [Book] = []
        for id in config.books {
            books.append(try await provider.fetchFullBookDetails(bookId: String(id), libraryId: String(config.library_id)))
        }
        await profile.libraryDatabase.repository.upsertBooks(books)
    }

    private struct UIProfileState: Codable {
        let originalID: String
        let originallyEnabled: Bool
        let labID: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_FEATURE_CONFIG"] != nil
        && ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_UI_ACTION"] == nil))
    func nativeFeatureRoundTrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_FEATURE_CONFIG"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = try ProfileSession(profile: FamilyProfile(id: config.ios_profile_id, name: "BookOrbit Feature Lab", role: .adult))
        let connection = ServerConnection(name: "BookOrbit Feature Lab", url: config.base_url, type: .bookOrbit,
                                          username: config.username, password: config.password)
        let provider = BookOrbitProvider(connection: connection, profileSession: profile)
        var stage = "authentication"
        var stagedIDs: [Int] = []
        do {
            guard try await provider.validateConnection() else { throw Failure.rejected }
            profile.providerConnections.connections = [provider.connection]
            #expect(try await provider.currentUserIsAdmin() == false)
            let libraries = try await provider.fetchLibraries()
            #expect(libraries.map(\.id) == [String(config.library_id)])
            let book = try await provider.fetchFullBookDetails(bookId: String(config.books[0]), libraryId: String(config.library_id))
            await profile.libraryDatabase.repository.upsertBooks([book])

            stage = "offline edits and persisted replay"
            let transport = LabTransport(provider: provider, book: book)
            let queue = PendingBookEditQueue(store: profile.pendingBookEdits, transport: transport,
                                             connection: { id in id == provider.connection.id ? provider.connection : nil })
            let obsolete = try #require(queue.submit(.rating(2), for: book))
            _ = try #require(queue.submit(.rating(4), for: book))
            _ = try #require(queue.submit(.readStatus("on_hold"), for: book))
            #expect(!profile.pendingBookEdits.acknowledge(obsolete))
            await queue.flush()
            #expect(profile.pendingBookEdits.entries.count == 2)
            #expect(queue.pendingRating(for: book) == 4)
            let overlaid = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
            #expect(overlaid.personalRating == 4)
            let restored = PendingBookEditStore(defaults: profile.defaults)
            #expect(restored.entries.count == 2)
            let replay = PendingBookEditQueue(store: restored, transport: transport,
                                              connection: { id in id == provider.connection.id ? provider.connection : nil })
            for edit in restored.entries.values { restored.retryNow(edit) }
            transport.offline = false
            await replay.flush()
            #expect(restored.isEmpty)
            for edit in profile.pendingBookEdits.entries.values { profile.pendingBookEdits.acknowledge(edit) }
            let remote = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
            #expect(remote.personalRating == 4)
            #expect(await provider.fetchReadStatus(for: book) == .onHold)
            print("BOOKORBIT LIVE Apple durable rating/status replay passed")

            stage = "saved scopes and paging"
            let scopes = try await provider.fetchSmartScopes()
            #expect(Set(config.scope_ids).isSubset(of: Set(scopes.map(\.id))))
            let first = try await provider.fetchSmartScopeBooks(scopeId: config.scope_ids[0], query: .init(page: 0, size: 1))
            let second = try await provider.fetchSmartScopeBooks(scopeId: config.scope_ids[0], query: .init(page: 1, size: 1))
            #expect(first.total >= 3)
            #expect(first.books.count == 1 && second.books.count == 1)
            #expect(first.books.first?.id != second.books.first?.id)
            let searched = try await provider.fetchSmartScopeBooks(scopeId: config.scope_ids[0], query: .init(search: "Enve Feature Lab Apple"))
            #expect(searched.books.contains { $0.id == String(config.books[0]) })
            let empty = try await provider.fetchSmartScopeBooks(scopeId: config.scope_ids[1], query: .init())
            #expect(empty.total == 0 && empty.books.isEmpty)
            print("BOOKORBIT LIVE Apple saved scope paging, search and empty state passed")

            stage = "highlights with notes"
            let all = try await provider.fetchAnnotations(.init(bookId: config.books[0]))
            let notes = try await provider.fetchAnnotations(.init(pageSize: 1, bookId: config.books[0], hasNote: true))
            let nextNotes = try await provider.fetchAnnotations(.init(page: 2, pageSize: 1, bookId: config.books[0], hasNote: true))
            #expect(all.total == 3 && notes.total == 2)
            #expect(notes.items.count == 1 && nextNotes.items.count == 1)
            #expect(notes.items.first?.id != nextNotes.items.first?.id)
            #expect(notes.items.allSatisfy { !($0.note ?? "").isEmpty })
            print("BOOKORBIT LIVE Apple notes-only filtering and paging passed")

            stage = "Book Drop permissions and destinations"
            let access = try await provider.fetchBookDockAccess()
            #expect(access.canUse && access.canFinalize && !access.managesAll)
            let destinations = try await provider.fetchBookDockDestinations()
            #expect(destinations.count == 1)
            #expect(destinations.first?.folders.contains { $0.id == config.folder_id } == true)
            let inbox = try await provider.fetchBookDockFiles(.init(limit: 1))
            #expect(inbox.total >= 4 && inbox.items.count == 1)
            let nextInbox = try await provider.fetchBookDockFiles(.init(page: 2, limit: 1))
            #expect(nextInbox.items.count == 1 && inbox.items.first?.id != nextInbox.items.first?.id)

            stage = "Book Drop upload and metadata"
            let approved = try await provider.uploadBookDockFile(at: URL(fileURLWithPath: config.upload_epub), filename: "Enve-Apple-Native.epub")
            stagedIDs.append(approved.id)
            let rejected = try await provider.uploadBookDockFile(at: URL(fileURLWithPath: config.reject_epub), filename: "Enve-Apple-No-Target.epub")
            stagedIDs.append(rejected.id)
            for id in stagedIDs {
                for _ in 0..<30 {
                    if try await provider.fetchBookDockFile(id: id).status == "ready" { break }
                    try await Task.sleep(for: .seconds(1))
                }
                #expect(try await provider.fetchBookDockFile(id: id).status == "ready")
            }
            let applied = try await provider.applyFetchedBookDockMetadata(ids: [approved.id])
            #expect(applied.total == 1)
            let approvalTitle = "Enve Apple Native Approval \(UUID().uuidString.prefix(8))"
            let stagedFile = try await provider.fetchBookDockFile(id: approved.id)
            var editedMetadata = stagedFile.metadata
            editedMetadata.title = approvalTitle
            let model = BookOrbitBookDropModel(source: provider)
            let edited = try #require(await model.save(stagedFile, metadata: editedMetadata,
                target: (config.library_id, config.folder_id)))
            #expect(edited.metadata.title == approvalTitle)
            #expect(edited.targetFolderId == config.folder_id)

            stage = "Book Drop partial approval and discard"
            let result = try await provider.finalizeBookDockFiles(ids: [approved.id, rejected.id])
            #expect(result.total == 2 && result.succeeded == 1 && result.failed == 1)
            #expect(result.results.first { $0.fileId == approved.id }?.success == true)
            #expect(result.results.first { $0.fileId == rejected.id }?.success == false)
            stagedIDs.removeAll { $0 == approved.id }
            let filedID = try #require(result.results.first { $0.fileId == approved.id }?.bookId)
            let filed = try await provider.fetchFullBookDetails(bookId: String(filedID), libraryId: String(config.library_id))
            #expect(filed.title == approvalTitle)
            #expect(filed.author == "Enve Test Lab")
            try await provider.discardBookDockFiles(ids: stagedIDs)
            stagedIDs.removeAll()
            let remaining = try await provider.fetchBookDockFiles(.init())
            #expect(!remaining.items.contains { $0.id == rejected.id })
            print("BOOKORBIT LIVE Apple upload, edit, partial approval and discard passed")
            await profile.retire()
        } catch {
            try? await provider.discardBookDockFiles(ids: stagedIDs)
            await profile.retire()
            throw Failure.stage(stage)
        }
    }

    private struct Configuration: Decodable {
        let base_url: String
        let username: String
        let password: String
        let library_id: Int
        let folder_id: Int
        let books: [Int]
        let scope_ids: [Int]
        let ios_profile_id: String
        let upload_epub: String
        let reject_epub: String
    }

    private enum Failure: Error { case rejected, stage(String) }

    private final class LabTransport: PendingBookEditTransporting {
        let provider: BookOrbitProvider
        let book: Book
        var offline = true

        init(provider: BookOrbitProvider, book: Book) {
            self.provider = provider
            self.book = book
        }

        func send(_ edit: PendingBookEdit, isCurrent: @escaping @MainActor () -> Bool) async throws -> PendingBookEditDisposition {
            if offline { throw URLError(.notConnectedToInternet) }
            guard isCurrent() else { return .unavailable }
            switch edit.value {
            case .rating(let value): try await provider.updatePersonalRating(for: book, rating: value)
            case .readStatus(let value): try await provider.updateReadStatus(for: book, rawStatus: value)
            }
            return .delivered
        }
    }
}
