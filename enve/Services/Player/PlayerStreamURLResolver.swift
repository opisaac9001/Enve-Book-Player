import Foundation
import Logging

@MainActor
final class PlayerStreamURLResolver {
    static let shared = PlayerStreamURLResolver(
        providerConnections: AppState.shared.providerConnections
    )

    private let plexService: PlexService
    private let audiobookshelfService: AudiobookshelfService
    private let providerConnections: any ProviderConnectionAccessing
    private let sessionService: PlayerSessionService
    private let progressService: PlayerProgressService

    private var currentSecurityScopedURL: URL?

    init(
        plexService: PlexService = PlexService(),
        audiobookshelfService: AudiobookshelfService = AudiobookshelfService(),
        providerConnections: any ProviderConnectionAccessing,
        sessionService: PlayerSessionService = .shared,
        progressService: PlayerProgressService = .shared
    ) {
        self.plexService = plexService
        self.audiobookshelfService = audiobookshelfService
        self.providerConnections = providerConnections
        self.sessionService = sessionService
        self.progressService = progressService
    }

    private func diagnosticBookID(_ book: Book) -> String {
        DiagnosticLogSanitizer.identifier(for: book.stableId)
    }

    func cleanupSecurityScopedAccess() {
        if let url = currentSecurityScopedURL {
            url.stopAccessingSecurityScopedResource()
            AppLogger.player.info("Stopped accessing security-scoped resource")
            currentSecurityScopedURL = nil
        }
    }

    func streamURL(for book: Book, backendOverride: BackendConfig? = nil) async throws -> URL? {
        let downloadKey = book.downloadKey
        AppLogger.player.debug(
            "Checking downloaded file bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: downloadKey))"
        )

        if let local = LocalStorageManager.shared.localAudiobookFileURLIfExists(bookId: downloadKey) {
            AppLogger.player.debug(
                "Found local download: \(DiagnosticLogSanitizer.fileDescriptor(for: local))"
            )
            if await validateLocalFile(url: local) {
                AppLogger.player.debug(
                    "Using downloaded file for playback: \(DiagnosticLogSanitizer.fileDescriptor(for: local))"
                )
                return local
            } else {
                AppLogger.player.error(
                    "Downloaded file validation failed: \(DiagnosticLogSanitizer.fileDescriptor(for: local))"
                )
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: local.path) && fileManager.isReadableFile(atPath: local.path) {
                    AppLogger.player.debug(
                        "File exists and is readable: \(DiagnosticLogSanitizer.fileDescriptor(for: local))"
                    )
                    return local
                }
            }
        } else {
            AppLogger.player.debug(
                "No downloaded file bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: downloadKey))"
            )

            if let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book),
                let firstLocal = localFiles.first
            {
                AppLogger.player.debug(
                    "Found local download via candidate lookup: \(DiagnosticLogSanitizer.fileDescriptor(for: firstLocal))"
                )
                if await validateLocalFile(url: firstLocal) {
                    AppLogger.player.debug(
                        "Using local file discovered via fallback lookup: \(DiagnosticLogSanitizer.fileDescriptor(for: firstLocal))"
                    )
                    return firstLocal
                }
            }
        }

        if let url = try await trySource(book: book, backendOverride: backendOverride) {
            return url
        }

        throw NSError(
            domain: "PlayerStreamURLResolver",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "All available sources failed to load"]
        )
    }

    private func trySource(book: Book, backendOverride: BackendConfig? = nil) async throws -> URL? {
        do {
            if book.source == .local, let filePath = book.filePath {
                let fileURL = URL(fileURLWithPath: filePath)
                if await validateLocalFile(url: fileURL) {
                    AppLogger.player.debug("Using local library file \(DiagnosticLogSanitizer.fileDescriptor(for: fileURL))")
                    return fileURL
                } else {
                    AppLogger.player.error("Local library file validation failed \(DiagnosticLogSanitizer.fileDescriptor(for: fileURL))")

                    if let libraryId = book.backendId,
                        let foundURL = await findLocalBookFile(bookId: book.id, libraryId: libraryId, originalPath: filePath)
                    {
                        AppLogger.player.debug(
                            "Found file at alternate location: \(DiagnosticLogSanitizer.fileDescriptor(for: foundURL))"
                        )
                        return foundURL
                    }

                    return nil
                }
            }

            return try await remoteStreamURL(for: book, backendOverride: backendOverride)
        } catch {
            AppLogger.player.error("Source \(book.source.rawValue) failed: \(error.localizedDescription)")
            return nil
        }
    }

    func remoteStreamURL(for book: Book, backendOverride: BackendConfig? = nil) async throws -> URL? {
        var effectiveSource = book.source
        let shouldResolveBackendSource =
            book.source == .audiobookshelf
            || book.source == .jellyfin
            || book.source == .emby
            || book.source == .plex

        if shouldResolveBackendSource,
            let backendId = book.backendId,
            let foundBackend = providerConnections.backend(id: backendId)
        {
            let backendSource: Book.BookSource
            switch foundBackend.type {
            case .audiobookshelf:
                backendSource = .audiobookshelf
            case .jellyfin:
                backendSource = .jellyfin
            case .emby:
                backendSource = .emby
            case .plex:
                backendSource = .plex
            case .storyteller:
                backendSource = .storyteller
            }

            if backendSource != book.source {
                AppLogger.player.info(
                    "Source mismatch detected: book.source=\(book.source.rawValue), backend.type=\(foundBackend.type.rawValue)"
                )
                AppLogger.player.info("Using backend type (\(backendSource.rawValue)) instead of stored source")
                effectiveSource = backendSource
            }
        } else if shouldResolveBackendSource, let backendId = book.backendId {
            AppLogger.player.info(
                "Could not find backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: backendId))"
            )
            let allBackends = providerConnections.allBackends()
            AppLogger.player.info("Available backends (\(allBackends.count)):")
            for backend in allBackends {
                AppLogger.player.debug(
                    "Available backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: backend.id)) type=\(backend.type.rawValue) enabled=\(backend.enabled)"
                )
            }
        }

        switch effectiveSource {
        case .plex:
            AppLogger.player.info("Plex playback - checking for backend connection")
            AppLogger.player.debug("Plex playback hasBackendID=\(book.backendId != nil)")

            var backendId = book.backendId

            if backendId == nil {
                AppLogger.player.info("No backendId on book, searching for enabled Plex backend...")
                let allBackends = providerConnections.allBackends()
                if let plexBackend = allBackends.first(where: { $0.type == .plex && $0.enabled }) {
                    AppLogger.player.debug(
                        "Found Plex backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: plexBackend.id))"
                    )
                    backendId = plexBackend.id
                } else {
                    AppLogger.player.info("No enabled Plex backends found")
                }
            }

            if let backendId = backendId {
                if let backend = providerConnections.backend(id: backendId) {
                    AppLogger.player.debug(
                        "Found backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: backend.id)) type=\(backend.type)"
                    )

                    if backend.type == .plex {
                        if let token = backend.token, !token.isEmpty {
                            AppLogger.player.debug(
                                "Using Plex backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: backend.id))"
                            )

                            let workingServerUrl = backend.url
                            AppLogger.player.info(
                                "Using backend URL: \(URL(string: workingServerUrl)?.redacted.absoluteString ?? "<invalid>")"
                            )

                            var partKey = book.partKey
                            if partKey == nil || partKey?.isEmpty == true {
                                AppLogger.player.warning("Part key missing, attempting to fetch from metadata...")
                                partKey = try await getPartKeyFromMetadata(
                                    serverUrl: workingServerUrl,
                                    token: token,
                                    ratingKey: book.ratingKey
                                )
                            }

                            guard let finalPartKey = partKey, !finalPartKey.isEmpty else {
                                throw NSError(
                                    domain: "PlayerStreamURLResolver",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Could not determine media part key for playback"]
                                )
                            }

                            AppLogger.player.debug(
                                "Using media part diagnosticID=\(DiagnosticLogSanitizer.identifier(for: finalPartKey))"
                            )

                            return plexService.getStreamUrl(
                                serverUrl: workingServerUrl,
                                partKey: finalPartKey,
                                token: token,
                                ratingKey: book.ratingKey
                            )
                        } else {
                            AppLogger.player.warning("Plex backend found but token is missing or empty")
                            throw NSError(
                                domain: "PlayerStreamURLResolver",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Plex backend token is missing. Please re-authenticate in settings."]
                            )
                        }
                    } else {
                        AppLogger.player.info("Backend found but type mismatch: expected plex, got \(backend.type)")
                    }
                } else {
                    AppLogger.player.warning(
                        "Backend not found diagnosticID=\(DiagnosticLogSanitizer.identifier(for: backendId))"
                    )
                    let allBackends = providerConnections.allBackends()
                    AppLogger.player.info("Available backends (\(allBackends.count)):")
                    for b in allBackends {
                        AppLogger.player.debug(
                            "Available backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: b.id)) type=\(b.type)"
                        )
                    }
                }
            } else {
                AppLogger.player.info("Could not determine backendId, will try legacy Plex authentication")
            }

            AppLogger.player.info("Falling back to legacy Plex authentication")
            guard let discoveryToken = PlexAuthStore.shared.loadToken() else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing Plex authentication token. Please connect a Plex server in settings."]
                )
            }

            guard let requestToken = PlexAuthStore.shared.tokenForServerRequests() else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing Plex server access token"]
                )
            }

            guard let workingServerUrl = await getWorkingServerUrl(token: discoveryToken) else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not determine working Plex server URL"]
                )
            }

            var partKey = book.partKey
            if partKey == nil || partKey?.isEmpty == true {
                AppLogger.player.warning("Part key missing, attempting to fetch from metadata...")
                partKey = try await getPartKeyFromMetadata(
                    serverUrl: workingServerUrl,
                    token: requestToken,
                    ratingKey: book.ratingKey
                )
            }

            guard let finalPartKey = partKey, !finalPartKey.isEmpty else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not determine media part key for playback"]
                )
            }

            AppLogger.player.debug(
                "Using media part diagnosticID=\(DiagnosticLogSanitizer.identifier(for: finalPartKey))"
            )

            return plexService.getStreamUrl(
                serverUrl: workingServerUrl,
                partKey: finalPartKey,
                token: requestToken,
                ratingKey: book.ratingKey
            )

        case .audiobookshelf:
            let backend: BackendConfig
            if let override = backendOverride {
                backend = override
            } else {
                AppLogger.player.info("Looking up backend for audiobookshelf book:")
                AppLogger.player.debug("Audiobookshelf playback hasBackendID=\(book.backendId != nil)")
                AppLogger.player.debug(
                    "providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.providerId.uuidString))"
                )
                AppLogger.player.info("Available connections: \(providerConnections.connections.count)")
                for conn in providerConnections.connections {
                    AppLogger.player.debug(
                        "Available connection diagnosticID=\(DiagnosticLogSanitizer.identifier(for: conn.id.uuidString)) type=\(conn.type)"
                    )
                }

                let lookupId = book.backendId ?? book.providerId.uuidString

                guard let foundBackend = providerConnections.backend(id: lookupId) else {
                    AppLogger.player.warning("Backend not found by ID, trying fallback lookup...")
                    let allBackends = providerConnections.allBackends()
                    AppLogger.player.info("All backends (\(allBackends.count)):")
                    for b in allBackends {
                        AppLogger.player.debug(
                            "Available backend diagnosticID=\(DiagnosticLogSanitizer.identifier(for: b.id)) type=\(b.type.rawValue)"
                        )
                    }

                    if let embyBackend = allBackends.first(where: { $0.type == .emby && $0.enabled }) {
                        AppLogger.player.warning(
                            "Found Emby fallback diagnosticID=\(DiagnosticLogSanitizer.identifier(for: embyBackend.id))"
                        )
                        guard let token = embyBackend.token, !token.isEmpty else {
                            throw NSError(
                                domain: "PlayerStreamURLResolver",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Missing Emby authentication token"]
                            )
                        }
                        let itemId = extractItemId(from: book.ratingKey)
                        let streamUrl = try buildEmbyJellyfinStreamURL(
                            baseUrl: embyBackend.url,
                            itemId: itemId,
                            token: token,
                            typeName: "Emby"
                        )
                        AppLogger.player.warning("Built fallback Emby stream URL: \(streamUrl.redacted)")
                        return streamUrl
                    }

                    if let jellyfinBackend = allBackends.first(where: { $0.type == .jellyfin && $0.enabled }) {
                        AppLogger.player.warning("Found Jellyfin backend fallback")
                        guard let token = jellyfinBackend.token, !token.isEmpty else {
                            throw NSError(
                                domain: "PlayerStreamURLResolver",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Missing Jellyfin authentication token"]
                            )
                        }
                        let itemId = extractItemId(from: book.ratingKey)
                        let streamUrl = try buildEmbyJellyfinStreamURL(
                            baseUrl: jellyfinBackend.url,
                            itemId: itemId,
                            token: token,
                            typeName: "Jellyfin"
                        )
                        AppLogger.player.warning("Built fallback Jellyfin stream URL: \(streamUrl.redacted)")
                        return streamUrl
                    }

                    throw NSError(
                        domain: "PlayerStreamURLResolver",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing Audiobookshelf backend configuration"]
                    )
                }
                backend = foundBackend
            }

            if backend.type == .emby || backend.type == .jellyfin {
                AppLogger.player.info("Correcting: Book has source=.audiobookshelf but backend.type=\(backend.type.rawValue)")
                AppLogger.player.info("Using Emby/Jellyfin streaming URL instead of Audiobookshelf API")

                guard let token = backend.token, !token.isEmpty else {
                    throw NSError(
                        domain: "PlayerStreamURLResolver",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing \(backend.type.rawValue) authentication token"]
                    )
                }

                let itemId = extractItemId(from: book.ratingKey)
                let streamUrl = try buildEmbyJellyfinStreamURL(
                    baseUrl: backend.url,
                    itemId: itemId,
                    token: token,
                    typeName: backend.type.rawValue
                )
                AppLogger.player.info("Built corrected \(backend.type.rawValue) stream URL: \(streamUrl.redacted)")
                return streamUrl
            }

            let libraryItemId = book.partKey ?? book.id
            let trackIndex = book.trackIndex ?? 0

            let playSession = try await sessionService.startABSSession(for: book, startTime: 0)
            progressService.absSessionActive = true

            guard let tracks = playSession.audioTracks, tracks.indices.contains(trackIndex) else {
                AppLogger.player.info("[ABS Session] No audio tracks in session, falling back to direct stream")
                let fallback = try await audiobookshelfService.getStreamUrl(
                    libraryItemId: libraryItemId,
                    trackIndex: trackIndex,
                    backend: backend
                )
                return fallback.map { Self.absStreamURLWithToken($0, backend: backend) }
            }

            let track = tracks[trackIndex]
            guard let contentUrl = track.contentUrl else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No content URL in audio track"]
                )
            }

            let streamURL: URL?
            if contentUrl.hasPrefix("http") {
                streamURL = URL(string: contentUrl)
            } else {
                guard let baseURL = backend.baseURL else { return nil }
                let cleanBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let cleanPath = contentUrl.hasPrefix("/") ? contentUrl : "/\(contentUrl)"
                streamURL = URL(string: "\(cleanBase)\(cleanPath)")
            }
            return streamURL.map { Self.absStreamURLWithToken($0, backend: backend) }
        case .jellyfin, .emby:
            let targetType: BackendConfig.BackendType = (book.source == .jellyfin) ? .jellyfin : .emby

            var backend: BackendConfig?
            if let backendId = book.backendId {
                backend = providerConnections.backend(id: backendId)
            }

            if backend == nil {
                let allBackends = providerConnections.allBackends()
                backend = allBackends.first(where: { $0.type == targetType && $0.enabled })

                if let foundBackend = backend {
                    AppLogger.player.warning(
                        "Backend lookup by ID failed; using \(targetType.rawValue) backendDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: foundBackend.id))"
                    )
                } else {
                    AppLogger.player.info("No enabled \(targetType.rawValue) backend found in \(allBackends.count) total backends")
                }
            }

            guard let finalBackend = backend else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No enabled \(book.source == .jellyfin ? "Jellyfin" : "Emby") backend configured"]
                )
            }

            AppLogger.player.debug(
                "Resolving \(targetType.rawValue) stream backendDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: finalBackend.id))"
            )
            AppLogger.player.debug("bookDiagnosticID=\(diagnosticBookID(book))")
            AppLogger.player.debug(
                "Plex book ratingDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.ratingKey)) hasPartKey=\(book.partKey != nil)"
            )

            let itemId = extractItemId(from: book.ratingKey)
            AppLogger.player.debug(
                "Using itemDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: itemId)) trackIndex=\(book.trackIndex ?? 0)"
            )

            guard let token = finalBackend.token, !token.isEmpty else {
                throw NSError(
                    domain: "PlayerStreamURLResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing \(targetType.rawValue) authentication token"]
                )
            }

            let streamUrl = try buildEmbyJellyfinStreamURL(
                baseUrl: finalBackend.url,
                itemId: itemId,
                token: token,
                typeName: targetType.rawValue
            )
            AppLogger.player.info("Built \(targetType.rawValue) stream URL: \(streamUrl.redacted)")
            return streamUrl
        case .webdav, .torbox, .realdebrid:
            if let provider = providerConnections.capability(PlaybackSessionProvider.self, for: book) {
                return provider.getAudioURL(for: book)
            }
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "WebDAV provider not available"]
            )
        case .local:
            if let filePath = book.filePath ?? book.partKey {
                if let libraryId = book.backendId {
                    if let bookmarkData = LocalLibraryStorageStore.shared.loadBookmark(for: libraryId) {
                        var isStale = false
                        do {
                            #if os(macOS)
                            let url = try URL(
                                resolvingBookmarkData: bookmarkData,
                                options: .withSecurityScope,
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

                            try Task.checkCancellation()
                            guard url.startAccessingSecurityScopedResource() else {
                                AppLogger.player.error(
                                    "Failed to access security-scoped library diagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId))"
                                )
                                throw NSError(
                                    domain: "PlayerStreamURLResolver",
                                    code: -50,
                                    userInfo: [NSLocalizedDescriptionKey: "Permission denied accessing local library"]
                                )
                            }

                            AppLogger.player.debug(
                                "Accessed security-scoped library diagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId))"
                            )

                            if let previousURL = currentSecurityScopedURL {
                                previousURL.stopAccessingSecurityScopedResource()
                                AppLogger.player.info("Stopped accessing previous security-scoped resource")
                            }
                            currentSecurityScopedURL = url

                            if let localBook = LocalLibraryStorageStore.shared.loadBooks(libraryId: libraryId).first(where: {
                                $0.id == book.id
                            }),
                                let relative = localBook.relativePath,
                                !relative.isEmpty
                            {
                                return urlByAppendingRelativePath(relative, to: url)
                            }

                            if filePath.hasPrefix(url.path) {
                                return URL(fileURLWithPath: filePath)
                            }

                            return url.appendingPathComponent((filePath as NSString).lastPathComponent)
                        } catch {
                            AppLogger.player.error(
                                "Failed to resolve library bookmark diagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId)): \(error)"
                            )
                            throw NSError(
                                domain: "PlayerStreamURLResolver",
                                code: -50,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to access local library folder"]
                            )
                        }
                    } else {
                        AppLogger.player.debug(
                            "No security bookmark for library diagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId))"
                        )
                    }
                }

                return URL(fileURLWithPath: filePath)
            }
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No file path for local book"]
            )
        case .smb:
            if let local = LocalStorageManager.shared.localAudiobookFileURLIfExists(bookId: book.downloadKey) {
                AppLogger.player.debug(
                    "Playing from local download: \(DiagnosticLogSanitizer.fileDescriptor(for: local))"
                )
                return local
            }

            AppLogger.player.info("Streaming mode - no local download, will stream from server")
            return try await streamFromSMB(book: book)

        case .booklore, .bookOrbit, .silo:
            if let provider = providerConnections.capability(PlaybackSessionProvider.self, for: book) {
                return provider.getAudioURL(for: book)
            }
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Provider not available"]
            )
        case .komga, .kavita, .opds:
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Ebook-only source does not support audio streaming"]
            )
        case .storyteller:
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Storyteller books must be downloaded before playback. Tap the download button to save this book for offline listening."
                ]
            )
        }
    }

    private func streamFromSMB(book: Book) async throws -> URL {
        guard let sourceId = book.backendId else {
            throw NSError(domain: "PlayerStreamURLResolver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SMB source id"])
        }

        let smbBooks = await SMBLibraryService.shared.getBooks(for: sourceId)
        guard let smbBook = smbBooks.first(where: { $0.id == book.id }),
            !smbBook.audioFiles.isEmpty
        else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SMB book or audio file not found"]
            )
        }

        AppLogger.player.info(
            "[SMB Stream] Starting playback for \(smbBook.audioFiles.count) file(s) firstFileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: smbBook.audioFiles.first?.name ?? "unknown"))"
        )

        guard let streamURLs = try await SMBStreamingServer.shared.startStreamingAllFiles(book: book),
            let firstURL = streamURLs.first
        else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start SMB streaming"]
            )
        }

        AppLogger.player.debug("[SMB Stream] Ready for playback streamCount=\(streamURLs.count)")
        return firstURL
    }

    private func urlByAppendingRelativePath(_ relativePath: String, to baseURL: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(baseURL) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }

    private func findLocalBookFile(bookId: String, libraryId: String, originalPath: String) async -> URL? {
        let fileManager = FileManager.default

        if libraryId == LocalLibraryService.fileSharingLibraryId {
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            let audiobooksFolder = documentsURL?.appendingPathComponent("Individual_Audiobooks", isDirectory: true)

            if let folder = audiobooksFolder {
                let audioExtensions = ["m4b", "m4a", "mp3", "mp4", "aac", "flac", "wav", "opus"]

                if let contents = try? fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for fileURL in contents {
                        let ext = fileURL.pathExtension.lowercased()
                        if audioExtensions.contains(ext) {
                            if fileManager.isReadableFile(atPath: fileURL.path) {
                                let originalFileName = (originalPath as NSString).lastPathComponent
                                let originalBaseName =
                                    (originalFileName as NSString).deletingPathExtension
                                    .components(separatedBy: "_").first ?? originalFileName

                                if contents.filter({ audioExtensions.contains($0.pathExtension.lowercased()) }).count == 1 {
                                    return fileURL
                                }

                                let currentBaseName = fileURL.deletingPathExtension().lastPathComponent
                                if currentBaseName.contains(originalBaseName) || originalBaseName.contains(currentBaseName) {
                                    return fileURL
                                }
                            }
                        }
                    }

                    for fileURL in contents {
                        let ext = fileURL.pathExtension.lowercased()
                        if audioExtensions.contains(ext) && fileManager.isReadableFile(atPath: fileURL.path) {
                            return fileURL
                        }
                    }
                }
            }
        }

        return nil
    }

    private func validateLocalFile(url: URL) async -> Bool {
        guard url.isFileURL else { return false }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            AppLogger.player.debug(
                "Local file does not exist: \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
            )
            return false
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let fileSize = attributes[.size] as? Int64
        {
            if fileSize < 1024 {
                AppLogger.player.warning(
                    "Local file is too small (\(fileSize) bytes): \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
                )
                return false
            }
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            AppLogger.player.warning(
                "Local file is not readable: \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
            )
            return false
        }

        return true
    }

    private func getWorkingServerUrl(token: String) async -> String? {
        do {
            let servers = try await plexService.getPlexServers(token: token)
            guard let server = servers.first else { return nil }
            return await plexService.findBestConnection(server: server)
        } catch {
            AppLogger.player.error("Failed to get working server URL: \(error)")
            return nil
        }
    }

    private func extractItemId(from ratingKey: String) -> String {
        let parts = ratingKey.split(separator: ":")
        if parts.count == 3 {
            return String(parts[2])
        }
        return ratingKey
    }

    private func buildEmbyJellyfinStreamURL(baseUrl: String, itemId: String, token: String, typeName: String) throws -> URL {
        let normalizedBase = EmbyProvider.normalizeServerURL(baseUrl)
        guard var components = URLComponents(string: "\(normalizedBase)/Audio/\(itemId)/stream") else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build \(typeName) stream URL"]
            )
        }
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
        ]
        guard let streamUrl = components.url else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct \(typeName) stream URL"]
            )
        }
        return streamUrl
    }

    private static func absStreamURLWithToken(_ url: URL, backend: BackendConfig) -> URL {
        guard let token = backend.token, !token.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "token" }) else { return url }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    private func getPartKeyFromMetadata(serverUrl: String, token: String, ratingKey: String) async throws -> String? {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/metadata/\(ratingKey)", relativeTo: baseURL)
        else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL for metadata request"]
            )
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch book metadata"]
            )
        }

        let parser = XMLParser(data: data)
        let delegate = PlexPartKeyParser()
        parser.delegate = delegate

        guard parser.parse() else {
            throw NSError(
                domain: "PlayerStreamURLResolver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse metadata XML"]
            )
        }

        return delegate.partKey
    }
}

private class PlexPartKeyParser: NSObject, XMLParserDelegate {
    var partKey: String?
    var currentElement: String = ""
    var inPart = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        if elementName == "Part" {
            inPart = true
            if let key = attributeDict["key"], !key.isEmpty {
                partKey = key
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Part" {
            inPart = false
        }
        currentElement = ""
    }
}
