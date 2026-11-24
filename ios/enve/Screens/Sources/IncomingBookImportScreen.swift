#if os(iOS)
import SwiftUI

final class IncomingBookImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let stagingError: String?
    private let stagingDirectory: URL?

    init(url: URL, inboxDirectory: URL? = nil) {
        let inbox = inboxDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox", isDirectory: true)
        if Self.supports(url), url.standardizedFileURL.path.hasPrefix(inbox.standardizedFileURL.path + "/") {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("EnveIncoming-" + UUID().uuidString, isDirectory: true)
            let destination = staging.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                // Claim the app's Inbox copy before the folder watcher can ingest it.
                try FileManager.default.moveItem(at: url, to: destination)
                self.url = destination
                stagingDirectory = staging
                stagingError = nil
            } catch {
                try? FileManager.default.removeItem(at: staging)
                self.url = url
                stagingDirectory = nil
                stagingError = "This file is no longer available. Try opening the original file again."
            }
        } else {
            self.url = url
            stagingDirectory = nil
            stagingError = nil
        }
    }

    deinit {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
    }

    nonisolated static func supports(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "zip"
            || AudiobookFormat.from(fileExtension: ext) != nil
            || (ext != "imagefolder" && EbookFormat.from(fileExtension: ext) != nil)
    }
}

struct IncomingBookImportScreen: View {
    let request: IncomingBookImportRequest
    let profileSession: ProfileSession
    let isReady: Bool
    let onOpen: (Book) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var books: [Book] = []
    @State private var isImporting = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Overline("From another app")
                    Text(isImporting ? "Adding your book" : books.isEmpty ? "Couldn’t add this file" : "Added to your library")
                        .font(.hearthDisplay(28))
                        .foregroundStyle(hearth.text)
                    Text(request.url.lastPathComponent)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .textSelection(.enabled)
                    if isImporting {
                        ProgressView("Importing…")
                            .tint(hearth.ember)
                    }
                    if let errorMessage {
                        SourcesErrorText(message: errorMessage)
                    }
                    ForEach(books, id: \.stableId) { book in
                        Button {
                            onOpen(book)
                        } label: {
                            Label(book.title, systemImage: book.mediaType == .ebook ? "book" : "play.fill")
                                .font(.hearthBody)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: Hearth.radiusCard))
                        }
                        .foregroundStyle(hearth.ember)
                        .accessibilityLabel("Open \(book.title)")
                    }
                    if !books.isEmpty {
                        Text("A copy is saved in Enve. The original file stays where it is.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                .padding(24)
            }
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isImporting)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .accessibilityIdentifier("incoming-book-import")
        .task(id: isReady) {
            guard isReady, isImporting, !profileSession.isRetired else { return }
            if let error = request.stagingError {
                errorMessage = error
                isImporting = false
                return
            }
            guard IncomingBookImportRequest.supports(request.url) else {
                errorMessage = "Choose a supported ebook, audiobook, comic, or ZIP archive."
                isImporting = false
                return
            }
            do {
                books = try await profileSession.engine.sources.importFiles(urls: [request.url], mode: .splitSelectedBooks)
                try Task.checkCancellation()
                guard !profileSession.isRetired else { return }
                await profileSession.engine.sources.refreshVisibleLibraryScope(.device)
                try Task.checkCancellation()
                guard !profileSession.isRetired else { return }
                if books.isEmpty {
                    errorMessage = "No readable books were found. Check that the file finished downloading and is not damaged."
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

#endif
