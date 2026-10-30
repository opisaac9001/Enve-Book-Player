import Foundation

struct CloudBookStaging {
    let urls: [URL]
    let directory: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class CloudBookDownloadService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stage(
        items: [RemoteItem],
        provider: any BookSourceProvider,
        preserveFolderGrouping: Bool = true,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> CloudBookStaging {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudBooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        var folders: [String: URL] = [:]
        do {
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                guard item.isSupportedBookFile else { throw CloudDownloadError.unsupportedFile }
                let file = try await provider.resolveFile(item)
                let name = (item.name as NSString).lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else { throw CloudDownloadError.unsupportedFile }
                let folderID = preserveFolderGrouping
                    ? item.parentId ?? item.pathHint.map { ($0 as NSString).deletingLastPathComponent } ?? "root"
                    : String(index)
                let folderName = item.pathHint.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
                let parent = folders[folderID] ?? directory.appendingPathComponent(String(folders.count), isDirectory: true)
                    .appendingPathComponent(folderName.flatMap { $0.isEmpty ? nil : $0 } ?? "Audiobook", isDirectory: true)
                folders[folderID] = parent
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let destination = parent.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw CloudDownloadError.duplicateName }
                if let localURL = file.localURL {
                    try FileManager.default.copyItem(at: localURL, to: destination)
                } else {
                    guard let url = file.streamURL, url.scheme == "https" else { throw CloudDownloadError.invalidDownload }
                    var request = URLRequest(url: url)
                    if file.requiresAuthHeader {
                        guard let authorization = file.authHeaderValue, !authorization.isEmpty else { throw CloudDownloadError.invalidDownload }
                        request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    }
                    let (temporary, response) = try await session.download(for: request)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        throw CloudDownloadError.invalidDownload
                    }
                    if let expected = file.contentLength {
                        let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        guard actual.map(Int64.init) == expected else { throw CloudDownloadError.incompleteDownload }
                    }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                urls.append(destination)
                progress(index + 1, items.count)
            }
            try Task.checkCancellation()
            return CloudBookStaging(urls: urls, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private enum CloudDownloadError: LocalizedError {
    case unsupportedFile, invalidDownload, incompleteDownload, duplicateName
    var errorDescription: String? {
        switch self {
        case .duplicateName: "Two selected files have the same name in this folder. Import them separately."
        case .unsupportedFile: "Choose supported audiobook or ebook files to import."
        case .invalidDownload: "The file could not be downloaded. Reconnect your cloud drive and try again."
        case .incompleteDownload: "The download was incomplete. Check your connection and try again."
        }
    }
}
