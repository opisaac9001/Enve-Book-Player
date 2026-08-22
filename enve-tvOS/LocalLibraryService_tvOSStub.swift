import Foundation

actor LocalLibraryService {
    static let shared = LocalLibraryService()

    init() {}

    nonisolated static let fileSharingLibraryId = "file-sharing"

    nonisolated static var fileSharingRootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    enum LocalLibraryError: LocalizedError {
        case notSupportedOnTVOS
        var errorDescription: String? {
            "Local library scanning isn't available on Apple TV."
        }
    }

    func removeBookFromScanCache(bookId: String, libraryId: String, filePath: String? = nil) async {}

    func deleteBookFiles(for book: Book) throws {}

    func scanLibrary(_ library: LocalLibrary) async throws -> LocalLibraryScanResult {
        LocalLibraryScanResult(
            localLibraryId: library.id,
            booksFound: [],
            skippedFiles: [],
            scanDuration: 0,
            scannedAt: Date()
        )
    }

    func updateBookMetadata(
        bookFile: LocalBookFile,
        metadata: LocalBookMetadata,
        embedIntoFile: Bool = false,
        libraryId: String? = nil
    ) async throws -> LocalBookFile {
        throw LocalLibraryError.notSupportedOnTVOS
    }
}
