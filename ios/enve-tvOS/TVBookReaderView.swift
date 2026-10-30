import CoreGraphics
import ReadiumZIPFoundation
import SwiftUI

struct TVBookReaderView: View {
    @Environment(\.hearth) private var hearth
    let book: Book
    var textOnly = false

    @Environment(\.dismiss) private var dismiss
    @State private var publication: TVPublication?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let publication {
                switch publication {
                case .epub(let prepared, let narrated):
                    if narrated && !textOnly {
                        StorytellerReaderView_tvOS(book: prepared)
                    } else {
                        EbookReaderView_tvOS(book: prepared)
                    }
                case .pages(let document):
                    TVPagedDocumentView(book: book, document: document)
                }
            } else {
                ZStack {
                    hearth.bgSunken.ignoresSafeArea()
                    VStack(spacing: 28) {
                        if let error {
                            Label("Couldn't open this book", systemImage: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(hearth.text)
                            Text(error).foregroundStyle(hearth.textSecondary).font(.title3).multilineTextAlignment(.center)
                            Button("Retry") { attempt += 1 }
                        } else {
                            ProgressView()
                            Text("Preparing book…").font(.title3).foregroundStyle(hearth.textSecondary)
                        }
                        Button("Done") { dismiss() }
                    }
                    .frame(maxWidth: 1000)
                }
            }
        }
        .task(id: attempt) {
            guard publication == nil else { return }
            error = nil
            do {
                let loaded = try await TVPublication.prepare(book: book)
                try Task.checkCancellation()
                publication = loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

enum TVPublication {
    case epub(Book, narrated: Bool)
    case pages(TVPagedDocument)

    static func prepare(book: Book) async throws -> TVPublication {
        let url = try await UnifiedDownloadService.shared.prepareReaderAsset(for: book)
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 8) ?? Data()
        try handle.close()

        if header.starts(with: Data("%PDF-".utf8)) {
            guard let pdf = CGPDFDocument(url as CFURL), !pdf.isEncrypted || pdf.isUnlocked, pdf.numberOfPages > 0 else {
                throw TVPublicationError("The PDF is damaged or password protected. Unlock it before adding it to your library.")
            }
            return .pages(.pdf(url, pageCount: pdf.numberOfPages))
        }
        if header.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) {
            return try await comic(url: url, book: book)
        }
        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw TVPublicationError("This file is not a supported EPUB, PDF, CBZ or CBR book.")
        }
        let entries = try await archive.entries()
        guard let container = entries.first(where: { $0.path == "META-INF/container.xml" }) else {
            return try await comic(url: url, book: book)
        }
        let containerData = try await data(for: container, in: archive)
        let package = TVStorytellerPackageParser()
        guard package.parse(containerData), let rootfile = package.rootfile,
            let opf = entries.first(where: { $0.path == TVStorytellerPaths.normalizeHref(rootfile) })
        else { throw TVPublicationError("The EPUB is missing its package document.") }
        let opfData = try await data(for: opf, in: archive)
        let manifest = TVStorytellerPackageParser()
        guard manifest.parse(opfData) else { throw TVPublicationError("The EPUB package could not be read.") }
        let narrated = manifest.items.values.contains { $0.overlayID != nil }
        var prepared = book
        prepared.ebookFileURL = url
        return .epub(prepared, narrated: narrated)
    }

    private static func comic(url: URL, book: Book) async throws -> TVPublication {
        let pages = try await ComicArchiveService.shared.extractedPages(from: url, bookId: book.stableId)
        let direction = await ComicArchiveService.shared.readingDirection(from: url)
        try Task.checkCancellation()
        return .pages(.comic(pages, rightToLeft: direction == .rightToLeft))
    }

    private static func data(for entry: Entry, in archive: Archive) async throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await archive.extract(entry, to: temporary)
        return try Data(contentsOf: temporary)
    }
}
