import SwiftUI

struct DragAndDropScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var books: [SourcesDragDropBook] = []
    @State private var isScanning = false
    @State private var scanMessage: String?
    @State private var loaded = false

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Drag & drop",
            subtitle: "Drop files into the Enve folder from a computer, then scan."
        ) {
            SourcesCard {
                QuietButton(title: isScanning ? "Scanning…" : "Scan for new books", systemImage: "arrow.clockwise") {
                    scan()
                }
                .disabled(isScanning)
                if let scanMessage {
                    Text(scanMessage)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }

            if !loaded {
                SourcesCard {
                    HStack(spacing: 10) {
                        ProgressView().tint(hearth.ember)
                        Text("Checking the folder…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            } else if books.isEmpty {
                howToCard
            } else {
                SourcesCard {
                    Overline("\(books.count) in the folder")
                    ForEach(books) { book in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .font(.hearthUI(15))
                                .foregroundStyle(hearth.ember)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title)
                                    .font(.hearthBody.weight(.medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    if let author = book.author {
                                        Text(author)
                                            .lineLimit(1)
                                    }
                                    Text(book.format.uppercased())
                                    Text(dragDropFileSize(book.fileSize))
                                }
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .task { reload() }
    }

    private var howToCard: some View {
        SourcesCard {
            Overline("How it works")
            dragDropStep("1", "Connect the phone to a computer with USB or Wi-Fi sync.")
            dragDropStep("2", "On a Mac, open Finder, choose this device, and open the Files tab. On Windows, use iTunes file sharing.")
            dragDropStep("3", "Drag audiobook or ebook files into the Enve folder. Folders like Author Name/Book Title also work.")
            dragDropStep("4", "Come back here and scan. Enve sorts the arrivals into the library.")
        }
    }

    private func dragDropStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.hearthUI(12, weight: .bold))
                .foregroundStyle(hearth.onEmber)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hearth.ember))
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reload() {
        books = engine.sources.dragDropBooks()
        loaded = true
    }

    private func scan() {
        isScanning = true
        scanMessage = nil
        Task {
            do {
                let count = try await engine.sources.scanDragDropLibrary()
                scanMessage = "Found \(count) book\(count == 1 ? "" : "s")."
                reload()
                PlatformHaptics.notification(.success)
            } catch {
                scanMessage = error.localizedDescription
            }
            isScanning = false
        }
    }
}

private func dragDropFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
