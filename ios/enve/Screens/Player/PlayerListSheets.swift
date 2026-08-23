import SwiftUI

struct PlayerChaptersSheet: View {
    let chapters: [Chapter]
    let currentIndex: Int?
    let tint: Color

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Overline("Chapters")
                        .padding(.horizontal, 24)
                        .padding(.top, 28)
                        .padding(.bottom, 12)

                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            PlatformHaptics.selection()
                            playerVM.seekToChapter(chapter)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                if index == currentIndex {
                                    Image(systemName: "flame.fill")
                                        .font(.hearthUI(12))
                                        .foregroundStyle(tint)
                                }
                                Text(title(for: chapter, index: index))
                                    .font(.hearthDisplay(17, weight: index == currentIndex ? .semibold : .regular))
                                    .foregroundStyle(index == currentIndex ? tint : hearth.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Text(HearthFormat.duration(chapter.duration))
                                    .font(.hearthUI(13).monospacedDigit())
                                    .foregroundStyle(hearth.textTertiary)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .id(index)

                        if index < chapters.count - 1 {
                            Rectangle()
                                .fill(hearth.hairline)
                                .frame(height: 1)
                                .padding(.leading, 24)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let currentIndex {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
    }

    private func title(for chapter: Chapter, index: Int) -> String {
        let trimmed = chapter.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Chapter \(index + 1)" : trimmed
    }
}

struct PlayerBookmarksSheet: View {
    let tint: Color

    @Environment(EnveEngine.self) private var engine
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var clipsByBookmark: [String: AudiobookClip] = [:]
    @State private var clipDraft: PlayerClipDraft?
    @State private var transcriptPresentation: PlayerClipTranscriptPresentation?
    @State private var sharePayload: PlayerSharePayload?
    @State private var clipAlertMessage: String?
    @State private var busyBookmarkId: String?

    private var currentBook: Book? {
        playerVM.currentBook ?? engine.playback.currentBook
    }

    private var clipSupported: Bool {
        guard let book = currentBook, book.mediaType != .ebook else { return false }
        return LocalStorageManager.shared.localAudiobookFilesIfExists(for: book)?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Overline("Bookmarks")
                Spacer()
                if currentBook?.mediaType != .ebook {
                    GlyphButton(systemImage: "scissors", glyphSize: 14, label: "Clip this moment") {
                        playerOpenClipDraftAtCurrentPosition()
                    }
                }
                Button {
                    PlatformHaptics.notification(.success)
                    playerVM.addBookmark(at: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill")
                            .font(.hearthUI(12, weight: .semibold))
                        Text("Mark this moment")
                            .font(.hearthUI(13, weight: .semibold))
                    }
                    .foregroundStyle(hearth.onEmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(tint, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 8)

            if playerVM.bookmarks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("Nothing marked yet.")
                        .font(.hearthDisplay(18))
                        .foregroundStyle(hearth.textSecondary)
                    if currentBook?.mediaType != .ebook, !clipSupported {
                        Text("Download this book to cut clips from it.")
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(playerVM.bookmarks) { bookmark in
                        bookmarkRow(bookmark)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
            }
        }
        .onAppear(perform: playerReloadClips)
        .sheet(item: $clipDraft) { draft in
            PlayerClipEditorSheet(draft: draft, tint: tint) { startTime, endTime, title, note in
                playerSaveClip(from: draft, startTime: startTime, endTime: endTime, title: title, note: note)
            }
            .presentationDetents([.medium, .large])
            .hearthPresentationBackground()
            .presentationDragIndicator(.visible)
            .enveEnvironment()
        }
        .sheet(item: $transcriptPresentation) { presentation in
            PlayerClipTranscriptSheet(title: presentation.title, transcript: presentation.transcript)
                .presentationDetents([.medium, .large])
                .hearthPresentationBackground()
                .presentationDragIndicator(.visible)
                .enveEnvironment()
        }
        .sheet(item: $sharePayload) { payload in
            PlayerShareSheet(items: payload.items)
                .presentationDetents([.medium, .large])
        }
        .alert("Clips", isPresented: clipAlertPresented) {
            Button("All right") { clipAlertMessage = nil }
        } message: {
            Text(clipAlertMessage ?? "")
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        let clip = clipsByBookmark[bookmark.id]
        return Button {
            PlatformHaptics.selection()
            playerVM.seekToBookmark(bookmark)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bookmark.title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if let note = bookmark.note, !note.isEmpty {
                        Text(note)
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                    if let chapterTitle = bookmark.chapterTitle, !chapterTitle.isEmpty {
                        Text(chapterTitle)
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(1)
                    }
                    if let clip {
                        HStack(spacing: 5) {
                            Image(systemName: "scissors")
                                .font(.hearthUI(10, weight: .medium))
                            Text("\(HearthFormat.clock(clip.startTime)) - \(HearthFormat.clock(clip.endTime))")
                                .font(.hearthUI(11, weight: .medium).monospacedDigit())
                        }
                        .foregroundStyle(tint)
                    }
                }
                Spacer()
                if busyBookmarkId == bookmark.id {
                    ProgressView()
                        .tint(tint)
                } else {
                    Text(bookmark.formattedTime)
                        .font(.hearthUI(13).monospacedDigit())
                        .foregroundStyle(tint)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(hearth.hairline)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let book = currentBook {
                Button {
                    openURL(EnveNotesCaptureLink.url(book: book, bookmark: bookmark))
                } label: {
                    Label("Capture in Enve Notes", systemImage: "square.and.arrow.up")
                }
                .tint(hearth.ember)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                playerVM.removeBookmark(bookmark)
                playerReloadClips()
            } label: {
                Label("Forget", systemImage: "trash")
            }
            if bookmark.mediaType != .ebook {
                if let clip {
                    Button {
                        Task { await playerExportClip(bookmark: bookmark, clip: clip) }
                    } label: {
                        Label("Share clip", systemImage: "square.and.arrow.up")
                    }
                    .tint(hearth.ember)
                    Button {
                        Task { await playerShowTranscript(bookmark: bookmark, clip: clip) }
                    } label: {
                        Label("Transcript", systemImage: "text.quote")
                    }
                    .tint(hearth.statusOK)
                    Button {
                        AudiobookClipService.shared.deleteClip(bookId: bookmark.bookId, clipId: bookmark.id)
                        playerReloadClips()
                    } label: {
                        Label("Remove clip", systemImage: "scissors")
                    }
                    .tint(hearth.statusError)
                } else if clipSupported {
                    Button {
                        playerOpenClipDraft(for: bookmark)
                    } label: {
                        Label("Clip", systemImage: "scissors")
                    }
                    .tint(hearth.ember)
                }
            }
        }
    }

    private func playerReloadClips() {
        guard let book = currentBook else {
            clipsByBookmark = [:]
            return
        }
        clipsByBookmark = Dictionary(
            uniqueKeysWithValues: AudiobookClipService.shared.clips(bookId: book.stableId).map { ($0.bookmarkId, $0) }
        )
    }

    private func playerOpenClipDraftAtCurrentPosition() {
        guard let book = currentBook, let duration = playerClipDuration(for: book) else { return }
        clipDraft = PlayerClipDraft(
            bookmark: nil,
            clip: nil,
            anchorTime: playerVM.progress,
            bookDuration: duration
        )
    }

    private func playerOpenClipDraft(for bookmark: Bookmark) {
        guard let book = currentBook, let duration = playerClipDuration(for: book) else { return }
        clipDraft = PlayerClipDraft(
            bookmark: bookmark,
            clip: clipsByBookmark[bookmark.id],
            anchorTime: bookmark.position,
            bookDuration: duration
        )
    }

    private func playerClipDuration(for book: Book) -> TimeInterval? {
        guard clipSupported else {
            clipAlertMessage = "Download \u{201C}\(book.title)\u{201D} before cutting clips from it."
            return nil
        }
        let duration = max(playerVM.duration, book.duration ?? 0)
        guard duration > 0 else {
            clipAlertMessage = "This book does not have a usable duration yet."
            return nil
        }
        return duration
    }

    private func playerSaveClip(from draft: PlayerClipDraft, startTime: TimeInterval, endTime: TimeInterval, title: String, note: String?) {
        guard let book = currentBook else { return }

        if let bookmark = draft.bookmark {
            let resolvedTitle = title.isEmpty ? bookmark.title : title
            if resolvedTitle != bookmark.title || note != bookmark.note {
                playerVM.updateBookmark(bookmark, newTitle: resolvedTitle, newNote: note)
            }
            AudiobookClipService.shared.saveClip(bookId: book.stableId, bookmarkId: bookmark.id, startTime: startTime, endTime: endTime)
            playerReloadClips()
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let bookmark = playerVM.addBookmark(
                at: draft.anchorTime,
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                note: note
            )
        else {
            clipAlertMessage = "The clip's bookmark could not be created."
            return
        }
        AudiobookClipService.shared.saveClip(bookId: book.stableId, bookmarkId: bookmark.id, startTime: startTime, endTime: endTime)
        playerReloadClips()
    }

    private func playerExportClip(bookmark: Bookmark, clip: AudiobookClip) async {
        guard let book = currentBook else { return }
        busyBookmarkId = bookmark.id
        defer { busyBookmarkId = nil }

        do {
            let url = try await AudiobookClipService.shared.exportClip(clip, for: book, title: bookmark.title)
            sharePayload = PlayerSharePayload(items: [url])
        } catch {
            clipAlertMessage = error.localizedDescription
        }
    }

    private func playerShowTranscript(bookmark: Bookmark, clip: AudiobookClip) async {
        busyBookmarkId = bookmark.id
        defer { busyBookmarkId = nil }

        do {
            let transcript: String
            if let existing = clip.transcript, !existing.isEmpty {
                transcript = existing
            } else if let book = currentBook {
                transcript = try await AudiobookClipService.shared.transcribeClip(clip, for: book, title: bookmark.title)
                playerReloadClips()
            } else {
                throw AudiobookClipError.transcriptionFailed
            }
            transcriptPresentation = PlayerClipTranscriptPresentation(title: bookmark.title, transcript: transcript)
        } catch {
            clipAlertMessage = error.localizedDescription
        }
    }

    private var clipAlertPresented: Binding<Bool> {
        Binding(
            get: { clipAlertMessage != nil },
            set: { if !$0 { clipAlertMessage = nil } }
        )
    }
}

private struct PlayerClipTranscriptPresentation: Identifiable {
    let id = UUID()
    let title: String
    let transcript: String
}
