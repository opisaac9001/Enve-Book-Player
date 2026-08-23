#if DEBUG
import Foundation

@MainActor
final class SyntheticLibrarySeeder {
    static let shared = SyntheticLibrarySeeder()
    private init() {}

    static let providerId = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!
    static let libraryId = "synthetic-library"

    struct Progress: Sendable {
        var written: Int
        var total: Int
    }

    enum Scenario: String, CaseIterable, Identifiable {
        case mixed
        case duplicateTitles
        case movedFiles
        case reimport

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .mixed: return "Mixed audiobook/ebook"
            case .duplicateTitles: return "Duplicate titles (collision)"
            case .movedFiles: return "Moved files (path churn)"
            case .reimport: return "Reimport (new provider id)"
            }
        }
    }

    private let authorPool = 2_000
    private let seriesPool = 5_000
    private let narratorPool = 1_000
    private let genrePool = [
        "Fantasy", "Sci-Fi", "Mystery", "Romance", "History",
        "Biography", "Thriller", "Horror", "Self-Help", "Science",
    ]
    private let batchSize = 1_000

    func seed(
        count: Int,
        scenario: Scenario = .mixed,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async {
        let store = AppState.shared.bookStore
        await store.replaceLibrary(
            books: [],
            libraryId: Self.libraryId,
            providerId: Self.providerId,
            allowSparseResult: true
        )
        let reconciliation = await store.beginReconciliation(
            libraryId: Self.libraryId,
            providerId: Self.providerId
        )

        var written = 0
        var batch: [Book] = []
        batch.reserveCapacity(batchSize)

        for index in 0..<count {
            batch.append(makeBook(index: index, scenario: scenario))
            if batch.count == batchSize {
                try? await store.upsertReconciledPage(
                    books: batch,
                    generation: reconciliation.generation,
                    notifyChange: false
                )
                written += batch.count
                batch.removeAll(keepingCapacity: true)
                onProgress(Progress(written: written, total: count))
            }
        }
        if !batch.isEmpty {
            try? await store.upsertReconciledPage(
                books: batch,
                generation: reconciliation.generation,
                notifyChange: false
            )
            written += batch.count
            onProgress(Progress(written: written, total: count))
        }
        _ = try? await store.endReconciliation(
            libraryId: Self.libraryId,
            providerId: Self.providerId,
            generation: reconciliation.generation,
            existingCountBefore: reconciliation.existingCount
        )
    }

    func teardown() async {
        let store = AppState.shared.bookStore
        await store.replaceLibrary(
            books: [],
            libraryId: Self.libraryId,
            providerId: Self.providerId,
            allowSparseResult: true
        )
    }

    func currentBookCount() async -> Int {
        await AppState.shared.bookStore.bookCount()
    }

    private func makeBook(index: Int, scenario: Scenario) -> Book {
        let isEbook = index % 5 == 0
        let authorIndex = index % authorPool
        let seriesIndex = index % seriesPool
        let narratorIndex = index % narratorPool
        let genre = genrePool[index % genrePool.count]

        let hasProgress = index % 10 < 3
        let isFinished = hasProgress && index % 30 == 0

        let baseId: String
        let provider: UUID
        let source: Book.BookSource = isEbook ? .booklore : .audiobookshelf
        let filePathSuffix: String

        switch scenario {
        case .mixed:
            baseId = "syn-\(index)"
            provider = Self.providerId
            filePathSuffix = "syn-\(index).\(isEbook ? "epub" : "m4b")"
        case .duplicateTitles:

            baseId = "syn-dup-\(index)"
            provider = (index % 2 == 0) ? Self.providerId : Self.altProviderId
            filePathSuffix = "syn-dup-\(index).\(isEbook ? "epub" : "m4b")"
        case .movedFiles:

            baseId = "syn-moved-\(index)"
            provider = Self.providerId
            filePathSuffix = "moved/\(index % 7)/syn-moved-\(index).\(isEbook ? "epub" : "m4b")"
        case .reimport:

            baseId = "syn-reimport-\(index)"
            provider = Self.altProviderId
            filePathSuffix = "syn-reimport-\(index).\(isEbook ? "epub" : "m4b")"
        }

        let title: String = {
            switch scenario {
            case .duplicateTitles: return "Collision Title \(index / 2)"
            default: return "Synthetic Book \(index)"
            }
        }()

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filePath = documents.appendingPathComponent(filePathSuffix).path

        var book = Book(
            id: baseId,
            title: title,
            author: "Author \(authorIndex)",
            authors: ["Author \(authorIndex)"],
            narrator: isEbook ? nil : "Narrator \(narratorIndex)",
            thumb: nil,
            duration: isEbook ? nil : Double(3600 + (index % 20) * 600),
            source: source,
            filePath: filePath,
            mediaType: isEbook ? .ebook : .audiobook,
            ebookProgress: isEbook && hasProgress ? Double(index % 100) / 100.0 : nil,
            series: "Series \(seriesIndex)",
            seriesNumber: (index % 9) + 1,
            publishedYear: 1990 + (index % 35),
            genres: [genre],
            isbn: (scenario == .reimport) ? "isbn-syn-\(index)" : nil,
            asin: (scenario == .movedFiles) ? "asin-syn-\(index)" : nil,
            addedAt: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 60),
            libraryName: "Synthetic Library",
            currentTime: (!isEbook && hasProgress) ? Double((index % 100) * 30) : 0,
            isFinished: isFinished,
            lastUpdate: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 60),
            providerId: provider,
            libraryId: Self.libraryId
        )
        if isEbook {
            book.ebookFileURL = URL(fileURLWithPath: filePath)
        }
        return book
    }

    private static let altProviderId = UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!
}
#endif
