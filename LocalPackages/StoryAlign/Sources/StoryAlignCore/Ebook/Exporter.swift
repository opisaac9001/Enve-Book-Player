//
// Exporter.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//


import Foundation
import ZIPFoundation

public struct EpubExporter : AlignmentSessionProviding {
    public init(session: AlignmentSession) {
        self.session = session
    }
    public let session:AlignmentSession
    
    public func export (eBook:EpubDocument, to outputFile:URL) throws {
        logger.log(.info, "Exporting to: \(outputFile)" )
        
        let totalBytes = Int( try FileManager.default.du( eBook.unzippedURL ))
        
        session.progressTracker.updateProgress(for: .export, event: .start, total: totalBytes)
        
        let folderURL = eBook.unzippedURL.standardizedFileURL
        if eBook.isEpub2 {
            let mimetypeURL = folderURL.appendingPathComponent("mimetype")
            try Data("application/epub+zip".utf8).write(to: mimetypeURL, options: .atomic)
        }
        
        let archive = try Archive(url: outputFile, accessMode: .create)
        logger.log(.debug, "folderURL \(folderURL)")
        try archive.addEntry(with: "mimetype", relativeTo: folderURL, compressionMethod: .none)

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: resourceKeys)!
        try enumerator.compactMap { ($0 as? URL)?.standardizedFileURL }.forEach { fileURL in
            try Task.checkCancellation()

            let resourceVals = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey] )

            defer {
                session.progressTracker.updateProgress(for: .export, increment: resourceVals.fileSize ?? 0, item:fileURL.lastPathComponent )
            }
            
            logger.log(.debug, "Processing \(fileURL)")
            let isDir = resourceVals.isDirectory ?? false
            let entryName = fileURL.path.replacingOccurrences(of: folderURL.path + "/", with: "")
            if entryName == "mimetype" {
                return
            }
            if isDir {
                return
            }
            logger.log( .info, "Adding \(entryName)")
            try archive.addEntry(with: entryName, relativeTo: folderURL, compressionMethod: .deflate)
        }
        
        session.progressTracker.updateProgress(for: .export, event: .end )
        
        logger.log(.info, "Export complete" )
    }
}
