import CryptoKit
import Foundation
import Logging

enum DiagnosticLogSanitizer {
    private nonisolated static let replacementRules: [(pattern: String, replacement: String)] = [
        (#"(?i)https?://[^\s\]\)>\"']+"#, "<server-url>"),
        (#"(?i)Bearer\s+[A-Za-z0-9\-._~+/]+=*"#, "Bearer <redacted>"),
        (#"(?i)(X-Plex-Token|token|password|passwd|pwd|secret|apikey|api_key|authorization|auth)\s*[=:]\s*[^\s&\]\)]+"#, "$1=<redacted>"),
        (#"(?i)(?:file://)?/(?:Users|Volumes|private|var|tmp|Applications)(?:/[^\"'\r\n,;\]\)]*)?"#, "<local-path>"),
        (#"(?i)([\"'])[^\"'\r\n]+\.(?:m4b|m4a|mp3|flac|aac|ogg|wav|epub|pdf|zip|cbz|cbr)\1"#, "<media-file>"),
        (#"(?i)\b(?:file(?:name)?|track)\s*[=:]\s*[^,\]\)\r\n]+\.(?:m4b|m4a|mp3|flac|aac|ogg|wav|epub|pdf|zip|cbz|cbr)"#, "file=<media-file>"),
        (#"(?i)\b(title|author|narrator|bookName|podcastName)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^,\]\)\r\n]+)"#, "$1=<private-library-data>"),
        (#"(?i)\b(?:bookId|stableId|uniqueId|providerId|sessionId)\s*[=:]\s*[A-Za-z0-9._:-]+"#, "identifier=<redacted>"),
        (#"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"#, "<redacted-id>"),
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<redacted-email>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ip>"),
    ]

    nonisolated static func sanitize(_ text: String, privateValues: [String] = []) -> String {
        var result = text

        for value in privateValues where !value.isEmpty {
            result = result.replacingOccurrences(
                of: value,
                with: "<private-library-data>",
                options: [.caseInsensitive, .literal]
            )
        }

        for rule in replacementRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }

        return result
    }

    nonisolated static func identifier(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fileDescriptor(for url: URL) -> String {
        let fileExtension = url.pathExtension.lowercased()
        let type = fileExtension.isEmpty ? "none" : fileExtension
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let bytes = byteCount.map(String.init) ?? "unknown"
        return "file[type=.\(type), bytes=\(bytes), id=\(identifier(for: url.standardizedFileURL.path))]"
    }
}

struct PrivacyRedactingLogHandler: LogHandler {
    private var base: any LogHandler

    init(_ base: any LogHandler) {
        self.base = base
    }

    var metadataProvider: Logger.MetadataProvider? {
        get { base.metadataProvider }
        set { base.metadataProvider = newValue }
    }

    var metadata: Logger.Metadata {
        get { base.metadata }
        set { base.metadata = newValue }
    }

    var logLevel: Logger.Level {
        get { base.logLevel }
        set { base.logLevel = newValue }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { base[metadataKey: key] }
        set { base[metadataKey: key] = newValue }
    }

    func log(event: LogEvent) {
        var event = event
        event.message = Logger.Message(stringLiteral: DiagnosticLogSanitizer.sanitize(event.message.description))
        event.metadata = event.metadata.map(Self.sanitize)
        if let error = event.error {
            event.error = SanitizedLogError(message: DiagnosticLogSanitizer.sanitize(error.localizedDescription))
        }
        base.log(event: event)
    }

    private static func sanitize(_ metadata: Logger.Metadata) -> Logger.Metadata {
        metadata.mapValues(sanitize)
    }

    private static func sanitize(_ value: Logger.Metadata.Value) -> Logger.Metadata.Value {
        switch value {
        case .string(let string):
            return .string(DiagnosticLogSanitizer.sanitize(string))
        case .stringConvertible(let value):
            return .string(DiagnosticLogSanitizer.sanitize(value.description))
        case .dictionary(let dictionary):
            return .dictionary(sanitize(dictionary))
        case .array(let values):
            return .array(values.map(sanitize))
        }
    }
}

private struct SanitizedLogError: Error, LocalizedError, CustomStringConvertible {
    let message: String

    var errorDescription: String? { message }
    var description: String { message }
}
