import AVFoundation
import Combine
import Foundation

@MainActor
@Observable
final class AmbientAudioService {
    static let shared = AmbientAudioService()

    private let store = AmbientAudioStore.shared
    private let playback: any PlaybackControlling
    private var player: AVAudioPlayer?
    private var activeScopedURL: URL?
    private var currentBookId: String?
    private var cancellables = Set<AnyCancellable>()

    var currentSelection: AmbientAudioSelection?
    var isPlaying = false
    var errorMessage: String?

    private init(playback: any PlaybackControlling = ActivePlayback.controller) {
        self.playback = playback
        observePlayback()
        handleBookChange(playback.snapshot.currentBook)
    }

    var currentVolume: Double {
        store.loadVolume(fallback: currentSelection?.volume)
    }

    func attachPresetToCurrentBook(_ preset: AmbientAudioPreset) {
        guard let book = playback.snapshot.currentBook else {
            errorMessage = "Open a book before attaching ambient audio."
            return
        }

        guard preset.url != nil else {
            errorMessage = "\(preset.title) is missing from the app bundle."
            return
        }

        do {
            let selection = AmbientAudioSelection(
                bookId: book.stableId,
                displayName: preset.title,
                presetId: preset.id,
                volume: currentVolume
            )
            store.save(selection)
            currentBookId = book.stableId
            currentSelection = selection
            try configurePlayer(for: selection)
            if playback.snapshot.isPlaying {
                startPlaybackIfNeeded()
            }
        } catch {
            errorMessage = "Couldn't attach ambient audio: \(error.localizedDescription)"
        }
    }

    func attachTrackToCurrentBook(from url: URL) {
        guard let book = playback.snapshot.currentBook else {
            errorMessage = "Open a book before attaching ambient audio."
            return
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let selection = AmbientAudioSelection(
                bookId: book.stableId,
                displayName: url.lastPathComponent,
                bookmarkData: bookmarkData,
                volume: currentVolume
            )
            store.save(selection)
            currentBookId = book.stableId
            currentSelection = selection
            try configurePlayer(for: selection)
            if playback.snapshot.isPlaying {
                startPlaybackIfNeeded()
            }
        } catch {
            errorMessage = "Couldn't attach ambient audio: \(error.localizedDescription)"
        }
    }

    func removeTrackFromCurrentBook() {
        guard let bookId = currentBookId else { return }
        store.clearSelection(bookId: bookId)
        teardownPlayer()
        currentSelection = nil
    }

    func updateVolume(_ volume: Double) {
        let clamped = max(0, min(volume, 1))
        store.saveVolume(clamped)
        player?.volume = Float(clamped)
        isPlaying = player?.isPlaying == true

        guard var selection = currentSelection else { return }
        selection.volume = clamped
        currentSelection = selection
        store.save(selection)
    }

    func clearError() {
        errorMessage = nil
    }

    private func observePlayback() {
        playback.snapshots
            .map { $0.currentBook }
            .removeDuplicates { $0?.stableId == $1?.stableId }
            .receive(on: RunLoop.main)
            .sink { [weak self] book in
                self?.handleBookChange(book)
            }
            .store(in: &cancellables)

        playback.snapshots
            .map(\.isPlaying)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                self?.handleNarrationPlaybackChange(isPlaying: isPlaying)
            }
            .store(in: &cancellables)
    }

    private func handleBookChange(_ book: Book?) {
        teardownPlayer()

        guard let book else {
            currentBookId = nil
            currentSelection = nil
            return
        }

        let bookId = book.stableId
        currentBookId = bookId
        currentSelection = store.loadSelection(bookId: bookId)

        guard let selection = currentSelection else { return }

        do {
            try configurePlayer(for: selection)
            if playback.snapshot.isPlaying {
                startPlaybackIfNeeded()
            }
        } catch {
            errorMessage = "Couldn't load ambient audio: \(error.localizedDescription)"
        }
    }

    private func handleNarrationPlaybackChange(isPlaying: Bool) {
        guard currentSelection != nil else { return }
        if isPlaying {
            startPlaybackIfNeeded()
        } else {
            pausePlayback()
        }
    }

    private func configurePlayer(for selection: AmbientAudioSelection) throws {
        teardownPlayer()

        let url = try resolveURL(for: selection)
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1
        player.volume = Float(currentVolume)
        player.prepareToPlay()
        self.player = player
        self.isPlaying = false
    }

    private func resolveURL(for selection: AmbientAudioSelection) throws -> URL {
        if let presetId = selection.presetId,
            let preset = AmbientAudioPresets.preset(id: presetId),
            let url = preset.url
        {
            return url
        }

        guard let bookmarkData = selection.bookmarkData else {
            throw NSError(
                domain: "AmbientAudioService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The selected ambient sound is no longer available."]
            )
        }

        var isStale = false
        #if os(macOS)
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif

        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(
                domain: "AmbientAudioService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The selected file is no longer available."]
            )
        }

        activeScopedURL = url

        if isStale {
            var refreshed = selection
            #if os(macOS)
            let bookmarkOptions: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let bookmarkOptions: URL.BookmarkCreationOptions = .minimalBookmark
            #endif
            refreshed = AmbientAudioSelection(
                bookId: selection.bookId,
                displayName: selection.displayName,
                bookmarkData: try url.bookmarkData(
                    options: bookmarkOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ),
                volume: currentVolume,
                createdAt: selection.createdAt
            )
            currentSelection = refreshed
            store.save(refreshed)
        }

        return url
    }

    private func startPlaybackIfNeeded() {
        guard let player else { return }
        if !player.isPlaying {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
    }

    private func teardownPlayer() {
        player?.stop()
        player = nil
        isPlaying = false

        if let activeScopedURL {
            activeScopedURL.stopAccessingSecurityScopedResource()
            self.activeScopedURL = nil
        }
    }
}
