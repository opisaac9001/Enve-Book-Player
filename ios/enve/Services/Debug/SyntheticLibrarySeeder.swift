#if DEBUG && os(iOS)
import Foundation
import Logging
import ReadiumZIPFoundation
import SwiftUI
import UIKit

@MainActor
final class SyntheticLibrarySeeder {
    static let shared = SyntheticLibrarySeeder()
    private init() {}

    static let providerId = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!
    static let libraryId = "synthetic-library"
    private static let comicProviderId = UUID(uuidString: "5EED0000-0000-4000-8000-000000000003")!
    static var providerIds: Set<UUID> { [providerId, comicProviderId, altProviderId] }

    struct Progress: Sendable {
        var written: Int
        var total: Int
    }

    enum Scenario: String, CaseIterable, Identifiable {
        case mixed
        case comics
        case duplicateTitles
        case movedFiles
        case reimport

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .mixed: return "Mixed audiobook/ebook"
            case .comics: return "Comic series, volumes and specials"
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
    private var comicFixture: URL?

    func seed(
        count: Int,
        scenario: Scenario = .mixed,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async {
        if scenario == .comics {
            do { comicFixture = try await makeComicFixture() }
            catch { AppLogger.general.error("Comic fixture generation failed"); return }
        }
        let store = AppState.shared.bookStore
        let providerId = scenario == .comics ? Self.comicProviderId : Self.providerId
        if scenario == .comics {
            await store.replaceLibrary(books: [], libraryId: Self.libraryId, providerId: Self.providerId, allowSparseResult: true)
        }
        await store.replaceLibrary(
            books: [],
            libraryId: Self.libraryId,
            providerId: providerId,
            allowSparseResult: true
        )
        guard let reconciliation = try? await store.beginReconciliation(
            libraryId: Self.libraryId,
            providerId: providerId
        ) else { return }

        var written = 0
        var batch: [Book] = []
        batch.reserveCapacity(batchSize)

        do {
            for index in 0..<count {
                batch.append(makeBook(index: index, scenario: scenario))
                if batch.count == batchSize {
                    try await store.upsertReconciledPage(
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
                try await store.upsertReconciledPage(
                    books: batch,
                    generation: reconciliation.generation,
                    notifyChange: false
                )
                written += batch.count
                onProgress(Progress(written: written, total: count))
            }
            _ = try await store.endReconciliation(
                libraryId: Self.libraryId,
                providerId: providerId,
                generation: reconciliation.generation,
                existingCountBefore: reconciliation.existingCount
            )
        } catch {
            AppLogger.general.error("Synthetic catalog write failed")
        }
    }

    func teardown() async {
        let store = AppState.shared.bookStore
        for providerId in [Self.providerId, Self.comicProviderId] {
            await store.replaceLibrary(books: [], libraryId: Self.libraryId, providerId: providerId, allowSparseResult: true)
        }
    }

    func currentBookCount() async -> Int {
        await AppState.shared.bookStore.bookCount()
    }

    private func makeBook(index: Int, scenario: Scenario) -> Book {
        if scenario == .comics { return makeComic(index: index) }
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
        case .mixed, .comics:
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

    private func makeComic(index: Int) -> Book {
        let issue = index % 700
        let run = index / 700
        let section: ComicSection = issue < 600 ? .volumes : (issue < 699 ? .issues : .specials)
        let label = section == .specials ? "Special 700" : "Issue \(issue + 1)"
        let volume = section == .volumes ? issue / 100 + 1 : nil
        let file = comicFixture!
        var book = Book(
            id: "syn-comic-\(index)", title: "Comic Fixture \(run) · \(label)", author: "Comic fixture",
            source: .komga, backendId: Self.comicProviderId.uuidString, filePath: file.path,
            mediaType: .ebook, ebookFormat: "cbz", ebookFileURL: file,
            series: "Comic Fixture \(run)", seriesNumber: issue + 1,
            providerId: Self.comicProviderId, libraryId: Self.libraryId
        )
        book.comicMetadata = ComicMetadata(
            seriesID: "synthetic-run-\(run)", section: section, volumeID: volume.map { "volume-\($0)" },
            volumeTitle: volume.map { "Volume \($0)" }, volumeOrder: volume.map(Double.init),
            issueLabel: label, issueOrder: Double(issue + 1), pageCount: 3
        )
        return book
    }

    private func makeComicFixture() async throws -> URL {
        let directory = ProfileSession.owner.ebooks.localEbooksRoot
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Enve-Comic-UX-Fixture.cbz")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let archive = try await Archive(url: file, accessMode: .create)
        let palette = Hearth.palette(for: .light)
        for index in 1...3 {
            let size = index == 3 ? CGSize(width: 1400, height: 900) : CGSize(width: 900, height: 1400)
            let data = UIGraphicsImageRenderer(size: size).pngData { context in
                UIColor(palette.bg).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let label = "Comic reader fixture\nPage \(index) of 3"
                label.draw(in: CGRect(x: 60, y: 120, width: size.width - 120, height: 300), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: UIColor(palette.text),
                ])
            }
            try await archive.addEntry(with: "page-\(index).png", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                data.subdata(in: Int(position)..<min(Int(position) + count, data.count))
            }
        }
        return file
    }

    private static let altProviderId = UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!
}
#endif
