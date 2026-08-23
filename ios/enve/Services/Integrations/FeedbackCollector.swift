import Foundation
import Logging
import Pulse

#if os(iOS)
import UIKit
#endif

final class FeedbackCollector {
    static let shared = FeedbackCollector()
    private init() {}

    func getDeviceInfo() -> [String: String] {
        var info: [String: String] = [:]

        #if os(iOS)
        info["Device"] = deviceModelIdentifier()
        info["OS Version"] = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        #else
        info["OS Version"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        info["App Version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        info["Build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let freeSpace = attrs[.systemFreeSize] as? Int64
        {
            info["Free Storage"] = ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
        }

        #if os(iOS)
        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.screen
        {
            info["Screen"] = "\(Int(screen.bounds.width))\u{00D7}\(Int(screen.bounds.height)) @\(Int(screen.scale))x"
        }
        #endif

        info["Language"] = Locale.current.language.languageCode?.identifier ?? "Unknown"

        return info
    }

    func getConsoleLogFileURL() -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = tempDir.appendingPathComponent("enve-logs-\(timestamp).txt")

        do {
            let store = LoggerStore.shared
            let sortDescriptors = [SortDescriptor(\LoggerMessageEntity.createdAt, order: .reverse)]
            let allMessages = try store.messages(sortDescriptors: sortDescriptors)

            let recentMessages = allMessages.prefix(200)
            var logText = "=== Enve Sanitized Logs ===\n"
            logText += "Exported: \(Date())\n"
            logText += "Entry count: \(recentMessages.count)\n\n"

            for message in recentMessages {
                let timestamp = ISO8601DateFormatter().string(from: message.createdAt)
                let level = levelName(message.level)
                let label = message.label
                let text = sanitizeLogText(message.text)
                logText += "[\(timestamp)] [\(level)] [\(label)] \(text)\n"
            }

            logText += "\n=== End Logs ===\n"
            try logText.write(to: logFile, atomically: true, encoding: .utf8)
            return logFile
        } catch {
            AppLogger.network.error("Failed to export Pulse logs: \(error)")
            return nil
        }
    }

    func generateDebugReport(userMessage: String) -> String {
        var report = "=== Enve Bug Report ===\n\n"

        report += "User Message:\n\(DiagnosticLogSanitizer.sanitize(userMessage))\n\n"

        report += "=== Device Information ===\n"
        let info = getDeviceInfo()
        for (key, value) in info.sorted(by: { $0.key < $1.key }) {
            report += "\(key): \(value)\n"
        }

        let backends = AppState.shared.providerConnections.allBackends().filter { $0.enabled }
        report += "\n=== Connected Servers ===\n"
        report += "Count: \(backends.count)\n"
        let types = Set(backends.map { $0.type.rawValue })
        report += "Types: \(types.sorted().joined(separator: ", "))\n"

        report += "\n=== Recent Logs (sanitized) ===\n"
        do {
            let store = LoggerStore.shared
            let sortDescriptors = [SortDescriptor(\LoggerMessageEntity.createdAt, order: .reverse)]
            let allMessages = try store.messages(sortDescriptors: sortDescriptors)
            let recentMessages = allMessages.prefix(50)
            for message in recentMessages {
                let timestamp = ISO8601DateFormatter().string(from: message.createdAt)
                let level = levelName(message.level)
                let text = sanitizeLogText(message.text)
                report += "[\(timestamp)] [\(level)] \(text)\n"
            }
        } catch {
            report += "(Unable to load logs)\n"
        }

        report += "\n=== End Report ===\n"
        return report
    }

    private func levelName(_ level: Int16) -> String {
        switch level {
        case 0: return "TRACE"
        case 1: return "DEBUG"
        case 2: return "INFO"
        case 3: return "NOTICE"
        case 4: return "WARNING"
        case 5: return "ERROR"
        case 6: return "CRITICAL"
        default: return "UNKNOWN"
        }
    }

    private func sanitizeLogText(_ text: String) -> String {
        DiagnosticLogSanitizer.sanitize(text)
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }

        if identifier == "x86_64" || identifier == "arm64" {
            return "Simulator"
        }
        return identifier
    }
}
