#if DEBUG
import SwiftUI

struct DetailDebugSection: View {
    let book: Book

    @Environment(\.hearth) private var hearth
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.35)) { expanded.toggle() }
            } label: {
                HStack {
                    Overline("Debug", color: hearth.textTertiary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.hearthUI(11, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    row("Book ID", book.id)
                    row("Stable ID", book.stableId)
                    row("Download key", book.downloadKey)
                    row("Source", book.source.rawValue)
                    row("Provider ID", book.providerId.uuidString)
                    if let backendName = book.backendName {
                        row("Backend", backendName)
                    }
                    row("Media type", book.mediaType.rawValue)
                    if let filePath = book.filePath {
                        row("File path", filePath)
                    }
                    if let thumb = book.thumb {
                        row("Thumb URL", thumb)
                    }
                    if let coverURL = book.coverURL {
                        row("Cover URL", coverURL.absoluteString)
                    }
                    let audioDir = LocalStorageManager.shared.bookAudioDirectory(for: book.downloadKey)
                    row("Audio dir", audioDir.path)
                    let exists = FileManager.default.fileExists(atPath: audioDir.path)
                    row("Dir exists", exists ? "yes" : "no")
                    if exists, let contents = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
                        row("Files", contents.joined(separator: ", "))
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 12)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.hearthUI(11).monospaced())
                .foregroundStyle(hearth.textTertiary)
                .frame(width: 88, alignment: .trailing)
            Text(value)
                .font(.hearthUI(11).monospaced())
                .foregroundStyle(hearth.textSecondary)
        }
    }
}
#endif
