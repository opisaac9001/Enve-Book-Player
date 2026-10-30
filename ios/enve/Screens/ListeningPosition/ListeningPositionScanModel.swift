#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ListeningPositionScanModel {
    enum Status: Equatable {
        case idle
        case applying
        case done(ListeningPositionApplyResult)
        case failed(String)
    }

    private(set) var payload: ListeningPositionPayload?
    private(set) var scanError: String?
    private(set) var suggestions: [ListeningPositionCandidate] = []
    private(set) var isLoadingSuggestions = false
    private(set) var searchResults: [ListeningPositionCandidate] = []
    private(set) var status: Status = .idle

    @ObservationIgnored private var lastRejectedMessage: String?
    @ObservationIgnored private let store: any BookQuerying
    @ObservationIgnored private let applier: ListeningPositionApplier
    @ObservationIgnored private let playback: any PlaybackStateProvider

    init(store: any BookQuerying, applier: ListeningPositionApplier, playback: any PlaybackStateProvider) {
        self.store = store
        self.applier = applier
        self.playback = playback
    }

    convenience init(session: ProfileSession) {
        self.init(
            store: session.bookStore,
            applier: ListeningPositionApplier(target: LiveListeningPositionProgressTarget(session: session)),
            playback: session.playback.composition.controller
        )
    }

    /// Live scanning reports the same code many times a second; a rejected code is reported once.
    func handleScanned(_ message: String) async {
        guard payload == nil, message != lastRejectedMessage else { return }
        do throws(ListeningPositionPayloadError) {
            accept(try ListeningPositionPayload.decode(message))
            await loadSuggestions()
        } catch {
            lastRejectedMessage = message
            scanError = Self.description(of: error)
        }
    }

    func handleImportedImage(_ data: Data) async {
        let messages = await Task.detached(priority: .userInitiated) {
            ListeningPositionQRCode.messages(inImageData: data)
        }.value
        guard !Task.isCancelled, payload == nil else { return }
        guard !messages.isEmpty else {
            scanError = "Couldn't read a listening-position code. Use a clear screenshot under 20 MB."
            return
        }
        var firstError: ListeningPositionPayloadError?
        for message in messages {
            do throws(ListeningPositionPayloadError) {
                accept(try ListeningPositionPayload.decode(message))
                await loadSuggestions()
                return
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { scanError = Self.description(of: firstError) }
    }

    func search(_ query: String) async {
        guard let payload else { return }
        let results = await ListeningPositionMatcher.search(query, for: payload, in: store)
        guard !Task.isCancelled, self.payload == payload else { return }
        searchResults = results
    }

    func currentPosition(of book: Book) -> TimeInterval {
        let snapshot = playback.snapshot
        return snapshot.currentBook?.uniqueId == book.uniqueId ? snapshot.position : book.currentTime
    }

    func apply(_ candidate: ListeningPositionCandidate) async {
        guard let payload, status != .applying else { return }
        status = .applying
        do throws(ListeningPositionApplyError) {
            status = .done(try await applier.apply(payload, to: candidate.book))
        } catch {
            switch error {
            case .positionBeyondEnd:
                status = .failed("The shared position is past the end of this copy, so it wasn't applied.")
            case .incompatibleMedia:
                status = .failed("Choose a reading copy for a reading position, or an audio copy for a timestamp.")
            case .bookUnavailable:
                status = .failed("This copy is no longer available in this profile's library.")
            }
        }
    }

    func clearStatus() {
        if case .applying = status { return }
        status = .idle
    }

    func reset() {
        payload = nil
        suggestions = []
        isLoadingSuggestions = false
        searchResults = []
        status = .idle
        scanError = nil
        lastRejectedMessage = nil
    }

    private func accept(_ decoded: ListeningPositionPayload) {
        payload = decoded
        scanError = nil
        lastRejectedMessage = nil
    }

    private func loadSuggestions() async {
        guard let payload else { return }
        isLoadingSuggestions = true
        let results = await ListeningPositionMatcher.suggestions(for: payload, in: store)
        guard !Task.isCancelled, self.payload == payload else { return }
        suggestions = results
        isLoadingSuggestions = false
    }

    static func description(of error: ListeningPositionPayloadError) -> String {
        switch error {
        case .tooLarge:
            "That code holds too much data to be a listening position."
        case .notListeningPosition:
            "That isn't an Enve book-position code."
        case .unsupportedVersion:
            "That code comes from a newer version of Enve. Update Enve to use it."
        case .invalidField:
            "That book-position code is damaged or incomplete."
        }
    }
}
#endif
