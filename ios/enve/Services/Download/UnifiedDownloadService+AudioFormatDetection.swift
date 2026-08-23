import Foundation
import Logging

extension UnifiedDownloadService {
    nonisolated static func detectAudioExtension(
        urlPathExtension: String?,
        response: URLResponse?,
        fileURL: URL
    ) -> String {
        if let ext = urlPathExtension, !ext.isEmpty,
            !["file", "download", "stream"].contains(ext)
        {
            return ext
        }

        if let httpResponse = response as? HTTPURLResponse,
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        {
            if contentType.contains("audio/mpeg") || contentType.contains("audio/mp3") {
                return "mp3"
            } else if contentType.contains("audio/mp4") || contentType.contains("audio/x-m4b") || contentType.contains("audio/m4b") {
                return "m4b"
            } else if contentType.contains("audio/x-m4a") || contentType.contains("audio/m4a") {
                return "m4a"
            } else if contentType.contains("audio/aac") {
                return "aac"
            } else if contentType.contains("audio/flac") {
                return "flac"
            } else if contentType.contains("audio/wav") || contentType.contains("audio/wave") || contentType.contains("audio/x-wav") {
                return "wav"
            } else if contentType.contains("audio/ogg") {
                return "ogg"
            } else if contentType.contains("application/audiobook+zip") || contentType.contains("application/zip") {
                return "zip"
            } else if contentType.contains("application/octet-stream") {
            } else if contentType.contains("text/html") || contentType.contains("text/plain") {
                AppLogger.network.info("Non-audio Content-Type: \(contentType)")
            }
        }

        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }

        if let ext = detectExtensionFromMagicBytes(at: fileURL) {
            return ext
        }

        return "m4b"
    }

    nonisolated static func detectExtensionFromMagicBytes(at fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 12), header.count >= 4 else { return nil }

        if header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33 {
            return "mp3"
        }
        if header[0] == 0xFF && (header[1] & 0xE0) == 0xE0 {
            return "mp3"
        }
        if header.count >= 8 && header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70 {
            return "m4b"
        }
        if header[0] == 0x66 && header[1] == 0x4C && header[2] == 0x61 && header[3] == 0x43 {
            return "flac"
        }
        if header[0] == 0x4F && header[1] == 0x67 && header[2] == 0x67 && header[3] == 0x53 {
            return "ogg"
        }
        if header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 {
            return "wav"
        }
        if header[0] == 0x1A && header[1] == 0x45 && header[2] == 0xDF && header[3] == 0xA3 {
            return "mka"
        }
        if header[0] == 0x50 && header[1] == 0x4B && header[2] == 0x03 && header[3] == 0x04 {
            return "zip"
        }

        return nil
    }
}
