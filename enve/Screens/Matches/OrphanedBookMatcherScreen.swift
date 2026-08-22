import AVFoundation
import Logging
import SwiftUI

struct OrphanedBookMatcherScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mantelInset) private var mantelInset

    private var orphanedBooks: [Book] {
        engine.matches.orphanedBooks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Found in the cellar")
                        Text("Recovered downloads")
                            .font(.hearthDisplay(24, weight: .semibold))
                            .foregroundStyle(hearth.text)
                    }
                    Spacer()
                    QuietButton(title: "Done") {
                        engine.matches.dismissAllOrphanedBooks()
                        dismiss()
                    }
                }
                .padding(.top, 24)

                if orphanedBooks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every download found its book.")
                            .font(.hearthDisplay(20, weight: .semibold))
                            .foregroundStyle(hearth.text)
                        Text("The files are reconnected to your library.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    }
                } else {
                    Text(
                        orphanedBooks.count == 1
                            ? "One downloaded book has no library match. Preview it, then match it to a server book."
                            : "\(orphanedBooks.count) downloaded books have no library match. Preview each, then match them to your servers."
                    )
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    LazyVStack(spacing: 14) {
                        ForEach(orphanedBooks, id: \.uniqueId) { book in
                            MatchesOrphanCard(orphan: book)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            engine.matches.refreshOrphanedBooks()
        }
    }
}

private struct MatchesOrphanCard: View {
    let orphan: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var preview = MatchesAudioPreviewPlayer()
    @State private var matchSheetShown = false
    @State private var deleteConfirmShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CoverTile(book: orphan, width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(orphan.title)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = orphan.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    if let duration = orphan.duration, duration > 0 {
                        Text(HearthFormat.duration(duration))
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    previewControls
                }
                Spacer()
            }

            HStack(spacing: 12) {
                EmberButton(title: "Match to library", systemImage: "link") {
                    matchSheetShown = true
                }
                Menu {
                    Button {
                        engine.matches.dismissOrphanedBook(orphan)
                    } label: {
                        Label("Keep as local", systemImage: "tray.and.arrow.down")
                    }
                    Button(role: .destructive) {
                        deleteConfirmShown = true
                    } label: {
                        Label("Delete files", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle()
                                .fill(hearth.bg)
                                .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                        }
                }
                .accessibilityLabel("More options")
            }
        }
        .padding(16)
        .background(dedupCardBackground(hearth))
        .confirmationDialog("Delete this download?", isPresented: $deleteConfirmShown) {
            Button("Delete files", role: .destructive) {
                preview.stop()
                engine.matches.deleteOrphanedBook(orphan)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The downloaded audio for \u{201C}\(orphan.title)\u{201D} is removed for good.")
        }
        .sheet(isPresented: $matchSheetShown) {
            MatchesOrphanMatchSheet(orphan: orphan)
                .enveEnvironment()
        }
        .onDisappear { preview.stop() }
    }

    private var previewControls: some View {
        HStack(spacing: 8) {
            Button {
                if preview.isPlaying {
                    preview.stop()
                } else {
                    playPreview()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: preview.isPlaying ? "stop.fill" : "play.fill")
                        .font(.hearthUI(10, weight: .semibold))
                    Text(preview.isPlaying ? "Stop" : "Hear a minute")
                        .font(.hearthUI(12, weight: .semibold))
                }
                .foregroundStyle(hearth.ember)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(hearth.emberSoft, in: Capsule())
                .frame(minHeight: 32)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(preview.isPlaying ? "Stop preview" : "Play a one minute preview")

            if preview.isPlaying {
                Text("\(HearthFormat.clock(preview.currentTime)) / 1:00")
                    .font(.hearthUI(11))
                    .monospacedDigit()
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .padding(.top, 2)
    }

    private func playPreview() {
        if let first = engine.matches.localPreviewFiles(for: orphan).first {
            preview.play(url: first, maxDuration: 60)
            return
        }
        AppLogger.general.debug(
            "No audio files found bookId=\(DiagnosticLogSanitizer.identifier(for: orphan.stableId))"
        )
    }
}

private struct MatchesOrphanMatchSheet: View {
    let orphan: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var serverBooks: [Book] = []
    @State private var selected: Book?
    @State private var confirmShown = false
    @State private var loaded = false

    private var filtered: [Book] {
        guard !query.isEmpty else { return serverBooks }
        let q = query.lowercased()
        return serverBooks.filter {
            $0.title.lowercased().contains(q) || ($0.author?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Overline("Recovered downloads")
                Text("Match to a library book")
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
            }
            .padding(.top, 24)

            CollectionsSearchField(text: $query)

            if !loaded {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(hearth.ember)
                    Text("Fetching your libraries.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            } else if filtered.isEmpty {
                Text(query.isEmpty ? "No server books to match against." : "Nothing answers to \u{201C}\(query)\u{201D}.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered, id: \.stableId) { book in
                            Button {
                                selected = book
                                confirmShown = true
                            } label: {
                                row(book)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 24)
        .hearthPresentationBackground()
        .presentationDragIndicator(.visible)
        .task {
            serverBooks = await engine.matches.matchableServerBooks(for: orphan)
            loaded = true
        }
        .confirmationDialog("Confirm the match", isPresented: $confirmShown, presenting: selected) { book in
            Button("Match") {
                engine.matches.matchOrphanedBook(orphan, to: book)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { book in
            Text(
                "Match \u{201C}\(orphan.title)\u{201D} to \u{201C}\(book.title)\u{201D}? The files and any listening progress move to this book."
            )
        }
    }

    private func row(_ book: Book) -> some View {
        HStack(spacing: 12) {
            CoverTile(book: book, width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author {
                    Text(author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Text(book.source.rawValue.capitalized)
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(12)
        .background(dedupCardBackground(hearth))
    }
}

@MainActor
@Observable
final class MatchesAudioPreviewPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var maxDuration: TimeInterval = 60

    func play(url: URL, maxDuration: TimeInterval = 60) {
        stop()
        self.maxDuration = maxDuration
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            isPlaying = true
            currentTime = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    self.currentTime = player.currentTime
                    if player.currentTime >= self.maxDuration || !player.isPlaying {
                        self.stop()
                    }
                }
            }
        } catch {
            AppLogger.general.error(
                "Preview failed \(DiagnosticLogSanitizer.fileDescriptor(for: url)): \(error)"
            )
            isPlaying = false
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
    }
}
