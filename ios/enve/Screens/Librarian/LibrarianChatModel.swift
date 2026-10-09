import Foundation

@MainActor
@Observable
final class LibrarianChatModel {
    let book: Book
    let initialEbookProgress: Double?
    var messages: [LibrarianMessage]
    var transcriptSegments: [TranscriptSegment] = []
    var ebookChunks: [EbookContextChunk] = []
    var ebookContextStatus: BookTranscriptStatus = .missing
    var isSending = false
    var sendStatusText: String?
    var alertMessage: String?

    @ObservationIgnored private lazy var transcriptStore = BookTranscriptStore.shared
    @ObservationIgnored private lazy var ebookContextStore = EbookContextStore.shared
    @ObservationIgnored private lazy var conversationStore = LibrarianConversationStore.shared
    @ObservationIgnored private lazy var contextRetriever = BookContextRetriever.shared
    @ObservationIgnored private lazy var transcriptionService = AudiobookTranscriptionService.shared
    @ObservationIgnored private lazy var ebookContextService = EbookContextService.shared
    @ObservationIgnored private lazy var librarianService = EnveLibrarianService.shared

    @ObservationIgnored private let profileSession: ProfileSession
    private var isAvailable: Bool { profileSession.isOwner && !profileSession.isRetired }

    init(book: Book, initialEbookProgress: Double? = nil, profileSession: ProfileSession = .owner) {
        self.profileSession = profileSession
        self.book = book
        self.initialEbookProgress = initialEbookProgress
        self.messages = []
        guard isAvailable else { return }
        self.messages = conversationStore.loadMessages(bookStableId: book.stableId)
        reloadTranscript()
        reloadEbookContext()
    }

    var modelAvailabilityMessage: String? {
        guard isAvailable else { return "The Librarian is available in the owner profile." }
        return librarianService.availabilityMessage()
    }

    func reloadTranscript() {
        guard isAvailable else { return }
        transcriptSegments = transcriptStore.loadTranscript(bookStableId: book.stableId)?.segments ?? []
    }

    func reloadEbookContext() {
        guard isAvailable else { return }
        let context = ebookContextStore.loadContext(bookStableId: book.stableId)
        ebookChunks = context?.chunks ?? []
        ebookContextStatus = context?.manifest.status ?? .missing
    }

    func prepareEbookContextIfNeeded() async {
        guard isAvailable else { return }
        guard book.mediaType == .ebook, ebookChunks.isEmpty else { return }
        do {
            try await ebookContextService.prepareContext(for: book)
        } catch {
            alertMessage = error.localizedDescription
        }
        reloadEbookContext()
    }

    func clearConversation() {
        guard isAvailable else { return }
        messages = []
        conversationStore.clear(bookStableId: book.stableId)
    }

    func send(
        question: String,
        scope: BookIntelligenceScope,
        currentTime: TimeInterval,
        contextRange: ClosedRange<TimeInterval>? = nil
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !trimmed.isEmpty, !isSending else { return }

        isSending = true
        sendStatusText = "Preparing context"
        defer {
            isSending = false
            sendStatusText = nil
        }

        let history = messages
        messages.append(LibrarianMessage(role: .user, text: trimmed, scope: scope))
        conversationStore.saveMessages(messages, bookStableId: book.stableId)

        do {
            let resolvedRange = resolvedContextRange(
                question: trimmed,
                scope: scope,
                currentTime: currentTime,
                contextRange: contextRange
            )
            try await prepareContext(range: resolvedRange)
            guard isAvailable, !Task.isCancelled else { return }
            sendStatusText = "Thinking"
            let answer = try await librarianService.answer(
                question: trimmed,
                book: book,
                scope: scope,
                currentTime: currentTime,
                contextRange: resolvedRange,
                history: history
            )
            guard isAvailable, !Task.isCancelled else { return }
            messages.append(LibrarianMessage(role: .assistant, text: answer, scope: scope))
            conversationStore.saveMessages(messages, bookStableId: book.stableId)
        } catch {

            alertMessage = error.localizedDescription
        }
    }

    func sendCatchUp(currentTime: TimeInterval) async {
        guard isAvailable else { return }
        let range = contextRetriever.catchUpRange(for: book, currentTime: currentTime)
        await send(
            question: "Catch me up.",
            scope: .previousChapter,
            currentTime: currentTime,
            contextRange: range
        )
    }

    private func resolvedContextRange(
        question: String,
        scope: BookIntelligenceScope,
        currentTime: TimeInterval,
        contextRange: ClosedRange<TimeInterval>?
    ) -> ClosedRange<TimeInterval>? {
        guard book.mediaType == .audiobook else { return contextRange }
        return contextRetriever.librarianRange(
            for: book,
            question: question,
            scope: scope,
            currentTime: currentTime,
            preferredRange: contextRange
        )
    }

    private func prepareContext(range: ClosedRange<TimeInterval>?) async throws {
        if book.mediaType == .ebook {
            try await ebookContextService.prepareContext(for: book)
            reloadEbookContext()
            return
        }

        guard book.mediaType == .audiobook else { return }
        reloadTranscript()
        guard let range, !librarianContextCovers(range: range) else { return }

        sendStatusText = "Listening to that passage"
        _ = try await transcriptionService.generateTranscript(
            for: book,
            startTime: range.lowerBound,
            endTime: range.upperBound
        )
        reloadTranscript()
    }

    private func librarianContextCovers(range: ClosedRange<TimeInterval>) -> Bool {
        let selected =
            transcriptSegments
            .filter { $0.endTime >= range.lowerBound && $0.startTime <= range.upperBound }
            .sorted { $0.startTime < $1.startTime }
        guard let first = selected.first, let last = selected.last else { return false }

        let tolerance: TimeInterval = 45
        return first.startTime <= range.lowerBound + tolerance
            && last.endTime >= range.upperBound - tolerance
    }
}
