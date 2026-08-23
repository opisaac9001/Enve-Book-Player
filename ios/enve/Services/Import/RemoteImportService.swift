import Combine
import Foundation
import Logging
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class RemoteImportService: NSObject, ObservableObject {
    static let shared = RemoteImportService()

    enum FilesAudioSelectionMode {
        case groupByFolder
        case splitSelectedBooks
    }

    @Published private(set) var currentBatch: ImportBatch?
    @Published private(set) var isImporting: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var webDAVServers: [WebDAVServerConfig] = []

    private let fileManager = FileManager.default
    private let storage = LocalStorageManager.shared
    private var cancellables = Set<AnyCancellable>()

    private var stagingDirectory: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupportURL.appendingPathComponent("Enve/ImportStaging", isDirectory: true)
    }

    private var canonicalLibraryRoot: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("Individual_Audiobooks", isDirectory: true)
    }

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.enve.import")
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 7200
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var downloadCompletionHandlers: [Int: (URL?, Error?) -> Void] = [:]
    private var activeDownloadTasks: [Int: ImportProgress] = [:]

    private override init() {
        super.init()
        createDirectoriesIfNeeded()
        loadWebDAVServers()
    }

    private func createDirectoriesIfNeeded() {
        let directories = [stagingDirectory, canonicalLibraryRoot]
        for directory in directories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func saveWebDAVServer(_ server: WebDAVServerConfig) {
        if let index = webDAVServers.firstIndex(where: { $0.id == server.id }) {
            webDAVServers[index] = server
        } else {
            webDAVServers.append(server)
        }
        persistWebDAVServers()
    }

    func removeWebDAVServer(id: String) {
        webDAVServers.removeAll { $0.id == id }
        persistWebDAVServers()
    }

    private func loadWebDAVServers() {
        let url = serversConfigURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            webDAVServers = try JSONDecoder().decode([WebDAVServerConfig].self, from: data)
        } catch {
            AppLogger.network.error("Failed to load WebDAV servers: \(error)")
        }
    }

    private func persistWebDAVServers() {
        do {
            let data = try JSONEncoder().encode(webDAVServers)
            try data.write(to: serversConfigURL, options: .atomic)
        } catch {
            AppLogger.network.error("Failed to save WebDAV servers: \(error)")
        }
    }

    private var serversConfigURL: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupportURL.appendingPathComponent("Enve/webdav_servers.json")
    }

    func listWebDAVDirectory(server: WebDAVServerConfig, path: String) async throws -> [RemoteFileEntry] {
        let normalizedBasePath = normalizedWebDAVPath(path, server: server)

        let directoryPath = normalizedBasePath.hasSuffix("/") ? normalizedBasePath : normalizedBasePath + "/"

        let url = server.url(for: directoryPath)
        AppLogger.network.info("PROPFIND -> \(url.redacted)")
        guard let scheme = url.scheme, scheme == "https" || scheme == "http" else {
            AppLogger.network.error("Invalid URL scheme")
            throw ImportError.unsupportedURL
        }
        guard let host = url.host, !host.isEmpty else {
            AppLogger.network.info("URL has no host")
            throw ImportError.unsupportedURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let username = server.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = (server.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let session: URLSession
        var challengeDelegate: WebDAVAuthDelegate?

        if !username.isEmpty {
            AppLogger.network.info("Auth: user=<redacted>, pass=<redacted> (challenge-based)")
            challengeDelegate = WebDAVAuthDelegate(username: username, password: password)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            session = URLSession(configuration: config, delegate: challengeDelegate, delegateQueue: nil)
        } else {
            AppLogger.network.info("No auth credentials set")
            session = URLSession.shared
        }

        let propfindXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <D:propfind xmlns:D="DAV:">
                <D:prop>
                    <D:displayname/>
                    <D:getcontentlength/>
                    <D:getlastmodified/>
                    <D:getcontenttype/>
                    <D:resourcetype/>
                </D:prop>
            </D:propfind>
            """
        request.httpBody = propfindXML.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLogger.network.error("Network error: \(error.localizedDescription)")
            if challengeDelegate != nil { session.finishTasksAndInvalidate() }
            if challengeDelegate != nil {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw ImportError.authenticationFailed
                }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    throw ImportError.authenticationFailed
                }
            }
            if let urlError = error as? URLError,
                urlError.code == .secureConnectionFailed || urlError.code == .serverCertificateUntrusted
                    || urlError.code == .serverCertificateHasBadDate || urlError.code == .serverCertificateNotYetValid
                    || urlError.code == .cannotLoadFromNetwork
            {
                throw ImportError.tlsTrustFailed
            }
            throw error
        }

        if challengeDelegate != nil { session.finishTasksAndInvalidate() }

        guard let httpResponse = response as? HTTPURLResponse else {
            AppLogger.network.info("Non-HTTP response")
            throw ImportError.invalidResponse
        }

        AppLogger.network.info("Response: HTTP \(httpResponse.statusCode) (\(data.count) bytes)")

        guard httpResponse.statusCode == 207 || httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                let wwwAuth = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate") ?? "<none>"
                AppLogger.network.error("Auth failed (401). WWW-Authenticate: \(wwwAuth)")
                throw ImportError.authenticationFailed
            }
            AppLogger.network.error("Server error: HTTP \(httpResponse.statusCode)")
            throw ImportError.serverError(statusCode: httpResponse.statusCode)
        }

        if data.isEmpty {
            throw ImportError.metadataParsingFailed("Server returned empty response. WebDAV may not be enabled on this server.")
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if !contentType.contains("xml") && !contentType.isEmpty {
            throw ImportError.metadataParsingFailed(
                "Server returned non-XML response (\(contentType)). This server may not support WebDAV."
            )
        }

        let parsed = try parseWebDAVResponse(data: data, basePath: directoryPath)
        let normalized = parsed.map { entry in
            RemoteFileEntry(
                id: entry.id,
                name: entry.name,
                path: normalizedWebDAVPath(entry.path, server: server),
                isDirectory: entry.isDirectory,
                size: entry.size,
                modifiedDate: entry.modifiedDate,
                mimeType: entry.mimeType
            )
        }
        let baseWithoutSlash = directoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.filter {
            let pathWithoutSlash = $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return pathWithoutSlash != baseWithoutSlash
                && pathWithoutSlash != normalizedBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    private func parseWebDAVResponse(data: Data, basePath: String) throws -> [RemoteFileEntry] {
        let parser = WebDAVResponseParser(data: data, basePath: basePath)
        return try parser.parse()
    }

    private func normalizedWebDAVPath(_ rawPath: String, server: WebDAVServerConfig) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: path), url.scheme != nil {
            path = url.path
        }

        if let decoded = path.removingPercentEncoding {
            path = decoded
        }

        if path.isEmpty { path = "/" }
        if !path.hasPrefix("/") { path = "/" + path }

        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let basePath = server.baseURL.path
        if basePath != "/", path.hasPrefix(basePath) {
            path = String(path.dropFirst(basePath.count))
            if path.isEmpty { path = "/" }
            if !path.hasPrefix("/") { path = "/" + path }
        }

        return path
    }

    func importFromFilesApp(
        urls: [URL],
        audioSelectionMode: FilesAudioSelectionMode = .groupByFolder
    ) async throws -> [LocalBookFile] {
        isImporting = true
        lastError = nil

        var importedBooks: [LocalBookFile] = []
        let batch = ImportBatch(sourceType: .files)

        defer {
            isImporting = false
            currentBatch = nil
        }

        var directoryURLs: [URL] = []
        var fileURLs: [URL] = []

        for url in urls {
            try Task.checkCancellation()
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }

            await ensureLocallyAvailable(url)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                AppLogger.network.warning(
                    "Downloaded file inaccessible \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
                )
                continue
            }

            if isDirectory.boolValue {
                directoryURLs.append(url)
            } else {
                fileURLs.append(url)
            }
        }

        for folderURL in directoryURLs {
            try Task.checkCancellation()
            let secured = folderURL.startAccessingSecurityScopedResource()
            defer { if secured { folderURL.stopAccessingSecurityScopedResource() } }
            do {
                if let book = try await importBookFolder(from: folderURL, sourceType: .files) {
                    importedBooks.append(book)
                }
            } catch {
                AppLogger.network.error(
                    "Folder import failed \(DiagnosticLogSanitizer.fileDescriptor(for: folderURL)): \(error.localizedDescription)"
                )
            }
        }

        let audioFileURLs = fileURLs.filter { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
        let nonAudioFileURLs = fileURLs.filter { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) == nil }

        var audioByParent: [String: [URL]] = [:]
        for url in audioFileURLs {
            try Task.checkCancellation()
            let parent = url.deletingLastPathComponent().path
            audioByParent[parent, default: []].append(url)
        }

        for (_, group) in audioByParent {
            let audioGroups: [[URL]]
            switch audioSelectionMode {
            case .groupByFolder:
                audioGroups = [group.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }]
            case .splitSelectedBooks:
                audioGroups = splitSelectedAudioGroups(group)
            }

            for audioGroup in audioGroups {
                try Task.checkCancellation()
                do {
                    if audioGroup.count > 1 {

                        let stagingFolder = stagingDirectory.appendingPathComponent(UUID().uuidString)
                        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
                        defer { try? fileManager.removeItem(at: stagingFolder) }
                        for fileURL in audioGroup {
                            try Task.checkCancellation()
                            let dest = stagingFolder.appendingPathComponent(fileURL.lastPathComponent)
                            let secured = fileURL.startAccessingSecurityScopedResource()
                            try fileManager.copyItem(at: fileURL, to: dest)
                            if secured { fileURL.stopAccessingSecurityScopedResource() }
                        }
                        let sourceInfo = SourceInfo(type: .files, remotePath: audioGroup[0].deletingLastPathComponent().path)
                        if let book = try await importStagedFolder(stagingFolder, sourceInfo: sourceInfo) {
                            importedBooks.append(book)
                        }
                    } else if let singleURL = audioGroup.first {
                        let secured = singleURL.startAccessingSecurityScopedResource()
                        defer { if secured { singleURL.stopAccessingSecurityScopedResource() } }
                        if let book = try await importSingleAudioFile(from: singleURL, sourceType: .files) {
                            importedBooks.append(book)
                        }
                    }
                } catch {
                    AppLogger.network.error(
                        "Failed to import audio group from '\(audioGroup.first?.deletingLastPathComponent().lastPathComponent ?? "?")': \(error.localizedDescription)"
                    )
                }
            }
        }

        for url in nonAudioFileURLs {
            try Task.checkCancellation()
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let lowerExt = url.pathExtension.lowercased()
            do {
                if lowerExt == "zip" {
                    let booksFromZip = try await importZipFile(from: url, sourceType: .files)
                    importedBooks.append(contentsOf: booksFromZip)
                } else if EbookFormat.from(fileExtension: lowerExt) != nil {
                    if let book = try await importEbookFile(from: url, sourceType: .files) {
                        importedBooks.append(book)
                    }
                }
            } catch {
                AppLogger.network.error(
                    "Import failed \(DiagnosticLogSanitizer.fileDescriptor(for: url)): \(error.localizedDescription)"
                )
            }
        }

        _ = batch
        return importedBooks
    }

    private func splitSelectedAudioGroups(_ files: [URL]) -> [[URL]] {
        guard files.count > 1 else { return [files] }

        let sortedFiles = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let selfContainedFiles = sortedFiles.filter { isSelfContainedAudiobookFile($0) }
        let partFiles = sortedFiles.filter { !isSelfContainedAudiobookFile($0) }

        if selfContainedFiles.count > 1 && partFiles.isEmpty {
            return selfContainedFiles.map { [$0] }
        }

        if !selfContainedFiles.isEmpty && !partFiles.isEmpty {
            var groups = selfContainedFiles.map { [$0] }
            groups.append(partFiles)
            return groups
        }

        return [sortedFiles]
    }

    private func isSelfContainedAudiobookFile(_ url: URL) -> Bool {
        ["m4b", "m4a", "mp4"].contains(url.pathExtension.lowercased())
    }

    private func ensureLocallyAvailable(_ url: URL) async {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus,
            status != .current
        else {
            return
        }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            AppLogger.network.error(
                "Could not start iCloud download \(DiagnosticLogSanitizer.fileDescriptor(for: url)): \(error)"
            )
            return
        }

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if current?.ubiquitousItemDownloadingStatus == .current {
                AppLogger.network.debug(
                    "iCloud download complete \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
                )
                return
            }
        }
        AppLogger.network.warning("iCloud download timed out \(DiagnosticLogSanitizer.fileDescriptor(for: url))")
    }

    private func importZipFile(from fileURL: URL, sourceType: SourceType) async throws -> [LocalBookFile] {
        try ImportLimits.validateArchiveFile(fileURL)
        let zipStaging = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: zipStaging, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: zipStaging)
        }

        let copiedZipURL = zipStaging.appendingPathComponent(fileURL.lastPathComponent)
        try fileManager.copyItem(at: fileURL, to: copiedZipURL)

        let extractionFolder = zipStaging.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionFolder, withIntermediateDirectories: true)

        #if os(tvOS)
        throw ImportError.fileOperationFailed("ZIP import is not available on tvOS.")
        #else
        do {
            try await ImportLimits.extractArchive(copiedZipURL, to: extractionFolder, fileManager: fileManager)
        } catch {
            throw ImportError.fileOperationFailed(error.localizedDescription)
        }

        var importedBooks: [LocalBookFile] = []
        let rootContents = try fileManager.contentsOfDirectory(
            at: extractionFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let rootHasAudio = rootContents.contains { item in
            AudiobookFormat.from(fileExtension: item.pathExtension.lowercased()) != nil
        }

        if rootHasAudio {
            if let book = try await importBookFolder(from: extractionFolder, sourceType: sourceType) {
                importedBooks.append(book)
            }
            return importedBooks
        }

        for item in rootContents {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                if let book = try await importBookFolder(from: item, sourceType: sourceType) {
                    importedBooks.append(book)
                }
            } else if AudiobookFormat.from(fileExtension: item.pathExtension.lowercased()) != nil {
                if let book = try await importSingleAudioFile(from: item, sourceType: sourceType) {
                    importedBooks.append(book)
                }
            }
        }

        return importedBooks
        #endif
    }

    func importFromWebDAV(server: WebDAVServerConfig, remotePath: String) async throws -> LocalBookFile? {
        isImporting = true
        lastError = nil

        defer { isImporting = false }

        return try await importFromWebDAVInternal(server: server, remotePath: remotePath, isTopLevel: true)
    }

    private func importFromWebDAVInternal(
        server: WebDAVServerConfig,
        remotePath: String,
        isTopLevel: Bool
    ) async throws -> LocalBookFile? {
        let entries = try await listWebDAVDirectory(server: server, path: remotePath)

        let fileEntries = entries.filter {
            $0.isAudioFile || $0.isMetadataFile || $0.isCoverImage || $0.isZipArchive || $0.isEbookFile
        }
        let subdirEntries = entries.filter { $0.isDirectory }

        if fileEntries.isEmpty && !subdirEntries.isEmpty && isTopLevel {
            AppLogger.network.info("Container folder detected at '\(remotePath)' - recursing into \(subdirEntries.count) subdirectorie(s)")
            var firstBook: LocalBookFile?
            for subdir in subdirEntries {
                try Task.checkCancellation()
                do {
                    if let book = try await importFromWebDAVInternal(server: server, remotePath: subdir.path, isTopLevel: false) {
                        if firstBook == nil { firstBook = book }
                    }
                } catch {
                    AppLogger.network.error("Skipping subfolder '\(subdir.name)': \(error.localizedDescription)")
                }
            }
            if firstBook != nil { return firstBook }
        }

        let stagingFolder = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)

        defer {
            if fileManager.fileExists(atPath: stagingFolder.path) {
                try? fileManager.removeItem(at: stagingFolder)
            }
        }

        var downloadedZipFiles: [URL] = []
        for entry in fileEntries {
            try Task.checkCancellation()
            let remoteURL = server.url(for: entry.path)
            let localPath = stagingFolder.appendingPathComponent(entry.name)

            try await downloadFile(from: remoteURL, to: localPath, auth: server)

            if entry.isZipArchive {
                downloadedZipFiles.append(localPath)
            }
        }

        if !downloadedZipFiles.isEmpty {
            var importedFromZip: [LocalBookFile] = []
            for zipURL in downloadedZipFiles {
                let books = try await importZipFile(from: zipURL, sourceType: .webDAV)
                importedFromZip.append(contentsOf: books)
            }
            return importedFromZip.first
        }

        let stagedContents = (try? fileManager.contentsOfDirectory(at: stagingFolder, includingPropertiesForKeys: nil)) ?? []
        let stagedAudio = stagedContents.filter { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
        let stagedEbooks = stagedContents.filter { EbookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }

        if stagedAudio.isEmpty, let ebookFile = stagedEbooks.first {
            AppLogger.network.debug(
                "[WebDAV] Routing ebook through Readium \(DiagnosticLogSanitizer.fileDescriptor(for: ebookFile))"
            )
            return try await importEbookFile(from: ebookFile, sourceType: .webDAV)
        }

        let sourceInfo = SourceInfo.fromWebDAV(serverId: server.id, serverName: server.name, path: remotePath)
        return try await importStagedFolder(stagingFolder, sourceInfo: sourceInfo)
    }

    private func downloadFile(from url: URL, to destination: URL, auth: WebDAVServerConfig?) async throws {
        var request = URLRequest(url: url)

        if let auth = auth, let username = auth.username, let password = auth.password {
            let credentials = "\(username):\(password)"
            if let credData = credentials.data(using: .utf8) {
                request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        let (tempURL, response) = try await URLSession.shared.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ImportError.downloadFailed
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
        try ImportLimits.validateImportedMediaFile(destination)
    }

    private func importBookFolder(from folderURL: URL, sourceType: SourceType) async throws -> LocalBookFile? {
        let stagingFolder = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingFolder) }

        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        for item in contents {
            try Task.checkCancellation()
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                try ImportLimits.validateImportedMediaFile(item)
            }
            let dest = stagingFolder.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: dest)
        }

        let stagedContents = (try? fileManager.contentsOfDirectory(at: stagingFolder, includingPropertiesForKeys: nil)) ?? []
        let hasAudio = stagedContents.contains { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
        let ebookFiles = stagedContents.filter { EbookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }

        if !hasAudio && !ebookFiles.isEmpty {
            AppLogger.network.info(
                "Folder '\(folderURL.lastPathComponent)' contains \(ebookFiles.count) ebook(s) and no audio - routing through ebook import"
            )
            var firstImported: LocalBookFile?
            for ebookFile in ebookFiles {
                if let book = try await importEbookFile(from: ebookFile, sourceType: sourceType) {
                    if firstImported == nil { firstImported = book }
                }
            }
            try? fileManager.removeItem(at: stagingFolder)
            return firstImported
        }

        let sourceInfo = SourceInfo(type: sourceType, remotePath: folderURL.path)
        return try await importStagedFolder(stagingFolder, sourceInfo: sourceInfo)
    }

    private func importEbookFile(from fileURL: URL, sourceType: SourceType) async throws -> LocalBookFile? {
        try Task.checkCancellation()
        try ImportLimits.validateImportedMediaFile(fileURL)
        let ebooksRoot = LocalEbookImporter.shared.localEbooksRoot
        try fileManager.createDirectory(at: ebooksRoot, withIntermediateDirectories: true)

        let destinationURL = uniqueDestinationURL(
            for: ebooksRoot.appendingPathComponent(sanitizeFilename(fileURL.lastPathComponent))
        )
        try fileManager.copyItem(at: fileURL, to: destinationURL)
        try ImportLimits.validateImportedMediaFile(destinationURL)

        var metadata: LocalBookMetadata
        do {
            metadata = try await LocalEbookImporter.shared.extractMetadata(from: destinationURL)
        } catch {
            AppLogger.network.error(
                "Ebook metadata extraction failed for '\(destinationURL.lastPathComponent)': \(error.localizedDescription)"
            )
            metadata = LocalBookMetadata(title: destinationURL.deletingPathExtension().lastPathComponent)
        }

        let size = fileSize(at: destinationURL)
        let format = destinationURL.pathExtension.lowercased()
        let fileHash = UUID().uuidString

        if let sourceCoverPath = metadata.coverImagePath,
            sourceCoverPath != destinationURL.deletingPathExtension().appendingPathExtension("cover.jpg").path,
            fileManager.fileExists(atPath: sourceCoverPath)
        {
            let sourceCoverURL = URL(fileURLWithPath: sourceCoverPath)
            let coverDestinationURL =
                destinationURL
                .deletingPathExtension()
                .appendingPathExtension(sourceCoverURL.pathExtension.isEmpty ? "cover.jpg" : "cover.\(sourceCoverURL.pathExtension)")

            if fileManager.fileExists(atPath: coverDestinationURL.path) {
                try? fileManager.removeItem(at: coverDestinationURL)
            }
            try? fileManager.copyItem(at: sourceCoverURL, to: coverDestinationURL)
            if fileManager.fileExists(atPath: coverDestinationURL.path) {
                metadata.coverImagePath = coverDestinationURL.path
            }
        }

        let sidecar = LocalBookSidecar(
            metadata: metadata,
            fileHash: fileHash,
            fileName: destinationURL.lastPathComponent,
            format: format
        )

        let sidecarURL = URL(fileURLWithPath: LocalBookFile.sidecarPath(for: destinationURL.path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: sidecarURL, options: .atomic)

        let relativePath = destinationURL.path.replacingOccurrences(of: ebooksRoot.path + "/", with: "")

        AppLogger.network.info("Stored ebook \(DiagnosticLogSanitizer.fileDescriptor(for: destinationURL))")

        return LocalBookFile(
            id: "\(LocalLibraryService.fileSharingLibraryId):\(fileHash)",
            fileName: destinationURL.lastPathComponent,
            filePath: destinationURL.path,
            relativePath: relativePath,
            fileSize: size,
            format: format,
            fileHash: fileHash,
            metadata: metadata,
            sidecarPath: sidecarURL.path,
            extractedAt: Date()
        )
    }

    private func importSingleAudioFile(from fileURL: URL, sourceType: SourceType) async throws -> LocalBookFile? {
        try Task.checkCancellation()
        try ImportLimits.validateImportedMediaFile(fileURL)
        let stagingFolder = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingFolder) }

        let destPath = stagingFolder.appendingPathComponent(fileURL.lastPathComponent)
        try fileManager.copyItem(at: fileURL, to: destPath)

        let sidecarPath = fileURL.deletingPathExtension().appendingPathExtension("sidecar.json")
        if fileManager.fileExists(atPath: sidecarPath.path) {
            let destSidecar = stagingFolder.appendingPathComponent(sidecarPath.lastPathComponent)
            try fileManager.copyItem(at: sidecarPath, to: destSidecar)
        }

        let metadataPath = fileURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
        if fileManager.fileExists(atPath: metadataPath.path) {
            let destMetadata = stagingFolder.appendingPathComponent("metadata.json")
            try fileManager.copyItem(at: metadataPath, to: destMetadata)
        }

        let coverNames = ["cover.jpg", "cover.png", "folder.jpg", "folder.png"]
        let parentFolder = fileURL.deletingLastPathComponent()
        for coverName in coverNames {
            let coverPath = parentFolder.appendingPathComponent(coverName)
            if fileManager.fileExists(atPath: coverPath.path) {
                let destCover = stagingFolder.appendingPathComponent(coverName)
                try fileManager.copyItem(at: coverPath, to: destCover)
                break
            }
        }

        let sourceInfo = SourceInfo(type: sourceType, remotePath: fileURL.path)
        return try await importStagedFolder(stagingFolder, sourceInfo: sourceInfo)
    }

    private func importStagedFolder(_ stagingFolder: URL, sourceInfo: SourceInfo) async throws -> LocalBookFile? {
        let contents = try fileManager.contentsOfDirectory(at: stagingFolder, includingPropertiesForKeys: [.fileSizeKey])
        var folderBudget = ImportScanBudget()
        for item in contents {
            try await folderBudget.recordAsync(url: item, root: stagingFolder)
        }

        let allAudioFiles =
            contents
            .filter { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard let primaryAudioFile = allAudioFiles.first else {
            throw ImportError.noAudioFileFound
        }

        var metadata = try await extractAndMergeMetadata(from: stagingFolder, audioFile: primaryAudioFile)

        let author = metadata.author ?? "Unknown Author"
        let title = metadata.title
        let safeAuthor = sanitizeFilename(author)
        let safeTitle = sanitizeFilename(title)

        let canonicalBookFolder =
            canonicalLibraryRoot
            .appendingPathComponent(safeAuthor)
            .appendingPathComponent(safeTitle)

        try fileManager.createDirectory(at: canonicalBookFolder, withIntermediateDirectories: true)

        let isMultiFile = allAudioFiles.count > 1

        var movedAudioFiles: [(url: URL, fileInfo: AudioFileInfo)] = []
        var totalSize: Int64 = 0

        for audioFile in allAudioFiles {
            try Task.checkCancellation()
            try ImportLimits.validateImportedMediaFile(audioFile)
            let destName =
                isMultiFile
                ? audioFile.lastPathComponent
                : "\(safeTitle).\(audioFile.pathExtension)"
            let destURL = canonicalBookFolder.appendingPathComponent(destName)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: audioFile, to: destURL)

            let sz = fileSize(at: destURL)
            totalSize += sz
            movedAudioFiles.append(
                (
                    url: destURL,
                    fileInfo: AudioFileInfo(
                        fileName: destName,
                        filePath: destURL.path,
                        fileSize: sz,
                        format: audioFile.pathExtension.lowercased()
                    )
                )
            )
        }

        let canonicalAudioPath = movedAudioFiles[0].url
        let canonicalAudioName = movedAudioFiles[0].fileInfo.fileName

        let currentStagingContents = (try? fileManager.contentsOfDirectory(at: stagingFolder, includingPropertiesForKeys: nil)) ?? []
        let allCoverCandidates = currentStagingContents.filter { url in
            let name = url.lastPathComponent.lowercased()
            return (name.contains("cover") || name.contains("folder"))
                && ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
        }

        if let coverFile = allCoverCandidates.first {
            let coverDest = canonicalBookFolder.appendingPathComponent("cover.\(coverFile.pathExtension)")
            if fileManager.fileExists(atPath: coverDest.path) {
                try fileManager.removeItem(at: coverDest)
            }
            try? fileManager.moveItem(at: coverFile, to: coverDest)
            metadata.coverImagePath = coverDest.path
        } else if let embeddedCoverPath = metadata.coverImagePath,
            embeddedCoverPath.contains(stagingFolder.path),
            fileManager.fileExists(atPath: embeddedCoverPath)
        {
            let coverSourceURL = URL(fileURLWithPath: embeddedCoverPath)
            let coverDest = canonicalBookFolder.appendingPathComponent("cover.\(coverSourceURL.pathExtension)")
            if fileManager.fileExists(atPath: coverDest.path) {
                try? fileManager.removeItem(at: coverDest)
            }
            try? fileManager.moveItem(at: coverSourceURL, to: coverDest)
            metadata.coverImagePath = coverDest.path
        } else if metadata.coverImagePath == nil || !fileManager.fileExists(atPath: metadata.coverImagePath ?? "") {
            let extractor = FileMetadataExtractor()
            if let coverPath = try? await extractor.extractAndSaveCoverImage(from: canonicalAudioPath.path) {
                metadata.coverImagePath = coverPath
            }
        }

        let metadataURL = canonicalBookFolder.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)

        if let chapters = metadata.chapters, !chapters.isEmpty {
            let chaptersURL = canonicalBookFolder.appendingPathComponent("chapters.json")
            let chaptersData = try encoder.encode(chapters)
            try chaptersData.write(to: chaptersURL, options: .atomic)
        }

        let sourceURL = canonicalBookFolder.appendingPathComponent("source.json")
        let sourceData = try encoder.encode(sourceInfo)
        try sourceData.write(to: sourceURL, options: .atomic)

        try? fileManager.removeItem(at: stagingFolder)

        let audioFileInfos: [AudioFileInfo]? = isMultiFile ? movedAudioFiles.map(\.fileInfo) : nil

        let bookFile = LocalBookFile(
            id: UUID().uuidString,
            fileName: canonicalAudioName,
            filePath: canonicalAudioPath.path,
            fileSize: isMultiFile ? totalSize : fileSize(at: canonicalAudioPath),
            format: canonicalAudioPath.pathExtension.lowercased(),
            metadata: metadata,
            sidecarPath: metadataURL.path,
            extractedAt: Date(),
            audioFiles: audioFileInfos
        )

        AppLogger.network.info(
            "Stored '\(title)' (\(isMultiFile ? "\(movedAudioFiles.count) tracks" : "single file")) -> \(canonicalBookFolder.path)"
        )
        return bookFile
    }

    private func extractAndMergeMetadata(from folder: URL, audioFile: URL) async throws -> LocalBookMetadata {
        let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)

        var sidecarMetadata: LocalBookMetadata?

        if let audibleSidecar = contents.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return name.hasSuffix(".metadata.json") && name != "metadata.json"
        }) {
            AppLogger.network.debug(
                "[Import] Found Audible sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: audibleSidecar))"
            )
            sidecarMetadata = try? loadSidecarMetadata(from: audibleSidecar)
        }

        if sidecarMetadata == nil,
            let metadataFile = contents.first(where: { $0.lastPathComponent.lowercased() == "metadata.json" })
        {
            sidecarMetadata = try? loadSidecarMetadata(from: metadataFile)
        }

        if sidecarMetadata == nil {
            if let sidecarFile = contents.first(where: { $0.pathExtension == "json" && $0.lastPathComponent.contains("sidecar") }) {
                sidecarMetadata = try? loadSidecarMetadata(from: sidecarFile)
            }
        }

        let embeddedMetadata = try await extractEmbeddedMetadata(from: audioFile)

        if var metadata = sidecarMetadata {
            if metadata.author == nil || metadata.author?.isEmpty == true {
                metadata.author = embeddedMetadata.author
            }
            if metadata.narrator == nil {
                metadata.narrator = embeddedMetadata.narrator
            }
            if metadata.description == nil {
                metadata.description = embeddedMetadata.description
            }
            if metadata.duration == nil {
                metadata.duration = embeddedMetadata.duration
            }
            if metadata.chapters == nil || metadata.chapters?.isEmpty == true {
                metadata.chapters = embeddedMetadata.chapters
            }
            if metadata.publishedYear == nil {
                metadata.publishedYear = embeddedMetadata.publishedYear
            }
            if metadata.genres == nil {
                metadata.genres = embeddedMetadata.genres
            }
            if metadata.coverImagePath == nil || metadata.coverImagePath?.isEmpty == true {
                metadata.coverImagePath = embeddedMetadata.coverImagePath
            }
            return metadata
        }

        if embeddedMetadata.title != audioFile.deletingPathExtension().lastPathComponent {
            return embeddedMetadata
        }

        let filename = audioFile.deletingPathExtension().lastPathComponent
        return LocalBookMetadata(
            title: filename,
            author: embeddedMetadata.author,
            narrator: embeddedMetadata.narrator,
            description: embeddedMetadata.description,
            series: embeddedMetadata.series,
            seriesNumber: embeddedMetadata.seriesNumber,
            publishedYear: embeddedMetadata.publishedYear,
            genres: embeddedMetadata.genres,
            publisher: embeddedMetadata.publisher,
            isbn: embeddedMetadata.isbn,
            asin: embeddedMetadata.asin,
            duration: embeddedMetadata.duration,
            chapters: embeddedMetadata.chapters,
            coverImagePath: embeddedMetadata.coverImagePath
        )
    }

    private func loadSidecarMetadata(from url: URL) throws -> LocalBookMetadata? {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let audibleMetadata = try? decoder.decode(AudibleMetadata.self, from: data),
            audibleMetadata.ChapterInfo != nil || audibleMetadata.authors != nil
        {
            AppLogger.network.info(
                "[Import] Detected Audible metadata format (chapters: \(audibleMetadata.ChapterInfo?.chapters?.count ?? 0))"
            )
            return audibleMetadata.toLocalBookMetadata()
        }

        if let absMetadata = try? decoder.decode(AudiobookshelfMetadata.self, from: data) {
            return absMetadata.toLocalBookMetadata()
        }

        if let metadata = try? decoder.decode(LocalBookMetadata.self, from: data) {
            return metadata
        }

        if let generic = try? decoder.decode(GenericBookMetadata.self, from: data) {
            return generic.toLocalBookMetadata()
        }

        return nil
    }

    private func extractEmbeddedMetadata(from audioURL: URL) async throws -> LocalBookMetadata {
        let extractor = FileMetadataExtractor()
        return try await extractor.extractMetadata(
            from: audioURL.path,
            timeout: ImportLimits.metadataExtractionTimeoutSeconds
        )
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

    private func uniqueDestinationURL(for desiredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: desiredURL.path) else { return desiredURL }

        let directory = desiredURL.deletingLastPathComponent()
        let baseName = desiredURL.deletingPathExtension().lastPathComponent
        let pathExtension = desiredURL.pathExtension
        var counter = 1

        while true {
            let candidateName =
                pathExtension.isEmpty
                ? "\(baseName) (\(counter))"
                : "\(baseName) (\(counter)).\(pathExtension)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

extension RemoteImportService: URLSessionDownloadDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            #if os(iOS)
            guard let delegate = UIApplication.shared.delegate as? CarPlayAppDelegate else { return }
            delegate.consumeBackgroundCompletionHandler(forIdentifier: identifier)?()
            #endif
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            if NetworkHostUtils.isLocalNetworkHost(host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in
            if let handler = downloadCompletionHandlers[taskId] {
                handler(location, nil)
                downloadCompletionHandlers.removeValue(forKey: taskId)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        Task { @MainActor in
            if let error = error, let handler = downloadCompletionHandlers[taskId] {
                handler(nil, error)
                downloadCompletionHandlers.removeValue(forKey: taskId)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier

        Task { @MainActor in
            if var importProgress = activeDownloadTasks[taskId] {
                importProgress.bytesDownloaded = totalBytesWritten
                importProgress.totalBytes = totalBytesExpectedToWrite
                activeDownloadTasks[taskId] = importProgress
            }
        }
    }
}

enum ImportError: LocalizedError {
    case noAudioFileFound
    case invalidResponse
    case authenticationFailed
    case serverError(statusCode: Int)
    case downloadFailed
    case unsupportedURL
    case tlsTrustFailed
    case metadataParsingFailed(String?)
    case fileOperationFailed(String)
    case serverUnreachable

    var errorDescription: String? {
        switch self {
        case .noAudioFileFound:
            return "No supported audio file found in folder"
        case .invalidResponse:
            return "Invalid server response"
        case .authenticationFailed:
            return "Authentication failed. Check username/password"
        case .serverError(let code):
            return "Server error (HTTP \(code))"
        case .downloadFailed:
            return "Download failed"
        case .unsupportedURL:
            return "Unsupported URL. Ensure it includes https:// and a hostname"
        case .tlsTrustFailed:
            return "TLS trust failed. Use the server's hostname that matches its certificate (e.g., MagicDNS name)"
        case .metadataParsingFailed(let detail):
            if let detail = detail {
                return "Failed to parse server response: \(detail)"
            }
            return "Failed to parse server response. Server may not support WebDAV PROPFIND."
        case .fileOperationFailed(let detail):
            return "File operation failed: \(detail)"
        case .serverUnreachable:
            return "Server unreachable. Check VPN/Tailscale connection"
        }
    }
}

private class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let basePath: String
    private var entries: [RemoteFileEntry] = []
    private var currentEntry: RemoteFileEntryBuilder?
    private var currentElement: String = ""
    private var currentText: String = ""

    init(data: Data, basePath: String) {
        self.parser = XMLParser(data: data)
        self.basePath = basePath
        super.init()
        parser.delegate = self
    }

    private func normalizedElementName(_ elementName: String, qualifiedName qName: String?) -> String {
        let raw = qName.flatMap { $0.isEmpty ? nil : $0 } ?? elementName
        let local = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? raw
        return local.lowercased()
    }

    func parse() throws -> [RemoteFileEntry] {
        guard parser.parse() else {
            if let error = parser.parserError {
                let nsError = error as NSError
                if nsError.domain == "NSXMLParserErrorDomain" && nsError.code == 111 {
                    throw ImportError.metadataParsingFailed(
                        "Server returned empty response. WebDAV is likely not enabled or the path doesn't exist."
                    )
                }
                throw ImportError.metadataParsingFailed("XML parse error: \(error.localizedDescription)")
            }
            throw ImportError.metadataParsingFailed("Unknown XML parse error")
        }
        let filtered = entries.filter { $0.path != basePath && $0.path != basePath + "/" }

        if entries.isEmpty {
            AppLogger.network.info("WebDAV PROPFIND returned no entries. Server may not support WebDAV.")
        }

        return filtered
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = normalizedElementName(elementName, qualifiedName: qName)
        currentText = ""

        if currentElement == "response" {
            currentEntry = RemoteFileEntryBuilder()
        } else if currentElement == "collection" {
            currentEntry?.isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = normalizedElementName(elementName, qualifiedName: qName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "href":
            currentEntry?.path = text.removingPercentEncoding ?? text
        case "displayname":
            currentEntry?.name = text.removingPercentEncoding ?? text
        case "getcontentlength":
            currentEntry?.size = Int64(text)
        case "getcontenttype":
            currentEntry?.mimeType = text
        case "getlastmodified":
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            currentEntry?.modifiedDate = formatter.date(from: text)
        case "response":
            if let builder = currentEntry, let entry = builder.build() {
                entries.append(entry)
            }
            currentEntry = nil
        default:
            break
        }
    }
}

private class RemoteFileEntryBuilder {
    var name: String?
    var path: String?
    var isDirectory: Bool = false
    var size: Int64?
    var modifiedDate: Date?
    var mimeType: String?

    private var inferredIsDirectory: Bool {
        if isDirectory {
            return true
        }

        if let path, path.count > 1, path.hasSuffix("/") {
            return true
        }

        let lowercasedMimeType = mimeType?.lowercased() ?? ""
        if lowercasedMimeType.contains("directory") || lowercasedMimeType.contains("collection")
            || lowercasedMimeType == "httpd/unix-directory" || lowercasedMimeType == "inode/directory"
        {
            return true
        }

        return false
    }

    func build() -> RemoteFileEntry? {
        guard let path = path else { return nil }
        let trimmedName = self.name?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName: String = {
            if let trimmedName, !trimmedName.isEmpty {
                return trimmedName
            }

            let normalizedPath: String
            if path.count > 1, path.hasSuffix("/") {
                normalizedPath = String(path.dropLast())
            } else {
                normalizedPath = path
            }

            let rawFallback = (normalizedPath as NSString).lastPathComponent
            let decodedFallback = rawFallback.removingPercentEncoding ?? rawFallback
            if decodedFallback.isEmpty {
                return "/"
            }
            return decodedFallback
        }()

        return RemoteFileEntry(
            name: resolvedName,
            path: path,
            isDirectory: inferredIsDirectory,
            size: size,
            modifiedDate: modifiedDate,
            mimeType: mimeType
        )
    }
}

private struct AudiobookshelfMetadata: Codable {
    let title: String?
    let author: String?
    let narrator: String?
    let description: String?
    let series: String?
    let seriesSequence: String?
    let publishedYear: Int?
    let genres: [String]?
    let duration: Double?
    let chapters: [AudiobookshelfChapter]?

    struct AudiobookshelfChapter: Codable {
        let title: String
        let start: Double
        let end: Double
    }

    func toLocalBookMetadata() -> LocalBookMetadata {
        let localChapters: [LocalChapter]? = chapters?.map { ch in
            LocalChapter(
                title: ch.title,
                startTime: ch.start,
                endTime: ch.end,
                duration: ch.end - ch.start
            )
        }

        return LocalBookMetadata(
            title: title ?? "Unknown",
            author: author,
            narrator: narrator,
            description: description,
            series: series,
            seriesNumber: Int(seriesSequence ?? ""),
            seriesSequence: seriesSequence,
            publishedYear: publishedYear,
            genres: genres,
            duration: duration,
            chapters: localChapters
        )
    }
}

private struct AudibleMetadata: Codable {
    let title: String?
    let asin: String?
    let authors: [AudibleAuthor]?
    let narrators: [AudibleNarrator]?
    let publisher_summary: String?
    let merchandising_summary: String?
    let publisher_name: String?
    let series: [AudibleSeries]?
    let runtime_length_min: Int?
    let release_date: String?
    let publication_datetime: String?
    let ChapterInfo: AudibleChapterInfo?

    struct AudibleAuthor: Codable {
        let name: String?
        let asin: String?
    }

    struct AudibleNarrator: Codable {
        let name: String?
    }

    struct AudibleSeries: Codable {
        let title: String?
        let sequence: String?
        let asin: String?
        let url: String?
    }

    struct AudibleChapterInfo: Codable {
        let chapters: [AudibleChapter]?
        let runtime_length_ms: Int64?
        let runtime_length_sec: Int64?
        let is_accurate: Bool?
        let brandIntroDurationMs: Int?
        let brandOutroDurationMs: Int?
    }

    struct AudibleChapter: Codable {
        let title: String
        let start_offset_ms: Int64
        let length_ms: Int64
        let start_offset_sec: Int64?
        let chapters: [AudibleChapter]?
    }

    func toLocalBookMetadata() -> LocalBookMetadata {
        let localChapters: [LocalChapter]? = ChapterInfo?.chapters?.map { chapter in
            let startSeconds = Double(chapter.start_offset_ms) / 1000.0
            let durationSeconds = Double(chapter.length_ms) / 1000.0
            return LocalChapter(
                title: chapter.title,
                startTime: startSeconds,
                endTime: startSeconds + durationSeconds,
                duration: durationSeconds
            )
        }

        let author = authors?.first?.name
        let narrator = narrators?.compactMap { $0.name }.joined(separator: ", ")
        let seriesName = series?.first?.title
        let rawSequence: String? = series?.first?.sequence
        let seriesNumber = rawSequence.flatMap { Double($0) }.map { Int($0) }
        let duration: TimeInterval? =
            ChapterInfo?.runtime_length_sec.map { Double($0) }
            ?? runtime_length_min.map { Double($0 * 60) }

        return LocalBookMetadata(
            title: title ?? "Unknown",
            author: author,
            narrator: narrator?.isEmpty == true ? nil : narrator,
            description: publisher_summary ?? merchandising_summary,
            series: seriesName,
            seriesNumber: seriesNumber,
            seriesSequence: rawSequence,
            publishedYear: nil,
            genres: nil,
            publisher: publisher_name,
            isbn: nil,
            asin: asin,
            duration: duration,
            chapters: localChapters
        )
    }
}

private struct GenericBookMetadata: Codable {
    let title: String?
    let author: String?
    let authors: [String]?
    let narrator: String?
    let narrators: [String]?
    let description: String?
    let summary: String?
    let series: String?
    let seriesIndex: Int?
    let year: Int?
    let publishedYear: Int?
    let genres: [String]?
    let tags: [String]?
    let duration: Double?
    let durationMs: Int?

    func toLocalBookMetadata() -> LocalBookMetadata {
        let authorStr = author ?? authors?.joined(separator: ", ")
        let narratorStr = narrator ?? narrators?.joined(separator: ", ")
        let desc = description ?? summary
        let pubYear = publishedYear ?? year
        let dur: TimeInterval? =
            if let d = duration {
                d
            } else if let ms = durationMs {
                Double(ms) / 1000.0
            } else {
                nil
            }

        return LocalBookMetadata(
            title: title ?? "Unknown",
            author: authorStr,
            narrator: narratorStr,
            description: desc,
            series: series,
            seriesNumber: seriesIndex,
            publishedYear: pubYear,
            genres: genres ?? tags,
            duration: dur
        )
    }
}

private final class WebDAVAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let credential: URLCredential
    private var challengeCount = 0

    init(username: String, password: String) {
        self.credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )
        super.init()
    }

    @objc nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        AppLogger.network.info("Auth challenge: \(method) (attempt \(challengeCount + 1))")

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if (method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest) && challengeCount < 2 {
            challengeCount += 1
            completionHandler(.useCredential, credential)
        } else if method == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust,
                NetworkHostUtils.isLocalNetworkHost(host)
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            AppLogger.network.info("Declining auth challenge: \(method)")
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
