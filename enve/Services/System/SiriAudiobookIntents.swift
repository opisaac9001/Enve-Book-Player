#if os(iOS)
import AppIntents

struct EnveAudiobookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Downloaded Audiobook"
    static let defaultQuery = EnveAudiobookQuery()

    let id: String
    let title: String
    let author: String?
    let narrator: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: (author ?? narrator).map { "\($0)" },
            image: .init(systemName: "book.closed.fill")
        )
    }

    init(_ descriptor: SiriAudiobookDescriptor) {
        id = descriptor.id
        title = descriptor.title
        author = descriptor.author
        narrator = descriptor.narrator
    }
}

struct EnveAudiobookQuery: EntityStringQuery {
    func entities(for identifiers: [EnveAudiobookEntity.ID]) async throws -> [EnveAudiobookEntity] {
        await SiriAudiobookService.downloadedAudiobooks(with: identifiers).map(EnveAudiobookEntity.init)
    }

    func entities(matching string: String) async throws -> [EnveAudiobookEntity] {
        await SiriAudiobookService.downloadedAudiobooks(matching: string).map(EnveAudiobookEntity.init)
    }

    func suggestedEntities() async throws -> [EnveAudiobookEntity] {
        await SiriAudiobookService.downloadedAudiobooks().map(EnveAudiobookEntity.init)
    }
}

struct PlayDownloadedAudiobookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Downloaded Audiobook"
    static let description = IntentDescription("Plays a downloaded audiobook in Enve.")
    static let openAppWhenRun = false

    @Parameter(title: "Audiobook")
    var audiobook: EnveAudiobookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$audiobook)")
    }

    init() {}

    func perform() async throws -> some IntentResult {
        try await SiriAudiobookService.playDownloadedAudiobook(identifier: audiobook.id)
        return .result()
    }
}

struct ResumeAudiobookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Audiobook"
    static let description = IntentDescription("Resumes the current audiobook in Enve.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await SiriAudiobookService.resumeCurrentAudiobook()
        return .result()
    }
}

struct EnveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayDownloadedAudiobookIntent(),
            phrases: [
                "Play \(\.$audiobook) with \(.applicationName)",
                "Play \(\.$audiobook) in \(.applicationName)",
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: ResumeAudiobookIntent(),
            phrases: [
                "Resume my audiobook with \(.applicationName)",
                "Continue my book with \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume Audiobook",
            systemImageName: "play.circle.fill"
        )
    }
}
#endif
