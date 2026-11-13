#if os(iOS)
import SwiftUI

struct NarratorModelsScreen: View {
    var models: NarratorModelStore = .shared

    @Environment(\.hearth) private var hearth

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & sync",
            title: "Narrator models",
            subtitle: "On-device voices for reading ebooks aloud. Downloads are shared by every profile on this device."
        ) {
            if EbookTTSEngineChoice.downloadableCases.isEmpty {
                SourcesCard {
                    Text("Downloadable narrators aren't available on this platform. Apple voices read your books aloud.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                storageCard
                ForEach(EbookTTSEngineChoice.downloadableCases) { engine in
                    SourcesCard {
                        NarratorModelControls(engine: engine, models: models) { models.download(engine) }
                        if let license = engine.license {
                            Link(license.title, destination: license.url)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.ember)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("narrator-model-\(engine.rawValue)")
                }
                Text("Apple voices are built in and need no download. Choose a narrator from Read to me in the reader.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await models.refreshStorage() }
    }

    private var storageCard: some View {
        SourcesCard {
            Overline("Storage")
            HStack {
                Text("Installed narrators")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                Text(installedSummary)
                    .font(.hearthUI(15, weight: .medium).monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
            }
            .accessibilityElement(children: .combine)
            if let available = models.availableBytes {
                HStack {
                    Text("Available on this device")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
                        .font(.hearthUI(15, weight: .medium).monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var installedSummary: String {
        let installed = EbookTTSEngineChoice.downloadableCases.filter { models.state(for: $0) == .ready }
        guard !installed.isEmpty else { return "None" }
        let bytes = installed.reduce(Int64(0)) { $0 + (models.storage[$1]?.installedBytes ?? 0) }
        return "\(installed.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

struct NarratorModelControls: View {
    let engine: EbookTTSEngineChoice
    let models: NarratorModelStore
    let download: () -> Void

    @Environment(\.hearth) private var hearth
    @State private var confirmingRemoval = false

    private var state: TTSModelDownloadState { models.state(for: engine) }
    private var storage: NarratorModelStorage? { models.storage[engine] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.modelName)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text([engine.modelSummary, sizeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if state == .ready {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.ember)
                }
            }
            .accessibilityElement(children: .combine)
            status
        }
        .confirmationDialog("Remove \(engine.modelName)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { models.remove(engine) }
        } message: {
            Text("Readers using \(engine.modelName) switch to Apple voices. You can download it again at any time.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .notDownloaded:
            if let shortage {
                Text(shortage)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuietButton(title: "Download", systemImage: "arrow.down.circle", action: download)
                .accessibilityLabel("Download \(engine.modelName)")
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading")
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.hearthCaption.monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                }
                ProgressView(value: progress)
                    .tint(hearth.ember)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading \(engine.modelName)")
            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
            QuietButton(title: "Cancel download", systemImage: "xmark.circle") { models.cancelDownload(engine) }
        case .cancelling:
            busy("Stopping download. Files already saved are kept for next time.")
        case .removing:
            busy("Removing \(engine.modelName)")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.hearthCaption)
                .foregroundStyle(hearth.statusError)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Try again", systemImage: "arrow.clockwise", action: download)
                .accessibilityLabel("Try downloading \(engine.modelName) again")
        case .ready:
            QuietButton(title: "Remove", systemImage: "trash") { confirmingRemoval = true }
                .accessibilityLabel("Remove \(engine.modelName)")
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(hearth.ember)
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var sizeText: String? {
        guard let storage else { return nil }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let approximate = storage.isEstimate ? "About " : ""
        switch state {
        case .ready, .removing:
            return storage.installedBytes > 0 ? "Uses \(format(storage.installedBytes))" : nil
        case .notDownloaded, .failed, .downloading, .cancelling:
            if storage.remainingBytes < storage.packageBytes, storage.remainingBytes > 0 {
                return "\(approximate)\(format(storage.remainingBytes)) left to download"
            }
            return "\(approximate)\(format(storage.packageBytes)) download"
        }
    }

    private var shortage: String? {
        guard let storage, let available = models.availableBytes, storage.remainingBytes > available else { return nil }
        return "Needs \(storage.isEstimate ? "about " : "")\(ByteCountFormatter.string(fromByteCount: storage.remainingBytes, countStyle: .file)) free; \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available."
    }
}
#endif
