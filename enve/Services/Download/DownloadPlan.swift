import Foundation

enum DownloadDestinationStructure: Equatable {
    case audiobookDirectory
    case readerAsset
    case sourceAdjacentCopy
}

enum DownloadPostProcessing: Equatable {
    case validateEbook
    case persistReaderAsset
    case cacheOfflineAssets
}

struct DownloadPlanFile: Equatable {
    enum Source: Equatable {
        case providerSession
        case remoteAsset
        case localAsset
    }

    let source: Source
    let headers: [String: String]
    let relativePath: String?
}

@MainActor
struct DownloadPlan {
    let providerId: String
    let files: [DownloadPlanFile]
    let destination: DownloadDestinationStructure
    let postProcessing: [DownloadPostProcessing]
    private let executor: (UnifiedDownloadService, BookDownloadTask, Book) async throws -> Void

    init(
        providerId: String,
        files: [DownloadPlanFile],
        destination: DownloadDestinationStructure,
        postProcessing: [DownloadPostProcessing],
        executor: @escaping (UnifiedDownloadService, BookDownloadTask, Book) async throws -> Void
    ) {
        self.providerId = providerId
        self.files = files
        self.destination = destination
        self.postProcessing = postProcessing
        self.executor = executor
    }

    func execute(using service: UnifiedDownloadService, task: BookDownloadTask, book: Book) async throws {
        try await executor(service, task, book)
    }
}

@MainActor
protocol DownloadPlanProviding {
    var id: String { get }
    func makePlan(for book: Book) throws -> DownloadPlan
}

@MainActor
private struct SourceDownloadPlanProvider: DownloadPlanProviding {
    let id: String
    let plan: (Book) throws -> DownloadPlan

    func makePlan(for book: Book) throws -> DownloadPlan {
        try plan(book)
    }
}

@MainActor
final class DownloadPlanRegistry {
    static let shared = DownloadPlanRegistry()

    private var providers: [Book.BookSource: any DownloadPlanProviding] = [:]

    private init() {
        registerDefaults()
    }

    func register(_ provider: any DownloadPlanProviding, for source: Book.BookSource) {
        providers[source] = provider
    }

    func plan(for book: Book) throws -> DownloadPlan {
        guard let provider = providers[book.source] else {
            throw ProviderError.notImplemented
        }
        return try provider.makePlan(for: book)
    }

    private func registerDefaults() {
        register(PlexDownloadPlanProvider(), for: .plex)
        register(audioProvider(id: "audiobookshelf") { try await $0.downloadFromAudiobookshelf(task: $1, book: $2) }, for: .audiobookshelf)
        register(JellyfinDownloadPlanProvider(), for: .jellyfin)
        register(EmbyDownloadPlanProvider(), for: .emby)
        register(WebDAVDownloadPlanProvider(id: "webdav"), for: .webdav)
        register(WebDAVDownloadPlanProvider(id: "torbox"), for: .torbox)
        register(audioProvider(id: "realdebrid") { try await $0.downloadFromRealDebrid(task: $1, book: $2) }, for: .realdebrid)
        register(audioProvider(id: "smb", source: .localAsset) { try await $0.downloadFromSMB(task: $1, book: $2) }, for: .smb)
        register(audioProvider(id: "local", source: .localAsset) { try await $0.downloadFromLocalOrPodcast(task: $1, book: $2) }, for: .local)
        register(
            mediaAwareProvider(id: "booklore") { service, task, book in
                if book.mediaType == .ebook {
                    try await service.downloadEbookViaProvider(task: task, book: book)
                } else {
                    try await service.downloadAudiobookViaGrimmory(task: task, book: book)
                }
            },
            for: .booklore
        )
        for source in [Book.BookSource.komga, .kavita, .opds] {
            register(ebookOnlyProvider(id: source.rawValue), for: source)
        }
        register(
            mediaAwareProvider(id: "storyteller") { service, task, book in
                if book.mediaType == .ebook, !book.isStorytellerReadAloud {
                    try await service.downloadEbookViaProvider(task: task, book: book)
                } else {
                    try await service.downloadAudiobookFromStoryteller(task: task, book: book)
                }
            },
            for: .storyteller
        )
        for source in [Book.BookSource.bookOrbit, .silo] {
            register(
                mediaAwareProvider(id: source.rawValue) { service, task, book in
                    if book.mediaType == .ebook {
                        try await service.downloadEbookViaProvider(task: task, book: book)
                    } else {
                        try await service.downloadAudiobookViaProvider(task: task, book: book)
                    }
                },
                for: source
            )
        }
    }

    private func audioProvider(
        id: String,
        source: DownloadPlanFile.Source = .providerSession,
        execute: @escaping (UnifiedDownloadService, BookDownloadTask, Book) async throws -> Void
    ) -> any DownloadPlanProviding {
        SourceDownloadPlanProvider(id: id) { _ in
            DownloadPlan(
                providerId: id,
                files: [DownloadPlanFile(source: source, headers: [:], relativePath: nil)],
                destination: .audiobookDirectory,
                postProcessing: [.cacheOfflineAssets],
                executor: execute
            )
        }
    }

    private func mediaAwareProvider(
        id: String,
        execute: @escaping (UnifiedDownloadService, BookDownloadTask, Book) async throws -> Void
    ) -> any DownloadPlanProviding {
        SourceDownloadPlanProvider(id: id) { book in
            DownloadPlan(
                providerId: id,
                files: [DownloadPlanFile(source: .providerSession, headers: [:], relativePath: nil)],
                destination: book.mediaType == .ebook ? .readerAsset : .audiobookDirectory,
                postProcessing: book.mediaType == .ebook
                    ? [.validateEbook, .persistReaderAsset, .cacheOfflineAssets]
                    : [.cacheOfflineAssets],
                executor: execute
            )
        }
    }

    private func ebookOnlyProvider(id: String) -> any DownloadPlanProviding {
        SourceDownloadPlanProvider(id: id) { book in
            guard book.mediaType == .ebook else {
                throw ProviderError.notImplemented
            }
            return DownloadPlan(
                providerId: id,
                files: [DownloadPlanFile(source: .providerSession, headers: [:], relativePath: nil)],
                destination: .readerAsset,
                postProcessing: [.validateEbook, .persistReaderAsset, .cacheOfflineAssets]
            ) { service, task, book in
                try await service.downloadEbookViaProvider(task: task, book: book)
            }
        }
    }
}
