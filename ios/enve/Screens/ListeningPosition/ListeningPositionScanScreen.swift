#if os(iOS)
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import PhotosUI
import SwiftUI
import UIKit

struct ListeningPositionScanScreen: View {
    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var model: ListeningPositionScanModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    if model.payload == nil {
                        ListeningPositionCaptureView(model: model)
                    } else {
                        ListeningPositionMatchView(model: model) { dismiss() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(hearth.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if model == nil {
                model = ListeningPositionScanModel(session: capturedSession ?? .owner)
            }
        }
    }
}

private struct ListeningPositionImportedImage: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= ListeningPositionQRCode.maxImageBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

private struct ListeningPositionCaptureView: View {
    let model: ListeningPositionScanModel

    @Environment(\.hearth) private var hearth
    @Environment(\.openURL) private var openURL

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var isReadingImage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Overline("Scan book position")
                    .padding(.top, 12)
                Text("Point the camera at a book-position code shown in Enve, or choose a screenshot of one. You'll pick which of your books to move before anything changes.")
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                camera

                QuietButton(title: isReadingImage ? "Reading image…" : "Choose an image", systemImage: "photo.on.rectangle") {
                    showPhotoPicker = true
                }
                .disabled(isReadingImage)
                .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)

                if let error = model.scanError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .task {
            if cameraStatus == .notDetermined && ListeningPositionCameraScanner.isSupported {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                isReadingImage = true
                defer {
                    isReadingImage = false
                    photoItem = nil
                }
                if let imported = try? await item.loadTransferable(type: ListeningPositionImportedImage.self) {
                    defer { try? FileManager.default.removeItem(at: imported.url) }
                    let data = try? Data(contentsOf: imported.url, options: .mappedIfSafe)
                    await model.handleImportedImage(data ?? Data())
                } else {
                    await model.handleImportedImage(Data())
                }
            }
        }
    }

    @ViewBuilder
    private var camera: some View {
        if !ListeningPositionCameraScanner.isSupported {
            note("This device can't scan codes live. Choose a screenshot or photo of the code instead.")
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            VStack(alignment: .leading, spacing: 10) {
                note("Camera access is off. Choose a screenshot or photo of the code instead, or allow camera access in Settings.")
                if cameraStatus == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    QuietButton(title: "Open Settings", systemImage: "gearshape") { openURL(settings) }
                }
            }
        } else if cameraStatus == .authorized && ListeningPositionCameraScanner.isReady {
            ListeningPositionCameraScanner { message in
                Task { await model.handleScanned(message) }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .accessibilityLabel("Camera viewfinder")
            .accessibilityHint("Hold a book-position code inside the frame.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.hearthUI(14))
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ListeningPositionMatchView: View {
    let model: ListeningPositionScanModel
    let onFinish: () -> Void

    @Environment(\.hearth) private var hearth
    @State private var query = ""
    @State private var selection: ListeningPositionCandidate?

    var body: some View {
        if let payload = model.payload {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Overline("Shared book position")
                        .padding(.top, 12)
                    ListeningPositionSharedSummary(payload: payload)

                    suggestions

                    VStack(alignment: .leading, spacing: 10) {
                        Overline("Search your library")
                        TextField("Title, author, narrator or series", text: $query)
                            .font(.hearthUI(15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background {
                                RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                                    .fill(hearth.bgSunken)
                            }
                            .accessibilityLabel("Search your library for this book")
                        ForEach(model.searchResults) { candidate in
                            row(candidate)
                        }
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty && model.searchResults.isEmpty {
                            Text("No compatible books in your library match “\(query)”.")
                                .font(.hearthUI(13))
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }

                    QuietButton(title: "Scan a different code", systemImage: "qrcode.viewfinder") {
                        query = ""
                        model.reset()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.search(query)
            }
            .navigationDestination(isPresented: isShowingSelection) {
                if let selection {
                    ListeningPositionConfirmView(model: model, candidate: selection, onFinish: onFinish)
                }
            }
        }
    }

    private var isShowingSelection: Binding<Bool> {
        Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })
    }

    @ViewBuilder
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("Matches in your library")
            if model.isLoadingSuggestions {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .accessibilityLabel("Finding matches")
            } else if model.suggestions.isEmpty {
                Text("No compatible book in your library has the same title and author. Search below to choose one yourself.")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.suggestions) { candidate in
                    row(candidate)
                }
            }
        }
    }

    private func row(_ candidate: ListeningPositionCandidate) -> some View {
        Button {
            model.clearStatus()
            selection = candidate
        } label: {
            ListeningPositionCandidateRow(candidate: candidate)
        }
        .buttonStyle(PressableStyle())
    }
}

struct ListeningPositionSharedSummary: View {
    let payload: ListeningPositionPayload

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(payload.title)
                .font(.hearthDisplay(22))
                .foregroundStyle(hearth.text)
                .fixedSize(horizontal: false, vertical: true)
            if !payload.authors.isEmpty {
                Text(payload.authors.joined(separator: ", "))
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
            }
            if !payload.narrators.isEmpty {
                Text("Narrated by \(payload.narrators.joined(separator: ", "))")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textTertiary)
            }
            if let series = payload.series {
                Text(payload.seriesSequence.map { "\(series) · Book \($0)" } ?? series)
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textTertiary)
            }
            Text(ListeningPositionText.position(payload, includesTotal: true))
                .font(.hearthUI(15, weight: .semibold).monospacedDigit())
                .foregroundStyle(hearth.ember)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ListeningPositionCandidateRow: View {
    let candidate: ListeningPositionCandidate

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 12) {
            CoverTile(book: candidate.book, width: 52, badges: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.book.title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Text(ListeningPositionText.byline(for: candidate.book))
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(2)
                Text(ListeningPositionText.summary(for: candidate))
                    .font(.hearthUI(12, weight: .medium))
                    .foregroundStyle(candidate.warnings.isEmpty ? hearth.textTertiary : hearth.statusWarn)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Review before moving this copy")
    }
}

enum ListeningPositionText {
    static func position(_ payload: ListeningPositionPayload, includesTotal: Bool = false) -> String {
        if let reading = payload.readingLocation {
            if let page = reading.page {
                return reading.pageCount.map { "Page \(page) of \($0)" } ?? "Page \(page)"
            }
            return reading.progression.formatted(.percent.precision(.fractionLength(1)))
        }
        let position = HearthFormat.clock(payload.position)
        return includesTotal ? "\(position) of \(HearthFormat.clock(payload.duration))" : position
    }

    static func byline(for book: Book) -> String {
        let author = book.authors.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? book.author
        let source = [book.backendName ?? book.source.rawValue.capitalized, book.libraryName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let format = book.mediaType == .ebook ? ListeningPositionReadingLocation.format(for: book).uppercased() : book.duration.map(HearthFormat.duration)
        return [author, format, source]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func summary(for candidate: ListeningPositionCandidate) -> String {
        if let warning = candidate.warnings.first { return text(for: warning) }
        if candidate.signals.contains(.sameIdentifier) { return "Same edition identifier" }
        if candidate.signals.contains(.sameLength) { return "Same title, author and length" }
        return "Same title and author"
    }

    static func text(for warning: ListeningPositionCandidate.Warning) -> String {
        switch warning {
        case .titleDiffers:
            "The title doesn't match the shared book."
        case .authorDiffers:
            "The author doesn't match the shared book."
        case .lengthDiffers(let minutes):
            "Length differs by about \(minutes) min, so this may be another recording or edition and the same time can land somewhere else."
        case .lengthUnknown:
            "This copy's length is unknown, so Enve can't compare recordings."
        case .narratorDiffers:
            "Different narrator, which usually means a different recording."
        case .seriesPositionDiffers:
            "A different book in the series."
        case .positionBeyondEnd:
            "The shared position is past the end of this copy."
        case .formatDiffers:
            "This copy uses a different reading format. The same percentage may land at a different passage."
        case .pageCountDiffers:
            "This copy has a different page count. Review the edition before applying this page."
        }
    }
}
#endif
