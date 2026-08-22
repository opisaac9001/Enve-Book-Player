//
// FileManage+Extensions.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation
import ZIPFoundation

public extension FileManager {
    func unzipItem(at archiveURL:URL, to destinationURL:URL, overwrite: Bool ) throws {
        if overwrite {
            let archive = try Archive(url: archiveURL, accessMode: .read)
            for entry in archive {
                let entryDest = destinationURL.appendingPathComponent(entry.path)
                if fileExists(atPath: entryDest.path) {
                    try removeItem(at: entryDest)
                }
            }
        }

        try self.unzipItem(at:archiveURL, to: destinationURL)
    }
}

extension FileManager {
    func du(_  url: URL) throws -> UInt64 {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = self.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }
        var totalSize: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if values.isRegularFile == true, let fileSize = values.fileSize {
                totalSize += UInt64(fileSize)
            }
        }
        return totalSize
    }
}
