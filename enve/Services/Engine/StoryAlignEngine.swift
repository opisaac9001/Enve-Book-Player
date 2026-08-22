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
    static let shared = StoryAlignEngine()

    private let appState: AppState
    private let catalog: LibraryCatalogCoordinator
    private let service: StoryAlignService

    init(
        appState: AppState = .shared,
        catalog: LibraryCatalogCoordinator = .shared,
        service: StoryAlignService = .shared
    ) {
        self.appState = appState
        self.catalog = catalog
        self.service = service
    }

    var activeConversion: StoryAlignService.ConversionState? {
        service.activeConversion
    }

    var pausedConversion: StoryAlignService.PausedConversion? {
        service.pausedConversion
    }

    func canStart(ebook: Book?, audiobook: Book?) -> Bool {
        ebook != nil && audiobook != nil && service.activeConversion == nil
    }

    func isConverted(ebook: Book, audiobook: Book) -> Bool {
        service.isConverted(ebook: ebook, audiobook: audiobook)
    }

    func needsDownload(ebook: Book, audiobook: Book) -> (ebook: Bool, audiobook: Bool) {
        service.needsDownload(ebook: ebook, audiobook: audiobook)
    }

    func startConversion(ebook: Book, audiobook: Book) {
        service.downloadAndConvert(ebook: ebook, audiobook: audiobook)
    }

    func resumeConversion(ebook: Book, audiobook: Book) {
        service.resumeConversion(ebook: ebook, audiobook: audiobook)
    }

    func cancelConversion() {
        service.cancelConversion()
    }

    func dismissConversion() {
        service.dismissConversion()
    }

    func deleteConversion(ebook: Book, audiobook: Book) {
        service.deleteConversion(ebook: ebook, audiobook: audiobook)
    }

    func books(for paused: StoryAlignService.PausedConversion) -> (ebook: Book?, audiobook: Book?) {
        (
            ebook: appState.bookInMemory(stableId: paused.ebookStableId),
            audiobook: appState.bookInMemory(stableId: paused.audiobookStableId)
        )
    }

    func completedConversions() -> AsyncStream<[StoryAlignService.CompletedConversion]> {
        let store = appState.bookStore
        let service = service
        return store.observe { await service.completedConversions() }
    }

    func pickerPage(mediaType: String, query: String, after cursor: Book? = nil, limit: Int = 100) async -> StoryAlignPickerPage {
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
        let knownUniqueIds = await appState.bookStore.allBookUniqueIds()
        let imported = try await RemoteImportService.shared.importFromFilesApp(urls: urls)

        let library = LocalLibrary(
            id: LocalLibraryService.fileSharingLibraryId,
            name: "Drag & Drop Books",
            folderPath: LocalLibraryService.fileSharingRootURL.path,
            createdAt: Date(),
            isEnabled: true,
            type: .fileSharing
        )
        LocalLibraryStorageStore.shared.saveLibrary(library)
        let scanResult = try await LocalLibraryService.shared.scanLibrary(library)
        LocalLibraryStorageStore.shared.saveScanResult(scanResult)

        for bookFile in imported {
            guard let coverPath = bookFile.metadata?.coverImagePath,
                FileManager.default.fileExists(atPath: coverPath),
                let data = try? Data(contentsOf: URL(fileURLWithPath: coverPath))
            else {
                continue
            }
            let book = bookFile.toBook(libraryId: LocalLibraryService.fileSharingLibraryId)
            await AppCache.shared.setCoverData(data, for: book)
        }

        catalog.forceNextLocalRefresh = true
        NotificationCenter.default.post(name: .localLibraryUpdated, object: LocalLibraryService.fileSharingLibraryId)

        try? await Task.sleep(for: .milliseconds(1500))
        let after = await appState.bookStore.pagedBooks(after: nil, limit: 200, mediaType: mediaType)
        return after.first { !knownUniqueIds.contains($0.uniqueId) }
    }
}
