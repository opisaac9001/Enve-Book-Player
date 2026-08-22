import SwiftUI

struct LibrarianChatScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var model: LibrarianChatModel
    @State private var selectedScope: BookIntelligenceScope = .previousChapter
    @State private var draftQuestion = ""
    @State private var ambient: Color = Hearth.accent

    private var transcriptionService: AudiobookTranscriptionService { .shared }
    private var ebookContextService: EbookContextService { .shared }

    init(book: Book, currentEbookProgress: Double? = nil) {
        _model = State(initialValue: LibrarianChatModel(book: book, initialEbookProgress: currentEbookProgress))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 14)
            statusPanel
            scopeRow
            quickPromptRow
            conversation
            composer
        }
        .background(hearth.bgElevated.ignoresSafeArea())
        .alert("The Librarian", isPresented: librarianAlertPresented) {
            Button("All right") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task(id: model.book.stableId) {
            ambient = await AmbientColorStore.shared.resolve(for: model.book)
        }
        .onAppear {
            model.reloadTranscript()
            model.reloadEbookContext()
        }
        .onChange(of: transcriptionService.progress(for: model.book.stableId)) {
            model.reloadTranscript()
        }
        .onChange(of: transcriptionService.isGenerating(bookStableId: model.book.stableId)) {
            model.reloadTranscript()
        }
        .onChange(of: ebookContextService.progress(for: model.book.stableId)) {
            model.reloadEbookContext()
        }
        .onChange(of: ebookContextService.isBuilding(bookStableId: model.book.stableId)) {
            model.reloadEbookContext()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverTile(book: model.book, width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Overline("The Librarian", color: ambient)
                Text(model.book.title)
                    .font(.hearthDisplay(17, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Clear the conversation", role: .destructive) {
                    model.clearConversation()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(hearth.bg)
                            .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
            }
            .accessibilityLabel("Conversation options")
            GlyphButton(systemImage: "xmark", label: "Close the Librarian") { dismiss() }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        if model.book.mediaType == .ebook {
            librarianEbookStatus
        } else if let availability = model.modelAvailabilityMessage {
            librarianNoticeCard(glyph: "exclamationmark.triangle", glyphColor: hearth.statusWarn, title: nil, text: availability)
        } else if transcriptionService.isGenerating(bookStableId: model.book.stableId) {
            librarianProgressCard(
                title: transcriptionService.statusText(for: model.book.stableId) ?? "Listening to that passage",
                progress: transcriptionService.progress(for: model.book.stableId)
            )
        }
    }

    @ViewBuilder
    private var librarianEbookStatus: some View {
        if ebookContextService.isBuilding(bookStableId: model.book.stableId) {
            librarianProgressCard(
                title: ebookContextService.statusText(for: model.book.stableId) ?? "Reading the book's text",
                progress: ebookContextService.progress(for: model.book.stableId)
            )
        } else if model.ebookChunks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                librarianNoticeText(
                    glyph: "books.vertical",
                    glyphColor: ambient,
                    title: model.ebookContextStatus == .failed ? "The text could not be read" : "The book's text is needed first",
                    text: "The Librarian reads a local copy of this book before answering."
                )
                QuietButton(title: "Prepare the book's text", systemImage: "text.book.closed") {
                    Task { await model.prepareEbookContextIfNeeded() }
                }
            }
            .padding(16)
            .background(librarianCardBackground)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        } else if let availability = model.modelAvailabilityMessage {
            librarianNoticeCard(glyph: "exclamationmark.triangle", glyphColor: hearth.statusWarn, title: nil, text: availability)
        }
    }

    private func librarianNoticeCard(glyph: String, glyphColor: Color, title: String?, text: String) -> some View {
        librarianNoticeText(glyph: glyph, glyphColor: glyphColor, title: title, text: text)
            .padding(16)
            .background(librarianCardBackground)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
    }

    private func librarianNoticeText(glyph: String, glyphColor: Color, title: String?, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph)
                .font(.hearthUI(15))
                .foregroundStyle(glyphColor)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.hearthUI(14, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
                Text(text)
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func librarianProgressCard(title: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
            ProgressView(value: progress)
                .tint(ambient)
        }
        .padding(16)
        .background(librarianCardBackground)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var librarianCardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(hearth.bg)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hearth.hairline, lineWidth: 1))
    }

    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(BookIntelligenceScope.allCases) { scope in
                        PlayerAudioChip(
                            title: scope.title(for: model.book.mediaType),
                            isSelected: selectedScope == scope,
                            tint: ambient
                        ) {
                            selectedScope = scope
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            Text("The Librarian reads only up to where you are.")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 10)
    }

    private var quickPromptRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                librarianQuickPrompt("Catch me up") {
                    await model.sendCatchUp(currentTime: currentContextPosition)
                }
                librarianQuickPrompt("Who was involved?") {
                    await model.send(question: "Who was involved?", scope: selectedScope, currentTime: currentContextPosition)
                }
                librarianQuickPrompt("Important details") {
                    await model.send(question: "Important details", scope: selectedScope, currentTime: currentContextPosition)
                }
                librarianQuickPrompt("Open threads") {
                    await model.send(question: "Open threads", scope: selectedScope, currentTime: currentContextPosition)
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    private func librarianQuickPrompt(_ text: String, action: @escaping () async -> Void) -> some View {
        Button {
            PlatformHaptics.selection()
            Task { await action() }
        } label: {
            Text(text)
                .font(.hearthUI(12, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(hearth.bg)
                        .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                }
        }
        .buttonStyle(PressableStyle())
        .disabled(!canAskQuestion)
        .opacity(canAskQuestion ? 1 : 0.4)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.messages.isEmpty {
                        librarianEmptyState
                            .padding(.top, 40)
                    }
                    ForEach(model.messages) { message in
                        LibrarianMessageRow(message: message, mediaType: model.book.mediaType, tint: ambient)
                            .id(message.id)
                    }
                    if model.isSending {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(ambient)
                            Text(model.sendStatusText ?? "Thinking")
                                .font(.hearthUI(12))
                                .foregroundStyle(hearth.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.messages.count) {
                guard let last = model.messages.last else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var librarianEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.hearthUI(26))
                .foregroundStyle(hearth.textTertiary)
            Text("Ask about the story so far.")
                .font(.hearthDisplay(19))
                .foregroundStyle(hearth.textSecondary)
            Text(librarianEmptyDescription)
                .font(.hearthUI(12))
                .foregroundStyle(hearth.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var librarianEmptyDescription: String {
        if model.book.mediaType == .ebook {
            return "Answers come from this book's local text, kept short of anywhere you haven't read."
        }
        return "Answers come from a small local transcript near your listening position, never from ahead of you."
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Ask the Librarian", text: $draftQuestion, axis: .vertical)
                    .font(.hearthUI(15))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(hearth.bg)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hearth.hairline, lineWidth: 1))
                    }
                Button {
                    let question = draftQuestion
                    draftQuestion = ""
                    Task {
                        await model.send(question: question, scope: selectedScope, currentTime: currentContextPosition)
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.hearthUI(30))
                        .foregroundStyle(canSend ? ambient : hearth.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend)
                .accessibilityLabel("Send question")
            }
            Text(
                BookIntelligenceSettingsStore.shared.activeBackend.keepsDataOnDevice
                    ? "The book's text and this conversation stay on this device."
                    : "Questions and book excerpts are sent to your own server."
            )
            .font(.hearthUI(11))
            .foregroundStyle(hearth.textTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var canSend: Bool {
        !draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canAskQuestion
    }

    private var canAskQuestion: Bool {
        !model.isSending && model.modelAvailabilityMessage == nil
    }

    private var currentContextPosition: TimeInterval {
        if model.book.mediaType == .ebook {
            return model.initialEbookProgress ?? model.book.canonicalEbookProgress
        }
        return ActivePlayback.controller.snapshot.position
    }

    private var librarianAlertPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}

private struct LibrarianMessageRow: View {
    let message: LibrarianMessage
    let mediaType: AppMediaType
    let tint: Color

    @Environment(\.hearth) private var hearth

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 5) {
                if let scope = message.scope, !isUser {
                    Overline(scope.title(for: mediaType))
                }
                Text(message.text)
                    .font(isUser ? .hearthUI(15) : .hearthDisplay(15, weight: .regular))
                    .foregroundStyle(isUser ? hearth.onEmber : hearth.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isUser ? tint : hearth.bg)
                    .overlay {
                        if !isUser {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                    }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }
}
