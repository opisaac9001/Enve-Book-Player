import Logging
import MessageUI
import SwiftUI
import UIKit

struct ReportIssueScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var feedbackMessage = ""
    @State private var includeDebugInfo = true
    @State private var showEmailComposer = false
    @State private var showCopiedAlert = false

    var body: some View {
        SettingsScaffold(
            overline: "About",
            title: "Report an issue",
            subtitle: "Bugs go to GitHub; conversation lives on Discord and Reddit."
        ) {
            channelsCard
            feedbackCard
            debugInfoCard
            actionsCard
            #if DEBUG
            devModeCard
            #endif
        }
        .alert("Report copied", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The report is on your clipboard, ready to paste.")
        }
        .sheet(isPresented: $showEmailComposer) {
            if MFMailComposeViewController.canSendMail() {
                ReportMailComposer(
                    recipient: "enve.audiobook@gmail.com",
                    subject: "Enve Bug Report",
                    messageBody: reportAnonymize(feedbackMessage.isEmpty ? "Bug report with attached logs" : feedbackMessage),
                    attachment: createLogsArchive()
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.hearthUI(40))
                        .foregroundStyle(hearth.statusWarn)
                    Text("Mail isn't set up on this device")
                        .font(.hearthDisplay(20))
                        .foregroundStyle(hearth.text)
                    Text("Copy the report instead and send it from anywhere.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                    QuietButton(title: "Copy report", systemImage: "doc.on.doc") {
                        copyReport()
                        showEmailComposer = false
                    }
                }
                .padding(28)
                .presentationDetents([.height(280)])
                .hearthPresentationBackground()
            }
        }
    }

    private var channelsCard: some View {
        SourcesCard {
            Overline("Support channels")
            reportChannelRow(
                title: "Report a bug",
                caption: "Open a GitHub issue",
                glyph: "ladybug",
                url: "https://github.com/opisaac9001/Enve-Audiobook-Player-Support/issues"
            )
            reportChannelRow(
                title: "Discord",
                caption: "discord.gg/nXtASwRkQy",
                glyph: "bubble.left.and.bubble.right",
                url: "https://discord.gg/nXtASwRkQy"
            )
            reportChannelRow(
                title: "Reddit",
                caption: "r/enveaudiobookplayer",
                glyph: "person.2",
                url: "https://reddit.com/r/enveaudiobookplayer"
            )
        }
    }

    private func reportChannelRow(title: String, caption: String, glyph: String, url: String) -> some View {
        Button {
            if let destination = URL(string: url) {
                UIApplication.shared.open(destination)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.hearthUI(16))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(caption)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var feedbackCard: some View {
        SourcesCard {
            Overline("What went wrong")
            TextEditor(text: $feedbackMessage)
                .font(.hearthBody)
                .scrollContentBackground(.hidden)
                .foregroundStyle(hearth.text)
                .frame(height: 130)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hearth.bg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }
        }
    }

    private var debugInfoCard: some View {
        SourcesCard {
            SourcesToggleRow(
                title: "Include debug information",
                subtitle: "Device details, app version, and recent logs",
                isOn: $includeDebugInfo
            )
            if includeDebugInfo {
                Divider().overlay(hearth.hairline)
                let info = FeedbackCollector.shared.getDeviceInfo()
                ForEach(info.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack {
                        Text(key)
                            .font(.hearthUI(12, weight: .medium).monospaced())
                            .foregroundStyle(hearth.textSecondary)
                        Spacer()
                        Text(value)
                            .font(.hearthUI(12).monospaced())
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                    }
                }
                Text("Emails, addresses, and secrets are scrubbed before the report leaves the phone.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sendDisabled: Bool {
        feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionsCard: some View {
        SourcesCard {
            EmberButton(title: "Send by email", systemImage: "envelope", tint: nil) {
                showEmailComposer = true
            }
            .disabled(sendDisabled)
            .opacity(sendDisabled ? 0.5 : 1)
            QuietButton(title: "Copy report", systemImage: "doc.on.doc") {
                copyReport()
            }
            .disabled(sendDisabled)
            .opacity(sendDisabled ? 0.5 : 1)
        }
    }

    private func copyReport() {
        UIPasteboard.general.string = generateReport()
        showCopiedAlert = true
        PlatformHaptics.notification(.success)
    }

    private func generateReport() -> String {
        let feedback = reportAnonymize(feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        let report =
            includeDebugInfo
            ? FeedbackCollector.shared.generateDebugReport(userMessage: feedback)
            : feedback
        return reportAnonymize(report)
    }

    private func createLogsArchive() -> URL? {
        let reportText = generateReport()
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logsDirectory = tempDir.appendingPathComponent("enve-logs-\(timestamp)")

        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try reportText.write(to: logsDirectory.appendingPathComponent("debug-report.txt"), atomically: true, encoding: .utf8)

            if let consoleLogURL = FeedbackCollector.shared.getConsoleLogFileURL() {
                let destination = logsDirectory.appendingPathComponent("console.log")
                if let rawLog = try? String(contentsOf: consoleLogURL, encoding: .utf8) {
                    try? reportAnonymize(rawLog).write(to: destination, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.copyItem(at: consoleLogURL, to: destination)
                }
            }

            let zipURL = tempDir.appendingPathComponent("enve-logs-\(timestamp).zip")
            try reportZipDirectory(at: logsDirectory, to: zipURL)
            try? FileManager.default.removeItem(at: logsDirectory)
            return zipURL
        } catch {
            AppLogger.general.error("Failed to create logs archive: \(error)")
            let fallback = tempDir.appendingPathComponent("enve-debug-report-\(timestamp).txt")
            try? reportText.write(to: fallback, atomically: true, encoding: .utf8)
            return fallback
        }
    }

    private func reportZipDirectory(at sourceURL: URL, to destinationURL: URL) throws {
        var coordinatorError: NSError?
        var zipError: Error?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: zipURL.path) {
                    try FileManager.default.copyItem(at: zipURL, to: destinationURL)
                }
            } catch {
                zipError = error
            }
        }
        if let error = coordinatorError ?? zipError { throw error }
    }

    #if DEBUG
    private var devModeCard: some View {
        SourcesCard {
            let devMode = DevModeManager.shared
            Button {
                devMode.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: devMode.isDevModeEnabled ? "lock.open" : "lock")
                        .font(.hearthUI(14))
                        .foregroundStyle(devMode.isDevModeEnabled ? hearth.statusOK : hearth.textSecondary)
                    Text(devMode.isDevModeEnabled ? "Dev mode is on. Tap to sign out." : "Dev mode")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }
    #endif
}

private func reportAnonymize(_ input: String) -> String {
    var text = input
    let patterns: [(String, String)] = [
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<redacted email>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted ip>"),
        (#"(https?:\/\/)[^\s@\/]+:[^\s@\/]+@"#, "$1<redacted>:<redacted>@"),
        (#"(?i)(token|access_token|api_key|apikey|password|passwd|pwd|secret|username|user)\s*[:=]\s*[^\s&]+"#, "$1=<redacted>"),
    ]
    for (pattern, replacement) in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        }
    }
    return text
}

private struct ReportMailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let messageBody: String
    let attachment: URL?

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([recipient])
        composer.setSubject(subject)
        composer.setMessageBody(messageBody, isHTML: false)
        if let attachment, let data = try? Data(contentsOf: attachment) {
            let mimeType = attachment.pathExtension == "zip" ? "application/zip" : "text/plain"
            composer.addAttachmentData(data, mimeType: mimeType, fileName: attachment.lastPathComponent)
        }
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}
