import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourcesFilesScreen: View {
    let onAdded: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var activeMode: SourcesFilesPickerMode?
    @State private var isImporting = false
    @State private var importedCount: Int?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        SourcesProviderLogo(assetName: nil, systemName: "folder", size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Overline("From this device")
                            Text("Files")
                                .font(.hearthDisplay(26))
                                .foregroundStyle(hearth.text)
                        }
                    }

                    Text("Bring in audiobooks and ebooks from Files or iCloud Drive.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)

                    SourcesCard {
                        ForEach(SourcesFilesPickerMode.allCases) { mode in
                            Button {
                                activeMode = mode
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: mode.glyph)
                                        .font(.hearthUI(16))
                                        .foregroundStyle(hearth.ember)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.title)
                                            .font(.hearthBody.weight(.medium))
                                            .foregroundStyle(hearth.text)
                                        Text(mode.caption)
                                            .font(.hearthCaption)
                                            .foregroundStyle(hearth.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.hearthUI(12, weight: .semibold))
                                        .foregroundStyle(hearth.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(isImporting)
                        }
                    }

                    if isImporting {
                        HStack(spacing: 8) {
                            ProgressView().tint(hearth.ember)
                            Text("Bringing your books in…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    if let importedCount {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(hearth.statusOK)
                            Text("\(importedCount) book\(importedCount == 1 ? "" : "s") brought in.")
                                .font(.hearthBody)
                                .foregroundStyle(hearth.text)
                        }
                    }
                    if let error { SourcesErrorText(message: error) }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .sheet(item: $activeMode) { mode in
                SourcesDocumentPicker(
                    allowFolders: mode.allowFolders,
                    allowsMultipleSelection: mode.allowsMultipleSelection
                ) { urls in
                    handleImport(urls, audioSelectionMode: mode.audioSelectionMode)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func handleImport(_ urls: [URL], audioSelectionMode: SourcesFilesImportMode) {
        guard !urls.isEmpty else { return }
        isImporting = true
        error = nil

        Task {
            do {
                let count = try await engine.sources.importFiles(
                    urls: urls,
                    mode: audioSelectionMode
                )

                importedCount = count
                isImporting = false
                PlatformHaptics.notification(.success)
                try? await Task.sleep(for: .seconds(1.2))
                onAdded()
            } catch {
                self.error = error.localizedDescription
                self.isImporting = false
            }
        }
    }
}

enum SourcesFilesPickerMode: String, CaseIterable, Identifiable {
    case file, book, folder, multipleBooks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: "A single file"
        case .book: "A book"
        case .folder: "A folder"
        case .multipleBooks: "Several books"
        }
    }

    var caption: String {
        switch self {
        case .file: "One audio file or ebook"
        case .book: "All the files of one book"
        case .folder: "Everything inside a folder"
        case .multipleBooks: "Each selection becomes its own book"
        }
    }

    var glyph: String {
        switch self {
        case .file: "doc"
        case .book: "books.vertical"
        case .folder: "folder"
        case .multipleBooks: "rectangle.stack.badge.plus"
        }
    }

    var allowFolders: Bool { self == .folder }

    var allowsMultipleSelection: Bool {
        switch self {
        case .file, .folder: false
        case .book, .multipleBooks: true
        }
    }

    var audioSelectionMode: SourcesFilesImportMode {
        self == .multipleBooks ? .splitSelectedBooks : .groupByFolder
    }
}

struct SourcesDocumentPicker: UIViewControllerRepresentable {
    let allowFolders: Bool
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker: UIDocumentPickerViewController
        if allowFolders {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        } else {
            let types: [UTType] = [
                .audio,
                UTType("org.idpf.epub-container") ?? .epub,
                .pdf,
                .zip,
                UTType(filenameExtension: "mp3") ?? .audio,
                UTType(filenameExtension: "m4b") ?? .audio,
                UTType(filenameExtension: "m4a") ?? .audio,
                UTType(filenameExtension: "flac") ?? .audio,
                UTType(filenameExtension: "ogg") ?? .audio,
                UTType(filenameExtension: "opus") ?? .audio,
                UTType(filenameExtension: "aac") ?? .audio,
            ]
            let unique = Array(Set(types.map(\.identifier)).compactMap { UTType($0) })
            picker = UIDocumentPickerViewController(forOpeningContentTypes: unique, asCopy: false)
        }
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {}
    }
}
