import Foundation
import unrar_lib


public struct RARArchive {


    public struct Entry {
        public let fileName: String
        public let uncompressedSize: UInt64
        public let isDirectory: Bool
    }


    public enum RARError: LocalizedError {
        case openFailed(code: UInt32)
        case readHeaderFailed(code: Int32)
        case extractFailed(code: Int32)
        case noSuchFile(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let code): return "Failed to open RAR archive (code \(code))"
            case .readHeaderFailed(let code): return "Failed to read RAR header (code \(code))"
            case .extractFailed(let code): return "Failed to extract RAR file (code \(code))"
            case .noSuchFile(let name): return "File not found in archive: \(name)"
            }
        }
    }

    private let archivePath: String

    public init(path: String) {
        self.archivePath = path
    }

    public init(url: URL) {
        self.archivePath = url.path
    }


    public func listEntries() throws -> [Entry] {
        let handle = try openArchive(mode: RAR_OM_LIST)
        defer { RARCloseArchive(handle) }

        var entries: [Entry] = []
        var header = RARHeaderDataEx()

        while true {
            let readResult = RARReadHeaderEx(handle, &header)
            if readResult == ERAR_END_ARCHIVE { break }
            guard readResult == ERAR_SUCCESS else {
                throw RARError.readHeaderFailed(code: readResult)
            }

            let name = extractFileName(from: &header)
            let isDir = (header.Flags & UInt32(RHDF_DIRECTORY)) != 0
            let size = UInt64(header.UnpSizeHigh) << 32 | UInt64(header.UnpSize)

            entries.append(Entry(fileName: name, uncompressedSize: size, isDirectory: isDir))

            let skipResult = RARProcessFile(handle, Int32(RAR_SKIP), nil, nil)
            guard skipResult == ERAR_SUCCESS else {
                throw RARError.extractFailed(code: skipResult)
            }
        }

        return entries
    }


    public func extractAll(to destinationPath: String) throws {
        let handle = try openArchive(mode: RAR_OM_EXTRACT)
        defer { RARCloseArchive(handle) }

        var header = RARHeaderDataEx()

        while true {
            let readResult = RARReadHeaderEx(handle, &header)
            if readResult == ERAR_END_ARCHIVE { break }
            guard readResult == ERAR_SUCCESS else {
                throw RARError.readHeaderFailed(code: readResult)
            }

            var destChars = Array(destinationPath.utf8CString)
            let processResult = destChars.withUnsafeMutableBufferPointer { buf in
                RARProcessFile(handle, Int32(RAR_EXTRACT), buf.baseAddress, nil)
            }
            guard processResult == ERAR_SUCCESS else {
                throw RARError.extractFailed(code: processResult)
            }
        }
    }


    public func extractData(fromFile fileName: String) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnrarKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let handle = try openArchive(mode: RAR_OM_EXTRACT)
        defer { RARCloseArchive(handle) }

        var header = RARHeaderDataEx()

        while true {
            let readResult = RARReadHeaderEx(handle, &header)
            if readResult == ERAR_END_ARCHIVE { break }
            guard readResult == ERAR_SUCCESS else {
                throw RARError.readHeaderFailed(code: readResult)
            }

            let entryName = extractFileName(from: &header)
            if normalizedArchivePath(entryName) == normalizedArchivePath(fileName) {
                var destChars = Array(tempDir.path.utf8CString)
                let processResult = destChars.withUnsafeMutableBufferPointer { buf in
                    RARProcessFile(handle, Int32(RAR_EXTRACT), buf.baseAddress, nil)
                }
                guard processResult == ERAR_SUCCESS else {
                    throw RARError.extractFailed(code: processResult)
                }
                let extractedURL = extractedFileURL(in: tempDir, for: entryName)
                return try Data(contentsOf: extractedURL)
            } else {
                let skipResult = RARProcessFile(handle, Int32(RAR_SKIP), nil, nil)
                guard skipResult == ERAR_SUCCESS else {
                    throw RARError.extractFailed(code: skipResult)
                }
            }
        }

        throw RARError.noSuchFile(fileName)
    }


    private func openArchive(mode: Int32) throws -> UnsafeMutableRawPointer {
        var archiveData = RAROpenArchiveDataEx()
        let pathBytes = Array(archivePath.utf8CString)
        return try pathBytes.withUnsafeBufferPointer { pathBuf in
            let mutablePath = UnsafeMutablePointer(mutating: pathBuf.baseAddress!)
            archiveData.ArcName = mutablePath
            archiveData.ArcNameW = nil
            archiveData.OpenMode = UInt32(mode)
            archiveData.CmtBuf = nil
            archiveData.CmtBufSize = 0

            guard let handle = RAROpenArchiveEx(&archiveData) else {
                throw RARError.openFailed(code: archiveData.OpenResult)
            }
            guard archiveData.OpenResult == ERAR_SUCCESS else {
                RARCloseArchive(handle)
                throw RARError.openFailed(code: archiveData.OpenResult)
            }
            return handle
        }
    }

    private func extractFileName(from header: inout RARHeaderDataEx) -> String {
       
        return withUnsafePointer(to: &header.FileName) { ptr -> String in

            let narrow = String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            return narrow
        }
    }

    private func normalizedArchivePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    private func extractedFileURL(in directory: URL, for entryName: String) -> URL {
        normalizedArchivePath(entryName)
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(directory) { partialResult, component in
                partialResult.appendingPathComponent(String(component), isDirectory: false)
            }
    }
}
