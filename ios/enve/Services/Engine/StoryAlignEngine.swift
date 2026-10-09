import Foundation

@available(iOS 26.0, *)
struct StoryAlignPickerPage {
    let books: [Book]
    let canLoadMore: Bool
}

@available(iOS 26.0, *)
@MainActor
@Observable
final class StoryAlignEngine {
    private unowned let profileSession: ProfileSession?
    private let appState: AppState
    private let catalog: LibraryCatalogCoordinator
    private let suppliedService: StoryAlignService?
    let isAvailable: Bool
    private var service: StoryAlignService { suppliedService ?? .shared }

    init(
        appState: AppState = .shared,
        catalog: LibraryCatalogCoordinator = .shared,
        service: StoryAlignService? = nil,
        isAvailable: Bool = true,
        profileSession: ProfileSession? = nil
    ) {
        self.profileSession = profileSession
        self.appState = appState
        self.catalog = catalog
        self.suppliedService = service
        self.isAvailable = isAvailable
    }

    var activeConversion: StoryAlignService.ConversionState? {
        guard isAvailable else { return nil }
        return service.activeConversion
    }

    var pausedConversion: StoryAlignService.PausedConversion? {
        guard isAvailable else { return nil }
        return service.pausedConversion
    }

    func canStart(ebook: Book?, audiobook: Book?) -> Bool {
        isAvailable && ebook != nil && audiobook != nil && service.activeConversion == nil
    }

    func isConverted(ebook: Book, audiobook: Book) -> Bool {
        isAvailable && service.isConverted(ebook: ebook, audiobook: audiobook)
    }

    func needsDownload(ebook: Book, audiobook: Book) -> (ebook: Bool, audiobook: Bool) {
        guard isAvailable else { return (false, false) }
        return service.needsDownload(ebook: ebook, audiobook: audiobook)
    }

    func startConversion(ebook: Book, audiobook: Book) throws {
        guard isAvailable else { throw ProfileAccessError.parentAuthorizationRequired }
        service.downloadAndConvert(ebook: ebook, audiobook: audiobook)
    }

    func resumeConversion(ebook: Book, audiobook: Book) throws {
        guard isAvailable else { throw ProfileAccessError.parentAuthorizationRequired }
        service.resumeConversion(ebook: ebook, audiobook: audiobook)
    }

    func cancelConversion() throws {
        guard isAvailable else { throw ProfileAccessError.parentAuthorizationRequired }
        service.cancelConversion()
    }

    func dismissConversion() throws {
        guard isAvailable else { throw ProfileAccessError.parentAuthorizationRequired }
        service.dismissConversion()
    }

    func deleteConversion(ebook: Book, audiobook: Book) throws {
        guard isAvailable else { throw ProfileAccessError.parentAuthorizationRequired }
        service.deleteConversion(ebook: ebook, audiobook: audiobook)
    }

    func books(for paused: StoryAlignService.PausedConversion) -> (ebook: Book?, audiobook: Book?) {
        guard isAvailable else { return (nil, nil) }
        return (
            ebook: appState.bookInMemory(stableId: paused.ebookStableId),
            audiobook: appState.bookInMemory(stableId: paused.audiobookStableId)
        )
    }

    func completedConversions() -> AsyncStream<[StoryAlignService.CompletedConversion]> {
        guard isAvailable else { return AsyncStream { $0.finish() } }
        let store = appState.bookStore
        let service = service
        return store.observe { await service.completedConversions() }
    }

    func pickerPage(mediaType: String, query: String, after cursor: Book? = nil, limit: Int = 100) async -> StoryAlignPickerPage {
        guard isAvailable else { return StoryAlignPickerPage(books: [], canLoadMore: false) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let page = await appState.bookStore.pagedBooks(after: cursor, limit: limit, mediaType: mediaType)
            return StoryAlignPickerPage(books: page, canLoadMore: page.count == limit)
        } else {
            let results = await appState.bookStore.searchBooks(query: trimmed, mediaType: mediaType, limit: 300)
            return StoryAlignPickerPage(books: results, canLoadMore: false)
        }
    }

    func importFilesForPicker(urls: [URL], mediaType: String) async throws -> Book? {
        guard isAvailable else { throw ProfileAccessError.parentAuthorizationRequired }
        let knownUniqueIds = await appState.bookStore.allBookUniqueIds()
        let imported = try await (profileSession?.remoteImport ?? RemoteImportService.shared).importFromFilesApp(urls: urls)

        let library = LocalLibrary(
            id: LocalLibraryService.fileSharingLibraryId,
            name: "Drag & Drop Books",
            folderPath: (profileSession?.storage.documentsDirectory ?? LocalLibraryService.fileSharingRootURL).path,
            createdAt: Date(),
            isEnabled: true,
            type: .fileSharing
        )
        (profileSession?.localLibrary ?? LocalLibraryStorageStore.shared).saveLibrary(library)
        let scanResult = try await (profileSession?.localLibraryService ?? LocalLibraryService.shared).scanLibrary(library)
        (profileSession?.localLibrary ?? LocalLibraryStorageStore.shared).saveScanResult(scanResult)

        for bookFile in imported {
            guard let coverPath = bookFile.metadata?.coverImagePath,
                FileManager.default.fileExists(atPath: coverPath),
                let data = try? Data(contentsOf: URL(fileURLWithPath: coverPath))
            else {
                continue
            }
            let book = bookFile.toBook(libraryId: LocalLibraryService.fileSharingLibraryId)
            await (profileSession?.appCache ?? AppCache.shared).setCoverData(data, for: book)
        }

        catalog.forceNextLocalRefresh = true
        NotificationCenter.default.post(name: .localLibraryUpdated, object: LocalLibraryService.fileSharingLibraryId)

        try? await Task.sleep(for: .milliseconds(1500))
        let after = await appState.bookStore.pagedBooks(after: nil, limit: 200, mediaType: mediaType)
        return after.first { !knownUniqueIds.contains($0.uniqueId) }
    }
}
