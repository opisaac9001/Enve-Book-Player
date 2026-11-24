#if os(iOS)
import AppIntents

struct EnveEbookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ebook"
    static let defaultQuery = EnveEbookQuery()

    let id: String
    let title: String
    let author: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" }, image: .init(systemName: "book"))
    }

    init(_ book: SystemEbook) {
        id = book.id
        title = book.title
        author = book.author
    }
}

struct EnveEbookQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EnveEbookEntity] {
        await EbookSystemService.permittedSession?.ebookSystem.entities(for: identifiers).map(EnveEbookEntity.init) ?? []
    }

    func entities(matching string: String) async throws -> [EnveEbookEntity] {
        await EbookSystemService.permittedSession?.ebookSystem.search(string).map(EnveEbookEntity.init) ?? []
    }

    func suggestedEntities() async throws -> [EnveEbookEntity] {
        await EbookSystemService.permittedSession?.ebookSystem.suggestions().map(EnveEbookEntity.init) ?? []
    }
}

struct OpenEbookIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Ebook"
    static let description = IntentDescription("Opens an ebook from your Enve library at its saved reading position.")
    static let openAppWhenRun = true

    @Parameter(title: "Ebook") var target: EnveEbookEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let session = EbookSystemService.permittedSession else { throw EbookSystemError.unavailable }
        try await session.ebookSystem.requestOpen(target.id)
        return .result()
    }
}

struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription("Opens your last ebook in Enve at its saved reading position.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let session = EbookSystemService.permittedSession else { throw EbookSystemError.unavailable }
        try await session.ebookSystem.requestContinue()
        return .result()
    }
}
#endif
